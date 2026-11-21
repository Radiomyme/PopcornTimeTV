

import UIKit
import class PopcornKit.ShowManager
import func PopcornKit.loadShows
import struct PopcornKit.Show
import enum PopcornKit.StreamingSort

class ShowsViewController: MediaViewController {
    
    override func collectionView(nibForHeaderInCollectionView collectionView: UICollectionView) -> UINib? {
        return UINib(nibName: String(describing: ContinueWatchingCollectionReusableView.self), bundle: nil)
    }

    var currentFilter = ShowManager.Filters.trending {
        didSet {
            // Set before the grid exists (a tab never shown yet): its first
            // load reads the filter. Set for a service: its reload covers it.
            guard let collectionView, !holdsReload else { return }
            collectionViewController.currentPage = 1
            #if os(tvOS)
            updateHeaderControls()
            #endif
            didRefresh(collectionView: collectionView)
        }
    }

    override var streamingSort: StreamingSort {
        return currentFilter.streamingSort ?? .popular
    }

    /// The sorts offered: with a service, only the orders its lists follow.
    private var sorts: [ShowManager.Filters] {
        return currentService == nil ? ShowManager.Filters.array : ShowManager.Filters.streamingArray
    }

    override func fitSortToService() {
        if !sorts.contains(currentFilter) { currentFilter = .popularity }
    }

    #if os(tvOS)
    override var currentFilterName: String { return currentFilter.string }

    override var sortChoices: [UIAction] {
        return sorts.map { filter in
            UIAction(title: filter.string, state: filter == currentFilter ? .on : .off) { [weak self] _ in
                self?.currentFilter = filter
            }
        }
    }
    #endif
    
    @IBAction func showFilters(_ sender: Any) {
        let controller = UIAlertController(title: "Select a filter to sort by".localized, message: nil, preferredStyle: .actionSheet, blurStyle: .dark)
        
        let handler: ((UIAlertAction) -> Void) = { (handler) in
            self.currentFilter = ShowManager.Filters.array.first(where: {$0.string == handler.title!})!
        }
        
        ShowManager.Filters.array.forEach {
            controller.addAction(UIAlertAction(title: $0.string, style: .default, handler: handler))
        }
        
        controller.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
        controller.preferredAction = controller.actions.first(where: {$0.title == self.currentFilter.string})
        
        if let barButtonItem = sender as? UIBarButtonItem {
            controller.popoverPresentationController?.barButtonItem = barButtonItem
        }
        
        present(controller, animated: true)
    }
    
    override func load(page: Int) {
        guard !collectionViewController.isLoading else { return }
        collectionViewController.isLoading = true
        collectionViewController.hasNextPage = false
        let filter = currentFilter, genre = currentGenre, generation = loadGeneration
        let completion: ([Show]?, NSError?) -> Void = { [weak self] (shows, error) in
            print("[Shows] callback shows=\(shows?.count ?? -1) error=\(error?.localizedDescription ?? "nil")")
            // Another list was asked for meanwhile (a filter or genre, even the
            // same one again): its own load (`didRefresh`) fills the grid.
            guard let self = self, generation == self.loadGeneration else { return }
            self.collectionViewController.isLoading = false
            
            // A grid with titles keeps them (its footer offers Retry for
            // the page); an empty one shows the error and Retry.
            guard let shows = shows else { return self.collectionViewController.loadFailed(error) }

            // Each page of "A - Z" is a page of the popular catalog sorted by
            // title: the accumulated list is sorted again so the grid stays
            // alphabetical as the user scrolls.
            self.show(page: page, items: shows as [AnyHashable], merge: filter != .name ? nil : { items in
                items.sorted {
                    guard let lhs = ($0 as? Show)?.title, let rhs = ($1 as? Show)?.title else { return false }
                    return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
            })
        }
        print("[Shows] load(page: \(page)) filter=\(filter) genre=\(genre)")
        #if DEBUG
        // `-PTDebugFailPages`: this page fails once, as offline.
        if GridDebugHooks.fails(page: page) {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { completion(nil, GridDebugHooks.failure) }
        }
        #endif
        // A service's catalogue (TMDB): no saved first page.
        if let service = currentService {
            return loadService(service, page: page) { items, error in completion(items?.compactMap(\.show), error) }
        }
        guard page <= 1 else {
            return PopcornKit.loadShows(page, filterBy: filter, genre: genre, completion: completion)
        }
        #if DEBUG
        // `-PTDebugStaleSnapshot`, `-PTDebugFirstPageDelay` (GridDebugHooks).
        GridDebugHooks.prepareFirstPage()
        let firstPage: ([Show]?, NSError?) -> Void = { items, error in
            GridDebugHooks.afterFirstPageDelay { completion(items, error) }
        }
        #else
        let firstPage = completion
        #endif
        // The first page: the list saved by the last load at once (a launch,
        // a sort picked again), then the network's.
        PopcornKit.loadShows(page, filterBy: filter, genre: genre, snapshot: { [weak self] shows in
            guard let self = self, generation == self.loadGeneration else { return }
            print("[Shows] snapshot shows=\(shows.count)")
            #if DEBUG
            // `-PTDebugStaleSnapshot`: a saved list the network's differs from.
            return self.showSnapshot(GridDebugHooks.snapshot(shows) as [AnyHashable])
            #else
            self.showSnapshot(shows as [AnyHashable])
            #endif
        }, completion: firstPage)
    }
}
