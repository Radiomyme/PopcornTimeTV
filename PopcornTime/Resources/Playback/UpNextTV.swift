#if os(tvOS)
import UIKit
import Combine
import AlamofireImage
import PopcornKit
import PopcornTorrent

// Episode chaining on the Apple TV (5.3.0): the platform's half of
// `UpNextSession` (`UpNextSession.swift`). `AppDelegate.play` makes one
// `UpNextTVLink` per episode played; the player that plays it (the native
// `RemuxAVPlayerViewController`, then `PCTPlayerViewController` after a
// hand-off to VLC) attaches to it, ticks the session and shows its card:
//
// - native player, countdown: AVKit's content proposal
//   (`UpNextProposalViewController`: the video shrunk at the top, the card
//   under it), else this file's `UpNextOverlayViewController`;
// - after the file (length unknown: EVENT playlist), « Still watching? »,
//   the VLC player: `UpNextOverlayViewController` over the player.
//
// Both show `UpNextCardContentView`: the episode's image, « Next episode »,
// « S1 · E3 — Title », the version line (« 1080p HEVC · same pack »), the
// countdown, and three buttons: « Play Now », « Back to the Video » (or
// « Cancel » / « Stop »), « Choose Version ».
//
// The host (`UpNextTVLink.makeHost`): the next episode starts once the player
// is closed — its stream cancelled and its data deleted (bounded storage,
// error -7 on the same pack) — through `AppDelegate.play`; anything the new
// route cannot do falls back on today's `playNext` → `chooseQuality`.

/// A player that carries the episode-chaining session (native, VLC).
@MainActor
protocol UpNextTVPlayer: AnyObject {
    /// Closes the player as at its end — progress saved, stream cancelled
    /// and its data deleted — then runs `then` once it is off the screen.
    func closeForNextEpisode(then: @escaping () -> Void)
    /// What the chooser of « Choose Version » is presented over.
    var upNextPresenter: UIViewController { get }
}

/// One playback of an episode on the Apple TV and its `UpNextSession`.
@MainActor
final class UpNextTVLink {
    let episode: Episode
    /// The session of this playback; nil: no next episode to offer (the
    /// players then do what they did before 5.3).
    private(set) var session: UpNextSession?
    /// The player that plays it now (the native one, then VLC).
    weak var player: UpNextTVPlayer?
    private var didBegin = false
    private var nextID: String?

    /// nil for a movie, or an episode without its show.
    init?(media: Media) {
        guard let episode = media as? Episode, episode.show != nil else { return nil }
        self.episode = episode
    }

    /// `player` plays the episode from now on. The first one begins the
    /// session; a later one (VLC after a hand-off) takes it over as it is.
    /// nil: no session — the player's own Up Next of before 5.3.
    func attach(_ player: UpNextTVPlayer, streamer: PTTorrentStreamer?) -> UpNextSession? {
        self.player = player
        if !didBegin {
            didBegin = true
            session = UpNextSession.begin(episode: episode, streamer: streamer, host: makeHost())
            nextID = session?.next.id
        } else if session != nil {
            print("[UpNext] the session goes on in \(type(of: player))")
        }
        return session
    }

    private func makeHost() -> UpNextSession.Host {
        UpNextSession.Host(
            startNext: { [weak self] plan in
                guard let torrent = plan.torrent else { return false }
                let start = {
                    print("[UpNext] starting \(plan.episode.id) — the previous stream is gone")
                    AppDelegate.shared.play(plan.episode, torrent: torrent)
                }
                guard let player = self?.player else {
                    start()
                    return true
                }
                player.closeForNextEpisode(then: start)
                return true
            },
            fallBack: { [weak self] episode in
                let fallBack = { AppDelegate.shared.playNext(episode) }
                if let player = self?.player {
                    player.closeForNextEpisode(then: fallBack)
                } else {
                    fallBack()
                }
            },
            chooseVersion: { [weak self] plan in
                self?.presentChooser(for: plan)
            },
            closePlayer: { [weak self] in
                self?.player?.closeForNextEpisode(then: {})
            },
            excludedSourceKeys: { [weak self] in
                AppDelegate.unansweredSources[self?.nextID ?? ""] ?? []
            })
    }

    // MARK: « Choose Version »

    /// The next episode's releases, the planned one first and focused;
    /// playback goes on behind. The list is the plan's, else the episode's
    /// sources (`EpisodeSourceResolver`, cached).
    private func presentChooser(for plan: UpNextPlan) {
        let next = plan.episode
        if !plan.sources.isEmpty || next.show?.id.hasPrefix("tt") != true {
            showChooser(plan, candidates: plan.sources.isEmpty ? next.torrents : plan.sources)
            return
        }
        EpisodeSourceResolver.shared.resolve(showId: next.show?.id ?? "", showTitle: next.show?.title,
                                             season: next.season, episode: next.episode,
                                             isEnough: { $0.count > 0 && $0.awaited.isEmpty },
                                             completion: { [weak self] sources in
            DispatchQueue.main.async {
                let merged = sources.merged(withBase: next.torrents, runtime: Torrent.mediaRuntime(of: next))
                self?.showChooser(plan, candidates: merged)
            }
        })
    }

    private func showChooser(_ plan: UpNextPlan, candidates: [Torrent]) {
        guard let session = session else { return }
        let excluded = AppDelegate.unansweredSources[plan.episode.id] ?? []
        var list = candidates.filter { !excluded.contains(AppDelegate.sourceKey($0.url)) }
        if let planned = plan.torrent, !list.contains(where: { $0.url == planned.url }) { list.append(planned) }
        let others = list.filter { $0.url != plan.torrent?.url }.sorted(by: <).reversed()
        let ordered = (plan.torrent.map { [$0] } ?? []) + others
        guard !ordered.isEmpty else {
            print("[UpNext] chooser: no release of \(plan.episode.id)")
            session.choiceCancelled()
            return
        }
        let alert = UIAlertController(title: "UpNext.ChooseVersion".localized, message: UpNextText.episodeTitle(plan.episode),
                                      preferredStyle: .alert, blurStyle: .extraLight)
        var plannedAction: UIAlertAction?
        for torrent in ordered {
            var label = torrent.qualityLabel.isEmpty ? "—" : torrent.qualityLabel
            label += "  ·  \(torrent.seeds) seeds"
            if let size = torrent.size, !size.isEmpty { label += "  ·  \(size)" }
            if let source = torrent.sourceLabel { label += "  ·  \(source)" }
            if torrent.url == plan.torrent?.url { label = "⭐︎ " + label }
            let action = UIAlertAction(title: label, style: .default) { [weak session] _ in
                print("[UpNext] chooser: \(torrent.quality ?? "?") picked")
                session?.chose(torrent)
            }
            alert.addAction(action)
            if torrent.url == plan.torrent?.url { plannedAction = action }
        }
        alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel) { [weak session] _ in
            session?.choiceCancelled()
        })
        if let plannedAction = plannedAction { alert.preferredAction = plannedAction }
        present(alert, attempts: 12)
    }

    /// Over the player once nothing is being presented or dismissed there:
    /// the card leaves as the chooser comes (AVKit presents its proposal
    /// modally — an alert over it would leave with it).
    private func present(_ alert: UIAlertController, attempts: Int) {
        guard let base = player?.upNextPresenter, base.viewIfLoaded?.window != nil else {
            print("[UpNext] chooser: the player is gone")
            session?.choiceCancelled()
            return
        }
        var top = base
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let busy = top.presentedViewController != nil || top.isBeingPresented || top.transitionCoordinator != nil
            || top is UpNextOverlayViewController || top is UpNextProposalViewController
        if busy, attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.present(alert, attempts: attempts - 1) }
            return
        }
        print("[UpNext] chooser: presented over \(type(of: top))"
              + (busy ? " (still busy: \(top.presentedViewController.map { "\(type(of: $0))" } ?? "a transition"))" : ""))
        top.present(alert, animated: true)
        // A presentation UIKit refused never shows: the chooser counts as left.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak alert] in
            guard let alert = alert, alert.presentingViewController == nil else { return }
            print("[UpNext] chooser: UIKit did not present it — left without a pick")
            self?.session?.choiceCancelled()
        }
    }
}

// MARK: - The card

/// The card's content, the same for the AVKit proposal and the overlay:
/// image | texts | three buttons (vertical), laid out on one row.
final class UpNextCardContentView: UIView {

    let playButton = UIButton(type: .system)
    let backButton = UIButton(type: .system)
    let chooseButton = UIButton(type: .system)

    var onPlay: (() -> Void)?
    var onBack: (() -> Void)?
    var onChoose: (() -> Void)?

    private let imageView = UIImageView()
    private let captionLabel = UILabel()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let versionLabel = UILabel()
    private let summaryLabel = UILabel()
    private let messageLabel = UILabel()
    private let countdownLabel = UILabel()
    private var imageURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { return nil }

    private func build() {
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 12
        imageView.backgroundColor = UIColor(white: 1, alpha: 0.08)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor, multiplier: 16.0 / 9.0).isActive = true

        captionLabel.font = .preferredFont(forTextStyle: .headline)
        captionLabel.textColor = UIColor(white: 1, alpha: 0.7)
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        detailLabel.font = .preferredFont(forTextStyle: .callout)
        detailLabel.textColor = UIColor(white: 1, alpha: 0.7)
        // The release that will play: what « same version » means here.
        versionLabel.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
        versionLabel.textColor = .white
        versionLabel.accessibilityIdentifier = "UpNext.VersionLine"
        summaryLabel.font = .preferredFont(forTextStyle: .callout)
        summaryLabel.textColor = UIColor(white: 1, alpha: 0.85)
        // Fits below the shrunk player on a 1080-point screen.
        summaryLabel.numberOfLines = 3
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .white
        messageLabel.numberOfLines = 2
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize,
                                                         weight: .semibold)
        countdownLabel.textColor = .white
        countdownLabel.accessibilityIdentifier = "UpNext.Countdown"

        let textStack = UIStackView(arrangedSubviews: [captionLabel, titleLabel, detailLabel, versionLabel, summaryLabel,
                                                       messageLabel, countdownLabel])
        textStack.axis = .vertical
        textStack.spacing = 10
        textStack.alignment = .leading
        textStack.setCustomSpacing(24, after: summaryLabel)
        textStack.setCustomSpacing(24, after: messageLabel)

        playButton.accessibilityIdentifier = "UpNext.Button.PlayNow"
        backButton.accessibilityIdentifier = "UpNext.Button.Back"
        chooseButton.accessibilityIdentifier = "UpNext.Button.ChooseVersion"
        playButton.addTarget(self, action: #selector(play), for: .primaryActionTriggered)
        backButton.addTarget(self, action: #selector(back), for: .primaryActionTriggered)
        chooseButton.addTarget(self, action: #selector(choose), for: .primaryActionTriggered)
        let buttonStack = UIStackView(arrangedSubviews: [playButton, backButton, chooseButton])
        buttonStack.axis = .vertical
        buttonStack.spacing = 24
        buttonStack.alignment = .fill

        let row = UIStackView(arrangedSubviews: [imageView, textStack, buttonStack])
        row.axis = .horizontal
        row.spacing = 48
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.26),
            buttonStack.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.28),
        ])
    }

    /// Shows `card`; `summary`: the episode's synopsis (nil: none).
    /// `showsChooseVersion` false: the old card (no session) has two buttons.
    func apply(_ card: UpNextCardState, summary: String?, showsChooseVersion: Bool = true) {
        captionLabel.text = card.headline
        titleLabel.text = card.title
        detailLabel.text = card.showTitle
        detailLabel.isHidden = (card.showTitle ?? "").isEmpty
        versionLabel.text = card.versionLine
        versionLabel.isHidden = (card.versionLine ?? "").isEmpty
        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        summaryLabel.text = summary == "No summary available.".localized ? "" : summary
        summaryLabel.isHidden = summaryLabel.text?.isEmpty ?? true || card.kind == .stillWatching
        messageLabel.text = card.message
        messageLabel.isHidden = (card.message ?? "").isEmpty
        countdownLabel.text = card.countdownText
        countdownLabel.isHidden = card.countdownText == nil
        playButton.setTitle(card.playNowTitle, for: .normal)
        backButton.setTitle(card.kind == .countdown ? card.backToVideoTitle : card.cancelTitle, for: .normal)
        chooseButton.setTitle(card.chooseVersionTitle, for: .normal)
        chooseButton.isHidden = !showsChooseVersion
        accessibilityLabel = card.accessibilityLabel
        if card.imageURL != imageURL {
            imageURL = card.imageURL
            if let url = card.imageURL {
                imageView.af.setImage(withURL: url)
            } else {
                imageView.image = nil
            }
        }
    }

    @objc private func play() { onPlay?() }
    @objc private func back() { onBack?() }
    @objc private func choose() { onChoose?() }
}

/// The card over the player — after the file, « Still watching? », the VLC
/// player, a countdown AVKit did not present — and the DEBUG fixture. Its
/// buttons answer the session; the player dismisses it when the session's
/// card goes. Menu = « Back to the Video » / « Cancel ».
final class UpNextOverlayViewController: UIViewController {

    let content = UpNextCardContentView()
    private weak var session: UpNextSession?
    private let summary: String?
    private var subscription: AnyCancellable?
    /// DEBUG fixture: what the buttons do instead of a session.
    var fixtureAction: ((String) -> Void)?

    init(session: UpNextSession?, summary: String?) {
        self.session = session
        self.summary = summary
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { return nil }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [content.playButton] }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Dark enough for white text over any picture; the video (VLC, or
        // its last frame) shows dimmed behind.
        view.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        view.accessibilityIdentifier = "UpNext.Card"
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 40),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -40),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
            NSLayoutConstraint(item: content, attribute: .top, relatedBy: .equal,
                               toItem: view, attribute: .bottom, multiplier: 0.5, constant: 0),
        ])
        content.onPlay = { [weak self] in self?.answer("accept") }
        content.onBack = { [weak self] in self?.answer("cancel") }
        content.onChoose = { [weak self] in self?.answer("choose") }
        if let card = session?.card { content.apply(card, summary: summary) }
        subscription = session?.$card.receive(on: DispatchQueue.main).sink { [weak self] card in
            guard let self = self, let card = card else { return }
            self.content.apply(card, summary: self.summary)
        }
    }

    /// The fixture's card (no session).
    func show(_ card: UpNextCardState) {
        loadViewIfNeeded()
        content.apply(card, summary: summary)
    }

    private func answer(_ action: String) {
        if let fixtureAction = fixtureAction { return fixtureAction(action) }
        guard let session = session else { return }
        switch action {
        case "accept": session.accept()
        case "cancel": session.cancel()
        default: session.chooseVersion()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else { return super.pressesBegan(presses, with: event) }
        answer("cancel")
    }

    // Menu's other phases stay here (the player under it would close).
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else { return super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else { return super.pressesCancelled(presses, with: event) }
    }
}

#if DEBUG
/// `-PTDebugResumeEpisode S01E02` (bench, N6): « Resume » on that episode
/// of the made-up show, the way the page's button and the Continue Watching
/// card call it (`AppDelegate.playRemembered`) — the release remembered
/// from an earlier launch, the saved position passed as decided. Nothing
/// remembered: a line says so and nothing plays.
enum UpNextTVResumeHook {
    static func runIfAsked() -> Bool {
        guard let marker = UserDefaults.standard.string(forKey: "PTDebugResumeEpisode"),
              let number = UpNextDebugHooks.parse(marker) else { return false }
        let show = UpNextDebugHooks.fakeShow(at: number)
        guard var episode = show.episodes.first(where: { $0.season == number.season && $0.episode == number.episode }) else {
            return false
        }
        episode.show = show
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print("[UpNextDebug] « Resume » on \(episode.id)")
            if !AppDelegate.shared.playRemembered(episode) {
                print("[UpNextDebug] resume: nothing remembered for \(episode.id) — nothing played")
            }
        }
        return true
    }
}

/// `-PTDebugUpNextCard <countdown|postPlay|stillWatching>` (UI tests): the
/// card over a black stand-in for the player, with made-up texts and a
/// countdown from 30 s that starts nothing. Its buttons only write what
/// they did into a label (`UpNext.Fixture.Log`): « accept », « cancel »,
/// « choose », « deadline » when the countdown ran out. No stream, no session.
enum UpNextTVFixture {
    static var kind: UpNextCardState.Kind? {
        UserDefaults.standard.string(forKey: "PTDebugUpNextCard").flatMap(UpNextCardState.Kind.init(rawValue:))
    }

    /// Presents the fixture over `root` when asked; true when it did.
    @discardableResult
    static func presentIfAsked(over root: UIViewController) -> Bool {
        guard let kind = kind else { return false }
        let stage = UIViewController()
        stage.view.backgroundColor = .black
        stage.modalPresentationStyle = .fullScreen
        let log = UILabel()
        log.text = "-"
        log.textColor = .white
        log.font = .systemFont(ofSize: 24)
        log.accessibilityIdentifier = "UpNext.Fixture.Log"
        log.translatesAutoresizingMaskIntoConstraints = false
        stage.view.addSubview(log)
        NSLayoutConstraint.activate([
            log.topAnchor.constraint(equalTo: stage.view.safeAreaLayoutGuide.topAnchor, constant: 20),
            log.leadingAnchor.constraint(equalTo: stage.view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
        ])
        var answers: [String] = []
        let overlay = UpNextOverlayViewController(session: nil,
                                                  summary: "Episode 2 of the bench. A made-up synopsis long enough to take two lines on the card, as a real one would.")
        var left = 30
        func card() -> UpNextCardState {
            let title = String(format: "UpNext.EpisodeTitle".localized, 1, 2, "Test Episode 2")
            let headline: String
            switch kind {
            case .countdown: headline = "ContinueWatching.NextEpisode".localized
            case .postPlay: headline = "UpNext.Ended".localized
            case .stillWatching: headline = "UpNext.StillWatching".localized
            }
            let countdown = kind == .stillWatching ? nil : left
            return UpNextCardState(kind: kind, episodeID: "tt0000001-s1e2", headline: headline, title: title,
                                   showTitle: "PT Test Show",
                                   versionLine: kind == .stillWatching ? nil : String(format: "UpNext.SamePack".localized, "1080p HEVC"),
                                   imageURL: nil, secondsLeft: countdown, total: kind == .postPlay ? 10 : 30,
                                   message: kind == .stillWatching ? String(format: "UpNext.StillWatching.Message".localized, 3) : nil)
        }
        overlay.fixtureAction = { action in
            answers.append(action)
            log.text = answers.joined(separator: ",")
            print("[UpNextDebug] fixture: \(action)")
        }
        if kind == .postPlay { left = 10 }
        root.present(stage, animated: false) {
            stage.present(overlay, animated: false) { overlay.show(card()) }
            overlay.show(card())
            guard kind != .stillWatching else { return }
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                left = max(0, left - 1)
                overlay.show(card())
                if left == 0 {
                    timer.invalidate()
                    overlay.fixtureAction?("deadline")
                }
            }
        }
        print("[UpNextDebug] fixture card: \(kind.rawValue)")
        return true
    }
}
#endif
#endif
