//
//  JumpWaitProgressTests.swift
//  PopcornTimeTests
//
//  « Resuming at 22:35 — 45% · 9.6 MB/s » (PopcornKit `JumpWaitProgressRule`,
//  `JumpWaitProgressTracker`; the app's `ResumePolicy.resumingText(position:progress:)`).
//
//  Why (Apple TV, 16 November 2026): a « Resume » from a show's page waited 110 s under
//  « Resuming at 22:35… » with nothing moving on screen. The engine's window filled around a
//  front piece that came last: a count from the front only would have shown the same number for
//  100 s. The share is counted piece by piece.
//

import XCTest
import Foundation
import PopcornKit

final class JumpWaitProgressTests: CheckedTestCase {

    private typealias Rule = JumpWaitProgressRule
    private static let mib: Int64 = 1 << 20

    /// A file whose pieces (`pieceLength`, starting at `boundary`) are on disk or not.
    private struct Pieces {
        let pieceLength: Int64
        let boundary: Int64
        let size: Int64
        var have: Set<Int>   // piece numbers, the one holding `boundary` = 0 (negative: before it)

        func piece(of offset: Int64) -> Int {
            let delta = offset - boundary
            return delta >= 0 ? Int(delta / pieceLength) : -Int((-delta + pieceLength - 1) / pieceLength)
        }

        func pieceStart(_ index: Int) -> Int64 { max(0, boundary + Int64(index) * pieceLength) }

        /// The engine's `firstMissingOffset(from:)`.
        func firstMissing(_ from: Int64) -> Int64 {
            guard from < size else { return size }
            var index = piece(of: max(0, from))
            while pieceStart(index) < size {
                if !have.contains(index) { return max(from, pieceStart(index)) }
                index += 1
            }
            return size
        }
    }

    // MARK: Counting

    /// The device's resume: 8 MiB pieces, the target's bytes span 6 pieces; the window filled
    /// around the front piece, which came last.
    func testTheCountIsPieceByPieceNotOnlyFromTheFront() {
        let piece = 8 * Self.mib
        var file = Pieces(pieceLength: piece, boundary: 0, size: 100 * piece, have: [])
        let start = 50 * piece + 3 * Self.mib     // the read offset, inside piece 50
        let end = 56 * piece + 1 * Self.mib       // the keyframe two segments on, inside piece 56
        let count = { Rule.bytesOnDisk(from: start, to: end, pieceLength: piece, pieceBoundary: 0,
                                       firstMissing: file.firstMissing) }
        eq(count(), 0, "nothing there")
        file.have = [51, 52, 53, 54, 55, 56]
        eq(count(), end - 51 * piece, "everything but the front piece: counted (a count from the front says 0)")
        check(file.firstMissing(start) == start, "(the front piece is missing: a contiguous count stays at 0)")
        file.have.insert(50)
        eq(count(), end - start, "the front piece in: all of it")
        file.have = [50, 52, 56]
        eq(count(), (51 * piece - start) + piece + (end - 56 * piece), "holes anywhere: each piece on its own")
    }

    /// A season pack: the file starts in the middle of a piece; the engine's tail pin start is a
    /// piece start of the file.
    func testAFileThatStartsInsideAPieceIsCountedOnItsOwnPieces() {
        let piece = 4 * Self.mib
        let boundary = 3 * Self.mib + 12345            // a piece starts there in the file
        var file = Pieces(pieceLength: piece, boundary: boundary, size: 40 * piece, have: [])
        let start = boundary + 10 * piece + 100
        let end = boundary + 14 * piece + 100
        file.have = [11, 13]
        let tail = boundary + 37 * piece                 // what the engine says as `tailPinStart`
        eq(Rule.bytesOnDisk(from: start, to: end, pieceLength: piece, pieceBoundary: tail, firstMissing: file.firstMissing),
           2 * piece, "pieces 11 and 13 of the file, whole")
        eq(Rule.nextPieceStart(after: start, pieceLength: piece, pieceBoundary: tail), boundary + 11 * piece, "the next piece start")
        eq(Rule.filePiece(of: boundary - 1, pieceLength: piece, pieceBoundary: tail), 0, "before the first boundary: the file's first piece")
        eq(Rule.filePiece(of: boundary, pieceLength: piece, pieceBoundary: tail), 1, "the first whole piece is the file's second")
        eq(Rule.filePiece(of: 5 * piece, pieceLength: piece, pieceBoundary: 0), 5, "a file that starts the torrent")
        eq(Rule.filePiece(of: 5, pieceLength: 0, pieceBoundary: 0), nil, "no piece length: no piece")
    }

    func testWithoutThePieceLengthTheCountCanOnlyBeLower() {
        let piece = 4 * Self.mib
        let file = Pieces(pieceLength: piece, boundary: 0, size: 20 * piece, have: [3, 5, 6])
        let exact = Rule.bytesOnDisk(from: 2 * piece, to: 8 * piece, pieceLength: piece, pieceBoundary: 0,
                                     firstMissing: file.firstMissing)
        eq(exact, 3 * piece, "known piece length: three pieces")
        let probed = Rule.bytesOnDisk(from: 2 * piece, to: 8 * piece, pieceLength: 0, pieceBoundary: 0,
                                      firstMissing: file.firstMissing)
        check(probed <= exact && probed >= exact - 2 * Self.mib, "probed every MiB: at most a step less", "\(probed)")
        eq(Rule.bytesOnDisk(from: 10, to: 10, pieceLength: piece, pieceBoundary: 0, firstMissing: file.firstMissing), 0,
           "an empty range")
    }

    /// The end of the range: the keyframe two segments on, plus its Cluster (a quarter of the
    /// segment before it stands for it — on the rig the media came 0.8 MB past that keyframe in a
    /// 8.8 MB segment).
    func testTheRangeEndsPastTheClusterOfTheKeyframeTwoSegmentsOn() {
        eq(RemuxPlayback.waitProgressEnd(keyframeAfterNext: 1_159_961_417, keyframeOfNext: 1_151_129_181, fileSize: 1_643_505_184),
           1_159_961_417 + 2_208_059, "the rig's segment 114: + a quarter of segment 115")
        eq(RemuxPlayback.waitProgressEnd(keyframeAfterNext: 1000, keyframeOfNext: nil, fileSize: 5000), 1000, "no segment before it known")
        eq(RemuxPlayback.waitProgressEnd(keyframeAfterNext: 4900, keyframeOfNext: 1000, fileSize: 5000), 5000, "never past the file")
        eq(RemuxPlayback.waitProgressEnd(keyframeAfterNext: nil, keyframeOfNext: 1000, fileSize: 5000), nil,
           "the film's last segments: not known (the rate alone)")
    }

    /// Review F2: in the plan's last two segments there is no keyframe two segments on, but the
    /// bytes needed are known — what is left of the file (`hasMediaToStart` asks `isTailWritten`).
    func testAtTheFilmsEndTheRangeRunsToTheEndOfTheFile() {
        eq(RemuxPlayback.waitProgressEnd(keyframeAfterNext: nil, keyframeOfNext: 1000, fileSize: 5000, isFilmEnd: true), 5000,
           "the last segments: to the file's end")
        eq(RemuxPlayback.waitProgressEnd(keyframeAfterNext: nil, keyframeOfNext: nil, fileSize: 5000, isFilmEnd: true), 5000,
           "the very last segment: to the file's end")
        eq(RemuxPlayback.waitProgressEnd(keyframeAfterNext: nil, keyframeOfNext: nil, fileSize: 0, isFilmEnd: true), nil,
           "the file's size not known: not known")
        eq(RemuxPlayback.waitProgressEnd(keyframeAfterNext: 1000, keyframeOfNext: 600, fileSize: 5000, isFilmEnd: true), 1100,
           "a keyframe known: the keyframe rule")
        let p = progress(needed: 5000 - 4200, onDisk: 400)
        eq(ResumePolicy.resumingText(position: "1:58:40", progress: p).contains("50%"), true,
           "a jump to the end credits shows its share, not the rate alone")
    }

    // MARK: What is shown

    private func progress(waited: TimeInterval = 5, needed: Int64? = 1000, onDisk: Int64? = 450, ready: Bool = false,
                          rate: Int = 10_066_330) -> JumpWaitProgress {
        JumpWaitProgress(targetSeconds: 1355, segment: 132, waitedSeconds: waited, isJump: true, neededBytes: needed,
                         onDiskBytes: onDisk,
                         shownFraction: Rule.fraction(onDisk: onDisk, needed: needed, isMediaReady: ready),
                         isMediaReady: ready, bytesPerSecond: rate, peers: 17)
    }

    func testTheShareIs99AtMostUntilTheMediaIsWritten() {
        eq(Rule.fraction(onDisk: 450, needed: 1000, isMediaReady: false), 0.45, "45 %")
        eq(Rule.fraction(onDisk: 1000, needed: 1000, isMediaReady: false), 0.99, "every byte, not cut yet: 99 %")
        eq(Rule.fraction(onDisk: 10, needed: 1000, isMediaReady: true), 1, "the media is written: 100 %")
        eq(Rule.fraction(onDisk: nil, needed: 1000, isMediaReady: false), nil, "count unknown")
        eq(Rule.fraction(onDisk: 5, needed: nil, isMediaReady: false), nil, "bytes needed unknown")
        eq(Rule.shownPercent(progress(onDisk: 1000)), 99, "99, not 100")
        eq(Rule.shownPercent(progress(onDisk: 999, ready: true)), 100, "100 once written")
        eq(Rule.shownPercent(progress(onDisk: 456)), 45, "rounded down")
    }

    func testNothingButThePositionForTheFirstSecond() {
        eq(Rule.shownPercent(progress(waited: 0.6)), nil, "0.6 s: no share (no flicker on a quick jump)")
        eq(Rule.shownRate(progress(waited: 0.6)), nil, "nor rate")
        eq(ResumePolicy.resumingText(position: "22:35", progress: progress(waited: 0.6)), "Resuming at 22:35…",
           "the label as before")
        eq(ResumePolicy.resumingText(position: "22:35", progress: nil), "Resuming at 22:35…", "no progress known")
    }

    /// Review F1: a resume's jump starts the jump's clock again, not the label's — the share
    /// « Resuming at 11:29 — 23% · 2.3 MB/s » showed while the resume steered, it stays across the
    /// jump (it went away for a tick, then came back: numbers, bare text, numbers).
    func testAResumesJumpKeepsTheShareTheLabelAlreadyShowed() {
        let steering = progress(waited: 3)
        check(Rule.shownPercent(steering) != nil, "3 s of steering: the share shows")
        var afterJump = progress(waited: 0.2)
        afterJump.labelSeconds = 3.2
        eq(Rule.shownPercent(afterJump), 45, "0.2 s after the resume's jump: the share stays")
        check(Rule.shownRate(afterJump) != nil, "and the rate")
        eq(ResumePolicy.resumingText(position: "22:35", progress: afterJump),
           ResumePolicy.resumingText(position: "22:35", progress: steering), "the same text across the jump")
        eq(Rule.labelClockStart(jumpStartedAt: 103, isResumeJump: true, resumeStartedAt: 100), 100,
           "a resume's jump: the label's clock from the resume's preparation")
        eq(Rule.labelClockStart(jumpStartedAt: 103, isResumeJump: false, resumeStartedAt: 100), 103,
           "a far jump or a rewind: its own clock (no share for its first second)")
        eq(Rule.labelClockStart(jumpStartedAt: 103, isResumeJump: true, resumeStartedAt: nil), 103,
           "no preparation known: the jump's clock")
        var quick = progress(waited: 0.2)
        quick.labelSeconds = 0.4
        eq(Rule.shownPercent(quick), nil, "a wait of 0.4 s on the label's clock: still nothing")
        eq(Rule.logStep(waited: afterJump.waitedSeconds, lastLogged: nil), nil,
           "the [Resume] jump wait lines keep the jump's clock")
    }

    func testTheLabelSaysTheShareAndTheRate() {
        let rate = LoadingPhase.formatRate(10_066_330)
        eq(ResumePolicy.resumingText(position: "22:35", progress: progress()), "Resuming at 22:35 — 45% · \(rate)",
           "the share and the loading screen's rate")
        check(rate == "9.6 MB/s" || rate == "9,6 MB/s" || rate == "9,6 Mo/s", "the loading screen's formatter", rate)
        eq(ResumePolicy.resumingText(position: "22:35", progress: progress(needed: nil)), "Resuming at 22:35 — \(rate)",
           "the bytes needed not known: the rate alone")
        eq(ResumePolicy.resumingText(position: "22:35", progress: progress(rate: 0)), "Resuming at 22:35 — 45%",
           "nothing coming in: the share alone")
        eq(ResumePolicy.resumingText(position: "22:35", progress: progress(needed: nil, rate: 0)), "Resuming at 22:35…",
           "nothing to say: the label as before")
        eq(ResumePolicy.resumingText(position: "1:28:20", progress: progress(onDisk: 1000, ready: true)),
           "Resuming at 1:28:20 — 100% · \(rate)", "the longest English shape")
    }

    func testTheProgressShownIsTheLabelsTarget() {
        let p = progress()
        eq(ResumePolicy.progress(p, forTarget: 1355), p, "the same position")
        eq(ResumePolicy.progress(p, forTarget: 1350.3), p, "the same segment")
        eq(ResumePolicy.progress(p, forTarget: 2000), nil, "another jump's: not under this label")
        eq(ResumePolicy.progress(p, forTarget: nil), p, "the start's resume: the remux's own target")
        var unknown = p
        unknown.targetSeconds = nil
        eq(ResumePolicy.progress(unknown, forTarget: 1355), nil, "a progress without target under a jump's label: no")
        eq(ResumePolicy.progress(nil, forTarget: 1355), nil, "none")
    }

    func testTheShareNeverGoesBackForTheSameTarget() {
        var tracker = JumpWaitProgressTracker()
        let key = JumpWaitProgressTracker.Key(segment: 132, startOffset: 5_732_921_423)
        eq(tracker.shown(0.10, for: key), 0.10, "10 %")
        eq(tracker.shown(0.40, for: key), 0.40, "40 %")
        eq(tracker.shown(0.35, for: key), 0.40, "a piece fetched again: still 40 %")
        eq(tracker.shown(nil, for: key), 0.40, "a look without a count: still 40 %")
        eq(tracker.shown(1, for: key), 1, "written")
        let other = JumpWaitProgressTracker.Key(segment: 429, startOffset: 4_400_000_000)
        eq(tracker.shown(0.05, for: other), 0.05, "another target starts from its own count")
        tracker.reset()
        eq(tracker.best, nil, "forgotten")
    }

    // MARK: The [Resume] jump wait lines

    func testTheLinesComeAt2_5_10ThenEvery10Seconds() {
        var logged: Int?
        var steps: [Int] = []
        for tenth in 0...450 {
            if let step = Rule.logStep(waited: Double(tenth) / 10 + 0.05, lastLogged: logged) {
                logged = step
                steps.append(step)
            }
        }
        eq(steps, [2, 5, 10, 20, 30, 40], "+2, +5, +10 s, then every 10 s")
        eq(Rule.logStep(waited: 7.2, lastLogged: 2), 5, "a late look logs the step it passed")
        eq(Rule.logStep(waited: 1.9, lastLogged: nil), nil, "not before 2 s")
        eq(Rule.logStep(waited: .nan, lastLogged: nil), nil, "no time")
    }

    func testTheLineSaysWhatTheTextSaysAndWhereTheReaderWaits() {
        var p = progress(needed: 80_000_000, onDisk: 12_345_678)
        p.reader = 5_732_921_423
        p.firstMissing = 5_740_000_000
        p.firstMissingPiece = 683
        p.window = 0.45
        eq(Rule.logLine(step: 5, p),
           "[Resume] jump wait +5 s: reader 5732921423, first missing 5740000000 (piece 683 of the file), "
           + "on disk 12345678 of 80000000 bytes of the target (15 %), window 45 %, 10.1 MB/s, 17 peers — target 1355.0 s, segment 132",
           "the line")
        let unknown = progress(needed: nil, onDisk: nil)
        eq(Rule.logLine(step: 10, unknown),
           "[Resume] jump wait +10 s: reader ?, first missing ?, bytes of the target not known, 10.1 MB/s, 17 peers — target 1355.0 s, segment 132",
           "what is not known says so")
    }

    func testAJumpWaitPausedByTheUserShowsAsAPause() {
        check(ResumePolicy.hidesJumpLabelOnPause(isWaitingForPlay: true, isResumingNatively: false, isLabelShown: true),
              "paused during a jump's wait: « Reprise à … » and its spinner go (the rig: 100 % over a spinner for 3 min 30)")
        check(!ResumePolicy.hidesJumpLabelOnPause(isWaitingForPlay: false, isResumingNatively: false, isLabelShown: true),
              "waiting for data: the label stays")
        check(!ResumePolicy.hidesJumpLabelOnPause(isWaitingForPlay: true, isResumingNatively: true, isLabelShown: true),
              "the start's resume keeps its cover and label")
        check(!ResumePolicy.hidesJumpLabelOnPause(isWaitingForPlay: true, isResumingNatively: false, isLabelShown: false),
              "nothing shown: nothing to hide")
    }

    func testAPressWhileTheResumesItemIsPutInPlaceGoesToTheResumePoint() {
        let invalid = -9_223_372_036_854_776.0
        eq(ResumePolicy.startSeekOverride(isResumingNatively: true, awaitingStartSeek: true, isItemReady: false, resumeTarget: 393.9),
           393.9, "before the start seek, item not ready (the rig's \(invalid) s): AVKit goes to the resume point")
        eq(ResumePolicy.startSeekOverride(isResumingNatively: true, awaitingStartSeek: false, isItemReady: false, resumeTarget: 393.9),
           393.9, "item not ready: the same")
        eq(ResumePolicy.startSeekOverride(isResumingNatively: true, awaitingStartSeek: false, isItemReady: true, resumeTarget: 393.9),
           nil, "the start seek issued on a ready item: the press is a move (the new start)")
        eq(ResumePolicy.startSeekOverride(isResumingNatively: false, awaitingStartSeek: true, isItemReady: false, resumeTarget: 393.9),
           nil, "not a native resume: AVKit's as usual")
        eq(ResumePolicy.startSeekOverride(isResumingNatively: true, awaitingStartSeek: true, isItemReady: false, resumeTarget: nil),
           nil, "no resume point known: AVKit's as usual")
    }
}
