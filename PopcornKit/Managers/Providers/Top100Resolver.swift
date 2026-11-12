import Foundation

/// Resolves ranked top-100 groups (`Top100Ranking`) to Cinemeta metas:
///
/// 1. the index's IMDb ids for the group (most frequent first, two at most),
///    each kept only when its meta passes `CinemetaMatching` (TPB files some
///    releases under a wrong or stub id: the YIFY "Interstellar" under
///    tt4288316);
/// 2. else a Cinemeta search of the title the releases read, kept only for
///    an exact title (+ year) match, then its full meta (genres);
/// 3. else nothing: the group is left out.
///
/// Groups resolve in rank order with bounded concurrency; once `limit`
/// distinct titles are certain the rest is skipped, and at the deadline the
/// titles resolved so far are delivered (later answers still fill the cache
/// for the next load). Titles several groups resolve to are merged (their
/// seeders summed), a group that failed validation adds its seeders to the
/// title its TPB id names when that title is already listed (it never adds
/// a title), and the result is ranked by seeders again. A movie keeps the
/// year its releases name when Cinemeta's full record is a year off ("Amélie"
/// 2001, not 2002). A group whose Cinemeta calls failed (timeout, backoff) is
/// not remembered as unresolvable, and the result says it is incomplete.
/// Fetching is injected, so the logic runs against recorded answers in tests.
final class Top100Resolver {

    /// The meta of an id (nil: not there), `answered` false when Cinemeta
    /// could not be reached.
    typealias MetaFetch = (_ kind: CinemetaClient.Kind, _ imdbId: String,
                           _ completion: @escaping (_ meta: [String: Any]?, _ answered: Bool) -> Void) -> Void
    /// Search results, `answered` false when Cinemeta could not be reached.
    typealias SearchFetch = (_ kind: CinemetaClient.Kind, _ query: String,
                             _ completion: @escaping (_ metas: [[String: Any]], _ answered: Bool) -> Void) -> Void

    struct Resolved {
        let meta: [String: Any]
        let seeders: Int
        /// The groups (`Top100Group.key`) that resolved to it.
        let keys: [String]
    }

    let kind: CinemetaClient.Kind
    private let fetchMeta: MetaFetch
    private let search: SearchFetch
    private let maxConcurrent: Int

    /// Group key → resolved meta ([:] when unresolvable), shared by loads.
    /// Only what Cinemeta actually answered is remembered.
    private static let resolutions = TTLCache<[String: Any]>(lifetime: 6 * 3600)

    static let liveMeta: MetaFetch = { kind, imdbId, completion in
        CinemetaClient.metaAnswer(kind, imdbId: imdbId) { answer in
            completion(answer.flatMap { $0.isEmpty ? nil : $0 }, answer != nil)
        }
    }

    static let liveSearch: SearchFetch = { kind, query, completion in
        CinemetaClient.searchAnswer(kind, query: query) { answer in
            completion(answer ?? [], answer != nil)
        }
    }

    init(kind: CinemetaClient.Kind, maxConcurrent: Int = 8,
         fetchMeta: @escaping MetaFetch = Top100Resolver.liveMeta,
         search: @escaping SearchFetch = Top100Resolver.liveSearch) {
        self.kind = kind
        self.maxConcurrent = maxConcurrent
        self.fetchMeta = fetchMeta
        self.search = search
    }

    /// The metas of `groups`, ranked, at most `limit`; `complete` false when
    /// the deadline hit or a Cinemeta call failed (the list may miss titles).
    /// Calls back once, on an arbitrary queue.
    func resolve(_ groups: [Top100Group], limit: Int, deadline: TimeInterval,
                 completion: @escaping (_ resolved: [Resolved], _ complete: Bool) -> Void) {
        let lock = NSLock()
        var results = [[String: Any]?](repeating: nil, count: groups.count)
        var done = [Bool](repeating: false, count: groups.count)
        var next = 0
        var running = 0
        var finished = false
        var failures = 0

        func finish(complete: Bool) {
            // Called with the lock held.
            guard !finished else { return }
            finished = true
            let ranked = Top100Resolver.rank(groups: groups, metas: results, limit: limit)
            let isComplete = complete && failures == 0
            DispatchQueue.global(qos: .userInitiated).async { completion(ranked, isComplete) }
        }
        /// Distinct titles among the leading groups that are all resolved:
        /// enough of them and the rest can't change the top `limit`.
        func leadingCertain() -> Int {
            var ids = Set<String>()
            for index in groups.indices {
                guard done[index] else { break }
                if let meta = results[index], let id = CinemetaMatching.id(meta) { ids.insert(id) }
            }
            return ids.count
        }
        func pump() {
            // Called with the lock held.
            guard !finished else { return }
            if leadingCertain() >= limit || (next >= groups.count && running == 0) {
                return finish(complete: true)
            }
            while running < maxConcurrent, next < groups.count {
                let index = next
                next += 1
                running += 1
                // Started off the lock: a cached group calls back at once.
                DispatchQueue.global(qos: .userInitiated).async {
                    self.resolve(groups[index]) { meta, answered in
                        lock.lock()
                        results[index] = meta
                        done[index] = true
                        if !answered { failures += 1 }
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
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
            lock.lock()
            if !finished { print("[Top100] \(self.kind.rawValue): deadline, \(done.filter { $0 }.count)/\(groups.count) groups resolved") }
            finish(complete: false)
            lock.unlock()
        }
    }

    /// Resolved metas in rank order: one per IMDb id (seeders of its groups
    /// summed, plus those of unresolved groups the index files under that id
    /// whose title and year agree), most seeded first, at most `limit`.
    static func rank(groups: [Top100Group], metas: [[String: Any]?], limit: Int) -> [Resolved] {
        var order: [String] = []
        var byId: [String: (meta: [String: Any], seeders: Int, first: Int, keys: [String])] = [:]
        for (index, group) in groups.enumerated() {
            guard let meta = metas[index], let id = CinemetaMatching.id(meta) else { continue }
            if let known = byId[id] {
                byId[id] = (known.meta, known.seeders &+ group.seeders, known.first, known.keys + [group.key])
            } else {
                byId[id] = (meta, group.seeders, index, [group.key])
                order.append(id)
            }
        }
        // "Avatar.The.Legend.of.Aang.The.Last.Airbender.2026" (a naming
        // variant Cinemeta couldn't confirm) under the id of "Aang: The Last
        // Airbender", listed through another release: its seeders count.
        for (index, group) in groups.enumerated() where metas[index] == nil {
            guard let id = group.imdbIds.first, let known = byId[id], sharesTitle(group, known.meta) else { continue }
            byId[id] = (known.meta, known.seeders &+ group.seeders, known.first, known.keys + [group.key])
        }
        return order.compactMap { byId[$0] }
            .sorted { $0.seeders != $1.seeders ? $0.seeders > $1.seeders : $0.first < $1.first }
            .prefix(limit)
            .map { Resolved(meta: $0.meta, seeders: $0.seeders, keys: $0.keys) }
    }

    /// The group's reading shares a word of the meta's name, and a year within
    /// one of the meta's when both have one.
    private static func sharesTitle(_ group: Top100Group, _ meta: [String: Any]) -> Bool {
        guard let reading = group.readings.first, let name = meta["name"] as? String else { return false }
        let common = Set(CinemetaMatching.contentWords(reading.title)).intersection(CinemetaMatching.contentWords(name))
        guard !common.isEmpty else { return false }
        if let year = reading.year, let metaYear = CinemetaMatching.startYear(meta) { return abs(year - metaYear) <= 1 }
        return true
    }

    // MARK: Genre filter

    /// Cinemeta's genre names for the app's genres (`NetworkManager.Genres`
    /// raw values, lower-cased) when they differ.
    private static let cinemetaGenres: [String: Set<String>] = [
        "science fiction": ["sci-fi", "science fiction", "sci-fi & fantasy"],
        "sports": ["sport", "sports"],
        "sporting event": ["sport"],
        "film noir": ["film-noir"],
        "music": ["music", "musical"],
        "suspense": ["thriller", "mystery", "suspense"],
        "fantasy": ["fantasy", "sci-fi & fantasy"],
        "action": ["action", "action & adventure"],
        "adventure": ["adventure", "action & adventure"],
    ]

    /// The metas of one genre (an app genre's raw value: "Science Fiction"
    /// keeps Cinemeta's "Sci-Fi"), in order.
    static func filter(_ metas: [[String: Any]], genre: String) -> [[String: Any]] {
        let wanted = genre.lowercased()
        let names = cinemetaGenres[wanted] ?? [wanted]
        return metas.filter { meta in
            let genres = ((meta["genres"] as? [String]) ?? (meta["genre"] as? [String]) ?? []).map { $0.lowercased() }
            return genres.contains { names.contains($0) }
        }
    }

    // MARK: One group

    /// The meta of one group, nil when unresolvable; `answered` false when a
    /// Cinemeta call failed on the way (then nothing is remembered).
    private func resolve(_ group: Top100Group, completion: @escaping ([String: Any]?, Bool) -> Void) {
        let cacheKey = "\(kind.rawValue)|\(group.key)|\(group.imdbIds.joined(separator: ","))"
        if let cached = Top100Resolver.resolutions.value(for: cacheKey) {
            return completion(cached.isEmpty ? nil : cached, true)
        }
        var answered = true
        let store: ([String: Any]?) -> Void = { meta in
            let meta = meta.map { self.withReleaseYear($0, group: group) }
            // A title found is found; "none" only when Cinemeta answered every call.
            if meta != nil || answered { Top100Resolver.resolutions.set(meta ?? [:], for: cacheKey) }
            completion(meta, answered || meta != nil)
        }
        // Strong captures: the resolver lives until its groups are resolved.
        tryIds(Array(group.imdbIds.prefix(2)), group: group, failed: { answered = false }) { meta in
            if let meta = meta { return store(meta) }
            self.trySearch(Array(group.readings.prefix(2)), group: group, failed: { answered = false }, completion: store)
        }
    }

    private func tryIds(_ ids: [String], group: Top100Group, failed: @escaping () -> Void,
                        completion: @escaping ([String: Any]?) -> Void) {
        guard let id = ids.first else { return completion(nil) }
        fetchMeta(kind, id) { meta, answered in
            if !answered { failed() }
            if let meta = meta, self.metaMatches(meta, group) { return completion(meta) }
            self.tryIds(Array(ids.dropFirst()), group: group, failed: failed, completion: completion)
        }
    }

    private func trySearch(_ readings: [Top100Group.Reading], group: Top100Group, failed: @escaping () -> Void,
                           completion: @escaping ([String: Any]?) -> Void) {
        guard let reading = readings.first else { return completion(nil) }
        search(kind, reading.title) { metas, answered in
            if !answered { failed() }
            let match: [String: Any]?
            switch self.kind {
            case .movie:
                match = reading.year.flatMap { CinemetaMatching.movieSearchMatch(metas, title: reading.title, year: $0) }
            case .series:
                match = CinemetaMatching.showSearchMatch(metas, title: reading.title, year: reading.year)
            }
            guard let found = match, let id = CinemetaMatching.id(found) else {
                return self.trySearch(Array(readings.dropFirst()), group: group, failed: failed, completion: completion)
            }
            // Search results carry no genres: the full meta does.
            self.fetchMeta(self.kind, id) { meta, answered in
                if !answered { failed() }
                guard var meta = meta, CinemetaMatching.isComplete(meta) else { return completion(found) }
                // The search's year is the one the releases name (an exact
                // match): the full record's may differ ("The Weight", 2026 in
                // the search, 2020 in the record).
                if self.kind == .movie, let info = found["releaseInfo"] as? String, info.count == 4 {
                    meta["releaseInfo"] = info
                }
                completion(meta)
            }
        }
    }

    /// A movie meta whose year is one off the year its releases name takes
    /// theirs (Cinemeta's full record sometimes carries a later release year:
    /// "Amélie" 2002, "Paprika" 2007, "La Haine" 1996).
    private func withReleaseYear(_ meta: [String: Any], group: Top100Group) -> [String: Any] {
        guard kind == .movie, let year = group.year,
              let info = meta["releaseInfo"] as? String, info.count == 4, let metaYear = Int(info),
              metaYear != year, abs(metaYear - year) <= 1 else { return meta }
        var adjusted = meta
        adjusted["releaseInfo"] = String(year)
        return adjusted
    }

    private func metaMatches(_ meta: [String: Any], _ group: Top100Group) -> Bool {
        switch kind {
        case .movie: return CinemetaMatching.movieMetaMatches(meta, group: group)
        case .series: return CinemetaMatching.showMetaMatches(meta, group: group)
        }
    }
}
