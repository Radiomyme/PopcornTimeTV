import Foundation

/// What is known of the file being played, to pick its subtitles. Every
/// field may be missing: with nothing known the choice is the plain score's
/// (`SubtitlesManager.bestSubtitles`), as before.
public struct SubtitleFileContext: Equatable {
    /// The file's name and, when it has one, its torrent's
    /// ("Movie.2019.1080p.BluRay.x264-GROUP.mkv").
    public var releaseNames: [String]
    /// The film's length (s).
    public var durationSeconds: Double?
    /// The video's frame rate.
    public var frameRate: Double?

    public init(releaseNames: [String] = [], durationSeconds: Double? = nil, frameRate: Double? = nil) {
        self.releaseNames = releaseNames.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.durationSeconds = durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.frameRate = frameRate.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
    }

    /// The names a release can be given: the file's name, and its folder's
    /// when the torrent has one (a multi-file torrent is saved in a folder
    /// named after the release; a folder without any release tag adds
    /// nothing to the match).
    public static func releaseNames(ofFile file: URL) -> [String] {
        let folder = file.deletingLastPathComponent().lastPathComponent
        return [file.lastPathComponent, folder].filter { !$0.isEmpty && $0 != "/" }
    }
}

/// Picks, per language, the OpenSubtitles file made for THE FILE PLAYED
/// rather than the most downloaded one of the title: a subtitle timed for
/// another release (another cut, a PAL 25 fps master, a different intro) is
/// seconds off or drifting. In order:
/// 1. readable on every route (`SubtitlesManager.score`'s format tier ≥ 2:
///    SubRip, WebVTT, ASS, MicroDVD…): nothing below lifts a file only VLC
///    can read above one the AVPlayer routes convert;
/// 2. hash match: found by the OpenSubtitles hash of this very file
///    (`OpenSubtitlesHash`, `rowsForTitle`) — made for, or linked to, it;
/// 3. strong release match: `MovieReleaseName` / `SubFileName` names the
///    same release (same name, or same group with no conflicting source or
///    edition: `releaseMatch`);
/// 4. consistent: no last cue far past the film's end, no frame-rate family
///    clash (25 vs 23.976) — `inconsistency`;
/// 5. the plain score's format / hearing-impaired / flagged tiers;
/// 6. partial release match: same source (BluRay, WEB-DL…), resolution,
///    edition — or a conflicting edition, below;
/// 7. the plain score's popularity.
/// With no hash rows and nothing known of the file, only 1, 5 and 7 differ
/// between rows: exactly the plain score's order (ties: the first row).
/// Pure: the tests cover it.
public enum SubtitleMatching {

    // MARK: Title of the hash rows

    /// The rows of a moviehash search that belong to the title played: the
    /// same imdb id for a movie; the show's imdb id, season and episode for
    /// an episode. The hash search answers for any title sharing that hash
    /// and size, often unrelated ones.
    public static func rowsForTitle(_ rows: [Subtitle], imdbId: String?, showImdbId: String? = nil,
                                    season: Int? = nil, episode: Int? = nil) -> [Subtitle] {
        if let season, let episode {
            guard let show = showImdbId.flatMap(Subtitle.normalizedImdb) else { return [] }
            return rows.filter { $0.showImdbId == show && $0.season == season && $0.episode == episode }
        }
        guard let movie = imdbId.flatMap(Subtitle.normalizedImdb) else { return [] }
        return rows.filter { $0.imdbId == movie && $0.showImdbId == nil }
    }

    // MARK: Choice

    /// The list (one entry per language, its other rows as `alternates`)
    /// with each language's entry re-picked for `file`: the chosen row
    /// first, the rest as its alternates in rank order. `hashRows` (already
    /// limited to the title: `rowsForTitle`) join their language; a
    /// language that is only in `hashRows` is not added (the players' menus
    /// and the remux master list the languages of the search). Order of the
    /// list kept.
    public static func choose(_ list: [Subtitle], file: SubtitleFileContext, hashRows: [Subtitle] = []) -> [Subtitle] {
        list.map { entry in
            let ranked = rank(entry.allRows, file: file, hashRows: hashRows.filter { $0.ISO639 == entry.ISO639 })
            guard let first = ranked.first else { return entry }
            return first.with(alternates: Array(ranked.dropFirst()))
        }
    }

    /// One language's rows best first (see the type's comment), the hash
    /// rows that are not among them added. Stable.
    public static func rank(_ rows: [Subtitle], file: SubtitleFileContext, hashRows: [Subtitle] = []) -> [Subtitle] {
        var all = rows
        for row in hashRows where !all.contains(where: { sameFile($0, row) }) { all.append(row) }
        // The file's names are read once; uninformative ones skip the
        // subtitles' names altogether.
        let fileTraits = informativeTraits(file.releaseNames)
        let keys = all.map { key(for: $0, file: file, fileTraits: fileTraits, hashRows: hashRows) }
        return all.indices.sorted { a, b in
            keys[a] != keys[b] ? keys[a] > keys[b] : a < b
        }.map { all[$0] }
    }

    /// Why `row` ranks where it does, for the logs: "hash match", "release
    /// match", "consistent", "inconsistent (…)" or "score".
    public static func reason(for row: Subtitle, file: SubtitleFileContext, hashRows: [Subtitle] = []) -> String {
        if isHashMatch(row, hashRows: hashRows) { return "hash match" }
        if releaseMatch(row, names: file.releaseNames).isStrong { return "release match" }
        if let why = inconsistency(of: row, file: file) { return "inconsistent: \(why)" }
        return file.durationSeconds != nil || file.frameRate != nil ? "consistent" : "score"
    }

    /// The row the overlay should show instead of `selected`, now that the
    /// list is `chosen`: its language's pick when that is another file; nil
    /// when nothing changes (the same file, or a language no longer listed).
    public static func replacement(for selected: Subtitle, in chosen: [Subtitle]) -> Subtitle? {
        guard let pick = chosen.first(where: { $0.ISO639 == selected.ISO639 }), !sameFile(pick, selected) else { return nil }
        return pick
    }

    /// What the remux does with a language whose pick changed after its
    /// file may have been fetched (the hash answer comes once both ends of
    /// the file are on disk, usually after playback started).
    public enum LateReplacement: Equatable {
        /// The file fetched is the one chosen.
        case keep
        /// Nothing fetched yet: the next fetch takes the new pick (a
        /// download in flight is redone when it ends).
        case takeOnNextFetch
        /// Fetch the new pick now and serve it instead; `notifyPlayer`: the
        /// player may hold the old one (it requested the file), its item is
        /// rebuilt if that language is on screen (`SubtitleRetimeWatch`).
        case replace(notifyPlayer: Bool)
    }

    /// The late-replacement decision of one language (pure).
    /// - Parameters:
    ///   - fetchedLink: the link of the file cached for it, nil when none.
    ///   - chosenLink: the link of the new pick.
    ///   - servedToPlayer: a player requested its file (the old one, or the
    ///     empty one served for a failure).
    ///   - failed: its last fetch failed (no file cached): the new pick is
    ///     a fresh chance.
    public static func lateReplacement(fetchedLink: String?, chosenLink: String, servedToPlayer: Bool,
                                       failed: Bool) -> LateReplacement {
        if let fetchedLink {
            return fetchedLink == chosenLink ? .keep : .replace(notifyPlayer: servedToPlayer)
        }
        return failed ? .replace(notifyPlayer: servedToPlayer) : .takeOnNextFetch
    }

    // MARK: Signals

    /// A row of the moviehash search, or the same file as one.
    static func isHashMatch(_ row: Subtitle, hashRows: [Subtitle]) -> Bool {
        row.movieHash != nil || hashRows.contains { sameFile($0, row) }
    }

    /// Same OpenSubtitles file: same `IDSubtitleFile`, else same link.
    static func sameFile(_ a: Subtitle, _ b: Subtitle) -> Bool {
        if let x = a.fileId, let y = b.fileId { return x == y }
        return a.link == b.link
    }

    /// How far the subtitle's last cue may start past the film's end (s):
    /// end credits are not subtitled, a last cue minutes past the end means
    /// another cut or another frame rate.
    public static let lastCueMargin: Double = 180

    /// Frame rates within this ratio are one family (23.976 / 24, 29.97 /
    /// 30); 25 vs 23.976 is 4.3 % — a subtitle timed in the other family
    /// drifts by 2.5 min an hour.
    public static let frameRateTolerance = 0.02

    /// Why `row` does not fit `file` (nil: it fits, or nothing to compare).
    public static func inconsistency(of row: Subtitle, file: SubtitleFileContext) -> String? {
        if let duration = file.durationSeconds, let last = row.lastCueTime, last > duration + lastCueMargin {
            return String(format: "last cue at %.0f s, film %.0f s", last, duration)
        }
        if let video = file.frameRate, let movie = row.frameRate, !sameFrameRateFamily(video, movie) {
            return String(format: "%.3f fps, video %.3f fps", movie, video)
        }
        return nil
    }

    static func sameFrameRateFamily(_ a: Double, _ b: Double) -> Bool {
        var ratio = max(a, b) / min(a, b)
        // A field rate reported for a frame rate (50 vs 25): the same timing.
        if ratio > 1.9 { ratio /= 2 }
        return abs(ratio - 1) <= frameRateTolerance
    }

    /// The sort key: higher is better, compared element by element.
    private struct Key: Comparable {
        var values: [Double]
        static func < (lhs: Key, rhs: Key) -> Bool { lhs.values.lexicographicallyPrecedes(rhs.values) }
    }

    private static func key(for row: Subtitle, file: SubtitleFileContext, fileTraits: [ReleaseTraits],
                            hashRows: [Subtitle]) -> Key {
        let match = releaseMatch(row, fileTraits: fileTraits)
        // `SubtitlesManager.score`: format rank × 1e12 + not HI × 1e11 +
        // not bad × 1e10 + popularity (< 1e10).
        let tiers = (row.rating / 1e10).rounded(.down)
        return Key(values: [
            row.rating >= 2e12 ? 1 : 0,
            isHashMatch(row, hashRows: hashRows) ? 1 : 0,
            match.isStrong ? 1 : 0,
            inconsistency(of: row, file: file) == nil ? 1 : 0,
            tiers,
            Double(match.points),
            row.rating - tiers * 1e10,
        ])
    }

    // MARK: Release names

    /// What a release name says of the release.
    public struct ReleaseTraits: Equatable {
        /// The release group, lowercased ("sparks", "yts").
        public var group: String?
        /// "bluray", "webdl", "webrip", "hdtv", "dvd", "hdrip", "cam".
        public var source: String?
        /// "2160", "1080", "720", "sd".
        public var resolution: String?
        /// Cut-changing editions: "extended", "directors", "unrated", "uncut",
        /// "final", "special".
        public var editions: Set<String>
        /// The words of the name without extension nor trailing language
        /// tags: two names with the same words are the same release.
        public var words: [String]

        /// It names something of the release, not just a title.
        public var isInformative: Bool { group != nil || source != nil || resolution != nil || !editions.isEmpty }
    }

    /// How well a subtitle's release names match the file's.
    public struct ReleaseMatchLevel: Equatable {
        /// The same release: the same name, or the same group with no
        /// conflicting source or edition.
        public var isStrong: Bool
        /// Partial agreement: same source +2, same resolution +1, a
        /// conflicting edition −3 (another cut).
        public var points: Int

        public static let none = ReleaseMatchLevel(isStrong: false, points: 0)
    }

    /// The best match between the subtitle's `MovieReleaseName` /
    /// `SubFileName` and any of `names`.
    public static func releaseMatch(_ row: Subtitle, names: [String]) -> ReleaseMatchLevel {
        releaseMatch(row, fileTraits: informativeTraits(names))
    }

    /// The traits of the names that say something of the release.
    static func informativeTraits(_ names: [String]) -> [ReleaseTraits] {
        names.map(traits).filter(\.isInformative)
    }

    static func releaseMatch(_ row: Subtitle, fileTraits files: [ReleaseTraits]) -> ReleaseMatchLevel {
        guard !files.isEmpty else { return .none }
        let subs = [row.releaseName, row.fileName].compactMap { $0 }.map(traits)
        var best: ReleaseMatchLevel?
        for file in files where !file.words.isEmpty {
            for sub in subs where !sub.words.isEmpty {
                let level = compare(sub, file)
                if best == nil || (level.isStrong ? 1 : 0, level.points) > (best!.isStrong ? 1 : 0, best!.points) { best = level }
            }
        }
        return best ?? .none
    }

    static func compare(_ sub: ReleaseTraits, _ file: ReleaseTraits) -> ReleaseMatchLevel {
        // A file name that says nothing of its release ("movie.mkv", a
        // download folder) compares with nothing; a bare subtitle name
        // ("Game of Thrones S01E01") is no other cut.
        guard file.isInformative else { return .none }
        let editionConflict = sub.isInformative && sub.editions != file.editions
        let sourceConflict = sub.source != nil && file.source != nil && sub.source != file.source
        var points = 0
        if let source = sub.source, source == file.source { points += 2 }
        if let resolution = sub.resolution, resolution == file.resolution { points += 1 }
        if editionConflict { points -= 3 }
        // The same name says nothing more only when it says something: a
        // bare title ("Inception") is no release.
        let sameName = sub.words == file.words
        let sameGroup = sub.group != nil && sub.group == file.group
        let strong = sameName || (sameGroup && !sourceConflict && !editionConflict)
        return ReleaseMatchLevel(isStrong: strong, points: points)
    }

    /// The traits of a torrent, file or subtitle name.
    public static func traits(of name: String) -> ReleaseTraits {
        var text = strippingExtension(ReleaseMatch.decoded(name).trimmingCharacters(in: .whitespacesAndNewlines))
        // Trailing language / subtitle tags of a subtitle file name:
        // "….x264-GROUP.fre", "…MIKY-fre", "….en.forced".
        while let separator = text.lastIndex(where: { $0 == "." || $0 == "-" || $0 == "_" || $0 == " " }) {
            let tail = text[text.index(after: separator)...].lowercased()
            guard languageTags.contains(tail) else { break }
            text = String(text[..<separator])
        }
        // The words keep what brackets hold ("[1080p] [BluRay]"); the group
        // is read without the trailing ones ("[YTS.MX]", "[rarbg]", "[eztv]").
        let words = ReleaseMatch.words(text)
        var isYTS = words.contains { $0 == "yts" || $0 == "yify" }
        var groupText = text
        while groupText.hasSuffix("]") || groupText.hasSuffix(")"),
              let open = groupText.lastIndex(where: { $0 == "[" || $0 == "(" }) {
            let inner = ReleaseMatch.words(String(groupText[open...]))
            // A year in parentheses is the title's, not a tag: stop there.
            if inner.count == 1, ReleaseMatch.year(inner[0]) != nil { break }
            if inner.contains(where: { $0 == "yts" || $0 == "yify" }) { isYTS = true }
            groupText = String(groupText[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var traits = ReleaseTraits(group: nil, source: nil, resolution: nil, editions: [], words: words)
        var hasTechnical = false
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : nil
            if let source = source(word, next: next) {
                if traits.source == nil { traits.source = source }
                hasTechnical = true
            }
            if let resolution = resolution(word) {
                if traits.resolution == nil { traits.resolution = resolution }
                hasTechnical = true
            }
            if codecWords.contains(word) { hasTechnical = true }
            if let edition = edition(word, next: next) { traits.editions.insert(edition) }
        }
        traits.group = isYTS ? "yts" : group(of: groupText, words: ReleaseMatch.words(groupText), hasTechnical: hasTechnical)
        return traits
    }

    /// The group: "…x264-SPARKS" → sparks; else, after the technical tags,
    /// a last word that is none ("….720p.BluRay.x264.MIKY" → miky).
    static func group(of text: String, words: [String], hasTechnical: Bool) -> String? {
        if let dash = text.lastIndex(of: "-") {
            let candidate = ReleaseMatch.words(String(text[text.index(after: dash)...]))
            if candidate.count == 1, isGroupWord(candidate[0]) { return candidate[0] }
        }
        guard hasTechnical, let last = words.last, isGroupWord(last) else { return nil }
        return last
    }

    static func isGroupWord(_ word: String) -> Bool {
        guard (2...20).contains(word.count), !word.allSatisfy({ $0.isNumber }) else { return false }
        if ReleaseMatch.isTechnical(word) || codecWords.contains(word) || languageTags.contains(word) { return false }
        if resolution(word) != nil || source(word, next: nil) != nil || edition(word, next: nil) != nil { return false }
        if ["dl", "rip", "ray", "web", "hd", "sd", "ma", "dd", "ddp", "aac", "ac3", "dts", "atmos", "truehd"].contains(word) { return false }
        // A season / episode marker ("s01e01", "1x01") ends many names.
        if word.range(of: "^(s\\d{1,2}(e\\d{1,3})*|\\d{1,2}x\\d{2,3}|e\\d{1,3})$", options: .regularExpression) != nil { return false }
        return true
    }

    static func source(_ word: String, next: String?) -> String? {
        switch word {
        case "bluray", "bdrip", "brrip", "bdremux", "remux", "bd", "bdr", "bd25", "bd50": return "bluray"
        case "blu" where next == "ray": return "bluray"
        case "webdl": return "webdl"
        case "web": return next == "rip" ? "webrip" : "webdl"
        case "webrip": return "webrip"
        case "hdtv", "pdtv", "dsr", "dsrip", "tvrip", "satrip", "hdtvrip": return "hdtv"
        case "dvdrip", "dvd", "dvdr", "dvd5", "dvd9", "dvdscr": return "dvd"
        case "hdrip": return "hdrip"
        case "cam", "camrip", "hdcam", "telesync", "hdts": return "cam"
        default: return nil
        }
    }

    static func resolution(_ word: String) -> String? {
        switch word {
        case "2160p", "4k", "uhd": return "2160"
        case "1080p", "1080i": return "1080"
        case "720p": return "720"
        case "576p", "480p", "576i", "480i": return "sd"
        default: return nil
        }
    }

    /// Editions that change the cut, hence the timing. A theatrical,
    /// remastered, IMAX or Criterion release is usually the plain cut: not
    /// counted, so it does not conflict with an untagged subtitle.
    static func edition(_ word: String, next: String?) -> String? {
        switch word {
        case "extended", "unrated", "uncut": return word
        case "directors", "dc": return "directors"
        case "final" where next == "cut": return "final"
        case "special" where next == "edition": return "special"
        default: return nil
        }
    }

    static let codecWords: Set<String> = [
        "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "xvid", "divx", "10bit", "hdr", "hdr10", "dv",
    ]

    /// Tags ending a subtitle file's name, never a group.
    static let languageTags: Set<String> = [
        "fr", "fre", "fra", "french", "vf", "vff", "vostfr", "en", "eng", "english", "es", "spa", "spanish", "de", "ger",
        "deu", "german", "it", "ita", "italian", "pt", "por", "pob", "nl", "dut", "nld", "pl", "pol", "ru", "rus", "ar",
        "ara", "tr", "tur", "sv", "swe", "da", "dan", "no", "nor", "fi", "fin", "cs", "cze", "el", "gre", "he", "heb",
        "hu", "hun", "ro", "rum", "ron", "ja", "jpn", "ko", "kor", "zh", "chi", "zho", "forced", "hi", "sdh", "cc", "sub",
        "subs",
    ]

    static let knownExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "webm", "mk3d", "ts", "m2ts", "wmv", "mpg", "mpeg",
        "srt", "sub", "ass", "ssa", "vtt", "smi", "txt", "idx", "mpl", "torrent",
    ]

    static func strippingExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return knownExtensions.contains(ext) ? (name as NSString).deletingPathExtension : name
    }
}
