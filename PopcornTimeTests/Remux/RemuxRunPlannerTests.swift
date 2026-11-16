//
//  RemuxRunPlannerTests.swift
//  PopcornTimeTests
//
//  RemuxRunPlanner: where the remux's one pass goes next. The table of its rule, the proof
//  that it is the pump's old rule when there is neither a hole nor a way to jump (10 000
//  random states against that rule written out), the guarantee that an HTTP request alone
//  never moves the pass, the gate that keeps a jump from following a scrub, the boundary
//  tolerance, and what becomes of a provisional jump in bounded storage.
//

import XCTest
import Foundation

/// A seeded generator: the random states are the same at every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class RemuxRunPlannerTests: CheckedTestCase {

    private typealias Planner = RemuxRunPlanner

    /// `step` with the windows of a 6 s grid (30 segments of lookahead), as the pump computes
    /// them.
    private func step(next: Int, highWater: Int, holes: IndexSet = [], pruned: IndexSet = [],
                      low: Int?, anchor: Int? = nil, canJump: Bool = true, explicit: Int? = nil,
                      far: @escaping (Int) -> Bool = { _ in false }) -> Planner.Step {
        let anchor = anchor ?? low ?? 0
        return Planner.step(next: next, highWater: highWater, holes: holes, pruned: pruned,
                            low: low, limitLow: low.map { $0 + 30 }, anchor: anchor, limitAnchor: anchor + 30,
                            canJump: canJump, explicitTarget: explicit, isFar: far)
    }

    // MARK: The table

    func testInFileOrderThePassPumpsAndHoldsAtTheLookaheadLimit() {
        eq(step(next: 0, highWater: 0, low: nil), .pump(maxNewSegments: 2), "nothing reported: the pass writes from 0")
        eq(step(next: 29, highWater: 29, low: nil), .pump(maxNewSegments: 1), "one segment left before the limit: one")
        eq(step(next: 30, highWater: 30, low: nil), .hold, "the lookahead of segment 0 is written: hold")
        eq(step(next: 30, highWater: 30, low: 5), .pump(maxNewSegments: 2), "the player moved on: pump again")
        eq(step(next: 40, highWater: 40, low: 5, anchor: 12), .pump(maxNewSegments: 2), "the anchor's window still has room")
        eq(step(next: 42, highWater: 42, low: 5, anchor: 12), .hold, "at the anchor's limit: hold")
    }

    func testAPositionAheadIsPumpedTowardUnlessItIsFar() {
        eq(step(next: 10, highWater: 10, low: 25), .pump(maxNewSegments: 2), "near and on disk: the pass pumps through")
        eq(step(next: 10, highWater: 10, low: 25, far: { _ in true }), .jump(toSegment: 25, reason: .farSeek),
           "far: the pass jumps to the player's segment")
        eq(step(next: 10, highWater: 10, low: 25, canJump: false, far: { _ in true }), .pump(maxNewSegments: 2),
           "no way to jump: the pump goes there in file order, as before")
        var asked: [Int] = []
        _ = step(next: 10, highWater: 10, low: 700, far: { asked.append($0); return true })
        eq(asked, [700], "the far test is asked about the needed segment")
    }

    func testAHoleBehindThePassIsFilledByAJumpBack() {
        // Written: 0…1 and 700…704 (a resume at segment 700); holes 2…699.
        let holes = IndexSet(2..<700)
        eq(step(next: 705, highWater: 705, holes: holes, low: 300), .jump(toSegment: 300, reason: .rewind),
           "the player is in a hole behind the pass: back to it")
        eq(step(next: 705, highWater: 705, holes: holes, low: 300, canJump: false), .hold,
           "without a way to jump the hole can't be filled")
        eq(step(next: 300, highWater: 705, holes: holes, low: 300), .pump(maxNewSegments: 2), "the pass fills the hole")
        eq(step(next: 329, highWater: 705, holes: holes.subtracting(IndexSet(300..<329)), low: 300), .pump(maxNewSegments: 1),
           "up to the lookahead limit")
        eq(step(next: 330, highWater: 705, holes: holes.subtracting(IndexSet(300..<330)), low: 300), .hold,
           "then holds, cursor below the mark")
        eq(step(next: 330, highWater: 705, holes: holes.subtracting(IndexSet(300..<330)), low: 303), .pump(maxNewSegments: 2),
           "and goes on as the player advances")
    }

    func testAPassInAHoleDoesNotPumpTowardAStalePlayedPosition() {
        // Resume at 700, island 700…705 short of its lead; the head pass wrote 0…29. A paused
        // player rewound to 300: `wanted` there, `played` still at 703 (the anchor). The pass
        // jumped back and wrote 300…329: the player's window is full.
        let holes = IndexSet(30..<300).union(IndexSet(330..<700))
        eq(step(next: 330, highWater: 706, holes: holes, low: 300, anchor: 703), .hold,
           "the anchor alone does not pull the pass through the holes up to the old position")
        eq(Planner.need(highWater: 706, holes: holes, pruned: [], low: 300, limitLow: 330, anchor: 703, limitAnchor: 733),
           Planner.Need(segment: 706, fromLow: false), "the need does come from the anchor")
        // Parked on a segment that exists, with a hole after it: no hop into the hole either.
        eq(step(next: 329, highWater: 706, holes: holes, low: 300, anchor: 703), .hold,
           "no hop to a hole the pass would only wait in")
        // Everything up to the mark exists: the frontier is not a hole, the pass goes there.
        eq(step(next: 330, highWater: 706, holes: IndexSet(30..<300), low: 300, anchor: 703),
           .jump(toSegment: 706, reason: .skipExisting), "over what exists to the frontier, as before")
        eq(step(next: 706, highWater: 706, holes: holes, low: 300, anchor: 703), .pump(maxNewSegments: 2),
           "at the frontier the anchor's window is pumped as before")
        // Once playback is reported at the rewind target, the pass goes on there.
        eq(step(next: 330, highWater: 706, holes: holes, low: 303, anchor: 703), .pump(maxNewSegments: 2),
           "the player advances: its own window pulls the pass")
        // Without any report the anchor still makes the pass pump (the rule before jumps).
        eq(step(next: 330, highWater: 706, holes: holes, low: nil, anchor: 330), .pump(maxNewSegments: 2),
           "no report: the anchor's own window is pumped")
    }

    func testThePassMovesOverWhatExists() {
        // Written: 0…704; the pass filled the holes up to 699 and now sits on 700.
        eq(step(next: 700, highWater: 705, low: 690), .jump(toSegment: 705, reason: .skipExisting),
           "nothing left to write before the mark: over what exists")
        eq(step(next: 700, highWater: 705, low: 690, canJump: false), .hold, "no jump: nothing can be done")
        eq(step(next: 700, highWater: 705, low: 600), .hold, "the mark is not in the window yet: the pass waits where it is")
        // An island ahead of a hole: written 0…9 and 20…24, the mark at 100.
        let afterIsland = IndexSet(25..<100)
        eq(step(next: 20, highWater: 100, holes: afterIsland, low: 22), .jump(toSegment: 25, reason: .skipExisting),
           "the pass filled 10…19 and met the island: over it to the next hole")
        func holes(from first: Int) -> IndexSet { afterIsland.union(IndexSet(first..<20)) }
        eq(step(next: 12, highWater: 100, holes: holes(from: 12), low: 22), .pump(maxNewSegments: 2),
           "the player is on the island, the pass in the hole before it, its data on disk: it fills on its way")
        eq(step(next: 12, highWater: 100, holes: holes(from: 12), low: 22, far: { _ in true }), .jump(toSegment: 25, reason: .farSeek),
           "that data is not there: straight to what the player needs next")
        eq(step(next: 12, highWater: 100, holes: holes(from: 12), low: 14), .pump(maxNewSegments: 2), "the player is in the hole: fill it")
        eq(step(next: 18, highWater: 100, holes: holes(from: 18), low: 14), .pump(maxNewSegments: 2), "two more")
        eq(step(next: 19, highWater: 100, holes: holes(from: 19), low: 14), .pump(maxNewSegments: 1), "never into a segment that exists")
        // The pass sits on the island and the player needs a hole past it, with holes between.
        eq(step(next: 20, highWater: 100, holes: afterIsland, low: 40), .jump(toSegment: 25, reason: .skipExisting),
           "parked on a segment that exists: over it first, then pump")
        eq(step(next: 20, highWater: 100, holes: afterIsland, low: 40, far: { _ in true }), .jump(toSegment: 40, reason: .farSeek),
           "or straight to the player's segment when it is far")
    }

    func testAPrunedSegmentIsNeverWrittenAgain() {
        let span = IndexSet(40..<60)
        eq(step(next: 100, highWater: 100, holes: span, low: 45), .jump(toSegment: 45, reason: .rewind), "a hole is written again")
        eq(step(next: 100, highWater: 100, pruned: span, low: 45), .hold,
           "the player is in a pruned span: nothing there is written again, and the frontier is not in its window")
        eq(step(next: 100, highWater: 100, holes: span, pruned: span, low: 45), .hold, "a hole that was given up is pruned, not writable")
        eq(step(next: 100, highWater: 100, pruned: span, low: 45, anchor: 80), .pump(maxNewSegments: 2),
           "the anchor's window reaches the frontier: the pump goes on there")
        eq(Planner.firstWritable(in: 40..<70, highWater: 100, holes: IndexSet(40..<70), pruned: span), 60,
           "the first writable index skips the pruned ones")
    }

    func testAnExplicitDecisionIsTakenAtOnce() {
        eq(step(next: 10, highWater: 10, low: nil, explicit: 700), .jump(toSegment: 700, reason: .requested),
           "the accepted resume: there now, far or not, whatever the player reports")
        eq(step(next: 10, highWater: 10, low: 3, explicit: 12), .jump(toSegment: 12, reason: .requested), "even a near one")
        eq(step(next: 10, highWater: 10, low: 3, canJump: false, explicit: 700), .pump(maxNewSegments: 2), "not without a way to jump")
        eq(step(next: 700, highWater: 705, low: 702, explicit: 702), .jump(toSegment: 705, reason: .skipExisting),
           "a target that exists is no jump: the usual rule")
        eq(step(next: 10, highWater: 10, low: 10, explicit: 10), .pump(maxNewSegments: 2), "the cursor itself: pump")
        eq(step(next: 705, highWater: 705, holes: IndexSet(2..<700), pruned: IndexSet(2..<700), low: 702, explicit: 300),
           .pump(maxNewSegments: 2), "a pruned target is no jump")
    }

    // MARK: Equivalence with the rule before jumps

    /// `RemuxPlayback.tick` before the session could jump (RemuxPlayback.swift of rs-base,
    /// the loop's limit test): `before` segments written, `limit` the anchor's lookahead limit.
    private func oldRule(before: Int, limit: Int) -> Planner.Step {
        before >= limit ? .hold : .pump(maxNewSegments: min(2, limit - before))
    }

    func testWithoutHolesNorJumpsThePlannerIsTheOldRule() {
        var generator = SeededGenerator(seed: 530)
        var differences = 0
        var holds = 0, pumps = 0
        for _ in 0..<10_000 {
            // A timeline as the pump sees it: segments of 1…20 s, a target of 6 s past its end.
            let count = Int.random(in: 0...400, using: &generator)
            let durations = (0..<count).map { _ in Double.random(in: 1...20, using: &generator) }
            let written = Int.random(in: 0...420, using: &generator)
            var pruned = IndexSet()
            if written > 1 {
                for _ in 0..<Int.random(in: 0...6, using: &generator) {
                    let start = Int.random(in: 1..<written, using: &generator)
                    pruned.insert(integersIn: start..<min(written, start + Int.random(in: 1...40, using: &generator)))
                }
            }
            let played: Double? = Bool.random(using: &generator) ? Double.random(in: 0...3000, using: &generator) : nil
            var wanted: Double? = Bool.random(using: &generator) ? Double.random(in: 0...3000, using: &generator) : nil
            if wanted != nil, count > 1, Int.random(in: 0..<4, using: &generator) == 0 {
                // A hair before a segment's start: the tolerance puts the player one segment
                // past the anchor's own segment.
                wanted = RemuxPlayback.segmentStart(index: Int.random(in: 1..<count, using: &generator), durations: durations,
                                                    targetDuration: 6) - 0.01
            }
            var requests: [Int: TimeInterval] = [:]
            for _ in 0..<Int.random(in: 0...3, using: &generator) {
                requests[Int.random(in: 0...450, using: &generator)] = Double.random(in: 60...100, using: &generator)
            }
            let reportedAt: TimeInterval? = played != nil || wanted != nil ? Double.random(in: 60...100, using: &generator) : nil
            let anchor = RemuxPlayback.lookaheadAnchor(played: played, wanted: wanted, reportedAt: reportedAt, requests: requests,
                                                       now: 100, durations: durations, targetDuration: 6)
            let limit = RemuxPlayback.lookaheadLimit(anchor: anchor, durations: durations, targetDuration: 6)
            let low = (wanted ?? played).map { Planner.lowSegment(playerSeconds: $0, durations: durations, targetDuration: 6) }
            let limitLow = low.map { RemuxPlayback.lookaheadLimit(anchor: $0, durations: durations, targetDuration: 6) }
            let expected = oldRule(before: written, limit: limit)
            if case .hold = expected { holds += 1 } else { pumps += 1 }
            // No way to jump (a local file, the hidden switch off, no keyframe index): whatever
            // the far test and an explicit target say.
            let far = Bool.random(using: &generator)
            let explicit: Int? = Bool.random(using: &generator) ? Int.random(in: 0...450, using: &generator) : nil
            let withoutJumps = Planner.step(next: written, highWater: written, holes: [], pruned: pruned, low: low, limitLow: limitLow,
                                            anchor: anchor, limitAnchor: limit, canJump: false, explicitTarget: explicit,
                                            isFar: { _ in far })
            // Able to jump, nothing far, nothing asked: a film played in file order.
            let nothingFar = Planner.step(next: written, highWater: written, holes: [], pruned: pruned, low: low, limitLow: limitLow,
                                          anchor: anchor, limitAnchor: limit, canJump: true, explicitTarget: nil,
                                          isFar: { _ in false })
            if withoutJumps != expected || nothingFar != expected { differences += 1 }
        }
        eq(differences, 0, "10 000 random states without a hole: the planner is the old rule")
        check(holds > 500 && pumps > 500, "both outcomes of the old rule were drawn", "hold \(holds), pump \(pumps)")
    }

    // MARK: Never on a request alone

    func testAnHTTPRequestAloneNeverMakesThePassJump() {
        let holes = IndexSet(2..<700)
        // AVPlayer asks again for a segment of a position it left (a hole behind the pass):
        // the anchor is there, the player's report is not.
        eq(step(next: 705, highWater: 705, holes: holes, low: nil, anchor: 300), .hold, "a hole behind, anchor only: no jump back")
        eq(step(next: 705, highWater: 705, holes: holes, low: 702, anchor: 300 + 500), .pump(maxNewSegments: 2),
           "the player is at the frontier: its own window comes first")
        // A request far ahead, nothing reported there: pumped toward, never jumped to.
        eq(step(next: 10, highWater: 10, low: 3, anchor: 400, far: { _ in true }), .pump(maxNewSegments: 2),
           "a far request the player does not report: the pump goes on in file order")
        eq(step(next: 10, highWater: 10, low: nil, anchor: 400, far: { _ in true }), .pump(maxNewSegments: 2), "same without any report")

        var generator = SeededGenerator(seed: 2026)
        var jumpsOnTheAnchor = 0, anchorOnly = 0
        for _ in 0..<10_000 {
            let highWater = Int.random(in: 2...300, using: &generator)
            var holes = IndexSet()
            for _ in 0..<Int.random(in: 0...4, using: &generator) {
                let start = Int.random(in: 2...highWater, using: &generator)
                holes.insert(integersIn: start..<min(highWater, start + Int.random(in: 1...80, using: &generator)))
            }
            var pruned = IndexSet()
            if Bool.random(using: &generator), highWater > 3 {
                let start = Int.random(in: 2..<highWater, using: &generator)
                pruned.insert(integersIn: start..<min(highWater, start + Int.random(in: 1...30, using: &generator)))
            }
            let next = Bool.random(using: &generator) ? highWater : Int.random(in: 2...highWater, using: &generator)
            let low: Int? = Bool.random(using: &generator) ? Int.random(in: 0...320, using: &generator) : nil
            let anchor = max(low ?? 0, Int.random(in: 0...340, using: &generator))
            let need = Planner.need(highWater: highWater, holes: holes.subtracting(pruned), pruned: pruned, low: low,
                                    limitLow: low.map { $0 + 30 }, anchor: anchor, limitAnchor: anchor + 30)
            guard let found = need, !found.fromLow else { continue }
            anchorOnly += 1
            let result = Planner.step(next: next, highWater: highWater, holes: holes.subtracting(pruned), pruned: pruned, low: low,
                                      limitLow: low.map { $0 + 30 }, anchor: anchor, limitAnchor: anchor + 30,
                                      canJump: true, explicitTarget: nil, isFar: { _ in true })
            if case .jump(_, let reason) = result, reason != .skipExisting { jumpsOnTheAnchor += 1 }
        }
        eq(jumpsOnTheAnchor, 0, "random states whose needed segment comes from the anchor alone: never a jump there")
        check(anchorOnly > 1000, "enough of those states were drawn", "\(anchorOnly)")
    }

    // MARK: The gate

    func testAJumpWaitsForAStablePositionAndIsSpaced() {
        var gate = Planner.JumpGate()
        check(!gate.admit(segment: 700, now: 10.00, explicit: false), "first sight of a segment: not yet")
        check(!gate.admit(segment: 700, now: 10.10, explicit: false), "0.1 s later: not yet")
        check(abs((gate.delayUntilAdmission(now: 10.10) ?? -1) - 0.15) < 1e-9, "it says how long is left")
        check(gate.admit(segment: 700, now: 10.25, explicit: false), "the same segment 0.25 s after it was first seen: jump")
        check(!gate.admit(segment: 300, now: 10.30, explicit: false), "another segment: seen once")
        check(!gate.admit(segment: 300, now: 10.60, explicit: false), "stable, but less than a second after the last jump")
        check(gate.admit(segment: 300, now: 11.25, explicit: false), "a second after the last jump: jump")

        var scrub = Planner.JumpGate()
        for (index, segment) in [100, 140, 180, 220, 260].enumerated() {
            check(!scrub.admit(segment: segment, now: 20 + Double(index) * 0.3, explicit: false), "a scrub passing through \(segment): no jump")
        }
        check(!scrub.admit(segment: 260, now: 21.3, explicit: false), "where it stops: seen again, 0.1 s later")
        check(scrub.admit(segment: 260, now: 21.5, explicit: false), "and jumped to once stable")

        var reset = Planner.JumpGate()
        _ = reset.admit(segment: 50, now: 30, explicit: false)
        reset.reset()
        check(!reset.admit(segment: 50, now: 30.3, explicit: false), "an evaluation that asked for no jump in between: the wait starts again")
        check(reset.delayUntilAdmission(now: 30.3) != nil && Planner.JumpGate().delayUntilAdmission(now: 0) == nil, "no delay without a candidate")

        var explicit = Planner.JumpGate()
        check(explicit.admit(segment: 700, now: 40, explicit: true), "an explicit decision is admitted at once")
        check(explicit.admit(segment: 20, now: 40.1, explicit: true), "and again, whatever the spacing")
        _ = explicit.admit(segment: 300, now: 40.2, explicit: false)
        check(!explicit.admit(segment: 300, now: 40.6, explicit: false), "a jump on the position waits a second after an explicit one")
        check(explicit.admit(segment: 300, now: 41.2, explicit: false), "then goes")
    }

    // MARK: Boundary tolerance

    func testAPositionAHairBeforeASegmentBelongsToIt() {
        // A two-hour film in 6 s segments; AVPlayer settled at the start of segment 599 and the
        // position came back rounded down to the millisecond.
        let durations = [Double](repeating: 6.006, count: 1200)
        let start = RemuxPlayback.segmentStart(index: 599, durations: durations, targetDuration: 6)
        let reported = (start * 1000).rounded(.down) / 1000 - 0.001
        eq(RemuxPlayback.segmentIndex(coveringPlayerSeconds: reported, durations: durations, targetDuration: 6), 598,
           "without tolerance the position falls in the segment before")
        eq(Planner.lowSegment(playerSeconds: reported, durations: durations, targetDuration: 6), 599, "with it, in the segment AVPlayer is in")
        eq(Planner.lowSegment(playerSeconds: start - 0.049, durations: durations, targetDuration: 6), 599, "49 ms early: still that segment")
        eq(Planner.lowSegment(playerSeconds: start - 0.06, durations: durations, targetDuration: 6), 598, "60 ms early: the one before")
        eq(Planner.lowSegment(playerSeconds: start + 3, durations: durations, targetDuration: 6), 599, "inside it")
        eq(Planner.lowSegment(playerSeconds: 0, durations: durations, targetDuration: 6), 0, "0 is segment 0")
        eq(Planner.lowSegment(playerSeconds: -5, durations: durations, targetDuration: 6), 0, "a negative position too")
        eq(Planner.boundaryTolerance, MKVToHLSRemuxSession.jumpBoundaryTolerance, "the session's own tolerance for a jump's target")
        // The pass is at 599 after the jump there: the position a hair early does not send it
        // one segment back (598 is a hole), then two.
        let holes = IndexSet(30..<599)
        let low = Planner.lowSegment(playerSeconds: reported, durations: durations, targetDuration: 6)
        eq(Planner.step(next: 599, highWater: 599, holes: holes, pruned: [], low: low, limitLow: low + 30, anchor: 598,
                        limitAnchor: 628, canJump: true, explicitTarget: nil, isFar: { _ in true }),
           .pump(maxNewSegments: 2), "no jump back to 598")
    }

    // MARK: Far or not

    func testFarMeansMoreThanOneLookaheadOrDataMissing() {
        check(!Planner.isFarForward(cursorSeconds: 100, targetSeconds: 250, sourceLocalUpToTarget: true), "150 s ahead, all on disk: pump through")
        check(!Planner.isFarForward(cursorSeconds: 100, targetSeconds: 280, sourceLocalUpToTarget: true), "exactly one lookahead: still near")
        check(Planner.isFarForward(cursorSeconds: 100, targetSeconds: 281, sourceLocalUpToTarget: true), "more than 180 s ahead: far")
        check(Planner.isFarForward(cursorSeconds: 100, targetSeconds: 130, sourceLocalUpToTarget: false), "30 s ahead but not downloaded: far")
        check(Planner.isFarForward(cursorSeconds: 100, targetSeconds: 6000, sourceLocalUpToTarget: false), "far and not downloaded")
        eq(RemuxPlayback.lookaheadSeconds, 180, "one lookahead is three minutes")
    }

    // MARK: Provisional jump (bounded storage)

    func testAProvisionalJumpIsKeptCommittedOrReverted() {
        // The pass was about to write the segment at 750 s; it jumped to 4200 s and has
        // written up to 4260 s.
        func outcome(played: Double?, wanted: Double?, runEnd: Double = 4260) -> Planner.ProvisionalOutcome {
            Planner.provisionalOutcome(played: played, wanted: wanted, targetStartSeconds: 4200, runEndSeconds: runEnd,
                                       oldFrontierSeconds: 750)
        }
        eq(outcome(played: 600, wanted: 4203), .keep, "the player waits at the destination, nothing played there yet")
        eq(outcome(played: nil, wanted: 4203), .keep, "a resume: nothing played at all yet")
        eq(outcome(played: 4201, wanted: 4203), .commit, "playback has run at the destination")
        eq(outcome(played: 4199.97, wanted: 4203), .commit, "30 ms before its first segment's start counts")
        eq(outcome(played: 4201, wanted: 30), .commit, "it ran there, then the player went back: committed all the same")
        eq(outcome(played: 4300, wanted: 4300), .keep, "past what the pass wrote there: not yet")
        eq(outcome(played: 600, wanted: 30), .revert, "back in the old series before anything played there")
        eq(outcome(played: nil, wanted: 30), .revert, "same after a resume")
        eq(outcome(played: 600, wanted: 749.97), .keep, "30 ms before the old frontier is the old frontier: a hole, not the old series")
        eq(outcome(played: 600, wanted: 900), .keep, "in what was skipped, past the old frontier: the pass goes there, still provisional")
        eq(outcome(played: 600, wanted: nil), .keep, "no position wanted: nothing to decide")
        eq(outcome(played: 4201, wanted: 4203, runEnd: 4200), .keep, "nothing written at the destination yet: nothing ran there")
    }

    // MARK: Helpers of the rule

    func testWritableSegments() {
        let holes = IndexSet(10..<20)
        check(Planner.isWritable(12, highWater: 30, holes: holes, pruned: []), "a hole is writable")
        check(Planner.isWritable(30, highWater: 30, holes: holes, pruned: []), "the mark is writable")
        check(!Planner.isWritable(25, highWater: 30, holes: holes, pruned: []), "a segment that exists is not")
        check(!Planner.isWritable(12, highWater: 30, holes: holes, pruned: IndexSet(integer: 12)), "nor a pruned one")
        eq(Planner.firstWritable(in: 0..<10, highWater: 30, holes: holes, pruned: []), nil, "nothing writable among what exists")
        eq(Planner.firstWritable(in: 5..<40, highWater: 30, holes: holes, pruned: []), 10, "the first hole of the range")
        eq(Planner.firstWritable(in: 20..<40, highWater: 30, holes: holes, pruned: []), 30, "else the mark")
        eq(Planner.firstWritable(in: 20..<30, highWater: 30, holes: holes, pruned: []), nil, "the range ends before the mark")
        eq(Planner.firstWritable(in: 15..<15, highWater: 30, holes: holes, pruned: []), nil, "an empty range")
        eq(Planner.writableExtent(from: 12, highWater: 30, holes: holes, pruned: []), 8, "a run of holes ends at what exists")
        eq(Planner.writableExtent(from: 25, highWater: 30, holes: holes, pruned: []), 0, "nothing on a segment that exists")
        eq(Planner.writableExtent(from: 30, highWater: 30, holes: holes, pruned: []), Int.max, "no bound from the mark on")
        eq(Planner.writableExtent(from: 22, highWater: 30, holes: IndexSet(20..<30), pruned: []), Int.max, "nor for holes that reach the mark")
        eq(Planner.need(highWater: 30, holes: holes, pruned: [], low: 12, limitLow: 42, anchor: 12, limitAnchor: 42),
           Planner.Need(segment: 12, fromLow: true), "the player's own window first")
        eq(Planner.need(highWater: 30, holes: holes, pruned: [], low: 0, limitLow: 5, anchor: 14, limitAnchor: 44),
           Planner.Need(segment: 14, fromLow: false), "else the anchor's")
        eq(Planner.need(highWater: 30, holes: [], pruned: [], low: 0, limitLow: 20, anchor: 0, limitAnchor: 20), nil, "else nothing")
        eq(Planner.need(highWater: 30, holes: [], pruned: [], low: 5, limitLow: 36, anchor: 4, limitAnchor: 30), nil,
           "the player's window never reaches past the anchor's limit")
    }

    /// Review finding ENG-3: a planner jump to a hole is waited on unless the player has at
    /// least a target duration of media before it. Segments of 6 s; 0…9 written, 10 a hole
    /// (a jump skipped it), 11…19 written, the mark at 20.
    func testAHoleRightAheadOfThePlayerIsWaitedOn() {
        let durations = [Double](repeating: 6, count: 20)
        let missing = IndexSet(integer: 10)
        func ahead(_ position: Double, _ low: Int?, pruned: IndexSet = []) -> Bool {
            RemuxPlayback.playsOnMediaAhead(position: position, low: low, highWater: 20, missing: missing, pruned: pruned,
                                            durations: durations, targetDuration: 6)
        }
        check(ahead(30, 5), "30 s of media before the hole at 60 s: plays on, nobody waits")
        check(ahead(54, 9), "exactly a target duration before it: plays on")
        check(!ahead(58, 9), "2 s before the hole: the player reaches it first — it waits")
        check(!ahead(61, 10), "in the hole: it waits")
        check(ahead(70, 11), "past the hole, 50 s of media to the mark: plays on")
        check(!ahead(118, 19), "2 s before the mark: it waits")
        check(!ahead(32, 5, pruned: IndexSet(integer: 6)), "a pruned segment right after: 4 s of media left — it waits")
        check(!ahead(30, nil), "no position: nothing plays on")
    }
}
