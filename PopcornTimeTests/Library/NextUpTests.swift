//
//  NextUpTests.swift
//  PopcornTimeTests
//
//  The single "next episode" rule (PopcornKit, NextUpRule): what Play starts on a show page
//  and which episode a show's Continue Watching card names. Pure: guide, watched marks,
//  records and the clock are arguments.
//

import Foundation
import XCTest
@testable import PopcornKit

/// Helpers shared by the library tests.
enum LibraryFixtures {

    /// "2026-11-14T12:00:00Z".
    static func date(_ iso: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: iso) else { fatalError("bad test date \(iso)") }
        return date
    }

    static func number(_ season: Int, _ episode: Int) -> EpisodeNumber {
        return EpisodeNumber(season: season, episode: episode)
    }

    static func episode(_ season: Int, _ episode: Int, aired: String? = nil, title: String? = nil, hasSource: Bool = false) -> GuideEpisode {
        return GuideEpisode(season: season, episode: episode, title: title, aired: aired.map(date), hasSource: hasSource)
    }

    static func record(_ season: Int, _ episode: Int, _ progress: Float, at iso: String? = nil, position: TimeInterval? = nil) -> EpisodeRecord {
        return EpisodeRecord(number: number(season, episode), progress: progress, position: position,
                             updatedAt: iso.map(date) ?? .distantPast)
    }

    /// A clock the tests move.
    final class Clock {
        var now: Date
        init(_ iso: String) { now = LibraryFixtures.date(iso) }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }
}

final class NextUpTests: CheckedTestCase {

    private typealias F = LibraryFixtures
    private let now = LibraryFixtures.date("2026-11-14T12:00:00Z")

    /// A special, a first season of three, a second season whose second episode airs tomorrow.
    private var guide: [GuideEpisode] {
        return [F.episode(0, 1, aired: "2019-12-24T20:00:00Z"),
                F.episode(1, 1, aired: "2020-01-05T20:00:00Z"), F.episode(1, 2, aired: "2020-01-12T20:00:00Z"),
                F.episode(1, 3, aired: "2020-01-19T20:00:00Z"),
                F.episode(2, 1, aired: "2026-11-01T20:00:00Z"), F.episode(2, 2, aired: "2026-11-15T20:00:00Z")]
    }

    private func position(_ guide: [GuideEpisode], watched: [EpisodeNumber] = [], _ records: [EpisodeRecord] = []) -> ShowWatchPosition {
        return NextUpRule.position(guide: guide, watched: Set(watched), records: records, now: now)
    }

    private func next(_ guide: [GuideEpisode], watched: [EpisodeNumber] = [], _ records: [EpisodeRecord] = []) -> NextUp? {
        return NextUpRule.nextUp(guide: guide, watched: Set(watched), records: records, now: now)
    }

    func testNothingPlayedStartsAtTheFirstRegularEpisode() {
        eq(next(guide), NextUp(number: F.number(1, 1), reason: .start), "no history: S1E1, not the special")
        eq(next(guide.shuffled()), NextUp(number: F.number(1, 1), reason: .start), "the guide's order does not matter")
        eq(next(guide + guide), NextUp(number: F.number(1, 1), reason: .start), "an episode listed twice counts once")
        check(next([]) == nil, "no guide, no history: nothing")
    }

    func testSpecialsAreNeverTheTarget() {
        // A special in progress, played last: the show still continues from its regular episodes.
        let records = [F.record(1, 1, 0.9, at: "2026-11-10T20:00:00Z"), F.record(0, 1, 0.5, at: "2026-11-12T20:00:00Z")]
        eq(next(guide, records), NextUp(number: F.number(1, 2), reason: .next), "a special in progress is not where the show is")
        eq(next(guide, watched: [F.number(0, 1)]), NextUp(number: F.number(1, 1), reason: .start), "a watched special is no history")
        // A guide of specials only (a show EZTV files under season 0): they are the show.
        let specials = [F.episode(0, 1), F.episode(0, 2)]
        eq(next(specials), NextUp(number: F.number(0, 1), reason: .start), "only season 0: its first episode")
        eq(next(specials, [F.record(0, 1, 0.95, at: "2026-11-10T20:00:00Z")]), NextUp(number: F.number(0, 2), reason: .next),
           "only season 0: it continues there")
    }

    func testResumeAndWatchedThreshold() {
        eq(next(guide, [F.record(1, 1, 0.5, at: "2026-11-10T20:00:00Z")]), NextUp(number: F.number(1, 1), reason: .resume, progress: 0.5),
           "half watched: resume")
        eq(next(guide, [F.record(1, 1, 0.79, at: "2026-11-10T20:00:00Z")]), NextUp(number: F.number(1, 1), reason: .resume, progress: 0.79),
           "0.79 is not watched: resume")
        eq(next(guide, [F.record(1, 1, 0.80, at: "2026-11-10T20:00:00Z")]), NextUp(number: F.number(1, 2), reason: .next),
           "0.80 is watched: the next episode")
        // The watched mark alone (marked on the page, no progress).
        eq(next(guide, watched: [F.number(1, 1)], [F.record(1, 1, 0, at: "2026-11-10T20:00:00Z")]),
           NextUp(number: F.number(1, 2), reason: .next), "marked watched: the next episode")
    }

    func testAnEpisodeOnlyOpenedDoesNotMoveTheShow() {
        // 5.2 took the highest episode touched: opening S2E1 for ten seconds made Play "S2 · E1".
        let finished = F.record(1, 2, 0.95, at: "2026-11-10T20:00:00Z")
        eq(next(guide, [finished, F.record(2, 1, 0.01, at: "2026-11-12T20:00:00Z", position: 10)]),
           NextUp(number: F.number(1, 3), reason: .next), "10 s of S2E1: still S1E3")
        eq(next(guide, [finished, F.record(2, 1, 0.01, at: "2026-11-12T20:00:00Z", position: 61)]),
           NextUp(number: F.number(2, 1), reason: .resume, progress: 0.01), "61 s played counts, whatever the fraction")
        eq(next(guide, [finished, F.record(2, 1, 0.02, at: "2026-11-12T20:00:00Z")]),
           NextUp(number: F.number(2, 1), reason: .resume, progress: 0.02), "2 % counts")
        eq(next(guide, [F.record(1, 1, 0.01, at: "2026-11-12T20:00:00Z", position: 5)]), NextUp(number: F.number(1, 1), reason: .start),
           "only opened, nothing else: the show is not begun")
    }

    func testTheLastEpisodePlayedCountsNotTheFurthest() {
        // S2E1 finished, then the user went back to S1E2.
        let records = [F.record(2, 1, 0.95, at: "2026-11-10T20:00:00Z"), F.record(1, 2, 0.4, at: "2026-11-12T20:00:00Z")]
        eq(next(guide, records), NextUp(number: F.number(1, 2), reason: .resume, progress: 0.4), "the episode played last is resumed")
    }

    func testGapsInTheNumbering() {
        let holes = [F.episode(1, 1), F.episode(1, 2), F.episode(1, 4), F.episode(3, 1)]
        eq(next(holes, [F.record(1, 2, 1, at: "2026-11-10T20:00:00Z")]), NextUp(number: F.number(1, 4), reason: .next),
           "no S1E3 in the guide: S1E4 (5.2 looked for episode + 1 and jumped to the next season)")
        eq(next(holes, [F.record(1, 4, 1, at: "2026-11-10T20:00:00Z")]), NextUp(number: F.number(3, 1), reason: .next),
           "no season 2 in the guide: S3E1 (5.2 found nothing and fell back to S1E1)")
    }

    func testAnEpisodeNotAiredIsNeverTheTarget() {
        let waiting = position(guide, [F.record(2, 1, 0.9, at: "2026-11-10T20:00:00Z")])
        check(waiting.nextUp == nil, "S2E2 airs tomorrow: nothing to play")
        eq(waiting.upcoming?.number, F.number(2, 2), "…and it is the episode awaited")
        eq(waiting.lastPlayed, F.number(2, 1), "the position comes from S2E1")
        // A torrent already listed makes it playable whatever the date says.
        var early = guide
        early[5] = F.episode(2, 2, aired: "2026-11-15T20:00:00Z", hasSource: true)
        eq(next(early, [F.record(2, 1, 0.9, at: "2026-11-10T20:00:00Z")]), NextUp(number: F.number(2, 2), reason: .next),
           "a source is listed: playable")
        // An unknown air date counts as aired (the detail page's rule).
        eq(next([F.episode(1, 1), F.episode(1, 2)], [F.record(1, 1, 1, at: "2026-11-10T20:00:00Z")]),
           NextUp(number: F.number(1, 2), reason: .next), "no date: aired")
        // A show whose first episode is announced: no Play.
        let announced = position([F.episode(1, 1, aired: "2026-12-01T20:00:00Z")])
        check(announced.nextUp == nil && announced.upcoming?.number == F.number(1, 1), "first episode not aired: nothing to play")
        // The day after, S2E2 has aired.
        let later = NextUpRule.nextUp(guide: guide, watched: [], records: [F.record(2, 1, 0.9, at: "2026-11-10T20:00:00Z")],
                                      now: F.date("2026-11-15T20:00:01Z"))
        eq(later, NextUp(number: F.number(2, 2), reason: .next), "one second after its air date: the next episode")
    }

    func testAShowEntirelyWatched() {
        let aired = Array(guide.dropLast())   // S2E2 not announced
        let all = aired.map { $0.number }
        let done = position(aired, watched: all, [F.record(2, 1, 1, at: "2026-11-10T20:00:00Z")])
        eq(done.nextUp, NextUp(number: F.number(1, 1), reason: .start), "everything watched: Play starts over (no card: .start)")
        // Watching the whole show again: finishing S1E1 goes on with S1E2, watched or not.
        let again = next(aired, watched: all, [F.record(2, 1, 1, at: "2026-11-01T20:00:00Z"), F.record(1, 1, 1, at: "2026-11-12T20:00:00Z")])
        eq(again, NextUp(number: F.number(1, 2), reason: .next), "a re-watch continues with the following episode")
        // Going back to one old episode in the middle of a show: on with the first one not watched.
        let middle = next(guide, watched: [F.number(1, 1), F.number(1, 2), F.number(1, 3)], [F.record(1, 1, 1, at: "2026-11-12T20:00:00Z")])
        eq(middle, NextUp(number: F.number(2, 1), reason: .next), "an old episode seen again: the first one not watched after it")
    }

    func testUndatedHistoryFallsBackToTheFurthestEpisode() {
        // Watched marks and progress migrated from 5.2 have no dates.
        eq(next(guide, watched: [F.number(1, 1), F.number(1, 2)]), NextUp(number: F.number(1, 3), reason: .next),
           "watched marks alone: after the furthest one")
        eq(next(guide, watched: [F.number(1, 1), F.number(1, 2)], [F.record(1, 3, 0.3)]),
           NextUp(number: F.number(1, 3), reason: .resume, progress: 0.3), "the furthest episode touched is in progress: resume")
        // Any dated activity is more recent than the undated history.
        eq(next(guide, watched: [F.number(1, 1), F.number(2, 1)], [F.record(1, 2, 0.5, at: "2026-11-12T20:00:00Z")]),
           NextUp(number: F.number(1, 2), reason: .resume, progress: 0.5), "a dated record wins over undated marks")
    }

    func testTheNextEpisodeKeepsItsSavedProgress() {
        let records = [F.record(1, 1, 1, at: "2026-11-12T20:00:00Z"), F.record(1, 2, 0.4, at: "2026-11-01T20:00:00Z")]
        eq(next(guide, records), NextUp(number: F.number(1, 2), reason: .next, progress: 0.4), "S1E2 was started earlier: its progress comes along")
    }

    func testARecordOutsideTheGuideStillResumes() {
        // The row has no guide for a show (cache purged): the entry itself is enough to resume.
        eq(next([], [F.record(3, 4, 0.3, at: "2026-11-12T20:00:00Z")]), NextUp(number: F.number(3, 4), reason: .resume, progress: 0.3),
           "no guide: resume from the record")
        check(next([], [F.record(3, 4, 1, at: "2026-11-12T20:00:00Z")])?.reason == .start,
              "no guide, the only episode known is finished: nothing to continue with (.start, no card)")
    }

    /// `Show.watchPosition`: the same rule over the app's models and a library.
    func testShowWatchPositionOverTheModels() {
        let clock = F.Clock("2026-11-14T12:00:00Z")
        let library = Library(storage: MemoryLibraryStorage(), guideDirectory: nil, remote: .offline, now: { clock.now })
        var show = Show(title: "Test Show", id: "tt7654321")
        show.episodes = guide.map { item in
            Episode(title: "Episode \(item.episode)", id: LibraryID.episodeID(showID: show.id, item.number), show: show,
                    episode: item.episode, season: item.season, firstAirDate: item.aired ?? .distantPast)
        }
        eq(show.watchPosition(now: clock.now, library: library).nextUp?.episode.id, "tt7654321-s1e1", "nothing played: S1E1")
        check(show.watchPosition(now: clock.now, library: library).nextUp?.reason == .start, "…as a start")
        check(show.watchPosition(now: clock.now, library: library).current == nil, "…and no episode the history leads to")

        library.setProgress(0.4, id: "tt7654321-s1e2", list: .episodes)
        let resume = show.watchPosition(now: clock.now, library: library)
        eq(resume.nextUp?.episode.id, "tt7654321-s1e2", "S1E2 in progress: resume it")
        eq(resume.current?.id, "tt7654321-s1e2", "…the episode the page opens on")

        clock.advance(3600)
        library.setProgress(0.85, id: "tt7654321-s2e1", list: .episodes)
        let waiting = show.watchPosition(now: clock.now, library: library)
        check(waiting.nextUp == nil, "S2E1 finished, S2E2 airs tomorrow: no Play")
        eq(waiting.upcoming?.id, "tt7654321-s2e2", "the episode awaited")
        eq(waiting.current?.id, "tt7654321-s2e2", "the page opens on season 2, not back on season 1")
        check(library.isWatched("tt7654321-s2e1"), "0.85 marked it watched")
    }
}
