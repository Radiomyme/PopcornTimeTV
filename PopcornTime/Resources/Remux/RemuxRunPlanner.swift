

import Foundation

/// Where the remux's one pass goes next (pure): `RemuxPlayback.tick` asks before every pump
/// step. The session (`MKVToHLSRemuxSession`) reads the file in order and writes the segment
/// at its cursor; `jump(toSegment:)` moves that pass to any segment of the keyframe-index
/// plan. This decides when it moves.
///
/// Three kinds of segment below the high-water mark (1 + the highest index ever published):
/// one that exists; a HOLE, which a jump skipped and a pass may still write; a PRUNED one,
/// gone for good (`RemuxPlayback.prunedIndexes`). "Writable" below means a hole, or any index
/// from the high-water mark on — never a pruned one.
///
/// Without holes and without the ability to jump, `step` is exactly the rule the pump had
/// before the session could jump: hold at the lookahead limit of the anchor, else pump at most
/// two segments, never past that limit (RemuxRunPlannerTests checks it on random states).
enum RemuxRunPlanner {

    /// Why the pass moves (the `[Resume]` log names it).
    enum Reason: String {
        /// The resume the user accepted (`RemuxPlayback.commitResume`).
        case resume
        /// The player wants a position the pass can't reach quickly in file order.
        case farSeek
        /// The player wants a hole behind the pass.
        case rewind
        /// Bounded storage: a jump is undone, the pass goes back to where it was.
        case revert
        /// Nothing is left to write between the pass and what is needed: over what exists.
        case skipExisting
        /// The owner asked (`RemuxPlayback.requestJump`).
        case requested
    }

    enum Step: Equatable {
        /// Nothing to write for now. Counts as held at the lookahead limit, never as an idle
        /// tick: it says nothing about the input being exhausted.
        case hold
        case pump(maxNewSegments: Int)
        case jump(toSegment: Int, reason: Reason)
    }

    /// A reported position less than this (s) before a segment's start belongs to that
    /// segment: a player reports the start it seeked to a hair early (rounded to the
    /// millisecond, it once sent a conversion one segment back, then two). The session's own
    /// rule for a jump's target (`MKVToHLSRemuxSession.jumpBoundaryTolerance`).
    static let boundaryTolerance = 0.05

    /// Segments one pump step writes at most (the tick re-plans after each).
    static let pumpBurst = 2

    /// The segment the player's position is in, with `boundaryTolerance`.
    static func lowSegment(playerSeconds: Double, durations: [Double], targetDuration: Double) -> Int {
        RemuxPlayback.segmentIndex(coveringPlayerSeconds: max(0, playerSeconds) + boundaryTolerance,
                                   durations: durations, targetDuration: targetDuration)
    }

    static func isWritable(_ index: Int, highWater: Int, holes: IndexSet, pruned: IndexSet) -> Bool {
        index >= 0 && !pruned.contains(index) && (index >= highWater || holes.contains(index))
    }

    /// The first writable index of `range`, nil when it has none.
    static func firstWritable(in range: Range<Int>, highWater: Int, holes: IndexSet, pruned: IndexSet) -> Int? {
        guard !range.isEmpty else { return nil }
        var candidate = holes.integerGreaterThanOrEqualTo(range.lowerBound)
        while let hole = candidate, hole < range.upperBound, hole < highWater {
            if !pruned.contains(hole) { return hole }
            candidate = holes.integerGreaterThan(hole)
        }
        var index = max(range.lowerBound, highWater)
        while index < range.upperBound {
            if !pruned.contains(index) { return index }
            index += 1
        }
        return nil
    }

    /// How many segments a pass at `next` can write in a row before it meets one it can't
    /// (one that exists, or a pruned one): `Int.max` once the run reaches the high-water mark.
    static func writableExtent(from next: Int, highWater: Int, holes: IndexSet, pruned: IndexSet) -> Int {
        var index = next
        while index < highWater, holes.contains(index), !pruned.contains(index) { index += 1 }
        if index >= highWater, !pruned.contains(index) { return Int.max }
        return index - next
    }

    /// The segment that has to be written first, and where that comes from.
    struct Need: Equatable {
        let segment: Int
        /// From the player's reported position (the window of `low`), not from the anchor
        /// alone — whose furthest term is a segment AVPlayer merely requested.
        let fromLow: Bool
    }

    /// The first writable segment of the window of `low` — [low, its lookahead limit), never
    /// past the anchor's limit —, else of the anchor's window [anchor, limitAnchor). nil:
    /// everything both windows hold exists (or is gone for good).
    static func need(highWater: Int, holes: IndexSet, pruned: IndexSet, low: Int?, limitLow: Int?,
                     anchor: Int, limitAnchor: Int) -> Need? {
        if let low = low, let limitLow = limitLow,
           let found = firstWritable(in: max(0, low)..<max(max(0, low), min(limitLow, limitAnchor)),
                                     highWater: highWater, holes: holes, pruned: pruned) {
            return Need(segment: found, fromLow: true)
        }
        if let found = firstWritable(in: max(0, anchor)..<max(max(0, anchor), limitAnchor),
                                     highWater: highWater, holes: holes, pruned: pruned) {
            return Need(segment: found, fromLow: false)
        }
        return nil
    }

    /// What the pass does now.
    ///  - next: the cursor (`MKVToHLSRemuxSession.nextSegmentIndex`); highWater:
    ///    `progress.segmentsWritten`; holes: the session's missing segments that are not
    ///    pruned; pruned: gone for good.
    ///  - low: the segment of the player's reported position (`wanted ?? played`,
    ///    `lowSegment`), nil without a report; limitLow: its lookahead limit
    ///    (`RemuxPlayback.lookaheadLimit`). anchor, limitAnchor: the lookahead anchor
    ///    (`RemuxPlayback.lookaheadAnchor`: the reported positions and AVPlayer's recent
    ///    requests) and its limit.
    ///  - canJump: the session can jump and jumps are allowed.
    ///  - explicitTarget: a segment an explicit decision sends the pass to (the accepted
    ///    resume, `requestJump`): taken at once when it is writable.
    ///  - isFar: whether a pass in file order would take too long to reach that segment
    ///    (`isFarForward`).
    ///
    /// The rule: the needed segment (`need`) decides. None → hold. The cursor → pump. Ahead
    /// of the cursor → over what exists when nothing is writable in between; a jump when the
    /// player's position asks for it and it is far; else pump toward it, as before. Behind
    /// the cursor (a hole the player went back into) → a jump back. A jump is never decided
    /// on the anchor alone: an HTTP request only ever makes the pass pump (AVPlayer asks
    /// again for segments of a position it has left).
    static func step(next: Int, highWater: Int, holes: IndexSet, pruned: IndexSet,
                     low: Int?, limitLow: Int?, anchor: Int, limitAnchor: Int,
                     canJump: Bool, explicitTarget: Int?, isFar: (Int) -> Bool) -> Step {
        if canJump, let target = explicitTarget, target != next,
           isWritable(target, highWater: highWater, holes: holes, pruned: pruned) {
            return .jump(toSegment: target, reason: .requested)
        }
        guard let need = need(highWater: highWater, holes: holes, pruned: pruned, low: low, limitLow: limitLow,
                              anchor: anchor, limitAnchor: limitAnchor) else { return .hold }
        let burst = min(pumpBurst, limitAnchor - next,
                        writableExtent(from: next, highWater: highWater, holes: holes, pruned: pruned))
        if need.segment == next { return burst > 0 ? .pump(maxNewSegments: burst) : .hold }
        if need.segment > next {
            guard let firstAhead = firstWritable(in: next..<need.segment, highWater: highWater, holes: holes,
                                                 pruned: pruned) else {
                // Everything from the cursor to it exists: over it.
                return canJump ? .jump(toSegment: need.segment, reason: .skipExisting) : .hold
            }
            if canJump, need.fromLow, isFar(need.segment) { return .jump(toSegment: need.segment, reason: .farSeek) }
            if !need.fromLow, low != nil, firstAhead < highWater {
                // The player's own window is written and only the anchor asks further — a
                // `played` left at the old position by a paused player after a rewind, say.
                // Filling every hole between them, with no lookahead bound and the torrent
                // steered along, writes segments nobody protects (pruned for good on a tight
                // disk); the pass waits for the player instead. A pass without holes has its
                // cursor at the mark, so the rule before jumps is unchanged.
                return .hold
            }
            if firstAhead != next {
                // The pass sits on a segment that exists: it writes nothing there.
                return canJump ? .jump(toSegment: firstAhead, reason: .skipExisting) : .hold
            }
            return burst > 0 ? .pump(maxNewSegments: burst) : .hold
        }
        return canJump && need.fromLow ? .jump(toSegment: need.segment, reason: .rewind) : .hold
    }

    /// A pass in file order from the cursor would take too long to reach the target: it is
    /// more than one lookahead of film away, or the file is not all on disk from the pass's
    /// reader up to where a jump to the target would read. The pass pumps through only when
    /// the target is near AND its way there is downloaded; otherwise a jump — a few seconds
    /// for the torrent to turn to the target — costs less than downloading in order.
    static func isFarForward(cursorSeconds: Double, targetSeconds: Double, sourceLocalUpToTarget: Bool,
                             lookahead: Double = RemuxPlayback.lookaheadSeconds) -> Bool {
        targetSeconds - cursorSeconds > lookahead || !sourceLocalUpToTarget
    }

    /// Keeps a jump the player's position asks for from following a scrub: the same segment
    /// must be asked for at two evaluations at least `stabilitySeconds` apart, and there is at
    /// most one such jump per `minimumIntervalSeconds`. An explicit decision (the accepted
    /// resume, `requestJump`, the move over what exists) is admitted at once.
    struct JumpGate: Equatable {
        static let stabilitySeconds: TimeInterval = 0.25
        static let minimumIntervalSeconds: TimeInterval = 1

        private(set) var candidate: Int?
        private(set) var candidateSince: TimeInterval = 0
        private(set) var lastJumpAt: TimeInterval?

        /// Whether the jump to `segment` is made now (`now`: uptime).
        mutating func admit(segment: Int, now: TimeInterval, explicit: Bool) -> Bool {
            if explicit {
                candidate = nil
                lastJumpAt = now
                return true
            }
            if candidate != segment {
                candidate = segment
                candidateSince = now
                return false
            }
            guard now - candidateSince >= Self.stabilitySeconds else { return false }
            if let last = lastJumpAt, now - last < Self.minimumIntervalSeconds { return false }
            candidate = nil
            lastJumpAt = now
            return true
        }

        /// An evaluation asked for no jump: the next candidate waits from the start.
        mutating func reset() { candidate = nil }

        /// How long (s) from `now` until the candidate can be admitted; nil without one.
        func delayUntilAdmission(now: TimeInterval) -> TimeInterval? {
            guard candidate != nil else { return nil }
            let stable = candidateSince + Self.stabilitySeconds
            let spaced = lastJumpAt.map { $0 + Self.minimumIntervalSeconds } ?? stable
            return max(0, max(stable, spaced) - now)
        }
    }

    /// What becomes of a bounded-storage jump that is still provisional (nothing was released
    /// for it yet, what it skipped can still be written).
    enum ProvisionalOutcome: Equatable {
        case keep
        /// Playback has run at the jump's destination: what it skipped is given up.
        case commit
        /// The player went back before the pass's old frontier: the jump is undone.
        case revert
    }

    /// - played: the last position playback reached; wanted: where the player needs data.
    /// - targetStartSeconds…runEndSeconds: what the pass wrote at the destination (from the
    ///   segment jumped to, to its cursor), on the player's timeline.
    /// - oldFrontierSeconds: the start of the segment the pass was about to write before.
    static func provisionalOutcome(played: Double?, wanted: Double?, targetStartSeconds: Double,
                                   runEndSeconds: Double, oldFrontierSeconds: Double) -> ProvisionalOutcome {
        if let played = played, played + boundaryTolerance >= targetStartSeconds, played < runEndSeconds {
            return .commit
        }
        if let wanted = wanted, wanted + boundaryTolerance < oldFrontierSeconds { return .revert }
        return .keep
    }
}

/// Where the torrent is told to download (`PTTorrentStreamer.readPosition`) on the remux
/// route (pure).
enum RemuxSteering {

    /// The offset to report after a tick, nil for none.
    ///  - preparedOffset: where a prepared resume would read (the resume question is up, or
    ///    answered and the jump not made yet): the torrent turns there in both storage modes.
    ///  - Otherwise the pass's reader: always in bounded mode (its window follows the reader),
    ///    in full mode only once a jump was made — a film played from 0:00 without a jump
    ///    leaves PopcornTorrent's own window alone.
    ///  - Nothing once stopped, nor before the header is parsed (`readerOffset` 0).
    static func readPosition(isStopped: Bool, preparedOffset: Int64?, isBounded: Bool, hasJumped: Bool,
                             readerOffset: Int64) -> Int64? {
        guard !isStopped else { return nil }
        if let prepared = preparedOffset { return max(0, prepared) }
        guard isBounded || hasJumped, readerOffset > 0 else { return nil }
        return readerOffset
    }
}
