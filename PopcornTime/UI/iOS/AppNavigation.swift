

import SwiftUI
import PopcornKit

/// A grid of the catalogue pushed on a stack: `NavigationLink(value:)` with
/// one of these opens the Movies or Shows grid on that filter and genre
/// ("See all" of a Home shelf, the genre shortcuts of Search).
enum CatalogRoute: Hashable {
    case movies(filter: MovieManager.Filters, genre: NetworkManager.Genres = .all)
    case shows(filter: ShowManager.Filters, genre: NetworkManager.Genres = .all)
    /// A Home shelf's own cards, in its order, then its catalogue's next
    /// pages ("See All" of the Home).
    case shelf(id: String)
}

/// A title's page pushed with more than the title: the card it zooms out of
/// (a title may sit on several shelves of the Home: its own id would name
/// several posters) and what the page is opened for (`MediaPageRequest`).
/// A plain `Movie` / `Show` value still pushes the page from a grid.
struct MediaRoute: Hashable {
    enum Target: Hashable {
        case movie(Movie)
        case show(Show)
    }

    let target: Target
    /// The id given to `matchedTransitionSource` by the card; nil: the
    /// title's id, as the grids' posters use.
    var zoomID: String?
    var request = MediaPageRequest()

    /// Nil when `media` is neither a movie nor a show.
    init?(media: Media, zoomID: String? = nil, request: MediaPageRequest = MediaPageRequest()) {
        if let movie = media as? Movie {
            target = .movie(movie)
        } else if let show = media as? Show {
            target = .show(show)
        } else {
            return nil
        }
        self.zoomID = zoomID
        self.request = request
    }

    var media: Media {
        switch target {
        case .movie(let movie): return movie
        case .show(let show): return show
        }
    }
}

/// Which tab shows and what is pushed on each tab's stack. One instance, made
/// by `RootTabView` and read from the environment (`@Environment(AppRouter.self)`).
@MainActor
@Observable
final class AppRouter {
    /// The tab the app opens on.
    static let initialTab: AppTab = .home

    var selection: AppTab = AppRouter.initialTab
    /// The Settings sheet (the gear of the root screens).
    var showsSettings = false
    /// A text a link asked to search: the Search screen types it in its
    /// field and forgets it (`SearchView`).
    var searchRequest: String?
    private var paths: [AppTab: NavigationPath] = [:]

    /// The title's page on top of a tab's stack, as it told when it appeared
    /// (`MediaDetailView`): a link to that title is handed to it rather
    /// than pushing a second copy of the page.
    private struct PageOnTop {
        let token: UUID
        let id: String
        let isMovie: Bool
        /// The stack's depth when it appeared: it is on top while the stack has it.
        let depth: Int
        let reopen: (MediaPageRequest) -> Void
    }
    @ObservationIgnored private var pagesOnTop: [AppTab: PageOnTop] = [:]
    /// Links held while a stream or the player is up (`AppLinkHold`).
    @ObservationIgnored private var linkHold = AppLinkHold()

    /// A page's stream is being prepared or its player is up (`isUp`), or
    /// that is over: a link held meanwhile is shown then, without playing.
    func playerChanged(_ token: UUID, isUp: Bool) {
        guard let held = linkHold.playerChanged(token, isUp: isUp) else { return }
        show(held)
    }

    /// A title's page appeared on top of `tab`'s stack; `reopen` takes a
    /// link to it (its season, its episode, `play`).
    func pageAppeared(_ token: UUID, media: Media, in tab: AppTab, reopen: @escaping (MediaPageRequest) -> Void) {
        pagesOnTop[tab] = PageOnTop(token: token, id: media.id, isMovie: media is Movie,
                                    depth: paths[tab]?.count ?? 0, reopen: reopen)
    }

    /// The page left the screen (covered, popped): unless another page
    /// has already said it is on top.
    func pageDisappeared(_ token: UUID, in tab: AppTab) {
        if pagesOnTop[tab]?.token == token { pagesOnTop[tab] = nil }
    }

    /// The stack of `tab`, for `NavigationStack(path:)`.
    func path(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(get: { self.paths[tab] ?? NavigationPath() },
                set: { self.paths[tab] = $0 })
    }

    /// Shows `tab` and pushes the page of `media` (a Movie or a Show) on it.
    func open(_ media: Media, in tab: AppTab) {
        var path = paths[tab] ?? NavigationPath()
        if let movie = media as? Movie {
            path.append(movie)
        } else if let show = media as? Show {
            path.append(show)
        } else {
            return
        }
        paths[tab] = path
        selection = tab
    }

    /// Shows `tab` and pushes a title's page on it, with what it is opened
    /// for and the card it zooms out of.
    func open(_ route: MediaRoute, in tab: AppTab) {
        var path = paths[tab] ?? NavigationPath()
        path.append(route)
        paths[tab] = path
        selection = tab
    }

    /// A popcorntime:// link the system (or a share sheet, a widget, the Top
    /// Shelf of an Apple TV…) handed the app. True when the app shows it;
    /// false for anything else — Trakt's redirect, a broken link.
    /// While a stream or the player is up the link is held, and shown —
    /// as a page, never playing — once the player is gone (`AppLinkHold`).
    @discardableResult
    func open(url: URL) -> Bool {
        guard let action = AppLinkAction(url: url) else { return false }
        if let now = linkHold.receive(action) { show(now) }
        return true
    }

    private func show(_ action: AppLinkAction) {
        switch action {
        case .tab(let tab):
            showsSettings = false
            selection = tab
        case .settings:
            showsSettings = true
        case .search(let text):
            showsSettings = false
            if !text.isEmpty { searchRequest = text }
            selection = .search
        case let .page(kind, id, title, request):
            showsSettings = false
            // The page of that title is already in front: it takes the link.
            if let page = pagesOnTop[selection], page.depth > 0, page.depth == (paths[selection]?.count ?? 0),
               page.id == id, page.isMovie == (kind == .movie) {
                page.reopen(request)
                return
            }
            // The page loads the title by its id; the link's title shows
            // meanwhile.
            let media: Media = kind == .movie ? Movie(title: title ?? "", id: id) : Show(title: title ?? "", id: id)
            guard let route = MediaRoute(media: media, request: request) else { return }
            // On the tab in front: the page comes over what the user was
            // looking at, and Back returns there.
            open(route, in: selection)
        }
    }

    /// Shows `tab` and pushes a catalogue grid on it.
    func open(_ route: CatalogRoute, in tab: AppTab) {
        var path = paths[tab] ?? NavigationPath()
        path.append(route)
        paths[tab] = path
        selection = tab
    }
}

// MARK: - Stack

/// One tab's navigation stack: its path (`AppRouter`), the destinations every
/// screen of the app pushes (a Movie, a Show, a `MediaRoute`, a
/// `CatalogRoute`) and the namespace of the zoom from a poster to its page.
struct MediaStack<Root: View>: View {
    let tab: AppTab
    @ViewBuilder var root: () -> Root

    @Environment(AppRouter.self) private var router
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: router.path(for: tab)) {
            root()
                .navigationDestination(for: Movie.self) { movie in
                    MediaDetailView(media: movie)
                        .navigationTransition(.zoom(sourceID: movie.id, in: zoom))
                }
                .navigationDestination(for: Show.self) { show in
                    MediaDetailView(media: show)
                        .navigationTransition(.zoom(sourceID: show.id, in: zoom))
                }
                .navigationDestination(for: MediaRoute.self) { route in
                    MediaDetailView(media: route.media, request: route.request)
                        .navigationTransition(.zoom(sourceID: route.zoomID ?? route.media.id, in: zoom))
                }
                .navigationDestination(for: CatalogRoute.self) { route in
                    switch route {
                    case .movies(let filter, let genre):
                        MoviesGridView(filter: filter, genre: genre, isRoot: false)
                    case .shows(let filter, let genre):
                        ShowsGridView(filter: filter, genre: genre, isRoot: false)
                    case .shelf(let id):
                        HomeShelfGridView(shelfID: id)
                    }
                }
        }
        // On the stack, not on its root: pushed pages (the related titles of
        // a detail page) mark their posters with the same namespace.
        .environment(\.mediaZoomNamespace, zoom)
        .environment(\.mediaStackTab, tab)
    }
}

private struct MediaZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct MediaStackTabKey: EnvironmentKey {
    static let defaultValue: AppTab? = nil
}

extension EnvironmentValues {
    /// The tab whose stack shows this view (`MediaStack`).
    var mediaStackTab: AppTab? {
        get { self[MediaStackTabKey.self] }
        set { self[MediaStackTabKey.self] = newValue }
    }

    /// The namespace of the poster → page zoom on this stack (`MediaStack`).
    var mediaZoomNamespace: Namespace.ID? {
        get { self[MediaZoomNamespaceKey.self] }
        set { self[MediaZoomNamespaceKey.self] = newValue }
    }
}

private struct MediaZoomSource: ViewModifier {
    let id: String?
    @Environment(\.mediaZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let id, let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

extension View {
    /// Marks the poster of the title `id`: its page zooms out of it. Does
    /// nothing outside a `MediaStack` or without an id.
    func mediaZoomSource(id: String?) -> some View {
        modifier(MediaZoomSource(id: id))
    }
}

// MARK: - Root toolbar

/// The gear of the root screens: opens Settings (a sheet of `RootTabView`).
struct RootToolbar: ToolbarContent {
    @Environment(AppRouter.self) private var router

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                router.showsSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("Root.Settings")
        }
    }
}
