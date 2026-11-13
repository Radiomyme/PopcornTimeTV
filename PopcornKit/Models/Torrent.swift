

import Foundation
import ObjectMapper
#if canImport(UIKit)
import UIKit
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
#endif

/**
 Health of a torrent.
 */
public enum Health {
    case bad
    case medium
    case good
    case excellent
    case unknown

    public var color: PlatformColor {
        switch self {
        case .bad:       return PlatformColor(red: 212.0/255.0, green:  14.0/255.0, blue:   0.0/255.0, alpha: 1.0)
        case .medium:    return PlatformColor(red: 212.0/255.0, green: 120.0/255.0, blue:   0.0/255.0, alpha: 1.0)
        case .good:      return PlatformColor(red: 201.0/255.0, green: 212.0/255.0, blue:   0.0/255.0, alpha: 1.0)
        case .excellent: return PlatformColor(red:  90.0/255.0, green: 186.0/255.0, blue:   0.0/255.0, alpha: 1.0)
        case .unknown:   return PlatformColor(red: 105.0/255.0, green: 105.0/255.0, blue: 105.0/255.0, alpha: 1.0)
        }
    }
}

// MARK: - Release-name analysis
//
// Everything from here down to `struct Torrent` is pure Foundation (plus the
// `PlaybackCapabilities.Snapshot` value type), so the parsers and the ranking
// score can be unit-tested headlessly against real release names.

/// Tokenizer and small classifiers shared by the resolution, tag, release-type
/// and file-selection parsers.
public enum ReleaseName {

    /// Lower-cased tokens of a release or file name. Alphanumeric runs are
    /// split at every letter↔digit boundary and "+" is kept as a token of its
    /// own, so every common spelling of a tag becomes the same sequence:
    /// "DDP5.1" → ddp 5 1 · "DD+" → dd + · "x264" / "H.264" → x|h 264 ·
    /// "HDR10+" → hdr 10 + · "10bit" / "10-bit" → 10 bit · "E-AC-3" → e ac 3 ·
    /// "DTS-HD MA" → dts hd ma · "HDRip" → hdrip (never "hdr").
    public static func tokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        var currentIsDigit = false
        func flush() {
            if !current.isEmpty {
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        for scalar in raw.lowercased().unicodeScalars {
            let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
            if isDigit || CharacterSet.letters.contains(scalar) {
                if !current.isEmpty && isDigit != currentIsDigit { flush() }
                current.append(scalar)
                currentIsDigit = isDigit
            } else {
                flush()
                if scalar == "+" { tokens.append("+") }
            }
        }
        flush()
        return tokens
    }

    /// Source / service tokens that start (or resume) the technical part of a name.
    static let technicalSources: Set<String> = ["bluray", "bdrip", "brrip", "bdremux", "remux", "web", "webrip", "webdl",
                                                "hdtv", "dvdrip", "hdrip", "uhd", "dvd", "amzn", "nf", "dsnp", "atvp", "hmax"]

    /// A year, a resolution ("1080p") or a source tag at token `i`.
    static func isTechnicalAnchor(_ t: [String], at i: Int) -> Bool {
        let token = t[i], next = i + 1 < t.count ? t[i + 1] : ""
        if let number = Int(token) {
            if token.count == 4 && (1900...2099).contains(number) { return true }
            return (next == "p" || next == "i") && [480, 540, 576, 720, 1080, 2160, 4320].contains(number)
        }
        return technicalSources.contains(token)
    }

    /// A codec, audio, HDR, bit-depth or source-abbreviation token at `i`:
    /// technical, never a word of an episode title ("…S03E05 - The Bonding -
    /// AV1 - Opus", "…S01E05 BR OPUS VFF…").
    static func isFormatToken(_ t: [String], at i: Int) -> Bool {
        let token = t[i], next = i + 1 < t.count ? t[i + 1] : ""
        switch token {
        case "hevc", "avc", "xvid", "divx", "aac", "flac", "truehd", "atmos", "ddp", "ddpa", "eac", "dts", "dtshd",
             "lpcm", "pcm", "hdr", "dovi", "dv", "hlg", "br", "bd", "hdlight":
            return true
        case "x", "h": return next == "264" || next == "265"
        case "av": return next == "1"
        case "vp": return next == "9"
        case "ac", "mp": return next == "3"
        case "dd": return next == "+" || Int(next) != nil
        case "10": return next == "bit" || next == "bits"
        default: return false
        }
    }

    /// Number of tokens of the episode marker starting at token `i` —
    /// `SxxEyy[Eyy…]` (s 02 e 05), `Sxx` (s 02) or `NxNN` (3 x 05) — else 0.
    static func episodeMarkerLength(_ t: [String], at i: Int) -> Int {
        func at(_ j: Int) -> String { return j < t.count ? t[j] : "" }
        if t[i] == "s" && Int(at(i + 1)) != nil {
            var j = i + 2
            while at(j) == "e" && Int(at(j + 1)) != nil { j += 2 }
            return j - i
        }
        let episode = at(i + 2)
        if t[i].count <= 2, Int(t[i]) != nil, at(i + 1) == "x",
           (2...3).contains(episode.count), Int(episode) != nil, episode != "264", episode != "265" {
            return 3
        }
        return 0
    }

    /// Per token, whether a tag that is also an ordinary word ("Opus", "Cam",
    /// "Screener"…) may be read there: only inside the technical part of the
    /// name — from its first year / episode marker / resolution / source
    /// token on — and never in an episode title, i.e. after an episode marker
    /// (`SxxEyy`, `Sxx`, `NxNN`) until the next year, resolution, source or
    /// format token (`isFormatToken`). So "Mr.Hollands.Opus.1995…", "Cam.2018…", "Body.Cam.S07E05…"
    /// (title / show name) and "Show.S02E05.Cam.Girl.1080p…",
    /// "Show.S03E07.Magnum.Opus.1080p…" (episode titles) carry no such tag,
    /// while "Movie.2023.HDCAM.x264" or "[Group] Show - 01 [1080p][AV1][Opus]" do.
    /// A name without any of those tokens — a bare label such as
    /// " CAM H.264 AAC", which `Torrent.quality`'s setter re-parses — is
    /// read whole.
    static func wordTagMask(of t: [String]) -> [Bool] {
        var mask = [Bool](repeating: false, count: t.count)
        var technical = false, episodeTitle = false
        var i = 0
        while i < t.count {
            let marker = episodeMarkerLength(t, at: i)
            if marker > 0 {
                technical = true
                episodeTitle = true
                i += marker
                continue
            }
            if isTechnicalAnchor(t, at: i) {
                technical = true
                episodeTitle = false
            } else if episodeTitle && isFormatToken(t, at: i) {
                // Ends an episode title, but never starts the technical part
                // ("Movie.Opus.x264" keeps its former reading).
                episodeTitle = false
            }
            mask[i] = technical && !episodeTitle
            i += 1
        }
        return technical ? mask : [Bool](repeating: true, count: t.count)
    }

    /// Containers AVPlayer plays (MP4 family) or the remuxer turns into HLS (Matroska / WebM).
    public static let modernVideoExtensions: Set<String> = ["mkv", "mk3d", "mp4", "m4v", "mov", "webm"]

    /// Containers only VLC handles (no remux, no AVPlayer): no native HDR / Atmos path.
    /// (".EVO" HD-DVD streams are left out: "EVO" is also a release group.)
    public static let legacyVideoExtensions: Set<String> = [
        "avi", "divx", "ts", "m2ts", "mts", "m2t", "tp", "trp", "wmv", "wm", "asf", "flv", "f4v",
        "mpg", "mpeg", "mpe", "m1v", "m2v", "mpv", "vob", "ogm", "ogv", "rm", "rmvb", "rv",
        "3gp", "3g2", "nut", "mxf",
    ]

    /// Disc images, archives and executables: nothing a streaming player can open.
    public static let unplayableExtensions: Set<String> = [
        "iso", "img", "bin", "cue", "nrg", "mdf", "mds", "ccd",
        "rar", "zip", "7z", "tar", "001",
        "exe", "msi", "bat", "cmd", "lnk", "apk", "dmg", "pkg", "jar", "vbs",
    ]

    /// Files that are never the video payload of a release.
    static let nonVideoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "webp", "nfo", "txt", "srt", "sub", "idx", "ass", "ssa", "vtt",
        "sfv", "md5", "url", "htm", "html", "pdf", "exe", "lnk", "torrent",
    ]

    /// Lower-cased path extension of a file name or path ("" when none).
    static func pathExtension(_ name: String) -> String {
        return (name as NSString).pathExtension.lowercased()
    }

    /// The extension when it names a video container we know, else nil
    /// ("Movie.2020.DDP5.1" has no container — its "extension" is "1").
    public static func videoContainerExtension(of name: String) -> String? {
        let ext = pathExtension(name)
        return modernVideoExtensions.contains(ext) || legacyVideoExtensions.contains(ext) ? ext : nil
    }

    /// True for a file name / path with a known video container extension.
    public static func isVideoFile(_ name: String) -> Bool {
        return videoContainerExtension(of: name) != nil
    }

    /// True for a file name with a known non-video extension (artwork, NFO,
    /// subtitles, executables…). Unknown extensions are NOT non-video.
    static func isNonVideoFile(_ name: String) -> Bool {
        let ext = pathExtension(name)
        return nonVideoExtensions.contains(ext) || unplayableExtensions.contains(ext)
    }

    /// Sample / trailer clips shipped next to the real payload.
    static func looksLikeSample(_ name: String) -> Bool {
        let tokens = Set(self.tokens((name as NSString).lastPathComponent))
        return tokens.contains("sample") || tokens.contains("trailer")
    }

    static func isUnplayableExtension(_ ext: String) -> Bool {
        if unplayableExtensions.contains(ext) { return true }
        // Split RAR volumes: .r00 … .r99
        let scalars = Array(ext.unicodeScalars)
        return scalars.count == 3 && scalars[0] == "r"
            && scalars[1...].allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
    }

    /// A Blu-ray / DVD stream file inside a disc structure: `00800.m2ts`, `VTS_01_1.VOB`.
    static func isDiscStreamFile(_ name: String) -> Bool {
        let file = (name as NSString).lastPathComponent.lowercased()
        let ext = pathExtension(file)
        let stem = (file as NSString).deletingPathExtension
        if ["m2ts", "mts", "m2t"].contains(ext) {
            return stem.count == 5 && stem.allSatisfy { $0.isASCII && $0.isNumber }
        }
        if ext == "vob" {
            return stem.hasPrefix("vts_") || stem.hasPrefix("video_ts")
        }
        return false
    }

    /// Tokens of an encode (as opposed to an untouched disc).
    static func hasEncodeMarker(_ t: [String]) -> Bool {
        for (i, token) in t.enumerated() {
            let next = i + 1 < t.count ? t[i + 1] : ""
            if token == "x" && (next == "264" || next == "265") { return true }
            if ["xvid", "divx", "remux", "bdremux", "bdrip", "brrip", "webrip", "dvdrip", "hdrip"].contains(token) { return true }
        }
        return false
    }

    /// Full-disc / disc-image markers: BDMV, VIDEO_TS, BD25/50/66/100, ISO,
    /// DVD5/DVD9/DVD-R, "COMPLETE (UHD) BLURAY", "DISC1".
    static func hasDiscMarker(_ t: [String]) -> Bool {
        func at(_ i: Int) -> String { return i >= 0 && i < t.count ? t[i] : "" }
        let isEncode = hasEncodeMarker(t)
        for i in t.indices {
            let token = t[i], next = at(i + 1), next2 = at(i + 2)
            switch token {
            case "bdmv", "iso", "bdiso", "dvdr", "dvdiso":
                return true
            case "video" where next == "ts":
                return true
            case "bd" where ["25", "50", "66", "100"].contains(next):
                return true
            case "dvd" where (next == "5" || next == "9") && Int(next2) == nil:
                return true
            case "dvd" where next == "r":
                return true
            case "complete" where !isEncode:
                // "COMPLETE BLURAY", "COMPLETE UHD BLURAY", "COMPLETE.2160p.UHD.BLURAY":
                // a resolution / "UHD" may come between.
                var j = i + 1
                while true {
                    if at(j) == "uhd" || at(j) == "4k" { j += 1; continue }
                    if let number = Int(at(j)), [1080, 2160].contains(number), at(j + 1) == "p" { j += 2; continue }
                    break
                }
                if at(j) == "bluray" || (at(j) == "blu" && at(j + 1) == "ray") { return true }
            case "disc", "disk":
                // "Disc1", "Disc 2" — not "The.Disc.2020" (a year).
                if !isEncode, let number = Int(next), number < 100 { return true }
            default:
                break
            }
        }
        return false
    }

    /// True when a release can't be streamed at all: a disc image or archive
    /// (`.iso`, `.img`, `.rar`, `.zip`, `.7z`, `.r00`, `.001`…), a full
    /// Blu-ray / DVD structure (BDMV, VIDEO_TS, BD25…BD100, "COMPLETE BLURAY",
    /// "DISC1"… when no video file is named), or a disc stream file such as
    /// `BDMV/STREAM/00800.m2ts`. A named `.mkv` / `.mp4` / `.avi`… is always
    /// considered playable, whatever the torrent title says.
    public static func isLikelyUnplayable(fileName: String?, title: String?) -> Bool {
        let file = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ext = pathExtension(file)
        if isUnplayableExtension(ext) { return true }
        let markers = tokens(file) + tokens(title ?? "")
        if modernVideoExtensions.contains(ext) || legacyVideoExtensions.contains(ext) {
            // A real video file: only a disc stream file is suspect.
            guard ["m2ts", "mts", "m2t", "vob"].contains(ext) else { return false }
            return isDiscStreamFile(file) || hasDiscMarker(markers)
        }
        return hasDiscMarker(markers)
    }

    // MARK: Episode coverage

    /// What a release / torrent name covers, relative to one episode of a series.
    public enum EpisodeScope: Equatable {
        /// Exactly the requested episode ("Show.S03E05.1080p…", "Show 3x05",
        /// "Show - Temporada 3 [HDTV][Cap.305]").
        case requestedEpisode
        /// The requested episode and one more ("S03E05E06", "S03E05-06"): a
        /// double episode, in one file or in two.
        case multiEpisode
        /// A season, several seasons or a whole series ("S03", "S01-S05",
        /// "Season 3", "Complete", "Сезон: 3"), or a range of 3+ episodes
        /// ("S03E01-E10", "[Cap.301_310]").
        case pack
        /// Names other episode(s) only, a single one or a double.
        case otherEpisode
        /// No season / episode marker at all ("[Group] Show - 05 [1080p]").
        case unknown
    }

    private struct EpisodeNumber: Hashable {
        let season: Int
        let episode: Int
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        return try! NSRegularExpression(pattern: pattern)
    }

    // Episode markers, bounded by non-alphanumerics ("dts5", "x264" and
    // "1920x1080" never match).
    private static let sxxEyyMarker = regex("(?<![\\p{L}\\p{N}])s(\\d{1,2})[ ._-]?ep?(\\d{1,3})(?!\\d)")
    private static let nxNNMarker = regex("(?<![\\p{L}\\p{N}])(\\d{1,2})x(\\d{2,3})(?![\\p{L}\\p{N}])")
    /// Spanish sites number episodes "Cap.SEE": Cap.305 = S03E05, Cap.1012 = S10E12.
    private static let capMarker = regex("(?<![\\p{L}\\p{N}])cap[ ._]?(\\d{3,4})(?!\\d)")
    /// Anime style "Show S2 - 05", "Show Season 2 - 05".
    private static let animeMarker = regex("(?<![\\p{L}\\p{N}])(?:s|season[ ._]?|saison[ ._]?)(\\d{1,2})[ ._]+-[ ._]+(\\d{2,3})(?![\\p{L}\\p{N}])")
    // Continuations, matched right after a marker: another episode ("E06",
    // "+E06", "-E06": a range with "-" / "~"), a range end ("-07", "~10",
    // "-S01E07"), "-3x06" / "-06", "_310".
    private static let extraEpisode = regex("(?:[ ._]*([-~&+])[ ._]*|[ ._]?)e(\\d{1,3})(?!\\d)")
    private static let rangeEnd = regex("[ ._]*[-~][ ._]*(?:s(\\d{1,2})[ ._-]?e)?(\\d{1,3})(?![\\dpi])(?!bit)")
    /// What may follow a range end written " - N" (spaces, no "E" / "SxxE"),
    /// in a torrent's name: its end, a bracket, a technical token. Not a
    /// word: "S02E01 - 8 00 A.M." (24), "S01E02 - 15 Million Merits" are
    /// episode titles. In a file's name never (`coverage`): "S01E01 - 33.mkv"
    /// is Battlestar Galactica's "33".
    private static let spacedRangeEndBoundary = regex("\\s*$|\\s*[\\[(]|[\\s._]+(?:\\d{3,4}p|web|webrip|web-dl|hdtv|bluray|blu-ray|bdrip|brrip|dvdrip|x26[45]|h\\.?26[45]|hevc|xvid|complete|batch|multi|vostfr)(?![\\p{L}\\p{N}])")
    private static let nxNNContinuation = regex("[ ._]*([-~&])[ ._]*(?:(\\d{1,2})x)?(\\d{2,3})(?![\\p{L}\\p{N}])")
    private static let capContinuation = regex("[ ._]*[-_~][ ._]*(?:cap[ ._]?)?(\\d{3,4})(?!\\d)")
    private static let animeContinuation = regex("[ ._]*[-~][ ._]*(\\d{2,3})(?![\\p{L}\\p{N}])")
    /// A season without an episode: "S03", "S01-S05", "[S01-05]".
    private static let seasonMarker = regex("(?<![\\p{L}\\p{N}])s(\\d{1,2})(?!\\d)")

    /// "Season" in the languages torrent names use (tokens, lower-cased).
    static let seasonWords: Set<String> = [
        "season", "seasons", "saison", "saisons", "temporada", "temporadas", "stagione", "stagioni",
        "staffel", "staffeln", "seizoen", "säsong", "sezon", "sezony", "сезон", "сезона", "сезоны",
    ]
    /// Singular "episode" words ("Season 3 Episode 5", "Temporada 3 Capitulo 5").
    static let episodeWords: Set<String> = [
        "episode", "épisode", "episodio", "folge", "ep", "capitulo", "capítulo", "cap", "серия",
    ]
    /// Whole-series / whole-season words ("Complete", "Intégrale", "Серии" = episodes).
    static let packWords: Set<String> = [
        "complete", "completa", "completo", "completas", "completos", "complet", "complète",
        "integrale", "intégrale", "komplett", "серии",
    ]

    /// Season / episode coverage of a release or torrent name for one
    /// requested episode (season / episode numbers as on TVDB / IMDb).
    ///
    /// Episode markers: `SxxEyy` (any padding, "S03.E05", "S03 E05"), double
    /// episodes and ranges ("S03E05E06", "S03E05-E06", "S03E01-10",
    /// "S03E01~E10", "S01E05-S02E03"), `NxNN` ("3x05", "3x05-06"), Spanish
    /// "Cap.SEE" ("[Cap.305]", "[Cap.301_310]"), anime "S2 - 05" / "Season 2 -
    /// 05", and "Season 3 Episode 5". Without an episode marker, a season marker
    /// ("S03", "S01-S05"), a season word ("Season", "Saison", "Temporada",
    /// "Stagione", "Staffel", "Sezon", "Сезон"…) or a series word
    /// ("Complete", "Intégrale"…) makes it a pack. An exact single-episode
    /// marker wins over pack words ("Westworld - Temporada 4 [Cap.408]" is
    /// S04E08 alone).
    public static func episodeScope(of name: String, season: Int, episode: Int) -> EpisodeScope {
        let (covered, spansSeasons, t, text) = coverage(of: name)
        let all = NSRange(location: 0, length: (text as NSString).length)
        let requested = EpisodeNumber(season: season, episode: episode)
        if covered.contains(requested) {
            switch covered.count {
            case 1: return .requestedEpisode
            case 2 where !spansSeasons: return .multiEpisode
            default: return .pack
            }
        }
        if !covered.isEmpty {
            return covered.count >= 3 || spansSeasons ? .pack : .otherEpisode
        }
        let isPack = seasonMarker.firstMatch(in: text, range: all) != nil
            || t.contains(where: { seasonWords.contains($0) || packWords.contains($0) })
        return isPack ? .pack : .unknown
    }

    /// Whether a name's own episode markers include that episode: a single
    /// episode, a double, or a range ("S01E01-E03" holds S01E03).
    static func namesEpisode(_ name: String, season: Int, episode: Int) -> Bool {
        return coverage(of: name).covered.contains(EpisodeNumber(season: season, episode: episode))
    }

    /// The one season a pack's name (or folder) names — "Show.S01.1080p",
    /// "Show (Season 1)", "Saison 2" — without any episode marker; nil for
    /// none, several ("S01-S03", "[S01-05]") or an episode.
    static func singleSeason(of name: String) -> Int? {
        let (covered, _, t, text) = coverage(of: name)
        guard covered.isEmpty else { return nil }
        let ns = text as NSString
        var seasons = Set<Int>()
        for match in seasonMarker.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let s = Int(ns.substring(with: match.range(at: 1))) else { continue }
            seasons.insert(s)
            // "S01-05", "S01~S05": a range of seasons.
            let after = NSMaxRange(match.range)
            if after < ns.length, seasonRangeContinuation.firstMatch(in: text, options: .anchored,
                                                                      range: NSRange(location: after, length: ns.length - after)) != nil {
                return nil
            }
        }
        for i in t.indices where seasonWords.contains(t[i]) && i + 1 < t.count {
            if let s = Int(t[i + 1]), t[i + 1].count <= 2 { seasons.insert(s) }
        }
        return seasons.count == 1 ? seasons.first : nil
    }
    private static let seasonRangeContinuation = regex("[ ._]*[-~][ ._]*s?\\d{1,2}(?!\\d)")

    /// The episode number a file names on its own, inside a folder or a
    /// torrent that names its season (`singleSeason`): "Episode 02",
    /// "E02", "EP02", "Серия 02", "第02集", a leading "02 - Title", a
    /// dash-delimited "Show - 02 [1080p]", "Part 2", "2of6", or scene
    /// numbering "102" / "1012" (season × 100 + episode) for `season`. Nil
    /// when there is none. `title`: the pack's own name (its folder or the
    /// torrent's): a leading number that is the show's ("24 - 05 - Title",
    /// "1923 - 05") is not the episode's (`WantedFile.choice` passes none
    /// when the files' leading numbers differ: "9-1-1 Season 3/09 - Title").
    static func episodeNumberInSeason(_ leaf: String, season: Int, title: String? = nil) -> Int? {
        var text = leaf.lowercased()
        if videoContainerExtension(of: text) != nil, let dot = text.lastIndex(of: ".") { text = String(text[..<dot]) }
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        func first(_ pattern: NSRegularExpression, in range: NSRange) -> Int? {
            guard let match = pattern.firstMatch(in: text, range: range), let e = Int(ns.substring(with: match.range(at: 1))), e > 0 else { return nil }
            return e
        }
        if let e = first(episodeOnlyMarker, in: all) { return e }
        if let lead = leadingEpisodeNumber.firstMatch(in: text, range: all), let e = Int(ns.substring(with: lead.range(at: 1))), e > 0 {
            // The show's own number ("24 - 05 - Title" in "24 Season 1"):
            // the episode's comes after it.
            var showNumber: Int?
            if let name = title?.lowercased(), let match = leadingNumber.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) {
                showNumber = Int((name as NSString).substring(with: match.range(at: 1)))
            }
            guard showNumber == e else { return e }
            let after = NSMaxRange(lead.range(at: 1))
            let rest = NSRange(location: after, length: ns.length - after)
            return first(dashEpisodeNumber, in: rest) ?? first(leadingAfterShow, in: rest)
        }
        for pattern in [dashEpisodeNumber, partNumber, partOfNumber, chineseEpisode] {
            if let e = first(pattern, in: all) { return e }
        }
        for match in sceneNumber.matches(in: text, range: all) {
            let digits = ns.substring(with: match.range(at: 1))
            guard let code = Int(digits), code / 100 == season, code % 100 > 0,
                  digits.count == (season < 10 ? 3 : 4) else { continue }
            return code % 100
        }
        return nil
    }
    /// A file's leading number as `episodeNumberInSeason` reads it ("09 - Title.mkv": 9,
    /// "24 - 05 - Title.avi": 24); nil for none.
    static func leadingNumber(ofLeaf leaf: String) -> Int? {
        var text = leaf.lowercased()
        if videoContainerExtension(of: text) != nil, let dot = text.lastIndex(of: ".") { text = String(text[..<dot]) }
        let ns = text as NSString
        guard let match = leadingEpisodeNumber.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Int(ns.substring(with: match.range(at: 1)))
    }
    /// "Episode 2", "Épisode 02", "E02", "EP02", "Ep.2", "Серия 02" (not "1080p", "x264": bounded).
    private static let episodeOnlyMarker = regex("(?<![\\p{L}\\p{N}])(?:episode|épisode|episodio|folge|серия|ep|e)[ ._-]?(\\d{1,3})(?![\\p{L}\\p{N}])")
    /// "02 - Title", "02. Title", "02_Title", "02" alone.
    private static let leadingEpisodeNumber = regex("^\\s*(\\d{1,3})(?:\\s*[-._]|\\s|$)")
    /// A name's leading number, up to 4 digits ("24 Season 1", "1923 S01").
    private static let leadingNumber = regex("^\\s*(\\d{1,4})(?![\\p{L}\\p{N}])")
    /// After the show's number: " - 05 - Title", ".05.Title".
    private static let leadingAfterShow = regex("^\\s*[-._]\\s*(\\d{1,3})(?:\\s*[-._]|\\s|$)")
    /// "[Group] Show - 05 [1080p]", "Show - 05 - Title", "Show - 05v2": a
    /// number between " - " and a space, a bracket, a dot or the end (not
    /// "- 1080p", "- 720p", nor a recap's "- 06.5").
    private static let dashEpisodeNumber = regex("(?:^|\\s)-\\s+(\\d{1,3})(?:v\\d)?(?=\\s|[\\[(]|\\.(?!\\d)|$)")
    /// "Chernobyl.Part.3", "Part 3".
    private static let partNumber = regex("(?<![\\p{L}\\p{N}])part[ ._]?(\\d{1,2})(?![\\p{L}\\p{N}])")
    /// "Planet.Earth.II.3of6", "3 of 6".
    private static let partOfNumber = regex("(?<![\\p{L}\\p{N}])(\\d{1,2})[ ._]?of[ ._]?\\d{1,2}(?![\\p{L}\\p{N}])")
    /// "第03集", "第3話", "第03话".
    private static let chineseEpisode = regex("第\\s*(\\d{1,3})\\s*[集話话]")

    /// A pack that names no season at all, only its episodes or itself as a
    /// whole: "[Group] Show (01-28) [Batch]", "Show 01-12 [1080p]",
    /// "Chernobyl.Complete.1080p" (a miniseries). Its files numbered on their
    /// own ("Show - 05", "Part.3") are season 1's.
    static func impliesSeasonOne(_ name: String) -> Bool {
        let (covered, _, t, text) = coverage(of: name)
        guard covered.isEmpty, singleSeason(of: name) == nil,
              seasonMarker.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) == nil,
              !t.contains(where: { seasonWords.contains($0) }) else { return false }
        if t.contains("batch") || t.contains(where: { packWords.contains($0) }) { return true }
        let ns = text as NSString
        for match in movieRange.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let a = Int(ns.substring(with: match.range(at: 1))), let b = Int(ns.substring(with: match.range(at: 2))), a == 1, b > a { return true }
        }
        return false
    }

    /// The one episode a name's markers cover ("Show S03 - 50", "S02E25"),
    /// nil for none or several.
    static func singleEpisode(of name: String) -> (season: Int, episode: Int)? {
        let covered = coverage(of: name).covered
        guard covered.count == 1, let only = covered.first else { return nil }
        return (only.season, only.episode)
    }
    /// "show.102.hdtv": three or four digits between non-alphanumerics.
    private static let sceneNumber = regex("(?<![\\p{L}\\p{N}])(\\d{3,4})(?![\\p{L}\\p{N}])")

    /// The episodes a name's markers cover, whether they span seasons, its
    /// tokens and its lower-cased text.
    private static func coverage(of name: String) -> (covered: Set<EpisodeNumber>, spansSeasons: Bool, tokens: [String], text: String) {
        let text = name.lowercased()
        let ns = text as NSString
        let isFileName = videoContainerExtension(of: text) != nil
        var covered = Set<EpisodeNumber>()
        var spansSeasons = false

        func number(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
        }
        func string(_ match: NSTextCheckingResult, _ group: Int) -> String {
            let range = match.range(at: group)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
        func add(_ season: Int, _ first: Int, through last: Int? = nil) {
            let last = max(first, min(last ?? first, first + 200))
            for episode in first...last { covered.insert(EpisodeNumber(season: season, episode: episode)) }
        }
        /// The continuation `pattern` matches right after a marker ending at `position`.
        func continuation(_ pattern: NSRegularExpression, at position: Int) -> NSTextCheckingResult? {
            guard position < ns.length else { return nil }
            let rest = NSRange(location: position, length: ns.length - position)
            return pattern.firstMatch(in: text, options: .anchored, range: rest)
        }
        let all = NSRange(location: 0, length: ns.length)
        /// A range end "-07", "-S01E07", " - S01E07"; " - 07" (spaced, no
        /// "E") only in a torrent's name, before its end, a bracket or a
        /// technical token (`spacedRangeEndBoundary`).
        func isRangeEnd(_ match: NSTextCheckingResult) -> Bool {
            guard string(match, 0).contains(" "), match.range(at: 1).location == NSNotFound else { return true }
            guard !isFileName else { return false }
            let after = NSMaxRange(match.range)
            return spacedRangeEndBoundary.firstMatch(in: text, options: .anchored,
                                                     range: NSRange(location: after, length: ns.length - after)) != nil
        }

        for match in sxxEyyMarker.matches(in: text, range: all) {
            guard let s = number(match, 1), let first = number(match, 2) else { continue }
            add(s, first)
            var last = first, position = NSMaxRange(match.range)
            while true {
                if let next = continuation(extraEpisode, at: position), let e = number(next, 2) {
                    let joiner = string(next, 1)
                    if joiner == "-" || joiner == "~" { add(s, last, through: e) } else { add(s, e) }
                    last = e
                    position = NSMaxRange(next.range)
                } else if let next = continuation(rangeEnd, at: position), let e = number(next, 2),
                          isRangeEnd(next) {
                    if let endSeason = number(next, 1), endSeason != s {
                        spansSeasons = true
                        add(endSeason, e)
                    } else {
                        add(s, last, through: e)
                    }
                    last = e
                    position = NSMaxRange(next.range)
                } else {
                    break
                }
            }
        }
        for match in nxNNMarker.matches(in: text, range: all) {
            guard let s = number(match, 1), let first = number(match, 2), first != 264, first != 265 else { continue }
            add(s, first)
            var last = first, position = NSMaxRange(match.range)
            while let next = continuation(nxNNContinuation, at: position), let e = number(next, 3) {
                if let endSeason = number(next, 2), endSeason != s {
                    spansSeasons = true
                    add(endSeason, e)
                } else if string(next, 1) == "&" {
                    add(s, e)
                } else {
                    add(s, last, through: e)
                }
                last = e
                position = NSMaxRange(next.range)
            }
        }
        for match in capMarker.matches(in: text, range: all) {
            guard let code = number(match, 1) else { continue }
            let s = code / 100, first = code % 100
            add(s, first)
            var last = first, position = NSMaxRange(match.range)
            while let next = continuation(capContinuation, at: position), let endCode = number(next, 1) {
                if endCode / 100 != s {
                    spansSeasons = true
                    add(endCode / 100, endCode % 100)
                } else {
                    add(s, last, through: endCode % 100)
                }
                last = endCode % 100
                position = NSMaxRange(next.range)
            }
        }
        for match in animeMarker.matches(in: text, range: all) {
            guard let s = number(match, 1), let first = number(match, 2), ![480, 576, 720].contains(first) else { continue }
            add(s, first)
            var last = first, position = NSMaxRange(match.range)
            while let next = continuation(animeContinuation, at: position), let e = number(next, 1) {
                add(s, last, through: e)
                last = e
                position = NSMaxRange(next.range)
            }
        }
        let t = tokens(text)
        // "Season 3 Episode 5", "Season.1.E02", "Saison 1 EP02".
        for i in t.indices where seasonWords.contains(t[i]) && i + 3 < t.count {
            if let s = Int(t[i + 1]), episodeWords.contains(t[i + 2]) || t[i + 2] == "e", let e = Int(t[i + 3]), t[i + 3].count <= 3 {
                add(s, e)
            }
        }

        return (covered, spansSeasons, t, text)
    }

    /// True when a release or file name covers more than one episode: a
    /// season / series pack ("Show.S03", "Season 3", "Complete", "S01-S05",
    /// "Temporada 1") or an episode range / double episode ("S03E01-E10",
    /// "S03E05E06", "3x05-06", "[Cap.301_310]"). A single episode, a name
    /// without any marker (movies, "[Group] Show - 05") and "Season 3
    /// Episode 5" are false. Judged against the name's own first episode
    /// marker (`episodeScope`), so it needs no requested episode.
    public static func coversSeveralEpisodes(_ name: String) -> Bool {
        let text = name.lowercased()
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var first: (location: Int, season: Int, episode: Int)?
        func consider(_ pattern: NSRegularExpression, decode: (Int, Int) -> (Int, Int)?) {
            guard let match = pattern.firstMatch(in: text, range: all),
                  first == nil || match.range.location < first!.location else { return }
            func number(_ group: Int) -> Int? {
                guard group < match.numberOfRanges else { return nil }
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
            }
            guard let a = number(1), let decoded = decode(a, number(2) ?? -1) else { return }
            first = (match.range.location, decoded.0, decoded.1)
        }
        consider(sxxEyyMarker) { s, e in e >= 0 ? (s, e) : nil }
        consider(nxNNMarker) { s, e in e >= 0 && e != 264 && e != 265 ? (s, e) : nil }
        consider(capMarker) { code, _ in (code / 100, code % 100) }
        if let first = first {
            switch episodeScope(of: name, season: first.season, episode: first.episode) {
            case .pack, .multiEpisode: return true
            case .requestedEpisode, .otherEpisode, .unknown: return false
            }
        }
        return episodeScope(of: name, season: -1, episode: -1) == .pack || isMovieCollection(name)
    }

    /// Several films in one torrent: "Trilogy", "Trilogie", "Quadrilogy",
    /// "Anthology", "Collection" (not "Criterion Collection", a single film's
    /// edition), "Box Set", or a numbered range ("Harry Potter 1-8",
    /// "Saw 1 - 7"). Not "Saga" alone ("The Twilight Saga: New Moon" is one
    /// film). Only judged where no episode marker decided (see
    /// `coversSeveralEpisodes`); a miss only leaves a bitrate unknown.
    static func isMovieCollection(_ name: String) -> Bool {
        let t = tokens(name.lowercased())
        for (i, token) in t.enumerated() {
            if collectionWords.contains(token) { return true }
            if token == "collection", i == 0 || t[i - 1] != "criterion" { return true }
            if token == "boxset" || (token == "box" && i + 1 < t.count && t[i + 1] == "set") { return true }
        }
        let text = name as NSString
        for match in movieRange.matches(in: name, range: NSRange(location: 0, length: text.length)) {
            if let a = Int(text.substring(with: match.range(at: 1))), let b = Int(text.substring(with: match.range(at: 2))),
               a >= 1, b > a, b <= 30 { return true }
        }
        return false
    }

    private static let collectionWords: Set<String> = [
        "duology", "dilogy", "trilogy", "trilogie", "trilogia", "trilogía", "quadrilogy", "quadrilogie",
        "tetralogy", "tetralogia", "pentalogy", "hexalogy", "anthology", "anthologie", "antologia", "antología",
    ]
    /// "1-8", "1 - 7", "1~3": a range of film numbers between non-alphanumerics
    /// ("DDP5.1-FGT", "H.264-2HD", "2019-2020" never match).
    private static let movieRange = regex("(?<![\\p{L}\\p{N}.])(\\d{1,2}) ?[-~] ?(\\d{1,2})(?![\\p{L}\\p{N}])")
}

/// Magnet-link helpers (BEP 9 `dn`, BEP 53 `so`).
public enum MagnetLink {

    /// Raw (still percent-encoded) values of every `key=` query parameter
    /// of a magnet link, in order (case-insensitive key).
    static func rawParameters(_ key: String, in magnet: String) -> [Substring] {
        guard magnet.lowercased().hasPrefix("magnet:"),
              let query = magnet.firstIndex(of: "?") else { return [] }
        let wanted = key.lowercased()
        return magnet[magnet.index(after: query)...]
            .split(separator: "&")
            .compactMap { pair -> Substring? in
                guard let equals = pair.firstIndex(of: "="),
                      pair[..<equals].lowercased() == wanted else { return nil }
                return pair[pair.index(after: equals)...]
            }
    }

    /// A source's identity across providers (their magnets name the torrent
    /// and list trackers their own way): the info-hash (`xt=urn:btih:`),
    /// lower-cased; the link itself when it has none (a .torrent URL).
    public static func sourceKey(of link: String) -> String {
        guard let range = link.range(of: "btih:", options: .caseInsensitive) else { return link }
        let hash = link[range.upperBound...].prefix { $0 != "&" }.lowercased()
        return hash.isEmpty ? link : hash
    }

    /// The display name (`dn=`), with "+" read as a space and percent-decoded.
    /// For single-file torrents it is the payload file name.
    public static func displayName(of magnet: String) -> String? {
        guard let raw = rawParameters("dn", in: magnet).first else { return nil }
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        let name = spaced.removingPercentEncoding ?? spaced
        return name.isEmpty ? nil : name
    }

    /// The file index selected by a BEP 53 `so=` parameter ("so=3",
    /// "so=0,2,4-6", percent-encoded commas accepted): the lowest index of
    /// the first well-formed selection, nil when absent or invalid. Like
    /// libtorrent's own parser, a value with anything but digits, "-" and ","
    /// is ignored as a whole.
    public static func selectedFileIndex(of magnet: String) -> Int? {
        for raw in rawParameters("so", in: magnet) {
            let value = raw.removingPercentEncoding ?? String(raw)
            guard value.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || $0 == "-" || $0 == "," }) else { continue }
            var lowest: Int?
            for entry in value.split(separator: ",") {
                let first: Int?
                if let dash = entry.firstIndex(of: "-") {
                    let lower = Int(entry[..<dash]), upper = Int(entry[entry.index(after: dash)...])
                    if let lower = lower, let upper = upper, lower >= 0, upper >= lower { first = lower } else { first = nil }
                } else if let index = Int(entry), index >= 0 {
                    first = index
                } else {
                    first = nil
                }
                if let first = first { lowest = min(lowest ?? first, first) }
            }
            if let lowest = lowest { return lowest }
        }
        return nil
    }

    /// Index of the file to stream from a multi-file torrent, given its file
    /// names in torrent order (and their sizes when the streamer provides
    /// them): the `preferredIndex` (a magnet's `so=`) when it is in range and
    /// not obviously artwork / text / subtitles; otherwise the largest video
    /// file when sizes are known, else the first video file that isn't a
    /// sample; otherwise 0.
    public static func fileIndexToStream(fileNames: [String], fileSizes: [Int64]? = nil, preferredIndex: Int?) -> Int {
        if let index = preferredIndex, fileNames.indices.contains(index), !ReleaseName.isNonVideoFile(fileNames[index]) {
            return index
        }
        let videos = fileNames.indices.filter { ReleaseName.isVideoFile(fileNames[$0]) }
        if let sizes = fileSizes, sizes.count == fileNames.count, !fileNames.isEmpty {
            let pool = videos.isEmpty ? Array(fileNames.indices) : videos
            return pool.max(by: { sizes[$0] < sizes[$1] }) ?? 0
        }
        if let index = videos.first(where: { !ReleaseName.looksLikeSample(fileNames[$0]) }) ?? videos.first {
            return index
        }
        return 0
    }
}

/// The file a stream wants from a multi-file torrent: for an episode, its
/// season and number, and its file name when the source gives one apart
/// from the magnet (Time4Popcorn's `file`: its episode magnets often name a
/// whole season pack and carry no BEP 53 `so=`); for a movie, only such a
/// file name. `choice` picks that file among the torrent's files.
public struct WantedFile: Equatable, Sendable, CustomStringConvertible {
    /// The episode's season (0 = specials) and number; nil for a movie.
    public let season: Int?
    public let episode: Int?
    /// The file's own name as the source gives it (its last path component).
    public let fileName: String?

    /// Nil when there is nothing to pick a file by: no file name, and no
    /// season ≥ 0 with an episode ≥ 1 (an `Episode` without numbers has -1).
    public init?(season: Int? = nil, episode: Int? = nil, fileName: String? = nil) {
        let name = fileName.map(WantedFile.leafName)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let numbered = (season ?? -1) >= 0 && (episode ?? 0) > 0
        guard numbered || !(name ?? "").isEmpty else { return nil }
        self.season = numbered ? season : nil
        self.episode = numbered ? episode : nil
        self.fileName = (name ?? "").isEmpty ? nil : name
    }

    public var description: String {
        let numbers = season.flatMap { s in episode.map { String(format: "S%02dE%02d", s, $0) } }
        return [numbers, fileName.map { "«\($0)»" }].compactMap { $0 }.joined(separator: " ")
    }

    /// Which file of a torrent to stream.
    public enum Choice: Equatable {
        /// This file (index in torrent order).
        case file(Int)
        /// None: a pack without the wanted episode (never another episode).
        case notInTorrent
        /// No opinion: the usual rule (the magnet's `so=`, else the largest
        /// video file).
        case usualRule
    }

    /// The file to stream among a torrent's `fileNames` (and `fileSizes`
    /// when known), given the magnet's `so=` (`preferredIndex`) and the
    /// torrent's display name (`torrentName`, the magnet's `dn`). A
    /// single-file torrent always follows the usual rule. Otherwise:
    /// 1. the file the source names (`fileName`), compared on letters and
    ///    digits only, without a video extension ("Show S02E03 1080p WEB-DL
    ///    DDP5 1.mkv" is "Show.S02E03.1080p.WEB-DL.DDP5.1.mkv") — unless that
    ///    file names another episode;
    /// 2. for an episode, the `so=` file, unless it names another episode;
    /// 3. the video file named after the episode (`ReleaseName.episodeScope`:
    ///    "S03E05", "S03EP05", "3x05", "Cap.305", "S3 - 05", "Season 3 E05"…;
    ///    samples left out), else a double episode holding it ("S03E04E05"),
    ///    else a range holding it ("S03E01-E06"); the largest of several;
    /// 4. in a folder or torrent named after one season (`singleSeason`:
    ///    "Show.S03.1080p/", "Season 3"), a file numbered on its own for that
    ///    season: "Episode 05", "E05", "05 - Title", "305" (a pack that names
    ///    no season, "[Group] Show (01-28) [Batch]", is season 1 for its
    ///    files at the top or all in one folder; extras never count; a later
    ///    season whose numbers start above 1 is numbered absolutely: none);
    /// 5. not found: with one video file at most, a single-episode torrent
    ///    (its sample, subtitles…), the usual rule as before; with several,
    ///    a pack when one of them names an episode or a season, or the
    ///    torrent's name covers several episodes: `.notInTorrent`. Video
    ///    files without any marker (absolute numbering "Show - 013") and a
    ///    torrent name that doesn't say pack: the usual rule.
    /// A sample is a file called "sample" / "trailer" (or in a Sample
    /// folder) that is much smaller than the largest video file (under a
    /// quarter of it; without sizes: unless every video file says so) —
    /// never when most video files say so: the word is then the show's
    /// title, "Trailer Park Boys".
    /// A movie (no numbers) stops after 1.
    public func choice(fileNames: [String], fileSizes: [Int64]? = nil, preferredIndex: Int? = nil,
                       torrentName: String? = nil) -> Choice {
        guard fileNames.count > 1 else { return .usualRule }
        let sizes = fileSizes.flatMap { $0.count == fileNames.count ? $0 : nil }
        /// The largest of `indices` (the first one on a tie or without sizes).
        func largest(_ indices: [Int]) -> Int {
            guard let sizes = sizes else { return indices[0] }
            return indices.max { sizes[$0] < sizes[$1] } ?? indices[0]
        }
        func scope(_ index: Int) -> ReleaseName.EpisodeScope? {
            guard let season = season, let episode = episode else { return nil }
            return ReleaseName.episodeScope(of: WantedFile.leafName(fileNames[index]), season: season, episode: episode)
        }

        let allVideos = fileNames.indices.filter { ReleaseName.isVideoFile(fileNames[$0]) }
        let calledSample = Set(allVideos.filter { WantedFile.isCalledSample(fileNames[$0]) })
        let largestVideo = sizes.flatMap { sizes in allVideos.map { sizes[$0] }.max() }
        func isSample(_ index: Int) -> Bool {
            guard calledSample.contains(index) else { return false }
            // Most video files say it: the word is the show's ("Trailer Park Boys"), even in a
            // pack whose SD seasons are a tenth of its 1080p ones.
            if calledSample.count * 2 > allVideos.count { return false }
            if let sizes = sizes, let largestVideo = largestVideo, largestVideo > 0 { return sizes[index] * 4 < largestVideo }
            return calledSample.count < allVideos.count
        }

        if let fileName = fileName {
            // Never its sample: Time4Popcorn sometimes names an episode's
            // "Sample/sample-….avi" (8 MB of it) as its file.
            let key = WantedFile.comparableName(fileName)
            let named = key.isEmpty ? [] : fileNames.indices.filter {
                WantedFile.comparableName(fileNames[$0]) == key
                    && !ReleaseName.isNonVideoFile(fileNames[$0]) && scope($0) != .otherEpisode && !isSample($0)
            }
            if !named.isEmpty { return .file(largest(named)) }
        }
        guard let season = season, let episode = episode else { return .usualRule }

        if let preferred = preferredIndex, fileNames.indices.contains(preferred),
           !ReleaseName.isNonVideoFile(fileNames[preferred]) {
            if scope(preferred) != .otherEpisode { return .file(preferred) }
            if WantedFile.continuesAbsoluteNumbering(preferred, season: season, episode: episode, fileNames: fileNames) {
                return .file(preferred)
            }
        }

        let videos = allVideos.filter { !isSample($0) }
        let scopes = videos.map { scope($0) ?? .unknown }
        for wanted in [ReleaseName.EpisodeScope.requestedEpisode, .multiEpisode] {
            let matching = videos.indices.filter { scopes[$0] == wanted }.map { videos[$0] }
            if !matching.isEmpty { return .file(largest(matching)) }
        }
        do {
            // A range holding it: "S01E01-E03" for S01E03.
            let ranges = videos.indices.filter {
                scopes[$0] == .pack && ReleaseName.namesEpisode(WantedFile.leafName(fileNames[videos[$0]]), season: season, episode: episode)
            }.map { videos[$0] }
            if !ranges.isEmpty { return .file(largest(ranges)) }
            // Numbered within its season: the season is the folder's or the
            // torrent's; a pack that names no season ("[Group] Show (01-28)
            // [Batch]", "Chernobyl.Complete") is season 1 for the files at its
            // top or all in one folder — not "Series 2/01 - …", "Book 3 -
            // Fire/01 - …" (folders not read as seasons). Extras ("Extras/",
            // "Bonus/", "Specials/", a featurette's "Part 1") never count.
            let episodes = videos.indices.filter { !WantedFile.isExtra(fileNames[videos[$0]]) }
            let oneFolder = Set(episodes.map { WantedFile.folders(of: fileNames[videos[$0]]) }).count <= 1
            let impliesSeasonOne = torrentName.map(ReleaseName.impliesSeasonOne) == true
            let inSeason = episodes.filter { position in
                guard scopes[position] == .unknown || scopes[position] == .pack else { return false }
                let path = fileNames[videos[position]]
                let packSeason = WantedFile.seasonOfFolders(path) ?? torrentName.flatMap(ReleaseName.singleSeason(of:))
                    ?? (impliesSeasonOne && (oneFolder || WantedFile.folders(of: path).count <= 1) ? 1 : nil)
                return packSeason == season
            }
            // A leading number that changes from file to file is the episode's
            // ("9-1-1 Season 3/09 - Title"); the same in every file, the show's
            // ("24 Season 1/24 - 05 - Title").
            let leaves = inSeason.map { WantedFile.leafName(fileNames[videos[$0]]) }
            let showNumberLeads = Set(leaves.compactMap(ReleaseName.leadingNumber(ofLeaf:))).count < 2
            let numbers = zip(inSeason, leaves).compactMap { position, leaf -> (position: Int, number: Int)? in
                let title = showNumberLeads ? (WantedFile.folders(of: fileNames[videos[position]]).first ?? torrentName) : nil
                return ReleaseName.episodeNumberInSeason(leaf, season: season, title: title).map { (position, $0) }
            }
            // A later season numbered from above 1 is numbered absolutely
            // ("[HorribleSubs] Boku no Hero Academia S2 (14-38)": "- 14" is
            // S02E01): no number is trusted then (the magnet's so= is, step 2).
            let absolute = season > 1 && (numbers.map { $0.number }.min() ?? 1) > 1
            let numbered = absolute ? [] : numbers.filter { $0.number == episode }.map { videos[$0.position] }
            if !numbered.isEmpty { return .file(largest(numbered)) }
        }

        guard videos.count > 1 else { return .usualRule }
        if scopes.contains(where: { $0 != .unknown }) { return .notInTorrent }
        if let name = torrentName, ReleaseName.coversSeveralEpisodes(name) { return .notInTorrent }
        return .usualRule
    }

    /// The magnet's `so=` file names this season with an absolute number,
    /// the requested episode's place in the pack: "[PnP] Shingeki no Kyojin
    /// S03 [38-59]" numbers S03E13 "S03 - 50", the 13th of the season's files
    /// from 38 (Jujutsu Kaisen S02E01: "S02E25"). Torrentio's `so=` points at
    /// the right file there; another season's file (American Dad "S11E08"
    /// for S02E01), or a number that is not the episode's place, is not.
    static func continuesAbsoluteNumbering(_ index: Int, season: Int, episode: Int, fileNames: [String]) -> Bool {
        guard let own = ReleaseName.singleEpisode(of: WantedFile.leafName(fileNames[index])),
              own.season == season, own.episode > episode else { return false }
        var numbers: [Int] = []
        for name in fileNames where ReleaseName.isVideoFile(name) {
            let leaf = WantedFile.leafName(name)
            // A file naming the episode itself: that one, not so= (step 3).
            if ReleaseName.episodeScope(of: leaf, season: season, episode: episode) == .requestedEpisode { return false }
            if let marked = ReleaseName.singleEpisode(of: leaf), marked.season == season { numbers.append(marked.episode) }
        }
        guard let first = numbers.min(), first > 1 else { return false }
        return first + episode - 1 == own.episode
    }

    /// The folders of a torrent path, outermost first.
    static func folders(of path: String) -> [String] {
        return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast().map(String.init)
    }

    /// A file called "sample" or "trailer", or in a "Sample" folder.
    static func isCalledSample(_ path: String) -> Bool {
        if ReleaseName.looksLikeSample(path) { return true }
        let folders = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast()
        return folders.contains { ["sample", "samples"].contains($0.lowercased()) }
    }

    /// A pack's extra: a file in an "Extras", "Featurettes", "Bonus", "Specials",
    /// "Behind the Scenes"… folder, or a featurette / "Making of" / "Behind the
    /// Scenes" by its name ("Planet Earth II Diaries Part 1", "The.Making.of.
    /// Chernobyl.Part.3" are not episodes 1 and 3).
    static func isExtra(_ path: String) -> Bool {
        if folders(of: path).contains(where: { extraFolders.contains($0.lowercased()) }) { return true }
        let t = ReleaseName.tokens(leafName(path))
        if t.contains("featurette") || t.contains("featurettes") { return true }
        return zip(t, t.dropFirst()).contains { $0 == "making" && $1 == "of" }
            || zip(t, zip(t.dropFirst(), t.dropFirst(2))).contains { $0 == "behind" && $1.0 == "the" && $1.1 == "scenes" }
    }
    private static let extraFolders: Set<String> = [
        "extras", "extra", "featurettes", "featurette", "bonus", "bonus features", "bonuses", "behind the scenes",
        "specials", "special features", "deleted scenes",
    ]

    /// The one season a file's folders name ("Show.S02.1080p/02 - Title.mkv"),
    /// the nearest folder first; nil when none does.
    static func seasonOfFolders(_ path: String) -> Int? {
        let folders = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast()
        for folder in folders.reversed() {
            if let season = ReleaseName.singleSeason(of: String(folder)) { return season }
        }
        return nil
    }

    /// The last path component of a file name or torrent path.
    static func leafName(_ name: String) -> String {
        return name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? name
    }

    /// A file name as `choice` compares it: its last path component without
    /// a video container extension, lower-cased letters and digits only.
    static func comparableName(_ name: String) -> String {
        var leaf = leafName(name).trimmingCharacters(in: .whitespacesAndNewlines)
        if ReleaseName.videoContainerExtension(of: leaf) != nil, let dot = leaf.lastIndex(of: ".") {
            leaf = String(leaf[..<dot])
        }
        return String(leaf.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
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
    ///
    /// An explicit resolution wins over "4K" / "UHD", which often only name
    /// the source ("Movie.4K.Remastered.1080p…", "…1080p.UHD.BluRay…" are
    /// 1080p). Frame-packed 3D (SBS / OU / TAB) goes to `.threeD` even when a
    /// resolution is present, so it never competes with regular releases;
    /// "3D" alone in a title ("Step.Up.3D.2010.1080p…") is not enough.
    public static func parse(_ raw: String) -> VideoQuality {
        let s = raw.lowercased()
        let t = ReleaseName.tokens(raw)
        // "3D" alone is YTS's quality field; "3D H.264 — EZTV" is the label
        // `Torrent.quality` re-parses.
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "3d" || trimmed.hasPrefix("3d ") || isFramePacked3D(t) { return .threeD }
        if s.contains("2160") || s.contains("4320") { return .uhd2160 }
        if s.contains("1080") { return .hd1080 }
        if s.contains("720")  { return .hd720 }
        if s.contains("480") || s.contains("576") { return .sd480 }
        if t.contains("uhd") || zip(t, t.dropFirst()).contains(where: { $0 == "4" && $1 == "k" }) { return .uhd2160 }
        if s.contains(" 3d") || s.contains(".3d") || s.contains("-3d") { return .threeD }
        return .unknown
    }

    /// Side-by-side / over-under / top-and-bottom frame packing.
    static func isFramePacked3D(_ t: [String]) -> Bool {
        let tokens = Set(t)
        if !tokens.isDisjoint(with: ["hsbs", "fsbs", "htab", "ftab"]) { return true }
        let pairs = zip(t, t.dropFirst())
        if pairs.contains(where: { ["half", "full", "h", "f"].contains($0) && ["sbs", "ou", "tab"].contains($1) }) { return true }
        let says3D = pairs.contains(where: { $0 == "3" && $1 == "d" })
        return says3D && !tokens.isDisjoint(with: ["sbs", "ou", "hou", "tab"])
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
/// Drive the playability ranking (`Torrent.playabilityScore`) and inform the
/// player engine of HDR / Dolby Vision / Atmos content.
///
/// Raw values may be persisted: existing bits never change, new ones are
/// appended.
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
    /// Any DTS flavour (core, ES, HD MA/HRA, DTS:X).
    public static let dts          = VideoTags(rawValue: 1 << 7)
    /// Dolby Digital Plus (E-AC-3). With Atmos (JOC) it is the one Atmos
    /// carrier Apple devices output natively (AVPlayer, remuxed MKV included).
    public static let eac3         = VideoTags(rawValue: 1 << 8)
    /// Dolby Digital (AC-3): "DD5.1", "AC3", "Dolby Digital".
    public static let ac3          = VideoTags(rawValue: 1 << 9)
    public static let aac          = VideoTags(rawValue: 1 << 10)
    public static let flac         = VideoTags(rawValue: 1 << 11)
    public static let opus         = VideoTags(rawValue: 1 << 12)
    /// PCM / LPCM (Blu-ray remuxes).
    public static let lpcm         = VideoTags(rawValue: 1 << 13)
    public static let mp3          = VideoTags(rawValue: 1 << 14)
    /// DTS-HD Master Audio / High Resolution (also sets `.dts`).
    public static let dtsHD        = VideoTags(rawValue: 1 << 15)
    /// DTS:X (also sets `.dts`).
    public static let dtsX         = VideoTags(rawValue: 1 << 16)
    /// H.264 / AVC ("x264", "H.264", "AVC").
    public static let h264         = VideoTags(rawValue: 1 << 17)
    public static let hlg          = VideoTags(rawValue: 1 << 18)
    public static let vp9          = VideoTags(rawValue: 1 << 19)
    /// Untouched Blu-ray streams in Matroska ("REMUX").
    public static let remux        = VideoTags(rawValue: 1 << 20)
    /// 10-bit video ("10bit", "10-bit", "Hi10P", "Main10").
    public static let tenBit       = VideoTags(rawValue: 1 << 21)
    /// Theater recording or pre-release screener (CAM, HDTS, TELESYNC,
    /// TELECINE, SCR…).
    public static let cam          = VideoTags(rawValue: 1 << 22)

    /// Parse a torrent / file name for codec, HDR and audio markers.
    ///
    /// Token-based (see `ReleaseName.tokens`): "HDRip" / "HDTV" never mean
    /// HDR, "DV" only counts as a standalone token (not DVD / DVDRip / DVDScr),
    /// DTS only as a token prefix (DTS, DTSHD, DTS-HD, DTSX, DTS:X).
    public static func parse(_ raw: String) -> VideoTags {
        let t = ReleaseName.tokens(raw)
        // Where "Opus" / "Cam" / "Screener"… may be tags, not words of a title.
        let wordTags = ReleaseName.wordTagMask(of: t)
        func at(_ i: Int) -> String { return i >= 0 && i < t.count ? t[i] : "" }
        var tags: VideoTags = []

        for i in t.indices {
            let token = t[i], prev = at(i - 1), next = at(i + 1), next2 = at(i + 2)
            switch token {
            // Dynamic range
            case "dv", "dovi", "dolbyvision":
                tags.insert(.dolbyVision)
            case "hdrdv", "dvhdr":
                tags.formUnion([.dolbyVision, .hdr10])
            case "hdr":
                tags.insert(.hdr10)
                if next == "10" && (next2 == "+" || next2 == "plus") { tags.insert(.hdr10Plus) }
            case "hdrplus":
                tags.formUnion([.hdr10, .hdr10Plus])
            case "hlg":
                tags.insert(.hlg)
            case "dolby":
                if next == "vision" { tags.insert(.dolbyVision) }
                else if next == "digital" { tags.insert(next2 == "plus" ? .eac3 : .ac3) }

            // Video codecs
            case "hevc":
                tags.insert(.hevc)
            case "x", "h":
                if next == "265" { tags.insert(.hevc) }
                if next == "264" { tags.insert(.h264) }
            case "avc":
                tags.insert(.h264)
            case "av":
                if next == "1" { tags.insert(.av1) }
            case "aom":
                tags.insert(.av1)
            case "vp":
                if next == "9" || next == "09" { tags.insert(.vp9) }
            case "bit", "bits":
                if prev == "10" { tags.insert(.tenBit) }
            case "hi":
                if next == "10" { tags.formUnion([.tenBit, .h264]) }   // Hi10 / Hi10P = H.264 High 10
            case "main":
                if next == "10" { tags.insert(.tenBit) }               // HEVC Main10

            // Audio
            case "ddp", "ddplus":
                tags.insert(.eac3)
            case "ddpa":
                tags.formUnion([.eac3, .atmos])
            case "dd":
                tags.insert(next == "+" ? .eac3 : .ac3)
            case "eac", "ec":
                if next == "3" { tags.insert(.eac3) }
            case "e":
                if next == "ac" && next2 == "3" { tags.insert(.eac3) }
            case "ac":
                if next == "3" && prev != "e" { tags.insert(.ac3) }
            case "aac":
                tags.insert(.aac)
            case "flac":
                tags.insert(.flac)
            case "opus":
                if wordTags[i] { tags.insert(.opus) }
            case "lpcm", "pcm":
                tags.insert(.lpcm)
            case "mp":
                if next == "3" { tags.insert(.mp3) }
            case "truehd":
                tags.insert(.trueHD)
            case "true":
                if next == "hd" { tags.insert(.trueHD) }
            case "atmos":
                tags.insert(.atmos)
            case "dts":
                tags.insert(.dts)
                if ["hd", "hdma", "hdhr", "hdhra", "ma", "hra"].contains(next) { tags.insert(.dtsHD) }
                // "DTS:X" / "DTS-X" — but "DTS.x264" is DTS + an x264 encode.
                if next == "x" && next2 != "264" && next2 != "265" { tags.insert(.dtsX) }
            case "dtshd", "dtshdma", "dtsma", "dtshdhr", "dtshra":
                tags.formUnion([.dts, .dtsHD])
            case "dtsx":
                tags.formUnion([.dts, .dtsX])
            case "dtses":
                tags.insert(.dts)

            // Release type
            case "remux", "bdremux", "uhdremux":
                tags.insert(.remux)
            case "cam", "camrip", "hdcam", "hqcam", "hdts", "telesync", "tsrip", "hdtc", "telecine",
                 "dvdscr", "bdscr", "screener", "scr", "pdvd", "predvd":
                if wordTags[i] { tags.insert(.cam) }
            case "ts":
                // A bare "TS" (telesync) right after the year or the resolution,
                // or right before the codec: "IT 2017 TS x264",
                // "Superman.2025.1080p.TS.READNFO". Never a ".ts" file extension.
                let afterYear = prev.count == 4 && Int(prev).map { (1900...2099).contains($0) } == true
                let afterResolution = prev == "p" && ["480", "720", "1080", "2160"].contains(at(i - 2))
                let beforeCodec = ["x", "h", "xvid", "divx", "hevc", "avc"].contains(next)
                if wordTags[i], afterYear || afterResolution || beforeCodec,
                   !raw.lowercased().trimmingCharacters(in: .whitespaces).hasSuffix(".ts") {
                    tags.insert(.cam)
                }
            default:
                break
            }
        }
        return tags
    }

    /// Human-readable suffix for the pickers, e.g. " DV HDR HEVC DD+ Atmos":
    /// dynamic range, video codec, then ONE audio label (the release's
    /// headline track). Every word parses back to the same tags, because
    /// `Torrent.quality`'s setter re-parses the label.
    public var displaySuffix: String {
        var parts: [String] = []
        if contains(.cam) { parts.append("CAM") }
        if contains(.dolbyVision) { parts.append("DV") }
        if contains(.hdr10Plus)   { parts.append("HDR10+") }
        else if contains(.hdr10)  { parts.append("HDR") }
        else if contains(.hlg)    { parts.append("HLG") }
        if contains(.av1)         { parts.append("AV1") }
        else if contains(.vp9)    { parts.append("VP9") }
        else if contains(.hevc)   { parts.append("HEVC") }
        else if contains(.h264)   { parts.append("H.264") }
        if let audio = audioLabel { parts.append(audio) }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    /// The headline audio track. Atmos goes with TrueHD when a release names
    /// both TrueHD and DD+ (Blu-ray Atmos lives in TrueHD; the DD+ is then a
    /// compatibility track).
    var audioLabel: String? {
        if contains(.atmos) && contains(.eac3) && !contains(.trueHD) { return "DD+ Atmos" }
        if contains(.atmos) && contains(.trueHD) { return "TrueHD Atmos" }
        if contains(.dtsX)   { return "DTS:X" }
        if contains(.dtsHD)  { return "DTS-HD MA" }
        if contains(.trueHD) { return "TrueHD" }
        if contains(.eac3)   { return "DD+" }
        if contains(.atmos)  { return "Atmos" }
        if contains(.ac3)    { return "DD" }
        if contains(.dts)    { return "DTS" }
        if contains(.flac)   { return "FLAC" }
        if contains(.lpcm)   { return "LPCM" }
        if contains(.aac)    { return "AAC" }
        if contains(.opus)   { return "Opus" }
        if contains(.mp3)    { return "MP3" }
        return nil
    }
}

/// How well a release is expected to play on this device — the ranking key
/// used after the resolution bucket (see `Torrent.playabilityScore`).
public struct PlayabilityAssessment: Equatable, CustomStringConvertible {

    /// Sum of the components below; higher is better. Ordinary releases land
    /// between 0 and +63, penalized ones go far below (down to about −140).
    public let score: Int
    /// Something in the release is expected to play badly here (software-only
    /// AV1 / VP9 / HEVC decode, Dolby Vision without an HDR10 base on a non-DV
    /// display, theater recording). `Torrent.balancedPick` and
    /// `TorrentioClient.merge` avoid these while an alternative exists.
    public let isPenalized: Bool
    /// Per-component explanation ("DV +30", "HEVC +5"…), only filled when
    /// requested — for logs and the stats overlay.
    public let notes: [String]

    public var description: String {
        return "\(score)\(isPenalized ? " (penalized)" : "")" + (notes.isEmpty ? "" : " [" + notes.joined(separator: ", ") + "]")
    }

    /// Deterministic score of a release (tags parsed from its name + payload
    /// container) for a device:
    ///
    /// - Dynamic range: Dolby Vision +30 when the display path supports it;
    ///   otherwise DV falls back to its HDR10 / HLG base layer when the name
    ///   has one, and DV alone (profile 5, no compatible base layer — wrong
    ///   colours) is −30 and penalized. HDR10+ +22, HDR10 +20, HLG +15 on an
    ///   HDR display; +5 for any of them on an SDR display (tone-mapped).
    /// - Video codec: HEVC +5 (−20, penalized, without hardware decode),
    ///   H.264 +3, AV1 +6 with hardware decode else −40 (penalized), VP9 −40
    ///   (penalized: VLC software decode). 10-bit HEVC/AV1 +2; 10-bit H.264
    ///   (Hi10P, no hardware decoder anywhere) −15.
    /// - Audio — the best natively playable track the name advertises:
    ///   E-AC-3 Atmos +25 (true Atmos everywhere), E-AC-3 +15, FLAC/LPCM +12
    ///   (lossless), AC-3 +10, AAC +8, TrueHD Atmos +8, Opus +6, TrueHD +6,
    ///   DTS:X +5, DTS-HD MA +5, MP3 +3, DTS +2 (no Apple decoder for
    ///   TrueHD/DTS: they need a compatibility track or VLC), Atmos with an
    ///   unnamed carrier +10, nothing advertised +7.
    /// - Container (payload extension from the magnet `dn`): MKV/MP4/MOV/WebM
    ///   0, AVI/TS/M2TS/WMV/FLV/MPG… −20 (VLC only), unknown 0.
    /// - Theater recording / screener −50 (penalized).
    public static func assess(tags: VideoTags,
                              containerExtension: String?,
                              capabilities caps: PlaybackCapabilities.Snapshot,
                              explain: Bool = false) -> PlayabilityAssessment {
        var score = 0
        var penalized = false
        var notes: [String] = []
        func add(_ value: Int, _ label: @autoclosure () -> String) {
            score += value
            if explain { notes.append("\(label()) \(value >= 0 ? "+" : "")\(value)") }
        }

        // Dynamic range
        let hdrBase: (value: Int, label: String)? = {
            if tags.contains(.hdr10Plus) { return (caps.hdr ? 22 : 5, "HDR10+") }
            if tags.contains(.hdr10)     { return (caps.hdr ? 20 : 5, "HDR10") }
            if tags.contains(.hlg)       { return (caps.hdr ? 15 : 5, "HLG") }
            return nil
        }()
        if tags.contains(.dolbyVision) {
            if caps.dolbyVision {
                add(30, "DV")
            } else if let base = hdrBase {
                add(base.value, "DV→\(base.label)")
            } else {
                add(-30, "DV only")
                penalized = true
            }
        } else if let base = hdrBase {
            add(base.value, base.label)
        }

        // Video codec
        if tags.contains(.av1) {
            if caps.av1HardwareDecode { add(6, "AV1") } else { add(-40, "AV1 (software)"); penalized = true }
        } else if tags.contains(.vp9) {
            add(-40, "VP9"); penalized = true
        } else if tags.contains(.hevc) {
            if caps.hevcHardwareDecode { add(5, "HEVC") } else { add(-20, "HEVC (software)"); penalized = true }
        } else if tags.contains(.h264) {
            add(3, "H.264")
        }
        if tags.contains(.tenBit) {
            if tags.contains(.h264) && !tags.contains(.hevc) && !tags.contains(.av1) {
                add(-15, "Hi10P")
            } else if tags.contains(.hevc) || tags.contains(.av1) {
                add(2, "10-bit")
            }
        }

        // Audio: the best track the device decodes (max, not sum).
        var audio: (value: Int, label: String)?
        func consider(_ value: Int, _ label: String) {
            if audio == nil || value > audio!.value { audio = (value, label) }
        }
        if tags.contains(.eac3) {
            if tags.contains(.atmos) && !tags.contains(.trueHD) { consider(25, "DD+ Atmos") } else { consider(15, "DD+") }
        }
        if tags.contains(.flac) { consider(12, "FLAC") }
        if tags.contains(.lpcm) { consider(12, "LPCM") }
        if tags.contains(.ac3)  { consider(10, "DD") }
        if tags.contains(.aac)  { consider(8, "AAC") }
        if tags.contains(.trueHD) {
            if tags.contains(.atmos) { consider(8, "TrueHD Atmos") } else { consider(6, "TrueHD") }
        }
        if tags.contains(.opus)  { consider(6, "Opus") }
        if tags.contains(.dtsX)  { consider(5, "DTS:X") }
        if tags.contains(.dtsHD) { consider(5, "DTS-HD MA") }
        if tags.contains(.mp3)   { consider(3, "MP3") }
        if tags.contains(.dts)   { consider(2, "DTS") }
        if audio == nil && tags.contains(.atmos) { consider(10, "Atmos") }
        if let audio = audio { add(audio.value, audio.label) } else { add(7, "audio ?") }

        // Container
        if let ext = containerExtension, ReleaseName.legacyVideoExtensions.contains(ext) {
            add(-20, ".\(ext)")
        }

        // Source
        if tags.contains(.cam) {
            add(-50, "CAM")
            penalized = true
        }

        return PlayabilityAssessment(score: score, isPenalized: penalized, notes: notes)
    }
}

// MARK: - Bandwidth

/// Whether a release's bitrate fits what this device's connection delivers.
/// Rates are in BYTES per second throughout (libtorrent's unit); the UI
/// converts with `megabitsPerSecond`.
///
/// The bitrate of a release is estimated as the streamed file's size over
/// the media runtime (`Torrent.estimatedBitrate`); the connection estimate
/// is measured by the app (`ConnectionSpeed`: a high percentile of the
/// sustained download rates of recent streams) and kept under
/// `connectionEstimateDefaultsKey`.
public enum StreamBandwidth {

    /// How a release compares with the connection.
    public enum Fit: Equatable {
        /// No estimate: size or runtime unknown, or the size is a whole pack's.
        case unknown
        /// Within `connectionHeadroom` of the measured connection, or not
        /// heavy (`heavyBitrate`) while the connection is unknown.
        case fits
        /// Above `connectionHeadroom` of the measured connection: playback
        /// will keep stalling while the download catches up.
        case exceedsConnection
        /// The connection is unknown and the release is above `heavyBitrate`
        /// (4K remux class), which few connections + swarms sustain.
        case heavy

        /// `exceedsConnection` or `heavy`: avoided by the recommendation
        /// whenever a lighter healthy release exists, flagged in the pickers.
        public var isTooHeavy: Bool {
            return self == .exceedsConnection || self == .heavy
        }
    }

    /// Share of the measured connection a release may use: the rest absorbs
    /// swarm fluctuations, protocol overhead and the variable bitrate of the
    /// video (action scenes run well above the average).
    public static var connectionHeadroom = 0.85

    /// 40 Mbit/s in bytes/s: without a connection estimate, releases above it
    /// (UHD Blu-ray remuxes run 50–100 Mbit/s) count as heavy.
    public static var heavyBitrate: Double = 40_000_000 / 8

    /// Estimates outside this range (bytes/s) are discarded as implausible: a
    /// wrong runtime, or a size that covers more than the streamed file
    /// (UHD Blu-ray peaks at 144 Mbit/s with audio).
    public static let plausibleBitrates: ClosedRange<Double> = 20_000...20_000_000

    /// UserDefaults key of the connection estimate in bytes/s (a Double),
    /// written by the app's `ConnectionSpeed`. Absent or 0 = unknown. (A
    /// launch argument `-PTConnectionSpeedEstimate <bytes/s>` overrides it.)
    public static let connectionEstimateDefaultsKey = "PTConnectionSpeedEstimate"

    /// The connection estimate (bytes/s), nil when no stream measured it yet.
    public static var connectionEstimate: Double? {
        let value = UserDefaults.standard.double(forKey: connectionEstimateDefaultsKey)
        return value.isFinite && value > 0 ? value : nil
    }

    /// Bytes per second → megabits per second.
    public static func megabitsPerSecond(_ bytesPerSecond: Double) -> Double {
        return bytesPerSecond * 8 / 1_000_000
    }

    /// How a release of `bitrate` bytes/s fits a connection of `connection`
    /// bytes/s (nil = unknown).
    public static func fit(bitrate: Double?, connection: Double?) -> Fit {
        guard let bitrate = bitrate else { return .unknown }
        if let connection = connection, connection > 0 {
            return bitrate > connection * connectionHeadroom ? .exceedsConnection : .fits
        }
        return bitrate > heavyBitrate ? .heavy : .fits
    }

    /// Bytes of a size label as the providers write it: Torrentio's
    /// "31.07 GB" / "984.22 MB", `ByteCountFormatter`'s in any locale of the
    /// app ("31,07 Go", "1 000 MB", "1.000 MB", Arabic-Indic digits with
    /// "غ.ب."), TPB / Knaben's "%.2f GB". Units are binary (every producer
    /// divides by 1024); a bare number is bytes. Nil when there is no number.
    public static func bytes(fromSizeLabel raw: String?) -> Int64? {
        guard let raw = raw else { return nil }
        let scalars = Array(raw.unicodeScalars)
        func digit(_ scalar: Unicode.Scalar) -> Character? {
            switch scalar.value {
            case 0x30...0x39: return Character(scalar)
            case 0x0660...0x0669: return Character(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)   // Arabic-Indic
            case 0x06F0...0x06F9: return Character(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)   // Extended Arabic-Indic
            default: return nil
            }
        }
        let separators: Set<UInt32> = [0x2E, 0x2C, 0x066B, 0x066C, 0x27, 0x2019, 0x20, 0xA0, 0x202F, 0x2009]
        guard let start = scalars.firstIndex(where: { digit($0) != nil }) else { return nil }
        // Digit runs and the separators between them ("1", " ", "000"; "31", ",", "07").
        var runs = [""], joins: [UInt32] = []
        var i = start
        while i < scalars.count {
            if let d = digit(scalars[i]) {
                runs[runs.count - 1].append(d)
            } else if separators.contains(scalars[i].value), i + 1 < scalars.count, digit(scalars[i + 1]) != nil {
                joins.append(scalars[i].value)
                runs.append("")
            } else {
                break
            }
            i += 1
        }
        // The last separator is the decimal one unless three digits follow
        // it (a grouping: "1,000", "1.000", "1 000"); "٫" is always decimal.
        var integer = runs.joined(), fraction = ""
        if let last = joins.last, last == 0x066B || ((last == 0x2E || last == 0x2C) && runs.last!.count != 3) {
            integer = runs.dropLast().joined()
            fraction = runs.last!
        }
        guard let value = Double(integer + (fraction.isEmpty ? "" : "." + fraction)), value > 0 else { return nil }
        // Unit: the first letter after the number (bidi marks and spaces skipped).
        let unit = scalars[i...].first(where: { CharacterSet.letters.contains($0) })
            .map { String($0).lowercased() } ?? ""
        let multiplier: Double
        switch unit {
        case "t", "т", "ت": multiplier = 1_099_511_627_776
        case "g", "г", "غ", "ج": multiplier = 1_073_741_824
        case "m", "м", "م": multiplier = 1_048_576
        case "k", "к", "ك": multiplier = 1024
        default: multiplier = 1                                  // "B", "o", "bytes", none
        }
        let bytes = value * multiplier
        return bytes.isFinite && bytes < 9e18 ? Int64(bytes) : nil
    }
}

// MARK: - Torrent

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

    /// Video container of the payload, from the magnet's `dn` (parsed once:
    /// the ranking comparator reads it on every comparison).
    private let payloadContainer: String?

    /// Human-readable quality label, e.g. "2160p DV HDR HEVC DD+ Atmos". Preserved as a
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

    /// Bytes of `size` when it is the streamed file's (see
    /// `streamedFileBytes`), parsed once: the ranking reads it on every
    /// comparison.
    private let streamedBytes: Int64?

    /// The streamed file's name when the provider gives it apart from the
    /// magnet (Time4Popcorn's `file`: its magnets name the whole season
    /// pack, its sizes are the episode file's). Judged instead of the
    /// magnet's `dn` by `streamedFileBytes`; the file a stream of a pack
    /// plays (`WantedFile(media:torrent:)`).
    public let releaseFileName: String?

    /// Runtime in seconds of the movie / episode this torrent plays, when
    /// the caller attached it (`withMediaRuntime`, `Torrent.mediaRuntime(of:)`):
    /// with the size it gives `estimatedBitrate`. Nil = unknown.
    public var mediaRuntime: TimeInterval?

    public init?(map: Map) {
        do { self = try Torrent(map) }
        catch { return nil }
    }

    private init(_ map: Map) throws {
        self.url   = try map.value("url")
        self.seeds = (try? (try? map.value("seeds")) ?? map.value(("seed"))) ?? 0
        self.peers = (try? (try? map.value("peers")) ?? map.value(("peer"))) ?? 0
        self.size  = try? map.value("filesize")
        self.payloadContainer = Torrent.payloadContainerExtension(ofMagnet: url)
        self.releaseFileName = nil
        self.streamedBytes = Torrent.streamedFileBytes(size: size, url: url)

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
                tags: VideoTags = [],
                fileName: String? = nil) {
        self.health = health
        self.url    = url
        self.seeds  = seeds
        self.peers  = peers
        self.size   = size
        self.payloadContainer = Torrent.payloadContainerExtension(ofMagnet: url)
        let fileName = fileName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.releaseFileName = fileName
        self.streamedBytes = Torrent.streamedFileBytes(size: size, url: url, fileName: fileName)
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

    private static func payloadContainerExtension(ofMagnet url: String) -> String? {
        return MagnetLink.displayName(of: url).flatMap(ReleaseName.videoContainerExtension(of:))
    }

    /// Bytes of the file a stream of `url` plays, from the `size` label —
    /// nil when unknown or when the size is likely a whole pack's.
    ///
    /// Torrentio's size is the stream's FILE whenever it knows the torrent's
    /// files (it then sets `fileIdx` and `behaviorHints.filename`, which the
    /// magnet's `dn` carries: "Game.of.Thrones.S01E01….mkv", 31.07 GB in a
    /// season pack); without file information it is the whole torrent and
    /// `dn` is the torrent name ("Juego de Tronos - 1ª Temporada", 24.8 GB).
    /// Time4Popcorn's size is the episode file's, its magnet names the pack:
    /// its `file` name (`fileName`) is judged instead. The other providers
    /// give the whole torrent. So the size counts as the file's unless the
    /// name (`fileName`, else `dn`) covers several episodes or films
    /// (`ReleaseName.coversSeveralEpisodes`); a magnet without `dn` or a
    /// `.torrent` URL gives nothing to judge by: unknown.
    static func streamedFileBytes(size: String?, url: String, fileName: String? = nil) -> Int64? {
        guard let bytes = StreamBandwidth.bytes(fromSizeLabel: size), bytes > 0,
              let name = fileName ?? MagnetLink.displayName(of: url),
              !ReleaseName.coversSeveralEpisodes(name) else { return nil }
        return bytes
    }

    /// Copy pointing at another URL (same label, tags, swarm figures and runtime).
    func replacingURL(_ newURL: String) -> Torrent {
        var copy = Torrent(health: health, url: newURL, quality: "", seeds: seeds, peers: peers, size: size, tags: tags,
                           fileName: releaseFileName)
        copy._qualityOverride = _qualityOverride
        copy.qualityValue = qualityValue
        copy.tags = tags
        copy.mediaRuntime = mediaRuntime
        return copy
    }
}

/// Strict weak ordering (a lexicographic key, so `sort(by: <)` is valid):
/// 1. resolution bucket (unknown < 3D < 480p < 720p < 1080p < 2160p);
/// 2. `playabilityScore` on this device (HDR/DV the display can show, codecs
///    with hardware decode, Atmos/lossless audio that plays natively, modern
///    container) — see `PlayabilityAssessment.assess`;
/// 3. seeds;
/// 4. url, so distinct torrents never compare equivalent.
/// The capability snapshot is cached (`PlaybackCapabilities.current`), so a
/// sort never queries the display path per comparison.
public func < (lhs: Torrent, rhs: Torrent) -> Bool {
    return Torrent.ranksBelow(lhs, rhs, capabilities: PlaybackCapabilities.current)
}

public func > (lhs: Torrent, rhs: Torrent) -> Bool {
    return rhs < lhs
}

public func == (lhs: Torrent, rhs: Torrent) -> Bool {
    return lhs.url == rhs.url
}

public extension Torrent {

    /// The magnet's display name (`dn=`, percent-decoded): the payload file
    /// name for single-file torrents ("Movie.2023.2160p….mkv"), the torrent /
    /// folder name otherwise. Nil for `.torrent` URLs or magnets without `dn`.
    var fileNameHint: String? {
        return MagnetLink.displayName(of: url)
    }

    /// Lower-cased video container of the payload ("mkv", "mp4", "avi"…) when
    /// `fileNameHint` names one; nil when unknown (YTS magnets carry no extension).
    var containerExtension: String? {
        return payloadContainer
    }

    /// True when the payload is an MP4-family file AVPlayer opens directly
    /// (.mp4/.m4v/.mov). Informational: Matroska now reaches AVPlayer through
    /// the remuxer with the same HDR / Dolby Vision / Atmos output, so the
    /// ranking no longer favours MP4 over MKV.
    var isAppleNativeContainer: Bool {
        guard let ext = payloadContainer else { return false }
        return ["mp4", "m4v", "mov"].contains(ext)
    }

    /// Playability of this release on a device (see `PlayabilityAssessment.assess`).
    func playability(for capabilities: PlaybackCapabilities.Snapshot = PlaybackCapabilities.current,
                     explain: Bool = false) -> PlayabilityAssessment {
        return PlayabilityAssessment.assess(tags: tags,
                                            containerExtension: payloadContainer,
                                            capabilities: capabilities,
                                            explain: explain)
    }

    /// Deterministic playability score on the current device — the ranking key
    /// right after the resolution bucket. Higher is better; see
    /// `PlayabilityAssessment.assess` for the scale (e.g. 2160p DV + HEVC +
    /// DD+ Atmos = 60, HDR10 + HEVC + TrueHD Atmos = 33, SDR x264 AAC = 11).
    var playabilityScore: Int {
        return playability().score
    }

    /// The ranking behind `<` for an explicit capability snapshot.
    static func ranksBelow(_ lhs: Torrent, _ rhs: Torrent, capabilities: PlaybackCapabilities.Snapshot) -> Bool {
        if lhs.qualityValue != rhs.qualityValue {
            return lhs.qualityValue < rhs.qualityValue
        }
        let lhsScore = lhs.playability(for: capabilities).score
        let rhsScore = rhs.playability(for: capabilities).score
        if lhsScore != rhsScore { return lhsScore < rhsScore }
        if lhs.seeds != rhs.seeds { return lhs.seeds < rhs.seeds }
        return lhs.url < rhs.url
    }

    /// BEP 53 `so=` file selection of a magnet (first selected index), nil
    /// when absent or malformed. Torrentio sets it for season packs.
    static func selectedFileIndex(fromMagnet magnet: String) -> Int? {
        return MagnetLink.selectedFileIndex(of: magnet)
    }

    /// File to stream from a multi-file torrent (see `MagnetLink.fileIndexToStream`).
    static func fileIndexToStream(fileNames: [String], fileSizes: [Int64]? = nil, preferredIndex: Int?) -> Int {
        return MagnetLink.fileIndexToStream(fileNames: fileNames, fileSizes: fileSizes, preferredIndex: preferredIndex)
    }

    /// True for releases that can't be streamed at all — disc images,
    /// archives, full Blu-ray / DVD structures (see `ReleaseName.isLikelyUnplayable`).
    static func isLikelyUnplayableRelease(fileName: String?, title: String?) -> Bool {
        return ReleaseName.isLikelyUnplayable(fileName: fileName, title: title)
    }

    /// Seeds a swarm needs before a stream of this resolution starts quickly.
    static func minimumSeedsForQuickStart(_ quality: VideoQuality) -> Int {
        switch quality {
        case .uhd2160: return 45
        case .hd1080:  return 10
        case .hd720:   return 5
        case .sd480:   return 2
        case .threeD, .unknown: return 1
        }
    }

    /// Pick the highest resolution whose swarm is large enough to start
    /// streaming quickly, and whose bitrate the connection can carry, rather
    /// than the absolute highest.
    ///
    /// Higher resolutions carry far more bitrate, so they need a bigger swarm
    /// before playback can begin. A brand-new 4K release with ~20 seeds can
    /// take many minutes to buffer, whereas a well-seeded 1080p (roughly a
    /// third of the size) starts almost immediately. This walks resolutions
    /// high → low and takes the first that has a torrent clearing the
    /// resolution's seed floor (`minimumSeedsForQuickStart`); among those it
    /// picks the best `playabilityScore` (then seeds), consistent with the
    /// list order.
    ///
    /// A release too heavy for the connection (`bandwidthFit`: its estimated
    /// bitrate above 85 % of the measured `connection`, or above 40 Mbit/s
    /// while the connection is unknown) only wins when no lighter release
    /// clears its floor: a 72 Mbit/s UHD remux on a 27 Mbit/s connection
    /// stalls every few seconds, a healthy 1080p plays. A playback penalty
    /// (software-only codec, Dolby Vision the display can't show, CAM)
    /// weighs more than the weight: pools are tried in the order clean and
    /// light, clean, light, all. Releases without an estimate (size or
    /// runtime unknown) count as light, so without estimates nothing
    /// changes. If nothing clears its bar it returns, as before the
    /// bandwidth rule, the most-seeded clean torrent (any torrent when none
    /// is clean) — the best shot at a quick start, never a dead light one
    /// over a seeded heavy one; lightness only breaks a tie of seeds.
    static func balancedPick(from torrents: [Torrent],
                             capabilities: PlaybackCapabilities.Snapshot = PlaybackCapabilities.current,
                             connection: Double? = StreamBandwidth.connectionEstimate) -> Torrent? {
        guard !torrents.isEmpty else { return nil }
        typealias Assessed = (torrent: Torrent, playability: PlayabilityAssessment, tooHeavy: Bool)
        let assessed: [Assessed] = torrents.map {
            ($0, $0.playability(for: capabilities), $0.bandwidthFit(connection: connection).isTooHeavy)
        }
        let clean = assessed.filter { !$0.playability.isPenalized }
        let light = assessed.filter { !$0.tooHeavy }
        let cleanLight = clean.filter { !$0.tooHeavy }
        let pools = [cleanLight, clean, light, assessed].filter { !$0.isEmpty }

        func better(_ a: Assessed, _ b: Assessed) -> Bool {
            if a.playability.score != b.playability.score { return a.playability.score < b.playability.score }
            if a.torrent.seeds != b.torrent.seeds { return a.torrent.seeds < b.torrent.seeds }
            return a.torrent.url < b.torrent.url
        }

        for pool in pools {
            for quality in [VideoQuality.uhd2160, .hd1080, .hd720, .sd480] {
                let floor = minimumSeedsForQuickStart(quality)
                let healthy = pool.filter { $0.torrent.qualityValue == quality && $0.torrent.seeds >= floor }
                if let best = healthy.max(by: better) { return best.torrent }
            }
        }
        let fallback = clean.isEmpty ? assessed : clean
        return fallback.max(by: { a, b in
            if a.torrent.seeds != b.torrent.seeds { return a.torrent.seeds < b.torrent.seeds }
            if a.tooHeavy != b.tooHeavy { return a.tooHeavy }
            return better(a, b)
        })?.torrent
    }

    /// Order in which candidates claim the limited per-resolution slots of an
    /// aggregated list (`TorrentioClient.merge`, after its fast-start slot
    /// for the best-seeded clean release): releases without a playback
    /// penalty first; among them, those whose swarm clears
    /// `minimumSeedsForQuickStart` and whose bitrate the connection carries
    /// (`bandwidthFit`, as in `balancedPick`), then the other healthy ones,
    /// by playability score (best experience first), the rest by seeds (the
    /// swarm is the bottleneck there); then seeds, then url. Returns true
    /// when `a` should come before `b`.
    static func precedesInListing(_ a: Torrent, _ b: Torrent,
                                  capabilities: PlaybackCapabilities.Snapshot = PlaybackCapabilities.current,
                                  connection: Double? = StreamBandwidth.connectionEstimate) -> Bool {
        let pa = a.playability(for: capabilities), pb = b.playability(for: capabilities)
        if pa.isPenalized != pb.isPenalized { return !pa.isPenalized }
        let healthyA = a.seeds >= minimumSeedsForQuickStart(a.qualityValue)
        let healthyB = b.seeds >= minimumSeedsForQuickStart(b.qualityValue)
        let fastA = healthyA && !a.bandwidthFit(connection: connection).isTooHeavy
        let fastB = healthyB && !b.bandwidthFit(connection: connection).isTooHeavy
        if fastA != fastB { return fastA }
        if healthyA != healthyB { return healthyA }
        if healthyA && pa.score != pb.score { return pa.score > pb.score }
        if a.seeds != b.seeds { return a.seeds > b.seeds }
        if pa.score != pb.score { return pa.score > pb.score }
        return a.url < b.url
    }
}

// MARK: - The file to stream

public extension WantedFile {

    /// What a stream of `torrent` played for `media` wants from a
    /// multi-file torrent: an episode's season and number, and the
    /// torrent's own file name (`Torrent.releaseFileName`); a movie, that
    /// file name only. Nil when neither is known.
    init?(media: Media?, torrent: Torrent?) {
        let episode = media as? Episode
        self.init(season: episode?.season, episode: episode?.episode, fileName: torrent?.releaseFileName)
    }
}

// MARK: - Bitrate

public extension Torrent {

    /// Bytes of the `size` label (whatever it covers), nil when unknown.
    var sizeInBytes: Int64? {
        return StreamBandwidth.bytes(fromSizeLabel: size)
    }

    /// Bytes of the file a stream plays, nil when unknown — also when the
    /// size is likely a whole season / series pack's (see
    /// `Torrent.streamedFileBytes(size:url:)`).
    var streamedFileBytes: Int64? {
        return streamedBytes
    }

    /// Average bitrate in BYTES per second of the streamed file over a media
    /// runtime of `runtimeSeconds`: what the download has to sustain for a
    /// smooth playback. Nil when the file size or the runtime is unknown, or
    /// the result is implausible (`StreamBandwidth.plausibleBitrates`: a
    /// wrong runtime, a pack's size).
    func estimatedBitrate(runtimeSeconds: TimeInterval?) -> Double? {
        guard let bytes = streamedBytes, let runtime = runtimeSeconds, runtime.isFinite, runtime >= 60 else { return nil }
        let rate = Double(bytes) / runtime
        return StreamBandwidth.plausibleBitrates.contains(rate) ? rate : nil
    }

    /// `estimatedBitrate(runtimeSeconds:)` over the attached `mediaRuntime`.
    var estimatedBitrate: Double? {
        return estimatedBitrate(runtimeSeconds: mediaRuntime)
    }

    /// How this release's estimated bitrate fits a connection of
    /// `connection` bytes/s (default: the measured estimate; nil = unknown).
    func bandwidthFit(connection: Double? = StreamBandwidth.connectionEstimate) -> StreamBandwidth.Fit {
        return StreamBandwidth.fit(bitrate: estimatedBitrate, connection: connection)
    }

    /// Copy with `mediaRuntime` set (seconds; nil or ≤ 0 = unknown).
    func withMediaRuntime(_ seconds: TimeInterval?) -> Torrent {
        var copy = self
        copy.mediaRuntime = seconds.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        return copy
    }

    /// Runtime in seconds of what `media` plays, nil when unknown: a
    /// movie's `runtime`; an episode's show's typical runtime (`show`, else
    /// `episode.show`). Minutes in the models, 0 = unknown.
    static func mediaRuntime(of media: Media, show: Show? = nil) -> TimeInterval? {
        let minutes: Int?
        if let movie = media as? Movie {
            minutes = movie.runtime
        } else if let episode = media as? Episode {
            minutes = (show ?? episode.show)?.runtime
        } else if let show = media as? Show {
            minutes = show.runtime
        } else {
            minutes = nil
        }
        guard let value = minutes, value > 0 else { return nil }
        return TimeInterval(value) * 60
    }
}

public extension Array where Element == Torrent {

    /// Every torrent with `mediaRuntime` set (see `Torrent.withMediaRuntime`).
    func withMediaRuntime(_ seconds: TimeInterval?) -> [Torrent] {
        return map { $0.withMediaRuntime(seconds) }
    }

    /// Every torrent with the runtime of `media` (`Torrent.mediaRuntime(of:show:)`).
    func withMediaRuntime(of media: Media, show: Show? = nil) -> [Torrent] {
        return withMediaRuntime(Torrent.mediaRuntime(of: media, show: show))
    }
}

// MARK: - Picker labels

public extension Torrent {

    /// Separator between the quality and the source in the labels of the
    /// aggregated torrents: "1080p HEVC — TPB", "2160p HDR — Knaben · 1337x",
    /// "720p — T4P", "1080p — ThePirateBay" (a Torrentio indexer).
    static let sourceSeparator = " — "

    /// The quality part of `quality` ("2160p DV HDR HEVC"), without the source.
    var qualityLabel: String {
        let label = quality ?? ""
        guard let range = label.range(of: Torrent.sourceSeparator) else { return label }
        let head = label[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? label : head
    }

    /// Where the torrent was found ("TPB", "Knaben · 1337x", "T4P", a
    /// Torrentio indexer); nil when the label names no source (YTS, EZTV).
    var sourceLabel: String? {
        guard let label = quality, let range = label.range(of: Torrent.sourceSeparator) else { return nil }
        let tail = label[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? nil : tail
    }
}
