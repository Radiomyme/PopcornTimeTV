//
//  RemuxJumpRefusalTests.swift
//  PopcornTimeTests
//
//  When the session does not jump. Either it says so beforehand — `jumpCapability` is
//  `.unavailable` with the reason (no keyframe index, no Duration, playlists frozen on
//  estimates, a transcoded track…) and `jump` returns nil having changed NOTHING — or the
//  index turns out to be wrong once the pass is there: `jumpFailure` is set, nothing is written
//  for the segment jumped to, and the session produces nothing more (the caller plays that
//  position another way).
//

import XCTest
import Foundation

final class RemuxJumpRefusalTests: RemuxSessionTestCase {

    private typealias Session = MKVToHLSRemuxSession

    /// Everything a caller can see of a session.
    private struct Visible: Equatable {
        var progress: Session.Progress
        var durations: [Double]
        var offsets: [Int64]
        var bytes: [Int64]
        var missing: IndexSet
        var next: Int
        var consumed: Int64
        var hasJumped: Bool
        var capability: Session.JumpCapability
        var list: [Double]?
        var files: [String]
    }

    private func visible(_ opened: Opened) -> Visible {
        let session = opened.session
        return Visible(progress: session.progress, durations: session.segmentDurations(), offsets: session.segmentSourceOffsets(),
                       bytes: session.segmentBytes(), missing: session.missingSegments(), next: session.nextSegmentIndex,
                       consumed: session.consumedInputOffset, hasJumped: session.hasJumped, capability: session.jumpCapability,
                       list: session.playerTimelineDurations(), files: files(in: opened.output).keys.sorted())
    }

    /// `jump` to each of `targets` returns nil and leaves the session as it was.
    private func expectRefused(_ opened: Opened, _ targets: [Int], _ why: String, file: StaticString = #filePath, line: Int = #line) {
        let before = visible(opened)
        for target in targets {
            for leadIn in [Session.JumpLeadIn.automatic, .always] {
                eq(opened.session.jump(toSegment: target, leadIn: leadIn), nil, "\(why): no jump to segment \(target)", file: file, line: line)
            }
        }
        eq(visible(opened), before, "\(why): nothing changed", file: file, line: line)
    }

    private func unavailable(_ session: Session, containing text: String, _ label: String, file: StaticString = #filePath, line: Int = #line) {
        guard case .unavailable(let reason) = session.jumpCapability else {
            return check(false, "\(label): jumps are unavailable", "\(session.jumpCapability)", file: file, line: line)
        }
        check(reason.contains(text), "\(label): the reason says why", reason, file: file, line: line)
    }

    /// Two segments written and the list frozen from the plan.
    private func started(_ stream: SyntheticMatroska, configure: (Session) -> Void = { _ in },
                         file: StaticString = #filePath, line: Int = #line) -> Opened? {
        guard let opened = open(stream, configure: configure, file: file, line: line) else { return nil }
        eq(produce(opened.session, 2), 2, "two segments to start with", file: file, line: line)
        check(opened.session.freezePlaylistFromPlan(), "the list is frozen from the plan", file: file, line: line)
        return opened
    }

    // MARK: Said beforehand

    func testWithoutAKeyframeIndex() {
        guard let opened = open(RemuxTestStreams.named("h264-aac-no-index")) else { return }
        let session = opened.session
        unavailable(session, containing: "no keyframe index", "no Cues, known at prepare")
        produce(session, 2)
        check(!session.freezePlaylistFromPlan(), "there is no plan to freeze the list from")
        eq(session.playerTimelineDurations(), nil, "and asking did not freeze it on estimates")
        eq(session.jumpTarget(forSegment: 5), nil, "no target")
        eq(session.jumpTarget(forPlayerSeconds: 40), nil, "at no position")
        eq(session.probeJump(toSegment: 5), .notACluster, "nothing to probe")
        expectRefused(opened, [3, 5, 9], "no index")
        check(session.markMissing(IndexSet([0, 1])).isEmpty, "nothing can be taken back: nothing could write it again")
        drain(session)
        session.finish()
        eq(session.progress.segmentsWritten, 10, "the film is converted in order as ever")
    }

    func testCuesInMuxOrderStillJump() {
        // libavformat before 5.0 writes cue points in mux order: a subtitle's, timed between a
        // keyframe's DTS and its PTS, after that keyframe's. The video index is right.
        let stream = RemuxTestStreams.make {
            $0.clusterCount = 60
            $0.cues = .front
            $0.hasTextSubtitles = true
            $0.subtitleCuesBefore = [12: 40]
        }
        guard let opened = started(stream) else { return }
        eq(opened.session.jumpCapability, .available, "the index is not refused for another track's cue point")
        check(opened.session.jumpTarget(forSegment: 5) != nil, "a target")
    }

    func testWithoutADuration() {
        guard let opened = open(RemuxTestStreams.make { $0.cues = .front; $0.hasDuration = false }) else { return }
        unavailable(opened.session, containing: "no Duration", "EVENT playlists, known at prepare")
        produce(opened.session, 2)
        check(!opened.session.freezePlaylistFromPlan(), "nothing to freeze")
        expectRefused(opened, [5], "no Duration")
    }

    func testPlaylistsFrozenOnEstimatesBeforeTheIndexArrived() {
        // Cues at the back of a file whose tail is not downloaded when the player asks for
        // its playlists.
        let stream = RemuxTestStreams.named("h264-aac-cues-back-sized-segment")
        let layout = stream.layout()
        let partial = Self.holed(layout.data, keeping: [0..<layout.clusterOffsets[14]])
        guard let opened = open(stream, complete: false, content: partial) else { return }
        let session = opened.session
        eq(produce(session, 2), 2, "two segments from the head")
        eq(session.jumpCapability, .pending, "the index may still come")
        check(!session.freezePlaylistFromPlan(), "no planned list yet")
        eq(session.playerTimelineDurations(), nil, "…and nothing frozen by asking")
        _ = session.mediaPlaylist(named: "video.m3u8")
        check(session.playerTimelineDurations() != nil && !session.isPlaylistFromKeyframeIndex, "the player's request freezes estimates")
        // The tail arrives: too late.
        fill(opened.input, from: layout.data, (layout.cuesOffset ?? 0)..<layout.data.count)
        _ = session.pump(maxNewSegments: 1)
        unavailable(session, containing: "frozen on estimates", "frozen before the index")
        check(!session.freezePlaylistFromPlan(), "frozen on estimates: false")
        expectRefused(opened, [5, 14], "estimated list")
    }

    func testATranscodedAudioTrack() {
        guard let opened = open(RemuxTestStreams.make { $0.cues = .front; $0.audioCodec = .pcm; $0.clusterCount = 36 }) else { return }
        let session = opened.session
        eq(session.audioRenditions.first?.codecs, "fLaC", "PCM is transcoded to FLAC")
        produce(session, 2)
        unavailable(session, containing: "transcoded", "PCM")
        check(session.freezePlaylistFromPlan() && session.isPlaylistFromKeyframeIndex, "the plan is still followed in file order")
        eq(session.jumpTarget(forSegment: 4), nil, "but offers no target")
        expectRefused(opened, [3, 5], "a transcoded track")
    }

    func testAnIndexWhoseOffsetsAreNotInFileOrder() {
        // The cue of the keyframe at 84 s points before the one at 78 s: not an index to jump
        // by. Cutting does not read the offsets: the film in file order is unchanged.
        let clean = RemuxTestStreams.named("hevc-eac3-cues-front")
        let offsets = clean.layout().clusterOffsets
        var damaged = clean
        damaged.cueOffsetErrors = [84: offsets[3] - offsets[84]]
        guard let reference = open(clean), let opened = started(damaged) else { return }
        unavailable(opened.session, containing: "not in file order", "a disordered index")
        expectRefused(opened, [5, 14, 15], "a disordered index")
        convertInOrder(reference)
        drain(opened.session)
        opened.session.finish()
        let (expected, got) = (files(in: reference.output), files(in: opened.output))
        check(!expected.isEmpty && expected == got, "the conversion in file order is byte-identical to the clean stream's")
    }

    // MARK: Refused for now, or for that target

    func testBeforeTheListIsFrozenFromThePlan() {
        guard let opened = open(RemuxTestStreams.named("h264-aac-cues-front")) else { return }
        let session = opened.session
        eq(session.jumpCapability, .pending, "after prepare: the plan is made once segment 0 is cut")
        expectRefused(opened, [5], "nothing written yet")
        check(!session.freezePlaylistFromPlan(), "no planned list before segment 0")
        eq(produce(session, 1), 1, "segment 0")
        eq(session.jumpCapability, .available, "known as soon as segment 0 is published")
        eq(session.jumpTarget(forSegment: 5), nil, "no target while the list is not frozen: its timeline could still move")
        expectRefused(opened, [5], "not frozen")
        check(session.freezePlaylistFromPlan(), "frozen from the plan")
        check(session.jumpTarget(forSegment: 5) != nil, "a target now")
        expectRefused(opened, [5, 14], "segment 1 is not written: the cursor is below 2")
        eq(produce(session, 1), 1, "segment 1")
        check(session.jump(toSegment: 5) != nil, "then the pass can move")
    }

    func testTargetsThatAreNotJumpedTo() {
        let stream = RemuxTestStreams.make {
            $0.cues = .front; $0.clusterCount = 122
            $0.isKeyframe = { index, perCluster in index % perCluster == 0 && index < 120 * perCluster }
        }
        guard let opened = started(stream) else { return }
        let session = opened.session
        eq(session.playerTimelineDurations()?.count, 21, "twenty real segments and a tail unit")
        expectRefused(opened, [-1, 0, 1], "segments 0 and 1 always exist")
        expectRefused(opened, [2], "the cursor itself")
        expectRefused(opened, [20, 21, 1000, Int.max], "past the last real segment (20 is the tail unit)")
        eq(session.jumpTarget(forSegment: 1), nil, "no target below 2")
        eq(session.jumpTarget(forSegment: 20), nil, "nor for the tail unit")

        check(session.jump(toSegment: 10) != nil, "ahead to 10")
        session.setInputComplete(true)
        eq(produce(session, 2), 2, "segments 10 and 11")
        expectRefused(opened, [10, 11], "a segment that exists is never written again")
        expectRefused(opened, [12], "the cursor")
        expectRefused(opened, [0, 1], "still not 0 nor 1")
        check(session.jump(toSegment: 4) != nil, "a hole can be jumped back to")
    }

    func testWhileASegmentWaitsForItsFiles() throws {
        guard let opened = started(RemuxTestStreams.named("h264-aac-cues-front")) else { return }
        let session = opened.session
        // The disk refuses writes (full): the segment cut stays pending.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: opened.output.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opened.output.path) }
        eq(session.pump(maxNewSegments: 1), 0, "segment 2 is cut, not written")
        check(session.isWaitingToWrite, "it waits for its files")
        eq(session.nextSegmentIndex, 2, "the cursor is still the segment not published")
        expectRefused(opened, [5, 14], "a segment is waiting to be written")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opened.output.path)
        eq(session.pump(maxNewSegments: 1), 1, "written once the disk takes it")
        check(session.jump(toSegment: 14) != nil, "then the pass can move")
    }

    func testAfterAFinishBelowTheHighWaterMark() {
        // `finish()` is for the pass at the high-water mark. Called on one that fills a hole,
        // it ends the session without writing the film's end — nor a wrong last segment.
        guard let opened = started(RemuxTestStreams.named("hevc-eac3-cues-front")) else { return }
        let session = opened.session
        check(session.jump(toSegment: 14) != nil, "ahead")
        session.setInputComplete(true)
        eq(produce(session, 1), 1, "segment 14")
        check(session.jump(toSegment: 2) != nil, "back")
        session.setInputComplete(true)
        eq(produce(session, 1), 1, "segment 2")
        let before = files(in: opened.output).keys.sorted()
        session.finish()
        eq(files(in: opened.output).keys.sorted(), before, "nothing is written: no segment 3 holding the rest of the film, no tail")
        check(session.progress.finished && !session.isTailWritten, "finished, without the film's end")
        unavailable(session, containing: "without the film's end", "finished below the mark")
        expectRefused(opened, [3, 15], "finished without its end")
    }

    // MARK: An index that lies

    func testAnOffsetThatIsNotAClusterFailsTheJumpAndWritesNothing() {
        var stream = RemuxTestStreams.named("h264-aac-cues-front")
        stream.cueOffsetErrors = [83: 7, 84: 7]     // the lead-in's Cluster and the keyframe's
        guard let opened = started(stream) else { return }
        let session = opened.session
        eq(session.jumpCapability, .available, "nothing says the index is wrong before going there")
        eq(session.probeJump(toSegment: 14), .notACluster, "a probe does")
        eq(session.probeJump(toSegment: 13), .cluster, "the other targets are fine")
        let before = files(in: opened.output).keys.sorted()
        check(session.jump(toSegment: 14) != nil, "the jump is made")
        session.setInputComplete(true)
        eq(session.pump(maxNewSegments: 2), 0, "nothing is produced")
        check(session.jumpFailure?.contains("not a Cluster") == true, "the failure says what was found", session.jumpFailure ?? "nil")
        eq(session.jumpCapability, .unavailable(session.jumpFailure ?? ""), "jumps are over, for that reason")
        eq(files(in: opened.output).keys.sorted(), before, "no file was written")
        eq(session.pump(maxNewSegments: 2), 0, "nor will be")
        eq(session.jump(toSegment: 5), nil, "no other jump")
        eq(session.jumpTarget(forSegment: 5), nil, "no target")
        check(session.markMissing(IndexSet([0, 1])).isEmpty, "nothing to take back")
        eq(session.writeFailure, nil, "not a write failure")
        session.finish()
        eq(files(in: opened.output).keys.sorted(), before, "finish() writes no end for a film that stopped in a jump")
        check(!session.isTailWritten, "the end is not written")
    }

    func testAClusterThatDoesNotHoldTheKeyframeFailsTheJump() {
        // The cue of the keyframe at 84 s points to the Cluster of 85 s: a real Cluster, whose
        // first keyframe is the wrong one. (E-AC-3: no lead-in to read the right one on the way.)
        let clean = RemuxTestStreams.named("hevc-eac3-cues-front")
        let offsets = clean.layout().clusterOffsets
        var stream = clean
        stream.cueOffsetErrors = [84: offsets[85] - offsets[84]]
        guard let opened = started(stream) else { return }
        let session = opened.session
        eq(session.probeJump(toSegment: 14), .cluster, "a probe sees a Cluster: it can't tell")
        let before = files(in: opened.output).keys.sorted()
        guard let target = session.jump(toSegment: 14) else { return check(false, "the jump is made") }
        eq(target.keyframeOffset, Int64(offsets[85]), "where the index says")
        session.setInputComplete(true)
        eq(produce(session, 2), 0, "nothing is produced")
        check(session.jumpFailure?.contains("no keyframe at the indexed 84.000 s") == true, "the keyframe met is not the planned one",
              session.jumpFailure ?? "nil")
        eq(files(in: opened.output).keys.sorted(), before, "nothing was written as segment 14")
        eq(session.missingSegments(), IndexSet(integersIn: 2..<14), "the holes stay holes (the caller gives them up)")
    }

    func testAnEarlierClusterStillLeadsToTheKeyframeWithinALimit() {
        // The cue of the keyframe at 84 s points to the Cluster of 78 s: the pass reads on to
        // the planned keyframe — unless that is further than the search limit.
        let clean = RemuxTestStreams.named("hevc-eac3-cues-front")
        let offsets = clean.layout().clusterOffsets
        var stream = clean
        stream.cueOffsetErrors = [84: offsets[78] - offsets[84]]
        guard let reference = open(clean), let found = started(stream) else { return }
        convertInOrder(reference)
        check(found.session.jump(toSegment: 14) != nil, "the jump is made")
        found.session.setInputComplete(true)
        eq(produce(found.session, 2), 2, "the keyframe is found six seconds further")
        let (expected, got) = (files(in: reference.output), files(in: found.output))
        check(["vseg14.m4s", "a0seg14.m4s", "vseg15.m4s", "a0seg15.m4s"].allSatisfy { got[$0] != nil && got[$0] == expected[$0] },
              "and the segments are the right ones")

        guard let limited = started(stream, configure: { $0.maxJumpSearchBytes = 40_000 }) else { return }
        check(limited.session.jump(toSegment: 14) != nil, "the same jump, allowed to read 40 KB")
        limited.session.setInputComplete(true)
        eq(produce(limited.session, 2), 0, "gives up")
        check(limited.session.jumpFailure?.contains("not found within 40000 bytes") == true, "saying so", limited.session.jumpFailure ?? "nil")
        check(files(in: limited.output)["vseg14.m4s"] == nil, "with nothing written")
    }

    func testAnIndexedTimeThatIsNotAKeyframe() {
        // The index lists 30.040 s; the stream's keyframes are at 30 s and 31 s. In file order
        // the plan is abandoned there (as before); a pass that jumped can't fall back on the
        // grid in the middle of the list.
        var stream = RemuxTestStreams.named("hevc-eac3-cues-front")
        stream.cueTimeErrors = [30: 40]

        // Jumped to directly: its keyframe is not there.
        guard let direct = started(stream) else { return }
        check(direct.session.jump(toSegment: 5) != nil, "to the segment that starts at the wrong time")
        direct.session.setInputComplete(true)
        eq(produce(direct.session, 2), 0, "nothing produced")
        check(direct.session.jumpFailure?.contains("no keyframe at the indexed 30.040 s") == true, "failed", direct.session.jumpFailure ?? "nil")

        // Met while filling a hole: the same.
        guard let filling = started(stream) else { return }
        check(filling.session.jump(toSegment: 10) != nil, "ahead, past the wrong time")
        filling.session.setInputComplete(true)
        eq(produce(filling.session, 1), 1, "segment 10")
        check(filling.session.jump(toSegment: 2) != nil, "back")
        filling.session.setInputComplete(true)
        eq(produce(filling.session, 8), 2, "segments 2 and 3; segment 4 would end at the wrong time")
        check(filling.session.jumpFailure?.contains("no keyframe at the planned 30.040 s") == true, "failed inside the hole",
              filling.session.jumpFailure ?? "nil")
        check(files(in: filling.output)["vseg4.m4s"] == nil, "segment 4 is not written with another end than the list says")

        // Met at the high-water mark: the plan is abandoned and the pass goes on on the grid,
        // as a session that never jumped does — but nothing can be jumped to any more.
        guard let frontier = started(stream) else { return }
        check(frontier.session.jump(toSegment: 3) != nil, "one segment ahead")
        frontier.session.setInputComplete(true)
        drain(frontier.session)
        eq(frontier.session.jumpFailure, nil, "no failure at the mark")
        unavailable(frontier.session, containing: "abandoned", "the plan is abandoned")
        check(frontier.session.progress.segmentsWritten > 10, "and the film goes on", "\(frontier.session.progress.segmentsWritten)")
        eq(frontier.session.missingSegments(), IndexSet([2]), "the hole stays")
        expectRefused(frontier, [2], "no plan to go back by")
    }
}
