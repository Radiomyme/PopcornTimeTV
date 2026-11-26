//
//  DownloadsCatalogTests.swift
//  PopcornTimeTests
//
//  The Apple TV's Downloads page (DownloadsCatalog): each row's status line with only what is
//  known, the percentage rounded down, the time left, the order of the rows, when a progress
//  is saved, which folders of the download directory nothing owns. No PopcornTorrent, no disk.
//

import XCTest
import Foundation

final class DownloadsCatalogTests: CheckedTestCase {

    /// The English texts of Localizable.strings, as the page reads them.
    private static let english: [String: String] = [
        "Downloads.Episode": "S%1$@ E%2$@",
        "Downloads.Status.Waiting": "Looking for sources…",
        "Downloads.Status.Speed": "%@/s",
        "Downloads.Status.TimeLeft": "about %@ left",
        "Downloads.Status.Of": "%1$@ of %2$@",
        "Downloads.Status.Paused": "Paused",
        "Downloads.Status.Failed": "Failed",
        "Downloads.Storage": "Downloads take %1$@ · %2$@ free",
        "Downloads.Storage.Used": "Downloads take %@",
        "Downloads.Storage.Free": "%@ free on this Apple TV",
        "Downloads.Failure.NoSpace": "not enough space",
        "Downloads.Failure.NoSpaceAmount": "not enough space (%@ to free)",
        "Downloads.Failure.File": "the file could not be written",
        "Downloads.Failure.NoEpisode": "this episode is not in the release",
        "Downloads.Failure.Other": "the download stopped",
        "Downloads.NoSpace.Message": "This download needs %1$@, and %2$@ is free on this Apple TV.",
    ]

    private let text = DownloadsText(locale: Locale(identifier: "en_US"), localize: { DownloadsCatalogTests.english[$0] ?? $0 })

    private func movie(_ id: String = "tt1", _ title: String = "Halloween", phase: DownloadsEntry.Phase,
                       progress: Double = 0, speed: Int64 = 0, total: Int64? = nil) -> DownloadsEntry {
        DownloadsEntry(id: id, kind: .movie, title: title, artworkURL: nil, phase: phase,
                       progress: progress, bytesPerSecond: speed, totalBytes: total)
    }

    private func episode(_ id: String, show: String, season: Int, number: Int, title: String,
                         phase: DownloadsEntry.Phase = .finished) -> DownloadsEntry {
        DownloadsEntry(id: id, kind: .episode(show: show, season: season, number: number), title: title,
                       artworkURL: nil, phase: phase, progress: 1, bytesPerSecond: 0, totalBytes: 1_000_000_000)
    }

    // MARK: Status line

    func testADownloadSaysEverythingKnown() {
        let entry = movie(phase: .downloading, progress: 0.42, speed: 3_100_000, total: 2_410_000_000)
        let done = text.bytes(Int64(2_410_000_000 * 0.42))
        let expected = "42% · \(text.bytes(3_100_000))/s · about \(text.timeLeft(of: entry)!) left · \(done) of \(text.bytes(2_410_000_000))"
        XCTAssertEqual(text.status(of: entry), expected)
        // 1.4 GB left at 3.1 MB/s: 7 to 8 minutes.
        XCTAssertEqual(DownloadsCatalog.secondsLeft(of: entry)!, 451, accuracy: 1)
    }

    func testOnlyWhatIsKnown() {
        // No rate yet: no speed, no time left; no size: no amounts.
        XCTAssertEqual(text.status(of: movie(phase: .downloading, progress: 0.05)), "5%")
        XCTAssertEqual(text.status(of: movie(phase: .downloading, progress: 0.05, total: 2_000_000_000)),
                       "5% · \(text.bytes(100_000_000)) of \(text.bytes(2_000_000_000))")
        XCTAssertNil(text.timeLeft(of: movie(phase: .downloading, progress: 0.5, speed: 1_000_000)))
    }

    func testPausedWaitingFailedAndFinished() {
        XCTAssertEqual(text.status(of: movie(phase: .paused, progress: 0.73, total: 1_640_000_000)),
                       "Paused · 73% · \(text.bytes(1_197_200_000)) of \(text.bytes(1_640_000_000))")
        XCTAssertEqual(text.status(of: movie(phase: .waiting)), "Looking for sources…")
        XCTAssertEqual(text.status(of: movie(phase: .waiting, progress: 0.3)), "Looking for sources… · 30%")
        XCTAssertEqual(text.status(of: movie(phase: .failed("No space left. "))), "Failed — No space left.")
        XCTAssertEqual(text.status(of: movie(phase: .failed(nil))), "Failed")
        XCTAssertEqual(text.status(of: movie(phase: .failed("  "))), "Failed")
        XCTAssertEqual(text.status(of: movie(phase: .finished, total: 2_640_000_000)), text.bytes(2_640_000_000))
        XCTAssertEqual(text.status(of: movie(phase: .finished)), "")
    }

    func testThePercentageIsRoundedDown() {
        XCTAssertEqual(text.percent(0.996), "99%", "a file still downloading is not « 100 % »")
        // 0.08 stored in a plist as a Float reads back 0.0799999982.
        XCTAssertEqual(text.percent(Double(Float(0.08))), "8%")
        XCTAssertEqual(text.percent(1), "100%")
        XCTAssertEqual(text.percent(-1), "0%")
        // French: a space before the sign (a no-break one).
        let french = DownloadsText(locale: Locale(identifier: "fr_FR"), localize: { $0 }).percent(0.42)
        XCTAssertTrue(french.hasPrefix("42") && french.hasSuffix("%") && french.count == 4, french)
    }

    func testTheTimeLeft() {
        // Under a minute still says a minute; hours and minutes beyond an hour; nothing past two days.
        XCTAssertEqual(text.timeLeft(of: movie(phase: .downloading, progress: 0.99, speed: 10_000_000, total: 1_000_000_000)), "1 min")
        XCTAssertEqual(text.timeLeft(of: movie(phase: .downloading, progress: 0, speed: 1_000_000, total: 3_900_000_000)), "1 hr, 5 min")
        XCTAssertNil(text.timeLeft(of: movie(phase: .downloading, progress: 0, speed: 1_000, total: 18_400_000_000)))
    }

    func testAnEpisodeIsTitledByItsShow() {
        let entry = episode("e1", show: "MobLand", season: 1, number: 5, title: "Out of the Frying Pan")
        XCTAssertEqual(text.title(of: entry), "MobLand")
        XCTAssertEqual(text.subtitle(of: entry), "S1 E5 · Out of the Frying Pan")
        XCTAssertNil(text.subtitle(of: movie(phase: .finished)))
        // A show without a title: the episode's, and the code alone under it.
        let orphan = episode("e2", show: "", season: 2, number: 1, title: "Pilot")
        XCTAssertEqual(text.title(of: orphan), "Pilot")
        XCTAssertEqual(text.subtitle(of: orphan), "S2 E1")
    }

    func testStorageAndSpace() {
        XCTAssertEqual(text.storage(used: 3_400_000_000, free: 21_000_000_000),
                       "Downloads take \(text.bytes(3_400_000_000)) · \(text.bytes(21_000_000_000)) free")
        XCTAssertEqual(text.storage(used: 0, free: nil), "Downloads take \(text.bytes(0))")
        XCTAssertNil(text.spaceWarning(needed: 2_000_000_000, free: 10_000_000_000))
        XCTAssertNil(text.spaceWarning(needed: nil, free: 1), "an unknown size never blocks")
        // The margin: a download that would leave less than 500 MB free does not fit.
        XCTAssertNotNil(text.spaceWarning(needed: 2_000_000_000, free: 2_300_000_000))
        XCTAssertTrue(DownloadsCatalog.fits(needed: 2_000_000_000, free: 2_500_000_000))
    }

    func testTheRowsQuietLineLeavesThePercentageOut() {
        let entry = movie(phase: .downloading, progress: 0.42, speed: 3_100_000, total: 2_410_000_000)
        XCTAssertEqual(text.detail(of: entry),
                       "\(text.bytes(3_100_000))/s · about \(text.timeLeft(of: entry)!) left · \(text.bytes(Int64(2_410_000_000 * 0.42))) of \(text.bytes(2_410_000_000))")
        XCTAssertFalse(text.detail(of: entry).contains("%"))
        XCTAssertEqual(text.detail(of: movie(phase: .paused, progress: 0.5, total: 2_000_000_000)),
                       "Paused · \(text.bytes(1_000_000_000)) of \(text.bytes(2_000_000_000))")
        XCTAssertEqual(text.detail(of: movie(phase: .paused, progress: 0.5)), "Paused")
        XCTAssertEqual(text.detail(of: movie(phase: .waiting, progress: 0.3)), "Looking for sources…")
        XCTAssertEqual(text.detail(of: movie(phase: .failed("no space"))), "Failed — no space")
        XCTAssertEqual(text.episodeCode(of: episode("e", show: "MobLand", season: 1, number: 5, title: "Pilot")), "S1 E5")
        XCTAssertNil(text.episodeCode(of: movie(phase: .finished)))
    }

    func testTheStorageCaptionNeverSaysZero() {
        XCTAssertEqual(text.storageCaption(used: 0, free: 21_000_000_000), "\(text.bytes(21_000_000_000)) free on this Apple TV")
        XCTAssertEqual(text.storageCaption(used: 3_400_000_000, free: 21_000_000_000),
                       "Downloads take \(text.bytes(3_400_000_000)) · \(text.bytes(21_000_000_000)) free")
    }

    func testAFailureIsSaidShortlyInTheUILanguage() {
        XCTAssertEqual(text.failureReason(.notEnoughSpace(bytesToFree: 1_900_000_000)),
                       "not enough space (\(text.bytes(1_900_000_000)) to free)")
        XCTAssertEqual(text.failureReason(.notEnoughSpace(bytesToFree: nil)), "not enough space")
        XCTAssertEqual(text.failureReason(.fileError), "the file could not be written")
        XCTAssertEqual(text.failureReason(.episodeNotInTorrent), "this episode is not in the release")
        XCTAssertEqual(text.failureReason(.other(nil)), "the download stopped", "the engine's English sentence is never shown")
        XCTAssertEqual(text.failureReason(.other("La connexion Internet semble interrompue.")), "La connexion Internet semble interrompue.")
        XCTAssertEqual(text.failureSentence(.fileError), "The file could not be written")
        XCTAssertEqual(text.status(of: movie(phase: .failed(text.failureReason(.notEnoughSpace(bytesToFree: nil))))),
                       "Failed — not enough space")
        // What to free: the file, plus the margin, less what is free; nothing when it fits.
        XCTAssertEqual(DownloadsFailure.bytesToFree(fileSize: 2_000_000_000, free: 1_000_000_000), 1_500_000_000)
        XCTAssertNil(DownloadsFailure.bytesToFree(fileSize: 2_000_000_000, free: 9_000_000_000))
        XCTAssertNil(DownloadsFailure.bytesToFree(fileSize: nil, free: 1))
    }

    // MARK: Sections

    func testTheRowsOrder() {
        let entries = [
            movie("p", "Zodiac", phase: .paused, progress: 0.2),
            movie("f", "Alien", phase: .failed(nil)),
            movie("d", "Wolfs", phase: .downloading, progress: 0.1),
            movie("w", "Arrival", phase: .waiting),
            movie("m", "Heat", phase: .finished),
            episode("b3", show: "Black Doves", season: 1, number: 3, title: "Hunted"),
            episode("b1", show: "Black Doves", season: 1, number: 1, title: "Pilot"),
            episode("a2", show: "Andor", season: 2, number: 1, title: "One Year Later"),
            movie("c", "Casablanca", phase: .finished),
        ]
        let sections = DownloadsCatalog.sections(entries)
        XCTAssertEqual(sections.active.map(\.id), ["d", "w", "p", "f"], "running, waiting, paused, failed")
        XCTAssertEqual(sections.finished.map(\.id), ["a2", "b1", "b3", "c", "m"], "by title, a show's episodes in order")
        XCTAssertTrue(entries[2].isRunning)
        XCTAssertFalse(entries[0].isRunning)
        XCTAssertFalse(entries[3].isRunning, "a download still looking for sources has nothing to pause")
    }

    // MARK: Saving

    func testTheProgressIsSavedEveryFivePercentOrHalfAMinute() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(DownloadsCatalog.shouldSave(progress: 0.01, lastSavedProgress: nil, now: start, lastSaved: nil))
        XCTAssertFalse(DownloadsCatalog.shouldSave(progress: 0.04, lastSavedProgress: 0.01, now: start + 10, lastSaved: start))
        XCTAssertTrue(DownloadsCatalog.shouldSave(progress: 0.06, lastSavedProgress: 0.01, now: start + 10, lastSaved: start))
        XCTAssertTrue(DownloadsCatalog.shouldSave(progress: 0.02, lastSavedProgress: 0.01, now: start + 30, lastSaved: start))
    }

    // MARK: Orphan folders

    func testOnlyOldFoldersWithoutAPlistThatNoDownloadOwnsAreOrphans() {
        let now = Date(timeIntervalSince1970: 100_000)
        let old = now - 3600
        let folders: [DownloadsCatalog.Folder] = [
            .init(name: "Movie-1a2b", isDirectory: true, hasMetadata: true, modified: old),       // a download
            .init(name: "Stopped-3c4d", isDirectory: true, hasMetadata: false, modified: old),    // orphan
            .init(name: "Starting-5e6f", isDirectory: true, hasMetadata: false, modified: now - 60), // just started
            .init(name: "Resolving-7a8b", isDirectory: true, hasMetadata: false, modified: old),  // owned
            .init(name: "notes.txt", isDirectory: false, hasMetadata: false, modified: old),      // a file
            .init(name: ".hidden", isDirectory: true, hasMetadata: false, modified: old),
        ]
        XCTAssertEqual(DownloadsCatalog.orphans(folders, owned: ["Resolving-7a8b"], now: now), ["Stopped-3c4d"])
        XCTAssertTrue(DownloadsCatalog.isMetadataFile("Metadata-file-0.plist"))
        XCTAssertTrue(DownloadsCatalog.isMetadataFile("Metadata.plist"))
        XCTAssertFalse(DownloadsCatalog.isMetadataFile("Metadata-file-0.plist.tmp"))
        XCTAssertFalse(DownloadsCatalog.isMetadataFile("movie.mkv"))
    }
}
