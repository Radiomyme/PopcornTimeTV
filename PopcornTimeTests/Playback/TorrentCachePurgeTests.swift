//
//  TorrentCachePurgeTests.swift
//  PopcornTimeTests
//
//  TorrentCachePurge: the leftovers of earlier streams are renamed out of the way at once and
//  deleted afterwards; a stream that starts in between keeps what it creates.
//

import XCTest
import Foundation

final class TorrentCachePurgeTests: CheckedTestCase {

    private var tmp: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tmp = fm.temporaryDirectory.appendingPathComponent("PopcornTimeTests-purge-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: tmp)
        super.tearDown()
    }

    private func write(_ path: String, bytes: Int = 4096) {
        let url = tmp.appendingPathComponent(path)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes))
    }

    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: tmp.appendingPathComponent(path).path) }

    private func entries(_ path: String = "") -> [String] {
        ((try? fm.contentsOfDirectory(atPath: tmp.appendingPathComponent(path).path)) ?? []).sorted()
    }

    func testLeftoversAreSetAsideThenDeleted() {
        write("Downloads/aaaa1111/Movie.2160p.mkv", bytes: 200_000)
        write("Downloads/bbbb2222/Show.S01E02.mkv")
        write("remux-4F2A/vseg0.m4s", bytes: 50_000)
        write("remux-4F2A/a0seg0.m4s")
        write("remux-9C01/master.m3u8")
        write("PopcornSubtitles/x/fr.srt")      // not a leftover of a stream
        write("notes-remux-1/keep.txt")         // "remux-" is a prefix, not a part of the name
        write("other.tmp")

        let trash = TorrentCachePurge.setAside(in: tmp)
        check(trash != nil && trash?.lastPathComponent.hasPrefix(TorrentCachePurge.trashPrefix) == true, "the leftovers are moved into a purged- folder")
        eq(entries("Downloads"), [], "Downloads/ is empty at once (the folder itself stays)")
        check(!exists("remux-4F2A") && !exists("remux-9C01"), "the remux folders are gone from the temporary directory at once")
        check(exists("PopcornSubtitles/x/fr.srt") && exists("notes-remux-1/keep.txt") && exists("other.tmp"), "nothing else is touched")
        eq(entries(trash?.lastPathComponent ?? "?"), ["Downloads-aaaa1111", "Downloads-bbbb2222", "remux-4F2A", "remux-9C01"],
           "everything waits in the purged- folder")

        // The next stream starts before the deletion ran — the same torrent, a new remux.
        write("Downloads/aaaa1111/Movie.2160p.mkv", bytes: 1000)
        write("remux-NEW1/vseg0.m4s")

        let freed = TorrentCachePurge.deleteSetAside(in: tmp)
        check(freed >= 250_000, "the bytes freed are counted (allocated sizes)", "\(freed)")
        check(entries().allSatisfy { !$0.hasPrefix(TorrentCachePurge.trashPrefix) }, "the purged- folder is deleted")
        check(exists("Downloads/aaaa1111/Movie.2160p.mkv") && exists("remux-NEW1/vseg0.m4s"),
              "what the new stream created — under the same names — is untouched")
        check(exists("PopcornSubtitles/x/fr.srt") && exists("other.tmp"), "nor anything else")
    }

    func testNothingToPurge() {
        write("other.tmp")
        check(TorrentCachePurge.setAside(in: tmp) == nil, "no leftover: nothing set aside")
        eq(entries(), ["other.tmp"], "…and no empty purged- folder left behind")
        eq(TorrentCachePurge.deleteSetAside(in: tmp), 0, "nothing to delete")
        // A temporary directory without a Downloads folder, or missing altogether.
        check(TorrentCachePurge.setAside(in: tmp.appendingPathComponent("missing")) == nil, "a missing directory is not an error")
    }

    func testAFolderLeftByACrashIsDeletedByTheNextPurge() {
        // The app died between the rename and the deletion.
        write("purged-OLD/Downloads-cccc3333/film.mkv", bytes: 30_000)
        check(TorrentCachePurge.setAside(in: tmp) == nil, "nothing new to set aside")
        check(TorrentCachePurge.deleteSetAside(in: tmp) >= 30_000, "the folder left behind is deleted with the others")
        check(!exists("purged-OLD"), "gone")
    }

    func testTwoPurgesInARow() {
        write("Downloads/aaaa1111/a.mkv")
        let first = TorrentCachePurge.setAside(in: tmp)
        write("Downloads/dddd4444/b.mkv")
        let second = TorrentCachePurge.setAside(in: tmp)
        check(first != nil && second != nil && first != second, "each purge has its own folder")
        TorrentCachePurge.deleteSetAside(in: tmp)
        eq(entries(), ["Downloads"], "both are deleted; Downloads/ stays, empty")
        eq(entries("Downloads"), [], "")
    }
}
