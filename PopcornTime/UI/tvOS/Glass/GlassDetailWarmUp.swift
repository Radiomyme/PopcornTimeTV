// GlassDetailWarmUp.swift — SwiftUI's first layout of a title's page, done
// once at a still moment after launch instead of under the first press on
// a poster.
import UIKit
import SwiftUI

/// The first title page of a launch cost SwiftUI about a second before
/// anything moved: 860 to 930 ms between the press and the page's first
/// layout on the tvOS 26.5 simulator, against 120 ms for every page after
/// it (the page's view types, fonts and glass materials are set up on
/// first use). The loading screen of 5.2 hid that second; a page that
/// opens at once would freeze the grid under the press instead.
///
/// So a page is laid out once ahead: a mock one — a show with every
/// section — in a hosting view put behind the app's screens (nothing of it
/// shows, it takes neither the focus nor VoiceOver), then taken away. It
/// costs that second once, at a moment the app is still: no press for a
/// while, nothing presented, no screen sliding. A page opened before that
/// moment pays it itself, as before, and the warm-up is dropped.
enum GlassDetailWarmUp {

    /// Not before the first screen has been up this long.
    private static let firstDelay: TimeInterval = 2.5
    /// The focus has not moved for this long: the user is not navigating.
    private static let stillness: TimeInterval = 1
    private static let retryDelay: TimeInterval = 1
    private static let maxAttempts = 40

    private static var isDone = false
    private static var lastFocusMove = ProcessInfo.processInfo.systemUptime
    private static var focusObserver: NSObjectProtocol?

    /// A title's page was made: SwiftUI has laid one out (or is about to),
    /// nothing is left to do ahead.
    static func pageWasMade() {
        isDone = true
        stopObserving()
    }

    /// Lays a page out once `window` has been still for a moment.
    static func schedule(in window: UIWindow) {
        guard !isDone, focusObserver == nil else { return }
        focusObserver = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { _ in
            lastFocusMove = ProcessInfo.processInfo.systemUptime
        }
        attempt(in: window, after: firstDelay, left: maxAttempts)
    }

    private static func stopObserving() {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
    }

    private static func attempt(in window: UIWindow, after delay: TimeInterval, left: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
            guard !isDone, let window else { return }
            guard left > 0 else { return stopObserving() }
            guard isStill(window) else { return attempt(in: window, after: retryDelay, left: left - 1) }
            run(in: window)
        }
    }

    /// Nothing presented (the Terms of Service, the release notes, a menu),
    /// no screen sliding in, no press for a moment, the app in front.
    private static func isStill(_ window: UIWindow) -> Bool {
        guard UIApplication.shared.applicationState == .active,
              let root = window.rootViewController, root.presentedViewController == nil,
              ProcessInfo.processInfo.systemUptime - lastFocusMove >= stillness else { return false }
        let selected = (root as? UITabBarController)?.selectedViewController
        return selected?.transitionCoordinator == nil
    }

    private static func run(in window: UIWindow) {
        isDone = true
        stopObserving()
        let started = ProcessInfo.processInfo.systemUptime
        let host = UIHostingController(rootView: GlassDetailView(model: mockPage()))
        host.view.frame = window.bounds
        // Behind every screen, out of the focus engine's and VoiceOver's reach.
        host.view.isUserInteractionEnabled = false
        host.view.accessibilityElementsHidden = true
        window.insertSubview(host.view, at: 0)
        host.view.layoutIfNeeded()
        print("[Detail] page warm-up: \(Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())) ms")
        // One frame drawn (the glass materials), then gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { host.view.removeFromSuperview() }
    }

    /// A page with every kind of view a real one has: the hero's chips and
    /// buttons, season pills, episode cards, related titles, people, the
    /// information cards. No image is loaded (no URL).
    private static func mockPage() -> GlassDetailModel {
        let episodes = (1...3).map { number in
            GlassEpisode(id: "warm-\(number)", season: 1, number: number, title: "Episode", summary: "Summary",
                         stillURL: nil, detail: "42 min", isWatched: number == 1, progress: number == 2 ? 0.4 : nil, download: .idle)
        }
        let model = GlassDetailModel(kind: .show,
                                     title: "Title",
                                     metadata: ["2026", "2 Seasons", "Drama"],
                                     certification: "PG-13",
                                     rating: 4,
                                     badges: [GlassBadge(text: "4K"), GlassBadge(text: "Dolby Vision")],
                                     summary: String(repeating: "A summary long enough to be cut at three lines. ", count: 8),
                                     play: GlassPlayInfo(season: 1, episode: 2, progress: 0.4),
                                     hasTrailer: true,
                                     isWatched: false,
                                     download: .idle,
                                     seasons: [1, 2],
                                     selectedSeason: 1,
                                     episodes: episodes,
                                     upNextEpisodeID: "warm-2",
                                     related: [GlassRelatedItem(id: "warm-a", title: "Title", subtitle: "2026", posterURL: nil),
                                               GlassRelatedItem(id: "warm-b", title: "Title", subtitle: "2025", posterURL: nil)],
                                     people: [GlassPerson(id: "warm-p", name: "First Last", role: "Role", imageURL: nil)],
                                     information: [GlassInfoRow(key: "Genre", value: "Drama")],
                                     accessibility: [GlassInfoRow(key: "SDH", value: "Subtitles")])
        model.sources = .partial
        return model
    }
}
