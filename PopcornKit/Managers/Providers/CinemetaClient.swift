import Foundation

/// Cinemeta (Stremio's public catalog of every IMDb title, keyless) for the
/// Top 100, title search and the Shows grid:
///
///   /catalog/movie/top/search=<q>.json, /catalog/series/top/search=<q>.json
///     → {"metas":[{"id":"tt…","name","releaseInfo","poster",…}]} (no genres)
///   /catalog/<kind>/<top|imdbRating|year>[/genre=<G>[&skip=<n>]].json
///     → {"metas":[50 full metas], "hasMore", "cacheMaxAge": 14400}: "top"
///     is the popular titles of the moment, "imdbRating" Stremio's "Featured"
///     list (titles on air, NOT sorted by rating), "year" a year's titles
///     newest first (its `genre` extra is the year)
///   /meta/movie/<tt>.json, /meta/series/<tt>.json
///     → {"meta":{…, "genres", "imdbRating", "description", "background"}}
///     (`{}` for a series asked as a movie or the other way round, except
///     that a series asked as a movie comes back as a "movie" with a ranged
///     "2025–" releaseInfo).
///
/// Answers are cached (metas 6 h, without their bulky fields — a long
/// series' episode list is megabytes —, searches 30 min, catalog pages 4 h
/// as the server's `cacheMaxAge` says); failures are not cached. Completions run on an arbitrary background queue; the public
/// wrappers hop to the main queue where they say so.
public enum CinemetaClient {

    /// Cinemeta hosts to try in order. Overridable.
    public static var hosts: [String] = ["https://v3-cinemeta.strem.io"]

    private static let fetcher = IndexFetcher(name: "Cinemeta", timeout: 8, cacheLifetime: 0, backoff: 15)
    private static let metas = TTLCache<[String: Any]>(lifetime: 6 * 3600)
    private static let searches = TTLCache<[[String: Any]]>(lifetime: 30 * 60)
    /// Catalog pages, trimmed (about 40 KB each): the server's own cache
    /// lifetime, a few dozen pages at most.
    private static let catalogs = BoundedTTLCache<[[String: Any]]>(lifetime: 4 * 3600, capacity: 48)

    /// Cinemeta's "movie" / "series" catalogs.
    public enum Kind: String {
        case movie
        case series
    }

    /// What a request came to: the answer (possibly empty: "not there"), or
    /// nil when Cinemeta could not be reached (not cached: asked again next time).
    typealias Answer<Value> = Value?

    /// Search results for `query` (most relevant first), [] on failure.
    public static func search(_ kind: Kind, query: String, completion: @escaping ([[String: Any]]) -> Void) {
        searchAnswer(kind, query: query) { completion($0 ?? []) }
    }

    /// Search results, nil when Cinemeta could not be reached.
    static func searchAnswer(_ kind: Kind, query: String, completion: @escaping (Answer<[[String: Any]]>) -> Void) {
        let terms = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !terms.isEmpty else { return completion([]) }
        let key = "\(kind.rawValue)/\(terms)"
        if let hit = searches.value(for: key) { return completion(hit) }
        let encoded = terms.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#=&"))) ?? terms
        fetcher.fetch(hosts: hosts, path: "/catalog/\(kind.rawValue)/top/search=\(encoded).json") { outcome in
            switch outcome {
            case .data(let data):
                let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard let found = root?["metas"] as? [[String: Any]] else { return completion(nil) }
                searches.set(found, for: key)
                completion(found)
            case .status(let status) where status == 404:
                searches.set([], for: key)
                completion([])
            case .status, .failed:
                completion(nil)
            }
        }
    }

    // MARK: Catalogs

    /// Cinemeta's catalogs (see the type's comment).
    enum Feed: String {
        /// The popular titles of the moment (Stremio's "Popular").
        case top
        /// Stremio's "Featured": titles on air or just out.
        case featured = "imdbRating"
        /// A year's titles, newest first: `genre` is the year ("2026").
        case year
    }

    /// The path of one catalog page ("/catalog/series/top/genre=Sci-Fi&skip=50.json").
    static func catalogPath(_ kind: Kind, _ feed: Feed, genre: String?, skip: Int) -> String {
        var extras: [String] = []
        if let genre = genre, !genre.isEmpty {
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#=&"))
            extras.append("genre=" + (genre.addingPercentEncoding(withAllowedCharacters: allowed) ?? genre))
        }
        if skip > 0 { extras.append("skip=\(skip)") }
        let base = "/catalog/\(kind.rawValue)/\(feed.rawValue)"
        return extras.isEmpty ? base + ".json" : base + "/" + extras.joined(separator: "&") + ".json"
    }

    /// One page (50 titles) of a catalog, without the bulky fields (a series
    /// catalog is 0.5 MB of JSON, 84 % of it the episode lists), `[]` past
    /// the end, nil when Cinemeta could not be reached.
    static func catalog(_ kind: Kind, _ feed: Feed, genre: String? = nil, skip: Int = 0,
                        completion: @escaping (Answer<[[String: Any]]>) -> Void) {
        let path = catalogPath(kind, feed, genre: genre, skip: skip)
        if let hit = catalogs.fresh(path) { return completion(hit) }
        fetcher.fetch(hosts: hosts, path: path) { outcome in
            switch outcome {
            case .data(let data):
                guard let metas = catalogMetas(fromJSON: data) else { return completion(nil) }
                catalogs.set(metas, for: path)
                completion(metas)
            case .status(let status) where status == 404:
                completion([])
            case .status, .failed:
                // A page asked before and gone stale beats nothing.
                completion(catalogs.any(path)?.value)
            }
        }
    }

    /// The fields the grids, the models and the genre filters read.
    private static let catalogFields: Set<String> = [
        "id", "imdb_id", "type", "name", "poster", "background", "logo", "genres", "genre",
        "releaseInfo", "year", "released", "imdbRating", "description", "runtime", "status", "trailerStreams",
    ]

    /// What a trimmed catalog meta keeps of a series' episode list: when
    /// its latest episode aired (ISO 8601) and that episode's season, i.e.
    /// how many seasons have aired. A poster's "New Episode" badge and
    /// "3 Seasons" come from them, without the list itself.
    static let lastAiredField = "lastAired"
    static let seasonsField = "seasons"

    /// A catalog answer's metas, trimmed; nil when it is not a catalog answer.
    static func catalogMetas(fromJSON data: Data, now: Date = Date()) -> [[String: Any]]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let metas = root["metas"] as? [[String: Any]] else { return nil }
        return metas.map { meta in
            var trimmed = meta.filter { catalogFields.contains($0.key) }
            if let latest = latestAired(of: meta["videos"] as? [[String: Any]], now: now) {
                trimmed[lastAiredField] = latest.released
                trimmed[seasonsField] = latest.season
            }
            return trimmed
        }
    }

    /// The latest episode of `videos` that has aired: its date as Cinemeta
    /// wrote it, and its season. Specials (season 0) and the seasons soaps
    /// number by year ("S2026E223") are not seasons.
    static func latestAired(of videos: [[String: Any]]?, now: Date) -> (released: String, season: Int)? {
        var latest: (date: Date, released: String, season: Int)?
        for video in videos ?? [] {
            guard let season = video["season"] as? Int, season > 0, season < 1900,
                  let released = video["released"] as? String,
                  let date = CatalogDates.date(from: released), date <= now else { continue }
            if latest.map({ date > $0.date || (date == $0.date && season > $0.season) }) ?? true {
                latest = (date, released, season)
            }
        }
        return latest.map { ($0.released, $0.season) }
    }

    // MARK: Metas

    /// The full meta of an IMDb title, nil when unknown or on failure.
    public static func meta(_ kind: Kind, imdbId: String, completion: @escaping ([String: Any]?) -> Void) {
        metaAnswer(kind, imdbId: imdbId) { answer in
            guard let meta = answer, !meta.isEmpty else { return completion(nil) }
            completion(meta)
        }
    }

    /// The meta of an IMDb title (`[:]` when Cinemeta doesn't know it), nil
    /// when Cinemeta could not be reached. Without `videos` and the other
    /// bulky fields (`trimmed`).
    static func metaAnswer(_ kind: Kind, imdbId: String, completion: @escaping (Answer<[String: Any]>) -> Void) {
        let key = "\(kind.rawValue)/\(imdbId)"
        if let hit = metas.value(for: key) { return completion(hit) }
        fetcher.fetch(hosts: hosts, path: "/meta/\(kind.rawValue)/\(imdbId).json") { outcome in
            switch outcome {
            case .data(let data):
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return completion(nil) }
                let meta = trimmed(root["meta"] as? [String: Any] ?? [:])
                metas.set(meta, for: key)
                completion(meta)
            case .status(let status) where status == 404:
                metas.set([:], for: key)
                completion([:])
            case .status, .failed:
                completion(nil)
            }
        }
    }

    /// The full series meta, its `videos` (every episode) included, on the
    /// main queue; nil when unknown or unreachable. Not cached (large).
    public static func seriesWithEpisodes(imdbId: String, completion: @escaping ([String: Any]?) -> Void) {
        fetcher.data(hosts: hosts, path: "/meta/series/\(imdbId).json") { data in
            let root = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let meta = root?["meta"] as? [String: Any]
            DispatchQueue.main.async { completion((meta?.isEmpty ?? true) ? nil : meta) }
        }
    }

    /// Fields no caller reads and that make a meta large (a long series'
    /// `videos` is megabytes: The Daily Show, 4,700 episodes).
    /// (`trailerStreams`, a few lines, stays: `Movie(cinemeta:)` reads the
    /// trailer from it.)
    private static let bulkyFields: Set<String> = [
        "videos", "trailers", "links", "credits_cast", "credits_crew", "app_extras", "popularities",
    ]

    static func trimmed(_ meta: [String: Any]) -> [String: Any] {
        return meta.filter { !bulkyFields.contains($0.key) }
    }

    /// Search results as `Movie` / `Show`-ready metas, on the main queue:
    /// complete entries only (a poster: Cinemeta also lists bare stubs).
    public static func searchTitles(_ kind: Kind, query: String, limit: Int = 20,
                                    completion: @escaping ([[String: Any]]) -> Void) {
        search(kind, query: query) { metas in
            let complete = metas.filter { CinemetaMatching.isComplete($0) && CinemetaMatching.id($0) != nil }
            DispatchQueue.main.async { completion(Array(complete.prefix(limit))) }
        }
    }
}

/// A thread-safe dictionary whose entries expire.
final class TTLCache<Value> {
    private let lifetime: TimeInterval
    private let lock = NSLock()
    private var storage: [String: (date: Date, value: Value)] = [:]

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    func value(for key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key] else { return nil }
        guard Date().timeIntervalSince(entry.date) < lifetime else {
            storage[key] = nil
            return nil
        }
        return entry.value
    }

    func set(_ value: Value, for key: String) {
        lock.lock()
        if storage.count > 2000 { storage.removeAll() }
        storage[key] = (Date(), value)
        lock.unlock()
    }
}
