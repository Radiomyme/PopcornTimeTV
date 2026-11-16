//
//  VLCResumeWatchTests.swift
//  PopcornTimeTests
//
//  VLCResumeWatch (VLCResumeWatch.swift): a VLC player's resume is "arrived" only once its
//  clock RUNS at the target; a clock that shows 0:00 or the target, frozen, waits, and gets the
//  offer after 30 s. The runs R1, R3, R6 and R7 of the diagnosis (tvOS simulator, one sample a
//  second: reports/resume-repro-sim.md § 4) and the false-clock runs R2 / S2 are replayed.
//

import XCTest
import Foundation

final class VLCResumeWatchTests: CheckedTestCase {

    /// "04:18" → 258 s.
    private func seconds(_ clock: String) -> Double {
        clock.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    /// A run as the trace printed it: (clock, how many one-second samples in a row). A count of
    /// 0 stands for a run of single samples one second apart ("04:18…04:30").
    private typealias Run = [(clock: String, count: Int)]

    /// One sample a second from +1 s: the first phase change to each phase, in seconds after
    /// the start. The seek is issued at `seekAt`; the offer is answered « Keep waiting » when
    /// `keepsWaiting`.
    private func replay(_ run: Run, target: Double?, seekAt: Double = 1.5, keepsWaiting: Bool = false)
        -> (offers: [Int], arrived: Int?, arrival: VLCResumeWatch.Arrival?, watch: VLCResumeWatch) {
        var watch = VLCResumeWatch(target: target, now: 0)
        var offers: [Int] = [], arrived: Int?
        var second = 0, seekIssued = false
        for (clock, count) in run {
            for _ in 0..<count {
                second += 1
                if !seekIssued, Double(second) > seekAt { watch.seekIssued(now: seekAt); seekIssued = true }
                let before = watch.phase
                let phase = watch.observe(time: seconds(clock), isPlaying: true, now: Double(second))
                if phase == .offer, before != .offer {
                    offers.append(second)
                    if keepsWaiting { watch.keepWaiting(now: Double(second)) }
                }
                if phase == .arrived, arrived == nil { arrived = second }
            }
        }
        return (offers, arrived, watch.arrival, watch)
    }

    /// "04:18" … "05:24": one sample a second, the clock running.
    private func running(from: String, to: String) -> Run {
        (Int(seconds(from))...Int(seconds(to))).map { (String(format: "%02d:%02d", $0 / 60, $0 % 60), 1) }
    }

    // MARK: The rule

    func testWaitsOfferArrives() {
        // 1. Nothing yet (no time point), then a clock frozen at the target: waiting, the offer at 30 s.
        var w = VLCResumeWatch(target: 6000, now: 100)
        eq(w.observe(time: nil, isPlaying: true, now: 101), .waiting, "no time point: waiting")
        w.seekIssued(now: 101.5)
        for s in 2..<30 { eq(w.observe(time: 6000, isPlaying: true, now: 100 + Double(s)), .waiting, "frozen at the target, +\(s) s") }
        eq(w.observe(time: 6000, isPlaying: true, now: 130), .offer, "30 s of waiting: the offer")
        eq(w.observe(time: 6000, isPlaying: true, now: 131), .offer, "the offer stays until it is answered")
        check(w.arrival == nil, "no arrival yet")
        // 2. « Keep waiting »: 30 s more.
        w.keepWaiting(now: 131)
        eq(w.phase, .waiting, "keep waiting: waiting again")
        for s in 132..<161 { eq(w.observe(time: 6000, isPlaying: true, now: Double(s)), .waiting, "second wait, \(s)") }
        eq(w.observe(time: 6000, isPlaying: true, now: 161), .offer, "the offer again, 30 s later")
        // 3. The clock starts: arrived once it ran 2 s — through the offer.
        eq(w.observe(time: 6001, isPlaying: true, now: 162), .offer, "1 s run: not yet")
        eq(w.observe(time: 6002, isPlaying: true, now: 163), .arrived, "2 s run at the target: arrived")
        eq(w.arrival, .atTarget, "at the target")
        // 4. Arrived is for good.
        eq(w.observe(time: 0, isPlaying: true, now: 164), .arrived, "arrived stays")
        w.keepWaiting(now: 165)
        eq(w.phase, .arrived, "keep waiting after the arrival changes nothing")
    }

    func testAClockThatOnlyShowsTheTargetIsNotThere() {
        // Position = target is not enough (run R3: VLC shows the target without playing).
        var w = VLCResumeWatch(target: 1000, now: 0)
        eq(w.observe(time: 1000, isPlaying: true, now: 1), .waiting, "shows the target")
        // One step forward, then frozen again: the keyframe VLC settled on, not playback.
        eq(w.observe(time: 1001.5, isPlaying: true, now: 2), .waiting, "one step")
        eq(w.observe(time: 1001.5, isPlaying: true, now: 3), .waiting, "frozen again")
        eq(w.observe(time: 1001.5, isPlaying: true, now: 4), .waiting, "still frozen")
        // A jump is no run either (2 s of clock in one sample is the limit of a catch-up).
        eq(w.observe(time: 1030, isPlaying: true, now: 5), .waiting, "a jump of 28 s")
        eq(w.observe(time: 1031, isPlaying: true, now: 6), .waiting, "1 s after the jump")
        eq(w.observe(time: 1032, isPlaying: true, now: 7), .arrived, "2 s after the jump: it runs")
    }

    func testToleranceBeforeTheTarget() {
        // The seek lands on the keyframe before the target: up to 5 s before it counts.
        var near = VLCResumeWatch(target: 1000, now: 0)
        near.seekIssued(now: 0.5)
        _ = near.observe(time: 995, isPlaying: true, now: 1)
        _ = near.observe(time: 996, isPlaying: true, now: 2)
        eq(near.observe(time: 997, isPlaying: true, now: 3), .arrived, "5 s before the target: there")
        eq(near.arrival, .atTarget, "at the target")
        // VLC's clock steps back as it settles (2604.0 → 2602.2 s, part 2's run fhand2), then runs.
        var settle = VLCResumeWatch(target: 2604, now: 0)
        _ = settle.observe(time: 2604.0, isPlaying: true, now: 1)
        eq(settle.observe(time: 2602.2, isPlaying: true, now: 2), .waiting, "the step back")
        eq(settle.observe(time: 2603.2, isPlaying: true, now: 3), .waiting, "1 s")
        eq(settle.observe(time: 2604.2, isPlaying: true, now: 4), .arrived, "2 s from the step back")
        // A run that starts 8 s before the target enters the tolerance while it runs: at the target.
        var far = VLCResumeWatch(target: 1000, now: 0)
        far.seekIssued(now: 0.5)
        var phases: [VLCResumeWatch.Phase] = []
        for s in 0..<6 { phases.append(far.observe(time: 992 + Double(s), isPlaying: true, now: 3 + Double(s))) }
        eq(phases, [.waiting, .waiting, .waiting, .waiting, .waiting, .arrived], "8 s before, running into the tolerance")
        eq(far.arrival, .atTarget, "counted at the target")
    }

    func testRunningElsewhere() {
        // A clock that runs away from the target, after the seek: playback runs (a false clock,
        // or a lost seek) — the state goes away after 3 s of it, without the offer.
        var w = VLCResumeWatch(target: 696, now: 0)
        eq(w.observe(time: 0, isPlaying: true, now: 1), .waiting, "0:00 before the seek")
        w.seekIssued(now: 1.5)
        eq(w.observe(time: 696, isPlaying: true, now: 2), .waiting, "the target, frozen")
        eq(w.observe(time: 696, isPlaying: true, now: 3), .waiting, "frozen")
        eq(w.observe(time: 23, isPlaying: true, now: 4), .waiting, "00:23: the false clock starts")
        eq(w.observe(time: 24, isPlaying: true, now: 5), .waiting, "1 s")
        eq(w.observe(time: 25, isPlaying: true, now: 6), .waiting, "2 s: not enough away from the target")
        eq(w.observe(time: 26, isPlaying: true, now: 7), .arrived, "3 s: playback runs")
        eq(w.arrival, .elsewhere, "elsewhere")

        // Before the seek is issued, a clock running from 0:00 is the head playing: never an arrival.
        var head = VLCResumeWatch(target: 696, now: 0)
        for s in 1...10 { eq(head.observe(time: Double(s), isPlaying: true, now: Double(s)), .waiting, "no seek yet, +\(s) s") }
        // … and for 2 s after the seek VLC may still report the old position running.
        head.seekIssued(now: 10.2)
        eq(head.observe(time: 11, isPlaying: true, now: 11), .waiting, "0.8 s after the seek")
        eq(head.observe(time: 12, isPlaying: true, now: 12), .waiting, "1.8 s after the seek")
        eq(head.observe(time: 696, isPlaying: true, now: 13), .waiting, "then the target, frozen")
        eq(head.observe(time: 696, isPlaying: true, now: 14), .waiting, "frozen")
        // A seek VLC lost: the head plays on, 2 s after the seek and later → lifted.
        var lost = VLCResumeWatch(target: 696, now: 0)
        lost.seekIssued(now: 1)
        var phases: [VLCResumeWatch.Phase] = []
        for s in 1...7 { phases.append(lost.observe(time: Double(s), isPlaying: true, now: Double(s))) }
        eq(phases, [.waiting, .waiting, .waiting, .waiting, .waiting, .arrived, .arrived], "the head plays on after the seek")
        eq(lost.arrival, .elsewhere, "elsewhere")
    }

    func testTimerJitter() {
        // The players' one-second timers are a few hundredths off: two samples "a second apart"
        // count as a second of clock (0.2 s of slack), 1.7 s of clock do not count as two.
        var w = VLCResumeWatch(target: 100, now: 0)
        _ = w.observe(time: 100.00, isPlaying: true, now: 1.00)
        _ = w.observe(time: 100.97, isPlaying: true, now: 1.97)
        eq(w.observe(time: 101.95, isPlaying: true, now: 2.95), .arrived, "1.95 s of clock over two samples: there")
        var slow = VLCResumeWatch(target: 100, now: 0)
        _ = slow.observe(time: 100.0, isPlaying: true, now: 1)
        _ = slow.observe(time: 100.85, isPlaying: true, now: 2)
        eq(slow.observe(time: 101.7, isPlaying: true, now: 3), .waiting, "1.7 s of clock: not yet")
        eq(slow.observe(time: 102.55, isPlaying: true, now: 4), .arrived, "2.55 s: there")
        var off = VLCResumeWatch(target: 700, now: 0)
        off.seekIssued(now: 0.5)
        _ = off.observe(time: 43.02, isPlaying: true, now: 3.01)
        _ = off.observe(time: 44.01, isPlaying: true, now: 4.00)
        _ = off.observe(time: 45.02, isPlaying: true, now: 5.01)
        eq(off.observe(time: 46.01, isPlaying: true, now: 6.00), .arrived, "2.99 s of a false clock over three samples: lifted")
    }

    func testTargetUnknownThenKnown() {
        // The film's length is not known at play(): no target yet.
        var w = VLCResumeWatch(target: nil, now: 0)
        check(w.target == nil, "no target")
        eq(w.observe(time: 0, isPlaying: true, now: 1), .waiting, "0:00")
        w.setTarget(600)
        eq(w.target, 600, "the target, once the length is known")
        w.setTarget(700)
        eq(w.target, 600, "the first target stays")
        w.seekIssued(now: 1.2)
        _ = w.observe(time: 600, isPlaying: true, now: 2)
        _ = w.observe(time: 601, isPlaying: true, now: 3)
        eq(w.observe(time: 602, isPlaying: true, now: 4), .arrived, "arrived at the late target")
        // A target that is no number is no target.
        check(VLCResumeWatch(target: .nan, now: 0).target == nil, "NaN")
        check(VLCResumeWatch(target: -1, now: 0).target == nil, "negative")
        var never = VLCResumeWatch(target: nil, now: 0)
        never.setTarget(.infinity)
        check(never.target == nil, "infinite")
    }

    func testPausedAndSuspended() {
        // VLC paused: it neither arrives nor waits (the offer's 30 s count playback wanted).
        var w = VLCResumeWatch(target: 500, now: 0)
        for s in 1...20 { _ = w.observe(time: 500, isPlaying: true, now: Double(s)) }
        eq(w.waited, 20, "20 s waited")
        for s in 21...80 { eq(w.observe(time: 500, isPlaying: false, now: Double(s)), .waiting, "paused, +\(s) s") }
        eq(w.waited, 20, "a paused VLC does not wait")
        for s in 81...89 { eq(w.observe(time: 500, isPlaying: true, now: Double(s)), .waiting, "playing again, +\(s) s") }
        eq(w.observe(time: 500, isPlaying: true, now: 90), .offer, "30 s of wanted playback: the offer")
        // A paused clock that moved is no run.
        var p = VLCResumeWatch(target: 500, now: 0)
        _ = p.observe(time: 500, isPlaying: true, now: 1)
        _ = p.observe(time: 501, isPlaying: false, now: 2)
        eq(p.observe(time: 502, isPlaying: true, now: 3), .waiting, "the run starts again after the pause")
        // The app suspended for ten minutes: one sample adds 2 s at most — no offer on return.
        var s = VLCResumeWatch(target: 500, now: 0)
        _ = s.observe(time: 500, isPlaying: true, now: 1)
        eq(s.observe(time: 500, isPlaying: true, now: 601), .waiting, "back from the background")
        eq(s.waited, 3, "1 s + 2 s counted")
    }

    func testSamplesTwiceASecond() {
        // The macOS player refreshes every 0.5 s: samples closer than 0.75 s are skipped, so a
        // clock VLC did not move between two refreshes does not break the run.
        var w = VLCResumeWatch(target: 300, now: 0)
        w.seekIssued(now: 0.2)
        var arrivedAt: Double?
        let clocks: [Double] = [300, 300, 300.5, 300.5, 301.5, 301.5, 302.5, 302.5, 303.5]
        for (i, clock) in clocks.enumerated() {
            let now = 1 + Double(i) * 0.5
            if w.observe(time: clock, isPlaying: true, now: now) == .arrived, arrivedAt == nil { arrivedAt = now }
        }
        eq(arrivedAt, 4, "arrived with half-second samples")
        // The wait still counts every sample.
        var t = VLCResumeWatch(target: 300, now: 0)
        for i in 1...59 { _ = t.observe(time: 300, isPlaying: true, now: Double(i) * 0.5) }
        eq(t.phase, .waiting, "29.5 s")
        eq(t.observe(time: 300, isPlaying: true, now: 30), .offer, "30 s, half-second samples")
    }

    // MARK: The diagnosis runs, replayed

    func testRunR1_ownDemuxerReadsThrough() {
        // R1 (full storage, VLC's own demuxer, H.264 + text subtitles, 330 s, resume at 78.125 %
        // = 4:17.8): 00:00 for 204 s while VLC reads the file from its head, then 04:18, 04:20…
        let run: Run = [("00:00", 204), ("04:18", 1)] + running(from: "04:20", to: "05:24")
        let target = 0.78125 * 330
        let silent = replay(run, target: target)
        eq(silent.offers, [30], "R1: the offer 30 s in (5.2.0 showed nothing for 204 s)")
        eq(silent.arrived, 206, "R1: arrived when the clock runs at 4:18")
        eq(silent.arrival, .atTarget, "R1: at the target")
        let patient = replay(run, target: target, keepsWaiting: true)
        eq(patient.offers, [30, 60, 90, 120, 150, 180], "R1: « keep waiting » brings the offer back every 30 s")
        eq(patient.arrived, 206, "R1: the same arrival")
    }

    func testRunR3_clockFrozenAtTheTarget() {
        // R3 (full storage, VLC's own demuxer, HEVC + E-AC-3, 358 s): 00:00, then the target
        // 04:39 for the 116 s of the run — VLC shows the resume point and plays nothing.
        let r = replay([("00:00", 1), ("04:39", 116)], target: 0.78125 * 358, keepsWaiting: true)
        check(r.arrived == nil, "R3: never arrived — the target shown is not playback")
        eq(r.offers, [30, 60, 90], "R3: the offer at 30 s, again every 30 s")
        eq(r.watch.phase, .waiting, "R3: still waiting at the end")
    }

    func testRunR6_boundedLibavformatSubtitles() {
        // R6 (bounded storage, libavformat, H.264 + text subtitles, 990 s): the target 12:53
        // frozen for 18 s, then it runs.
        let r = replay([("00:00", 1), ("12:53", 18)] + running(from: "12:54", to: "13:09"), target: 0.78125 * 990)
        eq(r.offers, [], "R6: no offer")
        eq(r.arrived, 21, "R6: arrived 2 s after the clock starts (+20 s)")
        eq(r.arrival, .atTarget, "R6: at the target")
    }

    func testRunR7_boundedLibavformat() {
        // R7 (bounded storage, libavformat, HEVC + E-AC-3, 985 s): 00:00 for 7 s, then 12:50…
        let r = replay([("00:00", 7)] + running(from: "12:50", to: "13:11"), target: 0.78125 * 985)
        eq(r.offers, [], "R7: no offer")
        eq(r.arrived, 10, "R7: arrived at +10 s")
        eq(r.arrival, .atTarget, "R7: at the target")
    }

    func testRunsR2S2_falseClock() {
        // R2 (full storage, libavformat forced, text subtitles, 330 s): the target 04:17 frozen
        // for 11 s, then the picture plays at the target while VLC reports 00:21…00:30, then
        // 04:28, 04:24… The state must go away while the picture plays, without the offer.
        let r2: Run = [("00:00", 1), ("04:17", 11)] + running(from: "00:21", to: "00:30")
            + [("04:28", 1)] + running(from: "04:24", to: "04:28")
        let a = replay(r2, target: 0.78125 * 330)
        eq(a.offers, [], "R2: no offer")
        eq(a.arrived, 16, "R2: lifted 3 s into the false clock (+13 s)")
        eq(a.arrival, .elsewhere, "R2: elsewhere — the clock is off")
        // S2 (the same on the 5.3.0 base, slower seed): 04:17 for 25 s, then 00:33…00:44.
        let b = replay([("00:00", 1), ("04:17", 25)] + running(from: "00:33", to: "00:44"), target: 0.78125 * 330)
        eq(b.offers, [], "S2: no offer")
        eq(b.arrived, 30, "S2: lifted 3 s into the false clock (+27 s)")
        eq(b.arrival, .elsewhere, "S2: elsewhere")
    }

    func testRunR4_fullLibavformat() {
        // R4 (full storage, libavformat, HEVC + E-AC-3, 358 s): 00:00 for 14 s, then 04:40…
        let r = replay([("00:00", 14)] + running(from: "04:40", to: "04:51"), target: 0.78125 * 358)
        eq(r.offers, [], "R4: no offer")
        eq(r.arrived, 17, "R4: arrived at +17 s")
    }

    func testNoTimePointAtAll() {
        // D5 / D6 of the VLC bench: VLC stays in « opening », no time point for 20 s and more.
        var w = VLCResumeWatch(target: nil, now: 0)
        var offerAt: Int?
        for s in 1...40 where offerAt == nil {
            if w.observe(time: nil, isPlaying: true, now: Double(s)) == .offer { offerAt = s }
        }
        eq(offerAt, 30, "no time point: the offer all the same")
    }

    // MARK: The wait the players keep

    func testWaitTargetLabelAndPause() {
        var wait = VLCResumeWait(fraction: 0.7, durationSeconds: nil, now: 0)
        check(wait.watch.target == nil, "no length: no target")
        eq(wait.position, "70 %", "the percentage while the length is not known")
        _ = wait.sample(time: nil, isPlaying: true, durationSeconds: nil, now: 1)
        _ = wait.sample(time: 0, isPlaying: true, durationSeconds: 0, now: 2)
        check(wait.watch.target == nil, "a length of 0 is not a length")
        _ = wait.sample(time: 0, isPlaying: true, durationSeconds: 8571.5, now: 3)
        eq(wait.watch.target ?? 0, Double(Float(0.7)) * 8571.5, "the target from the length")
        eq(wait.position, "1:40:00", "the clock time once the length is known")
        _ = wait.sample(time: 0, isPlaying: true, durationSeconds: 9000, now: 4)
        eq(wait.position, "1:40:00", "the first length stays")
        check(!wait.pausesAtArrival, "no pause wanted")
        check(wait.togglePauseAtArrival(), "Play/Pause during the wait: pause at the arrival")
        check(!wait.togglePauseAtArrival(), "again: playback at the arrival")
        wait.seekIssued(now: 4.5)
        _ = wait.sample(time: 6000, isPlaying: true, durationSeconds: 8571.5, now: 5)
        _ = wait.sample(time: 6001, isPlaying: true, durationSeconds: 8571.5, now: 6)
        eq(wait.sample(time: 6002, isPlaying: true, durationSeconds: 8571.5, now: 7), .arrived, "the wait arrives")
        eq(wait.phase, .arrived, "its phase")
        // Known from the start.
        let known = VLCResumeWait(fraction: 0.5, durationSeconds: 100, now: 0)
        eq(known.watch.target ?? 0, 50, "the target at once")
        eq(known.position, "0:50", "its clock time")
    }

    // MARK: The texts

    func testKeysAreInTheSevenTables() {
        let folder = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PopcornTime")
        let tables = ["Base", "en", "fr", "es", "it", "pt-BR", "ar"]
        eq(VLCResumeText.localizationKeys.count, 5, "five keys")
        var resumingAt: [String: String] = [:]
        for table in tables {
            let strings = NSDictionary(contentsOf: folder.appendingPathComponent("\(table).lproj/Localizable.strings")) as? [String: String]
            check(strings != nil, "\(table): the table reads")
            for key in VLCResumeText.localizationKeys {
                let value = strings?[key] ?? ""
                check(!value.isEmpty, "\(table): \(key) is there")
                let placeholders = value.components(separatedBy: "%@").count - 1
                eq(placeholders, key == "VLC.Resume.At" ? 1 : 0, "\(table): \(key) has its placeholder")
                check(!value.contains("%d") && !value.contains("%1$"), "\(table): \(key) has no other format")
            }
            resumingAt[table] = strings?["VLC.Resume.At"]
            // The native lane's keys are not this lane's to add.
            check(strings?["Player.Resuming.At"] == nil || strings?["VLC.Resume.At"] != nil, "\(table): VLC's own label")
        }
        eq(resumingAt["Base"], resumingAt["en"], "Base and en agree")
        eq(resumingAt["fr"], "Reprise à %@…", "the French label")
        // Translated: the five other languages do not repeat the English text.
        for table in ["fr", "es", "it", "pt-BR", "ar"] {
            check(resumingAt[table] != resumingAt["en"], "\(table): translated")
        }
    }

    // MARK: « Start from the beginning » of the slow-resume offer (VLCSlowResumeRestart)

    /// Run e11f's sequence (no-Cues file saved at 70 %, resumed through VLC, the offer answered
    /// « Start from the beginning »): during the wait VLC reports 0:00; the reopened media plays
    /// from 0:00; the user closes after a few seconds. The saved point is kept until playback
    /// from 0:00 has really run, then follows it.
    func testSlowResumeRestartKeepsTheResumePointUntilPlaybackFromTheStartRan() {
        let saved: Float = 0.703125
        var progress = VLCWatchProgress(startPosition: saved, resumePoint: saved)
        // The wait: VLC's clock at 0:00 (its first tick, +1 s and +2 s).
        progress.note(position: 0.0006)
        progress.note(position: 0.0006)
        eq(progress.progressToSave(), saved, "during the wait: the resume point")

        // 5.3.0 before this fix: the restart unprotected it at once (and kept the stale 0.0006).
        var unprotected = progress
        unprotected.restartFromBeginning()
        eq(unprotected.progressToSave(), 0.0006, "the old rule: a stale position replaces the resume point")

        progress = VLCSlowResumeRestart.progress(restartingFrom: progress)
        eq(progress.resumePoint, saved, "the resume point is carried over")
        check(progress.lastPosition == nil, "no stale position of the resume's input")
        check(progress.progressToSave() == nil, "before the new input's first tick: nothing is saved")
        eq(progress.highWater, 0, "the wait's high water is dropped")

        // The reopened media's first ticks, then a Menu a few seconds in.
        progress.note(position: 0.0001)
        check(progress.progressToSave() == nil, "first tick from 0:00: the resume point stays")
        progress.note(position: 0.0011)
        check(progress.progressToSave() == nil, "a close a few seconds in: the resume point stays")
        check(!VLCSlowResumeRestart.isConfirmed(clockSeconds: 7), "7 s in: not confirmed")
        check(!VLCSlowResumeRestart.isConfirmed(clockSeconds: nil), "no time yet: not confirmed")
        check(!VLCSlowResumeRestart.isConfirmed(clockSeconds: .nan), "a NaN clock: not confirmed")
        check(!VLCSlowResumeRestart.isConfirmed(clockSeconds: VLCSlowResumeRestart.confirmSeconds - 1), "just before")

        // Playback from 0:00 really ran: the restart is the user's (what the players do then).
        progress.note(position: 0.03)
        check(VLCSlowResumeRestart.isConfirmed(clockSeconds: VLCSlowResumeRestart.confirmSeconds), "3:00 in: confirmed")
        progress.restartFromBeginning()
        eq(progress.progressToSave(), 0.03, "confirmed: the position from 0:00 is saved")

        // Watching past the resume point before the confirmation (a forward scrub) saves as ever.
        var scrubbed = VLCSlowResumeRestart.progress(restartingFrom: VLCWatchProgress(startPosition: saved, resumePoint: saved))
        scrubbed.note(position: 0.75)
        eq(scrubbed.progressToSave(), 0.75, "past the resume point: saved")
    }

    /// Gate run g11f/g11c: a time tick of the abandoned input, still queued when the media
    /// is opened again, reports the resume point's clock (692 s) before the new input's 0:00.
    /// It must not confirm the restart — only playback from near 0:00 to 3:00 does.
    func testSlowResumeRestartIgnoresAStaleTickOfTheAbandonedInput() {
        var confirmation = VLCSlowResumeRestart.Confirmation()
        check(!confirmation.note(clockSeconds: 692), "the stale tick at 11:32: not confirmed")
        check(!confirmation.sawStart, "the stale tick does not count as the new input's start")
        check(!confirmation.note(clockSeconds: nil), "no time yet")
        check(!confirmation.note(clockSeconds: .nan), "a NaN clock")
        check(!confirmation.note(clockSeconds: 0), "the new input's first tick at 0:00")
        check(confirmation.sawStart, "0:00 seen")
        check(!confirmation.note(clockSeconds: 7), "7 s in")
        check(!confirmation.note(clockSeconds: VLCSlowResumeRestart.confirmSeconds - 1), "just before 3:00")
        check(confirmation.note(clockSeconds: VLCSlowResumeRestart.confirmSeconds), "3:00 in: confirmed")

        // A stale tick after the start was seen still needs 3:00 of the clock: a late stale
        // tick below 3:00 confirms nothing.
        var late = VLCSlowResumeRestart.Confirmation()
        check(!late.note(clockSeconds: 1), "0:01")
        check(!late.note(clockSeconds: 120), "a 2:00 clock")
    }
}
