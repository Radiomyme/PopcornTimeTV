// GridStyle.swift — the metrics, fonts and colours of the Apple TV poster
// grids (Movies, Shows, Watchlist, Search results), in UIKit.
//
// The grids are UIKit (a UICollectionView), the detail page and the Home are
// SwiftUI on GlassKit: these values are GlassKit's, so the three read as one
// app — the same 90 pt left edge for the page title and the rows, the
// captions' type scale (GlassFont), the accent and the star colours.
import UIKit
import SwiftUI

enum GridStyle {

    // MARK: Grid (1920 × 1080)

    /// Left and right edge of the page title, the controls and the rows
    /// (`GlassMetrics.sideInset`).
    static let sideInset: CGFloat = GlassMetrics.sideInset
    /// The Home's poster card (`TVHomeLayout.poster`), six columns:
    /// 6 × 240 + 5 × 60 = 1740 = 1920 − 2 × 90.
    static let posterSize = CGSize(width: 240, height: 360)
    static let columnSpacing: CGFloat = 60
    /// Between two rows: every poster's line of facts (`metaTop`,
    /// `metaHeight`), the focused poster's title under it (`captionTop`,
    /// `captionHeight`), and air before the next row.
    static let rowSpacing: CGFloat = 104
    /// Above the first row of a section, below the header (or the section
    /// title): clear of the lift of a focused poster of that row.
    static let sectionTop: CGFloat = 28
    /// Below the last row: its lines, then the end of the page.
    static let sectionBottom: CGFloat = 116

    // MARK: Header

    /// The page title and Sort / Genre, on one line.
    static let headerHeight: CGFloat = 56
    /// How far the header reaches above the grid's own top edge, into the
    /// margin the system leaves under the tab bar (the grid starts 157 pt
    /// down on tvOS 26, 45 pt under the tab bar's pill): the header sits
    /// between the tab bar and the first row, not against the row. With it
    /// the first row starts at 229, the third at 1013: two full rows and the
    /// top of a third on the screen — and that third row is inside the
    /// grid's bounds (they end at 1020), or the grid would not draw it.
    static let headerLift: CGFloat = 12
    static let pageTitleFont = UIFont.systemFont(ofSize: 48, weight: .heavy)
    static let controlFont = UIFont.systemFont(ofSize: 25, weight: .semibold)
    /// A section's title (Watchlist: Movies, Shows): `GlassFont.sectionTitle`.
    static let sectionTitleFont = UIFont.systemFont(ofSize: 38, weight: .bold)
    static let sectionTitleHeight: CGFloat = 52
    /// More room above the first section's title: it is not the page title's subtitle.
    static let firstSectionTitleTop: CGFloat = 18
    /// From a section's title to its first row (the focused poster's lift,
    /// and no more).
    static let titledSectionTop: CGFloat = 22

    // MARK: Lines under a poster

    /// Under every poster, as on the Home's cards: "2026 · ★ 8,0 · 4K · DV"
    /// (`PosterCardText.meta`). Clear of the focused poster's lift (about
    /// 20 pt for a 360 pt poster).
    static let metaTop: CGFloat = 26
    static let metaHeight: CGFloat = 30
    static let metaFont = UIFont.systemFont(ofSize: 22, weight: .semibold)

    /// Under the focused poster's line of facts: its title (one view for
    /// the grid, `PosterCaptionView`).
    static let captionTop: CGFloat = 60
    static let captionHeight: CGFloat = 34
    /// `GlassFont.captionBold` / `GlassFont.caption`, a size up: one line
    /// has to be read from the sofa without the artwork's help.
    /// How long the focus rests on a poster before its caption comes.
    static let captionDelay: TimeInterval = 0.12
    static let captionTitleFont = UIFont.systemFont(ofSize: 27, weight: .semibold)
    static let captionMetaFont = UIFont.systemFont(ofSize: 25, weight: .medium)

    // MARK: Marks on a poster

    static let badgeFont = UIFont.systemFont(ofSize: 17, weight: .bold)
    /// From the poster's edges to a corner mark.
    static let badgeInset: CGFloat = 10
    static let progressHeight: CGFloat = 5

    // MARK: States

    static let messageTitleFont = UIFont.systemFont(ofSize: 44, weight: .bold)
    static let messageBodyFont = UIFont.systemFont(ofSize: 29, weight: .regular)

    // MARK: Colours (GlassPalette)

    static let accent = UIColor(GlassPalette.accent)
    static let star = UIColor(GlassPalette.star)
    static let primaryText = UIColor.white
    static let secondaryText = UIColor(white: 1, alpha: 0.72)
    static let tertiaryText = UIColor(white: 1, alpha: 0.55)
    /// A poster not loaded yet, a skeleton card.
    static let placeholderFill = UIColor(white: 1, alpha: 0.08)

    // MARK: Motion

    /// Fades of the caption and of the states: short, and none with Reduce Motion.
    static var fadeDuration: TimeInterval {
        return UIAccessibility.isReduceMotionEnabled ? 0 : 0.2
    }
}

// MARK: - Pills

/// The small capsule marks ("4K", "NEW"…), drawn once per text and style
/// and kept: a poster shows an image, it lays out no text while the grid
/// scrolls.
enum GridPill {

    enum Style: Int {
        /// On artwork, what is new: the accent, white text.
        case accent
        /// On artwork, a format: dark glass-like fill, white text.
        case dark
        /// In the caption, on the page's background: outlined (`GlassChip`).
        case outline
    }

    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ text: String, style: Style, font: UIFont = GridStyle.badgeFont) -> UIImage {
        let key = "\(style.rawValue)|\(font.pointSize)|\(text)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: 0.4, .foregroundColor: UIColor.white]
        let label = NSAttributedString(string: text, attributes: attributes)
        let textSize = label.size()
        let padding = CGSize(width: (font.pointSize * 0.62).rounded(), height: (font.pointSize * 0.3).rounded())
        let size = CGSize(width: ceil(textSize.width) + padding.width * 2, height: ceil(textSize.height) + padding.height * 2)
        let radius = (font.pointSize * 0.42).rounded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: radius)
            switch style {
            case .accent:
                GridStyle.accent.setFill()
                path.fill()
            case .dark:
                UIColor(white: 0, alpha: 0.62).setFill()
                path.fill()
            case .outline:
                UIColor(white: 1, alpha: 0.10).setFill()
                path.fill()
                UIColor(white: 1, alpha: 0.55).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            label.draw(at: CGPoint(x: padding.width, y: padding.height))
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
