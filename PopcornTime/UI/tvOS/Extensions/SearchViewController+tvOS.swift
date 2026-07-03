

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
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

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

        installResultsFocusGuide()
    }

    /// tvOS focus engine picks the focusable view geometrically closest to
    /// the current focused element when the user navigates down. With only
    /// 2 results in a left-aligned grid, neither cell sits below the
    /// centered MOVIES/SHOWS/PEOPLE scope buttons, so the engine refuses
    /// to descend. Plant a horizontal UIFocusGuide INSIDE the search
    /// results' collection view (the focus environment that
    /// UISearchController actually queries on a downward move) and point
    /// it at the first visible cell. The guide doesn't render, doesn't
    /// affect hit-testing — it only steers the focus engine.
    private func installResultsFocusGuide() {
        guard let cv = collectionViewController?.collectionView else { return }
        guard cv.layoutGuides.first(where: { $0 is UIFocusGuide }) == nil else { return }
        let guide = UIFocusGuide()
        cv.addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: cv.frameLayoutGuide.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: cv.frameLayoutGuide.trailingAnchor),
            guide.topAnchor.constraint(equalTo: cv.frameLayoutGuide.topAnchor),
            guide.heightAnchor.constraint(equalToConstant: 80),
        ])
        focusGuide = guide
    }

    private static let focusGuideKey: UnsafeRawPointer =
        UnsafeRawPointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
    private var focusGuide: UIFocusGuide? {
        get { objc_getAssociatedObject(self, SearchViewController.focusGuideKey) as? UIFocusGuide }
        set { objc_setAssociatedObject(self, SearchViewController.focusGuideKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if focusGuide == nil { installResultsFocusGuide() }
        guard let guide = focusGuide,
              let first = collectionViewController?.collectionView?.visibleCells.first else { return }
        guide.preferredFocusEnvironments = [first]
    }
}
