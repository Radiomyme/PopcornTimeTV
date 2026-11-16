import Foundation

/// What aired, and what is about to, in one show the user follows.
public struct ShowNewEpisodes: Equatable {
    /// The show's IMDb id.
    public let showID: String
    public let showTitle: String?
    /// Aired, not watched, after the last episode the user reached, and
    /// aired since the user last watched the show or in the last 14 days
    /// (for a watchlisted show never started: aired in the last 14 days).
    /// Oldest first.
    public let new: [GuideEpisode]
    /// Airing within the next 7 days. Soonest first.
    public let upcoming: [GuideEpisode]
    /// The episodes of `new` the user has not been shown yet (after the
    /// "acknowledged through" mark): what a badge counts.
    public let unacknowledged: [GuideEpisode]

    public init(showID: String, showTitle: String?, new: [GuideEpisode], upcoming: [GuideEpisode], unacknowledged: [GuideEpisode]) {
        self.showID = showID
        self.showTitle = showTitle
        self.new = new
        self.upcoming = upcoming
        self.unacknowledged = unacknowledged
    }

    /// A badge is due.
    public var hasBadge: Bool { return !unacknowledged.isEmpty }
    /// The most recent new episode.
    public var latest: GuideEpisode? { return new.last }
    /// When the most recent new episode aired.
    public var latestAiredAt: Date? { return new.last?.aired }
    /// The next episode to air, and when.
    public var next: GuideEpisode? { return upcoming.first }
    public var isEmpty: Bool { return new.isEmpty && upcoming.isEmpty }

    /// Artwork by IMDb id (metahub): nothing to fetch first.
    public var posterURL: URL? { return OpenMetadata.posterURL(imdbId: showID) }
    public var backdropURL: URL? { return OpenMetadata.backgroundURL(imdbId: showID) }
    public var logoURL: URL? { return OpenMetadata.logoURL(imdbId: showID) }
    /// The still of one of its episodes.
    public func stillURL(of episode: GuideEpisode) -> URL? {
        return LibraryArtwork.episodeStillURL(showID: showID, episode.number)
    }
}

/// Artwork addresses derived from an IMDb id.
public enum LibraryArtwork {

    public enum BackdropSize: String {
        /// About 19 KB: a thumbnail.
        case small
        /// 1280 px wide JPEG: a card.
        case medium
        /// 1920 px wide: a page (`OpenMetadata.backgroundURL`).
        case large
    }

    /// metahub's landscape backdrop of a movie or a show.
    public static func backdropURL(imdbID: String, size: BackdropSize) -> URL? {
        guard LibraryID.isIMDb(imdbID) else { return nil }
        return URL(string: "https://images.metahub.space/background/\(size.rawValue)/\(imdbID)/img")
    }

    /// metahub's episode still (780 px wide JPEG; a 404 for an episode it
    /// does not know: fall back to the show's backdrop).
    public static func episodeStillURL(showID: String, _ number: EpisodeNumber) -> URL? {
        guard LibraryID.isIMDb(showID) else { return nil }
        return URL(string: "https://episodes.metahub.space/\(showID)/\(number.season)/\(number.episode)/w780.jpg")
    }
}

/// New and upcoming episodes of one show. Pure: the airings, the watch state
/// and the clock are arguments.
public enum NewEpisodesRule {

    /// - Parameters:
    ///   - airings: the show's recent and coming episodes (`ShowGuide.recentAirings`).
    ///   - reached: the furthest regular episode the user watched or started;
    ///     nil when the show was never started (it is followed because it is
    ///     in the watchlist).
    ///   - lastActivity: when the user last played or marked an episode of
    ///     the show; nil when unknown.
    ///   - watched: the episodes marked watched.
    ///   - acknowledgedThrough: the last episode the user was shown as new.
    ///
    /// New = aired by `now`, not watched, and
    /// - show started: after `reached`, and aired since `lastActivity` or
    ///   within `policy.newEpisodeWindow`. The date matters: Cinemeta's
    ///   calendar also returns the last ten episodes of a show that ended
    ///   years ago, and a user catching up on it is not being told news —
    ///   those episodes are its "next up", in Continue Watching;
    /// - show never started: aired within `policy.newEpisodeWindow`.
    public static func compute(showID: String, showTitle: String?, airings: [GuideEpisode],
                               reached: EpisodeNumber?, lastActivity: Date?, watched: Set<EpisodeNumber>,
                               acknowledgedThrough: EpisodeNumber?, now: Date,
                               policy: LibraryPolicy = .standard) -> ShowNewEpisodes {
        // Only dated, regular episodes: an undated one cannot be said to
        // have aired "since", and specials are not where a show continues.
        let dated: [(episode: GuideEpisode, aired: Date)] = airings.compactMap { episode in
            guard !episode.number.isSpecial, let aired = episode.aired else { return nil }
            return (episode, aired)
        }
        let new = dated.filter { item in
            guard item.aired <= now, !watched.contains(item.episode.number) else { return false }
            let isRecent = now.timeIntervalSince(item.aired) <= policy.newEpisodeWindow
            guard let reached = reached else { return isRecent }
            return item.episode.number > reached && (isRecent || (lastActivity.map { item.aired > $0 } ?? false))
        }.map { $0.episode }.sorted { $0.number < $1.number }

        let upcoming = dated.filter { $0.aired > now && $0.aired.timeIntervalSince(now) <= policy.upcomingWindow }
            .sorted { ($0.aired, $0.episode.number) < ($1.aired, $1.episode.number) }.map { $0.episode }

        let unacknowledged = new.filter { episode in acknowledgedThrough.map { episode.number > $0 } ?? true }
        return ShowNewEpisodes(showID: showID, showTitle: showTitle, new: new, upcoming: upcoming, unacknowledged: unacknowledged)
    }
}

/// "Seen through SxEy" per show, so a new-episode badge goes out once the
/// user has looked. Durable (it lives with the watch state, not in a cache).
final class NewEpisodesAcknowledgements {

    static let storageKey = "newEpisodesAcknowledged"

    private let storage: LibraryStorage
    private let lock = NSLock()
    private var marks: [String: EpisodeNumber]?

    init(storage: LibraryStorage) {
        self.storage = storage
    }

    func mark(_ showID: String) -> EpisodeNumber? {
        lock.lock(); defer { lock.unlock() }
        return loaded()[showID]
    }

    /// Moves the mark forward to `number` (never back). Returns whether it moved.
    @discardableResult
    func acknowledge(_ showID: String, through number: EpisodeNumber) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var current = loaded()
        if let known = current[showID], known >= number { return false }
        current[showID] = number
        marks = current
        // A property list: [show id: [season, episode]].
        storage.set(current.mapValues { [$0.season, $0.episode] }, forKey: NewEpisodesAcknowledgements.storageKey)
        return true
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        marks = nil
    }

    private func loaded() -> [String: EpisodeNumber] {
        if let marks = marks { return marks }
        var loaded: [String: EpisodeNumber] = [:]
        for (showID, value) in storage.object(forKey: NewEpisodesAcknowledgements.storageKey) as? [String: Any] ?? [:] {
            guard let pair = value as? [Any], pair.count == 2,
                  let season = (pair[0] as? NSNumber)?.intValue, let episode = (pair[1] as? NSNumber)?.intValue else { continue }
            loaded[showID] = EpisodeNumber(season: season, episode: episode)
        }
        marks = loaded
        return loaded
    }
}
