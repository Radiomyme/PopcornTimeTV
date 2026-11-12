

import SwiftUI
import PopcornKit

@MainActor
final class MoviesViewModel: ObservableObject {
    @Published var movies: [Movie] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var errorMessage: String?

    private var currentPage = 1
    private(set) var filter: MovieManager.Filters = .trending
    private(set) var genre:  NetworkManager.Genres = .all
    /// Bumped by `reload`: a load started for an older list is ignored when
    /// it lands (a filter or genre picked while it ran), and never keeps the
    /// grid "loading".
    private var generation = 0

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
        isLoading = false
        loadMore()
    }

    func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        let page = currentPage
        let captured = (filter, genre)
        let generation = self.generation
        PopcornKit.loadMovies(page,
                              filterBy: captured.0,
                              genre: captured.1) { [weak self] results, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                self.isLoading = false
                if let error = error { self.errorMessage = GridError.message(for: error); self.hasMore = false; return }
                let new = results ?? []
                if new.isEmpty {
                    self.hasMore = false
                } else {
                    self.movies.append(contentsOf: new.filter { incoming in
                        !self.movies.contains(where: { $0.id == incoming.id })
                    })
                    self.currentPage += 1
                }
            }
        }
    }
}

/// The message of a grid's load error: The Pirate Bay's Top 100
/// (`PirateBayTop100`) adds a hint, as the site is blocked on some networks.
enum GridError {
    static func message(for error: NSError) -> String {
        return PirateBayTop100.message(for: error)
    }
}

struct MoviesGridView: View {
    @StateObject private var viewModel = MoviesViewModel()
    @State private var showingFilters = false

    private let columns = PosterGrid.columns

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: PosterGrid.lineSpacing) {
                ForEach(viewModel.movies, id: \.id) { movie in
                    NavigationLink(value: movie) {
                        PosterCard(title: movie.title,
                                   subtitle: movie.year,
                                   imageURL: movie.smallCoverImage)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if movie.id == viewModel.movies.last?.id {
                            viewModel.loadMore()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if viewModel.isLoading {
                ProgressView().padding(.vertical, 24)
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView("Erreur",
                                        systemImage: "exclamationmark.triangle",
                                        description: Text(error))
                    .padding(.top, 32)
            } else if viewModel.movies.isEmpty {
                ContentUnavailableView("Aucun film",
                                        systemImage: "film",
                                        description: Text("La grille se remplira au chargement."))
                    .padding(.top, 32)
            }
        }
        .navigationDestination(for: Movie.self) { movie in
            MediaDetailView(media: movie)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Tri", selection: Binding(get: { viewModel.filter },
                                                     set: { viewModel.setFilter($0) })) {
                        ForEach(MovieManager.Filters.array, id: \.rawValue) { filter in
                            Text(filter.string).tag(filter)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .task {
            if viewModel.movies.isEmpty { viewModel.reload() }
        }
        .refreshable { viewModel.reload() }
    }
}

#Preview {
    NavigationStack { MoviesGridView() }
        .preferredColorScheme(.dark)
}
