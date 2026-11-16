//
//  AppLinkActionTests.swift
//  PopcornTimeTests
//
//  What the iOS app does with a popcorntime:// link (PopcornTime/UI/iOS/AppLink.swift): PopcornKit's
//  `DeepLink` says what the URL means, `AppLinkAction` which tab, sheet or page shows it — and
//  what is not a link of the app (Trakt's redirect, a screen iOS does not have).
//

import Foundation
import XCTest
@testable import PopcornKit

final class AppLinkActionTests: CheckedTestCase {


    func testLinksOnIOS() throws {
        func action(_ text: String) -> AppLinkAction? {
            URL(string: text).flatMap(AppLinkAction.init(url:))
        }
        eq(action("popcorntime://tab/home"), .tab(.home), "the Home tab")
        eq(action("popcorntime://tab/Movies"), .tab(.movies), "a tab, in any case")
        eq(action("popcorntime://tab/shows"), .tab(.shows), "Shows")
        eq(action("popcorntime://tab/watchlist"), .tab(.watchlist), "the watchlist")
        eq(action("popcorntime://tab/search"), .search(""), "the Search tab, nothing typed")
        eq(action("popcorntime://tab/settings"), .settings, "Settings is a sheet on iOS")
        eq(action("popcorntime://tab/downloads"), nil, "iOS has no Downloads screen")
        eq(action("popcorntime://search?q=dune%20part"), .search("dune part"), "a search")
        eq(action("popcorntime://movie/tt12042730?title=Project%20Hail%20Mary"),
           .page(kind: .movie, id: "tt12042730", title: "Project Hail Mary", request: MediaPageRequest(fromLink: true)), "a movie's page")
        eq(action("popcorntime://play/movie/tt12042730"),
           .page(kind: .movie, id: "tt12042730", title: nil, request: MediaPageRequest(autoPlay: true, fromLink: true)), "a movie to play")
        eq(action("popcorntime://show/tt31510819?season=2"),
           .page(kind: .show, id: "tt31510819", title: nil, request: MediaPageRequest(season: 2, fromLink: true)), "a show on a season")
        eq(action("popcorntime://play/show/tt31510819?season=2&episode=5"),
           .page(kind: .show, id: "tt31510819", title: nil, request: MediaPageRequest(autoPlay: true, season: 2, episode: 5, fromLink: true)), "an episode to play")
        eq(action("popcorntime://play/show/tt31510819?episode=5"),
           .page(kind: .show, id: "tt31510819", title: nil, request: MediaPageRequest(autoPlay: true, fromLink: true)), "an episode without its season names nothing")
        // Not links of the app.
        eq(action("popcorntime://trakt?code=abc&state=def"), nil, "Trakt's redirect is not a link to show")
        eq(action("popcorntime://movie/nm0000123"), nil, "not a title's id")
        eq(action("https://example.com/movie/tt12042730"), nil, "another scheme")
        eq(action("popcorntime://tab/nowhere"), nil, "an unknown tab")

        // Every card of the Home shares a link the app reads back.
        let movie = HomeItem(imdbId: "tt12042730", kind: .movie, title: "Project Hail Mary")
        let link = try XCTUnwrap(DeepLink.movie(id: movie.imdbId, title: movie.title).url)
        eq(AppLinkAction(url: link), .page(kind: .movie, id: "tt12042730", title: "Project Hail Mary", request: MediaPageRequest(fromLink: true)), "a shared link opens its page")
        eq(AppTab.allCases.first, .home, "Home is the first tab")
    }

    /// A link comes from outside the app (a web page, a message, a QR code): its page never
    /// picks a release by itself — the quality picker comes up, the user chooses what plays.
    func testALinkNeverPicksAlone() throws {
        for text in ["popcorntime://play/movie/tt12042730", "popcorntime://play/show/tt31510819",
                     "popcorntime://play/show/tt31510819?season=2&episode=5"] {
            guard case .page(_, _, _, let request)? = URL(string: text).flatMap(AppLinkAction.init(url:)) else {
                return XCTFail("\(text) opens a page")
            }
            check(request.autoPlay && request.fromLink, "\(text): a link's request, to play")
            check(!request.picksAlone(automaticQuality: true), "\(text): the picker, even with an automatic quality")
            check(!request.picksAlone(automaticQuality: false), "\(text): and with Always Ask")
        }
        let inApp = MediaPageRequest(autoPlay: true)
        check(inApp.picksAlone(automaticQuality: true), "a Play pressed in the app (a resume card, the carousel) follows the automatic quality")
        check(!inApp.picksAlone(automaticQuality: false), "… and Always Ask")
        let card = MediaPageRequest.home(item: HomeItem(imdbId: "tt12042730", kind: .movie, title: "Project Hail Mary"),
                                         shelfID: HomeShelfID.continueWatching, plays: true)
        check(!card.fromLink, "a Home card is not a link")
    }

    /// A link while a stream is prepared or the player is up is held, the latest only, and
    /// shown once every player is gone — as a page: it no longer plays (`AppLinkHold`).
    func testALinkWaitsForThePlayer() throws {
        func action(_ text: String) throws -> AppLinkAction {
            try XCTUnwrap(URL(string: text).flatMap(AppLinkAction.init(url:)))
        }
        let play = try action("popcorntime://play/movie/tt12042730")
        let tab = try action("popcorntime://tab/shows")
        var hold = AppLinkHold()
        eq(hold.receive(play), play, "no player: the link is shown at once, as it was asked")

        let page = UUID(), other = UUID()
        eq(hold.playerChanged(page, isUp: true), nil, "a stream starts")
        eq(hold.receive(tab), nil, "a tab asked meanwhile is held: the tab would change under the player")
        eq(hold.receive(play), nil, "a page asked meanwhile is held too")
        eq(hold.held, play.withoutPlay, "the latest link only, without its play")
        eq(hold.playerChanged(other, isUp: true), nil, "a second page's player")
        eq(hold.playerChanged(page, isUp: false), nil, "one player gone, another still up: still held")
        guard case .page(_, _, _, let request)? = hold.playerChanged(other, isUp: false) else {
            return XCTFail("the held link is shown once no player is up")
        }
        check(!request.autoPlay && request.fromLink, "… its page only, minutes after it was asked: nothing plays")
        eq(hold.held, nil, "shown once")
        eq(hold.playerChanged(page, isUp: false), nil, "a page that leaves with no player up gives nothing back")
        eq(tab.withoutPlay, tab, "a link that plays nothing is held as it is")
    }

    /// What a Home card asks of its title's page — the same on iOS and on the Mac.
    func testHomeCardsRequests() {
        let episode = HomeEpisode(season: 3, number: 2)
        let aired = HomeItem(imdbId: "tt0903747", kind: .show, title: "Breaking Bad", episode: episode)
        let movie = HomeItem(imdbId: "tt12042730", kind: .movie, title: "Project Hail Mary")
        eq(MediaPageRequest.home(item: aired, shelfID: HomeShelfID.yourShows, plays: false),
           MediaPageRequest(season: 3, episode: 2), "an episode's card opens the show on that episode's season")
        eq(MediaPageRequest.home(item: aired, shelfID: HomeShelfID.yourShows, plays: true),
           MediaPageRequest(autoPlay: true, season: 3, episode: 2), "Space on it (the Mac): that episode")
        eq(MediaPageRequest.home(item: aired, shelfID: HomeShelfID.continueWatching, plays: true),
           MediaPageRequest(autoPlay: true), "a resume card plays what the page's Play button plays")
        eq(MediaPageRequest.home(item: aired, shelfID: HomeShelfID.continueWatching, plays: false),
           MediaPageRequest(season: 3, episode: 2), "its page alone (a menu's « Details »): on its season")
        eq(MediaPageRequest.home(item: movie, shelfID: HomeShelfID.trendingMovies, plays: false),
           MediaPageRequest(), "a poster: its page")
        eq(MediaPageRequest.home(item: movie, shelfID: HomeShelfID.hero, plays: true),
           MediaPageRequest(autoPlay: true), "the carousel's Play")
    }
}
