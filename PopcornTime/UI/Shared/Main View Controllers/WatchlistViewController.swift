

import UIKit
import PopcornKit

class WatchlistViewController: MainViewController {

    override func viewDidLoad() {
        #if DEBUG && os(tvOS)
        // `-PTDebugWatchlist` (GridDebugHooks): before the first read.
        GridDebugHooks.fillWatchlistIfAsked()
        #endif
        super.viewDidLoad()
        
        collectionViewController.paginated = false
        // Every poster here is in the watchlist: no need to say so.
        collectionViewController.showsWatchlistMark = false
    }
    
    override func viewWillAppear(_ animated: Bool) {
        load(page: -1) // Refresh watchlsit
        super.viewWillAppear(animated)
    }
    
    /// Movies, then shows, each with the title added last first: what the
    /// user just put aside is what they come here for. (The list was sorted
    /// by title.)
    override func load(page: Int) {
        let movies = WatchlistManager<Movie>.movie.getWatchlist { [weak self] updated in
            self?.replace(updated, inSection: 0, kind: .movie)
        }
        let shows = WatchlistManager<Show>.show.getWatchlist { [weak self] updated in
            self?.replace(updated, inSection: 1, kind: .show)
        }
        collectionViewController.dataSources = [WatchlistViewController.latestFirst(movies, kind: .movie),
                                                WatchlistViewController.latestFirst(shows, kind: .show)]
    }

    /// Trakt's more recent list (an account still linked): in place of the
    /// stored one, and on the screen at once. The grid must show what its
    /// list holds: a poster removed later is taken out by its place in the
    /// list (a batch delete, which checks the counts).
    private func replace<Item: Media & Hashable>(_ items: [Item], inSection section: Int, kind: ContinueWatchingItem.Kind) {
        let list = WatchlistViewController.latestFirst(items, kind: kind)
        DispatchQueue.main.async { [weak self] in
            guard let controller = self?.collectionViewController,
                  controller.dataSources.indices.contains(section), controller.dataSources[section] != list else { return }
            controller.dataSources[section] = list
            controller.reloadDataKeepingFocus()
        }
    }

    /// `items` in the library's order: the latest added first. A title the
    /// library does not list (it always does) keeps its place at the end.
    private static func latestFirst<Item: Media & Hashable>(_ items: [Item], kind: ContinueWatchingItem.Kind) -> [AnyHashable] {
        var rank: [String: Int] = [:]
        for (index, item) in Library.shared.watchlist(kind).enumerated() { rank[item.imdbID] = index }
        return items.enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map { $0.element as AnyHashable }
    }
    
    override func collectionView(_ collectionView: UICollectionView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 {
            return "Movies".localized
        } else if section == 1 {
            return "Shows".localized
        }
        return nil
    }
    
    override func collectionView(isEmptyForUnknownReason collectionView: UICollectionView) {
        collectionViewController.showMessage(title: "Watchlist Empty".localized,
                                             body: "Try adding movies or shows to your watchlist.".localized)
    }
}
