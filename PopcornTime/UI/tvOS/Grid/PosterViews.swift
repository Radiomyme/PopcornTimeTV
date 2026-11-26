// PosterViews.swift — what the Apple TV grids draw around a poster: the marks
// on the artwork (PosterMarksView) and the line under the focused poster
// (PosterCaptionView).
import UIKit
import PopcornKit

// MARK: - Marks on the artwork

/// The small marks of a poster: "NEW" / "NEW EPISODE" top left, a watched
/// tick bottom right, a thin progress bar along the bottom
/// of a started title. The cell lays it over the poster, and over the place
/// the focus lifts the poster to (`CoverCollectionViewCell.showPoster`).
///
/// Plain views laid out by frame, pills drawn once (`GridPill`): nothing is
/// measured or typeset while the grid scrolls.
final class PosterMarksView: UIView {

    private let leadingPill = UIImageView()
    private let trailingPill = UIImageView()
    private let tick = UIImageView()
    private let scrim = CAGradientLayer()
    private let track = UIView()
    private let fill = UIView()
    private var progress: CGFloat = 0

    private static let tickImage: UIImage? = {
        let size = CGSize(width: 34, height: 34)
        let symbol = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .heavy))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let circle = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
            UIColor(white: 0, alpha: 0.66).setFill()
            circle.fill()
            UIColor(white: 1, alpha: 0.38).setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            if let symbol = symbol {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2))
            }
        }
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // Under the progress bar, so that it reads on a bright poster too.
        scrim.colors = [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.6).cgColor]
        scrim.isHidden = true
        layer.addSublayer(scrim)
        track.backgroundColor = UIColor(white: 1, alpha: 0.3)
        fill.backgroundColor = GridStyle.accent
        track.layer.cornerRadius = GridStyle.progressHeight / 2
        fill.layer.cornerRadius = GridStyle.progressHeight / 2
        tick.image = PosterMarksView.tickImage
        for view in [leadingPill, trailingPill, tick, track, fill] {
            view.isHidden = true
            addSubview(view)
        }
        // The cell's accessibility label says it all.
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The marks of `card`; nil (a person, a download, a poster being
    /// reused) clears them.
    func show(_ card: PosterCard?) {
        let news = card?.badges.first { $0 == .new || $0 == .newEpisode }
        leadingPill.image = news.map { GridPill.image($0.localizedLabel.localizedUppercase, style: .accent) }
        leadingPill.isHidden = news == nil
        // No format on the artwork: "4K" on nearly every poster said
        // nothing, and lists that do not know the formats (Top 100) showed
        // the same titles without it. The focused poster's caption spells
        // the formats, as the Home's cards do under the poster.
        trailingPill.image = nil
        trailingPill.isHidden = true
        tick.isHidden = !(card?.isWatched ?? false)
        progress = CGFloat(card?.progress ?? 0)
        let started = card?.progress != nil
        track.isHidden = !started
        fill.isHidden = !started
        scrim.isHidden = !started
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = GridStyle.badgeInset
        if let image = trailingPill.image {
            trailingPill.frame = CGRect(x: bounds.maxX - inset - image.size.width, y: inset, width: image.size.width, height: image.size.height)
        }
        if let image = leadingPill.image {
            // Never under the 4K pill: a long "NEW EPISODE" (in some
            // languages) is scaled down to the room left.
            let room = (trailingPill.isHidden ? bounds.maxX - inset : trailingPill.frame.minX - 6) - inset
            let scale = min(1, max(0.5, room / image.size.width))
            leadingPill.frame = CGRect(x: inset, y: inset, width: image.size.width * scale, height: image.size.height * scale)
        }
        if let image = tick.image {
            tick.frame = CGRect(x: bounds.maxX - inset - image.size.width, y: bounds.maxY - inset - image.size.height,
                                width: image.size.width, height: image.size.height)
        }
        let barWidth = bounds.width - inset * 2
        track.frame = CGRect(x: inset, y: bounds.maxY - inset - GridStyle.progressHeight, width: barWidth, height: GridStyle.progressHeight)
        fill.frame = CGRect(x: inset, y: track.frame.minY, width: max(GridStyle.progressHeight, barWidth * min(max(progress, 0), 1)),
                            height: GridStyle.progressHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = CGRect(x: 0, y: bounds.maxY - 64, width: bounds.width, height: 64)
        CATransaction.commit()
    }
}

// MARK: - Caption of the focused poster

/// The focused poster's title, under its line of facts. One view for the
/// whole grid, moved under whichever poster has the focus: the grid's
/// layout never changes with the focus.
///
/// It starts at the poster's left edge, like the captions of the detail
/// page's shelves; near the right edge of the screen, where it would not
/// fit, it is moved left just enough to end on the rows' right edge.
final class PosterCaptionView: UIView {

    private let label = UILabel()
    private(set) var card: PosterCard?
    /// The frame of the poster it is under.
    private(set) var poster = CGRect.null

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        // Above the posters (a focused one is lifted over its neighbours).
        layer.zPosition = 100
        // The focused poster reads the same words itself: the caption is
        // an element only while it shows, for the tools that look at the
        // screen (the UI tests check where it is).
        label.isAccessibilityElement = false
        accessibilityTraits = .staticText
        accessibilityIdentifier = "Grid.Caption"
    }

    override var alpha: CGFloat {
        didSet { isAccessibilityElement = alpha > 0 && card != nil }
    }

    /// The words of the caption, made when a tool asks for them.
    override var accessibilityLabel: String? {
        get { return card.map(PosterCardText.accessibilityLabel) }
        set { super.accessibilityLabel = newValue }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows `card` under the poster whose frame in the grid is `poster`.
    /// `width` is the grid's; the caption stays between its side insets.
    func show(_ card: PosterCard, under poster: CGRect, gridWidth width: CGFloat) {
        self.card = card
        let room = width - GridStyle.sideInset * 2
        // The title only: the line of facts is under every poster already.
        var text = PosterCardText.title(card)
        var size = text.size()
        // A very long title: shortened to the rows' width.
        var title = card.title
        while size.width > room, title.count > 12 {
            title = String(title.dropLast(max(2, title.count / 8))).trimmingCharacters(in: .whitespaces)
            text = PosterCardText.title(card, title: title + "…")
            size = text.size()
        }
        label.attributedText = text
        let textWidth = min(ceil(size.width), room)
        frame.size = CGSize(width: textWidth, height: GridStyle.captionHeight)
        label.frame = bounds
        move(under: poster, gridWidth: width)
    }

    /// Under `poster` again, the same words: its row scrolled sideways.
    func move(under poster: CGRect, gridWidth width: CGFloat) {
        self.poster = poster
        let x = max(GridStyle.sideInset, min(poster.minX, width - GridStyle.sideInset - bounds.width))
        let origin = CGPoint(x: x, y: poster.maxY + GridStyle.captionTop)
        if frame.origin != origin { frame.origin = origin }
    }

    func clear() {
        card = nil
        isAccessibilityElement = false
    }
}
