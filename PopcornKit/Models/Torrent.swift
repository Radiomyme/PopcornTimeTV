

import Foundation
import ObjectMapper

/**
 Health of a torrent.
 */
public enum Health {
    case bad
    case medium
    case good
    case excellent
    case unknown

    public var color: UIColor {
        switch self {
        case .bad:       return UIColor(red: 212.0/255.0, green:  14.0/255.0, blue:   0.0/255.0, alpha: 1.0)
        case .medium:    return UIColor(red: 212.0/255.0, green: 120.0/255.0, blue:   0.0/255.0, alpha: 1.0)
        case .good:      return UIColor(red: 201.0/255.0, green: 212.0/255.0, blue:   0.0/255.0, alpha: 1.0)
        case .excellent: return UIColor(red:  90.0/255.0, green: 186.0/255.0, blue:   0.0/255.0, alpha: 1.0)
        case .unknown:   return UIColor(red: 105.0/255.0, green: 105.0/255.0, blue: 105.0/255.0, alpha: 1.0)
        }
    }
}

/// Resolution buckets we care about. Raw value sorts naturally low → high.
/// 3D is intentionally placed BELOW SD because Half-Side-By-Side / Top-and-
/// Bottom variants render as a doubled image on a standard 4K TV — they're
/// a special-purpose variant, not a higher quality tier. Auto-picking the
/// "highest quality" should never land on 3D unless that's the only option.
public enum VideoQuality: Int, Comparable, Codable {
    case unknown = 0
    case threeD  = 1
    case sd480   = 480
    case hd720   = 720
    case hd1080  = 1080
    case uhd2160 = 2160

    public static func < (lhs: VideoQuality, rhs: VideoQuality) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    /// Parse a raw quality token from API or a torrent name.
    /// Examples: "2160p", "4K", "UHD", "1080p", "1080p.bluray", "720", "480p", "3D"
    public static func parse(_ raw: String) -> VideoQuality {
        let s = raw.lowercased()
        if s.contains("2160") || s.contains("4k") || s.contains("uhd") { return .uhd2160 }
        if s.contains("1080") { return .hd1080 }
        if s.contains("720")  { return .hd720 }
        if s.contains("480")  { return .sd480 }
        if s == "3d" || s.contains(" 3d") || s.contains(".3d") || s.contains("-3d") { return .threeD }
        return .unknown
    }

    /// Human-readable label preserved in `Torrent.quality` for the UI alerts
    /// that previously displayed the raw API string.
    public var displayLabel: String {
        switch self {
        case .uhd2160: return "2160p"
        case .hd1080:  return "1080p"
        case .hd720:   return "720p"
        case .sd480:   return "480p"
        case .threeD:  return "3D"
        case .unknown: return ""
        }
    }
}

/// Codec / dynamic-range / audio modifiers parsed from the torrent name.
/// Used as a tiebreaker in sorting (HDR/HEVC/Atmos preferred at equal resolution)
/// and to inform the player engine of HDR/Dolby Vision content.
public struct VideoTags: OptionSet, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let hdr10        = VideoTags(rawValue: 1 << 0)
    public static let hdr10Plus    = VideoTags(rawValue: 1 << 1)
    public static let dolbyVision  = VideoTags(rawValue: 1 << 2)
    public static let hevc         = VideoTags(rawValue: 1 << 3)
    public static let av1          = VideoTags(rawValue: 1 << 4)
    public static let atmos        = VideoTags(rawValue: 1 << 5)
    public static let trueHD       = VideoTags(rawValue: 1 << 6)
    public static let dts          = VideoTags(rawValue: 1 << 7)

    /// Parse a torrent name string for codec/HDR/audio markers.
    public static func parse(_ raw: String) -> VideoTags {
        let s = raw.lowercased().replacingOccurrences(of: "-", with: " ")
        var tags: VideoTags = []
        if s.contains("dv ") || s.contains("dovi") || s.contains("dolby.vision") || s.contains("dolby vision") { tags.insert(.dolbyVision) }
        if s.contains("hdr10+") || s.contains("hdr10plus") { tags.insert(.hdr10Plus) }
        if s.contains("hdr") { tags.insert(.hdr10) }
        if s.contains("hevc") || s.contains("x265") || s.contains("h.265") || s.contains("h265") { tags.insert(.hevc) }
        if s.contains("av1") || s.contains("aom") { tags.insert(.av1) }
        if s.contains("atmos") { tags.insert(.atmos) }
        if s.contains("truehd") || s.contains("true hd") { tags.insert(.trueHD) }
        if s.contains("dts") { tags.insert(.dts) }
        return tags
    }

    /// Human-readable suffix (e.g. " HDR DV HEVC Atmos") for the UI picker.
    public var displaySuffix: String {
        var parts: [String] = []
        if contains(.dolbyVision) { parts.append("DV") }
        if contains(.hdr10Plus)   { parts.append("HDR10+") }
        else if contains(.hdr10)  { parts.append("HDR") }
        if contains(.atmos)       { parts.append("Atmos") }
        if contains(.av1)         { parts.append("AV1") }
        else if contains(.hevc)   { parts.append("HEVC") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }
}

public struct Torrent: Mappable, Equatable, Comparable {

    public let health: Health
    public let url: String

    /// Resolution bucket of this torrent (480 / 720 / 1080 / 2160 / 3D / unknown).
    public var qualityValue: VideoQuality

    /// Codec / HDR / audio tags parsed from the torrent name.
    public var tags: VideoTags

    /// Backing storage so callers can still set `.quality` to a custom string
    /// (some Movie/Episode JSON paths assign it after construction).
    private var _qualityOverride: String?

    /// Human-readable quality label, e.g. "2160p HDR DV HEVC". Preserved as a
    /// settable property so the existing call sites that do
    /// `torrent.quality = key` after mapping continue to work.
    public var quality: String! {
        get {
            if let override = _qualityOverride { return override }
            return qualityValue.displayLabel + tags.displaySuffix
        }
        set {
            _qualityOverride = newValue
            if let value = newValue {
                qualityValue = VideoQuality.parse(value)
                tags = VideoTags.parse(value)
            }
        }
    }

    public let seeds: Int
    public let peers: Int
    public let size: String?

    public init?(map: Map) {
        do { self = try Torrent(map) }
        catch { return nil }
    }

    private init(_ map: Map) throws {
        self.url   = try map.value("url")
        self.seeds = (try? (try? map.value("seeds")) ?? map.value(("seed"))) ?? 0
        self.peers = (try? (try? map.value("peers")) ?? map.value(("peer"))) ?? 0
        self.size  = try? map.value("filesize")

        // Quality may be supplied as a JSON field, or set later by Movie/Episode mapping.
        let qualityString: String? = try? map.value("quality")
        if let q = qualityString {
            self._qualityOverride = q
            self.qualityValue     = VideoQuality.parse(q)
            self.tags             = VideoTags.parse(q)
        } else {
            self._qualityOverride = nil
            self.qualityValue     = .unknown
            self.tags             = []
        }

        let ratio            = peers > 0 ? (seeds / peers) : seeds
        let normalizedRatio  = min(ratio / 5 * 100, 100)
        let normalizedSeeds  = min(seeds / 30 * 100, 100)
        let weightedRatio    = Double(normalizedRatio) * 0.6
        let weightedSeeds    = Double(normalizedSeeds) * 0.4
        let weightedTotal    = weightedRatio + weightedSeeds
        var scaledTotal      = (weightedTotal * 3.0) / 100.0
        if scaledTotal < 0 { scaledTotal = 0 }

        switch floor(scaledTotal) {
        case 0:  health = .bad
        case 1:  health = .medium
        case 2:  health = .good
        case 3:  health = .excellent
        default: health = .unknown
        }
    }

    public init(health: Health = .unknown,
                url: String = "",
                quality: String = "",
                seeds: Int = 0,
                peers: Int = 0,
                size: String? = nil,
                tags: VideoTags = []) {
        self.health = health
        self.url    = url
        self.seeds  = seeds
        self.peers  = peers
        self.size   = size
        self._qualityOverride = quality.isEmpty ? nil : quality
        self.qualityValue     = VideoQuality.parse(quality)
        self.tags             = tags.isEmpty ? VideoTags.parse(quality) : tags
    }

    public mutating func mapping(map: Map) {
        switch map.mappingType {
        case .fromJSON:
            if let torrent = Torrent(map: map) {
                self = torrent
            }

        case .toJSON:
            url               >>> map["url"]
            seeds             >>> map["seeds"]
            peers             >>> map["peers"]
            quality           >>> map["quality"]
            size              >>> map["filesize"]
        }
    }
}

/// Total ordering: 3D sentinel sits above 2160p, then resolution descending
/// gets handled by VideoQuality's natural Int-ordered Comparable. At equal
/// resolution, prefer the torrent with HDR/DV/HEVC/Atmos tags, then prefer
/// more seeders.
public func < (lhs: Torrent, rhs: Torrent) -> Bool {
    if lhs.qualityValue != rhs.qualityValue {
        return lhs.qualityValue < rhs.qualityValue
    }
    let lhsScore = lhs.tags.rawValue.nonzeroBitCount
    let rhsScore = rhs.tags.rawValue.nonzeroBitCount
    if lhsScore != rhsScore { return lhsScore < rhsScore }
    return lhs.seeds < rhs.seeds
}

public func > (lhs: Torrent, rhs: Torrent) -> Bool {
    return rhs < lhs
}

public func == (lhs: Torrent, rhs: Torrent) -> Bool {
    return lhs.url == rhs.url
}

public extension Torrent {

    /// Pick the highest resolution whose best-seeded torrent has a swarm large
    /// enough to start streaming quickly, rather than the absolute highest.
    ///
    /// Higher resolutions carry far more bitrate, so they need a bigger swarm
    /// before playback can begin. A brand-new 4K release with ~20 seeds can
    /// take many minutes to buffer, whereas a well-seeded 1080p (roughly a
    /// third of the size) starts almost immediately. This walks resolutions
    /// high → low, taking the first whose best-seeded torrent clears a
    /// resolution-scaled seed floor; if nothing clears its bar it returns the
    /// most-seeded torrent overall (best shot at a quick start).
    static func balancedPick(from torrents: [Torrent]) -> Torrent? {
        guard !torrents.isEmpty else { return nil }
        let minSeeds: [VideoQuality: Int] = [.uhd2160: 45, .hd1080: 10, .hd720: 5, .sd480: 2]
        for quality in [VideoQuality.uhd2160, .hd1080, .hd720, .sd480] {
            let tier = torrents.filter { $0.qualityValue == quality }
            guard let best = tier.max(by: { $0.seeds < $1.seeds }) else { continue }
            if best.seeds >= (minSeeds[quality] ?? 1) {
                return best
            }
        }
        return torrents.max(by: { $0.seeds < $1.seeds })
    }
}
