//
//  HomeScreenLogicTests.swift
//  PopcornTimeTests
//
//  What the Home screen of iOS and macOS decides without drawing (PopcornTime/UI/Shared
//  SwiftUI/Home): the words of a card, of the hero and of a shelf in French and in English
//  (`HomeCardText`, on the apps' own strings files), the carousel's rules (`HomeHeroPager`), the
//  sizes for an iPhone, an iPad and a Mac window (`HomeLayout`), when a first load replaces its
//  placeholders (`HomeFirstPaint`), the hub fed from the recorded
//  answers (`HomeRecordedTransport`, through a real `HomeFeed`), and the settings' lists
//  (`HomeSettingsModel`).
//

import Foundation
import XCTest
@testable import PopcornKit

final class HomeScreenLogicTests: CheckedTestCase {

    // MARK: - Support

    /// The apps' strings of a language, read from the source tree.
    private func strings(_ language: String) throws -> [String: String] {
        let repository = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = repository.appendingPathComponent("PopcornTime/\(language).lproj/Localizable.strings")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("the sources are not next to the test bundle") }
        return NSDictionary(contentsOf: file) as? [String: String] ?? [:]
    }

    /// Sunday 15 November 2026, 10:00 in Paris.
    private let now = CatalogDates.date(from: "2026-11-15T09:00:00Z")!

    private func text(_ language: String) throws -> HomeCardText {
        let table = try strings(language)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = Locale(identifier: language == "fr" ? "fr_FR" : "en_US")
        let now = self.now
        return HomeCardText(localize: { table[$0] ?? $0 }, locale: calendar.locale!, calendar: calendar, now: { now })
    }

    /// The formatters separate a number from its unit with a no-break space ("42 min"): the
    /// screens keep it (a number is never cut from its unit at the end of a line), the
    /// comparisons here are written with plain spaces.
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func item(_ title: String = "Project Hail Mary", kind: HomeItem.Kind = .movie, year: Int? = 2026, rating: Double? = 8.1,
                      genres: [String] = [], runtime: Int? = nil, badges: [HomeBadge] = [], rank: Int? = nil,
                      episode: HomeEpisode? = nil, progress: Double? = nil, remaining: Int? = nil) -> HomeItem {
        HomeItem(imdbId: "tt12042730", kind: kind, title: title, year: year, rating: rating, genres: genres,
                 runtimeMinutes: runtime, badges: badges, rank: rank, episode: episode, progress: progress, remainingMinutes: remaining)
    }

    // MARK: - Words

    func testCardsInFrench() throws {
        let text = try text("fr")
        // A poster: how good, how recent.
        let facts = text.posterFacts(of: item())
        eq(facts.rating, "8,1", "the rating has the locale's separator")
        eq(facts.year, "2026", "the year")
        eq(text.posterFacts(of: item(year: nil, rating: nil)).rating, nil, "an unrated title has no rating")
        eq(text.rating(of: item(rating: 0)), nil, "a rating of 0 is no rating")
        eq(text.rating(of: item(rating: 7)), "7,0", "one decimal, always")

        // Durations.
        eq(plain(text.duration(minutes: 42)), "42 min", "minutes")
        eq(plain(text.duration(minutes: 134)), "2 h 14 min", "hours and minutes")
        eq(plain(text.duration(minutes: 60)), "1 h", "a round hour")
        eq(text.duration(minutes: 0), nil, "nothing under a minute")
        eq(text.duration(minutes: nil), nil, "no runtime, no duration")

        // Resume cards.
        eq(plain(text.landscapeDetail(of: item(progress: 0.4, remaining: 72))), "Il reste 1 h 12 min", "a movie to resume")
        let episode = HomeEpisode(season: 2, number: 5, title: "The Vault")
        eq(plain(text.landscapeDetail(of: item("Fallout", kind: .show, episode: episode, progress: 0.6, remaining: 23))),
           "S2 · É5 · Il reste 23 min", "an episode to resume")
        eq(text.landscapeDetail(of: item("Fallout", kind: .show, episode: HomeEpisode(season: 2, number: 6), progress: 0, remaining: 55)),
           "Épisode suivant · S2 · É6", "the next episode, not started")
        eq(text.landscapeDetail(of: item(progress: 0.99, remaining: 0)), "", "under a minute left says nothing")
        eq(text.landscapeTitle(of: item("Fallout", kind: .show, episode: episode)), "Fallout", "an episode card is titled by its show")

        // Episode cards: which episode, when (calendar days in the user's time zone).
        func aired(_ iso: String) -> HomeItem {
            item("MobLand", kind: .show, episode: HomeEpisode(season: 2, number: 8, airDate: CatalogDates.date(from: iso)))
        }
        eq(text.landscapeDetail(of: aired("2026-11-15T02:00:00Z")), "S2 · É8 · aujourd’hui", "aired today")
        eq(text.landscapeDetail(of: aired("2026-11-14T21:00:00Z")), "S2 · É8 · hier", "last night is yesterday, not « il y a 12 heures »")
        eq(text.landscapeDetail(of: aired("2026-11-16T20:00:00Z")), "S2 · É8 · demain", "airs tomorrow")
        eq(text.landscapeDetail(of: aired("2026-11-12T20:00:00Z")), "S2 · É8 · jeu. 12 nov.", "within a week: the weekday and the day")
        eq(text.landscapeDetail(of: aired("2026-11-03T20:00:00Z")), "S2 · É8 · 3 nov.", "older: the day")
        eq(text.landscapeDetail(of: item("MobLand", kind: .show, episode: HomeEpisode(season: 1, number: 1))), "S1 · É1", "no date known")
        eq(text.landscapeDetail(of: item(rating: 7.4)), "2026 · ★ 7,4", "a title on a 16:9 card")

        // Pills.
        eq(text.cardLabel(of: .new), "NOUVEAU", "an editorial pill, in capitals")
        eq(text.cardLabel(of: .newEpisode), "NOUVEL ÉPISODE", "accents kept in capitals")
        eq(text.cardLabel(of: .dolbyVision), "DV", "Dolby Vision, short")
        eq(text.cardLabel(of: .atmos), "ATMOS", "Dolby Atmos, short")
        eq(text.cardLabel(of: .uhd), "4K", "4K")
        eq(text.cardLabel(of: .hdr), "HDR", "HDR")
        let badged = item(badges: [.uhd, .dolbyVision, .hdr, .atmos, .new, .newEpisode])
        eq(text.editorialBadge(of: badged), .new, "one editorial pill: the first")
        eq(text.formatBadges(of: badged), [.uhd, .dolbyVision, .hdr], "three formats at most")
        eq(text.formatBadges(of: badged, limit: 2), [.uhd, .dolbyVision], "two on a narrow poster")
        eq(text.editorialBadge(of: item(badges: [.uhd])), nil, "no editorial badge")
    }

    /// The line under a poster names the same formats in every row, grid and search: the two
    /// best, never hidden by the list (D1); a list only leaves off the editorial pill its title
    /// says.
    func testFormatsUnderAPosterAreTheSameInEveryList() throws {
        let text = try text("fr")
        eq(text.compactFormats(of: item(badges: [.uhd, .dolbyVision, .hdr, .atmos, .new])), ["4K", "DV"], "the two best: DV, then 4K")
        eq(text.compactFormats(of: item(badges: [.dolbyVision, .hdr, .atmos])), ["DV", "ATMOS"], "DV says HDR")
        eq(text.compactFormats(of: item(badges: [.uhd, .hdr])), ["4K", "HDR"], "4K · HDR")
        eq(text.compactFormats(of: item(badges: [.uhd])), ["4K"], "4K alone is named")
        eq(text.compactFormats(of: item(badges: [.new])), [], "no format")

        let most4K = (0..<10).map { item("Film \($0)", badges: $0 < 8 ? [.uhd] : []) }
        eq(HomeListBadges.hidden(items: most4K), [], "a grid where most films are 4K still says 4K on each")
        eq(HomeListBadges.hidden(shelfID: HomeShelfID.uhd, items: most4K), [], "even « Nouveautés 4K »")
        eq(HomeListBadges.hidden(shelfID: HomeShelfID.newMovies, items: most4K), [.new], "« Nouveaux films » leaves off NOUVEAU")
        eq(HomeListBadges.hidden(shelfID: HomeShelfID.airedEpisodes, items: []), [.newEpisode], "« Derniers épisodes » leaves off NOUVEL ÉPISODE")
        eq(HomeListBadges.hidden(shelfID: HomeShelfID.trendingMovies, items: most4K), [], "another shelf hides nothing")
        check(HomeListBadges.hidden(shelfID: HomeShelfID.uhd).allSatisfy { !$0.isFormat }, "never a format")
    }

    func testHeroAndShelvesInFrenchAndEnglish() throws {
        let french = try text("fr"), english = try text("en")
        let movie = item(genres: ["Sci-Fi", "Adventure", "Drama"], runtime: 156)
        eq(plain(french.heroFacts(of: movie)), "Film · 2026 · 2 h 36 min · Science-fiction, Aventure", "a movie's facts")
        eq(plain(french.heroFacts(of: movie, genres: 1)), "Film · 2026 · 2 h 36 min · Science-fiction", "one genre on a compact screen")
        eq(plain(english.heroFacts(of: movie)), "Movie · 2026 · 2 hr 36 min · Science Fiction, Adventure", "in English")
        eq(french.heroFacts(of: item("MobLand", kind: .show, year: 2025, genres: ["Crime"], runtime: 50)), "Série · 2025 · Policier",
           "a show has no runtime line")
        eq(french.heroFacts(of: item(year: nil)), "Film", "nothing known but the kind")

        func shelf(_ id: String) -> HomeShelf { HomeShelf(id: id, style: .posters, items: []) }
        eq(french.title(of: shelf(HomeShelfID.trendingMovies)), "Films tendance", "a shelf's title")
        eq(french.title(of: shelf(HomeShelfID.continueWatching)), "Reprendre", "Continue Watching")
        eq(french.title(of: shelf(HomeShelfID.genre(.movie, "Sci-Fi"))), "Films : Science-fiction", "a genre shelf: the format and the genre, both translated")
        eq(english.title(of: shelf(HomeShelfID.genre(.show, "Comedy"))), "Comedy Shows", "in English")
        for id in HomeShelfID.order {
            check(!french.title(of: shelf(id)).isEmpty && french.title(of: shelf(id)) != id, "\(id) has a title")
        }

        // Offline note.
        eq(plain(french.offlineDetail(lastUpdated: now.addingTimeInterval(-3 * 3600))), "Contenu enregistré il y a 3 heures.", "how old the page is")
        eq(english.offlineDetail(lastUpdated: now.addingTimeInterval(-86_400)), "Showing what was saved yesterday.", "in English")
        eq(french.offlineDetail(lastUpdated: nil), nil, "no date, no line")
        check(french.offlineDetail(lastUpdated: now.addingTimeInterval(120))?.contains("dans") == false, "a date ahead of the clock is not « in 2 minutes »")
    }

    func testVoiceOverLabels() throws {
        let french = try text("fr"), english = try text("en")
        eq(french.accessibilityLabel(of: item(badges: [.uhd, .dolbyVision, .new])),
           "Project Hail Mary, 2026, note 8,1, 4K, Dolby Vision, Nouveau", "title, year, rating, badges — the formats by their full names")
        eq(english.accessibilityLabel(of: item(rating: nil, badges: [])), "Project Hail Mary, 2026", "no rating, no badge")
        eq(french.accessibilityLabel(of: item(rank: 3)), "Numéro 3, Project Hail Mary, 2026, note 8,1", "a ranked card says its rank first")
        let episode = HomeEpisode(season: 2, number: 5, title: "The Vault")
        eq(plain(french.accessibilityLabel(of: item("Fallout", kind: .show, rating: nil, episode: episode, progress: 0.6, remaining: 23))),
           "Fallout, Saison 2, Épisode 5, The Vault, Il reste 23 min", "a resume card")
        eq(french.accessibilityLabel(of: item("Fallout", kind: .show, rating: nil, episode: HomeEpisode(season: 2, number: 6), progress: 0, remaining: 50)),
           "Fallout, Saison 2, Épisode 6, Épisode suivant", "the next episode")
        let aired = HomeEpisode(season: 1, number: 4, airDate: CatalogDates.date(from: "2026-11-14T21:00:00Z"))
        eq(french.accessibilityLabel(of: item("Nocturne", kind: .show, rating: nil, badges: [.newEpisode], episode: aired)),
           "Nocturne, Saison 1, Épisode 4, hier, Nouvel épisode", "an episode that aired")
    }

    // MARK: - Carousel

    func testHeroPager() {
        var pager = HomeHeroPager(pages: ["a", "b", "c"])
        eq(pager.front, "a", "the first page is in front")
        eq(pager.frontIndex, 0, "its index")
        check(pager.autoAdvances, "three pages, nobody on them: the carousel turns")
        eq(pager.next, "b", "the next page")
        eq(pager.previous, "c", "before the first: the last")
        pager.current = "c"
        eq(pager.next, "a", "after the last: the first")
        eq(pager.previous, "b", "the page before")
        eq(pager.frontIndex, 2, "the index follows")

        // What stops it.
        pager.isTouched = true
        check(!pager.autoAdvances, "a finger on it: it waits")
        pager.isTouched = false
        pager.isHovered = true
        check(!pager.autoAdvances, "a pointer over it: it waits")
        pager.isHovered = false
        pager.reducesMotion = true
        check(!pager.autoAdvances, "Reduce Motion: it never turns by itself")
        eq(pager.next, "a", "… but a swipe still has a next page")
        pager.reducesMotion = false
        pager.isVisible = false
        check(!pager.autoAdvances, "off screen: it waits")
        pager.isVisible = true
        check(pager.autoAdvances, "back: it turns again")

        // The featured titles change under it.
        pager.update(pages: ["x", "c", "y"])
        eq(pager.front, "c", "the page in front stays in front while it is still featured")
        eq(pager.frontIndex, 1, "at its new place")
        pager.update(pages: ["x", "y"])
        eq(pager.front, "x", "gone: back to the first page")
        eq(pager.current, nil, "and the page it was on is forgotten")

        // One page, no page.
        let single = HomeHeroPager(pages: ["a"])
        check(!single.autoAdvances && single.next == nil && single.previous == nil, "one page does not turn")
        let empty = HomeHeroPager()
        check(empty.front == nil && empty.frontIndex == 0 && !empty.autoAdvances, "no page")
        check(HomeHeroPager.interval >= 5 && HomeHeroPager.interval <= 10, "a page stays long enough to be read")
    }

    // MARK: - First paint

    func testFirstPaint() {
        let hero = HomeShelfID.hero, movies = HomeShelfID.trendingMovies, shows = HomeShelfID.trendingShows
        let new = HomeShelfID.newMovies, uhd = HomeShelfID.uhd
        // Cold: nothing from the hosts or the cache — the user's own shelves do not count.
        check(HomeFirstPaint.isCold(shelves: [], hasHero: false), "an empty page is cold")
        check(HomeFirstPaint.isCold(shelves: [HomeShelfID.continueWatching, HomeShelfID.watchlist], hasHero: false), "the library's shelves alone: still cold")
        check(!HomeFirstPaint.isCold(shelves: [movies], hasHero: false), "a list from a host: not cold")
        check(!HomeFirstPaint.isCold(shelves: [], hasHero: true), "a carousel: not cold")

        // A first load waits for the top of the page: the carousel, the rows it is made from,
        // and the catalogue rows of the first screen.
        func ready(_ shelves: [String], hero hasHero: Bool, refreshing: Bool = true, hidden: Set<String> = []) -> Bool {
            HomeFirstPaint.isReady(shelves: shelves, hasHero: hasHero, isRefreshing: refreshing, hidden: hidden)
        }
        let top = [movies, new, uhd, shows]
        check(!ready([], hero: false), "nothing yet")
        check(!ready([movies], hero: true), "the carousel made of the movies alone, the shows' list on its way: not yet")
        check(!ready([new, uhd], hero: false), "shelves that answered before the carousel: not yet")
        check(!ready([movies, new, uhd, shows], hero: false), "every row but no carousel yet: not yet")
        check(!ready([movies, shows], hero: true), "the carousel and the two Trending rows, New Movies and New in 4K on their way: not yet (they would be inserted between them)")
        check(!ready([movies, new, HomeShelfID.airedEpisodes, shows], hero: true), "New in 4K still on its way: not yet")
        check(!ready([movies, uhd, shows], hero: true), "New Movies still on its way: not yet")
        check(ready(top, hero: true), "the carousel and the rows of the first screen: shown")
        check(ready([HomeShelfID.continueWatching, movies, new, uhd, HomeShelfID.airedEpisodes, shows], hero: true), "whatever else is there")
        check(ready(top + [HomeShelfID.newShows], hero: true), "a row further down is not waited for, nor in the way")
        // The refresh is over: what there is shows (a host down, nothing at all).
        check(ready([], hero: false, refreshing: false), "the refresh is over: the error page, or an empty one")
        check(ready([movies], hero: false, refreshing: false), "the refresh is over: what came")
        check(ready([movies, shows], hero: true, refreshing: false), "the refresh is over without the new movies: what came")
        // What the user hid is not waited for.
        check(ready([movies, new, uhd, shows], hero: false, hidden: [hero]), "a hidden carousel is not waited for")
        check(ready([new, uhd, shows], hero: true, hidden: [movies]), "nor a hidden row")
        check(ready([movies, shows], hero: true, hidden: [new, uhd]), "nor hidden first-screen rows")
        check(ready([], hero: false, hidden: [hero, movies, new, uhd, shows]), "nothing to wait for")
        eq(HomeFirstPaint.awaited(hidden: []), [hero, movies, new, uhd, shows], "the top of the page")
        eq(HomeFirstPaint.awaited(hidden: [uhd]), [hero, movies, new, shows], "less what the user hid")
        // The rows waited for are the first catalogue rows of the page's order.
        let catalogue = HomeShelfID.order.filter { $0 != hero && !HomeShelfID.local.contains($0) }
        eq(Array(catalogue.prefix(3)), [movies, new, uhd], "the first three catalogue rows of the order")
        check(HomeFirstPaint.patience > 1 && HomeFirstPaint.patience <= 3, "a host that hangs holds the page a moment, not more")

        // A page already shown, a refresh starting (each return to the Home, a pull to refresh).
        let local = [HomeShelfID.continueWatching, HomeShelfID.watchlist]
        let localCold = HomeFirstPaint.isCold(shelves: local, hasHero: false)
        let localReady = ready(local, hero: false)
        check(localCold && !localReady, "the user's own shelves alone, a refresh running: cold, not ready")
        check(!HomeFirstPaint.waitsAgain(isEmpty: false, isCold: localCold, isReady: localReady, patienceSpent: false),
              "the resume cards and the watchlist stay on screen through the refresh: no placeholders again")
        check(HomeFirstPaint.waitsAgain(isEmpty: true, isCold: true, isReady: false, patienceSpent: false),
              "an empty page (Retry from the error page) shows its placeholders while the refresh runs")
        check(!HomeFirstPaint.waitsAgain(isEmpty: true, isCold: true, isReady: false, patienceSpent: true),
              "… until its patience has run out")
        check(!HomeFirstPaint.waitsAgain(isEmpty: true, isCold: true, isReady: true, patienceSpent: false),
              "… or the refresh is over")
    }

    /// The hub's own updates, recorded: a first load is shown once, whole; the cache at once.
    func testFirstPaintOnARealLoad() throws {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let folder = Fixtures.url("Home")
        let recordedAt = try XCTUnwrap(HomeRecordedTransport.recordedDate(in: folder))
        // Every page the hub makes is delivered (no spacing between updates, HomeFeedTests
        // tests that on its own): the recorded answers come within a few milliseconds, and the
        // rule has to hold against each intermediate page a slower network would show.
        var options = HomeFeed.Options()
        options.updateSpacing = 0
        func feed() -> HomeFeed {
            HomeFeed(store: HomeStore(directory: sandbox.directory, now: { recordedAt }), transport: HomeRecordedTransport(directory: folder).transport,
                     defaults: sandbox.defaults, deviceLanguages: { ["fr-FR"] }, options: options, now: { recordedAt })
        }
        func updates(of feed: HomeFeed) -> [HomeSnapshot] {
            var updates: [HomeSnapshot] = []
            feed.onUpdate = { updates.append($0) }
            let done = expectation(description: "refresh")
            feed.start { done.fulfill() }
            wait(for: [done], timeout: 20)
            return updates
        }
        func ready(_ snapshot: HomeSnapshot) -> Bool {
            HomeFirstPaint.isReady(shelves: snapshot.rows.map(\.id), hasHero: !snapshot.heroItems.isEmpty, isRefreshing: snapshot.isRefreshing, hidden: [])
        }
        func cold(_ snapshot: HomeSnapshot) -> Bool {
            HomeFirstPaint.isCold(shelves: snapshot.rows.map(\.id), hasHero: !snapshot.heroItems.isEmpty)
        }

        // A first load: the first update is cold, and the page shown first has its carousel as
        // it will stay and both Trending rows.
        let first = updates(of: feed())
        check(first.count > 3, "a first load delivers its lists one by one", "\(first.count) updates")
        check(first.first.map(cold) == true && first.first.map(ready) == false, "it starts cold, placeholders up")
        let shown = try XCTUnwrap(first.first(where: ready))
        let last = try XCTUnwrap(first.last)
        eq(shown.heroItems.map(\.id), last.heroItems.map(\.id), "the carousel shown first is the final one")
        eq(shown.shelf(HomeShelfID.trendingMovies)?.items.map(\.id), last.shelf(HomeShelfID.trendingMovies)?.items.map(\.id),
           "Trending Movies does not move once shown")
        // No row is inserted above the ones of the first screen once the page shows.
        func firstScreen(_ snapshot: HomeSnapshot) -> [String] {
            let ids = snapshot.rows.map(\.id)
            guard let end = ids.firstIndex(of: HomeShelfID.trendingShows) else { return ids }
            return Array(ids[...end])
        }
        eq(firstScreen(shown), firstScreen(last), "the rows of the first screen, as they will stay")
        for update in first.drop(while: { !ready($0) }) {
            eq(firstScreen(update), firstScreen(last), "and no later update changes them")
        }
        // What the rule spares the eye: before it, the hub had delivered a carousel that was not the final one.
        let early = first.prefix { !ready($0) }.filter { !$0.heroItems.isEmpty }
        check(early.contains { $0.heroItems.map(\.id) != last.heroItems.map(\.id) }, "the hub's first carousel was made of one list",
              "\(early.count) early carousels")

        // From the cache: the first update is the whole page.
        let again = updates(of: feed())
        let cached = try XCTUnwrap(again.first)
        check(!cold(cached), "the cache's page is not cold: shown at once")
        eq(cached.rows.map(\.id), last.rows.map(\.id), "the same page")
    }

    // MARK: - Sizes

    func testLayouts() {
        // The three classes.
        eq(HomeLayout(width: 402, height: 874).sizeClass, .compact, "an iPhone 17 Pro")
        eq(HomeLayout(width: 820, height: 1180).sizeClass, .regular, "an iPad Air 11\" in portrait")
        eq(HomeLayout(width: 1180, height: 820).sizeClass, .wide, "the same iPad in landscape")
        eq(HomeLayout(width: 1100, height: 720).sizeClass, .wide, "a Mac window")
        eq(HomeLayout(width: 700, height: 500, sizeClass: .wide).sizeClass, .wide, "a class can be imposed")

        // One grid: the detail pages' margins.
        eq(HomeLayout(width: 402, height: 874).sideInset, 16, "the iPhone grids' margin")
        eq(HomeLayout(width: 1280, height: 800).sideInset, 52, "the Mac detail page's margin")

        // A row always ends on a card that is cut, on every width from an iPhone SE to a
        // large Mac window.
        let designs: [HomeLayout.SizeClass: (poster: CGFloat, landscape: CGFloat)] =
            [.compact: (124, 236), .regular: (150, 292), .wide: (164, 320)]
        for width in stride(from: CGFloat(320), through: 2200, by: 1) {
            let layout = HomeLayout(width: width, height: 900)
            guard let design = designs[layout.sizeClass] else { continue }
            for (name, card, target) in [("poster", layout.posterWidth, design.poster), ("landscape", layout.landscapeWidth, design.landscape)] {
                let row = width - layout.sideInset
                let shown = (row + layout.cardSpacing) / (card + layout.cardSpacing)
                let cut = shown - shown.rounded(.down)
                // The cut card shows between a quarter and three quarters of itself (a point of rounding apart)…
                check(cut > 0.18 && cut < 0.77, "\(name) at \(width): the last card is cut", "\(shown) cards")
                // … and the cards never shrink under their design size nor grow past a third more.
                check(card >= target && card <= target * 1.34, "\(name) at \(width): close to its design size", "\(card) for \(target)")
                check(shown >= 1.2, "\(name) at \(width): at least one card and a piece of the next")
            }
        }
        // The rule itself.
        eq(HomeLayout.cardWidth(target: 124, spacing: 12, row: 359), 124, "the target as it is when the row already ends on a cut card")
        eq(HomeLayout.cardWidth(target: 124, spacing: 12, row: 320), 124, "… with half a card showing")
        check(HomeLayout.cardWidth(target: 124, spacing: 12, row: 414) > 124, "a row that would end between two cards: wider cards")
        check(HomeLayout.cardWidth(target: 124, spacing: 12, row: 386) > 124, "a row that would end on an almost whole card: wider cards too")
        eq(HomeLayout.cardWidth(target: 124, spacing: 12, row: 60), 124, "a row narrower than a card keeps the target")

        // The hero: tall, and the first shelf's title still shows under it.
        for (width, height) in [(CGFloat(375), CGFloat(667)), (402, 874), (440, 956), (820, 1180), (1180, 820), (1100, 700), (1728, 1000)] {
            let layout = HomeLayout(width: width, height: height)
            check(layout.heroHeight <= height * 0.7, "\(width)×\(height): room under the hero", "\(layout.heroHeight)")
            check(layout.heroHeight >= min(300, height * 0.5), "\(width)×\(height): the hero carries the screen", "\(layout.heroHeight)")
            check(layout.heroTextWidth <= width - 2 * layout.sideInset, "\(width)×\(height): the text column fits")
            check(layout.heroLogoSize.width <= layout.heroTextWidth, "\(width)×\(height): the logo fits its column")
        }
        check(!HomeLayout(width: 402, height: 874).showsHeroSynopsis, "no synopsis on an iPhone")
        check(HomeLayout(width: 820, height: 1180).showsHeroSynopsis, "a synopsis on an iPad")
        check(HomeLayout(width: 402, height: 874).centersHero && !HomeLayout(width: 1280, height: 800).centersHero, "centred on an iPhone only")

        // Artwork sizes.
        eq(HomeLayout(width: 402, height: 874).heroPixelSize(scale: 3), 1920, "an iPhone asks the backdrop at the source's size")
        check(HomeLayout(width: 820, height: 1180).heroPixelSize(scale: 2) <= 1920, "an iPad too")
        eq(HomeLayout(width: 1728, height: 1000).heroPixelSize(scale: 2), 2560, "a Retina Mac window: the detail page's cap")
        let ranked = HomeLayout(width: 402, height: 874)
        check(ranked.rankedPosterWidth < ranked.posterWidth && ranked.rankOverlap > 0, "a ranked poster leaves room for its numeral")
    }

    // MARK: - Recorded answers

    func testRecordedRequestsNameTheirFiles() {
        func file(_ host: HomeRequest.Host, _ path: String) -> String? {
            HomeRecordedTransport.fileName(for: HomeRequest(host: host, path: path))
        }
        eq(file(.cinemeta, "/catalog/movie/top.json"), "cm_movie_top.json", "Cinemeta's movies")
        eq(file(.cinemeta, "/catalog/series/top.json"), "cm_series_top.json", "its series")
        eq(file(.cinemeta, "/catalog/series/year/genre=2026.json"), "cm_series_year_2026.json", "a year's new series")
        eq(file(.cinemeta, "/catalog/series/calendar-videos/calendarVideosIds=tt1,tt2.json"), "cm_calendar.json", "the calendar")
        eq(file(.cinemeta, "/catalog/series/last-videos/lastVideosIds=tt1.json"), "cm_last_videos.json", "the last videos")
        eq(file(.cinemeta, "/meta/movie/tt12042730.json"), "cm_meta_movies.json", "a meta")
        eq(file(.cinemeta, "/catalog/movie/top/genre=Action.json"), "cm_movie_top.json", "a genre has the shape of the popular list")
        eq(file(.cinemeta, "/catalog/series/top/genre=Drama.json"), "cm_series_top.json", "a series genre too")
        eq(file(.cinemeta, "/unknown.json"), nil, "anything else is not recorded")
        let yts = "/api/v2/list_movies.json?limit=50&order_by=desc"
        eq(file(.yts, yts + "&query_term=2026&sort_by=date_added&minimum_rating=6"), "yts_new_2026.json", "YTS, the year's additions")
        eq(file(.yts, yts + "&query_term=2026&sort_by=download_count"), "yts_year_2026.json", "YTS, the year")
        eq(file(.yts, yts + "&quality=2160p&sort_by=date_added"), "yts_4k.json", "YTS, 4K")
        eq(file(.yts, yts + "&query_term=../../etc&sort_by=date_added"), nil, "a year is four digits")
        eq(file(.tvmaze, "/schedule/web?date=2026-11-14"), "tvm_web_2026-11-14.json", "TVMaze, the platforms")
        eq(file(.tvmaze, "/schedule?country=US&date=2026-11-13"), "tvm_us_2026-11-13.json", "TVMaze, the US networks")
        eq(file(.tvmaze, "/schedule/web?date=../../x"), nil, "a day is a day")
        eq(file(.apibay, "/precompiled/data_top100_208.json"), "tpb_208.json", "apibay, the shows' Top 100")
        eq(file(.apibay, "/precompiled/data_top100_48h_208.json"), "tpb_48h_208.json", "apibay, the shows' 48 h (no longer asked)")
        eq(file(.apibay, "/precompiled/data_top100_207.json"), "tpb_207.json", "apibay, the movies' Top 100")
        eq(file(.apibay, "/precompiled/data_top100_211.json"), "tpb_211.json", "apibay, 4K")
        eq(file(.apibay, "/q.php?q=x"), nil, "not a precompiled list")
    }

    func testRecordedAnswers() throws {
        let folder = Fixtures.url("Home")
        func answer(_ host: HomeRequest.Host, _ path: String) -> Data? {
            HomeRecordedTransport.answer(to: HomeRequest(host: host, path: path), in: folder)
        }
        eq(answer(.cinemeta, "/catalog/movie/top.json"), Fixtures.data("Home/cm_movie_top.json"), "a recorded answer, as recorded")
        eq(answer(.cinemeta, "/catalog/series/year/genre=2019.json"), nil, "a year not recorded: Cinemeta fails")
        // One file for every meta: the title's own answer, {} for an unknown one.
        let metas = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.data("Home/cm_meta_movies.json")) as? [String: Any])
        let known = try XCTUnwrap(metas.keys.sorted().first)
        let meta = try XCTUnwrap(answer(.cinemeta, "/meta/movie/\(known).json"))
        let decoded = try JSONSerialization.jsonObject(with: meta) as? [String: Any]
        check(decoded?["meta"] != nil, "a known title's meta")
        eq(answer(.cinemeta, "/meta/movie/tt0000001.json"), Data("{}".utf8), "an unknown title answers {}")
        let empty = try XCTUnwrap(answer(.yts, "/api/v2/list_movies.json?limit=50&query_term=2019&sort_by=date_added"))
        check(String(decoding: empty, as: UTF8.self).contains("\"movie_count\":0"), "a year YTS has nothing for: its empty page")
        eq(answer(.tvmaze, "/schedule/web?date=2026-11-01"), Data("[]".utf8), "a day without a schedule: no episode")
        eq(answer(.apibay, "/precompiled/data_top100_999.json"), nil, "a list not recorded: apibay fails")

        eq(HomeRecordedTransport.recordedDate(in: folder), HomeFixture.now, "the folder's instant is the one the fixtures were recorded at")
        eq(HomeRecordedTransport.recordedDate(in: folder.appendingPathComponent("nowhere")), nil, "no folder, no date")
    }

    /// A real hub on the recorded transport: the page the debug launches show, then the
    /// page's states.
    func testAHubFedFromTheRecordedAnswers() throws {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let folder = Fixtures.url("Home")
        let recordedAt = try XCTUnwrap(HomeRecordedTransport.recordedDate(in: folder))
        let recorded = HomeRecordedTransport(directory: folder)
        func feed(deadline: TimeInterval = 15) -> HomeFeed {
            HomeFeed(store: HomeStore(directory: sandbox.directory, now: { recordedAt }), transport: recorded.transport,
                     defaults: sandbox.defaults, deviceLanguages: { ["fr-FR"] },
                     options: HomeFeed.Options(requestDeadline: deadline), now: { recordedAt })
        }
        func load(_ feed: HomeFeed, force: Bool = false) -> HomeSnapshot {
            let done = expectation(description: "refresh")
            feed.refresh(force: force) { done.fulfill() }
            wait(for: [done], timeout: 20)
            return feed.snapshot
        }

        // Replayed: the full page. (The movies' Top 100 is there when the refresh ends; the
        // titles no list knows join it once looked up, a moment later.)
        let first = feed()
        _ = load(first)
        let ranked = expectation(description: "the movies' ranking")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            guard first.snapshot.shelf(HomeShelfID.topMovies) != nil else { return }
            timer.invalidate()
            ranked.fulfill()
        }
        wait(for: [ranked], timeout: 10)
        poll.invalidate()
        let page = first.snapshot
        eq(page.heroItems.count, 8, "the hero has its eight titles")
        check(page.heroItems.allSatisfy { $0.backdropURL != nil && $0.logoURL != nil }, "each with a backdrop and a logo")
        let ids = page.rows.map(\.id)
        for id in [HomeShelfID.trendingMovies, HomeShelfID.newMovies, HomeShelfID.uhd, HomeShelfID.airedEpisodes,
                   HomeShelfID.trendingShows, HomeShelfID.topShows, HomeShelfID.topMovies] {
            check(ids.contains(id), "the page has \(id)", "\(ids)")
        }
        check(!page.isOffline && !page.isUnavailable, "the hub is online")
        eq(page.shelf(HomeShelfID.topMovies)?.style, .ranked, "a ranking is a ranked shelf")
        check(page.shelf(HomeShelfID.topMovies)?.items.first?.rank == 1, "its first card is number 1")
        check(page.shelf(HomeShelfID.uhd)?.items.contains { $0.badges.contains(.uhd) } == true, "4K cards carry their badge")
        check(page.shelf(HomeShelfID.airedEpisodes)?.items.allSatisfy { $0.episode != nil } == true, "episode cards carry their episode")

        // Down, the cache kept: the same page, offline.
        recorded.mode = .down
        let offline = load(first, force: true)
        check(offline.isOffline && !offline.isUnavailable, "no host answers: offline")
        eq(offline.rows.map(\.id), ids, "the cached page stays")

        // Down, nothing cached: the error page.
        first.store.removeAll()
        let nothing = load(feed(), force: true)
        check(nothing.isUnavailable && nothing.shelves.isEmpty, "nothing cached and no answer: unavailable")

        // Silent: the requests are never answered; the hub's own deadline ends the wait.
        recorded.mode = .silent
        let waiting = feed(deadline: 0.3)
        var updates: [HomeSnapshot] = []
        waiting.onUpdate = { updates.append($0) }
        let end = load(waiting)
        check(updates.contains { $0.isRefreshing && $0.shelves.isEmpty }, "meanwhile the page is refreshing and empty: its placeholders")
        check(end.isUnavailable, "then nothing came")
    }

    // MARK: - Settings

    func testContentLanguages() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let settings = HomeSettings(defaults: sandbox.defaults, deviceLanguages: { ["fr-FR"] })
        let table = ["None": "Aucune"]
        let model = HomeSettingsModel(settings: settings, locale: Locale(identifier: "fr_FR"),
                                      text: HomeCardText(localize: { table[$0] ?? $0 }, locale: Locale(identifier: "fr_FR")))

        // The default: English and French.
        check(!model.showsEveryLanguage, "by default the Home filters")
        let rows = model.languages
        eq(rows.filter(\.isOn).map(\.id).sorted(), ["en", "fr"], "English and French are ticked")
        eq(rows.first { $0.id == "fr" }?.name, "Français", "named in the app's language, capitalised")
        eq(rows.map(\.name), rows.map(\.name).sorted { $0.compare($1, locale: Locale(identifier: "fr_FR")) == .orderedAscending }, "in alphabetical order")
        check(Set(rows.map(\.id)).isSuperset(of: ["en", "fr", "es", "de", "it", "ja", "ko"]), "the common languages are offered")
        eq(model.languageSummary, "Anglais et Français", "the row sums the choice up")

        // Ticking and unticking.
        model.toggleLanguage("ja")
        eq(settings.contentLanguages, ["en", "fr", "ja"], "a language is added")
        model.toggleLanguage("en")
        model.toggleLanguage("ja")
        eq(settings.contentLanguages, ["fr"], "and removed")
        model.toggleLanguage("fr")
        eq(settings.contentLanguages, ["fr"], "the last one stays: an empty list would mean every language")

        // A stored language that is not offered is still listed.
        settings.contentLanguages = ["fr", "fi"]
        check(model.languages.contains { $0.id == "fi" && $0.isOn }, "a stored language is listed")

        // Every language.
        model.setShowsEveryLanguage(true)
        check(model.showsEveryLanguage && settings.contentLanguages.isEmpty, "every language: nothing is filtered")
        eq(model.languageSummary, nil, "and the row says so")
        check(model.languages.allSatisfy { !$0.isOn }, "no language is ticked then")
        model.setShowsEveryLanguage(false)
        eq(settings.contentLanguages, ["en", "fr"], "off: back to the default choice")
    }

    func testShelvesShownAndHidden() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let settings = HomeSettings(defaults: sandbox.defaults, deviceLanguages: { ["fr-FR"] })
        let table = ["None": "Aucune", "%@ Movies": "Films : %@", "Trending Movies": "Films tendance"]
        let model = HomeSettingsModel(settings: settings, locale: Locale(identifier: "fr_FR"),
                                      text: HomeCardText(localize: { table[$0] ?? $0 }, locale: Locale(identifier: "fr_FR")))
        let action = HomeShelf(id: HomeShelfID.genre(.movie, "Action"), style: .posters, items: [])

        var rows = model.shelves(current: [action])
        eq(Array(rows.map(\.id).prefix(HomeShelfID.order.count)), HomeShelfID.order, "the fixed shelves, in the page's order")
        eq(rows.last?.id, action.id, "then the genre shelves on the page")
        eq(rows.last?.title, "Films : Action", "titled as on the page")
        check(rows.allSatisfy(\.isShown), "nothing is hidden at first")
        eq(model.hiddenSummary, "Aucune", "the row says none is hidden")

        model.setShelf(HomeShelfID.trendingMovies, shown: false)
        model.setShelf(action.id, shown: false)
        eq(settings.hiddenShelves, [HomeShelfID.trendingMovies, action.id], "two shelves hidden")
        eq(model.hiddenSummary, "2", "the row counts them")
        // The hidden genre shelf left the page: it is still listed, to be shown again.
        rows = model.shelves(current: [])
        eq(rows.first { $0.id == action.id }?.isShown, false, "a hidden genre shelf stays in the list")
        eq(rows.first { $0.id == HomeShelfID.trendingMovies }?.title, "Films tendance", "a fixed shelf's title")
        eq(rows.filter { !$0.isShown }.count, 2, "two switches are off")

        model.setShelf(action.id, shown: true)
        model.setShelf(HomeShelfID.trendingMovies, shown: true)
        check(settings.hiddenShelves.isEmpty, "shown again")
    }

    /// The open list keeps its rows where they are: a genre shown again is
    /// not on the page yet (the page is rebuilt after the list is), and a
    /// genre hidden is not sent to the end.
    func testShelvesListKeepsItsRowsWhileSwitched() {
        let sandbox = HomeSandbox()
        defer { sandbox.discard() }
        let settings = HomeSettings(defaults: sandbox.defaults, deviceLanguages: { ["fr-FR"] })
        let model = HomeSettingsModel(settings: settings, locale: Locale(identifier: "fr_FR"))
        let action = HomeShelf(id: HomeShelfID.genre(.movie, "Action"), style: .posters, items: [])
        let comedy = HomeShelf(id: HomeShelfID.genre(.movie, "Comedy"), style: .posters, items: [])
        let drama = HomeShelf(id: HomeShelfID.genre(.movie, "Drama"), style: .posters, items: [])
        let genres: ([HomeSettingsModel.Shelf]) -> [String] = { $0.map(\.id).filter { HomeShelfID.genre(of: $0) != nil } }

        var rows = model.shelves(current: [action, comedy, drama])
        eq(genres(rows), [action.id, comedy.id, drama.id], "the page's genres, in its order")

        // Hiding Action: the page still has it until rebuilt, then not.
        model.setShelf(action.id, shown: false)
        rows = model.shelves(current: [action, comedy, drama], listed: rows)
        eq(genres(rows), [action.id, comedy.id, drama.id], "hidden: the row stays first")
        rows = model.shelves(current: [comedy, drama], listed: rows)
        eq(genres(rows), [action.id, comedy.id, drama.id], "page rebuilt without it: the row stays first")
        eq(rows.first { $0.id == action.id }?.isShown, false, "its switch is off")

        // Showing it again: not on the page before the rebuild.
        model.setShelf(action.id, shown: true)
        rows = model.shelves(current: [comedy, drama], listed: rows)
        eq(genres(rows), [action.id, comedy.id, drama.id], "shown again: the row is still listed, in place")
        eq(rows.first { $0.id == action.id }?.isShown, true, "its switch is on")

        // Without the open list, a hidden genre still comes back (at the end).
        model.setShelf(drama.id, shown: false)
        eq(genres(model.shelves(current: [action, comedy])), [action.id, comedy.id, drama.id], "a reopened list keeps hidden genres")
    }
}
