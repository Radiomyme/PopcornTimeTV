

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

    /// Override the YTS host at launch (e.g. `yts.am` if `yts.mx` is DNS-blocked
    /// in the user's region). Set BEFORE the first MovieManager call.
    public static var ytsHost: String = "https://yts.mx"

    private struct YTS {
        static var base:        String { return YTSEZTVProvider.ytsHost + "/api/v2" }
        static let listMovies = "/list_movies.json"
        static let movieInfo  = "/movie_details.json"
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

        let url = YTS.base + YTS.listMovies
        print("[YTS] GET \(url) params=\(params)")

        session.request(url, parameters: params).validate().responseData { response in
            let status = response.response?.statusCode ?? -1
            switch response.result {
            case .success(let data):
                let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
                print("[YTS] list_movies status=\(status) bytes=\(data.count) preview=\(preview)")
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
            case .failure(let err):
                print("[YTS] ERROR request failed: status=\(status) err=\(err)")
                DispatchQueue.main.async { completion(nil, err as NSError) }
            }
        }
    }

    public func getMovieInfo(imdbId: String, completion: @escaping (Movie?, NSError?) -> Void) {
        let params: [String: Any] = [
            "imdb_id":     imdbId,
            "with_images": true,
            "with_cast":   true,
        ]
        let url = YTS.base + YTS.movieInfo
        print("[YTS] GET \(url) imdb=\(imdbId)")

        session.request(url, parameters: params).validate().responseData { response in
            let status = response.response?.statusCode ?? -1
            switch response.result {
            case .success(let data):
                print("[YTS] movie_details status=\(status) bytes=\(data.count)")
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
            case .failure(let err):
                print("[YTS] ERROR movie_details failed status=\(status) err=\(err)")
                DispatchQueue.main.async { completion(nil, err as NSError) }
            }
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
