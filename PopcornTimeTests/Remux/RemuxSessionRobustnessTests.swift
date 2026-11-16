//
//  RemuxSessionRobustnessTests.swift
//  PopcornTimeTests
//
//  The remux session (MKVToHLSRemuxSession) on synthetic Matroska streams: a normal one, then
//  the malformed ones that used to bring the app down — a video with a single keyframe (the
//  whole file read into memory by one `pump`), a cluster timestamp no movie has (a trap in the
//  timeline's arithmetic), a forged TimestampScale.
//

import XCTest
import Foundation

final class RemuxSessionRobustnessTests: CheckedTestCase {

    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    /// A prepared session on `stream` (the input complete, as for a finished download).
    private func session(_ stream: SyntheticMatroska, file: StaticString = #filePath, line: Int = #line) -> (MKVToHLSRemuxSession, URL)? {
        guard let files = try? stream.write() else {
            check(false, "the synthetic stream is written", file: file, line: line)
            return nil
        }
        directories.append(files.directory)
        guard let session = try? MKVToHLSRemuxSession(inputFile: files.input, outputDirectory: files.output) else {
            check(false, "the session opens", file: file, line: line)
            return nil
        }
        session.markInputComplete()
        var result = session.prepare()
        var tries = 0
        while result == .needMoreData, tries < 20 { result = session.prepare(); tries += 1 }
        check(result == .ready, "the synthetic stream is playable natively", "\(result)", file: file, line: line)
        return result == .ready ? (session, files.output) : nil
    }

    /// Pumps like `RemuxPlayback.tick` until the input is exhausted (three idle calls) or the
    /// session stops; returns the number of `pump` calls.
    @discardableResult
    private func drain(_ session: MKVToHLSRemuxSession, maxCalls: Int = 100_000) -> Int {
        var idle = 0, calls = 0
        while idle < 3, calls < maxCalls, session.writeFailure == nil {
            let written = session.pump(maxNewSegments: 2)
            calls += 1
            idle = (written == 0 && !session.stoppedAtInputBudget) ? idle + 1 : 0
        }
        return calls
    }

    /// Every file of the output directory, by name.
    private func files(in directory: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            result[name] = try? Data(contentsOf: directory.appendingPathComponent(name))
        }
        return result
    }

    // MARK: A normal stream

    func testANormalStreamIsCutOnTheKeyframeGrid() {
        guard let (session, output) = session(SyntheticMatroska()) else { return }
        eq(session.pump(maxNewSegments: 2), 2, "two segments per call when the input is there")
        check(!session.stoppedAtInputBudget, "the input budget is not what ended that call")
        drain(session)
        session.finish()
        let durations = session.segmentDurations()
        eq(durations.count, 5, "30 s of 1 s GOPs: five 6 s segments")
        check(durations.allSatisfy { abs($0 - 6) < 0.05 }, "each 6 s long", "\(durations)")
        check(abs(session.progress.mediaSeconds - 30) < 0.05 && session.progress.finished, "30 s published", "\(session.progress)")
        check(session.writeFailure == nil, "healthy")
        eq(session.implausibleClusters, 0, "no cluster skipped")
        let written = files(in: output)
        check((0..<5).allSatisfy { written["vseg\($0).m4s"] != nil && written["a0seg\($0).m4s"] != nil }
              && written["video_init.mp4"] != nil && written["audio0_init.mp4"] != nil, "every segment file is on disk",
              "\(written.keys.sorted())")
    }

    func testTheInputBudgetChangesNothingOfTheOutput() {
        var stream = SyntheticMatroska()
        stream.videoFrameBytes = 1500   // ~38 KB a second
        guard let (reference, referenceOutput) = session(stream), let (budgeted, budgetedOutput) = session(stream) else { return }
        drain(reference)
        reference.finish()
        // A budget below one segment's input: `pump` returns between cuts.
        budgeted.pumpInputBudget = 40_000
        let first = budgeted.pump(maxNewSegments: 2)
        check(first == 0 && budgeted.stoppedAtInputBudget, "the call returns at its budget, saying there is more to read",
              "\(first) segment(s)")
        let consumed = budgeted.consumedInputOffset
        check(consumed > 0 && consumed < 200_000, "…having read about its budget, not the file", "\(consumed) bytes")
        let calls = drain(budgeted)
        check(calls > 10, "the stream takes many bounded calls", "\(calls)")
        budgeted.finish()
        eq(budgeted.segmentDurations(), reference.segmentDurations(), "same segments")
        let (a, b) = (files(in: referenceOutput), files(in: budgetedOutput))
        check(!a.isEmpty && a == b, "every output file is byte-identical to a run without budget stops",
              "\(a.count) vs \(b.count) files")
    }

    // MARK: A single keyframe

    func testAStreamWithASingleKeyframeStopsInsteadOfFillingTheMemory() {
        var stream = SyntheticMatroska()
        stream.clusterCount = 100                           // 100 s
        stream.isKeyframe = { index, _ in index == 0 }      // infinite GOP
        guard let (session, _) = session(stream) else { return }
        let size = Int64(stream.data().count)
        session.pumpInputBudget = 32_000

        // Before: this one call read the whole file into memory (0 segment).
        let first = session.pump(maxNewSegments: 2)
        check(first == 0 && session.stoppedAtInputBudget, "the first call returns at its input budget")
        check(session.consumedInputOffset < size / 4, "…with a fraction of the file read",
              "\(session.consumedInputOffset) of \(size) bytes")
        check(session.writeFailure == nil, "not judged yet: 60 s of video may still bring a keyframe")

        drain(session)
        eq(session.writeFailure, MKVToHLSRemuxSession.uncuttableVideoReason,
           "no keyframe to end segment 0 on after 60 s: the session stops (the player goes to VLC)")
        let consumed = session.consumedInputOffset
        check(consumed > size / 2 && consumed < size * 7 / 10, "stopped about 60 s into the 100 s file, not at its end",
              "\(consumed) of \(size) bytes")
        eq(session.pump(maxNewSegments: 2), 0, "nothing more is pumped")
        eq(session.consumedInputOffset, consumed, "…nor read")
        session.finish()
        eq(session.progress.segmentsWritten, 0, "finish() does not write the film as one segment")
        check(session.progress.finished, "the session is over")
    }

    func testKeyframesThatStopAfterPlaybackStarted() {
        var stream = SyntheticMatroska()
        stream.clusterCount = 200
        stream.isKeyframe = { index, perCluster in index % perCluster == 0 && index < 20 * perCluster }   // none after 20 s
        guard let (session, _) = session(stream) else { return }
        let size = Int64(stream.data().count)
        drain(session)
        eq(session.progress.segmentsWritten, 3, "the 18 s that can be cut are published (6 s segments)")
        eq(session.writeFailure, MKVToHLSRemuxSession.uncuttableVideoReason,
           "then the video can't be cut any more: the session stops (VLC at the playhead)")
        // Segment 3 starts at 18 s; a stream that was cut before gets 120 s.
        let consumed = session.consumedInputOffset
        check(consumed > size * 13 / 20 && consumed < size * 15 / 20, "stopped about 120 s after the last cut (≈ 139 s of 200 s)",
              "\(consumed) of \(size) bytes")
    }

    func testTheWaitingVideoIsBoundedInBytesToo() {
        var stream = SyntheticMatroska()
        stream.clusterCount = 50
        stream.videoFrameBytes = 2000                       // 50 KB a second
        stream.isKeyframe = { index, _ in index == 0 }
        guard let (session, _) = session(stream) else { return }
        let size = Int64(stream.data().count)
        session.maxPendingVideoBytes = 500_000              // 10 s of this video
        drain(session)
        eq(session.writeFailure, MKVToHLSRemuxSession.uncuttableVideoReason, "stopped by the bytes waiting, well before 60 s")
        check(session.consumedInputOffset < size / 3, "about 10 s of the 50 s file read", "\(session.consumedInputOffset) of \(size) bytes")
    }

    // MARK: Timestamps no movie has

    func testAClusterWithAnAbsurdTimestampIsSkippedWithoutATrap() {
        // 2^57 trapped in `units` ("Double value cannot be converted to Int64"), 2^41 … 2^56 in
        // the segmenter's products; 2^40 did not trap but cut the film short (120 s of 300).
        for exponent in [40, 41, 48, 57, 62, 63] {
            var stream = SyntheticMatroska()
            stream.clusterTimestamps = [14: exponent == 63 ? UInt64.max : UInt64(1) << UInt64(exponent)]
            guard let (session, _) = session(stream) else { return }
            drain(session)
            session.finish()
            check(session.writeFailure == nil, "2^\(exponent): the session stays healthy", session.writeFailure ?? "")
            eq(session.implausibleClusters, 1, "2^\(exponent): that one cluster is skipped")
            eq(session.segmentDurations().count, 5, "2^\(exponent): the film keeps its five segments")
            check(abs(session.progress.mediaSeconds - 30) < 0.1, "2^\(exponent): and its 30 s — the frame before the lost second spans it",
                  "\(session.progress.mediaSeconds)")
        }
    }

    func testASkippedClusterAtASegmentBoundary() {
        // The cluster that held a segment's keyframe: the cut moves to the next keyframe, the
        // second lost is a hole between two segments (as for any skipped damage).
        var stream = SyntheticMatroska()
        stream.clusterTimestamps = [12: 1 << 57]
        guard let (session, _) = session(stream) else { return }
        drain(session)
        session.finish()
        check(session.writeFailure == nil && session.implausibleClusters == 1, "skipped, the session healthy")
        eq(session.segmentDurations().count, 5, "five segments still")
        check(abs(session.progress.mediaSeconds - 29) < 0.1, "29 s of media around a 1 s hole", "\(session.progress.mediaSeconds)")
    }

    func testAnAbsurdTimestampScaleIsTakenAsTheDefault() {
        var stream = SyntheticMatroska()
        guard let (reference, _) = session(stream) else { return }
        drain(reference)
        reference.finish()
        // The same stream (1 ms ticks) whose header says 2^40 ns (18 min) per tick: every
        // timestamp would be astronomical.
        stream.declaredTimestampScale = 1 << 40
        guard let (session, _) = session(stream) else { return }
        drain(session)
        session.finish()
        eq(session.segmentDurations().count, reference.segmentDurations().count,
           "a TimestampScale above 1 s is damage: the default (1 ms) applies and the stream is cut as usual")
        eq(session.implausibleClusters, 0, "no cluster is thrown away for it")
    }

    func testUnitsNeverTraps() {
        let units = MKVToHLSRemuxSession.units
        eq(units(1000, 0, 1_000_000, 90_000), 90_000, "1 s of 1 ms ticks at 90 kHz")
        eq(units(-40, 40, 1_000_000, 90_000), 0, "the shift is added")
        eq(units(1001, 0, 1_000_000, 48_000), 48_048, "rounded to the nearest unit")
        let limit = MKVToHLSRemuxSession.maxUnits
        eq(units(1 << 57, 0, 1_000_000, 90_000), limit, "2^57 ticks: clamped (it trapped)")
        eq(units(Int64.max, Int64.max, 1_000_000, 90_000), limit, "the sum saturates")
        eq(units(Int64.min, Int64.min, 1_000_000, 90_000), -limit, "…both ways")
        eq(units(1 << 40, 0, UInt64.max, 90_000), limit, "an absurd scale: clamped")
        // What the timeline does with such values stays within Int64.
        let (product, overflow) = limit.multipliedReportingOverflow(by: Int64(MKVToHLSRemuxSession.maxAudioTimescale))
        check(!overflow && product > 0, "a clamped time × the highest audio timescale does not overflow")
    }

    func testClusterTimestampPlausibility() {
        let plausible = MatroskaDemuxer.isPlausibleClusterTimestamp
        check(plausible(0, 1_000_000, nil) && plausible(7_200_000, 1_000_000, 7_195_000), "a 2 h movie's clusters")
        check(plausible(72_000_000, 1_000_000, nil), "a first cluster 20 h in (a stream copied with its timestamps)")
        check(!plausible(1 << 40, 1_000_000, nil), "2^40 ms (34 years): damage")
        check(!plausible(Int64.max, 1_000_000, 0), "Int64.max: damage")
        check(plausible(600_000_000, 1_000_000, nil) && !plausible(605_000_000, 1_000_000, nil), "7 days is the bound")
        check(!plausible(7_200_000 + 6 * 3_600_000 + 1, 1_000_000, 7_200_000), "more than 6 h after the cluster before it: damage")
        check(plausible(7_200_000 + 6 * 3_600_000, 1_000_000, 7_200_000), "6 h after it: taken")
        check(plausible(1000, 1_000_000, 7_200_000), "a step backward is not this rule's business")
        check(plausible(3_600_000_000, 1000, nil) && !plausible(3_600_000_000, 1_000_000, nil),
              "judged in seconds, whatever the scale (1 h of 1 µs ticks; 41 days of 1 ms ticks)")
    }
}
