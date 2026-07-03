

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
    }

    public init() {}

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

        // Query YTS (curated qualities, rich metadata), the Torrentio
        // aggregator (a dozen extra indexers — REMUX, HDR, multi-audio) and
        // the Time4Popcorn backend (extra scraped releases) in parallel,
        // then merge every torrent list by info-hash.
        let group = DispatchGroup()
        var ytsMovie: Movie?
        var ytsError: NSError?
        var aggregated: [Torrent] = []
        var t4p: [Torrent] = []

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
        }

        group.enter()
        TorrentioClient.shared.streams(imdbId: imdbId) { torrents in
            aggregated = torrents
            group.leave()
        }

        group.enter()
        Time4PopcornClient.shared.movieTorrents(imdbId: imdbId) { torrents in
            t4p = torrents
            group.leave()
        }

        group.notify(queue: .main) {
            guard var movie = ytsMovie else {
                completion(nil, ytsError)
                return
            }
            let before = movie.torrents.count
            movie.torrents = TorrentioClient.merge(movie.torrents, with: aggregated + t4p)
            print("[YTS+Torrentio+T4P] \(imdbId): \(before) YTS + \(aggregated.count) aggregated + \(t4p.count) t4p -> \(movie.torrents.count) torrents")
            completion(movie, nil)
        }
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

        if let term = searchTerm, !term.isEmpty {
            // TVMaze search isn't paginated — return everything on page 1
            // and an empty page 2 so the infinite-scroll loop terminates.
            guard page <= 1 else {
                DispatchQueue.main.async { completion([], nil) }
                return
            }
            return searchShows(term, completion: completion)
        }

        let params: [String: Any] = ["limit": 100, "page": max(page, 1)]
        attemptEztv(hosts: orderedEztvHosts, path: "/api/get-torrents", params: params) { [weak self] data, error in
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
            self.buildShows(from: raw, filter: filter, genre: genre, completion: completion)
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
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }

            let group = DispatchGroup()
            var guide: [[String: Any]] = []
            var torrentEntries: [[String: Any]] = []

            if let tvmazeId = tvmaze["id"] as? Int {
                group.enter()
                self.fetchTVMazeEpisodes(tvmazeId: tvmazeId) { episodes in
                    guide = episodes
                    group.leave()
                }
            }

            group.enter()
            self.fetchAllEztvTorrents(imdbId: imdbId) { entries in
                torrentEntries = entries
                group.leave()
            }

            group.notify(queue: .main) {
                show.episodes = self.mergedEpisodes(guide: guide, eztvEntries: torrentEntries, show: show)
                self.cacheQueue.sync { self.showCache[imdbId] = show }
                print("[EZTV] getShowInfo \(imdbId): guide=\(guide.count) torrents=\(torrentEntries.count) episodes=\(show.episodes.count)")
                completion(show, nil)
            }
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
                if let tvmaze = tvmaze, var show = Show(tvmaze: tvmaze, imdbId: imdbId, episodes: []) {
                    show.episodes = self.mergedEpisodes(guide: [], eztvEntries: entries, show: show)
                    lock.lock(); shows.append(show); lock.unlock()
                }
                group.leave()
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
            case .popularity:
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
                                show: Show) -> [Episode] {
        struct Key: Hashable { let season: Int; let episode: Int }

        var torrentsByKey: [Key: [Torrent]] = [:]
        var titleByKey: [Key: String] = [:]
        var dateByKey: [Key: Date] = [:]
        for entry in eztvEntries {
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
            let summary = ((dict["summary"] as? String) ?? "No summary available.".localized).removingHtmlEncoding
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
        // guide gaps) still deserve a row.
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
