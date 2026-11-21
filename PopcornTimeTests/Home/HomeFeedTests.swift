//
//  HomeFeedTests.swift
//  PopcornTimeTests
//
//  The loader of the Home on recorded answers: the first paint after exactly the four
//  requests of phase 1, each shelf as soon as its source answers, concurrent refreshes
//  joined, the stand-ins when a host is down (and at every refresh while it stays down), the
//  disk snapshot when everything is, "offline" only when the device is, the local shelves
//  without a request, the settings, and the observable state. The network is HomeFakeNetwork
//  (Fixtures/Home); nothing here reaches a host.
//

import Foundation
import XCTest
@testable import PopcornKit

final class HomeFeedTests: CheckedTestCase {

    /// Counts the times `HomeState.shelves` changed, as a view would be invalidated.
    private final class ShelvesObserver: @unchecked Sendable {
        var changes = 0

        @MainActor
        func observe(_ state: HomeState) {
            withObservationTracking { _ = state.shelves } onChange: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.changes += 1
                        self?.observe(state)
                    }
                }
            }
        }
    }

    /// A clock the tests move.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = HomeFixture.now
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return date }
            set { lock.lock(); date = newValue; lock.unlock() }
        }
    }

    private var sandbox: HomeSandbox!
    private var network: HomeFakeNetwork!
    private var clock: Clock!

    override func setUp() {
        super.setUp()
        sandbox = HomeSandbox()
        network = HomeFakeNetwork()
        clock = Clock()
    }

    override func tearDown() {
        // The Home's service filter lasts for the run (`HomeSettings.homeServiceFilter`).
        HomeSettings(defaults: sandbox.defaults).homeServiceFilter = nil
        sandbox.discard()
        super.tearDown()
    }

    /// A feed on the test's folder, defaults, network and clock. Phases wait for each other
    /// (no grace timer) and requests have no deadline, unless the test sets them.
    private func makeFeed(options: HomeFeed.Options = HomeFeed.Options(requestDeadline: .infinity, phaseGrace: .infinity),
                          hooks: HomeLocalHooks = HomeLocalHooks()) -> HomeFeed {
        let clock = self.clock!
        return HomeFeed(store: HomeStore(directory: sandbox.directory, now: { clock.now }), transport: network.transport,
                        defaults: sandbox.defaults, deviceLanguages: { ["en-US"] }, hooks: hooks, options: options, now: { clock.now })
    }

    /// Runs a whole refresh, and the lookups that follow it, and returns the snapshot at the end.
    @discardableResult
    private func load(_ feed: HomeFeed, force: Bool = false, file: StaticString = #filePath, line: Int = #line) -> HomeSnapshot {
        var done = false
        feed.refresh(force: force) { done = true }
        check(homeWait { done }, "the refresh ends", file: file, line: line)
        idle(feed)
        return feed.snapshot
    }

    /// Waits for the lookups a refresh leaves behind, and for their update to be delivered.
    private func idle(_ feed: HomeFeed) {
        homeWait { feed.isIdle }
        homeSettle(0.01)
    }

    /// Thirty new shows of the year: a complete list. The fixture's (ten) is an incomplete
    /// one, asked again at every refresh — which hides what a refresh with nothing else to
    /// ask does.
    private let newShowsPath = "/catalog/series/year/genre=2026.json"
    private let thirtyNewShows: Data = {
        let metas = (1...30).map {
            ["id": String(format: "tt91%05d", $0), "name": "New Show \($0)", "poster": "https://x/p.jpg", "released": "2026-11-01T00:00:00.000Z"]
        }
        return try! JSONSerialization.data(withJSONObject: ["metas": metas])
    }()

    /// Twenty titles of its own for each genre (the fake network answers every genre with the
    /// same list, and a title is in two shelves at most: two of four genre shelves are empty).
    private func genreTitles(_ request: HomeRequest) -> Data? {
        guard let range = request.path.range(of: "/top/genre=") else { return nil }
        let genre = String(request.path[range.upperBound...].dropLast(".json".count))
        let index = (HomeBuilder.cinemetaGenres.firstIndex(of: genre) ?? 0) + (request.path.contains("/series/") ? 50 : 0)
        let metas = (1...20).map { ["id": String(format: "tt92%02d%03d", index, $0), "name": "\(genre) \($0)", "poster": "https://x/p.jpg"] }
        return try! JSONSerialization.data(withJSONObject: ["metas": metas])
    }

    /// A refresh the test watches: every update it delivers, with its requests held until
    /// `release`. Returns the updates once it has ended.
    private func watch(_ feed: HomeFeed, start: () -> Void, whileHeld: () -> Void) -> [HomeSnapshot] {
        var updates: [HomeSnapshot] = []
        feed.onUpdate = { updates.append($0) }
        network.hold = true
        start()
        check(homeWait { !self.network.waiting.isEmpty }, "the refresh asks")
        homeSettle()
        whileHeld()
        network.hold = false
        network.release()
        check(homeWait { !feed.snapshot.isRefreshing }, "the refresh ends")
        idle(feed)
        feed.onUpdate = nil
        return updates
    }

    private let phase1: Set<String> = [
        "/catalog/movie/top.json", "/catalog/series/top.json",
        "/api/v2/list_movies.json?limit=50&order_by=desc&query_term=2026&sort_by=date_added&minimum_rating=6",
        "/api/v2/list_movies.json?limit=50&order_by=desc&quality=2160p&sort_by=date_added",
    ]

    // MARK: Phases

    func testFirstPaintAfterExactlyThePhase1Requests() {
        network.hold = true
        // Every page delivered as it is made (no spacing; `testUpdatesThatComeTogetherAreDeliveredAsOne`
        // tests the spacing): the fake network answers within milliseconds.
        var options = HomeFeed.Options(requestDeadline: .infinity, phaseGrace: .infinity)
        options.updateSpacing = 0
        let feed = makeFeed(options: options)
        var updates: [HomeSnapshot] = []
        feed.onUpdate = { updates.append($0) }
        var finished = false
        feed.start { finished = true }

        check(homeWait { self.network.waiting.count == 4 }, "phase 1 is asked")
        homeSettle()
        eq(Set(network.paths), phase1, "exactly the four requests of the first paint")
        eq(network.requests.count, 4, "nothing else while they are in flight")
        eq(updates.last?.isRefreshing, true, "the page knows it is loading")
        eq(updates.last?.shelves.count, 0, "nothing to show yet on a first launch")
        check(updates.last?.isUnavailable == false && updates.last?.isOffline == false, "loading is not failing")

        // One source answers: its shelves are there at once, the others do not hold them back.
        network.release { $0.path == "/catalog/movie/top.json" }
        check(homeWait { feed.snapshot.shelf(HomeShelfID.trendingMovies) != nil }, "the trending movies as soon as movie/top answers")
        eq(feed.snapshot.shelves.ids, [HomeShelfID.hero, HomeShelfID.trendingMovies], "hero (movies only so far) and trending movies")
        check(feed.snapshot.heroItems.allSatisfy { $0.kind == .movie }, "no show in the hero before series/top answers")
        eq(network.requests.count, 4, "still phase 1")

        network.release { $0.path == "/catalog/series/top.json" }
        check(homeWait { feed.snapshot.shelf(HomeShelfID.trendingShows) != nil }, "the trending shows next")
        eq(feed.snapshot.shelves.ids, [HomeShelfID.hero, HomeShelfID.trendingMovies, HomeShelfID.airedEpisodes, HomeShelfID.trendingShows],
           "with the latest episodes read off series/top, before any TV schedule is asked")
        eq(feed.snapshot.heroItems.map(\.title).prefix(3).map { $0 }, ["Heart of the Beast", "Resident Evil", "MobLand"], "the hero is complete")
        eq(network.requests.count, 4, "still phase 1")

        // The last two: the first paint is whole, and only now is phase 2 asked.
        network.release()
        check(homeWait { self.network.waiting.count == 9 }, "phase 2 starts when phase 1 has answered")
        homeSettle()
        eq(feed.snapshot.shelves.ids, [HomeShelfID.hero, HomeShelfID.trendingMovies, HomeShelfID.newMovies, HomeShelfID.uhd,
                                      HomeShelfID.airedEpisodes, HomeShelfID.trendingShows], "the first paint: six shelves from four requests")
        eq(network.requests.count, 13, "four + the nine of phase 2, none of them answered")
        eq(Set(network.waiting.map(\.host)), [.yts, .cinemeta, .tvmaze], "the year's rankings, the new shows, the schedules")
        eq(network.waiting.filter { $0.host == .tvmaze }.count, 6, "three days of platforms and US networks")
        check(feed.snapshot.isRefreshing && !finished, "still refreshing")

        network.hold = false
        network.release()
        check(homeWait { finished }, "the refresh ends")
        let snapshot = feed.snapshot
        check(!snapshot.isRefreshing && !snapshot.isOffline && !snapshot.isUnavailable, "done, online")
        eq(Array(snapshot.shelves.ids.prefix(11)), [HomeShelfID.hero, HomeShelfID.trendingMovies, HomeShelfID.newMovies, HomeShelfID.uhd,
                                                    HomeShelfID.airedEpisodes, HomeShelfID.trendingShows, HomeShelfID.newShows, HomeShelfID.moviesOfTheYear,
                                                    HomeShelfID.topRatedOfTheYear, HomeShelfID.topShows, HomeShelfID.topMovies], "the whole page")
        check(snapshot.shelves.ids.contains(HomeShelfID.genre(.movie, "Action")) && snapshot.shelves.ids.contains(HomeShelfID.genre(.show, "Drama")), "and the genre shelves")
        eq(snapshot.lastUpdated, HomeFixture.now, "updated now")
        eq(snapshot.shelf(HomeShelfID.airedEpisodes)?.titles.first, "Honey", "the latest episodes now come from the schedules")

        // 4 + 9 + the new shows of 2025 (2026's list is short in the fixtures) + 3 rankings
        // + 4 genres + the lookups (one request for the shows, one per movie).
        let paths = network.paths
        eq(paths.count, 4 + 9 + 1 + 3 + 4 + 1 + 2, "24 requests for a cold load of everything")
        eq(Set(paths).count, paths.count, "none asked twice")
        check(paths.contains("/catalog/series/year/genre=2025.json"), "the year before, because this year's new shows are fewer than thirty")
        eq(paths.filter { $0.hasPrefix("/precompiled/") }.count, 3, "the rankings")
        eq(paths.filter { $0.contains("/top/genre=") }.count, 4, "the default genres")
        eq(paths.filter { $0.hasPrefix("/catalog/series/last-videos/") },
           ["/catalog/series/last-videos/lastVideosIds=tt0121955,tt0141842,tt0413573,tt10986410,tt14688458,tt26545992,tt2861424,tt33332385,tt35854736,tt36849871,tt37522541,tt7631058.json"],
           "one request for the shows of the Top 100's first twenty nobody knew")
        // The Top 100's leading titles the lists of the day do not know: Coyote vs. Acme and Buddy
        // (recorded). The Cycle is not among the first twenty any more: Resident Evil and Project
        // Hail Mary count their releases without an IMDb id.
        eq(Set(paths.filter { $0.hasPrefix("/meta/movie/") }), ["/meta/movie/tt1756855.json", "/meta/movie/tt37281055.json"],
           "one per unknown movie")
        let firstRanking = paths.firstIndex { $0.hasPrefix("/precompiled/") }!, lastSchedule = paths.lastIndex { $0.hasPrefix("/schedule") }!
        check(firstRanking > lastSchedule, "phase 3 after phase 2")
        check(paths.firstIndex { $0.hasPrefix("/catalog/series/last-videos/") }! > paths.lastIndex { $0.contains("/top/genre=") }!, "the lookups last")
        // The refresh did not wait for the lookups: the ranking fills in when they answer.
        let known = ["MobLand", "VisionQuest", "Dexter: Resurrection", "Tulsa King", "Slow Horses", "The Gilded Age", "12 12 12"]
        eq(snapshot.shelf(HomeShelfID.topShows)?.titles.prefix(8).map { $0 }, known + ["Nocturne"], "the ranking with the cards the lists know")
        idle(feed)
        // The recorded lookup knows one of the twelve shows asked: Grey's Anatomy, 16th of the list.
        eq(feed.snapshot.shelf(HomeShelfID.topShows)?.titles.prefix(8).map { $0 }, known + ["Grey's Anatomy"], "the lookups filled the ranking")
        // The movies' Top 100: the lists of the day know most of its titles, so it is on the page
        // before the lookups, which add theirs at their rank.
        let before = snapshot.shelf(HomeShelfID.topMovies)?.titles ?? []
        // Releases without an IMDb id count, offline, from the recorded list alone: Resident Evil
        // (4,748 + 1,478 seeders) is 4th, Project Hail Mary (3,880, its only release here) 7th.
        eq(Array(before.prefix(5)), ["The Odyssey", "Spider-Man: Brand New Day", "Heart of the Beast", "Resident Evil", "Primetime"], "the movies' ranking with the cards the lists know")
        eq(before.firstIndex(of: "Project Hail Mary"), 6, "Project Hail Mary: the film of that name and year the lists know")
        check(!before.contains("Coyote vs. Acme") && !before.contains("Buddy"), "not yet the titles no list knows")
        let after = feed.snapshot.shelf(HomeShelfID.topMovies)?.titles ?? []
        eq(after.firstIndex(of: "Coyote vs. Acme"), 11, "the lookups put Coyote vs. Acme at its rank")
        eq(after.firstIndex(of: "Buddy"), 14, "and Buddy")
        check(!after.contains("The Cycle"), "a title nobody asked Cinemeta about stays out")
        check(!after.contains("Street Fighter"), "Street Fighter: no release with an id, and no list knows it")
        eq(after.count, 20, "twenty titles, the ranking's size")
        eq(feed.snapshot.shelves.ids[10], HomeShelfID.topMovies, "in its place, after the shows' ranking")
        check(!feed.snapshot.isRefreshing, "without a refresh")
        check(updates.count >= 8, "the page was updated as the answers came", "\(updates.count) updates")
        check(zip(updates, updates.dropFirst()).allSatisfy { $0 != $1 }, "never twice the same snapshot")
    }

    func testAHostThatHangsDoesNotHoldTheNextPhaseBack() {
        network.hold = true
        let feed = makeFeed(options: HomeFeed.Options(requestDeadline: .infinity, phaseGrace: 0.05))
        feed.start()
        // Nothing answers phase 1; after the grace phase 2 is asked anyway, then phase 3.
        check(homeWait { self.network.requests.count >= 4 + 9 + 3 }, "the later phases start without waiting for a silent host")
        eq(network.waiting.count, network.requests.count, "nothing answered")
        check(feed.snapshot.isRefreshing, "still refreshing")
        network.hold = false
        network.release()
        check(homeWait { !feed.snapshot.isRefreshing && feed.snapshot.shelf(HomeShelfID.hero) != nil }, "and the refresh ends, with the page, when the answers come")
        idle(feed)
    }

    func testARequestThatNeverAnswersIsAFailure() {
        network.hold = true
        let feed = makeFeed(options: HomeFeed.Options(requestDeadline: 0.05, phaseGrace: .infinity))
        var finished = false
        feed.start { finished = true }
        check(homeWait { finished }, "the deadline ends the refresh")
        check(feed.snapshot.isUnavailable && feed.snapshot.isOffline && feed.snapshot.shelves.isEmpty, "nothing answered, nothing cached: unavailable")
        // The answers arriving after the deadline are ignored.
        network.release()
        homeSettle()
        check(feed.snapshot.shelves.isEmpty, "a late answer does not come back from the dead")
    }

    func testConcurrentRefreshesShareOneLoad() {
        network.hold = true
        let feed = makeFeed()
        var completions = 0
        feed.start { completions += 1 }
        feed.refresh { completions += 1 }
        feed.refresh(force: true) { completions += 1 }
        check(homeWait { self.network.waiting.count == 4 }, "phase 1")
        homeSettle()
        eq(network.requests.count, 4, "three calls, one load")
        network.hold = false
        network.release()
        check(homeWait { completions == 3 }, "every caller is told when it ends")
        idle(feed)
        eq(Set(network.paths).count, network.paths.count, "no request doubled")
    }

    func testAForcedRefreshThatJoinsARunningOneAsksEverything() {
        network.answer { $0.path == self.newShowsPath ? .some(self.thirtyNewShows) : nil }
        let feed = makeFeed()
        load(feed)
        eq(network.resets, 0, "a refresh that is not forced leaves the transport's memory of the hosts alone")
        // 31 minutes later the Home appears: only YTS's additions are asked, and YTS is slow.
        clock.now = HomeFixture.now.addingTimeInterval(31 * 60)
        network.forget()
        network.hold = true
        var appeared = false, pulled = false
        feed.refresh { appeared = true }
        check(homeWait { self.network.waiting.count == 2 }, "the two stale lists")
        homeSettle()
        eq(Set(network.waiting.map(\.host)), [.yts], "YTS's additions; the rest is fresh")
        // The user pulls to refresh meanwhile: the lists skipped as fresh are asked too.
        feed.refresh(force: true) { pulled = true }
        check(homeWait { self.network.waiting.count == 4 }, "the forced refresh makes the running one ask what it skipped")
        homeSettle()
        eq(Set(network.paths), phase1, "all of phase 1 now")
        eq(network.resets, 1, "and the transport forgets the hosts that failed: the user asked again")
        check(!appeared && !pulled, "one refresh, still running")
        network.hold = false
        network.release()
        check(homeWait { appeared && pulled }, "both callers are told when it ends")
        idle(feed)
        let paths = network.paths
        check(paths.filter { $0.hasPrefix("/schedule") }.count == 6 && paths.filter { $0.hasPrefix("/precompiled/") }.count == 3
              && paths.filter { $0.contains("/top/genre=") }.count == 4, "the later phases were forced too: every list of the plan")
        eq(Set(paths).count, paths.count, "none asked twice")
        eq(feed.snapshot.shelf(HomeShelfID.trendingMovies)?.updatedAt, clock.now, "the lists that were fresh were fetched again")
        feed.refresh(force: true)
        check(homeWait { self.network.resets == 2 }, "a forced refresh on its own resets the transport as well")
        check(homeWait { !feed.snapshot.isRefreshing && feed.isIdle }, "done")
    }

    // MARK: Cache

    func testFreshListsAreNotAskedAgain() {
        let feed = makeFeed()
        load(feed)
        network.forget()
        load(feed)
        // Everything is fresh except the new shows: nine in the fixture, fewer than the thirty of
        // a complete year's list, so it is asked again (with the year before).
        eq(Set(network.paths), ["/catalog/series/year/genre=2026.json", "/catalog/series/year/genre=2025.json"], "only the incomplete list is asked again")

        // 31 minutes later: YTS's additions (fresh 30 min) are asked; the rest is not.
        network.forget()
        clock.now = HomeFixture.now.addingTimeInterval(31 * 60)
        let later = load(feed)
        eq(Set(network.paths.filter { $0.hasPrefix("/api/v2/") }), [
            "/api/v2/list_movies.json?limit=50&order_by=desc&query_term=2026&sort_by=date_added&minimum_rating=6",
            "/api/v2/list_movies.json?limit=50&order_by=desc&quality=2160p&sort_by=date_added"], "after 31 min: the new movies and 4K")
        check(!network.paths.contains("/catalog/movie/top.json") && !network.paths.contains { $0.hasPrefix("/precompiled/") }, "not Cinemeta (4 h), not apibay (2 h)")
        eq(later.shelf(HomeShelfID.newMovies)?.updatedAt, clock.now, "the new movies' date moved")
        eq(later.shelf(HomeShelfID.trendingMovies)?.updatedAt, HomeFixture.now, "the trending movies' did not")

        // A forced refresh asks everything of the plan again.
        network.forget()
        load(feed, force: true)
        check(phase1.isSubset(of: Set(network.paths)) && network.paths.filter { $0.hasPrefix("/schedule") }.count == 6
              && network.paths.filter { $0.hasPrefix("/precompiled/") }.count == 3, "forced: every list")
        check(!network.paths.contains { $0.hasPrefix("/meta/movie/") || $0.contains("last-videos") }, "but a title already looked up is not looked up again")
    }

    func testPaintsFromDiskWithoutAnyRequest() {
        let first = makeFeed()
        let loaded = load(first)
        check(loaded.shelves.count >= 11, "a full page to cache")

        // A new launch: the page is whole before any request is made.
        network.forget()
        network.hold = true
        let second = makeFeed()
        let cached = second.cachedSnapshot()
        eq(network.requests.count, 0, "reading the cache asks nothing")
        check(cached.shelves == loaded.shelves, "the page of the last session, card for card")
        check(!cached.isRefreshing && !cached.isOffline, "as it was")

        var updates: [HomeSnapshot] = []
        second.onUpdate = { updates.append($0) }
        second.start()
        check(homeWait { !updates.isEmpty }, "start paints")
        check(updates[0].shelves == loaded.shelves, "the first update is the cached page")
        check(updates[0].shelves.allSatisfy { !$0.isStale || $0.id == HomeShelfID.newShows }, "fresh lists are not marked stale (the short list of new shows is)")
        network.hold = false
        network.release()
        check(homeWait { !second.snapshot.isRefreshing && updates.count >= 2 }, "then it refreshes what is not fresh")
        idle(second)
        check(!network.paths.contains("/catalog/movie/top.json"), "and only that")
    }

    func testEverythingDownShowsTheDiskSnapshot() {
        let loaded = load(makeFeed())
        // Five hours later, no network at all.
        clock.now = HomeFixture.now.addingTimeInterval(5 * 3600)
        network.down = Set(HomeRequest.Host.allCases)
        network.forget()
        let offline = makeFeed()
        let snapshot = load(offline)
        check(snapshot.isOffline, "the refresh reached nothing")
        check(!snapshot.isUnavailable, "but there is something to show")
        eq(snapshot.shelf(HomeShelfID.hero)?.titles, loaded.shelf(HomeShelfID.hero)?.titles, "the hero of the last session")
        eq(snapshot.shelf(HomeShelfID.trendingMovies)?.titles, loaded.shelf(HomeShelfID.trendingMovies)?.titles, "the trending movies too")
        eq(snapshot.shelf(HomeShelfID.trendingMovies)?.isStale, true, "marked stale")
        eq(snapshot.shelf(HomeShelfID.trendingMovies)?.updatedAt, HomeFixture.now, "with the date they were fetched")
        eq(snapshot.lastUpdated, HomeFixture.now, "the page's date is the last session's")
        check(snapshot.shelf(HomeShelfID.newMovies) != nil && snapshot.shelf(HomeShelfID.topShows) != nil, "lists usable 24 h are still shown after 5 h")
        check(network.requests.count >= 4, "it did try")

        // Two days later, still nothing: YTS's additions and apibay are too old to show, Cinemeta is not.
        clock.now = HomeFixture.now.addingTimeInterval(2 * 86_400)
        let old = load(makeFeed())
        check(old.isOffline && !old.isUnavailable, "offline, with a page")
        check(old.shelf(HomeShelfID.newMovies) == nil && old.shelf(HomeShelfID.topShows) == nil, "expired lists are gone")
        check(old.shelf(HomeShelfID.trendingMovies) != nil && old.shelf(HomeShelfID.moviesOfTheYear) != nil, "the weekly ones are there")

        // Back online: the flags clear.
        network.down = []
        let back = load(makeFeed())
        check(!back.isOffline && back.shelf(HomeShelfID.newMovies) != nil, "online again")
        eq(back.shelf(HomeShelfID.trendingMovies)?.isStale, false, "fresh again")
    }

    func testEverythingDownAndNothingCached() {
        network.down = Set(HomeRequest.Host.allCases)
        let feed = makeFeed()
        let snapshot = load(feed)
        check(snapshot.isUnavailable && snapshot.isOffline, "nothing answered and nothing cached: the error screen")
        eq(snapshot.shelves.count, 0, "no shelf")
        check(snapshot.lastUpdated == nil, "no date")
        // The library is still there.
        var hooks = HomeLocalHooks()
        hooks.watchlist = { [HomeItem(imdbId: "tt0903747", kind: .show, title: "Breaking Bad")] }
        feed.hooks = hooks
        let withLibrary = load(feed)
        eq(withLibrary.shelves.ids, [HomeShelfID.watchlist], "the watchlist needs no network")
        check(withLibrary.isUnavailable, "the catalog is still unavailable")
        network.down = []
        check(!load(feed).isUnavailable, "a retry that works clears it")
    }

    func testAnIncompleteAnswerDoesNotReplaceTheList() {
        let feed = makeFeed()
        let loaded = load(feed)
        eq(loaded.shelf(HomeShelfID.trendingMovies)?.items.count, 14, "20 trending movies, 6 in the hero")
        clock.now = HomeFixture.now.addingTimeInterval(5 * 3600)
        // movie/top answers five titles (a glitch), series/top an error page.
        let five = HomeFixture.entries("cm_movie_top.json", .cinemeta(.movie)).prefix(5).map { ["id": $0.item.imdbId, "name": $0.item.title, "poster": "https://x/p.jpg"] }
        let short = try! JSONSerialization.data(withJSONObject: ["metas": five])
        network.answer { request in
            if request.path == "/catalog/movie/top.json" { return .some(short) }
            if request.path == "/catalog/series/top.json" { return .some(Data("<html>502</html>".utf8)) }
            return nil
        }
        let after = load(feed)
        eq(after.shelf(HomeShelfID.trendingMovies)?.titles, loaded.shelf(HomeShelfID.trendingMovies)?.titles, "the fuller list stays")
        eq(after.shelf(HomeShelfID.trendingMovies)?.isStale, true, "stale: it will be asked again")
        eq(after.shelf(HomeShelfID.trendingShows)?.titles, loaded.shelf(HomeShelfID.trendingShows)?.titles, "an error page changes nothing either")
        check(!after.isOffline, "the other hosts answered")
        // On a first launch the same short answer is better than nothing.
        sandbox.discard()
        sandbox = HomeSandbox()
        let cold = load(makeFeed())
        eq(cold.shelf(HomeShelfID.trendingMovies)?.items.count, 5, "five titles are shown when nothing fuller is known")
        eq(cold.shelf(HomeShelfID.trendingMovies)?.isStale, true, "as an incomplete list")
    }

    func testJanuaryAsksTheYearBefore() {
        // The 2nd of January 2027: nothing of 2027 on YTS yet, an empty catalog of 2027's new shows.
        clock.now = CatalogDates.date(from: "2027-01-02T09:00:00Z")!
        network.answer { request in
            request.path == "/catalog/series/year/genre=2027.json" ? .some(Data(#"{"metas":[]}"#.utf8)) : nil
        }
        let snapshot = load(makeFeed())
        let paths = network.paths
        for sort in ["sort_by=date_added&minimum_rating=6", "sort_by=download_count", "sort_by=download_count&minimum_rating=7"] {
            check(paths.contains("/api/v2/list_movies.json?limit=50&order_by=desc&query_term=2027&\(sort)"), "2027 is asked: \(sort)")
            check(paths.contains("/api/v2/list_movies.json?limit=50&order_by=desc&query_term=2026&\(sort)"), "then 2026, because 2027 is short: \(sort)")
        }
        check(paths.contains("/catalog/series/year/genre=2027.json") && paths.contains("/catalog/series/year/genre=2026.json"), "the new shows of both years too")
        check(!paths.contains("/catalog/movie/imdbRating.json") && !paths.contains("/catalog/movie/top/skip=50.json"), "an empty year is not a host that is down: no stand-in is asked")
        eq(snapshot.shelf(HomeShelfID.moviesOfTheYear)?.titles.first, "Project Hail Mary", "the movies of the year are last year's while this one has none")
        check(snapshot.shelf(HomeShelfID.newMovies) != nil && snapshot.shelf(HomeShelfID.newShows) != nil, "new movies and new shows too")
        check(snapshot.heroItems.contains { $0.year == 2026 }, "and the hero features last year's titles")
        eq(snapshot.shelf(HomeShelfID.moviesOfTheYear)?.isStale, true, "the short lists are asked again at every refresh until the year fills up")
    }

    // MARK: Stand-ins

    func testCinemetaDown() {
        network.down = [.cinemeta]
        let snapshot = load(makeFeed())
        check(network.paths.contains("/api/v2/list_movies.json?limit=50&order_by=desc&query_term=2026&sort_by=like_count"), "the year's most liked movies are asked instead of movie/top")
        check(!snapshot.isOffline && !snapshot.isUnavailable, "three hosts out of four answer")
        eq(snapshot.heroItems.prefix(3).map(\.title), ["Project Hail Mary", "Spider-Man: Brand New Day", "Dexter: Resurrection"], "a hero from YTS and the schedules")
        check(snapshot.heroItems.allSatisfy { $0.logoURL?.host == "images.metahub.space" && $0.backdropURL?.host == "images.metahub.space" }, "with metahub's artwork by id")
        check(snapshot.shelf(HomeShelfID.trendingMovies) != nil && snapshot.shelf(HomeShelfID.trendingShows) != nil, "trending shelves from the stand-ins")
        eq(snapshot.shelf(HomeShelfID.newShows)?.titles, ["Honey", "12 12 12"], "new shows: this week's premieres")
        check(snapshot.shelf(HomeShelfID.newMovies) != nil && snapshot.shelf(HomeShelfID.uhd) != nil && snapshot.shelf(HomeShelfID.airedEpisodes) != nil, "YTS and TVMaze shelves are untouched")
        check(!snapshot.shelves.ids.contains { HomeShelfID.genre(of: $0) != nil }, "no genre shelf without Cinemeta")
        eq(snapshot.shelf(HomeShelfID.topShows)?.titles.first, "MobLand", "the ranking uses the schedules' cards (VisionQuest, 2nd, is Cinemeta's)")
        check(snapshot.shelf(HomeShelfID.topShows)?.titles.contains("Grey's Anatomy") == false, "the lookups failed: those titles are left out")
        check(snapshot.shelf(HomeShelfID.trendingMovies)?.isStale == false, "a stand-in that just answered is not stale")
    }

    func testYTSDown() {
        network.down = [.yts]
        // "Featured" is another list than "Popular" (19 titles in common out of 50 on the day of
        // the recordings): here, the second half of the popular movies.
        let all = (try! JSONSerialization.jsonObject(with: HomeFixture.data("cm_movie_top.json")) as! [String: Any])["metas"] as! [Any]
        let featured = try! JSONSerialization.data(withJSONObject: ["metas": Array(all.dropFirst(12))])
        network.answer { $0.path == "/catalog/movie/imdbRating.json" ? .some(featured) : nil }
        let snapshot = load(makeFeed())
        check(network.paths.contains("/catalog/movie/imdbRating.json"), "Stremio's Featured is asked for the new movies")
        check(network.paths.contains("/catalog/movie/top/skip=50.json"), "and the second page of the popular movies for the movies of the year")
        eq(Array(snapshot.shelves.ids.prefix(4)), [HomeShelfID.hero, HomeShelfID.trendingMovies, HomeShelfID.newMovies, HomeShelfID.uhd], "the movie shelves are all there")
        eq(snapshot.shelf(HomeShelfID.uhd)?.titles.first, "Resident Evil", "4K from apibay's UHD ranking, most seeded first")
        eq(snapshot.shelf(HomeShelfID.uhd)?.items.first?.badges, [.uhd, .dolbyVision, .hdr, .atmos], "with the releases' badges")
        check(snapshot.shelf(HomeShelfID.uhd)!.items.allSatisfy { $0.posterURL?.host == "images.metahub.space" }, "and Cinemeta's cards")
        check(!snapshot.isOffline, "online")
    }

    func testTVMazeDown() {
        network.down = [.tvmaze]
        let snapshot = load(makeFeed())
        eq(snapshot.shelf(HomeShelfID.airedEpisodes)?.titles.prefix(3).map { $0 }, ["Black Clover", "Nocturne", "MobLand"], "the latest episodes read off the trending shows")
        check(snapshot.shelf(HomeShelfID.airedEpisodes)!.items.allSatisfy { $0.episode?.stillURL?.host == "episodes.metahub.space" }, "with Cinemeta's stills")
        eq(network.paths.filter { $0.hasPrefix("/schedule") }.count, 6, "the schedules were asked")
        check(snapshot.shelf(HomeShelfID.topShows) != nil, "the ranking still has cards (Cinemeta's lists and lookups)")
    }

    func testApibayDown() {
        network.down = [.apibay]
        let snapshot = load(makeFeed())
        check(snapshot.shelf(HomeShelfID.topShows) == nil && snapshot.shelf(HomeShelfID.topMovies) == nil, "no ranking: the shelves are simply absent")
        eq(snapshot.shelf(HomeShelfID.uhd)?.titles.prefix(2).map { $0 }, ["Allen", "Avedon"], "4K in YTS's order")
        check(!network.paths.contains { $0.contains("last-videos") || $0.hasPrefix("/meta/") }, "nothing to look up")
        check(!snapshot.isOffline && snapshot.shelf(HomeShelfID.hero) != nil, "the rest of the page is whole")
    }

    func testStandInsStayWhileTheirHostStaysDown() {
        // YTS is down: new movies from Stremio's Featured, 4K from apibay's ranking (testYTSDown).
        network.down = [.yts]
        let all = (try! JSONSerialization.jsonObject(with: HomeFixture.data("cm_movie_top.json")) as! [String: Any])["metas"] as! [Any]
        let featured = try! JSONSerialization.data(withJSONObject: ["metas": Array(all.dropFirst(12))])
        network.answer { request in
            if request.path == "/catalog/movie/imdbRating.json" { return .some(featured) }
            return request.path == self.newShowsPath ? .some(self.thirtyNewShows) : nil
        }
        let feed = makeFeed()
        let first = load(feed)
        check(first.shelf(HomeShelfID.newMovies) != nil && first.shelf(HomeShelfID.uhd) != nil && first.shelf(HomeShelfID.moviesOfTheYear) != nil,
              "the stand-ins of the cold load")
        eq(feed.store.readDown().filter { $0.hasPrefix("yts-") }.sorted(), ["yts-4k", "yts-new-2026", "yts-top-2026", "yts-year-2026"],
           "the sources that gave nothing are remembered, on disk")

        // The Home appears again two minutes later: YTS's lists, never cached, are asked
        // again. Their stand-ins do not leave the page while they are, not for one update.
        clock.now = HomeFixture.now.addingTimeInterval(120)
        network.forget()
        let updates = watch(feed, start: { feed.refresh() }) {
            eq(Set(self.network.waiting.map(\.host)), [.yts], "YTS is tried again")
            check(feed.snapshot.isRefreshing, "refreshing")
            check(feed.snapshot.shelves == first.shelves, "and the page is the one of the first refresh meanwhile")
        }
        check(updates.count >= 2, "the refresh started and ended", "\(updates.count) updates")
        // (The lookups that follow a refresh may add cards: a shelf grows, it does not leave.)
        func keeps(_ before: HomeSnapshot) -> (HomeSnapshot) -> Bool {
            return { update in
                before.shelves.allSatisfy { shelf in Set(update.shelf(shelf.id)?.items.map(\.id) ?? []).isSuperset(of: shelf.items.map(\.id)) }
            }
        }
        check(updates.allSatisfy(keeps(first)), "no update of the second refresh drops a shelf, or a card of one", "\(updates.map { $0.shelves.ids })")

        // A new launch paints the same page from the disk, stand-ins included, and keeps it.
        let last = feed.snapshot
        let relaunched = makeFeed()
        check(relaunched.cachedSnapshot().shelves == last.shelves, "the cache alone is the page of the last session")
        let again = watch(relaunched, start: { relaunched.start() }) {
            check(relaunched.snapshot.shelves == last.shelves, "the first paint of the new launch has the stand-ins")
        }
        check(again.allSatisfy(keeps(last)), "and none of its updates drops them")

        // YTS is back: its own lists replace the stand-ins, and it is no longer "down".
        network.down = []
        let back = load(relaunched)
        eq(back.shelf(HomeShelfID.newMovies)?.items.count, 16, "the new movies are YTS's again")
        check(back.shelf(HomeShelfID.uhd)?.items != first.shelf(HomeShelfID.uhd)?.items, "4K too")
        check(!relaunched.store.readDown().contains { $0.hasPrefix("yts-") }, "nothing of YTS is remembered as down")
    }

    func testStandInsOfCinemetaStayWhileItStaysDown() {
        network.down = [.cinemeta]
        let feed = makeFeed()
        let first = load(feed)
        check(first.shelf(HomeShelfID.hero) != nil && first.shelf(HomeShelfID.trendingMovies) != nil
              && first.shelf(HomeShelfID.trendingShows) != nil && first.shelf(HomeShelfID.newShows) != nil, "hero and shelves from the stand-ins")
        clock.now = HomeFixture.now.addingTimeInterval(120)
        let updates = watch(feed, start: { feed.refresh() }) {
            eq(Set(self.network.waiting.map(\.host)), [.cinemeta], "Cinemeta is tried again")
            check(feed.snapshot.shelves == first.shelves, "the hero and the shelves made of its stand-ins stay meanwhile")
        }
        check(updates.allSatisfy { $0.shelves == first.shelves }, "no update drops the hero, a shelf, or changes the size of another",
              "\(updates.map { $0.shelves.map { "\($0.id):\($0.items.count)" } })")
        // A source never tried is still waited for: on a cold load where Cinemeta is slow, no
        // stand-in is shown for a moment and then swapped.
        sandbox.discard()
        sandbox = HomeSandbox()
        network.down = []
        network.forget()
        network.hold = true
        let cold = makeFeed(options: HomeFeed.Options(requestDeadline: .infinity, phaseGrace: 0.05))
        cold.start()
        check(homeWait { self.network.requests.count >= 4 + 9 + 3 }, "the later phases start without Cinemeta")
        network.release { $0.host != .cinemeta }
        check(homeWait { cold.snapshot.shelf(HomeShelfID.newMovies) != nil && cold.snapshot.shelf(HomeShelfID.airedEpisodes) != nil }, "YTS's and TVMaze's shelves are there")
        homeSettle()
        check(cold.snapshot.shelf(HomeShelfID.hero) == nil && cold.snapshot.shelf(HomeShelfID.trendingShows) == nil && cold.snapshot.shelf(HomeShelfID.newShows) == nil,
              "but no hero and no shelf made of a stand-in while Cinemeta's first answer is on its way", "\(cold.snapshot.shelves.ids)")
        network.hold = false
        network.release()
        check(homeWait { !cold.snapshot.isRefreshing && cold.snapshot.shelf(HomeShelfID.hero) != nil }, "then Cinemeta's own")
        idle(cold)
    }

    // MARK: Offline

    func testOneHostDownIsNotOffline() {
        // apibay is blocked (the ISP): its three lists are never cached, so every refresh asks them.
        network.down = [.apibay]
        network.answer { $0.path == self.newShowsPath ? .some(self.thirtyNewShows) : nil }
        let feed = makeFeed()
        let first = load(feed)
        check(!first.isOffline, "three hosts out of four answer the cold load")

        // Back on the Home two minutes later: everything else is fresh, only apibay is asked.
        clock.now = HomeFixture.now.addingTimeInterval(120)
        network.forget()
        let again = load(feed)
        check(!network.requests.isEmpty && network.requests.allSatisfy { $0.host == .apibay }, "only the host that is down is asked", "\(network.paths)")
        check(!again.isOffline && !again.isUnavailable, "a host that was already down failing again is not the device offline")
        check(again.shelves.count >= 10 && again.shelves.ids == first.shelves.ids, "and the page is whole", "\(again.shelves.ids)")

        // The same after a relaunch: what was down is remembered with the cache.
        network.forget()
        let relaunched = makeFeed()
        let launched = load(relaunched)
        check(!network.requests.isEmpty && network.requests.allSatisfy { $0.host == .apibay }, "a new launch asks apibay alone too")
        check(!launched.isOffline && !launched.isUnavailable, "and is not offline either")

        // The device does go offline: 45 minutes in, YTS's additions are asked too and fail.
        network.down = Set(HomeRequest.Host.allCases)
        clock.now = HomeFixture.now.addingTimeInterval(45 * 60)
        let offline = load(relaunched)
        check(offline.isOffline && !offline.isUnavailable, "a host that answered and no longer does, nothing else reached: offline")
        clock.now = HomeFixture.now.addingTimeInterval(50 * 60)
        check(load(relaunched).isOffline, "still offline at the next refresh, which learns nothing new")
        // Back, apibay still blocked.
        network.down = [.apibay]
        check(!load(relaunched).isOffline, "one answer: online")
    }

    func testAnAnswerThatIsNotKeptIsStillAHostReached() {
        network.answer { $0.path == self.newShowsPath ? .some(self.thirtyNewShows) : nil }
        let feed = makeFeed()
        let loaded = load(feed)
        // 31 minutes later only YTS's additions are asked, and YTS answers three movies (a
        // glitch): shorter than the lists kept, so they stay — but YTS did answer.
        clock.now = HomeFixture.now.addingTimeInterval(31 * 60)
        var json = try! JSONSerialization.jsonObject(with: HomeFixture.data("yts_4k.json")) as! [String: Any]
        var body = json["data"] as! [String: Any]
        body["movies"] = Array((body["movies"] as! [Any]).prefix(3))
        json["data"] = body
        let short = try! JSONSerialization.data(withJSONObject: json)
        network.answer { $0.host == .yts ? .some(short) : nil }
        network.forget()
        let after = load(feed)
        eq(Set(network.requests.map(\.host)), [.yts], "only YTS is asked")
        eq(after.shelf(HomeShelfID.uhd)?.titles, loaded.shelf(HomeShelfID.uhd)?.titles, "the fuller lists stay")
        check(!after.isOffline, "an answer the cache refuses is not a host that could not be reached")
    }

    // MARK: The library

    func testLocalShelvesAndTheFollowedShows() {
        var watchlist = [HomeItem(imdbId: "tt0903747", kind: .show, title: "Breaking Bad")]
        var watched: Set<String> = ["tt31510819:2:9"]
        var asked: [String] = []
        var hooks = HomeLocalHooks()
        hooks.continueWatching = { [HomeItem(imdbId: "tt12042730", kind: .movie, title: "Project Hail Mary", progress: 0.4, remainingMinutes: 55)] }
        hooks.watchlist = { watchlist }
        hooks.followedShowIds = { ["tt31510819", "tt26598805", "tt33043892", "tt5875444", "tt0903747"] }
        hooks.isWatched = { imdbId, season, episode in
            check(Thread.isMainThread, "the hooks are called on the main queue")
            asked.append("\(imdbId):\(season):\(episode)")
            return watched.contains("\(imdbId):\(season):\(episode)")
        }
        let feed = makeFeed(hooks: hooks)
        let snapshot = load(feed)
        eq(Array(snapshot.shelves.ids.prefix(4)), [HomeShelfID.hero, HomeShelfID.continueWatching, HomeShelfID.yourShows, HomeShelfID.trendingMovies], "the library's shelves under the hero")
        eq(snapshot.shelf(HomeShelfID.continueWatching)?.items.first?.progress, 0.4, "the resume card")
        eq(snapshot.shelves.ids.contains(HomeShelfID.watchlist), true, "the watchlist")
        check(network.paths.contains("/catalog/series/calendar-videos/calendarVideosIds=tt0903747,tt26598805,tt31510819,tt33043892,tt5875444.json"), "the followed shows are asked in one request")
        // MobLand S2E9 is watched: its card is the next episode; Nocturne's and Dexter's latest are not.
        eq(snapshot.shelf(HomeShelfID.yourShows)?.items.map(\.id), ["tt26598805:1:4", "tt33043892:2:2", "tt31510819:2:10"], "new episodes not watched, then the upcoming one")
        eq(Set(asked), ["tt31510819:2:9", "tt26598805:1:4", "tt33043892:2:2"], "the library is only asked about the episodes that can be new")

        // Back from watching Nocturne, a title added to the watchlist: no request.
        network.forget()
        watched.insert("tt26598805:1:4")
        watchlist.append(HomeItem(imdbId: "tt22084616", kind: .movie, title: "Spider-Man: Brand New Day"))
        feed.refreshLocal()
        check(homeWait { feed.snapshot.shelf(HomeShelfID.watchlist)?.items.count == 2 }, "the watchlist follows")
        eq(feed.snapshot.shelf(HomeShelfID.yourShows)?.items.map(\.id), ["tt33043892:2:2", "tt31510819:2:10", "tt26598805:1:5"], "Nocturne's card is now its next episode")
        eq(network.requests.count, 0, "recomputing the local shelves asks nothing")
        check(!feed.snapshot.isRefreshing, "and is not a refresh")

        // Another show followed: the calendar is asked at once (it is not six hours old), and the
        // shelf keeps the old cards meanwhile.
        hooks.followedShowIds = { ["tt31510819", "tt26598805", "tt33043892", "tt5875444", "tt0903747", "tt16358384"] }
        feed.hooks = hooks
        network.hold = true
        feed.refresh()
        check(homeWait { self.network.waiting.contains { $0.path.contains("calendar-videos") } }, "a new set of shows: a new calendar request")
        check(network.waiting.first { $0.path.contains("calendar-videos") }!.path.contains("tt16358384"), "with the new show")
        eq(feed.snapshot.shelf(HomeShelfID.yourShows)?.items.count, 3, "the shelf does not blink while it loads")
        network.hold = false
        network.release()
        check(homeWait { !feed.snapshot.isRefreshing }, "done")
        idle(feed)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path)) ?? []
        eq(files.filter { $0.hasPrefix("cm-calendar-") }.count, 1, "the calendar of the old set is deleted")
    }

    func testAShowFollowedMeanwhileIsAskedAtOnce() {
        var followed = ["tt31510819", "tt26598805", "tt33043892", "tt5875444", "tt0903747"]
        var hooks = HomeLocalHooks()
        hooks.followedShowIds = { followed }
        network.answer { $0.path == self.newShowsPath ? .some(self.thirtyNewShows) : nil }
        let feed = makeFeed(hooks: hooks)
        feed.refreshLocal()
        homeSettle()
        eq(network.requests.count, 0, "before the first refresh, the local shelves alone: nothing is asked")
        let loaded = load(feed)
        eq(loaded.shelf(HomeShelfID.yourShows)?.items.count, 3, "three shows have news")

        // The Home stays on screen and a sixth show is followed (the library changed): the
        // calendar of the new set is asked at once, and the cards do not leave meanwhile.
        followed.append("tt16358384")
        network.forget()
        let updates = watch(feed, start: { feed.refreshLocal() }) {
            eq(self.network.waiting.map(\.path), ["/catalog/series/calendar-videos/calendarVideosIds=tt0903747,tt16358384,tt26598805,tt31510819,tt33043892,tt5875444.json"],
               "the calendar of the six shows, and nothing else (the rest is fresh)")
            eq(feed.snapshot.shelf(HomeShelfID.yourShows)?.items.map(\.id), loaded.shelf(HomeShelfID.yourShows)?.items.map(\.id), "the cards stay while it loads")
        }
        check(updates.allSatisfy { $0.shelf(HomeShelfID.yourShows)?.items.count == 3 }, "the shelf never blinks", "\(updates.map { $0.shelf(HomeShelfID.yourShows)?.items.count ?? 0 })")
        eq(network.requests.count, 1, "one request")
        // Nothing changed since: recomputing the local shelves asks nothing again.
        network.forget()
        feed.refreshLocal()
        homeSettle()
        eq(network.requests.count, 0, "the same set of shows: no request")

        // A show unfollowed while the Home is on screen: its card goes at once, the others stay.
        followed.removeAll { $0 == "tt26598805" }
        network.hold = true
        feed.refreshLocal()
        check(homeWait { !self.network.waiting.isEmpty }, "another set again: its calendar is asked")
        homeSettle()
        eq(feed.snapshot.shelf(HomeShelfID.yourShows)?.items.map(\.imdbId), ["tt31510819", "tt33043892"], "Nocturne's card left with the show")
        network.hold = false
        network.release()
        check(homeWait { !feed.snapshot.isRefreshing }, "done")
        idle(feed)
    }

    func testTheGenresOfATitleJustAddedAreAskedAtOnce() {
        var watchlist: [HomeItem] = []
        var hooks = HomeLocalHooks()
        hooks.watchlist = { watchlist }
        network.answer { request in
            if let titles = self.genreTitles(request) { return .some(titles) }
            return request.path == self.newShowsPath ? .some(self.thirtyNewShows) : nil
        }
        let feed = makeFeed(hooks: hooks)
        func genres(_ snapshot: HomeSnapshot) -> [String] { snapshot.shelves.ids.filter { HomeShelfID.genre(of: $0) != nil } }
        let defaults = [HomeShelfID.genre(.movie, "Action"), HomeShelfID.genre(.show, "Drama"), HomeShelfID.genre(.movie, "Comedy"), HomeShelfID.genre(.show, "Sci-Fi")]
        eq(genres(load(feed)), defaults, "the default genre shelves")

        // A horror thriller is added to the watchlist while the Home is on screen.
        watchlist = [HomeItem(imdbId: "tt7526136", kind: .movie, title: "Heart of the Beast", genres: ["Horror", "Thriller"])]
        network.forget()
        let updates = watch(feed, start: { feed.refreshLocal() }) {
            eq(Set(self.network.waiting.map(\.path)), ["/catalog/movie/top/genre=Horror.json", "/catalog/movie/top/genre=Thriller.json"],
               "the two genres nobody asked yet, at once")
            eq(genres(feed.snapshot), defaults, "the shelves on screen stay while they load")
        }
        check(updates.allSatisfy { genres($0).count == 4 }, "four genre shelves throughout", "\(updates.map(genres))")
        eq(genres(feed.snapshot), [HomeShelfID.genre(.movie, "Horror"), HomeShelfID.genre(.movie, "Thriller"), HomeShelfID.genre(.movie, "Action"), HomeShelfID.genre(.show, "Drama")],
           "then the user's genres lead")
        eq(network.requests.count, 2, "two requests")

        // The title is removed while a refresh is running: the plan it changed is asked when
        // that refresh ends (here nothing: the default lists are still in memory).
        watchlist = []
        network.forget()
        feed.refreshLocal()
        check(homeWait { genres(feed.snapshot) == defaults }, "back to the defaults, from the lists kept")
        idle(feed)
        eq(network.requests.count, 0, "without a request")
    }

    func testFollowedShowsOptOut() {
        HomeSettings(defaults: sandbox.defaults).sendsFollowedShowsToCinemeta = false
        var hooks = HomeLocalHooks()
        hooks.followedShowIds = { ["tt31510819", "tt26598805"] }
        hooks.newEpisodes = { [HomeItem(imdbId: "tt26598805", kind: .show, title: "Nocturne", episode: HomeEpisode(season: 1, number: 4))] }
        let snapshot = load(makeFeed(hooks: hooks))
        check(!network.paths.contains { $0.contains("calendar-videos") || $0.contains("tt31510819") }, "opted out: the list of followed shows never leaves the device")
        eq(snapshot.shelf(HomeShelfID.yourShows)?.items.map(\.id), ["tt26598805:1:4"], "the shelf shows what the library knows by itself")
    }

    func testSettingsAreReadAtEveryBuild() {
        let feed = makeFeed()
        let snapshot = load(feed)
        check(snapshot.shelf(HomeShelfID.uhd) != nil, "4K is shown")
        eq(snapshot.shelf(HomeShelfID.newMovies)?.items.count, 16, "English and French (the device is English: no third language)")
        let settings = HomeSettings(defaults: sandbox.defaults)
        settings.setShelf(HomeShelfID.uhd, hidden: true)
        settings.contentLanguages = ["es"]
        network.forget()
        feed.refreshLocal()
        check(homeWait { feed.snapshot.shelf(HomeShelfID.uhd) == nil }, "a hidden shelf goes at the next build")
        eq(feed.snapshot.shelf(HomeShelfID.newMovies)?.titles, ["El deshielo", "Papi Ricky"], "the languages apply to the lists already loaded")
        eq(network.requests.count, 0, "without a request")
    }

    func testWhatTheFirst530BuildStoredStillApplies() {
        // Settings › Home of 5.3.0's first build, written by its own code (HomeSettings): the
        // movies' ranking hidden, under the id it had then.
        HomeSettings(defaults: sandbox.defaults).setShelf("top48hMovies", hidden: true)
        eq(sandbox.defaults.array(forKey: "popcornkit.home.hiddenShelves") as? [String], ["top48hMovies"], "as that build stored it")
        // Its disk: the movies' and the shows' Top 48 h under the keys of then, fresh.
        let store = HomeStore(directory: sandbox.directory, now: { HomeFixture.now })
        store.write(HomeSourceList(key: "tpb-48h-207", savedAt: HomeFixture.now, complete: true,
                                   entries: HomeFixture.entries("tpb_48h_207.json", .apibay(.movie))))
        store.write(HomeSourceList(key: "tpb-48h-208", savedAt: HomeFixture.now, complete: true,
                                   entries: HomeFixture.entries("tpb_48h_208.json", .apibay(.show))))
        store.write(down: ["tpb-48h-207", "tpb-48h-208"])
        let former = sandbox.directory.appendingPathComponent("tpb-48h-207.json")
        let formerShows = sandbox.directory.appendingPathComponent("tpb-48h-208.json")
        check(FileManager.default.fileExists(atPath: former.path) && FileManager.default.fileExists(atPath: formerShows.path), "the former lists are on disk")

        let feed = makeFeed()
        let page = load(feed)
        check(page.shelf(HomeShelfID.topMovies) == nil, "hidden then, hidden now")
        check(page.shelf(HomeShelfID.topShows) != nil, "the shows' ranking is shown")
        eq(page.shelf(HomeShelfID.topShows)?.titles.first, "MobLand", "the shows' Top 100, not their Top 48 h (Dexter: Resurrection)")
        check(!network.paths.contains { $0.hasSuffix("data_top100_48h_207.json") }, "the former list is never asked")
        check(!network.paths.contains { $0.hasSuffix("data_top100_48h_208.json") }, "nor the shows' former list")
        check(network.paths.contains("/precompiled/data_top100_207.json"), "the Top 100 is")
        check(network.paths.contains("/precompiled/data_top100_208.json"), "the shows' Top 100 too")
        check(!FileManager.default.fileExists(atPath: former.path), "the first refresh deleted the former list's file")
        check(!FileManager.default.fileExists(atPath: formerShows.path), "and the shows' one")
        let down = HomeStore(directory: sandbox.directory, now: { HomeFixture.now }).readDown()
        check(!down.contains("tpb-48h-207") && !down.contains("tpb-48h-208"), "and forgot they were down")
        // Shown again: the Top 100 under its new title, in its place after the shows' ranking.
        HomeSettings(defaults: sandbox.defaults).setShelf(HomeShelfID.topMovies, hidden: false)
        feed.refreshLocal()
        check(homeWait { feed.snapshot.shelf(HomeShelfID.topMovies) != nil }, "shown again at the next build")
        eq(feed.snapshot.shelf(HomeShelfID.topMovies)?.titles.first, "The Odyssey", "the Top 100's number one")
        let ids = feed.snapshot.shelves.ids
        eq(ids.firstIndex(of: HomeShelfID.topMovies), ids.firstIndex(of: HomeShelfID.topShows).map { $0 + 1 }, "right after the shows' ranking, as before")
    }

    func testRankingLookupsAreCappedAtEveryRefresh() {
        // Forty movies no list knows lead the Top 100: eight lookups per refresh, never past the
        // shelf's twenty, and none before the page is whole.
        let unknown = (1...40).map { ["name": "Unknown Film \($0) 2026 1080p WEB-DL x264", "category": 207, "seeders": 5000 - $0,
                                      "added": 1_794_600_000, "imdb": String(format: "tt95%05d", $0)] as [String: Any] }
        let body = try! JSONSerialization.data(withJSONObject: unknown)
        network.answer { $0.path == "/precompiled/data_top100_207.json" ? .some(body) : nil }
        let feed = makeFeed()
        var counts: [Int] = []
        for _ in 0..<4 {
            network.forget()
            load(feed, force: true)
            counts.append(network.paths.filter { $0.hasPrefix("/meta/movie/") }.count)
        }
        eq(counts, [8, 8, 4, 0], "eight per refresh, twenty in all, then none")
        check(feed.snapshot.shelf(HomeShelfID.topMovies) == nil, "titles Cinemeta does not know make no ranking")
    }

    func testARankingIsCompleteWithTwentyTitlesNotTwentyEntries() {
        // The movies' Top 100 answers fifteen titled releases and six readable releases without an
        // IMDb id that no list knows: twenty-one entries, fifteen titles. Short: kept, but stale,
        // so it is asked again (the pending entries may name no title).
        var releases = (1...15).map { ["name": "Known Film \($0) 2026 1080p WEB-DL x264", "category": 207, "seeders": 5000 - $0,
                                       "added": 1_794_600_000, "imdb": String(format: "tt96%05d", $0)] as [String: Any] }
        releases += ["A", "B", "C", "D", "E", "F"].map { ["name": "Unknown Title \($0) 2026 1080p WEB", "category": 207, "seeders": 4000,
                                                          "added": 1_794_600_000, "imdb": ""] as [String: Any] }
        let body = try! JSONSerialization.data(withJSONObject: releases)
        eq(HomeParse.entries(body, parser: .apibay(.movie), now: HomeFixture.now)?.count, 21, "fifteen titles and six pending entries")
        network.answer { $0.path == "/precompiled/data_top100_207.json" ? .some(body) : nil }
        let feed = makeFeed()
        load(feed)
        let list = feed.store.readAll()[HomeSource.topMovies.key]
        check(list != nil, "kept: better than nothing")
        eq(list?.complete, false, "incomplete: fifteen titles, under the minimum of twenty")
        // With five more titles it is whole.
        releases += (16...20).map { ["name": "Known Film \($0) 2026 1080p WEB-DL x264", "category": 207, "seeders": 3000 - $0,
                                     "added": 1_794_600_000, "imdb": String(format: "tt96%05d", $0)] as [String: Any] }
        let whole = try! JSONSerialization.data(withJSONObject: releases)
        network.answer { $0.path == "/precompiled/data_top100_207.json" ? .some(whole) : nil }
        load(feed, force: true)
        eq(feed.store.readAll()[HomeSource.topMovies.key]?.complete, true, "twenty titles: complete")
    }

    func testTheShowsTop100IsCompleteWithTenShows() {
        // Its hundred releases are episodes and season packs of few shows (26 on 2026-11-16): ten
        // titles make a complete answer, not twenty as for the movies.
        func answer(_ shows: Int) -> Data {
            let releases = (1...shows).map { ["name": "Known Show \($0) S01E0\($0 % 9 + 1) 1080p WEB H264", "category": 208, "seeders": 5000 - $0,
                                             "added": 1_794_600_000, "imdb": String(format: "tt97%05d", $0)] as [String: Any] }
            return try! JSONSerialization.data(withJSONObject: releases)
        }
        let feed = makeFeed()
        func refresh(_ shows: Int) -> HomeSourceList? {
            network.answer { $0.path == "/precompiled/data_top100_208.json" ? .some(answer(shows)) : nil }
            load(feed, force: true)
            return feed.store.readAll()[HomeSource.topShows.key]
        }
        // Five shows and nothing kept: kept, better than nothing, but incomplete (asked again).
        eq(refresh(5)?.complete, false, "five shows: under the minimum")
        // An honest day of twelve shows: complete.
        let twelve = refresh(12)
        eq(twelve?.entries.count, 12, "twelve shows kept")
        eq(twelve?.complete, true, "twelve shows: complete")
        // Five again: refused, the twelve stay.
        let after = refresh(5)
        eq(after?.entries.count, 12, "a shorter answer does not replace them")
        eq(after?.complete, true, "still complete")
        eq(feed.store.readAll()[HomeSource.topMovies.key]?.complete, true, "the movies keep their minimum of twenty (the recorded list: 26 titles)")
        eq(HomeSource.topMovies.minimum, 20, "twenty")
    }

    func testOptionsSizeThePage() {
        var options = HomeFeed.Options(requestDeadline: .infinity, phaseGrace: .infinity)
        options.heroLimit = 4
        options.shelfLimit = 6
        options.rankedLimit = 3
        options.genreShelves = 0
        let snapshot = load(makeFeed(options: options))
        eq(snapshot.heroItems.count, 4, "the hero's size")
        check(snapshot.rows.filter { $0.style != .ranked }.allSatisfy { $0.items.count <= 6 }, "a shelf's size")
        eq(snapshot.shelf(HomeShelfID.topShows)?.items.count, 3, "a ranking's size (and it may then be shorter than five)")
        check(!snapshot.shelves.ids.contains { HomeShelfID.genre(of: $0) != nil }, "no genre shelf")
        check(!network.paths.contains { $0.contains("/top/genre=") }, "and no genre request")
    }

    func testStartPaintsThenRefreshesAndCanBeCalledAgain() {
        let feed = makeFeed()
        var finished = 0
        feed.start { finished += 1 }
        check(homeWait { finished == 1 }, "start refreshes")
        idle(feed)
        let count = network.requests.count
        feed.start { finished += 1 }
        check(homeWait { finished == 2 }, "a second start is a refresh")
        idle(feed)
        eq(network.requests.count - count, 2, "of what is not fresh (the short list of new shows and its year before)")
    }

    // MARK: Delivery

    /// Lists that answer while the main queue is busy are one update, the page they leave
    /// together; the updates of a whole load are never closer than `updateSpacing`; and the
    /// refresh's completion runs after its last update.
    func testUpdatesThatComeTogetherAreDeliveredAsOne() {
        network.hold = true
        let feed = makeFeed()
        var updates: [(at: TimeInterval, snapshot: HomeSnapshot)] = []
        feed.onUpdate = { updates.append((ProcessInfo.processInfo.systemUptime, $0)) }
        var finished = false
        var lastAtCompletion: HomeSnapshot?
        var updatesAtCompletion = 0
        feed.start {
            finished = true
            lastAtCompletion = feed.snapshot
            updatesAtCompletion = updates.count
        }
        check(homeWait { self.network.waiting.count == 4 }, "phase 1 is asked")
        homeSettle(0.1)
        let before = updates.count
        check(before >= 1 && updates.last?.snapshot.shelves.isEmpty == true, "the refresh started: an empty page so far")

        // The four answers, parsed and built while the main queue does not run: four rebuilds.
        network.release()
        // The answers reach the hub's queue at once (`release` calls back on this thread): a
        // look at the hub's cache, on that queue, returns once they are all built.
        _ = feed.cachedSnapshot()
        eq(updates.count, before, "nothing is delivered while the main queue is busy")
        homeSettle(0.02)
        eq(updates.count, before + 1, "the four rebuilds are one update")
        eq(updates.last?.snapshot.shelves.ids, [HomeShelfID.hero, HomeShelfID.trendingMovies, HomeShelfID.newMovies, HomeShelfID.uhd,
                                                HomeShelfID.airedEpisodes, HomeShelfID.trendingShows],
           "the page all four answers make, not one of the pages in between")

        // The rest of the load: as the answers come, at most one update per spacing.
        network.hold = false
        network.release()
        check(homeWait { finished }, "the refresh ends")
        let spacing = HomeFeed.Options().updateSpacing
        check(spacing > 1.0 / 60 && spacing < 0.1, "two frames apart at 60 Hz, unnoticeable", "\(spacing) s")
        let gaps = zip(updates, updates.dropFirst()).map { $1.at - $0.at }
        check(gaps.allSatisfy { $0 >= spacing * 0.95 }, "no two updates within the spacing", "\(gaps.map { String(format: "%.3f", $0) })")
        eq(lastAtCompletion, updates.prefix(updatesAtCompletion).last?.snapshot, "the completion runs once the refresh's last page is delivered")
        check(lastAtCompletion?.isRefreshing == false, "a page that is not refreshing any more")
        check(lastAtCompletion?.shelf(HomeShelfID.topShows)?.titles.contains("Grey's Anatomy") == false,
              "the page the refresh left, not one its lookups made since")
        idle(feed)
        check(zip(updates, updates.dropFirst()).allSatisfy { $0.snapshot != $1.snapshot }, "never twice the same snapshot")
        check(!feed.snapshot.isRefreshing && feed.snapshot == updates.last?.snapshot, "the last page made is the last delivered")
    }

    /// With no spacing, an update follows each rebuild as soon as the main queue runs.
    func testNoSpacing() {
        var options = HomeFeed.Options(requestDeadline: .infinity, phaseGrace: .infinity)
        options.updateSpacing = 0
        let feed = makeFeed(options: options)
        var updates: [HomeSnapshot] = []
        feed.onUpdate = { updates.append($0) }
        let snapshot = load(feed)
        check(updates.count >= 8, "the page was updated as the answers came", "\(updates.count) updates")
        eq(updates.last, snapshot, "up to the last page")
    }

    // MARK: First frame from the disk

    /// `HomeState.paintFromDisk`: the page of the last session, the user's shelves included, at
    /// once and without a request; nothing on a first launch. (A synchronous test on the main
    /// thread: it waits by running the run loop.)
    func testPaintFromDisk() {
        var hooks = HomeLocalHooks()
        let resume = HomeItem(imdbId: "tt12042730", kind: .movie, title: "Project Hail Mary", progress: 0.4, remainingMinutes: 55)
        hooks.continueWatching = { [resume] }

        MainActor.assumeIsolated {
            // A first launch: nothing cached, nothing painted.
            let empty = HomeState(feed: makeFeed(hooks: hooks))
            check(!empty.paintFromDisk(), "nothing cached: no page")
            check(!empty.hasLoaded && empty.shelves.isEmpty && empty.heroItems.isEmpty, "the placeholders stay (not the resume cards alone)")
            eq(network.requests.count, 0, "and nothing asked")
        }

        // A session that loaded the page.
        let loaded = load(makeFeed(hooks: hooks))
        check(loaded.shelves.count >= 11, "a full page to cache")

        // The next launch.
        network.forget()
        network.hold = true
        let feed = makeFeed(hooks: hooks)
        let state = MainActor.assumeIsolated { HomeState(feed: feed) }
        MainActor.assumeIsolated {
            check(state.paintFromDisk(), "a page is painted")
            check(state.hasLoaded, "loaded: the screen shows it in the same frame")
            eq(state.shelves, loaded.rows, "the rows of the last session, card for card, with the resume cards")
            eq(state.heroItems, loaded.heroItems, "and its carousel")
            eq(state.shelves.first?.id, HomeShelfID.continueWatching, "the user's shelf in its place: nothing is inserted above the page later")
            check(!state.isRefreshing && !state.isOffline, "as it was")
            eq(network.requests.count, 0, "without a request")
            check(state.paintFromDisk(), "a second call keeps the page")
            // Then the hub starts as usual.
            state.start()
        }
        check(homeWait { MainActor.assumeIsolated { state.isRefreshing } }, "start refreshes")
        MainActor.assumeIsolated { eq(state.shelves, loaded.rows, "the same page while it refreshes") }
        network.hold = false
        network.release()
        check(homeWait { MainActor.assumeIsolated { !state.isRefreshing } }, "the refresh ends")
        idle(feed)
    }

    // MARK: Streaming services

    /// The Apple TV's « Services » row in a feed of the tests (they run on macOS, whose
    /// Home has none).
    private var servicesOptions: HomeFeed.Options {
        var options = HomeFeed.Options(requestDeadline: .infinity, phaseGrace: .infinity)
        options.servicesRow = true
        return options
    }

    /// A TMDB key, the country, and the service the Home shows (nil: the usual page).
    private func streaming(filter: Int?, services: [StreamingService]? = nil, region: String = "FR") {
        let settings = HomeSettings(defaults: sandbox.defaults)
        settings.tmdbAPIKey = "0123456789abcdef0123456789abcdef"
        settings.streamingRegion = region
        if let services { settings.streamingServices = services }
        settings.homeServiceFilter = filter
    }

    /// TMDB's discover pages as `TMDBStreamingClient` hands them to the hub (an IMDb id in
    /// every result): twelve titles of their own per service, kind and order.
    private func tmdbPage(_ request: HomeRequest) -> Data?? {
        guard request.host == .tmdb else { return nil }
        let path = request.path
        let kind: HomeItem.Kind = path.hasPrefix("/discover/tv") ? .show : .movie
        let sort = path.contains("sort_by=popularity") ? 1 : path.contains("sort_by=vote_average") ? 3 : 2
        let service = path.components(separatedBy: "with_watch_providers=").last.flatMap { Int($0.prefix { $0.isNumber }) } ?? 0
        let ids = (1...12).map { String(format: "tt9%03d%d%d%02d", service % 1000, kind == .movie ? 1 : 2, sort, $0) }
        return .some(HomeStreamingTests.discover(kind: kind, ids: ids))
    }

    private var tmdbPaths: [String] { network.requests.filter { $0.host == .tmdb }.map(\.path) }

    private func storedKeys() -> Set<String> {
        return Set(HomeStore(directory: sandbox.directory, now: { [clock] in clock!.now }).readAll().keys)
    }

    func testAPageFilteredOnAServiceAsksItsSixLists() {
        streaming(filter: 8)
        network.answer(tmdbPage)
        let snapshot = load(makeFeed(options: servicesOptions))
        eq(tmdbPaths.count, 6, "the service's six lists")
        check(tmdbPaths.allSatisfy { $0.contains("watch_region=FR&with_watch_providers=8") }, "of Netflix, in France")
        let netflix = HomeShelfID.streamingShelves.map { HomeShelfID.streaming(8, $0.kind, $0.sort) }
        eq(snapshot.shelves.ids, [HomeShelfID.hero, HomeShelfID.services] + netflix, "the hero, the row, the service's shelves")
        eq(snapshot.shelf(HomeShelfID.services)?.items.first?.id, HomeServiceCard.allId, "« All » first")
        check(snapshot.heroItems.allSatisfy { $0.imdbId.hasPrefix("tt9008") }, "a hero of the service's titles")
        check(!snapshot.isUnavailable && !snapshot.isOffline, "a page")

        // The « Services » row hidden: the usual page, and no list of the service.
        HomeSettings(defaults: sandbox.defaults).setShelf(HomeShelfID.services, hidden: true)
        network.forget()
        clock.now = HomeFixture.now.addingTimeInterval(13 * 3600)
        let usual = load(makeFeed(options: servicesOptions))
        eq(tmdbPaths.count, 0, "nothing asked of TMDB")
        check(usual.shelf(HomeShelfID.trendingMovies) != nil && !usual.shelves.contains { HomeShelfID.streaming(of: $0.id) != nil },
              "the usual page")

        // The Top Shelf's light refresh never asks them, filtered or not.
        HomeSettings(defaults: sandbox.defaults).setShelf(HomeShelfID.services, hidden: false)
        network.forget()
        clock.now = HomeFixture.now.addingTimeInterval(26 * 3600)
        var light = servicesOptions
        light.light = true
        load(makeFeed(options: light))
        check(network.requests.count > 0 && tmdbPaths.isEmpty, "the light refresh asks its lists, none of TMDB's")
    }

    func testOfflineWithAKeyAndNothingCachedIsUnavailable() {
        streaming(filter: nil)
        network.down = Set(HomeRequest.Host.allCases)
        let usual = load(makeFeed(options: servicesOptions))
        check(usual.isUnavailable && usual.isOffline, "the usual page: the error and its Retry (the « Services » row is not a list)")
        streaming(filter: 8)
        let filtered = load(makeFeed(options: servicesOptions))
        check(filtered.isUnavailable && filtered.isOffline, "a page filtered on a service too")
        MainActor.assumeIsolated {
            check(!HomeState(feed: makeFeed(options: servicesOptions)).paintFromDisk(),
                  "a launch with nothing cached paints no page made of the row alone")
        }
    }

    func testAFilteredPageWhoseListsFailedSaysSo() {
        streaming(filter: 8)
        network.down = [.tmdb]
        let failed = load(makeFeed(options: servicesOptions))
        check(failed.isUnavailable, "no list of the service: the error and its Retry")
        check(!failed.isOffline, "online: the other hosts answered")
        eq(failed.shelves.ids, [HomeShelfID.services], "the row stays: « All » is there")
        streaming(filter: nil)
        let feed = makeFeed(options: servicesOptions)
        check(!load(feed).isUnavailable, "the usual page is not unavailable")
        network.down = []
        network.answer(tmdbPage)
        streaming(filter: 8)
        let retried = load(feed, force: true)
        check(!retried.isUnavailable && retried.shelves.count == 8, "Retry: the service's page")
    }

    /// TMDB failing alone is not the device being offline. A service
    /// picked while the rest of the page is fresh asks only TMDB; when it
    /// refuses the key, the filtered page is unavailable, and the usual page
    /// after « All » shows no offline note.
    func testAServiceFailingWhileTheRestIsFreshIsNotOffline() {
        streaming(filter: nil)
        // Series-year answers long enough to count as complete, so a second
        // refresh within the hour asks nothing.
        let top = (try! JSONSerialization.jsonObject(with: HomeFixture.data("cm_series_top.json")) as! [String: Any])["metas"] as! [[String: Any]]
        let metas: [[String: Any]] = (0..<40).map { i in
            var meta = top[i % top.count]
            meta["id"] = String(format: "tt98%05d", i)
            meta["imdb_id"] = meta["id"]
            return meta
        }
        let yearPage = try! JSONSerialization.data(withJSONObject: ["metas": metas])
        network.answer { [self] request in
            if request.host == .cinemeta, request.path.contains("/catalog/series/year/") { return .some(yearPage) }
            return self.tmdbPage(request)
        }
        let feed = makeFeed(options: servicesOptions)
        check(!load(feed).isOffline, "the usual page, online")

        clock.now = HomeFixture.now.addingTimeInterval(600)
        network.down = [.tmdb]
        network.forget()
        streaming(filter: 8)
        feed.refreshLocal()
        check(homeWait { self.tmdbPaths.count >= 6 }, "Netflix's lists asked", "\(tmdbPaths)")
        idle(feed)
        homeSettle(0.2)
        eq(network.requests.filter { $0.host != .tmdb }.count, 0, "nothing else asked: the rest is fresh")
        check(feed.snapshot.isUnavailable, "the filtered page: unavailable, with its Retry")
        check(!feed.snapshot.isOffline, "not offline: only TMDB failed")

        streaming(filter: nil)
        feed.refreshLocal()
        homeSettle(0.2)
        idle(feed)
        check(!feed.snapshot.isOffline && !feed.snapshot.isUnavailable, "« All »: the usual page, no offline note")
    }

    /// A service's list that TMDB answers empty is a complete one: it
    /// replaces the titles kept (they left the service), is fresh for its 12
    /// hours, and the page is not unavailable for it.
    func testAServiceListThatEmptiesOutReplacesTheOldOne() {
        streaming(filter: 8)
        network.answer(tmdbPage)
        let feed = makeFeed(options: servicesOptions)
        eq(load(feed).shelves.ids.filter { HomeShelfID.streaming(of: $0) != nil }.count, 6, "Netflix's six shelves")

        clock.now = HomeFixture.now.addingTimeInterval(13 * 3600)
        network.answer { request in
            guard request.host == .tmdb else { return nil }
            return .some(HomeStreamingTests.discover(kind: request.path.hasPrefix("/discover/tv") ? .show : .movie, ids: []))
        }
        let emptied = load(feed)
        check(!emptied.shelves.contains { HomeShelfID.streaming(of: $0.id) != nil }, "the titles that left are gone")
        check(!emptied.isUnavailable && !emptied.isOffline, "an empty answer is not a failure")

        network.forget()
        clock.now = HomeFixture.now.addingTimeInterval(13 * 3600 + 600)
        load(feed)
        eq(tmdbPaths.count, 0, "the empty lists are fresh: not asked again")
    }

    func testServiceListsStayThroughAllAndAnotherService() {
        let netflix = StreamingService(id: 8, name: "Netflix"), disney = StreamingService(id: 337, name: "Disney+")
        streaming(filter: 8, services: [netflix, disney])
        network.answer(tmdbPage)
        let feed = makeFeed(options: servicesOptions)
        load(feed)
        let netflixKeys = Set(HomeShelfID.streamingShelves.map { "tmdb-FR-8-\($0.kind.rawValue)-\($0.sort.rawValue)" })
        check(storedKeys().isSuperset(of: netflixKeys), "Netflix's lists on disk")

        // « All », and a refresh of the usual page (the app comes back to the front).
        streaming(filter: nil)
        clock.now = HomeFixture.now.addingTimeInterval(3600)
        load(feed)
        check(storedKeys().isSuperset(of: netflixKeys), "kept through « All »")
        // Disney+, then Netflix again within its 12 hours: nothing asked of TMDB for it.
        streaming(filter: 337)
        load(feed)
        check(storedKeys().isSuperset(of: netflixKeys), "kept through another service")
        network.forget()
        streaming(filter: 8)
        feed.refreshLocal()
        homeSettle(0.2)
        idle(feed)
        eq(tmdbPaths.count, 0, "fresh: Netflix's page at once, without a request")
        eq(feed.snapshot.shelves.ids.filter { HomeShelfID.streaming(of: $0) != nil }.count, 6, "its six shelves")

        // Past their 12 hours, picked again from the usual page: asked again.
        streaming(filter: nil)
        clock.now = HomeFixture.now.addingTimeInterval(14 * 3600)
        load(feed)
        network.forget()
        streaming(filter: 8)
        feed.refreshLocal()
        check(homeWait { self.tmdbPaths.count == 6 }, "a stale list picked again is asked again", "\(tmdbPaths)")
        idle(feed)

        // Disney+ unchecked, then another country: their lists leave.
        streaming(filter: nil, services: [netflix])
        load(feed)
        check(!storedKeys().contains { $0.hasPrefix("tmdb-FR-337-") }, "an unchecked service's lists are cleaned")
        check(storedKeys().isSuperset(of: netflixKeys), "not the others'")
        streaming(filter: nil, region: "BE")
        load(feed)
        check(!storedKeys().contains { $0.hasPrefix("tmdb-") }, "another country: France's lists are cleaned")
    }

    func testAServicePickedDuringARefreshIsAskedWhenItEnds() {
        streaming(filter: nil)
        network.answer(tmdbPage)
        let feed = makeFeed(options: servicesOptions)
        network.hold = true
        feed.refresh()
        check(homeWait { !self.network.waiting.isEmpty }, "a refresh of the usual page runs")
        streaming(filter: 8)
        feed.refreshLocal()
        homeSettle()
        check(network.waiting.allSatisfy { $0.host != .tmdb }, "it goes on with its own plan")
        network.hold = false
        network.release()
        check(homeWait { self.tmdbPaths.count == 6 }, "the service's lists are asked when it ends", "\(tmdbPaths)")
        idle(feed)
        check(homeWait { feed.snapshot.shelves.filter { HomeShelfID.streaming(of: $0.id) != nil }.count == 6 }, "its page")
    }

    /// The Apple TV picks a service while the lookups that follow a refresh are still out:
    /// one of them answers after the filter changed and before the pick's `refreshLocal`
    /// reaches the hub. The page it makes is the picked one, its lists not asked yet: it is
    /// on its way (« refreshing »), not a page that listed nothing and is done — the screen
    /// would say « No results » and let go of the card it keeps the focus on, and the
    /// service's shelves would then come in below the screen.
    func testAServicePickedWhileALookupAnswersIsOnItsWay() {
        streaming(filter: nil)
        network.answer(tmdbPage)
        let feed = makeFeed(options: servicesOptions)
        var updates: [HomeSnapshot] = []
        feed.onUpdate = { updates.append($0) }
        let isLookup = { (request: HomeRequest) in
            request.path.hasPrefix("/meta/movie/") || request.path.hasPrefix("/catalog/series/last-videos/")
        }
        // A refresh of the usual page, every request answered but the lookups it leaves.
        network.hold = true
        var ended = false
        feed.refresh { ended = true }
        check(homeWait { self.network.release { !isLookup($0) }; return ended }, "the refresh ends")
        check(homeWait { self.network.waiting.contains(where: isLookup) }, "its lookups are out")
        check(!feed.snapshot.isRefreshing, "the usual page is done")

        // Netflix picked; a lookup answers first, and the hub rebuilds the page before the
        // pick's `refreshLocal` comes.
        streaming(filter: 8)
        network.release(isLookup)
        check(homeWait { feed.isIdle }, "the lookups' page is made")
        homeSettle(0.1)
        feed.refreshLocal()
        network.hold = false
        check(homeWait { self.network.release(); return feed.snapshot.shelves.contains { HomeShelfID.streamingService(of: $0.id) == 8 } },
              "Netflix's shelves come")
        idle(feed)
        feed.onUpdate = nil

        let picked = updates.filter { $0.shelves.shelf(HomeShelfID.services)?.items.contains(where: HomeServiceCard.isSelected) == true }
        check(!picked.isEmpty, "the picked page was delivered")
        for update in picked where !update.shelves.contains(where: { HomeShelfID.streamingService(of: $0.id) == 8 }) {
            check(update.isRefreshing, "Netflix's page without its shelves is on its way, not done",
                  "\(update.shelves.ids) refreshing=\(update.isRefreshing)")
        }
        eq(tmdbPaths.count, 6, "its six lists asked")
    }

    // MARK: Observable state

    @MainActor
    func testObservableState() async {
        // Every page delivered (no spacing; `testUpdatesThatComeTogetherAreDeliveredAsOne`
        // tests the spacing): the fake network answers within milliseconds.
        var options = HomeFeed.Options(requestDeadline: .infinity, phaseGrace: .infinity)
        options.updateSpacing = 0
        let feed = makeFeed(options: options)
        let state = HomeState(feed: feed)
        check(!state.hasLoaded && state.shelves.isEmpty && state.heroItems.isEmpty && !state.isRefreshing, "nothing before start")

        let observer = ShelvesObserver()
        observer.observe(state)
        var changes: Int { observer.changes }
        state.start()
        // An async test runs as a job of the main queue: it waits by suspending, not by
        // running the run loop (which would not let the other main-queue blocks in).
        let loaded = await homeUntil { state.hasLoaded && !state.isRefreshing && !state.shelves.isEmpty }
        check(loaded, "start loads")
        eq(state.heroItems.count, 8, "the hero's cards")
        check(!state.shelves.contains { $0.id == HomeShelfID.hero }, "the shelves are the rows under the hero")
        eq(state.shelves.first?.id, HomeShelfID.trendingMovies, "first row")
        eq(state.lastUpdated, HomeFixture.now, "updated")
        check(!state.isOffline && !state.isUnavailable, "online")
        check(changes >= 3, "observers of `shelves` were told as the page filled", "\(changes) changes")
        check(state.shelf(HomeShelfID.uhd) != nil && state.shelf(HomeShelfID.hero) == nil, "shelf by id")
        // The lookups that follow the refresh still add cards to the rankings.
        _ = await homeUntil { feed.isIdle }
        try? await Task.sleep(nanoseconds: 20_000_000)

        // A refresh that changes nothing does not invalidate the shelves.
        let before = changes
        await state.refresh()
        check(!state.isRefreshing, "refresh() returns when the refresh is over")
        eq(changes, before, "the same shelves are not assigned again")

        // Pull to refresh while offline: the flags follow, the page stays.
        network.down = Set(HomeRequest.Host.allCases)
        clock.now = HomeFixture.now.addingTimeInterval(5 * 3600)
        await state.refresh()
        check(state.isOffline && !state.isUnavailable && !state.shelves.isEmpty, "offline with the cached page")
        network.down = []
        await state.refresh(force: true)
        check(!state.isOffline, "online again")
        state.refreshLocal()
        state.start()
        let again = await homeUntil { !state.isRefreshing }
        check(again, "start can be called again")
    }
}
