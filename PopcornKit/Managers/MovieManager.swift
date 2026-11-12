

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
        print("[MovieManager] load page=\(page) filter=\(filter) genre=\(genre) -> provider=\(type(of: MediaProviders.shared))")
        MediaProviders.shared.loadMovies(
            page: page,
            filter: filter,
            genre: genre,
            searchTerm: searchTerm,
            order: order,
            completion: completion)
    }

    open func getInfo(_ imdbId: String, completion: @escaping (Movie?, NSError?) -> Void) {
        MediaProviders.shared.getMovieInfo(imdbId: imdbId, completion: completion)
    }
}
