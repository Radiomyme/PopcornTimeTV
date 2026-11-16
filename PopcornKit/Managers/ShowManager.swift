

import Foundation
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
        /// The Pirate Bay's top 100 (`PirateBayTop100`): one page.
        case top100 = "top100"
        case name = "name"

        public static let array = [trending, top100, popularity, rating, date, year, name]

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
        load(page, filterBy: filter, genre: genre, searchTerm: searchTerm, orderBy: order, snapshot: nil, completion: completion)
    }

    /**
     Load TV Shows from API, the first page of a list through its snapshot on disk: see `MovieManager.load(_:filterBy:genre:searchTerm:orderBy:snapshot:completion:)`.

     - Parameter snapshot:   Called at most once, before `completion`, on the main queue, with the list saved by an earlier load.
     - Parameter completion: Called once, on the main queue.
     */
    public func load(
        _ page: Int,
        filterBy filter: Filters,
        genre: Genres,
        searchTerm: String?,
        orderBy order: Orders,
        snapshot: (([Show]) -> Void)?,
        completion: @escaping ([Show]?, NSError?) -> Void) {
        let network: (@escaping ([Show]?, NSError?, _ partial: Bool) -> Void) -> Void = { done in
            let provider = MediaProviders.shared
            provider.loadShows(page: page, filter: filter, genre: genre, searchTerm: searchTerm, order: order) { shows, error in
                // Read here, inside the completion: a list a source was left
                // out of is not kept as the snapshot.
                let partial = (provider as? YTSEZTVProvider)?.lastListWasPartial ?? false
                // The snapshot rules run on the main queue, whatever the provider.
                if Thread.isMainThread { done(shows, error, partial) } else { DispatchQueue.main.async { done(shows, error, partial) } }
            }
        }
        let searching = !(searchTerm ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        guard page <= 1, !searching, filter != .top100 else { return network { items, error, _ in completion(items, error) } }
        CatalogSnapshotLoader.load(
            key: CatalogSnapshotStore.key(kind: "shows", filter: filter.rawValue, genre: genre.rawValue, order: order),
            freshness: .shows(filter),
            store: .shared,
            // A grid entry: without the episodes (the Recently Added list
            // carries the page's torrents; the show's page loads its own).
            encode: { shows in Mapper<Show>().toJSONArray(shows) },
            decode: { Mapper<Show>().mapArray(JSONArray: $0) },
            load: network,
            snapshot: snapshot,
            completion: completion)
    }

    open func getInfo(_ imdbId: String, completion: @escaping (Show?, NSError?) -> Void) {
        MediaProviders.shared.getShowInfo(imdbId: imdbId, completion: completion)
    }
}
