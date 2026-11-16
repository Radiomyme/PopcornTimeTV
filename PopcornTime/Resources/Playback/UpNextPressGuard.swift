import Foundation

// Episode chaining (5.3.0): what accepted the next episode, and the Apple TV
// card's guard against a press that was meant for the player.
//
// On the device, the next episode started the instant the card appeared
// while the viewer was pressing "+10 s" about once a second: the focus lands
// on « Play Now », and a click already on its way reached the card. The
// Apple TV cards (AVKit's proposal, the overlay) therefore ignore « Play Now »
// / « Continue » during their first second on screen, counted from
// `viewDidAppear` (a press during the presentation, before it, is refused
// too). Menu / Back and « Back to the Video » are never delayed, nor is
// AVKit's own `didAccept`. iPhone / iPad and Mac cards are touched or
// clicked on purpose: no guard there.

/// The one-second rule (pure).
enum UpNextPressGuard {
    /// How long the card is on screen before « Play Now » counts: 1 s
    /// (DEBUG: `-PTDebugUpNextPressGuard <s>`, the UI tests' slow presses).
    static var minimumOnScreen: TimeInterval {
        #if DEBUG
        if let seconds = UserDefaults.standard.string(forKey: "PTDebugUpNextPressGuard").flatMap(Double.init), seconds >= 0 {
            return seconds
        }
        #endif
        return 1.0
    }

    /// Whether a press at `now` counts, the card having appeared at
    /// `appearedAt` (nil: not on screen yet — refused).
    static func accepts(appearedAt: TimeInterval?, now: TimeInterval, minimum: TimeInterval = minimumOnScreen) -> Bool {
        guard let appearedAt = appearedAt else { return false }
        return now - appearedAt >= minimum
    }

    /// How long the card has been up at `now` (nil: not on screen yet).
    static func cardUp(appearedAt: TimeInterval?, now: TimeInterval) -> TimeInterval? {
        appearedAt.map { max(0, now - $0) }
    }

    /// "0.3 s", or "not on screen yet".
    static func cardUpText(_ seconds: TimeInterval?) -> String {
        seconds.map { String(format: "%.1f s", $0) } ?? "not on screen yet"
    }

    /// The line a refused press prints: "[UpNext] Play Now ignored: card up 0.3 s".
    static func ignoredLine(button: String, cardUp: TimeInterval?) -> String {
        "[UpNext] \(button) ignored: card up \(cardUpText(cardUp))"
    }

    /// A press on « Play Now » / « Continue » at `now`: the card's time on
    /// screen when it counts; nil (and the line above, through `log`) when
    /// it comes too soon.
    static func check(appearedAt: TimeInterval?, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                      button: String, log: (String) -> Void = { print($0) }) -> TimeInterval? {
        let up = cardUp(appearedAt: appearedAt, now: now)
        guard accepts(appearedAt: appearedAt, now: now), let seconds = up else {
            log(ignoredLine(button: button, cardUp: up))
            return nil
        }
        return seconds
    }
}

/// What accepted the next episode (`UpNextSession.accept(source:)`), for its
/// log line: "[UpNext] outcome accepted (Play Now, card up 12.4 s)".
enum UpNextAcceptSource: Equatable {
    /// « Play Now » / « Continue » on AVKit's proposal (Apple TV, native
    /// player), with its time on screen.
    case playNow(cardUp: TimeInterval?)
    /// AVKit's own `didAccept` (its automatic acceptance is off: NaN).
    case avkit(cardUp: TimeInterval?)
    /// « Play Now » / « Continue » on the overlay card (Apple TV: after the
    /// file, « Still watching? », the VLC player, a proposal AVKit did not show).
    case overlay(cardUp: TimeInterval?)
    /// The DEBUG scripted answer (`-PTDebugUpNextAnswer`).
    case debug
    /// The iPhone / iPad or Mac card's button (or its Return key).
    case cardButton

    /// "Play Now, card up 12.4 s"; `sessionCardUp`: how long the session's
    /// card has been published, used when the screen gave no time.
    func logText(sessionCardUp: TimeInterval?) -> String {
        func up(_ seconds: TimeInterval?) -> String {
            seconds.map { String(format: ", card up %.1f s", $0) } ?? ""
        }
        switch self {
        case .playNow(let seconds): return "Play Now" + up(seconds ?? sessionCardUp)
        case .avkit(let seconds): return "AVKit didAccept" + up(seconds ?? sessionCardUp)
        case .overlay(let seconds): return "overlay" + up(seconds ?? sessionCardUp)
        case .debug: return "debug" + up(sessionCardUp)
        case .cardButton: return "card button" + up(sessionCardUp)
        }
    }
}
