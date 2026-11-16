// HomeLayout.swift — the sizes of the Home for the space it is given (iOS
// and macOS): a compact iPhone, a regular iPad, a wide window (an iPad in
// landscape, the Mac). One grid: every shelf starts on `sideInset`, the
// page title's edge, and a row always ends on a card that is cut — the
// sign that it scrolls.
//
// The numbers are the detail pages': 16 points of margin and 12 of corner
// on an iPhone (PosterGrid, MediaDetailView), 52 and 12 on the Mac
// (MacGlassMetrics). No SwiftUI view here, only values (unit-tested).
import Foundation
import CoreGraphics

struct HomeLayout: Equatable {

    enum SizeClass: Equatable {
        /// An iPhone in portrait, a narrow split view.
        case compact
        /// An iPad in portrait, a small window.
        case regular
        /// An iPad in landscape, the Mac.
        case wide
    }

    let sizeClass: SizeClass
    /// The page's width and height (the hero's top safe area included).
    let width: CGFloat
    let height: CGFloat

    /// - Parameter sizeClass: nil (the default): by the width.
    init(width: CGFloat, height: CGFloat, sizeClass: SizeClass? = nil) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.sizeClass = sizeClass ?? HomeLayout.sizeClass(forWidth: width)
    }

    static func sizeClass(forWidth width: CGFloat) -> SizeClass {
        if width < 600 { return .compact }
        return width < 1000 ? .regular : .wide
    }

    // MARK: Grid

    /// The left edge of the page title, of every shelf title and of every
    /// row's first card.
    var sideInset: CGFloat {
        switch sizeClass {
        case .compact: return 16
        case .regular: return 28
        case .wide: return 52
        }
    }

    /// Between two cards of a row.
    var cardSpacing: CGFloat {
        switch sizeClass {
        case .compact: return 12
        case .regular: return 16
        case .wide: return 18
        }
    }

    /// Between two shelves.
    var shelfSpacing: CGFloat {
        switch sizeClass {
        case .compact: return 28
        case .regular: return 34
        case .wide: return 38
        }
    }

    /// Between a shelf's title and its cards.
    var headerSpacing: CGFloat { sizeClass == .compact ? 10 : 12 }

    let cardCorner: CGFloat = 12

    // MARK: Cards

    /// A 2:3 poster's width.
    var posterWidth: CGFloat {
        let target: CGFloat
        switch sizeClass {
        case .compact: target = 124
        case .regular: target = 150
        case .wide: target = 164
        }
        return HomeLayout.cardWidth(target: target, spacing: cardSpacing, row: width - sideInset)
    }

    var posterHeight: CGFloat { (posterWidth * 1.5).rounded() }

    /// A 16:9 card's width (resume cards, episodes).
    var landscapeWidth: CGFloat {
        let target: CGFloat
        switch sizeClass {
        case .compact: target = 236
        case .regular: target = 292
        case .wide: target = 320
        }
        return HomeLayout.cardWidth(target: target, spacing: cardSpacing, row: width - sideInset)
    }

    var landscapeHeight: CGFloat { (landscapeWidth * 9 / 16).rounded() }

    /// The poster of a ranked card: a little smaller than a plain one, its
    /// numeral stands to its left.
    var rankedPosterWidth: CGFloat { (posterWidth * 0.86).rounded() }
    var rankedPosterHeight: CGFloat { (rankedPosterWidth * 1.5).rounded() }

    /// Size of a rank's numeral: its digits are a little over half as tall
    /// as the poster they stand next to.
    var rankFontSize: CGFloat { (rankedPosterHeight * 0.78).rounded() }

    /// How much of the numeral the poster covers: its trailing fifth — the
    /// numeral reads whole, and a row of two cards leaves the next rank in
    /// sight on an iPhone.
    var rankOverlap: CGFloat { (rankFontSize * 0.2).rounded() }

    /// The width of a ranked card at its widest, a two-digit rank: the
    /// numeral (rounded heavy digits, about six tenths of the font size
    /// each) less what the poster covers, then the poster. An estimate, for
    /// counting the cards a row shows (`HomeShelfPaging`), not for drawing.
    var rankedCardWidth: CGFloat { (rankFontSize * 1.2 - rankOverlap + rankedPosterWidth).rounded() }

    /// A card's width such that the row ends on a card that is cut: the
    /// target as it is when the last card on screen shows between a quarter
    /// and three quarters of itself; otherwise the nearest width that does
    /// (wider cards, never narrower than the target). A card that shows
    /// nine tenths of itself reads as a full row, one that shows a tenth as
    /// a margin: neither says "this scrolls".
    ///
    /// - Parameter row: from the first card's leading edge to the trailing
    ///   edge of the page.
    static func cardWidth(target: CGFloat, spacing: CGFloat, row: CGFloat) -> CGFloat {
        guard target > 0, row > target else { return target }
        let fit = (row + spacing) / (target + spacing)
        let whole = fit.rounded(.down)
        let cut = fit - whole
        if (0.25...0.75).contains(cut) { return target }
        let cards = cut < 0.25 ? whole - 0.25 : whole + 0.75
        guard cards >= 1 else { return target }
        return ((row + spacing) / cards - spacing).rounded(.up)
    }

    // MARK: Hero

    /// The carousel's height, the top safe area included: tall enough for
    /// the artwork to carry the screen, and the first shelf's title still
    /// shows under it.
    var heroHeight: CGFloat {
        switch sizeClass {
        case .compact: return min(width * 1.28, height * 0.64).rounded()
        case .regular: return min(max(width * 0.56, 420), height * 0.62).rounded()
        case .wide: return min(max(width * 0.42, 440), height * 0.68).rounded()
        }
    }

    /// The hero's text column (centred on a compact screen).
    var heroTextWidth: CGFloat {
        switch sizeClass {
        case .compact: return width - 2 * 24
        case .regular: return min(520, width * 0.62)
        case .wide: return min(620, width * 0.5)
        }
    }

    /// The box the title's logo fits in.
    var heroLogoSize: CGSize {
        switch sizeClass {
        case .compact: return CGSize(width: min(260, width * 0.66), height: 84)
        case .regular: return CGSize(width: 340, height: 104)
        case .wide: return CGSize(width: 400, height: 124)
        }
    }

    /// The synopsis shows where there is room for it beside the artwork's
    /// subject: not on a compact screen.
    var showsHeroSynopsis: Bool { sizeClass != .compact }

    /// The hero's text and buttons sit at the bottom, centred on a compact
    /// screen and on the leading edge otherwise.
    var centersHero: Bool { sizeClass == .compact }

    /// Longest side a backdrop is decoded at, in pixels, on a screen of
    /// `scale`: the hero's drawn size, capped at the sources' (1920 wide; a
    /// Retina Mac window draws them larger and gets 2560, as its detail
    /// pages do).
    func heroPixelSize(scale: CGFloat) -> CGFloat {
        // The 16:9 backdrop fills the hero: as tall as it, or as wide.
        let drawnWidth = max(width, heroHeight * 16 / 9)
        return min((drawnWidth * max(scale, 1)).rounded(.up), sizeClass == .wide ? 2560 : 1920)
    }
}
