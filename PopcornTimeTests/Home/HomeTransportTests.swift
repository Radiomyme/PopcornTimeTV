//
//  HomeTransportTests.swift
//  PopcornTimeTests
//
//  The Home's real transport without the network: which hosts are put aside after a failure
//  and for how long (HomeHostMemory, pure), and HomeHTTP itself on a URLProtocol that plays
//  the hosts — a device that loses its network must not shut the hub out for minutes.
//

import Foundation
import XCTest
@testable import PopcornKit

/// Answers HomeHTTP's requests instead of the network: per host, a JSON body, an error code,
/// a page that is not JSON, or an HTTP error. Every request is logged by host.
private final class HomeHostStub: URLProtocol {

    enum Behaviour {
        case json
        case failure(Int)
        case html
        case status(Int)
    }

    private static let lock = NSLock()
    private static var behaviours: [String: Behaviour] = [:]
    private static var asked: [String] = []

    static func set(_ behaviour: Behaviour, for hosts: [String]) {
        lock.lock(); for host in hosts { behaviours[host] = behaviour }; lock.unlock()
    }

    /// The hosts asked since the last call, in order.
    static func takeLog() -> [String] {
        lock.lock(); defer { asked.removeAll(); lock.unlock() }
        return asked
    }

    static func reset() {
        lock.lock(); behaviours.removeAll(); asked.removeAll(); lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        HomeHostStub.lock.lock()
        HomeHostStub.asked.append(host)
        let behaviour = HomeHostStub.behaviours[host] ?? .failure(NSURLErrorCannotFindHost)
        HomeHostStub.lock.unlock()
        switch behaviour {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: code))
        case .json, .html, .status:
            var status = 200, body = #"{"metas":[]}"#
            if case .html = behaviour { body = "<html>parked</html>" }
            if case .status(let code) = behaviour { status = code }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

final class HomeTransportTests: CheckedTestCase {

    private let now = HomeFixture.now

    // MARK: Which hosts are tried

    func testHostsPutAside() {
        var memory = HomeHostMemory()
        let mirrors = ["https://a", "https://b", "https://c"]
        eq(memory.hostsToTry(mirrors, now: now), mirrors, "nothing failed: every host, in order")

        // One mirror among several cannot be reached: it goes behind the others, for five minutes.
        memory.failed("https://a", .unreachable, now: now)
        eq(memory.hostsToTry(mirrors, now: now.addingTimeInterval(20)), ["https://b", "https://c", "https://a"], "an unreachable mirror is tried after the others")
        eq(memory.hostsToTry(mirrors, now: now.addingTimeInterval(299)), ["https://b", "https://c", "https://a"], "for five minutes")
        eq(memory.hostsToTry(mirrors, now: now.addingTimeInterval(300)), mirrors, "then in its place again")

        // Every host of the service unreachable — the device lost its network, or the service
        // has one host: they are tried all the same (it costs nothing, and it may be over).
        memory.failed("https://b", .unreachable, now: now)
        memory.failed("https://c", .unreachable, now: now)
        eq(memory.hostsToTry(mirrors, now: now.addingTimeInterval(20)), mirrors, "no other host left: the unreachable ones are tried")
        eq(memory.hostsToTry(["https://a"], now: now.addingTimeInterval(1)), ["https://a"], "the only host of a service is never shut out by a failure to reach it")

        // A host that kept silent costs the whole timeout: it is not waited for again for a minute.
        memory.failed("https://a", .silent, now: now)
        eq(memory.hostsToTry(["https://a"], now: now.addingTimeInterval(59)), [], "a host that timed out is not tried for a minute, even alone")
        eq(memory.hostsToTry(["https://a"], now: now.addingTimeInterval(60)), ["https://a"], "then again")
        eq(memory.hostsToTry(mirrors, now: now.addingTimeInterval(20)), ["https://b", "https://c"], "its unreachable mirrors are tried meanwhile, not the silent one")

        // It answers: it is a host like the others again. The user asks again: all are.
        memory.failed("https://b", .silent, now: now)
        memory.answered("https://b")
        eq(memory.hostsToTry(mirrors, now: now.addingTimeInterval(20)), ["https://b", "https://c"], "a host that answered is trusted again, ahead of the unreachable one")
        memory.forget()
        eq(memory.hostsToTry(mirrors, now: now.addingTimeInterval(20)), mirrors, "forget: every host is tried")
        eq(memory.hostsToTry([], now: now), [], "a service without host (turned off)")
    }

    // MARK: HomeHTTP

    private func get(_ http: HomeHTTP, _ host: HomeRequest.Host) -> Data? {
        var answer: Data?, done = false
        http.get(HomeRequest(host: host, path: "/list.json")) { data in
            DispatchQueue.main.async { answer = data; done = true }
        }
        check(homeWait { done }, "\(host.rawValue): the request ends")
        return answer
    }

    func testADeviceFailureDoesNotShutTheHubOut() {
        HomeHostStub.reset()
        defer { HomeHostStub.reset() }
        let http = HomeHTTP(protocolClasses: [HomeHostStub.self])
        http.hosts = { host in
            host == .yts ? ["https://yts-a.test", "https://yts-b.test"] : ["https://\(host.rawValue).test"]
        }
        let every = ["cinemeta.test", "yts-a.test", "yts-b.test", "tvmaze.test", "apibay.test"]
        // TMDB is reached through its own client (`TMDBStreamingClient`), not `HomeHTTP`.
        let served = HomeRequest.Host.allCases.filter { $0 != .tmdb }

        // The router lost its WAN while the Home refreshes: no host resolves.
        HomeHostStub.set(.failure(NSURLErrorCannotFindHost), for: every)
        for host in served { check(get(http, host) == nil, "\(host.rawValue): no answer") }
        eq(HomeHostStub.takeLog(), every, "every host of every service was tried")

        // It is back twenty seconds later, and the Home appears again.
        HomeHostStub.set(.json, for: every)
        for host in served { check(get(http, host) != nil, "\(host.rawValue): asked again, and answers") }
        eq(HomeHostStub.takeLog(), ["cinemeta.test", "yts-a.test", "tvmaze.test", "apibay.test"], "each service by its first host: nothing is shut out for five minutes")

        // One mirror among several fails: the next answers, and the dead one is left alone after.
        HomeHostStub.set(.failure(NSURLErrorCannotConnectToHost), for: ["yts-a.test"])
        check(get(http, .yts) != nil, "the second mirror answers")
        eq(HomeHostStub.takeLog(), ["yts-a.test", "yts-b.test"], "after the first failed")
        check(get(http, .yts) != nil, "again")
        eq(HomeHostStub.takeLog(), ["yts-b.test"], "the mirror that cannot be reached is behind the one that answers")

        // A host that times out is not waited for again (8 s each time)…
        HomeHostStub.set(.failure(NSURLErrorTimedOut), for: ["apibay.test"])
        check(get(http, .apibay) == nil, "apibay hangs")
        eq(HomeHostStub.takeLog(), ["apibay.test"], "asked once")
        HomeHostStub.set(.json, for: ["apibay.test"])
        check(get(http, .apibay) == nil, "the next request fails at once")
        eq(HomeHostStub.takeLog(), [], "without waiting for it again")
        // …a parked page neither…
        HomeHostStub.set(.html, for: ["tvmaze.test"])
        check(get(http, .tvmaze) == nil, "a page that is not JSON is not an answer")
        HomeHostStub.set(.json, for: ["tvmaze.test"])
        check(get(http, .tvmaze) == nil && HomeHostStub.takeLog() == ["tvmaze.test"], "and its host is put aside too")
        // …until the user asks again (Retry, pull to refresh: `HomeTransport.reset`).
        HomeHostStub.set(.json, for: ["yts-a.test"])
        http.forgetFailures()
        check(get(http, .apibay) != nil && get(http, .tvmaze) != nil && get(http, .yts) != nil, "Retry reaches every host")
        eq(HomeHostStub.takeLog(), ["apibay.test", "tvmaze.test", "yts-a.test"], "the first mirror included")

        // An HTTP error is the host answering: it is not put aside.
        HomeHostStub.set(.status(503), for: ["cinemeta.test"])
        check(get(http, .cinemeta) == nil, "a 503 is not a list")
        HomeHostStub.set(.json, for: ["cinemeta.test"])
        check(get(http, .cinemeta) != nil, "and the host is asked again at the next request")
        eq(HomeHostStub.takeLog(), ["cinemeta.test", "cinemeta.test"], "twice")
        check(HomeHTTP.looksLikeJSON(Data(" \n[1]".utf8)) && !HomeHTTP.looksLikeJSON(Data("<html>".utf8)) && !HomeHTTP.looksLikeJSON(Data()), "what JSON starts like")
    }
}
