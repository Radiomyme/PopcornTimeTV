import Foundation

/// One title the user played: where it stopped and when. What "Continue
/// Watching" is built from, without asking any server.
public struct ContinueWatchingEntry: Codable, Equatable {

    public enum Kind: String, Codable {
        case movie
        case episode
    }

    /// The id the progress is saved under: "tt…" (movie) or "tt…-sXeY" (episode).
    public let mediaID: String
    public let kind: Kind
    /// An episode's show (IMDb id), season and number.
    public var showID: String?
    public var season: Int?
    public var episode: Int?
    /// The movie's title, or the show's for an episode. nil until known
    /// (entries migrated from 5.2 only had an id).
    public var title: String?
    public var episodeTitle: String?
    /// Catalogue runtime in minutes (the movie's, or the show's episodes').
    public var runtime: Int?
    /// 0…1, the value the progress list holds.
    public var progress: Float
    /// Seconds, when the player told them.
    public var position: TimeInterval?
    public var duration: TimeInterval?
    /// Last time this title was played, marked watched or migrated.
    public var updatedAt: Date
    /// Watched (an episode's entry stays: it is where the show continues from).
    public var isFinished: Bool
    /// The release it was played from (5.3.0, key "rl"): what « Resume » and
    /// the next episode replay without asking. nil for entries saved before.
    public var release: RememberedRelease?

    public init(mediaID: String, kind: Kind, showID: String? = nil, season: Int? = nil, episode: Int? = nil,
                title: String? = nil, episodeTitle: String? = nil, runtime: Int? = nil, progress: Float,
                position: TimeInterval? = nil, duration: TimeInterval? = nil, updatedAt: Date, isFinished: Bool = false,
                release: RememberedRelease? = nil) {
        self.mediaID = mediaID
        self.kind = kind
        self.showID = showID
        self.season = season
        self.episode = episode
        self.title = title
        self.episodeTitle = episodeTitle
        self.runtime = runtime
        self.progress = progress
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
        self.isFinished = isFinished
        self.release = release
    }

    /// The show's title of an episode.
    public var showTitle: String? { return kind == .episode ? title : nil }

    /// The IMDb id artwork is derived from: the movie, or the episode's show.
    public var imdbID: String { return showID ?? mediaID }

    public var number: EpisodeNumber? {
        guard let season = season, let episode = episode else { return nil }
        return EpisodeNumber(season: season, episode: episode)
    }

    // Short keys and no nil: on tvOS the entries live in UserDefaults.
    private enum CodingKeys: String, CodingKey {
        case mediaID = "i", kind = "k", showID = "sh", season = "s", episode = "e", title = "t", episodeTitle = "et"
        case runtime = "r", progress = "p", position = "ps", duration = "d", updatedAt = "u", isFinished = "f"
        case release = "rl"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaID = try container.decode(String.self, forKey: .mediaID)
        kind = try container.decode(Kind.self, forKey: .kind)
        showID = try container.decodeIfPresent(String.self, forKey: .showID)
        season = try container.decodeIfPresent(Int.self, forKey: .season)
        episode = try container.decodeIfPresent(Int.self, forKey: .episode)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        episodeTitle = try container.decodeIfPresent(String.self, forKey: .episodeTitle)
        runtime = try container.decodeIfPresent(Int.self, forKey: .runtime)
        progress = try container.decodeIfPresent(Float.self, forKey: .progress) ?? 0
        position = try container.decodeIfPresent(Double.self, forKey: .position)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        updatedAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .updatedAt))
        isFinished = try container.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false
        // An unreadable release is no release: the entry stays.
        release = (try? container.decodeIfPresent(RememberedRelease.self, forKey: .release)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mediaID, forKey: .mediaID)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(showID, forKey: .showID)
        try container.encodeIfPresent(season, forKey: .season)
        try container.encodeIfPresent(episode, forKey: .episode)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(episodeTitle, forKey: .episodeTitle)
        try container.encodeIfPresent(runtime, forKey: .runtime)
        if progress != 0 { try container.encode(progress, forKey: .progress) }
        try container.encodeIfPresent(position.map { $0.rounded() }, forKey: .position)
        try container.encodeIfPresent(duration.map { $0.rounded() }, forKey: .duration)
        try container.encode(updatedAt.timeIntervalSince1970.rounded(), forKey: .updatedAt)
        if isFinished { try container.encode(true, forKey: .isFinished) }
        try container.encodeIfPresent(release, forKey: .release)
    }
}

/// What a player knows about the title it saves the position of, beyond the
/// fraction: the richer half of `WatchedlistManager.setCurrentProgress`.
public struct PlaybackDetails {
    public var title: String?
    public var episodeTitle: String?
    public var showID: String?
    public var number: EpisodeNumber?
    public var runtime: Int?
    public var position: TimeInterval?
    public var duration: TimeInterval?
    /// The release playing (`PlaybackReleaseRegistry`): stored with the entry.
    public var release: RememberedRelease?

    public init(title: String? = nil, episodeTitle: String? = nil, showID: String? = nil, number: EpisodeNumber? = nil,
                runtime: Int? = nil, position: TimeInterval? = nil, duration: TimeInterval? = nil,
                release: RememberedRelease? = nil) {
        self.title = title
        self.episodeTitle = episodeTitle
        self.showID = showID
        self.number = number
        self.runtime = runtime
        self.position = position
        self.duration = duration
        self.release = release
    }
}

/// The resume entries: one small JSON blob in `storage`, a copy in memory.
///
/// Written from one place — `Library.setProgress` / `setWatched`, which the
/// managers call (`record`) — so an entry always says what the progress and
/// watched lists say. The first read builds the entries from the 5.2 lists (which
/// had no dates, no titles): see `migrated(from:)`. The 5.2 lists stay as
/// they are.
///
/// Bounded: a finished movie's entry is deleted, a show keeps its episodes in
/// progress plus the last one finished, and beyond `policy.maxEntries` (200,
/// about 40 KB) the least recently played leave.
final class ContinueWatchingStore {

    static let storageKey = "continueWatchingEntries"

    private struct Blob: Codable {
        var version = 1
        var entries: [ContinueWatchingEntry]
    }

    private let storage: LibraryStorage
    private let policy: LibraryPolicy
    private let now: () -> Date
    /// Reads the 5.2 lists for the one-off migration.
    private let legacy: WatchStateStore
    private let lock = NSLock()
    private var entries: [String: ContinueWatchingEntry]?

    init(storage: LibraryStorage, legacy: WatchStateStore, policy: LibraryPolicy = .standard, now: @escaping () -> Date) {
        self.storage = storage
        self.legacy = legacy
        self.policy = policy
        self.now = now
    }

    /// Forgets the in-memory copy (something else wrote the storage).
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        entries = nil
    }

    // MARK: - Reads

    func entry(_ mediaID: String) -> ContinueWatchingEntry? {
        lock.lock(); defer { lock.unlock() }
        return loaded()[mediaID]
    }

    /// Every entry, the most recently played first.
    func allEntries() -> [ContinueWatchingEntry] {
        lock.lock(); defer { lock.unlock() }
        return loaded().values.sorted(by: ContinueWatchingStore.moreRecent)
    }

    func entries(ofShow showID: String) -> [ContinueWatchingEntry] {
        lock.lock(); defer { lock.unlock() }
        return loaded().values.filter { $0.showID == showID }
    }

    /// Most recent first; the id breaks a tie so the order is stable.
    static func moreRecent(_ a: ContinueWatchingEntry, _ b: ContinueWatchingEntry) -> Bool {
        return a.updatedAt == b.updatedAt ? a.mediaID < b.mediaID : a.updatedAt > b.updatedAt
    }

    // MARK: - Writes

    /// `mediaID` was played to `progress` (nil: only marked watched), now.
    /// `isWatched`: its watched mark after that.
    ///
    /// A watched movie has no entry (nothing to continue). A watched episode
    /// keeps one — it is where its show continues from — and replaces the
    /// show's other finished episodes.
    func record(mediaID: String, kind: ContinueWatchingEntry.Kind, progress: Float?, isWatched: Bool, details: PlaybackDetails?) {
        mutate { entries in
            if kind == .movie, isWatched {
                entries[mediaID] = nil
                return
            }
            guard var entry = entries[mediaID] ?? ContinueWatchingStore.newEntry(mediaID, kind, details: details, at: now()) else { return }
            if let progress = progress { entry.progress = progress }
            entry.isFinished = isWatched
            entry.updatedAt = now()
            ContinueWatchingStore.apply(details, to: &entry)
            if let progress = progress, let duration = entry.duration, duration > 0, details?.position == nil {
                // The fraction moved but the player gave no position.
                entry.position = Double(progress) * duration
            }
            entries[mediaID] = entry
            guard isWatched else { return }
            for (id, other) in entries where id != mediaID && other.showID == entry.showID && other.isFinished {
                entries[id] = nil
            }
        }
    }

    /// The progress of `mediaID` was deleted or its watched mark cleared.
    /// Returns the entry removed.
    @discardableResult
    func remove(mediaID: String) -> ContinueWatchingEntry? {
        var removed: ContinueWatchingEntry?
        mutate { removed = $0.removeValue(forKey: mediaID) }
        return removed
    }

    /// Puts back a show's finished entry (its last one was un-marked: the
    /// show continues from `entry`'s episode) with the date it carries. An
    /// entry the episode already has becomes that one, and keeps the later
    /// date.
    func restore(_ entry: ContinueWatchingEntry) {
        mutate { entries in
            guard var known = entries[entry.mediaID] else {
                entries[entry.mediaID] = entry
                return
            }
            known.isFinished = true
            known.updatedAt = max(known.updatedAt, entry.updatedAt)
            entries[entry.mediaID] = known
        }
    }

    /// Forgets the release remembered with `mediaID`'s entry, or with every
    /// entry of a show (an IMDb show id): it failed to play again. Returns
    /// whether one was there.
    ///
    /// With `sourceKey`, only that release goes, and wherever the title
    /// remembers it: an episode's id also reaches the other episodes of its
    /// show that remember it (a season pack replayed for an episode not
    /// started yet is remembered with the show's other entries, not its own).
    @discardableResult
    func forgetRelease(_ id: String, sourceKey: String? = nil) -> Bool {
        var found = false
        let showOfEpisode = sourceKey == nil ? nil : LibraryID.episode(id)?.showID
        mutate { entries in
            for (key, var entry) in entries where entry.release != nil {
                let isTitle = key == id || (entry.kind == .episode && (entry.showID == id || (showOfEpisode != nil && entry.showID == showOfEpisode)))
                guard isTitle, sourceKey == nil || entry.release?.sourceKey == sourceKey else { continue }
                entry.release = nil
                entries[key] = entry
                found = true
            }
        }
        return found
    }

    /// Drops every entry of a show (its card was dismissed). Returns the
    /// entries removed.
    @discardableResult
    func removeShow(_ showID: String) -> [ContinueWatchingEntry] {
        var removed: [ContinueWatchingEntry] = []
        mutate { entries in
            for (id, entry) in entries where entry.showID == showID {
                removed.append(entry)
                entries[id] = nil
            }
        }
        return removed
    }

    /// Fills in what was learnt about a title (hydration): never touches the
    /// progress or the date. Returns whether anything changed.
    @discardableResult
    func fill(imdbID: String, title: String?, runtime: Int?, episodeTitles: [EpisodeNumber: String] = [:]) -> Bool {
        var changed = false
        mutate { entries in
            for (id, var entry) in entries where entry.imdbID == imdbID {
                let before = entry
                if let title = title, !title.isEmpty, entry.title == nil { entry.title = title }
                if let runtime = runtime, runtime > 0, entry.runtime == nil { entry.runtime = runtime }
                if entry.episodeTitle == nil, let number = entry.number, let name = episodeTitles[number], !name.isEmpty {
                    entry.episodeTitle = name
                }
                if entry != before {
                    entries[id] = entry
                    changed = true
                }
            }
        }
        return changed
    }

    private func mutate(_ change: (inout [String: ContinueWatchingEntry]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var current = loaded()
        let before = current
        change(&current)
        guard current != before else { return }
        if current.count > policy.maxEntries {
            let kept = current.values.sorted(by: ContinueWatchingStore.moreRecent).prefix(policy.maxEntries)
            current = Dictionary(uniqueKeysWithValues: kept.map { ($0.mediaID, $0) })
        }
        entries = current
        persist(current)
    }

    private static func newEntry(_ mediaID: String, _ kind: ContinueWatchingEntry.Kind, details: PlaybackDetails?,
                                 at date: Date) -> ContinueWatchingEntry? {
        switch kind {
        case .movie:
            return ContinueWatchingEntry(mediaID: mediaID, kind: .movie, progress: 0, updatedAt: date)
        case .episode:
            // The id says the show; a player's details win (they come from
            // the episode itself). An episode of no known show (a 4.x TVDB
            // id) has no card to make: only the progress list keeps it.
            let parsed = LibraryID.episode(mediaID)
            guard let showID = details?.showID ?? parsed?.showID, let number = details?.number ?? parsed?.number else { return nil }
            return ContinueWatchingEntry(mediaID: mediaID, kind: .episode, showID: showID, season: number.season,
                                         episode: number.episode, progress: 0, updatedAt: date)
        }
    }

    private static func apply(_ details: PlaybackDetails?, to entry: inout ContinueWatchingEntry) {
        guard let details = details else { return }
        if let title = details.title, !title.isEmpty { entry.title = title }
        if let title = details.episodeTitle, !title.isEmpty { entry.episodeTitle = title }
        if let runtime = details.runtime, runtime > 0 { entry.runtime = runtime }
        if let duration = details.duration, duration.isFinite, duration > 0 { entry.duration = duration }
        if let position = details.position, position.isFinite, position >= 0 { entry.position = position }
        if let release = details.release { entry.release = release }
    }

    // MARK: - Storage (lock held)

    private func loaded() -> [String: ContinueWatchingEntry] {
        if let entries = entries { return entries }
        let loaded: [String: ContinueWatchingEntry]
        if let data = storage.object(forKey: ContinueWatchingStore.storageKey) as? Data,
           let blob = try? JSONDecoder().decode(Blob.self, from: data) {
            loaded = Dictionary(blob.entries.map { ($0.mediaID, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        } else {
            // First launch of 5.3 (or an unreadable blob): from the 5.2 lists.
            let migrated = ContinueWatchingStore.migrated(movieProgress: legacy.allProgress(.movies),
                                                          watchedMovies: legacy.watchedSet(.movies),
                                                          episodeProgress: legacy.allProgress(.episodes),
                                                          watchedEpisodes: legacy.watchedIDs(.episodes),
                                                          policy: policy, at: now())
            loaded = Dictionary(uniqueKeysWithValues: migrated.map { ($0.mediaID, $0) })
            persist(loaded)
        }
        entries = loaded
        return loaded
    }

    private func persist(_ entries: [String: ContinueWatchingEntry]) {
        // Sorted: the same entries give the same bytes.
        let blob = Blob(entries: entries.values.sorted(by: ContinueWatchingStore.moreRecent))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(blob) else { return }
        storage.set(data, forKey: ContinueWatchingStore.storageKey)
    }

    // MARK: - Migration

    /// The entries the 5.2 lists stand for. Pure; nothing is read but the
    /// arguments and nothing is ever force-unwrapped:
    ///
    /// - a movie with a progress and no watched mark: one entry;
    /// - an episode "tt…-sXeY" with a progress and no watched mark: one entry;
    /// - per show, its furthest watched episode (the lists have no dates: the
    ///   furthest is the best guess of the latest), as a finished entry;
    /// - anything else — 4.x numeric TVDB ids, hashes — has no entry: it says
    ///   nothing about a show. It stays in the old lists, untouched.
    ///
    /// The lists carry no dates. Every entry is dated just before `date`, one
    /// second apart, in an order that makes "the most recent" mean what 5.2
    /// showed: within a show, the furthest episode touched is the latest.
    /// Between titles there is nothing to go by: the higher IMDb number (as
    /// a rule the more recent title) comes first in the row.
    static func migrated(movieProgress: [String: Float], watchedMovies: Set<String>,
                         episodeProgress: [String: Float], watchedEpisodes: [String],
                         policy: LibraryPolicy, at date: Date) -> [ContinueWatchingEntry] {
        var result: [ContinueWatchingEntry] = []

        for (id, progress) in movieProgress
        where LibraryID.isIMDb(id) && !watchedMovies.contains(id) && !policy.isFinished(progress: progress) && progress > 0 {
            result.append(ContinueWatchingEntry(mediaID: id, kind: .movie, progress: progress, updatedAt: date))
        }

        let watched = Set(watchedEpisodes)
        var furthestWatched: [String: EpisodeNumber] = [:]
        for id in watched {
            guard let (showID, number) = LibraryID.episode(id), !number.isSpecial else { continue }
            if let known = furthestWatched[showID], known >= number { continue }
            furthestWatched[showID] = number
        }
        for (showID, number) in furthestWatched {
            let id = LibraryID.episodeID(showID: showID, number)
            result.append(ContinueWatchingEntry(mediaID: id, kind: .episode, showID: showID, season: number.season,
                                                episode: number.episode, progress: episodeProgress[id] ?? 0,
                                                updatedAt: date, isFinished: true))
        }
        for (id, progress) in episodeProgress where !watched.contains(id) && !policy.isFinished(progress: progress) && progress > 0 {
            guard let (showID, number) = LibraryID.episode(id) else { continue }
            result.append(ContinueWatchingEntry(mediaID: id, kind: .episode, showID: showID, season: number.season,
                                                episode: number.episode, progress: progress, updatedAt: date))
        }

        // Oldest first: by IMDb number, then by episode.
        func rank(_ entry: ContinueWatchingEntry) -> Int { return Int(entry.imdbID.dropFirst(2)) ?? 0 }
        result.sort { a, b in
            if a.imdbID != b.imdbID { return (rank(a), a.imdbID) < (rank(b), b.imdbID) }
            return (a.number ?? EpisodeNumber(season: 0, episode: 0)) < (b.number ?? EpisodeNumber(season: 0, episode: 0))
        }
        // One second apart, the last one a minute before the migration.
        let start = date.addingTimeInterval(-60 - Double(result.count))
        for index in result.indices {
            result[index].updatedAt = start.addingTimeInterval(Double(index))
        }
        if result.count > policy.maxEntries {
            result = Array(result.suffix(policy.maxEntries))
        }
        return result
    }
}
