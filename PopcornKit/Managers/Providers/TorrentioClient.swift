

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
/// set of large public trackers so libtorrent can bootstrap peers quickly.
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
            var torrents: [Torrent] = []
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data),
               let root = json as? [String: Any],
               let streams = root["streams"] as? [[String: Any]] {
                torrents = streams.compactMap(TorrentioClient.torrent(fromStream:))
            }
            print("[Torrentio] \(path) -> \(torrents.count) torrents")
            DispatchQueue.main.async { completion(torrents) }
        }
    }

    /// Ceiling for aggregated torrents. The Apple TV app sandbox only has
    /// ~7-10 GB of usable cache, so a 55 GB UHD REMUX can never finish
    /// buffering there — surfacing it in the quality picker (or worse,
    /// auto-picking it as "Highest") just produces disk-full errors.
    public static var maxSizeBytes: Int64 = 15 * 1024 * 1024 * 1024

    /// How many aggregated torrents to keep per resolution bucket (best
    /// seeded first). Keeps the picker readable when Torrentio returns 40+
    /// entries for a popular release.
    public static var maxPerQuality = 3

    /// Merge aggregator results into an existing torrent list, deduplicating
    /// by info-hash (a YTS-sourced magnet and the Torrentio entry for the
    /// same release share the hash). Existing entries win so curated
    /// qualities/labels from the primary provider are preserved.
    public static func merge(_ existing: [Torrent], with aggregated: [Torrent]) -> [Torrent] {
        var seen = Set(existing.compactMap { infoHash(fromMagnet: $0.url) })
        var perBucket: [VideoQuality: Int] = [:]
        for torrent in existing {
            perBucket[torrent.qualityValue, default: 0] += 1
        }

        var merged = existing
        // Best-seeded candidates first so the per-bucket cap keeps winners.
        for torrent in aggregated.sorted(by: { $0.seeds > $1.seeds }) {
            guard torrent.seeds > 0,
                  sizeInBytes(torrent.size).map({ $0 <= maxSizeBytes }) ?? true,
                  let hash = infoHash(fromMagnet: torrent.url),
                  perBucket[torrent.qualityValue, default: 0] < maxPerQuality
            else { continue }
            if seen.insert(hash).inserted {
                merged.append(torrent)
                perBucket[torrent.qualityValue, default: 0] += 1
            }
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

    private static func torrent(fromStream dict: [String: Any]) -> Torrent? {
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
            size = String(tail.prefix(while: { $0 != "⚙" && $0 != "\n" })).trimmingCharacters(in: .whitespaces)
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
