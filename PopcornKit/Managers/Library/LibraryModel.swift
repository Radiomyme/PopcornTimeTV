import Foundation

// The user's library: what was watched, what is in progress, which shows are
// followed and what aired since. Plain values and pure rules live in this
// folder so they can be tested without the network, a clock or UserDefaults:
//
//   LibraryModel.swift           ids, guide episodes, the one policy, storage
//   WatchStateStore.swift        the six legacy UserDefaults lists, in memory
//   ContinueWatchingStore.swift  timestamped resume entries + their migration
//   NextUp.swift                 the episode a show continues with
//   ShowGuideCache.swift         episode guides on disk (Caches)
//   NewEpisodes.swift            what aired since the last watched episode
//   LibraryRemote.swift          Cinemeta / TVMaze answers → guides
//   Library.swift                the façade the managers and the UIs call
//   Library+Media.swift          Movie / Show / Episode ↔ the plain values;
//                                the players' save and its 30 s checkpoint

/// A season / episode number.
public struct EpisodeNumber: Hashable, Comparable, Codable {
    public let season: Int
    public let episode: Int

    public init(season: Int, episode: Int) {
        self.season = season
        self.episode = episode
    }

    public static func < (lhs: EpisodeNumber, rhs: EpisodeNumber) -> Bool {
        return lhs.season == rhs.season ? lhs.episode < rhs.episode : lhs.season < rhs.season
    }

    /// Season 0: specials, never where a show continues.
    public var isSpecial: Bool { return season <= 0 }
}

/// What a stored media id says. Movies and shows are IMDb ids ("tt0111161");
/// an episode is "<show IMDb id>-s<season>e<number>" since 5.0.0. 4.x stored
/// episodes under their numeric TVDB id: those say nothing about the show.
public enum LibraryID {

    /// "tt0903747-s1e1" → (tt0903747, S1E1); nil for anything else (a movie
    /// id, a 4.x TVDB number, a torrent hash).
    public static func episode(_ id: String) -> (showID: String, number: EpisodeNumber)? {
        guard let dash = id.lastIndex(of: "-") else { return nil }
        let showID = String(id[..<dash])
        guard isIMDb(showID) else { return nil }
        let tail = id[id.index(after: dash)...]
        guard tail.first == "s", let e = tail.firstIndex(of: "e"),
              let season = Int(tail[tail.index(after: tail.startIndex)..<e]),
              let number = Int(tail[tail.index(after: e)...]),
              season >= 0, number >= 0 else { return nil }
        return (showID, EpisodeNumber(season: season, episode: number))
    }

    /// The id the providers give an episode.
    public static func episodeID(showID: String, _ number: EpisodeNumber) -> String {
        return "\(showID)-s\(number.season)e\(number.episode)"
    }

    /// "tt" followed by digits only.
    public static func isIMDb(_ id: String) -> Bool {
        return id.count > 2 && id.hasPrefix("tt") && id.dropFirst(2).allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// One episode of a show's guide, as much as the library needs of it.
public struct GuideEpisode: Hashable, Codable {
    public let season: Int
    public let episode: Int
    public var title: String?
    /// First air date; nil = unknown (counts as aired, like the detail page).
    public var aired: Date?
    /// A torrent is already listed: playable whatever the date says.
    public var hasSource: Bool

    public init(season: Int, episode: Int, title: String? = nil, aired: Date? = nil, hasSource: Bool = false) {
        self.season = season
        self.episode = episode
        self.title = title
        self.aired = aired
        self.hasSource = hasSource
    }

    public var number: EpisodeNumber { return EpisodeNumber(season: season, episode: episode) }

    /// Can be played at `now`: aired, undated, or already offered.
    public func isAvailable(at now: Date) -> Bool {
        guard !hasSource, let aired = aired else { return true }
        return aired <= now
    }

    // Short keys: a long show's guide is thousands of these on disk.
    private enum CodingKeys: String, CodingKey {
        case season = "s", episode = "e", title = "t", aired = "a", hasSource = "x"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        season = try container.decode(Int.self, forKey: .season)
        episode = try container.decode(Int.self, forKey: .episode)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        aired = try container.decodeIfPresent(Double.self, forKey: .aired).map(Date.init(timeIntervalSince1970:))
        hasSource = try container.decodeIfPresent(Bool.self, forKey: .hasSource) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(season, forKey: .season)
        try container.encode(episode, forKey: .episode)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(aired.map { $0.timeIntervalSince1970.rounded() }, forKey: .aired)
        if hasSource { try container.encode(true, forKey: .hasSource) }
    }
}

/// The one set of thresholds of the watch state. Every reader goes through it
/// (the Continue Watching row, "next up", new episodes, the managers).
public struct LibraryPolicy {

    /// Below both, a title was only opened, not started: no card, and it does
    /// not move a show's "next up".
    public var startedFraction: Float = 0.02
    public var startedSeconds: TimeInterval = 60

    /// At or above: watched (the mark the managers set since 4.x).
    public var watchedFraction: Float = 0.80

    /// A Continue Watching card leaves the row this long after its last play.
    public var rowExpiry: TimeInterval = 90 * 86400

    /// A show with a watched or started episode is followed this long after
    /// the last one.
    public var followedActivityWindow: TimeInterval = 180 * 86400

    /// An episode aired within this is recent enough to be "new" whenever
    /// the user last watched (and it is all that makes one new in a
    /// watchlisted show never started).
    public var newEpisodeWindow: TimeInterval = 14 * 86400

    /// Episodes airing within this are "upcoming".
    public var upcomingWindow: TimeInterval = 7 * 86400

    /// How long a show's airings are trusted before they are asked again.
    public var airingsLifetime: TimeInterval = 6 * 3600

    /// New-episode detection looks at this many of a show's latest aired
    /// episodes (what Cinemeta's calendar returns), whatever the guide's size.
    public var recentAiringsCount = 10

    /// The players save the position this often during playback.
    public var checkpointInterval: TimeInterval = 30

    /// Resume entries kept (the least recently played leave first). About
    /// 200 bytes each with its titles: 40 KB at most (measured: 300 entries
    /// = 59 KB), next to the 1 MB tvOS allows the whole defaults domain.
    public var maxEntries = 200

    public init() {}

    public static let standard = LibraryPolicy()

    /// Played enough to be a title in progress. `position` in seconds, when
    /// the player told it.
    public func isStarted(progress: Float, position: TimeInterval?) -> Bool {
        return progress >= startedFraction || (position ?? 0) >= startedSeconds
    }

    public func isFinished(progress: Float) -> Bool {
        return progress >= watchedFraction
    }
}

/// Where the library keeps its small durable state. `UserDefaults` in the
/// apps (on tvOS the only local storage that is never purged); a dictionary
/// in the tests.
public protocol LibraryStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: LibraryStorage {}

/// A `LibraryStorage` in memory (tests, previews).
public final class MemoryLibraryStorage: LibraryStorage {
    private let lock = NSLock()
    private var values: [String: Any]

    public init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    public func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    public var keys: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(values.keys)
    }
}

/// The change notification of the library. Posted on the main thread after
/// every write; `userInfo` says what changed so a screen can update one card.
public enum LibraryChange {

    public enum Reason: String {
        /// A watched mark was set or cleared.
        case watched
        /// A playback position was saved or deleted.
        case progress
        /// A title entered or left the watchlist.
        case watchlist
        /// Titles or guides were filled in (hydration), or a card was dismissed.
        case continueWatching
        /// Airings were refreshed, or new episodes were acknowledged.
        case newEpisodes
    }

    /// `userInfo` key: `Set<String>` of the media ids touched ("tt…" for a
    /// movie or a show, "tt…-sXeY" for an episode — its show id is included).
    public static let idsKey = "ids"
    /// `userInfo` key: the `Reason`'s raw value.
    public static let reasonKey = "reason"

    public static func ids(of notification: Notification) -> Set<String> {
        return notification.userInfo?[idsKey] as? Set<String> ?? []
    }

    public static func reason(of notification: Notification) -> Reason? {
        return (notification.userInfo?[reasonKey] as? String).flatMap(Reason.init(rawValue:))
    }
}

public extension Notification.Name {
    /// See `LibraryChange`.
    static let libraryDidChange = Notification.Name("PopcornKit.Library.didChange")
}
