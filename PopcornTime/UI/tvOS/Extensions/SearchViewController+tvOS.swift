

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
        // No scope bar: a search looks for movies, shows and people at once.
        searchBar.showsScopeBar = false
        searchBar.placeholder = "Movies, shows, people".localized
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

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        revealSearchBarIfFirstRow(context.nextFocusedView)
    }

    /// The results scrolled down take the keyboard and the search bar with
    /// them, off the screen: from the first row, Up found nothing above and
    /// the focus stayed there (Menu then left the app). Back on the first
    /// row, the results scroll back to their top, the search bar with them,
    /// so the next Up reaches the keyboard, then the tab bar.
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
}
