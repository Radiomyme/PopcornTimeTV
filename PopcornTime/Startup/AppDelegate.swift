

import UIKit
import PopcornKit
import Reachability
import ObjectMapper
import MarqueeLabel

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

    var tabBarController: UITabBarController {
        return window?.rootViewController as! UITabBarController
    }

    var activeRootViewController: MainViewController? {
        guard
            let navigationController = tabBarController.selectedViewController as? UINavigationController,
            let main = navigationController.viewControllers.compactMap({$0 as? MainViewController}).first
            else {
                return nil
        }
        return main
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        print("[App] didFinishLaunching tosAccepted=\(UserDefaults.standard.bool(forKey: "tosAccepted"))")

        // Default to wiping torrent caches when the player exits. Apple TV's
        // per-app sandbox is ~7–12 GB; without this each streamed movie
        // leaves 5+ GB of partials behind, and 4K HEVC picks start failing
        // with "not enough space" after 1–2 watches. The user can flip the
        // toggle off in Settings if they want to retain partials for
        // resume-from-disk.
        UserDefaults.standard.register(defaults: ["removeCacheOnPlayerExit": true])

        // And purge any stragglers from previous sessions (crashes, force
        // quits, the toggle being off in the past) before any UI loads.
        purgeOrphanTorrentDownloads()

        if let url = launchOptions?[.url] as? URL {
            return self.application(.shared, open: url)
        }

        let font = UIFont.systemFont(ofSize: 38, weight: UIFont.Weight.heavy)
        UITabBarItem.appearance().setTitleTextAttributes([NSAttributedString.Key.font: font], for: .normal)

        if !UserDefaults.standard.bool(forKey: "tosAccepted") {
            let vc = UIStoryboard.main.instantiateViewController(withIdentifier: "TermsOfServiceNavigationController")
            window?.makeKeyAndVisible()
            /// Set themeSongVolume to its lowest by default
            UserDefaults.standard.set(0.25, forKey: "themeSongVolume")
            OperationQueue.main.addOperation {
                self.activeRootViewController?.present(vc, animated: false) {
                    self.activeRootViewController?.environmentsToFocus = [self.tabBarController.tabBar]
                }
            }
        }

        try? reachability.startNotifier()
        window?.tintColor = .app

        awakeObjects()

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

        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if tabBarController.selectedViewController == viewController, let scrollView = viewController.view.recursiveSubviews.compactMap({$0 as? UIScrollView}).first {
            let offset = CGPoint(x: 0, y: -scrollView.contentInset.top)
            scrollView.setContentOffset(offset, animated: true)
        }
        return true
    }


    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if url.scheme == "PopcornTime" {
            guard
                let actions = url.absoluteString.removingPercentEncoding?.components(separatedBy: "PopcornTime:?action=").last?.components(separatedBy: "»"),
                let type = actions.first, let json = actions.last
                else {
                    return false
            }

            let media: Media = type == "showMovie" ? Mapper<Movie>().map(JSONString: json)! : Mapper<Show>().map(JSONString: json)!

            if let vc = activeRootViewController {
                let storyboard = UIStoryboard.main
                let loadingViewController = storyboard.instantiateViewController(withIdentifier: "LoadingViewController")

                let segue = AutoPlayStoryboardSegue(identifier: type, source: vc, destination: loadingViewController)
                vc.prepare(for: segue, sender: media)

                tabBarController.tabBar.isHidden = true
                vc.navigationController?.push(loadingViewController, animated: true)
            }
        }

        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        UpdateManager.shared.checkVersion(.daily)
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
