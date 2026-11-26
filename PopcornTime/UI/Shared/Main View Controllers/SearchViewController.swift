

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

    /// One search looks in both catalogues at once: movies and shows come
    /// back as two titled rows, always in this order (there is no Movies /
    /// Shows switch to pick first). No people: Trakt, their only source,
    /// refuses the app's key, and a person's page needs it too.
    enum Group: Int, CaseIterable { case movies, shows }

    /// The query being searched or shown, which answers still count (an
    /// older query's are dropped: « ave » answering after « avengers » never
    /// replaces it) and which catalogue failed. The Mac's search page keeps
    /// the same session (`MacSearchModel`).
    private var session = SearchSession<Group>(kinds: Group.allCases)
    /// The current query's answers so far: shown once both are in.
    private var answers: [Group: [AnyHashable]] = [:]
    private var errors: [Group: NSError] = [:]

    override func load(page: Int) {
        filterSearchText(searchBar?.text ?? "")
    }

    /// The group of a row: what its titles are.
    private func group(ofSection section: Int) -> Group? {
        switch collectionViewController.dataSources[safe: section]?.first {
        case is Movie: return .movies
        case is Show: return .shows
        default: return nil
        }
    }

    override func collectionView(_ collectionView: UICollectionView, titleForHeaderInSection section: Int) -> String? {
        switch group(ofSection: section) {
        case .movies: return "Movies".localized
        case .shows: return "Shows".localized
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

    /// Searches `text` in both catalogues. The same query as the one shown
    /// (a space typed at its end) sends nothing; nor does an empty one,
    /// which brings back the empty starting screen.
    func filterSearchText(_ text: String) {
        // One character is a query here: the Apple TV keyboard has no Return
        // to say that a single letter (« X », « M ») is meant, as the Mac's
        // and the iPhone's fields have.
        guard let token = session.begin(text, submitted: true) else {
            if session.phase == .idle { showStartingScreen() }
            return
        }
        answers = [:]
        errors = [:]
        showSearching()

        func receive(_ group: Group) -> ([AnyHashable]?, NSError?, Bool) -> Void {
            return { [weak self] items, error, incomplete in
                DispatchQueue.main.async {
                    guard let self = self,
                          self.session.receive(group, count: items?.count ?? 0, error: error?.localizedDescription,
                                               incomplete: incomplete, token: token) else { return }
                    self.answers[group] = items ?? []
                    if let error = error { self.errors[group] = error }
                    // Movies and shows together, once both have answered
                    // (each source has its own timeout): a row that came in
                    // later was put above the one being browsed, and every
                    // answer reloaded the grid and took the focus back to
                    // its first poster.
                    if !self.session.isSearching { self.showResults() }
                }
            }
        }

        let query = session.query
        #if DEBUG
        if let error = Self.debugFailure(of: .movies) { receive(.movies)(nil, error, false) } else {
            PopcornKit.searchMovies(query) { results, error, incomplete in receive(.movies)(results, error, incomplete) }
        }
        if let error = Self.debugFailure(of: .shows) { receive(.shows)(nil, error, false) } else {
            PopcornKit.searchShows(query) { results, error, incomplete in receive(.shows)(results, error, incomplete) }
        }
        #else
        PopcornKit.searchMovies(query) { results, error, incomplete in receive(.movies)(results, error, incomplete) }
        PopcornKit.searchShows(query) { results, error, incomplete in receive(.shows)(results, error, incomplete) }
        #endif
    }

    /// Try Again (the grid's message, or the line under the rows that says
    /// which catalogue could not be searched): the same query once more. What
    /// was found stays on the screen, dimmed, until the new answers are in.
    override func retryLoading(page: Int?) {
        guard page == nil else { return }
        filterSearchText(searchBar?.text ?? "")
    }

    /// Nothing typed: nothing under the keyboard.
    private func showStartingScreen() {
        answers = [:]
        errors = [:]
        guard let grid = collectionViewController else { return }
        grid.isLoading = false
        grid.error = nil
        grid.partialFailure = nil
        grid.dataSources = [[]]
        grid.focusIndexPath = IndexPath(item: 0, section: 0)
        collectionView?.reloadData()
        setResultsDimmed(false)
    }

    /// A query was sent. What the last one found stays, dimmed, until this
    /// one has answered, as on the iPhone and the Mac (the posters turned
    /// into placeholder cards and back at every pause in the typing); cards
    /// where the posters will be only when there was nothing to show.
    private func showSearching() {
        guard let grid = collectionViewController else { return }
        if grid.dataSources.contains(where: { !$0.isEmpty }) {
            setResultsDimmed(true)
        } else {
            grid.isLoading = true
            grid.error = nil
            grid.partialFailure = nil
            grid.dataSources = [[]]
            collectionView?.reloadData()
        }
    }

    private func setResultsDimmed(_ dimmed: Bool) {
        guard let collectionView = collectionView else { return }
        let alpha: CGFloat = dimmed ? 0.45 : 1
        guard collectionView.alpha != alpha else { return }
        UIView.animate(withDuration: GridStyle.fadeDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            collectionView.alpha = alpha
        }
    }

    /// Both catalogues answered: their rows, movies first, in one reload.
    /// - Nothing found and a catalogue failed: its error, with Try Again
    ///   (not "No results": the title may well be in the catalogue that
    ///   could not be searched).
    /// - Titles found while the other catalogue failed: the titles, and one
    ///   line under them that says what is missing, with Try Again.
    private func showResults() {
        guard let grid = collectionViewController else { return }
        let rows = Group.allCases.compactMap { group in answers[group].flatMap { $0.isEmpty ? nil : (group, $0) } }

        // The focus is on a poster (it went down into the dimmed results
        // while they were being replaced): it stays on the same title when
        // its row still lists it, otherwise on the first title of its row.
        // In the keyboard, it stays there: the results start at their first
        // poster the next time it comes down.
        var focused: (kind: Group, id: AnyHashable)?
        if let indexPath = grid.focusedPosterIndexPath, let kind = group(ofSection: indexPath.section),
           let item = grid.dataSources[safe: indexPath.section]?[safe: indexPath.item] {
            focused = (kind, item)
        }
        let target = SearchSession<Group>.focusAfterReplacing(focused, rows: rows.map { (kind: $0.0, items: $0.1) })

        grid.isLoading = false
        grid.dataSources = rows.isEmpty ? [[]] : rows.map { $0.1 }
        if case .failed = session.phase {
            grid.error = Group.allCases.lazy.compactMap { self.errors[$0] }.first
        } else {
            grid.error = nil
        }
        grid.partialFailure = rows.isEmpty ? nil : partialFailureLine()
        grid.focusIndexPath = IndexPath(item: target.item, section: target.row)
        setResultsDimmed(false)
        if focused != nil {
            grid.reloadDataKeepingFocus()
        } else {
            collectionView?.reloadData()
        }
    }

    /// The catalogue that could not be searched while the other one found
    /// titles, said under them (as on the Mac): nil when both answered.
    private func partialFailureLine() -> String? {
        if session.failures[.movies] != nil { return "Search.MoviesFailed".localized }
        if session.failures[.shows] != nil { return "Search.ShowsFailed".localized }
        return nil
    }

    override func collectionView(isEmptyForUnknownReason collectionView: UICollectionView) {
        // Only for a query both catalogues answered with nothing: not for a
        // blank one ("No results for "   "" used to show for a space), and
        // the query as it was searched, without the field's spaces.
        guard session.phase == .empty, !session.query.isEmpty else { return }
        collectionViewController.showMessage(title: "No results".localized,
                                             body: .localizedStringWithFormat("We didn't turn anything up for %@. Try something else.".localized, session.query.quotedForDisplay()))
    }

    #if DEBUG
    /// `-PTDebugSearchFail <movies|shows|all>`: that catalogue's search fails
    /// as it does offline (the error with Try Again, or the line under the
    /// other catalogue's row). Try Again then searches for real.
    private static var debugFailing = UserDefaults.standard.string(forKey: "PTDebugSearchFail")

    private static func debugFailure(of group: Group) -> NSError? {
        guard let failing = debugFailing,
              failing == "all" || failing == (group == .movies ? "movies" : "shows") else { return nil }
        // Once: Try Again then gets real answers.
        if failing == "all" {
            debugFailing = group == .movies ? "shows" : nil
        } else {
            debugFailing = nil
        }
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                       userInfo: [NSLocalizedDescriptionKey: URLError(.notConnectedToInternet).localizedDescription])
    }
    #endif
}
