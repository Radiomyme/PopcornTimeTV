

import Foundation
import UIKit.UIAlertController

extension UIAlertController {

    /// Presents the alert from the foreground key-window's top-most VC.
    ///
    /// The legacy implementation built a brand-new `UIWindow` at
    /// `.alert` level and presented from a synthetic `UIViewController`.
    /// That works on iOS but on tvOS the focus engine has to walk a
    /// chain that includes the *active* `UIWindowScene`, and the new
    /// window often ends up unfocusable — the alert appears on screen
    /// but pressing the Siri Remote does nothing because no actionable
    /// element is in the focus environment.
    ///
    /// We now resolve the active foreground scene's key window and
    /// present the alert from whatever is currently on top of it. The
    /// alert inherits the active scene, the focus engine routes Siri
    /// Remote presses to its action buttons natively, and we still
    /// hop to the main thread defensively so background callbacks
    /// (PTTorrentStreamer, Alamofire) can call `show()` without
    /// crashing.
    func show(animated flag: Bool, completion: (() -> Void)? = nil) {
        let perform = { [self] in
            guard let presenter = topMostViewController() else { return }
            presenter.present(self, animated: flag, completion: completion)
        }
        if Thread.isMainThread { perform() } else { DispatchQueue.main.async(execute: perform) }
    }

    /// Walk the foreground active scene's window hierarchy to the
    /// top-most presented view controller.
    private func topMostViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        let key = scene?.windows.first(where: { $0.isKeyWindow })
            ?? scene?.windows.first

        var top = key?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
