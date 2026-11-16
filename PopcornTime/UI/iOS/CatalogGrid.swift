

import SwiftUI
import PopcornKit

/// What the Movies and Shows grids need from a title.
protocol CatalogItem: Media, Hashable {
    var year: String { get }
    /// The genres its grid offers: the ones its sources know, in each
    /// source's own vocabulary (`NetworkManager.Genres.movies` / `.shows`).
    static var catalogGenres: [NetworkManager.Genres] { get }
}

extension Movie: CatalogItem {
    static var catalogGenres: [NetworkManager.Genres] { NetworkManager.Genres.movies }
}

extension Show: CatalogItem {
    static var catalogGenres: [NetworkManager.Genres] { NetworkManager.Genres.shows }
}

/// The sort menu of a grid (`MovieManager.Filters`, `ShowManager.Filters`).
protocol CatalogFilter: Hashable {
    static var array: [Self] { get }
    /// Localized name.
    var string: String { get }
}

extension MovieManager.Filters: CatalogFilter {}
extension ShowManager.Filters: CatalogFilter {}

/// The message of a grid's load error: The Pirate Bay's Top 100
/// (`PirateBayTop100`) adds a hint, as the site is blocked on some networks.
enum GridError {
    static func message(for error: NSError) -> String {
        return PirateBayTop100.message(for: error)
    }
}

/// One catalogue grid's state: the sort, the genre and the pages. The paging
/// rules are `CatalogPager`'s (PopcornKit, unit-tested); this class runs the
/// requests it hands out and gives it the answers.
@MainActor
final class CatalogGridModel<Item: CatalogItem, Filter: CatalogFilter>: ObservableObject {
    /// Loads a page. `snapshot` (only for the first page of a new list): the
    /// first page saved by an earlier load, to show while the network's is
    /// on its way (the `snapshot:` loads of PopcornKit); nil: the answer is
    /// the network's list, or the saved one only when the network fails.
    typealias Loader = (_ page: Int, _ filter: Filter, _ genre: NetworkManager.Genres,
                        _ snapshot: (([Item]) -> Void)?,
                        _ completion: @escaping ([Item]?, NSError?) -> Void) -> Void

    @Published private(set) var pager = CatalogPager<Item> { $0.id }
    @Published private(set) var filter: Filter
    @Published private(set) var genre: NetworkManager.Genres

    private let load: Loader
    /// The order of the whole list under a sort the source cannot apply
    /// across pages ("A - Z"), nil otherwise.
    private let arrange: (Filter) -> (([Item]) -> [Item])?

    init(filter: Filter, genre: NetworkManager.Genres = .all,
         arrange: @escaping (Filter) -> (([Item]) -> [Item])? = { _ in nil },
         load: @escaping Loader) {
        self.filter = filter
        self.genre = genre
        self.arrange = arrange
        self.load = load
    }

    /// The first page, once (the grid appeared).
    func start() {
        if pager.isIdle { reload() }
    }

    func select(filter newFilter: Filter) {
        guard newFilter != filter else { return }
        filter = newFilter
        reload()
    }

    func select(genre newGenre: NetworkManager.Genres) {
        guard newGenre != genre else { return }
        genre = newGenre
        reload()
    }

    /// A new list: the grid empties and shows its placeholders.
    func reload() {
        run(pager.reset(filtered: genre != .all))
    }

    func loadMore() {
        if let request = pager.next() { run(request) }
    }

    func retry() {
        if let request = pager.retry() { run(request) }
    }

    /// Pull to refresh: returns when the new first page has arrived, and the
    /// grid keeps its posters until then.
    func refresh() async {
        // An explicit refresh: the first pages PopcornKit keeps on disk are
        // asked to the network again, however recent (without this a list
        // saved a moment ago is the answer, and nothing is refreshed).
        PopcornKit.refreshCatalogs()
        let request = pager.refresh()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            run(request) {
                // Once, whatever the source does with its completion.
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
        }
    }

    private func run(_ request: CatalogPager<Item>.Request, finished: (() -> Void)? = nil) {
        let filter = self.filter
        // A new list's first page: the saved one is painted at once (a
        // launch, a sort picked again), then replaced by the network's. Not
        // for a refresh: the grid already shows a list, the network's is
        // the answer it waits for.
        let snapshot: (([Item]) -> Void)? = request.page == 1 && !request.isRefresh ? { [weak self] items in
            // After the main queue's turn, as the completion: never after it.
            DispatchQueue.main.async {
                guard let self else { return }
                self.pager.receiveSnapshot(items, for: request, arrange: self.arrange(filter))
            }
        } : nil
        load(request.page, filter, genre, snapshot) { [weak self] items, error in
            DispatchQueue.main.async {
                defer { finished?() }
                guard let self else { return }
                // A failure is no list and an error; anything else is a page.
                let result: Result<[Item], NSError>
                if items == nil, let error { result = .failure(error) } else { result = .success(items ?? []) }
                let outcome = self.pager.receive(result, for: request, arrange: self.arrange(filter))
                if case .continueWith(let next) = outcome { self.run(next) }
            }
        }
    }
}

/// The Movies / Shows grid: posters, the sort and genre menu, pull to
/// refresh, and the loading, empty and error states.
struct CatalogGridView<Item: CatalogItem, Filter: CatalogFilter>: View {
    @ObservedObject var model: CatalogGridModel<Item, Filter>
    let title: LocalizedStringKey
    /// A tab's first screen (large title, the Settings gear), not a grid
    /// pushed by a `CatalogRoute`.
    let isRoot: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        PosterGridReader { metrics in
            ScrollView {
                // A pushed grid ("See All", a genre) on an iPad says what it
                // lists once: in the navigation bar, not again here.
                if isRoot, horizontalSizeClass == .regular {
                    Text(verbatim: subtitle)
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, metrics.sideInset)
                        .padding(.top, 8)
                }
                if model.pager.items.isEmpty {
                    emptyContent(metrics)
                } else {
                    grid(metrics)
                    footer
                }
            }
            .scrollTopShade()
        }
        .navigationTitle(isRoot ? Text(title) : Text(verbatim: subtitle))
        .navigationSubtitle(isRoot ? Text(verbatim: subtitle) : Text(verbatim: ""))
        .navigationBarTitleDisplayMode(isRoot ? .automatic : .large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
            if isRoot {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                RootToolbar()
            }
        }
        .homeFactsFeed()
        .task { model.start() }
        .refreshable { await model.refresh() }
    }

    /// "Trending" or "Trending · Action": what the grid lists.
    private var subtitle: String {
        model.genre == .all ? model.filter.string : "\(model.filter.string) · \(model.genre.string)"
    }

    // MARK: Grid

    private func grid(_ metrics: PosterGrid) -> some View {
        LazyVGrid(columns: metrics.columns, spacing: PosterGrid.lineSpacing) {
            ForEach(model.pager.items, id: \.id) { item in
                NavigationLink(value: item) {
                    PosterCard(media: item, size: metrics.cellSize)
                }
                .buttonStyle(HomeCardButtonStyle())
                .onAppear { loadMoreIfNear(item) }
            }
        }
        .padding(.horizontal, metrics.sideInset)
        .padding(.top, 8)
        .environment(\.homeHiddenBadges, HomeListBadges.hidden(items: model.pager.items.map { GridCard.item($0) }))
        // A refresh keeps the posters; they dim until the new page arrives.
        .opacity(model.pager.isRefreshing ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.2), value: model.pager.isRefreshing)
    }

    /// The next page starts loading a few rows before the end.
    private func loadMoreIfNear(_ item: Item) {
        guard model.pager.items.suffix(PosterGrid.preloadDistance).contains(where: { $0.id == item.id }) else { return }
        model.loadMore()
    }

    /// Under the posters: the next page loading, or why it did not come.
    @ViewBuilder
    private var footer: some View {
        if let error = model.pager.error.map(GridError.message(for:)) {
            VStack(spacing: 10) {
                Text(verbatim: error.isEmpty ? "Please check your internet connection and try again.".localized : error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { model.retry() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        } else if model.pager.isLoading && !model.pager.isRefreshing {
            ProgressView().padding(.vertical, 24)
        }
    }

    // MARK: Nothing to list

    @ViewBuilder
    private func emptyContent(_ metrics: PosterGrid) -> some View {
        if let error = model.pager.error.map(GridError.message(for:)) {
            ContentUnavailableView {
                Label("Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error.isEmpty ? "Please check your internet connection and try again.".localized : error)
            } actions: {
                Button("Try Again") { model.retry() }
                    .buttonStyle(.borderedProminent)
            }
            .containerRelativeFrame(.vertical) { height, _ in height * 0.7 }
        } else if model.pager.isLoading || model.pager.isIdle {
            placeholders(metrics)
        } else {
            ContentUnavailableView {
                Label("No results", systemImage: "film.stack")
            } description: {
                Text("Nothing to show for this selection.")
            } actions: {
                if model.genre != .all {
                    Button("All Genres") { model.select(genre: .all) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Try Again") { model.reload() }
                        .buttonStyle(.bordered)
                }
            }
            .containerRelativeFrame(.vertical) { height, _ in height * 0.7 }
        }
    }

    /// The first page is loading: the grid's shape, without titles.
    private func placeholders(_ metrics: PosterGrid) -> some View {
        LazyVGrid(columns: metrics.columns, spacing: PosterGrid.lineSpacing) {
            ForEach(0..<(metrics.columnCount * 4), id: \.self) { index in
                PosterCard.placeholder(index, size: metrics.cellSize)
            }
        }
        .padding(.horizontal, metrics.sideInset)
        .padding(.top, 8)
        .accessibilityHidden(true)
    }

    // MARK: Sort and genre

    private var filterMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(get: { model.filter }, set: { model.select(filter: $0) })) {
                ForEach(Filter.array, id: \.self) { filter in
                    Text(verbatim: filter.string).tag(filter)
                }
            }
            Picker("Genre", selection: Binding(get: { model.genre }, set: { model.select(genre: $0) })) {
                ForEach(Item.catalogGenres, id: \.self) { genre in
                    Text(verbatim: genre.string).tag(genre)
                }
            }
            .pickerStyle(.menu)
        } label: {
            // Filled while a genre narrows the grid.
            Label("Filter", systemImage: model.genre == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("Catalog.Filter")
    }
}
