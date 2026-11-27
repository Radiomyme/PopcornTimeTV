

import Foundation
import AVKit
import SwiftUI
import Combine
import PopcornTorrent
import PopcornKit

// OWNED BY agent B1 — split out of RemuxPlayback.swift. iOS + tvOS only.

#if canImport(UIKit)
/// The native (AVPlayer) player of the iOS / tvOS apps. Picks its engine
/// from the REAL payload file name:
///  - `.remux`    MKV / WebM → `RemuxPlayback` (fMP4/HLS on 127.0.0.1) →
///                AVPlayer: native HDR10 / Dolby Vision, true Atmos, every
///                audio / subtitle track as an HLS rendition;
///  - `.avPlayer` MP4 / M4V / MOV → AVPlayer straight on the torrent's local
///                HTTP endpoint, OpenSubtitles drawn by `SubtitleCueController`;
///  - `.vlc`      anything else → `onFallback` right away.
/// Whenever AVFoundation rejects the media (remux reports unsupported
/// tracks, item failure, undecodable track, readiness timeout) it stops,
/// keeps the torrent stream alive and calls `onFallback` ONCE, after the
/// controller has appeared, so the owner can swap in VLC on the same stream.
///
/// Download starvation is NOT such a failure: when the swarm is slower than
/// the movie, AVPlayer gives up on the held segment / byte range
/// (FailedToPlayToEnd -12889 after ~37 s) although the file plays fine. The
/// player then stays native (`PlaybackStarvationRecovery`): buffering
/// indicator, wait for the data (remux frontier past the playhead + 10 s /
/// more torrent bytes), new item on the same URL — pre-positioned at the
/// saved time — with the same audio / subtitle selection, seek back to the
/// same time — HDR / Atmos kept. A seek the user makes while it waits
/// becomes the position it recovers; so does a seek AVPlayer still held when
/// the item failed (past the download or the remux: AVPlayer then resets
/// its time to before that seek — `HeldSeekWatch`). A paused item can fail
/// too (AVPlayer buffers while paused): a user who had paused — or who
/// pauses while it waits — is never resumed behind their back: the recovery
/// rebuilds only once play is pressed (`PlaybackIntentWatch`). Only
/// repeated fruitless recoveries, a rebuilt item not ready within 30 s, or
/// (remux) a download that grows while the remux frontier stays frozen for
/// 3 min end on VLC — and (remux) a user's seek target the in-order download
/// (or the remux pump, over data on disk) can't bring within about 45 s
/// (`FarTargetWatch`: the remux frontier's measured pace), which goes to VLC
/// AT that target (its byte-range reads
/// make the torrent fetch it first): at once while AVPlayer still holds the
/// seek, or from the recovery that waits for it.
///
/// Remux path, what will never come back goes to VLC at once (at the
/// current / requested position): the remux halted after `onReady`
/// (`onHalted`, `failureReason` — disk full), a pruned segment playback
/// needs (`onUnavailableSegmentRequested`: a rewind past the kept media, or
/// playback reaching a span the remux deleted — a prefetch of it is held
/// until then, native playback goes on), a
/// seek into pruned segments during a starvation wait
/// (`positionUnavailable`), and any HTTP 404 in an AVPlayer error (the
/// server only 404s what will never exist; anything that may still appear
/// is held / 503). Once a second, and at once when the playhead jumps (a
/// seek, the start seek), the player tells the remux the last
/// position playback actually reached and the one it needs data for now —
/// the playhead, a pending seek target, the position a starvation recovery
/// waits for (`RemuxPlayback.updatePlaybackPositions`; a user seek during
/// that wait is reported at once): the remux runs ahead of the latter and
/// only deletes segments neither of them needs.
///
/// Once the remux has finished (every byte is local), an item that stays
/// frozen while the user wants it playing is not left spinning
/// (`StuckPlaybackWatch`): in the last second / last segment that is the
/// end — paused, as AVPlayer does at an item's end; elsewhere the item is
/// rebuilt in place (`PlaybackStarvationRecovery.rebuildNow`), at most twice
/// for one position, then VLC there. An item AVPlayer started on live EVENT
/// playlists (a file without a Matroska Duration) is rebuilt the same way,
/// once, as soon as the remux has finished: AVFoundation keeps that item's
/// live bookkeeping after ENDLIST and it later stops answering seeks and
/// audio / subtitle switches (`LiveBornItemWatch`).
///
/// Resume, while the payload is still downloading: the user is asked
/// « Reprendre à … » / « Reprendre du début » (`ResumePolicy.start`). When
/// the file has a usable keyframe index the remux can move its conversion to
/// the saved position (`RemuxPlayback.prepareResume` — it turns the torrent
/// there while the question is up): « Reprendre à … » then plays NATIVELY
/// there (`commitResume`), under a black cover, a spinner and « Reprise à
/// 1:40:00… » until the picture at that position plays — never the frozen
/// first frame of 0:00. Only a file the conversion can't jump in (no index, a
/// transcoded track, native jumps switched off: `ResumePolicy.resumeEngine`)
/// hands the SAME stream to VLC at that position, and the question says so.
/// « Reprendre du début » plays natively from 0 (`cancelResume`). A decided
/// start (a switch to a lighter release) does the same without the question.
/// The same jump serves a far seek during playback (`checkFarSeekTarget`,
/// the starvation recovery's `farTargetJump`): VLC only when the conversion
/// can't go there. A payload already on disk (finished download) and the
/// direct MP4 path (byte ranges) resume by a plain seek. The saved progress
/// is never replaced by a smaller fraction
/// unless the user restarted on purpose or watched past it. A hand-off to
/// VLC saves the native part first (at the hand-off position), so a VLC
/// crash or an immediate close never loses it. The progress is also saved
/// when the user pauses and when the app goes to the background (tvOS
/// suspends it at once and may kill it there), so a kill or a crash keeps
/// what was watched.
///
/// tvOS episodes get "Up Next" (AVKit content proposal, before the end: Settings › Next
/// Episode Card, 60 s by default, at most a third of the file).
///
/// A toggleable nerd-stats overlay shows the resolved formats — `Audio ec-3`
/// is the on-screen proof Apple's renderer gets the raw E-AC-3 and performs
/// the Atmos rendering.
/// (UIKit-only: the native macOS app has its own AVPlayerView-based player —
/// the shared `RemuxPlayback` engine is what both build on.)
final class RemuxAVPlayerViewController: AVPlayerViewController {
    /// The profile that started the play: its position goes there, even
    /// once another is in use (`PlaybackRecorder.save`).
    let profileID = ProfileManager.shared.activeID

    /// Called at most once, on the main queue, when the native path can't
    /// play the payload (or the user resumes through VLC). `resumeFraction`
    /// (0…1) is the playback position to resume from: where playback got
    /// (at most `ResumePolicy.handOffMaxFraction`), or the configured start
    /// position when playback never started. `resumeDecided`: the user chose
    /// « Reprendre » or was watching — VLC continues there without asking;
    /// false = nobody decided (e.g. rejected before the resume question),
    /// VLC asks « Reprendre / Depuis le début » itself. The torrent stream
    /// is NOT cancelled: hand it to VLC.
    var onFallback: ((_ reason: String, _ resumeFraction: Float, _ resumeDecided: Bool) -> Void)?

    /// Closes the player when the user cancels the resume question. nil =
    /// dismiss this modally presented controller (tvOS); the SwiftUI owner
    /// sets it (iOS cover).
    var onCloseRequest: (() -> Void)?

    /// Engine picked by `configure` from the payload's file name.
    private(set) var route: PlaybackRoute = .remux
    /// True once playback is being handed over to the VLC fallback — the
    /// torrent stream must outlive this controller.
    private(set) var isHandingOff = false

    private var remux: RemuxPlayback?
    /// The file's natural end that AVPlayer did not post (stuck in the last
    /// segment of a finished remux, `StuckPlaybackWatch`): the iPhone / iPad
    /// clock of episode chaining (`UpNextRemuxClock`) treats it as the end.
    var onNaturalEnd: (() -> Void)?
    private var keepAliveStreamer: PTTorrentStreamer?
    private var media: Media?
    /// 0…1 position to resume at, 0 = from the beginning.
    private var startPosition: Float = 0
    private var failureObserver: AVPlayerItemFailureObserver?
    private var startObservations: [NSKeyValueObservation] = []
    private var awaitingStartSeek = false
    private var didStartPlayback = false

    /// The saved position this session opened at (0 = none / finished
    /// title): never overwritten by a smaller fraction unless the user
    /// restarted on purpose or watched past it (`ResumePolicy`).
    private var resumePoint: Float = 0
    /// Furthest position (0…1) reached during this session.
    private var highWaterFraction: Float = 0
    /// When the position was last saved during playback (every 30 s).
    private var progressCheckpoint = PlaybackCheckpoint()
    /// The user answered « Reprendre du début ».
    private var userChoseStartOver = false
    /// The user answered « Reprendre à … », or had decided where to start
    /// (a switch to a lighter release): a hand-off to VLC continues there
    /// without asking again.
    private var userChoseResume = false
    /// The hidden switch (`RemuxPlayback.nativeJumpsEnabled`), read when the
    /// player is configured.
    private var nativeJumps = true
    /// A decided start on a payload still downloading
    /// (`ResumePolicy.Start.nativeResume`): no question — answered « Reprendre
    /// à … » as soon as the engine of the resume is known.
    private var resumesWithoutQuestion = false
    /// When the player started waiting for the remux to say whether the
    /// resume can be native (`ResumePolicy.resumeEngine`).
    private var resumeWaitStartedAt: TimeInterval?
    /// What « Reprendre à … » means in the question on screen.
    private var questionEngine: ResumePolicy.ResumeEngine?
    /// A native resume was accepted and the picture at its position does not
    /// play yet: the black cover, the spinner and « Reprise à … » are up
    /// (`beginNativeResume` … `finishNativeResume`).
    private var isResumingNatively = false
    /// The `[Resume]` log's clocks (uptime): the remux started, it said the
    /// resume is native (the torrent is turned there from then), the
    /// question came up, the answer.
    private var resumeStartedAt: TimeInterval?
    private var resumeNativeSince: TimeInterval?
    private var resumeQuestionShownAt: TimeInterval?
    private var resumeAnsweredAt: TimeInterval?
    /// The payload is entirely on disk (finished download / complete
    /// torrent): the remux can pump ahead to any resume point quickly.
    private var isPayloadLocal = false
    /// Remux path, payload still downloading, saved position > 0: waiting
    /// for the user's answer to the resume question.
    private var resumeChoicePending = false
    private var resumeQuestionScheduled = false
    private weak var resumeAlert: UIAlertController?
    /// The remux became ready while the question was up: attached once the
    /// user chose to play natively.
    private var pendingPlaylistURL: URL?

    /// tvOS "Up Next": the episode proposed near the end, and how to play it.
    private var nextEpisode: Episode?
    private var onPlayNext: ((Episode) -> Void)?
#if os(tvOS)
    private var upNextObservation: NSKeyValueObservation?
    private var didAcceptUpNext = false
    /// Episode chaining (5.3.0): this playback's link (`AppDelegate.play`)
    /// — it follows a hand-off to VLC — and its session. With a session the
    /// session drives the card (`reconcileUpNextCard`); without one, the
    /// Up Next of before 5.3 (`nextEpisode` / `onPlayNext`).
    private(set) var upNextLink: UpNextTVLink?
    private var upNextSession: UpNextSession?
    private var upNextCardSubscription: AnyCancellable?
    private weak var upNextProposal: UpNextProposalViewController?
    private weak var upNextOverlay: UpNextOverlayViewController?
    /// When AVKit was asked to present the proposal (it presents it once
    /// playback crosses its time): past `upNextProposalPatience`, the overlay.
    private var upNextProposalRequestedAt: TimeInterval?
    private static let upNextProposalPatience: TimeInterval = 3
    /// The player closes for the next episode (`closeForNextEpisode`): not
    /// the user leaving — the session is not told « closed ».
    private var isClosingForNextEpisode = false
#endif
    /// The close is the one for the next episode (tvOS; logs only).
    private var isClosingForNextEpisodeLog: Bool {
#if os(tvOS)
        return isClosingForNextEpisode
#else
        return false
#endif
    }

    /// External subtitles of the direct (MP4) path; the remux path exposes
    /// them as native HLS renditions instead.
    private var subtitleController: SubtitleCueController?
    private var subtitleSubscription: AnyCancellable?
    private var subtitleOverlay: SubtitleOverlayLabelView?
#if os(tvOS)
    private var subtitleMenuBinder: SubtitleMenuBinder?
#endif

    private var hasAppeared = false
    private var isTornDown = false
    private var fallbackRequested = false
    private var pendingFallback: (reason: String, resume: Float, decided: Bool)?

    private let statsLabel = UILabel()
    private var statsTimer: Timer?
    /// The `[Start]` trace's first-frame mark (`attachPlayer`).
    private var firstFrameWatch: FirstFrameWatch?
    private var engineLine = "préparation…"
    /// The engine line while playing natively (restored after a recovery).
    private var nativeEngineLine = ""
    /// Shown while the remux prepares its first segments (no player yet),
    /// during a far resume seek and while recovering from starvation.
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    /// Below the spinner while recovering from download starvation.
    private let bufferingLabel = StatusCapsuleLabel()
    /// Below the spinner, instead, while the conversion moves to a position:
    /// « Reprise à 1:40:00… » (a native resume, a far seek, a rewind into
    /// what a jump skipped).
    private let resumingLabel = StatusCapsuleLabel()
    /// A dark capsule under the spinner and whichever of the two labels
    /// shows (`layoutStatusCapsule`): the text stays readable over a bright
    /// picture, and when AVKit's transport bar dims the content overlay
    /// (it is under AVKit's controls) — dimmed, the capsule is still dark.
    private let statusCapsule = UIView()
    /// The capsule's bottom and width, on the label that shows.
    private var statusCapsuleConstraints: [NSLayoutConstraint] = []
    /// Under them during a native resume: black over the first frame of the
    /// item, which loads at 0:00 before its seek.
    private let resumeCover = UIView()

    /// Keeps the native player through download starvation (slow swarm):
    /// rebuilds the item once the data is there instead of falling back.
    private lazy var starvation: PlaybackStarvationRecovery = makeStarvationRecovery()
    /// What the player plays (master playlist / torrent HTTP endpoint):
    /// the starvation recovery rebuilds its item on it.
    private var playbackURL: URL?
    /// Target of the resume seek in flight (player timeline, s).
    private var startSeekTarget: Double?
    /// Last position / duration read from a ready item (1 Hz) — while a
    /// starvation recovery runs, the position it recovers.
    private var lastKnownTime: Double?
    private var lastKnownDuration: Double?
    /// Last position playback actually reached (sampled 1 Hz): the `played`
    /// position reported to the remux — never a held seek target.
    private var playedPosition = PlayedPositionTracker()
    /// The user's seek target AVPlayer still holds (past the download / the
    /// remux), noted at every tick and time jump of a healthy item: what a
    /// failure during the hold recovers — or hands VLC — instead of the reset
    /// `currentTime()` (both routes).
    private var heldSeek = HeldSeekWatch()
    /// Where a user navigation asked to go, which `currentTime()` may not
    /// show while the seek is held (`noteUserNavigation`, `wantedPosition`).
    private var navigation = UserNavigationTarget()
    /// `logPendingNavigation`: the target seen at the last tick, and how
    /// many ticks the current one has been pending.
    private var loggedNavigationTarget: Double?
    /// `UserNavigationTarget.dropCount` when a drop was last logged.
    private var loggedDropCount = 0
    private var pendingNavigationLogs = 0
    /// When the player's item was last replaced (uptime; `NavigationRebase`).
    private var lastItemReplacementAt: TimeInterval?
    /// Remux path: the pace of the remux frontier toward that held target
    /// while the user wants playback — a target it can't reach soon goes to
    /// VLC at once (`checkFarSeekTarget`).
    private var farTarget = FarTargetWatch()
    /// Remux path, remux finished: an item frozen while the user wants it
    /// playing (sampled 1 Hz) → natural end / rebuild / VLC.
    private var stuckWatch = StuckPlaybackWatch()
    /// Remux path: the item AVPlayer started on live EVENT playlists, replaced
    /// once when the remux has finished (`rebuildLiveBornItemIfEnded`).
    private var liveBornWatch = LiveBornItemWatch()
    /// Remux path: an OpenSubtitles list that came after the item read the
    /// master playlist — the item is rebuilt once for it
    /// (`rebuildForLateSubtitlesIfDue`).
    private var lateSubtitles = LateSubtitlesWatch()
    /// Remux path: an OpenSubtitles file the automatic sync retimed — the
    /// item is rebuilt when it is the subtitle on screen
    /// (`rebuildForRetimedSubtitlesIfDue`).
    private var retimeWatch = SubtitleRetimeWatch()
    /// The retimed files' selection check is under way (asynchronous).
    private var retimeCheckInFlight = false
    /// Bounded storage, direct path: AVPlayer waiting with the data on disk
    /// (sampled 1 Hz) → the item is rebuilt (`checkDirectStall`).
    private var directStall = BoundedDirectStallWatch()
    /// Picture in Picture is on (delegate): the stuck-playback safety net
    /// stays out of it; playback goes on in the background.
    private var isPictureInPictureActive = false
    /// The user's play / pause intent — what a starvation recovery and any
    /// rebuild of the item end in — and the pause checkpoint of the progress.
    private var playIntent = PlaybackIntentWatch()
    /// The player's rate changes (`playerRateDidChange`) and its current
    /// item's time jumps (`reportPlaybackPositions` at once).
    private var playerObservers: [NSObjectProtocol] = []
    /// The stream's context (the release, the title's other releases, the
    /// switch to a lighter one); nil for a plain local file.
    private var streamContext: PlaybackStreamContext?
#if os(tvOS)
    /// The deficit offer and its toast over the video.
    private var deficitSubscription: AnyCancellable?
    private weak var deficitToast: BandwidthDeficitToastController?
#endif

    /// - Parameters:
    ///   - localFile: the payload on disk (still downloading) — remux input
    ///     and the file name the route is decided from.
    ///   - remoteURL: the torrent's local HTTP endpoint (direct MP4 / VLC).
    ///   - startPosition: the saved 0…1 progress (resumed or asked about).
    ///   - nextEpisode / onPlayNext: tvOS "Up Next" — `onPlayNext` runs after
    ///     this player has closed (stream cancelled, progress saved).
    func configure(localFile: URL,
                   remoteURL: URL,
                   streamer: PTTorrentStreamer?,
                   title: String,
                   media: Media? = nil,
                   isAtmos: Bool = false,
                   releaseHintsHDR: Bool = false,
                   startPosition: Float = 0,
                   nextEpisode: Episode? = nil,
                   onPlayNext: ((Episode) -> Void)? = nil,
                   upNext: AnyObject? = nil) {
        // Picture in Picture state (and tvOS "Up Next").
        delegate = self
        keepAliveStreamer = streamer
        self.media = media
        self.title = title
        self.nextEpisode = nextEpisode
        self.onPlayNext = onPlayNext
        // A switch to a lighter release starts where the other one was,
        // decided by the user (taken once: a later hand-off to VLC on this
        // stream passes its own position).
        streamContext = PlaybackStreamContext.of(streamer)
#if os(tvOS)
        // Episode chaining: the session of this playback (nil: the Up Next
        // of before 5.3 above).
        if let link = upNext as? UpNextTVLink {
            upNextLink = link
            if let session = link.attach(self, streamer: streamer) { bindUpNext(session) }
        }
#endif
        #if DEBUG
        // `-PTDebugDecidedStart` (BoundedStorageDebugHooks): as after a switch.
        let decidedStart = streamContext?.takeDecidedStart() ?? BoundedStorageDebugHooks.decidedStart
        #else
        let decidedStart = streamContext?.takeDecidedStart()
        #endif
        // A finished (or nearly finished) title restarts from the beginning.
        self.startPosition = decidedStart.map { ResumePolicy.handOffFraction(reached: $0) }
            ?? ResumePolicy.startPosition(forSavedProgress: startPosition)
        resumePoint = self.startPosition
        isPayloadLocal = Self.isPayloadComplete(streamer)
        nativeJumps = RemuxPlayback.nativeJumpsEnabled
        attachDeficitMonitor()
        let fileName = localFile.lastPathComponent
        route = PlaybackRouting.route(forFileName: fileName)
        print("[Player] \(fileName) → \(route)")
        switch route {
        case .remux:
            // A payload still downloading: the conversion reads it in file
            // order, so a saved position is asked about (or, decided already,
            // resumed without a question) — natively when the conversion can
            // jump there, which the remux says a moment after it starts.
            let start = ResumePolicy.start(savedProgress: startPosition, decidedStart: decidedStart, route: route,
                                           isPayloadOnDisk: isPayloadLocal, nativeJumps: nativeJumps)
            switch start {
            case .fromBeginning, .nativeSeek:
                break
            case .askResume(let position), .nativeResume(let position):
                self.startPosition = position
                resumePoint = position
                resumeChoicePending = true
                if case .nativeResume = start {
                    resumesWithoutQuestion = true
                    userChoseResume = true
                }
                print("[Resume] " + (resumesWithoutQuestion ? "decided start at \(Int(position * 100)) % — no question"
                                                             : "saved \(Int(position * 100)) % — question pending")
                      + ", native jumps \(nativeJumps ? "on" : "off (\(RemuxPlayback.nativeJumpsDisabledKey))")")
            case .vlc(let position):
                // Native jumps are off and the user chose where to resume (a
                // lighter release): VLC there, without the question.
                self.startPosition = position
                resumePoint = position
                userChoseResume = true
                print("[Resume] decided start at \(Int(position * 100)) % — native jumps off "
                      + "(\(RemuxPlayback.nativeJumpsDisabledKey)): VLC there")
                requestFallback(ResumePolicy.vlcResumeReason(RemuxPlayback.nativeJumpsOffReason))
                return
            }
            startRemux(localFile: localFile, streamer: streamer, isAtmos: isAtmos, releaseHintsHDR: releaseHintsHDR)
            // A late jump's wait asks the engine's own server (127.0.0.1) for its bytes (`RemuxWaitNudge`).
            remux?.engineServerURL = PlaybackRouting.playableLocalURL(remoteURL, fileName: fileName)
        case .avPlayer:
            startDirect(url: PlaybackRouting.playableLocalURL(remoteURL, fileName: fileName))
        case .vlc:
            requestFallback(PlaybackRouting.vlcReason(forFileName: fileName))
        }
    }

    /// The payload is entirely on disk: a finished download, or a torrent
    /// already complete (no streamer = a plain local file). Completion only:
    /// at 0.999 up to 0.1 % of the file can still be missing.
    static func isPayloadComplete(_ streamer: PTTorrentStreamer?) -> Bool {
        guard let streamer = streamer else { return true }
        if let download = streamer as? PTTorrentDownload, download.downloadStatus == .finished { return true }
        // Bounded storage: every byte on disk now (never once a piece was
        // deleted); full mode: libtorrent's completion, as before.
        return streamer.isWholeFileOnDisk
    }

    /// Remux path: enough media remuxed past `time` (player timeline) to
    /// play again after starvation — on disk from that position on, which
    /// the frontier alone does not say once a jump left holes below it
    /// (`RemuxPlayback.hasMedia`).
    static func remuxHasData(_ remux: RemuxPlayback?, after time: Double) -> Bool {
        remux?.hasMedia(fromPlayerSeconds: time) ?? false
    }

    // MARK: - Remux path (MKV / WebM)

    private func startRemux(localFile: URL, streamer: PTTorrentStreamer?, isAtmos: Bool, releaseHintsHDR: Bool) {
        engineLine = "MKV remux → AVPlayer (natif)"
        nativeEngineLine = engineLine
        let remux = RemuxPlayback(localFile: localFile, streamer: streamer, isAtmos: isAtmos)
        // DEFAULT audio / subtitle renditions follow the user's languages.
        remux.preferredAudioLanguages = PlaybackLanguagePreferences.preferredAudioLanguageCode.map { [$0] } ?? []
        // A learnt subtitle language only when the audio asked for is
        // another (the subtitle controller decides on the audio heard).
        remux.preferredSubtitleLanguages = PlaybackLanguagePreferences.preferredSubtitleLanguageCode(
            whileHearing: PlaybackLanguagePreferences.preferredAudioLanguageCode).map { [$0] } ?? []
        remux.releaseHintsHDR = releaseHintsHDR
        // Native jumps (the hidden switch): a saved position is prepared now —
        // the remux says whether it can resume there natively
        // (`resumeReadiness`) and turns the torrent to it while the user is
        // asked. Its jumps are reported: one somebody waits on, one that failed.
        remux.allowsNativeJumps = nativeJumps
        if resumeChoicePending, nativeJumps { remux.prepareResume(atFraction: startPosition, decided: resumesWithoutQuestion) }
        remux.onResumeReadinessChanged = { [weak self] readiness in
            self?.resumeReadinessChanged(readiness)
        }
        remux.onJumpStateChanged = { [weak self] state in
            self?.jumpStateChanged(state)
        }
        remux.onJumpFailed = { [weak self] reason, playerSeconds in
            self?.jumpFailed(reason, at: playerSeconds)
        }
        remux.onHoleRequested = { [weak self] start, end in
            self?.holeRequested(start: start, end: end)
        }
        resumeStartedAt = ProcessInfo.processInfo.systemUptime
        self.remux = remux
        remux.onReady = { [weak self] playlistURL in
            DispatchQueue.main.async { self?.remuxDidBecomeReady(playlistURL) }
        }
        remux.onFailure = { [weak self] reason in
            // Unsupported tracks (DTS / TrueHD only, VP9, …) are reported
            // within seconds of the header — hand the stream to VLC.
            DispatchQueue.main.async { self?.requestFallback(reason) }
        }
        remux.onHalted = { [weak self] reason in
            // The remux stopped producing after `onReady` (disk full…): the
            // missing segments will never exist. VLC reads the torrent file
            // itself (no extra disk) — at once, at the current position.
            DispatchQueue.main.async { self?.remuxDidHalt(reason) }
        }
        // Main queue: an OpenSubtitles file the automatic sync retimed.
        remux.onExternalSubtitleRetimed = { [weak self] key in
            DispatchQueue.main.async { self?.retimeWatch.retimed(key: key) }
        }
        remux.onUnavailableSegmentRequested = { [weak self] playerSeconds in
            // Playback needs a pruned segment (deleted for good): at once for
            // a rewind past the kept media or into a span a far seek skipped;
            // for a pruned span AVPlayer prefetched ahead of the playhead,
            // only once playback gets within about a segment of it (the remux
            // holds that request meanwhile, AVPlayer plays its buffer
            // natively). AVPlayer would retry the 404 for ~30 s, then fail.
            DispatchQueue.main.async { self?.unavailableSegmentRequested(at: playerSeconds) }
        }
        // A seek into pruned segments while a starvation recovery waits:
        // the dead item requests nothing, the recovery asks here.
        starvation.positionUnavailable = { [weak self, weak remux] seconds in
            guard let remux = remux, !remux.isAvailable(playerSeconds: seconds) else { return false }
            // Bounded storage: a rewind there is blocked, not handed to VLC —
            // the dead item moves to the earliest point still available.
            return !(self?.limitRecoveringRewind(to: seconds) ?? false)
        }
        // OpenSubtitles surface as native HLS subtitle tracks in AVPlayer's
        // own picker. The play flow started their search with the stream
        // (`SubtitleSearch`): it has usually answered by now.
        if let media = media {
            if !media.subtitles.isEmpty {
                remux.subtitles = media.subtitles
            } else if let found = SubtitleSearch.shared.answer(for: media) {
                // Answered while the stream prepared — possibly with nothing:
                // no hold either way (an empty answer used to be searched
                // again here, `onReady` held meanwhile).
                remux.subtitles = found
            } else {
                // Still searching (a finished download, a very fast swarm, a
                // slow OpenSubtitles). AVPlayer reads the master playlist
                // once: `onReady` is held so the list can land in it, until
                // it comes or `startHold` after the search began, whichever
                // is first — assigning `subtitles` (even []) releases the
                // hold. A list that comes later still is in the masters
                // served from then on: when a player has already read one,
                // its item is rebuilt once (`rebuildForLateSubtitlesIfDue`).
                remux.externalSubtitlesPending = true
                SubtitleSearch.shared.search(for: media, waitingAtMost: SubtitleSearch.startHold) { [weak self, weak remux] subtitles, isFinal in
                    if !isFinal { print("[Player] OpenSubtitles has not answered: starting without its list") }
                    guard let remux = remux else { return }
                    if isFinal {
                        self?.lateSubtitles.listArrived(isEmpty: subtitles.isEmpty, masterServed: remux.hasServedMaster)
                    }
                    remux.subtitles = subtitles
                }
            }
        }
        // Started even while the resume question is up: the header gives the
        // exact time to show, an unplayable file goes to VLC without asking,
        // the torrent is turned to the resume point, and « Reprendre du
        // début » then starts at once.
        remux.start()
    }

    private func remuxDidBecomeReady(_ playlistURL: URL) {
        guard !isTornDown, !fallbackRequested else { return }
        if resumeChoicePending {
            pendingPlaylistURL = playlistURL
            return
        }
        if isResumingNatively {
            // « Reprendre à … » was answered before the remux was ready: the
            // item is made once the media at the resume point is on disk.
            pendingPlaylistURL = playlistURL
            attachNativeResumeWhenReady()
            return
        }
        attachPlayer(to: playlistURL, direct: false)
    }

    /// `RemuxPlayback.onHalted`: VLC now, at the current position (or the
    /// one a starvation recovery was resuming at).
    private func remuxDidHalt(_ reason: String) {
        guard !isTornDown, !fallbackRequested else { return }
        print("[Player] remux halted after playback started (\(reason))")
        requestFallback(reason)
    }

    /// `RemuxPlayback.onUnavailableSegmentRequested`: VLC at once, at the
    /// earlier of the playhead and the requested pruned segment's start
    /// (`ResumePolicy.handOffTime`) — the playhead when it lies before that
    /// segment (« recommencer » in the kept segment 0 while AVPlayer
    /// prefetches the pruned segment 1; playback reaching a pruned span
    /// about a segment early), the segment's start for a scrub into the
    /// pruned range. Around the resume seek the first item — which
    /// loads at 0, not positioned — is a special case (`RemuxPlayback`'s
    /// contract for such an item; its server holds such requests too):
    ///  - seek in flight: ignored. The item prefetched segments 1, 2… from 0,
    ///    which the remux, told the resume target at once, may evict under
    ///    disk pressure; the seek moves the item away and AVPlayer drops
    ///    those requests (measured: no failure follows a 404 there);
    ///  - seek not issued yet (item not ready): its start-up data is gone —
    ///    measured, it then never becomes ready —, so VLC at once, at the
    ///    resume point (not at 0:00, where the item sits).
    private func unavailableSegmentRequested(at playerSeconds: Double) {
        guard !isTornDown, !fallbackRequested, route == .remux, remux != nil else { return }
        if isSeekingToStart {
            print("[Player] pruned segment requested at \(Int(playerSeconds)) s while the start seek is in flight — "
                  + "a prefetch of the item loaded at 0, ignored")
            return
        }
        if awaitingStartSeek {
            print("[Player] pruned segment requested at \(Int(playerSeconds)) s before the start seek — VLC at the resume point")
            requestFallback(ResumePolicy.rewindPastBufferReason)
            return
        }
        // Bounded storage: a rewind past the kept media is blocked (the
        // earliest point still available instead, never VLC); playback
        // reaching a pruned span ahead goes on below (VLC at the playhead,
        // when its data is still there: `requestFallback`).
        if limitBoundedRewind(toPrunedSegmentAt: playerSeconds) { return }
        let target = ResumePolicy.handOffTime(prunedSegmentStart: playerSeconds, playhead: player?.currentTime().seconds)
        print("[Player] pruned segment requested at \(Int(playerSeconds)) s — target \(Int(target)) s")
        requestFallback(ResumePolicy.rewindPastBufferReason, resumeTime: target)
    }

    // MARK: - Bounded storage: rewinds

    /// The stream's bounded storage (nil: none — a download, a local file).
    /// Its `isBounded` is false in full mode: nothing below acts then.
    private var boundedStorage: BoundedStorageSession? { BoundedStorageSession.session(for: keepAliveStreamer) }

    /// The pending check after a burst of time jumps (`scheduleBoundedRewindCheck`).
    private var boundedRewindCheck: DispatchWorkItem?
    /// tvOS: a time jump happened while paused; checked once playback resumes.
    private var boundedCheckOnPlay = false
    /// When the playhead was last moved to the earliest point kept
    /// (`limitRewind`, uptime): a pruned request right after it is that
    /// blocked seek's leftover.
    private var lastBoundedLimitAt: TimeInterval?

    /// Bounded storage, a time jump of a healthy item (a scrub, a skip, a
    /// remote command, Siri): a playhead that went further back than what is
    /// still on disk goes to the earliest point still available, with the
    /// message. Checked 0.35 s after the last jump of a burst (iOS's timeline
    /// seeks all along a drag: the drag is not fought). tvOS: only while
    /// playing — a scrub while paused ends in
    /// `timeToSeekAfterUserNavigatedFrom`, which limits it.
    private func scheduleBoundedRewindCheck() {
        guard boundedStorage?.isBounded == true else { return }
        boundedRewindCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkBoundedRewind() }
        boundedRewindCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func checkBoundedRewind() {
        guard isItemHealthy, let player = player else { return }
#if os(tvOS)
        // Paused: a scrub ends in `timeToSeekAfterUserNavigatedFrom`, which
        // limits it; any other jump (a remote command from Control Center…)
        // is checked when playback resumes (`playerRateDidChange`).
        guard player.rate != 0 else { boundedCheckOnPlay = true; return }
        boundedCheckOnPlay = false
#endif
        let now = player.currentTime().seconds
        // From the last position playback actually reached (not a seek
        // target AVPlayer still holds: a far seek forward, then back, stays
        // allowed).
        guard let reference = playedPosition.lastPlayedTime,
              let landing = BoundedStorageUX.limitedRewindTarget(now, from: reference, session: boundedStorage) else { return }
        limitRewind(target: now, from: reference, landing: landing)
    }

    /// `unavailableSegmentRequested` in bounded mode: a pruned segment
    /// BEHIND the last played position is a rewind past the kept media —
    /// blocked: the playhead goes to the earliest point still available
    /// (unless it is already there: the request was the blocked seek's).
    /// False for a pruned span ahead, and outside bounded mode.
    private func limitBoundedRewind(toPrunedSegmentAt playerSeconds: Double) -> Bool {
        guard let session = boundedStorage, session.isBounded, let player = player else { return false }
        let now = player.currentTime().seconds
        guard let reference = playedPosition.lastPlayedTime, playerSeconds < reference else { return false }
        let earliest = session.earliestRewindTime(fromPlayerTime: reference) ?? reference
        if now.isFinite, now >= earliest {
#if os(tvOS)
            // The player reads a kept time: the leftover of a seek just
            // blocked (`limitRewind`), or of a navigation AVKit's delegate
            // already limited — else a seek whose target `currentTime()` does
            // not show (the Apple TV kept the old time during a held seek, and
            // no delegate call is assumed): blocked as any rewind past the kept
            // media, at the earliest point kept.
            let justLimited = lastBoundedLimitAt.map { ProcessInfo.processInfo.systemUptime - $0 < 10 } ?? false
            let limitedNavigation = pendingNavigationTarget().map { $0 >= earliest } ?? false
            if justLimited || limitedNavigation { return true }
            print("[Player] pruned segment requested at \(Int(playerSeconds)) s, behind what is kept, while the player "
                  + "reads \(Int(now)) s — a seek there: blocked")
            let landing = BoundedStorageUX.limitedRewindTarget(playerSeconds, from: reference, session: session) ?? earliest
            limitRewind(target: playerSeconds, from: reference, landing: landing)
#endif
            return true
        }
#if !os(tvOS)
        // iOS: AVKit seeks all along a timeline drag, and each pruned segment
        // it asks for lands here — the time-jump check limits the rewind
        // 0.35 s after the last jump instead, so the drag is not fought.
        if isItemHealthy {
            scheduleBoundedRewindCheck()
            return true
        }
#endif
        let target = now.isFinite ? min(now, reference) : playerSeconds
        let landing = BoundedStorageUX.limitedRewindTarget(target, from: reference, session: session) ?? reference
        limitRewind(target: target, from: reference, landing: landing)
        return true
    }

    /// Bounded storage, during a starvation recovery: the user moved the
    /// dead item's playhead into deleted media. Instead of VLC there, it
    /// goes to the earliest point still available — the recovery follows it
    /// as the user's new target at its next look — with the message. True
    /// when it did (outside bounded mode, and for a pruned span AHEAD of the
    /// last played position: false).
    private func limitRecoveringRewind(to seconds: Double) -> Bool {
        guard let session = boundedStorage, session.isBounded, player != nil,
              let reference = playedPosition.lastPlayedTime, seconds < reference else { return false }
        let landing = BoundedStorageUX.limitedRewindTarget(seconds, from: reference, session: session) ?? reference
        limitRewind(target: seconds, from: reference, landing: landing)
        return true
    }

    /// Moves the playhead to `landing` (a limited rewind) and says why.
    private func limitRewind(target: Double, from reference: Double, landing: Double) {
        BoundedStorageUX.logLimited(player: "AVPlayer", target: target, playhead: reference, landing: landing,
                                    session: boundedStorage)
        logRewindBlockedByJump(target: target, landing: landing)
        lastBoundedLimitAt = ProcessInfo.processInfo.systemUptime
        player?.seek(to: CMTime(seconds: landing, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        showBoundedToast()
    }

    /// Bounded storage, remux path: the rewind stopped at the edge of what a
    /// native jump skipped (a resume, a far seek) — never downloaded, which
    /// is what the message then says (`isRewindFloorNeverDownloaded`).
    private func logRewindBlockedByJump(target: Double, landing: Double) {
        guard route == .remux, boundedStorage?.isRewindFloorNeverDownloaded == true else { return }
        print("[Resume] rewind to \(String(format: "%.1f", target)) s blocked at \(String(format: "%.1f", landing)) s "
              + "(bounded, never downloaded)")
    }

    private func showBoundedToast() {
        guard let overlay = contentOverlayView else { return }
        BoundedStorageToastView.show(BoundedStorageUX.rewindLimitedMessage(for: boundedStorage), in: overlay)
    }

    /// Where VLC would continue (player timeline, s) when `requestFallback`
    /// gets no explicit time: what `currentResumeFraction` reads, in
    /// seconds. nil before playback started (VLC then resumes at the start
    /// position: nothing was deleted yet).
    private func knownPlaybackSeconds() -> Double? {
        guard didStartPlayback else { return nil }
        if starvation.isRecovering, let time = starvation.resumeTime { return time }
        if let player = player, player.currentItem?.status == .readyToPlay {
            let time = player.currentTime().seconds
            if time.isFinite, time >= 0 { return time }
        }
        return starvation.abandonedTime ?? lastKnownTime
    }

    /// Bounded storage: the hand-off to VLC at `resumeTime` (nil: the
    /// current position) would read deleted torrent data (HTTP 410). VLC
    /// continues where playback was instead when THAT is still there (a
    /// rewind target that is gone); `.end` when nothing can play here.
    private enum BoundedHandOff { case asked, at(Double), end }

    private func boundedHandOff(resumeTime: Double?) -> BoundedHandOff {
        guard route != .vlc, let session = boundedStorage, session.isBounded,
              let wanted = resumeTime ?? knownPlaybackSeconds(),
              !session.canResumeOverHTTP(atPlayerSeconds: wanted) else { return .asked }
        if let played = playedPosition.lastPlayedTime, played > wanted, session.canResumeOverHTTP(atPlayerSeconds: played) {
            print("[Bounded] VLC can't resume at \(Int(wanted)) s (deleted) — at the last played position \(Int(played)) s")
            return .at(played)
        }
        print("[Bounded] VLC can't resume at \(Int(wanted)) s: that part of the torrent is deleted")
        return .end
    }

    /// Bounded storage: native playback can't go on and VLC can't resume
    /// where it would have to (deleted): say so, then close (the stream is
    /// cancelled as at any close).
    private func endPlaybackForBoundedStorage(_ reason: String) {
        print("[Bounded] native playback unavailable (\(reason)) and its data is deleted — closing the player")
        fallbackRequested = true
        resumeChoicePending = false
        pendingPlaylistURL = nil
        stopNativePlayback()
        loadingIndicator.stopAnimating()
        bufferingLabel.isHidden = true
        engineLine = "arrêt — \(reason) (espace limité)"
        guard hasAppeared else {
            closePlayer()
            return
        }
        let alert = UIAlertController(title: BoundedStorageUX.cannotContinueTitle,
                                      message: BoundedStorageUX.cannotContinueMessage, preferredStyle: .alert)
        // `.cancel`: the Menu button (tvOS) answers it too.
        alert.addAction(UIAlertAction(title: "OK".localized, style: .cancel) { [weak self] _ in
            DispatchQueue.main.async { self?.closePlayer() }
        })
        var presenter: UIViewController = self
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        presenter.present(alert, animated: true)
    }

    // MARK: - Resume question (remux path, payload still downloading)

    /// What « Reprendre à … » means now (`ResumePolicy.resumeEngine`): the
    /// native player once the remux says its conversion can jump to the saved
    /// position, VLC when it says it can't, when native jumps are off, or when
    /// nothing is known `ResumePolicy.readinessWait` after the player started
    /// waiting. nil: not known yet.
    private func currentResumeEngine() -> ResumePolicy.ResumeEngine? {
        let now = ProcessInfo.processInfo.systemUptime
        return ResumePolicy.resumeEngine(readiness: remux?.resumeReadiness ?? .pending,
                                         waited: now - (resumeWaitStartedAt ?? now), nativeJumps: nativeJumps,
                                         indexIsRead: remux?.isKeyframeIndexRead == true)
    }

    /// Seconds since the remux started (the `[Resume]` lines' clock), to a tenth.
    private func sinceResumeStart(_ mark: TimeInterval? = nil) -> String {
        let from = mark ?? resumeStartedAt ?? ProcessInfo.processInfo.systemUptime
        return String(format: "%.1f", ProcessInfo.processInfo.systemUptime - from)
    }

    /// The saved position as the user reads it: the clock time once the MKV
    /// header gave the film's length, the percentage before.
    private func resumePositionLabel() -> String {
        ResumePolicy.resumeLabel(fraction: startPosition, durationSeconds: remux?.session?.totalDurationSeconds ?? 0)
    }

    /// Waits, under the spinner, until the engine of the resume is known
    /// (≤ `ResumePolicy.readinessWait`; a slow head whose index is read is
    /// waited for: it will be native) — and briefly (≤ 2.5 s) for the MKV
    /// header so the question can show the exact clock time — then asks. A
    /// decided start is not asked about: it resumes, on that engine.
    private func scheduleResumeQuestion() {
        guard resumeChoicePending, !fallbackRequested, !isTornDown else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if resumeWaitStartedAt == nil { resumeWaitStartedAt = now }
        let waited = now - (resumeWaitStartedAt ?? now)
        let headerParsed = remux?.session?.isHeaderParsed ?? false
        guard let engine = currentResumeEngine(), headerParsed || waited >= 2.5 else {
            // A decided start says where it is going while it waits.
            if resumesWithoutQuestion { showResuming(at: resumePositionLabel()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.scheduleResumeQuestion()
            }
            return
        }
        if resumesWithoutQuestion {
            resolveResumeChoice(resume: true)
        } else {
            presentResumeQuestion(engine)
        }
    }

    private func presentResumeQuestion(_ engine: ResumePolicy.ResumeEngine) {
        guard resumeChoicePending, !fallbackRequested, !isTornDown, resumeAlert == nil else { return }
        let position = resumePositionLabel()
        let alert = UIAlertController(title: NSLocalizedString("Remux.Resume.Title", value: "Resume playback?",
                                                               comment: "Native player: resume question while the file still downloads"),
                                      message: ResumePolicy.resumeQuestionMessage(for: engine),
                                      preferredStyle: .alert)
        let resumeTitle = String(format: NSLocalizedString("Remux.Resume.At", value: "Resume at %@",
                                                           comment: "Native player: resume button; %@ = the position, e.g. 1:02:07"), position)
        let resume = UIAlertAction(title: resumeTitle, style: .default) { [weak self] _ in
            DispatchQueue.main.async { self?.resolveResumeChoice(resume: true) }
        }
        alert.addAction(resume)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Remux.Resume.FromStart", value: "Start from the beginning",
                                                               comment: "Native player: play from the start, natively"),
                                      style: .default) { [weak self] _ in
            DispatchQueue.main.async { self?.resolveResumeChoice(resume: false) }
        })
        // Menu (tvOS) / Cancel: leave the player.
        alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel) { [weak self] _ in
            DispatchQueue.main.async { self?.cancelFromResumeQuestion() }
        })
        // Initial focus (tvOS) / emphasis (iOS) on « Reprendre ».
        alert.preferredAction = resume
        resumeAlert = alert
        questionEngine = engine
        resumeQuestionShownAt = ProcessInfo.processInfo.systemUptime
        loadingIndicator.stopAnimating()
        print("[Player] resume question: \(Int(startPosition * 100)) % (\(position)), payload still downloading")
        print("[Resume] question shown (\(ResumePolicy.logName(of: engine))) at +\(sinceResumeStart()) s")
        if case .vlc(let reason) = engine { print("[Resume] not native for the player: \(reason) — the question says VLC") }
        // On top of anything already presented over the player (AVKit sheet).
        var presenter: UIViewController = self
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        presenter.present(alert, animated: true)
        #if DEBUG
        // `-PTDebugResumeAnswer resume|start` (BoundedStorageDebugHooks): the
        // question answers itself, `-PTDebugResumeAnswerAfter` seconds later.
        if let answer = BoundedStorageDebugHooks.resumeAnswer {
            DispatchQueue.main.asyncAfter(deadline: .now() + answer.after) { [weak self, weak alert] in
                guard let self = self, self.resumeChoicePending else { return }
                print("[BoundedDebug] resume question answered by the script: \(answer.resume ? "resume" : "start")")
                let resolve = { self.resolveResumeChoice(resume: answer.resume) }
                if let alert = alert, alert.presentingViewController != nil {
                    alert.dismiss(animated: true, completion: resolve)
                } else {
                    resolve()
                }
            }
        }
        #endif
    }

    /// `RemuxPlayback.onResumeReadinessChanged`. While the question is up its
    /// message follows what « Reprendre à … » now means: the remux can find,
    /// from the bytes that arrive at the resume point, that the file's index
    /// does not say true there (native → VLC).
    private func resumeReadinessChanged(_ readiness: NativeResumeReadiness) {
        guard !isTornDown, !fallbackRequested else { return }
        if readiness == .native, resumeNativeSince == nil { resumeNativeSince = ProcessInfo.processInfo.systemUptime }
        guard resumeChoicePending, let alert = resumeAlert, let engine = currentResumeEngine(),
              engine != questionEngine else { return }
        questionEngine = engine
        alert.message = ResumePolicy.resumeQuestionMessage(for: engine)
        print("[Resume] question now says \(ResumePolicy.logName(of: engine)) at +\(sinceResumeStart()) s")
    }

    private func resolveResumeChoice(resume: Bool) {
        guard resumeChoicePending, !fallbackRequested, !isTornDown else { return }
        resumeChoicePending = false
        resumeAlert = nil
        // How long the question was up.
        let after = sinceResumeStart(resumeQuestionShownAt ?? resumeWaitStartedAt)
        if resume {
            // The user decided (here, or before: a lighter release): a
            // hand-off to VLC, now or later, must not ask again.
            userChoseResume = true
            // As the remux says NOW; not known (a slow head whose index is
            // read): native — the remux takes the answer when it is ready.
            let engine = currentResumeEngine() ?? .native
            let how = resumesWithoutQuestion ? "a decided start" : "after \(after) s"
            switch engine {
            case .native:
                print("[Resume] answer: resume at \(resumePositionLabel()) (\(how)) — native")
                beginNativeResume()
            case .vlc(let reason):
                // Same stream, VLC at the saved position (playback never
                // started, so the hand-off resumes at `startPosition`).
                print("[Resume] answer: resume at \(resumePositionLabel()) (\(how)) — through VLC (\(reason))")
                hideResuming()
                requestFallback(ResumePolicy.vlcResumeReason(reason))
            }
            return
        }
        print("[Player] resume declined — native playback from the beginning")
        print("[Resume] answer: from the beginning (after \(after) s)")
        // The torrent goes back to the head (the remux logs where).
        remux?.cancelResume()
        userChoseStartOver = true
        startPosition = 0
        if let url = pendingPlaylistURL {
            pendingPlaylistURL = nil
            attachPlayer(to: url, direct: false)
        } else {
            // Remux still preparing: `onReady` attaches.
            loadingIndicator.startAnimating()
        }
    }

    // MARK: - Native resume and jumps (remux path)

    /// « Reprendre à … », natively: the remux moves its conversion to the
    /// saved position now (`commitResume`; the torrent has been turning there
    /// since the question came up). Until the picture at that position plays,
    /// the screen is black with the spinner and « Reprise à 1:40:00… ». The
    /// item is made only once the media at that position is on disk
    /// (`attachNativeResumeWhenReady`), positioned there before it is
    /// attached (`attachPlayer`).
    private func beginNativeResume() {
        isResumingNatively = true
        resumeAnsweredAt = ProcessInfo.processInfo.systemUptime
        remux?.commitResume()
        showResuming(at: resumePositionLabel(), covered: true)
        // The remux hears where the player is going before its item exists.
        reportPlaybackPositions()
        attachNativeResumeWhenReady()
    }

    /// A poll of `attachNativeResumeWhenReady` is scheduled.
    private var isPollingResumeAttach = false

    /// A native resume makes its item once the media to start at the resume
    /// point is on disk (`RemuxPlayback.hasMediaToStart`: two segments, as
    /// at 0:00) — polled every 0.2 s under the cover. An item attached before
    /// would hold the request for a segment the conversion has yet to write,
    /// and AVPlayer gives up on a held request after about one target
    /// duration — on tvOS for good, without ever failing
    /// (`ResumePolicy.resumeAttach`). The torrent has been turning to that
    /// position since the question came up: with the answer a few seconds
    /// later the media is usually there within a second. A resume the remux
    /// can no longer serve natively goes to VLC at the saved position.
    private func attachNativeResumeWhenReady() {
        guard isResumingNatively, player == nil, !isTornDown, !fallbackRequested, let remux = remux else { return }
        let target = remux.resumeTargetSeconds
        var refusal = remux.failureReason
        if refusal == nil, case .vlcOnly(let reason) = remux.resumeReadiness { refusal = reason }
        let step = ResumePolicy.resumeAttach(isPlaylistReady: pendingPlaylistURL != nil, hasTarget: target != nil,
                                             hasMedia: target.map { remux.hasMediaToStart(fromPlayerSeconds: $0) } ?? false,
                                             isAvailable: target.map { remux.isAvailable(playerSeconds: $0) } ?? true,
                                             refusal: refusal)
        switch step {
        case .attach:
            guard let url = pendingPlaylistURL else { return }
            pendingPlaylistURL = nil
            let waited = resumeAnsweredAt.map { String(format: "%.1f", ProcessInfo.processInfo.systemUptime - $0) } ?? "?"
            print("[Resume] media at the resume point on disk \(waited) s after the answer — the player's item is made")
            attachPlayer(to: url, direct: false)
        case .vlc(let reason):
            print("[Resume] the resume can't be native after all (\(reason)) → VLC at \(resumePositionLabel())")
            requestFallback(reason)
        case .wait:
            guard !isPollingResumeAttach else { return }
            isPollingResumeAttach = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.isPollingResumeAttach = false
                self?.attachNativeResumeWhenReady()
            }
        }
    }

    /// The picture at the resume position plays (the player's first
    /// `.playing`, which only comes after the start seek — or after the
    /// starvation recovery that took it over): the cover and the label go.
    private func finishNativeResume() {
        guard isResumingNatively else { return }
        isResumingNatively = false
        hideResuming()
        let now = ProcessInfo.processInfo.systemUptime
        let time = player?.currentTime().seconds ?? .nan
        let answered = resumeAnsweredAt.map { String(format: "%.1f", now - $0) } ?? "?"
        let steered = resumeNativeSince.map { String(format: "%.1f", now - $0) } ?? "?"
        print("[Resume] first frame at \(String(format: "%.1f", time)) s — \(answered) s after the answer, "
              + "\(steered) s after steering")
    }

    /// Safety net (1 Hz): the cover never outlives a resume whose seek is
    /// over on a player that is no longer waiting (paused by the user right
    /// at the landing: there is no first `.playing` to wait for).
    private func checkNativeResumeCover() {
        guard isResumingNatively, let player = player, didStartPlayback, !awaitingStartSeek, !isSeekingToStart,
              !starvation.isRecovering, player.currentItem?.status == .readyToPlay,
              player.timeControlStatus != .waitingToPlayAtSpecifiedRate else { return }
        finishNativeResume()
    }

    /// The spinner with « Reprise à <position>… » under it; `covered`: over
    /// black (a native resume: the item's first frame is hidden). `target`:
    /// the position on the player's timeline (nil: the start's resume, whose
    /// position the remux places): once the wait lasts, the label says how
    /// far the media there is (« Reprise à 22:35 — 45 % · 9,6 Mo/s »,
    /// `refreshResumingText`).
    private func showResuming(at position: String, covered: Bool = false, target: Double? = nil) {
        resumingPosition = position
        resumingTarget = target
        resumingLabel.text = currentResumingText(position: position, target: target)
        resumingLabel.isHidden = false
        bufferingLabel.isHidden = true
        if covered { resumeCover.isHidden = false }
        loadingIndicator.startAnimating()
    }

    /// 1 Hz, while « Reprise à … » shows: its progress, from the remux's
    /// latest look (`RemuxPlayback.waitProgress`, refreshed on the remux's
    /// own 1 s tick — only the formatting runs here).
    private func refreshResumingText() {
        guard !resumingLabel.isHidden, let position = resumingPosition else { return }
        let text = currentResumingText(position: position, target: resumingTarget)
        if resumingLabel.text != text { resumingLabel.text = text }
    }

    /// « Reprise à <position> — 45 % · 9,6 Mo/s » from the remux's latest look.
    private func currentResumingText(position: String, target: Double?) -> String {
        #if DEBUG
        if let sample = Self.debugResumingSample { return ResumePolicy.resumingText(position: sample.position, progress: sample.progress) }
        #endif
        return ResumePolicy.resumingText(position: position, progress: ResumePolicy.progress(remux?.waitProgress, forTarget: target))
    }

    #if DEBUG
    /// `-PTDebugResumingSample "<position>|<percent>|<bytes per second>"` (DEBUG): every « Reprise à … »
    /// shows that text instead of the wait's — a screenshot of the longest string the label can carry
    /// (« Reprise à 1:28:20 — 100 % · 1 000 octets/s ») on a real wait of the loopback rig.
    private static let debugResumingSample: (position: String, progress: JumpWaitProgress)? = {
        guard let raw = UserDefaults.standard.string(forKey: "PTDebugResumingSample") else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let percent = Double(parts[1]), let rate = Int(parts[2]) else { return nil }
        let progress = JumpWaitProgress(targetSeconds: nil, segment: nil, waitedSeconds: 5, isJump: true,
                                        shownFraction: min(1, max(0, percent / 100)), isMediaReady: percent >= 100,
                                        bytesPerSecond: rate)
        return (parts[0], progress)
    }()
    #endif

    /// Takes « Reprise à … » (and the cover) away; the spinner stays when
    /// something else still needs it.
    private func hideResuming() {
        resumingLabel.isHidden = true
        resumingPosition = nil
        resumingTarget = nil
        resumeCover.isHidden = true
        jumpLabelTarget = nil
        if starvation.isRecovering, !starvation.isWaitingForPlay {
            // The recovery's own wait shows again as what it is.
            showStarvationIndicator(true)
        } else if !isSeekingToStart, player != nil {
            loadingIndicator.stopAnimating()
        }
    }

    /// The dark capsule around the spinner and the label that shows
    /// (« Reprise à … » or the starvation text); none when neither shows
    /// (the spinner alone, at the start, stays as it was). Follows the
    /// labels' `isHidden` (`StatusCapsuleLabel.onVisibilityChange`).
    private func layoutStatusCapsule() {
        guard statusCapsule.superview != nil else { return }
        let shown: UILabel? = !resumingLabel.isHidden ? resumingLabel : (!bufferingLabel.isHidden ? bufferingLabel : nil)
        NSLayoutConstraint.deactivate(statusCapsuleConstraints)
        statusCapsuleConstraints = []
        if let label = shown {
            let padding = StatusCapsuleLabel.padding
            statusCapsuleConstraints = [
                statusCapsule.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: padding),
                statusCapsule.widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 2 * padding),
            ]
            NSLayoutConstraint.activate(statusCapsuleConstraints)
        }
        statusCapsule.isHidden = shown == nil
    }

    /// The position of the jump whose « Reprise à … » is up (a far seek, a
    /// rewind into what a jump skipped — not the start's native resume, which
    /// has its own life: `isResumingNatively`).
    private var jumpLabelTarget: Double?
    /// What « Reprise à … » shows: its position as written, and on the
    /// player's timeline (nil: the start's resume) — `refreshResumingText`.
    private var resumingPosition: String?
    private var resumingTarget: Double?

    /// `RemuxPlayback.onJumpStateChanged`: the conversion was moved to serve
    /// a position somebody waits on — « Reprise à … » and the spinner until
    /// playback runs there (the wait is the torrent turning to that part and
    /// the first segments: seconds), instead of a silent frozen picture.
    private func jumpStateChanged(_ state: RemuxPlayback.JumpState) {
        guard !isTornDown, !fallbackRequested else { return }
        switch state {
        case .waiting(let playerSeconds):
            switch ResumePolicy.jumpWaitResponse(isResumingNatively: isResumingNatively, hasItem: player != nil) {
            case .ignore:
                // The start's resume already says it, over its cover.
                return
            case .armGraceOnly:
                // A seek under the resume's cover: the cover stays (no
                // `jumpLabelTarget`: `checkJumpLabel` would take it away),
                // its text follows the new position.
                showResuming(at: ResumePolicy.clockString(seconds: playerSeconds), covered: true, target: playerSeconds)
            case .showAndArmGrace:
                jumpLabelTarget = playerSeconds
                showResuming(at: ResumePolicy.clockString(seconds: playerSeconds), target: playerSeconds)
            }
            // The item is not left waiting on a segment the torrent has yet
            // to bring (`moveJumpWaitToNewItemIfNeeded`).
            jumpWaitCheck += 1
            let check = jumpWaitCheck
            DispatchQueue.main.asyncAfter(deadline: .now() + ResumePolicy.jumpGraceSeconds) { [weak self] in
                self?.moveJumpWaitToNewItemIfNeeded(check)
            }
        case .landed:
            checkJumpLabel()
        case .failed:
            guard jumpLabelTarget != nil else { return }
            hideResuming()
        }
    }

    /// The latest jump whose grace is running (only that one is checked).
    private var jumpWaitCheck = 0

    /// `ResumePolicy.jumpGraceSeconds` after the conversion was moved to a
    /// position somebody waits on (a far seek, a rewind into what a jump
    /// skipped): when the first segment there is still not written — the
    /// torrent has to turn to that part of the file — the wait moves from
    /// the item to the starvation recovery's (`waitForJump`): the player
    /// paused under « Reprise à … », a new item pre-positioned there once
    /// its media is on disk (`RemuxPlayback.hasMediaToStart`). The item
    /// that asked would give up on its held request after about one target
    /// duration, and on tvOS never play again nor fail
    /// (`ResumePolicy.jumpNeedsNewItem`). A jump over data already on disk
    /// has written its segment by now: that item just plays on.
    private func moveJumpWaitToNewItemIfNeeded(_ check: Int) {
        guard check == jumpWaitCheck, !isTornDown, !fallbackRequested, route == .remux, let remux = remux,
              let player = player, let wanted = wantedPosition() else { return }
        guard ResumePolicy.jumpNeedsNewItem(isJumpWaiting: remux.isJumpWaiting,
                                            hasFirstSegment: remux.hasMedia(fromPlayerSeconds: wanted, cushion: 0),
                                            isRecovering: starvation.isRecovering, isItemHealthy: isItemHealthy) else { return }
        // The move's origin: where AVPlayer puts its time back if it gives
        // up on the held seek (not a user seek, the wait stays at `wanted`).
        let origin = navigation.target.flatMap { abs($0 - wanted) <= UserNavigationTarget.thresholdSeconds ? navigation.from : nil }
        let started = starvation.waitForJump(player: player, at: wanted, resumesPlayback: playIntent.wantsPlayback,
                                             rebuildsWhilePaused: true, keepsPlayerRate: true,
                                             seekOrigin: origin) { [weak remux] time, _ in
            guard let remux = remux else { return false }
            // Bounded storage: a deleted segment never comes back (the wait
            // follows the playhead `limitRecoveringRewind` moved instead).
            if remux.isStorageBounded, !remux.isAvailable(playerSeconds: time) { return false }
            return remux.hasMediaToStart(fromPlayerSeconds: time)
        }
        guard started else { return }
        // The target is the recovery's from here on.
        _ = heldSeek.take()
        print("[Resume] jump to \(String(format: "%.1f", wanted)) s: its first segment is not written "
              + "\(String(format: "%.1f", ResumePolicy.jumpGraceSeconds)) s on — the wait moves to a new item, made once its media is on disk"
              + " (the player reads \(String(format: "%.1f", player.currentTime().seconds)) s, rate \(player.rate))")
    }

    /// At the jump's end and at 1 Hz: the jump's label goes once the player
    /// is no longer waiting for media where it is — media to play is on disk
    /// there and it is not stalled (a paused player never « lands »; one
    /// that went elsewhere, to media that exists, does not wait either).
    private func checkJumpLabel() {
        guard jumpLabelTarget != nil, let remux = remux else { return }
        let waitingForMedia = player?.timeControlStatus == .waitingToPlayAtSpecifiedRate || starvation.isRecovering
        guard !waitingForMedia, let wanted = wantedPosition(), remux.hasMedia(fromPlayerSeconds: wanted, cushion: 0) else { return }
        hideResuming()
    }

    /// `RemuxPlayback.onJumpFailed`: the conversion can't serve that position
    /// after all (the file's index does not say true there): VLC there, on
    /// the same stream (`onHalted` follows; the first of the two hands over).
    private func jumpFailed(_ reason: String, at playerSeconds: Double) {
        guard !isTornDown, !fallbackRequested else { return }
        print("[Player] the conversion could not jump to \(Int(playerSeconds)) s (\(reason)) — VLC there")
        requestFallback(reason, resumeTime: playerSeconds)
    }

    private func cancelFromResumeQuestion() {
        guard resumeChoicePending, !isTornDown else { return }
        resumeChoicePending = false
        resumeAlert = nil
        print("[Player] resume question cancelled — closing")
        closePlayer()
    }

    /// Leaves the player: the owner's close (iOS cover), else the modal
    /// dismissal (tvOS). Either way the teardown cancels the stream.
    private func closePlayer() {
        if let onCloseRequest = onCloseRequest {
            onCloseRequest()
        } else {
            dismissPlayer(animated: true) { [weak self] in self?.tearDown() }
        }
    }

    /// Dismisses this modally presented player together with anything it
    /// presents (dismissing from the PRESENTER: `self.dismiss` would only
    /// close a presented alert), after any transition in progress.
    private func dismissPlayer(animated: Bool, completion: @escaping () -> Void) {
        guard let presenter = presentingViewController else {
            completion()
            return
        }
        // (`animate` returns false — and never runs the completion — when it
        // can't queue: dismiss right away then.)
        if let coordinator = transitionCoordinator ?? presenter.transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { _ in
               presenter.dismiss(animated: animated, completion: completion)
           }) {
            return
        }
        presenter.dismiss(animated: animated, completion: completion)
    }

    // MARK: - Direct path (MP4 / M4V / MOV)

    private func startDirect(url: URL) {
        engineLine = "MP4 direct → AVPlayer (natif)"
        nativeEngineLine = engineLine
        // Nothing is ever pruned on the torrent's own file — except in
        // bounded storage: a seek of the dead item further back than what is
        // still on disk moves it to the earliest point still available (never
        // VLC there). Full mode: never unavailable, as before.
        starvation.positionUnavailable = { [weak self] seconds in
            guard let self = self, let session = self.boundedStorage, session.isBounded,
                  let reference = self.playedPosition.lastPlayedTime, seconds < reference,
                  !session.canSeek(to: seconds, fromPlayerTime: reference) else { return false }
            return !self.limitRecoveringRewind(to: seconds)
        }
        let controller = SubtitleCueController(subtitles: media?.subtitles ?? [])
        subtitleController = controller
        if controller.available.isEmpty {
            // Auto-select the preferred language once OpenSubtitles answers.
            subtitleSubscription = controller.$available
                .first(where: { !$0.isEmpty })
                .receive(on: DispatchQueue.main)
                .sink { [weak controller] _ in
                    guard let controller = controller, controller.selected == nil else { return }
                    controller.autoSelectPreferred()
                }
            controller.loadSubtitlesIfNeeded(for: media)
        } else {
            controller.autoSelectPreferred()
        }
#if os(tvOS)
        // Transport-bar "Sous-titres" menu, rebuilt whenever the list or the
        // selection changes (menus are immutable snapshots).
        subtitleMenuBinder = SubtitleMenuBinder(controller: controller) { [weak self] menu in
            self?.transportBarCustomMenuItems = [menu]
        }
#endif
        if isViewLoaded { installSubtitleOverlayIfNeeded() }
        attachPlayer(to: url, direct: true)
        // Bounded storage: AVPlayer reads through PopcornTorrent's server
        // (which moves the window); its playhead tells the torrent what it
        // may delete behind it.
        BoundedStorageSession.session(for: keepAliveStreamer)?.attachHTTPPlayer(self, readAheadSeconds: Self.directReadAheadSeconds) { [weak self] in
            guard let self = self, !self.isTornDown, !self.fallbackRequested, self.route == .avPlayer,
                  let player = self.player, player.currentItem?.status == .readyToPlay else { return nil }
            let time = player.currentTime().seconds
            guard time.isFinite else { return nil }
            return BoundedPlayerSample(time: time, isPlaying: player.timeControlStatus == .playing)
        }
    }

    /// Bounded storage, direct path: the forward buffer AVPlayer may keep
    /// (`preferredForwardBufferDuration`), and how far past the playhead it
    /// may have read (the buffer plus a margin).
    static let directForwardBufferSeconds: Double = 60
    static let directReadAheadSeconds: Double = 75

    private func installSubtitleOverlayIfNeeded() {
        guard subtitleOverlay == nil, let controller = subtitleController, let container = contentOverlayView else { return }
        let overlay = SubtitleOverlayLabelView(controller: controller)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isUserInteractionEnabled = false
        // Below the stats label.
        container.insertSubview(overlay, at: 0)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        subtitleOverlay = overlay
    }

    // MARK: - Player

    private func attachPlayer(to url: URL, direct: Bool) {
        guard !isTornDown, !fallbackRequested, !resumeChoicePending, player == nil else { return }
        // tvOS only routes surround / Dolby (Atmos) to the receiver when the
        // audio session is .playback / .moviePlayback. AVPlayerViewController
        // does NOT configure this for us, so without it the session stays in a
        // stereo-downmixing default and a byte-perfect Atmos stream still
        // reaches the soundbar as 2.0 — no Atmos badge. The VLC path already
        // sets this (PCTPlayerViewController); the native path must too.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        playbackURL = url
        let item = makePlayerItem(url: url)
        if isResumingNatively, let target = remux?.resumeTargetSeconds, target > 0 {
            // A native resume: positioned BEFORE it is attached, as a
            // starvation recovery's item is — its first media request is the
            // resume segment (on disk: `attachNativeResumeWhenReady`). An
            // unpositioned item loads at 0:00 and prefetches segments 2, 3…,
            // which the jump skipped: requests the server would hold until
            // AVPlayer gives up on them. (No completion handler: a seek with
            // one raises on an item that is not ready; the start seek
            // follows once it is, `applyStartPosition`.) Never past the
            // saved position: a keyframe before it, not the nearest one.
            item.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .positiveInfinity,
                      toleranceAfter: .zero, completionHandler: nil)
        }
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = true
#if os(tvOS)
        // "Match Content": switch the TV to the title's dynamic range (HDR10 /
        // Dolby Vision) and frame rate when the user enabled it in Settings.
        appliesPreferredDisplayCriteriaAutomatically = true
#endif
        self.player = player
        observePlayer(player)
        PlaybackLanguagePreferences.applyPreferredMediaSelection(to: item)
        installFailureObserver(on: item)
        noteAttachedItem(item)
        // (A native resume keeps its spinner, label and cover until the
        // picture at its position plays.)
        if !isResumingNatively { loadingIndicator.stopAnimating() }

        subtitleController?.attach(to: player)
        // The `[Start]` trace's last phase: the player really playing — and
        // the end of a native resume's wait.
        firstFrameWatch = FirstFrameWatch(player: player) { [weak self] in
            self?.keepAliveStreamer?.noteStartFirstFrame(detail: direct ? "AVPlayer (direct)" : "AVPlayer (remux)")
            self?.finishNativeResume()
        }
#if os(tvOS)
        installUpNextIfNeeded(for: item)
#endif
        prepareStartPosition(for: item, direct: direct)
        startPlaybackIfPossible()
        logResolvedAudio(after: item)
    }

    /// The item for `url` — also how the starvation recovery rebuilds it.
    private func makePlayerItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        // Allow AVPlayer to spatialize the multichannel (5.1 + Atmos objects)
        // audio — this is what renders Atmos to AirPods / built-in speakers
        // on iOS (and is a no-op for the Apple TV bitstream path).
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        if route == .avPlayer, BoundedStorageSession.session(for: keepAliveStreamer)?.isBounded == true {
            // Bounded storage: a known read-ahead over the torrent's file.
            item.preferredForwardBufferDuration = Self.directForwardBufferSeconds
        }
        if let title = title, !title.isEmpty {
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = title as NSString
            titleItem.extendedLanguageTag = "und"
            item.externalMetadata = [titleItem]
        }
        return item
    }

    /// For the player's whole life: its rate changes (`playerRateDidChange`)
    /// and the time jumps of its current item (seeks, scrubs) — the positions
    /// are reported to the remux at once then, not at the next tick
    /// (`reportPlaybackPositions`). Removed by `stopNativePlayback`.
    private func observePlayer(_ player: AVPlayer) {
        let center = NotificationCenter.default
        playerObservers.append(center.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player,
                                                  queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVPlayer.rateDidChangeReasonKey] as? AVPlayer.RateDidChangeReason
            MainActor.assumeIsolated { self?.playerRateDidChange(reason: reason) }
        })
        playerObservers.append(center.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: nil,
                                                  queue: .main) { [weak self] note in
            let jumped = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self = self, let item = self.player?.currentItem, jumped === item else { return }
                self.reportPlaybackPositions()
                self.noteHeldSeek(isJump: true)
                self.scheduleBoundedRewindCheck()
            }
        })
#if os(tvOS)
        // Episode chaining: the end of the file (the after-play card, or
        // the countdown's end).
        playerObservers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                                  queue: .main) { [weak self] note in
            let ended = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self = self, let item = self.player?.currentItem, ended === item else { return }
                self.upNextItemEnded(reason: "AVPlayerItemDidPlayToEndTime")
            }
        })
#endif
    }

    /// The current item plays normally: playback started, no start seek, no
    /// recovery or rebuild running (they pause and play the player
    /// themselves), not handing off or closed, the item not failed nor its
    /// failure reported.
    private var isItemHealthy: Bool {
        guard let item = player?.currentItem else { return false }
        return didStartPlayback && !awaitingStartSeek && !isSeekingToStart && !starvation.isRecovering
            && !fallbackRequested && !isTornDown && item.status != .failed && failureObserver?.hasReportedFailure != true
    }

    /// A rate change of the player: the user's play / pause intent and, on
    /// the user's pause, a progress checkpoint (`PlaybackIntentWatch`) — so
    /// a kill while suspended or a crash keeps what was watched. Only on a
    /// healthy item (`isItemHealthy`); the user's play / pause on a dead
    /// item while a recovery waits reaches the intent through the recovery
    /// (`onUserPlaybackChanged`).
    private func playerRateDidChange(reason: AVPlayer.RateDidChangeReason?) {
        guard let player = player else { return }
#if os(tvOS)
        // Bounded storage: a jump made while paused, now played.
        if boundedCheckOnPlay, player.rate != 0 { scheduleBoundedRewindCheck() }
#endif
        let item = player.currentItem
        guard playIntent.noteRateChange(rate: player.rate, reason: reason, isHealthy: isItemHealthy,
                                        canCheckpoint: item?.status == .readyToPlay) else { return }
        print("[Player] paused by the user — progress checkpoint")
        saveProgress(status: .paused)
    }

    /// The 1 Hz tick (after the played position is sampled) and every time
    /// jump of a healthy item: the user's seek target AVPlayer holds, if any
    /// (`HeldSeekWatch`: `wanted` far from the last played position).
    private func noteHeldSeek(isJump: Bool) {
        guard isItemHealthy else { return }
        heldSeek.note(wanted: wantedPosition(), played: playedPosition.lastPlayedTime, isJump: isJump)
    }

    /// Remux path, 1 Hz (right after `noteHeldSeek`): the user's seek target
    /// AVPlayer holds past the remux frontier, on a healthy item while the
    /// user wants playback, goes to VLC AT the target at once when the
    /// frontier can't reach it within about AVPlayer's own hold
    /// (`FarTargetWatch`: the frontier's measured pace while the torrent
    /// grows — the in-order download's, or the remux pump's over data
    /// already on disk) — rather than after AVPlayer's ~42 s failure and a
    /// recovery's long wait. A target the frontier reaches sooner (near, or
    /// over data on disk that the pump reaches within that hold) stays native
    /// and the seek lands; a jump so far into the downloaded part that the
    /// pump can't goes to VLC like a far download.
    /// Anything else resets the measurement: no held target, a paused user
    /// (a paused scrub's target is the recovery's, once play is pressed —
    /// so is a scrub on AVKit's own timeline on iOS: its `setRate:0`, a user
    /// reason, lasts until its seek completes, which a held seek doesn't —
    /// measured on the Mac's controls; it ends on VLC from the recovery's
    /// watch, once AVPlayer fails the item), an item not healthy (start
    /// seek, recovery, hand-off), the direct path, a finished remux.
    ///
    /// Native jumps: the remux moves its conversion to a far target by
    /// itself, on the position reported to it — the frontier is then at the
    /// target and nothing is measured here. What is left for this watch is a
    /// target the conversion pumps toward (near, its data on disk) too
    /// slowly: the conversion is asked to jump there (`requestJump`), and
    /// only a remux that can't (no usable index, native jumps off) hands the
    /// target to VLC. While a jump is waited on, nothing is measured.
    private func checkFarSeekTarget() {
        guard route == .remux, let remux = remux, let session = remux.session, !remux.isJumpWaiting else {
            farTarget.reset()
            return
        }
        let target = isItemHealthy && playIntent.wantsPlayback ? heldSeek.target : nil
        let frontier = session.progress.mediaSeconds
        guard farTarget.shouldHandOff(target: target, frontierSeconds: frontier,
                                      downloadProgress: keepAliveStreamer?.torrentStatus.totalProgress ?? 1,
                                      remuxFinished: remux.isFinished, now: ProcessInfo.processInfo.systemUptime),
              let held = target else { return }
        let away = "~\(Int((farTarget.estimatedSecondsToTarget ?? 0).rounded())) s away at the download's pace"
        // The remux hears of the target first: a jump goes where the player
        // is reported to be.
        reportPlaybackPositions()
        if remux.requestJump(toPlayerSeconds: held, reason: .requested) {
            print("[Player] seek to \(Int(held)) s held past the remux frontier (\(Int(frontier)) s): \(away) — "
                  + "the conversion jumps there, native playback kept")
            farTarget.reset()
            jumpLabelTarget = held
            showResuming(at: ResumePolicy.clockString(seconds: held), target: held)
            return
        }
        print("[Player] seek to \(Int(held)) s held past the remux frontier (\(Int(frontier)) s): \(away) — VLC there")
        requestFallback(FarTargetWatch.reason, resumeTime: held)
    }

    /// The app went to the background (tvOS: suspended at once — no
    /// background mode —, where the OS may kill it): progress checkpoint, by
    /// the close's rules, `.paused` — `.watching` when playback goes on in
    /// Picture in Picture or over AirPlay. Also while a recovery runs (its
    /// resume time is the position, as at close).
    @objc private func applicationDidEnterBackground() {
        guard !isTornDown, !fallbackRequested, !isHandingOff, player != nil else { return }
        let status = playIntent.backgroundCheckpointStatus(isPictureInPictureActive: isPictureInPictureActive,
                                                           isExternalPlaybackActive: player?.isExternalPlaybackActive ?? false)
        print("[Player] app in the background — progress checkpoint (\(status))")
        saveProgress(status: status == .watching ? .watching : .paused)
    }

    /// Any failure of `item` from here on → starvation recovery when the
    /// download is just slow, else VLC on the same stream. Hard failures
    /// (failed item, undecodable track) are reported at once; the readiness
    /// timeout only catches silent hangs (e.g. an HLS init segment that never
    /// loads leaves the item `.unknown` forever) and is extended — up to
    /// 4 × 30 s — while the torrent is still downloading, so a slow swarm
    /// isn't mistaken for an incompatible file. An item rebuilt by the
    /// starvation recovery (`isReplacement`) gets no readiness timeout here:
    /// the recovery gives it a fixed 30 s itself (no extensions).
    private func installFailureObserver(on item: AVPlayerItem, isReplacement: Bool = false) {
        failureObserver?.invalidate()
        let observer = AVPlayerItemFailureObserver(item: item, readyTimeout: isReplacement ? nil : 30,
                                                   onReport: { [weak self] failure in
            self?.handlePlaybackFailure(failure)
        })
        if !isReplacement {
            observer.shouldExtendReadyTimeout = { [weak self] in
                guard let self = self else { return false }
                return !Self.isPayloadComplete(self.keepAliveStreamer)
            }
        }
        failureObserver = observer
    }

    // MARK: - Download starvation (slow swarm) → stay native

    /// Starvation → the recovery keeps the native player (HDR / Atmos);
    /// anything else (decode / format error, readiness timeout, recovery
    /// exhausted) → VLC. Remux path: a halted remux or an HTTP 404 (a
    /// segment that will never exist) → VLC at once, never a recovery. A
    /// recovery's rebuilt item failing that way hands VLC the target the
    /// user picked during its wait, if any (also before playback started);
    /// a failure during a seek AVPlayer still held recovers — or hands VLC —
    /// that seek's target, as the user's (`HeldSeekWatch`: AVPlayer reset
    /// `currentTime()` to before it). A user who had paused stays paused:
    /// the recovery rebuilds only once play is pressed
    /// (`PlaybackIntentWatch`, `resumesPlayback`).
    private func handlePlaybackFailure(_ failure: AVPlayerItemFailureObserver.Failure) {
        guard !isTornDown, !fallbackRequested else { return }
        // Taken either way; a recovery in progress has its own target.
        var held = heldSeek.take() ?? pendingNavigationTarget()
        if starvation.isRecovering { held = nil }
        // Read before `handle`, which clears it when it ends the recovery.
        let userTarget = (starvation.resumeTimeIsUserTarget ? starvation.resumeTime : nil) ?? held
        if route == .remux {
            if let reason = remux?.failureReason {
                requestFallback(reason, resumeTime: userTarget)
                return
            }
            if failure.isMissingResource {
                print("[Player] HTTP 404 from the remux server — segment gone for good, not starvation")
                requestFallback("Segment indisponible : \(failure.reason)", resumeTime: userTarget)
                return
            }
        }
        let target = recoveryTarget(held: held)
        // The direct path's "already played" test needs where playback
        // stood: never a held target.
        let stood = target.isUserTarget ? recoveryTarget(held: nil).position : target.position
        if let player = player, let plan = starvationPlan(failurePosition: stood),
           starvation.handle(failure, player: player, position: target.position, resumeFraction: target.pendingFraction,
                             resumesPlayback: playIntent.wantsPlayback, positionIsUserTarget: target.isUserTarget,
                             stillDownloading: plan.stillDownloading, isDataReady: plan.isDataReady) {
            // The recovery seeks itself: a pending resume seek is moot.
            cancelStartSeek()
            isSeekingToStart = false
            startSeekTarget = nil
            return
        }
        requestFallback(failure.reason, resumeTime: userTarget)
    }

    /// Whether the data at the playhead can still arrive, and the test for
    /// "enough of it to play again": the remux frontier (VOD: time + 10 s),
    /// or — direct MP4 over the torrent's HTTP server — a position already
    /// played before `failurePosition` (a user rewind during the wait), else
    /// more torrent bytes. nil (→ VLC) when the remux stopped for good
    /// (`failureReason`).
    private func starvationPlan(failurePosition: Double) -> (stillDownloading: Bool, isDataReady: (Double, TimeInterval) -> Bool)? {
        switch route {
        case .remux:
            guard let remux = remux, remux.failureReason == nil else { return nil }
            // The conversion still has something to write: it has not reached
            // the film's end, or a jump left holes it fills when playback
            // goes there.
            let finished = (remux.session?.progress.finished ?? false) && remux.holeIndexes.isEmpty
            return (!finished, { [weak remux] time, _ in
                // Bounded storage: a deleted segment never comes back (the
                // recovery waits for the playhead `limitRecoveringRewind`
                // moved instead of rebuilding there).
                if remux?.isStorageBounded == true, remux?.isAvailable(playerSeconds: time) == false { return false }
                return Self.remuxHasData(remux, after: time)
            })
        case .avPlayer:
            let streamer = keepAliveStreamer
            let atFailure = streamer?.torrentStatus.totalProgress ?? 1
            return (!Self.isPayloadComplete(streamer), { [weak streamer] time, waited in
                // Bounded storage: a position whose data is gone never gets
                // ready (the recovery waits for the one
                // `limitRecoveringRewind` moved it to).
                if let session = BoundedStorageSession.session(for: streamer), session.isBounded,
                   !session.canSeek(to: time, fromPlayerTime: failurePosition) { return false }
                // The whole file on disk (bounded-aware), else more of it.
                if streamer?.isWholeFileOnDisk ?? true { return true }
                let progress = streamer?.torrentStatus.totalProgress ?? 1
                return StarvationPolicy.directDataReady(resumeTime: time, failurePosition: failurePosition, progress: progress,
                                                        progressAtFailure: atFailure, waited: waited)
            })
        case .vlc:
            return nil
        }
    }

    /// Where to recover after the item failed (player timeline, s): the
    /// resume seek's target while it is in flight; when the item failed
    /// before its first `.readyToPlay` with the resume seek still pending,
    /// the 0…1 start position the rebuilt item must resume at (not 0); the
    /// user's seek target AVPlayer still held (`held`, `isUserTarget`:
    /// `currentTime()` now reads where playback was before that seek); else
    /// where playback stood.
    private func recoveryTarget(held: Double?) -> (position: Double, pendingFraction: Float?, isUserTarget: Bool) {
        if isSeekingToStart, let target = startSeekTarget { return (target, nil, false) }
        if awaitingStartSeek, !didStartPlayback, startPosition > 0 {
            // The resume seek wasn't issued (item not ready). Remux: the
            // header gives the length, so the rebuilt item can be
            // pre-positioned there; the precise target follows from the
            // new item's own duration.
            let length = route == .remux ? (remux?.session?.playlistDurationSeconds ?? 0) : 0
            return (length > 0 ? Double(startPosition) * length : 0, startPosition, false)
        }
        if let target = held { return (target, nil, true) }
        if let time = player?.currentTime().seconds, time.isFinite, time > 0 { return (time, nil, false) }
        return (lastKnownTime ?? 0, nil, false)
    }

    private func makeStarvationRecovery() -> PlaybackStarvationRecovery {
        let recovery = PlaybackStarvationRecovery()
        recovery.onWaitingChanged = { [weak self] waiting in
            self?.showStarvationIndicator(waiting)
        }
        // Remux: a waiting recovery stops as soon as the remux halts…
        recovery.abandonReason = { [weak self] in
            guard let self = self, self.route == .remux else { return nil }
            return self.remux?.failureReason
        }
        // …or once the download keeps growing while the remux frontier
        // stays frozen (stall cap: VLC's byte ranges get the torrent to
        // fetch the playhead's pieces, the in-order remux can't).
        recovery.stallProbe = { [weak self] in
            guard let self = self, self.route == .remux, let session = self.remux?.session else { return nil }
            let progress = self.keepAliveStreamer?.torrentStatus.totalProgress ?? 1
            return (session.progress.mediaSeconds, progress)
        }
        // Its far-target pace starts from the download's pace this player's
        // own watch keeps (fed at every tick).
        recovery.farTargetHistory = { [weak self] in self?.farTarget.downloadHistory ?? [] }
        // A user target the in-order conversion can't reach soon: the
        // conversion jumps there when it can (the wait stays native) — VLC
        // there only when it can't.
        recovery.farTargetJump = { [weak self] seconds in
            guard let self = self, self.route == .remux, !self.fallbackRequested, let remux = self.remux else { return false }
            return remux.requestJump(toPlayerSeconds: seconds, reason: .requested)
        }
        recovery.makeItem = { [weak self] in
            guard let self = self, !self.isTornDown, let url = self.playbackURL else { return nil }
            return self.makePlayerItem(url: url)
        }
        recovery.onItemReplaced = { [weak self] item, restoresSelection in
            self?.didReplaceItem(item, restoresSelection: restoresSelection)
        }
        recovery.onResumed = { [weak self] _ in
            self?.resumeAfterStarvation()
        }
        recovery.onNavigatedDuringRebuild = { [weak self] seconds in
            self?.navigateAfterRebuild(to: seconds)
        }
        recovery.onGiveUp = { [weak self] reason in
            self?.recoveryGaveUp(reason)
        }
        // Remux: a user seek during the wait moves the remux lookahead there
        // at once — the dead item requests nothing (direct path: no remux).
        recovery.onRetarget = { [weak self] seconds in
            guard let self = self, !self.fallbackRequested else { return }
            self.remux?.updatePlaybackPositions(played: self.playedPosition.lastPlayedTime, wanted: seconds)
        }
        // The user's play / pause on the dead item during the wait: the play
        // intent follows (`playerRateDidChange` ignores a recovering player).
        recovery.onUserPlaybackChanged = { [weak self] playing in
            self?.playIntent.noteUserPlayback(playing: playing)
        }
        return recovery
    }

    /// The starvation recovery can't continue: VLC at the position it was
    /// recovering (`currentResumeFraction` reads it) — explicitly when the
    /// user picked it during the wait, which also holds before playback ever
    /// started (else the configured start position would win).
    private func recoveryGaveUp(_ reason: String) {
        requestFallback(reason, resumeTime: starvation.resumeTimeIsUserTarget ? starvation.resumeTime : nil)
    }

    /// The rebuilt item is the player's: same observers as the first one
    /// (its readiness budget is the recovery's: 30 s, no extensions).
    private func didReplaceItem(_ item: AVPlayerItem, restoresSelection: Bool) {
        navigation.clear()
        lastItemReplacementAt = ProcessInfo.processInfo.systemUptime
        installFailureObserver(on: item, isReplacement: true)
        noteAttachedItem(item)
        // The user's audio / subtitle choice is re-applied by the recovery;
        // without one, the preferred languages as on a first start.
        if !restoresSelection { PlaybackLanguagePreferences.applyPreferredMediaSelection(to: item) }
        // Direct path: the OpenSubtitles overlay coordinates with the NEW
        // item's own subtitle tracks.
        subtitleController?.bindNativeSubtitles(of: item)
#if os(tvOS)
        installUpNextIfNeeded(for: item)
#endif
        logResolvedAudio(after: item)
    }

    private func resumeAfterStarvation() {
        guard !isTornDown, !fallbackRequested, let player = player else { return }
        guard hasAppeared, !resumeChoicePending else { return }   // viewDidAppear starts it
        didStartPlayback = true
        player.play()
    }

    private func showStarvationIndicator(_ waiting: Bool) {
        if waiting, starvation.isRebuildingStuckItem {
            // Every byte is local: no "download slower than playback" text.
            engineLine = "\(nativeEngineLine) — lecture bloquée, nouvel élément"
            loadingIndicator.startAnimating()
            bufferingLabel.isHidden = true
        } else if waiting, isResumingNatively || remux?.isJumpWaiting == true {
            // The wait is a jump's (the conversion was moved to that
            // position: the torrent turns there, the first segments come),
            // not a download slower than the film: « Reprise à … ».
            engineLine = "\(nativeEngineLine) — reprise à la position demandée (saut de la conversion)"
            if !isResumingNatively {
                let time = starvation.resumeTime ?? jumpLabelTarget ?? 0
                jumpLabelTarget = time
                showResuming(at: ResumePolicy.clockString(seconds: time), target: time)
            }
            loadingIndicator.startAnimating()
            bufferingLabel.isHidden = true
        } else if waiting {
            engineLine = "\(nativeEngineLine) — attente des données (téléchargement plus lent que la lecture)"
            loadingIndicator.startAnimating()
            // (Never both texts: a jump's label that outlived its jump goes.)
            resumingLabel.isHidden = true
            jumpLabelTarget = nil
            bufferingLabel.isHidden = false
        } else {
            engineLine = nativeEngineLine
            if ResumePolicy.hidesJumpLabelOnPause(isWaitingForPlay: starvation.isRecovering && starvation.isWaitingForPlay,
                                                  isResumingNatively: isResumingNatively,
                                                  isLabelShown: !resumingLabel.isHidden) {
                // Paused by the user during a jump's wait: shown as a pause (AVKit's bar), not
                // as a spinner with « Reprise à … — 100 % » that says it still loads. Play
                // brings the wait's label back (`showStarvationIndicator(true)`).
                print("[Player] jump wait paused by the user — « Reprise à … » hidden until play is pressed")
                hideResuming()
            }
            if !isSeekingToStart, resumingLabel.isHidden { loadingIndicator.stopAnimating() }
            bufferingLabel.isHidden = true
        }
    }

    /// 0…1 position: while a starvation recovery runs, the position it
    /// recovers (the user's new target after a seek during the wait); else
    /// the player's; else — once a recovery gave up — the position it was
    /// recovering; else the last position read from a ready item.
    private func knownPlaybackFraction() -> Float? {
        if starvation.isRecovering, let time = starvation.resumeTime { return fraction(ofPlayerTime: time) }
        if let fraction = AVPlayerItemFailureObserver.playbackFraction(of: player) { return fraction }
        guard let time = starvation.abandonedTime ?? lastKnownTime else { return nil }
        return fraction(ofPlayerTime: time)
    }

    /// 0…1 share of the movie at `time` (player timeline): the ready item's
    /// duration, the last one seen, else (remux) the header's length.
    private func fraction(ofPlayerTime time: Double) -> Float? {
        var duration = player?.currentItem?.duration.seconds ?? .nan
        if !duration.isFinite || duration <= 0 { duration = lastKnownDuration ?? .nan }
        if !duration.isFinite || duration <= 0, let length = remux?.session?.playlistDurationSeconds, length > 0 {
            duration = length
        }
        return ResumePolicy.fraction(time: time, duration: duration)
    }

    /// Stats timer (1 Hz): position / duration of a ready item — while a
    /// starvation recovery runs, the position it recovers (it follows a
    /// user seek during the wait).
    private func noteKnownPosition() {
        if starvation.isRecovering {
            if let time = starvation.resumeTime, time.isFinite, time >= 0 { lastKnownTime = time }
            return
        }
        guard let item = player?.currentItem, item.status == .readyToPlay else { return }
        let time = item.currentTime().seconds
        if time.isFinite, time >= 0 { lastKnownTime = time }
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 { lastKnownDuration = duration }
    }

    /// Stats timer (1 Hz): samples the last position playback actually
    /// reached — playing through it, item ready, not recovering
    /// (`PlayedPositionTracker`). A seek target AVPlayer still waits for
    /// never counts.
    private func notePlayedPosition() {
        guard let player = player else { return }
        playedPosition.note(time: player.currentTime().seconds, clock: ProcessInfo.processInfo.systemUptime,
                            isPlaying: player.timeControlStatus == .playing,
                            isItemReady: player.currentItem?.status == .readyToPlay,
                            isRecovering: starvation.isRecovering)
    }

    /// Seek to `startPosition` once the item is ready and its duration known,
    /// then start playing. Direct MP4: AVPlayer reads over HTTP byte ranges
    /// (the torrent fetches those pieces first). Remux: with the payload
    /// fully on disk, the requested segment is held by the server's
    /// long-poll while the remux pumps ahead to it; a native resume of a
    /// payload still downloading (`beginNativeResume`): held the same way
    /// until the conversion, moved there, has written it.
    private func prepareStartPosition(for item: AVPlayerItem, direct: Bool) {
        guard startPosition > 0 else { return }
        awaitingStartSeek = true
        let handler: (AVPlayerItem) -> Void = { [weak self] observed in
            DispatchQueue.main.async { self?.applyStartPosition(to: observed, direct: direct) }
        }
        startObservations = [
            item.observe(\.status, options: [.initial, .new]) { observed, _ in handler(observed) },
            item.observe(\.duration, options: [.initial, .new]) { observed, _ in handler(observed) },
        ]
    }

    private var didScheduleStartSeekGiveUp = false

    private func applyStartPosition(to item: AVPlayerItem, direct: Bool) {
        guard awaitingStartSeek, !isTornDown, let player = player, player.currentItem === item,
              item.status == .readyToPlay else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else {
            // Ready but no usable duration (e.g. a Matroska header without
            // Duration → EVENT playlist): never let the resume block
            // playback — give it a few seconds, then start from the
            // beginning (the saved point is kept, see `saveProgress`).
            if !didScheduleStartSeekGiveUp {
                didScheduleStartSeekGiveUp = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self = self, self.awaitingStartSeek else { return }
                    print("[Player] resume skipped — duration unknown")
                    self.cancelStartSeek()
                    self.startPlaybackIfPossible()
                }
            }
            return
        }
        cancelStartSeek()
        // A native resume seeks where the remux sent its conversion (the same
        // share of the playlists' length: the segment the jump writes first).
        let target = (isResumingNatively ? remux?.resumeTargetSeconds : nil) ?? Double(startPosition) * duration
        if isResumingNatively {
            print("[Resume] seek issued to \(String(format: "%.1f", target)) s")
        } else if !direct {
            let remuxed = remux?.session?.progress.mediaSeconds ?? 0
            print("[Player] remux at \(Int(remuxed)) s, payload on disk — pumping ahead to the resume point")
        }
        print("[Player] resuming at \(Int(target)) s (\(Int(startPosition * 100)) %)")
        isSeekingToStart = true
        startSeekTarget = target
        loadingIndicator.startAnimating()
        // A native resume never starts past the saved position (its item was
        // put at a keyframe before it, `attachPlayer`: the nearest one could
        // be the next); the other starts keep AVPlayer's default tolerance.
        let after: CMTime = isResumingNatively ? .zero : .positiveInfinity
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .positiveInfinity,
                    toleranceAfter: after) { [weak self] _ in
            DispatchQueue.main.async {
                // Superseded when a starvation recovery took over the item.
                guard let self = self, self.isSeekingToStart, self.player?.currentItem === item else { return }
                self.isSeekingToStart = false
                self.startSeekTarget = nil
                // (A native resume's spinner, label and cover go with the
                // first picture that plays: `finishNativeResume`.)
                if !self.isResumingNatively { self.loadingIndicator.stopAnimating() }
                self.startPlaybackIfPossible()
            }
        }
        // The remux hears of the target now (`wantedPosition()`: the start
        // seek's target), not at the next tick.
        reportPlaybackPositions()
    }

    private var isSeekingToStart = false

    private func cancelStartSeek() {
        awaitingStartSeek = false
        startObservations.forEach { $0.invalidate() }
        startObservations = []
    }

    /// Starts playback once: the controller is on screen, the player exists,
    /// no question is pending and the resume seek (if any) is done.
    private func startPlaybackIfPossible() {
        guard hasAppeared, !didStartPlayback, !awaitingStartSeek, !isSeekingToStart, !resumeChoicePending,
              !fallbackRequested, !isTornDown, !starvation.isRecovering, let player = player else { return }
        didStartPlayback = true
        player.play()
    }

    /// Records the furthest position reached (stats timer, 1 Hz).
    private func noteHighWater() {
        guard didStartPlayback, !isSeekingToStart, let fraction = knownPlaybackFraction() else { return }
        highWaterFraction = max(highWaterFraction, fraction)
    }

    /// Poll the item until it's readyToPlay, then log what AVPlayer resolved
    /// for audio: the media-selection options (does it see a JOC rendition?)
    /// and the selected track's fourCC + channel count. Purely diagnostic.
    private func logResolvedAudio(after item: AVPlayerItem, attempt: Int = 0) {
        guard attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, !self.isTornDown, self.player?.currentItem === item else { return }
            guard item.status == .readyToPlay else {
                self.logResolvedAudio(after: item, attempt: attempt + 1); return
            }
            Task { @MainActor in
                if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
                    print("[Player] audio media-selection options: \(group.options.count)")
                    for option in group.options {
                        print("[Player]   option: \(option.displayName) — \(option.extendedLanguageTag ?? "und")")
                    }
                    if let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
                        print("[Player] selected audio option: \(selected.displayName)")
                    }
                } else {
                    print("[Player] no audible media-selection group (muxed audio / single track)")
                }
                await self.logResolvedAudioTracks(of: item, retry: true)
                // Output-side proof of Atmos on iOS: whether the current audio
                // route is actually rendering Spatial Audio (AirPods / built-in
                // speakers). `true` = the DD+/Atmos is being spatialized right now.
                for output in AVAudioSession.sharedInstance().currentRoute.outputs {
                    print("[Player] output '\(output.portName)' [\(output.portType.rawValue)] spatialAudioEnabled=\(output.isSpatialAudioEnabled)")
                }
            }
        }
    }

    /// The resolved audio track lines; none yet (the item's tracks may not
    /// list the audio before its first audio segment is parsed): said so,
    /// and one more look 1 s later — on the same item, not torn down.
    @MainActor
    private func logResolvedAudioTracks(of item: AVPlayerItem, retry: Bool) async {
        let audio = await PlayerTrackSummary.load(from: item).filter { $0.mediaType == .audio }
        for track in audio {
            print("[Player] resolved audio track: '\(track.fourCC)' \(track.channels)ch")
        }
        guard audio.isEmpty else { return }
        print("[Player] audio track not resolved yet (item.tracks \(item.tracks.count))"
              + (retry ? " — one more look in 1 s" : " — not after 1 s either"))
        guard retry else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, !self.isTornDown, self.player?.currentItem === item else { return }
            Task { @MainActor in await self.logResolvedAudioTracks(of: item, retry: false) }
        }
    }

    // MARK: - Download slower than the release (BandwidthDeficitMonitor)

    /// The stream's deficit watch hears from this player once a second; on
    /// tvOS the offer shows over the video, its buttons as AVKit's
    /// contextual actions (iOS: the SwiftUI cover shows it).
    private func attachDeficitMonitor() {
        guard let monitor = streamContext?.deficit else { return }
        monitor.attach(self, switchTo: { [weak self] torrent, fraction in
            self?.leave(for: torrent, at: fraction)
        }, state: { [weak self] in
            self?.deficitPlaybackState()
        })
#if os(tvOS)
        deficitSubscription = monitor.$offer.receive(on: DispatchQueue.main).sink { [weak self] offer in
            self?.showDeficitOffer(offer)
        }
#endif
    }

    private func detachDeficitMonitor() {
        streamContext?.deficit.detach(self)
#if os(tvOS)
        deficitSubscription = nil
        showDeficitOffer(nil)
#endif
    }

    /// The native player as the deficit watch sees it (nil once VLC took over).
    private func deficitPlaybackState() -> BandwidthDeficitMonitor.PlaybackState? {
        guard !isTornDown, !fallbackRequested, let player = player else { return nil }
        let recovering = starvation.isRecovering
        let time = recovering ? starvation.resumeTime : player.currentTime().seconds
        var duration = player.currentItem?.duration.seconds ?? .nan
        if !duration.isFinite || duration <= 0 { duration = lastKnownDuration ?? .nan }
        if !duration.isFinite || duration <= 0, let length = remux?.session?.playlistDurationSeconds, length > 0 {
            duration = length
        }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && playIntent.wantsPlayback
        // A wait for a jump of the conversion (a resume, a far seek) is not a
        // download slower than the film: the torrent is turning to that part.
        let jumping = isResumingNatively || remux?.isJumpWaiting == true
        return BandwidthDeficitMonitor.PlaybackState(playhead: time, duration: duration.isFinite ? duration : nil,
                                                     hasStarted: didStartPlayback && playedPosition.lastPlayedTime != nil,
                                                     wantsPlayback: playIntent.wantsPlayback,
                                                     isStalled: !jumping && ((recovering && !starvation.isRebuildingStuckItem) || waiting))
    }

    /// « Lighter version »: this player closes (progress saved, stream
    /// cancelled), then the platform plays `torrent` from `fraction` — the
    /// iOS cover's owner closes it itself.
    private func leave(for torrent: Torrent, at fraction: Float) {
        guard !isTornDown, let context = streamContext else { return }
        print("[Player] leaving for a lighter release (\(torrent.quality ?? "?")) at \(Int(fraction * 100)) %")
        if onCloseRequest != nil {
            context.onSwitch?(torrent, fraction)
            return
        }
        dismissPlayer(animated: true) { [weak self] in
            self?.tearDown()
            context.onSwitch?(torrent, fraction)
        }
    }

#if os(tvOS)
    /// The offer as a toast at the top of the video, « Lighter version »
    /// focused (the video plays on under it; Menu = « Continue »). Not
    /// AVKit's contextual actions: AVKit hides them while the player waits
    /// for data — when this offer matters most. Not over another
    /// presentation (resume question, Up Next): the offer then times out
    /// and may come back later.
    private func showDeficitOffer(_ offer: BandwidthDeficitMonitor.Offer?) {
        if let toast = deficitToast, toast.offerID != offer?.id {
            deficitToast = nil
            if toast.presentingViewController != nil, !toast.isBeingDismissed { toast.dismiss(animated: true) }
        }
        guard let offer = offer, !isTornDown, !fallbackRequested, deficitToast == nil, presentedViewController == nil,
              hasAppeared, let monitor = streamContext?.deficit else { return }
        let toast = BandwidthDeficitToastController(offer: offer,
                                                    onLighter: { [weak monitor] in monitor?.acceptLighter() },
                                                    onContinue: { [weak monitor] in monitor?.continueWatching() },
                                                    onPlayPause: { [weak self] in self?.togglePlaybackUnderToast() })
        deficitToast = toast
        present(toast, animated: true)
    }

    /// Play/Pause pressed while the offer's toast holds the remote: the
    /// player toggles as it would (the intent follows: through the rate
    /// observer, or directly while a starvation recovery waits).
    private func togglePlaybackUnderToast() {
        guard let player = player, !isTornDown, !fallbackRequested else { return }
        let playing = playIntent.wantsPlayback
        print("[Player] play/pause under the deficit toast: \(playing ? "pause" : "play")")
        if playing { player.pause() } else { player.play() }
        if starvation.isRecovering { playIntent.noteUserPlayback(playing: !playing) }
    }
#endif

    // MARK: - Fallback

    /// - Parameter resumeTime: where VLC continues (player timeline, s);
    ///   nil = the current position (`currentResumeFraction`).
    private func requestFallback(_ reason: String, resumeTime: Double? = nil) {
        guard !fallbackRequested, !isTornDown else { return }
        // Bounded storage: VLC reads the torrent's file — never where it
        // was deleted (it would get HTTP 410 and stop).
        var resumeTime = resumeTime
        switch boundedHandOff(resumeTime: resumeTime) {
        case .asked: break
        case .at(let time): resumeTime = time
        case .end:
            endPlaybackForBoundedStorage(reason)
            return
        }
        fallbackRequested = true
        resumeChoicePending = false
        pendingPlaylistURL = nil
        isResumingNatively = false
        var resume = currentResumeFraction()
        if let time = resumeTime, let fraction = fraction(ofPlayerTime: time) {
            resume = ResumePolicy.handOffFraction(reached: fraction)
        }
        // VLC asks « Reprendre / Depuis le début » unless the user chose
        // « Reprendre » here or was already watching.
        let decided = ResumePolicy.handOffResumeDecided(userChoseResume: userChoseResume,
                                                        playbackStarted: didStartPlayback)
        print("[Player] native playback unavailable (\(reason)) — handing over to VLC at \(Int(resume * 100)) %"
              + (decided ? "" : " (VLC asks whether to resume)"))
        stopNativePlayback()
        loadingIndicator.stopAnimating()
        engineLine = "bascule vers VLC — \(reason)"
        if hasAppeared {
            deliverFallback(reason: reason, resume: resume, decided: decided)
        } else {
            // The owner swaps view controllers: wait until we're on screen.
            // (Closed before that → tearDown still cancels the stream.)
            pendingFallback = (reason, resume, decided)
        }
    }

    private func deliverFallback(reason: String, resume: Float, decided: Bool) {
        // The owner dismisses / replaces this controller: never with our
        // resume question still on screen.
        if let alert = resumeAlert, alert.presentingViewController != nil {
            resumeAlert = nil
            alert.dismiss(animated: false) { [weak self] in
                self?.deliverFallback(reason: reason, resume: resume, decided: decided)
            }
            return
        }
        resumeAlert = nil
        guard !isTornDown else { return }
        guard let onFallback = onFallback else {
            // No VLC handler wired: nothing can play this — close.
            print("[Player] no fallback handler — closing the player")
            closePlayer()
            return
        }
        // The native part is saved now, at the hand-off position (the rules
        // of the close, still watching): a VLC crash, kill or immediate close
        // must not lose it — the teardown below saves nothing once handing
        // off. (tvOS: the VLC player saves its own progress later.)
        saveProgress(status: .watching, fraction: resume)
        // From here the torrent stream belongs to the VLC player.
        isHandingOff = true
        onFallback(reason, resume, decided)
    }

    /// Position to resume at in VLC: the position playback reached once it
    /// started (or the one a starvation recovery was resuming at), clamped
    /// to `ResumePolicy.handOffMaxFraction` — a failure in the end credits
    /// continues there, it doesn't restart the movie — else the configured
    /// start position.
    private func currentResumeFraction() -> Float {
        if didStartPlayback, let fraction = knownPlaybackFraction(), fraction > 0.001 {
            return ResumePolicy.handOffFraction(reached: fraction)
        }
        return startPosition
    }

    /// Stops AVPlayer, the remux and the observers — never the torrent stream.
    private func stopNativePlayback() {
        detachDeficitMonitor()
        starvation.cancel()
        failureObserver?.invalidate()
        failureObserver = nil
        firstFrameWatch?.invalidate()
        firstFrameWatch = nil
        cancelStartSeek()
#if os(tvOS)
        upNextObservation?.invalidate()
        upNextObservation = nil
        player?.currentItem?.nextContentProposal = nil
#endif
        subtitleSubscription = nil
        subtitleController?.detach()
        playerObservers.forEach { NotificationCenter.default.removeObserver($0) }
        playerObservers = []
        player?.pause()
        // Release the HTTP connection to the torrent's local server.
        player?.replaceCurrentItem(with: nil)
        remux?.stop()
        boundedRewindCheck?.cancel()
        BoundedStorageSession.session(for: keepAliveStreamer)?.detachHTTPPlayer(self)
        // Nothing resumes natively any more.
        isResumingNatively = false
        jumpLabelTarget = nil
        resumingLabel.isHidden = true
        resumeCover.isHidden = true
    }

#if DEBUG
    /// `-PTDebugSeek` (BoundedStorageDebugHooks): a seek like a user's.
    @objc private func debugScriptSeek(_ note: Notification) {
        guard !isTornDown, !fallbackRequested, let seconds = note.userInfo?["seconds"] as? Double, let player = player else { return }
        let now = player.currentTime().seconds
        print("[BoundedDebug] AVPlayer seek \(Int(now)) → \(Int(seconds)) s")
        // Limited like a user's seek (bounded storage).
        if let reference = playedPosition.lastPlayedTime ?? (now.isFinite ? now : nil),
           let landing = BoundedStorageUX.limitedRewindTarget(seconds, from: reference, session: boundedStorage) {
            limitRewind(target: seconds, from: reference, landing: landing)
            return
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// `-PTDebugPause` (BoundedStorageDebugHooks).
    @objc private func debugScriptPlayback(_ note: Notification) {
        guard !isTornDown, !fallbackRequested, let playing = note.userInfo?["playing"] as? Bool, let player = player else { return }
        if playing { player.play() } else { player.pause() }
    }
#endif

    /// Final teardown (player closed or removed). Cancels the torrent stream
    /// unless it is being handed over to VLC. Idempotent.
    func tearDown() {
        guard !isTornDown else { return }
#if os(tvOS)
        // The user left the player: nothing of the next episode starts
        // (not a close for the next episode, not a hand-off to VLC — the
        // session goes on there).
        if !isClosingForNextEpisode && !isHandingOff { upNextSession?.playerClosed() }
        upNextCardSubscription = nil
#endif
        if !isHandingOff { saveProgress(status: .finished) }
        let closedAt = String(format: "%.1f", player?.currentTime().seconds ?? .nan)
        isTornDown = true
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        resumeChoicePending = false
        pendingPlaylistURL = nil
        statsTimer?.invalidate()
        statsTimer = nil
        stopNativePlayback()
        pendingFallback = nil
        streamContext = nil
        if !isHandingOff {
            // tvOS deletes the stream's partial right away, as the VLC player
            // does (the app sandbox is small); iOS keeps it until the next
            // stream's purge. A completed download is never deleted.
#if os(tvOS)
            let wipe = !(keepAliveStreamer is PTTorrentDownload)
#else
            let wipe = false
#endif
            print("[Player] closed at \(closedAt) s — "
                  + (keepAliveStreamer == nil ? "no stream to cancel" : "stream cancelled, data deleted=\(wipe)")
                  + (isClosingForNextEpisodeLog ? " (the next episode starts)" : ""))
            keepAliveStreamer?.cancelStreamingAndDeleteData(wipe)
        } else {
            print("[Player] closed at \(closedAt) s — handed off to VLC: the stream is not cancelled, it plays on there")
        }
        keepAliveStreamer = nil
    }

    /// Watched progress (local + Trakt scrobble), same semantics as the VLC
    /// player, so "resume" works whichever engine played the title — except
    /// that the saved resume point is never replaced by a smaller fraction
    /// unless the user restarted on purpose or watched past it. Only once
    /// native playback has started. At close (`.finished`), at the hand-off
    /// to VLC (`.watching`), and as a checkpoint when the user pauses or the
    /// app goes to the background (`.paused` / `.watching`). `fraction`: the
    /// position to save (the VLC hand-off's); nil = the current one.
    private func saveProgress(status: Trakt.WatchedStatus, fraction explicitFraction: Float? = nil) {
        // NaN-safe: an EVENT playlist (no duration until ENDLIST) has no
        // fraction — nothing is saved then, the stored point stays.
        guard didStartPlayback, let media = media,
              let fraction = explicitFraction ?? knownPlaybackFraction(), fraction.isFinite else { return }
        noteHighWater()
        guard let value = ResumePolicy.progressToSave(current: fraction, resumePoint: resumePoint,
                                                      highWater: highWaterFraction,
                                                      userRestarted: userChoseStartOver) else {
            print("[Player] progress \(Int(fraction * 100)) % not saved — keeps the resume point at \(Int(resumePoint * 100)) %")
            return
        }
        // With the titles and the length: the Continue Watching card.
        PlaybackRecorder.save(value, of: media, duration: lastKnownDuration, status: status, profileID: profileID)
    }

    /// From the 1 Hz tick, while playing: the position every 30 s
    /// (`PlaybackCheckpoint`), so a crash, a kill or a power cut loses half a
    /// minute of an uninterrupted session, not all of it.
    private func checkpointProgressIfDue() {
        guard player?.timeControlStatus == .playing, progressCheckpoint.isDue() else { return }
        saveProgress(status: .watching)
    }

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // A kill while suspended (or a crash later) keeps what was watched.
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(userPickedAudio(_:)),
                                               name: MediaSelectionLearner.userPickedAudio, object: nil)
#if DEBUG
        // BoundedStorageDebugHooks' scripted seeks and pauses.
        NotificationCenter.default.addObserver(self, selector: #selector(debugScriptSeek(_:)), name: .ptDebugSeek, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(debugScriptPlayback(_:)), name: .ptDebugPlayback, object: nil)
#endif
        statsLabel.font = .monospacedSystemFont(ofSize: UIDevice.current.userInterfaceIdiom == .tv ? 23 : 12, weight: .medium)
        statsLabel.textColor = .white
        statsLabel.numberOfLines = 0
        statsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        if let overlay = contentOverlayView {
            overlay.addSubview(statsLabel)
            NSLayoutConstraint.activate([
                statsLabel.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 20),
                statsLabel.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                statsLabel.trailingAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            ])
        }
        installSubtitleOverlayIfNeeded()
        if let overlay = contentOverlayView {
            // Under everything else in the overlay: black over the video
            // during a native resume.
            resumeCover.backgroundColor = .black
            resumeCover.isUserInteractionEnabled = false
            resumeCover.isHidden = !isResumingNatively
            resumeCover.translatesAutoresizingMaskIntoConstraints = false
            overlay.insertSubview(resumeCover, at: 0)
            NSLayoutConstraint.activate([
                resumeCover.topAnchor.constraint(equalTo: overlay.topAnchor),
                resumeCover.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                resumeCover.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                resumeCover.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            ])
            // Above the cover, under the spinner and the labels.
            statusCapsule.backgroundColor = StatusCapsuleLabel.capsuleColor
            statusCapsule.layer.cornerRadius = StatusCapsuleLabel.cornerRadius
            statusCapsule.layer.cornerCurve = .continuous
            statusCapsule.isUserInteractionEnabled = false
            statusCapsule.isHidden = true
            statusCapsule.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(statusCapsule)
            loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
            loadingIndicator.color = .white
            loadingIndicator.hidesWhenStopped = true
            overlay.addSubview(loadingIndicator)
            // Download starvation: say why the picture is frozen.
            bufferingLabel.text = "Buffering…".localized + "\n" + "The download is slower than playback".localized
            bufferingLabel.numberOfLines = 2
            bufferingLabel.textAlignment = .center
            bufferingLabel.textColor = .white
            bufferingLabel.font = StatusCapsuleLabel.textFont
            bufferingLabel.adjustsFontForContentSizeCategory = true
            bufferingLabel.isHidden = true
            bufferingLabel.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(bufferingLabel)
            // A jump of the conversion: where playback resumes (its text is
            // set when it shows: `showResuming`). Same place, never both.
            resumingLabel.numberOfLines = 1
            // The longest French text (« Reprise à 1:28:20 — 100 % · 1 000 octets/s ») fits Apple TV's
            // width; on a 375-point iPhone in portrait it may not: smaller rather than cut with « … ».
            resumingLabel.adjustsFontSizeToFitWidth = true
            resumingLabel.minimumScaleFactor = 0.7
            resumingLabel.textAlignment = .center
            resumingLabel.textColor = .white
            resumingLabel.font = StatusCapsuleLabel.textFont
            resumingLabel.adjustsFontForContentSizeCategory = true
            resumingLabel.isHidden = resumingLabel.text?.isEmpty ?? true
            resumingLabel.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(resumingLabel)
            let padding = StatusCapsuleLabel.padding
            NSLayoutConstraint.activate([
                statusCapsule.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                statusCapsule.topAnchor.constraint(equalTo: loadingIndicator.topAnchor, constant: -padding),
                statusCapsule.widthAnchor.constraint(greaterThanOrEqualTo: loadingIndicator.widthAnchor, constant: 2 * padding),
            ])
            // As small as its contents allow (and a size while hidden).
            let hugWidth = statusCapsule.widthAnchor.constraint(equalToConstant: 0)
            let hugHeight = statusCapsule.heightAnchor.constraint(equalToConstant: 0)
            hugWidth.priority = .fittingSizeLevel
            hugHeight.priority = .fittingSizeLevel
            NSLayoutConstraint.activate([hugWidth, hugHeight])
            bufferingLabel.onVisibilityChange = { [weak self] in self?.layoutStatusCapsule() }
            resumingLabel.onVisibilityChange = { [weak self] in self?.layoutStatusCapsule() }
            NSLayoutConstraint.activate([
                loadingIndicator.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                loadingIndicator.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                bufferingLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                bufferingLabel.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: 16),
                bufferingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                bufferingLabel.trailingAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -20),
                resumingLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                resumingLabel.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: 16),
                resumingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                resumingLabel.trailingAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            ])
            if player == nil && !fallbackRequested && !isTornDown { loadingIndicator.startAnimating() }
            if !resumingLabel.isHidden { loadingIndicator.startAnimating() }
            if starvation.isRecovering { showStarvationIndicator(true) }
            layoutStatusCapsule()
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.statsTick()
        }
        refreshStats()
        // Visible briefly at start (proof-of-Atmos), then out of the way.
        // Toggle with "n" (Mac/iPad keyboard) or up-click (Siri Remote).
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.statsLabel.isHidden = true
        }
    }

    /// 1 Hz: stats, known / played position, a held seek target (and the
    /// far-target jump or hand-off), high-water mark, the positions reported
    /// to the remux, the end of a jump's « Reprise à … », the stuck-playback
    /// safety net, the one-time replacement of an item started on live EVENT
    /// playlists.
    private func statsTick() {
        noteKnownPosition()
        notePlayedPosition()
        noteHeldSeek(isJump: false)
        logPendingNavigation()
        checkFarSeekTarget()
        refreshStats()
        noteHighWater()
        checkpointProgressIfDue()
        reportPlaybackPositions()
        checkNativeResumeCover()
        checkJumpLabel()
        refreshResumingText()
        checkStuckPlayback()
        checkDirectStall()
        checkBoundedReverseScan()
        rebuildLiveBornItemIfEnded()
        rebuildForLateSubtitlesIfDue()
        rebuildForRetimedSubtitlesIfDue()
#if os(tvOS)
        upNextTick()
#endif
#if DEBUG
        debugPickAudioIfDue()
        debugSelectExternalSubtitleIfDue()
#endif
    }

#if DEBUG
    /// `-PTDebugPickAudio "<language>@<s>"`: once the player's time reaches
    /// <s>, the first audio option in <language> is selected the way AVKit's
    /// Audio menu does it (`AVPlayerItem.select`, not the app's own
    /// selection), so the menu pick's handling can be timed in a test rig.
    private func debugPickAudioIfDue() {
        guard !debugPickedAudio, let spec = UserDefaults.standard.string(forKey: "PTDebugPickAudio"),
              let at = spec.split(separator: "@").last.flatMap({ Double($0) }),
              let language = spec.split(separator: "@").first.map(String.init),
              let player = player, let item = player.currentItem, player.currentTime().seconds >= at else { return }
        debugPickedAudio = true
        Task { @MainActor in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  let option = group.options.first(where: { ($0.extendedLanguageTag ?? "").hasPrefix(language) }) else {
                print("[DebugPickAudio] no '\(language)' option"); return
            }
            print("[DebugPickAudio] selecting '\(option.displayName)' at \(String(format: "%.3f", player.currentTime().seconds)) s")
            item.select(option, in: group)
        }
    }
    private var debugPickedAudio = false
#endif

    /// Bounded storage, 1 Hz: a reverse scan (a held rewind) stops at the
    /// earliest point still available, with the message, and plays on from
    /// there (`BoundedStorageUX.reverseScanLimit`).
    private func checkBoundedReverseScan() {
        guard let player = player, isItemHealthy else { return }
        let now = player.currentTime().seconds
        guard let landing = BoundedStorageUX.reverseScanLimit(time: now, rate: player.rate,
                                                              playedReference: playedPosition.lastPlayedTime,
                                                              session: boundedStorage) else { return }
        player.rate = BoundedStorageUX.resumeRate(after: player)
        limitRewind(target: now, from: playedPosition.lastPlayedTime ?? now, landing: landing)
    }

    /// Bounded storage, direct path, 1 Hz: AVPlayer waiting for 8 s at the
    /// same time while the data ahead of the server's read position is on
    /// disk is not waiting for the download (macOS AVPlayer's loader stops
    /// requesting after a far seek's back-fill reached deleted data, part-3
    /// coverage md2–md5; not seen with tvOS AVPlayer, which does not
    /// back-fill — a safety net here). The item is rebuilt at the playhead
    /// (`BoundedDirectStallWatch`). Full mode: never.
    private func checkDirectStall() {
        guard let player = player else { return }
        let isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            && player.currentItem?.status == .readyToPlay
        let eligible = isWaiting && route == .avPlayer && isItemHealthy && hasAppeared
            && UIApplication.shared.applicationState == .active
            && boundedStorage?.isBounded == true && boundedStorage?.hasDataAheadOfReader() == true
        guard let time = directStall.note(time: player.currentTime().seconds, clock: ProcessInfo.processInfo.systemUptime,
                                          isWaiting: isWaiting, isEligible: eligible) else { return }
        print("[Player] bounded direct route: AVPlayer waiting at \(String(format: "%.1f", time)) s for "
              + "\(Int(BoundedDirectStallWatch.stallSeconds)) s with the data on disk → rebuilding the item")
        starvation.rebuildNow(player: player, at: time, reason: BoundedDirectStallWatch.reason)
    }

    /// Remux path, every tick — also while a starvation recovery runs — and
    /// at once when the playhead jumps (a time jump of the current item, the
    /// start seek issued): the last position playback reached (`played`) and
    /// where the player needs data now (`wanted`). The remux runs its
    /// lookahead from those and deletes only segments neither needs, so its
    /// copy on disk stays bounded during a pump-ahead to a resume point or a
    /// far seek too (`RemuxPlayback.updatePlaybackPositions`).
    private func reportPlaybackPositions() {
        guard route == .remux, let remux = remux, !fallbackRequested, !isTornDown else { return }
        remux.updatePlaybackPositions(played: playedPosition.lastPlayedTime, wanted: wantedPosition())
    }

    /// Where the player needs data now (player timeline, s): while a
    /// starvation recovery runs, the position it recovers (the user's target
    /// after a seek during the wait); during the start seek, its target
    /// (right after `seek(to:)` is issued `currentTime()` still reads the old
    /// time — measured: 0.0 —, AVPlayer moves it a few ms later); before the
    /// start seek of a native resume, the resume point; else
    /// `currentTime()` — the playhead, or a pending seek target. nil while
    /// unknown.
    private func wantedPosition() -> Double? {
        let time: Double?
        if starvation.isRecovering {
            time = starvation.resumeTime
        } else if isSeekingToStart, let target = startSeekTarget {
            time = target
        } else if isResumingNatively, player == nil || awaitingStartSeek, let target = remux?.resumeTargetSeconds {
            // A native resume before its seek is issued: the item is not
            // there yet, or still loads at 0:00 — the remux must not be told
            // the player needs 0:00 (its conversion would go back there).
            time = target
        } else {
            // A user navigation the playhead does not show yet: its target.
            time = navigation.wanted(current: player?.currentTime().seconds, played: playedPosition.lastPlayedTime,
                                     clock: ProcessInfo.processInfo.systemUptime)
        }
        guard let time = time, time.isFinite, time >= 0 else { return nil }
        return time
    }

    /// END safety net (1 Hz, remux path). Once the remux has finished, every
    /// byte is local: an item frozen while the user wants it playing (ready,
    /// rate ≠ 0, time unmoved for `StuckPlaybackWatch.stuckSeconds`) won't
    /// recover by waiting, and AVPlayer posts no failure for it. In the end
    /// zone (last second / last segment) that is the natural end: paused,
    /// as AVPlayer does at an item's end — progress is saved at the close
    /// as after one. Elsewhere the item is rebuilt in place (at the stuck
    /// position, i.e. a pending seek target too), at most twice for one
    /// position, then VLC there. Never during a starvation recovery, in the
    /// background, over AirPlay or in Picture in Picture.
    ///
    /// The same holds before the remux has finished once playback has run
    /// and the media to play at the frozen position is on disk
    /// (`RemuxPlayback.hasMedia`: 10 s of it): an item whose request for a
    /// segment was held too long — a jump's first segments, a download about
    /// as fast as the film — has dropped its video variant on tvOS, goes on
    /// loading audio and never fails (`ResumePolicy.jumpNeedsNewItem`). It
    /// is rebuilt the same way. (Not before playback ever ran: a start waits
    /// for its first segments, and for the TV's switch to the film's
    /// dynamic range, without being stuck.)
    private func checkStuckPlayback() {
        guard let player = player else { return }
        let remux = route == .remux ? self.remux : nil
        // A navigation still pending is where the player wants to be, not
        // the old time a held seek may leave in `currentTime()` (a stuck
        // item is rebuilt THERE, and never for media at the old time).
        let time = (route == .remux ? pendingNavigationTarget() : nil) ?? player.currentTime().seconds
        let isFinished = remux?.isFinished == true
        let hasMediaThere = playedPosition.lastPlayedTime != nil && time.isFinite
            && remux?.hasMedia(fromPlayerSeconds: time) == true
        let eligible = (isFinished || hasMediaThere) && hasAppeared && !starvation.isRecovering && !fallbackRequested
            && !isTornDown && !isPictureInPictureActive && !player.isExternalPlaybackActive
            && UIApplication.shared.applicationState == .active
        guard let stuckAt = stuckWatch.note(time: time, clock: ProcessInfo.processInfo.systemUptime,
                                            wantsPlayback: player.rate != 0,
                                            isItemReady: player.currentItem?.status == .readyToPlay,
                                            isEligible: eligible),
              let finished = remux else { return }
        // On AVPlayer's timeline: the EXTINF list it plays (VOD: the frozen
        // list; EVENT: the real durations).
        let session = finished.session
        let endZone = StuckPlaybackWatch.endZoneStart(segmentDurations: session?.playerTimelineDurations()
                                                                        ?? session?.segmentDurations() ?? [],
                                                      itemDuration: player.currentItem?.duration.seconds)
        let action = stuckWatch.decide(at: stuckAt, endZoneStart: endZone)
        print("[Player] AVPlayer stuck at \(String(format: "%.3f", stuckAt)) s on "
              + (isFinished ? "a finished remux" : "media that is on disk")
              + " (end zone from \(endZone.map { String(format: "%.3f", $0) } ?? "?") s) → \(action)")
        switch action {
        case .naturalEnd:
            player.pause()
#if os(tvOS)
            upNextItemEnded(reason: "natural end (stuck at the end)")
#endif
            // No end notification comes: the iPhone / iPad's episode
            // chaining (`UpNextRemuxClock`) is told here.
            onNaturalEnd?()
        case .rebuild:
            if starvation.rebuildNow(player: player, at: stuckAt, reason: StuckPlaybackWatch.reason) {
                // The recovery seeks itself: a pending resume seek is moot.
                cancelStartSeek()
                isSeekingToStart = false
                startSeekTarget = nil
            }
        case .fallback:
            requestFallback(StuckPlaybackWatch.reason, resumeTime: stuckAt)
        }
    }

    /// A new current item (the first one, a recovery's replacement): when
    /// AVPlayer starts it on live EVENT playlists — remux of a file without a
    /// Matroska Duration that hasn't finished yet — it is replaced once the
    /// remux has finished (`rebuildLiveBornItemIfEnded`).
    private func noteAttachedItem(_ item: AVPlayerItem) {
        let remux = route == .remux ? self.remux : nil
        liveBornWatch.attached(ObjectIdentifier(item),
                               isEventSession: (remux?.session?.totalDurationSeconds ?? 1) <= 0,
                               remuxFinished: remux?.isFinished ?? true)
        // Its master playlist has every OpenSubtitles list known so far,
        // and it loads the files as they are served now (retimed or not).
        lateSubtitles.attached()
        retimeWatch.attached()
    }

    /// Remux path, 1 Hz: AVFoundation keeps the live bookkeeping of an item
    /// it started on EVENT playlists after it sees ENDLIST, and that item
    /// later breaks (seekable range collapsed, seeks and audio / subtitle
    /// switches that never complete — `LiveBornItemWatch`). So once the
    /// remux has finished, that item is rebuilt once in place at the current
    /// time through the stuck-item path (selection and position kept, under
    /// 0.3 s without picture), playing on only if the user wants playback
    /// (`PlaybackIntentWatch`). Waits for the
    /// next tick while a recovery runs, a start seek or the resume question
    /// is pending, in the background, over AirPlay or in Picture in Picture.
    /// A resume seek not issued yet counts as pending: it observes the item
    /// it was set up for, so a replacement before it would lose the resume
    /// point and never start playback.
    private func rebuildLiveBornItemIfEnded() {
        guard let player = player, route == .remux, let remux = remux else { return }
        let time = player.currentTime().seconds
        guard liveBornWatch.shouldRebuild(current: player.currentItem.map { ObjectIdentifier($0) },
                                          remuxFinished: remux.isFinished,
                                          isEligible: canRebuildInPlace(player, at: time)) else { return }
        let playing = playIntent.wantsPlayback
        print("[Player] remux finished: replacing the item AVPlayer started on live EVENT playlists at "
              + "\(String(format: "%.3f", time)) s (\(playing ? "playing" : "paused"))")
        starvation.rebuildNow(player: player, at: time, reason: LiveBornItemWatch.reason,
                              resumesPlayback: playing, exactPosition: true)
    }

    /// The current item can be replaced in place at `time` now
    /// (`rebuildNow`): on screen and active, no recovery, hand-off, resume
    /// question nor start seek in the way, not over AirPlay nor in Picture
    /// in Picture.
    private func canRebuildInPlace(_ player: AVPlayer, at time: Double) -> Bool {
        return hasAppeared && !starvation.isRecovering && !fallbackRequested && !isTornDown
            && !resumeChoicePending && !awaitingStartSeek && !isSeekingToStart && time.isFinite && time >= 0
            && !isPictureInPictureActive && !player.isExternalPlaybackActive
            && UIApplication.shared.applicationState == .active
    }

    /// Remux path, 1 Hz: the OpenSubtitles list came after AVPlayer read the
    /// master playlist (`LateSubtitlesWatch`: it reads it once). The item is
    /// rebuilt once in place on a master that lists it, the way a live-born
    /// one is (selection and position kept, playing on only if the user
    /// wants playback); subtitles the user did not choose get the preferred
    /// language's, as on a first start. Waits for the next tick as
    /// `rebuildLiveBornItemIfEnded` does, and until playback has started.
    private func rebuildForLateSubtitlesIfDue() {
        guard let player = player, route == .remux, remux != nil, player.currentItem != nil else { return }
        let time = player.currentTime().seconds
        guard lateSubtitles.shouldRebuild(isEligible: didStartPlayback && canRebuildInPlace(player, at: time)) else { return }
        let playing = playIntent.wantsPlayback
        print("[Player] OpenSubtitles answered after the master playlist was read: replacing the item at "
              + "\(String(format: "%.3f", time)) s (\(playing ? "playing" : "paused")) for its subtitles")
        starvation.rebuildNow(player: player, at: time, reason: LateSubtitlesWatch.reason,
                              resumesPlayback: playing, exactPosition: true, picksSubtitlesAnew: true)
    }

    /// Remux path, 1 Hz: the automatic sync retimed an OpenSubtitles file
    /// (`RemuxPlayback.onExternalSubtitleRetimed`). AVPlayer read that
    /// WebVTT once for this item: when it is the subtitle on screen, the
    /// item is rebuilt in place on the corrected file — position, play /
    /// pause state and the user's audio and subtitle choice kept (not picked
    /// anew), under 0.3 s without picture — also when the user switches to
    /// it later on this item. Otherwise nothing: the next item loads the
    /// corrected file. Waits for the next tick as
    /// `rebuildForLateSubtitlesIfDue` does (recovery, resume question, start
    /// seek, Picture in Picture, AirPlay, background).
    private func rebuildForRetimedSubtitlesIfDue() {
        guard let player = player, route == .remux, remux != nil, let item = player.currentItem else { return }
        if retimeWatch.needsSelectionCheck, !retimeCheckInFlight {
            retimeCheckInFlight = true
            Task { @MainActor [weak self] in
                let shown = await PlaybackLanguagePreferences.shownExternalSubtitleKey(of: item)
                guard let self = self else { return }
                self.retimeCheckInFlight = false
                // The item was replaced meanwhile: it loaded the corrected file.
                guard self.player?.currentItem === item else { return }
                self.retimeWatch.selectionChecked(shownKey: shown)
            }
        }
        let time = player.currentTime().seconds
        guard retimeWatch.shouldRebuild(isEligible: didStartPlayback && canRebuildInPlace(player, at: time)) else { return }
        let playing = playIntent.wantsPlayback
        print("[Player] OpenSubtitles file retimed by the automatic sync: replacing the item at "
              + "\(String(format: "%.3f", time)) s (\(playing ? "playing" : "paused")) with the corrected subtitles")
        starvation.rebuildNow(player: player, at: time, reason: SubtitleRetimeWatch.reason,
                              resumesPlayback: playing, exactPosition: true, announced: true)
    }

#if DEBUG
    /// `-PTDebugExternalSubtitle "<file>@<language>"`: its OpenSubtitles
    /// rendition is selected once, as soon as the item has it (the remux
    /// flags it DEFAULT, but a DEFAULT subtitle is only shown when the
    /// system's subtitle setting asks for it).
    private func debugSelectExternalSubtitleIfDue() {
        guard !debugSelectedExternalSubtitle, !debugSelectingExternalSubtitle, route == .remux,
              let language = RemuxPlayback.debugExternalSubtitleLanguage,
              let item = player?.currentItem, item.status == .readyToPlay else { return }
        debugSelectingExternalSubtitle = true
        Task { @MainActor [weak self] in
            let done = await PlaybackLanguagePreferences.debugSelectExternalSubtitle(language: language, in: item)
            self?.debugSelectingExternalSubtitle = false
            if done { self?.debugSelectedExternalSubtitle = true }
        }
    }
    private var debugSelectedExternalSubtitle = false
    private var debugSelectingExternalSubtitle = false
#endif

    /// Remux path: the user picked another audio track in AVKit's menu. The
    /// item is rebuilt in place on that track (position kept, playing on
    /// only if the user wants playback) instead of AVPlayer switching
    /// renditions inside the item: tvOS sets the HDMI audio output up
    /// (passthrough, Dolby Atmos) for the track an item starts on, and a
    /// switch inside the item could keep the old track or freeze the
    /// picture — the stuck-item rebuild then went back to the master's
    /// default language. The new item gets the pick explicitly
    /// (`MediaSelectionSnapshot`), so it is a clean start of that track.
    @objc private func userPickedAudio(_ note: Notification) {
        guard let player = player, route == .remux, remux != nil, let item = player.currentItem,
              note.object as AnyObject? === item, didStartPlayback else { return }
        let time = player.currentTime().seconds
        guard canRebuildInPlace(player, at: time) else {
            print("[Player] audio track picked — no rebuild now (recovery, hand-off or background): AVPlayer switches it")
            return
        }
        let playing = playIntent.wantsPlayback
        print("[Player] audio track picked: rebuilding the item at \(String(format: "%.3f", time)) s on it "
              + "(\(playing ? "playing" : "paused")) — a clean start of its audio")
        starvation.rebuildNow(player: player, at: time, reason: Self.audioPickReason,
                              resumesPlayback: playing, exactPosition: true)
    }

    /// Why (the rebuild's log line).
    static let audioPickReason = "Changement de piste audio"

    override var canBecomeFirstResponder: Bool { return true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        hasAppeared = true
        if let pending = pendingFallback {
            pendingFallback = nil
            // Next turn: the owner dismisses / swaps this controller, which
            // shouldn't happen inside the presentation's own callout.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isTornDown else { return }
                self.deliverFallback(reason: pending.reason, resume: pending.resume, decided: pending.decided)
            }
            return
        }
        if resumeChoicePending && !resumeQuestionScheduled {
            resumeQuestionScheduled = true
            scheduleResumeQuestion()
        }
        startPlaybackIfPossible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Only a real exit tears down: AVKit's own full-screen transitions,
        // sheets, alerts and the Up Next proposal also trigger
        // viewWillDisappear.
        if isLeavingPermanently { tearDown() }
    }

    /// Dismissed (tvOS modal / SwiftUI cover) or removed from its parent
    /// (SwiftUI swapping the engine).
    private var isLeavingPermanently: Bool {
        var current: UIViewController? = self
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent
        }
        return false
    }

    override var keyCommands: [UIKeyCommand]? {
        let stats = UIKeyCommand(input: "n", modifierFlags: [], action: #selector(toggleStatsOverlay))
        stats.wantsPriorityOverSystemBehavior = true
        return [stats]
    }

#if os(tvOS)
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .upArrow }) {
            toggleStatsOverlay()
        }
        super.pressesBegan(presses, with: event)
    }
#endif

    @objc private func toggleStatsOverlay() {
        statsLabel.isHidden.toggle()
        // Its text is only kept up to date while it shows.
        refreshStats()
    }

    /// Formats AVPlayer resolved, refreshed asynchronously by the stats timer.
    private var trackSummaries: [PlayerTrackSummary] = []
    private var isLoadingTrackSummaries = false

    private func reloadTrackSummaries() {
        guard !isLoadingTrackSummaries, let item = player?.currentItem else { return }
        isLoadingTrackSummaries = true
        Task { @MainActor [weak self] in
            let summaries = await PlayerTrackSummary.load(from: item)
            guard let self = self else { return }
            self.trackSummaries = summaries
            self.isLoadingTrackSummaries = false
        }
    }

    /// The stats overlay's text — only while it shows: it is hidden 10 s
    /// after the start, and this used to reload every track's format
    /// description and rebuild the text once a second for the whole film,
    /// for a hidden label.
    private func refreshStats() {
        guard !statsLabel.isHidden else { return }
        reloadTrackSummaries()
        var lines = ["Engine  \(engineLine)"]
        if player?.currentItem != nil {
            for track in trackSummaries {
                if track.mediaType == .video {
                    lines.append("Video   \(track.fourCC)  \(track.width)×\(track.height)")
                } else {
                    let atmos = track.fourCC == "ec-3" ? "  → Dolby (Atmos-capable, Apple renderer)" : ""
                    lines.append("Audio   \(track.fourCC)  \(track.channels) ch\(atmos)")
                }
            }
        }
        if let remux = remux {
            lines.append(contentsOf: remux.renditionSummary.map { "Track   \($0)" })
            lines.append("Remux   \(remux.statsSummary)")
        }
        if let subtitles = subtitleController {
            lines.append("Subs    \(subtitles.selected?.language ?? "off") · \(subtitles.available.count) available")
        }
        if starvation.isRecovering, let time = starvation.resumeTime {
            if starvation.isRebuildingStuckItem {
                lines.append("Recovery stuck playback: new item at \(ResumePolicy.clockString(seconds: time))")
            } else if starvation.isWaitingForPlay {
                lines.append("Recovery paused: new item on play, at \(ResumePolicy.clockString(seconds: time))")
            } else {
                lines.append("Recovery waiting for data at \(ResumePolicy.clockString(seconds: time)) · attempt "
                             + "\(starvation.attemptsWithoutProgress)/\(starvation.maxAttemptsWithoutProgress)")
            }
        } else if starvation.recoveryCount > 0 {
            lines.append("Recovery \(starvation.recoveryCount) starvation(s) overcome natively")
        }
        statsLabel.text = " " + lines.joined(separator: "\n ") + " "
    }

#if os(tvOS)
    // MARK: - Up Next (tvOS episodes)

    /// Proposes the next episode before the end — the native counterpart
    /// of the VLC player's "Up Next" (AVKit content proposal: the video
    /// keeps playing in a frame while the countdown runs). As early as the
    /// session's card: the setting « Next Episode Card », at most a third
    /// of the file (`UpNextPreferences.legacyCardLead`).
    private func installUpNextIfNeeded(for item: AVPlayerItem) {
        // With a session, the session says when (`reconcileUpNextCard`).
        guard upNextSession == nil, nextEpisode != nil, onPlayNext != nil else { return }
        upNextObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] observed, _ in
            DispatchQueue.main.async { self?.configureUpNextProposal(on: observed) }
        }
    }

    private func configureUpNextProposal(on item: AVPlayerItem) {
        guard let episode = nextEpisode, !isTornDown, !fallbackRequested, player?.currentItem === item,
              item.nextContentProposal == nil else { return }
        let duration = item.duration.seconds
        // Known once the item is ready (VOD playlist / MP4); an EVENT
        // playlist gets it when the remux has finished.
        guard duration.isFinite, duration > 60 else { return }
        upNextObservation?.invalidate()
        upNextObservation = nil
        let lead = UpNextPreferences.legacyCardLead(duration: duration)
        let proposal = AVContentProposal(contentTimeForTransition: CMTime(seconds: duration - lead, preferredTimescale: 600),
                                         title: UpNextProposalViewController.displayTitle(for: episode),
                                         previewImage: nil)
        // Our own countdown (UpNextProposalViewController), not AVKit's.
        proposal.automaticAcceptanceInterval = .nan
        item.nextContentProposal = proposal
        print("[Player] Up Next: S\(episode.season)E\(episode.episode) proposed at \(Int(duration - lead)) s")
    }

    private func makeUpNextViewController(for episode: Episode) -> UpNextProposalViewController {
        let controller = UpNextProposalViewController(episode: episode)
        controller.onAccept = { [weak self] in self?.playNextEpisode() }
        controller.onDefer = { [weak self] in
            // « Revenir à la vidéo »: keep watching, don't propose again.
            self?.player?.currentItem?.nextContentProposal = nil
        }
        return controller
    }

    /// Accepted (button or countdown): close this player — progress saved,
    /// stream cancelled — then start the next episode through the app's
    /// normal flow (quality choice, new stream), like the VLC player.
    fileprivate func playNextEpisode() {
        guard !didAcceptUpNext, !isTornDown, let episode = nextEpisode, let onPlayNext = onPlayNext else { return }
        didAcceptUpNext = true
        print("[Player] Up Next accepted → S\(episode.season)E\(episode.episode)")
        tearDown()
        dismissPlayer(animated: true) { onPlayNext(episode) }
    }

    // MARK: - Episode chaining (5.3.0): the session drives the card

    private func bindUpNext(_ session: UpNextSession) {
        upNextSession = session
        // Async: the session publishes before it starts the next episode,
        // which closes this player first (`closeForNextEpisode`).
        upNextCardSubscription = session.$card.receive(on: DispatchQueue.main).sink { [weak self] card in
            self?.reconcileUpNextCard(card)
        }
    }

    /// 1 Hz: where the file is, to the session — its length when known (a
    /// remux still writing an EVENT playlist: its header's length when it
    /// has one, else none: the card comes after the file, never on a guess).
    private func upNextTick() {
        guard let session = upNextSession, !isTornDown, !fallbackRequested, !isHandingOff,
              let player = player, let item = player.currentItem, item.status == .readyToPlay,
              !starvation.isRecovering, !isResumingNatively, !awaitingStartSeek, !isSeekingToStart else { return }
        // A navigation still pending is where the user is (`wantedPosition`:
        // its target), not the old time a held seek leaves in `currentTime()`
        // — a rewind before the card takes the card away at once.
        guard let position = wantedPosition() else { return }
        var duration: Double? = item.duration.seconds
        if let known = duration, !known.isFinite || known <= 0 { duration = nil }
        if duration == nil, route == .remux, let total = remux?.session?.totalDurationSeconds, total > 0 { duration = total }
        #if DEBUG
        // `-PTDebugUpNextNoDuration YES` (bench): the length is never told,
        // as on an EVENT playlist to its end — the after-play card.
        if UserDefaults.standard.bool(forKey: "PTDebugUpNextNoDuration") { duration = nil }
        #endif
        session.tick(position: position, duration: duration, isPlaying: playIntent.wantsPlayback)
        reconcileUpNextCard(session.card)
    }

    /// The file ended (AVPlayer's notification, or the stuck-at-the-end
    /// safety net): the session takes the end over (after-play card, start,
    /// or the close) — nothing else here.
    private func upNextItemEnded(reason: String) {
        guard let session = upNextSession, !isTornDown, !fallbackRequested, !isHandingOff else { return }
        // Not while the user is elsewhere: a recovery (a jump's wait keeps
        // the old item at its rate), a navigation pending to well before the
        // end (`UpNextNavigationRule`; the Mac's end observer skips a
        // recovering player too).
        let pending = pendingNavigationTarget()
        var duration: Double? = player?.currentItem?.duration.seconds
        if let known = duration, !known.isFinite || known <= 0 { duration = nil }
        if duration == nil, route == .remux, let total = remux?.session?.totalDurationSeconds, total > 0 { duration = total }
        guard UpNextNavigationRule.isFileEnd(isRecovering: starvation.isRecovering, pendingTarget: pending,
                                             duration: duration) else {
            print("[UpNext] native player: an end of the item (\(reason)) ignored — "
                  + (starvation.isRecovering ? "a recovery runs" : "a navigation to \(String(format: "%.1f", pending ?? .nan)) s is pending"))
            return
        }
        print("[UpNext] native player: end of the file (\(reason))")
        if session.itemEnded() { reconcileUpNextCard(session.card) }
    }

    /// Shows, keeps or hides the card as the session says. A countdown on
    /// a healthy item: AVKit's content proposal (the video shrunk at the
    /// top), asked to present one second ahead; AVKit not presenting it in
    /// `upNextProposalPatience` s, or any other card (after the file, « Still
    /// watching? »): the overlay over the player.
    private func reconcileUpNextCard(_ card: UpNextCardState?) {
        guard upNextSession != nil, !isTornDown, !isClosingForNextEpisode, !isHandingOff, !fallbackRequested else { return }
        guard let card = card else {
            hideUpNextCard()
            return
        }
        if upNextProposal?.isShowing == true { return }
        if let overlay = upNextOverlay, overlay.presentingViewController != nil, !overlay.isBeingDismissed { return }
        guard hasAppeared, viewIfLoaded?.window != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if card.kind == .countdown, let player = player, let item = player.currentItem, item.status == .readyToPlay,
           presentedViewController == nil {
            if let asked = upNextProposalRequestedAt {
                guard now - asked >= Self.upNextProposalPatience else { return }
                print("[UpNext] AVKit did not present the proposal in \(Int(Self.upNextProposalPatience)) s — the overlay instead")
            } else {
                // Not while a navigation's seek is held: its proposal would
                // be timed on the old position (« AVKit proposal at 92 s »
                // for a move to 151.8 s); asked at a later tick, once the
                // player's time is where the user is (`wantedPosition`).
                let current = player.currentTime().seconds
                guard current.isFinite, let wanted = wantedPosition(),
                      abs(current - wanted) <= UserNavigationTarget.thresholdSeconds else { return }
                let at = current + 1
                upNextProposalRequestedAt = now
                item.nextContentProposal = nil
                let proposal = AVContentProposal(contentTimeForTransition: CMTime(seconds: at, preferredTimescale: 600),
                                                 title: card.title, previewImage: nil)
                // The session's countdown, not AVKit's.
                proposal.automaticAcceptanceInterval = .nan
                item.nextContentProposal = proposal
                print("[UpNext] native card: AVKit proposal at \(Int(at)) s")
                return
            }
        }
        presentUpNextOverlay(card)
    }

    private func presentUpNextOverlay(_ card: UpNextCardState) {
        guard let session = upNextSession else { return }
        // Not over another presentation (the resume question, the deficit
        // toast, the chooser): tried again at the next tick.
        guard presentedViewController == nil, transitionCoordinator == nil else { return }
        player?.currentItem?.nextContentProposal = nil
        let overlay = UpNextOverlayViewController(session: session, summary: session.next.summary)
        upNextOverlay = overlay
        print("[UpNext] native card: overlay (\(card.kind.rawValue))")
        present(overlay, animated: true)
    }

    private func hideUpNextCard() {
        upNextProposalRequestedAt = nil
        player?.currentItem?.nextContentProposal = nil
        if let proposal = upNextProposal, proposal.isShowing {
            proposal.dismissForSession()
        }
        upNextProposal = nil
        if let overlay = upNextOverlay, overlay.presentingViewController != nil, !overlay.isBeingDismissed {
            overlay.dismiss(animated: true)
        }
        upNextOverlay = nil
    }
#endif
}

#if os(tvOS)
extension RemuxAVPlayerViewController: UpNextTVPlayer {

    /// The next episode (or today's flow): this player closes as at the
    /// end of an episode — progress saved, stream cancelled and its data
    /// deleted (`tearDown`) — before `then` starts anything.
    func closeForNextEpisode(then: @escaping () -> Void) {
        guard !isTornDown else { return then() }
        isClosingForNextEpisode = true
        print("[UpNext] native player closes at the session's request (next episode, fallback or end) — stream cancelled, its data deleted")
        tearDown()
        dismissPlayer(animated: true, completion: then)
    }

    var upNextPresenter: UIViewController { self }
}
#endif

extension RemuxAVPlayerViewController: AVPlayerViewControllerDelegate {

    // Picture in Picture: the stuck-playback safety net stays out of it, and
    // playback goes on in the background (`applicationDidEnterBackground`).

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActive = true
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              failedToStartPictureInPictureWithError error: Error) {
        isPictureInPictureActive = false
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActive = false
    }

#if os(tvOS)
    /// Bounded storage: a skip or scrub (Siri Remote, transport bar) further
    /// back than what is still on disk lands on the earliest point still
    /// available instead, with the message. Forward moves, rewinds within
    /// what is kept and full mode: as the user asked.
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              timeToSeekAfterUserNavigatedFrom oldTime: CMTime, to proposedTime: CMTime) -> CMTime {
        // A press while the native resume's item is put in place, before its start seek: no
        // move (the player has no clock yet) — AVKit's own seek goes to the resume point too.
        if let resume = ResumePolicy.startSeekOverride(isResumingNatively: isResumingNatively, awaitingStartSeek: awaitingStartSeek,
                                                       isItemReady: player?.currentItem?.status == .readyToPlay,
                                                       resumeTarget: remux?.resumeTargetSeconds) {
            print("[Resume] navigation to \(String(format: "%.1f", proposedTime.seconds)) s while the resume's item is put in place "
                  + "— ignored, AVKit is sent to the resume point \(String(format: "%.1f", resume)) s")
            return CMTime(seconds: resume, preferredTimescale: 600)
        }
        // Counted from a new item's start while the player is elsewhere: the
        // same step from where it is (`NavigationRebase`).
        let target = rebasedNavigationTarget(old: oldTime.seconds, target: proposedTime.seconds)
        let targetTime = target == proposedTime.seconds ? proposedTime : CMTime(seconds: target, preferredTimescale: 600)
        guard !isTornDown, !fallbackRequested, let session = boundedStorage, session.isBounded,
              let reference = playedPosition.lastPlayedTime ?? (oldTime.seconds.isFinite ? oldTime.seconds : nil),
              let landing = BoundedStorageUX.limitedRewindTarget(target, from: reference, session: session) else {
            noteUserNavigation(from: oldTime.seconds, to: target)
            return targetTime
        }
        BoundedStorageUX.logLimited(player: "AVPlayer (navigation)", target: target, playhead: reference, landing: landing,
                                    session: boundedStorage)
        logRewindBlockedByJump(target: target, landing: landing)
        showBoundedToast()
        noteUserNavigation(from: oldTime.seconds, to: landing)
        return CMTime(seconds: landing, preferredTimescale: 600)
    }

    /// AVKit's seek for a navigation completed and it plays on (it calls
    /// `setRate:` itself right after): only logged — the intent was taken
    /// at the navigation (`noteUserNavigation`).
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willResumePlaybackAfterUserNavigatedFrom oldTime: CMTime, to targetTime: CMTime) {
        // What the player is at that moment decides what a target far from
        // the navigation's means (a held seek AVKit counted from a new item's
        // start, or a real seek): logs only, never acted on.
        let now = ProcessInfo.processInfo.systemUptime
        let item = player?.currentItem
        let isReplacement = item != nil && item === starvation.replacementItem
        let since = lastItemReplacementAt.map { String(format: "last item replacement %.1f s ago", now - $0) }
            ?? "no item replacement yet"
        print("[Player] AVKit resumes playback after the navigation to \(String(format: "%.1f", targetTime.seconds)) s"
              + " (from \(String(format: "%.1f", oldTime.seconds)) s; item: "
              + (item == nil ? "none" : isReplacement ? "the recovery's new one" : "not a recovery's")
              + ", \(since), rate \(player?.rate ?? 0)"
              + ", item \(item.map { Self.describe($0.status) } ?? "none")"
              + ", the player reads \(String(format: "%.1f", player?.currentTime().seconds ?? .nan)) s"
              + (starvation.isRecovering ? ", recovery running" : "") + ")")
    }

    // "Up Next" (tvOS episodes).

    func playerViewController(_ playerViewController: AVPlayerViewController, shouldPresent proposal: AVContentProposal) -> Bool {
        if let session = upNextSession {
            // The session's card, while it still wants one.
            guard session.card != nil, !isTornDown, !fallbackRequested, !isClosingForNextEpisode,
                  presentedViewController == nil else { return false }
            let controller = UpNextProposalViewController(session: session)
            upNextProposal = controller
            playerViewController.contentProposalViewController = controller
            print("[UpNext] native card: AVKit presents the proposal")
            return true
        }
        guard let episode = nextEpisode, onPlayNext != nil, !isTornDown, !fallbackRequested, !didAcceptUpNext else {
            return false
        }
        playerViewController.contentProposalViewController = makeUpNextViewController(for: episode)
        return true
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, didAccept proposal: AVContentProposal) {
        if let session = upNextSession {
            // Only AVKit itself accepts (the session's card answers the
            // session directly); its automatic acceptance is off (NaN).
            if session.card != nil { session.accept(source: .avkit(cardUp: upNextProposal?.cardUp)) }
            return
        }
        // The card's own completion normally gets there first (once it is
        // hidden); this is the safety net.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.playNextEpisode()
        }
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, didReject proposal: AVContentProposal) {
        player?.currentItem?.nextContentProposal = nil
        // Menu on AVKit's card: « Back to the Video ».
        if let session = upNextSession, session.card?.kind == .countdown { session.cancel() }
    }
#endif
}

// MARK: - User navigation the playhead does not show

extension RemuxAVPlayerViewController {

    /// tvOS: AVKit's navigation (transport bar, Siri Remote), confirmed —
    /// the final target, after the bounded-storage limit. It is where the
    /// player wants data from now on (`wantedPosition`), whatever
    /// `currentTime()` reads: on the Apple TV it kept the time from before
    /// a seek held for a segment the resume's jump skipped, so the
    /// conversion never jumped and the item failed (-12889). Reported to
    /// the remux at once: a target that is not on disk makes it jump there,
    /// and the jump's wait (« Reprise à … », a new item there once its media
    /// is written) takes over. AVKit resumes playback after a confirmed
    /// navigation, paused before or not (measured, tvOS 26.5 simulator) —
    /// but only once its own seek completes, which a held one may never
    /// do: the intent is taken now. During a recovery the move is the
    /// recovery's new target (`userNavigated`).
    private func noteUserNavigation(from old: Double, to target: Double) {
        guard !isTornDown, !fallbackRequested, target.isFinite, target >= 0, let player = player else { return }
        let current = player.currentTime().seconds
        // (Read BEFORE AVKit issues its seek: it says nothing of what
        // `currentTime()` shows during it — `logPendingNavigation` does.)
        print("[Player] navigation \(String(format: "%.1f", old)) → \(String(format: "%.1f", target)) s ("
              + "\(playIntent.wantsPlayback ? "playing" : "paused"), before AVKit's seek the player reads "
              + "\(String(format: "%.1f", current)) s, \(Self.describe(player.timeControlStatus)))")
        if starvation.isRecovering {
            starvation.userNavigated(to: target, from: old.isFinite ? old : current, resumesPlayback: true)
            return
        }
        if route == .remux, isSeekingToStart, startSeekTarget != nil {
            // During a native resume's start seek (under its cover): AVKit's
            // seek supersedes it — the move is the new start, and the
            // resume's start lock must not keep the conversion at the old one.
            print("[Resume] navigation during the start seek: \(String(format: "%.1f", target)) s is the new start")
            startSeekTarget = target
            remux?.releaseStartPin()
            navigation.navigated(from: old.isFinite ? old : current, to: target, played: playedPosition.lastPlayedTime,
                                 clock: ProcessInfo.processInfo.systemUptime)
            reportPlaybackPositions()
            return
        }
        guard isItemHealthy else { return }
        // AVKit resumes playback itself once its seek completes (the rate
        // observer takes the intent then); a seek it holds for media still to
        // be written may never complete: the intent is taken now (remux: only
        // then — a paused skip over media on disk keeps the intent AVKit's).
        if route != .remux || remux?.hasMedia(fromPlayerSeconds: target, cushion: 0) != true {
            playIntent.noteUserPlayback(playing: true)
        }
        // A press chained on a move still pending (AVKit counts it from that
        // move's target): the move's origin is kept, read before `navigated`
        // replaces it (`UserNavigationTarget.origin(ofMoveFrom:current:)`).
        let origin = navigation.origin(ofMoveFrom: old.isFinite ? old : current, current: current)
        if let origin = origin, old.isFinite, origin != old {
            print("[Player] navigation chained on the pending one: from \(String(format: "%.1f", origin)) s, where the player still reads")
        }
        navigation.navigated(from: origin, to: target, played: playedPosition.lastPlayedTime,
                             clock: ProcessInfo.processInfo.systemUptime)
        pendingNavigationLogs = 0
        reportPlaybackPositions()
        noteHeldSeek(isJump: false)
#if os(tvOS)
        // The « next episode » countdown hears the move now, not at the next
        // tick: a jump's wait (`ResumePolicy.jumpGraceSeconds` on) stops the
        // ticks, and the card would stay up over « Reprise à … ».
        upNextTick()
#endif
    }

    /// `PlaybackStarvationRecovery.onNavigatedDuringRebuild`: the user moved
    /// while the recovery's new item was put in place; it now sits at the
    /// recovery's position — the move is made now, as any navigation.
    private func navigateAfterRebuild(to target: Double) {
        guard !isTornDown, !fallbackRequested, let player = player else { return }
        print("[Player] the navigation made while the new item was put in place: seeking to \(String(format: "%.1f", target)) s")
        let from = player.currentTime().seconds
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        noteUserNavigation(from: from, to: target)
    }

    /// The delegate's target, re-based when AVKit counts from a new item's
    /// start (`NavigationRebase`), logged when it is.
    private func rebasedNavigationTarget(old: Double, target: Double) -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        let current = player?.currentTime().seconds
        let rebased = NavigationRebase.target(old: old, target: target, current: current,
                                              sinceReplacement: lastItemReplacementAt.map { now - $0 })
        if rebased != target {
            print("[Player] navigation \(String(format: "%.1f", old)) → \(String(format: "%.1f", target)) s counted from the new "
                  + "item's start while the player reads \(String(format: "%.1f", current ?? .nan)) s — "
                  + "\(String(format: "%.1f", rebased)) s instead")
        }
        return rebased
    }

    /// 1 Hz: while a navigation is pending, what the player shows — the
    /// question the device must answer (does `currentTime()` show a held
    /// seek?) — a few times, not every second; and why a target was dropped.
    private func logPendingNavigation() {
        guard let player = player else { return }
        let seen = loggedNavigationTarget
        let pending = pendingNavigationTarget()
        loggedNavigationTarget = pending
        if navigation.dropCount != loggedDropCount, let drop = navigation.lastDrop,
           let dropped = navigation.lastDroppedTarget ?? seen {
            // The target really dropped (a move made and dropped between two
            // ticks is told too, with its own position).
            loggedDropCount = navigation.dropCount
            print("[Player] navigation to \(String(format: "%.1f", dropped)) s no longer pending: \(drop.rawValue) "
                  + "(the player reads \(String(format: "%.1f", player.currentTime().seconds)) s)")
            if pending == nil { return }
        }
        guard let pending = pending else { return }
        pendingNavigationLogs += 1
        guard [1, 3, 10, 30].contains(pendingNavigationLogs) else { return }
        let age = navigation.age(clock: ProcessInfo.processInfo.systemUptime) ?? 0
        print("[Player] navigation to \(String(format: "%.1f", pending)) s pending for \(String(format: "%.1f", age)) s: "
              + "the player reads \(String(format: "%.1f", player.currentTime().seconds)) s, "
              + "\(Self.describe(player.timeControlStatus)), rate \(player.rate)"
              + ", item \(player.currentItem.map { Self.describe($0.status) } ?? "none")")
    }

    private static func describe(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        case .playing: return "playing"
        @unknown default: return "status \(status.rawValue)"
        }
    }

    private static func describe(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .readyToPlay: return "ready"
        case .failed: return "failed"
        case .unknown: return "not ready"
        @unknown default: return "status \(status.rawValue)"
        }
    }

    /// `RemuxPlayback.onHoleRequested`: AVPlayer asks for a segment a jump
    /// skipped, behind the position reported — it is seeking there. When
    /// the position wanted does not say so already (`HoleRequestRule`), the
    /// segment (2.5 s into it at most) becomes the wanted position (`UserNavigationTarget`),
    /// reported at once: the conversion jumps there instead of leaving the
    /// request to time out. tvOS: the play intent becomes playing — AVKit
    /// issues no seek on a paused player before the move is confirmed (rig:
    /// presses, a held press, no seek until the click), and it resumes after
    /// a confirmed one; iOS / Mac: left as it is (a timeline drag is no
    /// confirmation; a paused user gets the picture there, paused:
    /// `waitForJump(…rebuildsWhilePaused…)`). Never over a target AVKit's
    /// delegate gave (the user's own word, `isConfirmed`), nor on an item
    /// that is not healthy (start seek, recovery, hand-off). Bounded
    /// storage: a hole is media never downloaded — a rewind there is
    /// blocked at the earliest point kept, with the message, as the
    /// delegate's limit does.
    private func holeRequested(start: Double, end: Double) {
        guard !isTornDown, !fallbackRequested, route == .remux, let remux = remux,
              isItemHealthy, let player = player else { return }
        if pendingNavigationTarget() != nil, navigation.isConfirmed { return }
        let current = player.currentTime().seconds
        if remux.isStorageBounded {
#if os(tvOS)
            guard let session = boundedStorage, session.isBounded, let reference = playedPosition.lastPlayedTime,
                  start < reference,
                  let landing = BoundedStorageUX.limitedRewindTarget(start, from: reference, session: session),
                  !(current.isFinite && abs(current - landing) <= UserNavigationTarget.thresholdSeconds) else { return }
            print("[Player] AVPlayer asks for \(String(format: "%.1f", start))–\(String(format: "%.1f", end)) s, which a jump "
                  + "skipped (bounded storage): a rewind past what is kept — blocked")
            limitRewind(target: start, from: reference, landing: landing)
#endif
            // (iOS: AVKit seeks all along a timeline drag and `currentTime()`
            // shows it — the time-jump check limits the rewind after the drag.)
            return
        }
        let wanted = wantedPosition()
        guard HoleRequestRule.movesPlayer(segmentStart: start, segmentEnd: end, wanted: wanted) else { return }
        print("[Player] AVPlayer asks for \(String(format: "%.1f", start))–\(String(format: "%.1f", end)) s, which a jump "
              + "skipped, while the position wanted reads \(wanted.map { String(format: "%.1f", $0) } ?? "?") s — a seek there")
        // A little inside the segment: a target on its very start would put
        // the new item (pre-positioned, then up to 2 s before) in the hole
        // before it (measured: never ready, VLC after 30 s).
        let target = start + min(2.5, max(0, end - start) / 2)
#if os(tvOS)
        playIntent.noteUserPlayback(playing: true)
#endif
        navigation.navigated(from: current, to: target, played: playedPosition.lastPlayedTime,
                             clock: ProcessInfo.processInfo.systemUptime, confirmed: false)
        pendingNavigationLogs = 0
        reportPlaybackPositions()
        noteHeldSeek(isJump: false)
    }

    /// The navigation's target while it is still pending (a stale one is
    /// dropped first, as `wantedPosition` does): what a failure of the item
    /// recovers when no held seek was seen.
    private func pendingNavigationTarget() -> Double? {
        _ = navigation.wanted(current: player?.currentTime().seconds, played: playedPosition.lastPlayedTime,
                              clock: ProcessInfo.processInfo.systemUptime)
        return navigation.target
    }
}

#if os(tvOS)
/// tvOS "Up Next" card presented by AVKit before the end of an episode (Settings › Next
/// Episode Card: 60 s by default, at most a third of the file):
/// the current episode keeps playing in a frame at the top, the next one is
/// shown below (`UpNextCardContentView`) — like the VLC player's Up Next.
///
/// Two modes:
/// - with an `UpNextSession` (5.3.0): the session's card — version line,
///   countdown to the end of the file, « Still watching? » — and three
///   buttons answering the session (« Play Now », « Back to the Video »,
///   « Choose Version »); the player hides it when the session's card goes;
/// - without one (no next episode the session can offer): the card of
///   before 5.3, its own countdown (the same lead, counted on the file's
///   time), two buttons.
final class UpNextProposalViewController: AVContentProposalViewController {

    var onAccept: (() -> Void)?
    var onDefer: (() -> Void)?

    private let episode: Episode
    private weak var session: UpNextSession?
    private var subscription: AnyCancellable?
    /// Set by `startCountdown` (30: only if the player has no item then).
    private var secondsLeft = 30
    /// The card of before 5.3: its countdown's length (the setting, at most
    /// a third of the file; `startCountdown`).
    private var legacyTotal = 30
    private var countdownTimer: Timer?
    private var didFinish = false
    private let content = UpNextCardContentView()
    /// When the card was on screen (`viewDidAppear`): the session's « Play
    /// Now » / « Continue » count one second later (`UpNextPressGuard`: a
    /// click meant for the player as the card slid in).
    private var appearedAt: TimeInterval?

    /// How long the card has been on screen (nil: not yet).
    var cardUp: TimeInterval? {
        UpNextPressGuard.cardUp(appearedAt: appearedAt, now: ProcessInfo.processInfo.systemUptime)
    }

    /// The card of before 5.3 (no session).
    init(episode: Episode) {
        self.episode = episode
        super.init(nibName: nil, bundle: nil)
    }

    /// The session's card.
    init(session: UpNextSession) {
        self.episode = session.next
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// The card is up (not leaving).
    var isShowing: Bool { !didFinish && viewIfLoaded?.window != nil }

    /// "S2 · E3 — Title" (proposal title, logs).
    static func displayTitle(for episode: Episode) -> String {
        return String(format: "S%lld · E%lld".localized, episode.season, episode.episode) + " — " + name(of: episode)
    }

    /// The episode's title, else "Episode 3" in the app's language.
    private static func name(of episode: Episode) -> String {
        episode.title.isEmpty ? String(format: "Episode %lld".localized, episode.episode) : episode.title
    }

    /// The playing episode, shrunk to the top centre (≈ 42 % of the width).
    override var preferredPlayerViewFrame: CGRect {
        let bounds = playerViewController?.view.bounds ?? view.bounds
        let width = (bounds.width * 0.42).rounded()
        let height = (width * 9 / 16).rounded()
        return CGRect(x: ((bounds.width - width) / 2).rounded(), y: (bounds.height * 0.07).rounded(),
                      width: width, height: height)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [content.playButton]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "UpNext.Card"
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            // Below the shrunk player (7 % + 42 % × 9/16 × 16/9 of the height ≈ 49 %).
            NSLayoutConstraint(item: content, attribute: .top, relatedBy: .equal,
                               toItem: view, attribute: .bottom, multiplier: 0.56, constant: 0),
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 40),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -40),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        if let session = session {
            content.onPlay = { [weak self, weak session] in
                guard let self = self, let session = session else { return }
                let button = session.card?.kind == .stillWatching ? "Continue" : "Play Now"
                guard let up = UpNextPressGuard.check(appearedAt: self.appearedAt, button: button) else { return }
                session.accept(source: .playNow(cardUp: up))
            }
            content.onBack = { [weak session] in session?.cancel() }
            content.onChoose = { [weak session] in session?.chooseVersion() }
            if let card = session.card { content.apply(card, summary: episode.summary) }
            subscription = session.$card.receive(on: DispatchQueue.main).sink { [weak self] card in
                guard let self = self, let card = card else { return }
                self.content.apply(card, summary: self.episode.summary)
            }
        } else {
            content.onPlay = { [weak self] in
                // The same one-second guard as the session's card (U1).
                guard let self = self, UpNextPressGuard.check(appearedAt: self.appearedAt, button: "Play Now") != nil else { return }
                self.finish(accept: true)
            }
            content.onBack = { [weak self] in self?.finish(accept: false) }
            applyLegacyCard()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if appearedAt == nil {
            appearedAt = ProcessInfo.processInfo.systemUptime
            // « Play Now » counts a second from here (`UpNextPressGuard`).
            if session != nil { print("[UpNext] native card on screen (AVKit proposal)") }
        }
        if session == nil { startCountdown() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// The session's card went (cancelled, rewound before the card, the next
    /// episode starting): back to the full-screen video.
    func dismissForSession() {
        guard !didFinish else { return }
        didFinish = true
        subscription = nil
        dismissContentProposal(for: .defer, animated: true, completion: nil)
    }

    // Menu on the session's card: « Back to the Video » (the session decides).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let session = session, presses.contains(where: { $0.type == .menu }) else {
            return super.pressesBegan(presses, with: event)
        }
        session.cancel()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard session != nil, presses.contains(where: { $0.type == .menu }) else { return super.pressesEnded(presses, with: event) }
    }

    // MARK: The card of before 5.3

    private func applyLegacyCard() {
        var details = String(format: "Season %lld".localized, episode.season) + " · "
            + String(format: "Episode %lld".localized, episode.episode)
        if let show = episode.show?.title, !show.isEmpty { details = show + " — " + details }
        let image = (episode.largeBackgroundImage ?? episode.show?.largeBackgroundImage).flatMap(URL.init(string:))
        let card = UpNextCardState(kind: .countdown, episodeID: episode.id, headline: "ContinueWatching.NextEpisode".localized,
                                   title: Self.name(of: episode), showTitle: details, versionLine: nil, imageURL: image,
                                   secondsLeft: max(0, secondsLeft), total: legacyTotal, message: nil)
        content.apply(card, summary: episode.summary, showsChooseVersion: false)
    }

    /// The setting's lead (at most a third of the file), or what is left
    /// of the episode when less (auto-play as it ends, like the VLC
    /// player's countdown).
    private func startCountdown() {
        guard countdownTimer == nil, !didFinish else { return }
        if let player = playerViewController?.player, let item = player.currentItem {
            legacyTotal = Int(UpNextPreferences.legacyCardLead(duration: item.duration.seconds).rounded())
            secondsLeft = legacyTotal
            let remaining = item.duration.seconds - player.currentTime().seconds
            if remaining.isFinite { secondsLeft = min(legacyTotal, max(5, Int(remaining.rounded()))) }
        }
        applyLegacyCard()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // The file's own time: a pause or a stall holds the count (the next episode starts
            // at the end of this one, not after 60–90 s of wall clock).
            let player = self.playerViewController?.player
            let remaining = player.flatMap { player in
                player.currentItem.map { $0.duration.seconds - player.currentTime().seconds }
            }
            self.secondsLeft = UpNextPreferences.legacySecondsLeft(remaining: remaining, total: self.legacyTotal,
                                                                   previous: self.secondsLeft)
            self.applyLegacyCard()
            if self.secondsLeft <= 0 { self.finish(accept: true) }
        }
    }

    private func finish(accept: Bool) {
        guard !didFinish else { return }
        didFinish = true
        countdownTimer?.invalidate()
        countdownTimer = nil
        let callback = accept ? onAccept : onDefer
        // .defer: the video goes back to full screen and keeps playing.
        dismissContentProposal(for: accept ? .accept : .defer, animated: true) {
            callback?()
        }
    }
}
#endif

/// SwiftUI bridge for the iOS app.
struct RemuxPlayerView: UIViewControllerRepresentable {
    let localFile: URL
    /// Torrent's local HTTP endpoint (direct MP4 path); nil = remux only.
    var remoteURL: URL? = nil
    let title: String
    let streamer: PTTorrentStreamer?
    var media: Media? = nil
    var isAtmos: Bool = false
    var releaseHintsHDR: Bool = false
    /// 0…1 saved progress (resumed, or asked about on the remux path).
    var startPosition: Float = 0
    /// AVFoundation can't play the payload (or the user resumes through
    /// VLC): swap in VLC on the same stream (`resumeDecided`: see
    /// `RemuxAVPlayerViewController.onFallback`).
    var onFallback: ((_ reason: String, _ resumeFraction: Float, _ resumeDecided: Bool) -> Void)? = nil
    /// The user cancelled the resume question: close the cover.
    var onClose: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> RemuxAVPlayerViewController {
        let vc = RemuxAVPlayerViewController()
        vc.onFallback = onFallback
        vc.onCloseRequest = onClose
        // Episode chaining on iPhone / iPad (5.3.0): the « next episode »
        // card reads this player once a second.
        context.coordinator.attach(vc)
        vc.configure(localFile: localFile,
                     remoteURL: remoteURL ?? localFile,
                     streamer: streamer,
                     title: title,
                     media: media,
                     isAtmos: isAtmos,
                     releaseHintsHDR: releaseHintsHDR,
                     startPosition: startPosition)
        return vc
    }

    func updateUIViewController(_ vc: RemuxAVPlayerViewController, context: Context) {
        vc.onFallback = onFallback
        vc.onCloseRequest = onClose
    }

    static func dismantleUIViewController(_ vc: RemuxAVPlayerViewController, coordinator: UpNextRemuxClock) {
        coordinator.stop()
        // Removed from the hierarchy (cover closed, or the engine swapped to
        // VLC — the controller then keeps the torrent stream alive itself).
        vc.tearDown()
    }

    func makeCoordinator() -> UpNextRemuxClock { UpNextRemuxClock() }
}

/// Episode chaining on iPhone / iPad (5.3.0): the iOS cover's remux player
/// reports to the « next episode » session (`UpNextSession.current`) — its
/// position and the file's length once a second, and the end of the file.
/// Its own timer, so the shared player code is unchanged; nothing happens
/// when no session runs (a movie, the last episode).
@MainActor
final class UpNextRemuxClock {
    private weak var controller: RemuxAVPlayerViewController?
    private var timer: Timer?
    private var endObserver: NSObjectProtocol?
    private weak var observedItem: AVPlayerItem?

    func attach(_ controller: RemuxAVPlayerViewController) {
        self.controller = controller
        // A finished remux stuck in its last segment posts no end: the
        // player's safety net tells it (`onNaturalEnd`), as the Apple TV's
        // and the Mac's players tell their sessions.
        controller.onNaturalEnd = { [weak self] in
            MainActor.assumeIsolated { self?.itemEnded(reason: "stuck at the end of a finished remux") }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    private func tick() {
        guard let session = UpNextSession.current, let sample = controller?.upNextSample() else { return }
        watchEnd(of: sample.item)
        session.tick(position: sample.position, duration: sample.duration, isPlaying: sample.isPlaying)
    }

    /// The end of the CURRENT item (a starvation rebuild or the live-born
    /// item's replacement swaps it).
    private func watchEnd(of item: AVPlayerItem?) {
        guard let item, item !== observedItem else { return }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observedItem = item
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemEnded(reason: "end of the item") }
        }
    }

    private func itemEnded(reason: String) {
        guard let session = UpNextSession.current, let sample = controller?.upNextSample() else { return }
        // Only the file's own end (a jump's playlist ends there too).
        if let duration = sample.duration, sample.position < duration - 60 { return }
        print("[UpNext] iOS remux: \(reason) at \(String(format: "%.1f", sample.position)) s")
        session.tick(position: sample.position, duration: sample.duration, isPlaying: sample.isPlaying)
        session.itemEnded()
    }
}

extension RemuxAVPlayerViewController {
    /// Where the file stands, for `UpNextRemuxClock`: the position (the one
    /// a starvation recovery returns to while it runs), the file's length —
    /// the remux's (the MKV's own) or a VOD item's; nil while neither is
    /// known, never a growing EVENT playlist's —, and whether the user
    /// wants playback. nil before playback started (the resume question),
    /// once torn down or handed to VLC.
    func upNextSample() -> (position: Double, duration: Double?, isPlaying: Bool, item: AVPlayerItem?)? {
        guard !isTornDown, !fallbackRequested, !isHandingOff, didStartPlayback, let player = player else { return nil }
        let time = starvation.isRecovering ? (starvation.resumeTime ?? .nan) : player.currentTime().seconds
        guard time.isFinite, time >= 0 else { return nil }
        var duration: Double?
        if let total = remux?.session?.totalDurationSeconds, total > 0 {
            duration = total
        } else if let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
            duration = seconds
        }
        return (time, duration, playIntent.wantsPlayback, player.currentItem)
    }
}

/// A label of the players' wait states (« Reprise à … », the starvation
/// text) and the look of the dark capsule they sit in, shared by the native
/// player (`RemuxAVPlayerViewController`) and the VLC state
/// (`VLCResumeOverlayView`): black at 60 % with rounded corners, the text in
/// `title3` semibold on Apple TV and `headline` on iPhone / iPad. Dark under
/// white text, it stays readable over a bright picture and when AVKit dims
/// the content overlay under its transport bar.
final class StatusCapsuleLabel: UILabel {

    /// Called when `isHidden` changes (the capsule follows the label).
    var onVisibilityChange: (() -> Void)?

    override var isHidden: Bool {
        didSet { if oldValue != isHidden { onVisibilityChange?() } }
    }

    private static var isTV: Bool { UIDevice.current.userInterfaceIdiom == .tv }

    static let capsuleColor = UIColor.black.withAlphaComponent(0.6)
    /// 14 pt and 16 pt on iPhone / iPad; Apple TV's 1920-point screen gets
    /// the same proportions at 20 pt and 24 pt.
    static var cornerRadius: CGFloat { isTV ? 20 : 14 }
    static var padding: CGFloat { isTV ? 24 : 16 }

    static var textFont: UIFont {
        guard isTV else { return .preferredFont(forTextStyle: .headline) }
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3)
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
#endif
