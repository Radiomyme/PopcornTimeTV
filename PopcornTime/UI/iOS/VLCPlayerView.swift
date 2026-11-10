

import SwiftUI
import UIKit
import VLCKit
import PopcornTorrent
import PopcornKit

/// SwiftUI wrapper around a `VLCMediaPlayer` so the iOS app can play formats
/// AVPlayer can't open (.avi, .ts, exotic codecs) and act as the automatic
/// fallback when the native (remux / AVPlayer) path fails.
struct VLCPlayerView: UIViewControllerRepresentable {
    let url: URL
    let title: String
    let streamer: PTTorrentStreamer?
    /// OpenSubtitles candidates (best per language). When empty and `media`
    /// is set, the player searches OpenSubtitles itself.
    var subtitles: [Subtitle] = []
    /// The movie / episode playing: OpenSubtitles search, watched progress.
    var media: Media? = nil
    /// Where VLC starts, as a fraction of the duration (0…1): the position a
    /// failed AVPlayer session handed over, else the saved progress (0 for a
    /// finished title). 0 = start.
    var startPosition: Float = 0

    func makeUIViewController(context: Context) -> VLCPlayerViewController {
        let vc = VLCPlayerViewController()
        vc.url      = url
        vc.title    = title
        vc.streamer = streamer
        vc.externalSubtitles = subtitles
        vc.media = media
        vc.startPosition = startPosition
        return vc
    }

    func updateUIViewController(_ vc: VLCPlayerViewController, context: Context) {}
}

#if DEBUG
/// Prints ONLY VLC's audio-pipeline log lines (aout / spdif / eac3 / a52 /
/// avsamplebuffer…) so the passthrough negotiation is visible in Xcode's
/// console without libvlc's full debug flood.
final class VLCAudioLogFilter: NSObject, VLCLogging {
    var level: VLCLogLevel = .debug
    private let keywords = ["aout", "audio output", "spdif", "eac3", "a52", "passthrough", "avsamplebuffer", "audiounit"]
    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let module = context?.module ?? ""
        let haystack = (module + " " + message).lowercased()
        guard keywords.contains(where: { haystack.contains($0) }) else { return }
        print("[VLC \(module)] \(message)")
    }
}
#endif

/// Bare-bones VLC player VC: a movie surface, a tap-to-toggle controls
/// overlay (play/pause, scrubbing, time labels, close), and the same
/// max-quality VLCMedia options the tvOS player uses (5s caches,
/// drop-late-frames=0). Track pickers list the file's own audio / text
/// tracks plus OpenSubtitles subtitles (attached as VLC playback slaves);
/// the preferred audio / subtitle languages are selected automatically.
///
/// Saves the watched position like the native players (local progress,
/// Trakt scrobble, watched mark from 80 %): at close (`.finished`), on pause
/// and when the app goes to the background (`.paused`). The saved progress
/// the title had when this player opened — the resume point, or what the
/// native player saved at its hand-off — is never replaced by a smaller
/// fraction unless VLC played past it (`VLCWatchProgress`, PlaybackRouting.swift:
/// the same rules as the tvOS VLC player).
final class VLCPlayerViewController: UIViewController, VLCMediaPlayerDelegate, UIGestureRecognizerDelegate {
    var url: URL!
    var streamer: PTTorrentStreamer?
    /// OpenSubtitles candidates offered next to the file's own text tracks.
    var externalSubtitles: [Subtitle] = []
    /// Used to search OpenSubtitles when `externalSubtitles` is empty, and
    /// to save the watched progress.
    var media: Media?
    /// Resume fraction (0…1), applied once the stream is seekable.
    var startPosition: Float = 0
    /// This session's watched progress — set up in `viewDidLoad`, once
    /// `startPosition` and `media` are known.
    private var watchProgress = VLCWatchProgress(startPosition: 0, resumePoint: 0)

    // Same passthrough attempt as the tvOS player: force VLC's
    // AVSampleBufferAudioRenderer output and enable the core spdif option so
    // AC-3/E-AC-3 (incl. DD+ Atmos) is handed COMPRESSED to Apple's renderer,
    // which is what performs Atmos (spatial) rendering on macOS — VLC's own
    // decoder would discard the Atmos metadata and emit plain PCM. If the
    // encoded device is refused, playback falls back to decoded PCM exactly
    // as before, so the attempt costs nothing.
    private let player: VLCMediaPlayer = {
        var options = ["--aout=avsamplebuffer,any"]
        if UserDefaults.standard.object(forKey: "audioPassthrough") as? Bool ?? true {
            options.append("--spdif")
        }
        return VLCMediaPlayer(options: options)
    }()
    private var didEnablePassthrough = false
    private let movieView = UIView()
    private let controlsView = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let statsButton = UIButton(type: .system)
    private let progressSlider = UISlider()
    private let timeLabel = UILabel()
    private let durationLabel = UILabel()
    private let titleLabel = UILabel()
    private var hideControlsTask: DispatchWorkItem?

    // Nerd-stats overlay (toggled by the gauge button or the "n" key).
    private var nerdStatsContainer: UIView?
    private var nerdStatsLabel: UILabel?
    private var nerdStatsTimer: Timer?

    // MARK: External subtitles / auto-selection state

    /// Scratch directory for downloaded / converted subtitle files.
    private let subtitleDirectory = ExternalSubtitleLoader.makeWorkingDirectory()
    private var isSearchingSubtitles = false
    /// Link of the OpenSubtitles entry the user (or auto-selection) wants on.
    private var selectedExternalLink: String?
    /// Raw OpenSubtitles download per subtitle link. It is converted for VLC
    /// only once the input is ready: frame-based files (MicroDVD) are timed
    /// with the video's frame rate, which VLC knows by then.
    private var downloadedSubtitleFiles: [String: (subtitle: Subtitle, url: URL)] = [:]
    /// Converted UTF-8 SRT per subtitle link.
    private var preparedSubtitleFiles: [String: URL] = [:]
    /// Link whose download is being converted for VLC (one at a time).
    private var convertingSubtitleLink: String?
    /// OpenSubtitles entry awaiting attachment (downloading, downloaded or
    /// converted). VLCKit drops an `addPlaybackSlave` issued before the media
    /// is playing, so the file is held and (re)applied once the player
    /// actually plays.
    private var pendingSubtitleLink: String?
    /// Text-track ids that existed before the last `addPlaybackSlave` call.
    /// Non-nil means "a slave was added and its track hasn't been selected
    /// yet" — VLCKit 4's `enforce:` flag does NOT reliably select the slave's
    /// track, so we watch for the new track to appear (it registers a moment
    /// after the call) and select it explicitly from the time-changed tick.
    private var textTrackIdsBeforeSlave: Set<String>?
    private var slaveLinkAwaitingTrack: String?
    private var slaveRequestDate: Date?
    /// Link already re-attached once after VLC failed to register its track.
    private var slaveRetryLink: String?
    /// The file's own text track the user (or auto-selection) picked.
    private var selectedEmbeddedTrackId: String?
    /// VLC text-track id of each attached OpenSubtitles file.
    private var slaveTrackIds: [String: String] = [:]
    /// Every text-track id that belongs to an attached slave (hidden from
    /// the "embedded" list even if a retry produced a duplicate).
    private var slaveTrackIdSet: Set<String> = []
    private var didAutoSelectAudio = false
    private var didAutoSelectSubtitle = false
    private var userChoseSubtitle = false
    private var didApplyStartPosition = false
    private var isClosing = false
    /// Latched by `isInputReady` once VLC played with its tracks registered.
    private var didReachPlayingWithTracks = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // The protected point is what the title has saved NOW — the resume
        // point it opened with, or the native player's save at its hand-off
        // (made before this player exists) — not `startPosition`.
        let saved = Self.savedProgress(for: media)
        watchProgress = VLCWatchProgress(startPosition: startPosition,
                                         resumePoint: ResumePolicy.startPosition(forSavedProgress: saved))
        // A kill in the background (or a crash later) keeps what was watched.
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)

        movieView.translatesAutoresizingMaskIntoConstraints = false
        movieView.backgroundColor = .black
        view.addSubview(movieView)

        configureControlsLayout()

        player.delegate = self
        player.drawable = movieView
#if DEBUG
        player.libraryInstance.loggers = [VLCAudioLogFilter()]
#endif
        guard let media = VLCMedia(url: url) else { return } // VLCKit 4: failable init
        media.addOptions([
            "network-caching":  NSNumber(value: 5000),
            "file-caching":     NSNumber(value: 5000),
            "live-caching":     NSNumber(value: 5000),
            "drop-late-frames": NSNumber(value: 0),
            "skip-frames":      NSNumber(value: 0),
        ])
        player.media = media

        // Tap anywhere toggles controls. Attached to the ROOT view, not the
        // movie surface: VLCKit's drawable installs its own rendering
        // subviews over movieView, and on macOS those swallow mouse clicks —
        // a recognizer on movieView never fired there, so once the controls
        // auto-hid they could never be brought back. Taps landing on the
        // control bar itself are filtered out via the gesture delegate.
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)

        // Pointer hover (Mac / iPad trackpad) reveals the controls, like any
        // native video player.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverDidChange(_:)))
        view.addGestureRecognizer(hover)

        loadExternalSubtitlesIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        player.play()
        scheduleHideControls()
        // Put us in the responder chain so the keyboard shortcuts (space,
        // arrow keys) work on Mac and iPad with a hardware keyboard.
        becomeFirstResponder()
    }

    // MARK: - Keyboard (Mac / iPad hardware keyboard)

    override var canBecomeFirstResponder: Bool { return true }

    override var keyCommands: [UIKeyCommand]? {
        let space = UIKeyCommand(input: " ", modifierFlags: [], action: #selector(togglePlayback))
        let back  = UIKeyCommand(input: UIKeyCommand.inputLeftArrow,  modifierFlags: [], action: #selector(seekBackward))
        let fwd   = UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(seekForward))
        let stats = UIKeyCommand(input: "n", modifierFlags: [], action: #selector(toggleNerdStats))
        // Without priority, the system eats space/arrows for focus/scroll.
        [space, back, fwd, stats].forEach { $0.wantsPriorityOverSystemBehavior = true }
        return [space, back, fwd, stats]
    }

    @objc private func seekBackward() {
        player.jumpBackward(10)
        noteUserMovedPlayhead()
        showControls()
    }

    @objc private func seekForward() {
        player.jumpForward(10)
        noteUserMovedPlayhead()
        showControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !isClosing {
            // Before stop(): the last position VLC reached.
            notePlayerPosition()
            saveProgress(status: .finished)
        }
        isClosing = true
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        nerdStatsTimer?.invalidate()
        nerdStatsTimer = nil
        player.stop()
        streamer?.cancelStreamingAndDeleteData(false)
        streamer = nil
        try? FileManager.default.removeItem(at: subtitleDirectory)
    }

    // MARK: - Layout

    private func configureControlsLayout() {
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        controlsView.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        view.addSubview(controlsView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        controlsView.addSubview(titleLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 28, weight: .regular), forImageIn: .normal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        controlsView.addSubview(closeButton)

        // Subtitle picker (CC icon) — the file's text tracks + OpenSubtitles.
        subtitleButton.translatesAutoresizingMaskIntoConstraints = false
        subtitleButton.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        subtitleButton.tintColor = .white
        subtitleButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .regular), forImageIn: .normal)
        subtitleButton.addTarget(self, action: #selector(showSubtitlePicker), for: .touchUpInside)
        subtitleButton.accessibilityLabel = "Sous-titres"
        controlsView.addSubview(subtitleButton)

        // Audio track picker (speaker icon) — for multi-language releases.
        audioButton.translatesAutoresizingMaskIntoConstraints = false
        audioButton.setImage(UIImage(systemName: "speaker.wave.2"), for: .normal)
        audioButton.tintColor = .white
        audioButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .regular), forImageIn: .normal)
        audioButton.addTarget(self, action: #selector(showAudioPicker), for: .touchUpInside)
        audioButton.accessibilityLabel = "Audio"
        controlsView.addSubview(audioButton)

        // Nerd stats toggle (gauge icon).
        statsButton.translatesAutoresizingMaskIntoConstraints = false
        statsButton.setImage(UIImage(systemName: "gauge"), for: .normal)
        statsButton.tintColor = .white
        statsButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .regular), forImageIn: .normal)
        statsButton.addTarget(self, action: #selector(toggleNerdStats), for: .touchUpInside)
        controlsView.addSubview(statsButton)

        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 36, weight: .regular), forImageIn: .normal)
        playPauseButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        controlsView.addSubview(playPauseButton)

        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.minimumValue = 0
        progressSlider.maximumValue = 1
        progressSlider.tintColor = .white
        progressSlider.addTarget(self, action: #selector(scrub), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(scheduleHideControls), for: .touchUpInside)
        controlsView.addSubview(progressSlider)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .white
        timeLabel.text = "00:00"
        controlsView.addSubview(timeLabel)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.textColor = .white
        durationLabel.text = "--:--"
        durationLabel.textAlignment = .right
        controlsView.addSubview(durationLabel)

        NSLayoutConstraint.activate([
            movieView.topAnchor.constraint(equalTo: view.topAnchor),
            movieView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            movieView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            movieView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            controlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controlsView.heightAnchor.constraint(equalToConstant: 130),

            titleLabel.topAnchor.constraint(equalTo: controlsView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsButton.leadingAnchor, constant: -8),

            closeButton.topAnchor.constraint(equalTo: controlsView.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            subtitleButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            subtitleButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            subtitleButton.widthAnchor.constraint(equalToConstant: 36),
            subtitleButton.heightAnchor.constraint(equalToConstant: 36),

            audioButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            audioButton.trailingAnchor.constraint(equalTo: subtitleButton.leadingAnchor, constant: -8),
            audioButton.widthAnchor.constraint(equalToConstant: 36),
            audioButton.heightAnchor.constraint(equalToConstant: 36),

            statsButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            statsButton.trailingAnchor.constraint(equalTo: audioButton.leadingAnchor, constant: -8),
            statsButton.widthAnchor.constraint(equalToConstant: 36),
            statsButton.heightAnchor.constraint(equalToConstant: 36),

            playPauseButton.bottomAnchor.constraint(equalTo: controlsView.bottomAnchor, constant: -20),
            playPauseButton.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 16),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),

            timeLabel.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            timeLabel.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 12),
            timeLabel.widthAnchor.constraint(equalToConstant: 50),

            durationLabel.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            durationLabel.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor, constant: -16),
            durationLabel.widthAnchor.constraint(equalToConstant: 50),

            progressSlider.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            progressSlider.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            progressSlider.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -12),
        ])
    }

    // MARK: - Actions

    @objc private func togglePlayback() {
        if player.isPlaying {
            player.pause()
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        } else {
            player.play()
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        }
        // Reveal the bar so keyboard-triggered toggles give visual feedback.
        showControls()
    }

    @objc private func scrub() {
        // VLCMediaPlayer.position is normalized 0...1 (Double in VLCKit 4).
        player.position = Double(progressSlider.value)
        noteUserMovedPlayhead()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: - Track pickers

    /// One row of the subtitle picker.
    private enum SubtitleChoice {
        case embedded(trackId: String)
        case external(Subtitle)
    }

    // VLCKit 4 exposes tracks as `VLCMediaPlayer.Track` objects rather than
    // paired index/name NSArrays. The picker keeps its (index, name)
    // contract; "index" is the row position, mapped back to a track id /
    // OpenSubtitles entry by `subtitleChoices()`.
    private func embeddedTextTracks() -> [VLCMediaPlayer.Track] {
        return player.textTracks.filter { !slaveTrackIdSet.contains($0.trackId) }
    }

    private func subtitleChoices() -> [(name: String, choice: SubtitleChoice)] {
        var rows: [(name: String, choice: SubtitleChoice)] = embeddedTextTracks().map {
            ($0.trackName, .embedded(trackId: $0.trackId))
        }
        rows += externalSubtitles.map { ("\(ExternalSubtitleLoader.menuTitle(for: $0)) (OpenSubtitles)", .external($0)) }
        return rows
    }

    private func audioTracks() -> [(index: Int32, name: String)] {
        return player.audioTracks.enumerated().map { (Int32($0.offset), $0.element.trackName) }
    }

    /// Row of the current subtitle: the OpenSubtitles entry the user wants
    /// (even while it downloads / attaches — every selection path keeps
    /// `selectedExternalLink` up to date), else the selected VLC text track.
    private func selectedSubtitleRow(in rows: [(name: String, choice: SubtitleChoice)]) -> Int32 {
        func externalRow(_ link: String) -> Int32? {
            let row = rows.firstIndex { if case .external(let s) = $0.choice { return s.link == link } else { return false } }
            return row.map(Int32.init)
        }
        if let link = selectedExternalLink, let row = externalRow(link) { return row }
        guard let selected = player.textTracks.first(where: { $0.isSelected }) else { return -1 }
        if let link = slaveTrackIds.first(where: { $0.value == selected.trackId })?.key, let row = externalRow(link) {
            return row
        }
        let row = rows.firstIndex { if case .embedded(let id) = $0.choice { return id == selected.trackId } else { return false } }
        return row.map(Int32.init) ?? -1
    }

    @objc private func showSubtitlePicker() {
        let rows = subtitleChoices()
        presentTrackSheet(
            title: "Sous-titres",
            tracks: rows.enumerated().map { (Int32($0.offset), $0.element.name) },
            selectedIndex: selectedSubtitleRow(in: rows),
            allowDisable: true,
            sourceView: subtitleButton
        ) { [weak self] index in
            guard let self = self else { return }
            self.userChoseSubtitle = true
            if index < 0 || Int(index) >= rows.count {
                self.turnSubtitlesOff()
            } else {
                switch rows[Int(index)].choice {
                case .embedded(let trackId):
                    self.selectEmbeddedTextTrack(id: trackId)
                case .external(let subtitle):
                    self.selectExternalSubtitle(subtitle)
                }
            }
            self.scheduleHideControls()
        }
    }

    @objc private func showAudioPicker() {
        presentTrackSheet(
            title: "Audio",
            tracks: audioTracks(),
            selectedIndex: Int32(player.audioTracks.firstIndex(where: { $0.isSelected }) ?? -1),
            allowDisable: false,
            sourceView: audioButton
        ) { [weak self] index in
            guard let self = self, index >= 0, Int(index) < self.player.audioTracks.count else { return }
            self.didAutoSelectAudio = true // the user's choice wins from now on
            self.player.audioTracks[Int(index)].isSelectedExclusively = true
            self.scheduleHideControls()
        }
    }

    /// Wrap `TrackPickerSheet` in a `UIHostingController` and present as a
    /// form sheet. We pin the popover anchor for iPad regular-size class /
    /// Mac so the OS doesn't fall back to a modal that might miss the target.
    private func presentTrackSheet(title: String,
                                   tracks: [(index: Int32, name: String)],
                                   selectedIndex: Int32,
                                   allowDisable: Bool,
                                   sourceView: UIView,
                                   onSelect: @escaping (Int32) -> Void) {
        let view = TrackPickerSheet(title: title,
                                    tracks: tracks,
                                    selectedIndex: selectedIndex,
                                    allowDisable: allowDisable,
                                    onSelect: onSelect)
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .formSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        host.popoverPresentationController?.sourceView = sourceView
        host.popoverPresentationController?.sourceRect = sourceView.bounds
        present(host, animated: true)
        hideControlsTask?.cancel()
    }

    /// The subtitle button stays visible even with 0 tracks — OpenSubtitles
    /// entries can still arrive, and "Aucun" confirms there's nothing on. The
    /// audio button only when there's actually a choice to make (>1 track).
    /// Called whenever the state transitions to `.playing`.
    private func refreshTrackButtonsVisibility() {
        subtitleButton.isHidden = false
        audioButton.isHidden    = audioTracks().count <= 1
    }

    // MARK: - Subtitles (embedded tracks + OpenSubtitles slaves)

    private func loadExternalSubtitlesIfNeeded() {
        if externalSubtitles.isEmpty, let media = media {
            if !media.subtitles.isEmpty {
                externalSubtitles = media.subtitles
                return
            }
            isSearchingSubtitles = true
            ExternalSubtitleLoader.search(for: media) { [weak self] subtitles in
                guard let self = self else { return }
                self.isSearchingSubtitles = false
                if self.externalSubtitles.isEmpty { self.externalSubtitles = subtitles }
                self.autoSelectSubtitleIfNeeded()
            }
        }
    }

    private func turnSubtitlesOff() {
        selectedExternalLink = nil
        selectedEmbeddedTrackId = nil
        pendingSubtitleLink = nil
        player.deselectAllTextTracks()
    }

    private func selectEmbeddedTextTrack(id: String) {
        selectedExternalLink = nil
        selectedEmbeddedTrackId = id
        pendingSubtitleLink = nil
        player.textTracks.first(where: { $0.trackId == id })?.isSelectedExclusively = true
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

    /// Select an OpenSubtitles entry: re-select its track if it's already
    /// attached, else download it now, and convert + attach it once playing.
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
            guard let self = self, !self.isClosing else { return }
            guard let url = url else {
                print("[Player] subtitles: download failed for '\(subtitle.language)'")
                if self.selectedExternalLink == subtitle.link { self.selectedExternalLink = nil }
                if self.pendingSubtitleLink == subtitle.link { self.pendingSubtitleLink = nil }
                return
            }
            self.downloadedSubtitleFiles[subtitle.link] = (subtitle, url)
            // Attached if it is still the wanted one (the user may have
            // picked something else meanwhile).
            self.applyPendingSubtitle()
        }
    }

    /// The playing video's frame rate (selected video track), nil while VLC
    /// doesn't know it.
    private func currentVideoFrameRate() -> Double? {
        guard let video = (player.videoTracks.first(where: { $0.isSelected }) ?? player.videoTracks.first)?.video else { return nil }
        return ExternalSubtitleLoader.videoFrameRate(numerator: video.frameRate, denominator: video.frameRateDenominator)
    }

    /// Converts the downloaded OpenSubtitles file of `link` to UTF-8 SRT,
    /// frame-based files timed with the video's frame rate (the input is
    /// ready, so VLC knows it), then attaches whatever is pending.
    private func convertDownloadedSubtitle(link: String) {
        guard convertingSubtitleLink == nil, let download = downloadedSubtitleFiles[link] else { return }
        convertingSubtitleLink = link
        let frameRate = currentVideoFrameRate()
        print("[Player] subtitles: converting '\(download.subtitle.language)' for VLC (video \(frameRate.map { String(format: "%.3f fps", $0) } ?? "frame rate unknown"))")
        ExternalSubtitleLoader.convertForVLC(fileAt: download.url, subtitle: download.subtitle, frameRate: frameRate) { [weak self] file in
            guard let self = self, !self.isClosing else { return }
            self.convertingSubtitleLink = nil
            self.preparedSubtitleFiles[link] = file
            self.applyPendingSubtitle()
        }
    }

    /// True once VLC really plays the input with its tracks registered.
    /// VLCKit 4 reports `isPlaying` from `play()` on — through the whole
    /// `.opening` phase, which can last seconds on a torrent stream — while
    /// the demuxer hasn't registered a single track yet. Deciding then would
    /// pick OpenSubtitles over the file's own subtitle track, give up on the
    /// preferred language for good, or snapshot an empty track list before
    /// attaching a slave (every embedded track then looks like the slave's
    /// and vanishes from the picker). So: wait for the `.playing` state with
    /// an audio or video track listed (the file's own text tracks are
    /// registered by then), latch it, and from then on only require the
    /// input to run.
    private var isInputReady: Bool {
        guard !isClosing else { return false }
        let state = player.state
        if !didReachPlayingWithTracks {
            guard state == .playing, !player.audioTracks.isEmpty || !player.videoTracks.isEmpty else { return false }
            didReachPlayingWithTracks = true
        }
        return state == .playing || state == .paused
    }

    /// Attaches the pending subtitle as an enforced playback slave, but only
    /// once the input is ready (`isInputReady`) — VLCKit drops a slave added
    /// before the input runs, and the track ids snapshotted here must already
    /// include every track of the file. A downloaded file is converted first
    /// (with the video's frame rate, known now). Called from the download and
    /// conversion callbacks, from `.playing` and from the time tick, so
    /// whichever happens last wins.
    private func applyPendingSubtitle() {
        guard let link = pendingSubtitleLink, textTrackIdsBeforeSlave == nil, isInputReady else { return }
        guard let file = preparedSubtitleFiles[link] else {
            convertDownloadedSubtitle(link: link)   // no-op while still downloading
            return
        }
        let priorIds = Set(player.textTracks.map { $0.trackId })
        let result = player.addPlaybackSlave(file, type: .subtitle, enforce: true)
        guard result == 0 else {
            print("[Player] subtitles: addPlaybackSlave refused (\(result)), will retry")
            return // stays pending; retried on the next tick / .playing
        }
        pendingSubtitleLink = nil
        textTrackIdsBeforeSlave = priorIds
        slaveLinkAwaitingTrack = link
        slaveRequestDate = Date()
    }

    /// Select the slave's text track once VLC registers it. Recognised by its
    /// track id (`ExternalSubtitleLoader.slaveTrackIds`), never "the last new
    /// track": the file's own subtitle tracks — even one registering late —
    /// are never picked (or hidden) by mistake.
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
                print("[Player] subtitles: VLC never registered the OpenSubtitles track — giving up")
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
            print("[Player] subtitles ON: selected text track '\(slaveTrack.trackName)' (\(slaveTrack.trackId), \(player.textTracks.count) total)")
        } else {
            applyCurrentSubtitleChoice() // the user moved on while it loaded
        }
    }

    /// Preferred subtitle language (Settings): the file's own matching text
    /// track first (never a forced-only one), else the OpenSubtitles entry.
    /// Runs only once the input is ready (`isInputReady`), so the file's
    /// tracks are known; waits for a running OpenSubtitles search.
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
            print("[Player] auto-selecting subtitle track '\(track.trackName)' for '\(code)'")
            return
        }
        if let subtitle = ExternalSubtitleLoader.preferredSubtitle(in: externalSubtitles, code: code) {
            didAutoSelectSubtitle = true
            print("[Player] auto-selecting OpenSubtitles '\(subtitle.language)' for '\(code)'")
            selectExternalSubtitle(subtitle)
            return
        }
        // Nothing matches among the (known) tracks: give up unless the
        // OpenSubtitles search is still running — its completion calls back.
        if !isSearchingSubtitles { didAutoSelectSubtitle = true }
    }

    /// If the file carries an audio track matching the user's preferred
    /// audio language (Settings), switch to it. Track naming is free-form
    /// ("Track 1", "French", "[fre]", "VFF - Français"…), so the track's
    /// language code is checked first, then its name; commentary and
    /// audio-description tracks are avoided.
    private func autoSelectAudioTrackIfNeeded() {
        guard !didAutoSelectAudio, isInputReady else { return }
        let tracks = player.audioTracks
        guard !tracks.isEmpty else { return } // not known yet
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
        // Keep VLC's pick (the file's default track) when it already fits.
        if let current = tracks.first(where: { $0.isSelected }),
           matching.contains(where: { $0.trackId == current.trackId }), !isSecondary(current) { return }
        let best = matching.first(where: { !isSecondary($0) }) ?? matching[0]
        print("[Player] auto-selecting audio track '\(best.trackName)' for '\(code)'")
        best.isSelectedExclusively = true
    }

    /// Seek to `startPosition` (where the failed native player stopped, or
    /// the saved progress) once the stream is seekable.
    private func applyStartPositionIfNeeded() {
        guard !didApplyStartPosition, VLCWatchProgress.seeksAtStart(startPosition), player.isSeekable else { return }
        didApplyStartPosition = true
        player.position = Double(startPosition)
    }

    // MARK: - Watched progress

    /// The saved progress (0…1) of a movie / episode, 0 when none.
    private static func savedProgress(for media: Media?) -> Float {
        if let movie = media as? Movie { return WatchedlistManager<Movie>.movie.currentProgress(movie.id) }
        if let episode = media as? Episode { return WatchedlistManager<Episode>.episode.currentProgress(episode.id) }
        return 0
    }

    /// Samples VLC's position (time tick, pause, background, close) while
    /// its input plays or is paused.
    private func notePlayerPosition() {
        guard !isClosing, player.state == .playing || player.state == .paused else { return }
        watchProgress.note(position: player.position)
    }

    /// Slider / ±10 s: the position VLC reports from now on is the user's,
    /// even before the resume point. (A non-seekable input ignores them.)
    private func noteUserMovedPlayhead() {
        guard player.isSeekable else { return }
        watchProgress.userMovedPlayhead()
    }

    /// Pause / background: saves the position reached so far, so a kill or
    /// a crash afterwards doesn't lose it.
    private func checkpointProgress() {
        guard !isClosing else { return }
        notePlayerPosition()
        saveProgress(status: .paused)
    }

    @objc private func applicationDidEnterBackground() {
        checkpointProgress()
    }

    /// Watched progress (local + Trakt scrobble), same rules as the native
    /// players (`RemuxAVPlayerViewController.saveProgress`): the protected
    /// saved point is never replaced by a smaller fraction unless VLC played
    /// past it (`VLCWatchProgress.progressToSave`). Nothing is saved when
    /// VLC never played a session that starts at 0:00.
    private func saveProgress(status: Trakt.WatchedStatus) {
        guard let media = media else { return }
        guard let value = watchProgress.progressToSave() else {
            if let current = watchProgress.current {
                print("[Player] progress \(Int(current * 100)) % not saved — keeps the resume point at \(Int(watchProgress.resumePoint * 100)) %")
            }
            return
        }
        if let movie = media as? Movie {
            WatchedlistManager<Movie>.movie.setCurrentProgress(value, for: movie.id, with: status)
        } else if let episode = media as? Episode {
            WatchedlistManager<Episode>.episode.setCurrentProgress(value, for: episode.id, with: status)
        }
    }

    // MARK: - Controls visibility

    @objc private func toggleControls() {
        let target: CGFloat = controlsView.alpha > 0 ? 0 : 1
        UIView.animate(withDuration: 0.2) { self.controlsView.alpha = target }
        if target == 1 { scheduleHideControls() }
    }

    private func showControls() {
        UIView.animate(withDuration: 0.2) { self.controlsView.alpha = 1 }
        scheduleHideControls()
    }

    @objc private func hoverDidChange(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        if controlsView.alpha == 0 { showControls() }
    }

    /// Keep taps on the control bar from also toggling (and instantly
    /// hiding) the very controls being used.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return !(touch.view?.isDescendant(of: controlsView) ?? false)
    }

    // MARK: - Nerd stats

    @objc private func toggleNerdStats() {
        if let container = nerdStatsContainer {
            nerdStatsTimer?.invalidate()
            nerdStatsTimer = nil
            container.removeFromSuperview()
            nerdStatsContainer = nil
            nerdStatsLabel = nil
            return
        }

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 0

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        container.layer.cornerRadius = 10
        container.layer.masksToBounds = true
        container.addSubview(label)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(lessThanOrEqualTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])

        nerdStatsContainer = container
        nerdStatsLabel = label
        label.text = nerdStatsText()
        nerdStatsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self, self.nerdStatsLabel != nil else { timer.invalidate(); return }
            self.nerdStatsLabel?.text = self.nerdStatsText()
        }
    }

    /// libvlc packs fourccs low-byte-first (VLC_FOURCC('h','e','v','c')).
    private func fourCCString(_ cc: UInt32) -> String {
        let bytes: [UInt8] = [UInt8(cc & 0xff), UInt8((cc >> 8) & 0xff), UInt8((cc >> 16) & 0xff), UInt8((cc >> 24) & 0xff)]
        let printable = bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "?" }
        return String(printable).trimmingCharacters(in: .whitespaces)
    }

    private func nerdStatsText() -> String {
        var lines: [String] = []

        let videoTrack = player.videoTracks.first(where: { $0.isSelected }) ?? player.videoTracks.first
        if let track = videoTrack, let video = track.video {
            let fps: Double = video.frameRateDenominator > 0
                ? Double(video.frameRate) / Double(video.frameRateDenominator)
                : Double(video.frameRate)
            lines.append(String(format: "Video   %@  %u×%u  %.3f fps", fourCCString(track.codec), video.width, video.height, fps))
        }

        let audioTrack = player.audioTracks.first(where: { $0.isSelected }) ?? player.audioTracks.first
        if let track = audioTrack, let audio = track.audio {
            lines.append(String(format: "Audio   %@  %u ch  %u Hz", fourCCString(track.codec), audio.channelsNumber, audio.rate))
            lines.append("Track   \(track.trackName)")
        }

        // Reports whether the encoded (passthrough) device engaged — same
        // semantics as the tvOS overlay.
        let passthrough = player.audio?.passthrough ?? false
        lines.append("Output  " + (passthrough ? "Bitstream (Dolby passthrough)" : "PCM (decoded)"))

        let textTrack = player.textTracks.first(where: { $0.isSelected })
        lines.append("Subs    " + (textTrack?.trackName ?? "none"))

        if let stats = player.media?.statistics {
            lines.append(String(format: "Input   %.1f Mb/s  ·  demux %.1f Mb/s", Double(stats.inputBitrate) * 8000 / 1_000_000, Double(stats.demuxBitrate) * 8000 / 1_000_000))
            lines.append("Frames  \(stats.displayedPictures) shown · \(stats.latePictures) late · \(stats.lostPictures) lost")
        }

        if let status = streamer?.torrentStatus {
            lines.append("Buffer  \(Int(status.totalProgress * 100))% downloaded")
        }

        return lines.joined(separator: "\n")
    }

    @objc private func scheduleHideControls() {
        hideControlsTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.25) { self?.controlsView.alpha = 0 }
        }
        hideControlsTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // Track-dependent work runs from the tick too: tracks and slaves
        // register a moment after playback starts.
        applyStartPositionIfNeeded()
        notePlayerPosition()
        autoSelectAudioTrackIfNeeded()
        autoSelectSubtitleIfNeeded()
        applyPendingSubtitle()
        selectSlaveTextTrackIfNeeded()

        guard !progressSlider.isTracking else { return }
        progressSlider.setValue(Float(player.position), animated: false)
        if let elapsed = player.time.value?.intValue {
            timeLabel.text = formatMs(elapsed)
        }
        let totalMs: Int? = {
            if let dur = player.media?.length.value?.intValue { return dur }
            if let remaining = player.remainingTime?.value?.intValue,
               let elapsed   = player.time.value?.intValue {
                return abs(remaining) + elapsed
            }
            return nil
        }()
        if let totalMs { durationLabel.text = formatMs(totalMs) }
    }

    /// VLCKit 4 (4.0.0a21) passes the new STATE here — not a Notification as
    /// VLCKit 3 did. The old `(_ aNotification: Notification)` signature only
    /// "nearly matched" the optional requirement, was never exposed to
    /// Objective-C and therefore never called: passthrough re-assertion,
    /// track-button refresh and close-on-end silently never ran.
    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        switch newState {
        case .playing:
            // libvlc fills in the track list right after the file starts
            // playing. We refresh now (and on each subsequent transition)
            // so multi-language MKVs surface their tracks as soon as they
            // become available.
            refreshTrackButtonsVisibility()
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
            // The file's tracks are known now: preferred audio / subtitles
            // (the file's own subtitle track wins over OpenSubtitles), then
            // the slave the user picked while the input was opening.
            autoSelectAudioTrackIfNeeded()
            autoSelectSubtitleIfNeeded()
            applyPendingSubtitle()
            // Request the encoded (passthrough) device once the aout exists;
            // the nerd-stats Output line reports whether it engaged.
            if !didEnablePassthrough {
                didEnablePassthrough = true
                if UserDefaults.standard.object(forKey: "audioPassthrough") as? Bool ?? true {
                    player.audio?.passthrough = true
                    print("[Player] passthrough engaged (t0): \(player.audio?.passthrough ?? false)")
                    // The aout can be rebuilt when the audio ES starts; retry
                    // once a few seconds in and log whether it finally stuck.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self = self else { return }
                        self.player.audio?.passthrough = true
                        print("[Player] passthrough engaged (t3): \(self.player.audio?.passthrough ?? false)")
                    }
                }
            }
        case .paused:
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
            checkpointProgress()
        case .error, .stopped: // VLCKit 4 dropped `.ended`; end-of-file surfaces as `.stopped`
            // Our own stop() in viewWillDisappear also lands here — ignore it.
            guard !isClosing else { return }
            if newState == .error { print("[Player] VLC reported an error — closing the player") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, !self.isClosing else { return }
                self.dismiss(animated: true)
            }
        default: break
        }
    }

    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
