// HomePresentation.swift — what the Home tab says about a card and where it
// puts its rows: the texts (facts line, captions, VoiceOver labels) and the
// page's geometry. No SwiftUI and no singleton: the strings table and the
// locale are injected, so the unit tests (a macOS bundle) read the French
// strings file and check the wording the screen will show.
import Foundation
import CoreGraphics
import PopcornKit

// MARK: - Texts

/// One piece of the billboard's facts line ("2026 · Action, Aventure · ★ 7,8 · 1 h 41 min").
enum HomeFact: Hashable {
    case text(String)
    /// IMDb rating, already formatted ("7,8"): drawn with a star.
    case rating(String)

    var string: String {
        switch self {
        case .text(let text), .rating(let text): return text
        }
    }
}

/// The wording of the Home tab.
struct HomeText {
    /// Localizable.strings lookup (the key itself when there is no entry).
    var localize: (String) -> String = { $0.localized }
    /// Numbers, durations and dates are formatted for it.
    var locale: Locale = .current
    /// The words the sources give (synopses, episode titles) are in the
    /// app's language. Every source of the Home is English (Cinemeta,
    /// TVMaze, YTS: none has a localised synopsis); under another language
    /// the Home does not show them — three lines of English under a French
    /// interface — and says the episode by its number and date.
    var showsSourceText: Bool = HomeText.appLanguageIsEnglish

    /// The app's strings and the device's locale.
    static let standard = HomeText()

    /// The language the app's strings are shown in is English.
    static var appLanguageIsEnglish: Bool {
        return Bundle.main.preferredLocalizations.first.map { $0 == "en" || $0.hasPrefix("en-") || $0 == "Base" } ?? true
    }

    private func format(_ key: String, _ arguments: CVarArg...) -> String {
        return String(format: localize(key), locale: locale, arguments: arguments)
    }

    // MARK: Shelves

    /// "Films tendance", "Films : Horreur" (a genre shelf's title is a format).
    func title(of shelf: HomeShelf) -> String {
        return title(ofShelf: shelf.id, genre: shelf.titleArgument)
    }

    func title(ofShelf id: String, genre: String? = nil) -> String {
        let title = localize(HomeShelfID.defaultTitle(id))
        guard let genre = genre ?? HomeShelfID.genre(of: id).map({ self.appGenre($0.genre) }) else { return title }
        return title.replacingOccurrences(of: "%@", with: localize(genre))
    }

    // MARK: Pieces

    /// "7,8": one decimal, the locale's separator.
    func rating(_ value: Double) -> String {
        return value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// An episode's own title: nil for none, and for the placeholder some
    /// sources give an episode that has none yet ("Episode 9").
    /// nil too when the sources' words are not shown (`showsSourceText`).
    func title(of episode: HomeEpisode) -> String? {
        guard showsSourceText, let title = episode.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              title.caseInsensitiveCompare("Episode \(episode.number)") != .orderedSame else { return nil }
        return title
    }

    /// "S2 · É9".
    func episodeCode(_ episode: HomeEpisode) -> String {
        return format("S%lld · E%lld", Int64(episode.season), Int64(episode.number))
    }

    /// "1 h et 41 min" (the detail page's format); nil for nothing.
    func runtime(minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.hour, .minute]
        return formatter.string(from: TimeInterval(minutes) * 60)
    }

    /// "Il reste 33 min"; nil under a minute. The phrase is the app's own
    /// string: the system's "time remaining" phrase follows the process's
    /// language, not the locale asked.
    func remaining(minutes: Int) -> String? {
        return runtime(minutes: minutes).map { format("Home.Remaining", $0) }
    }

    /// "14 nov.".
    func day(_ date: Date) -> String {
        return date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }

    /// The app's name of a Cinemeta genre: the one the strings files translate.
    func appGenre(_ genre: String) -> String {
        switch genre {
        case "Sci-Fi": return "Science Fiction"
        case "Sport": return "Sports"
        default: return genre
        }
    }

    /// Up to `limit` genres, translated: "Action, Aventure".
    func genres(_ genres: [String], limit: Int = 2) -> String? {
        let names = genres.prefix(limit).map { localize(appGenre($0)) }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// A pill's text in the app's language ("Nouvel épisode"); a format's name as it is.
    func label(of badge: HomeBadge) -> String {
        guard let key = badge.localizationKey else { return badge.label }
        let text = localize(key)
        return text == key ? badge.label : text
    }

    /// The pill drawn on a card's artwork: what is new about it, if anything.
    /// In a shelf whose title says "new" (`shelfSaysNew`), "New" is not repeated on every card.
    func editorialBadge(of item: HomeItem, inShelf shelfID: String? = nil) -> String? {
        let saysNew = shelfID.map(shelfSaysNew) ?? false
        return item.badges.first { !$0.isFormat && !(saysNew && ($0 == .new || $0 == .newEpisode)) }.map(label(of:))
    }

    /// The formats of a card in a few characters, for the line under a
    /// poster: "4K · DV · Atmos". Dolby Vision says HDR too: HDR is only
    /// named without it (the billboard has the room for all of them).
    /// `limit`: the first ones only (a poster's line also has the year and
    /// the rating: "2026 · ★ 7,8 · 4K · DV").
    func formats(of item: HomeItem, limit: Int = .max) -> String? {
        let badges = item.badges
        let names = badges.compactMap { badge -> String? in
            switch badge {
            case .uhd: return "4K"
            case .dolbyVision: return "DV"
            case .hdr: return badges.contains(.dolbyVision) ? nil : "HDR"
            case .atmos: return "Atmos"
            default: return nil
            }
        }.prefix(limit)
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    /// The synopsis the billboard shows; nil when there is none, or when the
    /// sources' words are not shown (`showsSourceText`).
    func summary(of item: HomeItem) -> String? {
        guard showsSourceText, let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        return summary
    }

    /// A shelf whose title already says its titles are new: its cards do
    /// not say it again, one by one.
    /// ("Derniers épisodes diffusés" too: every card in it is a new episode.)
    func shelfSaysNew(_ shelfID: String) -> Bool {
        return shelfID == HomeShelfID.newMovies || shelfID == HomeShelfID.newShows || shelfID == HomeShelfID.airedEpisodes
    }

    // MARK: Billboard

    /// The billboard's line of facts. A title: year, genres, rating,
    /// runtime. An episode: its code, its title, the day it airs or aired,
    /// the show's rating. Empty pieces are left out.
    func facts(of item: HomeItem) -> [HomeFact] {
        var facts: [HomeFact] = []
        if let episode = item.episode {
            facts.append(.text(episodeCode(episode)))
            if let title = title(of: episode) { facts.append(.text(title)) }
            if let aired = episode.airDate { facts.append(.text(day(aired))) }
        } else {
            if let year = item.year { facts.append(.text(String(year))) }
            if let genres = genres(item.genres) { facts.append(.text(genres)) }
        }
        if let rating = item.rating, rating > 0 { facts.append(.rating(self.rating(rating))) }
        if item.episode == nil, let runtime = item.runtimeMinutes.flatMap(runtime(minutes:)) {
            facts.append(.text(runtime))
        }
        return facts
    }

    /// Where the user was: "Il reste 33 min" for a title in progress,
    /// "Épisode suivant" for a show whose last episode was finished.
    func progressNote(of item: HomeItem) -> String? {
        guard let progress = item.progress else { return nil }
        if progress > 0 { return item.remainingMinutes.flatMap(remaining(minutes:)) }
        return item.episode == nil ? nil : localize("ContinueWatching.NextEpisode")
    }

    // MARK: Cards

    /// The second line under a landscape card.
    /// - A title in progress: "Il reste 33 min"; an episode: "S2 · É9 · Il reste 33 min".
    /// - The next episode of a show: "Épisode suivant · S2 · É9".
    /// - An episode that aired or will: "S2 · É9 · Its Title", "S2 · É10 · 21 nov." when upcoming.
    func caption(of item: HomeItem) -> String {
        let code = item.episode.map(episodeCode)
        if let progress = item.progress {
            if progress > 0 {
                return [code, item.remainingMinutes.flatMap(remaining(minutes:))].compactMap { $0 }.joined(separator: " · ")
            }
            return [code == nil ? nil : localize("ContinueWatching.NextEpisode"), code].compactMap { $0 }.joined(separator: " · ")
        }
        guard let episode = item.episode else {
            return [item.year.map(String.init), genres(item.genres, limit: 1)].compactMap { $0 }.joined(separator: " · ")
        }
        if item.badges.contains(.upcoming), let aired = episode.airDate {
            return [code, day(aired)].compactMap { $0 }.joined(separator: " · ")
        }
        // No title of its own: the day it aired instead.
        return [code, title(of: episode) ?? episode.airDate.map(day)].compactMap { $0 }.joined(separator: " · ")
    }

    /// What VoiceOver reads on a card: title, episode, year, rating, pills, progress.
    func accessibilityLabel(of item: HomeItem) -> String {
        var parts: [String] = []
        if let rank = item.rank { parts.append(String(rank)) }
        parts.append(item.title)
        if let episode = item.episode {
            parts.append(episodeCode(episode))
            if let title = title(of: episode) { parts.append(title) }
        } else if let year = item.year {
            parts.append(String(year))
        }
        if let rating = item.rating, rating > 0 { parts.append(format("Home.Rating", self.rating(rating))) }
        parts += item.badges.map(label(of:))
        if let note = progressNote(of: item) { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Watched

extension HomeItem {
    /// What "watched" is about for a card: the movie, or the card's episode.
    /// A show's card without an episode has nothing to mark.
    var watchedID: String? {
        if kind == .movie { return imdbId }
        return episode.map { LibraryID.episodeID(showID: imdbId, EpisodeNumber(season: $0.season, episode: $0.number)) }
    }

    /// The card's episode has aired (a movie, or a show's card without an
    /// episode, has). An "Upcoming" card, or one whose air date is still to
    /// come — or unknown on an Upcoming card — is not offered "Mark as
    /// Watched": the library's next-episode rule would then skip it, in
    /// Continue Watching and in the new episodes once it airs.
    func hasAired(now: Date = Date()) -> Bool {
        if badges.contains(.upcoming) { return false }
        if let aired = episode?.airDate, aired > now { return false }
        return true
    }
}

// MARK: - See All

extension HomeSeeAll {
    /// The tab whose grid a shelf's "See All" opens.
    var tab: DeepLink.Tab {
        switch catalogue {
        case .movies: return .movies
        case .shows: return .shows
        case .watchlist: return .watchlist
        }
    }
}

// MARK: - Geometry

/// The Home page on a 1920 × 1080 screen: one grid for every row. The sizes
/// are fixed: a placeholder has the size of what replaces it, and a shelf
/// never changes height once on screen.
enum TVHomeLayout {
    /// The rows start on the page's left margin (the detail page's).
    static let side: CGFloat = 90
    /// What shows of the first shelf under the billboard, at the top of the page.
    static let heroPeek: CGFloat = 196
    /// The band the billboard keeps at the top of the screen once the focus
    /// is in the shelves: the focused shelf's title starts right under it.
    static let compactBand: CGFloat = 376
    /// The band without the synopsis's two lines (`HomeText.showsSourceText`
    /// off: the app is not in English): it ends a little under the facts
    /// line, and the shelves come up instead of leaving a dark void.
    static let compactBandWithoutSynopsis: CGFloat = 300

    static func compactBand(showsSynopsis: Bool) -> CGFloat {
        return showsSynopsis ? compactBand : compactBandWithoutSynopsis
    }
    /// The same band while the tab bar is on screen (a page without a hero).
    static let tabBarBand: CGFloat = 130

    static let titleHeight: CGFloat = 50
    static let rowTopPadding: CGFloat = 18
    /// Room above and under the cards for the focused card's lift.
    static let cardPadding: CGFloat = 26

    struct Card: Equatable {
        var width: CGFloat
        var height: CGFloat
        var spacing: CGFloat
        /// The lines of text under the card.
        var caption: CGFloat
    }

    static let poster = Card(width: 240, height: 360, spacing: 44, caption: 52)
    static let landscape = Card(width: 400, height: 225, spacing: 40, caption: 90)
    /// A ranked poster with its numeral on its left: the width is the one
    /// of a card with a one-digit rank (`rankZone` + the poster).
    static let ranked = Card(width: 340, height: 330, spacing: 14, caption: 52)
    static let rankedPosterWidth: CGFloat = 220
    /// How far the numeral goes under its poster.
    static let rankOverlap: CGFloat = 34

    /// The room a rank's numeral takes on the left of its poster.
    static func rankZone(of rank: Int) -> CGFloat {
        return rank >= 10 ? 206 : 120
    }

    static func card(of style: HomeShelf.Style) -> Card {
        switch style {
        case .landscape: return landscape
        case .ranked: return ranked
        case .posters, .hero: return poster
        }
    }

    /// Title, cards, caption: the whole row.
    static func rowHeight(of style: HomeShelf.Style) -> CGFloat {
        let card = card(of: style)
        return rowTopPadding + titleHeight + cardPadding + card.height + card.caption + cardPadding
    }

    /// The height of the billboard at the top of the page.
    static func heroHeight(viewport: CGFloat) -> CGFloat {
        return max(viewport - heroPeek, compactBand)
    }

    /// The `UnitPoint.y` that puts a row's top `band` points under the top
    /// of a `viewport` high scroll view: `ScrollViewProxy.scrollTo` aligns
    /// the point at that fraction of the row with the point at the same
    /// fraction of the scroll view.
    static func anchor(band: CGFloat, rowHeight: CGFloat, viewport: CGFloat) -> CGFloat {
        let free = viewport - rowHeight
        guard free > 0 else { return 0 }
        return min(max(band / free, 0), 1)
    }

    /// What must follow the last row for it to reach the band.
    static func bottomPadding(viewport: CGFloat, band: CGFloat = compactBandWithoutSynopsis) -> CGFloat {
        let shortest = [HomeShelf.Style.posters, .landscape, .ranked].map(rowHeight(of:)).min() ?? 0
        return max(viewport - band - shortest, 0) + 40
    }

    /// How much of the first card that does not fit shows at the right edge
    /// of a row at rest (0: the row ends exactly on a card or a gap).
    static func sliver(of card: Card, viewport: CGFloat) -> CGFloat {
        var leading = side
        while leading + card.width <= viewport { leading += card.width + card.spacing }
        return max(viewport - leading, 0)
    }
}
