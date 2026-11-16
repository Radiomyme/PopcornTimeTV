//
//  ArtworkPrefetcher.swift
//  PopcornKit
//
//  Pictures fetched before they are needed: the next shelf of the Home, the
//  next row of a grid, the backdrop of the card about to be focused. They go
//  through the same pipeline as the views (`ArtworkPipeline`), so a view
//  that then asks for one finds it decoded, or joins the load already
//  running; they wait behind everything a view is waiting for and never
//  take more than a few of the connections.
//
//      let prefetcher = ArtworkPrefetcher()                    // one per screen
//      prefetcher.prefetch(urls: nextShelfPosters, width: 250 * displayScale)
//      prefetcher.cancel(urls: shelfThatLeft)                  // or cancel() when the screen goes
//
//  `width` is the width the pictures will be drawn at, in PIXELS (points ×
//  the screen's scale): it chooses the size downloaded, as the view will.
//

import Foundation
import CoreGraphics

public final class ArtworkPrefetcher: @unchecked Sendable {

    /// For callers without a screen of their own to tie a prefetcher to.
    public static let shared = ArtworkPrefetcher()

    private let pipeline: ArtworkPipeline
    private let lock = NSLock()
    private var tasks: [URL: Task<Void, Never>] = [:]

    public init(pipeline: ArtworkPipeline = .shared) {
        self.pipeline = pipeline
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
    }

    /// Starts loading `urls` for a picture drawn `width` pixels wide. The
    /// ones already in memory at that size, and the ones already being
    /// prefetched, are skipped.
    public func prefetch(urls: [URL], width: CGFloat) {
        guard width > 0 else { return }
        for url in urls {
            let need = Self.need(for: url, width: width)
            if pipeline.cached(url, need: need)?.isEnough == true { continue }
            lock.lock()
            if tasks[url] == nil {
                tasks[url] = Task(priority: .utility) { [weak self, pipeline] in
                    _ = await pipeline.image(for: url, need: need, priority: .prefetch)
                    self?.ended(url)
                }
            }
            lock.unlock()
        }
    }

    /// Stops the prefetches of `urls` that have not ended (a load a view
    /// has joined meanwhile goes on for that view).
    public func cancel(urls: [URL]) {
        lock.lock()
        let cancelled = urls.compactMap { tasks.removeValue(forKey: $0) }
        lock.unlock()
        cancelled.forEach { $0.cancel() }
    }

    /// Stops every prefetch of this prefetcher.
    public func cancel() {
        lock.lock()
        let cancelled = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        cancelled.forEach { $0.cancel() }
    }

    /// The addresses being prefetched.
    public var pending: Int {
        lock.lock(); defer { lock.unlock() }
        return tasks.count
    }

    private func ended(_ url: URL) {
        lock.lock()
        tasks[url] = nil
        lock.unlock()
    }

    /// The size to load a picture drawn `width` pixels wide: decoded with
    /// some room (twice the side it needs), so that the view, which may
    /// allow itself a little more than it draws, still finds it large
    /// enough — while a host that only has one huge file is still cut down.
    /// Downloaded at the width a view asking for the picture's longest side
    /// (`ArtworkNeed(longestSide:)`, what every view passes) downloads: for
    /// an address that does not say what it shows, that side itself, so the
    /// view finds the prefetch's file — in memory, or in flight — rather
    /// than a narrower one it would load again.
    static func need(for url: URL, width: CGFloat) -> ArtworkNeed {
        let side = ArtworkURL.longestSide(forPixelWidth: width, of: url)
        return ArtworkNeed(longestSide: side * 2, pixelWidth: ArtworkURL.pixelWidth(forLongestSide: side, of: url))
    }
}
