

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
    private static let sxxEyyMarker = regex("(?<![\\p{L}\\p{N}])s(\\d{1,2})[ ._-]?e(\\d{1,3})(?!\\d)")
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
        let text = name.lowercased()
        let ns = text as NSString
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
                } else if let next = continuation(rangeEnd, at: position), let e = number(next, 2) {
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
        for i in t.indices where seasonWords.contains(t[i]) && i + 3 < t.count {
            if let s = Int(t[i + 1]), episodeWords.contains(t[i + 2]), let e = Int(t[i + 3]), t[i + 3].count <= 3 {
                add(s, e)
            }
        }

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
        self.payloadContainer = Torrent.payloadContainerExtension(ofMagnet: url)
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

    /// Copy pointing at another URL (same label, tags and swarm figures).
    func replacingURL(_ newURL: String) -> Torrent {
        var copy = Torrent(health: health, url: newURL, quality: "", seeds: seeds, peers: peers, size: size, tags: tags)
        copy._qualityOverride = _qualityOverride
        copy.qualityValue = qualityValue
        copy.tags = tags
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
    /// streaming quickly, rather than the absolute highest.
    ///
    /// Higher resolutions carry far more bitrate, so they need a bigger swarm
    /// before playback can begin. A brand-new 4K release with ~20 seeds can
    /// take many minutes to buffer, whereas a well-seeded 1080p (roughly a
    /// third of the size) starts almost immediately. This walks resolutions
    /// high → low and takes the first that has a torrent clearing the
    /// resolution's seed floor (`minimumSeedsForQuickStart`); among those it
    /// picks the best `playabilityScore` (then seeds), consistent with the
    /// list order. Releases with a playback penalty (software-only codec,
    /// Dolby Vision the display can't show, CAM) are only picked when no
    /// clean release clears its floor. If nothing clears its bar it returns
    /// the most-seeded torrent (clean first) — the best shot at a quick start.
    static func balancedPick(from torrents: [Torrent],
                             capabilities: PlaybackCapabilities.Snapshot = PlaybackCapabilities.current) -> Torrent? {
        guard !torrents.isEmpty else { return nil }
        let assessed = torrents.map { (torrent: $0, playability: $0.playability(for: capabilities)) }
        let clean = assessed.filter { !$0.playability.isPenalized }

        func better(_ a: (torrent: Torrent, playability: PlayabilityAssessment),
                    _ b: (torrent: Torrent, playability: PlayabilityAssessment)) -> Bool {
            if a.playability.score != b.playability.score { return a.playability.score < b.playability.score }
            if a.torrent.seeds != b.torrent.seeds { return a.torrent.seeds < b.torrent.seeds }
            return a.torrent.url < b.torrent.url
        }

        for pool in [clean, assessed] where !pool.isEmpty {
            for quality in [VideoQuality.uhd2160, .hd1080, .hd720, .sd480] {
                let floor = minimumSeedsForQuickStart(quality)
                let healthy = pool.filter { $0.torrent.qualityValue == quality && $0.torrent.seeds >= floor }
                if let best = healthy.max(by: better) { return best.torrent }
            }
        }
        let pool = clean.isEmpty ? assessed : clean
        return pool.max(by: { a, b in
            a.torrent.seeds != b.torrent.seeds ? a.torrent.seeds < b.torrent.seeds : better(a, b)
        })?.torrent
    }

    /// Order in which candidates claim the limited per-resolution slots of an
    /// aggregated list (`TorrentioClient.merge`, after its fast-start slot
    /// for the best-seeded clean release): releases without a playback
    /// penalty first; among them, those whose swarm clears
    /// `minimumSeedsForQuickStart` by playability score (best experience
    /// first), the others by seeds (the swarm is the bottleneck there); then
    /// seeds, then url. Returns true when `a` should come before `b`.
    static func precedesInListing(_ a: Torrent, _ b: Torrent,
                                  capabilities: PlaybackCapabilities.Snapshot = PlaybackCapabilities.current) -> Bool {
        let pa = a.playability(for: capabilities), pb = b.playability(for: capabilities)
        if pa.isPenalized != pb.isPenalized { return !pa.isPenalized }
        let healthyA = a.seeds >= minimumSeedsForQuickStart(a.qualityValue)
        let healthyB = b.seeds >= minimumSeedsForQuickStart(b.qualityValue)
        if healthyA != healthyB { return healthyA }
        if healthyA && pa.score != pb.score { return pa.score > pb.score }
        if a.seeds != b.seeds { return a.seeds > b.seeds }
        if pa.score != pb.score { return pa.score > pb.score }
        return a.url < b.url
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
