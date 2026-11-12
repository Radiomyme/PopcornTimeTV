

import UIKit
import PopcornKit
import Reachability
import ObjectMapper
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
            self.activeRootViewController?.present(vc, animated: false) {
                self.activeRootViewController?.environmentsToFocus = [self.tabBarController.tabBar]
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


    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if url.scheme == "PopcornTime" {
            // Playback is presented from the root view controller, which must
            // not be showing the release notes then.
            WhatsNewPresenter.dismiss(animated: false)

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
