//
//  CatalogCacheTests.swift
//  PopcornTimeTests
//
//  What the catalog keeps between two loads: the bounded cache with a lifetime (a show's
//  page), the first page of each list on disk and its stale-while-revalidate rules, and
//  the IMDb id → show directory behind "Recently Added" (bounded lookups, disk, the
//  schedule prefill). Clocks, timers, folders and lookups are injected: nothing here uses
//  the network, the app's caches or the real time.
//

import XCTest
import Foundation
@testable import PopcornKit

/// A clock a test moves.
private final class Clock {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        date += seconds
        lock.unlock()
    }
}

/// Timers collected instead of run: a test fires them by their delay.
private final class ManualScheduler {
    private var timers: [(delay: TimeInterval, work: () -> Void)] = []

    var schedule: (TimeInterval, @escaping () -> Void) -> Void {
        return { [self] delay, work in timers.append((delay, work)) }
    }

    func count(_ delay: TimeInterval) -> Int {
        return timers.filter { $0.delay == delay }.count
    }

    func fire(_ delay: TimeInterval) {
        let due = timers.filter { $0.delay == delay }
        timers.removeAll { $0.delay == delay }
        due.forEach { $0.work() }
    }
}

/// The lookups a directory makes: recorded, answered a moment later.
private final class Lookups {
    private let lock = NSLock()
    private var askedIds: [String] = []
    private var running = 0
    private var mostAtOnce = 0
    private var prefills = 0
    /// What an id is answered (default: a record named after it).
    var answers: [String: TVMazeShowDirectory.Outcome] = [:]
    /// Ids whose lookup never answers.
    var mute: Set<String> = []
    /// What the schedule gives.
    var schedule: [[String: Any]] = []

    var asked: [String] { lock.lock(); defer { lock.unlock() }; return askedIds }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return mostAtOnce }
    var prefillCount: Int { lock.lock(); defer { lock.unlock() }; return prefills }

    static func record(_ imdbId: String) -> [String: Any] {
        return ["id": abs(imdbId.hashValue % 100_000) + 1, "name": "Show \(imdbId)", "premiered": "2020-01-01",
                "externals": ["imdb": imdbId], "_links": ["self": ["href": "https://api.tvmaze.com/shows/1"]]]
    }

    var fetch: TVMazeShowDirectory.Fetch {
        return { [self] imdbId, completion in
            lock.lock()
            askedIds.append(imdbId)
            running += 1
            mostAtOnce = max(mostAtOnce, running)
            let answer = answers[imdbId] ?? .show(Lookups.record(imdbId))
            let silent = mute.contains(imdbId)
            lock.unlock()
            guard !silent else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { [self] in
                lock.lock()
                running -= 1
                lock.unlock()
                completion(answer)
            }
        }
    }

    var prefill: TVMazeShowDirectory.Prefill {
        return { [self] completion in
            lock.lock()
            prefills += 1
            let shows = schedule
            lock.unlock()
            DispatchQueue.global().async { completion(shows) }
        }
    }
}

private func temporaryFolder() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PopcornTimeTests-catalog-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func ids(_ range: ClosedRange<Int>) -> [String] {
    return range.map { String(format: "tt%07d", $0) }
}

final class CatalogCacheTests: CheckedTestCase {

    private var folder: URL!
    private var clock: Clock!
    /// The stores made on `folder` (`snapshotStore`).
    private var stores: [CatalogSnapshotStore] = []

    override func setUp() {
        super.setUp()
        folder = temporaryFolder()
        clock = Clock()
    }

    override func tearDown() {
        // A store writes its files in the background: one landing after the
        // folder is deleted would make it again, and leave it in the
        // temporary directory (four or five folders per run of the suite).
        stores.forEach { $0.flush() }
        stores = []
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// A store on the test's folder, at the test's clock.
    private func snapshotStore() -> CatalogSnapshotStore {
        let clock = self.clock!
        let store = CatalogSnapshotStore(directory: folder, now: { clock.now })
        stores.append(store)
        return store
    }

    // MARK: BoundedTTLCache

    func testACachedValueExpires() {
        let clock = self.clock!
        let cache = BoundedTTLCache<String>(lifetime: 900, capacity: 30, now: { clock.now })
        eq(cache.fresh("tt1"), nil, "nothing stored")
        check(cache.any("tt1") == nil, "nothing stored, however old")
        cache.set("page", for: "tt1")
        eq(cache.fresh("tt1"), "page", "just stored: fresh")
        clock.advance(899)
        eq(cache.fresh("tt1"), "page", "14 min 59: fresh")
        clock.advance(2)
        eq(cache.fresh("tt1"), nil, "15 min 01: no longer fresh")
        eq(cache.any("tt1")?.value, "page", "but still there for when a refresh fails")
        eq(cache.any("tt1")?.age, 901, "with its age")
        cache.set("newer", for: "tt1")
        eq(cache.fresh("tt1"), "newer", "stored again: fresh again")
        cache.remove("tt1")
        check(cache.any("tt1") == nil, "removed")
        cache.set("a", for: "a")
        cache.removeAll()
        eq(cache.count, 0, "emptied")
    }

    func testTheCacheIsBounded() {
        let clock = self.clock!
        let cache = BoundedTTLCache<Int>(lifetime: 900, capacity: 3, now: { clock.now })
        for (index, key) in ["a", "b", "c"].enumerated() { cache.set(index, for: key) }
        eq(cache.count, 3, "three entries")
        // "a" is read: "b" is now the one used the longest ago.
        eq(cache.fresh("a"), 0, "a is there")
        cache.set(3, for: "d")
        eq(cache.count, 3, "still three")
        eq(cache.fresh("b"), nil, "the least recently used went")
        eq(cache.fresh("a"), 0, "a stayed")
        eq(cache.fresh("c"), 2, "c stayed")
        eq(cache.fresh("d"), 3, "d is in")
        for index in 0..<100 { cache.set(index, for: "k\(index)") }
        eq(cache.count, 3, "never more than its capacity")
        eq(BoundedTTLCache<Int>(lifetime: 1, capacity: 0).capacity, 1, "a capacity of at least one")
    }

    // MARK: Freshness

    func testHowLongAListIsFresh() {
        let recent = CatalogFreshness.movies(.date)
        eq(recent, CatalogFreshness(fresh: 30 * 60, stale: 24 * 3600), "Recently Added: 30 min, 24 h")
        eq(CatalogFreshness.movies(.year), recent, "New: as Recently Added")
        eq(CatalogFreshness.movies(.trending), CatalogFreshness(fresh: 6 * 3600, stale: 7 * 24 * 3600), "Trending: 6 h, 7 d")
        eq(CatalogFreshness.movies(.popularity), CatalogFreshness.movies(.trending), "Popular: as Trending")
        eq(CatalogFreshness.movies(.rating), CatalogFreshness.movies(.trending), "Top Rated: as Trending")
        eq(CatalogFreshness.shows(.trending), CatalogFreshness(fresh: 4 * 3600, stale: 7 * 24 * 3600), "Cinemeta: 4 h, 7 d")
        for filter in [ShowManager.Filters.popularity, .rating, .year, .name] {
            eq(CatalogFreshness.shows(filter), CatalogFreshness.shows(.trending), "\(filter): a Cinemeta catalog")
        }
        eq(CatalogFreshness.shows(.date), CatalogFreshness(fresh: 15 * 60, stale: 24 * 3600), "EZTV's latest: 15 min, 24 h")

        eq(recent.state(age: 0), .fresh, "just saved")
        eq(recent.state(age: 29 * 60 + 59), .fresh, "29 min 59")
        eq(recent.state(age: 30 * 60 + 1), .stale, "30 min 01")
        eq(recent.state(age: 23 * 3600 + 59 * 60), .stale, "23 h 59")
        eq(recent.state(age: 24 * 3600 + 60), .expired, "24 h 01")
        // A snapshot dated in the future (the clock went back): shown, but asked again.
        eq(recent.state(age: -120), .stale, "saved \"in two minutes\"")
        eq(recent.state(age: -3 * 24 * 3600), .expired, "saved \"in three days\"")
    }

    // MARK: Snapshots on disk

    func testASnapshotIsReadBackFromDisk() {
        let clock = self.clock!
        let key = CatalogSnapshotStore.key(kind: "movies", filter: "trending", genre: "All", order: .descending)
        eq(key, "movies-trending-All-desc", "the key of a list")
        eq(CatalogSnapshotStore.key(kind: "shows", filter: "updated", genre: "Science Fiction", order: .ascending),
           "shows-updated-Science Fiction-asc", "another")
        let store = snapshotStore()
        check(store.read(key) == nil, "nothing saved yet")
        let items: [[String: Any]] = [["imdb_id": "tt1", "title": "One"], ["imdb_id": "tt2", "title": "Two"]]
        store.write(key, items: items)
        eq(store.read(key)?.snapshot.items.count, 2, "read back at once")
        eq(store.read(key)?.age, 0, "just saved")
        clock.advance(100)
        eq(store.read(key)?.age, 100, "its age follows the clock")
        store.flush()
        // Another store on the same folder: a relaunch.
        let relaunched = snapshotStore()
        let read = relaunched.read(key)
        eq(read?.snapshot.items.count, 2, "read from disk after a relaunch")
        eq(read?.snapshot.items.first?["title"] as? String, "One", "the same items in the same order")
        eq(read?.age, 100, "with the date it was saved")
        check(relaunched.read("movies-year-All-desc") == nil, "another list is not there")
        // An empty list is never saved, and does not erase the last one.
        store.write(key, items: [])
        eq(store.read(key)?.snapshot.items.count, 2, "an empty list changes nothing")
        // A key with characters a file name should not have.
        let odd = "shows-updated-Science Fiction/!-desc"
        store.write(odd, items: items)
        store.flush()
        eq(snapshotStore().read(odd)?.snapshot.items.count, 2, "an odd key is read back too")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        eq(names.count, 2, "two files")
        check(names.allSatisfy { !$0.contains(" ") && !$0.contains("!") && $0.hasSuffix(".json") }, "with plain names", "\(names)")
        // No folder (no Caches directory): memory only, no crash.
        let memoryOnly = CatalogSnapshotStore(directory: nil, now: { clock.now })
        memoryOnly.write(key, items: items)
        memoryOnly.flush()
        eq(memoryOnly.read(key)?.snapshot.items.count, 2, "without a folder: kept in memory")
    }

    func testOldSnapshotsAreDeleted() {
        let store = snapshotStore()
        for index in 0..<(CatalogSnapshotStore.maxFiles + 6) {
            store.write("movies-trending-genre\(index)-desc", items: [["imdb_id": "tt\(index)"]])
        }
        store.flush()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        eq(names.count, CatalogSnapshotStore.maxFiles, "at most \(CatalogSnapshotStore.maxFiles) lists on disk")
    }

    // MARK: Stale-while-revalidate

    private struct Run {
        var events: [String] = []
        var loads = 0
        var answerNetwork: (([String]?, NSError?) -> Void)?
        /// The same, saying whether the list is partial.
        var answerNetworkPartially: (([String]?, NSError?, Bool) -> Void)?
    }

    /// One load of a list of strings through its snapshot; the network answers when the test says.
    private func load(_ store: CatalogSnapshotStore, _ scheduler: ManualScheduler, withSnapshotHandler: Bool,
                      network: (([String]?, NSError?))? = nil) -> () -> Run {
        var run = Run()
        let freshness = CatalogFreshness(fresh: 600, stale: 6000)
        CatalogSnapshotLoader.load(
            key: "list", freshness: freshness, store: store, schedule: scheduler.schedule,
            encode: { $0.map { ["id": $0] } },
            decode: { $0.compactMap { $0["id"] as? String } },
            load: { done in
                run.loads += 1
                if let network = network { return done(network.0, network.1, false) }
                run.answerNetwork = { items, error in done(items, error, false) }
                run.answerNetworkPartially = done
            },
            snapshot: withSnapshotHandler ? { run.events.append("snapshot \($0.joined())") } : nil,
            completion: { items, error in
                run.events.append("completion \(items?.joined() ?? "nil")\(error == nil ? "" : " error")")
            })
        return { run }
    }

    private func savedList(_ store: CatalogSnapshotStore) -> String {
        return (store.read("list")?.snapshot.items.compactMap { $0["id"] as? String } ?? []).joined()
    }

    func testAFirstLoadGoesToTheNetworkAndIsSaved() {
        let clock = self.clock!
        let store = snapshotStore(), scheduler = ManualScheduler()
        let run = load(store, scheduler, withSnapshotHandler: true)
        eq(run().loads, 1, "the network is asked")
        eq(run().events, [], "nothing to show yet")
        run().answerNetwork?(["a", "b"], nil)
        eq(run().events, ["completion ab"], "the network's list")
        eq(savedList(store), "ab", "saved for the next load")
        // A failure with nothing saved: the error.
        let other = CatalogSnapshotStore(directory: nil, now: { clock.now })
        let failed = load(other, scheduler, withSnapshotHandler: false, network: (nil, NSError(domain: "test", code: 1)))
        eq(failed().events, ["completion nil error"], "nothing saved and a failure: the error")
        // An empty answer is delivered, and not saved.
        let empty = load(other, scheduler, withSnapshotHandler: false, network: ([], nil))
        eq(empty().events, ["completion "], "an empty list is an answer")
        check(other.read("list") == nil, "but it is not saved")
    }

    func testAFreshSnapshotIsTheAnswer() {
        let clock = self.clock!
        let store = snapshotStore(), scheduler = ManualScheduler()
        store.write("list", items: [["id": "a"], ["id": "b"]])
        clock.advance(599)
        let run = load(store, scheduler, withSnapshotHandler: true)
        eq(run().loads, 0, "9 min 59: the network is not asked")
        eq(run().events, [], "delivered on the next turn of the queue")
        scheduler.fire(0)
        eq(run().events, ["completion ab"], "the saved list is the answer (no snapshot call)")
    }

    func testAnExplicitRefreshAsksAFreshListAgain() {
        let clock = self.clock!
        let store = snapshotStore(), scheduler = ManualScheduler()
        store.write("list", items: [["id": "a"], ["id": "b"]])
        clock.advance(60)
        // A pull to refresh: the minute-old list is asked again, and shown meanwhile.
        store.expireAll()
        let refreshed = load(store, scheduler, withSnapshotHandler: true)
        eq(refreshed().loads, 1, "the network is asked")
        scheduler.fire(0)
        eq(refreshed().events, ["snapshot ab"], "the saved list is still shown meanwhile")
        clock.advance(1)
        refreshed().answerNetwork?(["c"], nil)
        eq(refreshed().events, ["snapshot ab", "completion c"], "then the network's")
        // The list just saved is fresh again.
        let next = load(store, scheduler, withSnapshotHandler: true)
        eq(next().loads, 0, "the refreshed list is not asked again")
        scheduler.fire(0)
        eq(next().events, ["completion c"], "it is the answer")
        // A refresh that fails keeps the list.
        clock.advance(1)
        store.expireAll()
        let failed = load(store, scheduler, withSnapshotHandler: false, network: (nil, NSError(domain: "test", code: 1)))
        eq(failed().events, ["completion c"], "a failed refresh: the saved list")
        // A pull to refresh in a grid that shows one list (iOS, the Mac): the network's,
        // however long it takes, never the list being refreshed.
        store.expireAll()
        let slow = load(store, scheduler, withSnapshotHandler: false)
        eq(slow().loads, 1, "the network is asked")
        scheduler.fire(0)
        scheduler.fire(1.5)
        eq(slow().events, [], "nothing is answered while the network is out")
        slow().answerNetwork?(["d"], nil)
        eq(slow().events, ["completion d"], "the refreshed list")
        eq(savedList(store), "d", "which is saved")
    }

    func testAStaleSnapshotIsPaintedThenReplaced() {
        let clock = self.clock!
        let store = snapshotStore(), scheduler = ManualScheduler()
        store.write("list", items: [["id": "a"], ["id": "b"]])
        clock.advance(601)
        let run = load(store, scheduler, withSnapshotHandler: true)
        eq(run().loads, 1, "10 min 01: the network is asked")
        scheduler.fire(0)
        eq(run().events, ["snapshot ab"], "the saved list is handed over at once")
        run().answerNetwork?(["c", "d"], nil)
        eq(run().events, ["snapshot ab", "completion cd"], "then the network's list")
        eq(savedList(store), "cd", "which is saved")
        eq(store.read("list")?.age, 0, "dated now")
    }

    func testTheSnapshotNeverComesAfterTheNetworksList() {
        let clock = self.clock!
        let store = snapshotStore(), scheduler = ManualScheduler()
        store.write("list", items: [["id": "a"]])
        clock.advance(601)
        // The network answers before the queue turns.
        let run = load(store, scheduler, withSnapshotHandler: true, network: (["c"], nil))
        eq(run().events, ["completion c"], "the network's list")
        scheduler.fire(0)
        eq(run().events, ["completion c"], "the older list is not handed over after it")
    }

    func testWithoutASnapshotHandlerTheNetworksListIsWaitedFor() {
        let clock = self.clock!
        let store = snapshotStore(), scheduler = ManualScheduler()
        store.write("list", items: [["id": "a"], ["id": "b"]])
        clock.advance(3000)
        // A slow network: the caller shows one list, the network's.
        let slow = load(store, scheduler, withSnapshotHandler: false)
        eq(slow().loads, 1, "the network is asked")
        scheduler.fire(0)
        scheduler.fire(1.5)
        eq(slow().events, [], "the older list is not answered meanwhile")
        slow().answerNetwork?(["c"], nil)
        eq(slow().events, ["completion c"], "the network's list is the answer")
        eq(savedList(store), "c", "and is saved")
        // The network gives up (its own deadline): the older list.
        clock.advance(3000)
        let down = load(store, scheduler, withSnapshotHandler: false)
        down().answerNetwork?(nil, NSError(domain: "test", code: 1))
        eq(down().events, ["completion c"], "a failure: the saved list")
        eq(savedList(store), "c", "which stays saved")
    }

    func testAPartialListIsShownButNotSaved() {
        let clock = self.clock!
        let store = snapshotStore(), scheduler = ManualScheduler()
        // Nothing saved: the partial list is the answer, and the next load asks again.
        let first = load(store, scheduler, withSnapshotHandler: true)
        first().answerNetworkPartially?(["a"], nil, true)
        eq(first().events, ["completion a"], "a partial list is delivered")
        check(store.read("list") == nil, "but not saved")
        // A complete list saved, then a partial refresh: delivered, the saved list stays.
        store.write("list", items: [["id": "a"], ["id": "b"]])
        clock.advance(1000)
        let refresh = load(store, scheduler, withSnapshotHandler: true)
        scheduler.fire(0)
        refresh().answerNetworkPartially?(["b"], nil, true)
        eq(refresh().events, ["snapshot ab", "completion b"], "the partial refresh is what the network knows now")
        eq(savedList(store), "ab", "the complete list stays saved")
        eq(store.read("list")?.age, 1000, "with its date: the next load asks again")
    }

    func testAFailedRefreshKeepsTheStaleList() {
        let clock = self.clock!
        let store = snapshotStore(), scheduler = ManualScheduler()
        store.write("list", items: [["id": "a"], ["id": "b"]])
        clock.advance(1000)
        let failed = load(store, scheduler, withSnapshotHandler: false, network: (nil, NSError(domain: "test", code: 1)))
        eq(failed().events, ["completion ab"], "a failure: the saved list, no error")
        let empty = load(store, scheduler, withSnapshotHandler: true, network: ([], nil))
        eq(empty().events, ["completion ab"], "an empty answer: the saved list")
        eq(savedList(store), "ab", "the saved list is untouched")
        eq(store.read("list")?.age, 1000, "and keeps its date")
        // Too old to show: the failure is the answer.
        clock.advance(6000)
        let expired = load(store, scheduler, withSnapshotHandler: true, network: (nil, NSError(domain: "test", code: 1)))
        eq(expired().events, ["completion nil error"], "an expired list is not shown")
        scheduler.fire(0)
        eq(expired().events, ["completion nil error"], "nor handed over as a snapshot")
    }

    // MARK: BoundedPump

    func testThePumpRunsAFewJobsAtATime() {
        let lock = NSLock()
        var running = 0, peak = 0, done = 0
        let finished = DispatchSemaphore(value: 0)
        var completions = 0
        BoundedPump.run(Array(0..<15), maxConcurrent: 3, work: { _, finish in
            lock.lock(); running += 1; peak = max(peak, running); lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                lock.lock(); running -= 1; done += 1; lock.unlock()
                finish()
            }
        }, completion: {
            lock.lock(); completions += 1; lock.unlock()
            finished.signal()
        })
        check(finished.wait(timeout: .now() + 10) == .success, "the pump finished")
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock()
        eq(done, 15, "every job ran")
        check(peak > 1 && peak <= 3, "a few at a time, never more than three", "peak \(peak)")
        eq(completions, 1, "one completion")
        lock.unlock()
        // Nothing to do, and jobs that finish at once.
        let empty = DispatchSemaphore(value: 0)
        BoundedPump.run([Int](), maxConcurrent: 3, work: { _, finish in finish() }, completion: { empty.signal() })
        check(empty.wait(timeout: .now() + 5) == .success, "no job: the completion still runs")
        let immediate = DispatchSemaphore(value: 0)
        BoundedPump.run(Array(0..<200), maxConcurrent: 4, work: { _, finish in finish() }, completion: { immediate.signal() })
        check(immediate.wait(timeout: .now() + 10) == .success, "200 jobs finishing at once")
    }

    // MARK: The show directory

    private func directory(_ lookups: Lookups, file: String = "shows.json", prefill: Bool = false) -> TVMazeShowDirectory {
        let clock = self.clock!
        return TVMazeShowDirectory(fileURL: folder.appendingPathComponent(file), now: { clock.now },
                                   fetch: lookups.fetch, prefill: prefill ? lookups.prefill : nil)
    }

    private func resolve(_ directory: TVMazeShowDirectory, _ imdbIds: [String], deadline: TimeInterval = 5) -> [String: [String: Any]] {
        let done = DispatchSemaphore(value: 0)
        var records: [String: [String: Any]] = [:]
        directory.resolve(imdbIds, deadline: deadline) { records = $0; done.signal() }
        check(done.wait(timeout: .now() + 15) == .success, "the directory answered")
        return records
    }

    func testLookupsAreBoundedAndKeptOnDisk() {
        let lookups = Lookups()
        let directory = self.directory(lookups)
        let page = ids(1...20)
        let records = resolve(directory, page)
        eq(records.count, 20, "20 shows resolved")
        eq(Set(lookups.asked), Set(page), "one lookup a show")
        eq(lookups.asked.count, 20, "20 lookups")
        check(lookups.peak > 1 && lookups.peak <= TVMazeShowDirectory.maxConcurrent, "a few at a time", "peak \(lookups.peak)")
        eq(records["tt0000007"]?["name"] as? String, "Show tt0000007", "the record of a show")
        check(records.values.allSatisfy { $0["_links"] == nil }, "records are trimmed")
        // The same page again (the next page of the grid, a show's own page): no lookup.
        eq(resolve(directory, page).count, 20, "resolved again")
        eq(lookups.asked.count, 20, "without a lookup")
        // A relaunch: read from disk.
        directory.flush()
        let relaunched = Lookups()
        eq(resolve(self.directory(relaunched), page + ["tt0000021"]).count, 21, "resolved after a relaunch")
        eq(relaunched.asked, ["tt0000021"], "only the new show is looked up")
        // Nothing asked: an answer all the same.
        eq(resolve(directory, []).count, 0, "no id")
    }

    func testTwoLoadsShareALookup() {
        let lookups = Lookups()
        let directory = self.directory(lookups)
        let page = ids(1...12)
        // A grid page and a show's own page ask at the same moment.
        let done = DispatchSemaphore(value: 0)
        var first: [String: [String: Any]] = [:], second: [String: [String: Any]] = [:]
        directory.resolve(page) { first = $0; done.signal() }
        directory.resolve(Array(page.prefix(4)) + ["tt0000013"]) { second = $0; done.signal() }
        check(done.wait(timeout: .now() + 15) == .success && done.wait(timeout: .now() + 15) == .success, "both answered")
        eq(first.count, 12, "the page is resolved")
        eq(second.count, 5, "so is the other load")
        eq(lookups.asked.count, 13, "13 shows, 13 lookups: none asked twice")
        eq(Set(lookups.asked).count, 13, "each show once")
    }

    func testUnknownAndFailedLookups() {
        let lookups = Lookups()
        lookups.answers["tt0000001"] = .unknown
        lookups.answers["tt0000002"] = .failed
        let directory = self.directory(lookups)
        let page = ids(1...3)
        eq(Set(resolve(directory, page).keys), ["tt0000003"], "only the known show is resolved")
        eq(lookups.asked.count, 3, "three lookups")
        // Unknown is remembered, a failure is not.
        _ = resolve(directory, page)
        eq(lookups.asked.count, 4, "one more lookup")
        eq(lookups.asked.last, "tt0000002", "the one that failed")
        // A day later the unknown show is asked again (TVMaze may have added it).
        clock.advance(TVMazeShowDirectory.unknownLifetime + 60)
        lookups.answers["tt0000002"] = nil
        eq(Set(resolve(directory, page).keys), ["tt0000002", "tt0000003"], "the failed one resolves now")
        eq(Set(lookups.asked.suffix(2)), ["tt0000001", "tt0000002"], "the unknown and the failed are asked again")
        eq(lookups.asked.count, 6, "the known one is not")
        // A week later the known shows are asked again.
        clock.advance(TVMazeShowDirectory.knownLifetime)
        _ = resolve(directory, ["tt0000003"])
        eq(lookups.asked.last, "tt0000003", "a record older than a week is asked again")

        // A series TVMaze does not know yet, named from Cinemeta: kept a day, not a week
        // (TVMaze gains it within days, with its episode guide).
        let standIn = TVMazeShowDirectory.record(fromCinemeta: ["id": "tt0000050", "name": "The Crow Club", "releaseInfo": "2026–"]) ?? [:]
        lookups.answers["tt0000050"] = .show(standIn)
        eq(resolve(directory, ["tt0000050"])["tt0000050"]?["name"] as? String, "The Crow Club", "listed from Cinemeta's record")
        let asked = lookups.asked.count
        clock.advance(TVMazeShowDirectory.unknownLifetime - 60)
        eq(resolve(directory, ["tt0000050"]).count, 1, "still known within the day")
        eq(lookups.asked.count, asked, "without a lookup")
        clock.advance(120)
        lookups.answers["tt0000050"] = nil
        let later = resolve(directory, ["tt0000050"])["tt0000050"]
        eq(lookups.asked.last, "tt0000050", "a day later TVMaze is asked again")
        check(later?["id"] is Int && later?["source"] == nil, "and its own record takes the stand-in's place")

        // One show at a time (a show's page).
        func record(_ id: String) -> TVMazeShowDirectory.Lookup {
            let done = DispatchSemaphore(value: 0)
            var lookup = TVMazeShowDirectory.Lookup.missing
            directory.record(id) { lookup = $0; done.signal() }
            check(done.wait(timeout: .now() + 10) == .success, "the directory answered")
            return lookup
        }
        if case .known(let show) = record("tt0000003") { eq(show["name"] as? String, "Show tt0000003", "a known show") } else { XCTFail("tt0000003 should be known") }
        if case .unknown = record("tt0000001") {} else { XCTFail("tt0000001 should be unknown") }
        lookups.answers["tt0000009"] = .failed
        if case .missing = record("tt0000009") {} else { XCTFail("a failed lookup is missing, not unknown") }
        check(true, "the three states of one show")
    }

    func testTheScheduleSparesLookups() {
        let web = TVMazeShowDirectory.shows(fromSchedule: Fixtures.data("Catalog/tvmaze_schedule_web.json"))
        let us = TVMazeShowDirectory.shows(fromSchedule: Fixtures.data("Catalog/tvmaze_schedule_us.json"))
        eq(web.count, 12, "12 episodes of streaming services")
        eq(us.count, 12, "12 episodes of US television")
        check((web + us).allSatisfy { $0["name"] is String }, "each with its show")
        eq(TVMazeShowDirectory.shows(fromSchedule: Data("<html></html>".utf8)).count, 0, "not a schedule")
        let scheduled = Array(Set((web + us).compactMap { ($0["externals"] as? [String: Any])?["imdb"] as? String })).sorted()
        eq(scheduled.count, 19, "19 shows with an IMDb id")

        let lookups = Lookups()
        lookups.schedule = web + us
        let directory = self.directory(lookups, prefill: true)
        // A cold first page: 10 shows of the schedule and 5 others.
        let others = ids(900...904)
        let page = Array(scheduled.prefix(10)) + others
        let records = resolve(directory, page)
        eq(records.count, 15, "15 shows resolved")
        eq(lookups.prefillCount, 1, "the schedule was read once")
        eq(Set(lookups.asked), Set(others), "only the shows the schedule does not name are looked up")
        eq(records["tt16358384"]?["name"] as? String, "Tulsa King", "a record from the schedule")
        check(Show(tvmaze: records["tt16358384"] ?? [:], imdbId: "tt16358384")?.largeCoverImage != nil, "with its poster")
        // The other shows of the schedule are known too.
        eq(resolve(directory, scheduled).count, 19, "the whole schedule is in the directory")
        eq(lookups.asked.count, 5, "without a lookup")
        // A few missing shows: no schedule read.
        _ = resolve(directory, ids(910...912))
        eq(lookups.prefillCount, 1, "3 missing shows: the schedule is not read")
        eq(lookups.asked.count, 8, "they are looked up")
        // Many again within ten minutes: not read again.
        _ = resolve(directory, ids(920...929))
        eq(lookups.prefillCount, 1, "the schedule is not read twice in ten minutes")
        clock.advance(601)
        _ = resolve(directory, ids(930...939))
        eq(lookups.prefillCount, 2, "ten minutes later it is")
    }

    func testTheDirectoryAnswersAtItsDeadline() {
        let lookups = Lookups()
        lookups.mute = ["tt0000002"]
        let directory = self.directory(lookups)
        let started = Date()
        let records = resolve(directory, ids(1...3), deadline: 0.3)
        let elapsed = Date().timeIntervalSince(started)
        eq(Set(records.keys), ["tt0000001", "tt0000003"], "the shows that answered")
        check(elapsed >= 0.25 && elapsed < 5, "at the deadline", "\(elapsed) s")
        // The directory says which shows it could not name in time: such a list is not complete.
        lookups.answers["tt0000004"] = .unknown
        lookups.answers["tt0000005"] = .failed
        let done = DispatchSemaphore(value: 0)
        var resolution: TVMazeShowDirectory.Resolution?
        directory.resolution(of: ids(1...5), deadline: 0.2) { resolution = $0; done.signal() }
        check(done.wait(timeout: .now() + 10) == .success, "the directory answered")
        eq(Set(resolution?.records.keys.map { $0 } ?? []), ["tt0000001", "tt0000003"], "the known shows")
        eq(resolution?.unanswered ?? [], ["tt0000002", "tt0000005"], "the lookup still out and the one that failed are not answered")
        // No time at all: what the directory knows already.
        let atOnce = DispatchSemaphore(value: 0)
        directory.resolution(of: ["tt0000001", "tt0000006"], deadline: 0) { resolution = $0; atOnce.signal() }
        check(atOnce.wait(timeout: .now() + 10) == .success, "the directory answered")
        eq(resolution?.records.keys.sorted() ?? [], ["tt0000001"], "the show it knew")
        eq(resolution?.unanswered ?? [], ["tt0000006"], "the other is not in yet")
        directory.flush()
        // The shows that answered are kept; the lookup that never answered is still
        // waited for a moment, not doubled…
        lookups.mute = []
        eq(resolve(directory, ids(1...3), deadline: 0.2).count, 2, "a moment later the third is still out")
        eq(lookups.asked.filter { $0 == "tt0000002" }.count, 1, "its lookup is not started twice")
        // …then given up on, and the show is asked again.
        clock.advance(TVMazeShowDirectory.lookupPatience + 1)
        eq(resolve(directory, ids(1...3)).count, 3, "later the third is asked again and resolves")
        eq(lookups.asked.filter { $0 == "tt0000002" }.count, 2, "one more lookup of the third")
        eq(lookups.asked.filter { $0 == "tt0000001" }.count, 1, "without asking the first again")
    }

    func testRecordsMakeShows() {
        let full = (try? JSONSerialization.jsonObject(with: Fixtures.data("Sources/tvm_lookup_tt31510819.json"))) as? [String: Any] ?? [:]
        let trimmed = TVMazeShowDirectory.trimmed(full)
        check(JSONSerialization.isValidJSONObject(trimmed), "a record is JSON")
        let a = Show(tvmaze: full, imdbId: "tt31510819"), b = Show(tvmaze: trimmed, imdbId: "tt31510819")
        eq(b?.title, "MobLand", "the title")
        eq(b?.title, a?.title, "as the full object's")
        eq(b?.year, a?.year, "the year")
        eq(b?.network, a?.network, "the network")
        eq(b?.status, a?.status, "the status")
        eq(b?.largeCoverImage, a?.largeCoverImage, "the poster")
        eq(trimmed["id"] as? Int, full["id"] as? Int, "the TVMaze id")
        // A schedule's show object, with a streaming service and nulls.
        let scheduled = TVMazeShowDirectory.shows(fromSchedule: Fixtures.data("Catalog/tvmaze_schedule_web.json"))
        guard let tulsa = scheduled.first(where: { $0["name"] as? String == "Tulsa King" }) else { return XCTFail("no Tulsa King") }
        let record = TVMazeShowDirectory.trimmed(tulsa)
        check(JSONSerialization.isValidJSONObject(record), "a schedule's record is JSON")
        check(record.values.allSatisfy { !($0 is NSNull) }, "without nulls")
        eq((record["webChannel"] as? [String: Any])?.keys.sorted(), ["name"], "the streaming service's name only")
        eq(Show(tvmaze: record, imdbId: "tt16358384")?.title, "Tulsa King", "it makes the show")

        // A series TVMaze does not know, from Cinemeta's meta.
        let meta = (CinemetaClient.catalogMetas(fromJSON: Fixtures.data("Catalog/cm_series_top.json")) ?? []).first ?? [:]
        guard let fromCinemeta = TVMazeShowDirectory.record(fromCinemeta: meta) else { return XCTFail("no record") }
        eq(fromCinemeta["id"] == nil, true, "no TVMaze id")
        eq(fromCinemeta["source"] as? String, "cinemeta", "marked as Cinemeta's")
        let show = Show(tvmaze: fromCinemeta, imdbId: "tt31510819")
        eq(show?.title, "MobLand", "the title")
        eq(show?.year, "2025", "the year")
        eq(show?.rating, 83, "the rating")
        eq(show?.genres ?? [], ["Crime", "Drama"], "the genres")
        eq(show?.largeCoverImage, "https://images.metahub.space/poster/medium/tt31510819/img", "the poster")
        eq(TVMazeShowDirectory.record(fromCinemeta: [:]) == nil, true, "an empty meta: no record")
        eq(TVMazeShowDirectory.record(fromCinemeta: ["id": "tt1", "name": ""]) == nil, true, "no name: no record")
    }

    func testAlternateTitlesStayWithTheirShow() {
        let lookups = Lookups()
        let directory = self.directory(lookups)
        func akas(_ id: String) -> [String]? {
            let done = DispatchSemaphore(value: 0)
            var titles: [String]?
            directory.akas(id) { titles = $0; done.signal() }
            check(done.wait(timeout: .now() + 10) == .success, "the directory answered")
            return titles
        }
        eq(akas("tt0000001"), nil, "nothing stored")
        directory.storeAkas("tt0000001", ["Ignored"])
        eq(akas("tt0000001"), nil, "a show without a record keeps no titles")
        _ = resolve(directory, ["tt0000001"])
        directory.storeAkas("tt0000001", ["The Doll", "Lalka"])
        eq(akas("tt0000001"), ["The Doll", "Lalka"], "stored with the record")
        eq(akas("tt0000002"), nil, "another show has none")
        directory.storeAkas("tt0000001", [])
        eq(akas("tt0000001"), [], "\"none\" is an answer too")
        directory.storeAkas("tt0000001", ["The Doll"])
        // After a relaunch.
        directory.save()
        directory.flush()
        let relaunched = self.directory(Lookups())
        let done = DispatchSemaphore(value: 0)
        var kept: [String]?
        relaunched.akas("tt0000001") { kept = $0; done.signal() }
        check(done.wait(timeout: .now() + 10) == .success, "the directory answered")
        eq(kept, ["The Doll"], "kept on disk")
        // The record refreshed a week later keeps them (the same TVMaze show)…
        clock.advance(TVMazeShowDirectory.knownLifetime + 60)
        _ = resolve(directory, ["tt0000001"])
        eq(lookups.asked.count, 2, "the record was asked again")
        eq(akas("tt0000001"), ["The Doll"], "the titles stay with the refreshed record")
        // …until they are a month old.
        clock.advance(TVMazeShowDirectory.akasLifetime)
        eq(akas("tt0000001"), nil, "a month later they are asked again")
    }
}
