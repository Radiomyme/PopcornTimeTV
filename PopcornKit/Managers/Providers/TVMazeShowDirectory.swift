import Foundation

/// Runs a batch of asynchronous jobs at most `maxConcurrent` at a time, in
/// order, and calls back once when all are done. (The Shows grid used to
/// start one TVMaze lookup per show of a page, all at once.)
enum BoundedPump {

    /// `work(input, done)`: `done` must be called exactly once, on any queue.
    /// `completion` runs on an arbitrary queue.
    static func run<Input>(_ inputs: [Input], maxConcurrent: Int,
                           work: @escaping (Input, @escaping () -> Void) -> Void,
                           completion: @escaping () -> Void) {
        guard !inputs.isEmpty else { return completion() }
        let lock = NSLock()
        var next = 0
        var running = 0
        var finished = false

        func pump() {
            // Called with the lock held.
            if next >= inputs.count, running == 0, !finished {
                finished = true
                DispatchQueue.global(qos: .userInitiated).async(execute: completion)
                return
            }
            while running < max(1, maxConcurrent), next < inputs.count {
                let input = inputs[next]
                next += 1
                running += 1
                // Started off the lock: a job may finish at once.
                DispatchQueue.global(qos: .userInitiated).async {
                    work(input) {
                        lock.lock()
                        running -= 1
                        pump()
                        lock.unlock()
                    }
                }
            }
        }
        lock.lock()
        pump()
        lock.unlock()
    }
}

/// IMDb id → show record, for the shows EZTV's latest releases name (EZTV
/// gives an IMDb id and a release name, nothing to draw a poster with).
///
/// A record is TVMaze's show object, trimmed to what `Show(tvmaze:imdbId:)`
/// and the alternate-titles lookup read (about 1.5 KB); for a series TVMaze
/// does not know it is built from Cinemeta's meta in the same shape, without
/// an `id` (no TVMaze episode guide: `getShowInfo` uses Cinemeta's).
///
/// - Kept in memory and in one JSON file in `Caches` (`knownLifetime`; "no
///   source knows this id" and a record built from Cinemeta only
///   `unknownLifetime`: TVMaze is asked again the next day; alternate titles
///   with their show): the second page of the grid, the next launch and the
///   show's own page ask nothing again.
/// - Missing records are looked up `maxConcurrent` at a time, after one
///   look at TVMaze's schedule of today and yesterday when many are missing
///   (each schedule answer carries the full record of every show airing
///   that day).
/// - `resolve` answers at its deadline with what is known by then (and
///   `resolution` says which ids are still out); the lookups still running
///   fill the directory for the next load.
///
/// Fetching, the clock and the file are injected (tests).
final class TVMazeShowDirectory {

    static let shared = TVMazeShowDirectory(
        fileURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("popcornkit-tvmaze-shows.json"))

    static var knownLifetime: TimeInterval = 7 * 24 * 3600
    /// "No source knows this id", and a record built from Cinemeta because
    /// TVMaze did not know the series: TVMaze gains a new series within
    /// days, and its record brings the episode guide and the alternate
    /// titles.
    static var unknownLifetime: TimeInterval = 24 * 3600
    /// Alternate titles hardly ever change.
    static var akasLifetime: TimeInterval = 30 * 24 * 3600
    /// Most records kept (about 2 MB of JSON).
    static var capacity = 1500
    static var maxConcurrent = 6
    /// Longest wait of `resolve`.
    static var deadline: TimeInterval = 6
    /// Missing records from which the schedule is read first.
    static var prefillThreshold = 8

    /// What the directory knows of an IMDb id.
    enum Lookup {
        case known([String: Any])
        /// Neither TVMaze nor Cinemeta has it (asked recently).
        case unknown
        /// Not asked yet, asked too long ago, or the request failed.
        case missing
    }

    /// What one lookup came to.
    enum Outcome {
        case show([String: Any])
        case unknown
        case failed
    }

    typealias Fetch = (_ imdbId: String, _ completion: @escaping (Outcome) -> Void) -> Void
    /// Full show records to absorb (TVMaze's schedule), [] on failure.
    typealias Prefill = (_ completion: @escaping ([[String: Any]]) -> Void) -> Void

    private let fileURL: URL?
    private let now: () -> Date
    private let fetch: Fetch
    private let prefill: Prefill?
    private let queue = DispatchQueue(label: "com.popcorntimetv.popcornkit.tvmaze.directory", qos: .userInitiated)
    /// imdb id → ["t": seconds, "show": record?, "akas": [String]?, "akasT": seconds?]. `queue` only.
    private var entries: [String: [String: Any]] = [:]
    private var loaded = false
    private var dirty = false
    private var prefilledAt: Date?
    /// Lookups under way, with who waits for each: two loads that miss the
    /// same show (a grid page and the show's own page) share one request.
    private var inFlight: [String: (started: Date, waiting: [() -> Void])] = [:]
    /// A lookup older than this is given up on: the show is asked again.
    static var lookupPatience: TimeInterval = 15

    init(fileURL: URL?, now: @escaping () -> Date = Date.init,
         fetch: @escaping Fetch = TVMazeShowDirectory.liveFetch,
         prefill: Prefill? = TVMazeShowDirectory.liveSchedule) {
        self.fileURL = fileURL
        self.now = now
        self.fetch = fetch
        self.prefill = prefill
    }

    // MARK: Reading

    /// What the directory can say of a list of ids when it answers.
    struct Resolution {
        /// The records of the ids that are known, by id.
        let records: [String: [String: Any]]
        /// The ids no answer came for (a lookup that failed, or is still
        /// running at the deadline): not known, and not unknown either.
        let unanswered: [String]
    }

    /// The records of `imdbIds` (those known, by id), looking up the missing
    /// ones first. Calls back once, on a background queue, at the latest
    /// after `deadline` seconds.
    func resolve(_ imdbIds: [String], deadline: TimeInterval = TVMazeShowDirectory.deadline,
                 completion: @escaping (_ records: [String: [String: Any]]) -> Void) {
        resolution(of: imdbIds, deadline: deadline) { completion($0.records) }
    }

    /// `resolve`, also saying which ids no answer came for.
    func resolution(of imdbIds: [String], deadline: TimeInterval = TVMazeShowDirectory.deadline,
                    completion: @escaping (Resolution) -> Void) {
        queue.async { [self] in
            loadIfNeeded()
            var answered = false
            let answer: () -> Void = { [self] in
                // `queue` only.
                guard !answered else { return }
                answered = true
                var records: [String: [String: Any]] = [:]
                var unanswered: [String] = []
                for id in imdbIds {
                    switch lookupLocked(id) {
                    case .known(let record): records[id] = record
                    case .missing: unanswered.append(id)
                    case .unknown: break
                    }
                }
                let resolution = Resolution(records: records, unanswered: unanswered)
                DispatchQueue.global(qos: .userInitiated).async { completion(resolution) }
            }
            let missing = imdbIds.filter { if case .missing = lookupLocked($0) { return true } else { return false } }
            guard !missing.isEmpty else { return answer() }
            queue.asyncAfter(deadline: .now() + deadline) {
                if !answered { print("[TVMaze] directory: deadline, answering with what is known") }
                answer()
            }
            let lookUp: ([String]) -> Void = { [self] ids in
                BoundedPump.run(ids, maxConcurrent: TVMazeShowDirectory.maxConcurrent, work: { [self] id, done in
                    lookUpOnce(id, done: done)
                }, completion: { [self] in
                    queue.async { [self] in
                        saveLocked()
                        answer()
                    }
                })
            }
            // Many unknown shows (a first launch): the schedule of today and
            // yesterday names a good part of them in a few requests. At most
            // once every ten minutes.
            let recentlyPrefilled = prefilledAt.map { now().timeIntervalSince($0) < 600 } ?? false
            if missing.count >= TVMazeShowDirectory.prefillThreshold, !recentlyPrefilled, let prefill = prefill {
                prefilledAt = now()
                prefill { [self] shows in
                    queue.async { [self] in
                        let absorbed = absorbLocked(shows)
                        let still = missing.filter { if case .missing = lookupLocked($0) { return true } else { return false } }
                        print("[TVMaze] directory: schedule gave \(absorbed) shows, \(missing.count - still.count)/\(missing.count) of the missing ones")
                        lookUp(still)
                    }
                }
            } else {
                lookUp(missing)
            }
        }
    }

    /// Looks `imdbId` up and stores the answer, unless a lookup of it is
    /// under way already: then `done` runs when that one ends. Any queue.
    private func lookUpOnce(_ imdbId: String, done: @escaping () -> Void) {
        queue.async { [self] in
            var waiting = [done]
            if let running = inFlight[imdbId] {
                if now().timeIntervalSince(running.started) < TVMazeShowDirectory.lookupPatience {
                    inFlight[imdbId]?.waiting.append(done)
                    return
                }
                // It never answered: asked again, for those who waited too.
                waiting += running.waiting
            }
            inFlight[imdbId] = (now(), waiting)
            fetch(imdbId) { [self] outcome in
                queue.async { [self] in
                    switch outcome {
                    case .show(let show): storeLocked(imdbId, show: show)
                    case .unknown: storeLocked(imdbId, show: nil)
                    case .failed: break
                    }
                    let waiting = inFlight.removeValue(forKey: imdbId)?.waiting ?? []
                    waiting.forEach { $0() }
                }
            }
        }
    }

    /// What is known of one show, looking it up when missing (`.missing`
    /// then means the request failed). Background queue.
    func record(_ imdbId: String, completion: @escaping (Lookup) -> Void) {
        resolve([imdbId]) { [self] _ in
            queue.async { [self] in
                let lookup = lookupLocked(imdbId)
                DispatchQueue.global(qos: .userInitiated).async { completion(lookup) }
            }
        }
    }

    /// The alternate titles stored with a show, nil when none were stored
    /// (or too long ago).
    func akas(_ imdbId: String, completion: @escaping ([String]?) -> Void) {
        queue.async { [self] in
            loadIfNeeded()
            guard let entry = entries[imdbId], let stored = entry["akasT"] as? Double,
                  now().timeIntervalSince1970 - stored < TVMazeShowDirectory.akasLifetime else { return completion(nil) }
            completion(entry["akas"] as? [String])
        }
    }

    /// Keeps a show's alternate titles with its record (a show without a
    /// record has nowhere to keep them).
    func storeAkas(_ imdbId: String, _ akas: [String]) {
        queue.async { [self] in
            loadIfNeeded()
            guard var entry = entries[imdbId], entry["show"] != nil else { return }
            entry["akas"] = akas
            entry["akasT"] = now().timeIntervalSince1970
            entries[imdbId] = entry
            dirty = true
        }
    }

    /// Writes the directory to its file when it changed.
    func save() {
        queue.async { [self] in saveLocked() }
    }

    /// Blocks until everything queued so far is done (tests).
    func flush() {
        queue.sync {}
    }

    // MARK: State (`queue` only)

    private func lookupLocked(_ imdbId: String) -> Lookup {
        guard let entry = entries[imdbId], let stored = entry["t"] as? Double else { return .missing }
        let age = now().timeIntervalSince1970 - stored
        if let show = entry["show"] as? [String: Any] {
            let standIn = show["source"] as? String == TVMazeShowDirectory.cinemetaSource
            return age < (standIn ? TVMazeShowDirectory.unknownLifetime : TVMazeShowDirectory.knownLifetime) ? .known(show) : .missing
        }
        return age < TVMazeShowDirectory.unknownLifetime ? .unknown : .missing
    }

    private func storeLocked(_ imdbId: String, show: [String: Any]?) {
        var entry: [String: Any] = ["t": now().timeIntervalSince1970]
        if let show = show {
            entry["show"] = TVMazeShowDirectory.trimmed(show)
            // Its type and language, for « Vos langues » (the app's directory only).
            if self === TVMazeShowDirectory.shared { TitleOriginStore.shared.note(TitleOrigin(tvmaze: show), for: imdbId) }
            // The alternate titles of the same TVMaze show stay valid.
            if let known = entries[imdbId], let akas = known["akas"], let stored = known["akasT"],
               (known["show"] as? [String: Any])?["id"] as? Int == show["id"] as? Int {
                entry["akas"] = akas
                entry["akasT"] = stored
            }
        }
        entries[imdbId] = entry
        dirty = true
    }

    /// Stores the shows of schedule answers that carry an IMDb id; how many.
    private func absorbLocked(_ shows: [[String: Any]]) -> Int {
        var count = 0
        for show in shows {
            guard let imdb = (show["externals"] as? [String: Any])?["imdb"] as? String, imdb.hasPrefix("tt"),
                  show["name"] is String else { continue }
            storeLocked(imdb, show: show)
            count += 1
        }
        return count
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let shows = root["shows"] as? [String: [String: Any]] else { return }
        entries = shows
    }

    private func saveLocked() {
        guard dirty, let url = fileURL else { return }
        dirty = false
        if entries.count > TVMazeShowDirectory.capacity {
            let oldestFirst = entries.sorted { ($0.value["t"] as? Double ?? 0) < ($1.value["t"] as? Double ?? 0) }
            for (key, _) in oldestFirst.prefix(entries.count - TVMazeShowDirectory.capacity) { entries[key] = nil }
        }
        let root: [String: Any] = ["version": 1, "shows": entries]
        guard JSONSerialization.isValidJSONObject(root), let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Records

    /// The fields of a TVMaze show object that are read.
    private static let keptFields: Set<String> = [
        "id", "name", "type", "language", "genres", "status", "runtime", "averageRuntime", "premiered",
        "schedule", "rating", "weight", "network", "webChannel", "externals", "image", "summary", "source",
        "country",   // a record built from Cinemeta (`record(fromCinemeta:)`)
    ]

    static func trimmed(_ show: [String: Any]) -> [String: Any] {
        var record = show.filter { keptFields.contains($0.key) && !($0.value is NSNull) }
        // Only the names of the network and the streaming service are read.
        for key in ["network", "webChannel"] {
            if let name = (record[key] as? [String: Any])?["name"] as? String { record[key] = ["name": name] } else { record[key] = nil }
        }
        return record
    }

    /// The `source` of a record built from Cinemeta's meta.
    static let cinemetaSource = "cinemeta"

    /// A Cinemeta series meta in the shape of a TVMaze show object (no `id`).
    static func record(fromCinemeta meta: [String: Any]) -> [String: Any]? {
        guard let name = meta["name"] as? String, !name.isEmpty,
              let imdb = (meta["imdb_id"] as? String) ?? (meta["id"] as? String), imdb.hasPrefix("tt") else { return nil }
        var record: [String: Any] = ["name": name, "source": cinemetaSource, "externals": ["imdb": imdb]]
        let released = (meta["released"] as? String).map { String($0.prefix(10)) }
        if let premiered = released ?? (meta["releaseInfo"] as? String).map({ String($0.prefix(4)) }), !premiered.isEmpty {
            record["premiered"] = premiered
        }
        if let rating = Double((meta["imdbRating"] as? String) ?? "") { record["rating"] = ["average": rating] }
        if let description = meta["description"] as? String { record["summary"] = description }
        if let genres = (meta["genres"] as? [String]) ?? (meta["genre"] as? [String]) { record["genres"] = genres }
        // The first country tells a Japanese series (« Vos langues »).
        if let country = meta["country"] as? String, !country.isEmpty { record["country"] = country }
        if let status = meta["status"] as? String { record["status"] = status }
        if let poster = meta["poster"] as? String { record["image"] = ["original": OpenMetadata.largerPoster(poster)] }
        return record
    }

    /// The show objects of TVMaze schedule answers: `show` in `/schedule`,
    /// `_embedded.show` in `/schedule/web`.
    static func shows(fromSchedule data: Data) -> [[String: Any]] {
        guard let episodes = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return episodes.compactMap { episode in
            (episode["show"] as? [String: Any]) ?? ((episode["_embedded"] as? [String: Any])?["show"] as? [String: Any])
        }
    }

    // MARK: Live requests

    static let tvmazeHosts = ["https://api.tvmaze.com"]
    /// One session for the grid's lookups (answers are kept in the directory,
    /// not in the fetcher).
    static let tvmaze = IndexFetcher(name: "TVMaze", timeout: 6, cacheLifetime: 0, backoff: 60)

    /// TVMaze's record of an IMDb id; a series TVMaze does not know, from
    /// Cinemeta. TVMaze asks clients to stay under 20 calls per 10 s: a 429
    /// is asked once more a moment later.
    static let liveFetch: Fetch = { imdbId, completion in
        func lookUp(retry: Bool) {
            // Answers with a 301 to /shows/{id}, which URLSession follows.
            tvmaze.fetch(hosts: tvmazeHosts, path: "/lookup/shows?imdb=\(imdbId)") { outcome in
                switch outcome {
                case .data(let data):
                    guard let show = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], show["name"] is String else {
                        return completion(.failed)
                    }
                    completion(.show(show))
                case .status(let status) where status == 404:
                    CinemetaClient.metaAnswer(.series, imdbId: imdbId) { answer in
                        guard let meta = answer else { return completion(.failed) }
                        completion(record(fromCinemeta: meta).map { .show($0) } ?? .unknown)
                    }
                case .status(let status) where status == 429 && retry:
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) { lookUp(retry: false) }
                case .status, .failed:
                    completion(.failed)
                }
            }
        }
        lookUp(retry: true)
    }

    /// The shows airing today and yesterday (UTC), on the streaming services
    /// and on US television: four requests, each with the full record of
    /// every show of the day.
    static let liveSchedule: Prefill = { completion in
        let today = Date()
        let days = [today, today.addingTimeInterval(-24 * 3600)].map(CatalogDates.dayString)
        let paths = days.flatMap { ["/schedule/web?date=\($0)", "/schedule?country=US&date=\($0)"] }
        let group = DispatchGroup()
        let lock = NSLock()
        var shows: [[String: Any]] = []
        for path in paths {
            group.enter()
            tvmaze.data(hosts: tvmazeHosts, path: path) { data in
                let found = data.map(TVMazeShowDirectory.shows(fromSchedule:)) ?? []
                lock.lock()
                shows += found
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { completion(shows) }
    }
}
