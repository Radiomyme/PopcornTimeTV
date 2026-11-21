import Foundation

/// What the user's library gives the hub (the values `HomeLocalHooks`
/// answered): the local shelves are made of it, without any request.
public struct HomeLocal: Hashable, Sendable {
    /// Resume cards (`progress`, `remainingMinutes`), most recent first.
    public var continueWatching: [HomeItem] = []
    public var watchlist: [HomeItem] = []
    /// IMDb ids of the shows the user follows (watchlist, shows being watched).
    public var followedShowIds: [String] = []
    /// New episodes of the followed shows the library already knows about.
    public var newEpisodes: [HomeItem] = []
    /// Ids ("tt…:season:episode") of the followed shows' recent episodes the
    /// user has watched: they are not "new episodes" any more.
    public var watchedEpisodeIds: Set<String> = []

    public init() {}
}

/// The shelves, from the lists the sources answered: filters, hero, the
/// "two shelves at most" rule, order. Pure: no clock, no defaults, no
/// singleton — `now`, the languages and the lists are parameters, so every
/// rule runs on recorded answers in the tests.
enum HomeBuilder {

    // MARK: - Rules

    /// The thresholds of feeds-live §5.1–5.2, in one place.
    struct Rules: Sendable {
        /// A list of one year with fewer titles than this is completed with
        /// the year before (January).
        static let yearRollover = 30
        /// Soaps number their seasons by year ("S2026E223"): not seasons.
        static let yearNumberedSeason = 1900
        /// Days of TV schedules read (today included).
        static let airedDays = 3

        var heroLimit = 8
        /// "About two movies for one show" in the hero.
        var heroMoviesPerShow = 2
        /// A show is recent enough for the hero when an episode aired within this.
        var heroShowRecency: TimeInterval = 45 * 86_400
        var shelfLimit = 30
        var rankedLimit = 20
        /// A ranking of fewer titles is not shown.
        var rankedMinimum = 5
        /// A title is shown in this many shelves at most (the first ones win).
        var maximumAppearances = 2
        /// A genre shelf ("Action Movies") shows only titles no shelf above
        /// it showed: the same poster in "Trending Movies" and again in
        /// "Action Movies" made the page look thinner than it is.
        var genreShelvesShowNewTitlesOnly = true
        /// ... unless that leaves it with fewer cards than this: then titles
        /// shown above complete it, at its end.
        var genreShelfMinimum = 10
        /// A ranking that skipped the titles shown above would lie about its
        /// ranks: the ranked shelves keep every title and do not count.
        var rankedShelvesAreComplete = true
        /// TVMaze popularity of the aired episodes' shows.
        var airedMinimumWeight = 90
        var airedShowTypes: Set<String> = ["Scripted", "Animation", "Documentary"]
        var newMoviesMinimumRating = 6.0
        var topRatedMinimumRating = 7.0
        /// "New": a movie added within this.
        var newMovieAge: TimeInterval = 3 * 86_400
        /// "New Episode": an episode aired within this.
        var newEpisodeAge: TimeInterval = 7 * 86_400
        /// "New": a show that premiered within this.
        var newShowAge: TimeInterval = 30 * 86_400
        /// The followed shows' episodes aired within this are "new episodes".
        var followedAiredAge: TimeInterval = 14 * 86_400
        /// The followed shows' episodes airing within this are "upcoming".
        var followedUpcoming: TimeInterval = 7 * 86_400
        var genreShelves = 4
        /// Metadata lookups for the titles of a ranking no list knows.
        var lookupLimit = 8
        /// A light refresh (`HomePlan.light`): the Top Shelf extension's.
        var light = false
    }

    /// Everything a build reads.
    struct Inputs: Sendable {
        /// The lists by source key (memory or disk); the expired ones are ignored.
        var lists: [String: HomeSourceList]
        var local = HomeLocal()
        /// ISO 639-1 codes of the content languages ([]: every language).
        var languages: [String] = []
        /// Ids of the shelves the user hid.
        var hidden: Set<String> = []
        /// False: the followed shows are not sent to Cinemeta (no calendar).
        var sendsFollowedShows = true
        /// The services of the « Services » row (none without a TMDB key:
        /// no row), the one the page is filtered on, and the country of
        /// their catalogues.
        var streaming: [StreamingService] = []
        var service: StreamingService?
        var region = "US"
        /// « All »'s title on the « Services » row (the app's language).
        var allServicesTitle = "All"
        /// Keys of the sources a running refresh has yet to hear from
        /// (the ones that were down at their last attempt left out). A
        /// shelf whose own source is awaited is not made of its stand-in
        /// meanwhile: it would be shown, then swapped a moment later.
        var pending: Set<String> = []
        var now: Date

        /// The sources this build reads: the same plan the loader asks.
        func plan(rules: Rules = Rules()) -> HomePlan {
            return HomePlan(now: now,
                            followedShowIds: sendsFollowedShows ? local.followedShowIds : [],
                            genres: HomeBuilder.genreChoices(local, limit: rules.genreShelves),
                            light: rules.light, service: service, offered: streaming.map(\.id), region: region)
        }
    }

    // MARK: - Build

    /// - Parameter facts: where the page's facts are kept for the rest of
    ///   the app (`HomeTitleFacts`); the tests pass their own.
    static func shelves(_ inputs: Inputs, rules: Rules = Rules(), facts: HomeTitleFacts = .shared) -> [HomeShelf] {
        let context = Context(inputs: inputs, rules: rules)
        var drafts: [Draft] = []

        // Filtered on a service: its row, then its shelves only.
        if let service = inputs.service {
            let streaming = context.streaming(service)
            if !inputs.hidden.contains(HomeShelfID.hero), let hero = context.streamingHero(streaming) { drafts.append(hero) }
            drafts.append(context.servicesRow())
            drafts += streaming
            let shelves = HomeBuilder.sameFormats(context.finished(drafts))
            facts.record(shelves.flatMap(\.items).filter { !HomeServiceCard.isServiceCard($0) })
            return shelves
        }

        var trendingMovies = context.trendingMovies()
        var trendingShows = context.trendingShows()
        if !inputs.hidden.contains(HomeShelfID.hero),
           let hero = context.hero(movies: trendingMovies, shows: trendingShows) {
            // What the hero shows is not repeated right under it.
            let featured = Set(hero.entries.map(\.item.imdbId))
            trendingMovies?.entries.removeAll { featured.contains($0.item.imdbId) }
            trendingShows?.entries.removeAll { featured.contains($0.item.imdbId) }
            drafts.append(hero)
        }
        drafts.append(Draft(HomeShelfID.continueWatching, inputs.local.continueWatching.map { HomeEntry(item: $0) }))
        drafts.append(context.servicesRow())
        drafts.append(context.yourShows())
        drafts += [
            trendingMovies, context.newMovies(), context.uhd(), context.airedEpisodes(), trendingShows,
            context.newShows(), context.moviesOfTheYear(), context.topRatedOfTheYear(),
            context.ranking(HomeShelfID.topShows, .topShows, kind: .show),
            context.ranking(HomeShelfID.topMovies, .topMovies, kind: .movie),
        ].compactMap { $0 }
        drafts.append(Draft(HomeShelfID.watchlist, inputs.local.watchlist.map { HomeEntry(item: $0) }))
        drafts += context.genres()

        let shelves = HomeBuilder.sameFormats(context.finished(drafts))
        // The grids, Search and the title pages of every platform tell
        // these titles as the Home does (the Apple TV's grids included).
        facts.record(shelves.flatMap(\.items).filter { !HomeServiceCard.isServiceCard($0) })
        return shelves
    }

    /// The same title has the same formats on every shelf: the union of
    /// what each list knows of it (a ranking's release says Atmos, the
    /// catalogue's says 4K).
    static func sameFormats(_ shelves: [HomeShelf]) -> [HomeShelf] {
        var formats: [String: Set<HomeBadge>] = [:]
        for shelf in shelves {
            for item in shelf.items { formats[item.imdbId, default: []].formUnion(item.badges.filter(\.isFormat)) }
        }
        return shelves.map { shelf in
            var shelf = shelf
            shelf.items = shelf.items.map { item in
                var item = item
                item.badges = HomeBadge.ordered(item.badges + (formats[item.imdbId] ?? []))
                return item
            }
            return shelf
        }
    }

    /// A shelf before the limits and the "two shelves at most" rule.
    struct Draft {
        var id: String
        var entries: [HomeEntry]
        /// The lists it is made of: its date and its staleness.
        var lists: [HomeSourceList]

        init(_ id: String, _ entries: [HomeEntry], lists: [HomeSourceList] = []) {
            self.id = id
            self.entries = entries
            self.lists = lists
        }
    }

    static func style(of id: String) -> HomeShelf.Style {
        switch id {
        case HomeShelfID.hero: return .hero
        case HomeShelfID.continueWatching, HomeShelfID.yourShows, HomeShelfID.airedEpisodes, HomeShelfID.services: return .landscape
        case HomeShelfID.topShows, HomeShelfID.topMovies: return .ranked
        default: return .posters
        }
    }

    /// The grid and filter behind a shelf, nil when the catalog has no
    /// equivalent (the hero, the local episode shelves, 4K).
    static func seeAll(of id: String) -> HomeSeeAll? {
        switch id {
        case HomeShelfID.trendingMovies: return HomeSeeAll(catalogue: .movies, filter: MovieManager.Filters.trending.rawValue)
        case HomeShelfID.newMovies: return HomeSeeAll(catalogue: .movies, filter: MovieManager.Filters.date.rawValue)
        case HomeShelfID.moviesOfTheYear: return HomeSeeAll(catalogue: .movies, filter: MovieManager.Filters.year.rawValue)
        case HomeShelfID.topRatedOfTheYear: return HomeSeeAll(catalogue: .movies, filter: MovieManager.Filters.rating.rawValue)
        case HomeShelfID.topMovies: return HomeSeeAll(catalogue: .movies, filter: MovieManager.Filters.top100.rawValue)
        case HomeShelfID.airedEpisodes: return HomeSeeAll(catalogue: .shows, filter: ShowManager.Filters.date.rawValue)
        case HomeShelfID.trendingShows: return HomeSeeAll(catalogue: .shows, filter: ShowManager.Filters.trending.rawValue)
        case HomeShelfID.newShows: return HomeSeeAll(catalogue: .shows, filter: ShowManager.Filters.year.rawValue)
        case HomeShelfID.topShows: return HomeSeeAll(catalogue: .shows, filter: ShowManager.Filters.top100.rawValue)
        case HomeShelfID.watchlist: return HomeSeeAll(catalogue: .watchlist)
        default:
            guard let genre = HomeShelfID.genre(of: id), let appGenre = appGenre(genre.genre) else { return nil }
            return genre.kind == .movie
                ? HomeSeeAll(catalogue: .movies, filter: MovieManager.Filters.trending.rawValue, genre: appGenre.rawValue)
                : HomeSeeAll(catalogue: .shows, filter: ShowManager.Filters.trending.rawValue, genre: appGenre.rawValue)
        }
    }

    // MARK: - Genres

    /// Cinemeta's genres (the `top` catalog's filter).
    static let cinemetaGenres = [
        "Action", "Adventure", "Animation", "Biography", "Comedy", "Crime", "Documentary", "Drama", "Family",
        "Fantasy", "History", "Horror", "Mystery", "Romance", "Sci-Fi", "Sport", "Thriller", "War", "Western",
    ]

    /// The genre shelves of someone the library says nothing about.
    static let defaultGenres: [(kind: HomeItem.Kind, genre: String)] = [
        (.movie, "Action"), (.show, "Drama"), (.movie, "Comedy"), (.show, "Sci-Fi"), (.movie, "Thriller"), (.show, "Crime"),
    ]

    /// Cinemeta's name of a genre as YTS, TVMaze or the app spell it.
    static func cinemetaGenre(_ name: String) -> String? {
        let lowered = name.lowercased()
        switch lowered {
        case "science fiction", "science-fiction", "sci-fi", "scifi": return "Sci-Fi"
        case "sports": return "Sport"
        default: return cinemetaGenres.first { $0.lowercased() == lowered }
        }
    }

    /// The app's genre (the grids' filter) of a Cinemeta genre.
    static func appGenre(_ cinemetaGenre: String) -> NetworkManager.Genres? {
        switch cinemetaGenre {
        case "Sci-Fi": return .sciFi
        case "Sport": return .sports
        default: return NetworkManager.Genres(rawValue: cinemetaGenre)
        }
    }

    /// The genre shelves: the genres the user's own titles (resume cards,
    /// watchlist, new episodes) have most, per kind, then the defaults.
    static func genreChoices(_ local: HomeLocal, limit: Int) -> [(kind: HomeItem.Kind, genre: String)] {
        guard limit > 0 else { return [] }
        var counts: [String: (kind: HomeItem.Kind, genre: String, count: Int, first: Int)] = [:]
        var position = 0
        var counted = Set<String>()
        for item in local.continueWatching + local.newEpisodes + local.watchlist where counted.insert(item.imdbId).inserted {
            for genre in Set(item.genres.compactMap(cinemetaGenre)).sorted() {
                let key = "\(item.kind.rawValue)|\(genre)"
                position += 1
                counts[key] = (item.kind, genre, (counts[key]?.count ?? 0) + 1, counts[key]?.first ?? position)
            }
        }
        var chosen = counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }
            .prefix(limit).map { (kind: $0.kind, genre: $0.genre) }
        for fallback in defaultGenres where chosen.count < limit {
            if !chosen.contains(where: { $0.kind == fallback.kind && $0.genre == fallback.genre }) { chosen.append(fallback) }
        }
        return chosen
    }

    // MARK: - Twins

    /// YTS lists the same title + year under two IMDb ids ("The Odyssey"
    /// 2026: the real one, and a stub rated 1.7 with fewer qualities): the
    /// one with the most qualities stays, then the best rated.
    static func withoutTwins(_ entries: [HomeEntry]) -> [HomeEntry] {
        var best: [String: Int] = [:]
        var dropped = Set<Int>()
        for (index, entry) in entries.enumerated() {
            guard let year = entry.item.year else { continue }
            let key = "\(titleKey(entry.item.title))|\(year)"
            guard let known = best[key] else {
                best[key] = index
                continue
            }
            let a = entry, b = entries[known]
            let better = (a.qualities ?? 0, a.item.rating ?? 0) > (b.qualities ?? 0, b.item.rating ?? 0)
            dropped.insert(better ? known : index)
            if better { best[key] = index }
        }
        return dropped.isEmpty ? entries : entries.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }

    /// A title without case, accents, punctuation or spaces.
    static func titleKey(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    // MARK: - Followed shows

    /// The followed shows' episodes whose "watched" state decides the
    /// "New Episodes of Your Shows" shelf (each show's latest aired one):
    /// the loader asks the library about these and nothing else.
    static func followedCandidates(_ inputs: Inputs, rules: Rules = Rules()) -> [(imdbId: String, season: Int, number: Int)] {
        // Any calendar kept, not only the current set of shows': when the
        // set changes the answer for the new one starts from the old one's.
        let calendars = inputs.lists.values.filter { $0.key.hasPrefix(HomeSource.calendarPrefix) }.sorted { $0.savedAt > $1.savedAt }
        let followed = Set(inputs.local.followedShowIds)
        var seen = Set<String>()
        return calendars.flatMap(\.entries).compactMap { entry in
            guard followed.contains(entry.item.imdbId), seen.insert(entry.item.imdbId).inserted else { return nil }
            return latestAired(entry, now: inputs.now, rules: rules).map { (entry.item.imdbId, $0.season, $0.number) }
        }
    }

    /// A followed show's latest episode when it aired lately.
    static func latestAired(_ entry: HomeEntry, now: Date, rules: Rules) -> HomeEpisode? {
        guard let episode = entry.latestAired(now), let aired = episode.airDate,
              now.timeIntervalSince(aired) < rules.followedAiredAge else { return nil }
        return episode
    }

    // MARK: - Releases without an id

    /// The ids of the known titles of a kind by what a release names them
    /// (`HomeParse.readings(ofTitle:year:kind:)`): their card's title and the
    /// name every card prints (`titles`), with the card's year.
    static func titlesByReading<Cards: Sequence>(_ cards: Cards, titles: [String: String], kind: HomeItem.Kind) -> [String: Set<String>]
        where Cards.Element == HomeEntry {
        var ids: [String: Set<String>] = [:]
        for card in cards where card.item.kind == kind && !card.isUnknown && !card.isPending {
            let id = card.item.imdbId
            for title in Set([card.item.title, titles[id]].compactMap { $0 }) where !HomeTitleFacts.isPlaceholder(title) {
                for key in HomeParse.readings(ofTitle: title, year: card.item.year, kind: kind) { ids[key, default: []].insert(id) }
            }
        }
        return ids
    }

    /// The ranking with each pending entry given to a title, its releases
    /// joining the title's entry (or making one when the list has none):
    /// - an entry the list ties to a title (`listedUnder`) goes to that title
    ///   only, when its card's name and year are one of the entry's readings
    ///   (`known`: ids by reading) — apibay files some releases under another
    ///   title's id ("Avengers Endgame Encore 2026" under the 2019 film). A
    ///   title no list has a card for yet (`pooled`: the ids that have one)
    ///   takes it as is: only the lookups' order sees it, a ranking shows a
    ///   title once its card is known, and checked then;
    /// - an entry the list ties to no title goes to the one title the lists
    ///   know by one of its readings; none, or two: dropped.
    /// Most seeded first.
    static func attachingPending(_ entries: [HomeEntry], known: [String: Set<String>], pooled: Set<String>) -> [HomeEntry] {
        var result = entries.filter { !$0.isPending }
        var index = Dictionary(result.enumerated().map { ($0.element.item.imdbId, $0.offset) }) { first, _ in first }
        for entry in entries where entry.isPending {
            let readings = entry.readings ?? []
            let target: String?
            if let listed = entry.listedUnder {
                let named = readings.contains { known[$0]?.contains(listed) == true }
                target = named || !pooled.contains(listed) ? listed : nil
            } else {
                let ids = readings.reduce(into: Set<String>()) { $0.formUnion(known[$1] ?? []) }
                target = ids.count == 1 ? ids.first : nil
            }
            guard let id = target else { continue }
            if let position = index[id] {
                result[position] = result[position].adding(releasesOf: entry)
            } else {
                var titled = entry
                titled.item.imdbId = id
                titled.item.id = id
                titled.readings = nil
                titled.listedUnder = nil
                index[id] = result.count
                result.append(titled)
            }
        }
        return HomeEntry.mostSeededFirst(result)
    }

    // MARK: - Lookups

    /// The titles of the rankings no loaded list knows, most seeded first:
    /// what the loader asks Cinemeta about once a refresh has ended.
    static func lookupsNeeded(_ inputs: Inputs, rules: Rules = Rules()) -> (shows: [String], movies: [String]) {
        let context = Context(inputs: inputs, rules: rules)
        var shows = context.unknownTitles(of: .topShows)
        var movies = context.unknownTitles(of: .topMovies)
        // The 4K shelf is made of apibay's ranking only when YTS is down.
        if context.list(.yts4K) == nil { movies += context.unknownTitles(of: .topUHD).filter { !movies.contains($0) } }
        shows = Array(shows.prefix(rules.rankedLimit))
        movies = Array(movies.prefix(rules.lookupLimit))
        return (shows, movies)
    }
}

// MARK: - The shelves

private struct Context {
    let inputs: HomeBuilder.Inputs
    let rules: HomeBuilder.Rules
    let plan: HomePlan
    let now: Date
    let wanted: Set<String>
    /// The best card known of every title, by IMDb id.
    let pool: [String: HomeEntry]
    /// The name every card of a title prints, by IMDb id, whatever list
    /// the card comes from: Cinemeta's (IMDb's English title; YTS names
    /// some films by their original one), else — Cinemeta has none, or
    /// only a working title ("Untitled …") — the first real one a list
    /// gives.
    let titles: [String: String]
    /// 4K / Dolby Vision / HDR / Atmos of the movies that have such a release.
    let formats: [String: [HomeBadge]]
    /// Shows whose first episode aired in the schedules read.
    let premieres: Set<String>
    /// `HomeBuilder.titlesByReading` of the pool, made once per kind for this build: `ranked`
    /// runs for each ranking shelf, the 4K shelf and the lookups — up to five scans of the whole
    /// pool on the main thread before the Home's first frame from disk otherwise.
    private let readingIndex = ReadingIndex()

    private final class ReadingIndex {
        var byKind: [HomeItem.Kind: [String: Set<String>]] = [:]
        var pooled: Set<String>?
    }

    init(inputs: HomeBuilder.Inputs, rules: HomeBuilder.Rules) {
        self.inputs = inputs
        self.rules = rules
        let now = inputs.now, lists = inputs.lists
        let plan = inputs.plan(rules: rules)
        self.now = now
        self.plan = plan
        wanted = Set(inputs.languages.map { $0.lowercased() })

        func usable(_ source: HomeSource) -> HomeSourceList? { Context.usable(lists[source.key], now: now) }
        let year = plan.year
        // Cinemeta first (logo, backdrop, trailer), then YTS, TVMaze, lookups.
        let poolSources: [HomeSource] = [.movieTop, .seriesTop, .movieFeatured, .movieTopNext, .seriesYear(year), .seriesYear(year - 1)]
            + [plan.calendar].compactMap { $0 } + plan.genres
            + [.ytsNew(year), .ytsNew(year - 1), .yts4K, .ytsYear(year), .ytsYear(year - 1), .ytsTop(year), .ytsTop(year - 1),
               .ytsLikes(year), .ytsLikes(year - 1)]
            + plan.tvmaze
        var pool: [String: HomeEntry] = [:]
        let cinemetaKeys = Set(([.movieTop, .seriesTop, .movieFeatured, .movieTopNext, .seriesYear(year), .seriesYear(year - 1)]
                                + [plan.calendar].compactMap { $0 } + plan.genres).map(\.key)
                               + [HomeSource.lookupShowsKey, HomeSource.lookupMoviesKey])
        var cinemetaTitles: [String: String] = [:], realTitles: [String: String] = [:]
        for key in poolSources.map(\.key) + [HomeSource.lookupShowsKey, HomeSource.lookupMoviesKey] {
            for entry in Context.usable(lists[key], now: now)?.entries ?? [] {
                let card = entry.asTitle
                pool[card.item.imdbId] = pool[card.item.imdbId]?.filling(from: card) ?? card
                let id = card.item.imdbId, title = card.item.title
                guard !card.isUnknown, !title.isEmpty else { continue }
                if cinemetaKeys.contains(key), cinemetaTitles[id] == nil { cinemetaTitles[id] = title }
                if !HomeTitleFacts.isPlaceholder(title), realTitles[id] == nil { realTitles[id] = title }
            }
        }
        self.pool = pool
        titles = cinemetaTitles.merging(realTitles) { cinemeta, real in
            HomeTitleFacts.isPlaceholder(cinemeta) ? real : cinemeta
        }

        var formats: [String: [HomeBadge]] = [:]
        for source in [HomeSource.ytsNew(year), .ytsNew(year - 1), .yts4K, .ytsYear(year), .ytsYear(year - 1), .ytsTop(year),
                       .ytsTop(year - 1), .ytsLikes(year), .ytsLikes(year - 1), .topUHD] {
            for entry in usable(source)?.entries ?? [] where !entry.isPending {
                let badges = entry.item.badges.filter(\.isFormat)
                if !badges.isEmpty { formats[entry.item.imdbId] = HomeBadge.ordered((formats[entry.item.imdbId] ?? []) + badges) }
            }
        }
        self.formats = formats

        var premieres = Set<String>()
        for source in plan.tvmaze {
            for entry in usable(source)?.entries ?? [] {
                if let episode = entry.item.episode, episode.season == 1, episode.number == 1,
                   (episode.airDate ?? .distantFuture) <= now { premieres.insert(entry.item.imdbId) }
            }
        }
        self.premieres = premieres
    }

    private static func usable(_ list: HomeSourceList?, now: Date) -> HomeSourceList? {
        guard let list = list,
              HomeCachePolicy.state(savedAt: list.savedAt, now: now,
                                    lifetime: HomeCachePolicy.lifetime(forKey: list.key, now: now)) != .expired else { return nil }
        return list
    }

    /// A source's list when it can still be shown.
    func list(_ source: HomeSource) -> HomeSourceList? {
        return Context.usable(inputs.lists[source.key], now: now)
    }

    /// A list of one year, completed with the year before when it is short
    /// (January). nil when neither year answered.
    func yearList(_ source: (Int) -> HomeSource) -> (entries: [HomeEntry], lists: [HomeSourceList])? {
        let current = list(source(plan.year)), previous = list(source(plan.year - 1))
        guard current != nil || previous != nil else { return nil }
        var entries = current?.entries ?? []
        var lists = [current].compactMap { $0 }
        if entries.count < HomeBuilder.Rules.yearRollover, let previous = previous {
            let known = Set(entries.map(\.item.imdbId))
            entries += previous.entries.filter { !known.contains($0.item.imdbId) }
            lists.append(previous)
        }
        return (entries, lists)
    }

    /// The source's answer is on its way: no stand-in yet. Nor for a list
    /// a light plan never asks: it has not failed, its shelf is simply not
    /// part of that page.
    func awaited(_ source: HomeSource) -> Bool {
        if inputs.pending.contains(source.key) { return true }
        return plan.light && !plan.sources.contains { $0.key == source.key }
    }

    /// The entry's language is one the user wants (unknown: kept).
    func speaks(_ entry: HomeEntry) -> Bool {
        guard !wanted.isEmpty, let language = entry.language else { return true }
        return wanted.contains(language)
    }

    func within(_ date: Date?, _ age: TimeInterval) -> Bool {
        guard let date = date else { return false }
        return date <= now && now.timeIntervalSince(date) < age
    }

    // MARK: Movies

    func trendingMovies() -> HomeBuilder.Draft? {
        if let top = list(.movieTop) {
            return HomeBuilder.Draft(HomeShelfID.trendingMovies, top.entries, lists: [top])
        }
        // Cinemeta is down: the year's most liked movies on YTS.
        guard !awaited(.movieTop), let likes = yearList(HomeSource.ytsLikes) else { return nil }
        return HomeBuilder.Draft(HomeShelfID.trendingMovies, HomeBuilder.withoutTwins(likes.entries.filter(speaks)), lists: likes.lists)
    }

    func newMovies() -> HomeBuilder.Draft? {
        if let added = yearList(HomeSource.ytsNew) {
            let kept = HomeBuilder.withoutTwins(added.entries.filter {
                speaks($0) && ($0.item.rating ?? 0) >= rules.newMoviesMinimumRating
            })
            // Two years merged are not in date order any more.
            let sorted = kept.enumerated().sorted {
                let a = $0.element.item.date ?? .distantPast, b = $1.element.item.date ?? .distantPast
                return a != b ? a > b : $0.offset < $1.offset
            }.map { badged($0.element, .new, when: within($0.element.item.date, rules.newMovieAge)) }
            return HomeBuilder.Draft(HomeShelfID.newMovies, sorted, lists: added.lists)
        }
        // YTS is down: Stremio's "Featured" movies of this year and the last.
        guard !awaited(.ytsNew(plan.year)), let featured = list(.movieFeatured) else { return nil }
        return HomeBuilder.Draft(HomeShelfID.newMovies, featured.entries.filter { ($0.item.year ?? 0) >= plan.year - 1 }, lists: [featured])
    }

    func uhd() -> HomeBuilder.Draft? {
        let ranking = list(.topUHD)
        if let added = list(.yts4K) {
            let kept = HomeBuilder.withoutTwins(added.entries.filter(speaks))
            // First the titles people are seeding right now, most seeded
            // first, then the other additions, latest first.
            var seeders: [String: Int] = [:]
            for entry in ranking.map({ ranked($0, kind: .movie) }) ?? [] { seeders[entry.item.imdbId] = entry.seeders ?? 0 }
            let seeded = kept.enumerated().filter { seeders[$0.element.item.imdbId] != nil }.sorted {
                let a = seeders[$0.element.item.imdbId] ?? 0, b = seeders[$1.element.item.imdbId] ?? 0
                return a != b ? a > b : $0.offset < $1.offset
            }.map(\.element)
            let others = kept.filter { seeders[$0.item.imdbId] == nil }
            let entries = (seeded + others).map { badged(badged($0, .uhd, when: true), .new, when: within($0.item.date, rules.newMovieAge)) }
            return HomeBuilder.Draft(HomeShelfID.uhd, entries, lists: [added] + [ranking].compactMap { $0 })
        }
        // YTS is down: apibay's UHD ranking, with the cards the other lists know.
        guard !awaited(.yts4K), let ranking = ranking else { return nil }
        return HomeBuilder.Draft(HomeShelfID.uhd, resolved(ranking, kind: .movie), lists: [ranking])
    }

    func moviesOfTheYear() -> HomeBuilder.Draft? {
        if let downloads = yearList(HomeSource.ytsYear) {
            return HomeBuilder.Draft(HomeShelfID.moviesOfTheYear, HomeBuilder.withoutTwins(downloads.entries.filter(speaks)), lists: downloads.lists)
        }
        guard !awaited(.ytsYear(plan.year)), let popular = popularOfTheYear() else { return nil }
        return HomeBuilder.Draft(HomeShelfID.moviesOfTheYear, popular.entries, lists: popular.lists)
    }

    func topRatedOfTheYear() -> HomeBuilder.Draft? {
        let source: (entries: [HomeEntry], lists: [HomeSourceList])
        if let rated = yearList(HomeSource.ytsTop) {
            source = (HomeBuilder.withoutTwins(rated.entries.filter(speaks)), rated.lists)
        } else if !awaited(.ytsTop(plan.year)), let popular = popularOfTheYear() {
            source = popular
        } else {
            return nil
        }
        // In the server's order: the most downloaded of the well rated
        // movies. Sorted by rating instead, the fifty start with concert
        // films and TV specials a handful of people rated 8 and more
        // ("Hadestown: The Musical", "Grand Theft Auto VI: An Extended
        // Look" before "Spider-Man", on the answers of 2026-11-14).
        let rated = source.entries.filter { ($0.item.rating ?? 0) >= rules.topRatedMinimumRating }
        return HomeBuilder.Draft(HomeShelfID.topRatedOfTheYear, rated, lists: source.lists)
    }

    /// YTS is down: Cinemeta's popular movies (two pages) that are of this
    /// year — of the last one too while this year's are few.
    private func popularOfTheYear() -> (entries: [HomeEntry], lists: [HomeSourceList])? {
        let lists = [list(.movieTop), list(.movieTopNext)].compactMap { $0 }
        guard !lists.isEmpty else { return nil }
        var seen = Set<String>()
        let all = lists.flatMap(\.entries).filter { seen.insert($0.item.imdbId).inserted }
        var entries = all.filter { $0.item.year == plan.year }
        if entries.count < HomeBuilder.Rules.yearRollover { entries = all.filter { ($0.item.year ?? 0) >= plan.year - 1 } }
        return (entries, lists)
    }

    // MARK: Shows

    func trendingShows() -> HomeBuilder.Draft? {
        if let top = list(.seriesTop) {
            let entries = top.entries.map { badged($0, .newEpisode, when: within($0.latestAired(now)?.airDate, rules.newEpisodeAge)) }
            return HomeBuilder.Draft(HomeShelfID.trendingShows, entries, lists: [top])
        }
        // Cinemeta is down: the most popular shows of the schedules read —
        // but for the ones that just premiered: the same schedules make the
        // new shows' stand-in, and a title is in two shelves at most.
        let lists = plan.tvmaze.compactMap(list)
        guard !awaited(.seriesTop), !lists.isEmpty else { return nil }
        var best: [String: HomeEntry] = [:]
        var order: [String] = []
        for entry in lists.flatMap(\.entries) where airable(entry) && (entry.item.date ?? .distantFuture) <= now
            && !premieres.contains(entry.item.imdbId) {
            let id = entry.item.imdbId
            if best[id] == nil { order.append(id) }
            if (entry.weight ?? 0) > (best[id]?.weight ?? -1) { best[id] = entry }
        }
        let entries = order.compactMap { best[$0] }.enumerated().sorted {
            let a = $0.element, b = $1.element
            if (a.weight ?? 0) != (b.weight ?? 0) { return (a.weight ?? 0) > (b.weight ?? 0) }
            if (a.item.rating ?? 0) != (b.item.rating ?? 0) { return (a.item.rating ?? 0) > (b.item.rating ?? 0) }
            return $0.offset < $1.offset
        }.map { badged(known($0.element.asTitle), .newEpisode, when: true) }
        return HomeBuilder.Draft(HomeShelfID.trendingShows, entries, lists: lists)
    }

    /// A scheduled episode of a show the aired shelves want: a scripted,
    /// animated or documentary show, popular enough, in a wanted language.
    private func airable(_ entry: HomeEntry) -> Bool {
        return rules.airedShowTypes.contains(entry.showType ?? "") && (entry.weight ?? 0) >= rules.airedMinimumWeight && speaks(entry)
    }

    func airedEpisodes() -> HomeBuilder.Draft? {
        let lists = plan.tvmaze.compactMap(list)
        // While a schedule never read before is on its way, the stand-in
        // stays: one swap when they are all in, not a shelf that grows day
        // by day in front of the user.
        let incoming = plan.tvmaze.contains { awaited($0) && list($0) == nil } && list(.seriesTop) != nil
        if !lists.isEmpty, !incoming {
            // One card per show: its latest episode that has aired (of two
            // aired together, a double bill, the second).
            var latest: [String: HomeEntry] = [:]
            func order(_ entry: HomeEntry) -> (Date, Int, Int) {
                return (entry.item.date ?? .distantPast, entry.item.episode?.season ?? 0, entry.item.episode?.number ?? 0)
            }
            for entry in lists.flatMap(\.entries) where airable(entry) {
                guard let aired = entry.item.date, aired <= now else { continue }
                if let known = latest[entry.item.imdbId], order(known) >= order(entry) { continue }
                latest[entry.item.imdbId] = entry
            }
            let entries = latest.values.sorted {
                let a = $0.item.date ?? .distantPast, b = $1.item.date ?? .distantPast
                if a != b { return a > b }
                if ($0.weight ?? 0) != ($1.weight ?? 0) { return ($0.weight ?? 0) > ($1.weight ?? 0) }
                return $0.item.id < $1.item.id
            }.compactMap { entry in entry.item.episode.map { episodeCard(known(entry), $0) } }
            return HomeBuilder.Draft(HomeShelfID.airedEpisodes, entries, lists: lists)
        }
        // No schedule (TVMaze is down, or has not answered yet: this one is
        // free and part of the first paint): the trending shows that had an
        // episode this week.
        guard let top = list(.seriesTop) else { return nil }
        let entries = top.entries.compactMap { entry -> HomeEntry? in
            guard let episode = entry.latestAired(now), within(episode.airDate, rules.newEpisodeAge) else { return nil }
            return episodeCard(entry, episode)
        }.enumerated().sorted {
            let a = $0.element.item.date ?? .distantPast, b = $1.element.item.date ?? .distantPast
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
        return HomeBuilder.Draft(HomeShelfID.airedEpisodes, entries, lists: [top])
    }

    func newShows() -> HomeBuilder.Draft? {
        if let premiered = yearList(HomeSource.seriesYear) {
            // The catalog also lists announced shows: only the ones that started.
            let entries = premiered.entries.compactMap { entry -> HomeEntry? in
                let first = entry.item.date ?? entry.episodes?.first { $0.season == 1 && $0.number == 1 }?.airDate
                guard (first.map { $0 <= now } ?? false) || entry.latestAired(now) != nil else { return nil }
                return badged(entry, .new, when: within(first, rules.newShowAge) || premieres.contains(entry.item.imdbId))
            }
            return HomeBuilder.Draft(HomeShelfID.newShows, entries, lists: premiered.lists)
        }
        // Cinemeta is down: the shows whose first episode just aired.
        let lists = plan.tvmaze.compactMap(list)
        guard !awaited(.seriesYear(plan.year)), !lists.isEmpty else { return nil }
        var seen = Set<String>()
        let entries = lists.flatMap(\.entries)
            .filter { entry in
                guard let episode = entry.item.episode, episode.season == 1, episode.number == 1,
                      (episode.airDate ?? .distantFuture) <= now else { return false }
                return rules.airedShowTypes.contains(entry.showType ?? "") && speaks(entry)
            }
            .sorted { ($0.item.date ?? .distantPast) > ($1.item.date ?? .distantPast) }
            .filter { seen.insert($0.item.imdbId).inserted }
            .map { badged(known($0.asTitle), .new, when: true) }
        return HomeBuilder.Draft(HomeShelfID.newShows, entries, lists: lists)
    }

    /// The calendar of the followed shows. While the one of a new set of
    /// shows is on its way (a show was just followed, the key changed), the
    /// latest calendar kept, for the shows still followed: marked
    /// incomplete, it is shown as stale.
    private func calendar() -> HomeSourceList? {
        guard let source = plan.calendar else { return nil }
        if let current = list(source) { return current }
        let kept = inputs.lists.values.filter { $0.key.hasPrefix(HomeSource.calendarPrefix) }.compactMap { Context.usable($0, now: now) }
        guard var latest = kept.max(by: { ($0.savedAt, $0.key) < ($1.savedAt, $1.key) }) else { return nil }
        let followed = Set(inputs.local.followedShowIds)
        latest.entries.removeAll { !followed.contains($0.item.imdbId) }
        latest.complete = false
        return latest
    }

    /// The followed shows: the library's own new episodes, then, from
    /// Cinemeta's calendar, one card per show — its latest episode when it
    /// aired lately and the user has not watched it, else (up to date, or
    /// nothing new) its next episode when it airs this week.
    func yourShows() -> HomeBuilder.Draft {
        var entries = inputs.local.newEpisodes.map { HomeEntry(item: $0) }
        guard let calendar = calendar() else { return HomeBuilder.Draft(HomeShelfID.yourShows, entries) }
        let listed = Set(entries.map(\.item.imdbId))
        var aired: [HomeEntry] = [], upcoming: [HomeEntry] = []
        for entry in calendar.entries where !listed.contains(entry.item.imdbId) {
            let unwatched = HomeBuilder.latestAired(entry, now: now, rules: rules).flatMap { episode in
                inputs.local.watchedEpisodeIds.contains(HomeItem.episodeId(imdbId: entry.item.imdbId, season: episode.season, number: episode.number)) ? nil : episode
            }
            if let episode = unwatched {
                aired.append(episodeCard(entry, episode))
            } else if let next = entry.nextUpcoming(now), let date = next.airDate, date.timeIntervalSince(now) < rules.followedUpcoming {
                upcoming.append(episodeCard(entry, next))
            }
        }
        aired.sort { ($0.item.date ?? .distantPast) > ($1.item.date ?? .distantPast) }
        upcoming.sort { ($0.item.date ?? .distantFuture) < ($1.item.date ?? .distantFuture) }
        entries += aired + upcoming
        return HomeBuilder.Draft(HomeShelfID.yourShows, entries, lists: [calendar])
    }

    /// The genre shelves of the plan. While lists of the genres just chosen
    /// are missing (a title was added to the watchlist: they are on their
    /// way), the genre lists loaded before take the free places, the latest
    /// fetched first: the shelves on screen stay until the new ones are in.
    func genres() -> [HomeBuilder.Draft] {
        var loaded = plan.genres.compactMap(list)
        if loaded.count < plan.genres.count {
            let planned = Set(plan.genres.map(\.key))
            let others = inputs.lists.values
                .filter { !planned.contains($0.key) && HomeSource.genre(ofKey: $0.key) != nil }
                .compactMap { Context.usable($0, now: now) }
                .sorted { $0.savedAt != $1.savedAt ? $0.savedAt > $1.savedAt : $0.key < $1.key }
            loaded += others.prefix(plan.genres.count - loaded.count)
        }
        return loaded.compactMap { list in
            guard let genre = HomeSource.genre(ofKey: list.key) else { return nil }
            return HomeBuilder.Draft(HomeShelfID.genre(genre.kind, genre.genre), list.entries, lists: [list])
        }
    }

    // MARK: Streaming

    /// The « Services » row: « All » while the page is filtered, then a
    /// card per service, the one shown marked. Empty without services (no
    /// TMDB key): no row.
    func servicesRow() -> HomeBuilder.Draft {
        guard !inputs.streaming.isEmpty else { return HomeBuilder.Draft(HomeShelfID.services, []) }
        let all = inputs.service == nil ? [] : [HomeServiceCard.all(title: inputs.allServicesTitle)]
        let cards = all + inputs.streaming.map { HomeServiceCard.item($0, selected: $0.id == inputs.service?.id) }
        return HomeBuilder.Draft(HomeShelfID.services, cards.map { HomeEntry(item: $0) })
    }

    /// A filtered page's shelves: the service's movies and shows, popular,
    /// recent, top rated. A list not in yet has no shelf.
    func streaming(_ service: StreamingService) -> [HomeBuilder.Draft] {
        let today = CatalogDates.dayString(now)
        return HomeShelfID.streamingShelves.compactMap { shelf in
            guard let list = list(.streaming(service: service.id, kind: shelf.kind, sort: shelf.sort, region: inputs.region,
                                             today: today)) else { return nil }
            return HomeBuilder.Draft(HomeShelfID.streaming(service.id, shelf.kind, shelf.sort), list.entries, lists: [list])
        }
    }

    /// A filtered page's hero: its popular movies and shows, one of each in
    /// turn, the ones with a backdrop.
    func streamingHero(_ shelves: [HomeBuilder.Draft]) -> HomeBuilder.Draft? {
        let popular = shelves.filter { HomeShelfID.streaming(of: $0.id)?.sort == .popular }
        let entries = TMDBStreamingClient.alternating(popular.map(\.entries)).filter { $0.item.backdropURL != nil }
        guard !entries.isEmpty else { return nil }
        return HomeBuilder.Draft(HomeShelfID.hero, entries, lists: popular.flatMap(\.lists))
    }

    /// A streaming shelf's See All: the service's whole catalogue of that
    /// kind, in that order.
    func streamingSeeAll(of id: String) -> HomeSeeAll? {
        guard let shelf = HomeShelfID.streaming(of: id), let service = inputs.service, service.id == shelf.service else { return nil }
        return HomeSeeAll(catalogue: .streaming, filter: shelf.sort.rawValue, service: service, region: inputs.region, kind: shelf.kind)
    }

    // MARK: Rankings

    /// An apibay ranking as cards: each IMDb id with the card another list
    /// knows, when that card's title names the release (apibay files some
    /// releases under another title's id) and the language is a wanted one.
    func resolved(_ ranking: HomeSourceList, kind: HomeItem.Kind) -> [HomeEntry] {
        return ranked(ranking, kind: kind).compactMap { group in
            guard let card = pool[group.item.imdbId], !card.isUnknown, card.item.kind == kind,
                  HomeParse.names(group.releaseName ?? "", title: card.item.title, year: card.item.year, kind: kind),
                  speaksRelease(group, card: card) else { return nil }
            var entry = card
            entry.item.badges = HomeBadge.ordered(card.item.badges + group.item.badges)
            entry.item.date = group.item.date
            entry.seeders = group.seeders
            return entry
        }
    }

    /// A ranking with its pending entries (releases without an IMDb id that
    /// no titled release of the list names) given to the title the other
    /// lists know by that name (`HomeBuilder.attachingPending`): ranks by
    /// the seeders of every release counted. No request: only the titles
    /// already known.
    func ranked(_ ranking: HomeSourceList, kind: HomeItem.Kind) -> [HomeEntry] {
        guard ranking.entries.contains(where: \.isPending) else { return ranking.entries }
        return HomeBuilder.attachingPending(ranking.entries, known: titlesByReading(kind), pooled: pooledIds())
    }

    private func titlesByReading(_ kind: HomeItem.Kind) -> [String: Set<String>] {
        if let made = readingIndex.byKind[kind] { return made }
        let made = HomeBuilder.titlesByReading(pool.values, titles: titles, kind: kind)
        readingIndex.byKind[kind] = made
        return made
    }

    private func pooledIds() -> Set<String> {
        if let made = readingIndex.pooled { return made }
        let made = Set(pool.keys)
        readingIndex.pooled = made
        return made
    }

    /// The title's own language when a list tells it, else the languages
    /// the releases name (none named: kept).
    private func speaksRelease(_ group: HomeEntry, card: HomeEntry?) -> Bool {
        guard !wanted.isEmpty else { return true }
        if let language = card?.language { return wanted.contains(language) }
        guard let named = group.releaseLanguages else { return true }
        return !wanted.isDisjoint(with: named)
    }

    func ranking(_ id: String, _ source: HomeSource, kind: HomeItem.Kind) -> HomeBuilder.Draft? {
        guard let ranking = list(source) else { return nil }
        return HomeBuilder.Draft(id, resolved(ranking, kind: kind), lists: [ranking])
    }

    /// The ids of a ranking's leading titles that no list knows and no
    /// lookup was made for yet. The titles a lookup did not find hold their
    /// place among the leading ones: the search does not move down the
    /// ranking refresh after refresh.
    func unknownTitles(of source: HomeSource) -> [String] {
        guard let ranking = list(source), case .apibay(let kind) = source.parser else { return [] }
        var unknown: [String] = []
        var shown = 0
        for group in ranked(ranking, kind: kind) where shown < rules.rankedLimit {
            if let card = pool[group.item.imdbId] {
                if card.isUnknown || speaksRelease(group, card: card) { shown += 1 }
            } else if speaksRelease(group, card: nil) {
                unknown.append(group.item.imdbId)
                shown += 1
            }
        }
        return unknown
    }

    // MARK: Hero

    /// The carousel: recent trending titles that have a backdrop and a logo,
    /// about two movies for one show.
    func hero(movies: HomeBuilder.Draft?, shows: HomeBuilder.Draft?) -> HomeBuilder.Draft? {
        // Cinemeta says which titles have a logo. Without it (the fallback
        // lists), metahub's artwork by IMDb id: the popular titles have it.
        let moviesFromCinemeta = list(.movieTop) != nil, showsFromCinemeta = list(.seriesTop) != nil
        func ready(_ entry: HomeEntry, cinemeta: Bool) -> HomeEntry? {
            var entry = entry
            if !cinemeta {
                entry.item.backdropURL = HomeArtwork.backdrop(entry.item.imdbId)
                entry.item.logoURL = HomeArtwork.logo(entry.item.imdbId)
            }
            return entry.item.backdropURL != nil && entry.item.logoURL != nil ? entry : nil
        }
        var movieCards = (movies?.entries ?? [])
            .filter { ($0.item.year ?? 0) >= plan.year - 1 }
            .compactMap { ready($0, cinemeta: moviesFromCinemeta) }[...]
        // The stand-in for the trending shows is made of this week's schedules: all recent.
        var showCards = (shows?.entries ?? [])
            .filter { !showsFromCinemeta || within($0.latestAired(now)?.airDate, rules.heroShowRecency) || ($0.item.year ?? 0) >= plan.year - 1 }
            .compactMap { ready($0, cinemeta: showsFromCinemeta) }[...]
        var entries: [HomeEntry] = []
        while entries.count < rules.heroLimit, !(movieCards.isEmpty && showCards.isEmpty) {
            let wantsShow = entries.count % (rules.heroMoviesPerShow + 1) == rules.heroMoviesPerShow
            if let next = (wantsShow ? showCards.popFirst() : movieCards.popFirst()) ?? movieCards.popFirst() ?? showCards.popFirst() {
                entries.append(next)
            }
        }
        guard !entries.isEmpty else { return nil }
        return HomeBuilder.Draft(HomeShelfID.hero, entries, lists: (movies?.lists ?? []) + (shows?.lists ?? []))
    }

    // MARK: Cards

    private func badged(_ entry: HomeEntry, _ badge: HomeBadge, when condition: Bool) -> HomeEntry {
        guard condition, !entry.item.badges.contains(badge) else { return entry }
        var entry = entry
        entry.item.badges = HomeBadge.ordered(entry.item.badges + [badge])
        return entry
    }

    /// The entry with the best card known of its title (Cinemeta's poster,
    /// backdrop and logo under a TVMaze episode), its own id, episode, date
    /// and badges kept.
    private func known(_ entry: HomeEntry) -> HomeEntry {
        guard let card = pool[entry.item.imdbId], !card.isUnknown else { return entry }
        var merged = card.filling(from: entry)
        merged.item.id = entry.item.id
        merged.item.episode = entry.item.episode
        merged.item.date = entry.item.date
        merged.item.badges = entry.item.badges
        return merged
    }

    /// The card of one episode of a show.
    private func episodeCard(_ show: HomeEntry, _ episode: HomeEpisode) -> HomeEntry {
        var entry = show
        entry.item.id = HomeItem.episodeId(imdbId: show.item.imdbId, season: episode.season, number: episode.number)
        entry.item.episode = episode
        entry.item.date = episode.airDate
        let aired = (episode.airDate ?? .distantFuture) <= now
        var badges = show.item.badges.filter { $0.isFormat }
        if !aired {
            badges.append(.upcoming)
        } else if episode.number == 1 {
            badges.append(episode.season == 1 ? .premiere : .newSeason)
        } else if episode.season == 1, premieres.contains(show.item.imdbId) {
            // A double-bill premiere: the card shows episode 2, the show is still new.
            badges.append(.premiere)
        } else if within(episode.airDate, rules.newEpisodeAge) {
            badges.append(.newEpisode)
        }
        entry.item.badges = HomeBadge.ordered(badges)
        return entry
    }

    // MARK: Finish

    /// One set of facts per title, whatever list a card comes from: the
    /// year, rating, genres and runtime of the best card known of it
    /// (`pool`: Cinemeta first — its rating is IMDb's —, YTS next, TVMaze's
    /// average only when nothing else rates it), the card's own where that
    /// one has none; and Cinemeta's title, unless it is a working title
    /// ("Untitled …") and the card has a real one. The billboard, the
    /// compact panel and every shelf then say the same of a title.
    func facts(of item: HomeItem) -> HomeItem {
        var item = item
        if let title = titles[item.imdbId], !(HomeTitleFacts.isPlaceholder(title) && !HomeTitleFacts.isPlaceholder(item.title)) {
            item.title = title
        }
        guard let card = pool[item.imdbId]?.item else { return item }
        item.year = card.year ?? item.year
        item.rating = card.rating ?? item.rating
        if !card.genres.isEmpty { item.genres = card.genres }
        // An episode keeps its own length (what is left of it is worked out from it).
        if item.episode == nil { item.runtimeMinutes = card.runtimeMinutes ?? item.runtimeMinutes }
        return item
    }

    /// Limits, the "two shelves at most" rule, ranks, format badges, dates;
    /// hidden and empty shelves dropped.
    func finished(_ drafts: [HomeBuilder.Draft]) -> [HomeShelf] {
        var appearances: [String: Int] = [:]
        var shelves: [HomeShelf] = []
        for draft in drafts where !inputs.hidden.contains(draft.id) {
            let style = HomeBuilder.style(of: draft.id)
            // A service's shelf is its catalogue: a title on Netflix is
            // there even when a shelf above showed it. The « Services » row
            // holds no title.
            let exempt = HomeShelfID.local.contains(draft.id) || (style == .ranked && rules.rankedShelvesAreComplete)
                || HomeShelfID.streamingService(of: draft.id) != nil || draft.id == HomeShelfID.services
            let limit = style == .hero ? rules.heroLimit : style == .ranked ? rules.rankedLimit : rules.shelfLimit
            // A genre shelf: the titles not shown above first; the ones shown
            // above (within the "two shelves" rule) only complete a shelf
            // that would be too short without them, after the others.
            let genre = HomeShelfID.genre(of: draft.id)?.genre
            let newFirst = rules.genreShelvesShowNewTitlesOnly && genre != nil
            var entries = draft.entries
            if let genre {
                // The titles the genre leads first: a "Comedy" shelf does
                // not open on a title its own billboard calls a crime thriller.
                let leads = { (entry: HomeEntry) -> Bool in
                    self.facts(of: entry.item).genres.prefix(2).contains { HomeBuilder.cinemetaGenre($0) == genre }
                }
                entries = entries.filter(leads) + entries.filter { !leads($0) }
            }
            var items: [HomeItem] = []
            var repeats: [HomeItem] = []
            var ids = Set<String>()
            for entry in entries where items.count < limit {
                var item = facts(of: entry.item)
                let shown = appearances[item.imdbId] ?? 0
                guard !item.title.isEmpty, ids.insert(item.id).inserted,
                      exempt || shown < rules.maximumAppearances else { continue }
                if item.kind == .movie, let badges = formats[item.imdbId] { item.badges = HomeBadge.ordered(item.badges + badges) }
                if style == .ranked { item.rank = items.count + 1 }
                if newFirst, !exempt, shown > 0 { repeats.append(item); continue }
                items.append(item)
            }
            if items.count < rules.genreShelfMinimum { items += repeats.prefix(min(limit, rules.genreShelfMinimum) - items.count) }
            guard !items.isEmpty, style != .ranked || items.count >= rules.rankedMinimum else { continue }
            if !exempt { for item in items { appearances[item.imdbId, default: 0] += 1 } }
            let states = draft.lists.map {
                HomeCachePolicy.state(savedAt: $0.savedAt, now: now, lifetime: HomeCachePolicy.lifetime(forKey: $0.key, now: now), complete: $0.complete)
            }
            shelves.append(HomeShelf(id: draft.id, style: style, items: items,
                                     updatedAt: draft.lists.map(\.savedAt).min(),
                                     isStale: states.contains { $0 != .fresh },
                                     seeAll: HomeBuilder.seeAll(of: draft.id) ?? streamingSeeAll(of: draft.id)))
        }
        return shelves
    }
}

// MARK: - Merging cards

extension HomeBadge {
    /// Without repeats, formats first: 4K, Dolby Vision, HDR, Atmos, then the others.
    static func ordered(_ badges: [HomeBadge]) -> [HomeBadge] {
        let present = Set(badges)
        return allCases.filter(present.contains)
    }
}

extension HomeItem {
    /// This card, what it does not say taken from `other` (the same title
    /// in another list): the first source wins, the next ones complete it.
    func filling(from other: HomeItem) -> HomeItem {
        var item = self
        item.year = year ?? other.year
        item.rating = rating ?? other.rating
        if genres.isEmpty { item.genres = other.genres }
        item.summary = summary ?? other.summary
        item.runtimeMinutes = runtimeMinutes ?? other.runtimeMinutes
        item.posterURL = posterURL ?? other.posterURL
        item.backdropURL = backdropURL ?? other.backdropURL
        item.logoURL = logoURL ?? other.logoURL
        item.trailerCode = trailerCode ?? other.trailerCode
        return item
    }
}

extension HomeEntry {
    func filling(from other: HomeEntry) -> HomeEntry {
        var entry = self
        entry.item = item.filling(from: other.item)
        entry.language = language ?? other.language
        entry.weight = weight ?? other.weight
        entry.showType = showType ?? other.showType
        entry.episodes = episodes ?? other.episodes
        entry.qualities = qualities ?? other.qualities
        return entry
    }

    /// The title's own card: an episode entry (a TVMaze schedule line)
    /// without its episode.
    var asTitle: HomeEntry {
        guard item.episode != nil || item.id != item.imdbId else { return self }
        var entry = self
        entry.item.id = item.imdbId
        entry.item.episode = nil
        entry.item.date = nil
        return entry
    }
}
