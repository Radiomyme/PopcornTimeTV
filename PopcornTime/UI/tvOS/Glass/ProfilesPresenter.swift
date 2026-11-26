// ProfilesPresenter.swift — « Who's Watching? » on the Apple TV: at launch
// (SceneDelegate, when the device has more than one profile) and from
// Settings (Profiles › Switch Profile / Manage Profiles).

import UIKit
import SwiftUI
import PopcornKit

enum ProfilesPresenter {

    /// The launch screen: the picker as the window's root. `then` installs
    /// the app's interface once a profile is picked.
    static func launchPicker(in window: UIWindow, then installInterface: @escaping () -> Void) {
        let picker = UIHostingController(rootView: ProfilePickerView(onPick: { _ in
            installInterface()
        }))
        picker.view.backgroundColor = .black
        window.rootViewController = picker
    }

    /// From Settings: the picker over the app. Picking another profile
    /// rebuilds the app's interface (every screen then reads the new
    /// profile's library and preferences); the same one only closes it.
    static func present(from presenter: UIViewController, managing: Bool = false) {
        let before = ProfileManager.shared.activeID
        weak var host: UIViewController?
        let view = ProfilePickerView(startsManaging: managing, onPick: { profile in
            if profile.id == before {
                host?.dismiss(animated: true)
            } else {
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
        host = controller
        presenter.present(controller, animated: true)
    }

    /// Settings › Profiles › Your Preferences, over the app.
    static func presentTaste(from presenter: UIViewController) {
        weak var host: UIViewController?
        let controller = UIHostingController(rootView: ProfileTasteView(onClose: { host?.dismiss(animated: true) }))
        controller.view.backgroundColor = .black
        controller.modalPresentationStyle = .fullScreen
        host = controller
        presenter.present(controller, animated: true)
    }

    /// The app's interface made again, from the storyboard, with a dissolve.
    static func rebuildInterface() {
        guard let window = AppDelegate.shared.window else { return }
        let root = UIStoryboard(name: "tvOS", bundle: nil).instantiateInitialViewController()
        UIView.transition(with: window, duration: 0.35, options: .transitionCrossDissolve) {
            // The picker (and whatever the old interface presented) goes
            // with it.
            window.rootViewController?.dismiss(animated: false)
            window.rootViewController = root
        }
    }
}
