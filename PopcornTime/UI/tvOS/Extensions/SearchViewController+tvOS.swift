

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
    }
}
