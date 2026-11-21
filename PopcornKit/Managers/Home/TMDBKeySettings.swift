import Foundation

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
    }

    /// TMDB's page where an account's key and token are shown (the QR code
    /// of the Apple TV's key sheet, « Obtenir une clé gratuite » elsewhere).
    public static let apiSettingsPage = URL(string: "https://www.themoviedb.org/settings/api")!

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
    /// `Authorization: Bearer …` header of a request, `api_key=…` or a whole
    /// address that carries it, a token broken over several lines. All of
    /// that comes down to the key itself; a key never has a space in it.
    public static func cleaned(_ text: String) -> String? {
        var key = text
        var previous: String?
        // Each rule may uncover another one ("'Bearer abc'"): until nothing changes.
        while key != previous {
            previous = key
            key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            key = key.trimmingCharacters(in: quotes)
            if let value = queryValue(in: key) { key = value }
            for prefix in ["authorization:", "bearer"] {
                guard key.lowercased().hasPrefix(prefix) else { continue }
                let rest = key.dropFirst(prefix.count)
                // A key that only starts with these letters ("Bearerless") stays.
                guard prefix.hasSuffix(":") || rest.isEmpty || rest.first?.isWhitespace == true else { continue }
                key = String(rest)
            }
        }
        key.removeAll { $0.isWhitespace || $0.isNewline }
        return key.isEmpty ? nil : key
    }

    /// Straight, curly, French and back quotes, and the angle brackets a
    /// mail client puts around an address.
    private static let quotes = CharacterSet(charactersIn: "\"'`“”‘’«»‹›<>")

    /// The value of `api_key=` in a query, an address or a bare
    /// "api_key=…"; nil when the text has none.
    private static func queryValue(in text: String) -> String? {
        guard let range = text.range(of: "api_key=", options: .caseInsensitive) else { return nil }
        let before = text[..<range.lowerBound].last
        // "my_api_key=": another parameter.
        if let before, before.isLetter || before.isNumber || before == "_" { return nil }
        let value = text[range.upperBound...].prefix { !"&#".contains($0) && !$0.isWhitespace }
        return String(value).removingPercentEncoding ?? String(value)
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

    /// Checks the key in `text` with TMDB, then keeps it unless TMDB
    /// refused it (`Verdict`). Text without a key (`cleaned` is nil) is
    /// refused without a request, and a key stored before stays.
    /// `completion` runs on the main queue.
    public func save(_ text: String, completion: @escaping (Verdict) -> Void) {
        guard let key = TMDBKeySettings.cleaned(text) else {
            return DispatchQueue.main.async { completion(.refused) }
        }
        let settings = self.settings
        client.check(key: key) { answer in
            DispatchQueue.main.async {
                let verdict = TMDBKeySettings.verdict(answer)
                if verdict != .refused { settings.tmdbAPIKey = key }
                completion(verdict)
            }
        }
    }

    /// Removes the stored key: the « Services » row and the streaming
    /// shelves go.
    public func remove() {
        settings.tmdbAPIKey = nil
    }

    /// Asks TMDB again about the stored key (a key « Refusée » that the
    /// user fixed on TMDB's side, or one saved while TMDB did not answer).
    /// The key stays stored whatever the answer: a refusal shows as
    /// `.refused`, an acceptance clears it. `completion` (main queue) gets
    /// nil when no key is stored.
    public func checkAgain(completion: @escaping (Verdict?) -> Void) {
        guard let key = settings.tmdbAPIKey else {
            return DispatchQueue.main.async { completion(nil) }
        }
        client.check(key: key) { answer in
            DispatchQueue.main.async { completion(TMDBKeySettings.verdict(answer)) }
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
