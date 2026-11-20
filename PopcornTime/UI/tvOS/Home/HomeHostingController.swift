// HomeHostingController.swift — puts `HomeView` in the first tab of the app
// and connects it to the rest: the hub (`HomeState`, PopcornKit), the
// title pages (`MainViewController.showDetail`, the entry point the grids
// use), the Movies / Shows / Watchlist tabs for See All, the user's library
// for the cards' menus, and the tab bar, which follows the page's scroll.
import UIKit
import SwiftUI
import PopcornKit

/// Root of the Home tab (installed by `TVTabBarController`).
final class HomeHostingController: UIHostingController<HomeView> {

    let model: HomePageModel
    private var home: HomeState { model.home }

    /// The page's vertical scroll view, once found (`viewDidLayoutSubviews`).
    private weak var pageScrollView: UIScrollView?
    private var hasAppeared = false
    /// The Terms of Service are accepted: the lists may be asked.
    private var termsAreAccepted = false

    /// - Parameter home: the hub the page shows (`HomeState.shared`; a DEBUG
    ///   launch hook gives one fed from recorded answers).
    init(home: HomeState) {
        // The page saved by the last session, painted before the first
        // frame of the tab: a warm launch never shows an empty page (the
        // disk was read in the background, its page arrived ~1.7 s after
        // launch). Main-thread file reads, measured in every build (one
        // line per launch: the Apple TV session's number, decision D-E4);
        // the plan's limit is ~50 ms on an Apple TV HD. A first launch
        // paints nothing and keeps the placeholders.
        let paintStart = CACurrentMediaTime()
        let painted = home.paintFromDisk()
        print(String(format: "[Measure] home paint from disk: %@ in %.1f ms (%d shelves)", painted ? "yes" : "no",
                     (CACurrentMediaTime() - paintStart) * 1000, home.shelves.count))
        model = HomePageModel(home: home)
        super.init(rootView: HomeView(model: model))
        // Its backdrop asked now, not when the tab appears.
        if painted { model.showHeroBackdrop() }
        model.actions = makeActions()
        model.focusIsInPage = { [weak self] in self?.focusIsInPage ?? false }
        model.pullFocus = { [weak self] in
            // Only into the page on screen: never from another tab's.
            guard let self, self.viewIfLoaded?.window != nil, let tabs = self.tabBarController as? TVTabBarController,
                  tabs.selectedViewController === (self.navigationController ?? self) else { return }
            tabs.moveFocus(to: self, attempts: 1)
        }
        // Nothing is asked of the network before the Terms of Service are
        // accepted (a fresh install shows them over this tab): the lists
        // start once they are.
        termsAreAccepted = TermsOfServiceViewController.areAccepted
        if termsAreAccepted {
            home.start()
        } else {
            print("[Home] the lists wait for the Terms of Service to be accepted")
            NotificationCenter.default.addObserver(self, selector: #selector(termsAccepted),
                                                   name: TermsOfServiceViewController.acceptedNotification, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        #if DEBUG
        HomeDebug.attach(to: self)
        #endif
    }

    @available(*, unavailable, message: "Created in code by TVTabBarController")
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        installEntryGuide()
    }

    // MARK: - Down from the tab bar

    /// Where the focus enters the page from the tab bar. The focus engine
    /// goes by geometry: under the Home tab it found More Info, not Play,
    /// and — the page left in its shelves — whichever card was under the
    /// tab. This guide lies across the screen under the tab bar and hands
    /// the focus to the page's own choice (`HomeView`'s default focus: Play,
    /// or the card the focus left). On only while the focus is outside the
    /// page: from inside, Up must reach the tab bar.
    private let entryGuide = UIFocusGuide()

    private func installEntryGuide() {
        view.addLayoutGuide(entryGuide)
        NSLayoutConstraint.activate([
            entryGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            entryGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            entryGuide.topAnchor.constraint(equalTo: view.topAnchor, constant: TVHomeLayout.tabBarBand),
            entryGuide.heightAnchor.constraint(equalToConstant: 420),
        ])
        entryGuide.preferredFocusEnvironments = [view]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let inPage = contains(context.nextFocusedItem)
        entryGuide.isEnabled = !inPage
        if let tabBar = tabBarController?.tabBar {
            model.tabBarHasFocus = context.nextFocusedView?.isDescendant(of: tabBar) ?? false
        }
        // A direction of the remote, or the page (or the system) moving it.
        model.focusUpdated(byUser: !context.focusHeading.isEmpty, inPage: inPage)
    }

    /// Is this item (a SwiftUI one is not a view) inside the page?
    private func contains(_ item: UIFocusItem?) -> Bool {
        var environment: UIFocusEnvironment? = item
        while let current = environment {
            if current === self || current === view { return true }
            environment = current.parentFocusEnvironment
        }
        return false
    }

    /// The focus, as UIKit has it, is on something of the page.
    private var focusIsInPage: Bool {
        return contains(UIFocusSystem.focusSystem(for: self)?.focusedItem)
    }

    // MARK: - Appearance

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The page draws under the tab bar, like a title's page: no bar of
        // the navigation controller over it.
        navigationController?.setNavigationBarHidden(true, animated: false)
        model.isVisible = true
        guard hasAppeared else { return }
        // Back on the tab, or back from a title's page: what the user did
        // meanwhile (watched, added to the watchlist) is in the local
        // shelves at once, and the lists that are no longer fresh are asked.
        home.refreshLocal()
        if termsAreAccepted { home.start() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        #if DEBUG
        HomeDebug.mark("the tab is on screen")
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        model.pageWillDisappear()
    }

    /// Back in the foreground with the tab on screen: the lists whose
    /// freshness has lapsed meanwhile are asked again (`start()` asks no
    /// other), and the local shelves are read again.
    @objc private func applicationWillEnterForeground() {
        guard viewIfLoaded?.window != nil else { return }
        model.isVisible = true
        home.refreshLocal()
        if termsAreAccepted { home.start() }
    }

    @objc private func termsAccepted() {
        NotificationCenter.default.removeObserver(self, name: TermsOfServiceViewController.acceptedNotification, object: nil)
        termsAreAccepted = true
        print("[Home] the Terms of Service are accepted: the lists start")
        home.start()
    }

    @objc private func applicationDidEnterBackground() {
        // The hero stops turning its pages behind the Home screen.
        model.isVisible = false
    }

    // MARK: - The tab bar follows the page

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        followPageScroll()
    }

    /// The tab bar goes away as the page scrolls down and comes back at its
    /// top, as on the grids (`MainViewController.installInBodyHeader`): the
    /// page's vertical scroll view, the outermost one of the hosted view, is
    /// declared as this screen's content scroll view. (tvOS 26.5 finds a
    /// hosted SwiftUI scroll view by itself — the bar already followed the
    /// page without this, checked in the simulator; said all the same, for
    /// the systems before it, where that could not be checked.)
    private func followPageScroll() {
        guard pageScrollView == nil, let scrollView = HomeHostingController.outermostScrollView(in: view) else { return }
        pageScrollView = scrollView
        setContentScrollView(scrollView, for: .top)
    }

    /// Breadth first: the page's scroll view is above its rows' own.
    private static func outermostScrollView(in root: UIView) -> UIScrollView? {
        var level = [root]
        while !level.isEmpty {
            if let found = level.compactMap({ $0 as? UIScrollView }).first { return found }
            level = level.flatMap(\.subviews)
        }
        return nil
    }

    // MARK: - Actions

    private func makeActions() -> HomeActions {
        var actions = HomeActions()
        actions.open = { [weak self] item, shelf in self?.open(item, from: shelf, play: false) }
        actions.play = { [weak self] item, shelf in self?.open(item, from: shelf, play: true) }
        actions.seeAll = { [weak self] shelf in self?.seeAll(shelf) }
        actions.isInWatchlist = { Library.shared.isInWatchlist($0.imdbId) }
        actions.toggleWatchlist = { item in
            if let movie = item.movie {
                WatchlistManager<Movie>.movie.toggle(movie)
            } else if let show = item.show {
                WatchlistManager<Show>.show.toggle(show)
            }
        }
        actions.isWatched = { item in
            // An episode still to air is not offered "Mark as Watched"
            // (one marked all the same can still be unmarked).
            guard let id = item.watchedID else { return nil }
            let watched = Library.shared.isWatched(id)
            return watched || item.hasAired() ? watched : nil
        }
        actions.toggleWatched = { item in
            guard let id = item.watchedID else { return }
            if item.kind == .movie {
                WatchedlistManager<Movie>.movie.toggle(id)
            } else {
                WatchedlistManager<Episode>.episode.toggle(id)
            }
        }
        actions.removeFromContinueWatching = { item in
            guard let card = Library.shared.continueWatching(limit: 200).first(where: { $0.imdbID == item.imdbId }) else { return }
            Library.shared.removeFromContinueWatching(card)
        }
        return actions
    }

    /// The title's page, through the loading screen, as from a grid's
    /// poster. `play`: the page then starts its playback (the detail page's
    /// own entry point: a resume card continues where the library says, an
    /// episode's card plays that episode).
    private func open(_ item: HomeItem, from shelf: String?, play: Bool) {
        guard let navigationController, let media = item.media else { return }
        var autoPlay = play
        #if DEBUG
        // `-PTDebugHomeDryRunPlay`: a UI test or a screenshot run never plays.
        if play, HomeDebug.isDryRunPlay {
            HomeDebug.notePlay(of: item, from: shelf)
            autoPlay = false
        }
        #endif
        // A resume card plays what the page's Play button plays (the
        // library's own rule); any other episode card names its episode.
        let episode = shelf == HomeShelfID.continueWatching ? nil : item.episode
        // The card's formats: its page opens with them, and keeps them.
        if item.kind == .movie { GlassDetailSeed.note(badges: GlassBadgeMerge.badges(of: item), of: item.imdbId) }
        MainViewController.showDetail(of: media, on: navigationController, autoPlay: autoPlay,
                                      season: episode?.season, episode: episode?.number)
    }

    /// The shelf's own titles, in its order, under its name, on the Home's
    /// stack (Menu comes back to its See All card) — not the catalogue's
    /// tab, which lists another selection in another order.
    private func seeAll(_ shelf: HomeShelf) {
        guard let navigationController, !shelf.items.isEmpty else { return }
        let actions = makeActions()
        var cards = HomeCardActions()
        cards.select = { [weak self] item, shelf in
            // A resume card resumes, as on the Home.
            self?.open(item, from: shelf.id, play: shelf.id == HomeShelfID.continueWatching)
        }
        cards.play = { [weak self] item, shelf in self?.open(item, from: shelf.id, play: true) }
        cards.isInWatchlist = actions.isInWatchlist
        cards.toggleWatchlist = actions.toggleWatchlist
        cards.isWatched = actions.isWatched
        cards.toggleWatched = actions.toggleWatched
        let text = HomeText.standard
        let grid = HomeSeeAllGrid(shelf: shelf, title: text.title(of: shelf), text: text, actions: cards,
                                  more: HomeSeeAllMore(pages: shelf.seeAll?.streamingPages()))
        navigationController.pushViewController(HomeSeeAllHostingController(grid: grid), animated: true)
    }
}
