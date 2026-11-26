

import UIKit
import PopcornKit

/// UIScene lifecycle adoption for the tvOS app.
///
/// The app was written against the legacy `UIApplicationDelegate`-only
/// lifecycle (window created from `UIMainStoryboardFile`, everything hanging
/// off `AppDelegate.window`). Newer tvOS SDKs emit the
/// `NoSceneLifecycleAdoption` runtime issue at launch for that pattern, so we
/// adopt scenes here.
///
/// To avoid touching the large amount of code that presents players / alerts
/// on `AppDelegate.shared.window`, this delegate creates the window from the
/// storyboard and points `AppDelegate.window` at it — so the rest of the app
/// keeps working unchanged.
@objc(SceneDelegate)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        #if DEBUG
        // Before the first screen reads what these hooks set.
        DebugLaunchHooks.prepare()
        #endif

        let window = UIWindow(windowScene: windowScene)
        window.tintColor = .app
        self.window = window

        // Keep the legacy AppDelegate.window reference valid.
        AppDelegate.shared.window = window

        let launchURL = connectionOptions.urlContexts.first?.url
        #if DEBUG
        // `-PTDebugProfilesPick <name>` (with `-PTDebugProfiles "Alex,Sam"`):
        // that profile answers the question at once (screenshots of the
        // content with several profiles, DEBUG builds only), as on the
        // iPhone and the Mac.
        if let name = UserDefaults.standard.string(forKey: "PTDebugProfilesPick"),
           let profile = ProfileManager.shared.profiles.first(where: { $0.name == name }) {
            ProfileManager.shared.activate(profile.id)
            window.makeKeyAndVisible()
            return installInterface(in: window, launchURL: launchURL, animated: false)
        }
        #endif
        // « Who's Watching? » first when the device has several profiles —
        // not for a launch to open a link (the Top Shelf's Play): the last
        // profile watches it. A link that comes while it asks is opened
        // after the pick.
        if ProfileManager.shared.asksAtLaunch && launchURL == nil {
            ProfilesPresenter.launchPicker(in: window) { [weak self] kept in
                self?.installInterface(in: window, launchURL: nil, keptLink: kept, animated: true)
            }
            window.makeKeyAndVisible()
        } else {
            window.makeKeyAndVisible()
            installInterface(in: window, launchURL: launchURL, animated: false)
        }
    }

    /// The tab bar from the storyboard, then what a launch shows over it.
    /// `keptLink`: a link that came while « Who's Watching? » asked.
    private func installInterface(in window: UIWindow, launchURL: URL?,
                                  keptLink: ProfilesPresenter.KeptLink? = nil, animated: Bool) {
        let root = UIStoryboard(name: "tvOS", bundle: nil).instantiateInitialViewController()
        if animated {
            let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.35
            UIView.transition(with: window, duration: duration, options: .transitionCrossDissolve) {
                window.rootViewController = root
            }
        } else {
            window.rootViewController = root
        }

        AppDelegate.shared.presentTermsOfServiceIfNeeded()
        #if DEBUG
        // `-PTDebugLaunchURL <url>`: as if the app had been launched to open
        // that URL (never with autoplay).
        let debugLaunchURL = launchURL == nil ? DebugLaunchHooks.launchURL : nil
        #else
        let debugLaunchURL: URL? = nil
        #endif

        // Release notes, once per version. A fresh install (Terms of Service
        // not accepted yet) and a launch to open a URL (Top Shelf) skip them.
        if let root = window.rootViewController {
            WhatsNewPresenter.presentAtLaunchIfNeeded(
                from: root,
                isFreshInstall: !UserDefaults.standard.bool(forKey: "tosAccepted"),
                launchedFromURL: launchURL != nil || debugLaunchURL != nil || keptLink != nil)
        }

        if let launchURL {
            AppDelegate.shared.open(launchURL)
        } else if let keptLink {
            AppDelegate.shared.open(keptLink.link, allowsAutoPlay: keptLink.allowsAutoPlay)
        } else if let debugLaunchURL {
            AppDelegate.shared.open(debugLaunchURL, allowsAutoPlay: false)
        }

        // Trakt's user data, with the account of the profile watching now
        // (never before « Who's Watching? » is answered: the lists would go
        // to the last profile while another one is picked), then each time
        // another profile becomes active. Deferred until *after* the first
        // visible frame (6 parallel HTTP requests for playback progress,
        // watchlists, etc.): otherwise it competes with the Movies tab's
        // initial YTS fetch over a small pool of HTTP/1.1 sockets and makes
        // the grid feel sluggish to populate. The stored values are returned
        // synchronously by each sub-call, so the UI doesn't need the network
        // results to render.
        TraktManager.shared.followActiveProfile()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            TraktManager.shared.syncUserData()
        }

        #if DEBUG
        DebugLaunchHooks.run()
        // `-PTDebugNoDetailWarmUp YES`: the first title page pays SwiftUI's
        // first layout itself (to measure what the warm-up saves).
        let warmsUp = !UserDefaults.standard.bool(forKey: "PTDebugNoDetailWarmUp")
        #else
        let warmsUp = true
        #endif
        // A title's page is laid out once ahead, at a still moment: the
        // first press on a poster then opens its page at once.
        if warmsUp { GlassDetailWarmUp.schedule(in: window) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            AppDelegate.shared.open(url)
        }
    }

    #if DEBUG
    func sceneWillEnterForeground(_ scene: UIScene) {
        DebugLaunchHooks.sceneWillEnterForeground()
    }
    #endif
}

#if DEBUG
/// Simulator verification hooks, compiled only with DEBUG (the app targets do
/// not define it: build with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` on the
/// xcodebuild command line). Launch arguments: `-PTDebugTab <name>` selects
/// that tab, by its name (`DeepLink.Tab`: home, movies, shows, watchlist,
/// search, downloads, settings) — never by its place in the bar, which
/// changes when a tab is added; an index is still read;
/// `-PTDebugOpenURL <url>` then hands the URL to the app's link handler
/// (`AppDelegate.open`), as the Top Shelf or another app would (`simctl
/// openurl` stops on a system dialog), a `play` link only opening its page,
/// 1 s later or `-PTDebugOpenURLAfter <seconds>` later, the handler's answer
/// then shown to the UI tests (`showLinkResult`; `-PTDebugOpenURL2 <url>`
/// hands a second link `-PTDebugOpenURL2After <seconds>` after the first)
/// (`-PTDebugLaunchURL <url>` instead: as if the app had been launched to
/// open it, see `scene(_:willConnectTo:options:)`; `-PTDebugActivationURL
/// <url>`: as if it had been picked while the app was in the background, each
/// time the app comes back to the foreground);
/// `-PTDebugOpenMovie <IMDb id>` or `-PTDebugOpenShow <IMDb id>`
/// opens the title's page on the selected tab through
/// `MainViewController.showDetail` (the page at once, filled as it loads),
/// never with autoplay, 1 s after the tab hook or `-PTDebugOpenAfter
/// <seconds>` after it; `-PTDebugReopenAfter <seconds>` then goes back to the
/// tab's root and opens the same page again (it then comes from the pages'
/// cache); `-PTDebugPrewarmMovie <IMDb id>` / `-PTDebugPrewarmShow <IMDb id>`
/// asks a title's page ahead at launch, as a card that keeps the focus does
/// (`DetailStore.prewarm`). The states of a page as it loads
/// (`DetailStore.Tampering`): `-PTDebugDetailMetadataDelay <seconds>` holds
/// the title's record, `-PTDebugDetailSourcesDelay <seconds>` its sources,
/// `-PTDebugDetailLastSourceDelay <seconds>` a movie's last source (Play is
/// live, a source still expected), `-PTDebugDetailSourcesFail YES` makes
/// every source fail,
/// `-PTDebugDetailFail YES` the whole load (`-PTDebugDetailHealAfter
/// <seconds>` ends both failures, then presses "Try Again");
/// `-PTDebugPressPlay <seconds>` presses Play that long after the page
/// opened — a dry run: the press waits for the sources as a real one does,
/// then its chooser only logs a pick — and `-PTDebugCancelPress <seconds>`
/// cancels it;
/// `-PTDebugFocusContent YES` moves the focus from the tab bar into the page
/// shown (as a remote would); `-PTDebugFocusSection <episodes|related|cast|info>`
/// then moves it down into that section of the detail page once it has loaded
/// (10 s later). Grids and sources:
/// `-PTDebugFilter <raw value>` (e.g. top100) sets the Movies / Shows tab's
/// filter and `-PTDebugGenre <raw value>` (e.g. "Science Fiction") its genre;
/// `-PTDebugSortMenu YES` then opens its Sort menu, `-PTDebugGenreMenu YES`
/// its Genre menu;
/// `-PTDebugOpenItem <index>` opens the grid's item at that index once it has
/// loaded (as a click would, never with autoplay); `-PTDebugQualityPicker YES`
/// shows the page's quality chooser once loaded (a pick only logs: nothing
/// plays); `-PTDebugSearch <text>` searches the text on the Search tab;
/// `-PTDebugOpenPerson "<IMDb id>|<name>"` pushes that person's page on the
/// selected tab;
/// `-PTDebugTop100Offline YES` turns The Pirate Bay off and deletes the
/// cached Top 100 lists (the grid's error state). Watched progress:
/// `-PTDebugMovieProgress <id>=<fraction>[,…]` and `-PTDebugEpisodeProgress
/// <id>=<fraction>[,…]` add started titles (Continue Watching) for this launch
/// only (`prepare`). The Home tab has its own (`HomeDebug`: recorded answers
/// instead of the network, a card focused, Play without playing). Nothing
/// happens without these arguments.
private enum DebugLaunchHooks {
    /// Before the window exists. `-PTDebugMovieProgress tt0816692=0.4` (movies,
    /// by IMDb id) and `-PTDebugEpisodeProgress <episode id>=0.4`: watched
    /// progress, from 0 to 1, as if the title had been played up to there.
    /// The entries are added to the stored ones in the argument domain, which
    /// is read first: nothing is written to the app's preferences, and they
    /// are gone at the next launch. (A dictionary passed as a launch argument
    /// has string values, which the progress readers refuse.) `Library.shared`
    /// keeps its lists in memory for such a launch, as with
    /// `-PTDebugLibraryInMemory`: the resume entries it makes of them are
    /// not stored either.
    static func prepare() {
        inject(progress: "PTDebugMovieProgress", into: "\(Trakt.MediaType.movies.rawValue)Progress")
        inject(progress: "PTDebugEpisodeProgress", into: "\(Trakt.MediaType.episodes.rawValue)Progress")
        tamperWithDetails()
    }

    /// `-PTDebugDetail…`: the pages' answers come late or fail
    /// (`DetailStore.Tampering`), so each state of a page can be looked at.
    private static func tamperWithDetails() {
        let defaults = UserDefaults.standard
        var tampering = DetailStore.Tampering()
        tampering.metadataDelay = defaults.string(forKey: "PTDebugDetailMetadataDelay").flatMap(Double.init) ?? 0
        tampering.sourcesDelay = defaults.string(forKey: "PTDebugDetailSourcesDelay").flatMap(Double.init) ?? 0
        tampering.lastSourceDelay = defaults.string(forKey: "PTDebugDetailLastSourceDelay").flatMap(Double.init) ?? 0
        tampering.sourcesFail = defaults.bool(forKey: "PTDebugDetailSourcesFail")
        tampering.fails = defaults.bool(forKey: "PTDebugDetailFail")
        DetailStore.shared.tampering = tampering
        if let prewarm: Media = defaults.string(forKey: "PTDebugPrewarmMovie").map({ Movie(title: $0, id: $0) })
            ?? defaults.string(forKey: "PTDebugPrewarmShow").map({ Show(title: $0, id: $0) }) {
            print("[Debug] prewarm of \(prewarm.id)")
            DetailStore.shared.prewarm(prewarm)
        }
    }

    /// `-PTDebugPressPlay`, `-PTDebugCancelPress`, `-PTDebugDetailHealAfter`:
    /// on the page the hooks have just opened on `navigationController`,
    /// that many seconds after it opened.
    private static func runPageHooks(in navigationController: UINavigationController) {
        let defaults = UserDefaults.standard
        let page = { [weak navigationController] in navigationController?.topViewController as? GlassDetailHostingController }
        if let delay = defaults.string(forKey: "PTDebugPressPlay").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { page()?.debugPressPlay() }
        }
        if let delay = defaults.string(forKey: "PTDebugCancelPress").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { page()?.debugCancelPress() }
        }
        if let delay = defaults.string(forKey: "PTDebugDetailHealAfter").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                DetailStore.shared.tampering.fails = false
                DetailStore.shared.tampering.sourcesFail = false
                page()?.debugRetry()
            }
        }
    }

    /// Whether the scene has entered the foreground once (the launch).
    private static var hasEnteredForeground = false

    /// `-PTDebugActivationURL`: the URL goes to the app's link handler when
    /// the app comes back to the foreground (not at launch), where
    /// `scene(_:openURLContexts:)` is called for a link picked on the Top
    /// Shelf meanwhile: before the scene is active and has its focus back.
    /// Never with autoplay.
    static func sceneWillEnterForeground() {
        guard let string = UserDefaults.standard.string(forKey: "PTDebugActivationURL"), let url = URL(string: string) else { return }
        guard hasEnteredForeground else { return hasEnteredForeground = true }
        DispatchQueue.main.async {
            let opened = AppDelegate.shared.open(url, allowsAutoPlay: false)
            print("[Debug] activation URL: \(opened ? "opened" : "refused") \(string.prefix(80))")
        }
    }

    /// `-PTDebugLaunchURL`: the URL the app is launched to open.
    static var launchURL: URL? {
        return UserDefaults.standard.string(forKey: "PTDebugLaunchURL").flatMap { URL(string: $0) }
    }

    private static func inject(progress argument: String, into key: String) {
        let defaults = UserDefaults.standard
        guard let pairs = defaults.string(forKey: argument) else { return }
        var progress = defaults.object(forKey: key) as? [String: Float] ?? [:]
        for pair in pairs.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, let fraction = Float(parts[1]), (0...1).contains(fraction) else {
                print("[Debug] progress: \(pair) is not <id>=<0 to 1>")
                continue
            }
            progress[parts[0]] = fraction
        }
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[key] = progress
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        print("[Debug] \(key) for this launch: \(progress)")
    }

    static func run() {
        let defaults = UserDefaults.standard
        // `-PTDebugUpNextCard <countdown|postPlay|stillWatching>`
        // (UpNextTVFixture): the episode card over a stand-in player, for
        // the UI tests of its focus and buttons. Nothing plays.
        if UpNextTVFixture.kind != nil {
            afterFocusSettles(atLeast: 1) {
                guard let root = AppDelegate.shared.window?.rootViewController else { return }
                var top = root
                while let presented = top.presentedViewController { top = presented }
                UpNextTVFixture.presentIfAsked(over: top)
            }
            return
        }
        // `-PTDebugPlayTorrent <file>` (BoundedStorageDebugHooks): the normal
        // play flow on a local .torrent, once the launch screens are up.
        // With `-PTDebugPlayEpisode S01E01` (UpNextDebugHooks): that episode
        // of the made-up show tt0000001, from the same .torrent.
        // `-PTDebugResumeEpisode S01E02` (UpNextTVResumeHook): « Resume »
        // on that episode of the made-up show (its remembered release).
        if UpNextTVResumeHook.runIfAsked() { return }
        if let (episode, torrent) = UpNextDebugHooks.episodeToPlay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("[UpNextDebug] playing \(episode.id) from \(torrent.url)")
                AppDelegate.shared.play(episode, torrent: torrent)
            }
            return
        }
        if let file = BoundedStorageDebugHooks.torrentFile {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("[BoundedDebug] playing \(file)")
                AppDelegate.shared.play(Movie(title: "Bounded storage test", id: "tt0000000"),
                                        torrent: Torrent(url: file, quality: "1080p"))
            }
            return
        }
        let tab = defaults.string(forKey: "PTDebugTab")
        let url = defaults.string(forKey: "PTDebugOpenURL")
        let media: Media? = defaults.string(forKey: "PTDebugOpenMovie").map { Movie(title: $0, id: $0) }
            ?? defaults.string(forKey: "PTDebugOpenShow").map { Show(title: $0, id: $0) }
        let focusContent = defaults.bool(forKey: "PTDebugFocusContent")
        let filter = defaults.string(forKey: "PTDebugFilter")
        let openItem = defaults.string(forKey: "PTDebugOpenItem").flatMap { Int($0) }
        let search = defaults.string(forKey: "PTDebugSearch")
        let person = defaults.string(forKey: "PTDebugOpenPerson")
        if defaults.bool(forKey: "PTDebugTop100Offline") { takeTop100Offline() }
        guard tab != nil || url != nil || media != nil || search != nil || person != nil else { return }
        // After the launch screens (Terms of Service, What's New) are up.
        afterFocusSettles(atLeast: 1) {
            guard let tabBarController = AppDelegate.shared.mainTabBarController else { return }
            if let tab { select(tab: tab, in: tabBarController) }
            if let url {
                let delay = defaults.string(forKey: "PTDebugOpenURLAfter").flatMap(Double.init) ?? 1
                open(url: url, in: tabBarController, after: delay, focus: focusContent)
            } else if let search {
                return run(search: search, in: tabBarController)
            }
            guard let navigationController = tabBarController.selectedViewController as? UINavigationController else { return }
            let root = navigationController.viewControllers.first
            if let filter { apply(filter: filter, to: root) }
            if let genre = defaults.string(forKey: "PTDebugGenre").flatMap(NetworkManager.Genres.init(rawValue:)) {
                root?.loadViewIfNeeded()
                (root as? MediaViewController)?.currentGenre = genre
            }
            if defaults.bool(forKey: "PTDebugSortMenu") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if let movies = root as? MoviesViewController { movies.showFilters(movies) }
                    if let shows = root as? ShowsViewController { shows.showFilters(shows) }
                }
            }
            if defaults.bool(forKey: "PTDebugGenreMenu"), let grid = root as? MediaViewController {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { grid.showGenres(grid) }
            }
            // The link is what opens a page then, not the hooks below.
            guard url == nil else { return }
            if let openItem, let grid = root as? MainViewController {
                return open(item: openItem, of: grid, on: navigationController, in: tabBarController, focus: focusContent)
            }
            if let person {
                return open(person: person, on: navigationController, in: tabBarController, focus: focusContent)
            }
            guard let media else {
                if focusContent { focus(navigationController.topViewController, in: tabBarController, after: 1) }
                return
            }
            let openDelay = defaults.string(forKey: "PTDebugOpenAfter").flatMap(Double.init) ?? 1
            DispatchQueue.main.asyncAfter(deadline: .now() + openDelay) {
                MainViewController.showDetail(of: media, on: navigationController, autoPlay: false)
                runPageHooks(in: navigationController)
                if focusContent { focusPage(in: navigationController, of: tabBarController) }
                guard let reopen = defaults.string(forKey: "PTDebugReopenAfter").flatMap(Double.init) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + reopen) {
                    navigationController.popToRootViewController(animated: false)
                    MainViewController.showDetail(of: media, on: navigationController, autoPlay: false)
                    if focusContent { focusPage(in: navigationController, of: tabBarController) }
                }
            }
        }
    }

    /// `work` once the focus has settled, `seconds` from now at the earliest.
    /// tvOS selects a tab 0.3 s after the focus lands on it: at launch (the
    /// first focus goes to a tab) and after a tab was selected in code (the
    /// focus follows to that tab). A hook that selects a tab in between is
    /// undone by that selection. The hooks ran exactly 1 s after the launch,
    /// about 50 ms after the launch's own selection, and before it when the
    /// launch took a little longer: the app then stayed on its first tab,
    /// which only showed for the tabs after it. Now: once the same item has
    /// had the focus for 0.7 s (checked every 0.1 s, for 10 s more at most).
    private static func afterFocusSettles(atLeast seconds: Double, elapsed: Int = 0, settled: Int = 0,
                                          on item: AnyObject? = nil, _ work: @escaping () -> Void) {
        let focused = AppDelegate.shared.mainTabBarController.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem } as AnyObject?
        let settled = (focused != nil && focused === item) ? settled + 1 : 0
        let waited = Double(elapsed) / 10
        guard (waited < seconds || settled < 7) && waited < seconds + 10 else { return work() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            afterFocusSettles(atLeast: seconds, elapsed: elapsed + 1, settled: settled, on: focused, work)
        }
    }

    /// `-PTDebugTab`: a tab's name or, as before, its index in the bar.
    private static func select(tab value: String, in tabBarController: TVTabBarController) {
        if let tab = DeepLink.Tab(name: value) {
            if !tabBarController.select(tab) { print("[Debug] tab: there is no \(tab.rawValue) tab") }
        } else if let index = Int(value), (0..<(tabBarController.viewControllers?.count ?? 0)).contains(index) {
            tabBarController.selectedIndex = index
        } else {
            print("[Debug] tab: \(value) is neither a tab's name nor an index")
        }
    }

    /// `-PTDebugOpenURL`: the URL goes to the app's link handler `delay`
    /// seconds after the tab hook, once the focus has followed to that tab
    /// (the link then comes while that tab, or its Sort menu, is shown).
    /// Never with autoplay: a `play` link only opens its page.
    private static func open(url string: String, in tabBarController: TVTabBarController, after delay: Double, focus: Bool) {
        guard let url = URL(string: string) else { return print("[Debug] open URL: \(string) is not a URL") }
        afterFocusSettles(atLeast: delay) {
            let opened = AppDelegate.shared.open(url, allowsAutoPlay: false)
            print("[Debug] open URL: \(opened ? "opened" : "refused") \(string.prefix(80)), tab \(tabBarController.selectedTabName?.rawValue ?? "?")")
            showLinkResult(opened ? "opened" : "refused")
            // `-PTDebugOpenURL2 <url>`: a second link, `-PTDebugOpenURL2After
            // <seconds>` (5) after the first — a link to the page the first
            // one opened, for instance. Its answer replaces the first's.
            if let second = UserDefaults.standard.string(forKey: "PTDebugOpenURL2").flatMap({ URL(string: $0) }) {
                let delay = UserDefaults.standard.string(forKey: "PTDebugOpenURL2After").flatMap(Double.init) ?? 5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    let opened = AppDelegate.shared.open(second, allowsAutoPlay: false)
                    print("[Debug] second URL: \(opened ? "opened" : "refused") \(second.absoluteString.prefix(80))")
                    showLinkResult(opened ? "opened twice" : "refused")
                }
            }
            guard opened, let navigationController = tabBarController.selectedViewController as? UINavigationController else { return }
            // The page is pushed once the tab's transition, if any, has ended.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { runPageHooks(in: navigationController) }
            if focus { focusPage(in: navigationController, of: tabBarController) }
        }
    }

    /// `-PTDebugOpenURL`'s answer, for the UI tests: a text whose identifier
    /// is `Debug.LinkResult` ("opened" or "refused"), one point in the
    /// window's corner, over everything. A test that checks that a link did
    /// nothing waits for it: without it, a link handed over late passed for
    /// one refused.
    private static func showLinkResult(_ result: String) {
        guard let window = AppDelegate.shared.window else { return }
        let label = window.subviews.compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == "Debug.LinkResult" } ?? {
            let label = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            label.accessibilityIdentifier = "Debug.LinkResult"
            label.textColor = .clear
            window.addSubview(label)
            return label
        }()
        label.text = result
        window.bringSubviewToFront(label)
    }

    /// Once the detail page is up (checked twice a second for 30 s), moves
    /// the focus into it.
    private static func focusPage(in navigationController: UINavigationController,
                                  of tabBarController: UITabBarController, attempt: Int = 0) {
        guard attempt < 60 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let page = navigationController.topViewController as? GlassDetailHostingController {
                focus(page, in: tabBarController, after: 1)
                if let section = UserDefaults.standard.string(forKey: "PTDebugFocusSection") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { page.debugFocus(section: section) }
                }
            } else {
                focusPage(in: navigationController, of: tabBarController, attempt: attempt + 1)
            }
        }
    }

    /// `-PTDebugFilter`: the Movies or Shows tab's filter.
    private static func apply(filter raw: String, to root: UIViewController?) {
        // A tab never shown yet has no collection view: the filter's
        // `didSet` reloads it.
        root?.loadViewIfNeeded()
        if let movies = root as? MoviesViewController, let filter = MovieManager.Filters(rawValue: raw) {
            movies.currentFilter = filter
        } else if let shows = root as? ShowsViewController, let filter = ShowManager.Filters(rawValue: raw) {
            shows.currentFilter = filter
        }
    }

    /// `-PTDebugOpenItem`: once the grid has items (checked twice a second for
    /// 40 s), opens the one at `index` like a click, then the page hooks.
    private static func open(item index: Int, of grid: MainViewController, on navigationController: UINavigationController,
                             in tabBarController: UITabBarController, focus: Bool, attempt: Int = 0) {
        guard attempt < 80 else { return print("[Debug] open item \(index): the grid never loaded") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let items = grid.collectionViewController.dataSources.first ?? []
            guard index < items.count, let media = items[index] as? Media else {
                return open(item: index, of: grid, on: navigationController, in: tabBarController, focus: focus, attempt: attempt + 1)
            }
            print("[Debug] opening grid item \(index): \(media.title) (\(media.id))")
            MainViewController.showDetail(of: media, on: navigationController, autoPlay: false)
            runPageHooks(in: navigationController)
            if focus { focusPage(in: navigationController, of: tabBarController) }
            if UserDefaults.standard.bool(forKey: "PTDebugQualityPicker") { chooseQuality(in: navigationController) }
        }
    }

    /// `-PTDebugQualityPicker`: once the page is up (checked twice a second
    /// for 40 s), its quality chooser 3 s later. A pick only logs.
    private static func chooseQuality(in navigationController: UINavigationController, attempt: Int = 0) {
        guard attempt < 80 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let page = navigationController.topViewController as? GlassDetailHostingController else {
                return chooseQuality(in: navigationController, attempt: attempt + 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { page.debugChooseQuality() }
        }
    }

    /// `-PTDebugSearch`: the Search tab with `text` searched.
    private static func run(search text: String, in tabBarController: UITabBarController) {
        func searchController(_ viewController: UIViewController) -> SearchViewController? {
            return ((viewController as? UINavigationController)?.viewControllers.first ?? viewController) as? SearchViewController
        }
        guard let index = tabBarController.viewControllers?.firstIndex(where: { searchController($0) != nil }) else {
            return print("[Debug] search: no Search tab")
        }
        tabBarController.selectedIndex = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let tab = tabBarController.viewControllers?[index], let search = searchController(tab) else { return }
            search.searchBar?.text = text
            search.filterSearchText(text)
        }
    }

    /// `-PTDebugTop100Offline`: The Pirate Bay off, no cached Top 100.
    private static func takeTop100Offline() {
        PirateBayClient.isEnabled = false
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        for kind in ["movie", "series"] {
            if let url = caches?.appendingPathComponent("popcornkit-top100-\(kind).json") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        print("[Debug] The Pirate Bay off, Top 100 cache deleted")
    }

    /// `-PTDebugOpenPerson "<IMDb id>|<name>"`: a person's page pushed on the
    /// selected tab, as a detail page's cast opens it (which needs Trakt).
    private static func open(person value: String, on navigationController: UINavigationController,
                             in tabBarController: TVTabBarController, focus focusContent: Bool) {
        let fields = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard fields.count == 2,
              let page = UIStoryboard.main.instantiateViewController(withIdentifier: "PersonViewController") as? PersonViewController else {
            return print("[Debug] open person: \(value) is not <IMDb id>|<name>")
        }
        page.currentItem = Actor(name: fields[1], imdbId: fields[0])
        navigationController.pushViewController(page, animated: true)
        print("[Debug] open person: \(fields[1]) (\(fields[0]))")
        if focusContent { focus(page, in: tabBarController, after: 1) }
    }

    private static func focus(_ viewController: UIViewController?, in tabBarController: UITabBarController, after delay: Double) {
        guard let viewController, let tabBarController = tabBarController as? TVTabBarController else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            tabBarController.moveFocus(to: viewController)
        }
    }
}
#endif
