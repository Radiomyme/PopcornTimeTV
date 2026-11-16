//
//  UserNavigationTests.swift
//  PopcornTimeTests
//
//  A move in the film the player does not show (PopcornKit `UserNavigationTarget`,
//  `HoleRequestRule`) and what the starvation recovery does with one
//  (`PlaybackStarvationRecovery.userNavigated`, `waitForJump(…rebuildsWhilePaused:…)`).
//
//  Why (Apple TV, 15 November 2026, 5.3.0 m1-gate): a film resumed natively at 1:06:38, paused,
//  then taken back about ten minutes with the Siri Remote — into the segments the resume's jump
//  skipped. No jump: the conversion only hears `currentTime()`, which on the device kept
//  4002.9 s while AVKit's seek was held. The item failed (-12889) and the recovery started AT
//  4002.9 s, waiting for a Play press, under a silent spinner. A stand-in build that keeps
//  `currentTime()` at the pre-seek time while AVKit's seek is pending reproduces that log line
//  for line (fx-repro.md); the inputs below are that device's.
//

import XCTest
import AVFoundation
import PopcornKit

final class UserNavigationTests: CheckedTestCase {

    // MARK: UserNavigationTarget

    /// The device: paused at 4002.9 s, navigated to 3402.9 s; `currentTime()` keeps 4002.9 s for
    /// the whole hold (dozens of ticks), then, the seek given up, AVPlayer puts it back there.
    func testATargetTheHeldSeekDoesNotShowIsWhereThePlayerWantsData() {
        var navigation = UserNavigationTarget()
        eq(navigation.wanted(current: 4002.9, played: 4002.9, clock: 100), 4002.9, "no move: currentTime()")
        navigation.navigated(from: 4002.9, to: 3402.9, played: 4002.9, clock: 100)
        eq(navigation.target, 3402.9, "the move is noted")
        for tick in 0..<45 {
            eq(navigation.wanted(current: 4002.9, played: 4002.9, clock: 100 + Double(tick)), 3402.9,
               "tick \(tick): currentTime() still reads the old time — the target is wanted")
        }
        // The item failed: AVPlayer reset currentTime() to before the seek.
        eq(navigation.wanted(current: 4002.9, played: 4002.9, clock: 150), 3402.9, "after the reset: still the target")
        eq(navigation.target, 3402.9, "kept for the failure's recovery")
        // Unknown time (no item, NaN): the target.
        eq(navigation.wanted(current: .nan, played: 4002.9, clock: 151), 3402.9, "an unknown time: the target")
        eq(navigation.wanted(current: nil, played: 4002.9, clock: 151), 3402.9, "no time at all: the target")
    }

    /// The simulator: `currentTime()` reads the target at once — it is the same answer.
    func testATargetTheSeekShowsIsCurrentTime() {
        var navigation = UserNavigationTarget()
        navigation.navigated(from: 697.7, to: 397.7, played: 697.7, clock: 10)
        eq(navigation.wanted(current: 397.66, played: 697.7, clock: 10.3), 397.66, "the seek shows: currentTime()")
        eq(navigation.target, 397.7, "the target stays until playback ran")
        // Playback ran at the target: done.
        eq(navigation.wanted(current: 399.0, played: 398.5, clock: 20), 399.0, "played since: currentTime()")
        eq(navigation.target, nil, "and the target is dropped")
    }

    func testPlaybackRecordedSinceTheMoveDropsIt() {
        var navigation = UserNavigationTarget()
        navigation.navigated(from: 697.7, to: 397.7, played: 697.7, clock: 10)
        eq(navigation.wanted(current: 698.7, played: 698.7, clock: 11), 698.7,
           "it played on at the old place (no seek happened): currentTime()")
        eq(navigation.target, nil, "dropped")
        navigation.navigated(from: 697.7, to: 397.7, played: nil, clock: 10)
        eq(navigation.wanted(current: 697.7, played: nil, clock: 11), 397.7, "nothing played before or since: the target")
        eq(navigation.wanted(current: 697.7, played: 697.0, clock: 12), 697.7, "a first played position: dropped")
    }

    func testAnotherMoveSinceWinsOverTheTarget() {
        var navigation = UserNavigationTarget()
        navigation.navigated(from: 697.7, to: 397.7, played: 697.7, clock: 10)
        eq(navigation.wanted(current: 900.0, played: 697.7, clock: 11), 900.0,
           "the playhead went neither to the target nor stayed: another move — currentTime()")
        eq(navigation.target, nil, "dropped")
    }

    /// While playing, the old time may still advance a little before the seek takes over.
    func testTheOldTimeMayAdvanceAtPlaybackSpeedMeanwhile() {
        var navigation = UserNavigationTarget()
        navigation.navigated(from: 697.7, to: 687.7, played: 697.7, clock: 10)
        eq(navigation.wanted(current: 699.2, played: 697.7, clock: 11), 687.7, "1.5 s on after 1 s: still the old place")
        eq(navigation.wanted(current: 703.0, played: 697.7, clock: 12.5), 687.7, "5.3 s on after 2.5 s: at most 2× + 1 s")
        eq(navigation.wanted(current: 696.9, played: 697.7, clock: 12.5), 687.7, "a hair before it: the old place")
        eq(navigation.wanted(current: 720.0, played: 697.7, clock: 13), 720.0, "22 s on after 3 s: elsewhere")
        eq(navigation.target, nil, "dropped")
    }

    func testAnUnusableMoveChangesNothing() {
        var navigation = UserNavigationTarget()
        navigation.navigated(from: 10, to: .nan, played: 10, clock: 1)
        navigation.navigated(from: 10, to: -1, played: 10, clock: 1)
        eq(navigation.target, nil, "no target")
        eq(navigation.wanted(current: 10, played: 10, clock: 2), 10, "currentTime()")
        eq(navigation.wanted(current: -3, played: 10, clock: 2), nil, "a negative time is unknown")
        navigation.navigated(from: .nan, to: 300, played: 10, clock: 1)
        eq(navigation.wanted(current: 500, played: 10, clock: 2), 300, "where it came from unknown: the target")
        navigation.clear()
        eq(navigation.target, nil, "cleared")
        eq(navigation.from, nil, "with where it came from")
    }

    // MARK: HoleRequestRule

    func testAHoleBehindTheReportedSegmentIsASeek() {
        check(HoleRequestRule.isSeekBehind(index: 65, reportedSegment: 116, hasPlayed: true, isStartLocked: false),
              "segment 65 while 116 is reported: AVPlayer seeks back")
        check(HoleRequestRule.isSeekBehind(index: 115, reportedSegment: 116, hasPlayed: true, isStartLocked: false),
              "the segment right behind: a seek too (playback never reads backwards)")
        check(!HoleRequestRule.isSeekBehind(index: 116, reportedSegment: 116, hasPlayed: true, isStartLocked: false),
              "the reported segment itself: the playhead's")
        check(!HoleRequestRule.isSeekBehind(index: 130, reportedSegment: 116, hasPlayed: true, isStartLocked: false),
              "ahead: a prefetch, never a seek by this rule")
        check(!HoleRequestRule.isSeekBehind(index: 2, reportedSegment: 389, hasPlayed: false, isStartLocked: false),
              "nothing played yet: an item loading at 0 before its resume seek asks for 1, 2…")
        check(!HoleRequestRule.isSeekBehind(index: 2, reportedSegment: 389, hasPlayed: true, isStartLocked: true),
              "under the start lock: the resume's own seek")
        check(!HoleRequestRule.isSeekBehind(index: 2, reportedSegment: nil, hasPlayed: true, isStartLocked: false),
              "no position reported: nothing to be behind")
    }

    func testAHoleRequestMovesThePlayerOnlyWhenTheWantedPositionDoesNotSaySo() {
        check(HoleRequestRule.movesPlayer(segmentStart: 390, segmentEnd: 396, wanted: 4002.9),
              "the device: wanted still reads the old time")
        check(HoleRequestRule.movesPlayer(segmentStart: 390, segmentEnd: 396, wanted: nil), "wanted unknown")
        check(!HoleRequestRule.movesPlayer(segmentStart: 390, segmentEnd: 396, wanted: 393.5),
              "the simulator: wanted already in the segment — the conversion heard")
        check(!HoleRequestRule.movesPlayer(segmentStart: 390, segmentEnd: 396, wanted: 389.4), "a hair before it")
        check(!HoleRequestRule.movesPlayer(segmentStart: 390, segmentEnd: 396, wanted: 396.8), "a hair after it")
        check(HoleRequestRule.movesPlayer(segmentStart: 390, segmentEnd: 396, wanted: 380), "elsewhere")
        check(!HoleRequestRule.movesPlayer(segmentStart: .nan, segmentEnd: 396, wanted: 4002.9), "no usable start")
    }

    // MARK: Review fixes (fx-fixed2)

    /// E5: after a move FORWARD, the holes between the old playhead and the target are no seek
    /// back — the request is judged against the lower of the played and wanted positions.
    func testAHoleIsJudgedAgainstThePlayheadNotATargetAheadOfIt() {
        eq(HoleRequestRule.referencePosition(played: 690, wanted: 900), 690, "forward: the playhead")
        eq(HoleRequestRule.referencePosition(played: 690, wanted: 390), 390, "back: the target")
        eq(HoleRequestRule.referencePosition(played: nil, wanted: 900), 900, "nothing played: wanted")
        eq(HoleRequestRule.referencePosition(played: 690, wanted: nil), 690, "nothing wanted: played")
        eq(HoleRequestRule.referencePosition(played: nil, wanted: nil), nil, "neither")
        eq(HoleRequestRule.referencePosition(played: .nan, wanted: 900), 900, "an unusable time is ignored")
    }

    /// E5: a target AVKit's delegate gave is the user's word; a guess from a request is not.
    func testADelegateTargetIsConfirmedAndAGuessIsNot() {
        var navigation = UserNavigationTarget()
        navigation.navigated(from: 690, to: 900, played: 690, clock: 1)
        check(navigation.isConfirmed, "the delegate's move is confirmed by default")
        navigation.navigated(from: 690, to: 392.5, played: 690, clock: 2, confirmed: false)
        check(!navigation.isConfirmed, "the server net's guess is not")
        navigation.clear()
        check(!navigation.isConfirmed, "nothing pending: nothing confirmed")
    }

    /// A4: why a target was dropped is kept for the log; how long it has been pending too.
    func testADroppedTargetSaysWhy() {
        var navigation = UserNavigationTarget()
        navigation.navigated(from: 697.7, to: 397.7, played: 697.7, clock: 10)
        eq(navigation.age(clock: 13), 3, "pending for 3 s")
        eq(navigation.lastDrop, nil, "not dropped")
        _ = navigation.wanted(current: 399.0, played: 398.5, clock: 20)
        eq(navigation.lastDrop, .played, "playback ran")
        eq(navigation.age(clock: 21), nil, "nothing pending")
        navigation.navigated(from: 697.7, to: 397.7, played: 697.7, clock: 30)
        eq(navigation.lastDrop, nil, "a new move: no drop yet")
        _ = navigation.wanted(current: 900, played: 697.7, clock: 31)
        eq(navigation.lastDrop, .elsewhere, "another move")
    }

    /// Checker R4 (1 run in 3): 20 quick presses during a jump wait; a new item went in at 688.2 s,
    /// then AVKit counted the next press from the new item's start (`0.0 → 10.0 s`) while the
    /// player read 688.5 s — the film played at 0:20.
    func testANavigationCountedFromANewItemsStartIsTheSameStepFromThePlayhead() {
        eq(NavigationRebase.target(old: 0.0, target: 10.0, current: 688.5, sinceReplacement: 0.4), 698.5,
           "the checker's run: one step forward from 688.5 s")
        eq(NavigationRebase.target(old: 0.0, target: 0.0, current: 688.5, sinceReplacement: 0.4), 688.5, "no step: where it is")
        eq(NavigationRebase.target(old: 0.2, target: -9.8, current: 688.5, sinceReplacement: 2), 678.5, "a step back")
        eq(NavigationRebase.target(old: 0.0, target: 10.0, current: 688.5, sinceReplacement: nil), 10.0, "no replacement: as asked")
        eq(NavigationRebase.target(old: 0.0, target: 10.0, current: 688.5, sinceReplacement: 30), 10.0, "long after it: as asked")
        eq(NavigationRebase.target(old: 0.0, target: 10.0, current: 2.0, sinceReplacement: 1), 10.0,
           "the player really near the start: as asked")
        eq(NavigationRebase.target(old: 680.0, target: 690.0, current: 688.5, sinceReplacement: 1), 690.0,
           "counted from where it was: as asked")
        eq(NavigationRebase.target(old: 0.0, target: 10.0, current: .nan, sinceReplacement: 1), 10.0, "time unknown: as asked")
    }

    /// 5.3.0 fusion (fx-gate into b-gate): the Apple TV's end of the item tells the « next
    /// episode » countdown the file is over — it starts the next episode, or closes the player
    /// once the card was dismissed. A 22-minute episode (1320 s): not while a jump's wait keeps
    /// the old item at its rate, nor while a rewind is pending.
    func testAnEndOfTheItemIsTheFilesEndOnlyWhereTheUserIs() {
        check(UpNextNavigationRule.isFileEnd(isRecovering: false, pendingTarget: nil, duration: 1320),
              "no navigation pending: the end")
        check(!UpNextNavigationRule.isFileEnd(isRecovering: true, pendingTarget: nil, duration: 1320),
              "a recovery (a jump's wait, a rebuild) runs: not the file's end")
        check(!UpNextNavigationRule.isFileEnd(isRecovering: true, pendingTarget: 1319.5, duration: 1320),
              "a recovery runs, even toward the end: its new item tells the end")
        check(!UpNextNavigationRule.isFileEnd(isRecovering: false, pendingTarget: 720, duration: 1320),
              "a rewind of ten minutes pending: not the file's end")
        check(!UpNextNavigationRule.isFileEnd(isRecovering: false, pendingTarget: 1259.9, duration: 1320),
              "pending just over a minute before the end: not the file's end")
        check(UpNextNavigationRule.isFileEnd(isRecovering: false, pendingTarget: 1260, duration: 1320),
              "pending a minute before the end: may be the end")
        check(UpNextNavigationRule.isFileEnd(isRecovering: false, pendingTarget: 1315, duration: 1320),
              "a skip to the last seconds pending: the end")
        check(UpNextNavigationRule.isFileEnd(isRecovering: false, pendingTarget: 720, duration: nil),
              "length unknown (EVENT playlist): the end counts, as before")
        check(UpNextNavigationRule.isFileEnd(isRecovering: false, pendingTarget: 720, duration: .nan),
              "length not finite: the end counts")
        check(UpNextNavigationRule.isFileEnd(isRecovering: false, pendingTarget: .nan, duration: 1320),
              "an unusable target: the end counts")
    }

    /// E1: during a jump wait that keeps the rate, the old item plays once its held request is
    /// answered — its playback is no user seek (run R2: « user seek to 900.4 s » for 898.4 s).
    func testPlaybackOfAPlayingItemIsNoUserSeek() {
        eq(StarvationPolicy.userSeekTarget(observed: 899.5, lastObserved: 898.4, playing: true, elapsed: 1.05), nil,
           "1.1 s on in 1.05 s, playing: playback")
        eq(StarvationPolicy.userSeekTarget(observed: 901.4, lastObserved: 898.4, playing: true, elapsed: 1.05), nil,
           "3 s on in 1.05 s: up to 2× + 1 s, still playback")
        eq(StarvationPolicy.userSeekTarget(observed: 908.4, lastObserved: 898.4, playing: true, elapsed: 1.0), 908.4,
           "+10 s in 1 s: a skip")
        eq(StarvationPolicy.userSeekTarget(observed: 888.4, lastObserved: 898.4, playing: true, elapsed: 1.0), 888.4,
           "back: always a seek")
        eq(StarvationPolicy.userSeekTarget(observed: 899.5, lastObserved: 898.4, playing: false, elapsed: 1.05), 899.5,
           "paused: any move over 1 s is the user's, as before")
        eq(StarvationPolicy.userSeekTarget(observed: 898.9, lastObserved: 898.4, playing: true, elapsed: 1), nil,
           "under the threshold: nothing")
    }
}

/// What the starvation recovery does with a user navigation, and the paused jump wait that
/// rebuilds anyway — on a real AVPlayer (items on a file that does not exist: nothing plays).
@MainActor
final class UserNavigationRecoveryTests: CheckedTestCase {

    private func item() -> AVPlayerItem {
        AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-popcorntime-test/master.m3u8"))
    }

    private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 8) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        return condition()
    }

    private func starvation() -> AVPlayerItemFailureObserver.Failure {
        AVPlayerItemFailureObserver.Failure(kind: .failedToPlayToEnd,
                                            error: NSError(domain: "CoreMediaErrorDomain", code: -12889),
                                            reason: "Lecture interrompue (CoreMediaErrorDomain -12889)")
    }

    /// The device's second half: the item failed with the user paused — the recovery waits for
    /// play. A navigation then (AVKit resumes after it) is the new target and ends that wait.
    func testANavigationDuringAWaitForPlayIsTheTargetAndPlaybackResumesThere() {
        let player = AVPlayer(playerItem: item())
        let recovery = PlaybackStarvationRecovery()
        var waiting: [Bool] = []
        var retargets: [Double] = []
        var intents: [Bool] = []
        var made: [AVPlayerItem] = []
        var asked: [Double] = []
        var dataReady = false
        recovery.onWaitingChanged = { waiting.append($0) }
        recovery.onRetarget = { retargets.append($0) }
        recovery.onUserPlaybackChanged = { intents.append($0) }
        recovery.makeItem = { [weak self] in
            guard let new = self?.item() else { return nil }
            made.append(new)
            return new
        }
        check(recovery.handle(starvation(), player: player, position: 4002.9, resumesPlayback: false,
                              stillDownloading: true) { time, _ in
            asked.append(time)
            return dataReady
        }, "a starvation recovery")
        check(recovery.isWaitingForPlay, "the paused user's: it waits for play (the device's log line)")
        eq(waiting, [], "no spinner")

        check(recovery.userNavigated(to: 3402.9, from: 4002.9, resumesPlayback: true), "the navigation is taken")
        eq(recovery.resumeTime, 3402.9, "at the navigation's target, not the old position")
        check(recovery.resumeTimeIsUserTarget, "the user's target")
        eq(retargets, [3402.9], "the owner hears of it (the conversion jumps there)")
        check(!recovery.isWaitingForPlay, "no Play press is waited for: AVKit resumes after a navigation")
        eq(intents, [true], "the owner's play intent follows")
        eq(waiting, [true], "the wait shows")

        check(waitUntil({ asked.count >= 1 }), "the data at the target is asked for", "\(asked)")
        check(asked.allSatisfy { $0 == 3402.9 }, "only at the target", "\(asked)")
        check(made.isEmpty, "nothing made before the data is there")
        dataReady = true
        check(waitUntil({ !made.isEmpty }), "a new item once the data is there, without a Play press")
        recovery.cancel()
    }

    func testANavigationToWhereTheWaitIsChangesOnlyThePlayIntent() {
        let player = AVPlayer(playerItem: item())
        let recovery = PlaybackStarvationRecovery()
        var retargets: [Double] = []
        recovery.onRetarget = { retargets.append($0) }
        check(recovery.waitForJump(player: player, at: 397.7, resumesPlayback: false) { _, _ in false }, "a paused jump wait")
        check(recovery.isWaitingForPlay, "waiting for play")
        check(recovery.userNavigated(to: 397.9, from: 697.7, resumesPlayback: true), "taken")
        eq(retargets, [], "the same position: no retarget")
        eq(recovery.resumeTime, 397.7, "the wait's position")
        check(!recovery.isWaitingForPlay, "but it no longer waits for play")
        recovery.cancel()
    }

    func testANavigationToAPositionThatCanNeverPlayNativelyGivesUpThere() {
        let player = AVPlayer(playerItem: item())
        let recovery = PlaybackStarvationRecovery()
        var gaveUp: [String] = []
        recovery.positionUnavailable = { $0 < 100 }
        recovery.onGiveUp = { gaveUp.append($0) }
        check(recovery.waitForJump(player: player, at: 397.7) { _, _ in false }, "a jump wait")
        check(recovery.userNavigated(to: 50, from: 397.7, resumesPlayback: true), "taken")
        eq(gaveUp.count, 1, "given up at once")
        eq(recovery.abandonedTime, 50, "at the navigation's target")
        check(!recovery.isRecovering, "the recovery ended")
    }

    func testANavigationWithoutARecoveryIsNotTheRecoverys() {
        let player = AVPlayer(playerItem: item())
        let recovery = PlaybackStarvationRecovery()
        check(!recovery.userNavigated(to: 300, from: 600, resumesPlayback: true), "no recovery: nothing to do")
        check(recovery.rebuildNow(player: player, at: 600, reason: "stuck"), "a stuck item's rebuild")
        check(!recovery.userNavigated(to: 300, from: 600, resumesPlayback: true), "a stuck item's rebuild is not a wait")
        recovery.cancel()
        check(recovery.waitForJump(player: player, at: 600) { _, _ in false }, "a jump wait")
        check(!recovery.userNavigated(to: .nan, from: 600, resumesPlayback: true), "no usable target")
        recovery.cancel()
    }

    /// A paused user who moved (iOS −10 s, a Mac arrow, a hole AVPlayer asked for): the picture
    /// there, paused — not a wait for a press they have no reason to give.
    func testAPausedJumpWaitThatRebuildsWhilePausedPutsANewItemThereLeftPaused() {
        let first = item()
        let player = AVPlayer(playerItem: first)
        let recovery = PlaybackStarvationRecovery()
        var waiting: [Bool] = []
        var made: [AVPlayerItem] = []
        var resumed: [Double] = []
        var dataReady = false
        recovery.onWaitingChanged = { waiting.append($0) }
        recovery.onResumed = { resumed.append($0) }
        recovery.makeItem = { [weak self] in
            guard let new = self?.item() else { return nil }
            made.append(new)
            return new
        }
        check(recovery.waitForJump(player: player, at: 397.7, resumesPlayback: false, rebuildsWhilePaused: true) { _, _ in
            dataReady
        }, "the wait is taken")
        check(recovery.isRecovering && recovery.isWaitingForJump, "a jump's wait")
        check(!recovery.isWaitingForPlay, "no wait for a Play press")
        eq(waiting, [true], "the wait shows (« Reprise à … »)")
        check(!waitUntil({ !made.isEmpty }, seconds: 1.2), "nothing made before the media is there")
        dataReady = true
        check(waitUntil({ !made.isEmpty }), "a new item once the media is there, the user still paused")
        check(player.currentItem === made.first, "it is the player's item")
        eq(player.rate, 0, "paused")
        eq(resumed, [], "and not played (no onResumed) — the rebuild ends paused once its seek is done")
        recovery.cancel()
    }

    /// tvOS: a jump wait of a user who wants playback keeps the player's rate, so the Siri
    /// Remote's presses stay skips AVKit reports (not a scrub it commits later); the rebuild
    /// pauses it before the new item goes in, then the owner plays.
    func testAJumpWaitThatKeepsThePlayerRateLeavesItPlayingUntilTheRebuild() {
        let player = AVPlayer(playerItem: item())
        let recovery = PlaybackStarvationRecovery()
        var made: [AVPlayerItem] = []
        var dataReady = false
        recovery.makeItem = { [weak self] in
            guard let new = self?.item() else { return nil }
            made.append(new)
            return new
        }
        player.play()
        check(recovery.waitForJump(player: player, at: 397.7, keepsPlayerRate: true) { _, _ in dataReady }, "the wait is taken")
        eq(player.rate, 1, "not paused while the media is waited for")
        check(recovery.userNavigated(to: 300, from: 397.7, resumesPlayback: true), "a skip during the wait")
        eq(recovery.resumeTime, 300, "is the new target")
        dataReady = true
        check(waitUntil({ !made.isEmpty }), "a new item once the media is there")
        eq(player.rate, 0, "paused by the rebuild until the new item sits at the position")
        recovery.cancel()

        let paused = AVPlayer(playerItem: item())
        paused.play()
        check(recovery.waitForJump(player: paused, at: 397.7, resumesPlayback: false, rebuildsWhilePaused: true,
                                   keepsPlayerRate: true) { _, _ in false }, "a paused user's wait")
        eq(paused.rate, 0, "a paused user's wait pauses the player as before")
        recovery.cancel()
    }

    /// The same wait, the item failing meanwhile (its held request timed out): the recovery goes
    /// on rebuilding while paused, it does not start waiting for play.
    func testAPausedJumpWaitWhoseItemFailsStillRebuildsWhilePaused() {
        let player = AVPlayer(playerItem: item())
        let recovery = PlaybackStarvationRecovery()
        var made = 0
        var dataReady = false
        recovery.makeItem = { [weak self] in
            made += 1
            return self?.item()
        }
        check(recovery.waitForJump(player: player, at: 397.7, resumesPlayback: false, rebuildsWhilePaused: true) { _, _ in
            dataReady
        }, "the wait is taken")
        check(recovery.handle(starvation(), player: player, position: 697.7, resumesPlayback: false,
                              stillDownloading: true) { _, _ in dataReady }, "the waited item failed: still recovering")
        eq(recovery.resumeTime, 397.7, "at the jump's position, not where the item stood")
        check(!recovery.isWaitingForPlay, "still no wait for a Play press")
        dataReady = true
        check(waitUntil({ made > 0 }), "rebuilt once the media is there")
        recovery.cancel()
    }

    /// A1: the OLD item a jump wait left in place fails (its held request timed out, -12889):
    /// the wait goes on as it was — still a jump wait, the player's rate kept (remote presses stay
    /// skips), no attempt spent, no starvation recovery started.
    func testTheOldItemFailingDuringAJumpWaitChangesNothing() {
        let player = AVPlayer(playerItem: item())
        let recovery = PlaybackStarvationRecovery()
        var waiting: [Bool] = []
        recovery.onWaitingChanged = { waiting.append($0) }
        player.play()
        check(recovery.waitForJump(player: player, at: 397.7, keepsPlayerRate: true) { _, _ in false }, "the wait is taken")
        eq(player.rate, 1, "the rate is kept")
        check(recovery.handle(starvation(), player: player, position: 697.7, resumesPlayback: true,
                              stillDownloading: true) { _, _ in false }, "the old item's failure is taken")
        check(recovery.isWaitingForJump, "still a jump wait (« [Resume] jump: a new item plays … » will say so)")
        eq(recovery.resumeTime, 397.7, "at the jump's position")
        eq(player.rate, 1, "the player is not paused: presses stay skips")
        eq(recovery.attemptsWithoutProgress, 0, "no starvation attempt spent")
        eq(recovery.recoveryCount, 0, "no starvation recovery")
        eq(waiting, [true], "the wait shows once, nothing hides it")
        recovery.cancel()
    }

    /// A5: a user who paused, then navigated (AVKit resumes after a confirmed move, but only once
    /// its held seek completes): the jump wait that keeps the rate plays the player — so presses
    /// during « Reprise à … » are skips AVKit reports, not a paused scrub it commits later.
    func testAJumpWaitThatKeepsTheRateOfAUserWhoWantsPlaybackPlaysAPausedPlayer() {
        let player = AVPlayer(playerItem: item())
        let recovery = PlaybackStarvationRecovery()
        var intents: [Bool] = []
        recovery.onUserPlaybackChanged = { intents.append($0) }
        eq(player.rate, 0, "paused")
        check(recovery.waitForJump(player: player, at: 397.7, resumesPlayback: true, rebuildsWhilePaused: true,
                                   keepsPlayerRate: true) { _, _ in false }, "the wait is taken")
        eq(player.rate, 1, "played, as AVKit would after the move")
        check(!recovery.isWaitingForPlay, "no wait for a Play press")
        // The rate note of that play is no user transition.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        eq(intents, [], "the recovery's own play is not taken for the user's")
        recovery.cancel()
    }

    /// X2 (s3 check, 1 run in 2): a paused move 91.8 → 151.8 s into a hole, slow download; 42 s
    /// later AVPlayer gave up on its held seek and put its time back to 91.8 s WITHOUT failing the
    /// item — taken for a user seek, the target was lost. The jump wait now knows where the move
    /// came from: a look that finds the time back there is no user seek.
    func testAJumpWaitKnowsWhereItsMoveCameFrom() {
        eq(StarvationPolicy.seekResetOrigin(target: 151.8, seekOrigin: 91.8, playerTime: 91.8), 91.8, "the navigation's origin")
        eq(StarvationPolicy.seekResetOrigin(target: 151.8, seekOrigin: nil, playerTime: 91.8), 91.8,
           "no navigation known: the player's time, which still reads the old position")
        eq(StarvationPolicy.seekResetOrigin(target: 151.8, seekOrigin: nil, playerTime: 151.5), nil,
           "the player already reads the target: nothing to tell apart")
        eq(StarvationPolicy.seekResetOrigin(target: 151.8, seekOrigin: 151.3, playerTime: 60), 60,
           "an origin at the target is no origin: the player's time")
        eq(StarvationPolicy.seekResetOrigin(target: 151.8, seekOrigin: .nan, playerTime: .nan), nil, "nothing usable")

        let player = AVPlayer(playerItem: item())
        let recovery = PlaybackStarvationRecovery()
        check(recovery.waitForJump(player: player, at: 151.8, resumesPlayback: true, rebuildsWhilePaused: true,
                                   keepsPlayerRate: true, seekOrigin: 91.8) { _, _ in false }, "the wait is taken")
        eq(recovery.seekResetOrigin, 91.8, "the move's origin is known to the wait")
        eq(recovery.resumeTime, 151.8, "at the target")
        recovery.cancel()
        eq(recovery.seekResetOrigin, nil, "forgotten with the wait")

        let other = PlaybackStarvationRecovery()
        check(other.waitForJump(player: player, at: 151.8) { _, _ in false }, "a wait without a known origin")
        let now = player.currentTime().seconds
        eq(other.seekResetOrigin, now.isFinite && now >= 0 ? now : nil, "the player's time, away from the target (\(now))")
        other.cancel()
    }

    /// E6 / A6: a navigation while the new item is being put in place is kept (not refused, not
    /// undone by the recovery's seek): the owner gets it once the new item sits at the position.
    func testANavigationWhileTheNewItemIsPutInPlaceIsKept() {
        let player = AVPlayer(playerItem: item())
        let recovery = PlaybackStarvationRecovery()
        var made: [AVPlayerItem] = []
        var retargets: [Double] = []
        recovery.onRetarget = { retargets.append($0) }
        recovery.makeItem = { [weak self] in
            guard let new = self?.item() else { return nil }
            made.append(new)
            return new
        }
        check(recovery.waitForJump(player: player, at: 397.7) { _, _ in true }, "a jump wait, its media on disk")
        check(waitUntil({ !made.isEmpty }), "the new item is put in place")
        check(recovery.userNavigated(to: 300, from: 397.7, resumesPlayback: true), "a navigation then is taken, not refused")
        eq(recovery.resumeTime, 397.7, "the new item still goes to the wait's position first")
        eq(retargets, [], "the conversion is not moved under the item being placed")
        check(recovery.isRecovering, "the recovery goes on")
        recovery.cancel()
    }
}
