//
//  ArtworkStore.swift
//  PopcornKit
//
//  The artwork's own session and disk cache.
//
//  Before 5.3.0 the pictures shared `URLCache.shared` with every other
//  request of the app (20 MB on disk by default, and an answer larger than
//  5 % of that — 1 MB, a single backdrop — is not kept at all), while the
//  tvOS grids had AlamofireImage's own (150 MB). Now one cache for all of
//  them, in Caches/popcornkit-artwork (on the Mac, Caches/<bundle id>/
//  popcornkit-artwork):
//
//    Apple TV          4 MB in memory, 150 MB on disk
//    iPhone / iPad     4 MB in memory, 250 MB on disk
//    Mac               8 MB in memory, 500 MB on disk
//
//  A sized poster weighs 20 to 40 KB and a page's backdrop 0.2 to 2 MB: 150
//  MB is some 3 000 posters and 50 backdrops, more than a long evening of
//  browsing. The memory side is small on purpose: what is kept in memory is
//  the decoded pictures (`ArtworkPipeline`), not the files.
//
//  The hosts say how long a picture is good for (60 days to one year), and
//  the cache follows them (`useProtocolCachePolicy`): within that time a
//  screen seen once repaints with no network at all; after it the host is
//  asked whether the picture changed. An answer that is not a picture is
//  never kept: metahub marks its 404s good for four days, and a cache this
//  size would hold them much longer than the shared one did — the logo or
//  the still of a new title, missing today, comes within days. Such an
//  address is only left alone for ten minutes (in memory), so that a screen
//  that comes back does not ask again each time.
//  The system may empty Caches when the device runs short, and the app's
//  « Clear cache » does (`ArtworkPipeline.removeAllCachedData`).
//

import Foundation

public final class ArtworkStore: NSObject, @unchecked Sendable {

    public struct Policy: Equatable, Sendable {
        public var memoryBytes: Int
        public var diskBytes: Int
        /// Seconds without a byte before a request gives up.
        public var timeout: TimeInterval

        public init(memoryBytes: Int, diskBytes: Int, timeout: TimeInterval = 15) {
            self.memoryBytes = memoryBytes
            self.diskBytes = diskBytes
            self.timeout = timeout
        }

        public static var platform: Policy {
            #if os(tvOS)
            return Policy(memoryBytes: 4 << 20, diskBytes: 150 << 20)
            #elseif os(macOS)
            return Policy(memoryBytes: 8 << 20, diskBytes: 500 << 20)
            #else
            return Policy(memoryBytes: 4 << 20, diskBytes: 250 << 20)
            #endif
        }
    }

    /// One answer, for the pipeline's counters.
    struct Response: Sendable {
        enum Outcome: String, Sendable {
            case network, disk, failed
        }
        let url: URL
        /// Where the picture's bytes came from.
        let outcome: Outcome
        /// The picture's size.
        let bytes: Int
        /// Bytes that crossed the network for it (headers and bodies,
        /// redirects included): nothing for a cached picture, unless a
        /// redirect to it had to be asked again.
        let wireBytes: Int
        let seconds: TimeInterval
    }

    public static let standard: ArtworkStore = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return ArtworkStore(directory: directory(in: caches, bundleIdentifier: Bundle.main.bundleIdentifier), policy: .platform)
    }()

    /// The cache's folder in `caches`. The Mac app is not sandboxed: its
    /// Caches folder is the user's, shared by every app — and by every
    /// build and test identity of this one. There the folder goes under the
    /// bundle's own (as URLCache.shared does), so that two copies never
    /// open one database, nor empty each other's. On iOS and tvOS the
    /// Caches folder is already the app's.
    static func directory(in caches: URL, bundleIdentifier: String?) -> URL {
        #if os(macOS)
        return caches.appendingPathComponent(bundleIdentifier ?? "PopcornTime", isDirectory: true)
            .appendingPathComponent("popcornkit-artwork", isDirectory: true)
        #else
        return caches.appendingPathComponent("popcornkit-artwork", isDirectory: true)
        #endif
    }

    public let policy: Policy
    public let cache: URLCache
    private let session: URLSession
    var onResponse: (@Sendable (Response) -> Void)?

    /// The addresses that answered "no such picture" (404, 410), and when:
    /// not asked again for `missingLifetime`.
    private let lock = NSLock()
    private var missing: [URL: Date] = [:]
    var missingLifetime: TimeInterval = 600
    var now: @Sendable () -> Date = { Date() }

    /// `protocolClasses`: for the tests, which answer the requests themselves.
    public init(directory: URL, policy: Policy, protocolClasses: [AnyClass]? = nil) {
        self.policy = policy
        // URLCache opens its database in the folder without making it.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.cache = URLCache(memoryCapacity: policy.memoryBytes, diskCapacity: policy.diskBytes, directory: directory)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = policy.timeout
        configuration.timeoutIntervalForResource = max(60, policy.timeout * 4)
        // Pictures from third-party hosts: nothing of the user goes with
        // the requests, and nothing they set is kept.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    /// The bytes at `url` (a file address is read directly). Throws for
    /// anything but a 2xx answer with a body.
    public func data(from url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        if isKnownMissing(url) { throw URLError(.fileDoesNotExist) }
        let started = Date()
        let probe = Probe()
        do {
            let (data, response) = try await session.data(from: url, delegate: probe)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                forget(url, answeredBy: http.url)
                if http.statusCode == 404 || http.statusCode == 410 { noteMissing(url) }
                throw URLError(.badServerResponse)
            }
            guard !data.isEmpty else { throw URLError(.zeroByteResource) }
            // A picture that came over the network weighs at least its
            // size (a protocol of the tests reports no bytes at all).
            let fromDisk = probe.readFromCache
            onResponse?(Response(url: url, outcome: fromDisk ? .disk : .network, bytes: data.count,
                                 wireBytes: fromDisk ? probe.networkBytes : max(probe.networkBytes, data.count),
                                 seconds: Date().timeIntervalSince(started)))
            return data
        } catch {
            // A request cancelled because another address won is not a
            // failure of this one.
            if (error as? URLError)?.code != .cancelled, !(error is CancellationError) {
                onResponse?(Response(url: url, outcome: .failed, bytes: 0, wireBytes: probe.networkBytes,
                                     seconds: Date().timeIntervalSince(started)))
            }
            throw error
        }
    }

    /// An answer that is not a picture leaves the cache: the address asked,
    /// and the one a redirect led to.
    private func forget(_ url: URL, answeredBy final: URL?) {
        cache.removeCachedResponse(for: URLRequest(url: url))
        if let final, final != url { cache.removeCachedResponse(for: URLRequest(url: final)) }
    }

    private func isKnownMissing(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let date = missing[url] else { return false }
        if now().timeIntervalSince(date) < missingLifetime { return true }
        missing[url] = nil
        return false
    }

    private func noteMissing(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if missing.count >= 2000 { missing.removeAll() }
        missing[url] = now()
    }

    /// Whether the cache has an answer for `url` (a read of the cache's
    /// database: not for the main thread).
    public func holds(_ url: URL) -> Bool {
        url.isFileURL || cache.cachedResponse(for: URLRequest(url: url)) != nil
    }

    /// Empties the disk cache (and forgets which addresses had nothing).
    public func removeAll() {
        cache.removeAllCachedResponses()
        lock.lock()
        missing.removeAll()
        lock.unlock()
    }

    /// Bytes the cache holds on disk.
    public var diskUsage: Int { cache.currentDiskUsage }

    /// Reads a task's metrics: whether the picture was read from the cache,
    /// and the bytes that came over the network (a cached picture behind a
    /// redirect that is not cached still costs the redirect).
    private final class Probe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        private var cached = false

        /// Bytes on the wire (headers and bodies, as sent, redirects
        /// included).
        var networkBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
        /// The last step of the load — the picture itself — came from the
        /// cache.
        var readFromCache: Bool { lock.lock(); defer { lock.unlock() }; return cached }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            var bytes = 0
            for transaction in metrics.transactionMetrics where transaction.resourceFetchType != .localCache {
                bytes += Int(transaction.countOfResponseHeaderBytesReceived + transaction.countOfResponseBodyBytesReceived)
            }
            lock.lock()
            self.bytes = bytes
            self.cached = metrics.transactionMetrics.last?.resourceFetchType == .localCache
            lock.unlock()
        }
    }
}
