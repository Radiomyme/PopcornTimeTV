

import UIKit
import MediaPlayer
import PopcornTorrent
import PopcornKit


protocol PCTPlayerViewControllerDelegate: AnyObject {
    func playNext(_ episode: Episode)
    
}

/// Optional functions
extension PCTPlayerViewControllerDelegate {
    func playNext(_ episode: Episode) {}
}

class PCTPlayerViewController: UIViewController, VLCMediaPlayerDelegate, UIGestureRecognizerDelegate, UpNextViewControllerDelegate, OptionsViewControllerDelegate {
    
    // MARK: - IBOutlets
    
    @IBOutlet var movieView: UIView!
    @IBOutlet var loadingActivityIndicatorView: UIView!
    @IBOutlet var progressBar: ProgressBar!
    
    @IBOutlet var overlayViews: [UIView] = []
    
    // tvOS exclusive
    @IBOutlet var dimmerView: UIView?
    @IBOutlet var infoHelperView: UIView?

    var lastTranslation: CGFloat = 0.0

#if os(tvOS)
    // Nerd-stats overlay (toggled with an up-click on the Siri Remote
    // clickpad). Stored here because extensions can't add stored properties;
    // all behavior lives in PCTPlayerViewController+tvOS.swift.
    var nerdStatsContainer: UIView?
    var nerdStatsLabel: UILabel?
    var nerdStatsTimer: Timer?
#endif
    
    // iOS exclusive
    @IBOutlet var airPlayingView: UIView?
    @IBOutlet var screenshotImageView: UIImageView?
    @IBOutlet var upNextContainerView: UIView?
    
    @IBOutlet var playPauseButton: UIButton?
    @IBOutlet var subtitleSwitcherButton: UIButton?
    @IBOutlet var videoDimensionsButton: UIButton?
    
    @IBOutlet var tapOnVideoRecognizer: UITapGestureRecognizer?
    @IBOutlet var doubleTapToZoomOnVideoRecognizer: UITapGestureRecognizer?
    
    @IBOutlet var regularConstraints: [NSLayoutConstraint] = []
    @IBOutlet var compactConstraints: [NSLayoutConstraint] = []
    @IBOutlet var duringScrubbingConstraints: NSLayoutConstraint?
    @IBOutlet var finishedScrubbingConstraints: NSLayoutConstraint?
    @IBOutlet var subtitleSwitcherButtonWidthConstraint: NSLayoutConstraint?
    
    @IBOutlet var scrubbingSpeedLabel: UILabel?
    
    
    
    
    // MARK: - Slider actions

    func positionSliderDidDrag() {
        let time = NSNumber(value: progressBar.scrubbingProgress * streamDuration)
        let remainingTime = NSNumber(value: time.floatValue - streamDuration)
        progressBar.remainingTimeLabel.text = VLCTime(number: remainingTime).stringValue
        progressBar.scrubbingTimeLabel.text = VLCTime(number: time).stringValue
        workItem?.cancel()
        workItem = DispatchWorkItem { [weak self] in
            if let image = self?.screenshotAtTime(time) {
#if os(tvOS)
                    self?.progressBar.screenshot = image
#endif
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem!)
    }
    
    func positionSliderAction() {
        resetIdleTimer()
        mediaplayer.play()
        if mediaplayer.isSeekable {
            let time = NSNumber(value: progressBar.scrubbingProgress * streamDuration)
            mediaplayer.time = VLCTime(number: time)
        }
    }
    
    // MARK: - Button actions
    
    /// Toggle playback. This is the Siri Remote Play/Pause button (storyboard
    /// gesture with `allowedPressTypes = playPause`) AND every Now-Playing /
    /// remote-control play/pause command. It used to fake a Select-click,
    /// which actually drops into *scrubbing* mode — so the dedicated
    /// Play/Pause button never toggled playback. Do a clean toggle instead.
    @IBAction func playandPause() {
        if mediaplayer.isPlaying {
            // canPause guards unseekable live streams; always true for a torrent file.
            if mediaplayer.canPause { mediaplayer.pause() }
        } else {
            mediaplayer.play()
        }
#if os(tvOS)
        // Reveal the controls for visual feedback, then re-arm auto-hide.
        if progressBar.isHidden { toggleControlsVisible() }
        resetIdleTimer()
#endif
    }
    
    @IBAction func fastForward() {
        mediaplayer.jumpForward(30)
    }
    
    @IBAction func rewind() {
        mediaplayer.jumpBackward(30)
    }
    
    @IBAction func fastForwardHeld(_ sender: UIGestureRecognizer) {
        switch sender.state {
        case .began:
            fallthrough
        case .changed:
#if os(tvOS)
            progressBar.hint = .fastForward
#endif
            guard mediaplayer.rate == 1.0 else { break }
            mediaplayer.fastForward(atRate: 20.0)
        case .cancelled:
            fallthrough
        case .failed:
            fallthrough
        case .ended:
#if os(tvOS)
            progressBar.hint = .none
#endif
            mediaplayer.rate = 1.0
            resetIdleTimer()
        default:
            break
        }
    }
    
    @IBAction func rewindHeld(_ sender: UIGestureRecognizer) {
        switch sender.state {
        case .began:
            fallthrough
        case .changed:
#if os(tvOS)
            progressBar.hint = .rewind
#endif
            guard mediaplayer.rate == 1.0 else { break }
            mediaplayer.rewind(atRate: 20.0)
        case .cancelled:
            fallthrough
        case .failed:
            fallthrough
        case .ended:
#if os(tvOS)
            progressBar.hint = .none
#endif
            mediaplayer.rate = 1.0
            resetIdleTimer()
        default:
            break
        }
    }
    
    @IBAction func didFinishPlaying() {
        mediaplayer.delegate = nil
        mediaplayer.stop()
        
        removeRemoteCommandCenterHandlers()
        endReceivingScreenNotifications()
        
        streamer.cancelStreamingAndDeleteData(UserDefaults.standard.bool(forKey: "removeCacheOnPlayerExit"))
        
        setProgress(status: .finished)
        NotificationCenter.default.removeObserver(self, name: .PTTorrentStatusDidChange, object: nil)
        
        dismiss(animated: true)
    }
    
    // MARK: - Public vars
    
    weak var delegate: PCTPlayerViewControllerDelegate?
    var subtitles: [Subtitle] {
        return media.subtitles
    }
    /// Downloaded subtitle awaiting application. VLCKit silently drops an
    /// `addPlaybackSlave` issued before the media is parsed/playing — which is
    /// exactly when the preferred-language auto-selection in `viewDidLoad`
    /// runs, and often when the user picks one from the just-opened options
    /// panel while the stream is still buffering. So we hold the downloaded
    /// file and (re)apply it once the player is actually playing.
    private var pendingSubtitleURL: URL?
    private var appliedSubtitleURL: URL?

    /// One-shot: re-select the "encoded" (passthrough) audio device once the
    /// stream is actually playing — the aout may not exist when viewDidLoad
    /// sets it — and log the audio tracks so the codec (DD+ vs TrueHD) is
    /// visible in the console when verifying Atmos on the device.
    private var didReassertPassthrough = false
    private func reassertPassthroughIfNeeded() {
#if os(tvOS)
        guard !didReassertPassthrough else { return }
        didReassertPassthrough = true
        if UserDefaults.standard.object(forKey: "audioPassthrough") as? Bool ?? true {
            mediaplayer.audio?.passthrough = true
        }
        print("[Player] audio tracks: \(mediaplayer.audioTracks.map { $0.trackName })")
#endif
    }

    var currentSubtitle: Subtitle? {
        didSet {
            guard let subtitle = currentSubtitle else {
                pendingSubtitleURL = nil
                appliedSubtitleURL = nil
                mediaplayer.deselectAllTextTracks() // Remove all subtitles (VLCKit 4 track API)
                return
            }
            PopcornKit.downloadSubtitleFile(subtitle.link, downloadDirectory: directory, completion: { [weak self] (subtitlePath, error) in
                guard let self = self, let subtitlePath = subtitlePath else { return }
                self.pendingSubtitleURL = subtitlePath
                self.applyPendingSubtitle()
            })
        }
    }

    /// Text-track ids that existed before the last `addPlaybackSlave` call.
    /// Non-nil means "a slave was added and its track hasn't been selected
    /// yet" — VLCKit 4's `enforce:` flag does NOT reliably select the slave's
    /// track, so we watch for the new track to appear (it registers a moment
    /// after the call) and select it explicitly from the time-changed tick.
    private var textTrackIdsBeforeSlave: Set<String>?

    /// Attaches the pending subtitle as an enforced playback slave, but only
    /// once the media is actually playing — otherwise VLCKit drops it on the
    /// floor. Called from the download callback and again from
    /// `mediaPlayerStateChanged(.playing)` so whichever happens last wins.
    func applyPendingSubtitle() {
        guard let url = pendingSubtitleURL, url != appliedSubtitleURL, mediaplayer.isPlaying else { return }
        textTrackIdsBeforeSlave = Set(mediaplayer.textTracks.map { $0.trackId })
        mediaplayer.addPlaybackSlave(url, type: .subtitle, enforce: true)
        appliedSubtitleURL = url
    }

    /// Select the slave's text track once VLC registers it. Distinguishing by
    /// track id (rather than "select the last one") keeps MKV-embedded
    /// subtitle tracks from being picked by mistake.
    func selectSlaveTextTrackIfNeeded() {
        guard let priorIds = textTrackIdsBeforeSlave else { return }
        let newTracks = mediaplayer.textTracks.filter { !priorIds.contains($0.trackId) }
        guard let slaveTrack = newTracks.last else { return } // not registered yet — keep waiting
        slaveTrack.isSelectedExclusively = true
        textTrackIdsBeforeSlave = nil
        print("[Player] subtitles ON: selected text track '\(slaveTrack.trackName)' (\(mediaplayer.textTracks.count) total)")
    }
    
    // MARK: - Private vars
    
#if os(tvOS)
    // Force VLC's AVSampleBufferAudioRenderer output (",any" keeps fallback).
    // It's the only aout with an "encoded" device — which is what
    // VLCAudio.passthrough actually selects (verified: setPassthrough: calls
    // libvlc_audio_output_device_set(mp, "encoded")). With it, AC-3/E-AC-3
    // (incl. DD+ Atmos JOC) bitstreams reach the AVR; other codecs gracefully
    // fall back to PCM. The audiounit_ios output can't passthrough at all.
    //
    // "--spdif" is the second half of the puzzle: selecting the encoded
    // device alone is NOT enough — VLC's decoder chain still decodes AC-3/
    // E-AC-3 to PCM unless the core `spdif` option makes the A/52 packetizer
    // hand the compressed frames to the aout (via the tospdif encapsulation
    // filter). Observed on-device: eac3 track + encoded device still showed
    // "PCM (decoded)" until spdif was set.
    private(set) var mediaplayer: VLCMediaPlayer = {
        var options = ["--aout=avsamplebuffer,any"]
        if UserDefaults.standard.object(forKey: "audioPassthrough") as? Bool ?? true {
            options.append("--spdif")
        }
        return VLCMediaPlayer(options: options)
    }()
#else
    private(set) var mediaplayer = VLCMediaPlayer()
#endif
    private(set) var url: URL!
    private(set) var directory: URL!
    private(set) var localPathToMedia: URL!
    private(set) var media: Media!
    private(set) var streamer: PTTorrentStreamer!
    internal var nextEpisode: Episode?
    internal var startPosition: Float = 0.0
    private var idleWorkItem: DispatchWorkItem?
    internal var shouldHideStatusBar = true
    private let NSNotFound: Int32 = -1
    private var imageGenerator: AVAssetImageGenerator!
    internal var workItem: DispatchWorkItem?
    private var resumePlayback = false
    internal var streamDuration: Float {
        guard let remaining = (mediaplayer.remainingTime ?? VLCTime(int: 0)).value?.floatValue, let elapsed = mediaplayer.time.value?.floatValue else { return Float(CMTimeGetSeconds(imageGenerator.asset.duration) * 1000) }
        return fabsf(remaining) + elapsed
    }
    internal var nowPlayingInfo: [String: Any]? {
        get {
            return MPNowPlayingInfoCenter.default().nowPlayingInfo
        } set {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = newValue
        }
    }
    
    // MARK: - Player functions
    
    func play(_ media: Media, fromURL url: URL, localURL local: URL, progress fromPosition: Float, nextEpisode: Episode? = nil, directory: URL, streamer: PTTorrentStreamer) {
        self.url = url
        self.localPathToMedia = local
        self.media = media
        self.startPosition = fromPosition
        self.nextEpisode = nextEpisode
        self.directory = directory
        self.imageGenerator = AVAssetImageGenerator(asset: AVAsset(url: local))
        self.streamer = streamer
    }
    
    // MARK: - Options view controller delegate
    
    func didSelectSubtitle(_ subtitle: Subtitle?) {
        currentSubtitle = subtitle
    }
    
    func didSelectAudioDelay(_ delay: Int) {
        mediaplayer.currentAudioPlaybackDelay = Int(1e6) * delay
    }

    func didSelectAudioTrack(_ index: Int32) {
        // VLCKit 4 selects tracks by object, not by VLC's internal index. The
        // options UI passes the *position* in `audioTracks` (see the adapters
        // in the tvOS presentOptionsViewController), so select that element.
        guard index >= 0, Int(index) < mediaplayer.audioTracks.count else { return }
        mediaplayer.audioTracks[Int(index)].isSelectedExclusively = true
    }

    /// Whether we already tried to honour the "Audio Language" setting for
    /// this playback. Tracks only become visible to VLC once decoding has
    /// started, so the check runs on the first time-changed callback.
    private var didAutoSelectAudioTrack = false

    /// If the file carries an audio track matching the user's preferred
    /// audio language (Settings → Audio Language), switch to it. Track
    /// naming is free-form ("Track 1", "French", "[fre]", "VFF - Français"…)
    /// so we match against the language's localized name, English name and
    /// ISO 639-1/2 codes.
    func autoSelectAudioTrackIfNeeded() {
        guard !didAutoSelectAudioTrack else { return }
        didAutoSelectAudioTrack = true

        let tracks = mediaplayer.audioTracks
        guard
            let preferred = UserDefaults.standard.string(forKey: "preferredAudioLanguage"),
            let code = Locale.commonISOLanguageCodes.first(where: {
                Locale.current.localizedString(forLanguageCode: $0)?.localizedCapitalized == preferred
            }),
            tracks.count > 1
        else { return }

        var tokens: Set<String> = [preferred.lowercased(), code.lowercased()]
        if let english = Locale(identifier: "en").localizedString(forLanguageCode: code) {
            tokens.insert(english.lowercased())
        }
        if let alpha3 = Locale.LanguageCode(code).identifier(.alpha3) {
            tokens.insert(alpha3.lowercased())
        }

        for track in tracks {
            // Split on non-letters so the 2-letter code can't false-match
            // inside an unrelated word ("en" in "Enhanced").
            let words = Set(track.trackName.lowercased().components(separatedBy: CharacterSet.letters.inverted)).subtracting([""])
            if !words.isDisjoint(with: tokens) {
                print("[Player] auto-selecting audio track '\(track.trackName)' for language '\(preferred)'")
                track.isSelectedExclusively = true
                return
            }
        }
    }

    
    func didSelectSubtitleDelay(_ delay: Int) {
        mediaplayer.currentVideoSubTitleDelay = Int(1e6) * delay
    }
    
    func didSelectEncoding(_ encoding: String) {
        mediaplayer.media?.addOptions([vlcSettingTextEncoding: encoding])
    }
    
    func screenshotAtTime(_ time: NSNumber) -> UIImage? {
        guard let image = try? imageGenerator.copyCGImage(at: CMTimeMakeWithSeconds(time.doubleValue/1000.0, preferredTimescale: 1000), actualTime: nil) else { return nil }
        return UIImage(cgImage: image)
    }
    
    // MARK: - View Methods
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard mediaplayer.state == .stopped || mediaplayer.state == .opening else { return }
        if startPosition > 0.0 {
            let isRegular = traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular
            let style: UIAlertController.Style = isRegular ? .alert : .actionSheet
            let continueWatchingAlert = UIAlertController(title: nil, message: nil, preferredStyle: style)
            
#if os(tvOS)
                NotificationCenter.default.addObserver(self, selector: #selector(alertFocusDidChange(_:)), name: .UIViewControllerFocusedViewDidChange, object: continueWatchingAlert)
#endif
            
            self.loadingActivityIndicatorView.isHidden = true
            
            
            continueWatchingAlert.addAction(UIAlertAction(title: "Resume Playing".localized, style: .default, handler:{ action in
                UIDevice.current.userInterfaceIdiom == .tv ? NotificationCenter.default.removeObserver(self, name: .UIViewControllerFocusedViewDidChange, object: continueWatchingAlert) : ()
                self.resumePlayback = true
                self.loadingActivityIndicatorView.isHidden = false
                self.mediaplayer.play()
            }))
            continueWatchingAlert.addAction(UIAlertAction(title: "Start from Beginning".localized, style: .default, handler: { action in
                UIDevice.current.userInterfaceIdiom == .tv ? NotificationCenter.default.removeObserver(self, name: .UIViewControllerFocusedViewDidChange, object: continueWatchingAlert) : ()
                self.loadingActivityIndicatorView.isHidden = false
                self.mediaplayer.play()
            }))
            continueWatchingAlert.popoverPresentationController?.sourceView = progressBar
            present(continueWatchingAlert, animated: true)
        } else {
            mediaplayer.play()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        mediaplayer.delegate = self
        mediaplayer.drawable = movieView
        mediaplayer.media = VLCMedia(url: url)

        // Tune VLC for max-quality playback on Apple TV 4K. Larger cache windows
        // hide network jitter on 1080p/2160p streams that PopcornTorrent serves
        // over HTTP localhost while still downloading. Disable VLC's framedrop
        // on slow seeks so high-bitrate sources keep their picture quality.
        let mediaOptions: [String: Any] = [
            "network-caching": NSNumber(value: 5000),
            "file-caching":    NSNumber(value: 5000),
            "live-caching":    NSNumber(value: 5000),
            "drop-late-frames": NSNumber(value: 0),
            "skip-frames":      NSNumber(value: 0),
        ]
        mediaplayer.media?.addOptions(mediaOptions)

#if os(tvOS)
        // Long-form movie audio session: this is what tvOS expects from a
        // video player before it will negotiate Dolby output with the AVR /
        // soundbar over HDMI-eARC. Without it the session runs in the generic
        // default and the renderer may stay in PCM.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        // Dolby / DTS bitstream passthrough to the receiver so Atmos, TrueHD,
        // E-AC3 and DTS-HD reach the AVR undecoded instead of being downmixed
        // to PCM stereo by VLCKit. This only helps when the Apple TV's audio
        // output (HDMI/eARC) and the connected AVR/soundbar can decode the
        // bitstream; on setups that can't, an unsupported track can come back
        // silent — so it's gated behind a default that can be flipped off
        // without a rebuild. HDR is a separate matter: VLC 3.7 tone-maps HDR
        // to SDR and exposes no passthrough for it, so 4K HDR/DV in an .mkv
        // still plays SDR here (only the AVPlayer path renders true HDR, and
        // it can't open .mkv).
        if UserDefaults.standard.object(forKey: "audioPassthrough") as? Bool ?? true {
            mediaplayer.audio?.passthrough = true
        }

#if DEBUG
        // Surface libvlc's own log in Xcode's console — the aout lines show
        // whether the avsamplebuffer "encoded" device engaged and whether the
        // A/52 packetizer went passthrough or fell back to decoding.
        let vlcLogger = VLCConsoleLogger()
        vlcLogger.level = .debug
        mediaplayer.libraryInstance.loggers = [vlcLogger]
#endif
#endif

        NotificationCenter.default.addObserver(self, selector: #selector(torrentStatusDidChange(_:)), name: .PTTorrentStatusDidChange, object: streamer)
        
        let settings = SubtitleSettings.shared
        // These are private libvlc text-renderer selectors that may not exist
        // in VLCKit 4's rewritten core. Call them optionally (`?`) so a missing
        // selector no-ops instead of crashing (force-unwrap would trap). The
        // font *scale* has a public 4.x replacement, so drive that too.
        (mediaplayer as VLCFontAppearance).setTextRendererFontSize?(NSNumber(value: settings.size.rawValue))
        (mediaplayer as VLCFontAppearance).setTextRendererFontColor?(NSNumber(value: settings.color.hexInt()))
        (mediaplayer as VLCFontAppearance).setTextRendererFont?(settings.font.fontName as NSString)
        (mediaplayer as VLCFontAppearance).setTextRendererFontForceBold?(NSNumber(booleanLiteral: settings.style == .bold || settings.style == .boldItalic))
        if let preferredLanguage = settings.language {
            currentSubtitle = subtitles.first(where: {$0.language == preferredLanguage})
        }
        mediaplayer.media?.addOptions([vlcSettingTextEncoding: settings.encoding])
        
        if let first = tapOnVideoRecognizer, let second = doubleTapToZoomOnVideoRecognizer {
            first.require(toFail: second)
        }
        
        subtitleSwitcherButton?.isHidden = subtitles.count == 0
        subtitleSwitcherButtonWidthConstraint?.constant = subtitleSwitcherButton?.isHidden == true ? 0 : 24
        
#if os(tvOS)
            let gesture = SiriRemoteGestureRecognizer(target: self, action: #selector(touchLocationDidChange(_:)))
            gesture.delegate = self
            view.addGestureRecognizer(gesture)
            
            let clickGesture = SiriRemoteGestureRecognizer(target: self, action: #selector(clickGesture(_:)))
            clickGesture.delegate = self
            view.addGestureRecognizer(clickGesture)
            
            didSelectEqualizerProfile(.fullDynamicRange)
#endif
    }
    
    // MARK: - Player changes notifications
    
    @objc func torrentStatusDidChange(_ aNotification: Notification) {
        if let streamer = aNotification.object as? PTTorrentStreamer {
            progressBar?.bufferProgress = streamer.torrentStatus.totalProgress
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if loadingActivityIndicatorView.isHidden == false {
            loadingActivityIndicatorView.isHidden = true

            addRemoteCommandCenterHandlers()
            beginReceivingScreenNotifications()
            configureNowPlayingInfo()
            autoSelectAudioTrackIfNeeded()

            resetIdleTimer()
        }
        
        if resumePlayback && mediaplayer.isSeekable {
            resumePlayback = false
            let time = NSNumber(value: startPosition * streamDuration)
            mediaplayer.time = VLCTime(number: time)
        }
        
        playPauseButton?.setImage(UIImage(named: "Pause"), for: .normal)
        
        progressBar.isBuffering = false
        
        progressBar.remainingTimeLabel.text = (mediaplayer.remainingTime ?? VLCTime(int: 0)).stringValue
        progressBar.elapsedTimeLabel.text = mediaplayer.time.stringValue
        progressBar.progress = Float(mediaplayer.position) // VLCKit 4: position is Double
        selectSlaveTextTrackIfNeeded()
        
        if nextEpisode != nil && ((mediaplayer.remainingTime ?? VLCTime(int: 0)).intValue/1000) == -31 && presentedViewController == nil {
            performSegue(withIdentifier: "showUpNext", sender: nil)
        } else if ((mediaplayer.remainingTime ?? VLCTime(int: 0)).intValue/1000) < -31, let vc = presentedViewController as? UpNextViewController {
            vc.dismiss(animated: true)
        }
    }
    
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        resetIdleTimer()
        progressBar.isBuffering = false
        nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = (mediaplayer.time.value?.doubleValue ?? 0)/1000
        // VLCKit 4 collapsed the state enum: `.ended`/`.buffering`/`.esAdded`
        // are gone. End-of-file and manual stop both surface as `.stopped`;
        // buffering is no longer a player state (the torrent streamer drives
        // the buffering UI via torrentStatusDidChange).
        switch mediaplayer.state {
        case .error:
            fallthrough
        case .stopped:
            setProgress(status: .finished)
            didFinishPlaying()
        case .paused:
            setProgress(status: .paused)
            playPauseButton?.setImage(UIImage(named: "Play"), for: .normal)
            nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        case .playing:
            playPauseButton?.setImage(UIImage(named: "Pause"), for: .normal)
            setProgress(status: .watching)
            nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = Double(mediaplayer.rate)
            applyPendingSubtitle() // media is ready now — safe to attach the slave
            reassertPassthroughIfNeeded()
        default:
            break
        }
    }
    
    
    @IBAction func toggleControlsVisible() {
        shouldHideStatusBar = overlayViews.first!.isHidden
        UIView.animate(withDuration: 0.25, animations: {
            if self.overlayViews.first!.isHidden {
                self.overlayViews.forEach({
                    $0.alpha = 1.0
                    $0.isHidden = false
                })
            } else {
                self.overlayViews.forEach({ $0.alpha = 0.0 })
            }
         }, completion: { finished in
            if self.overlayViews.first!.alpha == 0.0 {
                self.overlayViews.forEach({ $0.isHidden = true })
            }
            self.resetIdleTimer()
        }) 
    }
    
    // MARK: - Timers
    
    func resetIdleTimer() {
        idleWorkItem?.cancel()
        idleWorkItem = DispatchWorkItem() { [unowned self] in
            if !self.progressBar.isHidden && self.mediaplayer.isPlaying && !self.progressBar.isScrubbing && !self.progressBar.isBuffering && self.mediaplayer.rate == 1.0  && self.movieView.isDescendant(of: self.view) // If paused, scrubbing, fast forwarding, loading or mirroring, cancel work Item so UI doesn't disappear
            {
                self.toggleControlsVisible()
            }
        }
        
        let delay: TimeInterval = UIDevice.current.userInterfaceIdiom == .tv ? 3 : 5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: idleWorkItem!)
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {    
        return true
    }
    
    func setProgress(status: Trakt.WatchedStatus) {
        if let movie = media as? Movie {
            WatchedlistManager<Movie>.movie.setCurrentProgress(progressBar.progress, for: movie.id, with: status)
        } else if let episode = media as? Episode {
            WatchedlistManager<Episode>.episode.setCurrentProgress(progressBar.progress, for: episode.id, with: status)
        }
    }
    
    // MARK: UpNextViewControllerDelegate
    
    func viewController(_ viewController: UpNextViewController, proceedToNextVideo proceed: Bool) {
        let completion: (() -> Void) = { [unowned self] in
            if proceed {
                self.didFinishPlaying()
                self.delegate?.playNext(self.nextEpisode!)
            }
        }
        if UIDevice.current.userInterfaceIdiom == .tv {
            viewController.dismiss(animated: true, completion: completion)
        } else {
            UIView.animate(withDuration: .default, animations: { 
                self.upNextContainerView?.transform = .identity
            }) { (_) in
                completion()
            }
            
        }
    }
    
    // MARK: - Navigation
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "showUpNext", let vc = segue.destination as? UpNextViewController, let episode = nextEpisode {
            vc.delegate = self
            vc.modalPresentationStyle = .custom
            
            vc.loadViewIfNeeded()
            
            if UIDevice.current.userInterfaceIdiom == .tv {
                vc.titleLabel?.text = "Episode".localized + " \(episode.episode) - " + episode.title
                vc.summaryView?.text = episode.summary
            } else {
                vc.titleLabel?.text = episode.title
                vc.subtitleLabel?.text = "Season".localized + " \(episode.season) " + "Episode".localized + " \(episode.episode)"
                vc.infoLabel?.text = episode.show?.title
            }
            
            TMDBManager.shared.getEpisodeScreenshots(forShowWithImdbId: episode.show?.id, orTMDBId: episode.show?.tmdbId, season: episode.season, episode: episode.episode) { [weak self, weak vc] (tmdbId, image, error) in
                self?.nextEpisode?.largeBackgroundImage = image
                    
                if let image = image, let url = URL(string: image) {
                    vc?.imageView.af.setImage(withURL: url)
                }
                
                self?.nextEpisode?.getSubtitles { (subtitles) in
                    self?.nextEpisode?.subtitles = subtitles
                }
            }
        }
        
    }
}
