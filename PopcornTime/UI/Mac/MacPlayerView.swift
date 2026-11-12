

import SwiftUI
import AVKit
import Combine
import PopcornKit
import PopcornTorrent

/// Native macOS player: torrent stream → (remux | direct) → AVKit
/// `AVPlayerView`, VLC only as an automatic fallback. Because this is a REAL
/// Mac app (not iOS-on-Mac), macOS spatializes the E-AC-3/JOC audio itself —
/// Dolby Atmos renders on built-in speakers and AirPods, which the
/// "Designed for iPad" build never could.
///
/// One sheet, possibly several streams: « Choose another source » (a source
/// that does not answer) shows the title's other releases in the sheet
/// itself, and « Lighter version » (a download slower than the video)
/// replaces the stream by a lighter release at the same position — each
/// time a new `MacPlayerSession` (a new controller and stream) takes over.
struct MacPlayerView: View {
    let playback: MacPendingPlayback
    @Environment(\.dismiss) private var dismiss
    /// The stream playing now: `playback`, then the release the user switched to.
    @State private var current: MacPendingPlayback?
    /// « Choose another source »: the releases offered (the dead one left out).
    @State private var choosing: [Torrent]?
    /// The sources that did not answer in this sheet (`MagnetLink.sourceKey`):
    /// never offered again here.
    @State private var unanswered: Set<String> = []

    var body: some View {
        let active = current ?? playback
        Group {
            if let torrents = choosing {
                MacQualityPickerSheet(title: active.title, torrents: torrents) { torrent in
                    choosing = nil
                    guard let torrent else { return dismiss() }
                    print("[Player] another source chosen: \(torrent.quality ?? "?")")
                    current = MacPendingPlayback(torrent: torrent, media: active.media, title: active.title,
                                                 sources: active.knownSources)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if DEBUG
                .onAppear { MacDebugHooks.snapshotPlayerWindow(named: "choose-source", after: 1) }
                #endif
            } else {
                MacPlayerSession(playback: active,
                                 alternatives: alternatives(to: active),
                                 onChooseAnotherSource: { failed in
                                     print("[Player] choose another source (instead of \(failed.quality ?? "?"))")
                                     unanswered.insert(MagnetLink.sourceKey(of: failed.url))
                                     choosing = alternatives(to: active)
                                 },
                                 onSwitch: { torrent, fraction in
                                     current = MacPendingPlayback(torrent: torrent, media: active.media, title: active.title,
                                                                  sources: active.knownSources, startFraction: fraction)
                                 })
                    // A new stream for each release: a new controller.
                    .id(active.id)
            }
        }
    }

    /// The other releases of the title, best first: not the one playing,
    /// nor one that did not answer in this sheet. Runtimes attached
    /// (`knownSources`): the picker shows bitrates and warnings, and its
    /// recommendation weighs them.
    private func alternatives(to playback: MacPendingPlayback) -> [Torrent] {
        let playing = MagnetLink.sourceKey(of: playback.torrent.url)
        return playback.knownSources.filter {
            let key = MagnetLink.sourceKey(of: $0.url)
            return key != playing && !unanswered.contains(key)
        }.sorted(by: >)
    }
}

/// One stream in the player sheet.
private struct MacPlayerSession: View {
    let playback: MacPendingPlayback
    /// The title's other releases (« Choose another source » shows only
    /// when there is one).
    let alternatives: [Torrent]
    let onChooseAnotherSource: (Torrent) -> Void
    /// Plays a lighter release from a position (0…1) instead of this stream.
    let onSwitch: (Torrent, Float) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller = MacPlayerController()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let vlcURL = controller.vlcURL {
                // Resumes where the native player stopped.
                MacVLCPlayerView(url: vlcURL, subtitles: controller.subtitles, media: playback.media,
                                 startPosition: controller.vlcStartPosition,
                                 resumePoint: controller.resumePoint, nativeHighWater: controller.highWater,
                                 boundedStorage: BoundedStorageSession.session(for: controller.streamer),
                                 streamer: controller.streamer,
                                 deficitMonitor: controller.deficitMonitor)
                    .ignoresSafeArea()
            } else if let player = controller.player {
                MacAVPlayerRepresentable(player: player, onPictureInPictureChanged: { active in
                    controller.pictureInPictureChanged(active)
                })
                    // Never laid out at zero size (sheet appearing, VLC swap):
                    // AVKit's content view would get width / height == 0
                    // constraints it can't satisfy.
                    .frame(minWidth: 320, minHeight: 180)
                    .ignoresSafeArea()
                // Direct MP4: OpenSubtitles drawn over the video (the remux
                // path exposes them as native HLS tracks instead).
                if let cues = controller.cueController {
                    SubtitleOverlayText(controller: cues)
                        .allowsHitTesting(false)
                }
                // Download starvation: the native player waits for the data
                // (and resumes by itself) instead of switching to VLC. Also
                // shown, without the download line, while an item stuck on
                // complete data is rebuilt.
                if controller.isWaitingForData {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Buffering…")
                            .font(.headline)
                        if !controller.isRebuildingStuckItem {
                            Text("The download is slower than playback")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            } else {
                loadingView
            }

            if controller.showStats && controller.vlcURL == nil {
                Text(controller.statsText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(16)
            }

            // The download can't keep up with this release: a lighter one
            // at the same position, or carry on (native and VLC alike).
            if let monitor = controller.deficitMonitor {
                BandwidthDeficitBanner(monitor: monitor)
            }

            // Subtitle menu (direct path) + close; Escape closes too.
            HStack(spacing: 10) {
                Spacer()
                if controller.vlcURL == nil, let cues = controller.cueController {
                    SubtitleMenuButton(controller: cues)
                }
                Button {
                    dismiss()
                } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .trailing)

            // Hidden toggle bound to "n" — same shortcut as iOS/tvOS.
            Button("") { controller.showStats.toggle() }
                .keyboardShortcut("n", modifiers: [])
                .opacity(0)
        }
        // Bounded storage: a rewind stopped at the earliest point still on disk.
        .boundedStorageToast(controller.boundedToast)
        .background(Color.black)
        .onAppear {
            controller.onSwitch = onSwitch
            controller.start(playback)
        }
        .onDisappear { controller.stop() }
        #if DEBUG
        .onChange(of: controller.deficitOfferID) { _, id in
            if id != nil { MacDebugHooks.snapshotPlayerWindow(named: "deficit-offer", after: 1) }
        }
        .onChange(of: controller.loadingPhase.isNotResponding) { _, stalled in
            guard stalled else { return }
            MacDebugHooks.snapshotPlayerWindow(named: "loading-stall", after: 1)
            BandwidthDebugHooks.loadingStalled(choose: alternatives.isEmpty ? nil : { onChooseAnotherSource(playback.torrent) },
                                               keepWaiting: { controller.keepWaiting() })
        }
        #endif
    }

    /// Until the stream is ready: what the torrent is doing (from the first
    /// second: looking for peers, getting the torrent's details, buffering),
    /// and when the source does not answer, another source or more time.
    private var loadingView: some View {
        VStack(spacing: 14) {
            if controller.loadingPhase.isBuffering {
                ProgressView(value: controller.buffering, total: 1.0)
                    .frame(width: 320)
            } else if controller.showsLoadingSpinner && !controller.loadingPhase.isNotResponding {
                // Fixed size, in a container that never scales: AppKit's
                // indicator has fixed lengths (no min <= max warnings).
                ProgressView()
                    .controlSize(.large)
                    .frame(width: 40, height: 40)
            }
            Text(controller.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            // Bounded storage: the film is larger than the free space.
            if let note = controller.boundedNote {
                Label(note, systemImage: BoundedStorageUX.symbolName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if controller.loadingPhase.isNotResponding {
                HStack(spacing: 12) {
                    if !alternatives.isEmpty {
                        Button(LoadingPhase.chooseAnotherSourceTitle) { onChooseAnotherSource(playback.torrent) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                    Button(LoadingPhase.keepWaitingTitle) { controller.keepWaiting() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            } else if controller.loadingIsSlow && !alternatives.isEmpty {
                // Alive but minutes from playing: another source, beside
                // the progress.
                Button(LoadingPhase.chooseAnotherSourceTitle) { onChooseAnotherSource(playback.torrent) }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

/// Owns the torrent stream, the remux session, the AVPlayer and the switch
/// to VLC.
@MainActor
final class MacPlayerController: ObservableObject {
    @Published var player: AVPlayer?
    @Published var buffering: Double = 0
    @Published var statusLine = LoadingPhase.starting.line
    /// Where the stream's preparation is (`LoadingPhaseTracker`): the
    /// loading screen's line from the first second, and the « source not
    /// answering » state.
    @Published private(set) var loadingPhase: LoadingPhase = .starting
    /// The loading screen's spinner (not once the stream failed or stopped).
    @Published private(set) var showsLoadingSpinner = true
    /// Buffering, but minutes from playing (`LoadingPhaseTracker.isSlow`).
    @Published private(set) var loadingIsSlow = false
    /// The download against the release's bitrate (`BandwidthDeficitBanner`).
    @Published private(set) var deficitMonitor: BandwidthDeficitMonitor?
    /// The offer shown now (DEBUG snapshots).
    @Published private(set) var deficitOfferID: UUID?
    /// Plays a lighter release from a position (0…1) instead of this
    /// stream (the sheet: `MacPlayerView`). Set before `start`.
    var onSwitch: ((Torrent, Float) -> Void)?
    @Published var showStats = true
    @Published var statsText = ""
    /// Set when the native path gives up (DTS / TrueHD-only audio, VP9,
    /// AVI/TS container, AVPlayer failure…) — the view swaps to the VLC
    /// fallback player at this URL, on the SAME torrent stream.
    @Published var vlcURL: URL?
    /// 0…1 position VLC resumes at (where AVPlayer stopped).
    @Published private(set) var vlcStartPosition: Float = 0
    /// External subtitles drawn over the direct (MP4) AVPlayer path.
    @Published private(set) var cueController: SubtitleCueController?
    /// OpenSubtitles list — remux HLS renditions, VLC playback slaves.
    @Published private(set) var subtitles: [Subtitle] = []
    /// Download starvation: the native player waits for the data (buffering
    /// overlay) and resumes by itself.
    @Published private(set) var isWaitingForData = false
    /// That overlay is up for an item stuck on complete data being rebuilt
    /// (no "download slower" line).
    @Published private(set) var isRebuildingStuckItem = false
    /// Bounded storage: the loading screen's line (nil in full mode).
    @Published private(set) var boundedNote: String?
    /// Bounded storage's message over the video (a limited rewind).
    @Published private(set) var boundedToast: BoundedStorageToastMessage?
    /// When `boundedNote` was last computed (it reads the free space).
    private var boundedNoteAt: TimeInterval = -.infinity
    /// The pending check after a burst of time jumps (`scheduleBoundedRewindCheck`).
    private var boundedRewindCheck: DispatchWorkItem?
    /// Bounded storage ended playback for good (`endPlaybackForBoundedStorage`):
    /// the status screen keeps saying why, nothing restarts it.
    private var boundedPlaybackEnded = false

    /// The torrent's direct HTTP endpoint (direct AVPlayer path, VLC).
    private var directURL: URL?
    private var media: Media?
    private var remux: RemuxPlayback?
    private var failureObserver: AVPlayerItemFailureObserver?
    private var cueSubscription: AnyCancellable?
    private var statsTimer: Timer?
    private var stopped = false
    /// The controllers that started a stream (weak): one still playing in
    /// another window keeps the purge before a new stream away (`start`).
    private static let liveControllers = NSHashTable<MacPlayerController>.weakObjects()
    private var loggedAtmosVerdict = false
    private var engineLine = "…"
    /// What AVPlayer plays (master playlist / torrent HTTP endpoint): the
    /// starvation recovery rebuilds its item on it.
    private var playbackURL: URL?
    private var isDirectPlayback = false
    /// Keeps the native player through download starvation (slow swarm):
    /// rebuilds the item once the data is there instead of falling back.
    private lazy var starvation: PlaybackStarvationRecovery = makeStarvationRecovery()
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
    /// Bounded storage, direct path: AVPlayer waiting with the data on disk
    /// (sampled 1 Hz) → the item is rebuilt (`checkDirectStall`).
    private var directStall = BoundedDirectStallWatch()
    /// Remux path: the item AVPlayer started on live EVENT playlists, replaced
    /// once when the remux has finished (`rebuildLiveBornItemIfEnded`).
    private var liveBornWatch = LiveBornItemWatch()
    /// Picture in Picture is on: the stuck-playback safety net stays out of
    /// it.
    private var isPictureInPictureActive = false
    /// The user's play / pause intent: what a starvation recovery and any
    /// rebuild of the item end in.
    private var playIntent = PlaybackIntentWatch()
    /// The player's rate changes (`playerRateDidChange`) and its current
    /// item's time jumps (`reportPlaybackPositions` at once).
    private var playerObservers: [NSObjectProtocol] = []
    /// alextud's PopcornTorrent has no singleton — each stream owns an instance.
    let streamer = PTTorrentStreamer()
    /// Follows the stream's preparation (phase line, stall rules).
    private var loadingTracker = LoadingPhaseTracker()
    /// The stream is ready (or failed): the loading phase no longer moves.
    private var loadingDone = false
    /// 0…1 position this stream starts at (a switch to a lighter release).
    private var startFraction: Float = 0
    /// Direct path: the start seek waits for the item to be ready.
    private var startSeekObservation: NSKeyValueObservation?
    private var deficitSubscription: AnyCancellable?
    #if DEBUG
    /// BoundedStorageDebugHooks' seek / pause observers.
    private var debugObservers: [NSObjectProtocol] = []
    #endif
    /// The saved progress this session protects (read when it starts; 0 for
    /// none or a finished title) and the furthest position (0…1) reached
    /// natively (1 Hz): `MacPlaybackProgress.save`'s rules. Both go to the
    /// VLC fallback, which saves the rest of the session.
    private(set) var resumePoint: Float = 0
    private(set) var highWater: Float = 0

    func start(_ playback: MacPendingPlayback) {
        #if DEBUG
        // BoundedStorageDebugHooks' scripted seeks and pauses.
        debugObservers = [
            NotificationCenter.default.addObserver(forName: .ptDebugSeek, object: nil, queue: .main) { [weak self] note in
                let seconds = note.userInfo?["seconds"] as? Double
                MainActor.assumeIsolated {
                    guard let self, let seconds, self.vlcURL == nil, let player = self.player else { return }
                    let now = player.currentTime().seconds
                    print("[BoundedDebug] AVPlayer seek \(Int(now)) → \(Int(seconds)) s")
                    // Limited like a user's seek (bounded storage).
                    if let reference = self.playedPosition.lastPlayedTime ?? (now.isFinite ? now : nil),
                       let landing = BoundedStorageUX.limitedRewindTarget(seconds, from: reference, session: self.boundedStorage) {
                        self.limitRewind(target: seconds, from: reference, landing: landing)
                        return
                    }
                    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            },
            NotificationCenter.default.addObserver(forName: .ptDebugPlayback, object: nil, queue: .main) { [weak self] note in
                let playing = note.userInfo?["playing"] as? Bool
                MainActor.assumeIsolated {
                    guard let self, let playing, self.vlcURL == nil, let player = self.player else { return }
                    if playing { player.play() } else { player.pause() }
                }
            },
        ]
        #endif
        let magnet = playback.torrent.url
        // Reclaim prior torrent partials + orphaned remux output (shared
        // cross-platform helper — same disk-bounding as iOS/tvOS). Not while
        // another window plays: its torrent folder and HLS copy are not
        // orphans (verify-storage F6 — its remux lost its segments, and
        // libtorrent could reopen its file by path as a new, unsized one).
        // The next play with no other window, or the next launch, purges.
        if !Self.liveControllers.allObjects.contains(where: { $0 !== self && !$0.stopped }) {
            purgeOrphanTorrentDownloads()
        }
        Self.liveControllers.add(self)

        media = playback.media
        resumePoint = MacPlaybackProgress.resumePoint(for: playback.media)
        subtitles = playback.media.subtitles
        startFraction = playback.startFraction > 0.001 ? playback.startFraction : 0
        loadingTracker = LoadingPhaseTracker()
        // The release, the title's other releases and how to switch: the
        // deficit watch (native and VLC) reads them from the stream.
        let context = PlaybackStreamContext.attach(to: streamer, media: playback.media, sourceURL: magnet,
                                                   torrent: playback.torrent,
                                                   sources: playback.sources.isEmpty ? nil : playback.sources,
                                                   decidedStart: startFraction > 0 ? startFraction : nil)
        context.onSwitch = onSwitch
        let monitor = context.deficit
        monitor.attach(self) { [weak self] in
            MainActor.assumeIsolated { self?.deficitPlaybackState() }
        }
        deficitSubscription = monitor.$offer.receive(on: DispatchQueue.main).sink { [weak self] offer in
            MainActor.assumeIsolated { self?.deficitOfferID = offer?.id }
        }
        deficitMonitor = monitor
        let isAtmos = playback.torrent.tags.contains(.atmos)
        let hintsHDR = !playback.torrent.tags.isDisjoint(with: [.hdr10, .hdr10Plus, .dolbyVision])
        // BEP 53 `so=` (Torrentio season packs): stream THAT file.
        let preferredIndex = Torrent.selectedFileIndex(fromMagnet: magnet)
        // A film larger than the free space streams in bounded storage
        // (every route below drives the torrent's window).
        BoundedStorageSession.prepare(streamer, durationSeconds: BoundedStorageSession.durationHint(for: playback.media))

        streamer.startStreaming(fromMultiTorrentFileOrMagnetLink: magnet, progress: { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.player == nil, self.vlcURL == nil, !self.boundedPlaybackEnded,
                      !self.stopped, !self.loadingDone else { return }
                // From the first second (PopcornTorrent reports before the
                // metadata too): peers, the torrent's details, buffering.
                self.applyLoadingPhase(self.loadingTracker.update(streamer: self.streamer, fromCallback: true))
                self.refreshBoundedNote()
            }
        }, readyToPlay: { [weak self] videoFileURL, videoFilePath in
            DispatchQueue.main.async {
                guard let self = self, !self.stopped else { return }
                self.loadingDone = true
                self.buffering = 1
                self.loadingPhase = .buffering(progress: 1, eta: nil)
                let fileName = videoFilePath.lastPathComponent
                // alextud's GCDWebServer reports its URL as 0.0.0.0 — rewrite
                // to 127.0.0.1 (routable local endpoint) and name the file
                // (served on every path) so AVFoundation / VLC see the
                // container extension.
                self.directURL = PlaybackRouting.playableLocalURL(videoFileURL, fileName: fileName)
                // Route on the REAL payload name (magnet display names often
                // carry no extension). Unknown → remux, which fails fast.
                let route = PlaybackRouting.route(forFileName: fileName)
                print("[Player] \(fileName) → \(route)")
                switch route {
                case .remux:
                    // A start part-way (a switch to a lighter release) on a
                    // file still downloading: the in-order remux would take
                    // minutes to get there — VLC at once, at that position
                    // (its byte ranges fetch it first), as the tvOS / iOS
                    // quick resume does.
                    if self.startFraction > 0, !self.streamer.isWholeFileOnDisk {
                        self.vlcStartPosition = self.startFraction
                        self.fallBackToVLC("Reprise rapide")
                        return
                    }
                    self.startRemux(localFile: videoFilePath, isAtmos: isAtmos, releaseHintsHDR: hintsHDR)
                case .avPlayer:
                    self.startDirect()
                case .vlc:
                    self.vlcStartPosition = self.startFraction
                    self.fallBackToVLC(PlaybackRouting.vlcReason(forFileName: fileName))
                }
            }
        }, failure: { [weak self] (error: Error) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Not enough space even for bounded storage (-5: how much to
                // free), another file error (-6), or the error's own text.
                let message = StreamFailure(error, streamer: self.streamer).message(underlying: error) ?? error.localizedDescription
                self.loadingDone = true
                self.showsLoadingSpinner = false
                self.loadingPhase = .starting
                self.statusLine = String(format: "Failed: %@".localized, message)
            }
        }, selectFileToStream: { @Sendable (fileNames: [String], fileSizes: [NSNumber]) -> Int32 in
            // Runs on libtorrent's thread (pure helper only). Multi-file
            // torrents: the magnet's `so=` file when valid, else the largest
            // video file (the movie payload, not a sample).
            let index = PlaybackRouting.fileIndexToStream(names: fileNames,
                                                          sizes: fileSizes.map { $0.int64Value },
                                                          preferredIndex: preferredIndex)
            print("[Player] multi-file torrent: streaming #\(index) of \(fileNames.count)\(preferredIndex.map { " (so=\($0))" } ?? "")")
            return Int32(index)
        })

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
    }

    // MARK: - Loading

    /// The phase on the loading screen: its line (the swarm added while
    /// buffering) and the buffering bar.
    private func applyLoadingPhase(_ phase: LoadingPhase) {
        guard !loadingDone, !boundedPlaybackEnded else { return }
        loadingPhase = phase
        let slow = loadingTracker.isSlow
        if slow != loadingIsSlow { loadingIsSlow = slow }
        if case .buffering(let progress, _) = phase { buffering = Double(progress) }
        var line = loadingTracker.line
        if phase.isBuffering {
            let status = streamer.torrentStatus
            line += " · " + String(format: NSLocalizedString("PlayerLoading.Swarm", value: "Seeds: %1$d · %2$d KB/s",
                                                             comment: "Loading screen while buffering: connected seeds and download speed in kilobytes per second"),
                                   Int(status.seeds), Int(status.downloadSpeed / 1024))
        }
        statusLine = line
    }

    /// « Keep waiting » (the source does not answer): the message goes,
    /// every stall rule counts again from now.
    func keepWaiting() {
        guard !loadingDone else { return }
        print("[Player] keep waiting")
        loadingTracker.keepWaiting()
        applyLoadingPhase(loadingTracker.phase)
    }

    /// The deficit watch's view of the native player (nil while VLC plays:
    /// its own controller reports then).
    private func deficitPlaybackState() -> BandwidthDeficitMonitor.PlaybackState? {
        guard !stopped, vlcURL == nil, let player = player else { return nil }
        let recovering = starvation.isRecovering
        let time = recovering ? starvation.resumeTime : player.currentTime().seconds
        var duration = player.currentItem?.duration.seconds ?? .nan
        if !duration.isFinite || duration <= 0 { duration = lastKnownDuration ?? .nan }
        if !duration.isFinite || duration <= 0, let length = remux?.session?.playlistDurationSeconds, length > 0 {
            duration = length
        }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && playIntent.wantsPlayback
        return BandwidthDeficitMonitor.PlaybackState(playhead: time, duration: duration.isFinite ? duration : nil,
                                                     hasStarted: playedPosition.lastPlayedTime != nil,
                                                     wantsPlayback: playIntent.wantsPlayback,
                                                     isStalled: (recovering && !starvation.isRebuildingStuckItem) || waiting)
    }

    // MARK: - Remux path (MKV / WebM)

    private func startRemux(localFile: URL, isAtmos: Bool, releaseHintsHDR: Bool) {
        statusLine = "Remuxing MKV → HLS…".localized
        engineLine = "MKV remux → AVPlayer (macOS natif)"
        let remux = RemuxPlayback(localFile: localFile,
                                  streamer: streamer,
                                  isAtmos: isAtmos)
        // DEFAULT audio / subtitle renditions follow the user's languages.
        remux.preferredAudioLanguages = PlaybackLanguagePreferences.preferredAudioLanguageCode.map { [$0] } ?? []
        remux.preferredSubtitleLanguages = PlaybackLanguagePreferences.preferredSubtitleLanguageCode.map { [$0] } ?? []
        remux.releaseHintsHDR = releaseHintsHDR
        remux.subtitles = subtitles
        self.remux = remux
        remux.onReady = { [weak self] playlistURL in
            DispatchQueue.main.async { self?.attachPlayer(to: playlistURL, direct: false) }
        }
        remux.onFailure = { [weak self] message in
            // Codecs the remuxer can't repackage (DTS / TrueHD only, VP9…) —
            // reported within seconds of the header.
            DispatchQueue.main.async { self?.fallBackToVLC(message) }
        }
        remux.onHalted = { [weak self] reason in
            // The remux stopped producing after `onReady` (disk full…): the
            // missing segments will never exist — VLC at once, at the
            // current position (it reads the torrent file, no extra disk).
            DispatchQueue.main.async {
                print("[Player] remux halted after playback started (\(reason))")
                self?.fallBackToVLC(reason)
            }
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
        // OpenSubtitles → native HLS subtitle tracks (fetched when the detail
        // screen found none).
        if subtitles.isEmpty, let media = media {
            // AVPlayer reads the master playlist once: hold `onReady` a few
            // seconds so the search can land in it. Assigning `subtitles`
            // (even []) releases the hold.
            remux.externalSubtitlesPending = true
            Self.searchSubtitles(for: media) { [weak self, weak remux] found in
                remux?.subtitles = found
                guard let self = self, !found.isEmpty else { return }
                self.subtitles = found
            }
        }
        remux.start()
    }

    private static func searchSubtitles(for media: Media, completion: @escaping ([Subtitle]) -> Void) {
        if let episode = media as? Episode {
            SubtitlesManager.shared.search(episode, imdbId: episode.show?.id) { subtitles, _ in completion(subtitles) }
        } else {
            SubtitlesManager.shared.search(imdbId: media.id) { subtitles, _ in completion(subtitles) }
        }
    }

    // MARK: - Direct path (MP4 / M4V / MOV)

    private func startDirect() {
        guard let url = directURL else { return }
        statusLine = "Opening the file…".localized
        engineLine = "MP4 direct → AVPlayer (macOS natif)"
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
        let cues = SubtitleCueController(subtitles: subtitles)
        cueController = cues
        if cues.available.isEmpty {
            // Preferred subtitle language once OpenSubtitles answers
            // (`$available` fires before the change — hop a turn).
            cueSubscription = cues.$available
                .first(where: { !$0.isEmpty })
                .receive(on: DispatchQueue.main)
                .sink { [weak cues] _ in
                    guard let cues = cues, cues.selected == nil else { return }
                    cues.autoSelectPreferred()
                }
            cues.loadSubtitlesIfNeeded(for: media)
        } else {
            cues.autoSelectPreferred()
        }
        attachPlayer(to: url, direct: true)
        // Bounded storage: AVPlayer reads through PopcornTorrent's server
        // (which moves the window); its playhead tells the torrent what it
        // may delete behind it.
        BoundedStorageSession.session(for: streamer)?.attachHTTPPlayer(self, readAheadSeconds: Self.directReadAheadSeconds) { [weak self] in
            guard let self = self, self.isDirectPlayback, self.vlcURL == nil, let player = self.player,
                  player.currentItem?.status == .readyToPlay else { return nil }
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

    // MARK: - Player

    private func attachPlayer(to url: URL, direct: Bool) {
        guard !stopped, vlcURL == nil, player == nil else { return }
        playbackURL = url
        isDirectPlayback = direct
        let item = makePlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.appliesMediaSelectionCriteriaAutomatically = true
        PlaybackLanguagePreferences.applyPreferredMediaSelection(to: item)
        installFailureObserver(on: item)
        noteAttachedItem(item)
        print("[Player] AVPlayer on \(direct ? "the torrent's HTTP endpoint" : "the remux HLS")")
        cueController?.attach(to: player)
        self.player = player
        observePlayer(player)
        if direct, startFraction > 0 {
            seekToStartFraction(item: item, player: player)
        } else {
            player.play()
        }
        // Auto-hide the stats after the proof-of-Atmos glance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.showStats = false
        }
    }

    /// Direct path, a start part-way (a switch to a lighter release): once
    /// the item is ready with its duration, a seek there (byte ranges make
    /// the torrent fetch that part first), then play. Never blocks
    /// playback: after 45 s it plays from where it is.
    private func seekToStartFraction(item: AVPlayerItem, player: AVPlayer) {
        let fraction = Double(startFraction)
        startFraction = 0
        var done = false
        let finish: (String) -> Void = { [weak self, weak player] how in
            guard !done else { return }
            done = true
            self?.startSeekObservation?.invalidate()
            self?.startSeekObservation = nil
            print("[Player] start part-way: \(how)")
            player?.play()
        }
        startSeekObservation = item.observe(\.status, options: [.initial, .new]) { observed, _ in
            DispatchQueue.main.async {
                guard !done, observed.status == .readyToPlay else { return }
                let duration = observed.duration.seconds
                guard duration.isFinite, duration > 0 else { return finish("duration unknown, from the start") }
                let target = CMTime(seconds: fraction * duration, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    DispatchQueue.main.async { finish("at \(Int(fraction * duration)) s (\(Int(fraction * 100)) %)") }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { finish("not ready after 45 s, from where it is") }
    }

    /// The item for `url` — also how the starvation recovery rebuilds it.
    private func makePlayerItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        // Let macOS spatialize the 5.1 + Atmos objects (built-in speakers /
        // AirPods) — this is the whole point of the native Mac app.
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        if isDirectPlayback, BoundedStorageSession.session(for: streamer)?.isBounded == true {
            // Bounded storage: a known read-ahead over the torrent's file.
            item.preferredForwardBufferDuration = Self.directForwardBufferSeconds
        }
        return item
    }

    /// For the player's whole life: its rate changes (`playerRateDidChange`)
    /// and the time jumps of its current item (seeks, scrubs) — the positions
    /// are reported to the remux at once then, not at the next tick
    /// (`reportPlaybackPositions`). Removed when the player goes.
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

    private func removePlayerObservers() {
        playerObservers.forEach { NotificationCenter.default.removeObserver($0) }
        playerObservers = []
    }

    /// The current item plays normally: no recovery or rebuild running (they
    /// pause and play the player themselves), not handed off or stopped, the
    /// item not failed nor its failure reported.
    private var isItemHealthy: Bool {
        guard let item = player?.currentItem else { return false }
        return !starvation.isRecovering && !stopped && vlcURL == nil && item.status != .failed
            && failureObserver?.hasReportedFailure != true
    }

    /// A rate change of the player: the user's play / pause intent
    /// (`PlaybackIntentWatch`). Only on a healthy item (`isItemHealthy`); the
    /// user's play / pause on a dead item while a recovery waits reaches the
    /// intent through the recovery (`onUserPlaybackChanged`). (The Mac saves
    /// no progress: no checkpoint.)
    private func playerRateDidChange(reason: AVPlayer.RateDidChangeReason?) {
        guard let player = player else { return }
        _ = playIntent.noteRateChange(rate: player.rate, reason: reason, isHealthy: isItemHealthy, canCheckpoint: false)
    }

    /// The 1 Hz tick (after the played position is sampled) and every time
    /// jump of a healthy item: the user's seek target AVPlayer holds, if any
    /// (`HeldSeekWatch`: `currentTime()` far from the last played position).
    private func noteHeldSeek(isJump: Bool) {
        guard isItemHealthy, let player = player else { return }
        heldSeek.note(wanted: player.currentTime().seconds, played: playedPosition.lastPlayedTime, isJump: isJump)
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
    /// (a paused scrub's target is the recovery's, once play is pressed — so
    /// is a scrub on the player view's timeline: AVKit's `setRate:0`, a user
    /// reason, lasts until its seek completes, which a held seek doesn't
    /// (measured); it ends on VLC from the recovery's watch, once AVPlayer
    /// fails the item), an item not healthy (recovery, hand-off), the direct
    /// path, a finished remux.
    private func checkFarSeekTarget() {
        guard !isDirectPlayback, let remux = remux, let session = remux.session else {
            farTarget.reset()
            return
        }
        let target = isItemHealthy && playIntent.wantsPlayback ? heldSeek.target : nil
        let frontier = session.progress.mediaSeconds
        guard farTarget.shouldHandOff(target: target, frontierSeconds: frontier,
                                      downloadProgress: streamer.torrentStatus.totalProgress,
                                      remuxFinished: remux.isFinished, now: ProcessInfo.processInfo.systemUptime),
              let held = target else { return }
        print("[Player] seek to \(Int(held)) s held past the remux frontier (\(Int(frontier)) s): "
              + "~\(Int((farTarget.estimatedSecondsToTarget ?? 0).rounded())) s away at the download's pace — VLC there")
        fallBackToVLC(FarTargetWatch.reason, resumeTime: held)
    }

    /// ANY AVPlayer failure (remux or direct) → starvation recovery when the
    /// download is just slow, else VLC on the same stream. Hard failures are
    /// reported at once; the readiness timeout only catches silent hangs and
    /// is extended (up to 4 × 30 s) while the torrent is still downloading,
    /// so a slow swarm isn't mistaken for an incompatible file. An item
    /// rebuilt by the starvation recovery (`isReplacement`) gets no
    /// readiness timeout here: the recovery gives it 30 s, no extensions.
    private func installFailureObserver(on item: AVPlayerItem, isReplacement: Bool = false) {
        failureObserver?.invalidate()
        let observer = AVPlayerItemFailureObserver(item: item, readyTimeout: isReplacement ? nil : 30,
                                                   onReport: { [weak self] failure in
            self?.handlePlaybackFailure(failure)
        })
        if !isReplacement {
            observer.shouldExtendReadyTimeout = { [weak self] in
                guard let self = self else { return false }
                return !self.streamer.isWholeFileOnDisk
            }
        }
        failureObserver = observer
    }

    // MARK: - Download starvation (slow swarm) → stay native

    /// Starvation (FailedToPlayToEnd -12889 after AVPlayer waited ~37 s on a
    /// held segment / byte range) keeps the native player — HDR / Atmos —
    /// and resumes once the data is there (at the user's new target after a
    /// seek during the wait, or at the target of a seek AVPlayer still held
    /// when the item failed: `HeldSeekWatch`) — for a user who had paused,
    /// only once play is pressed (`PlaybackIntentWatch`); anything else →
    /// VLC, at that held target too. Remux path: a halted remux or an HTTP
    /// 404 (a segment that will never exist) → VLC at once, never a recovery.
    private func handlePlaybackFailure(_ failure: AVPlayerItemFailureObserver.Failure) {
        guard !stopped, vlcURL == nil else { return }
        // Taken either way; a recovery in progress has its own target.
        var held = heldSeek.take()
        if starvation.isRecovering { held = nil }
        if !isDirectPlayback {
            if let reason = remux?.failureReason {
                fallBackToVLC(reason, resumeTime: held)
                return
            }
            if failure.isMissingResource {
                print("[Player] HTTP 404 from the remux server — segment gone for good, not starvation")
                fallBackToVLC("Segment indisponible : \(failure.reason)", resumeTime: held)
                return
            }
        }
        let target = recoveryPosition(held: held)
        // The direct path's "already played" test needs where playback
        // stood: never a held target.
        let stood = target.isUserTarget ? recoveryPosition(held: nil).position : target.position
        if let player = player, let plan = starvationPlan(failurePosition: stood),
           starvation.handle(failure, player: player, position: target.position, resumesPlayback: playIntent.wantsPlayback,
                             positionIsUserTarget: target.isUserTarget,
                             stillDownloading: plan.stillDownloading, isDataReady: plan.isDataReady) {
            return
        }
        fallBackToVLC(failure.reason, resumeTime: held)
    }

    /// `RemuxPlayback.onUnavailableSegmentRequested`: VLC at once, at the
    /// earlier of the playhead and the requested pruned segment's start
    /// (`ResumePolicy.handOffTime`) — the playhead when it lies before that
    /// segment (« recommencer » in the kept segment 0 while AVPlayer
    /// prefetches the pruned segment 1; playback reaching a pruned span
    /// about a segment early), the segment's start for a scrub into the
    /// pruned range. (No start seek here: the Mac never resumes natively.)
    private func unavailableSegmentRequested(at playerSeconds: Double) {
        guard !stopped, vlcURL == nil, !isDirectPlayback, remux != nil else { return }
        // Bounded storage: a rewind past the kept media is blocked (the
        // earliest point still available instead, never VLC); playback
        // reaching a pruned span ahead goes on below (VLC at the playhead,
        // when its data is still there: `fallBackToVLC`).
        if limitBoundedRewind(toPrunedSegmentAt: playerSeconds) { return }
        let target = ResumePolicy.handOffTime(prunedSegmentStart: playerSeconds, playhead: player?.currentTime().seconds)
        print("[Player] pruned segment requested at \(Int(playerSeconds)) s — target \(Int(target)) s")
        fallBackToVLC(ResumePolicy.rewindPastBufferReason, resumeTime: target)
    }

    /// Whether the data at the playhead can still arrive, and the test for
    /// "enough of it to play again" (remux frontier / direct: a position
    /// already played before `failurePosition` — a user rewind during the
    /// wait — else more torrent bytes). nil (→ VLC) when the remux stopped
    /// for good (`failureReason`).
    private func starvationPlan(failurePosition: Double) -> (stillDownloading: Bool, isDataReady: (Double, TimeInterval) -> Bool)? {
        if isDirectPlayback {
            let streamer = self.streamer
            let atFailure = streamer.torrentStatus.totalProgress
            // The whole file on disk (bounded storage: `isFileComplete`), else more of it.
            return (!streamer.isWholeFileOnDisk, { time, waited in
                // Bounded storage: a position whose data is gone never gets
                // ready (the recovery waits for the one
                // `limitRecoveringRewind` moved it to).
                if let session = BoundedStorageSession.session(for: streamer), session.isBounded,
                   !session.canSeek(to: time, fromPlayerTime: failurePosition) { return false }
                if streamer.isWholeFileOnDisk { return true }
                return StarvationPolicy.directDataReady(resumeTime: time, failurePosition: failurePosition,
                                                        progress: streamer.torrentStatus.totalProgress,
                                                        progressAtFailure: atFailure, waited: waited)
            })
        }
        guard let remux = remux, remux.failureReason == nil else { return nil }
        let finished = remux.session?.progress.finished ?? false
        return (!finished, { [weak remux] time, _ in
            guard let session = remux?.session else { return false }
            // Bounded storage: a deleted segment never comes back (the
            // recovery waits for the playhead `limitRecoveringRewind` moved
            // instead of rebuilding there).
            if remux?.isStorageBounded == true, remux?.isAvailable(playerSeconds: time) == false { return false }
            let progress = session.progress
            return StarvationPolicy.remuxDataReady(frontierSeconds: progress.mediaSeconds, finished: progress.finished,
                                                   resumeTime: time, durationKnown: session.totalDurationSeconds > 0)
        })
    }

    /// Where to recover after the item failed (player timeline, s): the
    /// user's seek target AVPlayer still held (`held`, `isUserTarget`:
    /// `currentTime()` now reads where playback was before that seek); else
    /// where playback stood.
    private func recoveryPosition(held: Double?) -> (position: Double, isUserTarget: Bool) {
        if let target = held { return (target, true) }
        if let time = player?.currentTime().seconds, time.isFinite, time > 0 { return (time, false) }
        return (lastKnownTime ?? 0, false)
    }

    private func makeStarvationRecovery() -> PlaybackStarvationRecovery {
        let recovery = PlaybackStarvationRecovery()
        recovery.onWaitingChanged = { [weak self, unowned recovery] waiting in
            self?.isRebuildingStuckItem = waiting && recovery.isRebuildingStuckItem
            self?.isWaitingForData = waiting
        }
        // Remux: a user seek during the wait moves the remux lookahead there
        // at once — the dead item requests nothing (direct path: no remux).
        recovery.onRetarget = { [weak self] seconds in
            guard let self = self, self.vlcURL == nil else { return }
            self.remux?.updatePlaybackPositions(played: self.playedPosition.lastPlayedTime, wanted: seconds)
        }
        // The user's play / pause on the dead item during the wait: the play
        // intent follows (`playerRateDidChange` ignores a recovering player).
        recovery.onUserPlaybackChanged = { [weak self] playing in
            self?.playIntent.noteUserPlayback(playing: playing)
        }
        // Remux: a waiting recovery stops as soon as the remux halts…
        recovery.abandonReason = { [weak self] in
            guard let self = self, !self.isDirectPlayback else { return nil }
            return self.remux?.failureReason
        }
        // …or once the download keeps growing while the remux frontier
        // stays frozen (stall cap → VLC, whose byte ranges get the torrent
        // to fetch the playhead's pieces).
        recovery.stallProbe = { [weak self] in
            guard let self = self, !self.isDirectPlayback, let session = self.remux?.session else { return nil }
            return (session.progress.mediaSeconds, self.streamer.torrentStatus.totalProgress)
        }
        // Its far-target pace starts from the download's pace this player's
        // own watch keeps (fed at every tick).
        recovery.farTargetHistory = { [weak self] in self?.farTarget.downloadHistory ?? [] }
        recovery.makeItem = { [weak self] in
            guard let self = self, !self.stopped, let url = self.playbackURL else { return nil }
            return self.makePlayerItem(url: url)
        }
        recovery.onItemReplaced = { [weak self] item, restoresSelection in
            guard let self = self else { return }
            // Its readiness budget is the recovery's: 30 s, no extensions.
            self.installFailureObserver(on: item, isReplacement: true)
            self.noteAttachedItem(item)
            if !restoresSelection { PlaybackLanguagePreferences.applyPreferredMediaSelection(to: item) }
            // Direct path: the overlay coordinates with the NEW item's tracks.
            self.cueController?.bindNativeSubtitles(of: item)
            self.trackSummaries = []
            self.loggedAtmosVerdict = false
        }
        recovery.onResumed = { [weak self] _ in
            guard let self = self, !self.stopped, self.vlcURL == nil else { return }
            self.player?.play()
        }
        recovery.onGiveUp = { [weak self] reason in
            self?.fallBackToVLC(reason)
        }
        return recovery
    }

    /// 0…1 position: while a starvation recovery runs, the position it
    /// recovers (the user's new target after a seek during the wait); else
    /// the player's; else — once a recovery gave up — the position it was
    /// recovering; else the last position read from a ready item
    /// (NaN-safe).
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

    /// The native path can't play this payload: switch the view to VLC on
    /// the torrent's direct HTTP endpoint — same stream, not restarted —
    /// where playback got (`resumeTime`, player timeline, s: an explicit
    /// target), clamped to `ResumePolicy.handOffMaxFraction`: a failure in
    /// the end credits continues there instead of restarting the movie.
    private func fallBackToVLC(_ reason: String, resumeTime: Double? = nil) {
        guard !stopped, vlcURL == nil else { return }
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
        guard let url = directURL else {
            showsLoadingSpinner = false
            statusLine = String(format: "Cannot play: %@".localized, reason)
            return
        }
        // The native part of the session, up to now (VLC gets it as nativeHighWater).
        noteHighWater()
        let reached = resumeTime.flatMap { fraction(ofPlayerTime: $0) } ?? knownPlaybackFraction()
        if let fraction = reached, fraction > 0.001 {
            vlcStartPosition = ResumePolicy.handOffFraction(reached: fraction)
        }
        print("[Player] native playback unavailable (\(reason)) — bascule sur VLC à \(Int(vlcStartPosition * 100)) %")
        starvation.cancel()
        failureObserver?.invalidate()
        failureObserver = nil
        cueSubscription = nil
        cueController?.detach()
        cueController = nil
        removePlayerObservers()
        player?.pause()
        // Release the HTTP connection to the torrent's local server.
        player?.replaceCurrentItem(with: nil)
        player = nil
        remux?.stop()
        remux = nil
        BoundedStorageSession.session(for: streamer)?.detachHTTPPlayer(self)
        statusLine = "Playing with VLC…".localized
        vlcURL = url
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

    /// 1 Hz: played / known position, a held seek target (and the far-target
    /// hand-off), the positions reported to the remux, the stuck-playback
    /// safety net, the one-time replacement of an item started on live EVENT
    /// playlists, stats.
    private func refreshStats() {
        // Loading: the stall rules need the clock even when no status comes.
        if player == nil, vlcURL == nil, !stopped, !loadingDone {
            applyLoadingPhase(loadingTracker.update(streamer: streamer, fromCallback: false))
        }
        // The last position playback actually reached — playing through it,
        // item ready, not recovering (`PlayedPositionTracker`): a seek target
        // AVPlayer still waits for (held past the remux frontier) never
        // counts.
        if let player = player {
            playedPosition.note(time: player.currentTime().seconds, clock: ProcessInfo.processInfo.systemUptime,
                                isPlaying: player.timeControlStatus == .playing,
                                isItemReady: player.currentItem?.status == .readyToPlay,
                                isRecovering: starvation.isRecovering)
        }
        noteHeldSeek(isJump: false)
        checkFarSeekTarget()
        // Position / duration of a ready item — while a starvation recovery
        // runs, the position it recovers (it follows a user seek during the
        // wait).
        if starvation.isRecovering {
            if let time = starvation.resumeTime, time.isFinite, time >= 0 { lastKnownTime = time }
        } else if let item = player?.currentItem, item.status == .readyToPlay {
            let time = item.currentTime().seconds
            if time.isFinite, time >= 0 { lastKnownTime = time }
            let duration = item.duration.seconds
            if duration.isFinite, duration > 0 { lastKnownDuration = duration }
        }
        noteHighWater()
        reportPlaybackPositions()
        checkStuckPlayback()
        checkDirectStall()
        checkBoundedReverseScan()
        rebuildLiveBornItemIfEnded()
        reloadTrackSummaries()
        var lines = ["Engine  \(engineLine)"]
        if player?.currentItem != nil {
            for track in trackSummaries {
                if track.mediaType == .video {
                    lines.append("Video   \(track.fourCC)  \(track.width)×\(track.height)")
                    continue
                }
                let atmos = track.fourCC == "ec-3" ? "  → Dolby (Atmos, rendu spatial macOS)" : ""
                lines.append("Audio   \(track.fourCC)  \(track.channels) ch\(atmos)")
                // One clear, greppable verdict line the first time the audio
                // format resolves — THE line to read for Atmos.
                if !loggedAtmosVerdict {
                    loggedAtmosVerdict = true
                    let jocSignalled = remux?.session?.audioRenditions.contains(where: { $0.isAtmos }) ?? false
                    if track.fourCC == "ec-3" && jocSignalled {
                        print("[Atmos] ✅ DOLBY ATMOS ACTIF — flux DD+ JOC (16 objets), AVPlayer décode ec-3 \(track.channels) ch. Rendu spatial: Centre de contrôle ▸ Son ▸ Audio spatial.")
                    } else if track.fourCC == "ec-3" {
                        print("[Atmos] DD+ (E-AC-3) natif, \(track.channels) ch — Atmos seulement si le flux porte du JOC")
                    } else {
                        print("[Atmos] ❌ pas d'Atmos — piste audio '\(track.fourCC)' \(track.channels) ch (il faut une release DD+/E-AC-3 Atmos)")
                    }
                }
            }
        }
        if let remux = remux {
            lines.append(contentsOf: remux.renditionSummary.map { "Piste   \($0)" })
            lines.append("Remux   \(remux.statsSummary)")
        }
        if let cues = cueController {
            lines.append("Subs    \(cues.selected?.language ?? "désactivés") · \(cues.available.count) dispo.")
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
        statsText = " " + lines.joined(separator: "\n ") + " "
    }

    /// Remux path, every tick — also while a starvation recovery runs — and
    /// at once when the current item's time jumps (a seek): the last
    /// position playback reached (`played`) and where the player needs
    /// data now (`wanted`: while recovering, the position the recovery
    /// waits for; else `currentTime()` — the playhead, or a pending seek
    /// target). The remux runs its lookahead from those and deletes only
    /// segments neither needs (`RemuxPlayback.updatePlaybackPositions`).
    private func reportPlaybackPositions() {
        guard !isDirectPlayback, vlcURL == nil, let remux = remux else { return }
        let time = starvation.isRecovering ? starvation.resumeTime : player?.currentTime().seconds
        let wanted = time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        remux.updatePlaybackPositions(played: playedPosition.lastPlayedTime, wanted: wanted)
    }

    /// END safety net (1 Hz, remux path). Once the remux has finished, every
    /// byte is local: an item frozen while the user wants it playing (ready,
    /// rate ≠ 0, time unmoved for `StuckPlaybackWatch.stuckSeconds`) won't
    /// recover by waiting, and AVPlayer posts no failure for it. In the end
    /// zone (last second / last segment) that is the natural end: paused, as
    /// AVPlayer does at an item's end. Elsewhere the item is rebuilt in
    /// place (at the stuck position, i.e. a pending seek target too), at
    /// most twice for one position, then VLC there. Never during a
    /// starvation recovery, before the remux has finished, over AirPlay or
    /// in Picture in Picture (a sample gap — timers suspended — restarts the
    /// observation).
    private func checkStuckPlayback() {
        guard let player = player else { return }
        let remux = isDirectPlayback ? nil : self.remux
        let eligible = remux?.isFinished == true && !starvation.isRecovering && !stopped && vlcURL == nil
            && !isPictureInPictureActive && !player.isExternalPlaybackActive
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
            starvation.rebuildNow(player: player, at: stuckAt, reason: StuckPlaybackWatch.reason)
        case .fallback:
            fallBackToVLC(StuckPlaybackWatch.reason, resumeTime: stuckAt)
        }
    }

    /// Bounded storage, direct path, 1 Hz: AVPlayer waiting for 8 s at the
    /// same time while the data ahead of the server's read position is on
    /// disk is not waiting for the download — macOS AVPlayer's loader stops
    /// requesting after a far seek's back-fill reached deleted data (part-3
    /// coverage md2–md5). The item is rebuilt at the playhead
    /// (`BoundedDirectStallWatch`). Full mode: never.
    private func checkDirectStall() {
        guard let player = player else { return }
        let isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            && player.currentItem?.status == .readyToPlay
        let eligible = isWaiting && isDirectPlayback && vlcURL == nil && !stopped && !starvation.isRecovering
            && boundedStorage?.isBounded == true && boundedStorage?.hasDataAheadOfReader() == true
        guard let time = directStall.note(time: player.currentTime().seconds, clock: ProcessInfo.processInfo.systemUptime,
                                          isWaiting: isWaiting, isEligible: eligible) else { return }
        print("[Player] bounded direct route: AVPlayer waiting at \(String(format: "%.1f", time)) s for "
              + "\(Int(BoundedDirectStallWatch.stallSeconds)) s with the data on disk → rebuilding the item")
        starvation.rebuildNow(player: player, at: time, reason: BoundedDirectStallWatch.reason)
    }

    /// Bounded storage, 1 Hz: a reverse scan (J key, a held rewind) stops at
    /// the earliest point still available, with the message, and plays on
    /// from there (`BoundedStorageUX.reverseScanLimit`).
    private func checkBoundedReverseScan() {
        guard let player = player, isItemHealthy, !stopped else { return }
        let now = player.currentTime().seconds
        guard let landing = BoundedStorageUX.reverseScanLimit(time: now, rate: player.rate,
                                                              playedReference: playedPosition.lastPlayedTime,
                                                              session: boundedStorage) else { return }
        player.rate = BoundedStorageUX.resumeRate(after: player)
        limitRewind(target: now, from: playedPosition.lastPlayedTime ?? now, landing: landing)
    }

    /// A new current item (the first one, a recovery's replacement): when
    /// AVPlayer starts it on live EVENT playlists — remux of a file without a
    /// Matroska Duration that hasn't finished yet — it is replaced once the
    /// remux has finished (`rebuildLiveBornItemIfEnded`).
    private func noteAttachedItem(_ item: AVPlayerItem) {
        let remux = isDirectPlayback ? nil : self.remux
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
    /// next tick while a recovery runs, over AirPlay or in Picture in
    /// Picture.
    private func rebuildLiveBornItemIfEnded() {
        guard let player = player, !isDirectPlayback, vlcURL == nil, let remux = remux else { return }
        let time = player.currentTime().seconds
        let eligible = !starvation.isRecovering && !stopped && time.isFinite && time >= 0
            && !isPictureInPictureActive && !player.isExternalPlaybackActive
        guard liveBornWatch.shouldRebuild(current: player.currentItem.map { ObjectIdentifier($0) },
                                          remuxFinished: remux.isFinished, isEligible: eligible) else { return }
        let playing = playIntent.wantsPlayback
        print("[Player] remux finished: replacing the item AVPlayer started on live EVENT playlists at "
              + "\(String(format: "%.3f", time)) s (\(playing ? "playing" : "paused"))")
        starvation.rebuildNow(player: player, at: time, reason: LiveBornItemWatch.reason,
                              resumesPlayback: playing, exactPosition: true)
    }

    /// The session's furthest native position (1 Hz, and at close).
    private func noteHighWater() {
        guard player != nil, vlcURL == nil, let fraction = knownPlaybackFraction() else { return }
        highWater = max(highWater, fraction)
    }

    /// Closing the native player: saves the known position (≥ 80 % marks the
    /// title watched) — never below the session's resume point unless it
    /// played past it. Nothing while buffering, and nothing once VLC took
    /// over: MacVLCController saves its own position.
    private func saveProgressIfNeeded() {
        guard !stopped, vlcURL == nil, player != nil, let media,
              let fraction = knownPlaybackFraction(), fraction > 0 else { return }
        noteHighWater()
        MacPlaybackProgress.save(fraction, for: media, resumePoint: resumePoint, highWater: highWater)
    }

    /// `MacAVPlayerRepresentable`: Picture in Picture started / ended.
    func pictureInPictureChanged(_ active: Bool) {
        isPictureInPictureActive = active
    }

    // MARK: - Bounded storage

    /// The stream's bounded storage. Its `isBounded` is false in full mode:
    /// nothing below acts then.
    private var boundedStorage: BoundedStorageSession? { BoundedStorageSession.session(for: streamer) }

    /// The loading screen's line, at most every 5 s (it reads the free space).
    private func refreshBoundedNote() {
        guard !boundedPlaybackEnded else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - boundedNoteAt >= 5 || (boundedNote == nil && boundedStorage?.isBounded == true) else { return }
        boundedNoteAt = now
        boundedNote = BoundedStorageUX.loadingNote(for: streamer)
        #if DEBUG
        if boundedNote != nil { MacDebugHooks.snapshotPlayerWindow(named: "bounded-loading", after: 1) }
        #endif
    }

    /// Bounded storage, after a time jump of a healthy item (the player
    /// view's scrubber, ±15 s, the keyboard, a remote command): a playhead
    /// that went further back than what is still on disk goes to the
    /// earliest point still available, with the message — the user's
    /// decision: no new download, no VLC for a rewind. Checked 0.35 s after
    /// the last jump of a burst: a drag on the timeline is not fought.
    private func scheduleBoundedRewindCheck() {
        guard boundedStorage?.isBounded == true else { return }
        boundedRewindCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkBoundedRewind() }
        }
        boundedRewindCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func checkBoundedRewind() {
        guard isItemHealthy, let player = player else { return }
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
        guard let session = boundedStorage, session.isBounded, let player = player,
              let reference = playedPosition.lastPlayedTime, playerSeconds < reference else { return false }
        let now = player.currentTime().seconds
        let earliest = session.earliestRewindTime(fromPlayerTime: reference) ?? reference
        if now.isFinite, now >= earliest { return true }
        // AVKit seeks all along a timeline drag, and each pruned segment it
        // asks for lands here — the time-jump check limits the rewind 0.35 s
        // after the last jump instead, so the drag is not fought.
        if isItemHealthy {
            scheduleBoundedRewindCheck()
            return true
        }
        let target = now.isFinite ? min(now, reference) : playerSeconds
        let landing = BoundedStorageUX.limitedRewindTarget(target, from: reference, session: session) ?? reference
        limitRewind(target: target, from: reference, landing: landing)
        return true
    }

    /// Bounded storage, during a starvation recovery: the user moved the
    /// dead item's playhead into deleted media. Instead of VLC there, it
    /// goes to the earliest point still available — the recovery follows it
    /// as the user's new target at its next look — with the message. True
    /// when it did.
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
        let toast = BoundedStorageToastMessage(text: BoundedStorageUX.rewindLimitedMessage(for: boundedStorage))
        boundedToast = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + BoundedStorageToastMessage.visibleSeconds) { [weak self] in
            guard let self, self.boundedToast?.id == toast.id else { return }
            self.boundedToast = nil
        }
        #if DEBUG
        MacDebugHooks.snapshotPlayerWindow(named: "bounded-toast", after: 1)
        #endif
    }

    /// Bounded storage: the hand-off to VLC at `resumeTime` (nil: the
    /// current position) would read deleted torrent data (HTTP 410). VLC
    /// continues where playback was instead when THAT is still there (a
    /// rewind target that is gone); `.end` when nothing can play here.
    private enum BoundedHandOff { case asked, at(Double), end }

    private func boundedHandOff(resumeTime: Double?) -> BoundedHandOff {
        guard let session = boundedStorage, session.isBounded, player != nil else { return .asked }
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
    /// where it would have to (deleted): stop, cancel the stream (its disk
    /// space comes back at once) and say so on the player's status screen,
    /// which stays as it is until the user closes the player (the stream's
    /// progress, still reported every 0.5 s until the cancel lands, no
    /// longer overwrites it: `boundedPlaybackEnded`).
    private func endPlaybackForBoundedStorage(_ reason: String) {
        print("[Bounded] native playback unavailable (\(reason)) and its data is deleted — stopped")
        boundedPlaybackEnded = true
        noteHighWater()
        starvation.cancel()
        failureObserver?.invalidate()
        failureObserver = nil
        boundedRewindCheck?.cancel()
        cueSubscription = nil
        cueController?.detach()
        cueController = nil
        removePlayerObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        remux?.stop()
        remux = nil
        BoundedStorageSession.session(for: streamer)?.detachHTTPPlayer(self)
        isWaitingForData = false
        buffering = 0
        loadingDone = true
        showsLoadingSpinner = false
        loadingPhase = .starting
        // Title on the status line, the reason under it (one sentence each).
        statusLine = BoundedStorageUX.cannotContinueTitle
        boundedNote = BoundedStorageUX.cannotContinueMessage
        // Nothing can play this stream any more: give its space back now
        // (`stop()` cancels again when the player closes — harmless).
        streamer.cancelStreamingAndDeleteData(true)
    }

    func stop() {
        #if DEBUG
        debugObservers.forEach { NotificationCenter.default.removeObserver($0) }
        debugObservers = []
        #endif
        saveProgressIfNeeded()
        stopped = true
        statsTimer?.invalidate()
        statsTimer = nil
        startSeekObservation?.invalidate()
        startSeekObservation = nil
        deficitSubscription = nil
        deficitMonitor?.detach(self)
        starvation.cancel()
        failureObserver?.invalidate()
        failureObserver = nil
        cueSubscription = nil
        cueController?.detach()
        removePlayerObservers()
        boundedRewindCheck?.cancel()
        player?.pause()
        player = nil
        remux?.stop()
        remux = nil
        BoundedStorageSession.session(for: streamer)?.detachHTTPPlayer(self)
        streamer.cancelStreamingAndDeleteData(false)
    }
}

/// AVKit's native macOS player view (controls, PiP, fullscreen).
struct MacAVPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    /// Picture in Picture started (true) / ended (false).
    var onPictureInPictureChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// The sheet's minimum size: AVKit's content view never starts at zero
    /// (its width / height == 0 constraints conflicted with its own).
    static let initialSize = CGSize(width: 1024, height: 576)

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(frame: NSRect(origin: .zero, size: Self.initialSize))
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        context.coordinator.onChange = onPictureInPictureChanged
        view.pictureInPictureDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
        context.coordinator.onChange = onPictureInPictureChanged
    }

    /// A proposal without a size (sheet appearing, view swap) gets the
    /// sheet's minimum, never zero.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: Self.initialSize)
    }

    /// Reports the view's Picture in Picture state.
    final class Coordinator: NSObject, AVPlayerViewPictureInPictureDelegate {
        var onChange: ((Bool) -> Void)?

        func playerViewWillStartPicture(inPicture playerView: AVPlayerView) {
            onChange?(true)
        }

        func playerView(_ playerView: AVPlayerView, failedToStartPictureInPictureWithError error: Error) {
            onChange?(false)
        }

        func playerViewDidStopPicture(inPicture playerView: AVPlayerView) {
            onChange?(false)
        }
    }
}
