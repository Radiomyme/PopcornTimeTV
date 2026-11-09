

import SwiftUI
import VLCKit
import PopcornKit

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
    @StateObject private var controller = MacVLCController()

    init(url: URL, subtitles: [Subtitle] = [], media: Media? = nil, startPosition: Float = 0) {
        self.url = url
        self.subtitles = subtitles
        self.media = media
        self.startPosition = startPosition
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
                                      set: { controller.seek(to: $0) }))

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
        .onAppear { controller.play(url, subtitles: subtitles, media: media, startPosition: startPosition) }
        .onDisappear { controller.stop() }
    }

    private var subtitleMenu: some View {
        Menu {
            Toggle("Désactivés", isOn: subtitleBinding(.off))
            if !controller.embeddedSubtitleTracks.isEmpty {
                Section("Pistes du fichier") {
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
                Text("Recherche des sous-titres…")
            }
        } label: {
            Image(systemName: controller.subtitleSelection == .off ? "captions.bubble" : "captions.bubble.fill")
                .font(.title3)
                .accessibilityLabel("Sous-titres")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sous-titres")
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
                .accessibilityLabel("Audio")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Audio")
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

    let player = VLCMediaPlayer()
    private var timer: Timer?
    private var startPosition: Float = 0
    private var didApplyStartPosition = false
    private var didAutoSelectAudio = false
    private var didAutoSelectSubtitle = false
    private var userChoseSubtitle = false
    /// Latched by `isInputReady` once VLC played with its tracks registered.
    private var didReachPlayingWithTracks = false

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

    func play(_ url: URL, subtitles: [Subtitle] = [], media: Media? = nil, startPosition: Float = 0) {
        let vlcMedia = VLCMedia(url: url)
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
        player.play()
        isPlaying = true
        self.startPosition = startPosition
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

    private func refresh() {
        // Don't fight the user mid-drag; VLC position is 0…1.
        position = player.position
        timeLabel = player.time.stringValue
        remainingLabel = player.remainingTime?.stringValue ?? "--:--"
        isPlaying = player.isPlaying

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

    func seek(to newPosition: Double) {
        player.position = newPosition
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player.delegate = nil
        player.stop()
        try? FileManager.default.removeItem(at: subtitleDirectory)
    }

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

    /// The file's own text tracks (attached OpenSubtitles slaves excluded).
    private func embeddedTextTracks() -> [VLCMediaPlayer.Track] {
        return player.textTracks.filter { !slaveTrackIdSet.contains($0.trackId) }
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
        player.position = Double(startPosition)
    }
}

struct MacVLCVideoRepresentable: NSViewRepresentable {
    let controller: MacVLCController

    func makeNSView(context: Context) -> VLCVideoView {
        let view = VLCVideoView()
        controller.player.drawable = view
        return view
    }

    func updateNSView(_ view: VLCVideoView, context: Context) {}
}
