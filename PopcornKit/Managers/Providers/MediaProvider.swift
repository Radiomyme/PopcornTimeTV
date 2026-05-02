

import Foundation

/// Pluggable backend for catalog data. The legacy `tv-v2.api-fetch.website`
/// host is permanently offline, so app-side managers no longer hardcode it.
/// Plug another provider (self-hosted popcorn-api, mirror, …) by reassigning
/// `MediaProvider.shared` at app launch.
public protocol MediaProvider: AnyObject {
    func loadMovies(page: Int,
                    filter: MovieManager.Filters,
                    genre: NetworkManager.Genres,
                    searchTerm: String?,
                    order: NetworkManager.Orders,
                    completion: @escaping ([Movie]?, NSError?) -> Void)

    func getMovieInfo(imdbId: String,
                      completion: @escaping (Movie?, NSError?) -> Void)

    func loadShows(page: Int,
                   filter: ShowManager.Filters,
                   genre: NetworkManager.Genres,
                   searchTerm: String?,
                   order: NetworkManager.Orders,
                   completion: @escaping ([Show]?, NSError?) -> Void)

    func getShowInfo(imdbId: String,
                     completion: @escaping (Show?, NSError?) -> Void)
}

public enum MediaProviders {
    /// Active provider. Replace before any UI fetch occurs (typically in
    /// AppDelegate.application(_:didFinishLaunchingWithOptions:) before the
    /// first manager call) to switch backends.
    public static var shared: MediaProvider = YTSEZTVProvider()
}
