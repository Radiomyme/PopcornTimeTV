import Foundation

/// The extra sources of one episode — Time4Popcorn, Torrentio, The Pirate
/// Bay / Knaben — asked together, with ONE deadline for the caller.
///
/// Before, each play flow (Apple TV, iPhone / iPad, Mac) asked the three
/// with a `DispatchGroup` and waited for all of them: one source that did
/// not answer held every episode for its own 10 s timeout (Time4Popcorn's
/// host has no fallback), at each press, and nothing was kept from one
/// press to the next. Here:
///
/// - `resolve` answers when the three have answered, or `deadline` seconds
///   after they were asked with what has come by then (`Sources.missing`
///   names the others); a list completed afterwards goes to `late`, and to
///   the next call;
/// - the caller says what a partial list is worth to it (`isEnough`): a
///   chooser can open on what is in, but a release played without asking,
///   or « No torrents found », must not be decided on a list a source is
///   about to complete. A list it refuses is offered again each time a
///   source answers; nothing holds a caller longer than `patience`;
/// - a source that missed the deadline and then answered nothing (a dead
///   host: the clients fail when their own timeout ends) is no longer
///   waited for during `benchSeconds` (`Sources.awaited` leaves it out): the
///   next episodes answer as soon as the other sources have, with something
///   to show. It is still asked, and waited for again once it answers in
///   time or with torrents (slow, but alive);
/// - a complete answer with at least one torrent is reused for `lifetime`.
///   When a source FAILED in it (a timeout, an HTTP error: nothing says the
///   episode has no torrent there), the next call keeps the other lists and
///   asks that source again;
/// - `prefetch` asks ahead (a detail page showing the episode Play starts):
///   the press then finds the answer, or joins the request in flight — the
///   deadline counts from the moment the sources were asked.
///
/// Each call logs its `[Start] sources` line (`PlaybackStartTrace`) — `[UpNext] sources asked ahead`
/// when episode chaining asks during playback, which is no start.
/// Completions run on the main queue. Any thread.
public final class EpisodeSourceResolver {

    public static let shared = EpisodeSourceResolver()

    public enum Provider: String, CaseIterable {
        case time4Popcorn = "T4P"
        case torrentio = "Torrentio"
        case extra = "TPB/Knaben"
    }

    /// What the sources answered for one episode.
    public struct Sources {
        public var time4Popcorn: [Torrent] = []
        public var torrentio: [Torrent] = []
        public var extra: [Torrent] = []
        /// The sources whose answer is not in.
        public var missing: [Provider] = []
        /// Among `missing`, the sources still expected: not the ones on the
        /// bench (they did not answer lately, nothing says they will now).
        public var awaited: [Provider] = []
        /// The sources that answered with a failure (a timeout, an HTTP
        /// error): their list is empty, and nothing says the episode has no
        /// torrent there. The next call asks them again.
        public var failed: [Provider] = []

        public init() {}

        public var isComplete: Bool { missing.isEmpty }
        public var count: Int { time4Popcorn.count + torrentio.count + extra.count }

        /// The episode's list as the play flows build it: Time4Popcorn first,
        /// then `base` (the episode's own torrents: EZTV) and Torrentio, then
        /// the TPB / Knaben torrents no other source lists
        /// (`ExtraTorrentSources.novel`), merged by info-hash
        /// (`TorrentioClient.merge`). `runtime` (seconds) goes on every
        /// candidate first: with their sizes it gives the bitrates the merge
        /// weighs against the connection.
        public func merged(withBase base: [Torrent], runtime: TimeInterval?) -> [Torrent] {
            let primary = time4Popcorn.withMediaRuntime(runtime)
            let legacy = (base + torrentio).withMediaRuntime(runtime)
            let novel = ExtraTorrentSources.novel(extra.withMediaRuntime(runtime), beside: primary + legacy)
            #if DEBUG
            // The bench's releases (`seed`) are local .torrent files: no
            // info-hash, which the merge needs — it left them all out. They
            // are kept after the merged list, in their order.
            var merged = TorrentioClient.merge(primary, with: legacy + novel)
            let local = (time4Popcorn + base + torrentio + extra).withMediaRuntime(runtime)
                .filter { $0.url.hasPrefix("/") && $0.url.lowercased().hasSuffix(".torrent") }
            for torrent in local where !merged.contains(where: { $0.url == torrent.url }) { merged.append(torrent) }
            return merged
            #else
            return TorrentioClient.merge(primary, with: legacy + novel)
            #endif
        }

        subscript(provider: Provider) -> [Torrent] {
            get {
                switch provider {
                case .time4Popcorn: return time4Popcorn
                case .torrentio: return torrentio
                case .extra: return extra
                }
            }
            set {
                switch provider {
                case .time4Popcorn: time4Popcorn = newValue
                case .torrentio: torrentio = newValue
                case .extra: extra = newValue
                }
            }
        }
    }

    /// The episode asked for.
    struct Request {
        let showId: String
        let showTitle: String?
        let season: Int
        let episode: Int

        var key: String { "\(showId) S\(season)E\(episode)" }
    }

    /// Asks one source; its completion may come on any queue, once — with
    /// nil when the source failed (as opposed to: has nothing).
    typealias Fetch = (_ provider: Provider, _ request: Request, _ completion: @escaping ([Torrent]?) -> Void) -> Void

    /// How long a caller waits for every source, from the moment they were
    /// asked: past it, a partial list answers the caller it is enough for.
    public static var deadline: TimeInterval = 3
    /// How long a caller waits at most, whatever is in (beyond the clients'
    /// own 10 s timeouts: only a source that never calls back gets there).
    public static var patience: TimeInterval = 12
    /// How long a complete answer is reused, counted from the moment its
    /// oldest list was asked for.
    public static var lifetime: TimeInterval = 10 * 60
    /// How long a source that missed the deadline is not waited for.
    public static var benchSeconds: TimeInterval = 5 * 60
    /// A request still incomplete after this long is abandoned (a source
    /// that never called back): the next call asks again.
    static let staleAfter: TimeInterval = 30

    private struct Waiter {
        let id: Int
        let askedAt: TimeInterval
        let isEnough: ((Sources) -> Bool)?
        let completion: (Sources) -> Void
        let late: ((Sources) -> Void)?
        /// Asked ahead by episode chaining, not by a press (`resolve`'s `askedAhead`).
        let askedAhead: Bool
    }

    private struct Entry {
        let startedAt: TimeInterval
        let token: Int
        /// When the oldest list of `sources` was asked for: `startedAt`, or
        /// earlier for the lists kept from an answer one source failed in.
        var since: TimeInterval
        /// On the bench when the sources were asked: not waited for.
        var spared: Set<Provider> = []
        var sources = Sources()
        var answered: Set<Provider> = []
        var completedAt: TimeInterval?
        /// Not answered yet.
        var waiters: [Waiter] = []
        /// Answered at the deadline with a partial list: `late` once complete.
        var lateWaiters: [Waiter] = []
        var deadlinePassed = false
        /// `patience` is over: what is in answers whoever still waits.
        var patienceOver = false
    }

    private let fetch: Fetch
    private let now: () -> TimeInterval
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let deliver: (@escaping () -> Void) -> Void
    private let log: (String) -> Void
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var benchedUntil: [Provider: TimeInterval] = [:]
    private var nextToken = 0
    private var nextWaiter = 0
    #if DEBUG
    /// The DEBUG bench (`seed`): the sources of an episode as given.
    private var debugSeeds: [String: Sources] = [:]
    /// Shows whose sources never reach the clients: what was seeded for an
    /// episode answers, else nothing. The bench's made-up show is one.
    private var debugOfflineShows: Set<String> = [EpisodeSourceResolver.debugShowID]
    #endif

    /// - Parameters:
    ///   - fetch: asks one source (default: the three clients).
    ///   - now: a monotonic clock, in seconds.
    ///   - after: runs a block after a delay (the deadline).
    ///   - deliver: runs a completion (default: asynchronously on the main queue).
    init(fetch: @escaping Fetch = EpisodeSourceResolver.clients,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
         },
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         log: @escaping (String) -> Void = { print($0) }) {
        self.fetch = fetch
        self.now = now
        self.after = after
        self.deliver = deliver
        self.log = log
    }

    // MARK: API

    /// Asks the sources of an episode ahead of the press, unless a usable
    /// answer or a request in flight exists. Nothing for a show without an
    /// imdb id (the sources are keyed by it).
    public func prefetch(showId: String, showTitle: String?, season: Int, episode: Int) {
        guard showId.hasPrefix("tt") else { return }
        let request = Request(showId: showId, showTitle: showTitle, season: season, episode: episode)
        lock.lock()
        let start = startIfNeeded(request)
        lock.unlock()
        start?()
    }

    /// The sources of an episode: `completion` once, when every source has
    /// answered, or with a partial list — at the deadline, or before it once
    /// every source still expected is in with something to show (a source on
    /// the bench is not waited for); `late`, at most once and only after a
    /// partial `completion`, with the complete list.
    ///
    /// `isEnough` (nil: any list is) is asked of each partial list before it
    /// answers the caller, on the queue of the completions: false keeps the
    /// caller waiting — for the next source to answer, when it is asked
    /// again, for the complete list, or for `patience` seconds after the
    /// sources were asked, when what is in answers it whatever it holds.
    /// `askedAhead`: episode chaining asks for the next episode during playback — its timing is no
    /// start's (`[UpNext] sources asked ahead: …` instead of `[Start] sources: …`).
    public func resolve(showId: String, showTitle: String?, season: Int, episode: Int,
                        isEnough: ((Sources) -> Bool)? = nil, askedAhead: Bool = false,
                        completion: @escaping (Sources) -> Void, late: ((Sources) -> Void)? = nil) {
        guard showId.hasPrefix("tt") else {
            deliver { completion(Sources()) }
            return
        }
        let request = Request(showId: showId, showTitle: showTitle, season: season, episode: episode)
        let key = request.key
        lock.lock()
        let askedAt = now()
        if let entry = usableEntry(key), entry.completedAt != nil {
            let sources = entry.sources
            lock.unlock()
            log(Self.sourcesLine(elapsed: 0, detail: Self.detail(request, sources) + ", kept from "
                                 + "\(Int((askedAt - entry.startedAt).rounded())) s ago", askedAhead: askedAhead))
            deliver { completion(sources) }
            return
        }
        let start = startIfNeeded(request)
        nextWaiter += 1
        entries[key]?.waiters.append(Waiter(id: nextWaiter, askedAt: askedAt, isEnough: isEnough,
                                            completion: completion, late: late, askedAhead: askedAhead))
        // A request in flight may already be answerable (every source but a
        // benched one in, or its deadline past); else its own deadline, set
        // when it was sent, answers this caller too.
        let ready = answerWaitersIfDue(key)
        lock.unlock()
        start?()
        ready?()
    }

    /// A complete answer still in use for the episode (nil: none).
    public func cached(showId: String, season: Int, episode: Int) -> Sources? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = usableEntry(Request(showId: showId, showTitle: nil, season: season, episode: episode).key),
              entry.completedAt != nil else { return nil }
        return entry.sources
    }

    /// How many answers and requests are held (the tests).
    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Forgets every answer and the bench (the requests in flight still complete).
    public func removeAll() {
        lock.lock()
        entries = entries.filter { $0.value.completedAt == nil }
        benchedUntil = [:]
        lock.unlock()
    }

    #if DEBUG
    /// The made-up show of the DEBUG bench (`UpNextDebugHooks`): never asked
    /// of a real source.
    public static let debugShowID = "tt0000001"

    /// DEBUG bench (`-PTDebugEpisodeSources`): `sources` answer for that
    /// episode, every time, through the usual path (deadline, waiters, the
    /// `[Start] sources` line); no source of that show is asked from now on
    /// — an episode not seeded answers with nothing.
    public func seed(_ sources: Sources, showId: String, season: Int, episode: Int) {
        let key = Request(showId: showId, showTitle: nil, season: season, episode: episode).key
        var seeded = sources
        seeded.missing = []
        seeded.awaited = []
        seeded.failed = []
        lock.lock()
        debugSeeds[key] = seeded
        debugOfflineShows.insert(showId)
        entries[key] = nil
        lock.unlock()
        log("[UpNextDebug] sources seeded for \(key): \(Self.detail(seeded))")
    }

    /// Whether a show's sources are the bench's (never asked of a real source).
    public func isOffline(showId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return debugOfflineShows.contains(showId)
    }
    #endif

    // MARK: Requests

    /// The entry of `key` when it can still serve: a request in flight, or a
    /// complete answer that found something, in which no source failed, and
    /// young enough. Under `lock`.
    private func usableEntry(_ key: String) -> Entry? {
        guard let entry = entries[key] else { return nil }
        guard entry.completedAt != nil else {
            return now() - entry.startedAt <= Self.staleAfter ? entry : nil
        }
        // A source that failed is asked again (`startIfNeeded` keeps the
        // other lists); an answer without a torrent may be a failure too
        // (a source whose client cannot tell): everything is asked again.
        return isWorthKeeping(entry) && entry.sources.failed.isEmpty ? entry : nil
    }

    /// A complete answer something can still be taken from: it found
    /// something, and its oldest list is young enough. Under `lock`.
    private func isWorthKeeping(_ entry: Entry) -> Bool {
        return entry.completedAt != nil && entry.sources.count > 0 && now() - entry.since <= Self.lifetime
    }

    /// Under `lock`: a new entry unless one is usable; returns the requests
    /// to send once the lock is released.
    private func startIfNeeded(_ request: Request) -> (() -> Void)? {
        let key = request.key
        guard usableEntry(key) == nil else { return nil }
        let time = now()
        // The entries nothing will be taken from go: a detail page asks
        // ahead for every show opened, and each answer holds three lists.
        entries = entries.filter { $0.value.completedAt == nil ? time - $0.value.startedAt <= Self.staleAfter
                                                                : isWorthKeeping($0.value) }
        nextToken += 1
        let token = nextToken
        var entry = Entry(startedAt: time, token: token, since: time)
        var asked = Provider.allCases
        // What is left for `key` is a complete answer one source failed in:
        // the other lists are kept, only that source is asked again.
        if let kept = entries[key], kept.completedAt != nil {
            asked = kept.sources.failed
            entry.since = kept.since
            entry.sources = kept.sources
            entry.sources.failed = []
            entry.answered = Set(Provider.allCases).subtracting(asked)
        }
        entry.sources.missing = asked
        // With every source on the bench (a network that was down) the
        // bench says nothing of which one is back: all are waited for.
        let benched = Set(Provider.allCases.filter { (benchedUntil[$0] ?? -.infinity) > time })
        entry.spared = benched.count == Provider.allCases.count ? [] : benched
        entry.sources.awaited = asked.filter { !entry.spared.contains($0) }
        entries[key] = entry
        #if DEBUG
        // The bench: the seeded lists answer, no client is asked.
        let offline: Sources? = debugOfflineShows.contains(request.showId) ? (debugSeeds[key] ?? Sources()) : nil
        #endif
        return { [weak self] in
            guard let self = self else { return }
            for provider in asked {
                #if DEBUG
                if let offline = offline {
                    self.providerAnswered(provider, offline[provider], key: key, token: token, request: request)
                    continue
                }
                #endif
                self.fetch(provider, request) { [weak self] torrents in
                    self?.providerAnswered(provider, torrents, key: key, token: token, request: request)
                }
            }
            // The entry's own deadline: a prefetch has no waiter to set one,
            // and the bench must learn of a source that did not answer. Then
            // the end of the wait, for the callers a partial list was not
            // enough for and a source that never calls back.
            self.after(Self.deadline) { [weak self] in self?.deadlineReached(key: key, token: token) }
            self.after(Self.patience) { [weak self] in self?.deadlineReached(key: key, token: token, isLast: true) }
        }
    }

    /// `torrents`: nil when the source failed.
    private func providerAnswered(_ provider: Provider, _ torrents: [Torrent]?, key: String, token: Int, request: Request) {
        lock.lock()
        guard var entry = entries[key], entry.token == token, !entry.answered.contains(provider) else {
            lock.unlock()
            return
        }
        entry.answered.insert(provider)
        entry.sources[provider] = torrents ?? []
        if torrents == nil {
            entry.sources.failed = Provider.allCases.filter { $0 == provider || entry.sources.failed.contains($0) }
        }
        entry.sources.missing = Provider.allCases.filter { !entry.answered.contains($0) }
        entry.sources.awaited = entry.sources.missing.filter { !entry.spared.contains($0) }
        // A real answer in time, or late with torrents (slow, not dead):
        // waited for again. A failure, even a quick one, changes nothing.
        if let torrents = torrents, !entry.deadlinePassed || !torrents.isEmpty { benchedUntil[provider] = nil }
        var lateCalls: [() -> Void] = []
        if entry.sources.isComplete {
            entry.completedAt = now()
            let sources = entry.sources
            for waiter in entry.lateWaiters {
                if let late = waiter.late { lateCalls.append { late(sources) } }
            }
            if !entry.lateWaiters.isEmpty {
                let line = "[Sources] \(Self.detail(request, sources)) — complete "
                    + "\(PlaybackStartTrace.milliseconds(now() - entry.startedAt)) ms after they were asked"
                lateCalls.append { [log] in log(line) }
            }
            entry.lateWaiters = []
        }
        entries[key] = entry
        let ready = answerWaitersIfDue(key)
        lock.unlock()
        ready?()
        if !lateCalls.isEmpty { deliver { lateCalls.forEach { $0() } } }
    }

    /// The deadline of the entry, then (`isLast`) the end of `patience`.
    private func deadlineReached(key: String, token: Int, isLast: Bool = false) {
        lock.lock()
        guard var entry = entries[key], entry.token == token else {
            lock.unlock()
            return
        }
        if !entry.deadlinePassed {
            entry.deadlinePassed = true
            let until = now() + Self.benchSeconds
            for provider in entry.sources.missing { benchedUntil[provider] = until }
        }
        if isLast { entry.patienceOver = true }
        entries[key] = entry
        let ready = answerWaitersIfDue(key)
        lock.unlock()
        ready?()
    }

    /// Under `lock`: what the entry has for its waiters, to run once the
    /// lock is released — the answer of all of them when it is complete or
    /// `patience` is over; else, at the deadline or once every source still
    /// expected is in with something to show, a partial list each of them
    /// takes or leaves (`offer`).
    private func answerWaitersIfDue(_ key: String) -> (() -> Void)? {
        guard var entry = entries[key], !entry.waiters.isEmpty else { return nil }
        let time = now()
        let age = time - entry.startedAt
        let sources = entry.sources
        if sources.isComplete || entry.patienceOver || age >= Self.patience {
            let waiters = entry.waiters
            entry.waiters = []
            if !sources.isComplete { entry.lateWaiters += waiters }
            entries[key] = entry
            let lines = waiters.map { waiter in
                Self.sourcesLine(elapsed: time - waiter.askedAt, detail: Self.detail(sources), askedAhead: waiter.askedAhead)
            }
            return { [deliver, log] in
                lines.forEach(log)
                deliver { waiters.forEach { $0.completion(sources) } }
            }
        }
        // The bench spares the wait only for a list with something in it: an
        // empty answer (a source that fails at once) releases nobody early.
        guard entry.deadlinePassed || age >= Self.deadline || (sources.awaited.isEmpty && sources.count > 0) else { return nil }
        let waiters = entry.waiters
        let token = entry.token
        return { [weak self, deliver] in
            deliver { self?.offer(sources, to: waiters, key: key, token: token, at: time) }
        }
    }

    /// On the queue of the completions: the partial list `sources` answers
    /// each of `waiters` it is enough for; the others go on waiting.
    private func offer(_ sources: Sources, to waiters: [Waiter], key: String, token: Int, at time: TimeInterval) {
        for waiter in waiters where waiter.isEnough?(sources) ?? true {
            lock.lock()
            // Still waiting: not answered meanwhile by the complete list or
            // by an earlier offer.
            guard var entry = entries[key], entry.token == token,
                  let index = entry.waiters.firstIndex(where: { $0.id == waiter.id }) else {
                lock.unlock()
                continue
            }
            entry.waiters.remove(at: index)
            entry.lateWaiters.append(waiter)
            entries[key] = entry
            lock.unlock()
            log(Self.sourcesLine(elapsed: time - waiter.askedAt, detail: Self.detail(sources), askedAhead: waiter.askedAhead))
            waiter.completion(sources)
        }
    }

    // MARK: Lines

    /// `PlaybackStartTrace.sourcesLine`, or for sources asked ahead by episode chaining
    /// "[UpNext] sources asked ahead: 810 ms — …".
    static func sourcesLine(elapsed: TimeInterval, detail: String, askedAhead: Bool) -> String {
        let line = PlaybackStartTrace.sourcesLine(elapsed: elapsed, detail: detail)
        guard askedAhead, line.hasPrefix("[Start] sources:") else { return line }
        return "[UpNext] sources asked ahead:" + line.dropFirst("[Start] sources:".count)
    }

    private static func detail(_ request: Request, _ sources: Sources) -> String {
        return "\(request.key): " + detail(sources)
    }

    /// "14 torrents (T4P 3 · Torrentio 9 · TPB/Knaben 2), not in time: T4P".
    static func detail(_ sources: Sources) -> String {
        let parts = Provider.allCases.filter { !sources.missing.contains($0) }.map { "\($0.rawValue) \(sources[$0].count)" }
        var text = "\(sources.count) torrent(s)" + (parts.isEmpty ? "" : " (\(parts.joined(separator: " · ")))")
        if !sources.missing.isEmpty {
            text += ", not in time: " + sources.missing.map(\.rawValue).joined(separator: ", ")
        }
        if !sources.failed.isEmpty {
            text += ", failed: " + sources.failed.map(\.rawValue).joined(separator: ", ")
        }
        return text
    }

    // MARK: The sources

    static func clients(_ provider: Provider, _ request: Request, completion: @escaping ([Torrent]?) -> Void) {
        switch provider {
        case .time4Popcorn:
            Time4PopcornClient.shared.episodeAnswer(imdbId: request.showId, season: request.season,
                                                    episode: request.episode, completion: completion)
        case .torrentio:
            TorrentioClient.shared.streamsAnswer(imdbId: request.showId, season: request.season,
                                                 episode: request.episode, completion: completion)
        case .extra:
            // The Pirate Bay + Knaben, exact episode only. Their searches
            // end in a list whatever happened: a failure there cannot be
            // told from an episode they do not have.
            ExtraTorrentSources.shared.episodeTorrents(imdbId: request.showId, showTitle: request.showTitle,
                                                       season: request.season, episode: request.episode,
                                                       completion: { completion($0) })
        }
    }
}
