

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
/// (10 s later). Nothing happens without these arguments.
private enum DebugLaunchHooks {
    static func run() {
        let defaults = UserDefaults.standard
        // `-PTDebugPlayTorrent <file>` (BoundedStorageDebugHooks): the normal
        // play flow on a local .torrent, once the launch screens are up.
        if let file = BoundedStorageDebugHooks.torrentFile {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("[BoundedDebug] playing \(file)")
                AppDelegate.shared.play(Movie(title: "Bounded storage test", id: "tt0000000"),
                                        torrent: Torrent(url: file, quality: "1080p"))
            }
            return
        }
        let tab = defaults.string(forKey: "PTDebugTab").flatMap { Int($0) }
        let media: Media? = defaults.string(forKey: "PTDebugOpenMovie").map { Movie(title: $0, id: $0) }
            ?? defaults.string(forKey: "PTDebugOpenShow").map { Show(title: $0, id: $0) }
        let focusContent = defaults.bool(forKey: "PTDebugFocusContent")
        guard tab != nil || media != nil else { return }
        // After the launch screens (Terms of Service, What's New) are up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let tabBarController = AppDelegate.shared.tabBarController
            if let tab, (0..<(tabBarController.viewControllers?.count ?? 0)).contains(tab) {
                tabBarController.selectedIndex = tab
            }
            guard let navigationController = tabBarController.selectedViewController as? UINavigationController else { return }
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
