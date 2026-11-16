//
//  UpNextResumeReleaseTests.swift
//  PopcornTimeTests
//
//  The release a stream plays, as its context finds it (PlaybackStreamContext.playingRelease).
//  The first device session of 5.3.0 played « Resume » as a NAMELESS torrent: the remembered
//  release is a SHORT magnet that the episode's list never holds by URL, so the context fell
//  back on a bare Torrent(url:) — « The Kingsroad — , 21 release(s) known », no bitrate, no
//  file name, a Next Episode card reading « ? · même pack », and the remembered release saved
//  again without its label. The fix: the list's entry by URL, then by info-hash (one with a
//  file name first, the passed one's file name kept), else the passed torrent, else a bare one;
//  the list told apart by info-hash. A chained start of the same pack (a copy without a file
//  name) still gets the listed entry's file name.
//

import XCTest
import Foundation
@testable import PopcornKit

final class UpNextResumeReleaseTests: CheckedTestCase {

    /// `UpNextText.versionLine` as the English app shows it (the test bundle has no strings:
    /// `.localized` gives the key back), with its « ? » for an empty label.
    static func english(_ rule: UpNextChoice.Rule, _ label: String) -> String? {
        let folder = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PopcornTime/en.lproj/Localizable.strings")
        let strings = NSDictionary(contentsOf: folder) as? [String: String] ?? [:]
        guard rule == .samePack, let format = strings["UpNext.SamePack"],
              UpNextText.versionLine(rule: rule, label: label) == "UpNext.SamePack".localized else { return nil }
        return String(format: format, label.isEmpty ? "?" : label)
    }

    override func tearDown() {
        PlaybackReleaseRegistry.removeAll()
        super.tearDown()
    }

    private let packHash = "e8230895bc1b5a0f6e2d4c3b2a19087f6e5d4c3b"
    private let otherHash = "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"
    private let e02File = "Bench.Show.S01E02.2160p.HEVC-GRP.mkv"

    /// The pack as the provider lists it for E02: every tracker, the episode's own file.
    private var listed: Torrent {
        let trackers = (1...8).map { "&tr=udp%3A%2F%2Ftracker\($0).example%3A\(1000 + $0)" }.joined()
        return Torrent(url: "magnet:?xt=urn:btih:\(packHash)&dn=Bench.Show.S01.2160p.HEVC-GRP" + trackers,
                       quality: "2160p HEVC — T4P", seeds: 40, size: "3.2 GB", fileName: e02File)
    }

    private var lighter: Torrent {
        Torrent(url: "magnet:?xt=urn:btih:\(otherHash)&dn=Bench.Show.S01E02.1080p.HEVC-ABC.mkv",
                quality: "1080p HEVC — Torrentio", seeds: 90, size: "900 MB")
    }

    /// What Continue Watching remembered of the E02 stream (« rl »), as « Resume » plays it.
    private var remembered: RememberedRelease {
        let files = PackFiles(names: ["P/Bench.Show.S01E01.2160p.HEVC-GRP.mkv", "P/\(e02File)", "P/Bench.Show.S01E03.2160p.HEVC-GRP.mkv"],
                              sizes: [3, 3, 3])
        return RememberedRelease(torrent: listed, files: files, playedIndex: 1, at: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testResumeWithTheShortLinkFindsTheListedRelease() {
        let resume = remembered.torrent
        check(resume.url != listed.url, "« Resume » streams the short link, not the listed one", resume.url)
        eq(MagnetLink.sourceKey(of: resume.url), packHash, "the same info-hash")
        let list = [lighter, listed]
        let found = PlaybackStreamContext.playingRelease(sourceURL: resume.url, passed: resume, list: list)
        eq(found.playing.qualityLabel, "2160p HEVC", "the release's label, not an empty one")
        eq(found.playing.sourceLabel, "T4P", "and its source")
        eq(found.sources.count, 2, "the count of known releases does not grow by one (log:757 read 21 for 20)")
        eq(found.playing.releaseFileName, e02File, "the file name: the hint of the file selection")
        check(found.playing.withMediaRuntime(3000).estimatedBitrate != nil, "a bitrate (the ≈ Mb/s of the stream context line)")
        eq(Self.english(.samePack, found.playing.qualityLabel), "2160p HEVC · same pack",
           "the Next Episode card's line, never « ? · same pack »")

        // A caller that passes nothing (a safety net): the info-hash still finds it.
        let unpassed = PlaybackStreamContext.playingRelease(sourceURL: resume.url, passed: nil, list: list)
        eq(unpassed.playing.qualityLabel, "2160p HEVC", "found by info-hash")
        eq(unpassed.sources.count, 2, "not counted twice")

        // The old lookup (exact URL, else a bare torrent) for comparison: what the device showed.
        let bare = Torrent(url: resume.url)
        eq(bare.qualityLabel, "", "the bare torrent of log:757 has no label")
        eq(Self.english(.samePack, bare.qualityLabel), "? · same pack", "hence « ? · même pack »")
    }

    func testTheListedEntryKeepsThePassedFileName() {
        // The list holds the release without a file name (a provider that names the pack only).
        let packOnly = Torrent(url: listed.url, quality: "2160p HEVC — TPB", seeds: 10, size: "30 GB")
        let resume = remembered.torrent
        let found = PlaybackStreamContext.playingRelease(sourceURL: resume.url, passed: resume, list: [packOnly])
        eq(found.playing.qualityLabel, "2160p HEVC", "the listed label")
        eq(found.playing.sourceLabel, "TPB", "the listed entry")
        eq(found.playing.releaseFileName, e02File, "with the remembered file name")
        eq(found.sources.count, 1, "one release")
        eq(found.playing.withMediaRuntime(3000).estimatedBitrate, nil,
           "the pack's 30 GB is not the file's: no bitrate (not pack ÷ runtime)")
        eq(found.playing.size, nil, "the pack's size is dropped")
        // An entry whose own name is the episode's file keeps its size (it was the file's).
        let fileEntry = Torrent(url: "magnet:?xt=urn:btih:\(otherHash)&dn=Bench.Show.S01E02.1080p.HEVC-ABC.mkv",
                                quality: "1080p HEVC — Torrentio", seeds: 9, size: "900 MB")
        eq(fileEntry.withReleaseFileName("Bench.Show.S01E02.1080p.HEVC-ABC.mkv").size, "900 MB", "a file's size is kept")
        // Two entries of the same hash: the one that names the file wins.
        let both = PlaybackStreamContext.playingRelease(sourceURL: resume.url, passed: nil, list: [packOnly, listed])
        eq(both.playing.releaseFileName, e02File, "the entry with a file name first")
        eq(both.playing.sourceLabel, "T4P", "that one")
    }

    func testAChainedStartOfTheSamePackKeepsTheListedFileName() {
        // The plan's torrent: the pack again, without a file name (UpNextPlanner.packTorrent).
        let e01 = Torrent(url: listed.url, quality: "2160p HEVC — T4P", seeds: 40, size: "3.2 GB",
                          fileName: "Bench.Show.S01E01.2160p.HEVC-GRP.mkv")
        let plan = UpNextPlanner.packTorrent(e01, fileSize: nil)
        eq(plan.releaseFileName, nil, "the plan's torrent names no file")
        let found = PlaybackStreamContext.playingRelease(sourceURL: plan.url, passed: plan, list: [lighter, listed])
        eq(found.playing.releaseFileName, e02File, "E02's own file, from the list (the log:642 hint)")
        eq(found.playing.qualityLabel, "2160p HEVC", "its label")
        eq(found.sources.count, 2, "no release added")
    }

    func testAfterARelaunchTheRememberedReleaseBringsItsLabel() {
        // The episode's list is empty (nothing asked yet since the launch).
        let resume = remembered.torrent
        let found = PlaybackStreamContext.playingRelease(sourceURL: resume.url, passed: resume, list: [])
        eq(found.playing.qualityLabel, "2160p HEVC", "the remembered label")
        eq(found.playing.releaseFileName, e02File, "the remembered file")
        eq(found.playing.size, "3.2 GB", "its size")
        check(found.playing.tags.contains(.hevc), "its tags", "\(found.playing.tags)")
        eq(found.sources.count, 1, "listed once")
        // Nothing passed, nothing listed: a bare torrent, as before.
        let unknown = PlaybackStreamContext.playingRelease(sourceURL: resume.url, passed: nil, list: [])
        eq(unknown.playing.url, resume.url, "the URL alone")
        eq(unknown.sources.count, 1, "listed once")
    }

    func testTheRememberedReleaseIsNotOverwrittenWithAnEmptyOne() {
        let id = "tt0000201-s1e2"
        let found = PlaybackStreamContext.playingRelease(sourceURL: remembered.torrent.url, passed: remembered.torrent, list: [lighter, listed])
        // What `attach` notes: every save of the title stores it (Continue Watching « rl »).
        PlaybackReleaseRegistry.note(found.playing, for: id)
        let saved = PlaybackReleaseRegistry.current(for: id)
        eq(saved?.quality, "2160p HEVC", "a label, not nil")
        eq(saved?.provider, "T4P", "its source")
        eq(saved?.sourceKey, packHash, "the same release")
        eq(saved?.torrent.qualityLabel, "2160p HEVC", "the next « Resume » reads it again")
    }

    func testTheLighterReleaseKeepsItsOwnLabel() {
        // « Lighter version » (onSwitch) plays another listed release, passed as such.
        let found = PlaybackStreamContext.playingRelease(sourceURL: lighter.url, passed: lighter, list: [listed, lighter])
        eq(found.playing.qualityLabel, "1080p HEVC", "the lighter release's label")
        eq(found.playing.sourceLabel, "Torrentio", "its source")
        eq(found.sources.count, 2, "no release added")
    }

    func testAPackOfUnmarkedFilesOpensTheRememberedOne() {
        // Absolute numbering, no marker: E02 is not the largest file.
        let names = ["Show - 01.mkv", "Show - 02.mkv", "Show - 03.mkv"]
        let sizes: [Int64] = [900, 500, 900]
        let unmarked = Torrent(url: "magnet:?xt=urn:btih:\(packHash)&dn=Show&tr=udp%3A%2F%2Ft.example%3A1&tr=udp%3A%2F%2Fu.example%3A2",
                               quality: "1080p — T4P", seeds: 5, size: "500 MB", fileName: "Show - 02.mkv")
        let rl = RememberedRelease(torrent: unmarked, files: PackFiles(names: names, sizes: sizes), playedIndex: 1, at: Date())
        eq(rl.fileName, "Show - 02.mkv", "the file remembered")
        let found = PlaybackStreamContext.playingRelease(sourceURL: rl.torrent.url, passed: rl.torrent, list: [])
        let wanted = WantedFile(season: 1, episode: 2, fileName: found.playing.releaseFileName)
        eq(wanted?.choice(fileNames: names, fileSizes: sizes, torrentName: "Show"), .file(1), "« Show - 02.mkv »: file 1")
        // Without the file name (the device's bare torrent), the usual rule: not E02's file.
        let nameless = WantedFile(season: 1, episode: 2, fileName: nil)
        let choice = nameless?.choice(fileNames: names, fileSizes: sizes, torrentName: "Show")
        check(choice != .file(1), "without the name, E02 is not found by itself", "\(String(describing: choice))")
    }
}
