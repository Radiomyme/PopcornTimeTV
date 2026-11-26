//
//  UpNextPlannerTests.swift
//  PopcornTimeTests
//
//  Episode chaining (PopcornKit UpNextPlanner): which episode comes after the one playing
//  (decision D1: the next one of the guide), and which release of it plays in continuity
//  with the release watched — same pack, same group, same class, same resolution, the
//  balanced pick, none — native first (a release only VLC plays is left out while another
//  one remains). On made-up lists shaped like the loopback bench's, and on recorded ones:
//  Time4Popcorn's House of the Dragon answer (Fixtures/Packs), Torrentio's Game of Thrones
//  S01E01 (Fixtures/Torrentio), The Pirate Bay's Breaking Bad S03E05 (Fixtures/Sources).
//  The release group parser on 40 names. Pure: a fixed capability snapshot, no connection.
//

import XCTest
import Foundation
@testable import PopcornKit

private let caps = PlaybackCapabilities.Snapshot.everything

private func number(_ season: Int, _ episode: Int) -> EpisodeNumber { EpisodeNumber(season: season, episode: episode) }

/// A single-file release named `file` (the magnet's dn), with its hash.
private func makeRelease(_ file: String, seeds: Int = 10, hash: String? = nil, size: String? = "1.2 GB") -> Torrent {
    let dn = file.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? file
    let key = hash ?? String(format: "%040x", abs(file.hashValue))
    return Torrent(url: "magnet:?xt=urn:btih:\(key)&dn=\(dn)", quality: file, seeds: seeds, size: size)
}

private func plan(_ playing: Torrent, files: PackFiles? = nil, next: EpisodeNumber = number(1, 2), _ candidates: [Torrent],
                  excluded: Set<String> = []) -> UpNextChoice {
    UpNextPlanner.continuity(playing: playing, packFiles: files, next: next, candidates: candidates, excluded: excluded,
                             connection: nil, capabilities: caps)
}

private func nameOf(_ torrent: Torrent?) -> String { torrent.flatMap { ReleaseProfile.name(of: $0) } ?? "nil" }

/// The bench's season pack: three episodes, a sample, an .nfo.
private let packFolder = "Test.Show.S01.1080p.HEVC-PTT"
private let packFiles = PackFiles(names: ["\(packFolder)/Test.Show.S01E01.1080p.HEVC-PTT.mkv", "\(packFolder)/Test.Show.S01E02.1080p.HEVC-PTT.mkv",
                                          "\(packFolder)/Test.Show.S01E03.1080p.HEVC-PTT.mp4", "\(packFolder)/sample.mkv",
                                          "\(packFolder)/Test.Show.S01.1080p.HEVC-PTT.nfo"],
                                  sizes: [300_000_000, 310_000_000, 305_000_000, 5_000_000, 2_000])
private let pack = makeRelease(packFolder, hash: String(repeating: "a", count: 40), size: "915 MB")

final class UpNextPlannerTests: CheckedTestCase {

    // MARK: The next episode (D1)

    func testTheNextEpisodeOfTheGuide() {
        let now = LibraryFixtures.date("2026-11-15T12:00:00Z")
        let guide = [LibraryFixtures.episode(1, 1), LibraryFixtures.episode(1, 2), LibraryFixtures.episode(1, 3),
                     LibraryFixtures.episode(0, 1), LibraryFixtures.episode(2, 1), LibraryFixtures.episode(2, 2, aired: "2027-01-01T00:00:00Z")]
        eq(UpNextPlanner.episode(after: number(1, 1), guide: guide, now: now)?.number, number(1, 2), "within the season")
        eq(UpNextPlanner.episode(after: number(1, 3), guide: guide, now: now)?.number, number(2, 1), "to the next season, the special stepped over")
        eq(UpNextPlanner.episode(after: number(2, 1), guide: guide, now: now)?.number, nil, "the next one has not aired: nothing")
        eq(UpNextPlanner.episode(after: number(2, 2), guide: guide, now: now)?.number, nil, "the last episode")
        eq(UpNextPlanner.episode(after: number(0, 1), guide: guide, now: now)?.number, nil, "after a special: nothing")
        eq(UpNextPlanner.episode(after: number(1, 1), guide: [], now: now)?.number, nil, "no guide")
        // In any order, duplicates (the one with a torrent kept), gaps in the numbering.
        let messy = [LibraryFixtures.episode(1, 5), LibraryFixtures.episode(1, 2, aired: "2027-01-01T00:00:00Z"),
                     LibraryFixtures.episode(1, 2, aired: "2027-01-01T00:00:00Z", hasSource: true), LibraryFixtures.episode(1, 1)]
        eq(UpNextPlanner.episode(after: number(1, 1), guide: messy, now: now)?.number, number(1, 2),
           "announced but already offered by a torrent: playable")
        eq(UpNextPlanner.episode(after: number(1, 2), guide: messy, now: now)?.number, number(1, 5), "a gap in the numbering")
        eq(UpNextPlanner.episode(after: number(1, 1), guide: [LibraryFixtures.episode(1, 0), LibraryFixtures.episode(1, 2)], now: now)?.number,
           number(1, 2), "an episode 0 is no episode")
    }

    // MARK: The same pack

    func testTheSamePackHoldsTheNextEpisode() {
        let choice = plan(pack, files: packFiles, [])
        eq(choice.rule, .samePack, "E02 is in the pack")
        eq(choice.torrent?.url, pack.url, "the same torrent")
        check(choice.torrent?.releaseFileName == nil, "no file name: the stream picks E02's file")
        check(abs((choice.torrent?.sizeInBytes ?? 0) - 310_000_000) < 1_000_000, "the size of E02's file (its label, to 0.1 MB)",
              "\(String(describing: choice.torrent?.size))")
        eq(choice.reasons, ["same pack: file #1 Test.Show.S01E02.1080p.HEVC-PTT.mkv"], "the reason, word for word")
        eq(plan(pack, files: packFiles, next: number(1, 3), []).torrent?.url, pack.url, "E03 (an .mp4) too")
        // A pack of E01-E02 only: E03 comes from another torrent of the same group.
        let short = PackFiles(names: Array(packFiles.names.prefix(2)), sizes: [300, 310])
        let e03 = makeRelease("Test.Show.S01E03.1080p.HEVC-PTT.mkv")
        let other = makeRelease("Test.Show.S01E03.1080p.WEB.H264-ABC.mkv", seeds: 90)
        let n8 = plan(pack, files: short, next: number(1, 3), [other, e03])
        eq(n8.rule, .sameGroup, "N8: E03 not in the pack → the same group")
        eq(n8.torrent?.url, e03.url, "N8: PTT's E03")
        eq(n8.reasons, ["group PTT, 1080p SDR", "the pack does not hold S01E03"], "N8 reasons")
        // Absolute numbering is refused: no pack file is taken for another episode.
        let mha = PackFiles(names: (14...38).map { "[HorribleSubs] Boku no Hero Academia S2 (14-38) [1080p] [Batch]/[HorribleSubs] Boku no Hero Academia - \($0) [1080p].mkv" })
        let batch = makeRelease("[HorribleSubs] Boku no Hero Academia S2 (14-38) [1080p] [Batch]", hash: String(repeating: "b", count: 40))
        let refused = plan(batch, files: mha, next: number(2, 2), [])
        eq(refused.rule, .none, "an absolutely numbered batch: not the same pack")
        check(refused.reasons.contains("the pack does not hold S02E02"), "said", "\(refused.reasons)")
        // The file list was not captured, but a source lists the same torrent for E02.
        let listed = Torrent(url: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))&so=1&dn=Test.Show.S01E02.1080p.HEVC-PTT.mkv",
                             quality: "1080p HEVC", seeds: 4)
        let byListing = plan(pack, [makeRelease("Test.Show.S01E02.1080p.WEB.H264-ABC.mkv", seeds: 99), listed])
        eq(byListing.rule, .samePack, "the same hash listed for E02")
        eq(byListing.torrent?.url, listed.url, "the listing (its so=)")
        eq(byListing.reasons, ["same pack: listed for S01E02"], "its reason")
    }

    // MARK: Group, class, resolution, balanced

    func testIsolatedEpisodesKeepTheGroupThenTheClass() {
        let playing = makeRelease("Test.Show.S01E01.1080p.HEVC-PTT.mkv")
        let ptt = makeRelease("Test.Show.S01E02.1080p.HEVC-PTT.mkv", seeds: 3)
        let uhd = makeRelease("Test.Show.S01E02.2160p.WEB.H265-QQQ.mkv", seeds: 200)
        let avi = makeRelease("Test.Show.S01E02.1080p.HDTV.XviD-ZZZ.avi", seeds: 300)
        let abc = makeRelease("Test.Show.S01E02.1080p.WEB.H264-ABC.mkv", seeds: 50)
        let n2 = plan(playing, [uhd, avi, abc, ptt])
        eq(n2.rule, .sameGroup, "N2: PTT's E02")
        eq(n2.torrent?.url, ptt.url, "N2: the same group, few seeds or not")
        eq(n2.reasons, ["group PTT, 1080p SDR", "native first: 1 left out (AVI 1)"], "N2 reasons")
        let without = plan(playing, [uhd, avi, abc])
        eq(without.rule, .sameClass, "N2 without PTT: the same class")
        eq(without.torrent?.url, abc.url, "1080p SDR of another group — never the 2160p, never the AVI")
        eq(without.reasons, ["no PTT release, 1080p SDR", "native first: 1 left out (AVI 1)"], "its reasons")
        // Another episode's release and a theater recording never count.
        let e03 = makeRelease("Test.Show.S01E03.1080p.HEVC-PTT.mkv", seeds: 999)
        let cam = Torrent(url: "magnet:?xt=urn:btih:\(String(repeating: "c", count: 40))&dn=Test.Show.S01E02.CAM.1080p-PTT.mkv",
                          quality: "1080p CAM", seeds: 999)
        eq(plan(playing, [e03, cam, abc]).torrent?.url, abc.url, "not E03, not a CAM")
        eq(plan(playing, [e03]).rule, .none, "only another episode: none")
    }

    func testThePreferredLanguageNeedsASwarm() {
        // A French viewer: a 1-seed VF of the same class never wins over a
        // well-seeded original; a VF with a few seeders does.
        AudioLanguagePreference.override = "fr"
        defer { AudioLanguagePreference.override = nil }
        let playing = makeRelease("Show.S01E01.1080p.WEB.H264-GRP.mkv")
        let english = makeRelease("Show.S01E02.1080p.WEB.H264-BBB.mkv", seeds: 350)
        let thin = makeRelease("Show.S01E02.FRENCH.1080p.WEB.H264-AAA.mkv", seeds: 1)
        let thinChoice = plan(playing, [thin, english])
        eq(thinChoice.rule, .sameClass, "the same class")
        eq(thinChoice.torrent?.url, english.url, "1 seed: the original")
        let seeded = makeRelease("Show.S01E02.FRENCH.1080p.WEB.H264-AAA.mkv", seeds: 5)
        eq(plan(playing, [seeded, english]).torrent?.url, seeded.url, "5 seeds: the VF")
    }

    func testADeadReleaseGivesWayToTheNextRule() {
        // The same group listed with no seeder, a healthy release of the same class: the latter.
        let playing = makeRelease("Show.S01E01.1080p.WEB.H264-NTb.mkv")
        let deadNTb = makeRelease("Show.S01E02.1080p.WEB.H264-NTb.mkv", seeds: 0)
        let abc = makeRelease("Show.S01E02.1080p.WEB.H264-ABC.mkv", seeds: 200)
        let healthy = plan(playing, [deadNTb, abc])
        eq(healthy.rule, .sameClass, "not the dead NTb release")
        eq(healthy.torrent?.url, abc.url, "ABC's, 200 seeds")
        // One level down: a dead release of the same class gives way to a seeded one at the same resolution.
        let deadClass = makeRelease("Show.S01E02.1080p.WEB.H264-ZZZ.mkv", seeds: 0)
        let hdr = makeRelease("Show.S01E02.1080p.WEB.HDR.H265-YYY.mkv", seeds: 40)
        let down = plan(playing, [deadNTb, deadClass, hdr])
        eq(down.rule, .sameResolution, "the same resolution, seeded")
        eq(down.torrent?.url, hdr.url, "YYY's")
        // A provider with no seed counts at all: today's behaviour, the same group.
        let unknown = plan(playing, [deadNTb, makeRelease("Show.S01E02.1080p.WEB.H264-ABC.mkv", seeds: 0, hash: String(repeating: "9", count: 40))])
        eq(unknown.rule, .sameGroup, "no counts anywhere: the same group")
        eq(unknown.torrent?.url, deadNTb.url, "NTb's")
    }

    func testDynamicRangeBeforeTheGroup() {
        let dv = makeRelease("Show.S01E01.2160p.WEB-DL.DDP5.1.Atmos.DV.H.265-FLUX.mkv")
        let hdr = makeRelease("Show.S01E02.2160p.WEB-DL.DDP5.1.Atmos.HDR.H.265-FLUX.mkv", seeds: 40)
        let dvOther = makeRelease("Show.S01E02.2160p.WEB-DL.DDP5.1.DV.H.265-NTb.mkv", seeds: 5)
        let hd = makeRelease("Show.S01E02.1080p.WEB-DL.DDP5.1.H.264-FLUX.mkv", seeds: 80)
        let same = plan(dv, [hdr, dvOther, hd])
        eq(same.rule, .sameClass, "DV again from another group before FLUX's HDR10")
        eq(same.torrent?.url, dvOther.url, "2160p DV")
        let dvToHDR = plan(dv, [hdr, hd])
        eq(dvToHDR.rule, .sameResolution, "DV → HDR10 at the same resolution")
        eq(dvToHDR.torrent?.url, hdr.url, "2160p HDR10")
        eq(dvToHDR.reasons, ["2160p DV not found, HDR10 at the same resolution"], "its reason")
        let noUHD = plan(dv, [hd, makeRelease("Show.S01E02.720p.WEB.H264-FLUX.mkv", seeds: 200)])
        eq(noUHD.rule, .balanced, "no 2160p: the balanced pick")
        eq(noUHD.torrent?.url, hd.url, "the 1080p (its swarm clears the floor)")
        eq(noUHD.reasons, ["no 2160p release: balanced pick"], "its reason")
    }

    // MARK: Native first

    func testNativeFirst() {
        // N3: the episode watched was DTS only (VLC): the next one is native, another group.
        let dts = makeRelease("Test.Show.S01E01.1080p.BluRay.DTS.x264-PTT.mkv")
        let dtsNext = makeRelease("Test.Show.S01E02.1080p.BluRay.DTS.x264-PTT.mkv", seeds: 40)
        let eac3 = makeRelease("Test.Show.S01E02.1080p.WEB-DL.DDP5.1.H.264-XYZ.mkv", seeds: 5)
        let n3 = plan(dts, [dtsNext, eac3])
        eq(n3.rule, .sameClass, "N3: not the same group: native first")
        eq(n3.torrent?.url, eac3.url, "N3: the E-AC-3 release")
        eq(n3.reasons, ["no PTT release, 1080p SDR", "native first: 1 left out (DTS only 1)", "the release played is not native (DTS only)"],
           "N3 reasons, word for word")
        // Only VLC releases: the best of them all the same.
        eq(plan(dts, [dtsNext]).torrent?.url, dtsNext.url, "nothing native: PTT's DTS release")
        // TrueHD only, VP9 (penalized), AVI / TS left out while a native one remains.
        let truehd = makeRelease("Show.S01E02.1080p.BluRay.REMUX.AVC.TrueHD.7.1-AAA.mkv", seeds: 99)
        let vp9 = makeRelease("Show.S01E02.1080p.WEB.VP9.Opus-BBB.webm", seeds: 99)
        let ts = makeRelease("Show.S01E02.1080p.HDTV.H264-CCC.ts", seeds: 99)
        let aac = makeRelease("Show.S01E02.1080p.WEB.H264.AAC-DDD.mp4", seeds: 1)
        let mixed = plan(makeRelease("Show.S01E01.1080p.WEB.H264-DDD.mkv"), [truehd, vp9, ts, aac])
        eq(mixed.torrent?.url, aac.url, "the native one")
        eq(mixed.reasons, ["group DDD, 1080p SDR", "native first: 3 left out (TS 1, TrueHD only 1, penalized 1)"], "each named")
        // A pack that plays through VLC gives way to a native release of the next episode.
        let dtsPack = makeRelease("Test.Show.S01.1080p.BluRay.DTS.x264-PTT", hash: String(repeating: "d", count: 40))
        let viaVLC = plan(dtsPack, files: packFiles, [eac3])
        eq(viaVLC.rule, .sameClass, "the DTS pack holds E02, but a native release exists")
        eq(viaVLC.reasons.first, "no PTT release, 1080p SDR", "its first reason")
        check(viaVLC.reasons.contains("the pack holds S01E02 but plays through VLC (DTS only): a native release first"), "said",
              "\(viaVLC.reasons)")
        eq(plan(dtsPack, files: packFiles, []).rule, .samePack, "no native release known: the pack")
    }

    func testExcludedAndEmpty() {
        let playing = makeRelease("Show.S01E01.1080p.WEB.H264-NTb.mkv")
        let a = makeRelease("Show.S01E02.1080p.WEB.H264-NTb.mkv", hash: String(repeating: "e", count: 40))
        let b = makeRelease("Show.S01E02.1080p.WEB.H264-FLUX.mkv", hash: String(repeating: "f", count: 40))
        let choice = plan(playing, [a, b], excluded: [String(repeating: "e", count: 40)])
        eq(choice.torrent?.url, b.url, "the source that did not answer is left out")
        eq(choice.reasons, ["no NTb release, 1080p SDR", "1 excluded (source did not answer)"], "said")
        let none = plan(playing, [])
        eq(none.rule, .none, "nothing: none")
        eq(none.torrent, nil, "no torrent")
        eq(none.reasons, ["no release of S01E02"], "said")
        check(!none.isClearContinuity && choice.isClearContinuity && !noUHDChoice().isClearContinuity, "D4: clear continuity")
        eq(choice.logLine(next: number(1, 2), elapsed: 0.25),
           "[UpNext] plan S01E02 rule=sameClass torrent=\(b.quality ?? "?") (ffffffffffff) in 0.2 s — no NTb release, 1080p SDR; 1 excluded (source did not answer)",
           "the [UpNext] line")
    }

    private func noUHDChoice() -> UpNextChoice {
        plan(makeRelease("Show.S01E01.2160p.WEB.H265-FLUX.mkv"), [makeRelease("Show.S01E02.1080p.WEB.H264-FLUX.mkv")])
    }

    // MARK: Recorded lists

    /// Time4Popcorn's House of the Dragon: S01E01 from SMURF's 1080p → S01E02 from SMURF's 1080p
    /// (T4P lists both episodes from the same season-pack torrent: the same pack).
    func testTime4PopcornRecordedList() throws {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Fixtures.data("Packs/t4p_house_of_the_dragon.json")) as? [String: Any])
        func torrents(_ season: Int, _ episode: Int) -> [Torrent] {
            let episodes = (root["\(season)"] as? [[String: Any]]) ?? []
            let entry = episodes.first { Int(($0["episode"] as? String) ?? "") ?? ($0["episode"] as? Int ?? -1) == episode }
            return ((entry?["items"] as? [[String: Any]]) ?? []).compactMap(Time4PopcornClient.torrent(fromItem:))
        }
        let e01 = torrents(1, 1), e02 = torrents(1, 2)
        check(e01.count > 3 && e02.count > 3, "the fixture's lists", "\(e01.count) / \(e02.count)")
        let smurf = try XCTUnwrap(e01.first { ($0.releaseFileName ?? "").contains("1080p.HMAX.WEB-DL.DDP5.1.Atmos.H.264-SMURF") })
        let choice = plan(smurf, next: number(1, 2), e02)
        eq(choice.rule, .samePack, "SMURF's pack again (the same info-hash, listed for S01E02)")
        eq(choice.torrent.map { MagnetLink.sourceKey(of: $0.url) }, MagnetLink.sourceKey(of: smurf.url), "the same torrent")
        check(nameOf(choice.torrent).contains("S01E02") && nameOf(choice.torrent).hasSuffix("H.264-SMURF.mkv"), "SMURF's S01E02", nameOf(choice.torrent))
        let dvsux = try XCTUnwrap(e01.first { ($0.releaseFileName ?? "").contains("S01E01.2160p.HMAX.WEB-DL.DDP5.1.Atmos.DV.MP4.x265-DVSUX") })
        let uhd = plan(dvsux, next: number(1, 2), e02)
        check(uhd.rule == .samePack || uhd.rule == .sameGroup, "DVSUX 2160p DV again", uhd.rule.rawValue)
        check(nameOf(uhd.torrent).contains("S01E02") && nameOf(uhd.torrent).contains("DVSUX"), "DVSUX's S01E02", nameOf(uhd.torrent))
        // FGT's REMUX is DTS-HD MA + TrueHD: only VLC plays it; the next one is native.
        let fgt = try XCTUnwrap(e01.first { ($0.releaseFileName ?? "").contains("REMUX.AVC.DTS-HD.MA.TrueHD.7.1.Atmos-FGT") })
        let native = plan(fgt, next: number(1, 2), e02)
        check(!nameOf(native.torrent).contains("FGT"), "not FGT's DTS / TrueHD remux", nameOf(native.torrent))
        check(native.reasons.contains("the release played is not native (DTS only)"), "said", "\(native.reasons)")
    }

    /// Torrentio's Game of Thrones S01E01 as the next episode's list (500 streams, packs
    /// with their own file names).
    func testTorrentioRecordedList() throws {
        let data = Fixtures.data("Torrentio/got_s01e01.json")
        let streams = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["streams"] as? [[String: Any]])
        let got = streams.compactMap(TorrentioClient.torrent(fromStream:))
        check(got.count > 400, "the recorded list", "\(got.count)")
        let oft = makeRelease("Game of Thrones S00E55 Making Of 1080p BluRay x264-OFT.mkv")
        let choice = plan(oft, next: number(1, 1), got)
        eq(choice.rule, .sameGroup, "OFT again")
        eq(nameOf(choice.torrent), "Game of Thrones S01E01 Winter Is Coming 1080p BluRay x264-OFT.mkv", "OFT's S01E01")
        let kitsune = makeRelease("Game of Thrones S00E01 2160p MAX WEB-DL TrueHD 7 1 Atmos DV HDR H 265-Kitsune.mkv")
        let uhd = plan(kitsune, next: number(1, 1), got)
        check(uhd.torrent.map { $0.qualityValue == .uhd2160 } == true, "a 2160p", nameOf(uhd.torrent))
        check(uhd.reasons.contains("the release played is not native (TrueHD only)"), "Kitsune's is TrueHD only", "\(uhd.reasons)")
        check(!(ReleaseProfile(uhd.torrent!, capabilities: caps).vlcOnlyReason != nil), "and the pick is native", nameOf(uhd.torrent))
    }

    /// The Pirate Bay's Breaking Bad S03E05 (names without extensions, XviD, an .avi).
    func testPirateBayRecordedList() {
        let releases = PirateBayClient.releases(fromJSON: Fixtures.data("Sources/tpb_q_breaking_bad_s03e05.json"))
        let torrents = releases.map(ExtraTorrentSources.torrent(from:))
        check(torrents.count == 10, "the recorded list", "\(torrents.count)")
        let ctu = plan(makeRelease("Breaking.Bad.S03E04.720p.HDTV.x264-CTU"), next: number(3, 5), torrents)
        eq(ctu.rule, .sameGroup, "CTU again")
        eq(nameOf(ctu.torrent), "Breaking.Bad.S03E05.720p.HDTV.x264-CTU", "CTU's S03E05")
        let xebec = plan(makeRelease("Breaking Bad S03E04 2160p NF WEB-DL DDP5 1 H 265-XEBEC"), next: number(3, 5), torrents)
        eq(nameOf(xebec.torrent), "Breaking Bad S03E05 Mas 2160p NF WEB-DL DDP5 1 H 265-XEBEC", "XEBEC's S03E05")
        let remux = plan(makeRelease("Breaking Bad S03E04 1080p DTS-HD MA 5 1 AVC REMUX-FraMeSToR"), next: number(3, 5), torrents)
        check(!nameOf(remux.torrent).contains("FraMeSToR"), "not the DTS-only remux", nameOf(remux.torrent))
        check(remux.reasons.contains { $0.hasPrefix("native first: ") }, "native first said", "\(remux.reasons)")
        check(!nameOf(remux.torrent).contains("S03E13"), "never the S03E05-S03E13 range", nameOf(remux.torrent))
    }

    // MARK: The release group

    func testReleaseGroups() {
        let cases: [(String, String?)] = [
            ("House.of.the.Dragon.S02E03.1080p.MAX.WEB-DL.DDP5.1.x264-NTb.mkv", "NTb"),
            ("House of the Dragon S02E03 1080p MAX WEB-DL DDP5 1 x264-NTb.mkv", "NTb"),
            ("Game.of.Thrones.S01E01.2160p.UHD.BluRay.x265-SCOTLUHD[eztv.io].mkv", "SCOTLUHD"),
            ("Game of Thrones S01E01 2160p UHD BluRay x265-SCOTLUHD [eztv]", "SCOTLUHD"),
            ("Show.2019.S01E05.720p.HDTV.x264-KILLERS[ettv]", "KILLERS"),
            ("Show.S01E01.1080p.WEB.H264-GGEZ[TGx]", "GGEZ"),
            ("Game of Thrones S01E01 Winter Is Coming REPACK 2160p MAX WEB-DL TrueHD 7 1 Atmos DV HDR H 265-Kitsune.mkv", "Kitsune"),
            ("Game.of.Thrones.S01E01.2160p.DoVi.HDR.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos-PB69.mkv", "PB69"),
            ("Game.of.Thrones.S01E01.Winter.Is.Coming.1080p.10bit.BluRay.6CH.x265.HEVC-PSA.mkv", "PSA"),
            ("Game.of.Thrones.S01E01.Winter.Is.Coming.1080p.BluRay.10bit.HEVC.6CH-MkvCage.ws.mkv", "MkvCage"),
            ("Game of Thrones (2011) S01 (2160p x265 10bit HDR UHD BD Atmos) [Prof]", "Prof"),
            ("Game of Thrones - S01E01 - Winter Is Coming [2160p] [HDR] [5.1, 7.1, 5.1] [ger, eng, eng] [Vio].mkv", "Vio"),
            ("Game Of Thrones (2011) Season 01 S01 REPACK (2160p BluRay X265 HEVC 10bit AAC 7.1 Joy) [UTR]", "UTR"),
            ("Game.of.Thrones.S01.2160p.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos-FGT", "FGT"),
            ("Game.of.Thrones.S01.2160p.UHD.BluRay.TrueHD.7.1.DoVi-DON[rartv]", "DON"),
            ("Game.of.Thrones.S01E01.1080p.BluRay.x265-RARBG.mp4", "RARBG"),
            ("Breaking.Bad.S03E05.720p.HDTV.x264-CTU", "CTU"),
            ("Breaking Bad S03E05 HDTV XviD-FEVER [eztv]", "FEVER"),
            ("Breaking Bad S03E05 Mas REPACK2 1080p DTS-HD MA 5 1 AVC REMUX-FraMeSToR", "FraMeSToR"),
            ("House.of.the.Dragon.S01E01.2160p.HMAX.WEB-DL.DDP5.1.Atmos.DV.MP4.x265-DVSUX.mp4", "DVSUX"),
            ("house.of.the.dragon.s01e02.hdr.2160p.web.h265-ggez.mkv", "ggez"),
            ("House.of.the.Dragon.S02E01.REPACK.WEB.x264-TORRENTGALAXY.mkv", "TORRENTGALAXY"),
            ("Test.Show.S01E02.1080p.HEVC-PTT.mkv", "PTT"),
            ("Test.Show.S01.1080p.HEVC-PTT", "PTT"),
            ("Pack/Sub/Test.Show.S01E03.1080p.HEVC-PTT.mp4", "PTT"),
            ("[SubsPlease] Frieren - 05 (1080p) [ABCD1234].mkv", "SubsPlease"),
            ("[HorribleSubs] Boku no Hero Academia - 14 [1080p].mkv", "HorribleSubs"),
            ("Breaking.Bad.S03E05.H264[quark]", "quark"),
            // No group.
            ("Show.S01E01.1080p.WEB-DL.mkv", nil),
            ("Frieren - 05 (1080p).mkv", nil),
            ("Show S01E01 - 10 [1080p]", nil),
            ("Spider-Man.No.Way.Home.2021.1080p.mkv", nil),
            ("Spider-Man No Way Home 2021 1080p", nil),
            ("S01E01.mkv", nil),
            ("01 - L Hiver Vient.mkv", nil),
            ("Game of Thrones S01E01 Winter is Coming.mkv", nil),
            ("Breaking Bad.S03E05.Subtitulado.Esp.SC.avi", nil),
            ("Show.S01E01-E03.1080p", nil),
            ("Show.S01E01.1080p.WEB.H.264-", nil),
            ("Игра престолов.S01E01.WEB-DL.2160p.mkv", nil),
        ]
        eq(cases.count, 40, "40 names")
        for (name, expected) in cases {
            eq(ReleaseName.group(of: name), expected, name)
        }
    }

    // MARK: Profiles

    func testProfiles() {
        let profile = ReleaseProfile(makeRelease("Show.S01E01.2160p.WEB-DL.DDP5.1.Atmos.DV.H.265-FLUX.mkv"), capabilities: caps)
        eq(profile.resolution, .uhd2160, "resolution")
        eq(profile.hdr, .dolbyVision, "DV")
        eq(profile.codec, .hevc, "HEVC")
        eq(profile.audio, .atmos, "DD+ Atmos")
        eq(profile.group, "FLUX", "group")
        eq(profile.container, "mkv", "container")
        eq(profile.vlcOnlyReason, nil, "native")
        let local = Torrent(url: "/tmp/bench/Test.Show.S01E02.1080p.HEVC-PTT.torrent", quality: "1080p HEVC")
        eq(ReleaseProfile.name(of: local), "Test.Show.S01E02.1080p.HEVC-PTT", "a local .torrent's name")
        eq(ReleaseProfile(local, capabilities: caps).group, "PTT", "its group")
        let named = Torrent(url: "/tmp/bench/e02-avi.torrent", quality: "1080p", fileName: "Test.Show.S01E02.1080p.XviD-ZZZ.avi")
        eq(ReleaseProfile(named, capabilities: caps).vlcOnlyReason, "AVI", "the source's file name says AVI")
        eq(ReleaseProfile.audio(of: VideoTags.parse("TrueHD 7.1 Atmos")), .trueHDOnly, "TrueHD Atmos alone")
        eq(ReleaseProfile.audio(of: VideoTags.parse("DTS-HD MA TrueHD Atmos")), .dtsOnly, "DTS + TrueHD: no Dolby Digital track")
        eq(ReleaseProfile.audio(of: VideoTags.parse("TrueHD Atmos AC3")), .ac3, "TrueHD with an AC-3 track")
    }
}
