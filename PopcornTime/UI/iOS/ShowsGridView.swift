

import SwiftUI
import PopcornKit

typealias ShowsViewModel = CatalogGridModel<Show, ShowManager.Filters>

extension CatalogGridModel where Item == Show, Filter == ShowManager.Filters {
    /// The Shows grid on `filter` and `genre`.
    static func shows(filter: ShowManager.Filters = .trending, genre: NetworkManager.Genres = .all) -> ShowsViewModel {
        ShowsViewModel(filter: filter, genre: genre, arrange: { filter in
            // Each page is an unordered batch: "A - Z" re-sorts the whole
            // list so it stays alphabetical as pages arrive.
            guard filter == .name else { return nil }
            return { $0.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }
        }, load: { page, filter, genre, snapshot, completion in
            if let snapshot {
                PopcornKit.loadShows(page, filterBy: filter, genre: genre, snapshot: snapshot, completion: completion)
            } else {
                PopcornKit.loadShows(page, filterBy: filter, genre: genre, completion: completion)
            }
        })
    }
}

/// The Shows grid: a tab's first screen, or pushed on a sort and a genre by
/// a `CatalogRoute`.
struct ShowsGridView: View {
    @StateObject private var viewModel: ShowsViewModel
    private let isRoot: Bool

    init(filter: ShowManager.Filters = .trending, genre: NetworkManager.Genres = .all, isRoot: Bool = true) {
        var filter = filter
        var genre = genre
        #if DEBUG
        if isRoot, let forced = IOSDebugHooks.showFilter { filter = forced }
        if isRoot, let forced = IOSDebugHooks.genre { genre = forced }
        #endif
        _viewModel = StateObject(wrappedValue: .shows(filter: filter, genre: genre))
        self.isRoot = isRoot
    }

    var body: some View {
        CatalogGridView(model: viewModel, title: "Shows", isRoot: isRoot)
    }
}

#Preview {
    NavigationStack { ShowsGridView() }
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}
