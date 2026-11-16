import Foundation

/// The model of the "Home / What's New" hub: shelves of cards, the same on
/// tvOS, iOS, macOS and in the Top Shelf extension.
///
/// Plain values (Codable, Hashable, Sendable; no ObjectMapper): they are
/// what the disk cache stores and what the views diff. A card is not a
/// `Movie` / `Show`: it carries what a card shows, and `HomeItem.movie` /
/// `HomeItem.show` (HomeItem+Media.swift) make the object a detail page opens.

// MARK: - Card

/// One card of a shelf: a movie, a show, or an episode of a show.
public struct HomeItem: Codable, Hashable, Sendable, Identifiable {

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case movie
        case show
    }

    /// Unique in its shelf: the IMDb id of a title card, "tt…:season:episode"
    /// of an episode card.
    public var id: String
    /// IMDb id of the movie or of the show ("tt1234567").
    public var imdbId: String
    public var kind: Kind
    public var title: String
    public var year: Int?
    /// IMDb rating, 0…10 (nil: not rated yet).
    public var rating: Double?
    public var genres: [String]
    public var summary: String?
    public var runtimeMinutes: Int?
    /// 2:3 poster.
    public var posterURL: URL?
    /// 16:9 backdrop.
    public var backdropURL: URL?
    /// Transparent title logo (PNG). Only set when the source lists one; the
    /// image can still be missing (a 404): fall back to the title in text.
    public var logoURL: URL?
    /// YouTube id of the trailer.
    public var trailerCode: String?
    public var badges: [HomeBadge]
    /// Position in a ranked shelf, from 1.
    public var rank: Int?
    /// The episode of an episode card (latest aired, next to watch…).
    public var episode: HomeEpisode?
    /// What the shelf sorts by: added (new movies), aired (episodes),
    /// released (catalogs).
    public var date: Date?
    /// Resume cards: position, 0…1.
    public var progress: Double?
    /// Resume cards: minutes left.
    public var remainingMinutes: Int?

    public init(id: String? = nil, imdbId: String, kind: Kind, title: String, year: Int? = nil,
                rating: Double? = nil, genres: [String] = [], summary: String? = nil,
                runtimeMinutes: Int? = nil, posterURL: URL? = nil, backdropURL: URL? = nil,
                logoURL: URL? = nil, trailerCode: String? = nil, badges: [HomeBadge] = [],
                rank: Int? = nil, episode: HomeEpisode? = nil, date: Date? = nil,
                progress: Double? = nil, remainingMinutes: Int? = nil) {
        self.id = id ?? episode.map { HomeItem.episodeId(imdbId: imdbId, season: $0.season, number: $0.number) } ?? imdbId
        self.imdbId = imdbId
        self.kind = kind
        self.title = title
        self.year = year
        self.rating = rating
        self.genres = genres
        self.summary = summary
        self.runtimeMinutes = runtimeMinutes
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.logoURL = logoURL
        self.trailerCode = trailerCode
        self.badges = badges
        self.rank = rank
        self.episode = episode
        self.date = date
        self.progress = progress
        self.remainingMinutes = remainingMinutes
    }

    /// The id of an episode card (Cinemeta's video id: "tt26598805:1:4").
    public static func episodeId(imdbId: String, season: Int, number: Int) -> String {
        return "\(imdbId):\(season):\(number)"
    }

    /// The image of a landscape card: the episode's still, else the backdrop.
    public var landscapeURL: URL? {
        return landscapeURLs.first
    }

    /// The images of a landscape card, best first: the episode's still,
    /// then the backdrop. A still may be missing on its host (a 404: about
    /// half of this week's episodes have one on metahub): show the next.
    public var landscapeURLs: [URL] {
        return [episode?.stillURL, backdropURL].compactMap { $0 }
    }
}

/// The episode an episode card is about.
public struct HomeEpisode: Codable, Hashable, Sendable {
    public var season: Int
    public var number: Int
    public var title: String?
    /// 16:9 still.
    public var stillURL: URL?
    public var airDate: Date?

    public init(season: Int, number: Int, title: String? = nil, stillURL: URL? = nil, airDate: Date? = nil) {
        self.season = season
        self.number = number
        self.title = title
        self.stillURL = stillURL
        self.airDate = airDate
    }
}

/// A pill on a card. The raw value is stored in the cache; `label` is the
/// English text and `localizationKey` the key of the apps' strings files.
public enum HomeBadge: String, Codable, Hashable, Sendable, CaseIterable {
    case uhd
    case dolbyVision
    case hdr
    case atmos
    /// Added (movies) or premiered (shows) a few days ago.
    case new
    /// An episode aired this week.
    case newEpisode
    /// The episode opens a new season.
    case newSeason
    /// The episode is the first of the show.
    case premiere
    /// The episode has not aired yet.
    case upcoming

    /// English text.
    public var label: String {
        switch self {
        case .uhd: return "4K"
        case .dolbyVision: return "Dolby Vision"
        case .hdr: return "HDR"
        case .atmos: return "Dolby Atmos"
        case .new: return "New"
        case .newEpisode: return "New Episode"
        case .newSeason: return "New Season"
        case .premiere: return "Series Premiere"
        case .upcoming: return "Upcoming"
        }
    }

    /// Key of the apps' Localizable.strings ("Home.Badge.New"). The format
    /// names (4K, Dolby Vision, HDR, Dolby Atmos) are not translated: nil.
    /// To show a pill, use `localizedLabel`.
    public var localizationKey: String? {
        switch self {
        case .uhd, .dolbyVision, .hdr, .atmos: return nil
        case .new: return "Home.Badge.New"
        case .newEpisode: return "Home.Badge.NewEpisode"
        case .newSeason: return "Home.Badge.NewSeason"
        case .premiere: return "Home.Badge.Premiere"
        case .upcoming: return "Home.Badge.Upcoming"
        }
    }

    /// The text of the pill in the app's language: `localizationKey`
    /// looked up in the apps' strings, `label` for a format — and for a
    /// language whose strings file has no entry, never the raw key.
    public var localizedLabel: String {
        guard let key = localizationKey else { return label }
        let text = key.localized
        return text == key ? label : text
    }

    /// The video / audio formats, as opposed to the editorial pills.
    public var isFormat: Bool {
        return localizationKey == nil
    }
}

// MARK: - Shelf

/// One row of the hub.
public struct HomeShelf: Codable, Hashable, Sendable, Identifiable {

    public enum Style: String, Codable, Sendable {
        /// The carousel at the top: backdrop + logo.
        case hero
        /// 2:3 posters.
        case posters
        /// Posters with their rank (`HomeItem.rank`).
        case ranked
        /// 16:9 cards: episodes, resume cards.
        case landscape
    }

    /// Stable id (`HomeShelfID`): compare ids, never titles.
    public var id: String
    public var style: Style
    public var items: [HomeItem]
    /// When the list the shelf is made of was fetched (nil: local shelves).
    public var updatedAt: Date?
    /// Shown from an older answer: its refresh is running or failed.
    public var isStale: Bool
    /// What a "See All" button opens, nil when there is nothing more to show.
    public var seeAll: HomeSeeAll?

    public init(id: String, style: Style, items: [HomeItem], updatedAt: Date? = nil,
                isStale: Bool = false, seeAll: HomeSeeAll? = nil) {
        self.id = id
        self.style = style
        self.items = items
        self.updatedAt = updatedAt
        self.isStale = isStale
        self.seeAll = seeAll
    }

    /// The English title, which is also the apps' localisation key. Genre
    /// shelves have a format ("%@ Movies") whose argument is `titleArgument`.
    public var defaultTitle: String {
        return HomeShelfID.defaultTitle(id)
    }

    /// The genre of a genre shelf, to localise and put in `defaultTitle`:
    /// under the name the app's genres have ("Science Fiction" for
    /// Cinemeta's "Sci-Fi") when it is one of them — those are translated.
    public var titleArgument: String? {
        guard let genre = HomeShelfID.genre(of: id)?.genre else { return nil }
        return HomeBuilder.appGenre(genre)?.rawValue ?? genre
    }
}

/// The catalog grid and filter a shelf's "See All" opens.
public struct HomeSeeAll: Codable, Hashable, Sendable {

    public enum Catalogue: String, Codable, Sendable {
        case movies
        case shows
        case watchlist
    }

    public var catalogue: Catalogue
    /// Raw value of `MovieManager.Filters` / `ShowManager.Filters`.
    public var filter: String?
    /// Raw value of `NetworkManager.Genres`.
    public var genre: String?

    public init(catalogue: Catalogue, filter: String? = nil, genre: String? = nil) {
        self.catalogue = catalogue
        self.filter = filter
        self.genre = genre
    }

    public var movieFilter: MovieManager.Filters? {
        return catalogue == .movies ? filter.flatMap(MovieManager.Filters.init(rawValue:)) : nil
    }

    public var showFilter: ShowManager.Filters? {
        return catalogue == .shows ? filter.flatMap(ShowManager.Filters.init(rawValue:)) : nil
    }

    public var genreFilter: NetworkManager.Genres {
        return genre.flatMap(NetworkManager.Genres.init(rawValue:)) ?? .all
    }
}

/// The ids of the shelves, their order and their English titles.
public enum HomeShelfID {
    public static let hero = "hero"
    public static let continueWatching = "continueWatching"
    public static let yourShows = "yourShows"
    public static let trendingMovies = "trendingMovies"
    public static let newMovies = "newMovies"
    public static let uhd = "uhd"
    public static let airedEpisodes = "airedEpisodes"
    public static let trendingShows = "trendingShows"
    public static let newShows = "newShows"
    public static let moviesOfTheYear = "moviesOfTheYear"
    public static let topRatedOfTheYear = "topRatedOfTheYear"
    public static let top48hShows = "top48hShows"
    public static let top48hMovies = "top48hMovies"
    public static let watchlist = "watchlist"

    private static let genrePrefix = "genre-"

    /// The id of a genre shelf: "genre-movie-Action", "genre-show-Sci-Fi".
    public static func genre(_ kind: HomeItem.Kind, _ genre: String) -> String {
        return "\(genrePrefix)\(kind.rawValue)-\(genre)"
    }

    /// The kind and genre of a genre shelf's id, nil for the other shelves.
    public static func genre(of id: String) -> (kind: HomeItem.Kind, genre: String)? {
        guard id.hasPrefix(genrePrefix) else { return nil }
        let rest = id.dropFirst(genrePrefix.count)
        for kind in HomeItem.Kind.allCases where rest.hasPrefix(kind.rawValue + "-") {
            let genre = String(rest.dropFirst(kind.rawValue.count + 1))
            return genre.isEmpty ? nil : (kind, genre)
        }
        return nil
    }

    /// The fixed shelves in display order; the genre shelves come after.
    public static let order: [String] = [
        hero, continueWatching, yourShows, trendingMovies, newMovies, uhd, airedEpisodes,
        trendingShows, newShows, moviesOfTheYear, topRatedOfTheYear, top48hShows, top48hMovies, watchlist,
    ]

    /// The shelves made of the user's own data (`HomeLocalHooks`): never
    /// filtered by the "two shelves at most" rule, recomputed without network.
    public static let local: Set<String> = [continueWatching, yourShows, watchlist]

    /// The English title of a shelf, the apps' localisation key. A genre
    /// shelf's is a format: "%@ Movies" / "%@ Shows".
    public static func defaultTitle(_ id: String) -> String {
        switch id {
        case hero: return "Featured"
        case continueWatching: return "Continue Watching"
        case yourShows: return "New Episodes of Your Shows"
        case trendingMovies: return "Trending Movies"
        case newMovies: return "New Movies"
        case uhd: return "New in 4K"
        case airedEpisodes: return "Latest Episodes"
        case trendingShows: return "Trending Shows"
        case newShows: return "New Shows"
        case moviesOfTheYear: return "Movies of the Year"
        case topRatedOfTheYear: return "Top Rated of the Year"
        case top48hShows: return "Top Shows of the Last 48 Hours"
        case top48hMovies: return "Top Movies of the Last 48 Hours"
        case watchlist: return "Watchlist"
        default:
            guard let genre = genre(of: id) else { return id }
            return genre.kind == .movie ? "%@ Movies" : "%@ Shows"
        }
    }

    /// The title in English, the genre filled in ("Action Movies"): for
    /// logs and accessibility identifiers, not for the screen.
    public static func englishTitle(_ id: String) -> String {
        let title = defaultTitle(id)
        guard let genre = genre(of: id) else { return title }
        return title.replacingOccurrences(of: "%@", with: genre.genre)
    }
}

// MARK: - What the views show

/// The hub at one moment: what `HomeFeed` delivers at every update.
public struct HomeSnapshot: Hashable, Sendable {
    /// Every shelf in display order, the hero first when there is one.
    public var shelves: [HomeShelf]
    /// A refresh is running.
    public var isRefreshing: Bool
    /// When the freshest list on screen was fetched.
    public var lastUpdated: Date?
    /// The last refresh reached no source (the shelves, if any, come from
    /// the cache). One host that stays down — blocked by the ISP, say —
    /// while the others answer or are fresh is not "offline".
    public var isOffline: Bool
    /// The last refresh reached no source and nothing is cached: an error
    /// screen with a retry, not an empty page.
    public var isUnavailable: Bool

    public init(shelves: [HomeShelf] = [], isRefreshing: Bool = false, lastUpdated: Date? = nil,
                isOffline: Bool = false, isUnavailable: Bool = false) {
        self.shelves = shelves
        self.isRefreshing = isRefreshing
        self.lastUpdated = lastUpdated
        self.isOffline = isOffline
        self.isUnavailable = isUnavailable
    }

    /// The hero's cards ([] when there is no hero).
    public var heroItems: [HomeItem] {
        return shelves.first { $0.id == HomeShelfID.hero }?.items ?? []
    }

    /// The shelves under the hero.
    public var rows: [HomeShelf] {
        return shelves.filter { $0.id != HomeShelfID.hero }
    }

    public func shelf(_ id: String) -> HomeShelf? {
        return shelves.first { $0.id == id }
    }
}

// MARK: - One truth per title

extension HomeBadge {
    /// The formats a card names, on every screen and platform: the two
    /// best of `badges` — Dolby Vision, then HDR (which Dolby Vision says
    /// too: never both), then 4K, then Atmos — in the cards' reading order
    /// (4K, DV or HDR, Atmos). A list never hides one: a card says the
    /// same thing in every row, grid and search.
    public static func cardFormats(_ badges: [HomeBadge], limit: Int = 2) -> [HomeBadge] {
        let present = Set(badges)
        var best: [HomeBadge] = []
        if present.contains(.dolbyVision) { best.append(.dolbyVision) } else if present.contains(.hdr) { best.append(.hdr) }
        if present.contains(.uhd) { best.append(.uhd) }
        if present.contains(.atmos) { best.append(.atmos) }
        let kept = Set(best.prefix(max(limit, 0)))
        return allCases.filter(kept.contains)
    }
}

/// One rating, one set of formats and one title per title in the whole
/// app, on the three platforms: what the Home says of a title is kept by
/// IMDb id (`HomeBuilder` records its shelves, the iOS and Mac Home its
/// harmonised ones), and a card drawn elsewhere — the Movies and Shows
/// grids, My List, Search, See All, a title's page — takes it
/// (`harmonize`). A title the Home does not list is told as the first
/// screen that showed it.
public final class HomeTitleFacts: @unchecked Sendable {
    public static let shared = HomeTitleFacts()

    public init() {}

    public struct Facts: Equatable, Sendable {
        public var title: String
        public var year: Int?
        public var rating: Double?
        public var badges: [HomeBadge]

        public init(title: String, year: Int? = nil, rating: Double? = nil, badges: [HomeBadge] = []) {
            self.title = title
            self.year = year
            self.rating = rating
            self.badges = badges
        }
    }

    private var facts: [String: Facts] = [:]
    /// The ids the Home lists: its facts win over any other screen's.
    private var fromHome: Set<String> = []
    private let lock = NSLock()

    /// The Home's title cards (an episode's card speaks of its episode).
    public func record(_ items: [HomeItem]) {
        // A title on several shelves of this page keeps the editorial badge
        // any of them gives it (NOUVEAU on « New movies », nothing on a genre
        // shelf below): the union of the page, not its last card — the same
        // rule as `HomeHarmony` on the iPhone / iPad and the Mac.
        var editorial: [String: Set<HomeBadge>] = [:]
        for item in items where item.episode == nil && !item.imdbId.isEmpty {
            editorial[item.imdbId, default: []].formUnion(item.badges.filter { !$0.isFormat && $0 != .upcoming })
        }
        lock.lock(); defer { lock.unlock() }
        for item in items where item.episode == nil && !item.imdbId.isEmpty {
            let pageEditorial = editorial[item.imdbId] ?? []
            var badges = HomeBadge.allCases.filter { item.badges.contains($0) || pageEditorial.contains($0) }
            if let known = facts[item.imdbId], fromHome.contains(item.imdbId) {
                // A title on several shelves keeps every format any of
                // them knows.
                badges = HomeBadge.allCases.filter { badges.contains($0) || (known.badges.contains($0) && $0.isFormat) }
            }
            // A working title ("Untitled …") never replaces a real one.
            var title = item.title
            if let known = facts[item.imdbId], HomeTitleFacts.isPlaceholder(title), !HomeTitleFacts.isPlaceholder(known.title) {
                title = known.title
            }
            facts[item.imdbId] = Facts(title: title, year: item.year ?? facts[item.imdbId]?.year,
                                       rating: item.rating.flatMap { $0 > 0 ? $0 : nil } ?? facts[item.imdbId]?.rating,
                                       badges: badges)
            fromHome.insert(item.imdbId)
        }
    }

    /// The latest episode the Home lists for a show (its episode cards:
    /// the new episodes of the user's shows, the episodes just aired), by
    /// IMDb id: what a show's "NOUVEL ÉPISODE" is about.
    private var newEpisodes: [String: HomeEpisode] = [:]

    public func recordNewEpisodes(in shelves: [HomeShelf]) {
        var latest: [String: HomeEpisode] = [:]
        for shelf in shelves where shelf.id != HomeShelfID.continueWatching {
            for item in shelf.items where item.progress == nil && !item.badges.contains(.upcoming) {
                guard let episode = item.episode, !item.imdbId.isEmpty else { continue }
                if let known = latest[item.imdbId],
                   (known.airDate ?? .distantPast, known.season, known.number) >= (episode.airDate ?? .distantPast, episode.season, episode.number) {
                    continue
                }
                latest[item.imdbId] = episode
            }
        }
        lock.lock(); defer { lock.unlock() }
        newEpisodes = latest
    }

    /// The new episode of a show card badged "NOUVEL ÉPISODE" (nil: the
    /// Home lists none, or the card is not such a show card).
    public func newEpisode(of item: HomeItem) -> HomeEpisode? {
        guard item.kind == .show, item.episode == nil, item.badges.contains(.newEpisode) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return newEpisodes[item.imdbId]
    }

    /// The same, for a show's page: when the Home badges the show
    /// "NOUVEL ÉPISODE".
    public func newEpisode(ofShow imdbId: String) -> HomeEpisode? {
        lock.lock(); defer { lock.unlock() }
        guard facts[imdbId]?.badges.contains(.newEpisode) == true else { return nil }
        return newEpisodes[imdbId]
    }

    public func facts(of imdbId: String) -> Facts? {
        lock.lock(); defer { lock.unlock() }
        return facts[imdbId]
    }

    /// A card from another screen, told as the app already told it: the
    /// known rating; the known formats with its own; the known editorial
    /// badge ("NOUVEL ÉPISODE" in My List as on the Home) instead of its
    /// own; its year, else the known one; the Home's title, and the known
    /// title for a source's working title ("Untitled Jason Statham
    /// thriller").
    public func harmonize(_ item: HomeItem) -> HomeItem {
        guard item.episode == nil, !item.imdbId.isEmpty else { return item }
        let told = harmonized(Facts(title: item.title, year: item.year, rating: item.rating, badges: item.badges), of: item.imdbId)
        var item = item
        item.title = told.title
        item.year = told.year
        item.rating = told.rating
        item.badges = told.badges
        return item
    }

    /// The same for any card: `own` is what its screen knows.
    func harmonized(_ own: Facts, of imdbId: String) -> Facts {
        guard !imdbId.isEmpty else { return own }
        lock.lock(); defer { lock.unlock() }
        guard let known = facts[imdbId] else {
            facts[imdbId] = own
            return own
        }
        let home = fromHome.contains(imdbId)
        var told = own
        if let rating = known.rating { told.rating = rating }
        let formats = Set(own.badges.filter(\.isFormat)).union(known.badges.filter(\.isFormat))
        let editorial = home ? Set(known.badges.filter { !$0.isFormat }) : Set(own.badges.filter { !$0.isFormat })
        told.badges = HomeBadge.allCases.filter { formats.contains($0) || editorial.contains($0) }
        if told.year == nil { told.year = known.year }
        if !HomeTitleFacts.isPlaceholder(known.title), !known.title.isEmpty,
           home || HomeTitleFacts.isPlaceholder(own.title) {
            told.title = known.title
        }
        return told
    }

    /// "Untitled Jason Statham thriller", "TBA": a catalogue's working
    /// name for a title that had none yet. A card does not print it
    /// (`cardTitle`): the poster says the title; VoiceOver keeps it.
    public static func isPlaceholder(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^(untitled|tba|tbd)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The title a card prints under its artwork: nothing for a working
    /// title nobody could correct.
    public static func cardTitle(_ title: String) -> String {
        return isPlaceholder(title) ? "" : title
    }
}

extension HomeItem {
    /// The title printed on the card (`HomeTitleFacts.cardTitle`); `title`
    /// stays what VoiceOver reads.
    public var cardTitle: String {
        return HomeTitleFacts.cardTitle(title)
    }
}
