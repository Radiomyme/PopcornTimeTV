import Foundation

/// The hub's cache: stale-while-revalidate, on disk, per source — the model
/// of `PirateBayTop100`, with the clock and the folder injected.
///
/// - `HomeCachePolicy`: is a list fresh, stale or expired; does a new answer
///   replace the one already kept. Pure.
/// - `HomeStore`: one small JSON file per source in a folder.
///
/// A list is shown as long as it is not expired; it is asked again as soon
/// as it is not fresh. The lifetimes follow what the servers announce and
/// how fast each list really moves (feeds-live §5.5).

// MARK: - Policy

public enum HomeCachePolicy {

    public enum State: Equatable, Sendable {
        /// Shown, not asked again.
        case fresh
        /// Shown, and asked again at the next refresh.
        case stale
        /// Not shown any more.
        case expired
    }

    /// How long a list is fresh, and how long it may still be shown after.
    public struct Lifetime: Equatable, Sendable {
        public var fresh: TimeInterval
        public var usable: TimeInterval

        public init(fresh: TimeInterval, usable: TimeInterval) {
            self.fresh = fresh
            self.usable = usable
        }

        private static let hour: TimeInterval = 3600
        private static let day: TimeInterval = 86_400

        /// Cinemeta top, imdbRating, year, genre: `max-age=14400`.
        public static let cinemetaCatalogue = Lifetime(fresh: 4 * hour, usable: 7 * day)
        /// Cinemeta calendar-videos: `max-age=21600`.
        public static let cinemetaCalendar = Lifetime(fresh: 6 * hour, usable: 3 * day)
        /// YTS latest additions (new movies, 4K): about 20 additions a day, `no-store`.
        public static let ytsRecent = Lifetime(fresh: 30 * 60, usable: day)
        /// YTS rankings of the year: they move slowly.
        public static let ytsYear = Lifetime(fresh: 6 * hour, usable: 7 * day)
        /// TVMaze, today's schedule: `max-age=3600`.
        public static let tvmazeToday = Lifetime(fresh: hour, usable: day)
        /// TVMaze, a past day: nearly immutable.
        public static let tvmazePast = Lifetime(fresh: day, usable: 7 * day)
        /// apibay precompiled lists: `max-age=7200`.
        public static let apibay = Lifetime(fresh: 2 * hour, usable: day)
        /// Metadata lookups: a title's card does not change.
        public static let lookup = Lifetime(fresh: 7 * day, usable: 7 * day)
        /// TMDB's streaming catalogues: JustWatch updates them daily, and
        /// what a service offers moves slowly.
        public static let streaming = Lifetime(fresh: 12 * hour, usable: 7 * day)
    }

    /// The lifetime of a source's list, by its cache key. `now` tells today's
    /// TVMaze schedule (still filling up) from a past day's.
    public static func lifetime(forKey key: String, now: Date) -> Lifetime {
        if key.hasPrefix(HomeSource.calendarPrefix) { return .cinemetaCalendar }
        if key.hasPrefix(HomeSource.lookupPrefix) { return .lookup }
        if key.hasPrefix("cm-") { return .cinemetaCatalogue }
        if key.hasPrefix(HomeSource.ytsNewPrefix) || key == HomeSource.yts4K.key { return .ytsRecent }
        if key.hasPrefix("yts-") { return .ytsYear }
        if key.hasPrefix(HomeSource.tvmazePrefix) {
            // "tvm-web-2026-11-14": ISO days compare as text.
            return String(key.suffix(10)) >= CatalogDates.dayString(now) ? .tvmazeToday : .tvmazePast
        }
        if key.hasPrefix(HomeSource.apibayPrefix) { return .apibay }
        if key.hasPrefix(HomeSource.tmdbPrefix) { return .streaming }
        return .tvmazeToday
    }

    /// The state of a list saved at `savedAt`. An incomplete list (a short
    /// answer) is never fresh: it is shown and asked again. A date in the
    /// future (the clock was set back) is not trusted to be fresh either.
    public static func state(savedAt: Date, now: Date, lifetime: Lifetime, complete: Bool = true) -> State {
        let age = now.timeIntervalSince(savedAt)
        if age >= lifetime.usable { return .expired }
        if age < 0 || age >= lifetime.fresh || !complete { return .stale }
        return .fresh
    }

    /// What to do with a new answer.
    public struct Decision: Equatable, Sendable {
        /// Keep it (else the list already kept stays).
        public var accept: Bool
        /// It is as long as the source is expected to be.
        public var complete: Bool
    }

    /// Does an answer of `count` entries replace the list already kept?
    /// - A complete answer (`minimum` entries or more; none at all when the
    ///   source `allowsEmpty` and expects none) always does.
    /// - A shorter one does only when it is not shorter than the list kept
    ///   (`previous`: its size, nil when there is none or it is expired): an
    ///   incomplete refresh never replaces a fuller list.
    /// - An empty one from a source that always has entries is a failure.
    public static func decision(count: Int, minimum: Int, allowsEmpty: Bool, previous: Int?) -> Decision {
        let complete = count >= minimum && (count > 0 || allowsEmpty)
        if complete { return Decision(accept: true, complete: true) }
        if count == 0 && !allowsEmpty { return Decision(accept: false, complete: false) }
        if let previous = previous, previous > count { return Decision(accept: false, complete: false) }
        return Decision(accept: true, complete: false)
    }
}

// MARK: - Disk

/// The lists of the hub on disk: one JSON file per source key in
/// `directory`, written atomically. The clock is injected (tests), the
/// folder too (a folder of an App Group container shares it with the Top
/// Shelf extension). Thread-safe.
///
/// Give it a folder of its own. It only reads, replaces and deletes the
/// files it names itself — "<source key>.json" (`HomeSource.keyFamilies`)
/// and "down.json" — and leaves every other file of the folder alone, but
/// it does delete those when they are expired, of another format version
/// or unreadable.
public final class HomeStore: @unchecked Sendable {

    public let directory: URL
    private let now: () -> Date
    private let lock = NSLock()

    /// The default folder: Caches/popcornkit-home (the system may empty it;
    /// the hub then loads as on a first launch). Overridable — before the
    /// first use of `HomeFeed.shared` — to put the cache in a folder of an
    /// App Group container the Top Shelf extension reads too: a folder for
    /// the hub alone ("<container>/popcornkit-home"), not the container's
    /// root.
    public static var defaultDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("popcornkit-home", isDirectory: true)
    }()

    public init(directory: URL = HomeStore.defaultDirectory, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    private static let fileExtension = "json"

    private func url(_ key: String) -> URL {
        // Keys are made of letters, digits and dashes (`HomeSource`); anything
        // else would be a path.
        let safe = key.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "_" }
        return directory.appendingPathComponent(String(safe)).appendingPathExtension(HomeStore.fileExtension)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// The files of the folder that are lists of the store: named after a
    /// source key. Whatever else is in the folder is not the store's.
    private func listFiles(_ keys: [URLResourceKey]? = nil) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return files.filter { file in
            file.pathExtension == HomeStore.fileExtension && HomeSource.host(ofKey: file.lastPathComponent) != nil
        }
    }

    /// Every list on disk that is not expired, by key. Expired lists, lists
    /// of another format version and unreadable ones are deleted.
    func readAll() -> [String: HomeSourceList] {
        lock.lock()
        defer { lock.unlock() }
        var lists: [String: HomeSourceList] = [:]
        let now = self.now()
        for file in listFiles() {
            guard let data = try? Data(contentsOf: file),
                  let list = try? HomeStore.decoder.decode(HomeSourceList.self, from: data),
                  list.version == HomeSourceList.currentVersion,
                  HomeCachePolicy.state(savedAt: list.savedAt, now: now,
                                        lifetime: HomeCachePolicy.lifetime(forKey: list.key, now: now),
                                        complete: list.complete) != .expired
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            lists[list.key] = list
        }
        return lists
    }

    func write(_ list: HomeSourceList) {
        guard let data = try? HomeStore.encoder.encode(list) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(list.key), options: .atomic)
    }

    func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(key))
    }

    // MARK: Sources down

    /// Not a source key: `readAll` does not take it for a list.
    private var downFile: URL {
        return directory.appendingPathComponent("down").appendingPathExtension(HomeStore.fileExtension)
    }

    /// The keys of the sources that gave no list at their last attempt
    /// (`HomeFeed`), kept next to the lists: a new launch paints the page of
    /// the last session, the stand-ins of those sources included.
    func readDown() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: downFile),
              let keys = try? HomeStore.decoder.decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    func write(down keys: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        guard !keys.isEmpty, let data = try? HomeStore.encoder.encode(keys.sorted()) else {
            try? FileManager.default.removeItem(at: downFile)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: downFile, options: .atomic)
    }

    /// Deletes every list: the next start loads as on a first launch.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for file in listFiles() + [downFile] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Bytes the store has on disk (settings, diagnostics).
    public var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return (listFiles([.fileSizeKey]) + [downFile]).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
