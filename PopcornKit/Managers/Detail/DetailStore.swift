import Foundation

/// The load of one title's page: what has arrived so far, for the page —
/// or the pages — showing the title and for the prewarm that asked ahead.
/// Made and fed by `DetailStore`. Main queue only.
public final class TitleDetail {

    public enum Kind: String, Sendable {
        case movie
        case show
    }

    public let kind: Kind
    /// IMDb id.
    public let id: String
    /// When the sources were asked (the store's clock, seconds).
    public let startedAt: TimeInterval

    /// The title's record, from the best source that has answered
    /// (`DetailEvent.metadata`).
    public private(set) var record: Media?
    /// A movie's lists, once one has arrived.
    public private(set) var movieSources: MovieSources?
    /// A show with its torrents: the complete show.
    public private(set) var completeShow: Show?
    public private(set) var isFinished = false
    public private(set) var error: NSError?

    public private(set) var metadataAt: TimeInterval?
    public private(set) var firstSourceAt: TimeInterval?
    public private(set) var finishedAt: TimeInterval?

    /// Asked ahead of a page (a card had the focus).
    public internal(set) var wasPrewarmed = false
    /// A page reads it (`observe`): no longer a prewarm to count or drop.
    public private(set) var isObserved = false
    /// A prewarm's: what it holds back until a page reads the load.
    var gate: DetailGate?

    private var observers: [(token: Int, handler: (DetailEvent) -> Void)] = []
    private var nextToken = 0

    init(kind: Kind, id: String, startedAt: TimeInterval) {
        self.kind = kind
        self.id = id
        self.startedAt = startedAt
    }

    /// A show's record carries its episode guide.
    public var hasGuide: Bool {
        return completeShow != nil || !((record as? Show)?.episodes.isEmpty ?? true)
    }

    /// The events so far, at once, then the ones to come. The token ends it
    /// (`stopObserving`).
    @discardableResult
    public func observe(_ handler: @escaping (DetailEvent) -> Void) -> Int {
        isObserved = true
        nextToken += 1
        observers.append((nextToken, handler))
        if let record = record { handler(.metadata(record)) }
        if let lists = movieSources { handler(.movieSources(lists)) }
        if let show = completeShow { handler(.showSources(show)) }
        if isFinished { handler(.finished(error)) }
        let token = nextToken
        // A page reads it: what a prewarm held back is asked now (its
        // answers reach this page like the others).
        gate?.open()
        return token
    }

    public func stopObserving(_ token: Int) {
        observers.removeAll { $0.token == token }
    }

    func receive(_ event: DetailEvent, at time: TimeInterval) {
        guard !isFinished else { return }
        switch event {
        case .metadata(let media):
            record = media
            if metadataAt == nil { metadataAt = time }
        case .movieSources(let lists):
            movieSources = lists
            if firstSourceAt == nil, lists.missing.count < MovieSources.Provider.allCases.count { firstSourceAt = time }
        case .showSources(let show):
            completeShow = show
            if firstSourceAt == nil { firstSourceAt = time }
        case .finished(let error):
            isFinished = true
            self.error = error
            finishedAt = time
        }
        for observer in observers { observer.handler(event) }
    }

    /// Worth serving again once finished: the title was found, and no
    /// source failed (a failure is asked again at the next opening).
    var isConclusive: Bool {
        guard isFinished, error == nil, record != nil else { return false }
        switch kind {
        case .movie: return movieSources.map { !$0.isInconclusive } ?? false
        case .show: return !(completeShow?.episodes.isEmpty ?? true)
        }
    }
}

/// What a load asked ahead holds back until a page reads it
/// (`TitleDetail.observe`): the slow requests, and the ones that name a
/// title to a third party — The Pirate Bay and Knaben's title searches,
/// EZTV's pages of a show. A card the focus only rested on asks YTS,
/// Torrentio, Time4Popcorn, Cinemeta and TVMaze by IMDb id, nothing more.
/// Main queue only.
public final class DetailGate {
    public private(set) var isOpen: Bool
    /// The load waits at the gate for its last, slowest step (what is left
    /// in flight is a quick answer by id): it no longer counts as a prewarm
    /// in flight.
    public private(set) var isParked = false
    private var held: [() -> Void] = []

    public init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    /// `block` now if the gate is open, else when it opens.
    public func whenOpen(_ block: @escaping () -> Void) {
        if isOpen { block() } else { held.append(block) }
    }

    /// The same, for the load's last step: what the gate holds is all that
    /// is left of it.
    public func parkUntilOpen(_ block: @escaping () -> Void) {
        if !isOpen { isParked = true }
        whenOpen(block)
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        isParked = false
        let blocks = held
        held = []
        blocks.forEach { $0() }
    }
}

/// The pages' short-lived cache, and the prewarm.
///
/// A title's page content — its record, then its sources — is asked once
/// and shared: the page that opens while a prewarm is in flight joins it,
/// one opened again within `lifetime` gets everything at once, and two
/// requests for the same title never run side by side. Nothing is kept on
/// disk (the sources change by the hour).
///
/// **Prewarm** — for the screens that show cards (grids, the Home): call
/// `prewarm(_:)` each time a card takes the focus (tvOS), is hovered (Mac)
/// or is touched (iOS), and `prewarm(nil)` when none has it any more
/// (`stopPrewarm(of:)` when a card only knows that it lost the pointer). The
/// title's page is asked `prewarmDwell` seconds later if that card still
/// has the focus: a focus that only passes over a card asks nothing. At
/// most `maxPrewarms` such loads run at a time (a third waits for a slot,
/// and is dropped if the focus has moved on by then), and none is started
/// for `prewarmBackoff` seconds after Torrentio failed to answer one (it
/// limits the rate). A request already sent cannot be recalled: its answer
/// still fills the cache. What a prewarm asks is bounded (`DetailGate`):
/// the requests by IMDb id only; the title searches of The Pirate Bay and
/// Knaben and the walk through EZTV's pages wait for a page to open, and a
/// prewarm parked there no longer counts as in flight.
///
/// Main queue only. The clock and the timers are injected (the tests).
public final class DetailStore {

    public static let shared = DetailStore()

    public struct Request {
        public let kind: TitleDetail.Kind
        public let id: String
        /// What the caller knows of a movie: the extra sources are searched
        /// by "Title Year", from the first second instead of once a source
        /// has named the movie.
        public var title: String?
        public var year: Int?
        /// A prewarm's: what the load holds back until a page reads it.
        public var gate: DetailGate?

        var key: String { "\(kind.rawValue):\(id)" }
    }

    /// Loads a title, telling what arrives (`DetailEvent`), on the main queue.
    public typealias Fetch = (_ request: Request, _ send: @escaping (DetailEvent) -> Void) -> Void

    /// How long a complete answer is served again.
    public static var lifetime: TimeInterval = 10 * 60
    /// Most titles kept.
    public static var capacity = 12
    /// How long a card keeps the focus before its page is asked.
    public static var prewarmDwell: TimeInterval = 0.4
    /// Most prewarms in flight.
    public static var maxPrewarms = 2
    /// No prewarm for this long after Torrentio failed to answer one.
    public static var prewarmBackoff: TimeInterval = 60
    /// A load still unfinished after this long is not joined: a page asks again.
    static let staleAfter: TimeInterval = 30

    /// Verification only (the apps' DEBUG launch arguments): the answers
    /// come late, or fail, so that every state of a page can be looked at.
    public struct Tampering {
        /// Seconds added before the record.
        public var metadataDelay: TimeInterval = 0
        /// Seconds added before each list of sources.
        public var sourcesDelay: TimeInterval = 0
        /// Seconds added before a movie's last list: something to play is
        /// known, a source is still expected.
        public var lastSourceDelay: TimeInterval = 0
        /// Every source fails: no torrent.
        public var sourcesFail = false
        /// Nothing can be loaded.
        public var fails = false

        public init() {}

        var isOn: Bool { metadataDelay > 0 || sourcesDelay > 0 || lastSourceDelay > 0 || sourcesFail || fails }
    }
    public var tampering = Tampering()

    private let fetch: Fetch
    private let now: () -> TimeInterval
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private var details: [String: TitleDetail] = [:]
    /// Keys, the most recently used last.
    private var order: [String] = []
    private var focused: Request?
    private var focusGeneration = 0
    private var prewarmPausedUntil: TimeInterval = -.infinity

    /// - Parameters:
    ///   - fetch: loads a title (default: the provider's progressive loads).
    ///   - now: a monotonic clock, in seconds.
    ///   - after: runs a block after a delay, on the main queue.
    public init(fetch: @escaping Fetch = DetailStore.provider,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
                }) {
        self.fetch = fetch
        self.now = now
        self.after = after
    }

    // MARK: Pages

    /// What to ask for `media`: nil when it is neither a movie nor a show
    /// with an IMDb id.
    public static func request(for media: Media) -> Request? {
        guard media.id.hasPrefix("tt") else { return nil }
        if let movie = media as? Movie {
            let year = Int(movie.year.prefix(4)).flatMap { $0 > 0 ? $0 : nil }
            return Request(kind: .movie, id: movie.id, title: movie.hasTitleToShow ? movie.title : nil, year: year)
        }
        if let show = media as? Show {
            return Request(kind: .show, id: show.id, title: show.hasTitleToShow ? show.title : nil, year: nil)
        }
        return nil
    }

    /// The load of `media`'s page: the one in flight, the one kept, else a
    /// new one, started at once. Nil when `media` has no page to load.
    public func detail(for media: Media) -> TitleDetail? {
        guard let request = DetailStore.request(for: media) else { return nil }
        return detail(for: request, prewarming: false)
    }

    /// Whether a page of `media` would open on an answer already there or
    /// on its way (the tests, the logs).
    public func hasDetail(for media: Media) -> Bool {
        guard let request = DetailStore.request(for: media) else { return false }
        return usable(request.key) != nil
    }

    /// The next page of `media` asks its sources again (Retry).
    public func forget(_ media: Media) {
        guard let request = DetailStore.request(for: media) else { return }
        details[request.key] = nil
        order.removeAll { $0 == request.key }
    }

    public func removeAll() {
        details = [:]
        order = []
    }

    private func usable(_ key: String) -> TitleDetail? {
        guard let detail = details[key] else { return nil }
        let time = now()
        if let finishedAt = detail.finishedAt {
            return detail.isConclusive && time - finishedAt <= DetailStore.lifetime ? detail : nil
        }
        return time - detail.startedAt <= DetailStore.staleAfter ? detail : nil
    }

    private func detail(for request: Request, prewarming: Bool) -> TitleDetail {
        let key = request.key
        if let detail = usable(key) {
            touch(key)
            return detail
        }
        var request = request
        let detail = TitleDetail(kind: request.kind, id: request.id, startedAt: now())
        detail.wasPrewarmed = prewarming
        if prewarming {
            let gate = DetailGate()
            request.gate = gate
            detail.gate = gate
        }
        details[key] = detail
        touch(key)
        // The oldest go; never one still loading for a page.
        while order.count > DetailStore.capacity,
              let victim = order.first(where: { details[$0].map { $0.isFinished || !$0.isObserved } ?? true }) {
            details[victim] = nil
            order.removeAll { $0 == victim }
        }
        start(detail, request: request)
        return detail
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func start(_ detail: TitleDetail, request: Request) {
        let tampering = self.tampering
        guard tampering.isOn else {
            fetch(request) { [weak self, weak detail] event in
                guard let self = self, let detail = detail else { return }
                self.deliver(event, to: detail)
            }
            return
        }
        // Delayed answers keep their order: each one after the one before.
        var lastDue = now()
        let later: (DetailEvent, TimeInterval) -> Void = { [weak self, weak detail] event, delay in
            guard let self = self else { return }
            let due = max(lastDue, self.now() + delay)
            lastDue = due
            self.after(max(0, due - self.now())) { [weak self, weak detail] in
                guard let self = self, let detail = detail else { return }
                self.deliver(event, to: detail)
            }
        }
        if tampering.fails {
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                userInfo: [NSLocalizedDescriptionKey: "Please check your internet connection and try again.".localized])
            return later(.finished(error), tampering.metadataDelay)
        }
        fetch(request) { event in
            switch event {
            case .metadata:
                later(event, tampering.metadataDelay)
            case .movieSources(var lists):
                if tampering.sourcesFail {
                    for provider in MovieSources.Provider.allCases where !lists.missing.contains(provider) {
                        lists[provider] = []
                        if !lists.failed.contains(provider) { lists.failed.append(provider) }
                    }
                }
                later(.movieSources(lists), tampering.sourcesDelay + (lists.isComplete ? tampering.lastSourceDelay : 0))
            case .showSources(var show):
                if tampering.sourcesFail {
                    show.episodes = show.episodes.map { episode in
                        var episode = episode
                        episode.torrents = []
                        return episode
                    }
                }
                later(.showSources(show), tampering.sourcesDelay)
            case .finished:
                later(event, 0)
            }
        }
    }

    private func deliver(_ event: DetailEvent, to detail: TitleDetail) {
        detail.receive(event, at: now())
        guard case .finished = event else { return }
        if detail.wasPrewarmed, detail.movieSources?.failed.contains(.torrentio) == true {
            prewarmPausedUntil = now() + DetailStore.prewarmBackoff
        }
        // A slot is free: the card that waited for it, if it still has the focus.
        startFocusedPrewarmIfPossible()
    }

    // MARK: Prewarm

    /// A card took the focus (nil: no card has it): its page is asked ahead
    /// once the focus has stayed `prewarmDwell` seconds on it.
    public func prewarm(_ media: Media?) {
        focusGeneration += 1
        focused = media.flatMap(DetailStore.request(for:))
        guard focused != nil else { return }
        let generation = focusGeneration
        after(DetailStore.prewarmDwell) { [weak self] in
            guard let self = self, self.focusGeneration == generation else { return }
            self.startFocusedPrewarmIfPossible()
        }
    }

    /// A Home card: its movie or show (`HomeItem.media`).
    public func prewarm(_ item: HomeItem?) {
        prewarm(item?.media)
    }

    /// The pointer left the card of `media` (Mac): its page is no longer
    /// asked ahead — unless another card took over meanwhile (a hover's
    /// "out" may come after the next card's "in").
    public func stopPrewarm(of media: Media) {
        guard let request = DetailStore.request(for: media), focused?.key == request.key else { return }
        prewarm(nil as Media?)
    }

    /// The prewarms whose answers are still coming.
    var prewarmsInFlight: Int {
        return details.values.filter { $0.wasPrewarmed && !$0.isFinished && !$0.isObserved
            && !($0.gate?.isParked ?? false) && now() - $0.startedAt <= DetailStore.staleAfter }.count
    }

    private func startFocusedPrewarmIfPossible() {
        guard let request = focused, usable(request.key) == nil else { return }
        guard now() >= prewarmPausedUntil, prewarmsInFlight < DetailStore.maxPrewarms else { return }
        focused = nil
        print("[Detail] \(request.id) asked ahead (its card kept the focus)")
        _ = detail(for: request, prewarming: true)
    }

    // MARK: The provider

    /// The default `fetch`: the provider's progressive loads; one answer at
    /// the end for a provider that has none.
    public static let provider: Fetch = { request, send in
        let deliver: (DetailEvent) -> Void = { event in
            if Thread.isMainThread { send(event) } else { DispatchQueue.main.async { send(event) } }
        }
        if let provider = MediaProviders.shared as? YTSEZTVProvider {
            switch request.kind {
            case .movie:
                let hint = request.title.flatMap { title in request.year.map { (title: title, year: $0) } }
                provider.loadMovieDetail(imdbId: request.id, hint: hint, gate: request.gate, update: deliver)
            case .show:
                provider.loadShowDetail(imdbId: request.id, gate: request.gate, update: deliver)
            }
            return
        }
        switch request.kind {
        case .movie:
            MediaProviders.shared.getMovieInfo(imdbId: request.id) { movie, error in
                if let movie = movie {
                    deliver(.metadata(movie))
                    var lists = MovieSources()
                    lists.yts = movie.torrents
                    lists.ytsKnowsTitle = true
                    lists.missing = []
                    lists.runtime = Torrent.mediaRuntime(of: movie)
                    deliver(.movieSources(lists))
                }
                deliver(.finished(movie == nil ? error : nil))
            }
        case .show:
            MediaProviders.shared.getShowInfo(imdbId: request.id) { show, error in
                if let show = show {
                    deliver(.metadata(show))
                    deliver(.showSources(show))
                }
                deliver(.finished(show == nil ? error : nil))
            }
        }
    }
}
