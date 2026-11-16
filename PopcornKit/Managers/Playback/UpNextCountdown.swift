import Foundation

/// The « next episode » card of one playback, as a state machine (pure: the
/// clock is the `now` each call passes, monotonic seconds). The app's
/// `UpNextSession` feeds it what the player reports and carries out the
/// effects it returns; the card to show is `card`.
///
/// ```
/// idle ──(duration known)──▶ armed
/// armed ──(position ≥ prefetchAt)──▶ preparing          effect: prefetch
/// preparing ──planReady──▶ ready
/// armed|preparing|ready ──(position ≥ cardAt)──▶ offered  card: countdown to the end of the file
/// offered ──accept | end of the file──▶ starting         effect: start (plan awaited planWait s, else chooser)
/// offered ──cancel──▶ dismissed                          no card again; the end closes the player as before
/// offered ──choose──▶ choosing                           effect: chooser (playback goes on)
/// armed|preparing|ready ──itemEnded──▶ postPlay(10 s)     (no duration: EVENT playlist, VLC)
/// postPlay ──accept | 10 s──▶ starting ; ──cancel──▶ closed (effect: closePlayer)
/// offered ──(rewind before cardAt)──▶ ready|preparing    the card goes
/// any ──closed──▶ closed
/// ```
/// - `prefetchAt` = the earlier of 90 % and `duration − 300 s`; `cardAt` =
///   `duration − 30 s` (decision D7, the three platforms).
/// - The setting « Autoplay next episode » off: the card has no countdown,
///   nothing starts on its own.
/// - The countdown of `offered` is the file's own time: a pause freezes it.
/// - « Still watching? » (decision D6): after `stillWatchingAfter` episodes
///   started by the countdown in a row with no action from the user, the
///   end of the next one asks instead of starting.
public struct UpNextCountdown: Equatable {

    public struct Tuning: Equatable {
        public var prefetchFraction = 0.9
        public var prefetchLead: TimeInterval = 300
        public var cardLead: TimeInterval = 30
        /// The after-play card's countdown.
        public var postPlaySeconds: TimeInterval = 10
        /// How long an accepted card waits for its plan before the chooser.
        public var planWait: TimeInterval = 3
        /// Episodes started by the countdown alone before « Still watching? ».
        public var stillWatchingAfter = 3
        /// The card at this position (seconds) instead of `duration − cardLead`
        /// (DEBUG `-PTDebugUpNextCardAt`, short test episodes).
        public var cardAtOverride: TimeInterval?
        /// Within this of the end, the file is over.
        public var endTolerance: TimeInterval = 0.75

        public init() {}

        public static let standard = Tuning()
    }

    public enum Phase: Equatable {
        case idle, armed, preparing, ready, offered
        case postPlay(until: TimeInterval?)
        /// Accepted (or due) before the plan was in: the chooser at `until`.
        case awaitingPlan(until: TimeInterval)
        case stillWatching
        case choosing
        case starting
        case dismissed
        case closed
    }

    public enum Trigger: String {
        /// « Play Now », or « Continue » on « Still watching? ».
        case accepted
        /// The countdown ran out.
        case deadline
        /// A release picked in the chooser.
        case chosen
    }

    public enum ChooserReason: String {
        /// « Choose Version ».
        case userAsked
        /// No plan, or none in time.
        case noPlan
    }

    public enum Effect: Equatable {
        /// Ask the next episode's sources and subtitles now.
        case prefetch
        /// Start the next episode (`trigger` says why).
        case start(Trigger)
        /// Open the chooser on the next episode.
        case openChooser(ChooserReason)
        /// Close the player, as at the end of an episode before 5.3.
        case closePlayer
    }

    public enum PlanState: Equatable { case pending, ready, failed }

    /// What the card shows.
    public struct Card: Equatable {
        public enum Kind: String { case countdown, postPlay, stillWatching }
        public let kind: Kind
        /// Whole seconds before it starts on its own; nil: it does not.
        public let secondsLeft: Int?
        /// The countdown's full length (for a ring).
        public let total: Int?
    }

    public private(set) var phase: Phase = .idle
    public private(set) var plan: PlanState = .pending
    /// The user did something (accept, cancel, choose, pause, rewind): this
    /// episode was not chained « with no action ».
    public private(set) var sawActivity = false
    public private(set) var prefetchAt: TimeInterval?
    public private(set) var cardAt: TimeInterval?
    public private(set) var duration: TimeInterval?
    public private(set) var position: TimeInterval = 0
    /// The file played to its end.
    public private(set) var reachedEnd = false
    /// Why `starting` was entered (or is awaited).
    public private(set) var trigger: Trigger?
    /// Read by `card`.
    private var now: TimeInterval = 0

    public let autoAdvance: Bool
    /// Episodes started by the countdown alone just before this one.
    public let chainedWithoutAction: Int
    public let tuning: Tuning

    public init(autoAdvance: Bool, chainedWithoutAction: Int = 0, tuning: Tuning = .standard) {
        self.autoAdvance = autoAdvance
        self.chainedWithoutAction = chainedWithoutAction
        self.tuning = tuning
    }

    /// The card to show now; nil: none.
    public var card: Card? {
        func countdown(_ left: Int?) -> Card {
            guard autoAdvance, let duration = duration else { return Card(kind: .countdown, secondsLeft: nil, total: nil) }
            let total = Int((duration - (cardAt ?? duration)).rounded(.up))
            return Card(kind: .countdown, secondsLeft: left ?? max(0, Int((duration - position).rounded(.up))), total: max(total, 1))
        }
        switch phase {
        case .offered:
            return countdown(nil)
        case .awaitingPlan:
            // Accepted or due, the plan not in yet: the card stays, at 0.
            if postPlayShown { return Card(kind: .postPlay, secondsLeft: 0, total: Int(tuning.postPlaySeconds)) }
            return cardWasShown ? countdown(0) : nil
        case .postPlay(let until):
            guard autoAdvance, let until = until else { return Card(kind: .postPlay, secondsLeft: nil, total: nil) }
            return Card(kind: .postPlay, secondsLeft: max(0, Int((until - now).rounded(.up))), total: Int(tuning.postPlaySeconds))
        case .stillWatching:
            return Card(kind: .stillWatching, secondsLeft: nil, total: nil)
        default:
            return nil
        }
    }

    /// Whether the card (countdown) was up when `awaitingPlan` began.
    private var cardWasShown = false
    /// Whether the after-play card was up when `awaitingPlan` began.
    private var postPlayShown = false

    // MARK: Events

    /// The player's clock (about once a second): `position` and `duration`
    /// in seconds of the file (nil: not known yet — an EVENT playlist, VLC
    /// before it knows); `isPlaying`: the user wants playback (false only
    /// for a pause the user asked for, not a stall).
    public mutating func tick(now: TimeInterval, position: TimeInterval, duration: TimeInterval?, isPlaying: Bool) -> [Effect] {
        self.now = now
        let previous = self.position
        if position.isFinite, position >= 0 { self.position = position }
        if !isPlaying { sawActivity = true }
        if let duration = duration, duration.isFinite, duration > 1 {
            arm(duration)
        }
        var effects: [Effect] = []
        switch phase {
        case .idle:
            break
        case .armed, .preparing, .ready:
            effects += prefetchIfDue()
            if let cardAt = cardAt, self.position >= cardAt {
                phase = .offered
            }
            if isAtEnd { effects += fileEnded() }
        case .offered:
            if let cardAt = cardAt, self.position < cardAt - 1 {
                // Rewound before the card: it goes, and comes back there.
                sawActivity = true
                phase = plan == .ready ? .ready : .preparing
            } else if isAtEnd {
                effects += fileEnded()
            } else if self.position + 2 < previous {
                sawActivity = true
            }
        case .postPlay, .awaitingPlan, .stillWatching, .choosing, .starting, .dismissed, .closed:
            effects += clock(now: now)
        }
        return effects
    }

    /// The wall clock alone (the session's own timer, about once a second:
    /// a player may stop ticking once its file is over).
    public mutating func clock(now: TimeInterval) -> [Effect] {
        self.now = now
        switch phase {
        case .postPlay(let until?) where until <= now:
            return due(.deadline)
        case .awaitingPlan(let until) where until <= now:
            phase = .choosing
            return [.openChooser(.noPlan)]
        default:
            return []
        }
    }

    /// The file is over (`AVPlayerItemDidPlayToEndTime`, VLC's end).
    public mutating func itemEnded(now: TimeInterval) -> [Effect] {
        self.now = now
        return fileEnded()
    }

    /// The next episode's plan is in.
    public mutating func planReady(now: TimeInterval) -> [Effect] {
        self.now = now
        plan = .ready
        switch phase {
        case .armed, .preparing: phase = .ready; return []
        case .awaitingPlan:
            phase = .starting
            return [.start(trigger ?? .accepted)]
        default: return []
        }
    }

    /// No plan can be made (no release, the sources failed).
    public mutating func planFailed(now: TimeInterval) -> [Effect] {
        self.now = now
        plan = .failed
        if case .awaitingPlan = phase {
            phase = .choosing
            return [.openChooser(.noPlan)]
        }
        if phase == .preparing { phase = .ready }
        return []
    }

    /// « Play Now » (or « Continue » on « Still watching? »).
    public mutating func accept(now: TimeInterval) -> [Effect] {
        self.now = now
        switch phase {
        case .offered, .postPlay, .stillWatching:
            sawActivity = true
            return start(.accepted)
        default:
            return []
        }
    }

    /// « Cancel » / « Back to the Video » / « Stop » on « Still watching? ».
    public mutating func cancel(now: TimeInterval) -> [Effect] {
        self.now = now
        sawActivity = true
        switch phase {
        case .offered:
            phase = .dismissed
            return []
        case .awaitingPlan where !reachedEnd:
            phase = .dismissed
            return []
        case .postPlay, .stillWatching, .awaitingPlan:
            phase = .closed
            return [.closePlayer]
        default:
            return []
        }
    }

    /// « Choose Version »: the chooser on the next episode.
    public mutating func choose(now: TimeInterval) -> [Effect] {
        self.now = now
        switch phase {
        case .offered, .postPlay, .stillWatching, .ready, .preparing, .armed:
            sawActivity = true
            phase = .choosing
            return [.openChooser(.userAsked)]
        default:
            return []
        }
    }

    /// A release was picked in the chooser: it starts.
    public mutating func chose(now: TimeInterval) -> [Effect] {
        self.now = now
        guard phase == .choosing else { return [] }
        trigger = .chosen
        phase = .starting
        return [.start(.chosen)]
    }

    /// The chooser was left without a pick: no card again; at the end of
    /// the file (or past it) the player closes.
    public mutating func choiceCancelled(now: TimeInterval) -> [Effect] {
        self.now = now
        guard phase == .choosing else { return [] }
        if reachedEnd {
            phase = .closed
            return [.closePlayer]
        }
        phase = .dismissed
        return []
    }

    /// The player closed (the user left it): nothing starts.
    public mutating func closed() {
        phase = .closed
    }

    // MARK: Rules

    private mutating func arm(_ duration: TimeInterval) {
        guard self.duration != duration else { return }
        self.duration = duration
        let card = tuning.cardAtOverride.map { min($0, duration) } ?? max(0, duration - tuning.cardLead)
        cardAt = card
        prefetchAt = min(max(0, min(duration * tuning.prefetchFraction, duration - tuning.prefetchLead)), card)
        if phase == .idle { phase = .armed }
    }

    private var isAtEnd: Bool {
        guard let duration = duration else { return false }
        return position >= duration - tuning.endTolerance
    }

    private mutating func prefetchIfDue() -> [Effect] {
        guard phase == .armed, let prefetchAt = prefetchAt, position >= prefetchAt else { return [] }
        phase = plan == .ready ? .ready : .preparing
        return [.prefetch]
    }

    /// The end of the file, whatever reported it.
    private mutating func fileEnded() -> [Effect] {
        let first = !reachedEnd
        reachedEnd = true
        switch phase {
        case .idle, .armed, .preparing, .ready:
            // No card was up (no duration, or a jump to the end).
            let needsPrefetch = phase == .idle || phase == .armed
            phase = .postPlay(until: autoAdvance ? now + tuning.postPlaySeconds : nil)
            return needsPrefetch && plan == .pending ? [.prefetch] : []
        case .offered:
            guard autoAdvance else {
                phase = .postPlay(until: nil)
                return []
            }
            return due(.deadline)
        case .dismissed:
            // Today's end: the player closes.
            if first {
                phase = .closed
                return [.closePlayer]
            }
            return []
        default:
            return []
        }
    }

    /// The countdown ran out.
    private mutating func due(_ trigger: Trigger) -> [Effect] {
        if trigger == .deadline, chainedWithoutAction >= tuning.stillWatchingAfter {
            phase = .stillWatching
            return []
        }
        return start(trigger)
    }

    private mutating func start(_ trigger: Trigger) -> [Effect] {
        self.trigger = trigger
        switch plan {
        case .ready:
            phase = .starting
            return [.start(trigger)]
        case .failed:
            phase = .choosing
            return [.openChooser(.noPlan)]
        case .pending:
            cardWasShown = phase == .offered
            if case .postPlay = phase { postPlayShown = true } else { postPlayShown = false }
            phase = .awaitingPlan(until: now + tuning.planWait)
            return []
        }
    }

    /// Episodes chained « with no action » once this one has started the
    /// next: one more when the countdown started it untouched, else 0.
    public var chainedAfterStart: Int {
        return trigger == .deadline && !sawActivity ? chainedWithoutAction + 1 : 0
    }
}
