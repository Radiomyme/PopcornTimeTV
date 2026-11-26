// HomeDebug.swift — DEBUG launch hooks of the Home tab (compiled only with
// `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`, like SceneDelegate's): what
// the UI tests and the screenshot runs use so that the page does not depend
// on what the hosts answer that day, and so that nothing is ever played.
//
//   -PTDebugHomeFixtures <folder>   the hub answers from the JSON files of
//                                   that folder (PopcornTimeTests/Fixtures/Home)
//                                   at the instant they were recorded, with a
//                                   cache of its own, emptied at launch;
//   -PTDebugHomeKeepCache YES       … not emptied (a second launch paints
//                                   from the first one's snapshot);
//   -PTDebugHomeDelay <seconds>     each answer comes that much later (the
//                                   placeholders);
//   -PTDebugHomeOffline YES         no host answers, five hours later: with a
//                                   kept cache the page is the saved one and
//                                   says so, without one it is the error page;
//   -PTDebugHomeShelfLimit <n>      n cards a shelf (See All is n presses away);
//   -PTDebugHomeHero <index>        the billboard shows that hero item and
//                                   stays on it;
//   -PTDebugHomeFocus <shelf id>[:<index>]   once the page has loaded, the
//                                   focus goes to that card of that shelf
//                                   ("<shelf id>:seeall": to its See All
//                                   card; "hero": to Play; "retry": to Try
//                                   Again on the error page);
//   -PTDebugHomeResume <entries>    titles being watched, for the Continue
//                                   Watching shelf: "<IMDb id>|<title>|
//                                   <fraction>|<runtime in minutes>" for a
//                                   movie, plus "|<season>|<episode>|<episode
//                                   title>" for an episode, entries separated
//                                   by ";". A fraction of 1 with a last field
//                                   (the next episode's title) is a finished
//                                   episode whose show continues with the
//                                   next. Only with -PTDebugLibraryInMemory
//                                   YES: nothing is written to the defaults;
//   -PTDebugHomeDryRunPlay YES      Play, Play/Pause and a resume card open
//                                   the title's page without playing; what
//                                   would have played is in the text whose
//                                   identifier is Debug.HomePlay.
//
//   -PTDebugHomeTiming YES          logs how long the saved page takes to
//                                   read and build on this device;
//   -PTDebugHomeTrace <file>        the focus moves and what the page did
//                                   with them, one line each, appended to
//                                   that file (a path of the Mac: the
//                                   simulator shares its disk).
//
// Every launch also logs when the page got its data, in seconds since the
// process started: "[Home] +1.42 s first shelves (14)".
#if DEBUG
import UIKit
import PopcornKit

@MainActor
enum HomeDebug {

    private static var defaults: UserDefaults { .standard }

    static var isDryRunPlay: Bool { defaults.bool(forKey: "PTDebugHomeDryRunPlay") }

    /// The hub the tab shows: the app's, or one fed from recorded answers.
    static func makeState() -> HomeState {
        seedResumeEntries()
        guard let folder = defaults.string(forKey: "PTDebugHomeFixtures"), !folder.isEmpty else { return .shared }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = caches.appendingPathComponent("popcornkit-home-debug", isDirectory: true)
        if !defaults.bool(forKey: "PTDebugHomeKeepCache") {
            try? FileManager.default.removeItem(at: directory)
        }
        let offline = defaults.bool(forKey: "PTDebugHomeOffline")
        // Offline, later: the saved lists are stale (asked again, in vain)
        // and none has expired.
        let now = HomeFixtures.recordedAt.addingTimeInterval(offline ? 5 * 3600 : 0)
        var options = HomeFeed.Options()
        if let limit = defaults.string(forKey: "PTDebugHomeShelfLimit").flatMap({ Int($0) }), limit > 0 {
            options.shelfLimit = limit
        }
        let transport = HomeFixtures.transport(folder: URL(fileURLWithPath: folder, isDirectory: true),
                                               delay: defaults.double(forKey: "PTDebugHomeDelay"),
                                               isOffline: { offline })
        let feed = HomeFeed(store: HomeStore(directory: directory, now: { now }), transport: transport,
                            hooks: HomeLocalHooks(libraryOf: { Library.shared }, tasteOf: { ProfileTaste.shared }, now: { now }),
                            options: options, now: { now })
        feed.followActiveProfile()
        print("[Home] hub fed from \(folder)\(offline ? ", offline" : "")")
        return HomeState(feed: feed)
    }

    /// `-PTDebugHomeResume`: titles in progress, written through the same
    /// entry point as the players, into a library kept in memory.
    private static var seeded = false

    /// Once per launch: into the profile active when the Home is first made
    /// (a Home made again for another profile does not get them).
    private static func seedResumeEntries() {
        guard !seeded else { return }
        seeded = true
        guard let entries = defaults.string(forKey: "PTDebugHomeResume"), !entries.isEmpty else { return }
        guard defaults.bool(forKey: "PTDebugLibraryInMemory") else {
            return print("[Home] -PTDebugHomeResume needs -PTDebugLibraryInMemory YES: nothing seeded")
        }
        for entry in entries.split(separator: ";") {
            let fields = entry.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 4, let fraction = Float(fields[2]), (0...1).contains(fraction) else {
                print("[Home] resume entry not read: \(entry)")
                continue
            }
            let id = fields[0], title = fields[1], runtime = Int(fields[3])
            guard fields.count >= 6, let season = Int(fields[4]), let episode = Int(fields[5]) else {
                WatchedlistManager<Movie>.movie.setCurrentProgress(fraction, for: id, with: .paused,
                                                                   details: PlaybackDetails(title: title, runtime: runtime))
                continue
            }
            let number = EpisodeNumber(season: season, episode: episode)
            let episodeTitle = fields.count > 6 ? fields[6] : nil
            // The show's guide, as its page would have noted it: what says
            // which episode comes next.
            var guide = (1...(episode + 3)).map { GuideEpisode(season: season, episode: $0, title: "Episode \($0)") }
            guide[episode - 1].title = episodeTitle
            if fields.count > 7 { guide[episode].title = fields[7] }
            WatchedlistManager<Episode>.episode.setCurrentProgress(
                fraction, for: LibraryID.episodeID(showID: id, number), with: fraction >= 1 ? .finished : .paused,
                details: PlaybackDetails(title: title, episodeTitle: episodeTitle, showID: id, number: number, runtime: runtime))
            Library.shared.noteGuide(showID: id, title: title, runtime: runtime, episodes: guide, always: true)
        }
    }

    // MARK: Hooks on the page

    static func attach(to controller: HomeHostingController) {
        mark("the tab is created")
        measureSavedPage()
        let model = controller.model
        watch(model)
        if let hero = defaults.string(forKey: "PTDebugHomeHero").flatMap({ Int($0) }) {
            model.autoAdvances = false
            whenLoaded(model) { model.showHero(hero) }
        }
        if let target = defaults.string(forKey: "PTDebugHomeFocus"), !target.isEmpty {
            model.autoAdvances = false
            whenLoaded(model) { focus(target, on: controller) }
        }
    }

    /// `work` once the page has shelves and its first refresh is over,
    /// 2.5 s after the launch at the earliest: the launch's own focus has
    /// then settled on a tab (checked four times a second, for 40 s).
    private static func whenLoaded(_ model: HomePageModel, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            for attempt in 0..<160 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let home = model.home
                if attempt >= 10, !home.shelves.isEmpty || home.isUnavailable, !home.isRefreshing { return work() }
            }
            print("[Home] debug hook: the page never loaded")
        }
    }

    /// `-PTDebugHomeFocus`: the shelf under the band first (its row is lazy),
    /// then the focus from the tab bar into the page, on that card.
    private static func focus(_ target: String, on controller: HomeHostingController) {
        let model = controller.model
        let tabBarController = controller.tabBarController as? TVTabBarController
        guard target != "hero", target != "retry" else {
            tabBarController?.moveFocus(to: controller)
            model.focusRequest = target == "hero" ? .play : .retry
            return
        }
        let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
        guard let shelf = model.home.shelf(parts[0]) else { return print("[Home] debug focus: no shelf \(parts[0])") }
        let wanted: HomeFocus
        if parts.count > 1, parts[1] == "seeall" {
            wanted = .seeAll(shelf: shelf.id)
        } else {
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            guard shelf.items.indices.contains(index) else { return print("[Home] debug focus: \(shelf.id) has \(shelf.items.count) cards") }
            wanted = .card(shelf: shelf.id, item: shelf.items[index].id)
        }
        model.scrollRequest = shelf.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            tabBarController?.moveFocus(to: controller)
            guard case .seeAll = wanted, let last = shelf.items.last else { return model.focusRequest = wanted }
            // By the shelf's last card, as the remote gets there.
            model.focusRequest = .card(shelf: shelf.id, item: last.id)
            try? await Task.sleep(nanoseconds: 900_000_000)
            model.focusRequest = wanted
        }
    }

    // MARK: Play, without playing

    /// `-PTDebugHomeDryRunPlay`: what would have played, for the UI tests —
    /// a text whose identifier is Debug.HomePlay ("tt1234567", or
    /// "tt1234567:2:9" for an episode), one point in the window's corner.
    static func notePlay(of item: HomeItem, from shelf: String?) {
        print("[Home] dry run: play \(item.id) (\(item.title)) from \(shelf ?? "the billboard")")
        note(item.id, as: "Debug.HomePlay")
    }

    /// A shelf's See All opened a grid: what that grid is now set to, for
    /// the UI tests — a text whose identifier is Debug.HomeSeeAll
    /// ("movies|seeds|All": the tab, the sort and the genre read back from
    /// the grid's controller).
    static func noteCatalogue(shown root: UIViewController, for seeAll: HomeSeeAll) {
        var state = seeAll.tab.rawValue
        if let movies = root as? MoviesViewController {
            state += "|\(movies.currentFilter.rawValue)|\(movies.currentGenre.rawValue)"
        } else if let shows = root as? ShowsViewController {
            state += "|\(shows.currentFilter.rawValue)|\(shows.currentGenre.rawValue)"
        }
        print("[Home] See All: \(state)")
        note(state, as: "Debug.HomeSeeAll")
    }

    /// The selected tab's name, for the UI tests while a page hides the
    /// tab bar (the detail page): a text whose identifier is Debug.SelectedTab.
    static func noteSelectedTab(_ name: String) {
        note(name, as: "Debug.SelectedTab")
    }

    /// A text only the UI tests read: one point in the window's corner.
    private static func note(_ text: String, as identifier: String) {
        guard let window = AppDelegate.shared.window else { return }
        let label = window.subviews.compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == identifier } ?? {
            let label = UILabel(frame: CGRect(x: 2, y: 0, width: 1, height: 1))
            label.accessibilityIdentifier = identifier
            label.textColor = .clear
            window.addSubview(label)
            return label
        }()
        label.text = text
        window.bringSubviewToFront(label)
    }

    /// `-PTDebugHomeTiming YES`: how long the saved page takes to read and
    /// build on this device — the same work as the hub's first paint, done
    /// once more on the side, 3 s after the launch (when nothing else runs),
    /// and logged.
    private static func measureSavedPage() {
        guard defaults.bool(forKey: "PTDebugHomeTiming") else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
            let start = Date()
            let snapshot = HomeFeed(store: HomeStore()).cachedSnapshot()
            let cards = snapshot.shelves.reduce(0) { $0 + $1.items.count }
            print("[Home] the saved page read and built in \(Int(Date().timeIntervalSince(start) * 1000)) ms (\(snapshot.shelves.count) shelves, \(cards) cards)")
        }
    }

    // MARK: Trace

    private static let traceFile: FileHandle? = {
        guard let path = UserDefaults.standard.string(forKey: "PTDebugHomeTrace"), !path.isEmpty else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    /// `-PTDebugHomeTrace`: one line of the page's life.
    static func trace(_ text: @autoclosure () -> String) {
        guard let traceFile else { return }
        let elapsed = Date().timeIntervalSince(processStart)
        traceFile.write(Data("+\(String(format: "%.2f", elapsed)) \(text())\n".utf8))
    }

    // MARK: Timing

    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    private static var marked = Set<String>()

    /// Logs an event of the launch once, with its time since the process
    /// started (`date`: when it happened, when that is not now).
    static func mark(_ event: String, _ detail: String = "", at date: Date = Date()) {
        guard marked.insert(event).inserted else { return }
        let elapsed = date.timeIntervalSince(processStart)
        print("[Home] +\(String(format: "%.2f", elapsed)) s \(event)\(detail.isEmpty ? "" : " (\(detail))")")
    }

    /// Follows the hub until its first refresh is over. Two times for the
    /// first data: when the hub delivered it, and when the page had taken
    /// it (the main thread free again after the views were made).
    private static func watch(_ model: HomePageModel) {
        model.backdrop.onPresent = { mark("first backdrop on screen") }
        @MainActor func look(deliveredAt: Date) {
            let home = model.home
            withObservationTracking {
                if home.hasLoaded { mark("first snapshot", "\(home.shelves.count) shelves, hero \(home.heroItems.count)", at: deliveredAt) }
                if !home.shelves.isEmpty {
                    mark("first shelves", "\(home.shelves.count)", at: deliveredAt)
                    mark("first shelves in the page")
                }
                if !home.heroItems.isEmpty { mark("first hero", "\(home.heroItems.count)", at: deliveredAt) }
                if home.isOffline { mark("offline") }
                if home.isUnavailable { mark("unavailable") }
                if home.hasLoaded, !home.isRefreshing {
                    mark("refresh over", "\(home.shelves.count) shelves: \(home.shelves.map { "\($0.id) \($0.items.count)" }.joined(separator: ", "))")
                }
            } onChange: {
                // Called as the value changes; the look comes once the page
                // has taken the change.
                let now = Date()
                Task { @MainActor in look(deliveredAt: now) }
            }
        }
        look(deliveredAt: Date())
    }
}
#endif
