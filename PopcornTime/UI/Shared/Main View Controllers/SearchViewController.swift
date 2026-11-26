

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

    /// Bumped by every search: the answer of an older one (another text)
    /// is ignored when it lands. A broad search ("ave") can answer after the
    /// narrower one typed next ("avengers"): its results used to replace the
    /// newer ones.
    private var searchGeneration = 0

    /// One search looks in every catalogue at once: movies, shows and
    /// people come back in their own titled sections (there is no Movies /
    /// Shows / People switch to pick first).
    private enum Group: Int, CaseIterable { case movies, shows, people }
    private var results: [Group: [AnyHashable]] = [:]
    private var failures: [Group: NSError] = [:]
    private var pending: Set<Group> = []

    override func load(page: Int) {
        filterSearchText(searchBar?.text ?? "")
    }

    private func group(ofSection section: Int) -> Group? {
        guard let first = collectionViewController.dataSources[safe: section]?.first else { return nil }
        switch first {
        case is Movie: return .movies
        case is Show: return .shows
        case is Crew: return .people
        default: return nil
        }
    }

    override func minItemSize(forCellIn collectionView: UICollectionView, at indexPath: IndexPath) -> CGSize? {
        let people = group(ofSection: indexPath.section) == .people
        if UIDevice.current.userInterfaceIdiom == .tv {
            // Posters on the grids' own layout; people keep their round cells.
            return people ? CGSize(width: 250, height: 400) : nil
        } else {
            return CGSize(width: 108, height: people ? 160 : 185)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, titleForHeaderInSection section: Int) -> String? {
        switch group(ofSection: section) {
        case .movies: return "Movies".localized
        case .shows: return "Shows".localized
        case .people: return "People".localized
        case nil: return nil
        }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        workItem?.cancel()

        workItem = DispatchWorkItem {
            self.filterSearchText(searchText)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + searchDelay, execute: workItem)
    }

    func filterSearchText(_ text: String) {
        searchGeneration += 1
        let generation = searchGeneration
        results = [:]
        failures = [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = trimmed.isEmpty ? [] : Set(Group.allCases)
        collectionViewController.isLoading = !pending.isEmpty
        collectionViewController.dataSources = [[]]
        collectionViewController.error = nil
        collectionView?.reloadData()

        if trimmed.isEmpty { return }

        func receive(_ group: Group) -> ([AnyHashable]?, NSError?) -> Void {
            return { [weak self] data, error in
                DispatchQueue.main.async {
                    guard let self = self, generation == self.searchGeneration else { return }
                    self.results[group] = data ?? []
                    if let error = error { self.failures[group] = error }
                    self.pending.remove(group)
                    self.showResults()
                }
            }
        }

        PopcornKit.loadMovies(searchTerm: trimmed) { results, error in
            receive(.movies)(results, error)
        }
        PopcornKit.loadShows(searchTerm: trimmed) { results, error in
            receive(.shows)(results, error)
        }
        TraktManager.shared.search(forPerson: trimmed) { results, error in
            // Nil when Trakt fails: people simply stay out of the results
            // (the search still answers with the movies and shows).
            receive(.people)(results?.compactMap { $0 as? Crew }, error)
        }
    }

    /// The sections answered so far, movies first, then shows, then people.
    /// An error shows only when every catalogue failed and none answered.
    private func showResults() {
        let sections = Group.allCases.compactMap { results[$0] }.filter { !$0.isEmpty }
        collectionViewController.dataSources = sections.isEmpty ? [[]] : sections
        collectionViewController.isLoading = !pending.isEmpty && sections.isEmpty
        let catalogues: [Group] = [.movies, .shows]
        collectionViewController.error = pending.isEmpty && sections.isEmpty && catalogues.allSatisfy({ failures[$0] != nil })
            ? failures[.movies] : nil
        collectionView?.reloadData()
        // Reset the cached focus index path so the next focus update
        // targets the first cell of the new result set. Without this, a
        // previous index (say row=14 from a broader search) sticks around
        // and the focus engine refuses to descend into a smaller result set
        // (out-of-bounds index).
        collectionViewController.focusIndexPath = IndexPath(item: 0, section: 0)
        collectionViewController.collectionView?.layoutIfNeeded()
        collectionViewController.collectionView?.setNeedsFocusUpdate()
        collectionViewController.collectionView?.updateFocusIfNeeded()
    }

    override func collectionView(isEmptyForUnknownReason collectionView: UICollectionView) {
        guard let text = searchBar.text, !text.isEmpty else { return }
        let openQuote = Locale.current.quotationBeginDelimiter ?? "\""
        let closeQuote = Locale.current.quotationEndDelimiter ?? "\""
        collectionViewController.showMessage(title: "No results".localized,
                                             body: .localizedStringWithFormat("We didn't turn anything up for %@. Try something else.".localized, "\(openQuote + text + closeQuote)"))
    }
}
