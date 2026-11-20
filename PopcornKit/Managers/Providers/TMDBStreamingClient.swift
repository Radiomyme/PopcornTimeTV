import Foundation

/// TMDB's watch providers: which titles each streaming service offers in a
/// country (JustWatch's data), the services of a country, the countries.
///
/// - The key is the user's (`HomeSettings.tmdbAPIKey`): a v3 API key goes
///   in the query, a v4 read access token in an `Authorization` header.
/// - TMDB knows titles by TMDB ids; the app by IMDb ids. Every title of an
///   answer is given its IMDb id (`/movie|tv/{id}/external_ids`), a few
///   requests at a time, and the pairs are kept on disk for good (an id
///   never changes): a list asked again costs one request.
/// - The hub reaches it through `HomeTransport.live` (host `.tmdb`): the
///   body it gets is TMDB's page with an "imdb_id" in every result.
public final class TMDBStreamingClient: @unchecked Sendable {

    public static let shared = TMDBStreamingClient()

    static let base = "https://api.themoviedb.org/3"
    /// Seconds without a byte before a request is given up.
    static let timeout: TimeInterval = 8
    /// External-id requests in flight at once (TMDB allows about 40 a second).
    static let parallelLookups = 6

    /// The key, read at every request (the user may change it any time).
    var apiKey: () -> String? = { HomeSettings().tmdbAPIKey }

    private let session: URLSession
    private let ids: TMDBIdCache

    init(session: URLSession? = nil, ids: TMDBIdCache = TMDBIdCache()) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = TMDBStreamingClient.timeout
            configuration.timeoutIntervalForResource = TMDBStreamingClient.timeout * 3
            configuration.httpAdditionalHeaders = ["Accept": "application/json"]
            self.session = URLSession(configuration: configuration)
        }
        self.ids = ids
    }

    // MARK: Paths

    /// A page of a service's catalogue in a country, most popular first:
    /// subscription titles only ("flatrate": not the rentals and purchases
    /// TMDB lists under the same service), with a few votes at least (TMDB
    /// lists thousands of unrated fillers).
    static func discoverPath(service: Int, kind: HomeItem.Kind, region: String, page: Int, language: String?) -> String {
        var path = "/discover/\(kind == .movie ? "movie" : "tv")?watch_region=\(region)&with_watch_providers=\(service)"
            + "&with_watch_monetization_types=flatrate&sort_by=popularity.desc&include_adult=false&vote_count.gte=10&page=\(page)"
        if let language = language ?? TMDBStreamingClient.language() { path += "&language=\(language)" }
        return path
    }

    /// The device's first language as TMDB takes it ("fr-FR", "en-US").
    static func language(preferred: [String] = Locale.preferredLanguages) -> String? {
        guard let first = preferred.first else { return nil }
        let parts = first.split(separator: "-")
        guard let code = parts.first, code.count == 2 else { return nil }
        if let region = parts.dropFirst().first(where: { $0.count == 2 }) { return "\(code)-\(region)" }
        return String(code)
    }

    // MARK: Hub

    /// The hub's GET (`HomeTransport.live`, host `.tmdb`): the page, with
    /// every result's IMDb id. nil: no key, no answer, a refused key.
    func fetch(path: String, completion: @escaping @Sendable (Data?) -> Void) {
        let kind: HomeItem.Kind = path.hasPrefix("/discover/tv") ? .show : .movie
        get(path) { data in
            guard let data, var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let results = root["results"] as? [[String: Any]] else { return completion(nil) }
            self.withImdbIds(results, kind: kind) { resolved in
                root["results"] = resolved
                completion(try? JSONSerialization.data(withJSONObject: root))
            }
        }
    }

    // MARK: Catalogue

    /// A service's titles of one kind, page by page (`page` from 1), as
    /// cards. `hasMore`: TMDB has a next page. nil: no answer.
    public func titles(service: Int, kind: HomeItem.Kind, region: String, page: Int,
                       completion: @escaping @Sendable (_ items: [HomeItem]?, _ hasMore: Bool) -> Void) {
        let path = TMDBStreamingClient.discoverPath(service: service, kind: kind, region: region, page: page, language: nil)
        get(path) { data in
            guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let results = root["results"] as? [[String: Any]] else { return completion(nil, false) }
            let pages = (root["total_pages"] as? NSNumber)?.intValue ?? page
            self.withImdbIds(results, kind: kind) { resolved in
                let items = resolved.compactMap { HomeParse.tmdbEntry($0, kind: kind)?.item }
                completion(items, page < min(pages, 500))
            }
        }
    }

    /// The whole catalogue of a service in a country, the movies and the
    /// shows mixed (most popular first, one of each in turn), page after
    /// page: a See All grid's "more". Not thread-safe: one caller at a time.
    public final class CataloguePages: @unchecked Sendable {
        public let service: Int
        public let region: String
        private let client: TMDBStreamingClient
        private var next: [HomeItem.Kind: Int] = [.movie: 1, .show: 1]
        private var over: Set<HomeItem.Kind> = []
        private var seen = Set<String>()
        public private(set) var isLoading = false

        public init(service: Int, region: String, client: TMDBStreamingClient = .shared) {
            self.service = service
            self.region = region
            self.client = client
        }

        public var isOver: Bool { over.count == 2 }

        /// Titles already shown elsewhere (the shelf): not given again.
        public func skip(_ ids: [String]) {
            seen.formUnion(ids)
        }

        /// The next page of each kind, mixed. Calls back on the main queue;
        /// [] when the catalogue is over, nil on a failure. Ignored while a
        /// load is running (its caller gets the page).
        public func load(completion: @escaping ([HomeItem]?) -> Void) {
            guard !isLoading else { return }
            guard !isOver else { return completion([]) }
            isLoading = true
            let group = DispatchGroup()
            let lock = NSLock()
            var answers: [HomeItem.Kind: (items: [HomeItem]?, more: Bool)] = [:]
            for kind in HomeItem.Kind.allCases where !over.contains(kind) {
                group.enter()
                client.titles(service: service, kind: kind, region: region, page: next[kind] ?? 1) { items, more in
                    lock.lock()
                    answers[kind] = (items, more)
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                self.isLoading = false
                var lists: [[HomeItem]] = []
                var failed = true
                for kind in HomeItem.Kind.allCases {
                    guard let answer = answers[kind] else { continue }
                    guard let items = answer.items else { continue }
                    failed = false
                    self.next[kind, default: 1] += 1
                    if !answer.more { self.over.insert(kind) }
                    lists.append(items)
                }
                guard !failed else { return completion(nil) }
                let mixed = TMDBStreamingClient.alternating(lists).filter { self.seen.insert($0.imdbId).inserted }
                completion(mixed)
            }
        }
    }

    /// One of each list in turn: a, b, a, b… then the rest of the longer.
    static func alternating<T>(_ lists: [[T]]) -> [T] {
        var result: [T] = []
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count { result.append(list[index]) }
        }
        return result
    }

    // MARK: Services and countries

    /// The services of a country, the most watched there first (TMDB's
    /// `display_priorities`): movies' and shows' lists merged. nil: no answer.
    public func services(region: String, completion: @escaping @Sendable ([StreamingService]?) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var lists: [[[String: Any]]] = []
        var answered = false
        for kind in ["movie", "tv"] {
            group.enter()
            get("/watch/providers/\(kind)?watch_region=\(region)") { data in
                let results = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["results"] as? [[String: Any]]
                lock.lock()
                if let results { lists.append(results); answered = true }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            guard answered else { return completion(nil) }
            completion(TMDBStreamingClient.services(lists.flatMap { $0 }, region: region))
        }
    }

    static func services(_ results: [[String: Any]], region: String) -> [StreamingService] {
        var best: [Int: (service: StreamingService, priority: Int)] = [:]
        for result in results {
            guard let id = (result["provider_id"] as? NSNumber)?.intValue,
                  let name = (result["provider_name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let priorities = result["display_priorities"] as? [String: Any]
            let priority = (priorities?[region] as? NSNumber)?.intValue ?? (result["display_priority"] as? NSNumber)?.intValue ?? 999
            if let known = best[id], known.priority <= priority { continue }
            best[id] = (StreamingService(id: id, name: name, logoPath: result["logo_path"] as? String), priority)
        }
        return best.values.sorted { $0.priority != $1.priority ? $0.priority < $1.priority : $0.service.name < $1.service.name }.map(\.service)
    }

    /// The ISO codes of the countries TMDB has watch providers for. nil: no answer.
    public func regions(completion: @escaping @Sendable ([String]?) -> Void) {
        get("/watch/providers/regions") { data in
            let results = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["results"] as? [[String: Any]]
            completion(results?.compactMap { $0["iso_3166_1"] as? String })
        }
    }

    /// Does TMDB take this key? nil: no answer (offline, TMDB down).
    public func check(key: String, completion: @escaping @Sendable (Bool?) -> Void) {
        guard let request = request("/configuration", key: key) else { return completion(false) }
        session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 401 { return completion(false) }
            if let status, (200..<300).contains(status), error == nil { return completion(true) }
            completion(nil)
        }.resume()
    }

    // MARK: IMDb ids

    /// The results, each with its "imdb_id" (from the disk, else asked),
    /// in their order; the ones TMDB has none for are left out.
    private func withImdbIds(_ results: [[String: Any]], kind: HomeItem.Kind,
                             completion: @escaping @Sendable ([[String: Any]]) -> Void) {
        let tmdbIds = results.compactMap { ($0["id"] as? NSNumber)?.intValue }
        let missing = tmdbIds.filter { ids.imdbId(kind: kind, tmdbId: $0) == nil }
        lookUp(missing[...], kind: kind) {
            let resolved: [[String: Any]] = results.compactMap { result in
                guard let id = (result["id"] as? NSNumber)?.intValue,
                      let imdb = self.ids.imdbId(kind: kind, tmdbId: id), !imdb.isEmpty else { return nil }
                var result = result
                result["imdb_id"] = imdb
                return result
            }
            self.ids.save()
            completion(resolved)
        }
    }

    /// Asks the external ids of `pending`, `parallelLookups` at a time.
    private func lookUp(_ pending: ArraySlice<Int>, kind: HomeItem.Kind, completion: @escaping @Sendable () -> Void) {
        guard !pending.isEmpty else { return completion() }
        let batch = pending.prefix(TMDBStreamingClient.parallelLookups)
        let group = DispatchGroup()
        for id in batch {
            group.enter()
            get("/\(kind == .movie ? "movie" : "tv")/\(id)/external_ids") { data in
                if let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    let imdb = (root["imdb_id"] as? String).flatMap { HomeParse.isImdbId($0) ? $0 : nil }
                    // "": TMDB has no IMDb id for it (not asked again).
                    self.ids.set(imdb ?? "", kind: kind, tmdbId: id)
                }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            self.lookUp(pending.dropFirst(batch.count), kind: kind, completion: completion)
        }
    }

    // MARK: HTTP

    private func request(_ path: String, key: String) -> URLRequest? {
        let isToken = key.count > 40
        let separator = path.contains("?") ? "&" : "?"
        let address = TMDBStreamingClient.base + path + (isToken ? "" : "\(separator)api_key=\(key)")
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        if isToken { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// The body of a 2xx answer, nil otherwise (no key, refused, offline).
    private func get(_ path: String, completion: @escaping @Sendable (Data?) -> Void) {
        guard let key = apiKey(), let request = request(path, key: key) else { return completion(nil) }
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let data, error == nil, (200..<300).contains(status) else {
                print("[TMDB] \(path.prefix(60)) FAILED status=\(status)")
                return completion(nil)
            }
            completion(data)
        }.resume()
    }

    // MARK: Genres

    /// TMDB's genre ids (movies and TV) under Cinemeta's names, the ones
    /// the Home's filters and facts read.
    static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary", 18: "Drama",
        10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
        878: "Sci-Fi", 53: "Thriller", 10752: "War", 37: "Western",
        10759: "Action", 10765: "Sci-Fi", 10768: "War", 10762: "Family",
    ]
}

/// TMDB id → IMDb id, by kind, on disk ("" for a title that has none).
final class TMDBIdCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String]
    private var dirty = false
    private let file: URL?

    init(file: URL? = TMDBIdCache.defaultFile) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            map = stored
        } else {
            map = [:]
        }
    }

    static var defaultFile: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent("tmdb-imdb-ids.json")
    }

    private static func key(_ kind: HomeItem.Kind, _ tmdbId: Int) -> String {
        return "\(kind == .movie ? "m" : "t")\(tmdbId)"
    }

    func imdbId(kind: HomeItem.Kind, tmdbId: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return map[TMDBIdCache.key(kind, tmdbId)]
    }

    func set(_ imdbId: String, kind: HomeItem.Kind, tmdbId: Int) {
        lock.lock()
        map[TMDBIdCache.key(kind, tmdbId)] = imdbId
        dirty = true
        lock.unlock()
    }

    func save() {
        lock.lock()
        guard dirty, let file else { return lock.unlock() }
        dirty = false
        let data = try? JSONEncoder().encode(map)
        lock.unlock()
        try? data?.write(to: file, options: .atomic)
    }
}
