import Foundation

/// The torrent lists of one movie as its sources answer — YTS, the Torrentio
/// aggregator, Time4Popcorn, then The Pirate Bay / Knaben — and the list a
/// page offers from the ones that are in.
///
/// `getMovieInfo` used to hand over one list, once the slowest source had
/// answered: the page waited behind a loading screen for all of them. The
/// same lists now reach the page one by one (`DetailEvent.movieSources`); the
/// merge is done again from scratch each time, because it is not additive
/// (`TorrentioClient.merge` gives each resolution a few slots: a release
/// listed from two sources may lose its slot to one of a third). With every
/// list in, `merged` is exactly the list `getMovieInfo` always built.
public struct MovieSources {

    public enum Provider: String, CaseIterable, Sendable {
        case yts = "YTS"
        case torrentio = "Torrentio"
        case time4Popcorn = "T4P"
        case extra = "TPB/Knaben"
    }

    public var yts: [Torrent] = []
    public var torrentio: [Torrent] = []
    public var time4Popcorn: [Torrent] = []
    /// The Pirate Bay / Knaben releases of the movie (`ExtraTorrentSources`),
    /// whether another source lists them or not.
    public var extra: [Torrent] = []
    /// The sources whose answer is not in.
    public var missing: [Provider] = Provider.allCases
    /// The sources that answered with a failure (no host reached): their
    /// list is empty, and nothing says the movie has no torrent there.
    public var failed: [Provider] = []
    /// YTS has the title: its curated torrents lead the merge and are all
    /// kept. Without it Time4Popcorn's do (as `getMovieInfo` always did: the
    /// movie it built on was Time4Popcorn's then).
    public var ytsKnowsTitle = false
    /// The movie's runtime in seconds, when a source gave it: with the sizes
    /// it gives the bitrates the merge weighs against the connection.
    public var runtime: TimeInterval?

    public init() {}

    public var isComplete: Bool { missing.isEmpty }

    /// Every list answered, and at least one with a failure: an empty
    /// result then says nothing about the movie.
    public var isInconclusive: Bool { isComplete && !failed.isEmpty }

    /// The page's list from the lists that are in, and how many of the
    /// The Pirate Bay / Knaben torrents no other source lists (the log).
    /// - Parameter runtime: the movie's runtime when the sources gave none
    ///   (a page knows it from the grid's item).
    public func merge(runtime fallback: TimeInterval? = nil) -> (torrents: [Torrent], novelExtra: Int) {
        let runtime = self.runtime ?? fallback
        let primary = (ytsKnowsTitle ? yts : time4Popcorn).withMediaRuntime(runtime)
        let legacy = (torrentio + time4Popcorn).withMediaRuntime(runtime)
        let novel = ExtraTorrentSources.novel(extra.withMediaRuntime(runtime), beside: primary + legacy)
        return (TorrentioClient.merge(primary, with: legacy + novel), novel.count)
    }

    /// The page's list from the lists that are in (`merge`).
    public func merged(runtime fallback: TimeInterval? = nil) -> [Torrent] {
        return merge(runtime: fallback).torrents
    }

    subscript(provider: Provider) -> [Torrent] {
        get {
            switch provider {
            case .yts: return yts
            case .torrentio: return torrentio
            case .time4Popcorn: return time4Popcorn
            case .extra: return extra
            }
        }
        set {
            switch provider {
            case .yts: yts = newValue
            case .torrentio: torrentio = newValue
            case .time4Popcorn: time4Popcorn = newValue
            case .extra: extra = newValue
            }
        }
    }

    /// "T4P 1 · Torrentio 449 · YTS 6 · TPB/Knaben 68", the sources that are in.
    public var summary: String {
        let answered = Provider.allCases.filter { !missing.contains($0) }
        guard !answered.isEmpty else { return "no source in" }
        return answered.map { "\($0.rawValue) \(self[$0].count)" + (failed.contains($0) ? " (failed)" : "") }
            .joined(separator: " · ")
    }
}

/// What the load of a title's page tells, in order, on the main queue
/// (`YTSEZTVProvider.loadMovieDetail` / `loadShowDetail`, `DetailStore`).
public enum DetailEvent {
    /// The title's record — a `Movie` or a `Show` — from the first source
    /// that has it, then from a better one (a movie: Cinemeta's, then
    /// Time4Popcorn's, then YTS's with the cast; a show: its record, then
    /// the same with its episode guide). Its torrents are not what the page
    /// offers: those come with `movieSources` / `showSources`.
    case metadata(Media)
    /// A movie's lists, each time one arrives; the last one is complete.
    case movieSources(MovieSources)
    /// A show with its torrents attached to its episodes (EZTV): the
    /// complete show, as `getShowInfo` builds it.
    case showSources(Show)
    /// Nothing more comes. An error, or no `metadata` before it: the title
    /// could not be loaded.
    case finished(NSError?)
}
