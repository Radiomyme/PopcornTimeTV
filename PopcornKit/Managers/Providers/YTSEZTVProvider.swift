

import Foundation
import Alamofire

/// Default `MediaProvider` impl that talks directly to:
///   - YTS  (yts.mx)         — movies + torrent listings
///   - EZTV (eztvx.to)       — TV-show torrents (planned)
///   - TMDB (themoviedb.org) — show metadata fallback (planned)
///
/// Movies work end-to-end. Show support is currently stubbed out and
/// returns empty arrays; reintroduce by composing EZTV + TMDB queries
/// in `loadShows` and `getShowInfo`. Tracking item: plan Phase 7.
public final class YTSEZTVProvider: MediaProvider {

    private let session: Session = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        // Some public APIs (YTS included) rate-limit or 403 the default
        // Alamofire user-agent. Pose as a regular browser request.
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 11_0) AppleWebKit/605.1.15 PopcornTime/4.2",
            "Accept":     "application/json, text/plain, */*",
        ]
        return Session(configuration: configuration)
    }()

    /// Hosts the provider tries in order. The current official YTS endpoint
    /// (May 2026) is `movies-api.accel.li` — the legacy `yts.mx` domain has
    /// been retired (NXDOMAIN globally) and `yts.bz` is the front-end mirror
    /// that announces the API migration. The remaining entries are kept as
    /// last-resort fallbacks but they're either redirected to the new host
    /// or known broken. The first host that returns 2xx JSON is sticky-
    /// cached in UserDefaults so subsequent launches skip the failed lookups.
    public static var ytsMirrors: [String] = [
        "https://movies-api.accel.li",
        "https://yts.bz",
        "https://yts.am",
        "https://yts.lt",
        "https://yts.rs",
        "https://yts.ag",
    ]

    /// Stored as a UserDefault so we don't pay the DNS-failure cost on every
    /// app launch once a working mirror is identified.
    private static let stickyHostKey = "popcornkit.yts.lastGoodHost"
    private var lastGoodHost: String? {
        get { UserDefaults.standard.string(forKey: YTSEZTVProvider.stickyHostKey) }
        set { UserDefaults.standard.set(newValue, forKey: YTSEZTVProvider.stickyHostKey) }
    }

    private var orderedHosts: [String] {
        guard let sticky = lastGoodHost,
              YTSEZTVProvider.ytsMirrors.contains(sticky)
        else { return YTSEZTVProvider.ytsMirrors }
        var rotated = YTSEZTVProvider.ytsMirrors
        rotated.removeAll { $0 == sticky }
        rotated.insert(sticky, at: 0)
        return rotated
    }

    private struct Path {
        static let listMovies = "/api/v2/list_movies.json"
        static let movieInfo  = "/api/v2/movie_details.json"
        static let movieSuggestions = "/api/v2/movie_suggestions.json"
    }

    public init() {}

    /// YTS `movie_details` objects by IMDb id (with the cast): filled by
    /// `getMovieInfo`, read by `ytsMovieDetails`, so a movie page doesn't ask
    /// YTS for the same details three times (info, cast, suggestions).
    private let detailsCache = NSCache<NSString, NSDictionary>()

    /// Last batch of shows assembled by `loadShows`, keyed by imdb id, so
    /// `getShowInfo` can return the same instance with its episode list.
    private var showCache: [String: Show] = [:]
    private let cacheQueue = DispatchQueue(label: "com.popcorntimetv.popcornkit.eztv.cache")

    /// EZTV mirror chain. `eztvx.to` is the canonical host but most FAIs (and
    /// Apple's `Designed for iPad` Mac sandbox) DNS-block it, so we put a
    /// Cloudflare-fronted alternate first. The sticky-cache below promotes
    /// whichever mirror last worked, so subsequent runs skip the failure.
    public static var eztvMirrors: [String] = [
        "https://eztv.wf",
        "https://eztv.tf",
        "https://eztv.yt",
        "https://eztv1.xyz",
        "https://eztv.re",
        "https://eztvx.to",
    ]
    private static let stickyEztvKey = "popcornkit.eztv.lastGoodHost"
    private var lastGoodEztv: String? {
        get { UserDefaults.standard.string(forKey: YTSEZTVProvider.stickyEztvKey) }
        set { UserDefaults.standard.set(newValue, forKey: YTSEZTVProvider.stickyEztvKey) }
    }
    private var orderedEztvHosts: [String] {
        guard let sticky = lastGoodEztv,
              YTSEZTVProvider.eztvMirrors.contains(sticky)
        else { return YTSEZTVProvider.eztvMirrors }
        var rotated = YTSEZTVProvider.eztvMirrors
        rotated.removeAll { $0 == sticky }
        rotated.insert(sticky, at: 0)
        return rotated
    }

    // MARK: - Movies

    public func loadMovies(page: Int,
                           filter: MovieManager.Filters,
                           genre: NetworkManager.Genres,
                           searchTerm: String?,
                           order: NetworkManager.Orders,
                           completion: @escaping ([Movie]?, NSError?) -> Void) {

        // Top 100: The Pirate Bay's most seeded movies, mapped to IMDb titles.
        // A search typed while it is selected searches the catalog as usual.
        if filter == .top100, (searchTerm ?? "").isEmpty {
            return PirateBayTop100.shared.movies(page: page, genre: genre, completion: completion)
        }

        let sortBy: String = {
            switch filter {
            case .trending, .top100: return "download_count"
            case .popularity: return "seeds"
            case .rating:     return "rating"
            case .date:       return "date_added"
            case .year:       return "year"
            }
        }()

        var params: [String: Any] = [
            "page":     max(page, 1),
            "limit":    50,
            "sort_by":  sortBy,
            "order_by": order == .descending ? "desc" : "asc",
        ]
        if genre != .all {
            params["genre"] = genre.rawValue
        }
        if let term = searchTerm, !term.isEmpty {
            params["query_term"] = term
        }

        // Fetch YTS (primary) and the Time4Popcorn catalog in parallel, then
        // merge by imdb id so the grid / search show titles from both.
        let group = DispatchGroup()
        var ytsMovies: [Movie] = []
        var ytsError: NSError?
        var t4pMovies: [Movie] = []

        group.enter()
        attempt(hosts: orderedHosts, path: Path.listMovies, params: params) { data, error in
            defer { group.leave() }
            guard let data = data else { ytsError = error; return }
            guard
                let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                let root = json as? [String: Any]
            else {
                print("[YTS] ERROR: JSON not parseable")
                return
            }
            if let apiStatus = root["status"] as? String, apiStatus != "ok" {
                let msg = (root["status_message"] as? String) ?? "YTS error"
                print("[YTS] ERROR: api status=\(apiStatus) message=\(msg)")
                ytsError = NSError(domain: "yts", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
                return
            }
            guard
                let payload = root["data"] as? [String: Any],
                let raw     = payload["movies"] as? [[String: Any]]
            else {
                print("[YTS] payload missing data.movies")
                return
            }
            ytsMovies = raw.compactMap(Movie.init(yts:))
            print("[YTS] parsed \(ytsMovies.count)/\(raw.count) movies")
        }

        // Search: Cinemeta (every IMDb title) after T4P + YTS, so titles
        // neither catalog has are found too. Not paginated: page 1 only; its
        // results carry no genres: not with a genre filter.
        var cinemetaMovies: [Movie] = []
        if let term = searchTerm, !term.trimmingCharacters(in: .whitespaces).isEmpty, page <= 1, genre == .all {
            group.enter()
            CinemetaClient.searchTitles(.movie, query: term, limit: 40) { metas in
                cinemetaMovies = YTSEZTVProvider.relevantCinemeta(metas, query: term).compactMap(Movie.init(cinemeta:))
                group.leave()
            }
        }

        group.enter()
        Time4PopcornClient.shared.movies(page: page, searchTerm: searchTerm) { movies in
            var result = movies
            // T4P /list isn't genre-filtered and its `keywords` search can't
            // be relied on server-side, so filter client-side to keep the
            // grid on-genre and search results actually relevant.
            if let term = searchTerm, !term.isEmpty {
                result = result.filter { $0.title.localizedCaseInsensitiveContains(term) }
            }
            if genre != .all {
                let wanted = YTSEZTVProvider.normalizedGenre(genre.rawValue)
                result = result.filter { m in m.genres.contains { YTSEZTVProvider.normalizedGenre($0) == wanted } }
            }
            t4pMovies = result
            group.leave()
        }

        group.notify(queue: .main) {
            if ytsMovies.isEmpty && t4pMovies.isEmpty && cinemetaMovies.isEmpty {
                completion(ytsError == nil ? [] : nil, ytsError)
                return
            }
            // T4P first (primary), YTS appended as fallback/supplement, then
            // Cinemeta's search results. If T4P has no answer, the grid is
            // just the YTS results.
            var seen = Set(t4pMovies.map { $0.id })
            var merged = t4pMovies
            for movie in ytsMovies + cinemetaMovies where seen.insert(movie.id).inserted {
                merged.append(movie)
            }
            if let term = searchTerm, page <= 1 {
                merged = YTSEZTVProvider.exactFirst(merged, query: term) { $0.title }
            }
            print("[Movies] T4P \(t4pMovies.count) + YTS \(ytsMovies.count) + Cinemeta \(cinemetaMovies.count) -> \(merged.count) (page \(page))")
            completion(merged, nil)
        }
    }

    /// Walk through `hosts`, retrying on DNS-failure (-1003), connection-lost
    /// (-1004/-1009/-1001), or any non-2xx response. The first host that
    /// returns parseable bytes wins and is sticky-cached for the next launch.
    private func attempt(hosts: [String],
                         path: String,
                         params: [String: Any],
                         completion: @escaping (Data?, NSError?) -> Void) {
        var remaining = hosts
        var lastError: NSError?

        func tryNext() {
            guard let host = remaining.first else {
                print("[YTS] all mirrors exhausted")
                completion(nil, lastError)
                return
            }
            remaining.removeFirst()
            let url = host + path
            print("[YTS] GET \(url) params=\(params)")

            session.request(url, parameters: params).validate().responseData { [weak self] response in
                let status = response.response?.statusCode ?? -1
                switch response.result {
                case .success(let data):
                    print("[YTS] \(host) status=\(status) bytes=\(data.count)")
                    self?.lastGoodHost = host
                    completion(data, nil)
                case .failure(let err):
                    let nserr = err.underlyingError as NSError? ?? (err as NSError)
                    let code  = nserr.code
                    print("[YTS] \(host) FAILED status=\(status) code=\(code) err=\(nserr.localizedDescription)")
                    lastError = nserr
                    // Retry on DNS / connectivity errors and HTTP 4xx/5xx.
                    let recoverable = code == NSURLErrorCannotFindHost
                                   || code == NSURLErrorCannotConnectToHost
                                   || code == NSURLErrorNetworkConnectionLost
                                   || code == NSURLErrorTimedOut
                                   || code == NSURLErrorDNSLookupFailed
                                   || code == NSURLErrorNotConnectedToInternet
                                   || (status >= 400)
                    if recoverable {
                        tryNext()
                    } else {
                        completion(nil, nserr)
                    }
                }
            }
        }
        tryNext()
    }

    public func getMovieInfo(imdbId: String, completion: @escaping (Movie?, NSError?) -> Void) {
        getMovieInfo(imdbId: imdbId, extraSources: true, completion: completion)
    }

    /// `extraSources` false: no The Pirate Bay / Knaben search (posters and
    /// metadata only, e.g. the Continue Watching row: a burst of searches for
    /// torrents nobody looks at).
    public func getMovieInfo(imdbId: String, extraSources: Bool, completion: @escaping (Movie?, NSError?) -> Void) {
        // Strings, not Bool: Alamofire sends `true` as "1", which YTS ignores
        // (no cast came back).
        let params: [String: Any] = [
            "imdb_id":     imdbId,
            "with_images": "true",
            "with_cast":   "true",
        ]

        // Query YTS (curated qualities, rich metadata), the Torrentio
        // aggregator (a dozen extra indexers — REMUX, HDR, multi-audio) and
        // the Time4Popcorn backend (extra scraped releases) in parallel,
        // then merge every torrent list by info-hash.
        //
        // The Pirate Bay and Knaben (`ExtraTorrentSources`) are searched by
        // "Title Year" for every distinct title + year YTS, T4P and Cinemeta
        // give, as each answers; once YTS, Torrentio and T4P are in, the page
        // waits at most `ExtraTorrentSources.grace` more for them, then
        // filters what arrived with every source's titles and years. Cinemeta
        // (fast, but optional) also stands in for the metadata of a title
        // neither YTS nor T4P has (found by the Cinemeta search): only then
        // does the page wait for it.
        let group = DispatchGroup()
        var ytsMovie: Movie?
        var ytsTitles: [String] = []
        var ytsError: NSError?
        var aggregated: [Torrent] = []
        var t4pMovie: Movie?
        var t4p: [Torrent] = []
        var cinemetaMeta: [String: Any]?
        var cinemetaDone = false
        var whenCinemetaDone: (() -> Void)?
        // Main queue (Alamofire and T4P call back there; Cinemeta hops to it).
        let search = extraSources ? ExtraTorrentSources.shared.movieSearch(imdbId: imdbId) : nil

        CinemetaClient.meta(.movie, imdbId: imdbId) { meta in
            DispatchQueue.main.async {
                // A series asked as a movie comes back with a "2025–" range.
                if let meta = meta, let info = meta["releaseInfo"] as? String, info.count == 4 {
                    cinemetaMeta = meta
                    search?.offer(title: meta["name"] as? String, year: Int(info), yearIsReliable: false)
                }
                cinemetaDone = true
                whenCinemetaDone?()
                whenCinemetaDone = nil
            }
        }

        group.enter()
        attempt(hosts: orderedHosts, path: Path.movieInfo, params: params) { data, error in
            defer { group.leave() }
            guard let data = data else { ytsError = error; return }
            guard
                let json    = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                let root    = json as? [String: Any],
                let payload = root["data"] as? [String: Any],
                let movie   = payload["movie"] as? [String: Any]
            else { return }
            ytsMovie = Movie(yts: movie)
            if (movie["id"] as? Int ?? 0) > 0 {   // 0 = a title YTS doesn't have
                self.detailsCache.setObject(movie as NSDictionary, forKey: imdbId as NSString)
                ytsTitles = [movie["title"], movie["title_english"]].compactMap { $0 as? String }
                search?.offer(title: movie["title"] as? String, year: movie["year"] as? Int)
            }
        }

        group.enter()
        TorrentioClient.shared.streams(imdbId: imdbId) { torrents in
            aggregated = torrents
            group.leave()
        }

        group.enter()
        Time4PopcornClient.shared.movieDetail(imdbId: imdbId) { movie, torrents in
            t4pMovie = movie
            t4p = torrents
            search?.offer(title: movie?.title, year: movie.flatMap { Int($0.year) })
            group.leave()
        }

        group.notify(queue: .main) {
            func finish() {
                // Prefer YTS's richer metadata, but fall back to T4P's so a
                // T4P-only title (absent from YTS) is still openable, then to
                // Cinemeta's (a title only the Cinemeta search found).
                guard let base = ytsMovie ?? t4pMovie ?? cinemetaMeta.flatMap(Movie.init(cinemeta:)) else {
                    completion(nil, ytsError)
                    return
                }
                // Every source's title and year count: they don't always agree
                // (Amélie: 2001 on YTS, 2002 on Cinemeta). Read when the
                // searches are in: Cinemeta may have answered meanwhile.
                func identity() -> ReleaseMatch.MovieIdentity {
                    var titles: [String] = []
                    for title in [base.title] + ytsTitles + [t4pMovie?.title, cinemetaMeta?["name"] as? String].compactMap({ $0 })
                        where !title.isEmpty && !titles.contains(title) {
                        titles.append(title)
                    }
                    let years = Set([base.year, t4pMovie?.year ?? "", (cinemetaMeta?["releaseInfo"] as? String) ?? ""]
                        .compactMap { Int($0.prefix(4)) }.filter { $0 > 0 })
                    return ReleaseMatch.MovieIdentity(titles: titles, years: years, imdbId: imdbId)
                }
                func deliver(_ extra: [Torrent]) {
                    var movie = base
                    let before = movie.torrents.count
                    let legacy = aggregated + t4p
                    let added = ExtraTorrentSources.novel(extra, beside: movie.torrents + legacy)
                    movie.torrents = TorrentioClient.merge(movie.torrents, with: legacy + added)
                    print("[YTS+Torrentio+T4P+TPB/Knaben] \(imdbId): \(before) base + \(aggregated.count) aggregated + \(t4p.count) t4p + \(added.count)/\(extra.count) new extra -> \(movie.torrents.count) torrents")
                    completion(movie, nil)
                }
                guard let search = search else { return deliver([]) }
                search.finish(identity: identity, completion: deliver)
            }
            if ytsMovie == nil && t4pMovie == nil && !cinemetaDone {
                whenCinemetaDone = finish   // only Cinemeta can name it
            } else {
                finish()
            }
        }
    }

    // MARK: - Search ranking

    /// The Cinemeta search results worth adding to a search: real titles
    /// only (a start year, at most next year: no bare stub, nothing merely
    /// announced); Cinemeta's first three (its most popular matches, alternate
    /// titles included: "l'odyssée" finds "The Odyssey"), then those whose
    /// title holds every word searched (accents and punctuation ignored), in
    /// Cinemeta's order; ten at most. Loosely related titles further down
    /// ("la haine" → "The Hate U Give") are left out.
    static func relevantCinemeta(_ metas: [[String: Any]], query: String) -> [[String: Any]] {
        let wanted = Set(ReleaseMatch.words(query))
        let nextYear = Calendar(identifier: .gregorian).component(.year, from: Date()) + 1
        let real = metas.filter { meta in
            guard let year = CinemetaMatching.startYear(meta), (1880...nextYear).contains(year) else { return false }
            return meta["name"] is String
        }
        var result: [[String: Any]] = []
        for (index, meta) in real.enumerated() where result.count < 10 {
            let name = meta["name"] as? String ?? ""
            if index < 3 || (!wanted.isEmpty && wanted.isSubset(of: ReleaseMatch.words(name))) { result.append(meta) }
        }
        return result
    }

    /// Search results with the titles that are exactly what was typed first,
    /// then those that start with it, then the rest, each in their order:
    /// "hope" lists "Hope" (2026) before "Hope Floats" and "Grace and Hope".
    static func exactFirst<Item>(_ items: [Item], query: String, title: (Item) -> String) -> [Item] {
        let wanted = ReleaseMatch.titleWords(query)
        guard !wanted.isEmpty else { return items }
        func tier(_ item: Item) -> Int {
            let words = ReleaseMatch.titleWords(title(item))
            if words == wanted { return 0 }
            if words.starts(with: wanted) { return 1 }
            return 2
        }
        return items.enumerated()
            .sorted { tier($0.element) != tier($1.element) ? tier($0.element) < tier($1.element) : $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: - Shows (EZTV + TVMaze)

    /// Catalog entry point.
    ///
    /// - Search: TVMaze full-text search (EZTV has no search API). Torrents
    ///   are resolved later by `getShowInfo` when a result is opened.
    /// - Browse: fetch a page of episode torrents from EZTV, group by
    ///   imdb_id, resolve show metadata in parallel via TVMaze, then apply
    ///   the requested genre filter and sort locally (EZTV itself exposes
    ///   neither).
    public func loadShows(page: Int,
                          filter: ShowManager.Filters,
                          genre: NetworkManager.Genres,
                          searchTerm: String?,
                          order: NetworkManager.Orders,
                          completion: @escaping ([Show]?, NSError?) -> Void) {

        // Top 100: The Pirate Bay's most seeded shows, mapped to IMDb titles.
        // A search typed while it is selected searches the catalog as usual.
        if filter == .top100, (searchTerm ?? "").isEmpty {
            return PirateBayTop100.shared.shows(page: page, genre: genre, completion: completion)
        }

        // Base source (TVMaze search or EZTV browse) and the Time4Popcorn
        // catalog run in parallel; results merge by imdb id so the shows grid
        // and search surface titles from both.
        let group = DispatchGroup()
        var baseShows: [Show] = []
        var baseError: NSError?
        var t4pShows: [Show] = []

        group.enter()
        Time4PopcornClient.shared.shows(page: page, searchTerm: searchTerm) { shows in
            var result = shows
            if let term = searchTerm, !term.isEmpty {
                result = result.filter { $0.title.localizedCaseInsensitiveContains(term) }
            }
            if genre != .all {
                let wanted = YTSEZTVProvider.normalizedGenre(genre.rawValue)
                result = result.filter { s in s.genres.contains { YTSEZTVProvider.normalizedGenre($0) == wanted } }
            }
            t4pShows = result
            group.leave()
        }

        // Search: Cinemeta's series (every IMDb title) beside TVMaze's.
        // Page 1 only, and not with a genre filter (no genres in its results).
        var cinemetaShows: [Show] = []
        if let term = searchTerm, !term.trimmingCharacters(in: .whitespaces).isEmpty, page <= 1, genre == .all {
            group.enter()
            CinemetaClient.searchTitles(.series, query: term, limit: 40) { metas in
                cinemetaShows = YTSEZTVProvider.relevantCinemeta(metas, query: term).compactMap(Show.init(cinemeta:))
                group.leave()
            }
        }

        group.enter()
        if let term = searchTerm, !term.isEmpty {
            // TVMaze search isn't paginated — only fetch it on page 1;
            // subsequent pages come from T4P's paginated catalog above.
            if page <= 1 {
                searchShows(term) { shows, error in
                    baseShows = shows ?? []
                    baseError = error
                    group.leave()
                }
            } else {
                group.leave()
            }
        } else {
            let params: [String: Any] = ["limit": 100, "page": max(page, 1)]
            attemptEztv(hosts: orderedEztvHosts, path: "/api/get-torrents", params: params) { [weak self] data, error in
                guard let self = self else { group.leave(); return }
                guard
                    let data = data,
                    let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                    let root = json as? [String: Any],
                    let raw  = root["torrents"] as? [[String: Any]]
                else {
                    print("[EZTV] JSON parse failed")
                    baseError = error
                    group.leave()
                    return
                }
                print("[EZTV] got \(raw.count) torrents")
                self.buildShows(from: raw, filter: filter, genre: genre) { shows, _ in
                    baseShows = shows ?? []
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            if baseShows.isEmpty && t4pShows.isEmpty && cinemetaShows.isEmpty {
                completion(baseError == nil ? [] : nil, baseError)
                return
            }
            // T4P first (primary), EZTV/TVMaze appended as fallback/supplement,
            // then Cinemeta's search results.
            var seen = Set(t4pShows.map { $0.id })
            var merged = t4pShows
            for show in baseShows + cinemetaShows where seen.insert(show.id).inserted {
                merged.append(show)
            }
            if let term = searchTerm, page <= 1 {
                merged = YTSEZTVProvider.exactFirst(merged, query: term) { $0.title }
            }
            print("[Shows] T4P \(t4pShows.count) + base \(baseShows.count) + Cinemeta \(cinemetaShows.count) -> \(merged.count) (page \(page))")
            completion(merged, nil)
        }
    }

    private func searchShows(_ term: String, completion: @escaping ([Show]?, NSError?) -> Void) {
        let url = "https://api.tvmaze.com/search/shows"
        session.request(url, parameters: ["q": term]).validate().responseData { response in
            switch response.result {
            case .failure(let error):
                DispatchQueue.main.async { completion(nil, error.underlyingError as NSError? ?? error as NSError) }
            case .success(let data):
                var shows: [Show] = []
                if let json = try? JSONSerialization.jsonObject(with: data),
                   let results = json as? [[String: Any]] {
                    for result in results {
                        guard
                            let dict = result["show"] as? [String: Any],
                            let imdb = (dict["externals"] as? [String: Any])?["imdb"] as? String,
                            let show = Show(tvmaze: dict, imdbId: imdb)
                        else { continue }
                        shows.append(show)
                    }
                }
                print("[TVMaze] search '\(term)' -> \(shows.count) shows")
                DispatchQueue.main.async { completion(shows, nil) }
            }
        }
    }

    private func attemptEztv(hosts: [String],
                             path: String,
                             params: [String: Any],
                             completion: @escaping (Data?, NSError?) -> Void) {
        var remaining = hosts
        var lastError: NSError?
        func tryNext() {
            guard let host = remaining.first else {
                print("[EZTV] all mirrors exhausted")
                completion(nil, lastError)
                return
            }
            remaining.removeFirst()
            let url = host + path
            print("[EZTV] GET \(url) params=\(params)")
            session.request(url, parameters: params).validate().responseData { [weak self] response in
                let status = response.response?.statusCode ?? -1
                switch response.result {
                case .success(let data):
                    print("[EZTV] \(host) status=\(status) bytes=\(data.count)")
                    self?.lastGoodEztv = host
                    completion(data, nil)
                case .failure(let err):
                    let nserr = err.underlyingError as NSError? ?? (err as NSError)
                    let code  = nserr.code
                    print("[EZTV] \(host) FAILED status=\(status) code=\(code) err=\(nserr.localizedDescription)")
                    lastError = nserr
                    let recoverable = code == NSURLErrorCannotFindHost
                                   || code == NSURLErrorCannotConnectToHost
                                   || code == NSURLErrorNetworkConnectionLost
                                   || code == NSURLErrorTimedOut
                                   || code == NSURLErrorDNSLookupFailed
                                   || code == NSURLErrorNotConnectedToInternet
                                   || (status >= 400)
                    if recoverable {
                        tryNext()
                    } else {
                        completion(nil, nserr)
                    }
                }
            }
        }
        tryNext()
    }

    /// Assemble the complete detail-page payload for one show:
    ///
    ///   1. TVMaze `lookup/shows?imdb=` — canonical metadata + TVMaze id.
    ///   2. TVMaze `shows/{id}/episodes` — the FULL episode guide (titles,
    ///      summaries, stills, air dates) for every season.
    ///   3. EZTV `get-torrents?imdb_id=` — every torrent the indexer has for
    ///      the show (paginated), merged into the guide per episode.
    ///
    /// Episodes without a torrent are kept: the play flow falls back to the
    /// Torrentio aggregator at click time, which covers most catalog gaps.
    public func getShowInfo(imdbId: String, completion: @escaping (Show?, NSError?) -> Void) {
        let cached = cacheQueue.sync { showCache[imdbId] }
        if let cached = cached {
            DispatchQueue.main.async { completion(cached, nil) }
            return
        }

        fetchTVMaze(imdbId: imdbId) { [weak self] tvmaze in
            guard let self = self else { return }
            guard let tvmaze = tvmaze, var show = Show(tvmaze: tvmaze, imdbId: imdbId, episodes: []) else {
                // TVMaze doesn't know it (a series only the Cinemeta search
                // found): Cinemeta's own episode list, torrents at play time.
                self.cinemetaShow(imdbId: imdbId) { show in
                    if let show = show { self.cacheQueue.sync { self.showCache[imdbId] = show } }
                    completion(show, nil)
                }
                return
            }

            let group = DispatchGroup()
            var guide: [[String: Any]] = []
            var torrentEntries: [[String: Any]] = []
            // EZTV may name the releases after an alternate title ("The
            // Doll" for "Lalka"): those count as the show's too.
            var titles = [show.title]
            var akasKnown = false

            if let tvmazeId = tvmaze["id"] as? Int {
                group.enter()
                self.fetchTVMazeEpisodes(tvmazeId: tvmazeId) { episodes in
                    guide = episodes
                    group.leave()
                }
                group.enter()
                self.fetchTVMazeAkas(tvmazeId: tvmazeId) { akas in
                    if let akas {
                        titles += akas
                        akasKnown = true
                    }
                    group.leave()
                }
            }

            group.enter()
            self.fetchAllEztvTorrents(imdbId: imdbId) { entries in
                torrentEntries = entries
                group.leave()
            }

            group.notify(queue: .main) {
                // Alternate titles unknown (request failed) while the title
                // alone would drop releases: they may be named after one of
                // them ("Money Heist"), so keep them all this time and don't
                // cache the show: the next opening asks again.
                let complete = akasKnown || YTSEZTVProvider.releases(torrentEntries, of: titles).count == torrentEntries.count
                show.episodes = self.mergedEpisodes(guide: guide, eztvEntries: torrentEntries, show: show,
                                                    titles: complete ? titles : [])
                if complete { self.cacheQueue.sync { self.showCache[imdbId] = show } }
                print("[EZTV] getShowInfo \(imdbId): guide=\(guide.count) torrents=\(torrentEntries.count) episodes=\(show.episodes.count)")
                completion(show, nil)
            }
        }
    }

    /// A show TVMaze doesn't know, from Cinemeta: its meta and its episode
    /// list (`videos`: season, episode, name, release date, overview,
    /// thumbnail; specials left out). Main queue.
    private func cinemetaShow(imdbId: String, completion: @escaping (Show?) -> Void) {
        CinemetaClient.seriesWithEpisodes(imdbId: imdbId) { meta in
            guard let meta = meta, var show = Show(cinemeta: meta) else { return completion(nil) }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoPlain = ISO8601DateFormatter()
            var episodes: [Episode] = []
            var seen = Set<String>()
            for video in (meta["videos"] as? [[String: Any]]) ?? [] {
                guard let season = video["season"] as? Int, season > 0,
                      let number = (video["episode"] as? Int) ?? (video["number"] as? Int), number > 0,
                      seen.insert("\(season)x\(number)").inserted else { continue }
                let name = ((video["name"] as? String) ?? (video["title"] as? String) ?? "Episode \(number)").removingHtmlEncoding
                let released = (video["released"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
                var episode = Episode(
                    title: name,
                    id: "\(show.id)-s\(season)e\(number)",
                    slug: name.slugged,
                    summary: ((video["overview"] as? String) ?? (video["description"] as? String) ?? "No summary available.".localized).strippedOfHtml,
                    largeBackgroundImage: video["thumbnail"] as? String,
                    show: show,
                    episode: number,
                    season: season,
                    firstAirDate: released ?? .distantPast)
                episode.show = show
                episodes.append(episode)
            }
            episodes.sort { $0.season == $1.season ? $0.episode < $1.episode : $0.season < $1.season }
            show.episodes = episodes
            print("[Cinemeta] getShowInfo \(imdbId): TVMaze doesn't know it, \(episodes.count) episodes from Cinemeta")
            completion(episodes.isEmpty ? nil : show)
        }
    }

    private func buildShows(from raw: [[String: Any]],
                            filter: ShowManager.Filters,
                            genre: NetworkManager.Genres,
                            completion: @escaping ([Show]?, NSError?) -> Void) {
        // Group EZTV torrents by imdb_id (string form, since EZTV stores it
        // as a 7- or 8-digit number without "tt" prefix).
        var grouped: [String: [[String: Any]]] = [:]
        for entry in raw {
            guard let imdb = entry["imdb_id"] as? String, !imdb.isEmpty else { continue }
            grouped[imdb, default: []].append(entry)
        }
        guard !grouped.isEmpty else {
            DispatchQueue.main.async { completion([], nil) }
            return
        }

        let group = DispatchGroup()
        var shows: [Show] = []
        let lock = NSLock()

        for (imdbNumeric, entries) in grouped {
            group.enter()
            // Construct an `imdb_id` parameter for TVMaze — pad the numeric
            // form back to "tt"+digits, with at least 7 digits as is the
            // canonical IMDB ID width.
            let padded = String(imdbNumeric).leftPadded(to: 7, with: "0")
            let imdbId = "tt\(padded)"
            self.fetchTVMaze(imdbId: imdbId) { tvmaze in
                guard let tvmaze = tvmaze, let show = Show(tvmaze: tvmaze, imdbId: imdbId, episodes: []) else {
                    group.leave()
                    return
                }
                let add: ([String]) -> Void = { titles in
                    // Only another show's releases filed under this IMDb id:
                    // not this show's latest torrents, keep it out of the list.
                    let own = YTSEZTVProvider.releases(entries, of: titles)
                    if !own.isEmpty {
                        var built = show
                        built.episodes = self.mergedEpisodes(guide: [], eztvEntries: own, show: show, titles: titles)
                        lock.lock(); shows.append(built); lock.unlock()
                    }
                    group.leave()
                }
                // Releases not named after the TVMaze title: its alternate
                // titles too ("Ye Gou Gu Tou" for "Love For You") — asked
                // only then, one call per such show.
                let titles = [show.title]
                if YTSEZTVProvider.releases(entries, of: titles).count < entries.count, let tvmazeId = tvmaze["id"] as? Int {
                    // Unknown alternate titles (request failed): no filter.
                    self.fetchTVMazeAkas(tvmazeId: tvmazeId) { akas in add(akas.map { titles + $0 } ?? []) }
                } else {
                    add(titles)
                }
            }
        }

        group.notify(queue: .main) {
            var result = shows

            if genre != .all {
                let wanted = YTSEZTVProvider.normalizedGenre(genre.rawValue)
                result = result.filter { show in
                    show.genres.contains { YTSEZTVProvider.normalizedGenre($0) == wanted }
                }
            }

            switch filter {
            case .name:
                result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            case .rating:
                result.sort { $0.rating > $1.rating }
            case .year:
                result.sort { $0.year > $1.year }
            case .popularity, .top100:
                // Best proxy EZTV gives us: total seeders across the page's
                // torrents for that show.
                let seeds: (Show) -> Int = { $0.episodes.flatMap(\.torrents).map(\.seeds).reduce(0, +) }
                result.sort { seeds($0) > seeds($1) }
            case .trending, .date:
                // Most recent episode release first — matches the "Latest"
                // feel of the films tab.
                let latest: (Show) -> Date = { $0.episodes.map(\.firstAirDate).max() ?? .distantPast }
                result.sort { latest($0) > latest($1) }
            }

            // Deliberately NOT cached in showCache: catalog entries only
            // hold the current page's torrents, and getShowInfo builds the
            // complete guide on demand — a partial entry must never shadow
            // that full fetch.
            print("[EZTV] built \(result.count)/\(shows.count) shows from \(grouped.count) imdb groups (filter=\(filter.rawValue) genre=\(genre.rawValue))")
            completion(result, nil)
        }
    }

    /// Merge the TVMaze episode guide with EZTV torrents into one Episode
    /// per (season, episode), sorted by season then episode. Torrents for
    /// the same episode (different qualities/releases) are attached to that
    /// single Episode instead of surfacing as duplicate cells.
    private func mergedEpisodes(guide: [[String: Any]],
                                eztvEntries: [[String: Any]],
                                show: Show,
                                titles: [String]) -> [Episode] {
        struct Key: Hashable { let season: Int; let episode: Int }

        var torrentsByKey: [Key: [Torrent]] = [:]
        var titleByKey: [Key: String] = [:]
        var dateByKey: [Key: Date] = [:]
        let ownEntries = YTSEZTVProvider.releases(eztvEntries, of: titles)
        if ownEntries.count < eztvEntries.count {
            print("[EZTV] \(show.id) '\(show.title)': dropped \(eztvEntries.count - ownEntries.count)/\(eztvEntries.count) releases of another show")
        }
        for entry in ownEntries {
            let season  = Int((entry["season"]  as? String) ?? "0") ?? 0
            let episode = Int((entry["episode"] as? String) ?? "0") ?? 0
            // episode 0 == season packs / specials without numbering; the
            // guide can't anchor them so they'd render as junk rows.
            guard episode > 0, let torrent = YTSEZTVProvider.torrent(fromEztv: entry) else { continue }
            let key = Key(season: season, episode: episode)
            torrentsByKey[key, default: []].append(torrent)
            if titleByKey[key] == nil, let title = entry["title"] as? String {
                titleByKey[key] = title.removingHtmlEncoding
            }
            if let unix = entry["date_released_unix"] as? Int, unix > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(unix))
                dateByKey[key] = min(dateByKey[key] ?? date, date)
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var episodes: [Episode] = []
        var seenKeys = Set<Key>()

        for dict in guide {
            guard
                let season = dict["season"] as? Int,
                let number = dict["number"] as? Int
            else { continue }
            let key = Key(season: season, episode: number)
            seenKeys.insert(key)

            let image = (dict["image"] as? [String: Any])
            let airdate = (dict["airdate"] as? String).flatMap { dateFormatter.date(from: $0) }
            let summary = ((dict["summary"] as? String) ?? "No summary available.".localized).strippedOfHtml
            let name = ((dict["name"] as? String) ?? "Episode \(number)").removingHtmlEncoding

            var episode = Episode(
                title: name,
                id: "\(show.id)-s\(season)e\(number)",
                slug: name.slugged,
                summary: summary,
                torrents: (torrentsByKey[key] ?? []).sorted(by: <),
                largeBackgroundImage: ImageProxy.proxied(image?["original"] as? String ?? image?["medium"] as? String),
                show: show,
                episode: number,
                season: season,
                firstAirDate: airdate ?? dateByKey[key] ?? .distantPast)
            episode.show = show
            episodes.append(episode)
        }

        // Torrents for episodes the guide doesn't know (brand-new airings,
        // guide gaps, specials, revivals, soaps the guide numbers by year)
        // still deserve a row. Another show's releases filed under this
        // IMDb id were already dropped by name (`releases(_:of:)`).
        for (key, torrents) in torrentsByKey where !seenKeys.contains(key) {
            var episode = Episode(
                title: titleByKey[key] ?? "Episode \(key.episode)",
                id: "\(show.id)-s\(key.season)e\(key.episode)",
                summary: "No summary available.".localized,
                torrents: torrents.sorted(by: <),
                show: show,
                episode: key.episode,
                season: key.season,
                firstAirDate: dateByKey[key] ?? .distantPast)
            episode.show = show
            episodes.append(episode)
        }

        episodes.sort { $0.season == $1.season ? $0.episode < $1.episode : $0.season < $1.season }
        return episodes
    }

    /// Build a Torrent from one EZTV `get-torrents` entry. Quality/codec is
    /// parsed from the filename since EZTV has no structured fields for it.
    static func torrent(fromEztv entry: [String: Any]) -> Torrent? {
        guard let magnet = entry["magnet_url"] as? String, !magnet.isEmpty else { return nil }
        let filename = (entry["filename"] as? String) ?? (entry["title"] as? String) ?? ""
        let size: String? = (entry["size_bytes"] as? String).flatMap {
            guard let bytes = Double($0) else { return nil }
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .binary
            return formatter.string(fromByteCount: Int64(bytes))
        }
        var torrent = Torrent(
            health:  .unknown,
            url:     magnet,
            quality: filename,
            seeds:   entry["seeds"] as? Int ?? 0,
            peers:   entry["peers"] as? Int ?? 0,
            size:    size,
            tags:    VideoTags.parse(filename))
        var label = torrent.qualityValue.displayLabel + torrent.tags.displaySuffix
        if label.isEmpty { label = "Unknown".localized }
        torrent.quality = label + " — EZTV"
        torrent.qualityValue = VideoQuality.parse(filename)
        torrent.tags = VideoTags.parse(filename)
        return torrent
    }

    // MARK: Release names

    /// The entries whose release name names the show, under any of `titles`
    /// (its TVMaze title, then its alternate titles: `fetchTVMazeAkas`).
    /// EZTV files some releases of other shows under a show's IMDb id:
    /// every "Breaking Bad" (tt0903747) entry is in fact "Breaking Brad
    /// S09E02 …", a different show, which added seasons 6–9 and attached
    /// wrong torrents to S1–S5. Entries without a title are kept.
    static func releases(_ entries: [[String: Any]], of titles: [String]) -> [[String: Any]] {
        let forms = titles.flatMap(nameFormVariants)
        guard !forms.isEmpty else { return entries }
        return entries.filter { entry in
            guard let title = (entry["title"] as? String) ?? (entry["filename"] as? String), !title.isEmpty else { return true }
            let release = releaseName(title)
            return release.isEmpty || forms.contains { releaseMatches(release, forms: $0) }
        }
    }

    /// True when the release name, up to its SxxEyy / NxNN marker or its
    /// air date (daily shows), names the show: the same words (case,
    /// accents, punctuation, "&" / "and", a leading "The", a trailing year
    /// or country code ignored), or the title with a leading brand
    /// ("Marvel's …" / "Late Night with …") or a trailing subtitle or host
    /// dropped, or an acronym of its last words ("Law and Order SVU").
    /// Accented letters are also matched dropped ("Shgun" for "Shōgun"),
    /// as EZTV writes them.
    static func releaseMatches(_ releaseTitle: String, show showTitle: String) -> Bool {
        let forms = nameFormVariants(showTitle)
        let release = releaseName(releaseTitle)
        return forms.isEmpty || release.isEmpty || forms.contains { releaseMatches(release, forms: $0) }
    }

    /// The show part of a release name, as joined name words: cut at its
    /// SxxEyy / NxNN marker or at a "2026 11 09" air date.
    private static func releaseName(_ releaseTitle: String) -> String {
        var name = releaseTitle
        let marker = #"(?i)(^|[^a-z0-9])(s\d{1,2}\s?e\d{1,3}|\d{1,2}x\d{1,3}|(19|20)\d{2}[ ._-]\d{2}[ ._-]\d{2})([^0-9]|$)"#
        if let range = name.range(of: marker, options: .regularExpression) {
            name = String(name[..<range.lowerBound])
        }
        return nameWords(name).joined()
    }

    private static func releaseMatches(_ release: String, forms: NameForms) -> Bool {
        if forms.acronyms.contains(release) { return true }
        let full = forms.full
        if release == full || release.hasPrefix(full) { return true }
        if release.count >= 4, full.hasSuffix(release) { return true }
        // No "release is the start of the title" rule: it kept Netflix's
        // "Daredevil S01E03" under "Daredevil: Born Again".
        return false
    }

    struct NameForms {
        let full: String
        let acronyms: Set<String>
        var isEmpty: Bool { full.isEmpty }
    }

    /// `title`'s name forms, plus those of:
    /// - the title with its non-ASCII letters dropped rather than folded:
    ///   EZTV names "Shōgun" releases "Shgun 2024 S01E10 …";
    /// - a talk show's title without its host ("The Daily Show with Trevor
    ///   Noah" → "The Daily Show"): the tail after " with " is a name of
    ///   two or three capitalized words ("Dancing with the Stars" is kept whole);
    /// - a title of three words or more without a trailing "Live" ("Jimmy
    ///   Kimmel Live" → "Jimmy Kimmel 2026 11 09 …").
    private static func nameFormVariants(_ title: String) -> [NameForms] {
        var titles = [title]
        let ascii = String(String.UnicodeScalarView(title.unicodeScalars.filter(\.isASCII)))
        if ascii != title { titles.append(ascii) }
        let words = title.split(separator: " ")
        if words.count >= 3, let last = words.last,
           last.trimmingCharacters(in: .punctuationCharacters).lowercased() == "live" {
            titles.append(words.dropLast().joined(separator: " "))
        }
        if let with = title.range(of: " with ", options: .caseInsensitive) {
            let host = title[with.upperBound...].split(separator: " ")
            if (2...3).contains(host.count), host.allSatisfy({ $0.first?.isUppercase == true }) {
                titles.append(String(title[..<with.lowerBound]))
            }
        }
        return titles.map(nameForms).filter { !$0.isEmpty }
    }

    private static func nameForms(_ title: String) -> NameForms {
        let words = nameWords(title)
        var acronyms = Set<String>()
        if words.count >= 2 {
            for start in 0..<(words.count - 1) {
                let tail = words[start...].compactMap(\.first).map(String.init).joined()
                acronyms.insert(words[..<start].joined() + tail)
            }
        }
        return NameForms(full: words.joined(), acronyms: acronyms)
    }

    /// Lowercased ASCII-folded words, "&" read as "and", apostrophes removed,
    /// without a leading "the" or trailing years / country codes.
    private static func nameWords(_ raw: String) -> [String] {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        var words = folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        if words.count > 1, words.first == "the" { words.removeFirst() }
        let countries: Set<String> = ["us", "uk", "au", "nz", "ca"]
        while words.count > 1, let last = words.last,
              countries.contains(last) || (last.count == 4 && (last.hasPrefix("19") || last.hasPrefix("20")) && Int(last) != nil) {
            words.removeLast()
        }
        return words
    }

    private static func normalizedGenre(_ raw: String) -> String {
        return raw.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private func fetchTVMaze(imdbId: String, completion: @escaping ([String: Any]?) -> Void) {
        let url = "https://api.tvmaze.com/lookup/shows"
        let params: [String: Any] = ["imdb": imdbId]
        session.request(url, parameters: params).validate().responseData { response in
            switch response.result {
            case .success(let data):
                let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments)
                completion(json as? [String: Any])
            case .failure:
                completion(nil)
            }
        }
    }

    /// TVMaze's alternate titles of a show (`/shows/{id}/akas`) that EZTV
    /// may name its releases after: the international one (no country), the
    /// English-speaking countries' ("The Doll" for "Lalka", "Ye Gou Gu Tou"
    /// for "Love For You"), and any other written in Latin letters
    /// (romanizations: "Sousou no Frieren", "Shingeki no Kyojin"). Nil when
    /// the request fails (unknown, not "none").
    private func fetchTVMazeAkas(tvmazeId: Int, completion: @escaping ([String]?) -> Void) {
        let url = "https://api.tvmaze.com/shows/\(tvmazeId)/akas"
        let english: Set<String> = ["US", "GB", "CA", "AU", "NZ", "IE"]
        session.request(url).validate().responseData { response in
            guard case .success(let data) = response.result,
                  let akas = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                completion(nil)
                return
            }
            completion(akas.compactMap { aka in
                guard let name = aka["name"] as? String, !name.isEmpty else { return nil }
                guard let code = (aka["country"] as? [String: Any])?["code"] as? String else { return name }
                return english.contains(code) || YTSEZTVProvider.isLatinScript(name) ? name : nil
            })
        }
    }

    /// Every letter is Latin once accents are folded ("Sousou no Frieren"
    /// yes, "葬送のフリーレン" no).
    private static func isLatinScript(_ name: String) -> Bool {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let letters = folded.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty && letters.allSatisfy(\.isASCII)
    }

    private func fetchTVMazeEpisodes(tvmazeId: Int, completion: @escaping ([[String: Any]]) -> Void) {
        let url = "https://api.tvmaze.com/shows/\(tvmazeId)/episodes"
        session.request(url).validate().responseData { response in
            switch response.result {
            case .success(let data):
                let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments)
                completion(json as? [[String: Any]] ?? [])
            case .failure:
                completion([])
            }
        }
    }

    /// Page through EZTV's per-show torrent listing. Long-running shows have
    /// hundreds of entries; cap the walk so a pathological catalog (The
    /// Simpsons) can't hold the detail page hostage.
    private func fetchAllEztvTorrents(imdbId: String, completion: @escaping ([[String: Any]]) -> Void) {
        let numeric = imdbId.replacingOccurrences(of: "tt", with: "")
        let pageLimit = 100
        let maxPages = 5

        var collected: [[String: Any]] = []

        func fetch(page: Int) {
            let params: [String: Any] = ["imdb_id": numeric, "limit": pageLimit, "page": page]
            attemptEztv(hosts: orderedEztvHosts, path: "/api/get-torrents", params: params) { data, _ in
                var entries: [[String: Any]] = []
                var total = 0
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data),
                   let root = json as? [String: Any] {
                    entries = (root["torrents"] as? [[String: Any]]) ?? []
                    total = (root["torrents_count"] as? Int) ?? 0
                }
                collected += entries
                let exhausted = entries.isEmpty || collected.count >= total || page >= maxPages
                if exhausted {
                    completion(collected)
                } else {
                    fetch(page: page + 1)
                }
            }
        }
        fetch(page: 1)
    }
}

private extension String {
    func leftPadded(to width: Int, with pad: Character) -> String {
        if count >= width { return self }
        return String(repeating: pad, count: width - count) + self
    }
}

// MARK: - Details & suggestions (OpenMetadata)

extension YTSEZTVProvider {
    /// YTS `movie_details` (with the cast) for an IMDb id: the raw movie
    /// object, on the main queue, or nil (unknown title, every mirror down).
    func ytsMovieDetails(imdbId: String, completion: @escaping ([String: Any]?) -> Void) {
        if let cached = detailsCache.object(forKey: imdbId as NSString) as? [String: Any] {
            return DispatchQueue.main.async { completion(cached) }
        }
        attempt(hosts: orderedHosts, path: Path.movieInfo, params: ["imdb_id": imdbId, "with_cast": "true"]) { [weak self] data, _ in
            let root = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let movie = (root?["data"] as? [String: Any])?["movie"] as? [String: Any]
            let known = (movie?["id"] as? Int ?? 0) > 0
            if known, let movie { self?.detailsCache.setObject(movie as NSDictionary, forKey: imdbId as NSString) }
            DispatchQueue.main.async { completion(known ? movie : nil) }
        }
    }

    /// YTS's "suggested" movies for a title (4, from its own catalog):
    /// movie_details gives YTS's numeric id, movie_suggestions the list.
    /// Calls back on the main queue, with [] on any failure.
    func movieSuggestions(imdbId: String, completion: @escaping ([Movie]) -> Void) {
        ytsMovieDetails(imdbId: imdbId) { [weak self] movie in
            guard let self, let ytsId = movie?["id"] as? Int else { return completion([]) }
            self.attempt(hosts: self.orderedHosts, path: Path.movieSuggestions, params: ["movie_id": ytsId]) { data, _ in
                let root = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                let movies = ((root?["data"] as? [String: Any])?["movies"] as? [[String: Any]] ?? [])
                    .compactMap(Movie.init(yts:))
                    .filter { $0.id != imdbId }
                DispatchQueue.main.async { completion(movies) }
            }
        }
    }
}
