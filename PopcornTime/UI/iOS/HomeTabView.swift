import SwiftUI
import PopcornKit

/// The hub's state of the iOS app: PopcornKit's (`HomeState.shared`: the
/// real hosts, the disk cache), or — DEBUG launches with
/// `-PTDebugHomeFixtures` — one fed from recorded answers.
@MainActor
enum IOSHome {
    static let state: HomeState = {
        #if DEBUG
        if let recorded = IOSDebugHooks.homeState() { return recorded }
        #endif
        return .shared
    }()
}

/// The "Accueil" tab: the shared Home screen (`HomeScreen`) in the iOS
/// app's navigation. A card opens its page on this tab's stack, zooming out
/// of the card; a Continue Watching card and the carousel's Play open the
/// page to play (`MediaPageRequest.autoPlay`: the page's own Play, behind
/// its questions); "See All" pushes the shelf's own list
/// (`HomeShelfGridView`).
///
/// No title in the bar, as in the Apple TV app: the artwork goes up to the
/// screen's edge, and once the page has scrolled past its carousel a black
/// shade under the status bar and the Settings button keeps them off the
/// posters.
struct HomeTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.mediaZoomNamespace) private var zoom
    /// How dark the shade under the bars is, as the page scrolls.
    @State private var shade = HomeScrollShade()

    var body: some View {
        ZStack(alignment: .top) {
            HomeScreen(state: IOSHome.state,
                       initialShelf: initialShelf,
                       pinnedHeroPage: pinnedHeroPage,
                       scrollShade: shade,
                       open: open,
                       seeAll: seeAll,
                       showsSeeAll: HomeTabView.showsSeeAll)
                .environment(\.homeZoomNamespace, zoom)
            // Opaque behind the status bar and the Settings button as soon
            // as the page leaves its carousel: nothing shows through.
            HomeTabShade(shade: shade)
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        // The page draws its own shade: the system's edge effect would
        // blur the top of the artwork.
        .scrollEdgeEffectHidden(true, for: .top)
        .toolbar {
            // An empty title: the tab says which screen this is.
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
            RootToolbar()
        }
    }

    /// Every shelf of posters lists its own cards; a shelf of episodes or
    /// of resume cards has a grid only when a catalogue continues it.
    static func showsSeeAll(_ shelf: HomeShelf) -> Bool {
        switch shelf.style {
        case .posters, .ranked: return shelf.items.count > 3 || shelf.seeAll != nil
        case .landscape, .hero: return shelf.seeAll != nil
        }
    }

    /// A card picked: its title's page, told what it was opened for
    /// (`MediaPageRequest.home`, the Mac's rule too) — an episode's card
    /// opens the show on that episode's season.
    private func open(_ selection: HomeSelection) {
        let request = MediaPageRequest.home(item: selection.item, shelfID: selection.shelfID, plays: selection.intent == .play)
        guard let media = selection.item.media,
              let route = MediaRoute(media: media, zoomID: selection.sourceID, request: request) else { return }
        router.open(route, in: .home)
    }

    private func seeAll(_ shelf: HomeShelf) {
        if shelf.seeAll?.catalogue == .watchlist {
            // The watchlist is a tab of its own.
            router.selection = .watchlist
            return
        }
        // The shelf's own cards, in its order, then its catalogue.
        router.open(CatalogRoute.shelf(id: shelf.id), in: .home)
    }

    private var initialShelf: String? {
        #if DEBUG
        return IOSDebugHooks.homeShelf
        #else
        return nil
        #endif
    }

    private var pinnedHeroPage: Int? {
        #if DEBUG
        return IOSDebugHooks.homeHeroPage
        #else
        return nil
        #endif
    }
}

/// A shelf's "See All": its cards in the order the Home shows them, under
/// its title, as the Home's poster cards — then, for a shelf a catalogue
/// continues (`HomeShelf.seeAll`), that catalogue's pages, without the
/// titles already listed.
/// The Home's top shade, the only view that reads its level.
private struct HomeTabShade: View {
    let shade: HomeScrollShade

    var body: some View {
        TopShade(level: shade.level)
    }
}

struct HomeShelfGridView: View {
    let shelfID: String

    @State private var more = ShelfMore()
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let text = HomeCardText()

    private var shelf: HomeShelf? {
        let state = IOSHome.state
        return HomeHarmony(shelves: state.shelves, hero: []).shelves.first { $0.id == shelfID }
    }

    var body: some View {
        let shelf = self.shelf
        let entries = (shelf?.items.map(ShelfEntry.init(item:)) ?? []) + more.entries(after: shelf?.items ?? [])
        PosterGridReader { metrics in
            ScrollView {
                if horizontalSizeClass == .regular {
                    // An iPad: the title on the grid's edge, not the bar's.
                    Text(verbatim: shelf.map(text.title(of:)) ?? "")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, metrics.sideInset)
                        .padding(.top, 12)
                        .accessibilityAddTraits(.isHeader)
                }
                LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: PosterGrid.lineSpacing) {
                    ForEach(entries) { entry in
                        if let route = entry.route(shelfID: shelfID) {
                            NavigationLink(value: route) {
                                PosterCard(item: entry.item, size: metrics.cellSize, zoomID: entry.zoomID)
                            }
                            .buttonStyle(HomeCardButtonStyle())
                            .contextMenu {
                                if entry.media == nil {
                                    HomeCardMenu(item: entry.item, shelfID: shelfID, open: open)
                                }
                            }
                            .accessibilityIdentifier("SeeAll.Card.\(entry.id)")
                            .onAppear {
                                if entries.suffix(PosterGrid.preloadDistance).contains(where: { $0.id == entry.id }) {
                                    more.loadNext(seeAll: shelf?.seeAll)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, metrics.sideInset)
                .padding(.top, 8)
                .environment(\.homeHiddenBadges, HomeListBadges.hidden(shelfID: shelfID, items: entries.map(\.item)))
                if more.isLoading {
                    ProgressView().padding(.vertical, 24)
                }
            }
            .scrollTopShade()
        }
        .navigationTitle(Text(verbatim: shelf.map(text.title(of:)) ?? ""))
        .navigationBarTitleDisplayMode(horizontalSizeClass == .regular ? .inline : .large)
        .toolbar {
            // An iPad shows the title once, over the grid.
            if horizontalSizeClass == .regular {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
            }
        }
        .accessibilityIdentifier("SeeAll.\(shelfID)")
        .onAppear {
            // A short shelf: its catalogue's first page at once.
            if let shelf, shelf.items.count < 12 { more.loadNext(seeAll: shelf.seeAll) }
        }
    }
}

extension HomeShelfGridView {
    /// A menu's Play or "Voir la fiche": the title's page, as from the Home.
    fileprivate func open(_ selection: HomeSelection) {
        let request = MediaPageRequest.home(item: selection.item, shelfID: selection.shelfID, plays: selection.intent == .play)
        guard let media = selection.item.media,
              let route = MediaRoute(media: media, zoomID: "seeall/\(selection.item.id)", request: request) else { return }
        router.open(route, in: .home)
    }
}

/// A card of a shelf's grid: one of the shelf's, or one of its catalogue's.
private struct ShelfEntry: Identifiable {
    let item: HomeItem
    /// A catalogue's title (its page opens on it); nil: the shelf's card.
    var media: Media?

    var id: String { item.id }
    var zoomID: String { "seeall/\(item.id)" }

    init(item: HomeItem) { self.item = item }

    init(media: Media) {
        self.item = GridCard.item(media)
        self.media = media
    }

    func route(shelfID: String) -> MediaRoute? {
        if let media { return MediaRoute(media: media, zoomID: zoomID) }
        guard let media = item.media else { return nil }
        return MediaRoute(media: media, zoomID: zoomID,
                          request: .home(item: item, shelfID: shelfID, plays: false))
    }
}

/// The catalogue pages after a shelf's own cards.
@MainActor
@Observable
private final class ShelfMore {
    private(set) var loaded: [ShelfEntry] = []
    private(set) var isLoading = false
    private var page = 0
    private var isOver = false
    /// A streaming shelf's catalogue (TMDB), page after page.
    private var pages: TMDBStreamingClient.CataloguePages?

    /// The catalogue's titles that are not on the shelf.
    func entries(after shelf: [HomeItem]) -> [ShelfEntry] {
        var seen = Set(shelf.map(\.imdbId))
        return loaded.filter { seen.insert($0.item.imdbId).inserted }
    }

    func loadNext(seeAll: HomeSeeAll?) {
        guard let seeAll, !isLoading, !isOver else { return }
        let next = page + 1
        let finish: ([Media]?) -> Void = { [weak self] media in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                guard let media, !media.isEmpty else { self.isOver = true; return }
                self.page = next
                self.loaded += media.map(ShelfEntry.init(media:))
            }
        }
        switch seeAll.catalogue {
        case .movies:
            isLoading = true
            PopcornKit.loadMovies(next, filterBy: seeAll.movieFilter ?? .trending, genre: seeAll.genreFilter) { movies, _ in finish(movies) }
        case .shows:
            isLoading = true
            PopcornKit.loadShows(next, filterBy: seeAll.showFilter ?? .trending, genre: seeAll.genreFilter) { shows, _ in finish(shows) }
        case .watchlist:
            isOver = true
        case .streaming:
            if pages == nil { pages = seeAll.streamingPages() }
            guard let pages else { isOver = true; return }
            isLoading = true
            pages.load { [weak self] items in
                guard let self else { return }
                self.isLoading = false
                guard let items, !items.isEmpty else { self.isOver = pages.isOver || items == nil; return }
                self.page = next
                self.loaded += items.map(ShelfEntry.init(item:))
            }
        }
    }
}

#Preview {
    MediaStack(tab: .home) { HomeTabView() }
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}
