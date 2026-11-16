//
//  RemuxSteeringTests.swift
//  PopcornTimeTests
//
//  RemuxSteering.readPosition: what the remux tells the torrent to download after a tick, in
//  both storage modes — nothing for a film played from 0:00 in full mode, the resume point
//  while the question is up, the pass's reader from the first jump on, nothing once stopped.
//

import XCTest
import Foundation

final class RemuxSteeringTests: CheckedTestCase {

    private func position(stopped: Bool = false, prepared: Int64? = nil, bounded: Bool, jumped: Bool = false,
                          reader: Int64) -> Int64? {
        RemuxSteering.readPosition(isStopped: stopped, preparedOffset: prepared, isBounded: bounded, hasJumped: jumped,
                                   readerOffset: reader)
    }

    func testFullModeIsLeftAloneUntilAJump() {
        eq(position(bounded: false, reader: 0), nil, "before the header: nothing")
        eq(position(bounded: false, reader: 40_000_000), nil, "full mode, played from 0:00, no jump: PopcornTorrent's own window")
        eq(position(bounded: false, jumped: true, reader: 6_400_000_000), 6_400_000_000, "after a jump the torrent follows the pass's reader")
        eq(position(bounded: false, jumped: true, reader: 0), nil, "never offset 0")
    }

    func testBoundedModeFollowsTheReader() {
        eq(position(bounded: true, reader: 40_000_000), 40_000_000, "bounded mode: the window follows the reader, as before")
        eq(position(bounded: true, reader: 0), nil, "not before the header is parsed")
        eq(position(bounded: true, jumped: true, reader: 6_400_000_000), 6_400_000_000, "and after a jump")
    }

    func testThePreparedResumeWinsInBothModes() {
        for bounded in [false, true] {
            let mode = bounded ? "bounded" : "full"
            eq(position(prepared: 6_300_000_000, bounded: bounded, reader: 40_000_000), 6_300_000_000,
               "\(mode): while the question is up the torrent turns to the resume point")
            eq(position(prepared: 6_300_000_000, bounded: bounded, jumped: true, reader: 90_000_000), 6_300_000_000,
               "\(mode): also after an earlier jump")
            eq(position(prepared: 6_300_000_000, bounded: bounded, reader: 0), 6_300_000_000, "\(mode): whatever the reader")
            eq(position(stopped: true, prepared: 6_300_000_000, bounded: bounded, jumped: true, reader: 40_000_000), nil,
               "\(mode): nothing once stopped")
        }
        eq(position(prepared: -5, bounded: false, reader: 40_000_000), 0, "a negative offset is clamped")
    }

    func testFromTheBeginningGoesBackToTheHead() {
        // « Start from the beginning »: the prepared offset is gone; the head is reported once
        // by the engine itself (full mode: nothing more), then every tick in bounded mode.
        eq(position(prepared: nil, bounded: false, reader: 40_000_000), nil, "full mode: nothing more after the answer")
        eq(position(prepared: nil, bounded: true, reader: 40_000_000), 40_000_000, "bounded mode: the reader again, every tick")
        eq(position(stopped: true, bounded: true, reader: 40_000_000), nil, "nothing after stop()")
    }
}
