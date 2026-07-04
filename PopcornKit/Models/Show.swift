

import Foundation
import ObjectMapper
import MediaPlayer.MPMediaItem

/**
 Struct for managing show objects. 
 
 **Important:** In the description of all the optional variables where it says another method must be called on **only** `ShowManager` to populate `x`, does not apply if the show was loaded from Trakt. **However** episodes array will be empty for both Trakt and popcorn-api show objects.
 
 `TraktManager` has to be called regardless to fill up the special variables.
 */
public struct Show: Media, Equatable {
    
    /// Imdb id of show.
    public var id: String

    /// TMDB id of the show. This will be `nil` unless explicitly set by calling `getTMDBId:forImdbId:completion:` on `TraktManager` or the show was loaded from Trakt.
    public var tmdbId: Int?
    
    /// Tvdb for show.
    public var tvdbId: String
    
    /// Slug of the show.
    public let slug: String
    
    /// Title of the show.
    public let title: String
    
    /// Release date of the show.
    public let year: String
    
    /// Rating percentage of the show.
    public let rating: Float
    
    /// Summary of the show. Will default to "No summary available.".localized until `getInfo:imdbId:completion` is called on `ShowManager` and shows are updated. **However**, there may not be a summary provided by the api.
    public let summary: String
    
    /// Network that the show is officially released on. Will be `nil` until `getInfo:imdbId:completion` is called on `ShowManager` and shows are updated.
    public var network: String?
    
    /// Air day of the show. Will be `nil` until `getInfo:imdbId:completion` is called on `ShowManager` and shows are updated.
    public var airDay: String?
    
    /// Air time of the show. Will be `nil` until `getInfo:imdbId:completion` is called on `ShowManager` and shows are updated.
    public var airTime: String?
    
    /// Average runtime of each episode of the show rounded to the nearest minute. Will be `nil` until `getInfo:imdbId:completion` is called on `ShowManager` and shows are updated.
    public var runtime: Int?
    
    /// Status of the show. ie. Returning series, Ended etc. Will be `nil` until `getInfo:imdbId:completion` is called on `ShowManager` and shows are updated.
    public var status: String?
    
    /// The season numbers of the available seasons. The popcorn-api may only retrieve some seasons in arbitrary order. This variable contains the sorted season numbers. For example, popcorn-api only fetches series 21-28 of The Simpsons. This array will contain the numbers 21, 22, 23 ... 28 sorted by lowest first.
    public var seasonNumbers: [Int] {
        return Array(Set(episodes.map({$0.season}))).sorted()
    }
    
    /// If fanart image is available, it is returned with size 650*366.
    public var smallBackgroundImage: String? {
        let amazonUrl = largeBackgroundImage?.isAmazonUrl ?? false
        return largeBackgroundImage?.replacingOccurrences(of: amazonUrl ? "SX1920" : "w1920", with: amazonUrl ? "SX650" : "w650")
    }
    
    /// If fanart image is available, it is returned with size 1280*720.
    public var mediumBackgroundImage: String? {
        let amazonUrl = largeBackgroundImage?.isAmazonUrl ?? false
        return largeBackgroundImage?.replacingOccurrences(of: amazonUrl ? "SX1920" : "w1920", with: amazonUrl ? "SX1280" : "w1280")
    }
    
    /// If fanart image is available, it is returned with size 1920*1080.
    public var largeBackgroundImage: String?
    
    /// If poster image is available, it is returned with size 450*300.
    public var smallCoverImage: String? {
        let amazonUrl = largeCoverImage?.isAmazonUrl ?? false
        return largeCoverImage?.replacingOccurrences(of: amazonUrl ? "SX1000" : "w1000", with: amazonUrl ? "SX300" : "w300")
    }
    
    /// If poster image is available, it is returned with size 975*650.
    public var mediumCoverImage: String? {
        let amazonUrl = largeCoverImage?.isAmazonUrl ?? false
        return largeCoverImage?.replacingOccurrences(of: amazonUrl ? "SX1000" : "w1000", with: amazonUrl ? "SX650" : "w650")
    }
    
    /// If poster image is available, it is returned with size 1500*1000
    public var largeCoverImage: String?
    
    
    /// Convenience variable. Boolean value indicating whether or not the show has been added the users watchlist.
    public var isAddedToWatchlist: Bool {
        get {
            return WatchlistManager<Show>.show.isAdded(self)
        } set (add) {
            add ? WatchlistManager<Show>.show.add(self) : WatchlistManager<Show>.show.remove(self)
        }
    }
    
    
    /// All the people that worked on the show. Empty by default. Must be filled by calling `getPeople:forMediaOfType:id:completion` on `TraktManager`.
    public var crew = [Crew]()
    
    /// All the actors in the show. Empty by default. Must be filled by calling `getPeople:forMediaOfType:id:completion` on `TraktManager`.
    public var actors = [Actor]()
    
    /// The related shows. Empty by default. Must be filled by calling `getRelated:media:completion` on `TraktManager`.
    public var related = [Show]()
    
    /// All the episodes in the show sorted by season number. Empty by default. Must be filled by calling `getInfo:imdbId:completion` on `ShowManager`.
    public var episodes = [Episode]()
    
    /// The genres associated with the show. Empty by default. Must be filled by calling `getInfo:imdbId:completion` on `ShowManager`.
    public var genres = [String]()
    
    public init?(map: Map) {
        do { self = try Show(map) }
        catch { return nil }
    }
    
    private init(_ map: Map) throws {
        if map.context is TraktContext {
            self.id = try map.value("ids.imdb")
            self.tvdbId = try map.value("ids.tvdb", using: StringTransform())
            self.slug = try map.value("ids.slug")
            self.year = try map.value("year", using: StringTransform())
            self.airDay = try? map.value("airs.day")
            self.airTime = try? map.value("airs.time")
            self.rating = try map.value("rating")
        } else {
            self.id = try (try? map.value("imdb_id")) ?? map.value("_id")
            self.tvdbId = try map.value("tvdb_id")
            self.year = try map.value("year")
            self.rating = try map.value("rating.percentage")
            self.largeCoverImage = try? map.value("images.poster"); largeCoverImage = largeCoverImage?.replacingOccurrences(of: "w500", with: "w1000").replacingOccurrences(of: "SX300", with: "SX1000")
            self.largeBackgroundImage = try? map.value("images.fanart"); largeBackgroundImage = largeBackgroundImage?.replacingOccurrences(of: "w500", with: "w1920").replacingOccurrences(of: "SX300", with: "SX1920")
            self.slug = try map.value("slug")
            self.airDay = try? map.value("air_day")
            self.airTime = try? map.value("air_time")
        }
        self.summary = ((try? map.value("synopsis")) ?? "No summary available.".localized).removingHtmlEncoding
        var title: String = try map.value("title")
        title.removeHtmlEncoding()
        self.title = title
        self.status = try? map.value("status")
        self.runtime = try? map.value("runtime", using: IntTransform())
        self.genres = (try? map.value("genres")) ?? []
        self.episodes = (try? map.value("episodes")) ?? []
        self.tmdbId = try? map.value("ids.tmdb")
        self.network = try? map.value("network")
        
        var episodes = [Episode]()
        for var episode in self.episodes {
            episode.show = self
            episodes.append(episode)
        }
        self.episodes = episodes
        self.episodes.sort(by: { $0.episode < $1.episode })
    }
    
    /// Build a Show from a TVMaze `lookup/shows?imdb=tt…` payload plus the
    /// imdb id (TVMaze doesn't echo it back) and the list of episodes
    /// gathered from EZTV. Used by YTSEZTVProvider when no Trakt session is
    /// active — TVMaze is unauthenticated, free, and not DNS-blocked, so it's
    /// the best public source of show metadata + cover art.
    public init?(tvmaze dict: [String: Any], imdbId: String, episodes: [Episode] = []) {
        guard let name = dict["name"] as? String else { return nil }
        self.id      = imdbId
        self.tmdbId  = nil
        self.tvdbId  = String((dict["externals"] as? [String: Any])?["thetvdb"] as? Int ?? 0)
        self.slug    = name.slugged
        self.title   = name.removingHtmlEncoding
        let premiered = (dict["premiered"] as? String) ?? ""
        self.year    = String(premiered.prefix(4))
        self.rating  = Float((dict["rating"] as? [String: Any])?["average"] as? Double ?? 0) * 10.0
        let summary  = (dict["summary"] as? String) ?? "No summary available.".localized
        self.summary = summary.removingHtmlEncoding
        self.runtime = (dict["runtime"] as? Int) ?? (dict["averageRuntime"] as? Int)
        self.status  = dict["status"] as? String
        self.genres  = (dict["genres"] as? [String]) ?? []
        self.network = (dict["network"] as? [String: Any])?["name"] as? String
        let imageDict = dict["image"] as? [String: Any]
        self.largeCoverImage      = ImageProxy.proxied(imageDict?["original"] as? String ?? imageDict?["medium"] as? String)
        self.largeBackgroundImage = self.largeCoverImage
        self.airDay  = ((dict["schedule"] as? [String: Any])?["days"] as? [String])?.first
        self.airTime = (dict["schedule"] as? [String: Any])?["time"] as? String
        self.episodes = episodes
        self.episodes.sort { $0.season == $1.season ? $0.episode < $1.episode : $0.season < $1.season }
    }

    /// Convenience init mapping a Time4Popcorn (`api.apiabcd.com`) show list
    /// object (`/shows`). Episodes are resolved later by `getShowInfo` via
    /// TVMaze (the show carries an imdb id TVMaze can look up). Posters are
    /// TMDB URLs (bypassed by ImageProxy, served directly).
    public init?(t4p dict: [String: Any]) {
        guard let title = dict["title"] as? String else { return nil }
        let rawImdb = (dict["imdb"] as? String) ?? ""
        guard !rawImdb.isEmpty else { return nil }
        self.id      = rawImdb.hasPrefix("tt") ? rawImdb : "tt\(rawImdb)"
        self.tvdbId  = "0"
        self.slug    = title.slugged
        self.title   = title.removingHtmlEncoding
        self.year    = String(dict["year"] as? Int ?? 0)
        let ratingValue = (dict["rating"] as? Double) ?? Double(dict["rating"] as? Int ?? 0)
        self.rating  = Float(ratingValue * 10.0)
        self.summary = ((dict["description"] as? String) ?? "No summary available.".localized).removingHtmlEncoding
        self.tmdbId  = nil
        self.runtime = (dict["runtime"] as? Int)
        self.genres  = (dict["genres"] as? [String]) ?? []
        // Rewrite the T4P TMDB poster to the image.tmdb.org CDN (see Movie).
        let poster   = ((dict["poster_big"] as? String) ?? (dict["poster_med"] as? String))?
            .replacingOccurrences(of: "://www.themoviedb.org/t/p/", with: "://image.tmdb.org/t/p/")
        self.largeCoverImage      = ImageProxy.proxied(poster)
        self.largeBackgroundImage = ImageProxy.proxied(poster)
    }

    public init(title: String = "Unknown".localized, id: String = "tt0000000", tmdbId: Int? = nil, slug: String = "unknown", summary: String = "No summary available.".localized, torrents: [Torrent] = [], subtitles: [Subtitle] = [], largeBackgroundImage: String? = nil, largeCoverImage: String? = nil) {
        self.title = title
        self.id = id
        self.tmdbId = tmdbId
        self.slug = slug
        self.summary = summary
        self.largeBackgroundImage = largeBackgroundImage
        self.largeCoverImage = largeCoverImage
        self.year = ""
        self.rating = 0.0
        self.runtime = 0
        self.tvdbId = "0000000"
    }
    
    public mutating func mapping(map: Map) {
        switch map.mappingType {
        case .fromJSON:
            if let show = Show(map: map) {
                self = show
            }
        case .toJSON:
            id >>> map["imdb_id"]
            tmdbId >>> map["ids.tmdb"]
            tvdbId >>> map["tvdb_id"]
            slug >>> map["slug"]
            year >>> map["year"]
            rating >>> map["rating.percentage"]
            largeCoverImage >>> map["images.poster"]
            largeBackgroundImage >>> map["images.fanart"]
            title >>> map["title"]
            runtime >>> (map["runtime"], IntTransform())
            summary >>> map["synopsis"]
            genres >>> map["genres"]
            status >>> map["status"]
            airDay >>> map["air_day"]
            airTime >>> map["air_time"]
        }
    }
    
    public var mediaItemDictionary: [String: Any] {
        return [MPMediaItemPropertyTitle: title,
                MPMediaItemPropertyMediaType: NSNumber(value: MPMediaType.tvShow.rawValue),
                MPMediaItemPropertyPersistentID: id,
                MPMediaItemPropertyArtwork: smallCoverImage ?? "",
                MPMediaItemPropertyBackgroundArtwork: smallBackgroundImage ?? "",
                MPMediaItemPropertySummary: summary]
    }
    
    public init?(_ mediaItemDictionary: [String: Any]) {
        guard
            let rawValue = mediaItemDictionary[MPMediaItemPropertyMediaType] as? NSNumber,
            let type = MPMediaType(rawValue: rawValue.uintValue) as MPMediaType?,
            type == MPMediaType.tvShow,
            let id = mediaItemDictionary[MPMediaItemPropertyPersistentID] as? String,
            let title = mediaItemDictionary[MPMediaItemPropertyTitle] as? String,
            let image = mediaItemDictionary[MPMediaItemPropertyArtwork] as? String,
            let backgroundImage = mediaItemDictionary[MPMediaItemPropertyBackgroundArtwork] as? String,
            let summary = mediaItemDictionary[MPMediaItemPropertySummary] as? String
            else {
                return nil
        }
        
        let largeBackgroundImage = backgroundImage.replacingOccurrences(of: backgroundImage.isAmazonUrl ? "SX300" : "w300", with: backgroundImage.isAmazonUrl ? "SX1000" : "w1000")
        let largeCoverImage = image.replacingOccurrences(of: image.isAmazonUrl ? "SX300" : "w300", with: image.isAmazonUrl ? "SX1000" : "w1000")
        
        self.init(title: title, id: id, slug: title.slugged, summary: summary, largeBackgroundImage: largeBackgroundImage, largeCoverImage: largeCoverImage)
    }
}

// MARK: - Hashable

extension Show: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: Equatable

public func ==(lhs: Show, rhs: Show) -> Bool {
    return lhs.id == rhs.id
}
