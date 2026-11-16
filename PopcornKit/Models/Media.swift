

import Foundation
import ObjectMapper
import MediaPlayer.MPMediaItem

/// Generic media protocol.
public protocol Media: Mappable {
    var title: String { get }
    var id: String { get }
    var tmdbId: Int? { get set }
    var slug: String { get }
    
    var summary: String { get }
    
    var smallBackgroundImage: String? { get }
    var mediumBackgroundImage: String? { get }
    var largeBackgroundImage: String? { get set }
    var smallCoverImage: String? { get }
    var mediumCoverImage: String? { get }
    var largeCoverImage: String? { get set }
    
    /// Will be empty if Media is Show.
    var subtitles: [Subtitle] { get set }
    
    /// Will be empty if Media is Show.
    var torrents: [Torrent] { get set }
    
    /// Will return `false` if Media is Show.
    var isWatched: Bool { get set }
    
    /// Will return `false` if Media is Episode.
    var isAddedToWatchlist: Bool { get set }
    
    var mediaItemDictionary: [String: Any] { get }
    
    init?(_ mediaItemDictionary: [String: Any])
}

// MARK: - Optional vars

extension Media {
    public var subtitles: [Subtitle] { get { return [] } set {} }
    public var torrents: [Torrent] { get { return [] } set {} }
    
    public var isWatched: Bool { get { return false } set {} }
    
    public var isAddedToWatchlist: Bool { get { return false } set {} }
    
    public var smallCoverImage: String? { return nil }
    public var mediumCoverImage: String? { return nil }
    public var largeCoverImage: String? { get{ return nil } set {} }
}

extension String {
    public var isAmazonUrl: Bool {
        return contains("https://images-na.ssl-images-amazon.com/images/")
    }
}

class IntTransform: TransformType {
    typealias Object = Int
    typealias JSON = String
    
    init() {}
    
    func transformFromJSON(_ value: Any?) -> Object? {
        if let json = value as? JSON {
            return Object(json)
        }
        
        return nil
    }
    
    func transformToJSON(_ value: Object?) -> JSON? {
        if let object = value {
            return JSON(object)
        }
        return nil
    }
}

class StringTransform: TransformType {
    typealias Object = String
    typealias JSON = Int
    
    init() {}
    
    func transformFromJSON(_ value: Any?) -> Object? {
        if let json = value as? JSON {
            return Object(json)
        }
        
        return nil
    }
    
    func transformToJSON(_ value: Object?) -> JSON? {
        if let object = value {
            return JSON(object)
        }
        return nil
    }
}

/// An episode's id in its JSON ("tvdb_id"). 4.x ids are TVDB numbers, stored
/// as numbers; since 5.0.0 an id is "<show IMDb id>-s<season>e<number>",
/// which `StringTransform` could not write (`Int(id)` is nil): the key was
/// left out and reading the JSON back gave no episode at all. Numbers stay
/// numbers (an older build reads them), anything else is written as it is.
class EpisodeIDTransform: TransformType {
    typealias Object = String
    typealias JSON = Any

    init() {}

    func transformFromJSON(_ value: Any?) -> Object? {
        // A negative number lost its sign in 4.x too.
        if let number = value as? Int { return String(number).replacingOccurrences(of: "-", with: "") }
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    func transformToJSON(_ value: Object?) -> JSON? {
        guard let id = value else { return nil }
        if let number = Int(id) { return number }
        return id
    }
}
