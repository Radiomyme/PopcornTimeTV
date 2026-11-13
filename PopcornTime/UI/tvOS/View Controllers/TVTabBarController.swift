import Foundation


class TVTabBarController: UITabBarController {

    /// Where `moveFocus` sends the focus: kept until the focus lands outside
    /// the tab bar (or 2 s), not dropped on the first read. UIKit reads
    /// `preferredFocusEnvironments` more than once in one update: the second
    /// read used to get the tab bar's own answer, its first tab, and the
    /// focus on a tab selects it (the app switched to Movies).
    var environmentsToFocus: [UIFocusEnvironment] = []

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard !environmentsToFocus.isEmpty else { return super.preferredFocusEnvironments }
        // The selected screen next, never the tab bar: a target with nothing
        // focusable yet must not send the focus to a tab.
        return environmentsToFocus + [selectedViewController].compactMap { $0 }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let view = context.nextFocusedView, !view.isDescendant(of: tabBar) { environmentsToFocus.removeAll() }
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
    /// A screen still loading may have nothing focusable yet: the move is
    /// tried again twice a second (`attempts` in all) while the focus stays
    /// in the tab bar.
    func moveFocus(to environment: UIFocusEnvironment, attempts: Int = 5) {
        environmentsToFocus = [environment]
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        let target = environment as AnyObject
        let tab = selectedViewController
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.environmentsToFocus.first.map({ ($0 as AnyObject) === target }) == true else { return }
            guard attempts > 1, self.focusIsInTabBar, self.selectedViewController === tab,
                  let environment = target as? UIFocusEnvironment else {
                self.environmentsToFocus.removeAll()
                return
            }
            self.moveFocus(to: environment, attempts: attempts - 1)
        }
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
        // `moveFocus` (no heading: not the remote) never takes the focus from
        // one tab to another: the focus on a tab selects it, and a target with
        // nothing focusable yet made the focus engine fall back to the first
        // tab (the app switched to Movies).
        if !environmentsToFocus.isEmpty, context.focusHeading.isEmpty,
           let next = context.nextFocusedView, next.isDescendant(of: tabBar),
           let previous = context.previouslyFocusedView, previous.isDescendant(of: tabBar), previous !== next {
            return false
        }
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
