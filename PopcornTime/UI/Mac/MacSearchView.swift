import Foundation
import AppKit
import SwiftUI
import PopcornKit

// MARK: - Search model

/// The Search page's state: the field's text, searched live once the
/// typing pauses (`debounce`), and the movies and shows found. Which
/// answers still count is `SearchSession`'s (PopcornKit): those of an
/// older query never show. Owned by the window's `MacNavigator`: the
/// query and its results are still there when the section comes back.
@MainActor
final class MacSearchModel: ObservableObject {
    enum Kind: Hashable { case movies, shows }

    /// Searches one kind of title; calls back on any queue.
    /// `incomplete`: a source of that catalogue was left out (the same
    /// query may be sent again).
    typealias Searcher<T> = (_ term: String, _ completion: @escaping ([T]?, NSError?, _ incomplete: Bool) -> Void) -> Void

    /// How long the typing must pause before a query is sent: each one
    /// costs six requests (three sources for movies, three for shows).
    static let debounce: Duration = .milliseconds(350)

    /// The field's text.
    @Published var text = "" {
        didSet { if text != oldValue { textChanged() } }
    }
    @Published private(set) var session = SearchSession<Kind>(kinds: [.movies, .shows])
    @Published private(set) var movies: [Movie] = []
    @Published private(set) var shows: [Show] = []

    private let searchMovies: Searcher<Movie>
    private let searchShows: Searcher<Show>
    private var pending: Task<Void, Never>?
    /// The query whose results `movies` and `shows` hold.
    private var shownToken = 0

    init(searchMovies: @escaping Searcher<Movie> = { term, completion in
             PopcornKit.searchMovies(term, completion: completion)
         },
         searchShows: @escaping Searcher<Show> = { term, completion in
             PopcornKit.searchShows(term, completion: completion)
         }) {
        self.searchMovies = searchMovies
        self.searchShows = searchShows
    }

    /// Return in the field: now, without waiting for the typing to pause
    /// (one character is a query then: « X », « M »).
    func submit() {
        pending?.cancel()
        search(submitted: true)
    }

    /// Try Again / ⌘R: the same query once more when a source failed
    /// (nothing while the field is empty; a query every source answered is
    /// simply kept).
    func retry() {
        submit()
    }

    private func textChanged() {
        pending?.cancel()
        guard SearchSession<Kind>.normalised(text).count >= SearchSession<Kind>.minimumLength else {
            // Emptied (or one letter left): back to the starting page at
            // once, and whatever is on its way is dropped.
            session.clear()
            movies = []
            shows = []
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.search()
        }
    }

    private func search(submitted: Bool = false) {
        guard let token = session.begin(text, submitted: submitted) else { return }
        let query = session.query
        searchMovies(query) { [weak self] results, error, incomplete in
            DispatchQueue.main.async {
                guard let self = self, self.accept(.movies, count: results?.count ?? 0, error: error,
                                                   incomplete: incomplete, token: token) else { return }
                self.movies = results ?? []
            }
        }
        searchShows(query) { [weak self] results, error, incomplete in
            DispatchQueue.main.async {
                guard let self = self, self.accept(.shows, count: results?.count ?? 0, error: error,
                                                   incomplete: incomplete, token: token) else { return }
                self.shows = results ?? []
            }
        }
    }

    /// One source's answer: true when it is the current query's (the
    /// caller then shows it). What the previous query found stays on screen
    /// until the first answer of this one; then nothing of it is left.
    private func accept(_ kind: Kind, count: Int, error: NSError?, incomplete: Bool, token: Int) -> Bool {
        guard session.receive(kind, count: count, error: error?.localizedDescription, incomplete: incomplete,
                              token: token) else { return false }
        if shownToken != token {
            shownToken = token
            movies = []
            shows = []
        }
        return true
    }
}

// MARK: - Search page

/// Live search: the toolbar's field, then movies and shows as two grids.
/// States: a hint before anything is typed, a spinner while the first
/// answer is out, "no results" for a query nothing matches, the error with
/// Try Again when the sources could not be reached.
struct MacSearchView: View {
    @ObservedObject var model: MacSearchModel
    @EnvironmentObject private var navigator: MacNavigator

    var body: some View {
        let hasResults = model.session.phase == .results
        // What the previous query found stays, dimmed, until this one answers.
        let hasPreviousResults = model.session.isSearching && !(model.movies.isEmpty && model.shows.isEmpty)
        ZStack {
            if hasResults || hasPreviousResults {
                ScrollView { results }
                    .opacity(hasResults ? 1 : 0.45)
            } else {
                // Nothing to scroll: the status takes the page (as an
                // overlay of an empty scroll view it is given no height).
                status
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .macPageBackground()
        .navigationTitle(Text("Search"))
        .searchable(text: $model.text, placement: .toolbar, prompt: Text("Movie or show title"))
        .onSubmit(of: .search) { model.submit() }
        .modifier(MacSearchFieldFocus(request: navigator.searchFocusRequest))
        .toolbar {
            if model.session.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !model.movies.isEmpty {
                MacPosterSection(title: Text("Movies"), items: model.movies)
            }
            if !model.shows.isEmpty {
                MacPosterSection(title: Text("Shows"), items: model.shows)
            }
            // A source that failed while the other found something: said,
            // with Try Again (⌘R too), not left out silently.
            if !model.session.isSearching {
                ForEach([MacSearchModel.Kind.movies, .shows], id: \.self) { kind in
                    if let message = model.session.failures[kind] {
                        failureLine(kind == .movies ? Text("Movies") : Text("Shows"), message: message)
                    }
                }
            }
        }
        .padding(.vertical, 20)
    }

    private func failureLine(_ title: Text, message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            title
                .font(.headline)
            Text(verbatim: message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            Button("Try Again") { model.retry() }
        }
        .padding(.horizontal, HomeLayout(width: 1000, height: 800, sizeClass: .wide).sideInset)
    }

    @ViewBuilder
    private var status: some View {
        switch model.session.phase {
        case .idle:
            ContentUnavailableView {
                Label { Text("Search") } icon: { Image(systemName: "magnifyingglass") }
            } description: {
                Text("Find a movie or a show by its title.")
            }
        case .searching, .results:
            ProgressView()
                .controlSize(.large)
        case .empty:
            ContentUnavailableView {
                Label { Text("No results") } icon: { Image(systemName: "magnifyingglass") }
            } description: {
                Text(verbatim: String(format: "We didn't turn anything up for %@. Try something else.".localized,
                                      "“\(model.session.query)”"))
            }
        case .failed(let message):
            ContentUnavailableView {
                Label { Text("Error") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") { model.retry() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Puts the keyboard in the toolbar's search field when the Search page
/// shows and on every ⌘F (`request` changes): the section is there to type
/// in.
private struct MacSearchFieldFocus: ViewModifier {
    let request: Int

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            Focused(request: request, content: content)
        } else {
            // macOS 14 has no `searchFocused`: the toolbar's own search
            // item is asked to start a search, as a click in it does.
            content.task(id: request) {
                try? await Task.sleep(for: .milliseconds(150))
                guard let toolbar = (NSApp.keyWindow ?? NSApp.mainWindow)?.toolbar else { return }
                toolbar.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first?.beginSearchInteraction()
            }
        }
    }

    @available(macOS 15.0, *)
    private struct Focused: View {
        let request: Int
        let content: Content
        @FocusState private var isFocused: Bool

        var body: some View {
            content
                .searchFocused($isFocused)
                .task(id: request) {
                    // Once the field is in the toolbar (the page just appeared).
                    try? await Task.sleep(for: .milliseconds(150))
                    isFocused = true
                }
        }
    }
}
