//
//  UserNavigation.swift
//  PopcornKit
//
//  Where the user asked the native player to go, when the player does not show it (yet).
//
//  Why (Apple TV, 15 November 2026, 5.3.0 m1-gate): a film resumed natively, paused, then taken
//  back ten minutes with the Siri Remote — into the segments the resume's jump skipped. The
//  conversion never jumped there: every decision rested on `player.currentTime()`, which on the
//  device kept the time from before AVKit's seek while that seek was held. AVPlayer's request for
//  the skipped segment timed out (-12889) and the recovery started at the OLD position, waiting
//  for a Play press, under a silent spinner. What the app knows for certain instead: the target
//  AVKit hands its delegate (tvOS), and the request AVPlayer sends for a segment behind its
//  playhead (a seek: playback never reads backwards).
//

import Foundation

/// The position a user navigation asked for (pure — the tests drive it). The owner sets it when
/// it learns of a move it can trust — AVKit's `timeToSeekAfterUserNavigatedFrom` (tvOS), a
/// request for a hole behind the playhead — and takes `wanted(current:played:clock:)` as where the
/// player needs data, in place of `currentTime()` alone:
///  - `currentTime()` within `thresholdSeconds` of the target: the seek shows — `currentTime()`;
///  - `currentTime()` still where the move came from (`from`, give or take the threshold, plus
///    what playback at up to `maxRate` could have added since): the seek is pending and does not
///    show (what the Apple TV did) — the target;
///  - anywhere else: the user (or the player) went elsewhere since — the target is dropped;
///  - playback recorded since the target was set (`played` changed): it played somewhere, at the
///    target or not — the target is dropped.
public struct UserNavigationTarget: Equatable {
    /// How far (s) two positions may lie apart and still be the same
    /// (`StarvationPolicy.userSeekThresholdSeconds`).
    public static let thresholdSeconds: Double = 1
    /// Fastest playback rate AVKit offers (`PlayedPositionTracker.maxRate`).
    public static let maxRate: Double = 2

    /// The pending target (player timeline, s); nil when none.
    public private(set) var target: Double?
    /// Where the move came from (the player's time then); nil when unknown.
    public private(set) var from: Double?
    /// The target is the user's own word (AVKit's navigation delegate), not a guess from a request
    /// AVPlayer sent (`HoleRequestRule`): a guess never replaces it.
    public private(set) var isConfirmed = false
    /// Why `wanted(current:played:clock:)` last dropped a target (logs); nil when it dropped none
    /// since the last move.
    public private(set) var lastDrop: Drop?
    /// The target `wanted(current:played:clock:)` last dropped (logs: the line names the target
    /// really dropped, not one a log saw earlier); nil when none since the last move.
    public private(set) var lastDroppedTarget: Double?
    /// Drops so far (logs: each drop is told once).
    public private(set) var dropCount = 0
    private var playedAtTarget: Double?
    private var setAt: TimeInterval?

    /// Why a pending target was dropped.
    public enum Drop: String, Equatable {
        /// Playback ran since the move (at the target or not).
        case played = "playback ran since"
        /// `currentTime()` is neither at the target nor where the move came from: another move.
        case elsewhere = "the player went elsewhere"
    }

    public init() {}

    /// The user navigated from `from` to `target` (player timeline, s); `played` is the last
    /// position playback reached (`PlayedPositionTracker.lastPlayedTime`), `clock` a monotonic
    /// clock (s); `confirmed`: AVKit's navigation (see `isConfirmed`). A new move replaces the
    /// previous one. An unusable target changes nothing.
    public mutating func navigated(from: Double?, to target: Double, played: Double?, clock: TimeInterval,
                                   confirmed: Bool = true) {
        guard target.isFinite, target >= 0 else { return }
        self.target = target
        self.from = from.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        isConfirmed = confirmed
        lastDrop = nil
        lastDroppedTarget = nil
        playedAtTarget = played
        setAt = clock
    }

    /// Where a move AVKit reports as coming from `old` really comes from, the player reading
    /// `current` (`currentTime()`): a press made while the previous move is still held is counted
    /// by AVKit from that move's target (`old` within `thresholdSeconds` of `target`) while the
    /// player still reads where the previous move came from — that origin (`from`) is kept, so that
    /// the player's unchanged time is not taken for a move elsewhere (Apple TV, 16 November 2026: a
    /// second +10 s press while the first seek was held was dropped as « elsewhere »). Not when the
    /// previous seek already shows (`current` at its target: the player IS at `old`), and not
    /// without a known origin: `old` then.
    public func origin(ofMoveFrom old: Double?, current: Double?) -> Double? {
        guard let old = old, old.isFinite, let target = target, let from = from,
              abs(old - target) <= Self.thresholdSeconds else { return old }
        if let current = current, current.isFinite, abs(current - target) <= Self.thresholdSeconds { return old }
        return from
    }

    /// Forgets the target (a new item, a recovery that took it over).
    public mutating func clear() {
        target = nil
        from = nil
        isConfirmed = false
        playedAtTarget = nil
        setAt = nil
    }

    /// Seconds since the pending move was made (`clock` as in `navigated`); nil without one.
    public func age(clock: TimeInterval) -> TimeInterval? {
        guard target != nil, let setAt = setAt else { return nil }
        return max(0, clock - setAt)
    }

    /// Where the player needs data now (player timeline, s), from `current` (`currentTime()`),
    /// `played` and `clock` as in `navigated`. nil when neither is known.
    public mutating func wanted(current: Double?, played: Double?, clock: TimeInterval) -> Double? {
        let current = current.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard let target = target else { return current }
        if played != playedAtTarget {
            drop(.played)
            return current
        }
        guard let now = current else { return target }
        if abs(now - target) <= Self.thresholdSeconds { return now }
        guard let from = from else { return target }
        let elapsed = max(0, clock - (setAt ?? clock))
        if now >= from - Self.thresholdSeconds, now <= from + Self.thresholdSeconds + elapsed * Self.maxRate {
            return target
        }
        drop(.elsewhere)
        return current
    }

    private mutating func drop(_ reason: Drop) {
        let dropped = target
        clear()
        lastDrop = reason
        lastDroppedTarget = dropped
        dropCount += 1
    }
}

/// AVKit's navigation right after the player's item was replaced (a jump's or a recovery's new
/// item, pre-positioned then sought to its position): the transport bar may still count from the
/// new item's start (measured, tvOS 26.5 simulator, 20 quick presses during a jump wait: the press
/// after the replacement came as `0.0 → 10.0 s` while the player read 688.5 s, and the film went to
/// 0:20). Such a move is the same step from where the player is (pure — the tests drive it).
public enum NavigationRebase {
    /// How long after a replacement (s) a navigation from the item's start is suspect.
    public static let windowSeconds: TimeInterval = 10
    /// `old` this close to 0 (s) is the item's start.
    public static let startSeconds: Double = 0.5
    /// The player at least this far (s) from `old`: not where AVKit counts from.
    public static let minimumGapSeconds: Double = 5

    /// The target to seek to for a navigation `old` → `target` (player timeline, s) while the player
    /// reads `current`, `sinceReplacement` s after the last item replacement (nil: none). `target`
    /// itself unless the move counts from the new item's start while the player is elsewhere.
    public static func target(old: Double, target: Double, current: Double?, sinceReplacement: TimeInterval?) -> Double {
        guard let since = sinceReplacement, since >= 0, since <= windowSeconds,
              old.isFinite, target.isFinite, old >= 0, old <= startSeconds,
              let current = current, current.isFinite, current - old >= minimumGapSeconds else { return target }
        return max(0, current + (target - old))
    }
}

/// Episode chaining (5.3.0) meets a navigation the playhead does not show yet (pure — the tests
/// drive it). The end of the player's item tells the « next episode » countdown that the file is
/// over — which starts the next episode, or closes the player once the card was dismissed. It is
/// not the file's end when the user is elsewhere: while a recovery runs (a jump's wait keeps the
/// old item, at its rate, until a new one is put where the user went; a rebuild replaces it), or
/// while a navigation to well before the end is still pending (`UserNavigationTarget`).
public enum UpNextNavigationRule {
    /// A pending target this close to the file's length (s) or closer may be the end itself (the
    /// iPhone / iPad clock's own test, `UpNextRemuxClock`).
    public static let endZoneSeconds: Double = 60

    /// Whether an end of the player's item (`AVPlayerItemDidPlayToEndTime`, the stuck-at-the-end
    /// safety net) is the file's end: never while `isRecovering`; with a navigation pending to
    /// `pendingTarget` (player timeline, s), only when it lies within `endZoneSeconds` of
    /// `duration` (unknown length: the end counts, as before).
    public static func isFileEnd(isRecovering: Bool, pendingTarget: Double?, duration: Double?) -> Bool {
        guard !isRecovering else { return false }
        guard let target = pendingTarget, target.isFinite,
              let duration = duration, duration.isFinite, duration > 0 else { return true }
        return target >= duration - endZoneSeconds
    }
}

/// A request for a HOLE — a segment a jump of the conversion skipped, not on disk, still writable —
/// as the player's own word on where it wants to be (pure — the tests drive it). The server holds
/// such a request until the segment is written, and nothing writes it unless the conversion is
/// told the player is there: a player whose `currentTime()` does not show its pending seek would
/// wait for it until AVPlayer gives up (-12889).
public enum HoleRequestRule {
    /// Server side: the hole of segment `index` (a video segment) was requested and the request is
    /// held. It is a seek — not a prefetch — when it lies strictly behind the segment of the
    /// position last reported (`reportedSegment`, from `referencePosition`): AVPlayer never reads
    /// behind its playhead but after a seek. Never while nothing was played (`hasPlayed`: an item
    /// still loading at 0 before its resume seek asks for segments 1, 2… which a resume's jump
    /// skipped) nor under the start lock (`isStartLocked`: the resume's own seek).
    public static func isSeekBehind(index: Int, reportedSegment: Int?, hasPlayed: Bool, isStartLocked: Bool) -> Bool {
        guard hasPlayed, !isStartLocked, let reported = reportedSegment, index >= 0 else { return false }
        return index < reported
    }

    /// The position a held hole request is judged against (`isSeekBehind`'s `reportedSegment`): the
    /// lower of `played` and `wanted` — behind the playhead, not behind a target ahead of it (after a
    /// move forward, the holes between the old playhead and the target are no seek back). nil when
    /// neither is known.
    public static func referencePosition(played: Double?, wanted: Double?) -> Double? {
        [played, wanted].compactMap { $0 }.filter { $0.isFinite }.min()
    }

    /// Player side: the hole requested spans [`segmentStart`, `segmentEnd`) on the player's timeline;
    /// `wanted` is where the player is already known to want data. True when the request tells
    /// something new — `wanted` unknown or outside that span by more than
    /// `UserNavigationTarget.thresholdSeconds` (when it is inside, the conversion already heard).
    public static func movesPlayer(segmentStart: Double, segmentEnd: Double, wanted: Double?) -> Bool {
        guard segmentStart.isFinite, segmentStart >= 0 else { return false }
        guard let wanted = wanted, wanted.isFinite else { return true }
        let end = segmentEnd.isFinite ? max(segmentEnd, segmentStart) : segmentStart
        let slack = UserNavigationTarget.thresholdSeconds
        return wanted < segmentStart - slack || wanted > end + slack
    }
}
