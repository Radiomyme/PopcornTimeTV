//
//  PosterCardTests.swift
//  PopcornTimeTests
//
//  What a grid's poster says about its title (PopcornKit, PosterCard): the line under the
//  focused poster and the marks on the artwork, from what the lists carry (YTS, Cinemeta's
//  catalogs, their saved copies) and from the library's memory. No network, no real clock.
//

import Foundation
import XCTest
import ObjectMapper
@testable import PopcornKit

final class PosterCardTests: CheckedTestCase {

    private let now = CatalogDates.date(from: "2026-11-14T12:00:00Z")!

    private func date(_ text: String) -> Date { return CatalogDates.date(from: text)! }

    /// A `list_movies` entry of YTS, as the app reads it.
    private func ytsMovie(year: Int = 2026, rating: Double = 8.4, runtime: Int = 156, uploaded: String? = "2026-11-10T08:00:00Z",
                          qualities: [String] = ["720p", "1080p", "2160p"]) -> Movie {
        var dict: [String: Any] = [
            "imdb_code": "tt12042730", "title": "Project Hail Mary", "year": year, "rating": rating, "runtime": runtime,
            "torrents": qualities.map { ["hash": "0123456789ABCDEF0123456789ABCDEF01234567", "quality": $0, "seeds": 120, "peers": 10] },
        ]
        if let uploaded = uploaded { dict["date_uploaded_unix"] = Int(date(uploaded).timeIntervalSince1970) }
        return Movie(yts: dict)!
    }

    private func cinemetaShow(released: String? = "2025-03-30T00:00:00.000Z", videos: [[String: Any]]) -> Show {
        var meta: [String: Any] = ["id": "tt31510819", "type": "series", "name": "MobLand", "releaseInfo": "2025–",
                                   "imdbRating": "8.3", "runtime": "47 min", "status": "Continuing", "videos": videos,
                                   "cast": ["dropped by the trim"]]
        if let released = released { meta["released"] = released }
        let data = try! JSONSerialization.data(withJSONObject: ["metas": [meta]])
        let trimmed = CinemetaClient.catalogMetas(fromJSON: data, now: now)!
        check(trimmed[0]["videos"] == nil && trimmed[0]["cast"] == nil, "the trim still drops the episode list")
        return Show(cinemeta: trimmed[0])!
    }

    private func video(_ season: Int, _ number: Int, _ released: String) -> [String: Any] {
        return ["season": season, "number": number, "episode": number, "released": released, "id": "tt31510819:\(season):\(number)"]
    }

    // MARK: - Movies

    func testAMovieOfTheListSaysWhatItIs() {
        let card = PosterCard(movie: ytsMovie(), now: now)
        eq(card.title, "Project Hail Mary", "title")
        eq(card.year, 2026, "year")
        eq(card.rating, 8.4, "YTS's 0–10 rating, kept through the models' 0–100")
        eq(card.runtimeMinutes, 156, "runtime")
        eq(card.seasons, nil, "a movie has no seasons")
        eq(card.badges, [.uhd, .new], "a 2160p release and added four days ago: 4K first, then New")
        check(!card.isWatched && card.progress == nil && !card.isInWatchlist, "nothing from the library by default")

        let plain = PosterCard(movie: ytsMovie(rating: 0, runtime: 0, uploaded: nil, qualities: ["720p", "1080p"]), now: now)
        check(plain.rating == nil && plain.runtimeMinutes == nil, "0 is unknown: no rating, no runtime")
        eq(plain.badges, [], "no 2160p release, no date: no badge")
        eq(PosterCard(movie: Movie(title: "Loading", id: "tt1"), now: now).year, nil, "a title known by id only has no year")
    }

    func testNewIsARecentMovieJustAdded() {
        let added: (String, Int) -> [HomeBadge] = { uploaded, year in
            PosterCard(movie: self.ytsMovie(year: year, uploaded: uploaded, qualities: ["1080p"]), now: self.now).badges
        }
        eq(added("2026-10-31T12:00:00Z", 2026), [.new], "added 14 days ago to the second: still new")
        eq(added("2026-10-31T11:59:59Z", 2026), [], "a second more: not new")
        eq(added("2026-11-13T12:00:00Z", 2025), [.new], "last year's movie added yesterday is new")
        eq(added("2026-11-13T12:00:00Z", 2024), [], "an older movie added yesterday is a re-release, not a new movie")
        eq(added("2026-11-13T12:00:00Z", 1975), [], "…a 1975 one even less")
        eq(added("2026-11-15T12:00:00Z", 2026), [], "a date in the future is not an addition")

        // Cinemeta's movies carry a release date instead.
        let released: (String) -> [HomeBadge] = { day in
            let movie = Movie(cinemeta: ["id": "tt1", "name": "Heart of the Beast", "releaseInfo": "2026", "released": day])!
            return PosterCard(movie: movie, now: self.now).badges
        }
        eq(released("2026-11-05T00:00:00.000Z"), [.new], "released nine days ago")
        eq(released("2026-09-25T00:00:00.000Z"), [], "released in September")
        eq(released("2026-12-25T00:00:00.000Z"), [], "a release announced is not a release")
    }

    /// The first page of a grid is painted from its saved copy, whose JSON has no torrents.
    func testTheSavedListKeepsWhatTheBadgesNeed() {
        let movie = ytsMovie()
        let saved = Mapper<Movie>().toJSONArray([movie])
        check(saved[0]["torrents"] == nil, "the saved JSON leaves the torrents out")
        let data = try! JSONSerialization.data(withJSONObject: saved)
        let json = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let read = Mapper<Movie>().mapArray(JSONArray: json)
        eq(read.count, 1, "the movie is read back")
        check(read[0].torrents.isEmpty, "…without torrents")
        check(read[0].hasUHDRelease, "…but still known to have a 2160p release")
        eq(read[0].dateAdded, movie.dateAdded, "…and when it was added")
        eq(PosterCard(movie: read[0], now: now), PosterCard(movie: movie, now: now), "the same card from the saved list")
        // Saved again (a watchlist entry rewritten, a snapshot of a snapshot): nothing lost.
        let again = Mapper<Movie>().mapArray(JSONArray: Mapper<Movie>().toJSONArray(read))
        eq(PosterCard(movie: again[0], now: now), PosterCard(movie: movie, now: now), "…and from a copy of the copy")

        let hd = ytsMovie(qualities: ["1080p"])
        let hdSaved = Mapper<Movie>().toJSONArray([hd])
        check(hdSaved[0]["uhd"] == nil, "no flag written for a movie without a 2160p release")
        check(!Mapper<Movie>().mapArray(JSONArray: hdSaved)[0].hasUHDRelease, "…and none read")
    }

    // MARK: - Shows

    func testAShowOfTheCatalogKnowsItsLatestEpisodeAndItsSeasons() {
        let show = cinemetaShow(videos: [video(1, 10, "2025-06-01T03:00:00.000Z"), video(2, 8, "2026-11-06T03:00:00.000Z"),
                                         video(2, 9, "2026-11-13T03:00:00.000Z"), video(2, 10, "2026-11-20T03:00:00.000Z"),
                                         video(0, 1, "2026-11-14T00:00:00.000Z")])
        eq(show.latestEpisodeDate, date("2026-11-13T03:00:00Z"), "the latest episode aired: not the one to come, not the special")
        eq(show.seasonCount, 2, "its season is the number of seasons aired")
        let card = PosterCard(show: show, now: now)
        eq(card.year, 2025, "year")
        eq(card.rating, 8.3, "rating")
        eq(card.runtimeMinutes, 47, "an episode's length")
        eq(card.seasons, 2, "seasons")
        eq(card.badges, [.newEpisode], "an episode aired yesterday")
        check(!card.isWatched, "a show is never 'watched'")

        eq(PosterCard(show: show, now: date("2026-11-20T02:59:59Z")).badges, [.newEpisode], "seven days later, to the second")
        eq(PosterCard(show: show, now: date("2026-11-20T03:00:01Z")).badges, [], "past seven days: no badge")

        // A third season announced: still two seasons until it airs. Soaps number seasons by year.
        let announced = cinemetaShow(videos: [video(2, 9, "2026-06-13T03:00:00.000Z"), video(3, 1, "2027-01-10T03:00:00.000Z"),
                                              video(2026, 223, "2026-11-13T00:00:00.000Z")])
        eq(announced.seasonCount, 2, "a season to come and a year-numbered one are not counted")
        eq(PosterCard(show: announced, now: now).badges, [], "nothing aired this week")

        let ended = cinemetaShow(released: "2008-01-20T00:00:00.000Z", videos: [video(5, 16, "2013-09-30T05:00:00.000Z")])
        eq(PosterCard(show: ended, now: now).seasons, 5, "an ended show keeps its seasons")
        eq(PosterCard(show: ended, now: now).badges, [], "…and has no badge")

        let unknown = cinemetaShow(videos: [])
        check(unknown.latestEpisodeDate == nil && unknown.seasonCount == nil, "a catalog entry without episodes says nothing")
        eq(PosterCard(show: unknown, now: now).seasons, nil, "no seasons to show")
    }

    func testAShowThatJustPremieredIsNew() {
        let premiered = cinemetaShow(released: "2026-11-06T00:00:00.000Z",
                                     videos: [video(1, 1, "2026-11-06T08:00:00.000Z"), video(1, 2, "2026-11-13T08:00:00.000Z")])
        eq(PosterCard(show: premiered, now: now).badges, [.new], "premiered eight days ago: New, rather than New Episode")
        let month = cinemetaShow(released: "2026-10-16T00:00:00.000Z", videos: [video(1, 5, "2026-11-13T08:00:00.000Z")])
        eq(PosterCard(show: month, now: now).badges, [.newEpisode], "a month old: its episodes are what is new")
        let later = cinemetaShow(released: "2026-12-01T00:00:00.000Z", videos: [])
        eq(PosterCard(show: later, now: now).badges, [], "a premiere to come is not new yet")
    }

    func testTheSavedShowListKeepsTheEpisodeFacts() {
        let show = cinemetaShow(videos: [video(2, 9, "2026-11-13T03:00:00.000Z")])
        let read = Mapper<Show>().mapArray(JSONArray: Mapper<Show>().toJSONArray([show]))
        eq(read.count, 1, "the show is read back")
        eq(read[0].latestEpisodeDate, show.latestEpisodeDate, "with its latest episode's date")
        eq(read[0].seasonCount, 2, "…and its seasons")
        eq(PosterCard(show: read[0], now: now), PosterCard(show: show, now: now), "the same card from the saved list")
        // A show the list knows nothing of says the latest season of the episodes it came with
        // (the releases of the week of a show in its fifth season), specials and years aside.
        var listed = Show(title: "Slow Horses", id: "tt5875444")
        listed.episodes = [5, 5, 0, 2026].enumerated().map { index, season in
            Episode(title: "E", id: "tt5875444-s\(season)e\(index)", episode: index, season: season)
        }
        eq(PosterCard(show: listed, now: now).seasons, 5, "the latest season of the episodes it has")
        var loaded = show
        loaded.episodes = listed.episodes
        eq(PosterCard(show: loaded, now: now).seasons, 2, "what the list said comes first")
        eq(PosterCard(show: Show(title: "Unknown", id: "tt1"), now: now).seasons, nil, "nothing known, nothing said")
    }

    // MARK: - The library's side

    func testWhatTheLibraryKnows() {
        let movie = ytsMovie(uploaded: nil, qualities: ["1080p"])
        let watching = PosterCard(movie: movie, watch: PosterCard.WatchState(progress: 0.42, isInWatchlist: true), now: now)
        eq(watching.progress, 0.42, "a started movie shows its progress")
        check(watching.isInWatchlist && !watching.isWatched, "in the watchlist, not watched")
        let watched = PosterCard(movie: movie, watch: PosterCard.WatchState(isWatched: true, progress: 0.93), now: now)
        check(watched.isWatched && watched.progress == nil, "a watched movie has a tick, not a bar")
        eq(PosterCard(movie: movie, watch: PosterCard.WatchState(progress: 0.01), now: now).progress, nil, "only opened: no bar")
        eq(PosterCard(movie: movie, watch: PosterCard.WatchState(progress: 0.02), now: now).progress, 0.02, "started at 2 %")
        eq(PosterCard(movie: movie, watch: PosterCard.WatchState(progress: 1), now: now).progress, nil, "at its end: no bar")

        // A followed show whose list says nothing: the library's new episode.
        let show = Show(title: "Slow Horses", id: "tt5875444")
        let aired = PosterCard.WatchState(progress: 0.3, newEpisodeDate: date("2026-11-11T00:00:00Z"))
        let card = PosterCard(show: show, watch: aired, now: now)
        eq(card.badges, [.newEpisode], "the library knows an episode aired three days ago")
        eq(card.progress, 0.3, "…and where the user is in the episode in progress")
        eq(PosterCard(show: show, watch: PosterCard.WatchState(newEpisodeDate: date("2026-10-11T00:00:00Z")), now: now).badges, [],
           "an episode of last month is not this week's")
    }

    func testThePosterLibraryReadsTheLibrary() {
        let storage = MemoryLibraryStorage([
            "moviesProgress": ["tt0816692": Float(0.55), "tt1375666": Float(0.93)] as [String: Any],
            "moviesWatchedlist": ["tt1375666"],
            "episodesProgress": ["tt0903747-s1e2": Float(0.42)] as [String: Any],
            "moviesWatchlist": [["imdb_id": "tt0111161", "title": "The Shawshank Redemption", "year": "1994"]],
        ])
        let clock = now
        let library = Library(storage: storage, guideDirectory: nil, remote: .offline, center: NotificationCenter(), now: { clock })
        let posters = PosterLibrary(library: library)

        eq(posters.watchState(ofMovie: "tt0816692"), PosterCard.WatchState(progress: Double(Float(0.55))), "a movie in progress")
        check(posters.watchState(ofMovie: "tt1375666").isWatched, "a watched movie")
        check(posters.watchState(ofMovie: "tt0111161").isInWatchlist, "a movie of the watchlist")
        eq(posters.watchState(ofMovie: "tt9999999"), PosterCard.WatchState(), "a movie the library does not know")
        eq(posters.watchState(ofShow: "tt0903747").progress, Double(Float(0.42)), "a show takes the progress of its episode in progress")
        eq(posters.watchState(ofShow: "tt0944947").progress, 0, "a show never played has none")

        let card = posters.card(for: Movie(title: "Interstellar", id: "tt0816692"), now: now)
        eq(card?.progress, Double(Float(0.55)), "the card of a movie carries it")
        check(posters.card(for: Show(title: "Breaking Bad", id: "tt0903747"), now: now)?.progress != nil, "the card of a show too")

        // The shows' answers are gathered once, until the library changes.
        library.setProgress(0.6, id: "tt0944947-s1e1", list: .episodes)
        eq(posters.watchState(ofShow: "tt0944947").progress, 0, "kept until told")
        posters.invalidate()
        eq(posters.watchState(ofShow: "tt0944947").progress, Double(Float(0.6)), "read again after a change")
        // Movies are read live.
        library.setWatched(true, id: "tt0816692", list: .movies)
        check(posters.watchState(ofMovie: "tt0816692").isWatched, "a movie marked watched is watched at once")
    }

    // MARK: - One truth per title

    /// The formats a card names, on every screen: the two best — Dolby Vision (which says
    /// HDR), HDR, 4K, Atmos — in the cards' order. No list hides one.
    func testACardNamesItsTwoBestFormats() {
        eq(HomeBadge.cardFormats([.uhd, .dolbyVision, .hdr, .atmos]), [.uhd, .dolbyVision], "4K · DV: Dolby Vision first, then 4K")
        eq(HomeBadge.cardFormats([.dolbyVision, .hdr, .atmos]), [.dolbyVision, .atmos], "DV · ATMOS: HDR goes with Dolby Vision")
        eq(HomeBadge.cardFormats([.uhd, .hdr, .atmos]), [.uhd, .hdr], "4K · HDR")
        eq(HomeBadge.cardFormats([.uhd, .atmos]), [.uhd, .atmos], "4K · ATMOS")
        eq(HomeBadge.cardFormats([.atmos, .new]), [.atmos], "an editorial badge is not a format")
        eq(HomeBadge.cardFormats([.uhd]), [.uhd], "4K alone stays: never hidden")
        eq(HomeBadge.cardFormats([.new, .newEpisode]), [], "none")
        eq(HomeBadge.cardFormats([.uhd, .dolbyVision, .atmos], limit: 1), [.dolbyVision], "the best one")
    }

    /// A grid's card takes what the Home says of its title; a title the Home does not list is
    /// told as the first screen that showed it.
    func testAGridCardIsToldAsTheHomeTellsIt() {
        let facts = HomeTitleFacts()
        facts.record([HomeItem(imdbId: "tt12042730", kind: .movie, title: "Project Hail Mary", year: 2026, rating: 8.2,
                               badges: [.uhd, .dolbyVision, .hdr, .atmos])])
        let clock = now
        let library = Library(storage: MemoryLibraryStorage([:]), guideDirectory: nil, remote: .offline, center: NotificationCenter(), now: { clock })
        let posters = PosterLibrary(library: library, facts: facts)
        let card = posters.card(for: ytsMovie(rating: 8.4), now: now)
        eq(card?.rating, 8.2, "the Home's rating, not the list's 8,4")
        eq(card?.badges, [.uhd, .dolbyVision, .hdr, .atmos], "the Home's formats; its editorial badges (none) instead of the grid's New")

        // Not on the Home: the first screen's facts, then the same everywhere.
        var first = Movie(yts: ["imdb_code": "tt0000042", "title": "Some Film", "year": 2024, "rating": 6.6])!
        eq(posters.card(for: first, now: now)?.rating, 6.6, "the first screen tells it")
        first = Movie(yts: ["imdb_code": "tt0000042", "title": "Some Film", "year": 2024, "rating": 7.0])!
        eq(posters.card(for: first, now: now)?.rating, 6.6, "another list says the same afterwards")

        // A working title takes the real one the app knows.
        facts.record([HomeItem(imdbId: "tt32357218", kind: .movie, title: "Mutiny", rating: 6.1)])
        let untitled = Movie(yts: ["imdb_code": "tt32357218", "title": "Untitled Jason Statham thriller", "year": 2026, "rating": 6.1])!
        eq(posters.card(for: untitled, now: now)?.title, "Mutiny", "the real title")
        // …and a working title never replaces a real one.
        facts.record([HomeItem(imdbId: "tt32357218", kind: .movie, title: "Untitled Jason Statham thriller", rating: 6.1)])
        eq(facts.facts(of: "tt32357218")?.title, "Mutiny", "kept")
    }

    /// YTS gives the English title beside the original one: the English one.
    func testYTSEnglishTitle() {
        let both = Movie(yts: ["imdb_code": "tt0000043", "title": "Le Comte de Monte-Cristo", "title_english": "The Count of Monte Cristo",
                               "year": 2024, "rating": 7.7])!
        eq(both.title, "The Count of Monte Cristo", "title_english first")
        let empty = Movie(yts: ["imdb_code": "tt0000043", "title": "Le Comte de Monte-Cristo", "title_english": " ", "year": 2024])!
        eq(empty.title, "Le Comte de Monte-Cristo", "an empty English title is no title")
        let home = HomeParse.ytsEntry(["imdb_code": "tt0000043", "title": "Le Comte de Monte-Cristo",
                                       "title_english": "The Count of Monte Cristo", "year": 2024])
        eq(home?.item.title, "The Count of Monte Cristo", "the Home's YTS cards too")
    }
}
