import Foundation

/// The six lists `WatchedlistManager` / `WatchlistManager` have kept in
/// UserDefaults since 4.x, read once and served from memory:
///
///   moviesWatchedlist, episodesWatchedlist   [String]           watched ids
///   moviesProgress, episodesProgress         [String: Float]    0…1 by id
///   moviesWatchlist, showsWatchlist          [[String: Any]]    ObjectMapper JSON
///
/// The keys, their shapes and the ids keep their 5.2 form (an older build
/// still reads them; downloads are keyed by the same ids). What changes is
/// the cost: every `isWatched` / `progress` used to re-read and re-convert the
/// whole list from UserDefaults (a show page asked about six times per
/// episode: 139 ms for 100 episodes over a 1,000-episode history, measured),
/// and `isInWatchlist` rebuilt every model of the list with ObjectMapper.
/// Reads are now a dictionary lookup; a write updates the copy and writes
/// the list through.
///
/// Thread-safe. The copy is dropped by `invalidate()` (something else wrote
/// the keys).
final class WatchStateStore {

    /// The lists are keyed by `Trakt.MediaType`'s raw value ("movies",
    /// "episodes", "shows").
    typealias List = Trakt.MediaType

    private struct Watched {
        var order: [String]
        var set: Set<String>
    }

    private struct Watchlist {
        var json: [[String: Any]]
        var ids: Set<String>
        /// The decoded models (`[Movie]` / `[Show]`), until the next write.
        var models: Any?
    }

    private let storage: LibraryStorage
    private let lock = NSLock()
    private var watched: [String: Watched] = [:]
    private var progress: [String: [String: Float]] = [:]
    private var watchlists: [String: Watchlist] = [:]

    init(storage: LibraryStorage) {
        self.storage = storage
    }

    static func watchedKey(_ list: List) -> String { return "\(list.rawValue)Watchedlist" }
    static func progressKey(_ list: List) -> String { return "\(list.rawValue)Progress" }
    static func watchlistKey(_ list: List) -> String { return "\(list.rawValue)Watchlist" }

    /// Forgets the in-memory copy: the next read loads the lists again.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        watched.removeAll()
        progress.removeAll()
        watchlists.removeAll()
    }

    // MARK: - Watched

    func isWatched(_ id: String, _ list: List) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadedWatched(list).set.contains(id)
    }

    /// In the order they were marked.
    func watchedIDs(_ list: List) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return loadedWatched(list).order
    }

    func watchedSet(_ list: List) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return loadedWatched(list).set
    }

    /// Returns whether anything changed.
    @discardableResult
    func setWatched(_ isWatched: Bool, _ id: String, _ list: List) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var current = loadedWatched(list)
        if isWatched {
            guard current.set.insert(id).inserted else { return false }
            current.order.append(id)
        } else {
            guard current.set.remove(id) != nil else { return false }
            current.order.removeAll { $0 == id }
        }
        watched[list.rawValue] = current
        storage.set(current.order, forKey: WatchStateStore.watchedKey(list))
        return true
    }

    /// Adds ids (a Trakt sync): the local marks are never dropped.
    func mergeWatched(_ ids: [String], _ list: List) {
        lock.lock(); defer { lock.unlock() }
        var current = loadedWatched(list)
        let added = ids.filter { current.set.insert($0).inserted }
        guard !added.isEmpty else { return }
        current.order += added
        watched[list.rawValue] = current
        storage.set(current.order, forKey: WatchStateStore.watchedKey(list))
    }

    // MARK: - Progress

    /// 0 when none.
    func progress(_ id: String, _ list: List) -> Float {
        lock.lock(); defer { lock.unlock() }
        return loadedProgress(list)[id] ?? 0
    }

    func allProgress(_ list: List) -> [String: Float] {
        lock.lock(); defer { lock.unlock() }
        return loadedProgress(list)
    }

    /// nil or 0 deletes the entry. Returns whether anything changed.
    @discardableResult
    func setProgress(_ value: Float?, _ id: String, _ list: List) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var current = loadedProgress(list)
        if let value = value, value != 0, value.isFinite {
            guard current[id] != value else { return false }
            current[id] = value
        } else {
            guard current.removeValue(forKey: id) != nil else { return false }
        }
        progress[list.rawValue] = current
        storage.set(current, forKey: WatchStateStore.progressKey(list))
        return true
    }

    /// Sets these values (a Trakt sync); ids only known locally stay.
    func mergeProgress(_ values: [String: Float], _ list: List) {
        lock.lock(); defer { lock.unlock() }
        var current = loadedProgress(list)
        for (id, value) in values where value.isFinite && value != 0 { current[id] = value }
        progress[list.rawValue] = current
        storage.set(current, forKey: WatchStateStore.progressKey(list))
    }

    // MARK: - Watchlist

    func isInWatchlist(_ id: String, _ list: List) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadedWatchlist(list).ids.contains(id)
    }

    /// The stored JSON, in the order the titles were added.
    func watchlistJSON(_ list: List) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return loadedWatchlist(list).json
    }

    /// The ids of the list, in the order the titles were added, each once.
    func watchlistIDs(_ list: List) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        return loadedWatchlist(list).json.compactMap(WatchStateStore.id(ofWatchlistEntry:)).filter { seen.insert($0).inserted }
    }

    /// Appends `json` unless the title is already there (the list used to
    /// take the same title twice). Returns whether anything changed.
    @discardableResult
    func addToWatchlist(_ json: [String: Any], id: String, _ list: List) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var current = loadedWatchlist(list)
        guard current.ids.insert(id).inserted else { return false }
        current.json.append(json)
        current.models = nil
        watchlists[list.rawValue] = current
        storage.set(current.json, forKey: WatchStateStore.watchlistKey(list))
        return true
    }

    /// Fills what the stored entry of the title lacks (a key missing, or an
    /// empty value: a title, a year, the genres) from `json`; nothing it
    /// already holds changes. A title added from a page that had not loaded
    /// yet (a link's id, a Continue Watching card) is completed when its
    /// record arrives. Returns whether anything changed.
    @discardableResult
    func completeWatchlistEntry(_ json: [String: Any], id: String, _ list: List) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var current = loadedWatchlist(list)
        guard current.ids.contains(id),
              let index = current.json.firstIndex(where: { WatchStateStore.id(ofWatchlistEntry: $0) == id }) else { return false }
        guard let entry = WatchStateStore.completed(current.json[index], by: json) else { return false }
        current.json[index] = entry
        current.models = nil
        watchlists[list.rawValue] = current
        storage.set(current.json, forKey: WatchStateStore.watchlistKey(list))
        return true
    }

    /// `entry` with what it lacks taken from `json` (inside its dictionaries
    /// too: "images", "ids"); nil when it lacks nothing `json` has.
    private static func completed(_ entry: [String: Any], by json: [String: Any]) -> [String: Any]? {
        var entry = entry
        var changed = false
        for (key, value) in json where !isEmpty(value) {
            if isEmpty(entry[key]) {
                entry[key] = value
                changed = true
            } else if let inner = entry[key] as? [String: Any], let more = value as? [String: Any],
                      let merged = completed(inner, by: more) {
                entry[key] = merged
                changed = true
            }
        }
        return changed ? entry : nil
    }

    private static func isEmpty(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return true
        case let string as String: return string.isEmpty
        case let array as [Any]: return array.isEmpty
        case let dictionary as [String: Any]: return dictionary.isEmpty
        default: return false
        }
    }

    /// Removes every entry of the title. Returns whether anything changed.
    @discardableResult
    func removeFromWatchlist(id: String, _ list: List) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var current = loadedWatchlist(list)
        guard current.ids.remove(id) != nil else { return false }
        current.json.removeAll { WatchStateStore.id(ofWatchlistEntry: $0) == id }
        current.models = nil
        watchlists[list.rawValue] = current
        storage.set(current.json, forKey: WatchStateStore.watchlistKey(list))
        return true
    }

    /// Replaces the list (a Trakt sync).
    func replaceWatchlist(_ json: [[String: Any]], _ list: List) {
        lock.lock(); defer { lock.unlock() }
        watchlists[list.rawValue] = Watchlist(json: json, ids: Set(json.compactMap(WatchStateStore.id(ofWatchlistEntry:))), models: nil)
        storage.set(json, forKey: WatchStateStore.watchlistKey(list))
    }

    /// The list's models, decoded by `decode` once per change of the list.
    func watchlistModels<Model>(_ list: List, decode: ([[String: Any]]) -> [Model]) -> [Model] {
        lock.lock()
        let current = loadedWatchlist(list)
        lock.unlock()
        if let models = current.models as? [Model] { return models }
        let models = decode(current.json)
        lock.lock()
        // Only if the list is still the one that was decoded.
        if var now = watchlists[list.rawValue], now.json.count == current.json.count, now.ids == current.ids {
            now.models = models
            watchlists[list.rawValue] = now
        }
        lock.unlock()
        return models
    }

    /// The id of a stored `Movie` / `Show` JSON (both write "imdb_id").
    static func id(ofWatchlistEntry json: [String: Any]) -> String? {
        return json["imdb_id"] as? String
    }

    // MARK: - Loading (lock held)

    private func loadedWatched(_ list: List) -> Watched {
        if let hit = watched[list.rawValue] { return hit }
        // Element by element: one foreign value must not empty the list.
        let stored = (storage.object(forKey: WatchStateStore.watchedKey(list)) as? [Any] ?? []).compactMap { $0 as? String }
        var seen = Set<String>()
        let order = stored.filter { seen.insert($0).inserted }
        let loaded = Watched(order: order, set: seen)
        watched[list.rawValue] = loaded
        return loaded
    }

    private func loadedProgress(_ list: List) -> [String: Float] {
        if let hit = progress[list.rawValue] { return hit }
        // Value by value: `as? [String: Float]` is nil for the whole
        // dictionary as soon as one value is a Double that is not exactly a
        // Float (an import, a sync), and the next save then wrote a
        // dictionary holding nothing but the new entry.
        var loaded: [String: Float] = [:]
        for (id, value) in storage.object(forKey: WatchStateStore.progressKey(list)) as? [String: Any] ?? [:] {
            // A number; or a number as text (a list given as a launch
            // argument is an old-style property list: `{ tt… = "0.42"; }`).
            guard let fraction = (value as? NSNumber)?.floatValue ?? (value as? String).flatMap(Float.init) else { continue }
            if fraction.isFinite, fraction != 0 { loaded[id] = fraction }
        }
        progress[list.rawValue] = loaded
        return loaded
    }

    private func loadedWatchlist(_ list: List) -> Watchlist {
        if let hit = watchlists[list.rawValue] { return hit }
        let json = (storage.object(forKey: WatchStateStore.watchlistKey(list)) as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let loaded = Watchlist(json: json, ids: Set(json.compactMap(WatchStateStore.id(ofWatchlistEntry:))), models: nil)
        watchlists[list.rawValue] = loaded
        return loaded
    }
}
