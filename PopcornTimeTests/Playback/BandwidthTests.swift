//
//  BandwidthTests.swift
//  PopcornTimeTests
//
//  The bandwidth work: size labels, the bitrate estimate of a release, runtimes, pack
//  detection, the fit of a bitrate on a connection, the recommendation (balancedPick,
//  precedesInListing, merge) and ConnectionSpeed's pure core, against Torrentio answers
//  recorded on 2026-11-12 (Fixtures/Torrentio). (Port of the bandwidth harness: 149 checks.)
//

import XCTest
import Foundation
@testable import PopcornKit

/// A movie / show with a runtime (the harness used stand-ins; these are the real models).
private func movieWith(runtime: Int) -> Movie { Movie(yts: ["imdb_code": "tt0816692", "title": "Interstellar", "runtime": runtime])! }
private func showWith(runtime: Int?) -> Show { var show = Show(); show.runtime = runtime; return show }

private let fixtures = Fixtures.url("Torrentio")
private func streams(_ name: String) -> [[String: Any]] {
    let data = try! Data(contentsOf: fixtures.appendingPathComponent(name))
    return (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["streams"] as! [[String: Any]]
}
/// A defaults suite for one test, empty: a fixed name (not one per run: each left a plist in
/// ~/Library/Preferences, removePersistentDomain keeps the file).
private func throwawayDefaults(_ name: String) -> UserDefaults {
    let suite = UserDefaults(suiteName: name)!
    suite.removePersistentDomain(forName: name)
    return suite
}

/// Empties the suite and deletes its file.
private func discardDefaults(_ suite: UserDefaults, _ name: String) {
    suite.removePersistentDomain(forName: name)
    suite.synchronize()
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(at: file)
}

private func mbps(_ bytesPerSecond: Double?) -> Double { return bytesPerSecond.map(StreamBandwidth.megabitsPerSecond) ?? -1 }
private func near(_ a: Double?, _ b: Double, _ tolerance: Double = 0.01) -> Bool {
    guard let a = a else { return false }
    return abs(a - b) <= abs(b) * tolerance
}

private func bytes(_ label: String?) -> Double? { return StreamBandwidth.bytes(fromSizeLabel: label).map(Double.init) }
private let got = streams("got_s01e01.json").compactMap { TorrentioClient.torrent(fromStream: $0) }
private func named(_ fragment: String) -> Torrent? {
    return got.first { (MagnetLink.displayName(of: $0.url) ?? "").contains(fragment) }
}

private let mbit = 1_000_000.0 / 8

private func episodeTorrent(_ file: String, _ size: String, seeds: Int, hash: String) -> Torrent {
    let dn = file.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    return Torrent(url: "magnet:?xt=urn:btih:\(hash)&dn=\(dn)&so=0", quality: file, seeds: seeds, size: size)
}
// The deficit message's numbers: one decimal under 10 Mb/s, the bitrate rounded up, the rate down.
private func pair(_ b: Double, _ r: Double) -> String { BandwidthText.megabits(b * mbit, roundingUp: true) + " / " + BandwidthText.megabits(r * mbit, roundingUp: false) }

final class BandwidthTests: CheckedTestCase {

    func testBandwidth() {
        let GiB = 1_073_741_824.0, MiB = 1_048_576.0
        let caps = PlaybackCapabilities.Snapshot(av1HardwareDecode: false, hevcHardwareDecode: true, dolbyVision: true, hdr: true)

        check(near(bytes("31.07 GB"), 31.07 * GiB, 1e-6), "Torrentio GB \(bytes("31.07 GB") ?? -1)")
        check(near(bytes("984.22 MB"), 984.22 * MiB, 1e-6), "Torrentio MB")
        check(near(bytes("31,07 Go"), 31.07 * GiB, 1e-6), "French ByteCountFormatter")
        check(near(bytes("1\u{202F}000 Mo"), 1000 * MiB, 1e-6), "French grouping (narrow nbsp)")
        check(near(bytes("1,000 MB"), 1000 * MiB, 1e-6), "English grouping")
        check(near(bytes("1.000 MB"), 1000 * MiB, 1e-6), "pt-BR grouping")
        check(near(bytes("999,5 MB"), 999.5 * MiB, 1e-6), "decimal comma, one digit")
        check(near(bytes("2.47 GB"), 2.47 * GiB, 1e-6), "decimal point")
        check(near(bytes("\u{0663}\u{0661}\u{066B}\u{0660}\u{0667} \u{063A}.\u{0628}.\u{200F}"), 31.07 * GiB, 1e-6), "Arabic digits + غ.ب.")
        check(near(bytes("\u{0661}\u{066C}\u{0660}\u{0660}\u{0660} \u{0645}.\u{0628}.\u{200F}"), 1000 * MiB, 1e-6), "Arabic grouping + م.ب.")
        check(near(bytes("850 MB"), 850 * MiB, 1e-6), "integer MB")
        check(near(bytes("1.2 TB"), 1.2 * 1024 * GiB, 1e-6), "TB")
        check(near(bytes("512 KB"), 512 * 1024, 1e-6), "KB")
        check(near(bytes("2.4 GiB"), 2.4 * GiB, 1e-6), "GiB")
        check(bytes("12345") == 12345, "bare number = bytes")
        check(bytes(nil) == nil && bytes("") == nil && bytes("GB") == nil && bytes("—") == nil && bytes("0 MB") == nil, "no size")
        check(TorrentioClient.sizeInBytes("54.33 GB") == Int64(54.33 * GiB), "Torrentio client delegates")
        check(TorrentioClient.sizeInBytes("55,1 Go").map { $0 > TorrentioClient.maxSizeBytes } == true, "French EZTV label now exceeds the cap")

        // MARK: 2. Pack detection

        for single in ["Game.of.Thrones.S01E01.2160p.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos-FGT.mkv", "S01E01.mkv",
                       "Game of Thrones - 1x01 - Winter Is Coming.mkv", "Juego de Tronos - Temp.1 [HDTV][Cap.101][Spanish_English]",
                       "Interstellar.2014.1080p.BluRay.x264-YIFY.mp4", "01 - L Hiver Vient.mkv",
                       "Show Season 3 Episode 5 1080p", "[Group] Show - 05 [1080p]"] {
            check(!ReleaseName.coversSeveralEpisodes(single), "single: \(single)")
        }
        for pack in ["Game.of.Thrones.S01.2160p.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos-FGT", "Juego de Tronos - 1ª Temporada",
                     "Game of thrones S01E01-E10 SweSub [GA645Zi]", "Game of Thrones [1080p][5.1][Hi10p] Seasons 1-3",
                     "Show.S03E05E06.1080p.WEB", "Game.of.Thrones.Complete.2160p.BluRay", "Show [Cap.301_310]", "Show 3x05-06 720p",
                     "Game.of.Thrones.S01.E1-E2.CUSTOM.NORDIC.DVDR", "1º Temporada Game Of Thrones"] {
            check(ReleaseName.coversSeveralEpisodes(pack), "pack: \(pack)")
        }

        // Movie collections (a whole torrent's size without file information).
        for collection in ["The Matrix Trilogy 1999-2003 1080p BluRay x264", "Harry Potter 1-8 Complete 1080p", "Saw 1 - 7 BluRay",
                           "The Lord of the Rings Trilogie EXTENDED 2160p", "Alien Quadrilogy 1080p", "Pixar Short Films Collection 1080p",
                           "Star Wars Anthology", "Mad Max Box Set 1080p"] {
            check(ReleaseName.coversSeveralEpisodes(collection), "collection: \(collection)")
        }
        for film in ["The.Twilight.Saga.New.Moon.2009.1080p.BluRay.x264", "Seven.Samurai.1954.Criterion.Collection.1080p.BluRay",
                     "Movie.2023.1080p.WEB-DL.DDP5.1.H.264-FLUX", "Movie.2019.2160p.UHD.BluRay.REMUX.TrueHD.7.1-FGT",
                     "Blade.Runner.2049.2017.1080p", "Ocean's.Eleven.2001.1080p.DTS-HD.MA.5.1-2HD", "Movie 2019-2020 1080p"] {
            check(!ReleaseName.coversSeveralEpisodes(film), "single film: \(film)")
        }
        let matrix = Torrent(url: "magnet:?xt=urn:btih:ab&dn=The+Matrix+Trilogy+1999-2003+1080p+BluRay", quality: "1080p", seeds: 50, size: "26.5 GB")
        check(matrix.withMediaRuntime(8_160).estimatedBitrate == nil, "trilogy without file info: no estimate (was ≈ 28 Mb/s)")

        // Time4Popcorn: the magnet names the season pack, the size and `file` are the episode's.
        let t4p = Torrent(url: "magnet:?xt=urn:btih:cd&dn=House.of.the.Dragon.S01.1080p.BluRay.REMUX.AVC.DTS-HD.MA.TrueHD.7.1.At",
                          quality: "1080p", seeds: 40, size: "18.46 GB",
                          fileName: "House.of.the.Dragon.S01E01.1080p.BluRay.REMUX.AVC.DTS-HD.MA.TrueHD.7.1.Atmos-FGT")
        check(near(t4p.streamedFileBytes.map(Double.init), 18.46 * GiB, 1e-6), "T4P: the file name decides (episode file size)")
        check(near(mbps(t4p.withMediaRuntime(3960).estimatedBitrate), 18.46 * GiB * 8 / 1e6 / 3960, 1e-6), "T4P HotD FGT ≈ 40 Mb/s")
        check(t4p.replacingURL("magnet:?xt=urn:btih:cd&dn=x").streamedFileBytes == t4p.streamedFileBytes, "replacingURL keeps the file name")
        let t4pPack = Torrent(url: "magnet:?xt=urn:btih:ce&dn=Show.S01.1080p", quality: "1080p", seeds: 4, size: "40 GB", fileName: "Show.S01.1080p.Complete")
        check(t4pPack.streamedFileBytes == nil, "T4P file naming a pack: unknown")
        check(Torrent(url: "magnet:?xt=urn:btih:cf&dn=Show.S01.1080p", quality: "1080p", size: "4 GB", fileName: "  ").streamedFileBytes == nil,
              "blank file name: the magnet's dn decides (a pack)")
        check(MagnetLink.sourceKey(of: "magnet:?xt=urn:btih:ABCDEF&dn=x&tr=y") == "abcdef" && MagnetLink.sourceKey(of: "/tmp/a.torrent") == "/tmp/a.torrent",
              "source key = info-hash, else the link")

        // Conservative quirks (no estimate rather than a wrong one): "Temporada 4 Cap
        // 408" also reads as S04E408 (episodeScope's "Season N Episode M" rule), and
        // "S01E.01" is no SxxEyy marker, so "S01" makes it a season.
        check(ReleaseName.coversSeveralEpisodes("Westworld - Temporada 4 [Cap.408]"), "known quirk: Cap after Temporada")
        check(ReleaseName.coversSeveralEpisodes("Game.of.Thrones.S01E.01.UHD.BluRay.REMUX.2160p.TrueHD.mkv"), "known quirk: S01E.01")

        // MARK: 3. Bitrate of real Torrentio streams (Game of Thrones S01E01, ~60 min)

        let episodeRuntime: TimeInterval = 3_660
        check(got.count >= 400, "GOT torrents \(got.count)")
        let fgt = got.first { $0.url.contains("605b8f1c0032682c4826caf68db37b361199b2de") }!
        check(near(fgt.streamedFileBytes.map(Double.init), 33_364_684_042, 0.001), "FGT season pack: Torrentio's size is the episode file \(fgt.streamedFileBytes ?? -1)")
        check(near(mbps(fgt.estimatedBitrate(runtimeSeconds: episodeRuntime)), 72.9, 0.01), "FGT ≈ 72.9 Mb/s: \(mbps(fgt.estimatedBitrate(runtimeSeconds: episodeRuntime)))")
        check(fgt.estimatedBitrate == nil, "no runtime attached: no estimate")
        check(near(mbps(fgt.withMediaRuntime(episodeRuntime).estimatedBitrate), 72.9, 0.01), "withMediaRuntime")
        for fragment in ["Juego de Tronos - 1ª Temporada", "Seasons 1-3", "S01E01-E10 SweSub", "1º Temporada Game Of Thrones"] {
            let torrent = named(fragment)
            check(torrent != nil && torrent!.sizeInBytes != nil && torrent!.streamedFileBytes == nil
                  && torrent!.estimatedBitrate(runtimeSeconds: episodeRuntime) == nil,
                  "whole-pack size without file info gives no estimate: \(fragment) \(torrent?.size ?? "missing")")
        }
        let estimated = got.compactMap { $0.estimatedBitrate(runtimeSeconds: episodeRuntime) }
        let unknown = got.filter { $0.estimatedBitrate(runtimeSeconds: episodeRuntime) == nil }
        for torrent in got where torrent.sizeInBytes != nil {
            if let name = MagnetLink.displayName(of: torrent.url), ReleaseName.isMovieCollection(name) { print("GOT S01E01 named like a collection: \(name)") }
        }
        print("GOT S01E01: \(estimated.count) of \(got.count) streams with an estimate; max \(String(format: "%.0f", mbps(estimated.max()))) Mb/s; unknown e.g. \(unknown.prefix(4).map { MagnetLink.displayName(of: $0.url) ?? "?" })")
        check(estimated.count >= 380 && estimated.allSatisfy { mbps($0) < 160 }, "estimates plausible")
        let psa = named("S01E01.Winter.Is.Coming.1080p.10bit.BluRay.6CH.x265.HEVC-PSA")!
        check(near(mbps(psa.estimatedBitrate(runtimeSeconds: episodeRuntime)), 1.08 * GiB * 8 / 1e6 / episodeRuntime, 0.001), "PSA 1080p ≈ 2.5 Mb/s")

        // Movie: Interstellar (169 min).
        let interstellar = streams("interstellar.json").compactMap { TorrentioClient.torrent(fromStream: $0) }
        let movieRuntime = Torrent.mediaRuntime(of: movieWith(runtime: 169))
        check(movieRuntime == 10_140, "movie runtime \(movieRuntime ?? -1)")
        let imaxRemux = interstellar.first { $0.url.contains("d8d05ebec7303f05a7243986e8c7d0e201b0ac0d") }
        check(imaxRemux.map { near(mbps($0.estimatedBitrate(runtimeSeconds: movieRuntime)), 95.63 * GiB * 8 / 1e6 / 10_140, 0.001) } == true,
              "IMAX remux ≈ 81 Mb/s: \(mbps(imaxRemux?.estimatedBitrate(runtimeSeconds: movieRuntime)))")
        check(imaxRemux?.withMediaRuntime(movieRuntime).bandwidthFit(connection: nil) == .heavy, "remux heavy without a connection estimate")
        let movieEstimates = interstellar.compactMap { $0.estimatedBitrate(runtimeSeconds: movieRuntime) }
        print("Interstellar: \(movieEstimates.count) of \(interstellar.count) with an estimate, \(movieEstimates.filter { mbps($0) > 40 }.count) above 40 Mb/s")

        // Runtimes.
        check(Torrent.mediaRuntime(of: Episode(show: showWith(runtime: 60))) == 3600, "episode: show runtime")
        check(Torrent.mediaRuntime(of: Episode(show: nil), show: showWith(runtime: 45)) == 2700, "episode: explicit show")
        check(Torrent.mediaRuntime(of: Episode(show: showWith(runtime: 0))) == nil && Torrent.mediaRuntime(of: movieWith(runtime: 0)) == nil
              && Torrent.mediaRuntime(of: Episode(show: showWith(runtime: nil))) == nil, "unknown runtimes")
        check(fgt.estimatedBitrate(runtimeSeconds: 30) == nil && fgt.estimatedBitrate(runtimeSeconds: 120) == nil, "implausible runtimes give nothing")
        check(fgt.replacingURL(fgt.url + "&so=0").withMediaRuntime(3600).mediaRuntime == 3600
              && fgt.withMediaRuntime(3600).replacingURL("magnet:?xt=urn:btih:aa&dn=x.mkv").mediaRuntime == 3600, "runtime survives replacingURL")

        check(StreamBandwidth.fit(bitrate: 72 * mbit, connection: 27 * mbit) == .exceedsConnection, "72 on 27")
        check(StreamBandwidth.fit(bitrate: 22 * mbit, connection: 27 * mbit) == .fits, "22 on 27 (85 % = 22.95)")
        check(StreamBandwidth.fit(bitrate: 24 * mbit, connection: 27 * mbit) == .exceedsConnection, "24 on 27")
        check(StreamBandwidth.fit(bitrate: 72 * mbit, connection: nil) == .heavy, "72, connection unknown")
        check(StreamBandwidth.fit(bitrate: 35 * mbit, connection: nil) == .fits, "35, connection unknown")
        check(StreamBandwidth.fit(bitrate: nil, connection: 27 * mbit) == .unknown, "no estimate")
        check(StreamBandwidth.fit(bitrate: 72 * mbit, connection: 200 * mbit) == .fits, "fast connection")

        let remux2160 = episodeTorrent("Game.of.Thrones.S01E01.2160p.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos-FGT.mkv", "31.07 GB", seeds: 60, hash: "01")
        let x265_2160 = episodeTorrent("Game.of.Thrones.S01E01.2160p.UHD.BluRay.x265-SCOTLUHD.mkv", "11.74 GB", seeds: 50, hash: "02")
        let psa1080 = episodeTorrent("Game.of.Thrones.S01E01.Winter.Is.Coming.1080p.10bit.BluRay.6CH.x265.HEVC-PSA.mkv", "1.08 GB", seeds: 841, hash: "03")
        let lumi1080 = episodeTorrent("Game.of.Thrones.S01E01.1080p.BluRay.x265.10bit.6CH.ReEnc-LUMI.mkv", "2.36 GB", seeds: 372, hash: "04")
        let remux1080 = episodeTorrent("Game.of.Thrones.S01E01.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1-FGT.mkv", "14.62 GB", seeds: 10, hash: "05")
        let oft1080 = episodeTorrent("Game of Thrones S01E01 Winter Is Coming 1080p BluRay x264-OFT.mkv", "2.67 GB", seeds: 32, hash: "06")
        let candidates = [remux2160, x265_2160, psa1080, lumi1080, remux1080, oft1080]
        let tagged = candidates.withMediaRuntime(of: Episode(show: showWith(runtime: 61)))
        check(tagged.allSatisfy { $0.mediaRuntime == 3660 }, "tagged with the show's runtime")
        check(near(mbps(tagged[0].estimatedBitrate), 72.9, 0.01), "remux ≈ 72.9 Mb/s")
        let measured = 3.41e6   // the remux's measured input rate in the user's log (≈ 27 Mb/s)

        // Before (no estimate possible): the 2160p remux, healthy and best scored, wins — unchanged.
        let before = Torrent.balancedPick(from: candidates, capabilities: caps, connection: measured)
        check(before?.url == remux2160.url, "no runtime: behaviour unchanged (remux) — got \(before?.quality ?? "nil")")
        check(Torrent.balancedPick(from: tagged, capabilities: caps, connection: 1_000 * mbit)?.url == remux2160.url, "fast connection: the remux")

        // Measured 27 Mb/s: no 2160p fits (the x265 is 27.4 Mb/s > 23 Mb/s) → a light, healthy 1080p.
        let pick27 = Torrent.balancedPick(from: tagged, capabilities: caps, connection: measured)
        check(pick27 != nil && pick27!.qualityValue == .hd1080 && pick27!.url != remux1080.url
              && mbps(pick27!.estimatedBitrate) < 23, "27 Mb/s: a light 1080p, got \(pick27?.quality ?? "nil") \(mbps(pick27?.estimatedBitrate))")
        check(pick27?.bandwidthFit(connection: measured) == .fits, "the pick fits")
        check(tagged[0].bandwidthFit(connection: measured) == .exceedsConnection && tagged[4].bandwidthFit(connection: measured) == .exceedsConnection,
              "both remuxes flagged")

        // Unknown connection: the remux (> 40 Mb/s) is heavy, the 27 Mb/s 2160p x265 is not.
        let pickUnknown = Torrent.balancedPick(from: tagged, capabilities: caps, connection: nil)
        check(pickUnknown?.url == x265_2160.url, "unknown connection: the light 2160p, got \(pickUnknown?.quality ?? "nil")")

        // No lighter HEALTHY release: the heavy one stays the pick.
        let thin = episodeTorrent("Game.of.Thrones.S01E01.1080p.WEB.x264.mkv", "1.5 GB", seeds: 3, hash: "07")
        let onlyHeavy = [remux2160, thin].withMediaRuntime(3660)
        check(Torrent.balancedPick(from: onlyHeavy, capabilities: caps, connection: measured)?.url == remux2160.url,
              "only heavy releases are healthy: keep the remux")
        // Nothing healthy at all: the most-seeded clean one, as before the bandwidth
        // rule (review: a 0-seed light release must never win over a seeded heavy one);
        // lightness breaks a tie of seeds.
        let thinRemux = episodeTorrent("Game.of.Thrones.S01E01.2160p.BluRay.REMUX.HEVC.TrueHD.Atmos-X.mkv", "31 GB", seeds: 9, hash: "08")
        check(Torrent.balancedPick(from: [thinRemux, thin].withMediaRuntime(3660), capabilities: caps, connection: measured)?.url == thinRemux.url,
              "nothing healthy: most seeded (as before)")
        let thinTie = episodeTorrent("Game.of.Thrones.S01E01.1080p.WEB.x264-T.mkv", "1.5 GB", seeds: 9, hash: "0a")
        check(Torrent.balancedPick(from: [thinRemux, thinTie].withMediaRuntime(3660), capabilities: caps, connection: measured)?.url == thinTie.url,
              "nothing healthy, same seeds: the light one")
        // review-logic case: episode, connection unknown, 0-seed 720p vs 30-seed 2160p (46 Mb/s).
        let dead720 = episodeTorrent("Show.S01E01.720p.WEB.x264-D.mkv", "0.47 GB", seeds: 0, hash: "0b")
        let seeded2160 = episodeTorrent("Show.S01E01.2160p.WEB.HEVC-E.mkv", "19.6 GB", seeds: 30, hash: "0c")
        check(Torrent.balancedPick(from: [dead720, seeded2160].withMediaRuntime(3660), capabilities: caps, connection: nil)?.url == seeded2160.url,
              "never a 0-seed light release over a seeded heavy one")
        // review-logic case: 8 Mb/s measured, 1080p 1 seed (1.9 Mb/s) vs 1080p 8 seeds (10.7 Mb/s): the 8-seed one, as before.
        let oneSeed = episodeTorrent("Movie.2020.1080p.WEB.x264-A.mkv", "1.6 GB", seeds: 1, hash: "0d")
        let eightSeeds = episodeTorrent("Movie.2020.1080p.BluRay.x264-B.mkv", "9.0 GB", seeds: 8, hash: "0e")
        check(Torrent.balancedPick(from: [oneSeed, eightSeeds].withMediaRuntime(7200), capabilities: caps, connection: 1e6)?.url == eightSeeds.url,
              "fallback: most seeded as before")
        check(Torrent.balancedPick(from: [thinRemux, thin], capabilities: caps, connection: measured)?.url == thinRemux.url,
              "nothing healthy, no runtime: unchanged (most seeded)")
        // A penalty (AV1 without hardware decode: it stutters too; DV-only: wrong
        // colours; CAM) weighs more than the weight: the clean heavy release wins
        // over a penalized light one (pools: clean+light, clean, light, all).
        let av1 = episodeTorrent("Game.of.Thrones.S01E01.1080p.AV1.Opus-X.mkv", "0.9 GB", seeds: 200, hash: "09")
        check(Torrent.balancedPick(from: [remux2160, av1].withMediaRuntime(3660), capabilities: caps, connection: measured)?.url == remux2160.url,
              "clean heavy over penalized light")
        let cleanLight = episodeTorrent("Game.of.Thrones.S01E01.1080p.BluRay.x264-C.mkv", "2.2 GB", seeds: 30, hash: "0f")
        check(Torrent.balancedPick(from: [remux2160, av1, cleanLight].withMediaRuntime(3660), capabilities: caps, connection: measured)?.url == cleanLight.url,
              "clean and light first")
        check(Torrent.balancedPick(from: [remux2160, av1], capabilities: caps, connection: measured)?.url == remux2160.url,
              "no runtime: clean first as before")
        // A season pack without file information (whole size) never counts as heavy.
        let pack = Torrent(url: "magnet:?xt=urn:btih:10&dn=Game.of.Thrones.S01.2160p.BluRay.REMUX-X", quality: "2160p REMUX", seeds: 90, size: "310 GB")
        check(pack.withMediaRuntime(3660).bandwidthFit(connection: measured) == .unknown, "pack: unknown")

        // MARK: 6. Listing order and merge

        let heavy1080 = episodeTorrent("Game.of.Thrones.S01E01.1080p.BluRay.REMUX.HEVC.TrueHD.Atmos-Y.mkv", "14 GB", seeds: 80, hash: "11")
        let light1080 = episodeTorrent("Game.of.Thrones.S01E01.1080p.BluRay.x264.AAC-Z.mkv", "2 GB", seeds: 40, hash: "12")
        check(Torrent.precedesInListing(heavy1080, light1080, capabilities: caps, connection: measured), "no runtime: score order as before")
        check(Torrent.precedesInListing(light1080.withMediaRuntime(3660), heavy1080.withMediaRuntime(3660), capabilities: caps, connection: measured),
              "runtime: the light healthy one first")
        check(!Torrent.precedesInListing(heavy1080.withMediaRuntime(3660), light1080.withMediaRuntime(3660), capabilities: caps, connection: measured),
              "strict order")
        check(Torrent.precedesInListing(heavy1080.withMediaRuntime(3660), light1080.withMediaRuntime(3660), capabilities: caps, connection: 1_000 * mbit),
              "fast connection: score order")

        // Merge keeps the light 2160p when the slots are contested by heavy remuxes. The merge
        // reads the device's capabilities: those of an HDR, Dolby Vision display, whatever this
        // Mac's display does (asleep, it is not HDR-eligible: the remuxes were penalized).
        PlaybackCapabilities.pinnedForTesting = caps
        defer { PlaybackCapabilities.pinnedForTesting = nil }
        UserDefaults.standard.register(defaults: [StreamBandwidth.connectionEstimateDefaultsKey: measured])
        check(StreamBandwidth.connectionEstimate == measured, "estimate read from the defaults key")
        var aggregated: [Torrent] = []
        for i in 0..<4 {
            // 14 GB: under the merge's 15 GiB cap, still ≈ 33 Mb/s (heavy for 27 Mb/s).
            aggregated.append(episodeTorrent("Game.of.Thrones.S01E01.2160p.BluRay.REMUX.HEVC.DV.HDR.TrueHD.Atmos-R\(i).mkv", "14 GB",
                                             seeds: 100 + i, hash: "2\(i)"))
        }
        let light2160 = episodeTorrent("Game.of.Thrones.S01E01.2160p.WEB.x265.HDR.DDP5.1-L.mkv", "6 GB", seeds: 60, hash: "30")
        aggregated.append(light2160)
        let mergedPlain = TorrentioClient.merge([], with: aggregated)
        let mergedTagged = TorrentioClient.merge([], with: aggregated.withMediaRuntime(3660))
        print("merge 2160p: plain \(mergedPlain.map { $0.qualityLabel }) / tagged \(mergedTagged.map { $0.qualityLabel })")
        check(!mergedPlain.contains { $0.url == light2160.url }, "no runtime: the three remuxes take the slots, as before")
        check(mergedTagged.contains { $0.url == light2160.url }, "merge keeps the light 2160p")
        check(mergedTagged.allSatisfy { $0.mediaRuntime == 3660 }, "merge keeps the runtime")
        UserDefaults.standard.register(defaults: [StreamBandwidth.connectionEstimateDefaultsKey: 0.0])
        check(StreamBandwidth.connectionEstimate == nil, "0 = unknown")

        // MARK: 7. ConnectionSpeed core

        let tuning = ConnectionSpeed.Tuning()
        var meter = ConnectionSpeed.Meter()
        var t: TimeInterval = 100
        for _ in 0..<10 { meter.add(rate: 0, at: t, tuning: tuning); t += 0.5 }          // resolving metadata
        check(meter.activeSince == nil && meter.sustained == nil, "no download yet")
        for _ in 0..<12 { meter.add(rate: 0.5e6, at: t, tuning: tuning); t += 0.5 }      // ramp-up, warm-up
        check(meter.samples.isEmpty, "warm-up samples left out")
        var skipped = 0
        for _ in 0..<80 {                                                                  // 40 s at 3.41 MB/s
            if !meter.add(rate: 3.41e6, at: t, tuning: tuning) { skipped += 1 }
            if !meter.add(rate: 9e6, at: t + 0.1, tuning: tuning) { skipped += 1 }         // a piece post 0.1 s later: skipped
            t += 0.5
        }
        check(skipped == 80, "posts closer than 0.45 s skipped (\(skipped))")
        check(near(meter.sustained, 3.41e6, 0.005) && near(meter.peak, 3.41e6, 0.005), "steady 27 Mb/s: \(mbps(meter.sustained))")
        check(meter.samples.count <= 52, "window bounded: \(meter.samples.count)")
        for _ in 0..<120 { meter.add(rate: 1.2e6, at: t, tuning: tuning); t += 0.5 }     // bounded window full: playback rate
        check(near(meter.sustained, 1.2e6, 0.005) && near(meter.peak, 3.41e6, 0.005), "throttled: sustained follows, the peak stays")
        t += 30                                                                             // silence (seek, pause)
        meter.add(rate: 2e6, at: t, tuning: tuning)
        check(meter.samples.isEmpty && meter.sustained == nil && near(meter.peak, 3.41e6, 0.005), "a gap restarts the window, keeps the peak")
        var short = ConnectionSpeed.Meter()
        for i in 0..<24 { short.add(rate: 5e6, at: Double(i) * 0.5, tuning: tuning) }   // 12 s stream
        check(short.peak == nil, "a 12 s stream measures nothing")

        var history = ConnectionSpeed.History()
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for (i, rate) in [27.0, 30, 5, 25].enumerated() {
            history.record(id: "s\(i)", rate: rate * mbit, date: base.addingTimeInterval(Double(i)), limit: 12)
        }
        check(near(history.estimate(at: base, tuning: tuning), 30 * mbit, 1e-9), "90th percentile of 5/25/27/30 = 30: \(mbps(history.estimate(at: base, tuning: tuning)))")
        var p75 = tuning; p75.percentile = 0.75
        check(near(history.estimate(at: base, tuning: p75), 27 * mbit, 1e-9), "75th percentile = 27")
        history.record(id: "s2", rate: 6 * mbit, date: base, limit: 12)
        check(history.entries.count == 4 && history.entries.contains { $0.id == "s2" && near($0.rate, 6 * mbit, 1e-9) }, "a stream's entry updates in place")
        var decayed = ConnectionSpeed.History()
        decayed.record(id: "old", rate: 100 * mbit, date: base.addingTimeInterval(-60 * day), limit: 12)
        decayed.record(id: "new", rate: 27 * mbit, date: base, limit: 12)
        check(near(decayed.estimate(at: base, tuning: tuning), 27 * mbit, 1e-9), "recent streams weigh more")
        check(decayed.estimate(at: base.addingTimeInterval(200 * day), tuning: tuning) == nil, "older than 90 days: unknown")
        var capped = ConnectionSpeed.History()
        for i in 0..<20 { capped.record(id: "c\(i)", rate: Double(i + 1) * mbit, date: base.addingTimeInterval(Double(i)), limit: 12) }
        check(capped.entries.count == 12 && capped.entries.first?.id == "c8", "newest 12 kept")
        check(ConnectionSpeed.History(propertyList: capped.propertyList).entries == capped.entries, "property list round trip")
        check(ConnectionSpeed.History().estimate(at: base, tuning: tuning) == nil, "empty: unknown")

        // The class, on a throwaway defaults suite.
        let suiteName = "com.popcorntime.tests.bandwidth"
        let suite = throwawayDefaults(suiteName)
        var clockNow: TimeInterval = 1_000
        let speed = ConnectionSpeed(defaults: suite, clock: { clockNow }, now: { base })
        check(speed.estimate == nil && speed.currentSustainedRate == nil, "fresh: unknown")
        let streamA = NSObject(), streamB = NSObject()
        for i in 0..<120 {
            clockNow = 1_000 + Double(i) * 0.5
            speed.record(rate: 3.41e6, from: streamA)
            speed.record(rate: 1.0e6, from: streamB)
        }
        check(near(speed.sustainedRate(of: streamA), 3.41e6, 0.005) && near(speed.sustainedRate(of: streamB), 1.0e6, 0.005), "streams measured apart")
        check(near(speed.currentSustainedRate, 1.0e6, 0.005), "current = the last reporter")
        check(near(speed.estimate, 3.41e6, 0.005), "estimate (p90 of 27 and 8 Mb/s) published: \(mbps(speed.estimate))")
        check(near(suite.double(forKey: StreamBandwidth.connectionEstimateDefaultsKey), 3.41e6, 0.005), "under the PopcornKit key")
        check(ConnectionSpeed(defaults: suite, now: { base }).estimate == speed.estimate
              && ConnectionSpeed.History(propertyList: suite.array(forKey: ConnectionSpeed.historyDefaultsKey)).entries.count == 2, "persisted")
        clockNow += 10
        check(speed.currentSustainedRate == nil, "no report for 10 s: no current rate")
        let dead = NSObject()
        for i in 0..<120 { clockNow = 2_000 + Double(i) * 0.5; speed.record(rate: 20_000, from: dead) }
        check(ConnectionSpeed.History(propertyList: suite.array(forKey: ConnectionSpeed.historyDefaultsKey)).entries.count == 2,
              "a dead swarm (20 KB/s) is not recorded")
        // A thin swarm (fewer than 8 connected peers) measures itself, not the line.
        let thinSwarm = NSObject()
        for i in 0..<120 { clockNow = 3_000 + Double(i) * 0.5; speed.record(rate: 0.3e6, from: thinSwarm, peers: 3) }
        check(near(speed.sustainedRate(of: thinSwarm), 0.3e6, 0.005)
              && ConnectionSpeed.History(propertyList: suite.array(forKey: ConnectionSpeed.historyDefaultsKey)).entries.count == 2,
              "thin swarm (3 peers): measured for its stream, not recorded for the connection")
        let wellConnected = NSObject()
        for i in 0..<120 { clockNow = 4_000 + Double(i) * 0.5; speed.record(rate: 5e6, from: wellConnected, peers: 25) }
        check(ConnectionSpeed.History(propertyList: suite.array(forKey: ConnectionSpeed.historyDefaultsKey)).entries.count == 3,
              "well connected (25 peers): recorded")
        // Several recent thin swarms no longer drag the estimate down (review: 40/48 Mb/s then four 2–3 Mb/s swarms gave 3.2 Mb/s).
        let mixedName = "com.popcorntime.tests.bandwidth-mixed"
        let mixedSuite = throwawayDefaults(mixedName)
        var mixedNow: TimeInterval = 0
        let mixed = ConnectionSpeed(defaults: mixedSuite, clock: { mixedNow }, now: { base })
        for (k, (rate, peers)) in [(5.0e6, 30), (6.0e6, 30), (0.3e6, 3), (0.35e6, 2), (0.4e6, 4), (0.25e6, 1)].enumerated() {
            let stream = NSObject()
            for i in 0..<120 { mixedNow = Double(k) * 1_000 + Double(i) * 0.5; mixed.record(rate: rate, from: stream, peers: peers) }
        }
        check(near(mixed.estimate, 6.0e6, 0.005), "thin swarms ignored: estimate 48 Mb/s, got \(mbps(mixed.estimate))")
        discardDefaults(mixedSuite, mixedName)
        // DEBUG verification runs (loopback swarm): measured in memory, nothing written.
        let quietName = "com.popcorntime.tests.bandwidth-quiet"
        let quietSuite = throwawayDefaults(quietName)
        var quietNow: TimeInterval = 0
        let quiet = ConnectionSpeed(defaults: quietSuite, persists: false, clock: { quietNow }, now: { base })
        let loopback = NSObject()
        for i in 0..<120 { quietNow = Double(i) * 0.5; quiet.record(rate: 11e6, from: loopback, peers: 1) }
        quiet.start()
        // (The registration domain is process-wide: look at the suite's own domain.)
        check(near(quiet.sustainedRate(of: loopback), 11e6, 0.005) && (quietSuite.persistentDomain(forName: quietName) ?? [:]).isEmpty,
              "persists: false writes nothing: \(quietSuite.persistentDomain(forName: quietName) ?? [:])")
        discardDefaults(quietSuite, quietName)
        speed.forget()
        check(speed.estimate == nil && suite.double(forKey: StreamBandwidth.connectionEstimateDefaultsKey) == 0
              && suite.array(forKey: ConnectionSpeed.historyDefaultsKey) == nil, "forget")
        // Concurrency smoke test.
        let objects = (0..<8).map { _ in NSObject() }
        DispatchQueue.concurrentPerform(iterations: 8) { k in
            for i in 0..<2_000 { speed.record(rate: 2e6, from: objects[k], at: 5_000 + Double(i) * 0.5) }
            _ = speed.currentSustainedRate
            _ = speed.estimate
        }
        check(objects.allSatisfy { near(speed.sustainedRate(of: $0), 2e6, 0.005) }, "concurrent records")
        discardDefaults(suite, suiteName)

        // MARK: 8. Picker texts (development language)

        check(tagged[0].bitrateLabel == "≈ 73 Mb/s", "label \(tagged[0].bitrateLabel ?? "nil")")
        check(tagged[0].bandwidthWarning(connection: measured) == "May stutter: your downloads reach about 27 Mb/s", "warning \(tagged[0].bandwidthWarning(connection: measured) ?? "nil")")
        check(tagged[0].bandwidthWarning(connection: nil) == "Very heavy: may stutter", "heavy warning")
        check(tagged[2].bandwidthWarning(connection: measured) == nil, "light: no warning")
        check(pair(5.4, 4.6) == "5.4 / 4.6" && pair(2.44, 2.0) == "2.5 / 2" && pair(1.2, 0.6) == "1.2 / 0.6" && pair(10.1, 9.8) == "11 / 9.8"
              && pair(72.9, 27.3) == "73 / 27", "deficit numbers never equal: \(pair(5.4, 4.6)), \(pair(2.44, 2.0)), \(pair(1.2, 0.6)), \(pair(10.1, 9.8)), \(pair(72.9, 27.3))")
        check(candidates[0].bitrateLabel == nil && candidates[0].bandwidthWarning(connection: measured) == nil, "no runtime: nothing shown")
    }
}
