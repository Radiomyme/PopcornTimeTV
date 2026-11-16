//
//  HomeCursorTests.swift
//  PopcornTimeTests
//
//  The Home under a keyboard and a pointer (the Mac; PopcornTime/UI/Shared SwiftUI/Home): where
//  the arrow keys go (`HomeCursor`), how a shelf pages under its chevrons and shows the
//  keyboard's card (`HomeShelfPaging`), what Return, Space and Escape act on and what the page is
//  told (`HomeControls`), and the links the Mac reads as the iOS app does (`AppLinkAction`: the
//  Mac's sections have the iOS tabs' names).
//

import Foundation
import XCTest
@testable import PopcornKit

final class HomeCursorTests: CheckedTestCase {

    // MARK: - Support

    private let rows = [
        HomeCursor.Row(id: "resume", items: ["r1", "r2"]),
        HomeCursor.Row(id: "movies", items: ["m1", "m2", "m3", "m4", "m5"]),
        HomeCursor.Row(id: "empty", items: []),
        HomeCursor.Row(id: "shows", items: ["s1", "s2", "s3"]),
    ]

    private func card(_ shelf: String, _ item: String) -> HomeCursorCard {
        HomeCursorCard(shelf: shelf, item: item)
    }

    private func item(_ id: String, kind: HomeItem.Kind = .movie) -> HomeItem {
        HomeItem(id: id, imdbId: id, kind: kind, title: "Title \(id)")
    }

    private var shelves: [HomeShelf] {
        [HomeShelf(id: HomeShelfID.continueWatching, style: .landscape, items: [item("tt1"), item("tt2")]),
         HomeShelf(id: HomeShelfID.trendingMovies, style: .posters, items: [item("tt3"), item("tt4"), item("tt5")]),
         HomeShelf(id: HomeShelfID.trendingShows, style: .posters, items: [item("tt6", kind: .show)])]
    }

    private var hero: [HomeItem] { [item("tt8"), item("tt9", kind: .show), item("tt3")] }

    // MARK: - Arrow keys

    func testArrowsFromTheCarousel() {
        var cursor = HomeCursor()
        eq(cursor.card, nil, "the keyboard starts on the carousel")
        eq(cursor.press(.right, rows: rows, hasHero: true), .turnHero(forward: true), "→ turns the carousel")
        eq(cursor.press(.left, rows: rows, hasHero: true), .turnHero(forward: false), "← turns it back")
        eq(cursor.card, nil, "… and the keyboard stays on it")
        eq(cursor.press(.up, rows: rows, hasHero: true), .ignored, "↑ from the top is not the page's key")

        eq(cursor.press(.down, rows: rows, hasHero: true), .moved(card("resume", "r1")), "↓ goes to the first shelf's first card")
        eq(cursor.card, card("resume", "r1"), "the keyboard is on it")
        eq(cursor.press(.up, rows: rows, hasHero: true), .moved(nil), "↑ from the first shelf: back on the carousel")
        eq(cursor.card, nil, "no card any more")

        // A page without a carousel (hidden in the settings).
        var plain = HomeCursor()
        eq(plain.press(.right, rows: rows, hasHero: false), .moved(card("resume", "r1")), "no carousel: → starts on the first shelf")
        eq(plain.press(.up, rows: rows, hasHero: false), .stayed, "… and ↑ from the first shelf stays there")
        var nothing = HomeCursor()
        eq(nothing.press(.down, rows: [], hasHero: true), .ignored, "no shelf: ↓ has nowhere to go")
        eq(nothing.press(.right, rows: [HomeCursor.Row(id: "empty", items: [])], hasHero: false), .ignored, "an empty shelf is no shelf")
    }

    func testArrowsAlongAndAcrossShelves() {
        var cursor = HomeCursor()
        _ = cursor.press(.down, rows: rows, hasHero: true)
        eq(cursor.press(.left, rows: rows, hasHero: true), .stayed, "← on a shelf's first card: nothing moves, the key is still the page's")
        eq(cursor.press(.right, rows: rows, hasHero: true), .moved(card("resume", "r2")), "→ walks along the shelf")
        eq(cursor.press(.right, rows: rows, hasHero: true), .stayed, "… and stops on its last card")

        eq(cursor.press(.down, rows: rows, hasHero: true), .moved(card("movies", "m1")), "↓: the next shelf, on its first card")
        _ = cursor.press(.right, rows: rows, hasHero: true)
        _ = cursor.press(.right, rows: rows, hasHero: true)
        eq(cursor.card, card("movies", "m3"), "two cards further")
        eq(cursor.press(.down, rows: rows, hasHero: true), .moved(card("shows", "s1")), "↓ skips a shelf without cards")
        eq(cursor.press(.down, rows: rows, hasHero: true), .stayed, "the last shelf: ↓ stays")
        eq(cursor.press(.up, rows: rows, hasHero: true), .moved(card("movies", "m3")), "↑: a shelf comes back on the card it was left on")
        eq(cursor.press(.up, rows: rows, hasHero: true), .moved(card("resume", "r2")), "… each shelf its own")

        // A shelf the keyboard has not been on is entered where the user scrolled it to.
        var fresh = HomeCursor()
        eq(fresh.press(.down, rows: rows, hasHero: true, leading: { $0 == "resume" ? "r2" : nil }), .moved(card("resume", "r2")),
           "a shelf scrolled sideways is entered on its leading card")
        eq(fresh.press(.down, rows: rows, hasHero: true, leading: { _ in "gone" }), .moved(card("movies", "m1")),
           "a leading card that is not in the shelf any more: its first card")
    }

    func testArrowsStartFromThePointer() {
        var cursor = HomeCursor()
        eq(cursor.press(.right, rows: rows, hasHero: true, pointer: card("movies", "m2")), .moved(card("movies", "m3")),
           "no card under the keyboard: the keys start from the card under the pointer")
        eq(cursor.press(.right, rows: rows, hasHero: true, pointer: card("shows", "s1")), .moved(card("movies", "m4")),
           "once the keyboard is on a card, the pointer no longer matters")
        var stale = HomeCursor()
        eq(stale.press(.right, rows: rows, hasHero: true, pointer: card("movies", "gone")), .turnHero(forward: true),
           "a pointer on a card that is gone starts nothing")
    }

    func testTheCursorFollowsTheShelves() {
        var cursor = HomeCursor()
        cursor.move(to: card("movies", "m4"))
        cursor.reconcile(rows: rows)
        eq(cursor.card, card("movies", "m4"), "nothing changed: the keyboard stays")
        cursor.reconcile(rows: [HomeCursor.Row(id: "movies", items: ["m1", "m2"])])
        eq(cursor.card, card("movies", "m1"), "its card left the shelf: the shelf's first card")
        cursor.reconcile(rows: [HomeCursor.Row(id: "shows", items: ["s1"])])
        eq(cursor.card, nil, "its shelf left the page: back on the carousel")
        cursor.reconcile(rows: [])
        eq(cursor.card, nil, "nothing to do without a card")
    }

    // MARK: - Shelves

    func testShelfPaging() {
        // The Mac's wide layout in a 1,400-point window (1,210 for the page).
        let layout = HomeLayout(width: 1210, height: 874, sizeClass: .wide)
        let posters = HomeShelfPaging.wholeCards(row: layout.width - layout.sideInset, card: layout.posterWidth, spacing: layout.cardSpacing)
        let landscape = HomeShelfPaging.wholeCards(row: layout.width - layout.sideInset, card: layout.landscapeWidth, spacing: layout.cardSpacing)
        let ranked = HomeShelfPaging.wholeCards(row: layout.width - layout.sideInset, card: layout.rankedCardWidth, spacing: layout.cardSpacing)
        eq(posters, 6, "six posters show whole")
        eq(landscape, 3, "three 16:9 cards")
        check(ranked >= 2 && ranked < posters, "fewer ranked cards than posters: \(ranked)")
        check(layout.rankedCardWidth > layout.rankedPosterWidth, "a ranked card is its numeral and its poster")
        eq(HomeShelfPaging.wholeCards(row: 100, card: 164, spacing: 18), 1, "never less than one card")
        eq(HomeShelfPaging.wholeCards(row: 1000, card: 0, spacing: 18), 1, "no size, one card")

        // The chevrons: a screenful at a time, the last page ends on the last card.
        eq(HomeShelfPaging.page(from: 0, forward: true, count: 20, whole: 6), 6, "forward: the next six")
        eq(HomeShelfPaging.page(from: 6, forward: true, count: 20, whole: 6), 12, "again")
        eq(HomeShelfPaging.page(from: 12, forward: true, count: 20, whole: 6), 14, "the last page shows the last six cards")
        eq(HomeShelfPaging.page(from: 14, forward: true, count: 20, whole: 6), 14, "at the end: it stays")
        eq(HomeShelfPaging.page(from: 14, forward: false, count: 20, whole: 6), 8, "back: six before")
        eq(HomeShelfPaging.page(from: 2, forward: false, count: 20, whole: 6), 0, "never before the first card")
        eq(HomeShelfPaging.page(from: 0, forward: true, count: 4, whole: 6), 0, "a shelf that fits does not page")

        // The keyboard's card is shown whole with the least movement.
        eq(HomeShelfPaging.reveal(3, leading: 0, whole: 6), 0, "already whole: the shelf does not move")
        eq(HomeShelfPaging.reveal(5, leading: 0, whole: 6), 0, "the last whole card too")
        eq(HomeShelfPaging.reveal(6, leading: 0, whole: 6), 1, "the cut card: one card further")
        eq(HomeShelfPaging.reveal(9, leading: 0, whole: 6), 4, "further: it becomes the last whole card")
        eq(HomeShelfPaging.reveal(2, leading: 5, whole: 6), 2, "before the leading card: it becomes the leading card")
    }

    // MARK: - Keys

    @MainActor
    func testKeysOfThePage() {
        let controls = HomeControls()
        controls.heroFront = "tt9"

        // On the carousel.
        eq(controls.press(.right, shelves: shelves, heroItems: hero), .handled, "→ is the page's")
        eq(controls.heroTurn, HomeControls.HeroTurn(count: 1, forward: true), "the carousel is asked to turn forward")
        eq(controls.press(.left, shelves: shelves, heroItems: hero), .handled, "←")
        eq(controls.heroTurn, HomeControls.HeroTurn(count: 2, forward: false), "… back, as a new request")
        eq(controls.press(.right, shelves: shelves, heroItems: [hero[0]]), .ignored, "one page does not turn: the key is not taken")
        eq(controls.press(.up, shelves: shelves, heroItems: hero), .ignored, "↑ at the top is left to the system")
        eq(controls.press(.cancel, shelves: shelves, heroItems: hero), .ignored, "Escape with no card picked is not the page's")
        eq(controls.press(.open, shelves: shelves, heroItems: hero),
           .pick(HomeControls.Pick(item: hero[1], shelfID: HomeShelfID.hero, plays: false)), "Return opens the carousel's page in front")
        eq(controls.press(.play, shelves: shelves, heroItems: hero), .ignored,
           "Space with no card picked is the scroll view's: the carousel turning by itself picks nothing to play")
        controls.heroFront = nil
        eq(controls.press(.open, shelves: shelves, heroItems: hero),
           .pick(HomeControls.Pick(item: hero[0], shelfID: HomeShelfID.hero, plays: false)), "no page told yet: the first")
        eq(controls.press(.open, shelves: [], heroItems: []), .ignored, "an empty page opens nothing")

        // The page scrolled past its carousel: it takes no key for a title out of sight.
        controls.isPastHero = true
        eq(controls.press(.play, shelves: shelves, heroItems: hero), .ignored, "Space plays nothing while the carousel is out of sight")
        eq(controls.press(.open, shelves: shelves, heroItems: hero), .ignored, "nor does Return open it")
        eq(controls.press(.right, shelves: shelves, heroItems: hero), .ignored, "nor do the arrows turn it")
        eq(controls.heroTurn.count, 2, "no turn was asked")
        controls.isPastHero = false
        controls.heroShows = false
        eq(controls.press(.play, shelves: shelves, heroItems: hero), .ignored, "nor while it shows too little of itself")
        controls.heroShows = true

        // Down to the shelves.
        eq(controls.press(.down, shelves: shelves, heroItems: hero), .handled, "↓")
        eq(controls.cursorCard, HomeCursorCard(shelf: HomeShelfID.continueWatching, item: "tt1"), "the keyboard is on the first resume card")
        eq(controls.press(.open, shelves: shelves, heroItems: hero),
           .pick(HomeControls.Pick(item: shelves[0].items[0], shelfID: HomeShelfID.continueWatching, plays: true)),
           "Return on a Continue Watching card resumes, as a click does")
        _ = controls.press(.down, shelves: shelves, heroItems: hero)
        _ = controls.press(.right, shelves: shelves, heroItems: hero)
        eq(controls.cursorCard, HomeCursorCard(shelf: HomeShelfID.trendingMovies, item: "tt4"), "the second poster of the next shelf")
        eq(controls.press(.open, shelves: shelves, heroItems: hero),
           .pick(HomeControls.Pick(item: shelves[1].items[1], shelfID: HomeShelfID.trendingMovies, plays: false)), "Return opens a poster's page")
        eq(controls.press(.play, shelves: shelves, heroItems: hero),
           .pick(HomeControls.Pick(item: shelves[1].items[1], shelfID: HomeShelfID.trendingMovies, plays: true)), "Space plays it")
        eq(controls.press(.right, shelves: shelves, heroItems: hero), .handled, "→")
        eq(controls.press(.right, shelves: shelves, heroItems: hero), .handled, "→ at the end of a shelf is still the page's key")
        eq(controls.cursorCard, HomeCursorCard(shelf: HomeShelfID.trendingMovies, item: "tt5"), "… and the keyboard stays on the last card")

        // The shelves change under the keyboard.
        var fewer = shelves
        fewer[1].items.removeLast()
        controls.shelvesChanged(fewer)
        eq(controls.cursorCard, HomeCursorCard(shelf: HomeShelfID.trendingMovies, item: "tt3"), "its card is gone: the shelf's first")

        // Escape.
        eq(controls.press(.cancel, shelves: shelves, heroItems: hero), .handled, "Escape takes the keyboard off its card")
        eq(controls.cursorCard, nil, "no card")
    }

    @MainActor
    func testThePointerAndTheRequests() {
        let controls = HomeControls()
        let poster = HomeCursorCard(shelf: HomeShelfID.trendingMovies, item: "tt5")
        controls.pointer(true, on: poster)
        eq(controls.press(.play, shelves: shelves, heroItems: hero), .ignored,
           "Space does not play a card the pointer only rests on: it is left to the scroll view")
        eq(controls.press(.open, shelves: shelves, heroItems: hero),
           .pick(HomeControls.Pick(item: shelves[1].items[2], shelfID: HomeShelfID.trendingMovies, plays: false)),
           "Return opens the page of the card under the pointer")
        let resume = HomeCursorCard(shelf: HomeShelfID.continueWatching, item: "tt1")
        controls.pointer(true, on: resume)
        eq(controls.press(.open, shelves: shelves, heroItems: hero),
           .pick(HomeControls.Pick(item: shelves[0].items[0], shelfID: HomeShelfID.continueWatching, plays: false)),
           "a resume card under the pointer: Return opens its page, a click resumes")
        controls.pageHidden()
        eq(controls.pointerCard, nil, "the page went out of sight: no card is under the pointer any more")
        eq(controls.press(.open, shelves: shelves, heroItems: hero),
           .pick(HomeControls.Pick(item: hero[0], shelfID: HomeShelfID.hero, plays: false)),
           "back on the page, Return is the carousel's, not the card the pointer left")
        controls.pointer(true, on: poster)
        eq(controls.press(.left, shelves: shelves, heroItems: hero), .handled, "the arrows start from it")
        eq(controls.cursorCard, HomeCursorCard(shelf: HomeShelfID.trendingMovies, item: "tt4"), "one card to its left")
        controls.pointer(true, on: HomeCursorCard(shelf: HomeShelfID.trendingShows, item: "tt6"))
        eq(controls.press(.open, shelves: shelves, heroItems: hero),
           .pick(HomeControls.Pick(item: shelves[1].items[1], shelfID: HomeShelfID.trendingMovies, plays: false)),
           "the keyboard's card comes before the pointer's")
        controls.pointer(false, on: poster)
        eq(controls.pointerCard, HomeCursorCard(shelf: HomeShelfID.trendingShows, item: "tt6"), "leaving another card changes nothing")
        controls.pointer(false, on: HomeCursorCard(shelf: HomeShelfID.trendingShows, item: "tt6"))
        eq(controls.pointerCard, nil, "the pointer left its card")
        controls.pointer(true, on: poster)
        controls.shelvesChanged([shelves[0]])
        eq(controls.pointerCard, nil, "a card that left the page is not under the pointer any more")
        eq(controls.cursorCard, nil, "nor under the keyboard")

        // The card whose page is asked ahead.
        controls.pointer(true, on: poster)
        eq(controls.warmCard, poster, "the keyboard on no card: the pointer's")
        controls.moveCursor(to: HomeCursorCard(shelf: HomeShelfID.continueWatching, item: "tt1"))
        eq(controls.warmCard, HomeCursorCard(shelf: HomeShelfID.continueWatching, item: "tt1"), "the keyboard's comes first")
        eq(controls.press(.cancel, shelves: shelves, heroItems: hero), .handled, "Escape")
        eq(controls.warmCard, poster, "the keyboard off its card: back to the card still under the pointer")
        controls.pointer(false, on: poster)
        eq(controls.warmCard, nil, "neither: nothing")

        // What the host asks of the page.
        let before = controls.keyboardRequests
        controls.requestKeyboard()
        eq(controls.keyboardRequests, before + 1, "each request is a new value")
        controls.show(shelf: HomeShelfID.uhd)
        controls.show(shelf: HomeShelfID.uhd)
        eq(controls.shelfRequest, HomeControls.ShelfRequest(count: 2, shelf: HomeShelfID.uhd), "the same shelf asked twice is asked twice")
        controls.moveCursor(to: HomeCursorCard(shelf: HomeShelfID.continueWatching, item: "tt2"))
        eq(controls.press(.up, shelves: shelves, heroItems: hero), .handled, "↑ from the first shelf")
        eq(controls.cursorCard, nil, "back on the carousel")
        check(controls.scrollsAnimated, "the page glides unless a host says otherwise")
    }

    // MARK: - Links

    /// The Mac shows a link's tab as the section of the same name (`MacNavigator.open(url:)`
    /// builds its `MacSection` from the tab's raw value).
    func testLinksNameTheMacSections() {
        let sections = ["home", "movies", "shows", "watchlist", "search"]
        eq(AppTab.allCases.map(\.rawValue), sections, "the iOS tabs are the Mac's sections, in sidebar order")
        eq(AppLinkAction(url: URL(string: "popcorntime://tab/home")!), .tab(.home), "tab/home")
        eq(AppLinkAction(url: URL(string: "popcorntime://tab/watchlist")!), .tab(.watchlist), "tab/watchlist")
        eq(AppLinkAction(url: URL(string: "popcorntime://tab/settings")!), .settings, "tab/settings: the Settings window")
        eq(AppLinkAction(url: URL(string: "popcorntime://tab/downloads")!), nil, "no Downloads on the Mac either")
        eq(AppLinkAction(url: URL(string: "popcorntime://search?q=dune")!), .search("dune"), "a search")
        eq(AppLinkAction(url: URL(string: "popcorntime://trakt?code=1&state=2")!), nil, "Trakt's redirect is not a link to a page")
        eq(AppLinkAction(url: URL(string: "popcorntime://play/show/tt0903747?season=2&episode=5")!),
           .page(kind: .show, id: "tt0903747", title: nil, request: MediaPageRequest(autoPlay: true, season: 2, episode: 5, fromLink: true)),
           "a link that plays an episode carries its request")
        eq(AppLinkAction(url: URL(string: "popcorntime://movie/tt1160419?title=Dune")!),
           .page(kind: .movie, id: "tt1160419", title: "Dune", request: MediaPageRequest(fromLink: true)), "a movie's page, its title while it loads")
    }
}
