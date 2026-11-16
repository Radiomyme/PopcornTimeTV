// HomeCardText.swift — what the Home's cards, hero and shelves say in words
// (iOS and macOS). No SwiftUI: the strings table, the locale and the clock
// are given, so the unit tests read the lines a French or an English user
// sees. The views draw; the wording is decided here.
import Foundation
import NaturalLanguage
import PopcornKit

struct HomeCardText {
    /// The app's strings table (`String.localized`); the tests pass their own.
    var localize: (String) -> String = { $0.localized }
    /// The numbers', durations' and dates' locale.
    var locale: Locale = .current
    var calendar: Calendar = .current
    var now: () -> Date = Date.init

    // MARK: Shelves

    /// "Films tendance", "Films : Horreur" (a genre shelf's title is a
    /// format whose argument is the genre, localised too).
    func title(of shelf: HomeShelf) -> String {
        let title = localize(shelf.defaultTitle)
        guard let genre = shelf.titleArgument else { return title }
        return String(format: title, localize(genre))
    }

    // MARK: Pieces

    /// "8,1" (IMDb, one decimal, the locale's separator); nil when unrated.
    func rating(of item: HomeItem) -> String? {
        guard let rating = item.rating, rating > 0 else { return nil }
        return rating.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// "42 min", "2 h 14 min"; nil under a minute.
    func duration(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .condensedAbbreviated).locale(locale)
        return Duration.seconds(minutes * 60).formatted(style)
    }

    /// "S2 · É5".
    func number(of episode: HomeEpisode) -> String {
        String(format: localize("S%lld · E%lld"), episode.season, episode.number)
    }

    /// A genre as the sources name it, in the app's language ("Sci-Fi" is
    /// the app's "Science Fiction", which the strings translate).
    func genre(_ name: String) -> String {
        switch name {
        case "Sci-Fi": return localize("Science Fiction")
        case "Sport": return localize("Sports")
        default: return localize(name)
        }
    }

    /// When an episode aired, or airs: "aujourd’hui", "hier", "demain", the
    /// day with its weekday within a week ("ven. 13 nov.": a bare "vendredi"
    /// does not say whether it is past or to come), else the day ("3 nov.").
    /// Counted in calendar days, not in hours: an episode of last night is
    /// yesterday's.
    func day(_ date: Date) -> String {
        let today = calendar.startOfDay(for: now())
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case -1...1:
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            return formatter.localizedString(from: DateComponents(day: days))
        case -6...6:
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).weekday(.abbreviated).day().month(.abbreviated))
        default:
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).day().month(.abbreviated))
        }
    }

    // MARK: Cards

    /// Under a poster: "8,1 · 2026" — how good, then how recent. The star
    /// that goes with the rating is the view's.
    func posterFacts(of item: HomeItem) -> (rating: String?, year: String?) {
        (rating(of: item), item.year.map { String($0) })
    }

    /// Under a 16:9 card, second line. A resume card says where the user
    /// was: "Il reste 42 min" for a movie, "S2 · É5 · Il reste 23 min" for
    /// an episode, "Épisode suivant · S2 · É6" once the last one was
    /// finished. An episode card says which episode and when: "S2 · É5 ·
    /// hier".
    func landscapeDetail(of item: HomeItem) -> String {
        if let progress = item.progress {
            let left = item.remainingMinutes.flatMap { duration(minutes: $0) }
                .map { String(format: localize("Home.Card.Remaining"), $0) }
            guard let episode = item.episode else { return left ?? "" }
            // Nothing played of it yet: the episode that follows the one
            // just finished.
            if progress <= 0 {
                return [localize("ContinueWatching.NextEpisode"), number(of: episode)].joined(separator: " · ")
            }
            return [number(of: episode), left].compactMap { $0 }.joined(separator: " · ")
        }
        guard let episode = item.episode else {
            return [item.year.map { String($0) }, rating(of: item).map { "★ \($0)" }].compactMap { $0 }.joined(separator: " · ")
        }
        return [number(of: episode), episode.airDate.map(day)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Under a 16:9 card, first line: the title — of the show, for an
    /// episode.
    func landscapeTitle(of item: HomeItem) -> String {
        item.title
    }

    // MARK: Hero

    /// "Film · 2026 · 2 h 14 min · Action, Aventure": what it is, from
    /// when, how long (a movie), which kind.
    ///
    /// - Parameter genres: how many genres at most (a compact screen has
    ///   room for one).
    func heroFacts(of item: HomeItem, genres limit: Int = 2) -> String {
        var parts = [localize(item.kind == .movie ? "Home.Kind.Movie" : "Home.Kind.Show")]
        if let year = item.year { parts.append(String(year)) }
        if item.kind == .movie, let runtime = duration(minutes: item.runtimeMinutes) { parts.append(runtime) }
        let genres = item.genres.prefix(max(limit, 0)).map(genre)
        if !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Offline

    /// Under "Vous êtes hors ligne": "Contenu enregistré il y a 3 heures."
    /// Nil when nothing says how old the page is.
    func offlineDetail(lastUpdated: Date?) -> String? {
        guard let lastUpdated else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        // Never "in 2 seconds" for a list saved a moment ago on another clock.
        let saved = min(lastUpdated, now())
        return String(format: localize("Home.Offline.Saved"), formatter.localizedString(for: saved, relativeTo: now()))
    }

    // MARK: Badges

    /// The pill of a small card: the format names in their short form
    /// ("DV", "ATMOS"), as on a disc's case; the editorial ones in the app's
    /// language, in capitals.
    func cardLabel(of badge: HomeBadge) -> String {
        switch badge {
        case .dolbyVision: return "DV"
        case .atmos: return "ATMOS"
        case .uhd, .hdr: return badge.label
        default: return label(of: badge).uppercased(with: locale)
        }
    }

    /// A badge in full: "Dolby Vision", "Nouvel épisode" (the hero's chips,
    /// VoiceOver). The English text when the language has no entry, never
    /// the key.
    func label(of badge: HomeBadge) -> String {
        guard let key = badge.localizationKey else { return badge.label }
        let text = localize(key)
        return text == key ? badge.label : text
    }

    /// The first editorial badge of a card ("Nouveau", "Nouvel épisode"…):
    /// one pill on the artwork is read at a glance, two are not.
    func editorialBadge(of item: HomeItem) -> HomeBadge? {
        item.badges.first { !$0.isFormat }
    }

    /// The format badges, best first, at most `limit` (a 124-point poster
    /// has room for three).
    func formatBadges(of item: HomeItem, limit: Int = 3) -> [HomeBadge] {
        Array(item.badges.filter(\.isFormat).prefix(limit))
    }

    /// The formats under a poster, short: the two best (`HomeBadge.cardFormats`:
    /// "DV" says HDR too, then 4K, then "ATMOS"), in the cards' order —
    /// the same in every row, grid and search, whatever the list.
    func compactFormats(of item: HomeItem) -> [String] {
        HomeBadge.cardFormats(item.badges).map(cardLabel(of:))
    }

    // MARK: Synopsis

    /// The synopsis the hero shows: only one in the app's language. The
    /// sources write in English; an English text under a French interface
    /// is left out rather than shown as the page's voice.
    func heroSynopsis(of item: HomeItem) -> String? {
        guard let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        let app = locale.language.languageCode?.identifier ?? "en"
        guard app != "en" else { return summary }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(summary)
        return recognizer.dominantLanguage?.rawValue == app ? summary : nil
    }

    /// "Episode 2", "Episode #1.2", "": a source's placeholder for an
    /// episode it has no title for.
    static func isGenericEpisodeTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.range(of: #"^Episode\s*#?[\d.]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: VoiceOver

    /// "Project Hail Mary, 2026, note 8,1, Nouveau, 4K, Dolby Vision": the
    /// title, the year, the rating, the badges — and, first, the rank of a
    /// ranked card, the episode and what is left of a resume card.
    func accessibilityLabel(of item: HomeItem) -> String {
        var parts: [String] = []
        if let rank = item.rank { parts.append(String(format: localize("Home.Card.Rank"), rank)) }
        parts.append(item.title)
        if let episode = item.episode {
            parts.append([localize("Season") + " \(episode.season)", localize("Episode") + " \(episode.number)"].joined(separator: ", "))
            if let title = episode.title, !title.isEmpty, !HomeCardText.isGenericEpisodeTitle(title) { parts.append(title) }
            if item.progress == nil, let aired = episode.airDate { parts.append(day(aired)) }
        } else if let year = item.year {
            parts.append(String(year))
        }
        if let progress = item.progress {
            if progress <= 0, item.episode != nil {
                parts.append(localize("ContinueWatching.NextEpisode"))
            } else if let left = item.remainingMinutes.flatMap({ duration(minutes: $0) }) {
                parts.append(String(format: localize("Home.Card.Remaining"), left))
            }
        }
        if let rating = rating(of: item) { parts.append(String(format: localize("Home.Card.Rating"), rating)) }
        // The full names here: "DV" is read letter by letter.
        parts += item.badges.map(label(of:))
        return parts.joined(separator: ", ")
    }
}

/// What a list leaves off its cards (`homeHiddenBadges`): the editorial
/// pill its title already says ("NOUVEAU" in Nouveaux films, "NOUVEL
/// ÉPISODE" in Derniers épisodes). Never a format, not even 4K in
/// Nouveautés 4K or in a grid of 4K films: a card names the same formats
/// in every list.
enum HomeListBadges {
    static func hidden(shelfID: String? = nil, items: [HomeItem] = []) -> Set<HomeBadge> {
        var hidden: Set<HomeBadge> = []
        if let shelfID {
            if [HomeShelfID.newMovies, HomeShelfID.newShows].contains(shelfID) { hidden.insert(.new) }
            if [HomeShelfID.yourShows, HomeShelfID.airedEpisodes].contains(shelfID) { hidden.insert(.newEpisode) }
        }
        return hidden
    }
}
