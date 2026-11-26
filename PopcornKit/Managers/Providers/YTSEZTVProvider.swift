

import Foundation
import Alamofire

/// Default `MediaProvider`, on keyless public sources:
///
/// - Movies: YTS (`movies-api.accel.li` and its mirrors) for the grid, the
///   details and the curated torrents; Time4Popcorn's most seeded list in
///   front of "Popular" and in searches; Cinemeta's search for the titles no
///   catalog has. What each sort asks: `YTSCatalog`.
/// - Shows: Cinemeta's catalogs for Trending / Popular / Top Rated / New /
///   A - Z and the genres (one request a page: `ShowCatalog`); EZTV's latest
///   releases named through `TVMazeShowDirectory` for "Recently Added";
///   TVMaze's and Cinemeta's searches; TVMaze's episode guide and EZTV's
///   torrents for a show's page.
/// - The Top 100 of both: `PirateBayTop100`.
///
/// Every list is delivered by a `SourceGate` (a slow optional source is left
/// out, nothing waits past the deadline) and every YTS / EZTV request is a
/// `MirrorRace`. Completions run on the main queue.
public final class YTSEZTVProvider: MediaProvider {

    private let session: Session = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The mirror race's own deadline (`MirrorRace.deadline`).
        configuration.timeoutIntervalForRequest = 10
        // Some public APIs (YTS included) rate-limit or 403 the default
        // Alamofire user-agent. Pose as a regular browser request.
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 11_0) AppleWebKit/605.1.15 PopcornTime/4.2",
            "Accept":     "application/json, text/plain, */*",
        ]
        return Session(configuration: configuration)
    }()

    /// Hosts the provider asks, in order (`MirrorRace`). The current official
    /// YTS endpoint (May 2026) is `movies-api.accel.li` — the legacy `yts.mx`
    /// domain has been retired (NXDOMAIN globally) and `yts.bz` is the
    /// front-end mirror that announces the API migration. The remaining
    /// entries are kept as last-resort fallbacks but they're either
    /// redirected to the new host or known broken. The host that last gave a
    /// valid answer is asked first for a day (`MirrorHealth`), so later
    /// launches skip the failed lookups.
    public static var ytsMirrors: [String] = [
        "https://movies-api.accel.li",
        "https://yts.bz",
        "https://yts.am",
        "https://yts.lt",
        "https://yts.rs",
        "https://yts.ag",
    ]

    private let ytsHealth = MirrorHealth(name: "YTS", stickyKey: "popcornkit.yts.lastGoodHost")

    private struct Path {
        static let listMovies = "/api/v2/list_movies.json"
        static let movieInfo  = "/api/v2/movie_details.json"
        static let movieSuggestions = "/api/v2/movie_suggestions.json"
    }

    public init() {}

    /// YTS `movie_details` objects by IMDb id (with the cast): filled by
    /// `getMovieInfo`, read by `ytsMovieDetails`, so a movie page doesn't ask
    /// YTS for the same details three times (info, cast, suggestions).
    private let detailsCache = NSCache<NSString, NSDictionary>()
    /// Who waits for the `movie_details` request in flight for an IMDb id:
    /// the page's cast and suggestions join the page's own request instead
    /// of sending the same one beside it.
    private var detailsWaiters: [String: [([String: Any]?) -> Void]] = [:]
    private let detailsLock = NSLock()

    /// A `movie_details` request for `imdbId` leaves: `ytsMovieDetails`
    /// waits for its answer.
    private func detailsRequestBegan(_ imdbId: String) {
        detailsLock.lock()
        if detailsWaiters[imdbId] == nil { detailsWaiters[imdbId] = [] }
        detailsLock.unlock()
    }

    /// Its answer: the raw movie object when YTS has the title, kept for
    /// the next calls, and handed to whoever waited (main queue).
    private func detailsRequestEnded(_ imdbId: String, movie: [String: Any]?) {
        if let movie = movie { detailsCache.setObject(movie as NSDictionary, forKey: imdbId as NSString) }
        detailsLock.lock()
        let waiters = detailsWaiters.removeValue(forKey: imdbId) ?? []
        detailsLock.unlock()
        guard !waiters.isEmpty else { return }
        DispatchQueue.main.async { waiters.forEach { $0(movie) } }
    }

    /// How long a show's page (its guide and torrents) is served again
    /// without asking: an episode out since then shows up on the next
    /// opening. (The cache had no lifetime: a show opened once kept its
    /// episode list until the app was killed, days on an Apple TV.)
    public static var showLifetime: TimeInterval = 15 * 60
    /// Most shows kept (each carries every episode and its torrents).
    static let showCapacity = 30

    /// The complete shows `getShowInfo` built, by IMDb id.
    private let showCache = BoundedTTLCache<Show>(lifetime: YTSEZTVProvider.showLifetime, capacity: YTSEZTVProvider.showCapacity)

    /// EZTV mirror chain. `eztvx.to` is the canonical host but most FAIs (and
    /// Apple's `Designed for iPad` Mac sandbox) DNS-block it, so we put a
    /// Cloudflare-fronted alternate first. `MirrorHealth` promotes whichever
    /// mirror last gave a valid answer, so subsequent runs skip the failure.
    public static var eztvMirrors: [String] = [
        "https://eztv.wf",
        "https://eztv.tf",
        "https://eztv.yt",
        "https://eztv1.xyz",
        "https://eztv.re",
        "https://eztvx.to",
    ]

    private let eztvHealth = MirrorHealth(name: "EZTV", stickyKey: "popcornkit.eztv.lastGoodHost")

    /// True when the list `loadMovies` / `loadShows` has just delivered
    /// misses something that was asked: a source left out at the gate's
    /// grace or deadline, Time4Popcorn not answering, shows of "Recently
    /// Added" whose lookups were not in on time. Set right before the
    /// completion runs, on the main queue, so a caller reads it inside its
    /// completion. Such a list is shown, but not kept as the list's snapshot
    /// (`MovieManager.load`).
    public private(set) var lastListWasPartial = false

    /// Where each grid page of the lists read as segments starts
    /// (`CatalogRollover`), by list.
    private let pageStarts = CatalogPageStarts<CatalogRollover.Cursor>()
    /// The Time4Popcorn page each grid page of "Popular" asks, by list: the
    /// grid's own, less the pages delivered without it.
    private let t4pPages = CatalogPageStarts<Int>()

    // MARK: - Movies

    public func loadMovies(page: Int,
                           filter: MovieManager.Filters,
                           genre: NetworkManager.Genres,
                           searchTerm: String?,
                           order: NetworkManager.Orders,
                           completion: @escaping ([Movie]?, NSError?) -> Void) {
        let term = (searchTerm ?? "").trimmingCharacters(in: .whitespaces)
        let searching = !term.isEmpty

        // Top 100: The Pirate Bay's most seeded movies, mapped to IMDb titles.
        // A search typed while it is selected searches the catalog as usual.
        if filter == .top100, !searching {
            return PirateBayTop100.shared.movies(page: page, genre: genre, completion: completion)
        }
        // A genre YTS does not have: no result, not its whole catalog (YTS
        // ignores a genre it does not know).
        if genre != .all, genre.ytsValue == nil {
            return DispatchQueue.main.async { completion([], nil) }
        }

        var ytsMovies: [Movie] = []
        var ytsError: NSError?
        var t4pMovies: [Movie] = []
        var cinemetaMovies: [Movie] = []
        var cinemeta = CinemetaStanding()

        // Time4Popcorn's list is always "most seeded": in front of "Popular"
        // and in searches only. (It used to open every sort: the first 75
        // posters were the same whatever was picked.)
        let withT4P = searching || (filter == .popularity && order == .descending)
        let listKey = CatalogSnapshotStore.key(kind: "movies", filter: filter.rawValue, genre: genre.rawValue, order: order)
        // Its page: the grid's, unless an earlier page of the list went
        // without it (it was late, or down): its most seeded titles then
        // open the next page, instead of never being shown.
        let t4pPage = searching || page <= 1 ? max(page, 1) : (t4pPages.start(of: page, in: listKey) ?? page)
        /// Time4Popcorn answered in time: its page is in the list.
        var t4pMerged = false
        /// Time4Popcorn could not be reached.
        var t4pFailed = false
        /// YTS answered, if only with nothing: an empty list is an answer,
        /// not a failure, whatever optional source was left out.
        var ytsAnswered = false

        let gate = SourceGate(grace: searching ? SourceGate.searchGrace : SourceGate.browseGrace) { complete in
            var seen = Set<String>()
            var merged: [Movie] = []
            for movie in t4pMovies + ytsMovies + cinemetaMovies where seen.insert(movie.id).inserted {
                merged.append(movie)
            }
            if searching {
                if page <= 1 {
                    merged = YTSEZTVProvider.exactFirst(merged, query: term, title: { $0.title },
                                                        aliases: { cinemeta.names[$0.id].map { [$0] } ?? [] },
                                                        rank: { cinemeta.ranks[$0.id] })
                }
            } else {
                merged = YTSCatalog.withoutNamesakes(merged)
            }
            print("[Movies] \(filter.rawValue): T4P \(t4pMovies.count) + YTS \(ytsMovies.count) + Cinemeta \(cinemetaMovies.count) -> \(merged.count) (page \(page)\(complete ? "" : ", a source left out"))")
            if withT4P, !searching {
                self.t4pPages.set(t4pMerged ? t4pPage + 1 : t4pPage, of: max(page, 1) + 1, in: listKey)
            }
            // A list without Time4Popcorn's page is not "Popular" as it will
            // be once the host answers again: not kept.
            self.lastListWasPartial = !complete || t4pFailed
            if let failure = YTSEZTVProvider.failure(listIsEmpty: merged.isEmpty, error: ytsError, requiredAnswered: ytsAnswered) {
                return completion(nil, failure)
            }
            completion(merged, nil)
        }

        // YTS: the sort's queries, the current year first, each grid page
        // from where the last one stopped (`CatalogRollover`).
        let ytsDone = gate.source(required: true)
        let year = CatalogDates.year(of: Date())
        let queries = YTSCatalog.queries(filter: filter, genre: genre.ytsValue, searchTerm: searching ? term : nil, year: year)
        let segments: [CatalogRollover.Segment<Movie>] = queries.map { query in
            return { [weak self] first, done in
                guard let self = self else { return done(nil) }
                let pages = YTSCatalog.serverPages(filter: filter, searchTerm: searching ? term : nil, from: first)
                self.ytsList(query, pages: pages, order: order) { movies, hasMore, error in
                    guard let movies = movies else {
                        ytsError = error
                        return done(nil)
                    }
                    done(CatalogRollover.Batch(items: YTSCatalog.cleaned(movies, query: query, filter: filter),
                                               next: hasMore ? first + pages.count : nil))
                }
            }
        }
        let ytsLoaded: ([Movie]?) -> Void = { movies in
            ytsMovies = movies ?? []
            if movies != nil {
                ytsError = nil
                ytsAnswered = true
            } else {
                gate.failed()
            }
            ytsDone(!ytsMovies.isEmpty)
        }
        if searching {
            // One query, a page of it for each page of the grid.
            CatalogRollover.load(from: CatalogRollover.Cursor(segment: 0, page: max(page, 1)), segments: segments,
                                 minimum: 0) { movies, _ in ytsLoaded(movies) }
        } else {
            CatalogRollover.load(page: page, of: listKey, starts: pageStarts, segments: segments,
                                 minimum: filter == .rating ? YTSCatalog.topRatedMinimumPage : CatalogRollover.minimumPage,
                                 completion: ytsLoaded)
        }

        // Search: Cinemeta (every IMDb title) after T4P + YTS, so titles
        // neither catalog has are found too. Not paginated: page 1 only; its
        // results carry no genres: not with a genre filter.
        if searching, page <= 1, genre == .all {
            let cinemetaDone = gate.source(required: false)
            CinemetaClient.searchTitles(.movie, query: term, limit: 40) { metas in
                cinemeta = CinemetaStanding(metas)
                cinemetaMovies = YTSEZTVProvider.relevantCinemeta(metas, query: term).compactMap(Movie.init(cinemeta:))
                cinemetaDone(!cinemetaMovies.isEmpty)
            }
        }

        if withT4P {
            // Often mute: a search that found nothing elsewhere does not
            // wait the deadline for it.
            let t4pDone = gate.source(required: false, gracedWhenEmpty: searching)
            Time4PopcornClient.shared.movies(page: t4pPage, searchTerm: searching ? term : nil) { movies in
                guard var result = movies else {
                    t4pFailed = true
                    return t4pDone(false)
                }
                t4pMerged = true
                // T4P /list isn't genre-filtered and its `keywords` search can't
                // be relied on server-side, so filter client-side to keep the
                // grid on-genre and search results actually relevant.
                if searching {
                    result = result.filter { $0.title.localizedCaseInsensitiveContains(term) }
                }
                if genre != .all {
                    result = result.filter { YTSEZTVProvider.genres($0.genres, include: genre) }
                }
                t4pMovies = result
                t4pDone(!result.isEmpty)
            }
        }

        gate.start()
    }

    /// The error a list with nothing to show is delivered with: the
    /// required source's (YTS, the shows' base list) when it failed, a time
    /// out when it never answered. Nil when it answered with nothing: an
    /// empty list (« No results »), whatever optional source was left out —
    /// the list is still partial then (`lastListWasPartial`, a search's
    /// `incomplete`), so the same query may be sent again.
    static func failure(listIsEmpty: Bool, error: NSError?, requiredAnswered: Bool) -> NSError? {
        guard listIsEmpty else { return nil }
        if let error = error { return error }
        return requiredAnswered ? nil : timedOut
    }

    /// What a load answers when its deadline passed with nothing to show.
    private static var timedOut: NSError {
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                       userInfo: [NSLocalizedDescriptionKey: "Please check your internet connection and try again.".localized])
    }

    /// The movies of YTS pages `pages` of `query`, in page order (main
    /// queue), and whether the list goes on after them; nil with the error
    /// when no page could be read.
    private func ytsList(_ query: YTSCatalog.Query, pages: [Int], order: NetworkManager.Orders,
                         completion: @escaping (_ movies: [Movie]?, _ hasMore: Bool, NSError?) -> Void) {
        let group = DispatchGroup()
        var lists = [[Movie]?](repeating: nil, count: pages.count)
        var lastError: NSError?
        /// The query's `movie_count`, and how many films the last page held.
        var movieCount: Int?
        var lastPageCount = YTSCatalog.pageSize
        for (index, page) in pages.enumerated() {
            group.enter()
            attempt(path: Path.listMovies, params: query.parameters(page: page, order: order)) { data, error in
                defer { group.leave() }
                guard let data = data,
                      let root = (try? JSONSerialization.jsonObject(with: data, options: .allowFragments)) as? [String: Any] else {
                    lastError = error
                    return
                }
                if let apiStatus = root["status"] as? String, apiStatus != "ok" {
                    let msg = (root["status_message"] as? String) ?? "YTS error"
                    print("[YTS] ERROR: api status=\(apiStatus) message=\(msg)")
                    lastError = NSError(domain: "yts", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
                    return
                }
                let answer = YTSCatalog.listPage(root)
                if let count = answer.movieCount { movieCount = count }
                if index == pages.count - 1 { lastPageCount = answer.count }
                lists[index] = answer.movies
                print("[YTS] parsed \(answer.movies.count)/\(answer.count) movies (\(query.sortBy)\(query.year.map { " \($0)" } ?? "") page \(page))")
            }
        }
        group.notify(queue: .main) {
            let read = lists.compactMap { $0 }
            let hasMore = YTSCatalog.hasMore(after: pages.last ?? 1, movieCount: movieCount, pageCount: lastPageCount)
            completion(read.isEmpty ? nil : read.flatMap { $0 }, hasMore, read.isEmpty ? lastError : nil)
        }
    }

    /// A YTS answer: a JSON object with a `status`, and its `data` when the
    /// status is "ok". (Any 2xx used to do: a parked mirror's HTML page made
    /// it the preferred host, and YTS vanished without a word.)
    static func isYTSAnswer(_ data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = root["status"] as? String else { return false }
        return status != "ok" || root["data"] is [String: Any]
    }

    /// An EZTV answer: a JSON object with `torrents_count` or `torrents`.
    static func isEZTVAnswer(_ data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return root["torrents_count"] != nil || root["torrents"] is [Any]
    }

    /// Why a request failed, for `MirrorHealth`.
    private static func failure(_ error: AFError, status: Int) -> MirrorFailure {
        if status >= 400 { return .http(status) }
        let unreachable: Set<Int> = [
            NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
            NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateHasBadDate,
        ]
        let code = (error.underlyingError as NSError?)?.code ?? (error as NSError).code
        if unreachable.contains(code) { return .unreachable }
        return code == NSURLErrorTimedOut ? .timedOut : .other
    }

    /// One GET to a mirror chain (`MirrorRace`): the first valid answer, or
    /// nil with the last error. Main queue.
    private func race(_ name: String, mirrors: [String], health: MirrorHealth, path: String, params: [String: Any],
                      validate: @escaping (Data) -> Bool, completion: @escaping (Data?, NSError?) -> Void) {
        let session = self.session
        MirrorRace.run(hosts: health.ordered(mirrors), health: health, validate: validate, transport: { host, answer in
            let url = host + path
            print("[\(name)] GET \(url) params=\(params)")
            let request = session.request(url, parameters: params).validate().responseData { response in
                let status = response.response?.statusCode ?? -1
                switch response.result {
                case .success(let data):
                    print("[\(name)] \(host) status=\(status) bytes=\(data.count)")
                    answer(.data(data))
                case .failure(let error):
                    if error.isExplicitlyCancelledError { return answer(.failure(.other, nil)) }
                    let nserr = error.underlyingError as NSError? ?? (error as NSError)
                    print("[\(name)] \(host) FAILED status=\(status) code=\(nserr.code) err=\(nserr.localizedDescription)")
                    answer(.failure(YTSEZTVProvider.failure(error, status: status), nserr))
                }
            }
            return { request.cancel() }
        }, completion: { data, error in
            if data == nil { print("[\(name)] no mirror answered: \(error?.localizedDescription ?? "-")") }
            completion(data, error)
        })
    }

    /// A YTS request, to the mirrors.
    private func attempt(path: String, params: [String: Any], completion: @escaping (Data?, NSError?) -> Void) {
        race("YTS", mirrors: YTSEZTVProvider.ytsMirrors, health: ytsHealth, path: path, params: params,
             validate: YTSEZTVProvider.isYTSAnswer, completion: completion)
    }

    public func getMovieInfo(imdbId: String, completion: @escaping (Movie?, NSError?) -> Void) {
        getMovieInfo(imdbId: imdbId, extraSources: true, completion: completion)
    }

    /// `extraSources` false: no The Pirate Bay / Knaben search (posters and
    /// metadata only, e.g. the Continue Watching row: a burst of searches for
    /// torrents nobody looks at).
    ///
    /// The movie once every source has answered: the last record and the
    /// complete list of `loadMovieDetail`.
    public func getMovieInfo(imdbId: String, extraSources: Bool, completion: @escaping (Movie?, NSError?) -> Void) {
        var record: Movie?
        var lists = MovieSources()
        loadMovieDetail(imdbId: imdbId, extraSources: extraSources) { event in
            switch event {
            case .metadata(let media):
                record = media as? Movie
            case .movieSources(let answered):
                lists = answered
            case .showSources:
                break
            case .finished(let error):
                guard var movie = record else { return completion(nil, error) }
                let merge = lists.merge()
                movie.torrents = merge.torrents
                print("[YTS+Torrentio+T4P+TPB/Knaben] \(imdbId): \((lists.ytsKnowsTitle ? lists.yts : lists.time4Popcorn).count) base + \(lists.torrentio.count) aggregated + \(lists.time4Popcorn.count) t4p + \(merge.novelExtra)/\(lists.extra.count) new extra -> \(merge.torrents.count) torrents")
                completion(movie, nil)
            }
        }
    }

    /// A movie's page, as its sources answer (`DetailEvent`, main queue):
    /// its record from the first source that has it, then from a better
    /// one; its torrent lists one by one; then `finished`.
    ///
    /// YTS (curated qualities, rich metadata), the Torrentio aggregator (a
    /// dozen extra indexers — REMUX, HDR, multi-audio) and the Time4Popcorn
    /// backend (extra scraped releases) are asked in parallel, their
    /// torrents merged by info-hash (`MovieSources.merged`).
    ///
    /// The Pirate Bay and Knaben (`ExtraTorrentSources`) are searched by
    /// "Title Year" for every distinct title + year YTS, T4P and Cinemeta
    /// give, as each answers — and for `hint`, what the caller already
    /// knows, at once; once YTS, Torrentio and T4P are in, they get at most
    /// `ExtraTorrentSources.grace` more, then what arrived is filtered with
    /// every source's titles and years. Cinemeta (fast, but optional) also
    /// stands in for the metadata of a title neither YTS nor T4P has (found
    /// by the Cinemeta search): only then is it waited for.
    ///
    /// - Parameters:
    ///   - extraSources: false leaves The Pirate Bay / Knaben out.
    ///   - gate: a prewarm's (`DetailGate`): The Pirate Bay and Knaben are
    ///     searched once it opens — a page reads the load —, the other
    ///     sources at once.
    public func loadMovieDetail(imdbId: String, extraSources: Bool = true, hint: (title: String, year: Int)? = nil,
                                gate: DetailGate? = nil, update: @escaping (DetailEvent) -> Void) {
        // Strings, not Bool: Alamofire sends `true` as "1", which YTS ignores
        // (no cast came back).
        let params: [String: Any] = [
            "imdb_id":     imdbId,
            "with_images": "true",
            "with_cast":   "true",
        ]

        // Everything below runs on the main queue (Alamofire, Torrentio and
        // T4P call back there; Cinemeta hops to it).
        var lists = MovieSources()
        if !extraSources { lists.missing.removeAll { $0 == .extra } }
        var ytsMovie: Movie?
        var ytsTitles: [String] = []
        var ytsError: NSError?
        var t4pMovie: Movie?
        var cinemetaMeta: [String: Any]?
        var cinemetaDone = false
        /// The source of the record told last: 1 Cinemeta, 2 Time4Popcorn, 3 YTS.
        var toldRank = 0
        var coreIsIn = false
        let search = extraSources ? ExtraTorrentSources.shared.movieSearch(imdbId: imdbId) : nil
        /// A title and year to search, once the gate (if any) is open.
        func offer(title: String?, year: Int?, yearIsReliable: Bool = true) {
            guard let search = search else { return }
            let send = { search.offer(title: title, year: year, yearIsReliable: yearIsReliable) }
            if let gate = gate { gate.whenOpen(send) } else { send() }
        }
        // The caller's title and year are a list's, like Cinemeta's: the
        // year may be a later release's.
        if let hint = hint { offer(title: hint.title, year: hint.year, yearIsReliable: false) }

        // Prefer YTS's richer metadata, but fall back to T4P's so a T4P-only
        // title (absent from YTS) is still openable, then to Cinemeta's (a
        // title only the Cinemeta search found).
        func record() -> (movie: Movie, rank: Int)? {
            if let movie = ytsMovie { return (movie, 3) }
            if let movie = t4pMovie { return (movie, 2) }
            if let movie = cinemetaMeta.flatMap(Movie.init(cinemeta:)) { return (movie, 1) }
            return nil
        }
        func tellRecordIfBetter() {
            guard let best = record(), best.rank > toldRank else { return }
            toldRank = best.rank
            update(.metadata(best.movie))
        }
        func tellLists() {
            // The runtime on every candidate: with their sizes it gives the
            // bitrates, so the merge's slots go to the releases the
            // connection carries (`precedesInListing`).
            lists.runtime = record().flatMap { Torrent.mediaRuntime(of: $0.movie) } ?? t4pMovie.flatMap { Torrent.mediaRuntime(of: $0) }
            update(.movieSources(lists))
        }
        func finishIfCoreIsIn() {
            guard !coreIsIn, !lists.missing.contains(where: { $0 != .extra }) else { return }
            // Only Cinemeta can name it.
            if ytsMovie == nil, t4pMovie == nil, !cinemetaDone { return }
            coreIsIn = true
            guard let base = record()?.movie else { return update(.finished(ytsError)) }
            guard let search = search else { return update(.finished(nil)) }
            // A prewarm stops here until a page reads it: the searches its
            // offers held start then, and this waits for them.
            let park: (@escaping () -> Void) -> Void = { block in
                if let gate = gate { gate.parkUntilOpen(block) } else { block() }
            }
            park {
                // Every source's title and year count: they don't always agree
                // (Amélie: 2001 on YTS, 2002 on Cinemeta). Read when the
                // searches are in: Cinemeta may have answered meanwhile.
                search.finish(identity: {
                    var titles: [String] = []
                    for title in [base.title] + ytsTitles + [t4pMovie?.title, cinemetaMeta?["name"] as? String].compactMap({ $0 })
                        where !title.isEmpty && !titles.contains(title) {
                        titles.append(title)
                    }
                    let years = Set([base.year, t4pMovie?.year ?? "", (cinemetaMeta?["releaseInfo"] as? String) ?? ""]
                        .compactMap { Int($0.prefix(4)) }.filter { $0 > 0 })
                    return ReleaseMatch.MovieIdentity(titles: titles, years: years, imdbId: imdbId)
                }, completion: { extra in
                    lists.extra = extra
                    lists.missing.removeAll { $0 == .extra }
                    tellLists()
                    update(.finished(nil))
                })
            }
        }
        func answered(_ provider: MovieSources.Provider, failed: Bool) {
            lists.missing.removeAll { $0 == provider }
            if failed { lists.failed.append(provider) }
            tellRecordIfBetter()
            tellLists()
            finishIfCoreIsIn()
        }

        CinemetaClient.meta(.movie, imdbId: imdbId) { meta in
            DispatchQueue.main.async {
                // A series asked as a movie comes back with a "2025–" range.
                if let meta = meta, let info = meta["releaseInfo"] as? String, info.count == 4 {
                    cinemetaMeta = meta
                    offer(title: meta["name"] as? String, year: Int(info), yearIsReliable: false)
                }
                cinemetaDone = true
                tellRecordIfBetter()
                finishIfCoreIsIn()
            }
        }

        detailsRequestBegan(imdbId)
        attempt(path: Path.movieInfo, params: params) { data, error in
            var known: [String: Any]?
            defer {
                self.detailsRequestEnded(imdbId, movie: known)
                answered(.yts, failed: data == nil)
            }
            guard let data = data else { ytsError = error; return }
            guard
                let json    = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                let root    = json as? [String: Any],
                let payload = root["data"] as? [String: Any],
                let movie   = payload["movie"] as? [String: Any]
            else { return }
            ytsMovie = Movie(yts: movie)
            lists.yts = ytsMovie?.torrents ?? []
            lists.ytsKnowsTitle = ytsMovie != nil
            if (movie["id"] as? Int ?? 0) > 0 {   // 0 = a title YTS doesn't have
                known = movie
                ytsTitles = [movie["title"], movie["title_english"]].compactMap { $0 as? String }
                offer(title: movie["title"] as? String, year: movie["year"] as? Int)
            }
        }

        TorrentioClient.shared.streamsAnswer(imdbId: imdbId) { torrents in
            lists.torrentio = torrents ?? []
            answered(.torrentio, failed: torrents == nil)
        }

        Time4PopcornClient.shared.movieDetailAnswer(imdbId: imdbId) { movie, torrents, reached in
            t4pMovie = movie
            lists.time4Popcorn = torrents
            offer(title: movie?.title, year: movie.flatMap { Int($0.year) })
            answered(.time4Popcorn, failed: !reached)
        }
    }

    // MARK: - Search ranking

    /// The Cinemeta search results worth adding to a search: real titles
    /// only (a start year, at most next year: no bare stub, nothing merely
    /// announced); Cinemeta's first three (its most popular matches, alternate
    /// titles included: "l'odyssée" finds "The Odyssey"), then those whose
    /// title holds every word searched (accents and punctuation ignored), in
    /// Cinemeta's order; ten at most. Loosely related titles further down
    /// ("la haine" → "The Hate U Give") are left out.
    static func relevantCinemeta(_ metas: [[String: Any]], query: String) -> [[String: Any]] {
        let wanted = Set(ReleaseMatch.words(query))
        let nextYear = Calendar(identifier: .gregorian).component(.year, from: Date()) + 1
        let real = metas.filter { meta in
            guard let year = CinemetaMatching.startYear(meta), (1880...nextYear).contains(year) else { return false }
            return meta["name"] is String
        }
        var result: [[String: Any]] = []
        for (index, meta) in real.enumerated() where result.count < 10 {
            let name = meta["name"] as? String ?? ""
            if index < 3 || (!wanted.isEmpty && wanted.isSubset(of: ReleaseMatch.words(name))) { result.append(meta) }
        }
        return result
    }

    /// Search results with the titles that are exactly what was typed first,
    /// then those that start with it, then the rest: "hope" lists "Hope"
    /// (2026) before "Hope Floats" and "Grace and Hope". A title counts under
    /// its other names too (`aliases`: Cinemeta's name of the same IMDb id;
    /// YTS lists the 2021 "Dune" as "Dune: Part One"). Within each of the
    /// three, the titles `rank` knows come first, best rank first (their
    /// place in Cinemeta's answer, its most popular matches first: "dune"
    /// lists the 2021 film before the 1984 one), then the others in their
    /// order (the catalogs' own: most downloaded / most seeded first).
    static func exactFirst<Item>(_ items: [Item], query: String, title: (Item) -> String,
                                 aliases: (Item) -> [String] = { _ in [] },
                                 rank: (Item) -> Int? = { _ in nil }) -> [Item] {
        let wanted = ReleaseMatch.titleWords(query)
        guard !wanted.isEmpty else { return items }
        func tier(_ name: String) -> Int {
            let words = ReleaseMatch.titleWords(name)
            if words == wanted { return 0 }
            if words.starts(with: wanted) { return 1 }
            return 2
        }
        let keyed = items.enumerated().map { entry -> (tier: Int, rank: Int, offset: Int, item: Item) in
            let best = ([title(entry.element)] + aliases(entry.element)).map(tier).min() ?? 2
            return (best, rank(entry.element) ?? Int.max, entry.offset, entry.element)
        }
        return keyed
            .sorted { ($0.tier, $0.rank, $0.offset) < ($1.tier, $1.rank, $1.offset) }
            .map(\.item)
    }

    /// What Cinemeta's search says of the titles found: their place in its
    /// answer (most popular first) and the name it gives them, by IMDb id.
    private struct CinemetaStanding {
        var ranks: [String: Int] = [:]
        var names: [String: String] = [:]

        init(_ metas: [[String: Any]] = []) {
            for (index, meta) in metas.enumerated() {
                guard let id = CinemetaMatching.id(meta), ranks[id] == nil else { continue }
                ranks[id] = index
                names[id] = meta["name"] as? String
            }
        }
    }

    // MARK: - Shows (Cinemeta, EZTV + TVMaze)

    /// Catalog entry point.
    ///
    /// - Search: TVMaze's full-text search and Cinemeta's (EZTV has no
    ///   search API), with Time4Popcorn's. Torrents are resolved later by
    ///   `getShowInfo` when a result is opened.
    /// - Browse: one page of a Cinemeta catalog (`showsCatalog`), with
    ///   Time4Popcorn's most seeded list in front of "Popular"; "Recently
    ///   Added" is EZTV's latest releases grouped by show (`latestReleases`).
    public func loadShows(page: Int,
                          filter: ShowManager.Filters,
                          genre: NetworkManager.Genres,
                          searchTerm: String?,
                          order: NetworkManager.Orders,
                          completion: @escaping ([Show]?, NSError?) -> Void) {
        let term = (searchTerm ?? "").trimmingCharacters(in: .whitespaces)
        let searching = !term.isEmpty

        // Top 100: The Pirate Bay's most seeded shows, mapped to IMDb titles.
        // A search typed while it is selected searches the catalog as usual.
        if filter == .top100, !searching {
            return PirateBayTop100.shared.shows(page: page, genre: genre, completion: completion)
        }

        var baseShows: [Show] = []
        var baseError: NSError?
        var t4pShows: [Show] = []
        var cinemetaShows: [Show] = []
        var cinemeta = CinemetaStanding()

        // Time4Popcorn's list is always "most seeded": in front of "Popular"
        // and in searches only (see `loadMovies`).
        let withT4P = searching || filter == .popularity
        let listKey = CatalogSnapshotStore.key(kind: "shows", filter: filter.rawValue, genre: genre.rawValue, order: order)
        // Its page: the grid's, unless an earlier page went without it (see
        // `loadMovies`).
        let t4pPage = searching || page <= 1 ? max(page, 1) : (t4pPages.start(of: page, in: listKey) ?? page)
        var t4pMerged = false
        var t4pFailed = false
        /// "Recently Added" misses shows whose lookups were not in on time.
        var baseIsPartial = false
        // TVMaze's search isn't paginated: later pages of a search come from
        // Time4Popcorn's paginated catalog alone.
        let withBase = !searching || page <= 1
        /// The required source (the base list, else Time4Popcorn for a
        /// search's later pages) answered, if only with nothing.
        var requiredAnswered = false

        let gate = SourceGate(grace: searching ? SourceGate.searchGrace : SourceGate.browseGrace) { complete in
            var seen = Set<String>()
            var merged: [Show] = []
            for show in t4pShows + baseShows + cinemetaShows where seen.insert(show.id).inserted {
                merged.append(show)
            }
            if searching, page <= 1 {
                merged = YTSEZTVProvider.exactFirst(merged, query: term, title: { $0.title },
                                                    aliases: { cinemeta.names[$0.id].map { [$0] } ?? [] },
                                                    rank: { cinemeta.ranks[$0.id] })
            }
            print("[Shows] \(filter.rawValue): T4P \(t4pShows.count) + base \(baseShows.count) + Cinemeta \(cinemetaShows.count) -> \(merged.count) (page \(page)\(complete ? "" : ", a source left out"))")
            if withT4P, !searching {
                self.t4pPages.set(t4pMerged ? t4pPage + 1 : t4pPage, of: max(page, 1) + 1, in: listKey)
            }
            self.lastListWasPartial = !complete || t4pFailed || baseIsPartial
            if let failure = YTSEZTVProvider.failure(listIsEmpty: merged.isEmpty, error: baseError, requiredAnswered: requiredAnswered) {
                return completion(nil, failure)
            }
            completion(merged, nil)
        }

        if withBase {
            let baseDone = gate.source(required: true)
            let deliver: ([Show]?, NSError?) -> Void = { shows, error in
                baseShows = shows ?? []
                baseError = shows == nil ? error : nil
                if shows != nil { requiredAnswered = true } else { gate.failed() }
                baseDone(!baseShows.isEmpty)
            }
            if searching {
                searchShows(term, completion: deliver)
            } else if filter == .date {
                latestReleases(page: page, genre: genre) { shows, error, partial in
                    baseIsPartial = partial
                    deliver(shows, error)
                }
            } else {
                showsCatalog(page: page, filter: filter, genre: genre, list: listKey, completion: deliver)
            }
        }

        // Search: Cinemeta's series (every IMDb title) beside TVMaze's.
        // Page 1 only, and not with a genre filter (no genres in its results).
        if searching, page <= 1, genre == .all {
            let cinemetaDone = gate.source(required: false)
            CinemetaClient.searchTitles(.series, query: term, limit: 40) { metas in
                cinemeta = CinemetaStanding(metas)
                cinemetaShows = YTSEZTVProvider.relevantCinemeta(metas, query: term).compactMap(Show.init(cinemeta:))
                cinemetaDone(!cinemetaShows.isEmpty)
            }
        }

        if withT4P {
            // The only source of a search's later pages: waited for.
            let t4pDone = gate.source(required: !withBase, gracedWhenEmpty: searching)
            Time4PopcornClient.shared.shows(page: t4pPage, searchTerm: searching ? term : nil) { shows in
                guard var result = shows else {
                    t4pFailed = true
                    return t4pDone(false)
                }
                t4pMerged = true
                if !withBase { requiredAnswered = true }
                if searching {
                    result = result.filter { $0.title.localizedCaseInsensitiveContains(term) }
                }
                if genre != .all {
                    result = result.filter { YTSEZTVProvider.genres($0.genres, include: genre) }
                }
                t4pShows = result
                t4pDone(!result.isEmpty)
            }
        }

        gate.start()
    }

    /// One page of the Shows grid from Cinemeta's catalogs (main queue), in
    /// one request (two for "Top Rated"), about 0.1 s each:
    ///
    /// - Trending, A - Z: "top", the popular series of the moment (A - Z
    ///   sorts the page by title);
    /// - Popular: "imdbRating", Stremio's "Featured" list (series on air),
    ///   behind Time4Popcorn's most seeded;
    /// - Top Rated: the best rated of two pages of "top";
    /// - New: the year's series by premiere, newest first, then last year's
    ///   (`CatalogRollover`, `list` being the list's key). The genre is
    ///   filtered here (the catalog's only extra holds the year): the year
    ///   is then read four pages at a time, and last year's only after it.
    ///   (One page of 50 was filtered: 0 to 15 posters, none for War, and
    ///   last year's first page in front of the rest of the year.)
    ///
    /// A genre Cinemeta does not have: no result. (The grid used to be one
    /// page of EZTV's latest torrents sorted again locally, about 30 shows,
    /// for one TVMaze lookup a show.)
    private func showsCatalog(page: Int, filter: ShowManager.Filters, genre: NetworkManager.Genres, list: String,
                              completion: @escaping ([Show]?, NSError?) -> Void) {
        let finish: ([Show]?) -> Void = { shows in
            DispatchQueue.main.async { completion(shows, shows == nil ? YTSEZTVProvider.cinemetaUnreachable : nil) }
        }
        if genre != .all, genre.cinemetaValue == nil { return finish([]) }
        let genreValue = genre.cinemetaValue

        /// Catalog pages at `skips`, in order; nil when none could be read.
        /// `more`: none came back empty, the catalog goes on (a page can be
        /// one title short of 50 before the last: only an empty one ends it).
        func pages(_ feed: CinemetaClient.Feed, genre: String?, skips: [Int],
                   completion: @escaping (_ metas: [[String: Any]]?, _ more: Bool) -> Void) {
            let group = DispatchGroup()
            let lock = NSLock()
            var lists = [[[String: Any]]?](repeating: nil, count: skips.count)
            for (index, skip) in skips.enumerated() {
                group.enter()
                CinemetaClient.catalog(.series, feed, genre: genre, skip: skip) { metas in
                    lock.lock()
                    lists[index] = metas
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                let read = lists.compactMap { $0 }
                completion(read.isEmpty ? nil : read.flatMap { $0 }, !lists.contains { $0?.isEmpty == true })
            }
        }

        switch filter {
        case .trending, .top100, .date:
            pages(.top, genre: genreValue, skips: ShowCatalog.skips(page: page)) { metas, _ in
                finish(metas?.compactMap(Show.init(cinemeta:)))
            }
        case .name:
            pages(.top, genre: genreValue, skips: ShowCatalog.skips(page: page)) { metas, _ in
                finish(metas.map { ShowCatalog.alphabetical($0.compactMap(Show.init(cinemeta:))) })
            }
        case .popularity:
            pages(.featured, genre: genreValue, skips: ShowCatalog.skips(page: page)) { metas, _ in
                finish(metas?.compactMap(Show.init(cinemeta:)))
            }
        case .rating:
            pages(.top, genre: genreValue, skips: ShowCatalog.skips(page: page, catalogPages: ShowCatalog.topRatedCatalogPages)) { metas, _ in
                finish(metas.map { ShowCatalog.topRated($0.compactMap(Show.init(cinemeta:))) })
            }
        case .year:
            let now = Date()
            let year = CatalogDates.year(of: now)
            let atATime = genre == .all ? 1 : ShowCatalog.newInGenreCatalogPages
            let segments: [CatalogRollover.Segment<Show>] = [year, year - 1].map { year in
                return { first, done in
                    pages(.year, genre: String(year), skips: ShowCatalog.skips(from: first, count: atATime)) { metas, more in
                        guard var metas = metas else { return done(nil) }
                        metas = ShowCatalog.premiered(metas, now: now)
                        if genre != .all { metas = Top100Resolver.filter(metas, genre: genre.rawValue) }
                        done(CatalogRollover.Batch(items: metas.compactMap(Show.init(cinemeta:)),
                                                   next: more ? first + atATime : nil))
                    }
                }
            }
            CatalogRollover.load(page: page, of: list, starts: pageStarts, segments: segments, completion: finish)
        }
    }

    private static var cinemetaUnreachable: NSError {
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                       userInfo: [NSLocalizedDescriptionKey: "Please check your internet connection and try again.".localized])
    }

    /// What "Recently Added" leaves of its time to put the list together
    /// once the shows are named…
    static var assemblyReserve: TimeInterval = 0.5
    /// …and to the alternate titles, out of what naming the shows may take.
    static var alternateTitlesReserve: TimeInterval = 1.5

    /// How long naming the shows of "Recently Added" may take when `left`
    /// seconds remain before the list must be delivered.
    static func namingBudget(left: TimeInterval) -> TimeInterval {
        return min(TVMazeShowDirectory.deadline, max(0, left - alternateTitlesReserve))
    }

    /// "Recently Added": the shows of one page of EZTV's latest torrents
    /// (100 releases, about half a day), the latest release first. Main queue.
    ///
    /// The list is waited for `SourceGate.deadline` seconds and dropped when
    /// it lands later: EZTV's answer, the shows' names and their alternate
    /// titles share that time, so a slow lookup shortens the page instead of
    /// failing it. `partial`: shows were left out for that reason. (The
    /// steps had their own deadlines, 10 + 6 + 3 s: a first visit with one
    /// slow answer was an error, and the list built two seconds later was
    /// thrown away.)
    private func latestReleases(page: Int, genre: NetworkManager.Genres,
                                completion: @escaping ([Show]?, NSError?, _ partial: Bool) -> Void) {
        let until = Date().addingTimeInterval(SourceGate.deadline - YTSEZTVProvider.assemblyReserve)
        let params: [String: Any] = ["limit": 100, "page": max(page, 1)]
        attemptEztv(path: "/api/get-torrents", params: params) { [weak self] data, error in
            guard let self = self else { return completion(nil, error, false) }
            guard
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                let root = json as? [String: Any],
                let raw  = root["torrents"] as? [[String: Any]]
            else {
                print("[EZTV] no torrents in the answer")
                // An answer without `torrents`: past the last page.
                return completion(data == nil ? nil : [], error, false)
            }
            print("[EZTV] got \(raw.count) torrents")
            self.buildShows(from: raw, genre: genre, until: until) { shows, partial in completion(shows, nil, partial) }
        }
    }

    private func searchShows(_ term: String, completion: @escaping ([Show]?, NSError?) -> Void) {
        let url = "https://api.tvmaze.com/search/shows"
        session.request(url, parameters: ["q": term]).validate().responseData { response in
            switch response.result {
            case .failure(let error):
                DispatchQueue.main.async { completion(nil, error.underlyingError as NSError? ?? error as NSError) }
            case .success(let data):
                var shows: [Show] = []
                if let json = try? JSONSerialization.jsonObject(with: data),
                   let results = json as? [[String: Any]] {
                    for result in results {
                        guard
                            let dict = result["show"] as? [String: Any],
                            let imdb = (dict["externals"] as? [String: Any])?["imdb"] as? String,
                            let show = Show(tvmaze: dict, imdbId: imdb)
                        else { continue }
                        shows.append(show)
                    }
                }
                print("[TVMaze] search '\(term)' -> \(shows.count) shows")
                DispatchQueue.main.async { completion(shows, nil) }
            }
        }
    }

    /// An EZTV request, to the mirrors.
    private func attemptEztv(path: String, params: [String: Any], completion: @escaping (Data?, NSError?) -> Void) {
        race("EZTV", mirrors: YTSEZTVProvider.eztvMirrors, health: eztvHealth, path: path, params: params,
             validate: YTSEZTVProvider.isEZTVAnswer, completion: completion)
    }

    /// Assemble the complete detail-page payload for one show:
    ///
    ///   1. The show's record (`TVMazeShowDirectory`: TVMaze's
    ///      `lookup/shows?imdb=`, kept on disk) — canonical metadata + TVMaze id.
    ///   2. TVMaze `shows/{id}/episodes` — the FULL episode guide (titles,
    ///      summaries, stills, air dates) for every season.
    ///   3. EZTV `get-torrents?imdb_id=` — every torrent the indexer has for
    ///      the show (paginated), merged into the guide per episode.
    ///
    /// Episodes without a torrent are kept: the play flow falls back to the
    /// Torrentio aggregator at click time, which covers most catalog gaps.
    ///
    /// A page built less than `showLifetime` ago is served as it is. Past
    /// that it is built again; when that fails (offline), the older page is
    /// served rather than nothing.
    ///
    /// The show once everything has answered: the complete show of
    /// `loadShowDetail`.
    public func getShowInfo(imdbId: String, completion: @escaping (Show?, NSError?) -> Void) {
        var complete: Show?
        loadShowDetail(imdbId: imdbId) { event in
            switch event {
            case .metadata, .movieSources:
                break
            case .showSources(let show):
                complete = show
            case .finished(let error):
                completion(complete, error)
            }
        }
    }

    /// A show's page, as its sources answer (`DetailEvent`, main queue):
    /// its record (`metadata`), the same with its episode guide (`metadata`
    /// again: the page has its seasons and can play), then the complete
    /// show, EZTV's torrents attached to its episodes (`showSources`), then
    /// `finished`. See `getShowInfo` for what is asked. A show kept from an
    /// earlier call tells all of it at once. `gate`: a prewarm's
    /// (`DetailGate`) — EZTV's pages are walked once it opens, the record
    /// and the guide are asked at once.
    public func loadShowDetail(imdbId: String, gate: DetailGate? = nil, update: @escaping (DetailEvent) -> Void) {
        if let cached = showCache.fresh(imdbId) {
            DispatchQueue.main.async {
                update(.metadata(cached))
                update(.showSources(cached))
                update(.finished(nil))
            }
            return
        }

        /// EZTV's pages: the load's last step, held by a prewarm's gate.
        let walkEZTV: (@escaping () -> Void) -> Void = { block in
            if let gate = gate { gate.parkUntilOpen(block) } else { block() }
        }

        /// The end: the complete show when there is one.
        let finish: (Show?) -> Void = { show in
            if let show = show { update(.showSources(show)) }
            update(.finished(nil))
        }

        TVMazeShowDirectory.shared.record(imdbId) { [weak self] lookup in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // A record without a TVMaze id was built from Cinemeta's meta.
                var tvmaze: [String: Any]?
                if case .known(let record) = lookup, record["id"] is Int { tvmaze = record }
                guard let tvmaze = tvmaze, var show = Show(tvmaze: tvmaze, imdbId: imdbId, episodes: []) else {
                    // TVMaze doesn't know it (a series only Cinemeta lists, a
                    // new one in its first days): Cinemeta's own episode
                    // list, with EZTV's torrents. ("Recently Added" lists
                    // such a series from its EZTV releases: its page showed
                    // none of them, and not the episode Cinemeta had not
                    // listed yet.)
                    var listed: Show?
                    var cinemetaAnswered = false
                    var torrentEntries: [[String: Any]]?
                    var delivered = false
                    // Both on the main queue.
                    let deliver: () -> Void = {
                        guard !delivered, cinemetaAnswered else { return }
                        guard var show = listed else {
                            // Cinemeta has no such series either: no page,
                            // whatever EZTV files under the id.
                            delivered = true
                            return finish(self.showCache.any(imdbId)?.value)
                        }
                        guard let entries = torrentEntries else { return }
                        delivered = true
                        // No alternate titles without TVMaze: the releases
                        // named after the title (as in `buildShows`).
                        var bare = show
                        bare.episodes = []
                        let released = self.mergedEpisodes(guide: [], eztvEntries: entries, show: bare, titles: [show.title])
                        show.episodes = YTSEZTVProvider.episodes(show.episodes, withTorrentsOf: released)
                        guard !show.episodes.isEmpty else { return finish(self.showCache.any(imdbId)?.value) }
                        print("[EZTV] getShowInfo \(imdbId): Cinemeta's guide, torrents=\(entries.count) episodes=\(show.episodes.count)")
                        self.showCache.set(show, for: imdbId)
                        finish(show)
                    }
                    self.cinemetaShow(imdbId: imdbId) { show in
                        listed = show
                        cinemetaAnswered = true
                        // The record and Cinemeta's guide: the page has its
                        // seasons before EZTV has answered.
                        if let show = show, !delivered { update(.metadata(show)) }
                        deliver()
                    }
                    walkEZTV {
                        self.fetchAllEztvTorrents(imdbId: imdbId) { entries in
                            torrentEntries = entries
                            deliver()
                        }
                    }
                    return
                }

                // The record: network, runtime, summary — before the guide.
                update(.metadata(show))

                let group = DispatchGroup()
                var guide: [[String: Any]] = []
                var torrentEntries: [[String: Any]] = []
                // EZTV may name the releases after an alternate title ("The
                // Doll" for "Lalka"): those count as the show's too.
                var titles = [show.title]
                var akasKnown = false
                var isComplete = false

                if let tvmazeId = tvmaze["id"] as? Int {
                    group.enter()
                    self.fetchTVMazeEpisodes(tvmazeId: tvmazeId) { episodes in
                        guide = episodes
                        // The guide alone: the seasons and the episodes,
                        // their torrents to come.
                        if !episodes.isEmpty, !isComplete {
                            var guided = show
                            guided.episodes = self.mergedEpisodes(guide: episodes, eztvEntries: [], show: show, titles: [])
                            update(.metadata(guided))
                        }
                        group.leave()
                    }
                    group.enter()
                    self.fetchTVMazeAkas(imdbId: imdbId, tvmazeId: tvmazeId) { akas in
                        if let akas = akas {
                            titles += akas
                            akasKnown = true
                        }
                        group.leave()
                    }
                }

                group.enter()
                walkEZTV {
                    self.fetchAllEztvTorrents(imdbId: imdbId) { entries in
                        torrentEntries = entries
                        group.leave()
                    }
                }

                group.notify(queue: .main) {
                    isComplete = true
                    // Neither the guide nor a torrent (the network dropped):
                    // the page built earlier, when there is one.
                    if guide.isEmpty, torrentEntries.isEmpty, let older = self.showCache.any(imdbId)?.value {
                        print("[EZTV] getShowInfo \(imdbId): nothing could be loaded, serving the earlier page")
                        return finish(older)
                    }
                    // Alternate titles unknown (request failed) while the title
                    // alone would drop releases: they may be named after one of
                    // them ("Money Heist"), so keep them all this time and don't
                    // cache the show: the next opening asks again.
                    let complete = akasKnown || YTSEZTVProvider.releases(torrentEntries, of: titles).count == torrentEntries.count
                    show.episodes = self.mergedEpisodes(guide: guide, eztvEntries: torrentEntries, show: show,
                                                        titles: complete ? titles : [])
                    if complete { self.showCache.set(show, for: imdbId) }
                    TVMazeShowDirectory.shared.save()
                    print("[EZTV] getShowInfo \(imdbId): guide=\(guide.count) torrents=\(torrentEntries.count) episodes=\(show.episodes.count)")
                    finish(show)
                }
            }
        }
    }

    /// A show TVMaze doesn't know, from Cinemeta: its meta and its episode
    /// list (`videos`: season, episode, name, release date, overview,
    /// thumbnail; specials left out), which may be empty. Main queue.
    private func cinemetaShow(imdbId: String, completion: @escaping (Show?) -> Void) {
        CinemetaClient.seriesWithEpisodes(imdbId: imdbId) { meta in
            guard let meta = meta, var show = Show(cinemeta: meta) else { return completion(nil) }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoPlain = ISO8601DateFormatter()
            var episodes: [Episode] = []
            var seen = Set<String>()
            for video in (meta["videos"] as? [[String: Any]]) ?? [] {
                guard let season = video["season"] as? Int, season > 0,
                      let number = (video["episode"] as? Int) ?? (video["number"] as? Int), number > 0,
                      seen.insert("\(season)x\(number)").inserted else { continue }
                let name = ((video["name"] as? String) ?? (video["title"] as? String) ?? "Episode \(number)").removingHtmlEncoding
                let released = (video["released"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
                var episode = Episode(
                    title: name,
                    id: "\(show.id)-s\(season)e\(number)",
                    slug: name.slugged,
                    summary: ((video["overview"] as? String) ?? (video["description"] as? String) ?? "No summary available.".localized).strippedOfHtml,
                    largeBackgroundImage: video["thumbnail"] as? String,
                    show: show,
                    episode: number,
                    season: season,
                    firstAirDate: released ?? .distantPast)
                episode.show = show
                episodes.append(episode)
            }
            episodes.sort { $0.season == $1.season ? $0.episode < $1.episode : $0.season < $1.season }
            show.episodes = episodes
            print("[Cinemeta] getShowInfo \(imdbId): TVMaze doesn't know it, \(episodes.count) episodes from Cinemeta")
            completion(show)
        }
    }

    /// A guide's episodes with the torrents of `released`, the episodes a
    /// torrent list makes (`mergedEpisodes` without a guide): each episode
    /// of the guide gets its releases' torrents, and a released episode the
    /// guide does not list yet is added. By season, then episode.
    static func episodes(_ guide: [Episode], withTorrentsOf released: [Episode]) -> [Episode] {
        var merged = guide
        var positions: [String: Int] = [:]
        for (position, episode) in guide.enumerated() {
            positions["\(episode.season)x\(episode.episode)"] = position
        }
        for release in released {
            if let position = positions["\(release.season)x\(release.episode)"] {
                merged[position].torrents = release.torrents
                if merged[position].firstAirDate == .distantPast { merged[position].firstAirDate = release.firstAirDate }
            } else {
                merged.append(release)
            }
        }
        return merged.sorted { $0.season == $1.season ? $0.episode < $1.episode : $0.season < $1.season }
    }

    /// EZTV's `imdb_id` (digits, no "tt", "0" when unknown) as an IMDb id.
    static func imdbId(fromEztv numeric: String) -> String? {
        guard !numeric.isEmpty, numeric != "0", numeric.allSatisfy(\.isNumber) else { return nil }
        return "tt" + numeric.leftPadded(to: 7, with: "0")
    }

    /// The shows a page of EZTV torrents names, the latest release first,
    /// each with the page's torrents as episodes (main queue).
    ///
    /// EZTV gives an IMDb id and a release name: the show comes from
    /// `TVMazeShowDirectory` (disk, else a few lookups at a time, within
    /// what is left before `until`). A show whose lookup is not in by then
    /// is left out this time (`partial` is then true); the lookups still
    /// running fill the directory for the next load. Matching and assembly
    /// run off the main queue.
    private func buildShows(from raw: [[String: Any]],
                            genre: NetworkManager.Genres,
                            until: Date,
                            completion: @escaping (_ shows: [Show], _ partial: Bool) -> Void) {
        // Group EZTV torrents by IMDb id, in the page's order.
        var grouped: [String: [[String: Any]]] = [:]
        var order: [String] = []
        for entry in raw {
            guard let numeric = entry["imdb_id"] as? String, let imdbId = YTSEZTVProvider.imdbId(fromEztv: numeric) else { continue }
            if grouped[imdbId] == nil { order.append(imdbId) }
            grouped[imdbId, default: []].append(entry)
        }
        guard !order.isEmpty else {
            DispatchQueue.main.async { completion([], false) }
            return
        }

        let budget = YTSEZTVProvider.namingBudget(left: until.timeIntervalSinceNow)
        TVMazeShowDirectory.shared.resolution(of: order, deadline: budget) { resolution in
            let records = resolution.records
            struct Candidate {
                let show: Show
                let entries: [[String: Any]]
                /// Set when the releases aren't all named after the title:
                /// the alternate titles are needed.
                let tvmazeId: Int?
            }
            let candidates: [Candidate] = order.compactMap { imdbId in
                guard let record = records[imdbId], let show = Show(tvmaze: record, imdbId: imdbId, episodes: []),
                      let entries = grouped[imdbId] else { return nil }
                // Releases not named after the TVMaze title: its alternate
                // titles too ("Ye Gou Gu Tou" for "Love For You") — asked
                // only then, one call per such show.
                let named = YTSEZTVProvider.releases(entries, of: [show.title]).count == entries.count
                return Candidate(show: show, entries: entries, tvmazeId: named ? nil : record["id"] as? Int)
            }
            let needing = candidates.compactMap { candidate in candidate.tvmazeId.map { (imdbId: candidate.show.id, tvmazeId: $0) } }
            let left = min(YTSEZTVProvider.alternateTitlesDeadline, max(0, until.timeIntervalSinceNow))
            self.alternateTitles(of: needing, deadline: left) { akas in
                var shows: [Show] = []
                for candidate in candidates {
                    // Unknown alternate titles (request failed): no filter.
                    let titles = candidate.tvmazeId == nil ? [candidate.show.title]
                        : (akas[candidate.show.id].map { [candidate.show.title] + $0 } ?? [])
                    // Only another show's releases filed under this IMDb id:
                    // not this show's latest torrents, keep it out of the list.
                    let own = YTSEZTVProvider.releases(candidate.entries, of: titles)
                    guard !own.isEmpty else { continue }
                    var built = candidate.show
                    built.episodes = self.mergedEpisodes(guide: [], eztvEntries: own, show: candidate.show, titles: titles)
                    shows.append(built)
                }

                if genre != .all {
                    shows = shows.filter { YTSEZTVProvider.genres($0.genres, include: genre) }
                }
                // Most recent episode release first.
                let latest: (Show) -> Date = { $0.episodes.map(\.firstAirDate).max() ?? .distantPast }
                let result = shows.sorted { latest($0) > latest($1) }

                // Deliberately NOT cached in showCache: catalog entries only
                // hold the current page's torrents, and getShowInfo builds the
                // complete guide on demand — a partial entry must never shadow
                // that full fetch.
                print("[EZTV] built \(result.count)/\(candidates.count) shows from \(order.count) imdb groups (genre=\(genre.rawValue)), \(resolution.unanswered.count) lookups not in")
                DispatchQueue.main.async { completion(result, !resolution.unanswered.isEmpty) }
            }
        }
    }

    /// Longest wait for the alternate titles of a page's shows.
    static var alternateTitlesDeadline: TimeInterval = 3

    /// The alternate titles of `shows` by IMDb id (those that could be
    /// read), a few requests at a time, within `deadline` seconds.
    /// Background queue.
    private func alternateTitles(of shows: [(imdbId: String, tvmazeId: Int)], deadline: TimeInterval,
                                 completion: @escaping ([String: [String]]) -> Void) {
        guard !shows.isEmpty else { return completion([:]) }
        let lock = NSLock()
        var found: [String: [String]] = [:]
        var answered = false
        let answer: () -> Void = {
            lock.lock()
            let first = !answered
            answered = true
            let result = found
            lock.unlock()
            if first { completion(result) }
        }
        BoundedPump.run(shows, maxConcurrent: TVMazeShowDirectory.maxConcurrent, work: { show, done in
            self.fetchTVMazeAkas(imdbId: show.imdbId, tvmazeId: show.tvmazeId) { akas in
                lock.lock()
                if let akas = akas { found[show.imdbId] = akas }
                lock.unlock()
                done()
            }
        }, completion: {
            TVMazeShowDirectory.shared.save()
            answer()
        })
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline, execute: answer)
    }

    /// Merge the TVMaze episode guide with EZTV torrents into one Episode
    /// per (season, episode), sorted by season then episode. Torrents for
    /// the same episode (different qualities/releases) are attached to that
    /// single Episode instead of surfacing as duplicate cells.
    private func mergedEpisodes(guide: [[String: Any]],
                                eztvEntries: [[String: Any]],
                                show: Show,
                                titles: [String]) -> [Episode] {
        struct Key: Hashable { let season: Int; let episode: Int }

        var torrentsByKey: [Key: [Torrent]] = [:]
        var titleByKey: [Key: String] = [:]
        var dateByKey: [Key: Date] = [:]
        let ownEntries = YTSEZTVProvider.releases(eztvEntries, of: titles)
        if ownEntries.count < eztvEntries.count {
            print("[EZTV] \(show.id) '\(show.title)': dropped \(eztvEntries.count - ownEntries.count)/\(eztvEntries.count) releases of another show")
        }
        for entry in ownEntries {
            let season  = Int((entry["season"]  as? String) ?? "0") ?? 0
            let episode = Int((entry["episode"] as? String) ?? "0") ?? 0
            // episode 0 == season packs / specials without numbering; the
            // guide can't anchor them so they'd render as junk rows.
            guard episode > 0, let torrent = YTSEZTVProvider.torrent(fromEztv: entry) else { continue }
            let key = Key(season: season, episode: episode)
            torrentsByKey[key, default: []].append(torrent)
            if titleByKey[key] == nil, let title = entry["title"] as? String {
                titleByKey[key] = title.removingHtmlEncoding
            }
            if let unix = entry["date_released_unix"] as? Int, unix > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(unix))
                dateByKey[key] = min(dateByKey[key] ?? date, date)
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var episodes: [Episode] = []
        var seenKeys = Set<Key>()

        for dict in guide {
            guard
                let season = dict["season"] as? Int,
                let number = dict["number"] as? Int
            else { continue }
            let key = Key(season: season, episode: number)
            seenKeys.insert(key)

            let image = (dict["image"] as? [String: Any])
            let airdate = (dict["airdate"] as? String).flatMap { dateFormatter.date(from: $0) }
            let summary = ((dict["summary"] as? String) ?? "No summary available.".localized).strippedOfHtml
            let name = ((dict["name"] as? String) ?? "Episode \(number)").removingHtmlEncoding

            var episode = Episode(
                title: name,
                id: "\(show.id)-s\(season)e\(number)",
                slug: name.slugged,
                summary: summary,
                torrents: (torrentsByKey[key] ?? []).sorted(by: <),
                largeBackgroundImage: ImageProxy.proxied(image?["original"] as? String ?? image?["medium"] as? String),
                show: show,
                episode: number,
                season: season,
                firstAirDate: airdate ?? dateByKey[key] ?? .distantPast)
            episode.show = show
            episodes.append(episode)
        }

        // Torrents for episodes the guide doesn't know (brand-new airings,
        // guide gaps, specials, revivals, soaps the guide numbers by year)
        // still deserve a row. Another show's releases filed under this
        // IMDb id were already dropped by name (`releases(_:of:)`).
        for (key, torrents) in torrentsByKey where !seenKeys.contains(key) {
            var episode = Episode(
                title: titleByKey[key] ?? "Episode \(key.episode)",
                id: "\(show.id)-s\(key.season)e\(key.episode)",
                summary: "No summary available.".localized,
                torrents: torrents.sorted(by: <),
                show: show,
                episode: key.episode,
                season: key.season,
                firstAirDate: dateByKey[key] ?? .distantPast)
            episode.show = show
            episodes.append(episode)
        }

        episodes.sort { $0.season == $1.season ? $0.episode < $1.episode : $0.season < $1.season }
        return episodes
    }

    /// Build a Torrent from one EZTV `get-torrents` entry. Quality/codec is
    /// parsed from the filename since EZTV has no structured fields for it.
    static func torrent(fromEztv entry: [String: Any]) -> Torrent? {
        guard let magnet = entry["magnet_url"] as? String, !magnet.isEmpty else { return nil }
        let filename = (entry["filename"] as? String) ?? (entry["title"] as? String) ?? ""
        let size: String? = (entry["size_bytes"] as? String).flatMap {
            guard let bytes = Double($0) else { return nil }
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .binary
            return formatter.string(fromByteCount: Int64(bytes))
        }
        var torrent = Torrent(
            health:  .unknown,
            url:     magnet,
            quality: filename,
            seeds:   entry["seeds"] as? Int ?? 0,
            peers:   entry["peers"] as? Int ?? 0,
            size:    size,
            tags:    VideoTags.parse(filename))
        var label = torrent.qualityValue.displayLabel + torrent.tags.displaySuffix
        if label.isEmpty { label = "Unknown".localized }
        torrent.quality = label + " — EZTV"
        torrent.qualityValue = VideoQuality.parse(filename)
        torrent.tags = VideoTags.parse(filename)
        return torrent
    }

    // MARK: Release names

    /// The entries whose release name names the show, under any of `titles`
    /// (its TVMaze title, then its alternate titles: `fetchTVMazeAkas`).
    /// EZTV files some releases of other shows under a show's IMDb id:
    /// every "Breaking Bad" (tt0903747) entry is in fact "Breaking Brad
    /// S09E02 …", a different show, which added seasons 6–9 and attached
    /// wrong torrents to S1–S5. Entries without a title are kept.
    static func releases(_ entries: [[String: Any]], of titles: [String]) -> [[String: Any]] {
        let forms = titles.flatMap(nameFormVariants)
        guard !forms.isEmpty else { return entries }
        return entries.filter { entry in
            guard let title = (entry["title"] as? String) ?? (entry["filename"] as? String), !title.isEmpty else { return true }
            let release = releaseName(title)
            return release.isEmpty || forms.contains { releaseMatches(release, forms: $0) }
        }
    }

    /// True when the release name, up to its SxxEyy / NxNN marker or its
    /// air date (daily shows), names the show: the same words (case,
    /// accents, punctuation, "&" / "and", a leading "The", a trailing year
    /// or country code ignored), or the title with a leading brand
    /// ("Marvel's …" / "Late Night with …") or a trailing subtitle or host
    /// dropped, or an acronym of its last words ("Law and Order SVU").
    /// Accented letters are also matched dropped ("Shgun" for "Shōgun"),
    /// as EZTV writes them.
    static func releaseMatches(_ releaseTitle: String, show showTitle: String) -> Bool {
        let forms = nameFormVariants(showTitle)
        let release = releaseName(releaseTitle)
        return forms.isEmpty || release.isEmpty || forms.contains { releaseMatches(release, forms: $0) }
    }

    /// The show part of a release name, as joined name words: cut at its
    /// SxxEyy / NxNN marker or at a "2026 11 09" air date.
    private static func releaseName(_ releaseTitle: String) -> String {
        var name = releaseTitle
        let marker = #"(?i)(^|[^a-z0-9])(s\d{1,2}\s?e\d{1,3}|\d{1,2}x\d{1,3}|(19|20)\d{2}[ ._-]\d{2}[ ._-]\d{2})([^0-9]|$)"#
        if let range = name.range(of: marker, options: .regularExpression) {
            name = String(name[..<range.lowerBound])
        }
        return nameWords(name).joined()
    }

    private static func releaseMatches(_ release: String, forms: NameForms) -> Bool {
        if forms.acronyms.contains(release) { return true }
        let full = forms.full
        if release == full || release.hasPrefix(full) { return true }
        if release.count >= 4, full.hasSuffix(release) { return true }
        // No "release is the start of the title" rule: it kept Netflix's
        // "Daredevil S01E03" under "Daredevil: Born Again".
        return false
    }

    struct NameForms {
        let full: String
        let acronyms: Set<String>
        var isEmpty: Bool { full.isEmpty }
    }

    /// `title`'s name forms, plus those of:
    /// - the title with its non-ASCII letters dropped rather than folded:
    ///   EZTV names "Shōgun" releases "Shgun 2024 S01E10 …";
    /// - a talk show's title without its host ("The Daily Show with Trevor
    ///   Noah" → "The Daily Show"): the tail after " with " is a name of
    ///   two or three capitalized words ("Dancing with the Stars" is kept whole);
    /// - a title of three words or more without a trailing "Live" ("Jimmy
    ///   Kimmel Live" → "Jimmy Kimmel 2026 11 09 …").
    private static func nameFormVariants(_ title: String) -> [NameForms] {
        var titles = [title]
        let ascii = String(String.UnicodeScalarView(title.unicodeScalars.filter(\.isASCII)))
        if ascii != title { titles.append(ascii) }
        let words = title.split(separator: " ")
        if words.count >= 3, let last = words.last,
           last.trimmingCharacters(in: .punctuationCharacters).lowercased() == "live" {
            titles.append(words.dropLast().joined(separator: " "))
        }
        if let with = title.range(of: " with ", options: .caseInsensitive) {
            let host = title[with.upperBound...].split(separator: " ")
            if (2...3).contains(host.count), host.allSatisfy({ $0.first?.isUppercase == true }) {
                titles.append(String(title[..<with.lowerBound]))
            }
        }
        return titles.map(nameForms).filter { !$0.isEmpty }
    }

    private static func nameForms(_ title: String) -> NameForms {
        let words = nameWords(title)
        var acronyms = Set<String>()
        if words.count >= 2 {
            for start in 0..<(words.count - 1) {
                let tail = words[start...].compactMap(\.first).map(String.init).joined()
                acronyms.insert(words[..<start].joined() + tail)
            }
        }
        return NameForms(full: words.joined(), acronyms: acronyms)
    }

    /// Lowercased ASCII-folded words, "&" read as "and", apostrophes removed,
    /// without a leading "the" or trailing years / country codes.
    private static func nameWords(_ raw: String) -> [String] {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        var words = folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        if words.count > 1, words.first == "the" { words.removeFirst() }
        let countries: Set<String> = ["us", "uk", "au", "nz", "ca"]
        while words.count > 1, let last = words.last,
              countries.contains(last) || (last.count == 4 && (last.hasPrefix("19") || last.hasPrefix("20")) && Int(last) != nil) {
            words.removeLast()
        }
        return words
    }

    private static func normalizedGenre(_ raw: String) -> String {
        return raw.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    /// True when one of a title's `genres` is the app's `genre`, under any
    /// of the names the sources give it ("Science Fiction", TVMaze's
    /// "Science-Fiction", Cinemeta's and YTS's "Sci-Fi"; "Sports" / "Sport").
    static func genres(_ genres: [String], include genre: NetworkManager.Genres) -> Bool {
        let wanted = Set([genre.rawValue, genre.cinemetaValue, genre.ytsValue].compactMap { $0 }.map(normalizedGenre))
        return genres.contains { wanted.contains(normalizedGenre($0)) }
    }

    /// TVMaze's alternate titles of a show (`/shows/{id}/akas`) that EZTV
    /// may name its releases after: the international one (no country), the
    /// English-speaking countries' ("The Doll" for "Lalka", "Ye Gou Gu Tou"
    /// for "Love For You"), and any other written in Latin letters
    /// (romanizations: "Sousou no Frieren", "Shingeki no Kyojin"). Nil when
    /// the request fails (unknown, not "none"). Kept with the show's record
    /// (`TVMazeShowDirectory`). Background queue.
    private func fetchTVMazeAkas(imdbId: String, tvmazeId: Int, completion: @escaping ([String]?) -> Void) {
        let directory = TVMazeShowDirectory.shared
        directory.akas(imdbId) { known in
            if let known = known { return completion(known) }
            TVMazeShowDirectory.tvmaze.data(hosts: TVMazeShowDirectory.tvmazeHosts, path: "/shows/\(tvmazeId)/akas") { data in
                guard let data = data, let akas = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                    return completion(nil)
                }
                let names = YTSEZTVProvider.releaseAkas(akas)
                directory.storeAkas(imdbId, names)
                completion(names)
            }
        }
    }

    /// The alternate titles releases may be named after (see `fetchTVMazeAkas`).
    static func releaseAkas(_ akas: [[String: Any]]) -> [String] {
        let english: Set<String> = ["US", "GB", "CA", "AU", "NZ", "IE"]
        return akas.compactMap { aka in
            guard let name = aka["name"] as? String, !name.isEmpty else { return nil }
            guard let code = (aka["country"] as? [String: Any])?["code"] as? String else { return name }
            return english.contains(code) || YTSEZTVProvider.isLatinScript(name) ? name : nil
        }
    }

    /// Every letter is Latin once accents are folded ("Sousou no Frieren"
    /// yes, "葬送のフリーレン" no).
    private static func isLatinScript(_ name: String) -> Bool {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let letters = folded.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty && letters.allSatisfy(\.isASCII)
    }

    private func fetchTVMazeEpisodes(tvmazeId: Int, completion: @escaping ([[String: Any]]) -> Void) {
        let url = "https://api.tvmaze.com/shows/\(tvmazeId)/episodes"
        session.request(url).validate().responseData { response in
            switch response.result {
            case .success(let data):
                let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments)
                completion(json as? [[String: Any]] ?? [])
            case .failure:
                completion([])
            }
        }
    }

    /// Page through EZTV's per-show torrent listing. Long-running shows have
    /// hundreds of entries; cap the walk so a pathological catalog (The
    /// Simpsons) can't hold the detail page hostage.
    private func fetchAllEztvTorrents(imdbId: String, completion: @escaping ([[String: Any]]) -> Void) {
        let numeric = imdbId.replacingOccurrences(of: "tt", with: "")
        let pageLimit = 100
        let maxPages = 5

        var collected: [[String: Any]] = []

        func fetch(page: Int) {
            let params: [String: Any] = ["imdb_id": numeric, "limit": pageLimit, "page": page]
            attemptEztv(path: "/api/get-torrents", params: params) { data, _ in
                var entries: [[String: Any]] = []
                var total = 0
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data),
                   let root = json as? [String: Any] {
                    entries = (root["torrents"] as? [[String: Any]]) ?? []
                    total = (root["torrents_count"] as? Int) ?? 0
                }
                collected += entries
                let exhausted = entries.isEmpty || collected.count >= total || page >= maxPages
                if exhausted {
                    completion(collected)
                } else {
                    fetch(page: page + 1)
                }
            }
        }
        fetch(page: 1)
    }
}

private extension String {
    func leftPadded(to width: Int, with pad: Character) -> String {
        if count >= width { return self }
        return String(repeating: pad, count: width - count) + self
    }
}

// MARK: - Details & suggestions (OpenMetadata)

extension YTSEZTVProvider {
    /// YTS `movie_details` (with the cast) for an IMDb id: the raw movie
    /// object, on the main queue, or nil (unknown title, every mirror down).
    func ytsMovieDetails(imdbId: String, completion: @escaping ([String: Any]?) -> Void) {
        if let cached = detailsCache.object(forKey: imdbId as NSString) as? [String: Any] {
            return DispatchQueue.main.async { completion(cached) }
        }
        // A request for these details is out (the page's own): its answer.
        detailsLock.lock()
        let inFlight = detailsWaiters[imdbId] != nil
        detailsWaiters[imdbId, default: []].append(completion)
        detailsLock.unlock()
        guard !inFlight else { return }
        attempt(path: Path.movieInfo, params: ["imdb_id": imdbId, "with_cast": "true"]) { [weak self] data, _ in
            let root = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let movie = (root?["data"] as? [String: Any])?["movie"] as? [String: Any]
            let known = (movie?["id"] as? Int ?? 0) > 0
            guard let self = self else { return DispatchQueue.main.async { completion(known ? movie : nil) } }
            self.detailsRequestEnded(imdbId, movie: known ? movie : nil)
        }
    }

    /// YTS's "suggested" movies for a title (4, from its own catalog):
    /// movie_details gives YTS's numeric id, movie_suggestions the list.
    /// Calls back on the main queue, with [] on any failure.
    func movieSuggestions(imdbId: String, completion: @escaping ([Movie]) -> Void) {
        ytsMovieDetails(imdbId: imdbId) { [weak self] movie in
            guard let self, let ytsId = movie?["id"] as? Int else { return completion([]) }
            self.attempt(path: Path.movieSuggestions, params: ["movie_id": ytsId]) { data, _ in
                let root = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                let movies = ((root?["data"] as? [String: Any])?["movies"] as? [[String: Any]] ?? [])
                    .compactMap(Movie.init(yts:))
                    .filter { $0.id != imdbId }
                DispatchQueue.main.async { completion(movies) }
            }
        }
    }
}
