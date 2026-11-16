//
//  JumpWaitRecoveryTests.swift
//  PopcornTimeTests
//
//  PlaybackStarvationRecovery.waitForJump (AVPlayerItemFailureObserver.swift): the wait for the
//  media of a position the conversion jumped to, taken away from the item that asked for it.
//
//  Why (end-to-end run E6, tvOS simulator, 15 November 2026): after a far seek the conversion
//  jumped and wrote the first segment 5.0 s later; AVPlayer had dropped its held request after
//  5.84 s (-12889 "No response for media file"), dropped its video variant (-12880) and went
//  on loading audio — the picture stayed frozen for the rest of the run, with no failure for
//  the starvation recovery to start on. The players now move such a wait to the recovery
//  WITHOUT a failure: the player paused, a new item pre-positioned there once the media is on
//  disk. This test drives the recovery on a real AVPlayer (items on a file that does not
//  exist: nothing is played).
//

import XCTest
import AVFoundation

@MainActor
final class JumpWaitRecoveryTests: CheckedTestCase {

    private func item() -> AVPlayerItem {
        AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-popcorntime-test/master.m3u8"))
    }

    /// Runs the main run loop (the recovery's 1 Hz poll and its callbacks) until `condition`.
    private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 8) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        return condition()
    }

    func testAJumpWaitPausesThePlayerThenPutsANewItemThereOnceTheMediaIsOnDisk() {
        let first = item()
        let player = AVPlayer(playerItem: first)
        let recovery = PlaybackStarvationRecovery()
        var waiting: [Bool] = []
        var made: [AVPlayerItem] = []
        var replaced: [AVPlayerItem] = []
        var asked: [Double] = []
        var gaveUp: [String] = []
        var mediaIsOnDisk = false
        recovery.onWaitingChanged = { waiting.append($0) }
        recovery.makeItem = { [weak self] in
            guard let new = self?.item() else { return nil }
            made.append(new)
            return new
        }
        recovery.onItemReplaced = { item, _ in replaced.append(item) }
        recovery.onGiveUp = { gaveUp.append($0) }

        player.play()
        let started = recovery.waitForJump(player: player, at: 690) { time, _ in
            asked.append(time)
            return mediaIsOnDisk
        }
        check(started, "the wait is taken")
        check(recovery.isRecovering && recovery.isWaitingForJump, "a recovery, of a jump")
        check(!recovery.isRebuildingStuckItem && !recovery.isWaitingForPlay, "neither a stuck item nor a paused user")
        eq(recovery.resumeTime, 690, "at the position the conversion jumped to")
        check(recovery.resumeTimeIsUserTarget, "the user's target: a give-up hands VLC that position")
        eq(recovery.attemptsWithoutProgress, 0, "nothing failed: the starvation budget is untouched")
        eq(recovery.recoveryCount, 0, "and it is no starvation recovery")
        eq(player.rate, 0, "the player is paused: the item no longer plays toward the missing segment")
        eq(waiting, [true], "the owner shows its wait (« Resuming at … »)")
        check(player.currentItem === first, "the item stays while the media is waited for (its transport bar too)")
        check(!recovery.waitForJump(player: player, at: 100) { _, _ in true }, "a second wait is refused while one runs")
        eq(recovery.resumeTime, 690, "and changes nothing")

        // Not on disk: polled, nothing made. (Waited for by count, not by a window of the
        // real clock: the polls are chained 1 s apart on the main queue, which a loaded
        // machine delays.)
        check(waitUntil({ asked.count >= 2 || !made.isEmpty }), "the media at that position is asked for, again and again",
              "\(asked)")
        check(made.isEmpty, "no new item while the media is not on disk")
        check(asked.allSatisfy { $0 == 690 }, "at that position", "\(asked)")

        // The conversion wrote it.
        mediaIsOnDisk = true
        check(waitUntil({ !replaced.isEmpty }), "a new item once the media is on disk")
        eq(made.count, 1, "one item made")
        check(replaced.first === made.first && player.currentItem === made.first, "it is the player's item now")
        check(player.currentItem !== first, "the item that asked for the missing segment is gone")
        eq(player.rate, 0, "still paused: the owner plays once the new item sits at the position (onResumed)")
        check(gaveUp.isEmpty, "no give-up", "\(gaveUp)")
        check(recovery.isRecovering, "the rebuild is the recovery's until its seek is done")

        recovery.cancel()
        check(!recovery.isRecovering && !recovery.isWaitingForJump, "cancelled: idle")
        eq(waiting.last, false, "the owner's wait ends")
    }

    func testAJumpWaitOfAPausedUserWaitsForPlay() {
        let player = AVPlayer(playerItem: item())
        let recovery = PlaybackStarvationRecovery()
        var waiting: [Bool] = []
        var made = 0
        recovery.onWaitingChanged = { waiting.append($0) }
        recovery.makeItem = { [weak self] in
            made += 1
            return self?.item()
        }
        check(recovery.waitForJump(player: player, at: 300, resumesPlayback: false) { _, _ in true }, "the wait is taken")
        check(recovery.isRecovering && recovery.isWaitingForJump && recovery.isWaitingForPlay, "it waits for play first")
        eq(waiting, [], "no spinner over a paused picture")
        check(!waitUntil({ made > 0 }, seconds: 1.5), "nothing is rebuilt behind a paused user, even with the media on disk")
        recovery.cancel()
    }

    func testAJumpWaitNeedsAPlayerWithAnItemAndAPosition() {
        let recovery = PlaybackStarvationRecovery()
        let empty = AVPlayer()
        check(!recovery.waitForJump(player: empty, at: 10) { _, _ in true }, "no item: nothing to wait with")
        let player = AVPlayer(playerItem: item())
        check(!recovery.waitForJump(player: player, at: .nan) { _, _ in true }, "no position")
        check(!recovery.waitForJump(player: player, at: -1) { _, _ in true }, "a negative position")
        check(!recovery.isRecovering, "nothing was started")
    }
}
