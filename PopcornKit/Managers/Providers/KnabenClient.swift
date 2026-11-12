import Foundation

/// The Knaben meta-index (knaben.org), an optional extra torrent source. It
/// aggregates The Pirate Bay, 1337x, TorrentGalaxy, YTS, Nyaa, RuTracker,
/// RARBG archives… — most of what link launchers such as xtorx.com point to:
///
///   GET  /v2/search?q=<terms>&sf=title&o=seeders&d=desc&s=100&c=<ids>
///   POST /v1 {"search_type":"100%","search_field":"title","query":…}  (fallback)
///
/// Both answer {"hits":[{"title","hash","magnetUrl","bytes","seeders",
/// "peers","tracker","categoryId",…}]}. Knaben asks clients to use v2 (GET,
/// cached at its edge). Unsafe (likely malware) and XXX results are hidden by
/// default. Some hits (1337x) carry no info-hash: they are skipped. Fails fast
/// like every optional source (`IndexFetcher`). Completions run on the main
/// queue.
public final class KnabenClient {

    public static let shared = KnabenClient()

    /// Knaben API hosts to try in order. Overridable.
    public static var hosts: [String] = ["https://api.knaben.org"]

    /// Off: every call answers [] at once.
    public static var isEnabled = true

    /// Movies (3000000) and its HD / SD / UHD / Foreign / Other sub-categories
    /// (not DVD images or 3D). Knaben files some TPB movies under TV's root id
    /// plus a movie sub-id ([2000000, 3001000]): the sub-ids are listed.
    public static let movieCategories = [3000000, 3001000, 3002000, 3003000, 3005000, 3008000]
    /// TV (2000000) and its sub-categories except Sport.
    public static let showCategories = [2000000, 2001000, 2002000, 2003000, 2004000, 2005000, 2007000, 2008000]

    private let fetcher = IndexFetcher(name: "Knaben")

    public init() {}

    /// Search results for `query` in `categories`, best-seeded first.
    public func search(_ query: String, categories: [Int], completion: @escaping ([IndexedRelease]) -> Void) {
        let terms = query.trimmingCharacters(in: .whitespaces)
        guard KnabenClient.isEnabled, !terms.isEmpty else { return DispatchQueue.main.async { completion([]) } }
        let ids = categories.map(String.init).joined(separator: ",")
        let v2 = "/v2/search?q=\(IndexFetcher.encode(terms))&sf=title&o=seeders&d=desc&s=100&c=\(IndexFetcher.encode(ids))"
        fetcher.data(hosts: KnabenClient.hosts, path: v2) { [weak self] data in
            if let data = data, let hits = KnabenClient.releases(fromJSON: data) {
                return KnabenClient.finish(terms, hits, completion)
            }
            // v2 down or changed: the v1 POST API.
            let body: [String: Any] = [
                "search_type": "100%", "search_field": "title", "query": terms,
                "order_by": "seeders", "order_direction": "desc", "size": 100,
                "categories": categories, "hide_unsafe": true, "hide_xxx": true,
            ]
            guard let self = self, let json = try? JSONSerialization.data(withJSONObject: body) else {
                return KnabenClient.finish(terms, [], completion)
            }
            self.fetcher.data(hosts: KnabenClient.hosts, path: "/v1", body: json) { data in
                KnabenClient.finish(terms, data.flatMap(KnabenClient.releases(fromJSON:)) ?? [], completion)
            }
        }
    }

    private static func finish(_ terms: String, _ releases: [IndexedRelease], _ completion: @escaping ([IndexedRelease]) -> Void) {
        let kept = IndexedRelease.deduplicated(releases.sorted { $0.seeders > $1.seeders })
        print("[Knaben] search '\(terms)' -> \(kept.count) torrents")
        DispatchQueue.main.async { completion(kept) }
    }

    // MARK: Parsing

    /// Releases of a Knaben answer, nil when it isn't one (an error page).
    /// Hits without an info-hash are skipped; `liveSeeders` (fresh tracker
    /// counts) wins over `seeders` when present.
    static func releases(fromJSON data: Data) -> [IndexedRelease]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hits = root["hits"] as? [[String: Any]] else { return nil }
        return hits.compactMap { hit in
            guard let name = (hit["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let hash = IndexedRelease.normalizedInfoHash((hit["hash"] as? String) ?? infoHash(fromMagnet: hit["magnetUrl"] as? String))
            else { return nil }
            // `liveSeeders` is null when Knaben has no fresh count.
            let seeders = PirateBayClient.count(PirateBayClient.integer(hit["liveSeeders"]) ?? PirateBayClient.integer(hit["seeders"]))
            let peers = PirateBayClient.count(PirateBayClient.integer(hit["livePeers"]) ?? PirateBayClient.integer(hit["peers"]))
            let bytes = PirateBayClient.integer(hit["bytes"]).flatMap { $0 > 0 ? Int64($0) : nil }
            return IndexedRelease(name: name, infoHash: hash, seeders: seeders, peers: peers, bytes: bytes,
                                  source: "Knaben · " + shortName(ofTracker: hit["tracker"] as? String))
        }
    }

    static func infoHash(fromMagnet magnet: String?) -> String? {
        guard let magnet = magnet, let range = magnet.range(of: "btih:", options: .caseInsensitive) else { return nil }
        return String(magnet[range.upperBound...].prefix { $0 != "&" })
    }

    /// The tracker as the torrent picker shows it: "The Pirate Bay" → "TPB".
    static func shortName(ofTracker tracker: String?) -> String {
        guard let tracker = tracker?.trimmingCharacters(in: .whitespaces), !tracker.isEmpty else { return "?" }
        switch tracker.lowercased() {
        case "the pirate bay": return "TPB"
        case "nyaa.si": return "Nyaa"
        case "torrentgalaxy": return "TGx"
        default: return tracker
        }
    }
}
