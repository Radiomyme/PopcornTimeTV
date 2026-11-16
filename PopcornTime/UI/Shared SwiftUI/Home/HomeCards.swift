// HomeCards.swift — the cards of the Home's shelves (iOS and macOS): a
// poster, a ranked poster with its numeral, a 16:9 card (resume cards,
// episodes). A card answers at a glance: what it is (artwork, title), is it
// new (one pill on the artwork), how good (the IMDb rating), in which
// quality (4K, DV, HDR, ATMOS) and where the user was (progress, what is
// left, the next episode).
//
// Every card of a style has the same size whatever it says — one line of
// title, one of detail, both reserved — so a row never changes height, and
// the placeholders (`isSkeleton`) are the cards themselves, emptied.
import Foundation
import SwiftUI
import PopcornKit

// MARK: - Badges

/// The one badge of the app's cards and hero: the same shape and the same
/// capitals everywhere, in two sizes. An editorial badge ("NOUVEAU",
/// "NOUVEL ÉPISODE") is filled with the accent — or dark when it is not an
/// invitation to watch ("À VENIR"); a format ("4K", "DV", "ATMOS") is dark
/// with a hairline.
struct HomeBadgePill: View {
    enum Tone {
        case accent
        case quiet
        case format
    }

    enum Size {
        /// On a card: 18 points high, 10-point type.
        case small
        /// On the hero: 24 points high.
        case large
    }

    let label: String
    var tone: Tone = .accent
    var size: Size = .small

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size == .small ? 5 : 7, style: .continuous)
        Text(verbatim: label)
            .font(.system(size: size == .small ? 10 : 12, weight: .heavy))
            .tracking(0.3)
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, size == .small ? 6 : 9)
            .frame(height: size == .small ? 18 : 24)
            .background(tone == .accent ? GlassPalette.accent : Color.black.opacity(0.62), in: shape)
            .overlay {
                if tone == .format { shape.stroke(Color.white.opacity(0.35), lineWidth: 0.75) }
            }
            .fixedSize()
    }

    /// The tone of a badge.
    static func tone(of badge: HomeBadge) -> Tone {
        if badge.isFormat { return .format }
        return badge == .upcoming ? .quiet : .accent
    }
}

/// The top-left corner of a poster: its editorial badge ("NOUVEAU") and
/// nothing else — the formats are in the line under the title
/// (`HomePosterFacts`), as in the TV app, so that nothing covers the title
/// a poster prints at its top.
struct HomeCardBadges: View {
    let editorial: HomeBadge?
    let text: HomeCardText

    var body: some View {
        if let editorial {
            HomeBadgePill(label: text.cardLabel(of: editorial), tone: HomeBadgePill.tone(of: editorial))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A format in the line under a card's title: "4K", "DV", "ATMOS" in small
/// outlined capitals, quieter than the rating beside it.
private struct HomeFormatTag: View {
    let label: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        Text(verbatim: label)
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.2)
            .foregroundStyle(GlassPalette.secondaryText)
            .padding(.horizontal, 3)
            .frame(height: 14)
            .overlay(shape.stroke(GlassPalette.secondaryText.opacity(0.7), lineWidth: 0.75))
            .fixedSize()
    }
}

private struct HomeHiddenBadgesKey: EnvironmentKey {
    static let defaultValue: Set<HomeBadge> = []
}

extension EnvironmentValues {
    /// The editorial pills a list does not draw on its cards: the one its
    /// title already says ("NOUVEAU" in Nouveaux films). Never a format:
    /// a card names the same formats in every list (`HomeListBadges`).
    var homeHiddenBadges: Set<HomeBadge> {
        get { self[HomeHiddenBadgesKey.self] }
        set { self[HomeHiddenBadgesKey.self] = newValue }
    }
}

// MARK: - Artwork of a card

/// A card's artwork in its box: placeholder of the final size, fade-in, the
/// title in text when no image answers.
private struct HomeCardArtwork: View {
    let urls: [URL]
    let title: String
    let size: CGSize
    let corner: CGFloat
    var isSkeleton = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Group {
            if isSkeleton {
                HomePalette.placeholder
            } else {
                HomeArtwork(urls: urls, maxPixelSize: (max(size.width, size.height) * displayScale).rounded(.up)) { failed in
                    ZStack {
                        HomePalette.placeholder
                        if failed {
                            Text(verbatim: title)
                                .font(HomeFont.cardTitle)
                                .foregroundStyle(GlassPalette.secondaryText)
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                                .padding(10)
                        }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.stroke(HomePalette.hairline, lineWidth: 1))
    }
}

/// The lines under a card, all reserved: the title on one line (the full
/// title is in VoiceOver, and in the Mac's tooltip), then the detail right
/// under it — always at the same height, so the facts of a row are on one
/// line. The space of the caption is kept whatever this one says: a row
/// never changes height.
private struct HomeCardCaption<Detail: View>: View {
    let title: String
    var titleLines = 1
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The height of the longest caption.
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Array(repeating: "Ag", count: titleLines).joined(separator: "\n"))
                    .font(HomeFont.cardTitle)
                Text(verbatim: "Ag").font(HomeFont.cardDetail)
            }
            .hidden()
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(HomeFont.cardTitle)
                    .foregroundStyle(GlassPalette.primaryText)
                    .lineLimit(titleLines)
                detail()
                    .font(HomeFont.cardDetail)
                    .foregroundStyle(GlassPalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Between a card's artwork and its caption: on the Mac, room for the
/// ring of a card under the pointer or the keyboard (`homeCardLift`).
let homeCaptionGap: CGFloat = {
    #if os(macOS)
    return 11
    #else
    return 7
    #endif
}()

// MARK: - Poster

/// A 2:3 poster with its title and "★ 8,1 · 2026".
struct HomePosterCard: View {
    let item: HomeItem
    let shelfID: String
    let layout: HomeLayout
    let text: HomeCardText
    /// A ranked card draws a smaller poster.
    var size: CGSize? = nil
    var isSkeleton = false

    var body: some View {
        HomePosterTile(item: item, text: text,
                       size: size ?? CGSize(width: layout.posterWidth, height: layout.posterHeight),
                       corner: layout.cardCorner,
                       sourceID: HomeSelection.sourceID(shelf: shelfID, item: item.id),
                       isSkeleton: isSkeleton)
    }
}

/// The face of a poster card, wherever a poster is listed — the Home's
/// shelves, and on iOS the grids (Movies, Shows, My List, Search, See
/// All): the poster with its editorial pill at the top, then the title on
/// one line and "★ 8,1 · 2026  4K DV" — the same facts on every screen.
struct HomePosterTile: View {
    let item: HomeItem
    let text: HomeCardText
    let size: CGSize
    var corner: CGFloat = 12
    /// What a page zooms out of (`homeCardSource`).
    var sourceID: String
    var isSkeleton = false

    @Environment(\.homeHiddenBadges) private var hidden

    var body: some View {
        VStack(alignment: .leading, spacing: homeCaptionGap) {
            HomeCardArtwork(urls: posterURLs, title: item.title, size: size, corner: corner, isSkeleton: isSkeleton)
                .overlay(alignment: .top) {
                    if !isSkeleton {
                        HomeCardBadges(editorial: text.editorialBadge(of: item).flatMap { hidden.contains($0) ? nil : $0 },
                                       text: text)
                    }
                }
                .homeCardSource(id: sourceID)
                .homeCardLift(corner: corner)
            // A working title ("Untitled …") is not printed: the poster says
            // the title (VoiceOver still reads it). A space, not "": an
            // empty text is lower than a line, and the facts would step.
            HomeCardCaption(title: item.cardTitle.isEmpty ? " " : item.cardTitle) {
                HomePosterFacts(facts: text.posterFacts(of: item),
                                formats: isSkeleton ? [] : text.compactFormats(of: item))
            }
        }
        .frame(width: size.width, alignment: .leading)
    }

    /// The card's poster, then metahub's by IMDb id: a source's own poster
    /// may be gone.
    private var posterURLs: [URL] {
        var urls = [item.posterURL].compactMap { $0 }
        if let fallback = OpenMetadata.posterURL(imdbId: item.imdbId), !urls.contains(fallback) { urls.append(fallback) }
        return urls
    }
}

/// "★ 8,1 · 2026  4K DV": how good, how recent, in which quality. The
/// rating and the formats (two at most, `HomeBadge.cardFormats`) are the
/// same on every screen; on a card too narrow for all of it, the year
/// goes — never a format.
private struct HomePosterFacts: View {
    let facts: (rating: String?, year: String?)
    var formats: [String] = []

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(year: facts.year)
            row(year: nil)
        }
    }

    private func row(year: String?) -> some View {
        HStack(spacing: 4) {
            line(year: year)
            if !formats.isEmpty {
                HStack(spacing: 3) {
                    ForEach(formats, id: \.self) { HomeFormatTag(label: $0) }
                }
                .padding(.leading, 3)
            }
        }
    }

    @ViewBuilder
    private func line(year: String?) -> some View {
        HStack(spacing: 4) {
            if let rating = facts.rating {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(GlassPalette.star)
                Text(verbatim: rating)
                    .foregroundStyle(GlassPalette.primaryText.opacity(0.9))
            }
            if facts.rating != nil, year != nil { Text(verbatim: "·") }
            if let year { Text(verbatim: year) }
            // Neither: the line keeps its height.
            if facts.rating == nil, year == nil { Text(verbatim: " ") }
        }
    }
}

// MARK: - Ranked

/// A poster with its rank in large numerals on its left, the poster over
/// the numeral's edge.
struct HomeRankedCard: View {
    let item: HomeItem
    let shelfID: String
    let layout: HomeLayout
    let text: HomeCardText
    var isSkeleton = false

    /// How much of the numeral the poster covers. A numeral that ends in 1
    /// keeps its stem in sight: all of a "1" is on its right.
    private var overlap: CGFloat {
        (item.rank ?? 0) % 10 == 1 ? (layout.rankOverlap * 0.3).rounded() : layout.rankOverlap
    }

    var body: some View {
        // The numeral stands on the poster's bottom edge: its baseline is
        // aligned with it, whatever the caption under the poster measures.
        HStack(alignment: .homeRankBaseline, spacing: -overlap) {
            Text(verbatim: "\(item.rank ?? 0)")
                .font(.system(size: layout.rankFontSize, weight: .heavy, design: .rounded))
                .tracking(-layout.rankFontSize * 0.05)
                .foregroundStyle(LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.3)],
                                                startPoint: .top, endPoint: .bottom))
                .fixedSize()
                .alignmentGuide(.homeRankBaseline) { $0[.firstTextBaseline] }
                .accessibilityHidden(true)
            HomePosterCard(item: item, shelfID: shelfID, layout: layout, text: text,
                           size: CGSize(width: layout.rankedPosterWidth, height: layout.rankedPosterHeight),
                           isSkeleton: isSkeleton)
                .alignmentGuide(.homeRankBaseline) { _ in layout.rankedPosterHeight }
                .zIndex(1)
        }
    }
}

private extension VerticalAlignment {
    /// The bottom edge of a ranked card's poster, where its numeral stands.
    private enum HomeRankBaseline: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.bottom] }
    }

    static let homeRankBaseline = VerticalAlignment(HomeRankBaseline.self)
}

// MARK: - Landscape

/// A 16:9 card: an episode's still or a title's backdrop, the progress of a
/// resume card, then the title and what the card is about ("S2 · É5 · Il
/// reste 23 min", "Épisode suivant · S2 · É6", "S1 · É4 · hier").
struct HomeLandscapeCard: View {
    let item: HomeItem
    let shelfID: String
    let layout: HomeLayout
    let text: HomeCardText
    var isSkeleton = false
    /// The only card of its row: it takes the row's width, its still on
    /// the left and what it is about beside it, rather than leave most of
    /// the row empty. The row is as high as its still (or its text, when
    /// longer): no caption's room under a card whose text is beside it.
    var isWide = false

    @Environment(\.homeHiddenBadges) private var hidden

    private var resumes: Bool { item.progress != nil }

    var body: some View {
        if isWide {
            wide
        } else {
            regular
        }
    }

    /// A wide window gives the lone card a feature's size: a 16:9 still
    /// of up to 560 points and its text in the hero's type beside it, not
    /// a small card and a row of black.
    private var isFeature: Bool { layout.sizeClass == .wide }

    private var wide: some View {
        let row = layout.width - 2 * layout.sideInset
        let featureWidth = min(560, (row * 0.48).rounded())
        let size = isFeature ? CGSize(width: featureWidth, height: (featureWidth * 9 / 16).rounded())
                             : CGSize(width: layout.landscapeWidth, height: layout.landscapeHeight)
        return ZStack(alignment: .topLeading) {
            // At least the still's height. (The room of a caption under it
            // was a hole between this row and the next: the text is beside.)
            Color.clear.frame(width: 1, height: size.height)
                .accessibilityHidden(true)
            HStack(alignment: isFeature ? .center : .top, spacing: isFeature ? 28 : layout.cardSpacing + 2) {
                artwork(size: size)
                VStack(alignment: .leading, spacing: isFeature ? 8 : 4) {
                    Text(verbatim: text.landscapeTitle(of: item))
                        .font(isFeature ? Font.system(size: 28, weight: .bold) : HomeFont.cardTitle)
                        .foregroundStyle(GlassPalette.primaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(isFeature ? 0.7 : 1)
                    let detail = text.landscapeDetail(of: item)
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(isFeature ? HomeFont.heroFacts : HomeFont.cardDetail)
                            .foregroundStyle(GlassPalette.secondaryText)
                            .lineLimit(2)
                    }
                    if let title = item.episode?.title, !HomeCardText.isGenericEpisodeTitle(title) {
                        Text(verbatim: title)
                            .font(isFeature ? HomeFont.heroSynopsis.weight(.semibold) : HomeFont.cardDetail)
                            .foregroundStyle(GlassPalette.primaryText.opacity(0.85))
                            .lineLimit(isFeature ? 2 : 3)
                            .padding(.top, 4)
                    }
                    if isFeature, let summary = text.heroSynopsis(of: item) {
                        Text(verbatim: summary)
                            .font(HomeFont.heroSynopsis)
                            .foregroundStyle(GlassPalette.primaryText.opacity(0.8))
                            .lineLimit(3)
                    }
                }
                .padding(.top, 2)
                .frame(maxWidth: isFeature ? 460 : .infinity, alignment: .topLeading)
            }
        }
        .frame(width: row, alignment: .topLeading)
    }

    private func artwork(size: CGSize) -> some View {
        HomeCardArtwork(urls: item.landscapeURLs, title: item.title, size: size, corner: layout.cardCorner, isSkeleton: isSkeleton)
            .overlay(alignment: .bottom) {
                if !isSkeleton, resumes { resumeOverlay }
            }
            .overlay(alignment: .topLeading) {
                if !isSkeleton, let badge = text.editorialBadge(of: item), !hidden.contains(badge) {
                    HomeBadgePill(label: text.cardLabel(of: badge), tone: HomeBadgePill.tone(of: badge))
                        .padding(8)
                }
            }
            .homeCardSource(id: HomeSelection.sourceID(shelf: shelfID, item: item.id))
            .homeCardLift(corner: layout.cardCorner)
    }

    private var regular: some View {
        let size = CGSize(width: layout.landscapeWidth, height: layout.landscapeHeight)
        return VStack(alignment: .leading, spacing: homeCaptionGap) {
            artwork(size: size)
            HomeCardCaption(title: text.landscapeTitle(of: item)) {
                let detail = text.landscapeDetail(of: item)
                Text(verbatim: detail.isEmpty ? " " : detail)
            }
        }
        .frame(width: size.width, alignment: .leading)
    }

    /// A resume card: a play glyph (the card plays), and the progress along
    /// the bottom edge, over a shade that keeps both readable on any still.
    private var resumeOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, Color.black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(height: layout.landscapeHeight * 0.5)
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.black.opacity(0.5), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1))
                // A card whose episode has not been started shows an empty
                // track: the bar's place does not depend on the card.
                GlassProgressBar(progress: item.progress ?? 0, height: 4)
                    .opacity((item.progress ?? 0) > 0 ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: layout.cardCorner, bottomTrailingRadius: layout.cardCorner, style: .continuous))
        .allowsHitTesting(false)
    }
}

// MARK: - Placeholders

extension HomeItem {
    /// A card without content, for the placeholders: the views draw its
    /// shape, redacted.
    static func skeleton(_ index: Int, rank: Int? = nil) -> HomeItem {
        HomeItem(id: "skeleton-\(index)", imdbId: "", kind: .movie, title: "Placeholder title", year: 2026, rating: 7.5, rank: rank)
    }
}
