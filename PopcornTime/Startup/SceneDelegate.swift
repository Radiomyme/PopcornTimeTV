

import UIKit

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

        if let url = connectionOptions.urlContexts.first?.url {
            _ = AppDelegate.shared.application(.shared, open: url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            _ = AppDelegate.shared.application(.shared, open: url)
        }
    }
}
