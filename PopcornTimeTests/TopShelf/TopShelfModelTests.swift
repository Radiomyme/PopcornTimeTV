//
//  TopShelfModelTests.swift
//  PopcornTimeTests
//
//  What the Top Shelf shows, on the recorded answers of the Home (Fixtures/Home) and on pages
//  made by hand: the hero first then the newest titles, two movies for one show, a title once;
//  each card's texts in French, its formats, its two links (read back by DeepLink); only a
//  real backdrop goes full screen (YTS's blurred "background" does not); rows of posters when
//  no card has one; nothing at all rather than a card that opens nothing.
//

import Foundation
import XCTest
@testable import PopcornKit

final class TopShelfModelTests: CheckedTestCase {

    private func titleId(_ card: TopShelfModel.Card) -> String {
        return card.id.split(separator: ":").first.map(String.init) ?? card.id
    }

    // MARK: On the recorded answers

    func testTheCarouselIsTheHeroThenTheNewest() {
        let snapshot = TopShelfFixture.snapshot()
        let model = TopShelfModel(snapshot: snapshot, texts: TopShelfFixture.french)
        let hero = snapshot.heroItems
        eq(hero.count, 10, "the extension's hub makes a hero of ten")
        eq(model.carousel.count, 10, "ten cards")
        check(model.sections.isEmpty, "a carousel, not rows")
        check(!model.isEmpty, "something to show")

        // The hero's first six, in its order.
        eq(model.carousel.prefix(6).map(\.id), hero.prefix(6).map(\.id), "the hero leads")

        // Then the newest titles, with what is left of the hero where they are too few.
        let lead = Set(hero.prefix(6).map(\.imdbId))
        let newestMovies = Set(((snapshot.shelf(HomeShelfID.uhd)?.items ?? []) + (snapshot.shelf(HomeShelfID.newMovies)?.items ?? [])).map(\.id))
        let episodes = Set((snapshot.shelf(HomeShelfID.airedEpisodes)?.items ?? []).map(\.id))
        let rest = Set(hero.dropFirst(6).map(\.id))
        let tail = Array(model.carousel.dropFirst(6))
        for card in tail {
            check(!lead.contains(titleId(card)), "\(card.title): not a title of the first six")
            check(newestMovies.contains(card.id) || episodes.contains(card.id) || rest.contains(card.id),
                  "\(card.title): a new movie, a latest episode or a card of the hero")
        }
        check(tail.contains { episodes.contains($0.id) }, "a latest episode is in", "\(tail.map(\.id))")
        check(tail.contains { newestMovies.contains($0.id) && !rest.contains($0.id) }, "a new movie the hero does not show is in", "\(tail.map(\.title))")
        // The newest of a kind come before the hero's leftovers of that kind.
        for kind in HomeItem.Kind.allCases {
            let cards = tail.filter { $0.kind == kind }
            let firstLeftover = cards.firstIndex { !newestMovies.contains($0.id) && !episodes.contains($0.id) } ?? cards.count
            check(cards[firstLeftover...].allSatisfy { !newestMovies.contains($0.id) && !episodes.contains($0.id) || rest.contains($0.id) },
                  "\(kind): the newest first", "\(cards.map(\.title))")
        }

        // A title once, two movies for one show from the first card to the last.
        eq(Set(model.carousel.map(titleId)).count, 10, "a title once")
        eq(Set(model.carousel.map(\.id)).count, 10, "an id once: the system asks for it")
        eq(model.carousel.map { $0.kind == .show }, (0..<10).map { $0 % 3 == 2 }, "two movies, then a show")

        // Every card can be shown full screen, played and opened.
        for card in model.carousel {
            eq(card.wideImage?.host, "images.metahub.space", "\(card.title): a real backdrop")
            check(card.posterImage != nil, "\(card.title): a poster")
            check(!card.title.isEmpty && !(card.context ?? "").isEmpty, "\(card.title): a title and a reason")
        }
    }

    func testACardSaysWhatItIsInFrench() {
        let snapshot = TopShelfFixture.snapshot()
        let model = TopShelfModel(snapshot: snapshot, texts: TopShelfFixture.french)

        // The first card: the hero's first movie.
        guard let movie = model.carousel.first, let item = snapshot.heroItems.first else { return XCTFail("no card") }
        eq(movie.title, "Heart of the Beast", "the first card")
        eq(movie.kind, .movie, "a movie")
        eq(movie.context, "Films tendance", "why: trending")
        eq(movie.genre, "Action", "its first genre")
        eq(movie.summary, item.summary, "its summary")
        eq(movie.titledSummary, "Heart of the Beast\n" + (item.summary ?? ""), "the summary under the title, for tvOS 26")
        eq(movie.duration, 101 * 60, "101 minutes")
        eq(movie.date.map(CatalogDates.year(of:)), 2026, "its year")
        eq(movie.date, CatalogDates.date(from: "2026-07-01T12:00:00Z"), "the middle of the year: the same year in every time zone")
        eq(movie.attributes, [TopShelfModel.Attribute(name: "IMDb", values: ["7,2"])], "the rating, as French writes it")
        eq(movie.formats, [.uhd, .dolbyVision, .hdr], "the badges of the Home's card")
        eq(movie.wideImage?.absoluteString, "https://images.metahub.space/background/large/tt7526136/img", "the large backdrop")
        eq(movie.play.absoluteString, "popcorntime://play/movie/tt7526136?title=Heart%20of%20the%20Beast", "Play")
        eq(movie.display.absoluteString, "popcorntime://movie/tt7526136?title=Heart%20of%20the%20Beast", "More Info")

        // A show of the hero with an episode this week: the badge is the reason, and the card
        // says which episode (the page's latest-episodes shelf knows it).
        guard let show = model.carousel.first(where: { $0.id == "tt31510819" }) else { return XCTFail("MobLand is not in") }
        eq(show.kind, .show, "a show")
        eq(show.context, "Nouvel épisode", "why: a new episode")
        eq(show.attributes.first, TopShelfModel.Attribute(name: "Nouvel épisode", values: ["S2 · É9", "Nervous Breakdown"]), "which one")
        // Play plays the episode the card shows, not the show's next up (its pilot, for a show never watched).
        eq(DeepLink(url: show.play), .show(id: "tt31510819", title: "MobLand", season: 2, episode: 9, play: true), "Play: the episode the card shows")
        eq(DeepLink(url: show.display), .show(id: "tt31510819", title: "MobLand", season: 2, episode: 9, play: false), "More Info: the show, on that season")

        // A latest episode: the show's backdrop, and links to that episode.
        guard let episode = model.carousel.first(where: { $0.id.contains(":") }),
              let source = snapshot.shelf(HomeShelfID.airedEpisodes)?.items.first(where: { $0.id == episode.id }),
              let aired = source.episode else { return XCTFail("no episode card") }
        eq(episode.kind, .show, "an episode's card is its show's")
        eq(episode.title, source.title, "the show's title")
        eq(episode.date, aired.airDate, "the day it aired")
        eq(episode.attributes.first?.name, "Nouvel épisode", "the badge names the attribute")
        eq(episode.attributes.first?.values.first, "S\(aired.season) · É\(aired.number)", "season and episode, in French")
        eq(episode.wideImage?.absoluteString, "https://images.metahub.space/background/large/\(source.imdbId)/img", "the show's backdrop, not a still")
        eq(DeepLink(url: episode.play), .show(id: source.imdbId, title: source.title, season: aired.season, episode: aired.number, play: true),
           "Play: that episode")
        eq(DeepLink(url: episode.display), .show(id: source.imdbId, title: source.title, season: aired.season, episode: aired.number, play: false),
           "More Info: the show, on that season")
    }

    func testEveryLinkIsOneTheAppReads() {
        let snapshot = TopShelfFixture.snapshot()
        let model = TopShelfModel(snapshot: snapshot, texts: TopShelfFixture.french)
        let items = Dictionary(snapshot.shelves.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let aired = Dictionary((snapshot.shelf(HomeShelfID.airedEpisodes)?.items ?? []).compactMap { item in item.episode.map { (item.imdbId, $0) } },
                               uniquingKeysWith: { first, _ in first })
        var announcedShows = 0
        for card in model.carousel {
            guard let item = items[card.id] else { XCTFail("\(card.id): not a card of the page"); continue }
            let play = DeepLink(url: card.play), display = DeepLink(url: card.display)
            switch item.kind {
            case .movie:
                eq(play, .movie(id: item.imdbId, title: item.title, play: true), "\(item.title): Play")
                eq(display, .movie(id: item.imdbId, title: item.title, play: false), "\(item.title): More Info")
            case .show:
                // The episode the card names in its attribute, when it names one.
                let announced = item.badges.contains { [.newEpisode, .newSeason, .premiere].contains($0) }
                let shown = item.episode ?? (announced ? aired[item.imdbId] : nil)
                if item.episode == nil, let shown = shown {
                    announcedShows += 1
                    eq(card.attributes.first?.values.first, "S\(shown.season) · É\(shown.number)", "\(item.title): the episode it shows")
                }
                eq(play, .show(id: item.imdbId, title: item.title, season: shown?.season, episode: shown?.number, play: true),
                   "\(item.title): Play")
                eq(display, .show(id: item.imdbId, title: item.title, season: shown?.season, episode: shown?.number, play: false),
                   "\(item.title): More Info")
            }
            // The reader keeps what the builder wrote: the link survives a round trip.
            eq(play?.url, card.play, "\(item.title): Play, read and written again")
            eq(display?.url, card.display, "\(item.title): More Info, read and written again")
            eq(card.play.scheme, "popcorntime", "\(item.title): the app's scheme")
            check(card.play != card.display, "\(item.title): two actions")
        }
        check(announcedShows > 0, "a show's card that announces an episode is among them")
    }

    // MARK: On pages made by hand

    func testOnlyARealBackdropGoesFullScreen() {
        let page = TopShelfFixture.snapshot([
            HomeShelfID.hero: [TopShelfFixture.item("tt1000001", "Real"), TopShelfFixture.item("tt1000002", "No Backdrop", backdrop: .none),
                               TopShelfFixture.item("tt1000003", "Blurred", backdrop: .yts)],
            // The same movie as YTS lists it (blurred "background") and as Cinemeta does.
            HomeShelfID.trendingMovies: [TopShelfFixture.item("tt1000004", "Known Elsewhere")],
            HomeShelfID.newMovies: [TopShelfFixture.item("tt1000004", "Known Elsewhere", backdrop: .yts, badges: [.new]),
                                    TopShelfFixture.item("tt1000005", "Only YTS", backdrop: .yts, badges: [.new])],
            HomeShelfID.airedEpisodes: [
                TopShelfFixture.item("tt1000006", "A Show", kind: .show, backdrop: .none, badges: [.newEpisode],
                     episode: HomeEpisode(season: 1, number: 2, title: "Pilot, Part 2", stillURL: URL(string: "https://images.metahub.space/still.jpg"))),
            ],
        ])
        let model = TopShelfModel(snapshot: page, texts: TopShelfFixture.french)
        eq(model.carousel.map(\.title), ["Real", "Known Elsewhere"], "the cards with a real backdrop")
        eq(model.carousel.last?.wideImage?.absoluteString, "https://images.metahub.space/background/large/tt1000004/img",
           "the backdrop another shelf has for the title")
        eq(model.carousel.last?.context, "Nouveau", "its own badge")
        check(model.sections.isEmpty, "a carousel: no rows")
    }

    func testRowsOfPostersWhenNoCardHasABackdrop() {
        let movies = (1...15).map { TopShelfFixture.item(String(format: "tt20000%02d", $0), "Movie \($0)", backdrop: .yts) }
        let page = TopShelfFixture.snapshot([
            HomeShelfID.newMovies: movies + [TopShelfFixture.item("tt2000099", "No Poster", backdrop: .yts, poster: false)],
            HomeShelfID.uhd: [movies[0]],
            HomeShelfID.trendingShows: [TopShelfFixture.item("tt2000101", "Show A", kind: .show, backdrop: .none), TopShelfFixture.item("tt2000102", "Show B", kind: .show, backdrop: .none)],
        ])
        let model = TopShelfModel(snapshot: page, texts: TopShelfFixture.french)
        check(model.carousel.isEmpty, "no carousel")
        check(!model.isEmpty, "something to show")
        eq(model.sections.map(\.title), ["Nouveaux films", "Séries du moment"], "new movies, and the trending shows for want of episodes")
        eq(model.sections.map(\.id), [HomeShelfID.newMovies, HomeShelfID.trendingShows], "their shelves")
        eq(model.sections.first?.cards.map(\.title), (1...12).map { "Movie \($0)" }, "twelve posters at most, in the shelf's order")
        eq(model.sections.last?.cards.map(\.title), ["Show A", "Show B"], "the shows")
        check(model.sections.flatMap(\.cards).allSatisfy { $0.posterImage != nil }, "every card has a poster")
        let ids = model.sections.flatMap(\.cards).map(\.id)
        eq(Set(ids).count, ids.count, "an id once in the whole shelf")

        // The episodes' row, under its own title, when there are episodes.
        let episode = TopShelfFixture.item("tt2000103", "Show C", kind: .show, backdrop: .none, badges: [.newEpisode],
                           episode: HomeEpisode(season: 3, number: 1))
        let other = TopShelfModel(snapshot: TopShelfFixture.snapshot([HomeShelfID.trendingMovies: [movies[1]], HomeShelfID.airedEpisodes: [episode]]),
                                  texts: TopShelfFixture.french)
        eq(other.sections.map(\.title), ["Films tendance", "Derniers épisodes diffusés"], "the trending movies for want of new ones, the latest episodes")
        eq(other.sections.last?.cards.first?.play.absoluteString, "popcorntime://play/show/tt2000103?season=3&episode=1&title=Show%20C", "Play: the episode")
    }

    func testNothingRatherThanACardThatOpensNothing() {
        check(TopShelfModel(snapshot: HomeSnapshot(), texts: TopShelfFixture.french).isEmpty, "an empty page: nothing")
        var untitled = TopShelfFixture.item("tt3000002", "  ")
        untitled.summary = nil
        let page = TopShelfFixture.snapshot([HomeShelfID.hero: [TopShelfFixture.item("nm0000123", "A Person"), TopShelfFixture.item("tt3000001-s1e2", "An Episode Id"), untitled]])
        let model = TopShelfModel(snapshot: page, texts: TopShelfFixture.french)
        check(model.isEmpty, "ids no link is made of, a card without a title: no card", "\(model.carousel.map(\.title))")
        // Limits of zero: nothing, no trap.
        var rules = TopShelfModel.Rules()
        rules.limit = 0
        rules.heroCount = -1
        rules.sectionLimit = 0
        check(TopShelfModel(snapshot: TopShelfFixture.snapshot(), texts: TopShelfFixture.french, rules: rules).isEmpty, "limits of zero")
    }

    func testFormatsNumbersAndGenres() {
        let episode = HomeEpisode(season: 2, number: 5, title: "Episode 5")
        var unrated = TopShelfFixture.item("tt4000004", "Unrated", badges: [.atmos])
        unrated.rating = nil
        unrated.genres = []
        unrated.runtimeMinutes = nil
        unrated.year = nil
        let page = TopShelfFixture.snapshot([HomeShelfID.hero: [
            TopShelfFixture.item("tt4000001", "All", badges: [.uhd, .dolbyVision, .hdr, .atmos, .new]),
            TopShelfFixture.item("tt4000002", "Plain"),
            TopShelfFixture.item("tt4000003", "Episode", kind: .show, episode: episode),
            unrated,
        ]])
        let french = TopShelfModel(snapshot: page, texts: TopShelfFixture.french).carousel
        eq(french.map(\.formats), [[.uhd, .dolbyVision, .hdr, .atmos], [], [], [.atmos]], "the format badges; the others are not formats")
        eq(french.first?.context, "Nouveau", "the editorial badge is the reason")
        eq(french.first?.genre, "Science-fiction", "Cinemeta's Sci-Fi under the app's name, translated")
        eq(french.first?.attributes, [TopShelfModel.Attribute(name: "IMDb", values: ["7,3"])], "one decimal")
        // No badge: the attribute is named "Épisode"; a title that only numbers the episode is left out.
        eq(french[2].attributes.first, TopShelfModel.Attribute(name: "Épisode", values: ["S2 · É5"]), "the episode")
        eq(french[2].context, "Séries du moment", "the shelf's title when the card has no badge")
        eq(french[3].attributes, [], "no rating: no attribute")
        check(french[3].genre == nil && french[3].duration == nil && french[3].date == nil, "what the card does not know is left out")
        eq(french[3].titledSummary, "Unrated\nA summary.", "title, then summary")

        let english = TopShelfModel(snapshot: page, texts: TopShelfFixture.english).carousel
        eq(english.first?.attributes, [TopShelfModel.Attribute(name: "IMDb", values: ["7.3"])], "en_US numbers")
        eq(english.first?.context, "New", "a badge the strings do not translate reads in English, never as its key")
        eq(english[2].attributes.first, TopShelfModel.Attribute(name: "Episode", values: ["S2 · E5"]), "the format with its arguments")
    }

    /// The extension ships the app's Localizable.strings: every text it asks for is there, in
    /// every language.
    func testEveryTextIsInEveryLanguage() {
        check(TopShelfModel.localizationKeys.count >= 12, "the keys", "\(TopShelfModel.localizationKeys.count)")
        for language in ["Base", "en", "fr", "ar", "es", "it", "pt-BR"] {
            let strings = TopShelfFixture.strings(language)
            for key in TopShelfModel.localizationKeys {
                check(!(strings[key] ?? "").isEmpty, "\(language): \(key)")
            }
        }
        // In French nothing reads as a key, and nothing is left in English where French has a word.
        let model = TopShelfModel(snapshot: TopShelfFixture.snapshot(), texts: TopShelfFixture.french)
        for card in model.carousel {
            check(!(card.context ?? "").hasPrefix("Home."), "\(card.title): the reason is a text", card.context ?? "")
            check(["Films tendance", "Séries du moment", "Nouveaux films", "Nouveautés 4K", "Derniers épisodes diffusés",
                   "Nouveau", "Nouvel épisode", "Nouvelle saison", "Première", "À venir"].contains(card.context ?? ""),
                  "\(card.title): a French reason", card.context ?? "")
        }
    }
}
