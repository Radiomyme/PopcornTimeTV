//
//  HomeCacheTests.swift
//  PopcornTimeTests
//
//  The Home's cache: fresh / stale / expired at their boundaries, the lifetime of each source,
//  "an incomplete refresh never replaces a fuller list", and the disk store (round trip,
//  expired lists, files that are not its own, small files). The clock and the folder are injected.
//

import Foundation
import XCTest
@testable import PopcornKit

final class HomeCacheTests: CheckedTestCase {

    private let now = HomeFixture.now
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    // MARK: Policy

    func testStatesAtTheirBoundaries() {
        let life = HomeCachePolicy.Lifetime(fresh: 4 * hour, usable: 7 * day)
        func state(age: TimeInterval, complete: Bool = true) -> HomeCachePolicy.State {
            HomeCachePolicy.state(savedAt: now.addingTimeInterval(-age), now: now, lifetime: life, complete: complete)
        }
        eq(state(age: 0), .fresh, "just saved")
        eq(state(age: 4 * hour - 1), .fresh, "3 h 59 min 59 s: fresh")
        eq(state(age: 4 * hour), .stale, "4 h: stale")
        eq(state(age: 4 * hour + 1), .stale, "4 h 00 min 01 s")
        eq(state(age: 7 * day - 1), .stale, "one second before 7 days: still shown")
        eq(state(age: 7 * day), .expired, "7 days: expired")
        eq(state(age: 30 * day), .expired, "long after")
        eq(state(age: -60), .stale, "saved \"in the future\" (the clock was set back): shown, asked again")
        eq(state(age: 0, complete: false), .stale, "an incomplete list is never fresh")
        eq(state(age: 7 * day, complete: false), .expired, "and expires like the others")
        // 23 h 59 and 24 h 01 of a list usable one day.
        let recent = HomeCachePolicy.Lifetime.ytsRecent
        eq(HomeCachePolicy.state(savedAt: now.addingTimeInterval(-(24 * hour - 60)), now: now, lifetime: recent), .stale, "23 h 59: shown")
        eq(HomeCachePolicy.state(savedAt: now.addingTimeInterval(-(24 * hour + 60)), now: now, lifetime: recent), .expired, "24 h 01: not shown")
    }

    func testLifetimeOfEachSource() {
        func life(_ source: HomeSource, at date: Date? = nil) -> HomeCachePolicy.Lifetime { HomeCachePolicy.lifetime(forKey: source.key, now: date ?? now) }
        let catalogue = HomeCachePolicy.Lifetime(fresh: 4 * hour, usable: 7 * day)
        for source in [HomeSource.movieTop, .seriesTop, .movieFeatured, .movieTopNext, .seriesYear(2026), .genre(.movie, "Action")] {
            eq(life(source), catalogue, "\(source.key): Cinemeta catalogs, 4 h / 7 days")
        }
        eq(life(HomeSource.calendar(ids: ["tt31510819"])!), HomeCachePolicy.Lifetime(fresh: 6 * hour, usable: 3 * day), "calendar-videos: 6 h / 3 days")
        eq(life(.ytsNew(2026)), HomeCachePolicy.Lifetime(fresh: 30 * 60, usable: day), "YTS additions: 30 min / 24 h")
        eq(life(.yts4K), HomeCachePolicy.Lifetime(fresh: 30 * 60, usable: day), "YTS 4K additions too")
        for source in [HomeSource.ytsYear(2026), .ytsTop(2026), .ytsLikes(2026)] {
            eq(life(source), HomeCachePolicy.Lifetime(fresh: 6 * hour, usable: 7 * day), "\(source.key): the year's rankings, 6 h / 7 days")
        }
        eq(life(.tvmaze(web: true, day: "2026-11-14")), HomeCachePolicy.Lifetime(fresh: hour, usable: day), "TVMaze, today: 1 h / 24 h")
        eq(life(.tvmaze(web: false, day: "2026-11-13")), HomeCachePolicy.Lifetime(fresh: day, usable: 7 * day), "TVMaze, a past day: 24 h / 7 days")
        eq(life(.tvmaze(web: true, day: "2026-11-14"), at: now.addingTimeInterval(day)), HomeCachePolicy.Lifetime(fresh: day, usable: 7 * day), "the same list tomorrow is a past day's")
        for source in [HomeSource.top48hShows, .top48hMovies, .topUHD] {
            eq(life(source), HomeCachePolicy.Lifetime(fresh: 2 * hour, usable: day), "\(source.key): apibay, 2 h / 24 h")
        }
        eq(life(.lookupShows(ids: ["tt0413573"])), HomeCachePolicy.Lifetime(fresh: 7 * day, usable: 7 * day), "lookups: 7 days")
        eq(life(.lookupMovie(id: "tt4154796")), HomeCachePolicy.Lifetime(fresh: 7 * day, usable: 7 * day), "movie lookups too")
        // The keys are file names: letters, digits and dashes.
        let every: [HomeSource] = [.movieTop, .seriesTop, .movieFeatured, .movieTopNext, .seriesYear(2026), .genre(.show, "Sci-Fi"),
                                   HomeSource.calendar(ids: ["tt31510819"])!, .ytsNew(2026), .yts4K, .ytsYear(2026), .ytsTop(2026), .ytsLikes(2026),
                                   .tvmaze(web: true, day: "2026-11-14"), .tvmaze(web: false, day: "2026-11-14"), .top48hShows, .top48hMovies, .topUHD,
                                   .lookupShows(ids: ["tt0413573"]), .lookupMovie(id: "tt4154796")]
        check(every.allSatisfy { $0.key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }, "keys are safe file names", "\(every.map(\.key))")
        eq(Set(every.map(\.key)).count, every.count, "and distinct")
        check(every.allSatisfy { $0.request.path.hasPrefix("/") }, "paths start with /")
        // A key names its service: what the store reads back, and what "this host was down" is told by.
        check(every.allSatisfy { HomeSource.host(ofKey: $0.key) == $0.request.host }, "every key starts with its service's prefix",
              "\(every.filter { HomeSource.host(ofKey: $0.key) != $0.request.host }.map(\.key))")
        check(HomeSource.host(ofKey: "down") == nil && HomeSource.host(ofKey: "settings") == nil, "another name is no list")
    }

    func testAnIncompleteRefreshNeverReplacesAFullerList() {
        typealias Decision = HomeCachePolicy.Decision
        func decide(_ count: Int, minimum: Int = 20, allowsEmpty: Bool = false, previous: Int? = nil) -> Decision {
            HomeCachePolicy.decision(count: count, minimum: minimum, allowsEmpty: allowsEmpty, previous: previous)
        }
        eq(decide(50, previous: 50), Decision(accept: true, complete: true), "a full answer replaces the list")
        eq(decide(20, previous: 50), Decision(accept: true, complete: true), "the expected size is enough, even shorter than before")
        eq(decide(19, previous: 50), Decision(accept: false, complete: false), "a short answer does not replace a fuller list")
        eq(decide(19, previous: 19), Decision(accept: true, complete: false), "it replaces one that is not fuller — and stays incomplete")
        eq(decide(19, previous: 12), Decision(accept: true, complete: false), "or shorter")
        eq(decide(19, previous: nil), Decision(accept: true, complete: false), "or when there is none (or it expired)")
        eq(decide(0, previous: nil), Decision(accept: false, complete: false), "an empty answer of a source that always has titles is a failure")
        eq(decide(0, previous: 50), Decision(accept: false, complete: false), "and never empties a list")
        // A day without episodes, a calendar without anything new: valid.
        eq(decide(0, minimum: 0, allowsEmpty: true, previous: 40), Decision(accept: true, complete: true), "an empty day is an answer")
        eq(decide(3, minimum: 0, allowsEmpty: true, previous: 40), Decision(accept: true, complete: true), "so is a short one")
        // The lists of one year: fewer than 30 is "incomplete" (January), nothing yet is still an answer…
        eq(decide(4, minimum: 30, allowsEmpty: true, previous: nil), Decision(accept: true, complete: false), "January: four movies of the year")
        eq(decide(0, minimum: 30, allowsEmpty: true, previous: nil), Decision(accept: true, complete: false), "the 1st of January: none")
        // …but a glitch does not wipe November's list.
        eq(decide(4, minimum: 30, allowsEmpty: true, previous: 50), Decision(accept: false, complete: false), "a short answer against a full year's list")
        eq(decide(0, minimum: 30, allowsEmpty: true, previous: 50), Decision(accept: false, complete: false), "an empty one too")
        eq(decide(30, minimum: 30, allowsEmpty: true, previous: 50), Decision(accept: true, complete: true), "thirty is a full list")
        // What each source expects.
        eq(HomeSource.movieTop.minimum, 20, "a Cinemeta page is about 50")
        check(HomeSource.ytsYear(2026).minimum == 30 && HomeSource.ytsYear(2026).allowsEmpty
              && HomeSource.seriesYear(2026).minimum == 30 && HomeSource.seriesYear(2026).allowsEmpty, "lists of one year")
        check(!HomeSource.movieTop.allowsEmpty && !HomeSource.top48hShows.allowsEmpty, "the others always have titles")
        check(HomeSource.yts4K.minimum == 20 && !HomeSource.yts4K.allowsEmpty, "the 4K additions are not bound to a year")
        check(HomeSource.tvmaze(web: true, day: "2026-11-14").allowsEmpty && HomeSource.tvmaze(web: true, day: "2026-11-14").minimum == 0, "a day's schedule")
    }

    // MARK: Disk

    func testStoreRoundTrip() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let store = HomeStore(directory: sandbox.directory.appendingPathComponent("home"), now: { self.now })
        eq(store.readAll().count, 0, "a folder that does not exist yet reads as empty")
        let lists = HomeFixture.allLists()
        for list in lists.values { store.write(list) }
        let read = HomeStore(directory: store.directory, now: { self.now }).readAll()
        eq(read.count, lists.count, "every list comes back")
        for (key, list) in lists {
            check(read[key] == list, "\(key): identical after a round trip (cards, episodes, badges, dates, languages)")
        }
        // What the builder makes of the disk is what it made of memory.
        let before = HomeBuilder.shelves(HomeFixture.inputs(lists)), after = HomeBuilder.shelves(HomeFixture.inputs(read))
        check(before == after && !after.isEmpty, "the same shelves from the disk")
        // Small files: the cards, not the answers (series/top is 546 KB on the wire's far end).
        let files = (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)) ?? []
        eq(files.count, lists.count, "one file per list")
        check(files.allSatisfy { $0.pathExtension == "json" }, "json files")
        let fixtureBytes = ["cm_movie_top.json", "cm_series_top.json", "cm_series_year_2026.json", "yts_new_2026.json", "yts_4k.json", "yts_year_2026.json",
                            "yts_year_2026.json", "tvm_web_2026-11-13.json", "tvm_us_2026-11-13.json", "tvm_web_2026-11-14.json", "tpb_48h_208.json",
                            "tpb_48h_207.json", "tpb_211.json"].reduce(0) { $0 + HomeFixture.data($1).count }
        check(store.size > 0 && store.size < 2 * fixtureBytes, "the cache is of the order of the trimmed answers", "\(store.size) bytes for \(fixtureBytes) of fixtures")
        // The sources that were down, next to the lists.
        eq(store.readDown(), [], "none remembered")
        store.write(down: ["yts-4k", "tpb-211"])
        eq(HomeStore(directory: store.directory, now: { self.now }).readDown(), ["yts-4k", "tpb-211"], "the keys of the sources down come back")
        eq(store.readAll().count, lists.count, "and are not taken for a list")
        store.write(down: [])
        check(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("down.json").path), "none down: no file")
        store.write(down: ["yts-4k"])
        store.removeAll()
        eq(store.readAll().count, 0, "removeAll empties it")
        eq(store.readDown(), [], "the sources down too")
        eq(store.size, 0, "nothing left on disk")
    }

    func testStoreOnlyTouchesItsOwnFiles() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        var clock = now
        let store = HomeStore(directory: sandbox.directory, now: { clock })
        store.write(HomeFixture.list(.movieTop, "cm_movie_top.json"))          // usable 7 days
        store.write(HomeFixture.list(.ytsNew(2026), "yts_new_2026.json"))       // usable 24 h
        // Someone else's files in the same folder (an App Group container's root, say).
        let foreign = ["settings.json": "{}", "topshelf.json": "not json", "notes.txt": "keep me"]
        for (name, text) in foreign { try? Data(text.utf8).write(to: sandbox.directory.appendingPathComponent(name)) }
        // The store's own names, with what it cannot show.
        try? Data("not json".utf8).write(to: sandbox.directory.appendingPathComponent("cm-genre-movie-Drama.json"))
        try? Data("{}".utf8).write(to: sandbox.directory.appendingPathComponent("tpb-211.json"))
        var old = HomeFixture.list(.seriesTop, "cm_series_top.json")
        old.version = HomeSourceList.currentVersion + 1
        store.write(old)
        let ownBytes = ["cm-movie-top.json", "yts-new-2026.json"].reduce(0) {
            $0 + ((try? Data(contentsOf: sandbox.directory.appendingPathComponent($1)).count) ?? 0)
        }
        eq(Set(store.readAll().keys), [HomeSource.movieTop.key, HomeSource.ytsNew(2026).key], "unreadable lists and another format version are not lists")
        let left = Set(((try? FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path)) ?? []))
        eq(left, Set(["cm-movie-top.json", "yts-new-2026.json"] + foreign.keys), "they are deleted; the files that are not the store's are left alone, .json or not")
        eq(store.size, ownBytes, "and are not counted in its size")
        clock = now.addingTimeInterval(day + 60)
        eq(Set(store.readAll().keys), [HomeSource.movieTop.key], "a day later YTS's additions are expired")
        check(!FileManager.default.fileExists(atPath: sandbox.directory.appendingPathComponent("yts-new-2026.json").path), "and deleted")
        clock = now.addingTimeInterval(7 * day)
        eq(store.readAll().count, 0, "after 7 days nothing is left")
        store.write(HomeFixture.list(.movieTop, "cm_movie_top.json"))
        store.remove(HomeSource.movieTop.key)
        check(!FileManager.default.fileExists(atPath: sandbox.directory.appendingPathComponent("cm-movie-top.json").path), "remove deletes one list")
        store.write(HomeFixture.list(.movieTop, "cm_movie_top.json"))
        store.removeAll()
        eq(Set(((try? FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path)) ?? [])), Set(foreign.keys), "removeAll deletes the lists and nothing else")
    }

    func testModelRoundTrip() throws {
        // Every field of a card, through JSON.
        let item = HomeItem(imdbId: "tt26598805", kind: .show, title: "Nocturne", year: 2026, rating: 7.7, genres: ["Drama", "Crime"],
                            summary: "A summary.", runtimeMinutes: 46, posterURL: URL(string: "https://images.metahub.space/poster/medium/tt26598805/img"),
                            backdropURL: URL(string: "https://images.metahub.space/background/large/tt26598805/img"),
                            logoURL: URL(string: "https://images.metahub.space/logo/medium/tt26598805/img"), trailerCode: "abc123",
                            badges: [.uhd, .newEpisode], rank: 3,
                            episode: HomeEpisode(season: 1, number: 4, title: "The Courier", stillURL: URL(string: "https://episodes.metahub.space/tt26598805/1/4/w780.jpg"), airDate: now),
                            date: now, progress: 0.42, remainingMinutes: 27)
        eq(item.id, "tt26598805:1:4", "an episode card's id is made of the show and the episode")
        eq(HomeItem(imdbId: "tt1", kind: .movie, title: "x").id, "tt1", "a title card's is the IMDb id")
        eq(HomeItem(id: "custom", imdbId: "tt1", kind: .movie, title: "x").id, "custom", "unless the caller gives one")
        let shelf = HomeShelf(id: HomeShelfID.yourShows, style: .landscape, items: [item], updatedAt: now, isStale: true,
                              seeAll: HomeSeeAll(catalogue: .shows, filter: "trending", genre: "Drama"))
        let data = try JSONEncoder().encode(shelf)
        let back = try JSONDecoder().decode(HomeShelf.self, from: data)
        check(back == shelf, "a shelf survives JSON")
        eq(back.items[0].episode?.stillURL, item.episode?.stillURL, "the still")
        eq(back.items[0].progress, 0.42, "progress")
        eq(back.seeAll?.showFilter, .trending, "see all")
        eq(back.seeAll?.genreFilter, .drama, "its genre")
        let snapshot = HomeSnapshot(shelves: [HomeShelf(id: HomeShelfID.hero, style: .hero, items: [item]), shelf])
        eq(snapshot.heroItems.count, 1, "the hero's cards")
        eq(snapshot.rows.map(\.id), [HomeShelfID.yourShows], "the rows under it")
        check(snapshot.shelf(HomeShelfID.yourShows) != nil && snapshot.shelf("nope") == nil, "by id")
        eq(item.landscapeURL, item.episode?.stillURL, "a landscape card shows the still")
    }

    // MARK: Settings

    func testSettings() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let settings = HomeSettings(defaults: sandbox.defaults, deviceLanguages: { ["de-DE", "en-US"] })
        eq(settings.contentLanguages, ["en", "fr", "de"], "English, French and the device's language")
        eq(HomeSettings(defaults: sandbox.defaults, deviceLanguages: { ["fr-FR"] }).contentLanguages, ["en", "fr"], "a French device: no third language")
        eq(HomeSettings(defaults: sandbox.defaults, deviceLanguages: { [] }).contentLanguages, ["en", "fr"], "no device language")
        settings.contentLanguages = ["es", "EN-us", "es", "?"]
        eq(settings.contentLanguages, ["es", "en"], "what was stored, as codes, once each")
        eq(sandbox.defaults.array(forKey: "popcornkit.home.contentLanguages") as? [String], ["es", "EN-us", "es", "?"], "under the documented key")
        settings.contentLanguages = []
        eq(settings.contentLanguages, [], "an empty list means every language, not the default")
        settings.resetContentLanguages()
        eq(settings.contentLanguages, ["en", "fr", "de"], "back to the default")

        check(settings.sendsFollowedShowsToCinemeta, "the followed shows are sent by default")
        settings.sendsFollowedShowsToCinemeta = false
        check(!settings.sendsFollowedShowsToCinemeta, "the opt-out")
        eq(sandbox.defaults.object(forKey: "libraryBulkEpisodeLookup") as? Bool, false, "under the documented key: the library's")
        settings.sendsFollowedShowsToCinemeta = true
        check(settings.sendsFollowedShowsToCinemeta, "and back")

        eq(settings.hiddenShelves, [], "nothing hidden by default")
        settings.setShelf(HomeShelfID.uhd, hidden: true)
        settings.setShelf(HomeShelfID.top48hMovies, hidden: true)
        eq(settings.hiddenShelves, [HomeShelfID.uhd, HomeShelfID.top48hMovies], "hidden shelves")
        eq(sandbox.defaults.array(forKey: "popcornkit.home.hiddenShelves") as? [String], ["top48hMovies", "uhd"], "under the documented key")
        settings.setShelf(HomeShelfID.uhd, hidden: false)
        eq(settings.hiddenShelves, [HomeShelfID.top48hMovies], "shown again")
        check(UserDefaults.standard.object(forKey: HomeSettings.Key.hiddenShelves) == nil, "the standard defaults are untouched")
    }

    // MARK: Plan

    func testPlanOfARefresh() {
        let plan = HomePlan(now: now, followedShowIds: [], genres: HomeBuilder.defaultGenres.prefix(2).map { $0 })
        eq(plan.year, 2026, "the year")
        eq(plan.days, ["2026-11-14", "2026-11-13", "2026-11-12"], "today and the two days before (UTC)")
        eq(plan.phase1.map(\.request), [
            HomeRequest(host: .cinemeta, path: "/catalog/movie/top.json"),
            HomeRequest(host: .cinemeta, path: "/catalog/series/top.json"),
            HomeRequest(host: .yts, path: "/api/v2/list_movies.json?limit=50&order_by=desc&query_term=2026&sort_by=date_added&minimum_rating=6"),
            HomeRequest(host: .yts, path: "/api/v2/list_movies.json?limit=50&order_by=desc&quality=2160p&sort_by=date_added"),
        ], "the first paint is four requests")
        eq(plan.phase2.map(\.request.path), [
            "/api/v2/list_movies.json?limit=50&order_by=desc&query_term=2026&sort_by=download_count",
            "/api/v2/list_movies.json?limit=50&order_by=desc&query_term=2026&sort_by=download_count&minimum_rating=7",
            "/catalog/series/year/genre=2026.json",
            "/schedule/web?date=2026-11-14", "/schedule?country=US&date=2026-11-14",
            "/schedule/web?date=2026-11-13", "/schedule?country=US&date=2026-11-13",
            "/schedule/web?date=2026-11-12", "/schedule?country=US&date=2026-11-12",
        ], "then the shelves of the year, the new shows and three days of schedules")
        eq(plan.phase3.map(\.request.path), [
            "/precompiled/data_top100_48h_208.json", "/precompiled/data_top100_48h_207.json", "/precompiled/data_top100_211.json",
            "/catalog/movie/top/genre=Action.json", "/catalog/series/top/genre=Drama.json",
        ], "then the rankings and the genres")
        check(plan.calendar == nil, "nobody followed: no calendar")
        let followed = HomePlan(now: now, followedShowIds: ["tt31510819"], genres: [])
        eq(followed.phase2.map(\.request.path)[3], "/catalog/series/calendar-videos/calendarVideosIds=tt31510819.json", "the followed shows' calendar is in the second phase")
        check(followed.isCurrent(followed.calendar!.key) && !plan.isCurrent(followed.calendar!.key), "another set of shows' calendar is a leftover")
        check(plan.isCurrent("tvm-web-2026-11-12") && !plan.isCurrent("tvm-web-2026-11-11") && plan.isCurrent(HomeSource.movieTop.key), "so is a day out of the window")
        // New Year's Eve, 23:30 in New York: the plan follows UTC.
        let newYear = HomePlan(now: CatalogDates.date(from: "2027-01-01T04:30:00Z")!, followedShowIds: [], genres: [])
        eq(newYear.year, 2027, "the year in UTC")
        eq(newYear.days, ["2027-01-01", "2026-12-31", "2026-12-30"], "days across the year")
        eq(HomeSource.movieTopNext.request.path, "/catalog/movie/top/skip=50.json", "the second page of the popular movies")
        eq(HomeSource.lookupShows(ids: ["tt7235466", "tt0413573"]).request.path, "/catalog/series/last-videos/lastVideosIds=tt0413573,tt7235466.json", "a lookup of shows, sorted")
        eq(HomeSource.lookupMovie(id: "tt4154796").request.path, "/meta/movie/tt4154796.json", "a lookup of a movie")
        eq(HomeSource.hash("tt26598805,tt31510819"), HomeSource.hash("tt26598805,tt31510819"), "a stable hash")
        eq(HomeSource.hash(""), "cbf29ce484222325", "FNV-1a's offset basis")
        eq(HomeSource.hash("a"), "af63dc4c8601ec8c", "FNV-1a of \"a\"")
    }
}
