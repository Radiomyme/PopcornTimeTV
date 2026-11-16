//
//  ManualClock.swift
//  PopcornTimeTests
//
//  A clock the tests move by hand, with the blocks scheduled on it: what PopcornKit's
//  time-dependent classes (SubtitleSearch, EpisodeSourceResolver, PlaybackStartTrace) take
//  as `now` and `after`, so that a 3 s deadline is tested in microseconds.
//

import Foundation

final class ManualClock {
    private(set) var time: TimeInterval
    private var timers: [(at: TimeInterval, order: Int, block: () -> Void)] = []
    private var scheduled = 0

    init(_ time: TimeInterval = 1000) {
        self.time = time
    }

    /// `now` for the class under test (the closures keep the clock alive).
    var now: () -> TimeInterval { { [self] in self.time } }

    /// `after` for the class under test.
    var after: (TimeInterval, @escaping () -> Void) -> Void {
        { [self] delay, block in
            self.scheduled += 1
            self.timers.append((self.time + max(0, delay), self.scheduled, block))
        }
    }

    /// Moves the clock `seconds` ahead, running what comes due on the way, in order (a block
    /// may schedule another).
    func advance(_ seconds: TimeInterval) {
        let target = time + seconds
        while let next = timers.filter({ $0.at <= target }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            timers.removeAll { $0.order == next.order }
            time = max(time, next.at)
            next.block()
        }
        time = target
    }
}
