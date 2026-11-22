import Foundation

/// TMDB's watch providers: which titles each streaming service offers in a
/// country (JustWatch's data), the services of a country, the countries.
///
/// - The key is the user's (`HomeSettings.tmdbAPIKey`): a v3 API key goes
///   in the query, a v4 read access token in an `Authorization` header.
/// - TMDB knows titles by TMDB ids; the app by IMDb ids. Every title of an
///   answer is given its IMDb id (`/movie|tv/{id}/external_ids`), a few
///   requests at a time for the whole app (`parallelLookups`), and the ids
///   found are kept on disk for good (an id never changes): a list asked
///   again costs one request. A lookup that got no answer is tried once
///   more; still none, the page is a failure (nil), not a page with holes.
/// - The hub reaches it through `HomeTransport.live` (host `.tmdb`): the
///   body it gets is TMDB's page with an "imdb_id" in every result.
/// - The titles are asked in English ("en-US"), as the rest of the app
///   names them (Cinemeta's titles): one language on the shelves, and the
///   same name for a title on the Home, in the grids and in Search.
public final class TMDBStreamingClient: @unchecked Sendable {

    /// The app's client. In a DEBUG run with `-PTDebugHomeFixtures <folder>`
    /// it answers from the recorded files of that folder (`TMDBRecorded`)
    /// and keeps the ids it reads in memory only: no request ever reaches
    /// TMDB, and any key is taken (`check(key:)`) — or, with
    /// `-PTDebugHomeState tmdbrefused` (the iPhone and Mac fixture runs),
    /// every key is refused and nothing answers: the screens of a refused
    /// key, without TMDB. With `tmdbdown` no list answers and with
    /// `tmdbsilent` none ever comes, as for the Home's hub: the Settings'
    /// lists of services fail, or keep loading (a key is still taken).
    public static let shared: TMDBStreamingClient = {
        #if DEBUG
        if let folder = UserDefaults.standard.string(forKey: "PTDebugHomeFixtures"), !folder.isEmpty {
            let state = UserDefaults.standard.string(forKey: "PTDebugHomeState")?.lowercased()
            let client = TMDBStreamingClient(recordedIn: URL(fileURLWithPath: folder), refusesEveryKey: state == "tmdbrefused")
            if state == "tmdbdown" {
                client.recorded = { _, completion in completion(nil) }
            } else if state == "tmdbsilent" {
                client.recorded = { _, _ in }
            }
            return client
        }
        #endif
        return TMDBStreamingClient()
    }()

    static let base = "https://api.themoviedb.org/3"
    /// Seconds without a byte before a request is given up.
    static let timeout: TimeInterval = 8
    /// External-id requests in flight at once, every list and grid together
    /// (TMDB allows about 40 a second).
    static let parallelLookups = 6
    /// TMDB serves a discover list up to its 500th page; it refuses the next.
    static let lastPage = 500
    /// The language of the titles and summaries asked.
    static let language = "en-US"

    /// The key, read at every request (the user may change it any time).
    var apiKey: () -> String? = { HomeSettings().tmdbAPIKey }

    /// A GET: the body of a 2xx answer, nil otherwise. Called back on any queue.
    typealias Fetch = @Sendable (_ path: String, _ completion: @escaping @Sendable (Data?) -> Void) -> Void

    /// Answers instead of TMDB (recorded files: `init(recordedIn:)`); nil:
    /// TMDB itself, with the key. Set before the first request.
    var recorded: Fetch?

    /// Seconds before the lookups that got no answer are tried again.
    var retryDelay: TimeInterval = 1

    private let session: URLSession
    private let ids: TMDBIdCache
    /// The key TMDB refused last (401), until it takes it (`isKeyRefused`).
    private let refusedKey = TMDBGathered<String?>(nil)
    private let lookups = TMDBRequestGate(limit: TMDBStreamingClient.parallelLookups)

    /// Recorded answers only: every key is refused, as TMDB refuses a
    /// revoked one (`refusesEveryKey` of `init(recordedIn:)`).
    private(set) var refusesEveryKey = false

    /// A client of recorded answers (`TMDBRecorded`, a DEBUG fixture run):
    /// never a request, ids in memory only, every key taken — or, with
    /// `refusesEveryKey`, every key refused and no answer at all.
    convenience init(recordedIn folder: URL, refusesEveryKey: Bool = false) {
        self.init(ids: TMDBIdCache(file: nil))
        self.refusesEveryKey = refusesEveryKey
        recorded = { path, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                completion(refusesEveryKey ? nil : TMDBRecorded.answer(to: path, in: folder))
            }
        }
    }

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

    /// A page of a service's catalogue in a country, in `sort`'s order:
    /// titles watched with a subscription, free or with ads ("flatrate",
    /// "free", "ads"; %7C is TMDB's « or »), with a few votes at least (TMDB
    /// lists thousands of unrated fillers). TMDB applies these types to the
    /// title, not to the service asked: a title the service only rents or
    /// sells comes too when another service streams it. Subscription
    /// services offer nothing else (Netflix in France: the same 5384 titles
    /// with or without it, 2026-11-21); free services need "free" and "ads"
    /// (JustWatch TV Free in France: 178 titles with "flatrate" alone, 231
    /// with all three; Tubi TV in the US: 16889 and 20001); stores would
    /// list their rentals, which is why `services(region:)` leaves them out
    /// (`isStore`). `today` ("2026-11-20") bounds
    /// the recent ones (TMDB lists announced titles too). In English unless
    /// a `language` is given.
    static func discoverPath(service: Int, kind: HomeItem.Kind, region: String, page: Int, sort: StreamingSort = .popular,
                             genre: Int? = nil, today: String? = nil, language: String? = nil) -> String {
        let movie = kind == .movie
        var path = "/discover/\(movie ? "movie" : "tv")?watch_region=\(region)&with_watch_providers=\(service)"
            + "&with_watch_monetization_types=flatrate%7Cfree%7Cads&include_adult=false"
        switch sort {
        case .popular:
            path += "&sort_by=popularity.desc&vote_count.gte=10"
        case .recent:
            let date = movie ? "primary_release_date" : "first_air_date"
            path += "&sort_by=\(date).desc&\(date).lte=\(today ?? CatalogDates.dayString(Date()))&vote_count.gte=10"
        case .topRated:
            path += "&sort_by=vote_average.desc&vote_count.gte=\(movie ? 300 : 150)"
        }
        if let genre { path += "&with_genres=\(genre)" }
        path += "&page=\(page)"
        path += "&language=\(language ?? TMDBStreamingClient.language)"
        return path
    }

    // MARK: Hub

    /// The hub's GET (`HomeTransport.live`, host `.tmdb`): the page, with
    /// every result's IMDb id. nil: no key, no answer, a refused key — or a
    /// lookup of the page without an answer (the hub keeps the list it has
    /// and asks again at the next refresh, instead of a list with holes).
    func fetch(path: String, completion: @escaping @Sendable (Data?) -> Void) {
        let kind: HomeItem.Kind = path.hasPrefix("/discover/tv") ? .show : .movie
        get(path) { data in
            guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let results = root["results"] as? [[String: Any]] else { return completion(nil) }
            self.withImdbIds(results, kind: kind) { resolved, failed in
                guard failed == 0 else { return completion(nil) }
                var page = root
                page["results"] = resolved
                completion(try? JSONSerialization.data(withJSONObject: page))
            }
        }
    }

    // MARK: Catalogue

    /// A service's titles of one kind, page by page (`page` from 1), as
    /// cards. `hasMore`: TMDB has a next page — a page can be empty and
    /// still have one (none of its titles has an IMDb id): the end is
    /// `hasMore` false, not an empty page. nil: a failure (no answer, or a
    /// lookup of its titles without one), for a Retry.
    /// `genre`: a genre as the app names it ("Science Fiction"; nil or
    /// "All": every genre). One TMDB has no id for, for that kind
    /// (`supportsGenre`), answers an empty last page, without a request: a
    /// grid never shows the whole catalogue under a genre's name. So does
    /// a page past TMDB's last (`lastPage`).
    public func titles(service: Int, kind: HomeItem.Kind, region: String, page: Int, sort: StreamingSort = .popular,
                       genre: String? = nil,
                       completion: @escaping @Sendable (_ items: [HomeItem]?, _ hasMore: Bool) -> Void) {
        var genreId: Int?
        if let genre, !TMDBStreamingClient.isAll(genre) {
            guard let id = TMDBStreamingClient.genreId(genre, kind: kind) else { return completion([], false) }
            genreId = id
        }
        guard page <= TMDBStreamingClient.lastPage else { return completion([], false) }
        let path = TMDBStreamingClient.discoverPath(service: service, kind: kind, region: region, page: page, sort: sort, genre: genreId)
        get(path) { data in
            guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let results = root["results"] as? [[String: Any]] else { return completion(nil, false) }
            let pages = (root["total_pages"] as? NSNumber)?.intValue ?? page
            self.withImdbIds(results, kind: kind) { resolved, failed in
                guard failed == 0 else { return completion(nil, false) }
                let items = resolved.compactMap { HomeParse.tmdbEntry($0, kind: kind)?.item }
                completion(items, page < min(pages, TMDBStreamingClient.lastPage))
            }
        }
    }

    /// The whole catalogue of a service in a country, in an order, page
    /// after page: a See All grid's "more". Movies and shows mixed (one of
    /// each in turn) when both kinds are asked. Not thread-safe: one caller
    /// at a time.
    public final class CataloguePages: @unchecked Sendable {
        public let service: Int
        public let region: String
        public let kinds: [HomeItem.Kind]
        public let sort: StreamingSort
        private let client: TMDBStreamingClient
        private var next: [HomeItem.Kind: Int] = [.movie: 1, .show: 1]
        private var over: Set<HomeItem.Kind> = []
        private var seen = Set<String>()
        public private(set) var isLoading = false

        public init(service: Int, region: String, kinds: [HomeItem.Kind] = HomeItem.Kind.allCases, sort: StreamingSort = .popular,
                    client: TMDBStreamingClient = .shared) {
            self.service = service
            self.region = region
            self.kinds = kinds.isEmpty ? HomeItem.Kind.allCases : kinds
            self.sort = sort
            self.client = client
        }

        public var isOver: Bool { kinds.allSatisfy(over.contains) }

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
            let answers = TMDBGathered<[HomeItem.Kind: (items: [HomeItem]?, more: Bool)]>([:])
            for kind in kinds where !over.contains(kind) {
                group.enter()
                client.titles(service: service, kind: kind, region: region, page: next[kind] ?? 1, sort: sort) { items, more in
                    answers.update { $0[kind] = (items, more) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                self.isLoading = false
                let answers = answers.value
                var lists: [[HomeItem]] = []
                var failed = true
                for kind in self.kinds {
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
    /// `display_priorities`): movies' and shows' lists merged, without the
    /// stores (`isStore`). nil: no answer — or one of the two lists without
    /// one: Settings matches the services chosen to this list and leaves out
    /// the ones it does not have, so the list is whole or none.
    public func services(region: String, completion: @escaping @Sendable ([StreamingService]?) -> Void) {
        let group = DispatchGroup()
        let lists = TMDBGathered<[[[String: Any]]]>([])
        for kind in ["movie", "tv"] {
            group.enter()
            get("/watch/providers/\(kind)?watch_region=\(region)") { data in
                let results = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["results"] as? [[String: Any]]
                if let results { lists.update { $0.append(results) } }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            let answered = lists.value
            guard answered.count == 2 else { return completion(nil) }
            completion(TMDBStreamingClient.services(answered.flatMap { $0 }, region: region))
        }
    }

    static func services(_ results: [[String: Any]], region: String) -> [StreamingService] {
        var best: [Int: (service: StreamingService, priority: Int)] = [:]
        for result in results {
            guard let id = (result["provider_id"] as? NSNumber)?.intValue,
                  let name = (result["provider_name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  !isStore(id: id, name: name) else { continue }
            let priorities = result["display_priorities"] as? [String: Any]
            let priority = (priorities?[region] as? NSNumber)?.intValue ?? (result["display_priority"] as? NSNumber)?.intValue ?? 999
            if let known = best[id], known.priority <= priority { continue }
            best[id] = (StreamingService(id: id, name: name, logoPath: result["logo_path"] as? String), priority)
        }
        return best.values.sorted { $0.priority != $1.priority ? $0.priority < $1.priority : $0.service.name < $1.service.name }.map(\.service)
    }

    /// Stores TMDB lists among its watch providers: what they have is for
    /// rent or sale, and a « subscription » discover of one lists the titles
    /// it rents that another service streams (`discoverPath`). Checked on
    /// TMDB in France on 2026-11-21, title by title: Apple TV Store (2),
    /// Rakuten TV (35), Canal VOD (58), Orange VOD (61), YouTube (192),
    /// VIVA by videofutur (2286), Premiere Max (2307), Pathé Home (2601),
    /// JustWatch TV Store (2784); the others are the well-known stores of
    /// other countries (Google Play Movies, Fandango At Home, Amazon Video,
    /// Chili, Microsoft Store, Sky Store), and Fandango (60), the US cinema
    /// tickets and rentals seller (TMDB's US list, 2026-11-21; its free
    /// service, Fandango at Home Free, 332, stays). A name with « Store » or ending
    /// in « VOD » is one too. Free services (Arte, Pluto TV) and YouTube
    /// Premium are not stores.
    static let storeIds: Set<Int> = [2, 3, 7, 10, 35, 40, 58, 60, 61, 68, 130, 192, 2286, 2307, 2601, 2784]

    static func isStore(id: Int, name: String) -> Bool {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return storeIds.contains(id) || words.contains("store") || words.last == "vod"
    }

    /// The ISO codes of the countries TMDB has watch providers for. nil: no answer.
    public func regions(completion: @escaping @Sendable ([String]?) -> Void) {
        get("/watch/providers/regions") { data in
            let results = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["results"] as? [[String: Any]]
            completion(results?.compactMap { $0["iso_3166_1"] as? String })
        }
    }

    /// Does TMDB take this key? false: refused (401); nil: no answer
    /// (offline, TMDB down). Recorded answers take any key, unasked.
    public func check(key: String, completion: @escaping @Sendable (Bool?) -> Void) {
        if recorded != nil { return completion(!refusesEveryKey) }
        guard let request = request("/configuration", key: key) else { return completion(false) }
        session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 401 {
                self.note(status: 401, key: key)
                return completion(false)
            }
            if let status, (200..<300).contains(status), error == nil {
                self.note(status: status, key: key)
                return completion(true)
            }
            completion(nil)
        }.resume()
    }

    /// TMDB refused the user's key (401) at its last request with it, and
    /// has not taken it since: the screens say the key was refused, not
    /// that TMDB did not answer. False without a key, or with recorded
    /// answers (unless they refuse every key).
    public var isKeyRefused: Bool {
        guard let key = apiKey() else { return false }
        return isKeyRefused(key)
    }

    /// TMDB refused this key at its last request with it (`isKeyRefused`
    /// for a key read elsewhere: Settings' own defaults). False with
    /// recorded answers, unless they refuse every key.
    public func isKeyRefused(_ key: String) -> Bool {
        if recorded != nil { return refusesEveryKey }
        guard let refused = refusedKey.value else { return false }
        return key == refused
    }

    /// Remembers a refusal of `key`, forgets it once TMDB takes the key.
    private func note(status: Int, key: String) {
        if status == 401 {
            refusedKey.update { $0 = key }
        } else if (200..<300).contains(status) {
            refusedKey.update { if $0 == key { $0 = nil } }
        }
    }

    // MARK: IMDb ids

    /// The results, each with its "imdb_id" (from the disk, else asked),
    /// in their order; the ones TMDB has none for are left out. `failed`:
    /// the titles whose lookup got no answer, even tried again (left out
    /// too — a caller that cannot have holes treats the page as a failure).
    private func withImdbIds(_ results: [[String: Any]], kind: HomeItem.Kind,
                             completion: @escaping @Sendable (_ resolved: [[String: Any]], _ failed: Int) -> Void) {
        let tmdbIds = results.compactMap { ($0["id"] as? NSNumber)?.intValue }
        var seen = Set<Int>()
        let missing = tmdbIds.filter { ids.imdbId(kind: kind, tmdbId: $0) == nil && seen.insert($0).inserted }
        lookUp(missing, kind: kind, again: true) { failed in
            let resolved: [[String: Any]] = results.compactMap { result in
                guard let id = (result["id"] as? NSNumber)?.intValue,
                      let imdb = self.ids.imdbId(kind: kind, tmdbId: id), !imdb.isEmpty else { return nil }
                var result = result
                result["imdb_id"] = imdb
                return result
            }
            self.ids.save()
            completion(resolved, failed.count)
        }
    }

    /// Asks the external ids of `pending` through the client's one gate
    /// (`parallelLookups` in flight for the whole app). An answer is kept,
    /// "" when TMDB has no IMDb id; no answer is a failure: with `again`,
    /// the failed ones are asked once more after `retryDelay`. Calls back
    /// with the ones that failed in the end.
    private func lookUp(_ pending: [Int], kind: HomeItem.Kind, again: Bool, completion: @escaping @Sendable (_ failed: [Int]) -> Void) {
        guard !pending.isEmpty else { return completion([]) }
        let group = DispatchGroup()
        let failures = TMDBGathered<[Int]>([])
        for id in pending {
            group.enter()
            lookups.run { done in
                self.get("/\(kind == .movie ? "movie" : "tv")/\(id)/external_ids") { data in
                    if let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        let imdb = (root["imdb_id"] as? String).flatMap { HomeParse.isImdbId($0) ? $0 : nil }
                        // "": TMDB has no IMDb id for it (not asked again in this run).
                        self.ids.set(imdb ?? "", kind: kind, tmdbId: id)
                    } else {
                        failures.update { $0.append(id) }
                    }
                    done()
                    group.leave()
                }
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            let failed = failures.value
            guard again, !failed.isEmpty else { return completion(failed) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + self.retryDelay) {
                self.lookUp(failed, kind: kind, again: false, completion: completion)
            }
        }
    }

    // MARK: HTTP

    private func request(_ path: String, key: String) -> URLRequest? {
        let isToken = TMDBKeySettings.kind(of: key) == .readToken
        let separator = path.contains("?") ? "&" : "?"
        let address = TMDBStreamingClient.base + path + (isToken ? "" : "\(separator)api_key=\(key)")
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        if isToken { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// The body of a 2xx answer, nil otherwise (no key, refused, offline).
    private func get(_ path: String, completion: @escaping @Sendable (Data?) -> Void) {
        if let recorded { return recorded(path, completion) }
        guard let key = apiKey(), let request = request(path, key: key) else { return completion(nil) }
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if error == nil { self.note(status: status, key: key) }
            guard let data, error == nil, (200..<300).contains(status) else {
                print("[TMDB] \(path.prefix(60)) FAILED status=\(status)")
                return completion(nil)
            }
            completion(data)
        }.resume()
    }

    // MARK: Genres

    /// Can a service's titles of this kind be filtered on this genre (as
    /// the app or Cinemeta names it)? "All" can. The grids offer only these
    /// while a service is chosen.
    public static func supportsGenre(_ name: String, kind: HomeItem.Kind) -> Bool {
        return isAll(name) || genreId(name, kind: kind) != nil
    }

    /// "All", the app's genre that filters nothing.
    static func isAll(_ name: String) -> Bool {
        return name.caseInsensitiveCompare(NetworkManager.Genres.all.rawValue) == .orderedSame
    }

    /// TMDB's id of a genre as the app or Cinemeta names it, for a kind:
    /// nil when TMDB has none ("All", "Thriller" for shows).
    static func genreId(_ name: String, kind: HomeItem.Kind) -> Int? {
        // TMDB's movies have a Music genre; Cinemeta, whose names the
        // tables use, has none.
        if kind == .movie, name.caseInsensitiveCompare("Music") == .orderedSame { return 10402 }
        guard let genre = HomeBuilder.cinemetaGenre(name) else { return nil }
        let movies: [String: Int] = [
            "Action": 28, "Adventure": 12, "Animation": 16, "Comedy": 35, "Crime": 80, "Documentary": 99, "Drama": 18,
            "Family": 10751, "Fantasy": 14, "History": 36, "Horror": 27, "Mystery": 9648, "Romance": 10749, "Sci-Fi": 878,
            "Thriller": 53, "War": 10752, "Western": 37,
        ]
        let shows: [String: Int] = [
            "Action": 10759, "Adventure": 10759, "Animation": 16, "Comedy": 35, "Crime": 80, "Documentary": 99, "Drama": 18,
            "Family": 10751, "Fantasy": 10765, "Mystery": 9648, "Sci-Fi": 10765, "War": 10768, "Western": 37,
        ]
        return (kind == .movie ? movies : shows)[genre]
    }

    /// TMDB's genre ids (movies and TV) under Cinemeta's names, the ones
    /// the Home's filters and facts read.
    static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary", 18: "Drama",
        10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
        878: "Sci-Fi", 53: "Thriller", 10752: "War", 37: "Western",
        10759: "Action", 10765: "Sci-Fi", 10768: "War", 10762: "Family",
    ]
}

/// A value several requests' callbacks add to, under a lock.
final class TMDBGathered<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }
}

/// At most `limit` requests in flight; the others wait their turn, in order.
final class TMDBRequestGate: @unchecked Sendable {
    typealias Work = @Sendable (_ done: @escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private let limit: Int
    private var running = 0
    private var waiting: [Work] = []

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    /// Runs `work` now or when a place is free; `work` calls `done` once,
    /// when its request has answered.
    func run(_ work: @escaping Work) {
        lock.lock()
        guard running < limit else {
            waiting.append(work)
            return lock.unlock()
        }
        running += 1
        lock.unlock()
        start(work)
    }

    private func start(_ work: @escaping Work) {
        let once = TMDBGathered(false)
        DispatchQueue.global(qos: .userInitiated).async {
            work { [self] in
                var first = false
                once.update { first = !$0; $0 = true }
                if first { finished() }
            }
        }
    }

    private func finished() {
        lock.lock()
        guard !waiting.isEmpty else {
            running -= 1
            return lock.unlock()
        }
        let next = waiting.removeFirst()
        lock.unlock()
        start(next)
    }
}

/// TMDB id → IMDb id, by kind. The ids found are kept on disk; "" (TMDB
/// has none, yet: a new release often gets its IMDb id days later) stays
/// in memory, so the title is asked again at the next launch.
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

    /// Writes the real ids, under the lock (two lists that end together
    /// write in turn, the newer last). A write that fails is tried again at
    /// the next save.
    func save() {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, let file else { return }
        do {
            let data = try JSONEncoder().encode(map.filter { !$0.value.isEmpty })
            try data.write(to: file, options: .atomic)
            dirty = false
        } catch {
            dirty = true
        }
    }
}

/// TMDB's answers recorded in a folder, for the DEBUG fixture runs
/// (`-PTDebugHomeFixtures <folder>`: `TMDBStreamingClient.shared` and the
/// hubs' recorded transports read them) and the tests. The files, made by
/// tools/tmdb-fixtures.py into PopcornTimeTests/Fixtures/Home:
///
///   tmdb_<movie|tv>_<popular|recent|topRated>_p<page>.json   a discover page of any service and
///                                                            country, every result with its
///                                                            "imdb_id" (fake TMDB ids)
///   tmdb_providers.json                                      the services of a country
///   tmdb_providers_<country>.json                            the services of that country, when
///                                                            recorded (US: Amazon Prime Video is 9)
///   tmdb_regions.json                                        the countries
///
/// The genre and the service of a discover request are not looked at. A
/// page that was not recorded is an empty last page; an external id is
/// read off the recorded pages ({"imdb_id": null} for an id none has).
/// Nothing else is answered.
public enum TMDBRecorded {

    /// The service the recorded answers list nothing for (Apple TV):
    /// a fixture run shows how the Home and the grids say a service listed
    /// nothing.
    public static let emptyService = 350

    /// The recorded file a request reads; nil when it is answered without one.
    public static func fileName(for path: String) -> String? {
        if path.hasPrefix("/watch/providers/regions") { return "tmdb_regions.json" }
        if path.hasPrefix("/watch/providers/") { return "tmdb_providers.json" }
        guard let discover = discover(path) else { return nil }
        if discover.service == emptyService { return "tmdb_empty.json" }
        return "tmdb_\(discover.kind)_\(discover.sort)_p\(discover.page).json"
    }

    /// The body a request is answered with; nil: TMDB "fails".
    public static func answer(to path: String, in folder: URL) -> Data? {
        if path.hasPrefix("/watch/providers/"), !path.hasPrefix("/watch/providers/regions"),
           let region = URLComponents(string: "https://recorded" + path)?.queryItems?.first(where: { $0.name == "watch_region" })?.value,
           region.count == 2, region.allSatisfy({ $0.isASCII && $0.isUppercase }),
           let data = try? Data(contentsOf: folder.appendingPathComponent("tmdb_providers_\(region).json")) {
            return data
        }
        if let name = fileName(for: path), let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { return data }
        if let discover = discover(path) {
            return try? JSONSerialization.data(withJSONObject: ["page": discover.page, "total_pages": discover.page - 1,
                                                                "total_results": 0, "results": [Any]()])
        }
        // "/movie/9100004/external_ids"
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[2] == "external_ids", parts[0] == "movie" || parts[0] == "tv", let id = Int(parts[1]) else { return nil }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("tmdb_\(parts[0])_") && $0.hasSuffix(".json") }.sorted()
        for name in names {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let results = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["results"] as? [[String: Any]],
                  let hit = results.first(where: { ($0["id"] as? NSNumber)?.intValue == id }) else { continue }
            return externalIds(id, kind: String(parts[0]), imdb: hit["imdb_id"] ?? NSNull())
        }
        return externalIds(id, kind: String(parts[0]), imdb: NSNull())
    }

    /// An external_ids answer in TMDB's shape: every field, null when TMDB
    /// has no such id (as it answers for a title without an IMDb id).
    private static func externalIds(_ id: Int, kind: String, imdb: Any) -> Data? {
        var answer: [String: Any] = ["id": id, "imdb_id": imdb, "wikidata_id": NSNull(), "facebook_id": NSNull(),
                                     "instagram_id": NSNull(), "twitter_id": NSNull()]
        if kind == "tv" {
            for name in ["freebase_mid", "freebase_id", "tvdb_id", "tvrage_id"] { answer[name] = NSNull() }
        }
        return try? JSONSerialization.data(withJSONObject: answer)
    }

    /// The kind ("movie", "tv"), order, page and service of a discover path.
    private static func discover(_ path: String) -> (kind: String, sort: String, page: Int, service: Int?)? {
        guard path.hasPrefix("/discover/"), let items = URLComponents(string: "https://recorded" + path)?.queryItems else { return nil }
        func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        let kind = path.hasPrefix("/discover/tv") ? "tv" : "movie"
        let sortBy = value("sort_by")
        let sort = sortBy.hasPrefix("popularity") ? StreamingSort.popular : sortBy.hasPrefix("vote_average") ? .topRated : .recent
        guard let page = Int(value("page")), page >= 1 else { return nil }
        return (kind, sort.rawValue, page, Int(value("with_watch_providers")))
    }
}
