

import UIKit
import PopcornKit
import Reachability
import ObjectMapper

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

    var reachability: Reachability = .forInternetConnection()

    var tabBarController: UITabBarController {
        return window?.rootViewController as! UITabBarController
    }

    var activeRootViewController: MainViewController? {
        guard
            let navigationController = tabBarController.selectedViewController as? UINavigationController,
            let main = navigationController.viewControllers.flatMap({$0 as? MainViewController}).first
            else {
                return nil
        }
        return main
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        if let url = launchOptions?[.url] as? URL {
            return self.application(.shared, open: url)
        }

        let font = UIFont.systemFont(ofSize: 38, weight: UIFontWeightHeavy)
        UITabBarItem.appearance().setTitleTextAttributes([NSFontAttributeName: font], for: .normal)

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

        reachability.startNotifier()
        window?.tintColor = .app

        TraktManager.shared.syncUserData()
        awakeObjects()

        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if tabBarController.selectedViewController == viewController, let scrollView = viewController.view.recursiveSubviews.flatMap({$0 as? UIScrollView}).first {
            let offset = CGPoint(x: 0, y: -scrollView.contentInset.top)
            scrollView.setContentOffset(offset, animated: true)
        }
        return true
    }


    func application(_ app: UIApplication, open url: URL, options: [UIApplicationOpenURLOptionsKey : Any] = [:]) -> Bool {
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

    func awakeObjects() {
        let typeCount = Int(objc_getClassList(nil, 0))
        let types = UnsafeMutablePointer<AnyClass?>.allocate(capacity: typeCount)
        let autoreleasingTypes = AutoreleasingUnsafeMutablePointer<AnyClass?>(types)
        objc_getClassList(autoreleasingTypes, Int32(typeCount))
        for index in 0 ..< typeCount { (types[index] as? Object.Type)?.awake() }
        types.deallocate(capacity: typeCount)
    }
}
