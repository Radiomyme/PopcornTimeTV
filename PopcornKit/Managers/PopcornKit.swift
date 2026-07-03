

import Alamofire

/// Thread-safe one-shot box for sharing a download destination URL between
/// Alamofire's `to:` destination closure (Sendable) and the matching
/// `.response` callback. A bare `var url: URL?` captured by both closures
/// trips Swift 6's "mutation of captured var in concurrently-executing
/// code" diagnostic; wrapping it in a final class with a single property
/// satisfies the checker because the closures capture a *reference* whose
/// underlying storage is reachable from either thread without crossing a
/// Sendable boundary.
private final class PathBox: @unchecked Sendable {
    var url: URL?
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
public func loadShows(
    _ page: Int = 1,
    filterBy filter: ShowManager.Filters = .popularity,
    genre: ShowManager.Genres = .all,
    searchTerm: String? = nil,
    orderBy order: ShowManager.Orders = .descending,
    completion: @escaping ([Show]?, NSError?) -> Void) {
    ShowManager.shared.load(
        page,
        filterBy: filter,
        genre: genre,
        searchTerm: searchTerm,
        orderBy: order,
        completion: completion)
}

/**
 Get more show information.
 
 - Parameter imdbId:        The imdb identification code of the show.
 
 - Parameter completion:    Completion handler for the request. Returns show upon success, error upon failure.
 */
public func getShowInfo(_ imdbId: String, completion: @escaping (Show?, NSError?) -> Void) {
    ShowManager.shared.getInfo(imdbId, completion: completion)
}

/**
 Get more episode information.
 
 - Parameter tvdbId:        The tvdb identification code of the episode.
 
 - Parameter completion:    Completion handler for the request. Returns episode upon success, error upon failure.
 */
public func getEpisodeInfo(_ tvdbId: Int, completion: @escaping (Episode?, NSError?) -> Void) {
    TraktManager.shared.getEpisodeInfo(forTvdb: tvdbId, completion: completion)
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
public func loadMovies(
    _ page: Int = 1,
    filterBy filter: MovieManager.Filters = .popularity,
    genre: MovieManager.Genres = .all,
    searchTerm: String? = nil,
    orderBy order: MovieManager.Orders = .descending,
    completion: @escaping ([Movie]?, NSError?) -> Void) {
    MovieManager.shared.load(
        page,
        filterBy: filter,
        genre: genre,
        searchTerm: searchTerm,
        orderBy: order,
        completion: completion)
}

/**
 Get more movie information.
 
 - Parameter imdbId:        The imdb identification code of the movie.
 
 - Parameter completion:    Completion handler for the request. Returns movie upon success, error upon failure.
 */
public func getMovieInfo(_ imdbId: String, completion: @escaping (Movie?, NSError?) -> Void) {
    MovieManager.shared.getInfo(imdbId, completion: completion)
}

/**
 Download torrent file from link.
 
 - Parameter path:          The path to the torrent file you would like to download.
 
 - Parameter completion:    Completion handler for the request. Returns downloaded torrent url upon success, error upon failure.
 */
public func downloadTorrentFile(_ path: String, completion: @escaping (String?, NSError?) -> Void) {
    // Swift 6 forbids capturing a `var` across `@Sendable` closure
    // boundaries. Stash the resolved path in a thread-safe box so the
    // destination + response closures can both read/write it without the
    // compiler complaining about cross-actor mutation.
    let pathBox = PathBox()
    AF.download(path, to: { (temporaryURL, response) -> (destinationURL: URL, options: DownloadRequest.Options) in
        let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(response.suggestedFilename!)
        pathBox.url = dest
        return (dest, .removePreviousFile)
    }).validate().response { response in
        guard response.error == nil else { completion(nil, response.error as NSError?); return }
        completion(pathBox.url?.path, nil)
    }
}

/**
 Download subtitle file from link.
 
 - Parameter path:              The path to the subtitle file you would like to download.
 - Parameter fileName:          An optional file name you can provide.
 - Parameter downloadDirectory: You can opt to change the download location of the file. Defaults to `NSTemporaryDirectory/Subtitles`.
 
 - Parameter completion:    Completion handler for the request. Returns downloaded subtitle url upon success, error upon failure.
 */
public func downloadSubtitleFile(
    _ path: String,
    fileName suggestedName: String? = nil,
    downloadDirectory directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
    completion: @escaping (URL?, NSError?) -> Void) {
    let pathBox = PathBox()
    AF.download(path, to: { (temporaryURL, response) -> (destinationURL: URL, options: DownloadRequest.Options) in
        let fileName = suggestedName ?? response.suggestedFilename!
        let downloadDirectory = directory.appendingPathComponent("Subtitles")
        if !FileManager.default.fileExists(atPath: downloadDirectory.path) {
            try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true, attributes: nil)
        }
        let url = downloadDirectory.appendingPathComponent(fileName)
        pathBox.url = url
        return (url, .removePreviousFile)
    }).validate().response { response in
        if let error = response.error as NSError? {
            completion(nil, error)
            return
        }
        completion(pathBox.url, nil)
    }
}


