//
//  FarTargetWatchP12Tests.swift
//  PopcornTimeTests
//
//  FarTargetWatch, round 12: the owners' watch over simulated worlds (piece cadence,
//  segment length, download rate, pauses), in every tick / pump phase. (Port of the P12
//  bench: 41 checks.)
//

import XCTest
import Foundation

/// A world: the in-order download position D(t) (media s; frozen or slowed by `warp`), the remux frontier = the last
/// segment boundary ≤ min(D, the pump-ahead's capacity) at the pump's 1 Hz timer (phase `pumpPhase`), the progress
/// fine (published every 0.5 s) or per piece (`piece` media s), sampled by the owners' tick (phase `tickPhase`).
private struct World {
    var f0 = 1200.0, total = 7200.0
    var seg = 6.0, pace = 1.5, edge0 = 1203.0
    var piece: Double? = nil                 // per-piece progress: media s per piece; nil = fine
    var gated = false                        // the frontier only moves when a piece completes
    var pumpAhead: (onDisk: Double, perTick: Double)? = nil
    var tickPhase = 0.3, pumpPhase = 0.6
    /// Download time: real time t ↦ the time the download has been running (pauses / slowdowns).
    var warp: (Double) -> Double = { $0 }
    func download(_ t: Double) -> Double { edge0 + pace * warp(max(0, t)) + (pumpAhead?.onDisk ?? 0) }
    func completed(_ t: Double) -> Double {
        guard let p = piece else { return download(t) }
        return f0 + ((download(t) - f0) / p).rounded(.down) * p
    }
    func pumpTick(_ t: Double) -> Double { pumpPhase + ((t - pumpPhase).rounded(.down)) }
    func floorSeg(_ x: Double) -> Double { f0 + ((x - f0) / seg + 1e-9).rounded(.down) * seg }
    func frontier(_ t: Double) -> Double {
        let pt = pumpTick(t)
        guard pt >= 0 else { return f0 }
        var f = floorSeg(gated ? completed(pt) : download(pt))
        if let pa = pumpAhead { f = min(f, floorSeg(f0 + pa.perTick * (pt.rounded(.down) + 1))) }
        return f
    }
    func progress(_ t: Double) -> Float {
        if piece != nil { return Float(completed(t) / total) }
        let pt = 0.25 + ((t - 0.25) / 0.5).rounded(.down) * 0.5
        return Float(download(pt) / total)
    }
    /// When the pump-ahead caught up with the download edge (0 without one).
    var pumpAheadEnd: Double {
        guard let pa = pumpAhead else { return 0 }
        var t = 0.0
        while t < 400 { if f0 + pa.perTick * (pumpTick(t).rounded(.down) + 1) >= floorSeg(download(pumpTick(t))) { return t }; t += 0.05 }
        return .infinity
    }
}

/// Feeds a watch at the owners' 1 Hz tick from the seek (t = 0) — after `pre` ticks with no target (the owners'
/// persistent watch) — until it hands off, the frontier reaches the target, or `until`. Returns the hand-off time.
private func simulate(_ w: World, target: Double, until: Double = 60, pre: Int = 0, watch: inout FarTargetWatch) -> (handOff: Double?, reached: Double?) {
    for k in stride(from: pre, to: 0, by: -1) {
        let t = w.tickPhase - Double(k)
        let pt = 0.25 + ((t - 0.25) / 0.5).rounded(.down) * 0.5
        let p: Float = w.piece == nil ? Float((w.edge0 + w.pace * min(0, pt) + (w.pumpAhead?.onDisk ?? 0)) / w.total) : w.progress(0)
        _ = watch.shouldHandOff(target: nil, frontierSeconds: w.f0, downloadProgress: p, remuxFinished: false, now: 1000 + t)
    }
    var k = 0
    while true {
        let t = w.tickPhase + Double(k)
        if t > until { return (nil, nil) }
        let f = w.frontier(t)
        if f >= target { return (nil, t) }
        if watch.shouldHandOff(target: target, frontierSeconds: f, downloadProgress: w.progress(t), remuxFinished: false, now: 1000 + t) {
            return (t, nil)
        }
        k += 1
    }
}
private func simulate(_ w: World, target: Double, until: Double = 60, pre: Int = 0) -> (handOff: Double?, reached: Double?) {
    var watch = FarTargetWatch()
    return simulate(w, target: target, until: until, pre: pre, watch: &watch)
}
/// Every tick / pump phase pair of a 5 × 5 grid.
private func phases(_ body: (Double, Double) -> Void) {
    for a in 0..<5 { for b in 0..<5 { body(0.1 + 0.2 * Double(a), 0.05 + 0.2 * Double(b)) } }
}

final class FarTargetWatchP12Tests: CheckedTestCase {

    func testRound12() {
        print("== F. FASTDL — a fast in-order download is measured at its pace")
        do {
            // F1: no pump-ahead, fine progress (the Mac), 6 / 10.4 s segments, 5–50×: a target 2 × bound of download time
            // past the edge goes to VLC within 14 s of the seek (round 11: never at ≥ 5×).
            for seg in [6.0, 10.4] {
                for r in [5.0, 6.0, 8.0, 10.0, 15.0, 25.0, 50.0] {
                    var worst = 0.0, never = 0
                    phases { tp, pp in
                        var w = World(); w.seg = seg; w.pace = r; w.tickPhase = tp; w.pumpPhase = pp
                        let o = simulate(w, target: w.edge0 + 2 * 45 * r + 1, until: 30)
                        if let h = o.handOff { worst = max(worst, h) } else { never += 1 }
                    }
                    expect(never == 0 && worst <= 14, String(format: "F1 [R11 FAIL] fine, seg %.1f s, %.0f×, target 2 × bound of download away: VLC within 14 s", seg, r),
                           String(format: "worst +%.1f s, never %d/25", worst, never))
                }
            }
            // F2: a pump-ahead (300 s on disk at 30 / 60 / 120 s per tick), then the download at 5–10×, fine progress: VLC
            // within 14 s of the pump-ahead's end (the burst is cut at its deceleration).
            for (P, r) in [(30.0, 5.0), (60.0, 8.0), (120.0, 10.0), (60.0, 5.0)] {
                var worst = -Double.infinity, never = 0
                phases { tp, pp in
                    var w = World(); w.pace = r; w.tickPhase = tp; w.pumpPhase = pp; w.pumpAhead = (300, P)
                    let end = w.pumpAheadEnd
                    let o = simulate(w, target: w.download(end) + 2 * 45 * r + 1, until: 60)
                    if let h = o.handOff { worst = max(worst, h - end) } else { never += 1 }
                }
                expect(never == 0 && worst <= 14, String(format: "F2 [R11 FAIL] 300 s pumped at %.0f s/tick, then %.0f×: VLC within 14 s of the pump-ahead's end", P, r),
                       String(format: "worst %+.1f s, never %d/25", worst, never))
            }
            // F3: per-piece progress with 16 MiB pieces of an 8 Mb/s file (16.8 s of media), the file growing block by
            // block, 5 / 8 / 10×: VLC within 14 s.
            for r in [5.0, 8.0, 10.0] {
                var worst = 0.0, never = 0
                phases { tp, pp in
                    var w = World(); w.pace = r; w.piece = 16.8; w.tickPhase = tp; w.pumpPhase = pp
                    let o = simulate(w, target: w.edge0 + 2 * 45 * r + 1, until: 30)
                    if let h = o.handOff { worst = max(worst, h) } else { never += 1 }
                }
                expect(never == 0 && worst <= 14, String(format: "F3 [R11 FAIL] per piece (16.8 s pieces, Δp %.1f s), block by block, %.0f×: VLC within 14 s", 16.8 / r, r),
                       String(format: "worst +%.1f s, never %d/25", worst, never))
            }
            // F4: the burst's tail (round 11 kept it while the span read under 5×: some runs decided only when it left the
            // 90 s history): 600 s pumped at 30 s per tick, then 1.1×, fine; an x37-like target (153 s of download past the
            // edge): VLC within 14 s of the pump-ahead's end.
            var worst = -Double.infinity, never = 0
            phases { tp, pp in
                var w = World(); w.pace = 1.1; w.tickPhase = tp; w.pumpPhase = pp; w.pumpAhead = (600, 30)
                let end = w.pumpAheadEnd
                let o = simulate(w, target: w.download(end) + 1.1 * 153, until: 120)
                if let h = o.handOff { worst = max(worst, h - end) } else { never += 1 }
            }
            expect(never == 0 && worst <= 14, "F4 600 s pumped at 30 s/tick, then 1.1×, x37-like target: VLC within 14 s of the pump-ahead's end",
                   String(format: "worst %+.1f s, never %d/25", worst, never))
        }

        print("== P. PAUSE — a short pause or dip does not decide alone")
        do {
            // P1 / P2: the reviewer's deterministic replays (review11_far-target/probe_pause), verbatim samples.
            func replay(_ target: Double, _ samples: [(Double, Double, Double)]) -> Double? {
                var watch = FarTargetWatch()
                for (t, f, p) in samples {
                    if f >= target { return nil }
                    if watch.shouldHandOff(target: target, frontierSeconds: f, downloadProgress: Float(p), remuxFinished: false, now: 50_000 + t) { return t }
                }
                return nil
            }
            let mac: [(Double, Double, Double)] = [
                (0.650, 1018, 0.141487107), (1.639, 1018, 0.141695216), (2.638, 1018, 0.141902909), (3.632, 1018, 0.142109156),
                (4.664, 1018, 0.142318085), (5.649, 1024, 0.142538175), (6.650, 1024, 0.142747790), (7.634, 1024, 0.142834693),
                (8.630, 1024, 0.142834693), (9.676, 1024, 0.142834693), (10.622, 1024, 0.142834693), (11.636, 1024, 0.142933086),
                (12.655, 1024, 0.143120393), (13.651, 1030, 0.143343851), (14.627, 1030, 0.143569246), (15.667, 1030, 0.143802971),
                (16.628, 1036, 0.144015402), (17.621, 1036, 0.144196630), (18.661, 1036, 0.144379199), (19.678, 1036, 0.144572973),
                (20.658, 1036, 0.144766733), (21.622, 1042, 0.144950449), (22.661, 1042, 0.145133689), (23.639, 1042, 0.145322472),
                (24.663, 1042, 0.145513818), (25.665, 1048, 0.145708159), (26.623, 1048, 0.145905465), (27.645, 1048, 0.146101430),
                (28.659, 1048, 0.146295369), (29.648, 1048, 0.146494493), (30.679, 1054, 0.146709725), (31.677, 1054, 0.146916687),
                (32.663, 1054, 0.147105083), (33.621, 1054, 0.147296250), (34.621, 1060, 0.147513285), (35.650, 1060, 0.147727251),
                (36.663, 1060, 0.147926971), (37.668, 1060, 0.148126274), (38.666, 1066, 0.148321360)]
            let ios: [(Double, Double, Double)] = [
                (0.734, 1018, 0.140846431), (1.753, 1018, 0.140846431), (2.722, 1018, 0.141888097), (3.732, 1018, 0.141888097),
                (4.736, 1024, 0.141888097), (5.732, 1024, 0.141888097), (6.724, 1024, 0.141888097), (7.757, 1024, 0.141888097),
                (8.714, 1024, 0.141888097), (9.711, 1024, 0.141888097), (10.758, 1024, 0.141888097), (11.711, 1024, 0.141888097),
                (12.713, 1024, 0.141888097), (13.713, 1024, 0.141888097), (14.710, 1024, 0.141888097), (15.718, 1024, 0.142929763),
                (16.759, 1030, 0.142929763), (17.735, 1030, 0.142929763), (18.719, 1030, 0.142929763), (19.705, 1036, 0.142929763),
                (20.762, 1036, 0.143971428), (21.762, 1036, 0.143971428), (22.707, 1036, 0.143971428), (23.716, 1042, 0.143971428),
                (24.708, 1042, 0.143971428), (25.741, 1042, 0.145013094), (26.742, 1042, 0.145013094), (27.752, 1042, 0.145013094),
                (28.743, 1048, 0.145013094), (29.760, 1048, 0.145013094), (30.748, 1048, 0.146054760), (31.709, 1048, 0.146054760),
                (32.742, 1054, 0.146054760), (33.728, 1054, 0.146054760), (34.720, 1054, 0.146054760), (35.753, 1054, 0.146054760),
                (36.745, 1060, 0.147096425)]
            let m = replay(1066, mac), i = replay(1058, ios)
            /// The iOS replay after four pieces 5 s apart before the seek (the owners' ticks with no target): the cadence
            /// before the measurement shows the 13 s piece interval holds a pause.
            func replayWithCadence(_ target: Double, _ samples: [(Double, Double, Double)]) -> Double? {
                var watch = FarTargetWatch()
                let first = samples[0]
                for k in stride(from: 20, through: 1, by: -1) {
                    let t = first.0 - Double(k)
                    let pieces = Double((k + 4) / 5)                       // a piece every 5 s before the seek
                    _ = watch.shouldHandOff(target: nil, frontierSeconds: first.1, downloadProgress: Float(first.2 - 0.00104166 * pieces),
                                            remuxFinished: false, now: 50_000 + t)
                }
                for (t, f, p) in samples {
                    if f >= target { return nil }
                    if watch.shouldHandOff(target: target, frontierSeconds: f, downloadProgress: Float(p), remuxFinished: false, now: 50_000 + t) { return t }
                }
                return nil
            }
            let ic = replayWithCadence(1058, ios)
            expect(m == nil, "P1 [R11 FAIL] probe_pause Mac replay (1.5×, 4 s pause between the first two moves, target reached +38.7 s): native",
                   m.map { String(format: "VLC at +%.2f s", $0) } ?? "no hand-off")
            expect(i == nil, "P2 [R11 FAIL] probe_pause iOS replay (per piece 5 s, 8 s pause, target reached +36.7 s): native",
                   i.map { String(format: "VLC at +%.2f s", $0) } ?? "no hand-off")
            expect(ic == nil, "P2b [R11 FAIL] the same after pieces 5 s apart before the seek (the owners' watch): native",
                   ic.map { String(format: "VLC at +%.2f s", $0) } ?? "no hand-off")
            // P2c: per piece every 10 s at 1.2×, the file growing block by block, a target 90 s of download away, the owners'
            // watch with the cadence before the seek (30 ticks): a single piece interval like the ones before decides at its
            // pace — within 25 s in every phase (the one-piece margin would defer it).
            var worstC = 0.0, neverC = 0
            phases { tp, pp in
                var w = World(); w.pace = 1.2; w.piece = 12; w.tickPhase = tp; w.pumpPhase = pp; w.edge0 = 1200.5
                var watch = FarTargetWatch()
                // Pieces before the seek: every 10 s, the last one 10 s before the first one after it.
                let firstAfter = (w.f0 + 12 - w.edge0) / w.pace
                for k in stride(from: 30, through: 1, by: -1) {
                    let t = tp - Double(k)
                    let done = ((firstAfter - t) / 10).rounded(.down)
                    _ = watch.shouldHandOff(target: nil, frontierSeconds: w.f0, downloadProgress: Float((w.f0 - 12 * max(0, done - 0)) / w.total),
                                            remuxFinished: false, now: 1000 + t)
                }
                if let h = simulate(w, target: w.f0 + 1.2 * 90 + 1, until: 40, watch: &watch).handOff { worstC = max(worstC, h) } else { neverC += 1 }
            }
            expect(neverC == 0 && worstC <= 25, "P2c per piece 10 s apart at 1.2×, block by block, the cadence before the seek, a target 90 s of download away: VLC within 25 s",
                   String(format: "worst +%.1f s, never %d/25", worstC, neverC))
            // P3: fine progress, 6 s segments at 1.5×, a PAUSE of 2 / 4 / 6 s right after the first frontier step; the
            // farthest target the frontier reaches within 40 s of the seek: native in every phase.
            for len in [2.0, 4.0, 6.0] {
                var hands = 0, runs = 0, freshP3 = 0
                phases { tp, pp in
                    var w = World(); w.pace = 1.5; w.tickPhase = tp; w.pumpPhase = pp
                    let at = (w.f0 + w.seg - w.edge0) / w.pace + 0.3       // just after the first segment completes
                    w.warp = { t in t < at ? t : (t < at + len ? at : t - len) }
                    let target = w.frontier(40)
                    runs += 1
                    if simulate(w, target: target, until: 45, pre: 40).handOff != nil { hands += 1 }     // R13: the owners' samples
                    if simulate(w, target: target, until: 45).handOff != nil { freshP3 += 1 }
                }
                expect(hands == 0, String(format: "P3 %@R13 fine, 1.5×, a %.0f s pause after the first step, the owners' samples, the farthest target reached within 40 s: native", len >= 4 ? "[R11 FAIL] " : "", len),
                       "\(hands)/\(runs) hand-offs (a memory-less watch: \(freshP3)/\(runs))")
            }
            // P4: fine progress, a SLOWDOWN to 25 % for 7 s after the first step (2 / 3×): native in every phase.
            for r in [2.0, 3.0] {
                var hands = 0, runs = 0, freshP4 = 0
                phases { tp, pp in
                    var w = World(); w.pace = r; w.tickPhase = tp; w.pumpPhase = pp
                    let at = (w.f0 + w.seg - w.edge0) / w.pace + 0.3
                    w.warp = { t in t < at ? t : (t < at + 7 ? at + 0.25 * (t - at) : t - 0.75 * 7) }
                    runs += 1
                    if simulate(w, target: w.frontier(40), until: 45, pre: 40).handOff != nil { hands += 1 }    // R13: the owners' samples
                    if simulate(w, target: w.frontier(40), until: 45).handOff != nil { freshP4 += 1 }
                }
                expect(hands == 0, String(format: "P4 [R11 FAIL] R13 fine, %.0f×, a slowdown to 25 %% for 7 s after the first step, the owners' samples, the farthest target reached within 40 s: native", r),
                       "\(hands)/\(runs) hand-offs (a memory-less watch: \(freshP4)/\(runs))")
            }
            // P5: a slowdown to 25 % for 7 s FROM THE SEEK, at 2.5×: the owners' watch has the download's samples from
            // before the seek (10 ticks with no target) — native in every phase.
            var hands = 0, runs = 0
            phases { tp, pp in
                var w = World(); w.pace = 2.5; w.tickPhase = tp; w.pumpPhase = pp
                w.warp = { t in t < 7 ? 0.25 * t : t - 0.75 * 7 }
                runs += 1
                if simulate(w, target: w.frontier(40), until: 45, pre: 10).handOff != nil { hands += 1 }
            }
            expect(hands == 0, "P5 [R11 FAIL] slowdown to 25 % for 7 s from the seek at 2.5×, the owners' samples from before the seek: native", "\(hands)/\(runs) hand-offs")
            // P6: reset() forgets the measurement, not the download's samples: a watch reset by ticks with no target, then
            // measuring, sees the same samples as P5 (a fresh watch, with none, may decide on the dip: the recovery's case).
            var fresh = 0
            phases { tp, pp in
                var w = World(); w.pace = 2.5; w.tickPhase = tp; w.pumpPhase = pp
                w.warp = { t in t < 7 ? 0.25 * t : t - 0.75 * 7 }
                if simulate(w, target: w.frontier(40), until: 45).handOff != nil { fresh += 1 }
            }
            print("  info P6 the same with a fresh watch (no samples from before the seek: the recovery's watch): \(fresh)/25 hand-offs")
            // P7: a real slowdown (the download drops to 0.25× for good, from 4× — a target ~150 s of download away at the
            // new pace): the dip rule waits at most maxDipSeconds, then measures the new pace — VLC within 30 s.
            var late = 0.0, nev = 0
            phases { tp, pp in
                var w = World(); w.pace = 4; w.tickPhase = tp; w.pumpPhase = pp
                w.warp = { t in t < 3 ? t : 3 + 0.25 * (t - 3) }
                let o = simulate(w, target: w.edge0 + 4 * 3 + 4 * 0.25 * 150, until: 60, pre: 10)
                if let h = o.handOff { late = max(late, h) } else { nev += 1 }
            }
            expect(nev == 0 && late <= 30, "P7 the download drops to a quarter of its pace for good (4× → 1×), target ~150 s away at the new pace: VLC within 30 s",
                   String(format: "worst +%.1f s, never %d/25", late, nev))
        }

        print("== K. Kept invariants")
        do {
            // K1: the revised M5 — a pump at 30 / 60 / 120 s per tick over bytes on disk toward the farthest target it
            // reaches within 40 s, the download growing (fine): never.
            var hands = 0, runs = 0
            for P in [30.0, 60.0, 120.0] {
                phases { tp, pp in
                    var w = World(); w.pace = 1.2; w.tickPhase = tp; w.pumpPhase = pp; w.pumpAhead = (P * 60, P)
                    runs += 1
                    if simulate(w, target: w.frontier(40), until: 45).handOff != nil { hands += 1 }
                }
            }
            expect(hands == 0, "K1 pump at 30–120 s/tick over bytes on disk toward a target it reaches within 40 s: never", "\(hands)/\(runs)")
            // K2: a complete payload (progress 1, constant) and a finished remux never decide.
            var w1 = FarTargetWatch(), w2 = FarTargetWatch()
            var bad = 0
            for k in 0..<90 {
                let t = Double(k)
                if w1.shouldHandOff(target: 4000, frontierSeconds: 1200 + (2 * t / 6).rounded(.down) * 6, downloadProgress: 1, remuxFinished: false, now: t) { bad += 1 }
                if w2.shouldHandOff(target: 4000, frontierSeconds: 1200 + 1.2 * t, downloadProgress: 0.5 + Float(t) / 1000, remuxFinished: true, now: t) { bad += 1 }
            }
            expect(bad == 0, "K2 complete payload / finished remux: never", "\(bad) hand-offs")
            // K3: a frozen frontier while the download grows (fine / per piece): never.
            var frozen = 0
            for dp in [0.5, 7.0] {
                var w = FarTargetWatch()
                for k in 0..<200 {
                    let t = 0.3 + Double(k)
                    if w.shouldHandOff(target: 1600, frontierSeconds: 1200, downloadProgress: Float(0.2 + 0.0004 * ((t / dp).rounded(.down) * dp)), remuxFinished: false, now: t) { frozen += 1; break }
                }
            }
            expect(frozen == 0, "K3 frozen frontier, the download growing: never", "\(frozen)/2")
            // K4: x18d — the swarm stalls at the seek (the remux writes 0–2 on-disk segments), then comes back fast (60×).
            var x18 = 0, x18runs = 0
            for catchUp in 0...2 {
                for back in [6.5, 8.0, 10.0, 14.0] {
                    for i in 0..<5 {
                        let phase = Double(i) / 5
                        var w = FarTargetWatch()
                        x18runs += 1
                        for k in 0..<60 {
                            let t = phase + Double(k)
                            var f = 204.0
                            if catchUp >= 1 && t >= 3 { f += 6 }
                            if catchUp >= 2 && t >= 4 { f += 6 }
                            if t >= back + 0.6 { f = max(f, 204 + 6 * Double(catchUp) + 30 + ((60 * (t - back - 0.6)) / 6).rounded(.down) * 6) }
                            if f >= 500 { break }
                            let p: Float = t < back ? 0.3234 : 0.3234 + Float(0.2 * ((t - back) / 0.5).rounded(.down) * 0.5 + 0.02)
                            if w.shouldHandOff(target: 500, frontierSeconds: f, downloadProgress: p, remuxFinished: false, now: 300 + t) { x18 += 1; break }
                        }
                    }
                }
            }
            expect(x18 == 0, "K4 x18d: stalled swarm (catch-up 0–2 segments), then a fast return: never", "\(x18)/\(x18runs)")
            // K5: a drag (the target moves by more than 1 s every tick) never decides; settled 600 s ahead at 1.2×, it does.
            var w = FarTargetWatch()
            var mid = 0, settled: Double?
            for k in 0..<60 {
                let t = 0.4 + Double(k)
                let target = k < 20 ? 1400 + 20 * Double(k) * (k % 2 == 0 ? 1 : -1) : 1800
                let f = 1200 + ((1.2 * t) / 6).rounded(.down) * 6
                let p = Float((1203 + 1.2 * (0.25 + ((t - 0.25) / 0.5).rounded(.down) * 0.5)) / 7200)
                if w.shouldHandOff(target: target, frontierSeconds: f, downloadProgress: p, remuxFinished: false, now: t) {
                    if k < 20 { mid += 1 } else { settled = t; break }
                }
            }
            expect(mid == 0 && settled != nil, "K5 drag: no decision mid-drag; settled 600 s ahead at 1.2× → VLC",
                   "mid-drag \(mid), settled at \(settled.map { String(format: "+%.1f s after the settle", $0 - 20.4) } ?? "never")")
            // K6: a receding frontier, NaN / negative / infinite inputs: no decision.
            var w6 = FarTargetWatch()
            var odd = 0
            for k in 0..<40 {
                let t = Double(k)
                if w6.shouldHandOff(target: 5000, frontierSeconds: 1500 - 6 * t, downloadProgress: 0.3 + Float(t) / 1000, remuxFinished: false, now: t) { odd += 1 }
                if w6.shouldHandOff(target: .nan, frontierSeconds: 1200, downloadProgress: 0.3, remuxFinished: false, now: t) { odd += 1 }
                if w6.shouldHandOff(target: 5000, frontierSeconds: .infinity, downloadProgress: 0.3, remuxFinished: false, now: t) { odd += 1 }
            }
            expect(odd == 0, "K6 receding frontier / NaN / infinite: no decision", "\(odd)")
            // K7: far controls at the M2 journeys' pace (1.2×, 6 s segments, fine): x37 (184 s ahead) and R8-#7 (1620 s) go
            // to VLC within 14 s in every phase.
            for ahead in [184.0, 1620.0] {
                var worst = 0.0, never = 0
                phases { tp, pp in
                    var w = World(); w.pace = 1.2; w.edge0 = 1200 + 0.6 * tp * 6; w.tickPhase = tp; w.pumpPhase = pp
                    if let h = simulate(w, target: w.f0 + ahead, until: 30).handOff { worst = max(worst, h) } else { never += 1 }
                }
                expect(never == 0 && worst <= 14, String(format: "K7 far control %.0f s ahead at 1.2×, fine: VLC within 14 s", ahead),
                       String(format: "worst +%.1f s, never %d/25", worst, never))
            }
        }
    }
}
