//
//  ProfileTasteTests.swift
//  PopcornTimeTests
//
//  A profile's taste (PopcornKit, ProfileTaste): what each event is worth, counted once; the
//  decay of old events; titles given up on; the learnt audio / subtitle / quality choices; two
//  profiles kept apart; a reset; and the Home's « For You » shelf ranked by it. No UserDefaults,
//  no network, no real clock.
//

import Foundation
import XCTest
@testable import PopcornKit

final class ProfileTasteTests: CheckedTestCase {

    private typealias F = LibraryFixtures
    private let day: TimeInterval = 86_400

    private func taste(_ storage: LibraryStorage = MemoryLibraryStorage(), clock: F.Clock) -> ProfileTaste {
        return ProfileTaste(storage: storage, center: NotificationCenter(), now: { clock.now })
    }

    private let interstellar = TasteTitle(imdbID: "tt0816692", kind: .movie, genres: ["Adventure", "Drama", "Sci-Fi"], year: 2014,
                                          people: ["Christopher Nolan", "Matthew McConaughey"])
    private let arrival = TasteTitle(imdbID: "tt2543164", kind: .movie, genres: ["Science Fiction", "Drama"], year: 2016,
                                     people: ["Denis Villeneuve", "Amy Adams"])
    private let notebook = TasteTitle(imdbID: "tt0332280", kind: .movie, genres: ["Romance", "Drama"], year: 2004)
    private let breakingBad = TasteTitle(imdbID: "tt0903747", kind: .show, genres: ["Crime", "Drama", "Thriller"], year: 2008)

    private func card(_ id: String, _ genres: [String], kind: HomeItem.Kind = .movie, year: Int = 2015, rating: Double = 7) -> HomeItem {
        return HomeItem(imdbId: id, kind: kind, title: id, year: year, rating: rating, genres: genres)
    }

    // MARK: - Events

    func testAFinishedMovieOutweighsAStartedOneAndCountsOnce() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let taste = taste(clock: clock)
        check(taste.isEmpty, "a new profile knows nothing")
        eq(taste.snapshot().isConfident, false, "nothing to rank with")

        taste.notePlayback(of: interstellar, progress: 0.1, isFinished: false)
        let started = taste.snapshot().signal
        eq(round(started * 100), 30, "a started movie is worth 0.3")
        for progress: Float in [0.2, 0.4, 0.6] { taste.notePlayback(of: interstellar, progress: progress, isFinished: false) }
        eq(round(taste.snapshot().signal * 100), 30, "saving the position again adds nothing")
        taste.notePlayback(of: interstellar, progress: 0.9, isFinished: true)
        eq(round(taste.snapshot().signal * 100), 100, "finished: the difference to 1.0 is added, not 1.0 again")
        taste.notePlayback(of: interstellar, progress: 0.95, isFinished: true)
        eq(round(taste.snapshot().signal * 100), 100, "finished twice is finished once")

        let genres = taste.snapshot().genres
        eq(genres["Sci-Fi"], 1, "Sci-Fi under Cinemeta's spelling, the top genre")
        eq(genres["Drama"], 1, "every genre of the title alike")
        check(taste.snapshot().excluded.contains(interstellar.imdbID), "a movie played is not offered again")
        let people = taste.topAffinities()[.person]?.map(\.value) ?? []
        check(people.contains("Christopher Nolan"), "the director is learnt", "\(people)")
    }

    func testMarkedUnwatchedTakesItsWorthBack() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let taste = taste(clock: clock)
        taste.noteWatched(true, of: arrival)
        check((taste.snapshot().genres["Sci-Fi"] ?? 0) > 0, "marked watched: liked")
        taste.noteWatched(false, of: arrival)
        check(taste.topAffinities().isEmpty, "unmarked: nothing left", "\(taste.topAffinities())")
    }

    func testAShowCountsEachFinishedEpisodeOnceUpToACeiling() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let taste = taste(clock: clock)
        let episode = { (n: Int) in LibraryID.episodeID(showID: self.breakingBad.imdbID, EpisodeNumber(season: 1, episode: n)) }
        taste.notePlayback(of: breakingBad, progress: 0.5, isFinished: false, episodeID: episode(1))
        eq(round(taste.snapshot().signal * 100), 30, "an episode begun: the show started")
        taste.notePlayback(of: breakingBad, progress: 0.9, isFinished: true, episodeID: episode(1))
        taste.notePlayback(of: breakingBad, progress: 0.95, isFinished: true, episodeID: episode(1))
        eq(round(taste.snapshot().signal * 100), 50, "one episode finished (twice): 0.3 + 0.2")
        for n in 2...10 { taste.notePlayback(of: breakingBad, progress: 1, isFinished: true, episodeID: episode(n)) }
        eq(round(taste.snapshot().signal * 100), 140, "ten episodes: the ceiling, 1.4")
        eq(taste.snapshot().kinds["show"], 1, "the profile watches shows")
    }

    func testTheListCountsAndLeavingItUnwatchedCountsAgainst() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let taste = taste(clock: clock)
        taste.noteWatchlist(true, of: notebook)
        check((taste.snapshot().genres["Romance"] ?? 0) > 0, "listed: liked a little")
        check(taste.snapshot().excluded.contains(notebook.imdbID), "a listed title is not offered (it has its shelf)")
        taste.noteWatchlist(false, of: notebook)
        check((taste.snapshot().genres["Romance"] ?? 0) < 0, "taken out unwatched: disliked a little")
        check(!taste.snapshot().excluded.contains(notebook.imdbID), "and it may be offered again")
    }

    // MARK: - Time

    func testOldEventsWeighLessThanRecentOnes() {
        let clock = F.Clock("2026-01-01T12:00:00Z")
        let taste = taste(clock: clock)
        taste.notePlayback(of: notebook, progress: 1, isFinished: true)
        clock.advance(120 * day)
        let decayed = taste.snapshot().signal
        eq(round(decayed * 100), 25, "two half-lives later a finished movie weighs a quarter")
        taste.notePlayback(of: arrival, progress: 1, isFinished: true)
        let genres = taste.snapshot().genres
        eq(genres["Drama"], 1, "the genre both share leads")
        let sciFi = genres["Sci-Fi"] ?? 0, romance = genres["Romance"] ?? 0
        check(romance > 0 && abs(sciFi / romance - 4) < 0.01, "last week's genre weighs four times the one of four months ago", "\(genres)")
    }

    func testAMovieLeftEarlyAndNotResumedIsGivenUpOn() {
        let clock = F.Clock("2026-11-01T12:00:00Z")
        let taste = taste(clock: clock)
        taste.notePlayback(of: notebook, progress: 0.1, isFinished: false)
        taste.notePlayback(of: arrival, progress: 0.6, isFinished: false)
        clock.advance(10 * day)
        check((taste.snapshot().genres["Romance"] ?? 0) > 0, "ten days later: still just started")
        clock.advance(5 * day)
        let genres = taste.snapshot().genres
        check((genres["Romance"] ?? 0) < 0, "fifteen days at 10 %: given up on, it counts against", "\(genres)")
        check((genres["Sci-Fi"] ?? 0) > 0, "a movie past a quarter is not given up on")
        check(taste.snapshot().excluded.contains(notebook.imdbID), "and the one given up on is not offered")
        taste.notePlayback(of: notebook, progress: 0.5, isFinished: false)
        check((taste.snapshot().genres["Romance"] ?? 0) > 0, "played again: started again")
    }

    // MARK: - Choices

    func testAChoiceMadeOftenEnoughIsLearnt() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let taste = taste(clock: clock)
        taste.note(.audio("fr"))
        eq(taste.preferredChoice(.audio), nil, "once is not a habit")
        taste.note(.audio("fr"))
        taste.note(.audio("en"))
        taste.note(.audio("en"))
        eq(taste.preferredChoice(.audio), nil, "two out of four: no habit")
        taste.note(.audio("fr"))
        taste.note(.audio("fr"))
        eq(taste.preferredChoice(.audio), "fr", "four out of six: French")

        taste.note(.subtitle(nil))
        taste.note(.subtitle(nil))
        eq(taste.preferredChoice(.subtitle), nil, "subtitles off is no language")
        check(taste.prefersSubtitlesOff, "but it is learnt")

        taste.note(.quality("2160p"))
        taste.note(.quality("2160p"))
        eq(taste.preferredChoice(.quality), "2160p", "the quality played")
        check(taste.isFirstPlay(of: "tt1") && !taste.isFirstPlay(of: "tt1"), "a play's quality counted once")
    }

    // MARK: - Profiles

    func testTwoProfilesLearnApartAndAResetForgetsOneOnly() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let storage = MemoryLibraryStorage()
        let profiles = ProfileManager(storage: storage, defaultName: "Me", center: NotificationCenter(), makeID: { "kid" },
                                      now: { clock.now }, eraseExternal: { _ in })
        let kid = try! profiles.create(name: "Kid", avatar: 1)
        let me = taste(profiles.storage(for: Profile.primaryID), clock: clock)
        let them = taste(profiles.storage(for: kid.id), clock: clock)

        me.notePlayback(of: interstellar, progress: 1, isFinished: true)
        them.noteWatched(true, of: TasteTitle(imdbID: "tt2380307", kind: .movie, genres: ["Animation", "Family"], year: 2017))
        check(me.snapshot().genres["Animation"] == nil, "my taste has none of theirs")
        check(them.snapshot().genres["Sci-Fi"] == nil, "theirs has none of mine")
        check(storage.object(forKey: ProfileTaste.storageKey) is Data, "the primary profile's taste: the plain key")
        check(storage.object(forKey: "profile.kid.\(ProfileTaste.storageKey)") is Data, "the other's: under its prefix")

        // Read again from the storage (a new launch).
        let meAgain = taste(profiles.storage(for: Profile.primaryID), clock: clock)
        eq(meAgain.snapshot(), me.snapshot(), "the taste is stored")

        them.reset()
        check(them.isEmpty && !them.snapshot().isConfident, "reset: nothing learnt")
        check(taste(profiles.storage(for: kid.id), clock: clock).isEmpty, "and nothing stored")
        eq(taste(profiles.storage(for: Profile.primaryID), clock: clock).snapshot(), me.snapshot(), "the other profile is untouched")

        try! profiles.delete(kid.id)
        check(storage.object(forKey: "profile.kid.\(ProfileTaste.storageKey)") == nil, "a deleted profile takes its taste")
    }

    func testAProfileFromBeforeTastesIsSeededFromItsWatchlist() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let storage = MemoryLibraryStorage([
            "moviesWatchlist": [["imdb_id": "tt0111161", "title": "The Shawshank Redemption", "year": "1994", "genres": ["drama", "crime"]]],
        ])
        let library = Library(storage: storage, guideDirectory: nil, remote: .offline, center: NotificationCenter(), now: { clock.now })
        let taste = taste(storage, clock: clock)
        taste.seed(from: library)
        check((taste.snapshot().genres["Crime"] ?? 0) > 0, "the list's genres are learnt")
        check(taste.snapshot().decades[1990] != nil, "and its decade")
        taste.reset()
        taste.seed(from: library)
        check(taste.isEmpty, "after a reset the list is not read again")
    }

    // MARK: - Scoring and « For You »

    func testScoresFollowTheTaste() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let taste = taste(clock: clock)
        taste.notePlayback(of: interstellar, progress: 1, isFinished: true)
        taste.notePlayback(of: arrival, progress: 1, isFinished: true)
        taste.notePlayback(of: notebook, progress: 0.05, isFinished: false)
        clock.advance(20 * day)
        let snapshot = taste.snapshot()
        check(snapshot.isConfident, "two movies finished: enough to rank with", "\(snapshot.signal)")
        let sciFi = snapshot.score(card("a", ["Sci-Fi", "Adventure"]))
        let romance = snapshot.score(card("b", ["Romance"]))
        let unknown = snapshot.score(card("c", ["Western"]))
        check(sciFi > unknown && unknown > romance, "liked > unknown > given up on", "\(sciFi) \(unknown) \(romance)")
        check(snapshot.score(card("d", ["Sci-Fi"], rating: 8.5)) > snapshot.score(card("e", ["Sci-Fi"], rating: 5.5)),
              "between two alike, the better rated")
        check(snapshot.score(card("f", ["Sci-Fi"], year: 2015)) > snapshot.score(card("g", ["Sci-Fi"], year: 1975)),
              "the decade it watches")
    }

    func testForYouRanksThePagesTitlesByTasteWithoutWhatWasWatched() {
        let snapshot = TasteSnapshot(genres: ["Sci-Fi": 1, "Drama": 0.4, "Horror": -1], decades: [2010: 1], kinds: ["movie": 1],
                                     excluded: ["tt0816692"], signal: 5)
        var local = HomeLocal()
        local.taste = snapshot
        let shelves = HomeBuilder.shelves(HomeFixture.inputs(HomeFixture.allLists(), local: local), facts: HomeTitleFacts())
        guard let forYou = shelves.first(where: { $0.id == HomeShelfID.forYou }) else {
            return check(false, "a « For You » shelf", "\(shelves.map(\.id))")
        }
        eq(shelves.map(\.id).firstIndex(of: HomeShelfID.forYou), 1, "right under the hero (no resume cards here)")
        check(forYou.items.count >= 6 && forYou.items.count <= 20, "between 6 and 20 cards", "\(forYou.items.count)")
        eq(Set(forYou.items.map(\.imdbId)).count, forYou.items.count, "each title once")
        check(forYou.items.allSatisfy { $0.episode == nil && $0.rank == nil }, "title cards, no rank")
        check(!forYou.items.contains { $0.imdbId == "tt0816692" }, "what was watched is left out")
        check(!forYou.items.contains { $0.genres.contains("Horror") && !$0.genres.contains("Sci-Fi") }, "nothing it dislikes")
        let scores = forYou.items.map(snapshot.score)
        eq(scores, scores.sorted(by: >), "best first")
        let rest = shelves.filter { $0.id != HomeShelfID.forYou }
        let without = HomeBuilder.shelves(HomeFixture.inputs(HomeFixture.allLists()), facts: HomeTitleFacts())
        eq(rest.map(\.id), without.map(\.id), "the other shelves are the same")
        eq(rest.map { $0.items.map(\.id) }, without.map { $0.items.map(\.id) }, "with the same cards: « For You » takes none from them")

        var hidden = HomeBuilder.shelves(HomeFixture.inputs(HomeFixture.allLists(), local: local, hidden: [HomeShelfID.forYou]), facts: HomeTitleFacts())
        check(hidden.shelf(HomeShelfID.forYou) == nil, "hidden in Settings › Home: none")
        local.taste?.signal = 0.5
        hidden = HomeBuilder.shelves(HomeFixture.inputs(HomeFixture.allLists(), local: local), facts: HomeTitleFacts())
        check(hidden.shelf(HomeShelfID.forYou) == nil, "too little learnt: none")
    }
}
