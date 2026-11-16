//
//  DetailStoreTests.swift
//  PopcornTimeTests
//
//  DetailStore: a title's page content is asked once and shared — by the pages of the title,
//  by the prewarm that asked ahead — and kept a few minutes; the prewarm is bounded. And the
//  pieces under it: the merge of a movie's lists, the record that only fills what is missing.
//

import XCTest
import Foundation
@testable import PopcornKit

final class DetailStoreTests: CheckedTestCase {

    private let complete = detailLists(yts: [detailTorrent("aaaa")], torrentio: [detailTorrent("bbbb")], t4p: [], extra: [])

    private func answer(_ harness: DetailHarness, _ id: String = "tt15239678") {
        harness.sources.send(.metadata(detailRecord(id)), to: id)
        harness.sources.send(.movieSources(complete), to: id)
        harness.sources.send(.finished(nil), to: id)
    }

    // MARK: Sharing and keeping

    func testTwoPagesOfATitleShareOneLoad() {
        let harness = DetailHarness()
        let first = harness.session(detailBaseMovie())
        first.start()
        harness.clock.advance(0.3)
        harness.sources.send(.metadata(detailRecord()))
        let second = harness.session(detailBaseMovie())
        second.start()
        eq(harness.sources.ids, ["tt15239678"], "one request for the two pages")
        check(second.hasRecord, "the second page has at once what the first already received")
        check(second.joinedEarlierLoad && !first.joinedEarlierLoad, "and knows it joined a load")
        harness.sources.send(.movieSources(complete))
        harness.sources.send(.finished(nil))
        check(first.sources == .ready && second.sources == .ready, "both get the sources")
        eq(second.timings["all sources"], 0, "timed from its own opening")
    }

    func testAPageOpenedAgainIsServedAtOnce() {
        let harness = DetailHarness()
        let first = harness.session(detailBaseMovie())
        first.start()
        answer(harness)
        harness.clock.advance(120)
        let again = harness.session(detailBaseMovie())
        again.start()
        eq(harness.sources.ids.count, 1, "nothing is asked again two minutes later")
        check(again.isFinished && again.sources == .ready && again.hasRecord, "everything is there before start() returns")
        eq(again.movie?.torrents.count, 2, "with its torrents")
        check(harness.lines().contains("[Detail] tt15239678 kept from 120.0 s ago"), "logged", "\(harness.lines())")

        harness.clock.advance(DetailStore.lifetime)
        let later = harness.session(detailBaseMovie())
        later.start()
        eq(harness.sources.ids.count, 2, "past the lifetime the sources are asked again")
        check(!later.isFinished && later.sources == .searching, "and the page waits for them")
    }

    func testAnAnswerWithAFailedSourceIsNotKept() {
        let harness = DetailHarness()
        let first = harness.session(detailBaseMovie())
        first.start()
        harness.sources.send(.metadata(detailRecord()))
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa")], t4p: [], extra: [], failed: [.torrentio])))
        harness.sources.send(.finished(nil))
        check(first.sources == .ready && first.failure == nil, "the page plays what the other sources have")
        let again = harness.session(detailBaseMovie())
        again.start()
        eq(harness.sources.ids.count, 2, "but the next opening asks again: the failed source may answer")
    }

    func testALoadThatNeverEndsIsNotJoinedForever() {
        let harness = DetailHarness()
        harness.session(detailBaseMovie()).start()
        harness.clock.advance(31)
        harness.session(detailBaseMovie()).start()
        eq(harness.sources.ids.count, 2, "a load still unfinished after 30 s is asked again")
    }

    func testOnlyTheLatestTitlesAreKept() {
        let harness = DetailHarness()
        for index in 0..<(DetailStore.capacity + 3) {
            let id = "tt\(1000000 + index)"
            harness.session(detailBaseMovie(id)).start()
            answer(harness, id)
            harness.clock.advance(1)
        }
        check(!harness.store.hasDetail(for: detailBaseMovie("tt1000000")), "the oldest went")
        check(harness.store.hasDetail(for: detailBaseMovie("tt\(1000000 + DetailStore.capacity + 2)")), "the latest is kept")
    }

    func testMoviesAndShowsAreAskedByKind() {
        let harness = DetailHarness()
        harness.session(detailBaseMovie("tt0944947")).start()
        harness.session(detailShow("tt0944947")).start()
        eq(harness.sources.requests.map { $0.request.kind }, [.movie, .show], "an id asked as a movie and as a show: two loads")
        check(harness.store.detail(for: Episode(title: "An episode", id: "tt0944947-s1e1")) == nil, "an episode has no page")
        check(harness.store.detail(for: Movie(title: "No id", id: "42")) == nil, "nor a title without an IMDb id")
    }

    // MARK: Prewarm

    func testAFocusThatStaysAsksThePageAhead() {
        let harness = DetailHarness()
        harness.store.prewarm(detailBaseMovie())
        harness.clock.advance(0.39)
        check(harness.sources.ids.isEmpty, "nothing before the focus has stayed 0.4 s")
        harness.clock.advance(0.02)
        eq(harness.sources.ids, ["tt15239678"], "then the page is asked")
        answer(harness)

        harness.clock.advance(2)
        let page = harness.session(detailBaseMovie())
        page.start()
        eq(harness.sources.ids.count, 1, "the page opened after it asks nothing")
        check(page.isFinished && page.sources == .ready && page.joinedEarlierLoad, "and has everything at once")
        eq(page.timings["all sources"], 0, "0 ms after it opened")
    }

    func testAPageJoinsAPrewarmInFlight() {
        let harness = DetailHarness()
        harness.store.prewarm(detailBaseMovie())
        harness.clock.advance(0.5)
        harness.sources.send(.metadata(detailRecord()))
        harness.clock.advance(0.2)
        let page = harness.session(detailBaseMovie())
        page.start()
        check(page.hasRecord && page.sources == .searching, "the record is there, the sources still coming")
        var runs = 0
        page.press(picksAlone: true) { runs += 1 }
        harness.clock.advance(0.3)
        harness.sources.send(.movieSources(complete))
        eq(runs, 1, "a press runs when they arrive")
        eq(page.timings["all sources"], 300, "0.3 s after the page opened, 0.6 s after they were asked")
        eq(harness.sources.ids.count, 1, "one request in all")
    }

    func testAFocusThatMovesOnAsksNothing() {
        let harness = DetailHarness()
        harness.store.prewarm(detailBaseMovie("tt0000011"))
        harness.clock.advance(0.2)
        harness.store.prewarm(detailBaseMovie("tt0000012"))
        harness.clock.advance(0.2)
        harness.store.prewarm(detailBaseMovie("tt0000013"))
        harness.clock.advance(0.3)
        check(harness.sources.ids.isEmpty, "three cards crossed in 0.7 s: none is asked")
        harness.clock.advance(0.2)
        eq(harness.sources.ids, ["tt0000013"], "the one the focus stopped on is")
        harness.store.prewarm(detailBaseMovie("tt0000014"))
        harness.clock.advance(0.1)
        harness.store.prewarm(nil as Media?)
        harness.clock.advance(5)
        eq(harness.sources.ids, ["tt0000013"], "a focus that left the cards asks nothing more")
    }

    func testAPointerThatLeavesACardStopsItsPrewarmOnly() {
        let harness = DetailHarness()
        // The Mac's hover: the next card's "in" may come before this card's "out".
        harness.store.prewarm(detailBaseMovie("tt0000041"))
        harness.store.prewarm(detailBaseMovie("tt0000042"))
        harness.store.stopPrewarm(of: detailBaseMovie("tt0000041"))
        harness.clock.advance(0.5)
        eq(harness.sources.ids, ["tt0000042"], "the card the pointer is on is asked: the other card's « out » did not stop it")
        harness.store.prewarm(detailBaseMovie("tt0000043"))
        harness.store.stopPrewarm(of: detailBaseMovie("tt0000043"))
        harness.clock.advance(1)
        eq(harness.sources.ids, ["tt0000042"], "a card left before the dwell is not asked")
    }

    func testAtMostTwoPrewarmsAtATime() {
        let harness = DetailHarness()
        for id in ["tt0000021", "tt0000022", "tt0000023"] {
            harness.store.prewarm(detailBaseMovie(id))
            harness.clock.advance(0.5)
        }
        eq(harness.sources.ids, ["tt0000021", "tt0000022"], "the third waits: two are in flight")
        answer(harness, "tt0000021")
        eq(harness.sources.ids, ["tt0000021", "tt0000022", "tt0000023"], "a slot is free and its card still has the focus: asked")

        harness.store.prewarm(detailBaseMovie("tt0000024"))
        harness.clock.advance(0.5)
        harness.store.prewarm(detailBaseMovie("tt0000025"))
        harness.clock.advance(0.5)
        answer(harness, "tt0000022")
        check(!harness.sources.ids.contains("tt0000024"), "a card that waited for a slot and lost the focus is never asked")
        eq(harness.sources.ids.last, "tt0000025", "the focused one takes the slot")

        // A page opening needs no slot.
        harness.session(detailBaseMovie("tt0000026")).start()
        eq(harness.sources.ids.last, "tt0000026", "a page is asked at once, whatever the prewarms in flight")
    }

    func testAPrewarmHoldsItsSlowStepsUntilAPageReadsIt() {
        let harness = DetailHarness()
        harness.store.prewarm(detailBaseMovie("tt0000051"))
        harness.clock.advance(0.5)
        guard let gate = harness.sources.requests.last?.request.gate else { return check(false, "a prewarm's request carries a gate") }
        check(!gate.isOpen, "closed: the title searches wait for a page")
        var held: [String] = []
        gate.whenOpen { held.append("the title searched on TPB / Knaben") }
        gate.parkUntilOpen { held.append("the end of the search") }
        check(held.isEmpty && gate.isParked, "nothing of it is asked; the load is parked")

        // Parked: no longer in flight — the next card the focus rests on is asked.
        harness.store.prewarm(detailBaseMovie("tt0000052"))
        harness.clock.advance(0.5)
        harness.store.prewarm(detailBaseMovie("tt0000053"))
        harness.clock.advance(0.5)
        eq(harness.sources.ids, ["tt0000051", "tt0000052", "tt0000053"], "a parked prewarm takes no slot")

        let page = harness.session(detailBaseMovie("tt0000051"))
        page.start()
        eq(held, ["the title searched on TPB / Knaben", "the end of the search"], "the page opens it: what it held runs, in order")
        check(gate.isOpen && !gate.isParked, "open")
        eq(harness.sources.ids.count, 3, "and the page joined the prewarm: nothing asked again")
        harness.session(detailBaseMovie("tt0000054")).start()
        check(harness.sources.requests.last?.request.gate == nil, "a page's load holds nothing back")
    }

    func testNoPrewarmAfterTorrentioFailedOne() {
        let harness = DetailHarness()
        harness.store.prewarm(detailBaseMovie("tt0000031"))
        harness.clock.advance(0.5)
        harness.sources.send(.movieSources(detailLists(yts: [detailTorrent("aaaa")], t4p: [], extra: [], failed: [.torrentio])))
        harness.sources.send(.finished(nil))
        harness.store.prewarm(detailBaseMovie("tt0000032"))
        harness.clock.advance(30)
        eq(harness.sources.ids, ["tt0000031"], "Torrentio failed a prewarm: no other for a minute")
        harness.session(detailBaseMovie("tt0000032")).start()
        eq(harness.sources.ids.count, 2, "a page is still asked")
        harness.clock.advance(31)
        harness.store.prewarm(detailBaseMovie("tt0000033"))
        harness.clock.advance(0.5)
        eq(harness.sources.ids.last, "tt0000033", "prewarms resume after the minute")
    }

    func testATitleAlreadyThereIsNotPrewarmedAgain() {
        let harness = DetailHarness()
        harness.session(detailBaseMovie()).start()
        answer(harness)
        harness.store.prewarm(detailBaseMovie())
        harness.clock.advance(1)
        eq(harness.sources.ids.count, 1, "its answer is kept: nothing to ask")
        harness.store.prewarm(HomeItem(imdbId: "tt0944947", kind: .show, title: "Game of Thrones"))
        harness.clock.advance(0.5)
        check(harness.sources.requests.last?.request.kind == .show && harness.sources.ids.last == "tt0944947", "a Home card prewarms its show")
    }

    // MARK: Tampering (the DEBUG switches)

    func testDelayedAnswersKeepTheirOrder() {
        let harness = DetailHarness()
        harness.store.tampering.metadataDelay = 1
        harness.store.tampering.sourcesDelay = 3
        let session = harness.session(detailBaseMovie())
        session.start()
        answer(harness)
        check(!session.hasRecord && session.sources == .searching, "nothing yet")
        harness.clock.advance(1.01)
        check(session.hasRecord && session.sources == .searching, "the record 1 s late")
        harness.clock.advance(1.9)
        check(session.sources == .searching && !session.isFinished, "the sources not before their 3 s")
        harness.clock.advance(0.2)
        check(session.sources == .ready && session.isFinished, "then the sources, and the end after them", "\(session.sources)")

        // A record held longer than the sources: they wait for it (the order is kept).
        let ordered = DetailHarness()
        ordered.store.tampering.metadataDelay = 2
        ordered.store.tampering.sourcesDelay = 1
        let second = ordered.session(detailBaseMovie())
        var told: [DetailSession.Change] = []
        second.onChange = { told.append($0) }
        second.start()
        answer(ordered)
        ordered.clock.advance(1.5)
        check(told.isEmpty, "nothing before the record")
        ordered.clock.advance(1)
        eq(told, [.metadata, .sources, .state], "the record first, as the sources tell them")

        let failing = DetailHarness()
        failing.store.tampering.sourcesFail = true
        let page = failing.session(detailBaseMovie())
        page.start()
        answer(failing)
        failing.clock.advance(0.01)
        check(page.sources == .none && page.failure != nil && page.hasRecord, "every source failing: the record, no torrent, a retry")

        let down = DetailHarness()
        down.store.tampering.fails = true
        let dead = down.session(detailBaseMovie())
        dead.start()
        check(down.sources.ids.isEmpty && dead.failure == nil, "nothing is asked")
        down.clock.advance(0.01)
        check(dead.failure != nil && !dead.hasRecord, "the load fails")
    }

    // MARK: A movie's lists

    func testTheCompleteListIsTheOneGetMovieInfoBuilt() {
        var lists = MovieSources()
        lists.yts = [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "2160p")]
        lists.ytsKnowsTitle = true
        lists.torrentio = [detailTorrent("cccc"), detailTorrent("aaaa"), detailTorrent("dddd", quality: "2160p", seeds: 0)]
        lists.time4Popcorn = [detailTorrent("eeee", quality: "720p")]
        lists.extra = [detailTorrent("ffff"), detailTorrent("cccc")]
        lists.missing = []
        lists.runtime = 9960
        // The expression of `getMovieInfo` until 5.2.
        let base = lists.yts.withMediaRuntime(9960)
        let legacy = (lists.torrentio + lists.time4Popcorn).withMediaRuntime(9960)
        let added = ExtraTorrentSources.novel(lists.extra.withMediaRuntime(9960), beside: base + legacy)
        let before = TorrentioClient.merge(base, with: legacy + added)
        eq(lists.merged().map { $0.url }, before.map { $0.url }, "identical to the former merge")
        eq(lists.merge().novelExtra, 1, "one extra torrent no other source lists")
        check(lists.merged().allSatisfy { $0.mediaRuntime == 9960 }, "the runtime is on every candidate")
        eq(lists.summary, "YTS 2 · Torrentio 3 · T4P 1 · TPB/Knaben 2", "the log's summary")

        // A title YTS does not have: Time4Popcorn's torrents lead, all kept.
        var t4pOnly = MovieSources()
        t4pOnly.time4Popcorn = (0..<5).map { detailTorrent("t\($0)", seeds: 0) }
        t4pOnly.torrentio = [detailTorrent("cccc")]
        t4pOnly.missing = []
        let t4p = t4pOnly.time4Popcorn
        let formerly = TorrentioClient.merge(t4p, with: t4pOnly.torrentio + t4p)
        eq(t4pOnly.merged().map { $0.url }, formerly.map { $0.url }, "the movie built on Time4Popcorn's record")
        eq(t4pOnly.merged().count, 6, "its five torrents, seeded or not, and Torrentio's")

        // A page knows the runtime from its grid when no source gave it.
        var bare = MovieSources()
        bare.torrentio = [detailTorrent("cccc")]
        check(bare.merged(runtime: 7200).allSatisfy { $0.mediaRuntime == 7200 }, "the caller's runtime stands in")
        check(!bare.isComplete && !bare.isInconclusive, "a list still to come says nothing yet")
    }

    func testTheOrderOfTheAnswersDoesNotChangeTheList() {
        let yts = [detailTorrent("aaaa"), detailTorrent("bbbb", quality: "2160p")]
        let torrentio = (0..<6).map { detailTorrent("c\($0)", seeds: 10 + $0) }
        let t4p = [detailTorrent("eeee"), detailTorrent("c1")]
        let extra = [detailTorrent("ffff", seeds: 200), detailTorrent("c2")]
        let harness = DetailHarness()
        let session = harness.session(detailBaseMovie())
        session.start()
        // Time4Popcorn first, YTS last: the list on the way differs, the end does not.
        harness.sources.send(.movieSources(detailLists(t4p: t4p)))
        let early = session.movie?.torrents.map { $0.url } ?? []
        harness.sources.send(.movieSources(detailLists(torrentio: torrentio, t4p: t4p)))
        harness.sources.send(.movieSources(detailLists(yts: yts, torrentio: torrentio, t4p: t4p)))
        let all = detailLists(yts: yts, torrentio: torrentio, t4p: t4p, extra: extra)
        harness.sources.send(.movieSources(all))
        eq(early.count, 2, "Time4Popcorn's two releases first")
        eq(session.movie?.torrents.map { $0.url } ?? [], all.merged(runtime: nil).map { $0.url }, "the complete list, whatever the order")
        check((session.movie?.torrents.count ?? 0) < yts.count + torrentio.count + t4p.count + extra.count,
              "a few slots per resolution: the merge is done again at each answer, not added to")
    }

    // MARK: The record fills what is missing

    func testAShowKeepsWhatItsPageShows() {
        let base = Show(cinemeta: ["id": "tt0944947", "name": "Game of Thrones", "releaseInfo": "2011-2019", "imdbRating": "9.2",
                                   "description": "The grid's summary.", "genres": ["Action", "Drama"]])!
        let merged = base.completed(by: detailShow(title: "Game of Thrones (US)", episodes: [(1, 1), (1, 2)]))
        eq(merged.title, "Game of Thrones", "the title")
        eq(merged.summary, "The grid's summary.", "the summary")
        eq(merged.year, "2011", "the year")
        eq(merged.rating, 92, "the rating")
        eq(merged.genres, ["Action", "Drama"], "the genres")
        eq(merged.network, "HBO", "the network comes from the record")
        eq(merged.runtime, 60, "the runtime")
        eq(merged.episodes.count, 2, "and the episodes")

        let bare = Show(title: "", id: "tt0944947").completed(by: detailShow())
        eq(bare.title, "Game of Thrones", "a show known by its id takes everything from the record")
        eq(bare.summary, "The record's summary.", "its summary too")
        check(!Show(title: "Unknown", id: "tt1").hasTitleToShow && !Movie(title: " ", id: "tt1").hasTitleToShow
              && Movie(title: "Us", id: "tt1").hasTitleToShow, "what a title to show is")
    }

    func testASummaryCutByItsSourceGivesWayToAWholeOne() {
        // Cinemeta's lists cut their descriptions: "…to prevent a terrible fu...".
        let cut = "Paul Atreides unites with the Fremen while on a warpath of revenge. He endeavors to prevent a terrible fu..."
        let whole = "Paul Atreides unites with the Fremen while on a warpath of revenge. He endeavors to prevent a terrible future."
        eq(DetailMerge.summary(shown: cut, record: whole), whole, "the whole summary replaces the cut one")
        eq(DetailMerge.summary(shown: whole, record: "Another wording."), whole, "a whole summary on screen stays")
        eq(DetailMerge.summary(shown: cut, record: "Another one, cut too…"), cut, "a cut one is not replaced by another cut one")
        eq(DetailMerge.summary(shown: cut, record: "No summary available."), cut, "nor by none")
        eq(DetailMerge.summary(shown: "", record: whole), whole, "a page without a summary takes the record's")
        let card = Movie(cinemeta: ["id": "tt15239678", "name": "Dune: Part Two", "description": cut])!
        eq(card.completed(by: detailRecord()).summary, "The source's own, longer summary.", "a Home card's cut summary, on a movie")
    }
}
