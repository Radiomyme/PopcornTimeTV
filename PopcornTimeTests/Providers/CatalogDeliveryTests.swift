//
//  CatalogDeliveryTests.swift
//  PopcornTimeTests
//
//  How a catalog answer is obtained and delivered: which mirror is asked first and which
//  is left for last (MirrorHealth), the staggered race between mirrors and the validation
//  of their answers (MirrorRace), and when a list fed by several sources stops waiting
//  (SourceGate). Transports, timers, the clock and the defaults are injected: nothing
//  here uses the network or waits.
//

import XCTest
import Foundation
@testable import PopcornKit

/// Timers collected instead of run: a test fires them by their delay.
private final class ManualScheduler {
    private var timers: [(delay: TimeInterval, work: () -> Void)] = []

    var schedule: (TimeInterval, @escaping () -> Void) -> Void {
        return { [self] delay, work in timers.append((delay, work)) }
    }

    func count(_ delay: TimeInterval) -> Int {
        return timers.filter { $0.delay == delay }.count
    }

    /// Runs (and removes) the timers of that delay set so far, oldest first.
    func fire(_ delay: TimeInterval) {
        let due = timers.filter { $0.delay == delay }
        timers.removeAll { $0.delay == delay }
        due.forEach { $0.work() }
    }
}

/// A transport whose requests a test answers when it wants.
private final class ManualTransport {
    private(set) var asked: [String] = []
    private(set) var cancelled: [String] = []
    private var pending: [String: (MirrorRace.Answer) -> Void] = [:]
    /// Hosts answered at once, before `transport` returns.
    var immediate: [String: MirrorRace.Answer] = [:]

    var transport: MirrorRace.Transport {
        return { [self] host, completion in
            asked.append(host)
            if let answer = immediate[host] {
                completion(answer)
            } else {
                pending[host] = completion
            }
            return { [self] in cancelled.append(host) }
        }
    }

    func answer(_ host: String, _ answer: MirrorRace.Answer) {
        let completion = pending[host]
        pending[host] = nil
        completion?(answer)
    }
}

/// A defaults domain for one test, as a file in a temporary folder (see BandwidthTests:
/// a named suite would leave a plist in ~/Library/Preferences at every run).
private func throwawayDefaults(_ name: String) -> (UserDefaults, String) {
    let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("PopcornTimeTests-defaults")
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let domain = (folder as NSString).appendingPathComponent(name)
    let suite = UserDefaults(suiteName: domain)!
    suite.removePersistentDomain(forName: domain)
    return (suite, domain)
}

private func discardDefaults(_ suite: UserDefaults, _ domain: String) {
    suite.removePersistentDomain(forName: domain)
    suite.synchronize()
    try? FileManager.default.removeItem(atPath: domain + ".plist")
}

private let valid = Data("{\"status\":\"ok\",\"data\":{\"movie_count\":1}}".utf8)
private let html = Data("<!DOCTYPE html><html><body>This domain is for sale</body></html>".utf8)
private let stagger = 2.0, deadline = 10.0
private let mirrors = ["https://a.example", "https://b.example", "https://c.example"]

final class MirrorChainTests: CheckedTestCase {

    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var defaults: UserDefaults!
    private var domain = ""

    override func setUp() {
        super.setUp()
        now = Date(timeIntervalSince1970: 1_800_000_000)
        let made = throwawayDefaults("mirrors-\(UUID().uuidString)")
        defaults = made.0
        domain = made.1
    }

    override func tearDown() {
        discardDefaults(defaults, domain)
        super.tearDown()
    }

    private func health() -> MirrorHealth {
        return MirrorHealth(name: "Test", stickyKey: "sticky", defaults: defaults, now: { [unowned self] in self.now })
    }

    // MARK: MirrorHealth

    func testTheStickyMirrorIsTheOneThatGaveAValidAnswer() {
        let health = self.health()
        eq(health.ordered(mirrors), mirrors, "nothing known: the list's order")
        eq(health.sticky, nil, "nothing known: no sticky mirror")
        health.succeeded(mirrors[1])
        eq(health.sticky, mirrors[1], "the mirror that answered is sticky")
        eq(health.ordered(mirrors), [mirrors[1], mirrors[0], mirrors[2]], "it is asked first")
        // Another instance (a relaunch) reads it back.
        eq(self.health().ordered(mirrors), [mirrors[1], mirrors[0], mirrors[2]], "a relaunch keeps it")
        // A host that is no longer a mirror is ignored.
        eq(health.ordered([mirrors[0], mirrors[2]]), [mirrors[0], mirrors[2]], "a sticky host out of the list changes nothing")
    }

    func testTheStickyMirrorExpires() {
        let health = self.health()
        health.succeeded(mirrors[2])
        now += MirrorHealth.stickyLifetime - 60
        eq(health.ordered(mirrors).first, mirrors[2], "23 h 59: still sticky")
        now += 120
        eq(health.sticky, nil, "24 h 01: not sticky any more")
        eq(health.ordered(mirrors), mirrors, "24 h 01: the list's order again")
        // Used all along, it stays sticky: the date is refreshed (at most once an hour).
        health.succeeded(mirrors[2])
        now += 2 * 3600
        health.succeeded(mirrors[2])
        now += MirrorHealth.stickyLifetime - 3600
        eq(health.sticky, mirrors[2], "a mirror in use stays sticky")
    }

    func testAStickyHostOfAnOlderVersionIsNotTrusted() {
        // 5.2.0 stored the host of any 2xx answer, without a date.
        defaults.set(mirrors[1], forKey: "sticky")
        let health = self.health()
        eq(health.sticky, nil, "a host without a date is not sticky")
        eq(health.ordered(mirrors), mirrors, "the list's order")
        health.succeeded(mirrors[0])
        eq(health.sticky, mirrors[0], "the first valid answer sets it")
    }

    func testAFailedMirrorGoesLastForAWhile() {
        let health = self.health()
        health.succeeded(mirrors[0])
        health.failed(mirrors[0], .invalid)
        eq(health.sticky, nil, "a sticky mirror that fails is forgotten")
        eq(health.ordered(mirrors), [mirrors[1], mirrors[2], mirrors[0]], "it goes last")
        now += 599
        eq(health.ordered(mirrors).last, mirrors[0], "9 min 59 after an invalid answer: still last")
        now += 2
        eq(health.ordered(mirrors), mirrors, "10 min 01: back in its place")

        health.failed(mirrors[1], .timedOut)
        eq(health.ordered(mirrors), [mirrors[0], mirrors[2], mirrors[1]], "a timeout: last")
        now += 61
        eq(health.ordered(mirrors), mirrors, "a minute later: back")

        health.failed(mirrors[1], .unreachable)
        now += 299
        eq(health.ordered(mirrors).last, mirrors[1], "unreachable: 5 minutes")
        now += 2
        eq(health.ordered(mirrors), mirrors, "5 min 01: back")

        health.failed(mirrors[0], .http(503))
        eq(health.ordered(mirrors).last, mirrors[0], "an HTTP error: last")
        now += 61

        // Not the mirror's fault (offline): nothing changes, and it stays sticky.
        health.succeeded(mirrors[2])
        health.failed(mirrors[2], .other)
        eq(health.sticky, mirrors[2], "an offline failure keeps the sticky mirror")
        eq(health.ordered(mirrors), [mirrors[2], mirrors[0], mirrors[1]], "an offline failure changes no order")

        // Every mirror failing: they are all still asked, in order.
        for mirror in mirrors { health.failed(mirror, .timedOut) }
        eq(health.ordered(mirrors), mirrors, "all backing off: all asked, in the list's order")
        // A valid answer ends the backoff.
        health.succeeded(mirrors[1])
        eq(health.ordered(mirrors).first, mirrors[1], "a valid answer puts a mirror first again")
        eq(MirrorHealth.backoff(after: .other), nil, "offline: no backoff")
    }

    // MARK: MirrorRace

    private struct Outcome {
        var calls = 0
        var data: Data?
        var error: NSError?
    }

    private func race(_ transport: ManualTransport, _ scheduler: ManualScheduler, health: MirrorHealth?,
                      hosts: [String] = mirrors) -> () -> Outcome {
        var outcome = Outcome()
        MirrorRace.run(hosts: hosts, health: health, stagger: stagger, deadline: deadline, schedule: scheduler.schedule,
                       validate: YTSEZTVProvider.isYTSAnswer, transport: transport.transport) { data, error in
            outcome.calls += 1
            outcome.data = data
            outcome.error = error
        }
        return { outcome }
    }

    func testAnHTMLAnswerNeverWins() {
        let transport = ManualTransport(), scheduler = ManualScheduler(), health = self.health()
        // The first mirror answers 200 with a parked domain's page.
        transport.immediate[mirrors[0]] = .data(html)
        let outcome = race(transport, scheduler, health: health)
        eq(transport.asked, [mirrors[0], mirrors[1]], "the next mirror is asked at once")
        eq(outcome().calls, 0, "no answer yet")
        transport.answer(mirrors[1], .data(valid))
        eq(outcome().calls, 1, "one answer")
        eq(outcome().data, valid, "the valid answer")
        eq(health.sticky, mirrors[1], "the mirror with the valid answer is sticky, not the parked one")
        eq(health.ordered(mirrors), [mirrors[1], mirrors[2], mirrors[0]], "the parked mirror goes last")
        eq(transport.asked.count, 2, "the third mirror was never asked")
    }

    func testASlowMirrorIsRacedAfterTheStagger() {
        let transport = ManualTransport(), scheduler = ManualScheduler(), health = self.health()
        let outcome = race(transport, scheduler, health: health)
        eq(transport.asked, [mirrors[0]], "one mirror at first")
        eq(scheduler.count(stagger), 1, "a stagger timer")
        scheduler.fire(stagger)
        eq(transport.asked, [mirrors[0], mirrors[1]], "2 s without an answer: the second mirror too")
        scheduler.fire(stagger)
        eq(transport.asked, mirrors, "2 s more: the third")
        scheduler.fire(stagger)
        eq(transport.asked, mirrors, "no fourth mirror")
        // The first mirror answers at last: it wins, the others are cancelled.
        transport.answer(mirrors[0], .data(valid))
        eq(outcome().calls, 1, "one answer")
        eq(outcome().data, valid, "the first mirror's")
        eq(Set(transport.cancelled), Set([mirrors[1], mirrors[2]]), "the other requests are cancelled")
        eq(health.sticky, mirrors[0], "the winner is sticky")
        eq(health.ordered(mirrors), mirrors, "a mirror that lost the race is not marked failed")
        // Their late answers change nothing.
        transport.answer(mirrors[1], .data(valid))
        transport.answer(mirrors[2], .failure(.other, nil))
        scheduler.fire(deadline)
        eq(outcome().calls, 1, "still one answer")
        eq(health.sticky, mirrors[0], "still the winner")
    }

    func testAFailureAsksTheNextMirrorAtOnce() {
        let transport = ManualTransport(), scheduler = ManualScheduler(), health = self.health()
        let outcome = race(transport, scheduler, health: health)
        let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        transport.answer(mirrors[0], .failure(.unreachable, refused))
        eq(transport.asked, [mirrors[0], mirrors[1]], "the second mirror without waiting")
        // The first mirror's stagger timer no longer starts anything.
        scheduler.fire(stagger)
        eq(transport.asked, [mirrors[0], mirrors[1], mirrors[2]], "the second mirror's own stagger starts the third")
        transport.answer(mirrors[2], .data(valid))
        eq(outcome().data, valid, "the third mirror's answer")
        eq(transport.cancelled, [mirrors[1]], "the second request is cancelled")
        eq(health.ordered(mirrors), [mirrors[2], mirrors[1], mirrors[0]], "the winner first, the unreachable one last")
    }

    func testEveryMirrorFailing() {
        let transport = ManualTransport(), scheduler = ManualScheduler(), health = self.health()
        let dns = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        transport.immediate[mirrors[0]] = .failure(.unreachable, dns)
        transport.immediate[mirrors[1]] = .data(html)
        transport.immediate[mirrors[2]] = .failure(.http(503), NSError(domain: "http", code: 503))
        let outcome = race(transport, scheduler, health: health)
        eq(transport.asked, mirrors, "every mirror was asked")
        eq(outcome().calls, 1, "one answer")
        eq(outcome().data, nil, "no data")
        eq(outcome().error?.code, 503, "the last error")
        eq(health.sticky, nil, "no sticky mirror")
        scheduler.fire(deadline)
        scheduler.fire(stagger)
        eq(outcome().calls, 1, "the timers change nothing afterwards")
        eq(transport.cancelled, [], "nothing left to cancel")
    }

    func testTheDeadline() {
        let transport = ManualTransport(), scheduler = ManualScheduler(), health = self.health()
        let outcome = race(transport, scheduler, health: health)
        scheduler.fire(stagger)
        eq(transport.asked, [mirrors[0], mirrors[1]], "two mirrors asked")
        scheduler.fire(deadline)
        eq(outcome().calls, 1, "the race ends at the deadline")
        eq(outcome().data, nil, "without data")
        eq(outcome().error?.code, NSURLErrorTimedOut, "a timeout")
        check(!(outcome().error?.localizedDescription ?? "").isEmpty, "with a message")
        eq(Set(transport.cancelled), Set([mirrors[0], mirrors[1]]), "the running requests are cancelled")
        eq(health.ordered(mirrors), [mirrors[2], mirrors[0], mirrors[1]], "the mute mirrors go last")
        transport.answer(mirrors[0], .data(valid))
        eq(outcome().calls, 1, "a late answer is ignored")
        eq(health.sticky, nil, "and does not make its mirror sticky")
    }

    func testNoMirror() {
        let transport = ManualTransport(), scheduler = ManualScheduler()
        let outcome = race(transport, scheduler, health: nil, hosts: [])
        eq(outcome().calls, 1, "an answer at once")
        eq(outcome().data, nil, "no data")
        check(outcome().error != nil, "an error")
    }

    func testARaceWithoutHealth() {
        let transport = ManualTransport(), scheduler = ManualScheduler()
        transport.immediate[mirrors[0]] = .data(valid)
        let outcome = race(transport, scheduler, health: nil)
        eq(outcome().data, valid, "the answer")
        eq(transport.asked, [mirrors[0]], "one request")
        eq(transport.cancelled, [], "nothing to cancel: the request had answered")
    }
}

final class SourceGateTests: CheckedTestCase {

    private let grace = 0.6

    private func gate(_ scheduler: ManualScheduler) -> (SourceGate, () -> [Bool]) {
        var fired: [Bool] = []
        let gate = SourceGate(deadline: deadline, grace: grace, schedule: scheduler.schedule) { fired.append($0) }
        return (gate, { fired })
    }

    func testEverySourceAnswering() {
        let scheduler = ManualScheduler()
        let (gate, fired) = gate(scheduler)
        let yts = gate.source(required: true), t4p = gate.source(required: false)
        gate.start()
        eq(fired(), [], "nothing yet")
        t4p(true)
        eq(fired(), [], "the required source is still out")
        yts(true)
        eq(fired(), [true], "all in: delivered, complete")
        scheduler.fire(grace)
        scheduler.fire(deadline)
        eq(fired(), [true], "once only")
    }

    func testASlowOptionalSourceIsLeftOut() {
        let scheduler = ManualScheduler()
        let (gate, fired) = gate(scheduler)
        let yts = gate.source(required: true), t4p = gate.source(required: false)
        gate.start()
        yts(true)
        eq(fired(), [], "the optional source gets its grace")
        eq(scheduler.count(grace), 1, "a grace timer")
        scheduler.fire(grace)
        eq(fired(), [false], "after the grace: delivered without it")
        t4p(true)
        scheduler.fire(deadline)
        eq(fired(), [false], "its late answer changes nothing")
    }

    func testAnOptionalSourceAnsweringWithinTheGrace() {
        let scheduler = ManualScheduler()
        let (gate, fired) = gate(scheduler)
        let yts = gate.source(required: true), t4p = gate.source(required: false), cinemeta = gate.source(required: false)
        gate.start()
        yts(true)
        t4p(false)
        eq(fired(), [], "one optional source still out")
        cinemeta(true)
        eq(fired(), [true], "all in before the grace: complete")
        scheduler.fire(grace)
        eq(fired(), [true], "the grace timer changes nothing")
        eq(scheduler.count(grace), 0, "one grace timer only")
    }

    func testTheOptionalSourcesAreAllThereIsWhenTheRequiredOneBringsNothing() {
        let scheduler = ManualScheduler()
        let (gate, fired) = gate(scheduler)
        let yts = gate.source(required: true), t4p = gate.source(required: false)
        gate.start()
        yts(false)
        eq(scheduler.count(grace), 0, "no grace: the optional source is waited for")
        eq(fired(), [], "waiting")
        t4p(true)
        eq(fired(), [true], "delivered when it answers")
    }

    func testAnOptionalSourcesContentIsNotHeldForAMuteOne() {
        // A search for a title YTS does not have: Cinemeta finds it, Time4Popcorn's host is mute.
        let scheduler = ManualScheduler()
        let (gate, fired) = gate(scheduler)
        let yts = gate.source(required: true), cinemeta = gate.source(required: false), t4p = gate.source(required: false)
        gate.start()
        cinemeta(true)
        eq(scheduler.count(grace), 0, "the required source is still out: no grace yet")
        eq(fired(), [], "waiting for the required source")
        yts(false)
        eq(scheduler.count(grace), 1, "the required source answered and there is content: the mute one gets its grace")
        eq(fired(), [], "not delivered before the grace")
        scheduler.fire(grace)
        eq(fired(), [false], "delivered after the grace, without the mute source")
        t4p(true)
        scheduler.fire(deadline)
        eq(fired(), [false], "once only")

        // The same answers the other way round.
        let other = ManualScheduler()
        let (second, delivered) = self.gate(other)
        let required = second.source(required: true), found = second.source(required: false), _ = second.source(required: false)
        second.start()
        required(false)
        eq(other.count(grace), 0, "nothing yet: the optional sources are waited for")
        found(true)
        eq(other.count(grace), 1, "content: the last one gets its grace")
        other.fire(grace)
        eq(delivered(), [false], "delivered without it")

        // Optional sources that answer with nothing start no grace.
        let empty = ManualScheduler()
        let (third, nothing) = self.gate(empty)
        let base = third.source(required: true), first = third.source(required: false), _ = third.source(required: false)
        third.start()
        base(false)
        first(false)
        eq(empty.count(grace), 0, "no content: no grace")
        empty.fire(deadline)
        eq(nothing(), [false], "the deadline delivers")
    }

    func testTheDeadline() {
        let scheduler = ManualScheduler()
        let (gate, fired) = gate(scheduler)
        let yts = gate.source(required: true), t4p = gate.source(required: false)
        gate.start()
        t4p(true)
        scheduler.fire(deadline)
        eq(fired(), [false], "the deadline delivers what arrived")
        yts(true)
        eq(fired(), [false], "once only")
    }

    func testSourcesAnsweringBeforeTheStart() {
        let scheduler = ManualScheduler()
        let (gate, fired) = gate(scheduler)
        let only = gate.source(required: true)
        only(true)
        only(true)
        eq(fired(), [], "not started: nothing delivered")
        let second = gate.source(required: true)
        gate.start()
        eq(fired(), [], "the second source is still out")
        second(false)
        eq(fired(), [true], "delivered when the last one answers")
    }

    func testNoSource() {
        let scheduler = ManualScheduler()
        let (gate, fired) = gate(scheduler)
        gate.start()
        eq(fired(), [true], "no source: delivered at once")
    }

    func testASourceAnsweringTwiceCountsOnce() {
        let scheduler = ManualScheduler()
        let (gate, fired) = gate(scheduler)
        let first = gate.source(required: true), second = gate.source(required: true)
        gate.start()
        first(true)
        first(true)
        eq(fired(), [], "the second source has not answered")
        second(true)
        eq(fired(), [true], "delivered once both did")
    }
}
