

import Foundation
import ObjectMapper
import MediaPlayer.MPMediaItem

/**
 Struct for managing Movie objects.
 
 **Important:** In the description of all the optional variables where it says another method must be called on **only** `MovieManager` to populate x, does not apply if the movie was loaded from Trakt. **However**, no torrent metadata will be retrieved when movies are loaded from Trakt. They will need to be retrieved by calling `getInfo:imdbId:completion` on `MovieManager`.
 
 `TraktManager` has to be called regardless to fill up the special variables.
 */
public struct Movie: Media, Equatable {
    
    /// Imdb id of the movie.
    public let id: String
    
    /// TMDB id of the movie. If movie is loaded from Trakt, this will not be `nil`. Otherwise it will be `nil` and `getTMDBId:forImdbId:completion:` will have to be called on `TraktManager`.
    public var tmdbId: Int?
    
    /// The slug of the movie. May be wrong as it is being computed from title and year instead of being pulled from apis.
    public let slug: String
    
    /// Title of the movie.
    public let title: String
    
    /// Release date of the movie.
    public let year: String
    
    /// Rating percentage for the movie.
    public let rating: Float
    
    /// The runtime of the movie rounded to the nearest minute.
    public let runtime: Int
    
    /// The summary of the movie. Will default to "No summary available.".localized if a summary is not provided by the api.
    public let summary: String
    
    /// The trailer url of the movie. Will be `nil` if a trailer is not provided by the api.
    public var trailer: String?
    
    /// The youtube code (part of the url after `?v=`) of the trailer. Will be `nil` if trailer url is `nil`.
    public var trailerCode: String? {
        return trailer?.slice(from: "?v=", to: "")
    }
    
    /// The certification type according to the Motion picture rating system.
    public let certification: String
    
    
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

    /// If poster image is available, it is returned with size 1500*1000.
    public var largeCoverImage: String?
    
    /// Convenience variable. Boolean value indicating the watched status of the movie.
    public var isWatched: Bool {
        get {
            return WatchedlistManager<Movie>.movie.isAdded(id)
        } set (add) {
            add ? WatchedlistManager<Movie>.movie.add(id) : WatchedlistManager<Movie>.movie.remove(id)
        }
    }
    
    /// Convenience variable. Boolean value indicating whether or not the movie has been added the users watchlist.
    public var isAddedToWatchlist: Bool {
        get {
            return WatchlistManager<Movie>.movie.isAdded(self)
        } set (add) {
            add ? WatchlistManager<Movie>.movie.add(self) : WatchlistManager<Movie>.movie.remove(self)
        }
    }
    

    /// All the people that worked on the movie. Empty by default. Must be filled by calling `getPeople:forMediaOfType:id:completion` on `TraktManager`.
    public var crew = [Crew]()
    
    /// All the actors in the movie. Empty by default. Must be filled by calling `getPeople:forMediaOfType:id:completion` on `TraktManager`.
    public var actors = [Actor]()
    
    /// The related movies. Empty by default. Must be filled by calling `getRelated:media:completion` on `TraktManager`.
    public var related = [Movie]()
    
    /// The torrents for the movie. Will be empty by default if the movies were loaded from Trakt. Can be filled by calling `getInfo:imdbId:completion` on `MovieManager`.
    public var torrents = [Torrent]()
    
    /// The subtitles associated with the movie. Empty by default. Must be filled by calling `search:episode:imdbId:limit:completion:` on `SubtitlesManager`.
    public var subtitles = [Subtitle]()
    
    /// The genres associated with the movie.
    public var genres = [String]()
    
    public init?(map: Map) {
        do { self = try Movie(map) }
        catch { return nil }
    }

    private init(_ map: Map) throws {
        if map.context is TraktContext {
            self.id = try map.value("ids.imdb")
            self.year = try map.value("year", using: StringTransform())
            self.rating = try map.value("rating")
            self.summary = ((try? map.value("overview")) ?? "No summary available.".localized).removingHtmlEncoding
            self.runtime = try map.value("runtime")
        } else {
            self.id = try map.value("imdb_id")
            self.year = try map.value("year")
            self.rating = try map.value("rating.percentage")
            self.summary = ((try? map.value("synopsis")) ?? "No summary available.".localized).removingHtmlEncoding
            self.largeCoverImage = try? map.value("images.poster"); largeCoverImage = ImageProxy.proxied(largeCoverImage?.replacingOccurrences(of: "w500", with: "w1000").replacingOccurrences(of: "SX300", with: "SX1000"))
            self.largeBackgroundImage = try? map.value("images.fanart"); largeBackgroundImage = ImageProxy.proxied(largeBackgroundImage?.replacingOccurrences(of: "w500", with: "w1920").replacingOccurrences(of: "SX300", with: "SX1920"))
            self.runtime = try map.value("runtime", using: IntTransform())

        }
        var title: String = try map.value("title")
        title.removeHtmlEncoding()
        self.title = title
        self.tmdbId = try? map.value("ids.tmdb")
        self.slug = title.slugged
        self.trailer = try? map.value("trailer"); trailer == "false" ? trailer = nil : ()
        self.certification = try map.value("certification")
        self.genres = (try? map.value("genres")) ?? [String]()
        if let torrents = map["torrents.en"].currentValue as? [String: [String: Any]] {
            for (quality, torrent) in torrents {
                if var torrent = Mapper<Torrent>().map(JSONObject: torrent) , quality != "0" {
                    torrent.quality = quality
                    self.torrents.append(torrent)
                }
            }
        }
        torrents.sort(by: <)
    }
    
    /// Convenience init that maps a YTS movie payload (from `yts.mx/api/v2`)
    /// directly into a Movie without going through ObjectMapper. The schema
    /// differs from the legacy Popcorn API (torrents is an Array, quality
    /// strings include "2160p", `imdb_code` instead of `imdb_id`).
    public init?(yts dict: [String: Any]) {
        guard
            let imdb  = dict["imdb_code"] as? String,
            let title = dict["title"] as? String
        else { return nil }
        self.id    = imdb
        self.title = title.removingHtmlEncoding
        self.slug  = (dict["slug"] as? String) ?? title.slugged
        self.year  = String(dict["year"] as? Int ?? 0)
        // YTS rating is 0–10 float; the rest of the codebase expects 0–100 (Popcorn API style).
        let ytsRating = (dict["rating"] as? Double) ?? Double(dict["rating"] as? Int ?? 0)
        self.rating  = Float(ytsRating * 10.0)
        self.runtime = (dict["runtime"] as? Int) ?? 0
        let summaryText = (dict["description_full"] as? String) ?? (dict["synopsis"] as? String) ?? (dict["summary"] as? String) ?? "No summary available.".localized
        self.summary = summaryText.removingHtmlEncoding
        self.trailer = (dict["yt_trailer_code"] as? String).flatMap { code in
            code.isEmpty ? nil : "https://www.youtube.com/watch?v=\(code)"
        }
        self.certification = (dict["mpa_rating"] as? String) ?? "Unrated"
        self.genres = (dict["genres"] as? [String]) ?? []
        self.tmdbId = nil
        self.largeCoverImage      = ImageProxy.proxied((dict["large_cover_image"] as? String) ?? (dict["medium_cover_image"] as? String))
        self.largeBackgroundImage = ImageProxy.proxied((dict["background_image_original"] as? String) ?? (dict["background_image"] as? String))
        if let ytsTorrents = dict["torrents"] as? [[String: Any]] {
            for entry in ytsTorrents {
                guard let hash = entry["hash"] as? String else { continue }
                let qualityString = (entry["quality"] as? String) ?? "unknown"
                let codec         = entry["video_codec"] as? String ?? ""
                let audio         = entry["audio_channels"] as? String ?? ""
                let composedTags  = qualityString + " " + codec + " " + audio
                var torrent = Torrent(
                    health: .unknown,
                    url:    Movie.ytsMagnet(hash: hash, title: title),
                    quality: qualityString,
                    seeds:   entry["seeds"] as? Int ?? 0,
                    peers:   entry["peers"] as? Int ?? 0,
                    size:    entry["size"]  as? String,
                    tags:    VideoTags.parse(composedTags))
                // Re-apply quality string to enrich tags from the composed string.
                torrent.quality = qualityString + (torrent.tags.displaySuffix)
                self.torrents.append(torrent)
            }
            self.torrents.sort(by: <)
        }
    }

    /// YTS only exposes torrent hashes; build a standard magnet link with the
    /// public trackers YTS recommends.
    private static func ytsMagnet(hash: String, title: String) -> String {
        let trackers = [
            "udp://open.demonii.com:1337/announce",
            "udp://tracker.openbittorrent.com:80",
            "udp://tracker.coppersurfer.tk:6969",
            "udp://glotorrents.pw:6969/announce",
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://torrent.gresille.org:80/announce",
            "udp://p4p.arenabg.com:1337",
            "udp://tracker.leechers-paradise.org:6969",
        ]
        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? title
        let trackersQS = trackers.map { "tr=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? $0) }.joined(separator: "&")
        return "magnet:?xt=urn:btih:\(hash)&dn=\(encodedTitle)&\(trackersQS)"
    }

    public init(title: String = "Unknown".localized, id: String = "tt0000000", tmdbId: Int? = nil, slug: String = "unknown", summary: String = "No summary available.".localized, torrents: [Torrent] = [], subtitles: [Subtitle] = [], largeBackgroundImage: String? = nil, largeCoverImage: String? = nil) {
        self.title = title
        self.id = id
        self.tmdbId = tmdbId
        self.slug = slug
        self.summary = summary
        self.torrents = torrents
        self.subtitles = subtitles
        self.largeBackgroundImage = largeBackgroundImage
        self.largeCoverImage = largeCoverImage
        self.year = ""
        self.certification = "Unrated"
        self.rating = 0.0
        self.runtime = 0
    }

    public mutating func mapping(map: Map) {
        switch map.mappingType {
        case .fromJSON:
            if let movie =  Movie(map: map) {
                self = movie
            }
        case .toJSON:
            id >>> map["imdb_id"]
            tmdbId >>> map["ids.tmdb"]
            year >>> map["year"]
            rating >>> map["rating.percentage"]
            summary >>> map["synopsis"]
            largeCoverImage >>> map["images.poster"]
            largeBackgroundImage >>> map["images.fanart"]
            runtime >>> (map["runtime"], IntTransform())
            title >>> map["title"]
            trailer >>> map["trailer"]
            certification >>> map["certification"]
            genres >>> map["genres"]
        }
    }
    
    public var mediaItemDictionary: [String: Any] {
        return [MPMediaItemPropertyTitle: title,
                MPMediaItemPropertyMediaType: NSNumber(value: MPMediaType.movie.rawValue),
                MPMediaItemPropertyPersistentID: id,
                MPMediaItemPropertyArtwork: smallCoverImage ?? "",
                MPMediaItemPropertyBackgroundArtwork: smallBackgroundImage ?? "",
                MPMediaItemPropertySummary: summary]
    }
    
    public init?(_ mediaItemDictionary: [String: Any]) {
        guard
            let rawValue = mediaItemDictionary[MPMediaItemPropertyMediaType] as? NSNumber,
            let type = MPMediaType(rawValue: rawValue.uintValue) as MPMediaType?,
            type == MPMediaType.movie,
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

extension Movie: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: Equatable

public func ==(lhs: Movie, rhs: Movie) -> Bool {
    return lhs.id == rhs.id
}
