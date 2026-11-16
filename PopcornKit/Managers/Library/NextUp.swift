import Foundation

/// What is known about one episode the user touched.
public struct EpisodeRecord: Equatable {
    public let number: EpisodeNumber
    /// 0…1.
    public let progress: Float
    /// Seconds, when a player told it.
    public let position: TimeInterval?
    /// When it was last played or marked; `.distantPast` when unknown (a
    /// watched mark with no entry): then the furthest episode counts as the
    /// latest, which is what 5.2 did.
    public let updatedAt: Date

    public init(number: EpisodeNumber, progress: Float, position: TimeInterval? = nil, updatedAt: Date = .distantPast) {
        self.number = number
        self.progress = progress
        self.position = position
        self.updatedAt = updatedAt
    }
}

/// The episode a show continues with.
public struct NextUp: Equatable {

    public enum Reason: String {
        /// The episode last played, not finished.
        case resume
        /// The episode after the last one finished.
        case next
        /// Nothing was played yet (or everything was): the first episode.
        case start
    }

    public let number: EpisodeNumber
    public let reason: Reason
    /// The saved progress of that episode when it was started, else nil.
    public let progress: Float?

    public init(number: EpisodeNumber, reason: Reason, progress: Float? = nil) {
        self.number = number
        self.reason = reason
        self.progress = progress
    }
}

/// Where the user is in a show.
public struct ShowWatchPosition: Equatable {
    /// What Play starts. Never a special (season 0), never an episode that
    /// has not aired. nil: nothing to play (the next episode is not out).
    public let nextUp: NextUp?
    /// The episode the user is waiting for, when that is why `nextUp` is nil.
    public let upcoming: GuideEpisode?
    /// The episode the position was worked out from (the last one played).
    public let lastPlayed: EpisodeNumber?
}

/// The single "next episode" rule (it replaces `Show.latestUnwatchedEpisode`,
/// the iOS page's "first episode not watched" and GlassDetailAdapter's own
/// fallback, which disagreed). Pure.
public enum NextUpRule {

    /// See `position(guide:watched:records:now:policy:)`.
    public static func nextUp(guide: [GuideEpisode], watched: Set<EpisodeNumber>, records: [EpisodeRecord],
                              now: Date, policy: LibraryPolicy = .standard) -> NextUp? {
        return position(guide: guide, watched: watched, records: records, now: now, policy: policy).nextUp
    }

    /// - Parameters:
    ///   - guide: the show's episodes, in any order (specials included).
    ///   - watched: the episodes marked watched.
    ///   - records: the episodes with a saved progress or a watched date.
    ///
    /// 1. The episode played last (the latest `updatedAt`; the furthest one
    ///    between equal dates) is where the user is. An episode only opened
    ///    (below the policy's "started" threshold) does not count: opening
    ///    S5E1 by mistake no longer moves a show to season 5.
    /// 2. Not finished: resume it.
    /// 3. Finished: the first episode after it that is not watched — when it
    ///    has aired. When every later episode is watched already (a re-watch),
    ///    the one right after it.
    /// 4. Nothing played, or the last episode of the show finished: the first
    ///    episode, when it has aired.
    ///
    /// Season 0 is never the answer and never where the user is, unless the
    /// guide has nothing else. An episode that has not aired is never the
    /// answer: `upcoming` names it instead.
    public static func position(guide: [GuideEpisode], watched: Set<EpisodeNumber>, records: [EpisodeRecord],
                                now: Date, policy: LibraryPolicy = .standard) -> ShowWatchPosition {
        // One episode per number; a record's episode missing from the guide
        // (guide not loaded, or behind) still exists.
        var byNumber: [EpisodeNumber: GuideEpisode] = [:]
        for episode in guide where byNumber[episode.number] == nil { byNumber[episode.number] = episode }
        for record in records where byNumber[record.number] == nil {
            byNumber[record.number] = GuideEpisode(season: record.number.season, episode: record.number.episode)
        }
        var episodes = byNumber.values.sorted { $0.number < $1.number }
        if episodes.contains(where: { !$0.number.isSpecial }) {
            episodes.removeAll { $0.number.isSpecial }
        }
        guard let first = episodes.first else {
            return ShowWatchPosition(nextUp: nil, upcoming: nil, lastPlayed: nil)
        }
        let known = Set(episodes.map { $0.number })

        var recordByNumber: [EpisodeNumber: EpisodeRecord] = [:]
        for record in records {
            if let other = recordByNumber[record.number], other.updatedAt >= record.updatedAt { continue }
            recordByNumber[record.number] = record
        }
        func isFinished(_ number: EpisodeNumber) -> Bool {
            return watched.contains(number) || policy.isFinished(progress: recordByNumber[number]?.progress ?? 0)
        }
        func startedProgress(_ number: EpisodeNumber) -> Float? {
            guard let record = recordByNumber[number], !isFinished(number),
                  policy.isStarted(progress: record.progress, position: record.position) else { return nil }
            return record.progress
        }

        // Where the user is: the latest episode finished or really started.
        var touched = recordByNumber.values.filter { known.contains($0.number) && (isFinished($0.number) || startedProgress($0.number) != nil) }
        // Watched marks without a record are as old as can be.
        for number in watched where known.contains(number) && recordByNumber[number] == nil {
            touched.append(EpisodeRecord(number: number, progress: 1))
        }
        let anchor = touched.max { a, b in a.updatedAt == b.updatedAt ? a.number < b.number : a.updatedAt < b.updatedAt }

        func start() -> ShowWatchPosition {
            let playable = first.isAvailable(at: now)
            return ShowWatchPosition(nextUp: playable ? NextUp(number: first.number, reason: .start, progress: startedProgress(first.number)) : nil,
                                     upcoming: playable ? nil : first, lastPlayed: anchor?.number)
        }

        guard let anchor = anchor else { return start() }

        if !isFinished(anchor.number) {
            return ShowWatchPosition(nextUp: NextUp(number: anchor.number, reason: .resume, progress: anchor.progress),
                                     upcoming: nil, lastPlayed: anchor.number)
        }

        let later = episodes.filter { $0.number > anchor.number }
        if let next = later.first(where: { !isFinished($0.number) }) {
            guard next.isAvailable(at: now) else {
                return ShowWatchPosition(nextUp: nil, upcoming: next, lastPlayed: anchor.number)
            }
            return ShowWatchPosition(nextUp: NextUp(number: next.number, reason: .next, progress: startedProgress(next.number)),
                                     upcoming: nil, lastPlayed: anchor.number)
        }
        // Every later episode is watched: a re-watch goes on with the next one.
        if let following = later.first, following.isAvailable(at: now) {
            return ShowWatchPosition(nextUp: NextUp(number: following.number, reason: .next), upcoming: nil, lastPlayed: anchor.number)
        }
        // The show's last episode is finished.
        return start()
    }
}
