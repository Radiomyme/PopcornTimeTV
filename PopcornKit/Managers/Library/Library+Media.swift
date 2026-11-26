import Foundation

// The bridge between the library's plain values and the app's models
// (`Movie`, `Show`, `Episode`).

public extension GuideEpisode {
    /// An episode of the provider's guide. An unknown air date is
    /// `.distantPast` there.
    init(_ episode: Episode) {
        self.init(season: episode.season, episode: episode.episode,
                  title: episode.title.isEmpty ? nil : episode.title,
                  aired: episode.firstAirDate > Date(timeIntervalSince1970: 0) ? episode.firstAirDate : nil,
                  hasSource: !episode.torrents.isEmpty)
    }
}

public extension PlaybackDetails {
    /// What a movie or an episode says about itself, for its resume entry.
    /// The release it plays now goes with it (`PlaybackReleaseRegistry`, noted
    /// when its stream started): every player's save stores it.
    init(media: Media, position: TimeInterval? = nil, duration: TimeInterval? = nil) {
        self.init(position: position, duration: duration)
        release = PlaybackReleaseRegistry.current(for: media.id)
        if let movie = media as? Movie {
            title = movie.title
            runtime = movie.runtime > 0 ? movie.runtime : nil
        } else if let episode = media as? Episode {
            title = episode.show?.title
            episodeTitle = episode.title
            showID = episode.show.flatMap { LibraryID.isIMDb($0.id) ? $0.id : nil }
            number = episode.season >= 0 && episode.episode >= 0 ? EpisodeNumber(season: episode.season, episode: episode.episode) : nil
            runtime = episode.show?.runtime.flatMap { $0 > 0 ? $0 : nil }
        }
    }
}

/// Where the user is in a show, as episodes of that show.
public struct ShowPlayPosition {
    /// What Play starts, and why: the episode to resume, the next one, or
    /// the first (`.start`: nothing played yet, or everything was). Never a
    /// special, never an episode that cannot be played yet.
    public let nextUp: (episode: Episode, reason: NextUp.Reason)?
    /// The episode the user is waiting for, when that is why there is
    /// nothing to play.
    public let upcoming: Episode?

    /// The episode the user's history leads to — to resume, next, or still
    /// to air; nil for a show not begun (or finished). What a page opens on.
    public var current: Episode? {
        if let nextUp = nextUp { return nextUp.reason == .start ? nil : nextUp.episode }
        return upcoming
    }
}

public extension Show {

    /// The show's episodes as guide entries.
    var guideEpisodes: [GuideEpisode] {
        return episodes.map(GuideEpisode.init)
    }

    /// Where the user is in this show: `NextUpRule` over its episodes and the
    /// library's watch state. The one "next episode" of every platform.
    ///
    /// - Parameter episodes: a subset of the show's episodes; all by default.
    func watchPosition(in episodes: [Episode]? = nil, now: Date = Date(), library: Library = .shared) -> ShowPlayPosition {
        let episodes = episodes ?? self.episodes
        var watched = Set<EpisodeNumber>()
        var records: [EpisodeRecord] = []
        for episode in episodes {
            let number = EpisodeNumber(season: episode.season, episode: episode.episode)
            let isWatched = library.isWatched(episode.id, .episodes)
            let progress = library.progress(episode.id, .episodes)
            if isWatched { watched.insert(number) }
            guard isWatched || progress > 0 else { continue }
            let entry = library.entry(episode.id)
            records.append(EpisodeRecord(number: number, progress: progress, position: entry?.position,
                                         updatedAt: entry?.updatedAt ?? .distantPast))
        }
        let position = NextUpRule.position(guide: episodes.map(GuideEpisode.init), watched: watched, records: records,
                                           now: now, policy: library.policy)
        func episode(_ number: EpisodeNumber?) -> Episode? {
            guard let number = number else { return nil }
            return episodes.first { $0.season == number.season && $0.episode == number.episode }
        }
        let next = position.nextUp.flatMap { next in episode(next.number).map { (episode: $0, reason: next.reason) } }
        return ShowPlayPosition(nextUp: next, upcoming: episode(position.upcoming?.number))
    }
}

public extension Library {

    /// Remembers the show's guide (`noteGuide(showID:title:status:episodes:always:)`).
    func noteGuide(of show: Show, always: Bool = false) {
        noteGuide(showID: show.id, title: show.title, status: show.status, runtime: show.runtime, episodes: show.guideEpisodes, always: always)
    }
}

/// The players' one way to save how far a title was played: the fraction
/// (as before), plus what makes a Continue Watching card without the
/// network — titles, the position and duration in seconds, the show's guide.
public enum PlaybackRecorder {

    /// - Parameters:
    ///   - progress: 0…1; 0 deletes the saved position.
    ///   - position, duration: seconds, when the player knows them.
    public static func save(_ progress: Float, of media: Media, position: TimeInterval? = nil, duration: TimeInterval? = nil,
                            status: Trakt.WatchedStatus) {
        let details = PlaybackDetails(media: media, position: position, duration: duration)
        if let movie = media as? Movie {
            WatchedlistManager<Movie>.movie.setCurrentProgress(progress, for: movie.id, with: status, details: details)
        } else if let episode = media as? Episode {
            if let show = episode.show, !show.episodes.isEmpty { Library.shared.noteGuide(of: show, always: true) }
            WatchedlistManager<Episode>.episode.setCurrentProgress(progress, for: episode.id, with: status, details: details)
        }
        noteTaste(progress, of: media, release: details.release)
    }

    /// The profile's taste learns from the play: the title (once it really
    /// started), and the quality of the release the first time it counts.
    private static func noteTaste(_ progress: Float, of media: Media, release: RememberedRelease?) {
        let policy = Library.shared.policy
        guard progress.isFinite, progress > 0, policy.isStarted(progress: progress, position: nil) || policy.isFinished(progress: progress),
              let title = TasteTitle(media: media) else { return }
        let taste = ProfileTaste.shared
        let episodeID = (media as? Episode).flatMap { episode -> String? in
            guard let show = episode.show, episode.season >= 0, episode.episode >= 0 else { return nil }
            return LibraryID.episodeID(showID: show.id, EpisodeNumber(season: episode.season, episode: episode.episode))
        }
        if let quality = release?.quality.map(VideoQuality.parse), let label = quality.tasteLabel,
           taste.isFirstPlay(of: episodeID ?? title.imdbID) {
            taste.note(.quality(label))
        }
        taste.notePlayback(of: title, progress: progress, isFinished: policy.isFinished(progress: progress), episodeID: episodeID)
    }
}

/// "Is a position checkpoint due?" for a player's time tick: true once every
/// `interval` seconds of ticking (a crash, a kill or a power cut then loses
/// at most that much of a session, instead of all of it).
public struct PlaybackCheckpoint {
    public let interval: TimeInterval
    private var last: Date?

    public init(interval: TimeInterval = LibraryPolicy.standard.checkpointInterval) {
        self.interval = interval
    }

    /// The first call starts the clock.
    public mutating func isDue(now: Date = Date()) -> Bool {
        guard let last = last else {
            self.last = now
            return false
        }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed >= interval || elapsed < 0 else { return false }
        self.last = now
        return true
    }

    /// A save just happened for another reason (pause, background).
    public mutating func reset(now: Date = Date()) {
        last = now
    }
}

extension VideoQuality {
    /// "2160p", "1080p"…; nil for 3D and unknown.
    var tasteLabel: String? {
        switch self {
        case .sd480, .hd720, .hd1080, .uhd2160: return "\(rawValue)p"
        case .unknown, .threeD: return nil
        }
    }
}
