//
//  RemuxJumpBookkeepingTests.swift
//  PopcornTimeTests
//
//  What the session publishes around a jump, which the playback engine steers by: the cursor
//  and the high-water mark, the holes and their entries (the planned duration, the real offset
//  of each one's Cluster, 0 byte), the reader's position (the only figure that goes back), the
//  input-complete flag a jump takes down, the target of a player position, segments taken back
//  — and that a session which never jumps publishes exactly what it did.
//

import XCTest
import Foundation

final class RemuxJumpBookkeepingTests: RemuxSessionTestCase {

    private typealias Session = MKVToHLSRemuxSession

    /// Two segments written and the list frozen from the plan.
    private func started(_ stream: SyntheticMatroska, file: StaticString = #filePath, line: Int = #line) -> Opened? {
        guard let opened = open(stream, file: file, line: line) else { return nil }
        eq(produce(opened.session, 2), 2, "two segments to start with", file: file, line: line)
        check(opened.session.freezePlaylistFromPlan(), "the list is frozen from the plan", file: file, line: line)
        return opened
    }

    /// Bytes of the media segments in the output folder (the init segments are not counted).
    private func bytesOnDisk(_ opened: Opened) -> Int64 {
        files(in: opened.output).filter { $0.key.contains("seg") }.reduce(0) { $0 + Int64($1.value.count) }
    }

    /// The figures that only grow, and those that must agree with the disk.
    private func expectConsistent(_ opened: Opened, after previous: Session.Progress, _ step: String,
                                  file: StaticString = #filePath, line: Int = #line) {
        let session = opened.session
        let progress = session.progress
        check(progress.segmentsWritten >= previous.segmentsWritten && progress.mediaSeconds >= previous.mediaSeconds,
              "\(step): the high-water mark and the media length only grow", "\(previous) → \(progress)", file: file, line: line)
        eq(session.segmentDurations().count, progress.segmentsWritten, "\(step): one duration per index up to the mark", file: file, line: line)
        eq(session.segmentSourceOffsets().count, progress.segmentsWritten, "\(step): one offset", file: file, line: line)
        eq(session.segmentBytes().count, progress.segmentsWritten, "\(step): one size", file: file, line: line)
        let offsets = session.segmentSourceOffsets()
        check(zip(offsets, offsets.dropFirst()).allSatisfy { $0 <= $1 }, "\(step): the source offsets never decrease", file: file, line: line)
        eq(session.segmentBytes().reduce(0, +), bytesOnDisk(opened), "\(step): the sizes add up to what is on disk", file: file, line: line)
        check(session.bytesWritten >= bytesOnDisk(opened), "\(step): bytesWritten counts everything written", file: file, line: line)
        let sizes = session.segmentBytes()
        let missing = session.missingSegments()
        check(sizes.indices.allSatisfy { (sizes[$0] == 0) == missing.contains($0) }, "\(step): a hole is 0 byte, a segment is not",
              file: file, line: line)
        let onDisk = files(in: opened.output)
        check(sizes.indices.allSatisfy { onDisk["vseg\($0).m4s"] == nil ? missing.contains($0) : !missing.contains($0) },
              "\(step): the holes are the indexes without a file", file: file, line: line)
    }

    // MARK: Without a jump

    func testWithoutAJumpTheCursorIsTheSegmentCount() {
        guard let opened = open(RemuxTestStreams.named("h264-aac-cues-front")) else { return }
        let session = opened.session
        var previous = session.progress
        var reader: Int64 = 0
        var idle = 0
        while idle < 3 {
            let written = session.pump(maxNewSegments: 2)
            idle = written == 0 ? idle + 1 : 0
            eq(session.nextSegmentIndex, session.progress.segmentsWritten, "the cursor is the count")
            eq(session.bytesWritten, bytesOnDisk(opened), "bytesWritten is what is on disk")
            check(session.missingSegments().isEmpty && !session.hasJumped && !session.isTailWritten, "no hole, no jump, no end yet")
            check(session.consumedInputOffset >= reader, "the reader only moves forward")
            reader = session.consumedInputOffset
            expectConsistent(opened, after: previous, "in file order")
            previous = session.progress
            if session.progress.segmentsWritten == 2 { _ = session.mediaPlaylist(named: "video.m3u8") }
        }
        session.finish()
        check(session.isTailWritten && session.progress.finished, "finish() writes the end")
        eq(session.nextSegmentIndex, 20, "the cursor is past the last segment")
        check(session.missingSegments().isEmpty && !session.hasJumped, "still no hole")
        eq(session.jumpFailure, nil, "no jump, no failure")
        eq(session.indexedKeyframeCount, 120, "the index's cue points are counted")
    }

    func testTheCapabilityIsKnownWhenThePlanIs() {
        // Complete file: pending until segment 0 is cut, then available — before the second
        // segment the playback engine waits for.
        guard let files = temporaryInput(RemuxTestStreams.named("hevc-eac3-cues-front").data()),
              let session = try? MKVToHLSRemuxSession(inputFile: files.input, outputDirectory: files.output) else {
            return check(false, "the session opens")
        }
        eq(session.jumpCapability, .pending, "before prepare")
        session.markInputComplete()
        eq(session.prepare(), .ready, "prepared")
        eq(session.jumpCapability, .pending, "prepared: the plan needs segment 0")
        eq(session.pump(maxNewSegments: 1), 1, "segment 0")
        eq(session.jumpCapability, .available, "segment 0 published: known")
        eq(session.nextSegmentIndex, 1, "with one segment written")

        // Cues at the back, downloaded after playback started but before any playlist: pending
        // until they arrive.
        let stream = RemuxTestStreams.named("h264-aac-cues-back-sized-segment")
        let layout = stream.layout()
        guard let late = open(stream, complete: false, content: Self.holed(layout.data, keeping: [0..<layout.clusterOffsets[20]])) else { return }
        eq(produce(late.session, 2), 2, "two segments without the index")
        eq(late.session.jumpCapability, .pending, "the index may still come")
        eq(late.session.indexedKeyframeCount, 0, "not read yet")
        fill(late.input, from: layout.data, (layout.cuesOffset ?? 0)..<layout.data.count)
        _ = late.session.pump(maxNewSegments: 1)
        eq(late.session.jumpCapability, .available, "the index arrived before the list was frozen")
        check(late.session.freezePlaylistFromPlan() && late.session.jumpTarget(forSegment: 14) != nil, "and can be jumped by")
    }

    // MARK: A jump forward

    func testAJumpForwardPublishesWhatItSkipsAsHoles() {
        for (name, leadIn, expectsLeadIn) in [("h264-aac-cues-front", Session.JumpLeadIn.automatic, true),
                                              ("hevc-eac3-cues-front", .automatic, false),
                                              ("hevc-eac3-cues-front", .always, true)] {
            guard let opened = started(RemuxTestStreams.named(name)) else { return }
            let session = opened.session
            let clusters = opened.layout.clusterOffsets.map { Int64($0) }
            let list = session.playerTimelineDurations() ?? []
            let before = session.progress
            let readerBefore = session.consumedInputOffset
            let announced = session.jumpTarget(forSegment: 14)
            guard let target = session.jump(toSegment: 14, leadIn: leadIn) else { return check(false, "\(name): the jump is made") }

            // Where it reads from.
            eq(target.segment, 14, "\(name): the segment asked for")
            check(abs(target.playerStartSeconds - 84) < 0.01, "\(name): its start on the player's timeline", "\(target.playerStartSeconds)")
            eq(target.keyframeOffset, clusters[84], "\(name): the Cluster of its keyframe (84 s)")
            eq(target.readOffset, expectsLeadIn ? clusters[83] : clusters[84],
               "\(name): read from " + (expectsLeadIn ? "the indexed Cluster before it" : "that Cluster"))
            if leadIn == .automatic { eq(announced, target, "\(name): what jumpTarget announced") }
            eq(session.consumedInputOffset, target.readOffset, "\(name): the reader is where the pass reads from")
            check(session.consumedInputOffset > readerBefore, "\(name): further than it was")

            // What is published.
            check(session.hasJumped, "\(name): a jump was made")
            eq(session.nextSegmentIndex, 14, "\(name): the cursor is the target")
            eq(session.progress.segmentsWritten, 14, "\(name): the high-water mark is the target: every index below it is listed")
            eq(session.missingSegments(), IndexSet(integersIn: 2..<14), "\(name): the skipped ones as holes")
            check(abs(session.progress.mediaSeconds - target.playerStartSeconds) < 0.05, "\(name): media up to the target's start",
                  "\(session.progress.mediaSeconds)")
            eq(Array(session.segmentDurations()[2..<14]), Array(list[2..<14]), "\(name): a hole has its planned duration")
            eq(Array(session.segmentSourceOffsets()[2..<14]), (2..<14).map { clusters[6 * $0] },
               "\(name): and the offset of ITS OWN Cluster, not the target's")
            eq(Array(session.segmentBytes()[2..<14]), Array(repeating: 0, count: 12), "\(name): and 0 byte")
            expectConsistent(opened, after: before, "\(name), after the jump")
            check(!session.progress.finished && !session.isTailWritten, "\(name): not finished")
            eq(session.playerTimelineDurations(), list, "\(name): the frozen list is untouched")

            // The first segment written lands at the cursor.
            session.setInputComplete(true)
            let afterJump = session.progress
            eq(produce(session, 1), 1, "\(name): segment 14")
            eq(session.nextSegmentIndex, 15, "\(name): the cursor moves on")
            eq(session.progress.segmentsWritten, 15, "\(name): and the mark with it")
            eq(session.segmentSourceOffsets()[14], clusters[84], "\(name): its offset is its keyframe's Cluster")
            expectConsistent(opened, after: afterJump, "\(name), after one segment")
        }
    }

    // MARK: A jump back

    func testAJumpBackMovesTheReaderBackAndNothingElse() {
        guard let opened = started(RemuxTestStreams.named("hevc-eac3-cues-front")) else { return }
        let session = opened.session
        let clusters = opened.layout.clusterOffsets.map { Int64($0) }
        check(session.jump(toSegment: 14) != nil, "ahead")
        session.setInputComplete(true)
        eq(produce(session, 3), 3, "three segments there")
        let before = session.progress
        let durations = session.segmentDurations(), offsets = session.segmentSourceOffsets()
        let reader = session.consumedInputOffset

        guard let back = session.jump(toSegment: 5) else { return check(false, "back into a hole") }
        eq(back.readOffset, clusters[30], "read from the Cluster of 30 s")
        eq(session.consumedInputOffset, clusters[30], "the reader went back")
        check(session.consumedInputOffset < reader, "below where it was")
        eq(session.nextSegmentIndex, 5, "the cursor is the hole")
        eq(session.progress, before, "the mark and the media length did not move")
        eq(session.segmentDurations(), durations, "nor the entries")
        eq(session.segmentSourceOffsets(), offsets, "nor the offsets")
        eq(session.missingSegments(), IndexSet(integersIn: 2..<14), "the holes are the same")
        expectConsistent(opened, after: before, "after the jump back")

        // Filling: the hole's entry becomes the real one, the mark stays.
        session.setInputComplete(true)
        eq(produce(session, 2), 2, "segments 5 and 6")
        eq(session.nextSegmentIndex, 7, "the cursor follows")
        eq(session.progress, before, "the mark and the media length still did not move")
        eq(session.missingSegments(), IndexSet([2, 3, 4] + Array(7..<14)), "two holes fewer")
        eq(session.segmentSourceOffsets(), offsets, "the offsets a hole carried were the real ones")
        check(session.consumedInputOffset > clusters[30] && session.consumedInputOffset < reader, "the reader moves forward from there")
        expectConsistent(opened, after: before, "after filling two holes")
    }

    func testTheCutWaitsForTheAudioAfterAJumpBack() {
        // The highest video time ever demuxed must not survive a jump back: 168 s behind it,
        // the cutter took the video for hopelessly ahead of the audio — it stopped the session
        // ("can't be cut") instead of writing the first hole.
        let stream = RemuxTestStreams.make { $0.cues = .front; $0.clusterCount = 240 }
        guard let reference = open(stream), let opened = started(stream) else { return }
        convertInOrder(reference)
        let session = opened.session
        check(session.jump(toSegment: 30) != nil, "ahead to 180 s")
        session.setInputComplete(true)
        eq(produce(session, 2), 2, "two segments there")
        check(session.jump(toSegment: 2) != nil, "back to 12 s")
        session.setInputComplete(true)
        eq(produce(session, 3), 3, "the holes are written")
        eq(session.writeFailure, nil, "the session is not stopped")
        let (expected, got) = (files(in: reference.output), files(in: opened.output))
        check((2..<5).allSatisfy { got["vseg\($0).m4s"] == expected["vseg\($0).m4s"] && got["a0seg\($0).m4s"] == expected["a0seg\($0).m4s"] },
              "with all their audio")
    }

    // MARK: Input complete

    func testAJumpTakesTheInputCompleteFlagDown() {
        // The caller said the input was complete for the pass it had; the pass now reads a part
        // of the file that is not there. Zeros must be "to come" again, not what the file holds.
        let stream = RemuxTestStreams.named("hevc-eac3-cues-front")
        let layout = stream.layout()
        let partial = Self.holed(layout.data, keeping: [0..<layout.clusterOffsets[14]])
        guard let opened = open(stream, complete: true, content: partial) else { return }
        let session = opened.session
        eq(produce(session, 2), 2, "the head")
        check(session.freezePlaylistFromPlan(), "frozen from the plan")
        check(session.jump(toSegment: 14) != nil, "ahead, into what is not downloaded")
        eq(session.pump(maxNewSegments: 2), 0, "nothing yet")
        eq(session.jumpFailure, nil, "the zeros are waited for: the jump took the flag down")
        eq(session.probeJump(toSegment: 14), .notYet, "a probe says the same")
        // Had the flag stayed up: zeros are the content, and no Cluster.
        session.setInputComplete(true)
        eq(session.probeJump(toSegment: 14), .notACluster, "complete, the same zeros are not a Cluster")
        eq(session.pump(maxNewSegments: 2), 0, "nothing")
        check(session.jumpFailure != nil, "and the jump fails", session.jumpFailure ?? "nil")
    }

    // MARK: Targets

    func testTheTargetOfAPlayerPosition() {
        guard let opened = started(RemuxTestStreams.named("sparse-cues-mid-cluster-keyframes")) else { return }
        let session = opened.session
        let list = session.playerTimelineDurations() ?? []
        var starts: [Double] = [0]
        for duration in list { starts.append((starts.last ?? 0) + duration) }
        func segment(_ seconds: Double) -> Int? { session.jumpTarget(forPlayerSeconds: seconds)?.segment }

        eq(segment(starts[9] + 1), 9, "inside segment 9")
        eq(segment(starts[9]), 9, "at its start")
        eq(segment(starts[9] - 0.04), 9, "40 ms before its start: a player that seeked there reports a hair early")
        eq(segment(starts[9] - 0.06), 8, "60 ms before: the segment before")
        eq(segment(starts[10] - 0.06), 9, "to the end of segment 9")
        eq(session.jumpTarget(forPlayerSeconds: starts[9] + 1), session.jumpTarget(forSegment: 9), "the same target as by index")
        check(abs((session.jumpTarget(forSegment: 9)?.playerStartSeconds ?? 0) - starts[9]) < 1e-9, "whose start is the list's")
        eq(segment(starts[1] + 1), nil, "segment 1 is not a target")
        eq(segment(0), nil, "nor segment 0")
        eq(segment(-5), nil, "nor a negative position")
        eq(segment(starts[2] - 0.04), 2, "segment 2 is the first one")
        eq(segment(starts[20] + 100), 19, "past the end: the last real segment")
        eq(segment(.nan), nil, "not a number: none")
        eq(segment(.infinity), nil, "nor infinity")
        // The keyframes of this stream are inside their clusters, one in two indexed, and the
        // audio is laced: the pass reads from the indexed Cluster before the keyframe's.
        guard let target = session.jumpTarget(forSegment: 9) else { return check(false, "a target") }
        let clusters = opened.layout.clusterOffsets.map { Int64($0) }
        check(clusters.contains(target.keyframeOffset) && clusters.contains(target.readOffset), "both offsets are Clusters")
        check(target.readOffset < target.keyframeOffset, "the lead-in is before the keyframe's Cluster")
        eq(session.probeJump(toSegment: 9), .cluster, "and is there")
    }

    func testTheLeadInIsNotReadFromFurtherThanItsLimit() {
        // A sparse index: the indexed Cluster before the keyframe's is 3 s of file away.
        let stream = RemuxTestStreams.make { $0.cues = .front; $0.cueStride = 3 }
        guard let near = started(stream), let far = open(stream, configure: { $0.jumpLeadInLimit = 10_000 }) else { return }
        produce(far.session, 2)
        check(far.session.freezePlaylistFromPlan(), "frozen from the plan")
        let clusters = near.layout.clusterOffsets.map { Int64($0) }
        eq(near.session.jumpTarget(forSegment: 14)?.readOffset, clusters[81], "within the limit: read from the indexed Cluster before (81 s)")
        eq(far.session.jumpTarget(forSegment: 14)?.readOffset, clusters[84], "beyond it: read from the keyframe's own Cluster")
        eq(far.session.jump(toSegment: 14, leadIn: .always)?.readOffset, clusters[84], "even when the lead-in is asked for")
    }

    // MARK: Freezing

    func testFreezingTheListFromThePlan() {
        guard let opened = open(RemuxTestStreams.named("h264-aac-cues-front")) else { return }
        let session = opened.session
        check(!session.freezePlaylistFromPlan() && session.playerTimelineDurations() == nil, "nothing to freeze before segment 0")
        produce(session, 1)
        check(session.freezePlaylistFromPlan(), "frozen once a segment and the plan exist")
        eq(session.playerTimelineDurations()?.count, 20, "on the planned list")
        check(session.isPlaylistFromKeyframeIndex, "which is the keyframe index's")
        let list = session.playerTimelineDurations()
        check(session.freezePlaylistFromPlan(), "again: still true")
        _ = session.mediaPlaylist(named: "video.m3u8")
        eq(session.playerTimelineDurations(), list, "and what the player then fetches is that list")
    }

    // MARK: Taking segments back

    func testSegmentsTakenBackAreHolesAgain() {
        let stream = RemuxTestStreams.named("hevc-eac3-cues-front")
        guard let reference = open(stream), let opened = started(stream) else { return }
        convertInOrder(reference)
        let expected = files(in: reference.output)
        let session = opened.session
        check(session.jump(toSegment: 10) != nil, "ahead")
        session.setInputComplete(true)
        eq(produce(session, 4), 4, "segments 10 to 13")
        let before = session.progress
        let durations = session.segmentDurations(), offsets = session.segmentSourceOffsets()
        let sizes = session.segmentBytes()
        let written = session.bytesWritten

        // 0 and 1 always exist, 5 is already a hole, 14 and 99 are past the mark.
        let marked = session.markMissing(IndexSet([0, 1, 5, 10, 11, 13, 14, 99]))
        eq(marked, IndexSet([10, 11, 13]), "the written ones, from 2 up, below the mark")
        for index in marked {
            for name in Self.names(ofSegment: index, in: files(in: opened.output)) {
                try? FileManager.default.removeItem(at: opened.output.appendingPathComponent(name))
            }
        }
        eq(session.missingSegments(), IndexSet(Array(2..<10) + [10, 11, 13]), "they are holes again")
        eq(session.bytesWritten, written, "bytesWritten keeps what was written (it only grows)")
        eq(Array(session.segmentBytes()[10..<14]), [0, 0, sizes[12], 0], "their sizes are 0")
        eq(session.progress, before, "the mark does not come down")
        eq(session.segmentDurations(), durations, "the entries keep their durations")
        eq(session.segmentSourceOffsets(), offsets, "and offsets")
        eq(session.nextSegmentIndex, 14, "the cursor is where it was")
        expectConsistent(opened, after: before, "after taking three segments back")
        check(session.markMissing(IndexSet([10, 11])).isEmpty, "taking a hole back again changes nothing")

        // They can be written anew, and are the same segments.
        check(session.jump(toSegment: 10) != nil, "back to the first one")
        session.setInputComplete(true)
        eq(produce(session, 5), 2, "10 and 11; 12 exists: the pass is parked")
        check(session.jump(toSegment: 13) != nil, "then 13")
        session.setInputComplete(true)
        eq(produce(session, 2), 2, "13, and 14 beyond it: the mark is not a stop")
        let got = files(in: opened.output)
        check((10..<15).allSatisfy { index in Self.names(ofSegment: index, in: expected).allSatisfy { got[$0] == expected[$0] } },
              "byte-identical to a conversion in file order")
        eq(session.bytesWritten, written + sizes[10] + sizes[11] + sizes[13] + session.segmentBytes()[14], "written twice, counted twice")
        eq(Array(session.segmentBytes()[10..<14]), Array(sizes[10..<14]), "the sizes are back")
        expectConsistent(opened, after: before, "after writing them again")

        // Once the end is written, the last real segment and its tail are never taken back.
        drain(session)
        session.finish()
        check(session.isTailWritten, "the end is written")
        eq(session.markMissing(IndexSet([18, 19, 20])), IndexSet([18]), "18 can be written again; 19 is finish()'s")
        try? FileManager.default.removeItem(at: opened.output.appendingPathComponent("vseg18.m4s"))
        try? FileManager.default.removeItem(at: opened.output.appendingPathComponent("a0seg18.m4s"))
        check(session.jump(toSegment: 18) != nil, "a jump after the end")
        session.setInputComplete(true)
        eq(session.nextSegmentIndex, 18, "the cursor is the hole")
        eq(produce(session, 3), 1, "segment 18, then stopped before the end")
        eq(session.nextSegmentIndex, session.progress.segmentsWritten, "at rest once the end exists: the cursor reads the mark")
        eq(session.missingSegments(), IndexSet(integersIn: 2..<10), "at rest is not complete: the holes of the first jump remain")
        check(Self.names(ofSegment: 18, in: expected).allSatisfy { files(in: opened.output)[$0] == expected[$0] }, "the same segment 18")
    }
}
