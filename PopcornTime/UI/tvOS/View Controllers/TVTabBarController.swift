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
