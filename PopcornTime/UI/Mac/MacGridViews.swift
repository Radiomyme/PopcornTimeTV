

import Foundation
import SwiftUI
import PopcornKit

// MARK: - Catalogue model (Movies, Shows)

typealias MacMoviesModel = MacCatalogModel<Movie, MovieManager.Filters>
typealias MacShowsModel = MacCatalogModel<Show, ShowManager.Filters>

/// One catalogue grid's state: its filter and genre, its pages
/// (`CatalogPager`, PopcornKit: stale answers, repeated titles, the end of
/// the list, refresh) and where it is scrolled. Owned by the window's
/// `MacNavigator`, not by the grid view: the section can go and come back
/// without loading anything again.
@MainActor
final class MacCatalogModel<Item: MacCatalogItem, Filter: Hashable>: ObservableObject {
    /// Loads one page; calls back on any queue. `snapshot` (the first page
    /// of a new list only): the page saved by an earlier load, handed over
    /// before `completion` gets the network's (`PopcornKit.loadMovies(…,
    /// snapshot:completion:)`).
    typealias Loader = (_ page: Int, _ filter: Filter, _ genre: NetworkManager.Genres,
                        _ snapshot: (([Item]) -> Void)?,
                        _ completion: @escaping ([Item]?, NSError?) -> Void) -> Void

    @Published private(set) var pager = CatalogPager<Item>(id: { $0.id })
    @Published private(set) var filter: Filter
    @Published private(set) var genre: NetworkManager.Genres = .all
    /// The poster at the top of the grid (`scrollPosition`): where the
    /// grid opens again when its section comes back. Not published:
    /// scrolling must not redraw the grid.
    var scrolledID: String?
    /// The grid's scroll view identity: a new one for another list (and a
    /// refreshed one), which opens at its top. Clearing `scrolledID` alone
    /// would not scroll: the view keeps its offset, only clamped to the
    /// skeleton's height.
    @Published private(set) var listID = 0
    /// The posters whose cells exist in that scroll view (`onAppear` /
    /// `onDisappear`), and when the last one asks for the next page. Not
    /// published.
    private var cells = LastPosterWatch()

    /// The filters offered, in menu order, and their names.
    let filters: [Filter]
    let filterTitle: (Filter) -> String
    /// The genres offered: the ones this catalogue's sources know
    /// (`NetworkManager.Genres.movies` / `.shows`).
    let genres: [NetworkManager.Genres]
    private let load: Loader
    /// The order a filter keeps the whole list in (nil: the source's).
    private let order: (Filter) -> ((Item, Item) -> Bool)?

    init(filter: Filter, filters: [Filter], filterTitle: @escaping (Filter) -> String, genres: [NetworkManager.Genres],
         order: @escaping (Filter) -> ((Item, Item) -> Bool)? = { _ in nil }, load: @escaping Loader) {
        self.filter = filter
        self.filters = filters
        self.filterTitle = filterTitle
        self.genres = genres
        self.order = order
        self.load = load
    }

    var items: [Item] { pager.items }

    /// The first page, the first time the grid shows.
    func loadIfNeeded() {
        if pager.isIdle { startOver() }
    }

    /// The next page (the grid's last poster appeared).
    func loadMore() {
        if let request = pager.next() { run(request) }
    }

    /// A poster's cell appeared in the scroll view `list` (the `listID` it
    /// was drawn for): the last one asks for the next page.
    func posterAppeared(_ id: String, in list: Int) {
        if cells.appeared(id, in: list, last: pager.items.last?.id) { loadMore() }
    }

    func posterDisappeared(_ id: String, in list: Int) {
        cells.disappeared(id, in: list)
    }

    /// After an answer: a last poster whose cell was already there (the
    /// network's first page in place of the saved one with the same titles,
    /// an A–Z page that left the last title in place) gets no new
    /// `onAppear`: the next page is asked now — a few times in a row at
    /// most (`LastPosterWatch`: an A–Z list went on to the end of the
    /// catalogue, page after page, while its last poster stayed on screen).
    private func loadMoreIfLastIsShown() {
        if cells.answered(last: pager.items.last?.id) { loadMore() }
    }

    /// Try Again: what failed, again — the page that is missing, or the
    /// refresh (the posters stay, as for ⌘R).
    func retry() {
        if let request = pager.retry() { run(request) }
    }

    /// ⌘R: the list from its first page. The posters stay until it lands;
    /// with nothing on screen to keep, the pager makes it a plain first load.
    func refresh() {
        guard !pager.isRefreshing else { return }
        // An explicit refresh: the first pages PopcornKit keeps on disk are
        // asked to the network again, however recent.
        PopcornKit.refreshCatalogs()
        run(pager.refresh())
    }

    /// The current filter and genre from their first page: the list
    /// empties, a page still on its way is dropped when it lands. A genre
    /// is filtered by the source page by page (the Top 100): an empty page
    /// is then not the end of the list.
    private func startOver() {
        run(pager.reset(filtered: genre != .all))
    }

    func setFilter(_ newFilter: Filter) {
        show(filter: newFilter, genre: genre)
    }

    func setGenre(_ newGenre: NetworkManager.Genres) {
        show(filter: filter, genre: newGenre)
    }

    /// Another list: emptied, back to the top, its first page asked for.
    func show(filter newFilter: Filter, genre newGenre: NetworkManager.Genres) {
        guard newFilter != filter || newGenre != genre else { return loadIfNeeded() }
        filter = newFilter
        genre = newGenre
        backToTop()
        startOver()
    }

    /// A new scroll view, at its top: none of its cells exists yet, and
    /// those of the one it replaces no longer count (a refreshed list asked
    /// for its second page at once when the end of the first was on screen
    /// before the refresh).
    private func backToTop() {
        scrolledID = nil
        listID += 1
        cells.start(list: listID)
    }

    #if DEBUG
    /// `-PTDebugTour scroll:<n>`: the n-th poster at the top of the grid.
    func debugScroll(toIndex index: Int) {
        guard pager.items.indices.contains(index) else { return }
        scrolledID = pager.items[index].id
        // `scrolledID` is not published: the grid reads it again now.
        objectWillChange.send()
    }

    /// `-PTDebugTour fail | failmore | empty`: a made-up answer to the next
    /// page (after emptying the list when `fromStart`), to show the states
    /// a healthy network never does.
    func debugAnswer(_ result: Result<[Item], NSError>, fromStart: Bool) {
        if let request = fromStart ? pager.reset() : pager.next() { pager.receive(result, for: request) }
    }
    #endif

    private func run(_ request: CatalogPager<Item>.Request) {
        let filter = self.filter
        // The first page of a new list: the one saved by an earlier load at
        // once (a launch paints the grid without waiting), then the
        // network's in its place. Not for a refresh: its list stays.
        let saved: (([Item]) -> Void)? = request.page == 1 && !request.isRefresh ? { [weak self] items in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pager.receiveSnapshot(items, for: request, arrange: self.arrangement(for: filter))
            }
        } : nil
        load(request.page, filter, genre, saved) { [weak self] items, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let result: Result<[Item], NSError>
                if let error { result = .failure(error) } else { result = .success(items ?? []) }
                // A page of titles already listed adds no poster: nothing
                // would ever scroll into view to ask for the next one.
                switch self.pager.receive(result, for: request, arrange: self.arrangement(for: filter)) {
                case .continueWith(let next):
                    self.run(next)
                case .applied:
                    // A refreshed list opens at its top, as another list does.
                    if request.isRefresh, case .success(let page) = result, !page.isEmpty { self.backToTop() }
                    self.loadMoreIfLastIsShown()
                case .stale:
                    break
                }
            }
        }
    }

    private func arrangement(for filter: Filter) -> (([Item]) -> [Item])? {
        order(filter).map { areInOrder in { (items: [Item]) in items.sorted(by: areInOrder) } }
    }
}

extension MacCatalogModel where Item == Movie, Filter == MovieManager.Filters {
    static func movies(filter: MovieManager.Filters = .trending) -> MacMoviesModel {
        MacMoviesModel(filter: filter, filters: MovieManager.Filters.array, filterTitle: { $0.string },
                       genres: NetworkManager.Genres.movies) { page, filter, genre, snapshot, completion in
            if let snapshot {
                PopcornKit.loadMovies(page, filterBy: filter, genre: genre, snapshot: snapshot, completion: completion)
            } else {
                PopcornKit.loadMovies(page, filterBy: filter, genre: genre, completion: completion)
            }
        }
    }
}

extension MacCatalogModel where Item == Show, Filter == ShowManager.Filters {
    static func shows(filter: ShowManager.Filters = .trending) -> MacShowsModel {
        MacShowsModel(filter: filter, filters: ShowManager.Filters.array, filterTitle: { $0.string },
                      genres: NetworkManager.Genres.shows,
                      order: { filter -> ((Show, Show) -> Bool)? in
                          // "A - Z": each page is an unordered batch, the list is kept sorted.
                          guard filter == .name else { return nil }
                          return { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                      }) { page, filter, genre, snapshot, completion in
            if let snapshot {
                PopcornKit.loadShows(page, filterBy: filter, genre: genre, snapshot: snapshot, completion: completion)
            } else {
                PopcornKit.loadShows(page, filterBy: filter, genre: genre, completion: completion)
            }
        }
    }
}

// MARK: - Catalogue grid

/// The Movies / Shows page: posters by pages on the Home's black and its
/// grid, the sort and genre menus and Refresh in the toolbar.
struct MacCatalogGridView<Item: MacCatalogItem, Filter: Hashable>: View {
    @ObservedObject var model: MacCatalogModel<Item, Filter>
    let title: Text
    /// Symbol of the "No results" state.
    let systemImage: String

    @State private var width = MacPosterGrid.defaultWidth

    var body: some View {
        let pager = model.pager
        let grid = MacPosterGrid(width: width)
        // The scroll view the cells below are made for: what they report
        // after another one took its place is not about the new list.
        let list = model.listID
        // A container of its own, not a Group: before the first load the
        // status draws nothing, and modifiers on nothing (`task`, the
        // toolbar) would never take effect.
        ZStack {
            if pager.items.isEmpty && !pager.isLoading {
                // Nothing to scroll: the status takes the page (as an
                // overlay of an empty scroll view it is given no height).
                MacGridStatus(error: pager.error, isEnded: !pager.hasMore, systemImage: systemImage) { model.retry() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    MacPageTitle(title: title, sideInset: grid.sideInset)
                    if pager.items.isEmpty {
                        MacPosterSkeleton(grid: grid)
                    } else {
                        LazyVGrid(columns: grid.columns, alignment: .leading, spacing: MacPosterGrid.rowSpacing) {
                            ForEach(pager.items, id: \.id) { item in
                                MacPosterLink(item: item, size: grid.cellSize)
                                    .onAppear { model.posterAppeared(item.id, in: list) }
                                    .onDisappear { model.posterDisappeared(item.id, in: list) }
                            }
                        }
                        .scrollTargetLayout()
                        // 4K on nearly every card tells nothing: not drawn then.
                        .environment(\.homeHiddenBadges, HomeListBadges.hidden(items: pager.items.prefix(40).map { MacGridCard.sourceItem($0) }))
                        .padding(.horizontal, grid.sideInset)
                        .padding(.top, 14)
                        .padding(.bottom, 28)
                        MacGridFooter(isLoading: pager.isLoading && !pager.isRefreshing, error: pager.error) { model.retry() }
                    }
                }
                // Where the grid was when its section was left (the model
                // outlives the view): the row of that poster is at the top again.
                .scrollPosition(id: Binding(get: { model.scrolledID }, set: { model.scrolledID = $0 }), anchor: .top)
                .id(list)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .macGridWidth($width)
        .macPageBackground()
        .navigationTitle(title)
        .modifier(MacNoBarTitle())
        .toolbar {
            ToolbarItemGroup {
                MacToolbarChoice(label: "Filter", current: model.filterTitle(model.filter),
                                 options: model.filters.map { ($0, model.filterTitle($0)) },
                                 selection: model.filter) { model.setFilter($0) }
                MacToolbarChoice(label: "Genre", current: model.genre.string,
                                 options: model.genres.map { ($0, $0.string) },
                                 selection: model.genre) { model.setGenre($0) }
                if pager.isRefreshing {
                    // In the button's place while the new first page loads.
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28)
                } else {
                    Button {
                        model.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help(Text("Refresh"))
                }
            }
        }
        .task { model.loadIfNeeded() }
    }
}

/// A sort or genre of a grid, in the toolbar: what is chosen, in white
/// semibold, its chevron right after it (not a pale menu with its
/// indicator far off), the choices in a menu with a tick.
struct MacToolbarChoice<Value: Hashable>: View {
    let label: LocalizedStringKey
    let current: String
    let options: [(Value, String)]
    let selection: Value
    let choose: (Value) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button {
                    choose(option.0)
                } label: {
                    if option.0 == selection {
                        Label(option.1, systemImage: "checkmark")
                    } else {
                        Text(verbatim: option.1)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: current)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(GlassPalette.primaryText)
            .padding(.horizontal, 6)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: current))
        .help(Text(label))
    }
}

// MARK: - Grid status

/// Load errors of the grids: The Pirate Bay's Top 100 (`PirateBayTop100`)
/// gets its own title and a hint, as the site is blocked on some networks.
enum MacGridError {
    static func title(for error: NSError) -> String {
        return error.domain == PirateBayTop100.errorDomain ? "Top 100 Unavailable".localized : "Error".localized
    }

    static func message(for error: NSError) -> String {
        return PirateBayTop100.message(for: error)
    }
}

/// An empty grid that is not loading: the load error with Try Again, or
/// "No results" for a list that came back empty (the Top 100 filtered by
/// a genre none of its titles has, say). An empty page for a grid not
/// asked for yet.
struct MacGridStatus: View {
    let error: NSError?
    /// The list is complete (and empty).
    let isEnded: Bool
    let systemImage: String
    let retry: () -> Void

    var body: some View {
        if let error {
            ContentUnavailableView {
                Label { Text(verbatim: MacGridError.title(for: error)) } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(verbatim: MacGridError.message(for: error))
            } actions: {
                Button("Try Again", action: retry)
                    .keyboardShortcut(.defaultAction)
            }
        } else if isEnded {
            ContentUnavailableView {
                Label { Text("No results") } icon: { Image(systemName: systemImage) }
            }
        } else {
            Color.clear
        }
    }
}

/// Under the posters: the next page loading, or the error of a page (or of
/// a refresh) that failed, with Try Again — the posters stay.
struct MacGridFooter: View {
    let isLoading: Bool
    let error: NSError?
    let retry: () -> Void

    var body: some View {
        if let error {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(verbatim: MacGridError.message(for: error))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Button("Try Again", action: retry)
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        } else if isLoading {
            ProgressView()
                .controlSize(.small)
                .padding(.bottom, 24)
        }
    }
}
