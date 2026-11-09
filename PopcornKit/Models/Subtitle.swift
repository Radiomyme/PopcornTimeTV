

import Foundation
import ObjectMapper

/**
  Struct for managing subtitle objects.
 */
public struct Subtitle: Equatable {

    /// Language string of the subtitle. Eg. English.
    public let language: String

    /// Link to the subtitle zip.
    public let link: String

    /// Two letter ISO language code of the subtitle eg. en.
    public let ISO639: String

    /// The OpenSubtitles rating for the subtitle.
    internal let rating: Double

    /// Lowercased OpenSubtitles `SubFormat` ("srt", "sub", "ass", "ssa",
    /// "smi", "mpl", "txt", "vtt"…), nil when unknown. Hint for the
    /// subtitle converter (`.sub` can be MicroDVD or SubViewer).
    public let format: String?

    /// OpenSubtitles `SubEncoding` of the file ("UTF-8", "CP1252", "CP1251",
    /// "GB18030"…), nil when unknown. Files are served in that code page,
    /// not converted to UTF-8.
    public let encoding: String?

    /// `MovieReleaseName` the subtitle was synced against, nil when unknown.
    public let releaseName: String?

    /// True for hearing-impaired (SDH) subtitles.
    public let hearingImpaired: Bool

    /// `MovieFPS` of the release the subtitle was made for (> 0), nil when
    /// unknown. Frame-based formats (MicroDVD) that don't declare a frame
    /// rate need one to be timed.
    public let frameRate: Double?

    public init(language: String,
                link: String,
                ISO639: String,
                rating: Double,
                format: String? = nil,
                encoding: String? = nil,
                releaseName: String? = nil,
                hearingImpaired: Bool = false,
                frameRate: Double? = nil) {
        self.language = language
        self.link = link
        self.ISO639 = ISO639
        self.rating = rating
        let format = format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.format = format?.isEmpty == false ? format : nil
        let encoding = encoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.encoding = encoding?.isEmpty == false ? encoding : nil
        let releaseName = releaseName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.releaseName = releaseName?.isEmpty == false ? releaseName : nil
        self.hearingImpaired = hearingImpaired
        self.frameRate = frameRate.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
    }

    /// BCP 47 tag for `ISO639`, with OpenSubtitles' own codes mapped
    /// (pb → pt-BR, zt → zh-Hant, ze → zh, sp → es-ES, ea → es-419,
    /// me → sr-ME). Use it for HLS `LANGUAGE` and language matching.
    public var bcp47Language: String {
        switch ISO639.lowercased() {
        case "pb": return "pt-BR"
        case "zt": return "zh-Hant"
        case "ze": return "zh"
        case "sp": return "es-ES"
        case "ea": return "es-419"
        case "me": return "sr-ME"
        default:   return ISO639.lowercased()
        }
    }
}

public func ==(lhs: Subtitle, rhs: Subtitle) -> Bool {
    return lhs.link == rhs.link
}
