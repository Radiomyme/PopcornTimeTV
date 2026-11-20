// HomeFixtures.swift — the Home hub fed from recorded answers instead of the
// network: a `HomeTransport` that reads a folder of JSON files (the ones of
// PopcornTimeTests/Fixtures/Home, recorded on 2026-11-14 and trimmed to the
// fields the hub reads). The DEBUG launch hook `-PTDebugHomeFixtures <folder>`
// (HomeDebug.swift) builds the tab on it, so the UI tests and the screenshots
// show the same page whatever the hosts answer that day.
//
// Not inside `#if DEBUG`: the unit tests (which do not define it) load a
// whole page through it, so a request the hub adds or renames shows there
// before it shows as an empty shelf in a UI test.
import Foundation
import PopcornKit

enum HomeFixtures {

    /// When the answers were recorded: the hub fed from them runs at this
    /// instant ("today" for the aired episodes, the year of the yearly lists).
    static let recordedAt = Date(timeIntervalSince1970: 1_794_667_200)   // 2026-11-14T14:40:00Z

    /// What a request is answered with.
    enum Answer: Equatable {
        /// A file of the folder.
        case file(String)
        /// One entry of a file that maps ids to answers (the movie metas);
        /// an id it does not have answers `{}`, as Cinemeta does.
        case entry(file: String, key: String)
        /// A valid answer without titles.
        case empty(String)
        /// No answer: the host "fails".
        case none
    }

    /// The recorded answer of a request (the same choices as the unit
    /// tests' `HomeFakeNetwork`).
    static func answer(to request: HomeRequest) -> Answer {
        let path = request.path
        switch request.host {
        case .cinemeta:
            if path == "/catalog/movie/top.json" { return .file("cm_movie_top.json") }
            if path == "/catalog/series/top.json" { return .file("cm_series_top.json") }
            if path == "/catalog/series/year/genre=2026.json" { return .file("cm_series_year_2026.json") }
            if path.hasPrefix("/catalog/series/calendar-videos/") { return .file("cm_calendar.json") }
            if path.hasPrefix("/catalog/series/last-videos/") { return .file("cm_last_videos.json") }
            if path.hasPrefix("/meta/movie/"), path.hasSuffix(".json") {
                return .entry(file: "cm_meta_movies.json", key: String(path.dropFirst("/meta/movie/".count).dropLast(".json".count)))
            }
            // The catalogs not recorded apart (Featured, the second page,
            // the genres) have the shape of the popular ones.
            if path.hasPrefix("/catalog/movie/") { return .file("cm_movie_top.json") }
            if path.hasPrefix("/catalog/series/top/genre=") { return .file("cm_series_top.json") }
            return .none
        case .yts:
            if path.contains("query_term=2026") {
                return .file(path.contains("sort_by=date_added") ? "yts_new_2026.json" : "yts_year_2026.json")
            }
            if path.contains("quality=2160p") { return .file("yts_4k.json") }
            // Another year: YTS's answer for an empty page.
            return .empty(#"{"status":"ok","status_message":"Query was successful","data":{"movie_count":0,"limit":50,"page_number":1}}"#)
        case .tvmaze:
            if path == "/schedule/web?date=2026-11-13" { return .file("tvm_web_2026-11-13.json") }
            if path == "/schedule?country=US&date=2026-11-13" { return .file("tvm_us_2026-11-13.json") }
            if path == "/schedule/web?date=2026-11-14" { return .file("tvm_web_2026-11-14.json") }
            return .empty("[]")
        case .apibay:
            if path.hasSuffix("data_top100_208.json") { return .file("tpb_208.json") }
            if path.hasSuffix("data_top100_207.json") { return .file("tpb_207.json") }
            if path.hasSuffix("data_top100_211.json") { return .file("tpb_211.json") }
            return .none
        case .tmdb:
            // No key in a fixture run: the streaming shelves are not asked.
            return .none
        }
    }

    /// The body of an answer, read from `folder`.
    static func data(_ answer: Answer, in folder: URL) -> Data? {
        switch answer {
        case .file(let name):
            return try? Data(contentsOf: folder.appendingPathComponent(name))
        case .entry(let file, let key):
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)),
                  let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return try? JSONSerialization.data(withJSONObject: all[key] ?? [String: Any]())
        case .empty(let body):
            return Data(body.utf8)
        case .none:
            return nil
        }
    }

    /// A transport that answers from `folder`, off the caller's queue like
    /// a network would.
    /// - Parameters:
    ///   - delay: seconds before each answer (the page's placeholders).
    ///   - isOffline: true: no host answers.
    static func transport(folder: URL, delay: TimeInterval = 0,
                          isOffline: @escaping @Sendable () -> Bool = { false }) -> HomeTransport {
        let queue = DispatchQueue(label: "popcorntime.home.fixtures", qos: .userInitiated)
        return HomeTransport(fetch: { request, completion in
            queue.asyncAfter(deadline: .now() + delay) {
                completion(isOffline() ? nil : data(answer(to: request), in: folder))
            }
        })
    }
}
