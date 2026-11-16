

import UIKit
import struct PopcornKit.PosterCard

class CoverCollectionViewCell: BaseCollectionViewCell {
    
    @IBOutlet var watchedIndicator: UIImageView?
    
    var watched = false {
        didSet {
            watchedIndicator?.isHidden = !watched || marksView != nil
        }
    }
    
#if os(tvOS)

    /// The marks of a poster of a grid (`showPoster`); nil for the other
    /// users of this cell (the season picker), which keep its title label
    /// and its watched corner.
    private(set) var marksView: PosterMarksView?

    /// What the poster says about its title (`showPoster`).
    private(set) var card: PosterCard?

    /// Under the poster, as on the Home's cards: "2026 · ★ 8,0 · 4K · DV".
    private var metaLabel: UILabel?

    /// A poster of a grid: the artwork with its marks on it (New, watched,
    /// progress) and its line of facts under it; the focused poster's title
    /// comes under that line (`PosterCaptionView`).
    func showPoster(_ card: PosterCard?) {
        self.card = card
        if marksView == nil { installMarksView() }
        marksView?.show(card)
        metaLabel?.attributedText = card.map(PosterCardText.meta)
    }

    /// The marks sit over the poster, and over the place the focus lifts it
    /// to (`focusedFrameGuide`) while it has the focus: `focusedConstraints`
    /// take over then, animated with the focus (UICollectionViewCell+ReactiveCell).
    ///
    /// Not in the image view's `overlayContentView`, which would also tilt
    /// them with the poster: an image view with an overlay is drawn through
    /// the layered-image path whether it has the focus or not, and a grid of
    /// them dropped more frames while scrolling (measured with
    /// `-PTDebugHitches`: about a third more late time).
    private func installMarksView() {
        let marks = PosterMarksView()
        marks.translatesAutoresizingMaskIntoConstraints = false
        // On the cell, over its content view (which clips: the focused
        // poster is larger than the cell).
        addSubview(marks)
        marks.layer.zPosition = 5
        let atRest = [
            marks.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            marks.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            marks.topAnchor.constraint(equalTo: imageView.topAnchor),
            marks.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
        ]
        atRest.forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate(atRest)
        let guide = imageView.focusedFrameGuide
        focusedConstraints += [
            marks.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            marks.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            marks.topAnchor.constraint(equalTo: guide.topAnchor),
            marks.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ]
        marksView = marks
        // On the cell too, under its bounds (the row spacing is its room):
        // it stays where it is when the poster lifts.
        let meta = UILabel()
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.numberOfLines = 1
        meta.lineBreakMode = .byTruncatingTail
        meta.isAccessibilityElement = false
        addSubview(meta)
        NSLayoutConstraint.activate([
            meta.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            meta.widthAnchor.constraint(equalToConstant: GridStyle.posterSize.width + GridStyle.columnSpacing / 2),
            meta.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: GridStyle.metaTop),
            meta.heightAnchor.constraint(equalToConstant: GridStyle.metaHeight),
        ])
        metaLabel = meta
        titleLabel.isHidden = true
        watchedIndicator?.isHidden = true
    }

    /// A poster reads what it shows: "title, year, rating, runtime, 4K,
    /// New…". Made when asked for, not for every poster the grid scrolls by.
    override var accessibilityLabel: String? {
        get { return card.map(PosterCardText.accessibilityLabel) ?? super.accessibilityLabel ?? titleLabel?.text }
        set { super.accessibilityLabel = newValue }
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        
        if let watchedIndicator = watchedIndicator {
            focusedConstraints.append(watchedIndicator.trailingAnchor.constraint(equalTo: imageView.focusedFrameGuide.trailingAnchor))
            focusedConstraints.append(watchedIndicator.topAnchor.constraint(equalTo: imageView.focusedFrameGuide.topAnchor))
        }
    }
    
#endif
}
