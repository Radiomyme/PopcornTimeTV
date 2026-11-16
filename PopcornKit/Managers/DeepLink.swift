import Foundation

/// A link into the app: what a `popcorntime:` URL asks for. Pure (no UI, no
/// network): each platform has its own router that shows it.
///
///     popcorntime://movie/<imdb id>                            a movie's page
///     popcorntime://show/<imdb id>[?season=2&episode=5]        a show's page (on that season)
///     popcorntime://play/movie/<imdb id>                       the page, then what its Play button starts
///     popcorntime://play/show/<imdb id>[?season=2&episode=5]   the page, then that episode (none if the show
///                                                              has no such episode), else what Play starts
///     popcorntime://search?q=<text>                            the Search screen, with the text searched
///     popcorntime://tab/<home|movies|shows|watchlist|search|downloads|settings>
///
/// The scheme and the keywords are read whatever their case (the tvOS app
/// declares `PopcornTime`, iOS and the Mac `popcorntime`). `title=` on a page
/// link is the title to show while the page loads.
///
/// The Top Shelf of 5.2.0 and before sent `PopcornTime:?action=showMovie»{json}`
/// (the whole movie or show as JSON): tvOS keeps the shelf it last got until it
/// asks the extension again, so those links are still read, for the id and the
/// title only.
///
/// Anything else is not a link (`init?(url:)` is nil): another scheme, an id
/// that is not an IMDb id, an unknown tab, invalid JSON. Nothing here traps on
/// a hostile URL.
public enum DeepLink: Hashable, Sendable {

    /// A movie's page. `play`: then what its Play button starts.
    case movie(id: String, title: String? = nil, play: Bool = false)
    /// A show's page, on `season` when given. `play`: then the episode
    /// `season` and `episode` name (nothing if the show has no such episode),
    /// or what the page's Play button starts when they name none.
    case show(id: String, title: String? = nil, season: Int? = nil, episode: Int? = nil, play: Bool = false)
    /// The Search screen; an empty `query` only shows it.
    case search(query: String)
    /// One of the app's main screens.
    case tab(Tab)

    /// The app's main screens, by name: tabs on Apple TV and iOS, sidebar
    /// sections on the Mac. A platform without one of them refuses its link.
    public enum Tab: String, CaseIterable, Sendable {
        case home, movies, shows, watchlist, search, downloads, settings

        /// From a name in any case ("Movies"); nil for an unknown one.
        public init?(name: String) {
            self.init(rawValue: name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    /// The scheme of the links `url` builds, in lower case.
    public static let scheme = "popcorntime"

    // MARK: - Reading

    public init?(url: URL) {
        guard url.scheme?.lowercased() == DeepLink.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // "popcorntime://movie/tt1" has the keyword as its host,
        // "popcorntime:movie/tt1" and "popcorntime:///movie/tt1" in the path.
        var segments = components.path.split(separator: "/").map(String.init)
        if let host = components.host, !host.isEmpty { segments.insert(host, at: 0) }
        guard let keyword = segments.first?.lowercased() else {
            guard let legacy = DeepLink.legacyTopShelfLink(percentEncodedQuery: components.percentEncodedQuery) else { return nil }
            self = legacy
            return
        }

        let query = DeepLink.Query(components.queryItems ?? [])
        switch (keyword, segments.count) {
        case ("movie", 2):
            guard let id = DeepLink.imdbID(segments[1]) else { return nil }
            self = .movie(id: id, title: query.title, play: false)
        case ("show", 2):
            guard let id = DeepLink.imdbID(segments[1]) else { return nil }
            self = .show(id: id, title: query.title, season: query.season, episode: query.episode, play: false)
        case ("play", 3):
            guard let id = DeepLink.imdbID(segments[2]) else { return nil }
            switch segments[1].lowercased() {
            case "movie": self = .movie(id: id, title: query.title, play: true)
            case "show": self = .show(id: id, title: query.title, season: query.season, episode: query.episode, play: true)
            default: return nil
            }
        case ("search", 1):
            self = .search(query: query.search)
        case ("tab", 2):
            guard let tab = Tab(name: segments[1]) else { return nil }
            self = .tab(tab)
        default:
            return nil
        }
    }

    /// The query of a link, read tolerantly: names in any case, the first
    /// value of a name, unreadable values ignored.
    private struct Query {
        private var values: [String: String] = [:]

        init(_ items: [URLQueryItem]) {
            for item in items {
                let name = item.name.lowercased()
                if values[name] == nil, let value = item.value { values[name] = value }
            }
        }

        var title: String? {
            let title = DeepLink.text(values["title"])
            return title.isEmpty ? nil : title
        }

        var search: String { DeepLink.text(values["q"] ?? values["query"]) }
        var season: Int? { number(values["season"] ?? values["s"]) }
        var episode: Int? { number(values["episode"] ?? values["e"]) }

        /// A season or an episode in `DeepLink.numbers`.
        private func number(_ value: String?) -> Int? {
            guard let value, let number = Int(value), DeepLink.numbers.contains(number) else { return nil }
            return number
        }
    }

    /// The longest title or search text a link carries (more is cut).
    static let maximumTextLength = 200

    /// The seasons and episodes a link carries: season 0 is a show's
    /// specials; nothing has ten thousand of them.
    static let numbers = 0..<10_000

    /// Without the spaces around it, cut, and without the spaces the cut
    /// leaves at its end: the same text read twice stays the same.
    private static func text(_ value: String?) -> String {
        String((value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumTextLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An IMDb title id, "tt" and digits, as the providers use it (lower
    /// case). The id goes into the providers' request URLs: nothing else is
    /// let through.
    static func imdbID(_ value: String) -> String? {
        let id = value.lowercased()
        let digits = id.dropFirst(2)
        guard id.hasPrefix("tt"), (1...12).contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return id
    }

    /// `PopcornTime:?action=showMovie»{json}` or `showShow»{json}`: the link
    /// of the Top Shelf up to 5.2.0.
    private static func legacyTopShelfLink(percentEncodedQuery: String?) -> DeepLink? {
        // The action is the whole query: the JSON may hold "&" and "=".
        let prefix = "action="
        guard let encoded = percentEncodedQuery, encoded.lowercased().hasPrefix(prefix),
              let action = String(encoded.dropFirst(prefix.count)).removingPercentEncoding,
              // The first "»" only: a title or a synopsis may hold one (French quotes).
              let separator = action.firstIndex(of: "»"),
              let object = try? JSONSerialization.jsonObject(with: Data(action[action.index(after: separator)...].utf8)),
              let json = object as? [String: Any],
              let id = ((json["imdb_id"] ?? json["_id"]) as? String).flatMap(imdbID) else { return nil }
        let title = text(json["title"] as? String)
        switch action[..<separator] {
        case "showMovie": return .movie(id: id, title: title.isEmpty ? nil : title, play: false)
        case "showShow": return .show(id: id, title: title.isEmpty ? nil : title, season: nil, episode: nil, play: false)
        default: return nil
        }
    }

    // MARK: - Building

    /// The link's URL (the new form), for the Top Shelf, the Home screen, a
    /// widget… `DeepLink(url:)` reads it back as the same link, written as
    /// the reader keeps it: the id in lower case, a title or a search text
    /// without the spaces around it and cut at `maximumTextLength`, a season
    /// or an episode the reader ignores (negative, 10 000 or more) left out.
    /// Nil for an id that is not an IMDb title id (a person's "nm…", an
    /// episode's "tt…-s1e2"): never a link the app would refuse.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = DeepLink.scheme
        var items: [URLQueryItem] = []
        func add(_ name: String, text value: String?) {
            let text = DeepLink.text(value)
            if !text.isEmpty { items.append(URLQueryItem(name: name, value: text)) }
        }
        func add(_ name: String, number value: Int?) {
            if let value, DeepLink.numbers.contains(value) { items.append(URLQueryItem(name: name, value: String(value))) }
        }
        switch self {
        case let .movie(id, title, play):
            guard let id = DeepLink.imdbID(id) else { return nil }
            components.host = play ? "play" : "movie"
            components.path = play ? "/movie/\(id)" : "/\(id)"
            add("title", text: title)
        case let .show(id, title, season, episode, play):
            guard let id = DeepLink.imdbID(id) else { return nil }
            components.host = play ? "play" : "show"
            components.path = play ? "/show/\(id)" : "/\(id)"
            add("season", number: season)
            add("episode", number: episode)
            add("title", text: title)
        case let .search(query):
            components.host = "search"
            add("q", text: query)
        case let .tab(tab):
            components.host = "tab"
            components.path = "/\(tab.rawValue)"
        }
        if !items.isEmpty { components.queryItems = items }
        return components.url
    }
}
