//
//  TMDBStreamingClientTests.swift
//  PopcornTimeTests
//
//  TMDBStreamingClient's network side, on a URLProtocol stub (nothing reaches TMDB) and an id
//  cache in a temporary file: the key in the query or the token in a header, a refused key told
//  from no answer, the IMDb-id join (found, none, failed then tried again, one limit for every
//  list), what the id cache keeps on disk, the last page, a genre TMDB cannot filter on, the
//  See All's pages, and the recorded answers of the DEBUG fixture runs.
//

import Foundation
import XCTest
@testable import PopcornKit

/// TMDB as the tests make it answer: a reply per path, every request kept.
private final class TMDBStub: URLProtocol {

    enum Reply {
        case json(Any)
        case status(Int)
        /// No answer at all (offline).
        case failure
    }

    private static let lock = NSLock()
    private static var replies: (URLRequest) -> Reply = { _ in .failure }
    private static var log: [URLRequest] = []
    private static var inFlight = 0
    private static var mostInFlight = 0
    static var delay: TimeInterval = 0

    static func answer(_ replies: @escaping (URLRequest) -> Reply) {
        lock.lock(); self.replies = replies; lock.unlock()
    }

    static func reset() {
        lock.lock(); replies = { _ in .failure }; log = []; inFlight = 0; mostInFlight = 0; delay = 0; lock.unlock()
    }

    /// The requests so far, in order.
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }
    /// Their paths with their queries, without the host ("/discover/movie?…").
    static var paths: [String] {
        requests.compactMap { request in
            request.url.map { url in url.path.replacingOccurrences(of: "/3", with: "", options: .anchored) + (url.query.map { "?" + $0 } ?? "") }
        }
    }
    static var most: Int { lock.lock(); defer { lock.unlock() }; return mostInFlight }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TMDBStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        TMDBStub.lock.lock()
        TMDBStub.log.append(request)
        TMDBStub.inFlight += 1
        TMDBStub.mostInFlight = max(TMDBStub.mostInFlight, TMDBStub.inFlight)
        let reply = TMDBStub.replies(request), delay = TMDBStub.delay
        TMDBStub.lock.unlock()
        let finish = {
            TMDBStub.lock.lock(); TMDBStub.inFlight -= 1; TMDBStub.lock.unlock()
            guard let url = self.request.url else { return }
            switch reply {
            case .failure:
                self.client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
                return
            case .json(let value):
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
            case .status(let code):
                let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data(#"{"status_code":7}"#.utf8))
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: finish) } else { finish() }
    }
}

final class TMDBStreamingClientTests: CheckedTestCase {

    private let key = "0123456789abcdef0123456789abcdef"
    private var folder: URL!

    override func setUp() {
        super.setUp()
        TMDBStub.reset()
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PopcornTimeTests-tmdb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TMDBStub.reset()
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private var idFile: URL { folder.appendingPathComponent("tmdb-imdb-ids.json") }

    private func makeClient(key: String? = nil) -> TMDBStreamingClient {
        let client = TMDBStreamingClient(session: TMDBStub.session, ids: TMDBIdCache(file: idFile))
        let key = key ?? self.key
        client.apiKey = { key }
        return client
    }

    /// A discover page whose results have these TMDB ids (no IMDb id: the client finds them).
    private func page(_ ids: [Int], page: Int = 1, pages: Int = 1, kind: HomeItem.Kind = .movie) -> TMDBStub.Reply {
        let results: [[String: Any]] = ids.map {
            ["id": $0, kind == .movie ? "title" : "name": "Title \($0)", "vote_average": 7.0, "vote_count": 100, "original_language": "en"]
        }
        return .json(["page": page, "total_pages": pages, "results": results])
    }

    /// "tt" and seven digits: the IMDb id the stub gives a TMDB id.
    private func imdb(_ id: Int) -> String { String(format: "tt%07d", id) }

    /// The TMDB id of an external_ids path ("/movie/12/external_ids" → 12).
    private func externalId(_ request: URLRequest) -> Int? {
        let parts = request.url?.path.split(separator: "/") ?? []
        guard parts.last == "external_ids", parts.count >= 2 else { return nil }
        return Int(parts[parts.count - 2])
    }

    /// Waits for a callback (the client calls back on its own queues; CataloguePages on the
    /// main queue).
    private func wait<T>(_ timeout: TimeInterval = 10, _ start: (@escaping @Sendable (T) -> Void) -> Void) -> T? {
        let box = TMDBGathered<T?>(nil)
        start { value in box.update { $0 = value } }
        homeWait(timeout) { box.value != nil }
        return box.value
    }

    private func titles(_ client: TMDBStreamingClient, kind: HomeItem.Kind = .movie, page: Int = 1, genre: String? = nil)
        -> (items: [HomeItem]?, more: Bool)? {
        return wait { done in
            client.titles(service: 8, kind: kind, region: "FR", page: page, genre: genre) { items, more in done((items, more)) }
        }
    }

    private var externalRequests: Int { TMDBStub.requests.filter { externalId($0) != nil }.count }

    // MARK: The key

    func testAKeyGoesInTheQueryAndATokenInAHeader() {
        TMDBStub.answer { _ in self.page([]) }
        _ = titles(makeClient())
        let keyed = TMDBStub.requests.first
        check(keyed?.url?.query?.contains("api_key=\(key)") == true, "a v3 key: in the query")
        check(keyed?.value(forHTTPHeaderField: "Authorization") == nil, "and no header")
        check(keyed?.url?.absoluteString.hasPrefix("https://api.themoviedb.org/3/discover/movie?watch_region=FR&with_watch_providers=8") == true,
              "TMDB's discover, of the service in the country")

        TMDBStub.reset()
        TMDBStub.answer { _ in self.page([]) }
        let token = String(repeating: "t", count: 60)
        _ = titles(makeClient(key: token))
        let tokened = TMDBStub.requests.first
        eq(tokened?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)", "a v4 token: in the Authorization header")
        check(tokened?.url?.query?.contains("api_key") == false, "not in the query")

        TMDBStub.reset()
        let none = TMDBStreamingClient(session: TMDBStub.session, ids: TMDBIdCache(file: idFile))
        none.apiKey = { nil }
        check(titles(none)?.items == nil, "no key: no answer")
        eq(TMDBStub.requests.count, 0, "and no request")
    }

    func testCheckTellsARefusedKeyFromNoAnswer() {
        let client = makeClient()
        TMDBStub.answer { _ in .status(401) }
        eq(wait { done in client.check(key: self.key) { done($0) } }, .some(false), "401: the key is refused")
        eq(TMDBStub.paths.last, "/configuration?api_key=\(key)", "asked of TMDB's configuration")
        TMDBStub.answer { _ in .json([String: Any]()) }
        eq(wait { done in client.check(key: self.key) { done($0) } }, .some(true), "200: taken")
        TMDBStub.answer { _ in .failure }
        eq(wait { done in client.check(key: self.key) { done($0) } }, .some(nil), "no answer: nil, not a refusal")
        TMDBStub.answer { _ in .status(503) }
        eq(wait { done in client.check(key: self.key) { done($0) } }, .some(nil), "TMDB down: nil")
    }

    /// A refused key is told apart from no answer on the screens (Home, grids, Settings): TMDB
    /// answers 401 to a key it refuses (status_code 7, « Invalid API key »).
    func testARefusedKeyIsRemembered() {
        var current = key
        let client = makeClient()
        client.apiKey = { current }
        check(!client.isKeyRefused, "nothing asked yet")
        TMDBStub.answer { _ in .failure }
        check(titles(client)?.items == nil && !client.isKeyRefused, "no answer: not a refusal")
        TMDBStub.answer { _ in .status(503) }
        check(titles(client)?.items == nil && !client.isKeyRefused, "TMDB down: not a refusal")
        TMDBStub.answer { _ in .status(401) }
        check(titles(client)?.items == nil, "a refused key: no page")
        check(client.isKeyRefused, "and the key is known refused")
        current = String(repeating: "b", count: 32)
        check(!client.isKeyRefused, "another key: not known refused")
        current = key
        TMDBStub.answer { _ in self.page([]) }
        _ = titles(client)
        check(!client.isKeyRefused, "taken again: no longer refused")
        TMDBStub.answer { _ in .status(401) }
        _ = wait { done in client.check(key: self.key) { done($0) } }
        check(client.isKeyRefused, "Settings' check of the same key refused: refused")
        let none = makeClient()
        none.apiKey = { nil }
        check(!none.isKeyRefused, "no key: nothing refused")
    }

    /// Settings matches the chosen services to a country's list: half a list (one of TMDB's two
    /// answered) would drop services the country has.
    func testTheServicesOfACountryNeedBothLists() {
        let client = makeClient()
        TMDBStub.answer { request in
            guard request.url?.path.hasSuffix("/movie") == true else { return .failure }
            return .json(["results": [["provider_id": 8, "provider_name": "Netflix", "display_priorities": ["FR": 0]]]])
        }
        eq(wait { done in client.services(region: "FR") { done($0) } }, .some(nil), "the shows' list without an answer: no list")
        TMDBStub.answer { request in
            let tv = request.url?.path.hasSuffix("/tv") == true
            return .json(["results": [["provider_id": tv ? 381 : 8, "provider_name": tv ? "Canal+" : "Netflix", "display_priorities": ["FR": tv ? 1 : 0]],
                                      ["provider_id": 2, "provider_name": "Apple TV Store", "display_priorities": ["FR": 2]]]])
        }
        eq(wait { done in client.services(region: "FR") { done($0) } }??.map(\.id), [8, 381], "both: merged, the store left out")
    }

    // MARK: IMDb ids

    func testIdsAreJoinedAndOnlyRealOnesKeptOnDisk() {
        TMDBStub.answer { request in
            guard let id = self.externalId(request) else { return self.page([1, 2, 3]) }
            return .json(["id": id, "imdb_id": id == 2 ? NSNull() : self.imdb(id) as Any])
        }
        let client = makeClient()
        let answer = titles(client)
        eq(answer?.items?.map(\.imdbId), [imdb(1), imdb(3)], "every title with its IMDb id, in order; the one TMDB has none for left out")
        eq(TMDBStub.requests.count, 4, "the page and its three lookups")
        let stored = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: idFile))) ?? [:]
        eq(stored, ["m1": imdb(1), "m3": imdb(3)], "the ids found on disk; \"none\" is not written")

        TMDBStub.reset()
        TMDBStub.answer { request in self.externalId(request) == nil ? self.page([1, 2, 3]) : .failure }
        eq(titles(client)?.items?.count, 2, "asked again in the same run")
        eq(externalRequests, 0, "every id known: the page alone (a title without one is not asked twice in a run)")

        // The next launch: the ids found come from the disk, the one without is asked again
        // (a new release gets its IMDb id days later).
        TMDBStub.reset()
        TMDBStub.answer { request in
            guard let id = self.externalId(request) else { return self.page([1, 2, 3]) }
            return .json(["id": id, "imdb_id": self.imdb(id)])
        }
        let next = makeClient()
        eq(titles(next)?.items?.map(\.imdbId), [imdb(1), imdb(2), imdb(3)], "the title has its IMDb id now")
        eq(TMDBStub.paths.filter { $0.contains("external_ids") }, ["/movie/2/external_ids?api_key=\(key)"], "only it was asked")
    }

    func testALookupWithoutAnAnswerIsAFailureNotATitleLess() {
        // TMDB never answers one lookup: the page is a failure, for the grid and for the hub.
        TMDBStub.answer { request in
            guard let id = self.externalId(request) else { return self.page([1, 2, 3], pages: 3) }
            return id == 2 ? .status(500) : .json(["id": id, "imdb_id": self.imdb(id)])
        }
        let client = makeClient()
        let failed = titles(client)
        check(failed != nil && failed?.items == nil, "titles(): nil (the grid's Retry), not two titles", "\(String(describing: failed))")
        eq(TMDBStub.paths.filter { $0.hasPrefix("/movie/2/external_ids?") }.count, 2, "the lookup was tried twice")
        let hub = wait { done in client.fetch(path: "/discover/movie?page=1") { done($0) } }
        check(hub != nil && hub! == nil, "the hub's fetch: nil (it keeps the list it has)")

        // It fails once, then answers: the page is whole.
        TMDBStub.reset()
        let tries = TMDBGathered(0)
        TMDBStub.answer { request in
            guard let id = self.externalId(request) else { return self.page([4, 5, 6], pages: 3) }
            if id == 5 {
                var first = false
                tries.update { $0 += 1; first = $0 == 1 }
                if first { return .failure }
            }
            return .json(["id": id, "imdb_id": self.imdb(id)])
        }
        let retried = titles(client)
        eq(retried?.items?.map(\.imdbId), [imdb(4), imdb(5), imdb(6)], "tried again once: every title")
        eq(retried?.more, true, "and the next page")
    }

    func testOneLimitOfLookupsForEveryList() {
        TMDBStub.delay = 0.03
        TMDBStub.answer { request in
            guard let id = self.externalId(request) else {
                let base = request.url?.path.contains("/tv") == true ? 100 : 0
                return self.page(Array(base + 1...base + 20), kind: base == 0 ? .movie : .show)
            }
            return .json(["id": id, "imdb_id": self.imdb(id)])
        }
        let client = makeClient()
        let both = TMDBGathered(0)
        client.titles(service: 8, kind: .movie, region: "FR", page: 1) { items, _ in both.update { $0 += items?.count ?? 0 } }
        client.titles(service: 8, kind: .show, region: "FR", page: 1) { items, _ in both.update { $0 += items?.count ?? 0 } }
        check(homeWait(15) { both.value == 40 }, "two lists of twenty titles", "\(both.value)")
        check(TMDBStub.most <= TMDBStreamingClient.parallelLookups + 2,
              "at most six lookups in flight for the two lists together (and their two pages)", "\(TMDBStub.most) at once")
    }

    func testAFailedSaveIsTriedAgain() {
        let file = folder.appendingPathComponent("later/ids.json")
        let cache = TMDBIdCache(file: file)
        cache.set(imdb(7), kind: .show, tmdbId: 7)
        cache.save()
        check(!FileManager.default.fileExists(atPath: file.path), "its folder is not there: not written")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        cache.save()
        eq(TMDBIdCache(file: file).imdbId(kind: .show, tmdbId: 7), imdb(7), "the next save writes it")
    }

    // MARK: Pages and genres

    func testNoRequestPastTheLastPage() {
        TMDBStub.answer { _ in .status(422) }
        let past = titles(makeClient(), page: 501)
        check(past?.items == [] && past?.more == false, "page 501: an empty last page", "\(String(describing: past))")
        eq(TMDBStub.requests.count, 0, "TMDB is not asked (it refuses past its 500th page)")
        TMDBStub.answer { _ in self.page([], page: 500, pages: 900) }
        eq(titles(makeClient(), page: 500)?.more, false, "the 500th is the last")
    }

    func testAGenreTMDBHasNoIdForIsAnEmptyPage() {
        TMDBStub.answer { _ in self.page([]) }
        let horror = titles(makeClient(), kind: .show, genre: "Horror")
        check(horror?.items == [] && horror?.more == false, "the shows' Horror: nothing, not the whole catalogue under its name")
        eq(TMDBStub.requests.count, 0, "and no request")
        _ = titles(makeClient(), genre: "Music")
        check(TMDBStub.paths.last?.contains("&with_genres=10402&") == true, "the movies' Music: TMDB's id")
        _ = titles(makeClient(), genre: "All")
        check(TMDBStub.paths.last?.contains("with_genres") == false, "All: every genre")
        _ = titles(makeClient(), kind: .show, genre: "Science Fiction")
        check(TMDBStub.paths.last?.contains("&with_genres=10765&") == true, "a genre the shows have")
        check(TMDBStub.paths.allSatisfy { $0.contains("&language=en-US") }, "in English")
    }

    func testCataloguePages() {
        // Movies: one page; shows: two. Title 3 is a movie and a show.
        TMDBStub.answer { request in
            if let id = self.externalId(request) { return .json(["id": id, "imdb_id": self.imdb(id % 100)]) }
            let tv = request.url?.path.contains("/tv") == true
            let page = Int(request.url?.query?.components(separatedBy: "page=").last?.prefix { $0.isNumber } ?? "1") ?? 1
            if tv { return self.page(page == 1 ? [103, 104, 105] : [106], page: page, pages: 2, kind: .show) }
            return self.page([1, 2, 3], page: 1, pages: 1)
        }
        let pages = TMDBStreamingClient.CataloguePages(service: 8, region: "FR", client: makeClient())
        pages.skip([imdb(2)])
        let first = wait { done in pages.load { done($0) } }
        eq(first??.map(\.imdbId), [imdb(1), imdb(3), imdb(4), imdb(5)],
           "movies and shows in turn; the title the shelf showed and a repeat left out")
        check(!pages.isOver, "the shows go on")
        let second = wait { done in pages.load { done($0) } }
        eq(second??.map(\.imdbId), [imdb(6)], "the shows' second page only")
        check(pages.isOver, "both over")
        let asked = TMDBStub.requests.count
        let end = wait { done in pages.load { done($0) } }
        eq(end??.count, 0, "over: an empty page")
        eq(TMDBStub.requests.count, asked, "without a request")

        TMDBStub.answer { _ in .failure }
        let failing = TMDBStreamingClient.CataloguePages(service: 8, region: "FR", client: makeClient())
        let failed = wait { done in failing.load { done($0) } }
        check(failed != nil && failed! == nil, "no answer: nil (a failure, not the end)")
        check(!failing.isOver, "not over")
    }

    // MARK: Recorded answers (DEBUG fixture runs)

    func testRecordedAnswers() {
        let recorded = Fixtures.url("Home")
        let client = TMDBStreamingClient(recordedIn: recorded)
        client.apiKey = { nil }
        let first = titles(client)
        eq(first?.items?.count, 12, "a recorded page, whatever the key")
        eq(first?.more, true, "with a next one")
        check(first?.items?.allSatisfy { HomeParse.isImdbId($0.imdbId) } == true, "every title known by its IMDb id")
        eq(titles(client, page: 2)?.more, false, "the second is the last")
        let third = titles(client, kind: .show, page: 3)
        check(third?.items == [] && third?.more == false, "past it, a page not recorded: the end")
        eq(titles(client, kind: .show)?.items?.count, 12, "the shows")
        eq(wait { done in client.check(key: "anything") { done($0) } }, .some(true), "any key is taken")
        eq(wait { done in client.services(region: "FR") { done($0) } }??.first?.name, "Netflix", "the services of a country")
        check(wait { done in client.services(region: "FR") { done($0) } }??.contains { $0.id == 119 } == true, "France: Prime Video is 119")
        let american = wait { done in client.services(region: "US") { done($0) } } ?? nil
        check(american?.contains { $0.id == 9 } == true && american?.contains { $0.id == 119 } == false,
              "the United States' own list: Prime Video is 9", "\(american?.map(\.id) ?? [])")
        eq(wait { done in client.services(region: "DE") { done($0) } }??.map(\.id),
           wait { done in client.services(region: "FR") { done($0) } }??.map(\.id), "a country not recorded: the French list")
        check((wait { done in client.regions { done($0) } }??.count ?? 0) > 3, "the countries")
        eq(TMDBStub.requests.count, 0, "nothing asked of anyone")

        // The hub's lists, as the recorded transports answer them (an IMDb id in every result).
        let source = HomeSource.streaming(service: 8, kind: .movie, sort: .recent, region: "FR", today: "2026-11-14")
        eq(TMDBRecorded.fileName(for: source.request.path), "tmdb_movie_recent_p1.json", "a list's file")
        let entries = TMDBRecorded.answer(to: source.request.path, in: recorded).flatMap { HomeParse.tmdbDiscover($0, kind: .movie) }
        eq(entries?.count, 12, "read as the hub reads it")
        let nothing = HomeSource.streaming(service: TMDBRecorded.emptyService, kind: .show, sort: .popular, region: "FR",
                                           today: "2026-11-14")
        eq(TMDBRecorded.fileName(for: nothing.request.path), "tmdb_empty.json", "the service that lists nothing")
        eq(TMDBRecorded.answer(to: nothing.request.path, in: recorded).flatMap { HomeParse.tmdbDiscover($0, kind: .show) }?.count, 0,
           "an empty list, not a failure")
        let replayed = HomeRecordedTransport.answer(to: HomeRequest(host: .tmdb, path: source.request.path), in: recorded)
        eq(replayed, TMDBRecorded.answer(to: source.request.path, in: recorded), "the iOS and Mac recorded transport answers the same")
        let unknown = TMDBRecorded.answer(to: "/movie/1/external_ids", in: recorded)
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        check(unknown?["imdb_id"] is NSNull, "an id no page has: no IMDb id")
        check(unknown?["wikidata_id"] is NSNull && unknown?["tvdb_id"] == nil, "TMDB's other fields of a movie, null")
        let show = TMDBRecorded.answer(to: "/tv/9200000/external_ids", in: recorded)
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        check((show?["imdb_id"] as? String).map(HomeParse.isImdbId) == true && show?["tvdb_id"] is NSNull, "a recorded show: its IMDb id, a show's fields")
        check(TMDBRecorded.answer(to: "/configuration", in: recorded) == nil, "nothing else")
        check(!client.isKeyRefused("anything"), "no key is ever refused")
    }

    /// `-PTDebugHomeState tmdbrefused` (the iPhone and Mac fixture runs): the recorded
    /// client refuses every key and answers nothing — the screens of a revoked key, without
    /// TMDB.
    func testRecordedAnswersThatRefuseEveryKey() {
        let client = TMDBStreamingClient(recordedIn: Fixtures.url("Home"), refusesEveryKey: true)
        client.apiKey = { "made-up-key" }
        eq(wait { done in client.check(key: "made-up-key") { done($0) } }, .some(false), "the key is refused")
        check(client.isKeyRefused && client.isKeyRefused("another"), "every key reads « Refused »")
        check(titles(client)?.items == nil, "no list: a failure, not an empty page")
        eq(wait { done in client.services(region: "FR") { done($0) } }??.count, nil, "no services")
        eq(TMDBStub.requests.count, 0, "nothing asked of anyone")
    }
}
