

import SwiftUI
import PopcornKit

@MainActor
final class ShowsViewModel: ObservableObject {
    @Published var shows: [Show] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var errorMessage: String?

    private var currentPage = 1

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
        PopcornKit.loadShows(page,
                             filterBy: .trending,
                             genre: .all) { [weak self] results, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                if let error = error { self.errorMessage = error.localizedDescription; self.hasMore = false; return }
                let new = results ?? []
                if new.isEmpty {
                    self.hasMore = false
                } else {
                    self.shows.append(contentsOf: new.filter { incoming in
                        !self.shows.contains(where: { $0.id == incoming.id })
                    })
                    self.currentPage += 1
                }
            }
        }
    }
}

struct ShowsGridView: View {
    @StateObject private var viewModel = ShowsViewModel()

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
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
