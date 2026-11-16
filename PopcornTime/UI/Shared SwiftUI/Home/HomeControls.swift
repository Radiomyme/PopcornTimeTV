// HomeControls.swift — the Home under a keyboard and a pointer (the Mac):
// the card the arrow keys are on, the card under the pointer, the turns
// asked of the carousel, and what Return and Space act on. One object per
// window, owned by the host and handed to `HomeScreen`; without one (iOS)
// the screen has no cursor and takes no key.
//
// No SwiftUI: the screen and its cards observe it, the rules are
// `HomeCursor`'s (unit-tested with it).
import Foundation
import Observation
import PopcornKit

@MainActor
@Observable
final class HomeControls {

    /// A key of the page.
    enum Key: Equatable {
        case left, right, up, down
        /// Return: what a click on the card does.
        case open
        /// Space: play the title of the card the keyboard is on; on no
        /// card it is not the page's (the scroll view pages down).
        case play
        /// Escape: the keyboard leaves its card.
        case cancel
    }

    /// The card a key acts on.
    struct Pick: Equatable {
        let item: HomeItem
        let shelfID: String
        /// Play it (Space, a Continue Watching card); false: its page.
        let plays: Bool
    }

    enum Outcome: Equatable {
        /// Not the page's key: left to whatever handles it next.
        case ignored
        case handled
        case pick(Pick)
    }

    /// A turn of the carousel asked by a key: a new value each time.
    struct HeroTurn: Equatable {
        var count = 0
        var forward = true
    }

    /// A shelf the page is asked to scroll to: a new value each time.
    struct ShelfRequest: Equatable {
        var count = 0
        var shelf = ""
    }

    /// The card the arrow keys are on (drawn with a ring; its shelf and the
    /// page scroll to it); nil: the keyboard is on the carousel.
    private(set) var cursorCard: HomeCursorCard?
    private(set) var heroTurn = HeroTurn()
    private(set) var shelfRequest = ShelfRequest()
    /// Bumped by the host when the page should take the keyboard (it came
    /// in front): the screen then makes itself the key view.
    private(set) var keyboardRequests = 0
    /// Drawn as under the pointer: "hero", a shelf's id, or "<shelf
    /// id>/<item id>". Only set by verification launches (an app that is
    /// not in front gets no pointer events); a plain property, not behind
    /// `#if DEBUG`: the observation macro does not see through it.
    var shownAsHovered: String?

    /// The card under the pointer: what Return opens, and where the arrow
    /// keys start from, while the keyboard is on no card. Not observed: a
    /// pointer crossing the page must not redraw it.
    @ObservationIgnored var pointerCard: HomeCursorCard?
    /// False: the page jumps to a shelf instead of gliding to it. For a
    /// window that is not on screen (a verification launch in a locked
    /// session): it gets no frame, and a scroll animated by hand
    /// (`ScrollViewProxy.scrollTo`) would never move.
    @ObservationIgnored var scrollsAnimated = true
    /// The carousel's page in front, told by the carousel.
    @ObservationIgnored var heroFront: String?
    /// The carousel shows enough of itself, told by the carousel, and the
    /// page has not scrolled past it, told by the screen. Out of sight the
    /// carousel takes no key: Space would play a title the user is not
    /// looking at.
    @ObservationIgnored var heroShows = true
    @ObservationIgnored var isPastHero = false
    private var heroInView: Bool { heroShows && !isPastHero }
    @ObservationIgnored private var cursor = HomeCursor()

    init() {}

    /// The page takes the keyboard.
    func requestKeyboard() {
        keyboardRequests &+= 1
    }

    /// The page scrolls to a shelf (by id), its title under the top bar.
    func show(shelf id: String) {
        shelfRequest = ShelfRequest(count: shelfRequest.count &+ 1, shelf: id)
    }

    /// - Parameter leading: the card on a shelf's leading edge, by shelf id.
    func press(_ key: Key, shelves: [HomeShelf], heroItems: [HomeItem],
               leading: (String) -> String? = { _ in nil }) -> Outcome {
        switch key {
        case .left, .right, .up, .down:
            let direction: HomeCursor.Direction = key == .left ? .left : (key == .right ? .right : (key == .up ? .up : .down))
            let step = cursor.press(direction, rows: rows(of: shelves), hasHero: !heroItems.isEmpty,
                                    pointer: pointerCard, leading: leading)
            switch step {
            case .ignored:
                return .ignored
            case .stayed:
                return .handled
            case .turnHero(let forward):
                guard heroItems.count > 1, heroInView else { return .ignored }
                heroTurn = HeroTurn(count: heroTurn.count &+ 1, forward: forward)
                return .handled
            case .moved(let card):
                if cursorCard != card { cursorCard = card }
                return .handled
            }
        case .open, .play:
            guard let pick = target(shelves: shelves, heroItems: heroItems, plays: key == .play) else { return .ignored }
            return .pick(pick)
        case .cancel:
            guard cursorCard != nil else { return .ignored }
            moveCursor(to: nil)
            return .handled
        }
    }

    /// The card whose page is asked ahead (`DetailStore.prewarm`): the
    /// keyboard's, else the one under the pointer. The keyboard leaving its
    /// card (Escape, ↑ to the carousel, a refresh) gives the warm-up back to
    /// the pointer's card instead of cancelling it.
    var warmCard: HomeCursorCard? { cursorCard ?? pointerCard }

    /// The keyboard's card, else the pointer's, else the carousel's page
    /// in front while the carousel is on screen. Only the card the user
    /// moved the keyboard to plays (Space; Return on a Continue Watching
    /// card): a pointer resting on a card, or the carousel turning by
    /// itself, never starts a stream — Return opens their page, and Space
    /// is left to the scroll view.
    private func target(shelves: [HomeShelf], heroItems: [HomeItem], plays: Bool) -> Pick? {
        if let card = cursorCard, let found = find(card, in: shelves) {
            // A Continue Watching card resumes when clicked: Return too.
            return Pick(item: found.item, shelfID: found.shelf, plays: plays || found.shelf == HomeShelfID.continueWatching)
        }
        guard !plays else { return nil }
        if let card = pointerCard, let found = find(card, in: shelves) {
            return Pick(item: found.item, shelfID: found.shelf, plays: false)
        }
        guard heroInView, let item = heroItems.first(where: { $0.id == heroFront }) ?? heroItems.first else { return nil }
        return Pick(item: item, shelfID: HomeShelfID.hero, plays: false)
    }

    private func find(_ card: HomeCursorCard, in shelves: [HomeShelf]) -> (shelf: String, item: HomeItem)? {
        guard let shelf = shelves.first(where: { $0.id == card.shelf }),
              let item = shelf.items.first(where: { $0.id == card.item }) else { return nil }
        return (shelf.id, item)
    }

    /// The pointer came over a card, or left it.
    func pointer(_ inside: Bool, on card: HomeCursorCard) {
        if inside {
            pointerCard = card
        } else if pointerCard == card {
            pointerCard = nil
        }
    }

    /// The page went out of sight (a title's page pushed over it, another
    /// section): the pointer's exit from its card may never be told, and
    /// back on the page Return must not open a card the pointer left long
    /// ago. The next move over a card tells it again.
    func pageHidden() {
        pointerCard = nil
    }

    /// Puts the keyboard on a card (nil: back on the carousel).
    func moveCursor(to card: HomeCursorCard?) {
        cursor.move(to: card)
        if cursorCard != card { cursorCard = card }
    }

    /// The shelves changed: the keyboard stays on a card that is still
    /// there (`HomeCursor.reconcile`).
    func shelvesChanged(_ shelves: [HomeShelf]) {
        cursor.reconcile(rows: rows(of: shelves))
        if cursorCard != cursor.card { cursorCard = cursor.card }
        if let pointer = pointerCard, !shelves.contains(where: { $0.id == pointer.shelf && $0.items.contains { $0.id == pointer.item } }) {
            pointerCard = nil
        }
    }

    private func rows(of shelves: [HomeShelf]) -> [HomeCursor.Row] {
        shelves.map { HomeCursor.Row(id: $0.id, items: $0.items.map(\.id)) }
    }
}
