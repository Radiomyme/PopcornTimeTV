//
//  SubtitleSearchTests.swift
//  PopcornTimeTests
//
//  SubtitleSearch: the OpenSubtitles search runs alongside the stream — one request per title,
//  kept 30 min, a start that waits for it released at the deadline, late answers delivered.
//

import XCTest
import Foundation
@testable import PopcornKit

private func subtitle(_ code: String) -> Subtitle {
    Subtitle(language: code.uppercased(), link: "https://example.invalid/\(code).srt", ISO639: code, rating: 1)
}

/// The search's network side: the requests asked, answered by hand.
private final class FakeOpenSubtitles {
    var requests: [(key: String, answer: ([Subtitle], NSError?) -> Void)] = []

    var fetch: SubtitleSearch.Fetch {
        { [self] media, showId, completion in
            self.requests.append((SubtitleSearch.key(for: media, showId: showId) ?? "?", completion))
        }
    }

    func answer(_ index: Int, _ subtitles: [Subtitle], error: NSError? = nil) {
        requests[index].answer(subtitles, error)
    }
}

final class SubtitleSearchTests: CheckedTestCase {

    private let movie = Movie(yts: ["imdb_code": "tt0816692", "title": "Interstellar"])!
    private var episode: Episode {
        Episode(title: "Pilot", id: "ep1", show: Show(title: "Some Show", id: "tt0944947"), episode: 2, season: 1)
    }

    private func make() -> (SubtitleSearch, FakeOpenSubtitles, ManualClock) {
        let network = FakeOpenSubtitles()
        let clock = ManualClock()
        let search = SubtitleSearch(fetch: network.fetch, now: clock.now, after: clock.after, deliver: { $0() })
        return (search, network, clock)
    }

    func testKeys() {
        eq(SubtitleSearch.key(for: movie), "tt0816692", "a movie: its imdb id")
        eq(SubtitleSearch.key(for: episode), "tt0944947 S1E2", "an episode: the show's imdb id + season + episode")
        eq(SubtitleSearch.key(for: Episode(title: "Pilot", show: nil, episode: 2, season: 1), showId: "tt1"), "tt1 S1E2",
           "an episode without its show: the id given")
        eq(SubtitleSearch.key(for: Episode(title: "Pilot", show: Show(title: "Anime", id: "kitsu-12"), episode: 3, season: 1)),
           "q:Anime S1E3", "no imdb id: the text search's key")
    }

    func testOneRequestSharedByThePlayFlowAndThePlayers() {
        let (search, network, clock) = make()
        check(search.answer(for: movie) == nil, "nothing known before the search")
        search.prefetch(for: movie)
        search.prefetch(for: movie)
        eq(network.requests.count, 1, "Play starts one request (a second prefetch joins it)")
        check(search.answer(for: movie) == nil, "still unknown while the request runs")

        var first: [Subtitle]?, second: [Subtitle]?
        search.search(for: movie) { first = $0 }
        search.search(for: movie) { second = $0 }
        eq(network.requests.count, 1, "the players join the request in flight")
        check(first == nil && second == nil, "no completion before the answer")

        clock.advance(0.8)
        network.answer(0, [subtitle("fr"), subtitle("en")])
        eq(first?.count, 2, "first waiter answered")
        eq(second?.count, 2, "second waiter answered")
        eq(search.answer(for: movie)?.count, 2, "the answer is known from then on")

        // A player that starts later (the stream took 20 s to buffer): at once, no request.
        clock.advance(20)
        var late: [Subtitle]?
        search.search(for: movie) { late = $0 }
        eq(late?.count, 2, "a later player gets the list at once")
        eq(network.requests.count, 1, "…without a new request")
    }

    func testAnEmptyAnswerIsFinalAndNotSearchedAgain() {
        let (search, network, clock) = make()
        search.prefetch(for: episode)
        network.answer(0, [])
        eq(search.answer(for: episode), [], "found nothing: an empty list, known (the player holds nothing)")
        clock.advance(600)
        var got: [Subtitle]?
        search.search(for: episode) { got = $0 }
        eq(got, [], "asked again 10 min later: the empty answer")
        eq(network.requests.count, 1, "no second search of a title without subtitles")
    }

    func testAnswersExpire() {
        let (search, network, clock) = make()
        search.prefetch(for: movie)
        network.answer(0, [subtitle("fr")])
        clock.advance(SubtitleSearch.lifetime - 1)
        check(search.answer(for: movie) != nil, "kept just under the lifetime")
        clock.advance(2)
        check(search.answer(for: movie) == nil, "forgotten after the lifetime")
        search.prefetch(for: movie)
        eq(network.requests.count, 2, "then searched again")
    }

    func testAFailureIsKeptBrieflyThenRetried() {
        let (search, network, clock) = make()
        var got: [Subtitle]?
        search.search(for: movie) { got = $0 }
        network.answer(0, [], error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        eq(got, [], "a failed search answers an empty list")
        // The player that starts right after the failure does not wait for the same failure.
        clock.advance(5)
        eq(search.answer(for: movie), [], "the failure is known for a moment")
        search.prefetch(for: movie)
        eq(network.requests.count, 1, "no new request right after a failure")
        clock.advance(SubtitleSearch.failureLifetime)
        check(search.answer(for: movie) == nil, "…but the failure is not kept like an answer")
        search.prefetch(for: movie)
        eq(network.requests.count, 2, "a later playback tries again")
    }

    func testAStartThatWaitsIsReleasedAtTheDeadlineAndGetsTheLateAnswer() {
        let (search, network, clock) = make()
        // Play: the search starts with the stream.
        search.prefetch(for: movie)
        // The player is ready 1.5 s later and may hold its start for the list.
        clock.advance(1.5)
        var updates: [(count: Int, isFinal: Bool, at: TimeInterval)] = []
        search.search(for: movie, waitingAtMost: 4) { subtitles, isFinal in
            updates.append((subtitles.count, isFinal, clock.time))
        }
        check(updates.isEmpty, "held while the search runs")
        clock.advance(2.4)
        check(updates.isEmpty, "still held 3.9 s after Play")
        clock.advance(0.2)
        eq(updates.count, 1, "released at the deadline")
        check(updates[0].count == 0 && !updates[0].isFinal, "…with an empty, provisional list")
        eq(updates[0].at, 1004, "4 s after the search BEGAN, not after the player asked")
        // OpenSubtitles answers at last.
        clock.advance(3)
        network.answer(0, [subtitle("fr")])
        eq(updates.count, 2, "the late answer is delivered")
        check(updates[1].count == 1 && updates[1].isFinal, "…as the final list")
        clock.advance(60)
        eq(updates.count, 2, "nothing more afterwards")
    }

    func testAStartThatWaitsGetsAnAnswerInTimeOnce() {
        let (search, network, clock) = make()
        var updates: [(Int, Bool)] = []
        search.search(for: movie, waitingAtMost: 4) { updates.append(($0.count, $1)) }
        clock.advance(1)
        network.answer(0, [subtitle("fr"), subtitle("de")])
        eq(updates.count, 1, "answered in time: one update")
        check(updates[0] == (2, true), "…final")
        clock.advance(10)
        eq(updates.count, 1, "the deadline changes nothing afterwards")
    }

    func testAStartAfterTheDeadlineDoesNotWait() {
        let (search, network, clock) = make()
        search.prefetch(for: movie)
        clock.advance(9)   // a slow OpenSubtitles, a stream ready after 9 s
        var updates: [(Int, Bool)] = []
        search.search(for: movie, waitingAtMost: 4) { updates.append(($0.count, $1)) }
        eq(updates.count, 1, "the hold is already over: released at once")
        check(updates[0] == (0, false), "…provisionally")
        network.answer(0, [subtitle("fr")])
        check(updates.count == 2 && updates[1] == (1, true), "then the late list")
    }

    func testAKnownAnswerIsGivenAtOnceToAStartThatWouldWait() {
        let (search, network, _) = make()
        search.prefetch(for: movie)
        network.answer(0, [subtitle("fr")])
        var updates: [(Int, Bool)] = []
        search.search(for: movie, waitingAtMost: 4) { updates.append(($0.count, $1)) }
        check(updates.count == 1 && updates[0] == (1, true), "known: final at once, nothing held")
    }

    func testASilentRequestIsGivenUp() {
        let (search, network, clock) = make()
        var got: [Subtitle]?
        search.search(for: movie) { got = $0 }
        clock.advance(SubtitleSearch.giveUpAfter - 0.1)
        check(got == nil, "waiting until the give-up")
        clock.advance(0.2)
        eq(got, [], "given up: the waiters get an empty list")
        // Its answer still counts when it finally comes.
        network.answer(0, [subtitle("fr")])
        eq(search.answer(for: movie)?.count, 1, "the answer that came after the give-up is kept")
    }

    func testAnswersTooOldToServeAreDropped() {
        let (search, network, clock) = make()
        // An evening of episodes: one search per title played.
        for number in 1...6 {
            search.prefetch(for: Episode(title: "E\(number)", id: "ep\(number)", show: Show(title: "Some Show", id: "tt0944947"),
                                         episode: number, season: 1))
            network.answer(number - 1, [subtitle("fr")])
            clock.advance(SubtitleSearch.lifetime / 2 + 1)
        }
        eq(search.entryCount, 2, "the answers still good and the last search, not one per title played")
    }

    func testTitlesAreSearchedSeparately() {
        let (search, network, _) = make()
        search.prefetch(for: movie)
        search.prefetch(for: episode)
        eq(network.requests.map { $0.key }, ["tt0816692", "tt0944947 S1E2"], "one request per title")
        network.answer(1, [subtitle("fr")])
        check(search.answer(for: movie) == nil && search.answer(for: episode)?.count == 1, "answers do not mix")
    }
}
