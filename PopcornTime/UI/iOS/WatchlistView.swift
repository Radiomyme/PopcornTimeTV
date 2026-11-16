

import SwiftUI
import PopcornKit

/// "Ma liste": the movies and shows saved with the detail page's Watchlist
/// button (`WatchlistManager`). Read again every time the screen shows —
/// back from a page where a title was added or removed, or from another tab.
struct WatchlistView: View {
    @State private var movies: [Movie] = []
    @State private var shows: [Show] = []

    var body: some View {
        PosterGridReader { metrics in
        ScrollView {
            if movies.isEmpty && shows.isEmpty {
                ContentUnavailableView {
                    Label("Watchlist Empty", systemImage: "bookmark")
                } description: {
                    Text("Try adding movies or shows to your watchlist.")
                }
                .containerRelativeFrame(.vertical) { height, _ in height * 0.7 }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    if !movies.isEmpty {
                        section("Movies", items: movies, metrics: metrics) { movie in
                            WatchlistManager<Movie>.movie.remove(movie)
                        }
                    }
                    if !shows.isEmpty {
                        section("Shows", items: shows, metrics: metrics) { show in
                            WatchlistManager<Show>.show.remove(show)
                        }
                    }
                }
                .padding(.horizontal, metrics.sideInset)
                .padding(.top, 8)
            }
        }
        .scrollTopShade()
        }
        .navigationTitle("Watchlist")
        .toolbar { RootToolbar() }
        .homeFactsFeed()
        .onAppear(perform: reload)
    }

    private func section<Item: CatalogItem>(_ title: LocalizedStringKey, items: [Item], metrics: PosterGrid,
                                            remove: @escaping (Item) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            // Leading-aligned columns: one title is a card, not half a page.
            LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: PosterGrid.lineSpacing) {
                ForEach(items, id: \.id) { item in
                    NavigationLink(value: item) {
                        PosterCard(media: item, size: metrics.cellSize)
                    }
                    .buttonStyle(HomeCardButtonStyle())
                    .contextMenu {
                        Button(role: .destructive) {
                            remove(item)
                            withAnimation { reload() }
                        } label: {
                            Label("Remove from Watchlist", systemImage: "bookmark.slash")
                        }
                    }
                }
            }
            .environment(\.homeHiddenBadges, HomeListBadges.hidden(items: items.map { GridCard.item($0) }))
        }
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

    /// One entry per id, the last added first (the list is append-only JSON).
    private func unique<T: Media>(_ items: [T]) -> [T] {
        var seen = Set<String>()
        return items.reversed().filter { seen.insert($0.id).inserted }
    }
}

#Preview {
    NavigationStack { WatchlistView() }
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}
