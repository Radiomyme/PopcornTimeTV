import UIKit
import PopcornKit


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
        var environments = environmentsToFocus + [selectedViewController].compactMap { $0 }
        // Last, the tab that has the focus: it stays there until the target
        // can take it. With nothing focusable in this list (a page that
        // replaced its loading screen at once, its content not laid out
        // yet), the focus engine went to the first tab, and the focus on a
        // tab selects it: now and then the app showed the first tab instead
        // of the page a link had just opened on another one.
        if let tab = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView, tab.isDescendant(of: tabBar) {
            environments.append(tab)
        }
        return environments
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let view = context.nextFocusedView, !view.isDescendant(of: tabBar) { environmentsToFocus.removeAll() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Behind the grids (Movies, Shows, Watchlist, Search), which draw no
        // background of their own: the Home's black, not the system's grey.
        view.backgroundColor = .black
        installGlassSettings()
        installDownloadsIcon()
        installHome()
        installBackFromTabBar()
        noteSelectedTab()
    }

    // MARK: - Tabs by name

    /// The tabs added in code (`insert(_:as:at:)`), which say their name; the
    /// storyboard's tabs are recognised by their first screen.
    private var addedTabs: [DeepLink.Tab: UIViewController] = [:]

    /// The name of a tab (one of `viewControllers`): what a link
    /// (`popcorntime://tab/movies`), the DEBUG launch hooks and the UI tests
    /// call it. Never its index: a tab inserted before the others (Home)
    /// moves them all.
    func name(of viewController: UIViewController) -> DeepLink.Tab? {
        if let added = addedTabs.first(where: { $0.value === viewController }) { return added.key }
        let root = (viewController as? UINavigationController)?.viewControllers.first ?? viewController
        switch root {
        case is MoviesViewController: return .movies
        case is ShowsViewController: return .shows
        case is WatchlistViewController: return .watchlist
        case is SearchViewController: return .search
        case is DownloadViewController: return .downloads
        case is GlassSettingsHostingController: return .settings
        default: return nil
        }
    }

    /// The tab of that name; nil when the app has none.
    func viewController(for tab: DeepLink.Tab) -> UIViewController? {
        // Settings gets its first screen in `viewDidLoad`.
        loadViewIfNeeded()
        return viewControllers?.first { name(of: $0) == tab }
    }

    /// The selected tab's name (`selectedTab` is UIKit's own, a UITab).
    var selectedTabName: DeepLink.Tab? {
        return selectedViewController.flatMap(name(of:))
    }

    override var selectedViewController: UIViewController? {
        didSet { noteSelectedTab() }
    }

    override var selectedIndex: Int {
        didSet { noteSelectedTab() }
    }

    /// The tab bar's identifier says which tab is selected ("TabBar.shows"),
    /// for VoiceOver tools and the UI tests: the tvOS 26 tab bar does not
    /// mark the selected tab for them.
    private func noteSelectedTab() {
        guard isViewLoaded else { return }
        tabBar.accessibilityIdentifier = "TabBar." + (selectedTabName?.rawValue ?? "other")
        #if DEBUG
        // The detail page hides the tab bar: the tests read the tab here then.
        HomeDebug.noteSelectedTab(selectedTabName?.rawValue ?? "other")
        #endif
    }

    /// Selects the tab of that name, as it was left. False without such a tab.
    @discardableResult
    func select(_ tab: DeepLink.Tab) -> Bool {
        guard let viewController = viewController(for: tab) else { return false }
        selectedViewController = viewController
        return true
    }

    /// Adds a tab made in code at `index` (0: before the others), under the
    /// name `tab`. The selected tab stays selected.
    func insert(_ viewController: UIViewController, as tab: DeepLink.Tab, at index: Int) {
        addedTabs[tab] = viewController
        var tabs = viewControllers ?? []
        tabs.insert(viewController, at: min(max(index, 0), tabs.count))
        setViewControllers(tabs, animated: false)
        noteSelectedTab()
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
    /// goes back in the tab, as from the screen itself. On a tab's first
    /// screen, from the tab bar Menu goes to Home (`menuGoesHome`), and from
    /// Home leaves the app.
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

    // MARK: - Menu (Back) at a tab's root: Home first

    /// Whether Menu, which nothing below took, goes to Home instead of
    /// leaving the app: on the first screen of a tab other than Home, with
    /// nothing presented and nothing being pushed or popped. Home's own Menu
    /// (and the second press, once on Home) still leaves the app, as on every
    /// tvOS app. Playback, cards and sheets are presented: they keep theirs.
    private var menuGoesHome: Bool {
        guard let selected = selectedViewController, name(of: selected) != .home,
              presentedViewController == nil, selected.presentedViewController == nil else { return false }
        guard let navigation = selected as? UINavigationController else { return true }
        return navigation.viewControllers.count == 1 && navigation.transitionCoordinator == nil
            && navigation.topViewController?.presentedViewController == nil
    }

    /// Menu taken in `pressesBegan`: its end goes Home, and it never reaches
    /// the system (which leaves the app on it).
    private var menuIsGoingHome = false

    // The presses come here up the responder chain only when no screen below
    // took them (a pushed page pops, a grid goes back to its top, a sheet
    // closes): all of Menu's phases stay here then.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }), menuGoesHome else { return super.pressesBegan(presses, with: event) }
        menuIsGoingHome = true
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }), menuIsGoingHome else { return super.pressesEnded(presses, with: event) }
        menuIsGoingHome = false
        goHome()
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }), menuIsGoingHome else { return super.pressesCancelled(presses, with: event) }
        menuIsGoingHome = false
    }

    /// Home, as it was left; the focus goes into it (left on the tab bar, it
    /// would stay on the tab Menu came from, and the focus on a tab selects it).
    private func goHome() {
        guard let home = viewController(for: .home) else { return }
        selectedViewController = home
        let root = (home as? UINavigationController)?.topViewController ?? home
        moveFocus(to: root)
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
        settingsTab.tabBarItem = TVTabBarController.iconItem("gearshape.fill", label: glassSettingsLocalized("Settings"))
    }

    /// Downloads is an icon too (it was the system item, a text):
    /// "Téléchargements" took the place of two tabs, and the bar has to hold
    /// one more title, Home. VoiceOver still reads "Downloads".
    private func installDownloadsIcon() {
        guard let downloadsTab = viewControllers?.first(where: { name(of: $0) == .downloads }) else { return }
        downloadsTab.tabBarItem = TVTabBarController.iconItem("arrow.down.circle.fill", label: "Downloads".localized)
    }

    /// A tab shown as a symbol, sized like the Search glyph (the default
    /// symbol size is much smaller); `label` is what VoiceOver reads.
    private static func iconItem(_ symbol: String, label: String) -> UITabBarItem {
        let image = UIImage(systemName: symbol,
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .bold))
        let item = UITabBarItem(title: nil, image: image, selectedImage: nil)
        item.accessibilityLabel = label
        return item
    }

    // MARK: - Home

    /// Home is the first tab, selected at launch: the hub's page
    /// (`HomeHostingController`), made in code like the Settings page, in a
    /// navigation controller of its own — a title's page opens over it as
    /// over a grid. Its title is a text: Downloads and Settings are icons so
    /// that it fits the bar in every language.
    private func installHome() {
        #if DEBUG
        // `-PTDebugHomeFixtures`: recorded answers instead of the network.
        let state = HomeDebug.makeState()
        #else
        let state = HomeState.shared
        #endif
        let home = TVNavigationController(rootViewController: HomeHostingController(home: state))
        home.tabBarItem = UITabBarItem(title: "Home".localized, image: nil, selectedImage: nil)
        insert(home, as: .home, at: 0)
        select(.home)
    }

    /// What a Home shelf's See All card opens: the Movies or Shows tab on
    /// that shelf's sort and genre, at its first screen, or the Watchlist.
    /// The focus, which was on the card, follows into the grid. False
    /// without such a tab.
    @discardableResult
    func showCatalogue(_ seeAll: HomeSeeAll) -> Bool {
        guard let tab = viewController(for: seeAll.tab) else { return false }
        let navigation = tab as? UINavigationController
        _ = navigation?.popToRootViewController(animated: false)
        let root = navigation?.viewControllers.first ?? tab
        // A grid never shown yet reads its sort and genre at its first load;
        // one on screen reloads when either changes (their `didSet`).
        if let movies = root as? MoviesViewController {
            if let filter = seeAll.movieFilter, movies.currentFilter != filter { movies.currentFilter = filter }
            if movies.currentGenre != seeAll.genreFilter { movies.currentGenre = seeAll.genreFilter }
        } else if let shows = root as? ShowsViewController {
            if let filter = seeAll.showFilter, shows.currentFilter != filter { shows.currentFilter = filter }
            if shows.currentGenre != seeAll.genreFilter { shows.currentGenre = seeAll.genreFilter }
        }
        selectedViewController = tab
        root.loadViewIfNeeded()
        moveFocus(to: (root as? MainViewController)?.collectionView ?? root)
        #if DEBUG
        HomeDebug.noteCatalogue(shown: root, for: seeAll)
        #endif
        return true
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
