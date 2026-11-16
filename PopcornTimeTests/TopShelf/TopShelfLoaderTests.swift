//
//  TopShelfLoaderTests.swift
//  PopcornTimeTests
//
//  The Top Shelf extension's loader on recorded answers: a first load waits for its five
//  lists and nothing else; the next ones answer from the disk before returning, ask only what
//  is not fresh, and say "changed" when the refresh brought other titles — once; the cap
//  answers with what has arrived when a host hangs; everything down is an empty answer, not a
//  wait. The network is HomeFakeNetwork (Fixtures/Home): nothing here reaches a host.
//

import Foundation
import XCTest
@testable import PopcornKit

final class TopShelfLoaderTests: CheckedTestCase {

    /// A clock the tests move.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = HomeFixture.now
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return date }
            set { lock.lock(); date = newValue; lock.unlock() }
        }
    }

    /// What one `load` called back.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var models: [TopShelfModel] = []
        private var changes = 0
        var answers: [TopShelfModel] { lock.lock(); defer { lock.unlock() }; return models }
        var changed: Int { lock.lock(); defer { lock.unlock() }; return changes }
        func answer(_ model: TopShelfModel) { lock.lock(); models.append(model); lock.unlock() }
        func change() { lock.lock(); changes += 1; lock.unlock() }
    }

    private var sandbox: HomeSandbox!
    private var network: HomeFakeNetwork!
    private var clock: Clock!
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        sandbox = HomeSandbox()
        network = HomeFakeNetwork()
        clock = Clock()
        lines = []
    }

    override func tearDown() {
        sandbox.discard()
        super.tearDown()
    }

    /// A loader as the extension makes it (`TopShelfLoader.makeFeed`), on the test's folder,
    /// network and clock. `cap`: of the loader; `deadline`: of each request (the extension
    /// gives both the same value).
    private func makeLoader(cap: TimeInterval = 30, deadline: TimeInterval? = nil) -> TopShelfLoader {
        let clock = self.clock!
        let feed = TopShelfLoader.makeFeed(store: HomeStore(directory: sandbox.directory, now: { clock.now }), transport: network.transport,
                                           defaults: sandbox.defaults, deviceLanguages: { ["en-US"] }, cap: deadline ?? cap, now: { clock.now })
        return TopShelfLoader(feed: feed, texts: TopShelfFixture.french, cap: cap, log: { [weak self] line in
            DispatchQueue.main.async { self?.lines.append(line) }
        })
    }

    private func load(_ loader: TopShelfLoader) -> Outcome {
        let outcome = Outcome()
        loader.load(answer: outcome.answer, changed: outcome.change)
        return outcome
    }

    /// Waits for the refresh a load started, and for what it calls back.
    private func finish(_ loader: TopShelfLoader, file: StaticString = #filePath, line: Int = #line) {
        check(homeWait { !loader.feed.snapshot.isRefreshing && loader.feed.isIdle }, "the refresh ends", file: file, line: line)
        homeSettle(0.1)
    }

    private let fiveLists: Set<String> = [
        "/catalog/movie/top.json", "/catalog/series/top.json",
        "/api/v2/list_movies.json?limit=50&order_by=desc&query_term=2026&sort_by=date_added&minimum_rating=6",
        "/api/v2/list_movies.json?limit=50&order_by=desc&quality=2160p&sort_by=date_added",
        "/precompiled/data_top100_211.json",
    ]

    func testAFirstLoadWaitsForItsFiveLists() {
        network.hold = true
        let loader = makeLoader()
        check(loader.current().isEmpty, "nothing on the disk")
        let outcome = load(loader)
        check(homeWait { self.network.waiting.count == 5 }, "five requests", "\(network.waiting.map(\.path))")
        homeSettle()
        eq(Set(network.waiting.map(\.path)), fiveLists, "the first paint and the 4K ranking")
        eq(outcome.answers.count, 0, "no answer before the lists")
        network.hold = false
        network.release()
        check(homeWait { outcome.answers.count == 1 }, "answered when the refresh has ended")
        finish(loader)
        eq(outcome.answers.count, 1, "answered once")
        eq(outcome.changed, 0, "the answer is the news")
        eq(outcome.answers.first?.carousel.count, 10, "a carousel of ten")
        eq(outcome.answers.first, TopShelfModel(snapshot: TopShelfFixture.snapshot(), texts: TopShelfFixture.french),
           "the shelf of the five recorded lists")
        eq(network.requests.count, 5, "five requests in all")
        eq(loader.current(), outcome.answers.first, "what the hub has now")
        check(lines.contains { $0.hasPrefix("answered after the refresh") && $0.hasSuffix("carousel of 10") }, "logged with its timing", "\(lines)")
    }

    func testTheDiskAnswersBeforeTheNetwork() {
        let first = makeLoader()
        let cold = load(first)
        check(homeWait { cold.answers.count == 1 }, "the first load")
        finish(first)

        // Another launch of the extension, 45 minutes later: YTS's additions are not fresh any
        // more (30 minutes), the three other lists are.
        clock.now = HomeFixture.now.addingTimeInterval(45 * 60)
        network.forget()
        network.hold = true
        let second = makeLoader()
        let warm = load(second)
        eq(warm.answers.count, 1, "answered before `load` returned")
        eq(warm.answers.first?.carousel.map(\.id), cold.answers.first?.carousel.map(\.id), "the shelf the disk has")
        eq(network.requests.count, 0, "without a request")
        check(homeWait { self.network.waiting.count == 2 }, "then the two lists that are not fresh are asked", "\(network.waiting.map(\.path))")
        check(network.waiting.allSatisfy { $0.host == .yts }, "YTS's")
        network.hold = false
        network.release()
        finish(second)
        eq(warm.answers.count, 1, "still one answer")
        eq(warm.changed, 0, "the same titles: the system is not asked to come back")
        check(lines.contains { $0.hasPrefix("answered from the disk") }, "logged", "\(lines)")
        check(lines.contains { $0.hasSuffix("the same shelf") }, "and the refresh", "\(lines)")

        // At once again while everything is fresh: nothing is asked at all.
        network.forget()
        let third = load(second)
        eq(third.answers.count, 1, "at once")
        finish(second)
        eq(network.requests.count, 0, "fresh lists are not asked")
        eq(third.changed, 0, "nothing new")
    }

    func testOtherTitlesAfterTheAnswerAreAnnouncedOnce() {
        let first = makeLoader()
        let cold = load(first)
        check(homeWait { cold.answers.count == 1 }, "the first load")
        finish(first)

        // Five hours later Cinemeta's popular movies are others: the first two swapped.
        clock.now = HomeFixture.now.addingTimeInterval(5 * 3600)
        network.answer { request in
            guard request.path == "/catalog/movie/top.json",
                  var root = (try? JSONSerialization.jsonObject(with: HomeFixture.data("cm_movie_top.json"))) as? [String: Any],
                  var metas = root["metas"] as? [Any], metas.count > 1 else { return nil }
            metas.swapAt(0, 1)
            root["metas"] = metas
            return .some(try? JSONSerialization.data(withJSONObject: root))
        }
        let second = makeLoader()
        let warm = load(second)
        eq(warm.answers.count, 1, "answered at once from the disk")
        eq(warm.answers.first?.carousel.map(\.id), cold.answers.first?.carousel.map(\.id), "the shelf of five hours ago")
        check(homeWait { warm.changed == 1 }, "the refresh brought another shelf: announced")
        finish(second)
        eq(warm.changed, 1, "once")
        eq(warm.answers.count, 1, "and not answered twice")
        let now = second.current()
        eq(now.carousel.prefix(2).map(\.id), cold.answers.first.map { Array($0.carousel.prefix(2).map(\.id).reversed()) }, "the new order")

        // The system asks again: the new shelf, at once, and nothing more to announce.
        network.forget()
        let again = load(second)
        eq(again.answers.first, now, "the new shelf at once")
        finish(second)
        eq(again.changed, 0, "nothing new")
        eq(network.requests.count, 0, "nothing asked")
    }

    func testTheCapAnswersWithWhatHasArrived() {
        // Requests may take 30 s; the system waits 0.4 s for us.
        network.hold = true
        let loader = makeLoader(cap: 0.4, deadline: 30)
        let started = Date()
        let outcome = load(loader)
        check(homeWait { self.network.waiting.count == 5 }, "five requests")
        // Cinemeta answers, YTS and apibay hang.
        network.release { $0.host == .cinemeta }
        check(homeWait { outcome.answers.count == 1 }, "answered at the cap")
        let elapsed = Date().timeIntervalSince(started)
        check(elapsed >= 0.35 && elapsed < 3, "at the cap, not before, not much after", "\(elapsed)")
        let partial = outcome.answers.first
        check(!(partial?.carousel.isEmpty ?? true), "with the cards of the lists that answered", "\(String(describing: partial?.carousel.count))")
        check(partial?.carousel.allSatisfy { $0.formats.isEmpty } ?? false, "no format badge yet: YTS and the 4K ranking have not answered")
        eq(outcome.changed, 0, "nothing to announce yet")
        // The cap answers on a background queue; its log line reaches `lines` through the
        // main queue (`makeLoader`), possibly a run-loop turn after the answer itself.
        check(homeWait(1) { self.lines.contains { $0.hasPrefix("answered at the cap") } }, "logged", "\(lines)")

        // The slow hosts answer at last: the system is told to come back.
        network.hold = false
        network.release()
        check(homeWait { outcome.changed == 1 }, "the refresh ended with more: announced")
        finish(loader)
        eq(outcome.answers.count, 1, "answered once")
        eq(outcome.changed, 1, "announced once")
        check(loader.current().carousel.contains { $0.formats.contains(.uhd) }, "the shelf now has its 4K badges")
    }

    func testTheCapAnswersNothingWhenNothingArrived() {
        network.hold = true
        let loader = makeLoader(cap: 0.3, deadline: 30)
        let outcome = load(loader)
        check(homeWait { outcome.answers.count == 1 }, "answered at the cap")
        check(outcome.answers.first?.isEmpty ?? false, "nothing: the system shows the app's static image")
        network.hold = false
        network.release()
        check(homeWait { outcome.changed == 1 }, "then the lists arrive: announced")
        finish(loader)
        eq(loader.current().carousel.count, 10, "the shelf is there for the next load")
    }

    func testEverythingDownIsAnEmptyAnswerNotAWait() {
        network.down = Set(HomeRequest.Host.allCases)
        let loader = makeLoader()
        let started = Date()
        let outcome = load(loader)
        check(homeWait { outcome.answers.count == 1 }, "answered")
        check(Date().timeIntervalSince(started) < 5, "as soon as every list has failed, long before the cap")
        check(outcome.answers.first?.isEmpty ?? false, "nothing to show")
        finish(loader)
        eq(outcome.changed, 0, "and nothing to announce")
    }

    func testTwoLoadsShareOneRefresh() {
        network.hold = true
        let loader = makeLoader()
        let first = load(loader), second = load(loader)
        check(homeWait { self.network.waiting.count == 5 }, "five requests")
        homeSettle(0.1)
        eq(network.requests.count, 5, "asked once, not twice")
        network.hold = false
        network.release()
        check(homeWait { first.answers.count == 1 && second.answers.count == 1 }, "both answered")
        finish(loader)
        eq(first.answers.first, second.answers.first, "the same shelf")
        eq(first.changed + second.changed, 0, "nothing to announce")
    }
}
