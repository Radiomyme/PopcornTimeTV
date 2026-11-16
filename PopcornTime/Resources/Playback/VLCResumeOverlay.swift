import Foundation
#if canImport(UIKit)
import UIKit

/// The UIKit VLC players' « Resuming at … » state over the video (tvOS, iOS):
/// the picture dimmed — VLC's first frame at 0:00 stays under it while it
/// gets to the resume point —, a spinner and the label, from `play()` until
/// `VLCResumeWatch` says playback runs. On iOS the slow-resume offer
/// (message and two buttons) shows under the label; on tvOS the VLC player's
/// own remote handling leaves no room for focusable buttons in its view: the
/// offer is `VLCResumeOfferController`, presented over it.
final class VLCResumeOverlayView: UIView {

    private let spinner = UIActivityIndicatorView(style: .large)
    private let label = UILabel()
    private let pauseGlyph = UIImageView(image: UIImage(systemName: "pause.fill"))
    private let offerStack = UIStackView()
    private var onKeepWaiting: (() -> Void)?
    private var onFromStart: (() -> Void)?

    private static var isTV: Bool { UIDevice.current.userInterfaceIdiom == .tv }

    /// Adds the state to `container`, above `sibling` (the video) when given.
    static func install(in container: UIView, above sibling: UIView?) -> VLCResumeOverlayView {
        let overlay = VLCResumeOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        if let sibling = sibling, sibling.superview === container {
            container.insertSubview(overlay, aboveSubview: sibling)
        } else {
            container.addSubview(overlay)
        }
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return overlay
    }

    private init() {
        super.init(frame: .zero)
        let isTV = Self.isTV
        // Dimmed, not black: should VLC play under a state that is still up
        // (a clock this watch does not understand), the picture shows.
        backgroundColor = UIColor.black.withAlphaComponent(0.7)
        // tvOS: nothing here takes the focus or the remote. iOS: the taps on
        // the dimmed picture go on to the player (its controls), the offer's
        // buttons take theirs (`hitTest`).
        isUserInteractionEnabled = !isTV

        spinner.color = .white
        spinner.startAnimating()
        pauseGlyph.tintColor = .white
        pauseGlyph.isHidden = true
        pauseGlyph.setContentHuggingPriority(.required, for: .horizontal)
        label.textColor = .white
        // The native player's look (`StatusCapsuleLabel`): `title3`
        // semibold on Apple TV, `headline` on iPhone / iPad.
        label.font = StatusCapsuleLabel.textFont
        label.adjustsFontForContentSizeCategory = !isTV
        label.numberOfLines = 2
        label.textAlignment = .center
        pauseGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: label.font, scale: .small)
        let labelRow = UIStackView(arrangedSubviews: [pauseGlyph, label])
        labelRow.axis = .horizontal
        labelRow.alignment = .center
        labelRow.spacing = isTV ? 18 : 8

        offerStack.axis = .vertical
        offerStack.alignment = .center
        offerStack.spacing = 14
        offerStack.isHidden = true

        // The spinner and the label in the same dark capsule as the native
        // player's « Reprise à … »: readable over a bright picture and
        // under the transport bar.
        let capsuleStack = UIStackView(arrangedSubviews: [spinner, labelRow])
        capsuleStack.axis = .vertical
        capsuleStack.alignment = .center
        capsuleStack.spacing = 16
        capsuleStack.translatesAutoresizingMaskIntoConstraints = false
        let capsule = UIView()
        capsule.backgroundColor = StatusCapsuleLabel.capsuleColor
        capsule.layer.cornerRadius = StatusCapsuleLabel.cornerRadius
        capsule.layer.cornerCurve = .continuous
        capsule.addSubview(capsuleStack)
        let padding = StatusCapsuleLabel.padding
        NSLayoutConstraint.activate([
            capsuleStack.topAnchor.constraint(equalTo: capsule.topAnchor, constant: padding),
            capsuleStack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -padding),
            capsuleStack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: padding),
            capsuleStack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -padding),
        ])

        let stack = UIStackView(arrangedSubviews: [capsule, offerStack])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = isTV ? 48 : 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // The spinner where the players' loading spinner is: the centre.
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
        isAccessibilityElement = false
        label.accessibilityTraits = .updatesFrequently
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// « Resuming at 1:40:00… » (announced when it first shows).
    var text: String? {
        get { label.text }
        set {
            guard newValue != label.text else { return }
            let isFirst = label.text == nil
            label.text = newValue
            if isFirst, let text = newValue { UIAccessibility.post(notification: .announcement, argument: text) }
        }
    }

    /// Play/Pause was pressed during the wait: a pause sign by the label
    /// (VLC is paused at the arrival).
    var showsPause: Bool {
        get { !pauseGlyph.isHidden }
        set { pauseGlyph.isHidden = !newValue }
    }

    /// iOS: the slow-resume offer under the label — `VLCResumeText.slow`,
    /// « Keep waiting » and, when `fromStart` is given, « Start from the
    /// beginning ».
    func showOffer(keepWaiting: @escaping () -> Void, fromStart: (() -> Void)?) {
        onKeepWaiting = keepWaiting
        onFromStart = fromStart
        offerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let message = UILabel()
        message.text = VLCResumeText.slow
        message.textColor = .white
        message.font = .preferredFont(forTextStyle: .subheadline)
        message.adjustsFontForContentSizeCategory = true
        message.numberOfLines = 0
        message.textAlignment = .center
        offerStack.addArrangedSubview(message)
        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = 16
        buttons.addArrangedSubview(Self.button(VLCResumeText.keepWaiting, target: self, action: #selector(keepWaitingTapped)))
        if fromStart != nil {
            buttons.addArrangedSubview(Self.button(VLCResumeText.fromStart, target: self, action: #selector(fromStartTapped)))
        }
        offerStack.addArrangedSubview(buttons)
        offerStack.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: VLCResumeText.slow)
    }

    func hideOffer() {
        offerStack.isHidden = true
        onKeepWaiting = nil
        onFromStart = nil
    }

    var isOfferShown: Bool { !offerStack.isHidden }

    private static func button(_ title: String, target: Any, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = UIColor.white.withAlphaComponent(0.22)
        configuration.cornerStyle = .medium
        let button = UIButton(configuration: configuration)
        button.addTarget(target, action: action, for: .primaryActionTriggered)
        return button
    }

    @objc private func keepWaitingTapped() {
        let action = onKeepWaiting
        hideOffer()
        action?()
    }

    @objc private func fromStartTapped() {
        let action = onFromStart
        hideOffer()
        action?()
    }

    /// Only the offer's buttons take touches: everything else goes to the
    /// player under the state (tap to show its controls, its close button).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit is UIButton ? hit : nil
    }

    /// Fades the state away and removes it.
    func dismiss() {
        isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.25, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })
    }
}

#if os(tvOS)
/// tvOS: the slow-resume offer of the VLC player — a card under the « Resuming
/// at … » label, presented over the player (`.overFullScreen`), as the
/// bandwidth offer is (`BandwidthDeficitToastController`): it takes the
/// remote while it shows. « Keep waiting » is focused (a click meant for the
/// player changes nothing), clicks in its first second are ignored, Menu =
/// « Keep waiting » (the next Menu closes the player), and Play/Pause still
/// reaches the player (`onPlayPause`). VoiceOver reads the message.
final class VLCResumeOfferController: UIViewController {
    private let onKeepWaiting: () -> Void
    private let onFromStart: (() -> Void)?
    private let onPlayPause: () -> Void
    private var keepWaitingButton: UIButton?
    private var answered = false
    /// Clicks before this (system uptime) are ignored: a press meant for the
    /// player as the card appears.
    private var acceptsClicksAt: TimeInterval = .infinity

    /// - Parameter onFromStart: nil when the film can't start over (bounded
    ///   storage that already released its head): the card then has the one
    ///   button.
    init(onKeepWaiting: @escaping () -> Void, onFromStart: (() -> Void)?, onPlayPause: @escaping () -> Void) {
        self.onKeepWaiting = onKeepWaiting
        self.onFromStart = onFromStart
        self.onPlayPause = onPlayPause
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        card.layer.cornerRadius = 24
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        let label = UILabel()
        label.text = VLCResumeText.slow
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .callout)
        label.textAlignment = .center

        let keepWaiting = UIButton(type: .system)
        keepWaiting.setTitle(VLCResumeText.keepWaiting, for: .normal)
        keepWaiting.addTarget(self, action: #selector(keepWaitingTapped), for: .primaryActionTriggered)
        keepWaitingButton = keepWaiting
        var buttons = [keepWaiting]
        if onFromStart != nil {
            let fromStart = UIButton(type: .system)
            fromStart.setTitle(VLCResumeText.fromStart, for: .normal)
            fromStart.addTarget(self, action: #selector(fromStartTapped), for: .primaryActionTriggered)
            buttons.append(fromStart)
        }
        let buttonRow = UIStackView(arrangedSubviews: buttons)
        buttonRow.spacing = 40

        let stack = UIStackView(arrangedSubviews: [label, buttonRow])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            // Under the spinner and the label, which stay in sight, and
            // above the transport bar (below the capsule of
            // `VLCResumeOverlayView`, whose bottom is ≈ 130 pt under the centre).
            card.topAnchor.constraint(equalTo: view.centerYAnchor, constant: 170),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 1300),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -40),
        ])
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [keepWaitingButton].compactMap { $0 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        acceptsClicksAt = ProcessInfo.processInfo.systemUptime + 1
        UIAccessibility.post(notification: .announcement, argument: VLCResumeText.slow)
    }

    private var acceptsClicks: Bool { ProcessInfo.processInfo.systemUptime >= acceptsClicksAt }

    @objc private func keepWaitingTapped() {
        guard !answered, acceptsClicks else { return }
        answered = true
        onKeepWaiting()
    }

    @objc private func fromStartTapped() {
        guard !answered, acceptsClicks, let onFromStart = onFromStart else { return }
        answered = true
        onFromStart()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            guard !answered else { return }
            answered = true
            onKeepWaiting()
            return
        }
        if presses.contains(where: { $0.type == .playPause }) {
            onPlayPause()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // Menu's end (and Play/Pause's) stay here too: passed on, they reached
    // the player under the card, whose Menu handling acts on the press's end.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu || $0.type == .playPause }) { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu || $0.type == .playPause }) { return }
        super.pressesCancelled(presses, with: event)
    }
}
#endif
#endif
