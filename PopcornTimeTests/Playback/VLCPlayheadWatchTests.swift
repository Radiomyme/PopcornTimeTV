//
//  VLCPlayheadWatchTests.swift
//  PopcornTimeTests
//
//  VLCPlayheadWatch (BoundedStorageUX.swift): VLC's own seeks and clock jitter are not
//  rewinds; a real rewind is caught once. (Port: 14 checks.)
//

import XCTest
import Foundation

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

final class VLCPlayheadWatchTests: CheckedTestCase {

    func testVLCPlayheadWatch() {
        // 1. part 2's fhand2: start at a position (own seek), VLC reports 2604.0 then 2602.2 → not a rewind
        var w = VLCPlayheadWatch(); w.noteOwnSeek(at: at(0))
        check(w.rewind(to: 2604.0, at: at(1)) == nil, "hand-off first tick")
        check(w.rewind(to: 2602.2, at: at(1.5)) == nil, "hand-off settle step back")
        check(w.rewind(to: 2603.0, at: at(5)) == nil, "after settle forward")
        // 2. the same step back 10 s after the seek: below the jitter → not a rewind
        check(w.rewind(to: 2600.5, at: at(10)) == nil, "small step back after settle")
        // 3. a real rewind (rate-based, cumulative 3 s steps) → caught once more than 5 s back from the furthest time
        var r = VLCPlayheadWatch(); _ = r.rewind(to: 1000, at: at(0))
        check(r.rewind(to: 997, at: at(1)) == nil, "rate rewind step 1")
        check(r.rewind(to: 994, at: at(2)) == 1000, "rate rewind step 2 caught from 1000")
        check(r.rewind(to: 991, at: at(3)) == nil, "reference moved to 994")
        check(r.rewind(to: 988, at: at(4)) == 994, "caught again from 994")
        // 4. a big jump back within the settle window of an own seek → ignored (already limited where made)
        var s = VLCPlayheadWatch(); _ = s.rewind(to: 500, at: at(0)); s.noteOwnSeek(at: at(10))
        check(s.rewind(to: 100, at: at(11)) == nil, "own limited seek")
        check(s.rewind(to: 101, at: at(16)) == nil, "after own seek forward")
        // 5. a big jump back with no own seek → caught
        check(s.rewind(to: 50, at: at(20)) == 101, "unlimited rewind caught")
        // 6. normal forward play never fires; paused (same time) never fires
        var p = VLCPlayheadWatch(); var fired = false
        for i in 0..<100 { if p.rewind(to: Double(i) * 0.5, at: at(Double(i) * 0.5)) != nil { fired = true } }
        for i in 0..<10 { if p.rewind(to: 49.5, at: at(60 + Double(i))) != nil { fired = true } }
        check(!fired, "forward play and pause")
        // 7. undf
        check(BoundedStorageUX.isUndecodableVLCTrack(codec: 0x66646e75), "undf")
        check(!BoundedStorageUX.isUndecodableVLCTrack(codec: 0x74627573), "subt")   // 'subt' little-endian
    }
}
