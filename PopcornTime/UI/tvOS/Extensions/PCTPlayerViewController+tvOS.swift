

import Foundation

extension PCTPlayerViewController: UIViewControllerTransitioningDelegate {
    
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return presented is OptionsViewController ? OptionsAnimatedTransitioning(isPresenting: true) : nil
        
    }
    
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return dismissed is OptionsViewController ? OptionsAnimatedTransitioning(isPresenting: false) : nil
    }
    
    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        return presented is OptionsViewController ? OptionsPresentationController(presentedViewController: presented, presenting: presenting) : nil
    }
    
    @IBAction func handlePositionSliderGesture(_ sender: UIPanGestureRecognizer) {
        
        let translation = sender.translation(in: view)
        
        guard !(presentedViewController is OptionsViewController) && progressBar.isScrubbing && !progressBar.isHidden else { return }
        
        let offset = progressBar.scrubbingProgress + Float((translation.x - lastTranslation)/progressBar.bounds.width/8.0)
        
        switch sender.state {
        case .cancelled:
            fallthrough
        case .ended:
            lastTranslation = 0.0
        case .began:
            fallthrough
        case .changed:
            progressBar.scrubbingProgress = offset
            positionSliderDidDrag()
            lastTranslation = translation.x
        default:
            return
        }
    }
    
    @IBAction func presentOptionsViewController() {
        // Never stack over the loading spinner, the continue-watching alert, or
        // an already-open panel. A stray down-click while one of those is up
        // would otherwise try to present here and crash on the not-yet-wired
        // child view controllers.
        guard presentedViewController == nil else { return }
        guard let destinationController = storyboard?.instantiateViewController(withIdentifier: "OptionsViewController") as? OptionsViewController else { return }

        // Force the view (and its embed segues) to load NOW so the
        // subtitles/audio/info child view controllers exist before we configure
        // them. Previously we presented first and configured after, relying on
        // `present(animated:)` having synchronously loaded the view — which is
        // not guaranteed, so `subtitlesViewController` could still be nil.
        destinationController.loadViewIfNeeded()

        destinationController.transitioningDelegate = self
        destinationController.modalPresentationStyle = .custom
        destinationController.delegate = self

        destinationController.subtitlesViewController.subtitles = subtitles
        destinationController.subtitlesViewController.currentSubtitle = currentSubtitle
        destinationController.subtitlesViewController.currentDelay = mediaplayer.currentVideoSubTitleDelay/Int(1e6)
        destinationController.audioViewController.currentDelay = mediaplayer.currentAudioPlaybackDelay/Int(1e6)
        // VLCKit 4 track API: feed the picker each track's name and its
        // *position* as the "index" (didSelectAudioTrack selects by position),
        // and mark the currently-selected track.
        let audioTracks = mediaplayer.audioTracks
        destinationController.audioViewController.audioTrackNames = audioTracks.map { $0.trackName }
        destinationController.audioViewController.audioTrackIndexes = audioTracks.indices.map { Int32($0) }
        destinationController.audioViewController.currentAudioTrackIndex = Int32(audioTracks.firstIndex(where: { $0.isSelected }) ?? -1)
        destinationController.infoViewController.media = media

        present(destinationController, animated: true)
    }
    
    @objc func touchLocationDidChange(_ gesture: SiriRemoteGestureRecognizer) {
        if gesture.state == .ended { hideInfoLabel() } else if gesture.isLongTap { showInfoLabel() }
        
        progressBar.hint = .none
        resetIdleTimer()
        
        guard !progressBar.isScrubbing && mediaplayer.isPlaying && !progressBar.isHidden && !progressBar.isBuffering else { return }
        
        switch gesture.touchLocation {
        case .left:
            if gesture.isClick && gesture.state == .ended { rewind(); progressBar.hint = .none }
            if gesture.isLongPress { rewindHeld(gesture) } else if gesture.state != .ended { progressBar.hint = .jumpBackward30 }
        case .right:
            if gesture.isClick && gesture.state == .ended { fastForward(); progressBar.hint = .none }
            if gesture.isLongPress { fastForwardHeld(gesture) } else if gesture.state != .ended { progressBar.hint = .jumpForward30 }
        default: return
        }
    }
    
    @objc func clickGesture(_ gesture: SiriRemoteGestureRecognizer) {
        guard gesture.touchLocation == .unknown && gesture.isClick && gesture.state == .ended else {
            progressBar.isHidden ? toggleControlsVisible() : ()
            return
        }
        
        guard !progressBar.isScrubbing else {
            endScrubbing()
            if mediaplayer.isSeekable {
                let time = NSNumber(value: progressBar.scrubbingProgress * streamDuration)
                mediaplayer.time = VLCTime(number: time)
                // Force a progress change rather than waiting for VLCKit's delegate call to.
                progressBar.progress = progressBar.scrubbingProgress
                progressBar.elapsedTimeLabel.text = progressBar.scrubbingTimeLabel.text
            }
            return
        }
        
        mediaplayer.canPause ? mediaplayer.pause() : ()
        progressBar.isHidden ? toggleControlsVisible() : ()
        dimmerView!.isHidden = false
        progressBar.isScrubbing = true
        
        let currentTime = NSNumber(value: progressBar.progress * streamDuration)
        if let image = screenshotAtTime(currentTime) {
            progressBar.screenshot = image
        }
    }
    
    @IBAction func menuPressed() {
        progressBar.isScrubbing ? endScrubbing() : didFinishPlaying()
    }

    /// Handle the dedicated Play/Pause button on the Siri Remote (or any
    /// gamepad). The touchpad-click action (`clickGesture`) intentionally
    /// enters scrubbing mode — that's the standard Apple TV video-app
    /// pattern and should stay. The Play/Pause button instead toggles
    /// playback directly without entering scrub.
    ///
    /// `presses` is the modern UIKit press-handling API. We must call
    /// `super` for unhandled press types so the menu / select buttons
    /// still reach `clickGesture` / `menuPressed`.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if press.type == .playPause {
                playandPause()
            } else if press.type == .downArrow {
                // Deterministic way to reach Subtitles / Audio / Info. The
                // storyboard swipe-down gesture is unreliable on the 2nd-gen
                // Siri Remote clickpad, which left users unable to open the
                // options panel at all. A firm click on the bottom of the
                // clickpad always emits `.downArrow`, so bind it directly.
                presentOptionsViewController()
            } else if press.type == .upArrow {
                // Up-click mirrors the down-click: playback nerd stats
                // (codec / resolution / fps / audio format / output mode).
                toggleNerdStats()
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    func endScrubbing() {
        if !mediaplayer.isPlaying { mediaplayer.play() } // VLCKit 4 dropped `willPlay`
        resetIdleTimer()
        progressBar.isScrubbing = false
        dimmerView!.isHidden = true
    }
    
    func hideInfoLabel() {
        guard infoHelperView!.alpha == 1 else { return }
        UIView.animate(withDuration: 0.3) {
            self.infoHelperView!.alpha = 0.0
        }
    }
    
    func showInfoLabel() {
        guard infoHelperView!.alpha == 0 else { return }
        UIView.animate(withDuration: 0.3) {
            self.infoHelperView!.alpha = 1.0
        }
    }
    
    @objc func alertFocusDidChange(_ notification: Notification) {
        guard let alertController = notification.object as? UIAlertController,
            let UIAlertControllerActionView = NSClassFromString("_UIAlertControllerActionView"),
            let dimmerView = alertController.value(forKey: "_dimmingView") as? UIView else { return }
        
        dimmerView.isHidden = true
        progressBar.isBuffering = false
        
        let subviews = alertController.view.recursiveSubviews.filter({type(of: $0) == UIAlertControllerActionView})
        
        for view in subviews {
            guard let title = view.value(forKeyPath: "label.text") as? String,
                let isHighlighted = view.value(forKey: "isHighlighted") as? Bool,
                isHighlighted else { continue }
            
            if title == "Resume Playing".localized {
                progressBar.progress = startPosition
            } else if title == "Start from Beginning".localized {
                progressBar.progress = 0
            }
            
            positionSliderDidDrag()
            
            workItem?.cancel() // Cancel item so screenshot is not loaded
            progressBar.elapsedTimeLabel.text = progressBar.scrubbingTimeLabel.text
            
            progressBar.setNeedsLayout()
            progressBar.layoutIfNeeded()
        }
    }
    
    func didSelectEqualizerProfile(_ profile: EqualizerProfiles) {
        // VLCKit 4: equalizer is an object set on the player, built from a
        // preset in the shared presets list (indexed the same as the old
        // EqualizerProfiles raw values).
        let presets = VLCAudioEqualizer.presets
        guard Int(profile.rawValue) < presets.count else { return }
        mediaplayer.equalizer = VLCAudioEqualizer(preset: presets[Int(profile.rawValue)])
    }

    // MARK: - Nerd stats (up-click on the clickpad)

    func toggleNerdStats() {
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
        label.font = .monospacedSystemFont(ofSize: 23, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 0

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        container.layer.cornerRadius = 12
        container.layer.masksToBounds = true
        container.addSubview(label)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 30),
            container.trailingAnchor.constraint(lessThanOrEqualTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
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

        let videoTrack = mediaplayer.videoTracks.first(where: { $0.isSelected }) ?? mediaplayer.videoTracks.first
        if let track = videoTrack, let video = track.video {
            let fps: Double = video.frameRateDenominator > 0
                ? Double(video.frameRate) / Double(video.frameRateDenominator)
                : Double(video.frameRate)
            lines.append(String(format: "Video   %@  %u×%u  %.3f fps", fourCCString(track.codec), video.width, video.height, fps))
        }

        let audioTrack = mediaplayer.audioTracks.first(where: { $0.isSelected }) ?? mediaplayer.audioTracks.first
        if let track = audioTrack, let audio = track.audio {
            lines.append(String(format: "Audio   %@  %u ch  %u Hz", fourCCString(track.codec), audio.channelsNumber, audio.rate))
            lines.append("Track   \(track.trackName)")
        }

        let passthrough = mediaplayer.audio?.passthrough ?? false
        lines.append("Output  " + (passthrough ? "Bitstream (Dolby passthrough)" : "PCM (decoded)"))

        let textTrack = mediaplayer.textTracks.first(where: { $0.isSelected })
        lines.append("Subs    " + (textTrack?.trackName ?? "none"))

        if let stats = mediaplayer.media?.statistics {
            // input_bitrate is in bytes/ms — ×8000 gives bit/s, then to Mb/s.
            lines.append(String(format: "Input   %.1f Mb/s  ·  demux %.1f Mb/s", Double(stats.inputBitrate) * 8000 / 1_000_000, Double(stats.demuxBitrate) * 8000 / 1_000_000))
            lines.append("Frames  \(stats.displayedPictures) shown · \(stats.latePictures) late · \(stats.lostPictures) lost")
        }

        lines.append("Buffer  \(Int((progressBar?.bufferProgress ?? 0) * 100))% downloaded")
        return lines.joined(separator: "\n")
    }
}

