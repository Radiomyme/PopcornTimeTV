//
//  ReleaseMatchingTests.swift
//  PopcornTimeTests
//
//  The extra sources (apibay, Knaben, Cinemeta, TVMaze) against recorded answers in
//  Fixtures/Sources: parsing, title / year / episode matching, packs and namesakes, the
//  Top 100 grouping and its resolution through Cinemeta. Never calls the APIs.
//  (Port of the more-sources harness: 2345 checks.)
//

import XCTest
import Foundation
@testable import PopcornKit

private let fixtures = Fixtures.url("Sources")
private func loadFixture(_ name: String) -> Data {
    return Fixtures.data("Sources/" + name)
}
private func json(_ name: String) -> Any { try! JSONSerialization.jsonObject(with: loadFixture(name)) }

private typealias Movie = ReleaseMatch.MovieIdentity
private func accepts(_ movie: Movie, _ name: String, imdb: String? = nil) -> Bool {
    ReleaseMatch.isRelease(name, of: movie, indexImdb: imdb)
}
private func expect(_ movie: Movie, accept: [String], reject: [String], line: Int = #line) {
    for name in accept { check(accepts(movie, name), "\(movie.titles[0]) \(movie.years.sorted()) should ACCEPT '\(name)'", line: line) }
    for name in reject { check(!accepts(movie, name), "\(movie.titles[0]) \(movie.years.sorted()) should REJECT '\(name)'", line: line) }
}

private let interstellar = Movie(titles: ["Interstellar"], years: [2014], imdbId: "tt0816692")
private let it2017 = Movie(titles: ["It"], years: [2017], imdbId: "tt1396484")
private let us = Movie(titles: ["Us"], years: [2019], imdbId: "tt6857112")
private let up = Movie(titles: ["Up"], years: [2009], imdbId: "tt1049413")
private let alien = Movie(titles: ["Alien"], years: [1979], imdbId: "tt0078748")
private let aliens = Movie(titles: ["Aliens"], years: [1986], imdbId: "tt0090605")
private let dune2021 = Movie(titles: ["Dune", "Dune: Part One"], years: [2021], imdbId: "tt1160419")
private let dune1984 = Movie(titles: ["Dune"], years: [1984], imdbId: "tt0087182")
private let amelie = Movie(titles: ["Amélie"], years: [2001, 2002], imdbId: "tt0211915")

private func identity(_ imdb: String, search: String?) -> ReleaseMatch.ShowIdentity {
    let show = json("tvm_lookup_\(imdb).json") as! [String: Any]
    let akas = ReleaseMatch.englishAkas(json("tvm_akas_\(imdb).json") as? [[String: Any]] ?? [])
    let results = search.map { json("tvm_search_\($0).json") as! [[String: Any]] }
    return ReleaseMatch.showIdentity(tvmaze: show, akas: akas, searchResults: results)
}
private let mobland = identity("tt31510819", search: "mobland")
private func expectEpisode(_ show: ReleaseMatch.ShowIdentity, _ season: Int, _ episode: Int, accept: [String], reject: [String], line: Int = #line) {
    for name in accept {
        check(ReleaseMatch.isRelease(name, season: season, episode: episode, of: show), "\(show.titles[0]) S\(season)E\(episode) should ACCEPT '\(name)'", line: line)
    }
    for name in reject {
        check(!ReleaseMatch.isRelease(name, season: season, episode: episode, of: show), "\(show.titles[0]) S\(season)E\(episode) should REJECT '\(name)'", line: line)
    }
}
private let shogun = ReleaseMatch.ShowIdentity(titles: ["Shōgun"], year: 2024, country: "US", isAmbiguous: true)
private let movieTop = [201, 207, 211].flatMap { PirateBayClient.releases(fromJSON: loadFixture("top100_\($0).json")) }
private let showTop = [205, 208, 212].flatMap { PirateBayClient.releases(fromJSON: loadFixture("top100_\($0).json")) }
private let movieGroups = Top100Ranking.movieGroups(movieTop)
private let showGroups = Top100Ranking.showGroups(showTop)
/// The recorded Cinemeta answers (Fixtures/Sources/cinemeta.json: file name → answer), read-only: never the API.
private let cinemetaAnswers: [String: Any] = (try? JSONSerialization.jsonObject(with: Fixtures.data("Sources/cinemeta.json"))) as? [String: Any] ?? [:]
private func cinemetaAnswer(_ file: String) -> Any? { cinemetaAnswers[file] }
private final class Recorder {
    let dir: URL
    init(_ dir: URL) {
        self.dir = dir
    }
    var misses = 0
    func fetch(_ url: String, file: String) -> Any? {
        if let answer = cinemetaAnswer(file) { return answer }
        misses += 1
        return nil
    }
}
private let recorder = Recorder(fixtures.appendingPathComponent("cinemeta"))
private let recordLock = NSLock()
private func slug(_ text: String) -> String { text.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() }

private func resolveTop(_ kind: CinemetaClient.Kind, _ groups: [Top100Group], limit: Int = 100) -> [Top100Resolver.Resolved] {
    let resolver = Top100Resolver(kind: kind, maxConcurrent: 4, fetchMeta: { kind, id, completion in
        recordLock.lock()
        let root = recorder.fetch("https://v3-cinemeta.strem.io/meta/\(kind.rawValue)/\(id).json", file: "\(kind.rawValue)_meta_\(id).json") as? [String: Any]
        recordLock.unlock()
        let meta = root?["meta"] as? [String: Any]
        completion((meta?.isEmpty ?? true) ? nil : meta, true)
    }, search: { kind, query, completion in
        var found: [[String: Any]] = []
        recordLock.lock()
        defer { completion(found, true) }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        let root = recorder.fetch("https://v3-cinemeta.strem.io/catalog/\(kind.rawValue)/top/search=\(encoded).json", file: "\(kind.rawValue)_search_\(slug(query)).json") as? [String: Any]
        found = root?["metas"] as? [[String: Any]] ?? []
        recordLock.unlock()
    })
    let semaphore = DispatchSemaphore(value: 0)
    var output: [Top100Resolver.Resolved] = []
    resolver.resolve(groups, limit: limit, deadline: 20) { resolved, _ in
        output = resolved
        semaphore.signal()
    }
    semaphore.wait()
    return output
}

final class ReleaseMatchingTests: CheckedTestCase {

    func testApibayParsing() {
        do {
            let none = PirateBayClient.releases(fromJSON: loadFixture("tpb_q_zzqqxxnotitle_1999.json"))
            check(none.isEmpty, "apibay sentinel 'No results returned' must be dropped, got \(none.map(\.name))")

            let top = PirateBayClient.releases(fromJSON: loadFixture("top100_207.json"))
            check(top.count == 100, "top100_207: 100 entries, got \(top.count)")
            check(top.allSatisfy { $0.category == 207 && $0.source == "TPB" && $0.infoHash.count == 40 }, "top100_207 categories / hashes")
            check(top.contains { $0.imdb == nil } && top.contains { $0.imdb == "tt33764258" }, "imdb null → nil, tt kept")
            check(top.first?.seeders == 10194 && top.first?.bytes ?? 0 > 0, "numbers as JSON numbers")

            let search = PirateBayClient.releases(fromJSON: loadFixture("tpb_q_it_2017.json"))
            check(search.count == 100, "q.php: 100 results, got \(search.count)")
            check(search.first?.seeders == 188 && search.first?.category == 207, "numbers as strings: \(String(describing: search.first))")
            check(search.first(where: { $0.name.hasPrefix("IT.Chapter.One.2017.2160p.MA") })?.imdb == nil, "empty imdb string → nil")

            // Malformed / placeholder entries.
            let synthetic = """
            [{"id":"0","name":"No results returned","info_hash":"0000000000000000000000000000000000000000","seeders":"0","leechers":"0","size":"0","category":"0","imdb":""},
             {"id":"5","name":"Bad hash","info_hash":"xyz","seeders":"3","leechers":"0","size":"10","category":"207","imdb":"tt"},
             {"id":"6","name":"Ok.2020.1080p","info_hash":"ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD","seeders":"3","leechers":"1","size":"1073741824","category":"207","imdb":"0"}]
            """.data(using: .utf8)!
            let parsed = PirateBayClient.releases(fromJSON: synthetic)
            check(parsed.count == 1 && parsed[0].infoHash == "abcdefabcdefabcdefabcdefabcdefabcdefabcd" && parsed[0].imdb == nil,
                  "synthetic apibay: \(parsed)")
            check(parsed.first?.sizeString == "1.00 GB", "size string \(String(describing: parsed.first?.sizeString))")
            check(PirateBayClient.releases(fromJSON: "<html>blocked</html>".data(using: .utf8)!).isEmpty, "HTML block page → []")
        }
    }

    func testKnabenParsing() {
        do {
            check(KnabenClient.releases(fromJSON: loadFixture("kn_zzqqxxnotitle_1999.json"))?.isEmpty == true, "Knaben empty hits")
            check(KnabenClient.releases(fromJSON: "<html>".data(using: .utf8)!) == nil, "Knaben non-JSON → nil (v1 fallback)")
            let hits = KnabenClient.releases(fromJSON: loadFixture("kn_interstellar_2014.json"))!
            check(hits.count >= 50, "Knaben interstellar hits \(hits.count)")
            check(hits.contains { $0.source == "Knaben · TPB" } && hits.contains { $0.source == "Knaben · YTS" }, "Knaben source labels")
            let yify = hits.filter { $0.infoHash == "89599bf4dc369a3a8eca26411c5ccf922d78b486" }
            check(yify.count == 2, "same hash listed by TPB and YTS: \(yify.count)")
            let deduped = IndexedRelease.deduplicated(hits)
            check(deduped.filter { $0.infoHash == "89599bf4dc369a3a8eca26411c5ccf922d78b486" }.count == 1, "dedupe by hash")
            check(deduped.first { $0.infoHash == "89599bf4dc369a3a8eca26411c5ccf922d78b486" }?.seeders == yify.map(\.seeders).max(), "dedupe keeps best seeders")
            check(hits.first?.seeders == 1059, "liveSeeders preferred: \(String(describing: hits.first?.seeders))")
            let tpbAndKnaben = PirateBayClient.releases(fromJSON: loadFixture("tpb_q_interstellar_2014.json")) + hits
            let merged = IndexedRelease.deduplicated(tpbAndKnaben)
            check(merged.count < tpbAndKnaben.count && Set(merged.map(\.infoHash)).count == merged.count, "TPB + Knaben deduped by hash \(tpbAndKnaben.count) → \(merged.count)")
            check(merged.first { $0.infoHash == "89599bf4dc369a3a8eca26411c5ccf922d78b486" }?.source == "TPB", "first listing (TPB) wins")
        }
    }

    func testNormalizationHelpers() {
        do {
            check(ReleaseMatch.words("Ocean's Eleven") == ["oceans", "eleven"], "apostrophe")
            check(ReleaseMatch.words("Spider-Man: Brand New Day") == ["spider", "man", "brand", "new", "day"], "punctuation")
            check(ReleaseMatch.words("Amélie & Co") == ["amelie", "and", "co"], "accents / ampersand")
            check(ReleaseMatch.words(ReleaseMatch.cleaned("The Worst Person in the World [2021 - Norway] comedy")) == ["the", "worst", "person", "in", "the", "world", "2021", "comedy"], "bracketed year kept")
            check(ReleaseMatch.words(ReleaseMatch.cleaned("Top Gear   (BBC - Seasons 1 to 17 - Complete)")) == ["top", "gear"], "bracketed group dropped")
            check(ReleaseMatch.words(ReleaseMatch.cleaned("Us 2019&nbsp; 1080p")) == ["us", "2019", "1080p"], "&nbsp;")
            check(ReleaseMatch.searchTerms("Spider-Man: Brand New Day") == "spider man brand new day", "search terms")
            check(ReleaseMatch.searchTerms("It's Always Sunny in Philadelphia") == "its always sunny in philadelphia", "search terms apostrophe")
            check(IndexedRelease.normalizedImdb("0816692") == "tt0816692" && IndexedRelease.normalizedImdb("tt") == nil && IndexedRelease.normalizedImdb("") == nil, "imdb normalization")
            check(IndexedRelease.normalizedInfoHash(String(repeating: "0", count: 40)) == nil, "zero hash")
            check(IndexedRelease.normalizedInfoHash("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567") == "abcdefghijklmnopqrstuvwxyz234567", "base32 hash")
        }
    }

    func testMovieMatching() {
        let her = Movie(titles: ["Her"], years: [2013], imdbId: "tt1798709")
        let halloween1978 = Movie(titles: ["Halloween"], years: [1978], imdbId: "tt0077651")
        let halloween2007 = Movie(titles: ["Halloween"], years: [2007], imdbId: "tt0373883")
        let halloween2018 = Movie(titles: ["Halloween"], years: [2018], imdbId: "tt1502407")
        expect(interstellar,
               accept: ["Interstellar (2014) (2014) 1080p BrRip x264 - YIFY", "Interstellar.2014.PROPER.IMAX.1080p.UHD.BluRay.x265",
                        "Interstellar 2014 IMAX 1080p BluRay HEVC x265 5.1 BONE", "Interstellar IMAX 2014 (1080p Bluray x265 HEVC AAC 5.1 Joy)[UTR]",
                        "[YTS.MX] Interstellar (2014) 2160p"],
               reject: ["The Science of Interstellar (2014) 1080p BRRip x264 -YTS", "Hans Zimmer - Interstellar (OST) (2014) [MP3 @ 320 kbps]",
                        "Interstellar Wars 2016 1080p", "Interstellar.2015.1080p", "Interstellar 1080p BluRay"])
        // imdb evidence: accepted without a year only under the movie's own id, and
        // a wrong id never vetoes an exact title + year.
        check(accepts(interstellar, "Interstellar 1080p BluRay x264", imdb: "tt0816692"), "title + technical + own imdb, no year")
        check(!accepts(interstellar, "Interstellar 1080p BluRay x264", imdb: "tt4288316"), "title without year, other imdb")
        check(accepts(interstellar, "Interstellar (2014) (2014) 1080p BrRip x264 - YIFY", imdb: "tt4288316"), "wrong TPB imdb, exact title + year")
        check(!accepts(interstellar, "Interstellar Wars 1080p", imdb: "tt0816692"), "own imdb but other title")
        check(!accepts(interstellar, "Interstellar 2016 1080p", imdb: "tt0816692"), "own imdb but year contradicts")
        check(!accepts(it2017, "IT Chapter 1 And 2 2017-2019 720p H264 BONE", imdb: "tt1396484"), "own imdb, pack")

        expect(it2017,
               accept: ["It.2017.1080p.BRRip.6CH.MkvCage", "It 2017 BluRay 1080p DDP 5 1 x264-hallowed", "It. 2017.2160p.AI Enhanced.WEB-DL",
                        "IT.2017.1080p.10bit.BluRay.8CH.x265.HEVC-PSA", "It (2017) 1080p BRRip x264 -YTS"],
               reject: ["IT Chapter 1 And 2 2017-2019 720p H264 BONE",
                        "It Comes at Night (2017) 1080p BrRip x264 - VPPV", "IT 1, 2, Stephen King 1990 Remake 2017 Eng Ita Spa [Subs 1080p]",
                        "It Happened One Valentines 2017 1080p AMZN WEB-DL", "It Chapter Two 2019 1080p", "It 1990 Miniseries 720p"])
        expect(us,
               accept: ["Us-(2019)-[WEBRip]-(1080p)", "Us..2019..[WEBRip].[720p]", "Us 2019&nbsp; 1080p.Ai Enhanced.WEB-DL", "Us.2019.1080p.WEB-DL.DD5.1.H264-FGT"],
               reject: ["Euphoria (US) (2019) Season 1 S01 (1080p AMZN WEB-DL x265 HEVC 1", "Beneath Us (2019) [WEBRip] [1080p]", "Fix Us 2019 1080p WEBRip",
                        "Love Island US 2019 Season 1 Complete 720p", "Roger.Waters.Us.Them.2019.1080p", "Til Death Do Us Part S01E03 2019 2160p"])
        expect(her, accept: ["Her.2013.1080p.BluRay.x264-SPARKS", "Her (2013) [1080p]"],
               reject: ["Her Smell 2018 1080p", "Her.2014.1080p", "Hereditary 2018 1080p", "Her Story 2013 1080p"])
        expect(up, accept: ["Up.2009.1080p.BluRay.x264", "Up (2009) [1080p]"],
               reject: ["Up in the Air 2009 1080p BluRay", "Upgrade 2018 1080p", "Up 2 2009"])
        expect(alien, accept: ["Alien.1979.Directors.Cut.1080p.BluRay", "Alien (1979) 1080p BrRip x264 - YIFY"],
               reject: ["Aliens (1986) 1080p BrRip x264 - YIFY", "Alien.Romulus.2024.1080p", "Alien 3 1992 1080p", "Alien.Covenant.2017.1080p"])
        expect(aliens, accept: ["Aliens.1986.Special.Edition.1080p"].map { $0.replacingOccurrences(of: ".Special.Edition", with: "") } + ["Aliens (1986) 1080p BrRip x264 - YIFY"],
               reject: ["Alien (1979) 1080p", "Aliens vs Predator Requiem 2007"])
        expect(dune2021,
               accept: ["Dune (2021) [1080p] [WEBRip]", "Dune.2021.1080p.BluRay.REMUX.AVC", "Dune Part One 2021 720p BluRay x264", "Dune.Part.One.2021.1080p.UHD.BluRay"],
               reject: ["Dune (1984) 1080p BrRip x264 - YIFY", "Dune.Part.Two.2024.2160p", "Dune 2000 Miniseries", "Dune Prophecy S01E01 2024"])
        expect(dune1984,
               accept: ["Dune (1984) 1080p BrRip x264 - YIFY", "Dune.1984.Extended.1080p.BluRay.AC3.x264-ETRG", "Dune 1984 RM4k Koch 1080p BluRay"],
               reject: ["Dune (2021) [1080p] [WEBRip]", "Dune.2021.1080p", "Dune Extended Edition - Sci-Fi 1984 Eng Rus"])
        expect(halloween2018, accept: ["Halloween.2018.1080p.BluRay.H264.AAC", "Halloween.2018.V2.1080p.WEB-DL.H264.AC3-EVO[EtHD]"],
               reject: ["Goosebumps 2 Haunted Halloween 2018 1080p BluRay", "Halloween.Horror.Tales.2018.1080p", "Halloween (1978) 1080p",
                        "Halloween Kills 2021 1080p", "Halloween.2007.1080p", "The.Legend.of.Halloween.Jack.2018.HDRip"])
        expect(halloween1978, accept: ["Halloween (1978) 1080p BrRip x264 - YIFY", "Halloween.1978.REMASTERED.1080p.BluRay"],
               reject: ["Halloween.2018.1080p.BluRay.H264.AAC", "Halloween 2007 1080p", "Halloween II 1981 1080p"])
        expect(halloween2007, accept: ["Halloween.2007.Unrated.Directors.Cut.1080p.BluRay"], reject: ["Halloween.2018.1080p", "Halloween (1978)"])
        expect(amelie, accept: ["Amelie [AmÃ©lie Poulain].2001.BRRip.x264.AAC[5.1]-VLiS", "Amélie (2001) 1080p", "Amelie.2002.1080p"],
               reject: ["Amelie.Poulain.2001.1080p"])

        // Every fixture: count kept releases and check none of another film slips in.
        do {
            func kept(_ file: String, _ movie: Movie) -> [IndexedRelease] {
                let data = loadFixture(file)
                let releases = file.hasPrefix("kn_") ? (KnabenClient.releases(fromJSON: data) ?? []) : PirateBayClient.releases(fromJSON: data)
                let result = ReleaseMatch.movieReleases(releases, of: movie)
                return result
            }
            let cases: [(String, Movie, Int)] = [
                ("tpb_q_interstellar_2014.json", interstellar, 20), ("kn_interstellar_2014.json", interstellar, 30),
                ("tpb_q_it_2017.json", it2017, 4), ("kn_it_2017.json", it2017, 4),
                ("tpb_q_us_2019.json", us, 5), ("kn_us_2019.json", us, 3),
                ("tpb_q_dune_2021.json", dune2021, 20), ("kn_dune_2021.json", dune2021, 20),
                ("tpb_q_dune_1984.json", dune1984, 8), ("kn_dune_1984.json", dune1984, 8),
                ("tpb_q_halloween_2018.json", halloween2018, 3), ("kn_halloween_2018.json", halloween2018, 2),
                ("tpb_q_halloween_1978.json", halloween1978, 3), ("kn_halloween_1978.json", halloween1978, 3),
                ("tpb_q_alien_1979.json", alien, 3), ("kn_alien_1979.json", alien, 3),
                ("tpb_q_aliens_1986.json", aliens, 3), ("tpb_q_her_2013.json", her, 2), ("tpb_q_up_2009.json", up, 2),
                ("tpb_q_halloween_2007.json", halloween2007, 2),
            ]
            for (file, movie, minimum) in cases {
                let result = kept(file, movie)
                check(result.count >= minimum, "\(file): kept \(result.count) < \(minimum)")
                for release in result {
                    // Independent oracle: the name, cleaned, starts with the title and
                    // names one of the years before any other year.
                    let tokens = ReleaseMatch.words(ReleaseMatch.cleaned(release.name))
                    let firstYear = tokens.compactMap { ReleaseMatch.year($0) }.first
                    check(firstYear.map { movie.years.contains($0) } ?? (release.imdb == movie.imdbId),
                          "\(file): '\(release.name)' first year \(String(describing: firstYear))")
                    check(!ReleaseName.isLikelyUnplayable(fileName: nil, title: release.name), "unplayable kept: \(release.name)")
                }
            }
            // Disc images / BD structures are dropped even when the name matches.
            let iso = IndexedRelease(name: "Interstellar.2014.COMPLETE.UHD.BLURAY-TERMiNAL", infoHash: String(repeating: "a", count: 40),
                                     seeders: 50, peers: 1, bytes: nil, source: "TPB")
            let isoFile = IndexedRelease(name: "Interstellar 2014 1080p BluRay.iso", infoHash: String(repeating: "b", count: 40),
                                         seeders: 50, peers: 1, bytes: nil, source: "TPB")
            check(ReleaseMatch.movieReleases([iso, isoFile], of: interstellar).isEmpty, "disc structure / iso dropped")
        }
    }

    func testEpisodeMatching() {
        let breakingBad = identity("tt0903747", search: "breaking_bad")
        let office = identity("tt0386676", search: "the_office")
        let darkMatter = identity("tt19231492", search: "dark_matter")
        let doctorWho = identity("tt0436992", search: "doctor_who")

        check(!mobland.isAmbiguous && mobland.year == 2025, "MobLand identity \(mobland)")
        check(!breakingBad.isAmbiguous && breakingBad.country == "US", "Breaking Bad identity \(breakingBad)")
        check(office.isAmbiguous && office.country == "US" && office.year == 2005, "The Office identity \(office)")
        check(darkMatter.isAmbiguous && darkMatter.year == 2024 && darkMatter.country == nil, "Dark Matter identity \(darkMatter)")
        check(doctorWho.isAmbiguous && doctorWho.country == "GB", "Doctor Who identity \(doctorWho)")
        check(ReleaseMatch.showIdentity(tvmaze: ["name": "X"], akas: [], searchResults: nil).isAmbiguous, "unknown search → ambiguous")
        check(!ReleaseMatch.englishAkas(json("tvm_akas_tt31510819.json") as! [[String: Any]]).contains("Gengsztervilág"), "foreign akas left out")

        expectEpisode(mobland, 2, 7,
                      accept: ["MobLand S02E07 Ace of Spades 1080p AMZN WEB-DL DDP5 1 H 264-RAWR", "MobLand.S02E07.1080p.WEBRip.10Bit.DDP5.1.x265-NeoNoir",
                               "MobLand (2025) S02E07 720p hevc x265 [WD-13].mkv"],
                      reject: ["MobLand S02E06 A Different Corner XviD-AFG", "MobLand S02 1080p", "MobLand S02E07E08 1080p", "MobLand (2024) S02E07 720p",
                               "MobLand S02E07-E10 1080p", "Mobland Holland S02E07"])
        do {
            let disc = IndexedRelease(name: "MobLand.S02E07.COMPLETE.BLURAY-GRP", infoHash: String(repeating: "c", count: 40), seeders: 9, peers: 0, bytes: nil, source: "TPB")
            let ok = IndexedRelease(name: "MobLand.S02E07.1080p.WEB.H264-GRP", infoHash: String(repeating: "d", count: 40), seeders: 9, peers: 0, bytes: nil, source: "TPB")
            check(ReleaseMatch.episodeReleases([disc, ok], season: 2, episode: 7, of: mobland) == [ok], "episode disc structure dropped")
        }
        expectEpisode(breakingBad, 3, 5,
                      accept: ["Breaking Bad S03E05 Mas 2160p NF WEB-DL DDP5 1 H 265-XEBEC", "Breaking.Bad.S03E05.720p.HDTV.x264-CTU",
                               "Breaking Bad.S03E05.Subtitulado.Esp.SC.avi", "Breaking.Bad.3x05.720p"],
                      reject: ["Breaking.Bad.S03E05-S03E13.HDTV.SWESUB.REPACK", "Breaking Brad S03E05 720p", "Breaking Bad S03E06 720p",
                               "Breaking Bad Original Minisodes S03E05", "Talking Bad S03E05", "Breaking Bad UK S03E05 720p", "BB S03E05 720p"])
        expectEpisode(office, 2, 1,
                      accept: ["The Office US S02E01 The Dundies 1080p Extended Cut AMZN WEB-DL DDP5 1 H 26", "The.Office.US.S02E01.The.Dundies.720p.HEVC.x265-MeGusta",
                               "The.Office.2005.S02E01.720p", "Office US S02E01 1080p"],
                      reject: ["The Office Movers S02E01 Mans Are Moving Different 1080p AMZN WEB-DL DDP5 1", "The.Office.Movers.S02E01.1080p.WEB.H264-CBFM",
                               "The.Office.US.S02E01-E11.SWESUB.DVDRip.XviD-aNdY", "The Office S02E01 720p", "The.Office.UK.S02E01.720p", "The Office 2001 S02E01"])
        expectEpisode(darkMatter, 2, 5,
                      accept: ["Dark Matter 2024 S02E05 Love and Be Loved 1080p HEVC x265-MeGusta", "Dark.Matter.2024.S02E05.1080p.WEBRip.10Bit.DDP5.1.x265-NeoNoir"],
                      reject: ["Dark Matter S02E05 1080p WEBRip 10Bit DDP5 1 HEVC-d3g", "Dark.Matter.S02E05.We.Voted.Not.to.Space.You.720p.WEB-DL",
                               "Dark S02E05 720p WEBRip x264-MATTER", "Dark Matter 2015 S02E05 720p", "Dark.Matter.S02E05.WEB-DL.x264-FUM[ettv]"])
        expectEpisode(doctorWho, 1, 1,
                      accept: ["Doctor.Who.2005.S01E01.Rose.720p", "Doctor Who (2005) S01E01 1080p"],
                      reject: ["Doctor.Who.S01E01.720p", "Doctor Who 2023 S01E01 1080p", "Doctor Who 1963 S01E01"])
        let svu = ReleaseMatch.ShowIdentity(titles: ["Law & Order: Special Victims Unit"], year: 1999, country: "US", isAmbiguous: false)
        expectEpisode(svu, 25, 1, accept: ["Law.and.Order.SVU.S25E01.1080p", "Law & Order Special Victims Unit S25E01 720p", "Law.And.Order.Special.Victims.Unit.S25E01"],
                      reject: ["Law.and.Order.S25E01.1080p", "Law and Order Organized Crime S25E01"])
        expectEpisode(shogun, 1, 10, accept: ["Shgun 2024 S01E10 1080p", "Shogun.2024.S01E10.2160p"], reject: ["Shogun S01E10 1080p", "Shogun 1980 S01E10"])

        do {
            for (file, show, season, episode, minimum) in [
                ("tpb_q_mobland_s02e07.json", mobland, 2, 7, 8), ("kn_mobland_s02e07.json", mobland, 2, 7, 12),
                ("tpb_q_breaking_bad_s03e05.json", breakingBad, 3, 5, 6), ("kn_breaking_bad_s03e05.json", breakingBad, 3, 5, 2),
                ("tpb_q_the_office_s02e01.json", office, 2, 1, 4), ("kn_the_office_s02e01.json", office, 2, 1, 1),
                ("tpb_q_dark_matter_s02e05.json", darkMatter, 2, 5, 5), ("kn_dark_matter_s02e05.json", darkMatter, 2, 5, 8),
            ] as [(String, ReleaseMatch.ShowIdentity, Int, Int, Int)] {
                let data = loadFixture(file)
                let releases = file.hasPrefix("kn_") ? (KnabenClient.releases(fromJSON: data) ?? []) : PirateBayClient.releases(fromJSON: data)
                let kept = ReleaseMatch.episodeReleases(releases, season: season, episode: episode, of: show)
                check(kept.count >= minimum, "\(file): kept \(kept.count) < \(minimum)")
                for release in kept {
                    check(ReleaseName.episodeScope(of: release.name, season: season, episode: episode) == .requestedEpisode, "\(file): pack kept \(release.name)")
                    check(!release.name.lowercased().contains("movers"), "\(file): The Office Movers kept")
                }
            }
        }
    }

    func testTop100GroupingAndOrdering() {
        do {
            check(zip(movieGroups, movieGroups.dropFirst()).allSatisfy { $0.seeders >= $1.seeders }, "movie groups ranked by seeders")
            check(zip(showGroups, showGroups.dropFirst()).allSatisfy { $0.seeders >= $1.seeders }, "show groups ranked by seeders")
            check(Set(movieGroups.map(\.key)).count == movieGroups.count, "group keys unique")
            let odyssey = movieGroups.first { $0.key == "m:odyssey|2026" }
            check(movieGroups.first?.key == "m:odyssey|2026", "The Odyssey (2026) leads the movie top: \(movieGroups.prefix(3).map(\.key))")
            check((odyssey?.entries.count ?? 0) >= 5, "The Odyssey releases grouped: \(odyssey?.entries.count ?? 0)")
            check(odyssey?.imdbIds.first == "tt33764258", "most frequent imdb first")
            let total = Dictionary(grouping: IndexedRelease.deduplicated(movieTop), by: \.infoHash).count
            check(odyssey.map { $0.seeders == IndexedRelease.deduplicated(movieTop).filter { r in odyssey!.entries.contains { $0.name == r.name } }.map(\.seeders).reduce(0, +) } ?? false,
                  "group seeders = sum of its distinct torrents (\(total) torrents)")
            check(!movieGroups.contains { $0.key.contains("kurosawa") }, "box sets without year or imdb dropped")
            check(ReleaseMatch.movieTitleCandidates("Wonder.Woman.1984.2020.1080p").map { "\($0.title)|\($0.year)" } == ["wonder woman|1984", "wonder woman 1984|2020"], "WW84 readings")
            check(ReleaseMatch.movieTitleCandidates("1917.2019.1080p").first.map { "\($0.title)|\($0.year)" } == "1917|2019", "1917 reading")
            check(ReleaseMatch.movieTitleCandidates("Blade.Runner.2049.2017.1080p").first.map { "\($0.title)|\($0.year)" } == "blade runner 2049|2017", "BR2049 reading")
            check(ReleaseMatch.movieTitleCandidates("Interstellar IMAX 2014 1080p").first.map { "\($0.title)|\($0.year)" } == "interstellar|2014", "edition dropped")
            check(ReleaseMatch.movieTitleCandidates("Akira Kurosawa Boxset").isEmpty, "no year → no reading")
            let mobGroup = showGroups.first { $0.key == "s:mobland" }
            check(mobGroup != nil && (mobGroup?.entries.count ?? 0) >= 2, "MobLand episodes grouped")
            check(ReleaseMatch.showPart(of: "The Sopranos: The Complete Series (Season 1,2,3,4,5&6) + Extras")?.words == ["sopranos"], "series pack show part")
            check(ReleaseMatch.showPart(of: "Its.Always.Sunny.in.Philadelphia.S01.WEB-DL.AAC2.0.H264-BTN")?.words.joined() == "itsalwayssunnyinphiladelphia", "season pack show part")
            check(ReleaseMatch.showPart(of: "Top Gear   (BBC - Seasons 1 to 17 - Complete)") == nil, "no marker outside brackets → nil")
            check(ReleaseMatch.showPart(of: "Star Trek The Next Generation Season 1, 2, 3, 4, 5, 6 & 7 Deluxe")?.words.joined() == "startrekthenextgeneration", "TNG show part")
        }
    }

    func testCinemetaValidationOfStubsAndWrongIds() {
        do {
            let stub = (json("cm_meta_movie_tt4288316.json") as! [String: Any])["meta"] as! [String: Any]
            let real = (json("cm_meta_movie_tt0816692.json") as! [String: Any])["meta"] as! [String: Any]
            let amelieMeta = (json("cm_meta_movie_tt0211915.json") as! [String: Any])["meta"] as! [String: Any]
            let yify = Top100Group(key: "m:interstellar|2014", readings: [.init(title: "interstellar", year: 2014)],
                                   entries: [.init(name: "Interstellar (2014) (2014) 1080p BrRip x264 - YIFY", imdb: "tt4288316")], seeders: 1, firstIndex: 0)
            check(!CinemetaMatching.movieMetaMatches(stub, group: yify), "stub meta tt4288316 rejected")
            check(CinemetaMatching.movieMetaMatches(real, group: yify), "real Interstellar accepted for the YIFY group")
            let searchMetas = (json("cm_search_movie_interstellar.json") as! [String: Any])["metas"] as! [[String: Any]]
            check(CinemetaMatching.movieSearchMatch(searchMetas, title: "interstellar", year: 2014).flatMap { $0["id"] as? String } == "tt0816692", "search → tt0816692")
            check(CinemetaMatching.movieSearchMatch(searchMetas, title: "interstellar", year: 2015) == nil, "search wrong year → nil")
            let amelieGroup = Top100Group(key: "m:amelie|2001", readings: [.init(title: "amelie", year: 2001)],
                                          entries: [.init(name: "Amelie [AmÃ©lie Poulain].2001.BRRip.x264.AAC[5.1]-VLiS", imdb: "tt0211915")], seeders: 1, firstIndex: 0)
            check(CinemetaMatching.movieMetaMatches(amelieMeta, group: amelieGroup), "Amélie 2001 release vs Cinemeta 2002 under its own id")
            let homeAlone: [String: Any] = ["id": "tt0099785", "name": "Home Alone", "releaseInfo": "1990", "poster": "x"]
            let boxSet = Top100Group(key: "x", readings: [], entries: [.init(name: "Home Alone 1, 2, 3, 4, 5 - Family Comedy 1990-2012 Eng Subs [H24", imdb: "tt0099785")], seeders: 1, firstIndex: 0)
            check(!CinemetaMatching.movieMetaMatches(homeAlone, group: boxSet), "box set not the film")
            let mando: [String: Any] = ["id": "tt30825738", "name": "Star Wars: The Mandalorian and Grogu", "releaseInfo": "2026", "poster": "x"]
            let mandoGroup = Top100Group(key: "m:mandalorianandgrogu|2026", readings: [], entries: [.init(name: "The Mandalorian and Grogu (2026) [1080p] [WEBRip] [5.1]", imdb: "tt30825738")], seeders: 1, firstIndex: 0)
            check(CinemetaMatching.movieMetaMatches(mando, group: mandoGroup), "subtitle alone under its own id")
            var mandoOther = mandoGroup; mandoOther.entries[0].imdb = nil
            check(!CinemetaMatching.movieMetaMatches(mando, group: mandoOther), "subtitle alone needs the index's id")
            let lotr: [String: Any] = ["id": "tt0120737", "name": "The Lord of the Rings: The Fellowship of the Ring", "releaseInfo": "2001", "poster": "x"]
            let lotrGroup = Top100Group(key: "x", readings: [], entries: [.init(name: "Lord.of.the.Rings.Fellowship.of.Ring.2001.EXTENDED.1080p.BluRay.", imdb: "tt0120737")], seeders: 1, firstIndex: 0)
            check(CinemetaMatching.movieMetaMatches(lotr, group: lotrGroup), "articles dropped under its own id")
            let hope: [String: Any] = ["id": "tt27369017", "name": "Hope", "releaseInfo": "2026", "poster": "x"]
            let hopeu = Top100Group(key: "x", readings: [], entries: [.init(name: "Hopeu.2026.1080p.AMZN.WEB-DL", imdb: "tt27369017")], seeders: 1, firstIndex: 0)
            check(!CinemetaMatching.movieMetaMatches(hope, group: hopeu), "Hopeu is not Hope")
            let dune2: [String: Any] = ["id": "tt1160419", "name": "Dune", "releaseInfo": "2021", "poster": "x"]
            let dunePartTwo = Top100Group(key: "x", readings: [], entries: [.init(name: "Dune.Part.Two.2024.2160p", imdb: "tt1160419")], seeders: 1, firstIndex: 0)
            check(!CinemetaMatching.movieMetaMatches(dune2, group: dunePartTwo), "sequel filed under the first film's id")
            let daily: [String: Any] = ["id": "tt0115147", "name": "The Daily Show", "releaseInfo": "1996–", "poster": "x"]
            let dailyGroup = Top100Group(key: "i:tt0115147", readings: [], entries: [.init(name: "The Daily Show 2026 03 31 Julio Torres 480p x264-mSD", imdb: "tt0115147")], seeders: 1, firstIndex: 0)
            check(CinemetaMatching.showMetaMatches(daily, group: dailyGroup), "daily show without marker under its own id")
            check(Top100Ranking.showGroups([IndexedRelease(name: "The Bear (2022) S05E01 720p", infoHash: String(repeating: "e", count: 40), seeders: 1, peers: 0, bytes: nil, source: "TPB")]).first?.readings.first?.title == "the bear", "show reading keeps its The")
            let seriesAsMovie = (try! JSONSerialization.jsonObject(with: "{\"id\":\"tt31510819\",\"type\":\"movie\",\"name\":\"MobLand\",\"releaseInfo\":\"2025–\",\"poster\":\"x\"}".data(using: .utf8)!)) as! [String: Any]
            let mobMovie = Top100Group(key: "m:mobland|2025", readings: [.init(title: "mobland", year: 2025)], entries: [.init(name: "MobLand 2025 1080p", imdb: "tt31510819")], seeders: 1, firstIndex: 0)
            check(!CinemetaMatching.movieMetaMatches(seriesAsMovie, group: mobMovie), "series id served as movie rejected")
            let darkSearch = (json("cm_search_series_dark_matter.json") as! [String: Any])["metas"] as! [[String: Any]]
            check(CinemetaMatching.showSearchMatch(darkSearch, title: "dark matter", year: 2024).flatMap { $0["id"] as? String } == "tt19231492", "series search with year")
            check(CinemetaMatching.showSearchMatch(darkSearch, title: "dark matter", year: 2015).flatMap { $0["id"] as? String } == "tt4159076", "series search other year")
        }
    }

    func testTop100ResolutionAgainstRecordedCinemeta() {
        do {
            let movies = resolveTop(.movie, movieGroups)
            let shows = resolveTop(.series, showGroups)
            let movieIds = movies.compactMap { $0.meta["id"] as? String }
            let showIds = shows.compactMap { $0.meta["id"] as? String }
            check(Set(movieIds).count == movieIds.count && Set(showIds).count == showIds.count, "Top 100 deduped by imdb")
            check(zip(movies, movies.dropFirst()).allSatisfy { $0.seeders >= $1.seeders }, "Top 100 movies ranked")
            check(movies.count >= 70, "Top 100 movies resolved: \(movies.count)")
            check(shows.count >= 40, "Top 100 shows resolved: \(shows.count)")
            check(movieIds.first == "tt33764258", "The Odyssey (2026) first: \(movieIds.prefix(3))")
            check(!movieIds.contains("tt4288316") && !movieIds.contains("tt0118414"), "wrong / stub ids never listed")
            check(movies.allSatisfy { CinemetaMatching.isComplete($0.meta) }, "every title has a poster")
            check(shows.allSatisfy { ($0.meta["type"] as? String) != "movie" }, "shows are series")
            check(showIds.contains("tt31510819"), "MobLand among the shows")
            // Genre filter (client-side, on the ranked list).
            let sciFi = Top100Resolver.filter(movies.map(\.meta), genre: "Science Fiction")
            check(!sciFi.isEmpty && sciFi.allSatisfy { ($0["genres"] as? [String] ?? []).contains("Sci-Fi") }, "Science Fiction → Sci-Fi \(sciFi.count)")
            let ids = movies.map { $0.meta["id"] as? String ?? "" }
            let filteredIds = sciFi.map { $0["id"] as? String ?? "" }
            check(filteredIds == ids.filter { filteredIds.contains($0) }, "genre filter keeps the ranking order")
            check(Top100Resolver.filter(movies.map(\.meta), genre: "Horror").count == movies.filter { ($0.meta["genres"] as? [String] ?? []).contains("Horror") }.count, "Horror")
            check(Top100Resolver.filter(movies.map(\.meta), genre: "Holiday").isEmpty, "unknown genre → empty")
            // Bounded concurrency + deadline: a fetcher that never answers.
            let stuck = Top100Resolver(kind: .movie, maxConcurrent: 3, fetchMeta: { _, _, _ in }, search: { _, _, _ in })
            let semaphore = DispatchSemaphore(value: 0)
            let started = Date()
            var stuckCount = -1
            stuck.resolve(movieGroups.map { var group = $0; group.key += "#stuck"; return group }, limit: 100, deadline: 0.5) { resolved, complete in stuckCount = complete ? -2 : resolved.count; semaphore.signal() }
            semaphore.wait()
            check(stuckCount == 0 && Date().timeIntervalSince(started) < 2, "deadline delivers when sources hang")
        }
    }

    func testPacksEditionsNamesakesOverflowAndFlakyCinemeta() {
        do {
            let godfather = Movie(titles: ["The Godfather"], years: [1972], imdbId: "tt0068646")
            let bttf = Movie(titles: ["Back to the Future"], years: [1985], imdbId: "tt0088763")
            let toyStory = Movie(titles: ["Toy Story"], years: [1995], imdbId: "tt0114709")
            let homeAlone = Movie(titles: ["Home Alone"], years: [1990], imdbId: "tt0099785")
            let johnWick = Movie(titles: ["John Wick"], years: [2014], imdbId: "tt2911666")
            let terminator = Movie(titles: ["The Terminator"], years: [1984], imdbId: "tt0088247")
            let matrix = Movie(titles: ["The Matrix"], years: [1999], imdbId: "tt0133093")
            let rocky = Movie(titles: ["Rocky"], years: [1976], imdbId: "tt0075148")
            let odyssey2001 = Movie(titles: ["2001: A Space Odyssey"], years: [1968], imdbId: "tt0062622")
            let thing = Movie(titles: ["The Thing"], years: [1982], imdbId: "tt0084787")
            let bladeRunner = Movie(titles: ["Blade Runner"], years: [1982], imdbId: "tt0083658")
            let parasite = Movie(titles: ["Parasite"], years: [2019], imdbId: "tt6751668")
            let hope = Movie(titles: ["Hope", "Hopeu"], years: [2026], imdbId: "tt27369017")
            let hunger = Movie(titles: ["The Hunger Games"], years: [2012], imdbId: "tt1392170")
            // Packs and bonus discs: never the film alone.
            expect(godfather, accept: ["The Godfather 1972 1080p BluRay x264", "The Godfather Part I 1972 1080p", "The.Godfather.1972.REMASTERED.2160p"],
                   reject: ["The Godfather (Trilogy) (1972-1990) 1080p", "The Godfather Part II 1974 1080p", "The Godfather Trilogy 1972 1080p",
                            "The Godfather 1972 Collection 1080p"])
            expect(bttf, accept: ["Back to the Future 1985 1080p"], reject: ["Back.To.The.Future.1985-1990.Trilogy.1080p"])
            expect(toyStory, accept: ["Toy Story (1995) 1080p"], reject: ["Toy Story (1995 - 2019) Quadrilogy 1080p", "Toy Story 1995 4 Movies Collection"])
            expect(homeAlone, accept: ["Home Alone 1990 720p"], reject: ["Home Alone 1990 2 1992 3 1997 4 2002 5 2012"])
            expect(johnWick, accept: ["John Wick 2014 1080p"], reject: ["John Wick 2014 Chapter 2 2017 3 Parabellum 2019"])
            expect(terminator, accept: ["The Terminator 1984 1080p"], reject: ["Terminator 1984-2019 + The Sarah Connor Chronicles"])
            expect(matrix, accept: ["The Matrix 1999 2160p"], reject: ["The Matrix 1999 Reloaded 2003 Revolutions 2003"])
            expect(rocky, accept: ["Rocky.1976.1080p"], reject: ["Rocky.1976-2006.XviD.AC3.13CD", "Rocky 1976 DVDRip CD1"])
            expect(odyssey2001, accept: ["2001 A Space Odyssey 1968 1080p"],
                   reject: ["2001.A.Space.Odyssey.1968.EXTRAS.iNTERNAL.DVDRip", "2001: A Space Odyssey (1968) and 2010: Odyssey Two (1984)"])
            expect(thing, accept: ["The Thing 1982 1080p"], reject: ["The Thing 1982/The Thing 2011 1080p", "The Thing 1982 Box Set 1080p"])
            expect(alien, accept: ["Alien DC (1979) 1080p BrRip x264 - YIFY", "Alien (1979) DC + Featurettes (2160p BluRay x265)", "Alien.1979.swesub.xvid.saga",
                                   "Alien Criterion Collection 1979 1080p"],
                   reject: ["Alien 1979 Bonus Disc DVDRip", "Alien 1979 Making Of 1080p"])
            expect(aliens, accept: ["Aliens Special Edition 1986.720p.BrRip.x264.YIFY", "Aliens DC (1986) 1080p BrRip x264 - YIFY"], reject: [])
            expect(bladeRunner, accept: ["Blade Runner Final Cut 1982 2160p", "Blade.Runner.1982.Open.Matte.1080p"], reject: ["Blade Runner 2049 2017 1080p"])
            expect(parasite, accept: ["Parasite.aka.Gisaengchung.2019.1080p", "Parasite Korean 2019 1080p"], reject: ["Parasite Korean French 2019"])
            expect(hope, accept: ["Hope.Hopeu.2026.1080p.WEB", "Hope 2026 1080p"], reject: ["Hope Floats 2026"])
            expect(it2017, accept: ["IT.Chapter.One.2017.2160p.MA.WEB-DL", "It Part 1 2017 1080p"], reject: ["It Chapter Two 2017", "It Part II 2017"])
            check(!accepts(hunger, "The Hunger Games 4 Film Complete Collection 1080p", imdb: "tt1392170"), "4-film collection under the film's id")
            check(accepts(interstellar, "Interstellar 2014 Movies 720p BluRay x264 ESubs"), "'2014 Movies' is no pack")
            // Other versions: dropped from the streamable releases, the film still matches.
            let other = ["Up (2009) 3D HSBS 1080p BluRay", "Dune 2021 1080p Rifftrax 6ch x265 HEVC", "Dune (1984) Alternative Edition Redux [fanedit]",
                         "Dune 2021 Half-SBS 1080p"]
            for name in other {
                let movie = name.hasPrefix("Up") ? up : (name.contains("1984") ? dune1984 : dune2021)
                let release = IndexedRelease(name: name, infoHash: String(repeating: "e", count: 40), seeders: 9, peers: 0, bytes: nil, source: "TPB")
                check(accepts(movie, name) && ReleaseMatch.movieReleases([release], of: movie).isEmpty, "other version dropped: \(name)")
            }
            let stepUp = Movie(titles: ["Step Up 3D"], years: [2010], imdbId: "tt1193631")
            let stepUpRelease = IndexedRelease(name: "Step Up 3D 2010 1080p BluRay", infoHash: String(repeating: "f", count: 40), seeders: 9, peers: 0, bytes: nil, source: "TPB")
            check(ReleaseMatch.movieReleases([stepUpRelease], of: stepUp).count == 1, "a title's own '3D' is no 3D version")
            // Namesakes: a release filed under another film of the same title and year.
            var odyssey = Movie(titles: ["The Odyssey"], years: [2026], imdbId: "tt33764258")
            odyssey.namesakeIds = ["tt41605854", "tt40188305"]
            check(!accepts(odyssey, "The Odyssey 2026 (NOT The Chris Nolan FILM) 1080p BONE", imdb: "tt41605854"), "namesake's release vetoed")
            check(accepts(odyssey, "The Odyssey 2026 1080p WEB", imdb: "tt33764258") && accepts(odyssey, "The Odyssey 2026 1080p WEB"), "own / unknown id kept")
            let nolan = Movie(titles: ["The Odyssey"], years: [2026], imdbId: "tt33764258")
            for name in ["The.Odyssey.2026.720p.TUBI.WEB-DL.AAC2.0-NOtLAN (NOT The Chris Nolan FILM)", "The Odyssey 2026 NOT The Chris Nolan FILM 1080p WEB-DL HEVC x265 5 1-BONE",
                         "The Odyssey 2026 not the 2026 blockbuster movie 1080p"] {
                check(!accepts(nolan, name), "says it is another film: \(name)")
            }
            check(accepts(nolan, "The Odyssey 2026 Not Rated 1080p WEB"), "'Not Rated' is no other film")
            // Full UHD disc between "COMPLETE" and "BLURAY".
            check(ReleaseName.isLikelyUnplayable(fileName: nil, title: "Weapons.2025.COMPLETE.2160p.UHD.BLURAY-TDi"), "COMPLETE 2160p UHD BLURAY is a disc")
            check(!ReleaseName.isLikelyUnplayable(fileName: nil, title: "Weapons.2025.COMPLETE.2160p.UHD.BluRay.x265-GRP"), "an encode is no disc")
        }

        do {
            // The Last of Us: "us" is the title's, not a country.
            let tlou = ReleaseMatch.ShowIdentity(titles: ["The Last of Us"], year: 2023, country: "US", isAmbiguous: false)
            expectEpisode(tlou, 2, 1, accept: ["The.Last.of.Us.S02E01.1080p.WEB.H264-SuccessfulCrab", "The Last of Us S02E01 Future Days 2160p"],
                          reject: ["The Last S02E01 1080p", "The Last of Us S02E02 1080p", "The Last of Us S02 1080p"])
            let tlouGroups = Top100Ranking.showGroups([IndexedRelease(name: "The Last of Us S02E01 1080p WEB", infoHash: String(repeating: "1", count: 40),
                                                                      seeders: 900, peers: 1, bytes: nil, source: "TPB", imdb: "tt3581920")])
            check(tlouGroups.first?.readings.first?.title == "the last of us", "TLOU searched by its full name: \(tlouGroups.first?.readings ?? [])")
            // A year after SxxEyy identifies an ambiguous show, never refuses one.
            let shogun = ReleaseMatch.ShowIdentity(titles: ["Shōgun"], year: 2024, country: "US", isAmbiguous: true)
            expectEpisode(shogun, 1, 1, accept: ["Shogun.S01E01.2024.1080p.WEB", "Shogun 2024 S01E01 1080p"], reject: ["Shogun.S01E01.1080p", "Shogun.S01E01.1980.DVDRip"])
            let plainShow = ReleaseMatch.ShowIdentity(titles: ["Severance"], year: 2022, country: "US", isAmbiguous: false)
            expectEpisode(plainShow, 1, 4, accept: ["Severance S01E04 1984 1080p"], reject: [])
            // Namesake ids kept for the per-episode check.
            let silo = ReleaseMatch.showIdentity(tvmaze: ["id": 1, "name": "Silo", "premiered": "2023-05-05"], akas: [],
                                                 searchResults: [["show": ["id": 1, "name": "Silo"]], ["show": ["id": 2, "name": "Silo"]], ["show": ["id": 3, "name": "Silos"]]])
            check(silo.isAmbiguous && silo.namesakeIds == [2], "namesake ids: \(silo.namesakeIds)")
            // Animaniacs (1993-1999): the run's first year.
            check(ReleaseMatch.showPart(of: "ANIMANIACS (1993-1999): Complete Animated TV Series")?.year == 1993, "run → first year")
            check(ReleaseMatch.showPart(of: "Dark Matter 2024 US S02E05")?.year == 2024 && ReleaseMatch.showPart(of: "Dark Matter 2024 US S02E05")?.country == "US", "year + country")
            // Spin-offs / sequels filed under the parent's id.
            let wicked: [String: Any] = ["id": "tt1262426", "name": "Wicked", "releaseInfo": "2024", "poster": "x"]
            let wickedForGood = Top100Group(key: "m:wickedforgood|2025", readings: [], entries: [.init(name: "Wicked For Good (2025) 1080p WEB", imdb: "tt1262426")], seeders: 1, firstIndex: 0)
            check(!CinemetaMatching.movieMetaMatches(wicked, group: wickedForGood), "sequel under the parent's id")
            let ballerina: [String: Any] = ["id": "tt7181546", "name": "Ballerina", "releaseInfo": "2025", "poster": "x"]
            let ballerinaGroup = Top100Group(key: "m:b|2025", readings: [], entries: [.init(name: "Ballerina From the World of John Wick 2025 576p WEBRip x265-SSN", imdb: "tt7181546")], seeders: 1, firstIndex: 0)
            check(CinemetaMatching.movieMetaMatches(ballerina, group: ballerinaGroup), "long title, exact year, own id")
            let matchbox: [String: Any] = ["id": "tt28498219", "name": "Matchbox", "releaseInfo": "2026", "poster": "x"]
            let matchboxGroup = Top100Group(key: "m:m|2026", readings: [], entries: [.init(name: "Matchbox The Movie 2026 1080p WEB-DL", imdb: "tt28498219")], seeders: 1, firstIndex: 0)
            check(CinemetaMatching.movieMetaMatches(matchbox, group: matchboxGroup), "'The Movie' after the title")
            let dexter: [String: Any] = ["id": "tt0773262", "name": "Dexter", "releaseInfo": "2006–2013", "poster": "x"]
            let resurrection = Top100Group(key: "s:dexterresurrection", readings: [], entries: [.init(name: "Dexter Resurrection S02E01 1080p", imdb: "tt0773262")], seeders: 1, firstIndex: 0)
            check(!CinemetaMatching.showMetaMatches(dexter, group: resurrection), "spin-off under the parent's id")
            let twd: [String: Any] = ["id": "tt1520211", "name": "The Walking Dead", "releaseInfo": "2010–2022", "poster": "x"]
            let daryl = Top100Group(key: "s:x", readings: [], entries: [.init(name: "The Walking Dead Daryl Dixon S03E01 1080p", imdb: "tt1520211")], seeders: 1, firstIndex: 0)
            check(!CinemetaMatching.showMetaMatches(twd, group: daryl), "TWD spin-off under TWD's id")
            let dexterOwn = Top100Group(key: "s:dexter", readings: [], entries: [.init(name: "Dexter S08E01 1080p", imdb: "tt0773262")], seeders: 1, firstIndex: 0)
            check(CinemetaMatching.showMetaMatches(dexter, group: dexterOwn), "the show itself")
        }

        do {
            // Absurd seeder counts are clamped: no overflow in the sums.
            let json = """
            [{"id":"1","name":"Overflow 2020 1080p","info_hash":"\(String(repeating: "a", count: 40))","seeders":"9223372036854775807","leechers":"1","size":"1","category":"201","imdb":""},
             {"id":"2","name":"Overflow 2020 720p","info_hash":"\(String(repeating: "b", count: 40))","seeders":1e30,"leechers":"-5","size":"1","category":"201","imdb":""}]
            """.data(using: .utf8)!
            let parsed = PirateBayClient.releases(fromJSON: json)
            check(parsed.map(\.seeders) == [10_000_000, 10_000_000] && parsed[1].peers == 0, "seeders clamped: \(parsed.map(\.seeders))")
            check(Top100Ranking.movieGroups(parsed).first?.seeders == 20_000_000, "sum without overflow")
        }

        do {
            // Flaky Cinemeta: failed calls are not remembered as "unresolvable", and
            // the result says it is incomplete; a healthy retry resolves everything.
            let groups = Array(movieGroups.prefix(40)).map { group -> Top100Group in var g = group; g.key += "#flaky"; return g }
            func simulate(failing: Bool) -> (Int, Bool) {
                let lock = NSLock()
                var calls = 0
                let resolver = Top100Resolver(kind: .movie, maxConcurrent: 4, fetchMeta: { kind, id, completion in
                    lock.lock(); calls += 1; let fail = failing && calls > 10; lock.unlock()
                    if fail { return completion(nil, false) }
                    let root = cinemetaAnswer("\(kind.rawValue)_meta_\(id).json") as? [String: Any]
                    let meta = root?["meta"] as? [String: Any]
                    completion((meta?.isEmpty ?? true) ? nil : meta, true)
                }, search: { kind, query, completion in
                    lock.lock(); calls += 1; let fail = failing && calls > 10; lock.unlock()
                    if fail { return completion([], false) }
                    let root = cinemetaAnswer("\(kind.rawValue)_search_\(slug(query)).json") as? [String: Any]
                    completion(root?["metas"] as? [[String: Any]] ?? [], true)
                })
                let semaphore = DispatchSemaphore(value: 0)
                var result = (0, false)
                resolver.resolve(groups, limit: 100, deadline: 20) { resolved, complete in result = (resolved.count, complete); semaphore.signal() }
                semaphore.wait()
                return result
            }
            let flaky = simulate(failing: true)
            let healthy = simulate(failing: false)
            check(!flaky.1 && flaky.0 < healthy.0, "flaky load incomplete: \(flaky) vs \(healthy)")
            check(healthy.1 && healthy.0 >= 30, "healthy reload resolves what the flaky one missed: \(healthy)")
        }
    }
}
