import Foundation

/// Cinemeta (Stremio's public catalog of every IMDb title, keyless) for the
/// Top 100 and title search:
///
///   /catalog/movie/top/search=<q>.json, /catalog/series/top/search=<q>.json
///     → {"metas":[{"id":"tt…","name","releaseInfo","poster",…}]} (no genres)
///   /meta/movie/<tt>.json, /meta/series/<tt>.json
///     → {"meta":{…, "genres", "imdbRating", "description", "background"}}
///     (`{}` for a series asked as a movie or the other way round, except
///     that a series asked as a movie comes back as a "movie" with a ranged
///     "2025–" releaseInfo).
///
/// Answers are cached (metas 6 h, without their bulky fields — a long
/// series' episode list is megabytes —, searches 30 min); failures are not
/// cached. Completions run on an arbitrary background queue; the public
/// wrappers hop to the main queue where they say so.
public enum CinemetaClient {

    /// Cinemeta hosts to try in order. Overridable.
    public static var hosts: [String] = ["https://v3-cinemeta.strem.io"]

    private static let fetcher = IndexFetcher(name: "Cinemeta", timeout: 8, cacheLifetime: 0, backoff: 15)
    private static let metas = TTLCache<[String: Any]>(lifetime: 6 * 3600)
    private static let searches = TTLCache<[[String: Any]]>(lifetime: 30 * 60)

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
    private static let bulkyFields: Set<String> = [
        "videos", "trailerStreams", "trailers", "links", "credits_cast", "credits_crew", "app_extras", "popularities",
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
