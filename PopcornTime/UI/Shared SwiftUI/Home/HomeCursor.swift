// HomeCursor.swift — the keyboard on the Home (the Mac today): which card
// the arrow keys are on, where each key goes from there, and how a row
// pages under its chevrons. No SwiftUI: the views ask, the rules answer
// (unit-tested).
//
// The page reads like a remote's: ← → turn the carousel while the keyboard
// is on it, ↓ goes down to the first shelf, then ← → walk along a shelf and
// ↑ ↓ change shelf — each shelf remembers the card it was left on.
import Foundation
import CoreGraphics

/// A card of a shelf, by ids.
struct HomeCursorCard: Hashable {
    let shelf: String
    let item: String
}

struct HomeCursor: Equatable {

    /// A shelf, as the cursor sees it: its id and its cards' ids, in order.
    struct Row: Equatable {
        let id: String
        let items: [String]
    }

    enum Direction {
        case left, right, up, down
    }

    /// What an arrow key did.
    enum Step: Equatable {
        /// Not the page's key here (↑ from the carousel, a page without
        /// anything to walk): left to whatever handles it next.
        case ignored
        /// The carousel turns to its next (`forward`) or previous page.
        case turnHero(forward: Bool)
        /// The keyboard is on this card now; nil: back on the carousel.
        case moved(HomeCursorCard?)
        /// The page's key, but there is nowhere to go (the end of a shelf,
        /// the last shelf): nothing moves, and nothing else takes the key.
        case stayed
    }

    /// The card the keyboard is on; nil: the carousel (the top of the page).
    private(set) var card: HomeCursorCard?
    /// The card each shelf was left on.
    private var remembered: [String: String] = [:]

    /// - Parameters:
    ///   - rows: the shelves on the page, in order.
    ///   - hasHero: the page starts with its carousel.
    ///   - pointer: the card under the pointer: where the keys start from
    ///     while the keyboard is on no card.
    ///   - leading: the card on a shelf's leading edge, by shelf id (where
    ///     the user scrolled it to): where the keyboard enters a shelf it
    ///     has not been on.
    mutating func press(_ direction: Direction, rows: [Row], hasHero: Bool, pointer: HomeCursorCard? = nil,
                        leading: (String) -> String? = { _ in nil }) -> Step {
        let rows = rows.filter { !$0.items.isEmpty }
        func place(of card: HomeCursorCard?) -> (row: Int, index: Int)? {
            guard let card, let row = rows.firstIndex(where: { $0.id == card.shelf }),
                  let index = rows[row].items.firstIndex(of: card.item) else { return nil }
            return (row, index)
        }
        func enter(_ row: Row) -> Step {
            let kept = [remembered[row.id], leading(row.id)].compactMap { $0 }.first { row.items.contains($0) }
            return move(to: HomeCursorCard(shelf: row.id, item: kept ?? row.items[0]))
        }

        guard let (row, index) = place(of: card) ?? place(of: pointer) else {
            // On the carousel, or nowhere yet.
            switch direction {
            case .left, .right:
                if hasHero { return .turnHero(forward: direction == .right) }
                return rows.first.map(enter) ?? .ignored
            case .down:
                return rows.first.map(enter) ?? .ignored
            case .up:
                return .ignored
            }
        }
        let items = rows[row].items
        switch direction {
        case .left:
            return index > 0 ? move(to: HomeCursorCard(shelf: rows[row].id, item: items[index - 1])) : .stayed
        case .right:
            return index + 1 < items.count ? move(to: HomeCursorCard(shelf: rows[row].id, item: items[index + 1])) : .stayed
        case .up:
            if row > 0 { return enter(rows[row - 1]) }
            return hasHero ? move(to: nil) : .stayed
        case .down:
            return row + 1 < rows.count ? enter(rows[row + 1]) : .stayed
        }
    }

    /// Puts the keyboard on a card (nil: back on the carousel).
    @discardableResult
    mutating func move(to card: HomeCursorCard?) -> Step {
        self.card = card
        if let card { remembered[card.shelf] = card.item }
        return .moved(card)
    }

    /// The shelves changed (a refresh, a title taken out of a shelf): a
    /// card that is gone leaves the keyboard on its shelf's first card, a
    /// shelf that is gone on the carousel.
    mutating func reconcile(rows: [Row]) {
        guard let card else { return }
        guard let row = rows.first(where: { $0.id == card.shelf }), let first = row.items.first else {
            self.card = nil
            return
        }
        if !row.items.contains(card.item) { move(to: HomeCursorCard(shelf: row.id, item: first)) }
    }
}

/// A shelf under its paging chevrons and under the keyboard: counted in
/// cards, from the card on the shelf's leading edge.
enum HomeShelfPaging {

    /// How many cards a shelf shows whole.
    /// - Parameter row: from the first card's leading edge to the trailing
    ///   edge of the page.
    static func wholeCards(row: CGFloat, card: CGFloat, spacing: CGFloat) -> Int {
        guard card > 0 else { return 1 }
        return max(1, Int(((row + spacing) / (card + spacing)).rounded(.down)))
    }

    /// The card on the leading edge after a page forward or back: a
    /// screenful further, and the last page ends on the last card.
    static func page(from leading: Int, forward: Bool, count: Int, whole: Int) -> Int {
        let last = max(0, count - whole)
        let target = forward ? leading + whole : leading - whole
        return min(max(target, 0), last)
    }

    /// The card to put on the leading edge so that `index` shows whole:
    /// `leading` itself while it already does.
    static func reveal(_ index: Int, leading: Int, whole: Int) -> Int {
        if index < leading { return index }
        if index >= leading + whole { return index - whole + 1 }
        return leading
    }
}
