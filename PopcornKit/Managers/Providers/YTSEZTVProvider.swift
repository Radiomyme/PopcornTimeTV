

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
        return Session(configuration: configuration)
    }()

    private struct YTS {
        static let base       = "https://yts.mx/api/v2"
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
            "page":        max(page, 1),
            "limit":       50,
            "sort_by":     sortBy,
            "order_by":    order == .descending ? "desc" : "asc",
            "with_rt_ratings": false,
        ]
        if genre != .all {
            params["genre"] = genre.rawValue
        }
        if let term = searchTerm, !term.isEmpty {
            params["query_term"] = term
        }

        session.request(YTS.base + YTS.listMovies, parameters: params).validate().responseData { response in
            switch response.result {
            case .success(let data):
                guard
                    let json    = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                    let root    = json as? [String: Any],
                    let payload = root["data"] as? [String: Any],
                    let raw     = payload["movies"] as? [[String: Any]]
                else {
                    DispatchQueue.main.async { completion([], nil) }
                    return
                }
                let movies = raw.compactMap(Movie.init(yts:))
                DispatchQueue.main.async { completion(movies, nil) }
            case .failure(let err):
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
        session.request(YTS.base + YTS.movieInfo, parameters: params).validate().responseData { response in
            switch response.result {
            case .success(let data):
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
