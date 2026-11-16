import Foundation
import Alamofire

public struct Trakt {
    static let apiKey = "d3b0811a35719a67187cba2476335b2144d31e5840d02f687fbf84e7eaadc811"
    static let apiSecret = "f047aa37b81c87a990e210559a797fd4af3b94c16fb6d22b62aa501ca48ea0a4"
    static let base = "https://api.trakt.tv"
    static let shows = "/shows"
    static let movies = "/movies"
    static let people = "/people"
    static let person = "/person"
    static let seasons = "/seasons"
    static let episodes = "/episodes"
    static let auth = "/oauth"
    static let token = "/token"
    static let sync = "/sync"
    static let playback = "/playback"
    static let history = "/history"
    static let device = "/device"
    static let code = "/code"
    static let remove = "/remove"
    static let related = "/related"
    static let watched = "/watched"
    static let watchlist = "/watchlist"
    static let scrobble = "/scrobble"
    static let imdb = "/imdb"
    static let tvdb = "/tvdb"
    static let search = "/search"
    
    static let extended = ["extended": "full"]
    public struct Headers {
        static let Default = [
            "Content-Type": "application/json",
            "trakt-api-version": "2",
            "trakt-api-key": Trakt.apiKey
        ]
        
        static func Authorization(_ token: String) -> [String: String] {
            var Authorization = Default; Authorization["Authorization"] = "Bearer \(token)"
            return Authorization
        }
    }
    public enum MediaType: String {
        case movies = "movies"
        case shows = "shows"
        case episodes = "episodes"
        case people = "people"
    }
    /**
     Watched status of media.
     
     - .watching:   When the video intially starts playing or is unpaused.
     - .paused:     When the video is paused.
     - .finished:   When the video is stopped or finishes playing on its own.
     */
    public enum WatchedStatus: String {
        /// When the video intially starts playing or is unpaused.
        case watching = "start"
        /// When the video is paused.
        case paused = "pause"
        /// When the video is stopped or finishes playing on its own.
        case finished = "stop"
    }
}

public struct Popcorn {
    static let base = "https://tv-v2.api-fetch.website"
    static let shows = "/shows"
    static let movies = "/movies"

    static let movie = "/movie"
    static let show = "/show"
}

public struct TMDB {
    static let apiKey = "fa664b70ac6e307a1f859198f1148ce9"
    static let base = "https://api.themoviedb.org/3"
    static let tv = "/tv"
    static let person = "/person"
    static let images = "/images"
    static let season = "/season"
    static let episode = "/episode"
    
    public enum MediaType: String {
        case movies = "movie"
        case shows = "tv"
    }
    
    static let defaultHeaders = ["api_key": TMDB.apiKey]
}

public struct Fanart {
    static let apiKey = "bd2753f04538b01479e39e695308b921"
    static let base = "http://webservice.fanart.tv/v3"
    static let tv = "/tv"
    static let movies = "/movies"
    
    static let defaultParameters = ["api_key": Fanart.apiKey]
}

public struct OpenSubtitles {
    static let base = "https://api.opensubtitles.org:443/xml-rpc"
    static let userAgent = "Popcorn Time v1"
    
    static let logIn = "LogIn"
    static let logOut = "LogOut"
    static let search = "SearchSubtitles"
    
    static let defaultHeaders = ["User-Agent": OpenSubtitles.userAgent]
}

open class NetworkManager: NSObject {
    internal let manager: Session = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.urlCache = nil
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return Session(configuration: configuration)
    }()
    
    /// Possible orders used in API call.
    public enum Orders: Int {
        case ascending = 1
        case descending = -1
        
    }
    
    /// Possible genres used in API call.
    ///
    /// The raw values are the app's names (and localisation keys); what a
    /// source is asked is `ytsValue` (movies) / `cinemetaValue` (shows). The
    /// cases no source has (Disaster, Fan Film, Holiday, Indie, Road, Short,
    /// Sporting Event, Suspense: inherited from the retired popcorn API) are
    /// kept so stored values still decode, but are no longer offered: YTS
    /// ignores a genre it does not know and answers its whole catalog.
    public enum Genres: String {
        case all = "All"
        case action = "Action"
        case adventure = "Adventure"
        case animation = "Animation"
        case comedy = "Comedy"
        case crime = "Crime"
        case disaster = "Disaster"
        case documentary = "Documentary"
        case drama = "Drama"
        case family = "Family"
        case fanFilm = "Fan Film"
        case fantasy = "Fantasy"
        case filmNoir = "Film Noir"
        case history = "History"
        case holiday = "Holiday"
        case horror = "Horror"
        case indie = "Indie"
        case music = "Music"
        case mystery = "Mystery"
        case road = "Road"
        case romance = "Romance"
        case sciFi = "Science Fiction"
        case short = "Short"
        case sports = "Sports"
        case sportingEvent = "Sporting Event"
        case suspense = "Suspense"
        case thriller = "Thriller"
        case war = "War"
        case western = "Western"

        /// The genres a grid can offer: those at least one catalog knows
        /// (`movies`; `shows` is a subset). A grid of one kind should list
        /// `movies` or `shows`.
        public static var array = movies

        /// The genres of the Movies grid: YTS's vocabulary.
        public static let movies: [Genres] = [all, action, adventure, animation, comedy, crime, documentary, drama, family, fantasy, filmNoir, history, horror, music, mystery, romance, sciFi, sports, thriller, war, western]

        /// The genres of the Shows grid: Cinemeta's vocabulary.
        public static let shows: [Genres] = movies.filter { $0 == .all || $0.cinemetaValue != nil }

        /// What YTS calls the genre (`genre=` of `list_movies`, measured
        /// 2026-11-14: "Science Fiction" is ignored, "sci-fi" is 5,862 films),
        /// nil for `all` and for the genres YTS does not have.
        public var ytsValue: String? {
            switch self {
            case .action, .adventure, .animation, .comedy, .crime, .documentary, .drama, .family, .fantasy,
                 .history, .horror, .music, .mystery, .romance, .thriller, .war, .western:
                return rawValue.lowercased()
            case .sciFi: return "sci-fi"
            case .sports: return "sport"
            case .filmNoir: return "film-noir"
            case .all, .disaster, .fanFilm, .holiday, .indie, .road, .short, .sportingEvent, .suspense:
                return nil
            }
        }

        /// What Cinemeta calls the genre (the `genre=` extra of its series
        /// catalogs), nil for `all` and for the genres it does not have.
        public var cinemetaValue: String? {
            switch self {
            case .action, .adventure, .animation, .comedy, .crime, .documentary, .drama, .family, .fantasy,
                 .history, .horror, .mystery, .romance, .thriller, .war, .western:
                return rawValue
            case .sciFi: return "Sci-Fi"
            case .sports: return "Sport"
            case .all, .disaster, .fanFilm, .filmNoir, .holiday, .indie, .music, .road, .short, .sportingEvent, .suspense:
                return nil
            }
        }

        public var string: String {
            return rawValue.localized
        }
    }
}
