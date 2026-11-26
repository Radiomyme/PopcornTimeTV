

import Foundation
import ObjectMapper

open class MovieManager: NetworkManager {
    
    /// Creates new instance of MovieManager class
    public static let shared = MovieManager()
    
    /// Possible filters used in API call.
    public enum Filters: String {
        case trending = "trending"
        /// The Pirate Bay's top 100 (`PirateBayTop100`): one page.
        case top100 = "top100"
        case popularity = "seeds"
        case rating = "rating"
        case date = "last added"
        case year = "year"
        
        public static let array = [trending, top100, popularity, rating, date, year]
        
        public var string: String {
            switch self {
            case .top100:
                return "Top 100".localized
            case .popularity:
                return "Popular".localized
            case .year:
                return "New".localized
            case .date:
                return "Recently Added".localized
            case .rating:
                return "Top Rated".localized
            case .trending:
                return "Trending".localized
            }
        }
    }
    
    /**
     Load Movies from API.
     
     - Parameter page:       The page number to load.
     - Parameter filterBy:   Sort the response by Popularity, Year, Date Rating, Alphabet or Trending.
     - Parameter genre:      Only return movies that match the provided genre.
     - Parameter searchTerm: Only return movies that match the provided string.
     - Parameter orderBy:    Ascending or descending.
     
     - Parameter completion: Completion handler for the request. Returns array of movies upon success, error upon failure.
     */
    open func load(
        _ page: Int,
        filterBy filter: Filters,
        genre: Genres,
        searchTerm: String?,
        orderBy order: Orders,
        completion: @escaping ([Movie]?, NSError?) -> Void) {
        load(page, filterBy: filter, genre: genre, searchTerm: searchTerm, orderBy: order, snapshot: nil, completion: completion)
    }

    /**
     Search Movies (page 1 of `load` with `searchTerm`), on the main queue. `incomplete`: a source was left out of the answer (late or down), so an empty list is « nothing found yet », and the same query is worth sending again.
     */
    public func search(_ term: String, completion: @escaping ([Movie]?, NSError?, _ incomplete: Bool) -> Void) {
        let provider = MediaProviders.shared
        provider.loadMovies(page: 1, filter: .popularity, genre: .all, searchTerm: term, order: .descending) { movies, error in
            // Read here, inside the completion, as `load` does.
            let partial = (provider as? YTSEZTVProvider)?.lastListWasPartial ?? false
            if Thread.isMainThread { completion(movies, error, partial) } else { DispatchQueue.main.async { completion(movies, error, partial) } }
        }
    }

    /**
     Load Movies from API, the first page of a list through its snapshot on disk (`CatalogSnapshotStore`): a list loaded recently is answered without a request; an older one is handed to `snapshot` at once (a grid paints it), then `completion` gets the network's list. Without a `snapshot` handler the network's list is waited for, and the older one is the answer only when the network fails. Searches, later pages and the Top 100 (which keeps its own cache) go straight to the provider.

     - Parameter snapshot:   Called at most once, before `completion`, on the main queue, with the list saved by an earlier load.
     - Parameter completion: Called once, on the main queue.
     */
    public func load(
        _ page: Int,
        filterBy filter: Filters,
        genre: Genres,
        searchTerm: String?,
        orderBy order: Orders,
        snapshot: (([Movie]) -> Void)?,
        completion: @escaping ([Movie]?, NSError?) -> Void) {
        print("[MovieManager] load page=\(page) filter=\(filter) genre=\(genre) -> provider=\(type(of: MediaProviders.shared))")
        let network: (@escaping ([Movie]?, NSError?, _ partial: Bool) -> Void) -> Void = { done in
            let provider = MediaProviders.shared
            provider.loadMovies(page: page, filter: filter, genre: genre, searchTerm: searchTerm, order: order) { movies, error in
                // Read here, inside the completion: a list a source was left
                // out of is not kept as the snapshot.
                let partial = (provider as? YTSEZTVProvider)?.lastListWasPartial ?? false
                // The snapshot rules run on the main queue, whatever the provider.
                if Thread.isMainThread { done(movies, error, partial) } else { DispatchQueue.main.async { done(movies, error, partial) } }
            }
        }
        let searching = !(searchTerm ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        guard page <= 1, !searching, filter != .top100 else { return network { items, error, _ in completion(items, error) } }
        CatalogSnapshotLoader.load(
            key: CatalogSnapshotStore.key(kind: "movies", filter: filter.rawValue, genre: genre.rawValue, order: order),
            freshness: .movies(filter),
            store: .shared,
            encode: { Mapper<Movie>().toJSONArray($0) },
            decode: { Mapper<Movie>().mapArray(JSONArray: $0) },
            load: network,
            snapshot: snapshot,
            completion: completion)
    }

    open func getInfo(_ imdbId: String, completion: @escaping (Movie?, NSError?) -> Void) {
        MediaProviders.shared.getMovieInfo(imdbId: imdbId, completion: completion)
    }
}
