

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

    /// `SubFileName`: the name the uploader gave the file — often the
    /// release it was made for when `MovieReleaseName` is vague; nil when
    /// unknown. Compared with the file played (`SubtitleMatching`).
    public let fileName: String?

    /// `SubLastTS` in seconds: when the last cue starts, nil when unknown
    /// (a frame number for frame-based files is not read). A last cue far
    /// past the end of the film played says the subtitle was made for
    /// another cut or another frame rate (`SubtitleMatching`).
    public let lastCueTime: Double?

    /// The OpenSubtitles hash this row was found by (`MatchedBy` =
    /// moviehash), nil for a row of the imdb search: such a subtitle was
    /// made for, or linked to, a file of exactly that hash and size.
    public let movieHash: String?

    /// `IDMovieImdb` (digits, no "tt", no leading zeros): the movie — or,
    /// for an episode, the episode itself.
    public let imdbId: String?

    /// `SeriesIMDBParent`, `SeriesSeason`, `SeriesEpisode` of an episode
    /// row (nil for a movie): a moviehash search answers for any title, so
    /// its rows are kept only when they name the episode played.
    public let showImdbId: String?
    public let season: Int?
    public let episode: Int?

    /// `IDSubtitleFile`: the same file found by both searches has the same
    /// id (its download links differ by a token).
    public let fileId: String?

    /// The other rows of this language, best first by the plain score
    /// (`SubtitlesManager.bestSubtitles`): the player re-ranks them against
    /// the file it plays (`SubtitleMatching.choose`). Empty on the
    /// alternates themselves.
    public let alternates: [Subtitle]

    public init(language: String,
                link: String,
                ISO639: String,
                rating: Double,
                format: String? = nil,
                encoding: String? = nil,
                releaseName: String? = nil,
                hearingImpaired: Bool = false,
                frameRate: Double? = nil,
                fileName: String? = nil,
                lastCueTime: Double? = nil,
                movieHash: String? = nil,
                imdbId: String? = nil,
                showImdbId: String? = nil,
                season: Int? = nil,
                episode: Int? = nil,
                fileId: String? = nil,
                alternates: [Subtitle] = []) {
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
        let fileName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fileName = fileName?.isEmpty == false ? fileName : nil
        self.lastCueTime = lastCueTime.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let movieHash = movieHash?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.movieHash = movieHash?.isEmpty == false ? movieHash : nil
        self.imdbId = imdbId.flatMap(Subtitle.normalizedImdb)
        self.showImdbId = showImdbId.flatMap(Subtitle.normalizedImdb)
        self.season = season
        self.episode = episode
        self.fileId = fileId?.isEmpty == false ? fileId : nil
        self.alternates = alternates
    }

    /// The same row with `alternates`.
    func with(alternates: [Subtitle]) -> Subtitle {
        Subtitle(language: language, link: link, ISO639: ISO639, rating: rating, format: format, encoding: encoding,
                 releaseName: releaseName, hearingImpaired: hearingImpaired, frameRate: frameRate, fileName: fileName,
                 lastCueTime: lastCueTime, movieHash: movieHash, imdbId: imdbId, showImdbId: showImdbId, season: season,
                 episode: episode, fileId: fileId, alternates: alternates)
    }

    /// Every row of this language: this one, then its alternates.
    public var allRows: [Subtitle] { [with(alternates: [])] + alternates }

    /// "tt0111161", "0111161", "111161" → "111161"; nil for "0", "" or
    /// anything not made of digits.
    static func normalizedImdb(_ raw: String) -> String? {
        var digits = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if digits.hasPrefix("tt") { digits.removeFirst(2) }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let trimmed = String(digits.drop { $0 == "0" })
        return trimmed.isEmpty ? nil : trimmed
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
