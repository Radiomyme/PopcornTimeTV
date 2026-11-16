import Foundation

/// How a player session starts for a title that may have a saved position —
/// the decision the tvOS / iOS native player takes when it is configured
/// (RemuxAVPlayerViewController), as one pure function the Mac player and
/// the tests share.
extension ResumePolicy {

    enum Start: Equatable {
        /// From 0:00: nothing saved, or a finished title
        /// (`restartThreshold`).
        case fromBeginning
        /// The native player, seeking to this 0…1 position once its item is
        /// ready: a direct MP4 (byte ranges make the torrent fetch that part
        /// first) or a remux whose file is entirely on disk.
        case nativeSeek(Float)
        /// The remux of a file that is still downloading, and nobody chose
        /// yet: the player asks « Resume at … » / « Start from the
        /// beginning ». Which engine « Resume at … » means is known a moment
        /// later (`resumeEngine`): the native player when the conversion can
        /// jump to that position (`NativeResumeReadiness`), else VLC — and
        /// the question says which.
        case askResume(Float)
        /// The remux of a file that is still downloading, and the user
        /// already decided where to start (a switch to a lighter release):
        /// no question — the native player there when the conversion can
        /// jump (`resumeEngine`), else VLC there.
        case nativeResume(Float)
        /// VLC at this position, without asking: the container is VLC's
        /// anyway, or — native jumps switched off — the user already decided
        /// where to start on a remux still downloading.
        case vlc(Float)
    }

    /// A decided start below this is no start at all.
    static let minimumDecidedStart: Float = 0.001

    /// - Parameters:
    ///   - savedProgress: the title's saved 0…1 progress (0 = none).
    ///   - decidedStart: where the user already chose to start (a switch to
    ///     a lighter release continues where the other one was); wins over
    ///     the saved progress and never restarts a title near its end.
    ///   - route: the engine the payload starts on.
    ///   - isPayloadOnDisk: every byte of the file is local.
    ///   - nativeJumps: the conversion may jump to a position
    ///     (`RemuxPlayback.nativeJumpsEnabled`, the hidden switch). False:
    ///     the table of before 5.3.0 — a decided start on a remux still
    ///     downloading goes to VLC at once, and the question's « Resume
    ///     at … » means VLC (`resumeEngine`).
    static func start(savedProgress: Float, decidedStart: Float?, route: PlaybackRoute, isPayloadOnDisk: Bool,
                      nativeJumps: Bool = RemuxPlayback.nativeJumpsEnabled) -> Start {
        let decided = decidedStart.flatMap { $0.isFinite && $0 > minimumDecidedStart ? handOffFraction(reached: $0) : nil }
        let position = decided ?? startPosition(forSavedProgress: savedProgress)
        guard position > 0 else { return .fromBeginning }
        switch route {
        case .vlc:
            return .vlc(position)
        case .avPlayer:
            return .nativeSeek(position)
        case .remux:
            if isPayloadOnDisk { return .nativeSeek(position) }
            guard decided != nil else { return .askResume(position) }
            return nativeJumps ? .nativeResume(position) : .vlc(position)
        }
    }

    /// The engine that resumes a remux still downloading at its saved
    /// position.
    enum ResumeEngine: Equatable {
        /// The native player: the conversion jumps there (HDR, Dolby Atmos kept).
        case native
        /// VLC there; `reason` for the logs (no keyframe index, a track the
        /// conversion transcodes, native jumps switched off…).
        case vlc(reason: String)
    }

    /// How long (s) a player waits for the remux to say whether it can
    /// resume natively before it takes VLC for it (the remux has its own
    /// limit, `RemuxPlayback.resumeReadinessTimeout`, counted from its first
    /// tick: this one is the player's, counted from when it starts waiting).
    static let readinessWait: TimeInterval = 8

    /// Which engine « Resume at … » means, or nil while it is not known yet
    /// (the player keeps its spinner and asks again).
    /// - Parameters:
    ///   - readiness: `RemuxPlayback.resumeReadiness`.
    ///   - waited: seconds since the player started waiting for it.
    ///   - nativeJumps: as for `start`. False: VLC, at once.
    ///   - indexIsRead: the file's keyframe index is read and usable
    ///     (`MKVToHLSRemuxSession.jumpCapability == .available`) although
    ///     the readiness is still pending: only the first segments are slow
    ///     to come (a slow head). The resume will be native: it is waited
    ///     for, however long — nothing could play natively from 0:00 before
    ///     that either, and VLC is the last resort.
    static func resumeEngine(readiness: NativeResumeReadiness, waited: TimeInterval, nativeJumps: Bool,
                             indexIsRead: Bool = false) -> ResumeEngine? {
        guard nativeJumps else { return .vlc(reason: RemuxPlayback.nativeJumpsOffReason) }
        switch readiness {
        case .native:
            return .native
        case .vlcOnly(let reason):
            return .vlc(reason: reason)
        case .pending:
            if indexIsRead { return nil }
            return waited >= readinessWait ? .vlc(reason: "not known to be native after \(Int(readinessWait)) s") : nil
        }
    }

    /// The hand-off reason (the `[Player]` log, the engine line) of a resume
    /// that goes through VLC: `reason` is why the conversion can't jump to
    /// its position (`ResumeEngine.vlc`).
    static func vlcResumeReason(_ reason: String) -> String {
        "resume not native: \(reason)"
    }

    // MARK: The wait for a jump's media (the tvOS / iOS and the Mac players)

    // AVPlayer holds a request for an HLS segment for about one target
    // duration (-12889 "No response for media file in 5.84s", measured on
    // tvOS 26.5 with 6 s segments). On tvOS it then drops the video variant
    // for good (-12880 "Can not proceed after removing variants") while the
    // audio rendition goes on loading: that item never plays again and never
    // fails either — a frozen picture with nothing to recover from (run E6
    // of the end-to-end matrix: the segment came 0.1 s too late). A jump of
    // the conversion makes the torrent turn to another part of the file: its
    // first segment takes longer than that on any real swarm. So a player
    // never leaves its item waiting on a segment a jump has yet to write.

    /// What a native resume does while its cover is up.
    enum ResumeAttach: Equatable {
        /// Keep waiting, under the cover, the spinner and « Resuming at … ».
        case wait
        /// The media at the resume point is on disk: the player's item is
        /// made now — its start seek finds its segments there.
        case attach
        /// It can't be native after all: VLC at the saved position.
        case vlc(reason: String)
    }

    /// - Parameters:
    ///   - isPlaylistReady: the remux gave its playlist (`onReady`).
    ///   - hasTarget: the remux knows where the resume lands
    ///     (`RemuxPlayback.resumeTargetSeconds`).
    ///   - hasMedia: the media to start there is on disk
    ///     (`RemuxPlayback.hasMediaToStart`).
    ///   - isAvailable: that position can still be played natively (false:
    ///     its segment was given up — the conversion can't jump any more).
    ///   - refusal: why the remux can't resume natively any more (it failed,
    ///     or its readiness turned VLC-only after the answer); nil: it can.
    static func resumeAttach(isPlaylistReady: Bool, hasTarget: Bool, hasMedia: Bool, isAvailable: Bool,
                             refusal: String?) -> ResumeAttach {
        if let refusal = refusal { return .vlc(reason: refusal) }
        guard hasTarget else { return .wait }
        guard isAvailable else { return .vlc(reason: rewindPastBufferReason) }
        return isPlaylistReady && hasMedia ? .attach : .wait
    }

    /// How long (s) the item that asked for a jump's first segment is left
    /// waiting on it: a conversion that jumps over data already on disk
    /// writes it within that (the item then plays on, untouched); one that
    /// waits for the torrent does not.
    static let jumpGraceSeconds: TimeInterval = 1

    /// `jumpGraceSeconds` after a jump somebody waits on: true when the wait
    /// must move from the item to the recovery's (the player paused, a new
    /// item put at the position once its media is on disk —
    /// `PlaybackStarvationRecovery.waitForJump`).
    /// - Parameters:
    ///   - isJumpWaiting: the jump is still waited on (`RemuxPlayback.isJumpWaiting`).
    ///   - hasFirstSegment: the segment of the position the player wants is
    ///     on disk (`RemuxPlayback.hasMedia(fromPlayerSeconds:cushion: 0)`).
    ///   - isRecovering: a recovery already holds the player.
    ///   - isItemHealthy: the current item plays normally (playback started,
    ///     no start seek, not failed).
    static func jumpNeedsNewItem(isJumpWaiting: Bool, hasFirstSegment: Bool, isRecovering: Bool,
                                 isItemHealthy: Bool) -> Bool {
        isJumpWaiting && !hasFirstSegment && !isRecovering && isItemHealthy
    }

    /// What a player does when the conversion says a jump is waited on
    /// (`RemuxPlayback.JumpState.waiting`).
    enum JumpWaitResponse: Equatable {
        /// Nothing: the native resume has no item yet — its attach waits
        /// for the media at its position (`resumeAttach`).
        case ignore
        /// The native resume's item exists (the user sought under its
        /// cover): the cover and its label stay, but the item must not be
        /// left on a held request — on tvOS it would never play nor fail.
        case armGraceOnly
        /// « Resuming at … » for that position, and the grace check.
        case showAndArmGrace
    }

    static func jumpWaitResponse(isResumingNatively: Bool, hasItem: Bool) -> JumpWaitResponse {
        guard isResumingNatively else { return .showAndArmGrace }
        return hasItem ? .armGraceOnly : .ignore
    }

    // MARK: Texts (the tvOS / iOS and the Mac players show the same)

    /// The resume question's message: « Resume at … » plays natively at the
    /// saved position, or — this file can't — goes through VLC.
    static func resumeQuestionMessage(for engine: ResumeEngine) -> String {
        switch engine {
        case .native:
            return NSLocalizedString("Remux.Resume.Message",
                                     value: "This file is still downloading. Playback resumes there in full quality (HDR, Dolby Atmos).",
                                     comment: "Native player: resume question while the file still downloads; resuming stays native")
        case .vlc:
            return NSLocalizedString("Remux.Resume.Message.VLC",
                                     value: "This file can't resume in full quality: resuming there goes through the VLC player. From the beginning, playback stays native (HDR, Dolby Atmos).",
                                     comment: "Native player: resume question while the file still downloads; resuming switches to VLC")
        }
    }

    /// « Resuming at 1:40:00… »: under the spinner while playback moves to a
    /// position (a native resume, a far seek, a rewind into what a jump
    /// skipped). `position`: the clock time, or the percentage while the
    /// film's length is not known (`resumeLabel`, `clockString`).
    static func resumingText(position: String) -> String {
        String(format: NSLocalizedString("Player.Resuming.At", value: "Resuming at %@…",
                                         comment: "Native player, under the spinner while playback moves to a position; %@ = the position, e.g. 1:40:00"),
               position)
    }

    /// The engine's name in the `[Resume]` log.
    static func logName(of engine: ResumeEngine) -> String {
        engine == .native ? "native" : "VLC"
    }
}
