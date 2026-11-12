import Foundation

/// The "Top 100" catalogs: The Pirate Bay's precompiled top-100 lists, the
/// most seeded torrents of the moment, mapped to IMDb titles.
///
/// - Movies: categories 201 (Movies) + 207 (HD) + 211 (UHD) merged.
/// - Shows: 205 (TV) + 208 (HD TV) + 212 (UHD TV) merged.
///
/// Releases are grouped by the title they name and ranked by the seeders of
/// all their torrents (`Top100Ranking`), then resolved to Cinemeta metas
/// (`Top100Resolver`: TPB's IMDb id when Cinemeta confirms title and year,
/// else an exact title + year search; unresolvable groups — box sets, packs
/// of several titles — are left out). One page of at most `limit` titles;
/// the genre filter applies to it client-side.
///
/// Caching: a complete list is kept `cacheLifetime` in memory and on disk (a
/// relaunch paints at once). Once it is older, a refresh starts and the grid
/// waits for it at most `staleGrace`, then shows the older list (up to
/// `staleLifetime`) while the refresh finishes for the next load; a failed
/// refresh falls back to it too. A list Cinemeta couldn't fully resolve (a
/// failed call, the deadline) is shown but kept only `incompleteLifetime`
/// and never written to disk. Completions run on the main queue.
public final class PirateBayTop100 {

    public static let shared = PirateBayTop100()

    public static var limit = 100
    public static var cacheLifetime: TimeInterval = 15 * 60
    /// Age of a cached list still shown when TPB can't be reached.
    public static var staleLifetime: TimeInterval = 24 * 3600
    /// Longest wait for a refresh when an older list can be shown instead.
    public static var staleGrace: TimeInterval = 1.5
    /// Life of a list Cinemeta couldn't fully resolve.
    public static var incompleteLifetime: TimeInterval = 2 * 60
    /// Longest wait for Cinemeta: the titles resolved by then are shown.
    public static var resolveDeadline: TimeInterval = 10

    private struct Snapshot {
        let date: Date
        let metas: [[String: Any]]
        /// When it stops being fresh.
        let expires: Date
    }

    /// One waiting grid: answered once, by the refresh or by the stale list.
    private final class Waiter {
        private var completion: (([[String: Any]]?, NSError?) -> Void)?
        init(_ completion: @escaping ([[String: Any]]?, NSError?) -> Void) { self.completion = completion }
        /// Main queue.
        func answer(_ metas: [[String: Any]]?, _ error: NSError?) {
            guard let completion = completion else { return }
            self.completion = nil
            completion(metas, error)
        }
    }

    private let lock = NSLock()
    private var snapshots: [String: Snapshot] = [:]
    private var waiters: [String: [Waiter]] = [:]

    public init() {}

    /// Top 100 movies (page 1 only: later pages are empty), most popular first.
    public func movies(page: Int, genre: NetworkManager.Genres, completion: @escaping ([Movie]?, NSError?) -> Void) {
        guard page <= 1 else { return DispatchQueue.main.async { completion([], nil) } }
        metas(.movie, categories: PirateBayClient.movieCategories) { metas, error in
            guard let metas = metas else { return completion(nil, error) }
            completion(PirateBayTop100.filter(metas, genre: genre).compactMap(Movie.init(cinemeta:)), nil)
        }
    }

    /// Top 100 shows (page 1 only: later pages are empty), most popular first.
    public func shows(page: Int, genre: NetworkManager.Genres, completion: @escaping ([Show]?, NSError?) -> Void) {
        guard page <= 1 else { return DispatchQueue.main.async { completion([], nil) } }
        metas(.series, categories: PirateBayClient.showCategories) { metas, error in
            guard let metas = metas else { return completion(nil, error) }
            completion(PirateBayTop100.filter(metas, genre: genre).compactMap(Show.init(cinemeta:)), nil)
        }
    }

    // MARK: Errors

    /// Domain of the errors the loaders answer when nothing can be shown:
    /// the grids show their Top 100 message for it.
    public static let errorDomain = "popcornkit.top100"
    /// The Pirate Bay could not be reached.
    public static let unreachableCode = -1
    /// TPB answered, but Cinemeta (the titles) could not be reached.
    public static let titlesUnavailableCode = -2

    private static var unreachable: NSError {
        return NSError(domain: errorDomain, code: unreachableCode,
                       userInfo: [NSLocalizedDescriptionKey: "The Pirate Bay could not be reached.".localized])
    }

    private static var titlesUnavailable: NSError {
        return NSError(domain: errorDomain, code: titlesUnavailableCode,
                       userInfo: [NSLocalizedDescriptionKey: "The titles of the Top 100 could not be loaded. Try again later.".localized])
    }

    /// The full message of a load error: The Pirate Bay's adds that the
    /// site may be blocked on the network.
    public static func message(for error: NSError) -> String {
        guard error.domain == errorDomain, error.code == unreachableCode else { return error.localizedDescription }
        return error.localizedDescription + " " + "The site may be blocked on your network. Try again later.".localized
    }

    // MARK: Loading

    /// The ranked metas of one kind (main queue), or the error when nothing
    /// can be shown. Concurrent calls share one load.
    private func metas(_ kind: CinemetaClient.Kind, categories: [Int],
                       completion: @escaping ([[String: Any]]?, NSError?) -> Void) {
        let key = kind.rawValue
        let now = Date()
        lock.lock()
        if snapshots[key] == nil, let disk = PirateBayTop100.readDisk(key) { snapshots[key] = disk }
        let snapshot = snapshots[key]
        if let snapshot = snapshot, now < snapshot.expires {
            lock.unlock()
            return DispatchQueue.main.async { completion(snapshot.metas, nil) }
        }
        let waiter = Waiter(completion)
        let loading = waiters[key] != nil
        waiters[key, default: []].append(waiter)
        lock.unlock()

        // An older list to show if the refresh is slow: wait for it a moment only.
        if let stale = snapshot, now.timeIntervalSince(stale.date) < PirateBayTop100.staleLifetime {
            DispatchQueue.main.asyncAfter(deadline: .now() + PirateBayTop100.staleGrace) {
                waiter.answer(stale.metas, nil)
            }
        }
        guard !loading else { return }

        let started = Date()
        load(kind, categories: categories) { [weak self] metas, complete in
            guard let self = self else { return }
            self.lock.lock()
            var result: [[String: Any]]? = metas
            var error: NSError?
            let previous = self.snapshots[key]
            let stale = previous.flatMap { Date().timeIntervalSince($0.date) < PirateBayTop100.staleLifetime ? $0 : nil }
            if let metas = metas, !metas.isEmpty, complete || metas.count >= (stale?.metas.count ?? 0) {
                let date = Date()
                let lifetime = complete ? PirateBayTop100.cacheLifetime : PirateBayTop100.incompleteLifetime
                let snapshot = Snapshot(date: date, metas: metas, expires: date.addingTimeInterval(lifetime))
                self.snapshots[key] = snapshot
                if complete { PirateBayTop100.writeDisk(key, snapshot) }
            } else if let stale = stale {
                print("[Top100] \(key): refresh \(metas == nil ? "failed" : "incomplete"), showing the list from \(Int(Date().timeIntervalSince(stale.date) / 60)) min ago")
                result = stale.metas
            } else if let metas = metas, !metas.isEmpty {
                result = metas
            } else {
                result = nil
                error = metas == nil ? PirateBayTop100.unreachable : PirateBayTop100.titlesUnavailable
            }
            let callbacks = self.waiters[key] ?? []
            self.waiters[key] = nil
            self.lock.unlock()
            print("[Top100] \(key): \(result?.count ?? 0) titles in \(String(format: "%.1f", Date().timeIntervalSince(started)))s\(complete ? "" : " (incomplete)")")
            DispatchQueue.main.async { callbacks.forEach { $0.answer(result, error) } }
        }
    }

    /// Fetch the categories' top 100s, group, rank and resolve. nil when no
    /// list could be fetched; `complete` false when Cinemeta couldn't resolve
    /// every group it was asked (the deadline, a failed call).
    private func load(_ kind: CinemetaClient.Kind, categories: [Int],
                      completion: @escaping ([[String: Any]]?, _ complete: Bool) -> Void) {
        let group = DispatchGroup()
        var lists = [[IndexedRelease]](repeating: [], count: categories.count)
        for (index, category) in categories.enumerated() {
            group.enter()
            PirateBayClient.shared.top100(category: category) { releases in
                lists[index] = releases
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // Interleave the lists (rank 1 of each, then rank 2…) so equal
            // seeders keep TPB's order across categories.
            var merged: [IndexedRelease] = []
            for rank in 0..<(lists.map(\.count).max() ?? 0) {
                for list in lists where rank < list.count { merged.append(list[rank]) }
            }
            guard !merged.isEmpty else { return completion(nil, false) }
            let groups = kind == .movie ? Top100Ranking.movieGroups(merged) : Top100Ranking.showGroups(merged)
            Top100Resolver(kind: kind).resolve(groups, limit: PirateBayTop100.limit, deadline: PirateBayTop100.resolveDeadline) { resolved, complete in
                completion(resolved.map { PirateBayTop100.trimmed($0.meta) }, complete)
            }
        }
    }

    // MARK: Genre filter

    static func filter(_ metas: [[String: Any]], genre: NetworkManager.Genres) -> [[String: Any]] {
        return genre == .all ? metas : Top100Resolver.filter(metas, genre: genre.rawValue)
    }

    // MARK: Disk cache

    /// The meta fields the grid and the models read: keeps the cache small.
    private static let keptFields: Set<String> = [
        "id", "imdb_id", "type", "name", "poster", "background", "logo", "genres", "genre",
        "releaseInfo", "year", "imdbRating", "description", "runtime",
    ]

    private static func trimmed(_ meta: [String: Any]) -> [String: Any] {
        return meta.filter { keptFields.contains($0.key) }
    }

    private static func diskURL(_ key: String) -> URL? {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("popcornkit-top100-\(key).json")
    }

    private static func readDisk(_ key: String) -> Snapshot? {
        guard let url = diskURL(key), let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let time = root["date"] as? Double, let metas = root["metas"] as? [[String: Any]], !metas.isEmpty
        else { return nil }
        let date = Date(timeIntervalSince1970: time)
        return Snapshot(date: date, metas: metas, expires: date.addingTimeInterval(cacheLifetime))
    }

    private static func writeDisk(_ key: String, _ snapshot: Snapshot) {
        guard let url = diskURL(key) else { return }
        let root: [String: Any] = ["date": snapshot.date.timeIntervalSince1970, "metas": snapshot.metas]
        guard JSONSerialization.isValidJSONObject(root), let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
