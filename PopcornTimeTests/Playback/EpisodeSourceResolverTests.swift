//
//  EpisodeSourceResolverTests.swift
//  PopcornTimeTests
//
//  EpisodeSourceResolver: an episode's three extra sources behind one deadline — the caller is
//  never held by the slowest, a dead source is no longer waited for, answers are kept; a partial
//  list only answers the caller it is enough for, and a source that failed is asked again.
//

import XCTest
import Foundation
@testable import PopcornKit

private typealias Provider = EpisodeSourceResolver.Provider

private func torrent(_ hash: String, quality: String = "1080p", seeds: Int = 50) -> Torrent {
    Torrent(url: "magnet:?xt=urn:btih:\(hash)&dn=Show.S01E02.\(quality)", quality: quality, seeds: seeds)
}

/// The three sources: the requests sent, answered by hand.
private final class FakeSources {
    var sent: [(provider: Provider, key: String, answer: ([Torrent]?) -> Void)] = []

    var fetch: EpisodeSourceResolver.Fetch {
        { [self] provider, request, completion in
            self.sent.append((provider, request.key, completion))
        }
    }

    /// Answers the latest request sent to `provider`.
    func answer(_ provider: Provider, _ torrents: [Torrent]) {
        sent.last { $0.provider == provider }?.answer(torrents)
    }

    /// The latest request sent to `provider` fails (a timeout, an HTTP error).
    func fail(_ provider: Provider) {
        sent.last { $0.provider == provider }?.answer(nil)
    }
}

final class EpisodeSourceResolverTests: CheckedTestCase {

    private func make() -> (EpisodeSourceResolver, FakeSources, ManualClock, () -> [String]) {
        let sources = FakeSources()
        let clock = ManualClock()
        var lines: [String] = []
        let resolver = EpisodeSourceResolver(fetch: sources.fetch, now: clock.now, after: clock.after,
                                             deliver: { $0() }, log: { lines.append($0) })
        return (resolver, sources, clock, { lines })
    }

    private func resolve(_ resolver: EpisodeSourceResolver, episode: Int = 2,
                         isEnough: ((EpisodeSourceResolver.Sources) -> Bool)? = nil,
                         late: ((EpisodeSourceResolver.Sources) -> Void)? = nil,
                         _ completion: @escaping (EpisodeSourceResolver.Sources) -> Void) {
        resolver.resolve(showId: "tt0944947", showTitle: "Some Show", season: 1, episode: episode,
                         isEnough: isEnough, completion: completion, late: late)
    }

    /// What a chooser needs of a partial list: something to show.
    private let aChooser: (EpisodeSourceResolver.Sources) -> Bool = { $0.count > 0 }
    /// What a release played without asking needs: every source still expected.
    private let anAutomaticPick: (EpisodeSourceResolver.Sources) -> Bool = { $0.count > 0 && $0.awaited.isEmpty }

    func testEverySourceInTime() {
        let (resolver, sources, clock, lines) = make()
        var got: EpisodeSourceResolver.Sources?
        resolve(resolver) { got = $0 }
        eq(sources.sent.map { $0.provider }, Provider.allCases, "the three sources are asked together")
        clock.advance(0.4)
        sources.answer(.torrentio, [torrent("a"), torrent("b")])
        sources.answer(.extra, [torrent("c")])
        check(got == nil, "waits for the third source while the deadline runs")
        clock.advance(0.5)
        sources.answer(.time4Popcorn, [torrent("d")])
        check(got?.isComplete == true && got?.count == 4, "answered as soon as the last source is in", "\(String(describing: got))")
        eq(lines().first, "[Start] sources: 900 ms — 4 torrent(s) (T4P 1 · Torrentio 2 · TPB/Knaben 1)", "the [Start] line")
    }

    func testTheSlowestSourceDoesNotHoldTheCaller() {
        let (resolver, sources, clock, lines) = make()
        var got: EpisodeSourceResolver.Sources?
        var late: EpisodeSourceResolver.Sources?
        resolve(resolver, late: { late = $0 }) { got = $0 }
        clock.advance(1)
        sources.answer(.torrentio, [torrent("a")])
        sources.answer(.extra, [])
        // Time4Popcorn's host is down: its client answers nothing for 10 s.
        clock.advance(1.9)
        check(got == nil, "2.9 s: still waiting")
        clock.advance(0.2)
        check(got != nil, "the deadline answers with what is in")
        eq(got?.missing, [.time4Popcorn], "…and says which source is missing")
        eq(got?.torrentio.count, 1, "the sources in time are delivered")
        eq(lines().first, "[Start] sources: 3000 ms — 1 torrent(s) (Torrentio 1 · TPB/Knaben 0), not in time: T4P",
           "the [Start] line names the source that was late")
        check(late == nil, "no late list yet")
        clock.advance(7)
        sources.answer(.time4Popcorn, [])
        check(late?.isComplete == true && late?.count == 1, "the complete list goes to `late` when the last source answers")
    }

    func testADeadSourceIsNotWaitedForAgain() {
        let (resolver, sources, clock, _) = make()
        resolve(resolver) { _ in }
        sources.answer(.torrentio, [torrent("a")])
        sources.answer(.extra, [])
        clock.advance(10)
        sources.answer(.time4Popcorn, [])   // its timeout: nothing

        // The next episode: answered as soon as the two live sources are in.
        var got: EpisodeSourceResolver.Sources?
        resolve(resolver, episode: 3) { got = $0 }
        eq(sources.sent.count, 6, "the dead source is still asked")
        clock.advance(0.3)
        sources.answer(.torrentio, [torrent("e")])
        check(got == nil, "one live source still to come")
        sources.answer(.extra, [torrent("f")])
        check(got?.count == 2 && got?.missing == [.time4Popcorn], "answered without waiting for the dead source (0.3 s, not 3 s)")

        // It comes back: in time once, it is waited for again.
        clock.advance(1)
        sources.answer(.time4Popcorn, [torrent("g")])
        var third: EpisodeSourceResolver.Sources?
        resolve(resolver, episode: 4) { third = $0 }
        sources.answer(.torrentio, [torrent("h")])
        sources.answer(.extra, [])
        check(third == nil, "a source that answered in time is waited for again")
        sources.answer(.time4Popcorn, [torrent("i")])
        check(third?.isComplete == true, "…and its torrents are in the first answer")
    }

    func testASlowButLiveSourceIsStillWaitedFor() {
        let (resolver, sources, clock, _) = make()
        resolve(resolver) { _ in }
        sources.answer(.time4Popcorn, [])
        sources.answer(.extra, [])
        clock.advance(3.5)
        sources.answer(.torrentio, [torrent("a")])   // late, but with torrents: alive
        var got: EpisodeSourceResolver.Sources?
        resolve(resolver, episode: 3) { got = $0 }
        sources.answer(.time4Popcorn, [])
        sources.answer(.extra, [])
        check(got == nil, "the slow source is waited for (it had torrents last time)")
        clock.advance(2)
        sources.answer(.torrentio, [torrent("b")])
        check(got?.isComplete == true && got?.count == 1, "…and delivered in the first answer when it makes the deadline")
    }

    func testEverySourceBenchedSparesNone() {
        let (resolver, sources, clock, _) = make()
        // The network was down: nothing answered in time, then three failures.
        resolve(resolver) { _ in }
        clock.advance(10)
        Provider.allCases.forEach { sources.fail($0) }
        var got: EpisodeSourceResolver.Sources?
        resolve(resolver, episode: 3) { got = $0 }
        check(got == nil, "not answered with nothing at once")
        // The bench says nothing of which source is back: a source that fails at once, then the
        // first list, release nobody — the two others are a moment away.
        sources.fail(.time4Popcorn)
        check(got == nil, "a source that fails at once does not answer the caller with nothing")
        clock.advance(0.5)
        sources.answer(.extra, [torrent("a")])
        check(got == nil, "nor does the first list: with every source on the bench, all are waited for")
        sources.answer(.torrentio, [torrent("b"), torrent("c")])
        check(got?.count == 3 && got?.isComplete == true, "answered once the three are in (0.5 s)", "\(String(describing: got))")
    }

    func testABenchedSourceDoesNotSpareTheWaitForAnEmptyList() {
        let (resolver, sources, clock, _) = make()
        // Torrentio missed a deadline and then failed: on the bench.
        resolve(resolver) { _ in }
        sources.answer(.time4Popcorn, [torrent("a")])
        sources.answer(.extra, [])
        clock.advance(10)
        sources.fail(.torrentio)

        // An episode the two others have nothing for: answered with nothing as soon as they are
        // in, the caller would say « No torrents found » half a second before Torrentio's list.
        var got: EpisodeSourceResolver.Sources?
        resolve(resolver, episode: 3) { got = $0 }
        sources.answer(.time4Popcorn, [])
        sources.answer(.extra, [])
        check(got == nil, "two empty lists do not answer the caller while the benched source is out")
        clock.advance(0.5)
        sources.answer(.torrentio, [torrent("b")])
        check(got?.count == 1 && got?.isComplete == true, "its list, half a second later, does")
    }

    // MARK: What a partial list is worth to the caller

    func testNothingAtTheDeadlineIsNotEnoughForAChooser() {
        let (resolver, sources, clock, lines) = make()
        var got: EpisodeSourceResolver.Sources?
        var late: EpisodeSourceResolver.Sources?
        // An old episode on a slow link: nothing is in at the deadline.
        resolve(resolver, isEnough: aChooser, late: { late = $0 }) { got = $0 }
        sources.answer(.extra, [])
        clock.advance(3.5)
        check(got == nil, "3.5 s: no « No torrents found » while two sources are still out")
        clock.advance(0.5)
        sources.answer(.torrentio, [torrent("a"), torrent("b")])
        check(got?.count == 2 && got?.missing == [.time4Popcorn], "answered as soon as there is something to show (4 s)",
              "\(String(describing: got))")
        eq(lines().first, "[Start] sources: 4000 ms — 2 torrent(s) (Torrentio 2 · TPB/Knaben 0), not in time: T4P", "the [Start] line")
        clock.advance(6)
        sources.fail(.time4Popcorn)
        check(late?.isComplete == true && late?.failed == [.time4Popcorn], "the complete list still goes to `late`")
    }

    func testNothingFoundIsSaidOnceEverySourceHasAnswered() {
        let (resolver, sources, clock, _) = make()
        var got: EpisodeSourceResolver.Sources?
        resolve(resolver, isEnough: aChooser) { got = $0 }
        sources.answer(.time4Popcorn, [])
        sources.answer(.extra, [])
        clock.advance(9)
        check(got == nil, "9 s: Torrentio has not answered, nothing is said yet")
        clock.advance(1)
        sources.fail(.torrentio)   // its own timeout
        check(got?.count == 0 && got?.isComplete == true, "every source has answered: nothing was found")
    }

    func testASourceThatNeverCallsBackHoldsNobodyPastPatience() {
        let (resolver, sources, clock, _) = make()
        var got: EpisodeSourceResolver.Sources?
        resolve(resolver, isEnough: aChooser) { got = $0 }
        sources.answer(.time4Popcorn, [])
        clock.advance(EpisodeSourceResolver.patience - 0.1)
        check(got == nil, "still waiting just before the end of the wait")
        clock.advance(0.2)
        check(got?.count == 0 && got?.missing == [.torrentio, .extra], "answered with what is in, enough or not")
    }

    func testAnAutomaticPickWaitsForTheSourcesStillExpected() {
        let (resolver, sources, clock, _) = make()
        var picked: EpisodeSourceResolver.Sources?
        var shown: EpisodeSourceResolver.Sources?
        // Two callers on one request: a release played without asking, and a chooser.
        resolve(resolver, isEnough: anAutomaticPick) { picked = $0 }
        resolve(resolver, isEnough: aChooser) { shown = $0 }
        eq(sources.sent.count, 3, "one round of requests for both")
        sources.answer(.time4Popcorn, [torrent("a", quality: "720p")])
        sources.answer(.extra, [])
        clock.advance(3.1)
        check(shown?.count == 1 && shown?.awaited == [.torrentio], "the chooser opens at the deadline on what is in")
        check(picked == nil, "the pick is not made on a list Torrentio is about to complete")
        clock.advance(0.9)
        sources.answer(.torrentio, [torrent("b", quality: "2160p")])
        check(picked?.count == 2 && picked?.isComplete == true, "made at 4 s, on the three lists")
    }

    func testAnAutomaticPickDoesNotWaitForASourceOnTheBench() {
        let (resolver, sources, clock, _) = make()
        // Time4Popcorn's host is down: on the bench after the first episode.
        resolve(resolver) { _ in }
        sources.answer(.torrentio, [torrent("a")])
        sources.answer(.extra, [])
        clock.advance(10)
        sources.fail(.time4Popcorn)

        var picked: EpisodeSourceResolver.Sources?
        resolve(resolver, episode: 3, isEnough: anAutomaticPick) { picked = $0 }
        clock.advance(0.3)
        sources.answer(.extra, [])
        check(picked == nil, "Torrentio is still expected")
        sources.answer(.torrentio, [torrent("b")])
        check(picked?.count == 1 && picked?.missing == [.time4Popcorn] && picked?.awaited == [],
              "picked at 0.3 s, without the 10 s of the dead host")
    }

    // MARK: A source that failed

    func testASourceThatFailedIsAskedAgainAtTheNextPress() {
        let (resolver, sources, clock, lines) = make()
        // Torrentio limits the rate (HTTP 429) while the page asks ahead.
        resolver.prefetch(showId: "tt0944947", showTitle: "Some Show", season: 1, episode: 2)
        sources.answer(.time4Popcorn, [torrent("a", quality: "720p")])
        sources.answer(.extra, [])
        sources.fail(.torrentio)
        check(resolver.cached(showId: "tt0944947", season: 1, episode: 2) == nil, "an answer one source failed in is not a kept answer")

        clock.advance(20)
        var got: EpisodeSourceResolver.Sources?
        resolve(resolver) { got = $0 }
        eq(sources.sent.count, 4, "the press asks again")
        eq(sources.sent.last?.provider, .torrentio, "…the source that failed, not the two that answered")
        check(got == nil, "and waits for it")
        clock.advance(0.4)
        sources.answer(.torrentio, [torrent("b", quality: "2160p")])
        check(got?.count == 2 && got?.isComplete == true && got?.failed == [], "its list is merged with the ones kept",
              "\(String(describing: got))")
        eq(lines().last, "[Start] sources: 400 ms — 2 torrent(s) (T4P 1 · Torrentio 1 · TPB/Knaben 0)", "the [Start] line")

        var again: EpisodeSourceResolver.Sources?
        resolve(resolver) { again = $0 }
        check(again?.count == 2 && sources.sent.count == 4, "now complete: kept for the next press")
    }

    func testASourceThatKeepsFailingIsAskedAtEachPressUntilTheListsAreTooOld() {
        let (resolver, sources, clock, lines) = make()
        resolve(resolver) { _ in }
        sources.answer(.time4Popcorn, [torrent("a")])
        sources.answer(.extra, [])
        sources.fail(.torrentio)
        eq(lines().first, "[Start] sources: 0 ms — 1 torrent(s) (T4P 1 · Torrentio 0 · TPB/Knaben 0), failed: Torrentio",
           "the [Start] line names the source that failed")
        for press in 1...3 {
            clock.advance(120)
            var got: EpisodeSourceResolver.Sources?
            resolve(resolver) { got = $0 }
            eq(sources.sent.count, 3 + press, "press \(press): one request, to Torrentio")
            sources.fail(.torrentio)
            check(got?.count == 1 && got?.failed == [.torrentio], "answered with the lists kept when it fails again")
        }
        // The two lists kept were asked for more than `lifetime` ago: everything is asked again.
        clock.advance(EpisodeSourceResolver.lifetime - 360 + 1)
        resolve(resolver) { _ in }
        eq(sources.sent.count, 9, "the three sources are asked once the kept lists are too old")
    }

    func testAFailureInTimeLeavesTheBenchAsItIs() {
        let (resolver, sources, clock, _) = make()
        // Time4Popcorn's host is down: its first request waits for its timeout, the next ones
        // fail at once (the client skips the host for a while).
        resolve(resolver) { _ in }
        sources.answer(.torrentio, [torrent("a")])
        sources.answer(.extra, [])
        clock.advance(10)
        sources.fail(.time4Popcorn)
        resolve(resolver, episode: 3) { _ in }
        sources.fail(.time4Popcorn)   // at once
        sources.answer(.torrentio, [torrent("b")])
        sources.answer(.extra, [])

        // Later the client asks the host again, which is still down.
        clock.advance(130)
        var got: EpisodeSourceResolver.Sources?
        resolve(resolver, episode: 4, isEnough: anAutomaticPick) { got = $0 }
        sources.answer(.torrentio, [torrent("c")])
        sources.answer(.extra, [])
        check(got?.count == 1 && got?.missing == [.time4Popcorn], "a failure in time did not take the source off the bench")
    }

    // MARK: Memory

    func testTheAnswersNothingCanUseAreDropped() {
        let (resolver, sources, clock, _) = make()
        // A session of browsing: each show page asks ahead for one episode.
        for episode in 1...40 {
            resolver.prefetch(showId: "tt0944947", showTitle: "Some Show", season: 1, episode: episode)
            Provider.allCases.forEach { sources.answer($0, [torrent("\(episode)\($0)")]) }
            clock.advance(60)
        }
        eq(resolver.entryCount, 11, "the answers of the last ten minutes are held, not the forty")
        clock.advance(EpisodeSourceResolver.lifetime)
        resolver.prefetch(showId: "tt0944947", showTitle: "Some Show", season: 2, episode: 1)
        eq(resolver.entryCount, 1, "the request in flight alone, once every answer is too old")
        // An answer without a torrent, a request nothing answered: gone at the next request.
        Provider.allCases.forEach { sources.answer($0, []) }
        resolver.prefetch(showId: "tt0944947", showTitle: "Some Show", season: 2, episode: 2)
        clock.advance(EpisodeSourceResolver.staleAfter + 1)
        resolver.prefetch(showId: "tt0944947", showTitle: "Some Show", season: 2, episode: 3)
        eq(resolver.entryCount, 1, "neither is kept")
    }

    func testAnAnswerIsKeptAndAPrefetchIsJoined() {
        let (resolver, sources, clock, lines) = make()
        // The detail page shows the episode: its sources are asked ahead.
        resolver.prefetch(showId: "tt0944947", showTitle: "Some Show", season: 1, episode: 2)
        eq(sources.sent.count, 3, "a prefetch asks the sources")
        clock.advance(1)
        // Play is pressed while they load: the request in flight is joined.
        var got: EpisodeSourceResolver.Sources?
        resolve(resolver) { got = $0 }
        eq(sources.sent.count, 3, "no second round of requests")
        Provider.allCases.forEach { sources.answer($0, [torrent("\($0)")]) }
        check(got?.count == 3, "the press gets the prefetched answer")
        eq(lines().first, "[Start] sources: 0 ms — 3 torrent(s) (T4P 1 · Torrentio 1 · TPB/Knaben 1)",
           "the press waited 0 ms: the sources were asked 1 s before it")

        // Another press 5 min later: kept.
        clock.advance(300)
        var again: EpisodeSourceResolver.Sources?
        resolve(resolver) { again = $0 }
        check(again?.count == 3 && sources.sent.count == 3, "kept for the next press")
        check(resolver.cached(showId: "tt0944947", season: 1, episode: 2)?.count == 3, "and readable without a callback")
        clock.advance(EpisodeSourceResolver.lifetime)
        resolve(resolver) { _ in }
        eq(sources.sent.count, 6, "asked again once the answer is too old")
    }

    func testAPrefetchPastItsDeadlineAnswersThePressAtOnce() {
        let (resolver, sources, clock, _) = make()
        resolver.prefetch(showId: "tt0944947", showTitle: nil, season: 1, episode: 2)
        sources.answer(.torrentio, [torrent("a")])
        clock.advance(5)   // the two others are silent
        var got: EpisodeSourceResolver.Sources?
        resolve(resolver) { got = $0 }
        check(got?.count == 1 && got?.missing.count == 2, "the deadline counts from the moment the sources were asked")
    }

    func testAnEmptyAnswerIsNotKept() {
        let (resolver, sources, _, _) = make()
        resolve(resolver) { _ in }
        Provider.allCases.forEach { sources.answer($0, []) }
        resolve(resolver) { _ in }
        eq(sources.sent.count, 6, "no torrent at all may be a failure: asked again at the next press")
    }

    func testAShowWithoutAnImdbIdHasNoExtraSource() {
        let (resolver, sources, _, _) = make()
        var got: EpisodeSourceResolver.Sources?
        resolver.resolve(showId: "kitsu-12", showTitle: "Anime", season: 1, episode: 1, completion: { got = $0 })
        check(got?.count == 0 && got?.isComplete == true && sources.sent.isEmpty, "answered empty, nothing asked")
    }

    func testMergedList() {
        var sources = EpisodeSourceResolver.Sources()
        sources.time4Popcorn = [torrent("aaaa")]
        sources.torrentio = [torrent("bbbb"), torrent("aaaa")]
        sources.extra = [torrent("cccc"), torrent("bbbb")]
        let base = [torrent("dddd", quality: "720p")]   // (the merge lists 3 releases per resolution)
        let merged = sources.merged(withBase: base, runtime: 3600)
        eq(merged.compactMap { TorrentioClient.infoHash(fromMagnet: $0.url) }.sorted(), ["aaaa", "bbbb", "cccc", "dddd"],
           "one row per info-hash: Time4Popcorn, the episode's own, Torrentio, then TPB / Knaben's novel ones")
        check(merged.allSatisfy { $0.mediaRuntime == 3600 }, "the runtime is on every candidate")
        // The same expression the play flows used before the resolver.
        let t4p = sources.time4Popcorn.withMediaRuntime(3600)
        let legacy = (base + sources.torrentio).withMediaRuntime(3600)
        let before = TorrentioClient.merge(t4p, with: legacy + ExtraTorrentSources.novel(sources.extra.withMediaRuntime(3600), beside: t4p + legacy))
        eq(merged.map { $0.url }, before.map { $0.url }, "identical to the play flows' former merge")
    }
}
