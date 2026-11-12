

import Foundation
import SwiftUI
import VLCKit
import PopcornKit
import PopcornTorrent

/// VLC fallback for payloads the remux/AVPlayer path can't handle (DTS audio,
/// exotic containers…). Same VLCKit the iOS/tvOS apps bundle — the macOS
/// slice ships in the same xcframework. The transport bar offers the file's
/// audio tracks and its text tracks plus OpenSubtitles subtitles; the
/// preferred languages (Settings → Langues) are selected automatically.
struct MacVLCPlayerView: View {
    let url: URL
    let subtitles: [Subtitle]
    let media: Media?
    /// Resume point (fraction 0…1) when taking over from a failed AVPlayer.
    let startPosition: Float
    /// The point the session protects (MacPlayerController, read when it
    /// opened); nil = what `media` has saved now.
    let resumePoint: Float?
    /// The furthest position the native player reached before handing over.
    let nativeHighWater: Float
    /// The stream's bounded storage (nil: none): VLC's playhead tells the
    /// torrent what it may delete behind it.
    let boundedStorage: BoundedStorageSession?
    /// The stream (nil: unknown): bounded storage reads its file's Matroska
    /// tracks and what is on disk to pick VLC's demuxer
    /// (`BoundedStorageUX.vlcMediaOptions`).
    let streamer: PTTorrentStreamer?
    /// The stream's deficit watch (nil: none): VLC's position and state feed
    /// it once VLC plays (the sheet shows the offer).
    let deficitMonitor: BandwidthDeficitMonitor?
    @StateObject private var controller = MacVLCController()

    init(url: URL, subtitles: [Subtitle] = [], media: Media? = nil, startPosition: Float = 0,
         resumePoint: Float? = nil, nativeHighWater: Float = 0, boundedStorage: BoundedStorageSession? = nil,
         streamer: PTTorrentStreamer? = nil, deficitMonitor: BandwidthDeficitMonitor? = nil) {
        self.streamer = streamer
        self.deficitMonitor = deficitMonitor
        self.url = url
        self.subtitles = subtitles
        self.media = media
        self.startPosition = startPosition
        self.resumePoint = resumePoint
        self.nativeHighWater = nativeHighWater
        self.boundedStorage = boundedStorage
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MacVLCVideoRepresentable(controller: controller)
                .background(Color.black)

            // Minimal transport bar.
            HStack(spacing: 14) {
                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                Text(controller.timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Slider(value: Binding(get: { controller.position },
                                      set: { controller.scrub(to: $0) }),
                       onEditingChanged: { controller.setScrubbing($0) })

                Text(controller.remainingLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if controller.audioTracks.count > 1 {
                    audioMenu
                }
                subtitleMenu
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(16)
        }
        // Bounded storage: a rewind stopped at the earliest point still on disk.
        .boundedStorageToast(controller.boundedToast)
        .onAppear {
            controller.play(url, subtitles: subtitles, media: media, startPosition: startPosition,
                            resumePoint: resumePoint, nativeHighWater: nativeHighWater,
                            extraOptions: BoundedStorageUX.vlcMediaOptions(url: url, session: boundedStorage,
                                                                           startPosition: startPosition,
                                                                           streamer: streamer))
            controller.attachBoundedStorage(boundedStorage)
            controller.attachDeficitMonitor(deficitMonitor)
        }
        .onDisappear { controller.stop() }
    }

    private var subtitleMenu: some View {
        Menu {
            Toggle("Off", isOn: subtitleBinding(.off))
            if !controller.embeddedSubtitleTracks.isEmpty {
                Section("Tracks in the File") {
                    ForEach(controller.embeddedSubtitleTracks) { track in
                        Toggle(track.name, isOn: subtitleBinding(.embedded(track.id)))
                    }
                }
            }
            if !controller.externalSubtitles.isEmpty {
                Section("OpenSubtitles") {
                    ForEach(controller.externalSubtitles, id: \.link) { subtitle in
                        Toggle("\(ExternalSubtitleLoader.menuTitle(for: subtitle)) (OpenSubtitles)",
                               isOn: subtitleBinding(.external(subtitle.link)))
                    }
                }
            } else if controller.isSearchingSubtitles {
                Text("Searching for subtitles…")
            }
        } label: {
            Image(systemName: controller.subtitleSelection == .off ? "captions.bubble" : "captions.bubble.fill")
                .font(.title3)
                .accessibilityLabel(Text("Subtitles"))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Subtitles"))
    }

    private var audioMenu: some View {
        Menu {
            ForEach(controller.audioTracks) { track in
                Toggle(track.name, isOn: Binding(
                    get: { controller.selectedAudioTrackId == track.id },
                    set: { isOn in if isOn { controller.selectAudioTrack(id: track.id) } }
                ))
            }
        } label: {
            Image(systemName: "speaker.wave.2")
                .font(.title3)
                .accessibilityLabel(Text("Audio"))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Audio"))
    }

    /// Radio-style checkmark binding for a subtitle choice.
    private func subtitleBinding(_ choice: MacVLCController.SubtitleChoice) -> Binding<Bool> {
        Binding(
            get: { controller.subtitleSelection == choice },
            set: { isOn in if isOn { controller.selectSubtitle(choice) } }
        )
    }
}

@MainActor
final class MacVLCController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    struct TrackItem: Identifiable, Equatable {
        let id: String
        let name: String
    }

    enum SubtitleChoice: Hashable {
        case off
        case embedded(String)   // VLC text-track id
        case external(String)   // OpenSubtitles link
    }

    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var timeLabel = "--:--"
    @Published var remainingLabel = "--:--"
    @Published private(set) var audioTracks: [TrackItem] = []
    @Published private(set) var selectedAudioTrackId: String?
    @Published private(set) var embeddedSubtitleTracks: [TrackItem] = []
    @Published private(set) var externalSubtitles: [Subtitle] = []
    @Published private(set) var subtitleSelection: SubtitleChoice = .off
    @Published private(set) var isSearchingSubtitles = false
    /// Bounded storage's message over the video (a limited rewind).
    @Published private(set) var boundedToast: BoundedStorageToastMessage?

    /// VLCKit's macOS default video output (`--vout=macosx`: an NSOpenGLView
    /// it adds to the drawable from the main queue, asynchronously) aborts
    /// the whole app on its first picture when that view is not in a window
    /// yet — the drawable not attached, or the main queue busy (a SwiftUI
    /// swap, the native player's teardown) at that moment: assertion
    /// GL_INVALID_FRAMEBUFFER_OPERATION, vout_helper.c:491, exit 134. Seen
    /// in 3 of 4 hand-offs from AVPlayer (bounded storage, part 2); the same
    /// path in full mode. Reproduced standalone with VLCKit 4.0.0a21: drawable
    /// added to the window 0.15–1.5 s late, or removed just after play():
    /// 100 % abort; main queue busy 60 ms every 61 ms: 6 of 12. VLC 4's
    /// AVSampleBufferDisplayLayer output (no GL context of its own) never
    /// aborted in the same 30 runs, renders subtitles, HDR 10-bit
    /// VideoToolbox frames and software-decoded I420 (converted by VLC):
    /// it goes first; the OpenGL output stays the fallback for what it
    /// refuses (360° projections). One libVLC instance for every Mac VLC
    /// player (the default options plus this one).
    /// Its log: libvlc's errors only — its default output (clock drift,
    /// late pictures, buffering, deferred starts…) printed ~1,500 lines in
    /// two minutes of a stream handed over to VLC.
    static let library: VLCLibrary = {
        let library = VLCLibrary(options: ["--vout=samplebufferdisplay,macosx"])
        let console = VLCConsoleLogger()
        console.level = .error
        library.loggers = [console]
        return library
    }()
    let player = VLCMediaPlayer(library: MacVLCController.library)
    private var timer: Timer?
    /// `stop()` ran (a pending start then does nothing).
    private var isStopped = false
    /// The video view VLC draws into (`MacVLCVideoRepresentable`); nil
    /// until SwiftUI made it.
    private weak var videoView: MacVLCVideoView?
    /// `play()` waits for the video view to be in a window (`startWhenDrawn`).
    private var pendingStart: (() -> Void)?
    /// The longest `play()` waits for its video view (then starts anyway).
    static let drawableWaitLimit: TimeInterval = 1.5
    private var startPosition: Float = 0
    private var didApplyStartPosition = false
    private var didAutoSelectAudio = false
    private var didAutoSelectSubtitle = false
    private var userChoseSubtitle = false
    /// Latched by `isInputReady` once VLC played with its tracks registered.
    private var didReachPlayingWithTracks = false
    /// What plays: its progress is saved when the player closes.
    private var media: Media?
    /// Watched progress of this session, under the iOS / tvOS VLC players'
    /// rules (`VLCWatchProgress`): the last position VLC reported while it
    /// played (it reports -1 once the input has ended), and the hand-off
    /// position until the resume seek has landed.
    private var watch = VLCWatchProgress(startPosition: 0, resumePoint: 0)
    /// The session's furthest position before VLC: the native player's.
    private var nativeHighWater: Float = 0

    // External subtitles: downloaded right away, then — once the input is
    // ready (see `isInputReady`) — converted to UTF-8 SRT (frame-based files
    // timed with the video's frame rate, which VLC knows by then), attached
    // as a playback slave and selected by track-id diff (`enforce:` alone is
    // unreliable).
    private let subtitleDirectory = ExternalSubtitleLoader.makeWorkingDirectory()
    private var selectedExternalLink: String?
    /// Raw OpenSubtitles download per link (converted once the input is ready).
    private var downloadedSubtitleFiles: [String: (subtitle: Subtitle, url: URL)] = [:]
    /// Converted UTF-8 SRT per link.
    private var preparedSubtitleFiles: [String: URL] = [:]
    /// Link whose download is being converted (one at a time).
    private var convertingSubtitleLink: String?
    /// OpenSubtitles entry awaiting attachment (downloading, downloaded or converted).
    private var pendingSubtitleLink: String?
    private var textTrackIdsBeforeSlave: Set<String>?
    private var slaveLinkAwaitingTrack: String?
    private var slaveRequestDate: Date?
    /// Link already re-attached once after VLC failed to register its track.
    private var slaveRetryLink: String?
    /// The file's own text track the user (or auto-selection) picked.
    private var selectedEmbeddedTrackId: String?
    private var slaveTrackIds: [String: String] = [:]
    private var slaveTrackIdSet: Set<String> = []

    func play(_ url: URL, subtitles: [Subtitle] = [], media: Media? = nil, startPosition: Float = 0,
              resumePoint: Float? = nil, nativeHighWater: Float = 0, extraOptions: [String] = []) {
        let vlcMedia = VLCMedia(url: url)
        // Bounded storage: which Matroska demuxer VLC uses
        // (`BoundedStorageUX.vlcMediaOptions`).
        for option in extraOptions { vlcMedia?.addOption(option) }
        // Force software decoding on the fallback path. VLCKit 4's macOS
        // OpenGL video output aborts (CreateFilters, vout_helper.c:164) when
        // the VideoToolbox hardware decoder hands it a 10-bit / HDR pixel
        // format it can't build filters for. Software decode emits a planar
        // format the OpenGL output handles, avoiding the crash — acceptable
        // since this path only runs for the rare files the remuxer can't take.
        vlcMedia?.addOption(":avcodec-hw=none")
        player.media = vlcMedia
        didReachPlayingWithTracks = false   // a new input: its tracks aren't known yet
        player.delegate = self
        playheadWatch.noteOwnSeek()   // a start at a position settles like a seek
        startWhenDrawn(vlcMedia)
        isPlaying = true
        self.startPosition = startPosition
        self.media = media
        // The protected point is the session's — what the title had saved
        // when the player opened (the native player saves nothing when it
        // hands over) —, not `startPosition`.
        watch = VLCWatchProgress(startPosition: startPosition,
                                 resumePoint: resumePoint ?? media.map(MacPlaybackProgress.resumePoint(for:)) ?? 0)
        self.nativeHighWater = nativeHighWater
        externalSubtitles = subtitles
        if subtitles.isEmpty, let media {
            if !media.subtitles.isEmpty {
                externalSubtitles = media.subtitles
            } else {
                isSearchingSubtitles = true
                ExternalSubtitleLoader.search(for: media) { [weak self] found in
                    guard let self else { return }
                    self.isSearchingSubtitles = false
                    if self.externalSubtitles.isEmpty { self.externalSubtitles = found }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Plays `vlcMedia` once VLC's video view is in a window: at once when
    /// it already is, else when SwiftUI puts it there (`videoViewDidAppear`),
    /// at most `drawableWaitLimit` later. VLC opens its video output on the
    /// first picture and needs a drawable in a window then (see `library`).
    private func startWhenDrawn(_ vlcMedia: VLCMedia?) {
        var started = false
        let start = { [weak self] in
            guard let self, !started, self.player.media === vlcMedia, !self.isStopped else { return }
            started = true
            self.pendingStart = nil
            self.player.play()
        }
        if let view = videoView, view.window != nil {
            start()
            return
        }
        pendingStart = start
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.drawableWaitLimit) {
            if !started { print("[MacVLC] video view not in a window after \(Self.drawableWaitLimit) s — starting anyway") }
            start()
        }
    }

    /// `MacVLCVideoRepresentable`: VLC's drawable, made by SwiftUI.
    func attachVideoView(_ view: MacVLCVideoView) {
        videoView = view
        player.drawable = view
        view.onWindow = { [weak self] in self?.videoViewDidAppear() }
        if view.window != nil { videoViewDidAppear() }
    }

    /// The video view is in a window: a start waiting for it goes now.
    private func videoViewDidAppear() {
        guard let start = pendingStart, videoView?.window != nil else { return }
        // The next turn of the main queue: SwiftUI finishes the swap first.
        DispatchQueue.main.async { start() }
    }

    private func refresh() {
        // Don't fight the user mid-drag; VLC position is 0…1.
        position = player.position
        timeLabel = player.time.stringValue
        remainingLabel = player.remainingTime?.stringValue ?? "--:--"
        isPlaying = player.isPlaying
        notePlayerPosition()
        checkBoundedPlayhead()

        if isInputReady {
            applyStartPositionIfNeeded()
            autoSelectAudioIfNeeded()
            autoSelectSubtitleIfNeeded()
            applyPendingSubtitle()
            selectSlaveTextTrackIfNeeded()
        }
        refreshTrackLists()
    }

    /// True once VLC really plays the input with its tracks registered.
    /// VLCKit 4 reports `isPlaying` from `play()` on — through the whole
    /// `.opening` phase, which can last seconds on a torrent stream — while
    /// the demuxer hasn't registered a single track yet. Deciding then would
    /// pick OpenSubtitles over the file's own subtitle track, give up on the
    /// preferred language for good, or snapshot an empty track list before
    /// attaching a slave (every embedded track then looks like the slave's
    /// and vanishes from the menu). So: wait for the `.playing` state with an
    /// audio or video track listed (the file's own text tracks are registered
    /// by then), latch it, and from then on only require the input to run.
    private var isInputReady: Bool {
        let state = player.state
        if !didReachPlayingWithTracks {
            guard state == .playing, !player.audioTracks.isEmpty || !player.videoTracks.isEmpty else { return false }
            didReachPlayingWithTracks = true
        }
        return state == .playing || state == .paused
    }

    // MARK: - VLCMediaPlayerDelegate

    /// `.playing`: the tracks are known — decide now rather than on the next
    /// 0.5 s tick. Nonisolated + hop: safe whatever thread VLCKit calls from.
    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        guard newState == .playing else { return }
        Task { @MainActor [weak self] in
            guard let self, self.timer != nil else { return }
            self.refresh()
        }
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying = player.isPlaying
    }

    /// The user drags the slider (`setScrubbing`).
    private var isScrubbing = false
    /// Bounded storage: where a drag over what is no longer on disk stands;
    /// sent (and limited) once the drag ends.
    private var pendingScrub: Double?

    /// The slider's value while the user moves it: VLC follows the drag as
    /// before — except, bounded storage, over what is no longer on disk:
    /// nothing is sent there, and the drag is limited once, where it ends
    /// (`setScrubbing(false)`), instead of snapping back with the message
    /// at every step (verify-playback 5).
    func scrub(to newPosition: Double) {
        guard isScrubbing, boundedStorage?.isBounded == true, let duration = durationSeconds, duration > 0,
              let now = playheadSeconds,
              BoundedStorageUX.limitedRewindTarget(newPosition * duration, from: now, session: boundedStorage) != nil else {
            seek(to: newPosition)
            return
        }
        position = newPosition
        pendingScrub = newPosition
    }

    /// The slider's drag starts (true) or ends (false).
    func setScrubbing(_ editing: Bool) {
        isScrubbing = editing
        guard !editing, let pending = pendingScrub else { return }
        seek(to: pending)
    }

    func seek(to newPosition: Double) {
        pendingScrub = nil
        // The position VLC reports from now on is the user's, even before
        // the hand-off point. (A non-seekable input ignores the slider.)
        if player.isSeekable { watch.userMovedPlayhead() }
        var position = newPosition
        // Bounded storage: a drag further back than what is still on disk
        // stops at the earliest point still available.
        if let duration = durationSeconds, duration > 0 {
            let limited = limitedSeekSeconds(position * duration)
            if limited != position * duration {
                position = min(1, max(0, limited / duration))
                self.position = position
            }
        }
        playheadWatch.noteOwnSeek()
        player.position = position
    }

    // MARK: Bounded storage: rewinds

    /// VLC's playhead in seconds; nil before its first time point.
    private var playheadSeconds: Double? {
        guard let milliseconds = player.time.value?.doubleValue, milliseconds > 0 else { return nil }
        return milliseconds / 1000
    }

    /// The input's length in seconds, nil while unknown.
    private var durationSeconds: Double? {
        if let length = player.media?.length.value?.doubleValue, length > 0 { return length / 1000 }
        if let remaining = player.remainingTime?.value?.doubleValue, let elapsed = player.time.value?.doubleValue {
            let total = abs(remaining) + elapsed
            return total > 0 ? total / 1000 : nil
        }
        return nil
    }

    /// VLC's time at the refreshes (`checkBoundedPlayhead`).
    private var playheadWatch = VLCPlayheadWatch()

    /// Bounded storage (`boundedStorage`; its `isBounded` is false in full
    /// mode): where a seek to `seconds` goes — the earliest point still
    /// available when it is further back than what is still on disk (the
    /// user's decision: no new download, no rewind into deleted data), with
    /// the message; `seconds` otherwise.
    private func limitedSeekSeconds(_ seconds: Double) -> Double {
        guard let now = playheadSeconds,
              let landing = BoundedStorageUX.limitedRewindTarget(seconds, from: now, session: boundedStorage) else { return seconds }
        BoundedStorageUX.logLimited(player: "VLC", target: seconds, playhead: now, landing: landing)
        showBoundedToast()
        return landing
    }

    /// Bounded storage, every refresh: VLC's time went back past what is
    /// still on disk by a path not limited above — back to the earliest
    /// point still available, with the message.
    private func checkBoundedPlayhead() {
        // Not VLC settling after a start or seek (`VLCPlayheadWatch`).
        guard let now = playheadSeconds, let previous = playheadWatch.rewind(to: now),
              let landing = BoundedStorageUX.limitedRewindTarget(now, from: previous, session: boundedStorage) else { return }
        BoundedStorageUX.logLimited(player: "VLC (refresh)", target: now, playhead: previous, landing: landing)
        playheadWatch.noteOwnSeek()
        player.time = VLCTime(number: NSNumber(value: landing * 1000))
        showBoundedToast()
    }

    private func showBoundedToast() {
        let toast = BoundedStorageToastMessage(text: BoundedStorageUX.rewindLimitedMessage(for: boundedStorage))
        boundedToast = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + BoundedStorageToastMessage.visibleSeconds) { [weak self] in
            guard let self, self.boundedToast?.id == toast.id else { return }
            self.boundedToast = nil
        }
    }

    /// One position for the watched progress, while VLC plays or is paused
    /// (`VLCWatchProgress.note` ignores the -1 of an input that ended).
    private func notePlayerPosition() {
        guard player.state == .playing || player.state == .paused else { return }
        watch.note(position: player.position)
    }

    func stop() {
        // Closing: save where playback got (≥ 80 % marks the title watched):
        // the last position VLC reported while playing — a title played to
        // its end keeps its last one — or the hand-off position while the
        // resume seek has not landed. A smaller fraction never replaces the
        // saved one unless the session — the native player before VLC, or
        // VLC — played past it (`VLCWatchProgress`, `ResumePolicy`).
        notePlayerPosition()
        if let media, let current = watch.current,
           let value = ResumePolicy.progressToSave(current: current, resumePoint: watch.resumePoint,
                                                   highWater: max(watch.highWater, current, nativeHighWater),
                                                   userRestarted: false) {
            MacPlaybackProgress.store(value, for: media)
        }
        media = nil
        isStopped = true
        deficitMonitor?.detach(self)
        deficitMonitor = nil
        timer?.invalidate()
        timer = nil
        player.delegate = nil
        player.stop()
        boundedStorage?.detachHTTPPlayer(self)
        boundedStorage = nil
        try? FileManager.default.removeItem(at: subtitleDirectory)
    }

    /// The stream's bounded storage, if any (see `BoundedStorageSession`).
    private var boundedStorage: BoundedStorageSession?

    /// The stream's deficit watch (`BandwidthDeficitMonitor`), if any.
    private var deficitMonitor: BandwidthDeficitMonitor?

    /// VLC reports to the stream's deficit watch from now on (it replaces
    /// the native player there). A stall is inferred from a time that does
    /// not move while VLC plays (VLCKit 4 has no buffering state).
    func attachDeficitMonitor(_ monitor: BandwidthDeficitMonitor?) {
        deficitMonitor = monitor
        monitor?.attach(self) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isStopped else { return nil }
                return BandwidthDeficitMonitor.PlaybackState(playhead: self.playheadSeconds, duration: self.durationSeconds,
                                                             hasStarted: self.didReachPlayingWithTracks,
                                                             wantsPlayback: self.player.state == .playing,
                                                             isStalled: nil)
            }
        }
    }

    /// Reports VLC's playhead to the stream's bounded storage (it reads
    /// through PopcornTorrent's server, which moves the window itself).
    func attachBoundedStorage(_ session: BoundedStorageSession?) {
        #if DEBUG
        // BoundedStorageDebugHooks' scripted seeks and pauses.
        NotificationCenter.default.addObserver(self, selector: #selector(debugScriptSeek(_:)), name: .ptDebugSeek, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(debugScriptPlayback(_:)), name: .ptDebugPlayback, object: nil)
        #endif
        guard let session else { return }
        boundedStorage = session
        session.attachHTTPPlayer(self, readAheadSeconds: 10) { [weak self] in
            guard let self, let milliseconds = self.player.time.value?.doubleValue, milliseconds > 0 else { return nil }
            return BoundedPlayerSample(time: milliseconds / 1000, isPlaying: self.player.isPlaying)
        }
    }

    #if DEBUG
    /// `-PTDebugSeek` (BoundedStorageDebugHooks): VLC to that time.
    @objc private func debugScriptSeek(_ note: Notification) {
        guard let seconds = note.userInfo?["seconds"] as? Double else { return }
        print("[BoundedDebug] VLC seek → \(Int(seconds)) s")
        // Limited like a user's seek (bounded storage).
        let target = limitedSeekSeconds(seconds)
        playheadWatch.noteOwnSeek()
        player.time = VLCTime(number: NSNumber(value: Int32(clamping: Int64(target * 1000))))
    }

    /// `-PTDebugPause` (BoundedStorageDebugHooks).
    @objc private func debugScriptPlayback(_ note: Notification) {
        guard let playing = note.userInfo?["playing"] as? Bool else { return }
        if playing { player.play() } else { player.pause() }
        isPlaying = player.isPlaying
    }
    #endif

    // MARK: - Tracks

    func selectAudioTrack(id: String) {
        didAutoSelectAudio = true // the user's choice wins from now on
        player.audioTracks.first(where: { $0.trackId == id })?.isSelectedExclusively = true
        refreshTrackLists()
    }

    func selectSubtitle(_ choice: SubtitleChoice) {
        userChoseSubtitle = true
        switch choice {
        case .off:
            selectedExternalLink = nil
            selectedEmbeddedTrackId = nil
            pendingSubtitleLink = nil
            player.deselectAllTextTracks()
        case .embedded(let id):
            selectedExternalLink = nil
            selectedEmbeddedTrackId = id
            pendingSubtitleLink = nil
            player.textTracks.first(where: { $0.trackId == id })?.isSelectedExclusively = true
        case .external(let link):
            if let subtitle = externalSubtitles.first(where: { $0.link == link }) {
                selectExternalSubtitle(subtitle)
            }
        }
        refreshTrackLists()
    }

    /// The file's own text tracks VLC can show (attached OpenSubtitles
    /// slaves excluded, and the tracks no decoder takes: libavformat's
    /// demuxer lists SRT / ASS / WebVTT tracks with no codec —
    /// `BoundedStorageUX.isUndecodableVLCTrack`).
    private func embeddedTextTracks() -> [VLCMediaPlayer.Track] {
        return player.textTracks.filter {
            !slaveTrackIdSet.contains($0.trackId) && !BoundedStorageUX.isUndecodableVLCTrack(codec: $0.codec)
        }
    }

    private func refreshTrackLists() {
        let audio = player.audioTracks.map { TrackItem(id: $0.trackId, name: $0.trackName) }
        if audio != audioTracks { audioTracks = audio }
        let selectedAudio = player.audioTracks.first(where: { $0.isSelected })?.trackId
        if selectedAudio != selectedAudioTrackId { selectedAudioTrackId = selectedAudio }

        let text = embeddedTextTracks().map { TrackItem(id: $0.trackId, name: $0.trackName) }
        if text != embeddedSubtitleTracks { embeddedSubtitleTracks = text }

        let selection: SubtitleChoice
        if let link = selectedExternalLink {
            selection = .external(link)   // even while downloading / attaching
        } else if let track = player.textTracks.first(where: { $0.isSelected }) {
            if let link = slaveTrackIds.first(where: { $0.value == track.trackId })?.key {
                selection = .external(link)
            } else {
                selection = .embedded(track.trackId)
            }
        } else {
            selection = .off
        }
        if selection != subtitleSelection { subtitleSelection = selection }
    }

    private func selectExternalSubtitle(_ subtitle: Subtitle) {
        selectedExternalLink = subtitle.link
        selectedEmbeddedTrackId = nil
        if let trackId = slaveTrackIds[subtitle.link],
           let track = player.textTracks.first(where: { $0.trackId == trackId }) {
            pendingSubtitleLink = nil
            track.isSelectedExclusively = true
            return
        }
        pendingSubtitleLink = subtitle.link
        if preparedSubtitleFiles[subtitle.link] != nil || downloadedSubtitleFiles[subtitle.link] != nil {
            applyPendingSubtitle()
            return
        }
        ExternalSubtitleLoader.download(subtitle, into: subtitleDirectory) { [weak self] url in
            guard let self, self.timer != nil else { return }
            guard let url else {
                print("[MacVLC] subtitles: download failed for '\(subtitle.language)'")
                if self.selectedExternalLink == subtitle.link { self.selectedExternalLink = nil }
                if self.pendingSubtitleLink == subtitle.link { self.pendingSubtitleLink = nil }
                self.refreshTrackLists()
                return
            }
            self.downloadedSubtitleFiles[subtitle.link] = (subtitle, url)
            self.applyPendingSubtitle()   // if still the wanted one
        }
    }

    /// The playing video's frame rate (selected video track), nil while VLC
    /// doesn't know it.
    private func currentVideoFrameRate() -> Double? {
        guard let video = (player.videoTracks.first(where: { $0.isSelected }) ?? player.videoTracks.first)?.video else { return nil }
        return ExternalSubtitleLoader.videoFrameRate(numerator: video.frameRate, denominator: video.frameRateDenominator)
    }

    /// Converts the downloaded file of `link` to UTF-8 SRT — frame-based
    /// files timed with the video's frame rate (the input is ready, so VLC
    /// knows it) — then attaches whatever is pending.
    private func convertDownloadedSubtitle(link: String) {
        guard convertingSubtitleLink == nil, let download = downloadedSubtitleFiles[link] else { return }
        convertingSubtitleLink = link
        let frameRate = currentVideoFrameRate()
        print("[MacVLC] subtitles: converting '\(download.subtitle.language)' for VLC (video \(frameRate.map { String(format: "%.3f fps", $0) } ?? "frame rate unknown"))")
        ExternalSubtitleLoader.convertForVLC(fileAt: download.url, subtitle: download.subtitle, frameRate: frameRate) { [weak self] file in
            guard let self, self.timer != nil else { return }
            self.convertingSubtitleLink = nil
            self.preparedSubtitleFiles[link] = file
            self.applyPendingSubtitle()
        }
    }

    /// Attach the pending subtitle — only once the input is ready: VLCKit
    /// drops a slave added before the input runs, and the track ids
    /// snapshotted here must already include every track of the file. A
    /// downloaded file is converted first (the video's frame rate is known now).
    private func applyPendingSubtitle() {
        guard let link = pendingSubtitleLink, textTrackIdsBeforeSlave == nil, isInputReady else { return }
        guard let file = preparedSubtitleFiles[link] else {
            convertDownloadedSubtitle(link: link)   // no-op while still downloading
            return
        }
        let priorIds = Set(player.textTracks.map { $0.trackId })
        let result = player.addPlaybackSlave(file, type: .subtitle, enforce: true)
        guard result == 0 else {
            print("[MacVLC] subtitles: addPlaybackSlave refused (\(result)), will retry")
            return
        }
        pendingSubtitleLink = nil
        textTrackIdsBeforeSlave = priorIds
        slaveLinkAwaitingTrack = link
        slaveRequestDate = Date()
    }

    /// Select the slave's text track once VLC registers it. Recognised by its
    /// track id (`ExternalSubtitleLoader.slaveTrackIds`), never "the last new
    /// track": the file's own text tracks — even one registering late — are
    /// never picked (or hidden from the menu) by mistake.
    private func selectSlaveTextTrackIfNeeded() {
        guard let priorIds = textTrackIdsBeforeSlave, let link = slaveLinkAwaitingTrack else { return }
        let tracks = player.textTracks
        let registered = ExternalSubtitleLoader.slaveTrackIds(tracks.map { $0.trackId }, addedAfter: priorIds)
        guard let slaveId = registered.last, let slaveTrack = tracks.first(where: { $0.trackId == slaveId }) else {
            // Not registered yet — keep waiting a few seconds, then re-attach
            // once; after that give up so later selections aren't blocked.
            guard let requested = slaveRequestDate, Date().timeIntervalSince(requested) > 8 else { return }
            textTrackIdsBeforeSlave = nil
            slaveLinkAwaitingTrack = nil
            slaveRequestDate = nil
            if slaveRetryLink != link, selectedExternalLink == link, preparedSubtitleFiles[link] != nil {
                slaveRetryLink = link
                pendingSubtitleLink = link
                applyPendingSubtitle()
            } else {
                print("[MacVLC] subtitles: VLC never registered the OpenSubtitles track — giving up")
                if selectedExternalLink == link { selectedExternalLink = nil }
            }
            return
        }
        slaveTrackIdSet.formUnion(registered)
        slaveTrackIds[link] = slaveTrack.trackId
        textTrackIdsBeforeSlave = nil
        slaveLinkAwaitingTrack = nil
        slaveRequestDate = nil
        if selectedExternalLink == link {
            slaveTrack.isSelectedExclusively = true
            print("[MacVLC] subtitles ON: '\(slaveTrack.trackName)' (\(slaveTrack.trackId))")
        } else {
            applyCurrentSubtitleChoice() // the user moved on while it loaded
        }
    }

    /// Re-applies the current choice — used when a slave the user no longer
    /// wants registers (VLC may select it on its own because of `enforce:`).
    private func applyCurrentSubtitleChoice() {
        if let link = selectedExternalLink {
            if let id = slaveTrackIds[link], let track = player.textTracks.first(where: { $0.trackId == id }) {
                track.isSelectedExclusively = true
            } // else: still downloading / pending — attached and selected later
        } else if let id = selectedEmbeddedTrackId, let track = player.textTracks.first(where: { $0.trackId == id }) {
            track.isSelectedExclusively = true
        } else {
            player.deselectAllTextTracks()
        }
    }

    // MARK: - Preferred languages

    private func autoSelectAudioIfNeeded() {
        guard !didAutoSelectAudio, isInputReady else { return }
        let tracks = player.audioTracks
        guard !tracks.isEmpty else { return }
        didAutoSelectAudio = true
        guard tracks.count > 1, let code = PlaybackLanguagePreferences.preferredAudioLanguageCode else { return }
        let matching = tracks.filter {
            PlaybackLanguagePreferences.matches($0.language, code: code)
                || PlaybackLanguagePreferences.matches($0.trackName, code: code)
        }
        guard !matching.isEmpty else { return }
        func isSecondary(_ track: VLCMediaPlayer.Track) -> Bool {
            return PlaybackLanguagePreferences.isCommentary(track.trackName)
                || PlaybackLanguagePreferences.isAudioDescription(track.trackName)
        }
        if let current = tracks.first(where: { $0.isSelected }),
           matching.contains(where: { $0.trackId == current.trackId }), !isSecondary(current) { return }
        let best = matching.first(where: { !isSecondary($0) }) ?? matching[0]
        print("[MacVLC] auto-selecting audio track '\(best.trackName)' for '\(code)'")
        best.isSelectedExclusively = true
    }

    /// Preferred subtitle language (Settings): the file's own matching text
    /// track first (never a forced-only one), else the OpenSubtitles entry.
    /// Runs only once the input is ready, so the file's tracks are known.
    private func autoSelectSubtitleIfNeeded() {
        guard !didAutoSelectSubtitle, !userChoseSubtitle, isInputReady else { return }
        guard let code = PlaybackLanguagePreferences.preferredSubtitleLanguageCode else {
            didAutoSelectSubtitle = true
            return
        }
        let embedded = embeddedTextTracks().filter {
            (PlaybackLanguagePreferences.matches($0.language, code: code)
                || PlaybackLanguagePreferences.matches($0.trackName, code: code))
                && !PlaybackLanguagePreferences.isForcedSubtitle($0.trackName)
        }
        if let track = embedded.first(where: { !PlaybackLanguagePreferences.isHearingImpaired($0.trackName) }) ?? embedded.first {
            didAutoSelectSubtitle = true
            selectedEmbeddedTrackId = track.trackId
            if !track.isSelected { track.isSelectedExclusively = true }
            print("[MacVLC] auto-selecting subtitle track '\(track.trackName)' for '\(code)'")
            return
        }
        if let subtitle = ExternalSubtitleLoader.preferredSubtitle(in: externalSubtitles, code: code) {
            didAutoSelectSubtitle = true
            print("[MacVLC] auto-selecting OpenSubtitles '\(subtitle.language)' for '\(code)'")
            selectExternalSubtitle(subtitle)
            return
        }
        // No match among the (known) tracks: wait while the OpenSubtitles
        // search runs; otherwise give up.
        if !isSearchingSubtitles { didAutoSelectSubtitle = true }
    }

    private func applyStartPositionIfNeeded() {
        guard !didApplyStartPosition, startPosition > 0, startPosition < 1, player.isSeekable else { return }
        didApplyStartPosition = true
        playheadWatch.noteOwnSeek()
        player.position = Double(startPosition)
    }
}

struct MacVLCVideoRepresentable: NSViewRepresentable {
    let controller: MacVLCController

    func makeNSView(context: Context) -> MacVLCVideoView {
        let view = MacVLCVideoView()
        controller.attachVideoView(view)
        return view
    }

    func updateNSView(_ view: MacVLCVideoView, context: Context) {}
}

/// VLC's drawable: says when SwiftUI has put it in a window
/// (`MacVLCController.startWhenDrawn`).
final class MacVLCVideoView: VLCVideoView {
    var onWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindow?() }
    }
}
