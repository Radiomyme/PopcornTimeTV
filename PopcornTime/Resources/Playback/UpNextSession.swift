import Foundation
import Combine
import PopcornKit
import PopcornTorrent

// Episode chaining (5.3.0): the app's half. One `UpNextSession` per playback
// of an episode links the player, the planner (PopcornKit `UpNextPlanner`,
// `UpNextCountdown`) and the platform's play flow. The decisions are
// PopcornKit's; the players report where they are and show the card.
//
// WHAT A PLAYER CALLS (all on the main thread):
//
//   let session = UpNextSession.begin(episode: episode, streamer: streamer, host: host)
//                                    // when playback starts; nil: a movie, the last episode,
//                                    // a show without a guide — the player does what it did
//   session?.tick(position: s, duration: d, isPlaying: wants)   // its 1 Hz clock
//   session?.itemEnded()             // its file ended; true: the session handles the end
//                                    // (do NOT close or loop yourself), false: do as before
//   session?.playerClosed()          // the user left the player (nothing starts)
//   session?.accept() / .cancel() / .chooseVersion()   // the card's buttons
//   session?.chose(torrent) / .choiceCancelled()        // what the chooser answered
//   session.card                     // @Published: the card to show (nil: none)
//
// WHAT A PLAYER (OR ITS PLATFORM) IMPLEMENTS: `UpNextSession.Host`
//
//   startNext(plan) -> Bool   tear this stream down (its data deleted: bounded
//                             storage, error -7 on the same pack), then play
//                             plan.torrent for plan.episode through the platform's
//                             normal flow; false: it could not → fallBack runs
//   fallBack(episode)         today's behaviour: playNext → chooseQuality (sources,
//                             « Always Ask » chooser, « No torrents found »)
//   chooseVersion(plan)       the chooser on the next episode, plan.torrent first;
//                             playback goes on behind; answer with chose / choiceCancelled
//   closePlayer()             close the player as at the end of an episode before 5.3
//
// If anything of the new route fails (no plan, a start refused), the
// session calls `fallBack`: the next episode still plays as it did before.

/// The setting « Autoplay next episode » (decision D8: on by default, the
/// three platforms) and how chaining reads the quality setting.
enum UpNextPreferences {
    /// A Bool; absent = on. The settings rows of the three platforms use it
    /// (`@AppStorage(UpNextPreferences.autoPlayNextKey) var autoPlayNext = true`).
    static let autoPlayNextKey = "autoPlayNextEpisode"

    static var autoPlayNext: Bool {
        get { (UserDefaults.standard.object(forKey: autoPlayNextKey) as? NSNumber)?.boolValue ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoPlayNextKey) }
    }

    /// The quality setting is « Always Ask ». Apple TV: "autoSelectQuality"
    /// absent or not one of Highest / Balanced / Lowest (stored localized,
    /// `GlassSettingsStore`); iPhone / iPad and Mac: "" (absent = Balanced).
    static var qualityAlwaysAsks: Bool {
        let stored = UserDefaults.standard.string(forKey: "autoSelectQuality")
        #if os(tvOS)
        guard let stored = stored, !stored.isEmpty else { return true }
        return !["Highest", "Balanced", "Lowest"].contains { stored == $0 || stored == $0.localized }
        #else
        return stored?.isEmpty ?? false
        #endif
    }
}

/// What starts the next episode.
struct UpNextPlan {
    /// The next episode, its show attached.
    let episode: Episode
    /// The release to play; nil: none (the chooser / today's flow).
    var torrent: Torrent?
    /// The episode's releases, merged as the chooser merges them: the next
    /// stream's other releases (another source, a lighter one), the chooser's list.
    var sources: [Torrent]
    var rule: UpNextChoice.Rule
    var reasons: [String]
    /// Its subtitles when the search already answered (the start reuses them).
    var subtitles: [Subtitle]?
    /// The chooser rather than `torrent` (no clear continuity and the quality
    /// setting is « Always Ask », decision D3; or no release).
    var needsChooser: Bool

    /// The card's version line: "1080p HEVC · same pack", nil when none.
    var versionLine: String? {
        guard let torrent = torrent, !needsChooser else { return nil }
        return UpNextText.versionLine(rule: rule, label: torrent.qualityLabel)
    }
}

/// The texts of the cards, the same on the three platforms.
enum UpNextText {
    /// "1080p HEVC · same pack" (`UpNext.SamePack`), "· same group",
    /// "· same quality"; the label alone for a balanced pick.
    static func versionLine(rule: UpNextChoice.Rule, label: String) -> String? {
        let label = label.isEmpty ? "?" : label
        switch rule {
        case .samePack: return String(format: "UpNext.SamePack".localized, label)
        case .sameGroup: return String(format: "UpNext.SameGroup".localized, label)
        case .sameClass, .sameResolution: return String(format: "UpNext.SameQuality".localized, label)
        case .balanced: return label
        case .none: return nil
        }
    }

    /// « Resume » / a Home card replaying the release remembered: "1080p HEVC · same release".
    static func versionLine(resume rule: UpNextResume.Rule, label: String) -> String {
        let label = label.isEmpty ? "?" : label
        return String(format: (rule == .samePack ? "UpNext.SamePack" : "UpNext.SameRelease").localized, label)
    }

    /// "S1 · E3 — Title" ("S1 · É3 — Titre").
    static func episodeTitle(_ episode: Episode) -> String {
        let title = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(format: "UpNext.EpisodeTitle".localized, episode.season, episode.episode, title.isEmpty ? "" : title)
            .trimmingCharacters(in: CharacterSet(charactersIn: " —-"))
    }
}

/// What a card shows: the same model for the Apple TV cards (native and
/// VLC players) and `UpNextCardView` (iPhone / iPad, Mac).
struct UpNextCardState: Equatable {
    typealias Kind = UpNextCountdown.Card.Kind

    let kind: Kind
    /// The next episode's id.
    let episodeID: String
    /// "Next episode", "Episode finished", "Still watching?".
    let headline: String
    /// "S1 · E3 — Title".
    let title: String
    let showTitle: String?
    /// "1080p HEVC · same pack", "Finding the version…"; nil: no line.
    let versionLine: String?
    /// The episode's still, else the show's backdrop.
    let imageURL: URL?
    /// Whole seconds before it starts on its own; nil: it does not.
    let secondsLeft: Int?
    /// The countdown's full length, for a ring.
    let total: Int?
    /// "Plays automatically in 12 s"; nil without a countdown.
    var countdownText: String? {
        secondsLeft.map { String(format: "UpNext.Countdown".localized, $0) }
    }
    /// 0…1 of the countdown elapsed (a ring), nil without one.
    var progress: Double? {
        guard let left = secondsLeft, let total = total, total > 0 else { return nil }
        return min(1, max(0, 1 - Double(left) / Double(total)))
    }
    /// The « Still watching? » message ("3 episodes in a row…").
    let message: String?

    /// The buttons' titles.
    var playNowTitle: String { kind == .stillWatching ? "UpNext.StillWatching.Continue".localized : "UpNext.PlayNow".localized }
    var cancelTitle: String { kind == .stillWatching ? "UpNext.StillWatching.Stop".localized : "UpNext.Cancel".localized }
    var backToVideoTitle: String { "UpNext.BackToVideo".localized }
    var chooseVersionTitle: String { "UpNext.ChooseVersion".localized }

    /// VoiceOver: one sentence.
    var accessibilityLabel: String {
        [headline, showTitle, title, versionLine, countdownText, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

@MainActor
final class UpNextSession: ObservableObject {

    /// What the platform does for the session (see the top of this file).
    struct Host {
        var startNext: (UpNextPlan) -> Bool
        var fallBack: (Episode) -> Void
        var chooseVersion: (UpNextPlan) -> Void
        var closePlayer: () -> Void
        /// Source keys the chooser leaves out (tvOS: the sources of
        /// `AppDelegate` that did not answer).
        var excludedSourceKeys: () -> Set<String> = { [] }

        init(startNext: @escaping (UpNextPlan) -> Bool, fallBack: @escaping (Episode) -> Void,
             chooseVersion: @escaping (UpNextPlan) -> Void, closePlayer: @escaping () -> Void,
             excludedSourceKeys: @escaping () -> Set<String> = { [] }) {
            self.startNext = startNext
            self.fallBack = fallBack
            self.chooseVersion = chooseVersion
            self.closePlayer = closePlayer
            self.excludedSourceKeys = excludedSourceKeys
        }
    }

    /// Everything the session reads from the world (the tests replace it).
    struct Environment {
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        /// Runs `block` every `interval` seconds on the main thread until the
        /// returned cancel is called.
        var every: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { interval, block in
            let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { block() } }
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        }
        /// The episode's sources (EpisodeSourceResolver: 10 min cache, joined requests).
        var resolveSources: (Episode, @escaping (EpisodeSourceResolver.Sources) -> Void) -> Void = { episode, completion in
            guard let showID = episode.show?.id else { return completion(EpisodeSourceResolver.Sources()) }
            EpisodeSourceResolver.shared.resolve(showId: showID, showTitle: episode.show?.title, season: episode.season,
                                                 episode: episode.episode,
                                                 isEnough: { $0.count > 0 && $0.awaited.isEmpty },
                                                 completion: completion)
        }
        var prefetchSubtitles: (Episode) -> Void = { SubtitleSearch.shared.prefetch(for: $0, showId: $0.show?.id) }
        var knownSubtitles: (Episode) -> [Subtitle]? = { SubtitleSearch.shared.answer(for: $0, showId: $0.show?.id) }
        var packFiles: (String) -> PackFiles? = { PlaybackReleaseRegistry.packFiles(forLink: $0) }
        var autoAdvance: () -> Bool = { UpNextPreferences.autoPlayNext }
        var qualityAlwaysAsks: () -> Bool = { UpNextPreferences.qualityAlwaysAsks }
        /// What the native player reads here (native first).
        var capabilities: () -> PlaybackCapabilities.Snapshot = { PlaybackCapabilities.current }
        var tuning: UpNextCountdown.Tuning = .standard
        var log: (String) -> Void = { print($0) }
        var date: () -> Date = Date.init

        /// The app's: the clocks, the resolver, the settings — and the DEBUG
        /// bench's tuning (`-PTDebugUpNextCardAt`, `-PTDebugUpNextStillAfter`).
        static var live: Environment {
            var environment = Environment()
            #if DEBUG
            environment.tuning = UpNextDebugHooks.tuning(environment.tuning)
            #endif
            return environment
        }
    }

    /// The session of the playback in progress (one at a time).
    private(set) static var current: UpNextSession?
    /// Episodes chained by the countdown alone in a row, per show (decision D6).
    private static var chain: (showID: String, count: Int)?

    let episode: Episode
    let next: Episode
    let playing: Torrent?
    @Published private(set) var card: UpNextCardState?
    @Published private(set) var plan: UpNextPlan?

    private var countdown: UpNextCountdown
    private let host: Host
    private let environment: Environment
    private var stopTimer: (() -> Void)?
    private var prefetchedAt: TimeInterval?
    private var isOver = false
    private var lastPhase: UpNextCountdown.Phase = .idle
    #if DEBUG
    private var debugAnswerScheduled = false
    #endif

    /// The session of `episode`'s playback, made current (the previous one
    /// ends). nil — the player then does what it did before 5.3 — for a
    /// movie, the last episode, a special, an episode whose next one cannot
    /// be played yet, a show whose guide is not loaded.
    ///
    /// - Parameters:
    ///   - playing: the release playing (default: the stream's context, else
    ///     the one noted for the episode).
    ///   - streamer: the stream (its `PlaybackStreamContext` names the release).
    static func begin(episode: Episode, playing: Torrent? = nil, streamer: PTTorrentStreamer? = nil, host: Host,
                      environment: Environment = .live) -> UpNextSession? {
        current?.end(reason: "another playback")
        guard let show = episode.show, episode.season >= 0, episode.episode > 0 else { return nil }
        let number = EpisodeNumber(season: episode.season, episode: episode.episode)
        guard let nextNumber = UpNextPlanner.episode(after: number, guide: show.guideEpisodes, now: environment.date())?.number,
              var next = show.episodes.first(where: { $0.season == nextNumber.season && $0.episode == nextNumber.episode }) else {
            environment.log("[UpNext] \(Self.name(number)) of \(show.id): no next episode to offer")
            return nil
        }
        next.show = show
        let chained = chain?.showID == show.id ? chain?.count ?? 0 : 0
        let release = playing ?? PlaybackStreamContext.of(streamer)?.torrent ?? PlaybackReleaseRegistry.torrent(for: episode.id)
        let session = UpNextSession(episode: episode, next: next, playing: release, chained: chained, host: host,
                                    environment: environment)
        current = session
        environment.log("[UpNext] begin \(Self.name(number)) → \(Self.name(nextNumber)) of \(show.id), autoplay "
                        + "\(session.countdown.autoAdvance ? "on" : "off"), chained \(chained)"
                        + (release.map { ", playing \($0.quality ?? "?")" } ?? ""))
        session.stopTimer = environment.every(1) { [weak session] in session?.clockTick() }
        session.planSamePackIfKnown()
        return session
    }

    private init(episode: Episode, next: Episode, playing: Torrent?, chained: Int, host: Host, environment: Environment) {
        self.episode = episode
        self.next = next
        self.playing = playing
        self.host = host
        self.environment = environment
        countdown = UpNextCountdown(autoAdvance: environment.autoAdvance(), chainedWithoutAction: chained,
                                    tuning: environment.tuning)
    }

    deinit {
        stopTimer?()
    }

    // MARK: What the player calls

    /// The player's 1 Hz clock: `position` / `duration` in seconds of the
    /// file (`duration` nil while not known — a remux still writing an EVENT
    /// playlist passes its `totalDurationSeconds` when > 0, else nil: the card
    /// then comes after the file, never on a guessed length); `isPlaying`:
    /// the user wants playback (false only for the user's own pause).
    func tick(position: Double, duration: Double?, isPlaying: Bool) {
        guard !isOver else { return }
        handle(countdown.tick(now: environment.now(), position: position, duration: duration, isPlaying: isPlaying))
    }

    /// The file ended. True: the session handles the end (after-play card,
    /// start, or the player's close through `Host.closePlayer`) — the player
    /// must not close or loop by itself; false: do as before.
    @discardableResult
    func itemEnded() -> Bool {
        guard !isOver, countdown.phase != .closed else { return false }
        environment.log("[UpNext] file ended (phase \(countdown.phase))")
        handle(countdown.itemEnded(now: environment.now()))
        return true
    }

    /// The user left the player: nothing starts, and the count of episodes
    /// chained with no action starts again (a later playback of the show is
    /// the user's own).
    func playerClosed() {
        guard !isOver else { return }
        countdown.closed()
        UpNextSession.resetChain(of: episode)
        end(reason: "player closed")
    }

    /// « Play Now » (and « Continue » on « Still watching? »).
    func accept() {
        guard !isOver else { return }
        environment.log("[UpNext] outcome accepted")
        handle(countdown.accept(now: environment.now()))
    }

    /// « Cancel » / « Back to the Video » (and « Stop » on « Still watching? »).
    func cancel() {
        guard !isOver else { return }
        environment.log("[UpNext] outcome cancelled")
        handle(countdown.cancel(now: environment.now()))
    }

    /// « Choose Version ».
    func chooseVersion() {
        guard !isOver else { return }
        environment.log("[UpNext] outcome choose version")
        handle(countdown.choose(now: environment.now()))
    }

    /// The chooser's pick: it starts.
    func chose(_ torrent: Torrent) {
        guard !isOver else { return }
        var chosen = plan ?? UpNextPlan(episode: next, torrent: nil, sources: [], rule: .none, reasons: [], subtitles: nil,
                                        needsChooser: false)
        chosen.torrent = torrent
        chosen.needsChooser = false
        chosen.reasons = ["chosen: \(torrent.quality ?? "?")"]
        plan = chosen
        handle(countdown.chose(now: environment.now()))
    }

    /// The chooser was left without a pick.
    func choiceCancelled() {
        guard !isOver else { return }
        environment.log("[UpNext] chooser left without a pick")
        handle(countdown.choiceCancelled(now: environment.now()))
    }

    // MARK: The plan

    /// The release played is a season pack whose file list holds the next
    /// episode: the plan is that pack, at once (the sources are still asked
    /// at `prefetchAt`, for another source and the fallback). A pack only
    /// VLC plays is planned too (nothing else is known yet), but the
    /// sources decide when they come: native first (`sourcesArrived`).
    private func planSamePackIfKnown() {
        guard plan == nil, let playing = playing, let files = environment.packFiles(playing.url), files.isMultiFile else { return }
        let number = EpisodeNumber(season: next.season, episode: next.episode)
        let choice = UpNextPlanner.continuity(playing: playing, packFiles: files, next: number, candidates: [],
                                              capabilities: environment.capabilities())
        guard choice.rule == .samePack else { return }
        adopt(choice, sources: [], elapsed: nil)
    }

    private func prefetch() {
        prefetchedAt = environment.now()
        environment.log("[UpNext] prefetch \(Self.name(next)): sources, subtitles")
        environment.prefetchSubtitles(next)
        planSamePackIfKnown()
        environment.resolveSources(next) { [weak self] sources in
            MainActor.assumeIsolated { self?.sourcesArrived(sources) }
        }
    }

    private func sourcesArrived(_ sources: EpisodeSourceResolver.Sources) {
        guard !isOver else { return }
        let candidates = sources.merged(withBase: next.torrents, runtime: Torrent.mediaRuntime(of: next))
        let elapsed = prefetchedAt.map { environment.now() - $0 }
        if var known = plan, known.rule == .samePack, !packPlaysThroughVLC {
            // The pack stays; the list is the next stream's other releases.
            known.sources = candidates
            plan = known
            environment.log("[UpNext] sources of \(Self.name(next)) in: \(candidates.count) release(s), same pack kept")
            return
        }
        // (A pack only VLC plays: the planner looks at the releases now —
        // a native one goes first, else the pack again.)
        let number = EpisodeNumber(season: next.season, episode: next.episode)
        let choice: UpNextChoice
        if let playing = playing {
            choice = UpNextPlanner.continuity(playing: playing, packFiles: environment.packFiles(playing.url), next: number,
                                              candidates: candidates, excluded: host.excludedSourceKeys(),
                                              capabilities: environment.capabilities())
        } else {
            let pool = candidates.filter { !host.excludedSourceKeys().contains(MagnetLink.sourceKey(of: $0.url)) }
            choice = UpNextChoice(torrent: Torrent.balancedPick(from: pool), rule: pool.isEmpty ? .none : .balanced,
                                  reasons: ["release played unknown"])
        }
        adopt(choice, sources: candidates, elapsed: elapsed)
    }

    /// The release played is a pack that only VLC plays (DTS / TrueHD only,
    /// AVI, penalized): `ReleaseProfile.vlcOnlyReason`.
    private var packPlaysThroughVLC: Bool {
        guard let playing = playing else { return false }
        return ReleaseProfile(playing, isMultiFile: true, capabilities: environment.capabilities()).vlcOnlyReason != nil
    }

    private func adopt(_ choice: UpNextChoice, sources: [Torrent], elapsed: TimeInterval?) {
        let number = EpisodeNumber(season: next.season, episode: next.episode)
        let asks = environment.qualityAlwaysAsks()
        let needsChooser = choice.torrent == nil || (choice.rule == .balanced && asks)
        var reasons = choice.reasons
        if choice.rule == .balanced && asks { reasons.append("no clear continuity and « Always Ask »: the chooser") }
        plan = UpNextPlan(episode: next, torrent: choice.torrent, sources: sources, rule: choice.rule, reasons: reasons,
                          subtitles: nil, needsChooser: needsChooser)
        environment.log(UpNextChoice(torrent: choice.torrent, rule: choice.rule, reasons: reasons).logLine(next: number, elapsed: elapsed))
        if choice.torrent == nil {
            handle(countdown.planFailed(now: environment.now()))
        } else {
            handle(countdown.planReady(now: environment.now()))
        }
    }

    // MARK: Effects

    private func handle(_ effects: [UpNextCountdown.Effect]) {
        if countdown.phase != lastPhase {
            logPhase(from: lastPhase, to: countdown.phase)
            lastPhase = countdown.phase
        }
        for effect in effects {
            guard !isOver else { break }
            switch effect {
            case .prefetch:
                prefetch()
            case .start(let trigger):
                start(trigger)
            case .openChooser(.userAsked):
                let current = plan ?? UpNextPlan(episode: next, torrent: nil, sources: [], rule: .none, reasons: [],
                                                 subtitles: nil, needsChooser: true)
                environment.log("[UpNext] chooser on \(Self.name(next))" + (current.torrent.map { ", \($0.quality ?? "?") first" } ?? ""))
                host.chooseVersion(current)
            case .openChooser(.noPlan):
                fallBack("no plan in time")
            case .closePlayer:
                environment.log("[UpNext] the player closes (as before 5.3)")
                UpNextSession.resetChain(of: episode)
                end(reason: "closed at the end")
                host.closePlayer()
            }
        }
        refreshCard()
    }

    private func start(_ trigger: UpNextCountdown.Trigger) {
        guard var plan = plan, let torrent = plan.torrent, !plan.needsChooser else {
            fallBack(plan == nil ? "no plan" : "the chooser (\(plan?.rule.rawValue ?? "none"))")
            return
        }
        // Only a start of the plan's own release counts towards « Still
        // watching? » (D6): today's flow (the chooser) is the user's pick.
        UpNextSession.chain = (episode.show?.id ?? "", countdown.chainedAfterStart)
        plan.subtitles = environment.knownSubtitles(next)
        // The next stream knows the episode's other releases (another
        // source, a lighter one: `BandwidthDeficitMonitor`).
        if !plan.sources.isEmpty { PlaybackStreamContext.noteSources(plan.sources, forMediaID: next.id) }
        environment.log("[UpNext] start \(Self.name(next)) (\(trigger.rawValue)) rule=\(plan.rule.rawValue) "
                        + "torrent=\(torrent.quality ?? "?")" + (plan.subtitles.map { ", \($0.count) subtitle language(s) known" } ?? ""))
        end(reason: "started")
        if !host.startNext(plan) {
            environment.log("[UpNext] fallback \(Self.name(next)): the start was refused, today's flow")
            UpNextSession.resetChain(of: episode)
            host.fallBack(next)
        }
    }

    private func fallBack(_ reason: String) {
        environment.log("[UpNext] fallback \(Self.name(next)): \(reason) — playNext → chooseQuality")
        UpNextSession.resetChain(of: episode)
        end(reason: "fallback")
        host.fallBack(next)
    }

    /// Ends the session: no timer, no card, no more effects.
    private func end(reason: String) {
        guard !isOver else { return }
        isOver = true
        stopTimer?()
        stopTimer = nil
        if card != nil { card = nil }
        if UpNextSession.current === self { UpNextSession.current = nil }
        environment.log("[UpNext] end (\(reason))")
    }

    private func clockTick() {
        guard !isOver else { return }
        handle(countdown.clock(now: environment.now()))
    }

    private func refreshCard() {
        guard !isOver, let shown = countdown.card else {
            if card != nil { card = nil }
            return
        }
        let line: String?
        if let plan = plan {
            line = plan.versionLine
        } else {
            line = countdown.plan == .failed ? nil : "UpNext.FindingVersion".localized
        }
        let headline: String
        switch shown.kind {
        case .countdown: headline = "ContinueWatching.NextEpisode".localized
        case .postPlay: headline = "UpNext.Ended".localized
        case .stillWatching: headline = "UpNext.StillWatching".localized
        }
        let message = shown.kind == .stillWatching
            ? String(format: "UpNext.StillWatching.Message".localized, countdown.chainedWithoutAction) : nil
        let state = UpNextCardState(kind: shown.kind, episodeID: next.id, headline: headline,
                                    title: UpNextText.episodeTitle(next), showTitle: next.show?.title,
                                    versionLine: line, imageURL: imageURL, secondsLeft: shown.secondsLeft, total: shown.total,
                                    message: message)
        guard state != card else { return }
        if card?.kind != state.kind {
            environment.log("[UpNext] card shown: \(state.kind.rawValue)"
                            + (state.secondsLeft.map { ", \($0) s" } ?? ", no countdown") + (line.map { " — \($0)" } ?? ""))
            #if DEBUG
            if !debugAnswerScheduled {
                debugAnswerScheduled = true
                UpNextDebugHooks.scheduleAnswer(for: self)
            }
            #endif
        }
        card = state
    }

    /// The episode's still (metahub), else its own image, else the show's backdrop.
    private var imageURL: URL? {
        if let show = next.show, let url = LibraryArtwork.episodeStillURL(showID: show.id, EpisodeNumber(season: next.season, episode: next.episode)) {
            return url
        }
        return (next.largeBackgroundImage ?? next.show?.largeBackgroundImage).flatMap(URL.init(string:))
    }

    private func logPhase(from old: UpNextCountdown.Phase, to new: UpNextCountdown.Phase) {
        if old == .idle, new == .armed || new == .preparing || new == .offered {
            environment.log("[UpNext] armed \(Self.name(episode)) → \(Self.name(next)): prefetch at "
                            + "\(Int(countdown.prefetchAt ?? -1)) s, card at \(Int(countdown.cardAt ?? -1)) s "
                            + "(duration \(Int(countdown.duration ?? -1)) s)")
        }
        if case .stillWatching = new {
            environment.log("[UpNext] still watching? after \(countdown.chainedWithoutAction) episodes chained with no action")
        }
    }

    /// The next playback of `episode`'s show starts a new count (D6).
    private static func resetChain(of episode: Episode) {
        if chain?.showID == episode.show?.id { chain = nil }
    }

    private static func name(_ number: EpisodeNumber) -> String {
        String(format: "S%02dE%02d", number.season, number.episode)
    }

    private static func name(_ episode: Episode) -> String {
        name(EpisodeNumber(season: episode.season, episode: episode.episode))
    }
}
