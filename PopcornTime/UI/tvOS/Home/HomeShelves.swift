// HomeShelves.swift — the rows of the Home tab: posters, ranked posters with
// their numeral, landscape cards (resume cards, episodes), the See All card,
// and the placeholders shown before the first data.
//
// Every size comes from `TVHomeLayout`: a row has the same height whatever it
// holds, and a placeholder has the size of the card that replaces it.
import SwiftUI
import CoreText
import PopcornKit

/// What a card does, handed down from the page (`HomeActions` plus the
/// shelf the card is in).
struct HomeCardActions {
    var select: (_ item: HomeItem, _ shelf: HomeShelf) -> Void = { _, _ in }
    /// Plays the title (its page, then its playback).
    var play: (_ item: HomeItem, _ shelf: HomeShelf) -> Void = { _, _ in }
    var seeAll: (HomeShelf) -> Void = { _ in }
    var isInWatchlist: (HomeItem) -> Bool = { _ in false }
    var toggleWatchlist: (HomeItem) -> Void = { _ in }
    var isWatched: (HomeItem) -> Bool? = { _ in nil }
    var toggleWatched: (HomeItem) -> Void = { _ in }
    var removeFromContinueWatching: (HomeItem) -> Void = { _ in }
}

// MARK: - Row

/// One shelf: its title on the page's left margin, its cards in a lazy row.
///
/// Equatable on what it draws: a focus move re-evaluates the page's body
/// (it reads the focus), not the rows.
struct HomeShelfRow: View, Equatable {
    let shelf: HomeShelf
    let title: String
    /// The user's library changed: the menus read it again.
    let libraryVersion: Int
    let text: HomeText
    var focus: FocusState<HomeFocus?>.Binding
    let actions: HomeCardActions

    static func == (lhs: HomeShelfRow, rhs: HomeShelfRow) -> Bool {
        return lhs.shelf == rhs.shelf && lhs.title == rhs.title && lhs.libraryVersion == rhs.libraryVersion
    }

    var body: some View {
        let card = TVHomeLayout.card(of: shelf.style)
        VStack(alignment: .leading, spacing: 0) {
            HomeShelfTitle(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: card.spacing) {
                    ForEach(shelf.items) { item in
                        cardView(item)
                    }
                    if shelf.seeAll != nil {
                        seeAllCard
                    }
                }
                .padding(.vertical, TVHomeLayout.cardPadding)
            }
            .contentMargins(.horizontal, TVHomeLayout.side, for: .scrollContent)
            .scrollClipDisabled()
            .focusSection()
        }
        .padding(.top, TVHomeLayout.rowTopPadding)
        .frame(height: TVHomeLayout.rowHeight(of: shelf.style), alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityIdentifier("Home.Section.\(shelf.id)")
    }

    // MARK: Cards

    @ViewBuilder
    private func cardView(_ item: HomeItem) -> some View {
        if shelf.id == HomeShelfID.services {
            serviceCard(item)
        } else {
            titleCard(item)
        }
    }

    /// A card of the « Services » row: the service's logo (its name when
    /// there is none), the one the page shows checked; « All » first while
    /// the page is filtered. No menu: it is not a title.
    private func serviceCard(_ item: HomeItem) -> some View {
        let selected = HomeServiceCard.isSelected(item)
        return VStack(alignment: .leading, spacing: 0) {
            SwiftUI.Button { actions.select(item, shelf) } label: {
                HomeServiceArt(item: item, selected: selected)
            }
            .glassCardStyle()
            .focused(focus, equals: .card(shelf: shelf.id, item: item.id))
            .accessibilityLabel(Text(verbatim: item.title))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("Home.Card.\(item.id)")
            HomeLandscapeCaption(title: item.title, caption: selected ? "Home.Services.Shown".localized : "")
        }
        .frame(width: TVHomeLayout.landscape.width, alignment: .leading)
    }

    @ViewBuilder
    private func titleCard(_ item: HomeItem) -> some View {
        switch shelf.style {
        case .landscape:
            VStack(alignment: .leading, spacing: 0) {
                button(item) { HomeLandscapeArt(item: item, badge: text.editorialBadge(of: item, inShelf: shelf.id)) }
                HomeLandscapeCaption(title: item.title, caption: text.caption(of: item))
            }
            .frame(width: TVHomeLayout.landscape.width, alignment: .leading)
        case .ranked:
            // The numeral stands on the row's baseline, its right edge under the poster.
            let zone = TVHomeLayout.rankZone(of: item.rank ?? 0)
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    HomeRankNumeral(rank: item.rank ?? 0)
                        .frame(width: zone + TVHomeLayout.rankOverlap, height: TVHomeLayout.ranked.height * 0.64)
                    button(item) {
                        HomePosterArt(item: item, badge: text.editorialBadge(of: item, inShelf: shelf.id),
                                      width: TVHomeLayout.rankedPosterWidth, height: TVHomeLayout.ranked.height)
                    }
                    .padding(.leading, zone)
                }
                HomePosterMeta(rating: item.rating.flatMap { $0 > 0 ? text.rating($0) : nil },
                               formats: text.formats(of: item, limit: 2), year: item.year)
                    .padding(.leading, zone)
            }
            .frame(width: zone + TVHomeLayout.rankedPosterWidth, alignment: .leading)
        case .posters, .hero:
            VStack(alignment: .leading, spacing: 0) {
                button(item) {
                    HomePosterArt(item: item, badge: text.editorialBadge(of: item, inShelf: shelf.id),
                                  width: TVHomeLayout.poster.width, height: TVHomeLayout.poster.height)
                }
                HomePosterMeta(rating: item.rating.flatMap { $0 > 0 ? text.rating($0) : nil },
                               formats: text.formats(of: item, limit: 2), year: item.year)
            }
            .frame(width: TVHomeLayout.poster.width, alignment: .leading)
        }
    }

    /// The focusable part of a card: the system card style (lift, parallax,
    /// the glass platter of tvOS 26), like the posters of the detail page.
    private func button<Label: View>(_ item: HomeItem, @ViewBuilder label: () -> Label) -> some View {
        SwiftUI.Button { actions.select(item, shelf) } label: { label() }
            .glassCardStyle()
            .focused(focus, equals: .card(shelf: shelf.id, item: item.id))
            .contextMenu { menu(item) }
            .accessibilityLabel(Text(verbatim: text.accessibilityLabel(of: item)))
            .accessibilityIdentifier("Home.Card.\(item.id)")
    }

    /// Hold Select on a card: the grids' menu (the title, Play, the
    /// watchlist, watched) and — on a resume card — leaving the shelf.
    @ViewBuilder
    private func menu(_ item: HomeItem) -> some View {
        let listed = actions.isInWatchlist(item)
        // An episode's card says which episode Play and the mark are about.
        let code = item.episode.map(text.episodeCode)
        Text(verbatim: item.title)
        SwiftUI.Button { actions.play(item, shelf) } label: {
            Label(code.map { String(format: "Play %@".localized, $0) } ?? "Play".localized, systemImage: "play.fill")
        }
        SwiftUI.Button { actions.toggleWatchlist(item) } label: {
            Label(listed ? "Remove from Watchlist" : "Add to Watchlist", systemImage: listed ? "minus.circle" : "plus.circle")
        }
        if let watched = actions.isWatched(item) {
            SwiftUI.Button { actions.toggleWatched(item) } label: {
                Label(code.map { String(format: (watched ? "Mark %@ as Unwatched" : "Mark %@ as Watched").localized, $0) }
                        ?? (watched ? "Mark as Unwatched" : "Mark as Watched").localized,
                      systemImage: watched ? "eye.slash" : "eye")
            }
        }
        if shelf.id == HomeShelfID.continueWatching {
            SwiftUI.Button(role: .destructive) { actions.removeFromContinueWatching(item) } label: {
                Label("Home.Menu.RemoveFromContinueWatching", systemImage: "xmark.circle")
            }
        }
    }

    /// The last card of a shelf that has more to show: its grid.
    private var seeAllCard: some View {
        let card = TVHomeLayout.card(of: shelf.style)
        let width = shelf.style == .ranked ? TVHomeLayout.rankedPosterWidth : min(card.width, TVHomeLayout.poster.width)
        // A ranked shelf's posters start after their numeral: so does this card.
        return SwiftUI.Button { actions.seeAll(shelf) } label: {
            VStack(spacing: 18) {
                Image(systemName: "chevron.right.circle")
                    .font(.system(size: 58, weight: .regular))
                Text("See All")
                    .font(GlassFont.bodyEmphasis)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .frame(width: width, height: card.height)
        }
        .buttonStyle(HomeSeeAllButtonStyle())
        .focused(focus, equals: .seeAll(shelf: shelf.id))
        .accessibilityIdentifier("Home.SeeAll.\(shelf.id)")
    }
}

/// The See All card: dark glass with white type, at rest and focused — a
/// focused card lifts like a poster and its glass lightens a little; it is
/// never the white slab of a focused button (the brightest thing on a dark
/// page, among posters that do not turn white).
struct HomeSeeAllButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.glassFallback) private var fallback
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            configuration.label
                .foregroundStyle(Color.white.opacity(isFocused ? 1 : 0.86))
                .background { surface(shape) }
                .overlay { shape.strokeBorder(Color.white.opacity(isFocused ? 0.5 : 0.14), lineWidth: isFocused ? 2 : 1) }
                .scaleEffect(configuration.isPressed ? 1.04 : (isFocused ? 1.08 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 24, y: 16)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFocused)
        }

        @ViewBuilder
        private func surface(_ shape: RoundedRectangle) -> some View {
            if #available(tvOS 26.0, *), !fallback {
                Color.clear.glassEffect(.regular.tint(Color.black.opacity(isFocused ? 0.15 : 0.45)), in: shape)
            } else {
                shape.fill(Color.white.opacity(isFocused ? 0.18 : 0.08))
            }
        }
    }
}

/// A shelf's title, on the page's left margin.
struct HomeShelfTitle: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(GlassFont.sectionTitle)
            .foregroundStyle(GlassPalette.primaryText)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            .frame(height: TVHomeLayout.titleHeight, alignment: .bottomLeading)
            .padding(.horizontal, TVHomeLayout.side)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Services

/// A service's card: its logo on dark glass (its name when it has none),
/// a checkmark on the one the page shows; « All »: a grid symbol.
struct HomeServiceArt: View {
    let item: HomeItem
    let selected: Bool

    var body: some View {
        let card = TVHomeLayout.landscape
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if HomeServiceCard.isAll(item) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(GlassPalette.primaryText)
            } else if let logo = item.posterURL {
                HomeArtImage(urls: [logo], maxPixelSize: homePixels(150)) { name }
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            } else {
                name
            }
        }
        .frame(width: card.width, height: card.height)
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, .white)
                    .padding(16)
            }
        }
    }

    private var name: some View {
        Text(verbatim: item.title)
            .font(.system(size: 40, weight: .heavy))
            .foregroundStyle(GlassPalette.primaryText)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .padding(24)
    }
}

// MARK: - Artwork

/// Pixels of `points` on this screen (an Apple TV HD draws at 1×, a 4K at 2×).
@MainActor
func homePixels(_ points: CGFloat) -> CGFloat {
    return points * min(max(UIScreen.main.scale, 1), 2)
}

/// A card's image: the first of `urls` that loads (an episode's still, then
/// its show's backdrop: a still can be a 404), decoded at the size drawn,
/// faded in over a placeholder of the same size.
struct HomeArtImage<Placeholder: View>: View {
    let urls: [URL]
    let maxPixelSize: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: GlassPlatformImage?
    @State private var loadedFor: [URL] = []

    init(urls: [URL], maxPixelSize: CGFloat, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.urls = urls
        self.maxPixelSize = maxPixelSize
        self.placeholder = placeholder
        // A decoded image at hand: no placeholder flash when a row comes back.
        let hit = HomeArtImage.cached(urls, maxPixelSize: maxPixelSize)
        _image = State(initialValue: hit)
        _loadedFor = State(initialValue: hit == nil ? [] : urls)
    }

    /// The first of `urls` already decoded in the artwork pipeline (no I/O).
    private static func cached(_ urls: [URL], maxPixelSize: CGFloat) -> GlassPlatformImage? {
        return urls.lazy.compactMap { GlassImageCache.shared.cachedImage(for: $0, maxPixelSize: maxPixelSize) }.first
    }

    var body: some View {
        ZStack {
            if image == nil || loadedFor != urls {
                placeholder()
            }
            if let image, loadedFor == urls {
                Image(glassImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        // A card off screen lets its image go: the lazy rows keep the state
        // of the cards they have created, and an image held there is out of
        // the reach of the pipeline's memory bound (every card of every
        // shelf browsed would stay decoded). Back on screen, the pipeline's
        // copy is drawn at once when it still has one; else it loads again.
        .onAppear {
            guard image == nil, let hit = HomeArtImage.cached(urls, maxPixelSize: maxPixelSize) else { return }
            image = hit
            loadedFor = urls
        }
        .onDisappear {
            image = nil
            loadedFor = []
        }
        .task(id: urls) {
            guard loadedFor != urls || image == nil else { return }
            for url in urls {
                let loaded = await GlassImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
                if Task.isCancelled { return }
                guard let loaded else { continue }
                withAnimation(.easeOut(duration: 0.3)) {
                    image = loaded
                    loadedFor = urls
                }
                return
            }
        }
    }
}

/// The pill on a card's artwork: what is new about it.
/// The same pill as the grids' posters (`GridPill`, the accent style): one
/// drawing of "new" on a poster across the Apple TV app.
struct HomeCardBadge: View {
    let text: String

    var body: some View {
        Image(uiImage: GridPill.image(text.localizedUppercase, style: .accent))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A 2:3 poster, with its "new" pill.
struct HomePosterArt: View {
    let item: HomeItem
    let badge: String?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        HomeArtImage(urls: HomePosterArt.urls(of: item), maxPixelSize: homePixels(height)) {
            ZStack {
                LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom)
                Text(verbatim: item.title)
                    .font(GlassFont.captionBold)
                    .foregroundStyle(GlassPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .padding(18)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay(alignment: .topLeading) {
            if let badge {
                HomeCardBadge(text: badge).padding(GridStyle.badgeInset)
            }
        }
    }

    /// The card's poster, then metahub's by IMDb id.
    static func urls(of item: HomeItem) -> [URL] {
        var urls: [URL] = []
        for url in [item.posterURL, OpenMetadata.posterURL(imdbId: item.imdbId)].compactMap({ $0 }) where !urls.contains(url) {
            urls.append(url)
        }
        return urls
    }
}

/// Under a poster, one pattern on every card: the year, the IMDb rating,
/// the formats ("2026 · ★ 7,8 · 4K · DV"); what is not known is left out.
/// One line, always there: the row keeps its height.
struct HomePosterMeta: View {
    let rating: String?
    let formats: String?
    let year: Int?

    var body: some View {
        HStack(spacing: 0) {
            if let year {
                Text(verbatim: String(year))
                    .foregroundStyle(GlassPalette.secondaryText)
            }
            if let rating {
                if year != nil { separator }
                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(GlassPalette.star)
                    Text(verbatim: rating)
                        .foregroundStyle(GlassPalette.primaryText.opacity(0.86))
                }
            }
            if let formats {
                if year != nil || rating != nil { separator }
                Text(verbatim: formats)
                    .foregroundStyle(GlassPalette.secondaryText)
            }
        }
        .font(GlassFont.small)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
        // Clear of the focused poster above it, which grows.
        .padding(.top, 24)
        .frame(height: TVHomeLayout.poster.caption, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var separator: some View {
        Text(verbatim: " · ").foregroundStyle(GlassPalette.tertiaryText)
    }
}

/// A 16:9 card: an episode's still or a backdrop, its "new" pill, and the
/// progress of a title being watched.
struct HomeLandscapeArt: View {
    let item: HomeItem
    let badge: String?

    var body: some View {
        let card = TVHomeLayout.landscape
        HomeArtImage(urls: HomeLandscapeArt.urls(of: item), maxPixelSize: homePixels(card.width)) {
            ZStack {
                LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(verbatim: item.title)
                    .font(GlassFont.bodyEmphasis)
                    .foregroundStyle(GlassPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(24)
            }
        }
        .frame(width: card.width, height: card.height)
        .clipped()
        .overlay(alignment: .bottom) {
            if let progress = item.progress, progress > 0 {
                ZStack(alignment: .bottom) {
                    // Behind the bar only: the picture stays clear.
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 64)
                    GlassProgressBar(progress: progress, height: 7)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let badge {
                HomeCardBadge(text: badge).padding(GridStyle.badgeInset)
            }
        }
    }

    /// The episode's still, the card's backdrop, then metahub's by IMDb id.
    static func urls(of item: HomeItem) -> [URL] {
        var urls: [URL] = []
        for url in item.landscapeURLs + [OpenMetadata.backgroundURL(imdbId: item.imdbId)].compactMap({ $0 }) where !urls.contains(url) {
            urls.append(url)
        }
        return urls
    }
}

/// Under a landscape card: the title, then where the user was or which episode it is.
struct HomeLandscapeCaption: View {
    let title: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(GlassPalette.primaryText)
            Text(verbatim: caption.isEmpty ? " " : caption)
                .font(GlassFont.small)
                .foregroundStyle(GlassPalette.secondaryText)
        }
        .lineLimit(1)
        .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
        .padding(.top, 22)
        .frame(height: TVHomeLayout.landscape.caption, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

// MARK: - Rank numeral

/// The large outlined numeral of a ranked card, drawn from the glyphs'
/// outlines (SwiftUI's Text has no stroke) and fitted to its box, standing
/// on its bottom edge against the poster on its right.
struct HomeRankNumeral: View {
    let rank: Int

    var body: some View {
        let shape = HomeRankShape(text: String(rank))
        ZStack {
            shape.fill(Color.black.opacity(0.35))
            shape.stroke(Color.white.opacity(0.82), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct HomeRankShape: Shape {
    let text: String

    func path(in rect: CGRect) -> Path {
        let glyphs = HomeRankShape.outline(of: text)
        let box = glyphs.boundingBoxOfPath
        let inset = rect.insetBy(dx: 4, dy: 4)
        guard box.width > 0, box.height > 0, inset.width > 0, inset.height > 0 else { return Path() }
        // As tall as the box; narrowed to its width, by 15 % at most — then
        // made smaller instead.
        var scaleY = inset.height / box.height
        let scaleX = min(scaleY, inset.width / box.width)
        if scaleX < scaleY * 0.85 { scaleY = scaleX / 0.85 }
        // Font coordinates grow upwards: flipped, set on the bottom edge,
        // against the trailing edge (the poster covers a little of it).
        var transform = CGAffineTransform(a: scaleX, b: 0, c: 0, d: -scaleY,
                                          tx: inset.maxX - box.width * scaleX - box.minX * scaleX,
                                          ty: inset.maxY + box.minY * scaleY)
        return Path(glyphs.copy(using: &transform) ?? glyphs)
    }

    /// The outlines already made: the ranks are few, and a row asks for
    /// each of them at every pass of its layout.
    private static let outlines = NSCache<NSString, CGPath>()

    /// The outline of `text` in the heavy system font, in font units.
    private static func outline(of text: String) -> CGPath {
        if let known = outlines.object(forKey: text as NSString) { return known }
        let font = UIFont.systemFont(ofSize: 200, weight: .heavy) as CTFont
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .kern: -8]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
                path.addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
            }
        }
        // The system font's digits are made of contours that overlap (the
        // foot of a 2 over its diagonal), and so do two digits set tight:
        // stroked as they are, the overlaps show as small loops inside the
        // numeral. One contour per visible shape.
        let outline = path.normalized(using: .winding)
        outlines.setObject(outline, forKey: text as NSString)
        return outline
    }
}

// MARK: - Placeholders

/// A row before the first data: a title bar and cards of the final size.
struct HomeShelfSkeleton: View {
    let style: HomeShelf.Style

    var body: some View {
        let card = TVHomeLayout.card(of: style)
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.13))
                .frame(width: 320, height: 30)
                .frame(height: TVHomeLayout.titleHeight, alignment: .bottomLeading)
            HStack(alignment: .top, spacing: card.spacing) {
                ForEach(0..<8, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: card.width, height: card.height)
                }
            }
            .padding(.vertical, TVHomeLayout.cardPadding)
        }
        .padding(.top, TVHomeLayout.rowTopPadding)
        .padding(.leading, TVHomeLayout.side)
        .frame(height: TVHomeLayout.rowHeight(of: style), alignment: .top)
        .accessibilityHidden(true)
    }
}
