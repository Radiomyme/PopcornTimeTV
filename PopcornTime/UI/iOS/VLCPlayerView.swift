

import SwiftUI
import UIKit
import MobileVLCKit
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
final class VLCPlayerViewController: UIViewController, VLCMediaPlayerDelegate {
    var url: URL!
    var streamer: PTTorrentStreamer?

    private let player = VLCMediaPlayer()
    private let movieView = UIView()
    private let controlsView = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let progressSlider = UISlider()
    private let timeLabel = UILabel()
    private let durationLabel = UILabel()
    private let titleLabel = UILabel()
    private var hideControlsTask: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        movieView.translatesAutoresizingMaskIntoConstraints = false
        movieView.backgroundColor = .black
        view.addSubview(movieView)

        configureControlsLayout()

        player.delegate = self
        player.drawable = movieView
        let media = VLCMedia(url: url)
        media.addOptions([
            "network-caching":  NSNumber(value: 5000),
            "file-caching":     NSNumber(value: 5000),
            "live-caching":     NSNumber(value: 5000),
            "drop-late-frames": NSNumber(value: 0),
            "skip-frames":      NSNumber(value: 0),
        ])
        player.media = media

        // Tap on the movie surface toggles controls.
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        movieView.addGestureRecognizer(tap)
        movieView.isUserInteractionEnabled = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        player.play()
        scheduleHideControls()
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
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: audioButton.leadingAnchor, constant: -8),

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
        scheduleHideControls()
    }

    @objc private func scrub() {
        // VLCMediaPlayer.position is normalized 0...1.
        player.position = progressSlider.value
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: - Track pickers

    /// Pull (index, name) pairs out of `VLCMediaPlayer.videoSubTitlesIndexes/Names`
    /// (paired NSArrays). Filters out the magic "-1 / Disable" sentinel that VLC
    /// always reports — we add our own "Aucun" entry instead.
    private func subtitleTracks() -> [(index: Int32, name: String)] {
        guard let idx = player.videoSubTitlesIndexes as? [NSNumber],
              let names = player.videoSubTitlesNames as? [String],
              idx.count == names.count else { return [] }
        return zip(idx, names).compactMap { (n, name) -> (Int32, String)? in
            let value = n.int32Value
            // VLC uses -1 to mean "subtitles disabled". We expose that via a
            // separate cancel-style action so the list only contains real tracks.
            return value < 0 ? nil : (value, name)
        }
    }

    private func audioTracks() -> [(index: Int32, name: String)] {
        guard let idx = player.audioTrackIndexes as? [NSNumber],
              let names = player.audioTrackNames as? [String],
              idx.count == names.count else { return [] }
        return zip(idx, names).compactMap { (n, name) -> (Int32, String)? in
            let value = n.int32Value
            return value < 0 ? nil : (value, name)
        }
    }

    @objc private func showSubtitlePicker() {
        presentTrackSheet(
            title: "Sous-titres",
            tracks: subtitleTracks(),
            selectedIndex: player.currentVideoSubTitleIndex,
            allowDisable: true,
            sourceView: subtitleButton
        ) { [weak self] index in
            self?.player.currentVideoSubTitleIndex = index
            self?.scheduleHideControls()
        }
    }

    @objc private func showAudioPicker() {
        presentTrackSheet(
            title: "Audio",
            tracks: audioTracks(),
            selectedIndex: player.currentAudioTrackIndex,
            allowDisable: false,
            sourceView: audioButton
        ) { [weak self] index in
            self?.player.currentAudioTrackIndex = index
            self?.scheduleHideControls()
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
        progressSlider.setValue(player.position, animated: false)
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
        case .error, .stopped, .ended:
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
