//
//  HomeStreamingTests.swift
//  PopcornTimeTests
//
//  The streaming shelves ("On Netflix"): the settings (key, country, services), TMDB's
//  discover answer as cards, the plan's lists, the shelves the builder makes of them, and
//  their See All. Pure: hand-made TMDB answers, no network.
//

import Foundation
import XCTest
@testable import PopcornKit

final class HomeStreamingTests: CheckedTestCase {

    private let now = HomeFixture.now

    // MARK: Settings

    func testSettingsDefaults() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let settings = HomeSettings(defaults: sandbox.defaults, deviceLanguages: { ["fr-FR"] }, deviceRegion: { "FR" })
        check(settings.tmdbAPIKey == nil, "no key shipped")
        eq(settings.streamingRegion, "FR", "the device's region by default")
        eq(settings.streamingServices.map(\.id), [8, 119, 337, 350], "Netflix, Prime Video, Disney+, Apple TV+ by default")
        check(settings.streamingShelves.isEmpty, "no shelf without a key")

        settings.tmdbAPIKey = "  abc123  "
        eq(settings.tmdbAPIKey, "abc123", "the key, trimmed")
        eq(settings.streamingShelves.count, 4, "a key: the services' shelves")
        settings.tmdbAPIKey = ""
        check(settings.tmdbAPIKey == nil, "an empty key removes it")

        settings.streamingRegion = "be"
        eq(settings.streamingRegion, "BE", "a chosen country, upper-cased")
        settings.streamingRegion = "150"
        eq(settings.streamingRegion, "BE", "not a country: ignored")

        settings.streamingServices = [StreamingService(id: 381, name: "Canal+"), StreamingService(id: 8, name: "Netflix"),
                                      StreamingService(id: 381, name: "Canal+")]
        eq(settings.streamingServices.map(\.id), [381, 8], "the chosen services, in order, without repeats")
        settings.streamingServices = []
        check(settings.streamingServices.isEmpty, "none chosen: none (not the defaults)")

        let elsewhere = HomeSettings(defaults: sandbox.defaults, deviceRegion: { nil })
        sandbox.defaults.removeObject(forKey: HomeSettings.Key.streamingRegion)
        eq(elsewhere.streamingRegion, "US", "no region at all: the United States")
    }

    // MARK: Sources and parser

    func testSourceKeysAndPaths() {
        let source = HomeSource.streaming(service: 8, kind: .show, region: "FR", language: "fr-FR")
        eq(source.key, "tmdb-FR-8-show", "the key names the country, the service and the kind")
        eq(source.request.host, .tmdb, "TMDB's host")
        check(source.request.path.hasPrefix("/discover/tv?watch_region=FR&with_watch_providers=8"), "a discover page of TV shows")
        check(source.request.path.contains("with_watch_monetization_types=flatrate"), "subscription titles only")
        check(source.request.path.hasSuffix("&language=fr-FR"), "in the device's language")
        let parsed = HomeSource.streaming(ofKey: source.key)
        check(parsed?.region == "FR" && parsed?.service == 8 && parsed?.kind == .show, "the key read back")
        check(HomeSource.streaming(ofKey: "tpb-207") == nil, "another list's key")
        eq(HomeSource.host(ofKey: source.key), .tmdb, "the store files it under TMDB")
        eq(HomeCachePolicy.lifetime(forKey: source.key, now: now), .streaming, "kept 12 hours fresh")
        eq(TMDBStreamingClient.language(preferred: ["fr-FR", "en"]), "fr-FR", "TMDB's language")
        eq(TMDBStreamingClient.language(preferred: ["fr"]), "fr", "a language without a region")
    }

    func testDiscoverAnswer() {
        let entries = HomeParse.tmdbDiscover(Self.discover(kind: .movie, ids: ["tt0000001", "tt0000002"]), kind: .movie)
        eq(entries?.count, 2, "every result with an IMDb id")
        let first = entries?.first?.item
        eq(first?.imdbId, "tt0000001", "known by its IMDb id")
        eq(first?.title, "Title 1", "TMDB's title, in the device's language")
        eq(first?.year, 2025, "the year of its release")
        eq(first?.rating, 7.5, "TMDB's rating")
        eq(first?.genres, ["Action", "Sci-Fi"], "TMDB's genres under Cinemeta's names")
        eq(first?.posterURL?.absoluteString, "https://image.tmdb.org/t/p/w500/poster1.jpg", "TMDB's poster")
        eq(entries?.first?.language, "en", "the original language")

        let partial = HomeParse.tmdbDiscover(Self.discover(kind: .show, ids: ["tt0000003", nil, "tt0000003"]), kind: .show)
        eq(partial?.map(\.item.imdbId), ["tt0000003"], "a title without an IMDb id, and a repeat, left out")
        eq(partial?.first?.item.title, "Title 1", "a show's name")
        check(HomeParse.tmdbDiscover(Data("{\"status_code\":7}".utf8), kind: .movie) == nil, "an error is not an answer")
    }

    // MARK: Plan and shelves

    private let netflix = StreamingService(id: 8, name: "Netflix")
    private let disney = StreamingService(id: 337, name: "Disney+")

    func testPlan() {
        let plan = HomePlan(now: now, followedShowIds: [], genres: [], streaming: [netflix, disney], region: "FR")
        eq(plan.streaming.map(\.key), ["tmdb-FR-8-movie", "tmdb-FR-8-show", "tmdb-FR-337-movie", "tmdb-FR-337-show"],
           "two lists per service")
        check(plan.phase3.contains { $0.key == "tmdb-FR-8-movie" }, "asked last")
        check(plan.isCurrent("tmdb-FR-8-show") && !plan.isCurrent("tmdb-US-8-show") && !plan.isCurrent("tmdb-FR-119-show"),
              "another country's or service's list is a leftover")
        let light = HomePlan(now: now, followedShowIds: [], genres: [], light: true, streaming: [netflix], region: "FR")
        check(!light.sources.contains { $0.request.host == .tmdb }, "the Top Shelf's light refresh never asks TMDB")
    }

    func testShelves() {
        var lists = HomeFixture.allLists()
        for list in [Self.list("tmdb-FR-8-movie", kind: .movie, ids: ["tt1000001", "tt1000002", "tt1000003"]),
                     Self.list("tmdb-FR-8-show", kind: .show, ids: ["tt2000001", "tt2000002"]),
                     Self.list("tmdb-FR-337-show", kind: .show, ids: ["tt3000001"])] {
            lists[list.key] = list
        }
        var inputs = HomeFixture.inputs(lists, local: HomeLocal(), languages: ["en", "fr"], hidden: [], now: now)
        inputs.streaming = [netflix, disney, StreamingService(id: 119, name: "Prime Video")]
        inputs.region = "FR"
        let shelves = HomeBuilder.shelves(inputs, facts: HomeTitleFacts())

        let ids = shelves.map(\.id)
        eq(Array(ids.drop { $0 != HomeShelfID.newShows }.dropFirst().prefix(3)),
           [HomeShelfID.streaming(8), HomeShelfID.streaming(337), HomeShelfID.moviesOfTheYear],
           "after New Shows, in the user's order; Prime Video, without lists yet, has no shelf")
        let onNetflix = shelves.first { $0.id == HomeShelfID.streaming(8) }
        eq(onNetflix?.items.map(\.imdbId), ["tt1000001", "tt2000001", "tt1000002", "tt2000002", "tt1000003"],
           "a movie, a show, in turn")
        eq(onNetflix?.seeAll, HomeSeeAll(catalogue: .streaming, service: netflix, region: "FR"), "See All: the whole catalogue")
        eq(onNetflix?.titleArgument, "Netflix", "« On %@ »'s argument")
        eq(onNetflix?.defaultTitle, "On %@", "the title's format")
        check(onNetflix?.seeAll?.streamingPages()?.service == 8, "the pages of the service")

        inputs.hidden = [HomeShelfID.streaming(8)]
        check(!HomeBuilder.shelves(inputs, facts: HomeTitleFacts()).contains { $0.id == HomeShelfID.streaming(8) }, "a hidden shelf")
    }

    func testAlternating() {
        eq(TMDBStreamingClient.alternating([[1, 3, 5, 7], [2, 4]]), [1, 2, 3, 4, 5, 7], "one of each, then the rest")
        eq(TMDBStreamingClient.alternating([[Int]]()), [], "nothing")
    }

    func testServicesOfACountry() {
        let results: [[String: Any]] = [
            ["provider_id": 337, "provider_name": "Disney Plus", "logo_path": "/d.jpg", "display_priorities": ["FR": 3]],
            ["provider_id": 8, "provider_name": "Netflix", "display_priorities": ["FR": 1, "US": 4]],
            ["provider_id": 8, "provider_name": "Netflix", "display_priorities": ["FR": 2]],
            ["provider_id": 381, "provider_name": "Canal+", "display_priority": 2],
        ]
        let services = TMDBStreamingClient.services(results, region: "FR")
        eq(services.map(\.id), [8, 381, 337], "most watched in the country first, each once")
        eq(services.last?.logoURL?.absoluteString, "https://image.tmdb.org/t/p/w154/d.jpg", "the logo")
    }

    // MARK: Helpers

    /// A TMDB discover page as the client hands it over (nil: no IMDb id found).
    static func discover(kind: HomeItem.Kind, ids: [String?]) -> Data {
        let results: [[String: Any]] = ids.enumerated().map { index, imdb in
            var result: [String: Any] = [
                "id": 100 + index, kind == .movie ? "title" : "name": "Title \(index + 1)",
                kind == .movie ? "release_date" : "first_air_date": "2025-03-0\(index + 1)",
                "vote_average": 7.5, "vote_count": 120, "genre_ids": [28, 878], "original_language": "en",
                "poster_path": "/poster\(index + 1).jpg", "overview": "Summary \(index + 1)",
            ]
            if let imdb { result["imdb_id"] = imdb }
            return result
        }
        return try! JSONSerialization.data(withJSONObject: ["page": 1, "results": results])
    }

    static func list(_ key: String, kind: HomeItem.Kind, ids: [String]) -> HomeSourceList {
        let entries = HomeParse.tmdbDiscover(discover(kind: kind, ids: ids), kind: kind) ?? []
        return HomeSourceList(key: key, savedAt: HomeFixture.now, complete: true, entries: entries)
    }
}
