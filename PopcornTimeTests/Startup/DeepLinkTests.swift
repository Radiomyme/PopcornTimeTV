//
//  DeepLinkTests.swift
//  PopcornTimeTests
//
//  What a `popcorntime:` URL asks for (PopcornKit's DeepLink): the new links, the
//  Top Shelf links of 5.2.0 (`PopcornTime:?action=showMovie»{json}`), URLs that are
//  not links (hostile ones included: none may trap), and the URLs the builder makes.
//

import XCTest
import Foundation
@testable import PopcornKit

final class DeepLinkTests: CheckedTestCase {

    private func link(_ string: String) -> DeepLink? {
        guard let url = URL(string: string) else { return nil }
        return DeepLink(url: url)
    }

    // MARK: - The new links

    func testPagesPlaySearchAndTabs() {
        let cases: [(String, DeepLink)] = [
            ("popcorntime://movie/tt1375666", .movie(id: "tt1375666")),
            ("popcorntime://show/tt0903747", .show(id: "tt0903747")),
            ("popcorntime://play/movie/tt1375666", .movie(id: "tt1375666", play: true)),
            ("popcorntime://play/show/tt0903747", .show(id: "tt0903747", play: true)),
            ("popcorntime://play/show/tt0903747?season=2&episode=5", .show(id: "tt0903747", season: 2, episode: 5, play: true)),
            ("popcorntime://show/tt0903747?season=2&episode=5", .show(id: "tt0903747", season: 2, episode: 5)),
            ("popcorntime://show/tt0903747?season=0&episode=1", .show(id: "tt0903747", season: 0, episode: 1)),
            ("popcorntime://search?q=dune", .search(query: "dune")),
            ("popcorntime://search?q=dune%20part%20two", .search(query: "dune part two")),
            ("popcorntime://search", .search(query: "")),
            ("popcorntime://tab/home", .tab(.home)),
            ("popcorntime://tab/movies", .tab(.movies)),
            ("popcorntime://tab/shows", .tab(.shows)),
            ("popcorntime://tab/watchlist", .tab(.watchlist)),
            ("popcorntime://tab/search", .tab(.search)),
            ("popcorntime://tab/downloads", .tab(.downloads)),
            ("popcorntime://tab/settings", .tab(.settings)),
        ]
        for (url, expected) in cases {
            check(link(url) == expected, url, "got \(String(describing: link(url)))")
        }
    }

    /// The tvOS app declares the scheme `PopcornTime`, iOS and the Mac
    /// `popcorntime`; the system may hand over either.
    func testSchemeAndKeywordsInAnyCase() {
        let cases: [(String, DeepLink)] = [
            ("PopcornTime://movie/tt1375666", .movie(id: "tt1375666")),
            ("POPCORNTIME://MOVIE/TT1375666", .movie(id: "tt1375666")),
            ("PopcornTime://Play/Show/tt0903747?Season=3&EPISODE=7", .show(id: "tt0903747", season: 3, episode: 7, play: true)),
            ("popcorntime://Tab/Movies", .tab(.movies)),
            ("popcorntime://TAB/SETTINGS", .tab(.settings)),
            ("PopcornTime://Search?Q=Dune", .search(query: "Dune")),
        ]
        for (url, expected) in cases {
            check(link(url) == expected, url, "got \(String(describing: link(url)))")
        }
    }

    func testTolerantForms() {
        let cases: [(String, DeepLink)] = [
            // Without "//", with an empty host, with a trailing slash.
            ("popcorntime:movie/tt1375666", .movie(id: "tt1375666")),
            ("popcorntime:///movie/tt1375666", .movie(id: "tt1375666")),
            ("popcorntime://movie/tt1375666/", .movie(id: "tt1375666")),
            ("popcorntime:tab/shows", .tab(.shows)),
            ("popcorntime:search?q=dune", .search(query: "dune")),
            // The short names of the season and the episode, `query` for `q`.
            ("popcorntime://show/tt0903747?s=2&e=5", .show(id: "tt0903747", season: 2, episode: 5)),
            ("popcorntime://search?query=dune", .search(query: "dune")),
            // An unreadable season or episode is ignored, the page still opens.
            ("popcorntime://show/tt0903747?season=two&episode=5", .show(id: "tt0903747", episode: 5)),
            ("popcorntime://show/tt0903747?season=-1&episode=99999", .show(id: "tt0903747")),
            ("popcorntime://show/tt0903747?season=&episode", .show(id: "tt0903747")),
            // The first value of a name, unknown names ignored.
            ("popcorntime://show/tt0903747?season=2&season=9&utm=x", .show(id: "tt0903747", season: 2)),
            // A season on a movie means nothing.
            ("popcorntime://movie/tt1375666?season=2", .movie(id: "tt1375666")),
            // The title shown while the page loads.
            ("popcorntime://movie/tt1375666?title=Inception", .movie(id: "tt1375666", title: "Inception")),
            ("popcorntime://play/movie/tt1375666?title=%20Inception%20", .movie(id: "tt1375666", title: "Inception", play: true)),
            ("popcorntime://show/tt0903747?title=Breaking%20Bad&season=1", .show(id: "tt0903747", title: "Breaking Bad", season: 1)),
            ("popcorntime://movie/tt1375666?title=", .movie(id: "tt1375666")),
            ("popcorntime://movie/tt1375666?title=%20%20", .movie(id: "tt1375666")),
            // "+" is a plus (not a space), "&" and "»" come percent-encoded.
            ("popcorntime://search?q=1+1", .search(query: "1+1")),
            ("popcorntime://search?q=fast%20%26%20furious", .search(query: "fast & furious")),
            ("popcorntime://movie/tt0211915?title=Am%C3%A9lie%20%C2%AB%20Poulain%20%C2%BB", .movie(id: "tt0211915", title: "Amélie « Poulain »")),
            ("popcorntime://search?q=%20%20dune%20%20", .search(query: "dune")),
            ("popcorntime://search?q=", .search(query: "")),
        ]
        for (url, expected) in cases {
            check(link(url) == expected, url, "got \(String(describing: link(url)))")
        }
    }

    func testLongTextsAreCut() {
        let long = String(repeating: "a", count: 5_000)
        guard case .search(let query)? = link("popcorntime://search?q=\(long)") else {
            return check(false, "a long search text is still a search")
        }
        eq(query.count, DeepLink.maximumTextLength, "a long search text is cut")
        guard case .movie(_, let title?, _)? = link("popcorntime://movie/tt1375666?title=\(long)") else {
            return check(false, "a long title is still a page link")
        }
        eq(title.count, DeepLink.maximumTextLength, "a long title is cut")
    }

    // MARK: - Not links

    func testWhatIsNotALink() {
        let urls = [
            // Other schemes; the Trakt sign-in callback of iOS and the Mac.
            "https://movie/tt1375666",
            "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            "popcorntimes://movie/tt1375666",
            "popcorntime://trakt?code=abc&state=def",
            // Nothing, or an unknown keyword.
            "popcorntime:",
            "popcorntime://",
            "popcorntime:///",
            "popcorntime://?",
            "popcorntime://person/nm0000138",
            "popcorntime://episode/tt0959621",
            // No id, an id that is not an IMDb title id, more than an id.
            "popcorntime://movie",
            "popcorntime://movie/",
            "popcorntime://show",
            "popcorntime://movie/tt",
            "popcorntime://movie/1375666",
            "popcorntime://movie/nm0000138",
            "popcorntime://movie/tt1375666x",
            "popcorntime://movie/tt13756661234567",
            "popcorntime://movie/tt1375666/extra",
            "popcorntime://movie/tt١٢٣",
            "popcorntime://movie/tt1375666%2F..%2Fsecret",
            "popcorntime://movie/tt1375666%26limit%3D50",
            "popcorntime://movie/tt1375666%3Fquery_term%3Dx",
            "popcorntime://movie/%00",
            "popcorntime://movie/tt1375666%20",
            "popcorntime://movie?id=tt1375666",
            // play: a kind and an id, nothing else.
            "popcorntime://play",
            "popcorntime://play/tt1375666",
            "popcorntime://play/movie",
            "popcorntime://play/episode/tt0959621",
            "popcorntime://play/movie/tt1375666/now",
            // An unknown tab, no tab, more than a tab.
            "popcorntime://tab",
            "popcorntime://tab/",
            "popcorntime://tab/anime",
            "popcorntime://tab/movies/top100",
            "popcorntime://tab/0",
            // search takes its text from the query only.
            "popcorntime://search/dune",
        ]
        for url in urls {
            check(link(url) == nil, "not a link: \(url)", "got \(String(describing: link(url)))")
        }
    }

    // MARK: - The Top Shelf links of 5.2.0

    /// The URL of a Top Shelf item as 5.2.0's ServiceProvider built it:
    /// URLComponents, scheme "PopcornTime", one query item `action`.
    private func topShelfURL(_ action: String) -> URL? {
        var components = URLComponents()
        components.scheme = "PopcornTime"
        components.queryItems = [URLQueryItem(name: "action", value: action)]
        return components.url
    }

    private func topShelfLink(_ action: String) -> DeepLink? {
        return topShelfURL(action).flatMap { DeepLink(url: $0) }
    }

    /// A movie or a show as ObjectMapper wrote it into the link (the keys of
    /// `Movie.mapping` / `Show.mapping`).
    private func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private var movieJSON: [String: Any] {
        return ["imdb_id": "tt1375666", "title": "Inception", "year": "2010", "runtime": "148",
                "rating": ["percentage": 88.0], "certification": "PG-13", "genres": ["Action", "Sci-Fi"],
                "synopsis": "A thief who steals corporate secrets through dream-sharing technology.",
                "images": ["poster": "https://img.example/poster.jpg?w=1000&h=1500", "fanart": "https://img.example/fanart.jpg"],
                "ids": ["tmdb": 27205], "trailer": "https://www.youtube.com/watch?v=YoHD9XEInc0"]
    }

    private var showJSON: [String: Any] {
        return ["imdb_id": "tt0903747", "title": "Breaking Bad", "year": "2008", "runtime": "47", "slug": "breaking-bad",
                "tvdb_id": "81189", "rating": ["percentage": 95.0], "genres": ["Crime", "Drama"], "status": "Ended",
                "synopsis": "A chemistry teacher turns to making drugs.", "images": ["poster": "https://img.example/bb.jpg"]]
    }

    func testTopShelfLinksOf520() {
        eq(topShelfLink("showMovie»" + json(movieJSON)), .movie(id: "tt1375666", title: "Inception"), "a movie")
        eq(topShelfLink("showShow»" + json(showJSON)), .show(id: "tt0903747", title: "Breaking Bad"), "a show")

        // The scheme as iOS and the Mac spell it, the action name in any case.
        let lower = topShelfURL("showMovie»" + json(movieJSON))?.absoluteString
            .replacingOccurrences(of: "PopcornTime:", with: "popcorntime:")
            .replacingOccurrences(of: "action=", with: "Action=")
        eq(lower.flatMap(link), .movie(id: "tt1375666", title: "Inception"), "a lower-case scheme")

        // "»" in the title and the synopsis (French quotes) cut the JSON in
        // 5.2.0: the app crashed on the half that was left.
        var quoted = movieJSON
        quoted["title"] = "Le film « culte »"
        quoted["synopsis"] = "Un « classique » : a=b&c=d, 100 % d'action + 1 suite » fin."
        eq(topShelfLink("showMovie»" + json(quoted)), .movie(id: "tt1375666", title: "Le film « culte »"), "« » in the JSON")

        // Legacy Popcorn API shows carried their id as `_id`.
        var legacyShow = showJSON
        legacyShow["imdb_id"] = nil
        legacyShow["_id"] = "tt0903747"
        eq(topShelfLink("showShow»" + json(legacyShow)), .show(id: "tt0903747", title: "Breaking Bad"), "a show with _id")

        // Only the id is required (5.2.0 also required certification,
        // runtime, tvdb_id…: a missing one crashed the app).
        eq(topShelfLink("showMovie»" + json(["imdb_id": "tt1375666"])), .movie(id: "tt1375666"), "a movie with its id only")
        eq(topShelfLink("showShow»" + json(["imdb_id": "TT0903747", "title": "  "])), .show(id: "tt0903747"), "a blank title is no title")
    }

    /// 5.2.0 crashed on every one of these (`Mapper<Movie>().map(JSONString:)!`)
    /// but the one whose percent-encoding is not UTF-8, which it ignored.
    func testBrokenTopShelfLinksAreNotLinks() {
        let actions = [
            "",
            "showMovie",
            "showMovie»",
            "showMovie»{}",
            "showShow»not-json",
            "showMovie»{\"imdb_id\":",
            "showMovie»[\"tt1375666\"]",
            "showMovie»\"tt1375666\"",
            "showMovie»null",
            "showMovie»{\"title\":\"Inception\"}",
            "showMovie»{\"imdb_id\":1375666}",
            "showMovie»{\"imdb_id\":\"../../etc\"}",
            "showMovie»{\"imdb_id\":null,\"_id\":null}",
            "showPerson»" + json(movieJSON),
            "»" + json(movieJSON),
            "play»showMovie»" + json(movieJSON),
            json(movieJSON),
        ]
        for action in actions {
            check(topShelfLink(action) == nil, "not a link: \(action.prefix(60))", "got \(String(describing: topShelfLink(action)))")
        }
        let urls = [
            "PopcornTime:?action=showMovie",
            "PopcornTime:?action=showMovie%C2%BB%7B%7D",
            "PopcornTime:?action=showShow%C2%BBnot-json",
            "PopcornTime:?action=showMovie%FF%FE",
            "PopcornTime:?action=%C2%BB",
            "PopcornTime:?other=showMovie%C2%BB%7B%22imdb_id%22%3A%22tt1375666%22%7D",
            "PopcornTime:?",
            "PopcornTime://anything",
            "PopcornTime://anything?action=showMovie%C2%BB%7B%22imdb_id%22%3A%22tt1375666%22%7D",
        ]
        for url in urls {
            check(link(url) == nil, "not a link: \(url)", "got \(String(describing: link(url)))")
        }
        // The same query on its own is a link (the cases above fail for
        // their own reason, not because of the percent-encoding).
        eq(link("PopcornTime:?action=showMovie%C2%BB%7B%22imdb_id%22%3A%22tt1375666%22%7D"), .movie(id: "tt1375666"), "percent-encoded by hand")
    }

    // MARK: - Building

    func testBuiltURLs() {
        let cases: [(DeepLink, String)] = [
            (.movie(id: "tt1375666"), "popcorntime://movie/tt1375666"),
            (.movie(id: "tt1375666", play: true), "popcorntime://play/movie/tt1375666"),
            (.movie(id: "tt1375666", title: "Inception"), "popcorntime://movie/tt1375666?title=Inception"),
            (.show(id: "tt0903747"), "popcorntime://show/tt0903747"),
            (.show(id: "tt0903747", season: 2, episode: 5), "popcorntime://show/tt0903747?season=2&episode=5"),
            (.show(id: "tt0903747", season: 2, episode: 5, play: true), "popcorntime://play/show/tt0903747?season=2&episode=5"),
            (.show(id: "tt0903747", title: "Breaking Bad", season: 1, play: true), "popcorntime://play/show/tt0903747?season=1&title=Breaking%20Bad"),
            (.search(query: "dune part two"), "popcorntime://search?q=dune%20part%20two"),
            (.search(query: ""), "popcorntime://search"),
            (.tab(.home), "popcorntime://tab/home"),
            (.tab(.downloads), "popcorntime://tab/downloads"),
        ]
        for (link, expected) in cases {
            eq(link.url?.absoluteString ?? "nil", expected, "the URL of \(link)")
        }
    }

    /// What the builder writes, the reader reads back as the same link.
    func testBuiltURLsReadBack() {
        var links: [DeepLink] = DeepLink.Tab.allCases.map { .tab($0) }
        let titles: [String?] = [nil, "Inception", "Fast & Furious", "Amélie « Poulain »", "1+1=2 ? 100 % #1", "a/b\\c;d:e@f"]
        for title in titles {
            for play in [false, true] {
                links.append(.movie(id: "tt1375666", title: title, play: play))
                links.append(.show(id: "tt0903747", title: title, play: play))
                links.append(.show(id: "tt0903747", title: title, season: 0, episode: 12, play: play))
                links.append(.show(id: "tt0903747", title: title, season: 3, play: play))
            }
        }
        links += ["", "dune", "fast & furious", "« ça »", "a=b&c=d", "1+1", "100 %", "#tag?"].map { .search(query: $0) }
        for link in links {
            guard let url = link.url else {
                check(false, "\(link) has a URL")
                continue
            }
            eq(DeepLink(url: url), link, "read back from \(url.absoluteString)")
            check(url.scheme == DeepLink.scheme, "the scheme of \(url.absoluteString)")
        }
    }

    /// What the reader would refuse or change, the builder does not write:
    /// an id that is not an IMDb title id gives no URL (never a link the
    /// app ignores), the rest is written as the reader keeps it.
    func testTheBuilderWritesWhatTheReaderKeeps() {
        for link: DeepLink in [.movie(id: "nm0000138"), .movie(id: "tt"), .movie(id: "", play: true),
                               .show(id: "tt9999999999-s1e2"), .show(id: "tt0903747/../x", season: 1, play: true),
                               .movie(id: "tt1234567890123")] {
            check(link.url == nil, "\(link) has no URL", "got \(link.url?.absoluteString ?? "nil")")
        }
        let long = String(repeating: "a", count: 199) + " " + String(repeating: "b", count: 50)
        let cases: [(DeepLink, DeepLink)] = [
            (.movie(id: "TT0816692", title: "  Interstellar \n"), .movie(id: "tt0816692", title: "Interstellar")),
            (.movie(id: "tt0816692", title: " ", play: true), .movie(id: "tt0816692", title: nil, play: true)),
            (.movie(id: "tt0816692", title: long), .movie(id: "tt0816692", title: String(repeating: "a", count: 199))),
            (.show(id: "tt0903747", season: -1, episode: 20_000), .show(id: "tt0903747")),
            (.show(id: "tt0903747", season: 9_999, episode: 0, play: true), .show(id: "tt0903747", season: 9_999, episode: 0, play: true)),
            (.search(query: "  star  "), .search(query: "star")),
            (.search(query: "\n"), .search(query: "")),
        ]
        for (link, kept) in cases {
            guard let url = link.url else {
                check(false, "\(link) has a URL")
                continue
            }
            eq(DeepLink(url: url), kept, "\(link) written as the reader keeps it (\(url.absoluteString))")
            eq(kept.url, url, "\(link) and what the reader keeps of it have the same URL")
        }
    }

    func testTabNames() {
        eq(DeepLink.Tab.allCases.map(\.rawValue), ["home", "movies", "shows", "watchlist", "search", "downloads", "settings"], "the tabs' names")
        eq(DeepLink.Tab(name: "Movies"), .movies, "a name in any case")
        eq(DeepLink.Tab(name: " settings\n"), .settings, "a name with spaces around")
        check(DeepLink.Tab(name: "") == nil, "no name")
        check(DeepLink.Tab(name: "0") == nil, "an index is not a name")
        check(DeepLink.Tab(name: "film") == nil, "an unknown name")
    }
}
