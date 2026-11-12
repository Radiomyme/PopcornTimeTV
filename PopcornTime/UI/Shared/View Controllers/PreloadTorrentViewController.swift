

import UIKit
import PopcornKit
import PopcornTorrent
import QuartzCore

class PreloadTorrentViewController: UIViewController {

    @IBOutlet var progressView: UIProgressView!
    @IBOutlet var speedLabel: UILabel!
    @IBOutlet var seedsLabel: UILabel!
    @IBOutlet var titleLabel: UILabel!
    @IBOutlet var processingView: UIView!

    @IBOutlet var backgroundImageView: UIImageView?

    var streamer: PTTorrentStreamer! {
        didSet {
            // Back was pressed before the stream existed (the play flow
            // fetches the subtitles first, then starts it): the stream it
            // starts now is not wanted. It is stopped as soon as it started,
            // with its callbacks, so no player opens after the user left.
            guard isCancelled, let streamer = streamer, streamer !== oldValue,
                  !(streamer is PTTorrentDownload) else { return }
            print("[Loading] stream started after Back — stopping it")
            DispatchQueue.main.async { streamer.cancelStreamingAndDeleteData(false) }
        }
    }

    /// Menu (Back) closed this screen (`cancel`).
    private(set) var isCancelled = false

    /// The movie or episode being loaded, and the source (torrent URL) it
    /// plays: « Choose another source » goes back to the quality picker for
    /// it (`AppDelegate.chooseAnotherSource`). Set by
    /// `Media.play(fromFileOrMagnetLink:…)`; nil hides that button.
    var media: Media?
    var sourceURL: String?

    /// What the screen says while the torrent prepares (`LoadingPhase`): the
    /// phase line under the spinner from the first second (« Looking for
    /// peers… », « Getting the torrent's details… », with the time spent),
    /// then the buffering % and ETA as before, and « This source isn't
    /// responding… » with « Choose another source » / « Keep waiting » when
    /// the source looks dead. Fed by every status (`progress`) and a 1 s
    /// timer (the stall rules need the clock; an older PopcornTorrent sends no
    /// status before the metadata).
    private var tracker: LoadingPhaseTracker?
    private weak var trackedStreamer: PTTorrentStreamer?
    private var phaseTimer: Timer?
    private var isLeaving = false

    /// Numeric buffering % + a rough ETA until playback can start, shown just
    /// below the existing progress bar / speed / seeds block. Built in code so
    /// it needs no storyboard outlet.
    private lazy var etaLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 1
        label.font = .systemFont(ofSize: 30, weight: .semibold)
        label.shadowColor = UIColor.black.withAlphaComponent(0.6)
        label.shadowOffset = CGSize(width: 0, height: 1)
        label.isHidden = true
        return label
    }()

    /// Bounded storage (the film is larger than the free space): « Limited
    /// storage: you can rewind about N min », below the ETA. Hidden in full
    /// mode.
    private lazy var boundedLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.font = .systemFont(ofSize: 26, weight: .medium)
        label.shadowColor = UIColor.black.withAlphaComponent(0.6)
        label.shadowOffset = CGSize(width: 0, height: 1)
        label.isHidden = true
        return label
    }()
    /// When the bounded-storage line was last computed (it reads the free space).
    private var boundedNoteAt: CFTimeInterval = 0

    /// The phase line: under the spinner while waiting (the not-responding
    /// message too, if nothing was buffered yet), else in the ETA's place
    /// below the progress block.
    private lazy var phaseLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = Self.waitingFont
        label.shadowColor = UIColor.black.withAlphaComponent(0.6)
        label.shadowOffset = CGSize(width: 0, height: 1)
        label.isHidden = true
        return label
    }()
    private static let waitingFont = UIFont.systemFont(ofSize: 30, weight: .medium)
    private static let messageFont = UIFont.systemFont(ofSize: 34, weight: .semibold)
    private var phaseUnderSpinner: NSLayoutConstraint?
    private var phaseUnderProgress: NSLayoutConstraint?
    private var actionsUnderPhase: NSLayoutConstraint?
    private var actionsUnderProgress: NSLayoutConstraint?

    /// The action buttons under the phase line, or under the buffering block.
    private func placeActions(underProgress: Bool) {
        guard actionsUnderProgress?.isActive != underProgress else { return }
        actionsUnderPhase?.isActive = false
        actionsUnderProgress?.isActive = false
        (underProgress ? actionsUnderProgress : actionsUnderPhase)?.isActive = true
    }

    private lazy var chooseSourceButton: UIButton = makeActionButton(LoadingPhase.chooseAnotherSourceTitle,
                                                                     action: #selector(chooseAnotherSource))
    private lazy var keepWaitingButton: UIButton = makeActionButton(LoadingPhase.keepWaitingTitle,
                                                                    action: #selector(keepWaiting))
    private lazy var actionsStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [chooseSourceButton, keepWaitingButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 40
        stack.alignment = .center
        stack.isHidden = true
        return stack
    }()

    private func makeActionButton(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.addTarget(self, action: action, for: .primaryActionTriggered)
        return button
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installETALabelIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isLeaving else { return }
        startPhaseTimer()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        phaseTimer?.invalidate()
        phaseTimer = nil
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard !actionsStack.isHidden else { return super.preferredFocusEnvironments }
        return [chooseSourceButton.isHidden ? keepWaitingButton : chooseSourceButton]
    }

    /// Idempotent install, called from viewDidLoad AND from the first status
    /// update. The play flow historically called `loadView()` directly on this
    /// controller, which wires outlets but bypasses UIKit's loading machinery
    /// so viewDidLoad never fires — install lazily so the label exists no
    /// matter how the view was loaded.
    private func installETALabelIfNeeded() {
        guard etaLabel.superview == nil, isViewLoaded else { return }
        view.addSubview(etaLabel)
        // Anchor under the container that holds the progress bar + speed/seeds
        // labels so it can't overlap them; fall back to the progress bar.
        let anchorView: UIView = progressView.superview ?? progressView
        NSLayoutConstraint.activate([
            etaLabel.centerXAnchor.constraint(equalTo: anchorView.centerXAnchor),
            etaLabel.topAnchor.constraint(equalTo: anchorView.bottomAnchor, constant: 16),
            etaLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            etaLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
        ])
        view.addSubview(boundedLabel)
        NSLayoutConstraint.activate([
            boundedLabel.centerXAnchor.constraint(equalTo: anchorView.centerXAnchor),
            boundedLabel.topAnchor.constraint(equalTo: etaLabel.bottomAnchor, constant: 14),
            boundedLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            boundedLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
        ])
        view.addSubview(phaseLabel)
        phaseUnderSpinner = phaseLabel.topAnchor.constraint(equalTo: processingView.bottomAnchor, constant: 28)
        phaseUnderProgress = phaseLabel.topAnchor.constraint(equalTo: anchorView.bottomAnchor, constant: 16)
        phaseUnderSpinner?.isActive = true
        NSLayoutConstraint.activate([
            phaseLabel.centerXAnchor.constraint(equalTo: anchorView.centerXAnchor),
            phaseLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 1200),
            phaseLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 80),
            phaseLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -80),
        ])
        view.addSubview(actionsStack)
        // Under the phase line (not responding), or under the buffering
        // block and its bounded-storage line (a slow source).
        actionsUnderPhase = actionsStack.topAnchor.constraint(equalTo: phaseLabel.bottomAnchor, constant: 48)
        actionsUnderProgress = actionsStack.topAnchor.constraint(equalTo: boundedLabel.bottomAnchor, constant: 36)
        actionsUnderPhase?.isActive = true
        actionsStack.centerXAnchor.constraint(equalTo: anchorView.centerXAnchor).isActive = true
    }

    /// Bounded storage's line, at most every 5 s (it reads the free space);
    /// at once when the stream turns out bounded.
    private func updateBoundedNote() {
        let now = CACurrentMediaTime()
        guard now - boundedNoteAt >= 5
                || (boundedLabel.isHidden && BoundedStorageSession.session(for: streamer)?.isBounded == true) else { return }
        boundedNoteAt = now
        guard let note = BoundedStorageUX.loadingNote(for: streamer) else {
            boundedLabel.isHidden = true
            return
        }
        let text = NSMutableAttributedString()
        if let symbol = UIImage(systemName: BoundedStorageUX.symbolName,
                                withConfiguration: UIImage.SymbolConfiguration(font: boundedLabel.font))?
            .withTintColor(boundedLabel.textColor, renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
            text.append(NSAttributedString(string: "  "))
        }
        text.append(NSAttributedString(string: note))
        boundedLabel.attributedText = text
        boundedLabel.isHidden = false
    }

    /// Set by the play flow's loading block with every status of the stream
    /// (PopcornTorrent sends one every 0.5 s from the moment the torrent is
    /// added, buffering 0 before its metadata).
    var progress: Float = 0.0 {
        didSet {
            progressView.progress = progress
            refreshPhase(fromCallback: true)
        }
    }

    var speed: Int = 0 {
        didSet {
            speedLabel.text = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .binary) + "/s"
        }
    }

    var seeds: Int = 0 {
        didSet {
            // "Seeds: 1", not "1 seeds" (no plural rules in the tables).
            seedsLabel.text = String(format: NSLocalizedString("PlayerLoading.Seeds", value: "Seeds: %d",
                                                               comment: "Loading screen: connected seeds (count-neutral form)"),
                                     seeds)
        }
    }

    // MARK: - Phase

    private func startPhaseTimer() {
        guard phaseTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPhase(fromCallback: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        phaseTimer = timer
        refreshPhase(fromCallback: false)
    }

    /// Leaving (cancel, another source): the phase stays as it is while the
    /// screen goes (the cancelled stream would read « Looking for peers… »).
    private func stopPhaseUpdates() {
        phaseTimer?.invalidate()
        phaseTimer = nil
        isLeaving = true
    }

    /// Updates the phase from the streamer and lays the screen out for it.
    /// Before the stream starts (subtitles are fetched first: no streamer
    /// yet) the spinner alone, as before.
    private func refreshPhase(fromCallback: Bool) {
        guard isViewLoaded, !isLeaving, let streamer = streamer else { return }
        installETALabelIfNeeded()
        if tracker == nil || trackedStreamer !== streamer {
            tracker = LoadingPhaseTracker()
            trackedStreamer = streamer
        }
        guard let tracker = tracker else { return }
        let buttonsBefore = [actionsStack.isHidden, chooseSourceButton.isHidden, keepWaitingButton.isHidden]
        let phase = tracker.update(streamer: streamer, fromCallback: fromCallback)
        render(phase, line: tracker.line)
        if [actionsStack.isHidden, chooseSourceButton.isHidden, keepWaitingButton.isHidden] != buttonsBefore {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    /// Whether another source of the title is known (the stream's list —
    /// an episode's merged one — minus this source and those that did not
    /// answer): « Choose another source » shows only then.
    private var hasOtherSource: Bool {
        guard let media = media else { return false }
        var excluded = AppDelegate.unansweredSources[media.id] ?? []
        if let url = sourceURL { excluded.insert(AppDelegate.sourceKey(url)) }
        let known = PlaybackStreamContext.of(streamer)?.sources ?? media.torrents
        return known.contains { !excluded.contains(AppDelegate.sourceKey($0.url)) }
    }

    private func render(_ phase: LoadingPhase, line: String) {
        switch phase {
        case .buffering(let progress, _):
            processingView.isHidden = true
            progressView.isHidden = false
            progressView.progress = progress
            speedLabel.isHidden = false
            seedsLabel.isHidden = false
            etaLabel.isHidden = false
            etaLabel.text = line
            phaseLabel.isHidden = true
            // Alive but minutes from playing: another source, beside the
            // progress (no message, no « Keep waiting »).
            let offersAnother = tracker?.isSlow == true && hasOtherSource
            chooseSourceButton.isHidden = !offersAnother
            keepWaitingButton.isHidden = true
            actionsStack.isHidden = !offersAnother
            if offersAnother { placeActions(underProgress: true) }
            updateBoundedNote()
        case .notResponding:
            // The message and the actions in the spinner's place, or below
            // the progress block when the buffering had started (the bar
            // stays where it stopped).
            processingView.isHidden = true
            etaLabel.isHidden = true
            boundedLabel.isHidden = true
            showPhaseLine(line, underSpinner: progressView.isHidden, message: true)
            chooseSourceButton.isHidden = !hasOtherSource
            keepWaitingButton.isHidden = false
            actionsStack.isHidden = false
            placeActions(underProgress: false)
        case .starting, .lookingForPeers, .gettingDetails:
            processingView.isHidden = false
            progressView.isHidden = true
            speedLabel.isHidden = true
            seedsLabel.isHidden = true
            etaLabel.isHidden = true
            boundedLabel.isHidden = true
            showPhaseLine(line, underSpinner: true, message: false)
            actionsStack.isHidden = true
        }
    }

    private func showPhaseLine(_ line: String, underSpinner: Bool, message: Bool) {
        phaseLabel.font = message ? Self.messageFont : Self.waitingFont
        phaseLabel.textColor = message ? .white : UIColor.white.withAlphaComponent(0.9)
        if phaseUnderSpinner?.isActive != underSpinner {
            phaseUnderSpinner?.isActive = false
            phaseUnderProgress?.isActive = false
            (underSpinner ? phaseUnderSpinner : phaseUnderProgress)?.isActive = true
        }
        phaseLabel.text = line
        phaseLabel.isHidden = false
    }

    // MARK: - Actions

    /// « Choose another source »: this stream stops and the quality picker
    /// opens again for the same movie or episode.
    @objc private func chooseAnotherSource() {
        guard let media = media, !isLeaving else { return }
        stopPhaseUpdates()
        print("[Loading] \(tracker?.phase.stall.map { "\($0)" } ?? (tracker?.isSlow == true ? "slow" : "?")) — choosing another source than \(sourceURL?.prefix(80) ?? "?")")
        AppDelegate.shared.chooseAnotherSource(for: media, replacing: sourceURL, from: self)
    }

    /// « Keep waiting »: the message goes, and comes back only if the source
    /// still does not answer for as long again.
    @objc private func keepWaiting() {
        guard let tracker = tracker else { return }
        tracker.keepWaiting()
        render(tracker.phase, line: tracker.line)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Menu (Back): the stream stops and the screen closes — also when the
    /// press comes while the screen is still sliding in (UIKit would ignore
    /// that dismissal and leave a spinner without a stream: it waits for the
    /// presentation to end), and again on a later press if it did not close.
    @IBAction func cancel() {
        if !isCancelled {
            isCancelled = true
            stopPhaseUpdates()
            // nil until a download's `play` answers (it is set in that handler).
            streamer?.cancelStreamingAndDeleteData(false)
        }
        dismissWhenPossible()
    }

    private func dismissWhenPossible() {
        guard presentingViewController != nil, !isBeingDismissed else { return }
        if let coordinator = transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in
               DispatchQueue.main.async { self?.dismissWhenPossible() }
           }) {
            return
        }
        dismiss(animated: true)
    }

}

extension AppDelegate {

    /// The loading screen's « Choose another source » (a source that does
    /// not answer, or too slowly): stops the stream, closes the loading
    /// screen and opens the quality picker again for the same movie or
    /// episode (`chooseQuality`, a busy card while an episode's sources
    /// load), then plays the source picked. The source is remembered as
    /// unanswered for this title (`unansweredSources`, by info-hash): left
    /// out of the picker and of an automatic pick (Settings, Auto Select
    /// Quality) — an episode's aggregators would list it again, and an
    /// automatic pick would take it again.
    func chooseAnotherSource(for media: Media, replacing sourceURL: String?, from loadingViewController: PreloadTorrentViewController) {
        loadingViewController.streamer?.cancelStreamingAndDeleteData(false)
        if let sourceURL = sourceURL {
            AppDelegate.unansweredSources[media.id, default: []].insert(AppDelegate.sourceKey(sourceURL))
        }
        loadingViewController.dismiss(animated: true) { [weak self] in
            guard let self = self else { return }
            self.chooseQuality(nil, media: media) { torrent in
                self.play(media, torrent: torrent)
            }
        }
    }
}
