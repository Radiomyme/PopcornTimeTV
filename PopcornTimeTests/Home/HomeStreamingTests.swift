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

    /// TMDB lists Amazon Prime Video as provider 119 in most countries but as 9 in Austria,
    /// Germany, the United Kingdom, Japan and the United States (TMDB, 2026-11-21: 119 is not in
    /// the US list, and a US discover of 119 answers no title). Someone there who keeps the
    /// default services must get the 9, or its card opens an empty page.
    func testTheDefaultServicesFollowTheCountry() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let american = HomeSettings(defaults: sandbox.defaults, deviceRegion: { "US" })
        eq(american.streamingServices.map(\.id), [8, 9, 337, 350], "in the United States: Prime Video is 9")
        eq(american.streamingServices.map(\.name), ["Netflix", "Amazon Prime Video", "Disney Plus", "Apple TV"], "TMDB's names")
        american.streamingRegion = "fr"
        eq(american.streamingServices.map(\.id), [8, 119, 337, 350], "the country chosen in Settings decides: France, 119")
        american.streamingRegion = "GB"
        eq(american.streamingServices.map(\.id), [8, 9, 337, 350], "the United Kingdom: 9")
        american.streamingServices = [StreamingService(id: 381, name: "Canal+"), StreamingService(id: 8, name: "Netflix")]
        eq(american.streamingServices.map(\.id), [381, 8], "services the user chose are kept as they are")
    }

    /// A choice stored in another country, or by the build before Prime Video's id depended on
    /// the country (it stored [8, 119, 337, 350] for someone in the United States), is read in
    /// the country's ids — even when TMDB never listed the new country's services to Settings
    /// (no key, no answer): a 119 there would open an empty page.
    func testAStoredChoiceReadsInTheCountrysIds() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let settings = HomeSettings(defaults: sandbox.defaults, deviceRegion: { "FR" })
        settings.streamingRegion = "US"
        settings.streamingServices = [StreamingService(id: 8, name: "Netflix"),
                                      StreamingService(id: 119, name: "Amazon Prime Video", logoPath: "/p.png"),
                                      StreamingService(id: 337, name: "Disney Plus"), StreamingService(id: 350, name: "Apple TV")]
        eq(settings.streamingServices.map(\.id), [8, 9, 337, 350], "the US: Prime Video is 9")
        eq(settings.streamingServices[1].name, "Amazon Prime Video", "its name kept")
        eq(settings.streamingServices[1].logoPath, "/p.png", "and its logo (TMDB's is the same under both ids)")
        settings.streamingRegion = "FR"
        eq(settings.streamingServices.map(\.id), [8, 119, 337, 350], "back in France: 119")
        settings.streamingServices = [StreamingService(id: 9, name: "Amazon Prime Video"), StreamingService(id: 119, name: "Amazon Prime Video")]
        eq(settings.streamingServices.map(\.id), [119], "France, a stored 9: 119, once")
    }

    /// The country changes in Settings: once TMDB lists the new country's services, the chosen
    /// ones become that country's — unless the user has meanwhile chosen another country.
    func testTheServicesFollowTheCountryChosenInSettings() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let root = (try? JSONSerialization.jsonObject(with: HomeFixture.data("tmdb_providers_US.json"))) as? [String: Any]
        let american = TMDBStreamingClient.services(root?["results"] as? [[String: Any]] ?? [], region: "US")
        let settings = HomeSettings(defaults: sandbox.defaults, deviceRegion: { "FR" })
        let french = [StreamingService(id: 8, name: "Netflix"), StreamingService(id: 119, name: "Amazon Prime Video"),
                      StreamingService(id: 381, name: "Canal+")]

        settings.streamingRegion = "FR"
        settings.streamingServices = french
        settings.streamingRegion = "US"
        check(settings.adoptServices(american, listedFor: "US"), "the US list arrives: the choice changes")
        eq(settings.streamingServices.map(\.id), [8, 9], "Prime Video is the US's 9, Canal+ is not in the US")
        check(settings.streamingServices.allSatisfy { american.contains($0) }, "TMDB's US entries (names, logos)")
        check(!settings.adoptServices(american, listedFor: "us"), "the same list again: nothing to change")

        settings.streamingRegion = "FR"
        settings.streamingServices = french
        settings.streamingRegion = "US"
        settings.streamingRegion = "FR"
        check(!settings.adoptServices(american, listedFor: "US"), "the US answer arrives after a move back to France")
        eq(settings.streamingServices.map(\.id), [8, 119, 381], "the French choice is left alone")
    }

    /// TMDB lists stores among its watch providers (Apple TV Store, Amazon Video, Rakuten TV…),
    /// and its discover cannot tie « subscription » to the service asked: with
    /// with_watch_monetization_types=flatrate, a store's list is the titles it rents or sells
    /// that some other service streams (TMDB, 2026-11-21: of the first titles of Apple TV Store,
    /// Rakuten TV, YouTube, Canal VOD, Orange VOD in France, none was a subscription title
    /// there). Settings must not offer them.
    func testStoresAreNotOfferedAsServices() {
        let root = (try? JSONSerialization.jsonObject(with: HomeFixture.data("tmdb_providers.json"))) as? [String: Any]
        let listed = TMDBStreamingClient.services(root?["results"] as? [[String: Any]] ?? [], region: "FR")
        eq(listed.map(\.id), [8, 119, 350, 337, 381, 283, 531, 1899], "the recorded French list without Apple TV Store and Amazon Video")
        let results: [[String: Any]] = [
            ["provider_id": 8, "provider_name": "Netflix", "display_priorities": ["FR": 0]],
            ["provider_id": 35, "provider_name": "Rakuten TV", "display_priorities": ["FR": 1]],
            ["provider_id": 192, "provider_name": "YouTube", "display_priorities": ["FR": 2]],
            ["provider_id": 9999, "provider_name": "Some Store", "display_priorities": ["FR": 3]],
            ["provider_id": 9998, "provider_name": "Some VOD", "display_priorities": ["FR": 4]],
            ["provider_id": 234, "provider_name": "Arte", "display_priorities": ["FR": 5]],
            ["provider_id": 188, "provider_name": "YouTube Premium", "display_priorities": ["FR": 6]],
            ["provider_id": 60, "provider_name": "Fandango", "display_priorities": ["FR": 7]],
            ["provider_id": 332, "provider_name": "Fandango at Home Free", "display_priorities": ["FR": 8]],
        ]
        eq(TMDBStreamingClient.services(results, region: "FR").map(\.id), [8, 234, 188, 332],
           "stores left out, by id or by a name that says so; free services (Arte, Fandango at Home Free) and YouTube Premium kept")
    }

    /// The Home's filter lasts for the run of the app only, and a hidden « Services » row
    /// means the usual page (its « All » card is the only way back).
    func testServiceFilterLastsTheSessionOnly() {
        let sandbox = HomeSandbox()
        defer {
            HomeSettings(defaults: sandbox.defaults).homeServiceFilter = nil
            sandbox.discard()
        }
        let settings = HomeSettings(defaults: sandbox.defaults, deviceRegion: { "FR" })
        settings.tmdbAPIKey = "abc123"
        // What an earlier build kept across launches.
        sandbox.defaults.set(8, forKey: HomeSettings.Key.serviceFilter)
        check(settings.homeService == nil, "a filter an earlier build stored is not read: a launch opens on the usual page")
        _ = HomeFeed(store: HomeStore(directory: sandbox.directory), transport: HomeFakeNetwork().transport, defaults: sandbox.defaults)
        check(sandbox.defaults.object(forKey: HomeSettings.Key.serviceFilter) == nil, "and it is removed")

        settings.homeServiceFilter = 8
        eq(settings.homeService?.id, 8, "a service picked")
        check(sandbox.defaults.object(forKey: HomeSettings.Key.serviceFilter) == nil, "kept in memory, not in the defaults")
        eq(HomeSettings(defaults: sandbox.defaults).homeServiceFilter, 8, "every reader of the run sees it")

        settings.setShelf(HomeShelfID.services, hidden: true)
        check(settings.homeService == nil, "the « Services » row hidden: the usual page")
        settings.setShelf(HomeShelfID.services, hidden: false)
        eq(settings.homeService?.id, 8, "shown again: the service picked is back")
        settings.homeServiceFilter = nil
        check(settings.homeService == nil, "« All »")
    }

    // MARK: Sources and parser

    func testSourceKeysAndPaths() {
        let source = HomeSource.streaming(service: 8, kind: .show, sort: .popular, region: "FR", today: "2026-11-14")
        eq(source.key, "tmdb-FR-8-show-popular", "the key names the country, the service, the kind and the order")
        eq(source.request.host, .tmdb, "TMDB's host")
        check(source.request.path.hasPrefix("/discover/tv?watch_region=FR&with_watch_providers=8"), "a discover page of TV shows")
        check(source.request.path.contains("with_watch_monetization_types=flatrate%7Cfree%7Cads&"),
              "titles watched with a subscription, free or with ads: a free service's own titles too, no rentals asked")
        let types = URLComponents(string: "https://api.themoviedb.org/3" + source.request.path)?.queryItems?
            .first { $0.name == "with_watch_monetization_types" }?.value
        eq(types, "flatrate|free|ads", "a URL the system accepts, TMDB's « or » once decoded")
        check(source.request.path.contains("sort_by=popularity.desc"), "most popular first")
        check(source.request.path.hasSuffix("&language=en-US"), "in English, as the app names its titles (Cinemeta's), whatever the device's language")
        let parsed = HomeSource.streaming(ofKey: source.key)
        check(parsed?.region == "FR" && parsed?.service == 8 && parsed?.kind == .show && parsed?.sort == .popular, "the key read back")
        check(HomeSource.streaming(ofKey: "tpb-207") == nil, "another list's key")
        eq(HomeSource.host(ofKey: source.key), .tmdb, "the store files it under TMDB")
        eq(HomeCachePolicy.lifetime(forKey: source.key, now: now), .streaming, "kept 12 hours fresh")

        let recent = TMDBStreamingClient.discoverPath(service: 8, kind: .movie, region: "FR", page: 2, sort: .recent, genre: 878,
                                                      today: "2026-11-14")
        check(recent.contains("sort_by=primary_release_date.desc&primary_release_date.lte=2026-11-14"), "recent: released by today")
        check(recent.contains("&with_genres=878&page=2"), "a genre, a page")
        check(TMDBStreamingClient.discoverPath(service: 8, kind: .show, region: "FR", page: 1, sort: .topRated)
                .contains("sort_by=vote_average.desc&vote_count.gte=150"), "top rated: among titles with many votes")
        eq(TMDBStreamingClient.genreId("Science Fiction", kind: .movie), 878, "the app's genre, TMDB's id")
        eq(TMDBStreamingClient.genreId("Science Fiction", kind: .show), 10765, "the shows' own id")
        check(TMDBStreamingClient.genreId("Thriller", kind: .show) == nil && TMDBStreamingClient.genreId("All", kind: .movie) == nil,
              "TMDB has no id for these")
        eq(TMDBStreamingClient.genreId("Music", kind: .movie), 10402, "Music: TMDB's movies have it (Cinemeta has not)")
        check(TMDBStreamingClient.genreId("Music", kind: .show) == nil, "not its shows")
        // The genres a grid offers while a service is chosen.
        let movies = NetworkManager.Genres.movies.filter { TMDBStreamingClient.supportsGenre($0.rawValue, kind: .movie) }
        eq(movies.map(\.rawValue), ["All", "Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama", "Family",
                                    "Fantasy", "History", "Horror", "Music", "Mystery", "Romance", "Science Fiction", "Thriller", "War", "Western"],
           "the movies' genres TMDB can filter on (not Film Noir, not Sports)")
        let shows = NetworkManager.Genres.shows.filter { TMDBStreamingClient.supportsGenre($0.rawValue, kind: .show) }
        eq(shows.map(\.rawValue), ["All", "Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama", "Family",
                                   "Fantasy", "Mystery", "Science Fiction", "War", "Western"],
           "the shows' (not Horror, History, Romance, Thriller, Sports)")
    }

    /// While a service is chosen the grids' Sort offers only what its list
    /// is really in, under the app's own names (Popular, Top Rated, New).
    func testTheSortsAGridOffersWithAService() {
        eq(MovieManager.Filters.streamingArray, [.popularity, .rating, .year], "Movies: Popular, Top Rated, New")
        eq(MovieManager.Filters.streamingArray.compactMap(\.streamingSort), [.popular, .topRated, .recent], "each its own TMDB order")
        for filter in [MovieManager.Filters.trending, .top100, .date] {
            check(filter.streamingSort == nil, "\(filter): an order TMDB's lists cannot follow")
        }
        eq(ShowManager.Filters.streamingArray, [.popularity, .rating, .year], "Shows: Popular, Top Rated, New")
        eq(ShowManager.Filters.streamingArray.compactMap(\.streamingSort), [.popular, .topRated, .recent], "each its own TMDB order")
        for filter in [ShowManager.Filters.trending, .top100, .date, .name] {
            check(filter.streamingSort == nil, "\(filter): not offered with a service (A - Z would be TMDB's popularity)")
        }
        eq(Set(StreamingSort.allCases), Set(MovieManager.Filters.streamingArray.compactMap(\.streamingSort)), "every order a service lists is offered")
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
        let usual = HomePlan(now: now, followedShowIds: [], genres: [], region: "FR")
        check(!usual.sources.contains { $0.request.host == .tmdb }, "the usual page asks TMDB nothing")
        let plan = HomePlan(now: now, followedShowIds: [], genres: [], service: netflix, region: "FR")
        eq(plan.streaming.map(\.key), ["tmdb-FR-8-movie-popular", "tmdb-FR-8-show-popular", "tmdb-FR-8-movie-recent",
                                       "tmdb-FR-8-show-recent", "tmdb-FR-8-movie-topRated", "tmdb-FR-8-show-topRated"],
           "a filtered page: six lists of its service")
        check(plan.phase1.prefix(6).allSatisfy { $0.request.host == .tmdb }, "asked first: they are the page")
        check(plan.isCurrent("tmdb-FR-8-show-recent") && !plan.isCurrent("tmdb-US-8-show-recent") && !plan.isCurrent("tmdb-FR-119-show-recent"),
              "another country's or service's list is a leftover")
        let offered = HomePlan(now: now, followedShowIds: [], genres: [], offered: [8, 119], region: "FR")
        check(offered.streaming.isEmpty, "the usual page asks no service's list")
        check(offered.isCurrent("tmdb-FR-8-movie-popular") && offered.isCurrent("tmdb-FR-119-show-recent"),
              "but keeps the lists of the services offered, in the country (« All », another service)")
        check(!offered.isCurrent("tmdb-FR-337-show-recent") && !offered.isCurrent("tmdb-US-8-movie-popular") && !offered.isCurrent("tmdb-junk"),
              "not a service unchecked, another country's, or a key it cannot read")
        let light = HomePlan(now: now, followedShowIds: [], genres: [], light: true, service: netflix, region: "FR")
        check(!light.sources.contains { $0.request.host == .tmdb }, "the Top Shelf's light refresh never asks TMDB")
    }

    func testServicesRowOnTheUsualPage() {
        var inputs = HomeFixture.inputs(HomeFixture.allLists(), now: now)
        eq(HomeBuilder.shelves(inputs, facts: HomeTitleFacts()).map(\.id).contains(HomeShelfID.services), false, "no services: no row")
        inputs.streaming = [netflix, disney]
        inputs.region = "FR"
        let shelves = HomeBuilder.shelves(inputs, facts: HomeTitleFacts())
        let row = shelves.first { $0.id == HomeShelfID.services }
        eq(shelves.map(\.id).prefix(2), [HomeShelfID.hero, HomeShelfID.services], "under the hero (no resume card here)")
        eq(row?.items.map(\.id), ["service-8", "service-337"], "a card per service, no « All »")
        check(row?.items.allSatisfy { !HomeServiceCard.isSelected($0) } == true, "none checked")
        eq(HomeServiceCard.serviceId(of: row!.items[1]), 337, "what a card picks")
        check(row?.seeAll == nil, "nothing more behind it")
        check(!shelves.contains { HomeShelfID.streaming(of: $0.id) != nil }, "no service shelf on the usual page")
    }

    func testFilteredPage() {
        var lists = HomeFixture.allLists()
        for list in [Self.list("tmdb-FR-8-movie-popular", kind: .movie, ids: ["tt1000001", "tt1000002", "tt1000003"]),
                     Self.list("tmdb-FR-8-show-popular", kind: .show, ids: ["tt2000001", "tt2000002"]),
                     Self.list("tmdb-FR-8-show-topRated", kind: .show, ids: ["tt3000001"])] {
            lists[list.key] = list
        }
        var inputs = HomeFixture.inputs(lists, now: now)
        inputs.streaming = [netflix, disney]
        inputs.service = netflix
        inputs.region = "FR"
        inputs.allServicesTitle = "Tous"
        let shelves = HomeBuilder.shelves(inputs, facts: HomeTitleFacts())

        eq(shelves.map(\.id), [HomeShelfID.hero, HomeShelfID.services, HomeShelfID.streaming(8, .movie, .popular),
                                HomeShelfID.streaming(8, .show, .popular), HomeShelfID.streaming(8, .show, .topRated)],
           "the service's shelves only, a list not in yet has none")
        eq(shelves[0].items.map(\.imdbId), ["tt1000001", "tt2000001", "tt1000002", "tt2000002", "tt1000003"],
           "the hero: its popular movies and shows in turn")
        let row = shelves[1]
        eq(row.items.map(\.id), [HomeServiceCard.allId, "service-8", "service-337"], "« All » first")
        eq(row.items.first?.title, "Tous", "in the app's language")
        check(HomeServiceCard.isSelected(row.items[1]) && !HomeServiceCard.isSelected(row.items[2]), "Netflix checked")
        check(HomeServiceCard.serviceId(of: row.items[0]) == nil && HomeServiceCard.isAll(row.items[0]), "« All »: no service")

        let movies = shelves[2]
        eq(movies.items.map(\.imdbId), ["tt1000001", "tt1000002", "tt1000003"], "every title, even shown in the hero")
        eq(movies.defaultTitle, "Popular Movies on %@", "the title's format")
        eq(movies.titleArgument, "Netflix", "its argument")
        eq(movies.seeAll, HomeSeeAll(catalogue: .streaming, filter: "popular", service: netflix, region: "FR", kind: .movie),
           "See All: the service's movies, in that order")
        let pages = movies.seeAll?.streamingPages()
        check(pages?.service == 8 && pages?.kinds == [.movie] && pages?.sort == .popular, "its pages")
    }

    /// Settings › Services stores TMDB's entries for the services chosen (their logos): the
    /// row's cards keep the names the user first saw only if the defaults are TMDB's names.
    /// This checks the defaults against the hand-made tmdb_providers.json
    /// (tools/tmdb-fixtures.py), whose ids and names are the ones TMDB's API gave for France on
    /// 2026-11-21 (350 is « Apple TV » there, no longer « Apple TV Plus »).
    func testTheDefaultServicesHaveTMDBsNames() {
        for (region, file) in [("FR", "tmdb_providers.json"), ("US", "tmdb_providers_US.json")] {
            let root = (try? JSONSerialization.jsonObject(with: HomeFixture.data(file))) as? [String: Any]
            let listed = TMDBStreamingClient.services(root?["results"] as? [[String: Any]] ?? [], region: region)
            let names = Dictionary(listed.map { ($0.id, $0.name) }) { first, _ in first }
            for service in StreamingService.defaults(for: region) {
                eq(service.name, names[service.id], "\(region), service \(service.id): in the country's list, under TMDB's own name")
            }
        }
    }

    /// A new country: the services chosen become that country's (Settings, when TMDB lists them).
    func testTheChosenServicesFollowANewCountry() {
        let root = (try? JSONSerialization.jsonObject(with: HomeFixture.data("tmdb_providers_US.json"))) as? [String: Any]
        let american = TMDBStreamingClient.services(root?["results"] as? [[String: Any]] ?? [], region: "US")
        let french = StreamingService.defaults(for: "FR") + [StreamingService(id: 381, name: "Canal+")]
        let matched = StreamingService.matching(french, in: american)
        eq(matched.map(\.id), [8, 9, 337, 350], "Prime Video becomes the US's 9 by its name; Canal+, not in the US, is left out")
        check(matched.allSatisfy { service in american.contains(service) }, "TMDB's entries for the country")
        eq(StreamingService.matching([StreamingService(id: 350, name: "Apple TV Plus")], in: american).first?.name, "Apple TV",
           "a service the country has keeps its id and takes TMDB's name of today")
        eq(StreamingService.matching([StreamingService(id: 119, name: "amazon prime video"), StreamingService(id: 9, name: "Amazon Prime Video")],
                                     in: american).map(\.id), [9], "the same service once")
        eq(StreamingService.matching(french, in: []).count, 0, "a country with no service: none")
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
        eq(services.last?.logoURL?.absoluteString, "https://image.tmdb.org/t/p/w300/d.jpg", "the logo")
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
