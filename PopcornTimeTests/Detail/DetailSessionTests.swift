//
//  DetailSessionTests.swift
//  PopcornTimeTests
//
//  DetailSession: a title's page opens on what its caller had, its record fills in what is
//  missing, its sources arrive one by one; a press made before them is kept and runs by the
//  rules of an episode's sources; a failure keeps the page, with a retry.
//

import XCTest
import Foundation
@testable import PopcornKit

final class DetailSessionTests: CheckedTestCase {

    private typealias State = DetailSession.SourcesState

    /// The session of a movie page, started, with what it told its page.
    private func open(_ harness: DetailHarness, _ media: Media) -> (DetailSession, () -> [DetailSession.Change]) {
        let session = harness.session(media)
        var changes: [DetailSession.Change] = []
        session.onChange = { changes.append($0) }
        session.start()
        return (session, { changes })
    }

    private func hashes(_ torrents: [Torrent]?) -> [String] {
        return (torrents ?? []).compactMap { TorrentioClient.infoHash(fromMagnet: $0.url) }.sorted()
    }

    // MARK: States

    func testThePageOpensOnWhatItsCallerHad() {
        let harness = DetailHarness()
        let (session, changes) = open(harness, detailBaseMovie())
        eq(session.movie?.title, "Dune: Part Two", "the grid's title, before any answer")
        eq(session.movie?.summary, "The grid's summary.", "and its summary")
        eq(session.sources, State.searching, "the sources are being searched")
        check(!session.hasRecord && !session.isFinished && session.failure == nil, "nothing else yet")
        eq(harness.sources.ids, ["tt15239678"], "the title is asked once, at the opening")
        eq(harness.sources.requests.first?.request.title, "Dune: Part Two", "with the title the caller knows")
        eq(harness.sources.requests.first?.request.year, 2024, "and its year (the extra sources' search)")
        check(changes().isEmpty, "nothing to tell the page yet")
        check(harness.lines().first == "[Detail] tt15239678 open — movie, Dune: Part Two", "the opening is logged", "\(harness.lines())")
    }

    func testAListsOwnTorrentsArePlayableAtOnce() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailBaseMovie(torrents: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "2160p")]))
        eq(session.sources, State.partial, "a grid's movie carries YTS's torrents: something to play from the first frame")
        eq(hashes(session.movie?.torrents), ["aaaa", "bbbb"], "its own torrents")
        // Torrentio first: the grid's torrents stand in for YTS's until it answers.
        harness.sources.send(.movieSources(detailLists(torrentio: [detailTorrent("cccc")])))
        eq(hashes(session.movie?.torrents), ["aaaa", "bbbb", "cccc"], "the caller's torrents stay beside the first list")
        // YTS fails: they still stand in.
        harness.sources.send(.movieSources(detailLists(torrentio: [detailTorrent("cccc")], t4p: [], extra: [], failed: [.yts])))
        eq(hashes(session.movie?.torrents), ["aaaa", "bbbb", "cccc"], "and when YTS fails")
        eq(session.sources, State.ready, "every source answered")
        harness.sources.send(.finished(nil))
        check(session.failure == nil, "a source failed, but there is something to play: not a failure")
    }

    func testTheRecordOnlyGivesWhatThePageLacks() {
        let harness = DetailHarness()
        let (session, changes) = open(harness, detailBaseMovie())
        harness.clock.advance(0.2)
        harness.sources.send(.metadata(detailRecord()))
        eq(session.movie?.title, "Dune: Part Two", "the title on screen does not change")
        eq(session.movie?.summary, "The grid's summary.", "nor the summary")
        eq(session.movie?.year, "2024", "nor the year")
        eq(session.movie?.genres ?? [], ["Action", "Adventure"], "nor the genres")
        eq(session.movie?.runtime, 166, "the runtime comes from the record")
        eq(session.movie?.certification, "PG-13", "the certification too")
        eq(session.movie?.trailerCode, "Way9Dexny3w", "the trailer")
        eq(session.movie?.actors.map { $0.name } ?? [], ["Timothée Chalamet"], "and the cast")
        check(session.hasRecord, "the record is in")
        eq(changes(), [.metadata], "the page is told once")
        check(harness.lines().contains("[Detail] tt15239678 metadata: 200 ms"), "with its time", "\(harness.lines())")
    }

    func testATitleKnownByItsIdAloneTakesTheRecordsTitle() {
        let harness = DetailHarness()
        // What a link or a DEBUG hook opens: the id, no title.
        let (session, _) = open(harness, Movie(title: "tt15239678", id: "tt15239678"))
        check(harness.sources.requests.first?.request.title == nil, "no title to search the extra sources with")
        harness.sources.send(.metadata(detailRecord(title: "Dune: Part Two")))
        eq(session.movie?.title, "Dune: Part Two", "the record's title")
        eq(session.movie?.summary, "The source's own, longer summary.", "and its summary")
        eq(session.movie?.year, "2023", "and its year")
    }

    func testABetterRecordCompletesTheFirstWithoutReplacingIt() {
        let harness = DetailHarness()
        let (session, _) = open(harness, Movie(title: "tt15239678", id: "tt15239678"))
        // Cinemeta answers first: a title, a summary, a year, no certification.
        harness.sources.send(.metadata(detailBaseMovie()))
        eq(session.movie?.summary, "The grid's summary.", "the first record's summary shows")
        check(session.movie?.certification == "Unrated" && session.movie?.runtime == 0, "it has no certification nor runtime")
        // Then YTS, with the cast and the certification — and another summary.
        harness.sources.send(.metadata(detailRecord()))
        eq(session.movie?.summary, "The grid's summary.", "the summary on screen is not replaced by the second record's")
        eq(session.movie?.title, "Dune: Part Two", "nor the title")
        eq(session.movie?.year, "2024", "nor the year")
        eq(session.movie?.certification, "PG-13", "the second record gives what the first lacked: the certification")
        eq(session.movie?.runtime, 166, "the runtime")
        eq(session.movie?.actors.count, 1, "the cast")
    }

    func testTheSourcesArriveOneByOne() {
        let harness = DetailHarness()
        let (session, changes) = open(harness, detailBaseMovie())
        harness.clock.advance(0.3)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "2160p")])))
        eq(session.sources, State.partial, "something to play, more expected")
        eq(hashes(session.movie?.torrents), ["aaaa", "bbbb"], "YTS's torrents")
        harness.clock.advance(0.4)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "2160p")],
                                                       torrentio: [detailTorrent("cccc")])))
        eq(session.sources, State.partial, "still a source to come")
        harness.clock.advance(0.5)
        let complete = detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "2160p")],
                                   torrentio: [detailTorrent("cccc")], t4p: [], extra: [detailTorrent("dddd"), detailTorrent("cccc")])
        harness.sources.send(.movieSources(complete))
        eq(session.sources, State.ready, "every source is in")
        eq(hashes(session.movie?.torrents), ["aaaa", "bbbb", "cccc", "dddd"], "one row per info-hash")
        eq(session.movie?.torrents.map { $0.url } ?? [], complete.merged().map { $0.url }, "the list getMovieInfo builds")
        harness.sources.send(.finished(nil))
        check(session.isFinished && session.failure == nil, "finished")
        eq(changes(), [.sources, .sources, .sources, .state], "the page is told at each list, then at the end")
        let lines = harness.lines()
        check(lines.contains("[Detail] tt15239678 first source: 300 ms — YTS 2"), "the first source's line", "\(lines)")
        check(lines.contains("[Detail] tt15239678 all sources: 1200 ms — 4 torrent(s) (YTS 2 · Torrentio 1 · T4P 0 · TPB/Knaben 2)"),
              "the last one's", "\(lines)")
        eq(lines.last, "[Detail] tt15239678 Dune: Part Two: first source 300 ms · all sources 1200 ms", "the summary line")
    }

    func testNothingToPlayIsNotAFailure() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailBaseMovie())
        harness.sources.send(.metadata(detailRecord()))
        harness.sources.send(.movieSources(detailLists(yts: [], torrentio: [], t4p: [], extra: [])))
        harness.sources.send(.finished(nil))
        eq(session.sources, State.none, "every source answered: nothing")
        check(session.failure == nil, "the title has no torrent: the page says so, there is nothing to retry")
        var ran = false
        check(session.press(picksAlone: false) { ran = true }, "a press runs at once")
        check(ran, "(it tells there is nothing to play, as before)")
    }

    // MARK: A press before the sources

    func testAPressBeforeTheSourcesRunsWhenTheyAreIn() {
        let harness = DetailHarness()
        let (session, changes) = open(harness, detailBaseMovie())
        harness.clock.advance(0.2)
        var runs = 0
        check(!session.press(picksAlone: false) { runs += 1 }, "nothing to play yet: the press is kept")
        check(session.isPressPending, "and the page knows it")
        eq(changes(), [.state], "told once")
        harness.clock.advance(0.3)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "720p")])))
        eq(runs, 0, "two releases are in, but other sources are expected before the deadline: it waits for them")
        harness.clock.advance(0.5)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "720p")],
                                                       torrentio: [detailTorrent("cccc", quality: "2160p")], t4p: [], extra: [])))
        eq(runs, 1, "every source is in: the press runs, on the complete list")
        check(!session.isPressPending, "nothing pending any more")
        eq(hashes(session.movie?.torrents), ["aaaa", "bbbb", "cccc"], "the best release is in the list it chooses from")
        harness.sources.send(.finished(nil))
        harness.clock.advance(20)
        eq(runs, 1, "once")
    }

    func testAPressWhenTheSourcesAreInRunsAtOnce() {
        let harness = DetailHarness()
        let (session, changes) = open(harness, detailBaseMovie())
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa")], torrentio: [], t4p: [], extra: [])))
        let before = changes().count
        var runs = 0
        check(session.press(picksAlone: true) { runs += 1 }, "ran at once")
        eq(runs, 1, "once")
        check(!session.isPressPending && changes().count == before, "no pending state shown, even for a moment")
    }

    func testPastTheDeadlineAChooserOpensOnWhatIsIn() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailBaseMovie())
        harness.clock.advance(0.5)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "720p")])))
        var runs = 0
        session.press(picksAlone: false) { runs += 1 }
        harness.clock.advance(2.4)
        eq(runs, 0, "2.9 s after the sources were asked: still waiting for the others")
        harness.clock.advance(0.2)
        eq(runs, 1, "at the deadline (3 s), a chooser has two releases to show: it opens")
        eq(session.sources, State.partial, "the other sources are still expected")
    }

    func testAnAutomaticPickWaitsForEverySource() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailBaseMovie())
        harness.clock.advance(0.5)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "720p")])))
        var runs = 0
        session.press(picksAlone: true) { runs += 1 }
        harness.clock.advance(5)
        eq(runs, 0, "past the deadline, a release played without asking still waits: a source may bring a better one")
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "720p")],
                                                       torrentio: [detailTorrent("cccc", quality: "2160p")], t4p: [], extra: [])))
        eq(runs, 1, "it runs once the last source is in")
    }

    func testNothingHoldsAPressPastThePatience() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailBaseMovie())
        harness.clock.advance(1)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa")])))
        var runs = 0
        session.press(picksAlone: true) { runs += 1 }
        harness.clock.advance(10.9)
        eq(runs, 0, "11.9 s: a source never answered, the press still waits")
        harness.clock.advance(0.2)
        eq(runs, 1, "12 s after the sources were asked: what is in decides")
    }

    func testAMovieWithNothingToPlayWaitsPastThePatienceForTheEndOfItsSearch() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailBaseMovie())
        var runs = 0
        session.press(picksAlone: false) { runs += 1 }
        harness.clock.advance(1)
        harness.sources.send(.movieSources(detailLists(yts: [], t4p: [])))
        harness.clock.advance(12)
        eq(runs, 0, "13 s, nothing to play and Torrentio still expected: a chooser would say « No torrents found »")
        check(session.isPressPending && session.sources == .searching, "the press still waits, the page still searches")
        harness.sources.send(.movieSources(detailLists(yts: [], torrentio: [detailTorrent("aaaa")], t4p: [])))
        eq(runs, 1, "a release is in: past the patience, the press runs on it (the last source may still add to it)")
    }

    func testAMovieThatEndsWithNothingRunsThePressOnTheEmptyList() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailBaseMovie())
        var runs = 0
        session.press(picksAlone: false) { runs += 1 }
        harness.clock.advance(20)
        eq(runs, 0, "20 s, no answer at all: still waiting")
        harness.sources.send(.metadata(detailRecord()))
        harness.sources.send(.movieSources(detailLists(yts: [], torrentio: [], t4p: [], extra: [])))
        eq(runs, 1, "every source answered with nothing: now « No torrents found » is the truth")
        eq(session.sources, State.none, "and the page says so")
    }

    func testThePatienceCountsFromThePageNotFromAPrewarm() {
        let harness = DetailHarness()
        harness.store.prewarm(detailBaseMovie())
        harness.clock.advance(0.5)
        eq(harness.sources.ids.count, 1, "the card kept the focus: its page is asked ahead")
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa")])))
        harness.clock.advance(12)
        let (session, _) = open(harness, detailBaseMovie())
        check(session.joinedEarlierLoad, "the page joins the prewarm, asked 12 s before")
        var runs = 0
        session.press(picksAlone: true) { runs += 1 }
        eq(runs, 0, "a release played without asking still waits for the other sources: the user has not waited yet")
        harness.clock.advance(11.9)
        eq(runs, 0, "11.9 s after the page opened")
        harness.clock.advance(0.2)
        eq(runs, 1, "12 s after the page opened: what is in decides")
    }

    func testALonePressIsKept() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailBaseMovie())
        var first = 0, second = 0
        session.press(picksAlone: false) { first += 1 }
        session.press(picksAlone: false) { second += 1 }
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa")], torrentio: [], t4p: [], extra: [])))
        check(first == 0 && second == 1, "a second press replaces the first: one thing starts", "\(first) \(second)")
    }

    func testCancelDropsThePress() {
        let harness = DetailHarness()
        let (session, changes) = open(harness, detailBaseMovie())
        var runs = 0
        session.press(picksAlone: false) { runs += 1 }
        session.cancelPress()
        check(!session.isPressPending, "no longer pending")
        eq(changes(), [.state, .state], "the page is told of the press, then of its end")
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa")], torrentio: [], t4p: [], extra: [])))
        harness.sources.send(.finished(nil))
        harness.clock.advance(20)
        eq(runs, 0, "nothing runs: the sources arrive on a page whose press was cancelled")
        eq(session.sources, State.ready, "which still fills in")
        check(session.press(picksAlone: false) { runs += 1 } && runs == 1, "and a new press runs at once")
    }

    /// iOS: a release tapped in « Choose Quality » while an automatic press
    /// waits starts a stream, and the page drops the press then (its
    /// `requestPlay`): neither the last source nor the patience may start a
    /// second stream over the one chosen.
    func testAReleaseChosenWhileAPressWaitsDropsThePress() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailBaseMovie())
        harness.clock.advance(0.5)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "720p")])))
        var automatic = 0
        session.press(picksAlone: true) { automatic += 1 }
        check(session.isPressPending, "an automatic pick waits for the other sources")
        // The user taps « bbbb » in the list: the page starts it and drops the press.
        session.cancelPress()
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "720p")],
                                                       torrentio: [detailTorrent("cccc", quality: "2160p")], t4p: [], extra: [])))
        harness.clock.advance(20)
        eq(automatic, 0, "the last source and the patience start nothing over the release the user chose")
    }

    /// The press's own action reaches the same `requestPlay`: its cancel finds
    /// nothing pending and changes nothing.
    func testACancelFromThePressesOwnActionChangesNothing() {
        let harness = DetailHarness()
        let (session, changes) = open(harness, detailBaseMovie())
        var runs = 0
        var told = (before: -1, after: -1)
        session.press(picksAlone: false) {
            runs += 1
            told.before = changes().count
            session.cancelPress()
            told.after = changes().count
            check(!session.isPressPending, "nothing pending inside the action")
        }
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa")], torrentio: [], t4p: [], extra: [])))
        eq(runs, 1, "the press ran")
        eq(told.after, told.before, "the cancel inside the action told the page nothing")
        harness.clock.advance(20)
        eq(runs, 1, "once")
        check(session.press(picksAlone: false) { runs += 1 } && runs == 2, "a later press runs at once")
    }

    // MARK: A late source

    func testALateSourceCompletesThePage() {
        let harness = DetailHarness()
        let (session, changes) = open(harness, detailBaseMovie())
        harness.clock.advance(0.4)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "720p")],
                                                       torrentio: [detailTorrent("cccc", quality: "2160p")])))
        var runs = 0
        session.press(picksAlone: false) { runs += 1 }
        harness.clock.advance(2.7)
        eq(runs, 1, "the chooser opened at the deadline, without Time4Popcorn")
        let told = changes().count
        // Time4Popcorn answers 6 s later, then the extra sources.
        harness.clock.advance(6)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "720p")],
                                                       torrentio: [detailTorrent("cccc", quality: "2160p")],
                                                       t4p: [detailTorrent("dddd")], extra: [detailTorrent("eeee")])))
        harness.sources.send(.finished(nil))
        eq(runs, 1, "the late source starts nothing")
        eq(session.sources, State.ready, "the page's sources are complete")
        eq(hashes(session.movie?.torrents), ["aaaa", "bbbb", "cccc", "dddd", "eeee"], "with the late one's releases")
        check(changes().count > told && changes().dropFirst(told).contains(.sources), "and the page was told")
        check(harness.lines().contains { $0.hasPrefix("[Detail] tt15239678 all sources: 9100 ms") }, "logged with its time", "\(harness.lines())")
    }

    // MARK: Failures

    func testAFailureKeepsThePageAndRetryAsksAgain() {
        let harness = DetailHarness()
        let (session, changes) = open(harness, detailBaseMovie())
        var runs = 0
        session.press(picksAlone: false) { runs += 1 }
        harness.clock.advance(1.5)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                              userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        harness.sources.send(.finished(offline))
        eq(session.failure?.localizedDescription, "The Internet connection appears to be offline.", "the reason")
        eq(session.movie?.title, "Dune: Part Two", "the page keeps what it showed")
        eq(session.sources, State.none, "nothing to play")
        check(!session.isPressPending && runs == 0, "the press is dropped: nothing will start behind the error")
        check(!session.press(picksAlone: false) { runs += 1 } && runs == 0, "and Play does nothing while it shows")
        check(changes().last == [.sources, .state], "the page is told", "\(changes())")
        check(harness.lines().contains { $0.hasPrefix("[Detail] tt15239678 failed after 1500 ms") }, "logged", "\(harness.lines())")

        session.retry()
        check(session.failure == nil && !session.isFinished, "Retry: the error goes")
        eq(session.sources, State.searching, "the sources are searched again")
        eq(harness.sources.ids, ["tt15239678", "tt15239678"], "by a new request")
        harness.sources.send(.metadata(detailRecord()))
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa")], torrentio: [], t4p: [], extra: [])))
        harness.sources.send(.finished(nil))
        check(session.failure == nil && session.sources == .ready && session.hasRecord, "and the page loads")
        eq(runs, 0, "the press of before the failure does not come back")
    }

    func testSourcesThatCouldNotBeReachedAreAFailure() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailBaseMovie())
        harness.sources.send(.metadata(detailRecord()))
        harness.sources.send(.movieSources(detailLists(yts: [], extra: [], failed: [.torrentio, .time4Popcorn])))
        harness.sources.send(.finished(nil))
        eq(session.sources, State.none, "nothing to play")
        check(session.failure != nil, "and sources failed: nothing says the title has no torrent — the page offers to retry")
        check(session.hasRecord && session.movie?.runtime == 166, "the page keeps its record meanwhile")
    }

    func testATitleNoSourceKnows() {
        let harness = DetailHarness()
        let (session, _) = open(harness, Movie(title: "tt0000001", id: "tt0000001"))
        harness.sources.send(.movieSources(detailLists(torrentio: [], t4p: [])))
        harness.sources.send(.finished(nil))
        check(session.failure != nil, "no record, nothing to play: a failure the page shows", "\(String(describing: session.failure))")
    }

    // MARK: Shows

    func testAShowGetsItsRecordThenItsGuideThenItsTorrents() {
        let harness = DetailHarness()
        let base = Show(cinemeta: ["id": "tt0944947", "name": "Game of Thrones", "releaseInfo": "2011-2019", "description": "The grid's summary."])!
        let (session, changes) = open(harness, base)
        eq(session.sources, State.searching, "nothing to play before the guide")
        check(harness.sources.requests.first?.request.kind == .show, "asked as a show")

        harness.clock.advance(0.1)
        harness.sources.send(.metadata(detailShow()))
        eq(session.show?.network, "HBO", "the record's network")
        eq(session.show?.summary, "The grid's summary.", "the summary on screen stays")
        check(!session.hasGuide && session.sources == .searching, "no episode yet")

        harness.clock.advance(0.3)
        harness.sources.send(.metadata(detailShow(episodes: [(1, 1), (1, 2), (2, 1)])))
        check(session.hasGuide, "the guide is in")
        eq(session.show?.seasonNumbers ?? [], [1, 2], "the seasons")
        eq(session.sources, State.partial, "Play has an episode to start; EZTV's torrents are still expected")
        eq(changes().last, [.metadata, .sources], "the page is told of both")

        harness.clock.advance(0.6)
        harness.sources.send(.showSources(detailShow(episodes: [(1, 1), (1, 2), (2, 1), (2, 2)], torrents: true)))
        harness.sources.send(.finished(nil))
        eq(session.sources, State.ready, "complete")
        eq(session.show?.episodes.count, 4, "with the episode only EZTV lists")
        check(session.show?.episodes.allSatisfy { !$0.torrents.isEmpty } == true, "and the torrents on the episodes")
        check(session.failure == nil && session.isFinished, "finished")
        let lines = harness.lines()
        check(lines.contains("[Detail] tt0944947 metadata: 100 ms"), "metadata line", "\(lines)")
        check(lines.contains("[Detail] tt0944947 guide: 400 ms — 3 episode(s)"), "guide line", "\(lines)")
        check(lines.contains("[Detail] tt0944947 all sources: 1000 ms — 4 of 4 episode(s) with EZTV torrents"), "sources line", "\(lines)")
    }

    func testAPressOnAShowWaitsForEZTVUntilTheDeadline() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailShow())
        var runs = 0
        session.press(picksAlone: false) { runs += 1 }
        harness.clock.advance(0.5)
        harness.sources.send(.metadata(detailShow(episodes: [(1, 1)])))
        eq(runs, 0, "the guide is in, EZTV's torrents are expected: the press waits (they are part of the episode's choice)")
        harness.clock.advance(2.6)
        eq(runs, 1, "at the deadline it runs without them: the episode's own sources are asked at the press")

        let other = DetailHarness()
        let (second, _) = open(other, detailShow())
        var ran = 0
        second.press(picksAlone: true) { ran += 1 }
        other.sources.send(.metadata(detailShow(episodes: [(1, 1)])))
        other.sources.send(.showSources(detailShow(episodes: [(1, 1)], torrents: true)))
        eq(ran, 1, "and as soon as EZTV has answered")
    }

    func testAShowWithoutEpisodesIsAFailure() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailShow())
        harness.sources.send(.metadata(detailShow()))
        harness.sources.send(.showSources(detailShow()))
        harness.sources.send(.finished(nil))
        eq(session.failure?.code, -243, "the « no seasons » error of 5.2, on the page")
        let none = DetailHarness()
        let (unknown, _) = open(none, Show(title: "tt0000002", id: "tt0000002"))
        none.sources.send(.finished(nil))
        check(unknown.failure != nil && unknown.failure?.code != -243, "a show no source knows: the general failure")
    }

    // MARK: Timing

    func testTheStepsAreTimedFromTheOpening() {
        let harness = DetailHarness()
        let (session, _) = open(harness, detailBaseMovie())
        harness.clock.advance(0.04)
        session.noteFirstPaint()
        session.noteFirstPaint()
        harness.clock.advance(0.16)
        harness.sources.send(.metadata(detailRecord()))
        harness.clock.advance(0.2)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa")])))
        harness.clock.advance(0.8)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa")], torrentio: [], t4p: [], extra: [])))
        harness.sources.send(.finished(nil))
        eq(session.timings, ["first paint": 40, "metadata": 200, "first source": 400, "all sources": 1200], "each step once, in ms")
        eq(harness.lines().last,
           "[Detail] tt15239678 Dune: Part Two: first paint 40 ms · metadata 200 ms · first source 400 ms · all sources 1200 ms",
           "the summary line")
    }
}
