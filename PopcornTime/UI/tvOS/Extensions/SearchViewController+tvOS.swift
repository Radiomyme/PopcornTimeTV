

import Foundation

extension SearchViewController {
    
    override func viewDidLoad() {
        // Make sure we set this before calling super as it is not being loaded from storyboard.
        collectionViewController = storyboard?.instantiateViewController(withIdentifier: "CollectionViewController") as! CollectionViewController
        
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
    /// to descend. Plant an invisible UIFocusGuide that spans the entire
    /// width of the screen just under the keyboard and explicitly redirects
    /// focus to the first available result cell. The guide doesn't affect
    /// hit-testing or layout — it only steers the focus engine.
    private func installResultsFocusGuide() {
        guard view.layoutGuides.first(where: { $0 is UIFocusGuide }) == nil else { return }
        let guide = UIFocusGuide()
        view.addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guide.heightAnchor.constraint(equalToConstant: 60),
            guide.bottomAnchor.constraint(equalTo: view.centerYAnchor, constant: 60),
        ])

        // Re-point the guide on every layout pass so it always references
        // the currently visible first cell (cells are recreated when the
        // user types and results change).
        focusGuide = guide
    }

    private static var focusGuideKey = "SearchViewController.focusGuideKey"
    private var focusGuide: UIFocusGuide? {
        get { objc_getAssociatedObject(self, &SearchViewController.focusGuideKey) as? UIFocusGuide }
        set { objc_setAssociatedObject(self, &SearchViewController.focusGuideKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let guide = focusGuide,
              let first = collectionViewController?.collectionView?.visibleCells.first else { return }
        guide.preferredFocusEnvironments = [first]
    }
}
