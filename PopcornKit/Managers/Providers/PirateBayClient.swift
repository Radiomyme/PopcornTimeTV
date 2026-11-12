import Foundation

/// The Pirate Bay's JSON API (apibay), an optional extra torrent source:
///
///   search:  /q.php?q=<terms>&cat=<categories>   up to 100 torrents
///   top 100: /precompiled/data_top100_<category>.json
///
/// Categories: 201 Movies, 207 HD Movies, 211 UHD Movies, 205 TV shows, 208
/// HD TV shows, 212 UHD TV shows. Entries carry the name, info-hash, seeders,
/// leechers, size and often an IMDb id (sometimes wrong). A search without a
/// hit answers one placeholder entry ("No results returned", id 0, a hash of
/// zeros), dropped here. A search by IMDb id finds nothing: search "Title
/// Year". The web proxies (tpbpxy.site…) sit behind Cloudflare challenges
/// and some French ISPs DNS-block TPB domains: the source is optional and
/// fails fast (`IndexFetcher`). Completions run on the main queue.
public final class PirateBayClient {

    public static let shared = PirateBayClient()

    /// apibay hosts to try in order. Overridable (a mirror, a self-hosted relay).
    public static var hosts: [String] = ["https://apibay.org"]

    /// Off: every call answers [] at once.
    public static var isEnabled = true

    public static let movieCategories = [201, 207, 211]
    public static let showCategories = [205, 208, 212]

    private let fetcher = IndexFetcher(name: "TPB")

    public init() {}

    /// Search results for `query` in `categories`, best-seeded first.
    public func search(_ query: String, categories: [Int], completion: @escaping ([IndexedRelease]) -> Void) {
        let terms = query.trimmingCharacters(in: .whitespaces)
        guard PirateBayClient.isEnabled, !terms.isEmpty else { return DispatchQueue.main.async { completion([]) } }
        let path = "/q.php?q=\(IndexFetcher.encode(terms))&cat=\(categories.map(String.init).joined(separator: ","))"
        fetcher.data(hosts: PirateBayClient.hosts, path: path) { data in
            let releases = data.map(PirateBayClient.releases(fromJSON:)) ?? []
            let wanted = Set(categories)
            let kept = releases.filter { $0.category.map(wanted.contains) ?? true }
                .sorted { $0.seeders > $1.seeders }
            print("[TPB] search '\(terms)' -> \(kept.count) torrents")
            DispatchQueue.main.async { completion(kept) }
        }
    }

    /// The top-100 list of one category (in TPB's order), [] on failure.
    public func top100(category: Int, completion: @escaping ([IndexedRelease]) -> Void) {
        guard PirateBayClient.isEnabled else { return DispatchQueue.main.async { completion([]) } }
        fetcher.data(hosts: PirateBayClient.hosts, path: "/precompiled/data_top100_\(category).json") { data in
            let releases = data.map(PirateBayClient.releases(fromJSON:)) ?? []
            print("[TPB] top100 \(category) -> \(releases.count) torrents")
            DispatchQueue.main.async { completion(releases) }
        }
    }

    // MARK: Parsing

    /// Releases of an apibay answer (search or top 100), minus the "No
    /// results returned" placeholder and malformed entries. Numbers come as
    /// JSON numbers (top 100) or strings (search).
    static func releases(fromJSON data: Data) -> [IndexedRelease] {
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  integer(entry["id"]) != 0,
                  let hash = IndexedRelease.normalizedInfoHash(entry["info_hash"] as? String) else { return nil }
            let size = integer(entry["size"])
            return IndexedRelease(name: name,
                                  infoHash: hash,
                                  seeders: count(entry["seeders"]),
                                  peers: count(entry["leechers"]),
                                  bytes: size.flatMap { $0 > 0 ? Int64($0) : nil },
                                  source: "TPB",
                                  category: integer(entry["category"]),
                                  imdb: IndexedRelease.normalizedImdb(entry["imdb"] as? String))
        }
    }

    /// A seed / peer count, clamped to 0 … 10 million: a hostile or broken
    /// mirror's "9223372036854775807" must not overflow the sums.
    static func count(_ value: Any?) -> Int {
        return count(integer(value))
    }

    static func count(_ value: Int?) -> Int {
        return min(max(value ?? 0, 0), 10_000_000)
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite, abs(double) < 9e18 else { return double > 0 ? Int.max : nil }
            return number.intValue
        }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
