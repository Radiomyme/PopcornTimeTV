

import SwiftUI
import PopcornKit

// MARK: - Movies

@MainActor
final class MacMoviesViewModel: ObservableObject {
    @Published var movies: [Movie] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var errorMessage: String?

    private var currentPage = 1
    private(set) var filter: MovieManager.Filters = .trending
    private(set) var genre: NetworkManager.Genres = .all

    func setFilter(_ newFilter: MovieManager.Filters) {
        filter = newFilter
        reload()
    }

    func setGenre(_ newGenre: NetworkManager.Genres) {
        genre = newGenre
        reload()
    }

    func reload() {
        currentPage = 1
        movies = []
        hasMore = true
        errorMessage = nil
        loadMore()
    }

    func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        let page = currentPage
        let captured = (filter, genre)
        PopcornKit.loadMovies(page, filterBy: captured.0, genre: captured.1) { [weak self] results, error in
            DispatchQueue.main.async {
                guard let self = self, self.filter == captured.0, self.genre == captured.1 else { return }
                self.isLoading = false
                if let error = error { self.errorMessage = error.localizedDescription; self.hasMore = false; return }
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
            if let message = viewModel.errorMessage {
                Text(message).foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle("Films")
        .toolbar {
            Picker("Filtre", selection: Binding(get: { viewModel.filter },
                                                set: { viewModel.setFilter($0) })) {
                Text("Tendances").tag(MovieManager.Filters.trending)
                Text("Populaires").tag(MovieManager.Filters.popularity)
                Text("Mieux notés").tag(MovieManager.Filters.rating)
                Text("Récents").tag(MovieManager.Filters.date)
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

    private var currentPage = 1
    private(set) var filter: ShowManager.Filters = .trending
    private(set) var genre: ShowManager.Genres = .all

    func setFilter(_ newFilter: ShowManager.Filters) {
        filter = newFilter
        reload()
    }

    func setGenre(_ newGenre: ShowManager.Genres) {
        genre = newGenre
        reload()
    }

    func reload() {
        currentPage = 1
        shows = []
        hasMore = true
        errorMessage = nil
        loadMore()
    }

    func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        let page = currentPage
        let captured = (filter, genre)
        PopcornKit.loadShows(page, filterBy: captured.0, genre: captured.1) { [weak self] results, error in
            DispatchQueue.main.async {
                guard let self = self, self.filter == captured.0, self.genre == captured.1 else { return }
                self.isLoading = false
                if let error = error { self.errorMessage = error.localizedDescription; self.hasMore = false; return }
                let new = results ?? []
                if new.isEmpty { self.hasMore = false } else {
                    self.shows.append(contentsOf: new.filter { incoming in
                        !self.shows.contains(where: { $0.id == incoming.id })
                    })
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
            if let message = viewModel.errorMessage {
                Text(message).foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle("Séries")
        .toolbar {
            Picker("Filtre", selection: Binding(get: { viewModel.filter },
                                                set: { viewModel.setFilter($0) })) {
                Text("Tendances").tag(ShowManager.Filters.trending)
                Text("Populaires").tag(ShowManager.Filters.popularity)
                Text("Mieux notées").tag(ShowManager.Filters.rating)
                Text("Récentes").tag(ShowManager.Filters.date)
                Text("A–Z").tag(ShowManager.Filters.name)
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
                sectionHeader("Films")
                LazyVGrid(columns: MacPosterGrid.columns, spacing: 22) {
                    ForEach(movies, id: \.id) { movie in
                        NavigationLink(value: movie) {
                            MacPosterCard(title: movie.title, subtitle: movie.year, imageURL: movie.smallCoverImage)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20)
            }
            if !shows.isEmpty {
                sectionHeader("Séries")
                LazyVGrid(columns: MacPosterGrid.columns, spacing: 22) {
                    ForEach(shows, id: \.id) { show in
                        NavigationLink(value: show) {
                            MacPosterCard(title: show.title, subtitle: show.year, imageURL: show.smallCoverImage)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20)
            }
        }
        .navigationTitle("Recherche")
        .searchable(text: $query, prompt: "Titre du film ou de la série")
        .onSubmit(of: .search) { performSearch() }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.title3.weight(.semibold))
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
