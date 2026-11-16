import Foundation
import PopcornKit

/// What the Top Shelf shows, as plain values: made from the Home's snapshot
/// (`HomeSnapshot`), turned into TVServices objects by `ContentProvider`.
///
/// Pure — no TVServices, no clock, no bundle (the texts come through
/// `Texts`) — so the unit tests, a macOS bundle, run it on the recorded
/// answers of the Home.
///
/// The shelf is a showcase of what is new: the Home's hero first (recent
/// trending movies and shows, two movies for one show), then the newest
/// titles the hero does not already show — the latest 4K releases, the
/// latest additions, the latest episodes aired — then the rest of the hero.
/// Full screen when the titles have a backdrop (`carousel`), rows of posters
/// when none has (`sections`).
///
/// The artwork is the whole screen, so only a real backdrop will do: the
/// one metahub serves (16:9, up to 3840 × 2160, no text on it). The
/// "background" YTS gives is a blurred still made for its site: a movie
/// only YTS knows is left out of the carousel.
struct TopShelfModel: Equatable {

    // MARK: - Values

    /// One title of the shelf.
    struct Card: Equatable {
        /// Unique in the shelf: the card's id in the Home ("tt1234567", or
        /// "tt1234567:2:5" for an episode).
        var id: String
        /// A movie, or a show (an episode's card is its show's).
        var kind: HomeItem.Kind
        var title: String
        /// Why it is there, in the user's language ("Films tendance",
        /// "Nouvel épisode").
        var context: String?
        var summary: String?
        /// The first genre, in the user's language.
        var genre: String?
        /// An episode: the day it aired. A movie or a show: its year (the
        /// middle of it: a first of January is the year before west of
        /// Greenwich).
        var date: Date?
        var duration: TimeInterval?
        var formats: Formats = []
        /// At most four ("Nouvel épisode": "S2 · É5", its title; "IMDb":
        /// "7,8"): a name, dimmed, then its values.
        var attributes: [Attribute] = []
        /// 16:9, full screen: a backdrop of the artwork host, nil when the
        /// page knows none for the title.
        var wideImage: URL?
        /// 2:3.
        var posterImage: URL?
        /// `popcorntime://play/…`: the page, then playback.
        var play: URL
        /// `popcorntime://movie/…` or `show/…`: the page.
        var display: URL

        /// The summary under its title, for a system that does not show the
        /// title itself: since tvOS 26 the details of a carousel card are
        /// its summary, its genre, year, duration and badges, its attributes
        /// and the two buttons — the title and the context are not drawn.
        var titledSummary: String {
            guard let summary = summary, !summary.isEmpty else { return title }
            return title + "\n" + summary
        }
    }

    struct Attribute: Equatable {
        var name: String
        var values: [String]
    }

    /// The formats a title has a release in: the badges of the Home's card.
    struct Formats: OptionSet, Equatable {
        let rawValue: Int
        static let uhd = Formats(rawValue: 1 << 0)
        static let hdr = Formats(rawValue: 1 << 1)
        static let dolbyVision = Formats(rawValue: 1 << 2)
        static let atmos = Formats(rawValue: 1 << 3)
    }

    /// A row of the sectioned shelf.
    struct Section: Equatable {
        /// The Home's shelf it is made of (`HomeShelfID`).
        var id: String
        var title: String
        var cards: [Card]
    }

    /// The full-screen carousel: the cards that have a backdrop. Empty when
    /// none has one.
    var carousel: [Card] = []
    /// The rows of posters shown instead of an empty carousel.
    var sections: [Section] = []

    /// Nothing to show: the system then shows the app's static image.
    var isEmpty: Bool {
        return carousel.isEmpty && sections.isEmpty
    }

    // MARK: - Texts and rules

    /// The words of the shelf. The extension reads them in the app's strings
    /// (`Texts.app`); the tests give their own.
    struct Texts {
        /// A key of the app's Localizable.strings → its text.
        var localize: (String) -> String
        /// Formats the numbers.
        var locale: Locale

        init(localize: @escaping (String) -> String, locale: Locale) {
            self.localize = localize
            self.locale = locale
        }

        /// The app's strings (the extension ships the same Localizable.strings),
        /// the user's formats.
        static var app: Texts {
            return Texts(localize: { $0.localized }, locale: .current)
        }
    }

    struct Rules {
        /// Cards in the carousel.
        var limit = 10
        /// The hero's cards that come first; the newest titles take the
        /// places left, with the rest of the hero when they are too few.
        var heroCount = 6
        /// "About two movies for one show", as in the hero.
        var moviesPerShow = 2
        /// Cards in a row of the sectioned shelf.
        var sectionLimit = 12

        init() {}
    }

    /// Every key `Texts.localize` is asked: the app's strings have them all.
    static let localizationKeys: [String] = [
        HomeShelfID.trendingMovies, HomeShelfID.trendingShows, HomeShelfID.newMovies, HomeShelfID.uhd, HomeShelfID.airedEpisodes,
    ].map(HomeShelfID.defaultTitle) + HomeBadge.allCases.compactMap(\.localizationKey)
        + [episodeKey, episodeNumberKey, "Science Fiction", "Sports"]

    /// "Episode": the name of the attribute that tells which one.
    fileprivate static let episodeKey = "Episode"
    /// "S%lld · E%lld": season, then episode.
    fileprivate static let episodeNumberKey = "S%lld · E%lld"
    /// The rating's attribute: a name, not a word to translate.
    fileprivate static let ratingName = "IMDb"

    // MARK: - From the Home

    init(carousel: [Card] = [], sections: [Section] = []) {
        self.carousel = carousel
        self.sections = sections
    }

    init(snapshot: HomeSnapshot, texts: Texts, rules: Rules = Rules()) {
        let maker = Maker(snapshot: snapshot, texts: texts)

        // The hero is ordered already (two movies for one show).
        let hero = snapshot.heroItems.compactMap { item in
            maker.card(item, shelf: item.kind == .movie ? HomeShelfID.trendingMovies : HomeShelfID.trendingShows)
        }
        var seen = Set<String>()
        func fresh(_ cards: [Card]) -> [Card] {
            // A title once: a show of the hero is not shown again by its
            // latest episode, nor a movie by its 4K release.
            return cards.filter { $0.wideImage != nil && seen.insert(TopShelfModel.titleId($0.id)).inserted }
        }
        let lead = fresh(Array(hero.prefix(max(rules.heroCount, 0))))
        // Then the newest — 4K releases and additions in turn, the latest
        // episodes — and, where they are too few, what is left of the hero:
        // still two movies for one show.
        let rest = hero.dropFirst(max(rules.heroCount, 0))
        let movies = fresh(TopShelfModel.alternating(maker.cards(of: HomeShelfID.uhd), maker.cards(of: HomeShelfID.newMovies))
                           + rest.filter { $0.kind == .movie })
        let shows = fresh(maker.cards(of: HomeShelfID.airedEpisodes) + rest.filter { $0.kind == .show })
        let tail = TopShelfModel.mixed(movies: movies, shows: shows, moviesPerShow: rules.moviesPerShow)
        carousel = Array((lead + tail).prefix(max(rules.limit, 0)))

        // No backdrop at all: rows of posters — the new movies and the
        // latest episodes, the trending titles when a row would be empty.
        guard carousel.isEmpty else { return }
        var listed = Set<String>()
        for row in [[HomeShelfID.newMovies, HomeShelfID.trendingMovies], [HomeShelfID.airedEpisodes, HomeShelfID.trendingShows]] {
            for id in row {
                // An id once in the whole shelf: the system asks for it.
                let cards = maker.cards(of: id).filter { $0.posterImage != nil && !listed.contains($0.id) }.prefix(max(rules.sectionLimit, 0))
                guard !cards.isEmpty else { continue }
                listed.formUnion(cards.map(\.id))
                sections.append(Section(id: id, title: texts.localize(HomeShelfID.defaultTitle(id)), cards: Array(cards)))
                break
            }
        }
    }

    /// The IMDb id of a card's title ("tt1:2:5" → "tt1").
    private static func titleId(_ id: String) -> String {
        return id.split(separator: ":").first.map(String.init) ?? id
    }

    /// One of each in turn; what is left of the longer one at the end.
    private static func alternating(_ first: [Card], _ second: [Card]) -> [Card] {
        var cards: [Card] = []
        cards.reserveCapacity(first.count + second.count)
        for index in 0..<max(first.count, second.count) {
            if index < first.count { cards.append(first[index]) }
            if index < second.count { cards.append(second[index]) }
        }
        return cards
    }

    /// `moviesPerShow` movies, then a show, and so on; when one kind runs
    /// out the other goes on alone.
    private static func mixed(movies: [Card], shows: [Card], moviesPerShow: Int) -> [Card] {
        var movies = movies[...], shows = shows[...]
        var cards: [Card] = []
        cards.reserveCapacity(movies.count + shows.count)
        let cycle = max(moviesPerShow, 0) + 1
        while !(movies.isEmpty && shows.isEmpty) {
            let wantsShow = cards.count % cycle == cycle - 1
            if let next = (wantsShow ? shows.popFirst() : movies.popFirst()) ?? movies.popFirst() ?? shows.popFirst() {
                cards.append(next)
            }
        }
        return cards
    }
}

// MARK: - Cards

/// Makes the cards of one snapshot.
private struct Maker {
    let snapshot: HomeSnapshot
    let texts: TopShelfModel.Texts
    /// The backdrop metahub serves for a title, when a card of the page has
    /// it: Cinemeta's catalogs list it, and a show of the TV schedules has
    /// it by its IMDb id. A movie YTS alone lists has none here.
    let backdrops: [String: URL]
    /// The latest episode aired of the shows that have one on the page: a
    /// show's card says which one its "New Episode" is.
    let latestEpisodes: [String: HomeEpisode]
    private let rating: NumberFormatter

    init(snapshot: HomeSnapshot, texts: TopShelfModel.Texts) {
        self.snapshot = snapshot
        self.texts = texts
        var backdrops: [String: URL] = [:]
        for item in snapshot.shelves.flatMap(\.items) where backdrops[item.imdbId] == nil {
            if let url = item.backdropURL, url.host == Maker.artworkHost { backdrops[item.imdbId] = url }
        }
        self.backdrops = backdrops
        var latestEpisodes: [String: HomeEpisode] = [:]
        for item in snapshot.shelf(HomeShelfID.airedEpisodes)?.items ?? [] where latestEpisodes[item.imdbId] == nil {
            latestEpisodes[item.imdbId] = item.episode
        }
        self.latestEpisodes = latestEpisodes
        rating = NumberFormatter()
        rating.locale = texts.locale
        rating.numberStyle = .decimal
        rating.minimumFractionDigits = 1
        rating.maximumFractionDigits = 1
    }

    private static let artworkHost = "images.metahub.space"

    func cards(of shelf: String) -> [TopShelfModel.Card] {
        return (snapshot.shelf(shelf)?.items ?? []).compactMap { card($0, shelf: shelf) }
    }

    /// The card of a Home card; nil when no link opens it (an id that is not
    /// an IMDb title id) or it has no title.
    func card(_ item: HomeItem, shelf: String) -> TopShelfModel.Card? {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = episode(of: item)
        let display: DeepLink, play: DeepLink
        switch item.kind {
        case .movie:
            display = .movie(id: item.imdbId, title: title)
            play = .movie(id: item.imdbId, title: title, play: true)
        case .show:
            // A card about an episode opens the show on that season, and
            // plays that episode — the one it shows; a show's card that names
            // none plays what its page would.
            display = .show(id: item.imdbId, title: title, season: shown?.season, episode: shown?.number)
            play = .show(id: item.imdbId, title: title, season: shown?.season, episode: shown?.number, play: true)
        }
        guard !title.isEmpty, let displayURL = display.url, let playURL = play.url else { return nil }

        var card = TopShelfModel.Card(id: item.id, kind: item.kind, title: title, play: playURL, display: displayURL)
        // The editorial badge says more than the shelf ("New Episode" on a
        // trending show).
        let context = item.badges.first { !$0.isFormat }.flatMap(label) ?? texts.localize(HomeShelfID.defaultTitle(shelf))
        card.context = context
        card.summary = item.summary.flatMap { $0.isEmpty ? nil : $0 }
        card.genre = item.genres.first.map(genre)
        card.date = shown?.airDate ?? item.year.flatMap(Maker.middle(ofYear:))
        card.duration = item.runtimeMinutes.flatMap { $0 > 0 ? TimeInterval($0 * 60) : nil }
        card.formats = Maker.formats(item.badges)
        card.attributes = attributes(item, episode: shown, context: context)
        // The show's backdrop, not the episode's still: a still is small,
        // often missing on its host, and may give the episode away.
        card.wideImage = backdrops[item.imdbId]
        card.posterImage = item.posterURL
        return card
    }

    /// The badge in the user's language; the English text when the strings
    /// have no entry for it, never the raw key.
    private func label(_ badge: HomeBadge) -> String? {
        guard let key = badge.localizationKey else { return nil }
        let text = texts.localize(key)
        return text == key ? badge.label : text
    }

    /// Cinemeta and YTS name the genres in English, two of them differently
    /// from the app's own names — the ones the strings translate.
    private func genre(_ name: String) -> String {
        switch name {
        case "Sci-Fi": return texts.localize("Science Fiction")
        case "Sport": return texts.localize("Sports")
        default: return texts.localize(name)
        }
    }

    /// The episode a card is about: an episode's card's; for a show's card
    /// whose badge announces an episode, the latest one aired. The card says
    /// it and its links name it, so Play plays what the card shows.
    private func episode(of item: HomeItem) -> HomeEpisode? {
        if let episode = item.episode { return episode }
        let announced = item.badges.contains { [.newEpisode, .newSeason, .premiere].contains($0) }
        return item.kind == .show && announced ? latestEpisodes[item.imdbId] : nil
    }

    /// The episode a card is about, under the reason it is there ("New
    /// Episode": "S2 · E5", its title), then the rating.
    private func attributes(_ item: HomeItem, episode: HomeEpisode?, context: String) -> [TopShelfModel.Attribute] {
        var attributes: [TopShelfModel.Attribute] = []
        if let episode = episode {
            let number = String(format: texts.localize(TopShelfModel.episodeNumberKey), locale: texts.locale, episode.season, episode.number)
            let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // "Episode 7" is what the sources call an episode without a title.
            let isName = !title.isEmpty && title.range(of: #"^(episode|épisode)\s*#?\d+$"#, options: [.regularExpression, .caseInsensitive]) == nil
            // The badge when the card has one; "Episode" under a shelf's title.
            let name = item.badges.contains { !$0.isFormat } ? context : texts.localize(TopShelfModel.episodeKey)
            attributes.append(TopShelfModel.Attribute(name: name, values: isName ? [number, title] : [number]))
        }
        if let value = item.rating, value > 0, let text = rating.string(from: NSNumber(value: value)) {
            attributes.append(TopShelfModel.Attribute(name: TopShelfModel.ratingName, values: [text]))
        }
        return attributes
    }

    private static func formats(_ badges: [HomeBadge]) -> TopShelfModel.Formats {
        var formats: TopShelfModel.Formats = []
        for badge in badges {
            switch badge {
            case .uhd: formats.insert(.uhd)
            case .hdr: formats.insert(.hdr)
            case .dolbyVision: formats.insert(.dolbyVision)
            case .atmos: formats.insert(.atmos)
            default: break
            }
        }
        return formats
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }()

    private static func middle(ofYear year: Int) -> Date? {
        guard (1880...2200).contains(year) else { return nil }
        return utc.date(from: DateComponents(year: year, month: 7, day: 1, hour: 12))
    }
}
