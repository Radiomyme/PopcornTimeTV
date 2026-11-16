// HomeHeroPager.swift — the rules of the Home's carousel (iOS and macOS):
// which page comes next, when the carousel may turn by itself, and which
// page stays in front when the featured titles change under it. No SwiftUI:
// the view asks, the rules answer (unit-tested).
import Foundation

struct HomeHeroPager: Equatable {

    /// How long a page stays in front before the carousel turns.
    static let interval: TimeInterval = 7

    /// Ids of the pages, in order.
    var pages: [String]
    /// The page in front (nil: none yet — the first one).
    var current: String?

    /// The user holds or drags the carousel.
    var isTouched = false
    /// The pointer is over the carousel (Mac, iPad with a trackpad).
    var isHovered = false
    /// The system's Reduce Motion setting.
    var reducesMotion = false
    /// The carousel is on screen (it scrolled away, another tab or a page
    /// covers it, the app is in the background: false).
    var isVisible = true

    init(pages: [String] = [], current: String? = nil) {
        self.pages = pages
        self.current = current
    }

    /// The page in front: `current` while it is one of the pages, else the
    /// first.
    var front: String? {
        if let current, pages.contains(current) { return current }
        return pages.first
    }

    var frontIndex: Int {
        front.flatMap(pages.firstIndex(of:)) ?? 0
    }

    /// The carousel turns by itself: more than one page, nobody holding it
    /// or pointing at it, on screen, and motion not reduced (a page that
    /// slides away under a reader who asked for less motion is exactly what
    /// the setting is for).
    var autoAdvances: Bool {
        pages.count > 1 && !isTouched && !isHovered && !reducesMotion && isVisible
    }

    /// The page after the one in front, the first after the last; nil when
    /// there is nothing to turn to.
    var next: String? {
        guard pages.count > 1 else { return nil }
        return pages[(frontIndex + 1) % pages.count]
    }

    /// The page before the one in front, the last before the first.
    var previous: String? {
        guard pages.count > 1 else { return nil }
        return pages[(frontIndex + pages.count - 1) % pages.count]
    }

    /// The featured titles changed (a refresh): the page in front stays in
    /// front when it is still featured; otherwise the carousel goes back to
    /// its first page.
    mutating func update(pages newPages: [String]) {
        pages = newPages
        if let current, !newPages.contains(current) { self.current = nil }
    }
}
