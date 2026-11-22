#if DEBUG
import Foundation
import PopcornKit

/// Verification hooks of the iOS app, compiled only with DEBUG (the app
/// targets do not define it: build with
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` on the xcodebuild command
/// line). Launch arguments, as on tvOS (`SceneDelegate`) and macOS
/// (`MacDebugHooks`):
/// - `-PTDebugTab <home|movies|shows|watchlist|search>`: the tab shown at launch;
/// - `-PTDebugHomeFixtures <folder>`: the Home is fed from recorded answers
///   (`HomeRecordedTransport`; the repository's PopcornTimeTests/Fixtures/Home)
///   instead of the hosts, with its clock at the day they were recorded and
///   a cache of its own, emptied at launch. The artwork still comes from
///   its hosts;
/// - `-PTDebugHomeState <skeleton|offline|error>` (with the fixtures): the
///   page waiting for its first answers; the cached page with the offline
///   note; no answer and nothing cached. With a TMDB key, also `tmdbdown`
///   (TMDB fails, the other hosts answer: a service's page says its
///   catalogue cannot load), `tmdbrefused` (the same, and the app's TMDB
///   client refuses every key: the refused-key message and « Refused » in
///   Settings) and `tmdbsilent` (TMDB never answers: a service's page keeps
///   its placeholders);
/// - `-popcornkit.tmdb.apiKey <text>` (with the fixtures): a made-up TMDB
///   key, read from the arguments (never stored): the Home gets its
///   « Services » row. With the fixtures nothing ever reaches TMDB — the
///   hub's lists and `TMDBStreamingClient.shared` (Settings, See All) read
///   the recorded tmdb_*.json files;
/// - `-PTDebugHomeService <TMDB provider id>` (with the fixtures): the Home
///   starts filtered on that service (8: Netflix; 350 lists nothing);
/// - `-PTDebugHomeShelf <shelf id>`: the Home scrolls to that shelf
///   (`continueWatching`, `top48hMovies`…) once it is on the page;
/// - `-PTDebugHomeHeroPage <n>`: the carousel shows its n-th page (from 0)
///   and stays on it;
/// - `-PTDebugOpenURL <url>`: the URL is handed to the app's link handler a
///   second after launch, as the system would (`simctl openurl` raises a
///   dialog nobody answers); the console says « opened » or « refused »;
/// - `-PTDebugOpenMovie <IMDb id>` / `-PTDebugOpenShow <IMDb id>`: push that
///   title's page on the tab (never plays anything);
/// - `-PTDebugFilter <raw value>` (e.g. `top100`, `year`) and
///   `-PTDebugGenre <raw value>` (e.g. `Comedy`): the Movies and Shows grids'
///   sort and genre at launch;
/// - `-PTDebugSearch <text>`: typed in the Search tab's field;
/// - `-PTDebugSettings YES`: opens the Settings sheet;
///   `-PTDebugSettingsScreen <name>` opens it too, and names the screen
///   Settings pushes at once, once per run (`tmdbKey`, `region`,
///   `services`: the « Services de streaming » screens);
/// - `-PTDebugTMDBKeyDraft <text>`: the key screen's field holds that text,
///   as if pasted (a made-up key: never a real one); `-PTDebugTMDBKeySave
///   YES` presses « Enregistrer » once, `-PTDebugTMDBKeyCheck YES`
///   « Vérifier à nouveau » (with the fixtures, TMDB's recorded client
///   answers: it takes any key, or refuses every key with
///   `-PTDebugHomeState tmdbrefused`);
/// - `-PTDebugExpensiveNetwork YES`: the connection counts as cellular;
/// - `-PTDebugPressPlay YES`: an opened page presses Play once its sources
///   are known — only when that cannot start a stream: the cellular question
///   would show (`-PTDebugExpensiveNetwork YES` with the setting off) or the
///   quality sheet would (`-autoSelectQuality ""`, "Always Ask"). Nothing
///   plays; otherwise the hook does nothing;
/// - `-PTDebugTop100Offline YES`: The Pirate Bay off and the cached Top 100
///   lists deleted (the grids' error state, with `-PTDebugFilter top100`);
/// - `-PTDebugWatchlistSeed YES`: an opened page is added to the watchlist
///   (the simulator's own defaults);
/// - `-PTDebugDetailError YES`: an opened page shows its load error state;
/// - `-PTDebugDetailMetadataDelay <s>`, `-PTDebugDetailSourcesDelay <s>`,
///   `-PTDebugDetailLastSourceDelay <s>`, `-PTDebugDetailSourcesFail YES`,
///   `-PTDebugDetailFail YES`: a page's record and sources come late, or
///   fail (`DetailStore.Tampering`): the states of a page as it loads;
/// - `-PTDebugAmbient YES`: an opened page draws its hero without a
///   backdrop (the blurred poster and poster card layout).
/// Any of them also skips the release notes sheet. Nothing happens without
/// these arguments.
enum IOSDebugHooks {
    private static var defaults: UserDefaults { .standard }
    private static let keys = ["PTDebugTab", "PTDebugOpenMovie", "PTDebugOpenShow", "PTDebugFilter", "PTDebugGenre",
                               "PTDebugSearch", "PTDebugSettings", "PTDebugPressPlay", "PTDebugExpensiveNetwork",
                               "PTDebugWatchlistSeed", "PTDebugDetailError", "PTDebugTop100Offline", "PTDebugAmbient",
                               "PTDebugDetailMetadataDelay", "PTDebugDetailSourcesDelay", "PTDebugDetailLastSourceDelay",
                               "PTDebugDetailSourcesFail", "PTDebugDetailFail",
                               "PTDebugHomeFixtures", "PTDebugHomeState", "PTDebugHomeShelf", "PTDebugHomeHeroPage",
                               "PTDebugOpenURL", "PTDebugHomeService", "PTDebugSettingsScreen",
                               "PTDebugTMDBKeyDraft", "PTDebugTMDBKeySave", "PTDebugTMDBKeyCheck"]

    static var isActive: Bool {
        keys.contains { defaults.object(forKey: $0) != nil }
    }

    static var tab: AppTab? {
        defaults.string(forKey: "PTDebugTab").flatMap { AppTab(rawValue: $0.lowercased()) }
    }

    /// A placeholder with the IMDb id: the page loads the real title.
    static var media: Media? {
        if let id = defaults.string(forKey: "PTDebugOpenMovie") { return Movie(title: id, id: id) }
        if let id = defaults.string(forKey: "PTDebugOpenShow") { return Show(title: id, id: id) }
        return nil
    }

    static var movieFilter: MovieManager.Filters? {
        defaults.string(forKey: "PTDebugFilter").flatMap(MovieManager.Filters.init(rawValue:))
    }

    static var showFilter: ShowManager.Filters? {
        defaults.string(forKey: "PTDebugFilter").flatMap(ShowManager.Filters.init(rawValue:))
    }

    static var genre: NetworkManager.Genres? {
        defaults.string(forKey: "PTDebugGenre").flatMap(NetworkManager.Genres.init(rawValue:))
    }

    /// `-PTDebugSettingsScreen`: the screen of Settings shown at launch
    /// (lowercased), over the sheet `apply(to:)` opens.
    static var settingsScreen: String? {
        defaults.string(forKey: "PTDebugSettingsScreen")?.lowercased()
    }

    @MainActor private static var didTakeSettingsScreen = false

    /// The screen `-PTDebugSettingsScreen` names, the first time Settings
    /// shows (nil afterwards: Back stays back).
    @MainActor
    static func takeSettingsScreen() -> StreamingSettingsScreen? {
        guard !didTakeSettingsScreen else { return nil }
        didTakeSettingsScreen = true
        return settingsScreen.flatMap(StreamingSettingsScreen.init(rawValue:))
    }

    /// The key screen's hooks ran (once per run).
    @MainActor static var didApplyKeyScreen = false

    static var keyDraft: String? {
        defaults.string(forKey: "PTDebugTMDBKeyDraft")
    }

    static var savesKey: Bool {
        defaults.bool(forKey: "PTDebugTMDBKeySave")
    }

    static var checksKey: Bool {
        defaults.bool(forKey: "PTDebugTMDBKeyCheck")
    }

    static var searchText: String? {
        defaults.string(forKey: "PTDebugSearch")
    }

    static var pressesPlay: Bool {
        defaults.bool(forKey: "PTDebugPressPlay")
    }

    /// `-PTDebugTop100Offline`: The Pirate Bay off, no cached Top 100. Once,
    /// before the first grid loads.
    static func applySourceSwitches() {
        guard defaults.bool(forKey: "PTDebugTop100Offline"), PirateBayClient.isEnabled else { return }
        PirateBayClient.isEnabled = false
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        for kind in ["movie", "series"] {
            if let url = caches?.appendingPathComponent("popcornkit-top100-\(kind).json") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        print("[iOSDebug] The Pirate Bay off, Top 100 cache deleted")
    }

    static var forcesExpensiveNetwork: Bool {
        defaults.bool(forKey: "PTDebugExpensiveNetwork")
    }

    static var seedsWatchlist: Bool {
        defaults.bool(forKey: "PTDebugWatchlistSeed")
    }

    static var forcesDetailError: Bool {
        defaults.bool(forKey: "PTDebugDetailError")
    }

    private static var didTamperWithDetails = false

    /// `-PTDebugDetail…Delay`, `-PTDebugDetailSourcesFail`, `-PTDebugDetailFail`:
    /// the pages' answers come late or fail (`DetailStore.Tampering`). Once,
    /// before the first page loads.
    static func applyDetailTamperingOnce() {
        guard !didTamperWithDetails else { return }
        didTamperWithDetails = true
        var tampering = DetailStore.Tampering()
        tampering.metadataDelay = defaults.double(forKey: "PTDebugDetailMetadataDelay")
        tampering.sourcesDelay = defaults.double(forKey: "PTDebugDetailSourcesDelay")
        tampering.lastSourceDelay = defaults.double(forKey: "PTDebugDetailLastSourceDelay")
        tampering.sourcesFail = defaults.bool(forKey: "PTDebugDetailSourcesFail")
        tampering.fails = defaults.bool(forKey: "PTDebugDetailFail")
        DetailStore.shared.tampering = tampering
    }

    static var forcesAmbientHero: Bool {
        defaults.bool(forKey: "PTDebugAmbient")
    }

    // MARK: Home

    static var homeShelf: String? {
        defaults.string(forKey: "PTDebugHomeShelf")
    }

    static var homeHeroPage: Int? {
        defaults.object(forKey: "PTDebugHomeHeroPage") == nil ? nil : defaults.integer(forKey: "PTDebugHomeHeroPage")
    }

    /// `-PTDebugHomeFixtures`: a hub of its own, on recorded answers. Nil
    /// without the argument (the app's hub, the real hosts).
    @MainActor
    static func homeState() -> HomeState? {
        guard let folder = defaults.string(forKey: "PTDebugHomeFixtures"), !folder.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        let mode = defaults.string(forKey: "PTDebugHomeState")?.lowercased()
        let recorded = HomeRecordedTransport(directory: directory)
        recorded.mode = HomeRecordedTransport.mode(forState: mode)
        // Its own cache, emptied: every launch is a first load of the
        // same answers, and the app's real cache is left alone.
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("popcornkit-home-debug", isDirectory: true)
        try? FileManager.default.removeItem(at: cache)
        // "New", "this week" and the schedules asked are counted from the
        // day the answers were recorded, not from today.
        let recordedAt = HomeRecordedTransport.recordedDate(in: directory) ?? Date()
        // The placeholders stay as long as the screenshot needs them.
        let options = HomeFeed.Options(requestDeadline: mode == "skeleton" || mode == "tmdbsilent" ? 600 : 15)
        let feed = HomeFeed(store: HomeStore(directory: cache, now: { recordedAt }), transport: recorded.transport,
                            hooks: HomeLocalHooks(library: .shared), options: options, now: { recordedAt })
        feed.followChanges(of: .shared)
        // `-PTDebugHomeService <id>`: the page starts filtered on that
        // service (the made-up key of `-popcornkit.tmdb.apiKey <text>`
        // makes the row; the recorded answers are its lists).
        let service = HomeRecordedTransport.service(from: defaults.string(forKey: "PTDebugHomeService"))
        if let service { HomeSettings().homeServiceFilter = service }
        let state = HomeState(feed: feed)
        print("[iOSDebug] Home fed from \(folder) as of \(recordedAt)" + (mode.map { ", state \($0)" } ?? "")
              + (service.map { ", service \($0)" } ?? "") + (HomeSettings().tmdbAPIKey == nil ? ", no TMDB key" : ", a TMDB key"))
        if mode == "offline" {
            // The page is loaded and cached from the recordings, then no
            // host answers a forced refresh: the cached page, offline.
            feed.start {
                recorded.mode = .down
                feed.refresh(force: true) { print("[iOSDebug] Home offline: \(state.isOffline), \(state.shelves.count) shelves") }
            }
        }
        return state
    }

    /// The tab, the pushed page and the Settings sheet asked for at launch.
    @MainActor
    static func apply(to router: AppRouter) {
        let tab = self.tab ?? (searchText != nil ? .search : router.selection)
        router.selection = tab
        if let media { router.open(media, in: tab) }
        if defaults.bool(forKey: "PTDebugSettings") || settingsScreen != nil { router.showsSettings = true }
        print("[iOSDebug] tab \(tab.rawValue)" + (media.map { ", page \($0.id)" } ?? ""))
        if let text = defaults.string(forKey: "PTDebugOpenURL"), let url = URL(string: text) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                print("[iOSDebug] link \(text): \(router.open(url: url) ? "opened" : "refused")")
            }
        }
    }
}
#endif
