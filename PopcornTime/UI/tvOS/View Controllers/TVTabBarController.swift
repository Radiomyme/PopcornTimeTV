import Foundation


class TVTabBarController: UITabBarController {

    var environmentsToFocus: [UIFocusEnvironment] = []

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        defer { environmentsToFocus.removeAll() }
        return environmentsToFocus.isEmpty ? super.preferredFocusEnvironments : environmentsToFocus
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installGlassSettings()
        installBackFromTabBar()
    }

    // MARK: - Menu (Back) with the focus in the tab bar

    /// The navigation controller of the selected tab when it shows a pushed
    /// screen (a page, the loading screen, a person…).
    private var pushedNavigationController: UINavigationController? {
        guard let navigation = selectedViewController as? UINavigationController,
              navigation.viewControllers.count > 1 else { return nil }
        return navigation
    }

    /// Whether the focus is on a tab.
    var focusIsInTabBar: Bool {
        guard let view = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView else { return false }
        return view.isDescendant(of: tabBar)
    }

    /// Gives the focus to `environment` (a screen of the selected tab).
    func moveFocus(to environment: UIFocusEnvironment) {
        environmentsToFocus = [environment]
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// tvOS leaves the app when Menu is pressed in the tab bar. Over a pushed
    /// screen that is not one level back: the focus is there only because
    /// that screen had nothing to focus (a page still loading, an error), or
    /// because the user went up to the tabs from a person's page. Menu then
    /// goes back in the tab, as from the screen itself; on a tab's first
    /// screen it still leaves the app.
    private func installBackFromTabBar() {
        let menu = UITapGestureRecognizer(target: self, action: #selector(backFromTabBar))
        menu.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        // Its own delegate object: UITabBarController may be the delegate of
        // its private recognizers, which must keep their own answers.
        backFromTabBarGate.shouldBegin = { [weak self] in self?.pushedNavigationController != nil }
        menu.delegate = backFromTabBarGate
        tabBar.addGestureRecognizer(menu)
    }

    private let backFromTabBarGate = GestureGate()

    /// One screen back; the screen shown then takes the focus from the tab
    /// bar (`TVNavigationController`'s `didShow`).
    @objc private func backFromTabBar() {
        pushedNavigationController?.popViewController(animated: true)
    }

    /// The Settings tab shows `GlassSettingsView`. The storyboard's navigation
    /// controller stays; its root, the old table page, is replaced before it
    /// ever loads. That root is the only tab root without a custom class,
    /// which is how the tab is found.
    ///
    /// The tab is a gear, like the magnifying glass of Search: with the
    /// system "Downloads" title, the French titles ("Téléchargements",
    /// "Réglages"…) no longer fit the tvOS 26 tab bar, which cut the last one.
    /// VoiceOver still reads "Settings".
    private func installGlassSettings() {
        let settingsTab = viewControllers?
            .compactMap { $0 as? UINavigationController }
            .first { navigation in
                navigation.viewControllers.first.map { type(of: $0) == UIViewController.self } ?? false
            }
        guard let settingsTab else { return }
        settingsTab.setViewControllers([GlassSettingsHostingController()], animated: false)
        // Sized like the Search glyph (the default symbol size is much smaller).
        let gear = UIImage(systemName: "gearshape.fill",
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .bold))
        let item = UITabBarItem(title: nil, image: gear, selectedImage: nil)
        item.accessibilityLabel = glassSettingsLocalized("Settings")
        settingsTab.tabBarItem = item
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // Sort / Genre moved from custom-view UIButtons (legacy storyboard)
        // to native `UIBarButtonItem`s — see
        // `MainViewController.installModernRightBarButtonItems`. tvOS 17+
        // routes focus through native bar items automatically (they are
        // first-class focus environments alongside tab pills and the
        // collection view), so the bespoke redirect this method used to
        // perform is no longer needed and would actually fight the system's
        // routing. Default behaviour: let the focus engine decide.
        return super.shouldUpdateFocus(in: context)
    }
}

/// Lets a gesture recognizer begin only when `shouldBegin` says so (Menu in
/// the tab bar is taken only over a pushed screen).
private final class GestureGate: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: () -> Bool = { true }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return shouldBegin()
    }
}
