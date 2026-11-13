

import Foundation

extension SearchViewController {
    
    override func viewDidLoad() {
        // Make sure we set this before calling super as it is not being loaded from storyboard.
        // Force-cast → if-let-cast since `instantiateViewController` is non-Optional in modern SDKs
        // and the forced cast triggers a "downcast will never produce nil" warning.
        if let cvc = storyboard?.instantiateViewController(withIdentifier: "CollectionViewController") as? CollectionViewController {
            collectionViewController = cvc
        }

        super.viewDidLoad()
        
        collectionViewController.delegate = self
        collectionViewController.paginated = false

        searchController = UISearchController(searchResultsController: collectionViewController)
        searchController.hidesNavigationBarDuringPresentation = false
        if #available(tvOS 9.1, *) {
            searchController.obscuresBackgroundDuringPresentation = false
        }
        
        searchBar = searchController.searchBar
        searchBar.scopeButtonTitles = ["Movies".localized, "Shows".localized, "People".localized]
        searchBar.showsScopeBar = true
        searchBar.delegate = self
        searchBar.keyboardAppearance = .dark
        searchBar.searchBarStyle = .minimal
        searchBar.sizeToFit()

        // The keyboard and the results are in place from the first frame the
        // tab shows (they were added once the tab had appeared: the first
        // visit to Search showed an empty screen, then the keyboard popped in).
        installSearchContainerIfNeeded()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        installSearchContainerIfNeeded()
        installResultsFocusGuide()
    }

    private func installSearchContainerIfNeeded() {
        searchContainerViewController = searchContainerViewController ?? {
            let container = UISearchContainerViewController(searchController: searchController)

            addChild(container)
            view.addSubview(container.view)
            // Without these constraints the container view ends up with an
            // ambiguous frame on tvOS — the search keyboard renders fine but
            // the focus engine can't move down into the results collection
            // view (it sees a 0-height results region). Pinning the
            // container to fill the parent makes the keyboard → scope tabs
            // → results focus chain work end to end.
            container.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                container.view.topAnchor.constraint(equalTo: view.topAnchor),
                container.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                container.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                container.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            container.didMove(toParent: self)

            return container
        }()
    }

    /// tvOS focus engine picks the focusable view geometrically closest to
    /// the current focused element when the user navigates down. With only
    /// 2 results in a left-aligned grid, neither cell sits below the
    /// centered MOVIES/SHOWS/PEOPLE scope buttons, so the engine refuses
    /// to descend. A full-width UIFocusGuide inside the results' collection
    /// view, just above their first row (below the scope bar), points at the
    /// first visible cell. The guide doesn't render, doesn't affect
    /// hit-testing — it only steers the focus engine, and only while the
    /// focus is on the scope bar (`updateResultsFocusGuide`).
    private func installResultsFocusGuide() {
        guard let cv = collectionViewController?.collectionView else { return }
        guard cv.layoutGuides.first(where: { $0 is UIFocusGuide }) == nil else { return }
        let guide = UIFocusGuide()
        guide.isEnabled = false
        cv.addLayoutGuide(guide)
        let top = guide.topAnchor.constraint(equalTo: cv.frameLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: cv.frameLayoutGuide.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: cv.frameLayoutGuide.trailingAnchor),
            top,
            guide.heightAnchor.constraint(equalToConstant: SearchViewController.focusGuideHeight),
        ])
        focusGuide = guide
        focusGuideTop = top
    }

    private static let focusGuideHeight: CGFloat = 40

    private static let focusGuideKey: UnsafeRawPointer =
        UnsafeRawPointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
    private static let focusGuideTopKey: UnsafeRawPointer =
        UnsafeRawPointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
    private var focusGuide: UIFocusGuide? {
        get { objc_getAssociatedObject(self, SearchViewController.focusGuideKey) as? UIFocusGuide }
        set { objc_setAssociatedObject(self, SearchViewController.focusGuideKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    private var focusGuideTop: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, SearchViewController.focusGuideTopKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, SearchViewController.focusGuideTopKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if focusGuide == nil { installResultsFocusGuide() }
        updateResultsFocusGuide(scopeBarFocused: isScopeBar(UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView))
    }

    /// The guide steers only a downward move from the scope bar into the
    /// results. Anywhere else it is off: pinned at the top of the results'
    /// frame (the whole screen, behind the keyboard) it used to catch every
    /// upward move — from the keyboard (Up never reached the tab bar: the
    /// focus went keyboard → first result → scope bar → keyboard…) and from
    /// the results' top row once they had scrolled (focus stuck on it,
    /// Menu left the app). Off, the search container's own focus moves
    /// apply: Up from the results reaches the scope bar and the keyboard,
    /// Up from the keyboard the tab bar.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateResultsFocusGuide(scopeBarFocused: isScopeBar(context.nextFocusedView))
        revealSearchBarIfFirstRow(context.nextFocusedView)
    }

    /// The results scrolled down take the keyboard and the scope bar with
    /// them, off the screen: from the first row, Up found nothing above and
    /// the focus stayed there (Menu then left the app). Back on the first
    /// row, the results scroll back to their top, the search bar with them,
    /// so the next Up reaches the scope bar, then the keyboard and the tab bar.
    private func revealSearchBarIfFirstRow(_ view: UIView?) {
        guard let cv = collectionViewController?.collectionView, let cell = view as? UICollectionViewCell,
              cell.isDescendant(of: cv), cv.numberOfSections > 0, cv.numberOfItems(inSection: 0) > 0,
              let firstRow = cv.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
              abs(cell.frame.minY - firstRow.minY) < 1 else { return }
        let top = -cv.adjustedContentInset.top
        guard cv.contentOffset.y > top + 1 else { return }
        DispatchQueue.main.async {
            cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: top), animated: true)
        }
    }

    /// A Movies / Shows / People button of the search bar's scope bar.
    private func isScopeBar(_ view: UIView?) -> Bool {
        guard let searchBar = searchBar else { return false }
        var current = view
        while let candidate = current, candidate !== searchBar {
            if candidate is UISegmentedControl { return candidate.isDescendant(of: searchBar) }
            current = candidate.superview
        }
        return false
    }

    private func updateResultsFocusGuide(scopeBarFocused: Bool) {
        guard let guide = focusGuide else { return }
        guard scopeBarFocused, let cv = collectionViewController?.collectionView,
              let first = cv.visibleCells.min(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) else {
            guide.isEnabled = false
            guide.preferredFocusEnvironments = []
            return
        }
        // Just above the first row, in the collection view's frame (the
        // guide is pinned to its frameLayoutGuide): below the scope bar.
        let firstRowTop = first.frame.minY - cv.contentOffset.y
        focusGuideTop?.constant = max(0, firstRowTop - SearchViewController.focusGuideHeight - 4)
        guide.preferredFocusEnvironments = [first]
        guide.isEnabled = true
    }
}
