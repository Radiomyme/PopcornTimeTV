

import Foundation
import Alamofire

/// Client for the Torrentio aggregation API (the torrent resolver behind
/// Stremio). One unauthenticated GET returns torrents collected from a dozen
/// upstream indexers (YTS, EZTV, RARBG archives, 1337x, TorrentGalaxy,
/// MagnetDL, …), which massively increases source diversity compared to a
/// single indexer:
///
///   movies:   /stream/movie/tt0111161.json
///   episodes: /stream/series/tt0944947:1:2.json
///
/// Each stream entry carries an `infoHash` + display metadata packed into a
/// text blob ("👤 75 💾 54.33 GB ⚙️ TorrentGalaxy"), which we parse back into
/// the app's `Torrent` model. Magnets are reconstructed from the hash plus a
/// set of large public trackers so libtorrent can bootstrap peers quickly,
/// and carry the stream's `fileIdx` as a BEP 53 `so=` selection so season
/// packs stream the requested episode rather than the biggest file where
/// the streamer honours it (macOS). Releases that can't stream at all (disc
/// images, archives, full Blu-ray / DVD structures) are dropped, and so are
/// multi-episode packs of episode results where the streamer can only play
/// a torrent's largest file (iOS / tvOS, see `dropsEpisodePacks`).
public final class TorrentioClient {

    public static let shared = TorrentioClient()

    /// Torrentio instances to try in order. The main instance sits behind
    /// Cloudflare and has been stable for years; alternates are community
    /// mirrors running the same code.
    public static var hosts: [String] = [
        "https://torrentio.strem.fun",
    ]

    /// Public trackers appended to reconstructed magnet links. Torrentio
    /// returns bare info-hashes; without trackers libtorrent would rely on
    /// DHT alone which is slow to bootstrap on Apple TV.
    private static let trackers: [String] = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://tracker.dler.org:6969/announce",
    ]

    private let session: Session = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Keep this short: the fetch happens at "Play" time and we never
        // want the user staring at a spinner because an aggregator is slow.
        configuration.timeoutIntervalForRequest = 10
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 11_0) AppleWebKit/605.1.15 PopcornTime/4.2",
            "Accept":     "application/json",
        ]
        return Session(configuration: configuration)
    }()

    public init() {}

    /// Fetch torrents for a movie (`season`/`episode` nil) or a specific
    /// episode. Always calls back on the main queue. Failures degrade to an
    /// empty array — Torrentio is an *additional* source, never a blocker.
    public func streams(imdbId: String,
                        season: Int? = nil,
                        episode: Int? = nil,
                        completion: @escaping ([Torrent]) -> Void) {
        guard imdbId.hasPrefix("tt") else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let path: String
        if let season = season, let episode = episode {
            path = "/stream/series/\(imdbId):\(season):\(episode).json"
        } else {
            path = "/stream/movie/\(imdbId).json"
        }
        attempt(hosts: TorrentioClient.hosts, path: path) { data in
            var result: (torrents: [Torrent], unplayable: [String], packs: [String]) = ([], [], [])
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data),
               let root = json as? [String: Any],
               let streams = root["streams"] as? [[String: Any]] {
                result = TorrentioClient.torrents(fromStreams: streams, season: season, episode: episode)
            }
            func sample(_ names: [String]) -> String {
                return names.isEmpty ? "" : " (\(names.prefix(3).joined(separator: " | ")))"
            }
            print("[Torrentio] \(path) -> \(result.torrents.count) torrents, \(result.unplayable.count) unplayable dropped"
                  + sample(result.unplayable)
                  + (season != nil && TorrentioClient.dropsEpisodePacks
                     ? ", \(result.packs.count) multi-episode packs dropped" + sample(result.packs) : ""))
            DispatchQueue.main.async { completion(result.torrents) }
        }
    }

    /// Drop multi-episode torrents (season packs, complete series, episode
    /// ranges) from EPISODE results. The iOS / tvOS PopcornTorrent pod
    /// (1.3.15) always streams a torrent's LARGEST file — its file-selection
    /// API keeps a process-wide flag that crashes later streams, so the apps
    /// don't use it — and a pack would play another episode, or fail. macOS
    /// streams through the SPM PopcornTorrent, which honours the magnet's
    /// `so=` per instance, so packs stay there. Single-episode releases and
    /// movies are never dropped.
    #if os(macOS)
    public static var dropsEpisodePacks = false
    #else
    public static var dropsEpisodePacks = true
    #endif

    /// Torrents of a Torrentio `streams` array, minus the releases that can't
    /// stream at all and — for an episode (`season` and `episode` set) when
    /// `dropPacks` — the multi-episode packs (`isEpisodePack`). Also returns
    /// the dropped names, for the log.
    static func torrents(fromStreams streams: [[String: Any]],
                         season: Int?,
                         episode: Int?,
                         dropPacks: Bool = dropsEpisodePacks) -> (torrents: [Torrent], unplayable: [String], packs: [String]) {
        var torrents: [Torrent] = []
        var unplayable: [String] = []
        var packs: [String] = []
        for stream in streams {
            let names = releaseNames(ofStream: stream)
            if Torrent.isLikelyUnplayableRelease(fileName: names.fileName, title: names.title) {
                unplayable.append(names.fileName ?? names.title)
                continue
            }
            if dropPacks, let season = season, let episode = episode,
               isEpisodePack(stream, season: season, episode: episode) {
                packs.append(releaseLines(ofStream: stream).first ?? names.title)
                continue
            }
            if let torrent = torrent(fromStream: stream) {
                torrents.append(torrent)
            }
        }
        return (torrents, unplayable, packs)
    }

    /// Ceiling for aggregated torrents. The Apple TV app sandbox only has
    /// ~7-10 GB of usable cache, so a 55 GB UHD REMUX can never finish
    /// buffering there — surfacing it in the quality picker (or worse,
    /// auto-picking it as "Highest") just produces disk-full errors.
    public static var maxSizeBytes: Int64 = 15 * 1024 * 1024 * 1024

    /// How many torrents a merged list keeps per resolution bucket (existing
    /// entries count), plus at most one fast-start slot (see `merge`). Keeps
    /// the picker readable when Torrentio returns 40+ entries for a popular
    /// release.
    public static var maxPerQuality = 3

    /// Merge aggregator results into an existing torrent list, deduplicating
    /// by info-hash (a YTS-sourced magnet and the Torrentio entry for the
    /// same release share the hash). Existing entries win so curated
    /// qualities/labels from the primary provider are preserved — but a
    /// winner whose magnet lacks the file selection (`so=`) a duplicate
    /// carries adopts it, so a season pack listed by another provider still
    /// streams the requested episode where `so=` is honoured.
    ///
    /// Candidates fill each resolution bucket up to `maxPerQuality`:
    /// 1. fast-start slot — the bucket's best-seeded candidate without a
    ///    playback penalty, whenever it out-seeds every clean release already
    ///    listed in that bucket (granted even when existing entries fill the
    ///    bucket), so the swarm that starts streaming fastest never
    ///    disappears behind better-scored but thinly seeded releases;
    /// 2. the remaining slots in `Torrent.precedesInListing` order (clean
    ///    first; healthy swarms by playability score, then the best-seeded).
    public static func merge(_ existing: [Torrent], with aggregated: [Torrent]) -> [Torrent] {
        var selections: [String: Int] = [:]
        for torrent in existing + aggregated {
            guard let hash = infoHash(fromMagnet: torrent.url), selections[hash] == nil,
                  let index = Torrent.selectedFileIndex(fromMagnet: torrent.url) else { continue }
            selections[hash] = index
        }
        func withSelection(_ torrent: Torrent) -> Torrent {
            guard Torrent.selectedFileIndex(fromMagnet: torrent.url) == nil,
                  let hash = infoHash(fromMagnet: torrent.url),
                  let index = selections[hash] else { return torrent }
            return torrent.replacingURL(torrent.url + "&so=\(index)")
        }

        var seen = Set(existing.compactMap { infoHash(fromMagnet: $0.url) })
        var perBucket: [VideoQuality: Int] = [:]
        for torrent in existing {
            perBucket[torrent.qualityValue, default: 0] += 1
        }

        var merged = existing.map(withSelection)
        func admit(_ torrent: Torrent) {
            guard let hash = infoHash(fromMagnet: torrent.url), seen.insert(hash).inserted else { return }
            merged.append(withSelection(torrent))
            perBucket[torrent.qualityValue, default: 0] += 1
        }

        // Seeded candidates within the size cap, in listing order.
        let capabilities = PlaybackCapabilities.current
        let candidates = aggregated
            .filter { torrent in
                torrent.seeds > 0
                    && (sizeInBytes(torrent.size).map { $0 <= maxSizeBytes } ?? true)
                    && infoHash(fromMagnet: torrent.url) != nil
            }
            .sorted { Torrent.precedesInListing($0, $1, capabilities: capabilities) }
        func isClean(_ torrent: Torrent) -> Bool {
            return !torrent.playability(for: capabilities).isPenalized
        }

        // 1. Fast-start slot of each bucket (first of equally seeded: listing order).
        let clean = candidates.filter(isClean)
        for quality in Set(clean.map { $0.qualityValue }).sorted(by: >) {
            guard let fastest = clean.filter({ $0.qualityValue == quality }).max(by: { $0.seeds < $1.seeds }),
                  let hash = infoHash(fromMagnet: fastest.url), !seen.contains(hash)   // else already listed
            else { continue }
            let listed = merged.filter { $0.qualityValue == quality && isClean($0) }
            if listed.allSatisfy({ $0.seeds < fastest.seeds }) {
                admit(fastest)
            }
        }
        // 2. The other slots, in listing order.
        for torrent in candidates where perBucket[torrent.qualityValue, default: 0] < maxPerQuality {
            admit(torrent)
        }
        return merged.sorted(by: <)
    }

    /// Parse Torrentio's human size string ("54.33 GB", "850 MB") to bytes.
    static func sizeInBytes(_ raw: String?) -> Int64? {
        guard let raw = raw?.uppercased() else { return nil }
        let scanner = Scanner(string: raw)
        guard let value = scanner.scanDouble() else { return nil }
        if raw.contains("GB") { return Int64(value * 1024 * 1024 * 1024) }
        if raw.contains("MB") { return Int64(value * 1024 * 1024) }
        if raw.contains("KB") { return Int64(value * 1024) }
        return Int64(value)
    }

    static func infoHash(fromMagnet magnet: String) -> String? {
        guard let range = magnet.range(of: "btih:") else { return nil }
        let tail = magnet[range.upperBound...]
        let hash = tail.prefix(while: { $0 != "&" }).lowercased()
        return hash.isEmpty ? nil : String(hash)
    }

    // MARK: - Parsing

    /// The non-empty title lines before the "👤 seeds 💾 size ⚙️ indexer"
    /// line: the torrent name, then — only when the stream's file is just a
    /// part of the torrent (a pack's episode) — that file's path. Torrentio
    /// leaves the file line out when the file is (nearly) the whole torrent.
    static func releaseLines(ofStream dict: [String: Any]) -> [String] {
        let lines = ((dict["title"] as? String) ?? "").components(separatedBy: "\n")
        return lines.prefix(while: { !$0.contains("👤") && !$0.contains("💾") })
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The payload file name (`behaviorHints.filename`) and the release text
    /// of a stream: the title lines before the "👤 seeds 💾 size ⚙️ indexer"
    /// line — torrent name, then the file name for multi-file torrents.
    static func releaseNames(ofStream dict: [String: Any]) -> (fileName: String?, title: String) {
        let hints = dict["behaviorHints"] as? [String: Any]
        let fileName = (hints?["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (fileName, releaseLines(ofStream: dict).joined(separator: " "))
    }

    /// True when an episode stream comes from a multi-episode torrent — a
    /// season / series pack or an episode range — judged from the torrent
    /// name (first title line, `ReleaseName.episodeScope`):
    /// - exactly the requested episode: never a pack;
    /// - a season / series / 3+ episode range: always a pack (with or without
    ///   a separate file line: "Show.S03" + "Show.S03E05.mkv" has none);
    /// - a double episode, another episode or no marker at all (anime "Show -
    ///   05", Torrentio's absolute-numbering matches): a pack when the title
    ///   lists the episode as a separate file of the torrent, or when the
    ///   file (`behaviorHints.filename`) is named for exactly the requested
    ///   episode while the torrent isn't — Torrentio also leaves the file line
    ///   out when the file path contains the torrent name ("Frasier" →
    ///   "Frasier - S03E05 - ….avi", file #100).
    static func isEpisodePack(_ dict: [String: Any], season: Int, episode: Int) -> Bool {
        let lines = releaseLines(ofStream: dict)
        guard let name = lines.first else { return false }
        switch ReleaseName.episodeScope(of: name, season: season, episode: episode) {
        case .requestedEpisode:
            return false
        case .pack:
            return true
        case .multiEpisode, .otherEpisode, .unknown:
            if lines.count > 1 { return true }
            guard let file = releaseNames(ofStream: dict).fileName else { return false }
            return ReleaseName.episodeScope(of: file, season: season, episode: episode) == .requestedEpisode
        }
    }

    /// The torrent's file index for this stream (`fileIdx`, 0-based, the
    /// order libtorrent lists the files in), nil when absent.
    static func fileIndex(ofStream dict: [String: Any]) -> Int? {
        if let index = dict["fileIdx"] as? Int { return index >= 0 ? index : nil }
        if let text = dict["fileIdx"] as? String, let index = Int(text) { return index >= 0 ? index : nil }
        return nil
    }

    static func torrent(fromStream dict: [String: Any]) -> Torrent? {
        guard let infoHash = (dict["infoHash"] as? String)?.lowercased(), !infoHash.isEmpty else { return nil }

        let title = (dict["title"] as? String) ?? ""
        let hints = dict["behaviorHints"] as? [String: Any]
        let filename = (hints?["filename"] as? String)
            ?? title.components(separatedBy: "\n").first
            ?? "download"

        // "👤 75 💾 54.33 GB ⚙️ TorrentGalaxy" → seeds / size / indexer.
        var seeds = 0
        if let range = title.range(of: "👤 ") {
            let tail = title[range.upperBound...]
            seeds = Int(tail.prefix(while: { $0.isNumber })) ?? 0
        }
        var size: String?
        if let range = title.range(of: "💾 ") {
            let tail = title[range.upperBound...]
            // Torrentio writes "⚙️" (gear + variation selector), a different
            // Character from a bare "⚙": stop on the gear scalar itself, or
            // the size would read "54.33 GB ⚙️ TorrentGalaxy".
            size = String(tail.prefix(while: { $0.unicodeScalars.first != "⚙" && $0 != "\n" }))
                .trimmingCharacters(in: .whitespaces)
        }
        var indexer: String?
        if let range = title.range(of: "⚙️ ") {
            let tail = title[range.upperBound...]
            indexer = String(tail.prefix(while: { $0 != "\n" })).trimmingCharacters(in: .whitespaces)
        }

        let dn = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? filename
        var magnet = "magnet:?xt=urn:btih:\(infoHash)&dn=\(dn)"
        for tracker in trackers {
            magnet += "&tr=" + (tracker.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tracker)
        }
        // BEP 53 select-only: the file this stream refers to (the episode in
        // a season pack, the feature next to extras). The players hand it to
        // the streamer's file-selection callback.
        if let fileIndex = fileIndex(ofStream: dict) {
            magnet += "&so=\(fileIndex)"
        }

        // Resolution/codec live in the release name; Torrentio also puts a
        // human bucket ("4k DV") in `name` after a newline.
        let qualitySource = filename + " " + ((dict["name"] as? String) ?? "")
        var torrent = Torrent(
            health:  .unknown,
            url:     magnet,
            quality: qualitySource,
            seeds:   seeds,
            peers:   0,
            size:    size,
            tags:    VideoTags.parse(qualitySource))
        // Rebuild the display label from the parsed bucket + tags and append
        // the indexer so the quality picker shows where a stream comes from.
        var label = torrent.qualityValue.displayLabel + torrent.tags.displaySuffix
        if label.isEmpty { label = "Unknown".localized }
        if let indexer = indexer, !indexer.isEmpty { label += " — \(indexer)" }
        torrent.quality = label
        // `quality` setter re-parses value; restore the accurate bucket/tags
        // in case the label lost information (e.g. "Unknown").
        torrent.qualityValue = VideoQuality.parse(qualitySource)
        torrent.tags = VideoTags.parse(qualitySource)
        return torrent
    }

    private func attempt(hosts: [String], path: String, completion: @escaping (Data?) -> Void) {
        var remaining = hosts
        func tryNext() {
            guard let host = remaining.first else {
                completion(nil)
                return
            }
            remaining.removeFirst()
            session.request(host + path).validate().responseData { response in
                switch response.result {
                case .success(let data):
                    completion(data)
                case .failure(let error):
                    print("[Torrentio] \(host) FAILED: \(error.localizedDescription)")
                    tryNext()
                }
            }
        }
        tryNext()
    }
}
