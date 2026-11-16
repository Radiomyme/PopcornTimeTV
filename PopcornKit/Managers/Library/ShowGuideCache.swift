import Foundation

/// A show's episodes as the library last saw them.
public struct ShowGuide: Codable, Equatable {

    /// Where the episode list came from. The app's own guide (TVMaze, through
    /// the provider) numbers episodes the way their ids are built; Cinemeta
    /// follows IMDb, which differs for a few shows (split seasons, anime).
    public enum Source: String, Codable {
        /// A show page was opened: the provider's guide.
        case provider
        /// TVMaze, asked by the library.
        case tvmaze
        /// Cinemeta (a meta or the calendar).
        case cinemeta
    }

    public let showID: String
    public var title: String?
    /// "Continuing", "Ended"… as the source words it.
    public var status: String?
    /// An episode's usual length in minutes, when the source says it.
    public var runtime: Int?
    /// Sorted by season, then number; one per number.
    public var episodes: [GuideEpisode]
    public var source: Source
    /// Every episode of the show was listed at least once (a provider's or
    /// TVMaze's guide, a Cinemeta meta); false while only calendar windows
    /// (about ten episodes around today) are known.
    public var isComplete: Bool
    /// When the airings were last asked (even if nothing came back): what
    /// the 6 h lifetime is counted from. nil: never asked.
    public var checkedAt: Date?

    public init(showID: String, title: String? = nil, status: String? = nil, runtime: Int? = nil, episodes: [GuideEpisode] = [],
                source: Source, isComplete: Bool? = nil, checkedAt: Date? = nil) {
        self.showID = showID
        self.title = title
        self.status = status
        self.runtime = runtime.flatMap { $0 > 0 ? $0 : nil }
        self.episodes = ShowGuide.normalized(episodes)
        self.source = source
        self.isComplete = isComplete ?? (source != .cinemeta && !episodes.isEmpty)
        self.checkedAt = checkedAt
    }

    static func normalized(_ episodes: [GuideEpisode]) -> [GuideEpisode] {
        var seen = Set<EpisodeNumber>()
        return episodes.sorted { $0.number < $1.number }.filter { seen.insert($0.number).inserted }
    }

    public func episode(_ number: EpisodeNumber) -> GuideEpisode? {
        return episodes.first { $0.number == number }
    }

    /// Whether this guide can say which episode comes after `number`: a
    /// complete guide always; a calendar window (about ten episodes around
    /// today, none when the calendar had nothing for the show) only when it
    /// holds `number` itself — what follows it there follows it in the show.
    public func knowsWhatFollows(_ number: EpisodeNumber) -> Bool {
        return isComplete || episode(number) != nil
    }

    /// This guide brought up to date with `fresh` (asked at `date`):
    ///
    /// - a full guide (the provider's, TVMaze's) replaces the episodes — but
    ///   for those known after its last one (an episode Cinemeta's calendar
    ///   added that the guide does not list yet);
    /// - a Cinemeta answer (the calendar is a window of about ten episodes)
    ///   over nothing or over Cinemeta's own: its episodes replace their
    ///   numbers and add the new ones;
    /// - a Cinemeta answer over the provider's or TVMaze's guide: it only
    ///   fills missing air dates and adds episodes after the guide's last one
    ///   (a new episode aired since the page was opened). Never an episode in
    ///   the middle: where the two number a show differently, IMDb's numbers
    ///   would show up as episodes that do not exist in the app.
    public func merging(_ fresh: ShowGuide, checkedAt date: Date?) -> ShowGuide {
        var merged = self
        if let title = fresh.title, !title.isEmpty, merged.title == nil || fresh.source != .cinemeta { merged.title = title }
        if let status = fresh.status { merged.status = status }
        if let runtime = fresh.runtime { merged.runtime = runtime }
        if let date = date { merged.checkedAt = date }
        guard !fresh.episodes.isEmpty else { return merged }
        merged.isComplete = isComplete || fresh.isComplete

        if fresh.source != .cinemeta {
            let end = fresh.episodes.last?.number
            merged.episodes = fresh.episodes + episodes.filter { known in end.map { known.number > $0 } ?? false }
            merged.source = fresh.source
            return merged
        }
        let foreign = source != .cinemeta && !episodes.isEmpty
        var byNumber = Dictionary(episodes.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        let last = episodes.last?.number
        for episode in fresh.episodes {
            if var known = byNumber[episode.number] {
                if foreign {
                    if known.aired == nil { known.aired = episode.aired }
                } else {
                    known.title = episode.title ?? known.title
                    known.aired = episode.aired ?? known.aired
                }
                byNumber[episode.number] = known
            } else if !foreign || (last.map { episode.number > $0 } ?? true) {
                byNumber[episode.number] = episode
            }
        }
        merged.episodes = ShowGuide.normalized(Array(byNumber.values))
        if !foreign { merged.source = .cinemeta }
        return merged
    }

    /// The episodes new-episode detection looks at: the latest
    /// `policy.recentAiringsCount` regular ones aired by `now`, and every
    /// dated one still to come. (Cinemeta's calendar returns about that; a
    /// full guide is cut to the same so a show counts the same either way.)
    public func recentAirings(now: Date, policy: LibraryPolicy = .standard) -> [GuideEpisode] {
        let dated = episodes.filter { !$0.number.isSpecial && $0.aired != nil }
        let aired = dated.filter { ($0.aired ?? now) <= now }.sorted { ($0.aired ?? now, $0.number) < ($1.aired ?? now, $1.number) }
        let coming = dated.filter { ($0.aired ?? now) > now }
        return ShowGuide.normalized(Array(aired.suffix(policy.recentAiringsCount)) + coming)
    }
}

/// Episode guides of the shows the user follows, one JSON file per show in a
/// cache folder (everything in it can be asked again by IMDb id), with a copy
/// in memory. `directory` nil keeps them in memory only (tests).
///
/// Three writers: a show page that opened (the provider's full guide, free),
/// the new-episode refresh (Cinemeta's calendar or TVMaze), and the lazy
/// hydration of shows known by id only (Cinemeta's meta).
final class ShowGuideCache {

    private let directory: URL?
    private let lock = NSLock()
    private var guides: [String: ShowGuide] = [:]
    /// Shows whose file was looked for and not found.
    private var missing = Set<String>()
    private let writer = DispatchQueue(label: "PopcornKit.Library.guides", qos: .utility)

    init(directory: URL?) {
        self.directory = directory
    }

    func guide(_ showID: String) -> ShowGuide? {
        lock.lock(); defer { lock.unlock() }
        if let hit = guides[showID] { return hit }
        guard !missing.contains(showID), let file = file(showID),
              let data = try? Data(contentsOf: file),
              let guide = try? JSONDecoder().decode(ShowGuide.self, from: data), guide.showID == showID else {
            missing.insert(showID)
            return nil
        }
        guides[showID] = guide
        return guide
    }

    /// Stores `guide` as is.
    func store(_ guide: ShowGuide) {
        lock.lock()
        let changed = guides[guide.showID] != guide
        guides[guide.showID] = guide
        missing.remove(guide.showID)
        lock.unlock()
        guard changed, let file = file(guide.showID) else { return }
        writer.async { [directory] in
            guard let directory = directory, let data = try? JSONEncoder().encode(guide) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Merges `fresh` into what is known of the show (`ShowGuide.merging`).
    @discardableResult
    func merge(_ fresh: ShowGuide, checkedAt date: Date?) -> ShowGuide {
        let merged: ShowGuide
        if let known = guide(fresh.showID) {
            merged = known.merging(fresh, checkedAt: date)
        } else {
            var first = fresh
            first.checkedAt = date ?? fresh.checkedAt
            merged = first
        }
        store(merged)
        return merged
    }

    /// Waits for the pending file writes (tests).
    func flush() {
        writer.sync {}
    }

    private func file(_ showID: String) -> URL? {
        guard LibraryID.isIMDb(showID) else { return nil }
        return directory?.appendingPathComponent("\(showID).json")
    }
}
