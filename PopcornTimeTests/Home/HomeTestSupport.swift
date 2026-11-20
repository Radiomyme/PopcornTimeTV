//
//  HomeTestSupport.swift
//  PopcornTimeTests
//
//  What the Home tests share: the moment the fixtures were recorded, the fixtures themselves
//  (Fixtures/Home: the answers of 2026-11-14 trimmed to the fields HomeParse reads), and a
//  transport that replays them instead of the network.
//

import Foundation
import XCTest
@testable import PopcornKit

enum HomeFixture {
    /// When the answers were recorded: every test runs at this instant (or a stated offset).
    static let now = CatalogDates.date(from: "2026-11-14T14:40:00Z")!

    static func data(_ name: String) -> Data { Fixtures.data("Home/\(name)") }

    static func entries(_ name: String, _ parser: HomeSource.Parser, now: Date = HomeFixture.now) -> [HomeEntry] {
        return HomeParse.entries(data(name), parser: parser, now: now) ?? []
    }

    /// A parsed list as the cache would hold it.
    static func list(_ source: HomeSource, _ name: String, savedAt: Date = HomeFixture.now, complete: Bool = true) -> HomeSourceList {
        return HomeSourceList(key: source.key, savedAt: savedAt, complete: complete, entries: entries(name, source.parser))
    }

    static func list(_ source: HomeSource, _ entries: [HomeEntry], savedAt: Date = HomeFixture.now) -> HomeSourceList {
        return HomeSourceList(key: source.key, savedAt: savedAt, complete: true, entries: entries)
    }

    /// Every list of a full load at `now`, parsed from the fixtures.
    static func allLists(now: Date = HomeFixture.now) -> [String: HomeSourceList] {
        let year = CatalogDates.year(of: now)
        let lists = [
            list(.movieTop, "cm_movie_top.json"), list(.seriesTop, "cm_series_top.json"),
            list(.seriesYear(year), "cm_series_year_2026.json"),
            list(.ytsNew(year), "yts_new_2026.json"), list(.yts4K, "yts_4k.json"),
            list(.ytsYear(year), "yts_year_2026.json"), list(.ytsTop(year), "yts_year_2026.json"),
            list(.tvmaze(web: true, day: "2026-11-13"), "tvm_web_2026-11-13.json"),
            list(.tvmaze(web: false, day: "2026-11-13"), "tvm_us_2026-11-13.json"),
            list(.tvmaze(web: true, day: "2026-11-14"), "tvm_web_2026-11-14.json"),
            list(.topShows, "tpb_208.json"), list(.topMovies, "tpb_207.json"), list(.topUHD, "tpb_211.json"),
        ]
        return Dictionary(uniqueKeysWithValues: lists.map { ($0.key, $0) })
    }

    static func inputs(_ lists: [String: HomeSourceList], local: HomeLocal = HomeLocal(), languages: [String] = ["en", "fr"],
                       hidden: Set<String> = [], now: Date = HomeFixture.now) -> HomeBuilder.Inputs {
        return HomeBuilder.Inputs(lists: lists, local: local, languages: languages, hidden: hidden, sendsFollowedShows: true, now: now)
    }

    /// A card made by hand.
    static func entry(_ imdbId: String, _ title: String, kind: HomeItem.Kind = .movie, year: Int? = 2026, rating: Double? = nil,
                      language: String? = nil, qualities: Int? = nil, date: Date? = nil) -> HomeEntry {
        let item = HomeItem(imdbId: imdbId, kind: kind, title: title, year: year, rating: rating,
                            posterURL: URL(string: "https://images.metahub.space/poster/medium/\(imdbId)/img"),
                            backdropURL: URL(string: "https://images.metahub.space/background/large/\(imdbId)/img"),
                            logoURL: URL(string: "https://images.metahub.space/logo/medium/\(imdbId)/img"), date: date)
        return HomeEntry(item: item, language: language, qualities: qualities)
    }
}

/// The network of the tests: every request is recorded, and answered from the fixtures (or by
/// `answer`), at once or — `hold` — when the test releases it.
final class HomeFakeNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [HomeRequest] = []
    private var pending: [(request: HomeRequest, completion: HomeTransport.Completion)] = []
    private var isHolding = false
    private var downHosts = Set<HomeRequest.Host>()
    private var custom: ((HomeRequest) -> Data??)?
    private var resetCount = 0

    /// Every request asked so far, in order.
    var requests: [HomeRequest] { lock.lock(); defer { lock.unlock() }; return log }
    var paths: [String] { requests.map(\.path) }
    /// Requests asked and not answered yet (`hold`).
    var waiting: [HomeRequest] { lock.lock(); defer { lock.unlock() }; return pending.map(\.request) }

    /// True: requests wait for `release`.
    var hold: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isHolding }
        set { lock.lock(); isHolding = newValue; lock.unlock() }
    }

    /// Hosts that do not answer.
    var down: Set<HomeRequest.Host> {
        get { lock.lock(); defer { lock.unlock() }; return downHosts }
        set { lock.lock(); downHosts = newValue; lock.unlock() }
    }

    /// Overrides the fixtures: `.some(data)` / `.some(nil)` (no answer) for a request, nil to
    /// fall through to the fixtures.
    func answer(_ custom: @escaping (HomeRequest) -> Data??) {
        lock.lock(); self.custom = custom; lock.unlock()
    }

    func forget() { lock.lock(); log.removeAll(); lock.unlock() }

    /// The times the hub told the transport to forget the hosts that failed (a forced refresh).
    var resets: Int { lock.lock(); defer { lock.unlock() }; return resetCount }

    var transport: HomeTransport {
        return HomeTransport(fetch: { [self] request, completion in
            lock.lock()
            log.append(request)
            if isHolding {
                pending.append((request, completion))
                lock.unlock()
                return
            }
            lock.unlock()
            completion(body(request))
        }, reset: { [self] in
            lock.lock(); resetCount += 1; lock.unlock()
        })
    }

    /// Answers the held requests that match, in the order they were asked.
    func release(_ matching: (HomeRequest) -> Bool = { _ in true }) {
        lock.lock()
        let ready = pending.filter { matching($0.request) }
        pending.removeAll { matching($0.request) }
        lock.unlock()
        for held in ready { held.completion(body(held.request)) }
    }

    func body(_ request: HomeRequest) -> Data? {
        lock.lock()
        let isDown = downHosts.contains(request.host), custom = self.custom
        lock.unlock()
        if isDown { return nil }
        if let answer = custom?(request) { return answer }
        return HomeFakeNetwork.fixture(request)
    }

    /// The recorded answer of a request, nil when none was recorded (the host "fails").
    static func fixture(_ request: HomeRequest) -> Data? {
        let path = request.path
        switch request.host {
        case .cinemeta:
            if path == "/catalog/movie/top.json" { return HomeFixture.data("cm_movie_top.json") }
            if path == "/catalog/series/top.json" { return HomeFixture.data("cm_series_top.json") }
            if path == "/catalog/series/year/genre=2026.json" { return HomeFixture.data("cm_series_year_2026.json") }
            if path.hasPrefix("/catalog/series/calendar-videos/") { return HomeFixture.data("cm_calendar.json") }
            if path.hasPrefix("/catalog/series/last-videos/") { return HomeFixture.data("cm_last_videos.json") }
            if path.hasPrefix("/meta/movie/") {
                // One file for the four metas recorded: id → answer. Unknown ids answer {} like Cinemeta.
                let id = String(path.dropFirst("/meta/movie/".count).dropLast(".json".count))
                let all = (try? JSONSerialization.jsonObject(with: HomeFixture.data("cm_meta_movies.json"))) as? [String: Any]
                return try? JSONSerialization.data(withJSONObject: all?[id] ?? [String: Any]())
            }
            // The catalogs not recorded apart (Featured, page 2, genres) have the shape of the top ones.
            if path.hasPrefix("/catalog/movie/") { return HomeFixture.data("cm_movie_top.json") }
            if path.hasPrefix("/catalog/series/top/genre=") { return HomeFixture.data("cm_series_top.json") }
            return nil
        case .yts:
            if path.contains("query_term=2026") {
                return HomeFixture.data(path.contains("sort_by=date_added") ? "yts_new_2026.json" : "yts_year_2026.json")
            }
            if path.contains("quality=2160p") { return HomeFixture.data("yts_4k.json") }
            // Another year: an answer without movies, as YTS gives for an empty page.
            return Data(#"{"status":"ok","status_message":"Query was successful","data":{"movie_count":0,"limit":50,"page_number":1}}"#.utf8)
        case .tvmaze:
            if path == "/schedule/web?date=2026-11-13" { return HomeFixture.data("tvm_web_2026-11-13.json") }
            if path == "/schedule?country=US&date=2026-11-13" { return HomeFixture.data("tvm_us_2026-11-13.json") }
            if path == "/schedule/web?date=2026-11-14" { return HomeFixture.data("tvm_web_2026-11-14.json") }
            return Data("[]".utf8)
        case .apibay:
            if path.hasSuffix("data_top100_208.json") { return HomeFixture.data("tpb_208.json") }
            if path.hasSuffix("data_top100_207.json") { return HomeFixture.data("tpb_207.json") }
            if path.hasSuffix("data_top100_211.json") { return HomeFixture.data("tpb_211.json") }
            return nil
        case .tmdb:
            return nil
        }
    }
}

/// A folder and a defaults domain for one test, both in the temporary directory and deleted
/// at the end (a named defaults suite would leave a plist in ~/Library/Preferences).
final class HomeSandbox {
    let directory: URL
    let defaults: UserDefaults
    private let domain: String

    init() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PopcornTimeTests-home", isDirectory: true)
        let name = UUID().uuidString
        directory = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        domain = root.appendingPathComponent("defaults-\(name)").path
        defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
    }

    func discard() {
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
        try? FileManager.default.removeItem(atPath: domain + ".plist")
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Runs the main run loop until `condition` holds (the feed delivers on the main queue), at
/// most `timeout` seconds. False when it never did.
@discardableResult
func homeWait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }
    return true
}

/// The same from an async test on the main actor: suspends between two looks.
@MainActor
func homeUntil(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return true
}

/// Lets what is already queued run (a few turns of the feed's queue and of the main queue).
func homeSettle(_ seconds: TimeInterval = 0.05) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

extension HomeShelf {
    var titles: [String] { items.map(\.title) }
    var imdbIds: [String] { items.map(\.imdbId) }
}

extension Array where Element == HomeShelf {
    var ids: [String] { map(\.id) }
    func shelf(_ id: String) -> HomeShelf? { first { $0.id == id } }
}
