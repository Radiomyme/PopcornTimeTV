

import SwiftUI
import PopcornKit

/// The grids of the iOS app (Movies, Shows, My List, Search, a shelf's
/// See All) on the Home's grid: its margins (16 points on an iPhone, the
/// iPad's), its gutters, and its poster card (`HomePosterTile`) — three
/// columns on an iPhone, five on an iPad in portrait, more when wider.
struct PosterGrid {
    static let lineSpacing: CGFloat = 20
    /// How many cells before the end the next page starts loading.
    static let preloadDistance = 8

    let layout: HomeLayout
    let columnCount: Int
    let cellWidth: CGFloat

    init(width: CGFloat) {
        let layout = HomeLayout(width: width, height: 800)
        self.layout = layout
        let inset = layout.sideInset, gap = layout.cardSpacing
        let row = max(width - 2 * inset, 1)
        switch layout.sizeClass {
        case .compact: columnCount = 3
        case .regular: columnCount = 5
        case .wide: columnCount = max(6, Int((row + gap) / (164 + gap)))
        }
        cellWidth = max(((row - CGFloat(columnCount - 1) * gap) / CGFloat(columnCount)).rounded(.down), 1)
    }

    var sideInset: CGFloat { layout.sideInset }

    var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellWidth), spacing: layout.cardSpacing, alignment: .top), count: columnCount)
    }

    var cellSize: CGSize { CGSize(width: cellWidth, height: (cellWidth * 1.5).rounded()) }
}

/// A grid that knows its width: `content` is given the grid's metrics.
struct PosterGridReader<Content: View>: View {
    @ViewBuilder var content: (PosterGrid) -> Content

    var body: some View {
        GeometryReader { proxy in
            content(PosterGrid(width: proxy.size.width))
        }
    }
}

/// What a grid's card says, as a Home card (`HomeItem`): the title cleaned of
/// what some sources append ("Dune (2021) | Dune: Part One" is "Dune"), the
/// year, the IMDb rating and the badges of `PopcornKit.PosterCard` (4K,
/// New, New Episode).
enum GridCard {
    /// The card as the rest of the app tells this title
    /// (`HomeTitleFacts`): the Home's rating and badges when it lists it.
    static func item(_ media: Media, now: Date = Date()) -> HomeItem {
        HomeTitleFacts.shared.harmonize(sourceItem(media, now: now))
    }

    /// The card as its source tells it.
    static func sourceItem(_ media: Media, now: Date = Date()) -> HomeItem {
        if let movie = media as? Movie {
            let card = PopcornKit.PosterCard(movie: movie, now: now)
            return HomeItem(imdbId: movie.id, kind: .movie, title: cleanTitle(movie.title), year: card.year,
                            rating: card.rating, posterURL: url(movie.smallCoverImage ?? movie.mediumCoverImage),
                            badges: card.badges)
        }
        if let show = media as? Show {
            let card = PopcornKit.PosterCard(show: show, now: now)
            return HomeItem(imdbId: show.id, kind: .show, title: cleanTitle(show.title), year: card.year,
                            rating: card.rating, posterURL: url(show.smallCoverImage ?? show.mediumCoverImage),
                            badges: card.badges)
        }
        return HomeItem(imdbId: media.id, kind: .movie, title: cleanTitle(media.title))
    }

    /// "Dune (2021) | Dune: Part One" → "Dune"; "Alien (1979)" → "Alien".
    static func cleanTitle(_ title: String) -> String {
        var text = title
        if let bar = text.range(of: "|") { text = String(text[..<bar.lowerBound]) }
        text = text.trimmingCharacters(in: .whitespaces)
        if let year = text.range(of: #"\s*\((19|20)\d\d\)$"#, options: .regularExpression) {
            text.removeSubrange(year)
        }
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    private static func url(_ string: String?) -> URL? {
        string.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
}

/// One card of a grid: the Home's poster card, zooming into its page.
struct PosterCard: View {
    let item: HomeItem
    let size: CGSize
    /// The title's id when its page zooms out of this poster.
    var zoomID: String? = nil
    var isSkeleton = false
    /// A catalogue's title: the card is worked out when drawn, so that it
    /// follows the Home's facts as they arrive (`homeFactsFeed`).
    var media: Media? = nil

    @Environment(\.mediaZoomNamespace) private var zoom
    @Environment(\.homeFactsVersion) private var factsVersion

    var body: some View {
        // Read: a new version of the Home's facts draws the card again.
        let _ = factsVersion
        let item = media.map { GridCard.item($0) } ?? self.item
        HomePosterTile(item: item, text: HomeCardText(), size: size, sourceID: zoomID ?? item.id, isSkeleton: isSkeleton)
            .environment(\.homeZoomNamespace, zoomID == nil ? nil : zoom)
            .redacted(reason: isSkeleton ? .placeholder : [])
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: HomeCardText().accessibilityLabel(of: item)))
    }
}

extension PosterCard {
    /// A movie's or a show's card.
    init(media: Media, size: CGSize) {
        self.init(item: GridCard.item(media), size: size, zoomID: media.id, media: media)
    }

    /// A card of the placeholders of a grid that is loading.
    static func placeholder(_ index: Int, size: CGSize) -> PosterCard {
        PosterCard(item: .skeleton(index), size: size, isSkeleton: true)
    }
}

// MARK: - Top shade

/// The black under the status bar and the navigation bar once a page has
/// scrolled: opaque from the screen's top edge to the bottom of the bars,
/// then fading out over 60 points (90 on an iPad, whose tab bar floats
/// there). Nothing shows through behind the clock, the title or the
/// buttons. Shared by the Home and every grid (See All, Movies, Shows, My
/// List, Search).
struct TopShade: View {
    /// 0: hidden (the Home's carousel at rest), 1: opaque.
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            let top = proxy.safeAreaInsets.top
            let fade: CGFloat = proxy.size.width < 600 ? 60 : 90
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: top / max(top + fade, 1)),
                                   .init(color: .black.opacity(0.6), location: (top + fade * 0.4) / max(top + fade, 1)),
                                   .init(color: .black.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: top + fade)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
                .opacity(level)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A grid's scroll view: the top shade comes in as soon as its content
/// leaves its resting place, in place of the system's edge effect.
private struct ScrollTopShade: ViewModifier {
    @State private var shaded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 4
            } action: { _, scrolled in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { shaded = scrolled }
            }
            .scrollEdgeEffectHidden(true, for: .top)
            .overlay(alignment: .top) { TopShade(level: shaded ? 1 : 0) }
    }
}

extension View {
    /// On a grid's scroll view: the shared top shade (`TopShade`).
    func scrollTopShade() -> some View {
        modifier(ScrollTopShade())
    }
}

// MARK: - The Home's facts on the other tabs

private struct HomeFactsVersionKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Bumped when the Home's facts (`HomeTitleFacts`) change under a grid.
    var homeFactsVersion: Int {
        get { self[HomeFactsVersionKey.self] }
        set { self[HomeFactsVersionKey.self] = newValue }
    }
}

/// A grid opened before the Home was ever shown (a launch on the Movies
/// tab, a link): the Home's lists are read — from the disk first — and
/// told to `HomeTitleFacts`, so the grid's cards carry the Home's ratings
/// and badges, and are drawn again when they arrive.
private struct HomeFactsFeed: ViewModifier {
    @State private var version = 0
    @MainActor private static var started = false

    func body(content: Content) -> some View {
        let state = IOSHome.state
        let key = state.shelves.map { "\($0.id):\($0.items.count):\($0.updatedAt?.timeIntervalSinceReferenceDate ?? 0)" }
            + ["hero:\(state.heroItems.count)"]
        content
            .environment(\.homeFactsVersion, version)
            .onChange(of: key, initial: true) { _, _ in
                guard !state.shelves.isEmpty else { return }
                _ = HomeHarmony(shelves: state.shelves, hero: state.heroItems)
                version &+= 1
            }
            .task {
                guard !HomeFactsFeed.started else { return }
                HomeFactsFeed.started = true
                state.start()
            }
    }
}

extension View {
    /// On a grid: its cards told as the Home tells them (`HomeFactsFeed`).
    func homeFactsFeed() -> some View {
        modifier(HomeFactsFeed())
    }
}
