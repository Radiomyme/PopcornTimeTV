import Foundation
import SwiftUI
import PopcornKit

/// Movies and shows saved with a title page's Watchlist button or a
/// poster's right click (WatchlistManager, synced with Trakt when signed
/// in). Drawn from the window's `MacLibraryState`: a title added or
/// removed anywhere in the window shows here at once.
struct MacWatchlistView: View {
    @EnvironmentObject private var library: MacLibraryState

    var body: some View {
        Group {
            if library.watchlistMovies.isEmpty && library.watchlistShows.isEmpty {
                ContentUnavailableView {
                    Label { Text("Watchlist Empty") } icon: { Image(systemName: "bookmark") }
                } description: {
                    Text("Try adding movies or shows to your watchlist.")
                }
            } else {
                ScrollView {
                    MacPageTitle(title: Text("Watchlist"))
                    VStack(alignment: .leading, spacing: 26) {
                        if !library.watchlistMovies.isEmpty {
                            MacPosterSection(title: Text("Movies"), items: library.watchlistMovies)
                        }
                        if !library.watchlistShows.isEmpty {
                            MacPosterSection(title: Text("Shows"), items: library.watchlistShows)
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .macPageBackground()
        .navigationTitle(Text("Watchlist"))
        .modifier(MacNoBarTitle())
        // The section showing: Trakt's list too, when signed in.
        .onAppear { library.reload() }
    }
}
