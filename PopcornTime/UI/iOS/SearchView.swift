

import SwiftUI
import PopcornKit

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query   = ""
    @Published var movies: [Movie] = []
    @Published var shows:  [Show]  = []
    @Published var loading = false

    private var searchTask: Task<Void, Never>?

    func runSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            movies = []; shows = []
            return
        }
        loading = true
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self = self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        PopcornKit.loadMovies(searchTerm: q) { results, _ in
                            DispatchQueue.main.async {
                                self.movies = results ?? []
                                cont.resume()
                            }
                        }
                    }
                }
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        PopcornKit.loadShows(searchTerm: q) { results, _ in
                            DispatchQueue.main.async {
                                self.shows = results ?? []
                                cont.resume()
                            }
                        }
                    }
                }
            }
            await MainActor.run { self.loading = false }
        }
        searchTask = task
    }
}

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !viewModel.movies.isEmpty {
                    section(title: "Films") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(viewModel.movies, id: \.id) { movie in
                                NavigationLink(value: movie) {
                                    PosterCard(title: movie.title,
                                               subtitle: movie.year,
                                               imageURL: movie.smallCoverImage)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if !viewModel.shows.isEmpty {
                    section(title: "Séries") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(viewModel.shows, id: \.id) { show in
                                NavigationLink(value: show) {
                                    PosterCard(title: show.title,
                                               subtitle: show.year,
                                               imageURL: show.smallCoverImage)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if viewModel.loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                } else if viewModel.movies.isEmpty && viewModel.shows.isEmpty && !viewModel.query.isEmpty {
                    ContentUnavailableView("Aucun résultat",
                                            systemImage: "magnifyingglass",
                                            description: Text("Aucun film ou série trouvé pour « \(viewModel.query) »."))
                        .padding(.top, 32)
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationDestination(for: Movie.self) { MediaDetailView(media: $0) }
        .navigationDestination(for: Show.self)  { MediaDetailView(media: $0) }
        .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Films et séries")
        .onChange(of: viewModel.query) { _, _ in viewModel.runSearch() }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            content()
        }
    }
}

#Preview {
    NavigationStack { SearchView() }
        .preferredColorScheme(.dark)
}
