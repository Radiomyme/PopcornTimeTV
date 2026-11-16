//
//  LibraryWatchStateTests.swift
//  PopcornTimeTests
//
//  The watched / progress / watchlist lists served from memory (PopcornKit, WatchStateStore
//  behind Library): one read of the storage however many lookups, write-through in the shapes
//  4.x / 5.x wrote, the change notification, and the Episode JSON round trip.
//

import Foundation
import XCTest
import ObjectMapper
@testable import PopcornKit

/// A storage that counts what is asked of it.
private final class CountingStorage: LibraryStorage {
    var values: [String: Any]
    private(set) var reads: [String: Int] = [:]
    private(set) var writes: [String: Int] = [:]

    init(_ values: [String: Any] = [:]) { self.values = values }

    func object(forKey key: String) -> Any? {
        reads[key, default: 0] += 1
        return values[key]
    }

    func set(_ value: Any?, forKey key: String) {
        writes[key, default: 0] += 1
        values[key] = value
    }
}

final class LibraryWatchStateTests: CheckedTestCase {

    private typealias F = LibraryFixtures

    private func history(episodes: Int) -> [String: Any] {
        let ids = (0..<episodes).map { "tt\(1_000_000 + $0 / 100)-s\($0 / 20 % 5 + 1)e\($0 % 20 + 1)" }
        var progress: [String: Any] = [:]
        for id in ids { progress[id] = Float(0.97) }
        return ["episodesWatchedlist": ids, "episodesProgress": progress]
    }

    // MARK: - The snapshot

    func testLookupsReadTheStorageOnce() {
        let storage = CountingStorage(history(episodes: 3000))
        let library = Library(storage: storage, guideDirectory: nil, remote: .offline, now: Date.init)
        // A show page: watched and progress of every episode, several times over.
        var watched = 0
        for _ in 0..<6 {
            for episode in 0..<800 {
                let id = "tt1000007-s\(episode / 20 % 5 + 1)e\(episode % 20 + 1)"
                if library.isWatched(id, .episodes) { watched += 1 }
                _ = library.progress(id, .episodes)
            }
        }
        eq(watched, 6 * 800, "the lookups answer")
        eq(storage.reads["episodesWatchedlist"], 1, "9,600 lookups: the watched list was read once")
        eq(storage.reads["episodesProgress"], 1, "…and the progress dictionary once")
        check(storage.writes.isEmpty, "reading writes nothing")
        // The public lookup (movie or episode) reads the movie lists once too.
        for _ in 0..<50 { _ = library.isWatched("tt0816692"); _ = library.progress("tt0816692") }
        eq(storage.reads["moviesWatchedlist"], 1, "the movie watched list: once")
        eq(storage.reads["moviesProgress"], 1, "the movie progress: once")
    }

    func testAWriteUpdatesTheSnapshotAndTheStorage() {
        let storage = CountingStorage(["moviesWatchedlist": ["tt0468569"], "moviesProgress": ["tt0468569": Float(0.9)] as [String: Any]])
        let library = Library(storage: storage, guideDirectory: nil, remote: .offline, now: Date.init)
        check(library.isWatched("tt0468569") && !library.isWatched("tt0816692"), "the stored state")

        library.setProgress(0.4, id: "tt0816692", list: .movies)
        eq(library.progress("tt0816692"), 0.4, "the snapshot has the new progress at once")
        eq(storage.values["moviesProgress"] as? [String: Float], ["tt0468569": 0.9, "tt0816692": 0.4], "…and the storage too, as [String: Float]")

        check(library.setWatched(true, id: "tt0816692", list: .movies), "marked")
        check(!library.setWatched(true, id: "tt0816692", list: .movies), "marking twice changes nothing")
        check(library.isWatched("tt0816692"), "the snapshot has the mark")
        eq(storage.values["moviesWatchedlist"] as? [String], ["tt0468569", "tt0816692"], "the storage too, as [String], in the order marked")

        check(library.setWatched(false, id: "tt0468569", list: .movies), "unmarked")
        check(!library.isWatched("tt0468569") && library.progress("tt0468569") == 0, "no mark, no progress")
        eq(storage.values["moviesWatchedlist"] as? [String], ["tt0816692"], "removed from the stored list")
        eq(storage.values["moviesProgress"] as? [String: Float], ["tt0816692": 0.4], "…and from the stored progress")
        eq(storage.reads["moviesWatchedlist"], 1, "all along, the list was read once")
        eq(storage.reads["moviesProgress"], 1, "…and the progress once")
    }

    func testInvalidationReadsTheStorageAgain() {
        let storage = CountingStorage(["moviesWatchedlist": ["tt0468569"]])
        let library = Library(storage: storage, guideDirectory: nil, remote: .offline, now: Date.init)
        check(library.isWatched("tt0468569"), "loaded")
        // Something else writes the storage (a restore, a debug hook): the snapshot does not know…
        storage.values["moviesWatchedlist"] = ["tt0816692"]
        storage.values["moviesProgress"] = ["tt0816692": Float(0.5)]
        check(library.isWatched("tt0468569") && !library.isWatched("tt0816692"), "the snapshot is still the old one")
        // …until it is told.
        library.reloadFromStorage()
        check(!library.isWatched("tt0468569") && library.isWatched("tt0816692") && library.progress("tt0816692") == 0.5,
              "after reloadFromStorage: the new content")
        eq(storage.reads["moviesWatchedlist"], 2, "read a second time")
    }

    func testAnUnchangedWriteDoesNotTouchTheStorage() {
        let storage = CountingStorage()
        let state = WatchStateStore(storage: storage)
        check(state.setProgress(0.4, "tt0816692", .movies), "a new progress is written")
        check(!state.setProgress(0.4, "tt0816692", .movies), "the same value is not written again")
        check(!state.setProgress(nil, "tt0000001", .movies), "deleting what is not there neither")
        check(!state.setWatched(false, "tt0000001", .movies), "nor unmarking what is not marked")
        eq(storage.writes["moviesProgress"], 1, "one write in all")
        check(storage.writes["moviesWatchedlist"] == nil, "the watched list was never written")
    }

    // MARK: - Watchlist

    func testWatchlist() {
        let dune: [String: Any] = ["imdb_id": "tt15239678", "title": "Dune: Part Two", "year": "2024",
                                   "images": ["poster": "https://img.example/dune.jpg"]]
        // 5.2 appended without looking: the same title twice.
        let storage = CountingStorage(["moviesWatchlist": [dune, dune, ["imdb_id": "tt0816692", "title": "Interstellar", "year": "2014"]]])
        let library = Library(storage: storage, guideDirectory: nil, remote: .offline, now: Date.init)
        check(library.isInWatchlist("tt15239678") && library.isInWatchlist("tt0816692") && !library.isInWatchlist("tt0468569"), "membership")
        eq(library.watchlist(.movie).map { $0.imdbID }, ["tt0816692", "tt15239678"], "each title once, the latest added first")
        eq(library.watchlist(.movie)[1].posterURL?.absoluteString, "https://img.example/dune.jpg", "the stored poster")
        eq(library.watchlist(.movie)[1].year, "2024", "the stored year")
        for _ in 0..<500 { _ = library.isInWatchlist("tt15239678") }
        eq(storage.reads["moviesWatchlist"], 1, "500 lookups: the list was read once (5.2 rebuilt every model each time)")

        check(!library.addToWatchlist(dune, id: "tt15239678", list: .movies), "adding a title already there changes nothing")
        check(library.addToWatchlist(["imdb_id": "tt0468569", "title": "The Dark Knight"], id: "tt0468569", list: .movies), "a new title is added")
        check(library.removeFromWatchlist(id: "tt15239678", list: .movies), "removed")
        check(!library.isInWatchlist("tt15239678"), "…both stored copies")
        eq((storage.values["moviesWatchlist"] as? [[String: Any]])?.compactMap { $0["imdb_id"] as? String }, ["tt0816692", "tt0468569"],
           "the stored list: the two titles left, as dictionaries")

        // The models are decoded once per change of the list.
        var decodes = 0
        func models() -> [String] {
            return library.state.watchlistModels(.movies) { json -> [String] in
                decodes += 1
                return json.compactMap { $0["title"] as? String }
            }
        }
        eq(models(), ["Interstellar", "The Dark Knight"], "decoded")
        _ = models(); _ = models()
        eq(decodes, 1, "decoded once for three reads")
        library.removeFromWatchlist(id: "tt0468569", list: .movies)
        eq(models(), ["Interstellar"], "decoded again after a change")
        eq(decodes, 2, "…once")
    }

    func testAWatchlistEntryAddedBeforeItsRecordIsCompletedByIt() {
        // Added from a link's page before its record: an id and an empty title.
        let storage = CountingStorage(["moviesWatchlist": [["imdb_id": "tt0816692", "title": "Interstellar", "year": "2014"],
                                                           ["imdb_id": "tt15239678", "title": "", "genres": [String](),
                                                            "images": ["poster": "https://img.example/card.jpg"]]]])
        let library = Library(storage: storage, guideDirectory: nil, remote: .offline, now: Date.init)
        let record: [String: Any] = ["imdb_id": "tt15239678", "title": "Dune: Part Two", "year": "2024", "genres": ["Sci-Fi"],
                                     "rating": 8.5, "images": ["poster": "https://img.example/record.jpg",
                                                               "fanart": "https://img.example/fanart.jpg"]]
        check(library.completeWatchlistEntry(record, id: "tt15239678", list: .movies), "the record fills the entry")
        let stored = storage.values["moviesWatchlist"] as? [[String: Any]] ?? []
        eq(stored.compactMap { $0["imdb_id"] as? String }, ["tt0816692", "tt15239678"], "in its place in the list")
        eq(stored.last?["title"] as? String, "Dune: Part Two", "its title")
        eq(stored.last?["year"] as? String, "2024", "its year")
        eq(stored.last?["genres"] as? [String], ["Sci-Fi"], "its genres")
        eq(stored.last?["images"] as? [String: String], ["poster": "https://img.example/card.jpg", "fanart": "https://img.example/fanart.jpg"],
           "the artwork it lacked; the poster it had is kept")
        eq(library.watchlist(.movie).first?.title, "Dune: Part Two", "the Watchlist's card has its title")

        check(!library.completeWatchlistEntry(record, id: "tt15239678", list: .movies), "complete: nothing changes the second time")
        check(!library.completeWatchlistEntry(["imdb_id": "tt0816692", "title": "Interstellar (2014)", "year": "2015"],
                                              id: "tt0816692", list: .movies), "what an entry holds is kept")
        eq((storage.values["moviesWatchlist"] as? [[String: Any]])?.first?["year"] as? String, "2014", "its year unchanged")
        check(!library.completeWatchlistEntry(record, id: "tt0468569", list: .movies), "a title not in the list is not added")
        check(!library.isInWatchlist("tt0468569"), "…as said")
    }

    // MARK: - Change notification

    func testChangeNotification() {
        let center = NotificationCenter()
        let library = Library(storage: MemoryLibraryStorage(), guideDirectory: nil, remote: .offline, center: center, now: Date.init)
        var posted: [(reason: LibraryChange.Reason?, ids: Set<String>, onMain: Bool)] = []
        let token = center.addObserver(forName: .libraryDidChange, object: library, queue: nil) { note in
            posted.append((LibraryChange.reason(of: note), LibraryChange.ids(of: note), Thread.isMainThread))
        }
        defer { center.removeObserver(token) }

        library.setProgress(0.3, id: "tt0903747-s1e1", list: .episodes)
        eq(posted.count, 1, "one notification per write")
        check(posted[0].reason == .progress && posted[0].ids == ["tt0903747-s1e1", "tt0903747"], "a progress: the episode and its show")
        library.setProgress(0.9, id: "tt0903747-s1e1", list: .episodes)
        check(posted[1].reason == .watched, "0.9: the title became watched")
        library.setWatched(false, id: "tt0903747-s1e1", list: .episodes)
        check(posted[2].reason == .watched && posted[2].ids.contains("tt0903747"), "unwatched")
        library.addToWatchlist(["imdb_id": "tt15239678"], id: "tt15239678", list: .movies)
        check(posted[3].reason == .watchlist && posted[3].ids == ["tt15239678"], "watchlist")
        library.addToWatchlist(["imdb_id": "tt15239678"], id: "tt15239678", list: .movies)
        eq(posted.count, 4, "nothing changed: nothing posted")

        // From another thread: still delivered on the main thread.
        let delivered = expectation(description: "delivered")
        let extra = center.addObserver(forName: .libraryDidChange, object: library, queue: nil) { note in
            if LibraryChange.ids(of: note).contains("tt0816692") { delivered.fulfill() }
        }
        defer { center.removeObserver(extra) }
        DispatchQueue.global().async { library.setProgress(0.5, id: "tt0816692", list: .movies) }
        wait(for: [delivered], timeout: 5)
        check(posted.allSatisfy { $0.onMain }, "every notification was posted on the main thread")
    }

    // MARK: - Checkpoints

    func testPlaybackCheckpointIsDueEvery30Seconds() {
        var checkpoint = PlaybackCheckpoint()
        let start = F.date("2026-11-14T20:00:00Z")
        check(!checkpoint.isDue(now: start), "the first tick starts the clock")
        check(!checkpoint.isDue(now: start.addingTimeInterval(29.9)), "29.9 s: not yet")
        check(checkpoint.isDue(now: start.addingTimeInterval(30)), "30 s: due")
        check(!checkpoint.isDue(now: start.addingTimeInterval(31)), "…once")
        check(checkpoint.isDue(now: start.addingTimeInterval(60)), "30 s after the last one: due again")
        checkpoint.reset(now: start.addingTimeInterval(80))
        check(!checkpoint.isDue(now: start.addingTimeInterval(100)), "a save for another reason restarts the wait")
        check(checkpoint.isDue(now: start.addingTimeInterval(70)), "the clock went back: due, rather than waiting for it to catch up")
    }

    // MARK: - Models

    /// `Mapper<Episode>().mapArray(JSONArray: [toJSON(episode)])` gave an empty array for every
    /// episode since 5.0.0: `StringTransform` only wrote numeric ids.
    func testEpisodeJSONRoundTrip() {
        let show = Show(title: "Breaking Bad", id: "tt0903747")
        let episode = Episode(title: "Pilot", id: "tt0903747-s1e1", summary: "A teacher.", show: show, episode: 1, season: 1,
                              firstAirDate: F.date("2008-01-21T05:00:00Z"))
        let json = Mapper<Episode>().toJSON(episode)
        eq(json["tvdb_id"] as? String, "tt0903747-s1e1", "a 5.x id is written as it is")
        let back = Mapper<Episode>().mapArray(JSONArray: [json])
        eq(back.count, 1, "the episode comes back")
        eq(back.first?.id, "tt0903747-s1e1", "with its id")
        check(back.first?.season == 1 && back.first?.episode == 1 && back.first?.title == "Pilot"
              && back.first?.firstAirDate == episode.firstAirDate, "…and its season, number, title and air date")
        // An undated episode (.distantPast) too.
        let undated = Episode(title: "Episode 2", id: "tt0903747-s1e2", show: show, episode: 2, season: 1)
        eq(Mapper<Episode>().mapArray(JSONArray: [Mapper<Episode>().toJSON(undated)]).first?.id, "tt0903747-s1e2", "an undated episode comes back")
        // A 4.x TVDB number stays a number (an older build reads it), and still reads back.
        let legacy = Episode(title: "Pilot", id: "349232", show: show, episode: 1, season: 1)
        let legacyJSON = Mapper<Episode>().toJSON(legacy)
        eq(legacyJSON["tvdb_id"] as? Int, 349232, "a numeric id is written as a number")
        eq(Mapper<Episode>().map(JSON: legacyJSON)?.id, "349232", "…and read back")
        var negative = legacyJSON
        negative["tvdb_id"] = -349232
        eq(Mapper<Episode>().map(JSON: negative)?.id, "349232", "a negative number loses its sign, as in 4.x")
        // What the watchlist stores (a Show) is unchanged.
        let stored = Mapper<Show>().toJSON(show)
        eq(stored["imdb_id"] as? String, "tt0903747", "a show is stored under imdb_id")
        eq(Mapper<Show>().mapArray(JSONArray: [stored]).first?.id, "tt0903747", "…and comes back")
    }
}
