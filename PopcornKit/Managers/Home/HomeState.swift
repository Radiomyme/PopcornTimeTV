import Foundation
import Observation

/// The hub's state for the views: one observable object for tvOS, iOS and
/// macOS (SwiftUI reads it directly; UIKit observes it with
/// `withObservationTracking`, or sets `HomeFeed.onUpdate` itself instead).
/// No SwiftUI here: PopcornKit stays UI-free.
///
///     @State private var home = HomeState.shared
///     …
///     .task { home.start() }
///     .refreshable { await home.refresh(force: true) }
///     .onAppear { home.refreshLocal() }
@MainActor
@Observable
public final class HomeState {

    /// The app's hub (`HomeFeed.shared`).
    public static let shared = HomeState(feed: .shared)

    /// The shelves under the hero, in display order. Empty shelves are not listed.
    public private(set) var shelves: [HomeShelf] = []
    /// The hero's cards ([]: no hero, start the page with the first shelf).
    public private(set) var heroItems: [HomeItem] = []
    public private(set) var isRefreshing = false
    /// When the freshest list on screen was fetched.
    public private(set) var lastUpdated: Date?
    /// The last refresh reached no source: what is shown comes from the
    /// cache. (A single host that stays down does not set it.)
    public private(set) var isOffline = false
    /// The last refresh reached no source and nothing is cached: show an
    /// error with a retry instead of an empty page.
    public private(set) var isUnavailable = false
    /// False until the first snapshot arrived (the disk cache has been
    /// read): until then the page shows its placeholders, not "nothing".
    public private(set) var hasLoaded = false

    @ObservationIgnored public let feed: HomeFeed
    @ObservationIgnored private var started = false

    /// Takes over `feed.onUpdate`.
    public init(feed: HomeFeed) {
        self.feed = feed
        feed.onUpdate = { [weak self] snapshot in
            // `HomeFeed` delivers on the main queue.
            MainActor.assumeIsolated { self?.apply(snapshot) }
        }
    }

    /// Paints from the disk cache (read off the main thread: the shelves
    /// arrive a few milliseconds later), then refreshes. Later calls only
    /// refresh what is not fresh any more (cheap: call it whenever the hub
    /// appears).
    public func start() {
        guard !started else { return feed.refresh() }
        started = true
        feed.start()
    }

    /// Paints the page the disk cache has at once, on the main thread, with
    /// the user's own shelves: for a screen whose first frame should not be
    /// empty (the Apple TV Home, before `start()`). The cost is a read of
    /// the cache and of the library's files on the main thread — measure it
    /// on the slowest device. Does nothing once a page is shown; returns
    /// whether a page is shown. No list cached (a first launch, where the
    /// user's own shelves alone would be a page the lists then push down):
    /// nothing is painted and `hasLoaded` stays false, so the page keeps
    /// its placeholders until `start()` brings the first lists.
    @discardableResult
    public func paintFromDisk() -> Bool {
        guard !hasLoaded else { return true }
        let snapshot = feed.diskSnapshot()
        guard snapshot.shelves.contains(where: { !HomeShelfID.local.contains($0.id) }) else { return false }
        apply(snapshot)
        return true
    }

    /// Refreshes and returns when it is over (pull to refresh, Retry).
    /// `force` asks every list again, fresh or not, and every host, even
    /// one that just failed.
    public func refresh(force: Bool = false) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            feed.refresh(force: force) { continuation.resume() }
        }
    }

    /// Recomputes the local shelves (resume cards, the user's shows, the
    /// watchlist): no request, unless the user's titles changed what the
    /// page reads (`HomeFeed.refreshLocal`).
    public func refreshLocal() {
        feed.refreshLocal()
    }

    public func shelf(_ id: String) -> HomeShelf? {
        return id == HomeShelfID.hero ? nil : shelves.first { $0.id == id }
    }

    /// Only what changed is assigned: a view that reads `shelves` is not
    /// invalidated when `isRefreshing` flips.
    private func apply(_ snapshot: HomeSnapshot) {
        let rows = snapshot.rows, hero = snapshot.heroItems
        if shelves != rows { shelves = rows }
        if heroItems != hero { heroItems = hero }
        if isRefreshing != snapshot.isRefreshing { isRefreshing = snapshot.isRefreshing }
        if lastUpdated != snapshot.lastUpdated { lastUpdated = snapshot.lastUpdated }
        if isOffline != snapshot.isOffline { isOffline = snapshot.isOffline }
        if isUnavailable != snapshot.isUnavailable { isUnavailable = snapshot.isUnavailable }
        if !hasLoaded { hasLoaded = true }
    }
}
