//
//  ArtworkPipeline.swift
//  PopcornKit
//
//  One way in for every artwork of the app: the right size from the network
//  (`ArtworkURL`), with somewhere else to go when an address fails
//  (`ArtworkLoader`), decoded once at the size it is drawn, kept in memory
//  (bounded by pixels) and on disk (its own URLCache), and ready before it
//  is needed (`ArtworkPrefetcher`).
//
//  The views sit on top of it: `GlassRemoteImage` (SwiftUI, the three
//  platforms) and the grid cells' `UIImageView` loader (tvOS). It returns
//  CGImages: wrapping them in a UIImage or an NSImage is the caller's.
//

import Foundation
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// What the pipeline did since launch (or the last `resetStats`): read by
/// the DEBUG log and by the measurements of a screen's weight.
public struct ArtworkStats: Equatable, Sendable {
    /// Pictures answered from the decoded cache.
    public var memoryHits = 0
    /// Pictures decoded (from the network or from the disk cache).
    public var decoded = 0
    /// Pictures that came over the network, and every byte the pipeline
    /// received from it (headers and bodies, redirects and failures
    /// included).
    public var networkResponses = 0
    public var networkBytes = 0
    /// Answers read from the disk cache, and their size.
    public var diskResponses = 0
    public var diskBytes = 0
    /// Addresses that gave no picture (an error, a timeout, not an image).
    public var failures = 0
    /// Pictures that came from another address than the first one tried.
    public var detours = 0
    /// Pictures nobody could give.
    public var missing = 0

    public init() {}
}

public final class ArtworkPipeline: @unchecked Sendable {

    public typealias Priority = ArtworkPriority

    // MARK: Configuration

    public struct Configuration: Sendable {
        /// The decoded pictures kept in memory, in pixels (4 bytes each).
        public var memoryPixels: Int
        /// Loads at once, and how many of them prefetches may take.
        public var concurrentLoads: Int
        public var concurrentPrefetches: Int
        /// See `ArtworkLoader`.
        public var hedgeDelay: TimeInterval
        /// False: every address is loaded as given, without its alternates
        /// (what the app did before; kept for the measurements).
        public var sizesAddresses: Bool
        public var fetch: ArtworkLoader.Fetch
        public var sleep: ArtworkLoader.Sleep
        public var now: @Sendable () -> Date

        public init(memoryPixels: Int, concurrentLoads: Int, concurrentPrefetches: Int, hedgeDelay: TimeInterval = 2,
                    sizesAddresses: Bool = true, fetch: @escaping ArtworkLoader.Fetch,
                    sleep: @escaping ArtworkLoader.Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.memoryPixels = memoryPixels
            self.concurrentLoads = concurrentLoads
            self.concurrentPrefetches = concurrentPrefetches
            self.hedgeDelay = hedgeDelay
            self.sizesAddresses = sizesAddresses
            self.fetch = fetch
            self.sleep = sleep
            self.now = now
        }

        /// The memory bound for a device with `physicalMemory` bytes of RAM.
        /// A decoded poster of a grid is 0.1 to 0.4 million pixels, a
        /// 1920 × 1080 backdrop 2 million. Apple TV HD has 2 GB and a player
        /// to feed: 16 million pixels (64 MB) there, 24 million on the other
        /// Apple TVs; iPhone and iPad 32 million; the Mac 64 million. (The
        /// cache was 160 MB of full-size pictures on every platform.)
        public static func memoryPixels(physicalMemory: UInt64) -> Int {
            #if os(tvOS)
            return physicalMemory <= 2_200_000_000 ? 16_000_000 : 24_000_000
            #elseif os(macOS)
            return 64_000_000
            #else
            return physicalMemory <= 4_400_000_000 ? 24_000_000 : 32_000_000
            #endif
        }
    }

    public static let shared: ArtworkPipeline = {
        let store = ArtworkStore.standard
        var configuration = Configuration(
            memoryPixels: Configuration.memoryPixels(physicalMemory: ProcessInfo.processInfo.physicalMemory),
            concurrentLoads: 8, concurrentPrefetches: 3,
            fetch: { _ in throw URLError(.unsupportedURL) })
        #if os(tvOS)
        configuration.concurrentLoads = 6
        configuration.concurrentPrefetches = 2
        #endif
        #if DEBUG
        // -PTDebugArtworkOriginals YES: the addresses as the sources list
        // them, as 5.2.0 loaded them (to measure a screen before / after).
        if UserDefaults.standard.bool(forKey: "PTDebugArtworkOriginals") { configuration.sizesAddresses = false }
        #endif
        let pipeline = ArtworkPipeline(configuration: configuration, store: store)
        return pipeline
    }()

    // MARK: State

    private let configuration: Configuration
    private let loader: ArtworkLoader
    /// The disk cache and its session (nil when the fetch is injected).
    public let store: ArtworkStore?

    private let lock = NSLock()
    private var memory: ArtworkMemoryCache
    private var queue: ArtworkQueue
    private var routes = ArtworkRoutes()
    private var flights: [FlightKey: Flight] = [:]
    private var waiting: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    private var nextID: UInt64 = 0
    /// Where the picture of an address came from last time, when it was not
    /// the first address tried: tried first the next time.
    private var detours: [URL: ArtworkRoutes.Detour] = [:]
    private var counters = ArtworkStats()

    /// A load is shared by the address it downloads first, whatever side
    /// each caller decodes: two requests for one file are never in flight.
    private struct FlightKey: Hashable {
        let url: URL
        let first: URL?
        let alternates: [URL]
    }

    /// One load, shared by everyone who asks for the same picture while it
    /// runs. Its fields are read and written under the pipeline's lock.
    private final class Flight: @unchecked Sendable {
        let id: UInt64
        let key: FlightKey
        /// The longest side it decodes (`.infinity`: the picture's own).
        let side: CGFloat
        var task: Task<ArtworkImage?, Never>?
        var waiters = 0
        var priority: Priority
        init(id: UInt64, key: FlightKey, side: CGFloat, priority: Priority) {
            self.id = id
            self.key = key
            self.side = side
            self.priority = priority
        }
    }

    /// `store` nil: `configuration.fetch` is used as is (the tests).
    public init(configuration: Configuration, store: ArtworkStore? = nil) {
        var configuration = configuration
        if let store {
            configuration.fetch = { [weak store] url in
                guard let store else { throw URLError(.cancelled) }
                return try await store.data(from: url)
            }
        }
        self.configuration = configuration
        self.store = store
        self.loader = ArtworkLoader(fetch: configuration.fetch, sleep: configuration.sleep, hedgeDelay: configuration.hedgeDelay)
        self.memory = ArtworkMemoryCache(limit: configuration.memoryPixels)
        self.queue = ArtworkQueue(limit: configuration.concurrentLoads, prefetchLimit: configuration.concurrentPrefetches)
        store?.onResponse = { [weak self] response in self?.record(response) }
        #if canImport(UIKit)
        // Under memory pressure the decoded pictures go: what is on screen
        // is held by its views, the rest comes back from the disk cache.
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.purgeMemory()
        }
        #endif
    }

    #if canImport(UIKit)
    private var memoryWarning: NSObjectProtocol?
    deinit {
        if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
    }
    #endif

    // MARK: Reading

    /// The picture held in memory for `url`, and whether it is enough for
    /// `need` (when it is not, it can still be shown while the larger one
    /// loads). No I/O.
    public func cached(_ url: URL, need: ArtworkNeed) -> (image: ArtworkImage, isEnough: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard let image = memory.image(for: url) else { return nil }
        return (image, need.isMet(by: image, of: url))
    }

    /// The picture of `url` for `need`: from memory, else downloaded (or
    /// read from the disk cache) and decoded off the calling thread. Nil
    /// when no address gave a picture, or when the task was cancelled.
    /// `alternates`: other addresses of the same artwork, tried when `url`
    /// fails or stays silent (after the ones in `ArtworkAlternates`).
    public func image(for url: URL, need: ArtworkNeed = ArtworkNeed(), alternates: [URL] = [],
                      priority: Priority = .visible) async -> ArtworkImage? {
        guard let (image, joinedSmaller) = await loadOnce(url, need: need, alternates: alternates, priority: priority) else { return nil }
        // It joined a load of the same file decoded smaller (a prefetch,
        // another view): decoded again for this need, from the disk cache
        // that load has just filled — not downloaded a second time.
        guard joinedSmaller, !need.isMet(by: image, of: url), !Task.isCancelled else { return image }
        return await loadOnce(url, need: need, alternates: alternates, priority: priority)?.image ?? image
    }

    /// The picture from memory or from a load (joined or started), and
    /// whether that load decodes a smaller side than `need`.
    private func loadOnce(_ url: URL, need: ArtworkNeed, alternates: [URL],
                          priority: Priority) async -> (image: ArtworkImage, joinedSmaller: Bool)? {
        guard !Task.isCancelled else { return nil }
        let flight: Flight
        switch join(url, need: need, alternates: alternates, priority: priority) {
        case .held(let image): return (image, false)
        case .flight(let joined): flight = joined
        }
        let joinedSmaller = flight.side < (need.longestSide ?? .infinity)
        // A caller that gives up leaves the load to the others still
        // waiting for it; the last one to leave cancels it.
        let left = Left()
        return await withTaskCancellationHandler {
            let image = await flight.task?.value
            leave(flight, left, cancels: false)
            guard let image, !Task.isCancelled else { return nil }
            return (image, joinedSmaller)
        } onCancel: {
            leave(flight, left, cancels: true)
        }
    }

    private enum Joined {
        case held(ArtworkImage)
        case flight(Flight)
    }

    /// The picture when memory has it, else the load of it: the one already
    /// running for the same download, or a new one.
    private func join(_ url: URL, need: ArtworkNeed, alternates: [URL], priority: Priority) -> Joined {
        let width = configuration.sizesAddresses ? need.networkWidth(for: url) : nil
        let plan: [[URL]] = configuration.sizesAddresses
            ? ArtworkURL.sources(for: url, pixelWidth: width, alternates: alternates)
            : [[url]]
        let key = FlightKey(url: url, first: plan.first?.first, alternates: alternates)

        lock.lock()
        if let image = memory.image(for: url), need.isMet(by: image, of: url) {
            counters.memoryHits += 1
            lock.unlock()
            return .held(image)
        }
        let flight: Flight
        var promoted: [UInt64] = []
        if let running = flights[key] {
            flight = running
            if priority == .visible, running.priority == .prefetch {
                // A screen now waits for what was only being prefetched.
                running.priority = .visible
                promoted = queue.promote(running.id)
            }
        } else {
            nextID += 1
            let created = Flight(id: nextID, key: key, side: need.longestSide ?? .infinity, priority: priority)
            created.task = Task.detached(priority: priority == .visible ? .userInitiated : .utility) { [weak self] in
                guard let self else { return nil }
                let image = await self.load(url, need: need, askedWidth: width, plan: plan, flight: created)
                self.finished(created)
                return image
            }
            flights[key] = created
            flight = created
        }
        flight.waiters += 1
        let admitted = promoted.compactMap { waiting.removeValue(forKey: $0) }
        lock.unlock()
        admitted.forEach { $0.resume(returning: true) }
        return .flight(flight)
    }

    /// One caller's "I have left" flag: leaving is counted once, whether
    /// the load ended or the caller was cancelled first.
    private final class Left: @unchecked Sendable {
        var value = false
    }

    private func leave(_ flight: Flight, _ left: Left, cancels: Bool) {
        lock.lock()
        guard !left.value else { lock.unlock(); return }
        left.value = true
        flight.waiters -= 1
        let abandon = cancels && flight.waiters <= 0
        if abandon, flights[flight.key] === flight { flights[flight.key] = nil }
        lock.unlock()
        if abandon { flight.task?.cancel() }
    }

    private func finished(_ flight: Flight) {
        lock.lock()
        if flights[flight.key] === flight { flights[flight.key] = nil }
        lock.unlock()
    }

    // MARK: Loading

    private func load(_ url: URL, need: ArtworkNeed, askedWidth: CGFloat?, plan: [[URL]], flight: Flight) async -> ArtworkImage? {
        guard await enterQueue(flight) else { return nil }
        defer { leaveQueue() }
        guard !Task.isCancelled else { return nil }

        let sources = ordered(plan, for: url)
        let side = need.longestSide
        let result = await loader.load(sources) { data, _ in
            ArtworkDecoder.decode(data, longestSide: side)
        }
        guard !Task.isCancelled else { return nil }
        return settle(result, url: url, askedWidth: askedWidth, side: side, plan: plan, sources: sources)
    }

    /// The sources of a load in the order to try them now.
    private func ordered(_ plan: [[URL]], for url: URL) -> [[URL]] {
        lock.lock()
        let routes = self.routes, detour = detours[url]
        lock.unlock()
        // The disk cache is only asked about a route that is put aside: a
        // picture already downloaded is not fetched from another address
        // because its host stopped answering since.
        return routes.ordered(plan, detour: detour, now: configuration.now()) { [store] in store?.holds($0) ?? false }
    }

    /// Notes what the load says of the hosts, and keeps the picture.
    private func settle(_ result: ArtworkLoader.Result<ArtworkDecoder.Output>?, url: URL, askedWidth: CGFloat?, side: CGFloat?,
                        plan: [[URL]], sources: [[URL]]) -> ArtworkImage? {
        lock.lock()
        let now = configuration.now()
        guard let result else {
            counters.missing += 1
            sources.compactMap(\.first).forEach { routes.failed(ArtworkURL.route(of: $0), now: now) }
            lock.unlock()
            return nil
        }
        let winner = sources[result.source].last
        for index in result.passed {
            guard let lead = sources[index].first else { continue }
            // A source still silent is held against its route (the proxy
            // says nothing for a cover it cannot fetch) — unless it was the
            // winner's own resized copy: the proxy's first resize of a large
            // original is only slower than the original, not broken.
            if !result.failed.contains(index), let winner, let askedWidth,
               ArtworkURL.sized(winner, pixelWidth: askedWidth) == lead { continue }
            routes.failed(ArtworkURL.route(of: lead), now: now)
        }
        routes.succeeded(ArtworkURL.route(of: result.url), now: now)
        let detoured = result.url != plan.first?.first
        if detoured, let origin = sources[result.source].last {
            counters.detours += 1
            if detours.count >= 4000 { detours.removeAll() }
            detours[url] = ArtworkRoutes.Detour(origin: origin, skipsVariant: result.url == origin && sources[result.source].count > 1)
        } else {
            detours[url] = nil
        }
        counters.decoded += 1
        let image = memory.insert(ArtworkImage(cgImage: result.output.image, source: result.url,
                                               askedWidth: askedWidth ?? .infinity, askedSide: side ?? .infinity,
                                               reducedByDecoding: result.output.reduced), for: url)
        #if DEBUG
        let held = (memory.count, memory.pixels)
        #endif
        lock.unlock()
        #if DEBUG
        if Self.logs {
            print("[Artwork] decoded \(result.output.image.width)x\(result.output.image.height) for \(askedWidth.map { "w\(Int($0))" } ?? "original")\(detoured ? " (detour)" : "") <- \(result.url.absoluteString) | memory \(held.0) pictures \(held.1) px")
        }
        #endif
        return image
    }

    private func enterQueue(_ flight: Flight) async -> Bool {
        let id = flight.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                } else if queue.enter(id, flight.priority) {
                    lock.unlock()
                    continuation.resume(returning: true)
                } else {
                    waiting[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let continuation = queue.cancel(id) ? waiting.removeValue(forKey: id) : nil
            lock.unlock()
            continuation?.resume(returning: false)
        }
    }

    private func leaveQueue() {
        lock.lock()
        let admitted = queue.leave().compactMap { waiting.removeValue(forKey: $0) }
        lock.unlock()
        admitted.forEach { $0.resume(returning: true) }
    }

    // MARK: Housekeeping

    /// Forgets the decoded pictures (a memory warning, a player about to
    /// start): the views keep the ones they show.
    public func purgeMemory() {
        lock.lock()
        #if DEBUG
        let line = Self.logs ? "[Artwork] memory purged: \(memory.count) pictures \(memory.pixels) px" : nil
        #endif
        memory.removeAll()
        lock.unlock()
        #if DEBUG
        if let line { print(line) }
        #endif
    }

    /// Empties the memory and the disk caches (« Clear cache », a torrent
    /// that needs the room).
    public func removeAllCachedData() {
        purgeMemory()
        store?.removeAll()
    }

    /// Pixels held in memory, and their bound.
    public var memoryUse: (pixels: Int, limit: Int, pictures: Int) {
        lock.lock(); defer { lock.unlock() }
        return (memory.pixels, memory.limit, memory.count)
    }

    public var stats: ArtworkStats {
        lock.lock(); defer { lock.unlock() }
        return counters
    }

    public func resetStats() {
        lock.lock()
        counters = ArtworkStats()
        lock.unlock()
    }

    private func record(_ response: ArtworkStore.Response) {
        lock.lock()
        counters.networkBytes += response.wireBytes
        switch response.outcome {
        case .network:
            counters.networkResponses += 1
        case .disk:
            counters.diskResponses += 1
            counters.diskBytes += response.bytes
        case .failed:
            counters.failures += 1
        }
        #if DEBUG
        let line = Self.logs ? "[Artwork] \(response.outcome) \(response.outcome == .disk ? response.bytes : response.wireBytes) B \(Int(response.seconds * 1000)) ms \(response.url.absoluteString) | total network \(counters.networkResponses) answers \(counters.networkBytes) B, disk \(counters.diskResponses), failed \(counters.failures)" : nil
        #endif
        lock.unlock()
        #if DEBUG
        if let line { print(line) }
        #endif
    }

    #if DEBUG
    /// -PTDebugArtworkLog YES: one line per answer and per decoded picture.
    private static let logs = UserDefaults.standard.bool(forKey: "PTDebugArtworkLog")
    #endif
}

// MARK: - Decoding

enum ArtworkDecoder {

    struct Output: @unchecked Sendable {
        let image: CGImage
        /// Smaller than the file it was decoded from.
        let reduced: Bool
    }

    /// Decodes `data` at most `longestSide` pixels long (nil: its own size),
    /// straight to that size: the full bitmap of a 3840 × 2160 backdrop is
    /// never made. Nil when `data` is not a picture.
    static func decode(_ data: Data, longestSide: CGFloat?) -> Output? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let natural = CGFloat(max(width, height))
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let longestSide, longestSide > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = longestSide
        } else if natural > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = natural
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Output(image: image, reduced: natural > 0 && CGFloat(max(image.width, image.height)) < natural - 1)
    }
}
