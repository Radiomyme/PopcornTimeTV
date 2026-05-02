

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

    /// Hosts the provider tries in order. A French ISP (Orange/SFR/Bouygues)
    /// will typically DNS-block at least the first one; subsequent entries
    /// often resolve fine through the same FAI. Sticky-cache the first host
    /// that successfully serves a JSON response in `lastGoodHost`, then
    /// only fall back when it later fails.
    public static var ytsMirrors: [String] = [
        "https://yts.mx",
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

    // MARK: - Shows (stub — see Phase 7 for full EZTV+TMDB integration)

    public func loadShows(page: Int,
                          filter: ShowManager.Filters,
                          genre: NetworkManager.Genres,
                          searchTerm: String?,
                          order: NetworkManager.Orders,
                          completion: @escaping ([Show]?, NSError?) -> Void) {
        DispatchQueue.main.async { completion([], nil) }
    }

    public func getShowInfo(imdbId: String, completion: @escaping (Show?, NSError?) -> Void) {
        DispatchQueue.main.async { completion(nil, nil) }
    }
}
