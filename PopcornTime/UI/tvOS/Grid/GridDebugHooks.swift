// GridDebugHooks.swift — simulator verification hooks of the Apple TV grids,
// compiled only with DEBUG (the app targets do not define it: build with
// SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG, like the hooks of SceneDelegate).
// Nothing happens without their launch arguments.
#if DEBUG
import UIKit
import PopcornKit

/// What the UI tests cannot produce with a remote: a list that fails, a
/// saved first page that differs from the network's, a late answer.
///
/// - `-PTDebugFailPages 2,3`: the Movies / Shows grid's load of each of
///   these pages fails once, as offline; asked again (Retry), it loads.
///   Page 1 failing also skips the list saved on disk (an empty grid).
/// - `-PTDebugStaleSnapshot YES`: the saved first pages count as old (the
///   network is asked again) and the one painted is reversed, so the
///   network's list always differs from it and replaces it.
/// - `-PTDebugFirstPageDelay <seconds>`: the network's first page reaches
///   the grid that much later (time to move the focus on the saved one).
/// - `-PTDebugWatchlist "movie|tt0816692|Interstellar|2014|8.7|169;show|…"`
///   (kind | IMDb id | title | year | rating | minutes), with
///   `-PTDebugLibraryInMemory YES` only: these titles are in the watchlist
///   for this launch, in that order (nothing is stored).
/// - `-PTDebugPosterPlayDryRun YES` (`CollectionViewController`): Play in a
///   poster's menu and Play/Pause on a poster only log; nothing opens,
///   nothing plays.
/// - `-PTDebugHitches <seconds>`: counts the frames the main thread
///   delivered late, from that many seconds after the launch on
///   (`GridHitchMonitor`): once the grid is up, while a test scrolls it.
enum GridDebugHooks {

    private static var pagesToFail: Set<Int> = {
        let pages = UserDefaults.standard.string(forKey: "PTDebugFailPages") ?? ""
        return Set(pages.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }()

    /// True once per page listed in `-PTDebugFailPages`.
    static func fails(page: Int) -> Bool {
        return pagesToFail.remove(page) != nil
    }

    /// The error of a failed page: offline.
    static let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                 userInfo: [NSLocalizedDescriptionKey: "PTDebugFailPages"])

    static let staleSnapshot = UserDefaults.standard.bool(forKey: "PTDebugStaleSnapshot")

    private static var didExpire = false

    /// Before a first page loads: with `-PTDebugStaleSnapshot`, every saved
    /// list is asked to the network again.
    static func prepareFirstPage() {
        guard staleSnapshot, !didExpire else { return }
        didExpire = true
        PopcornKit.refreshCatalogs()
    }

    /// The saved list to paint: reversed with `-PTDebugStaleSnapshot`.
    static func snapshot<Item>(_ items: [Item]) -> [Item] {
        return staleSnapshot ? Array(items.reversed()) : items
    }

    /// Runs `work` now, or `-PTDebugFirstPageDelay` seconds later.
    static func afterFirstPageDelay(_ work: @escaping () -> Void) {
        let delay = UserDefaults.standard.double(forKey: "PTDebugFirstPageDelay")
        guard delay > 0 else { return work() }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static var didFillWatchlist = false

    /// `-PTDebugWatchlist`: before the Watchlist tab reads its list.
    static func fillWatchlistIfAsked() {
        let defaults = UserDefaults.standard
        guard !didFillWatchlist, defaults.bool(forKey: "PTDebugLibraryInMemory"),
              let titles = defaults.string(forKey: "PTDebugWatchlist") else { return }
        didFillWatchlist = true
        for title in titles.split(separator: ";") {
            let fields = title.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 6 else {
                print("[Debug] watchlist: \(title) is not kind|id|title|year|rating|minutes")
                continue
            }
            let meta: [String: Any] = ["id": fields[1], "name": fields[2], "releaseInfo": fields[3], "imdbRating": fields[4],
                                       "runtime": fields[5] + " min",
                                       "poster": "https://images.metahub.space/poster/medium/\(fields[1])/img"]
            if fields[0] == "movie", let movie = Movie(cinemeta: meta) {
                WatchlistManager<Movie>.movie.add(movie)
            } else if fields[0] == "show", let show = Show(cinemeta: meta) {
                WatchlistManager<Show>.show.add(show)
            }
        }
    }

    /// Shows `text` to the UI tests under `identifier` (a one-point label
    /// in the window's corner, like `Debug.LinkResult`).
    static func report(_ text: String, as identifier: String) {
        guard let window = AppDelegate.shared.window else { return }
        let label = window.subviews.compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == identifier } ?? {
            let label = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            label.accessibilityIdentifier = identifier
            label.textColor = .clear
            window.addSubview(label)
            return label
        }()
        label.text = text
        window.bringSubviewToFront(label)
    }
}

/// Late frames, without Instruments: a display link on the main run loop
/// measures the time between two frames it is given. A frame that comes
/// more than half a frame late is a hitch; what is reported is what Apple's
/// "hitch time ratio" counts: the milliseconds of lateness per second.
///
/// The count starts `-PTDebugHitches` seconds after the launch (the launch
/// itself, the first page and its posters are not what is measured). Its
/// total is printed every 5 s ("[Hitches] …") and shown to the UI tests
/// under `Debug.Hitches`.
final class GridHitchMonitor: NSObject {

    static let shared = GridHitchMonitor()

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var lateness: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var lastReport: CFTimeInterval = 0

    static func startIfAsked() {
        guard UserDefaults.standard.object(forKey: "PTDebugHitches") != nil else { return }
        let delay = max(0, UserDefaults.standard.double(forKey: "PTDebugHitches"))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { shared.start() }
    }

    private func start() {
        guard link == nil else { return }
        started = CACurrentMediaTime()
        lastReport = started
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        GridDebugHooks.report(summary, as: "Debug.Hitches")
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let interval = link.timestamp - last
        let expected = link.duration > 0 ? link.duration : 1.0 / 60
        frames += 1
        if interval > expected * 1.5 {
            hitches += 1
            lateness += interval - expected
            worst = max(worst, interval)
        }
        // Once a second for the tests (a label set at every frame would be
        // part of what is measured), every 5 s in the console.
        let now = CACurrentMediaTime()
        guard now - lastReport >= 1 else { return }
        lastReport = now
        GridDebugHooks.report(summary, as: "Debug.Hitches")
        if Int(now - started) % 5 == 0 { print("[Hitches] \(summary)") }
    }

    /// "frames=1180 seconds=20.0 hitches=12 worst=83ms late=24.5ms/s".
    var summary: String {
        let seconds = max(0.001, CACurrentMediaTime() - started)
        return String(format: "frames=%d seconds=%.1f hitches=%d worst=%.0fms late=%.1fms/s",
                      frames, seconds, hitches, worst * 1000, lateness * 1000 / seconds)
    }
}
#endif
