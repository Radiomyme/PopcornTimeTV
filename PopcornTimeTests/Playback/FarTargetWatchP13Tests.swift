//
//  FarTargetWatchP13Tests.swift
//  PopcornTimeTests
//
//  FarTargetWatch, round 13: per-piece jitter, fast / slow bursts, piece-gated frontiers,
//  the lost-time credit, and the recovery's watch seeded with the owners' download
//  history; the reviewer's recorded traces in Fixtures/FarTarget. (Port of the P13 bench:
//  24 checks.)
//

import XCTest
import Foundation

private func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }

/// A deterministic generator (the same draws on every build).
private struct LCG {
    var s: UInt64
    mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
}

/// A download world sampled like the owners: an in-order download position D(t) (media s) from 60 s before the seek,
/// built from pieces of `piece` media s whose durations are `durations` (or a rate profile for fine progress); the
/// remux frontier = the last segment boundary ≤ D (block by block) or ≤ the completed pieces' end (gated), published at
/// the pump's 1 Hz timer; the progress = completed pieces (per piece) or D at the 0.5 s refresh (fine).
private struct World {
    var f0 = 1200.0, total = 7200.0, seg = 10.4
    var edge0 = 1204.0
    var tickPhase = 0.3, pumpPhase = 0.6
    var gated = false
    var fine = false
    /// Breakpoints (time, D) of the download, ascending; D is linear between them.
    var bp: [(t: Double, x: Double)] = []
    /// Piece completions (time, end), ascending (per piece).
    var pieces: [(t: Double, x: Double)] = []

    /// Per piece: pieces of `piece` media s taking `duration(k)` s each (k = 0 at the one holding the edge at t = 0).
    static func perPiece(piece: Double, edge0: Double, seg: Double, duration: (Int) -> Double) -> World {
        var w = World(); w.seg = seg; w.edge0 = edge0
        // Pieces before the seek, backwards, then forwards; the piece holding edge0 is half done at t = 0.
        var t = -duration(0) / 2, x = edge0 - piece / 2
        var back: [(Double, Double)] = []
        var k = -1, tb = t, xb = x
        while tb > -70 { let d = duration(k); tb -= d; xb -= piece; back.append((tb, xb)); k -= 1 }
        w.bp = back.reversed().map { ($0.0, $0.1) } + [(t, x)]
        w.pieces = back.reversed().map { ($0.0, $0.1) } + [(t, x)]
        k = 0
        while t < 400 { t += duration(k); x += piece; w.bp.append((t, x)); w.pieces.append((t, x)); k += 1 }
        return w
    }
    /// Fine progress: D advances at `rate(t)` media s per s (piecewise constant over 0.05 s steps) from −70 s.
    static func fineRate(seg: Double, edge0: Double, rate: (Double) -> Double) -> World {
        var w = World(); w.seg = seg; w.edge0 = edge0; w.fine = true
        var t = -70.0, x = 0.0
        var pts: [(Double, Double)] = [(t, x)]
        while t < 400 { x += rate(t + 0.025) * 0.05; t += 0.05; pts.append((t, x)) }
        // Shift so that D(0) = edge0.
        let at0 = pts.first { $0.0 >= -0.001 }!.1
        w.bp = pts.map { ($0.0, $0.1 - at0 + edge0) }
        return w
    }
    func download(_ t: Double) -> Double {
        var lo = 0, hi = bp.count - 1
        if t <= bp[0].t { return bp[0].x }
        if t >= bp[hi].t { return bp[hi].x }
        while hi - lo > 1 { let m = (lo + hi) / 2; if bp[m].t <= t { lo = m } else { hi = m } }
        return bp[lo].x + (bp[hi].x - bp[lo].x) * (t - bp[lo].t) / (bp[hi].t - bp[lo].t)
    }
    func completed(_ t: Double) -> Double {
        var lo = -1, hi = pieces.count
        while hi - lo > 1 { let m = (lo + hi) / 2; if pieces[m].t <= t { lo = m } else { hi = m } }
        return lo >= 0 ? pieces[lo].x : pieces[0].x
    }
    func pumpTick(_ t: Double) -> Double { pumpPhase + ((t - pumpPhase).rounded(.down)) }
    func frontier(_ t: Double) -> Double {
        let at = pumpTick(t)
        let x = gated ? completed(at) : download(at)
        return max(f0, f0 + ((x - f0) / seg + 1e-9).rounded(.down) * seg)
    }
    func progress(_ t: Double) -> Float {
        if fine { return Float(download(0.2 + ((t - 0.2) / 0.5).rounded(.down) * 0.5) / total) }
        return Float(completed(t) / total)
    }
}

/// The owners' watch: fed with no target for `pre` ticks before the seek, then the target until a hand-off, the
/// frontier reaching it, or `until`; returns the hand-off time.
private func owners(_ w: World, target: Double, pre: Int = 40, until: Double = 42, watch: inout FarTargetWatch) -> Double? {
    for k in stride(from: pre, to: 0, by: -1) {
        let t = w.tickPhase - Double(k)
        _ = watch.shouldHandOff(target: nil, frontierSeconds: w.f0, downloadProgress: w.progress(t), remuxFinished: false, now: 1000 + t)
    }
    var k = 0
    while true {
        let t = w.tickPhase + Double(k)
        if t > until { return nil }
        let f = w.frontier(t)
        if f >= target { return nil }
        if watch.shouldHandOff(target: target, frontierSeconds: f, downloadProgress: w.progress(t), remuxFinished: false, now: 1000 + t) {
            return t
        }
        k += 1
    }
}
private func owners(_ w: World, target: Double, pre: Int = 40, until: Double = 42) -> Double? {
    var watch = FarTargetWatch()
    return owners(w, target: target, pre: pre, until: until, watch: &watch)
}
/// Every tick / pump phase pair of a 5 × 5 grid.
private func phases(_ body: (Double, Double) -> Void) {
    for a in 0..<5 { for b in 0..<5 { body(0.1 + 0.2 * Double(a), 0.05 + 0.2 * Double(b)) } }
}

final class FarTargetWatchP13Tests: CheckedTestCase {

    func testRound13() {
        print("== J. JITTER — ordinary per-piece jitter neither restarts nor blocks the measurement")
        do {
            // J1: the reviewer's probe_dip world (review12_far-target/probe_dip): pieces every 1.1 s at 1.3×, one straggler
            // 20 s before the seek, 10.4 s segments, block by block, a target 90 s of download past the edge, the owners' 40 s
            // of samples: VLC within 1 s (median) / 3 s (max) of round 11's 11.0 / 13.5 s (round 12: 13.2–16.2 / 21.2–23.9 s).
            var times: [Double] = [], never = 0
            for i in 0..<20 {
                for edge in [1.3, 4.9, 8.1] {
                    let dp = 1.1, pace = 1.3
                    var w = World.perPiece(piece: dp * pace, edge0: 1200 + edge, seg: 10.4) { k in
                        k == -19 ? dp * 1.6 : (k == -18 ? dp * 0.4 : dp)       // the straggler: late, right before its successor
                    }
                    w.tickPhase = Double(i) / 20 + 0.013; w.pumpPhase = 0.5
                    if let h = owners(w, target: w.edge0 + pace * 90) { times.append(h) } else { never += 1 }
                }
            }
            expect(never == 0 && median(times) <= 12.0 && (times.max() ?? 99) <= 16.5,
                   "J1 [R12 FAIL] probe_dip world (1.1 s pieces, 1.3×, 10.4 s segments, 90 s away): VLC, median ≤ 12.0 s, max ≤ 16.5 s",
                   String(format: "median %.1f s, max %.1f s, never %d/60", median(times), times.max() ?? .nan, never))
            // J2: the reviewer's probe_replay traces (pieces ±30 % around 1.1 s, 10.4 s segments, 1.3×, 90 s away), replayed
            // through the owners' watch: VLC within 16 s in each (round 11: +12.27 / +14.71 / +7.53 s; round 12: never).
            let dir = Fixtures.url("FarTarget/traces").path
            for name in ["pc1.1_seg10.4_1.3x_D90_i29.txt", "pc1.1_seg10.4_1.3x_D90_i5.txt", "pc1.1_seg10.4_1.3x_D90_i61.txt"] {
                let lines = (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8))?.split(separator: "\n") ?? []
                var target = 0.0, watch = FarTargetWatch(), hand: Double?
                for line in lines {
                    let f = line.split(separator: " ")
                    if f[0] == "target" { target = Double(f[1])!; continue }
                    guard hand == nil, f.count == 4, f[0] != "rec", let t = Double(f[1]), let fr = Double(f[2]), let p = Double(f[3]) else { continue }
                    if f[0] == "pre" {
                        _ = watch.shouldHandOff(target: nil, frontierSeconds: fr, downloadProgress: Float(p), remuxFinished: false, now: 1000 + t)
                    } else if fr < target, watch.shouldHandOff(target: target, frontierSeconds: fr, downloadProgress: Float(p), remuxFinished: false, now: 1000 + t) {
                        hand = t
                    }
                }
                expect(!lines.isEmpty && (hand ?? 99) <= 16, "J2 [R12 FAIL] probe_replay \(name): VLC by the owners within 16 s",
                       lines.isEmpty ? "trace not found" : hand.map { String(format: "VLC at +%.2f s", $0) } ?? "no hand-off")
            }
            // J3: pieces 1.1 s ± 30 % (uniform), the pre-seek cadence as jittery, 10.4 s segments, block by block, 1.3×, a
            // target 90 s of download away: every one of 100 runs goes to VLC within 25 s (round 12: some never).
            var late = 0.0, nev = 0
            for seed in 0..<4 {
                phases { tp, pp in
                    var rng = LCG(s: UInt64(seed * 1000) + UInt64(tp * 100) * 31 + UInt64(pp * 100))
                    var d: [Int: Double] = [:]
                    var w = World.perPiece(piece: 1.1 * 1.3, edge0: 1203.3, seg: 10.4) { k in
                        if let v = d[k] { return v }
                        let v = 1.1 * (0.7 + 0.6 * rng.next()); d[k] = v; return v
                    }
                    w.tickPhase = tp; w.pumpPhase = pp
                    if let h = owners(w, target: w.edge0 + 1.3 * 90) { late = max(late, h) } else { nev += 1 }
                }
            }
            expect(nev == 0 && late <= 25, "J3 [R12 FAIL] pieces 1.1 s ± 30 %, 10.4 s segments, 1.3×, 90 s away: VLC within 25 s in 100/100",
                   String(format: "worst +%.1f s, never %d/100", late, nev))
        }

        print("== B. BURST — recurring fast / slow stretches are averaged")
        do {
            /// Fine progress, alternating `fast`× / `slow`× in stretches of `tf` / `ts` s (phase `ph` s into the pattern).
            func burst(fast: Double, slow: Double, tf: Double, ts: Double, ph: Double, tp: Double, pp: Double) -> World {
                var w = World.fineRate(seg: 6, edge0: 1202.2) { t in
                    let y = (t + 70 + ph).truncatingRemainder(dividingBy: tf + ts)
                    return y < tf ? fast : slow
                }
                w.tickPhase = tp; w.pumpPhase = pp
                return w
            }
            for (fast, slow, tf, ts, limit) in [(2.5, 0.5, 5.0, 5.0, 20.0), (3.0, 0.3, 4.0, 6.0, 25.0)] {
                let avg = (fast * tf + slow * ts) / (tf + ts)
                var late = 0.0, nev = 0, near = 0, runs = 0
                for ph in [0.0, 2.5, 5.0, 7.5] {
                    phases { tp, pp in
                        let w = burst(fast: fast, slow: slow, tf: tf, ts: ts, ph: ph, tp: tp, pp: pp)
                        if let h = owners(w, target: w.edge0 + avg * 90) { late = max(late, h) } else { nev += 1 }
                        runs += 1
                        if owners(w, target: w.frontier(38)) != nil { near += 1 }
                    }
                }
                expect(nev == 0 && late <= limit, String(format: "B1 [R12 FAIL] fine %.1f×/%.1f× in %.0f/%.0f s stretches, 90 s of download away: VLC within %.0f s in 100/100", fast, slow, tf, ts, limit),
                       String(format: "worst +%.1f s, never %d/100", late, nev))
                expect(near <= 1, String(format: "B2 the same download, the farthest target reached within 38 s: native (≤ 1/100)"),
                       "\(near)/\(runs) hand-offs")
            }
        }

        print("== C. COARSE — a piece-gated frontier gets one piece of credit")
        do {
            // C1: the F3 x37-paused geometry (VAL13's replay): pieces of 2.924 s of media every 2.437 s (64 KiB at 1.2×),
            // complete pieces only (piece-gated), 6 s segments, a target 130 s of media past the frontier at the press; the
            // recovery's watch made at the play press — FRESH, as in round 12 (no history) — over 10 pump phases × 10 poll
            // phases × 5 press offsets: median ≤ 10 s and ≥ 95 % within 14 s (round 12: median 12.85 s, 73 % — the third move;
            // round 11: 8.65 s, 100 %).
            var times: [Double] = [], never = 0
            for a in 0..<10 { for b in 0..<10 { for c in 0..<5 {
                var w = World.perPiece(piece: 2.924, edge0: 1203.0, seg: 6) { _ in 2.437 }
                w.gated = true; w.pumpPhase = 0.05 + 0.1 * Double(a)
                let press = 0.2 * Double(c), poll = 0.05 + 0.1 * Double(b)
                let target = w.frontier(press) + 130
                var watch = FarTargetWatch()
                // playPressSettled's proceed() 0.25 s after the press, then the recovery's 1 Hz poll (its own phase).
                var samples = [press + 0.25]
                var tt = (press + 0.25 - poll).rounded(.down) + poll
                while tt <= press + 0.25 { tt += 1 }
                while tt < press + 60 { samples.append(tt); tt += 1 }
                var hand: Double?
                for t in samples {
                    let f = w.frontier(t)
                    if f >= target { break }
                    if watch.shouldHandOff(target: target, frontierSeconds: f, downloadProgress: w.progress(t), remuxFinished: false, now: 1000 + t) { hand = t - press; break }
                }
                if let h = hand { times.append(h) } else { never += 1 }
            } } }
            let within = Double(times.filter { $0 <= 14 }.count) / 500
            expect(never == 0 && median(times) <= 10 && within >= 0.95,
                   "C1 [R12 FAIL] x37 paused geometry (piece-gated 2.44 s pieces, 6 s segments, 1.2×), a fresh watch at the press: median ≤ 10 s, ≥ 95 % within 14 s",
                   String(format: "median %.2f s, within 14 s %.1f %%, max %.1f s, never %d/500", median(times), 100 * within, times.max() ?? .nan, never))
            // C2: the piece credit keeps the upper bound: piece-gated 2 s pieces at 1.5× (3 s of media), 6 s segments, the
            // farthest target reached within 40 s, the owners: native in every phase.
            var hands = 0
            phases { tp, pp in
                var w = World.perPiece(piece: 3.0, edge0: 1201.7, seg: 6) { _ in 2.0 }
                w.gated = true; w.tickPhase = tp; w.pumpPhase = pp
                if owners(w, target: w.frontier(40), until: 45) != nil { hands += 1 }
            }
            expect(hands == 0, "C2 piece-gated 2 s pieces at 1.5×, 6 s segments, the farthest target reached within 40 s: native", "\(hands)/25")
            // C3: the F3 x37f-paused geometry as VAL12's probe runs it (a FRESH recovery watch at the play press): pieces
            // 7.5–9.6 s apart (F3's totalProgress gaps), 10.2 s of media each at 1.2×, piece-gated, 6 s segments, a target
            // 136 s past the frontier at the press; 85 press offsets × 10 poll phases: every run hands off within 27 s (rounds
            // 11 / 12: max 26.9 s). A rate read over the few seconds since a fresh watch's first sample vouches for no more
            // lost time than that (else up to ~29 s, or none within 27 s in F3).
            let gaps = [8.3, 9.6, 7.6, 8.1, 9.0, 8.5, 7.5, 8.5, 8.8]
            var pieceTimes: [Double] = [-60]
            for i in 0..<60 { pieceTimes.append(pieceTimes.last! + gaps[i % gaps.count]) }
            func completedEnd(_ t: Double) -> Double { Double(pieceTimes.filter { $0 <= t }.count) * 10.2 }
            func frontierF(_ t: Double) -> Double { 6 * (completedEnd(t - 0.4) / 6).rounded(.down) }
            var worstF = 0.0, neverF = 0
            for p in 0..<85 { for q in 0..<10 {
                let press = 20 + Double(p) * 0.1, poll = Double(q) * 0.1
                let target = frontierF(press) + 136
                var watch = FarTargetWatch()
                var samples = [press + 0.25]
                var tt = (press + 0.25 - poll).rounded(.down) + poll
                while tt <= press + 0.25 { tt += 1 }
                while tt < press + 60 { samples.append(tt); tt += 1 }
                var hand: Double?
                for t in samples {
                    let f = frontierF(t)
                    if f >= target { break }
                    if watch.shouldHandOff(target: target, frontierSeconds: f, downloadProgress: Float((1000 + completedEnd(t)) / 7200),
                                           remuxFinished: false, now: 1000 + t) { hand = t - press; break }
                }
                if let h = hand { worstF = max(worstF, h) } else { neverF += 1 }
            } }
            expect(neverF == 0 && worstF <= 27, "C3 x37f paused geometry (8.5 s pieces, piece-gated), a fresh watch at the press: VLC within 27 s in 850/850",
                   String(format: "worst +%.1f s, never %d/850", worstF, neverF))
        }

        print("== L. The lost-time credit")
        do {
            /// Fine progress at `pace`× with a disturbance from `at` for `len` s at `factor` × the pace (0 = a pause).
            func disturbed(pace: Double, at: Double, len: Double, factor: Double, tp: Double, pp: Double, seg: Double = 6) -> World {
                var w = World.fineRate(seg: seg, edge0: 1203.0) { t in (t >= at && t < at + len) ? pace * factor : pace }
                w.tickPhase = tp; w.pumpPhase = pp
                return w
            }
            // L1: a pause of 2 / 4 / 6 s, or a slowdown to 25 % for 7 s, right after the first frontier step (fine, 6 s
            // segments, 1.5× / 2×), the owners' 40 s of samples: the farthest target reached within 40 s stays native.
            for (factor, len, pace) in [(0.0, 2.0, 1.5), (0.0, 4.0, 1.5), (0.0, 6.0, 1.5), (0.25, 7.0, 2.0), (0.25, 7.0, 3.0)] {
                var hands = 0
                phases { tp, pp in
                    let at = (1206 - 1203) / pace + 0.3
                    let w = disturbed(pace: pace, at: at, len: len, factor: factor, tp: tp, pp: pp)
                    if owners(w, target: w.frontier(40), until: 45) != nil { hands += 1 }
                }
                expect(hands == 0, String(format: "L1 fine %.1f×, %@ after the first step, the owners' samples, the farthest target reached within 40 s: native",
                                          pace, factor == 0 ? String(format: "a %.0f s pause", len) : String(format: "%.0f s at %.0f %%", len, 100 * factor)),
                       "\(hands)/25")
            }
            // L2: a lasting slowdown (4× → 1× for good at 3 s), a target ~150 s of download away at the new pace: VLC within
            // 30 s (the credit stops at maxLostSeconds; P12's P7).
            var late = 0.0, nev = 0
            phases { tp, pp in
                let w = disturbed(pace: 4, at: 3, len: 1000, factor: 0.25, tp: tp, pp: pp)
                if let h = owners(w, target: w.edge0 + 4 * 3 + 150, until: 60) { late = max(late, h) } else { nev += 1 }
            }
            expect(nev == 0 && late <= 30, "L2 4× → 1× for good, a target ~150 s away at the new pace: VLC within 30 s",
                   String(format: "worst +%.1f s, never %d/25", late, nev))
            // L3: the credit is capped — a 20 s pause right after the first step, 1.5×, a target 3 bounds of download away:
            // VLC within 15 s of the pause's end.
            var worst = -Double.infinity, nev3 = 0
            phases { tp, pp in
                let at = (1206 - 1203) / 1.5 + 0.3
                let w = disturbed(pace: 1.5, at: at, len: 20, factor: 0, tp: tp, pp: pp)
                if let h = owners(w, target: w.edge0 + 1.5 * 135, until: 90) { worst = max(worst, h - (at + 20)) } else { nev3 += 1 }
            }
            expect(nev3 == 0 && worst <= 15, "L3 a 20 s pause after the first step, 1.5×, a target 3 bounds away: VLC within 15 s of the pause's end",
                   String(format: "worst %+.1f s, never %d/25", worst, nev3))
            // L4: a steady fine download (1.2×, 6 s segments), x37 / R8-#7 targets: VLC within 14 s (the far controls).
            for ahead in [184.0, 1620.0] {
                var w4 = 0.0, n4 = 0
                phases { tp, pp in
                    let w = disturbed(pace: 1.2, at: 1000, len: 0, factor: 1, tp: tp, pp: pp)
                    if let h = owners(w, target: w.f0 + ahead, until: 30) { w4 = max(w4, h) } else { n4 += 1 }
                }
                expect(n4 == 0 && w4 <= 14, String(format: "L4 steady 1.2×, a target %.0f s ahead: VLC within 14 s", ahead),
                       String(format: "worst +%.1f s, never %d/25", w4, n4))
            }
        }

        print("== S. Item 2 — the recovery's watch starts from the owners' download history")
        do {
            // S1: downloadHistory keeps the last downloadMemorySeconds of changes, oldest first; reset() keeps them; a watch
            // made from them ignores non-finite, out-of-order or non-increasing entries.
            var w = FarTargetWatch()
            for k in 0..<60 { _ = w.shouldHandOff(target: nil, frontierSeconds: 1200, downloadProgress: 0.1 + Float(k / 2) * 0.001, remuxFinished: false, now: Double(k)) }
            let h = w.downloadHistory
            var mono = true
            for i in h.indices.dropFirst() where !(h[i].time > h[i - 1].time && h[i].progress > h[i - 1].progress) { mono = false }
            w.reset()
            expect(!h.isEmpty && mono && (h.first?.time ?? 0) >= 59 - FarTargetWatch.downloadMemorySeconds && w.downloadHistory.count == h.count,
                   "S1 downloadHistory: the last 40 s of changes, oldest first; reset() keeps them",
                   "\(h.count) changes from \(h.first.map { String(format: "%.0f", $0.time) } ?? "-") s")
            let dirty: [(time: TimeInterval, progress: Float)] = [(1, 0.1), (2, .nan), (3, 0.12), (2.5, 0.13), (4, 0.11), (.infinity, 0.2), (5, 0.14)]
            let s = FarTargetWatch(downloadHistory: dirty).downloadHistory
            expect(s.map { $0.time } == [1, 3, 5], "S1b init(downloadHistory:) keeps a clean increasing history", "\(s.map { $0.time })")
            // S2: a pause of 4 s right after the first step (fine, 1.5×), the farthest target reached within 40 s; the watch
            // under test is the RECOVERY's, made at the seek (a play press) from the owners' history: native in every phase
            // (a fresh watch, with no history, judges the pause like round 11: informative).
            var seeded = 0, fresh = 0
            phases { tp, pp in
                let at = (1206 - 1203) / 1.5 + 0.3
                var wd = World.fineRate(seg: 6, edge0: 1203) { t in (t >= at && t < at + 4) ? 0 : 1.5 }
                wd.tickPhase = tp; wd.pumpPhase = pp
                var own = FarTargetWatch()
                for k in stride(from: 40, to: 0, by: -1) {
                    let t = tp - Double(k)
                    _ = own.shouldHandOff(target: nil, frontierSeconds: wd.f0, downloadProgress: wd.progress(t), remuxFinished: false, now: 1000 + t)
                }
                var rec = FarTargetWatch(downloadHistory: own.downloadHistory)
                if owners(wd, target: wd.frontier(40), pre: 0, until: 45, watch: &rec) != nil { seeded += 1 }
                if owners(wd, target: wd.frontier(40), pre: 0, until: 45) != nil { fresh += 1 }
            }
            expect(seeded == 0, "S2 the recovery's watch made from the owners' history at a play press: a 4 s pause after the first step stays native",
                   "\(seeded)/25 hand-offs (a fresh watch: \(fresh)/25)")
        }
    }
}
