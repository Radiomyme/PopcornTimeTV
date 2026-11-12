

import SwiftUI
import PopcornKit

// MARK: - Movies

@MainActor
final class MacMoviesViewModel: ObservableObject {
    @Published var movies: [Movie] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var errorMessage: String?
    @Published var errorTitle: String?

    private var currentPage = 1
    private(set) var filter: MovieManager.Filters = .trending
    private(set) var genre: NetworkManager.Genres = .all
    /// Bumped by `reload`: a load started for an older list is ignored when
    /// it lands, and never keeps the grid "loading".
    private var generation = 0

    init() {
        #if DEBUG
        MacDebugHooks.applySourceSwitches()
        if let filter = MacDebugHooks.movieFilter { self.filter = filter }
        #endif
    }

    func setFilter(_ newFilter: MovieManager.Filters) {
        filter = newFilter
        reload()
    }

    func setGenre(_ newGenre: NetworkManager.Genres) {
        genre = newGenre
        reload()
    }

    func reload() {
        generation += 1
        currentPage = 1
        movies = []
        hasMore = true
        errorMessage = nil
        errorTitle = nil
        isLoading = false
        loadMore()
    }

    func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        let page = currentPage
        let captured = (filter, genre)
        let generation = self.generation
        PopcornKit.loadMovies(page, filterBy: captured.0, genre: captured.1) { [weak self] results, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                self.isLoading = false
                if let error = error {
                    self.errorTitle = MacGridError.title(for: error)
                    self.errorMessage = MacGridError.message(for: error)
                    self.hasMore = false
                    return
                }
                let new = results ?? []
                if new.isEmpty { self.hasMore = false } else {
                    self.movies.append(contentsOf: new.filter { incoming in
                        !self.movies.contains(where: { $0.id == incoming.id })
                    })
                    self.currentPage = page + 1
                }
            }
        }
    }
}

struct MacMoviesGridView: View {
    @StateObject private var viewModel = MacMoviesViewModel()

    var body: some View {
        ScrollView {
            LazyVGrid(columns: MacPosterGrid.columns, spacing: 22) {
                ForEach(viewModel.movies, id: \.id) { movie in
                    NavigationLink(value: movie) {
                        MacPosterCard(title: movie.title, subtitle: movie.year, imageURL: movie.smallCoverImage)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if movie.id == viewModel.movies.last?.id { viewModel.loadMore() }
                    }
                }
            }
            .padding(20)
            if viewModel.isLoading { ProgressView().padding() }
            MacGridStatus(isEmpty: viewModel.movies.isEmpty, isLoading: viewModel.isLoading,
                          hasMore: viewModel.hasMore, errorTitle: viewModel.errorTitle,
                          errorMessage: viewModel.errorMessage, systemImage: "film") { viewModel.reload() }
        }
        .navigationTitle(Text("Movies"))
        .toolbar {
            Picker("Filter", selection: Binding(get: { viewModel.filter },
                                                set: { viewModel.setFilter($0) })) {
                Text("Trending").tag(MovieManager.Filters.trending)
                Text("Top 100").tag(MovieManager.Filters.top100)
                Text("Popular").tag(MovieManager.Filters.popularity)
                Text("Top Rated").tag(MovieManager.Filters.rating)
                Text("Recently Added").tag(MovieManager.Filters.date)
            }
            .pickerStyle(.menu)
            Picker("Genre", selection: Binding(get: { viewModel.genre },
                                               set: { viewModel.setGenre($0) })) {
                ForEach(NetworkManager.Genres.array, id: \.self) { genre in
                    Text(genre.string).tag(genre)
                }
            }
            .pickerStyle(.menu)
        }
        .task { if viewModel.movies.isEmpty { viewModel.loadMore() } }
    }
}

// MARK: - Shows

@MainActor
final class MacShowsViewModel: ObservableObject {
    @Published var shows: [Show] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var errorMessage: String?
    @Published var errorTitle: String?

    private var currentPage = 1
    private(set) var filter: ShowManager.Filters = .trending
    private(set) var genre: ShowManager.Genres = .all
    /// Bumped by `reload`: a load started for an older list is ignored when
    /// it lands, and never keeps the grid "loading".
    private var generation = 0

    init() {
        #if DEBUG
        MacDebugHooks.applySourceSwitches()
        if let filter = MacDebugHooks.showFilter { self.filter = filter }
        #endif
    }

    func setFilter(_ newFilter: ShowManager.Filters) {
        filter = newFilter
        reload()
    }

    func setGenre(_ newGenre: ShowManager.Genres) {
        genre = newGenre
        reload()
    }

    func reload() {
        generation += 1
        currentPage = 1
        shows = []
        hasMore = true
        errorMessage = nil
        errorTitle = nil
        isLoading = false
        loadMore()
    }

    func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        let page = currentPage
        let captured = (filter, genre)
        let generation = self.generation
        PopcornKit.loadShows(page, filterBy: captured.0, genre: captured.1) { [weak self] results, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                self.isLoading = false
                if let error = error {
                    self.errorTitle = MacGridError.title(for: error)
                    self.errorMessage = MacGridError.message(for: error)
                    self.hasMore = false
                    return
                }
                let new = results ?? []
                if new.isEmpty { self.hasMore = false } else {
                    self.shows.append(contentsOf: new.filter { incoming in
                        !self.shows.contains(where: { $0.id == incoming.id })
                    })
                    // "A - Z": each page is an unordered batch, re-sort the list.
                    if captured.0 == .name {
                        self.shows.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    }
                    self.currentPage = page + 1
                }
            }
        }
    }
}

struct MacShowsGridView: View {
    @StateObject private var viewModel = MacShowsViewModel()

    var body: some View {
        ScrollView {
            LazyVGrid(columns: MacPosterGrid.columns, spacing: 22) {
                ForEach(viewModel.shows, id: \.id) { show in
                    NavigationLink(value: show) {
                        MacPosterCard(title: show.title, subtitle: show.year, imageURL: show.smallCoverImage)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if show.id == viewModel.shows.last?.id { viewModel.loadMore() }
                    }
                }
            }
            .padding(20)
            if viewModel.isLoading { ProgressView().padding() }
            MacGridStatus(isEmpty: viewModel.shows.isEmpty, isLoading: viewModel.isLoading,
                          hasMore: viewModel.hasMore, errorTitle: viewModel.errorTitle,
                          errorMessage: viewModel.errorMessage, systemImage: "tv") { viewModel.reload() }
        }
        .navigationTitle(Text("Shows"))
        .toolbar {
            Picker("Filter", selection: Binding(get: { viewModel.filter },
                                                set: { viewModel.setFilter($0) })) {
                Text("Trending").tag(ShowManager.Filters.trending)
                Text("Top 100").tag(ShowManager.Filters.top100)
                Text("Popular").tag(ShowManager.Filters.popularity)
                Text("Top Rated").tag(ShowManager.Filters.rating)
                Text("Recently Added").tag(ShowManager.Filters.date)
                Text("A - Z").tag(ShowManager.Filters.name)
            }
            .pickerStyle(.menu)
            Picker("Genre", selection: Binding(get: { viewModel.genre },
                                               set: { viewModel.setGenre($0) })) {
                ForEach(NetworkManager.Genres.array, id: \.self) { genre in
                    Text(genre.string).tag(genre)
                }
            }
            .pickerStyle(.menu)
        }
        .task { if viewModel.shows.isEmpty { viewModel.loadMore() } }
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

/// Under a grid: the load error (a full message with Try Again while the
/// grid is empty, a line under the posters otherwise), or "No results" for a
/// list that came back empty (the Top 100 filtered by a genre none of its
/// titles has, say).
struct MacGridStatus: View {
    let isEmpty: Bool
    let isLoading: Bool
    let hasMore: Bool
    let errorTitle: String?
    let errorMessage: String?
    let systemImage: String
    let retry: () -> Void

    var body: some View {
        if let errorMessage {
            if isEmpty {
                ContentUnavailableView {
                    Label { Text(verbatim: errorTitle ?? "Error".localized) } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                } description: {
                    Text(verbatim: errorMessage)
                } actions: {
                    Button("Try Again", action: retry)
                }
                .padding(.top, 60)
            } else {
                Text(verbatim: errorMessage).foregroundStyle(.secondary).padding()
            }
        } else if isEmpty && !isLoading && !hasMore {
            ContentUnavailableView {
                Label { Text("No results") } icon: { Image(systemName: systemImage) }
            }
            .padding(.top, 60)
        }
    }
}

// MARK: - Search

struct MacSearchView: View {
    @State private var query = ""
    @State private var movies: [Movie] = []
    @State private var shows: [Show] = []
    @State private var searching = false

    var body: some View {
        ScrollView {
            if searching { ProgressView().padding() }
            if !movies.isEmpty {
                sectionHeader(Text("Movies"))
                LazyVGrid(columns: MacPosterGrid.columns, spacing: 22) {
                    ForEach(movies, id: \.id) { movie in
                        NavigationLink(value: movie) {
                            MacPosterCard(title: movie.title, subtitle: movie.year, imageURL: movie.smallCoverImage)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20)
            }
            if !shows.isEmpty {
                sectionHeader(Text("Shows"))
                LazyVGrid(columns: MacPosterGrid.columns, spacing: 22) {
                    ForEach(shows, id: \.id) { show in
                        NavigationLink(value: show) {
                            MacPosterCard(title: show.title, subtitle: show.year, imageURL: show.smallCoverImage)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20)
            }
        }
        .navigationTitle(Text("Search"))
        .searchable(text: $query, prompt: Text("Movie or show title"))
        .onSubmit(of: .search) { performSearch() }
    }

    private func sectionHeader(_ title: Text) -> some View {
        HStack {
            title.font(.title3.weight(.semibold))
            Spacer()
        }.padding(.horizontal, 20).padding(.top, 14)
    }

    private func performSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        movies = []; shows = []
        let group = DispatchGroup()
        group.enter()
        PopcornKit.loadMovies(searchTerm: q) { results, _ in
            DispatchQueue.main.async { movies = results ?? []; group.leave() }
        }
        group.enter()
        PopcornKit.loadShows(searchTerm: q) { results, _ in
            DispatchQueue.main.async { shows = results ?? []; group.leave() }
        }
        group.notify(queue: .main) { searching = false }
    }
}

// MARK: - Watchlist

/// Movies and shows saved with the detail page's Watchlist button
/// (WatchlistManager, synced with Trakt when signed in). Read again every
/// time the section shows, e.g. back from a page where one was removed.
struct MacWatchlistView: View {
    @State private var movies: [Movie] = []
    @State private var shows: [Show] = []
    /// Pages pushed over the grid (MacRootView's stack).
    @Environment(\.macStackDepth) private var stackDepth

    var body: some View {
        Group {
            if movies.isEmpty && shows.isEmpty {
                ContentUnavailableView {
                    Label { Text("Watchlist Empty") } icon: { Image(systemName: "bookmark") }
                } description: {
                    Text("Try adding movies or shows to your watchlist.")
                }
            } else {
                ScrollView {
                    if !movies.isEmpty {
                        sectionHeader(Text("Movies"))
                        LazyVGrid(columns: MacPosterGrid.columns, spacing: 22) {
                            ForEach(movies, id: \.id) { movie in
                                NavigationLink(value: movie) {
                                    MacPosterCard(title: movie.title, subtitle: movie.year, imageURL: movie.smallCoverImage)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    if !shows.isEmpty {
                        sectionHeader(Text("Shows"))
                        LazyVGrid(columns: MacPosterGrid.columns, spacing: 22) {
                            ForEach(shows, id: \.id) { show in
                                NavigationLink(value: show) {
                                    MacPosterCard(title: show.title, subtitle: show.year, imageURL: show.smallCoverImage)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .navigationTitle(Text("Watchlist"))
        .onAppear(perform: reload)
        // Back to the grid: no onAppear then (the stack keeps it in place).
        .onChange(of: stackDepth) { _, depth in
            if depth == 0 { reload() }
        }
    }

    private func sectionHeader(_ title: Text) -> some View {
        HStack {
            title.font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    /// The local lists now; Trakt's when it answers (signed in only).
    private func reload() {
        movies = unique(WatchlistManager<Movie>.movie.getWatchlist { updated in
            DispatchQueue.main.async { movies = unique(updated) }
        })
        shows = unique(WatchlistManager<Show>.show.getWatchlist { updated in
            DispatchQueue.main.async { shows = unique(updated) }
        })
    }

    /// One entry per id (the list is append-only JSON).
    private func unique<T: Media>(_ items: [T]) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
