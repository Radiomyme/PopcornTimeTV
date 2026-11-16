//
//  ResumeStartTests.swift
//  PopcornTimeTests
//
//  ResumePolicy.start (ResumeStart.swift): where a player session starts for a title with a
//  saved position — the native players' resume, on the three platforms. The thresholds are
//  tvOS's (ResumePolicy): a title saved at 95 % or more restarts from the beginning; an MKV
//  still downloading asks — and « Resume at … » then plays natively when the conversion can
//  jump to that position, through VLC when it can't (ResumePolicy.resumeEngine: what the remux
//  says, waited for 8 s at most). With native jumps switched off (the hidden switch) the
//  table is the one of before 5.3.0.
//

import XCTest
import Foundation

final class ResumeStartTests: CheckedTestCase {

    /// (`jumps`: the hidden switch, given — the default reads the user defaults.)
    private func start(_ saved: Float, decided: Float? = nil, _ route: PlaybackRoute, onDisk: Bool = false,
                       jumps: Bool = true) -> ResumePolicy.Start {
        ResumePolicy.start(savedProgress: saved, decidedStart: decided, route: route, isPayloadOnDisk: onDisk, nativeJumps: jumps)
    }

    func testNothingSavedStartsFromTheBeginning() {
        for route in [PlaybackRoute.remux, .avPlayer, .vlc] {
            for onDisk in [false, true] {
                eq(start(0, route, onDisk: onDisk), .fromBeginning, "no saved progress, \(route), on disk \(onDisk)")
            }
        }
        eq(start(-0.2, .avPlayer), .fromBeginning, "a negative progress is none")
        eq(start(.nan, .avPlayer), .fromBeginning, "NaN is none")
        eq(start(.infinity, .vlc), .fromBeginning, "infinity is a finished title")
    }

    func testFinishedTitleRestarts() {
        // tvOS's threshold: 95 % and beyond is a finished title.
        eq(start(0.95, .avPlayer), .fromBeginning, "95 % restarts")
        eq(start(0.99, .remux), .fromBeginning, "99 % restarts, MKV")
        eq(start(1, .vlc), .fromBeginning, "100 % restarts, VLC")
        eq(start(0.949, .avPlayer), .nativeSeek(0.949), "94.9 % still resumes")
        // The "watched" mark (80 %) is not the restart threshold: a title stopped in its last
        // fifth resumes there.
        eq(start(0.85, .avPlayer), .nativeSeek(0.85), "85 % (marked watched) resumes")
    }

    func testDirectFileSeeksNatively() {
        eq(start(0.4, .avPlayer), .nativeSeek(0.4), "MP4 still downloading: byte ranges, native seek")
        eq(start(0.4, .avPlayer, onDisk: true), .nativeSeek(0.4), "MP4 on disk")
        eq(start(0.0005, .avPlayer), .nativeSeek(0.0005), "a few seconds in still resumes (as tvOS: no low threshold)")
    }

    func testMatroskaAsksWhileDownloading() {
        eq(start(0.4, .remux), .askResume(0.4), "MKV still downloading: the user chooses to resume there or to start from 0:00")
        eq(start(0.4, .remux, onDisk: true), .nativeSeek(0.4), "MKV entirely on disk: the remux pumps ahead, native seek")
        // The question is the same with native jumps off: only what « Resume at … » means changes.
        eq(start(0.4, .remux, jumps: false), .askResume(0.4), "native jumps off: still asked")
        eq(start(0.4, .remux, onDisk: true, jumps: false), .nativeSeek(0.4), "native jumps off: a file on disk still seeks natively")
    }

    func testVLCContainerResumesInVLC() {
        eq(start(0.4, .vlc), .vlc(0.4), "AVI / TS: VLC at the saved position")
        eq(start(0.4, .vlc, onDisk: true), .vlc(0.4), "on disk too")
    }

    func testDecidedStartWinsAndNeverAsks() {
        // A switch to a lighter release continues where the other one was.
        eq(start(0.2, decided: 0.6, .remux), .nativeResume(0.6),
           "decided start on an MKV still downloading: resumed there without a question, natively when the conversion can jump")
        eq(start(0.2, decided: 0.6, .remux, onDisk: true), .nativeSeek(0.6), "decided start, MKV on disk")
        eq(start(0.2, decided: 0.6, .avPlayer), .nativeSeek(0.6), "decided start, MP4")
        eq(start(0, decided: 0.6, .vlc), .vlc(0.6), "decided start, VLC container, nothing saved")
        // In the end credits a switch must not restart the movie: clamped, not reset.
        eq(start(0.2, decided: 0.97, .avPlayer), .nativeSeek(0.97), "decided start past 95 % is kept")
        eq(start(0.2, decided: 1, .avPlayer), .nativeSeek(ResumePolicy.handOffMaxFraction), "decided start at the very end is clamped")
        // No decided start at all: the saved position decides.
        eq(start(0.2, decided: 0, .avPlayer), .nativeSeek(0.2), "decided 0 = none")
        eq(start(0.2, decided: 0.001, .remux), .askResume(0.2), "decided at the threshold = none, the saved one asks")
        eq(start(0.2, decided: .nan, .avPlayer), .nativeSeek(0.2), "decided NaN = none")
        eq(start(0, decided: 0.0005, .avPlayer), .fromBeginning, "nothing decided, nothing saved")
    }

    /// Episode chaining, decision D2: « Resume » (a Home card, the page's button) already answers
    /// « Resume at … ? » — the saved position is passed as decided, so an MKV still downloading
    /// resumes natively by a jump, without the question and without VLC; on disk it seeks.
    func testResumeButtonPassesTheSavedPositionAsDecided() {
        eq(start(0.4, decided: 0.4, .remux), .nativeResume(0.4), "« Resume » on a remux still downloading: native, no question")
        eq(start(0.4, decided: 0.4, .remux, onDisk: true), .nativeSeek(0.4), "« Resume » on a remux on disk: a native seek")
        eq(start(0.4, decided: 0.4, .avPlayer), .nativeSeek(0.4), "« Resume » on an MP4")
        eq(start(0.4, .remux), .askResume(0.4), "Play (not « Resume »): still asked")
    }

    func testNativeJumpsOffIsTheTableOfBefore() {
        // `PTNativeJumpsDisabled`: every row as in 5.2.0 — the only start that changes with the
        // switch is the decided one on an MKV still downloading.
        for onDisk in [false, true] {
            for route in [PlaybackRoute.remux, .avPlayer, .vlc] {
                for saved in [Float(0), 0.4, 0.96] {
                    let on = start(saved, route, onDisk: onDisk)
                    let off = start(saved, route, onDisk: onDisk, jumps: false)
                    eq(off, on, "nothing decided: the switch changes nothing (\(route), on disk \(onDisk), saved \(saved))")
                }
            }
        }
        eq(start(0.2, decided: 0.6, .remux, jumps: false), .vlc(0.6), "decided start on an MKV still downloading: VLC at once, as before")
        eq(start(0.2, decided: 0.6, .remux, onDisk: true, jumps: false), .nativeSeek(0.6), "decided start, MKV on disk: native seek")
        eq(start(0.2, decided: 0.6, .avPlayer, jumps: false), .nativeSeek(0.6), "decided start, MP4: native seek")
        eq(start(0.2, decided: 0.6, .vlc, jumps: false), .vlc(0.6), "decided start, VLC container")
        eq(start(0.2, decided: 1, .remux, jumps: false), .vlc(ResumePolicy.handOffMaxFraction), "clamped the same way")
        eq(start(0.2, decided: 1, .remux), .nativeResume(ResumePolicy.handOffMaxFraction), "as the native resume is")
        // The default reads the hidden switch, which nobody set here.
        eq(ResumePolicy.start(savedProgress: 0.2, decidedStart: 0.6, route: .remux, isPayloadOnDisk: false),
           RemuxPlayback.nativeJumpsEnabled ? .nativeResume(0.6) : .vlc(0.6), "the default is the switch")
    }

    func testResumeEngineFollowsTheRemux() {
        func engine(_ readiness: NativeResumeReadiness, waited: TimeInterval = 0, jumps: Bool = true,
                    indexIsRead: Bool = false) -> ResumePolicy.ResumeEngine? {
            ResumePolicy.resumeEngine(readiness: readiness, waited: waited, nativeJumps: jumps, indexIsRead: indexIsRead)
        }
        eq(ResumePolicy.readinessWait, 8, "the player waits 8 s for the remux")
        // The remux knows.
        eq(engine(.native), .native, "the conversion can jump there: native")
        eq(engine(.native, waited: 60), .native, "however long it took")
        eq(engine(.vlcOnly("no keyframe index")), .vlc(reason: "no keyframe index"), "it can't: VLC, with the remux's reason")
        eq(engine(.vlcOnly("no keyframe index"), waited: 0.1, indexIsRead: true), .vlc(reason: "no keyframe index"),
           "the remux's word wins over the index")
        // It does not know yet: the player waits (nil), 8 s at most.
        check(engine(.pending) == nil, "not known at once: wait")
        check(engine(.pending, waited: 7.9) == nil, "7.9 s: still waiting")
        guard case .vlc(let late)? = engine(.pending, waited: 8) else { return check(false, "8 s without an answer: VLC") }
        check(late.contains("8 s"), "the reason says the wait", late)
        check(engine(.pending, waited: 600) != .native, "never native on a guess")
        // A slow head: the index is read, only the first segments are missing — the resume
        // will be native, and is waited for (VLC is the last resort).
        check(engine(.pending, waited: 8, indexIsRead: true) == nil, "index read, 8 s: still waiting")
        check(engine(.pending, waited: 300, indexIsRead: true) == nil, "index read, 5 min: still waiting")
        eq(engine(.native, waited: 300, indexIsRead: true), .native, "then native")
        // The hidden switch: VLC at once, whatever the remux would say.
        for readiness in [NativeResumeReadiness.pending, .native, .vlcOnly("x")] {
            guard case .vlc(let reason)? = engine(readiness, jumps: false, indexIsRead: true) else {
                return check(false, "native jumps off: VLC (\(readiness))")
            }
            check(reason.contains(RemuxPlayback.nativeJumpsDisabledKey), "the reason names the switch", reason)
        }
        eq(ResumePolicy.logName(of: .native), "native", "the log's names")
        eq(ResumePolicy.logName(of: .vlc(reason: "x")), "VLC", "the log's names")
    }

    /// End-to-end run E6 (tvOS simulator): an item left waiting on a segment the conversion
    /// had yet to write gave up on it after 5.84 s (-12889), dropped its video variant and
    /// never played again — nor failed. A native resume therefore makes its item only once
    /// the media at the resume point is on disk.
    func testANativeResumeMakesItsItemOnlyOnceItsMediaIsOnDisk() {
        func step(ready: Bool = true, target: Bool = true, media: Bool = true, available: Bool = true,
                  refusal: String? = nil) -> ResumePolicy.ResumeAttach {
            ResumePolicy.resumeAttach(isPlaylistReady: ready, hasTarget: target, hasMedia: media, isAvailable: available,
                                      refusal: refusal)
        }
        eq(step(), .attach, "playlist ready, media at the resume point on disk: the item is made")
        eq(step(media: false), .wait, "the conversion has not written the resume point yet: wait under the cover")
        eq(step(ready: false), .wait, "the remux is still preparing: wait")
        eq(step(ready: false, media: false), .wait, "neither: wait")
        eq(step(target: false, media: false), .wait, "the remux has not said where the resume lands yet: wait")
        eq(step(target: false), .wait, "no target: never an item on a guess")
        // It can't be native after all: VLC at the saved position, never a wait without end.
        eq(step(media: false, available: false), .vlc(reason: ResumePolicy.rewindPastBufferReason),
           "the resume point was given up (the conversion can't jump any more): VLC there")
        eq(step(refusal: "the keyframe index does not say true"), .vlc(reason: "the keyframe index does not say true"),
           "the remux refuses: VLC, with its reason — even with media there")
        eq(step(ready: false, target: false, media: false, refusal: "halted"), .vlc(reason: "halted"), "a remux that stopped: VLC")
    }

    /// The same defect on a far seek and on a rewind into what a jump skipped: the wait for
    /// the jump's media moves from the item to a new, pre-positioned one — unless the
    /// conversion wrote the segment within the grace (the data was on disk).
    func testAJumpWhoseFirstSegmentIsNotWrittenMovesItsWaitToANewItem() {
        func moves(waiting: Bool = true, segment: Bool = false, recovering: Bool = false, healthy: Bool = true) -> Bool {
            ResumePolicy.jumpNeedsNewItem(isJumpWaiting: waiting, hasFirstSegment: segment, isRecovering: recovering,
                                          isItemHealthy: healthy)
        }
        check(moves(), "a jump waited on, its first segment not written after the grace: a new item will be put there")
        check(!moves(segment: true), "the segment is there (the jump was over data on disk): the item plays on")
        check(!moves(waiting: false), "the jump is no longer waited on (it landed, or the user went elsewhere): nothing")
        check(!moves(recovering: true), "a recovery already holds the player: nothing")
        check(!moves(healthy: false), "an item that has not started, seeks to its start or failed: its own path")
        // Well under AVPlayer's patience for a held segment (one target duration, 6 s: 5.84 s
        // measured), the jump's decision (≤ 1.3 s after the seek) included.
        check(ResumePolicy.jumpGraceSeconds > 0 && ResumePolicy.jumpGraceSeconds <= 2, "the grace leaves AVPlayer's 5.84 s far away",
              "\(ResumePolicy.jumpGraceSeconds)")
    }

    /// A seek under a native resume's cover (its item made, the first picture not played
    /// yet) sends the conversion back into a hole: that jump's wait must still be moved off
    /// the item, or on tvOS the item stays frozen under the cover for good.
    func testAJumpWaitedOnUnderTheNativeResumeCoverStillArmsTheGraceCheck() {
        eq(ResumePolicy.jumpWaitResponse(isResumingNatively: true, hasItem: false), .ignore,
           "no item yet: the resume's attach waits for the media at its position")
        eq(ResumePolicy.jumpWaitResponse(isResumingNatively: true, hasItem: true), .armGraceOnly,
           "the item exists under the cover: the cover stays, the grace check is armed")
        eq(ResumePolicy.jumpWaitResponse(isResumingNatively: false, hasItem: true), .showAndArmGrace,
           "a jump during playback: « Resuming at … » and the grace check")
    }

    func testAHandOffToVLCSaysWhoDecidedAndWhy() {
        // The VLC player is told whether somebody already chose to resume: the user in the
        // native question (or before it: a lighter release), or by watching. Otherwise — a
        // DTS-only MKV refused before any question — VLC asks its own.
        check(!ResumePolicy.handOffResumeDecided(userChoseResume: false, playbackStarted: false), "nobody decided: VLC asks")
        check(ResumePolicy.handOffResumeDecided(userChoseResume: true, playbackStarted: false), "« Resume at … » was chosen")
        check(ResumePolicy.handOffResumeDecided(userChoseResume: false, playbackStarted: true), "the user was watching")
        check(ResumePolicy.handOffResumeDecided(userChoseResume: true, playbackStarted: true), "both")
        // The reason the players hand over with when the resume itself is VLC's: the one the
        // question was shown for, never a "quick resume".
        eq(ResumePolicy.vlcResumeReason("no keyframe index"), "resume not native: no keyframe index", "the remux's reason, said")
        // The hidden switch has one wording, the remux's and the policy's.
        eq(RemuxPlayback.nativeJumpsOffReason, "native jumps are off (PTNativeJumpsDisabled)", "the switch, named")
        eq(ResumePolicy.resumeEngine(readiness: .native, waited: 0, nativeJumps: false),
           .vlc(reason: RemuxPlayback.nativeJumpsOffReason), "the policy gives the same reason as the remux")
    }

    func testResumedSessionProtectsItsPoint() {
        // The session that resumed at 40 % and is closed before the seek landed (position
        // still ~0) keeps the saved point; once played past it, a smaller position replaces it.
        check(ResumePolicy.progressToSave(current: 0.0004, resumePoint: 0.4, highWater: 0.0004, userRestarted: false) == nil,
              "closed before the start seek landed: the saved point stays")
        eq(ResumePolicy.progressToSave(current: 0.41, resumePoint: 0.4, highWater: 0.41, userRestarted: false), 0.41,
           "played on from the resume point: saved")
        eq(ResumePolicy.progressToSave(current: 0.1, resumePoint: 0.4, highWater: 0.45, userRestarted: false), 0.1,
           "watched past it, then went back: the new position")
        // « Start from the beginning » in the question: the Mac player drops its resume point.
        eq(ResumePolicy.progressToSave(current: 0.01, resumePoint: 0, highWater: 0.01, userRestarted: false), 0.01,
           "started over (resume point dropped): the new position replaces the old one")
    }

    func testQuestionLabel() {
        eq(ResumePolicy.resumeLabel(fraction: 0.5, durationSeconds: 7454), "1:02:07", "clock time once the length is known")
        eq(ResumePolicy.resumeLabel(fraction: 0.5, durationSeconds: 0), "50 %", "the percentage before")
    }
}
