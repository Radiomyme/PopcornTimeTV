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
        /// 200 with this body.
        case json(String)
        /// No answer at all (offline).
        case failure
        /// No answer until the test releases it (`release`): a slow TMDB.
        case held
    }

    private static let lock = NSLock()
    private static var reply: Reply = .failure
    private static var log: [URLRequest] = []
    private static var waiting: [KeyCheckStub] = []

    static func answer(_ reply: Reply) {
        lock.lock(); self.reply = reply; lock.unlock()
    }

    static func reset() {
        lock.lock(); reply = .failure; log = []; waiting = []; lock.unlock()
    }

    /// Answers `status` to the held request whose address or header carries `key`.
    static func release(_ key: String, status: Int) {
        lock.lock()
        let index = waiting.firstIndex { held in
            let request = held.request
            return request.url?.absoluteString.contains(key) == true
                || request.value(forHTTPHeaderField: "Authorization")?.contains(key) == true
        }
        let held = index.map { waiting.remove(at: $0) }
        lock.unlock()
        held?.respond(.status(status))
    }

    static var heldCount: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }

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
        if case .held = reply { KeyCheckStub.waiting.append(self) }
        KeyCheckStub.lock.unlock()
        respond(reply)
    }

    private func respond(_ reply: Reply) {
        guard let url = request.url else { return }
        switch reply {
        case .held:
            return
        case .failure:
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        case .status, .json:
            var code = 200, body = "{}"
            if case .status(let status) = reply { code = status }
            if case .json(let json) = reply { body = json }
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
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
            ("\u{FEFF}\(key)", key, "a byte-order mark before it"),
            ("\u{2060}\(key)\u{2060}", key, "word joiners around it"),
            ("\(key)\u{200E}", key, "a left-to-right mark after it (a page in Arabic)"),
            ("\u{200F}\(key)\u{200B}", key, "a right-to-left mark and a zero-width space"),
            ("--header 'Authorization: Bearer \(token)'", token, "the header line of TMDB's curl example"),
            ("curl --request GET \\\n  --header \"Authorization: Bearer \(token)\" \\", token, "more of the curl example"),
            ("-H \"Authorization: Bearer \(token)\"", token, "curl's -H"),
            ("API Key\n\(key)", key, "TMDB's « API Key » label copied with it"),
            ("API Key: \(key)", key, "the label and a colon"),
            ("API Read Access Token\n\(token)", token, "TMDB's token label copied with it"),
            ("api_key: \(key)", key, "api_key: "),
            ("api_key = \(key)", key, "api_key = "),
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

    /// A stored key TMDB refused stays « Refusée » when another key the user tries is refused
    /// too: the second refusal does not make the first one forgotten.
    func testARefusedStoredKeyStaysRefusedWhenAnotherKeyIsRefused() {
        let client = makeClient()
        let keys = makeKeys(client)
        KeyCheckStub.answer(.failure)
        eq(saved(key, keys), .unanswered, "stored while TMDB did not answer")
        KeyCheckStub.answer(.status(401))
        eq(checkedAgain(keys), .some(.refused), "TMDB refuses it")
        eq(keys.state, .refused, "« Refusée »")

        let mistyped = String(repeating: "e", count: 32)
        eq(saved(mistyped, keys), .refused, "another key, refused too")
        eq(settings.tmdbAPIKey, key, "not stored: the refused one stays")
        eq(keys.state, .refused, "still « Refusée », not « Définie »")
        check(client.isKeyRefused, "the Home still says the key was refused")
        check(client.isKeyRefused(mistyped), "and the other one is known refused")

        KeyCheckStub.answer(.status(200))
        eq(checkedAgain(keys), .some(.accepted), "fixed on TMDB's side")
        eq(keys.state, .set, "« Définie »")
        check(client.isKeyRefused(mistyped), "the other one is still refused")
    }

    /// A slow answer to « Enregistrer » never undoes what the user did after it: a key removed
    /// meanwhile stays removed, a key saved after it stays the one stored, whatever order the
    /// answers come in — even through another instance (the iPhone makes one per sheet).
    func testALateAnswerNeverUndoesALaterSaveOrRemoval() {
        KeyCheckStub.answer(.held)
        let first = makeKeys(), second = makeKeys()
        var answers: [TMDBKeySettings.Verdict] = []

        // Saved, then removed before TMDB answered.
        first.save(key) { answers.append($0) }
        homeWait(10) { KeyCheckStub.heldCount == 1 }
        first.remove()
        KeyCheckStub.release(key, status: 200)
        _ = homeWait(0.5) { false }
        check(settings.tmdbAPIKey == nil, "the removal wins: the late answer stores nothing")
        check(answers.isEmpty, "and is not reported", "\(answers)")

        // A saved, then B (another sheet); B answers first, then A.
        let other = String(repeating: "c", count: 32)
        first.save(key) { answers.append($0) }
        homeWait(10) { KeyCheckStub.heldCount == 1 }
        second.save(other) { answers.append($0) }
        homeWait(10) { KeyCheckStub.heldCount == 2 }
        KeyCheckStub.release(other, status: 200)
        homeWait(10) { answers.count == 1 }
        eq(settings.tmdbAPIKey, other, "B stored")
        KeyCheckStub.release(key, status: 200)
        _ = homeWait(0.5) { false }
        eq(settings.tmdbAPIKey, other, "A's late answer does not replace B")
        eq(answers, [.accepted], "only B's verdict reported")

        // A check of the stored key, then a removal: the check's answer is dropped.
        var checked: TMDBKeySettings.Verdict??
        first.checkAgain { checked = .some($0) }
        homeWait(10) { KeyCheckStub.heldCount == 1 }
        first.remove()
        KeyCheckStub.release(other, status: 200)
        _ = homeWait(0.5) { false }
        check(checked == nil, "no verdict about a key no longer stored")
        check(settings.tmdbAPIKey == nil, "still removed")
    }

    // MARK: The Settings store

    @MainActor
    private func makeStore(_ client: TMDBStreamingClient) -> StreamingSettingsStore {
        return StreamingSettingsStore(settings: settings, client: client, locale: Locale(identifier: "en_US"), refreshHub: {})
    }

    /// A key TMDB revoked since it was stored: the store learns it from its own lists (the
    /// Services list, the countries), so the row says « Refusée » and the list says the key
    /// was refused — not that TMDB did not answer.
    @MainActor
    func testTheStoreLearnsARefusalFromItsLists() {
        settings.tmdbAPIKey = key
        let store = makeStore(makeClient())
        eq(store.keyState, .set, "« Définie » after a launch: nothing refused yet")
        KeyCheckStub.answer(.status(401))
        store.loadServices()
        homeWait(10) { store.servicesLoad == .failed }
        eq(store.servicesLoad, .failed, "the services list failed")
        eq(store.keyState, .refused, "and the row says « Refusée » at once")

        let other = makeStore(makeClient())
        eq(other.keyState, .set, "another run")
        other.loadRegions()
        homeWait(10) { other.regionsLoad == .failed }
        eq(other.keyState, .refused, "the countries' 401 says it too")
    }

    /// The countries asked without a key (or offline) give the system's list for now, and are
    /// asked of TMDB again later — at once when a key is saved — instead of for the whole run.
    @MainActor
    func testTheCountriesAreAskedAgainAfterAFailure() {
        let store = makeStore(makeClient())
        var first: [StreamingChoice]?
        store.loadRegions { first = $0 }
        homeWait(10) { first != nil }
        eq(store.regionsLoad, .failed, "no key: not TMDB's list")
        check((first?.count ?? 0) > 200, "the system's countries meanwhile", "\(first?.count ?? 0)")
        eq(KeyCheckStub.requests.count, 0, "nothing asked without a key")

        KeyCheckStub.answer(.json(#"{"results":[{"iso_3166_1":"FR"},{"iso_3166_1":"BE"},{"iso_3166_1":"CA"}]}"#))
        var verdict: TMDBKeySettings.Verdict?
        store.saveKey(key) { verdict = $0 }
        homeWait(10) { verdict != nil && store.regionsLoad == .loaded }
        eq(verdict, .accepted, "a key saved")
        eq(store.regionsLoad, .loaded, "TMDB's countries asked at once")
        eq(store.regionChoices?.map(\.id), ["BE", "CA", "FR"], "TMDB's three, by name")
        check(KeyCheckStub.requests.contains { $0.url?.path.hasSuffix("/watch/providers/regions") == true }, "asked of TMDB")
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

        // The very call of the Apple TV's sheet (`apiPageQRCode`, 8 px a module, drawn 248 pt
        // wide), with a key stored: it reads as the page, and never carries the key.
        settings.tmdbAPIKey = key
        let sheet = try XCTUnwrap(TMDBKeySettings.apiPageQRCode())
        eq(sheet.width % 8, 0, "whole modules at the sheet's scale")
        let readOnSheet = detector.features(in: CIImage(cgImage: sheet)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        eq(readOnSheet, [page], "the sheet's code reads as TMDB's API page")
        check(!readOnSheet.contains { $0.contains(key) }, "not the stored key")
    }
}
