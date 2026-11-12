

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
/// Resume: the remux reads the payload in order and nothing makes the torrent
/// fetch the pieces at a resume point first, so while the payload is still
/// downloading a far resume would take minutes natively. The user is then
/// asked: « Reprendre à … » hands the SAME stream to VLC at that position
/// (VLC reads over HTTP byte ranges, which PopcornTorrent prioritizes),
/// « Reprendre du début » plays natively from 0. A payload already on disk
/// (finished download) and the direct MP4 path (byte ranges too) resume
/// natively. The saved progress is never replaced by a smaller fraction
/// unless the user restarted on purpose or watched past it. A hand-off to
/// VLC saves the native part first (at the hand-off position), so a VLC
/// crash or an immediate close never loses it. The progress is also saved
/// when the user pauses and when the app goes to the background (tvOS
/// suspends it at once and may kill it there), so a kill or a crash keeps
/// what was watched.
///
/// tvOS episodes get "Up Next" (AVKit content proposal, 30 s before the end).
///
/// A toggleable nerd-stats overlay shows the resolved formats — `Audio ec-3`
/// is the on-screen proof Apple's renderer gets the raw E-AC-3 and performs
/// the Atmos rendering.
/// (UIKit-only: the native macOS app has its own AVPlayerView-based player —
/// the shared `RemuxPlayback` engine is what both build on.)
final class RemuxAVPlayerViewController: AVPlayerViewController {

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
    /// The user answered « Reprendre du début ».
    private var userChoseStartOver = false
    /// The user answered « Reprendre à … » (quick resume through VLC).
    private var userChoseQuickResume = false
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
#endif

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
    private var engineLine = "préparation…"
    /// The engine line while playing natively (restored after a recovery).
    private var nativeEngineLine = ""
    /// Shown while the remux prepares its first segments (no player yet),
    /// during a far resume seek and while recovering from starvation.
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    /// Below the spinner while recovering from download starvation.
    private let bufferingLabel = UILabel()

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
                   onPlayNext: ((Episode) -> Void)? = nil) {
        // Picture in Picture state (and tvOS "Up Next").
        delegate = self
        keepAliveStreamer = streamer
        self.media = media
        self.title = title
        self.nextEpisode = nextEpisode
        self.onPlayNext = onPlayNext
        // A finished (or nearly finished) title restarts from the beginning.
        self.startPosition = ResumePolicy.startPosition(forSavedProgress: startPosition)
        resumePoint = self.startPosition
        isPayloadLocal = Self.isPayloadComplete(streamer)
        let fileName = localFile.lastPathComponent
        route = PlaybackRouting.route(forFileName: fileName)
        print("[Player] \(fileName) → \(route)")
        switch route {
        case .remux:
            // Sequential remux + still-downloading payload: a far resume
            // can't be served natively in reasonable time — ask first.
            resumeChoicePending = self.startPosition > 0 && !isPayloadLocal
            startRemux(localFile: localFile, streamer: streamer, isAtmos: isAtmos, releaseHintsHDR: releaseHintsHDR)
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
    /// play again after starvation.
    static func remuxHasData(_ remux: RemuxPlayback?, after time: Double) -> Bool {
        guard let session = remux?.session else { return false }
        let progress = session.progress
        return StarvationPolicy.remuxDataReady(frontierSeconds: progress.mediaSeconds, finished: progress.finished,
                                               resumeTime: time, durationKnown: session.totalDurationSeconds > 0)
    }

    // MARK: - Remux path (MKV / WebM)

    private func startRemux(localFile: URL, streamer: PTTorrentStreamer?, isAtmos: Bool, releaseHintsHDR: Bool) {
        engineLine = "MKV remux → AVPlayer (natif)"
        nativeEngineLine = engineLine
        let remux = RemuxPlayback(localFile: localFile, streamer: streamer, isAtmos: isAtmos)
        // DEFAULT audio / subtitle renditions follow the user's languages.
        remux.preferredAudioLanguages = PlaybackLanguagePreferences.preferredAudioLanguageCode.map { [$0] } ?? []
        remux.preferredSubtitleLanguages = PlaybackLanguagePreferences.preferredSubtitleLanguageCode.map { [$0] } ?? []
        remux.releaseHintsHDR = releaseHintsHDR
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
        // own picker. Fetched in parallel when the caller had none.
        if let media = media {
            if media.subtitles.isEmpty {
                // AVPlayer reads the master playlist once: hold `onReady` a
                // few seconds so the search can land in it. Assigning
                // `subtitles` (even []) releases the hold.
                remux.externalSubtitlesPending = true
                Self.searchSubtitles(for: media) { [weak remux] subtitles in
                    remux?.subtitles = subtitles
                }
            } else {
                remux.subtitles = media.subtitles
            }
        }
        // Started even while the resume question is up: the header gives the
        // exact time to show, an unplayable file goes to VLC without asking,
        // and « Reprendre du début » then starts at once.
        remux.start()
    }

    private func remuxDidBecomeReady(_ playlistURL: URL) {
        guard !isTornDown, !fallbackRequested else { return }
        if resumeChoicePending {
            pendingPlaylistURL = playlistURL
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
        if now.isFinite, now >= earliest { return true }
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
        BoundedStorageUX.logLimited(player: "AVPlayer", target: target, playhead: reference, landing: landing)
        player?.seek(to: CMTime(seconds: landing, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        showBoundedToast()
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

    /// OpenSubtitles search (SubtitlesManager directly — `Media.getSubtitles`
    /// lives in a tvOS-only extension). Completion on the main queue.
    static func searchSubtitles(for media: Media, completion: @escaping ([Subtitle]) -> Void) {
        if let episode = media as? Episode {
            SubtitlesManager.shared.search(episode, imdbId: episode.show?.id) { subtitles, _ in
                completion(subtitles)
            }
        } else {
            SubtitlesManager.shared.search(imdbId: media.id) { subtitles, _ in
                completion(subtitles)
            }
        }
    }

    // MARK: - Resume question (remux path, payload still downloading)

    /// Waits briefly (≤ 2.5 s) for the MKV header so the question can show
    /// the exact clock time, then asks.
    private func scheduleResumeQuestion(attempt: Int = 0) {
        guard resumeChoicePending, !fallbackRequested, !isTornDown else { return }
        let headerParsed = remux?.session?.isHeaderParsed ?? false
        guard headerParsed || attempt >= 10 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.scheduleResumeQuestion(attempt: attempt + 1)
            }
            return
        }
        presentResumeQuestion()
    }

    private func presentResumeQuestion() {
        guard resumeChoicePending, !fallbackRequested, !isTornDown, resumeAlert == nil else { return }
        let duration = remux?.session?.totalDurationSeconds ?? 0
        let position = ResumePolicy.resumeLabel(fraction: startPosition, durationSeconds: duration)
        let alert = UIAlertController(title: "Reprendre la lecture ?",
                                      message: "Ce fichier est encore en téléchargement : la reprise rapide passe par le lecteur VLC. "
                                        + "Depuis le début, la lecture reste native (HDR, Dolby Atmos).",
                                      preferredStyle: .alert)
        let resume = UIAlertAction(title: "Reprendre à \(position)", style: .default) { [weak self] _ in
            DispatchQueue.main.async { self?.resolveResumeChoice(resume: true) }
        }
        alert.addAction(resume)
        alert.addAction(UIAlertAction(title: "Reprendre du début", style: .default) { [weak self] _ in
            DispatchQueue.main.async { self?.resolveResumeChoice(resume: false) }
        })
        // Menu (tvOS) / Annuler: leave the player.
        alert.addAction(UIAlertAction(title: "Annuler", style: .cancel) { [weak self] _ in
            DispatchQueue.main.async { self?.cancelFromResumeQuestion() }
        })
        // Initial focus (tvOS) / emphasis (iOS) on « Reprendre ».
        alert.preferredAction = resume
        resumeAlert = alert
        loadingIndicator.stopAnimating()
        print("[Player] resume question: \(Int(startPosition * 100)) % (\(position)), payload still downloading")
        // On top of anything already presented over the player (AVKit sheet).
        var presenter: UIViewController = self
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        presenter.present(alert, animated: true)
    }

    private func resolveResumeChoice(resume: Bool) {
        guard resumeChoicePending, !fallbackRequested, !isTornDown else { return }
        resumeChoicePending = false
        resumeAlert = nil
        if resume {
            // Same stream, VLC at the saved position (playback never
            // started, so the hand-off resumes at `startPosition`) — the
            // user decided: VLC must not ask again.
            userChoseQuickResume = true
            requestFallback("Reprise rapide")
            return
        }
        print("[Player] resume declined — native playback from the beginning")
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
        loadingIndicator.stopAnimating()

        subtitleController?.attach(to: player)
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
    private func checkFarSeekTarget() {
        guard route == .remux, let remux = remux, let session = remux.session else {
            farTarget.reset()
            return
        }
        let target = isItemHealthy && playIntent.wantsPlayback ? heldSeek.target : nil
        let frontier = session.progress.mediaSeconds
        guard farTarget.shouldHandOff(target: target, frontierSeconds: frontier,
                                      downloadProgress: keepAliveStreamer?.torrentStatus.totalProgress ?? 1,
                                      remuxFinished: remux.isFinished, now: ProcessInfo.processInfo.systemUptime),
              let held = target else { return }
        print("[Player] seek to \(Int(held)) s held past the remux frontier (\(Int(frontier)) s): "
              + "~\(Int((farTarget.estimatedSecondsToTarget ?? 0).rounded())) s away at the download's pace — VLC there")
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
        var held = heldSeek.take()
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
            let finished = remux.session?.progress.finished ?? false
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
        } else if waiting {
            engineLine = "\(nativeEngineLine) — attente des données (téléchargement plus lent que la lecture)"
            loadingIndicator.startAnimating()
            bufferingLabel.isHidden = false
        } else {
            engineLine = nativeEngineLine
            if !isSeekingToStart { loadingIndicator.stopAnimating() }
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
    /// (the torrent fetches those pieces first). Remux: only reached with
    /// the payload fully on disk (otherwise the user was asked) — the
    /// requested segment is held by the server's long-poll while the remux
    /// pumps ahead to it.
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
        let target = Double(startPosition) * duration
        if !direct {
            let remuxed = remux?.session?.progress.mediaSeconds ?? 0
            print("[Player] remux at \(Int(remuxed)) s, payload on disk — pumping ahead to the resume point")
        }
        print("[Player] resuming at \(Int(target)) s (\(Int(startPosition * 100)) %)")
        isSeekingToStart = true
        startSeekTarget = target
        loadingIndicator.startAnimating()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            DispatchQueue.main.async {
                // Superseded when a starvation recovery took over the item.
                guard let self = self, self.isSeekingToStart, self.player?.currentItem === item else { return }
                self.isSeekingToStart = false
                self.startSeekTarget = nil
                self.loadingIndicator.stopAnimating()
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
                for track in await PlayerTrackSummary.load(from: item) where track.mediaType == .audio {
                    print("[Player] resolved audio track: '\(track.fourCC)' \(track.channels)ch")
                }
                // Output-side proof of Atmos on iOS: whether the current audio
                // route is actually rendering Spatial Audio (AirPods / built-in
                // speakers). `true` = the DD+/Atmos is being spatialized right now.
                for output in AVAudioSession.sharedInstance().currentRoute.outputs {
                    print("[Player] output '\(output.portName)' [\(output.portType.rawValue)] spatialAudioEnabled=\(output.isSpatialAudioEnabled)")
                }
            }
        }
    }

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
        var resume = currentResumeFraction()
        if let time = resumeTime, let fraction = fraction(ofPlayerTime: time) {
            resume = ResumePolicy.handOffFraction(reached: fraction)
        }
        // VLC asks « Reprendre / Depuis le début » unless the user chose
        // « Reprendre » here or was already watching.
        let decided = ResumePolicy.handOffResumeDecided(userChoseQuickResume: userChoseQuickResume,
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
        starvation.cancel()
        failureObserver?.invalidate()
        failureObserver = nil
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
        if !isHandingOff { saveProgress(status: .finished) }
        isTornDown = true
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        resumeChoicePending = false
        pendingPlaylistURL = nil
        statsTimer?.invalidate()
        statsTimer = nil
        stopNativePlayback()
        pendingFallback = nil
        if !isHandingOff {
            // tvOS deletes the stream's partial right away, as the VLC player
            // does (the app sandbox is small); iOS keeps it until the next
            // stream's purge. A completed download is never deleted.
#if os(tvOS)
            let wipe = !(keepAliveStreamer is PTTorrentDownload)
#else
            let wipe = false
#endif
            keepAliveStreamer?.cancelStreamingAndDeleteData(wipe)
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
        if let movie = media as? Movie {
            WatchedlistManager<Movie>.movie.setCurrentProgress(value, for: movie.id, with: status)
        } else if let episode = media as? Episode {
            WatchedlistManager<Episode>.episode.setCurrentProgress(value, for: episode.id, with: status)
        }
    }

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // A kill while suspended (or a crash later) keeps what was watched.
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
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
            loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
            loadingIndicator.color = .white
            loadingIndicator.hidesWhenStopped = true
            overlay.addSubview(loadingIndicator)
            // Download starvation: say why the picture is frozen.
            bufferingLabel.text = "Mise en mémoire tampon…\nLe téléchargement est plus lent que la lecture"
            bufferingLabel.numberOfLines = 2
            bufferingLabel.textAlignment = .center
            bufferingLabel.textColor = .white
            bufferingLabel.font = .preferredFont(forTextStyle: .callout)
            bufferingLabel.shadowColor = UIColor.black.withAlphaComponent(0.8)
            bufferingLabel.shadowOffset = CGSize(width: 0, height: 1)
            bufferingLabel.isHidden = true
            bufferingLabel.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(bufferingLabel)
            NSLayoutConstraint.activate([
                loadingIndicator.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                loadingIndicator.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                bufferingLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                bufferingLabel.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: 16),
                bufferingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                bufferingLabel.trailingAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            ])
            if player == nil && !fallbackRequested && !isTornDown { loadingIndicator.startAnimating() }
            if starvation.isRecovering { showStarvationIndicator(true) }
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
    /// far-target hand-off), high-water mark, the positions reported to the
    /// remux, the stuck-playback safety net, the one-time replacement of an
    /// item started on live EVENT playlists.
    private func statsTick() {
        noteKnownPosition()
        notePlayedPosition()
        noteHeldSeek(isJump: false)
        checkFarSeekTarget()
        refreshStats()
        noteHighWater()
        reportPlaybackPositions()
        checkStuckPlayback()
        checkDirectStall()
        checkBoundedReverseScan()
        rebuildLiveBornItemIfEnded()
    }

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
    /// time — measured: 0.0 —, AVPlayer moves it a few ms later); else
    /// `currentTime()` — the playhead, or a pending seek target. nil while
    /// unknown.
    private func wantedPosition() -> Double? {
        let time: Double?
        if starvation.isRecovering {
            time = starvation.resumeTime
        } else if isSeekingToStart, let target = startSeekTarget {
            time = target
        } else {
            time = player?.currentTime().seconds
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
    /// position, then VLC there. Never during a starvation recovery, before
    /// the remux has finished, in the background, over AirPlay or in
    /// Picture in Picture.
    private func checkStuckPlayback() {
        guard let player = player else { return }
        let remux = route == .remux ? self.remux : nil
        let eligible = remux?.isFinished == true && hasAppeared && !starvation.isRecovering && !fallbackRequested
            && !isTornDown && !isPictureInPictureActive && !player.isExternalPlaybackActive
            && UIApplication.shared.applicationState == .active
        guard let stuckAt = stuckWatch.note(time: player.currentTime().seconds, clock: ProcessInfo.processInfo.systemUptime,
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
        print("[Player] AVPlayer stuck at \(String(format: "%.3f", stuckAt)) s on a finished remux "
              + "(end zone from \(endZone.map { String(format: "%.3f", $0) } ?? "?") s) → \(action)")
        switch action {
        case .naturalEnd:
            player.pause()
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
        let eligible = hasAppeared && !starvation.isRecovering && !fallbackRequested && !isTornDown
            && !resumeChoicePending && !awaitingStartSeek && !isSeekingToStart && time.isFinite && time >= 0
            && !isPictureInPictureActive && !player.isExternalPlaybackActive
            && UIApplication.shared.applicationState == .active
        guard liveBornWatch.shouldRebuild(current: player.currentItem.map { ObjectIdentifier($0) },
                                          remuxFinished: remux.isFinished, isEligible: eligible) else { return }
        let playing = playIntent.wantsPlayback
        print("[Player] remux finished: replacing the item AVPlayer started on live EVENT playlists at "
              + "\(String(format: "%.3f", time)) s (\(playing ? "playing" : "paused"))")
        starvation.rebuildNow(player: player, at: time, reason: LiveBornItemWatch.reason,
                              resumesPlayback: playing, exactPosition: true)
    }

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

    private func refreshStats() {
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
            lines.append(contentsOf: remux.renditionSummary.map { "Piste   \($0)" })
            lines.append("Remux   \(remux.statsSummary)")
        }
        if let subtitles = subtitleController {
            lines.append("Subs    \(subtitles.selected?.language ?? "désactivés") · \(subtitles.available.count) dispo.")
        }
        if starvation.isRecovering, let time = starvation.resumeTime {
            if starvation.isRebuildingStuckItem {
                lines.append("Reprise lecture bloquée : nouvel élément à \(ResumePolicy.clockString(seconds: time))")
            } else if starvation.isWaitingForPlay {
                lines.append("Reprise en pause : nouvel élément à la lecture, à \(ResumePolicy.clockString(seconds: time))")
            } else {
                lines.append("Reprise attente des données à \(ResumePolicy.clockString(seconds: time)) · tentative "
                             + "\(starvation.attemptsWithoutProgress)/\(starvation.maxAttemptsWithoutProgress)")
            }
        } else if starvation.recoveryCount > 0 {
            lines.append("Reprise \(starvation.recoveryCount) famine(s) surmontée(s) en natif")
        }
        statsLabel.text = " " + lines.joined(separator: "\n ") + " "
    }

#if os(tvOS)
    // MARK: - Up Next (tvOS episodes)

    /// Proposes the next episode 30 s before the end — the native
    /// counterpart of the VLC player's "Up Next" (AVKit content proposal:
    /// the video keeps playing in a frame while a 30 s countdown runs).
    private func installUpNextIfNeeded(for item: AVPlayerItem) {
        guard nextEpisode != nil, onPlayNext != nil else { return }
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
        let proposal = AVContentProposal(contentTimeForTransition: CMTime(seconds: duration - 30, preferredTimescale: 600),
                                         title: UpNextProposalViewController.displayTitle(for: episode),
                                         previewImage: nil)
        // Our own countdown (UpNextProposalViewController), not AVKit's.
        proposal.automaticAcceptanceInterval = .nan
        item.nextContentProposal = proposal
        print("[Player] Up Next: S\(episode.season)E\(episode.episode) proposed at \(Int(duration - 30)) s")
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
#endif
}

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
                              timeToSeekAfterUserNavigatedFrom oldTime: CMTime, to targetTime: CMTime) -> CMTime {
        let target = targetTime.seconds
        guard !isTornDown, !fallbackRequested, let session = boundedStorage, session.isBounded,
              let reference = playedPosition.lastPlayedTime ?? (oldTime.seconds.isFinite ? oldTime.seconds : nil),
              let landing = BoundedStorageUX.limitedRewindTarget(target, from: reference, session: session) else {
            return targetTime
        }
        BoundedStorageUX.logLimited(player: "AVPlayer (navigation)", target: target, playhead: reference, landing: landing)
        showBoundedToast()
        return CMTime(seconds: landing, preferredTimescale: 600)
    }

    // "Up Next" (tvOS episodes).

    func playerViewController(_ playerViewController: AVPlayerViewController, shouldPresent proposal: AVContentProposal) -> Bool {
        guard let episode = nextEpisode, onPlayNext != nil, !isTornDown, !fallbackRequested, !didAcceptUpNext else {
            return false
        }
        playerViewController.contentProposalViewController = makeUpNextViewController(for: episode)
        return true
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, didAccept proposal: AVContentProposal) {
        // The card's own completion normally gets there first (once it is
        // hidden); this is the safety net.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.playNextEpisode()
        }
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, didReject proposal: AVContentProposal) {
        player?.currentItem?.nextContentProposal = nil
    }
#endif
}

#if os(tvOS)
/// tvOS "Up Next" card presented by AVKit 30 s before the end of an episode:
/// the current episode keeps playing in a frame at the top, the next one is
/// shown below with a countdown — like the VLC player's Up Next screen.
/// « Lire maintenant » or the end of the countdown → next episode;
/// « Revenir à la vidéo » → keep watching.
final class UpNextProposalViewController: AVContentProposalViewController {

    var onAccept: (() -> Void)?
    var onDefer: (() -> Void)?

    private let episode: Episode
    private var secondsLeft = 30
    private var countdownTimer: Timer?
    private var didFinish = false

    private let imageView = UIImageView()
    private let captionLabel = UILabel()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let summaryLabel = UILabel()
    private let countdownLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)

    init(episode: Episode) {
        self.episode = episode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// "S2 · É3 — Title" (proposal title, logs).
    static func displayTitle(for episode: Episode) -> String {
        let name = episode.title.isEmpty ? "Épisode \(episode.episode)" : episode.title
        return "S\(episode.season) · É\(episode.episode) — \(name)"
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
        return [playButton]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 12
        imageView.backgroundColor = UIColor(white: 1, alpha: 0.08)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor, multiplier: 16.0 / 9.0).isActive = true

        captionLabel.text = "Épisode suivant"
        captionLabel.font = .preferredFont(forTextStyle: .headline)
        captionLabel.textColor = UIColor(white: 1, alpha: 0.7)

        let name = episode.title.isEmpty ? "Épisode \(episode.episode)" : episode.title
        titleLabel.text = name
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2

        var details = "Saison \(episode.season) · Épisode \(episode.episode)"
        if let show = episode.show?.title, !show.isEmpty { details = show + " — " + details }
        detailLabel.text = details
        detailLabel.font = .preferredFont(forTextStyle: .callout)
        detailLabel.textColor = UIColor(white: 1, alpha: 0.7)

        let summary = episode.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        summaryLabel.text = summary == "No summary available.".localized ? "" : summary
        summaryLabel.font = .preferredFont(forTextStyle: .callout)
        summaryLabel.textColor = UIColor(white: 1, alpha: 0.85)
        // Fits below the shrunk player on a 1080-point screen.
        summaryLabel.numberOfLines = 3

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize,
                                                         weight: .semibold)
        countdownLabel.textColor = .white
        updateCountdownLabel()

        let textStack = UIStackView(arrangedSubviews: [captionLabel, titleLabel, detailLabel, summaryLabel, countdownLabel])
        textStack.axis = .vertical
        textStack.spacing = 10
        textStack.alignment = .leading
        textStack.setCustomSpacing(24, after: summaryLabel)

        playButton.setTitle("Lire maintenant", for: .normal)
        playButton.addTarget(self, action: #selector(playNow), for: .primaryActionTriggered)
        backButton.setTitle("Revenir à la vidéo", for: .normal)
        backButton.addTarget(self, action: #selector(backToVideo), for: .primaryActionTriggered)
        let buttonStack = UIStackView(arrangedSubviews: [playButton, backButton])
        buttonStack.axis = .vertical
        buttonStack.spacing = 24
        buttonStack.alignment = .fill

        let row = UIStackView(arrangedSubviews: [imageView, textStack, buttonStack])
        row.axis = .horizontal
        row.spacing = 48
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            // Below the shrunk player (7 % + 42 % × 9/16 × 16/9 of the height ≈ 49 %).
            NSLayoutConstraint(item: row, attribute: .top, relatedBy: .equal,
                               toItem: view, attribute: .bottom, multiplier: 0.56, constant: 0),
            row.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 40),
            row.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -40),
            row.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.24),
            buttonStack.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.26),
        ])
        loadImage()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startCountdown()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// 30 s, or what is left of the episode when less (auto-play as it
    /// ends, like the VLC player's countdown).
    private func startCountdown() {
        guard countdownTimer == nil, !didFinish else { return }
        if let player = playerViewController?.player, let item = player.currentItem {
            let remaining = item.duration.seconds - player.currentTime().seconds
            if remaining.isFinite { secondsLeft = min(30, max(5, Int(remaining.rounded()))) }
        }
        updateCountdownLabel()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.secondsLeft -= 1
            self.updateCountdownLabel()
            if self.secondsLeft <= 0 { self.finish(accept: true) }
        }
    }

    private func updateCountdownLabel() {
        countdownLabel.text = "Lecture automatique dans \(max(0, secondsLeft)) s"
    }

    private func loadImage() {
        guard let string = episode.largeBackgroundImage ?? episode.show?.largeBackgroundImage,
              let url = URL(string: string) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { self?.imageView.image = image }
        }.resume()
    }

    @objc private func playNow() {
        finish(accept: true)
    }

    @objc private func backToVideo() {
        finish(accept: false)
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

    static func dismantleUIViewController(_ vc: RemuxAVPlayerViewController, coordinator: ()) {
        // Removed from the hierarchy (cover closed, or the engine swapped to
        // VLC — the controller then keeps the torrent stream alive itself).
        vc.tearDown()
    }
}
#endif
