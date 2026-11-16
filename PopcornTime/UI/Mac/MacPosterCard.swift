import Foundation
import SwiftUI
import PopcornKit

// MARK: - Poster grid building blocks

/// The grids of the Mac app (Movies, Shows, My List, Search, a shelf's See
/// All) on the Home's grid: its 52-point margin, its gutters, its poster
/// width and its poster card (`HomePosterTile`: the title on two lines,
/// then "★ 7,6 · 2023" and the formats) — one app from the Home to the grids.
struct MacPosterGrid {
    static let rowSpacing: CGFloat = 26
    /// Decode size of a poster (longest side, pixels).
    static let posterPixels: CGFloat = 600
    /// The width a grid is drawn at before it has been measured.
    static let defaultWidth: CGFloat = 1100

    let layout: HomeLayout
    let columnCount: Int
    let cellWidth: CGFloat

    init(width: CGFloat) {
        // The Mac's pages have the wide margins in a narrow window too.
        let layout = HomeLayout(width: width, height: 800, sizeClass: .wide)
        self.layout = layout
        let inset = layout.sideInset, gap = layout.cardSpacing
        let row = max(width - 2 * inset, 1)
        columnCount = max(2, Int((row + gap) / (164 + gap)))
        cellWidth = max(((row - CGFloat(columnCount - 1) * gap) / CGFloat(columnCount)).rounded(.down), 1)
    }

    var sideInset: CGFloat { layout.sideInset }

    var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellWidth), spacing: layout.cardSpacing, alignment: .top), count: columnCount)
    }

    var cellSize: CGSize { CGSize(width: cellWidth, height: (cellWidth * 1.5).rounded()) }
}

extension View {
    /// Tells the width the view is laid out at (a grid's columns follow it).
    func macGridWidth(_ width: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            if abs(new - width.wrappedValue) >= 1 { width.wrappedValue = new }
        }
    }
}

/// What a grid shows of a title, beyond `Media`: movies and shows.
protocol MacCatalogItem: Media, Hashable {
    var year: String { get }
}

extension Movie: MacCatalogItem {}
extension Show: MacCatalogItem {}

/// What a grid's card says, as a Home card (`HomeItem`): the title cleaned of
/// what some sources append ("Dune (2021) | Dune: Part One" is "Dune"), the
/// year, the IMDb rating and the badges of `PopcornKit.PosterCard` — then
/// told as the rest of the app tells this title (`HomeTitleFacts`: the
/// Home's rating and badges when it lists it).
enum MacGridCard {
    static func item(_ media: Media, now: Date = Date()) -> HomeItem {
        HomeTitleFacts.shared.harmonize(sourceItem(media, now: now))
    }

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

/// A grid's card: the Home's poster card, with the user's marks (in the
/// watchlist, watched) in its top-right corner. The label of a
/// `HomeCardButtonStyle` button: it lifts under the pointer and the keyboard
/// as the Home's cards do.
struct MacPosterCard: View {
    let item: HomeItem
    let size: CGSize
    /// Marked watched: a checkmark in the corner.
    var isWatched = false
    /// In the watchlist: a bookmark in the corner.
    var isInWatchlist = false
    var isSkeleton = false

    var body: some View {
        let text = HomeCardText()
        HomePosterTile(item: item, text: text, size: size, sourceID: "grid/\(item.id)", isSkeleton: isSkeleton)
            .overlay(alignment: .topTrailing) {
                if !isSkeleton { marks.frame(height: size.height, alignment: .topTrailing) }
            }
            .redacted(reason: isSkeleton ? .placeholder : [])
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: isSkeleton ? "" : accessibilityLabel(text)))
            .help(Text(verbatim: item.title))
    }

    private func accessibilityLabel(_ text: HomeCardText) -> String {
        var parts = [text.accessibilityLabel(of: item)]
        if isInWatchlist { parts.append("In Watchlist".localized) }
        if isWatched { parts.append("Watched".localized) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var marks: some View {
        if isWatched || isInWatchlist {
            HStack(spacing: 4) {
                if isInWatchlist { Image(systemName: "bookmark.fill") }
                if isWatched { Image(systemName: "checkmark") }
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(6)
        }
    }
}

/// A poster of a grid: opens the title's page, lifts under the pointer,
/// and offers the library actions on a right click — the watchlist for
/// every title, watched / unwatched for a movie (a show's episodes are
/// marked on its page).
struct MacPosterLink<Item: MacCatalogItem>: View {
    let item: Item
    let size: CGSize
    @EnvironmentObject private var library: MacLibraryState

    var body: some View {
        let inWatchlist = library.isInWatchlist(item)
        let watched = library.isWatched(item)
        #if DEBUG
        // `-PTDebugTour lift:<n>`: this poster drawn as under the pointer.
        let forced = library.debugLiftedID == item.id
        #else
        let forced = false
        #endif
        NavigationLink(value: item) {
            MacPosterCard(item: MacGridCard.item(item), size: size, isWatched: watched, isInWatchlist: inWatchlist)
        }
        .buttonStyle(HomeCardButtonStyle(isHoverForced: forced) { inside in
            // The page of the poster the pointer rests on is asked ahead
            // (`DetailStore.prewarm`: 0.4 s on it, two at a time): it then
            // opens with its sources.
            if inside {
                DetailStore.shared.prewarm(item)
            } else {
                DetailStore.shared.stopPrewarm(of: item)
            }
        })
        .contextMenu {
            Button {
                library.toggleWatchlist(item)
            } label: {
                Label {
                    inWatchlist ? Text("Remove from Watchlist") : Text("Add to Watchlist")
                } icon: {
                    Image(systemName: inWatchlist ? "bookmark.slash" : "bookmark")
                }
            }
            if let movie = item as? Movie {
                Button {
                    library.toggleWatched(movie)
                } label: {
                    Label {
                        watched ? Text("Mark as Unwatched") : Text("Mark as Watched")
                    } icon: {
                        Image(systemName: watched ? "eye.slash" : "checkmark.circle")
                    }
                }
            }
        }
    }
}

/// A grid of posters under an optional section title, on the Home's margin.
struct MacPosterSection<Item: MacCatalogItem>: View {
    var title: Text?
    let items: [Item]

    @State private var width = MacPosterGrid.defaultWidth

    var body: some View {
        let grid = MacPosterGrid(width: width)
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                title
                    .font(HomeFont.shelfTitle(.wide))
                    .foregroundStyle(GlassPalette.primaryText)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, grid.sideInset)
            }
            LazyVGrid(columns: grid.columns, alignment: .leading, spacing: MacPosterGrid.rowSpacing) {
                ForEach(items, id: \.id) { item in
                    MacPosterLink(item: item, size: grid.cellSize)
                }
            }
            .padding(.horizontal, grid.sideInset)
            .environment(\.homeHiddenBadges, HomeListBadges.hidden(items: items.prefix(40).map { MacGridCard.sourceItem($0) }))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .macGridWidth($width)
    }
}

/// The grid before its first page has arrived: the cards themselves,
/// emptied, so the page does not jump when the titles land.
struct MacPosterSkeleton: View {
    let grid: MacPosterGrid
    var count = 24

    var body: some View {
        LazyVGrid(columns: grid.columns, alignment: .leading, spacing: MacPosterGrid.rowSpacing) {
            ForEach(0..<count, id: \.self) { index in
                MacPosterCard(item: .skeleton(index), size: grid.cellSize, isSkeleton: true)
            }
        }
        .padding(.horizontal, grid.sideInset)
        .padding(.top, 20)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: NSLocalizedString("Spinner.Loading", value: "Loading…",
                                                              comment: "VoiceOver: a spinner (something is loading)")))
    }
}

/// The black of the Home under a grid's page, the window's bar included
/// once it scrolls (the system's own bar keeps it legible).
struct MacPageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(HomePalette.background.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func macPageBackground() -> some View { modifier(MacPageBackground()) }
}

/// A grid's own title at its top, on the grid's edge, in the Home's
/// type (28 points, bold): the page says what it is, not the window's
/// small grey bar title — which it then leaves out (macOS 15+).
struct MacPageTitle: View {
    let title: Text
    var sideInset: CGFloat = 52

    var body: some View {
        title
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(GlassPalette.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, sideInset)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The page draws its own title (`MacPageTitle`): none in the bar.
struct MacNoBarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// A rank in a Top's See All: a small dark pill in the poster's top-left
/// corner, drawn as the user's marks in the top-right one. Not on the
/// bottom of the poster: that is where posters print their title, and a
/// numeral there covered it ("5" over "Allen").
struct MacRankMark: View {
    let rank: Int
    /// The card's badge of that corner (« NOUVEAU »), set beside the rank.
    var badge: (label: String, tone: HomeBadgePill.Tone)?

    var body: some View {
        HStack(spacing: 6) {
            number
            if let badge { HomeBadgePill(label: badge.label, tone: badge.tone) }
        }
        .padding(6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var number: some View {
        Text(verbatim: "\(rank)")
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            // 28 × 28 for one or two digits; a third one widens it.
            .padding(.horizontal, 6)
            .frame(minWidth: 28, minHeight: 28)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
