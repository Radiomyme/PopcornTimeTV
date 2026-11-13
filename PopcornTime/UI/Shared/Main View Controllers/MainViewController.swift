

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

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return environmentsToFocus.isEmpty ? super.preferredFocusEnvironments : environmentsToFocus
    }

    #if os(tvOS)
    /// Tracks whether we've already injected the in-body header. viewDidLoad
    /// can fire repeatedly when the VC is removed/re-added (e.g. tab switch
    /// + memory pressure), so we de-dup.
    private var didInstallInBodyHeader: Bool = false

    /// Reference to the in-body title label so subclasses can update it
    /// (e.g. `MediaViewController.showGenres` rewrites the title to the
    /// current genre when the user filters).
    var bodyTitleLabel: UILabel?

    /// The in-body header (title + Sort / Genre): a subview of the grid,
    /// placed in its top content inset by `layoutInBodyHeader`.
    private var bodyHeader: UIView?

    /// Over the header, left of Sort / Genre: Up from any poster of the
    /// first row goes to Sort (the focus engine went straight to the tab bar
    /// from the columns far from the buttons). On only while the focus is in
    /// the grid (`didUpdateFocus`): Down from the tab bar still goes to the
    /// poster below.
    private var bodyHeaderFocusGuide: UIFocusGuide?

    /// The header's height, and its distance from the top of the grid's
    /// content inset (which starts just below the tab bar).
    private static let bodyHeaderHeight: CGFloat = 100
    private static let bodyHeaderTop: CGFloat = 16

    /// On tvOS 26 the centered tab-bar pills live in the same vertical strip
    /// as `navigationItem.leftBarButtonItem` and `rightBarButtonItems`,
    /// hiding the giant page title + Sort/Genre under them. The Downloads
    /// page never had this problem — its "Downloads" label is laid out as a
    /// regular subview at body y≈190, well below the pills. We mirror that
    /// approach for every `MainViewController` subclass: read the page
    /// title from `navigationItem.title` (set via storyboard or by the
    /// subclass), clear it so the system doesn't render its own copy
    /// alongside the pills, and inject a fresh body header above the grid's
    /// first row with the title + Sort/Genre buttons.
    ///
    /// The header is part of the page, as on every tvOS screen: it lives in
    /// the grid (its top content inset) and scrolls away with the first row,
    /// and the tab bar follows the grid's scroll (`setContentScrollView`).
    /// Pinned on the view, it stayed while the posters slid under the title,
    /// Sort / Genre and the tab bar.
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

        // 3) Push the collection view's content below the header.
        //    Header (100) + breathing room above (16) and below (~30) +
        //    extra padding so the focus zoom on the first row clears
        //    the header → 150pt.
        let topInset: CGFloat = 150
        collectionView?.contentInset.top = topInset
        collectionView?.verticalScrollIndicatorInsets.top = topInset

        var rightButtons: [UIButton] = []
        let sortSel = NSSelectorFromString("showFilters:")
        if responds(to: sortSel) { rightButtons.append(makeCapsuleButton(title: "Sort".localized, action: sortSel, identifier: "GridHeader.Sort")) }
        let genreSel = NSSelectorFromString("showGenres:")
        if responds(to: genreSel) { rightButtons.append(makeCapsuleButton(title: "Genre".localized, action: genreSel, identifier: "GridHeader.Genre")) }

        guard let collectionView, titleText != nil || !rightButtons.isEmpty else { return }

        // 4) Build the in-body header: placed by frame in the grid's content
        //    (`layoutInBodyHeader`), its title and buttons by constraints.
        let header = UIView()
        collectionView.addSubview(header)
        bodyHeader = header

        if let text = titleText {
            let titleLabel = UILabel()
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.text = text
            titleLabel.font = .systemFont(ofSize: 75, weight: .heavy)
            titleLabel.textColor = .white
            titleLabel.adjustsFontSizeToFitWidth = false
            titleLabel.accessibilityIdentifier = "GridHeader.Title"
            header.addSubview(titleLabel)
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ])
            self.bodyTitleLabel = titleLabel
        }

        if let firstButton = rightButtons.first {
            let stack = UIStackView(arrangedSubviews: rightButtons)
            stack.axis = .horizontal
            stack.spacing = 28
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(stack)

            let guide = UIFocusGuide()
            guide.isEnabled = false
            guide.preferredFocusEnvironments = [firstButton]
            header.addLayoutGuide(guide)
            bodyHeaderFocusGuide = guide

            NSLayoutConstraint.activate([
                stack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                guide.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                guide.trailingAnchor.constraint(equalTo: stack.leadingAnchor),
                guide.topAnchor.constraint(equalTo: header.topAnchor),
                guide.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            ])
        }

        layoutInBodyHeader()

        // 5) The tab bar follows the grid: it goes away as the posters
        //    scroll up and comes back at the top.
        setContentScrollView(collectionView, for: .top)
    }

    /// The header in the 150 pt content inset reserved for it above the
    /// grid's content, `bodyHeaderTop` below that inset's top edge, between
    /// the view's safe area margins + 90: at the top of the grid, exactly
    /// where it was when pinned on the view, under the tab bar. Being in the
    /// content, it scrolls with the posters.
    private func layoutInBodyHeader() {
        guard let header = bodyHeader, let collectionView = header.superview as? UICollectionView else { return }
        let leading = view.safeAreaInsets.left + 90
        let trailing = view.safeAreaInsets.right + 90
        let frame = CGRect(x: leading,
                           y: Self.bodyHeaderTop - collectionView.contentInset.top,
                           width: max(0, collectionView.bounds.width - leading - trailing),
                           height: Self.bodyHeaderHeight)
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
            bodyHeaderFocusGuide?.isEnabled = false
            return
        }
        bodyHeaderFocusGuide?.isEnabled = true
        revealHeaderIfAtTheTop(next, in: collectionView)
    }

    /// A poster of the first row (or a Continue Watching card) focused: the
    /// grid goes back to its very top, the header and the tab bar in full.
    /// tvOS scrolls only until the poster is clear of the edge, which left
    /// the page 30 pt short of its top (title and tab bar cut at the top of
    /// the screen) once the tab bar had gone away with the scroll.
    private func revealHeaderIfAtTheTop(_ focused: UIView, in collectionView: UICollectionView) {
        let top = -collectionView.adjustedContentInset.top
        guard collectionView.contentOffset.y > top + 1 else { return }
        // Where the grid shows its content when at its top.
        let shownAtTheTop = CGRect(x: collectionView.bounds.minX, y: top,
                                   width: collectionView.bounds.width, height: collectionView.bounds.height)
        guard shownAtTheTop.contains(focused.convert(focused.bounds, to: collectionView)) else { return }
        DispatchQueue.main.async {
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: top), animated: true)
        }
    }

    /// Update the in-body title label. Used by `MediaViewController`
    /// when the user picks a genre filter.
    func setBodyTitle(_ text: String) {
        bodyTitleLabel?.text = text
    }

    private func makeCapsuleButton(title: String, action: Selector, identifier: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 32, bottom: 14, trailing: 32)
        config.baseForegroundColor = .white
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 26, weight: .semibold)
            return out
        }
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: action, for: .primaryActionTriggered)
        btn.accessibilityIdentifier = identifier
        return btn
    }
    #endif
    
    override dynamic func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        navigationController?.navigationBar.tintColor = .app
    }
    
    /// What the grid showed when another screen covered it (a page pushed,
    /// another tab): its items and the Continue Watching titles.
    private var shownWhenLeft: (items: [[AnyHashable]], continueWatching: [String])?

    /// The Continue Watching row's titles (Movies and Shows grids only).
    private var continueWatchingIDs: [String] {
        if self is MoviesViewController { return WatchedlistManager<Movie>.movie.getOnDeck() }
        if self is ShowsViewController { return WatchedlistManager<Episode>.episode.getOnDeck() }
        return []
    }

    override dynamic func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        shownWhenLeft = (collectionViewController?.dataSources ?? [], continueWatchingIDs)
    }

    override dynamic func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        setNeedsFocusUpdate()
        updateFocusIfNeeded()

        environmentsToFocus.removeAll()

        collectionView?.setNeedsFocusUpdate()
        collectionView?.updateFocusIfNeeded()

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
            collectionView.reloadData()
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
        #endif
    }
    
    func didRefresh(collectionView: UICollectionView) {
        loadGeneration += 1
        collectionViewController.dataSources = [[]]
        // A new list (another filter or genre): not the last one's error, and
        // a load still running for the last one must not block it (Movies and
        // Shows drop the results of a filter or genre no longer selected).
        collectionViewController.error = nil
        collectionViewController.isLoading = false
        collectionView.reloadData()
        load(page: 1)
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "embed", let vc = segue.destination as? CollectionViewController {
            collectionViewController = vc
            collectionViewController.delegate = self
        } else if let segue = segue as? AutoPlayStoryboardSegue,
            segue.identifier == "showMovie" || segue.identifier == "showShow",
            let media: Media = sender as? Movie ?? sender as? Show {
            MainViewController.loadDetail(of: media, behind: segue.destination, autoPlay: segue.shouldAutoPlay)
        } else if segue.identifier == "showPerson",
            let vc = segue.destination as? PersonViewController,
            let person: Person = sender as? Crew ?? sender as? Actor {
            vc.currentItem = person
        }
    }
}

// MARK: - Detail pages

extension MainViewController {

    /// Opens the page of a movie or show from code (e.g. a related title on a
    /// detail page): pushes the loading screen, which is then replaced by the
    /// page, exactly like a poster's `showMovie` / `showShow` segue.
    static func showDetail(of media: Media, on navigationController: UINavigationController, autoPlay: Bool = false) {
        let loadingViewController = UIStoryboard.main.instantiateViewController(withIdentifier: "LoadingViewController")
        loadDetail(of: media, behind: loadingViewController, autoPlay: autoPlay)
        navigationController.push(loadingViewController, animated: true)
    }

    /// Fills `loadingViewController` (the TVLoadingViewController a
    /// `showMovie` / `showShow` segue pushes) with the poster and title,
    /// loads the movie or show info, then swaps the loading screen for the
    /// detail page (`GlassDetailHostingController`) with a fade, or for an
    /// error page. Nothing happens if the user left the loading screen
    /// meanwhile. `autoPlay` (a Continue Watching item) then plays what
    /// the page's Play button would.
    static func loadDetail(of media: Media, behind loadingViewController: UIViewController, autoPlay: Bool) {
#if os(tvOS)
        if let destination = loadingViewController as? TVLoadingViewController {
            destination.loadViewIfNeeded() // Initialize the @IBOutlets

            if let image = media.smallCoverImage, let url = URL(string: image) {
                destination.backgroundImageView.af.setImage(withURL: url)
            }

            destination.titleLabel.text = media.title
        }
#endif

        /// Replaces the loading screen with the page (or an error page), in
        /// one change of the navigation stack under a 0.5 s fade. (The page
        /// used to be pushed over the loading screen, which was taken out of
        /// the stack 0.5 s later: Back during that fade went to the loading
        /// screen, then that removal ran in the middle of the pop and could
        /// leave a spinner that never went away.)
        func replaceLoadingScreen(with media: Media?, error: NSError?) {
            guard let navigationController = loadingViewController.navigationController,
                navigationController.visibleViewController === loadingViewController, // Make sure we're still loading and the user hasn't dismissed the view.
                (navigationController as? TVNavigationController)?.isGoingBack != true // nor pressed Back while the loading screen slid in
                else { return }
            // A transition still running (UIKit would drop this change): after it.
            if let coordinator = navigationController.transitionCoordinator {
                let retry = { DispatchQueue.main.async { replaceLoadingScreen(with: media, error: error) } }
                if !coordinator.animate(alongsideTransition: nil, completion: { _ in retry() }) {
                    retry()
                }
                return
            }
            guard let index = navigationController.viewControllers.firstIndex(where: { $0 === loadingViewController }) else { return }

            let page: UIViewController
            var detailViewController: GlassDetailHostingController?
            if let error = error {
                page = TVErrorPageViewController(error: error)
            } else if let media = media {
                let vc = GlassDetailHostingController(media: media, autoPlay: autoPlay)
                detailViewController = vc
                page = vc
            } else {
                return
            }

            let transition = CATransition()
            transition.duration = 0.5
            transition.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
            transition.type = CATransitionType.fade
            navigationController.view.layer.add(transition, forKey: nil)

            var viewControllers = navigationController.viewControllers
            viewControllers[index] = page
            navigationController.setViewControllers(viewControllers, animated: false)

            if autoPlay, let detailViewController {
                DispatchQueue.main.asyncAfter(deadline: .now() + transition.duration) {
                    // Not over another screen if the user left the page meanwhile.
                    guard detailViewController.navigationController?.topViewController === detailViewController else { return }
                    detailViewController.startAutoPlay()
                }
            }
        }

        GlassDetailHostingController.loadCore(of: media) { (media, error) in
            // A cached show answers within a few milliseconds, while the
            // loading screen's own push (TVNavigationController's 0.6 s
            // animation) is still running. UIKit drops navigation changes made
            // during a transition (the page would never open), so the swap
            // waits for that push to end (`replaceLoadingScreen`).
            replaceLoadingScreen(with: media, error: error)
        }
    }
}
