

import Foundation
import UIKit
import PopcornKit

class MediaViewController: MainViewController {

    /// The streaming service whose catalogue the grid shows, in the user's
    /// country (TMDB); nil: the usual catalogue. Sort and Genre still apply,
    /// limited to what the service's lists can follow (`genres`, the
    /// subclasses' `sortChoices`): one that is not is put back first.
    var currentService: StreamingService? {
        didSet {
            guard oldValue != currentService else { return }
            servicePageShift = 0
            fitSortAndGenreToService()
            guard let collectionView else { return }
            collectionViewController.currentPage = 1
            #if os(tvOS)
            updateHeaderControls()
            #endif
            didRefresh(collectionView: collectionView)
        }
    }

    /// True while Sort or Genre is set for the service (`fitSortAndGenreToService`):
    /// their own reload waits, the service's covers it.
    var holdsReload = false

    /// A genre or a sort the service's lists cannot follow goes back to
    /// « All » or to Popular (Movies and Shows put their sort back).
    private func fitSortAndGenreToService() {
        holdsReload = true
        defer { holdsReload = false }
        if !genres.contains(currentGenre) { currentGenre = .all }
        fitSortToService()
    }

    /// The grid's sort, back to one the service's lists follow (Movies, Shows).
    func fitSortToService() {}

    /// The kind of titles of this grid.
    var streamingKind: HomeItem.Kind { return self is MoviesViewController ? .movie : .show }

    /// The service order of the grid's sort (Movies and Shows map theirs).
    var streamingSort: StreamingSort { return .popular }

    /// Pages of the service's list skipped so far because they came back
    /// empty with more after them (every title of the page was without an
    /// IMDb id): the grid's page n is TMDB's n + this.
    private var servicePageShift = 0
    /// The service's list said it has no page after the last one shown:
    /// the grid stops asking (`show(page:items:merge:)`).
    private(set) var serviceListIsOver = false
    /// Empty pages in a row the grid goes past before it stops asking.
    private static let toleratedEmptyServicePages = 3

    /// A page of `service`'s catalogue for this grid, as cards (main queue;
    /// nil: TMDB did not answer, or a title's IMDb id could not be asked).
    /// An empty page with more after it is not the end: the next one is
    /// asked, three at most in a row.
    func loadService(_ service: StreamingService, page: Int, completion: @escaping ([HomeItem]?, NSError?) -> Void) {
        askService(service, page: page, genre: currentGenre == .all ? nil : currentGenre.rawValue, sort: streamingSort,
                   emptyPagesSoFar: 0, generation: loadGeneration, completion: completion)
    }

    private func askService(_ service: StreamingService, page: Int, genre: String?, sort: StreamingSort, emptyPagesSoFar: Int,
                            generation: Int, completion: @escaping ([HomeItem]?, NSError?) -> Void) {
        TMDBStreamingClient.shared.titles(service: service.id, kind: streamingKind, region: HomeSettings().streamingRegion,
                                          page: page + servicePageShift, sort: sort, genre: genre) { [weak self] items, hasMore in
            DispatchQueue.main.async {
                // Another list was asked meanwhile (another service, genre or
                // sort): its own load fills the grid, and this answer must not
                // touch the page shift or the end of that list.
                guard let self, self.currentService == service, self.loadGeneration == generation else { return }
                guard let items else {
                    let error = NSError(domain: "TMDB", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: (TMDBStreamingClient.shared.isKeyRefused
                                                                               ? "Grid.Service.Refused" : "Grid.Service.Unavailable").localized])
                    return completion(nil, error)
                }
                if items.isEmpty, hasMore, emptyPagesSoFar + 1 < MediaViewController.toleratedEmptyServicePages {
                    self.servicePageShift += 1
                    return self.askService(service, page: page, genre: genre, sort: sort, emptyPagesSoFar: emptyPagesSoFar + 1,
                                           generation: generation, completion: completion)
                }
                self.serviceListIsOver = !hasMore || items.isEmpty
                completion(items, nil)
            }
        }
    }

    /// The services offered (Settings › Streaming Services; none without a key).
    var offeredServices: [StreamingService] { return HomeSettings().streamingShelves }

    /// The Service control (UIKit fallback; the header's menu replaces it).
    @objc func showServices(_ sender: Any) {
        let controller = UIAlertController(title: "Settings.StreamingServices".localized, message: nil, preferredStyle: .actionSheet)
        controller.addAction(UIAlertAction(title: "All".localized, style: .default) { [weak self] _ in self?.currentService = nil })
        for service in offeredServices {
            controller.addAction(UIAlertAction(title: service.name, style: .default) { [weak self] _ in self?.currentService = service })
        }
        controller.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
        present(controller, animated: true)
    }
    
    var currentGenre = NetworkManager.Genres.all {
        didSet {
            // Set before the grid exists (a tab never shown yet): its first
            // load reads the genre. Set for a service: its reload covers it.
            guard let collectionView, !holdsReload else { return }
            collectionViewController.currentPage = 1
            #if os(tvOS)
            updateHeaderControls()
            #endif
            didRefresh(collectionView: collectionView)
        }
    }

    #if os(tvOS)
    /// The name of the sort the grid is set to ("Trending"): Movies and
    /// Shows have their own lists of sorts.
    var currentFilterName: String { return "" }

    /// "Sort: Trending", "Genre: All": the header's controls say which list
    /// the page shows. (Nothing said the sort; the genre took the place of
    /// the page title.)
    override func updateHeaderControls() {
        // Without services (no TMDB key, or none chosen) no Service control:
        // the header is the usual one. One chosen that is no longer offered
        // (the key removed, the service unchecked in Settings) is dropped.
        let services = offeredServices
        if let service = currentService, !services.contains(where: { $0.id == service.id }) { currentService = nil }
        serviceButton?.isHidden = services.isEmpty
        GridHeaderView.set(sortButton, format: "Sort: %@".localized, value: currentFilterName)
        GridHeaderView.set(genreButton, format: "Genre: %@".localized, value: currentGenre.string)
        GridHeaderView.set(serviceButton, format: "Service: %@".localized, value: currentService?.name ?? "All".localized)
        var serviceChoices: [UIMenuElement] = [UIAction(title: "All".localized, state: currentService == nil ? .on : .off) { [weak self] _ in
            self?.currentService = nil
        }]
        serviceChoices += services.map { service in
            UIAction(title: service.name, state: service.id == currentService?.id ? .on : .off) { [weak self] _ in
                self?.currentService = service
            }
        }
        GridHeaderView.setMenu(serviceButton, UIMenu(options: .singleSelection, children: serviceChoices))
        // A menu anchored to its control (the system's glass, a white
        // focus, a tick on the current choice), not an alert over the page.
        GridHeaderView.setMenu(sortButton, UIMenu(options: .singleSelection, children: sortChoices))
        let genres = self.genres
        GridHeaderView.setMenu(genreButton, UIMenu(options: .singleSelection, children: genres.map { genre in
            UIAction(title: genre.string, state: genre == currentGenre ? .on : .off) { [weak self] _ in
                // The Genre control says the genre; the page keeps its title.
                self?.currentGenre = genre
            }
        }))
    }

    /// The sorts the Sort control offers (Movies and Shows have their own).
    var sortChoices: [UIAction] { return [] }

    /// Back on the grid (from Settings, where a key or the services may
    /// have changed): the Service control and its menu read them again.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if bodyHeader != nil { updateHeaderControls() }
    }
    #endif

    /// The genres this grid offers: those its catalog knows (YTS for the
    /// movies, Cinemeta for the shows); with a service, those TMDB can
    /// filter its titles on. A genre the catalog ignores used to show the
    /// whole catalog under the genre's name.
    var genres: [NetworkManager.Genres] {
        let all = self is MoviesViewController ? NetworkManager.Genres.movies : NetworkManager.Genres.shows
        guard currentService != nil else { return all }
        let kind = streamingKind
        return all.filter { TMDBStreamingClient.supportsGenre($0.rawValue, kind: kind) }
    }

    // MARK: First page: last session's list, then the network's

    /// True while page 1 on screen is the list saved by an earlier load
    /// (`CatalogSnapshotStore`), painted while the network's is on its way.
    private var showingSnapshot = false

    /// The network's first page, when it landed while the grid was scrolled
    /// away from its top: it takes the snapshot's place once the grid is
    /// back there (`showPendingFirstPageIfAtTheTop`).
    private var pendingFirstPage: (items: [AnyHashable], merge: (([AnyHashable]) -> [AnyHashable])?)?
    /// Watches the grid's scroll while a first page is pending.
    private var topObservation: NSKeyValueObservation?

    /// Pages in a row that added no new title (`show(page:items:merge:)`).
    private var barrenPages = 0
    private static let toleratedBarrenPages = 3

    override func didRefresh(collectionView: UICollectionView) {
        showingSnapshot = false
        barrenPages = 0
        servicePageShift = 0
        serviceListIsOver = false
        dropPendingFirstPage()
        super.didRefresh(collectionView: collectionView)
    }

    override func viewDidAppear(_ animated: Bool) {
        // Back on the grid, at its top: before `super` compares the grid
        // with what it showed when it was left.
        showPendingFirstPageIfAtTheTop()
        super.viewDidAppear(animated)
    }

    /// The saved first page of the list being loaded: painted at once. The
    /// load goes on (`isLoading` stays set: no pagination meanwhile).
    func showSnapshot(_ items: [AnyHashable]) {
        guard !items.isEmpty, collectionViewController.dataSources.allSatisfy({ $0.isEmpty }) else { return }
        showingSnapshot = true
        collectionViewController.dataSources = [items]
        collectionViewController.reloadDataKeepingFocus()
    }

    /// A page the network answered. Page 1 over a snapshot: when it is the
    /// same list its titles only take the saved ones' place (what they say
    /// may be newer); otherwise it replaces the snapshot, the focus staying
    /// where it is in the grid. When the grid was scrolled meanwhile (the
    /// posters must not change under the focus) it waits until the grid is
    /// back at its top. (It used to be dropped: a snapshot can be a week
    /// old, and it stayed the list until the sort was picked again or the
    /// app relaunched.) Any other page is added under the list, without
    /// touching the posters on screen; `merge` puts the whole list in order
    /// when the sort needs it (A - Z), the focused title staying in place.
    func show(page: Int, items: [AnyHashable], merge: (([AnyHashable]) -> [AnyHashable])? = nil) {
        guard let controller = collectionViewController else { return }
        if page <= 1, showingSnapshot {
            showingSnapshot = false
            let shown = controller.dataSources.first ?? []
            guard !items.isEmpty else { controller.hasNextPage = true; return }
            if shown == items {
                // Equal by id: the posters stay, their titles are the
                // network's from now on (a rating, a 4K release since).
                controller.dataSources = [items]
                controller.refreshVisibleItemsInPlace()
                controller.hasNextPage = true
                return
            }
            if !isAtTheTop {
                controller.hasNextPage = true
                pendingFirstPage = (items, merge)
                topObservation = collectionView?.observe(\.contentOffset) { [weak self] grid, _ in
                    guard grid.contentOffset.y <= -grid.adjustedContentInset.top + 1 else { return }
                    // Not in the middle of the scroll's own pass.
                    DispatchQueue.main.async { self?.showPendingFirstPageIfAtTheTop() }
                }
                return
            }
            controller.dataSources = [merge.map { $0(items) } ?? items]
            controller.hasNextPage = true
            return controller.reloadDataKeepingFocus()
        }

        let listed = Set(controller.dataSources.first ?? [])
        var seen = Set<AnyHashable>()
        let added = items.filter { !listed.contains($0) && seen.insert($0).inserted }
        // A page of titles the grid already has adds nothing: after a few
        // of them in a row the list is at its end, like an empty page (a
        // source that repeats its last page would be asked for ever, and
        // the grid would keep its last titles back for a row that never
        // fills: `CollectionViewController.shownCount`).
        barrenPages = added.isEmpty ? barrenPages + 1 : 0
        if items.isEmpty || barrenPages >= MediaViewController.toleratedBarrenPages || (currentService != nil && serviceListIsOver) {
            // No more results: the content inset of the collection view is reset.
            collectionView?.contentInset.bottom = tabBarController?.tabBar.frame.height ?? 0
        } else {
            controller.hasNextPage = true
        }
        guard let merge = merge else {
            if controller.dataSources.isEmpty { controller.dataSources = [[]] }
            if listed.isEmpty {
                // The first titles of the grid: over the placeholders.
                controller.dataSources[0] = added
                return controller.reloadDataKeepingFocus()
            }
            return controller.append(added)
        }
        // Sorted again as a whole: the title under the focus moves in the
        // list, and stays under the focus where it was on the screen.
        let focused = controller.focusedPosterIndexPath.flatMap { controller.dataSources[safe: $0.section]?[safe: $0.item] }
        controller.dataSources[0] = merge((controller.dataSources.first ?? []) + added)
        controller.reloadDataKeepingFocus(on: focused)
    }

    /// The grid has not been scrolled.
    private var isAtTheTop: Bool {
        guard let collectionView = collectionView else { return true }
        return collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 1
    }

    /// The grid is back at its top with a first page pending: the network's
    /// titles open the list, followed by what the grid had and they do not
    /// repeat (the pages loaded since, and the titles that left the first page).
    private func showPendingFirstPageIfAtTheTop() {
        guard let pending = pendingFirstPage, isAtTheTop, let controller = collectionViewController else { return }
        dropPendingFirstPage()
        var items = pending.items + (controller.dataSources.first ?? [])
        items.unique()
        controller.dataSources = [pending.merge.map { $0(items) } ?? items]
        controller.reloadDataKeepingFocus()
    }

    private func dropPendingFirstPage() {
        pendingFirstPage = nil
        topObservation = nil
    }
    
    @IBAction func showGenres(_ sender: Any) {
        let controller = UIAlertController(title: "Select a genre to filter by".localized, message: nil, preferredStyle: .actionSheet, blurStyle: .dark)
        let genres = self.genres
        
        let handler: ((UIAlertAction) -> Void) = { (handler) in
            guard let genre = genres.first(where: { $0.string == handler.title }) else { return }
            // The Genre control says the genre (`updateHeaderControls`); the
            // page keeps its title.
            self.currentGenre = genre
        }
        
        genres.forEach {
            controller.addAction(UIAlertAction(title: $0.string, style: .default, handler: handler))
        }
        
        controller.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
        controller.preferredAction = controller.actions.first(where: {$0.title == self.currentGenre.string})
        
        if let barButtonItem = sender as? UIBarButtonItem {
            controller.popoverPresentationController?.barButtonItem = barButtonItem
        }
        
        present(controller, animated: true)
    }

    /// A list that came back empty: the Top 100 filtered by a genre none of
    /// its titles has, say.
    override func collectionView(isEmptyForUnknownReason collectionView: UICollectionView) {
        collectionViewController.showMessage(title: "No results".localized,
                                             body: currentGenre == .all ? nil : "Try another genre or another sort.".localized)
    }
}
