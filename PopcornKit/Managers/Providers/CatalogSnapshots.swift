import Foundation

/// How long the first page of a catalog can be shown again without asking
/// the network (`fresh`), and how long it is still worth showing while, or
/// instead of, a refresh (`stale`). From the servers' own cache headers and
/// their rate of change, measured 2026-11-14:
///
/// | list                                   | fresh  | stale |
/// |----------------------------------------|--------|-------|
/// | YTS by date (Recently Added, New)      | 30 min | 24 h  | `no-store`, ~20 additions a day
/// | YTS rankings (Trending, Popular, Top Rated) | 6 h | 7 d  | slow rankings
/// | Cinemeta catalogs (the Shows grid)     | 4 h    | 7 d   | `max-age=14400`
/// | EZTV's latest releases (Shows, Recently Added) | 15 min | 24 h | a feed to the minute
struct CatalogFreshness: Equatable {

    let fresh: TimeInterval
    let stale: TimeInterval

    enum State: Equatable {
        /// Recent enough to be the answer.
        case fresh
        /// Shown at once, while the list is asked again.
        case stale
        /// Too old to show.
        case expired
    }

    func state(age: TimeInterval) -> State {
        // A date in the future (the clock was set back): not trusted as fresh.
        if age >= 0 && age < fresh { return .fresh }
        return abs(age) < stale ? .stale : .expired
    }

    static func movies(_ filter: MovieManager.Filters) -> CatalogFreshness {
        switch filter {
        case .date, .year:
            return CatalogFreshness(fresh: 30 * 60, stale: 24 * 3600)
        case .trending, .popularity, .rating, .top100:
            return CatalogFreshness(fresh: 6 * 3600, stale: 7 * 24 * 3600)
        }
    }

    static func shows(_ filter: ShowManager.Filters) -> CatalogFreshness {
        switch filter {
        case .date:
            return CatalogFreshness(fresh: 15 * 60, stale: 24 * 3600)
        case .trending, .popularity, .rating, .year, .name, .top100:
            return CatalogFreshness(fresh: 4 * 3600, stale: 7 * 24 * 3600)
        }
    }
}

/// The first page of each catalog (a kind, a sort, a genre), as last loaded,
/// on disk: the Movies and Shows grids paint at once at launch and when a
/// sort already visited is picked again, then the list is refreshed
/// (`MovieManager.load`, `ShowManager.load`). The Top 100 keeps its own
/// (`PirateBayTop100`).
///
/// One small JSON file per list in `Caches/popcornkit-catalog` (the system
/// may empty it: the next load simply waits for the network), `{date, items}`
/// where the items are the models' own JSON (the Watchlist's format). At most
/// `maxFiles` lists are kept. The directory and the clock are injected (tests).
final class CatalogSnapshotStore {

    static let shared = CatalogSnapshotStore(directory:
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("popcornkit-catalog", isDirectory: true))

    /// Most lists kept on disk (each sort × genre visited is one).
    static let maxFiles = 40

    struct Snapshot {
        let date: Date
        let items: [[String: Any]]
    }

    private let directory: URL?
    private let now: () -> Date
    private let lock = NSLock()
    /// What was read or written during this run (the files are small, but a
    /// revisit should not touch the disk on the main thread again).
    private var memory: [String: Snapshot] = [:]
    /// Lists saved before this are asked again (`expireAll`).
    private var refreshedAt = Date.distantPast
    private let writer = DispatchQueue(label: "com.popcorntimetv.popcornkit.catalog.snapshots", qos: .utility)

    init(directory: URL?, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    /// The key of a list: "movies-trending-All-desc".
    static func key(kind: String, filter: String, genre: String, order: NetworkManager.Orders) -> String {
        return [kind, filter, genre, order == .descending ? "desc" : "asc"].joined(separator: "-")
    }

    /// The list saved under `key` with its age, nil when there is none.
    func read(_ key: String) -> (snapshot: Snapshot, age: TimeInterval)? {
        lock.lock()
        var snapshot = memory[key]
        lock.unlock()
        if snapshot == nil, let url = fileURL(key), let data = try? Data(contentsOf: url),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let time = root["date"] as? Double, let items = root["items"] as? [[String: Any]], !items.isEmpty {
            let read = Snapshot(date: Date(timeIntervalSince1970: time), items: items)
            lock.lock()
            memory[key] = read
            lock.unlock()
            snapshot = read
        }
        guard let found = snapshot else { return nil }
        return (found, now().timeIntervalSince(found.date))
    }

    /// Saves `items` (the models' JSON) as the list of `key`, dated now. An
    /// empty list is never saved. The file is written in the background.
    func write(_ key: String, items: [[String: Any]]) {
        guard !items.isEmpty else { return }
        let snapshot = Snapshot(date: now(), items: items)
        lock.lock()
        memory[key] = snapshot
        lock.unlock()
        guard let url = fileURL(key), let directory = directory else { return }
        writer.async {
            let root: [String: Any] = ["date": snapshot.date.timeIntervalSince1970, "items": items]
            guard JSONSerialization.isValidJSONObject(root),
                  let data = try? JSONSerialization.data(withJSONObject: root) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            CatalogSnapshotStore.prune(directory, keeping: CatalogSnapshotStore.maxFiles)
        }
    }

    /// An explicit refresh (a pull to refresh): every list saved so far is
    /// asked again on its next load, however recent. It is still what a
    /// caller with a `snapshot` handler paints meanwhile, and what the load
    /// answers when the network fails.
    func expireAll() {
        lock.lock()
        refreshedAt = now()
        lock.unlock()
    }

    /// True for a list saved before the last explicit refresh.
    func mustBeAskedAgain(_ snapshot: Snapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.date <= refreshedAt
    }

    /// Blocks until the pending writes are on disk (tests).
    func flush() {
        writer.sync {}
    }

    private func fileURL(_ key: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let name = String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return directory?.appendingPathComponent(name + ".json")
    }

    /// Deletes the least recently written lists beyond `count`.
    private static func prune(_ directory: URL, keeping count: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > count else { return }
        let dated = files.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(count) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// The first page of a catalog through its snapshot: stale-while-revalidate.
///
/// - A fresh snapshot is the answer: no request (unless an explicit refresh
///   was asked since it was saved: `CatalogSnapshotStore.expireAll`).
/// - A stale one is handed to `snapshot` at once when the caller gave one
///   (it paints it), and the network's list then comes through `completion`.
///   Without a `snapshot` handler the caller can show one list only: the
///   network's, which is waited for (`load` has its own deadline). (The
///   stale list used to be the answer after 1.5 s: on a slow link a pull to
///   refresh gave back the list it was refreshing, and a launch a list up
///   to a week old, the network's being saved for the load after.)
/// - The network failed, or came back empty: the stale list, when there is one.
/// - A list the network says is partial (a source that normally feeds it
///   was left out) is delivered but not saved: the next load asks again.
///
/// `load` is the network load (items, error, partial); `encode` / `decode`
/// turn the models into their JSON and back. Main queue: `load` must call back there, and
/// `snapshot` / `completion` run there (`snapshot` first, at most once).
enum CatalogSnapshotLoader {

    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    static let mainQueue: Scheduler = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    static func load<Item>(key: String,
                           freshness: CatalogFreshness,
                           store: CatalogSnapshotStore,
                           schedule: @escaping Scheduler = CatalogSnapshotLoader.mainQueue,
                           encode: @escaping ([Item]) -> [[String: Any]],
                           decode: @escaping ([[String: Any]]) -> [Item],
                           load: (_ completion: @escaping ([Item]?, NSError?, _ partial: Bool) -> Void) -> Void,
                           snapshot: (([Item]) -> Void)?,
                           completion: @escaping ([Item]?, NSError?) -> Void) {
        var state = CatalogFreshness.State.expired
        var saved: [Item] = []
        if let found = store.read(key) {
            state = freshness.state(age: found.age)
            if state == .fresh, store.mustBeAskedAgain(found.snapshot) { state = .stale }
            if state != .expired { saved = decode(found.snapshot.items) }
            if saved.isEmpty { state = .expired }
        }
        if state == .fresh {
            return schedule(0) { completion(saved, nil) }
        }

        let once = Once<([Item]?, NSError?)> { completion($0.0, $0.1) }
        if state == .stale, let snapshot = snapshot {
            // Never after the network's list (a `load` that answers at once).
            schedule(0) { if !once.isDone { snapshot(saved) } }
        }
        load { items, error, partial in
            if let items = items, !items.isEmpty {
                if !partial { store.write(key, items: encode(items)) }
                once((items, nil))
            } else if state == .stale {
                once((saved, nil))
            } else {
                once((items, error))
            }
        }
    }
}
