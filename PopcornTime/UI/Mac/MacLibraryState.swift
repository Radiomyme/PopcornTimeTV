import Foundation
import SwiftUI
import PopcornKit

/// What the grids show and change about the user's library: the watchlist
/// (movies and shows) and the watched movies. Read once into sets when it
/// changes, not once per poster: `WatchlistManager.isAdded` decodes the
/// whole stored list on every call, which a grid of posters cannot afford.
///
/// The local sets are read again on every `.libraryDidChange` (the library
/// posts it after each write: a toggle in this window or another one, a
/// title's page, a player's checkpoint marking a title watched). Trakt is
/// asked only by `reload()` (init, the stack back on the section, the
/// Watchlist page, ⌘R): its answer rewrites the list, which posts the
/// notification — asking it again there would loop. One per window, in the
/// environment.
@MainActor
final class MacLibraryState: ObservableObject {
    @Published private(set) var watchlistMovies: [Movie] = []
    @Published private(set) var watchlistShows: [Show] = []
    /// Ids of every title in the watchlist (movies and shows).
    @Published private(set) var watchlistIDs: Set<String> = []
    /// Ids of the movies marked watched (a show is not watched as a whole:
    /// its episodes are).
    @Published private(set) var watchedMovieIDs: Set<String> = []
    #if DEBUG
    /// `-PTDebugTour lift:<n>` (MacDebugHooks): the poster drawn as under
    /// the pointer. Here because the posters already follow this object.
    @Published var debugLiftedID: String?
    #endif

    private var libraryObserver: NSObjectProtocol?

    init() {
        reload()
        libraryObserver = NotificationCenter.default.addObserver(forName: .libraryDidChange, object: Library.shared,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadStored() }
        }
    }

    deinit {
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
    }

    /// The lists stored on this Mac, without asking Trakt.
    private func reloadStored() {
        setWatchlist(movies: WatchlistManager<Movie>.movie.storedWatchlist(),
                     shows: WatchlistManager<Show>.show.storedWatchlist())
        let watched = Set(WatchedlistManager<Movie>.movie.storedWatched())
        if watched != watchedMovieIDs { watchedMovieIDs = watched }
    }

    /// The local lists now; Trakt's when it answers (signed in only).
    func reload() {
        let movies = WatchlistManager<Movie>.movie.getWatchlist { [weak self] updated in
            DispatchQueue.main.async { self?.setWatchlist(movies: updated) }
        }
        let shows = WatchlistManager<Show>.show.getWatchlist { [weak self] updated in
            DispatchQueue.main.async { self?.setWatchlist(shows: updated) }
        }
        setWatchlist(movies: movies, shows: shows)
        let watched = Set(WatchedlistManager<Movie>.movie.getWatched())
        if watched != watchedMovieIDs { watchedMovieIDs = watched }
    }

    func isInWatchlist(_ media: Media) -> Bool {
        watchlistIDs.contains(media.id)
    }

    /// Movies only (false for a show).
    func isWatched(_ media: Media) -> Bool {
        media is Movie && watchedMovieIDs.contains(media.id)
    }

    /// Adds the movie / show to the watchlist, or removes it.
    func toggleWatchlist(_ media: Media) {
        // From what is stored now (not from this copy of it): the list is
        // append-only, adding a title twice would list it twice.
        if var movie = media as? Movie {
            movie.isAddedToWatchlist.toggle()
        } else if var show = media as? Show {
            show.isAddedToWatchlist.toggle()
        } else {
            return
        }
        reload()
    }

    /// Marks the movie watched, or unwatched (which also forgets where it
    /// was stopped: WatchedlistManager.remove).
    func toggleWatched(_ movie: Movie) {
        var movie = movie
        movie.isWatched.toggle()
        reload()
    }

    /// Only what changed is published: unchanged pages don't redraw.
    private func setWatchlist(movies: [Movie]? = nil, shows: [Show]? = nil) {
        if let movies {
            let list = Self.unique(movies)
            if list.map(\.id) != watchlistMovies.map(\.id) { watchlistMovies = list }
        }
        if let shows {
            let list = Self.unique(shows)
            if list.map(\.id) != watchlistShows.map(\.id) { watchlistShows = list }
        }
        let ids = Set(watchlistMovies.map(\.id)).union(watchlistShows.map(\.id))
        if ids != watchlistIDs { watchlistIDs = ids }
    }

    /// One entry per id (the stored list is append-only JSON).
    private static func unique<T: Media>(_ items: [T]) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
