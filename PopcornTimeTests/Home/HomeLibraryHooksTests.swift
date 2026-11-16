//
//  HomeLibraryHooksTests.swift
//  PopcornTimeTests
//
//  The bridge between the user's library and the Home hub (PopcornKit, HomeLibraryHooks.swift):
//  the library's values as cards, the hooks answered by a library, a hub that follows the
//  library's changes without a request, the followed shows' episodes asked once (by the
//  library), a library migrated from 5.2 (ids only) named in one refresh without a card from
//  the calendar's window, the library's files read before the hub asks, and the one switch for
//  "send my followed shows to Cinemeta in one request". A library in memory, the recorded
//  answers, no real clock.
//

import Foundation
import XCTest
@testable import PopcornKit

final class HomeLibraryHooksTests: CheckedTestCase {

    private typealias F = LibraryFixtures

    /// The library's network: Cinemeta's calendar as recorded (Fixtures/Library), nothing else.
    private final class Remote {
        private let lock = NSLock()
        private var calls: [[String]] = []
        var calendarCalls: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }

        func make() -> LibraryRemote {
            return LibraryRemote(calendar: { [self] ids, done in
                lock.lock(); calls.append(ids); lock.unlock()
                let known = LibraryRemote.guides(fromCinemetaCalendar: Fixtures.data("Library/cm_calendar_videos.json")) ?? []
                done(known.filter { ids.contains($0.showID) })
            }, tvmazeGuide: { _, done in done(.unreachable) }, title: { _, _, done in done(.unreachable) })
        }
    }

    /// MobLand watched through S2E8 on Nov 7; Nocturne and From (shows), two movies in the
    /// watchlist; Project Hail Mary stopped at 40 % a moment ago.
    private func library(_ remote: Remote, clock: F.Clock, center: NotificationCenter = NotificationCenter()) -> Library {
        let storage = MemoryLibraryStorage()
        storage.set([["imdb_id": "tt26598805", "title": "Nocturne", "year": "2026", "genres": ["Crime", "Drama", "Thriller"]],
                     ["imdb_id": "tt9813792", "title": "From"]], forKey: "showsWatchlist")
        storage.set([["imdb_id": "tt0111161", "title": "The Shawshank Redemption", "year": "1994", "genres": ["Drama"],
                      "images": ["poster": "https://example.org/shawshank.jpg"]],
                     ["imdb_id": "tt0816692", "title": "Interstellar", "year": "2014"],
                     ["imdb_id": "tt0000001", "title": ""]], forKey: "moviesWatchlist")
        let library = Library(storage: storage, guideDirectory: nil, remote: remote.make(), center: center, now: { clock.now })
        library.tvmazeSpacing = 0
        let today = clock.now
        clock.now = F.date("2026-11-07T21:00:00Z")
        for episode in 1...8 { library.setWatched(true, id: "tt31510819-s2e\(episode)", list: .episodes) }
        clock.now = today
        library.setProgress(0.4, id: "tt12042730", list: .movies,
                            details: PlaybackDetails(title: "Project Hail Mary", runtime: 156, position: 3744, duration: 9360))
        return library
    }

    // MARK: - Cards

    func testContinueWatchingCards() {
        let played = F.date("2026-11-14T12:00:00Z")
        let movie = ContinueWatchingItem(kind: .movie, reason: .resume, imdbID: "tt12042730", mediaID: "tt12042730",
                                         title: "Project Hail Mary", season: nil, episode: nil, episodeTitle: nil,
                                         progress: 0.4, position: 3744, duration: 9360, runtime: 156, updatedAt: played)
        guard let card = HomeItem(resuming: movie) else { return XCTFail("a named movie has a card") }
        check(card.id == "tt12042730" && card.imdbId == "tt12042730" && card.kind == .movie, "a movie card, under its IMDb id")
        eq(card.title, "Project Hail Mary", "its title")
        eq(card.progress.map { ($0 * 100).rounded() }, 40, "its progress, 0…1")
        eq(card.remainingMinutes, 94, "the time left, from the player's own duration (9360 − 3744 s)")
        eq(card.runtimeMinutes, 156, "the catalogue runtime")
        eq(card.backdropURL?.absoluteString, "https://images.metahub.space/background/large/tt12042730/img", "the backdrop by IMDb id")
        eq(card.posterURL?.absoluteString, "https://images.metahub.space/poster/medium/tt12042730/img", "the poster by IMDb id")
        eq(card.logoURL?.absoluteString, "https://images.metahub.space/logo/medium/tt12042730/img", "the logo by IMDb id")
        check(card.episode == nil && card.date == played, "no episode; dated by the last play")
        check(card.movie?.id == "tt12042730" && card.show == nil, "it opens the movie's page")

        // A show whose last episode was finished: the next one, not started.
        let next = ContinueWatchingItem(kind: .show, reason: .nextUp, imdbID: "tt31510819", mediaID: "tt31510819-s2e9",
                                        title: "MobLand", season: 2, episode: 9, episodeTitle: "Nervous Breakdown",
                                        progress: 0, position: nil, duration: nil, runtime: 47, updatedAt: played)
        guard let show = HomeItem(resuming: next) else { return XCTFail("a named show has a card") }
        check(show.id == "tt31510819:2:9" && show.imdbId == "tt31510819" && show.kind == .show, "an episode card of the show")
        eq(show.episode, HomeEpisode(season: 2, number: 9, title: "Nervous Breakdown",
                                     stillURL: URL(string: "https://episodes.metahub.space/tt31510819/2/9/w780.jpg")),
           "the episode it continues with, and its still")
        check(show.progress == 0 && show.remainingMinutes == 47, "not started: a whole episode left")
        eq(show.landscapeURLs.map(\.absoluteString), ["https://episodes.metahub.space/tt31510819/2/9/w780.jpg",
                                                      "https://images.metahub.space/background/large/tt31510819/img"],
           "the still, then the show's backdrop")
        check(show.show?.id == "tt31510819" && show.movie == nil, "it opens the show's page")

        // An episode in progress, nothing known about its length.
        let resumed = ContinueWatchingItem(kind: .show, reason: .resume, imdbID: "tt0944947", mediaID: "tt0944947-s2e3",
                                           title: "Game of Thrones", season: 2, episode: 3, episodeTitle: nil,
                                           progress: 0.31, position: nil, duration: nil, runtime: nil, updatedAt: played)
        let resumedCard = HomeItem(resuming: resumed)
        check(resumedCard?.remainingMinutes == nil && resumedCard?.episode?.title == nil, "no runtime, no duration: no time left to show")
        eq(resumedCard?.progress.map { ($0 * 100).rounded() }, 31, "the progress is still there")

        // Almost over: a minute is the least a card says.
        let ending = ContinueWatchingItem(kind: .movie, reason: .resume, imdbID: "tt0816692", mediaID: "tt0816692", title: "Interstellar",
                                          season: nil, episode: nil, episodeTitle: nil, progress: 0.79, position: 9990, duration: 10000,
                                          runtime: nil, updatedAt: played)
        eq(HomeItem(resuming: ending)?.remainingMinutes, 1, "ten seconds left read as one minute, not zero")

        // An entry migrated from 5.2 only has ids until the library names it: no card meanwhile.
        let unnamed = ContinueWatchingItem(kind: .movie, reason: .resume, imdbID: "tt15239678", mediaID: "tt15239678", title: nil,
                                           season: nil, episode: nil, episodeTitle: nil, progress: 0.37, position: nil, duration: nil,
                                           runtime: nil, updatedAt: played)
        check(HomeItem(resuming: unnamed) == nil, "a title the library cannot name yet has no card")
    }

    func testWatchlistCards() {
        let stored = WatchlistItem(kind: .show, imdbID: "tt26598805", title: "Nocturne", year: "2026",
                                   posterURL: URL(string: "https://example.org/nocturne.jpg"), genres: ["Crime", "Drama"])
        guard let card = HomeItem(watchlisted: stored) else { return XCTFail("a watchlisted show has a card") }
        check(card.id == "tt26598805" && card.kind == .show && card.title == "Nocturne", "the show, under its IMDb id")
        check(card.year == 2026 && card.genres == ["Crime", "Drama"], "the year and the genres stored with it")
        eq(card.posterURL?.absoluteString, "https://example.org/nocturne.jpg", "the stored poster")
        eq(card.backdropURL?.absoluteString, "https://images.metahub.space/background/large/tt26598805/img", "the backdrop by IMDb id")
        check(card.progress == nil && card.episode == nil && card.badges.isEmpty, "a plain title card")
        let bare = WatchlistItem(kind: .movie, imdbID: "tt0816692", title: "Interstellar", year: nil, posterURL: nil, genres: [])
        check(HomeItem(watchlisted: bare)?.kind == .movie && HomeItem(watchlisted: bare)?.year == nil, "a movie without a year")
        let untitled = WatchlistItem(kind: .movie, imdbID: "tt0000001", title: "", year: nil, posterURL: nil, genres: [])
        check(HomeItem(watchlisted: untitled) == nil, "no card without a title")

        eq(HomeLocalHooks.alternating([1, 3, 5, 7], [2, 4]), [1, 2, 3, 4, 5, 7], "one of each list in turn, then what is left")
        eq(HomeLocalHooks.alternating([Int](), [2, 4]), [2, 4], "one list alone keeps its order")
    }

    func testNewEpisodeCards() {
        let now = F.date("2026-11-14T15:40:00Z")
        func news(_ new: [GuideEpisode], upcoming: [GuideEpisode] = [], title: String? = "MobLand") -> ShowNewEpisodes {
            return ShowNewEpisodes(showID: "tt31510819", showTitle: title, new: new, upcoming: upcoming, unacknowledged: new)
        }
        let s2e9 = F.episode(2, 9, aired: "2026-11-13T03:00:00Z", title: "Nervous Breakdown")
        let s2e10 = F.episode(2, 10, aired: "2026-11-20T03:00:00Z")

        guard let card = HomeItem(newEpisodesOf: news([F.episode(2, 8, aired: "2026-11-06T03:00:00Z"), s2e9], upcoming: [s2e10]), now: now) else {
            return XCTFail("a show with new episodes has a card")
        }
        check(card.id == "tt31510819:2:9" && card.imdbId == "tt31510819" && card.kind == .show && card.title == "MobLand",
              "the card of its most recent new episode")
        eq(card.episode, HomeEpisode(season: 2, number: 9, title: "Nervous Breakdown",
                                     stillURL: URL(string: "https://episodes.metahub.space/tt31510819/2/9/w780.jpg"),
                                     airDate: F.date("2026-11-13T03:00:00Z")), "the episode, its still and its date")
        eq(card.badges, [.newEpisode], "aired this week: New Episode")
        eq(card.date, F.date("2026-11-13T03:00:00Z"), "dated by the airing")
        eq(card.backdropURL?.absoluteString, "https://images.metahub.space/background/large/tt31510819/img", "the show's backdrop by IMDb id")

        eq(HomeItem(newEpisodesOf: news([F.episode(1, 1, aired: "2026-11-13T03:00:00Z")]), now: now)?.badges, [.premiere],
           "the first episode of a show: Series Premiere")
        eq(HomeItem(newEpisodesOf: news([F.episode(3, 1, aired: "2026-11-13T03:00:00Z")]), now: now)?.badges, [.newSeason],
           "the first episode of another season: New Season")
        eq(HomeItem(newEpisodesOf: news([F.episode(2, 5, aired: "2026-11-04T03:00:00Z")]), now: now)?.badges, [],
           "new for this user but aired ten days ago: no pill")
        let upcoming = HomeItem(newEpisodesOf: news([], upcoming: [s2e10, F.episode(2, 11, aired: "2026-11-21T03:00:00Z")]), now: now)
        check(upcoming?.id == "tt31510819:2:10" && upcoming?.badges == [.upcoming], "nothing new: the next one to air, Upcoming")
        check(HomeItem(newEpisodesOf: news([s2e9], title: nil), now: now) == nil, "a show the library cannot name has no card (until it is named)")
        check(HomeItem(newEpisodesOf: news([]), now: now) == nil, "nothing new, nothing coming: no card")
    }

    // MARK: - Hooks

    func testHooksAnswerFromTheLibrary() {
        let clock = F.Clock("2026-11-14T15:40:00Z")
        let remote = Remote()
        let library = self.library(remote, clock: clock)
        let hooks = HomeLocalHooks(library: library, now: { clock.now })

        eq(library.followedShowIDs(), ["tt31510819", "tt9813792", "tt26598805"], "the library follows the show being watched, then the watchlist's shows")
        eq(hooks.followedShowIds(), [], "…and keeps them to itself: it asks their airings, the hub does not ask them a second time")
        eq(hooks.continueWatching().map(\.id), ["tt12042730"], "the movie in progress (MobLand has no guide yet: no card)")
        eq(hooks.continueWatching().first?.remainingMinutes, 94, "with its time left")
        check(hooks.newEpisodes().isEmpty, "no airings known yet")
        check(hooks.isWatched("tt31510819", 2, 8) && !hooks.isWatched("tt31510819", 2, 9) && !hooks.isWatched("tt26598805", 1, 4),
              "the watched marks, by show, season and episode")
        eq(hooks.watchlist().map(\.imdbId), ["tt0816692", "tt9813792", "tt0111161", "tt26598805"],
           "movies and shows in turn, the latest added first; the untitled entry has no card")
        eq(hooks.watchlist().map(\.kind), [.movie, .show, .movie, .show], "each card knows its kind")
        eq(hooks.watchlist().first { $0.imdbId == "tt0111161" }?.posterURL?.absoluteString, "https://example.org/shawshank.jpg", "the stored poster")
        eq(hooks.watchlist().first { $0.imdbId == "tt26598805" }?.genres, ["Crime", "Drama", "Thriller"],
           "the stored genres (what the hub picks its genre shelves from)")
        check(remote.calendarCalls.isEmpty, "answering the hooks asked nothing")

        // The hub is about to refresh: the library brings its airings up to date, on its own.
        hooks.willRefresh()
        check(homeWait { !hooks.newEpisodes().isEmpty }, "the airings arrive")
        eq(remote.calendarCalls, [["tt31510819", "tt9813792", "tt26598805"]], "one request for the followed shows")
        let news = hooks.newEpisodes()
        eq(news.map(\.id), ["tt26598805:1:4", "tt31510819:2:9"], "one card per show with news, the latest aired first (From has none)")
        check(news.allSatisfy { $0.badges == [.newEpisode] && $0.kind == .show }, "both aired this week")
        eq(news.last?.episode?.title, "Nervous Breakdown", "with the episode's title")
        eq(hooks.continueWatching().map(\.id), ["tt12042730", "tt31510819:2:9"],
           "and MobLand now has its next episode in Continue Watching, after the movie played last")
        hooks.willRefresh()
        homeSettle()
        eq(remote.calendarCalls.count, 1, "fresh airings are not asked again at the next refresh")

        // Watching the episode moves both shelves.
        library.setWatched(true, id: "tt31510819-s2e9", list: .episodes)
        check(hooks.isWatched("tt31510819", 2, 9), "watched")
        eq(hooks.newEpisodes().map(\.id), ["tt26598805:1:4", "tt31510819:2:10"], "MobLand's card is its next airing")
        eq(hooks.newEpisodes().last?.badges, [.upcoming], "…marked Upcoming")
    }

    func testCardsOfWatchlistedTitlesHaveTheirYearAndGenres() {
        let clock = F.Clock("2026-11-14T15:40:00Z")
        let remote = Remote()
        let library = self.library(remote, clock: clock)
        let hooks = HomeLocalHooks(library: library, now: { clock.now })
        hooks.willRefresh()
        check(homeWait { !hooks.newEpisodes().isEmpty }, "the airings arrive")
        library.setProgress(0.5, id: "tt0111161", list: .movies, details: PlaybackDetails(title: "The Shawshank Redemption", runtime: 142))

        // The watchlist is where the library keeps a title's year and genres: its other cards say them too.
        let news = hooks.newEpisodes()
        eq(news.map(\.id), ["tt26598805:1:4", "tt31510819:2:9"], "Nocturne (watchlisted) and MobLand (only watched)")
        check(news.first?.year == 2026 && news.first?.genres == ["Crime", "Drama", "Thriller"], "Nocturne's new episode has the show's year and genres")
        check(news.first?.episode?.number == 4 && news.first?.badges == [.newEpisode] && news.first?.date != nil
              && news.first?.date == news.first?.episode?.airDate, "…and is still the card of its episode")
        check(news.last?.year == nil && news.last?.genres == [], "a show that is not in the watchlist: nothing is known, nothing is asked")
        let resume = hooks.continueWatching()
        eq(resume.map(\.id), ["tt0111161", "tt12042730", "tt31510819:2:9"], "the movie just played, the one before, MobLand's next episode")
        check(resume[0].year == 1994 && resume[0].genres == ["Drama"], "the resume card of a watchlisted movie has its year and genres")
        eq(resume[0].posterURL?.absoluteString, "https://images.metahub.space/poster/medium/tt0111161/img", "and keeps its own artwork")
        check(resume[0].progress == 0.5 && resume[0].remainingMinutes == 71, "…its progress and its time left")
        check(resume[1].year == nil && resume[1].genres.isEmpty, "a movie that is not in the watchlist has neither")

        // What the hub's genre shelves are picked from: a title counts once, by its first card
        // (resume cards and new episodes come before the watchlist). Nocturne's new-episode
        // card had no genres and hid the ones stored with the show.
        var local = HomeLocal()
        local.continueWatching = resume
        local.newEpisodes = news
        local.watchlist = hooks.watchlist()
        let chosen = HomeBuilder.genreChoices(local, limit: 4).map { "\($0.kind.rawValue) \($0.genre)" }
        eq(Set(chosen), ["movie Drama", "show Crime", "show Drama", "show Thriller"], "the genres of the user's titles, a watched one included")
        check(remote.calendarCalls.count == 1, "nothing else was asked")
    }

    // MARK: - The hub follows the library

    func testTheHubFollowsTheLibrary() {
        let clock = F.Clock("2026-11-14T14:40:00Z")   // when the hub's fixtures were recorded
        let remote = Remote()
        let center = NotificationCenter()
        let library = self.library(remote, clock: clock, center: center)
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let network = HomeFakeNetwork()

        var localReads = 0
        var hooks = HomeLocalHooks(library: library, now: { clock.now })
        let news = hooks.newEpisodes
        hooks.newEpisodes = { localReads += 1; return news() }
        let feed = HomeFeed(store: HomeStore(directory: sandbox.directory, now: { clock.now }), transport: network.transport,
                            defaults: sandbox.defaults, deviceLanguages: { ["en-US"] }, hooks: hooks,
                            options: HomeFeed.Options(requestDeadline: .infinity, phaseGrace: .infinity), now: { clock.now })
        let token = feed.followChanges(of: library, center: center)

        var done = false
        feed.refresh { done = true }
        check(homeWait { done && feed.isIdle }, "the refresh ends")
        eq(remote.calendarCalls.count, 1, "refreshing the hub refreshed the library's airings")
        check(homeWait { feed.snapshot.shelf(HomeShelfID.yourShows)?.items.first?.id == "tt26598805:1:4" },
              "the library's new episodes reach the shelf when they arrive")
        let shows = feed.snapshot.shelf(HomeShelfID.yourShows)?.items ?? []
        eq(shows.map(\.id), ["tt26598805:1:4", "tt31510819:2:9"], "the shelf is the library's cards, and only them")
        eq(feed.snapshot.shelf(HomeShelfID.continueWatching)?.items.map(\.id), ["tt12042730", "tt31510819:2:9"], "Continue Watching, from the library")
        eq(feed.snapshot.shelf(HomeShelfID.watchlist)?.items.map(\.imdbId), ["tt0816692", "tt9813792", "tt0111161", "tt26598805"], "the watchlist")
        eq(Array(feed.snapshot.shelves.ids.prefix(3)), [HomeShelfID.hero, HomeShelfID.continueWatching, HomeShelfID.yourShows],
           "the library's shelves under the hero")
        check(!network.paths.contains { $0.contains("calendar-videos") }, "the hub asks no calendar of its own: one download, by the library")

        // A title is played: its card arrives without anyone telling the hub, and without a request.
        network.forget()
        clock.advance(60)
        library.setProgress(0.3, id: "tt0816692", list: .movies, details: PlaybackDetails(title: "Interstellar", runtime: 169))
        check(homeWait { feed.snapshot.shelf(HomeShelfID.continueWatching)?.items.first?.id == "tt0816692" }, "the card of the title just played comes first")
        eq(feed.snapshot.shelf(HomeShelfID.continueWatching)?.items.first?.remainingMinutes, 118, "70 % of 169 minutes left")
        eq(network.requests.count, 0, "the local shelves are recomputed without a request")
        eq(remote.calendarCalls.count, 1, "…and without asking the airings again")

        // A burst of changes (a season marked watched) recomputes the shelves once.
        homeSettle()
        let before = localReads
        for episode in 9...10 { library.setWatched(true, id: "tt31510819-s2e\(episode)", list: .episodes) }
        library.setWatched(true, id: "tt26598805-s1e4", list: .episodes)
        check(homeWait { feed.snapshot.shelf(HomeShelfID.yourShows)?.items.contains { $0.id == "tt26598805:1:4" } == false },
              "the episodes watched leave the shelf")
        homeSettle()
        eq(localReads - before, 1, "three changes in a row: one recomputation")

        // No longer followed: a change does nothing.
        center.removeObserver(token)
        library.setProgress(0.5, id: "tt0111161", list: .movies, details: PlaybackDetails(title: "The Shawshank Redemption"))
        homeSettle()
        check(localReads - before == 1 && feed.snapshot.shelf(HomeShelfID.continueWatching)?.items.first?.id == "tt0816692",
              "once the observation is removed the hub no longer follows")
    }

    // MARK: - A library migrated from 5.2

    func testAMigratedLibraryIsNamedInOneRefreshWithoutACardFromTheCalendar() {
        // 5.2 left ids only: Breaking Bad watched through S2E3, fourteen movies stopped halfway.
        // The hub refreshes. The calendar (one request) answers before the titles do, and its
        // ten episodes around today, S5E7…S5E16, are then all the library knows of the show.
        let clock = F.Clock("2026-11-14T14:40:00Z")
        let movies = (1...14).map { String(format: "tt80000%02d", $0) }
        let storage = MemoryLibraryStorage([
            "episodesWatchedlist": (1...7).map { "tt0903747-s1e\($0)" } + (1...3).map { "tt0903747-s2e\($0)" },
            "moviesProgress": Dictionary(uniqueKeysWithValues: movies.map { ($0, Float(0.4)) }) as [String: Any],
        ])
        // The titles answer when the test lets them.
        let lock = NSLock()
        var asked: [String] = []
        var held: [() -> Void] = []
        func askedCount() -> Int { lock.lock(); defer { lock.unlock() }; return asked.count }
        func release() {
            lock.lock(); let ready = held; held = []; lock.unlock()
            ready.forEach { $0() }
        }
        let remote = LibraryRemote(calendar: { ids, done in
            let known = LibraryRemote.guides(fromCinemetaCalendar: Fixtures.data("Library/cm_calendar_videos.json")) ?? []
            done(known.filter { ids.contains($0.showID) })
        }, tvmazeGuide: { _, done in done(.unreachable) }, title: { id, kind, done in
            let answer: LibraryRemote.Answer<LibraryRemote.Title>
            if kind == .movie {
                answer = .found(LibraryRemote.Title(imdbID: id, title: "Movie \(id)", runtime: 100))
            } else {
                answer = LibraryRemote.title(fromCinemetaMeta: Fixtures.data("Library/cm_meta_series_\(id).json"), imdbID: id).map { .found($0) } ?? .unknown
            }
            lock.lock(); asked.append(id); held.append { done(answer) }; lock.unlock()
        })
        let center = NotificationCenter()
        let library = Library(storage: storage, guideDirectory: nil, remote: remote, center: center, now: { clock.now })
        library.tvmazeSpacing = 0
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let feed = HomeFeed(store: HomeStore(directory: sandbox.directory, now: { clock.now }), transport: HomeFakeNetwork().transport,
                            defaults: sandbox.defaults, deviceLanguages: { ["en-US"] }, hooks: HomeLocalHooks(library: library, now: { clock.now }),
                            options: HomeFeed.Options(requestDeadline: .infinity, phaseGrace: .infinity), now: { clock.now })
        let token = feed.followChanges(of: library, center: center)
        defer { center.removeObserver(token) }
        // The Continue Watching shelf of every update the page gets.
        var shown: [[String]] = []
        feed.onUpdate = { shown.append($0.shelf(HomeShelfID.continueWatching)?.items.map(\.id) ?? []) }
        func resume() -> [HomeItem] { feed.snapshot.shelf(HomeShelfID.continueWatching)?.items ?? [] }

        var done = false
        feed.start { done = true }
        check(homeWait { done && feed.isIdle }, "the hub's refresh ends")
        check(homeWait { library.guides.guide("tt0903747")?.episodes.first?.number == F.number(5, 7) }, "the calendar answered: its window starts at S5E7")
        check(library.resume.entries(ofShow: "tt0903747").first?.title == "Breaking Bad", "…and named the show")
        homeSettle()
        eq(askedCount(), 12, "the first twelve titles are asked meanwhile")
        check(resume().isEmpty, "no card yet: the movies have no name, and S5E7 is not what follows S2E3", resume().map(\.id).joined(separator: " "))

        // The first titles answer: their cards, and the next ones are asked without the hub refreshing again.
        release()
        check(homeWait { askedCount() == 15 }, "the three titles left are asked by the same refresh")
        check(homeWait { resume().count == 12 }, "the twelve titles named have their cards")
        check(!resume().contains { $0.imdbId == "tt0903747" }, "Breaking Bad still has none")
        release()
        check(homeWait { resume().count == 15 }, "every title has its card after one refresh of the hub")
        let show = resume().first { $0.imdbId == "tt0903747" }
        eq(show?.id, "tt0903747:2:4", "Breaking Bad continues with S2E4")
        check(show?.episode?.title == "Down" && show?.title == "Breaking Bad" && show?.progress == 0, "…named by the whole guide, not started")
        check(resume().filter { $0.kind == .movie }.allSatisfy { $0.title == "Movie \($0.imdbId)" }, "the movies have their titles")
        homeSettle()
        check(!shown.joined().contains { $0.hasPrefix("tt0903747:5:") }, "no update ever showed an episode of the calendar's window",
              shown.joined().filter { $0.hasPrefix("tt0903747") }.joined(separator: " "))
        check(library.titlesToHydrate().isEmpty && askedCount() == 15, "nothing left to ask, nothing asked twice")
    }

    // MARK: - The library's files

    func testTheLibraryReadsItsFilesBeforeTheHubAsks() {
        let clock = F.Clock("2026-11-14T14:40:00Z")
        /// The library of a new launch (nothing in memory) after one that left MobLand at S2E9:
        /// its entry in the storage, its guide in a file of `folder`.
        func relaunched(in folder: URL) -> Library {
            let storage = MemoryLibraryStorage()
            let last = Library(storage: storage, guideDirectory: folder, remote: .offline, now: { clock.now })
            for episode in 1...8 { last.setWatched(true, id: "tt31510819-s2e\(episode)", list: .episodes, details: PlaybackDetails(title: "MobLand")) }
            last.noteGuide(showID: "tt31510819", title: "MobLand",
                           episodes: (1...10).map { F.episode(2, $0, aired: "2026-10-\(10 + $0)T03:00:00Z", title: "Episode \($0)") })
            last.guides.flush()
            return Library(storage: storage, guideDirectory: folder, remote: .offline, now: { clock.now })
        }
        let sandbox = HomeSandbox(), first = HomeSandbox(), files = HomeSandbox()
        defer { sandbox.discard(); first.discard(); files.discard() }

        // Without `preload` the first answer reads the guide's file (here: finds it gone).
        let unread = relaunched(in: first.directory), cold = relaunched(in: first.directory)
        // `preload` reads what the answers take from the disk, from any queue.
        let read = expectation(description: "preloaded")
        DispatchQueue.global().async { cold.preload(); read.fulfill() }
        wait(for: [read], timeout: 5)
        try? FileManager.default.removeItem(at: first.directory)
        eq(cold.continueWatching().map(\.mediaID), ["tt31510819-s2e9"], "after it the row is made from memory: the next episode comes from the guide")
        check(cold.titlesToHydrate().isEmpty && cold.followedShows().first?.title == "MobLand", "…and so are the other answers")
        check(unread.continueWatching().isEmpty, "(a library that did not read it has no guide to go by)")

        // The hub: `prepare` once, off the main queue, before any other hook — whichever call
        // comes first (a SwiftUI page calls `refreshLocal` in `onAppear`, before its task starts
        // the hub).
        let library = relaunched(in: files.directory)
        let lock = NSLock()
        var events: [String] = []
        func note(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
        func noted() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
        var hooks = HomeLocalHooks(library: library, now: { clock.now })
        let prepare = hooks.prepare, resume = hooks.continueWatching, willRefresh = hooks.willRefresh
        hooks.prepare = {
            note(Thread.isMainThread ? "prepare on the main queue" : "prepare")
            prepare()
            // From here on the disk is not needed.
            try? FileManager.default.removeItem(at: files.directory)
        }
        hooks.continueWatching = { note("continueWatching"); return resume() }
        hooks.willRefresh = { note("willRefresh"); willRefresh() }
        let feed = HomeFeed(store: HomeStore(directory: sandbox.directory, now: { clock.now }), transport: HomeFakeNetwork().transport,
                            defaults: sandbox.defaults, deviceLanguages: { ["en-US"] }, hooks: hooks,
                            options: HomeFeed.Options(requestDeadline: .infinity, phaseGrace: .infinity), now: { clock.now })
        feed.refreshLocal()
        check(!noted().contains { $0 != "prepare" }, "nothing is asked on the main queue before the files are read", noted().joined(separator: ", "))
        var done = false
        feed.start { done = true }
        check(homeWait { done && feed.isIdle }, "the refresh ends")
        homeSettle()
        eq(Array(noted().prefix(4)), ["prepare", "continueWatching", "willRefresh", "continueWatching"],
           "the files first, off the main queue; then the hooks, in the order the hub was called")
        eq(noted().filter { $0.hasPrefix("prepare") }.count, 1, "once")
        eq(feed.snapshot.shelf(HomeShelfID.continueWatching)?.items.map(\.id), ["tt31510819:2:9"],
           "the card that takes the guide was made from memory")
        var again = false
        feed.refresh { again = true }
        feed.refreshLocal()
        check(homeWait { again && feed.isIdle }, "later calls")
        homeSettle()
        eq(noted().filter { $0.hasPrefix("prepare") }.count, 1, "…do not read the files again")
    }

    // MARK: - One switch

    func testOneSwitchForTheFollowedShows() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let settings = HomeSettings(defaults: sandbox.defaults)
        let library = Library(storage: sandbox.defaults, guideDirectory: nil, remote: .offline, now: Date.init)
        check(settings.sendsFollowedShowsToCinemeta && library.isBulkEpisodeLookupEnabled, "both send the list by default")
        settings.sendsFollowedShowsToCinemeta = false
        check(!library.isBulkEpisodeLookupEnabled, "the hub's opt-out is the library's: its airings then come from TVMaze, show by show")
        eq(sandbox.defaults.object(forKey: Library.bulkEpisodeLookupKey) as? Bool, false, "one stored value")
        check(sandbox.defaults.object(forKey: "popcornkit.home.followedShowsOptOut") == nil, "no second key")
        library.isBulkEpisodeLookupEnabled = true
        check(settings.sendsFollowedShowsToCinemeta, "and the library's choice is the hub's")
    }
}
