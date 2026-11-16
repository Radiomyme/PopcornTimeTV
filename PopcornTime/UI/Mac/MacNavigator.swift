import Foundation
import AppKit
import Combine
import SwiftUI
import PopcornKit

/// Sidebar sections of the Mac app, in sidebar order: « Accueil » (Home)
/// first — the section the app opens on, ⌘1 in the Go menu.
enum MacSection: String, CaseIterable, Identifiable {
    case home
    case movies
    case shows
    case watchlist
    case search

    var id: String { rawValue }

    /// The section the app opens on: the first one.
    static var launch: MacSection { allCases[0] }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .movies: return "film"
        case .shows: return "play.tv"
        case .watchlist: return "bookmark"
        case .search: return "magnifyingglass"
        }
    }

    /// The key of the section's name in Localizable.strings ("Home" =
    /// "Accueil", "Watchlist" = "Ma liste"…); `rawValue` is only the id.
    var titleKey: String {
        switch self {
        case .home: return "Home"
        case .movies: return "Movies"
        case .shows: return "Shows"
        case .watchlist: return "Watchlist"
        case .search: return "Search"
        }
    }

    /// Sidebar and menu label.
    var title: Text { Text(LocalizedStringKey(titleKey)) }

    /// The sections the Go menu numbers (⌘1…⌘9, in sidebar order). Search
    /// is not one of them: it has ⌘F, which also focuses its field.
    static var numbered: [MacSection] { allCases.filter { $0 != .search } }

    /// ⌘ + this digit selects the section (Go menu).
    var shortcut: KeyEquivalent? {
        guard let index = Self.numbered.firstIndex(of: self), index < 9 else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }
}

/// A page of the detail stack named by value: what `MacNavigator.open(_:)`
/// and `NavigationLink(value:)` push besides the catalogue's own `Movie` /
/// `Show` values (which keep their destinations). The Home's cards and the
/// popcorntime:// links open their pages this way: they know a title by
/// its IMDb id (the page loads the title itself), and may ask the page for
/// more than showing itself (`MediaPageRequest`: play, a season). New kinds
/// of pages are new cases here and in `MacRootView.destination(for:)`.
enum MacRoute: Hashable {
    /// A movie's page from its IMDb id; `title` shows until it has loaded.
    case movie(id: String, title: String, request: MediaPageRequest = MediaPageRequest())
    /// A show's page from its IMDb id.
    case show(id: String, title: String, request: MediaPageRequest = MediaPageRequest())
    /// A Home shelf's « See All »: its cards, then its catalogue's pages,
    /// on the Home's stack (`MacShelfGridView`).
    case shelf(id: String)
}

/// The Mac window's navigation and the state that outlives a section
/// change: which section shows, the pages pushed over it, and the grids'
/// own models — kept here, not in the grids, so that leaving a section and
/// coming back neither loads its list again nor loses its filter and
/// place, and so that a « see all » can select a section and a filter
/// (`showMovies`, `showShows`). One per window (`MacRootView`); in the
/// environment of every page, and the Go menu's target.
@MainActor
final class MacNavigator: ObservableObject {
    @Published var section: MacSection = .launch {
        didSet {
            guard section != oldValue else { return }
            // Another section: its page is the page, nothing pushed over it.
            if !path.isEmpty { path = NavigationPath() }
            if section == .home, !keepsHome { keepsHome = true }
        }
    }
    /// The detail pages pushed over the section's page.
    @Published var path = NavigationPath()
    /// Bumped by `focusSearch()`: the Search page focuses its field.
    @Published private(set) var searchFocusRequest = 0

    /// The Home has been shown in this window: its page then stays alive
    /// under the other sections (`MacRootView`), so that coming back finds
    /// it as it was left — scrolled, each shelf where it was, the carousel
    /// on its page. False until then: a window opened on another section
    /// does not load the Home behind it.
    @Published private(set) var keepsHome: Bool

    let movies: MacMoviesModel
    let shows: MacShowsModel
    let search: MacSearchModel
    /// Watchlist and watched state, for the posters and the Watchlist page.
    let library = MacLibraryState()
    /// The Home's hub (`MacHome.state`: one for the app) and this window's
    /// keyboard cursor and pointer on it.
    let home: HomeState = MacHome.state
    let homeControls = HomeControls()
    /// Opens the Settings window (a popcorntime://tab/settings link): set
    /// by the window's root view, which has the environment's action.
    var openSettings: () -> Void = {}

    init() {
        var movieFilter = MovieManager.Filters.trending
        var showFilter = ShowManager.Filters.trending
        var search = MacSearchModel()
        #if DEBUG
        MacDebugHooks.applySourceSwitches()
        if let filter = MacDebugHooks.movieFilter { movieFilter = filter }
        if let filter = MacDebugHooks.showFilter { showFilter = filter }
        if let failing = MacDebugHooks.failingSearch { search = failing }
        #endif
        movies = .movies(filter: movieFilter)
        shows = .shows(filter: showFilter)
        self.search = search
        keepsHome = true
        #if DEBUG
        // `-PTDebugSection`: the window opens on that section at once — a
        // verification run of another section does not load the Home.
        if let requested = MacDebugHooks.section, requested != .home {
            section = requested
            keepsHome = false
        }
        // `-PTDebugNoAnimation`: also the scrolls the Home animates by hand.
        homeControls.scrollsAnimated = !MacDebugHooks.disablesAnimations
        #endif
    }

    // MARK: Sections

    func select(_ section: MacSection) {
        self.section = section
    }

    /// « See all »: the Movies section on this filter (and genre), from
    /// its first page.
    func showMovies(filter: MovieManager.Filters, genre: NetworkManager.Genres = .all) {
        movies.show(filter: filter, genre: genre)
        section = .movies
        path = NavigationPath()
    }

    /// « See all »: the Shows section on this filter (and genre).
    func showShows(filter: ShowManager.Filters, genre: NetworkManager.Genres = .all) {
        shows.show(filter: filter, genre: genre)
        section = .shows
        path = NavigationPath()
    }

    /// ⌘F: the Search section, its field focused.
    func focusSearch() {
        section = .search
        path = NavigationPath()
        searchFocusRequest += 1
    }

    // MARK: Pages

    func open(_ movie: Movie) {
        path.append(movie)
    }

    func open(_ show: Show) {
        path.append(show)
    }

    func open(_ route: MacRoute) {
        path.append(route)
    }

    /// The title's page on top of the stack, as it told when it appeared
    /// (`MacGlassDetailScreen`), and its depth: a link to that title is
    /// handed to it rather than pushing a second copy of the page.
    private weak var pageOnTop: MacGlassDetailController?
    private var pageOnTopDepth = 0

    func pageAppeared(_ page: MacGlassDetailController, depth: Int) {
        pageOnTop = page
        pageOnTopDepth = depth
    }

    /// The page left the screen: unless another one has already said it is on top.
    func pageDisappeared(_ page: MacGlassDetailController) {
        if pageOnTop === page { pageOnTop = nil }
    }

    // MARK: Links

    /// A sheet is up in one of the app's windows (the player, the quality
    /// picker, the release notes): looked for in every window, not only the
    /// main or key one — AVKit's full screen is a window of its own, and a
    /// second window may be the one in front.
    static var isASheetUp: Bool {
        NSApp.windows.contains { $0.attachedSheet != nil || $0.isSheet }
    }

    /// A popcorntime:// link (`DeepLink`, as `AppLinkAction` reads it for
    /// the apps): a section, the Settings window, a search, or a title's
    /// page pushed over the page in front — Back returns to where the user
    /// was. False for a URL that is not such a link (Trakt's sign-in
    /// redirect has the same scheme), and for a link that arrives under a
    /// sheet (the player, the quality picker, the release notes): leaving
    /// the page would close it — the player with it.
    @discardableResult
    func open(url: URL) -> Bool {
        guard let action = AppLinkAction(url: url) else { return false }
        if Self.isASheetUp {
            NSSound.beep()
            return false
        }
        switch action {
        case .tab(let tab):
            // The iOS tabs and the Mac sections have the same names.
            guard let section = MacSection(rawValue: tab.rawValue) else { return false }
            select(section)
        case .settings:
            openSettings()
        case .search(let text):
            focusSearch()
            if !text.isEmpty { search.text = text }
        case .page(let kind, let id, let title, let request):
            // The page of that title is already in front: it takes the link.
            if let page = pageOnTop, !path.isEmpty, pageOnTopDepth == path.count, page.shows(id: id, isMovie: kind == .movie) {
                page.reopen(request)
                return true
            }
            switch kind {
            case .movie: open(.movie(id: id, title: title ?? "", request: request))
            case .show: open(.show(id: id, title: title ?? "", request: request))
            }
        }
        return true
    }

    var canGoBack: Bool { !path.isEmpty }

    func goBack() {
        if !path.isEmpty { path.removeLast() }
    }

    // MARK: Refresh

    /// ⌘R makes sense on the section's own page only (a title's page loads
    /// once), and where a list comes from the network or the library.
    var canRefresh: Bool { path.isEmpty }

    /// ⌘R: the section's list again. The Home and the grids keep their
    /// posters until the new answers are in.
    func refresh() {
        guard canRefresh else { return }
        switch section {
        case .home:
            // Every list again, and every host, even one that just failed;
            // the cards stay until the answers are in.
            Task {
                await home.refresh(force: true)
                #if DEBUG
                if MacDebugHooks.isActive { print("[MacHome] debug: refreshed — \(home.shelves.count) shelves, hero \(home.heroItems.count)") }
                #endif
            }
            library.reload()
        case .movies: movies.refresh()
        case .shows: shows.refresh()
        case .watchlist: library.reload()
        case .search: search.retry()
        }
    }
}

/// The window the Go menu acts on when no scene has the focus — the app
/// has just been launched, or its windows are not key: the last
/// `MacRootView` that came in front. Follows that window's navigator, so
/// the menu's Back and Refresh enable and disable with it.
@MainActor
final class MacFrontNavigator: ObservableObject {
    static let shared = MacFrontNavigator()

    private(set) weak var navigator: MacNavigator?
    private let all = NSHashTable<MacNavigator>.weakObjects()
    private var changes: AnyCancellable?

    private init() {}

    /// A window opened: it is the front one if there was none.
    func windowAppeared(_ navigator: MacNavigator) {
        all.add(navigator)
        if self.navigator == nil { setFront(navigator) }
    }

    /// A window got the keyboard.
    func windowBecameKey(_ navigator: MacNavigator) {
        all.add(navigator)
        if self.navigator !== navigator { setFront(navigator) }
    }

    /// A window closed: another one, if any, is the front one.
    func windowClosed(_ navigator: MacNavigator) {
        all.remove(navigator)
        if self.navigator === navigator || self.navigator == nil { setFront(all.allObjects.first) }
    }

    private func setFront(_ navigator: MacNavigator?) {
        objectWillChange.send()
        self.navigator = navigator
        changes = navigator?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
