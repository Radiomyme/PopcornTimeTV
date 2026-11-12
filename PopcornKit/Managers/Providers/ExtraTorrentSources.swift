import Foundation

/// More torrents per title from The Pirate Bay (apibay) and the Knaben
/// meta-index, beside YTS / EZTV / Torrentio / Time4Popcorn. Both are free-text
/// searches, so every result goes through `ReleaseMatch` before it can reach
/// the torrent picker (precision first: a torrent of the wrong film or episode
/// is worse than none):
///
/// - movies: search "Title Year" for every distinct title + year the sources
///   give (YTS, Time4Popcorn and Cinemeta don't always agree: Amélie 2001 /
///   2002); keep a release whose name is the title (or a known alias)
///   followed by one of its years, alone (no pack, no bonus disc), not filed
///   under another film of the same title and year;
/// - episodes: search "Show SxxEyy" (the app's title, TVMaze's, an acronym
///   form: "Law and Order SVU"); keep a release of exactly that episode (no
///   pack) whose show part is the show's TVMaze title or an alternate title,
///   with the year / country the show's when the release names one, and a
///   year or country when another show of the same name can have that episode.
///
/// Releases that can't stream (disc images, archives, BD / DVD structures),
/// 3D / RiffTrax / fan-edit versions and torrents with fewer than
/// `minSeeders` seeders are dropped, and of copies with the same name and
/// size only the best seeded is kept. Torrents are labelled like Torrentio's:
/// "1080p — TPB", "2160p HDR — Knaben · 1337x". Every source is optional and
/// fails fast; completions run on the main queue.
public final class ExtraTorrentSources {

    public static let shared = ExtraTorrentSources()

    /// Longest wait for a standalone search (`searchMovie`).
    public static var deadline: TimeInterval = 6
    /// On a movie page, the longest wait for TPB / Knaben once the other
    /// sources have answered: whatever arrived by then is used (late answers
    /// are cached for the next opening).
    public static var grace: TimeInterval = 1.5
    /// At play time, the longest wait for an episode's extra torrents.
    public static var episodeDeadline: TimeInterval = 3
    /// Fewest seeders of a torrent worth offering.
    public static var minSeeders = 3
    /// Most distinct searches per title.
    static let maxQueries = 3

    private let tvmaze = IndexFetcher(name: "TVMaze", timeout: 6, cacheLifetime: 3600, backoff: 60)
    private let identities = TTLCache<IdentityBox>(lifetime: 3600)

    public init() {}

    // MARK: Movies

    /// A movie page's search: `offer` each title + year a source gives as it
    /// answers, then `finish` once the page's other sources are in.
    public func movieSearch(imdbId: String) -> MovieSearch {
        return MovieSearch(imdbId: imdbId)
    }

    /// The words searched for a movie title: `ReleaseMatch.searchTerms`
    /// without a leading "the" (indexes match every word, and "Intouchables
    /// 2011" releases lack it).
    public static func movieTerms(_ title: String, year: Int? = nil) -> String {
        var words = ReleaseMatch.searchTerms(title).split(separator: " ").map(String.init)
        if words.count > 1, words.first == "the" { words.removeFirst() }
        // A title that already ends with the year ("Us 2019" on Time4Popcorn).
        if let year = year, words.count > 1, words.last == String(year) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// The searches of one movie page. Main queue only.
    public final class MovieSearch {
        private let imdbId: String
        private var queries: [String] = []
        private var namesakeQueries: Set<String> = []
        private var fromTPB: [[IndexedRelease]] = []
        private var fromKnaben: [[IndexedRelease]] = []
        private var namesakeMetas: [[String: Any]] = []
        private var offeredTitles: [String] = []
        private var offeredYears: [Int] = []
        private var reliableYears: [Int] = []
        private var foreignIds: Set<String> = []
        private var pending = 0
        private var onIdle: (() -> Void)?

        /// Once finished (for measurements): every release the searches
        /// found, those of the movie, the namesakes' ids, the queries sent.
        public private(set) var found: [IndexedRelease] = []
        public private(set) var accepted: [IndexedRelease] = []
        public private(set) var namesakeIds: Set<String> = []
        public var sentQueries: [String] { queries }

        init(imdbId: String) {
            self.imdbId = imdbId
        }

        /// A title and year a source gives: searched unless already searched
        /// (at most three searches). `yearIsReliable` false for Cinemeta,
        /// whose year is sometimes a later release's ("Amélie" 2002).
        public func offer(title: String?, year: Int?, yearIsReliable: Bool = true) {
            guard let title = title, let year = year, year > 0 else { return }
            if !offeredTitles.contains(title) { offeredTitles.append(title) }
            if !offeredYears.contains(year) { offeredYears.append(year) }
            if yearIsReliable, !reliableYears.contains(year) { reliableYears.append(year) }
            search(title: title, year: year)
            // Other films of that title (and year): Cinemeta lists them.
            let name = ReleaseMatch.searchTerms(title)
            if !name.isEmpty, namesakeQueries.count < 2, namesakeQueries.insert(name).inserted {
                pending += 1
                CinemetaClient.search(.movie, query: name) { metas in
                    DispatchQueue.main.async { [self] in
                        namesakeMetas += metas
                        done()
                    }
                }
            }
        }

        /// Searches "Title Year" unless already searched (at most three searches).
        private func search(title: String, year: Int) {
            let terms = ExtraTorrentSources.movieTerms(title, year: year)
            guard !terms.isEmpty else { return }
            let query = "\(terms) \(year)"
            guard !queries.contains(query), queries.count < ExtraTorrentSources.maxQueries else { return }
            queries.append(query)
            let slot = fromTPB.count
            fromTPB.append([])
            fromKnaben.append([])
            pending += 2
            PirateBayClient.shared.search(query, categories: PirateBayClient.movieCategories) { [self] found in
                fromTPB[slot] = found
                lookUpForeignIds(found)
                done()
            }
            KnabenClient.shared.search(query, categories: KnabenClient.movieCategories) { [self] found in
                fromKnaben[slot] = found
                done()
            }
        }

        /// The Pirate Bay files some releases of the title and year under
        /// another IMDb id: when Cinemeta knows that id as a complete film of
        /// the same title and year, it is a namesake ("The Odyssey" 2026,
        /// tt41605854, not Nolan's) and its releases are left out. Four ids at
        /// most, the best seeded; Cinemeta's answers are cached.
        private func lookUpForeignIds(_ found: [IndexedRelease]) {
            let provisional = ReleaseMatch.MovieIdentity(titles: offeredTitles, years: Set(offeredYears), imdbId: imdbId)
            for release in found.sorted(by: { $0.seeders > $1.seeders }) where foreignIds.count < 4 {
                guard let id = release.imdb, id != imdbId, !foreignIds.contains(id),
                      ReleaseMatch.isRelease(release.name, of: provisional) else { continue }
                foreignIds.insert(id)
                pending += 1
                CinemetaClient.meta(.movie, imdbId: id) { meta in
                    DispatchQueue.main.async { [self] in
                        if var meta = meta {
                            meta["id"] = meta["id"] ?? id
                            namesakeMetas.append(meta)
                        }
                        done()
                    }
                }
            }
        }

        /// A title one source gives with the year another gives ("The Weight"
        /// 2020 on Cinemeta, 2026 on YTS under its Chinese title): searched
        /// last, with the slots left, YTS's / Time4Popcorn's years first.
        private func searchCrossPairs() {
            for year in reliableYears + offeredYears.filter({ !reliableYears.contains($0) }) {
                for title in offeredTitles where queries.count < ExtraTorrentSources.maxQueries {
                    search(title: title, year: year)
                }
            }
        }

        private func done() {
            pending -= 1
            if pending == 0, let idle = onIdle {
                onIdle = nil
                idle()
            }
        }

        /// Every release found so far, deduplicated (TPB first: its IMDb ids).
        var releases: [IndexedRelease] {
            return IndexedRelease.deduplicated(fromTPB.flatMap { $0 } + fromKnaben.flatMap { $0 })
        }

        /// The torrents of the movie `identity` names (asked once the searches
        /// are in or `grace` has passed, so late titles count), on the main queue.
        public func finish(within grace: TimeInterval = ExtraTorrentSources.grace,
                           identity: @escaping () -> ReleaseMatch.MovieIdentity,
                           completion: @escaping ([Torrent]) -> Void) {
            searchCrossPairs()
            let once = Once<Void> { [self] _ in
                var movie = identity()
                movie.namesakeIds = ExtraTorrentSources.namesakes(of: movie, among: namesakeMetas)
                let all = releases
                found = all
                accepted = ReleaseMatch.movieReleases(all, of: movie)
                namesakeIds = movie.namesakeIds
                completion(ExtraTorrentSources.movieTorrents(from: all, movie: movie))
            }
            guard pending > 0 else { return once(()) }
            onIdle = { once(()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [self] in
                if pending > 0 { print("[Extra] \(imdbId): \(pending) source(s) late, using what arrived") }
                onIdle = nil
                once(())
            }
        }
    }

    /// IMDb ids of the other complete Cinemeta entries with the movie's title
    /// and one of its years ("The Odyssey" 2026: two besides Nolan's).
    public static func namesakes(of movie: ReleaseMatch.MovieIdentity, among metas: [[String: Any]]) -> Set<String> {
        let titles = Set(movie.titles.flatMap(ReleaseMatch.titleForms).map { $0.joined() })
        var ids = Set<String>()
        for meta in metas {
            guard CinemetaMatching.isComplete(meta), let id = CinemetaMatching.id(meta), id != movie.imdbId,
                  let name = meta["name"] as? String, let info = meta["releaseInfo"] as? String, info.count == 4,
                  let year = Int(info), movie.years.contains(year),
                  ReleaseMatch.titleForms(name).contains(where: { titles.contains($0.joined()) }) else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// TPB + Knaben search results for "Title Year" (movie categories),
    /// deduplicated by info-hash, NOT yet filtered: pass them to
    /// `movieTorrents(from:movie:)` once the movie's aliases and years are
    /// all known. Main queue, within `deadline`.
    public func searchMovie(title: String, year: Int, completion: @escaping ([IndexedRelease]) -> Void) {
        let terms = ExtraTorrentSources.movieTerms(title)
        guard !terms.isEmpty, year > 0 else { return DispatchQueue.main.async { completion([]) } }
        search("\(terms) \(year)", tpb: PirateBayClient.movieCategories, knaben: KnabenClient.movieCategories, completion: completion)
    }

    /// The releases of `movie` among search results, as torrents.
    public static func movieTorrents(from releases: [IndexedRelease], movie: ReleaseMatch.MovieIdentity) -> [Torrent] {
        let kept = ReleaseMatch.movieReleases(releases, of: movie)
        let offered = offerable(kept)
        if !releases.isEmpty {
            print("[Extra] \(movie.imdbId) \(movie.titles.first ?? "") \(movie.years.sorted()): kept \(kept.count)/\(releases.count), \(offered.count) offered\(movie.namesakeIds.isEmpty ? "" : ", namesakes \(movie.namesakeIds.sorted())")")
        }
        return offered.map(torrent(from:))
    }

    /// Releases worth offering: at least `minSeeders` seeders, one per name
    /// and size (the same upload under several hashes: the best seeded).
    public static func offerable(_ releases: [IndexedRelease]) -> [IndexedRelease] {
        var seen = Set<String>()
        return releases
            .filter { $0.seeders >= minSeeders }
            .sorted { $0.seeders > $1.seeders }
            .filter { release in
                let key = ReleaseMatch.words(release.name).joined(separator: " ") + "|" + String(release.bytes ?? -1)
                return seen.insert(key).inserted
            }
    }

    /// The extra torrents that are new beside the other sources' `lists`: a
    /// torrent another source already lists (same info-hash, seeded) keeps
    /// that source's row and label.
    public static func novel(_ extra: [Torrent], beside lists: [Torrent]) -> [Torrent] {
        let known = Set(lists.filter { $0.seeds > 0 }.compactMap { TorrentioClient.infoHash(fromMagnet: $0.url) })
        return extra.filter { torrent in
            guard let hash = TorrentioClient.infoHash(fromMagnet: torrent.url) else { return false }
            return !known.contains(hash)
        }
    }

    // MARK: Episodes

    /// TPB + Knaben torrents of exactly one episode. `showTitle` (the title
    /// the app shows) starts the searches at once; the show's TVMaze entry
    /// (title, alternate titles, premiere year, country, namesakes) decides
    /// which results are the episode. Main queue, within `episodeDeadline`
    /// (a slow source is left out).
    public func episodeTorrents(imdbId: String, showTitle: String?, season: Int, episode: Int,
                                completion: @escaping ([Torrent]) -> Void) {
        guard imdbId.hasPrefix("tt"), season >= 0, episode > 0 else { return DispatchQueue.main.async { completion([]) } }
        guard Thread.isMainThread else {
            return DispatchQueue.main.async {
                self.episodeTorrents(imdbId: imdbId, showTitle: showTitle, season: season, episode: episode, completion: completion)
            }
        }
        var identity: ReleaseMatch.ShowIdentity?
        var identityKnown = false
        var fromTPB: [[IndexedRelease]] = []
        var fromKnaben: [[IndexedRelease]] = []
        var queries: [String] = []
        var pending = 0
        let marker = String(format: "S%02dE%02d", season, episode)
        let finish = Once<[Torrent]>(completion)

        func result() -> [Torrent] {
            guard let identity = identity else { return [] }
            let releases = IndexedRelease.deduplicated(fromTPB.flatMap { $0 } + fromKnaben.flatMap { $0 })
            let kept = ReleaseMatch.episodeReleases(releases, season: season, episode: episode, of: identity)
            let offered = ExtraTorrentSources.offerable(kept)
            print("[Extra] \(imdbId) \(identity.titles.first ?? "") \(marker) year=\(identity.year.map(String.init) ?? "?") country=\(identity.country ?? "?") ambiguous=\(identity.isAmbiguous): kept \(kept.count)/\(releases.count), \(offered.count) offered")
            return offered.map(ExtraTorrentSources.torrent(from:))
        }
        func check() {
            if identityKnown && pending == 0 { finish(result()) }
        }
        func startSearches(_ title: String) {
            for terms in ExtraTorrentSources.episodeTerms(title) where queries.count < ExtraTorrentSources.maxQueries && !queries.contains(terms) {
                queries.append(terms)
                let slot = fromTPB.count
                fromTPB.append([])
                fromKnaben.append([])
                pending += 2
                PirateBayClient.shared.search("\(terms) \(marker)", categories: PirateBayClient.showCategories) { found in
                    fromTPB[slot] = found
                    pending -= 1
                    check()
                }
                KnabenClient.shared.search("\(terms) \(marker)", categories: KnabenClient.showCategories) { found in
                    fromKnaben[slot] = found
                    pending -= 1
                    check()
                }
            }
        }

        if let title = showTitle { startSearches(title) }
        showIdentity(imdbId: imdbId, fallbackTitle: showTitle) { found in
            self.episodeIdentity(found, season: season, episode: episode) { adjusted in
                DispatchQueue.main.async {
                    identity = adjusted
                    identityKnown = true
                    if let title = adjusted.titles.first { startSearches(title) }
                    check()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ExtraTorrentSources.episodeDeadline) {
            guard !finish.isDone else { return }
            print("[Extra] \(imdbId) \(marker): late sources left out")
            finish(result())
        }
    }

    /// The words searched for a show title: its search terms, plus — for a
    /// "Main: Sub Title" name — the main words and the subtitle's acronym,
    /// the way releases name it ("Law & Order: Special Victims Unit" → "law
    /// and order svu").
    static func episodeTerms(_ title: String) -> [String] {
        var result: [String] = []
        let terms = ReleaseMatch.searchTerms(title)
        if !terms.isEmpty { result.append(terms) }
        if let colon = title.firstIndex(of: ":") {
            let main = ReleaseMatch.searchTerms(String(title[..<colon]))
            let sub = ReleaseMatch.words(String(title[title.index(after: colon)...]))
            if !main.isEmpty, sub.count >= 2 {
                result.append(main + " " + sub.compactMap(\.first).map(String.init).joined())
            }
        }
        return result
    }

    /// The identity for one episode: a show whose namesakes (other shows of
    /// its name) can't have this episode — TVMaze has no such episode for
    /// them: a one-season "Silo" for S03E08 — is not ambiguous for it.
    private func episodeIdentity(_ identity: ReleaseMatch.ShowIdentity, season: Int, episode: Int,
                                 completion: @escaping (ReleaseMatch.ShowIdentity) -> Void) {
        let namesakes = Array(identity.namesakeIds.prefix(3))
        guard identity.isAmbiguous, !namesakes.isEmpty, namesakes.count == identity.namesakeIds.count else {
            return completion(identity)
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var possible = 0
        for id in namesakes {
            group.enter()
            tvmaze.fetch(hosts: ["https://api.tvmaze.com"], path: "/shows/\(id)/episodebynumber?season=\(season)&number=\(episode)") { outcome in
                // Only TVMaze's "no such episode" (404) rules it out.
                if case .status(404) = outcome {} else {
                    lock.lock(); possible += 1; lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            var adjusted = identity
            if possible == 0 { adjusted.isAmbiguous = false }
            completion(adjusted)
        }
    }

    /// What identifies the show in release names, from TVMaze (cached an
    /// hour). Unknown show (TVMaze down): the app's title, strictly matched
    /// (a year or country must agree, and none is known: nothing passes).
    private func showIdentity(imdbId: String, fallbackTitle: String?,
                              completion: @escaping (ReleaseMatch.ShowIdentity) -> Void) {
        let extra = fallbackTitle.map { [$0] } ?? []
        if let cached = identities.value(for: imdbId) {
            var identity = cached.identity
            for title in extra where !identity.titles.contains(title) { identity.titles.append(title) }
            return completion(identity)
        }
        let hosts = ["https://api.tvmaze.com"]
        tvmaze.data(hosts: hosts, path: "/lookup/shows?imdb=\(imdbId)") { [weak self] data in
            guard let self = self,
                  let show = data.flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }),
                  let tvmazeId = show["id"] as? Int, let name = show["name"] as? String else {
                return completion(ReleaseMatch.ShowIdentity(titles: extra, year: nil, country: nil, isAmbiguous: true))
            }
            let group = DispatchGroup()
            var akas: [String] = []
            var results: [[String: Any]]?
            group.enter()
            self.tvmaze.data(hosts: hosts, path: "/shows/\(tvmazeId)/akas") { data in
                let list = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] } ?? []
                akas = ReleaseMatch.englishAkas(list)
                group.leave()
            }
            group.enter()
            self.tvmaze.data(hosts: hosts, path: "/search/shows?q=\(IndexFetcher.encode(name))") { data in
                results = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] }
                group.leave()
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                let identity = ReleaseMatch.showIdentity(tvmaze: show, akas: akas, searchResults: results)
                if results != nil { self.identities.set(IdentityBox(identity: identity), for: imdbId) }
                var withApp = identity
                for title in extra where !withApp.titles.contains(title) { withApp.titles.append(title) }
                completion(withApp)
            }
        }
    }

    private struct IdentityBox {
        let identity: ReleaseMatch.ShowIdentity
    }

    // MARK: Shared

    /// TPB + Knaben results for `query`, deduplicated (TPB first), on the main
    /// queue within `deadline` (a slow source is left out).
    private func search(_ query: String, tpb: [Int], knaben: [Int], completion: @escaping ([IndexedRelease]) -> Void) {
        let group = DispatchGroup()
        var fromTPB: [IndexedRelease] = []
        var fromKnaben: [IndexedRelease] = []
        group.enter()
        PirateBayClient.shared.search(query, categories: tpb) { found in
            fromTPB = found
            group.leave()
        }
        group.enter()
        KnabenClient.shared.search(query, categories: knaben) { found in
            fromKnaben = found
            group.leave()
        }
        let finish = Once<[IndexedRelease]>(completion)
        group.notify(queue: .main) {
            finish(IndexedRelease.deduplicated(fromTPB + fromKnaben))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ExtraTorrentSources.deadline) {
            // Main queue, like the completions: whatever arrived so far.
            finish(IndexedRelease.deduplicated(fromTPB + fromKnaben))
        }
    }

    /// A playable torrent for an index release: a magnet rebuilt from the
    /// info-hash, the release name and public trackers; quality and tags
    /// parsed from the name; labelled with its source like Torrentio's.
    static func torrent(from release: IndexedRelease) -> Torrent {
        let dn = release.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? release.name
        var magnet = "magnet:?xt=urn:btih:\(release.infoHash)&dn=\(dn)"
        for tracker in TorrentioClient.trackers {
            magnet += "&tr=" + (tracker.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tracker)
        }
        var torrent = Torrent(health: .unknown,
                              url: magnet,
                              quality: release.name,
                              seeds: release.seeders,
                              peers: release.peers,
                              size: release.sizeString,
                              tags: VideoTags.parse(release.name))
        var label = torrent.qualityValue.displayLabel + torrent.tags.displaySuffix
        if label.isEmpty { label = "Unknown".localized }
        torrent.quality = label + Torrent.sourceSeparator + release.source
        // The `quality` setter re-parses the label: restore the name's bucket and tags.
        torrent.qualityValue = VideoQuality.parse(release.name)
        torrent.tags = VideoTags.parse(release.name)
        return torrent
    }
}

/// A completion that runs once: the first call wins, later ones are ignored.
/// Called on the main queue only.
final class Once<Value> {
    private var completion: ((Value) -> Void)?

    init(_ completion: @escaping (Value) -> Void) {
        self.completion = completion
    }

    /// Called already.
    var isDone: Bool { completion == nil }

    func callAsFunction(_ value: Value) {
        guard let completion = completion else { return }
        self.completion = nil
        completion(value)
    }
}
