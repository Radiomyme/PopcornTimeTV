

import UIKit
import PopcornKit
import class PopcornTorrent.PTTorrentDownloadManager
import MediaPlayer.MPMediaItem

class MainViewController: UIViewController, CollectionViewControllerDelegate {
    
    func load(page: Int) {}
    func collectionView(isEmptyForUnknownReason collectionView: UICollectionView) {}
    func collectionView(_ collectionView: UICollectionView, titleForHeaderInSection section: Int) -> String? { return nil }
    func collectionView(nibForHeaderInCollectionView collectionView: UICollectionView) -> UINib? { return nil }
    
    func minItemSize(forCellIn collectionView: UICollectionView, at indexPath: IndexPath) -> CGSize? { return nil }
    func collectionView(_ collectionView: UICollectionView, insetForSectionAt section: Int) -> UIEdgeInsets? { return nil }
    
    
    var collectionViewController: CollectionViewController!

    /// Bumped by `didRefresh`: a page load started for an older list (another
    /// filter or genre, or the same one picked again) is ignored when it lands.
    var loadGeneration = 0
    
    var collectionView: UICollectionView? {
        get {
            return collectionViewController?.collectionView
        } set(newObject) {
            collectionViewController?.collectionView = newObject
        }
    }
    
    var environmentsToFocus: [UIFocusEnvironment] = []

    /// Whether the focused view is in this screen (a poster, a Continue
    /// Watching card, Sort or Genre), not in the tab bar or elsewhere.
    private var focusIsInScreen: Bool {
        guard isViewLoaded, let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: view)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return environmentsToFocus.isEmpty ? super.preferredFocusEnvironments : environmentsToFocus
    }

    #if os(tvOS)
    /// Tracks whether we've already injected the in-body header. viewDidLoad
    /// can fire repeatedly when the VC is removed/re-added (e.g. tab switch
    /// + memory pressure), so we de-dup.
    private var didInstallInBodyHeader: Bool = false

    /// The in-body header (title + Sort / Genre): a subview of the grid,
    /// placed in its top content inset by `layoutInBodyHeader`.
    private(set) var bodyHeader: GridHeaderView?

    /// The header's controls, for the subclasses that have them: they write
    /// what the control is set to on it (`updateHeaderControls`).
    private(set) var sortButton: UIButton?
    private(set) var genreButton: UIButton?
    private(set) var serviceButton: UIButton?

    /// The page title (the tab's name; a person's).
    var bodyTitleLabel: UILabel? { return bodyHeader?.titleLabel }

    /// On tvOS 26 the centered tab-bar pills live in the same vertical strip
    /// as `navigationItem.leftBarButtonItem` and `rightBarButtonItems`,
    /// hiding the page title + Sort/Genre under them. So the header is part
    /// of the page, as on every tvOS screen: read the page title from
    /// `navigationItem.title` (set via storyboard or by the subclass), clear
    /// it so the system doesn't render its own copy alongside the pills, and
    /// put a header above the grid's first row.
    ///
    /// It is one line (`GridHeaderView`): the title on the rows' left edge,
    /// Sort / Genre on the right, each saying what it is set to. (It was a
    /// 75 pt title that repeated the tab's name over two bare "Sort" /
    /// "Genre" buttons, in 150 pt: with it and six columns of posters the
    /// screen showed one row and a half.) It lives in the grid (its top
    /// content inset) and scrolls away with the first row, and the tab bar
    /// follows the grid's scroll (`setContentScrollView`). Pinned on the
    /// view, it stayed while the posters slid under the title, Sort / Genre
    /// and the tab bar.
    ///
    /// `responds(to:)` filters: Movies & Shows expose `showFilters:` and
    /// `showGenres:`; Watchlist / Person have neither so they get the
    /// title only, no buttons. Search has neither title nor buttons: no
    /// header, and its tab bar is left to the search container.
    func installInBodyHeader() {
        guard !didInstallInBodyHeader else { return }
        didInstallInBodyHeader = true

        // 1) Extract title text. Storyboard sets `navigationItem.title`
        //    statically for Movies/Shows/Watchlist/Settings; subclasses
        //    (PersonViewController) set it before calling super. As a
        //    legacy fallback, read the customView label still in the bar
        //    item (Person hasn't been migrated).
        var titleText: String? = navigationItem.title
        if titleText == nil,
           let custom = navigationItem.leftBarButtonItem?.customView,
           let label = (custom as? UILabel) ?? custom.subviews.compactMap({ $0 as? UILabel }).first {
            titleText = label.text
        }

        // 2) Detach the legacy chrome so tvOS doesn't render its own copy
        //    of the title (browser-style nav bar would mirror
        //    `navigationItem.title` next to the tab pills).
        navigationItem.title = ""
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItems = nil

        let sortSel = NSSelectorFromString("showFilters:"), genreSel = NSSelectorFromString("showGenres:")
        guard let collectionView, titleText != nil || responds(to: sortSel) || responds(to: genreSel) else { return }

        // 3) The header, in the grid's top content inset: placed by frame
        //    (`layoutInBodyHeader`), its title and controls by constraints.
        //    The first row starts `GridStyle.sectionTop` below it.
        collectionView.contentInset.top = GridStyle.headerHeight - GridStyle.headerLift
        collectionView.verticalScrollIndicatorInsets.top = collectionView.contentInset.top

        let header = GridHeaderView()
        header.titleLabel.text = titleText
        header.titleLabel.isHidden = titleText == nil
        if responds(to: sortSel) { sortButton = header.addControl(identifier: "GridHeader.Sort", target: self, action: sortSel) }
        if responds(to: genreSel) { genreButton = header.addControl(identifier: "GridHeader.Genre", target: self, action: genreSel) }
        let serviceSel = NSSelectorFromString("showServices:")
        if responds(to: serviceSel) { serviceButton = header.addControl(identifier: "GridHeader.Service", target: self, action: serviceSel) }
        collectionView.addSubview(header)
        bodyHeader = header
        updateHeaderControls()

        layoutInBodyHeader()

        // 4) The tab bar follows the grid: it goes away as the posters
        //    scroll up and comes back at the top.
        setContentScrollView(collectionView, for: .top)

        installMenuToTheTop()
    }

    /// Writes on Sort / Genre what they are set to ("Sort: Trending").
    /// Movies and Shows override it; called when the header is made and
    /// after each choice.
    func updateHeaderControls() {}

    /// The header in the content inset reserved for it above the grid's
    /// content, between the rows' side insets: the page title starts on the
    /// posters' left edge. Being in the content, it scrolls with the posters.
    private func layoutInBodyHeader() {
        guard let header = bodyHeader, let collectionView = header.superview as? UICollectionView else { return }
        let frame = CGRect(x: GridStyle.sideInset,
                           y: -collectionView.contentInset.top - GridStyle.headerLift,
                           width: max(0, collectionView.bounds.width - GridStyle.sideInset * 2),
                           height: GridStyle.headerHeight)
        if header.frame != frame { header.frame = frame }
    }

    override dynamic func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutInBodyHeader()
    }

    override dynamic func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let header = bodyHeader, let collectionView else { return }
        // Up from the grid → Sort / Genre; from anywhere else (the tab bar,
        // the header itself) the focus engine decides alone.
        guard let next = context.nextFocusedView,
              next.isDescendant(of: collectionView), !next.isDescendant(of: header) else {
            header.focusGuide.isEnabled = false
            return
        }
        header.focusGuide.isEnabled = !header.buttons.isEmpty
        revealHeaderIfAtTheTop(next, in: collectionView)
    }

    /// A poster of the first row (or a Continue Watching card) focused: the
    /// grid goes back to its very top, the header and the tab bar in full.
    /// tvOS scrolls only until the poster is clear of the edge, which left
    /// the page short of its top (title and tab bar cut at the top of the
    /// screen) once the tab bar had gone away with the scroll.
    private func revealHeaderIfAtTheTop(_ focused: UIView, in collectionView: UICollectionView) {
        let top = -collectionView.adjustedContentInset.top
        guard collectionView.contentOffset.y > top + 1 else { return }
        // Where the grid shows its content when at its top.
        let shownAtTheTop = CGRect(x: collectionView.bounds.minX, y: top,
                                   width: collectionView.bounds.width, height: collectionView.bounds.height)
        let frame = focused.convert(focused.bounds, to: collectionView)
        guard shownAtTheTop.contains(frame) else { return }
        // The first row only. The second one fits the screen at the top
        // too, now that the header is one line: tvOS scrolls a little when
        // it gets the focus (the third row comes up), and the grid stays
        // there — also when it comes back from a page.
        if let controller = collectionViewController, let section = controller.dataSources.firstIndex(where: { !$0.isEmpty }),
           let firstRow = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: section))?.frame {
            guard frame.midY < firstRow.maxY else { return }
        }
        DispatchQueue.main.async {
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: top), animated: true)
        }
    }

    /// Update the in-body title label (a person's name).
    func setBodyTitle(_ text: String) {
        bodyTitleLabel?.text = text
    }

    // MARK: Menu: to the top of the grid, then to the tab bar

    private let menuGate = MenuGate()

    /// Menu on a grid goes up one level at a time, as the user reads the
    /// page: from the rows below, back to the top of the grid (the first
    /// row, with the header and the tab bar); from the top, to the tab bar;
    /// from the tab bar Menu goes to Home (`TVTabBarController`), and from
    /// Home leaves the app. (tvOS 26 leaves the app
    /// at once from anywhere on a tab's first screen: a long way from the
    /// fifth page of a list.)
    private func installMenuToTheTop() {
        let menu = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
        menu.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuGate.shouldBegin = { [weak self] in self?.takesMenu ?? false }
        menu.delegate = menuGate
        view.addGestureRecognizer(menu)
    }

    /// Only for a tab's first screen at rest with the focus in it: a page
    /// being pushed or popped keeps its own Back (`TVNavigationController`),
    /// a screen pushed on a tab (a person's titles) goes back with one press,
    /// and from the tab bar Menu goes to Home (`TVTabBarController`), and
    /// from Home leaves the app.
    private var takesMenu: Bool {
        guard let navigationController, navigationController.topViewController === self,
              navigationController.viewControllers.first === self,
              navigationController.transitionCoordinator == nil, presentedViewController == nil,
              let tabBarController = tabBarController as? TVTabBarController, !tabBarController.focusIsInTabBar,
              let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: view)
    }

    @objc private func menuPressed() {
        guard let collectionView, let controller = collectionViewController else { return }
        let top = -collectionView.adjustedContentInset.top
        if collectionView.contentOffset.y > top + 1 {
            // Back to the first row, in the column the focus was in.
            let section = controller.dataSources.firstIndex { !$0.isEmpty } ?? 0
            let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: section))
            let focusedX = (UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView).map { $0.convert($0.bounds, to: collectionView).midX }
            var item = 0
            if let first = attributes?.frame, let x = focusedX, first.width > 0 {
                let column = Int(max(0, x - first.minX) / (first.width + GridStyle.columnSpacing))
                item = min(column, max(0, (controller.dataSources[safe: section]?.count ?? 1) - 1))
            }
            controller.focusIndexPath = IndexPath(item: item, section: section)
            UIView.transition(with: collectionView, duration: GridStyle.fadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: top), animated: false)
                collectionView.layoutIfNeeded()
            }
            controller.setNeedsFocusUpdate()
            controller.updateFocusIfNeeded()
            controller.updateCaption(animated: false)
        } else if let tabBarController = tabBarController as? TVTabBarController {
            // At the top: the tab bar, on the tab this screen belongs to.
            tabBarController.environmentsToFocus = [tabBarController.tabBar]
            tabBarController.setNeedsFocusUpdate()
            tabBarController.updateFocusIfNeeded()
            tabBarController.environmentsToFocus.removeAll()
        }
    }
    #endif
    
    override dynamic func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        navigationController?.navigationBar.tintColor = .app
    }
    
    /// What the grid showed when another screen covered it (a page pushed,
    /// another tab): its items and the Continue Watching titles.
    private var shownWhenLeft: (items: [[AnyHashable]], continueWatching: [String])?

    /// The Continue Watching row's cards, in order (Movies and Shows grids
    /// only): the movie or the episode each one plays.
    private var continueWatchingIDs: [String] {
        if self is MoviesViewController { return ContinueWatchingCollectionReusableView.items(for: .movies).map { $0.mediaID } }
        if self is ShowsViewController { return ContinueWatchingCollectionReusableView.items(for: .episodes).map { $0.mediaID } }
        return []
    }

    override dynamic func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        shownWhenLeft = (collectionViewController?.dataSources ?? [], continueWatchingIDs)
    }

    override dynamic func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // A focus already in the screen stays where it is. A focus update
        // asked here only moves a focus the screen holds (one in the tab bar
        // is left alone), and it moved it to the grid's preferred poster: a
        // Down pressed before the tab had finished appearing reached a
        // Continue Watching card, then the focus jumped to the first poster
        // under the row (ContinueWatchingUITests, about 1 s after launch).
        if !environmentsToFocus.isEmpty || !focusIsInScreen {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()

            collectionView?.setNeedsFocusUpdate()
            collectionView?.updateFocusIfNeeded()
        }
        environmentsToFocus.removeAll()

        refreshShownContent()
    }

    /// Back on the grid (a page popped, a tab selected again): it comes back
    /// exactly as it was left, focus included. Only when its items or the
    /// Continue Watching titles changed meanwhile (the Watchlist reloaded, a
    /// title started or finished) is it reloaded; otherwise the posters'
    /// watched marks and the Continue Watching progress are updated in place.
    /// (Reloading on every return redrew every poster, from the placeholder
    /// for those not in memory, and moved the focus.)
    private func refreshShownContent() {
        guard let collectionView, let collectionViewController else { return }
        let continueWatching = continueWatchingIDs
        guard let left = shownWhenLeft,
              left.items == collectionViewController.dataSources,
              left.continueWatching == continueWatching else {
            #if os(tvOS)
            // Not a bare `reloadData`: it took the focus from a Continue
            // Watching card (a Down pressed while the tab was appearing).
            collectionViewController.reloadDataKeepingFocus()
            #else
            collectionView.reloadData()
            #endif
            return
        }
        collectionViewController.refreshVisibleItemsInPlace()
    }

    override dynamic func viewDidLoad() {
        super.viewDidLoad()

        collectionViewController.paginated = true
        // The grid's name for VoiceOver tools and the tvOS UI tests.
        collectionView?.accessibilityIdentifier = "MediaGrid.\(type(of: self))"
        load(page: 1)

        #if os(tvOS)
        installInBodyHeader()
        #if DEBUG
        GridHitchMonitor.startIfAsked()
        #endif
        #endif
    }
    
    func didRefresh(collectionView: UICollectionView) {
        loadGeneration += 1
        collectionViewController.dataSources = [[]]
        // A new list (another filter or genre): not the last one's error, and
        // a load still running for the last one must not block it (Movies and
        // Shows drop the results of a filter or genre no longer selected).
        collectionViewController.error = nil
        collectionViewController.loadMoreError = nil
        collectionViewController.isLoading = false
        #if os(tvOS)
        // Another list starts at its first poster: Down from the header
        // went to the place the focus had in the list before.
        collectionViewController.focusIndexPath = IndexPath(item: 0, section: 0)
        #endif
        collectionView.reloadData()
        load(page: 1)
    }

    /// Retry: the whole list again (an empty grid's error), or the page
    /// that failed under the titles already there.
    func retryLoading(page: Int?) {
        guard let collectionView else { return }
        guard let page = page else { return didRefresh(collectionView: collectionView) }
        load(page: page)
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "embed", let vc = segue.destination as? CollectionViewController {
            collectionViewController = vc
            collectionViewController.delegate = self
        } else if let segue = segue as? AutoPlayStoryboardSegue,
            segue.identifier == "showMovie" || segue.identifier == "showShow",
            let media: Media = sender as? Movie ?? sender as? Show {
            // The title's page at once, in place of the storyboard's loading
            // screen (`AutoPlayStoryboardSegue.perform`).
            segue.page = MainViewController.detailPage(of: media, autoPlay: segue.shouldAutoPlay)
        } else if segue.identifier == "showPerson",
            let vc = segue.destination as? PersonViewController,
            let person: Person = sender as? Crew ?? sender as? Actor {
            vc.currentItem = person
        }
    }
}

// MARK: - Detail pages

extension MainViewController {

    /// Opens the page of a movie or show: pushed at once, with what the
    /// caller has of the title (a grid's item, a Home card, a link's id) —
    /// the title's record, then its sources, fill it as they arrive
    /// (`GlassDetailHostingController`). There is no loading screen any
    /// more: the page used to come only once the slowest torrent source had
    /// answered.
    ///
    /// The page of that title already on top is not pushed a second time
    /// (a link to the page being shown): it takes the link's season and
    /// episode, and plays for `autoPlay`.
    ///
    /// `autoPlay` (a Continue Watching item, a `play` link, Play/Pause on a
    /// poster) plays what the page's Play button would, once the page is
    /// on screen and its sources are in. `season` / `episode`: a link's
    /// (`GlassDetailHostingController.init`).
    static func showDetail(of media: Media, on navigationController: UINavigationController, autoPlay: Bool = false,
                           season: Int? = nil, episode: Int? = nil) {
        if let top = navigationController.topViewController as? GlassDetailHostingController, top.shows(media) {
            print("[Detail] \(media.id) is the page on top: not opened a second time")
            top.reopen(autoPlay: autoPlay, season: season, episode: episode)
            return
        }
        navigationController.push(detailPage(of: media, autoPlay: autoPlay, season: season, episode: episode), animated: true)
    }

    /// The page `showDetail` pushes (a `showMovie` / `showShow` segue shows
    /// it in place of its storyboard destination).
    static func detailPage(of media: Media, autoPlay: Bool, season: Int? = nil, episode: Int? = nil) -> UIViewController {
        return GlassDetailHostingController(media: media, autoPlay: autoPlay, season: season, episode: episode)
    }
}

#if os(tvOS)
/// Lets a grid's Menu recognizer begin only when the grid takes Menu
/// (`MainViewController.installMenuToTheTop`); otherwise the press goes on
/// to the navigation controller or to the system.
final class MenuGate: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: () -> Bool = { false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return shouldBegin()
    }
}
#endif
