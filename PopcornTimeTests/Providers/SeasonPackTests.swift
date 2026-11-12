//
//  SeasonPackTests.swift
//  PopcornTimeTests
//
//  Season packs: which file of a multi-file torrent a stream of an episode plays
//  (`WantedFile`, PopcornKit/Models/Torrent.swift), never another episode. Pure, offline;
//  section 9 runs on Time4Popcorn's recorded House of the Dragon answer
//  (Fixtures/Packs/t4p_house_of_the_dragon.json: the fields the parser reads, magnets
//  without their trackers). (Port of the season-pack harness: 396 checks.)
//

import XCTest
import Foundation
@testable import PopcornKit

private func want(_ season: Int?, _ episode: Int?, _ file: String? = nil) -> WantedFile {
    WantedFile(season: season, episode: episode, fileName: file)!
}
private let GB: Int64 = 1_000_000_000

/// House of the Dragon S01, ten episodes, the finale the largest.
private let hotd = (1...10).map { String(format: "House.of.the.Dragon.S01E%02d.2160p.HMAX.WEB-DL.DDP5.1.Atmos.DV.MP4.x265-DVSUX.mp4", $0) }
    + ["RARBG.txt", "House.of.the.Dragon.S01.Subs/2_English.srt"]
private let hotdSizes: [Int64] = (1...10).map { Int64($0 == 10 ? 12 : 8) * GB + Int64($0) } + [100, 50_000]
private let packName = "House.of.the.Dragon.S01.2160p.HMAX.WEB-DL.DDP5.1.Atmos.DV.MP4.x265-DVSUX[rartv]"

final class SeasonPackTests: CheckedTestCase {

    func testNamesCompared() {
        check(WantedFile.comparableName("House of the Dragon S02E03 1080p MAX WEB-DL DDP5 1 x264-NTb.mkv")
              == WantedFile.comparableName("House.of.the.Dragon.S02E03.1080p.MAX.WEB-DL.DDP5.1.x264-NTb.mkv"), "spaces vs dots")
        check(WantedFile.comparableName("Show.S01E01.mp4") == WantedFile.comparableName("show.s01e01.MKV"), "video extension dropped, case")
        check(WantedFile.comparableName("Movie.DDP5.1") == "movieddp51", "no container: nothing dropped")
        check(WantedFile.comparableName("Show.S01E01.srt") != WantedFile.comparableName("Show.S01E01.mkv"), "subtitles keep their extension")
        check(WantedFile.comparableName("Pack/Sub/Show.S01E01.mkv") == "shows01e01", "last path component")
        check(WantedFile.leafName("A\\B\\c.mkv") == "c.mkv", "backslash paths")
    }

    func testWhatIsWanted() {
        check(WantedFile(season: nil, episode: nil, fileName: nil) == nil, "nothing to go by")
        check(WantedFile(season: -1, episode: -1, fileName: "  ") == nil, "Episode without numbers, blank name")
        check(WantedFile(season: 0, episode: 1) != nil, "specials (season 0)")
        check(WantedFile(season: 1, episode: 0) == nil, "episode 0 is no episode")
        check(WantedFile(season: -1, episode: 3, fileName: "a/b.mkv")?.season == nil, "half numbers dropped")
        check(WantedFile(season: -1, episode: 3, fileName: "a/b.mkv")?.fileName == "b.mkv", "leaf of the given name")
        check(WantedFile(media: Episode(episode: 3, season: 1), torrent: nil) == want(1, 3), "from an Episode")
        check(WantedFile(media: Episode(), torrent: Torrent(url: "magnet:?xt=urn:btih:ab")) == nil, "Episode without numbers, no name")
        check(WantedFile(media: Movie(), torrent: Torrent(url: "magnet:?xt=urn:btih:ab")) == nil, "a movie, no name")
        check(WantedFile(media: Movie(), torrent: Torrent(url: "m", fileName: "Film.2020.mkv"))
              == WantedFile(fileName: "Film.2020.mkv"), "a movie with a file name")
        check(want(1, 3, "x.mkv").description == "S01E03 «x.mkv»", want(1, 3, "x.mkv").description)
    }

    func testSeasonPack() {
        for e in 1...10 {
            check(want(1, e).choice(fileNames: hotd, fileSizes: hotdSizes, torrentName: packName) == .file(e - 1), "S01E\(e) by marker")
        }
        check(want(1, 11).choice(fileNames: hotd, fileSizes: hotdSizes, torrentName: packName) == .notInTorrent, "S01E11 not in the pack")
        check(want(2, 1).choice(fileNames: hotd, fileSizes: hotdSizes, torrentName: packName) == .notInTorrent, "S02E01 not in an S01 pack")
        check(want(1, 3).choice(fileNames: hotd, fileSizes: nil, torrentName: packName) == .file(2), "no sizes")
        check(want(1, 3).choice(fileNames: hotd, fileSizes: [1, 2], torrentName: packName) == .file(2), "sizes of another torrent ignored")
        // Before: the largest video file, another episode.
        check(PlaybackRouting.fileIndexToStream(names: hotd, sizes: hotdSizes, preferredIndex: nil) == 9, "the usual rule streams the finale")
    }

    func testTheSourcesFileName() {
        let spaced = ["House of the Dragon S02E03 1080p MAX WEB-DL DDP5 1 x264-NTb.mkv"]
        let dotted = (1...8).map { String(format: "House.of.the.Dragon.S02E%02d.1080p.MAX.WEB-DL.DDP5.1.x264-NTb.mkv", $0) }
        check(WantedFile(fileName: spaced[0])!.choice(fileNames: dotted) == .file(2), "the source's name, spaces for dots (no numbers)")
        let obfuscated = ["a1b2c3.mkv", "d4e5f6.mkv", "g7h8i9.mkv"]
        check(want(1, 2, "d4e5f6.mkv").choice(fileNames: obfuscated, fileSizes: [3, 2, 1]) == .file(1), "the source's name, no marker")
        check(want(1, 2, "D4E5F6.mp4").choice(fileNames: obfuscated, fileSizes: [3, 2, 1]) == .file(1), "the source's name, other container")
        check(want(2, 5, dotted[2]).choice(fileNames: dotted) == .file(4),
              "a source name naming another episode is ignored: the marker decides")
        check(want(1, 2, "d4e5f6.srt").choice(fileNames: obfuscated + ["d4e5f6.srt"], fileSizes: [3, 2, 1, 9]) == .usualRule,
              "a subtitle never; unmarked files without a pack name: the usual rule")
        check(want(1, 2, "nothing.mkv").choice(fileNames: obfuscated, fileSizes: [3, 2, 1], torrentName: "Show.S01.1080p") == .notInTorrent,
              "an unmarked pack named as one, file name not found")
        check(want(2, 2, dotted[1]).choice(fileNames: dotted, preferredIndex: 5) == .file(1), "the source's name before so=")
    }

    func testTheMagnetsSelectOnly() {
        let obfuscated = ["a1b2c3.mkv", "d4e5f6.mkv", "g7h8i9.mkv"]
        check(want(1, 4).choice(fileNames: hotd, fileSizes: hotdSizes, preferredIndex: 3) == .file(3), "so= of the episode")
        check(want(1, 4).choice(fileNames: hotd, fileSizes: hotdSizes, preferredIndex: 7) == .file(3), "so= naming another episode ignored")
        check(want(1, 4).choice(fileNames: hotd, fileSizes: hotdSizes, preferredIndex: 10) == .file(3), "so= on a text file ignored")
        check(want(1, 4).choice(fileNames: hotd, fileSizes: hotdSizes, preferredIndex: 99) == .file(3), "so= out of range ignored")
        check(want(1, 2).choice(fileNames: obfuscated, fileSizes: [3, 2, 1], preferredIndex: 2) == .file(2), "so= on an unmarked file trusted")
    }

    func testOtherMarkersDoublesSeasonsSpecials() {
        let nx = ["show.1x01.hdtv.avi", "show.1x02.hdtv.avi", "show.1x03.hdtv.avi", "show.1x10.hdtv.avi"]
        check(want(1, 3).choice(fileNames: nx, fileSizes: [1, 1, 1, 5]) == .file(2), "1x03")
        check(want(1, 1).choice(fileNames: nx, fileSizes: [1, 1, 1, 5]) == .file(0), "E01 is not E10")
        check(want(1, 10).choice(fileNames: nx, fileSizes: [9, 1, 1, 5]) == .file(3), "E10 is not E01")
        let doubles = ["Show.S02E01.mkv", "Show.S02E02E03.mkv", "Show.S02E04.mkv"]
        check(want(2, 3).choice(fileNames: doubles, fileSizes: [5, 5, 5]) == .file(1), "a double episode holding it")
        check(want(2, 2).choice(fileNames: doubles + ["Show.S02E02.mkv"], fileSizes: [5, 9, 5, 1]) == .file(3), "the single file before the double")
        let seasons = ["Show.S01E03.mkv", "Show.S02E03.mkv", "Show.S03E03.mkv"]
        check(want(2, 3).choice(fileNames: seasons, fileSizes: [1, 1, 9]) == .file(1), "the right season")
        check(want(0, 1).choice(fileNames: ["Show.S00E01.Special.mkv", "Show.S01E01.mkv"], fileSizes: [1, 9]) == .file(0), "specials")
        check(want(1, 3).choice(fileNames: ["Show.S01E03.720p.mkv", "Show.S01E03.1080p.mkv", "Show.S01E04.1080p.mkv"],
                                fileSizes: [1, 2, 3]) == .file(1), "two copies: the largest")
        check(want(1, 3).choice(fileNames: ["Show.S01E03.a.mkv", "Show.S01E03.b.mkv"], fileSizes: [7, 7]) == .file(0), "a tie: the first")
        check(want(5, 5).choice(fileNames: ["Show.Cap.505.mkv", "Show.Cap.506.mkv"], fileSizes: [1, 2]) == .file(0), "Cap.505")
        check(want(1, 3).choice(fileNames: ["Show.S01.Sub/Show.S01E03.mkv", "Show.S01.Sub/Show.S01E04.mkv"], fileSizes: [1, 2]) == .file(0),
              "names with a folder")
    }

    func testSingleEpisodeTorrentsSamplesAbsoluteNumbering() {
        let single = ["Show.S01E02.1080p.mkv", "Sample/show.s01e02.1080p.sample.mkv", "Show.S01E02.1080p.srt", "info.nfo"]
        let singleSizes: [Int64] = [2 * GB, 50_000_000, 80_000, 2_000]
        check(want(1, 2).choice(fileNames: single, fileSizes: singleSizes) == .file(0), "the episode, not its sample")
        check(want(1, 3).choice(fileNames: single, fileSizes: singleSizes) == .usualRule, "one video, another episode: as before")
        check(want(1, 2).choice(fileNames: ["Show.S01E02.mkv"], fileSizes: [1]) == .usualRule, "single-file torrent: as before")
        check(want(1, 3).choice(fileNames: ["Show.S01E01.mkv", "Show.S01E03.sample.mkv", "Show.S01E02.mkv"], fileSizes: [5, 1, 5])
              == .notInTorrent, "only the sample of the episode: not in the pack")
        let absolute = ["[Group] Show - 01 [1080p].mkv", "[Group] Show - 02 [1080p].mkv", "[Group] Show - 03 [1080p].mkv"]
        check(want(1, 2).choice(fileNames: absolute, fileSizes: [1, 2, 3], torrentName: "[Group] Show (Season 1) [1080p]") == .notInTorrent,
              "absolute numbering in a torrent named as a season: not played blindly")
        check(want(1, 2).choice(fileNames: absolute, fileSizes: [1, 2, 3], torrentName: "[Group] Show [1080p]") == .usualRule,
              "absolute numbering, no pack name: as before")
        check(want(1, 2).choice(fileNames: absolute, fileSizes: [1, 2, 3], torrentName: nil) == .usualRule, "absolute numbering, no name")
        check(want(1, 2).choice(fileNames: ["Show.S01E02.CD1.avi", "Show.S01E02.CD2.avi"], fileSizes: [7, 7]) == .file(0), "an episode in two parts")
        check(want(1, 2).choice(fileNames: ["part1.avi", "part2.avi"], fileSizes: [7, 8], torrentName: "Show.S01E02.DVDRip") == .usualRule,
              "unmarked parts of a single episode: as before")
    }

    /// "Sample" / "Trailer" in the show's own title (Trailer Park Boys), or in an episode's: not a
    /// sample unless the file is much smaller than the largest video file.
    func testSampleWordsInTitles() {
        let tpb = (1...6).map { String(format: "Trailer.Park.Boys.S01E%02d.1080p.WEB-DL.mkv", $0) } + ["Trailer.Park.Boys.S01.nfo"]
        let tpbSizes: [Int64] = [900, 910, 920, 930, 940, 1200, 1].map { $0 * 1_000_000 }
        let tpbName = "Trailer.Park.Boys.S01.1080p.WEB-DL"
        for e in 1...6 {
            check(want(1, e).choice(fileNames: tpb, fileSizes: tpbSizes, torrentName: tpbName) == .file(e - 1), "Trailer Park Boys S01E0\(e)")
        }
        check(want(1, 9).choice(fileNames: tpb, fileSizes: tpbSizes, torrentName: tpbName) == .notInTorrent, "Trailer Park Boys S01E09: not in the pack")
        check(want(1, 2).choice(fileNames: tpb, fileSizes: nil, torrentName: tpbName) == .file(1), "Trailer Park Boys without sizes")
        let titled = ["Show.S02E01.Pilot.mkv", "Show.S02E02.The.Trailer.mkv", "Show.S02E03.Finale.mkv"]
        check(want(2, 2).choice(fileNames: titled, fileSizes: [5, 5, 9], torrentName: "Show.S02") == .file(1), "an episode called The Trailer")
        let extras = ["Show.S01E01.mkv", "Show.S01E02.mkv", "Extras/Show.S01E02.Trailer.mkv"]
        check(want(1, 2).choice(fileNames: extras, fileSizes: [900, 900, 40], torrentName: "Show.S01") == .file(1), "the episode, not a small trailer of it")
        check(want(1, 3).choice(fileNames: extras + ["Sample/Show.S01E03.mkv"], fileSizes: [900, 900, 40, 30], torrentName: "Show.S01") == .notInTorrent,
              "only a sample of it (in a Sample folder): not in the pack")
    }

    /// Packs named otherwise: "S01EP02", "Season 1 E02", files numbered within a season named by
    /// their folder or the torrent ("Episode 02", "02 - Title", "102"), a range holding the episode.
    func testOtherPackNamings() {
        check(want(1, 2).choice(fileNames: ["Show.S01EP01.mkv", "Show.S01EP02.mkv", "Show.S01EP03.mkv"], fileSizes: [5, 5, 9]) == .file(1), "S01EP02")
        check(want(1, 2).choice(fileNames: ["Show.Season.1.E01.mkv", "Show.Season.1.E02.mkv", "Show.Season.1.E03.mkv"], fileSizes: [5, 5, 9]) == .file(1),
              "Season.1.E02")
        let episodeWords = ["Show - Episode 01.mkv", "Show - Episode 02.mkv", "Show - Episode 03.mkv"]
        check(want(1, 2).choice(fileNames: episodeWords, fileSizes: [5, 5, 9], torrentName: "Show Season 1") == .file(1), "Episode 02 in a Season 1 pack")
        check(want(2, 2).choice(fileNames: episodeWords, fileSizes: [5, 5, 9], torrentName: "Show Season 1") == .notInTorrent,
              "Episode 02 of a Season 1 pack is not S02E02")
        let scene = ["show.101.hdtv.avi", "show.102.hdtv.avi", "show.103.hdtv.avi"]
        check(want(1, 2).choice(fileNames: scene, fileSizes: [5, 5, 9], torrentName: "Show.S01.HDTV") == .file(1), "102 in an S01 pack")
        let leading = ["Show.S01.1080p/01 - First.mkv", "Show.S01.1080p/02 - Second.mkv", "Show.S01.1080p/03 - Third.mkv"]
        check(want(1, 2).choice(fileNames: leading, fileSizes: [5, 5, 9], torrentName: "Show.S01.1080p") == .file(1), "02 - Second under Show.S01.1080p")
        check(want(1, 2).choice(fileNames: leading, fileSizes: [5, 5, 9], torrentName: nil) == .file(1), "the folder names the season")
        let seasons = ["Show/Season 1/01.mkv", "Show/Season 1/02.mkv", "Show/Season 2/01.mkv", "Show/Season 2/02.mkv"]
        check(want(2, 1).choice(fileNames: seasons, fileSizes: [5, 5, 5, 9], torrentName: "Show.Complete") == .file(2), "Season 2/01.mkv")
        let ranges = ["Show.S01E01-E03.mkv", "Show.S01E04.mkv", "Show.S01E05.mkv"]
        check(want(1, 3).choice(fileNames: ranges, fileSizes: [9, 5, 5]) == .file(0), "a range file holding E03")
        check(want(1, 6).choice(fileNames: ranges, fileSizes: [9, 5, 5]) == .notInTorrent, "E06 in none of them")

        check(ReleaseName.singleSeason(of: "Show.S01.1080p") == 1, "S01")
        check(ReleaseName.singleSeason(of: "[Group] Show (Season 2) [1080p]") == 2, "Season 2")
        check(ReleaseName.singleSeason(of: "Show.S01-S03.1080p") == nil, "S01-S03")
        check(ReleaseName.singleSeason(of: "Show [S01-05]") == nil, "[S01-05]")
        check(ReleaseName.singleSeason(of: "Show.S01E02.1080p") == nil, "an episode")
        check(ReleaseName.singleSeason(of: "Show.2160p.x265") == nil, "no season")
        check(ReleaseName.episodeNumberInSeason("Show.1080p.x264.mkv", season: 1) == nil, "1080p, x264: no number")
        check(ReleaseName.episodeNumberInSeason("Show.720p.mkv", season: 7) == nil, "720p is not S07E20")
    }

    func testMoviesUseTheSourcesFileNameOnly() {
        let collection = ["Saga.1.2001.1080p.mkv", "Saga.2.2003.1080p.mkv", "Saga.3.2005.1080p.mkv"]
        check(WantedFile(fileName: "Saga 2 2003 1080p.mp4")!.choice(fileNames: collection, fileSizes: [3, 2, 1]) == .file(1), "a film of a collection")
        check(WantedFile(fileName: "Other.mkv")!.choice(fileNames: collection, fileSizes: [3, 2, 1]) == .usualRule, "never notInTorrent for a movie")
        check(WantedFile(fileName: "Other.mkv")!.choice(fileNames: collection, fileSizes: [3, 2, 1], preferredIndex: 2) == .usualRule,
              "a movie's so= is the usual rule's")
    }

    /// Time4Popcorn's recorded answer for House of the Dragon (/show): every item keeps its
    /// file name (trimmed), and in each pack every episode finds its own file, by the
    /// source's name and by its marker, the largest file being another one.
    func testTime4PopcornAnswer() throws {
        let data = Fixtures.data("Packs/t4p_house_of_the_dragon.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var packs: [String: [(season: Int, episode: Int, file: String, torrent: Torrent)]] = [:]
        var items = 0
        for (seasonKey, value) in root {
            guard let season = Int(seasonKey), let episodes = value as? [[String: Any]] else { continue }
            for ep in episodes {
                let number = Int((ep["episode"] as? String) ?? "") ?? (ep["episode"] as? Int ?? -1)
                for item in (ep["items"] as? [[String: Any]]) ?? [] {
                    guard let torrent = Time4PopcornClient.torrent(fromItem: item), let file = item["file"] as? String else { continue }
                    items += 1
                    let trimmed = file.trimmingCharacters(in: .whitespacesAndNewlines)
                    check(torrent.releaseFileName == trimmed, "T4P file kept (trimmed): \(file)")
                    let wanted = WantedFile(media: Episode(episode: number, season: season), torrent: torrent)
                    // (Some T4P names start with a no-break space: trimmed.)
                    check(wanted?.season == season && wanted?.episode == number && wanted?.fileName == trimmed,
                          "wanted \(String(describing: wanted))")
                    packs[MagnetLink.sourceKey(of: torrent.url), default: []].append((season, number, file, torrent))
                }
            }
        }
        var multi = 0, picked = 0
        for (_, entries) in packs where Set(entries.map(\.file)).count > 1 {
            multi += 1
            let files = Array(Set(entries.map(\.file))).sorted()
            let sizes = files.map { Int64($0.utf8.count) * (files.firstIndex(of: $0)! == 0 ? 1000 : 1) }
            for entry in entries {
                let name = MagnetLink.displayName(of: entry.torrent.url)
                let byName = try XCTUnwrap(WantedFile(media: Episode(episode: entry.episode, season: entry.season), torrent: entry.torrent))
                let byMarker = want(entry.season, entry.episode)
                let expected = WantedFile.Choice.file(files.firstIndex(of: entry.file)!)
                check(byName.choice(fileNames: files, fileSizes: sizes, torrentName: name) == expected, "T4P pack by name: \(entry.file)")
                check(byMarker.choice(fileNames: files, fileSizes: sizes, torrentName: name) == expected, "T4P pack by marker: \(entry.file)")
                picked += 1
            }
        }
        print("T4P: \(items) items, \(packs.count) torrents, \(multi) packs, \(picked) pack plays checked")
        check(items == 101, "the fixture's items: \(items)")
        check(multi > 0 && picked > 10, "the fixture has packs: \(multi) packs, \(picked) plays")
    }
}
