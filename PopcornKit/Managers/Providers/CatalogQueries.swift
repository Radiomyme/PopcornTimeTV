import Foundation

/// What the Movies grid asks YTS for each sort, and how the answer is cleaned.
/// Every choice below was measured on the live API (2026-11-14):
///
/// - `sort_by=seeds` (and `peers`, `featured`) is ignored: the answer is
///   byte for byte the `date_added` one. `sort_by=download_count` is the
///   all-time count (Avengers: Infinity War, Superbad…).
/// - `query_term=<year>` restricts a list to that year's films (50/50); with
///   `download_count` it is "what people download now" (Project Hail Mary,
///   Spider-Man: Brand New Day…).
/// - `sort_by=date_added` alone is 2.5 days of additions, half of them old or
///   unrated; `minimum_rating=6` keeps the films worth a look.
/// - `sort_by=rating` starts with concert films and one-off documentaries a
///   handful of people rated 9.3: they have next to no seeders, the films
///   people actually watch have the 100 the API caps at.
/// - the same title + year exists under two IMDb ids ("The Odyssey" 2026:
///   tt33764258 rated 8.4 with a 4K release, tt41605854 rated 1.7).
/// - an unknown `genre` value is ignored: the whole catalog comes back.
///
/// Pure: no clock, no network (the loads are in `YTSEZTVProvider`).
enum YTSCatalog {

    /// YTS's largest page (a larger `limit` silently falls back to 20).
    static let pageSize = 50
    /// Rating floor (0–9, IMDb) of the lists by date.
    static let minimumRating = 6
    /// "Top Rated": fewest seeders of a title's best release (the API caps
    /// them at 100)…
    static let topRatedMinimumSeeds = 50
    /// …and within a genre, whose own films are less seeded than the hits
    /// of every genre: of Documentary's first 150 by rating, 6 have 50
    /// seeders and 41 have 10 (Shoah, The Blue Planet, Nuit et brouillard).
    static let topRatedMinimumSeedsInGenre = 10
    /// "Top Rated": YTS pages asked at a time (a fifth of a page passes the
    /// seeders floor).
    static let topRatedServerPages = 3
    /// "Top Rated": fewest titles of a grid page before more pages are read
    /// (`CatalogRollover`).
    static let topRatedMinimumPage = 20

    /// One `list_movies` query.
    struct Query: Equatable {
        var sortBy: String
        /// Only that year's films (`query_term=<year>`).
        var year: Int? = nil
        var minimumRating: Int? = nil
        /// YTS's genre value (`NetworkManager.Genres.ytsValue`).
        var genre: String? = nil
        var searchTerm: String? = nil

        func parameters(page: Int, order: NetworkManager.Orders) -> [String: Any] {
            var parameters: [String: Any] = [
                "page": max(page, 1),
                "limit": YTSCatalog.pageSize,
                "sort_by": sortBy,
                "order_by": order == .descending ? "desc" : "asc",
            ]
            if let genre = genre { parameters["genre"] = genre }
            if let minimumRating = minimumRating { parameters["minimum_rating"] = minimumRating }
            if let term = searchTerm, !term.isEmpty {
                parameters["query_term"] = term
            } else if let year = year {
                parameters["query_term"] = String(year)
            }
            return parameters
        }
    }

    /// The queries of a sort, in the order `CatalogRollover` tries them (the
    /// current year's films, last year's when there are too few — January, a
    /// rare genre —, then every year's):
    ///
    /// - Trending: the most downloaded films of the year.
    /// - Popular: the most downloaded of all time (Time4Popcorn's most
    ///   seeded list goes in front of it, see `YTSEZTVProvider`).
    /// - Top Rated: by rating (`cleaned` keeps the well seeded ones).
    /// - Recently Added: by date added, rated 6 or more.
    /// - New: the year's films by date added, rated 6 or more.
    /// - A search: the matches, most downloaded first unless another sort
    ///   was picked.
    static func queries(filter: MovieManager.Filters, genre: String?, searchTerm: String?, year: Int) -> [Query] {
        if let term = searchTerm, !term.isEmpty {
            let sort: String
            switch filter {
            case .rating: sort = "rating"
            case .date: sort = "date_added"
            case .year: sort = "year"
            case .trending, .top100, .popularity: sort = "download_count"
            }
            return [Query(sortBy: sort, genre: genre, searchTerm: term)]
        }
        switch filter {
        case .trending, .top100:
            return [Query(sortBy: "download_count", year: year, genre: genre),
                    Query(sortBy: "download_count", year: year - 1, genre: genre),
                    Query(sortBy: "download_count", genre: genre)]
        case .popularity:
            return [Query(sortBy: "download_count", genre: genre)]
        case .rating:
            return [Query(sortBy: "rating", genre: genre)]
        case .date:
            return [Query(sortBy: "date_added", minimumRating: minimumRating, genre: genre)]
        case .year:
            return [Query(sortBy: "date_added", year: year, minimumRating: minimumRating, genre: genre),
                    Query(sortBy: "date_added", year: year - 1, minimumRating: minimumRating, genre: genre),
                    Query(sortBy: "year", minimumRating: minimumRating, genre: genre)]
        }
    }

    /// The YTS pages one read of a sort asks, from page `first` on.
    static func serverPages(filter: MovieManager.Filters, searchTerm: String?, from first: Int) -> [Int] {
        let first = max(first, 1)
        guard filter == .rating, (searchTerm ?? "").isEmpty else { return [first] }
        return Array(first..<(first + topRatedServerPages))
    }

    /// One page of a `list_movies` answer: its films, how many the server
    /// sent (`movies` is absent past the last page) and the `movie_count`
    /// of the whole query.
    static func listPage(_ root: [String: Any]) -> (movies: [Movie], count: Int, movieCount: Int?) {
        let data = root["data"] as? [String: Any]
        let raw = (data?["movies"] as? [[String: Any]]) ?? []
        return (raw.compactMap(Movie.init(yts:)), raw.count, data?["movie_count"] as? Int)
    }

    /// True when a list goes on after its page `page`: by the `movie_count`
    /// of the answer (sent past the last page too), else when that page,
    /// `pageCount` films, was full.
    static func hasMore(after page: Int, movieCount: Int?, pageCount: Int) -> Bool {
        if let movieCount = movieCount { return page * pageSize < movieCount }
        return pageCount >= pageSize
    }

    /// One query's answer without its noise: a year's list holds that year's
    /// films only (`query_term` is a text search: a title can hold the
    /// number), "Top Rated" keeps the titles people seed (a lower floor
    /// within a genre), and of two entries with the same title and year
    /// only the better one stays.
    static func cleaned(_ movies: [Movie], query: Query, filter: MovieManager.Filters) -> [Movie] {
        var result = movies
        let searching = !(query.searchTerm ?? "").isEmpty
        if let year = query.year, !searching {
            result = result.filter { $0.year == String(year) }
        }
        if filter == .rating, !searching {
            let floor = query.genre == nil ? topRatedMinimumSeeds : topRatedMinimumSeedsInGenre
            result = result.filter { ($0.torrents.map(\.seeds).max() ?? 0) >= floor }
        }
        return withoutNamesakes(result)
    }

    /// Of the entries with the same title and year (the same film under two
    /// IMDb ids), the one with the most releases, then the best rating, at
    /// the place of the first. Order otherwise unchanged.
    static func withoutNamesakes(_ movies: [Movie]) -> [Movie] {
        func key(_ movie: Movie) -> String {
            let title = movie.title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                            locale: Locale(identifier: "en_US_POSIX")).lowercased()
            return title + "|" + movie.year
        }
        func better(_ candidate: Movie, than kept: Movie) -> Bool {
            if candidate.torrents.count != kept.torrents.count { return candidate.torrents.count > kept.torrents.count }
            return candidate.rating > kept.rating
        }
        var positions: [String: Int] = [:]
        var result: [Movie] = []
        var seenIds = Set<String>()
        for movie in movies where seenIds.insert(movie.id).inserted {
            let identity = key(movie)
            if let index = positions[identity] {
                if better(movie, than: result[index]) { result[index] = movie }
            } else {
                positions[identity] = result.count
                result.append(movie)
            }
        }
        return result
    }
}

/// What the Shows grid makes of Cinemeta's catalogs (`CinemetaClient.catalog`).
/// Pure.
enum ShowCatalog {

    /// Cinemeta's page size (`skip=50`, `skip=100`…).
    static let pageSize = 50
    /// "Top Rated": Cinemeta has no catalog by rating ("imdbRating" is its
    /// "Featured" list, not sorted by rating), so each grid page is this many
    /// pages of the popular catalog…
    static let topRatedCatalogPages = 2
    /// …of which the series rated at least this (0–100) stay, best first.
    static let topRatedMinimumRating: Float = 80
    /// "New" within a genre: catalog pages asked at a time. The year catalog
    /// has no genre extra and holds 200 to 400 series a year, 1 to 65 of a
    /// genre (War: 1 in 2026, 3 in 2025): it is filtered here, half a year
    /// at a time.
    static let newInGenreCatalogPages = 4

    /// The `skip` values that make grid page `page`.
    static func skips(page: Int, catalogPages: Int = 1) -> [Int] {
        let first = (max(page, 1) - 1) * catalogPages
        return (0..<catalogPages).map { (first + $0) * pageSize }
    }

    /// The `skip` values of `count` catalog pages, from page `first` on.
    static func skips(from first: Int, count: Int) -> [Int] {
        return (0..<max(count, 1)).map { (max(first, 1) - 1 + $0) * pageSize }
    }

    /// "Top Rated": the well rated series of the popular catalog, best rated
    /// first (catalog order between equal ratings).
    static func topRated(_ shows: [Show]) -> [Show] {
        return shows.enumerated()
            .filter { $0.element.rating >= topRatedMinimumRating }
            .sorted { $0.element.rating != $1.element.rating ? $0.element.rating > $1.element.rating : $0.offset < $1.offset }
            .map(\.element)
    }

    /// "A - Z": by title, case ignored (the way the grids sort when they
    /// merge the next pages in).
    static func alphabetical(_ shows: [Show]) -> [Show] {
        return shows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// "New": the year catalog lists series by premiere, newest first, the
    /// announced ones included: those whose premiere is still to come are
    /// left out (no date: kept, the catalog lists them among the aired ones).
    static func premiered(_ metas: [[String: Any]], now: Date) -> [[String: Any]] {
        return metas.filter { meta in
            guard let released = (meta["released"] as? String).flatMap(CatalogDates.date(from:)) else { return true }
            return released <= now
        }
    }
}

/// A list read as "segments", one after the other: the current year's
/// titles, then last year's, then every year's (in January the year has a
/// dozen titles, a rare genre has none); a single one for the other sorts.
/// A grid page starts where the last one stopped (`Cursor`):
///
/// - it is read on, in its segment and then in the next ones, until it has
///   `minimum` titles (a year that runs dry, a page that the cleaning or a
///   genre left short), in at most `maxReads` reads;
/// - the next page starts at the read after its last one.
///
/// (Each segment used to be asked the grid's own page number: a year with 41
/// films gave page 1, then page 2 was last year's page 2, and last year's 50
/// most downloaded films were never shown.)
///
/// A segment answers nil when it failed. The page is nil when a read failed
/// before anything was gathered; otherwise it is what was gathered, and the
/// next page asks the failed read again.
enum CatalogRollover {

    /// Fewest titles of a grid page before the list is read further.
    static let minimumPage = 30
    /// Most reads for one grid page.
    static let maxReads = 4

    /// Where a grid page starts: a segment, and the page to ask it (the
    /// segment's own numbering, from 1). Past the last segment: the list
    /// has ended.
    struct Cursor: Equatable {
        var segment = 0
        var page = 1
    }

    /// What a segment read: the titles kept, and the page to ask it next
    /// (nil: it has no more).
    struct Batch<Item> {
        var items: [Item]
        var next: Int?
    }

    typealias Segment<Item> = (_ page: Int, _ completion: @escaping (Batch<Item>?) -> Void) -> Void

    /// The grid page that starts at `cursor`, and where the next one starts.
    static func load<Item>(from cursor: Cursor, segments: [Segment<Item>],
                           minimum: Int = minimumPage, maxReads: Int = maxReads,
                           completion: @escaping (_ items: [Item]?, _ next: Cursor) -> Void) {
        step(cursor: cursor, segments: segments, gathered: [], reads: 0, minimum: minimum, maxReads: max(maxReads, 1),
             completion: completion)
    }

    private static func step<Item>(cursor: Cursor, segments: [Segment<Item>], gathered: [Item], reads: Int,
                                   minimum: Int, maxReads: Int,
                                   completion: @escaping ([Item]?, Cursor) -> Void) {
        guard cursor.segment < segments.count else { return completion(gathered, cursor) }
        segments[cursor.segment](cursor.page) { batch in
            guard let batch = batch else {
                return completion(gathered.isEmpty ? nil : gathered, cursor)
            }
            let all = gathered + batch.items
            let next = batch.next.map { Cursor(segment: cursor.segment, page: $0) } ?? Cursor(segment: cursor.segment + 1, page: 1)
            if all.count >= minimum || reads + 1 >= maxReads {
                completion(all, next)
            } else {
                step(cursor: next, segments: segments, gathered: all, reads: reads + 1, minimum: minimum, maxReads: maxReads,
                     completion: completion)
            }
        }
    }

    /// Grid page `page` of the list `key`, read from where page `page - 1`
    /// stopped (`starts`). A page whose start is not known (the first page
    /// came from the snapshot on disk: nothing was read) is reached by
    /// reading again the pages before it, from the last one whose start is
    /// known. Nil when a read failed before the page had anything.
    static func load<Item>(page: Int, of key: String, starts: CatalogPageStarts<Cursor>, segments: [Segment<Item>],
                           minimum: Int = minimumPage, maxReads: Int = maxReads,
                           completion: @escaping ([Item]?) -> Void) {
        let page = max(page, 1)
        var known = page
        while known > 1, starts.start(of: known, in: key) == nil { known -= 1 }
        func read(_ current: Int) {
            let cursor = current <= 1 ? Cursor() : (starts.start(of: current, in: key) ?? Cursor())
            load(from: cursor, segments: segments, minimum: minimum, maxReads: maxReads) { items, next in
                guard let items = items else { return completion(nil) }
                starts.set(next, of: current + 1, in: key)
                if current == page { completion(items) } else { read(current + 1) }
            }
        }
        read(known)
    }
}

/// What a list has to remember from one grid page to the next, by list and
/// page number: a grid asks its pages by number, and what page 3 must ask
/// depends on what pages 1 and 2 were given (`CatalogRollover.Cursor`; the
/// Time4Popcorn page of "Popular"). Kept for the lists last loaded
/// (`capacity`). Thread-safe.
final class CatalogPageStarts<Position> {

    private let capacity: Int
    private let lock = NSLock()
    private var lists: [String: [Int: Position]] = [:]
    /// The lists, least recently written first.
    private var order: [String] = []

    init(capacity: Int = 24) {
        self.capacity = max(capacity, 1)
    }

    /// Where page `page` of `list` starts, nil when not known.
    func start(of page: Int, in list: String) -> Position? {
        lock.lock()
        defer { lock.unlock() }
        return lists[list]?[page]
    }

    func set(_ position: Position, of page: Int, in list: String) {
        lock.lock()
        defer { lock.unlock() }
        lists[list, default: [:]][page] = position
        order.removeAll { $0 == list }
        order.append(list)
        while order.count > capacity { lists[order.removeFirst()] = nil }
    }
}
