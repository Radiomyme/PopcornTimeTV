//
//  PlaybackStartMeasureTests.swift
//  PopcornTimeTests
//
//  PlaybackStartMeasure: the [Measure] lines of a playback's start (the torrent's pieces, what the
//  engine waits for before readyToPlay, the counters at each step), logged once per step.
//

import XCTest
import Foundation
@testable import PopcornKit

final class PlaybackStartMeasureTests: CheckedTestCase {

    private let mebibyte: Int64 = 1_048_576

    // MARK: Geometry

    func testTheFileListGivesTheOffsetAndThePieceCount() {
        // A season pack: an .nfo, the episode played, another episode; 256 KiB pieces.
        let geometry = PlaybackStartMeasure.Geometry(pieceLength: 262_144, fileSize: 300_000_000,
                                                     sizes: [500_000, 300_000_000, 200_000_000], selected: 1)
        eq(geometry?.fileOffset, 500_000, "the offset is the running sum of the files before it")
        eq(geometry?.torrentSize, 500_500_000, "the torrent's size is the sum of its files")
        eq(geometry?.torrentPieceCount, 1910, "pieces of the whole torrent, the last one partial")
        eq(geometry?.filePieces, 1...1146, "the file starts inside piece 1 and ends in piece 1146")
        eq(geometry?.fileIndex, 1, "file index")
        eq(geometry?.fileCount, 3, "file count")
        check(PlaybackStartMeasure.Geometry(pieceLength: 262_144, fileSize: 1, sizes: [1, 2], selected: 2) == nil,
              "an index out of range gives no geometry")
        check(PlaybackStartMeasure.Geometry(pieceLength: 262_144, fileSize: 1, sizes: [1, 2], selected: -1) == nil,
              "« no file » gives no geometry")
        let bare = PlaybackStartMeasure.Geometry(pieceLength: mebibyte, fileSize: 10 * mebibyte)
        check(bare.torrentPieceCount == nil && bare.filePieces == nil, "without the file list: no piece count, no range")
    }

    // MARK: The engine's readiness rule

    func testAFourKFilmWaitsForTwentyHeadPiecesAndTwoTailPieces() {
        // The 7.7 GB film of the Apple TV session of 2026-11-15 (1 MiB pieces assumed here).
        let geometry = PlaybackStartMeasure.Geometry(pieceLength: mebibyte, fileSize: 8_086_691_840,
                                                     sizes: [8_086_691_840], selected: 0)!
        let rule = PlaybackStartMeasure.Readiness.engineRule(geometry, bounded: false)
        eq(rule?.headPieces, 20, "3 % of the file is 231 pieces: capped at 20")
        eq(rule?.tailPieces, 2, "more than 6 head pieces: the last 2")
        eq(rule?.headBytes, 20 * mebibyte, "20 whole pieces of the file")
        eq(rule?.tailBytes, 1_122_304, "one whole piece and the last one, which holds 73 728 B")
        eq(rule?.distinctPieces, 22, "22 pieces")
        check(rule?.headIsUpperBound == false && rule?.assumesAlignedFile == false, "full mode, offset known")
    }

    func testAFileInsideAPackCountsOnlyItsOwnBytes() {
        let geometry = PlaybackStartMeasure.Geometry(pieceLength: 262_144, fileSize: 300_000_000,
                                                     sizes: [500_000, 300_000_000, 200_000_000], selected: 1)!
        let rule = PlaybackStartMeasure.Readiness.engineRule(geometry, bounded: false)
        eq(rule?.headPieces, 20, "34 pieces of 3 %: capped at 20")
        eq(rule?.headBytes, 5_005_024, "pieces 1…20 end at 5 505 024 in the torrent; the file starts at 500 000")
        eq(rule?.tailBytes, 345_120, "pieces 1145…1146 hold the file's last 345 120 B")
    }

    func testSmallFilesWaitForFewerPieces() {
        // 3 % of 220 pieces = 6.6 → 6: one tail piece; of 240 pieces = 7.2 → 7: two.
        let six = PlaybackStartMeasure.Readiness.engineRule(.init(pieceLength: mebibyte, fileSize: 220 * mebibyte), bounded: false)
        eq(six?.headPieces, 6, "truncated, as the engine's int does")
        eq(six?.tailPieces, 1, "6 head pieces or fewer: the last one only")
        let seven = PlaybackStartMeasure.Readiness.engineRule(.init(pieceLength: mebibyte, fileSize: 240 * mebibyte), bounded: false)
        eq(seven?.headPieces, 7, "7 head pieces")
        eq(seven?.tailPieces, 2, "7 head pieces: the last two")
        let small = PlaybackStartMeasure.Readiness.engineRule(.init(pieceLength: mebibyte, fileSize: 50 * mebibyte), bounded: false)
        eq(small?.headPieces, 1, "1.5 pieces → 1, never 0")
        check(small?.assumesAlignedFile == true, "no file list: the file is assumed to start on a piece boundary")
        let tiny = PlaybackStartMeasure.Readiness.engineRule(.init(pieceLength: mebibyte, fileSize: 600_000), bounded: false)
        eq(tiny?.headBytes, 600_000, "a file smaller than a piece: its own bytes")
        eq(tiny?.tailBytes, 600_000, "the same piece")
        eq(tiny?.distinctPieces, 1, "head and tail are the same piece")
        check(PlaybackStartMeasure.Readiness.engineRule(.init(pieceLength: 0, fileSize: 600_000), bounded: false) == nil,
              "no piece length: unknown")
        check(PlaybackStartMeasure.Readiness.engineRule(.init(pieceLength: mebibyte, fileSize: 240 * mebibyte), bounded: true)?
              .headIsUpperBound == true, "bounded: at most that many (the window is not published)")
    }

    // MARK: Lines

    func testTheLines() {
        let geometry = PlaybackStartMeasure.Geometry(pieceLength: mebibyte, fileSize: 8_086_691_840,
                                                     sizes: [8_086_691_840], selected: 0)!
        eq(PlaybackStartMeasure.torrentLine(geometry),
           "[Measure] torrent: piece 1048576 B (1.0 MiB), 7713 piece(s), 8086691840 B; file #0 of 1, 8086691840 B at offset 0 (pieces 0…7712)",
           "the torrent line")
        eq(PlaybackStartMeasure.readinessLine(geometry, bounded: false, tailPinStart: 8_079_278_080, headPinEnd: 0),
           "[Measure] readiness (engine rule, recomputed by the app): head 20 piece(s) = 20971520 B of the file + tail 2 piece(s) "
           + "= 1122304 B; tail pinned from 8079278080 (7413760 B), head pin 0 B; full",
           "the readiness line, with the engine's tail pin")
        eq(PlaybackStartMeasure.torrentLine(.init(pieceLength: 262_144, fileSize: 1_000_000)),
           "[Measure] torrent: piece 262144 B, piece count unknown (no file list); file 1000000 B at an unknown offset",
           "without the file list")
        eq(PlaybackStartMeasure.readinessLine(.init(pieceLength: mebibyte, fileSize: 600_000), bounded: true,
                                              tailPinStart: -1, headPinEnd: 67_108_864),
           "[Measure] readiness (engine rule, recomputed by the app): head at most 1 piece(s) = 600000 B of the file + tail 1 "
           + "piece(s) = 600000 B (1 distinct piece(s)) (offset unknown: file assumed piece-aligned); head pin 67108864 B; bounded",
           "bounded, one piece, no tail pin")
        eq(PlaybackStartMeasure.torrentLine(.init(pieceLength: 0, fileSize: 0)),
           "[Measure] torrent: unknown (no piece length or file size from the engine)", "no statistics")
        eq(PlaybackStartMeasure.readinessLine(.init(pieceLength: 0, fileSize: 0), bounded: false, tailPinStart: nil, headPinEnd: nil),
           "[Measure] readiness: unknown (no piece length or file size)", "no statistics")

        let ready = PlaybackStartMeasure.Sample(fileBytes: 30_408_704, bytesOnDisk: 30_408_704, headOnDisk: 20 * mebibyte,
                                                downloadRate: 4_823_449, peers: 11, seeds: 9, engineSeconds: 16.2)
        eq(PlaybackStartMeasure.line(.ready, sample: ready, sinceTrace: 16.365),
           "[Measure] ready: t+16365 ms (engine +16200 ms) — file 30408704 B (29.0 MiB) · on disk 30408704 B (29.0 MiB) · "
           + "head 20971520 B (20.0 MiB) · 4823449 B/s (4.6 MiB/s) · 11 peer(s), 9 seed(s)",
           "a step with both clocks")
        let early = PlaybackStartMeasure.Sample(fileBytes: 0, downloadRate: 120_000, peers: 1, seeds: 1, engineSeconds: 1.98)
        eq(PlaybackStartMeasure.line(.firstPeer, sample: early, sinceTrace: nil),
           "[Measure] first peer: engine +1980 ms — file 0 B · 120000 B/s · 1 peer(s), 1 seed(s)",
           "before the metadata: no disk counters, no trace")
        eq(PlaybackStartMeasure.line(.jumpDecided, sample: early, sinceTrace: 3, detail: "resume, segment 389"),
           "[Measure] jump decided: t+3000 ms (engine +1980 ms) — file 0 B · 120000 B/s · 1 peer(s), 1 seed(s) — resume, segment 389",
           "the detail comes last")
    }

    // MARK: Once per step

    func testEachStepIsLoggedOnce() {
        var lines: [String] = []
        let measure = PlaybackStartMeasure(log: { lines.append($0) })
        let sample = PlaybackStartMeasure.Sample(fileBytes: 0, downloadRate: 0, peers: 1, seeds: 0)
        check(measure.isPending(.firstPeer), "pending at first")
        check(measure.reach(.firstPeer, sample: sample, sinceTrace: 1), "logged")
        check(!measure.reach(.firstPeer, sample: sample, sinceTrace: 2), "not twice: the 1 Hz samples after it log nothing")
        check(!measure.isPending(.firstPeer) && measure.isPending(.firstFrame), "only that step is done")
        eq(lines.count, 1, "one line")

        measure.noteFiles(sizes: [10, 20], selected: 5)
        measure.noteFiles(sizes: [500_000, 300_000_000, 200_000_000], selected: 1)
        measure.noteFiles(sizes: [1], selected: 0)
        check(measure.logGeometry(pieceLength: 262_144, fileSize: 300_000_000, bounded: false, tailPinStart: nil, headPinEnd: nil),
              "geometry logged")
        check(!measure.logGeometry(pieceLength: 262_144, fileSize: 300_000_000, bounded: false, tailPinStart: nil, headPinEnd: nil),
              "geometry once")
        eq(lines.count, 3, "the torrent and readiness lines")
        eq(lines[1], "[Measure] torrent: piece 262144 B, 1910 piece(s), 500500000 B; file #1 of 3, 300000000 B at offset 500000 "
           + "(pieces 1…1146)", "the first valid file list is kept (an index out of range is ignored, a later list too)")
        check(lines[2].contains("= 5005024 B of the file"), "the readiness uses the file's offset", lines[2])
    }

    // MARK: The start's jump only

    /// A film started from 0:00, no resume: the user's first rewind 40 minutes later is no part
    /// of the start — no « jump decided » / « jump written » after the first frame.
    func testAJumpAfterTheFirstFrameIsNotTheStarts() {
        var lines: [String] = []
        let measure = PlaybackStartMeasure(log: { lines.append($0) })
        let sample = PlaybackStartMeasure.Sample(fileBytes: 0, downloadRate: 0, peers: 1, seeds: 1)
        check(measure.reach(.firstFrame, sample: sample, sinceTrace: 9), "the start's first frame")
        check(!measure.reach(.jumpDecided, sample: sample, sinceTrace: 2400, detail: "rewind, segment 300", segment: 300),
              "a rewind 40 minutes in: not logged")
        check(!measure.reach(.jumpWritten, sample: sample, sinceTrace: 2405, segment: 300), "nor its segment")
        eq(lines.count, 1, "only the first frame")
        check(measure.isPending(.jumpDecided), "still pending (and never logged for this stream)")
    }

    /// A resume: the start's jump is decided then written before the first frame — both lines,
    /// once; a later jump logs nothing.
    func testTheStartsJumpIsLoggedDecidedThenWritten() {
        var lines: [String] = []
        let measure = PlaybackStartMeasure(log: { lines.append($0) })
        let sample = PlaybackStartMeasure.Sample(fileBytes: 0, downloadRate: 0, peers: 1, seeds: 1)
        check(!measure.reach(.jumpWritten, sample: sample, sinceTrace: 1, segment: 114), "written before any decided: no line")
        check(measure.reach(.jumpDecided, sample: sample, sinceTrace: 3, detail: "resume, segment 114", segment: 114), "decided")
        check(measure.reach(.jumpWritten, sample: sample, sinceTrace: 4, segment: 114), "its segment written")
        check(measure.reach(.firstFrame, sample: sample, sinceTrace: 5), "first frame")
        check(!measure.reach(.jumpDecided, sample: sample, sinceTrace: 60, segment: 20), "a later jump: nothing")
        eq(lines.map { $0.components(separatedBy: ":").first ?? "" },
           ["[Measure] jump decided", "[Measure] jump written", "[Measure] first frame"], "three lines, in order")
    }

    /// The start's jump replaced by a player request before its segment was written: « jump
    /// written » is not logged for the other segment (the two lines would describe two jumps).
    func testAWrittenSegmentOfAnotherJumpIsNotTheStarts() {
        var lines: [String] = []
        let measure = PlaybackStartMeasure(log: { lines.append($0) })
        let sample = PlaybackStartMeasure.Sample(fileBytes: 0, downloadRate: 0, peers: 1, seeds: 1)
        check(measure.reach(.jumpDecided, sample: sample, sinceTrace: 3, segment: 114), "decided: segment 114")
        check(!measure.reach(.jumpWritten, sample: sample, sinceTrace: 6, segment: 90), "segment 90 written: not the start's")
        check(measure.isPending(.jumpWritten), "still pending")
        check(measure.reach(.jumpWritten, sample: sample, sinceTrace: 8, segment: 114), "segment 114 written: logged")
        eq(lines.count, 2, "decided and written, of the same jump")
        check(PlaybackStartMeasure.admits(.jumpWritten, reached: [.jumpDecided], decidedSegment: nil, segment: 7),
              "a segment unknown on one side: logged as before")
        check(PlaybackStartMeasure.admits(.ready, reached: [.firstFrame], decidedSegment: nil, segment: nil),
              "the other steps are not concerned")
    }

    // MARK: Head and tail on disk, the steering after ready (chantier « attente »)

    /// The two ends the engine waits for before `readyToPlay`: a line for each the first time
    /// it is all on disk (the later of the two ended the start buffer).
    func testTheHeadAndTheTailAreDueOnceAllOnDisk() {
        let geometry = PlaybackStartMeasure.Geometry(pieceLength: 8 << 20, fileSize: 12_607_042_523)
        guard let rule = PlaybackStartMeasure.Readiness.engineRule(geometry, bounded: false) else { return check(false, "a rule") }
        let size = geometry.fileSize
        eq(PlaybackStartMeasure.requiredEnds(rule, fileSize: size, headOnDisk: 0, tailOnDisk: false).map(\.0), [],
           "nothing on disk: nothing due")
        eq(PlaybackStartMeasure.requiredEnds(rule, fileSize: size, headOnDisk: rule.headBytes - 1, tailOnDisk: true).map(\.0),
           [.tailOnDisk], "the tail first, the head one byte short")
        let both = PlaybackStartMeasure.requiredEnds(rule, fileSize: size, headOnDisk: 244_304_933, tailOnDisk: true)
        eq(both.map(\.0), [.headOnDisk, .tailOnDisk], "a head beyond the 20 pieces and the tail: both")
        eq(both.first?.1, "20 piece(s) = 167772160 B of the file", "the head's detail")
        eq(both.last?.1, "2 piece(s) = \(rule.tailBytes) B from \(size - rule.tailBytes)", "the tail's detail")
    }

    /// Bounded storage: the engine waits for no more head pieces than its window (unpublished),
    /// so the app's 20-piece head can still be missing at ready. The head is then logged at
    /// ready, « seen at ready », never left out (a lone tail line would read as the end of the
    /// start buffer).
    func testInBoundedStorageTheHeadIsLoggedAtReadyAtTheLatest() {
        let geometry = PlaybackStartMeasure.Geometry(pieceLength: 8 << 20, fileSize: 12_607_042_523)
        guard let rule = PlaybackStartMeasure.Readiness.engineRule(geometry, bounded: true) else { return check(false, "a rule") }
        let size = geometry.fileSize
        let window: Int64 = 4 * (8 << 20)
        eq(PlaybackStartMeasure.requiredEnds(rule, fileSize: size, headOnDisk: window, tailOnDisk: true).map(\.0),
           [.tailOnDisk], "a sample before ready: 4 pieces of an upper bound of 20 are not the head yet")
        let atReady = PlaybackStartMeasure.requiredEnds(rule, fileSize: size, headOnDisk: window, tailOnDisk: true, atReady: true)
        eq(atReady.map(\.0), [.headOnDisk, .tailOnDisk], "at ready the engine's head is on disk: both")
        check(atReady.first?.1.hasPrefix("seen at ready: bounded storage waits for at most 20 piece(s)") ?? false,
              "marked as seen at ready", atReady.first?.1 ?? "")
        let full = PlaybackStartMeasure.Readiness.engineRule(geometry, bounded: false)!
        eq(PlaybackStartMeasure.requiredEnds(full, fileSize: size, headOnDisk: window, tailOnDisk: true, atReady: true).map(\.0),
           [.tailOnDisk], "full storage: the rule is exact, nothing guessed at ready")
    }

    func testTheHeadAndTheTailAreLoggedOnceEach() {
        var lines: [String] = []
        let measure = PlaybackStartMeasure(log: { lines.append($0) })
        let sample = PlaybackStartMeasure.Sample(fileBytes: 0, downloadRate: 0, peers: 1, seeds: 1)
        check(measure.reach(.tailOnDisk, sample: sample, sinceTrace: 30, detail: "2 piece(s)"), "the tail")
        check(!measure.reach(.tailOnDisk, sample: sample, sinceTrace: 31), "once")
        check(measure.reach(.headOnDisk, sample: sample, sinceTrace: 44.6, detail: "20 piece(s)"), "then the head")
        eq(lines.map { $0.components(separatedBy: ":").first ?? "" }, ["[Measure] tail on disk", "[Measure] head on disk"],
           "two lines")
        check(lines.last?.hasPrefix("[Measure] head on disk: t+44600 ms") ?? false, "with its time", lines.last ?? "")
    }

    /// A decided start steers as soon as the remux knows the target: its line says how long
    /// after the engine's ready that was.
    func testTheSteeringSaysHowLongAfterReady() {
        var lines: [String] = []
        var now: TimeInterval = 100
        let measure = PlaybackStartMeasure(log: { lines.append($0) }, clock: { now })
        let sample = PlaybackStartMeasure.Sample(fileBytes: 0, downloadRate: 0, peers: 1, seeds: 1)
        measure.reach(.ready, sample: sample, sinceTrace: 44.6)
        now += 0.4
        measure.reach(.resumeSteering, sample: sample, sinceTrace: 45.0, detail: "read offset 5732921423, segment 132")
        check(lines.last?.hasSuffix("read offset 5732921423, segment 132, 400 ms after ready") ?? false, "400 ms after ready",
              lines.last ?? "")
        var alone: [String] = []
        let noReady = PlaybackStartMeasure(log: { alone.append($0) }, clock: { now })
        noReady.reach(.resumeSteering, sample: sample, sinceTrace: 1, detail: "read offset 1")
        check(alone.last?.hasSuffix("read offset 1") ?? false, "no ready logged: nothing added", alone.last ?? "")
    }
}
