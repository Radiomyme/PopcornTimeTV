// PosterCardText.swift — a `PosterCard` in words: the line under the focused
// poster and what VoiceOver reads on any poster. Numbers, durations and
// counts are formatted by the system in the user's language.
import UIKit
import PopcornKit

enum PosterCardText {

    // MARK: Pieces

    private static let ratingFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// "2 h 36 min left", in the user's language.
    private static let remainingFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        formatter.includesTimeRemainingPhrase = true
        return formatter
    }()

    /// "8.4" / "8,4".
    static func rating(_ value: Double) -> String {
        return ratingFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// "2 hr, 36 min": the detail page's format
    /// (`GlassDetailAdapter.runtime`), with a formatter kept (the caption
    /// is made at every move of the focus).
    private static let runtimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.hour, .minute]
        return formatter
    }()

    static func runtime(_ minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        return runtimeFormatter.string(from: TimeInterval(minutes) * 60)
    }

    static func seasons(_ count: Int) -> String {
        return count == 1 ? String(localized: "1 Season") : String(localized: "\(count) Seasons")
    }

    /// What is left of a started movie; nil for a show (the progress is an
    /// episode's), an unknown runtime or less than a minute.
    static func remaining(_ card: PosterCard) -> String? {
        guard let progress = card.progress, card.seasons == nil, let minutes = card.runtimeMinutes else { return nil }
        let seconds = (Double(minutes) * 60 * (1 - progress)).rounded()
        guard seconds >= 60 else { return nil }
        return remainingFormatter.string(from: seconds)
    }

    /// A show says its seasons when the list knows them, else an episode's
    /// length; a movie, its length — or what is left of it once started.
    private static func length(_ card: PosterCard) -> String? {
        if let seasons = card.seasons { return PosterCardText.seasons(seasons) }
        if let remaining = remaining(card) { return remaining }
        return card.runtimeMinutes.flatMap(runtime)
    }

    /// The marks, spelled: "4K", "New", "New Episode", then "Watched" and
    /// "In Watchlist" (the library's).
    static func marks(_ card: PosterCard) -> [String] {
        var marks = card.badges.map { $0.localizedLabel }
        if card.isWatched { marks.append("Watched".localized) }
        if card.isInWatchlist { marks.append("In Watchlist".localized) }
        return marks
    }

    // MARK: Line of facts

    /// The formats in a few characters, as every card of the app names
    /// them (`HomeBadge.cardFormats`: the two best, Dolby Vision before
    /// HDR, 4K, Atmos): "4K · DV". Dolby Vision says HDR too.
    static func formats(_ badges: [HomeBadge], limit: Int = 2) -> String? {
        let names = HomeBadge.cardFormats(badges, limit: limit).compactMap { badge -> String? in
            switch badge {
            case .uhd: return "4K"
            case .dolbyVision: return "DV"
            case .hdr: return "HDR"
            case .atmos: return "Atmos"
            default: return nil
            }
        }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    /// Under every poster, the Home card's pattern: "2026 · ★ 8,0 · 4K · DV";
    /// what is not known is left out.
    static func meta(_ card: PosterCard) -> NSAttributedString {
        let font = GridStyle.metaFont
        let secondary: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: GridStyle.secondaryText]
        let separator = NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: GridStyle.tertiaryText])
        var parts: [NSAttributedString] = []
        if let year = card.year { parts.append(NSAttributedString(string: String(year), attributes: secondary)) }
        if let rating = card.rating {
            let part = NSMutableAttributedString(attachment: metaStarAttachment)
            part.append(NSAttributedString(string: "\u{00A0}" + PosterCardText.rating(rating),
                                           attributes: [.font: font, .foregroundColor: UIColor(white: 1, alpha: 0.86)]))
            parts.append(part)
        }
        if let formats = formats(card.badges) { parts.append(NSAttributedString(string: formats, attributes: secondary)) }
        let line = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { line.append(separator) }
            line.append(part)
        }
        return line
    }

    private static let metaStarAttachment: NSTextAttachment = {
        let attachment = NSTextAttachment()
        let configuration = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        let image = UIImage(systemName: "star.fill", withConfiguration: configuration)?
            .withTintColor(GridStyle.star, renderingMode: .alwaysOriginal)
        attachment.image = image
        if let size = image?.size {
            attachment.bounds = CGRect(x: 0, y: (GridStyle.metaFont.capHeight - size.height) / 2, width: size.width, height: size.height)
        }
        return attachment
    }()

    // MARK: Caption

    /// The focused poster's title, under its line of facts: what the
    /// poster does not say at rest, and nothing it already says — nothing
    /// for a working title ("Untitled …"): the poster prints the title.
    static func title(_ card: PosterCard, title: String? = nil) -> NSAttributedString {
        let shown = HomeTitleFacts.isPlaceholder(card.title) ? "" : title ?? card.title
        return NSAttributedString(string: shown, attributes: [
            .font: GridStyle.captionTitleFont, .foregroundColor: GridStyle.primaryText,
        ])
    }

    /// "Project Hail Mary   2026 · ★ 8,4 · 2 h 36 min  [4K] [NEW]" on one line.
    /// `title` replaces the card's when it had to be shortened to fit.
    static func caption(_ card: PosterCard, title: String? = nil) -> NSAttributedString {
        let line = NSMutableAttributedString(string: title ?? HomeTitleFacts.cardTitle(card.title), attributes: [
            .font: GridStyle.captionTitleFont, .foregroundColor: GridStyle.primaryText,
        ])
        let meta: [NSAttributedString.Key: Any] = [.font: GridStyle.captionMetaFont, .foregroundColor: GridStyle.secondaryText]
        var parts: [NSAttributedString] = []
        if let year = card.year { parts.append(NSAttributedString(string: String(year), attributes: meta)) }
        if let rating = card.rating {
            let part = NSMutableAttributedString(attachment: starAttachment)
            part.append(NSAttributedString(string: "\u{00A0}" + PosterCardText.rating(rating), attributes: meta))
            parts.append(part)
        }
        if let length = length(card) { parts.append(NSAttributedString(string: length, attributes: meta)) }
        for (index, part) in parts.enumerated() {
            line.append(NSAttributedString(string: index == 0 ? "    " : "  ·  ", attributes: meta))
            line.append(part)
        }
        // The pills of the title ("4K", "NOUVEAU") in capitals, the
        // library's ("Vu", "Dans ma liste") as they are written.
        let badges = card.badges.count
        for (index, mark) in marks(card).enumerated() {
            line.append(NSAttributedString(string: index == 0 ? "    " : "  ", attributes: meta))
            line.append(NSAttributedString(attachment: pillAttachment(index < badges ? mark.localizedUppercase : mark)))
        }
        return line
    }

    private static let starAttachment: NSTextAttachment = {
        let attachment = NSTextAttachment()
        let configuration = UIImage.SymbolConfiguration(pointSize: 19, weight: .bold)
        let image = UIImage(systemName: "star.fill", withConfiguration: configuration)?
            .withTintColor(GridStyle.star, renderingMode: .alwaysOriginal)
        attachment.image = image
        if let size = image?.size {
            // Centered on the digits of the metadata font.
            attachment.bounds = CGRect(x: 0, y: (GridStyle.captionMetaFont.capHeight - size.height) / 2, width: size.width, height: size.height)
        }
        return attachment
    }()

    private static func pillAttachment(_ text: String) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let image = GridPill.image(text, style: .outline, font: .systemFont(ofSize: 18, weight: .bold))
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (GridStyle.captionTitleFont.capHeight - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height)
        return attachment
    }

    // MARK: VoiceOver

    /// "Project Hail Mary, 2026, 8.4 out of 10, 2 hr, 36 min, 4K, New, 42 %".
    static func accessibilityLabel(_ card: PosterCard) -> String {
        var parts = [card.title]
        if let year = card.year { parts.append(String(year)) }
        if let rating = card.rating { parts.append(String(format: "%@ out of 10".localized, PosterCardText.rating(rating))) }
        if let length = length(card) { parts.append(length) }
        parts += marks(card)
        if let progress = card.progress, let percent = percentFormatter.string(from: NSNumber(value: progress)) {
            parts.append(percent)
        }
        return parts.joined(separator: ", ")
    }
}
