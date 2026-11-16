//
//  PlaybackStartTraceTests.swift
//  PopcornTimeTests
//
//  PlaybackStartTrace: one [Start] line per phase of a playback's start, with milliseconds.
//

import XCTest
import Foundation
@testable import PopcornKit

final class PlaybackStartTraceTests: CheckedTestCase {

    func testAStreamedMKV() {
        let clock = ManualClock()
        var lines: [String] = []
        let trace = PlaybackStartTrace(title: "Dune", now: clock.now, log: { lines.append($0) })
        trace.begin(.subtitles)
        clock.advance(0.83)
        check(trace.reach(.subtitles, detail: "23 language(s)"), "subtitles reached")
        clock.advance(2.37)
        trace.reach(.metadata, detail: "12 peer(s)")
        clock.advance(8.1)
        trace.reach(.buffer, detail: "Dune.2160p.mkv")
        clock.advance(0.42)
        trace.reach(.remuxPrepare, detail: "2 segment(s)")
        clock.advance(0.9)
        trace.reach(.firstFrame, detail: "AVPlayer (remux)")
        eq(lines, [
            "[Start] subtitles: 830 ms (t+830 ms) — 23 language(s)",
            "[Start] metadata: 3200 ms (t+3200 ms) — 12 peer(s)",
            "[Start] buffer: 8100 ms (t+11300 ms) — Dune.2160p.mkv",
            "[Start] remux prepare: 420 ms (t+11720 ms) — 2 segment(s)",
            "[Start] first frame: 900 ms (t+12620 ms) — AVPlayer (remux)",
            "[Start] total: 12620 ms to the first frame — Dune (subtitles 830 ms · metadata 3200 ms · buffer 8100 ms · "
                + "remux prepare 420 ms · first frame 900 ms)",
        ], "the lines of a streamed MKV")
        check(abs((trace.duration(of: .buffer) ?? 0) - 8.1) < 1e-6, "a phase's duration is readable")
    }

    func testPhasesAreReachedOnceAndMayBeAbsent() {
        let clock = ManualClock()
        var lines: [String] = []
        let trace = PlaybackStartTrace(title: "Film", now: clock.now, log: { lines.append($0) })
        clock.advance(1)
        check(trace.reach(.metadata), "first time")
        clock.advance(1)
        check(!trace.reach(.metadata), "a phase is reached once: the 1 Hz samples after it log nothing")
        eq(lines, ["[Start] metadata: 1000 ms (t+1000 ms)"], "one line, no detail")
        // A direct MP4 on VLC: no remux phase; the first frame follows the buffer.
        clock.advance(4)
        trace.reach(.buffer)
        clock.advance(0.5)
        trace.reach(.firstFrame, detail: "VLC")
        eq(lines.suffix(2).first, "[Start] first frame: 500 ms (t+6500 ms) — VLC", "the first frame counts from the phase before it")
        check(lines.last?.contains("remux prepare") == false && lines.last?.hasPrefix("[Start] total: 6500 ms") == true,
              "the total lists only the phases that happened", lines.last ?? "")
        check(trace.duration(of: .remuxPrepare) == nil && trace.duration(of: .subtitles) == nil, "absent phases have no duration")
    }

    func testSubtitlesRunAlongsideTheStream() {
        let clock = ManualClock()
        var lines: [String] = []
        let trace = PlaybackStartTrace(title: "Film", now: clock.now, log: { lines.append($0) })
        trace.begin(.subtitles)
        clock.advance(2)
        trace.reach(.metadata)
        clock.advance(3)
        trace.reach(.subtitles)   // a slow OpenSubtitles: 5 s, during the buffering
        clock.advance(1)
        trace.reach(.buffer)
        eq(lines, ["[Start] metadata: 2000 ms (t+2000 ms)",
                   "[Start] subtitles: 5000 ms (t+5000 ms)",
                   "[Start] buffer: 4000 ms (t+6000 ms)"],
           "the subtitles phase does not push the buffer phase: it ran in parallel")
    }

    func testSourcesLine() {
        eq(PlaybackStartTrace.sourcesLine(elapsed: 1.2396, detail: "14 torrent(s)"), "[Start] sources: 1240 ms — 14 torrent(s)",
           "the sources line stands alone (the chooser sits between it and the stream)")
        eq(PlaybackStartTrace.line(.buffer, elapsed: -1, sinceStart: .infinity), "[Start] buffer: 0 ms (t+0 ms)",
           "nonsense durations log 0")
    }
}
