

import UIKit
import PopcornKit
import Reachability
import MarqueeLabel
import VLCKit
import AlamofireImage

public let vlcSettingTextEncoding = "subsdec-encoding"

struct ColorPallete {
    let primary: UIColor
    let secondary: UIColor
    let tertiary: UIColor

    private init(primary: UIColor, secondary: UIColor, tertiary: UIColor) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
    }

    static let light = ColorPallete(primary: .white, secondary: UIColor.white.withAlphaComponent(0.667), tertiary: UIColor.white.withAlphaComponent(0.333))
    static let dark  = ColorPallete(primary: .black, secondary: UIColor.black.withAlphaComponent(0.667), tertiary: UIColor.black.withAlphaComponent(0.333))
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UITabBarControllerDelegate {

    static var shared: AppDelegate = UIApplication.shared.delegate as! AppDelegate

    var window: UIWindow?

    var reachability: Reachability = (try? Reachability()) ?? (try! Reachability(hostname: "www.apple.com"))

    /// Kept for code that still asks for it; it traps before the scene has
    /// made its window. Use `mainTabBarController`.
    var tabBarController: UITabBarController {
        return window?.rootViewController as! UITabBarController
    }

    /// The root tab bar; nil before the scene has made its window.
    var mainTabBarController: TVTabBarController? {
        return window?.rootViewController as? TVTabBarController
    }

    /// The first grid of the selected tab's navigation stack (Movies, Shows,
    /// the Watchlist, Search, a person's page). Nil on a tab that has none:
    /// Settings, Downloads, a SwiftUI screen (Home). Nothing may count on it
    /// to present a screen or to open a page: see
    /// `presentTermsOfServiceIfNeeded` and `open(_:allowsAutoPlay:)`.
    var activeRootViewController: MainViewController? {
        guard
            let navigationController = mainTabBarController?.selectedViewController as? UINavigationController,
            let main = navigationController.viewControllers.compactMap({$0 as? MainViewController}).first
            else {
                return nil
        }
        return main
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        print("[App] didFinishLaunching tosAccepted=\(UserDefaults.standard.bool(forKey: "tosAccepted"))")
        // GCDWebServer (torrent streaming + remux HLS servers): quiet about
        // the players' cancelled requests. First: -PTDebugHTTPTrace replaces it.
        GCDWebServerLogging.configure()
        #if DEBUG
        // Bounded-storage verification runs: the loopback-only torrent
        // session and the download directory, before anything uses them.
        BoundedStorageDebugHooks.prepareAtLaunch()
        #endif

        // VLCKit 4 rewrote event management and now dispatches player delegate
        // callbacks (mediaPlayerTimeChanged / StateChanged) on a BACKGROUND
        // queue. Our player code touches UIKit directly in those callbacks
        // (e.g. ProgressBar.isBuffering → UIImageView.setHidden), which traps
        // on the main-queue assertion — the crash seen on play/pause. The
        // legacy events configuration restores VLCKit 3.x behaviour (callbacks
        // on the main thread). Must be set before any VLCMediaPlayer is created.
        VLCLibrary.sharedEventsConfiguration = VLCEventsLegacyConfiguration()

        // metahub serves some posters as WebP (recent titles, often in the
        // Top 100), which AlamofireImage refused by content type: the grids
        // showed placeholders. UIImage decodes WebP since tvOS 14.
        ImageResponseSerializer.addAcceptableImageContentTypes(["image/webp"])

        // Stored preferences written by older versions: subtitle language
        // moved to its own key, Auto Select Quality re-spelled in the current
        // UI language (see GlassSettingsStore).
        GlassSettingsStore.migrateStoredPreferences()

        // Purge any stragglers from previous sessions (crashes, force quits)
        // before any UI loads. We can't keep partials for resume: libtorrent
        // crashes reading back a resumed preallocated partial (see Media.play),
        // so a leftover partial is only dead weight on the small Apple TV
        // sandbox — clear it.
        purgeOrphanTorrentDownloads()

        let font = UIFont.systemFont(ofSize: 38, weight: UIFont.Weight.heavy)
        UITabBarItem.appearance().setTitleTextAttributes([NSAttributedString.Key.font: font], for: .normal)

        try? reachability.startNotifier()

        awakeObjects()

        // The Top Shelf follows the Home and the library.
        TopShelfReloader.shared.start()

        // Defer Trakt's user-data sync (6 parallel HTTP requests for
        // playback progress, watchlists, etc.) to *after* the first
        // visible frame. Otherwise it competes with the Movies tab's
        // initial YTS fetch over a small pool of HTTP/1.1 sockets and
        // makes the grid feel sluggish to populate. The cached
        // UserDefaults values are returned synchronously by each
        // sub-call so the UI doesn't need the network results to
        // render.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            TraktManager.shared.syncUserData()
        }

        // Window creation, the Terms-of-Service gate and launch-URL handling
        // now happen in `SceneDelegate` (they need the window, which only
        // exists once the scene connects).
        return true
    }

    // MARK: - Scene lifecycle

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Uses the "Default Configuration" declared in the Info.plist scene
        // manifest, whose delegate class is `SceneDelegate`.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /// Presents the Terms-of-Service gate on first launch. Called by the
    /// scene delegate once the window/root tab bar exists.
    func presentTermsOfServiceIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "tosAccepted") else { return }
        let vc = UIStoryboard.main.instantiateViewController(withIdentifier: "TermsOfServiceNavigationController")
        // Theme songs are on by default (Settings > Theme Songs), at the
        // volume Settings writes for "On".
        GlassSettingsStore.themeSongs = true
        OperationQueue.main.addOperation {
            // From the window's root, whatever the first tab shows. (It was
            // presented from the first tab's grid: with another first screen
            // there, Home, the terms would never show.)
            self.window?.rootViewController?.present(vc, animated: false) {
                // Once accepted, the focus goes to the tab bar, not into the
                // grid behind (when the first tab is a grid).
                guard let tabBarController = self.mainTabBarController else { return }
                self.activeRootViewController?.environmentsToFocus = [tabBarController.tabBar]
            }
        }
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if tabBarController.selectedViewController == viewController, let scrollView = viewController.view.recursiveSubviews.compactMap({$0 as? UIScrollView}).first {
            let offset = CGPoint(x: 0, y: -scrollView.contentInset.top)
            scrollView.setContentOffset(offset, animated: true)
        }
        return true
    }


    // MARK: - Links into the app

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        return open(url)
    }

    /// Shows what `url` asks for (`DeepLink`: a `popcorntime:` link from the
    /// Top Shelf or another app, or the Top Shelf link of 5.2.0), from any
    /// tab. False for a URL that is not a link into the app (it used to crash
    /// on a Top Shelf link whose JSON did not map) and for a link that cannot
    /// be shown now.
    /// - Parameter allowsAutoPlay: false makes a `play` link only open its
    ///   page (the DEBUG hook `-PTDebugOpenURL`: nothing plays in a test).
    @discardableResult
    func open(_ url: URL, allowsAutoPlay: Bool = true) -> Bool {
        guard let link = DeepLink(url: url) else {
            print("[DeepLink] not a link into the app: \(url.absoluteString.prefix(80))")
            return false
        }
        return open(link, allowsAutoPlay: allowsAutoPlay)
    }

    /// Shows what `link` asks for, from any tab: a title's page (with
    /// playback for a `play` link), a search, a tab.
    /// False when it cannot be shown now: the Terms of Service are not
    /// accepted yet, the app has no such tab, or a screen the link must not
    /// close is up (a player, a stream being prepared, a Settings choice):
    /// the link is then kept and opened once that screen has gone
    /// (`keepUntilNothingIsPresented`).
    @discardableResult
    func open(_ link: DeepLink, allowsAutoPlay: Bool = true) -> Bool {
        // The last link wins: one kept before is dropped.
        pendingLink = nil
        // The Terms of Service come first (a fresh install): nothing opens
        // behind them.
        guard UserDefaults.standard.bool(forKey: "tosAccepted"), let tabBarController = mainTabBarController else {
            print("[DeepLink] \(link) not opened: the Terms of Service are not accepted yet")
            return false
        }
        // The release notes go: a page must not open under them, and playback
        // is presented from the root view controller.
        WhatsNewPresenter.dismiss(animated: false)

        let presented = tabBarController.presentedViewController.flatMap { $0.isBeingDismissed ? nil : $0 }
        if let alert = presented as? UIAlertController {
            // A menu or a question of the screen the link leaves (Sort, a
            // quality choice): closed, like Menu would.
            alert.dismiss(animated: false) { [weak self] in
                _ = self?.show(link, in: tabBarController, allowsAutoPlay: allowsAutoPlay)
            }
            return true
        }
        if let busy = presented as? SourcesBusyViewController, busy.cancel(then: { [weak self] in
            _ = self?.show(link, in: tabBarController, allowsAutoPlay: allowsAutoPlay)
        }) {
            // « Looking for sources… »: its request is dropped, as with Menu.
            return true
        }
        if let presented {
            // A player, a stream being prepared, a trailer, a SwiftUI sheet
            // (a Settings choice): closing them is their own business (the
            // stream, the saved position, the sheet's state), and a page
            // pushed under them would open unseen. The
            // link waits for them to go: leaving a film with the TV button
            // then picking a title on the Top Shelf brings the app back on
            // the player; Menu there opens the title.
            print("[DeepLink] \(link) kept until \(type(of: presented)) goes")
            keepUntilNothingIsPresented(link, allowsAutoPlay: allowsAutoPlay)
            return false
        }
        return show(link, in: tabBarController, allowsAutoPlay: allowsAutoPlay)
    }

    /// A link kept while a screen it must not close was up.
    private var pendingLink: (link: DeepLink, allowsAutoPlay: Bool, since: Date)?
    /// A kept link older than this is dropped: a title picked before a whole
    /// film is not opened when the film ends.
    static let pendingLinkLifetime: TimeInterval = 10 * 60

    /// Opens `link` once nothing has been presented over the tab bar for
    /// two checks in a row (half a second apart: a player that closes for
    /// the next episode's leaves a gap of a moment), the app active.
    private func keepUntilNothingIsPresented(_ link: DeepLink, allowsAutoPlay: Bool) {
        let kept = (link: link, allowsAutoPlay: allowsAutoPlay, since: Date())
        pendingLink = kept
        func check(clearChecks: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                // Replaced by a newer link, or opened.
                guard let self, let pending = self.pendingLink, pending.since == kept.since, pending.link == kept.link else { return }
                guard Date().timeIntervalSince(kept.since) < AppDelegate.pendingLinkLifetime else {
                    self.pendingLink = nil
                    return print("[DeepLink] \(link) dropped: what was on screen stayed too long")
                }
                let isClear = UIApplication.shared.applicationState == .active
                    && self.mainTabBarController.map { $0.presentedViewController == nil } == true
                guard isClear, clearChecks >= 1 else { return check(clearChecks: isClear ? clearChecks + 1 : 0) }
                print("[DeepLink] \(link) kept: opened now")
                self.open(link, allowsAutoPlay: allowsAutoPlay)
            }
        }
        check(clearChecks: 0)
    }

    private func show(_ link: DeepLink, in tabBarController: TVTabBarController, allowsAutoPlay: Bool) -> Bool {
        print("[DeepLink] \(link)\(allowsAutoPlay ? "" : " (autoplay off)")")
        switch link {
        case .tab(let tab):
            return tabBarController.select(tab)
        case .search(let query):
            return search(query, in: tabBarController)
        case .movie(let id, let title, let play):
            let movie = Movie(title: title ?? "", id: id, largeCoverImage: OpenMetadata.posterURL(imdbId: id)?.absoluteString)
            return showDetail(of: movie, autoPlay: play && allowsAutoPlay, in: tabBarController)
        case .show(let id, let title, let season, let episode, let play):
            // The page opens on the link's season (else on the episode to
            // watch next); a `play` link naming an episode plays that one,
            // and nothing when the show has no such episode.
            let show = Show(title: title ?? "", id: id, largeCoverImage: OpenMetadata.posterURL(imdbId: id)?.absoluteString)
            return showDetail(of: show, autoPlay: play && allowsAutoPlay, season: season, episode: episode, in: tabBarController)
        }
    }

    /// The tabs a title's page opens on. From the others (Settings,
    /// Downloads) the link goes to the title's own tab: a page there would
    /// be one level under a screen it has nothing to do with.
    private static let tabsShowingPages: Set<DeepLink.Tab> = [.home, .movies, .shows, .watchlist, .search]

    /// The title's page on the selected tab (`MainViewController.showDetail`:
    /// at once, or the page of that title already on top), over whatever
    /// that tab shows.
    private func showDetail(of media: Media, autoPlay: Bool, season: Int? = nil, episode: Int? = nil,
                            in tabBarController: TVTabBarController) -> Bool {
        if tabBarController.selectedTabName.map(AppDelegate.tabsShowingPages.contains) != true,
           !tabBarController.select(media is Movie ? .movies : .shows) {
            // Neither Movies nor Shows (never the case today): the first tab
            // that can push a page.
            guard let fallback = tabBarController.viewControllers?.first(where: { $0 is UINavigationController }) else { return false }
            tabBarController.selectedViewController = fallback
        }
        guard let navigationController = tabBarController.selectedViewController as? UINavigationController else { return false }
        afterTransition(of: navigationController) {
            MainViewController.showDetail(of: media, on: navigationController, autoPlay: autoPlay, season: season, episode: episode)
        }
        return true
    }

    /// The Search tab's first screen, with `query` searched (an empty one
    /// only shows the tab).
    private func search(_ query: String, in tabBarController: TVTabBarController) -> Bool {
        guard tabBarController.select(.search),
              let navigationController = tabBarController.selectedViewController as? UINavigationController,
              let search = navigationController.viewControllers.first as? SearchViewController else { return false }
        afterTransition(of: navigationController) {
            _ = navigationController.popToRootViewController(animated: false)
            guard !query.isEmpty else { return }
            // A tab never shown yet has no search bar.
            search.loadViewIfNeeded()
            search.searchBar?.text = query
            search.filterSearchText(query)
        }
        return true
    }

    /// `work` now, or once the push or pop `navigationController` is running
    /// has ended: UIKit drops a navigation change made during a transition.
    private func afterTransition(of navigationController: UINavigationController, _ work: @escaping () -> Void) {
        guard let coordinator = navigationController.transitionCoordinator else { return work() }
        let retry = { [weak self, weak navigationController] in
            DispatchQueue.main.async {
                guard let self, let navigationController else { return }
                self.afterTransition(of: navigationController, work)
            }
        }
        if !coordinator.animate(alongsideTransition: nil, completion: { _ in retry() }) {
            retry()
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
    }

    func applicationWillTerminate(_ application: UIApplication) {
        SubtitlesManager.shared.logout()
    }

    /// Method-swizzling bootstrap — must run before any of these classes
    /// is instantiated.
    ///
    /// The legacy implementation walked **every** Objective-C class
    /// registered in the runtime (`objc_getClassList`) and tried
    /// `as? Object.Type` on each to discover swizzlers. On tvOS that's
    /// ~50 000 classes (UIKit + TVKit + TVUI + TVMLKit + AVKit + libtorrent
    /// + GCDWebServer + …) and the cast is *not* O(1) — it accounted for
    /// most of the 40-second cold launch on Apple TV. iOS was unaffected
    /// because its runtime carries far fewer types.
    ///
    /// We only have three Object conformers in our codebase, all in
    /// PopcornTime.app itself — call them directly. Adding a new
    /// conformer? Append it here.
    func awakeObjects() {
        UIViewController.awake()
        UICollectionView.awake()
        MarqueeLabel.awake()
    }
}
