//
//  SubtitleMatchingTests.swift
//  PopcornTimeTests
//
//  The subtitles made for the file played: the OpenSubtitles hash (checked against an
//  independent implementation on generated files), the rows of a moviehash answer kept for
//  the title, the per-language ranking (hash match > release match > length / frame-rate
//  consistency > the plain score) on recorded answers, and what happens when the hash
//  answer comes late (the remux serves the new file, the overlay switches).
//
//  Fixtures/Subtitles: two answers of rest.opensubtitles.org recorded on 2026-11-27, trimmed
//  to the fields read (uploader fields removed, two release names shortened):
//   - moviehash-8e245d9679d31e12-12909756.json: /search/moviebytesize-12909756/moviehash-8e245d9679d31e12
//     (the classic test file of the OpenSubtitles hash, breakdance.avi; the answer names a
//     dozen titles);
//   - imdb-0944947-s01e01-fre.json: /search/episode-1/imdbid-0944947/season-1/sublanguageid-fre.
//  No network here.
//

import XCTest
import Foundation
@testable import PopcornKit

final class SubtitleMatchingTests: CheckedTestCase {

    private func rows(_ name: String) -> [[String: Any]] {
        let data = Fixtures.data("Subtitles/\(name).json")
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-matching-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The bytes of the generated test files: a 64-bit LCG, the top byte of each state
    /// (the same generator as the independent Python implementation the hashes below
    /// come from).
    private static func pattern(size: Int, seed: UInt64) -> Data {
        var state = seed
        var bytes = [UInt8](repeating: 0, count: size)
        for index in 0..<size {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 56)
        }
        return Data(bytes)
    }

    // MARK: The hash

    func testHashOfGeneratedFilesMatchesAnIndependentImplementation() throws {
        // Expected values: an independent Python implementation (size + the little-endian
        // uint64 words of the first and last 64 KiB, mod 2^64, as subliminal's refiner),
        // run on the same files with python3 -I.
        let cases: [(name: String, data: Data, hash: String?)] = [
            ("zeros", Data(count: 131_072), "0000000000020000"),
            ("ones", Data(repeating: 0xFF, count: 131_072), "000000000001c000"),
            ("lcg-131072-1", Self.pattern(size: 131_072, seed: 1), "255dc56d1db3aab4"),
            ("lcg-200000-2", Self.pattern(size: 200_000, seed: 2), "8613c334b0174f19"),
            ("lcg-1000003-3", Self.pattern(size: 1_000_003, seed: 3), "eb6aa74f14b3c52c"),
            ("lcg-100000-4", Self.pattern(size: 100_000, seed: 4), nil),
        ]
        let folder = temporaryDirectory()
        for test in cases {
            let file = folder.appendingPathComponent("\(test.name).bin")
            try test.data.write(to: file)
            eq(OpenSubtitlesHash.hash(ofFileAt: file), test.hash, "\(test.name): the hash of the file on disk")
            let size = Int64(test.data.count)
            if size >= 2 * 65_536 {
                let tailStart = Int(OpenSubtitlesHash.tailOffset(fileSize: size))
                eq(OpenSubtitlesHash.hash(fileSize: size, head: test.data.prefix(65_536), tail: test.data.subdata(in: tailStart..<test.data.count)),
                   test.hash, "\(test.name): the hash from the two chunks in memory")
            }
        }
        eq(OpenSubtitlesHash.hash(fileSize: 200_000, head: Data(count: 65_536), tail: Data(count: 65_535)), nil,
           "a short chunk: no hash")
        let short = folder.appendingPathComponent("short.bin")
        try Data(count: 100_000).write(to: short)
        eq(OpenSubtitlesHash.readChunk(of: short, at: 65_536), nil, "fewer than 64 KiB on disk there: no chunk")
        eq(OpenSubtitlesHash.hash(ofFileAt: short, fileSize: 200_000), nil,
           "a file smaller on disk than its final size (still downloading): no hash")
    }

    func testTheClassicTestVectorAndItsSearch() {
        // breakdance.avi (12 909 756 bytes) hashes to 8e245d9679d31e12 — the reference
        // implementations' test vector; the file itself is not available here. Its
        // recorded search: the URL asked and every row echoing that hash and size.
        eq(SubtitlesManager.url(for: ["moviehash-8e245d9679d31e12", "moviebytesize-12909756"]),
           "https://rest.opensubtitles.org/search/moviebytesize-12909756/moviehash-8e245d9679d31e12",
           "the moviehash search: components in alphabetical order")
        eq(OpenSubtitlesHash.format(0x8e24_5d96_79d3_1e12), "8e245d9679d31e12", "16 lowercase hex digits")
        eq(OpenSubtitlesHash.format(0x2_0000), "0000000000020000", "zero-padded")
        let answer = SubtitlesManager.candidates(from: rows("moviehash-8e245d9679d31e12-12909756"))
        eq(answer.count, 11, "every row of the answer, not one per language")
        check(answer.allSatisfy { $0.movieHash == "8e245d9679d31e12" }, "each row says it was found by that hash")
        eq(Set(answer.compactMap(\.imdbId)).count, 6, "the hash answers for six titles")
        let sum = OpenSubtitlesHash.hash(fileSize: 12_909_756, headSum: 0x8e24_5d96_79d3_1e12 &- 12_909_756, tailSum: 0)
        eq(sum, "8e245d9679d31e12", "size + head sum + tail sum, wrapping")
    }

    // MARK: Rows of the title

    func testHashRowsAreKeptForTheTitlePlayedOnly() {
        let answer = SubtitlesManager.candidates(from: rows("moviehash-8e245d9679d31e12-12909756"))
        let breakdance = SubtitleMatching.rowsForTitle(answer, imdbId: "tt0086998")
        eq(breakdance.count, 4, "the film of the test file: its rows only")
        eq(Set(breakdance.map(\.ISO639)), ["en", "da", "id"], "in three languages")
        eq(SubtitleMatching.rowsForTitle(answer, imdbId: "tt0369702").count, 2, "another film the hash is linked to")
        eq(SubtitleMatching.rowsForTitle(answer, imdbId: "tt0111161").count, 0, "a film the hash is not linked to: nothing")
        let vikings = SubtitleMatching.rowsForTitle(answer, imdbId: nil, showImdbId: "tt2306299", season: 2, episode: 1)
        eq(vikings.map(\.releaseName), ["Vikings.S02E01.HDTV.x264-EXCELLENCE"], "an episode: by its show, season and episode")
        eq(SubtitleMatching.rowsForTitle(answer, imdbId: nil, showImdbId: "tt2306299", season: 2, episode: 2).count, 0,
           "another episode of that show: nothing")
        eq(SubtitleMatching.rowsForTitle(answer, imdbId: "tt3358048").count, 0,
           "an episode's own imdb id taken for a movie's: nothing (the row is an episode's)")
        let title = SubtitleHashLookup.Title(imdbId: "tt0086998")
        eq(title.rows(of: answer).count, 4, "the lookup's title filter")
        eq(SubtitleHashLookup.Title(media: Movie(yts: ["imdb_code": "tt0086998", "title": "Breakin'"])),
           SubtitleHashLookup.Title(imdbId: "tt0086998"), "a movie: its imdb id")
        let episode = Episode(title: "Pilot", id: "ep1", show: Show(title: "Some Show", id: "tt0944947"), episode: 1, season: 1)
        eq(SubtitleHashLookup.Title(media: episode), SubtitleHashLookup.Title(showImdbId: "tt0944947", season: 1, episode: 1),
           "an episode: its show's id, season and episode")
    }

    // MARK: The plain score is kept when nothing is known

    /// The choice before this change: one row per language, a later row replacing the kept
    /// one only with a strictly higher score; sorted by language name.
    private func todaysBest(_ rows: [[String: Any]]) -> [Subtitle] {
        var kept: [Subtitle] = []
        for row in SubtitlesManager.candidates(from: rows) {
            if let index = kept.firstIndex(where: { $0.ISO639 == row.ISO639 }) {
                if row.rating > kept[index].rating { kept[index] = row }
            } else {
                kept.append(row)
            }
        }
        return kept.sorted { $0.language < $1.language }
    }

    func testWithNothingKnownTheChoiceIsTodays() {
        for name in ["moviehash-8e245d9679d31e12-12909756", "imdb-0944947-s01e01-fre"] {
            let recorded = rows(name)
            let best = SubtitlesManager.bestSubtitles(from: recorded)
            eq(best.map(\.link), todaysBest(recorded).map(\.link), "\(name): the best row per language, as before")
            eq(best.map { $0.alternates.count + 1 }.reduce(0, +), SubtitlesManager.candidates(from: recorded).count,
               "\(name): every other row kept as an alternate")
            check(best.allSatisfy { entry in zip(entry.alternates, entry.alternates.dropFirst()).allSatisfy { $0.rating >= $1.rating } },
                  "\(name): alternates best first")
            eq(SubtitleMatching.choose(best, file: SubtitleFileContext()).map(\.link), best.map(\.link),
               "\(name): nothing known of the file — the same pick")
            eq(SubtitleMatching.choose(best, file: SubtitleFileContext(releaseNames: ["movie.mkv", "Downloads"])).map(\.link),
               best.map(\.link), "\(name): a name without any release tag — the same pick")
        }
    }

    // MARK: Release names

    func testReleaseTraits() {
        let sparks = SubtitleMatching.traits(of: "Interstellar.2014.1080p.BluRay.x264-SPARKS.mkv")
        eq(sparks.group, "sparks", "the group after the last dash")
        eq(sparks.source, "bluray", "BluRay")
        eq(sparks.resolution, "1080", "1080p")
        let web = SubtitleMatching.traits(of: "Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX")
        eq(web.source, "webdl", "WEB-DL")
        eq(web.group, "flux", "a group after WEB-DL's own dash")
        eq(SubtitleMatching.traits(of: "Show.S01E01.720p.WEB-DL").group, nil, "WEB-DL's DL is no group")
        eq(SubtitleMatching.traits(of: "Show.S01E01.1080p.WEBRip.x264").source, "webrip", "WEBRip")
        eq(SubtitleMatching.traits(of: "Game.of.Thrones.S01E01.720p.BluRay.X264-REWARD.fre.srt").group, "reward",
           "a subtitle file name: extension and language tag dropped")
        eq(SubtitleMatching.traits(of: "Game.of.Thrones.S01E01.720p.BluRay.x264.MIKY-fre.srt").group, "miky",
           "a dash before the language tag")
        eq(SubtitleMatching.traits(of: "Game.of.Thrones.101.BDRip.REWARD").group, "reward",
           "no dash: the last word after technical tags")
        eq(SubtitleMatching.traits(of: "The Shawshank Redemption").group, nil, "a bare title has no group")
        eq(SubtitleMatching.traits(of: "Game of Thrones S01E01").group, nil, "nor a title and an episode marker")
        let yts = SubtitleMatching.traits(of: "Inception (2010) [1080p] [BluRay] [5.1] [YTS.MX]")
        eq(yts.group, "yts", "YTS in brackets")
        eq(yts.resolution, "1080", "the bracketed tags still count")
        eq(SubtitleMatching.traits(of: "Inception.2010.1080p.BRrip.x264.YIFY").group, "yts", "YIFY is YTS")
        eq(SubtitleMatching.traits(of: "Aliens.1986.Directors.Cut.1080p.BluRay").editions, ["directors"], "a director's cut")
        eq(SubtitleMatching.traits(of: "Aliens.1986.REMASTERED.1080p.BluRay").editions, [], "a remaster is the plain cut")
    }

    func testReleaseMatchLevels() {
        func subtitle(_ release: String?, file: String? = nil) -> Subtitle {
            Subtitle(language: "French", link: "https://example.invalid/\(UUID())", ISO639: "fr", rating: 3e12,
                     releaseName: release, fileName: file)
        }
        let names = ["Interstellar.2014.1080p.BluRay.x264-SPARKS.mkv"]
        check(SubtitleMatching.releaseMatch(subtitle("Interstellar.2014.1080p.BluRay.x264-SPARKS"), names: names).isStrong,
              "the same release name")
        check(SubtitleMatching.releaseMatch(subtitle("Interstellar 2014 720p BluRay x264-SPARKS"), names: names).isStrong,
              "the same group and source, another resolution: the same master")
        check(SubtitleMatching.releaseMatch(subtitle(nil, file: "Interstellar.2014.1080p.BluRay.x264-SPARKS.eng.srt"), names: names).isStrong,
              "SubFileName when MovieReleaseName is missing")
        check(!SubtitleMatching.releaseMatch(subtitle("Interstellar.2014.1080p.WEB-DL.x264-SPARKS"), names: names).isStrong,
              "the same group, another source: not strong")
        check(!SubtitleMatching.releaseMatch(subtitle("Interstellar.2014.EXTENDED.1080p.BluRay.x264-SPARKS"), names: names).isStrong,
              "another cut: not strong")
        eq(SubtitleMatching.releaseMatch(subtitle("Interstellar.2014.1080p.BluRay.x264-OTHER"), names: names).points, 3,
           "another group, same source and resolution: partial")
        eq(SubtitleMatching.releaseMatch(subtitle("Interstellar.2014.EXTENDED.1080p.BluRay.x264-OTHER"), names: names).points, 0,
           "a conflicting edition takes the partial points back")
        eq(SubtitleMatching.releaseMatch(subtitle("Interstellar"), names: names), .none, "a bare title: nothing")
    }

    // MARK: Ranking on a recorded answer

    private var episodeList: [Subtitle] { SubtitlesManager.bestSubtitles(from: rows("imdb-0944947-s01e01-fre")) }

    func testTheReleasePlayedPicksItsSubtitle() {
        let list = episodeList
        eq(list.map(\.ISO639), ["fr"], "one language")
        eq(list.first?.fileId, "1952844910", "today's pick: the most downloaded (an HDTV release)")
        let reward = SubtitleFileContext(releaseNames: ["Game.of.Thrones.S01E01.720p.BluRay.x264-REWARD.mkv", "Downloads"],
                                         durationSeconds: 3_700, frameRate: 23.976)
        let picked = SubtitleMatching.choose(list, file: reward).first
        eq(picked?.fileId, "1953040591", "a REWARD BluRay file: the subtitle timed on that release")
        eq(picked?.alternates.first?.fileId, "1953690247",
           "then REWARD's 25 fps one: the same release, but its frame rate does not fit the video")
        eq(picked.map { SubtitleMatching.reason(for: $0, file: reward) }, "release match", "why, for the log")
        eq(picked.map { 1 + $0.alternates.count }, 13, "no row lost")
        let fever = SubtitleFileContext(releaseNames: ["Game.of.Thrones.S01E01.HDTV.XviD-FEVER.avi"])
        eq(SubtitleMatching.choose(list, file: fever).first?.fileId, "1952844910", "the FEVER HDTV file: its own subtitle")
        let otherWeb = SubtitleFileContext(releaseNames: ["Game.of.Thrones.S01E01.1080p.WEB-DL.DD5.1.H.264-XYZ.mkv"])
        eq(SubtitleMatching.choose(list, file: otherWeb).first?.fileId, "1952844910",
           "a release none of the rows names: the plain score decides")
    }

    func testLengthAndFrameRateDemoteRowsMadeForAnotherCut() {
        let list = episodeList
        let file = SubtitleFileContext(durationSeconds: 3_700, frameRate: 23.976)
        let ranked = SubtitleMatching.choose(list, file: file).first.map { [$0.with(alternates: [])] + $0.alternates } ?? []
        // Consistent rows by the plain score, then the inconsistent ones: a last cue at
        // 01:12:17 (another show's file) and the 25 fps rows.
        eq(ranked.compactMap(\.fileId), [
            "1952844910", "1953040591", "1956309919", "1954072180", "1953516576", "1953201161", "1953660048",
            "1956107418", "1959113979",
            "1954877622", "1953158377", "1953361455", "1953690247",
        ], "consistent rows first, each group by the plain score")
        eq(SubtitleMatching.inconsistency(of: ranked[9], file: file), "last cue at 4337 s, film 3700 s", "the reason given")
        let shortCut = SubtitleFileContext(durationSeconds: 2_400)
        eq(SubtitleMatching.choose(list, file: shortCut).first?.fileId, "1953660048",
           "a 40 min cut: every row whose last cue is past it plus 3 min loses its place (the one without a last cue stays)")
        check(SubtitleMatching.sameFrameRateFamily(23.976, 24) && SubtitleMatching.sameFrameRateFamily(25, 50)
              && !SubtitleMatching.sameFrameRateFamily(25, 23.976), "frame-rate families")
    }

    func testHashRowsWinTheirLanguage() {
        let list = episodeList
        let hashRow = Subtitle(language: "French", link: "https://example.invalid/hash.srt", ISO639: "fr",
                               rating: SubtitlesManager.score(format: "srt", hearingImpaired: true, flaggedBad: false, rating: 0, downloads: 3),
                               format: "srt", hearingImpaired: true, movieHash: "0123456789abcdef", fileId: "42")
        let picked = SubtitleMatching.choose(list, file: SubtitleFileContext(), hashRows: [hashRow]).first
        eq(picked?.fileId, "42", "a hash match beats the most downloaded, hearing-impaired or not")
        eq(picked.map { SubtitleMatching.reason(for: $0, file: SubtitleFileContext(), hashRows: [hashRow]) }, "hash match", "why")
        eq(picked?.alternates.count, 13, "the search's rows stay as alternates")
        let reward = SubtitleFileContext(releaseNames: ["Game.of.Thrones.S01E01.720p.BluRay.x264-REWARD.mkv"])
        eq(SubtitleMatching.choose(list, file: reward, hashRows: [hashRow]).first?.fileId, "42", "and a release match")

        // A hash row that is also in the imdb answer (same IDSubtitleFile, another link).
        let sameFile = Subtitle(language: "French", link: "https://example.invalid/other-token/1953516576", ISO639: "fr",
                                rating: 3e12, format: "srt", movieHash: "0123456789abcdef", fileId: "1953516576")
        let merged = SubtitleMatching.choose(list, file: SubtitleFileContext(), hashRows: [sameFile]).first
        eq(merged?.fileId, "1953516576", "the imdb row of that file wins")
        eq(merged.map { 1 + $0.alternates.count }, 13, "not listed twice")

        let unreadable = Subtitle(language: "French", link: "https://example.invalid/hash.psb", ISO639: "fr",
                                  rating: SubtitlesManager.score(format: "psb", hearingImpaired: false, flaggedBad: false, rating: 0, downloads: 0),
                                  format: "psb", movieHash: "0123456789abcdef", fileId: "43")
        eq(SubtitleMatching.choose(list, file: SubtitleFileContext(), hashRows: [unreadable]).first?.fileId, "1952844910",
           "a hash match only VLC could read does not replace a file every route converts")
        let english = Subtitle(language: "English", link: "https://example.invalid/en.srt", ISO639: "en", rating: 3e12,
                               movieHash: "0123456789abcdef")
        eq(SubtitleMatching.choose(list, file: SubtitleFileContext(), hashRows: [english]).map(\.ISO639), ["fr"],
           "a language the search did not list is not added")
    }

    // MARK: A late hash answer

    func testLateReplacementDecisions() {
        typealias R = SubtitleMatching.LateReplacement
        eq(SubtitleMatching.lateReplacement(fetchedLink: nil, chosenLink: "b", servedToPlayer: false, failed: false),
           R.takeOnNextFetch, "nothing fetched: the next fetch takes the new pick")
        eq(SubtitleMatching.lateReplacement(fetchedLink: "b", chosenLink: "b", servedToPlayer: true, failed: false),
           R.keep, "the file fetched is the pick")
        eq(SubtitleMatching.lateReplacement(fetchedLink: "a", chosenLink: "b", servedToPlayer: false, failed: false),
           R.replace(notifyPlayer: false), "fetched ahead, never requested: replaced quietly")
        eq(SubtitleMatching.lateReplacement(fetchedLink: "a", chosenLink: "b", servedToPlayer: true, failed: false),
           R.replace(notifyPlayer: true), "a player has the old one: replaced, the owner told (rebuild if on screen)")
        eq(SubtitleMatching.lateReplacement(fetchedLink: nil, chosenLink: "b", servedToPlayer: true, failed: true),
           R.replace(notifyPlayer: true), "the old one failed (an empty file served): the new pick is fetched now")

        let a = Subtitle(language: "French", link: "a", ISO639: "fr", rating: 3e12, fileId: "1")
        let b = Subtitle(language: "French", link: "b", ISO639: "fr", rating: 3e12, fileId: "2")
        let en = Subtitle(language: "English", link: "e", ISO639: "en", rating: 3e12, fileId: "3")
        eq(SubtitleMatching.replacement(for: a, in: [b, en])?.link, "b", "the overlay shows fr's old file: switch")
        eq(SubtitleMatching.replacement(for: b, in: [b, en])?.link, nil, "already the pick: nothing")
        eq(SubtitleMatching.replacement(for: en, in: [b]), nil, "a language no longer listed: nothing")
    }

    func testTheLookupWaitsForBothEndsOfTheFile() throws {
        let file = temporaryDirectory().appendingPathComponent("Breakin.1984.720p.BluRay.x264-GRP.mkv")
        try Self.pattern(size: 200_000, seed: 2).write(to: file)
        let answer = SubtitlesManager.candidates(from: rows("moviehash-8e245d9679d31e12-12909756"))
        var onDisk: (head: Bool, tail: Bool) = (false, false)
        var searched: [(hash: String, size: Int64)] = []
        let logLock = NSLock()
        var lines: [String] = []
        let lookup = SubtitleHashLookup(file: file, title: SubtitleHashLookup.Title(imdbId: "tt0086998"), fileSize: { 200_000 },
                                        isRangeOnDisk: { offset, _ in offset == 0 ? onDisk.head : onDisk.tail },
                                        search: { hash, size, completion in
                                            searched.append((hash, size))
                                            completion(answer, nil)
                                        },
                                        log: { line in logLock.withLock { lines.append(line) } })
        let delivered = expectation(description: "rows of the title")
        var matches: [Subtitle] = []
        lookup.onMatches = { matches = $0; delivered.fulfill() }

        lookup.pollNow()
        eq(searched.count, 0, "nothing on disk: no search")
        onDisk.head = true
        lookup.pollNow()
        eq(searched.count, 0, "the head only: no search yet")
        // Bounded storage: the head is gone once played; its sum was kept.
        onDisk = (false, true)
        lookup.pollNow()
        eq(searched.map(\.hash), ["8613c334b0174f19"], "both ends seen: the file's hash (the Python value)")
        eq(searched.map(\.size), [200_000], "with its size")
        wait(for: [delivered], timeout: 5)
        eq(matches.count, 4, "the rows of the title played only")
        lookup.pollNow()
        eq(searched.count, 1, "searched once")
        let summary = logLock.withLock { lines.last ?? "" }
        check(summary.hasPrefix("[Subtitles] moviehash 8613c334b0174f19 size 200000: 4 rows for this title (7 of other titles ignored)"),
              "the log line", summary)
        check(summary.contains("en → 'breakdance' (hash match)"), "the pick per language in the log", summary)
        eq(SubtitleHashLookup.knownMatches(forFile: file).count, 4, "remembered for a later player of this file (VLC)")
        let list = [Subtitle(language: "English", link: "https://example.invalid/en.srt", ISO639: "en", rating: 3.1e12)]
        eq(SubtitleHashLookup.pick(list, forFile: file).first?.movieHash, "8e245d9679d31e12",
           "VLC's next load takes the hash match")
        eq(SubtitleHashLookup.pick(list, forFile: nil).map(\.link), list.map(\.link), "no file: the list as it is")
    }

    // MARK: The remux serves the new pick

    private func writeSRT(_ text: String, to url: URL) throws {
        try Data("1\n00:00:01,000 --> 00:00:02,000\n\(text)\n".utf8).write(to: url)
    }

    private func served(_ remux: RemuxPlayback) -> String {
        var text = ""
        let fetched = expectation(description: "sub_fr.vtt")
        remux.externalSubtitleData(forKey: "fr") { data in
            text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            fetched.fulfill()
        }
        wait(for: [fetched], timeout: 5)
        return text
    }

    func testTheRemuxServesTheHashMatchedFileInstead() throws {
        let folder = temporaryDirectory()
        let aFile = folder.appendingPathComponent("a.srt"), bFile = folder.appendingPathComponent("b.srt")
        try writeSRT("from the popular file", to: aFile)
        try writeSRT("from the hash-matched file", to: bFile)
        let previous = RemuxPlayback.readsLocalSubtitleFiles
        RemuxPlayback.readsLocalSubtitleFiles = true
        defer { RemuxPlayback.readsLocalSubtitleFiles = previous }
        let a = Subtitle(language: "French", link: aFile.absoluteString, ISO639: "fr", rating: 3.11e12, format: "srt", fileId: "1")
        let b = Subtitle(language: "French", link: bFile.absoluteString, ISO639: "fr", rating: 3.0e12, format: "srt", fileId: "2")
        let hashRow = Subtitle(language: "French", link: bFile.absoluteString, ISO639: "fr", rating: 3.0e12, format: "srt",
                               movieHash: "0123456789abcdef", fileId: "2")

        // Fetched before the hash answer, then replaced.
        let remux = RemuxPlayback(localFile: folder.appendingPathComponent("Film.2020.1080p.BluRay.x264-GRP.mkv"), streamer: nil)
        remux.startsTicksOnDemand = false
        defer { remux.stop() }
        var told: [String] = []
        remux.onExternalSubtitleRetimed = { told.append($0) }
        remux.subtitles = [a.with(alternates: [b])]
        check(served(remux).contains("from the popular file"), "before the hash answer: the plain score's pick")
        remux.applyMovieHashMatches([hashRow])
        var text = ""
        let deadline = Date(timeIntervalSinceNow: 5)
        repeat {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            text = served(remux)
        } while !text.contains("hash-matched") && Date() < deadline
        check(text.contains("from the hash-matched file"), "the hash match is served instead, same URI", text)
        while remux.subtitleSync.map({ $0.generation(forKey: "fr") != 1 }) ?? false, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        if let sync = remux.subtitleSync {
            eq(sync.generation(forKey: "fr"), 1, "the automatic sync starts over on the new file")
            eq(sync.plan(forKey: "fr")?.estimates, 0, "with a fresh plan")
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        eq(told, [], "no player requested the old file: no rebuild asked")

        // The hash answer before the first fetch: the new pick is fetched directly.
        let early = RemuxPlayback(localFile: folder.appendingPathComponent("Film.2020.1080p.BluRay.x264-GRP.mkv"), streamer: nil)
        early.startsTicksOnDemand = false
        defer { early.stop() }
        early.subtitles = [a.with(alternates: [b])]
        early.applyMovieHashMatches([hashRow])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        check(served(early).contains("from the hash-matched file"), "the hash answer came first: fetched directly")
    }

    func testTheAutomaticSyncIgnoresAnOlderFilesLateRegistration() {
        let sync = SubtitleAutoSync(schedule: .quick, log: { _ in })
        let cues = [SubtitleCue(start: 1, end: 2, text: "a", settings: nil)]
        sync.register(key: "fr", language: "fr", cues: cues, generation: 1)
        sync.register(key: "fr", language: "fr", cues: cues, generation: 0)
        eq(sync.generation(forKey: "fr"), 1, "a registration of the replaced file, late, changes nothing")
        sync.register(key: "fr", language: "fr", cues: cues, generation: 2)
        eq(sync.generation(forKey: "fr"), 2, "a newer file starts over")
    }
}
