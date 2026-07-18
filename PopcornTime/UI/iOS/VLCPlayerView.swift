

import SwiftUI
import UIKit
import VLCKit
import PopcornTorrent

/// SwiftUI wrapper around a `VLCMediaPlayer` so the iOS app can play formats
/// AVPlayer can't open (.mkv, .avi, exotic codecs). Used as fallback when the
/// codec sniffer in `MediaDetailView` decides AVPlayer wouldn't be a fit.
struct VLCPlayerView: UIViewControllerRepresentable {
    let url: URL
    let title: String
    let streamer: PTTorrentStreamer?

    func makeUIViewController(context: Context) -> VLCPlayerViewController {
        let vc = VLCPlayerViewController()
        vc.url      = url
        vc.title    = title
        vc.streamer = streamer
        return vc
    }

    func updateUIViewController(_ vc: VLCPlayerViewController, context: Context) {}
}

/// Bare-bones VLC player VC: a movie surface, a tap-to-toggle controls
/// overlay (play/pause, scrubbing, time labels, close), and the same
/// max-quality VLCMedia options the tvOS player uses (5s caches,
/// drop-late-frames=0). Subtitle/audio track pickers are intentionally
/// minimal here; the SwiftUI surface treats the VLC path as a fallback for
/// MKV/AVI rather than a full feature parity rewrite.
final class VLCPlayerViewController: UIViewController, VLCMediaPlayerDelegate, UIGestureRecognizerDelegate {
    var url: URL!
    var streamer: PTTorrentStreamer?

    private let player = VLCMediaPlayer()
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        movieView.translatesAutoresizingMaskIntoConstraints = false
        movieView.backgroundColor = .black
        view.addSubview(movieView)

        configureControlsLayout()

        player.delegate = self
        player.drawable = movieView
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
        showControls()
    }

    @objc private func seekForward() {
        player.jumpForward(10)
        showControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player.stop()
        streamer?.cancelStreamingAndDeleteData(false)
        streamer = nil
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

        // Subtitle picker (CC icon) — shown only if the media reports tracks.
        subtitleButton.translatesAutoresizingMaskIntoConstraints = false
        subtitleButton.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        subtitleButton.tintColor = .white
        subtitleButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .regular), forImageIn: .normal)
        subtitleButton.addTarget(self, action: #selector(showSubtitlePicker), for: .touchUpInside)
        controlsView.addSubview(subtitleButton)

        // Audio track picker (speaker icon) — for multi-language releases.
        audioButton.translatesAutoresizingMaskIntoConstraints = false
        audioButton.setImage(UIImage(systemName: "speaker.wave.2"), for: .normal)
        audioButton.tintColor = .white
        audioButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .regular), forImageIn: .normal)
        audioButton.addTarget(self, action: #selector(showAudioPicker), for: .touchUpInside)
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
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: - Track pickers

    /// Pull (index, name) pairs out of `VLCMediaPlayer.videoSubTitlesIndexes/Names`
    /// (paired NSArrays). Filters out the magic "-1 / Disable" sentinel that VLC
    /// always reports — we add our own "Aucun" entry instead.
    // VLCKit 4 exposes tracks as `VLCMediaPlayerTrack` objects rather than
    // paired index/name NSArrays. We keep the picker's (index, name) contract
    // but treat "index" as the *position* in the track array; selection then
    // goes through `selectedExclusively` / `deselectAllTextTracks`.
    private func subtitleTracks() -> [(index: Int32, name: String)] {
        return player.textTracks.enumerated().map { (Int32($0.offset), $0.element.trackName) }
    }

    private func audioTracks() -> [(index: Int32, name: String)] {
        return player.audioTracks.enumerated().map { (Int32($0.offset), $0.element.trackName) }
    }

    @objc private func showSubtitlePicker() {
        presentTrackSheet(
            title: "Sous-titres",
            tracks: subtitleTracks(),
            selectedIndex: Int32(player.textTracks.firstIndex(where: { $0.isSelected }) ?? -1),
            allowDisable: true,
            sourceView: subtitleButton
        ) { [weak self] index in
            guard let self = self else { return }
            if index < 0 {
                self.player.deselectAllTextTracks()
            } else if Int(index) < self.player.textTracks.count {
                self.player.textTracks[Int(index)].isSelectedExclusively = true
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

    /// Hide the subtitle/audio buttons when VLC reports no tracks at all
    /// (raw audio file, or before media probing finishes). Called from
    /// `mediaPlayerStateChanged` whenever the state transitions to `.playing`.
    private func refreshTrackButtonsVisibility() {
        let hasSub   = !subtitleTracks().isEmpty
        let hasAudio = audioTracks().count > 1
        // Subtitle button stays visible even with 0 tracks — user might want
        // to confirm "no subtitles" via the sheet. Audio button only when
        // there's actually a choice to make (>1 track).
        subtitleButton.isHidden = false
        audioButton.isHidden    = !hasAudio
        _ = hasSub
    }

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

        // On iOS/macOS the player never attempts bitstream passthrough (that's
        // a tvOS/AVR concern), so this reads "PCM (decoded)" — shown anyway so
        // the overlay matches tvOS and doesn't leave the question open.
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

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch player.state {
        case .playing:
            // libvlc fills in the track list right after the file starts
            // playing. We refresh now (and on each subsequent transition)
            // so multi-language MKVs surface their tracks as soon as they
            // become available.
            refreshTrackButtonsVisibility()
        case .error, .stopped: // VLCKit 4 dropped `.ended`; end-of-file surfaces as `.stopped`
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.dismiss(animated: true)
            }
        default: break
        }
    }

    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
