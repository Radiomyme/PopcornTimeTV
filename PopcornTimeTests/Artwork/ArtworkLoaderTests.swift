//
//  ArtworkLoaderTests.swift
//  PopcornTimeTests
//
//  The fallback of an artwork load (ArtworkLoader): inside a source, the next address when
//  one fails (a 404 on one size must not leave a hole); the next source when the previous
//  one has failed or stays silent, as the image proxy does for a cover it cannot fetch; the
//  first picture wins and the rest is cancelled. And the hosts put aside after failing in
//  a row (ArtworkRoutes). The network is a table of answers: nothing is fetched.
//

import XCTest
import Foundation
@testable import PopcornKit

/// A network that answers from a table: bytes, an error, or silence (the request only ends
/// when it is cancelled). Records what was asked, and what was cancelled while silent.
final class ArtworkTestNetwork: @unchecked Sendable {

    enum Answer {
        case data(Data)
        case failure
        /// Answers after this many seconds.
        case late(Data, TimeInterval)
        /// Never answers.
        case silent
    }

    private let lock = NSLock()
    private var answers: [URL: Answer] = [:]
    private var asked: [URL] = []
    private var dropped: [URL] = []

    subscript(_ url: URL) -> Answer? {
        get { lock.lock(); defer { lock.unlock() }; return answers[url] }
        set { lock.lock(); answers[url] = newValue; lock.unlock() }
    }

    /// The addresses fetched, in order.
    var requests: [URL] { lock.lock(); defer { lock.unlock() }; return asked }
    /// The silent requests that were cancelled.
    var cancelled: [URL] { lock.lock(); defer { lock.unlock() }; return dropped }

    func reset() {
        lock.lock()
        asked.removeAll()
        dropped.removeAll()
        lock.unlock()
    }

    var fetch: ArtworkLoader.Fetch {
        return { [self] url in
            lock.lock()
            asked.append(url)
            let answer = answers[url]
            lock.unlock()
            switch answer {
            case .data(let data):
                return data
            case .late(let data, let seconds):
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return data
            case .silent:
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    lock.lock()
                    dropped.append(url)
                    lock.unlock()
                    throw error
                }
                throw URLError(.timedOut)
            case .failure, nil:
                throw URLError(.badServerResponse)
            }
        }
    }
}

final class ArtworkLoaderTests: CheckedTestCase {

    private func url(_ name: String) -> URL { URL(string: "https://example.org/\(name)")! }
    private let picture = Data("picture".utf8)
    private let page = Data("<html>not found</html>".utf8)

    /// A loader on `network` whose pictures are the answers that say "picture".
    private func load(_ sources: [[URL]], on network: ArtworkTestNetwork, hedge: TimeInterval = 0.05) async -> ArtworkLoader.Result<String>? {
        let loader = ArtworkLoader(fetch: network.fetch, hedgeDelay: hedge)
        return await loader.load(sources) { data, url in
            String(decoding: data, as: UTF8.self) == "picture" ? url.lastPathComponent : nil
        }
    }

    func testTheSizedVariantIsUsedWhenItAnswers() async {
        let network = ArtworkTestNetwork()
        network[url("small")] = .data(picture)
        network[url("original")] = .data(picture)
        let result = await load([[url("small"), url("original")]], on: network)
        eq(result?.output, "small", "the first address gave the picture")
        eq(result?.url, url("small"), "and is named")
        eq(result?.source, 0, "from the first source")
        eq(result?.passed, [], "nothing was passed over")
        eq(network.requests, [url("small")], "the address as given was never fetched")
    }

    func testAVariantThatFailsFallsBackToTheAddressAsGiven() async {
        let network = ArtworkTestNetwork()
        network[url("small")] = .failure
        network[url("original")] = .data(picture)
        let result = await load([[url("small"), url("original")]], on: network)
        eq(result?.url, url("original"), "a 404 on the size leaves no hole")
        eq(result?.source, 0, "still the first source")
        eq(network.requests, [url("small"), url("original")], "one after the other")
    }

    func testAnAnswerThatIsNotAPictureIsAFailure() async {
        let network = ArtworkTestNetwork()
        network[url("small")] = .data(page)
        network[url("original")] = .data(picture)
        let result = await load([[url("small"), url("original")]], on: network)
        eq(result?.url, url("original"), "an error page served with a 200 is passed over")
    }

    func testTheNextSourceIsTriedWhenTheFirstHasNothing() async {
        let network = ArtworkTestNetwork()
        network[url("cover-small")] = .failure
        network[url("cover")] = .failure
        network[url("metahub")] = .data(picture)
        // A long hedge: the second source starts because the first failed, not because it was slow.
        let result = await load([[url("cover-small"), url("cover")], [url("metahub")], [url("medium-cover")]], on: network, hedge: 30)
        eq(result?.url, url("metahub"), "another picture of the title")
        eq(result?.source, 1, "the second source")
        eq(result?.passed, [0], "the first one failed")
        eq(result?.failed, [0], "and is reported as failed")
        eq(network.requests, [url("cover-small"), url("cover"), url("metahub")], "the third source was not needed")
    }

    func testASilentSourceDoesNotHoldThePictureBack() async {
        let network = ArtworkTestNetwork()
        network[url("cover-small")] = .silent      // the image proxy, for a cover it cannot fetch
        network[url("metahub")] = .data(picture)
        let started = Date()
        let result = await load([[url("cover-small"), url("cover")], [url("metahub")]], on: network)
        eq(result?.url, url("metahub"), "the second source answered while the first said nothing")
        eq(result?.passed, [0], "the first is reported as passed over")
        eq(result?.failed, [], "as silent, not failed")
        check(Date().timeIntervalSince(started) < 10, "long before the first one's timeout", "\(Date().timeIntervalSince(started)) s")
        eq(network.cancelled, [url("cover-small")], "and its request was cancelled")
        eq(network.requests, [url("cover-small"), url("metahub")], "the first source's second address was never tried")
    }

    func testASlowFirstSourceStillWinsWhenItAnswersFirst() async {
        let network = ArtworkTestNetwork()
        network[url("cover")] = .late(picture, 0.2)
        network[url("metahub")] = .silent
        let result = await load([[url("cover")], [url("metahub")]], on: network)
        eq(result?.url, url("cover"), "slower than the hedge, but the first to give a picture")
        eq(result?.source, 0, "the first source")
        eq(result?.passed, [], "the second one, started meanwhile, is not held against anybody")
        eq(network.cancelled, [url("metahub")], "the second source's request was cancelled")
    }

    func testEverySourceInTurnWhenAllAreSilent() async {
        let network = ArtworkTestNetwork()
        network[url("a")] = .silent
        network[url("b")] = .silent
        network[url("c")] = .data(picture)
        let result = await load([[url("a")], [url("b")], [url("c")]], on: network)
        eq(result?.url, url("c"), "the third source, after two hedges")
        eq(result?.passed, [0, 1], "both silent ones are reported")
        eq(Set(network.cancelled), [url("a"), url("b")], "and cancelled")
    }

    func testNothingWhenNoSourceHasAPicture() async {
        let network = ArtworkTestNetwork()
        network[url("a")] = .failure
        network[url("b")] = .data(page)
        let result = await load([[url("a")], [url("b")]], on: network)
        check(result == nil, "no picture")
        eq(network.requests, [url("a"), url("b")], "every address was tried once")
        let nothing = await load([], on: network)
        check(nothing == nil, "no source, no picture")
        let empty = await load([[]], on: network)
        check(empty == nil, "an empty source neither")
    }

    func testACancelledLoadStopsItsRequests() async {
        let network = ArtworkTestNetwork()
        network[url("a")] = .silent
        let sources = [[url("a")], [url("b")]]
        let loader = ArtworkLoader(fetch: network.fetch, hedgeDelay: 30)
        let task = Task { await loader.load(sources) { data, _ in String(decoding: data, as: UTF8.self) } }
        // Let the request start, then give up.
        for _ in 0..<200 where network.requests.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        task.cancel()
        let result = await task.value
        check(result == nil, "a cancelled load gives nothing")
        eq(network.cancelled, [url("a")], "its request was cancelled")
        eq(network.requests, [url("a")], "and the next source was not started")
    }

    // MARK: Routes

    func testARouteThatFailsHalfOfTheTimeIsPutAside() {
        var routes = ArtworkRoutes()
        let now = Date(timeIntervalSince1970: 1_000)
        let cover = URL(string: ImageProxy.proxied("https://yts.gg/assets/images/movies/x/large-cover.jpg")!)!
        let metahub = URL(string: "https://images.metahub.space/poster/small/tt1/img")!
        let medium = URL(string: ImageProxy.proxied("https://yts.gg/assets/images/movies/x/medium-cover.jpg")!)!
        let plan = [[cover], [metahub], [medium]]
        let route = ArtworkURL.route(of: cover)

        routes.failed(route, now: now)
        routes.succeeded(route, now: now)
        routes.failed(route, now: now)
        check(!routes.isBenched(route, now: now), "two failures out of three: still tried first")
        eq(routes.ordered(plan, now: now), plan, "the order is the plan's")
        routes.succeeded(route, now: now)
        routes.failed(route, now: now)
        check(routes.isBenched(route, now: now), "three failures in the last five loads: put aside, successes in between or not")
        eq(routes.ordered(plan, now: now), [[metahub], [cover], [medium]],
           "its addresses go after the others (the medium cover is on the same route), in their order")
        eq(routes.ordered(plan, now: now, isAtHand: { $0 == cover }), plan,
           "but a cover already in the disk cache keeps its place: it needs no host")
        check(routes.isBenched(route, now: now.addingTimeInterval(59)), "for a minute")
        check(!routes.isBenched(route, now: now.addingTimeInterval(61)), "then it is tried first again")
        eq(routes.ordered(plan, now: now.addingTimeInterval(61)), plan, "the plan's order again")
        routes.failed(route, now: now.addingTimeInterval(61))
        check(routes.isBenched(route, now: now.addingTimeInterval(62)), "and put aside at once if it still fails")
        routes.succeeded(route, now: now.addingTimeInterval(62))
        check(routes.isBenched(route, now: now.addingTimeInterval(63)), "one success does not clear a route that fails that often")
        for _ in 0..<4 { routes.succeeded(route, now: now.addingTimeInterval(63)) }
        check(!routes.isBenched(route, now: now.addingTimeInterval(64)), "a run of successes does")
        check(!routes.isBenched("images.metahub.space", now: now), "another route is not concerned")
    }

    func testABenchThatRanOutIsNotStartedAgainByASuccess() {
        var routes = ArtworkRoutes()
        let now = Date(timeIntervalSince1970: 1_000)
        let route = "images.weserv.nl>static.tvmaze.com"
        for _ in 0..<3 { routes.failed(route, now: now) }
        check(routes.isBenched(route, now: now.addingTimeInterval(1)), "three failures: put aside")
        routes.succeeded(route, now: now.addingTimeInterval(30))
        check(routes.isBenched(route, now: now.addingTimeInterval(31)), "a success does not lift the bench")
        routes.succeeded(route, now: now.addingTimeInterval(65))
        check(!routes.isBenched(route, now: now.addingTimeInterval(66)),
              "the minute over, a success does not put it aside again, failures still in its window or not")
        routes.succeeded(route, now: now.addingTimeInterval(126))
        check(!routes.isBenched(route, now: now.addingTimeInterval(127)), "nor the next one")
        routes.failed(route, now: now.addingTimeInterval(130))
        check(routes.isBenched(route, now: now.addingTimeInterval(131)), "a failure, with half of its last six loads failed: put aside")
        for _ in 0..<2 { routes.succeeded(route, now: now.addingTimeInterval(132)) }
        check(!routes.isBenched(route, now: now.addingTimeInterval(133)), "successes that bring it under half lift the bench")
    }

    func testTheSourceThatHadThePictureLastTimeGoesFirst() {
        var routes = ArtworkRoutes()
        let now = Date(timeIntervalSince1970: 1_000)
        let a = URL(string: "https://a.example/small.jpg")!, a2 = URL(string: "https://a.example/original.jpg")!
        let b = URL(string: "https://b.example/1.jpg")!, c = URL(string: "https://c.example/1.jpg")!
        let plan = [[a, a2], [b], [c]]
        eq(routes.ordered(plan, detour: .init(origin: c, skipsVariant: false), now: now), [[c], [a, a2], [b]], "the remembered source first")
        eq(routes.ordered(plan, detour: .init(origin: a2, skipsVariant: true), now: now), [[a2, a], [b], [c]],
           "the first source's sized variant had failed: its address as given goes first")
        eq(routes.ordered(plan, detour: .init(origin: a2, skipsVariant: false), now: now), plan, "the first source as it is")
        // Another size of the same picture: the source is known by its address as given.
        let a3 = URL(string: "https://a.example/large.jpg")!
        eq(routes.ordered([[b], [a3, a2]], detour: .init(origin: a2, skipsVariant: false), now: now), [[a3, a2], [b]],
           "whatever variant is asked this time")
        for _ in 0..<3 { routes.failed("c.example", now: now) }
        eq(routes.ordered(plan, detour: .init(origin: c, skipsVariant: false), now: now), [[c], [a, a2], [b]], "remembered wins over put aside")
        eq(routes.ordered([[a, a2], [c], [b]], now: now), [[a, a2], [b], [c]], "without a memory, put aside goes last")
        eq(routes.ordered([[], [b]], now: now), [[b]], "an empty source is dropped")
    }
}
