//
//  HomePresentationTests.swift
//  PopcornTimeTests
//
//  What the Apple TV's Home tab says and where it puts its rows (HomePresentation.swift,
//  an app source the bundle compiles): the billboard's facts, the cards' captions and
//  VoiceOver labels in French and in English, read through the strings files of the source
//  tree; the geometry of the page; and the hub fed from the recorded answers the UI tests
//  use (HomeFixtures.swift), loaded whole.
//

import Foundation
import XCTest
@testable import PopcornKit

final class HomePresentationTests: CheckedTestCase {

    /// A strings file of the app, by language ("fr", "en").
    private static func strings(_ language: String) -> [String: String] {
        let url = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PopcornTime/\(language).lproj/Localizable.strings")
        return (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
    }

    private static let french = strings("fr")
    private static let english = strings("en")

    private var fr: HomeText {
        return HomeText(localize: { Self.french[$0] ?? $0 }, locale: Locale(identifier: "fr_FR"))
    }

    private var en: HomeText {
        return HomeText(localize: { Self.english[$0] ?? $0 }, locale: Locale(identifier: "en_US"))
    }

    /// The system's formatters put no-break spaces between a number and its unit.
    private func plain(_ text: String) -> String {
        return text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func movie(_ title: String = "Dune: Part Two", year: Int? = 2024, rating: Double? = 8.46, genres: [String] = ["Sci-Fi", "Adventure", "Drama"],
                       runtime: Int? = 166, badges: [HomeBadge] = [], progress: Double? = nil, remaining: Int? = nil) -> HomeItem {
        return HomeItem(imdbId: "tt15239678", kind: .movie, title: title, year: year, rating: rating, genres: genres,
                        runtimeMinutes: runtime, badges: badges, progress: progress, remainingMinutes: remaining)
    }

    private func episode(season: Int = 2, number: Int = 9, title: String? = "Nervous Breakdown", aired: Date? = nil,
                         badges: [HomeBadge] = [], progress: Double? = nil, remaining: Int? = nil) -> HomeItem {
        return HomeItem(imdbId: "tt31510819", kind: .show, title: "MobLand", rating: 8.4, badges: badges,
                        episode: HomeEpisode(season: season, number: number, title: title, airDate: aired),
                        progress: progress, remainingMinutes: remaining)
    }

    // MARK: - Texts

    func testTheStringsOfTheHomeTabAreInTheFiles() {
        let keys = ["Home", "Home.Play", "More Info", "See All", "Watchlist", "Home.Menu.RemoveFromContinueWatching", "Home.Rating", "Home.Remaining",
                    "Home.Offline", "Home.Unavailable.Title", "Home.Unavailable.Message", "Try Again", "Add to Watchlist",
                    "Remove from Watchlist", "Mark as Watched", "Mark as Unwatched", "ContinueWatching.NextEpisode", "S%lld · E%lld",
                    "Content Languages", "All Languages", "Shown Shelves", "Home Shelves", "Grouped Episode Lookup",
                    "Home.Settings.All", "Home.Settings.Shelves.Count", "Home.Settings.Languages.Detail",
                    "Home.Settings.Languages.Message", "Home.Settings.Shelves.Detail", "Home.Settings.Shelves.Message",
                    "Home.Settings.Lookup.Detail", "Spinner.Loading", "Detail.Summary.InEnglish"]
        for key in keys {
            check(Self.french[key]?.isEmpty == false, "fr has \(key)")
            check(Self.english[key]?.isEmpty == false, "en has \(key)")
        }
        eq(Self.french["Home"] ?? "", "Accueil", "the tab's title")
        eq(Self.french["Home.Play"] ?? "", "Lire", "the billboard's first button")
        eq(Self.french["Home.Play"] ?? "", Self.french["Play"] ?? "-", "the same word as the page's Play button")
        eq(Self.french["More Info"] ?? "", "Plus d’infos", "its second")
        eq(Self.french["Watchlist"] ?? "", "Ma liste", "its third")
        eq(Self.french["See All"] ?? "", "Tout voir", "the last card of a shelf")
    }

    func testShelfTitles() {
        let shelf = HomeShelf(id: HomeShelfID.trendingMovies, style: .posters, items: [])
        eq(fr.title(of: shelf), "Films tendance", "a fixed shelf, in French")
        eq(en.title(of: shelf), "Trending Movies", "in English")
        let genre = HomeShelf(id: HomeShelfID.genre(.movie, "Sci-Fi"), style: .posters, items: [])
        eq(fr.title(of: genre), "Films : Science-fiction", "a genre shelf: Cinemeta's Sci-Fi under the app's translated name")
        eq(en.title(of: genre), "Science Fiction Movies", "in English")
        eq(fr.title(ofShelf: HomeShelfID.genre(.show, "Drama")), "Séries : Drame", "from the id alone (Settings)")
        eq(fr.title(ofShelf: HomeShelfID.continueWatching), "Reprendre", "Continue Watching")
        eq(fr.title(ofShelf: HomeShelfID.topShows), "Top 100 : séries", "a ranked shelf: the shows' Top 100")
        eq(en.title(ofShelf: HomeShelfID.topShows), "Top 100 Shows", "in English")
        eq(fr.title(ofShelf: HomeShelfID.topMovies), "Top 100 : films", "the movies' Top 100")
        eq(en.title(ofShelf: HomeShelfID.topMovies), "Top 100 Movies", "in English")
        for id in HomeShelfID.order where id != HomeShelfID.hero {
            check(fr.title(ofShelf: id) != HomeShelfID.defaultTitle(id) || id == "none", "\(id) has a French title", fr.title(ofShelf: id))
        }
    }

    func testFactsOfATitle() {
        eq(fr.facts(of: movie()).map(\.string).map(plain), ["2024", "Science-fiction, Aventure", "8,5", "2 h et 46 min"],
           "year, two genres, rating, runtime")
        eq(fr.facts(of: movie())[2], .rating("8,5"), "the rating is the piece drawn with a star")
        eq(en.facts(of: movie()).map(\.string).map(plain), ["2024", "Science Fiction, Adventure", "8.5", "2 hr, 46 min"], "in English")
        eq(fr.facts(of: movie(year: nil, rating: nil, genres: [], runtime: nil)), [], "nothing known, nothing said")
        eq(fr.facts(of: movie(rating: 0, runtime: 0)).map(\.string), ["2024", "Science-fiction, Aventure"], "no rating of 0, no runtime of 0")
        eq(fr.rating(7.0), "7,0", "one decimal, always")
        eq(en.rating(7.75), "7.8", "rounded")
    }

    func testFactsOfAnEpisode() {
        let aired = CatalogDates.date(from: "2026-11-14T02:00:00Z")
        eq(fr.facts(of: episode(aired: aired)).map(\.string), ["S2 · É9", "Nervous Breakdown", "14 nov.", "8,4"],
           "the episode's code, its title, its day, the show's rating")
        eq(en.facts(of: episode(aired: aired)).map(\.string), ["S2 · E9", "Nervous Breakdown", "Nov 14", "8.4"], "in English")
        eq(fr.facts(of: episode(title: " ")).map(\.string), ["S2 · É9", "8,4"], "an episode without a title or a date")
        eq(fr.facts(of: episode(title: "Episode 9", aired: aired)).map(\.string), ["S2 · É9", "14 nov.", "8,4"],
           "a placeholder title is not a title")
        eq(fr.caption(of: episode(title: "Episode 9", aired: aired)), "S2 · É9 · 14 nov.", "its card says the day instead")
        eq(fr.caption(of: episode(title: "episode 9")), "S2 · É9", "nor the day when it is not known")
        eq(fr.caption(of: episode(number: 10, title: "Episode 9")), "S2 · É10 · Episode 9", "another episode's number is a title")
    }

    func testCaptionsOfResumeCards() {
        eq(plain(fr.caption(of: movie(progress: 0.42, remaining: 33))), "Il reste 33 min", "a movie being watched")
        eq(plain(en.caption(of: movie(progress: 0.42, remaining: 33))), "33 min left", "in English")
        eq(plain(fr.caption(of: movie(progress: 0.42, remaining: 104))), "Il reste 1 h et 44 min", "more than an hour")
        eq(fr.caption(of: movie(progress: 0.42, remaining: nil)), "", "nothing known of what is left")
        eq(plain(fr.caption(of: episode(progress: 0.3, remaining: 33))), "S2 · É9 · Il reste 33 min", "an episode being watched")
        eq(fr.caption(of: episode(progress: 0, remaining: 47)), "Épisode suivant · S2 · É9", "the next episode of a show")
        eq(en.caption(of: episode(progress: 0, remaining: 47)), "Next episode · S2 · E9", "in English")
        eq(plain(fr.progressNote(of: movie(progress: 0.42, remaining: 33)) ?? ""), "Il reste 33 min", "the billboard's note")
        eq(fr.progressNote(of: episode(progress: 0, remaining: 47)) ?? "", "Épisode suivant", "a next episode")
        check(fr.progressNote(of: movie()) == nil, "no note on a catalogue card")
    }

    func testCaptionsOfEpisodeCards() {
        eq(fr.caption(of: episode()), "S2 · É9 · Nervous Breakdown", "an episode that aired")
        eq(fr.caption(of: episode(title: nil)), "S2 · É9", "without a title")
        let next = CatalogDates.date(from: "2026-11-21T02:00:00Z")
        eq(fr.caption(of: episode(number: 10, title: "The Reckoning", aired: next, badges: [.upcoming])), "S2 · É10 · 21 nov.",
           "an episode to come says when")
        eq(fr.caption(of: movie()), "2024 · Science-fiction", "a title on a landscape card: its year and first genre")
    }

    func testPillsAndFormats() {
        let item = movie(badges: [.uhd, .dolbyVision, .hdr, .atmos, .new])
        eq(fr.editorialBadge(of: item) ?? "", "Nouveau", "the pill on the artwork")
        eq(en.editorialBadge(of: item) ?? "", "New", "in English")
        eq(fr.formats(of: item) ?? "", "4K · DV · Atmos", "the formats under a poster, short: Dolby Vision says HDR")
        eq(fr.formats(of: movie(badges: [.uhd, .hdr, .atmos])) ?? "", "4K · HDR · Atmos", "HDR without Dolby Vision")
        check(fr.editorialBadge(of: movie(badges: [.uhd])) == nil, "a format is not a pill on the artwork")
        check(fr.formats(of: movie(badges: [.new])) == nil, "no formats, no text")
        eq(fr.label(of: .newEpisode), "Nouvel épisode", "a pill in French")
        eq(fr.label(of: .dolbyVision), "Dolby Vision", "a format keeps its name")
        eq(fr.editorialBadge(of: episode(badges: [.upcoming])) ?? "", "À venir", "an episode to come")
    }

    /// The sources' words (synopses, episode titles) are English: under French the Home leaves them out.
    func testWithoutTheSourcesEnglishWords() {
        var french = fr
        french.showsSourceText = false
        let aired = CatalogDates.date(from: "2026-11-14T02:00:00Z")
        eq(french.facts(of: episode(aired: aired)).map(\.string), ["S2 · É9", "14 nov.", "8,4"], "the episode by its code and its day")
        eq(french.caption(of: episode(aired: aired)), "S2 · É9 · 14 nov.", "a card says the day instead of the English title")
        eq(french.accessibilityLabel(of: episode(badges: [.newEpisode])), "MobLand, S2 · É9, IMDb 8,4, Nouvel épisode", "VoiceOver too")
        var item = movie()
        item.summary = "  A summary.  "
        check(french.summary(of: item) == nil, "no English synopsis on the billboard")
        eq(fr.summary(of: item) ?? "", "A summary.", "shown, trimmed, when the sources' words are")
        item.summary = " "
        check(fr.summary(of: item) == nil, "an empty synopsis is none")
    }

    func testPosterCaptionsAndNewShelves() {
        let item = movie(badges: [.uhd, .dolbyVision, .hdr, .atmos, .new])
        eq(fr.formats(of: item, limit: 2) ?? "", "4K · DV", "under a poster, the first two formats")
        check(fr.editorialBadge(of: item, inShelf: HomeShelfID.newMovies) == nil, "no « Nouveau » in « Nouveaux films »")
        eq(fr.editorialBadge(of: episode(badges: [.newEpisode]), inShelf: HomeShelfID.newShows) ?? "x", "x", "nor in « Nouvelles séries »")
        eq(fr.editorialBadge(of: episode(badges: [.newEpisode]), inShelf: HomeShelfID.airedEpisodes) ?? "x", "x", "nor in « Derniers épisodes diffusés »")
        eq(fr.editorialBadge(of: episode(badges: [.premiere]), inShelf: HomeShelfID.airedEpisodes) ?? "", "Première", "a premiere is still said there")
        eq(fr.editorialBadge(of: item, inShelf: HomeShelfID.trendingMovies) ?? "", "Nouveau", "elsewhere it is said")
        eq(fr.editorialBadge(of: episode(badges: [.upcoming]), inShelf: HomeShelfID.newShows) ?? "", "À venir", "what is not « new » is still said")
    }

    func testAccessibilityLabels() {
        eq(fr.accessibilityLabel(of: movie(badges: [.uhd, .dolbyVision, .new])),
           "Dune: Part Two, 2024, IMDb 8,5, 4K, Dolby Vision, Nouveau", "title, year, rating, pills")
        eq(en.accessibilityLabel(of: movie(rating: nil)), "Dune: Part Two, 2024", "no rating")
        eq(fr.accessibilityLabel(of: episode(badges: [.newEpisode])), "MobLand, S2 · É9, Nervous Breakdown, IMDb 8,4, Nouvel épisode",
           "an episode's card")
        eq(plain(fr.accessibilityLabel(of: movie(year: nil, rating: nil, progress: 0.42, remaining: 33))), "Dune: Part Two, Il reste 33 min",
           "a resume card")
        var ranked = movie(rating: nil)
        ranked.rank = 3
        eq(en.accessibilityLabel(of: ranked), "3, Dune: Part Two, 2024", "a ranked card starts with its rank")
    }

    func testWhatAWatchedMarkIsAbout() {
        let now = CatalogDates.date(from: "2026-11-15T12:00:00Z")!
        eq(movie().watchedID ?? "", "tt15239678", "a movie: itself")
        eq(episode().watchedID ?? "", LibraryID.episodeID(showID: "tt31510819", EpisodeNumber(season: 2, episode: 9)), "an episode card: its episode")
        var show = episode()
        show.episode = nil
        check(show.watchedID == nil, "a show's card without an episode: nothing to mark")
        check(movie().hasAired(now: now), "a movie can be marked")
        check(episode(aired: now.addingTimeInterval(-86400), badges: [.newEpisode]).hasAired(now: now), "an episode that aired yesterday")
        check(episode().hasAired(now: now), "an episode without an air date nor the Upcoming pill (a resume card)")
        check(!episode(aired: now.addingTimeInterval(6 * 86400), badges: [.upcoming]).hasAired(now: now), "an Upcoming card")
        check(!episode(badges: [.upcoming]).hasAired(now: now), "an Upcoming card without an air date")
        check(!episode(aired: now.addingTimeInterval(3600)).hasAired(now: now), "an air date still to come, without the pill")
    }

    func testSeeAllTabs() {
        eq(HomeSeeAll(catalogue: .movies, filter: "trending").tab, .movies, "movies")
        eq(HomeSeeAll(catalogue: .shows).tab, .shows, "shows")
        eq(HomeSeeAll(catalogue: .watchlist).tab, .watchlist, "the watchlist")
    }

    // MARK: - Geometry

    func testRowsFitTheScreenUnderTheBand() {
        let viewport: CGFloat = 1080
        for style in [HomeShelf.Style.posters, .landscape, .ranked] {
            let height = TVHomeLayout.rowHeight(of: style)
            check(TVHomeLayout.compactBand + height <= viewport, "\(style): the focused row is whole under the band", "\(height)")
            // The row lands where the band ends.
            let anchor = TVHomeLayout.anchor(band: TVHomeLayout.compactBand, rowHeight: height, viewport: viewport)
            check(anchor > 0 && anchor < 1, "\(style): an anchor inside the scroll view", "\(anchor)")
            eq(Double(anchor * (viewport - height)).rounded(), Double(TVHomeLayout.compactBand), "\(style): its top is the band's bottom")
            // The title of the next row shows under it.
            let next = TVHomeLayout.compactBand + height + TVHomeLayout.rowTopPadding + TVHomeLayout.titleHeight
            check(next <= viewport, "\(style): the next shelf's title shows under the focused one", "\(next)")
        }
        eq(TVHomeLayout.anchor(band: 376, rowHeight: 1200, viewport: 1080), 0, "a row taller than the screen: its top")
        // The first shelf shows under the hero, with the top of its cards.
        let hero = TVHomeLayout.heroHeight(viewport: viewport)
        let cards = hero + TVHomeLayout.rowTopPadding + TVHomeLayout.titleHeight + TVHomeLayout.cardPadding
        check(viewport - cards >= 60, "the first shelf's cards show under the billboard", "\(viewport - cards)")
        // The last row can reach the band.
        let shortest = TVHomeLayout.rowHeight(of: .landscape)
        check(shortest + TVHomeLayout.bottomPadding(viewport: viewport) >= viewport - TVHomeLayout.compactBand,
              "the page ends low enough for its last row to go under the band")
    }

    func testARowShowsASliverOfItsNextCard() {
        let viewport: CGFloat = 1920
        for (name, card) in [("posters", TVHomeLayout.poster), ("landscape", TVHomeLayout.landscape), ("ranked", TVHomeLayout.ranked)] {
            let sliver = TVHomeLayout.sliver(of: card, viewport: viewport)
            check(sliver >= 40 && sliver < card.width, "\(name): the next card shows at the right edge", "\(sliver)")
        }
        eq(TVHomeLayout.rankZone(of: 9) + TVHomeLayout.rankedPosterWidth, TVHomeLayout.ranked.width, "a one-digit rank is the ranked card's width")
        check(TVHomeLayout.rankZone(of: 10) > TVHomeLayout.rankZone(of: 9), "two digits take more room")
    }

    // MARK: - The hub on the recorded answers (the UI tests' page)

    private var fixturesFolder: URL {
        return Fixtures.url("Home")
    }

    func testTheRecordingsInstant() {
        eq(HomeFixtures.recordedAt, HomeFixture.now, "the app's fixtures run at the instant the unit tests' do")
    }

    func testEveryRequestOfALoadHasItsRecordedAnswer() {
        let plan = HomePlan(now: HomeFixtures.recordedAt, followedShowIds: ["tt0903747"],
                            genres: [(.movie, "Action"), (.show, "Sci-Fi")])
        for source in plan.sources {
            let answer = HomeFixtures.answer(to: source.request)
            check(answer != .none, "\(source.key) has a recorded answer")
            let data = HomeFixtures.data(answer, in: fixturesFolder)
            check(data != nil, "\(source.key): the answer reads")
            // The same bytes the unit tests' network gives.
            check(data == HomeFakeNetwork.fixture(source.request), "\(source.key): the answer of the unit tests' network")
            check(data.flatMap { HomeParse.entries($0, parser: source.parser, now: HomeFixtures.recordedAt) } != nil, "\(source.key): it parses")
        }
        eq(HomeFixtures.answer(to: HomeRequest(host: .cinemeta, path: "/meta/movie/tt0000001.json")),
           .entry(file: "cm_meta_movies.json", key: "tt0000001"), "a movie lookup")
        eq(HomeFixtures.data(.entry(file: "cm_meta_movies.json", key: "tt0000001"), in: fixturesFolder).map { String(decoding: $0, as: UTF8.self) } ?? "",
           "{}", "a title Cinemeta does not know")
        eq(HomeFixtures.answer(to: HomeRequest(host: .apibay, path: "/q.php?q=x")), .none, "a request never recorded: the host fails")
        check(HomeFixtures.data(.file("nothing.json"), in: fixturesFolder) == nil, "a file that is not there")
    }

    func testAPageLoadsFromTheFolder() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let now = HomeFixtures.recordedAt
        let feed = HomeFeed(store: HomeStore(directory: sandbox.directory, now: { now }),
                            transport: HomeFixtures.transport(folder: fixturesFolder),
                            defaults: sandbox.defaults, deviceLanguages: { ["en-US"] }, now: { now })
        var last = HomeSnapshot()
        feed.onUpdate = { last = $0 }
        var done = false
        feed.start { done = true }
        check(homeWait(10) { done }, "the load ends")
        check(homeWait(10) { feed.isIdle }, "and its lookups")
        homeSettle()
        eq(last.heroItems.count, 8, "the hero's eight titles")
        let ids = last.rows.map(\.id)
        for id in [HomeShelfID.trendingMovies, HomeShelfID.newMovies, HomeShelfID.uhd, HomeShelfID.airedEpisodes,
                   HomeShelfID.trendingShows, HomeShelfID.newShows, HomeShelfID.moviesOfTheYear, HomeShelfID.topShows,
                   HomeShelfID.topMovies] {
            check(ids.contains(id), "the page has \(id)", "\(ids)")
        }
        eq(ids.first ?? "", HomeShelfID.trendingMovies, "the shelf the UI tests reach first")
        eq(ids.dropFirst().first ?? "", HomeShelfID.newMovies, "then New Movies, whose See All is Recently Added")
        eq(last.shelf(HomeShelfID.newMovies)?.seeAll?.filter ?? "", MovieManager.Filters.date.rawValue, "its sort")
        check((last.shelf(HomeShelfID.trendingMovies)?.items.count ?? 0) >= 10, "enough cards to scroll a shelf")
        check(!last.isOffline && !last.isUnavailable, "the hosts answered")
    }

    func testNoHostAnswers() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let now = HomeFixtures.recordedAt
        let feed = HomeFeed(store: HomeStore(directory: sandbox.directory, now: { now }),
                            transport: HomeFixtures.transport(folder: fixturesFolder, isOffline: { true }),
                            defaults: sandbox.defaults, deviceLanguages: { ["en-US"] }, now: { now })
        var last = HomeSnapshot()
        feed.onUpdate = { last = $0 }
        var done = false
        feed.start { done = true }
        check(homeWait(10) { done }, "the load ends")
        homeSettle()
        check(last.isUnavailable, "nothing answered and nothing saved: the error page")
        check(last.rows.isEmpty, "no shelf")
    }
}
