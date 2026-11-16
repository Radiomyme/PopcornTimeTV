//
//  ContinueWatchingTests.swift
//  PopcornTimeTests
//
//  The resume entries (PopcornKit, ContinueWatchingStore) and the row built from them
//  (Library.continueWatching): the migration of the 4.x / 5.x UserDefaults lists, the order,
//  one card per show, the thresholds, removal. No UserDefaults, no network, no real clock.
//

import Foundation
import XCTest
@testable import PopcornKit

final class ContinueWatchingTests: CheckedTestCase {

    private typealias F = LibraryFixtures

    private func library(_ storage: LibraryStorage = MemoryLibraryStorage(), clock: F.Clock, policy: LibraryPolicy = .standard,
                         remote: LibraryRemote = .offline, center: NotificationCenter = NotificationCenter()) -> Library {
        return Library(storage: storage, guideDirectory: nil, remote: remote, policy: policy, center: center, now: { clock.now })
    }

    private func cards(_ library: Library) -> [String] {
        return library.continueWatching().map { "\($0.mediaID):\($0.reason.rawValue)" }
    }

    /// Cinemeta's recorded meta of Dune: Part Two (movie) or Breaking Bad (series).
    private func recordedTitle(_ id: String, _ kind: ContinueWatchingEntry.Kind) -> LibraryRemote.Answer<LibraryRemote.Title> {
        let file = kind == .movie ? "Library/cm_meta_movie_\(id).json" : "Library/cm_meta_series_\(id).json"
        return LibraryRemote.title(fromCinemetaMeta: Fixtures.data(file), imdbID: id).map { .found($0) } ?? .unknown
    }

    private func hydrate(_ library: Library, limit: Int = 12) -> Bool {
        let done = expectation(description: "hydrated")
        var changed = false
        library.hydrateMissingTitles(limit: limit) { changed = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return changed
    }

    // MARK: - Migration

    /// What 5.x wrote: episode ids "tt…-sXeY"; also leftovers of 4.x (numeric TVDB ids) and a torrent hash.
    private func storage5x() -> MemoryLibraryStorage {
        return MemoryLibraryStorage([
            "moviesProgress": ["tt0816692": Float(0.55), "tt15239678": Float(0.37), "tt1375666": Float(0.93)] as [String: Any],
            "moviesWatchedlist": ["tt1375666", "tt0468569"],
            "episodesProgress": ["tt0903747-s1e1": Float(0.42), "tt0944947-s2e3": Float(0.31), "tt0944947-s1e1": Float(0.95),
                                 "349232": Float(0.5), "0123456789abcdef0123456789abcdef01234567": Float(0.2)] as [String: Any],
            "episodesWatchedlist": ["tt0944947-s1e1", "tt0944947-s1e2", "tt0944947-s2e1", "349232", "349233",
                                    "tt5875444-s5e6", "tt5875444-s0e1"],
            "moviesWatchlist": [["imdb_id": "tt0111161", "title": "The Shawshank Redemption", "year": "1994"]],
        ])
    }

    func testMigrationFrom5x() {
        let storage = storage5x()
        let before = storage.keys.sorted().map { "\($0)=\(String(describing: storage.object(forKey: $0)))" }
        let clock = F.Clock("2026-11-14T12:00:00Z")
        let library = self.library(storage, clock: clock)

        let entries = library.resume.allEntries()
        eq(Set(entries.map { $0.mediaID }),
           ["tt0816692", "tt15239678", "tt0903747-s1e1", "tt0944947-s2e3", "tt0944947-s2e1", "tt5875444-s5e6"],
           "movies in progress, episodes in progress, each show's furthest watched episode — nothing for TVDB numbers, a hash, a watched movie, a special")
        let got = library.resume.entry("tt0944947-s2e3")
        eq(got?.showID, "tt0944947", "the show comes from the id")
        eq(got?.number, F.number(2, 3), "…and the season and episode")
        eq(got?.progress, 0.31, "the progress is the stored one")
        check(got?.title == nil && got?.isFinished == false, "no title yet, not finished")
        check(library.resume.entry("tt0944947-s2e1")?.isFinished == true, "the furthest watched episode is a finished entry")
        check(entries.allSatisfy { $0.updatedAt < clock.now && clock.now.timeIntervalSince($0.updatedAt) < 3600 },
              "every entry is dated just before the migration")
        eq(Set(entries.map { $0.updatedAt }).count, entries.count, "…each at its own second (a stable order)")

        // The row: each title once, as 5.2 would have continued it.
        eq(Set(cards(library)), ["tt0816692:resume", "tt15239678:resume", "tt0903747-s1e1:resume", "tt0944947-s2e3:resume"],
           "movies and episodes in progress have a card; Slow Horses (S5E6 watched, no guide yet) has none")
        eq(library.continueWatching().filter { $0.imdbID == "tt0944947" }.count, 1, "one card for Game of Thrones")

        // The old lists are untouched, and still answer.
        let after = storage.keys.filter { $0 != ContinueWatchingStore.storageKey }.sorted().map { "\($0)=\(String(describing: storage.object(forKey: $0)))" }
        eq(after, before, "the 5.2 keys keep their content")
        check(library.isWatched("349232") && library.progress("349232") == 0.5, "a 4.x TVDB id is still watched, with its progress")
        check(library.isWatched("tt0468569") && library.progress("tt1375666") == 0.93, "movies too")
        check(storage.object(forKey: ContinueWatchingStore.storageKey) is Data, "the entries are one Data value")

        // Once: a second library on the same storage reads the entries, it does not migrate again.
        storage.set(["tt0816692": Float(0.10)] as [String: Any], forKey: "moviesProgress")
        let again = self.library(storage, clock: F.Clock("2026-12-24T12:00:00Z"))
        eq(again.resume.allEntries(), entries, "the stored entries are read back as they were")
    }

    func testMigrationFrom4x() {
        // 4.x: movies by IMDb id, episodes by TVDB number only.
        let storage = MemoryLibraryStorage([
            "moviesProgress": ["tt0468569": 0.25, "tt0109830": 0.5] as [String: Any],            // Doubles
            "moviesWatchedlist": ["tt0109830"],
            "episodesProgress": ["349232": 0.4, "349233": 0.99] as [String: Any],
            "episodesWatchedlist": ["349233", "4161693"],
        ])
        let library = self.library(storage, clock: F.Clock("2026-11-14T12:00:00Z"))
        eq(library.resume.allEntries().map { $0.mediaID }, ["tt0468569"], "the movie in progress; nothing can be made of TVDB numbers")
        eq(cards(library), ["tt0468569:resume"], "its card")
        check(library.followedShows().isEmpty, "no show can be named from TVDB numbers")
        // Nothing is dropped: the lists still hold and answer the TVDB ids.
        eq((storage.object(forKey: "episodesWatchedlist") as? [String]) ?? [], ["349233", "4161693"], "the watched list is as it was")
        check(library.isWatched("4161693") && library.progress("349232") == 0.4, "4.x episodes are still watched / in progress by their id")
        // A list given as launch arguments (the UI tests) holds its numbers as text.
        let fromArguments = self.library(MemoryLibraryStorage(["moviesProgress": ["tt0816692": "0.42", "tt0468569": "x"]]),
                                         clock: F.Clock("2026-11-14T12:00:00Z"))
        check(fromArguments.progress("tt0816692") == 0.42 && fromArguments.progress("tt0468569") == 0, "a number as text is read, other text is not")
        // A later write keeps them too.
        library.setProgress(0.3, id: "tt0903747-s1e1", list: .episodes)
        let progress = storage.object(forKey: "episodesProgress") as? [String: Any] ?? [:]
        eq(Set(progress.keys), ["349232", "349233", "tt0903747-s1e1"], "writing a 5.x progress keeps the 4.x ones")
    }

    func testMigrationSurvivesForeignValues() {
        // One value that is not a number, one list entry that is not a string, a Double that is not a Float:
        // 5.2's `as? [String: Float]` gave nil for the whole dictionary and the next save wiped it.
        let storage = MemoryLibraryStorage([
            "moviesProgress": ["tt0816692": 0.1, "tt15239678": "half", "tt0468569": NSNull(), "tt0111161": 0.7] as [String: Any],
            "moviesWatchedlist": ["tt0109830", 42, ["nested"]] as [Any],
            "episodesProgress": "not a dictionary",
            "episodesWatchedlist": ["tt0944947-s1e1", "tt0944947-sXe1", "tt-s1e1", "-s1e1", "tt0944947-s1e", ""],
        ])
        let library = self.library(storage, clock: F.Clock("2026-11-14T12:00:00Z"))
        eq(Set(library.resume.allEntries().map { $0.mediaID }), ["tt0816692", "tt0111161", "tt0944947-s1e1"],
           "what can be read is migrated, the rest is skipped")
        eq(library.progress("tt0816692"), Float(0.1), "a Double that is not exactly a Float is read")
        check(library.isWatched("tt0109830") && !library.isWatched("42"), "a foreign list entry is skipped, the others stay")
        library.setProgress(0.5, id: "tt15239678", list: .movies)
        let progress = storage.object(forKey: "moviesProgress") as? [String: Float] ?? [:]
        eq(progress, ["tt0816692": 0.1, "tt0111161": 0.7, "tt15239678": 0.5], "the next save keeps every readable progress")
    }

    func testEpisodeIDs() {
        check(LibraryID.episode("tt0903747-s1e1")! == ("tt0903747", F.number(1, 1)), "tt…-s1e1")
        check(LibraryID.episode("tt31510819-s12e104")! == ("tt31510819", F.number(12, 104)), "two-digit season, three-digit episode")
        check(LibraryID.episode("tt0903747-s0e3")! == ("tt0903747", F.number(0, 3)), "a special")
        for other in ["tt0903747", "349232", "0123456789abcdef0123456789abcdef01234567", "tt0903747-s1", "tt0903747-e1s1",
                      "tt0903747-s-1e1", "ttabc-s1e1", "kitsu123-s1e1", "tt0903747-s1e1x", ""] {
            check(LibraryID.episode(other) == nil, "'\(other)' is not an episode id")
        }
        eq(LibraryID.episodeID(showID: "tt0903747", F.number(1, 1)), "tt0903747-s1e1", "the id the providers build")
        check(LibraryID.isIMDb("tt0903747") && !LibraryID.isIMDb("tt") && !LibraryID.isIMDb("tt09x") && !LibraryID.isIMDb("349232"), "IMDb ids")
    }

    // MARK: - Order, one card per show

    func testTheRowIsSortedByLastPlayAndHasOneCardPerShow() {
        let clock = F.Clock("2026-11-01T20:00:00Z")
        let library = self.library(clock: clock)
        library.setProgress(0.30, id: "tt0816692", list: .movies)                 // Interstellar
        clock.advance(3600)
        library.setProgress(0.30, id: "tt0903747-s1e1", list: .episodes)          // Breaking Bad S1E1
        clock.advance(3600)
        library.setProgress(0.50, id: "tt15239678", list: .movies)                // Dune
        clock.advance(3600)
        library.setProgress(0.50, id: "tt0903747-s1e2", list: .episodes)          // Breaking Bad S1E2
        clock.advance(3600)
        library.setProgress(0.20, id: "tt0944947-s3e4", list: .episodes)          // Game of Thrones S3E4

        eq(cards(library), ["tt0944947-s3e4:resume", "tt0903747-s1e2:resume", "tt15239678:resume", "tt0816692:resume"],
           "the most recently played first; Breaking Bad once, on the episode played last")
        let breakingBad = library.continueWatching().first { $0.imdbID == "tt0903747" }
        eq(breakingBad?.kind, .show, "a show card")
        eq(breakingBad?.number, F.number(1, 2), "S1E2")
        eq(breakingBad?.updatedAt, F.date("2026-11-01T23:00:00Z"), "dated by the show's last play")
        eq(library.continueWatching(limit: 2).map { $0.imdbID }, ["tt0944947", "tt0903747"], "the limit keeps the most recent")
        eq(library.continueWatching(kinds: [.movie]).map { $0.imdbID }, ["tt15239678", "tt0816692"], "movies only")
        eq(library.continueWatching(kinds: [.show]).map { $0.imdbID }, ["tt0944947", "tt0903747"], "shows only")

        // Playing a title again moves it to the front.
        clock.advance(3600)
        library.setProgress(0.35, id: "tt0816692", list: .movies)
        eq(library.continueWatching().first?.imdbID, "tt0816692", "played again: first")
    }

    func testNextUpCard() {
        let clock = F.Clock("2026-11-10T20:00:00Z")
        let library = self.library(clock: clock)
        library.noteGuide(showID: "tt0903747", title: "Breaking Bad",
                          episodes: [F.episode(1, 1, aired: "2008-01-21T05:00:00Z", title: "Pilot"),
                                     F.episode(1, 2, aired: "2008-01-28T05:00:00Z", title: "Cat's in the Bag..."),
                                     F.episode(1, 3, aired: "2026-11-12T05:00:00Z", title: "...And the Bag's in the River")], always: true)
        library.setProgress(0.5, id: "tt0903747-s1e1", list: .episodes,
                            details: PlaybackDetails(title: "Breaking Bad", episodeTitle: "Pilot", runtime: 49, position: 1470, duration: 2940))
        var card = library.continueWatching().first
        eq(card?.reason, .resume, "half of S1E1: resume")
        eq(card?.title, "Breaking Bad", "the show's title")
        eq(card?.episodeTitle, "Pilot", "the episode's title")
        eq(card?.remaining, 1470, "the time left, from the player's position and duration")
        eq(card?.episodeStillURL?.absoluteString, "https://episodes.metahub.space/tt0903747/1/1/w780.jpg", "the still, from the ids")
        eq(card?.backdropURL?.absoluteString, "https://images.metahub.space/background/large/tt0903747/img", "the backdrop, from the IMDb id")

        clock.advance(1800)
        check(library.setProgress(0.9, id: "tt0903747-s1e1", list: .episodes), "0.9 marks S1E1 watched")
        card = library.continueWatching().first
        eq(card?.reason, .nextUp, "S1E1 finished: the next episode")
        eq(card?.mediaID, "tt0903747-s1e2", "S1E2")
        eq(card?.episodeTitle, "Cat's in the Bag...", "its title, from the guide")
        eq(card?.progress, 0, "not started")
        eq(card?.remaining, 49 * 60, "a whole episode left, from the runtime")
        eq(card?.title, "Breaking Bad", "the show's title carries over")

        // S1E2 finished: S1E3 airs on the 12th.
        clock.advance(1800)
        library.setWatched(true, id: "tt0903747-s1e2", list: .episodes)
        check(library.continueWatching().isEmpty, "the next episode has not aired: no card")
        eq(library.resume.entries(ofShow: "tt0903747").map { $0.mediaID }, ["tt0903747-s1e2"], "one finished entry per show")
        clock.now = F.date("2026-11-12T05:00:01Z")
        eq(cards(library), ["tt0903747-s1e3:nextUp"], "once it has aired: the card is back, without any write")
    }

    // MARK: - Thresholds, expiry

    func testThresholds() {
        let clock = F.Clock("2026-11-10T20:00:00Z")
        let library = self.library(clock: clock)
        library.setProgress(0.01, id: "tt0816692", list: .movies)
        check(cards(library).isEmpty, "1 % and no position: only opened")
        check(library.progress("tt0816692") == 0.01, "…though the position is saved (the page resumes)")
        library.setProgress(0.01, id: "tt0816692", list: .movies, details: PlaybackDetails(position: 61, duration: 10140))
        eq(cards(library), ["tt0816692:resume"], "61 s played: started")
        library.setProgress(0.02, id: "tt15239678", list: .movies)
        eq(Set(cards(library)), ["tt0816692:resume", "tt15239678:resume"], "2 %: started")

        check(!library.setProgress(0.79, id: "tt15239678", list: .movies), "0.79 does not mark watched")
        check(!library.isWatched("tt15239678") && cards(library).contains("tt15239678:resume"), "0.79: still in the row")
        check(library.setProgress(0.80, id: "tt15239678", list: .movies), "0.80 marks watched")
        check(library.isWatched("tt15239678") && !cards(library).contains("tt15239678:resume"), "0.80: watched, out of the row")
        check(library.resume.entry("tt15239678") == nil, "a watched movie has no entry")
        eq(library.progress("tt15239678"), 0.80, "its position stays (a resume below 95 %)")
        check(!library.setProgress(0.85, id: "tt15239678", list: .movies), "already watched: not marked again")

        eq(library.policy.watchedFraction, 0.80, "watched at 0.80")
        check(library.policy.isStarted(progress: 0.02, position: nil) && !library.policy.isStarted(progress: 0.019, position: 59)
              && library.policy.isStarted(progress: 0, position: 60), "started: 2 % or 60 s")
    }

    func testACardLeavesTheRowAfter90Days() {
        let clock = F.Clock("2026-01-01T20:00:00Z")
        let library = self.library(clock: clock)
        library.setProgress(0.4, id: "tt0816692", list: .movies)
        clock.advance(90 * 86400)
        eq(cards(library), ["tt0816692:resume"], "90 days later: still there")
        clock.advance(1)
        check(cards(library).isEmpty, "one second more: gone from the row")
        check(library.progress("tt0816692") == 0.4 && library.resume.entry("tt0816692") != nil, "the position is kept")
    }

    func testTheEntriesStayBounded() {
        var policy = LibraryPolicy()
        policy.maxEntries = 5
        let clock = F.Clock("2026-11-01T20:00:00Z")
        let storage = MemoryLibraryStorage()
        let library = self.library(storage, clock: clock, policy: policy)
        for index in 1...8 {
            clock.advance(60)
            library.setProgress(0.3, id: "tt000000\(index)", list: .movies)
        }
        eq(library.resume.allEntries().map { $0.mediaID }, ["tt0000008", "tt0000007", "tt0000006", "tt0000005", "tt0000004"],
           "the five most recently played are kept")
        eq((storage.object(forKey: "moviesProgress") as? [String: Float])?.count, 8, "the positions are all kept")
        // A full store with its titles fits comfortably in UserDefaults (tvOS: 1 MB for the whole domain).
        let bigStorage = MemoryLibraryStorage()
        let big = self.library(bigStorage, clock: clock)
        eq(big.policy.maxEntries, 200, "200 entries at most")
        for index in 0..<300 {
            clock.advance(1)
            big.setProgress(0.3, id: "tt\(1_000_000 + index)-s\(index % 9 + 1)e\(index % 23 + 1)", list: .episodes,
                            details: PlaybackDetails(title: "A Show With A Fairly Long Title \(index)", episodeTitle: "An Episode Title Of Usual Length",
                                                     runtime: 45, position: 600, duration: 2700))
        }
        eq(big.resume.allEntries().count, 200, "300 titles played: the 200 most recent have an entry")
        let bytes = (bigStorage.object(forKey: ContinueWatchingStore.storageKey) as? Data)?.count ?? .max
        check(bytes < 50_000, "…in less than 50 KB", "\(bytes) bytes")
        print("ContinueWatchingTests: 200 entries = \(bytes) bytes")
    }

    // MARK: - Removal

    func testRemovingCards() {
        let clock = F.Clock("2026-11-10T20:00:00Z")
        let library = self.library(clock: clock)
        library.setProgress(0.3, id: "tt0816692", list: .movies)
        clock.advance(60)
        library.setWatched(true, id: "tt0903747-s1e1", list: .episodes)
        clock.advance(60)
        library.setProgress(0.4, id: "tt0903747-s1e2", list: .episodes)
        clock.advance(60)
        library.setProgress(0.2, id: "tt0903747-s1e5", list: .episodes)
        eq(cards(library), ["tt0903747-s1e5:resume", "tt0816692:resume"], "a movie and a show")

        library.removeFromContinueWatching(library.continueWatching()[1])
        eq(cards(library), ["tt0903747-s1e5:resume"], "the movie's card is gone")
        check(library.progress("tt0816692") == 0, "…with its saved position")

        library.removeFromContinueWatching(library.continueWatching()[0])
        check(cards(library).isEmpty, "the show's card is gone, and no other episode of it takes the place")
        check(library.progress("tt0903747-s1e5") == 0, "the episode shown loses its position")
        check(library.progress("tt0903747-s1e2") == 0.4, "the others keep theirs (the page still shows them)")
        check(library.isWatched("tt0903747-s1e1"), "watched marks stay")

        // Unwatching deletes the position too (as it always did), and the entry.
        library.setProgress(0.9, id: "tt0944947-s1e1", list: .episodes)
        check(library.isWatched("tt0944947-s1e1"), "watched at 0.9")
        check(library.setWatched(false, id: "tt0944947-s1e1", list: .episodes), "unwatched")
        check(!library.isWatched("tt0944947-s1e1") && library.progress("tt0944947-s1e1") == 0 && library.resume.entry("tt0944947-s1e1") == nil,
              "no mark, no position, no entry")
        // A progress of 0 deletes the position and the entry.
        library.setProgress(0.3, id: "tt15239678", list: .movies)
        library.setProgress(0, id: "tt15239678", list: .movies)
        check(library.progress("tt15239678") == 0 && library.resume.entry("tt15239678") == nil, "0 removes")
    }

    // MARK: - Titles asked once

    func testTitlesKnownByIdAreHydratedOnce() {
        let clock = F.Clock("2026-11-14T12:00:00Z")
        let storage = MemoryLibraryStorage([
            "moviesProgress": ["tt15239678": Float(0.37)] as [String: Any],
            "episodesProgress": ["tt0903747-s1e1": Float(0.95)] as [String: Any],
            "episodesWatchedlist": ["tt0903747-s1e1"],
        ])
        var asked: [String] = []
        let remote = LibraryRemote(calendar: { _, done in done(nil) }, tvmazeGuide: { _, done in done(.unreachable) }, title: { id, kind, done in
            asked.append("\(kind.rawValue)/\(id)")
            done(self.recordedTitle(id, kind))
        })
        let center = NotificationCenter()
        let library = self.library(storage, clock: clock, remote: remote, center: center)

        eq(cards(library), ["tt15239678:resume"], "before: the movie, without a title; the show has no guide, so no next episode")
        check(library.continueWatching().first?.title == nil, "no title yet")
        eq(library.titlesToHydrate().map { $0.imdbID }.sorted(), ["tt0903747", "tt15239678"], "two titles to ask")

        var posted: [Notification] = []
        let token = center.addObserver(forName: .libraryDidChange, object: library, queue: nil) { posted.append($0) }
        defer { center.removeObserver(token) }
        let done = expectation(description: "hydrated")
        library.hydrateMissingTitles { changed in
            check(changed, "something was filled in")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        eq(asked.sorted(), ["episode/tt0903747", "movie/tt15239678"], "one request per title")
        let items = library.continueWatching()
        eq(Set(items.map { "\($0.mediaID):\($0.reason.rawValue)" }), ["tt15239678:resume", "tt0903747-s1e2:nextUp"],
           "after: the show's next episode has a card too")
        let movie = items.first { $0.kind == .movie }
        eq(movie?.title, "Dune: Part Two", "the movie's title")
        eq(movie?.runtime, 167, "its runtime")
        check(abs((movie?.remaining ?? 0) - 6312.6) < 0.01, "so the time left is known: 63 % of 167 min", "\(String(describing: movie?.remaining))")
        let show = items.first { $0.kind == .show }
        eq(show?.title, "Breaking Bad", "the show's title")
        eq(show?.episodeTitle, "Cat's in the Bag...", "the next episode's title, from the guide")
        eq(library.resume.entry("tt0903747-s1e1")?.episodeTitle, "Pilot", "the finished episode got its title too")
        check(posted.contains { LibraryChange.reason(of: $0) == .continueWatching && LibraryChange.ids(of: $0) == ["tt15239678", "tt0903747"] },
              "one change notification names both titles")
        check(library.titlesToHydrate().isEmpty, "nothing left to ask")

        // A second pass asks nothing; a new library on the same storage has the titles without asking.
        let again = expectation(description: "second pass")
        library.hydrateMissingTitles { changed in
            check(!changed, "nothing to do")
            again.fulfill()
        }
        wait(for: [again], timeout: 5)
        eq(asked.count, 2, "no request the second time")
        let relaunched = self.library(storage, clock: clock, remote: .offline)
        eq(relaunched.continueWatching(kinds: [.movie]).first?.title, "Dune: Part Two", "the title is stored with the entry")
    }

    func testATitleThatCouldNotBeAskedAboutIsAskedAgain() {
        // The first launch of 5.3 with the network not up yet: the request fails. (The title was
        // marked "asked" before the request and never asked again in the session.)
        let clock = F.Clock("2026-11-14T12:00:00Z")
        let storage = MemoryLibraryStorage(["moviesProgress": ["tt15239678": Float(0.37), "tt0000404": Float(0.5)] as [String: Any]])
        var online = false
        var asked: [String] = []
        let remote = LibraryRemote(calendar: { _, done in done(nil) }, tvmazeGuide: { _, done in done(.unreachable) }, title: { id, kind, done in
            asked.append(id)
            guard online else { return done(.unreachable) }
            done(id == "tt15239678" ? self.recordedTitle(id, kind) : .unknown)
        })
        let library = self.library(storage, clock: clock, remote: remote)

        check(!hydrate(library), "offline: nothing changed")
        eq(asked.sorted(), ["tt0000404", "tt15239678"], "both titles were asked")
        check(library.continueWatching().allSatisfy { $0.title == nil }, "no title yet")
        eq(library.titlesToHydrate().count, 2, "both are still to ask")

        online = true
        check(hydrate(library), "online: the title came")
        eq(asked.count, 4, "both were asked again")
        eq(library.continueWatching().first { $0.imdbID == "tt15239678" }?.title, "Dune: Part Two", "the movie has its title")
        // Cinemeta answered that it does not have the other one: that is an answer.
        check(!hydrate(library), "nothing more to learn")
        eq(asked.count, 4, "a title Cinemeta does not have is not asked again")
    }

    func testEveryTitleIsAskedBatchAfterBatch() {
        // 30 movies known by id only, 12 asked at a time: one call names them all. (The next batch
        // waited for the caller to ask again: the Home feed named 12 titles per refresh.)
        let clock = F.Clock("2026-11-14T12:00:00Z")
        let ids = (1...30).map { "tt00001\($0 < 10 ? "0" : "")\($0)" }
        let storage = MemoryLibraryStorage(["moviesProgress": Dictionary(uniqueKeysWithValues: ids.map { ($0, Float(0.3)) }) as [String: Any]])
        let lock = NSLock()
        var online = true
        var batches: [Int] = []
        var pending = 0
        let remote = LibraryRemote(calendar: { _, done in done(nil) }, tvmazeGuide: { _, done in done(.unreachable) }, title: { id, _, done in
            lock.lock(); pending += 1; let answers = online; lock.unlock()
            done(answers ? .found(LibraryRemote.Title(imdbID: id, title: "Movie \(id)", runtime: 100)) : .unreachable)
        })
        let center = NotificationCenter()
        let library = self.library(storage, clock: clock, remote: remote, center: center)
        let token = center.addObserver(forName: .libraryDidChange, object: library, queue: nil) { _ in
            lock.lock(); batches.append(pending); pending = 0; lock.unlock()
        }
        defer { center.removeObserver(token) }

        check(hydrate(library), "the titles came")
        eq(batches, [12, 12, 6], "three batches, a change notification after each")
        let named = library.continueWatching(limit: 30)
        check(named.count == 30 && named.allSatisfy { $0.title == "Movie \($0.imdbID)" }, "every card has its title")
        check(library.titlesToHydrate().isEmpty, "nothing left to ask")

        // Nobody answers: the pass stops at its first batch instead of asking for everything.
        let offline = self.library(MemoryLibraryStorage(["moviesProgress": Dictionary(uniqueKeysWithValues: ids.map { ($0, Float(0.3)) }) as [String: Any]]),
                                   clock: clock, remote: remote)
        online = false
        pending = 0
        check(!hydrate(offline), "offline: nothing changed")
        eq(pending, 12, "one batch was asked, not the thirty titles")
        eq(offline.titlesToHydrate().count, 30, "they are all still to ask")
    }

    // MARK: - A show's next episode takes a guide that says what follows

    func testACalendarWindowDoesNotSayWhatFollowsAnOldEpisode() {
        // Breaking Bad S1E3 finished, saved by a player (titles and all); its guide is gone (tvOS
        // purged Caches). The calendar then answers the ten episodes around today: S5E7…S5E16.
        let clock = F.Clock("2026-11-14T15:40:00Z")
        var metaAnswers = false
        var asked: [String] = []
        let remote = LibraryRemote(calendar: { ids, done in
            let known = LibraryRemote.guides(fromCinemetaCalendar: Fixtures.data("Library/cm_calendar_videos.json")) ?? []
            done(known.filter { ids.contains($0.showID) })
        }, tvmazeGuide: { _, done in done(.unreachable) }, title: { id, kind, done in
            asked.append(id)
            done(metaAnswers && id == "tt0903747" ? self.recordedTitle(id, kind) : .unreachable)
        })
        let library = self.library(clock: clock, remote: remote)
        library.setProgress(0.95, id: "tt0903747-s1e3", list: .episodes,
                            details: PlaybackDetails(title: "Breaking Bad", episodeTitle: "...And the Bag's in the River", runtime: 49))
        // A show Cinemeta's calendar has nothing for: an empty guide is stored for it.
        library.setProgress(0.95, id: "tt7654321-s1e1", list: .episodes, details: PlaybackDetails(title: "Unlisted", episodeTitle: "One"))
        check(cards(library).isEmpty, "no guide: no next episode yet")
        eq(library.titlesToHydrate().map { $0.imdbID }.sorted(), ["tt0903747", "tt7654321"], "both guides are to ask")

        let refreshed = expectation(description: "refreshed")
        library.refreshNewEpisodes { _ in refreshed.fulfill() }
        wait(for: [refreshed], timeout: 5)
        let window = library.guides.guide("tt0903747")
        check(window?.isComplete == false && window?.episodes.first?.number == F.number(5, 7), "the calendar's window starts at S5E7")
        check(library.guides.guide("tt7654321")?.episodes.isEmpty == true, "…and the other show has an empty guide")
        check(cards(library).isEmpty, "S5E7 is not what follows S1E3: still no card", cards(library).joined(separator: " "))
        eq(library.titlesToHydrate().map { $0.imdbID }.sorted(), ["tt0903747", "tt7654321"],
           "a window that does not hold the episode, or an empty one, is no guide: both are still to ask")

        // The meta request fails once (it was then never made again), then answers.
        check(!hydrate(library) && asked.count == 2, "asked, no answer")
        metaAnswers = true
        check(hydrate(library), "the whole guide came")
        eq(cards(library), ["tt0903747-s1e4:nextUp"], "S1E4 follows S1E3")
        eq(library.continueWatching().first?.episodeTitle, "Cancer Man", "…with its title")
        eq(library.titlesToHydrate().map { $0.imdbID }, ["tt7654321"], "only the show nobody knows is left")

        // A window that holds the episode says what follows it (NewEpisodesTests: MobLand S2E8 → S2E9).
        let guide = ShowGuide(showID: "tt1", episodes: [F.episode(5, 7), F.episode(5, 8)], source: .cinemeta)
        check(!guide.isComplete && guide.knowsWhatFollows(F.number(5, 7)) && !guide.knowsWhatFollows(F.number(1, 3)),
              "a window knows what follows its own episodes only")
        check(ShowGuide(showID: "tt1", episodes: [F.episode(1, 1)], source: .provider).knowsWhatFollows(F.number(4, 2)),
              "a complete guide knows what follows any episode")
    }

    // MARK: - What moves a show, what does not

    /// A show of eight aired episodes, its guide known.
    private func showLibrary(clock: F.Clock) -> Library {
        let library = self.library(clock: clock)
        library.noteGuide(showID: "tt7654321", title: "Test Show",
                          episodes: (1...8).map { F.episode(1, $0, aired: "2020-01-0\($0)T20:00:00Z", title: "Episode \($0)") }, always: true)
        return library
    }

    func testAWatchedEpisodeOnlyOpenedDoesNotMoveItsShow() {
        let clock = F.Clock("2026-11-10T20:00:00Z")
        let library = showLibrary(clock: clock)
        for episode in [1, 2, 4, 5, 6] {
            clock.advance(3600)
            library.setProgress(0.9, id: "tt7654321-s1e\(episode)", list: .episodes)
        }
        eq(cards(library), ["tt7654321-s1e7:nextUp"], "S1E6 was finished last: S1E7 is next")
        let finishedAt = clock.now

        // S1E1 opened again for five seconds (a player saves once it has a position).
        clock.advance(86400)
        check(!library.setProgress(0.002, id: "tt7654321-s1e1", list: .episodes, details: PlaybackDetails(position: 5, duration: 2700)),
              "already watched: not marked again")
        eq(cards(library), ["tt7654321-s1e7:nextUp"], "five seconds of a watched episode do not move the show")
        eq(library.progress("tt7654321-s1e1"), 0.002, "its position is saved all the same")
        eq(library.resume.entries(ofShow: "tt7654321").map { $0.mediaID }, ["tt7654321-s1e6"], "the show's finished entry is still S1E6")
        eq(library.continueWatching().first?.updatedAt, finishedAt, "…and the card keeps its date")
        // The show's page follows the same episodes.
        var show = Show(title: "Test Show", id: "tt7654321")
        show.episodes = (1...8).map { Episode(title: "Episode \($0)", id: "tt7654321-s1e\($0)", show: show, episode: $0, season: 1,
                                              firstAirDate: F.date("2020-01-0\($0)T20:00:00Z")) }
        eq(show.watchPosition(now: clock.now, library: library).nextUp?.episode.id, "tt7654321-s1e7", "the page's Play is S1E7 too")
        // The same five seconds on an episode not watched: no card of its own either.
        library.setProgress(0.002, id: "tt7654321-s1e8", list: .episodes, details: PlaybackDetails(position: 5, duration: 2700))
        eq(cards(library), ["tt7654321-s1e7:nextUp"], "an episode only opened does not move the show")

        // Played on, a watched episode is where the user is: by the fraction…
        clock.advance(60)
        library.setProgress(0.03, id: "tt7654321-s1e1", list: .episodes, details: PlaybackDetails(duration: 2700))
        eq(cards(library), ["tt7654321-s1e3:nextUp"], "S1E1 watched again: on with the first episode not watched after it")
        eq(library.resume.entries(ofShow: "tt7654321").filter { $0.isFinished }.map { $0.mediaID }, ["tt7654321-s1e1"], "one finished entry per show")
        // …or by the time played, which a player gives as a duration.
        clock.advance(60)
        library.setProgress(0.01, id: "tt7654321-s1e4", list: .episodes, details: PlaybackDetails(duration: 7200))
        eq(cards(library), ["tt7654321-s1e7:nextUp"], "72 s of S1E4 count, whatever the fraction")

        // A show entirely watched has no card, and five seconds of one of its episodes make none.
        let seen = showLibrary(clock: clock)
        for episode in 1...8 {
            clock.advance(60)
            seen.setWatched(true, id: "tt7654321-s1e\(episode)", list: .episodes)
        }
        check(cards(seen).isEmpty, "everything watched: no card")
        clock.advance(86400)
        seen.setProgress(0.002, id: "tt7654321-s1e4", list: .episodes, details: PlaybackDetails(position: 5, duration: 2700))
        check(cards(seen).isEmpty, "S1E4 opened for five seconds: still no card", cards(seen).joined(separator: " "))
        eq(show.watchPosition(now: clock.now, library: seen).nextUp?.reason, .start, "…and the page still starts over")
    }

    func testUnmarkingTheLastEpisodeFinishedKeepsTheShow() {
        let clock = F.Clock("2026-11-10T20:00:00Z")
        let library = showLibrary(clock: clock)
        library.setWatched(true, id: "tt7654321-s0e1", list: .episodes)   // a special
        for episode in 1...5 {
            clock.advance(3600)
            library.setWatched(true, id: "tt7654321-s1e\(episode)", list: .episodes,
                               details: PlaybackDetails(title: "Test Show", episodeTitle: "Episode \(episode)", runtime: 45))
        }
        let markedAt = clock.now
        eq(cards(library), ["tt7654321-s1e6:nextUp"], "five episodes watched: S1E6 is next")
        eq(library.followedShowIDs(), ["tt7654321"], "the show is followed")

        // An older episode un-marked: the show's entry is not concerned.
        clock.advance(3600)
        library.setWatched(false, id: "tt7654321-s1e2", list: .episodes)
        eq(library.resume.entries(ofShow: "tt7654321").map { $0.mediaID }, ["tt7654321-s1e5"], "still S1E5")

        // The last one un-marked (it was not really watched): the show goes back one episode.
        check(library.setWatched(false, id: "tt7654321-s1e5", list: .episodes), "un-marked")
        eq(cards(library), ["tt7654321-s1e5:nextUp"], "S1E5 is next again (the card was gone, and the show no longer followed)")
        eq(library.followedShowIDs(), ["tt7654321"], "the show is still followed")
        eq(library.followedShows().first?.reached, F.number(1, 4), "…reached S1E4")
        let entry = library.resume.entry("tt7654321-s1e4")
        check(entry?.isFinished == true && entry?.updatedAt == markedAt, "S1E4 is the show's finished entry now, with the date of the one removed")
        check(entry?.title == "Test Show" && entry?.runtime == 45, "…and the show's title and runtime")
        eq(library.continueWatching().first?.title, "Test Show", "the card keeps its title")
        check(!library.isWatched("tt7654321-s1e5") && library.resume.entry("tt7654321-s1e5") == nil, "S1E5: no mark, no entry")

        // Down to nothing watched but the special: no entry, no card, not followed.
        for episode in [4, 3, 1] { library.setWatched(false, id: "tt7654321-s1e\(episode)", list: .episodes) }
        check(library.resume.entries(ofShow: "tt7654321").isEmpty && cards(library).isEmpty, "nothing watched: no entry, no card")
        check(library.followedShowIDs().isEmpty && library.isWatched("tt7654321-s0e1"), "…the show is not followed; its special keeps its mark")
    }
}
