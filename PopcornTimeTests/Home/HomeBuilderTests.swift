//
//  HomeBuilderTests.swift
//  PopcornTimeTests
//
//  The shelves made from the lists: order, hero, the "two shelves at most" rule, languages,
//  the year rollover, twins, the stand-ins when a source is missing, the local shelves. Pure:
//  the lists are the recorded answers of 2026-11-14, `now` is the moment they were recorded.
//

import Foundation
import XCTest
@testable import PopcornKit

final class HomeBuilderTests: CheckedTestCase {

    private let now = HomeFixture.now
    private let year = 2026

    private func build(_ lists: [String: HomeSourceList], local: HomeLocal = HomeLocal(), languages: [String] = ["en", "fr"],
                       hidden: Set<String> = [], now: Date = HomeFixture.now, rules: HomeBuilder.Rules = HomeBuilder.Rules()) -> [HomeShelf] {
        return HomeBuilder.shelves(HomeFixture.inputs(lists, local: local, languages: languages, hidden: hidden, now: now), rules: rules)
    }

    private func lists(_ sources: [HomeSourceList]) -> [String: HomeSourceList] {
        return Dictionary(uniqueKeysWithValues: sources.map { ($0.key, $0) })
    }

    // MARK: The whole page

    func testShelvesOfAFullLoad() {
        let shelves = build(HomeFixture.allLists())
        eq(shelves.ids, [HomeShelfID.hero, HomeShelfID.trendingMovies, HomeShelfID.newMovies, HomeShelfID.uhd,
                         HomeShelfID.airedEpisodes, HomeShelfID.trendingShows, HomeShelfID.newShows,
                         HomeShelfID.moviesOfTheYear, HomeShelfID.topRatedOfTheYear, HomeShelfID.top48hShows],
           "the order of the page; no local shelf without a library, no ranking of fewer than five known titles")
        eq(shelves.map(\.style), [.hero, .posters, .posters, .posters, .landscape, .posters, .posters, .posters, .posters, .ranked], "styles")
        check(shelves.allSatisfy { !$0.items.isEmpty }, "no empty shelf")
        check(shelves.allSatisfy { !$0.isStale && $0.updatedAt == now }, "lists fetched now are not stale")
        for shelf in shelves {
            eq(Set(shelf.items.map(\.id)).count, shelf.items.count, "\(shelf.id): ids are unique in a shelf")
        }
        eq(shelves.shelf(HomeShelfID.trendingMovies)?.seeAll, HomeSeeAll(catalogue: .movies, filter: "trending"), "see all: the movies grid, Trending")
        eq(shelves.shelf(HomeShelfID.newMovies)?.seeAll?.movieFilter, .date, "see all: Recently Added")
        eq(shelves.shelf(HomeShelfID.airedEpisodes)?.seeAll?.showFilter, .date, "see all: the shows grid")
        eq(shelves.shelf(HomeShelfID.top48hShows)?.seeAll?.showFilter, .top100, "see all: Top 100")
        check(shelves.shelf(HomeShelfID.hero)?.seeAll == nil && shelves.shelf(HomeShelfID.uhd)?.seeAll == nil, "nothing more to show behind the hero and 4K")
    }

    func testHero() {
        let shelves = build(HomeFixture.allLists())
        let hero = shelves.shelf(HomeShelfID.hero)!
        // movie/top in order, 2025 and later only (Halloween 1978 is trending, not featured);
        // series/top in order; two movies for one show.
        eq(hero.titles, ["Heart of the Beast", "Resident Evil", "MobLand", "Primetime", "Obsession", "Nocturne",
                         "A Dog's Perfect Christmas", "Verity"], "two movies, one show, in the catalogs' order")
        check(hero.items.allSatisfy { $0.backdropURL != nil && $0.logoURL != nil }, "every hero card has a backdrop and a logo")
        check(hero.items.allSatisfy { ($0.year ?? 0) >= year - 1 }, "recent titles")
        eq(hero.items[0].trailerCode, "UkMuGKqAux4", "the trailer comes along")
        eq(hero.items[0].badges, [.uhd, .dolbyVision, .hdr], "Heart of the Beast: a 4K Dolby Vision release is seeded")
        eq(hero.items[1].badges, [.uhd, .dolbyVision, .hdr, .atmos], "Resident Evil")
        eq(hero.items[2].badges, [.newEpisode], "MobLand: an episode aired yesterday")
        check(hero.items[2].episode == nil, "a show's hero card is the show, not an episode")
        eq(hero.items[3].badges, [.uhd, .dolbyVision, .hdr], "Primetime: YTS has no 4K of it, apibay's UHD ranking does")
        eq(hero.items[6].badges, [.uhd], "A Dog's Perfect Christmas: 4K on YTS, which says nothing of HDR")
    }

    func testHeroTitlesAreNotRepeatedInTheTrendingShelves() {
        let shelves = build(HomeFixture.allLists())
        let featured = Set(shelves.shelf(HomeShelfID.hero)!.imdbIds)
        let movies = shelves.shelf(HomeShelfID.trendingMovies)!
        let shows = shelves.shelf(HomeShelfID.trendingShows)!
        check(featured.isDisjoint(with: movies.imdbIds), "trending movies without the hero's")
        check(featured.isDisjoint(with: shows.imdbIds), "trending shows without the hero's")
        eq(movies.titles.prefix(4).map { $0 }, ["Halloween", "Spider-Man: Brand New Day", "The Invite", "Godzilla Minus One"], "the catalog's order otherwise")
        eq(movies.items.count, 14, "20 trending movies, 6 in the hero")
        eq(shows.titles.prefix(3).map { $0 }, ["Black Doves", "Dexter: Resurrection", "VisionQuest"], "the catalog's order")
        eq(shows.items.count, 18, "20 trending shows, 2 in the hero")
        eq(shows.items[1].badges, [.newEpisode], "Dexter: an episode this week")
        eq(shows.items[0].badges, [], "Black Doves: its last episode is nine days old")
        // Without the hero the trending shelves are whole.
        let plain = build(HomeFixture.allLists(), hidden: [HomeShelfID.hero])
        check(plain.shelf(HomeShelfID.hero) == nil, "a hidden hero")
        eq(plain.shelf(HomeShelfID.trendingMovies)?.items.count, 20, "then nothing is taken off the trending movies")
        eq(plain.shelf(HomeShelfID.trendingMovies)?.titles.first, "Heart of the Beast", "first")
    }

    func testAGenreShelfShowsOnlyTitlesNotShownAbove() {
        let shelves = build(HomeFixture.allLists())
        var shown = Set<String>()
        var genreShelves = 0
        for shelf in shelves where shelf.style != .ranked && !HomeShelfID.local.contains(shelf.id) {
            if HomeShelfID.genre(of: shelf.id) != nil {
                genreShelves += 1
                let repeated = shelf.items.filter { shown.contains($0.imdbId) }.map(\.title)
                check(repeated.isEmpty, "\(shelf.id) repeats no title shown above", "\(repeated)")
            }
            for item in shelf.items { shown.insert(item.imdbId) }
        }
        _ = genreShelves
    }

    func testATitleIsInTwoShelvesAtMost() {
        let shelves = build(HomeFixture.allLists())
        var count: [String: [String]] = [:]
        for shelf in shelves where shelf.style != .ranked {
            for item in shelf.items { count[item.imdbId, default: []].append(shelf.id) }
        }
        let over = count.filter { $0.value.count > 2 }
        check(over.isEmpty, "no title in three shelves", "\(over)")
        // The Odyssey: new movies, then 4K — not in the movies of the year, which it is part of.
        eq(count["tt33764258"], [HomeShelfID.newMovies, HomeShelfID.uhd], "the first two shelves in page order win")
        // Project Hail Mary: trending, movies of the year — not in the top rated, which it leads.
        eq(count["tt12042730"], [HomeShelfID.trendingMovies, HomeShelfID.moviesOfTheYear], "Project Hail Mary")
        // An episode card counts for its show.
        eq(count["tt26598805"], [HomeShelfID.hero, HomeShelfID.airedEpisodes], "Nocturne: hero, its episode — not in the new shows")

        // A ranking keeps every title, whatever is shown above: a top without its number one lies.
        let top = shelves.shelf(HomeShelfID.top48hShows)!
        eq(top.titles.first, "Dexter: Resurrection", "number one, although it is in two shelves above")
        eq(count["tt33043892"], [HomeShelfID.airedEpisodes, HomeShelfID.trendingShows], "it is")
        // The rule is a parameter: three shelves, or rankings filtered like the others.
        var loose = HomeBuilder.Rules()
        loose.maximumAppearances = 3
        check(build(HomeFixture.allLists(), rules: loose).shelf(HomeShelfID.moviesOfTheYear)!.imdbIds.contains("tt33764258"), "three allowed: The Odyssey is in the movies of the year")
        var strict = HomeBuilder.Rules()
        strict.rankedShelvesAreComplete = false
        check(!build(HomeFixture.allLists(), rules: strict).shelf(HomeShelfID.top48hShows)!.imdbIds.contains("tt33043892"), "rankings filtered: no Dexter")
    }

    // MARK: Movies

    func testNewMoviesKeepTheWantedLanguages() {
        let shelf = build(HomeFixture.allLists()).shelf(HomeShelfID.newMovies)!
        // 30 additions: 12 English, 4 French; Spanish, Malayalam, Hindi, Tamil… are left out.
        eq(shelf.items.count, 16, "English and French titles")
        eq(shelf.titles.prefix(3).map { $0 }, ["Extra Geography", "Being Heumann", "The Ballad of Lieutenant Dan"], "latest added first")
        check(shelf.imdbIds.contains("tt39453578"), "\"Un bon avocat\" (French) is kept")
        check(!shelf.imdbIds.contains("tt39571626") && !shelf.imdbIds.contains("tt33318732"), "\"El deshielo\" (Spanish) and \"Jailer 2\" (Tamil) are not")
        let dates = shelf.items.compactMap(\.date)
        eq(dates, dates.sorted(by: >), "by date added")
        eq(shelf.items[0].badges, [.new], "added yesterday: New")
        eq(shelf.items.first { $0.imdbId == "tt41593493" }?.badges, [.uhd], "Avedon: 4K, added more than three days ago")
        check(shelf.items.allSatisfy { ($0.rating ?? 0) >= 6 }, "rated 6 and more")

        let tamil = build(HomeFixture.allLists(), languages: ["ta"]).shelf(HomeShelfID.newMovies)!
        eq(tamil.titles, ["Jailer 2"], "another language setting")
        let all = build(HomeFixture.allLists(), languages: []).shelf(HomeShelfID.newMovies)!
        eq(all.items.count, 30, "no language set: everything")

        // The rating floor is checked here too (a mirror that ignores minimum_rating).
        var entries = HomeFixture.entries("yts_new_2026.json", .yts)
        entries[1].item.rating = 5.9
        entries[2].item.rating = nil
        let floored = build(lists([HomeFixture.list(.ytsNew(year), entries)])).shelf(HomeShelfID.newMovies)!
        check(!floored.imdbIds.contains(entries[1].item.imdbId) && !floored.imdbIds.contains(entries[2].item.imdbId), "under 6, or not rated: left out")
    }

    func testUHDShelfStartsWithWhatIsSeeded() {
        let shelf = build(HomeFixture.allLists()).shelf(HomeShelfID.uhd)!
        // Seeded on apibay's UHD top, most seeded first; then YTS's additions, latest first.
        eq(shelf.titles.prefix(6).map { $0 }, ["The Odyssey", "Heart of the Beast", "Other Mommy", "Allen", "Avedon", "The Gospel of Christmas"],
           "the seeded titles, then the latest additions")
        check(shelf.items.allSatisfy { $0.badges.contains(.uhd) }, "every card says 4K")
        eq(shelf.items[0].badges, [.uhd, .hdr], "The Odyssey: HDR")
        eq(shelf.items[2].badges, [.uhd, .dolbyVision, .hdr, .atmos], "Other Mommy: Dolby Vision, Atmos")
        eq(shelf.items[3].badges, [.uhd, .new], "Allen: added two days ago")
        check(!shelf.imdbIds.contains("tt33318732"), "Jailer 2 (Tamil) is not in an English + French 4K shelf")
        // apibay blocked: the order is YTS's, the badges are 4K only.
        var without = HomeFixture.allLists()
        without[HomeSource.topUHD.key] = nil
        let plain = build(without).shelf(HomeShelfID.uhd)!
        eq(plain.titles.prefix(3).map { $0 }, ["Allen", "Avedon", "The Gospel of Christmas"], "YTS's order")
        eq(plain.items.first { $0.imdbId == "tt33764258" }?.badges, [.uhd], "4K is all YTS tells")
    }

    func testTwinsOfTheSameTitleAndYear() {
        let entries = HomeFixture.entries("yts_year_2026.json", .yts)
        eq(entries.filter { $0.item.title == "The Odyssey" }.map(\.item.imdbId), ["tt41605854", "tt33764258"], "YTS lists The Odyssey (2026) twice")
        let kept = HomeBuilder.withoutTwins(entries)
        eq(kept.count, entries.count - 1, "one of them goes")
        eq(kept.filter { $0.item.title == "The Odyssey" }.map(\.item.imdbId), ["tt33764258"], "the one with the 4K release (and the rating) stays")
        eq(kept.map(\.item.imdbId), entries.map(\.item.imdbId).filter { $0 != "tt41605854" }, "the order of the others is untouched")
        // Same number of qualities: the better rated; accents, case and punctuation do not make two titles.
        let a = HomeFixture.entry("tt0000001", "Amélie", year: 2001, rating: 6.0, qualities: 2)
        let b = HomeFixture.entry("tt0000002", "AMELIE!", year: 2001, rating: 8.3, qualities: 2)
        let c = HomeFixture.entry("tt0000003", "Amelie", year: 2002, rating: 9.0, qualities: 3)
        let d = HomeFixture.entry("tt0000004", "Amelie", year: nil, rating: 9.0, qualities: 3)
        eq(HomeBuilder.withoutTwins([a, b, c, d]).map(\.item.imdbId), ["tt0000002", "tt0000003", "tt0000004"], "same year: the better rated; another year, or none, is another title")
        eq(HomeBuilder.withoutTwins([b, a]).map(\.item.imdbId), ["tt0000002"], "whatever the order")
        let shelf = build(HomeFixture.allLists()).shelf(HomeShelfID.moviesOfTheYear)!
        check(!shelf.imdbIds.contains("tt41605854"), "the stub is not in the movies of the year")
    }

    func testMoviesOfTheYearAndTopRated() {
        let shelves = build(HomeFixture.allLists(), hidden: [HomeShelfID.hero, HomeShelfID.trendingMovies, HomeShelfID.newMovies, HomeShelfID.uhd])
        let ofTheYear = shelves.shelf(HomeShelfID.moviesOfTheYear)!
        eq(ofTheYear.titles.prefix(4).map { $0 }, ["Project Hail Mary", "Spider-Man: Brand New Day", "War Machine", "Mortal Kombat II"], "the server's order: downloads")
        eq(ofTheYear.items.count, 29, "30 movies, one twin")
        let rated = shelves.shelf(HomeShelfID.topRatedOfTheYear)!
        // The same answer stands for both requests in the fixtures: the top rated are its 7 and more,
        // in the server's order (downloads) — the well rated movies people actually watch first.
        eq(rated.titles, ["Project Hail Mary", "Spider-Man: Brand New Day", "Toy Story 5", "The Odyssey", "Michael", "28 Years Later: The Bone Temple", "Resident Evil"],
           "7 and more, most downloaded first")
        check(rated.items.allSatisfy { ($0.rating ?? 0) >= 7 }, "the rating floor is checked here too")
    }

    // MARK: January

    func testYearRollover() {
        // The 3rd of January: the lists of the new year are short, the old year's complete them.
        let january = CatalogDates.date(from: "2027-01-03T10:00:00Z")!
        let thisYear = Array(HomeFixture.entries("yts_year_2026.json", .yts).prefix(4)).map { entry -> HomeEntry in
            var entry = entry
            entry.item.year = 2027
            return entry
        }
        let lastYear = Array(HomeFixture.entries("yts_year_2026.json", .yts).dropFirst(4))
        let both = lists([HomeFixture.list(.ytsYear(2027), thisYear, savedAt: january), HomeFixture.list(.ytsYear(2026), lastYear, savedAt: january)])
        let shelf = build(both, now: january).shelf(HomeShelfID.moviesOfTheYear)!
        eq(shelf.items.prefix(4).map(\.year), [2027, 2027, 2027, 2027], "the new year's movies first")
        eq(shelf.items.count, 29, "then last year's (one twin removed)")
        eq(shelf.items[4].year, 2026, "last year's")

        // Thirty and more: the year stands alone.
        let full = (0..<30).map { HomeFixture.entry(String(format: "tt90000%02d", $0), "Movie \($0)", year: 2027, language: "en") }
        let alone = build(lists([HomeFixture.list(.ytsYear(2027), full, savedAt: january), HomeFixture.list(.ytsYear(2026), lastYear, savedAt: january)]), now: january)
        eq(alone.shelf(HomeShelfID.moviesOfTheYear)?.items.count, 30, "30 titles: nothing added")
        check(alone.shelf(HomeShelfID.moviesOfTheYear)!.items.allSatisfy { $0.year == 2027 }, "only this year's")
        let short = Array(full.prefix(29))
        let completed = build(lists([HomeFixture.list(.ytsYear(2027), short, savedAt: january), HomeFixture.list(.ytsYear(2026), lastYear, savedAt: january)]), now: january)
        check(completed.shelf(HomeShelfID.moviesOfTheYear)!.items.contains { $0.year == 2026 }, "29 titles: completed")

        // Nothing at all this year yet (the 1st of January): last year's alone.
        let empty = build(lists([HomeFixture.list(.ytsYear(2027), [], savedAt: january), HomeFixture.list(.ytsYear(2026), lastYear, savedAt: january)]), now: january)
        eq(empty.shelf(HomeShelfID.moviesOfTheYear)?.items.first?.year, 2026, "an empty year is completed too")

        // New movies of two years are merged by date; the hero takes last year's titles.
        let newThis = [HomeFixture.entry("tt9100001", "January Movie", year: 2027, rating: 7, language: "en", date: january.addingTimeInterval(-86_400))]
        let newLast = [HomeFixture.entry("tt9100002", "New Year's Eve Movie", year: 2026, rating: 7, language: "en", date: january.addingTimeInterval(-3600)),
                       HomeFixture.entry("tt9100003", "December Movie", year: 2026, rating: 7, language: "en", date: january.addingTimeInterval(-20 * 86_400))]
        let merged = build(lists([HomeFixture.list(.ytsNew(2027), newThis, savedAt: january), HomeFixture.list(.ytsNew(2026), newLast, savedAt: january)]), now: january)
        eq(merged.shelf(HomeShelfID.newMovies)?.titles, ["New Year's Eve Movie", "January Movie", "December Movie"], "by date added across the two years")
        var top = HomeFixture.list(.movieTop, "cm_movie_top.json", savedAt: january)
        top.entries = top.entries.filter { $0.item.year == 2026 || $0.item.year == 1978 }
        let hero = build(lists([top]), now: january).shelf(HomeShelfID.hero)!
        check(!hero.items.isEmpty && hero.items.allSatisfy { $0.year == 2026 }, "in January 2027 the hero is made of 2026's titles")
    }

    // MARK: Shows

    func testAiredEpisodes() {
        let shelf = build(HomeFixture.allLists()).shelf(HomeShelfID.airedEpisodes)!
        // Scripted / animated / documentary shows, weight 90 and more, English or French, aired,
        // one card per show (its latest episode), latest first; equal air times: most popular
        // first, then by id.
        eq(shelf.items.map { "\($0.title) \($0.episode!.season)x\($0.episode!.number)" },
           ["Honey 1x2", "The Rainmaker 2x5", "Fire Country 5x6", "Sheriff Country 2x6", "SpongeBob SquarePants 17x24", "Yaga 1x5",
            "Tulsa King 4x5", "Nocturne 1x4", "MobLand 2x9", "Dexter: Resurrection 2x3", "12 12 12 1x2"], "the latest episodes")
        check(!shelf.titles.contains("Furia"), "a Spanish show is left out")
        check(!shelf.titles.contains("Cops") && !shelf.titles.contains("The View"), "reality and talk shows are left out")
        let nocturne = shelf.items[7]
        eq(nocturne.id, "tt26598805:1:4", "an episode card")
        eq(nocturne.posterURL?.absoluteString, "https://images.metahub.space/poster/medium/tt26598805/img", "the poster is the one of the show's own card (Cinemeta)")
        eq(nocturne.backdropURL?.absoluteString, "https://images.metahub.space/background/large/tt26598805/img", "its backdrop too")
        check(nocturne.episode?.stillURL?.host == "static.tvmaze.com" && nocturne.landscapeURL == nocturne.episode?.stillURL, "the still is the episode's")
        eq(nocturne.rating, 7.7, "Cinemeta has no rating yet: TVMaze's completes the card")
        eq(nocturne.badges, [.newEpisode], "aired yesterday")
        eq(shelf.items[0].badges, [.premiere], "Honey: the card shows episode 2 of a double-bill premiere")
        eq(shelf.items[10].badges, [.premiere], "12 12 12 too")
        let twelve = shelf.items[10]
        check(twelve.episode?.stillURL == nil && twelve.landscapeURL == twelve.backdropURL && twelve.backdropURL?.host == "images.metahub.space",
              "an episode without a still: the landscape card shows the show's backdrop")
        eq(nocturne.landscapeURLs.count, 2, "still, then backdrop: the card tries them in order")
        eq(twelve.posterURL?.absoluteString, "https://images.metahub.space/poster/medium/tt32375763/img", "a show Cinemeta's lists do not have: metahub's poster by IMDb id")

        // An episode that has not aired is not "aired": one hour before Honey.
        let before = build(HomeFixture.allLists(), now: CatalogDates.date(from: "2026-11-14T05:00:00Z")!).shelf(HomeShelfID.airedEpisodes)!
        check(!before.titles.contains("Honey"), "not aired yet")
        eq(before.titles.first, "The Rainmaker", "then the latest is The Rainmaker")
        // The popularity floor is a rule.
        var rules = HomeBuilder.Rules()
        rules.airedMinimumWeight = 100
        eq(build(HomeFixture.allLists(), rules: rules).shelf(HomeShelfID.airedEpisodes)?.items.count, 7, "weight 100 only")
    }

    func testAiredEpisodesWithoutTVMaze() {
        var without = HomeFixture.allLists()
        for key in without.keys where key.hasPrefix("tvm-") { without[key] = nil }
        let shelf = build(without).shelf(HomeShelfID.airedEpisodes)!
        // The trending shows that had an episode in the last seven days, latest first.
        eq(shelf.items.map { "\($0.title) \($0.episode!.season)x\($0.episode!.number)" },
           ["Black Clover 2x7", "Nocturne 1x4", "MobLand 2x9", "War 1x7", "VisionQuest 1x8", "The Gilded Age 4x2", "Dexter: Resurrection 2x2"],
           "read off series/top: no request more")
        eq(shelf.style, .landscape, "same shelf, same style")
        eq(shelf.items[2].episode?.stillURL?.absoluteString, "https://episodes.metahub.space/tt31510819/2/9/w780.jpg", "the still Cinemeta lists")
        check(shelf.items.allSatisfy { $0.badges == [.newEpisode] }, "all aired this week")
    }

    func testNewShows() {
        let shelf = build(HomeFixture.allLists(), hidden: [HomeShelfID.hero, HomeShelfID.airedEpisodes, HomeShelfID.trendingShows]).shelf(HomeShelfID.newShows)!
        eq(shelf.titles, ["Campus Drivers", "Dead-End Job", "Nocturne", "The One About Matthew Perry", "Minimum Wage", "Yaga", "Crystal Lake",
                          "VisionQuest", "Untitled Mike Tyson Documentary Series"], "the catalog's order: latest premiere first")
        eq(shelf.items.first { $0.title == "Nocturne" }?.badges, [.new], "premiered two weeks ago")
        eq(shelf.items.first { $0.title == "Dead-End Job" }?.badges, [], "premiered more than 30 days ago")
        // A show that has not started is not a "new show" yet.
        var future = HomeFixture.allLists()
        var list = future[HomeSource.seriesYear(year).key]!
        list.entries[1].item.date = now.addingTimeInterval(86_400)
        list.entries[1].episodes = []
        future[list.key] = list
        check(!build(future).shelf(HomeShelfID.newShows)!.titles.contains("Dead-End Job"), "announced for tomorrow: left out")
    }

    // MARK: Stand-ins

    func testWithoutCinemeta() {
        var lists = HomeFixture.allLists()
        for key in lists.keys where key.hasPrefix("cm-") { lists[key] = nil }
        lists[HomeSource.ytsLikes(year).key] = HomeFixture.list(.ytsLikes(year), "yts_year_2026.json")
        let shelves = build(lists)
        let hero = shelves.shelf(HomeShelfID.hero)!
        // Trending movies ← the year's most liked on YTS; trending shows ← TVMaze's most popular.
        eq(hero.titles.prefix(3).map { $0 }, ["Project Hail Mary", "Spider-Man: Brand New Day", "Dexter: Resurrection"], "two movies for one show from the stand-ins (shows: most popular, then best rated)")
        eq(hero.items[2].logoURL?.absoluteString, "https://images.metahub.space/logo/medium/tt33043892/img", "a show's logo too")
        eq(hero.items[0].logoURL?.absoluteString, "https://images.metahub.space/logo/medium/tt12042730/img", "metahub's logo by IMDb id")
        eq(hero.items[0].backdropURL?.absoluteString, "https://images.metahub.space/background/large/tt12042730/img", "and backdrop")
        let movies = shelves.shelf(HomeShelfID.trendingMovies)!
        check(!movies.items.isEmpty && movies.items.allSatisfy { $0.posterURL?.host == "images.weserv.nl" }, "YTS cards stand in for the trending movies")
        check(!movies.imdbIds.contains("tt41605854"), "without the twin")
        let shows = shelves.shelf(HomeShelfID.trendingShows)!
        check(shows.items.allSatisfy { $0.episode == nil && $0.id == $0.imdbId }, "show cards, not episode cards")
        check(shows.titles.contains("The Rainmaker") && !shows.titles.contains("Cops") && !shows.titles.contains("Furia"), "the scheduled shows, filtered as the aired episodes are")
        check(!shows.titles.contains("Honey") && !shows.titles.contains("12 12 12"), "this week's premieres are kept for the new shows")
        let newShows = shelves.shelf(HomeShelfID.newShows)!
        eq(newShows.titles, ["Honey", "12 12 12"], "the shows whose first episode just aired, latest first")
        check(newShows.items.allSatisfy { $0.badges == [.new] }, "badged New")
        check(shelves.shelf(HomeShelfID.yourShows) == nil, "no calendar: no shelf")
    }

    func testWithoutYTS() {
        var lists = HomeFixture.allLists()
        for key in lists.keys where key.hasPrefix("yts-") { lists[key] = nil }
        lists[HomeSource.movieFeatured.key] = HomeFixture.list(.movieFeatured, "cm_movie_top.json")
        let shelves = build(lists, hidden: [HomeShelfID.hero, HomeShelfID.trendingMovies])
        // New movies ← Stremio's Featured, this year and the last.
        let new = shelves.shelf(HomeShelfID.newMovies)!
        check(!new.titles.contains("Halloween") && !new.titles.contains("Coraline"), "old titles are not new movies")
        eq(new.titles.first, "Heart of the Beast", "the catalog's order")
        // 4K ← apibay's UHD ranking, with the cards the other lists know.
        let uhd = shelves.shelf(HomeShelfID.uhd)!
        eq(uhd.titles.prefix(4).map { $0 }, ["Resident Evil", "Project Hail Mary", "Primetime", "Backrooms"], "most seeded first; The Odyssey has no card without YTS")
        eq(uhd.items[0].badges, [.uhd, .dolbyVision, .hdr, .atmos], "the releases' badges")
        check(uhd.items.allSatisfy { $0.posterURL != nil && !$0.title.isEmpty }, "only titles with a card")
        // Movies of the year ← Cinemeta's popular movies of the year.
        let ofTheYear = build(lists, hidden: [HomeShelfID.hero, HomeShelfID.trendingMovies, HomeShelfID.newMovies, HomeShelfID.uhd]).shelf(HomeShelfID.moviesOfTheYear)!
        check(ofTheYear.items.allSatisfy { $0.year == year }, "this year's")
        eq(ofTheYear.titles.first, "Heart of the Beast", "in popularity order")
    }

    func testRankingsTakeTheirCardsFromTheOtherLists() {
        let shelves = build(HomeFixture.allLists())
        let top = shelves.shelf(HomeShelfID.top48hShows)!
        eq(top.titles, ["Dexter: Resurrection", "12 12 12", "Tulsa King", "War", "The Rainmaker", "SpongeBob SquarePants",
                        "Sheriff Country", "Yaga", "Fire Country"], "the shows another list knows, most seeded first")
        eq(top.items.map(\.rank), [1, 2, 3, 4, 5, 6, 7, 8, 9], "ranked from 1, without holes")
        check(top.items.allSatisfy { $0.episode == nil && $0.posterURL != nil }, "title cards")
        check(shelves.shelf(HomeShelfID.top48hMovies) == nil, "two known movies are not a ranking")

        // What the loader then asks Cinemeta about: the leading titles nobody knows.
        let needed = HomeBuilder.lookupsNeeded(HomeFixture.inputs(HomeFixture.allLists()))
        eq(needed.shows, ["tt0413573", "tt7235466", "tt0437005", "tt20859904", "tt33270224", "tt0159881", "tt33550053", "tt27954448",
                          "tt31842126", "tt36984433", "tt0350448"], "the unknown shows of the first twenty, most seeded first")
        eq(needed.movies, ["tt27419420", "tt4154796", "tt47791876", "tt29256561"], "the unknown movies with a release in a wanted language")

        // With the lookups answered: the cards, and "unknown" remembered for the rest.
        var lists = HomeFixture.allLists()
        let found = HomeFixture.entries("cm_last_videos.json", .cinemeta(.show))
        let unknown = needed.shows.filter { id in !found.contains { $0.item.imdbId == id } }.map { HomeEntry.unknown(imdbId: $0, kind: .show) }
        lists[HomeSource.lookupShowsKey] = HomeSourceList(key: HomeSource.lookupShowsKey, savedAt: now, complete: true, entries: found + unknown)
        let resolved = build(lists).shelf(HomeShelfID.top48hShows)!
        eq(resolved.titles.prefix(5).map { $0 }, ["Dexter: Resurrection", "12 12 12", "Tulsa King", "Grey's Anatomy", "9-1-1"], "the looked up shows take their rank")
        eq(resolved.items.count, 15, "nine known + six found")
        check(resolved.titles.contains("SWAT Exiles") && resolved.titles.contains("Law & Order Toronto: Criminal Intent"), "titles spelled differently in the release")
        eq(HomeBuilder.lookupsNeeded(HomeFixture.inputs(lists)).shows, [], "nothing is asked twice, found or not")

        // A release filed under another title's id is not shown under that title.
        var wrong = HomeFixture.allLists()
        var ranking = wrong[HomeSource.top48hShows.key]!
        ranking.entries[0].releaseName = "Some Other Show S01E01 1080p WEB H264"
        wrong[ranking.key] = ranking
        eq(build(wrong).shelf(HomeShelfID.top48hShows)?.titles.first, "12 12 12", "Dexter's card does not name that release: left out")
    }

    func testRankingLanguages() {
        var lists = HomeFixture.allLists()
        let metas = (try? JSONSerialization.jsonObject(with: HomeFixture.data("cm_meta_movies.json"))) as? [String: [String: Any]] ?? [:]
        let found = metas.values.compactMap { HomeParse.cinemetaEntry($0["meta"] as? [String: Any], kind: .movie, now: now) }
        lists[HomeSource.lookupMoviesKey] = HomeSourceList(key: HomeSource.lookupMoviesKey, savedAt: now, complete: true, entries: found)
        let top = build(lists).shelf(HomeShelfID.top48hMovies)!
        // Telugu / Tamil / Malayalam releases lead the list: not in an English + French ranking.
        // "Avengers: Endgame" (2019) is not the card of "Avengers Endgame Encore 2026".
        eq(top.titles, ["Street Fighter", "Snoopy Presents: 12 Days of Snoopy", "The Beast", "Extra Geography", "Resident Evil"], "the titles with a release in a wanted language")
        eq(top.items.map(\.rank), [1, 2, 3, 4, 5], "ranked")
        var rules = HomeBuilder.Rules()
        rules.rankedMinimum = 1
        // Tamil wanted: Jailer 2 (Tamil on YTS) is in; Extra Geography and Resident Evil (English on YTS) are out;
        // the releases that name no language stay.
        eq(build(lists, languages: ["ta"], rules: rules).shelf(HomeShelfID.top48hMovies)?.titles,
           ["Jailer 2", "Street Fighter", "Snoopy Presents: 12 Days of Snoopy", "The Beast"], "another language setting")
        check(build(lists, languages: ["ta"]).shelf(HomeShelfID.top48hMovies) == nil, "four titles are not a ranking (five at least)")
        let everything = build(lists, languages: []).shelf(HomeShelfID.top48hMovies)!
        eq(everything.titles.first, "Jailer 2", "no language set: the most seeded known title leads")
    }

    // MARK: Local shelves

    private func resume(_ imdbId: String, _ title: String, kind: HomeItem.Kind = .movie, genres: [String] = [], episode: HomeEpisode? = nil) -> HomeItem {
        return HomeItem(imdbId: imdbId, kind: kind, title: title, genres: genres, episode: episode, progress: 0.4, remainingMinutes: 55)
    }

    func testLocalShelves() {
        var local = HomeLocal()
        local.continueWatching = [resume("tt12042730", "Project Hail Mary"), resume("tt31510819", "MobLand", kind: .show, episode: HomeEpisode(season: 2, number: 8))]
        local.watchlist = [HomeItem(imdbId: "tt22084616", kind: .movie, title: "Spider-Man: Brand New Day"), HomeItem(imdbId: "tt0903747", kind: .show, title: "Breaking Bad")]
        let shelves = build(HomeFixture.allLists(), local: local)
        eq(Array(shelves.ids.prefix(3)), [HomeShelfID.hero, HomeShelfID.continueWatching, HomeShelfID.trendingMovies], "the resume cards right under the hero")
        eq(shelves.ids.last, HomeShelfID.watchlist, "the watchlist after the rankings")
        let resumeShelf = shelves.shelf(HomeShelfID.continueWatching)!
        eq(resumeShelf.style, .landscape, "landscape cards")
        eq(resumeShelf.items.map(\.id), ["tt12042730", "tt31510819:2:8"], "as the library gave them")
        eq(resumeShelf.items[0].progress, 0.4, "progress")
        eq(resumeShelf.items[0].remainingMinutes, 55, "minutes left")
        check(resumeShelf.updatedAt == nil && !resumeShelf.isStale, "a local shelf has no fetch date")
        eq(shelves.shelf(HomeShelfID.watchlist)?.seeAll, HomeSeeAll(catalogue: .watchlist), "see all: the watchlist")
        // The user's own titles do not count for the "two shelves at most" rule, and are not filtered by it.
        check(shelves.shelf(HomeShelfID.trendingMovies)!.imdbIds.contains("tt12042730") && shelves.shelf(HomeShelfID.moviesOfTheYear)!.imdbIds.contains("tt12042730"),
              "Project Hail Mary is still in two catalog shelves")
        // Local shelves alone: nothing loaded yet, the page already has the library.
        let alone = build([:], local: local)
        eq(alone.ids, [HomeShelfID.continueWatching, HomeShelfID.watchlist], "the library without any list")
    }

    func testYourShows() {
        var local = HomeLocal()
        local.followedShowIds = ["tt31510819", "tt26598805", "tt33043892", "tt5875444", "tt0903747"]
        var lists = HomeFixture.allLists()
        let calendar = HomeSource.calendar(ids: local.followedShowIds)!
        lists[calendar.key] = HomeFixture.list(calendar, "cm_calendar.json")

        let fresh = build(lists, local: local).shelf(HomeShelfID.yourShows)!
        eq(fresh.style, .landscape, "episode cards")
        // Aired lately and not watched, latest first; then the next episodes of the week.
        eq(fresh.items.map { "\($0.title) \($0.episode!.season)x\($0.episode!.number)" },
           ["Nocturne 1x4", "MobLand 2x9", "Dexter: Resurrection 2x2"], "each show's latest episode; Slow Horses (three weeks ago) and Breaking Bad have none")
        eq(fresh.items.map(\.badges), [[.newEpisode], [.newEpisode], [.newEpisode]], "new episodes")
        eq(Array(build(lists, local: local).ids.prefix(3)), [HomeShelfID.hero, HomeShelfID.yourShows, HomeShelfID.trendingMovies], "under the hero (and the resume cards)")

        eq(HomeBuilder.followedCandidates(HomeFixture.inputs(lists, local: local)).map { "\($0.imdbId):\($0.season):\($0.number)" },
           ["tt31510819:2:9", "tt26598805:1:4", "tt33043892:2:2"], "the episodes whose watched state matters")
        // MobLand S2E9 watched: the user is up to date, the card is the next episode (in six days).
        local.watchedEpisodeIds = ["tt31510819:2:9"]
        let watched = build(lists, local: local).shelf(HomeShelfID.yourShows)!
        eq(watched.items.map { "\($0.title) \($0.episode!.season)x\($0.episode!.number)" },
           ["Nocturne 1x4", "Dexter: Resurrection 2x2", "MobLand 2x10"], "aired first, upcoming after")
        eq(watched.items[2].badges, [.upcoming], "not aired yet")
        eq(watched.items[2].date, CatalogDates.date(from: "2026-11-20T03:00:00.000Z"), "its air date")
        // Everything watched: Dexter's next (in two days) and MobLand's; Nocturne's is in six days.
        local.watchedEpisodeIds = ["tt31510819:2:9", "tt26598805:1:4", "tt33043892:2:2"]
        eq(build(lists, local: local).shelf(HomeShelfID.yourShows)?.items.map(\.id), ["tt33043892:2:3", "tt31510819:2:10", "tt26598805:1:5"], "upcoming, soonest first")

        // The library's own new episodes come first and are not doubled by the calendar's.
        local.watchedEpisodeIds = []
        local.newEpisodes = [resume("tt33043892", "Dexter: Resurrection", kind: .show, episode: HomeEpisode(season: 2, number: 1))]
        eq(build(lists, local: local).shelf(HomeShelfID.yourShows)?.items.map(\.id), ["tt33043892:2:1", "tt26598805:1:4", "tt31510819:2:9"], "the library's card for Dexter, the calendar's for the others")
        // Not sent to Cinemeta (the opt-out): the library's cards alone, and no calendar in the plan.
        var optedOut = HomeFixture.inputs(lists, local: local)
        optedOut.sendsFollowedShows = false
        check(optedOut.plan().calendar == nil, "no calendar request planned")
        eq(HomeBuilder.shelves(optedOut).shelf(HomeShelfID.yourShows)?.items.map(\.id), ["tt33043892:2:1"], "only what the library knows")

        // Another show is followed: the calendar of the new set is not in yet (its key
        // changed). The cards of the old one stay meanwhile, for the shows still followed.
        local.newEpisodes = []
        local.followedShowIds.append("tt16358384")
        check(HomeSource.calendar(ids: local.followedShowIds)!.key != calendar.key && lists[HomeSource.calendar(ids: local.followedShowIds)!.key] == nil,
              "the new set's calendar is another list, not loaded")
        let meanwhile = build(lists, local: local).shelf(HomeShelfID.yourShows)
        eq(meanwhile?.items.map(\.id), fresh.items.map(\.id), "the shelf keeps its cards while the new calendar is on its way")
        eq(meanwhile?.isStale, true, "shown as stale: it is being asked")
        local.followedShowIds.removeAll { $0 == "tt26598805" }
        eq(build(lists, local: local).shelf(HomeShelfID.yourShows)?.items.map(\.imdbId), ["tt31510819", "tt33043892"], "a show no longer followed has no card")
        // The latest calendar kept is the one read.
        var older = HomeFixture.list(calendar, "cm_calendar.json", savedAt: now.addingTimeInterval(-3600))
        older.key = HomeSource.calendarPrefix + "older"
        older.entries.removeAll { $0.item.imdbId != "tt31510819" }
        lists[older.key] = older
        eq(build(lists, local: local).shelf(HomeShelfID.yourShows)?.items.count, 2, "of two calendars kept, the latest")
        var expired = lists
        expired[calendar.key]?.savedAt = now.addingTimeInterval(-4 * 86_400)
        expired[older.key] = nil
        check(build(expired, local: local).shelf(HomeShelfID.yourShows) == nil, "an expired calendar is not shown")
    }

    func testCalendarKeyFollowsTheSetOfShows() {
        let a = HomeSource.calendar(ids: ["tt31510819", "tt26598805"])!
        let b = HomeSource.calendar(ids: ["tt26598805", "tt31510819", "tt31510819"])!
        eq(a.key, b.key, "the same shows in another order: the same list")
        eq(a.request.path, "/catalog/series/calendar-videos/calendarVideosIds=tt26598805,tt31510819.json", "sorted, once each")
        check(HomeSource.calendar(ids: ["tt31510819"])!.key != a.key, "another set: another list, asked at once")
        check(HomeSource.calendar(ids: []) == nil && HomeSource.calendar(ids: ["../../x", "nm0000001", ""]) == nil, "nothing valid: no request")
        eq(HomeSource.calendar(ids: (0..<150).map { String(format: "tt%07d", 1_000_000 + $0) })!.request.path.components(separatedBy: ",").count, 100, "100 shows at most in one request")
        // More than 100 followed: the first 100 as the library ordered them (the ones that
        // matter most first), not the 100 smallest ids. Here the 60 shows being watched are
        // recent ones (tt3…), ahead of 90 older ones from the watchlist (tt0…).
        let watching = (0..<60).map { String(format: "tt3%07d", $0) }, listed = (0..<90).map { String(format: "tt0%07d", 500_000 + $0) }
        let many = HomeSource.calendar(ids: watching + ["nm0000001", watching[0]] + listed)!
        let path = many.request.path
        let asked = path.dropFirst("/catalog/series/calendar-videos/calendarVideosIds=".count).dropLast(".json".count).components(separatedBy: ",")
        eq(asked.count, 100, "100 shows")
        eq(Set(asked), Set(watching + listed.prefix(40)), "the first 100 of the given order; an invalid id and a repeat take no place")
        eq(asked, asked.sorted(), "sorted in the request: the same shows in another order are the same list")
        eq(many.key, HomeSource.calendar(ids: Array((watching + listed.prefix(40)).reversed()))!.key, "…with the same key")
    }

    // MARK: Genres, hidden shelves, limits

    func testGenreShelves() {
        var local = HomeLocal()
        eq(HomeBuilder.genreChoices(local, limit: 4).map { "\($0.kind.rawValue)-\($0.genre)" }, ["movie-Action", "show-Drama", "movie-Comedy", "show-Sci-Fi"], "the defaults")
        local.continueWatching = [resume("tt1", "A", genres: ["Horror", "Thriller"]), resume("tt2", "B", genres: ["Horror", "Science-Fiction"])]
        local.watchlist = [resume("tt3", "C", kind: .show, genres: ["Crime", "Legal"]), resume("tt1", "A again", genres: ["Horror"])]
        eq(HomeBuilder.genreChoices(local, limit: 4).map { "\($0.kind.rawValue)-\($0.genre)" }, ["movie-Horror", "movie-Thriller", "movie-Sci-Fi", "show-Crime"],
           "the genres of the user's titles, the most frequent first (a title counts once; names other sources use are mapped)")
        eq(HomeBuilder.genreChoices(local, limit: 6).map { "\($0.kind.rawValue)-\($0.genre)" },
           ["movie-Horror", "movie-Thriller", "movie-Sci-Fi", "show-Crime", "movie-Action", "show-Drama"], "completed with the defaults")
        eq(HomeBuilder.genreChoices(local, limit: 0).count, 0, "no genre shelf")

        var lists = HomeFixture.allLists()
        let horror = HomeSource.genre(.movie, "Horror")
        eq(horror.request.path, "/catalog/movie/top/genre=Horror.json", "the request")
        eq(HomeSource.genre(.show, "Sci-Fi").request.path, "/catalog/series/top/genre=Sci-Fi.json", "a series genre")
        lists[horror.key] = HomeFixture.list(horror, "cm_movie_top.json")
        let shelves = build(lists, local: local, hidden: [HomeShelfID.hero, HomeShelfID.trendingMovies])
        let shelf = shelves.shelf(HomeShelfID.genre(.movie, "Horror"))!
        eq(shelves.ids.last, shelf.id, "genre shelves close the page")
        eq(shelf.defaultTitle, "%@ Movies", "its title is a format")
        eq(shelf.titleArgument, "Horror", "and the genre")
        eq(HomeShelf(id: HomeShelfID.genre(.show, "Sci-Fi"), style: .posters, items: []).titleArgument, "Science Fiction", "under the app's name of the genre, which is translated")
        eq(HomeShelf(id: HomeShelfID.genre(.movie, "Biography"), style: .posters, items: []).titleArgument, "Biography", "or Cinemeta's when the app has no such genre")
        check(HomeShelf(id: HomeShelfID.uhd, style: .posters, items: []).titleArgument == nil, "a fixed shelf has none")
        eq(shelf.seeAll, HomeSeeAll(catalogue: .movies, filter: "trending", genre: "Horror"), "see all: the movies grid, that genre")
        eq(HomeBuilder.seeAll(of: HomeShelfID.genre(.show, "Sci-Fi"))?.genreFilter, .sciFi, "Cinemeta's Sci-Fi is the app's Science Fiction")
        check(HomeBuilder.seeAll(of: HomeShelfID.genre(.movie, "Biography")) == nil, "a genre the grids do not have: no see all")
        check(HomeSource.genre(ofKey: HomeSource.genre(.show, "Sci-Fi").key)! == (.show, "Sci-Fi") && HomeSource.genre(ofKey: HomeSource.movieTop.key) == nil
              && HomeSource.genre(ofKey: "cm-genre-movie-") == nil, "a genre list's key names its kind and genre")
    }

    func testGenreShelvesStayWhileTheNewChoiceLoads() {
        // Four distinct lists, so that each shelf has titles of its own.
        let movies = HomeFixture.entries("cm_movie_top.json", .cinemeta(.movie)), shows = HomeFixture.entries("cm_series_top.json", .cinemeta(.show))
        func genreList(_ kind: HomeItem.Kind, _ genre: String, _ slice: Int, savedAt: Date = HomeFixture.now) -> HomeSourceList {
            let entries = Array((kind == .movie ? movies : shows).dropFirst(slice * 5).prefix(5))
            return HomeFixture.list(.genre(kind, genre), entries, savedAt: savedAt)
        }
        func genres(_ lists: [String: HomeSourceList], _ local: HomeLocal, limit: Int = 4) -> [String] {
            var rules = HomeBuilder.Rules()
            rules.genreShelves = limit
            rules.maximumAppearances = 99
            return build(lists, local: local, rules: rules).ids.filter { HomeShelfID.genre(of: $0) != nil }
        }
        var lists = self.lists([genreList(.movie, "Action", 0), genreList(.show, "Drama", 0), genreList(.movie, "Comedy", 1), genreList(.show, "Sci-Fi", 1)])
        var local = HomeLocal()
        let defaults = ["genre-movie-Action", "genre-show-Drama", "genre-movie-Comedy", "genre-show-Sci-Fi"]
        eq(genres(lists, local), defaults, "the default genre shelves")

        // A horror thriller joins the watchlist: Horror and Thriller are chosen, their lists
        // are not in yet. The shelves on screen stay.
        local.watchlist = [resume("tt1", "A", genres: ["Horror", "Thriller"])]
        eq(HomeBuilder.genreChoices(local, limit: 4).map { "\($0.kind.rawValue)-\($0.genre)" }, ["movie-Horror", "movie-Thriller", "movie-Action", "show-Drama"], "the new choice")
        eq(genres(lists, local), defaults, "nothing leaves the page while the new lists are on their way")
        lists[HomeSource.genre(.movie, "Horror").key] = genreList(.movie, "Horror", 2)
        eq(genres(lists, local), ["genre-movie-Horror", "genre-movie-Action", "genre-show-Drama", "genre-movie-Comedy"], "one is in: it takes its place, one old shelf leaves")
        lists[HomeSource.genre(.movie, "Thriller").key] = genreList(.movie, "Thriller", 3)
        eq(genres(lists, local), ["genre-movie-Horror", "genre-movie-Thriller", "genre-movie-Action", "genre-show-Drama"], "both are in: the new choice, whole")
        // Of the lists kept, the latest fetched fill the free places; never more shelves than chosen.
        lists[HomeSource.genre(.movie, "Thriller").key] = nil
        lists[HomeSource.genre(.show, "Sci-Fi").key] = genreList(.show, "Sci-Fi", 1, savedAt: now.addingTimeInterval(60))
        eq(genres(lists, local), ["genre-movie-Horror", "genre-movie-Action", "genre-show-Drama", "genre-show-Sci-Fi"], "the latest fetched first")
        eq(genres(lists, local, limit: 2), ["genre-movie-Horror", "genre-show-Sci-Fi"], "as many shelves as the plan has genres")
        lists[HomeSource.genre(.show, "Sci-Fi").key]?.savedAt = now.addingTimeInterval(-8 * 86_400)
        eq(genres(lists, local), ["genre-movie-Horror", "genre-movie-Action", "genre-show-Drama", "genre-movie-Comedy"], "an expired list fills nothing")
        eq(genres([:], local), [], "no list: no shelf")
    }

    func testHiddenShelvesAndLimits() {
        let hidden = build(HomeFixture.allLists(), hidden: [HomeShelfID.uhd, HomeShelfID.top48hShows])
        check(hidden.shelf(HomeShelfID.uhd) == nil && hidden.shelf(HomeShelfID.top48hShows) == nil, "hidden shelves are not built")
        // A hidden shelf does not use up a title's two appearances.
        check(hidden.shelf(HomeShelfID.moviesOfTheYear)!.imdbIds.contains("tt33764258"), "The Odyssey, no longer in 4K, is in the movies of the year")
        var rules = HomeBuilder.Rules()
        rules.shelfLimit = 5
        rules.heroLimit = 3
        rules.rankedLimit = 6
        let small = build(HomeFixture.allLists(), rules: rules)
        eq(small.shelf(HomeShelfID.hero)?.items.count, 3, "hero limit")
        eq(small.shelf(HomeShelfID.hero)?.titles, ["Heart of the Beast", "Resident Evil", "MobLand"], "two movies, one show")
        check(small.filter { $0.style == .posters || $0.style == .landscape }.allSatisfy { $0.items.count <= 5 }, "shelf limit")
        eq(small.shelf(HomeShelfID.top48hShows)?.items.count, 6, "ranking limit")
        // Titles past a shelf's limit do not use up their appearances either.
        check(small.shelf(HomeShelfID.moviesOfTheYear) != nil, "the next shelves still have titles")
        eq(build([:]).count, 0, "nothing loaded, no library: no shelf")
    }

    func testStaleAndExpiredLists() {
        // Five hours later: the Cinemeta catalogs (fresh 4 h) are stale, YTS's rankings (6 h) are not.
        let later = now.addingTimeInterval(5 * 3600)
        let shelves = build(HomeFixture.allLists(), now: later)
        eq(shelves.shelf(HomeShelfID.trendingMovies)?.isStale, true, "movie/top after 5 h: shown, stale")
        eq(shelves.shelf(HomeShelfID.trendingMovies)?.updatedAt, now, "its date is the fetch")
        eq(shelves.shelf(HomeShelfID.moviesOfTheYear)?.isStale, false, "the movies of the year are fresh for 6 h")
        eq(shelves.shelf(HomeShelfID.newMovies)?.isStale, true, "the new movies for 30 min")
        // Two days later: YTS's additions and apibay (usable 24 h) are gone, Cinemeta (7 days) is still shown.
        let twoDays = build(HomeFixture.allLists(), now: now.addingTimeInterval(2 * 86_400))
        check(twoDays.shelf(HomeShelfID.newMovies) == nil && twoDays.shelf(HomeShelfID.uhd) == nil && twoDays.shelf(HomeShelfID.top48hShows) == nil, "expired lists are not shown")
        check(twoDays.shelf(HomeShelfID.trendingMovies) != nil && twoDays.shelf(HomeShelfID.moviesOfTheYear) != nil, "the others still are")
        // An incomplete list is shown, and stale at once.
        var lists = HomeFixture.allLists()
        lists[HomeSource.movieTop.key]?.complete = false
        eq(build(lists).shelf(HomeShelfID.trendingMovies)?.isStale, true, "an incomplete list is never fresh")
        eq(build(HomeFixture.allLists(), now: now.addingTimeInterval(8 * 86_400)).count, 0, "after eight days nothing is left to show")
    }

    // MARK: Model

    func testShelfIdsAndTitles() {
        eq(HomeShelfID.order, ["hero", "continueWatching", "yourShows", "trendingMovies", "newMovies", "uhd", "airedEpisodes", "trendingShows",
                               "newShows", "moviesOfTheYear", "topRatedOfTheYear", "top48hShows", "top48hMovies", "watchlist"], "the fixed shelves in page order")
        eq(HomeShelfID.genre(.movie, "Action"), "genre-movie-Action", "a genre shelf's id")
        eq(HomeShelfID.genre(of: "genre-show-Sci-Fi")?.genre, "Sci-Fi", "a genre with a dash")
        eq(HomeShelfID.genre(of: "genre-show-Sci-Fi")?.kind, .show, "its kind")
        check(HomeShelfID.genre(of: "hero") == nil && HomeShelfID.genre(of: "genre-movie-") == nil && HomeShelfID.genre(of: "genre-book-Drama") == nil, "not genre shelves")
        for id in HomeShelfID.order {
            let title = HomeShelfID.defaultTitle(id)
            check(!title.isEmpty && title != id && !title.contains("%@"), "\(id) has an English title: \(title)")
        }
        eq(Set(HomeShelfID.order.map(HomeShelfID.defaultTitle)).count, HomeShelfID.order.count, "every shelf its own title")
        eq(HomeShelfID.defaultTitle("genre-movie-Action"), "%@ Movies", "genre titles are formats")
        eq(HomeShelfID.englishTitle("genre-show-Sci-Fi"), "Sci-Fi Shows", "filled in")
        eq(HomeShelfID.englishTitle(HomeShelfID.uhd), "New in 4K", "a fixed title")
        eq(HomeShelfID.local, [HomeShelfID.continueWatching, HomeShelfID.yourShows, HomeShelfID.watchlist], "the local shelves")
        eq(HomeBadge.ordered([.new, .atmos, .uhd, .atmos, .hdr]), [.uhd, .hdr, .atmos, .new], "badges: formats first, once each")
        eq(HomeBadge.uhd.label, "4K", "a format's label")
        check(HomeBadge.uhd.localizationKey == nil && HomeBadge.uhd.isFormat, "formats are not translated")
        eq(HomeBadge.newEpisode.localizationKey, "Home.Badge.NewEpisode", "an editorial badge's key")
        eq(Set(HomeBadge.allCases.compactMap(\.localizationKey)).count, 5, "five translated badges")
        // What a pill shows: the translation, and the English label — never the raw key —
        // where there is none (here: the test bundle has no strings file).
        eq(HomeBadge.newEpisode.localizedLabel, "New Episode", "no entry in this language: the English label")
        eq(HomeBadge.dolbyVision.localizedLabel, "Dolby Vision", "a format is its own label")
        check(HomeBadge.allCases.allSatisfy { !$0.localizedLabel.hasPrefix("Home.") }, "no key on a card")
    }

    func testEveryTitleAndBadgeIsTranslated() throws {
        // The kit carries English titles; the apps' strings files translate them. Read from
        // the source tree (the test bundle only carries the fixtures).
        let repository = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var keys = HomeShelfID.order.map(HomeShelfID.defaultTitle) + ["%@ Movies", "%@ Shows"] + HomeBadge.allCases.compactMap(\.localizationKey)
        keys += HomeBuilder.cinemetaGenres.map { HomeBuilder.appGenre($0)?.rawValue ?? $0 }
        for language in ["fr", "en", "Base"] {
            let file = repository.appendingPathComponent("PopcornTime/\(language).lproj/Localizable.strings")
            guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("the sources are not next to the test bundle") }
            let strings = NSDictionary(contentsOf: file) as? [String: String] ?? [:]
            check(strings.count > 300, "\(language): the strings file is read", "\(strings.count) entries")
            let missing = keys.filter { strings[$0] == nil }
            check(missing.isEmpty, "\(language): every shelf title, genre and badge has an entry", "\(missing)")
            if language == "fr" {
                eq(strings["New in 4K"], "Nouveautés 4K", "a French title")
                eq(strings["Home.Badge.NewEpisode"], "Nouvel épisode", "a French badge")
                let formats = ["%@ Movies", "%@ Shows"].compactMap { strings[$0] }
                check(formats.count == 2 && formats.allSatisfy { $0.contains("%@") }, "the genre formats keep their argument")
            } else {
                eq(strings["Home.Badge.NewEpisode"], HomeBadge.newEpisode.label, "\(language): the badge's English text is its label")
            }
        }
        // The badges' keys are symbolic: a language without an entry would show "Home.Badge.New"
        // (a shelf title falls back to its English text, a symbolic key to nothing). Every
        // language the apps ship has them.
        let folder = repository.appendingPathComponent("PopcornTime")
        let languages = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { name in
            name.hasSuffix(".lproj") && FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name)/Localizable.strings").path)
        }
        check(Set(languages).isSuperset(of: ["Base.lproj", "ar.lproj", "en.lproj", "es.lproj", "fr.lproj", "it.lproj", "pt-BR.lproj"]), "every strings file is found", "\(languages)")
        for language in languages {
            let strings = NSDictionary(contentsOf: folder.appendingPathComponent("\(language)/Localizable.strings")) as? [String: String] ?? [:]
            let missing = HomeBadge.allCases.compactMap(\.localizationKey).filter { (strings[$0] ?? "").isEmpty || strings[$0]?.hasPrefix("Home.") == true }
            check(missing.isEmpty, "\(language): every badge has its text", "\(missing)")
        }
    }

    func testCardsAsMovieAndShow() {
        let movieCard = HomeFixture.entries("cm_movie_top.json", .cinemeta(.movie))[0].item
        let movie = movieCard.movie
        eq(movie?.id, "tt7526136", "the movie a detail page opens")
        eq(movie?.title, "Heart of the Beast", "title")
        eq(movie?.year, "2026", "year")
        eq(movie?.rating, 72, "the app's 0–100 rating")
        eq(movie?.runtime, 101, "runtime")
        eq(movie?.genres, ["Action", "Adventure", "Drama"], "genres")
        eq(movie?.trailerCode, "UkMuGKqAux4", "trailer")
        eq(movie?.largeCoverImage, "https://images.metahub.space/poster/medium/tt7526136/img", "poster")
        eq(movie?.largeBackgroundImage, "https://images.metahub.space/background/large/tt7526136/img", "backdrop")
        check(movieCard.show == nil && movieCard.media is Movie, "a movie card is not a show")
        let episodeCard = build(HomeFixture.allLists()).shelf(HomeShelfID.airedEpisodes)!.items[7]
        eq(episodeCard.show?.id, "tt26598805", "an episode card opens its show")
        eq(episodeCard.show?.title, "Nocturne", "the show")
        check(episodeCard.movie == nil && episodeCard.media is Show, "not a movie")
    }

    // MARK: One truth per title

    /// Spider-Man: Brand New Day is rated 8,0 by Cinemeta (IMDb) and 7,9 by YTS; YTS here names
    /// it by another title. Every card of it, on every shelf, and the grids of the three
    /// platforms (`PosterLibrary`, told by `HomeTitleFacts`) say the same.
    func testEveryCardOfATitleSaysTheSameThing() {
        let facts = HomeTitleFacts()
        var lists = HomeFixture.allLists()
        var yts = lists[HomeSource.ytsYear(year).key]!
        let index = yts.entries.firstIndex { $0.item.imdbId == "tt22084616" }!
        eq(yts.entries[index].item.rating, 7.9, "YTS's rating of the fixture")
        yts.entries[index].item.title = "Spider-Man : Un nouveau jour"
        lists[yts.key] = yts
        let shelves = HomeBuilder.shelves(HomeFixture.inputs(lists), facts: facts)
        let cards = shelves.flatMap(\.items).filter { $0.imdbId == "tt22084616" }
        check(!cards.isEmpty, "Spider-Man is on the page")
        eq(Set(cards.map(\.title)), ["Spider-Man: Brand New Day"], "Cinemeta's title on every card, not YTS's")
        eq(Set(cards.map(\.rating)), [8.0], "Cinemeta's (IMDb's) rating on every card, not YTS's 7,9")
        // Every title: one rating and one set of formats on the whole page.
        var told: [String: (Double?, [HomeBadge])] = [:]
        for item in shelves.flatMap(\.items) where !item.imdbId.isEmpty {
            let mine = (item.rating, item.badges.filter(\.isFormat))
            if let known = told[item.imdbId] {
                check(known.0 == mine.0 && known.1 == mine.1, "\(item.title): the same rating and formats on every shelf",
                      "\(known) / \(mine)")
            }
            told[item.imdbId] = mine
        }
        // Kept for the other screens.
        let kept = facts.facts(of: "tt22084616")
        eq(kept?.rating, 8.0, "the Home's rating is kept")
        eq(kept?.title, "Spider-Man: Brand New Day", "and its title")
        eq(kept?.badges.filter(\.isFormat), cards[0].badges.filter(\.isFormat), "and its formats")

        // The Movies grid of the Apple TV (a YTS movie, rated 7,9, "4K" its only format known)
        // tells it as the Home does.
        let storage = MemoryLibraryStorage([:])
        let library = Library(storage: storage, guideDirectory: nil, remote: .offline, center: NotificationCenter(), now: { HomeFixture.now })
        let posters = PosterLibrary(library: library, facts: facts)
        let grid = Movie(yts: ["imdb_code": "tt22084616", "title": "Spider-Man : Un nouveau jour", "year": 2026, "rating": 7.9,
                               "torrents": [["hash": "0123456789ABCDEF0123456789ABCDEF01234567", "quality": "2160p"]]])!
        let card = posters.card(for: grid, now: HomeFixture.now)
        eq(card?.rating, 8.0, "the grid's rating is the Home's")
        eq(card?.title, "Spider-Man: Brand New Day", "its title too")
        eq(card?.badges.filter(\.isFormat), kept?.badges.filter(\.isFormat), "and its formats (4K, and what the Home knows)")
    }

    /// A title on two shelves keeps the editorial badge of either (NOUVEAU on « New movies »,
    /// none on a later shelf), recorded again and again: the other screens (the Apple TV's grids,
    /// Search, My List; a show page's new episode) tell it with the badge.
    func testATitleOnTwoShelvesKeepsItsEditorialBadge() {
        let facts = HomeTitleFacts()
        var newMovie = HomeItem(imdbId: "tt0000901", kind: .movie, title: "New Film", year: 2026, rating: 7.1)
        newMovie.badges = [.new, .uhd]
        var later = newMovie
        later.badges = [.uhd]
        var newShow = HomeItem(imdbId: "tt0000902", kind: .show, title: "Show", year: 2026, rating: 7.8)
        newShow.badges = [.newEpisode]
        var plainShow = newShow
        plainShow.badges = []
        for _ in 0..<2 { facts.record([newMovie, newShow, later, plainShow]) }
        eq(facts.facts(of: "tt0000901")?.badges, [.uhd, .new], "NOUVEAU kept, with its 4K")
        check(facts.facts(of: "tt0000902")?.badges.contains(.newEpisode) == true, "NOUVEL ÉPISODE kept")
        var grid = HomeItem(imdbId: "tt0000901", kind: .movie, title: "New Film", year: 2026, rating: 6.0)
        grid.badges = [.uhd]
        check(facts.harmonize(grid).badges.contains(.new), "a grid card of it says NOUVEAU as the Home does")
        // The next page no longer lists it as new: the badge goes.
        facts.record([later, plainShow])
        check(facts.facts(of: "tt0000901")?.badges.contains(.new) == false, "not new any more")
        check(facts.facts(of: "tt0000902")?.badges.contains(.newEpisode) == false, "no new episode any more")
    }

    /// A working title nobody corrects stays the card's (VoiceOver reads it); the card does not
    /// print it (`cardTitle`). A real title of another list replaces Cinemeta's working one.
    func testWorkingTitles() {
        let facts = HomeTitleFacts()
        let shelves = HomeBuilder.shelves(HomeFixture.inputs(HomeFixture.allLists()), facts: facts)
        let tyson = shelves.flatMap(\.items).filter { $0.imdbId == "tt35051210" }
        check(!tyson.isEmpty, "the Mike Tyson series is on the page")
        check(tyson.allSatisfy { $0.title == "Untitled Mike Tyson Documentary Series" && $0.cardTitle.isEmpty },
              "no list gives a real title: kept, not printed")

        // Cinemeta's working title, YTS's real one: the real one everywhere.
        var lists = HomeFixture.allLists()
        var top = lists[HomeSource.movieTop.key]!
        let index = top.entries.firstIndex { $0.item.imdbId == "tt22084616" }!
        top.entries[index].item.title = "Untitled Spider-Man Sequel"
        lists[top.key] = top
        let spiderMan = HomeBuilder.shelves(HomeFixture.inputs(lists), facts: HomeTitleFacts()).flatMap(\.items)
            .filter { $0.imdbId == "tt22084616" }
        check(!spiderMan.isEmpty, "on the page")
        eq(Set(spiderMan.map(\.title)), ["Spider-Man: Brand New Day"], "YTS's real title, not Cinemeta's working one")

        eq(HomeTitleFacts.isPlaceholder("Untitled Jason Statham thriller"), true, "Untitled …")
        eq(HomeTitleFacts.isPlaceholder("untitled project"), true, "in any case")
        eq(HomeTitleFacts.isPlaceholder("TBA"), true, "TBA")
        eq(HomeTitleFacts.isPlaceholder(" TBD (2027)"), true, "TBD")
        eq(HomeTitleFacts.isPlaceholder("The Untitled Kartik Aaryan Film"), false, "only a title that starts with it")
        eq(HomeTitleFacts.isPlaceholder("Tbilisi"), false, "a word that starts with the letters")
        eq(HomeTitleFacts.isPlaceholder("Bytet"), false, "an original title is a real one")
    }
}
