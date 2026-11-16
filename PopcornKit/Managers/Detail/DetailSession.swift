import Foundation

/// One title's page, from the moment it opens: the page shows at once what
/// its caller had (a grid's item, a Home card, a link's id), the title's
/// record fills in when it arrives, and the sources come last, one by one.
///
/// Until 5.3 the three apps showed nothing before the slowest torrent
/// source had answered (a loading screen on Apple TV, a spinner on the Mac):
/// 2 to 3 seconds for a page whose title, artwork and summary the grid
/// already had.
///
/// The session reads the title's load in `DetailStore` (shared with the
/// prewarm and with any other page of the title) and tells its page what
/// changed (`onChange`):
///
/// - `movie` / `show`: what the page was opened with, completed by the
///   record (`Movie.completed(by:)`: nothing already on screen changes),
///   with the torrents known so far;
/// - `sources`: where the search stands, for the Play control;
/// - `failure`: nothing can be played and a source failed — the page stays,
///   with a Retry (`retry`);
/// - `press`: Play pressed before the sources are in. The press is kept
///   and runs once they are, by the rules of an episode's sources
///   (`EpisodeSourceResolver`): every source still expected is waited for
///   until `deadline` seconds after they were asked; past it, a list a
///   source may still complete is enough for a chooser, not for a release
///   played without asking, which waits for all of them, `patience` seconds
///   after the page opened at most — a movie with nothing to play yet
///   waits for the end of its search. `cancelPress` drops it.
///
/// Each step is logged with its time since the page opened:
///
///     [Detail] tt15239678 open — movie, Dune: Part Two
///     [Detail] tt15239678 first paint: 38 ms
///     [Detail] tt15239678 metadata: 212 ms
///     [Detail] tt15239678 first source: 371 ms — YTS 6
///     [Detail] tt15239678 all sources: 1184 ms — 15 torrent(s) (YTS 6 · Torrentio 449 · T4P 1 · TPB/Knaben 68)
///     [Detail] tt15239678 Dune: Part Two: first paint 38 ms · metadata 212 ms · first source 371 ms · all sources 1184 ms
///
/// Main queue only. The clock and the timers are injected (the tests).
public final class DetailSession {

    /// Where the search for the title's sources stands.
    public enum SourcesState: Equatable, Sendable {
        /// Asked; nothing to play is known yet.
        case searching
        /// Something can be played; a source may still add to it.
        case partial
        /// Every source has answered (or was given up): this is the list.
        case ready
        /// Every source has answered: nothing to play.
        case none

        /// Play has something to start.
        public var isPlayable: Bool { self == .partial || self == .ready }
        /// A source is still expected.
        public var isSearching: Bool { self == .searching || self == .partial }
    }

    public struct Change: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// `movie` / `show` changed otherwise than by their torrents.
        public static let metadata = Change(rawValue: 1 << 0)
        /// The torrents, `sources`.
        public static let sources = Change(rawValue: 1 << 1)
        /// `failure`, `isPressPending`, `isFinished`.
        public static let state = Change(rawValue: 1 << 2)
    }

    /// How long a press waits for every source, from the moment they were
    /// asked — the deadline of an episode's sources.
    public static var deadline: TimeInterval { EpisodeSourceResolver.deadline }
    /// How long a press waits at most.
    public static var patience: TimeInterval { EpisodeSourceResolver.patience }

    public let kind: TitleDetail.Kind
    public let id: String
    /// The movie's page content so far (nil for a show).
    public private(set) var movie: Movie?
    /// The show's page content so far (nil for a movie).
    public private(set) var show: Show?
    public private(set) var sources: SourcesState = .searching
    /// A source's record has arrived (the page shows more than its caller had).
    public private(set) var hasRecord = false
    /// A show's episode guide is in.
    public private(set) var hasGuide = false
    /// Nothing more comes.
    public private(set) var isFinished = false
    /// Why nothing can be played, when a failure is the reason: the title
    /// could not be loaded, or none of its sources could be reached.
    public private(set) var failure: NSError?
    /// A press waits for the sources.
    public private(set) var isPressPending = false
    /// The page was served by a load asked before it opened (a prewarm, or
    /// an earlier opening).
    public private(set) var joinedEarlierLoad = false

    /// Called after each change, on the main queue.
    public var onChange: ((Change) -> Void)?

    /// Works a movie's list out of its sources' lists: `work` anywhere,
    /// then `done` with its result on the main queue.
    public typealias Merge = (_ work: @escaping () -> [Torrent], _ done: @escaping ([Torrent]) -> Void) -> Void

    /// Off the main queue: merging a popular movie's lists (hundreds of
    /// releases to rank, at each answer) takes tens of milliseconds, which
    /// used to pass behind a loading screen and would now make the page
    /// stutter as it slides in.
    public static let mergingInBackground: Merge = { work, done in
        mergeQueue.async {
            let torrents = work()
            DispatchQueue.main.async { done(torrents) }
        }
    }
    private static let mergeQueue = DispatchQueue(label: "popcornkit.detail.merge", qos: .userInitiated)

    /// The latest lists handed to `merge`: an older one still waiting in
    /// the queue is not worked out.
    private final class MergeTicket {
        private let lock = NSLock()
        private var latest = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            latest += 1
            return latest
        }

        func isLatest(_ number: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return number == latest
        }
    }

    private let baseMovie: Movie?
    private let baseShow: Show?
    private let store: DetailStore
    private let now: () -> TimeInterval
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let merge: Merge
    private let log: (String) -> Void
    private let mergeTicket = MergeTicket()
    /// A list is being merged: what follows it (the end of the load) waits.
    private var isMerging = false
    /// The end of the load, told while a list was being merged.
    private var heldFinish: (error: NSError?, isHeld: Bool) = (nil, false)

    private var detail: TitleDetail?
    private var token: Int?
    private var lists: MovieSources?
    private var openedAt: TimeInterval
    private var marks: [(name: String, milliseconds: Int)] = []
    private var pending: (picksAlone: Bool, generation: Int, action: () -> Void)?
    private var pressGeneration = 0

    /// - Parameters:
    ///   - media: a `Movie` or a `Show`, as much of it as the caller has.
    ///   - store: where the title's load is shared.
    ///   - now: a monotonic clock, in seconds — the store's.
    ///   - after: runs a block after a delay, on the main queue.
    ///   - merge: works a movie's list out (default: off the main queue).
    ///   - log: where the `[Detail]` lines go.
    public init?(media: Media, store: DetailStore = .shared,
                 now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                 after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
                     DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
                 },
                 merge: @escaping Merge = DetailSession.mergingInBackground,
                 log: @escaping (String) -> Void = { print($0) }) {
        if let movie = media as? Movie {
            kind = .movie
            baseMovie = movie
            baseShow = nil
        } else if let show = media as? Show {
            kind = .show
            baseMovie = nil
            baseShow = show
        } else {
            return nil
        }
        id = media.id
        movie = baseMovie
        show = baseShow
        self.store = store
        self.now = now
        self.after = after
        self.merge = merge
        self.log = log
        openedAt = now()
        // A list's movie carries YTS's own torrents: something to play, and
        // its qualities, from the first frame.
        if let torrents = baseMovie?.torrents, !torrents.isEmpty { sources = .partial }
    }

    deinit {
        if let token = token { detail?.stopObserving(token) }
    }

    /// The movie or the show.
    public var media: Media {
        if let movie = movie { return movie }
        if let show = show { return show }
        return base
    }

    /// What the page was opened with.
    private var base: Media {
        if let movie = baseMovie { return movie }
        return baseShow ?? Show()
    }

    /// The sources' answers so far (a movie's).
    public var movieSources: MovieSources? { lists }

    // MARK: Loading

    /// Starts reading the title's load (once). What is already known is
    /// told before this returns.
    public func start() {
        guard detail == nil else { return }
        openedAt = now()
        marks = []
        log("[Detail] \(id) open — \(kind.rawValue)\(title.isEmpty ? "" : ", \(title)")")
        attach()
    }

    /// The same title asked again, from scratch: after `failure`.
    public func retry() {
        guard detail != nil else { return start() }
        if let token = token { detail?.stopObserving(token) }
        token = nil
        detail = nil
        store.forget(base)
        cancelPress()
        _ = mergeTicket.next()
        isMerging = false
        heldFinish = (nil, false)
        lists = nil
        failure = nil
        isFinished = false
        hasRecord = false
        hasGuide = false
        movie = baseMovie
        show = baseShow
        sources = (baseMovie?.torrents.isEmpty ?? true) ? .searching : .partial
        openedAt = now()
        marks = []
        log("[Detail] \(id) retry")
        onChange?([.metadata, .sources, .state])
        attach()
    }

    private func attach() {
        guard let detail = store.detail(for: base) else {
            fail(nil)
            return
        }
        self.detail = detail
        joinedEarlierLoad = detail.startedAt < openedAt - 0.05
        if joinedEarlierLoad {
            let age = openedAt - detail.startedAt
            log("[Detail] \(id) " + (detail.isFinished ? "kept from" : (detail.wasPrewarmed ? "prewarm asked" : "load asked"))
                + " \(String(format: "%.1f", age)) s ago")
        }
        token = detail.observe { [weak self] event in self?.receive(event) }
    }

    private func receive(_ event: DetailEvent) {
        switch event {
        case .metadata(let media):
            // A better record follows the first (a movie's: YTS's after
            // Cinemeta's): it completes what the first one left, and
            // replaces nothing the page already shows.
            if let record = media as? Movie, let base = baseMovie {
                var merged = (movie ?? base).completed(by: record)
                merged.torrents = movie?.torrents ?? []
                movie = merged
            } else if let record = media as? Show, let base = baseShow {
                // Not over the complete show (a replay tells the record first).
                guard sources != .ready else { break }
                show = (show ?? base).completed(by: record)
                if !record.episodes.isEmpty, !hasGuide {
                    hasGuide = true
                    mark("guide", detail: "\(record.episodes.count) episode(s)")
                }
            } else {
                break
            }
            if !hasRecord {
                hasRecord = true
                mark("metadata")
            }
            var change: Change = .metadata
            if kind == .show, hasGuide, sources == .searching {
                sources = .partial
                change.insert(.sources)
            }
            onChange?(change)
            offerPress()

        case .movieSources(let lists):
            guard let base = baseMovie else { break }
            // The page's list from the lists that are in, worked out off the
            // main queue; only the latest lists' is kept.
            let effective = effectiveLists(lists, base: base)
            let runtime = Torrent.mediaRuntime(of: movie ?? base)
            let ticket = mergeTicket
            let number = ticket.next()
            isMerging = true
            merge({ ticket.isLatest(number) ? effective.merged(runtime: runtime) : [] }) { [weak self] torrents in
                guard let self = self, ticket.isLatest(number) else { return }
                self.isMerging = false
                self.apply(lists, merged: torrents)
                if self.heldFinish.isHeld {
                    let error = self.heldFinish.error
                    self.heldFinish = (nil, false)
                    self.finish(error)
                }
            }

        case .showSources(let complete):
            guard let base = baseShow else { break }
            show = (show ?? base).completed(by: complete)
            let hadGuide = hasGuide
            hasGuide = !complete.episodes.isEmpty
            if !hasRecord {
                hasRecord = true
                mark("metadata")
            }
            if hasGuide, !hadGuide { mark("guide", detail: "\(complete.episodes.count) episode(s)") }
            sources = complete.episodes.isEmpty ? .none : .ready
            let withTorrents = complete.episodes.filter { !$0.torrents.isEmpty }.count
            mark("all sources", detail: "\(withTorrents) of \(complete.episodes.count) episode(s) with EZTV torrents")
            onChange?([.metadata, .sources])
            offerPress()

        case .finished(let error):
            // After the list being merged: what it holds decides whether
            // the load failed.
            if isMerging {
                heldFinish = (error, true)
            } else {
                finish(error)
            }
        }
    }

    /// A movie's lists, merged: the page's torrents and where the search stands.
    private func apply(_ lists: MovieSources, merged torrents: [Torrent]) {
        let hadSource = self.lists.map { $0.missing.count < MovieSources.Provider.allCases.count } ?? false
        self.lists = lists
        movie?.torrents = torrents
        if lists.isComplete {
            sources = torrents.isEmpty ? .none : .ready
        } else {
            sources = torrents.isEmpty ? .searching : .partial
        }
        if !hadSource, lists.missing.count < MovieSources.Provider.allCases.count {
            mark("first source", detail: lists.summary)
        }
        if lists.isComplete {
            mark("all sources", detail: "\(torrents.count) torrent(s) (\(lists.summary))")
        }
        onChange?(.sources)
        offerPress()
    }

    /// The movie's lists with the caller's own (a list's movie carries
    /// YTS's torrents) standing in for YTS's until it answers, and when it
    /// fails to.
    private func effectiveLists(_ lists: MovieSources, base: Movie) -> MovieSources {
        guard !base.torrents.isEmpty, lists.missing.contains(.yts) || lists.failed.contains(.yts) else { return lists }
        var lists = lists
        lists.yts = base.torrents
        lists.ytsKnowsTitle = true
        return lists
    }

    private func finish(_ error: NSError?) {
        guard !isFinished else { return }
        isFinished = true
        var change: Change = .state
        switch kind {
        case .movie:
            let torrents = movie?.torrents ?? []
            if sources.isSearching {
                // Finished without every list (a load that failed outright).
                sources = torrents.isEmpty ? .none : .ready
                change.insert(.sources)
            }
            if !hasRecord, !(baseMovie?.hasTitleToShow ?? false) || torrents.isEmpty {
                failure = error ?? DetailSession.unavailable
            } else if torrents.isEmpty, lists?.isInconclusive ?? true {
                failure = error ?? DetailSession.sourcesUnreachable
            }
        case .show:
            if sources != .ready {
                sources = .none
                change.insert(.sources)
                failure = error ?? (hasRecord ? DetailSession.noSeasons : DetailSession.unavailable)
            }
        }
        if failure != nil {
            log("[Detail] \(id) failed after \(milliseconds()) ms: \(failure?.localizedDescription ?? "?")")
            dropPress()
        } else {
            let steps = marks.map { "\($0.name) \($0.milliseconds) ms" }.joined(separator: " · ")
            log("[Detail] \(id)\(title.isEmpty ? "" : " " + title): \(steps)" + (joinedEarlierLoad ? " (asked before the page opened)" : ""))
        }
        onChange?(change)
        offerPress()
    }

    private func fail(_ error: NSError?) {
        isFinished = true
        sources = .none
        failure = error ?? DetailSession.unavailable
        dropPress()
        onChange?([.sources, .state])
    }

    private var title: String {
        if let movie = movie, movie.hasTitleToShow { return movie.title }
        if let show = show, show.hasTitleToShow { return show.title }
        return ""
    }

    // MARK: Errors

    private static func error(_ code: Int, _ message: String) -> NSError {
        return NSError(domain: "com.popcorntimetv.popcorntime.error", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.localized])
    }

    /// The title could not be loaded at all.
    static var unavailable: NSError { error(-1, "Please check your internet connection and try again.") }
    /// No source could be reached.
    static var sourcesUnreachable: NSError { error(-2, "Please check your internet connection and try again.") }
    /// The show has no episode (the message of 5.2).
    static var noSeasons: NSError {
        error(-243, "There are no seasons available for the selected show. Please try again later.")
    }

    // MARK: Timing

    private func milliseconds() -> Int {
        return Int(((now() - openedAt) * 1000).rounded())
    }

    private func mark(_ name: String, detail: String? = nil) {
        guard !marks.contains(where: { $0.name == name }) else { return }
        let elapsed = milliseconds()
        marks.append((name, elapsed))
        log("[Detail] \(id) \(name): \(elapsed) ms" + (detail.map { " — \($0)" } ?? ""))
    }

    /// The page drew its first frame (title, controls; the artwork fades in).
    public func noteFirstPaint() {
        mark("first paint")
    }

    /// The page's artwork is on screen.
    public func noteArtwork() {
        mark("artwork")
    }

    /// The steps so far, in milliseconds since the page opened (the tests).
    var timings: [String: Int] {
        return Dictionary(marks.map { ($0.name, $0.milliseconds) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: A press before the sources

    /// Whether what Play needs is in for a press made now.
    /// - Parameter picksAlone: a release will be played without asking
    ///   (an automatic quality).
    public func isReady(picksAlone: Bool) -> Bool {
        if failure != nil { return false }
        if isFinished || !sources.isSearching { return true }
        guard let detail = detail else { return false }
        let (asked, waited) = ages(of: detail)
        if waited >= DetailSession.patience {
            // A movie with nothing to play yet waits for the end of its
            // search: a chooser on an empty list would say « No torrents
            // found » while a source is still expected.
            return kind == .show || !(movie?.torrents.isEmpty ?? true)
        }
        guard asked >= DetailSession.deadline else { return false }
        switch kind {
        case .movie:
            // A chooser can open on what is in; a pick made without asking
            // waits for the sources that may still bring a better release.
            return !picksAlone && (movie?.torrents.count ?? 0) > 1
        case .show:
            // The episode's own sources are asked at the press: EZTV's,
            // late, are done without.
            return hasGuide
        }
    }

    /// How long ago the sources were asked (`deadline`), and how long the
    /// user has waited for them (`patience`): from the page's opening, not
    /// from a prewarm asked while the focus rested on a card.
    private func ages(of detail: TitleDetail) -> (asked: TimeInterval, waited: TimeInterval) {
        let time = now()
        return (time - detail.startedAt, time - max(detail.startedAt, openedAt))
    }

    /// Play (an episode, a download) was pressed: `action` runs now when
    /// the sources are in, else once they are — `isPressPending` meanwhile.
    /// One press is kept: another one replaces it. Nothing runs when the
    /// load fails (`failure`).
    /// - Returns: whether `action` ran at once.
    @discardableResult
    public func press(picksAlone: Bool, _ action: @escaping () -> Void) -> Bool {
        guard failure == nil else { return false }
        if isReady(picksAlone: picksAlone) {
            dropPress()
            action()
            return true
        }
        pressGeneration += 1
        let generation = pressGeneration
        pending = (picksAlone, generation, action)
        if !isPressPending {
            isPressPending = true
            onChange?(.state)
        }
        log("[Detail] \(id) Play pressed \(milliseconds()) ms after opening: waiting for the sources")
        // The deadline counts from when the sources were asked, the end of
        // the wait from when the page opened; a source's answer offers the
        // press before them.
        let (asked, waited) = detail.map(ages(of:)) ?? (0, 0)
        for remaining in [DetailSession.deadline - asked, DetailSession.patience - waited] where remaining > 0 {
            after(remaining) { [weak self] in
                guard let self = self, self.pending?.generation == generation else { return }
                self.offerPress()
            }
        }
        return false
    }

    /// The press kept by `press` is dropped: nothing will run.
    public func cancelPress() {
        guard pending != nil else { return }
        log("[Detail] \(id) the press waiting for the sources was cancelled")
        dropPress()
    }

    private func dropPress() {
        pending = nil
        guard isPressPending else { return }
        isPressPending = false
        onChange?(.state)
    }

    private func offerPress() {
        guard let press = pending, isReady(picksAlone: press.picksAlone) else { return }
        log("[Detail] \(id) the press runs \(milliseconds()) ms after opening")
        dropPress()
        press.action()
    }
}
