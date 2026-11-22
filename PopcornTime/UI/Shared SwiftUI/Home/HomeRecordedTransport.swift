// HomeRecordedTransport.swift — the Home hub fed from recorded answers
// instead of the network (iOS and macOS, DEBUG launches: stable screenshots
// and UI journeys; the launch arguments are each platform's debug hooks').
//
// The folder is one of answers as the hosts gave them, named as
// tools/home-fixtures.py names them (PopcornTimeTests/Fixtures/Home):
//
//   cm_movie_top.json, cm_series_top.json            Cinemeta's popular movies / series
//   cm_series_year_<year>.json                       the new series of a year
//   cm_calendar.json, cm_last_videos.json            the followed shows' episodes, a batch of shows
//   cm_meta_movies.json                              { "<imdb id>": <the answer of /meta/movie/<id>.json> }
//   yts_new_<year>.json, yts_year_<year>.json        YTS, a year by date added / by downloads
//   yts_4k.json                                      YTS, 2160p
//   tvm_web_<day>.json, tvm_us_<day>.json            TVMaze's schedules of a day (2026-11-14)
//   tpb_<list>.json                                  apibay's precompiled lists (207, 208, 211)
//   tmdb_*.json                                      TMDB's discover pages, services, countries:
//                                                    hand-made (tools/tmdb-fixtures.py), read by
//                                                    `TMDBRecorded` (the streaming services)
//
// A request without a file answers what its host answers when it has
// nothing (an empty page, an empty day), or fails when a real host would.
// Only the lists are replayed: the artwork still comes from its hosts.
import Foundation
import PopcornKit

struct HomeRecordedTransport {

    /// What the "network" does, for the page's states.
    enum Mode: Equatable {
        /// Every request is answered from the folder.
        case replay
        /// No request is ever answered: the page waits (its placeholders).
        case silent
        /// Every request fails at once (with nothing cached: the error page).
        case down
        /// TMDB fails at once, the other hosts answer: a page filtered on
        /// a service says its catalogue cannot load.
        case tmdbDown
        /// TMDB never answers, the other hosts do: a service's page keeps
        /// its placeholders.
        case tmdbSilent
    }

    /// The mode a fixture run's `-PTDebugHomeState` asks for (iOS and
    /// macOS hooks): `skeleton` (silent), `error` (down), `tmdbdown` and
    /// `tmdbrefused` (TMDB fails; with `tmdbrefused` the app's TMDB client
    /// also refuses every key: `TMDBStreamingClient.shared`), `tmdbsilent`;
    /// anything else replays (`offline` starts by replaying).
    static func mode(forState state: String?) -> Mode {
        switch state?.lowercased() {
        case "skeleton": return .silent
        case "error": return .down
        case "tmdbdown", "tmdbrefused": return .tmdbDown
        case "tmdbsilent": return .tmdbSilent
        default: return .replay
        }
    }

    /// The service a fixture run's Home starts filtered on
    /// (`-PTDebugHomeService`): a TMDB provider id ("8": Netflix; "350",
    /// `TMDBRecorded.emptyService`, lists nothing); nil for anything else.
    static func service(from argument: String?) -> Int? {
        argument.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }
    }

    let directory: URL
    private let state = State()

    init(directory: URL) {
        self.directory = directory
    }

    /// Thread-safe: the hub asks from its own queues.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Mode.replay
        var mode: Mode {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    /// Changes at any time: `.replay` to fill the page, then `.down` and a
    /// forced refresh for the offline note over the cached page.
    var mode: Mode {
        get { state.mode }
        nonmutating set { state.mode = newValue }
    }

    var transport: HomeTransport {
        let directory = self.directory, state = self.state
        return HomeTransport(fetch: { request, completion in
            switch state.mode {
            case .replay: completion(HomeRecordedTransport.answer(to: request, in: directory))
            case .down: completion(nil)
            case .silent: break   // the hub's own deadline ends the wait
            case .tmdbDown: completion(request.host == .tmdb ? nil : HomeRecordedTransport.answer(to: request, in: directory))
            case .tmdbSilent: if request.host != .tmdb { completion(HomeRecordedTransport.answer(to: request, in: directory)) }
            }
        })
    }

    // MARK: - Requests to files

    /// The recorded file a request reads, by name; nil when the request is
    /// answered without one (or not at all).
    static func fileName(for request: HomeRequest) -> String? {
        let path = request.path
        switch request.host {
        case .cinemeta:
            if path == "/catalog/movie/top.json" { return "cm_movie_top.json" }
            if path == "/catalog/series/top.json" { return "cm_series_top.json" }
            if let year = value(after: "/catalog/series/year/genre=", in: path) { return "cm_series_year_\(year).json" }
            if path.hasPrefix("/catalog/series/calendar-videos/") { return "cm_calendar.json" }
            if path.hasPrefix("/catalog/series/last-videos/") { return "cm_last_videos.json" }
            if path.hasPrefix("/meta/movie/") { return "cm_meta_movies.json" }
            // The catalogues not recorded apart (Featured, the second page,
            // the genres) have the shape of the popular ones.
            if path.hasPrefix("/catalog/movie/") { return "cm_movie_top.json" }
            if path.hasPrefix("/catalog/series/top/genre=") { return "cm_series_top.json" }
            return nil
        case .yts:
            if path.contains("quality=2160p") { return "yts_4k.json" }
            guard let year = query("query_term", in: path), year.count == 4, year.allSatisfy(\.isNumber) else { return nil }
            return path.contains("sort_by=date_added") ? "yts_new_\(year).json" : "yts_year_\(year).json"
        case .tvmaze:
            guard let day = query("date", in: path), isDay(day) else { return nil }
            if path.hasPrefix("/schedule/web?") { return "tvm_web_\(day).json" }
            if path.hasPrefix("/schedule?") { return "tvm_us_\(day).json" }
            return nil
        case .apibay:
            // "/precompiled/data_top100_207.json" → "tpb_207.json".
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            let prefix = "data_top100_"
            guard name.hasPrefix(prefix), name.hasSuffix(".json"), isPlainName(name) else { return nil }
            return "tpb_" + name.dropFirst(prefix.count)
        case .tmdb:
            return TMDBRecorded.fileName(for: path)
        }
    }

    /// The body a request is answered with, nil when its host "fails".
    static func answer(to request: HomeRequest, in directory: URL) -> Data? {
        let recorded = fileName(for: request).flatMap { try? Data(contentsOf: directory.appendingPathComponent($0)) }
        switch request.host {
        case .cinemeta:
            guard request.path.hasPrefix("/meta/movie/") else { return recorded }
            // One file for every meta recorded, by id; a title Cinemeta does
            // not know answers {}.
            let id = String(request.path.dropFirst("/meta/movie/".count).dropLast(".json".count))
            let all = recorded.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            return try? JSONSerialization.data(withJSONObject: all?[id] ?? [String: Any]())
        case .yts:
            // A year or a page YTS has nothing for: its answer without movies.
            return recorded ?? Data(#"{"status":"ok","status_message":"Query was successful","data":{"movie_count":0,"limit":50,"page_number":1}}"#.utf8)
        case .tvmaze:
            // A day without a recorded schedule: a day without episodes.
            return recorded ?? Data("[]".utf8)
        case .apibay:
            return recorded
        case .tmdb:
            // A page not recorded: an empty last page.
            return TMDBRecorded.answer(to: request.path, in: directory)
        }
    }

    /// The instant the folder was recorded at, for the hub's clock ("new",
    /// "this week" and the schedules asked are counted from it): the
    /// afternoon (UTC) of the last day it has a schedule of. nil: no
    /// schedule in the folder.
    static func recordedDate(in directory: URL) -> Date? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let days = names.compactMap { name -> String? in
            guard name.hasPrefix("tvm_web_"), name.hasSuffix(".json") else { return nil }
            let day = String(name.dropFirst("tvm_web_".count).dropLast(".json".count))
            return isDay(day) ? day : nil
        }
        guard let last = days.max() else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: "\(last)T14:40:00Z")
    }

    // MARK: - Reading a path

    /// What follows `prefix` in `path`, up to ".json"; nil when the path
    /// does not start with it. Only a plain name is returned (it becomes a
    /// file name).
    private static func value(after prefix: String, in path: String) -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(".json") else { return nil }
        let value = String(path.dropFirst(prefix.count).dropLast(".json".count))
        return isPlainName(value) && !value.isEmpty ? value : nil
    }

    /// The value of a query item of a path ("/schedule?country=US&date=…").
    private static func query(_ name: String, in path: String) -> String? {
        guard let mark = path.firstIndex(of: "?") else { return nil }
        for item in path[path.index(after: mark)...].split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == name { return String(pair[1]) }
        }
        return nil
    }

    /// "2026-11-14".
    private static func isDay(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.map(\.count) == [4, 2, 2] && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// Letters, digits, "_", "-" and ".": never a path out of the folder.
    private static func isPlainName(_ value: String) -> Bool {
        !value.contains("..") && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }
    }
}
