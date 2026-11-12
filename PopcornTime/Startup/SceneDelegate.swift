

import UIKit
#if DEBUG
import PopcornKit
#endif

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

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIStoryboard(name: "tvOS", bundle: nil).instantiateInitialViewController()
        window.tintColor = .app
        self.window = window

        // Keep the legacy AppDelegate.window reference valid.
        AppDelegate.shared.window = window
        window.makeKeyAndVisible()

        AppDelegate.shared.presentTermsOfServiceIfNeeded()

        // Release notes, once per version. A fresh install (Terms of Service
        // not accepted yet) and a launch to open a URL (Top Shelf) skip them.
        if let root = window.rootViewController {
            WhatsNewPresenter.presentAtLaunchIfNeeded(
                from: root,
                isFreshInstall: !UserDefaults.standard.bool(forKey: "tosAccepted"),
                launchedFromURL: !connectionOptions.urlContexts.isEmpty)
        }

        if let url = connectionOptions.urlContexts.first?.url {
            _ = AppDelegate.shared.application(.shared, open: url)
        }

        #if DEBUG
        DebugLaunchHooks.run()
        #endif
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            _ = AppDelegate.shared.application(.shared, open: url)
        }
    }
}

#if DEBUG
/// Simulator verification hooks, compiled only with DEBUG (the app targets do
/// not define it: build with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` on the
/// xcodebuild command line). Launch arguments: `-PTDebugTab <index>` selects
/// that tab; `-PTDebugOpenMovie <IMDb id>` or `-PTDebugOpenShow <IMDb id>` then
/// opens the title's page on the selected tab through
/// `MainViewController.showDetail` (loading screen, then the page), never with
/// autoplay; `-PTDebugReopenAfter <seconds>` then goes back to the tab's root
/// and opens the same page again (a show then comes from the provider's cache,
/// the case that must wait for the loading screen's push);
/// `-PTDebugFocusContent YES` moves the focus from the tab bar into the page
/// shown (as a remote would); `-PTDebugFocusSection <episodes|related|cast|info>`
/// then moves it down into that section of the detail page once it has loaded
/// (10 s later). Grids and sources:
/// `-PTDebugFilter <raw value>` (e.g. top100) sets the Movies / Shows tab's
/// filter; `-PTDebugSortMenu YES` then opens its Sort menu;
/// `-PTDebugOpenItem <index>` opens the grid's item at that index once it has
/// loaded (as a click would, never with autoplay); `-PTDebugQualityPicker YES`
/// shows the page's quality chooser once loaded (a pick only logs: nothing
/// plays); `-PTDebugSearch <text>` searches the text on the Search tab;
/// `-PTDebugTop100Offline YES` turns The Pirate Bay off and deletes the
/// cached Top 100 lists (the grid's error state). Nothing happens without
/// these arguments.
private enum DebugLaunchHooks {
    static func run() {
        let defaults = UserDefaults.standard
        let tab = defaults.string(forKey: "PTDebugTab").flatMap { Int($0) }
        let media: Media? = defaults.string(forKey: "PTDebugOpenMovie").map { Movie(title: $0, id: $0) }
            ?? defaults.string(forKey: "PTDebugOpenShow").map { Show(title: $0, id: $0) }
        let focusContent = defaults.bool(forKey: "PTDebugFocusContent")
        let filter = defaults.string(forKey: "PTDebugFilter")
        let openItem = defaults.string(forKey: "PTDebugOpenItem").flatMap { Int($0) }
        let search = defaults.string(forKey: "PTDebugSearch")
        if defaults.bool(forKey: "PTDebugTop100Offline") { takeTop100Offline() }
        guard tab != nil || media != nil || search != nil else { return }
        // After the launch screens (Terms of Service, What's New) are up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let tabBarController = AppDelegate.shared.tabBarController
            if let tab, (0..<(tabBarController.viewControllers?.count ?? 0)).contains(tab) {
                tabBarController.selectedIndex = tab
            }
            if let search { return run(search: search, in: tabBarController) }
            guard let navigationController = tabBarController.selectedViewController as? UINavigationController else { return }
            let root = navigationController.viewControllers.first
            if let filter { apply(filter: filter, to: root) }
            if defaults.bool(forKey: "PTDebugSortMenu") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if let movies = root as? MoviesViewController { movies.showFilters(movies) }
                    if let shows = root as? ShowsViewController { shows.showFilters(shows) }
                }
            }
            if let openItem, let grid = root as? MainViewController {
                return open(item: openItem, of: grid, on: navigationController, in: tabBarController, focus: focusContent)
            }
            guard let media else {
                if focusContent { focus(navigationController.topViewController, in: tabBarController, after: 1) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainViewController.showDetail(of: media, on: navigationController, autoPlay: false)
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

    /// Once the detail page has replaced the loading screen (checked twice a
    /// second for 30 s), moves the focus into it.
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

    private static func focus(_ viewController: UIViewController?, in tabBarController: UITabBarController, after delay: Double) {
        guard let viewController, let tabBarController = tabBarController as? TVTabBarController else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            tabBarController.environmentsToFocus = [viewController]
            tabBarController.setNeedsFocusUpdate()
            tabBarController.updateFocusIfNeeded()
        }
    }
}
#endif
