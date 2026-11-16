

import SwiftUI
// PopcornKit predates Swift concurrency auditing; its models (Movie/Show/…)
// aren't marked Sendable, so passing them out of the completion handlers
// trips "non-Sendable capture" warnings. `@preconcurrency` tells the compiler
// to treat the module as pre-concurrency and silences those (they're
// value-type structs, safe to hand across in practice).
@preconcurrency import PopcornKit

@MainActor
final class SearchViewModel: ObservableObject {
    /// What the screen shows under the search field.
    enum Phase: Equatable {
        /// Nothing typed: the recent searches and the genres.
        case idle
        /// The answer to the text in the field is on its way.
        case searching
        /// `movies` and `shows` answer the text in the field.
        case results
        case noResults
        /// Both catalogues failed: the reason.
        case failed(String)
    }

    @Published var query = ""
    @Published private(set) var movies: [Movie] = []
    @Published private(set) var shows: [Show] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recents: [String]

    private let recentSearches: RecentSearches
    /// Bumped at every change of the text: an answer is shown only if it
    /// carries the current value. `Task.cancel()` alone did not stop the
    /// callbacks already on their way, so the results of "bat" could land
    /// after — and replace — those of "batman".
    private var token = 0
    private var pending: Task<Void, Never>?
    /// The text of the search that is running or answered.
    private var requestedText = ""

    init(recentSearches: RecentSearches = RecentSearches()) {
        self.recentSearches = recentSearches
        recents = recentSearches.queries
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text changed: search it after a short pause in the typing.
    func queryChanged() {
        // Not again for the text already asked for (a recent search picked
        // sets the field and searches at once).
        guard trimmedQuery != requestedText else { return }
        start(after: 300_000_000)
    }

    /// Return on the keyboard, a recent search picked, Try Again: search
    /// now — unless that text is already answered or on its way (a failed
    /// search is run again).
    func submit() {
        remember()
        var failed = false
        if case .failed = phase { failed = true }
        guard failed || trimmedQuery != requestedText else { return }
        start(after: 0)
    }

    /// The search led somewhere (submitted, or one of its results opened):
    /// it is one to offer again.
    func remember() {
        guard !trimmedQuery.isEmpty else { return }
        recentSearches.add(trimmedQuery)
        recents = recentSearches.queries
    }

    func forget(_ query: String) {
        recentSearches.remove(query)
        recents = recentSearches.queries
    }

    func forgetAll() {
        recentSearches.clear()
        recents = []
    }

    private func start(after delay: UInt64) {
        token += 1
        let token = self.token
        pending?.cancel()
        let text = trimmedQuery
        requestedText = text
        guard !text.isEmpty else {
            movies = []
            shows = []
            phase = .idle
            return
        }
        // The previous results stay, dimmed, until these arrive.
        phase = .searching
        pending = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled, let self, self.token == token else { return }
            self.search(text, token: token)
        }
    }

    private func search(_ text: String, token: Int) {
        let group = DispatchGroup()
        let answer = Answer()

        group.enter()
        PopcornKit.loadMovies(searchTerm: text) { results, error in
            DispatchQueue.main.async {
                answer.movies = results ?? []
                if results == nil, let error { answer.errors.append(error) }
                group.leave()
            }
        }
        group.enter()
        PopcornKit.loadShows(searchTerm: text) { results, error in
            DispatchQueue.main.async {
                answer.shows = results ?? []
                if results == nil, let error { answer.errors.append(error) }
                group.leave()
            }
        }
        // Both halves at once: never the movies of one search beside the
        // shows of another.
        group.notify(queue: .main) { [weak self] in
            guard let self, self.token == token else { return }
            self.movies = answer.movies
            self.shows = answer.shows
            if !answer.movies.isEmpty || !answer.shows.isEmpty {
                self.phase = .results
            } else if answer.errors.count == 2, let error = answer.errors.first {
                self.phase = .failed(error.localizedDescription)
            } else {
                self.phase = .noResults
            }
        }
    }

    /// The two catalogues' answers to one search (filled on the main queue).
    private final class Answer {
        var movies: [Movie] = []
        var shows: [Show] = []
        var errors: [NSError] = []
    }
}

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @Environment(AppRouter.self) private var router

    /// `.searchable`'s UIKit search bar crashes when the app runs as an
    /// "iOS app on Mac" (Designed for iPad, still a run destination of this
    /// target): activating the field drives `_UISearchPresentationController`
    /// → `UIScreen._preferredFocusedWindow`, which asserts with
    /// `_screenBasedFocusUnsupported` because screen-based focus doesn't
    /// exist on the Mac windowing model. There the screen draws its own
    /// field; iPhone and iPad keep the native one.
    private let isiOSAppOnMac = ProcessInfo.processInfo.isiOSAppOnMac

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if isiOSAppOnMac {
                VStack(spacing: 0) {
                    macSearchField
                    scroll
                }
            } else {
                scroll
                    // An iPad: the field in sight under the title, and no
                    // second magnifier in the bar beside the tab's own.
                    .searchable(text: $viewModel.query,
                                placement: horizontalSizeClass == .regular
                                    ? .navigationBarDrawer(displayMode: .always) : .automatic,
                                prompt: "Movie or show title")
                    .onSubmit(of: .search) { viewModel.submit() }
            }
        }
        .navigationTitle("Search")
        .homeFactsFeed()
        .toolbar { RootToolbar() }
        .onChange(of: viewModel.query) { _, _ in viewModel.queryChanged() }
        // A popcorntime://search?q=… link: its text goes in the field (and
        // is searched as if typed), once.
        .onChange(of: router.searchRequest, initial: true) { _, text in
            guard let text else { return }
            router.searchRequest = nil
            viewModel.query = text
        }
        #if DEBUG
        .task {
            if let text = IOSDebugHooks.searchText, viewModel.query.isEmpty { viewModel.query = text }
        }
        #endif
    }

    private var scroll: some View {
        PosterGridReader { metrics in
            ScrollView {
                content(metrics)
                    .padding(.horizontal, metrics.sideInset)
                    .padding(.top, 8)
            }
            .scrollTopShade()
        }
    }

    private var macSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Movie or show title", text: $viewModel.query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onSubmit { viewModel.submit() }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func content(_ metrics: PosterGrid) -> some View {
        switch viewModel.phase {
        case .idle:
            suggestions
        case .searching where viewModel.movies.isEmpty && viewModel.shows.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        case .searching, .results:
            results(metrics)
                .opacity(viewModel.phase == .searching ? 0.45 : 1)
                .animation(.easeInOut(duration: 0.2), value: viewModel.phase)
        case .noResults:
            ContentUnavailableView.search(text: viewModel.query)
                .padding(.top, 32)
        case .failed(let message):
            ContentUnavailableView {
                Label("Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") { viewModel.submit() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 32)
        }
    }

    // MARK: Results

    private func results(_ metrics: PosterGrid) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if !viewModel.movies.isEmpty {
                section("Movies") { grid(viewModel.movies, metrics: metrics) }
            }
            if !viewModel.shows.isEmpty {
                section("Shows") { grid(viewModel.shows, metrics: metrics) }
            }
        }
    }

    private func grid<Item: CatalogItem>(_ items: [Item], metrics: PosterGrid) -> some View {
        LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: PosterGrid.lineSpacing) {
            ForEach(items, id: \.id) { item in
                NavigationLink(value: item) {
                    PosterCard(media: item, size: metrics.cellSize)
                }
                .buttonStyle(HomeCardButtonStyle())
                // A search that led to a page is one to offer again.
                .simultaneousGesture(TapGesture().onEnded { viewModel.remember() })
            }
        }
        .environment(\.homeHiddenBadges, HomeListBadges.hidden(items: items.map { GridCard.item($0) }))
    }

    // MARK: Nothing typed

    /// Before anything is typed: the last searches, then the genres as
    /// shortcuts into the Movies grid.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !viewModel.recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Recent Searches").font(.title3.bold())
                        Spacer()
                        Button("Clear") { withAnimation { viewModel.forgetAll() } }
                            .font(.subheadline)
                    }
                    .padding(.bottom, 6)
                    ForEach(viewModel.recents, id: \.self) { recent in
                        Button {
                            viewModel.query = recent
                            viewModel.submit()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                Text(verbatim: recent)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.left")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation { viewModel.forget(recent) }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        Divider()
                    }
                }
            }

            section("Browse by Genre") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(NetworkManager.Genres.movies.filter { $0 != .all }, id: \.self) { genre in
                        NavigationLink(value: CatalogRoute.movies(filter: .trending, genre: genre)) {
                            Text(verbatim: genre.string)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 14)
                                .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: .regularMaterial)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            content()
        }
    }
}

#Preview {
    NavigationStack { SearchView() }
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}
