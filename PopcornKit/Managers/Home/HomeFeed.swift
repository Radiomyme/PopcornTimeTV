import Foundation

/// What the user's library gives the hub, as closures: the hub's rules stay
/// testable without a library. `HomeLocalHooks(library:)`
/// (HomeLibraryHooks.swift) answers them from `Library`, and `HomeFeed.shared`
/// is made with the app's; a hub made by hand sets them before `start()`.
/// Every closure but `prepare` is called on the MAIN queue, and must answer
/// at once from what is in memory or in the defaults — never from the
/// network. The defaults answer nothing: the local shelves are then simply
/// absent.
public struct HomeLocalHooks {
    /// Called once, on a background queue, before any other closure is
    /// asked: the moment for the library to read from the disk what its
    /// answers are made of (a file per followed show, say), so that they
    /// then come from memory. The hub's first paint waits for it; the main
    /// queue does not.
    public var prepare: () -> Void = {}
    /// The resume cards, most recent first: `progress` (0…1) and
    /// `remainingMinutes` set; an episode's card has its `episode`.
    public var continueWatching: () -> [HomeItem] = { [] }
    /// The watchlist, as it is ordered in the app.
    public var watchlist: () -> [HomeItem] = { [] }
    /// IMDb ids of the shows the user follows (watchlist shows, shows being
    /// watched), the ones that matter most first: the hub asks Cinemeta's
    /// calendar about the first 100 and makes their cards itself. For a
    /// library that does not follow the airings: one that does answers
    /// `newEpisodes` and leaves this empty, so the same calendar is not
    /// downloaded twice and one rule says what is new
    /// (`HomeLocalHooks(library:)`).
    public var followedShowIds: () -> [String] = { [] }
    /// New episodes of the followed shows the library knows by itself
    /// (shown before the ones Cinemeta's calendar adds).
    public var newEpisodes: () -> [HomeItem] = { [] }
    /// Has the user watched this episode of this show?
    public var isWatched: (_ imdbId: String, _ season: Int, _ episode: Int) -> Bool = { _, _, _ in false }
    /// The hub is about to refresh (`start`, `refresh`; not `refreshLocal`):
    /// the moment for the library to bring up to date what it keeps from
    /// the network itself (the followed shows' airings, the titles its cards
    /// lack). It returns at once; whoever set it calls `refreshLocal()` when
    /// something changed.
    public var willRefresh: () -> Void = {}

    public init() {}
}

/// The loader of the hub: the only asynchronous part.
///
/// - `start()` paints from the disk cache at once (no request), then refreshes.
/// - A refresh asks the sources in three phases (`HomePlan`): the four
///   requests of the first paint, then the rest, then the rankings and the
///   genres. Requests of a phase run in parallel; a list that is still fresh
///   is not asked. Each answer is parsed, cached and delivered at once: a
///   slow host only delays its own shelves.
/// - Every source is optional. When one fails, its cached list stays; when
///   there is none, the stand-in of feeds-live §5.6 is asked or derived.
/// - Concurrent refreshes share one load; a forced one that joins makes it
///   ask the lists it had skipped as fresh.
/// - When a refresh ends, the titles of the rankings no list knows are
///   looked up (a few small requests); the refresh does not wait for them.
/// - The local shelves (`HomeLocalHooks`) are recomputed by `refreshLocal()`,
///   without any request unless the user's titles changed what the page
///   reads (another set of followed shows, another genre).
///
/// Updates arrive on the main queue through `onUpdate`. The network is a
/// closure (`HomeTransport`), like `Top100Resolver`'s: the tests replay
/// recorded answers.
public final class HomeFeed: @unchecked Sendable {

    public struct Options: Sendable {
        /// A request whose transport has not called back after this is a failure.
        public var requestDeadline: TimeInterval = 15
        /// A phase starts when the one before has answered — or after this,
        /// so a host that hangs does not hold the next shelves back.
        public var phaseGrace: TimeInterval = 1.5
        /// Cards in the hero.
        public var heroLimit = 8
        /// Cards in a shelf of posters or of landscape cards.
        public var shelfLimit = 30
        /// Titles in a ranking.
        public var rankedLimit = 20
        /// Genre shelves at the end of the page (0: none).
        public var genreShelves = 4
        /// Two updates are at least this far apart (0: as they come): a
        /// screen gets one page per frame, two frames at 60 Hz. Pages made
        /// meanwhile are folded into the next update, the newest wins.
        public var updateSpacing: TimeInterval = 0.034
        /// A light refresh, for the Top Shelf extension: only the lists of
        /// the first paint (hero, trending and new titles, 4K) and the 4K
        /// ranking their format badges come from — five requests, then what
        /// their answers call for (the year before in January, the stand-in
        /// of a list that failed). The other shelves are not asked, and no
        /// title of a ranking is looked up.
        public var light = false

        public init(requestDeadline: TimeInterval = 15, phaseGrace: TimeInterval = 1.5) {
            self.requestDeadline = requestDeadline
            self.phaseGrace = phaseGrace
        }

        var rules: HomeBuilder.Rules {
            var rules = HomeBuilder.Rules()
            rules.light = light
            rules.heroLimit = max(heroLimit, 0)
            rules.shelfLimit = max(shelfLimit, 1)
            rules.rankedLimit = max(rankedLimit, 1)
            rules.rankedMinimum = min(rules.rankedMinimum, rules.rankedLimit)
            rules.genreShelves = max(genreShelves, 0)
            return rules
        }
    }

    /// The app's hub: `HomeStore.defaultDirectory`, the real hosts, the
    /// standard defaults, and the user's library (`Library.shared`) behind
    /// its local shelves — its hooks are the library's, and the shelves
    /// follow the library's changes (HomeLibraryHooks.swift).
    public static let shared: HomeFeed = {
        let feed = HomeFeed(hooks: HomeLocalHooks(library: .shared))
        feed.followChanges(of: .shared)
        return feed
    }()

    /// Posted on the main queue when a refresh has ended, after its last
    /// update was delivered (`snapshot` is the page it left); the object is
    /// the feed. For whoever follows the hub without being its screen
    /// (`onUpdate` has one subscriber, the screen's `HomeState`): the Apple
    /// TV app tells the system its Top Shelf may have changed.
    public static let didRefreshNotification = Notification.Name("PopcornKit.HomeFeed.didRefresh")

    /// The « Services » row and the page filtered on a service: the Apple
    /// TV's Home only (the other apps have no such row).
    #if os(tvOS)
    static let servicesRow = true
    #else
    static let servicesRow = false
    #endif

    public let store: HomeStore
    private let transport: HomeTransport
    private let settings: HomeSettings
    private let options: Options
    private let now: () -> Date
    let rules: HomeBuilder.Rules

    // Main queue only.
    private var mainHooks: HomeLocalHooks
    private var mainOnUpdate: ((HomeSnapshot) -> Void)?
    private var mainSnapshot = HomeSnapshot()
    /// The disk was read: the lists' cache, and what the hooks answer from
    /// (`whenReady`).
    private var mainReady = false
    /// What waits for that, in order.
    private var mainWaiting: [() -> Void] = []
    /// When the last update was delivered (`Options.updateSpacing`).
    private var mainLastDelivery: DispatchTime?

    /// Parsing, caching and building, in order.
    private let queue = DispatchQueue(label: "popcornkit.home.feed", qos: .userInitiated)
    /// `lists` and `local` are written on `queue` and on the main queue
    /// respectively, and read on both; `outgoing`, `deliveryPosted` and
    /// `checkpoints` go from `queue` to the main queue: under this lock.
    private let lock = NSLock()
    private var lists: [String: HomeSourceList] = [:]
    private var local = HomeLocal()
    /// The newest page `rebuild()` made that the main queue has not taken
    /// yet, and whether a block to take it is queued (`deliver`).
    private var outgoing: HomeSnapshot?
    private var deliveryPosted = false
    /// Pages that must be delivered as they are, each before what waits
    /// for it runs (a refresh's completions see the page it left, not one
    /// a lookup made since).
    private var checkpoints: [(snapshot: HomeSnapshot, work: () -> Void)] = []

    // `queue` only.
    private var diskLoaded = false
    private var running: Refresh?
    /// The last refresh that could tell found no source (see `finish`).
    private var reachedNothing = false
    /// Keys of the sources that gave no list at their last attempt: no
    /// answer, not their JSON, or a list the cache policy refused. A
    /// refresh does not hold their shelves back while it tries them again
    /// (the stand-in stays on screen), and their host failing again is no
    /// news of the network. Kept on disk with the lists
    /// (`HomeStore.readDown`): a new launch paints the page of the last
    /// session.
    private var down = Set<String>()
    /// `down` as the disk has it.
    private var savedDown = Set<String>()
    /// Keys of the sources of the last plan a refresh was started with.
    private var planned = Set<String>()
    /// IMDb ids being looked up: lookups outlive the refresh that asked them.
    private var lookingUp = Set<String>()

    /// What an answer was worth.
    private enum Answer {
        /// A list of the source, kept.
        case kept
        /// The source answered, but not a list to keep: shorter than the
        /// one kept, or empty when it never is.
        case refused
        /// No answer, or not this source's JSON.
        case none
    }

    /// One refresh: what was asked, what is still in flight, who waits.
    private final class Refresh: @unchecked Sendable {
        let plan: HomePlan
        /// Every list is asked, fresh or not. A forced refresh that joins
        /// one that is not sets it.
        var force: Bool
        var phase = 0
        /// Keys of the sources asked, or skipped as fresh.
        var started = Set<String>()
        /// The sources skipped as fresh.
        var skipped: [HomeSource] = []
        var inFlight = Set<String>()
        /// Source key → it answered a list that was kept.
        var outcomes: [String: Bool] = [:]
        /// Keys of the sources that answered or failed.
        var settled = Set<String>()
        /// The hosts asked.
        var hosts = Set<HomeRequest.Host>()
        /// The hosts that had a source down when the refresh started.
        let downHosts: Set<HomeRequest.Host>
        /// A source answered: a list of its own, kept or not.
        var reached = false
        var completions: [() -> Void] = []

        init(plan: HomePlan, force: Bool, downHosts: Set<HomeRequest.Host>) {
            self.plan = plan
            self.force = force
            self.downHosts = downHosts
        }
    }

    /// - Parameters:
    ///   - store: the disk cache (its folder: one of its own, in an App
    ///     Group container to share the hub with the Top Shelf extension).
    ///   - transport: the network; `.live` in the apps.
    ///   - defaults: where `HomeSettings` are read.
    ///   - deviceLanguages: see `HomeSettings`.
    ///   - now: the clock.
    public convenience init(store: HomeStore = HomeStore(), transport: HomeTransport = .live,
                            defaults: UserDefaults = .standard,
                            deviceLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
                            hooks: HomeLocalHooks = HomeLocalHooks(), options: Options = Options(),
                            now: @escaping () -> Date = Date.init) {
        self.init(store: store, transport: transport, defaults: defaults, deviceLanguages: deviceLanguages,
                  hooks: hooks, options: options, rules: options.rules, now: now)
    }

    init(store: HomeStore, transport: HomeTransport, defaults: UserDefaults,
         deviceLanguages: @escaping () -> [String], hooks: HomeLocalHooks, options: Options,
         rules: HomeBuilder.Rules, now: @escaping () -> Date) {
        self.store = store
        self.transport = transport
        self.settings = HomeSettings(defaults: defaults, deviceLanguages: deviceLanguages)
        self.mainHooks = hooks
        self.options = options
        self.rules = rules
        self.now = now
    }

    // MARK: - API (main queue)

    /// The library's side. Set on the main queue, before `start()`.
    public var hooks: HomeLocalHooks {
        get { mainHooks }
        set { mainHooks = newValue }
    }

    /// Called on the main queue at every change: a list answered, the
    /// refresh started or ended, the local shelves were recomputed. Changes
    /// that come together (lists answering within the same moment) are one
    /// call, with the page they leave.
    public var onUpdate: ((HomeSnapshot) -> Void)? {
        get { mainOnUpdate }
        set { mainOnUpdate = newValue }
    }

    /// The last snapshot delivered (main queue).
    public var snapshot: HomeSnapshot { mainSnapshot }

    /// Paints from the disk cache, then refreshes what is not fresh.
    /// `completion` runs on the main queue when the refresh ends.
    public func start(completion: (() -> Void)? = nil) {
        // The first update of a refresh is the page as the cache has it.
        refresh(force: false, completion: completion)
    }

    /// Asks every list that is not fresh (`force`: every list, and every
    /// host, whatever the transport remembers of the ones that failed). A
    /// refresh already running is joined, not doubled; a forced one makes
    /// it ask the lists it skipped as fresh. `completion` runs on the main
    /// queue when it ends.
    public func refresh(force: Bool = false, completion: (() -> Void)? = nil) {
        whenReady {
            self.mainHooks.willRefresh()
            self.readLocal()
            self.queue.async { self.begin(force: force, completion: completion) }
        }
    }

    /// Recomputes the local shelves (resume cards, the user's shows, the
    /// watchlist) from the hooks: no request. For when the user comes back
    /// to the hub after watching something or editing the watchlist.
    ///
    /// One exception: when the user's titles changed what the page reads —
    /// another set of followed shows, the genres of a title just added —
    /// the lists nobody asked yet are asked at once, by a refresh (the
    /// shelves on screen stay meanwhile).
    public func refreshLocal() {
        whenReady {
            self.readLocal()
            self.queue.async {
                if self.running == nil, self.readsUnaskedLists() {
                    self.begin(force: false, completion: nil)
                } else {
                    self.rebuild()
                }
            }
        }
    }

    /// The hub as the disk cache has it, without any request and without
    /// waiting: for the Top Shelf extension, or a first frame. The local
    /// shelves are the ones last read from the hooks. Any queue.
    public func cachedSnapshot() -> HomeSnapshot {
        return queue.sync {
            loadDisk()
            return makeSnapshot()
        }
    }

    /// The page the disk cache has, with the user's own shelves, made at
    /// once on the main queue — for a screen whose very first frame should
    /// be whole (`HomeState.paintFromDisk`). It reads the lists' cache and
    /// asks the hooks now, before their `prepare`: what the library has not
    /// read yet it reads on the main queue. No request, no refresh, and
    /// nothing delivered: the caller shows it.
    public func diskSnapshot() -> HomeSnapshot {
        dispatchPrecondition(condition: .onQueue(.main))
        queue.sync { loadDisk() }
        readLocal()
        return queue.sync { makeSnapshot() }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Runs `work` on the main queue once the hub answers from memory. The
    /// first call reads the disk first, off the main queue: the lists' cache
    /// on `queue`, and what the hooks answer from (`prepare`) on a queue of
    /// its own — a library with many shows holds neither the lists nor the
    /// main queue back. What is called meanwhile runs after it, in order;
    /// later calls run at once.
    private func whenReady(_ work: @escaping () -> Void) {
        onMain {
            guard !self.mainReady else { return work() }
            self.mainWaiting.append(work)
            guard self.mainWaiting.count == 1 else { return }
            let disk = DispatchGroup()
            self.queue.async(group: disk) { self.loadDisk() }
            DispatchQueue.global(qos: .userInitiated).async(group: disk, execute: self.mainHooks.prepare)
            disk.notify(queue: .main) {
                self.mainReady = true
                let waiting = self.mainWaiting
                self.mainWaiting = []
                waiting.forEach { $0() }
            }
        }
    }

    // MARK: - Local (main queue)

    /// Asks the hooks. The watched state is asked for the episodes that can
    /// be "new episodes" only (the followed shows' latest ones).
    private func readLocal() {
        var fresh = HomeLocal()
        fresh.continueWatching = mainHooks.continueWatching()
        fresh.watchlist = mainHooks.watchlist()
        fresh.followedShowIds = mainHooks.followedShowIds()
        fresh.newEpisodes = mainHooks.newEpisodes()
        fresh.watchedEpisodeIds = watched(among: fresh)
        lock.lock()
        local = fresh
        lock.unlock()
    }

    private func watched(among local: HomeLocal) -> Set<String> {
        lock.lock()
        let lists = self.lists
        lock.unlock()
        let candidates = HomeBuilder.followedCandidates(inputs(lists: lists, local: local), rules: rules)
        var watched = Set<String>()
        for candidate in candidates where mainHooks.isWatched(candidate.imdbId, candidate.season, candidate.number) {
            watched.insert(HomeItem.episodeId(imdbId: candidate.imdbId, season: candidate.season, number: candidate.number))
        }
        return watched
    }

    /// The calendar changed: which of its episodes are watched is asked on
    /// the main queue before the shelf is rebuilt (no card of a watched
    /// episode flashes by).
    private func rewatchThenRebuild() {
        DispatchQueue.main.async {
            self.lock.lock()
            var local = self.local
            self.lock.unlock()
            local.watchedEpisodeIds = self.watched(among: local)
            self.lock.lock()
            self.local = local
            self.lock.unlock()
            self.queue.async { self.rebuild() }
        }
    }

    // MARK: - State (`queue`)

    private func inputs(lists: [String: HomeSourceList], local: HomeLocal, pending: Set<String> = []) -> HomeBuilder.Inputs {
        return HomeBuilder.Inputs(lists: lists, local: local, languages: settings.contentLanguages,
                                  hidden: settings.hiddenShelves,
                                  sendsFollowedShows: settings.sendsFollowedShowsToCinemeta,
                                  streaming: HomeFeed.servicesRow ? settings.streamingShelves : [],
                                  service: HomeFeed.servicesRow ? settings.homeService : nil,
                                  region: settings.streamingRegion,
                                  allServicesTitle: Bundle.main.localizedString(forKey: "All", value: "All", table: nil),
                                  pending: pending, now: now())
    }

    private func currentInputs() -> HomeBuilder.Inputs {
        lock.lock()
        let local = self.local
        lock.unlock()
        return inputs(lists: lists, local: local, pending: running.map(awaited) ?? [])
    }

    /// The sources of the plan the refresh will ask, or is asking: their
    /// shelves wait for them instead of showing a stand-in for a moment.
    /// Not the ones that were down at their last attempt: their stand-in
    /// is what the page shows already, and it stays until they answer.
    private func awaited(_ refresh: Refresh) -> Set<String> {
        let now = self.now()
        var keys = Set<String>()
        for source in refresh.plan.sources where !refresh.settled.contains(source.key) && !down.contains(source.key) {
            if !refresh.force, let list = lists[source.key], state(list, at: now) == .fresh { continue }
            keys.insert(source.key)
        }
        return keys
    }

    /// The user's titles changed what the page reads (another set of
    /// followed shows, the genres of a title just added) and no refresh
    /// asked those lists: one is due. False before the first refresh.
    private func readsUnaskedLists() -> Bool {
        // A light plan reads the same lists as a full one and asks five of
        // them: the others are not "yet to ask".
        guard !rules.light, !planned.isEmpty else { return false }
        let plan = currentInputs().plan(rules: rules)
        return ([plan.calendar].compactMap { $0 } + plan.genres + plan.streaming).contains { !planned.contains($0.key) && lists[$0.key] == nil }
    }

    private func setList(_ list: HomeSourceList?, key: String) {
        lock.lock()
        lists[key] = list
        lock.unlock()
    }

    private func state(_ list: HomeSourceList, at now: Date) -> HomeCachePolicy.State {
        return HomeCachePolicy.state(savedAt: list.savedAt, now: now,
                                     lifetime: HomeCachePolicy.lifetime(forKey: list.key, now: now), complete: list.complete)
    }

    /// The list of a key when it can still be shown.
    private func usable(_ key: String) -> HomeSourceList? {
        guard let list = lists[key], state(list, at: now()) != .expired else { return nil }
        return list
    }

    private func loadDisk() {
        guard !diskLoaded else { return }
        diskLoaded = true
        let disk = store.readAll()
        lock.lock()
        // What memory already has (a refresh that started first) is newer.
        lists.merge(disk) { memory, _ in memory }
        lock.unlock()
        savedDown = store.readDown()
        down.formUnion(savedDown)
    }

    private func makeSnapshot() -> HomeSnapshot {
        let shelves = HomeBuilder.shelves(currentInputs(), rules: rules)
        let remote = shelves.contains { !HomeShelfID.local.contains($0.id) }
        return HomeSnapshot(shelves: shelves, isRefreshing: running != nil,
                            lastUpdated: shelves.compactMap(\.updatedAt).max(),
                            isOffline: reachedNothing, isUnavailable: reachedNothing && !remote)
    }

    /// Delivers the page as it is now, then runs `then` (main queue).
    ///
    /// Lists that answer together make rebuilds a few milliseconds apart.
    /// Delivered one by one, they would hand a screen two or three pages
    /// within one frame (SwiftUI: « onChange … tried to update multiple
    /// times per frame »). So one delivery waits at a time, and it takes
    /// the newest page when it runs; and two deliveries are at least
    /// `Options.updateSpacing` apart. A page made meanwhile replaces the one
    /// waiting: no update is lost, the last page is always delivered. A
    /// page with `then` work is delivered as it is, then the work runs.
    private func rebuild(then work: (() -> Void)? = nil) {
        let snapshot = makeSnapshot()
        lock.lock()
        outgoing = snapshot
        if let work { checkpoints.append((snapshot, work)) }
        let posts = !deliveryPosted
        deliveryPosted = true
        lock.unlock()
        guard posts else { return }
        DispatchQueue.main.async { self.deliverWhenDue() }
    }

    /// Main queue: delivers now, or once the spacing since the last
    /// delivery has passed.
    private func deliverWhenDue() {
        let spacing = options.updateSpacing
        if spacing > 0, let last = mainLastDelivery {
            let wait = spacing - Double(DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds) / 1e9
            if wait > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.deliver() }
                return
            }
        }
        deliver()
    }

    /// Main queue: the first page a completion waits for, else the newest
    /// page `rebuild()` left — if it is news; then what waited for it. A
    /// newer page left behind gets its own delivery, spaced.
    private func deliver() {
        lock.lock()
        let snapshot: HomeSnapshot?
        var work: (() -> Void)?
        if checkpoints.isEmpty {
            snapshot = outgoing
            outgoing = nil
        } else {
            let first = checkpoints.removeFirst()
            snapshot = first.snapshot
            work = first.work
            if checkpoints.isEmpty, outgoing == first.snapshot { outgoing = nil }
        }
        let more = !checkpoints.isEmpty || outgoing != nil
        deliveryPosted = more
        lock.unlock()
        if let snapshot, snapshot != mainSnapshot {
            mainSnapshot = snapshot
            mainLastDelivery = .now()
            mainOnUpdate?(snapshot)
        }
        work?()
        if more { DispatchQueue.main.async { self.deliverWhenDue() } }
    }

    // MARK: - Refresh (`queue`)

    private func begin(force: Bool, completion: (() -> Void)?) {
        // The user asks again: every host is tried.
        if force { transport.reset() }
        if let running = running {
            if let completion = completion { running.completions.append(completion) }
            // The refresh it joins skipped the fresh lists: it asks them too.
            if force, !running.force {
                running.force = true
                let skipped = running.skipped
                running.skipped = []
                for source in skipped { ask(source, running) }
            }
            return
        }
        let inputs = currentInputs()
        let refresh = Refresh(plan: inputs.plan(rules: rules), force: force, downHosts: Set(down.compactMap(HomeSource.host(ofKey:))))
        if let completion = completion { refresh.completions.append(completion) }
        running = refresh
        planned = Set(refresh.plan.sources.map(\.key))
        tidy(for: refresh.plan, followed: Set(inputs.local.followedShowIds))
        rebuild()
        advance(refresh)
    }

    /// Lists the plan no longer reads (a day that slid out of the window,
    /// the calendar of another set of shows) leave memory and disk. A new
    /// calendar starts from the old one's shows that are still followed, so
    /// the shelf does not blink while the new answer is on its way.
    private func tidy(for plan: HomePlan, followed: Set<String>) {
        if let calendar = plan.calendar, lists[calendar.key] == nil,
           let old = lists.values.filter({ $0.key.hasPrefix(HomeSource.calendarPrefix) }).max(by: { $0.savedAt < $1.savedAt }) {
            let kept = old.entries.filter { followed.contains($0.item.imdbId) }
            if !kept.isEmpty {
                setList(HomeSourceList(key: calendar.key, savedAt: old.savedAt, complete: false, entries: kept), key: calendar.key)
            }
        }
        for key in lists.keys where !plan.isCurrent(key) {
            setList(nil, key: key)
            store.remove(key)
        }
    }

    /// Starts the next phase.
    private func advance(_ refresh: Refresh) {
        guard running === refresh, refresh.phase < 3 else { return }
        refresh.phase += 1
        let phase = refresh.phase
        let sources = phase == 1 ? refresh.plan.phase1 : phase == 2 ? refresh.plan.phase2 : refresh.plan.phase3
        for source in sources + followUps(refresh) { request(source, refresh) }
        if phase < 3, options.phaseGrace.isFinite {
            queue.asyncAfter(deadline: .now() + options.phaseGrace) {
                if refresh.phase == phase { self.advance(refresh) }
            }
        }
        settle(refresh)
    }

    private func request(_ source: HomeSource, _ refresh: Refresh) {
        guard refresh.started.insert(source.key).inserted else { return }
        if !refresh.force, let list = lists[source.key], state(list, at: now()) == .fresh {
            refresh.skipped.append(source)
            return
        }
        ask(source, refresh)
    }

    private func ask(_ source: HomeSource, _ refresh: Refresh) {
        refresh.inFlight.insert(source.key)
        refresh.hosts.insert(source.request.host)
        send(source) { [weak self] data in self?.completed(source, data, refresh) }
    }

    /// Asks the transport; `completion` runs once, on `queue`, with the
    /// answer or — at the deadline, whichever comes first — nil.
    private func send(_ source: HomeSource, completion: @escaping @Sendable (Data?) -> Void) {
        let once = FirstCallback()
        let finish: @Sendable (Data?) -> Void = { [weak self] data in
            guard once.first(), let self = self else { return }
            self.queue.async { completion(data) }
        }
        transport.fetch(source.request, finish)
        if options.requestDeadline.isFinite {
            queue.asyncAfter(deadline: .now() + options.requestDeadline) { finish(nil) }
        }
    }

    private func completed(_ source: HomeSource, _ data: Data?, _ refresh: Refresh) {
        guard running === refresh else { return }
        refresh.inFlight.remove(source.key)
        refresh.settled.insert(source.key)
        let answer = ingest(source, data)
        refresh.outcomes[source.key] = answer == .kept
        if answer != .none { refresh.reached = true }
        if answer == .kept { down.remove(source.key) } else { down.insert(source.key) }
        for source in followUps(refresh) { request(source, refresh) }
        // A failure changes the page too: the stand-in of a shelf whose
        // source just failed may now be shown.
        if answer == .kept, source.key.hasPrefix(HomeSource.calendarPrefix) { rewatchThenRebuild() } else { rebuild() }
        settle(refresh)
    }

    /// Parses an answer and keeps it when the cache policy says so.
    private func ingest(_ source: HomeSource, _ data: Data?) -> Answer {
        let now = self.now()
        guard let data = data, let entries = HomeParse.entries(data, parser: source.parser, now: now) else { return .none }
        let previous = usable(source.key)
        var list: HomeSourceList
        if source.merges {
            // A lookup: what it found, and "unknown" for what it did not, on
            // top of the earlier lookups (their date stays: the whole list
            // is asked again when it expires).
            let found = Set(entries.map(\.item.imdbId))
            let kind: HomeItem.Kind = source.key == HomeSource.lookupMoviesKey ? .movie : .show
            let unknown = source.lookupIds.filter { !found.contains($0) }.map { HomeEntry.unknown(imdbId: $0, kind: kind) }
            let asked = found.union(source.lookupIds)
            let earlier = (previous?.entries ?? []).filter { !asked.contains($0.item.imdbId) }
            list = HomeSourceList(key: source.key, savedAt: previous?.savedAt ?? now, complete: true,
                                  entries: Array((entries + unknown + earlier).prefix(200)))
        } else {
            // The titles only: a ranking's releases without an id (pending)
            // may name no title at all.
            let titled = { (list: [HomeEntry]) in list.filter { !$0.isPending }.count }
            let decision = HomeCachePolicy.decision(count: titled(entries), minimum: source.minimum,
                                                    allowsEmpty: source.allowsEmpty, previous: previous.map { titled($0.entries) })
            guard decision.accept else { return .refused }
            list = HomeSourceList(key: source.key, savedAt: now, complete: decision.complete, entries: entries)
        }
        list.version = HomeSourceList.currentVersion
        setList(list, key: source.key)
        store.write(list)
        return .kept
    }

    /// What the answers so far call for: the year before when a list of
    /// this year is short (January), the stand-in of a source that failed
    /// and has nothing cached (feeds-live §5.6).
    private func followUps(_ refresh: Refresh) -> [HomeSource] {
        let year = refresh.plan.year
        func settled(_ source: HomeSource) -> Bool {
            return refresh.started.contains(source.key) && !refresh.inFlight.contains(source.key)
        }
        func missing(_ source: HomeSource) -> Bool { usable(source.key) == nil }
        func down(_ source: HomeSource) -> Bool { settled(source) && refresh.outcomes[source.key] == false && missing(source) }
        func short(_ source: HomeSource) -> Bool {
            guard settled(source), let list = usable(source.key) else { return false }
            return list.entries.count < HomeBuilder.Rules.yearRollover
        }
        var sources: [HomeSource] = []
        let byYear: [(Int) -> HomeSource] = [HomeSource.ytsNew, HomeSource.ytsYear, HomeSource.ytsTop, HomeSource.seriesYear, HomeSource.ytsLikes]
        for source in byYear where short(source(year)) { sources.append(source(year - 1)) }
        if down(.movieTop) { sources.append(.ytsLikes(year)) }
        if down(.ytsNew(year)), missing(.ytsNew(year - 1)) { sources.append(.movieFeatured) }
        if (down(.ytsYear(year)) && missing(.ytsYear(year - 1))) || (down(.ytsTop(year)) && missing(.ytsTop(year - 1))) {
            sources.append(.movieTopNext)
        }
        return sources.filter { !refresh.started.contains($0.key) }
    }

    /// Nothing in flight: the next phase, or the end.
    private func settle(_ refresh: Refresh) {
        guard running === refresh, refresh.inFlight.isEmpty else { return }
        if refresh.phase < 3 { return advance(refresh) }
        finish(refresh)
    }

    private func finish(_ refresh: Refresh) {
        running = nil
        // One answer: the network is there. None: it is not — when that is
        // news. Nothing asked (everything fresh) says nothing about the
        // network, and neither do hosts that were already down failing
        // again while the others were left alone, their lists being fresh:
        // a host the ISP blocks fails at every refresh, and the device is
        // not offline for that.
        if refresh.reached {
            reachedNothing = false
        } else if !refresh.hosts.isEmpty,
                  !refresh.hosts.isSubset(of: refresh.downHosts) || refresh.hosts.isSuperset(of: refresh.plan.sources.map(\.request.host)) {
            reachedNothing = true
        }
        // What a source this refresh had no use for was worth is forgotten
        // (another day's schedule, the stand-in of a source that is back).
        down.formIntersection(refresh.started)
        if down != savedDown {
            savedDown = down
            store.write(down: down)
        }
        // The lookups are asked first: whoever is told the refresh ended
        // finds them asked. Their answers come in later blocks of `queue`,
        // after this page.
        lookUp()
        let completions = refresh.completions
        // After the update of the page this refresh leaves.
        rebuild {
            completions.forEach { $0() }
            NotificationCenter.default.post(name: HomeFeed.didRefreshNotification, object: self)
        }
        // The user's titles changed while it ran: what they added to the
        // plan is asked now.
        if readsUnaskedLists() { begin(force: false, completion: nil) }
    }

    /// Now that every list is in: the cards of the rankings' titles none of
    /// them knows, asked to Cinemeta — one request for the shows, one per
    /// movie. The page is already whole; each answer adds its cards.
    private func lookUp() {
        guard !rules.light else { return }
        let needed = HomeBuilder.lookupsNeeded(currentInputs(), rules: rules)
        let shows = needed.shows.filter { !lookingUp.contains($0) }
        var sources = needed.movies.filter { !lookingUp.contains($0) }.map(HomeSource.lookupMovie(id:))
        if !shows.isEmpty { sources.append(.lookupShows(ids: shows)) }
        for source in sources {
            lookingUp.formUnion(source.lookupIds)
            send(source) { [weak self] data in
                guard let self = self else { return }
                self.lookingUp.subtract(source.lookupIds)
                if self.ingest(source, data) == .kept { self.rebuild() }
            }
        }
    }

    /// No refresh and no lookup running, and no update waiting to be
    /// delivered (the tests wait for this).
    var isIdle: Bool {
        return queue.sync {
            lock.lock()
            defer { lock.unlock() }
            return running == nil && lookingUp.isEmpty && !deliveryPosted
        }
    }
}

/// True once: the first of two racing callbacks wins.
private final class FirstCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
