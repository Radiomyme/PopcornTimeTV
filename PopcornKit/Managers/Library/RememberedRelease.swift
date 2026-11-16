import Foundation

// The release a title was played from, remembered with its Continue Watching
// entry ("rl"), so that « Resume », the Home cards and the next episode play it
// again without asking (episode chaining, 5.3.0).
//
//   PackFiles                 the files of a multi-file torrent, captured when
//                             the stream picks its file (PTTorrentStreamer+Current)
//   RememberedRelease         what is stored: a SHORT magnet (tvOS keeps the whole
//                             preferences domain under 1 MB), the file played, the
//                             quality, the group, the episodes a pack holds
//   PlaybackReleaseRegistry   the release of the stream playing now, in memory:
//                             `PlaybackDetails(media:)` reads it, so every player's
//                             save (`PlaybackRecorder.save`) stores it unchanged

/// The files of a multi-file torrent, in torrent order (their paths inside
/// the torrent), and their sizes when known.
public struct PackFiles: Equatable {
    public let names: [String]
    public let sizes: [Int64]?

    public init(names: [String], sizes: [Int64]? = nil) {
        self.names = names
        self.sizes = sizes.flatMap { $0.count == names.count ? $0 : nil }
    }

    /// More than one file.
    public var isMultiFile: Bool { names.count > 1 }

    /// The episodes the pack's video files name on their own ("S01E03"),
    /// samples left out. What `RememberedRelease.packEpisodes` keeps.
    public var episodes: [EpisodeNumber] {
        var found = Set<EpisodeNumber>()
        for name in names where ReleaseName.isVideoFile(name) && !WantedFile.isCalledSample(name) {
            if let marked = ReleaseName.singleEpisode(of: WantedFile.leafName(name)), marked.episode > 0 {
                found.insert(EpisodeNumber(season: marked.season, episode: marked.episode))
            }
        }
        return found.sorted()
    }
}

/// A release played, as stored in a Continue Watching entry (key "rl").
/// Short keys, no nil written: on tvOS the entries live in UserDefaults.
public struct RememberedRelease: Codable, Equatable {

    /// `MagnetLink.sourceKey` of the link: the info-hash (lower case), or the
    /// URL / path of a .torrent.
    public var sourceKey: String
    /// A magnet REBUILT short (`shortenedLink`): xt, dn, so=, a few trackers;
    /// or the .torrent URL / path as it was.
    public var link: String
    /// The file played in a multi-file torrent (its leaf name, ≤ 80
    /// characters); nil for a single-file torrent.
    public var fileName: String?
    /// The quality label without its source ("1080p HEVC DD+").
    public var quality: String?
    /// `VideoTags.rawValue`.
    public var tags: Int
    /// The size label as the source gave it.
    public var size: String?
    /// Where the release was found ("TPB", "T4P", a Torrentio indexer).
    public var provider: String?
    /// The release group (`ReleaseName.group(of:)`).
    public var group: String?
    public var isMultiFile: Bool
    /// The episodes a season pack holds ("1:1-10"), when known: what lets a
    /// Home « Next episode » card replay the same pack without asking.
    public var packEpisodes: String?
    public var savedAt: Date

    public init(sourceKey: String, link: String, fileName: String? = nil, quality: String? = nil, tags: Int = 0,
                size: String? = nil, provider: String? = nil, group: String? = nil, isMultiFile: Bool = false,
                packEpisodes: String? = nil, savedAt: Date) {
        self.sourceKey = sourceKey
        self.link = link
        self.fileName = fileName
        self.quality = quality
        self.tags = tags
        self.size = size
        self.provider = provider
        self.group = group
        self.isMultiFile = isMultiFile
        self.packEpisodes = packEpisodes
        self.savedAt = savedAt
    }

    /// The release of `torrent`; `files`: its file list when captured,
    /// `playedIndex`: the file streamed in it.
    public init(torrent: Torrent, files: PackFiles?, playedIndex: Int?, at date: Date) {
        let multi = files?.isMultiFile ?? false
        var played: String?
        if multi, let files = files, let index = playedIndex, files.names.indices.contains(index) {
            played = RememberedRelease.clip(WantedFile.leafName(files.names[index]), to: 80)
        } else if multi, let name = torrent.releaseFileName {
            played = RememberedRelease.clip(WantedFile.leafName(name), to: 80)
        }
        self.init(sourceKey: MagnetLink.sourceKey(of: torrent.url),
                  link: RememberedRelease.shortenedLink(torrent.url),
                  fileName: played,
                  quality: torrent.qualityLabel.isEmpty ? nil : RememberedRelease.clip(torrent.qualityLabel, to: 40),
                  tags: torrent.tags.rawValue,
                  size: torrent.size.map { RememberedRelease.clip($0, to: 16) },
                  provider: torrent.sourceLabel.map { RememberedRelease.clip($0, to: 24) },
                  group: ReleaseName.group(of: ReleaseProfile.name(of: torrent) ?? "").map { RememberedRelease.clip($0, to: 24) },
                  isMultiFile: multi,
                  packEpisodes: multi ? files.flatMap { RememberedRelease.encode(episodes: $0.episodes) } : nil,
                  savedAt: date)
    }

    /// The release, playable as it is: the same torrent, the same file (for
    /// « Resume » of the same title).
    public var torrent: Torrent {
        return makeTorrent(fileName: fileName)
    }

    /// The same torrent for ANOTHER episode of its pack: no file name (the
    /// stream then picks the episode's own file, `WantedFile`).
    public var packTorrent: Torrent {
        return makeTorrent(fileName: nil)
    }

    private func makeTorrent(fileName: String?) -> Torrent {
        let label = (quality ?? "") + (provider.map { Torrent.sourceSeparator + $0 } ?? "")
        return Torrent(url: link, quality: label, size: isMultiFile && fileName == nil ? nil : size,
                       tags: VideoTags(rawValue: tags), fileName: fileName)
    }

    /// Whether the pack holds that episode (nil: unknown, not a pack).
    public func packHolds(_ number: EpisodeNumber) -> Bool? {
        guard isMultiFile, let packEpisodes = packEpisodes else { return nil }
        return RememberedRelease.decode(episodes: packEpisodes).contains(number)
    }

    /// What `ReleaseProfile` the planner compares the next episode's releases with.
    public var profile: ReleaseProfile {
        return ReleaseProfile(torrent, isMultiFile: isMultiFile, group: group)
    }

    // MARK: Short keys

    private enum CodingKeys: String, CodingKey {
        case sourceKey = "k", link = "l", fileName = "f", quality = "q", tags = "t", size = "z", provider = "p"
        case group = "g", isMultiFile = "m", packEpisodes = "pe", savedAt = "d"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        link = try container.decode(String.self, forKey: .link)
        sourceKey = try container.decodeIfPresent(String.self, forKey: .sourceKey) ?? MagnetLink.sourceKey(of: link)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        quality = try container.decodeIfPresent(String.self, forKey: .quality)
        tags = try container.decodeIfPresent(Int.self, forKey: .tags) ?? 0
        size = try container.decodeIfPresent(String.self, forKey: .size)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        isMultiFile = try container.decodeIfPresent(Bool.self, forKey: .isMultiFile) ?? false
        packEpisodes = try container.decodeIfPresent(String.self, forKey: .packEpisodes)
        savedAt = Date(timeIntervalSince1970: try container.decodeIfPresent(Double.self, forKey: .savedAt) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The key is the link's own unless it says otherwise: not written twice.
        if sourceKey != MagnetLink.sourceKey(of: link) { try container.encode(sourceKey, forKey: .sourceKey) }
        try container.encode(link, forKey: .link)
        try container.encodeIfPresent(fileName, forKey: .fileName)
        try container.encodeIfPresent(quality, forKey: .quality)
        if tags != 0 { try container.encode(tags, forKey: .tags) }
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(group, forKey: .group)
        if isMultiFile { try container.encode(true, forKey: .isMultiFile) }
        try container.encodeIfPresent(packEpisodes, forKey: .packEpisodes)
        try container.encode(savedAt.timeIntervalSince1970.rounded(), forKey: .savedAt)
    }

    // MARK: The short magnet

    /// Encoded `dn` at most this long, trackers at most this long in all.
    /// (200 entries with the longest recorded names and trackers stay under
    /// 100 KB added: RememberedReleaseTests.)
    static let displayNameBytes = 72
    static let trackerBytes = 96
    static let maxTrackers = 3

    /// A magnet rebuilt short: `xt`, `dn` (cut to `displayNameBytes` once
    /// encoded), the BEP 53 `so=` when there is one, and its first trackers
    /// (at most 3, `trackerBytes` in all; PopcornTorrent adds its public
    /// trackers to every public torrent). The info-hash is the same, so is
    /// `MagnetLink.sourceKey`. Anything but a magnet is returned as it is (a
    /// .torrent URL or path).
    public static func shortenedLink(_ link: String) -> String {
        guard link.lowercased().hasPrefix("magnet:"), link.range(of: "btih:", options: .caseInsensitive) != nil else { return link }
        let hash = MagnetLink.sourceKey(of: link)
        var parts = ["xt=urn:btih:\(hash)"]
        if let name = MagnetLink.displayName(of: link) {
            parts.append("dn=" + encodedDisplayName(name))
        }
        if let so = MagnetLink.rawParameters("so", in: link).first, !so.isEmpty {
            parts.append("so=\(so)")
        }
        var used = 0, kept = 0
        for tracker in MagnetLink.rawParameters("tr", in: link) {
            guard kept < maxTrackers else { break }
            let value = String(tracker)
            guard !value.isEmpty, used + value.utf8.count <= trackerBytes else { continue }
            used += value.utf8.count
            kept += 1
            parts.append("tr=\(value)")
        }
        return "magnet:?" + parts.joined(separator: "&")
    }

    /// `name` percent-encoded ("+" for a space, as the providers write it),
    /// characters dropped from its end until it fits `displayNameBytes`.
    static func encodedDisplayName(_ name: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~ ")
        allowed.remove(charactersIn: "+")
        func encode(_ text: Substring) -> String {
            let encoded = String(text).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return encoded.replacingOccurrences(of: " ", with: "+")
        }
        var text = Substring(name)
        var result = encode(text)
        while result.utf8.count > displayNameBytes, !text.isEmpty {
            text = text.dropLast()
            result = encode(text)
        }
        return result
    }

    static func clip(_ text: String, to length: Int) -> String {
        return text.count <= length ? text : String(text.prefix(length))
    }

    // MARK: The pack's episodes, compact

    /// "1:1-10,12;2:1-3": seasons, then episodes and ranges.
    static func encode(episodes: [EpisodeNumber]) -> String? {
        guard !episodes.isEmpty else { return nil }
        var bySeason: [Int: [Int]] = [:]
        for number in episodes { bySeason[number.season, default: []].append(number.episode) }
        var seasons: [String] = []
        for season in bySeason.keys.sorted() {
            let numbers = Array(Set(bySeason[season] ?? [])).sorted()
            var runs: [String] = []
            var start = numbers[0], last = numbers[0]
            for number in numbers.dropFirst() {
                if number == last + 1 { last = number; continue }
                runs.append(start == last ? "\(start)" : "\(start)-\(last)")
                start = number
                last = number
            }
            runs.append(start == last ? "\(start)" : "\(start)-\(last)")
            seasons.append("\(season):" + runs.joined(separator: ","))
        }
        let text = seasons.joined(separator: ";")
        return text.count <= 200 ? text : nil
    }

    static func decode(episodes text: String) -> Set<EpisodeNumber> {
        var result = Set<EpisodeNumber>()
        for season in text.split(separator: ";") {
            let parts = season.split(separator: ":")
            guard parts.count == 2, let number = Int(parts[0]) else { continue }
            for run in parts[1].split(separator: ",") {
                let bounds = run.split(separator: "-").compactMap { Int($0) }
                guard let first = bounds.first, let last = bounds.last, first <= last, last - first < 1000 else { continue }
                for episode in first...last { result.insert(EpisodeNumber(season: number, episode: episode)) }
            }
        }
        return result
    }
}

/// The release of the stream playing now, in memory, by media id; and the
/// file list of each torrent a stream opened, by source key (captured on
/// libtorrent's thread when the stream picks its file). Thread-safe.
///
/// Written by `PlaybackStreamContext.attach` (every stream, every platform)
/// and by the file selection (`PTTorrentStreamer.fileSelection`); read by
/// `PlaybackDetails(media:)`, hence by every save of the five players.
public enum PlaybackReleaseRegistry {

    private struct Noted {
        var torrent: Torrent
        var at: Date
    }

    private static let lock = NSLock()
    private static var byMedia: [String: Noted] = [:]
    private static var mediaOrder: [String] = []
    private static var filesByKey: [String: (files: PackFiles, played: Int?)] = [:]
    private static var keyOrder: [String] = []
    /// How many titles and file lists are kept (the latest).
    static let capacity = 8

    /// `torrent` is what `mediaID` plays now.
    public static func note(_ torrent: Torrent, for mediaID: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        byMedia[mediaID] = Noted(torrent: torrent, at: date)
        mediaOrder.removeAll { $0 == mediaID }
        mediaOrder.append(mediaID)
        while mediaOrder.count > capacity { byMedia[mediaOrder.removeFirst()] = nil }
    }

    /// The torrent of `link` holds `files`; the stream plays `playedIndex`
    /// (nil: no file, "not in this torrent"). Any thread.
    public static func noteFiles(_ files: PackFiles, playedIndex: Int?, forLink link: String) {
        let key = MagnetLink.sourceKey(of: link)
        lock.lock(); defer { lock.unlock() }
        filesByKey[key] = (files, playedIndex)
        keyOrder.removeAll { $0 == key }
        keyOrder.append(key)
        while keyOrder.count > capacity { filesByKey[keyOrder.removeFirst()] = nil }
    }

    /// The file list captured for the torrent of `link`, nil when none was.
    public static func packFiles(forLink link: String) -> PackFiles? {
        lock.lock(); defer { lock.unlock() }
        return filesByKey[MagnetLink.sourceKey(of: link)]?.files
    }

    /// The torrent `mediaID` plays (nil: no stream of it noted).
    public static func torrent(for mediaID: String) -> Torrent? {
        lock.lock(); defer { lock.unlock() }
        return byMedia[mediaID]?.torrent
    }

    /// What `mediaID`'s Continue Watching entry remembers of the release it
    /// plays now; nil when no stream of it was noted.
    public static func current(for mediaID: String, at date: Date = Date()) -> RememberedRelease? {
        lock.lock()
        let noted = byMedia[mediaID]
        let files = noted.flatMap { filesByKey[MagnetLink.sourceKey(of: $0.torrent.url)] }
        lock.unlock()
        guard let noted = noted, !noted.torrent.url.isEmpty else { return nil }
        return RememberedRelease(torrent: noted.torrent, files: files?.files, playedIndex: files?.played, at: date)
    }

    /// Forgets `mediaID` (its stream failed: nothing to remember of it).
    public static func forget(_ mediaID: String) {
        lock.lock(); defer { lock.unlock() }
        byMedia[mediaID] = nil
        mediaOrder.removeAll { $0 == mediaID }
    }

    /// Forgets everything (the tests).
    public static func removeAll() {
        lock.lock(); defer { lock.unlock() }
        byMedia = [:]
        mediaOrder = []
        filesByKey = [:]
        keyOrder = []
    }
}
