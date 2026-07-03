

import Foundation
import Alamofire

/// Extra torrent source backed by the Time4Popcorn SE catalog API
/// (`api.apiabcd.com`, `app_id=T4P_SEC`) — the backend the still-working
/// `PopcornTime.app` uses. It aggregates YTS + Time4Popcorn's own movie/TV
/// scrapers server-side, so it often carries releases (older seasons, extra
/// qualities, alternate encodes) that YTS/EZTV/Torrentio miss.
///
/// Endpoints (plain HTTP — the app plists already allow arbitrary loads):
///   movie torrents:   /movie?imdb=tt<id>&quality=720p,1080p,3d&app_id=T4P_SEC
///   show torrents:    /show?imdb=tt<id>&app_id=T4P_SEC   -> keyed by season
///
/// Both wrap each torrent in an `items` array with `torrent_magnet`,
/// `torrent_seeds`, `size_bytes`, `quality` and the release `file` name,
/// which map straight onto the app's `Torrent` model. Results are merged
/// into the existing torrent lists (deduped by info-hash) via
/// `TorrentioClient.merge`, so this is strictly additive.
public final class Time4PopcornClient {

    public static let shared = Time4PopcornClient()

    /// Host chain. `api.apiabcd.com` is the one the desktop app talks to;
    /// keep alternates here if it rotates.
    public static var hosts: [String] = [
        "http://api.apiabcd.com",
    ]

    private static let appId = "T4P_SEC"
    private static let clientVersion = "6.2.1.17"
    private static let qualityFilter = "720p,1080p,3d"

    private let session: Session = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        // The API 403s unknown clients; pose as the desktop app / a browser.
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) PopcornTime/T4P_SEC",
            "Accept":     "application/json, text/plain, */*",
        ]
        return Session(configuration: configuration)
    }()

    public init() {}

    // MARK: - Public API

    /// Torrents for a movie. Always calls back on the main queue; failures
    /// degrade to an empty array (this is an *additional* source).
    public func movieTorrents(imdbId: String, completion: @escaping ([Torrent]) -> Void) {
        guard imdbId.hasPrefix("tt") else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let query = "/movie?cb=&quality=\(Time4PopcornClient.qualityFilter)&page=1&imdb=\(imdbId)&ver=\(Time4PopcornClient.clientVersion)&os=mac&app_id=\(Time4PopcornClient.appId)"
        get(path: query) { data in
            var torrents: [Torrent] = []
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data),
               let root = json as? [String: Any] {
                // Detail returns the movie object directly (with `items`) or
                // wrapped in a MovieList — handle both.
                let movie = (root["MovieList"] as? [[String: Any]])?.first ?? root
                let items = (movie["items"] as? [[String: Any]]) ?? []
                torrents = items.compactMap(Time4PopcornClient.torrent(fromItem:))
            }
            print("[T4P] movie \(imdbId) -> \(torrents.count) torrents")
            DispatchQueue.main.async { completion(torrents) }
        }
    }

    /// Torrents for a specific episode. The `/show` payload is keyed by
    /// season number ("1", "2", …), each a list of episode objects carrying
    /// their own `items`.
    public func episodeTorrents(imdbId: String,
                                season: Int,
                                episode: Int,
                                completion: @escaping ([Torrent]) -> Void) {
        guard imdbId.hasPrefix("tt") else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let query = "/show?imdb=\(imdbId)&ver=\(Time4PopcornClient.clientVersion)&os=mac&app_id=\(Time4PopcornClient.appId)"
        get(path: query) { data in
            var torrents: [Torrent] = []
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data),
               let root = json as? [String: Any],
               let episodes = root[String(season)] as? [[String: Any]] {
                for ep in episodes {
                    let number = Int((ep["episode"] as? String) ?? "") ?? (ep["episode"] as? Int ?? -1)
                    guard number == episode else { continue }
                    let items = (ep["items"] as? [[String: Any]]) ?? []
                    torrents = items.compactMap(Time4PopcornClient.torrent(fromItem:))
                    break
                }
            }
            print("[T4P] show \(imdbId) S\(season)E\(episode) -> \(torrents.count) torrents")
            DispatchQueue.main.async { completion(torrents) }
        }
    }

    // MARK: - Parsing

    private static func torrent(fromItem item: [String: Any]) -> Torrent? {
        guard let magnet = item["torrent_magnet"] as? String, magnet.hasPrefix("magnet:") else { return nil }
        let file = (item["file"] as? String) ?? ""
        let apiQuality = (item["quality"] as? String) ?? ""
        let seeds = (item["torrent_seeds"] as? Int) ?? Int((item["torrent_seeds"] as? String) ?? "") ?? 0
        let peers = (item["torrent_peers"] as? Int) ?? Int((item["torrent_peers"] as? String) ?? "") ?? 0
        let size: String? = (item["size_bytes"] as? NSNumber).map {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .binary
            return formatter.string(fromByteCount: $0.int64Value)
        }

        // Parse resolution/codec from the filename first (richest signal),
        // falling back to the API's coarse quality field.
        let parseSource = file.isEmpty ? apiQuality : file
        var torrent = Torrent(
            health:  .unknown,
            url:     magnet,
            quality: parseSource,
            seeds:   seeds,
            peers:   peers,
            size:    size,
            tags:    VideoTags.parse(parseSource))
        var label = torrent.qualityValue.displayLabel + torrent.tags.displaySuffix
        if label.isEmpty { label = apiQuality.isEmpty ? "Unknown".localized : apiQuality }
        torrent.quality = label + " — T4P"
        torrent.qualityValue = VideoQuality.parse(parseSource)
        torrent.tags = VideoTags.parse(parseSource)
        return torrent
    }

    private func get(path: String, completion: @escaping (Data?) -> Void) {
        var remaining = Time4PopcornClient.hosts
        func tryNext() {
            guard let host = remaining.first else { completion(nil); return }
            remaining.removeFirst()
            session.request(host + path).validate().responseData { response in
                switch response.result {
                case .success(let data):
                    completion(data)
                case .failure(let error):
                    print("[T4P] \(host) FAILED: \(error.localizedDescription)")
                    tryNext()
                }
            }
        }
        tryNext()
    }
}
