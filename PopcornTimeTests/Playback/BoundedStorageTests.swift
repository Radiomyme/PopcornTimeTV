//
//  BoundedStorageTests.swift
//  PopcornTimeTests
//
//  The app side of bounded storage (BoundedStorage.swift): the budget split, the space a
//  refused stream asks for, remuxConsumedBefore, the native rewind's earliest segment,
//  MediaByteMap and the HTTP sample filter. (Port of the bounded-storage unit harness:
//  58 checks.)
//

import XCTest
import Foundation

private struct LCG {
    var s: UInt64
    mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
}
private let MiB = Int64(1) << 20, GiB = Int64(1) << 30
private func mib(_ v: Int64) -> String { String(format: "%.0f MiB", Double(v) / Double(MiB)) }

// A 13 GB film over 2 h 10 (report_4 B4), "3 GB" free as the app sees it (2.8 GiB).
private let film: Int64 = 13_000_000_000
private let filmSeconds = 130.0 * 60
private let src = BoundedStorage.sourceBytesPerSecond(fileSize: film, durationSeconds: filmSeconds)
private func remuxInput(free: Int64, torrent: Int64 = 0, hls: Int64 = 0, rate: Double = src, out: Double? = nil, piece: Int64 = 16 * MiB) -> StorageBudget.Input {
    StorageBudget.Input(route: .remux, freeBytes: free, torrentBytesOnDisk: torrent, hlsDeletableBytes: hls,
                        sourceBytesPerSecond: rate, outputBytesPerSecond: out, pieceLength: piece)
}

final class BoundedStorageTests: CheckedTestCase {

    func testBoundedStorage() {
        let free28 = Int64(2.8 * Double(GiB))
        print("A. StorageBudget")
        do {
            let b = StorageBudget(remuxInput(free: free28))
            print("    13 GB / 2 h 10, 2.8 GiB free: room \(mib(b.roomBytes)), torrent \(mib(b.torrentBudget)) (ahead \(mib(b.torrentAheadBytes)), keep \(mib(b.torrentKeepBehindBytes))), HLS \(mib(b.hlsAllowedBytes)) (ahead \(mib(b.hlsAheadBytes)), behind \(mib(b.hlsBehindBytes))), rewind \(Int(b.rewindSeconds)) s")
            expect(b.roomBytes == free28 - 512 * MiB, "A1 room = free − the 512 MiB reserve", mib(b.roomBytes))
            expect((9...12).contains(b.rewindMinutes), "A1 native rewind ≈ 11 min (B4)", "\(b.rewindMinutes) min")
            expect(!b.failoverKeepCut && b.torrentKeepBehindBytes >= Int64(180 * src), "A1 the playhead → reader keep (≥ 180 s) is kept", mib(b.torrentKeepBehindBytes))
            expect(b.torrentAheadBytes >= 256 * MiB && b.torrentAheadBytes <= 1 * GiB, "A1 torrent ahead within [256 MiB, 1 GiB] (≈ 5 min)", mib(b.torrentAheadBytes))
            expect(b.hlsAheadBytes == Int64(180 * src), "A1 HLS ahead = the 180 s lookahead", mib(b.hlsAheadBytes))
            expect(b.protectBehindSeconds == 180, "A1 protected span behind each position unchanged (180 s)", "\(b.protectBehindSeconds)")
            let headroom = max(32 * MiB, Int64(20 * src))
            expect(b.torrentBudget + b.hlsAllowedBytes + headroom + 512 * MiB == free28,
                   "A2 reserve + torrent + HLS + headroom = the free space (nothing on disk yet)")
            // Mid-stream: the torrent holds its budget, the HLS copy what it is allowed: the split stands still.
            let mid = StorageBudget(remuxInput(free: free28 - b.torrentBudget - b.hlsAllowedBytes, torrent: b.torrentBudget, hls: b.hlsAllowedBytes))
            expect(mid.hlsAllowedBytes == b.hlsAllowedBytes && mid.torrentBudget == b.torrentBudget,
                   "A2 at its own fill level the split does not move", "\(mib(mid.hlsAllowedBytes)) vs \(mib(b.hlsAllowedBytes))")
            // The torrent over its budget (floor band, a burst): its excess is never counted as the HLS copy's.
            let over = StorageBudget(remuxInput(free: free28 - b.torrentBudget - 200 * MiB, torrent: b.torrentBudget + 200 * MiB))
            expect(over.hlsAllowedBytes == b.hlsAllowedBytes - 200 * MiB, "A5 a torrent 200 MiB over budget takes it from the HLS share",
                   "\(mib(over.hlsAllowedBytes))")
            // Tight: just above the essentials — the failover keep goes first, HLS rewind keeps 60 s, ahead ≥ minimum.
            let essentials = 512 * MiB + (64 * MiB + 32 * MiB) + 64 * MiB + 256 * MiB + Int64(180 * src) + Int64(60 * src) + headroom
            let tight = StorageBudget(remuxInput(free: essentials + 50 * MiB))
            expect(tight.failoverKeepCut && tight.torrentKeepBehindBytes == 0, "A3 tight: the playhead → reader keep is cut first",
                   mib(tight.torrentKeepBehindBytes))
            expect(tight.rewindSeconds >= 59.5 && tight.rewindSeconds < 120, "A3 tight: HLS rewind ≥ 60 s", "\(Int(tight.rewindSeconds)) s")
            expect(tight.torrentAheadBytes >= 256 * MiB, "A3 tight: torrent ahead ≥ its minimum", mib(tight.torrentAheadBytes))
            expect(tight.protectBehindSeconds >= 60 && tight.protectBehindSeconds < 180, "A3 tight: the eviction protects 60…180 s",
                   "\(tight.protectBehindSeconds)")
            // Monotone in the free space.
            var monotone = true
            var previous = StorageBudget(remuxInput(free: essentials))
            for step in stride(from: essentials, through: 8 * GiB, by: Int(64 * MiB)) {
                let s = StorageBudget(remuxInput(free: step))
                if s.rewindSeconds + 1e-9 < previous.rewindSeconds || s.torrentBudget < previous.torrentBudget
                    || s.torrentKeepBehindBytes < previous.torrentKeepBehindBytes { monotone = false }
                previous = s
            }
            expect(monotone, "A4 more free space never shortens the rewind, the torrent budget or the keep")
            // Priorities: ahead to its target before the keep, the keep before HLS behind beyond 60 s.
            let between = StorageBudget(remuxInput(free: essentials + 200 * MiB))
            expect(between.torrentAheadBytes > 256 * MiB && between.torrentKeepBehindBytes == 0,
                   "A4 the ahead window grows before the keep", "ahead \(mib(between.torrentAheadBytes)) keep \(mib(between.torrentKeepBehindBytes))")
            // HTTP routes (VLC / direct MP4): no HLS copy, the rest is the torrent's rewind (~18 min, B5).
            let http = StorageBudget(StorageBudget.Input(route: .http, freeBytes: free28, torrentBytesOnDisk: 0, sourceBytesPerSecond: src,
                                                         pieceLength: 16 * MiB, playerReadAheadSeconds: 30))
            let httpHeadroom = max(32 * MiB, Int64(20 * src))
            expect(http.torrentBudget == http.roomBytes - httpHeadroom && http.hlsAllowedBytes == 0,
                   "A7 HTTP: the room minus the headroom (20 s) is the torrent's", mib(http.torrentBudget))
            expect((15...20).contains(http.rewindMinutes), "A7 HTTP: rewind ≈ 18 min", "\(http.rewindMinutes) min")
            // 60 GB 4K at 7 MB/s (B4's worst case): the remux split stays positive, protection drops toward 60 s.
            let fourK = StorageBudget(remuxInput(free: free28, rate: 7_000_000))
            expect(fourK.failoverKeepCut && fourK.protectBehindSeconds >= 60 && fourK.protectBehindSeconds < 180,
                   "A8 60 GB 4K: keep cut, protected span 60…180 s", "rewind \(Int(fourK.rewindSeconds)) s, protect \(fourK.protectBehindSeconds)")
            expect(StorageBudget(remuxInput(free: 0)).hlsAllowedBytes == 0, "A9 no free space: no HLS allowance (never negative)")
            // The keep follows the observed playhead → reader distance (AVPlayer's requests pull the reader past one lookahead).
            let floor = Int64(225 * src)
            var observed = remuxInput(free: free28); observed.failoverKeepObservedBytes = Int64(300 * src)
            let wide = StorageBudget(observed)
            expect(wide.torrentKeepBehindBytes == Int64(300 * src) && wide.rewindSeconds < b.rewindSeconds,
                   "A10 an observed 300 s distance is kept (from the HLS rewind)", "\(mib(wide.torrentKeepBehindBytes)), rewind \(Int(wide.rewindSeconds)) s")
            observed.failoverKeepObservedBytes = 10 * GiB
            expect(StorageBudget(observed).torrentKeepBehindBytes == 2 * floor, "A10 capped at twice the lookahead keep")
            observed.failoverKeepObservedBytes = Int64(30 * src)
            expect(StorageBudget(observed).torrentKeepBehindBytes == floor, "A10 a short distance keeps the lookahead keep")
        }

        print("M. minimumFreeBytes / bytesToFree")
        do {
            let minimum = BoundedStorage.minimumFreeBytes(fileSize: film, durationSeconds: filmSeconds)
            expect(minimum > Int64(1.15 * Double(GiB)) && minimum < Int64(1.4 * Double(GiB)), "M1 13 GB / 2 h 10: ≈ 1.25 GiB (fork doc)",
                   mib(minimum))
            let k4 = BoundedStorage.minimumFreeBytes(fileSize: 60_000_000_000, durationSeconds: 60_000_000_000 / 7_000_000)
            expect(k4 > Int64(2.4 * Double(GiB)) && k4 < Int64(2.9 * Double(GiB)), "M1 60 GB 4K at 7 MB/s: ≈ 2.6 GiB (fork doc)", mib(k4))
            let free: Int64 = 900_000_000
            let toFree = BoundedStorage.bytesToFree(fileSize: film, durationSeconds: filmSeconds, freeBytes: free)
            expect(toFree >= minimum - free && toFree < minimum - free + 100_000_000 && toFree % 100_000_000 == 0,
                   "M2 bytesToFree = the shortfall rounded up to 100 MB", "\(toFree)")
            expect(BoundedStorage.bytesToFree(fileSize: film, durationSeconds: filmSeconds, freeBytes: 2 * GiB) == 0, "M2 0 when it fits")
            expect(BoundedStorage.sourceBytesPerSecond(fileSize: 7200, durationSeconds: 0) == 1, "M3 unknown duration: 2 h")
            expect(BoundedStorage.tailPinBytes(pieceLength: 16 * MiB) == 32 * MiB && BoundedStorage.tailPinBytes(pieceLength: MiB) == 8 * MiB
                   && BoundedStorage.tailPinBytes(pieceLength: 256 * 1024) == 2560 * 1024, "M4 tail pin: whole pieces for 8 MiB, 2…10 (fork)")
        }

        print("H. httpConsumedBefore (part-2 fix: byte cap)")
        do {
            // A denser stretch: the time rule releases less than the split keeps in bytes.
            expect(BoundedStorage.httpConsumedBefore(byTime: 1_000, byBytes: 5_000, served: 9_000) == 5_000,
                   "H1 the byte rule wins when the time rule keeps more than the split's bytes")
            expect(BoundedStorage.httpConsumedBefore(byTime: 6_000, byBytes: 5_000, served: 9_000) == 6_000,
                   "H2 the time rule wins when it releases more")
            expect(BoundedStorage.httpConsumedBefore(byTime: 12_000, byBytes: 5_000, served: 9_000) == 9_000,
                   "H3 never past the read position")
            expect(BoundedStorage.httpConsumedBefore(byTime: 3_000, byBytes: -5_000, served: 0) == 3_000,
                   "H4 no read position: the time rule alone")
            expect(BoundedStorage.httpConsumedBefore(byTime: 0, byBytes: -5_000, served: 9_000) == 0, "H5 never negative")
            expect(BoundedStorage.fullModeAppWorkingSetSeconds >= 360, "H6 full mode leaves room for 360 s of HLS at least")
        }

        print("R. remuxConsumedBefore")
        do {
            let reader: Int64 = 5 * GiB
            expect(BoundedStorage.remuxConsumedBefore(readerOffset: reader, playheadSourceOffset: 4 * GiB, keepBehindBytes: 2 * GiB) == 4 * GiB,
                   "R1 room for the keep: release up to the playhead's cluster")
            expect(BoundedStorage.remuxConsumedBefore(readerOffset: reader, playheadSourceOffset: 4 * GiB, keepBehindBytes: 0) == reader,
                   "R2 keep cut: release up to the reader")
            expect(BoundedStorage.remuxConsumedBefore(readerOffset: reader, playheadSourceOffset: 4 * GiB, keepBehindBytes: 512 * MiB) == reader - 512 * MiB,
                   "R2 partial keep: the reader minus the keep")
            expect(BoundedStorage.remuxConsumedBefore(readerOffset: reader, playheadSourceOffset: 6 * GiB, keepBehindBytes: GiB) == reader,
                   "R3 never past the reader")
            expect(BoundedStorage.remuxConsumedBefore(readerOffset: reader, playheadSourceOffset: nil, keepBehindBytes: GiB) == reader - GiB,
                   "R4 no playhead: the budget alone")
            expect(BoundedStorage.remuxConsumedBefore(readerOffset: 0, playheadSourceOffset: nil, keepBehindBytes: GiB) == 0, "R4 nothing read: 0")
        }

        print("K. earliestContiguousKeptSegment")
        do {
            var pruned = IndexSet(1...40)
            expect(BoundedStorage.earliestContiguousKeptSegment(playheadSegment: 100, written: 130, pruned: pruned) == 41, "K1 the run after the pruned span")
            expect(BoundedStorage.earliestContiguousKeptSegment(playheadSegment: 20, written: 130, pruned: pruned) == nil, "K2 a pruned playhead segment: nil")
            expect(BoundedStorage.earliestContiguousKeptSegment(playheadSegment: 140, written: 130, pruned: pruned) == nil, "K3 not written yet: nil")
            pruned = IndexSet()
            expect(BoundedStorage.earliestContiguousKeptSegment(playheadSegment: 50, written: 130, pruned: pruned) == 0, "K4 nothing pruned: segment 0")
            pruned = IndexSet([5, 60])
            expect(BoundedStorage.earliestContiguousKeptSegment(playheadSegment: 100, written: 130, pruned: pruned) == 61, "K5 the nearest hole bounds it")
        }

        print("D. MediaByteMap")
        do {
            var map = MediaByteMap()
            map.add(time: 10, byte: 100)
            map.add(time: 20, byte: 300)
            map.add(time: 15, byte: 200)
            map.add(time: 30, byte: 250)            // redundant: lower than the bound at 20
            expect(map.anchors.map(\.time) == [10, 15, 20], "D1 staircase, redundant anchors ignored", "\(map.anchors)")
            map.add(time: 12, byte: 400)            // implies 15 and 20
            expect(map.anchors.map(\.time) == [10, 12] && map.lowerBound(atTime: 25) == 400, "D1 a higher earlier anchor replaces later lower ones")
            expect(map.lowerBound(atTime: 5) == 0 && map.lowerBound(atTime: 11) == 100, "D1 lower bound before / between anchors")
            expect(map.earliestTime(atOrAbove: 150) == 12 && map.earliestTime(atOrAbove: 500) == nil, "D1 earliest time at or above an offset")

            // VBR worlds: b(t) = offset a player resuming at t needs (keyframe cluster), piecewise-linear with scenes of 0.3–3×
            // the mean rate; a player with read-ahead λ ∈ [0, λmax] sampled once a second while playing, with seeks.
            var valid = true, tight = true, earliestValid = true, rng = LCG(s: 7)
            var worstLag = 0.0
            for world in 0..<40 {
                var knots: [(Double, Double)] = [(0, 0)]
                var t = 0.0, b = 0.0
                while t < 7800 { let d = 20 + rng.next() * 300; t += d; b += d * src * (0.3 + rng.next() * 2.7); knots.append((t, b)) }
                func offset(_ x: Double) -> Int64 {
                    guard x > 0 else { return 0 }
                    for i in 1..<knots.count where knots[i].0 >= x {
                        let (t0, b0) = knots[i - 1], (t1, b1) = knots[i]
                        return Int64(b0 + (b1 - b0) * (x - t0) / (t1 - t0))
                    }
                    return Int64(knots.last!.1)
                }
                let lambdaMax = 30.0 + Double(world % 3) * 30
                var m = MediaByteMap()
                m.capacity = world % 2 == 0 ? 64 : 4096            // thinning keeps validity
                var playhead = rng.next() * 600
                for second in 0..<3000 {
                    if second % 700 == 699 { playhead = max(0, playhead + (rng.next() - 0.4) * 1800) }  // seeks
                    playhead += 1
                    let lambda = rng.next() * lambdaMax
                    m.add(time: playhead + lambdaMax, byte: offset(playhead + lambda))
                }
                for probe in stride(from: 0.0, to: 7800, by: 7.3) {
                    let low = m.lowerBound(atTime: probe)
                    if low > offset(probe) { valid = false }
                    if let e = m.earliestTime(atOrAbove: low), low > 0, offset(e) < low { earliestValid = false }
                }
                // Tightness over the last steady stretch (200 s since the last seek): the bound lags the real offset by about
                // λmax + 1 s at most.
                for probe in stride(from: playhead - 198 + lambdaMax, to: playhead, by: 3.0) where m.capacity > 1000 {
                    let low = m.lowerBound(atTime: probe)
                    var lag = 0.0
                    while offset(probe - lag) > low && lag < 1000 { lag += 1 }
                    worstLag = max(worstLag, lag - lambdaMax)
                    if lag > lambdaMax + 2 { tight = false }
                }
            }
            expect(valid, "D2 40 VBR worlds with seeks: the map never exceeds the real offset (a lower bound)")
            expect(earliestValid, "D3 earliestTime(atOrAbove: b): every later time needs b or more")
            expect(tight, "D2 the bound lags the real offset by at most λmax + 2 s on steady stretches", String(format: "worst %.1f s past λmax", worstLag))
            var thin = MediaByteMap()
            thin.capacity = 32
            for k in 1...10_000 { thin.add(time: Double(k), byte: Int64(k) * 1000) }
            expect(thin.anchors.count <= 33 && thin.lowerBound(atTime: 10_000) == 10_000_000, "D4 thinning bounds the size and keeps the highest anchor",
                   "\(thin.anchors.count) anchors")
            // Binary search = linear scan.
            var agree = true
            for cut in stride(from: Int64(0), through: 11_000_000, by: 333_333) {
                if thin.earliestTime(atOrAbove: cut) != thin.anchors.first(where: { $0.byte >= cut })?.time { agree = false }
            }
            expect(agree, "D5 earliestTime's binary search matches a linear scan")
        }

        print("F. HTTPSampleFilter")
        do {
            var f = HTTPSampleFilter(settleSeconds: 6)
            var accepted: [Int] = []
            var served: Int64 = 100 * MiB
            for s in 0..<20 {
                served += Int64(src)
                if f.accept(clock: Double(s), time: 100 + Double(s), served: served, isPlaying: true, bytesPerSecond: src) { accepted.append(s) }
            }
            expect(accepted.first == 7 && accepted.count == 13, "F1 steady playback: anchors once settled (6 s)", "\(accepted)")
            // A seek (playhead jump) resets; the read position moving back too.
            var g = HTTPSampleFilter(settleSeconds: 6)
            served = 100 * MiB
            var afterSeek: [Int] = []
            for s in 0..<30 {
                let time = s < 10 ? 100 + Double(s) : 2000 + Double(s)
                served = s == 10 ? 50 * MiB : served + Int64(src)
                if g.accept(clock: Double(s), time: time, served: served, isPlaying: true, bytesPerSecond: src) { afterSeek.append(s) }
            }
            expect(!afterSeek.contains(where: { (10...16).contains($0) }) && afterSeek.contains(17), "F2 a seek (time jump, read position back) waits 6 s again",
                   "\(afterSeek)")
            var h = HTTPSampleFilter(settleSeconds: 0)
            _ = h.accept(clock: 0, time: 100, served: 10 * MiB, isPlaying: true, bytesPerSecond: src)
            expect(!h.accept(clock: 1, time: 101, served: 11 * MiB, isPlaying: false, bytesPerSecond: src), "F3 paused: no anchor")
            _ = h.accept(clock: 2, time: 102, served: 12 * MiB, isPlaying: true, bytesPerSecond: src)
            expect(!h.accept(clock: 3, time: 103, served: 4 * GiB, isPlaying: true, bytesPerSecond: src), "F4 a read position jump: no anchor")
        }
    }
}
