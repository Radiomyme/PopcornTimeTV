

import UIKit
import Combine
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

#if DEBUG && os(tvOS)
/// Prints ONLY VLC's audio-pipeline log lines (aout / spdif / eac3 / a52 /
/// avsamplebuffer…) so the passthrough negotiation is visible in Xcode's
/// console without libvlc's full debug flood — plus the demuxer and video
/// output VLC picked, its seeks and first picture (bounded storage checks).
final class VLCAudioLogFilter: NSObject, VLCLogging {
    var level: VLCLogLevel = .debug
    private let keywords = ["aout", "audio output", "spdif", "eac3", "a52", "passthrough", "avsamplebuffer", "audiounit",
                            "using demux module", "using vout display module", "seek request", "received first picture",
                            "no spu decoder"] + VLCAudioLogFilter.extraKeywords
    /// `-PTDebugVLCLog "preroll,discontinuity,…"`: more of libvlc's lines,
    /// by the words they hold (measurements of a demuxer's seeks).
    private static var extraKeywords: [String] {
        (UserDefaults.standard.string(forKey: "PTDebugVLCLog") ?? "").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let module = context?.module ?? ""
        let haystack = (module + " " + message).lowercased()
        guard logLevel == .error || keywords.contains(where: { haystack.contains($0) }) else { return }
        print("[VLC \(module)\(logLevel == .error ? " ERROR" : "")] \(message)")
    }
}
#endif

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
            seekLimited(toMilliseconds: NSNumber(value: progressBar.scrubbingProgress * streamDuration))
        }
    }
    
    // MARK: - Button actions
    
    /// Toggle playback. This is the Siri Remote Play/Pause button (storyboard
    /// gesture with `allowedPressTypes = playPause`) AND every Now-Playing /
    /// remote-control play/pause command. It used to fake a Select-click,
    /// which actually drops into *scrubbing* mode — so the dedicated
    /// Play/Pause button never toggled playback. Do a clean toggle instead.
    @IBAction func playandPause() {
        // A resume on its way: VLC is not paused while it gets there (the
        // press is kept for the arrival, `VLCResumeWait.pausesAtArrival`).
        if resumeWait != nil {
            resumeOverlay?.showsPause = resumeWait?.togglePauseAtArrival() ?? false
            return
        }
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
        guard resumeWait == nil else { return } // nothing to jump from before the resume point plays
        playheadWatch.noteOwnSeek()
        mediaplayer.jumpForward(30)
        noteUserMovedPlayhead()
    }
    
    @IBAction func rewind() {
        guard resumeWait == nil else { return }
        jumpBackwardLimited(30)
        noteUserMovedPlayhead()
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
    
    /// Closes the player: the user left, Up Next proceeds, or VLC stopped by
    /// itself (end of file, error). The final progress save comes first,
    /// before `stop()`: the last position VLC reached.
    @IBAction func didFinishPlaying() {
#if os(tvOS)
        // The user left the player (not a close for the next episode):
        // nothing of the next episode starts.
        if !isClosingForNextEpisode { upNextSession?.playerClosed() }
        upNextCardSubscription = nil
#endif
        if !isClosing {
            notePlayerPosition()
            setProgress(status: .finished)
            isClosing = true
        }
        // A resume still on its way: abandoned (the save above kept the
        // resume point: VLC never followed it, `VLCWatchProgress`).
        resumeWait?.logEnded("player closed", now: VLCResumeWait.clock)
        resumeWait = nil
        resumeWaitTimer?.invalidate()
        resumeWaitTimer = nil
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        mediaplayer.delegate = nil
        mediaplayer.stop()
        
        removeRemoteCommandCenterHandlers()
        endReceivingScreenNotifications()
        
        // The payload is deleted next: nothing of this player may keep it
        // open (a deleted file's disk space comes back only once its last
        // descriptor closes). The asset behind the scrub thumbnails and the
        // duration fallback holds it open once read; a pending thumbnail
        // would read it again.
        workItem?.cancel()
        idleWorkItem?.cancel()
        imageGenerator = nil
        BoundedStorageSession.session(for: streamer)?.detachHTTPPlayer(self)
        
        // Always delete the stream's partial: the Apple TV sandbox is small
        // and a kept partial can't be resumed anyway (see Media.play). Never
        // a download's files: the SPM PopcornTorrent deletes a finished
        // download's folder on `cancelStreamingAndDeleteData(true)`.
        streamer.cancelStreamingAndDeleteData(!(streamer is PTTorrentDownload))
        
        NotificationCenter.default.removeObserver(self, name: .PTTorrentStatusDidChange, object: nil)
        PlaybackStreamContext.of(streamer)?.deficit.detach(self)
        deficitSubscription = nil
        
        // « Lighter version »: the next stream starts once this player is gone.
        let next = afterClose
        afterClose = nil
        // Anything this player presents (the slow-resume offer, the next
        // episode's card or chooser, the subtitles / audio panel, the
        // bandwidth toast…): `dismiss` on the player would close only that
        // and leave a stopped player on screen — and the next playback
        // could not be presented over it. Dismissing from the presenter
        // takes the whole stack down, as the native player does.
        resumeOffer = nil
        if presentedViewController != nil, let presenter = presentingViewController {
            presenter.dismiss(animated: true, completion: next)
        } else {
            dismiss(animated: true, completion: next)
        }
    }
    
    // MARK: - Public vars
    
    weak var delegate: PCTPlayerViewControllerDelegate?
    var subtitles: [Subtitle] {
        return media.subtitles
    }
    /// Downloaded subtitle awaiting application. VLCKit silently drops an
    /// `addPlaybackSlave` issued before the media is parsed/playing — often
    /// when the user picks one from the just-opened options panel while the
    /// stream is still buffering. So we hold the downloaded file, and
    /// convert + apply it once the player is actually playing (the
    /// conversion needs the video's frame rate, which VLC knows by then).
    private var pendingSubtitle: (subtitle: Subtitle, file: URL)?
    /// A pending file is being converted for VLC (one at a time).
    private var isConvertingSubtitle = false

    /// One-shot: re-select the "encoded" (passthrough) audio device once the
    /// stream is actually playing — the aout may not exist when viewDidLoad
    /// sets it — and log the audio tracks so the codec (DD+ vs TrueHD) is
    /// visible in the console when verifying Atmos on the device.
    private var didReassertPassthrough = false
    private func reassertPassthroughIfNeeded() {
#if os(tvOS)
        guard !didReassertPassthrough else { return }
        didReassertPassthrough = true
        guard UserDefaults.standard.object(forKey: "audioPassthrough") as? Bool ?? true else { return }
        mediaplayer.audio?.passthrough = true
        print("[Player] audio tracks: \(mediaplayer.audioTracks.map { $0.trackName })")
        print("[Player] passthrough engaged (t0): \(mediaplayer.audio?.passthrough ?? false)")
        // The aout can be torn down/recreated when the audio ES actually
        // starts decoding; a single early device-set request can be lost in
        // that window. Re-request a couple of seconds in and log whether the
        // encoded device finally stuck — key data point for the Atmos hunt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            self.mediaplayer.audio?.passthrough = true
            print("[Player] passthrough engaged (t3): \(self.mediaplayer.audio?.passthrough ?? false)")
        }
#endif
    }

    /// The OpenSubtitles file on screen (or on its way). nil: none of them —
    /// the file's own text track the user or the auto-selection picked
    /// (`selectedEmbeddedTrackId`), or no subtitles. Setting nil turns every
    /// text track off. A file that can't be shown — its download failed, or
    /// VLC never registered its track — stops being the choice
    /// (`dropFailedSubtitle`): the options panel shows what is on screen,
    /// and one click on the entry tries it again.
    var currentSubtitle: Subtitle? {
        didSet {
            // `dropFailedSubtitle` hands the choice back to what VLC already
            // shows: nothing to download, nothing to turn off.
            guard !choiceFollowsScreen else { return }
            guard let subtitle = currentSubtitle else {
                pendingSubtitle = nil
                mediaplayer.deselectAllTextTracks() // Remove all subtitles (VLCKit 4 track API)
                return
            }
            // Downloaded now; normalised to a UTF-8 SubRip once VLC plays
            // (applyPendingSubtitle): OpenSubtitles serves the original code
            // page (CP1251, CP1252…) and formats such as MicroDVD that VLC
            // would otherwise mis-decode or mis-time.
            ExternalSubtitleLoader.download(subtitle, into: directory) { [weak self] file in
                // The user may have picked another one (or none) meanwhile.
                guard let self = self, !self.isClosing, self.currentSubtitle == subtitle else { return }
                guard let file = file else {
                    // HTTP 404 / 429 / 5xx, network error: none of it is on screen.
                    print("[Player] subtitles: download failed for '\(subtitle.language)'")
                    self.dropFailedSubtitle(subtitle)
                    return
                }
                self.pendingSubtitle = (subtitle, file)
                self.applyPendingSubtitle()
            }
        }
    }

    /// Set while `dropFailedSubtitle` hands the choice back to what VLC shows.
    private var choiceFollowsScreen = false

    /// The OpenSubtitles file `subtitle` can't be shown: its download failed,
    /// or VLC never registered its track (`giveUpOnSlaveIfOverdue`). It stops
    /// being the choice, and what VLC shows stays on screen — nothing is
    /// turned off. The choice becomes that: an earlier OpenSubtitles file VLC
    /// still shows (`currentSubtitle` again, not downloaded again), the
    /// file's own track (`selectedEmbeddedTrackId`), or nothing. The options
    /// panel then shows what is on screen — one already open is refreshed
    /// (`refreshSubtitlesPanelIfPresented`) — and one click on the entry
    /// tries it again. (The iOS and macOS VLC players' rule.)
    private func dropFailedSubtitle(_ subtitle: Subtitle) {
        guard currentSubtitle == subtitle else { return }
        let shown = mediaplayer.textTracks.first(where: { $0.isSelected })
        choiceFollowsScreen = true
        currentSubtitle = shown.flatMap { attachedSlaveSubtitles[$0.trackId] }
        choiceFollowsScreen = false
        selectedEmbeddedTrackId = shown.flatMap { ExternalSubtitleLoader.isVLCSlaveTrackId($0.trackId) ? nil : $0.trackId }
        pendingSubtitle = nil // an earlier pick waiting to be attached was replaced by this one
#if os(tvOS)
        // An open panel still has the dropped entry checked: a click on it
        // would turn off what is on screen instead of retrying.
        refreshSubtitlesPanelIfPresented()
#endif
    }

    /// The playing video's frame rate (selected video track), nil while VLC
    /// doesn't know it.
    private func currentVideoFrameRate() -> Double? {
        guard let video = (mediaplayer.videoTracks.first(where: { $0.isSelected }) ?? mediaplayer.videoTracks.first)?.video else { return nil }
        return ExternalSubtitleLoader.videoFrameRate(numerator: video.frameRate, denominator: video.frameRateDenominator)
    }

    /// Text-track ids that existed before the last `addPlaybackSlave` call.
    /// Non-nil means "a slave was added and its track hasn't been selected
    /// yet" — VLCKit 4's `enforce:` flag does NOT reliably select the slave's
    /// track, so we watch for the new track to appear (it registers a moment
    /// after the call) and select it explicitly from the time-changed tick
    /// — for `slaveRegistrationTimeout` at most (`giveUpOnSlaveIfOverdue`).
    private var textTrackIdsBeforeSlave: Set<String>?
    /// The subtitle of that slave: its track is selected only while it is
    /// still `currentSubtitle`.
    private var slaveSubtitleAwaitingTrack: Subtitle?
    /// That slave's converted file (attached once more if VLC doesn't
    /// register it) and when it was attached.
    private var slaveFileAwaitingTrack: URL?
    private var slaveRequestDate: Date?
    /// The subtitle whose file was already attached a second time.
    private var slaveRetrySubtitle: Subtitle?
    /// VLC drops a slave it can't read — an HTML « download limit » page
    /// served as the file — without registering any track: after this long
    /// it is attached once more, then given up (the iOS and macOS VLC
    /// players' delay).
    private static let slaveRegistrationTimeout: TimeInterval = 8
    /// The OpenSubtitles file of each registered slave track (by VLC track
    /// id): what VLC shows becomes the choice again when a later file can't
    /// be shown (`dropFailedSubtitle`).
    private var attachedSlaveSubtitles: [String: Subtitle] = [:]

    /// Converts the pending subtitle to UTF-8 SRT — frame-based files
    /// (MicroDVD) timed with the video's frame rate — and attaches it as an
    /// enforced playback slave, but only once the media is actually playing:
    /// otherwise VLCKit drops it on the floor, and the frame rate isn't known.
    /// Called from the download callback, from
    /// `mediaPlayerStateChanged(.playing)` and from the time tick, so
    /// whichever happens last wins.
    func applyPendingSubtitle() {
        // VLCKit 4 reports `isPlaying` during `.opening` too, before the file's
        // tracks exist — only the `.playing` state guarantees the slave sticks;
        // with the file's tracks listed, the id snapshot below already holds
        // the embedded ones and the video's frame rate is known (otherwise
        // retried on the next time tick).
        guard let pending = pendingSubtitle, !isConvertingSubtitle, mediaplayer.state == .playing,
              !mediaplayer.videoTracks.isEmpty || !mediaplayer.audioTracks.isEmpty else { return }
        isConvertingSubtitle = true
        let frameRate = currentVideoFrameRate()
        print("[Player] subtitles: converting '\(pending.subtitle.language)' for VLC (video \(frameRate.map { String(format: "%.3f fps", $0) } ?? "frame rate unknown"))")
        ExternalSubtitleLoader.convertForVLC(fileAt: pending.file, subtitle: pending.subtitle, frameRate: frameRate) { [weak self] converted in
            guard let self = self else { return }
            self.isConvertingSubtitle = false
            // Another subtitle (or none) was picked meanwhile: that one goes next.
            guard let current = self.pendingSubtitle, current.file == pending.file else {
                self.applyPendingSubtitle()
                return
            }
            // Stopped meanwhile: kept pending, converted again on `.playing`.
            guard self.mediaplayer.state == .playing || self.mediaplayer.state == .paused else { return }
            self.pendingSubtitle = nil
            self.attachSlave(converted, for: pending.subtitle)
        }
    }

    /// Attaches `subtitle`'s converted `file` as an enforced playback slave;
    /// its track is selected once VLC registers it
    /// (`selectSlaveTextTrackIfNeeded`).
    private func attachSlave(_ file: URL, for subtitle: Subtitle) {
        textTrackIdsBeforeSlave = Set(mediaplayer.textTracks.map { $0.trackId })
        slaveSubtitleAwaitingTrack = subtitle
        slaveFileAwaitingTrack = file
        slaveRequestDate = Date()
        let result = mediaplayer.addPlaybackSlave(file, type: .subtitle, enforce: true)
        if result != 0 { print("[Player] subtitles: addPlaybackSlave refused (\(result))") } // no track: given up as an unreadable file
    }

    /// No longer waits for the attached slave's track.
    private func endSlaveWait() {
        textTrackIdsBeforeSlave = nil
        slaveSubtitleAwaitingTrack = nil
        slaveFileAwaitingTrack = nil
        slaveRequestDate = nil
    }

    /// The slave's track hasn't registered `slaveRegistrationTimeout` after
    /// the attach: the same file is attached once more, and the next time
    /// the subtitle is given up — no longer the choice (`dropFailedSubtitle`),
    /// so later selections aren't blocked either. A slave the user no longer
    /// wants is just no longer waited for.
    private func giveUpOnSlaveIfOverdue() {
        guard let requested = slaveRequestDate,
              Date().timeIntervalSince(requested) > Self.slaveRegistrationTimeout else { return }
        let subtitle = slaveSubtitleAwaitingTrack
        let file = slaveFileAwaitingTrack
        endSlaveWait()
        guard let subtitle = subtitle, currentSubtitle == subtitle else { return }
        if slaveRetrySubtitle != subtitle, let file = file {
            slaveRetrySubtitle = subtitle
            print("[Player] subtitles: VLC didn't register '\(subtitle.language)' — attaching it once more")
            attachSlave(file, for: subtitle)
        } else {
            print("[Player] subtitles: VLC never registered the OpenSubtitles track — giving up")
            dropFailedSubtitle(subtitle)
        }
    }

    /// Select the slave's text track once VLC registers it. Recognised by its
    /// track id (`ExternalSubtitleLoader.slaveTrackIds`), never "the last new
    /// track": the file's own subtitle tracks — MKV-embedded ones, or one
    /// registering late such as closed captions — are never picked by
    /// mistake. If the user picked another subtitle (or none) meanwhile, the
    /// slave's track isn't selected; `enforce:` may have turned it on, so
    /// the current choice is applied again: its OpenSubtitles file when VLC
    /// already registered it, the file's own track the user picked, else
    /// nothing. A track that doesn't register in time is given up
    /// (`giveUpOnSlaveIfOverdue`).
    func selectSlaveTextTrackIfNeeded() {
        guard let priorIds = textTrackIdsBeforeSlave else { return }
        let tracks = mediaplayer.textTracks
        let registered = ExternalSubtitleLoader.slaveTrackIds(tracks.map { $0.trackId }, addedAfter: priorIds)
        guard let slaveId = registered.last, let slaveTrack = tracks.first(where: { $0.trackId == slaveId }) else {
            giveUpOnSlaveIfOverdue() // not registered yet — keep waiting, up to the timeout
            return
        }
        let subtitle = slaveSubtitleAwaitingTrack
        endSlaveWait()
        if let subtitle = subtitle {
            for id in registered { attachedSlaveSubtitles[id] = subtitle }
        }
        if let subtitle = subtitle, currentSubtitle == subtitle {
            slaveTrack.isSelectedExclusively = true
            print("[Player] subtitles ON: selected text track '\(slaveTrack.trackName)' (\(slaveTrack.trackId), \(tracks.count) total)")
        } else if currentSubtitle == nil {
            if let id = selectedEmbeddedTrackId, let track = tracks.first(where: { $0.trackId == id }) {
                track.isSelectedExclusively = true
            } else {
                mediaplayer.deselectAllTextTracks()
            }
        } else if let current = currentSubtitle,
                  let track = tracks.first(where: { attachedSlaveSubtitles[$0.trackId] == current }) {
            track.isSelectedExclusively = true // the current choice, already attached, stays on screen
        } // else: another subtitle is on its way — selected once attached
    }

    // MARK: - The file's own subtitle tracks

    /// The file's own text track the user or the auto-selection picked — or
    /// the one VLC showed when an OpenSubtitles file that can't be shown was
    /// dropped (`dropFailedSubtitle`); nil when an OpenSubtitles file
    /// (`currentSubtitle`) or nothing is on.
    private(set) var selectedEmbeddedTrackId: String?
    /// The preferred subtitle language was applied (or there was nothing to apply).
    private var didAutoSelectSubtitle = false
    /// The user picked subtitles in the options panel: the auto-selection
    /// never overrides that.
    private var userChoseSubtitle = false
    /// Latched by `isInputReady` once VLC played with its tracks registered.
    private var didReachPlayingWithTracks = false

    /// The file's own text tracks VLC can show: VLC's text tracks minus the
    /// OpenSubtitles playback slaves (`ExternalSubtitleLoader.isVLCSlaveTrackId`)
    /// and the tracks no decoder takes (libavformat's demuxer lists SRT /
    /// ASS / WebVTT tracks with no codec: `BoundedStorageUX.isUndecodableVLCTrack`).
    func embeddedTextTracks() -> [VLCMediaPlayer.Track] {
        return mediaplayer.textTracks.filter {
            !ExternalSubtitleLoader.isVLCSlaveTrackId($0.trackId) && !BoundedStorageUX.isUndecodableVLCTrack(codec: $0.codec)
        }
    }

    /// True once VLC really plays the input with its tracks registered.
    /// VLCKit 4 reports `isPlaying` through the whole `.opening` phase too,
    /// which can last seconds on a torrent stream, while the demuxer hasn't
    /// registered a single track yet: deciding then would pick OpenSubtitles
    /// over the file's own subtitle track. So: wait for the `.playing` state
    /// with an audio or video track listed (the file's own text tracks are
    /// registered by then), latch it, and from then on only require the
    /// input to run. (Same rule as the iOS VLC player.)
    private var isInputReady: Bool {
        guard !isClosing else { return false }
        let state = mediaplayer.state
        if !didReachPlayingWithTracks {
            guard state == .playing, !mediaplayer.audioTracks.isEmpty || !mediaplayer.videoTracks.isEmpty else { return false }
            didReachPlayingWithTracks = true
            noteFirstFrameIfDue()
        }
        return state == .playing || state == .paused
    }

    /// The `[Start]` trace's last phase was noted.
    private var didNoteFirstFrame = false

    /// The `[Start]` trace's last phase: VLC really playing — where the user
    /// asked to: a resume counts once playback runs at its target, not when
    /// VLC decodes the file's first picture before its seek.
    private func noteFirstFrameIfDue() {
        guard !didNoteFirstFrame, didReachPlayingWithTracks, resumeWait == nil else { return }
        didNoteFirstFrame = true
        streamer?.noteStartFirstFrame(detail: "VLC")
    }

    /// Preferred subtitle language (Settings → Subtitles): the file's own
    /// matching text track first — never a forced-only one, a non-SDH one
    /// preferred — else the OpenSubtitles entry. Decided once, when the
    /// input is ready (`isInputReady`), unless the user already picked; the
    /// iOS VLC player's rule (`autoSelectSubtitleIfNeeded` there). The
    /// release's own track keeps playing in a native → VLC hand-off, where
    /// the remux showed it too.
    func autoSelectSubtitleIfNeeded() {
        guard !didAutoSelectSubtitle, !userChoseSubtitle, isInputReady else { return }
        didAutoSelectSubtitle = true
        // The file's text tracks VLC lists, and those it can show (a track
        // without a codec — libavformat's demuxer — is left out).
        let listed = mediaplayer.textTracks.filter { !ExternalSubtitleLoader.isVLCSlaveTrackId($0.trackId) }
        print("[Player] text tracks: \(listed.count) listed, \(embeddedTextTracks().count) shown \(listed.map { "'\($0.trackName)'" })")
        guard let code = PlaybackLanguagePreferences.preferredSubtitleLanguageCode else { return }
        let embedded = embeddedTextTracks().filter {
            (PlaybackLanguagePreferences.matches($0.language, code: code)
                || PlaybackLanguagePreferences.matches($0.trackName, code: code))
                && !PlaybackLanguagePreferences.isForcedSubtitle($0.trackName)
        }
        if let track = embedded.first(where: { !PlaybackLanguagePreferences.isHearingImpaired($0.trackName) }) ?? embedded.first {
            selectedEmbeddedTrackId = track.trackId
            if !track.isSelected { track.isSelectedExclusively = true }
            print("[Player] auto-selecting subtitle track '\(track.trackName)' for '\(code)'")
            return
        }
        if let subtitle = ExternalSubtitleLoader.preferredSubtitle(in: subtitles, code: code) {
            print("[Player] auto-selecting OpenSubtitles '\(subtitle.language)' for '\(code)'")
            currentSubtitle = subtitle
        }
    }

    /// The user picked one of the file's own text tracks in the options
    /// panel (nil: turned it off). Any OpenSubtitles file goes off first.
    func didSelectEmbeddedSubtitleTrack(_ trackId: String?) {
        userChoseSubtitle = true
        currentSubtitle = nil // every text track off, nothing pending
        selectedEmbeddedTrackId = trackId
        if let trackId = trackId, let track = mediaplayer.textTracks.first(where: { $0.trackId == trackId }) {
            track.isSelectedExclusively = true
        }
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
#if os(tvOS)
    /// Episode chaining (5.3.0): the playback's link, set by
    /// `AppDelegate.play` (or handed over by the native player) before
    /// `play(…)`. With a session the session drives the card
    /// (`reconcileUpNextCard`); without one, the storyboard's Up Next of
    /// before 5.3 (`nextEpisode`, segue `showUpNext`).
    var upNextLink: UpNextTVLink?
    private var upNextSession: UpNextSession?
    private var upNextCardSubscription: AnyCancellable?
    private weak var upNextOverlay: UpNextOverlayViewController?
    /// The last position / length VLC reported (s): the end of the file is
    /// told apart from an error stop.
    private var upNextLastPosition: Double = 0
    private var upNextLastDuration: Double?
    #if DEBUG
    /// `-PTDebugOpenOptionsAtRemaining` did its one opening.
    private var debugOpenedOptions = false
    #endif
    private var isClosingForNextEpisode = false
    private var upNextRetryScheduled = false
#endif
    internal var startPosition: Float = 0.0
    private var idleWorkItem: DispatchWorkItem?
    internal var shouldHideStatusBar = true
    private let NSNotFound: Int32 = -1
    /// Scrub thumbnails and `streamDuration`'s fallback, on the torrent
    /// payload itself. Its asset keeps the payload's file descriptor open
    /// once it has read the file: released at close, before the payload is
    /// deleted (`didFinishPlaying`).
    private var imageGenerator: AVAssetImageGenerator?
    internal var workItem: DispatchWorkItem?
    /// The targets this player added to the shared `MPRemoteCommandCenter`,
    /// with their command (`addRemoteCommandCenterHandlers`): removed at
    /// close.
    var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    /// The resume seek to `startPosition` is due: the hand-off continues
    /// there, or the user chose « Resume Playing ». Issued once the input is
    /// seekable (`applyStartPositionIfNeeded`).
    private var resumePlayback = false
    /// This session's watched progress, under the iOS VLC player's rules
    /// (`VLCWatchProgress`) — set up in `viewDidLoad`, once `startPosition`
    /// and `media` are known.
    private var watchProgress = VLCWatchProgress(startPosition: 0, resumePoint: 0)
    /// « Start from the beginning » of the slow-resume offer was chosen and
    /// playback from 0:00 has not yet run long enough for the saved resume
    /// point to stop being protected (`VLCSlowResumeRestart`).
    private var restartAwaitsConfirmation = false
    /// The new input's clock since that restart (`VLCSlowResumeRestart.Confirmation`).
    private var restartConfirmation = VLCSlowResumeRestart.Confirmation()
    /// When the position was last saved during playback (every 30 s).
    private var progressCheckpoint = PlaybackCheckpoint()
    /// VLCKit posted a time tick: libvlc has reported a time point, so
    /// `position` is real from now on. Before the first one it reads 0.0
    /// (no time point yet), even while `.playing`.
    private var didReceiveTimeTick = false
    /// The first time tick's setup (remote commands, Now Playing…) is done.
    private var didSetUpAtFirstTick = false
    /// A resume on its way (`beginResumeWait` … `endResumeWait`): from
    /// `play()` until VLC's clock runs at the resume point. The spinner and
    /// « Resuming at … » stay up meanwhile (`resumeOverlay`), with the offer
    /// 30 s in (`resumeOffer`). nil: no resume, or it arrived.
    private var resumeWait: VLCResumeWait?
    private var resumeWaitTimer: Timer?
    private weak var resumeOverlay: VLCResumeOverlayView?
    private weak var resumeOffer: VLCResumeOfferController?
    /// When « Start from the beginning » opened the media again
    /// (`restartFromBeginning`): VLC's `.stopped` for the input it left is
    /// not the end of playback for `reopenGrace`.
    private var reopenedAt: Date?
    private static let reopenGrace: TimeInterval = 5
    /// The player is closing (`didFinishPlaying`): its final save is done.
    private(set) var isClosing = false
    /// Runs once the player is dismissed (« Lighter version »: the next stream).
    private var afterClose: (() -> Void)?
    /// The deficit offer (`BandwidthDeficitMonitor`) and its toast.
    private var deficitSubscription: AnyCancellable?
    private weak var deficitToast: BandwidthDeficitToastController?
    internal var streamDuration: Float {
        guard let remaining = (mediaplayer.remainingTime ?? VLCTime(int: 0)).value?.floatValue, let elapsed = mediaplayer.time.value?.floatValue else {
            return imageGenerator.map { Float(CMTimeGetSeconds($0.asset.duration) * 1000) } ?? 0
        }
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
        // A switch to a lighter release whose first player is VLC: the user
        // chose where to resume — no question (taken once per stream).
        if let decided = PlaybackStreamContext.of(streamer)?.takeDecidedStart() {
            self.startPosition = ResumePolicy.handOffFraction(reached: decided)
            resumesWithoutPrompt = true
        }
        self.nextEpisode = nextEpisode
        self.directory = directory
        self.imageGenerator = AVAssetImageGenerator(asset: AVAsset(url: local))
        self.streamer = streamer
#if os(tvOS)
        if let session = upNextLink?.attach(self, streamer: streamer) {
            upNextSession = session
            upNextCardSubscription = session.$card.receive(on: DispatchQueue.main).sink { [weak self] card in
                self?.reconcileUpNextCard(card)
            }
        }
#endif
        // The OpenSubtitles search runs alongside the stream (`SubtitleSearch`):
        // a list that is not in yet joins the options panel when it comes.
        if media.subtitles.isEmpty {
            SubtitleSearch.shared.search(for: media) { [weak self] found in
                self?.attachLateSubtitles(found)
            }
        }
    }

    /// The OpenSubtitles list arrived after the player was set up: it is
    /// offered from now on (the options panel reads `subtitles` when it
    /// opens), and the preferred language is applied when the automatic
    /// choice was already made without it and nothing else is on.
    private func attachLateSubtitles(_ found: [Subtitle]) {
        guard !found.isEmpty, !isClosing, media != nil, media.subtitles.isEmpty else { return }
        media.subtitles = found
        print("[Player] subtitles: \(found.count) OpenSubtitles language(s) arrived after the player started")
        subtitleSwitcherButton?.isHidden = false
        subtitleSwitcherButtonWidthConstraint?.constant = 24
        guard didAutoSelectSubtitle, !userChoseSubtitle, currentSubtitle == nil, selectedEmbeddedTrackId == nil,
              let code = PlaybackLanguagePreferences.preferredSubtitleLanguageCode,
              let subtitle = ExternalSubtitleLoader.preferredSubtitle(in: found, code: code) else { return }
        print("[Player] auto-selecting OpenSubtitles '\(subtitle.language)' for '\(code)'")
        currentSubtitle = subtitle
    }
    
    // MARK: - Options view controller delegate
    
    func didSelectSubtitle(_ subtitle: Subtitle?) {
        userChoseSubtitle = true
        selectedEmbeddedTrackId = nil
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
        let tracks = mediaplayer.audioTracks
        guard !tracks.isEmpty else { return } // not known yet — retried on the next tick
        didAutoSelectAudioTrack = true
        guard tracks.count > 1, let code = PlaybackLanguagePreferences.preferredAudioLanguageCode else { return }

        // Same matching as the iOS / macOS players: the container's language
        // code first, then the free-form track name; commentary and audio
        // description tracks are avoided.
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

    
    func didSelectSubtitleDelay(_ delay: Int) {
        mediaplayer.currentVideoSubTitleDelay = Int(1e6) * delay
    }
    
    func didSelectEncoding(_ encoding: String) {
        mediaplayer.media?.addOptions([vlcSettingTextEncoding: encoding])
    }
    
    func screenshotAtTime(_ time: NSNumber) -> UIImage? {
        guard let image = try? imageGenerator?.copyCGImage(at: CMTimeMakeWithSeconds(time.doubleValue/1000.0, preferredTimescale: 1000), actualTime: nil) else { return nil }
        return UIImage(cgImage: image)
    }
    
    // MARK: - VLC's demuxer (a stream, both storage modes)

    /// The demuxer options `mediaplayer.media` was made with
    /// (`BoundedStorageUX.vlcMediaOptions`).
    private var boundedDemuxerOptions: [String] = []

    /// `url`'s VLC media for a start at `position` (0…1), with the Matroska
    /// demuxer that start needs (`BoundedStorageUX.vlcMediaOptions`, full
    /// and bounded storage alike) — added BEFORE the player gets the media:
    /// VLCKit 4 opens the input when `mediaplayer.media` is set and ignores
    /// the options added later (measured with 4.0.0a21: ":demux=avformat"
    /// added after the assignment left VLC on its own demuxer).
    private func makeVLCMedia(startingAt position: Float) -> VLCMedia? {
        let vlcMedia = VLCMedia(url: url)
        boundedDemuxerOptions = BoundedStorageUX.vlcMediaOptions(url: url, session: boundedStorage,
                                                                 startPosition: position, streamer: streamer)
        for option in boundedDemuxerOptions { vlcMedia?.addOption(option) }
        return vlcMedia
    }

    /// The resume prompt chose another start than `startPosition`: a new
    /// media when that start gets another demuxer (before `play()`) — in
    /// full storage too, where « Start from Beginning » would otherwise keep
    /// the resume point's libavformat demuxer and lose the file's text
    /// subtitles for nothing. The options the old one got after the
    /// assignment are added again, as they were.
    private func remakeVLCMediaIfNeeded(startingAt position: Float) {
        guard mediaplayer.state == .stopped || mediaplayer.state == .opening else { return }
        let previous = boundedDemuxerOptions
        guard let vlcMedia = makeVLCMedia(startingAt: position), boundedDemuxerOptions != previous else {
            boundedDemuxerOptions = previous
            return
        }
        retireCurrentVLCMedia()
        mediaplayer.media = vlcMedia
        mediaplayer.media?.addOptions(Self.vlcTuningOptions)
        mediaplayer.media?.addOptions([vlcSettingTextEncoding: SubtitleSettings.shared.encoding])
    }

    /// The media this player replaced (`retireCurrentVLCMedia`), kept alive
    /// for as long as the player and a while after (`deinit`).
    private var retiredVLCMedia: [VLCMedia] = []

    /// Keeps the current media alive before the player gets another one.
    /// VLCKit 4.0.0a21 posts the player's events to the main queue with the
    /// libvlc media as a bare pointer, without retaining it
    /// (`HandleMediaPlayerMediaMetaChanged`: its block reads the pointer
    /// later, `libvlc_media_get_user_data` then `+[VLCMedia
    /// mediaWithLibVLCMediaDescriptor:]` → `libvlc_media_retain`). Replaced,
    /// the old `VLCMedia` is released at once and frees that media, while
    /// the input VLC is still stopping (`stop()` is asynchronous) can have
    /// a « meta changed » for it in the queue: a use after free
    /// (EXC_BAD_ACCESS in `input_item_Hold`, seen once in five « Start from
    /// the beginning »). Kept, the pointer stays valid and the late event
    /// finds its own `VLCMedia` (harmless `metaChanged`).
    private func retireCurrentVLCMedia() {
        if let current = mediaplayer.media { retiredVLCMedia.append(current) }
    }

    deinit {
        // Still alive for late events of an input stopping as the player
        // goes (dispatched to the main queue before this release).
        let retired = retiredVLCMedia
        guard !retired.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { withExtendedLifetime(retired) {} }
    }

    /// The caching / frame-drop options `viewDidLoad` adds to the media.
    static let vlcTuningOptions: [String: Any] = [
        "network-caching": NSNumber(value: 5000),
        "file-caching":    NSNumber(value: 5000),
        "live-caching":    NSNumber(value: 5000),
        "drop-late-frames": NSNumber(value: 0),
        "skip-frames":      NSNumber(value: 0),
    ]

    // MARK: - View Methods
    
    /// Set when VLC takes over from the native (AVPlayer) player: the user has
    /// either already chosen to resume there, or was watching when the native
    /// path failed — continue at `startPosition` without asking again.
    var resumesWithoutPrompt = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard mediaplayer.state == .stopped || mediaplayer.state == .opening else { return }
        // A start at 0 or at the very end (a finished title) plays from the
        // beginning, without asking (`VLCWatchProgress.seeksAtStart`).
        let seeksAtStart = VLCWatchProgress.seeksAtStart(startPosition)
        if seeksAtStart && resumesWithoutPrompt {
            resumePlayback = true
            beginResumeWait()
            mediaplayer.play()
        } else if seeksAtStart {
            let isRegular = traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular
            let style: UIAlertController.Style = isRegular ? .alert : .actionSheet
            // VLC's own question: a file the native player does not play
            // (DTS / TrueHD-only audio, AVI, TS…) — it says so.
            let continueWatchingAlert = UIAlertController(title: nil, message: VLCResumeText.questionMessage, preferredStyle: style)
            
#if os(tvOS)
                NotificationCenter.default.addObserver(self, selector: #selector(alertFocusDidChange(_:)), name: .UIViewControllerFocusedViewDidChange, object: continueWatchingAlert)
#endif
            
            self.loadingActivityIndicatorView.isHidden = true
            
            
            let shownAt = VLCResumeWait.clock
            continueWatchingAlert.addAction(UIAlertAction(title: "Resume Playing".localized, style: .default, handler:{ action in
                UIDevice.current.userInterfaceIdiom == .tv ? NotificationCenter.default.removeObserver(self, name: .UIViewControllerFocusedViewDidChange, object: continueWatchingAlert) : ()
                self.answerResumeQuestion(resume: true, shownAt: shownAt)
            }))
            continueWatchingAlert.addAction(UIAlertAction(title: "Start from Beginning".localized, style: .default, handler: { action in
                UIDevice.current.userInterfaceIdiom == .tv ? NotificationCenter.default.removeObserver(self, name: .UIViewControllerFocusedViewDidChange, object: continueWatchingAlert) : ()
                self.answerResumeQuestion(resume: false, shownAt: shownAt)
            }))
            continueWatchingAlert.popoverPresentationController?.sourceView = progressBar
            present(continueWatchingAlert, animated: true)
            print("[Resume] VLC: question shown — saved \(Int(startPosition * 100)) %, this file plays with VLC")
            #if DEBUG
            // `-PTDebugResumeAnswer resume|start` (BoundedStorageDebugHooks):
            // the question answers itself as its buttons do,
            // `-PTDebugResumeAnswerAfter` seconds later — the simulator has no
            // remote to press them (end-to-end runs).
            if let answer = BoundedStorageDebugHooks.resumeAnswer {
                DispatchQueue.main.asyncAfter(deadline: .now() + answer.after) { [weak self, weak continueWatchingAlert] in
                    guard let self = self, let alert = continueWatchingAlert, alert.presentingViewController != nil else { return }
                    print("[BoundedDebug] VLC's resume question answered by the script: \(answer.resume ? "resume" : "start")")
                    NotificationCenter.default.removeObserver(self, name: .UIViewControllerFocusedViewDidChange, object: alert)
                    alert.dismiss(animated: true) { self.answerResumeQuestion(resume: answer.resume, shownAt: shownAt) }
                }
            }
            #endif
        } else {
            mediaplayer.play()
        }
    }

    /// The answer to VLC's own resume question (`shownAt`: when it came up,
    /// `VLCResumeWait.clock`): « Resume Playing » at `startPosition`, under
    /// the resume state, or « Start from Beginning ».
    private func answerResumeQuestion(resume: Bool, shownAt: TimeInterval) {
        let after = String(format: "%.1f", VLCResumeWait.clock - shownAt)
        if resume {
            print("[Resume] VLC: answer: resume (after \(after) s)")
            resumePlayback = true
            beginResumeWait()
        } else {
            print("[Resume] VLC: answer: from the beginning (after \(after) s)")
            // The demuxer picked for the resume point may not be the one
            // for a start at 0:00 (both storage modes).
            remakeVLCMediaIfNeeded(startingAt: 0)
            // The saved resume point is no longer protected: what VLC
            // plays from 0:00 is saved as is.
            watchProgress.restartFromBeginning()
            loadingActivityIndicatorView.isHidden = false
        }
        mediaplayer.play()
    }

    #if DEBUG
    /// Wall-clock time of a "[ResumeDebug]" line (the console has none).
    private static func debugClock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private var resumeTraceTimer: Timer?

    /// `-PTDebugResumeTrace 1`: VLC's state every second — what a resume
    /// really does (state, position, time, whether a tick came) next to
    /// what the transport bar shows; `-PTDebugKeepControls 1` keeps that bar
    /// on screen for the screenshots.
    private func startDebugResumeTrace() {
        guard UserDefaults.standard.object(forKey: "PTDebugResumeTrace") != nil else { return }
        let opened = Date()
        print("[ResumeDebug] \(Self.debugClock()) VLC player opened: startPosition=\(startPosition) resumesWithoutPrompt=\(resumesWithoutPrompt) options=\(boundedDemuxerOptions)")
        resumeTraceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self, !self.isClosing else { timer.invalidate(); return }
            let player = self.mediaplayer
            print(String(format: "[ResumeDebug] %@ vlc +%.0fs state=%ld playing=%ld seekable=%ld pos=%.4f time=%@ ms=%ld remaining=%@ tick=%ld resumeDue=%ld spinnerHidden=%ld wait=%@ overlay=%ld offer=%ld",
                         Self.debugClock(), Date().timeIntervalSince(opened), Int(player.state.rawValue),
                         player.isPlaying ? 1 : 0, player.isSeekable ? 1 : 0, player.position,
                         player.time.stringValue, Int(player.time.intValue),
                         (player.remainingTime ?? VLCTime(int: 0)).stringValue,
                         self.didReceiveTimeTick ? 1 : 0, self.resumePlayback ? 1 : 0,
                         self.loadingActivityIndicatorView.isHidden ? 1 : 0,
                         self.resumeWait.map { "\($0.phase)" + ($0.pausesAtArrival ? "+pause" : "") } ?? "-",
                         self.resumeOverlay?.superview != nil ? 1 : 0, self.resumeOffer?.presentingViewController != nil ? 1 : 0))
            guard UserDefaults.standard.bool(forKey: "PTDebugKeepControls") else { return }
            if self.presentedViewController == nil, let first = self.overlayViews.first, first.isHidden {
                self.toggleControlsVisible()
            }
            print(String(format: "[ResumeDebug] ui elapsed=%@ remaining=%@ progress=%.4f buffer=%.4f isBuffering=%ld",
                         self.progressBar.elapsedTimeLabel.text ?? "-", self.progressBar.remainingTimeLabel.text ?? "-",
                         self.progressBar.progress, self.progressBar.bufferProgress, self.progressBar.isBuffering ? 1 : 0))
        }
    }
    #endif
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // The protected point is what the title has saved NOW — its resume
        // point, or what the native player saved at its hand-off (made
        // before this player exists) — not `startPosition`.
        watchProgress = VLCWatchProgress(startPosition: startPosition,
                                         resumePoint: ResumePolicy.startPosition(forSavedProgress: Self.savedProgress(for: media)))
        // Home, then tvOS terminates the suspended app (or a crash later):
        // what was watched is kept.
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)

        mediaplayer.delegate = self
        mediaplayer.drawable = movieView
        mediaplayer.media = makeVLCMedia(startingAt: startPosition)
        #if DEBUG
        startDebugResumeTrace()
        #endif

        // Tune VLC for max-quality playback on Apple TV 4K. Larger cache windows
        // hide network jitter on 1080p/2160p streams that PopcornTorrent serves
        // over HTTP localhost while still downloading. Disable VLC's framedrop
        // on slow seeks so high-bitrate sources keep their picture quality.
        mediaplayer.media?.addOptions(Self.vlcTuningOptions)

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
        // Audio-pipeline lines only — a handful of lines per playback, not
        // libvlc's full debug flood.
        mediaplayer.libraryInstance.loggers = [VLCAudioLogFilter()]
#else
        // libvlc's errors only, not its default output (clock drift, late
        // pictures, buffering: hundreds of lines a minute).
        let console = VLCConsoleLogger()
        console.level = .error
        mediaplayer.libraryInstance.loggers = [console]
#endif
#endif

        NotificationCenter.default.addObserver(self, selector: #selector(torrentStatusDidChange(_:)), name: .PTTorrentStatusDidChange, object: streamer)
        attachDeficitMonitor()
        // Bounded storage (a film larger than the free space): VLC reads
        // through PopcornTorrent's server, which moves the window; its
        // playhead tells the torrent what it may delete behind it.
        BoundedStorageSession.session(for: streamer)?.attachHTTPPlayer(self, readAheadSeconds: 10) { [weak self] in
            // Nothing while a resume is on its way: VLC's clock then shows
            // 0:00 or the target without playing there.
            guard let self = self, !self.isClosing, self.didReceiveTimeTick, self.resumeWait == nil,
                  let milliseconds = self.mediaplayer.time.value?.doubleValue else { return nil }
            return BoundedPlayerSample(time: milliseconds / 1000, isPlaying: self.mediaplayer.isPlaying)
        }
#if DEBUG
        // BoundedStorageDebugHooks' scripted seeks and pauses.
        NotificationCenter.default.addObserver(self, selector: #selector(debugScriptSeek(_:)), name: .ptDebugSeek, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(debugScriptPlayback(_:)), name: .ptDebugPlayback, object: nil)
#endif
        
        let settings = SubtitleSettings.shared
        // These are private libvlc text-renderer selectors that may not exist
        // in VLCKit 4's rewritten core. Call them optionally (`?`) so a missing
        // selector no-ops instead of crashing (force-unwrap would trap). The
        // font *scale* has a public 4.x replacement, so drive that too.
        (mediaplayer as VLCFontAppearance).setTextRendererFontSize?(NSNumber(value: settings.size.rawValue))
        (mediaplayer as VLCFontAppearance).setTextRendererFontColor?(NSNumber(value: settings.color.hexInt()))
        (mediaplayer as VLCFontAppearance).setTextRendererFont?(settings.font.fontName as NSString)
        (mediaplayer as VLCFontAppearance).setTextRendererFontForceBold?(NSNumber(booleanLiteral: settings.style == .bold || settings.style == .boldItalic))
        // The preferred subtitle language is applied once VLC lists the
        // file's own tracks (`autoSelectSubtitleIfNeeded`).
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
    
#if DEBUG
    /// `-PTDebugSeek` (BoundedStorageDebugHooks): VLC to that time, limited
    /// like a user's seek (bounded storage).
    @objc private func debugScriptSeek(_ note: Notification) {
        guard !isClosing, let seconds = note.userInfo?["seconds"] as? Double else { return }
        print("[BoundedDebug] VLC seek → \(Int(seconds)) s")
        seekLimited(toMilliseconds: NSNumber(value: Int32(clamping: Int64(seconds * 1000))))
    }

    /// `-PTDebugPause` (BoundedStorageDebugHooks).
    @objc private func debugScriptPlayback(_ note: Notification) {
        guard !isClosing, let playing = note.userInfo?["playing"] as? Bool else { return }
        // A resume on its way: as the remote's Play/Pause, kept for the arrival.
        if let wait = resumeWait {
            if wait.pausesAtArrival == playing { playandPause() }
            return
        }
        if playing { mediaplayer.play() } else { mediaplayer.pause() }
    }
#endif

    // MARK: - Player changes notifications
    
    @objc func torrentStatusDidChange(_ aNotification: Notification) {
        if let streamer = aNotification.object as? PTTorrentStreamer {
            progressBar?.bufferProgress = streamer.torrentStatus.totalProgress
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // A tick delivered after close would register the remote handlers
        // and the Now Playing info again.
        guard !isClosing else { return }
        // The first tick's setup — no longer tied to the spinner: a resume
        // keeps its own state up until playback runs at the target, long
        // after VLC's first time point (which it reports at 0:00).
        loadingActivityIndicatorView.isHidden = true
        if !didSetUpAtFirstTick {
            didSetUpAtFirstTick = true

            addRemoteCommandCenterHandlers()
            beginReceivingScreenNotifications()
            configureNowPlayingInfo()
            autoSelectAudioTrackIfNeeded()

            resetIdleTimer()
        }
        
        didReceiveTimeTick = true
        applyStartPositionIfNeeded()
        notePlayerPosition() // after the resume seek was issued
        checkpointProgressIfDue()
        // Not while a resume is on its way: VLC's clock then shows 0:00 or
        // the target without playing there — bounded storage would take a
        // step between them for a rewind (a forced seek, and « This part
        // hasn't been downloaded », for nothing).
        if resumeWait == nil { checkBoundedPlayhead() }
        
        playPauseButton?.setImage(UIImage(named: "Pause"), for: .normal)
        
        progressBar.isBuffering = resumeWait != nil
        
        if resumeWait != nil {
            showResumeTargetOnBar() // not VLC's clock: 0:00 before its seek lands
        } else {
            progressBar.remainingTimeLabel.text = (mediaplayer.remainingTime ?? VLCTime(int: 0)).stringValue
            progressBar.elapsedTimeLabel.text = mediaplayer.time.stringValue
            progressBar.progress = Float(mediaplayer.position) // VLCKit 4: position is Double
        }
        autoSelectSubtitleIfNeeded() // one-shot; waits until VLC has listed the file's tracks
        applyPendingSubtitle() // no-op unless a downloaded subtitle still waits for `.playing`
        selectSlaveTextTrackIfNeeded()
        autoSelectAudioTrackIfNeeded() // one-shot; waits until VLC has listed the tracks
        
#if os(tvOS)
        if upNextSession != nil {
            if resumeWait == nil { upNextTick(isPlaying: true) }
            return
        }
#endif
        if nextEpisode != nil && ((mediaplayer.remainingTime ?? VLCTime(int: 0)).intValue/1000) == -31 && presentedViewController == nil {
            performSegue(withIdentifier: "showUpNext", sender: nil)
        } else if ((mediaplayer.remainingTime ?? VLCTime(int: 0)).intValue/1000) < -31, let vc = presentedViewController as? UpNextViewController {
            vc.dismiss(animated: true)
        }
    }
    
    /// VLCKit 4 (4.0.0a21) passes the new STATE here, not a Notification as
    /// VLCKit 3 did. The old `(_ aNotification: Notification)` signature only
    /// "nearly matched" the optional protocol requirement, so it was never
    /// called: the subtitle re-apply on `.playing`, the passthrough
    /// re-assertion, paused/finished progress and close-at-end never ran.
    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        resetIdleTimer()
        progressBar.isBuffering = resumeWait != nil
        nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = (mediaplayer.time.value?.doubleValue ?? 0)/1000
        // VLCKit 4 collapsed the state enum: `.ended`/`.buffering`/`.esAdded`
        // are gone. End-of-file and manual stop both surface as `.stopped`;
        // buffering is no longer a player state (the torrent streamer drives
        // the buffering UI via torrentStatusDidChange). `didFinishPlaying()`
        // clears the delegate before stopping, so our own stop can't re-enter.
        switch newState {
        case .error, .stopped:
            // « Start from the beginning » just opened the media again
            // (`restartFromBeginning`): this `.stopped` is the input it
            // left. VLC is asked to play once more — nothing if it already
            // plays the new one.
            if newState == .stopped, let reopened = reopenedAt, Date().timeIntervalSince(reopened) < Self.reopenGrace {
                mediaplayer.play()
                return
            }
#if os(tvOS)
            // Episode chaining: the end of the file goes to the session
            // (after-play card, the countdown's start, or the close).
            if newState == .stopped, upNextFileEnded() { return }
#endif
            // Saves (`.finished`: at the end of the file the last tick
            // reported 1.0), then closes.
            didFinishPlaying()
        case .paused:
            checkpointProgress()
#if os(tvOS)
            upNextTick(isPlaying: false)
#endif
            playPauseButton?.setImage(UIImage(named: "Play"), for: .normal)
            nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        case .playing:
            playPauseButton?.setImage(UIImage(named: "Pause"), for: .normal)
            // Trakt « start » on resuming from a pause. The first `.playing`
            // comes before any time tick: nothing is saved then
            // (`setProgress`), so the stored resume point stays.
            setProgress(status: .watching)
            nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = Double(mediaplayer.rate)
            // The file's tracks are known now: the preferred subtitles (the
            // file's own track wins over OpenSubtitles), then the slave.
            autoSelectSubtitleIfNeeded()
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
        // Weak: a closed player is released, possibly before the item runs.
        idleWorkItem = DispatchWorkItem() { [weak self] in
            guard let self = self else { return }
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
    
    // MARK: - Bounded storage: rewinds

    /// The stream's bounded storage (nil: a download). Its `isBounded` is
    /// false in full mode: every seek below is then the plain one.
    private var boundedStorage: BoundedStorageSession? { BoundedStorageSession.session(for: streamer) }

    /// VLC's playhead in seconds; nil before its first time point.
    private var playheadSeconds: Double? {
        guard didReceiveTimeTick, let milliseconds = mediaplayer.time.value?.doubleValue else { return nil }
        return milliseconds / 1000
    }

    /// VLC's time at the time ticks (`checkBoundedPlayhead`); seeks made
    /// here are noted in it (`noteOwnSeek`).
    var playheadWatch = VLCPlayheadWatch()

    /// Bounded storage: where a seek to `seconds` goes — the earliest point
    /// still available when it is further back than what is still on disk
    /// (the user's decision: no new download, no rewind into deleted data),
    /// with the message; `seconds` otherwise (forward, within what is kept,
    /// full mode).
    private func limitedSeekSeconds(_ seconds: Double) -> Double {
        guard let now = playheadSeconds,
              let landing = BoundedStorageUX.limitedRewindTarget(seconds, from: now, session: boundedStorage) else { return seconds }
        BoundedStorageUX.logLimited(player: "VLC", target: seconds, playhead: now, landing: landing, session: boundedStorage)
        BoundedStorageToastView.show(BoundedStorageUX.rewindLimitedMessage(for: boundedStorage), in: view)
        return landing
    }

    /// `mediaplayer.time =` a scrub's or a remote command's target
    /// (milliseconds, as `streamDuration`), limited by bounded storage —
    /// the very same value when nothing limits it (full mode). Returns the
    /// milliseconds VLC is sent to.
    @discardableResult
    func seekLimited(toMilliseconds milliseconds: NSNumber) -> NSNumber {
        // A resume on its way: VLC is already seeking; another seek would
        // start from a clock that shows 0:00 or the target without playing.
        guard resumeWait == nil else { return milliseconds }
        let wanted = milliseconds.doubleValue / 1000
        let seconds = limitedSeekSeconds(wanted)
        let target = seconds == wanted ? milliseconds : NSNumber(value: seconds * 1000)
        playheadWatch.noteOwnSeek()
        mediaplayer.time = VLCTime(number: target)
        return target
    }

    /// `jumpBackward(interval)` (±30 s, remote commands), limited by bounded
    /// storage: stopped at the earliest point still available.
    func jumpBackwardLimited(_ interval: Double) {
        guard resumeWait == nil else { return } // as `seekLimited`
        if let now = playheadSeconds, boundedStorage?.isBounded == true {
            let landing = limitedSeekSeconds(max(0, now - interval))
            if landing != max(0, now - interval) {
                if landing < now {
                    playheadWatch.noteOwnSeek()
                    mediaplayer.time = VLCTime(number: NSNumber(value: Float(landing * 1000)))
                }
                return
            }
        }
        playheadWatch.noteOwnSeek()
        mediaplayer.jumpBackward(interval)
    }

    /// Bounded storage, every time tick: VLC's time went back past what is
    /// still on disk by a path not limited above (its rewind at a rate) —
    /// back to the earliest point still available, with the message. VLC
    /// settling after a start or seek is not a rewind (`VLCPlayheadWatch`).
    private func checkBoundedPlayhead() {
        guard let now = playheadSeconds, let previous = playheadWatch.rewind(to: now),
              let landing = BoundedStorageUX.limitedRewindTarget(now, from: previous, session: boundedStorage) else { return }
        BoundedStorageUX.logLimited(player: "VLC (time tick)", target: now, playhead: previous, landing: landing,
                                    session: boundedStorage)
        if mediaplayer.rate != 1 { mediaplayer.rate = 1 }
        playheadWatch.noteOwnSeek()
        mediaplayer.time = VLCTime(number: NSNumber(value: Float(landing * 1000)))
        BoundedStorageToastView.show(BoundedStorageUX.rewindLimitedMessage(for: boundedStorage), in: view)
    }

    // MARK: - Download slower than the release (BandwidthDeficitMonitor)

    /// The stream's deficit watch hears from VLC once a second (a stall is
    /// inferred from a time that does not move while VLC plays: VLCKit 4
    /// has no buffering state); its offer shows as a toast over the video.
    private func attachDeficitMonitor() {
        guard let monitor = PlaybackStreamContext.of(streamer)?.deficit else { return }
        monitor.attach(self, switchTo: { [weak self] torrent, fraction in
            self?.leave(for: torrent, at: fraction)
        }, state: { [weak self] in
            guard let self = self, !self.isClosing else { return nil }
            let milliseconds = self.mediaplayer.time.value?.doubleValue ?? 0
            let duration = Double(self.streamDuration) / 1000
            return BandwidthDeficitMonitor.PlaybackState(playhead: milliseconds > 0 ? milliseconds / 1000 : nil,
                                                         duration: duration > 0 ? duration : nil,
                                                         // Not during a resume's wait: a clock that
                                                         // does not move there is no stall of a film
                                                         // that played (no « lighter version » offer).
                                                         hasStarted: self.didReceiveTimeTick && self.resumeWait == nil,
                                                         wantsPlayback: self.mediaplayer.state == .playing,
                                                         isStalled: nil)
        })
        deficitSubscription = monitor.$offer.receive(on: DispatchQueue.main).sink { [weak self] offer in
            self?.showDeficitOffer(offer)
        }
    }

    /// The offer as a toast at the top of the video (the toast takes the
    /// remote while it shows; the video plays on). Not over another panel
    /// (options, Up Next): it times out then, and may come back later.
    private func showDeficitOffer(_ offer: BandwidthDeficitMonitor.Offer?) {
        if let toast = deficitToast, toast.offerID != offer?.id {
            deficitToast = nil
            if toast.presentingViewController != nil, !toast.isBeingDismissed { toast.dismiss(animated: true) }
        }
        guard let offer = offer, !isClosing, deficitToast == nil, presentedViewController == nil,
              let monitor = PlaybackStreamContext.of(streamer)?.deficit else { return }
        let toast = BandwidthDeficitToastController(offer: offer,
                                                    onLighter: { [weak monitor] in monitor?.acceptLighter() },
                                                    onContinue: { [weak monitor] in monitor?.continueWatching() },
                                                    // Play/Pause still reaches VLC under the toast.
                                                    onPlayPause: { [weak self] in self?.playandPause() })
        deficitToast = toast
        present(toast, animated: true)
    }

    /// « Lighter version »: this player closes like Menu does (progress
    /// saved, stream cancelled), then the app plays `torrent` from
    /// `fraction` (`PlaybackStreamContext.onSwitch`).
    private func leave(for torrent: Torrent, at fraction: Float) {
        guard !isClosing, let context = PlaybackStreamContext.of(streamer) else { return }
        print("[Player] VLC: leaving for a lighter release (\(torrent.quality ?? "?")) at \(Int(fraction * 100)) %")
        let close = { [weak self] in
            guard let self = self else { return }
            self.afterClose = { context.onSwitch?(torrent, fraction) }
            self.didFinishPlaying()
        }
        if let presented = presentedViewController {
            deficitToast = nil
            presented.dismiss(animated: false, completion: close)
        } else {
            close()
        }
    }

    // MARK: - Watched progress

    /// Seeks to `startPosition` once the input is seekable, when the resume
    /// is due (`resumePlayback`) — by POSITION, as the iOS VLC player does,
    /// never by `startPosition × streamDuration`: at VLCKit 4's first time
    /// tick `remainingTime` is often still nil (libvlc has only reported its
    /// time point at position 0.0), and `streamDuration` then falls back to
    /// AVAsset's duration of the payload, 0 for a Matroska file — the seek
    /// went to 0:00 and was never retried. libvlc maps a position with the
    /// demuxer's own duration (measured on 4.0.0a21: lands at the target).
    private func applyStartPositionIfNeeded() {
        guard resumePlayback, mediaplayer.isSeekable else { return }
        resumePlayback = false // before the seek: a seek can post a nested time tick (seen with `time =`)
        playheadWatch.noteOwnSeek()
        mediaplayer.position = Double(startPosition)
        print("[Player] resuming at \(Int(startPosition * 100)) %")
        resumeWait?.seekIssued(now: VLCResumeWait.clock)
    }

    // MARK: - Resume: a visible state until playback runs at the target

    /// A resume is on its way (the tvOS extension's remote handling).
    var isWaitingForResume: Bool { resumeWait != nil }

    /// The film's length as VLC reports it, in seconds; nil until it does
    /// (never `streamDuration`'s fallback, which reads the payload).
    private var vlcDurationSeconds: Double? {
        if let length = mediaplayer.media?.length.value?.doubleValue, length > 0 { return length / 1000 }
        guard didReceiveTimeTick, let remaining = mediaplayer.remainingTime?.value?.doubleValue,
              let elapsed = mediaplayer.time.value?.doubleValue else { return nil }
        let total = abs(remaining) + elapsed
        return total > 0 ? total / 1000 : nil
    }

    /// A resume starts (just before `play()`): the dimmed picture, the
    /// spinner and « Resuming at … » stay up until VLC's clock runs at
    /// `startPosition` (`VLCResumeWatch`), sampled once a second — VLC's own
    /// time ticks stop while it waits for data. VLC's state says nothing:
    /// `.playing` and `isPlaying` from `play()` on, its clock at 0:00 or at
    /// the target, frozen.
    private func beginResumeWait() {
        guard resumeWait == nil, !isClosing else { return }
        let wait = VLCResumeWait(fraction: startPosition, durationSeconds: vlcDurationSeconds, now: VLCResumeWait.clock)
        resumeWait = wait
        loadingActivityIndicatorView.isHidden = true // the state has its own spinner, at the same place
        let overlay = VLCResumeOverlayView.install(in: view, above: movieView)
        overlay.text = wait.label
        resumeOverlay = overlay
        progressBar.isBuffering = true
        showResumeTargetOnBar()
        resumeWaitTimer?.invalidate()
        resumeWaitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.resumeWaitTick()
        }
    }

    /// Once a second while a resume is on its way.
    private func resumeWaitTick() {
        guard !isClosing, var wait = resumeWait else { return }
        let time = didReceiveTimeTick ? mediaplayer.time.value.map { $0.doubleValue / 1000 } : nil
        let phase = wait.sample(time: time, isPlaying: mediaplayer.isPlaying, durationSeconds: vlcDurationSeconds,
                                now: VLCResumeWait.clock)
        resumeWait = wait
        resumeOverlay?.text = wait.label // the clock time once VLC knows the film's length
        switch phase {
        case .waiting: break
        case .offer: showResumeOfferIfNeeded()
        case .arrived: endResumeWait()
        }
    }

    /// The transport bar during the wait: the resume point, not VLC's clock.
    private func showResumeTargetOnBar() {
        progressBar.progress = startPosition
        guard let duration = vlcDurationSeconds else { return }
        let target = Double(startPosition) * duration * 1000
        progressBar.elapsedTimeLabel.text = VLCTime(number: NSNumber(value: target)).stringValue
        progressBar.remainingTimeLabel.text = VLCTime(number: NSNumber(value: target - duration * 1000)).stringValue
    }

    /// Playback runs: the state goes away, and a Play/Pause pressed during
    /// the wait takes effect.
    private func endResumeWait() {
        guard let wait = resumeWait else { return }
        resumeWait = nil
        resumeWaitTimer?.invalidate()
        resumeWaitTimer = nil
        resumeOverlay?.dismiss()
        resumeOverlay = nil
        dismissResumeOffer()
        progressBar.isBuffering = false
        // Bounded storage's time-tick check starts from VLC's clock as it
        // runs now, not from what it showed during the wait.
        playheadWatch.noteOwnSeek()
        noteFirstFrameIfDue()
        if wait.pausesAtArrival, mediaplayer.canPause { mediaplayer.pause() }
        resetIdleTimer()
    }

    /// `VLCResumeWatch.offerDelay` into the wait: « Keep waiting » / « Start
    /// from the beginning », over the state (which stays up). Not over
    /// another panel (options): shown once that one closes.
    private func showResumeOfferIfNeeded() {
        guard resumeOffer == nil, !isClosing, presentedViewController == nil else { return }
        let fromStart: (() -> Void)? = canRestartFromBeginning ? { [weak self] in self?.restartFromBeginning() } : nil
        let offer = VLCResumeOfferController(onKeepWaiting: { [weak self] in self?.keepWaitingForResume() },
                                             onFromStart: fromStart,
                                             // Play/Pause still reaches the player under the card.
                                             onPlayPause: { [weak self] in self?.playandPause() })
        resumeOffer = offer
        present(offer, animated: true)
        #if DEBUG
        VLCResumeDebugHooks.offerShown(keepWaiting: { [weak self] in self?.keepWaitingForResume() }, fromStart: fromStart)
        #endif
    }

    private func dismissResumeOffer(completion: (() -> Void)? = nil) {
        guard let offer = resumeOffer, offer.presentingViewController != nil, !offer.isBeingDismissed else {
            resumeOffer = nil
            completion?()
            return
        }
        resumeOffer = nil
        offer.dismiss(animated: true, completion: completion)
    }

    /// « Keep waiting »: the offer comes back 30 s later.
    private func keepWaitingForResume() {
        guard resumeWait != nil else { return }
        resumeWait?.keepWaiting(now: VLCResumeWait.clock)
        dismissResumeOffer()
    }

    /// The film can start over: always in full storage; in bounded storage
    /// only while nothing was released (the head is still there to read).
    private var canRestartFromBeginning: Bool {
        guard boundedStorage?.isBounded == true else { return true }
        return streamer.lowestAvailableOffset == 0
    }

    /// « Start from the beginning » of the slow-resume offer: the media is
    /// opened again at 0:00, with the demuxer that start gets
    /// (`makeVLCMedia`). Not a seek: VLC's demuxer may be reading the file
    /// through to the resume point (no index), and takes no other seek
    /// until it is there. Unlike the question's « Start from Beginning », the
    /// saved resume point stays protected until playback from 0:00 has
    /// really run (`VLCSlowResumeRestart`): the app offered this exit after
    /// its own resume failed.
    private func restartFromBeginning() {
        guard !isClosing, let wait = resumeWait else { return }
        wait.logEnded("answer: start from the beginning — the media is opened again at 0:00,", now: VLCResumeWait.clock)
        resumeWait = nil
        resumeWaitTimer?.invalidate()
        resumeWaitTimer = nil
        resumeOverlay?.dismiss()
        resumeOverlay = nil
        progressBar.isBuffering = false
        resumePlayback = false
        watchProgress = VLCSlowResumeRestart.progress(restartingFrom: watchProgress)
        restartAwaitsConfirmation = true
        restartConfirmation = VLCSlowResumeRestart.Confirmation()
        dismissResumeOffer()

        // The new input: its tracks are not known yet, its first time tick
        // is to come (the loading spinner until then).
        didReceiveTimeTick = false
        didReachPlayingWithTracks = false
        didAutoSelectAudioTrack = false
        didReassertPassthrough = false
        endSlaveWait()
        attachedSlaveSubtitles = [:]
        pendingSubtitle = nil
        selectedEmbeddedTrackId = nil
        let chosen = userChoseSubtitle ? currentSubtitle : nil
        choiceFollowsScreen = true // the input is leaving: nothing to download or to turn off
        currentSubtitle = nil
        choiceFollowsScreen = false
        didAutoSelectSubtitle = userChoseSubtitle
        loadingActivityIndicatorView.isHidden = false
        progressBar.progress = 0

        reopenedAt = Date()
        retireCurrentVLCMedia()
        mediaplayer.stop()
        mediaplayer.media = makeVLCMedia(startingAt: 0)
        mediaplayer.media?.addOptions(Self.vlcTuningOptions)
        mediaplayer.media?.addOptions([vlcSettingTextEncoding: SubtitleSettings.shared.encoding])
        mediaplayer.play()
        // The OpenSubtitles file the user picked during the wait: attached
        // again once the new input plays.
        if let chosen = chosen { currentSubtitle = chosen }
    }

    /// The saved progress (0…1) of a movie / episode, 0 when none.
    private static func savedProgress(for media: Media?) -> Float {
        if let movie = media as? Movie { return WatchedlistManager<Movie>.movie.currentProgress(movie.id) }
        if let episode = media as? Episode { return WatchedlistManager<Episode>.episode.currentProgress(episode.id) }
        return 0
    }

    /// Samples VLC's position (time tick, pause, background, close) once
    /// VLC has reported a time point, while its input plays or is paused.
    private func notePlayerPosition() {
        guard !isClosing, didReceiveTimeTick, mediaplayer.state == .playing || mediaplayer.state == .paused else { return }
        watchProgress.note(position: mediaplayer.position)
        if restartAwaitsConfirmation, restartConfirmation.note(clockSeconds: playheadSeconds) {
            restartAwaitsConfirmation = false
            watchProgress.restartFromBeginning()
            print("[Resume] VLC: playback from 0:00 got past 3:00 after « Start from the beginning » — the restart is the user's, the resume point is no longer protected")
        }
    }

    /// ±30 s, end of a scrub: the position VLC reports from now on is the
    /// user's, even before the resume point. (A non-seekable input ignores
    /// them.)
    func noteUserMovedPlayhead() {
        // Not while a resume is on its way: a remote's skip then moves a
        // clock at 0:00 or at the target, not a position the user watched —
        // the saved resume point stays protected.
        guard mediaplayer.isSeekable, resumeWait == nil else { return }
        watchProgress.userMovedPlayhead()
    }

    /// Pause / background: saves the position reached so far, so a kill or
    /// a crash afterwards doesn't lose it.
    private func checkpointProgress() {
        guard !isClosing else { return }
        notePlayerPosition()
        setProgress(status: .paused)
    }

    /// tvOS suspends the app in the background (no background mode) and may
    /// terminate it there.
    @objc private func applicationDidEnterBackground() {
        checkpointProgress()
    }

    /// From the time tick: the position every 30 s of playback
    /// (`PlaybackCheckpoint`), so a crash, a kill or a power cut loses half a
    /// minute of an uninterrupted session, not all of it.
    private func checkpointProgressIfDue() {
        guard progressCheckpoint.isDue() else { return }
        setProgress(status: .watching)
    }

    /// Watched progress (local + Trakt scrobble, watched mark from 80 %),
    /// under the native players' rules through `VLCWatchProgress`: the saved
    /// resume point — or the native player's save at its hand-off — is never
    /// replaced by a smaller fraction unless VLC played past it or the user
    /// chose « Start from Beginning »; until the resume seek lands the
    /// position is at least `startPosition`. Nothing is saved before VLC has
    /// reported a real position (its first time tick): until then the store
    /// still holds what the title had when this player opened — a `.playing`
    /// or `.error` at open, a kill or a close in the first second never
    /// replace it. And a 0 is never written: WatchedlistManager deletes the
    /// entry for it (and Trakt its playback progress), while VLC at 0:00 has
    /// nothing to add.
    func setProgress(status: Trakt.WatchedStatus) {
        guard let media = media, watchProgress.lastPosition != nil else { return }
        guard let value = watchProgress.progressToSave(), value > 0 else {
            if let current = watchProgress.current, current > 0 {
                print("[Player] progress \(Int(current * 100)) % not saved — keeps the resume point at \(Int(watchProgress.resumePoint * 100)) %")
            }
            return
        }
        // With the titles and the length: the Continue Watching card.
        PlaybackRecorder.save(value, of: media, duration: streamDuration > 0 ? Double(streamDuration) / 1000 : nil, status: status)
    }
    
    // MARK: UpNextViewControllerDelegate
    
    func viewController(_ viewController: UpNextViewController, proceedToNextVideo proceed: Bool) {
        // Weak: the player may have closed and been released meanwhile.
        let completion: (() -> Void) = { [weak self] in
            guard let self = self else { return }
            if proceed, let next = self.nextEpisode {
                self.didFinishPlaying()
                self.delegate?.playNext(next)
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
    
#if os(tvOS)
    // MARK: - Episode chaining (5.3.0): the session drives the card

    /// From VLC's time ticks (and a pause): where the file is, to the session.
    private func upNextTick(isPlaying: Bool) {
        guard let session = upNextSession, !isClosing, didReceiveTimeTick else { return }
        let position = (mediaplayer.time.value?.doubleValue ?? 0) / 1000
        let duration = streamDuration > 0 ? Double(streamDuration) / 1000 : nil
        guard position.isFinite, position >= 0 else { return }
        upNextLastPosition = position
        if let duration = duration { upNextLastDuration = duration }
        session.tick(position: position, duration: duration, isPlaying: isPlaying)
        #if DEBUG
        debugOpenOptionsIfAsked(position: position, duration: duration)
        #endif
        reconcileUpNextCard(session.card)
    }

    #if DEBUG
    /// `-PTDebugOpenOptionsAtRemaining <s>` (bench): the subtitles / audio
    /// panel opens once, that many seconds before the end — as a swipe down
    /// would — and stays: the next episode must still take the whole stack
    /// down (`didFinishPlaying`).
    private func debugOpenOptionsIfAsked(position: Double, duration: Double?) {
        guard !debugOpenedOptions, let duration,
              let remaining = UserDefaults.standard.string(forKey: "PTDebugOpenOptionsAtRemaining").flatMap(Double.init),
              duration - position <= remaining else { return }
        debugOpenedOptions = true
        print("[UpNextDebug] the options panel opens \(Int(duration - position)) s before the end")
        presentOptionsViewController()
    }
    #endif

    /// VLC stopped: at the end of the file (the last position within 3 s
    /// of the length, or VLC's own position at 98 %) the session takes the
    /// end over — true: this player stays, with the card. Else (an error,
    /// a stop elsewhere): false, the player closes as before.
    private func upNextFileEnded() -> Bool {
        guard let session = upNextSession, !isClosing else { return false }
        let nearEnd = upNextLastDuration.map { upNextLastPosition >= $0 - 3 } ?? false
        guard nearEnd || mediaplayer.position >= 0.98 else { return false }
        print("[UpNext] VLC player: end of the file at \(Int(upNextLastPosition)) s")
        // The position the close would save: the end.
        notePlayerPosition()
        guard session.itemEnded() else { return false }
        reconcileUpNextCard(session.card)
        return true
    }

    /// The overlay card over the player while the session has one.
    private func reconcileUpNextCard(_ card: UpNextCardState?) {
        guard upNextSession != nil, !isClosing, !isClosingForNextEpisode else { return }
        guard let card = card else {
            if let overlay = upNextOverlay, overlay.presentingViewController != nil, !overlay.isBeingDismissed {
                overlay.dismiss(animated: true)
            }
            upNextOverlay = nil
            return
        }
        if let overlay = upNextOverlay, overlay.presentingViewController != nil, !overlay.isBeingDismissed { return }
        // Not over another presentation (options, the slow-resume offer, the
        // chooser): tried again in a second.
        guard viewIfLoaded?.window != nil, presentedViewController == nil, transitionCoordinator == nil else {
            scheduleUpNextRetry()
            return
        }
        let overlay = UpNextOverlayViewController(session: upNextSession, summary: upNextSession?.next.summary)
        upNextOverlay = overlay
        print("[UpNext] VLC card: overlay (\(card.kind.rawValue))")
        present(overlay, animated: true)
    }

    private func scheduleUpNextRetry() {
        guard !upNextRetryScheduled else { return }
        upNextRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            self.upNextRetryScheduled = false
            self.reconcileUpNextCard(self.upNextSession?.card)
        }
    }
#endif

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

#if os(tvOS)
extension PCTPlayerViewController: UpNextTVPlayer {

    /// The next episode (or today's flow): this player closes as at the
    /// end of an episode — progress saved, stream cancelled and its data
    /// deleted (`didFinishPlaying`) — and `then` runs once it is gone.
    func closeForNextEpisode(then: @escaping () -> Void) {
        guard !isClosing else { return then() }
        isClosingForNextEpisode = true
        print("[UpNext] VLC player closes at the session's request (next episode, fallback or end) — stream cancelled, its data deleted")
        let before = afterClose
        afterClose = { before?(); then() }
        didFinishPlaying()
    }

    var upNextPresenter: UIViewController { self }
}
#endif
