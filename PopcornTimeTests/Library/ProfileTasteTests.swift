//
//  ProfileTasteTests.swift
//  PopcornTimeTests
//
//  A profile's taste (PopcornKit, ProfileTaste): what each event is worth, counted once; the
//  decay of old events; titles given up on; the learnt audio / subtitle / quality choices; two
//  profiles kept apart; a reset; and the Home's « For You » shelf ranked by it. Also: titles
//  marked by their id only, features learnt late, how seldom and how small the model is written,
//  the players' choices (an explicit « None », the language heard, the picks in AVKit's menus).
//  No UserDefaults, no network, no real clock.
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

    /// A storage that counts the taste's writes.
    private final class CountingStorage: LibraryStorage {
        let base = MemoryLibraryStorage()
        private(set) var writes = 0
        func object(forKey key: String) -> Any? { base.object(forKey: key) }
        func set(_ value: Any?, forKey key: String) {
            if key == ProfileTaste.storageKey { writes += 1 }
            base.set(value, forKey: key)
        }
        var storedBytes: Int { (base.object(forKey: ProfileTaste.storageKey) as? Data)?.count ?? 0 }
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

    // MARK: - Titles known by their id, features learnt late

    func testAMarkByIdOnlyCountsOnceItsFeaturesAreKnown() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let taste = taste(clock: clock)
        taste.noteWatched(true, mediaID: arrival.imdbID, kind: .movie)
        eq(taste.snapshot().signal, 0, "marked from a card, features unknown: nothing learnt yet")
        check(taste.snapshot().excluded.contains(arrival.imdbID), "but it is not offered")
        taste.notePlayback(of: arrival, progress: 1, isFinished: true)
        eq(round(taste.snapshot().signal * 100), 100, "played from its page: its whole worth, once")
        check((taste.snapshot().genres["Sci-Fi"] ?? 0) > 0, "on its genres")

        // A movie marked from its page: the movie itself comes along.
        taste.noteWatched(true, mediaID: notebook.imdbID, kind: .movie, title: notebook)
        check((taste.snapshot().genres["Romance"] ?? 0) > 0, "marked with its features: learnt at once")
    }

    func testEpisodesMarkedByIdCountForTheirShowOncePlayed() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let taste = taste(clock: clock)
        let episode = { (season: Int, n: Int) in LibraryID.episodeID(showID: self.breakingBad.imdbID, EpisodeNumber(season: season, episode: n)) }
        for n in 1...10 { taste.noteWatched(true, mediaID: episode(1, n), kind: .show) }
        eq(taste.snapshot().signal, 0, "a season marked by its ids: nothing learnt yet")
        taste.notePlayback(of: breakingBad, progress: 1, isFinished: true, episodeID: episode(2, 1))
        check((taste.snapshot().genres["Crime"] ?? 0) > 0, "the next episode played: the show's genres are learnt")
        eq(round(taste.snapshot().signal * 100), 140, "at the show's ceiling, counted once")
    }

    func testMarksByIdDoNotMakeTheTasteConfident() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let taste = taste(clock: clock)
        taste.noteWatched(true, mediaID: "tt0000001", kind: .movie)
        taste.noteWatched(true, mediaID: "tt0000002", kind: .movie)
        taste.noteWatchlist(true, of: arrival)
        eq(round(taste.snapshot().signal * 100), 40, "only the listed title counts")
        check(!taste.snapshot().isConfident, "one listed title is not enough to rank with")
    }

    func testPeopleLearntLaterTakeOverWhatTheListCredited() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let taste = taste(clock: clock)
        var listed = interstellar
        listed.people = []
        taste.noteWatchlist(true, of: listed)
        check(taste.topAffinities()[.person] == nil, "listed: no people known")
        taste.notePlayback(of: interstellar, progress: 0.5, isFinished: false)
        let people = taste.topAffinities()[.person]?.map(\.value) ?? []
        check(people.contains("Christopher Nolan"), "played from its page: its people are learnt", "\(people)")
        eq(round(taste.snapshot().signal * 100), 70, "listed then started: 0.4 + 0.3, the move not counted again")

        // The same as learning it all at once.
        let direct = self.taste(clock: clock)
        direct.noteWatchlist(true, of: interstellar)
        direct.notePlayback(of: interstellar, progress: 0.5, isFinished: false)
        eq(taste.snapshot().genres, direct.snapshot().genres, "the genres weigh what they would have")
        eq(taste.topAffinities(), direct.topAffinities(), "and so do the people")
    }

    // MARK: - Writes

    func testAPositionSavedAgainIsWrittenSeldomAndNotAnnounced() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let storage = CountingStorage()
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: ProfileTaste.didChangeNotification, object: nil, queue: nil) { _ in posts += 1 }
        defer { center.removeObserver(token) }
        let taste = ProfileTaste(storage: storage, center: center, now: { clock.now })

        taste.notePlayback(of: interstellar, progress: 0.3, isFinished: false)
        eq(storage.writes, 1, "started: written")
        eq(posts, 1, "and announced")
        for _ in 0..<10 {
            clock.advance(30)
            taste.notePlayback(of: interstellar, progress: 0.35, isFinished: false)
        }
        eq(storage.writes, 1, "the 30 s checkpoints change nothing the taste says: not written")
        eq(posts, 1, "nor announced (no second Home rebuild)")
        taste.flush()
        eq(storage.writes, 2, "the pause writes what is left")
        taste.flush()
        eq(storage.writes, 2, "once")

        clock.advance(30)
        taste.notePlayback(of: interstellar, progress: 0.36, isFinished: false)
        clock.advance(31 * 60)
        taste.notePlayback(of: interstellar, progress: 0.4, isFinished: false)
        eq(storage.writes, 3, "half an hour later a quiet change is written anyway")

        taste.notePlayback(of: interstellar, progress: 0.9, isFinished: true)
        eq(storage.writes, 4, "finished: written at once")
        eq(posts, 2, "and announced")

        // A movie crossing the « given up on » fraction matters: the sweep reads it.
        taste.notePlayback(of: notebook, progress: 0.1, isFinished: false)
        let before = storage.writes
        taste.notePlayback(of: notebook, progress: 0.3, isFinished: false)
        eq(storage.writes, before + 1, "past a quarter: written")
        let stored = self.taste(storage, clock: clock)
        eq(stored.snapshot(), taste.snapshot(), "what is stored is what is learnt")
    }

    func testTheWatchlistSeedIsWrittenOnce() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let entries: [[String: Any]] = (0..<300).map {
            ["imdb_id": String(format: "tt%07d", 1_000_000 + $0), "title": "Movie \($0)", "year": "1994", "genres": ["drama", "crime"]]
        }
        let library = Library(storage: MemoryLibraryStorage(["moviesWatchlist": entries]), guideDirectory: nil, remote: .offline,
                              center: NotificationCenter(), now: { clock.now })
        let storage = CountingStorage()
        let taste = taste(storage, clock: clock)
        taste.seed(from: library)
        eq(storage.writes, 1, "300 listed titles: one write")
        check((taste.snapshot().genres["Crime"] ?? 0) > 0, "and they are learnt")
        check(storage.storedBytes <= taste.policy.maxStoredBytes, "within the size", "\(storage.storedBytes)")
    }

    func testAFullModelStaysSmall() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let storage = CountingStorage()
        let taste = taste(storage, clock: clock)
        let names = ["Christopher Nolan", "Matthew McConaughey", "Anne Hathaway", "Jessica Chastain", "Michael Caine"]
        for index in 0..<300 {
            clock.advance(3600)
            let isShow = index % 2 == 1
            let title = TasteTitle(imdbID: String(format: "tt%07d", 2_000_000 + index), kind: isShow ? .show : .movie,
                                   genres: ["Science Fiction", "Adventure", "Drama"], year: 1950 + index % 70,
                                   people: names.map { "\($0) \(index)" })
            if isShow {
                for n in 1...40 {
                    taste.notePlayback(of: title, progress: 1, isFinished: true,
                                       episodeID: LibraryID.episodeID(showID: title.imdbID, EpisodeNumber(season: n / 10 + 1, episode: n)))
                }
            } else {
                taste.notePlayback(of: title, progress: 1, isFinished: true)
            }
        }
        check(storage.storedBytes > 0 && storage.storedBytes <= taste.policy.maxStoredBytes,
              "300 heavy titles stored in at most \(taste.policy.maxStoredBytes) bytes", "\(storage.storedBytes)")
        check(5 * storage.storedBytes < 400_000, "five such profiles stay well under the 1 MB tvOS allows", "\(storage.storedBytes)")

        // A show keeps a few finished episodes only, and its full worth.
        let binge = self.taste(clock: clock)
        let episode = { (n: Int) in LibraryID.episodeID(showID: self.breakingBad.imdbID, EpisodeNumber(season: 1, episode: n)) }
        for n in 1...20 { binge.noteWatched(true, of: breakingBad, episodeID: episode(n)) }
        eq(round(binge.snapshot().signal * 100), 140, "twenty episodes: the ceiling")
        binge.noteWatched(false, of: breakingBad, episodeID: episode(20))
        binge.noteWatched(false, of: breakingBad, episodeID: episode(1))
        eq(round(binge.snapshot().signal * 100), 140, "one unmarked: still at the ceiling")
    }

    // MARK: - Shows given up on

    func testAShowLeftPastAQuarterIsNotGivenUpOn() {
        let clock = F.Clock("2026-11-01T12:00:00Z")
        let taste = taste(clock: clock)
        let pilot = LibraryID.episodeID(showID: breakingBad.imdbID, EpisodeNumber(season: 1, episode: 1))
        taste.notePlayback(of: breakingBad, progress: 0.75, isFinished: false, episodeID: pilot)
        let lost = TasteTitle(imdbID: "tt0411008", kind: .show, genres: ["Mystery", "Adventure"], year: 2004)
        taste.notePlayback(of: lost, progress: 0.1, isFinished: false,
                           episodeID: LibraryID.episodeID(showID: lost.imdbID, EpisodeNumber(season: 1, episode: 1)))
        clock.advance(15 * day)
        let genres = taste.snapshot().genres
        check((genres["Crime"] ?? 0) > 0, "a pilot left at 75 % three weeks ago: still liked", "\(genres)")
        check((genres["Mystery"] ?? 0) < 0, "one left at 10 %: given up on", "\(genres)")
    }

    // MARK: - « For You »: hidden shelves, genres it likes

    func testForYouLeavesOutHiddenShelves() {
        let snapshot = TasteSnapshot(genres: ["Sci-Fi": 1, "Drama": 0.8, "Action": 0.6, "Thriller": 0.5, "Crime": 0.5],
                                     decades: [2020: 1], kinds: ["movie": 1, "show": 0.5], signal: 5)
        var local = HomeLocal()
        local.taste = snapshot
        let shelves = HomeBuilder.shelves(HomeFixture.inputs(HomeFixture.allLists(), local: local), facts: HomeTitleFacts())
        guard let forYou = shelves.shelf(HomeShelfID.forYou) else { return check(false, "a « For You » shelf", "\(shelves.map(\.id))") }
        let offered = Set(forYou.items.map(\.imdbId))
        let others = shelves.filter { $0.id != HomeShelfID.forYou && $0.id != HomeShelfID.hero }
        // A shelf some of whose own titles (on no other shelf) are offered.
        let source = others.first { shelf in
            let rest = Set(others.filter { $0.id != shelf.id }.flatMap { $0.items.map(\.imdbId) })
            return !offered.intersection(Set(shelf.items.map(\.imdbId)).subtracting(rest)).isEmpty
        }
        guard let source else { return check(false, "« For You » takes titles of its own from a shelf") }
        let only = Set(source.items.map(\.imdbId)).subtracting(Set(others.filter { $0.id != source.id }.flatMap { $0.items.map(\.imdbId) }))

        let hidden = HomeBuilder.shelves(HomeFixture.inputs(HomeFixture.allLists(), local: local, hidden: [source.id]), facts: HomeTitleFacts())
        check(hidden.shelf(source.id) == nil, "\(source.id) hidden")
        let stillOffered = Set(hidden.shelf(HomeShelfID.forYou)?.items.map(\.imdbId) ?? [])
        check(stillOffered.isDisjoint(with: only), "none of the hidden \(source.id)'s titles in « For You »",
              "\(stillOffered.intersection(only))")
    }

    func testForYouRequiresGenresTheProfileLikes() {
        let snapshot = TasteSnapshot(genres: ["Sci-Fi": 1], decades: [2020: 1], kinds: ["movie": 1], signal: 5)
        let comedy = card("a", ["Comedy"], year: 2024, rating: 7.5)
        check(snapshot.score(comedy) >= 0.12, "a recent, well-rated comedy scores on decade, kind and rating alone")
        eq(snapshot.genreScore(comedy.genres), 0, "but it shares no genre the profile likes")
        check(snapshot.genreScore(["Drama", "Sci-Fi"]) >= 0.2, "a liked second genre is enough")

        var local = HomeLocal()
        local.taste = snapshot
        let shelves = HomeBuilder.shelves(HomeFixture.inputs(HomeFixture.allLists(), local: local), facts: HomeTitleFacts())
        if let forYou = shelves.shelf(HomeShelfID.forYou) {
            check(forYou.items.allSatisfy { snapshot.genreScore($0.genres) >= 0.2 }, "only titles of genres it likes",
                  "\(forYou.items.map { "\($0.title) \($0.genres)" })")
        }
        local.taste = TasteSnapshot(genres: ["Western": 1], decades: [2020: 1], kinds: ["movie": 1], signal: 5)
        let westerns = HomeBuilder.shelves(HomeFixture.inputs(HomeFixture.allLists(), local: local), facts: HomeTitleFacts())
        check(westerns.shelf(HomeShelfID.forYou) == nil, "too few titles of its genres on the page: no shelf, not a padded one")
    }

    // MARK: - The players' choices

    func testAnExplicitNoneIsNeverReplacedByALearntLanguage() {
        typealias P = PlaybackLanguagePreferences
        eq(P.effectiveCode(stored: nil, learned: "fr"), "fr", "never set: the learnt language")
        eq(P.effectiveCode(stored: P.noneValue, learned: "fr"), nil, "« None » chosen: none")
        eq(P.effectiveCode(stored: "Français", learned: "en"), "fr", "a setting wins")
        eq(P.isoCode(for: P.noneValue), nil, "« None » reads as no language in Settings")
        eq(P.subtitleCode(stored: P.noneValue, learned: "fr", heard: "kor"), nil, "subtitles: « None » holds")
    }

    func testALearntSubtitleLanguageIsNotTurnedOnForAudioInIt() {
        typealias P = PlaybackLanguagePreferences
        eq(P.subtitleCode(stored: nil, learned: "fr", heard: "ko"), "fr", "Korean heard: the French subtitles it picks")
        eq(P.subtitleCode(stored: nil, learned: "fr", heard: "fre"), nil, "French heard: no French subtitles")
        eq(P.subtitleCode(stored: nil, learned: "fr", heard: "Track 1 - [Français]"), nil, "a VLC track's name says it too")
        eq(P.subtitleCode(stored: nil, learned: "fr", heard: nil), nil, "audio unknown: nothing turned on by itself")
        eq(P.subtitleCode(stored: nil, learned: "fr", heard: "und"), nil, "undetermined: unknown")
        eq(P.subtitleCode(stored: "Français", learned: "en", heard: "fr"), "fr", "a setting applies whatever is heard")
    }

    func testThePlayersPicksTeachTheProfilesTaste() {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let taste = taste(clock: clock)
        let previous = PlaybackLanguagePreferences.choiceTaste
        PlaybackLanguagePreferences.choiceTaste = { taste }
        defer { PlaybackLanguagePreferences.choiceTaste = previous }

        for name in ["Track 2 - [French]", "fre", "fr-FR"] {
            clock.advance(day)
            PlaybackLanguagePreferences.noteChosenSubtitle(languageOrName: name, isOff: false)
        }
        eq(taste.preferredChoice(.subtitle), "fr", "three picks a day apart (decayed, a little under 3): learnt")
        PlaybackLanguagePreferences.noteChosenAudio(languageOrName: "Commentary")
        eq(taste.choices(.audio).count, 0, "a track of no known language teaches nothing")
        PlaybackLanguagePreferences.noteChosenAudio(languageOrName: PlaybackLanguagePreferences.languageOrName(language: "", name: "Japanese"))
        eq(taste.choices(.audio).first?.value, "ja", "a VLC track without a code: its name")
    }

    func testOnlyTheUsersOwnPicksInAVKitsMenusAreLearnt() {
        typealias P = PlaybackLanguagePreferences
        eq(P.selectionChange(current: "fr", known: "fr", own: nil, settled: true), .none, "nothing changed")
        eq(P.selectionChange(current: "fr", known: "en", own: nil, settled: false), .notTheUser, "AVPlayer settling the item")
        eq(P.selectionChange(current: "fr", known: "en", own: .some("fr"), settled: true), .notTheUser, "the app's own selection")
        eq(P.selectionChange(current: nil, known: "en", own: .some(nil), settled: true), .notTheUser, "the app turning them off")
        eq(P.selectionChange(current: "fr", known: "en", own: .some("en"), settled: true), .user, "anything else: the user's pick")
        eq(P.selectionChange(current: nil as String?, known: "en", own: nil, settled: true), .user, "turned off by the user")
    }
}
