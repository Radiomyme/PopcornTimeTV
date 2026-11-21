// HomeSeeAllGrid.swift — a shelf's "See All": the shelf's own titles, in its
// order, in a grid pushed on the Home's stack under the shelf's name (not
// the Movies tab, sorted another way). The Home's cards and lines: a poster
// (or a landscape card for an episode shelf), its line of facts at rest, its
// title under that line once focused. Menu goes back to the See All card.
import SwiftUI
import PopcornKit

struct HomeSeeAllGrid: View {
    let shelf: HomeShelf
    let title: String
    let text: HomeText
    let actions: HomeCardActions
    /// The user's library changed: the menus read it again.
    var libraryVersion: Int = 0
    /// What comes after the shelf's own titles: a streaming service's
    /// whole catalogue (an empty one for the other shelves).
    @ObservedObject var more = HomeSeeAllMore()

    @FocusState private var focused: String?

    private var isLandscape: Bool { shelf.style == .landscape }
    private var card: TVHomeLayout.Card { isLandscape ? TVHomeLayout.landscape : TVHomeLayout.poster }
    /// 6 posters (6 × 240 + 5 × 60) or 4 landscape cards (4 × 400 + 3 × 46)
    /// across the 1740 pt between the page's margins.
    private var columns: [GridItem] {
        let count = isLandscape ? 4 : 6
        let spacing = isLandscape ? (1740 - 4 * card.width) / 3 : (1740 - 6 * card.width) / 5
        return Array(repeating: GridItem(.fixed(card.width), spacing: spacing, alignment: .topLeading), count: count)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundStyle(GlassPalette.primaryText)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("SeeAll.Title")
                    // Under the tab bar (it leaves as the grid scrolls).
                    .padding(.top, 150)
                    .padding(.bottom, 34)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 40) {
                    ForEach(items) { item in
                        cell(item)
                            // Two rows before the end: the next page.
                            .onAppear { if item.id == loadMark { more.loadNext() } }
                    }
                }
                if more.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, TVHomeLayout.side)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("SeeAll.\(shelf.id)")
        .onAppear { more.start(after: shelf.items) }
    }

    /// The shelf's titles, then the catalogue's others.
    private var items: [HomeItem] {
        shelf.items + more.items
    }

    /// The cell whose appearance asks the next page: twelve before the end.
    private var loadMark: String? {
        let all = items
        return all.isEmpty ? nil : all[max(all.count - 12, 0)].id
    }

    @ViewBuilder
    private func cell(_ item: HomeItem) -> some View {
        let badge = text.editorialBadge(of: item, inShelf: shelf.id)
        VStack(alignment: .leading, spacing: 0) {
            SwiftUI.Button { actions.select(item, shelf) } label: {
                if isLandscape {
                    HomeLandscapeArt(item: item, badge: badge)
                } else {
                    HomePosterArt(item: item, badge: badge, width: card.width, height: card.height)
                }
            }
            .glassCardStyle()
            .focused($focused, equals: item.id)
            .contextMenu { menu(item) }
            .accessibilityLabel(Text(verbatim: text.accessibilityLabel(of: item)))
            .accessibilityIdentifier("SeeAll.Card.\(item.id)")

            if isLandscape {
                HomeLandscapeCaption(title: item.title, caption: text.caption(of: item))
            } else {
                HomePosterMeta(rating: item.rating.flatMap { $0 > 0 ? text.rating($0) : nil },
                               formats: text.formats(of: item, limit: 2), year: item.year)
                // The focused poster's title, in a slot every cell keeps:
                // nothing moves when the focus comes.
                Text(verbatim: item.title)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(GlassPalette.primaryText)
                    .lineLimit(1)
                    .frame(width: card.width + 56, height: 34, alignment: .leading)
                    .opacity(focused == item.id ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: focused == item.id)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: card.width, alignment: .leading)
    }

    /// Hold Select: the Home card's menu.
    @ViewBuilder
    private func menu(_ item: HomeItem) -> some View {
        let _ = libraryVersion
        let listed = actions.isInWatchlist(item)
        Text(verbatim: item.title)
        SwiftUI.Button { actions.play(item, shelf) } label: {
            Label("Play", systemImage: "play.fill")
        }
        SwiftUI.Button { actions.toggleWatchlist(item) } label: {
            Label(listed ? "Remove from Watchlist" : "Add to Watchlist", systemImage: listed ? "minus.circle" : "plus.circle")
        }
        if let watched = actions.isWatched(item) {
            SwiftUI.Button { actions.toggleWatched(item) } label: {
                Label(watched ? "Mark as Unwatched" : "Mark as Watched", systemImage: watched ? "eye.slash" : "eye")
            }
        }
    }
}

/// The titles a See All lists after its shelf's: a streaming service's
/// catalogue (TMDB), a page at a time. Without pages, nothing.
final class HomeSeeAllMore: ObservableObject {
    @Published private(set) var items: [HomeItem] = []
    @Published private(set) var isLoading = false
    private let pages: TMDBStreamingClient.CataloguePages?
    private var started = false

    init(pages: TMDBStreamingClient.CataloguePages? = nil) {
        self.pages = pages
    }

    /// The first page, the shelf's own titles left out.
    func start(after shelf: [HomeItem]) {
        guard !started, let pages else { return }
        started = true
        pages.skip(shelf.map(\.imdbId))
        loadNext()
    }

    /// Empty pages in a row so far (`loadNext`).
    private var emptyPages = 0
    /// Empty pages in a row asked one after the other before the grid
    /// waits for the user to reach its end again: a catalogue whose next
    /// titles have no IMDb id was asked for page after page, up to TMDB's
    /// 500th, with nothing for the user to see.
    static let toleratedEmptyPages = 3

    func loadNext() {
        guard started, let pages, !isLoading, !pages.isOver else { return }
        isLoading = true
        pages.load { [weak self] page in
            guard let self else { return }
            self.isLoading = false
            guard let page else { return }
            self.items += page
            self.emptyPages = page.isEmpty ? self.emptyPages + 1 : 0
            // A page whose titles were all on the shelf: the one after.
            if page.isEmpty, !pages.isOver, self.emptyPages < HomeSeeAllMore.toleratedEmptyPages { self.loadNext() }
        }
    }
}

/// Hosts a shelf's See All grid on the Home's navigation stack.
final class HomeSeeAllHostingController: UIHostingController<HomeSeeAllGrid> {

    init(grid: HomeSeeAllGrid) {
        super.init(rootView: grid)
        navigationItem.title = grid.title
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The tab bar follows the grid, as on the other grids: it goes
        // away as the posters scroll up and comes back at the top.
        if let scrollView = HomeSeeAllHostingController.scrollView(in: view) {
            setContentScrollView(scrollView, for: .top)
        }
    }

    private static func scrollView(in root: UIView) -> UIScrollView? {
        var level = [root]
        while !level.isEmpty {
            if let found = level.compactMap({ $0 as? UIScrollView }).first { return found }
            level = level.flatMap(\.subviews)
        }
        return nil
    }
}
