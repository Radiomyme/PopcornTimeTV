//
//  HomeLightPlanTests.swift
//  PopcornTimeTests
//
//  The light refresh of the Home (HomeFeed.Options.light: the Top Shelf extension's): the
//  five lists of the first paint and of the 4K badges and nothing else, the stand-in of a list
//  that failed, January, no lookup and no refresh that starts itself again; and the
//  notification a refresh posts when it has ended. Recorded answers (Fixtures/Home): nothing
//  here reaches a host.
//

import Foundation
import XCTest
@testable import PopcornKit

final class HomeLightPlanTests: CheckedTestCase {

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
        sandbox.discard()
        super.tearDown()
    }

    private func makeFeed(light: Bool = true) -> HomeFeed {
        let clock = self.clock!
        var options = HomeFeed.Options(requestDeadline: .infinity, phaseGrace: .infinity)
        options.light = light
        return HomeFeed(store: HomeStore(directory: sandbox.directory, now: { clock.now }), transport: network.transport,
                        defaults: sandbox.defaults, deviceLanguages: { ["en-US"] }, options: options, now: { clock.now })
    }

    /// A whole refresh; what was asked meanwhile.
    @discardableResult
    private func load(_ feed: HomeFeed, file: StaticString = #filePath, line: Int = #line) -> HomeSnapshot {
        var done = false
        feed.refresh { done = true }
        check(homeWait { done }, "the refresh ends", file: file, line: line)
        homeWait { feed.isIdle }
        homeSettle(0.05)
        return feed.snapshot
    }

    private let fiveLists: Set<String> = [
        "/catalog/movie/top.json", "/catalog/series/top.json",
        "/api/v2/list_movies.json?limit=50&order_by=desc&query_term=2026&sort_by=date_added&minimum_rating=6",
        "/api/v2/list_movies.json?limit=50&order_by=desc&quality=2160p&sort_by=date_added",
        "/precompiled/data_top100_211.json",
    ]

    func testALightRefreshAsksFiveLists() {
        // All five at once: the 4K ranking does not wait for the others.
        network.hold = true
        let feed = makeFeed()
        var done = false
        feed.refresh { done = true }
        check(homeWait { self.network.waiting.count == 5 }, "five requests in flight", "\(network.waiting.map(\.path))")
        homeSettle()
        eq(Set(network.waiting.map(\.path)), fiveLists, "the first paint and the 4K ranking")
        check(!done, "the refresh waits for them")
        network.hold = false
        network.release()
        check(homeWait { done }, "the refresh ends")
        homeWait { feed.isIdle }
        homeSettle(0.1)

        let snapshot = feed.snapshot
        eq(Set(network.paths), fiveLists, "nothing else was asked: no other shelf, no lookup of a ranking's titles")
        eq(network.requests.count, 5, "each once")
        eq(snapshot.shelves.ids, [HomeShelfID.hero, HomeShelfID.trendingMovies, HomeShelfID.newMovies, HomeShelfID.uhd,
                                  HomeShelfID.airedEpisodes, HomeShelfID.trendingShows], "the shelves of the first paint")
        check(!snapshot.isRefreshing && !snapshot.isOffline && !snapshot.isUnavailable, "a page, not an error")
        // The 4K ranking gave its badges to the movies of the other lists.
        let badges = Set(snapshot.shelves.flatMap(\.items).flatMap(\.badges))
        check(badges.isSuperset(of: [.uhd, .dolbyVision, .hdr, .atmos]), "4K, Dolby Vision, HDR and Atmos badges", "\(badges)")

        // Fresh lists are not asked again, and the local shelves start no refresh of their own
        // (a full plan would ask the genre lists it reads and never asked).
        load(feed)
        feed.refreshLocal()
        homeSettle(0.2)
        eq(network.requests.count, 5, "nothing asked while the lists are fresh")
        check(feed.isIdle, "no refresh left running")

        // The same lists make the same page when read back from the disk, without a request.
        let reopened = makeFeed()
        eq(reopened.cachedSnapshot().shelves, snapshot.shelves, "the page from the disk")
        eq(network.requests.count, 5, "reading the disk asks nothing")
    }

    func testALightRefreshStandsInForAListThatFailed() {
        network.down = [.cinemeta]
        let feed = makeFeed()
        let snapshot = load(feed)
        let asked = Set(network.paths)
        check(asked.isSuperset(of: fiveLists), "the five lists")
        check(asked.contains { $0.contains("sort_by=like_count") }, "the trending movies' stand-in: the year's most liked on YTS", "\(asked)")
        check(!network.requests.contains { $0.host == .tvmaze }, "no TV schedule: not a list of the first paint")
        check(asked.subtracting(fiveLists).allSatisfy { $0.contains("sort_by=like_count") }, "nothing else", "\(asked.subtracting(fiveLists))")
        check(snapshot.shelf(HomeShelfID.trendingMovies) != nil, "trending movies, from the stand-in")
        check(!snapshot.heroItems.isEmpty, "a hero made of them")
        check(snapshot.heroItems.allSatisfy { $0.backdropURL?.host == "images.metahub.space" }, "with metahub's backdrops by IMDb id")
        check(!snapshot.isOffline, "one host down is not offline")
    }

    func testJanuaryAsksTheYearBefore() {
        clock.now = CatalogDates.date(from: "2027-01-02T10:00:00Z")!
        let feed = makeFeed()
        load(feed)
        let yts = network.requests.filter { $0.host == .yts }.map(\.path)
        check(yts.contains { $0.contains("query_term=2027") && $0.contains("sort_by=date_added") }, "this year's additions")
        check(yts.contains { $0.contains("query_term=2026") && $0.contains("sort_by=date_added") }, "last year's: this year's list is short")
        check(yts.count == 3, "and the 4K list: nothing else of YTS", "\(yts)")
        check(!network.requests.contains { $0.host == .tvmaze }, "no TV schedule")
    }

    func testARefreshThatEndsIsAnnounced() {
        for light in [true, false] {
            let feed = makeFeed(light: light)
            var announced: [(refreshing: Bool, main: Bool, shelves: Int)] = []
            let token = NotificationCenter.default.addObserver(forName: HomeFeed.didRefreshNotification, object: feed, queue: nil) { notification in
                let sender = notification.object as? HomeFeed
                announced.append((sender?.snapshot.isRefreshing ?? true, Thread.isMainThread, sender?.snapshot.shelves.count ?? 0))
            }
            defer { NotificationCenter.default.removeObserver(token) }
            // The page when the refresh ends (a full plan's lookups add to it later).
            var left: Int?
            feed.refresh { left = feed.snapshot.shelves.count }
            check(homeWait { left != nil }, "light \(light): the refresh ends")
            homeWait { feed.isIdle }
            homeSettle(0.05)
            eq(announced.count, 1, "light \(light): announced once")
            eq(announced.first?.refreshing, false, "light \(light): after the last update — the snapshot is the page it left")
            eq(announced.first?.main, true, "light \(light): on the main thread")
            eq(announced.first?.shelves, left, "light \(light): with every shelf of that page")
            check((left ?? 0) >= 6, "light \(light): a page", "\(String(describing: left))")
            // A refresh that asks nothing ends too.
            load(feed)
            eq(announced.count, 2, "light \(light): every refresh that ends")
            network.forget()
            sandbox.discard()
            sandbox = HomeSandbox()
        }
    }
}
