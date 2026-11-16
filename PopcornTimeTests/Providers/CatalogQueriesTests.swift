//
//  CatalogQueriesTests.swift
//  PopcornTimeTests
//
//  What the Movies and Shows grids ask their catalogs for each sort and genre, and how the
//  answers are cleaned, against answers recorded on the live APIs on 2026-11-14
//  (Fixtures/Catalog, trimmed to the fields read). Never calls the APIs.
//

import XCTest
import Foundation
import ObjectMapper
@testable import PopcornKit

private func json(_ name: String) -> [String: Any] {
    return (try? JSONSerialization.jsonObject(with: Fixtures.data("Catalog/" + name))) as? [String: Any] ?? [:]
}
private func ytsMovies(_ name: String) -> [Movie] {
    let movies = (json(name)["data"] as? [String: Any])?["movies"] as? [[String: Any]] ?? []
    return movies.compactMap(Movie.init(yts:))
}
private func cinemetaMetas(_ name: String) -> [[String: Any]] {
    return CinemetaClient.catalogMetas(fromJSON: Fixtures.data("Catalog/" + name)) ?? []
}
private func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}
private func string(_ parameters: [String: Any], _ key: String) -> String? {
    return parameters[key].map { "\($0)" }
}

final class CatalogQueriesTests: CheckedTestCase {

    // MARK: Movies: the queries

    func testEverySortAsksYTSSomethingItHonours() {
        typealias Filter = MovieManager.Filters
        func first(_ filter: Filter) -> [String: Any] {
            return YTSCatalog.queries(filter: filter, genre: nil, searchTerm: nil, year: 2026)[0].parameters(page: 1, order: .descending)
        }
        // No sort sends what the server ignores (seeds, peers, featured).
        for filter in Filter.array where filter != .top100 {
            for query in YTSCatalog.queries(filter: filter, genre: nil, searchTerm: nil, year: 2026) {
                check(["download_count", "rating", "date_added", "year"].contains(query.sortBy), "\(filter) sorts by \(query.sortBy)")
                eq(string(query.parameters(page: 3, order: .descending), "limit"), "50", "\(filter): YTS's largest page")
                eq(string(query.parameters(page: 3, order: .descending), "page"), "3", "\(filter): the page asked")
                eq(string(query.parameters(page: 3, order: .ascending), "order_by"), "asc", "\(filter): ascending")
                eq(string(query.parameters(page: 0, order: .descending), "page"), "1", "\(filter): page 0 is page 1")
            }
        }
        // Trending: the year's most downloaded, not the all-time ones.
        eq(string(first(.trending), "sort_by"), "download_count", "Trending sorts by downloads")
        eq(string(first(.trending), "query_term"), "2026", "Trending is this year's films")
        eq(first(.trending)["minimum_rating"] == nil, true, "Trending has no rating floor")
        // Popular: every year's.
        eq(string(first(.popularity), "sort_by"), "download_count", "Popular sorts by downloads")
        eq(first(.popularity)["query_term"] == nil, true, "Popular is every year's films")
        eq(YTSCatalog.queries(filter: .popularity, genre: nil, searchTerm: nil, year: 2026).count, 1, "Popular: one list")
        check(first(.trending)["query_term"] != nil && first(.popularity)["query_term"] == nil, "Trending and Popular are different lists")
        // Top Rated.
        eq(string(first(.rating), "sort_by"), "rating", "Top Rated sorts by rating")
        // Recently Added: every year, rated.
        eq(string(first(.date), "sort_by"), "date_added", "Recently Added sorts by date added")
        eq(string(first(.date), "minimum_rating"), "6", "Recently Added: rating floor")
        eq(first(.date)["query_term"] == nil, true, "Recently Added is every year's films")
        // New: this year's, by date, rated.
        eq(string(first(.year), "sort_by"), "date_added", "New sorts by date added")
        eq(string(first(.year), "query_term"), "2026", "New is this year's films")
        eq(string(first(.year), "minimum_rating"), "6", "New: rating floor")
    }

    func testYearListsGoOnWithLastYearThenEveryYear() {
        let trending = YTSCatalog.queries(filter: .trending, genre: "action", searchTerm: nil, year: 2027)
        eq(trending.map(\.year), [2027, 2026, nil], "Trending: this year, last year, every year")
        check(trending.allSatisfy { $0.sortBy == "download_count" && $0.genre == "action" }, "Trending: same sort and genre down the chain")
        let new = YTSCatalog.queries(filter: .year, genre: nil, searchTerm: nil, year: 2027)
        eq(new.map(\.year), [2027, 2026, nil], "New: this year, last year, every year")
        eq(new.map(\.sortBy), ["date_added", "date_added", "year"], "New: by date added, then the newest years")
        check(new.allSatisfy { $0.minimumRating == 6 }, "New: the rating floor down the chain")
        // The year is the calendar's, in January too.
        eq(CatalogDates.year(of: utc(2027, 1, 1)), 2027, "1 January 2027")
        eq(CatalogDates.year(of: utc(2026, 12, 31)), 2026, "31 December 2026")
    }

    func testSearchKeepsTheTermAndPutsPopularMatchesFirst() {
        let queries = YTSCatalog.queries(filter: .popularity, genre: nil, searchTerm: "dune", year: 2026)
        eq(queries.count, 1, "a search is one query")
        let parameters = queries[0].parameters(page: 1, order: .descending)
        eq(string(parameters, "query_term"), "dune", "the term is searched, not the year")
        eq(string(parameters, "sort_by"), "download_count", "the most downloaded matches first")
        eq(parameters["minimum_rating"] == nil, true, "a search has no rating floor")
        eq(YTSCatalog.queries(filter: .trending, genre: nil, searchTerm: "dune", year: 2026)[0].year, nil, "a search is not restricted to the year")
        eq(YTSCatalog.queries(filter: .rating, genre: nil, searchTerm: "dune", year: 2026)[0].sortBy, "rating", "another sort picked is kept")
    }

    func testTopRatedReadsThreeServerPages() {
        eq(YTSCatalog.serverPages(filter: .rating, searchTerm: nil, from: 1), [1, 2, 3], "Top Rated: three pages at a time")
        eq(YTSCatalog.serverPages(filter: .rating, searchTerm: nil, from: 4), [4, 5, 6], "Top Rated: the next three")
        eq(YTSCatalog.serverPages(filter: .rating, searchTerm: "dune", from: 2), [2], "a search by rating: one page")
        eq(YTSCatalog.serverPages(filter: .trending, searchTerm: nil, from: 4), [4], "Trending: one page")
        eq(YTSCatalog.serverPages(filter: .date, searchTerm: nil, from: 0), [1], "page 0 is page 1")
    }

    func testWhereAYTSListEnds() {
        // History, 2026: 41 films (the count is sent with every page, past the last one too).
        eq(YTSCatalog.hasMore(after: 1, movieCount: 41, pageCount: 41), false, "41 films: one page")
        eq(YTSCatalog.hasMore(after: 3, movieCount: 41, pageCount: 0), false, "past the end")
        eq(YTSCatalog.hasMore(after: 2, movieCount: 105, pageCount: 50), true, "105 films: a third page")
        eq(YTSCatalog.hasMore(after: 3, movieCount: 105, pageCount: 5), false, "105 films: no fourth")
        eq(YTSCatalog.hasMore(after: 1, movieCount: 50, pageCount: 50), false, "exactly one page")
        // No count in the answer: a full page has a next one.
        eq(YTSCatalog.hasMore(after: 1, movieCount: nil, pageCount: 50), true, "no count: a full page goes on")
        eq(YTSCatalog.hasMore(after: 1, movieCount: nil, pageCount: 12), false, "no count: a short page is the last")
        // The recorded answers: Trending 2026 has 1,479 films, New 2026 (rated 6 or more) 566.
        let trending = YTSCatalog.listPage(json("yts_trending_2026.json"))
        eq(trending.movies.count, 50, "the page's films")
        eq(trending.count, 50, "as many as the server sent")
        eq(trending.movieCount, 1479, "the query's count")
        eq(YTSCatalog.hasMore(after: 1, movieCount: trending.movieCount, pageCount: trending.count), true, "Trending goes on")
        eq(YTSCatalog.hasMore(after: 30, movieCount: trending.movieCount, pageCount: 29), false, "until its page 30")
        eq(YTSCatalog.listPage(json("yts_new_2026.json")).movieCount, 566, "another query's count")
        // Past the last page: no `movies`, the count all the same.
        let past = YTSCatalog.listPage(["status": "ok", "data": ["movie_count": 41, "limit": 50, "page_number": 3]])
        eq(past.movies.count, 0, "past the end: no film")
        eq(past.movieCount, 41, "and the count")
        eq(YTSCatalog.listPage([:]).movieCount, nil, "not an answer")
    }

    // MARK: Genres

    func testGenresSpeakEachCatalogsVocabulary() {
        typealias Genre = NetworkManager.Genres
        eq(Genre.sciFi.ytsValue, "sci-fi", "YTS: Science Fiction")
        eq(Genre.sports.ytsValue, "sport", "YTS: Sports")
        eq(Genre.filmNoir.ytsValue, "film-noir", "YTS: Film Noir")
        eq(Genre.music.ytsValue, "music", "YTS: Music")
        eq(Genre.action.ytsValue, "action", "YTS: Action")
        eq(Genre.sciFi.cinemetaValue, "Sci-Fi", "Cinemeta: Science Fiction")
        eq(Genre.sports.cinemetaValue, "Sport", "Cinemeta: Sports")
        eq(Genre.action.cinemetaValue, "Action", "Cinemeta: Action")
        eq(Genre.filmNoir.cinemetaValue, nil, "Cinemeta has no Film Noir")
        eq(Genre.music.cinemetaValue, nil, "Cinemeta has no Music")
        eq(Genre.all.ytsValue, nil, "All: no genre parameter (YTS)")
        eq(Genre.all.cinemetaValue, nil, "All: no genre parameter (Cinemeta)")
        // The genres no source has are not offered any more.
        let gone: [Genre] = [.disaster, .fanFilm, .holiday, .indie, .road, .short, .sportingEvent, .suspense]
        for genre in gone {
            eq(genre.ytsValue, nil, "\(genre.rawValue): YTS ignores it")
            eq(genre.cinemetaValue, nil, "\(genre.rawValue): Cinemeta ignores it")
            check(!Genre.movies.contains(genre) && !Genre.shows.contains(genre) && !Genre.array.contains(genre), "\(genre.rawValue) is not offered")
        }
        // Every genre offered is one its catalog knows.
        eq(Genre.movies.first, .all, "Movies: All first")
        eq(Genre.shows.first, .all, "Shows: All first")
        for genre in Genre.movies where genre != .all { check(genre.ytsValue != nil, "Movies offer \(genre.rawValue), which YTS knows") }
        for genre in Genre.shows where genre != .all { check(genre.cinemetaValue != nil, "Shows offer \(genre.rawValue), which Cinemeta knows") }
        eq(Genre.movies.count, 21, "Movies: All + 20 genres")
        eq(Genre.shows.count, 19, "Shows: All + 18 genres")
        check(Genre.shows.allSatisfy { Genre.movies.contains($0) }, "the Shows genres are among the Movies ones")
        eq(Genre.array, Genre.movies, "the common list is the larger one")
        // The values the server documents, as measured: lowercase, IMDb's spellings.
        let yts = Set(Genre.movies.compactMap(\.ytsValue))
        eq(yts.count, 20, "20 distinct YTS genres")
        check(yts.allSatisfy { $0 == $0.lowercased() && !$0.contains(" ") }, "YTS genres are lowercase without spaces")
        eq(YTSCatalog.queries(filter: .trending, genre: Genre.sciFi.ytsValue, searchTerm: nil, year: 2026)[0]
            .parameters(page: 1, order: .descending)["genre"] as? String, "sci-fi", "the genre parameter sent")
        eq(YTSCatalog.queries(filter: .trending, genre: nil, searchTerm: nil, year: 2026)[0]
            .parameters(page: 1, order: .descending)["genre"] == nil, true, "All: no genre parameter sent")
    }

    func testAGenreMatchesUnderEverySourcesName() {
        check(YTSEZTVProvider.genres(["Drama", "Science-Fiction"], include: .sciFi), "TVMaze's Science-Fiction")
        check(YTSEZTVProvider.genres(["Sci-Fi"], include: .sciFi), "Cinemeta's and YTS's Sci-Fi")
        check(YTSEZTVProvider.genres(["Science Fiction"], include: .sciFi), "the app's Science Fiction")
        check(YTSEZTVProvider.genres(["Sport"], include: .sports), "Sport")
        check(YTSEZTVProvider.genres(["Sports"], include: .sports), "Sports")
        check(YTSEZTVProvider.genres(["Film-Noir"], include: .filmNoir), "Film-Noir")
        check(!YTSEZTVProvider.genres(["Drama", "Crime"], include: .sciFi), "Drama, Crime is not Science Fiction")
        check(!YTSEZTVProvider.genres([], include: .action), "no genre")
    }

    // MARK: Movies: cleaning

    func testTheSameFilmUnderTwoIdsIsListedOnce() {
        let movies = ytsMovies("yts_trending_2026.json")
        eq(movies.count, 50, "the recorded page")
        let odysseys = movies.filter { $0.title == "The Odyssey" }
        eq(odysseys.map(\.id), ["tt41605854", "tt33764258"], "The Odyssey (2026) is there twice")
        let first = movies.firstIndex { $0.title == "The Odyssey" }
        let cleaned = YTSCatalog.withoutNamesakes(movies)
        eq(cleaned.count, 49, "one entry less")
        eq(cleaned.filter { $0.title == "The Odyssey" }.map(\.id), ["tt33764258"], "the one with the 4K release and the 8.4 stays")
        eq(cleaned.firstIndex { $0.title == "The Odyssey" }, first, "at the place of the first")
        eq(cleaned.map(\.id), movies.map(\.id).filter { $0 != "tt33764258" }.map { $0 == "tt41605854" ? "tt33764258" : $0 },
           "the others keep their order")
        // The same id twice (two sources): once.
        eq(YTSCatalog.withoutNamesakes(movies + movies).count, 49, "the same ids again add nothing")
        // Same title, another year: both stay.
        let dune1984 = Movie(yts: ["imdb_code": "tt0087182", "title": "Dune", "year": 1984])!
        let dune2021 = Movie(yts: ["imdb_code": "tt1160419", "title": "Dune", "year": 2021])!
        eq(YTSCatalog.withoutNamesakes([dune1984, dune2021]).count, 2, "Dune 1984 and Dune 2021 are two films")
        // Same releases count: the better rated one.
        let low = Movie(yts: ["imdb_code": "tt1", "title": "Twin", "year": 2026, "rating": 3.0])!
        let high = Movie(yts: ["imdb_code": "tt2", "title": "TWIN", "year": 2026, "rating": 7.5])!
        eq(YTSCatalog.withoutNamesakes([low, high]).map(\.id), ["tt2"], "equal releases: the better rated, case ignored")
    }

    func testTopRatedKeepsTheFilmsPeopleSeed() {
        let movies = ytsMovies("yts_rating.json")
        eq(movies.count, 50, "the recorded page")
        eq(movies.prefix(2).map(\.title), ["Dance for Your Life", "Yanni Live! The Concert Event"],
           "the raw list opens with a documentary and a concert")
        let query = YTSCatalog.queries(filter: .rating, genre: nil, searchTerm: nil, year: 2026)[0]
        let cleaned = YTSCatalog.cleaned(movies, query: query, filter: .rating)
        eq(cleaned.count, 13, "13 of 50 are seeded")
        eq(cleaned.prefix(3).map(\.title), ["The Day of the Doctor", "The Shawshank Redemption", "The Godfather"], "the films, in rating order")
        for title in ["The Dark Knight", "12 Angry Men", "Schindler's List", "The Godfather Part II"] {
            check(cleaned.contains { $0.title == title }, "\(title) stays")
        }
        for title in ["Yanni Live! The Concert Event", "Hans Zimmer: Live in Prague", "Mexican Wave"] {
            check(!cleaned.contains { $0.title == title }, "\(title) goes")
        }
        check(cleaned.allSatisfy { ($0.torrents.map(\.seeds).max() ?? 0) >= YTSCatalog.topRatedMinimumSeeds }, "every title kept is seeded")
        eq(cleaned.map(\.rating), cleaned.map(\.rating).sorted(by: >), "still best rated first")
        // Within a genre the floor is lower: a genre's own films are less seeded than the
        // hits of every genre (Documentary: 6 of its first 150 have 50 seeders).
        let inGenre = YTSCatalog.queries(filter: .rating, genre: "documentary", searchTerm: nil, year: 2026)[0]
        let kept = YTSCatalog.cleaned(movies, query: inGenre, filter: .rating)
        check(kept.count > cleaned.count && kept.count < movies.count, "a genre keeps more titles, not all", "\(kept.count)")
        check(kept.allSatisfy { ($0.torrents.map(\.seeds).max() ?? 0) >= YTSCatalog.topRatedMinimumSeedsInGenre }, "those seeded at all")
        check(cleaned.allSatisfy { title in kept.contains { $0.id == title.id } }, "the well seeded ones among them")
        // The other sorts keep the unseeded titles (a film just added has no count yet).
        let trending = YTSCatalog.queries(filter: .date, genre: nil, searchTerm: nil, year: 2026)[0]
        eq(YTSCatalog.cleaned(movies, query: trending, filter: .date).count, 50, "Recently Added keeps them all")
        // A search by rating is not filtered.
        let search = YTSCatalog.queries(filter: .rating, genre: nil, searchTerm: "live", year: 2026)[0]
        eq(YTSCatalog.cleaned(movies, query: search, filter: .rating).count, 50, "a search keeps every match")
    }

    func testAYearsListHoldsThatYearsFilmsOnly() {
        var movies = ytsMovies("yts_new_2026.json")
        eq(movies.count, 20, "the recorded page")
        check(movies.allSatisfy { $0.year == "2026" }, "the server's list is 2026 only")
        // `query_term` is a text search: a title holding the number matches too.
        movies.insert(Movie(yts: ["imdb_code": "tt9999001", "title": "2026: A Prophecy", "year": 2019])!, at: 3)
        let query = YTSCatalog.queries(filter: .year, genre: nil, searchTerm: nil, year: 2026)[0]
        let cleaned = YTSCatalog.cleaned(movies, query: query, filter: .year)
        eq(cleaned.count, 20, "the 2019 film is left out")
        check(!cleaned.contains { $0.id == "tt9999001" }, "the 2019 film is left out of the 2026 list")
        // The list of every year keeps it.
        let all = YTSCatalog.queries(filter: .year, genre: nil, searchTerm: nil, year: 2026)[2]
        eq(YTSCatalog.cleaned(movies, query: all, filter: .year).count, 21, "the every-year list keeps it")
    }

    // MARK: The year running dry

    /// Segments of numbers for `CatalogRollover`: `pages` by page (a page not listed is
    /// empty, a nil one fails), the last listed page being the segment's last.
    private final class Lists {
        typealias Segment = CatalogRollover.Segment<Int>
        var asked: [String] = []

        func segment(_ name: String, _ pages: [Int: [Int]?], atATime: Int = 1) -> Segment {
            let last = pages.keys.max() ?? 0
            return { [self] first, done in
                asked.append("\(name)\(first)")
                var items: [Int] = []
                for page in first..<(first + atATime) {
                    let listed: [Int]? = pages[page] ?? []
                    guard let list = listed else { return done(nil) }
                    items += list
                }
                done(CatalogRollover.Batch(items: items, next: first + atATime > last ? nil : first + atATime))
            }
        }
    }

    func testRollover() {
        typealias Segment = CatalogRollover.Segment<Int>
        typealias Cursor = CatalogRollover.Cursor
        let lists = Lists()
        func load(_ cursor: Cursor, _ segments: [Segment], minimum: Int = CatalogRollover.minimumPage) -> (items: [Int]?, next: Cursor) {
            lists.asked = []
            var result: ([Int]?, Cursor)?
            CatalogRollover.load(from: cursor, segments: segments, minimum: minimum) { result = ($0, $1) }
            check(result != nil, "the load answered")
            return result ?? (nil, cursor)
        }
        let full = Array(1...50), few = Array(101...112), last = Array(201...250), all = Array(301...350)
        /// A list that could not be read.
        let failed: [Int]? = nil
        let start = Cursor()

        // November: the year fills its pages alone.
        var page = load(start, [lists.segment("Y", [1: full, 2: full]), lists.segment("P", [1: last])])
        eq(page.items, full, "a full first page is the year's alone")
        eq(lists.asked, ["Y1"], "last year is not asked")
        eq(page.next, Cursor(segment: 0, page: 2), "the next page is the year's second")
        // 30 titles are enough.
        page = load(start, [lists.segment("Y", [1: Array(1...30)]), lists.segment("P", [1: last])])
        eq(page.items?.count, 30, "30 titles: enough")
        eq(lists.asked, ["Y1"], "30 titles: last year is not asked")
        eq(page.next, Cursor(segment: 1, page: 1), "the year had one page: last year's first is next")
        // January: a dozen titles, topped up with last year's first page.
        let january = [lists.segment("Y", [1: few]), lists.segment("P", [1: last, 2: full]), lists.segment("A", [1: all])]
        page = load(start, january)
        eq(page.items, few + last, "January: the year's few, then last year's")
        eq(lists.asked, ["Y1", "P1"], "January: this year, then last year")
        eq(page.next, Cursor(segment: 1, page: 2), "January: the next page is last year's second")
        page = load(page.next, january)
        eq(page.items, full, "January, page 2: last year's page 2")
        eq(lists.asked, ["P2"], "January, page 2: the year is not asked again")
        eq(page.next, Cursor(segment: 2, page: 1), "then every year's list, from its first page")
        // A rare genre: nothing this year, one film last year, then every year's.
        let rare = [lists.segment("Y", [:]), lists.segment("P", [1: [7]]), lists.segment("A", [1: all, 2: full])]
        page = load(start, rare)
        eq(page.items, [7] + all, "a rare genre: every year's list tops it up")
        eq(lists.asked, ["Y1", "P1", "A1"], "a rare genre asks the three lists")
        page = load(page.next, rare)
        eq(page.items, full, "a rare genre, page 2: every year's page 2")
        eq(lists.asked, ["A2"], "and nothing else")
        // The end of every list.
        eq(page.next, Cursor(segment: 3, page: 1), "past the last list")
        page = load(page.next, rare)
        eq(page.items, [], "past the end: an empty page")
        eq(lists.asked, [], "and no request")
        eq(page.next, Cursor(segment: 3, page: 1), "the end stays the end")
        eq(load(start, [Segment]()).items, [], "no list at all: an empty page")
        // Failures.
        page = load(start, [lists.segment("Y", [1: failed]), lists.segment("P", [1: last])])
        eq(page.items, nil, "the first list failed: an error")
        eq(lists.asked, ["Y1"], "nothing is asked after the first list failed")
        eq(page.next, start, "the page starts at the same place the next time")
        page = load(start, [lists.segment("Y", [1: few]), lists.segment("P", [1: failed])])
        eq(page.items, few, "last year failed: the year's few")
        eq(page.next, Cursor(segment: 1, page: 1), "and the next page asks last year again")
        eq(load(Cursor(segment: 1, page: 2), [lists.segment("Y", [:]), lists.segment("P", [2: failed])]).items, nil,
           "nothing gathered and a failure: an error")
    }

    func testAYearOfThirtyToAHundredFiftyTitlesHandsOverAtLastYearsFirstPage() {
        typealias Cursor = CatalogRollover.Cursor
        let lists = Lists()
        let starts = CatalogPageStarts<Cursor>()
        func load(_ page: Int, _ segments: [CatalogRollover.Segment<Int>], key: String = "list") -> [Int]? {
            lists.asked = []
            var result: [Int]??
            CatalogRollover.load(page: page, of: key, starts: starts, segments: segments) { result = $0 }
            check(result != nil, "the load answered")
            return result ?? nil
        }
        // History, 14 November: 41 films this year, 122 last year (three pages), then every year's.
        let year = Array(1...41), lastYear = [Array(1001...1050), Array(1051...1100), Array(1101...1122)]
        let everyYear = [Array(2001...2050), Array(2051...2100)]
        let history = [lists.segment("Y", [1: year]),
                       lists.segment("P", [1: lastYear[0], 2: lastYear[1], 3: lastYear[2]]),
                       lists.segment("A", [1: everyYear[0], 2: everyYear[1]])]
        eq(load(1, history), year, "page 1: the year's 41 films")
        eq(lists.asked, ["Y1"], "page 1 asks the year")
        eq(load(2, history), lastYear[0], "page 2: last year's 50 most downloaded (it was its page 2)")
        eq(lists.asked, ["P1"], "page 2 asks last year's first page")
        eq(load(3, history), lastYear[1], "page 3: last year's page 2")
        // A short last page is topped up with the start of the next list.
        eq(load(4, history), lastYear[2] + everyYear[0], "page 4: last year's last 22, then every year's first page")
        eq(lists.asked, ["P3", "A1"], "page 4 asks both")
        eq(load(5, history), everyYear[1], "page 5: every year's page 2")
        eq(load(6, history), [], "page 6: the end")
        eq(lists.asked, [], "the end asks nothing")
        // No title is skipped, none comes twice.
        eq((1...6).flatMap { load($0, history) ?? [] }, year + lastYear.flatMap { $0 } + everyYear.flatMap { $0 }, "the three lists, whole and in order")

        // Sci-Fi: 105 films this year (50 + 50 + 5), then last year's from its first page.
        let sciFi = [lists.segment("Y", [1: Array(1...50), 2: Array(51...100), 3: Array(101...105)]),
                     lists.segment("P", [1: lastYear[0], 2: lastYear[1]])]
        eq(load(3, sciFi, key: "sci-fi"), Array(101...105) + lastYear[0], "page 3: the year's last 5 and last year's first page")
        eq(lists.asked, ["Y1", "Y2", "Y3", "P1"], "a page whose start is not known is reached by reading the ones before it")
        eq(load(4, sciFi, key: "sci-fi"), lastYear[1], "page 4: last year's page 2")
        eq(lists.asked, ["P2"], "from where page 3 stopped")

        // The first page came from the snapshot on disk: nothing was read, page 2 reads it again.
        eq(load(2, history, key: "relaunch"), lastYear[0], "page 2 after a relaunch: last year's first page")
        eq(lists.asked, ["Y1", "P1"], "page 1 is read again to know where page 2 starts")
        // A failure on the way to a page is that page's failure, and nothing is remembered of it.
        let broken = [lists.segment("Y", [1: year]), lists.segment("P", [1: nil])]
        eq(load(2, broken, key: "broken"), nil, "page 2 could not be read")
        eq(starts.start(of: 3, in: "broken") == nil, true, "page 3's start is not known")
        eq(starts.start(of: 2, in: "broken"), Cursor(segment: 1, page: 1), "page 2 still starts at last year's first page")
    }

    func testAGridPageIsFilledFromTheNextReads() {
        typealias Cursor = CatalogRollover.Cursor
        let lists = Lists()
        func load(_ cursor: Cursor, _ segments: [CatalogRollover.Segment<Int>], minimum: Int) -> (items: [Int]?, next: Cursor) {
            lists.asked = []
            var result: ([Int]?, Cursor)?
            CatalogRollover.load(from: cursor, segments: segments, minimum: minimum) { result = ($0, $1) }
            return result ?? (nil, cursor)
        }
        // Top Rated within Documentary: three YTS pages a read, a handful of titles pass.
        var pages: [Int: [Int]?] = [:]
        for page in 1...30 { pages[page] = [page * 10, page * 10 + 1] }
        let documentary = [lists.segment("R", pages, atATime: 3)]
        var page = load(Cursor(), documentary, minimum: 20)
        eq(page.items?.count, 24, "four reads of 6 titles: the most a page asks")
        eq(lists.asked, ["R1", "R4", "R7", "R10"], "three pages at a time, four times")
        eq(page.next, Cursor(segment: 0, page: 13), "the next page goes on from page 13")
        page = load(page.next, documentary, minimum: 20)
        eq(page.items?.first, 130, "and starts with its titles")
        // Film Noir: 15 titles in the first three pages, none after, ten pages in all.
        var noir: [Int: [Int]?] = [1: Array(1...15)]
        for page in 2...10 { noir[page] = [] }
        page = load(Cursor(), [lists.segment("R", noir, atATime: 3)], minimum: 20)
        eq(page.items, Array(1...15), "the 15 titles")
        eq(lists.asked, ["R1", "R4", "R7", "R10"], "read to the end of the genre")
        eq(page.next, Cursor(segment: 1, page: 1), "which is the end of the list: the next page is empty for good")
        // New within War: one series this year (the whole year in one read), two last year.
        let war = [lists.segment("Y", [1: [], 2: [1], 3: [], 4: []], atATime: 4), lists.segment("P", [1: [], 2: [2], 3: [3], 4: []], atATime: 4)]
        page = load(Cursor(), war, minimum: 30)
        eq(page.items, [1, 2, 3], "this year's, then last year's: never an empty first page, never last year's first")
        eq(lists.asked, ["Y1", "P1"], "a year a read")
        // Enough titles: one read.
        page = load(Cursor(), documentary, minimum: 5)
        eq(lists.asked, ["R1"], "enough titles: one read")
        // A search asks a page of its one query, short or not.
        page = load(Cursor(segment: 0, page: 2), [lists.segment("S", [1: full50, 2: [1, 2], 3: [3]])], minimum: 0)
        eq(page.items, [1, 2], "a search's page is not filled")
        eq(lists.asked, ["S2"], "one read")
    }

    private let full50 = Array(1...50)

    func testWhatAListRemembersFromOnePageToTheNext() {
        let starts = CatalogPageStarts<Int>(capacity: 2)
        eq(starts.start(of: 2, in: "a"), nil, "nothing known")
        starts.set(1, of: 2, in: "a")
        starts.set(2, of: 3, in: "a")
        eq(starts.start(of: 2, in: "a"), 1, "page 2 of a list")
        eq(starts.start(of: 3, in: "a"), 2, "page 3")
        eq(starts.start(of: 2, in: "b"), nil, "another list knows nothing of it")
        starts.set(5, of: 2, in: "a")
        eq(starts.start(of: 2, in: "a"), 5, "a page loaded again: its new start")
        // Only the lists last loaded are kept.
        starts.set(7, of: 2, in: "b")
        starts.set(8, of: 2, in: "c")
        eq(starts.start(of: 2, in: "a"), nil, "the oldest list is forgotten")
        eq(starts.start(of: 2, in: "b"), 7, "the others are kept")
        eq(starts.start(of: 2, in: "c"), 8, "the others are kept")
    }

    // MARK: Shows: Cinemeta's catalogs

    func testCatalogPaths() {
        eq(CinemetaClient.catalogPath(.series, .top, genre: nil, skip: 0), "/catalog/series/top.json", "the popular series")
        eq(CinemetaClient.catalogPath(.series, .top, genre: nil, skip: 50), "/catalog/series/top/skip=50.json", "page 2")
        eq(CinemetaClient.catalogPath(.series, .top, genre: "Sci-Fi", skip: 0), "/catalog/series/top/genre=Sci-Fi.json", "a genre")
        eq(CinemetaClient.catalogPath(.series, .top, genre: "Sci-Fi", skip: 100), "/catalog/series/top/genre=Sci-Fi&skip=100.json", "a genre, page 3")
        eq(CinemetaClient.catalogPath(.series, .featured, genre: nil, skip: 0), "/catalog/series/imdbRating.json", "Featured")
        eq(CinemetaClient.catalogPath(.series, .year, genre: "2026", skip: 50), "/catalog/series/year/genre=2026&skip=50.json", "a year, page 2")
        eq(CinemetaClient.catalogPath(.movie, .top, genre: "Reality TV", skip: 0), "/catalog/movie/top/genre=Reality%20TV.json", "a genre is escaped")
        eq(ShowCatalog.skips(page: 1), [0], "page 1")
        eq(ShowCatalog.skips(page: 3), [100], "page 3")
        eq(ShowCatalog.skips(page: 0), [0], "page 0 is page 1")
        eq(ShowCatalog.skips(page: 1, catalogPages: 2), [0, 50], "Top Rated page 1 is two catalog pages")
        eq(ShowCatalog.skips(page: 2, catalogPages: 2), [100, 150], "Top Rated page 2")
        // New: read from a catalog page on (`CatalogRollover`), the whole year at once within a genre.
        eq(ShowCatalog.skips(from: 1, count: 1), [0], "New, the year's first page")
        eq(ShowCatalog.skips(from: 3, count: 1), [100], "its third")
        eq(ShowCatalog.skips(from: 1, count: ShowCatalog.newInGenreCatalogPages), [0, 50, 100, 150], "New within a genre: four pages at a time")
        eq(ShowCatalog.skips(from: 5, count: 4), [200, 250, 300, 350], "then the next four")
        eq(ShowCatalog.skips(from: 0, count: 0), [0], "never before the first page, never no page")
    }

    func testACatalogPageIsKeptWithoutItsEpisodeLists() {
        let raw = (json("cm_series_top.json")["metas"] as? [[String: Any]]) ?? []
        eq(raw.count, 50, "the recorded page")
        check(raw.prefix(3).allSatisfy { ($0["videos"] as? [Any])?.isEmpty == false }, "the server's metas carry their episodes")
        let metas = cinemetaMetas("cm_series_top.json")
        eq(metas.count, 50, "50 metas")
        check(metas.allSatisfy { $0["videos"] == nil }, "no episode list is kept")
        check(metas.allSatisfy { $0["credits_cast"] == nil && $0["credits_crew"] == nil }, "no credits are kept")
        check(metas.allSatisfy { $0["id"] is String && $0["name"] is String && $0["poster"] is String }, "what a poster needs is kept")
        check(metas.contains { $0["trailerStreams"] != nil }, "the trailers are kept")
        check(metas.contains { $0["released"] != nil } && metas.contains { $0["status"] != nil }, "the premiere and the status are kept")
        eq(CinemetaClient.catalogMetas(fromJSON: Data("<html>parked</html>".utf8)) == nil, true, "a page that is not a catalog")
        eq(CinemetaClient.catalogMetas(fromJSON: Data("{\"metas\":[]}".utf8))?.count, 0, "past the end: an empty catalog")
        check(JSONSerialization.isValidJSONObject(metas), "the trimmed page is still JSON")
    }

    func testShowsOfACatalogPage() {
        let shows = cinemetaMetas("cm_series_top.json").compactMap(Show.init(cinemeta:))
        eq(shows.count, 50, "50 shows")
        eq(shows.prefix(4).map(\.title), ["MobLand", "Nocturne", "Black Doves", "Dexter: Resurrection"], "the catalog's order")
        eq(shows[0].id, "tt31510819", "the IMDb id")
        eq(shows[0].year, "2025", "the first year of \"2025–\"")
        eq(shows[0].rating, 83, "8.3 as a percentage")
        eq(shows[0].genres, ["Crime", "Drama"], "the genres")
        eq(shows[0].status, "Continuing", "the status")
        eq(shows[0].largeCoverImage, "https://images.metahub.space/poster/medium/tt31510819/img", "the medium poster")
        eq(shows[0].logoImage, "https://images.metahub.space/logo/medium/tt31510819/img", "the logo")
        eq(shows[0].releaseDate, utc(2025, 3, 30), "the premiere")
        check(shows.allSatisfy { $0.episodes.isEmpty }, "no episodes: the show's page loads them")
        eq(Set(shows.map(\.id)).count, 50, "50 distinct ids")
    }

    func testTopRatedShows() {
        let shows = (cinemetaMetas("cm_series_top.json") + cinemetaMetas("cm_series_top_skip100.json")).compactMap(Show.init(cinemeta:))
        eq(shows.count, 100, "two catalog pages")
        let top = ShowCatalog.topRated(shows)
        eq(top.count, 50, "50 of 100 are rated 8 or more")
        eq(top.prefix(5).map(\.title), ["Breaking Bad", "Band of Brothers", "Avatar: The Last Airbender", "Game of Thrones", "The Sopranos"], "best rated first")
        check(top.allSatisfy { $0.rating >= ShowCatalog.topRatedMinimumRating }, "nothing under 8")
        eq(top.map(\.rating), top.map(\.rating).sorted(by: >), "by rating")
        // Equal ratings keep the catalog's order.
        let nines = shows.filter { $0.rating == 92 }.map(\.id)
        eq(top.filter { $0.rating == 92 }.map(\.id), nines, "equal ratings: the catalog's order")
        check(!top.contains { $0.title == "Nocturne" }, "an unrated series is not top rated")
        eq(ShowCatalog.topRated([]).count, 0, "no show")
    }

    func testAlphabeticalShows() {
        let shows = cinemetaMetas("cm_series_top.json").compactMap(Show.init(cinemeta:))
        let sorted = ShowCatalog.alphabetical(shows)
        eq(sorted.count, 50, "every show")
        eq(Set(sorted.map(\.id)), Set(shows.map(\.id)), "the same shows")
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            check(a.title.localizedCaseInsensitiveCompare(b.title) != .orderedDescending, "\(a.title) before \(b.title)")
        }
        check(sorted.first!.title != shows.first!.title, "not the catalog's order")
    }

    func testNewShowsLeaveOutTheAnnouncedOnes() {
        let metas = cinemetaMetas("cm_series_year_2026.json")
        eq(metas.count, 30, "the recorded page")
        // (A series without a premiere date has `"released": null`.)
        let undated = metas.filter { !($0["released"] is String) }.count
        eq(undated, 11, "11 have no premiere date")
        // The day of the recording: everything dated has premiered.
        eq(ShowCatalog.premiered(metas, now: utc(2026, 11, 14)).count, 30, "14 November: all have premiered")
        // Two weeks earlier: Nocturne (30 October) has not.
        let earlier = ShowCatalog.premiered(metas, now: utc(2026, 10, 29))
        check(!earlier.contains { $0["name"] as? String == "Nocturne" }, "29 October: Nocturne is still to come")
        check(earlier.count < 30 && earlier.count >= undated, "29 October: fewer, the undated ones stay", "\(earlier.count)")
        check(earlier.filter { !($0["released"] is String) }.count == undated, "the series without a date stay")
        // The genre is filtered by the client (the catalog's only extra is the year).
        let horror = Top100Resolver.filter(metas, genre: NetworkManager.Genres.horror.rawValue)
        check(!horror.isEmpty && horror.count < metas.count, "the genre filter keeps some", "\(horror.count)")
        check(horror.allSatisfy { (($0["genres"] as? [String]) ?? []).contains("Horror") }, "all of them Horror")
        let sciFi = Top100Resolver.filter(metas, genre: NetworkManager.Genres.sciFi.rawValue)
        check(sciFi.allSatisfy { (($0["genres"] as? [String]) ?? []).contains("Sci-Fi") }, "Science Fiction keeps Cinemeta's Sci-Fi")
    }

    // MARK: Shows: "Recently Added" and the show's page

    func testRecentlyAddedSharesTheTimeItIsWaitedFor() {
        let reserve = YTSEZTVProvider.alternateTitlesReserve
        // EZTV answered at once: naming the shows and their alternate titles fit before the
        // list stops being waited for.
        let left = SourceGate.deadline - YTSEZTVProvider.assemblyReserve
        let naming = YTSEZTVProvider.namingBudget(left: left)
        check(naming > 0 && naming <= TVMazeShowDirectory.deadline, "naming the shows has a budget", "\(naming)")
        check(naming + reserve <= left, "which leaves the alternate titles their share", "\(naming) + \(reserve) of \(left)")
        // A slow mirror took most of the time: what is left, never the full 6 s.
        eq(YTSEZTVProvider.namingBudget(left: 3), 3 - reserve, "3 s left")
        eq(YTSEZTVProvider.namingBudget(left: reserve), 0, "no time left: what the directory knows already")
        eq(YTSEZTVProvider.namingBudget(left: -2), 0, "past the deadline")
        // A longer wait never gives naming more than the directory's own deadline.
        eq(YTSEZTVProvider.namingBudget(left: 60), TVMazeShowDirectory.deadline, "never more than the directory's deadline")
    }

    func testAGuideGetsItsReleasesTorrents() {
        func episode(_ season: Int, _ number: Int, title: String, torrents: [String] = [], aired: Date = .distantPast) -> Episode {
            return Episode(title: title, id: "tt1-s\(season)e\(number)",
                           torrents: torrents.map { Torrent(url: "magnet:?xt=urn:btih:\($0)", quality: "1080p") },
                           episode: number, season: season, firstAirDate: aired)
        }
        // Cinemeta lists one episode of a series whose second is out on EZTV.
        let guide = [episode(1, 1, title: "Pilot", aired: utc(2026, 11, 1))]
        let released = [episode(1, 2, title: "I Kill the Bear S01E02", torrents: ["b"], aired: utc(2026, 11, 8)),
                        episode(1, 1, title: "I Kill the Bear S01E01", torrents: ["a", "c"], aired: utc(2026, 11, 2))]
        let merged = YTSEZTVProvider.episodes(guide, withTorrentsOf: released)
        eq(merged.map { "\($0.season)x\($0.episode)" }, ["1x1", "1x2"], "the guide's episode, then the one it does not list yet")
        eq(merged[0].title, "Pilot", "the guide's title stays")
        eq(merged[0].torrents.count, 2, "with its releases' torrents")
        eq(merged[0].firstAirDate, utc(2026, 11, 1), "and the guide's date")
        eq(merged[1].title, "I Kill the Bear S01E02", "the release's title for an episode the guide lacks")
        eq(merged[1].torrents.count, 1, "and its torrent")
        // No release: the guide as it is. No guide: the releases.
        eq(YTSEZTVProvider.episodes(guide, withTorrentsOf: []).map(\.title), ["Pilot"], "no release: the guide")
        eq(YTSEZTVProvider.episodes([], withTorrentsOf: released).map(\.episode), [1, 2], "no guide: the releases, in order")
        // An episode the guide could not date takes its release's date.
        let undated = YTSEZTVProvider.episodes([episode(1, 1, title: "Pilot")], withTorrentsOf: released)
        eq(undated[0].firstAirDate, utc(2026, 11, 2), "an undated episode: its release's date")
    }

    // MARK: Models

    func testACinemetaMovieKeepsItsDateTrailerAndLogo() {
        let metas = cinemetaMetas("cm_movie_top.json")
        eq(metas.count, 12, "the recorded metas")
        guard let movie = metas.first.flatMap(Movie.init(cinemeta:)) else { return XCTFail("no movie") }
        eq(movie.title, "Heart of the Beast", "the title")
        eq(movie.id, "tt7526136", "the IMDb id")
        eq(movie.releaseDate, utc(2026, 9, 25), "the release date")
        eq(movie.trailerCode, "UkMuGKqAux4", "the first trailer")
        eq(movie.logoImage, "https://images.metahub.space/logo/medium/tt7526136/img", "the logo")
        eq(movie.year, "2026", "the year")
        // A meta without them: nothing invented.
        let bare = Movie(cinemeta: ["id": "tt0000001", "name": "Bare", "releaseInfo": "1999"])
        eq(bare?.releaseDate, nil, "no date")
        eq(bare?.trailer, nil, "no trailer")
        eq(bare?.logoImage, nil, "no logo")
        // The JSON the snapshot and the Watchlist store brings them back.
        let stored = Mapper<Movie>().toJSONArray([movie])
        check(JSONSerialization.isValidJSONObject(stored), "the movie's JSON can be written")
        let back = Mapper<Movie>().mapArray(JSONArray: stored)
        eq(back.count, 1, "the movie comes back")
        eq(back.first?.id, movie.id, "its id")
        eq(back.first?.title, movie.title, "its title")
        eq(back.first?.year, movie.year, "its year")
        eq(back.first?.rating, movie.rating, "its rating")
        eq(back.first?.releaseDate, movie.releaseDate, "its release date")
        eq(back.first?.trailerCode, movie.trailerCode, "its trailer")
        eq(back.first?.logoImage, movie.logoImage, "its logo")
        eq(back.first?.largeCoverImage, movie.largeCoverImage, "its poster")
        eq(back.first?.genres ?? [], movie.genres, "its genres")
    }

    func testAYTSMovieSurvivesTheSnapshot() {
        let movies = ytsMovies("yts_new_2026.json")
        let stored = Mapper<Movie>().toJSONArray(movies)
        check(JSONSerialization.isValidJSONObject(stored), "the list's JSON can be written")
        let data = (try? JSONSerialization.data(withJSONObject: stored)) ?? Data()
        let read = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
        let back = Mapper<Movie>().mapArray(JSONArray: read)
        eq(back.map(\.id), movies.map(\.id), "the same films in the same order")
        eq(back.map(\.title), movies.map(\.title), "their titles")
        eq(back.map(\.year), movies.map(\.year), "their years")
        eq(back.map(\.largeCoverImage), movies.map(\.largeCoverImage), "their posters (proxied once)")
        eq(back.map(\.rating), movies.map(\.rating), "their ratings")
        eq(back.map(\.trailer), movies.map(\.trailer), "their trailers")
        check(back.allSatisfy { $0.releaseDate == nil && $0.logoImage == nil }, "YTS gives no release date or logo")
    }

    func testACinemetaShowSurvivesTheSnapshot() {
        let shows = cinemetaMetas("cm_series_top.json").compactMap(Show.init(cinemeta:))
        let stored = Mapper<Show>().toJSONArray(shows)
        let data = (try? JSONSerialization.data(withJSONObject: stored)) ?? Data()
        let read = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
        let back = Mapper<Show>().mapArray(JSONArray: read)
        eq(back.map(\.id), shows.map(\.id), "the same shows in the same order")
        eq(back.map(\.title), shows.map(\.title), "their titles")
        eq(back.map(\.largeCoverImage), shows.map(\.largeCoverImage), "their posters")
        eq(back.map(\.releaseDate), shows.map(\.releaseDate), "their premieres")
        eq(back.map(\.logoImage), shows.map(\.logoImage), "their logos")
        eq(back.map(\.status), shows.map(\.status), "their status")
        eq(back.map(\.genres), shows.map(\.genres), "their genres")
        eq(back.map(\.rating), shows.map(\.rating), "their ratings")
    }

    func testATVMazeShowHasItsPremiere() {
        let record = (try? JSONSerialization.jsonObject(with: Fixtures.data("Sources/tvm_lookup_tt31510819.json"))) as? [String: Any] ?? [:]
        let show = Show(tvmaze: record, imdbId: "tt31510819")
        eq(show?.title, "MobLand", "the title")
        eq(show?.releaseDate, utc(2025, 3, 30), "premiered 2025-03-30")
        eq(Show(tvmaze: ["name": "Undated"], imdbId: "tt1")?.releaseDate, nil, "no premiere: no date")
    }

    // MARK: Search ranking

    func testSearchListsPopularExactMatchesFirst() {
        struct Title { let name: String; let id: String }
        let found = [Title(name: "Dune", id: "1984"), Title(name: "Dune World", id: "world"), Title(name: "Dune", id: "2021"),
                     Title(name: "Children of Dune", id: "children"), Title(name: "Dune: Part Two", id: "two"),
                     Title(name: "Dune Drifter", id: "drifter")]
        // Without a rank: exact titles, then those that start with the words, then the rest, each in their order.
        eq(YTSEZTVProvider.exactFirst(found, query: "dune", title: { $0.name }).map(\.id),
           ["1984", "2021", "world", "two", "drifter", "children"], "exact, then prefix, then the rest")
        // Cinemeta's order (most popular first): Part Two, the 2021 film, the 1984 one.
        let ranks = ["two": 0, "2021": 1, "1984": 2]
        eq(YTSEZTVProvider.exactFirst(found, query: "dune", title: { $0.name }, rank: { ranks[$0.id] }).map(\.id),
           ["2021", "1984", "two", "world", "drifter", "children"], "the popular exact match first, the popular sequel first of the rest")
        // A title counts under its other names: YTS's "Dune: Part One" is Cinemeta's "Dune".
        let yts = [Title(name: "Dune", id: "1984"), Title(name: "Dune: Part One", id: "2021"), Title(name: "Dune: Part Two", id: "two")]
        eq(YTSEZTVProvider.exactFirst(yts, query: "dune", title: { $0.name }, rank: { ranks[$0.id] }).map(\.id),
           ["1984", "two", "2021"], "without its other name, \"Dune: Part One\" is not an exact match")
        eq(YTSEZTVProvider.exactFirst(yts, query: "dune", title: { $0.name }, aliases: { $0.id == "2021" ? ["Dune"] : [] },
                                      rank: { ranks[$0.id] }).map(\.id),
           ["2021", "1984", "two"], "with it, the 2021 film leads")
        // "the" and case are ignored, an empty query changes nothing.
        eq(YTSEZTVProvider.exactFirst(found, query: "The DUNE", title: { $0.name }).first?.id, "1984", "The DUNE is dune")
        eq(YTSEZTVProvider.exactFirst(found, query: "  ", title: { $0.name }).map(\.id), found.map(\.id), "no query: the same order")
        // A rank never lifts a title over a better tier.
        eq(YTSEZTVProvider.exactFirst(found, query: "dune", title: { $0.name }, rank: { $0.id == "children" ? 0 : nil }).last?.id,
           "children", "a popular loose match stays last")
    }

    // MARK: Answers and ids

    func testAMirrorsAnswerIsValidated() {
        check(YTSEZTVProvider.isYTSAnswer(Fixtures.data("Catalog/yts_trending_2026.json")), "a YTS list")
        check(YTSEZTVProvider.isYTSAnswer(Data("{\"status\":\"ok\",\"status_message\":\"Query was successful\",\"data\":{\"movie_count\":0}}".utf8)), "a YTS page past the end")
        check(YTSEZTVProvider.isYTSAnswer(Data("{\"status\":\"error\",\"status_message\":\"movie_id is null\"}".utf8)), "a YTS error is still YTS answering")
        check(!YTSEZTVProvider.isYTSAnswer(Data("<!DOCTYPE html><html><body>This domain is for sale</body></html>".utf8)), "a parked domain's page")
        check(!YTSEZTVProvider.isYTSAnswer(Data("{\"status\":\"ok\"}".utf8)), "ok without data")
        check(!YTSEZTVProvider.isYTSAnswer(Data("{\"torrents_count\":3,\"torrents\":[]}".utf8)), "another API's JSON")
        check(!YTSEZTVProvider.isYTSAnswer(Data("[]".utf8)), "a JSON array")
        check(!YTSEZTVProvider.isYTSAnswer(Data()), "an empty body")
        check(YTSEZTVProvider.isEZTVAnswer(Fixtures.data("Catalog/eztv_latest.json")), "an EZTV page")
        check(YTSEZTVProvider.isEZTVAnswer(Data("{\"imdb_id\":\"6151526\",\"torrents_count\":0,\"limit\":100,\"page\":1}".utf8)), "an EZTV show without torrents")
        check(!YTSEZTVProvider.isEZTVAnswer(Data("<html>captive portal</html>".utf8)), "a captive portal's page")
        check(!YTSEZTVProvider.isEZTVAnswer(Data("{}".utf8)), "an empty object")
        check(!YTSEZTVProvider.isEZTVAnswer(Fixtures.data("Catalog/yts_trending_2026.json")), "a YTS answer is not EZTV's")
    }

    func testEZTVIds() {
        eq(YTSEZTVProvider.imdbId(fromEztv: "6151526"), "tt6151526", "7 digits")
        eq(YTSEZTVProvider.imdbId(fromEztv: "903747"), "tt0903747", "padded to 7 digits")
        eq(YTSEZTVProvider.imdbId(fromEztv: "13438882"), "tt13438882", "8 digits")
        eq(YTSEZTVProvider.imdbId(fromEztv: "0"), nil, "0: EZTV does not know the show")
        eq(YTSEZTVProvider.imdbId(fromEztv: ""), nil, "empty")
        eq(YTSEZTVProvider.imdbId(fromEztv: "tt123"), nil, "not a number")
        // The recorded page: 100 torrents, 14 without a show, 23 shows.
        let torrents = (json("eztv_latest.json")["torrents"] as? [[String: Any]]) ?? []
        eq(torrents.count, 100, "100 torrents")
        let ids = torrents.compactMap { ($0["imdb_id"] as? String).flatMap(YTSEZTVProvider.imdbId(fromEztv:)) }
        eq(ids.count, 86, "86 name a show")
        eq(Set(ids).count, 23, "23 shows")
        check(torrents.allSatisfy { YTSEZTVProvider.torrent(fromEztv: $0) != nil }, "every torrent is read")
    }
}
