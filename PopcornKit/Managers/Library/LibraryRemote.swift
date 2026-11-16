import Foundation

/// What the library asks the network for, as closures: the apps use `live`,
/// the tests answer from recorded files. Completions may run on any queue.
///
/// Keyless hosts only:
/// - Cinemeta `catalog/series/calendar-videos/calendarVideosIds=<ids>.json`:
///   up to 100 shows per request (0.34 s for 100, measured), each with about
///   ten episodes around today, upcoming ones included;
/// - Cinemeta `meta/<movie|series>/<id>.json`: a title by IMDb id, with every
///   episode for a series;
/// - TVMaze `lookup/shows?imdb=` then `shows/<id>/episodes`: one show's full
///   guide (two requests per show, about 20 calls per 10 s allowed).
public struct LibraryRemote {

    /// A title known by its id only, filled in.
    public struct Title {
        public let imdbID: String
        public let title: String
        /// Minutes.
        public let runtime: Int?
        /// A series' episodes.
        public let guide: ShowGuide?

        public init(imdbID: String, title: String, runtime: Int? = nil, guide: ShowGuide? = nil) {
            self.imdbID = imdbID
            self.title = title
            self.runtime = runtime
            self.guide = guide
        }
    }

    /// What a host said about one title asked by its id. "It does not know
    /// the title" and "it did not answer" are two answers: the first is not
    /// asked again for a while, the second is.
    public enum Answer<Value> {
        case found(Value)
        /// The host answered, and has nothing under that id.
        case unknown
        /// No answer: offline, a timeout, an error of the host's own.
        case unreachable
    }

    /// The airings of up to `calendarBatch` shows in one request; nil when
    /// Cinemeta could not be reached (a show it does not know is just absent).
    public var calendar: (_ showIDs: [String], _ completion: @escaping ([ShowGuide]?) -> Void) -> Void
    /// One show's guide from TVMaze.
    public var tvmazeGuide: (_ showID: String, _ completion: @escaping (Answer<ShowGuide>) -> Void) -> Void
    /// A movie's or a series' title (and episodes).
    public var title: (_ imdbID: String, _ kind: ContinueWatchingEntry.Kind, _ completion: @escaping (Answer<Title>) -> Void) -> Void

    public init(calendar: @escaping ([String], @escaping ([ShowGuide]?) -> Void) -> Void,
                tvmazeGuide: @escaping (String, @escaping (Answer<ShowGuide>) -> Void) -> Void,
                title: @escaping (String, ContinueWatchingEntry.Kind, @escaping (Answer<Title>) -> Void) -> Void) {
        self.calendar = calendar
        self.tvmazeGuide = tvmazeGuide
        self.title = title
    }

    /// Cinemeta takes at most this many ids per calendar request.
    public static let calendarBatch = 100

    /// Answers nothing (tests of the offline paths).
    public static let offline = LibraryRemote(calendar: { _, done in done(nil) },
                                              tvmazeGuide: { _, done in done(.unreachable) },
                                              title: { _, _, done in done(.unreachable) })

    // MARK: - Live

    private static let fetcher = IndexFetcher(name: "Library", timeout: 10, cacheLifetime: 0, backoff: 60)
    private static let tvmazeHosts = ["https://api.tvmaze.com"]

    public static let live = LibraryRemote(
        calendar: { showIDs, completion in
            let ids = showIDs.filter(LibraryID.isIMDb).prefix(calendarBatch)
            guard !ids.isEmpty else { return completion([]) }
            let path = "/catalog/series/calendar-videos/calendarVideosIds=\(ids.joined(separator: ",")).json"
            fetcher.fetch(hosts: CinemetaClient.hosts, path: path) { outcome in
                switch outcome {
                case .data(let data): completion(LibraryRemote.guides(fromCinemetaCalendar: data))
                case .status(let status) where status == 404: completion([])
                case .status, .failed: completion(nil)
                }
            }
        },
        tvmazeGuide: { showID, completion in
            guard LibraryID.isIMDb(showID) else { return completion(.unknown) }
            // TVMaze answers 404 for an IMDb id it does not have.
            fetcher.fetch(hosts: tvmazeHosts, path: "/lookup/shows?imdb=\(showID)") { outcome in
                let lookup = LibraryRemote.answer(outcome) { data -> (show: [String: Any], id: Int)? in
                    guard let show = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let id = show["id"] as? Int else { return nil }
                    return (show, id)
                }
                switch lookup {
                case .unknown: completion(.unknown)
                case .unreachable: completion(.unreachable)
                case .found(let found):
                    fetcher.fetch(hosts: tvmazeHosts, path: "/shows/\(found.id)/episodes") { outcome in
                        completion(LibraryRemote.answer(outcome) { LibraryRemote.guide(showID: showID, tvmazeShow: found.show, episodes: $0) })
                    }
                }
            }
        },
        title: { imdbID, kind, completion in
            guard LibraryID.isIMDb(imdbID) else { return completion(.unknown) }
            let catalog = kind == .movie ? "movie" : "series"
            // Cinemeta answers `{}` for an id it does not have under that type.
            fetcher.fetch(hosts: CinemetaClient.hosts, path: "/meta/\(catalog)/\(imdbID).json") { outcome in
                completion(LibraryRemote.answer(outcome) { LibraryRemote.title(fromCinemetaMeta: $0, imdbID: imdbID) })
            }
        })

    /// A host's answer to a request by id, its body read by `parse`. A 404,
    /// or a body `parse` finds nothing in: the host does not know the id.
    /// Any other status (a 5xx, a 429) or no answer at all: to ask again.
    static func answer<Value>(_ outcome: IndexFetcher.Outcome, _ parse: (Data) -> Value?) -> Answer<Value> {
        switch outcome {
        case .data(let data): return parse(data).map { .found($0) } ?? .unknown
        case .status(let status) where status == 404: return .unknown
        case .status, .failed: return .unreachable
        }
    }

    // MARK: - Parsing (pure)

    /// `{"metasDetailed":[{"id":"tt…","name":…,"status":…,"videos":[…]}]}`;
    /// nil when the answer is not that.
    static func guides(fromCinemetaCalendar data: Data) -> [ShowGuide]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let metas = (root["metasDetailed"] ?? root["metas"]) as? [[String: Any]] else { return nil }
        return metas.compactMap { guide(fromCinemetaMeta: $0, isComplete: false) }
    }

    /// `{"meta":{"id","name","runtime":"145 min","videos":[…]}}`; nil for `{}`
    /// (Cinemeta does not know the id under that type).
    static func title(fromCinemetaMeta data: Data, imdbID: String) -> Title? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = root["meta"] as? [String: Any],
              let name = (meta["name"] as? String)?.removingHtmlEncoding, !name.isEmpty else { return nil }
        let guide = (meta["videos"] as? [[String: Any]]).flatMap { _ in LibraryRemote.guide(fromCinemetaMeta: meta, isComplete: true) }
        return Title(imdbID: imdbID, title: name, runtime: minutes(meta["runtime"]),
                     guide: guide.flatMap { $0.showID == imdbID ? $0 : nil })
    }

    /// "145 min" (Cinemeta) or 45 (TVMaze) → minutes; nil when 0 or absent.
    private static func minutes(_ value: Any?) -> Int? {
        let number = (value as? NSNumber)?.intValue ?? Int(((value as? String) ?? "").prefix { $0.isNumber })
        return number.flatMap { $0 > 0 ? $0 : nil }
    }

    /// `isComplete`: a meta lists every episode, the calendar about ten.
    private static func guide(fromCinemetaMeta meta: [String: Any], isComplete: Bool) -> ShowGuide? {
        guard let id = (meta["imdb_id"] as? String) ?? (meta["id"] as? String), LibraryID.isIMDb(id) else { return nil }
        let episodes: [GuideEpisode] = ((meta["videos"] as? [[String: Any]]) ?? []).compactMap { video in
            guard let season = video["season"] as? Int,
                  let number = (video["episode"] as? Int) ?? (video["number"] as? Int), season >= 0, number > 0 else { return nil }
            let name = ((video["name"] as? String) ?? (video["title"] as? String))?.removingHtmlEncoding
            let released = ((video["released"] as? String) ?? (video["firstAired"] as? String)).flatMap(CatalogDates.date(from:))
            return GuideEpisode(season: season, episode: number, title: name.flatMap { $0.isEmpty ? nil : $0 }, aired: released)
        }
        return ShowGuide(showID: id, title: (meta["name"] as? String)?.removingHtmlEncoding, status: meta["status"] as? String,
                         runtime: minutes(meta["runtime"]), episodes: episodes, source: .cinemeta, isComplete: isComplete && !episodes.isEmpty)
    }

    /// TVMaze's show object and its `/episodes` answer
    /// (`[{"season","number","name","airstamp","airdate"}]`; a special has no
    /// number). nil when the episodes are not that.
    static func guide(showID: String, tvmazeShow show: [String: Any], episodes data: Data) -> ShowGuide? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let episodes: [GuideEpisode] = list.compactMap { item in
            guard let season = item["season"] as? Int, let number = item["number"] as? Int, number > 0 else { return nil }
            // The exact instant when TVMaze has it, else the day (UTC).
            let aired = (item["airstamp"] as? String).flatMap(CatalogDates.date(from:))
                ?? (item["airdate"] as? String).flatMap(CatalogDates.date(from:))
            let name = (item["name"] as? String)?.removingHtmlEncoding
            return GuideEpisode(season: season, episode: number, title: name.flatMap { $0.isEmpty ? nil : $0 }, aired: aired)
        }
        return ShowGuide(showID: showID, title: (show["name"] as? String)?.removingHtmlEncoding, status: show["status"] as? String,
                         runtime: minutes(show["averageRuntime"]) ?? minutes(show["runtime"]), episodes: episodes, source: .tvmaze)
    }
}
