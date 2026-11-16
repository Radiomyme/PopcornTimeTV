//
//  VLCDemuxChoiceTests.swift
//  PopcornTimeTests
//
//  BoundedStorageUX.vlcDemuxChoice: which Matroska demuxer VLC opens a stream with, in both
//  storage modes. At a position on a file that is not local up to the target: libavformat's
//  (it jumps through the Cues) — full storage too, where 5.2.0 left VLC's own demuxer read the
//  whole file up to a resume point at download speed. A start at 0:00 and every bounded row of
//  5.2.0 are unchanged; a file known to have no Cues keeps VLC's own in full storage (nothing
//  jumps without an index). Plus the facts the choice reads: `ownDemuxerReadsOnlyLocalData` and
//  `matroskaHead` (text subtitle tracks, a findable Cues element).
//

import XCTest
import Foundation

final class VLCDemuxChoiceTests: CheckedTestCase {

    private typealias Demux = BoundedStorageUX.VLCDemux

    private let textTrackCases: [Int?] = [nil, 0, 1, 3]
    private let cuesCases: [Bool?] = [nil, true, false]
    private let bools = [false, true]

    private func choice(matroska: Bool = true, bounded: Bool, atPosition: Bool, text: Int?, local: Bool,
                        cues: Bool?, onDisk: Bool? = nil) -> (Demux, why: String) {
        BoundedStorageUX.vlcDemuxChoice(isMatroska: matroska, isBounded: bounded, startsAtPosition: atPosition,
                                        textSubtitleTracks: text, ownReadsOnlyLocalData: local, hasCues: cues,
                                        everythingOnDisk: onDisk ?? local)
    }

    /// 5.2.0's rule for a bounded Matroska stream (BoundedStorageUX.vlcMediaOptions at tag
    /// 5.2.0), copied as it was: the rows that must not move.
    private func bounded520(text textTracks: Int?, atPosition: Bool, local: Bool) -> (avformat: Bool, why: String) {
        switch (textTracks, atPosition) {
        case (0?, _):
            return (true, "no text subtitle track")
        case (_?, true):
            if local {
                return (false, "keeps its \(textTracks ?? 0) text subtitle track(s); everything up to there is on disk")
            }
            return (true, "its \(textTracks ?? 0) text subtitle track(s) are lost: VLC's own demuxer would read deleted or missing data")
        case (_?, false):
            return (false, "keeps its \(textTracks ?? 0) text subtitle track(s); far seeks read through")
        case (nil, true):
            return (true, "tracks unknown; VLC's own demuxer would read deleted or missing data")
        case (nil, false):
            return (false, "tracks unknown")
        }
    }

    // MARK: The table

    func testOtherContainersKeepVLCAsItIs() {
        for bounded in bools { for atPosition in bools { for text in textTrackCases { for local in bools { for cues in cuesCases {
            let (demux, why) = choice(matroska: false, bounded: bounded, atPosition: atPosition, text: text, local: local, cues: cues)
            check(demux == .own && why == "not a Matroska file",
                  "not Matroska → VLC's own (bounded \(bounded), at position \(atPosition), text \(String(describing: text)))")
        } } } } }
    }

    func testBoundedRowsAreThoseOf520() {
        for atPosition in bools { for text in textTrackCases { for local in bools { for cues in cuesCases { for onDisk in bools {
            let expected = bounded520(text: text, atPosition: atPosition, local: local)
            let (demux, why) = choice(bounded: true, atPosition: atPosition, text: text, local: local, cues: cues,
                                      onDisk: onDisk || local)
            check((demux == .avformat) == expected.avformat,
                  "bounded, at position \(atPosition), text \(String(describing: text)), local \(local), cues \(String(describing: cues)): demuxer")
            check(why == expected.why,
                  "bounded, at position \(atPosition), text \(String(describing: text)), local \(local), cues \(String(describing: cues)): reason « \(why) »")
        } } } } }
        // The rows, spelled out once.
        check(choice(bounded: true, atPosition: false, text: 0, local: false, cues: true).0 == .avformat, "bounded, no text track, from the start → libavformat")
        check(choice(bounded: true, atPosition: true, text: 0, local: true, cues: true).0 == .avformat, "bounded, no text track, at a position, local → libavformat")
        check(choice(bounded: true, atPosition: true, text: 2, local: true, cues: true).0 == .own, "bounded, text tracks, at a position, local → VLC's own")
        check(choice(bounded: true, atPosition: true, text: 2, local: false, cues: true).0 == .avformat, "bounded, text tracks, at a position, not local → libavformat")
        check(choice(bounded: true, atPosition: false, text: 2, local: false, cues: true).0 == .own, "bounded, text tracks, from the start → VLC's own")
        check(choice(bounded: true, atPosition: true, text: nil, local: true, cues: true).0 == .avformat, "bounded, unknown tracks, at a position → libavformat")
        check(choice(bounded: true, atPosition: false, text: nil, local: false, cues: true).0 == .own, "bounded, unknown tracks, from the start → VLC's own")
    }

    func testFullStorageFromTheStartIsUnchanged() {
        for text in textTrackCases { for local in bools { for cues in cuesCases { for onDisk in bools {
            let (demux, why) = choice(bounded: false, atPosition: false, text: text, local: local, cues: cues, onDisk: onDisk || local)
            check(demux == .own, "full, from the start, text \(String(describing: text)), cues \(String(describing: cues)) → VLC's own, as in 5.2.0")
            check(why == "full storage, from the start: far seeks read through", "full, from the start: reason")
        } } } }
    }

    func testFullStorageAtAPositionLocalKeepsVLCsOwn() {
        for text in textTrackCases { for cues in cuesCases {
            let (demux, why) = choice(bounded: false, atPosition: true, text: text, local: true, cues: cues)
            check(demux == .own, "full, at a position, everything local, text \(String(describing: text)) → VLC's own (a local read)")
            check(why.hasPrefix("everything up to there is on disk"), "full, at a position, local: reason « \(why) »")
        } }
        check(choice(bounded: false, atPosition: true, text: 3, local: true, cues: true).why
                == "everything up to there is on disk; keeps its 3 text subtitle track(s)", "the kept subtitles are named")
        check(choice(bounded: false, atPosition: true, text: 0, local: true, cues: true).why
                == "everything up to there is on disk", "nothing to keep, nothing said")
    }

    /// The fix: the reported resume at 1 h 40 (full storage, the file empty again at every launch).
    func testFullStorageAtAPositionNotLocalJumpsWithLibavformat() {
        for text in textTrackCases { for cues in [Bool?.none, true] {
            let (demux, why) = choice(bounded: false, atPosition: true, text: text, local: false, cues: cues)
            check(demux == .avformat, "full, at a position, not local, text \(String(describing: text)), cues \(String(describing: cues)) → libavformat")
            check(why.hasSuffix("VLC's own demuxer would read the whole file up to there at download speed"), "full, at a position, not local: reason « \(why) »")
        } }
        check(choice(bounded: false, atPosition: true, text: 0, local: false, cues: true).why.hasPrefix("no text subtitle track:"), "no text track")
        check(choice(bounded: false, atPosition: true, text: 2, local: false, cues: true).why.hasPrefix("its 2 text subtitle track(s) are lost:"), "the lost subtitles are named")
        check(choice(bounded: false, atPosition: true, text: nil, local: false, cues: true).why.hasPrefix("tracks unknown:"), "unknown tracks")
    }

    /// A native film handed over to VLC late in full storage (a decode failure, a remux halt, a
    /// starvation give-up at 1 h 10 of a 9 GiB film): its whole head is on disk but past the
    /// quick local read. libavformat's clock is off on a file with text subtitles (00:23 for
    /// 1:10:00: runs S1 / S3 / S4 of rs-vlc-demux.md), so VLC's own reads it locally; a file with
    /// no text track keeps the limit (nothing lost, a right clock).
    func testFullStorageEverythingOnDiskPastTheLimitKeepsVLCsOwnOnTextSubtitleFiles() {
        for cues in cuesCases {
            for text in [Int?.none, 1, 3] {
                let (demux, why) = choice(bounded: false, atPosition: true, text: text, local: false, cues: cues, onDisk: true)
                check(demux == .own, "full, on disk past the limit, text \(String(describing: text)), cues \(String(describing: cues)) → VLC's own")
                check(why.hasPrefix("everything up to there is on disk (past the quick local read"), "reason « \(why) »")
            }
            if cues != false {
                check(choice(bounded: false, atPosition: true, text: 0, local: false, cues: cues, onDisk: true).0 == .avformat,
                      "full, on disk past the limit, no text track, cues \(String(describing: cues)) → libavformat (the limit holds)")
            }
        }
        check(choice(bounded: false, atPosition: true, text: 3, local: false, cues: true, onDisk: true).why.contains("keeps its 3 text subtitle track(s)"),
              "the kept subtitles are named")
        check(choice(bounded: false, atPosition: true, text: nil, local: false, cues: true, onDisk: true).why.contains("tracks unknown"),
              "unknown tracks may hold text subtitles")
        // Not on disk: unchanged (libavformat jumps).
        check(choice(bounded: false, atPosition: true, text: 3, local: false, cues: true, onDisk: false).0 == .avformat, "not on disk → libavformat")
    }

    /// A file known to have no index: nothing jumps (measured: libavformat reads through like
    /// VLC's own), so full storage keeps VLC's own demuxer and its subtitles.
    func testFullStorageAtAPositionWithoutCuesKeepsVLCsOwn() {
        for text in textTrackCases {
            let (demux, why) = choice(bounded: false, atPosition: true, text: text, local: false, cues: false)
            check(demux == .own, "full, at a position, not local, no Cues, text \(String(describing: text)) → VLC's own")
            check(why.hasPrefix("no keyframe index (Cues) in the file"), "full, no Cues: reason « \(why) »")
        }
        check(choice(bounded: false, atPosition: true, text: 2, local: false, cues: false).why.hasSuffix("and keeps its 2 text subtitle track(s)"),
              "the kept subtitles are named")
        // Unknown is not « none »: an index that may exist is used.
        check(choice(bounded: false, atPosition: true, text: 2, local: false, cues: nil).0 == .avformat, "Cues unknown → libavformat")
        // Local data wins over the missing index (the same demuxer, another reason).
        check(choice(bounded: false, atPosition: true, text: 0, local: true, cues: false).why == "everything up to there is on disk",
              "no Cues but local: the local read is the reason")
    }

    /// The two modes agree at a position on a file that is not local up to there, whatever its
    /// tracks: D5's « a demuxer that jumps through the index at a position in BOTH modes ».
    func testBothModesJumpAtAPositionWhenTheDataIsNotLocal() {
        for text in textTrackCases { for cues in [Bool?.none, true] {
            let full = choice(bounded: false, atPosition: true, text: text, local: false, cues: cues).0
            let bounded = choice(bounded: true, atPosition: true, text: text, local: false, cues: cues).0
            check(full == .avformat && bounded == .avformat, "at a position, not local, text \(String(describing: text)): libavformat in both modes")
        } }
    }

    func testMediaOptions() {
        check(Demux.own.mediaOptions.isEmpty, "VLC's own demuxer: no option")
        check(Demux.avformat.mediaOptions == [":demux=avformat"], "libavformat: :demux=avformat")
        check(BoundedStorageUX.vlcAVFormatDemuxOption == ":demux=avformat", "the option's text")
    }

    // MARK: ownDemuxerReadsOnlyLocalData

    func testOwnDemuxerReadsOnlyLocalData() {
        let mib: Int64 = 1 << 20
        let gib: Int64 = 1 << 30
        func local(size: Int64, fraction: Float, lowest: Int64 = 0, firstMissing: Int64) -> Bool {
            BoundedStorageUX.ownDemuxerReadsOnlyLocalData(fileSize: size, fraction: fraction, lowestAvailableOffset: lowest,
                                                           firstMissingOffset: firstMissing)
        }
        // A 9 GiB film, resume at 69 %: the file is empty again at launch (head only).
        check(!local(size: 9 * gib, fraction: 0.69, firstMissing: 64 * mib), "an empty file is not local up to 69 %")
        // … and even wholly on disk it is past what a local read may cost.
        check(!local(size: 9 * gib, fraction: 0.69, firstMissing: 9 * gib), "6 GiB to read: past the local read limit")
        // A 2 GiB film at 30 %: 614 MiB + 25 % + 64 MiB = 832 MiB needed.
        check(local(size: 2 * gib, fraction: 0.3, firstMissing: 900 * mib), "everything up to the target (with its margin) on disk")
        check(!local(size: 2 * gib, fraction: 0.3, firstMissing: 700 * mib), "the margin past the target is not on disk")
        check(!local(size: 2 * gib, fraction: 0.3, lowest: 4 * mib, firstMissing: 900 * mib), "something was released: not local")
        // A small file: the need is capped at its size.
        check(local(size: 100 * mib, fraction: 0.9, firstMissing: 100 * mib), "a complete small file")
        check(!local(size: 100 * mib, fraction: 0.9, firstMissing: 99 * mib), "a small file with its end missing")
        // No position.
        check(!local(size: 2 * gib, fraction: 0, firstMissing: 2 * gib), "0:00 is no position")
        check(!local(size: 2 * gib, fraction: 1, firstMissing: 2 * gib), "the very end is no position")
        check(!local(size: 0, fraction: 0.5, firstMissing: 0), "an unknown size")

        // No limit (`everythingOnDisk`, full storage): the 9 GiB film wholly on disk is.
        func onDisk(size: Int64, fraction: Float, lowest: Int64 = 0, firstMissing: Int64, target: UInt64? = nil) -> Bool {
            BoundedStorageUX.ownDemuxerReadsOnlyLocalData(fileSize: size, fraction: fraction, lowestAvailableOffset: lowest,
                                                           firstMissingOffset: firstMissing, targetOffset: target, limit: nil)
        }
        check(onDisk(size: 9 * gib, fraction: 0.69, firstMissing: 9 * gib), "no limit: 6 GiB on disk")
        check(!onDisk(size: 9 * gib, fraction: 0.69, firstMissing: 64 * mib), "no limit: still the data that is missing")
        // A starvation give-up at 50 %: the download frontier just past the playhead's Cluster.
        // The fraction's margin (+25 %, +64 MiB) would want 1.2 GiB more; the Cues' Cluster does not.
        let cluster: UInt64 = UInt64(4 * gib + 600 * mib)
        check(!onDisk(size: 9 * gib, fraction: 0.5, firstMissing: Int64(cluster) + 40 * mib), "fraction estimate: refused")
        check(onDisk(size: 9 * gib, fraction: 0.5, firstMissing: Int64(cluster) + 40 * mib, target: cluster), "the Cues' Cluster + its margin on disk")
        check(!onDisk(size: 9 * gib, fraction: 0.5, firstMissing: Int64(cluster) + 8 * mib, target: cluster), "less than the margin past it: not")
        // The target offset also serves the limited rule, and the limit still holds.
        check(local(size: 2 * gib, fraction: 0.3, firstMissing: 700 * mib) == false, "estimate: 832 MiB needed")
        check(BoundedStorageUX.ownDemuxerReadsOnlyLocalData(fileSize: 2 * gib, fraction: 0.3, lowestAvailableOffset: 0,
                                                             firstMissingOffset: 700 * mib, targetOffset: UInt64(600 * mib)),
              "the Cues' Cluster at 600 MiB: 616 MiB needed, on disk")
        check(!BoundedStorageUX.ownDemuxerReadsOnlyLocalData(fileSize: 9 * gib, fraction: 0.5, lowestAvailableOffset: 0,
                                                              firstMissingOffset: 9 * gib, targetOffset: cluster),
              "the limited rule keeps its limit")
        check(!onDisk(size: 9 * gib, fraction: 0.5, lowest: 4 * mib, firstMissing: 9 * gib, target: cluster), "something released: not")
        // An offset past the end (a wrong index) falls back to the estimate.
        check(!onDisk(size: 2 * gib, fraction: 0.3, firstMissing: 700 * mib, target: UInt64(3 * gib)), "an offset past the end is not used")
    }

    // MARK: matroskaClusterOffset

    func testMatroskaClusterOffsetFromTheCues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VLCDemuxChoiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, _ data: Data) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        // 30 one-second clusters, a keyframe at each start, every one indexed.
        var film = SyntheticMatroska()
        film.cues = .back
        let layout = film.layout()
        let url = try write("film.mkv", layout.data)
        eq(BoundedStorageUX.matroskaClusterOffset(url, fraction: 0.5), UInt64(layout.clusterOffsets[15]), "15.0 s: cluster 15")
        eq(BoundedStorageUX.matroskaClusterOffset(url, fraction: 0.51), UInt64(layout.clusterOffsets[15]), "15.3 s: the keyframe before, cluster 15")
        eq(BoundedStorageUX.matroskaClusterOffset(url, fraction: 0.99), UInt64(layout.clusterOffsets[29]), "29.7 s: the last cluster")
        check(BoundedStorageUX.matroskaClusterOffset(url, fraction: 0) == nil, "0:00 is no position")
        // A sparse index (every 4th keyframe): the indexed one before the target.
        film.cueStride = 4
        let sparse = film.layout()
        let sparseURL = try write("sparse.mkv", sparse.data)
        eq(BoundedStorageUX.matroskaClusterOffset(sparseURL, fraction: 0.5),
           UInt64(sparse.clusterOffsets[12]), "sparse index: cluster 12 for 15 s")
        // No Cues, or Cues not downloaded yet (zeros at the tail): unknown.
        film.cueStride = 1
        film.cues = .none
        let noCues = try write("nocues.mkv", film.data())
        check(BoundedStorageUX.matroskaClusterOffset(noCues, fraction: 0.5) == nil, "no Cues")
        film.cues = .back
        let pending = film.layout()
        var bytes = [UInt8](pending.data)
        check(pending.cuesOffset != nil, "the Cues are at the tail")
        if let cues = pending.cuesOffset { for index in cues..<bytes.count { bytes[index] = 0 } }
        let pendingURL = try write("pending.mkv", Data(bytes))
        check(BoundedStorageUX.matroskaClusterOffset(pendingURL, fraction: 0.5) == nil,
              "the Cues not downloaded yet")
    }

    // MARK: matroskaHead

    func testMatroskaHeadReadsTextTracksAndCues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VLCDemuxChoiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func facts(_ text: Int, _ cues: Bool?) -> BoundedStorageUX.MatroskaHead? {
            BoundedStorageUX.MatroskaHead(textSubtitleTracks: text, hasCues: cues)
        }
        func head(_ name: String, _ file: TinyMatroska) throws -> BoundedStorageUX.MatroskaHead? {
            let url = directory.appendingPathComponent(name)
            try file.data().write(to: url)
            return BoundedStorageUX.matroskaHead(url)
        }

        // The Cues listed in the SeekHead (mkvmerge, ffmpeg): found without reading them.
        let listed = try head("listed.mkv", TinyMatroska(textSubtitleTracks: 2, cues: .listedInSeekHead))
        check(listed == facts(2, true), "2 text tracks, Cues listed in the SeekHead")
        // No index at all.
        let none = try head("none.mkv", TinyMatroska(textSubtitleTracks: 0, cues: .none))
        check(none == facts(0, false), "no text track, no Cues")
        // … with the file still downloading where its first Cluster is: « none » is not certain.
        let unknown = try head("unknown.mkv", TinyMatroska(textSubtitleTracks: 0, cues: .none, clusterOnDisk: false))
        check(unknown == facts(0, nil), "no Cues listed, the first Cluster not on disk: Cues unknown")
        // Not listed, but before the first Cluster (reserved index space): a demuxer meets them.
        let front = try head("front.mkv", TinyMatroska(textSubtitleTracks: 0, cues: .beforeFirstCluster))
        check(front == facts(0, true), "Cues before the first Cluster, not in the SeekHead")
        // An image subtitle track is not a text track.
        let image = try head("image.mkv", TinyMatroska(textSubtitleTracks: 1, imageSubtitleTracks: 2, cues: .listedInSeekHead))
        check(image?.textSubtitleTracks == 1, "PGS tracks are not counted")
        // mkvmerge's second SeekHead (at the end) lists them: read from there.
        let second = try head("second.mkv", TinyMatroska(textSubtitleTracks: 1, cues: .listedInSecondSeekHead(onDisk: true)))
        check(second == facts(1, true), "Cues listed in the second SeekHead")
        // … which is not downloaded yet: unknown, never « none ».
        let pending = try head("pending.mkv", TinyMatroska(textSubtitleTracks: 1, cues: .listedInSecondSeekHead(onDisk: false)))
        check(pending == facts(1, nil), "second SeekHead not on disk: Cues unknown")
        // Not Matroska, not there.
        let junk = directory.appendingPathComponent("junk.mkv")
        try Data(repeating: 0x41, count: 4096).write(to: junk)
        check(BoundedStorageUX.matroskaHead(junk) == nil, "not a Matroska file")
        check(BoundedStorageUX.matroskaHead(directory.appendingPathComponent("absent.mkv")) == nil, "no file")
    }
}

/// A Matroska file just big enough for `MatroskaDemuxer.parseHeaders`: EBML header, Segment
/// (SeekHead, Info, Tracks, one Cluster, Cues / a second SeekHead at the end). No media.
private struct TinyMatroska {
    enum Cues {
        case none
        /// The first SeekHead lists the Cues (written after the Cluster).
        case listedInSeekHead
        /// No SeekHead entry; the Cues stand between the Tracks and the Cluster.
        case beforeFirstCluster
        /// The first SeekHead lists a second SeekHead at the end, which lists the Cues; `onDisk`
        /// false: everything after the Cluster is zeros (not downloaded yet).
        case listedInSecondSeekHead(onDisk: Bool)
    }

    var textSubtitleTracks = 0
    var imageSubtitleTracks = 0
    var cues: Cues = .none
    /// false: the Cluster reads as zeros (not downloaded yet).
    var clusterOnDisk = true

    private static func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        // 8-byte sizes: an element's length does not depend on its payload's.
        var size: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) { size.append(UInt8((payload.count >> shift) & 0xFF)) }
        return id + size + payload
    }

    private static func uint(_ value: UInt64, width: Int = 8) -> [UInt8] {
        (0..<width).reversed().map { UInt8((value >> (UInt64($0) * 8)) & 0xFF) }
    }

    private static func seek(_ id: [UInt8], position: UInt64) -> [UInt8] {
        element([0x4D, 0xBB], element([0x53, 0xAB], id) + element([0x53, 0xAC], uint(position)))
    }

    private static let cuesID: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]
    private static let seekHeadID: [UInt8] = [0x11, 0x4D, 0x9B, 0x74]

    private func track(number: UInt8, type: UInt8, codec: String) -> [UInt8] {
        Self.element([0xAE], Self.element([0xD7], [number]) + Self.element([0x73, 0xC5], [number])
                     + Self.element([0x83], [type]) + Self.element([0x86], Array(codec.utf8)))
    }

    func data() -> Data {
        let ebml = Self.element([0x1A, 0x45, 0xDF, 0xA3], Self.element([0x42, 0x82], Array("matroska".utf8)))
        let info = Self.element([0x15, 0x49, 0xA9, 0x66],
                                Self.element([0x2A, 0xD7, 0xB1], Self.uint(1_000_000, width: 4))
                                + Self.element([0x44, 0x89], Self.uint(Double(60_000).bitPattern)))
        var entries = track(number: 1, type: 1, codec: "V_MPEG4/ISO/AVC") + track(number: 2, type: 2, codec: "A_AC3")
        var number: UInt8 = 3
        for _ in 0..<textSubtitleTracks { entries += track(number: number, type: 0x11, codec: "S_TEXT/UTF8"); number += 1 }
        for _ in 0..<imageSubtitleTracks { entries += track(number: number, type: 0x11, codec: "S_HDMV/PGS"); number += 1 }
        let tracks = Self.element([0x16, 0x54, 0xAE, 0x6B], entries)
        var cluster = Self.element([0x1F, 0x43, 0xB6, 0x75], Self.element([0xE7], [0x01]))
        if !clusterOnDisk { cluster = [UInt8](repeating: 0, count: cluster.count) }

        // The first SeekHead always holds one entry of the same size (Info's when it lists no
        // Cues), so the positions after it do not depend on the case.
        let seekHeadLength = Self.element(Self.seekHeadID, Self.seek(Self.cuesID, position: 0)).count
        let clusterPosition = UInt64(seekHeadLength + info.count + tracks.count)   // relative to the Segment's data
        let afterCluster = clusterPosition + UInt64(cluster.count)
        let cuePoint = Self.element([0xBB], Self.element([0xB3], [0x01])
                                    + Self.element([0xB7], Self.element([0xF7], [0x01]) + Self.element([0xF1], Self.uint(clusterPosition))))
        let cuesElement = Self.element(Self.cuesID, cuePoint)

        let seekHead: [UInt8]
        var front: [UInt8] = []
        var tail: [UInt8] = []
        switch cues {
        case .none:
            seekHead = Self.element(Self.seekHeadID, Self.seek([0x15, 0x49, 0xA9, 0x66], position: UInt64(seekHeadLength)))
        case .beforeFirstCluster:
            seekHead = Self.element(Self.seekHeadID, Self.seek([0x15, 0x49, 0xA9, 0x66], position: UInt64(seekHeadLength)))
            // A Void first, as the muxers leave one: the walk skips it by its size.
            front = Self.element([0xEC], [0xFF, 0xFF]) + cuesElement
        case .listedInSeekHead:
            seekHead = Self.element(Self.seekHeadID, Self.seek(Self.cuesID, position: afterCluster))
            tail = cuesElement
        case .listedInSecondSeekHead(let onDisk):
            // Cues, then the second SeekHead that lists them.
            let second = Self.element(Self.seekHeadID, Self.seek(Self.cuesID, position: afterCluster))
            seekHead = Self.element(Self.seekHeadID, Self.seek(Self.seekHeadID, position: afterCluster + UInt64(cuesElement.count)))
            // A Void after it: the SeekHead's last byte is not the last of the file (a zero
            // there would read as the download frontier).
            tail = cuesElement + second + Self.element([0xEC], [0xFF])
            if !onDisk { tail = [UInt8](repeating: 0, count: tail.count) }
        }
        let body = seekHead + info + tracks + front + cluster + tail
        return Data(ebml + Self.element([0x18, 0x53, 0x80, 0x67], body))
    }
}
