

import ObjectMapper

open class ShowManager: NetworkManager {
    
    /// Creates new instance of ShowManager class
    public static let shared = ShowManager()
    
    /// Possible filters used in API call.
    public enum Filters: String {
        case popularity = "popularity"
        case year = "year"
        case date = "updated"
        case rating = "rating"
        case trending = "trending"
        case name = "name"

        public static let array = [trending, popularity, rating, date, year, name]

        public var string: String {
            switch self {
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
            case .name:
                return "A - Z".localized
            }
        }
    }
    
    /**
     Load TV Shows from API.
     
     - Parameter page:       The page number to load.
     - Parameter filterBy:   Sort the response by Popularity, Year, Date Rating, Alphabet or Trending.
     - Parameter genre:      Only return shows that match the provided genre.
     - Parameter searchTerm: Only return shows that match the provided string.
     - Parameter orderBy:    Ascending or descending.
     
     - Parameter completion: Completion handler for the request. Returns array of shows upon success, error upon failure.
     */
    open func load(
        _ page: Int,
        filterBy filter: Filters,
        genre: Genres,
        searchTerm: String?,
        orderBy order: Orders,
        completion: @escaping ([Show]?, NSError?) -> Void) {
        MediaProviders.shared.loadShows(
            page: page,
            filter: filter,
            genre: genre,
            searchTerm: searchTerm,
            order: order,
            completion: completion)
    }

    open func getInfo(_ imdbId: String, completion: @escaping (Show?, NSError?) -> Void) {
        MediaProviders.shared.getShowInfo(imdbId: imdbId, completion: completion)
    }
}
