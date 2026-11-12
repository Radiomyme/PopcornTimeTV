

import SwiftUI
import AVKit
import PopcornKit

/// Wraps `AVPlayerViewController` so SwiftUI can present it full-screen —
/// the direct path for MP4 / M4V / MOV payloads (Matroska goes through the
/// remuxer, `RemuxPlayerView`). AVPlayer is the right call on iOS / iPadOS —
/// hardware HEVC, HDR10, Dolby Vision and Atmos rendering, AirPlay 4K,
/// picture-in-picture, and the standard transport controls.
///
/// Watches the item with `AVPlayerItemFailureObserver`: when AVFoundation
/// can't play the file (failed item, `hev1` HEVC, undecodable audio,
/// readiness timeout) `onFallback` fires once so the owner can swap in VLC.
/// Download starvation is not such a failure: when AVPlayer gives up on a
/// byte range the torrent hasn't fetched yet (FailedToPlayToEnd while
/// downloading), the player stays native — buffering indicator, then a new
/// item at the same time once more data exists (`PlaybackStarvationRecovery`;
/// a seek the user makes while it waits becomes that time, as does a seek —
/// the resume seek or the user's — AVPlayer still held when the item failed;
/// a rewind into what was already played resumes at once; a user who had
/// paused, or pauses while it waits, stays paused until they press play) —
/// and only falls back after repeated fruitless retries.
struct VideoPlayerWrapper: UIViewControllerRepresentable {
    let url: URL
    var title: String? = nil
    /// The movie / episode playing — its watched progress is saved on close,
    /// when playback is handed over to VLC, and as a checkpoint when the user
    /// pauses or the app goes to the background.
    var media: Media? = nil
    /// 0…1 position to resume at once the item is ready.
    var startPosition: Float = 0
    /// Seconds allowed to reach `.readyToPlay`; nil = no timeout.
    var readyTimeout: TimeInterval? = 30
    /// Asked when the timeout elapses: true = the bytes AVPlayer waits for
    /// are still downloading, grant more time (bounded). nil: derived from
    /// `downloadProgress` (< 1).
    var isWaitingForData: (() -> Bool)? = nil
    /// The torrent's `totalProgress` (0…1; 1 = complete). Lets a starved
    /// player wait for more data instead of falling back. nil = a complete
    /// / local file.
    var downloadProgress: (() -> Float)? = nil
    /// The stream's bounded storage (nil: none): AVPlayer's playhead tells
    /// the torrent what it may delete behind it.
    var boundedStorage: BoundedStorageSession? = nil
    /// The whole payload is on disk (bounded-aware: `isWholeFileOnDisk`);
    /// nil: `downloadProgress` reaching 1.
    var isPayloadComplete: (() -> Bool)? = nil
    /// The player was created (e.g. to attach a `SubtitleCueController`).
    var onPlayerReady: ((AVPlayer) -> Void)? = nil
    /// The player's item was rebuilt after download starvation (e.g. to
    /// rebind a `SubtitleCueController` to the new item's own subtitles).
    var onItemReplaced: ((AVPlayerItem) -> Void)? = nil
    /// AVFoundation can't play the payload: hand the stream over to VLC.
    /// `resumeFraction`: where playback got (at most
    /// `ResumePolicy.handOffMaxFraction`), else the start position;
    /// `resumeDecided`: playback had started (VLC continues without asking).
    /// The native part's progress is already saved when it runs.
    var onFallback: ((_ reason: String, _ resumeFraction: Float, _ resumeDecided: Bool) -> Void)? = nil
    /// Bounded storage: native playback can't go on and VLC can't resume
    /// where it would have to (that part of the torrent is deleted). The
    /// message was shown; the owner closes the player.
    var onCannotContinue: (() -> Void)? = nil

    /// Also the AVPlayerViewController's delegate: Picture in Picture state
    /// (AVKit calls it on the main thread).
    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        var onFallback: ((_ reason: String, _ resumeFraction: Float, _ resumeDecided: Bool) -> Void)?
        var onCannotContinue: (() -> Void)?
        /// The player's view controller (bounded storage's alert).
        private weak var playerController: AVPlayerViewController?
        var onItemReplaced: ((AVPlayerItem) -> Void)?
        var media: Media?
        /// The user's play / pause intent — what a starvation recovery ends
        /// in — and the pause checkpoint of the progress.
        private var playIntent = PlaybackIntentWatch()
        /// The player's rate changes, the app going to the background.
        private var observers: [NSObjectProtocol] = []
        /// Picture in Picture is on: playback goes on in the background.
        private var isPictureInPictureActive = false
        private var failureObserver: AVPlayerItemFailureObserver?
        private var startObservations: [NSKeyValueObservation] = []
        private weak var player: AVPlayer?
        private var startPosition: Float = 0
        /// The saved position this session opened at (0 = none / finished):
        /// protected from a smaller fraction (`ResumePolicy`).
        private var resumePoint: Float = 0
        /// Furthest position (0…1) reached during this session.
        private var highWater: Float = 0
        private var timeObserver: Any?
        private var didFallBack = false
        private var didStart = false

        /// Starvation recovery: what to rebuild, how to tell new data came.
        private var url: URL?
        private var title: String?
        private var readyTimeout: TimeInterval?
        private var isWaitingForData: (() -> Bool)?
        private var downloadProgress: (() -> Float)?
        /// Bounded storage (`VideoPlayerWrapper.boundedStorage`): the whole
        /// payload on disk, and the stream's session.
        var isPayloadComplete: (() -> Bool)?
        var boundedStorage: BoundedStorageSession?
        /// Bounded storage: the forward buffer AVPlayer may keep over the
        /// torrent's file, and how far past the playhead it may have read.
        static let boundedForwardBufferSeconds: Double = 60
        static let boundedReadAheadSeconds: Double = 75
        private lazy var starvation: PlaybackStarvationRecovery = makeStarvationRecovery()
        private var lastKnownTime: Double?
        private var lastKnownDuration: Double?
        /// Last position playback actually reached (periodic observer) —
        /// never a held seek target.
        private var playedPosition = PlayedPositionTracker()
        /// The user's seek target AVPlayer still holds (past the download):
        /// what a failure during the hold recovers — or hands VLC — instead
        /// of the reset `currentTime()`.
        private var heldSeek = HeldSeekWatch()
        /// Target of the resume seek in flight (player timeline, s): a seek
        /// AVPlayer may hold too.
        private var startSeekTarget: Double?
        /// Bounded storage: AVPlayer waiting with the data on disk (sampled
        /// 1 Hz by `directStallTimer`: the periodic time observer does not fire
        /// while the item's time stands still) → the item is rebuilt
        /// (`checkDirectStall`).
        private var directStall = BoundedDirectStallWatch()
        private var directStallTimer: Timer?
        private weak var indicator: UIActivityIndicatorView?
        private weak var bufferingLabel: UILabel?
        /// The player's content overlay (bounded storage's message).
        private weak var overlayView: UIView?
        /// The pending check after a burst of time jumps (`scheduleBoundedRewindCheck`).
        private var boundedRewindCheck: DispatchWorkItem?

        func start(player: AVPlayer, item: AVPlayerItem, url: URL, title: String?, startPosition: Float,
                   readyTimeout: TimeInterval?, isWaitingForData: (() -> Bool)?, downloadProgress: (() -> Float)?) {
            self.player = player
            self.url = url
            self.title = title
            self.readyTimeout = readyTimeout
            self.downloadProgress = downloadProgress
            if let isWaitingForData = isWaitingForData {
                self.isWaitingForData = isWaitingForData
            } else if let complete = isPayloadComplete {
                self.isWaitingForData = { !complete() }
            } else if let progress = downloadProgress {
                self.isWaitingForData = { !StarvationPolicy.isComplete(progress: progress()) }
            }
            if let session = boundedStorage {
                directStallTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                    guard let self = self else { timer.invalidate(); return }
                    MainActor.assumeIsolated {
                        self.checkDirectStall()
                        self.checkBoundedReverseScan()
                    }
                }
                // AVPlayer reads through PopcornTorrent's server (which moves
                // the window); its playhead tells the torrent what it may
                // delete behind it.
                if session.isBounded { item.preferredForwardBufferDuration = Self.boundedForwardBufferSeconds }
                session.attachHTTPPlayer(self, readAheadSeconds: Self.boundedReadAheadSeconds) { [weak self] in
                    guard let self = self, !self.didFallBack, let player = self.player,
                          player.currentItem?.status == .readyToPlay else { return nil }
                    let time = player.currentTime().seconds
                    guard time.isFinite else { return nil }
                    return BoundedPlayerSample(time: time, isPlaying: player.timeControlStatus == .playing)
                }
            }
            // A finished (or nearly finished) title restarts from the beginning.
            self.startPosition = ResumePolicy.startPosition(forSavedProgress: startPosition)
            resumePoint = self.startPosition
            installFailureObserver(on: item)
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600),
                                                          queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.noteKnownPosition()
                    self?.notePlayedPosition()
                    self?.noteHeldSeek(isJump: false)
                    self?.noteHighWater()
                }
            }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player,
                                                queue: .main) { [weak self] note in
                let reason = note.userInfo?[AVPlayer.rateDidChangeReasonKey] as? AVPlayer.RateDidChangeReason
                MainActor.assumeIsolated { self?.playerRateDidChange(reason: reason) }
            })
            // A time jump of the current item (a seek that landed): the held
            // seek target follows.
            observers.append(center.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: nil,
                                                queue: .main) { [weak self] note in
                let jumped = note.object as AnyObject?
                MainActor.assumeIsolated {
                    guard let self = self, let item = self.player?.currentItem, jumped === item else { return }
                    self.noteHeldSeek(isJump: true)
                    self.scheduleBoundedRewindCheck()
                }
            })
            // A kill while suspended (or a crash later) keeps what was watched.
            observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidEnterBackground() }
            })

            guard self.startPosition > 0 else {
                didStart = true
                player.play()
                return
            }
            // Resume: seek once the item is ready and its duration known,
            // then play (byte-range requests make the torrent fetch that
            // part first).
            let handler: (AVPlayerItem) -> Void = { [weak self] observed in
                DispatchQueue.main.async { self?.seekToStartIfPossible(observed) }
            }
            startObservations = [
                item.observe(\.status, options: [.initial, .new]) { observed, _ in handler(observed) },
                item.observe(\.duration, options: [.initial, .new]) { observed, _ in handler(observed) },
            ]
            // Never let a resume block playback (the saved point is then
            // kept: `saveProgressIfNeeded` won't replace it with less).
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                guard let self = self, !self.didStart, !self.didFallBack, !self.starvation.isRecovering else { return }
                self.startObservations.forEach { $0.invalidate() }
                self.startObservations = []
                self.didStart = true
                self.player?.play()
            }
        }

        /// The player item for `url` (title metadata, spatialized audio) —
        /// also how the starvation recovery rebuilds it.
        static func makeItem(url: URL, title: String?) -> AVPlayerItem {
            let item = AVPlayerItem(url: url)
            // Spatialize multichannel (5.1 + Atmos objects) on AirPods / speakers.
            item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
            if let title = title, !title.isEmpty {
                let titleItem = AVMutableMetadataItem()
                titleItem.identifier = .commonIdentifierTitle
                titleItem.value = title as NSString
                titleItem.extendedLanguageTag = "und"
                item.externalMetadata = [titleItem]
            }
            return item
        }

        /// Spinner + "Mise en mémoire tampon…" over the video, shown while
        /// recovering from download starvation.
        func installIndicator(in controller: AVPlayerViewController) {
            playerController = controller
            guard let overlay = controller.contentOverlayView, indicator == nil else { return }
            overlayView = overlay
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.color = .white
            spinner.hidesWhenStopped = true
            spinner.translatesAutoresizingMaskIntoConstraints = false
            let label = UILabel()
            label.text = "Mise en mémoire tampon…\nLe téléchargement est plus lent que la lecture"
            label.numberOfLines = 2
            label.textAlignment = .center
            label.textColor = .white
            label.font = .preferredFont(forTextStyle: .callout)
            label.shadowColor = UIColor.black.withAlphaComponent(0.8)
            label.shadowOffset = CGSize(width: 0, height: 1)
            label.isHidden = true
            label.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(spinner)
            overlay.addSubview(label)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 20),
                label.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -20),
            ])
            indicator = spinner
            bufferingLabel = label
        }

        /// `isReplacement`: an item rebuilt by the starvation recovery — no
        /// readiness timeout here, the recovery gives it 30 s (no
        /// extensions) itself.
        private func installFailureObserver(on item: AVPlayerItem, isReplacement: Bool = false) {
            failureObserver?.invalidate()
            let observer = AVPlayerItemFailureObserver(item: item, readyTimeout: isReplacement ? nil : readyTimeout,
                                                       onReport: { [weak self] failure in
                self?.handleFailure(failure)
            })
            if !isReplacement { observer.shouldExtendReadyTimeout = isWaitingForData }
            failureObserver = observer
        }

        private func seekToStartIfPossible(_ item: AVPlayerItem) {
            guard !didStart, !didFallBack, let player = player, player.currentItem === item,
                  item.status == .readyToPlay else { return }
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else { return }
            didStart = true
            startObservations.forEach { $0.invalidate() }
            startObservations = []
            let target = Double(startPosition) * duration
            print("[Player] resuming at \(Int(target)) s (\(Int(startPosition * 100)) %)")
            startSeekTarget = target
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
                DispatchQueue.main.async {
                    // Also called (`finished` false) when the item failed during
                    // the seek, after the failure was handled: a recovery or the
                    // VLC hand-off has taken over then — playing the dead item
                    // would read as the user's play press.
                    guard let self = self, self.startSeekTarget != nil else { return }
                    self.startSeekTarget = nil
                    guard !self.didFallBack, !self.starvation.isRecovering, self.player?.currentItem === item else { return }
                    self.player?.play()
                }
            }
        }

        // MARK: - Play intent, progress checkpoints

        /// The current item plays normally: playback started, no recovery
        /// running (it pauses and plays the player itself), not handed off,
        /// the item not failed nor its failure reported.
        private var isItemHealthy: Bool {
            guard let item = player?.currentItem else { return false }
            return didStart && !didFallBack && !starvation.isRecovering && item.status != .failed
                && failureObserver?.hasReportedFailure != true
        }

        /// A rate change of the player: the user's play / pause intent and,
        /// on the user's pause, a progress checkpoint (`PlaybackIntentWatch`).
        /// Only on a healthy item (`isItemHealthy`); the user's play / pause
        /// on a dead item while a recovery waits reaches the intent through
        /// the recovery (`onUserPlaybackChanged`).
        private func playerRateDidChange(reason: AVPlayer.RateDidChangeReason?) {
            guard let player = player else { return }
            let item = player.currentItem
            guard playIntent.noteRateChange(rate: player.rate, reason: reason, isHealthy: isItemHealthy,
                                            canCheckpoint: item?.status == .readyToPlay) else { return }
            print("[Player] paused by the user — progress checkpoint")
            saveProgressIfNeeded(status: .paused)
        }

        /// Periodic observer and every time jump of a healthy item, the resume
        /// seek done: the user's seek target AVPlayer holds, if any
        /// (`HeldSeekWatch`: `currentTime()` far from the last played position).
        private func noteHeldSeek(isJump: Bool) {
            guard isItemHealthy, startSeekTarget == nil, let player = player else { return }
            heldSeek.note(wanted: player.currentTime().seconds, played: playedPosition.lastPlayedTime, isJump: isJump)
        }

        // MARK: - Bounded storage: rewinds

        /// Bounded storage, 1 Hz (periodic observer): AVPlayer waiting for 8 s
        /// at the same time while the data ahead of the server's read position
        /// is on disk is not waiting for the download — macOS AVPlayer's loader
        /// stops requesting after a far seek's back-fill reached deleted data
        /// (part-3 coverage md2–md5); iOS AVPlayer is untested. The item is
        /// rebuilt at the playhead (`BoundedDirectStallWatch`). Full mode:
        /// never.
        private func checkDirectStall() {
            guard let player = player else { return }
            let isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                && player.currentItem?.status == .readyToPlay
            let eligible = isWaiting && isItemHealthy && didStart && startSeekTarget == nil
                && UIApplication.shared.applicationState == .active
                && boundedStorage?.isBounded == true && boundedStorage?.hasDataAheadOfReader() == true
            guard let time = directStall.note(time: player.currentTime().seconds, clock: ProcessInfo.processInfo.systemUptime,
                                              isWaiting: isWaiting, isEligible: eligible) else { return }
            print("[Player] bounded direct route: AVPlayer waiting at \(String(format: "%.1f", time)) s for "
                  + "\(Int(BoundedDirectStallWatch.stallSeconds)) s with the data on disk → rebuilding the item")
            starvation.rebuildNow(player: player, at: time, reason: BoundedDirectStallWatch.reason)
        }

        /// Bounded storage (`boundedStorage.isBounded`; nothing in full mode):
        /// after a time jump of a healthy item (AVKit's scrubber or ±10 s, a
        /// remote command), a playhead that went further back than what is
        /// still on disk goes to the earliest point still available, with the
        /// message — the user's decision: no new download, no VLC for a
        /// rewind. Checked 0.35 s after the last jump of a burst: a drag on
        /// the timeline (which seeks all along) is not fought.
        private func scheduleBoundedRewindCheck() {
            guard boundedStorage?.isBounded == true else { return }
            boundedRewindCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.checkBoundedRewind() }
            }
            boundedRewindCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        /// Bounded storage, 1 Hz (`directStallTimer`): a reverse scan (a held
        /// rewind) stops at the earliest point still available, with the
        /// message, and plays on from there (`BoundedStorageUX.reverseScanLimit`).
        private func checkBoundedReverseScan() {
            guard isItemHealthy, startSeekTarget == nil, !didFallBack, let player = player else { return }
            let now = player.currentTime().seconds
            guard let landing = BoundedStorageUX.reverseScanLimit(time: now, rate: player.rate,
                                                                  playedReference: playedPosition.lastPlayedTime,
                                                                  session: boundedStorage) else { return }
            player.rate = BoundedStorageUX.resumeRate(after: player)
            BoundedStorageUX.logLimited(player: "AVPlayer (direct)", target: now,
                                        playhead: playedPosition.lastPlayedTime ?? now, landing: landing)
            player.seek(to: CMTime(seconds: landing, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if let overlay = overlayView {
                BoundedStorageToastView.show(BoundedStorageUX.rewindLimitedMessage(for: boundedStorage), in: overlay)
            }
        }

        private func checkBoundedRewind() {
            guard isItemHealthy, startSeekTarget == nil, let player = player else { return }
            let now = player.currentTime().seconds
            // From the last position playback actually reached (not a seek
            // target AVPlayer still holds).
            guard let reference = playedPosition.lastPlayedTime,
                  let landing = BoundedStorageUX.limitedRewindTarget(now, from: reference, session: boundedStorage) else { return }
            BoundedStorageUX.logLimited(player: "AVPlayer (direct)", target: now, playhead: reference, landing: landing)
            player.seek(to: CMTime(seconds: landing, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if let overlay = overlayView {
                BoundedStorageToastView.show(BoundedStorageUX.rewindLimitedMessage(for: boundedStorage), in: overlay)
            }
        }

        /// The app went to the background: progress checkpoint, by the
        /// close's rules — `.watching` when playback goes on in Picture in
        /// Picture or over AirPlay, else `.paused`.
        private func applicationDidEnterBackground() {
            guard !didFallBack, let player = player else { return }
            let status = playIntent.backgroundCheckpointStatus(isPictureInPictureActive: isPictureInPictureActive,
                                                               isExternalPlaybackActive: player.isExternalPlaybackActive)
            print("[Player] app in the background — progress checkpoint (\(status))")
            saveProgressIfNeeded(status: status == .watching ? .watching : .paused)
        }

        // MARK: - Picture in Picture (AVPlayerViewControllerDelegate)

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

        // MARK: - Failures: starvation → stay native, else VLC

        /// A recovery's failure that ends on VLC hands it the target the user
        /// picked during the wait, if any (also before playback started); a
        /// failure during a seek AVPlayer still held recovers — or hands VLC
        /// — that seek's target (the resume seek's, or the user's as a user
        /// target): AVPlayer reset `currentTime()` to before it.
        private func handleFailure(_ failure: AVPlayerItemFailureObserver.Failure) {
            guard !didFallBack else { return }
            // Taken either way; a recovery in progress has its own target.
            var held = heldSeek.take()
            if starvation.isRecovering { held = nil }
            // Read before `handle`, which clears it when it ends the recovery.
            let userTarget = (starvation.resumeTimeIsUserTarget ? starvation.resumeTime : nil) ?? held
            if let player = player, let progress = downloadProgress {
                let atFailure = progress()
                let target = recoveryPosition(held: held)
                let stood = playbackPosition()
                // Failed before the resume seek was issued (item not ready,
                // duration unknown): the rebuilt item resumes at the saved
                // point once its duration is known — not at 0.
                let pendingStart: Float? = !didStart && startPosition > 0 ? startPosition : nil
                // Ready: a position already played before the failure (a
                // user rewind during the wait), else more torrent bytes.
                if starvation.handle(failure, player: player, position: target.position,
                                     resumeFraction: pendingStart,
                                     resumesPlayback: playIntent.wantsPlayback,
                                     positionIsUserTarget: target.isUserTarget,
                                     stillDownloading: !(isPayloadComplete?() ?? StarvationPolicy.isComplete(progress: atFailure)),
                                     isDataReady: { [weak self] time, waited in
                                         // Bounded storage: a position whose data is gone never
                                         // gets ready (the recovery waits for the one
                                         // `positionUnavailable` moved it to).
                                         if let session = self?.boundedStorage, session.isBounded,
                                            !session.canSeek(to: time, fromPlayerTime: stood) { return false }
                                         // The whole file on disk (bounded-aware), else more of it.
                                         if self?.isPayloadComplete?() == true { return true }
                                         return StarvationPolicy.directDataReady(resumeTime: time, failurePosition: stood,
                                                                                 progress: progress(), progressAtFailure: atFailure,
                                                                                 waited: waited)
                                     }) {
                    // The recovery seeks and plays itself.
                    startObservations.forEach { $0.invalidate() }
                    startObservations = []
                    startSeekTarget = nil
                    return
                }
            }
            fallBack(failure.reason, resumeTime: userTarget)
        }

        /// Where playback stood when the item failed (player timeline, s).
        private func playbackPosition() -> Double {
            if let time = player?.currentTime().seconds, time.isFinite, time > 0 { return time }
            if !didStart, let duration = lastKnownDuration, startPosition > 0 { return Double(startPosition) * duration }
            return lastKnownTime ?? 0
        }

        /// Where to recover after the item failed (player timeline, s): the
        /// resume seek's target while it is in flight, the user's seek target
        /// AVPlayer still held (`held`, `isUserTarget`) — `currentTime()` now
        /// reads where playback was before either —, else where playback
        /// stood.
        private func recoveryPosition(held: Double?) -> (position: Double, isUserTarget: Bool) {
            if let target = startSeekTarget { return (target, false) }
            if let target = held { return (target, true) }
            return (playbackPosition(), false)
        }

        /// Periodic observer: the last position playback actually reached
        /// (`PlayedPositionTracker`) — never a held seek target.
        private func notePlayedPosition() {
            guard let player = player else { return }
            playedPosition.note(time: player.currentTime().seconds, clock: ProcessInfo.processInfo.systemUptime,
                                isPlaying: player.timeControlStatus == .playing,
                                isItemReady: player.currentItem?.status == .readyToPlay,
                                isRecovering: starvation.isRecovering)
        }

        private func makeStarvationRecovery() -> PlaybackStarvationRecovery {
            let recovery = PlaybackStarvationRecovery()
            recovery.onWaitingChanged = { [weak self] waiting in
                if waiting { self?.indicator?.startAnimating() } else { self?.indicator?.stopAnimating() }
                self?.bufferingLabel?.isHidden = !waiting
            }
            recovery.makeItem = { [weak self] in
                guard let self = self, !self.didFallBack, let url = self.url else { return nil }
                let item = Self.makeItem(url: url, title: self.title)
                if self.boundedStorage?.isBounded == true { item.preferredForwardBufferDuration = Self.boundedForwardBufferSeconds }
                return item
            }
            recovery.onItemReplaced = { [weak self] item, restoresSelection in
                guard let self = self else { return }
                self.installFailureObserver(on: item, isReplacement: true)
                if !restoresSelection { PlaybackLanguagePreferences.applyPreferredMediaSelection(to: item) }
                self.onItemReplaced?(item)
            }
            // Bounded storage: the user moved the dead item further back than
            // what is still on disk — it goes to the earliest point still
            // available (with the message), never VLC there. Full mode:
            // never unavailable (the torrent keeps the whole file), as before.
            recovery.positionUnavailable = { [weak self] seconds in
                guard let self = self, let session = self.boundedStorage, session.isBounded,
                      let reference = self.playedPosition.lastPlayedTime, seconds < reference,
                      let landing = BoundedStorageUX.limitedRewindTarget(seconds, from: reference, session: session)
                else { return false }
                BoundedStorageUX.logLimited(player: "AVPlayer (direct, recovering)", target: seconds, playhead: reference,
                                            landing: landing)
                self.player?.seek(to: CMTime(seconds: landing, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if let overlay = self.overlayView {
                    BoundedStorageToastView.show(BoundedStorageUX.rewindLimitedMessage(for: session), in: overlay)
                }
                return false
            }
            recovery.onResumed = { [weak self] _ in
                guard let self = self, !self.didFallBack else { return }
                self.didStart = true
                self.player?.play()
            }
            recovery.onGiveUp = { [weak self] reason in
                // At the position being recovered — explicitly when the user
                // picked it during the wait, which also holds before playback
                // ever started (else the configured start position would win).
                guard let self = self else { return }
                self.fallBack(reason, resumeTime: self.starvation.resumeTimeIsUserTarget ? self.starvation.resumeTime : nil)
            }
            // The user's play / pause on the dead item during the wait: the
            // play intent follows (`playerRateDidChange` ignores a recovering
            // player).
            recovery.onUserPlaybackChanged = { [weak self] playing in
                self?.playIntent.noteUserPlayback(playing: playing)
            }
            return recovery
        }

        /// 0…1 position: while a starvation recovery runs, the position it
        /// recovers (the user's new target after a seek during the wait);
        /// else the player's; else — once a recovery gave up — the position
        /// it was recovering; else the last position read from a ready item
        /// (NaN-safe).
        private func knownPlaybackFraction() -> Float? {
            if starvation.isRecovering, let time = starvation.resumeTime { return fraction(ofPlayerTime: time) }
            if let fraction = AVPlayerItemFailureObserver.playbackFraction(of: player) { return fraction }
            guard let time = starvation.abandonedTime ?? lastKnownTime else { return nil }
            return fraction(ofPlayerTime: time)
        }

        /// 0…1 share of the movie at `time` (player timeline): the ready
        /// item's duration, else the last one seen.
        private func fraction(ofPlayerTime time: Double) -> Float? {
            var duration = player?.currentItem?.duration.seconds ?? .nan
            if !duration.isFinite || duration <= 0 { duration = lastKnownDuration ?? .nan }
            return ResumePolicy.fraction(time: time, duration: duration)
        }

        /// VLC continues where playback got (clamped to
        /// `ResumePolicy.handOffMaxFraction`: a failure in the end credits
        /// doesn't restart the movie), else at the start position;
        /// `resumeTime` (player timeline, s), an explicit target — the user's,
        /// picked during a recovery's wait —, wins over both. The
        /// native part is saved first, same rules as at close (`.watching`:
        /// VLC goes on): a VLC crash, kill or immediate close never loses
        /// it, and the VLC player protects what was saved here.
        private func fallBack(_ reason: String, resumeTime: Double? = nil) {
            guard !didFallBack else { return }
            // Bounded storage: VLC reads the torrent's file — never where it
            // was deleted (HTTP 410: VLC stops for good). At the last played
            // position instead when that is still there, else the player
            // closes with the message (tvOS / macOS `boundedHandOff`;
            // verify-playback 4).
            var resumeTime = resumeTime
            switch boundedHandOff(resumeTime: resumeTime) {
            case .asked: break
            case .at(let time): resumeTime = time
            case .end:
                endPlaybackForBoundedStorage(reason)
                return
            }
            var resume = startPosition
            if didStart, let fraction = knownPlaybackFraction(), fraction > 0.001 {
                resume = ResumePolicy.handOffFraction(reached: fraction)
            }
            if let time = resumeTime, let fraction = fraction(ofPlayerTime: time) {
                resume = ResumePolicy.handOffFraction(reached: fraction)
            }
            let decided = ResumePolicy.handOffResumeDecided(userChoseQuickResume: false, playbackStarted: didStart)
            // While `didFallBack` is still false (the save requires it).
            saveProgressIfNeeded(status: .watching)
            didFallBack = true
            invalidate()
            player?.pause()
            onFallback?(reason, resume, decided)
        }

        /// Bounded storage: where a hand-off to VLC may resume (see `fallBack`).
        private enum BoundedHandOff { case asked, at(Double), end }

        private func boundedHandOff(resumeTime: Double?) -> BoundedHandOff {
            guard didStart, let session = boundedStorage, session.isBounded, player != nil else { return .asked }
            let current: Double? = {
                if starvation.isRecovering, let time = starvation.resumeTime { return time }
                if let player = player, player.currentItem?.status == .readyToPlay {
                    let time = player.currentTime().seconds
                    if time.isFinite, time >= 0 { return time }
                }
                return starvation.abandonedTime ?? lastKnownTime
            }()
            guard let wanted = resumeTime ?? current, !session.canResumeOverHTTP(atPlayerSeconds: wanted) else { return .asked }
            if let played = playedPosition.lastPlayedTime, played > wanted, session.canResumeOverHTTP(atPlayerSeconds: played) {
                print("[Bounded] VLC can't resume at \(Int(wanted)) s (deleted) — at the last played position \(Int(played)) s")
                return .at(played)
            }
            print("[Bounded] VLC can't resume at \(Int(wanted)) s: that part of the torrent is deleted")
            return .end
        }

        /// Bounded storage: native playback can't go on and VLC can't resume
        /// where it would have to (deleted): say so, then the owner closes the
        /// player (the stream is cancelled as at any close).
        private func endPlaybackForBoundedStorage(_ reason: String) {
            print("[Bounded] native playback unavailable (\(reason)) and its data is deleted — closing the player")
            saveProgressIfNeeded()
            didFallBack = true
            invalidate()
            player?.pause()
            let close = onCannotContinue
            guard let presenter = playerController, presenter.presentedViewController == nil else {
                close?()
                return
            }
            let alert = UIAlertController(title: BoundedStorageUX.cannotContinueTitle,
                                          message: BoundedStorageUX.cannotContinueMessage, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK".localized, style: .cancel) { _ in close?() })
            presenter.present(alert, animated: true)
        }

        /// Periodic observer (1 Hz while playing, and on time jumps):
        /// position / duration of a ready item — while a starvation recovery
        /// runs, the position it recovers.
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

        private func noteHighWater() {
            guard didStart, let fraction = knownPlaybackFraction() else { return }
            highWater = max(highWater, fraction)
        }

        /// Watched progress (local + Trakt scrobble), same semantics as the
        /// other players, so "resume" works whichever engine played it —
        /// but the saved resume point is never replaced by a smaller
        /// fraction unless the user watched past it this session. NaN-safe:
        /// no fraction (unknown duration) = nothing saved. At close
        /// (`.finished`), at the hand-off to VLC (`.watching`), and as a
        /// checkpoint when the user pauses or the app goes to the background
        /// (`.paused` / `.watching`); never once VLC took over (it saves the
        /// rest).
        func saveProgressIfNeeded(status: Trakt.WatchedStatus = .finished) {
            guard didStart, !didFallBack, let media = media, let fraction = knownPlaybackFraction() else { return }
            noteHighWater()
            guard let value = ResumePolicy.progressToSave(current: fraction, resumePoint: resumePoint,
                                                          highWater: highWater, userRestarted: false) else {
                print("[Player] progress \(Int(fraction * 100)) % not saved — keeps the resume point at \(Int(resumePoint * 100)) %")
                return
            }
            if let movie = media as? Movie {
                WatchedlistManager<Movie>.movie.setCurrentProgress(value, for: movie.id, with: status)
            } else if let episode = media as? Episode {
                WatchedlistManager<Episode>.episode.setCurrentProgress(value, for: episode.id, with: status)
            }
        }

        func invalidate() {
            boundedRewindCheck?.cancel()
            directStallTimer?.invalidate()
            directStallTimer = nil
            boundedStorage?.detachHTTPPlayer(self)
            starvation.cancel()
            failureObserver?.invalidate()
            failureObserver = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            startObservations.forEach { $0.invalidate() }
            startObservations = []
            if let token = timeObserver {
                player?.removeTimeObserver(token)
                timeObserver = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // Long-form movie audio session: required for multichannel / Dolby
        // Atmos output (otherwise the session stays in a stereo-downmixing
        // default and AirPlay receivers / AirPods get 2.0).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = Coordinator.makeItem(url: url, title: title)
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = true
        PlaybackLanguagePreferences.applyPreferredMediaSelection(to: item)

        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        // Picture in Picture state (the background checkpoint's status).
        vc.delegate = context.coordinator

        context.coordinator.onFallback = onFallback
        context.coordinator.onCannotContinue = onCannotContinue
        context.coordinator.onItemReplaced = onItemReplaced
        context.coordinator.media = media
        context.coordinator.isPayloadComplete = isPayloadComplete
        context.coordinator.boundedStorage = boundedStorage
        context.coordinator.installIndicator(in: vc)
        context.coordinator.start(player: player, item: item, url: url, title: title, startPosition: startPosition,
                                  readyTimeout: readyTimeout, isWaitingForData: isWaitingForData,
                                  downloadProgress: downloadProgress)
        onPlayerReady?(player)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.onFallback = onFallback
        context.coordinator.onCannotContinue = onCannotContinue
        context.coordinator.onItemReplaced = onItemReplaced
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.saveProgressIfNeeded()
        coordinator.invalidate()
        vc.player?.pause()
        // Release the HTTP connection to the torrent's local server.
        vc.player?.replaceCurrentItem(with: nil)
        vc.player = nil
    }
}
