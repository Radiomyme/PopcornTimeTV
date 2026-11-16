import Foundation

// Episode chaining (5.3.0), the decisions: which episode comes after the one
// playing, and which release of it plays « in continuity » with the release
// watched. Pure: no network, no clock but the one passed in, no UserDefaults.
// The app's `UpNextSession` (one per playback) asks; the players only report
// where they are and show what they are told.
//
// The rules, in order (the first one with a candidate wins; the ranking `<`
// breaks ties inside a rule):
//   samePack        the season pack played holds the next episode: the same
//                   torrent again (its own file is picked by `WantedFile`)
//   sameGroup       same group, same resolution, same dynamic range
//   sameClass       same resolution, same dynamic range
//   sameResolution  same resolution
//   balanced        today's `Torrent.balancedPick`
//   none            nothing: the chooser
// Before them, NATIVE FIRST: a release only VLC plays (AVI / TS / WMV…,
// DTS or TrueHD with no Dolby / AAC track, a penalized codec) is left out
// while another one remains — even when it is the group played (a DTS-only
// episode that went through VLC is followed by a native release). Releases
// of another episode and theater recordings are always left out.

/// The dynamic range of a release.
public enum HDRClass: String, Codable {
    case dolbyVision = "dv", hdr10Plus = "hdr10+", hdr10 = "hdr10", hlg, sdr

    init(_ tags: VideoTags) {
        if tags.contains(.dolbyVision) { self = .dolbyVision }
        else if tags.contains(.hdr10Plus) { self = .hdr10Plus }
        else if tags.contains(.hdr10) { self = .hdr10 }
        else if tags.contains(.hlg) { self = .hlg }
        else { self = .sdr }
    }
}

/// What the planner compares two releases on.
public struct ReleaseProfile: Equatable {
    public enum Codec: String { case hevc, h264, av1, other }
    public enum Audio: String { case atmos, eac3, ac3, aac, dtsOnly, trueHDOnly, other }

    public let sourceKey: String
    public let resolution: VideoQuality
    public let hdr: HDRClass
    public let codec: Codec
    public let audio: Audio
    public let group: String?
    public let isMultiFile: Bool
    public let provider: String?
    /// The payload's container ("mkv", "avi"…), from its name; nil when unknown.
    public let container: String?
    /// The release is penalized on this device (software decode, DV without
    /// a base layer, CAM): see `PlayabilityAssessment`.
    public let isPenalized: Bool

    /// - Parameters:
    ///   - group: when known otherwise (a remembered release); default: read
    ///     from the release's name (`ReleaseName.group(of:)`).
    public init(_ torrent: Torrent, isMultiFile: Bool = false, group: String? = nil,
                capabilities: PlaybackCapabilities.Snapshot = PlaybackCapabilities.current) {
        let name = ReleaseProfile.name(of: torrent)
        sourceKey = MagnetLink.sourceKey(of: torrent.url)
        resolution = torrent.qualityValue
        hdr = HDRClass(torrent.tags)
        let tags = torrent.tags
        if tags.contains(.hevc) { codec = .hevc }
        else if tags.contains(.av1) { codec = .av1 }
        else if tags.contains(.h264) { codec = .h264 }
        else { codec = .other }
        audio = ReleaseProfile.audio(of: tags)
        self.group = group ?? name.flatMap(ReleaseName.group(of:))
        self.isMultiFile = isMultiFile
        provider = torrent.sourceLabel
        container = name.flatMap(ReleaseName.videoContainerExtension(of:)) ?? torrent.containerExtension
        isPenalized = torrent.playability(for: capabilities).isPenalized
    }

    static func audio(of tags: VideoTags) -> Audio {
        let compatible = !tags.intersection([.eac3, .ac3, .aac]).isEmpty
        if tags.contains(.atmos) && (tags.contains(.eac3) || (!tags.contains(.trueHD) && compatible)) { return .atmos }
        if tags.contains(.eac3) { return .eac3 }
        if tags.contains(.ac3) { return .ac3 }
        if tags.contains(.aac) { return .aac }
        if !tags.intersection([.dts, .dtsHD, .dtsX]).isEmpty { return .dtsOnly }
        if tags.contains(.trueHD) { return .trueHDOnly }
        return .other
    }

    /// The name a release is judged by: the source's file name, else the
    /// magnet's `dn`, else the last component of a .torrent URL or path
    /// (without ".torrent").
    public static func name(of torrent: Torrent) -> String? {
        if let name = torrent.releaseFileName ?? torrent.fileNameHint { return name }
        guard !torrent.url.lowercased().hasPrefix("magnet:") else { return nil }
        var leaf = WantedFile.leafName(torrent.url.components(separatedBy: "?").first ?? torrent.url)
        if leaf.lowercased().hasSuffix(".torrent") { leaf = String(leaf.dropLast(8)) }
        return leaf.isEmpty ? nil : leaf
    }

    /// Why only VLC plays this release ("AVI", "DTS only", "TrueHD only",
    /// "penalized"); nil when the native player does (AVPlayer, or the remux
    /// feeding it).
    public var vlcOnlyReason: String? {
        if let container = container, ReleaseName.legacyVideoExtensions.contains(container) { return container.uppercased() }
        if audio == .dtsOnly { return "DTS only" }
        if audio == .trueHDOnly { return "TrueHD only" }
        if isPenalized { return "penalized" }
        return nil
    }

    /// "1080p SDR", "2160p DV".
    var classLabel: String {
        let resolution = self.resolution == .unknown ? "?p" : self.resolution.displayLabel
        return "\(resolution) \(hdr == .sdr ? "SDR" : hdr.rawValue.uppercased())"
    }
}

/// What the planner chose for the next episode.
public struct UpNextChoice: Equatable {
    public enum Rule: String {
        case samePack, sameGroup, sameClass, sameResolution, balanced, none
    }

    /// nil with `.none`.
    public let torrent: Torrent?
    public let rule: Rule
    /// Why, in plain words: the `[UpNext]` line says them.
    public let reasons: [String]

    public init(torrent: Torrent?, rule: Rule, reasons: [String]) {
        self.torrent = torrent
        self.rule = rule
        self.reasons = reasons
    }

    /// A release clearly in continuity with the one played: played without
    /// asking even where the setting is « Always Ask » (a Home « Next
    /// episode » card, decision D4).
    public var isClearContinuity: Bool {
        return rule == .samePack || rule == .sameGroup || rule == .sameClass
    }

    /// "[UpNext] plan S01E02 rule=samePack torrent=1080p HEVC (ab12cd34) in 0.2 s — reason; reason".
    public func logLine(next: EpisodeNumber, elapsed: TimeInterval?) -> String {
        let name = String(format: "S%02dE%02d", next.season, next.episode)
        let torrentText = torrent.map { "\($0.quality ?? "?") (\(String(MagnetLink.sourceKey(of: $0.url).suffix(12))))" } ?? "none"
        let time = elapsed.map { String(format: " in %.1f s", $0) } ?? ""
        return "[UpNext] plan \(name) rule=\(rule.rawValue) torrent=\(torrentText)\(time)"
            + (reasons.isEmpty ? "" : " — " + reasons.joined(separator: "; "))
    }
}

public enum UpNextPlanner {

    /// The episode proposed after `current` (decision D1): the next one in
    /// the guide, later seasons included; never a special (season 0), never
    /// one that cannot be played yet (`GuideEpisode.isAvailable`: an
    /// announced episode stops the chain, it is not stepped over). nil after
    /// the last one, and after a special.
    public static func episode(after current: EpisodeNumber, guide: [GuideEpisode], now: Date) -> GuideEpisode? {
        guard !current.isSpecial else { return nil }
        var byNumber: [EpisodeNumber: GuideEpisode] = [:]
        for episode in guide where !episode.number.isSpecial && episode.number > current && episode.episode > 0 {
            if let known = byNumber[episode.number], known.hasSource || !episode.hasSource { continue }
            byNumber[episode.number] = episode
        }
        guard let next = byNumber.keys.min().flatMap({ byNumber[$0] }), next.isAvailable(at: now) else { return nil }
        return next
    }

    /// The release of `next` in continuity with `playing`.
    ///
    /// - Parameters:
    ///   - playing: the release played (or remembered: `RememberedRelease.packTorrent`).
    ///   - profile: what `playing` is compared on (default: read from it;
    ///     a remembered release passes its own, with its group).
    ///   - packFiles: the files of `playing`'s torrent when captured.
    ///   - candidates: `next`'s releases, merged as the chooser merges them.
    ///   - excluded: source keys left out (sources that did not answer).
    ///   - connection: the measured rate (bytes/s), for `balancedPick`.
    public static func continuity(playing: Torrent, profile given: ReleaseProfile? = nil, packFiles: PackFiles?,
                                  next: EpisodeNumber, candidates: [Torrent], excluded: Set<String> = [],
                                  connection: Double? = StreamBandwidth.connectionEstimate,
                                  capabilities: PlaybackCapabilities.Snapshot = PlaybackCapabilities.current) -> UpNextChoice {
        let profile = given ?? ReleaseProfile(playing, isMultiFile: packFiles?.isMultiFile ?? false, capabilities: capabilities)
        let label = String(format: "S%02dE%02d", next.season, next.episode)
        var reasons: [String] = []
        let playedVLCOnly = profile.vlcOnlyReason

        // The candidates: not excluded, not another episode, not a recording.
        let keep = candidates.filter { !excluded.contains(MagnetLink.sourceKey(of: $0.url)) }
        if keep.count < candidates.count {
            reasons.append("\(candidates.count - keep.count) excluded (source did not answer)")
        }
        var pool = keep.filter { torrent in
            guard !torrent.tags.contains(.cam) else { return false }
            guard let name = ReleaseProfile.name(of: torrent) else { return true }
            return ReleaseName.episodeScope(of: name, season: next.season, episode: next.episode) != .otherEpisode
        }
        let profiles = Dictionary(pool.map { ($0.url, ReleaseProfile($0, capabilities: capabilities)) }, uniquingKeysWith: { a, _ in a })
        let native = pool.filter { profiles[$0.url]?.vlcOnlyReason == nil }

        // 1. The same pack.
        if let files = packFiles, files.isMultiFile, let wanted = WantedFile(season: next.season, episode: next.episode) {
            let choice = wanted.choice(fileNames: files.names, fileSizes: files.sizes,
                                       preferredIndex: MagnetLink.selectedFileIndex(of: playing.url),
                                       torrentName: MagnetLink.displayName(of: playing.url))
            switch choice {
            case .file(let index):
                let leaf = WantedFile.leafName(files.names[index])
                if playedVLCOnly == nil || native.isEmpty {
                    reasons.insert("same pack: file #\(index) \(leaf)", at: 0)
                    if let why = playedVLCOnly { reasons.append("the pack \(notNativeText(why)), no native release known") }
                    return UpNextChoice(torrent: packTorrent(playing, fileSize: files.sizes?[index]), rule: .samePack, reasons: reasons)
                }
                reasons.append("the pack holds \(label) but \(notNativeText(playedVLCOnly ?? "?")): a native release first")
            case .notInTorrent:
                reasons.append("the pack does not hold \(label)")
            case .usualRule:
                reasons.append("the pack's files do not name \(label)")
            }
        }
        // The same torrent listed by a source for this episode (a pack whose
        // file list was not captured): the same pack too.
        if let same = pool.first(where: { MagnetLink.sourceKey(of: $0.url) == profile.sourceKey }),
           playedVLCOnly == nil || native.isEmpty,
           let name = ReleaseProfile.name(of: same),
           ReleaseName.episodeScope(of: name, season: next.season, episode: next.episode) == .requestedEpisode {
            reasons.insert("same pack: listed for \(label)", at: 0)
            return UpNextChoice(torrent: same, rule: .samePack, reasons: reasons)
        }

        // Native first.
        if !native.isEmpty, native.count < pool.count {
            var why: [String: Int] = [:]
            for torrent in pool { if let reason = profiles[torrent.url]?.vlcOnlyReason { why[reason, default: 0] += 1 } }
            let detail = why.keys.sorted().map { "\($0) \(why[$0] ?? 0)" }.joined(separator: ", ")
            reasons.append("native first: \(pool.count - native.count) left out (\(detail))")
            pool = native
        }
        if let why = playedVLCOnly {
            reasons.append("the release played is not native (\(why))")
        }
        guard !pool.isEmpty else {
            reasons.append("no release of \(label)")
            return UpNextChoice(torrent: nil, rule: .none, reasons: reasons)
        }

        // 2-4. Same group, same class, same resolution. A rule whose
        // releases have no seeder gives way to the next rule while the pool
        // has a seeded one (a dead release of the same group is not « in
        // continuity »); a pool with no seed count at all keeps them.
        let poolHasSeeds = pool.contains { $0.seeds > 0 }
        func best(_ matches: [Torrent]) -> Torrent? {
            let seeded = matches.filter { $0.seeds > 0 }
            if seeded.isEmpty && poolHasSeeds { return nil }
            let light = seeded.filter { !$0.bandwidthFit(connection: connection).isTooHeavy }
            let pick = light.isEmpty ? (seeded.isEmpty ? matches : seeded) : light
            return pick.max { Torrent.ranksBelow($0, $1, capabilities: capabilities) }
        }
        let sameResolution = pool.filter { profiles[$0.url]?.resolution == profile.resolution }
        let sameClass = sameResolution.filter { profiles[$0.url]?.hdr == profile.hdr }
        if let group = profile.group?.lowercased(),
           let pick = best(sameClass.filter { profiles[$0.url]?.group?.lowercased() == group }) {
            reasons.insert("group \(profile.group ?? group), \(profile.classLabel)", at: 0)
            return UpNextChoice(torrent: pick, rule: .sameGroup, reasons: reasons)
        }
        if let pick = best(sameClass) {
            reasons.insert(profile.group.map { "no \($0) release, \(profile.classLabel)" } ?? profile.classLabel, at: 0)
            return UpNextChoice(torrent: pick, rule: .sameClass, reasons: reasons)
        }
        if let pick = best(sameResolution) {
            let found = profiles[pick.url].map { $0.hdr == .sdr ? "SDR" : $0.hdr.rawValue.uppercased() } ?? "?"
            reasons.insert("\(profile.classLabel) not found, \(found) at the same resolution", at: 0)
            return UpNextChoice(torrent: pick, rule: .sameResolution, reasons: reasons)
        }
        // 5. Today's balanced pick.
        if let pick = Torrent.balancedPick(from: pool, capabilities: capabilities, connection: connection) {
            reasons.insert("no \(profile.resolution == .unknown ? "?p" : profile.resolution.displayLabel) release: balanced pick", at: 0)
            return UpNextChoice(torrent: pick, rule: .balanced, reasons: reasons)
        }
        reasons.append("no release of \(label)")
        return UpNextChoice(torrent: nil, rule: .none, reasons: reasons)
    }

    /// Why a release is not native first, for the `[UpNext]` line: a
    /// penalized one (software decoding, DV without a base layer) may still
    /// play on the native player — it is not said to go through VLC.
    static func notNativeText(_ why: String) -> String {
        return why == "penalized" ? "is penalized here (software decoding or no DV base layer)" : "plays through VLC (\(why))"
    }

    /// `playing` again, for another file of its pack: no file name (the
    /// stream picks the episode's own), the size of that file when known.
    static func packTorrent(_ playing: Torrent, fileSize: Int64?) -> Torrent {
        var torrent = Torrent(health: playing.health, url: playing.url, quality: playing.quality ?? "", seeds: playing.seeds,
                              peers: playing.peers, size: fileSize.map(sizeLabel), tags: playing.tags, fileName: nil)
        torrent.qualityValue = playing.qualityValue
        return torrent
    }

    /// "1.23 GB", "300.0 MB": what `StreamBandwidth.bytes(fromSizeLabel:)` reads back.
    static func sizeLabel(_ bytes: Int64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        return gib >= 1 ? String(format: "%.2f GB", gib) : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - The release group

public extension ReleaseName {

    /// The group of a release from its name: the last "-GROUP" token
    /// ("Show.S01E02.1080p.WEB.h264-NTb.mkv" → "NTb"), else a group in
    /// brackets at the end ("… [Prof]") or at the start ("[SubsPlease] Show
    /// - 05"), the extension and site tags ("[eztv]", "[rartv]") left out.
    /// nil when the name has none (an anime "Show - 05 (1080p).mkv", "WEB-DL").
    static func group(of raw: String) -> String? {
        var name = WantedFile.leafName(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if let ext = videoContainerExtension(of: name) ?? groupTrailingExtension(of: name) {
            name = String(name.dropLast(ext.count + 1))
        }
        var leading: String?
        if name.hasPrefix("["), let close = name.firstIndex(of: "]") {
            let inside = String(name[name.index(after: name.startIndex)..<close])
            if isGroupToken(inside) { leading = inside }
        }
        // Trailing brackets: a site tag goes, a lone token is the group,
        // anything else ("(1080p)", "(2160p x265 10bit)") goes.
        while let last = name.last, last == "]" || last == ")" {
            let open: Character = last == "]" ? "[" : "("
            guard let start = name.lastIndex(of: open) else { break }
            let inside = String(name[name.index(after: start)..<name.index(before: name.endIndex)])
            name = String(name[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            if last == "]", !isSiteTag(inside), isGroupToken(inside) { return inside }
        }
        if let dash = name.lastIndex(of: "-") {
            var tail = String(name[name.index(after: dash)...])
            // "MkvCage.ws": the group, not its site. More than that after a
            // dash is a title ("Spider-Man.No.Way.Home.2021").
            let pieces = tail.split(separator: ".", omittingEmptySubsequences: false)
            if pieces.count == 2, (2...3).contains(pieces[1].count), pieces[1].allSatisfy({ $0.isLetter && $0.isLowercase }) {
                tail = String(pieces[0])
            }
            if pieces.count <= 2, isGroupToken(tail) { return tail }
        }
        return leading
    }

    /// A lone word of 2-24 letters / digits that is not a technical token.
    private static func isGroupToken(_ text: String) -> Bool {
        guard (2...24).contains(text.count),
              text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }),
              text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        let lower = text.lowercased()
        if groupNotWords.contains(lower) || isSiteTag(lower) { return false }
        // An anime release's checksum, "[ABCD1234]".
        if text.count == 8, text.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789ABCDEFabcdef").contains($0) }) {
            return false
        }
        // "1080p", "x265", "10bit", "S01E01", "E03", "5.1"-like tokens.
        if lower.range(of: "^(\\d{3,4}p|[xh]26[45]|\\d+bits?|s\\d+(e\\d+)?|e\\d+|\\d+ch|ddp?\\d*|aac\\d*|ac3|eac3)$",
                       options: .regularExpression) != nil { return false }
        return true
    }

    private static func isSiteTag(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["eztv", "eztv.io", "eztv.re", "eztvx.to", "rartv", "rarbg.com", "ettv", "tgx", "publichd", "ettv.to"].contains(lower)
            || lower.hasPrefix("eztv") || lower.hasPrefix("www.")
    }

    /// A short extension that is not a video's ("nfo", "srt").
    private static func groupTrailingExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        return ["srt", "nfo", "txt", "torrent"].contains(ext) ? ext : nil
    }

    private static let groupNotWords: Set<String> = [
        "dl", "rip", "web", "webrip", "webdl", "hd", "ma", "ray", "dts", "audio", "sd", "dvd", "bd", "hdr", "hdr10", "dv",
        "dovi", "atmos", "hevc", "avc", "aac", "remux", "bluray", "uhd", "sdr", "repack", "proper", "multi", "vostfr",
        "truefrench", "french", "x", "h", "es", "en", "fr", "ita", "eng", "sub", "subs", "dub", "dubbed", "rus", "ger",
        "lat", "dual", "complete", "season", "batch", "mp4", "mkv", "avi", "hdtv", "hdrip", "brrip", "bdrip", "dvdrip",
        "720p", "1080p", "2160p", "4k", "imax", "internal", "extended", "uncut", "hybrid", "nf", "amzn", "hmax", "dsnp",
    ]
}

// MARK: - « Resume » and the Home cards

/// What « Resume » (decision D2) and a Home « Next episode » card (decision
/// D4) replay without asking: the release remembered with the title, the
/// show's pack, or a release of the episode in clear continuity with the
/// show's last one. The same rule on the three platforms.
public enum UpNextResume {

    public enum Rule: String {
        /// The release the title was played from (« Resume »).
        case sameRelease
        /// The season pack the show was played from holds this episode.
        case samePack
        /// An episode not started: a release of its own, in clear
        /// continuity with the show's last one (same group or same class,
        /// `UpNextChoice.isClearContinuity`, D4). Not a remembered release:
        /// no shorter patience, nothing to forget if it fails.
        case continuity
    }

    public struct Choice {
        public let torrent: Torrent
        /// The release remembered: the title's own, or the show's last one
        /// (`.samePack`, `.continuity`).
        public let release: RememberedRelease
        public let rule: Rule
        /// How old the remembered release is, in seconds.
        public let age: TimeInterval
        /// `.continuity`: what the planner said.
        public let planned: UpNextChoice?

        /// The remembered release itself replays (`.sameRelease`,
        /// `.samePack`): it is waited for `patience` (D5) and forgotten when
        /// it fails (`Library.forgetRelease(_:sourceKey:)`).
        public var replaysRemembered: Bool { rule != .continuity }

        /// "[UpNext] resume tt…-s1e2 rule=sameRelease release=1080p HEVC (ab12cd34) age 3 h".
        public func logLine(mediaID: String) -> String {
            let hours = age / 3600
            let ageText = hours < 1 ? "\(Int(age / 60)) min" : String(format: "%.0f h", hours)
            var line = "[UpNext] resume \(mediaID) rule=\(rule.rawValue) release=\(release.quality ?? "?") "
                + "(\(String(release.sourceKey.suffix(12)))) age \(ageText)"
            if let planned = planned {
                line += " → \(planned.rule.rawValue) \(torrent.quality ?? "?")"
                    + (planned.reasons.isEmpty ? "" : " — " + planned.reasons.joined(separator: "; "))
            }
            return line
        }
    }

    /// How long a remembered release that does not answer is waited for
    /// before « Choose another source » (decision D5; 45 s for any other).
    public static let patience: TimeInterval = 20

    /// The release to replay for `mediaID` (an episode "tt…-sXeY" or a
    /// movie), in this order:
    ///   1. its own entry's (`.sameRelease`);
    ///   2. an episode not started: the show's latest release when it is a
    ///      pack that holds the episode (`.samePack`) — NATIVE FIRST: a pack
    ///      only VLC plays (`ReleaseProfile.vlcOnlyReason`) waits for the
    ///      episode's releases (`candidates`) and replays only when none of
    ///      them is native;
    ///   3. with `candidates`: the release of them in clear continuity with
    ///      the show's latest one (`.continuity`, D4).
    /// nil: the usual flow (sources, chooser / automatic quality).
    ///
    /// - Parameters:
    ///   - candidates: the episode's releases when known (nil: not yet —
    ///     a caller asks again once they are in).
    ///   - excluded: source keys left out (sources that did not answer).
    public static func choice(mediaID: String, candidates: [Torrent]? = nil, excluded: Set<String> = [],
                              library: Library = .shared, now: Date = Date(),
                              capabilities: PlaybackCapabilities.Snapshot = PlaybackCapabilities.current) -> Choice? {
        if let release = library.rememberedRelease(for: mediaID) {
            return Choice(torrent: release.torrent, release: release, rule: .sameRelease,
                          age: max(0, now.timeIntervalSince(release.savedAt)), planned: nil)
        }
        guard let (showID, number) = LibraryID.episode(mediaID),
              let release = library.rememberedRelease(ofShow: showID) else { return nil }
        let age = max(0, now.timeIntervalSince(release.savedAt))
        if release.packHolds(number) == true, !excluded.contains(release.sourceKey) {
            let profile = ReleaseProfile(release.packTorrent, isMultiFile: release.isMultiFile, group: release.group,
                                         capabilities: capabilities)
            if profile.vlcOnlyReason == nil {
                return Choice(torrent: release.packTorrent, release: release, rule: .samePack, age: age, planned: nil)
            }
            if let candidates = candidates, !hasNativeRelease(of: number, in: candidates, excluded: excluded,
                                                              capabilities: capabilities) {
                return Choice(torrent: release.packTorrent, release: release, rule: .samePack, age: age, planned: nil)
            }
        }
        guard let candidates = candidates, !candidates.isEmpty else { return nil }
        let planned = UpNextPlanner.continuity(playing: release.packTorrent,
                                               profile: ReleaseProfile(release.packTorrent, isMultiFile: release.isMultiFile,
                                                                       group: release.group, capabilities: capabilities),
                                               packFiles: nil, next: number, candidates: candidates, excluded: excluded,
                                               capabilities: capabilities)
        guard planned.isClearContinuity, let torrent = planned.torrent else { return nil }
        return Choice(torrent: torrent, release: release, rule: .continuity, age: age, planned: planned)
    }

    /// A release of episode `number` among `candidates` that the native
    /// player reads (not another episode's, not a recording, not excluded).
    static func hasNativeRelease(of number: EpisodeNumber, in candidates: [Torrent], excluded: Set<String>,
                                 capabilities: PlaybackCapabilities.Snapshot) -> Bool {
        return candidates.contains { torrent in
            guard !excluded.contains(MagnetLink.sourceKey(of: torrent.url)), !torrent.tags.contains(.cam) else { return false }
            if let name = ReleaseProfile.name(of: torrent),
               ReleaseName.episodeScope(of: name, season: number.season, episode: number.episode) == .otherEpisode { return false }
            return ReleaseProfile(torrent, capabilities: capabilities).vlcOnlyReason == nil
        }
    }
}
