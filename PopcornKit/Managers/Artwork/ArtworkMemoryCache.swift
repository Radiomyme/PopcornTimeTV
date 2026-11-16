//
//  ArtworkMemoryCache.swift
//  PopcornKit
//
//  The decoded pictures kept in memory, and the queue in front of the
//  network. Both are plain values behind the pipeline's lock.
//

import Foundation
import CoreGraphics

/// A decoded picture, with what was asked when it was loaded: a picture
/// loaded for a card answers the same card again whatever its pixels turned
/// out to be (a source that only has a small file, another picture of the
/// title used because the first address stayed silent), and is loaded again
/// only for something larger.
public struct ArtworkImage: @unchecked Sendable {
    public let cgImage: CGImage
    /// The address its bytes came from (a sized variant, another source…).
    public let source: URL
    /// The drawn width it was downloaded for (`.infinity`: the address as
    /// given, nothing wider exists).
    public var askedWidth: CGFloat
    /// The longest side it was decoded for (`.infinity`: its own size).
    public var askedSide: CGFloat
    /// Whether decoding made it smaller than the file downloaded.
    public let reducedByDecoding: Bool

    public var pixelWidth: Int { cgImage.width }
    public var pixelHeight: Int { cgImage.height }
    /// What it weighs in the memory cache.
    public var pixels: Int { cgImage.width * cgImage.height }
    /// The address as given, decoded whole: it answers any size.
    public var isComplete: Bool { askedWidth == .infinity && !reducedByDecoding }

    public init(cgImage: CGImage, source: URL, askedWidth: CGFloat = .infinity, askedSide: CGFloat = .infinity,
                reducedByDecoding: Bool = false) {
        self.cgImage = cgImage
        self.source = source
        self.askedWidth = askedWidth
        self.askedSide = askedSide
        self.reducedByDecoding = reducedByDecoding
    }
}

/// The size a picture is wanted at, in pixels.
public struct ArtworkNeed: Hashable, Sendable {
    /// The longest side to decode (nil: the picture's own size).
    public var longestSide: CGFloat?
    /// The width it is drawn at, which chooses what is downloaded (nil:
    /// worked out from `longestSide`).
    public var pixelWidth: CGFloat?

    public init(longestSide: CGFloat? = nil, pixelWidth: CGFloat? = nil) {
        self.longestSide = longestSide.flatMap { $0 > 0 ? $0 : nil }
        self.pixelWidth = pixelWidth.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The width to ask the network for: the drawn width, never more than
    /// what the decoder will keep.
    public func networkWidth(for url: URL) -> CGFloat? {
        let fromSide = longestSide.map { ArtworkURL.pixelWidth(forLongestSide: $0, of: url) }
        switch (pixelWidth, fromSide) {
        case let (width?, side?): return min(width, side)
        case let (width?, nil): return width
        case let (nil, side?): return side
        case (nil, nil): return nil
        }
    }

    /// Whether `image` is enough for this need: it was downloaded for a
    /// width at least as large — or happens to be about that wide (a
    /// prefetch, another screen) — and decoding did not cut it below the
    /// side asked.
    public func isMet(by image: ArtworkImage, of url: URL) -> Bool {
        let tolerance = ArtworkURL.coverage
        let width = networkWidth(for: url) ?? .infinity
        guard width <= max(image.askedWidth, CGFloat(image.pixelWidth) / tolerance) else { return false }
        guard image.reducedByDecoding else { return true }
        let side = longestSide ?? .infinity
        return side <= max(image.askedSide, CGFloat(max(image.pixelWidth, image.pixelHeight)) / tolerance)
    }
}

/// Decoded pictures by the address asked (one per address: the largest
/// decoded so far), bounded by the pixels they hold; the least recently
/// used go first.
struct ArtworkMemoryCache {

    private struct Entry {
        var image: ArtworkImage
        var used: UInt64
    }

    /// The bound, in pixels (4 bytes each once decoded).
    var limit: Int
    private(set) var pixels = 0
    private var entries: [URL: Entry] = [:]
    private var clock: UInt64 = 0

    init(limit: Int) {
        self.limit = limit
    }

    var count: Int { entries.count }

    mutating func image(for url: URL) -> ArtworkImage? {
        guard var entry = entries[url] else { return nil }
        clock += 1
        entry.used = clock
        entries[url] = entry
        return entry.image
    }

    /// Keeps the larger of `image` and the picture already held for `url`,
    /// with the largest size either was asked for. Returns the one kept.
    @discardableResult
    mutating func insert(_ image: ArtworkImage, for url: URL) -> ArtworkImage {
        clock += 1
        var kept = image
        if let old = entries[url]?.image {
            if old.pixels > image.pixels { kept = old }
            kept.askedWidth = max(old.askedWidth, image.askedWidth)
            kept.askedSide = max(old.askedSide, image.askedSide)
            pixels -= old.pixels
        }
        entries[url] = Entry(image: kept, used: clock)
        pixels += kept.pixels
        trim(to: limit, keeping: url)
        return kept
    }

    /// Drops the least recently used pictures until at most `bound` pixels
    /// are held (`keeping`: the one just added stays, even alone over the
    /// bound — it is on screen).
    mutating func trim(to bound: Int, keeping kept: URL? = nil) {
        guard pixels > bound else { return }
        for (url, entry) in entries.sorted(by: { $0.value.used < $1.value.used }) where url != kept {
            entries[url] = nil
            pixels -= entry.image.pixels
            if pixels <= bound { break }
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        pixels = 0
    }
}

/// Who waits for a picture.
public enum ArtworkPriority: Sendable {
    /// A view on screen.
    case visible
    /// Nobody yet: it is fetched ahead, behind everything a view waits for.
    case prefetch
}

/// The queue in front of the network: at most `limit` loads at once, the
/// ones a screen is waiting for before the prefetches, which never take more
/// than `prefetchLimit` of the places.
struct ArtworkQueue {

    typealias Priority = ArtworkPriority

    let limit: Int
    let prefetchLimit: Int
    private(set) var running = 0
    private var visible: [UInt64] = []
    private var prefetch: [UInt64] = []

    init(limit: Int, prefetchLimit: Int) {
        self.limit = max(1, limit)
        self.prefetchLimit = max(1, min(prefetchLimit, limit))
    }

    var waiting: Int { visible.count + prefetch.count }

    /// True when `id` may start now; otherwise it waits and `leave` (or
    /// `promote`) names it later.
    mutating func enter(_ id: UInt64, _ priority: Priority) -> Bool {
        switch priority {
        case .visible:
            if running < limit, visible.isEmpty { running += 1; return true }
            visible.append(id)
        case .prefetch:
            if running < prefetchLimit, visible.isEmpty, prefetch.isEmpty { running += 1; return true }
            prefetch.append(id)
        }
        return false
    }

    /// A load ended: the ones that may start now (they hold their place
    /// already).
    mutating func leave() -> [UInt64] {
        running = max(0, running - 1)
        return admit()
    }

    /// A screen now waits for a load queued as a prefetch.
    mutating func promote(_ id: UInt64) -> [UInt64] {
        guard let index = prefetch.firstIndex(of: id) else { return [] }
        prefetch.remove(at: index)
        visible.append(id)
        return admit()
    }

    /// `id` gave up while waiting. True when it was still in the queue.
    mutating func cancel(_ id: UInt64) -> Bool {
        if let index = visible.firstIndex(of: id) { visible.remove(at: index); return true }
        if let index = prefetch.firstIndex(of: id) { prefetch.remove(at: index); return true }
        return false
    }

    private mutating func admit() -> [UInt64] {
        var admitted: [UInt64] = []
        while running < limit, !visible.isEmpty {
            admitted.append(visible.removeFirst())
            running += 1
        }
        while visible.isEmpty, running < prefetchLimit, !prefetch.isEmpty {
            admitted.append(prefetch.removeFirst())
            running += 1
        }
        return admitted
    }
}
