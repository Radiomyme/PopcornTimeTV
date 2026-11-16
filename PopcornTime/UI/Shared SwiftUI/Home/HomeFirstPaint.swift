// HomeFirstPaint.swift — when the Home replaces its placeholders with
// content (iOS and macOS). No SwiftUI: a rule, unit-tested.
//
// From the disk cache the hub delivers its whole page at once: it is shown
// at once. On a first load (nothing cached) the hub delivers each list as
// its host answers, within a few hundred milliseconds: the carousel is
// first made of the trending movies alone, then remade with the shows when
// their list arrives — and the movies it gives back push the Trending
// Movies row sideways; a shelf that answers before the carousel is pushed
// down by it; a row of the first screen that answers late (New Movies, New
// in 4K) is inserted above the ones already there, during the fade from
// the placeholders. Shown as they come, these are jumps under the eye. So
// a first load keeps its placeholders until the top of the page is whole —
// the carousel, the two Trending rows it is made from, and the catalogue
// rows of the first screen — or the refresh is over, or a short patience
// has run out (a host that hangs must not hold the page).
import Foundation
import PopcornKit

enum HomeFirstPaint {

    /// How long a first load waits for the top of the page, at most.
    static let patience: TimeInterval = 2.5

    /// The top of the page: what a first load waits for, less what the user
    /// hid — the carousel, the first three catalogue rows of the page's
    /// order (`HomeShelfID.order`: Trending Movies, New Movies, New in 4K),
    /// and Trending Shows, the carousel's other half (Latest Episodes, in
    /// between, is read off the same answer). The user's own rows come from
    /// the library, before any host; the rows after these come further down
    /// the page, where an insertion is not under the eye.
    static func awaited(hidden: Set<String>) -> [String] {
        [HomeShelfID.hero, HomeShelfID.trendingMovies, HomeShelfID.newMovies, HomeShelfID.uhd, HomeShelfID.trendingShows]
            .filter { !hidden.contains($0) }
    }

    /// Nothing from the hosts or the cache yet: no carousel, and no shelf
    /// but the user's own (resume cards, the watchlist: the library answers
    /// before any host does).
    static func isCold(shelves: [String], hasHero: Bool) -> Bool {
        !hasHero && shelves.allSatisfy(HomeShelfID.local.contains)
    }

    /// A first load may show what it has: the refresh is over, or the top
    /// of the page is there.
    static func isReady(shelves: [String], hasHero: Bool, isRefreshing: Bool, hidden: Set<String>) -> Bool {
        guard isRefreshing else { return true }
        var present = Set(shelves)
        if hasHero { present.insert(HomeShelfID.hero) }
        return awaited(hidden: hidden).allSatisfy(present.contains)
    }

    /// A page already shown goes back to its placeholders only when it has
    /// nothing to show — a Retry from the error page, or a refresh after
    /// an empty one. A page that shows the user's own shelves (offline,
    /// hosts down, nothing cached) keeps them, and its scroll position,
    /// through the refresh each return to the Home starts.
    static func waitsAgain(isEmpty: Bool, isCold: Bool, isReady: Bool, patienceSpent: Bool) -> Bool {
        isEmpty && isCold && !isReady && !patienceSpent
    }
}
