

import UIKit
import AlamofireImage
import PopcornKit

class SearchViewController: MainViewController, UISearchBarDelegate {
    
#if os(tvOS)
    
    var searchBar: UISearchBar!
    var searchController: UISearchController!
    var searchContainerViewController: UISearchContainerViewController?
    
#endif

    let searchDelay: TimeInterval = 0.25
    var workItem: DispatchWorkItem!

    var fetchType: Trakt.MediaType = .movies

    override func load(page: Int) {
        filterSearchText(searchBar?.text ?? "")
    }
    
    
    override func minItemSize(forCellIn collectionView: UICollectionView, at indexPath: IndexPath) -> CGSize? {
        if UIDevice.current.userInterfaceIdiom == .tv {
            return CGSize(width: 250, height: fetchType == .people ? 400 : 460)
        } else {
            return CGSize(width: 108, height: fetchType == .people ? 160 : 185)
        }
    }
    
    func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
        switch selectedScope {
        case 0:
            fetchType = .movies
        case 1:
            fetchType = .shows
        case 2:
            fetchType = .people
        default: return
        }
        filterSearchText(searchBar.text ?? "")
    }
    
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        workItem?.cancel()
        
        workItem = DispatchWorkItem {
            self.filterSearchText(searchText)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + searchDelay, execute: workItem)
    }
    
    func filterSearchText(_ text: String) {
        collectionViewController.isLoading = !text.isEmpty
        collectionViewController.dataSources = [[]]
        collectionView?.reloadData()

        if text.isEmpty { return }

        let completion: ([AnyHashable]?, NSError?) -> Void = { [unowned self] (data, error) in
            self.collectionViewController.dataSources = [data ?? []]
            self.collectionViewController.error = error
            self.collectionViewController.isLoading = false
            self.collectionView?.reloadData()
            // Reset the cached focus index path so the next focus update
            // targets the first cell of the new result set. Without this,
            // a previous index (say row=14 from a Shows search) sticks
            // around and the focus engine refuses to descend into a Movies
            // result set that only has 2 cells (out-of-bounds index).
            self.collectionViewController.focusIndexPath = IndexPath(item: 0, section: 0)
            self.collectionViewController.collectionView?.layoutIfNeeded()
            self.collectionViewController.collectionView?.setNeedsFocusUpdate()
            self.collectionViewController.collectionView?.updateFocusIfNeeded()
        }
        
        switch fetchType {
        case .movies:
            PopcornKit.loadMovies(searchTerm: text) { results, error in
                completion(results, error)
            }
        case .shows:
            PopcornKit.loadShows(searchTerm: text) { results, error in
                completion(results, error)
            }
        case .people:
            TraktManager.shared.search(forPerson: text) { results, error in
                completion(results as! [Crew], error)
            }
        default:
            return
        }
    }
    
    override func collectionView(isEmptyForUnknownReason collectionView: UICollectionView) {
        if let background: ErrorBackgroundView = .fromNib(),
            let text = searchBar.text, !text.isEmpty {
            
            let openQuote = Locale.current.quotationBeginDelimiter ?? "\""
            let closeQuote = Locale.current.quotationEndDelimiter ?? "\""
            
            background.setUpView(title: "No results".localized, description: .localizedStringWithFormat("We didn't turn anything up for %@. Try something else.".localized, "\(openQuote + text + closeQuote)"))
            
            collectionView.backgroundView = background
        }
    }
}
