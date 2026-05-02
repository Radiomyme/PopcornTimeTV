

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
              let idx    = YTSEZTVProvider.ytsMirrors.firstIndex(of: sticky)
        else { return YTSEZTVProvider.ytsMirrors }
        var rotated = YTSEZTVProvider.ytsMirrors
        rotated.removeAll { $0 == sticky }
        rotated.insert(sticky, at: 0)
        return rotated
    }

    private struct Path {
        static let listMovies = "/api/v2/list_movies.json"
        static let movieInfo  = "/api/v2/movie_details.json"
    }

    public init() {}

    /// Last batch of shows assembled by `loadShows`, keyed by imdb id, so
    /// `getShowInfo` can return the same instance with its episode list.
    private var showCache: [String: Show] = [:]
    private let cacheQueue = DispatchQueue(label: "com.popcorntimetv.popcornkit.eztv.cache")

    /// EZTV mirror chain. Like YTS, FAIs blacklist `eztvx.to` directly so we
    /// walk through alternates that resolve through Cloudflare-fronted IPs.
    public static var eztvMirrors: [String] = [
        "https://eztvx.to",
        "https://eztv.wf",
        "https://eztv.tf",
        "https://eztv.yt",
        "https://eztv1.xyz",
        "https://eztv.re",
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

        let sortBy: String = {
            switch filter {
            case .trending:   return "download_count"
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

        attempt(hosts: orderedHosts, path: Path.listMovies, params: params) { [weak self] data, error in
            guard let self = self else { return }
            guard let data = data else {
                DispatchQueue.main.async { completion(nil, error) }
                return
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                let root = json as? [String: Any]
            else {
                print("[YTS] ERROR: JSON not parseable")
                DispatchQueue.main.async { completion([], nil) }
                return
            }
            if let apiStatus = root["status"] as? String, apiStatus != "ok" {
                let msg = (root["status_message"] as? String) ?? "YTS error"
                print("[YTS] ERROR: api status=\(apiStatus) message=\(msg)")
                DispatchQueue.main.async {
                    completion([], NSError(domain: "yts", code: -1,
                                           userInfo: [NSLocalizedDescriptionKey: msg]))
                }
                return
            }
            guard
                let payload = root["data"] as? [String: Any],
                let raw     = payload["movies"] as? [[String: Any]]
            else {
                let count = (root["data"] as? [String: Any])?["movie_count"] ?? "nil"
                print("[YTS] payload missing data.movies (movie_count=\(count))")
                DispatchQueue.main.async { completion([], nil) }
                return
            }
            let movies = raw.compactMap(Movie.init(yts:))
            print("[YTS] parsed \(movies.count)/\(raw.count) movies")
            DispatchQueue.main.async { completion(movies, nil) }
            _ = self  // silence warning
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
        let params: [String: Any] = [
            "imdb_id":     imdbId,
            "with_images": true,
            "with_cast":   true,
        ]
        attempt(hosts: orderedHosts, path: Path.movieInfo, params: params) { data, error in
            guard let data = data else {
                DispatchQueue.main.async { completion(nil, error) }
                return
            }
            guard
                let json    = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                let root    = json as? [String: Any],
                let payload = root["data"] as? [String: Any],
                let movie   = payload["movie"] as? [String: Any]
            else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }
            DispatchQueue.main.async { completion(Movie(yts: movie), nil) }
        }
    }

    // MARK: - Shows (EZTV + TVMaze)

    /// Fetch a page of episode torrents from EZTV, group by imdb_id, then
    /// resolve show metadata in parallel via TVMaze (free, unauthenticated).
    /// EZTV doesn't expose sort/genre filtering; we ignore those args and
    /// always return the most recently released episodes' shows.
    public func loadShows(page: Int,
                          filter: ShowManager.Filters,
                          genre: NetworkManager.Genres,
                          searchTerm: String?,
                          order: NetworkManager.Orders,
                          completion: @escaping ([Show]?, NSError?) -> Void) {

        let params: [String: Any] = ["limit": 100, "page": max(page, 1)]
        attemptEztv(hosts: orderedEztvHosts, params: params) { [weak self] data, error in
            guard let self = self else { return }
            guard let data = data else {
                DispatchQueue.main.async { completion(nil, error) }
                return
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                let root = json as? [String: Any],
                let raw  = root["torrents"] as? [[String: Any]]
            else {
                print("[EZTV] JSON parse failed")
                DispatchQueue.main.async { completion([], nil) }
                return
            }
            print("[EZTV] got \(raw.count) torrents")
            self.buildShows(from: raw, completion: completion)
        }
    }

    private func attemptEztv(hosts: [String],
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
            let url = host + "/api/get-torrents"
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

    public func getShowInfo(imdbId: String, completion: @escaping (Show?, NSError?) -> Void) {
        // First-class source: the show that loadShows already assembled with
        // its episode list (cached when the catalog rendered). If absent
        // (deep-linked from a watchlist with no fresh catalog fetch), fall
        // back to a TVMaze-only metadata refresh — episodes will be empty
        // but the detail screen renders a "no episodes" path correctly.
        let cached = cacheQueue.sync { showCache[imdbId] }
        if let cached = cached {
            DispatchQueue.main.async { completion(cached, nil) }
            return
        }
        fetchTVMaze(imdbId: imdbId) { tvmaze in
            guard let tvmaze = tvmaze, let show = Show(tvmaze: tvmaze, imdbId: imdbId, episodes: []) else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }
            DispatchQueue.main.async { completion(show, nil) }
        }
    }

    private func buildShows(from raw: [[String: Any]],
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
                let episodes = entries.compactMap { Episode(eztv: $0) }
                if let tvmaze = tvmaze, var show = Show(tvmaze: tvmaze, imdbId: imdbId, episodes: episodes) {
                    // Wire each episode back to its show so the player flow
                    // (which reads episode.show) has the metadata.
                    show.episodes = episodes.map { var e = $0; e.show = show; return e }
                    lock.lock(); shows.append(show); lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            // Sort by most recent episode air date (descending) so newer
            // shows surface first — matches the "Latest" feel of the films
            // tab.
            shows.sort { lhs, rhs in
                let l = lhs.episodes.map(\.firstAirDate).max() ?? .distantPast
                let r = rhs.episodes.map(\.firstAirDate).max() ?? .distantPast
                return l > r
            }
            // Cache for later getShowInfo lookups by detail screens.
            self.cacheQueue.sync {
                for s in shows { self.showCache[s.id] = s }
            }
            print("[EZTV] built \(shows.count) shows from \(grouped.count) imdb groups")
            completion(shows, nil)
        }
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
}

private extension String {
    func leftPadded(to width: Int, with pad: Character) -> String {
        if count >= width { return self }
        return String(repeating: pad, count: width - count) + self
    }
}
