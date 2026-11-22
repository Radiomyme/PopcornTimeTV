import Foundation
import CoreGraphics

/// The user's TMDB key as the three apps' Settings handle it: what is typed
/// or pasted, cleaned into a key; whether it is a v3 API key or a v4 read
/// access token; the state a row shows (none, set, refused); saving after a
/// check with TMDB, removing, and checking a stored key again.
///
/// No SwiftUI, no UIKit: the Apple TV, iPhone / iPad and Mac settings call
/// it, and so do the unit tests. The key stays where the rest of the app
/// reads it, `HomeSettings.tmdbAPIKey` (UserDefaults, `popcornkit.tmdb.apiKey`).
/// Once saved, a screen never shows it again: only its `state`.
public struct TMDBKeySettings {

    /// What TMDB gives: two credentials that read the same API.
    public enum Kind: Equatable, Sendable {
        /// The v3 « API key » (32 characters): sent as `api_key=` in the query.
        case apiKey
        /// The v4 « API read access token » (a JWT of about 200 characters):
        /// sent in an `Authorization: Bearer` header.
        case readToken
    }

    /// What a Settings row says of the key.
    public enum State: Equatable, Sendable {
        /// No key: « Aucune » / « Not Set ».
        case none
        /// A key, not known to be refused: « Définie » / « Set ».
        case set
        /// TMDB refused the stored key (401) at its last request with it,
        /// and has not taken it since: « Refusée » / « Refused ».
        case refused

        /// The string key of what a Settings row says of the key (it is
        /// never shown again once saved): « Aucune », « Définie »,
        /// « Refusée ». The same on the iPhone, the iPad and the Mac.
        public var summaryKey: String {
            switch self {
            case .none: return "Settings.TMDBKey.Missing"
            case .set: return "Settings.TMDBKey.Set"
            case .refused: return "Settings.TMDBKey.Refused.Short"
            }
        }
    }

    /// TMDB's answer to a key being saved or checked again.
    public enum Verdict: Equatable, Sendable {
        /// TMDB took it. Saving: the key is stored.
        case accepted
        /// TMDB refused it (401). Saving: nothing is stored, a key stored
        /// before stays. Checking again: the stored key stays, and reads
        /// `.refused` from then on.
        case refused
        /// TMDB could not be asked (offline, TMDB down). Saving: the key is
        /// stored anyway and tried at the next request — what the Apple TV
        /// has done since the streaming services came (« the key is saved
        /// and will be tried at the next refresh »).
        case unanswered

        /// The verdict as the Apple TV's settings page takes it: true,
        /// false, nil when TMDB did not answer.
        public var accepted: Bool? {
            switch self {
            case .accepted: return true
            case .refused: return false
            case .unanswered: return nil
            }
        }

        /// The string key of the verdict in plain words, on the apps whose
        /// Home alone uses the key (iPhone, iPad, Mac: no grids' filter to
        /// promise): after « Enregistrer », or after « Vérifier à nouveau »
        /// (`afterCheck`), which says the STORED key's fate.
        public func messageKey(afterCheck: Bool) -> String {
            switch (self, afterCheck) {
            case (.accepted, false): return "Settings.TMDBKey.Accepted.HomeOnly"
            case (.refused, false): return "Settings.TMDBKey.Refused"
            case (.unanswered, false): return "Settings.TMDBKey.Unchecked"
            case (.accepted, true): return "Settings.TMDBKey.Check.Accepted"
            case (.refused, true): return "Settings.TMDBKey.Check.Refused"
            case (.unanswered, true): return "Settings.TMDBKey.Check.Unanswered"
            }
        }
    }

    /// TMDB's page where an account's key and token are shown (the QR code
    /// of the Apple TV's key sheet, « Obtenir une clé gratuite » elsewhere).
    public static let apiSettingsPage = URL(string: "https://www.themoviedb.org/settings/api")!

    /// The QR code of the Apple TV's key sheet: `apiSettingsPage`, at
    /// `scale` pixels a module. It takes no key: it can never show one.
    public static func apiPageQRCode(scale: Int = 8) -> CGImage? {
        return QRCodeImage.make(apiSettingsPage.absoluteString, scale: scale)
    }

    /// Longer than this, a credential is a v4 token (a v3 key has 32
    /// characters, a token about 200).
    static let longestAPIKey = 40

    private let settings: HomeSettings
    private let client: TMDBStreamingClient

    /// - Parameter settings: where the key is kept (the app's standard
    ///   defaults; a scratch suite in tests).
    /// - Parameter client: the client that checks the key and remembers a
    ///   refusal (`TMDBStreamingClient.shared`; a DEBUG fixture run's takes
    ///   any key, unasked).
    public init(settings: HomeSettings = HomeSettings(), client: TMDBStreamingClient = .shared) {
        self.settings = settings
        self.client = client
    }

    // MARK: Text

    /// The key in what was typed or pasted, nil when there is none.
    ///
    /// People paste what TMDB's page and its examples show, not only the
    /// key: the key between quotes (straight, curly or French), the
    /// `Authorization: Bearer …` header of a request — or the whole line of
    /// TMDB's curl example around it —, `api_key=…` (or `api_key: …`) or a
    /// whole address that carries it, the page's « API Key » label copied
    /// with it, a token broken over several lines. Invisible marks a page
    /// or a chat app slips in (U+200E, U+FEFF, U+2060…) go too. All of that
    /// comes down to the key itself; a key never has a space in it.
    public static func cleaned(_ text: String) -> String? {
        // Format characters (category Cf: direction marks, zero-width
        // spaces and joiners, the byte-order mark) are never part of a key.
        var key = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
        var previous: String?
        // Each rule may uncover another one ("'Bearer abc'"): until nothing changes.
        while key != previous {
            previous = key
            key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            key = key.trimmingCharacters(in: quotes)
            if let value = queryValue(in: key) { key = value }
            for prefix in ["authorization:", "bearer"] + labels {
                guard key.lowercased().hasPrefix(prefix) else { continue }
                let rest = key.dropFirst(prefix.count)
                // A key that only starts with these letters ("Bearerless") stays.
                guard prefix.hasSuffix(":") || rest.isEmpty || rest.first?.isWhitespace == true || rest.first == ":" else { continue }
                key = String(rest.first == ":" ? rest.dropFirst() : rest)
            }
            // « Bearer » inside a longer text (curl's `--header 'Authorization:
            // Bearer …'`): the key is what follows it.
            if let value = afterBearer(in: key) { key = value }
        }
        key.removeAll { $0.isWhitespace || $0.isNewline }
        return key.isEmpty ? nil : key
    }

    /// The labels of TMDB's API page, copied with what they label.
    private static let labels = ["api read access token", "api key"]

    /// Straight, curly, French and back quotes, and the angle brackets a
    /// mail client puts around an address.
    private static let quotes = CharacterSet(charactersIn: "\"'`“”‘’«»‹›<>")

    /// The value of `api_key=` (or `api_key:`) in a query, an address or a
    /// bare "api_key=…"; nil when the text has none.
    private static func queryValue(in text: String) -> String? {
        guard let range = text.range(of: "api_key", options: .caseInsensitive) else { return nil }
        let before = text[..<range.lowerBound].last
        // "my_api_key=": another parameter.
        if let before, before.isLetter || before.isNumber || before == "_" { return nil }
        var rest = text[range.upperBound...].drop { $0 == " " }
        guard let sign = rest.first, sign == "=" || sign == ":" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " }
        let value = rest.prefix { !"&#".contains($0) && !$0.isWhitespace }
        return String(value).removingPercentEncoding ?? String(value)
    }

    /// What follows a word « Bearer » (any case) followed by a space, past
    /// the start of the text, up to the quote or the backslash that ends a
    /// curl header; nil when there is none.
    private static func afterBearer(in text: String) -> String? {
        var start = text.startIndex
        while let range = text.range(of: "bearer", options: .caseInsensitive, range: start..<text.endIndex) {
            start = range.upperBound
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            guard before.map({ !$0.isLetter && !$0.isNumber }) ?? true,
                  range.upperBound < text.endIndex, text[range.upperBound].isWhitespace else { continue }
            return String(text[range.upperBound...].prefix { !"\"'\\“”‘’".contains($0) })
        }
        return nil
    }

    /// A v3 API key or a v4 read access token, by its length.
    public static func kind(of key: String) -> Kind {
        return key.count > longestAPIKey ? .readToken : .apiKey
    }

    // MARK: State

    /// True when a key is stored.
    public var hasKey: Bool {
        return settings.tmdbAPIKey != nil
    }

    /// What a Settings row says of the stored key.
    public var state: State {
        guard let key = settings.tmdbAPIKey else { return .none }
        return client.isKeyRefused(key) ? .refused : .set
    }

    // MARK: Changes

    /// The user's key actions in order (saves and removals, on any screen,
    /// any store): an answer of TMDB that comes after a later one is
    /// dropped — the last action wins. Shared by every instance: the iPhone
    /// makes one per Settings sheet.
    private static let actions = TMDBGathered<Int>(0)

    private static func nextAction() -> Int {
        var number = 0
        actions.update { $0 += 1; number = $0 }
        return number
    }

    /// Checks the key in `text` with TMDB, then keeps it unless TMDB
    /// refused it (`Verdict`). Text without a key (`cleaned` is nil) is
    /// refused without a request (and changes nothing else), and a key
    /// stored before stays. `completion` runs on the main queue — unless
    /// a later save or a removal came before TMDB's answer: then nothing
    /// is stored and `completion` is not called (that later action has its
    /// own outcome; a slow answer never brings back a key the user removed
    /// or replaced).
    public func save(_ text: String, completion: @escaping (Verdict) -> Void) {
        guard let key = TMDBKeySettings.cleaned(text) else {
            return DispatchQueue.main.async { completion(.refused) }
        }
        let action = TMDBKeySettings.nextAction()
        let settings = self.settings
        client.check(key: key) { answer in
            DispatchQueue.main.async {
                guard TMDBKeySettings.actions.value == action else { return }
                let verdict = TMDBKeySettings.verdict(answer)
                if verdict != .refused { settings.tmdbAPIKey = key }
                completion(verdict)
            }
        }
    }

    /// Removes the stored key: the « Services » row and the streaming
    /// shelves go. A save still waiting for TMDB's answer is dropped.
    public func remove() {
        _ = TMDBKeySettings.nextAction()
        settings.tmdbAPIKey = nil
    }

    /// Asks TMDB again about the stored key (a key « Refusée » that the
    /// user fixed on TMDB's side, or one saved while TMDB did not answer).
    /// The key stays stored whatever the answer: a refusal shows as
    /// `.refused`, an acceptance clears it. `completion` (main queue) gets
    /// nil when no key is stored; it is not called when a save or a
    /// removal came before TMDB's answer (that answer is about a key that
    /// is no longer the one stored).
    public func checkAgain(completion: @escaping (Verdict?) -> Void) {
        guard let key = settings.tmdbAPIKey else {
            return DispatchQueue.main.async { completion(nil) }
        }
        let action = TMDBKeySettings.actions.value
        client.check(key: key) { answer in
            DispatchQueue.main.async {
                guard TMDBKeySettings.actions.value == action else { return }
                completion(TMDBKeySettings.verdict(answer))
            }
        }
    }

    private static func verdict(_ answer: Bool?) -> Verdict {
        switch answer {
        case true?: return .accepted
        case false?: return .refused
        case nil: return .unanswered
        }
    }
}
