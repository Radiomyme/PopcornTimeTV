//
//  FarTargetWatchP11Tests.swift
//  PopcornTimeTests
//
//  FarTargetWatch (PlaybackRouting.swift), round 11: the pace is measured between
//  frontier moves; hand-offs to VLC for far targets, native waits for near ones, on
//  simulated downloads. (Port of the P11 bench: 35 checks.)
//

import XCTest
import Foundation

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// An in-order download from `c0` (media s) at `pace`× after `stall` s; its chunks (segments of `seg` s, or pieces of
/// pace × `piece` s) take their nominal time × (1 ± jitter). Frontier: the last segment boundary at or below the bytes
/// on disk — block by block (`gated` false) or only at piece completions (`gated` true). Progress: published every
/// 0.5 s (`piece` nil) or per piece.
private struct Download {
    var bp: [(t: Double, x: Double)] = []
    var pieces: [(t: Double, x: Double)] = []
    var pieceStart = 0.0
    let f0: Double, seg: Double, gated: Bool, piece: Double?
    init(f0: Double, offset: Double, seg: Double, pace: Double, stall: Double = 0, piece: Double? = nil, gated: Bool = false,
         jitter: Double = 0, seed: UInt64 = 1, horizon: Double = 200) {
        self.f0 = f0; self.seg = seg; self.gated = gated; self.piece = piece
        var rng = SplitMix(state: seed)
        func j() -> Double { jitter > 0 ? Double.random(in: -jitter...jitter, using: &rng) : 0 }
        let c0 = f0 + offset
        var t = stall, x = c0
        bp.append((t, x))
        if let dp = piece {
            let p = pace * dp
            pieceStart = f0 - p * 0.37 + ((c0 - (f0 - p * 0.37)) / p).rounded(.down) * p
            var next = pieceStart + p
            var d = dp * (1 + j()) * (next - c0) / p
            while t < horizon { t += d; x = next; bp.append((t, x)); pieces.append((t, x)); next += p; d = dp * (1 + j()) }
        } else {
            var next = f0 + seg
            while next <= c0 { next += seg }
            var d = (next - c0) / pace * (1 + j())
            while t < horizon { t += d; x = next; bp.append((t, x)); next += seg; d = seg / pace * (1 + j()) }
        }
    }
    func position(_ t: Double) -> Double {
        if t <= bp[0].t { return bp[0].x }
        var lo = 0, hi = bp.count - 1
        if t >= bp[hi].t { return bp[hi].x }
        while hi - lo > 1 { let m = (lo + hi) / 2; if bp[m].t <= t { lo = m } else { hi = m } }
        return bp[lo].x + (bp[hi].x - bp[lo].x) * (t - bp[lo].t) / (bp[hi].t - bp[lo].t)
    }
    func completed(_ t: Double) -> Double { pieces.last { $0.t <= t }?.x ?? pieceStart }
    func frontier(_ t: Double) -> Double {
        let x = gated ? completed(t) : position(t)
        return f0 + ((x - f0) / seg + 1e-9).rounded(.down) * seg
    }
    func progress(_ t: Double) -> Float {
        if piece != nil { return Float(completed(t) / 7200) }
        return Float(position((t / 0.5).rounded(.down) * 0.5) / 7200)
    }
}

/// Feeds a fresh watch at 1 Hz from `phase` and returns the first hand-off time (s after the seek), nil if none before
/// the frontier covers the target or `until`.
private func handOff(_ d: Download, target: Double, phase: Double = 0.3, until: Double = 120,
             progress: Bool = true) -> (t: Double, eta: Double?)? {
    var w = FarTargetWatch()
    var t = phase
    while t <= until {
        let f = d.frontier(t)
        if f >= target { return nil }
        if w.shouldHandOff(target: target, frontierSeconds: f, downloadProgress: progress ? d.progress(t) : nil,
                           remuxFinished: false, now: 1000 + t) { return (t, w.estimatedSecondsToTarget) }
        t += 1
    }
    return nil
}
private func fmt(_ h: (t: Double, eta: Double?)?) -> String {
    h.map { String(format: "hand-off at +%.1f s (ETA %.0f s)", $0.t, $0.eta ?? -1) } ?? "no hand-off"
}

final class FarTargetWatchP11Tests: CheckedTestCase {

    func testRound11() {
        print("== C. COARSEPROG — per-piece progress")
        do {
            // C1 the R8-#7 journey (20:00 → 50:00, frontier 23:00, 1620 s ahead) at 1.2×, 6 s segments, one progress change per
            // piece every Δp s (no jitter: the reviewer's "never in 400/400" case at 7 s), every tick phase.
            for dp in [7.0, 8.0, 10.0, 15.0] {
                var worst = 0.0, never = 0
                for k in 0..<10 {
                    let d = Download(f0: 1380, offset: 3, seg: 6, pace: 1.2, piece: dp)
                    if let h = handOff(d, target: 3000, phase: Double(k) / 10) { worst = max(worst, h.t) } else { never += 1 }
                }
                let deadline = dp <= 10 ? 25.0 : 38.0
                expect(never == 0 && worst <= deadline, "C1 [R10 FAIL] R8-#7 at 1.2×, progress every \(Int(dp)) s: VLC within \(Int(deadline)) s in 10/10 tick phases",
                       "worst +\(String(format: "%.1f", worst)) s, never \(never)/10")
            }
            // C2 piece-gated (F3 x37f's model): the frontier jumps only when a piece completes; x37's target 184 s ahead.
            for dp in [7.0, 10.0] {
                var worst = 0.0, never = 0
                for k in 0..<10 {
                    let d = Download(f0: 216, offset: 2, seg: 6, pace: 1.2, piece: dp, gated: true, jitter: 0.1, seed: UInt64(k + 1))
                    if let h = handOff(d, target: 400, phase: Double(k) / 10) { worst = max(worst, h.t) } else { never += 1 }
                }
                expect(never == 0 && worst <= 25, "C2 [R10 FAIL] x37f piece-gated, a piece every \(Int(dp)) s at 1.2×, 184 s ahead: VLC within 25 s",
                       "worst +\(String(format: "%.1f", worst)) s, never \(never)/10")
            }
            // C3 the reviewer's piecestep sweep: 16 Mb/s at 1.2×, pieces every Δ s ±15 %, 200 seeds; frontier block by block.
            for delta in [6.0, 7.0, 8.0, 10.0] {
                var within = 0, worst = 0.0
                for s in 0..<200 {
                    let d = Download(f0: 1380, offset: 3, seg: 6, pace: 1.2, piece: delta, jitter: 0.15, seed: UInt64(s) * 7919 + 3)
                    if let h = handOff(d, target: 3000, phase: Double(s % 4) * 0.25, until: 60) {
                        worst = max(worst, h.t); if h.t <= 25 { within += 1 }
                    }
                }
                expect(within == 200, "C3 [R10 FAIL] piecestep Δ = \(Int(delta)) s ±15 %: VLC within 25 s in 200/200 seeds",
                       "\(within)/200, worst +\(String(format: "%.1f", worst)) s")
            }
            // C4 per-piece progress and a target ~30 s of download away: native (the far rule must not fire on coarse progress).
            var near = 0
            for k in 0..<10 {
                let d = Download(f0: 1380, offset: 3, seg: 6, pace: 1.2, piece: 10)
                if handOff(d, target: 1416, phase: Double(k) / 10) != nil { near += 1 }
            }
            expect(near == 0, "C4 per-piece progress (10 s), a target the frontier reaches in ~30 s: never", "\(near)/10 hand-offs")
        }

        print("== O. ONEWINDOW — reachable targets stay native")
        do {
            /// The reviewer's farwatch model (continuous download, frontier at whole segments, fine progress), all 20 phases.
            func cell(seg: Double, pace: Double, stall: Double, gap: Double, offset: Double = 0) -> Int {
                var hands = 0
                for i in 0..<20 {
                    let d = Download(f0: 2000 - gap, offset: offset, seg: seg, pace: pace, stall: stall)
                    if handOff(d, target: 2000, phase: Double(i) / 20, until: 150) != nil { hands += 1 }
                }
                return hands
            }
            for gap in [55.0, 60, 65] {
                let h = cell(seg: 6, pace: 1.5, stall: 0, gap: gap)
                expect(h == 0, "O1 [R10 FAIL] 6 s steps at 1.5×, target \(Int(gap)) s ahead (reached in \(Int(gap / 1.5)) s): native", "\(h)/20 hand-offs")
            }
            for (pace, gaps) in [(2.0, [55.0, 65, 75]), (3.0, [70.0, 90, 110])] {
                for gap in gaps {
                    let h = cell(seg: 6, pace: pace, stall: 10, gap: gap)
                    expect(h == 0, "O2 [R10 FAIL] 10 s stall then \(pace)×, target \(Int(gap)) s ahead (reached \(Int(gap / pace)) s after the stall): native", "\(h)/20 hand-offs")
                }
            }
            for gap in [90.0, 100, 110] {
                let h = cell(seg: 10.4, pace: 2.5, stall: 0, gap: gap)
                expect(h == 0, "O3 [R10 FAIL] 10.4 s steps at 2.5×, target \(Int(gap)) s ahead (reached in \(Int(gap / 2.5)) s): native", "\(h)/20 hand-offs")
            }
            // O4 farwatch5's grid: every tick phase × segment offset, targets reached within 30–44 s.
            var worstCell = (rate: 0, label: "")
            for seg in [6.0, 10.4] {
                for pace in [1.2, 1.3, 1.5, 1.7, 1.9, 2.2, 2.6, 3.0] {
                    for reach in [30.0, 35.0, 40.0, 44.0] {
                        var hands = 0
                        for i in 0..<10 { for j in 0..<10 {
                            let gap = reach * pace
                            let d = Download(f0: 2000 - gap, offset: seg * Double(j) / 10, seg: seg, pace: pace)
                            if handOff(d, target: 2000, phase: Double(i) / 10, until: 150) != nil { hands += 1 }
                        } }
                        if hands > worstCell.rate { worstCell = (hands, "seg \(seg) \(pace)× reach \(Int(reach)) s") }
                    }
                }
            }
            expect(worstCell.rate == 0, "O4 [R10 FAIL] farwatch5's grid (6 / 10.4 s steps, 1.2–3×, reached in 30–44 s): no hand-off",
                   worstCell.rate == 0 ? "" : "worst \(worstCell.label): \(worstCell.rate)%")
            // O5 the far controls still decide in the first measured steps.
            for gap in [188.0, 1570] {
                var worst = 0.0, never = 0
                for i in 0..<20 {
                    let d = Download(f0: 2000 - gap, offset: 0, seg: 6, pace: 1.2)
                    if let h = handOff(d, target: 2000, phase: Double(i) / 20) { worst = max(worst, h.t) } else { never += 1 }
                }
                expect(never == 0 && worst <= 14, "O5 far control \(Int(gap)) s ahead at 1.2×: VLC within 14 s (x37's deadline)",
                       "worst +\(String(format: "%.1f", worst)) s, never \(never)/20")
            }
            // O6 a 4× download and a target 100 s of download away (400 s ahead): still decides within 14 s.
            var worst4 = 0.0, never4 = 0
            for i in 0..<20 {
                let d = Download(f0: 1600, offset: 3 * Double(i % 2), seg: 6, pace: 4)
                if let h = handOff(d, target: 2000, phase: Double(i) / 20) { worst4 = max(worst4, h.t) } else { never4 += 1 }
            }
            expect(never4 == 0 && worst4 <= 14, "O6 4× download, target 400 s ahead: VLC within 14 s", "worst +\(String(format: "%.1f", worst4)) s, never \(never4)/20")
        }

        print("== K. Kept invariants")
        do {
            // K1 frozen frontier while the download grows (fine and per-piece): never, 300 s.
            for dp in [0.5, 7.0] {
                var w = FarTargetWatch()
                var handed = false
                for k in 0..<300 {
                    let t = 0.4 + Double(k)
                    let p = Float(0.2 + 0.0004 * ((t / dp).rounded(.down) * dp))
                    if w.shouldHandOff(target: 1600, frontierSeconds: 1200, downloadProgress: p, remuxFinished: false, now: t) { handed = true; break }
                }
                expect(!handed, "K1 frozen frontier, download growing (progress every \(dp) s): no decision in 300 s")
            }
            // K2 x18d: held seek while the swarm stalls — the remux writes 0–2 segments from disk (catch-up), frozen ≥ 6 s —
            // then a FAST return (+30 s at once, then 60 media-s per s), progress constant until then; never.
            var x18 = 0, x18runs = 0
            for catchUp in 0...2 {
                for frozen in [6.0, 8.0, 12.0] {
                    for i in 0..<10 {
                        var w = FarTargetWatch()
                        let back = frozen + Double(i) / 10
                        func frontier(_ t: Double) -> Double {
                            var f = 204.0
                            if catchUp >= 1, t >= 3 { f += 6 }
                            if catchUp >= 2, t >= 4.5 { f += 6 }
                            if t >= back + 0.6 { f = 204 + 6 * Double(catchUp) + 30 + (60 * (t - back - 0.6) / 6).rounded(.down) * 6 }
                            return f
                        }
                        func progress(_ t: Double) -> Float { t < back ? 0.3234 : min(1, 0.3234 + Float(0.2 * ((t - back) / 0.5).rounded(.down) * 0.5 + 0.02)) }
                        x18runs += 1
                        for k in 0..<40 {
                            let t = Double(i) / 10 + Double(k)
                            let f = frontier(t)
                            if f >= 500 { break }
                            if w.shouldHandOff(target: 500, frontierSeconds: f, downloadProgress: progress(t), remuxFinished: false, now: t) { x18 += 1; break }
                        }
                    }
                }
            }
            expect(x18 == 0, "K2 x18d: stalled swarm (catch-up 0–2 segments, frozen 6–12 s), then a fast return: never", "\(x18)/\(x18runs) hand-offs")
            // K3 pump-bound: the remux writes on-disk data (6 s segments at its 1 Hz timer) while the download grows
            // elsewhere (fine / per piece).
            // R12 (fix_round12.md, M5 REVISED — the round-11 rule "≥ 5× never decides" is withdrawn): a pump at 30–120×
            // toward a target it reaches within 40 s never decides (K3); a slow pump (5–20×) toward a target 3000 s ahead
            // follows the principle (the frontier needs 150–600 s at that pace): it goes to VLC (K3b, informative).
            var pump = 0, pumpRuns = 0
            for rate in [30.0, 60.0, 120.0] {
                for dp in [0.5, 7.0] {
                    for i in 0..<10 {
                        var w = FarTargetWatch()
                        pumpRuns += 1
                        let target = 1200 + rate * 39
                        for k in 0..<120 {
                            let t = Double(i) / 10 + Double(k)
                            let f = 1200 + ((rate * Double(k)) / 6).rounded(.down) * 6
                            if f >= target { break }
                            let p = Float(0.4 + 0.0003 * ((t / dp).rounded(.down) * dp))
                            if w.shouldHandOff(target: target, frontierSeconds: f, downloadProgress: p, remuxFinished: false, now: t) { pump += 1; break }
                        }
                    }
                }
            }
            expect(pump == 0, "K3 (R12: M5 revised) pump 30–120× toward a target it reaches within 40 s, download growing: never", "\(pump)/\(pumpRuns) hand-offs")
            var slowPump = 0, slowRuns = 0
            for rate in [5.0, 8.0, 20.0] {
                for dp in [0.5, 7.0] {
                    for i in 0..<10 {
                        var w = FarTargetWatch()
                        slowRuns += 1
                        for k in 0..<120 {
                            let t = Double(i) / 10 + Double(k)
                            let f = 1200 + ((rate * Double(k)) / 6).rounded(.down) * 6
                            let p = Float(0.4 + 0.0003 * ((t / dp).rounded(.down) * dp))
                            if w.shouldHandOff(target: 4200, frontierSeconds: f, downloadProgress: p, remuxFinished: false, now: t) { slowPump += 1; break }
                        }
                    }
                }
            }
            print("  info K3b (R12) slow pump 5–20× toward a target 3000 s ahead (150–600 s at that pace): \(slowPump)/\(slowRuns) go to VLC (the principle)")
            // K4 complete payload (1.0, constant) at 1–4× (a slow pump) and a finished remux: never.
            var complete = 0
            for rate in [1.0, 2.0, 4.0] {
                var w = FarTargetWatch(), wf = FarTargetWatch()
                for k in 0..<120 {
                    let t = Double(k), f = 1200 + ((rate * t) / 6).rounded(.down) * 6
                    if w.shouldHandOff(target: 4000, frontierSeconds: f, downloadProgress: 1, remuxFinished: false, now: t) { complete += 1; break }
                    if wf.shouldHandOff(target: 4000, frontierSeconds: f, downloadProgress: 0.5 + Float(t) * 0.001, remuxFinished: true, now: t) { complete += 1; break }
                }
            }
            expect(complete == 0, "K4 complete payload (1.0) or a finished remux: never", "\(complete) hand-offs")
            // K5 drag: the target moves by > 1 s every tick for 20 s → no decision; settled 600 s ahead → decides within 14 s.
            var w = FarTargetWatch()
            var mid = false
            var settled: Double?
            for k in 0..<60 {
                let t = 0.3 + Double(k)
                let f = 1200 + ((1.2 * t) / 6).rounded(.down) * 6
                let target = k < 20 ? 1400 + 7 * Double(k) : 1800
                let p = Float(0.2 + 0.0002 * t)
                let h = w.shouldHandOff(target: target, frontierSeconds: f, downloadProgress: p, remuxFinished: false, now: t)
                if h, k < 20 { mid = true; break }
                if h { settled = t - 19.3; break }
            }
            expect(!mid && settled.map { $0 <= 14 } == true, "K5 drag: no decision mid-drag; settled → a new measurement decides",
                   "settled decision +\(settled.map { String(format: "%.1f", $0) } ?? "never") s")
            // K6 a receding frontier (another session's) and invalid samples: no decision.
            var r = FarTargetWatch()
            var rec = false
            for k in 0..<30 { if r.shouldHandOff(target: 3000, frontierSeconds: 1430 - Double(k), downloadProgress: 0.3 + Float(k) * 0.001, remuxFinished: false, now: Double(k)) { rec = true } }
            var v = FarTargetWatch()
            let invalid = v.shouldHandOff(target: .nan, frontierSeconds: 1, remuxFinished: false, now: 0)
                || v.shouldHandOff(target: -5, frontierSeconds: 1, remuxFinished: false, now: 1)
                || v.shouldHandOff(target: 50, frontierSeconds: .infinity, remuxFinished: false, now: 2)
                || v.shouldHandOff(target: 50, frontierSeconds: 1, remuxFinished: false, now: .nan)
            expect(!rec && !invalid, "K6 receding frontier / NaN / negative / infinite: no decision")
            // K7 the logged estimate: x37 (6 s steps at 1.2×, 184 s ahead) → the seconds the frontier needs at 1.2× (±20 %).
            let d = Download(f0: 216, offset: 1, seg: 6, pace: 1.2)
            if let h = handOff(d, target: 400, phase: 0.5) {
                let truth = (400 - d.frontier(h.t)) / 1.2
                expect(h.eta.map { abs($0 - truth) / truth <= 0.1 } == true, "K7 [R10 FAIL] estimatedSecondsToTarget ≈ the frontier's time to the target at the download's pace (±10 %)",
                       String(format: "estimate %.0f s, frontier at 1.2× %.0f s (round 10 read one segment per window: ~1.0×)", h.eta ?? -1, truth))
            } else {
                expect(false, "K7 x37 decides", "no hand-off")
            }
        }
    }
}
