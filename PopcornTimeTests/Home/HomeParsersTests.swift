//
//  HomeParsersTests.swift
//  PopcornTimeTests
//
//  The raw JSON of each source of the Home → cards, on the answers recorded on 2026-11-14
//  (Fixtures/Home, trimmed to the fields read), plus the cases the recordings do not have.
//

import Foundation
import XCTest
@testable import PopcornKit

final class HomeParsersTests: CheckedTestCase {

    private let now = HomeFixture.now

    private func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: Cinemeta

    func testCinemetaMovieCatalogue() {
        let entries = HomeFixture.entries("cm_movie_top.json", .cinemeta(.movie))
        eq(entries.count, 20, "movie/top: every meta is a card")
        let first = entries[0].item
        eq(first.id, "tt7526136", "id = IMDb id")
        eq(first.imdbId, "tt7526136", "imdbId")
        eq(first.kind, .movie, "kind")
        eq(first.title, "Heart of the Beast", "title")
        eq(first.year, 2026, "year from releaseInfo")
        eq(first.rating, 7.2, "imdbRating is a string in the catalog")
        eq(first.genres, ["Action", "Adventure", "Drama"], "genres")
        eq(first.runtimeMinutes, 101, "runtime \"101 min\"")
        eq(first.posterURL?.absoluteString, "https://images.metahub.space/poster/medium/tt7526136/img", "the medium poster, not the small one listed")
        eq(first.backdropURL?.absoluteString, "https://images.metahub.space/background/large/tt7526136/img", "the large backdrop")
        eq(first.logoURL?.absoluteString, "https://images.metahub.space/logo/medium/tt7526136/img", "logo")
        eq(first.trailerCode, "UkMuGKqAux4", "trailer = first trailerStreams ytId")
        eq(first.date, CatalogDates.date(from: "2026-09-25T00:00:00.000Z"), "released")
        check(first.summary?.hasPrefix("After a harrowing plane crash") == true, "description kept", first.summary ?? "nil")
        check(first.episode == nil && entries[0].episodes == nil, "a movie has no episodes")

        eq(entries[1].item.title, "Resident Evil", "second")
        check(entries[1].item.rating == nil, "an empty imdbRating is no rating, not 0")
        let undated = entries.first { $0.item.imdbId == "tt38515310" }
        check(undated != nil && undated?.item.date == nil, "a title without `released` has no date")
        eq(entries.first { $0.item.imdbId == "tt0077651" }?.item.year, 1978, "an old title in the trending list keeps its year (the hero filters on it)")
    }

    func testCinemetaSeriesKeepTheEpisodesAroundNow() {
        let entries = HomeFixture.entries("cm_series_top.json", .cinemeta(.show))
        eq(entries.count, 20, "series/top")
        let mobland = entries[0]
        eq(mobland.item.title, "MobLand", "first")
        eq(mobland.item.kind, .show, "kind")
        eq(mobland.item.year, 2025, "\"2025–\" → 2025")
        // The fixture keeps S1E1 (2025-03-30): outside the window, like most of a real `videos`.
        eq(mobland.episodes?.map { "\($0.season)x\($0.number)" }, ["2x8", "2x9"], "only the episodes around now are kept, oldest first")
        let latest = mobland.latestAired(now)
        eq(latest?.number, 9, "latest aired")
        eq(latest?.title, "Nervous Breakdown", "episode title")
        eq(latest?.stillURL?.absoluteString, "https://episodes.metahub.space/tt31510819/2/9/w780.jpg", "episode still")
        eq(latest?.airDate, CatalogDates.date(from: "2026-11-13T03:00:00.000Z"), "air date")
        check(mobland.item.episode == nil, "a catalog entry is a title card: the builder makes the episode cards")

        let dexter = entries.first { $0.item.imdbId == "tt33043892" }!
        eq(dexter.latestAired(now)?.number, 2, "Dexter: S2E2 aired on the 9th")
        eq(dexter.nextUpcoming(now)?.number, 3, "S2E3 airs on the 16th")
        // The cached list stays right for the days it is shown: three days later E3 has aired.
        eq(dexter.latestAired(now.addingTimeInterval(3 * 86_400))?.number, 3, "the latest aired episode follows the clock, not the fetch")
        check(dexter.nextUpcoming(now.addingTimeInterval(3 * 86_400)) == nil, "nothing upcoming known after it")

        let mentalist = entries.first { $0.item.imdbId == "tt1196946" }!
        eq(mentalist.episodes?.count, 0, "a show that ended in 2015 has no episode around now")
        check(mentalist.latestAired(now) == nil, "so no latest aired episode")
        check(entries[1].item.rating == nil, "Nocturne: not rated yet")
    }

    func testCinemetaEpisodeWindow() {
        func video(_ season: Int, _ episode: Int, _ released: String?) -> [String: Any] {
            var video: [String: Any] = ["season": season, "episode": episode, "name": "E\(episode)"]
            if let released = released { video["released"] = released }
            return video
        }
        let videos: [[String: Any]] = [
            video(0, 1, "2026-11-10T00:00:00.000Z"),      // a special
            video(1, 1, "2026-09-29T00:00:00.000Z"),      // 46 days ago: out
            video(1, 2, "2026-10-01T00:00:00.000Z"),      // 44 days ago: in
            video(1, 3, nil),                             // undated
            video(1, 4, "2026-11-14T14:40:00.000Z"),      // airs now: aired
            video(1, 5, "2026-11-14T14:40:01.000Z"),      // one second from now: upcoming
            video(1, 6, "2026-12-06T00:00:00.000Z"),      // 22 days ahead: out
            video(2026, 7, "2026-11-12T00:00:00.000Z"),   // a soap's year-numbered season
        ]
        let kept = HomeParse.episodes(cinemetaVideos: videos, now: now)
        eq(kept.map(\.number), [2, 4, 5], "specials, undated, far past, far future and year-numbered seasons are left out")
        let many = (1...40).map { video(3, $0, CatalogDates.dayString(now.addingTimeInterval(Double($0 - 30) * 86_400)) + "T00:00:00.000Z") }
        let window = HomeParse.episodes(cinemetaVideos: many, now: now)
        eq(window.count, HomeParse.episodeWindow.count, "a daily show is capped")
        eq(window.filter { ($0.airDate ?? .distantPast) > now }.count, 4, "a third of the cap for the upcoming ones")
        eq(window.last?.number, 34, "the next four")
        eq(window.first?.number, 23, "and the eight latest aired")
    }

    func testCinemetaYearCatalogueDropsStubs() {
        let entries = HomeFixture.entries("cm_series_year_2026.json", .cinemeta(.show))
        eq(entries.count, 9, "the entry without a poster (an announced title's stub) is left out")
        check(!entries.contains { $0.item.imdbId == "tt42767924" }, "the stub")
        let campus = entries[0]
        eq(campus.item.title, "Campus Drivers", "first")
        check(campus.item.date == nil, "no `released`")
        check(campus.latestAired(now) != nil, "but aired episodes: the builder keeps it")
    }

    func testCinemetaCalendarAndLookups() {
        let calendar = HomeFixture.entries("cm_calendar.json", .cinemeta(.show))
        eq(calendar.map(\.item.title), ["MobLand", "Nocturne", "Dexter: Resurrection", "Slow Horses", "Breaking Bad"], "metasDetailed")
        eq(calendar[0].episodes?.map(\.number), [6, 7, 8, 9, 10], "MobLand: the episodes around today, the next one included")
        eq(calendar[0].nextUpcoming(now)?.number, 10, "next")
        eq(calendar[4].episodes?.count, 0, "Breaking Bad: nothing around today")

        let lookups = HomeFixture.entries("cm_last_videos.json", .cinemeta(.show))
        eq(lookups.map(\.item.title).sorted(), ["9-1-1", "Beavis and Butt-Head", "Grey's Anatomy", "Hell's Kitchen",
                                                "Law & Order Toronto: Criminal Intent", "SWAT Exiles"], "last-videos: one card per show asked")

        let metas = (try? JSONSerialization.jsonObject(with: HomeFixture.data("cm_meta_movies.json"))) as? [String: Any] ?? [:]
        let streetFighter = try! JSONSerialization.data(withJSONObject: metas["tt27419420"]!)
        let found = HomeParse.entries(streetFighter, parser: .cinemetaMeta(.movie), now: now)
        eq(found?.map(\.item.title), ["Street Fighter"], "a meta is one card")
        eq(found?.first?.item.year, 2026, "its year")
        eq(HomeParse.entries(json("{}"), parser: .cinemetaMeta(.movie), now: now)?.count, 0, "{}: Cinemeta does not know the id — an answer, without a card")
        eq(HomeParse.entries(json(#"{"meta":{}}"#), parser: .cinemetaMeta(.movie), now: now)?.count, 0, "an empty meta too")
        check(HomeParse.entries(json("<html>Bad gateway</html>"), parser: .cinemetaMeta(.movie), now: now) == nil, "not JSON: a failure")
    }

    func testCinemetaRejectsWhatIsNotACatalog() {
        check(HomeParse.entries(json("<html></html>"), parser: .cinemeta(.movie), now: now) == nil, "an error page is a failure")
        check(HomeParse.entries(json(#"{"error":"not found"}"#), parser: .cinemeta(.movie), now: now) == nil, "a JSON without metas is a failure")
        check(HomeParse.entries(json("[]"), parser: .cinemeta(.movie), now: now) == nil, "an array is not a catalog")
        eq(HomeParse.entries(json(#"{"metas":[]}"#), parser: .cinemeta(.movie), now: now)?.count, 0, "an empty catalog is an answer")
        let odd = json(#"{"metas":[{"id":"nm0000001","name":"A person","poster":"p"},{"id":"tt1234567","name":"","poster":"p"},{"id":"tt1234567","name":"No poster"},7,{"id":"tt7654321","name":"Fine &amp; Dandy","poster":"https://x/p.jpg","type":"series","imdbRating":7,"releaseInfo":"1999-2004"},{"id":"tt7654321","name":"Twice","poster":"https://x/p.jpg"}]}"#)
        let kept = HomeParse.entries(odd, parser: .cinemeta(.movie), now: now) ?? []
        eq(kept.map(\.item.title), ["Fine & Dandy"], "not an IMDb id, no name, no poster, not an object, twice the same id: left out; entities decoded")
        eq(kept.first?.item.kind, .show, "the meta's own type wins over the catalog's")
        eq(kept.first?.item.rating, 7, "a numeric rating")
        eq(kept.first?.item.year, 1999, "\"1999-2004\"")
    }

    // MARK: YTS

    func testYTSList() {
        let entries = HomeFixture.entries("yts_new_2026.json", .yts)
        eq(entries.count, 30, "list_movies")
        let first = entries[0]
        eq(first.item.imdbId, "tt39571626", "imdb_code")
        eq(first.item.title, "El deshielo", "title")
        eq(first.item.kind, .movie, "kind")
        eq(first.item.year, 2026, "year")
        eq(first.item.rating, 6.7, "rating")
        eq(first.language, "es", "language")
        eq(first.item.runtimeMinutes, 108, "runtime")
        eq(first.item.trailerCode, "o0t7FOjxmtY", "trailer")
        eq(first.item.date, Date(timeIntervalSince1970: 1_794_612_216), "date_uploaded_unix")
        eq(first.qualities, 2, "720p and 1080p")
        check(first.item.badges.isEmpty, "no 4K release, no badge")
        eq(first.item.posterURL?.host, "images.weserv.nl", "the cover goes through the image proxy (its host is blocked by some ISPs)")
        check(first.item.posterURL?.absoluteString.contains("yts.gg/assets/images/movies/el_deshielo_2026/large-cover.jpg") == true, "the proxied cover", first.item.posterURL?.absoluteString ?? "nil")
        eq(first.item.backdropURL?.host, "images.weserv.nl", "the background too")
        check(first.item.logoURL == nil, "YTS has no logo")

        let jailer = entries.first { $0.item.imdbId == "tt33318732" }!
        eq(jailer.qualities, 3, "two 1080p encodes are one quality")
        eq(jailer.item.badges, [.uhd], "a 2160p torrent: 4K")
        eq(jailer.language, "ta", "Tamil")

        let uhd = HomeFixture.entries("yts_4k.json", .yts)
        let unrated = uhd.first { $0.item.imdbId == "tt29631525" }!
        check(unrated.item.rating == nil, "rating 0 is \"not rated\"")
        check(unrated.item.date == nil, "no upload date")
        check(uhd.allSatisfy { $0.item.badges == [.uhd] }, "every title of the 2160p list is 4K")
    }

    func testYTSAnswersThatAreNotLists() {
        let empty = json(#"{"status":"ok","status_message":"Query was successful","data":{"movie_count":0,"limit":50,"page_number":1}}"#)
        eq(HomeParse.entries(empty, parser: .yts, now: now)?.count, 0, "no `movies` key (an empty page, a year without movies yet): an empty answer")
        check(HomeParse.entries(json(#"{"status":"error","status_message":"down"}"#), parser: .yts, now: now) == nil, "status error")
        check(HomeParse.entries(json("<!DOCTYPE html><html>parked</html>"), parser: .yts, now: now) == nil, "a parked mirror's page")
        check(HomeParse.entries(json(#"{"metas":[]}"#), parser: .yts, now: now) == nil, "another API's JSON")
        let odd = json(#"{"status":"ok","data":{"movies":[{"imdb_code":"","title":"No id"},{"imdb_code":"tt1234567","title":"Tom &amp; Jerry","year":0,"rating":11,"runtime":0,"torrents":[]}]}}"#)
        let kept = HomeParse.entries(odd, parser: .yts, now: now) ?? []
        eq(kept.count, 1, "an entry without an IMDb id is left out")
        eq(kept.first?.item.title, "Tom & Jerry", "entities decoded")
        check(kept.first?.item.year == nil && kept.first?.item.runtimeMinutes == nil, "0 is \"unknown\"")
        eq(kept.first?.item.rating, 10, "a rating is capped at 10")
        eq(kept.first?.qualities, 0, "no torrent")
    }

    // MARK: TVMaze

    func testTVMazeWebSchedule() {
        let entries = HomeFixture.entries("tvm_web_2026-11-13.json", .tvmaze)
        // 12 episodes recorded: no IMDb id (Айда!), a year-numbered season (S2026E91) and an
        // unpopular show (weight 58) are left out.
        eq(entries.map { "\($0.item.title) \($0.item.episode!.season)x\($0.item.episode!.number)" },
           ["Tulsa King 4x5", "Nocturne 1x4", "MobLand 2x9", "Dexter: Resurrection 2x3", "12 12 12 1x1", "12 12 12 1x2",
            "Yaga 1x5", "Furia 2x6", "Cops 38x20"], "schedule/web: the show is under _embedded")
        let nocturne = entries[1]
        eq(nocturne.item.id, "tt26598805:1:4", "an episode card's id")
        eq(nocturne.item.imdbId, "tt26598805", "the show's IMDb id")
        eq(nocturne.item.kind, .show, "kind")
        eq(nocturne.item.episode?.title, "The Courier", "episode title")
        eq(nocturne.item.episode?.airDate, CatalogDates.date(from: "2026-11-13T12:00:00+00:00"), "airstamp")
        eq(nocturne.item.date, nocturne.item.episode?.airDate, "the card's date is the air date")
        check(nocturne.item.episode?.stillURL?.absoluteString.contains("static.tvmaze.com") == true, "the episode's still")
        eq(nocturne.item.posterURL?.absoluteString, "https://images.metahub.space/poster/medium/tt26598805/img", "the show's poster is metahub's by IMDb id (TVMaze's originals weigh up to 2 MB)")
        eq(nocturne.item.backdropURL?.absoluteString, "https://images.metahub.space/background/large/tt26598805/img", "its backdrop too")
        eq(nocturne.item.year, 2026, "premiered")
        eq(nocturne.item.rating, 7.7, "rating.average")
        eq(nocturne.item.genres, ["Drama", "Crime", "Thriller"], "genres")
        eq(nocturne.language, "en", "\"English\" → en")
        eq(nocturne.weight, 100, "weight")
        eq(nocturne.showType, "Scripted", "type")
        check(nocturne.item.summary?.contains("<") == false, "the summary's HTML is stripped", nocturne.item.summary ?? "nil")
        eq(entries.first { $0.item.title == "Furia" }?.language, "es", "a Spanish show is kept: the builder filters languages")
        eq(entries.first { $0.item.title == "Cops" }?.showType, "Reality", "so is a reality show: the builder filters types")
        check(entries.first { $0.item.title == "12 12 12" }?.item.rating == nil, "a null rating")
    }

    func testTVMazeNetworkSchedule() {
        let entries = HomeFixture.entries("tvm_us_2026-11-13.json", .tvmaze)
        // No IMDb id (The Story Is…), year-numbered seasons (Late Night S2026E107, CBS Mornings).
        eq(entries.map(\.item.id), ["tt0206512:17:23", "tt0206512:17:24", "tt32268630:2:6", "tt16098700:5:6", "tt6151526:2:5", "tt0123366:30:49"],
           "schedule?country=US: the show is under `show`")
        let today = HomeFixture.entries("tvm_web_2026-11-14.json", .tvmaze)
        eq(today.map(\.item.id), ["tt36329495:1:1", "tt36329495:1:2"], "a special (number null) is left out")
        eq(HomeParse.entries(json("[]"), parser: .tvmaze, now: now)?.count, 0, "a day without episodes is an answer")
        check(HomeParse.entries(json(#"{"name":"Not Found","status":404}"#), parser: .tvmaze, now: now) == nil, "an error object is a failure")
        let unaired = json(#"[{"name":"x","season":1,"number":1,"airstamp":null,"show":{"name":"S","weight":100,"externals":{"imdb":"tt1234567"}}}]"#)
        eq(HomeParse.entries(unaired, parser: .tvmaze, now: now)?.count, 0, "an episode without an air time is left out")
    }

    // MARK: apibay

    func testApibayShowsGroupedByImdbId() {
        let parsed = HomeFixture.entries("tpb_48h_208.json", .apibay(.show))
        // 32 releases: 3 without an IMDb id, the others under 21 ids. The three are pending, one
        // per show name read: "Greys.Anatomy.S14…" tied to Grey's Anatomy (it reads as the titled
        // "Greys Anatomy S23E05…"); MobLand and X Factor Italia name no titled release of the list.
        eq(parsed.filter { !$0.isPending }.count, 21, "one entry per IMDb id")
        eq(parsed.filter(\.isPending).map(\.readings), [["mobland"], ["xfactoritalia|2026"], ["greysanatomy"]], "then one pending entry per show name read")
        eq(parsed.filter(\.isPending).map(\.listedUnder), [nil, nil, "tt0413573"], "tied to the title of the list it names, if any")
        eq(parsed.filter(\.isPending).map(\.seeders), [1549, 78, 56], "with their seeders")
        eq(parsed.prefix(6).map(\.item.imdbId), ["tt33043892", "tt32375763", "tt16358384", "tt0413573", "", "tt7235466"],
           "most seeded first, the pending entries among the others")
        // The builder, before any card is known: the season pack joins the title the list ties it
        // to; the other two wait for a card of their name.
        let entries = HomeBuilder.attachingPending(parsed, known: [:], pooled: [])
        eq(entries[2].seeders, 1850 + 276 + 56, "Grey's Anatomy: its two titled releases and the season pack without an id")
        eq(entries[2].releaseName, "Greys Anatomy S23E05 1080p WEB h264-ETHEL", "its most seeded release still names it")
        eq(entries.count, 21, "MobLand and X Factor Italia: no card of their name yet")
        let dexter = entries[0]
        eq(dexter.seeders, 3201 + 2005 + 884 + 537, "the seeders of the four releases of the episode")
        eq(dexter.releaseName, "Dexter Resurrection S02E03 1080p WEB H264-CAKES", "the most seeded release names the group")
        eq(dexter.item.kind, .show, "kind")
        eq(dexter.item.title, "", "no title yet: the builder takes the card from the other lists")
        eq(dexter.item.date, Date(timeIntervalSince1970: 1_794_560_102), "the latest `added` of the group")
        check(dexter.item.badges.isEmpty, "1080p releases: no format badge")
        check(dexter.releaseLanguages == nil, "no language named")
        eq(entries[1].seeders, 1823 + 796, "12 12 12: two episodes of the same show")
    }

    func testApibayMoviesLeaveOutTheaterRecordings() {
        let entries = HomeFixture.entries("tpb_48h_207.json", .apibay(.movie))
        // 30 releases; 8 are DVDScr (Donga Naa Koduku, G.O.A.T, Ramayana, Scene, AK 47, Cult).
        check(!entries.contains { ["tt43738410", "tt27730178", "tt27988879", "tt38192494", "tt30768979", "tt3333428"].contains($0.item.imdbId) },
              "screeners and theater recordings are left out")
        eq(entries.count, 21, "the other titles")
        eq(entries[0].item.imdbId, "tt32324552", "Ranabaali first")
        eq(entries[0].releaseLanguages, ["te"], "its only release says Telugu")
        eq(entries.first { $0.item.imdbId == "tt27512908" }?.releaseLanguages, ["hi", "kn", "ta", "te"], "[Tel + Tam + Hin + Kan]")
        let streetFighter = entries.first { $0.item.imdbId == "tt27419420" }!
        eq(streetFighter.seeders, 483 + 361, "two releases")
        eq(streetFighter.releaseLanguages, ["en", "hi", "ta", "te"], "the languages of the most seeded release, the one that ranks the title: [Tel + Tam + Hin + Eng]")
        check(entries.first { $0.item.imdbId == "tt47791876" }?.releaseLanguages == nil, "a release that names none: the original language, or unknown")
        // A second, barely seeded release ("DUAL", "MULTI") does not make a Malayalam title an English one.
        let daayra = Data(#"[{"name":"Daayra (2026) 720p Malayalam HQ HDRip x264 DD+5.1 192Kbps AAC - ESub","seeders":1020,"imdb":"tt32634611","category":207},{"name":"Daayra (2026) DUAL (DS4K 1080p NF WEB-Rip E-AC3 5.1 10bit HEVC - SP1EG3L)","seeders":11,"imdb":"tt32634611","category":207}]"#.utf8)
        eq(HomeParse.entries(daayra, parser: .apibay(.movie), now: now)?.first?.releaseLanguages, ["ml"], "the most seeded release decides")
        eq(entries.first { $0.item.imdbId == "tt4154796" }?.item.badges, [.atmos], "\"DDP5.1.Atmos\"")
    }

    func testApibayTop100OfHDMovies() {
        // The movies' ranking since it reads the Top 100 (recorded 2026-11-16, 45 releases): eight
        // DVDScr screeners, one "HQ Pre" copy and one TELESYNC left out; six other releases have
        // no IMDb id.
        let parsed = HomeFixture.entries("tpb_207.json", .apibay(.movie))
        eq(parsed.filter { !$0.isPending }.count, 26, "one entry per IMDb id")
        // The six are pending, one per title read; three read as a titled release of the list
        // (Resident Evil, The Odyssey twice): tied to it.
        eq(parsed.filter(\.isPending).map(\.readings),
           [["residentevil|2026"], ["projecthailmary|2026"], ["streetfighter|2026"], ["odyssey|2026"], ["avengersendgame|2026"]],
           "Resident Evil, Project Hail Mary, Street Fighter, The Odyssey, Avengers Endgame Encore (a re-release: \"Encore\" read as an edition)")
        eq(parsed.filter(\.isPending).map(\.listedUnder), ["tt35538033", nil, nil, "tt33764258", nil], "tied to the title of the list they name, if any")
        eq(parsed.filter(\.isPending).map(\.seeders), [4748, 3880, 3500, 1942 + 1302, 2192], "with their seeders")
        check(parsed.filter(\.isPending).allSatisfy { $0.item.imdbId.isEmpty && $0.item.title.isEmpty }, "no id, no title")
        // The builder, before any card is known: the tied ones join their title (a card, once
        // known, must have their name and year); the others wait for a card of their name.
        let entries = HomeBuilder.attachingPending(parsed, known: [:], pooled: [])
        eq(entries.count, 26, "the titles of the list")
        let residentEvil = entries.first { $0.item.imdbId == "tt35538033" }!
        eq(residentEvil.seeders, 1478 + 4748, "Resident Evil: its titled release and the Kitsune one without an id")
        eq(residentEvil.releaseName, "Resident Evil 2026 REPACK 1080p AMZN WEB-DL DDP5 1 Atmos H 264-Kitsune",
           "the most seeded release names the group, with or without an id")
        eq(residentEvil.item.badges, [.atmos], "its badges too: \"DDP5 1 Atmos\"")
        let screeners = ["tt43738410", "tt27988879", "tt27730178", "tt38192494", "tt39131708", "tt30768979"]
        check(!entries.contains { screeners.contains($0.item.imdbId) },
              "Donga Naa Koduku, Ramayana, G.O.A.T, Scene, Itllu Arjuna, AK 47: DVDScr, left out")
        eq(entries[0].item.imdbId, "tt33764258", "The Odyssey first")
        eq(entries[0].seeders, 9685 + 4455 + 1942 + 1302, "its two titled releases, and the Kitsune and LAMA ones without an id (not the TELESYNC)")
        eq(entries.prefix(3).map(\.item.imdbId), ["tt33764258", "tt22084616", "tt32324552"], "then Spider-Man: Brand New Day, then Ranabaali")
        eq(entries[2].releaseLanguages, ["te"], "\"Telugu HQ HDRip\": Telugu")
        let spiderMan = entries.first { $0.item.imdbId == "tt22084616" }!
        eq(spiderMan.seeders, 7560 + 3397, "Spider-Man: the \"HQ Pre\" copy's 2,758 seeders do not count")
        eq(spiderMan.releaseLanguages, nil, "its most seeded release names no language")
        check(!entries.contains { ($0.releaseName ?? "").contains("TELESYNC") }, "The Odyssey's TELESYNC has no id anyway, and is a recording")
    }

    func testReadingsOfReleaseNames() {
        // What a release without an IMDb id reads as: the Top 100 grid's reading of a name
        // (`ReleaseMatch.movieTitleCandidates`, `showReadings`), as "title|year" keys.
        let movies: [(String, [String])] = [
            ("Resident Evil 2026 REPACK 1080p AMZN WEB-DL DDP5 1 Atmos H 264-Kitsune", ["residentevil|2026"]),
            ("The Odyssey (2026) 1080p WEBRip x265 10bit 5.1-LAMA", ["odyssey|2026"]),
            ("Spider-Man: Brand New Day 2026.1080p.WEB", ["spidermanbrandnewday|2026"]),
            // Two years in a row read as several films (`isPackOrExtras`): left out, the safe side.
            ("Wonder.Woman.1984.2020.1080p.WEB", []),
            ("Fantastic Four 1994 Remastered 2023 1080p", ["fantasticfour|1994", "fantasticfour1994|2023"]),
            ("Avengers Endgame Encore (2026) 1080p HDRip", ["avengersendgame|2026"]),
            ("Avengers.Endgame.Encore.2026.1080p.IMAX.DSNP.WEB-DL", ["avengersendgame|2026"]),
            ("Blade Runner Director's Cut 1982 1080p", ["bladerunner|1982"]),
            ("Akira Kurosawa Boxset", []), ("Disney MEGA Collection 1937-2008", []), ("Project Hail Mary 1080p WEBRip", []),
            ("Star Wars 14 Movie Collection 1977-2019 - threesixtyp", []), ("Rome - Seasons 1 and 2 - HBO", []),
            ("Lupin.2021.S04.1080p.NF.WEB-DL", []), ("The Complete Matrix 1999 1080p", []),
        ]
        for (name, keys) in movies { eq(HomeParse.readings(ofRelease: name, kind: .movie), keys, "movie: \(name)") }
        // "Encore" is read as an edition here only: the Top 100 grid and the source picker keep
        // their reading of the name.
        eq(ReleaseMatch.movieTitleCandidates("Avengers Endgame Encore (2026) iMAX 1080p").first?.title, "avengers endgame encore",
           "the grid's reading of an Encore")
        check(!ReleaseMatch.editionWords.contains("encore"), "not one of the shared edition words")
        let shows: [(String, [String])] = [
            ("MobLand S02E09 Nervous Breakdown 1080p AMZN WEB-DL DDP5 1 H 264-RAWR", ["mobland"]),
            ("The Office (US) (2005) Season 1-9 S01-S09 (1080p BluRay x265 HEV", ["office|2005"]),
            ("The Last of Us S02E01 1080p WEB", ["last|US", "lastofus"]),
            ("Greys.Anatomy.S14.1080p.WEBRip.AV1.Opus.5.1-heTOrico", ["greysanatomy"]),
            ("UFC 334 1080p ENG", []), ("AEW Full Gear 2026 MyAEW 720p WEB H264-XWT [TJET]", []),
        ]
        for (name, keys) in shows { eq(HomeParse.readings(ofRelease: name, kind: .show), keys, "show: \(name)") }
        // And what a known title answers to.
        eq(HomeParse.readings(ofTitle: "Amélie", year: 2001, kind: .movie), ["amelie|2001", "amlie|2001"], "accents folded, or dropped")
        eq(HomeParse.readings(ofTitle: "The Odyssey", year: nil, kind: .movie), [], "a movie without a year: none")
        eq(HomeParse.readings(ofTitle: "Doctor Who (2005)", year: 2005, kind: .show), ["doctorwho", "doctorwho|2005"], "a show: its name, and with its year")
    }

    func testTheaterRecordingsAndScreeners() {
        // The spellings of a theater copy or a pre-release screener, from the Top 100 of
        // 2026-11-16 and the usual variants: never ranked on the Home, last among a title's sources.
        for name in ["Donga Naa Koduku (2026) 720p Telugu DVDScr x264 AAC", "The.Odyssey.2026.1080p.TELESYNC.HEVC.AAC2.0-SPLiCE",
                     "Spider-Man: Brand New Day 2026.1080p.HQ Pre.Multi.AAC 2.0.x264", "Movie.2026.1080p.HDTS.x264-GRP",
                     "Movie 2026 1080p HD-TS x264", "Movie 2026 720p HDTSRip", "Movie 2026 HDCAM x264", "Movie 2026 HDCAMRip x264",
                     "Movie.2026.CAM.x264", "Movie (2026) HQ PreDVD 720p", "Movie (2026) 1080p Pre-DVD x264", "Movie.2026.PreDVDRip.x264",
                     "Movie.2026.DVDScreener.XviD", "Movie 2026 BDScr 1080p", "Movie.2026.HDTC.x264", "Movie 2026 720p HD-TC x264",
                     "Movie 2026 TeleCine x264", "Movie 2026 HQCam 720p",
                     "Movie (2026) 1080p HQ S-Print x264 AAC", "Movie (2026) 720p S Print", "Movie 2026 720p SPrint x264",
                     "Movie (2026) 1080p Pre-HDRip x264", "Movie (2026) PreHDRip 720p", "Movie.2026.1080p.TC.x264", "Movie 2026 TC x264"] {
            check(VideoTags.parse(name).contains(.cam), "a recording: \(name)")
        }
        for name in ["Ranabaali (2026) 1080p Telugu HQ HDRip HEVC x265 DD+5.1 192Kbps AAC-ESub", "Coyote.vs.Acme.2026.1080p.DCPRIP.HEVC.x265.RMTeam",
                     "The.Pre.Party.2023.1080p.WEB-DL.x264", "Pre.Dvd.Things.2020.1080p.WEB", "Cam.2018.1080p.NF.WEB-DL", "Movie.2026.1080p.WEB.TC.x264",
                     "The Odyssey (2026) [1080p] [BluRay] [5.1]", "Movie 2026 1080p HD WEB-DL", "Movie (2026).ts",
                     "Sprint.2024.S01E01.1080p.NF.WEB-DL", "Pre.HDRip.Story.2020.1080p.WEB", "The.Print.2020.1080p.WEB", "Show.S01E05.1080p.WEB.x264"] {
            check(!VideoTags.parse(name).contains(.cam), "not a recording: \(name)")
        }
    }

    func testApibayUHDBadges() {
        let entries = HomeBuilder.attachingPending(HomeFixture.entries("tpb_211.json", .apibay(.movie)), known: [:], pooled: [])
        eq(entries.prefix(3).map(\.item.imdbId), ["tt35538033", "tt33764258", "tt12042730"], "Resident Evil, The Odyssey, Project Hail Mary")
        eq(entries[0].seeders, 1747 + 548 + 512 + 402, "Resident Evil: three releases with its id, and the MIRCrew one without")
        eq(entries[0].item.badges, [.uhd, .dolbyVision, .hdr, .atmos], "DV.HDR10+ … Atmos")
        eq(entries[1].item.badges, [.uhd, .hdr], "The Odyssey: HDR, DTS-HD MA (no Dolby Vision, no Atmos)")
        eq(entries[2].item.badges, [.uhd, .dolbyVision, .hdr, .atmos], "Project Hail Mary: the badges of all its releases")
        check(entries.allSatisfy { $0.item.badges.contains(.uhd) }, "category 211 is UHD")
        check(HomeParse.entries(json(#"{"error":"x"}"#), parser: .apibay(.movie), now: now) == nil, "not a list: a failure")
        let hostile = json(#"[{"name":"A.Film.2026.2160p.WEB","seeders":"9223372036854775807","imdb":"tt1234567","category":211,"added":"1"},{"name":"A.Film.2026.1080p.WEB","seeders":-5,"imdb":"tt1234567"}]"#)
        eq(HomeParse.entries(hostile, parser: .apibay(.movie), now: now)?.first?.seeders, 10_000_000, "absurd counts are clamped, numbers may be strings")
    }

    // MARK: Helpers

    func testReleaseLanguages() {
        func named(_ name: String) -> [String]? { HomeLanguages.named(inRelease: name)?.sorted() }
        eq(named("Bandra (2023) Malayalam TRUE WEB-DL 1080p AVC DD+5.1 192Kbps AAC - ESub"), ["ml"], "a language after the year")
        eq(named("Reckless.2026.1080p.ITA-ENG.WEBRip.x265.AAC-V3SP4EV3R.mkv"), ["en", "it"], "ITA-ENG")
        check(named("Never.Surrender.2026.1080p.ITA-IND-ENG.MULTI.WEBRip.x265.AAC-V3SP4EV3R.mkv") == nil, "MULTI: carries the original language")
        check(named("Dexter Resurrection S02E03 1080p WEB H264-CAKES") == nil, "none named")
        check(named("The English Patient 1996 1080p BluRay x264") == nil, "a language in the title is the title")
        check(named("Mal 2026 1080p WEB h264") == nil, "\"Mal\" before the year is the title")
        eq(named("Mal 2026 1080p MAL WEB h264"), ["ml"], "after it, a language")
        check(named("Some Movie Hindi") == nil, "nothing tells the title from the tags: unknown")
        eq(named("Show S02E03 FRENCH 720p HDTV"), ["fr"], "after an episode marker")

        eq(HomeLanguages.code(ofEnglishName: "English"), "en", "TVMaze names")
        eq(HomeLanguages.code(ofEnglishName: "French"), "fr", "French")
        eq(HomeLanguages.code(ofEnglishName: "Chinese"), "zh", "Chinese")
        eq(HomeLanguages.code(ofEnglishName: "Norwegian"), "no", "Norwegian")
        check(HomeLanguages.code(ofEnglishName: "Klingon") == nil && HomeLanguages.code(ofEnglishName: nil) == nil, "unknown names")
        eq(HomeLanguages.code(ofIdentifier: "fr-FR"), "fr", "a locale identifier")
        eq(HomeLanguages.code(ofIdentifier: "en_US"), "en", "with an underscore")
        eq(HomeLanguages.code(ofIdentifier: "ES"), "es", "upper case")
        check(HomeLanguages.code(ofIdentifier: "") == nil, "empty")
    }

    func testReleaseNamesItsTitle() {
        func names(_ release: String, _ title: String, _ year: Int? = nil, _ kind: HomeItem.Kind = .show) -> Bool {
            HomeParse.names(release, title: title, year: year, kind: kind)
        }
        check(names("Dexter Resurrection S02E03 1080p WEB H264-CAKES", "Dexter: Resurrection"), "punctuation")
        check(names("Greys Anatomy S23E05 1080p WEB h264-ETHEL", "Grey's Anatomy"), "apostrophe")
        check(names("S W A T Exiles S01E08 1080p HEVC x265-MeGusta", "SWAT Exiles"), "spelled out letter by letter")
        check(names("Law.and.Order.Toronto.Criminal.Intent.S04E08.1080p.x265-ELiTE", "Law & Order Toronto: Criminal Intent"), "& / and")
        check(names("Mike Judges Beavis and Butt-Head S04E12 Chickens 1080p HULU WEB-DL AAC2 0 H 264-NTb", "Beavis and Butt-Head"), "a longer release title")
        check(names("9-1-1 Nashville S02E05 720p HEVC x265-MeGusta", "9-1-1: Nashville"), "digits")
        check(names("War 2026 S01E07 1080p WEB h264-ETHEL", "War", 2025), "a show's year is not compared (the release names the season's)")
        check(!names("Tulsa King S04E05 1080p WEB H264-CAKES", "Grey's Anatomy"), "another show")
        check(names("Resident.Evil.2026.2160p.iT.WEB-DL.DV.HDR10+.DDP.5.1.Atmos.H265.MP4-BTM", "Resident Evil", 2026, .movie), "a movie and its year")
        check(names("Amelie.2001.1080p.BluRay.x264", "Amélie", 2002, .movie), "accents; a year off by one")
        check(!names("Avengers.Endgame.Encore.2026.1080p.IMAX.DSNP.WEB-DL.DDP5.1.Atmos.H264.MP4-BTM", "Avengers: Endgame", 2019, .movie), "the same words, another year: not this movie's card")
        check(!names("Interstellar.2014.1080p.BluRay.x264.YIFY", "Lazarus", 2015, .movie), "apibay's wrong id: another title")
        check(names("1917.2019.2160p.UHD.BluRay.x265", "1917", 2019, .movie), "a title that is a year")
        check(!names("Whatever.2026.1080p", "", 2026, .movie), "no title")
    }

    func testDates() {
        eq(CatalogDates.date(from: "2026-07-31T00:00:00.000Z")?.timeIntervalSince1970, 1_785_456_000, "Cinemeta: milliseconds and Z")
        eq(CatalogDates.date(from: "2026-11-13T12:00:00+00:00")?.timeIntervalSince1970, 1_794_571_200, "TVMaze: an offset")
        eq(CatalogDates.date(from: "2026-11-13T12:00:00+01:00")?.timeIntervalSince1970, 1_794_567_600, "one hour east: an hour earlier in UTC")
        eq(CatalogDates.date(from: "2026-11-13T12:00:00-0500")?.timeIntervalSince1970, 1_794_589_200, "an offset without a colon")
        eq(CatalogDates.date(from: "2026-10-30")?.timeIntervalSince1970, 1_793_318_400, "a day: midnight UTC")
        eq(CatalogDates.date(from: "2024-02-29T23:59:59Z")?.timeIntervalSince1970, 1_709_251_199, "a leap day")
        eq(CatalogDates.date(from: "1969-12-31T23:59:59Z")?.timeIntervalSince1970, -1, "before 1970")
        check(CatalogDates.date(from: nil) == nil && CatalogDates.date(from: "") == nil && CatalogDates.date(from: "soon") == nil
              && CatalogDates.date(from: "2026-13-01") == nil && CatalogDates.date(from: "2026-11-13T25:00:00Z") == nil, "what is not a date")
        eq(CatalogDates.dayString(now), "2026-11-14", "the day in UTC")
        eq(CatalogDates.dayString(CatalogDates.date(from: "2026-12-31T23:59:59Z")!), "2026-12-31", "the last second of the year")
        eq(CatalogDates.dayString(CatalogDates.date(from: "2027-01-01T00:00:00Z")!), "2027-01-01", "the first of the next")
        eq(CatalogDates.year(of: CatalogDates.date(from: "2026-12-31T23:59:59Z")!), 2026, "year")
        eq(CatalogDates.year(of: CatalogDates.date(from: "2027-01-01T00:00:00Z")!), 2027, "next year")
        eq(CatalogDates.dayString(Date(timeIntervalSince1970: -1)), "1969-12-31", "before 1970")
        check(HomeParse.isImdbId("tt1234567") && HomeParse.isImdbId("tt26598805"), "IMDb ids")
        check(!HomeParse.isImdbId("tt") && !HomeParse.isImdbId("nm0000001") && !HomeParse.isImdbId("tt12a4567")
              && !HomeParse.isImdbId("tt123") && !HomeParse.isImdbId("tt1234567/../x"), "what is not one (ids go into request paths)")
    }
}
