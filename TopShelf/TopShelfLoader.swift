import Foundation
import PopcornKit

/// Where the Top Shelf gets its titles: the Home engine (`HomeFeed`), run by
/// the extension itself on a light plan.
///
/// The app and the extension share no container (no App Group: it would
/// need new entitlements), so the extension cannot read the cache the app
/// keeps of its Home. It keeps its own — the same small JSON files, in its
/// own Caches folder — and asks the five lists of a light refresh itself
/// (`HomeFeed.Options.light`). For the same reason it knows nothing of the
/// user's library: no resume card, no "new episodes of your shows", and the
/// content languages are the defaults, not the ones chosen in the app — nor
/// its hidden shelves, nor whether its Terms of Service were accepted: the
/// extension asks its hosts (Cinemeta, YTS, apibay's 4K ranking) whenever
/// the system asks it for the shelf and a list is stale, on a box whose user
/// never opened the app. (5.2.0's extension asked YTS and EZTV the same way.)
///
/// One load (`load`):
/// - the disk has something to show: answered at once, without a request;
///   the lists that are not fresh any more are then asked, and `changed` is
///   called if what they bring differs from what was answered;
/// - the disk has nothing (a first launch, a cache the system emptied): the
///   answer waits for the refresh — `cap` seconds at most, then what has
///   arrived is answered, possibly nothing.
///
/// No TVServices here: the unit tests (a macOS bundle) run it on recorded
/// answers; `ContentProvider` turns the model into the system's objects.
final class TopShelfLoader: @unchecked Sendable {

    /// The longest the system waits for an answer of ours, and the deadline
    /// of every request. The header only says "in a timely manner"; a cold
    /// load takes about half a second on a good line (five small requests in
    /// parallel), so five seconds is a line on which waiting more would not
    /// help either.
    static let defaultCap: TimeInterval = 5

    let feed: HomeFeed
    private let texts: TopShelfModel.Texts
    private let rules: TopShelfModel.Rules
    private let cap: TimeInterval
    private let log: (String) -> Void

    private let lock = NSLock()
    /// What the system was last given.
    private var answered: TopShelfModel?

    /// - Parameters:
    ///   - feed: a hub on a light plan (`makeFeed`).
    ///   - cap: seconds a first answer may take.
    ///   - log: one line per step, with its timing.
    init(feed: HomeFeed, texts: TopShelfModel.Texts = .app, rules: TopShelfModel.Rules = TopShelfModel.Rules(),
         cap: TimeInterval = TopShelfLoader.defaultCap, log: @escaping (String) -> Void = { _ in }) {
        self.feed = feed
        self.texts = texts
        self.rules = rules
        self.cap = cap
        self.log = log
    }

    /// A hub for the Top Shelf: a light plan, every request given up after
    /// `cap` seconds, no library behind it.
    /// - Parameters:
    ///   - store: the cache; by default Caches/popcornkit-home of the
    ///     process — in the extension, its own container.
    ///   - defaults: where the hub's settings are read (the extension's own:
    ///     the app's do not reach it).
    static func makeFeed(store: HomeStore = HomeStore(), transport: HomeTransport = .live, defaults: UserDefaults = .standard,
                         deviceLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
                         cap: TimeInterval = TopShelfLoader.defaultCap, now: @escaping () -> Date = Date.init) -> HomeFeed {
        var options = HomeFeed.Options(requestDeadline: cap)
        options.light = true
        // The shelf shows ten titles: the hero is its main source.
        options.heroLimit = 10
        return HomeFeed(store: store, transport: transport, defaults: defaults, deviceLanguages: deviceLanguages,
                        options: options, now: now)
    }

    /// The shelf as the hub has it now, without a request and without
    /// waiting: what is in memory, read from the disk the first time. Any
    /// queue.
    func current() -> TopShelfModel {
        return TopShelfModel(snapshot: feed.cachedSnapshot(), texts: texts, rules: rules)
    }

    /// Loads the shelf.
    /// - Parameters:
    ///   - answer: called exactly once, on any queue: at once (before `load`
    ///     returns) when the disk has something to show, else when the
    ///     refresh has ended or after `cap` seconds, whichever comes first.
    ///     An empty model means there is nothing to show.
    ///   - changed: called on the main queue, at most once, when the refresh
    ///     ended with another shelf than the one answered: the system should
    ///     ask again.
    func load(answer: @escaping (TopShelfModel) -> Void, changed: @escaping () -> Void = {}) {
        let started = Date()
        let milliseconds = { Int((Date().timeIntervalSince(started) * 1000).rounded()) }
        let once = FirstAnswer()
        // True when `model` was the answer: the first of the disk, the
        // refresh and the cap.
        let give: (TopShelfModel, String) -> Bool = { [weak self] model, origin in
            guard let self = self, once.first() else { return false }
            self.lock.lock()
            self.answered = model
            self.lock.unlock()
            self.log("answered \(origin) in \(milliseconds()) ms: \(TopShelfLoader.describe(model))")
            answer(model)
            return true
        }

        let cached = current()
        if !cached.isEmpty {
            _ = give(cached, "from the disk")
        } else if cap.isFinite {
            // Nothing to show yet: the refresh decides, within the cap.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + cap) { [weak self] in
                guard let self = self, !once.isDone else { return }
                _ = give(self.current(), "at the cap")
            }
        }

        // A refresh already running (the system asked twice) is joined; the
        // lists that are still fresh are not asked.
        feed.refresh { [weak self] in
            guard let self = self else { return }
            let fresh = TopShelfModel(snapshot: self.feed.snapshot, texts: self.texts, rules: self.rules)
            if give(fresh, "after the refresh") { return }
            self.lock.lock()
            let answered = self.answered
            self.answered = fresh
            self.lock.unlock()
            let isNews = fresh != answered && !fresh.isEmpty
            self.log("refreshed in \(milliseconds()) ms: \(isNews ? "changed, " + TopShelfLoader.describe(fresh) : "the same shelf")")
            if isNews { changed() }
        }
    }

    /// "carousel of 10" / "2 sections (12 + 9)" / "nothing".
    static func describe(_ model: TopShelfModel) -> String {
        if !model.carousel.isEmpty { return "carousel of \(model.carousel.count)" }
        if !model.sections.isEmpty {
            return "\(model.sections.count) sections (\(model.sections.map { String($0.cards.count) }.joined(separator: " + ")))"
        }
        return "nothing"
    }
}

/// True once: the disk, the refresh and the cap race for the one answer.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// Somebody answered already (the cap then has nothing to build).
    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
