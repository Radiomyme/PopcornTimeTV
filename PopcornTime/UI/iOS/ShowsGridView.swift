

import SwiftUI
import PopcornKit

@MainActor
final class ShowsViewModel: ObservableObject {
    @Published var shows: [Show] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var errorMessage: String?

    private var currentPage = 1
    private(set) var filter: ShowManager.Filters = .trending
    /// Bumped by `reload`: a load started for an older list is ignored when
    /// it lands, and never keeps the grid "loading".
    private var generation = 0

    func setFilter(_ newFilter: ShowManager.Filters) {
        filter = newFilter
        reload()
    }

    func reload() {
        generation += 1
        currentPage = 1
        shows = []
        hasMore = true
        errorMessage = nil
        isLoading = false
        loadMore()
    }

    func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        let page = currentPage
        let captured = filter
        let generation = self.generation
        PopcornKit.loadShows(page,
                             filterBy: captured,
                             genre: .all) { [weak self] results, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                self.isLoading = false
                if let error = error { self.errorMessage = GridError.message(for: error); self.hasMore = false; return }
                let new = results ?? []
                if new.isEmpty {
                    self.hasMore = false
                } else {
                    self.shows.append(contentsOf: new.filter { incoming in
                        !self.shows.contains(where: { $0.id == incoming.id })
                    })
                    // Each page is an unordered batch: "A - Z" re-sorts the
                    // whole list so it stays alphabetical as pages arrive.
                    if captured == .name {
                        self.shows.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    }
                    self.currentPage += 1
                }
            }
        }
    }
}

struct ShowsGridView: View {
    @StateObject private var viewModel = ShowsViewModel()

    private let columns = PosterGrid.columns

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: PosterGrid.lineSpacing) {
                ForEach(viewModel.shows, id: \.id) { show in
                    NavigationLink(value: show) {
                        PosterCard(title: show.title,
                                   subtitle: show.year,
                                   imageURL: show.smallCoverImage)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if show.id == viewModel.shows.last?.id {
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
            } else if viewModel.shows.isEmpty {
                ContentUnavailableView("Aucune série",
                                        systemImage: "tv",
                                        description: Text("La grille se remplira au chargement."))
                    .padding(.top, 32)
            }
        }
        .navigationDestination(for: Show.self) { show in
            MediaDetailView(media: show)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Tri", selection: Binding(get: { viewModel.filter },
                                                     set: { viewModel.setFilter($0) })) {
                        ForEach(ShowManager.Filters.array, id: \.rawValue) { filter in
                            Text(filter.string).tag(filter)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .task {
            if viewModel.shows.isEmpty { viewModel.reload() }
        }
        .refreshable { viewModel.reload() }
    }
}

#Preview {
    NavigationStack { ShowsGridView() }
        .preferredColorScheme(.dark)
}
