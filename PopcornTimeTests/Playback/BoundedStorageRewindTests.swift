//
//  BoundedStorageRewindTests.swift
//  PopcornTimeTests
//
//  BoundedStorage.httpRewindTargetIsOnDisk: a rewind reaches data still on disk before a
//  gap a forward seek left, never the gap nor what lowestAvailableOffset freed.
//  (Port of the part-3 unit harness: 18 checks.)
//

import XCTest
import Foundation

// vgap1's film: 4.5 GiB over 2875 s (1.67 MB/s).
private let rate = Double(4_802_708_788) / 2875
private func off(_ t: Double) -> Int64 { Int64(t * rate) }

/// On disk: a set of [begin, end) runs. firstMissingOffset(from:) as PopcornTorrent answers it.
private struct Disk {
    var runs: [(Int64, Int64)]
    var size: Int64 = 4_802_708_788
    func firstMissing(_ from: Int64) -> Int64 {
        for (b, e) in runs where from >= b && from < e { return e }
        return from
    }
}

/// Anchors the HTTP sample filter gives while playing [from, to] s: (playhead + read-ahead, served),
/// the player having read `lead` seconds past its playhead.
private func playedMap(_ from: Double, _ to: Double, readAhead: Double = 60, lead: Double = 5, into map: inout MediaByteMap) {
    var t = from
    while t <= to {
        map.add(time: t + readAhead, byte: off(t + lead))
        t += 1
    }
}

final class BoundedStorageRewindTests: CheckedTestCase {

    func testHTTPRewindTargetIsOnDisk() {
        let MiB = Int64(1) << 20
        print("I. httpRewindTargetIsOnDisk")
        do {
            // I1 vgap1 without anything consumed yet: played 6–120 s, the torrent's window held 0–1428 MiB, far seek to
            // 1200 s (its run 1900–2100 MiB). Lowest 0.
            var map = MediaByteMap()
            playedMap(6, 120, into: &map)
            playedMap(1206, 1270, into: &map)
            let disk = Disk(runs: [(0, 1428 * MiB), (1900 * MiB, 2100 * MiB)])
            func onDisk(_ t: Double, lowest: Int64 = 0) -> Bool {
                BoundedStorage.httpRewindTargetIsOnDisk(target: t, map: map, lowestAvailableOffset: lowest, bytesPerSecond: rate,
                                                        marginSeconds: 10, firstMissingOffset: disk.firstMissing)
            }
            expect(onDisk(30), "I1 a played stretch before the gap")
            expect(onDisk(300), "I1 the window data before the gap (never played, on disk)")
            expect(onDisk(800), "I1 still inside the window (≈ 1270 MiB of 1428)")
            expect(!onDisk(1000), "I1 the gap (≈ 1590 MiB, never downloaded) stays out of reach")
            expect(!onDisk(1150), "I1 the gap just below the seek's landing")
            // I2 the same after the byte rule consumed 0–412 MiB: the bound of 300 s (served at 120 s ≈ 200 MiB) is under
            // the floor — that the keyframe before 300 s is above 412 MiB can't be proven: blocked (no HTTP 410 risk).
            expect(!onDisk(300, lowest: 412 * MiB), "I2 a bound under lowestAvailableOffset is never trusted")
            expect(!onDisk(30, lowest: 412 * MiB), "I2 consumed data")
        }
        do {
            // I3 played 0–900 s, lowest 412 MiB (≈ 260 s), far seek to 2600 s: a rewind to 500 s (played, on disk) is allowed.
            var map = MediaByteMap()
            playedMap(6, 900, into: &map)
            playedMap(2606, 2650, into: &map)
            let disk = Disk(runs: [(0, 64 * MiB), (412 * MiB, off(905) + 200 * MiB), (off(2600), off(2700))])
            func onDisk(_ t: Double) -> Bool {
                BoundedStorage.httpRewindTargetIsOnDisk(target: t, map: map, lowestAvailableOffset: 412 * MiB, bytesPerSecond: rate,
                                                        marginSeconds: 10, firstMissingOffset: disk.firstMissing)
            }
            expect(onDisk(500), "I3 back to a played stretch before the gap")
            expect(onDisk(890), "I3 the last played seconds before the seek")
            expect(!onDisk(300), "I3 a target whose bound lies under the floor (≈ 260 s + read-ahead)")
            expect(!onDisk(1500), "I3 the gap")
        }
        do {
            // I4 tvOS tvb1: the remux played and seeded the map (segment starts), then VLC took over at 950 s;
            // nothing consumed. A rewind to 30 s is on disk.
            var map = MediaByteMap()
            var start = 0.0
            while start < 900 { map.add(time: start + 8, byte: max(1, off(start))); start += 6 }
            playedMap(956, 980, into: &map)
            let disk = Disk(runs: [(0, off(920)), (off(948), off(1000))])
            let result = BoundedStorage.httpRewindTargetIsOnDisk(target: 30, map: map, lowestAvailableOffset: 0, bytesPerSecond: rate,
                                                                  marginSeconds: 10, firstMissingOffset: disk.firstMissing)
            expect(result, "I4 tvb1: rewind 962 → 30 s reaches the remux's data on disk")
        }
        do {
            // I5 VLC resumed at 3000 s (only the head pin and the resume run on disk): a rewind to 1000 s was never
            // downloaded — no anchor before it, the estimate from 0 runs far past the head pin.
            var map = MediaByteMap()
            playedMap(3006, 3100, into: &map)
            let disk = Disk(runs: [(0, 64 * MiB), (off(2995), off(3200))])
            let result = BoundedStorage.httpRewindTargetIsOnDisk(target: 1000, map: map, lowestAvailableOffset: 0, bytesPerSecond: rate,
                                                                  marginSeconds: 10, firstMissingOffset: disk.firstMissing)
            expect(!result, "I5 before a resume point: never downloaded, blocked")
            let head = BoundedStorage.httpRewindTargetIsOnDisk(target: 15, map: map, lowestAvailableOffset: 0, bytesPerSecond: rate,
                                                                marginSeconds: 10, firstMissingOffset: disk.firstMissing)
            expect(head, "I5 the first seconds, inside the pinned head (25 s of it)")
        }
        do {
            // I6 degenerate inputs.
            let map = MediaByteMap()
            let disk = Disk(runs: [(0, 1000 * MiB)])
            expect(!BoundedStorage.httpRewindTargetIsOnDisk(target: 30, map: map, lowestAvailableOffset: 0, bytesPerSecond: 0,
                                                            marginSeconds: 10, firstMissingOffset: disk.firstMissing), "I6 unknown bitrate")
            expect(!BoundedStorage.httpRewindTargetIsOnDisk(target: .nan, map: map, lowestAvailableOffset: 0, bytesPerSecond: rate,
                                                            marginSeconds: 10, firstMissingOffset: disk.firstMissing), "I6 NaN target")
            expect(BoundedStorage.httpRewindTargetIsOnDisk(target: 30, map: map, lowestAvailableOffset: 0, bytesPerSecond: rate,
                                                           marginSeconds: 10, firstMissingOffset: disk.firstMissing), "I6 no anchor, all on disk from 0")
        }
        do {
            // I7 safety on variable-bitrate worlds: whenever the answer is yes, the player's resume offset (the keyframe
            // before the target, ≤ 10 s back) lies at or above lowestAvailableOffset: never deleted data (HTTP 410).
            var seed: UInt64 = 0x5eed
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
            var violations = 0, yes = 0, cases = 0
            for _ in 0..<200 {
                // A VBR film: per-second sizes between 0.3× and 2.5× the average.
                var cumulative: [Int64] = [0]
                for _ in 0..<3000 { cumulative.append(cumulative.last! + Int64(rate * (0.3 + 2.2 * rnd()))) }
                func trueOffset(_ t: Double) -> Int64 { cumulative[max(0, min(cumulative.count - 1, Int(t)))] }
                let readAhead = 20 + 100 * rnd()
                var map = MediaByteMap()
                let playedEnd = 200 + 1500 * rnd()
                var t = 6.0
                while t <= playedEnd { map.add(time: t + readAhead, byte: trueOffset(t + readAhead * rnd())); t += 1 }
                let lowest = trueOffset(playedEnd * rnd() * 0.8)
                let windowEnd = trueOffset(min(2990, playedEnd + 400 * rnd()))
                let disk = Disk(runs: [(lowest, windowEnd)])
                for _ in 0..<40 {
                    let target = 15 + (playedEnd + 600) * rnd()
                    cases += 1
                    if BoundedStorage.httpRewindTargetIsOnDisk(target: target, map: map, lowestAvailableOffset: lowest, bytesPerSecond: rate,
                                                               marginSeconds: 10, firstMissingOffset: disk.firstMissing) {
                        yes += 1
                        if trueOffset(target - 10) < lowest { violations += 1 }
                    }
                }
            }
            expect(violations == 0 && yes > 0, "I7 VBR worlds: a yes never resumes under the floor", "\(yes) yes of \(cases), \(violations) violations")
        }
    }
}
