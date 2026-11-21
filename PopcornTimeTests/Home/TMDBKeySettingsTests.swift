//
//  TMDBKeySettingsTests.swift
//  PopcornTimeTests
//
//  The TMDB key as the three apps' Settings handle it (TMDBKeySettings): what is pasted,
//  cleaned into the key; a v3 key told from a v4 token; the state a row shows; saving after a
//  check (accepted and stored, refused and not stored, no answer and stored), removing,
//  checking a stored key again; and the QR code of TMDB's API page. TMDB is a URLProtocol stub
//  (nothing reaches it) and the defaults a scratch suite; the keys are made up.
//

import Foundation
import CoreImage
import XCTest
@testable import PopcornKit

/// TMDB's answer to every request, as the tests set it; the requests kept.
private final class KeyCheckStub: URLProtocol {

    enum Reply {
        case status(Int)
        /// No answer at all (offline).
        case failure
    }

    private static let lock = NSLock()
    private static var reply: Reply = .failure
    private static var log: [URLRequest] = []

    static func answer(_ reply: Reply) {
        lock.lock(); self.reply = reply; lock.unlock()
    }

    static func reset() {
        lock.lock(); reply = .failure; log = []; lock.unlock()
    }

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyCheckStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        KeyCheckStub.lock.lock()
        KeyCheckStub.log.append(request)
        let reply = KeyCheckStub.reply
        KeyCheckStub.lock.unlock()
        guard let url = request.url else { return }
        switch reply {
        case .failure:
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        case .status(let code):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

final class TMDBKeySettingsTests: CheckedTestCase {

    /// Made up: 32 characters, as a v3 key.
    private let key = "0123456789abcdef0123456789abcdef"
    /// Made up: a JWT-shaped v4 token.
    private let token = "eyJhbGciOiJIUzI1NiJ9." + String(repeating: "x", count: 150) + ".signature_part-01"

    private var sandbox: HomeSandbox!
    private var folder: URL!

    override func setUp() {
        super.setUp()
        KeyCheckStub.reset()
        sandbox = HomeSandbox()
        folder = sandbox.directory
    }

    override func tearDown() {
        KeyCheckStub.reset()
        sandbox.discard()
        super.tearDown()
    }

    private var settings: HomeSettings { HomeSettings(defaults: sandbox.defaults, deviceRegion: { "FR" }) }

    /// A client of the stub that reads its key where these settings keep it.
    private func makeClient() -> TMDBStreamingClient {
        let client = TMDBStreamingClient(session: KeyCheckStub.session, ids: TMDBIdCache(file: folder.appendingPathComponent("ids.json")))
        let settings = self.settings
        client.apiKey = { settings.tmdbAPIKey }
        return client
    }

    private func makeKeys(_ client: TMDBStreamingClient? = nil) -> TMDBKeySettings {
        return TMDBKeySettings(settings: settings, client: client ?? makeClient())
    }

    /// The verdict a save gets (on the main queue).
    private func saved(_ text: String, _ keys: TMDBKeySettings) -> TMDBKeySettings.Verdict? {
        var verdict: TMDBKeySettings.Verdict?
        keys.save(text) { verdict = $0 }
        homeWait(10) { verdict != nil }
        return verdict
    }

    private func checkedAgain(_ keys: TMDBKeySettings) -> TMDBKeySettings.Verdict?? {
        var verdict: TMDBKeySettings.Verdict??
        keys.checkAgain { verdict = .some($0) }
        homeWait(10) { verdict != nil }
        return verdict
    }

    // MARK: Text

    func testWhatIsPastedComesDownToTheKey() {
        let cases: [(String, String?, String)] = [
            (key, key, "the key itself"),
            ("  \(key)\n", key, "spaces and a line break around it"),
            ("\"\(key)\"", key, "straight quotes"),
            ("'\(key)'", key, "single quotes"),
            ("“\(key)”", key, "curly quotes"),
            ("« \(key) »", key, "French quotes"),
            ("`\(key)`", key, "back quotes"),
            ("Bearer \(token)", token, "a « Bearer » prefix"),
            ("bearer   \(token)", token, "« bearer », any case, several spaces"),
            ("Authorization: Bearer \(token)", token, "the whole header"),
            ("\"Bearer \(token)\"", token, "a header value between quotes"),
            (String(token.prefix(60)) + "\n" + String(token.dropFirst(60)), token, "a token broken over two lines"),
            ("api_key=\(key)", key, "api_key="),
            ("?api_key=\(key)", key, "?api_key="),
            ("API_KEY=\(key)", key, "API_KEY=, any case"),
            ("https://api.themoviedb.org/3/movie/550?api_key=\(key)", key, "an address that carries it"),
            ("https://api.themoviedb.org/3/discover/movie?language=en-US&api_key=\(key)&page=2", key,
             "an address with other parameters around it"),
            ("<https://api.themoviedb.org/3/configuration?api_key=\(key)>", key, "an address between angle brackets"),
            ("Bearerless", "Bearerless", "a word that only starts like « Bearer » stays"),
            ("", nil, "nothing"),
            ("   \n ", nil, "only spaces"),
            ("\"\"", nil, "only quotes"),
            ("Bearer ", nil, "only « Bearer »"),
            ("api_key=", nil, "only api_key="),
        ]
        for (text, expected, label) in cases {
            eq(TMDBKeySettings.cleaned(text), expected, label)
        }
        eq(TMDBKeySettings.cleaned("my_api_key=\(key)"), "my_api_key=\(key)", "another parameter is not api_key")
    }

    func testAKeyIsToldFromAToken() {
        eq(TMDBKeySettings.kind(of: key), .apiKey, "32 characters: a v3 API key")
        eq(TMDBKeySettings.kind(of: token), .readToken, "about 200: a v4 read token")
        eq(TMDBKeySettings.kind(of: String(repeating: "a", count: 40)), .apiKey, "40: still a key")
        eq(TMDBKeySettings.kind(of: String(repeating: "a", count: 41)), .readToken, "41: a token")
        eq(TMDBKeySettings.apiSettingsPage.absoluteString, "https://www.themoviedb.org/settings/api", "TMDB's API page")
    }

    /// The key goes where the client asks with it: in the query for a key, a header for a token.
    func testTheCheckSendsAKeyInTheQueryAndATokenInAHeader() {
        KeyCheckStub.answer(.status(200))
        let keys = makeKeys()
        eq(saved(key, keys), .accepted, "a key")
        let asked = KeyCheckStub.requests.last
        check(asked?.url?.query?.contains("api_key=\(key)") == true, "the key in the query")
        check(asked?.value(forHTTPHeaderField: "Authorization") == nil, "no header")
        eq(saved("Bearer \(token)", keys), .accepted, "a token")
        let tokened = KeyCheckStub.requests.last
        eq(tokened?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)", "the token in the header, cleaned")
        check(tokened?.url?.query?.contains("api_key") != true, "not in the query")
        eq(settings.tmdbAPIKey, token, "the token stored without « Bearer »")
    }

    // MARK: Saving

    func testSavingKeepsTheKeyUnlessTMDBRefusesIt() {
        let keys = makeKeys()
        eq(keys.state, .none, "no key: « Aucune »")
        check(!keys.hasKey, "none stored")

        KeyCheckStub.answer(.status(401))
        eq(saved("\"\(key)\"", keys), .refused, "401: refused")
        check(settings.tmdbAPIKey == nil, "a refused key is not stored")
        eq(keys.state, .none, "still « Aucune »")

        KeyCheckStub.answer(.status(200))
        eq(saved(" \(key) ", keys), .accepted, "200: accepted")
        eq(settings.tmdbAPIKey, key, "stored, cleaned")
        eq(keys.state, .set, "« Définie »")

        let other = String(repeating: "f", count: 32)
        KeyCheckStub.answer(.status(401))
        eq(saved(other, keys), .refused, "another key refused")
        eq(settings.tmdbAPIKey, key, "the key stored before stays")
        eq(keys.state, .set, "and is not the one refused")

        KeyCheckStub.answer(.failure)
        eq(saved(other, keys), .unanswered, "no answer")
        eq(settings.tmdbAPIKey, other, "stored anyway, tried at the next request (as the Apple TV does)")
        eq(keys.state, .refused, "TMDB's last word on this very key was a refusal: « Refusée »")

        KeyCheckStub.answer(.status(503))
        eq(saved(key, keys), .unanswered, "TMDB down: no answer, not a refusal")
        eq(settings.tmdbAPIKey, key, "stored")
        eq(keys.state, .set, "never refused: « Définie »")
    }

    func testTextWithoutAKeyIsRefusedWithoutARequest() {
        KeyCheckStub.answer(.status(200))
        let keys = makeKeys()
        eq(saved(key, keys), .accepted, "a key first")
        let before = KeyCheckStub.requests.count
        eq(saved("  \"\" ", keys), .refused, "quotes alone: no key in it")
        eq(KeyCheckStub.requests.count, before, "nothing asked of TMDB")
        eq(settings.tmdbAPIKey, key, "the stored key stays")
    }

    func testRemovingTheKey() {
        KeyCheckStub.answer(.status(200))
        let keys = makeKeys()
        _ = saved(key, keys)
        keys.remove()
        check(settings.tmdbAPIKey == nil, "removed")
        check(sandbox.defaults.object(forKey: HomeSettings.Key.tmdbAPIKey) == nil, "nothing left in the defaults")
        eq(keys.state, .none, "« Aucune »")
        check(settings.streamingShelves.isEmpty, "no « Services » row without it")
    }

    // MARK: Checking again

    func testCheckingAStoredKeyAgain() {
        let keys = makeKeys()
        let none = checkedAgain(keys)
        check(none != nil && none! == nil, "no key: nothing to check")
        eq(KeyCheckStub.requests.count, 0, "and no request")

        KeyCheckStub.answer(.failure)
        eq(saved(key, keys), .unanswered, "saved while TMDB did not answer")
        KeyCheckStub.answer(.status(401))
        eq(checkedAgain(keys), .some(.refused), "TMDB now refuses it")
        eq(settings.tmdbAPIKey, key, "the key stays stored")
        eq(keys.state, .refused, "« Refusée »")

        KeyCheckStub.answer(.failure)
        eq(checkedAgain(keys), .some(.unanswered), "no answer")
        eq(keys.state, .refused, "still known refused")

        KeyCheckStub.answer(.status(200))
        eq(checkedAgain(keys), .some(.accepted), "taken again (fixed on TMDB's side)")
        eq(keys.state, .set, "« Définie » again")
    }

    /// A DEBUG fixture run's client takes any key, unasked, and never calls one refused.
    func testRecordedAnswersTakeAnyKey() {
        let client = TMDBStreamingClient(recordedIn: Fixtures.url("Home"))
        let keys = makeKeys(client)
        eq(saved("fixture-key", keys), .accepted, "any key taken")
        eq(keys.state, .set, "« Définie »")
        eq(checkedAgain(keys), .some(.accepted), "checked again: taken")
        eq(KeyCheckStub.requests.count, 0, "nothing asked of anyone")
    }

    // MARK: QR code

    /// The Apple TV's key sheet shows a code a phone opens TMDB's API page with: the page, never
    /// the key. Read back with CoreImage's own reader.
    func testTheQRCodeOpensTMDBsAPIPage() throws {
        let page = TMDBKeySettings.apiSettingsPage.absoluteString
        let image = try XCTUnwrap(QRCodeImage.make(page, scale: 10))
        eq(image.width, image.height, "square")
        eq(image.width % 10, 0, "whole modules: crisp")
        check(image.width >= 250, "large enough to scan", "\(image.width)")
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let read = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        eq(read, [page], "it reads as TMDB's API page")
        check(!read.contains { $0.contains(key) }, "never a key")
        // The corner pixel is the quiet zone: white, for a dark screen.
        let corner = CIImage(cgImage: image).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(corner, toBitmap: &pixel, rowBytes: 4, bounds: corner.extent, format: .RGBA8, colorSpace: nil)
        check(pixel[0] > 200 && pixel[1] > 200 && pixel[2] > 200, "a white margin", "\(pixel)")
    }
}
