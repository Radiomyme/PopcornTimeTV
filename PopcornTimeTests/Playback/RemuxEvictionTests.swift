//
//  RemuxEvictionTests.swift
//  PopcornTimeTests
//
//  RemuxPlayback.evictionVictims in bounded mode: what is kept behind the playhead goes
//  first, furthest first, then what is ahead. (Port of the eviction harness: 5 checks.)
//

import XCTest
import Foundation


final class RemuxEvictionTests: CheckedTestCase {

    func testEvictionInBoundedMode() {
        print("E. evictionVictims, bounded order (part-2 fix)")
        // 300 segments of 6 s; kept: 84...115 ([504, 696)) behind the playhead 757, and 156...243 ([936, 1464))
        // ahead of it (written before a deep rewind); the rest pruned. 1 MB each.
        let durations = Array(repeating: 6.0, count: 300)
        let bytes = Array(repeating: Int64(1_000_000), count: 300)
        var pruned = IndexSet(1..<300)
        pruned.subtract(IndexSet(84...115)); pruned.subtract(IndexSet(156...243))
        let positions = [757.0, 757.0, 756.0]
        let keptCount = 32 + 88
        let allowed = Int64(keptCount - 20) * 1_000_000
        let full = RemuxPlayback.evictionVictims(durations: durations, segmentBytes: bytes, pruned: pruned, positions: positions,
                                                  allowedKeptBytes: allowed, protectBehind: 60)
        expect(full.count == 20 && full.allSatisfy { $0 >= 156 }, "E1 full mode (nil): furthest first — the old window ahead goes", "\(full.first!)…\(full.last!)")
        let bounded = RemuxPlayback.evictionVictims(durations: durations, segmentBytes: bytes, pruned: pruned, positions: positions,
                                                     allowedKeptBytes: allowed, protectBehind: 60, behindFirstOf: 757)
        expect(bounded.count == 20 && bounded.allSatisfy { $0 < 116 }, "E2 bounded: behind the playhead first, furthest first",
               "\(bounded.first!)…\(bounded.last!)")
        expect(bounded.first == 84, "E3 the furthest behind goes first")
        // More than everything behind: then the ahead ones, furthest first.
        let more = RemuxPlayback.evictionVictims(durations: durations, segmentBytes: bytes, pruned: pruned, positions: positions,
                                                  allowedKeptBytes: Int64(keptCount - 40) * 1_000_000, protectBehind: 60, behindFirstOf: 757)
        let behindUnprotected = (84...115).filter { Double($0 + 1) * 6 < 756 - 60 }.count
        expect(more.count == 40 && more.prefix(behindUnprotected).allSatisfy { $0 < 116 } && more.suffix(40 - behindUnprotected).allSatisfy { $0 >= 156 }
               && more.last! < 243, "E4 then ahead, furthest first", "behind \(behindUnprotected), last \(more.last!)")
        expect(RemuxPlayback.evictionVictims(durations: durations, segmentBytes: bytes, pruned: pruned, positions: positions,
                                             allowedKeptBytes: Int64(keptCount) * 1_000_000, protectBehind: 60, behindFirstOf: 757).isEmpty,
               "E5 nothing over the budget: nothing evicted")
    }
}
