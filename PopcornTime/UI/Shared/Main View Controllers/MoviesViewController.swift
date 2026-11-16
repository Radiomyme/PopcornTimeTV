

import UIKit
import func PopcornKit.loadMovies
import class PopcornKit.MovieManager
import struct PopcornKit.Movie

class MoviesViewController: MediaViewController {
    
    override func collectionView(nibForHeaderInCollectionView collectionView: UICollectionView) -> UINib? {
        return UINib(nibName: String(describing: ContinueWatchingCollectionReusableView.self), bundle: nil)
    }
    
    var currentFilter: MovieManager.Filters = .trending {
        didSet {
            // Set before the grid exists (a tab never shown yet): its first
            // load reads the filter.
            guard let collectionView else { return }
            collectionViewController.currentPage = 1
            #if os(tvOS)
            updateHeaderControls()
            #endif
            didRefresh(collectionView: collectionView)
        }
    }

    #if os(tvOS)
    override var currentFilterName: String { return currentFilter.string }

    override var sortChoices: [UIAction] {
        return MovieManager.Filters.array.map { filter in
            UIAction(title: filter.string, state: filter == currentFilter ? .on : .off) { [weak self] _ in
                self?.currentFilter = filter
            }
        }
    }
    #endif
    
    @IBAction func showFilters(_ sender: Any) {
        let controller = UIAlertController(title: "Select a filter to sort by".localized, message: nil, preferredStyle: .actionSheet, blurStyle: .dark)
        
        let handler: ((UIAlertAction) -> Void) = { (handler) in
            self.currentFilter = MovieManager.Filters.array.first(where: {$0.string == handler.title!})!
        }
        
        MovieManager.Filters.array.forEach {
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
        print("[Movies] load(page: \(page)) filter=\(currentFilter) genre=\(currentGenre)")
        guard !collectionViewController.isLoading else {
            print("[Movies] skip: already loading")
            return
        }
        collectionViewController.isLoading = true
        collectionViewController.hasNextPage = false
        let filter = currentFilter, genre = currentGenre, generation = loadGeneration
        let completion: ([Movie]?, NSError?) -> Void = { [weak self] (movies, error) in
            print("[Movies] callback movies=\(movies?.count ?? -1) error=\(error?.localizedDescription ?? "nil")")
            // Another list was asked for meanwhile (a filter or genre, even the
            // same one again): its own load (`didRefresh`) fills the grid.
            guard let self = self, generation == self.loadGeneration else { return }
            self.collectionViewController.isLoading = false

            // A grid with titles keeps them (its footer offers Retry for
            // the page); an empty one shows the error and Retry.
            guard let movies = movies else { return self.collectionViewController.loadFailed(error) }

            self.show(page: page, items: movies as [AnyHashable])
        }
        #if DEBUG
        // `-PTDebugFailPages`: this page fails once, as offline.
        if GridDebugHooks.fails(page: page) {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { completion(nil, GridDebugHooks.failure) }
        }
        #endif
        guard page <= 1 else {
            return PopcornKit.loadMovies(page, filterBy: filter, genre: genre, completion: completion)
        }
        #if DEBUG
        // `-PTDebugStaleSnapshot`, `-PTDebugFirstPageDelay` (GridDebugHooks).
        GridDebugHooks.prepareFirstPage()
        let firstPage: ([Movie]?, NSError?) -> Void = { items, error in
            GridDebugHooks.afterFirstPageDelay { completion(items, error) }
        }
        #else
        let firstPage = completion
        #endif
        // The first page: the list saved by the last load at once (a launch,
        // a sort picked again), then the network's.
        PopcornKit.loadMovies(page, filterBy: filter, genre: genre, snapshot: { [weak self] movies in
            guard let self = self, generation == self.loadGeneration else { return }
            print("[Movies] snapshot movies=\(movies.count)")
            #if DEBUG
            // `-PTDebugStaleSnapshot`: a saved list the network's differs from.
            return self.showSnapshot(GridDebugHooks.snapshot(movies) as [AnyHashable])
            #else
            self.showSnapshot(movies as [AnyHashable])
            #endif
        }, completion: firstPage)
    }
}
