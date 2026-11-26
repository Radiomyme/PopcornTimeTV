// ProfilesPresenter.swift — « Who's Watching? » on the Apple TV: at launch
// (SceneDelegate, when the device has more than one profile) and from
// Settings (Profiles › Switch Profile). Your Preferences is a sheet of the
// Settings page itself (`GlassSettingsTasteSheet`).

import UIKit
import SwiftUI
import PopcornKit

enum ProfilesPresenter {

    /// A link that arrived while the launch question was up (the Top Shelf,
    /// another app): opened once a profile is picked, as if it had launched
    /// the app.
    typealias KeptLink = (link: DeepLink, allowsAutoPlay: Bool)

    /// The launch question is the window's root: the app's interface is not
    /// there yet to open a link in (`AppDelegate.open`).
    private(set) static var isAskingAtLaunch = false
    private static var keptLink: KeptLink?

    /// The launch screen: the picker as the window's root. `then` installs
    /// the app's interface once a profile is picked, and opens the link
    /// that came meanwhile, if any. Menu there is the system's: it leaves
    /// the app for the Home Screen.
    static func launchPicker(in window: UIWindow, then installInterface: @escaping (KeptLink?) -> Void) {
        isAskingAtLaunch = true
        keptLink = nil
        let picker = UIHostingController(rootView: ProfilePickerView(onPick: { profile in
            ProfileManager.shared.activate(profile.id)
            isAskingAtLaunch = false
            let kept = keptLink
            keptLink = nil
            installInterface(kept)
        }))
        picker.view.backgroundColor = .black
        window.rootViewController = picker
    }

    /// A link while the launch question is up: kept (the latest only) for
    /// after the pick. False when the question is not up.
    static func keepUntilPicked(_ link: DeepLink, allowsAutoPlay: Bool) -> Bool {
        guard isAskingAtLaunch else { return false }
        keptLink = (link, allowsAutoPlay)
        return true
    }

    /// From Settings: the picker over the app, cross-faded in. Picking
    /// another profile rebuilds the app's interface (every screen then reads
    /// the new profile's library and preferences); the same one, or Menu,
    /// only closes it — Settings is as it was.
    static func present(from presenter: UIViewController) {
        let before = ProfileManager.shared.activeID
        weak var host: UIViewController?
        let view = ProfilePickerView(onPick: { profile in
            if profile.id == before {
                host?.dismiss(animated: true)
            } else {
                ProfileManager.shared.activate(profile.id)
                rebuildInterface()
            }
        }, onCancel: {
            host?.dismiss(animated: true)
            // Managing may have deleted the active profile: the primary one
            // is active then, and the interface must follow.
            if ProfileManager.shared.activeID != before { rebuildInterface() }
        })
        let controller = UIHostingController(rootView: view)
        controller.view.backgroundColor = .black
        controller.modalPresentationStyle = .fullScreen
        controller.modalTransitionStyle = .crossDissolve
        host = controller
        presenter.present(controller, animated: true)
    }

    /// The app's interface made again, from the storyboard, with a dissolve
    /// (none under Reduce Motion).
    static func rebuildInterface() {
        guard let window = AppDelegate.shared.window else { return }
        let root = UIStoryboard(name: "tvOS", bundle: nil).instantiateInitialViewController()
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.35
        UIView.transition(with: window, duration: duration, options: .transitionCrossDissolve) {
            // The picker (and whatever the old interface presented) goes
            // with it.
            window.rootViewController?.dismiss(animated: false)
            window.rootViewController = root
        }
    }
}
