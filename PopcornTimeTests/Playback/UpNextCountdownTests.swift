//
//  UpNextCountdownTests.swift
//  PopcornTimeTests
//
//  The « next episode » card of one playback (PopcornKit UpNextCountdown), every transition
//  with an injected clock: the preparation at 90 % or 5 min before the end, the card 30 s
//  before the end (decision D7) counting down to the end of the file, a pause that freezes
//  it, cancel (the card never comes back; the end closes the player as before), a rewind
//  before the card, the after-play card of a file whose length was not known, closing the
//  player, a plan missing at the start (3 s, then the chooser), the setting off (no
//  countdown), « Still watching? » after 3 episodes chained with no action (decision D6).
//

import XCTest
import Foundation
@testable import PopcornKit

private typealias C = UpNextCountdown

final class UpNextCountdownTests: CheckedTestCase {

    /// A 45 min episode, played second by second from `from` to `to` (the clock = the position).
    private func play(_ countdown: inout C, from: Int, to: Int, duration: Double = 2700, playing: Bool = true) -> [(Int, C.Effect)] {
        var effects: [(Int, C.Effect)] = []
        for second in from...to {
            for effect in countdown.tick(now: Double(second), position: Double(second), duration: duration, isPlaying: playing) {
                effects.append((second, effect))
            }
        }
        return effects
    }

    func testPreparationAndCardTimes() {
        var long = C(autoAdvance: true)
        eq(long.phase, .idle, "idle before a duration")
        _ = long.tick(now: 0, position: 0, duration: nil, isPlaying: true)
        eq(long.phase, .idle, "no duration: still idle")
        let effects = play(&long, from: 1, to: 2420)
        eq(long.phase, .preparing, "45 min: preparing")
        eq(long.prefetchAt, 2400, "45 min: 5 min before the end (earlier than 90 % = 2430)")
        eq(long.cardAt, 2670, "the card 30 s before the end")
        eq(effects.map { $0.0 }, [2400], "one prefetch, at 2400 s")
        eq(effects.first?.1, .prefetch, "the prefetch effect")
        check(long.card == nil, "no card yet")

        var short = C(autoAdvance: true)
        _ = play(&short, from: 0, to: 1, duration: 1200)
        eq(short.prefetchAt, 900, "20 min: 5 min before the end (90 % = 1080)")
        var tiny = C(autoAdvance: true)
        _ = play(&tiny, from: 0, to: 1, duration: 180)
        eq(tiny.prefetchAt, 0, "3 min: at once")
        eq(tiny.cardAt, 150, "3 min: the card at 2:30")
        var hour = C(autoAdvance: true)
        _ = play(&hour, from: 0, to: 1, duration: 4000)
        eq(hour.prefetchAt, 3600, "4000 s: 90 % (3600) is earlier than 3700")
        var debug = C(autoAdvance: true, tuning: { var t = C.Tuning(); t.cardAtOverride = 60; return t }())
        _ = play(&debug, from: 0, to: 1, duration: 180)
        eq(debug.cardAt, 60, "-PTDebugUpNextCardAt 60")
        eq(debug.prefetchAt, 0, "the prefetch never after the card")
    }

    func testCardCountsDownToTheEndThenStarts() {
        var countdown = C(autoAdvance: true)
        _ = play(&countdown, from: 2390, to: 2669)
        _ = countdown.planReady(now: 2669)
        eq(countdown.phase, .ready, "plan ready before the card")
        _ = play(&countdown, from: 2670, to: 2670)
        eq(countdown.phase, .offered, "the card at -30 s")
        eq(countdown.card, C.Card(kind: .countdown, secondsLeft: 30, total: 30), "30 s left")
        _ = play(&countdown, from: 2671, to: 2690)
        eq(countdown.card?.secondsLeft, 10, "10 s left")
        // A pause freezes it (the file's own time).
        for second in 2691...2720 {
            _ = countdown.tick(now: Double(second), position: 2690, duration: 2700, isPlaying: false)
        }
        eq(countdown.card?.secondsLeft, 10, "paused: still 10 s")
        eq(countdown.phase, .offered, "paused: still offered")
        let end = play(&countdown, from: 2691, to: 2700)
        eq(end.map { $0.1 }, [.start(.deadline)], "the end starts the next one, once")
        eq(countdown.phase, .starting, "starting")
        eq(countdown.card, nil, "no card once starting")
        eq(countdown.itemEnded(now: 2701), [], "the file's end event changes nothing then")
        eq(countdown.chainedAfterStart, 0, "a pause is an action: the chain restarts")
    }

    func testAcceptAndChooseAndCancel() {
        var accepted = C(autoAdvance: true)
        _ = play(&accepted, from: 2600, to: 2675)
        _ = accepted.planReady(now: 2675)
        eq(accepted.accept(now: 2676), [.start(.accepted)], "Play Now")
        eq(accepted.chainedAfterStart, 0, "an action")

        var chooser = C(autoAdvance: true)
        _ = play(&chooser, from: 2600, to: 2675)
        eq(chooser.choose(now: 2676), [.openChooser(.userAsked)], "Choose Version")
        eq(chooser.phase, .choosing, "choosing (playback goes on)")
        eq(chooser.chose(now: 2680), [.start(.chosen)], "a pick starts it")
        var left = C(autoAdvance: true)
        _ = play(&left, from: 2600, to: 2675)
        _ = left.choose(now: 2676)
        eq(left.choiceCancelled(now: 2680), [], "the chooser left before the end")
        eq(left.phase, .dismissed, "no card again")
        eq(play(&left, from: 2681, to: 2699).map { $0.1 }, [], "nothing more")
        eq(left.itemEnded(now: 2700), [.closePlayer], "the end closes the player, as before")

        var cancelled = C(autoAdvance: true)
        _ = play(&cancelled, from: 2600, to: 2675)
        eq(cancelled.cancel(now: 2676), [], "Cancel / Back to the Video")
        eq(cancelled.phase, .dismissed, "dismissed")
        eq(cancelled.card, nil, "the card goes")
        _ = play(&cancelled, from: 2650, to: 2680)
        eq(cancelled.card, nil, "and never comes back, a rewind before it included")
        eq(cancelled.itemEnded(now: 2700), [.closePlayer], "the end: the player closes, nothing starts")
        eq(cancelled.itemEnded(now: 2701), [], "once")
    }

    func testRewindBeforeTheCard() {
        var countdown = C(autoAdvance: true)
        _ = play(&countdown, from: 2650, to: 2680)
        eq(countdown.phase, .offered, "offered")
        _ = countdown.tick(now: 2681, position: 2500, duration: 2700, isPlaying: true)
        eq(countdown.phase, .preparing, "rewound before the card: it goes (plan not in)")
        eq(countdown.card, nil, "no card")
        check(countdown.sawActivity, "a rewind is an action")
        _ = countdown.planReady(now: 2682)
        _ = countdown.tick(now: 2683, position: 2669, duration: 2700, isPlaying: true)
        eq(countdown.phase, .ready, "ready")
        _ = countdown.tick(now: 2684, position: 2670, duration: 2700, isPlaying: true)
        eq(countdown.phase, .offered, "the card comes back there")
    }

    func testAfterPlayCardWithoutDuration() {
        var countdown = C(autoAdvance: true)
        for second in 0...100 { _ = countdown.tick(now: Double(second), position: Double(second), duration: nil, isPlaying: true) }
        eq(countdown.phase, .idle, "an EVENT playlist: no length, no card")
        eq(countdown.itemEnded(now: 101), [.prefetch], "the end: the after-play card, the sources asked now")
        eq(countdown.phase, .postPlay(until: 111), "10 s")
        eq(countdown.card, C.Card(kind: .postPlay, secondsLeft: 10, total: 10), "« Episode finished », 10 s")
        eq(countdown.clock(now: 105), [], "nothing at 4 s")
        eq(countdown.card?.secondsLeft, 6, "6 s left")
        eq(countdown.clock(now: 111), [], "due, but no plan: waits")
        eq(countdown.phase, .awaitingPlan(until: 114), "the plan awaited 3 s")
        eq(countdown.card, C.Card(kind: .postPlay, secondsLeft: 0, total: 10), "the card stays at 0")
        eq(countdown.planReady(now: 112), [.start(.deadline)], "the plan comes: it starts")

        var accept = C(autoAdvance: true)
        _ = accept.itemEnded(now: 10)
        _ = accept.planReady(now: 11)
        eq(accept.accept(now: 12), [.start(.accepted)], "Play Now on the after-play card")
        var cancel = C(autoAdvance: true)
        _ = cancel.itemEnded(now: 10)
        eq(cancel.cancel(now: 12), [.closePlayer], "Cancel there: the player closes")
        eq(cancel.phase, .closed, "closed")
    }

    func testPlanMissingAtTheStartOpensTheChooser() {
        var countdown = C(autoAdvance: true)
        _ = play(&countdown, from: 2600, to: 2680)
        eq(countdown.accept(now: 2681), [], "accepted without a plan: waits")
        eq(countdown.phase, .awaitingPlan(until: 2684), "3 s")
        eq(countdown.card?.secondsLeft, 0, "the card stays")
        eq(countdown.clock(now: 2683), [], "2 s: still waiting")
        eq(countdown.clock(now: 2684), [.openChooser(.noPlan)], "3 s: the chooser")
        eq(countdown.phase, .choosing, "choosing")

        var failed = C(autoAdvance: true)
        _ = play(&failed, from: 2600, to: 2680)
        _ = failed.accept(now: 2681)
        eq(failed.planFailed(now: 2682), [.openChooser(.noPlan)], "no plan possible: the chooser at once")
        var early = C(autoAdvance: true)
        _ = play(&early, from: 2600, to: 2610)
        _ = early.planFailed(now: 2611)
        _ = play(&early, from: 2611, to: 2680)
        eq(early.accept(now: 2681), [.openChooser(.noPlan)], "known to have failed: the chooser when accepted")
    }

    func testClosingThePlayer() {
        var countdown = C(autoAdvance: true)
        _ = play(&countdown, from: 2600, to: 2680)
        countdown.closed()
        eq(countdown.phase, .closed, "closed")
        eq(countdown.card, nil, "no card")
        eq(play(&countdown, from: 2681, to: 2700).map { $0.1 }, [], "nothing starts")
        eq(countdown.itemEnded(now: 2701), [], "nor at the end")
        eq(countdown.accept(now: 2702), [], "nor on a late press")
    }

    func testSettingOffNeverStartsAlone() {
        var countdown = C(autoAdvance: false)
        _ = play(&countdown, from: 2600, to: 2680)
        _ = countdown.planReady(now: 2680)
        eq(countdown.card, C.Card(kind: .countdown, secondsLeft: nil, total: nil), "the card, without a countdown")
        eq(play(&countdown, from: 2681, to: 2700).map { $0.1 }, [], "nothing at the end")
        eq(countdown.phase, .postPlay(until: nil), "the card stays after the end")
        eq(countdown.clock(now: 3000), [], "and nothing starts, ever")
        eq(countdown.card, C.Card(kind: .postPlay, secondsLeft: nil, total: nil), "no countdown")
        eq(countdown.accept(now: 3001), [.start(.accepted)], "Play Now still plays it")

        var noDuration = C(autoAdvance: false)
        _ = noDuration.itemEnded(now: 5)
        eq(noDuration.phase, .postPlay(until: nil), "after a file of unknown length too")
        eq(noDuration.clock(now: 500), [], "nothing")
    }

    func testStillWatchingAfterThreeChainedEpisodes() {
        // Three episodes started by the countdown alone, one after the other.
        var chained = 0
        for _ in 0..<3 {
            var countdown = C(autoAdvance: true, chainedWithoutAction: chained)
            _ = countdown.planReady(now: 0)
            eq(play(&countdown, from: 2600, to: 2700).map { $0.1 }, [.prefetch, .start(.deadline)], "episode \(chained + 1) chained")
            chained = countdown.chainedAfterStart
        }
        eq(chained, 3, "three in a row")
        var fourth = C(autoAdvance: true, chainedWithoutAction: chained)
        _ = fourth.planReady(now: 0)
        eq(play(&fourth, from: 2600, to: 2700).map { $0.1 }, [.prefetch], "the fourth: no start")
        eq(fourth.phase, .stillWatching, "« Still watching? »")
        eq(fourth.card, C.Card(kind: .stillWatching, secondsLeft: nil, total: nil), "no countdown on it")
        eq(fourth.clock(now: 9999), [], "it waits")
        eq(fourth.accept(now: 10000), [.start(.accepted)], "Continue: it starts")
        eq(fourth.chainedAfterStart, 0, "and the count starts again")
        var stop = C(autoAdvance: true, chainedWithoutAction: 3)
        _ = stop.planReady(now: 0)
        _ = play(&stop, from: 2600, to: 2700)
        eq(stop.cancel(now: 2701), [.closePlayer], "Stop: the player closes")
        // An action resets the count; « Play Now » is one.
        var pressed = C(autoAdvance: true, chainedWithoutAction: 2)
        _ = pressed.planReady(now: 0)
        _ = play(&pressed, from: 2600, to: 2680)
        _ = pressed.accept(now: 2681)
        eq(pressed.chainedAfterStart, 0, "Play Now is an action")
        // A setting of 0 asks at once (`-PTDebugUpNextStillAfter 0`).
        var zero = C(autoAdvance: true, tuning: { var t = C.Tuning(); t.stillWatchingAfter = 0; return t }())
        _ = zero.planReady(now: 0)
        _ = play(&zero, from: 2600, to: 2700)
        eq(zero.phase, .stillWatching, "after 0")
    }

    func testJumpToTheEndAndPrefetchOnce() {
        var countdown = C(autoAdvance: true)
        _ = countdown.tick(now: 0, position: 10, duration: 2700, isPlaying: true)
        let effects = countdown.tick(now: 1, position: 2699.5, duration: 2700, isPlaying: true)
        eq(effects, [.prefetch], "a seek to the very end: prefetch, then the countdown's end (the plan awaited)")
        eq(countdown.phase, .awaitingPlan(until: 4), "waits for its plan")
        eq(countdown.planReady(now: 2), [.start(.deadline)], "then starts")
        // A duration that changes (the remux learned the real one) re-arms the times.
        var growing = C(autoAdvance: true)
        _ = growing.tick(now: 0, position: 0, duration: 1000, isPlaying: true)
        _ = growing.tick(now: 1, position: 1, duration: 2700, isPlaying: true)
        eq(growing.cardAt, 2670, "the card follows the longer duration")
    }
}
