

import SwiftUI
import PopcornKit

typealias MoviesViewModel = CatalogGridModel<Movie, MovieManager.Filters>

extension CatalogGridModel where Item == Movie, Filter == MovieManager.Filters {
    /// The Movies grid on `filter` and `genre`.
    static func movies(filter: MovieManager.Filters = .trending, genre: NetworkManager.Genres = .all) -> MoviesViewModel {
        MoviesViewModel(filter: filter, genre: genre) { page, filter, genre, snapshot, completion in
            if let snapshot {
                PopcornKit.loadMovies(page, filterBy: filter, genre: genre, snapshot: snapshot, completion: completion)
            } else {
                PopcornKit.loadMovies(page, filterBy: filter, genre: genre, completion: completion)
            }
        }
    }
}

/// The Movies grid: a tab's first screen, or pushed on a sort and a genre by
/// a `CatalogRoute` ("See all" of a shelf, a genre of Search).
struct MoviesGridView: View {
    @StateObject private var viewModel: MoviesViewModel
    private let isRoot: Bool

    init(filter: MovieManager.Filters = .trending, genre: NetworkManager.Genres = .all, isRoot: Bool = true) {
        var filter = filter
        var genre = genre
        #if DEBUG
        if isRoot, let forced = IOSDebugHooks.movieFilter { filter = forced }
        if isRoot, let forced = IOSDebugHooks.genre { genre = forced }
        #endif
        _viewModel = StateObject(wrappedValue: .movies(filter: filter, genre: genre))
        self.isRoot = isRoot
    }

    var body: some View {
        CatalogGridView(model: viewModel, title: "Movies", isRoot: isRoot)
    }
}

#Preview {
    NavigationStack { MoviesGridView() }
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}
