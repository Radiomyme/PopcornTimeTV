import Foundation

/// The requests the hub is made of: one `HomeSource` per list, with its
/// cache key and its parser, and the plan of a refresh (which sources in
/// which phase). All keyless hosts, measured in
/// feeds-live (audit 5.3.0, §4): Cinemeta, YTS, TVMaze, apibay.

// MARK: - Request

/// One GET of the hub, as the transport sees it: which service, which path.
/// The transport knows the hosts (YTS has mirrors) and their health.
public struct HomeRequest: Hashable, Sendable {

    public enum Host: String, Sendable, CaseIterable {
        /// v3-cinemeta.strem.io
        case cinemeta
        /// movies-api.accel.li and its mirrors
        case yts
        /// api.tvmaze.com
        case tvmaze
        /// apibay.org (blocked by some ISPs: always optional)
        case apibay
    }

    public var host: Host
    /// Starts with "/", query included.
    public var path: String

    public init(host: Host, path: String) {
        self.host = host
        self.path = path
    }
}

// MARK: - Source

/// One list the hub reads. How long its answer is kept is the cache
/// policy's business (`HomeCachePolicy.lifetime(forKey:now:)`).
struct HomeSource: Hashable, Sendable {

    enum Parser: Hashable, Sendable {
        /// A Cinemeta catalog ("metas" / "metasDetailed").
        case cinemeta(HomeItem.Kind)
        /// One Cinemeta meta ("meta"): a metadata lookup.
        case cinemetaMeta(HomeItem.Kind)
        case yts
        case tvmaze
        /// An apibay precompiled list of movies or of shows.
        case apibay(HomeItem.Kind)
    }

    /// Name of the list in memory and of its cache file.
    let key: String
    let request: HomeRequest
    let parser: Parser
    /// Fewer entries than this is an incomplete answer (`HomeCachePolicy.decision`).
    let minimum: Int
    /// An empty answer is a valid one (a day without episodes, January's "movies of the year").
    let allowsEmpty: Bool
    /// The answers of the same key add up instead of replacing each other
    /// (the metadata lookups: one request per batch of titles).
    var merges = false
    /// The titles a lookup asks about: the ones it does not answer are unknown.
    var lookupIds: [String] = []

    // MARK: Cinemeta

    static let movieTop = cinemeta("cm-movie-top", "/catalog/movie/top.json", .movie)
    static let seriesTop = cinemeta("cm-series-top", "/catalog/series/top.json", .show)
    /// Stremio's "Featured": stands in for the new movies when YTS is down.
    static let movieFeatured = cinemeta("cm-movie-featured", "/catalog/movie/imdbRating.json", .movie)
    /// The second page of the popular movies: with the first, stands in for
    /// the movies of the year when YTS is down.
    static let movieTopNext = cinemeta("cm-movie-top-2", "/catalog/movie/top/skip=50.json", .movie)

    /// The new series of a year, latest premiere first. Like YTS's lists of
    /// one year: short in January, completed with the year before.
    static func seriesYear(_ year: Int) -> HomeSource {
        return cinemeta("cm-series-year-\(year)", "/catalog/series/year/genre=\(year).json", .show,
                        minimum: HomeBuilder.Rules.yearRollover, allowsEmpty: true)
    }

    /// The popular titles of one genre.
    static func genre(_ kind: HomeItem.Kind, _ genre: String) -> HomeSource {
        let type = kind == .movie ? "movie" : "series"
        let encoded = genre.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) ?? genre
        return cinemeta("\(genrePrefix)\(kind.rawValue)-\(genre)", "/catalog/\(type)/top/genre=\(encoded).json", kind)
    }

    static let genrePrefix = "cm-genre-"

    /// The kind and genre of a genre list's key ("cm-genre-show-Sci-Fi"),
    /// nil for the other lists.
    static func genre(ofKey key: String) -> (kind: HomeItem.Kind, genre: String)? {
        guard key.hasPrefix(genrePrefix) else { return nil }
        let rest = key.dropFirst(genrePrefix.count)
        for kind in HomeItem.Kind.allCases where rest.hasPrefix(kind.rawValue + "-") {
            let genre = String(rest.dropFirst(kind.rawValue.count + 1))
            return genre.isEmpty ? nil : (kind, genre)
        }
        return nil
    }

    /// The episodes around today of the shows the user follows: the first
    /// 100 of `ids` (one request takes no more; the caller puts the shows
    /// that matter most first). The key changes with the set of shows, not
    /// with their order: a new show is asked at once.
    static func calendar(ids: [String]) -> HomeSource? {
        var seen = Set<String>()
        let valid = ids.filter { HomeParse.isImdbId($0) && seen.insert($0).inserted }.prefix(100).sorted()
        guard !valid.isEmpty else { return nil }
        let joined = valid.joined(separator: ",")
        return HomeSource(key: calendarPrefix + HomeSource.hash(joined),
                          request: HomeRequest(host: .cinemeta, path: "/catalog/series/calendar-videos/calendarVideosIds=\(joined).json"),
                          parser: .cinemeta(.show), minimum: 0, allowsEmpty: true)
    }

    static let calendarPrefix = "cm-calendar-"

    /// Metadata of shows no loaded list knows (the shows' ranking): one request for
    /// all of them, the card and the last 20 episodes each (a full meta of a
    /// long-running show is megabytes).
    static func lookupShows(ids: [String]) -> HomeSource {
        let joined = ids.sorted().joined(separator: ",")
        return HomeSource(key: lookupShowsKey,
                          request: HomeRequest(host: .cinemeta, path: "/catalog/series/last-videos/lastVideosIds=\(joined).json"),
                          parser: .cinemeta(.show), minimum: 0, allowsEmpty: true, merges: true, lookupIds: ids)
    }

    /// Metadata of one movie no loaded list knows.
    static func lookupMovie(id: String) -> HomeSource {
        return HomeSource(key: lookupMoviesKey, request: HomeRequest(host: .cinemeta, path: "/meta/movie/\(id).json"),
                          parser: .cinemetaMeta(.movie), minimum: 0, allowsEmpty: true, merges: true, lookupIds: [id])
    }

    static let lookupPrefix = "cm-lookup-"
    static let lookupShowsKey = lookupPrefix + "shows"
    static let lookupMoviesKey = lookupPrefix + "movies"

    private static func cinemeta(_ key: String, _ path: String, _ kind: HomeItem.Kind, minimum: Int = 20,
                                 allowsEmpty: Bool = false) -> HomeSource {
        return HomeSource(key: key, request: HomeRequest(host: .cinemeta, path: path), parser: .cinemeta(kind),
                          minimum: minimum, allowsEmpty: allowsEmpty)
    }

    // MARK: YTS

    private static let ytsList = "/api/v2/list_movies.json?limit=50&order_by=desc"

    /// The year's movies rated 6 and more, latest added first.
    static func ytsNew(_ year: Int) -> HomeSource {
        return yts(ytsNewPrefix + String(year), "&query_term=\(year)&sort_by=date_added&minimum_rating=6", yearBound: true)
    }

    /// The latest 4K releases.
    static let yts4K = yts("yts-4k", "&quality=2160p&sort_by=date_added", yearBound: false)

    static let ytsNewPrefix = "yts-new-"

    /// The year's most downloaded movies.
    static func ytsYear(_ year: Int) -> HomeSource {
        return yts("yts-year-\(year)", "&query_term=\(year)&sort_by=download_count", yearBound: true)
    }

    /// The year's most downloaded movies rated 7 and more.
    static func ytsTop(_ year: Int) -> HomeSource {
        return yts("yts-top-\(year)", "&query_term=\(year)&sort_by=download_count&minimum_rating=7", yearBound: true)
    }

    /// The year's most liked movies: stands in for the trending movies when
    /// Cinemeta is down.
    static func ytsLikes(_ year: Int) -> HomeSource {
        return yts("yts-likes-\(year)", "&query_term=\(year)&sort_by=like_count", yearBound: true)
    }

    /// A list of one year is short in January: fewer than `yearRollover`
    /// titles is "incomplete" (never fresh, completed with the year before),
    /// and none at all is still an answer.
    private static func yts(_ key: String, _ query: String, yearBound: Bool) -> HomeSource {
        return HomeSource(key: key, request: HomeRequest(host: .yts, path: ytsList + query), parser: .yts,
                          minimum: yearBound ? HomeBuilder.Rules.yearRollover : 20, allowsEmpty: yearBound)
    }

    // MARK: TVMaze

    /// The episodes of one day: the streaming platforms (worldwide: never
    /// filtered by country, the global platforms have none) or the US networks.
    static func tvmaze(web: Bool, day: String) -> HomeSource {
        return HomeSource(key: "\(tvmazePrefix)\(web ? "web" : "us")-\(day)",
                          request: HomeRequest(host: .tvmaze, path: web ? "/schedule/web?date=\(day)" : "/schedule?country=US&date=\(day)"),
                          parser: .tvmaze, minimum: 0, allowsEmpty: true)
    }

    static let tvmazePrefix = "tvm-"

    // MARK: apibay

    /// apibay's list behind each ranked shelf (`data_top100_<list>.json`).
    /// "207" / "208" (both shelves): the Top 100 of HD movies / of HD episodes, the most
    /// seeded torrents of the moment — what the grids' « Top 100 » reads
    /// (with SD and UHD merged in). "48h_207" / "48h_208": the most seeded
    /// among the torrents UPLOADED in the last 48 hours — a few new
    /// releases, then re-encodes of old films with a hundred seeders (the
    /// movies' list of 2026-11-16: 45 titles, 3 in common with the Top 100).
    /// A shelf's title (`HomeShelfID.defaultTitle`) and cache key follow
    /// its list: changing the list is all a switch takes.
    static let moviesRanking = "207"
    static let showsRanking = "208"

    static func isLast48Hours(_ list: String) -> Bool {
        return list.hasPrefix("48h_")
    }

    /// The fewest titles (releases with an IMDb id) of a complete answer
    /// of the shows' Top 100. Its hundred releases are episodes and season
    /// packs of few shows: 26 on 2026-11-16 (the 48 h list: 49), so the
    /// movies' 20 would take an honest day for a broken answer. Fewer than
    /// this: an incomplete answer (`HomeCachePolicy.decision`), kept only
    /// when nothing fuller is.
    static let showsRankingMinimum = 10

    /// The most seeded HD episodes (`showsRanking`).
    static let topShows = apibay(showsRanking, .show, minimum: showsRankingMinimum)
    /// The most seeded HD movies (`moviesRanking`).
    static let topMovies = apibay(moviesRanking, .movie)
    /// The most seeded UHD movies: order and Dolby Vision / HDR / Atmos
    /// badges of the 4K shelf.
    static let topUHD = apibay("211", .movie)

    private static func apibay(_ list: String, _ kind: HomeItem.Kind, minimum: Int = 20) -> HomeSource {
        return HomeSource(key: apibayPrefix + list.replacingOccurrences(of: "_", with: "-"),
                          request: HomeRequest(host: .apibay, path: "/precompiled/data_top100_\(list).json"),
                          parser: .apibay(kind), minimum: minimum, allowsEmpty: false)
    }

    static let apibayPrefix = "tpb-"

    /// Every apibay list the hub reads. Another one kept on disk is a list
    /// it read before (5.3.0's first builds kept the Top 48 h under
    /// "tpb-48h-207" and "tpb-48h-208"): `HomePlan.isCurrent` says no, the
    /// next refresh deletes it.
    static let apibayLists: Set<String> = [topShows.key, topMovies.key, topUHD.key]

    /// What every key starts with, one prefix per service: the names of
    /// the store's own files (`HomeStore` touches no other file of its
    /// folder), and the host of a list by its key.
    static let keyFamilies: [(prefix: String, host: HomeRequest.Host)] = [
        ("cm-", .cinemeta), ("yts-", .yts), (tvmazePrefix, .tvmaze), (apibayPrefix, .apibay),
    ]

    /// The service the list of a key comes from.
    static func host(ofKey key: String) -> HomeRequest.Host? {
        return keyFamilies.first { key.hasPrefix($0.prefix) }?.host
    }

    /// FNV-1a, in hex: a stable name for a set of ids (Swift's `hashValue`
    /// changes at every launch).
    static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Parsed lists

/// A parsed title with what the filters need and a card does not show.
struct HomeEntry: Codable, Hashable, Sendable {
    var item: HomeItem
    /// Original language, ISO 639-1 ("en"), when the source tells it (YTS, TVMaze).
    var language: String?
    /// TVMaze's popularity, 0…100.
    var weight: Int?
    /// TVMaze's type: "Scripted", "Animation", "Documentary", "Reality"…
    var showType: String?
    /// Series: the episodes around the day the list was fetched, oldest first.
    var episodes: [HomeEpisode]?
    /// apibay: the seeders of every release of the title.
    var seeders: Int?
    /// YTS: how many qualities the title has.
    var qualities: Int?
    /// apibay: the name of the most seeded release.
    var releaseName: String?
    /// apibay: the languages the most seeded release names — the release
    /// that puts the title in the ranking (nil: it names none, or "multi":
    /// the original language, or unknown).
    var releaseLanguages: [String]?
    /// apibay: the seeders of the most seeded release (`releaseName`).
    var releaseSeeders: Int?
    /// apibay: releases without an IMDb id, and what their names read as
    /// ("streetfighter|2026", `HomeParse.readings(ofRelease:kind:)`). Such an
    /// entry has no id: the builder gives it to the title its lists know by
    /// that name, or drops it.
    var readings: [String]?
    /// apibay, an entry without an id: the id of the titled releases of the
    /// list whose names read the same, nil when none does. The builder gives
    /// the entry to that title only, and only when its card has that name.
    var listedUnder: String?

    init(item: HomeItem, language: String? = nil, weight: Int? = nil, showType: String? = nil,
         episodes: [HomeEpisode]? = nil, seeders: Int? = nil, qualities: Int? = nil,
         releaseName: String? = nil, releaseLanguages: [String]? = nil, releaseSeeders: Int? = nil,
         readings: [String]? = nil, listedUnder: String? = nil) {
        self.item = item
        self.language = language
        self.weight = weight
        self.showType = showType
        self.episodes = episodes
        self.seeders = seeders
        self.qualities = qualities
        self.releaseName = releaseName
        self.releaseLanguages = releaseLanguages
        self.releaseSeeders = releaseSeeders
        self.readings = readings
        self.listedUnder = listedUnder
    }

    /// Releases without an IMDb id waiting for a title (`readings`).
    var isPending: Bool {
        return item.imdbId.isEmpty
    }

    /// This ranking entry with the releases of `other` (the same title):
    /// seeders summed, the most seeded release's name and languages, every
    /// format badge, the latest date.
    func adding(releasesOf other: HomeEntry) -> HomeEntry {
        var entry = self
        entry.seeders = (seeders ?? 0) + (other.seeders ?? 0)
        if (other.releaseSeeders ?? 0) > (releaseSeeders ?? 0) {
            entry.releaseSeeders = other.releaseSeeders
            entry.releaseName = other.releaseName
            entry.releaseLanguages = other.releaseLanguages
        }
        entry.item.badges = HomeBadge.ordered(item.badges + other.item.badges)
        entry.item.date = [item.date, other.item.date].compactMap { $0 }.max()
        return entry
    }

    /// A ranking in order: most seeded first, equal seeders in their order.
    static func mostSeededFirst(_ entries: [HomeEntry]) -> [HomeEntry] {
        return entries.enumerated()
            .sorted { ($0.element.seeders ?? 0) != ($1.element.seeders ?? 0) ? ($0.element.seeders ?? 0) > ($1.element.seeders ?? 0) : $0.offset < $1.offset }
            .map(\.element)
    }

    /// A lookup that found nothing, remembered so the title is not asked again.
    static func unknown(imdbId: String, kind: HomeItem.Kind) -> HomeEntry {
        return HomeEntry(item: HomeItem(imdbId: imdbId, kind: kind, title: ""))
    }

    var isUnknown: Bool {
        return item.title.isEmpty
    }

    /// The latest episode aired at `now`.
    func latestAired(_ now: Date) -> HomeEpisode? {
        return (episodes ?? []).last { ($0.airDate ?? .distantFuture) <= now }
    }

    /// The first episode that has not aired at `now`.
    func nextUpcoming(_ now: Date) -> HomeEpisode? {
        return (episodes ?? []).first { ($0.airDate ?? .distantPast) > now }
    }
}

/// One source's answer as memory and the disk cache keep it.
struct HomeSourceList: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version = HomeSourceList.currentVersion
    var key: String
    var savedAt: Date
    /// False when the answer was shorter than expected: shown, never "fresh".
    var complete: Bool
    var entries: [HomeEntry]
}

// MARK: - Plan

/// What one refresh asks, in three phases (feeds-live §5.4).
struct HomePlan: Sendable {
    /// The year of the "of the year" shelves (UTC).
    let year: Int
    /// The days of the aired episodes, today first ("2026-11-14").
    let days: [String]
    /// The shows the user follows, when sending them to Cinemeta is allowed.
    let calendar: HomeSource?
    let genres: [HomeSource]
    /// A light refresh, for the Top Shelf extension (it has seconds and a
    /// small memory budget, not a session): the lists of the first paint
    /// and, with them, the 4K ranking that tells which of their movies have
    /// a Dolby Vision, HDR or Atmos release. Nothing else is asked. What
    /// the page reads does not change: a list a full refresh left in the
    /// same folder is still shown.
    let light: Bool

    init(now: Date, followedShowIds: [String], genres: [(kind: HomeItem.Kind, genre: String)], days: Int = HomeBuilder.Rules.airedDays,
         light: Bool = false) {
        year = CatalogDates.year(of: now)
        self.days = (0..<max(days, 1)).map { CatalogDates.dayString(now.addingTimeInterval(-Double($0) * 86_400)) }
        calendar = HomeSource.calendar(ids: followedShowIds)
        self.genres = genres.map { HomeSource.genre($0.kind, $0.genre) }
        self.light = light
    }

    /// The first paint: hero, trending movies and shows, new movies, 4K, and
    /// the latest episodes read off the trending shows.
    var phase1: [HomeSource] {
        return [.movieTop, .seriesTop, .ytsNew(year), .yts4K] + (light ? [.topUHD] : [])
    }

    /// Right after: the shelves of the year, the new shows, the user's
    /// shows, the aired episodes.
    var phase2: [HomeSource] {
        guard !light else { return [] }
        var sources: [HomeSource] = [.ytsYear(year), .ytsTop(year), .seriesYear(year)]
        if let calendar = calendar { sources.append(calendar) }
        sources += tvmaze
        return sources
    }

    /// The platforms' and the US networks' episodes of each day.
    var tvmaze: [HomeSource] {
        return days.flatMap { [HomeSource.tvmaze(web: true, day: $0), HomeSource.tvmaze(web: false, day: $0)] }
    }

    /// Last: the two rankings, the 4K ranking, the genre shelves.
    var phase3: [HomeSource] {
        guard !light else { return [] }
        return [.topShows, .topMovies, .topUHD] + genres
    }

    /// Every source of the three phases.
    var sources: [HomeSource] {
        return phase1 + phase2 + phase3
    }

    /// Every key the plan can read: the others are leftovers (another day,
    /// another year, shows no longer followed, a ranking's former list).
    func isCurrent(_ key: String) -> Bool {
        if key.hasPrefix(HomeSource.calendarPrefix) { return key == calendar?.key }
        if key.hasPrefix(HomeSource.tvmazePrefix) { return days.contains { key.hasSuffix($0) } }
        if key.hasPrefix(HomeSource.apibayPrefix) { return HomeSource.apibayLists.contains(key) }
        return true
    }
}
