//
//  RemuxJumpIdentityTests.swift
//  PopcornTimeTests
//
//  A segment written after a jump is the segment a conversion in file order writes there, byte
//  for byte: the player may then be handed any mix of the two. Each test converts a synthetic
//  stream in order (the reference), converts it again while moving the pass — ahead (a resume),
//  back into what was skipped (a rewind), ahead again over what exists (the hop to the
//  high-water mark), to the end — and compares every file, the playlists and what the session
//  publishes about its segments. The same on a file still downloading, whose pieces arrive in
//  any order, and after the end of the film is written.
//

import XCTest
import Foundation

final class RemuxJumpIdentityTests: RemuxSessionTestCase {

    private typealias Session = MKVToHLSRemuxSession

    /// What a conversion in file order gives.
    private struct Reference {
        let files: [String: Data]
        let playlists: [String: String]
        let durations: [Double]
        let offsets: [Int64]
        let bytes: [Int64]
        let segments: Int
        let mediaSeconds: Double
        let tailFillers: Int
    }

    private func describe(_ opened: Opened) -> Reference {
        let session = opened.session
        return Reference(files: files(in: opened.output), playlists: playlists(session), durations: session.segmentDurations(),
                         offsets: session.segmentSourceOffsets(), bytes: session.segmentBytes(),
                         segments: session.progress.segmentsWritten, mediaSeconds: session.progress.mediaSeconds,
                         tailFillers: session.tailFillerCount)
    }

    private func reference(_ stream: SyntheticMatroska, file: StaticString = #filePath, line: Int = #line) -> Reference? {
        guard let opened = open(stream, file: file, line: line) else { return nil }
        convertInOrder(opened)
        check(opened.session.writeFailure == nil && opened.session.progress.finished, "the reference is converted to the end",
              file: file, line: line)
        return describe(opened)
    }

    /// The real segments of the plan: a jump can go to 2 ..< this.
    private func realCount(_ session: Session) -> Int {
        var count = 2
        while session.jumpTarget(forSegment: count) != nil { count += 1 }
        return count
    }

    /// A session with segments 0 and 1 written and its list frozen from the plan, as when the
    /// player has fetched its playlists.
    private func started(_ stream: SyntheticMatroska, name: String, configure: (Session) -> Void = { _ in },
                         file: StaticString = #filePath, line: Int = #line) -> Opened? {
        guard let opened = open(stream, configure: configure, file: file, line: line) else { return nil }
        eq(produce(opened.session, 2), 2, "\(name): two segments to start with", file: file, line: line)
        check(opened.session.freezePlaylistFromPlan(), "\(name): the list is frozen from the plan", file: file, line: line)
        eq(opened.session.jumpCapability, .available, "\(name): jumps are available", file: file, line: line)
        return opened
    }

    /// Moves the pass and says, as `RemuxPlayback` does at its next tick, that the whole file
    /// is there.
    @discardableResult
    private func jump(_ session: Session, to index: Int, leadIn: Session.JumpLeadIn = .automatic, name: String,
                      file: StaticString = #filePath, line: Int = #line) -> Session.JumpTarget? {
        let target = session.jump(toSegment: index, leadIn: leadIn)
        check(target != nil, "\(name): the pass moves to segment \(index)", file: file, line: line)
        session.setInputComplete(true)
        return target
    }

    /// Ahead to `target` (70 % of the film when nil), three segments there, back to segment 2
    /// to fill what was skipped, the hop to the high-water mark, the rest, the end.
    private func aheadBackHopEnd(_ stream: SyntheticMatroska, leadIn: Session.JumpLeadIn, name: String, target: Int? = nil,
                                 configure: (Session) -> Void = { _ in },
                                 file: StaticString = #filePath, line: Int = #line) -> Opened? {
        guard let opened = started(stream, name: name, configure: configure, file: file, line: line) else { return nil }
        let session = opened.session
        let real = realCount(session)
        let ahead = target ?? Int(0.7 * Double(real))
        guard ahead > 2, ahead < real else {
            check(false, "\(name): the stream is long enough to jump in", "\(real) real segments", file: file, line: line)
            return nil
        }
        jump(session, to: ahead, leadIn: leadIn, name: name, file: file, line: line)
        let there = produce(session, min(3, real - 1 - ahead))
        eq(there, min(3, real - 1 - ahead), "\(name): the segments at the target", file: file, line: line)
        eq(session.missingSegments(), IndexSet(integersIn: 2..<ahead), "\(name): what was skipped is missing", file: file, line: line)
        jump(session, to: 2, leadIn: leadIn, name: name, file: file, line: line)
        // More asked than there are holes: the pass stops by itself at the first segment that exists.
        eq(produce(session, real), ahead - 2, "\(name): the pass fills the holes, no more", file: file, line: line)
        check(session.missingSegments().isEmpty, "\(name): nothing is missing any more", file: file, line: line)
        if there > 0 {
            eq(session.nextSegmentIndex, ahead, "\(name): the pass is parked on the first segment that exists", file: file, line: line)
            jump(session, to: ahead + there, leadIn: .always, name: name, file: file, line: line)
        }
        drain(session)
        session.finish()
        return opened
    }

    private func expectIdentical(_ opened: Opened, _ reference: Reference, name: String,
                                 file: StaticString = #filePath, line: Int = #line) {
        let session = opened.session
        let got = describe(opened)
        eq(session.jumpFailure, nil, "\(name): no jump failed", file: file, line: line)
        eq(session.writeFailure, nil, "\(name): no write failed", file: file, line: line)
        eq(got.files.keys.sorted(), reference.files.keys.sorted(), "\(name): the same files", file: file, line: line)
        let differing = reference.files.keys.sorted().filter { got.files[$0] != reference.files[$0] }
        check(differing.isEmpty, "\(name): every file is byte-identical to the conversion in file order",
              "\(differing.count) of \(reference.files.count) differ: \(differing.prefix(8))", file: file, line: line)
        eq(got.playlists, reference.playlists, "\(name): the playlists are the same text", file: file, line: line)
        eq(got.durations, reference.durations, "\(name): the same durations are published", file: file, line: line)
        eq(got.offsets, reference.offsets, "\(name): the same source offsets", file: file, line: line)
        eq(got.bytes, reference.bytes, "\(name): the same sizes", file: file, line: line)
        eq(got.segments, reference.segments, "\(name): the same segment count", file: file, line: line)
        eq(got.tailFillers, reference.tailFillers, "\(name): the same tail", file: file, line: line)
        check(abs(got.mediaSeconds - reference.mediaSeconds) < 0.25, "\(name): the same media length, to the planned durations of the skipped segments",
              "\(got.mediaSeconds) vs \(reference.mediaSeconds)", file: file, line: line)
        check(session.missingSegments().isEmpty && session.isTailWritten && session.progress.finished,
              "\(name): complete, its end written", file: file, line: line)
    }

    // MARK: Ahead, back, hop, end

    func testAheadBackHopAndEndWriteWhatAPassInFileOrderWrites() {
        // Every indexed stream of the golden file but the one with long subtitle cues (below).
        for (name, stream) in RemuxTestStreams.all where name != "h264-aac-no-index" && name != "subtitles-cues-front" {
            guard let reference = reference(stream) else { return }
            for (mode, leadIn) in [("automatic lead-in", Session.JumpLeadIn.automatic), ("lead-in always", .always)] {
                guard let jumped = aheadBackHopEnd(stream, leadIn: leadIn, name: "\(name), \(mode)") else { return }
                expectIdentical(jumped, reference, name: "\(name), \(mode)")
            }
        }
    }

    func testOtherShapesOfStreams() {
        let variants: [(String, SyntheticMatroska)] = [
            ("laced E-AC-3 without a frame duration", RemuxTestStreams.make { $0.cues = .front; $0.audioCodec = .eac3; $0.audioFramesPerBlock = 6 }),
            ("laced AAC with a frame duration", RemuxTestStreams.make { $0.cues = .back; $0.audioFramesPerBlock = 3; $0.audioDeclaresFrameDuration = true }),
            ("AAC, keyframes inside the clusters", RemuxTestStreams.make { $0.cues = .front; $0.isKeyframe = { index, _ in index % 60 == 0 } }),
            ("HEVC + E-AC-3, 0.1 ms ticks, Cues at the back", RemuxTestStreams.make {
                $0.cues = .back; $0.segmentSizeKnown = true; $0.videoCodec = .hevc; $0.audioCodec = .eac3; $0.timestampScale = 100_000
            }),
            ("a sparse index after unknown-size clusters", RemuxTestStreams.make { $0.cues = .back; $0.cueStride = 3; $0.unknownSizeClusters = true }),
            // No keyframe in the last grid slot: the film ends with a tail unit.
            ("a tail unit", RemuxTestStreams.make {
                $0.cues = .front; $0.clusterCount = 122
                $0.isKeyframe = { index, perCluster in index % perCluster == 0 && index < 120 * perCluster }
            }),
        ]
        for (name, stream) in variants {
            guard let reference = reference(stream), let jumped = aheadBackHopEnd(stream, leadIn: .automatic, name: name) else { return }
            expectIdentical(jumped, reference, name: name)
            if name == "a tail unit" { eq(reference.tailFillers, 1, "\(name): the stream does end with one") }
        }
    }

    func testAFilmOfTheUsersShapeWithTwoAudioTracksBFramesAndAFullIndex() {
        // HEVC + E-AC-3 Atmos + an AAC commentary + text subtitles, the video in decode order,
        // the Cues at the back listing every track: a jump must give each audio rendition its
        // own start (the AAC one its priming frames: the lead-in is decided on every audio
        // track, not the first), keep the reordered frames whole at the junctions, and read
        // the video's position among the cue's track positions.
        let stream = RemuxTestStreams.make {
            $0.videoCodec = .hevc; $0.videoFrameBytes = 600; $0.reorderedVideoFrames = true
            $0.audioCodec = .eac3; $0.secondAudioCodec = .aac
            $0.hasTextSubtitles = true
            // Cues that end in the segment they begin in: what differs is then the audio's and
            // the video's doing (crossing cues: `testSubtitlesWithTheLeadIn`).
            $0.subtitleCue = { index in (index * 2000 + 300, 1000, "Cue \(index)") }
            $0.cues = .back; $0.segmentSizeKnown = true; $0.cuesAlsoListTracks = [2, 4, 3]
        }
        guard let reference = reference(stream) else { return }
        eq(reference.segments, 20, "the film is cut on the keyframe grid: twenty segments")
        check(reference.files.keys.contains { $0.hasPrefix("a1seg") }, "the second audio track has its own rendition",
              "\(reference.files.keys.sorted().prefix(12))")
        for (mode, leadIn) in [("automatic lead-in", Session.JumpLeadIn.automatic), ("lead-in always", .always)] {
            guard let jumped = aheadBackHopEnd(stream, leadIn: leadIn, name: "the user's shape, \(mode)") else { return }
            expectIdentical(jumped, reference, name: "the user's shape, \(mode)")
        }
    }

    func testAnyRealSegmentCanBeTheTarget() {
        let stream = RemuxTestStreams.named("hevc-eac3-cues-front")
        guard let reference = reference(stream) else { return }
        // The segment right after the cursor, the middle, the last but one, the last real one
        // (the pass then runs to the end of the input: `finish` writes it).
        for target in [3, 9, 18, 19] {
            guard let jumped = aheadBackHopEnd(stream, leadIn: .automatic, name: "target \(target)", target: target) else { return }
            expectIdentical(jumped, reference, name: "target \(target)")
        }
    }

    func testABoundedPumpChangesNothing() {
        // `pump` returning between two cuts (its input budget) while a jump looks for its keyframe.
        let stream = RemuxTestStreams.named("h264-aac-cues-back-sized-segment")
        guard let reference = reference(stream),
              let jumped = aheadBackHopEnd(stream, leadIn: .automatic, name: "4 KB a call", configure: { $0.pumpInputBudget = 4000 }) else { return }
        expectIdentical(jumped, reference, name: "4 KB a call")
    }

    func testABackPassThatReachesTheHighWaterMarkGoesOnWithoutAHop() {
        // Ahead, then back before anything was written there: the pass fills the holes and
        // arrives at the mark with the right frames in hand.
        let stream = RemuxTestStreams.named("laced-aac-cues-back")
        guard let reference = reference(stream), let opened = started(stream, name: "no hop") else { return }
        let session = opened.session
        jump(session, to: 12, name: "no hop")
        jump(session, to: 2, name: "no hop")
        eq(produce(session, 12), 12, "the ten holes, then segments 12 and 13: the mark is not a stop")
        eq(session.nextSegmentIndex, 14, "the pass went through the mark")
        drain(session)
        session.finish()
        expectIdentical(opened, reference, name: "no hop")
    }

    func testManyJumpsInARow() {
        // A viewer who can't make up their mind: every move discards what was demuxed.
        let stream = RemuxTestStreams.named("sparse-cues-mid-cluster-keyframes")
        guard let reference = reference(stream), let opened = started(stream, name: "many") else { return }
        let session = opened.session
        for target in [15, 6, 17, 4, 10] {
            jump(session, to: target, name: "many")
            eq(produce(session, 1), 1, "one segment at \(target)")
        }
        eq(session.missingSegments(), IndexSet([2, 3, 5, 7, 8, 9, 11, 12, 13, 14, 16]), "what none of them wrote")
        // Then everything that is missing, lowest first, and the end.
        while let hole = session.missingSegments().first {
            jump(session, to: hole, name: "many")
            check(produce(session, 20) >= 1, "the run of holes from \(hole) is filled")
        }
        jump(session, to: 18, leadIn: .always, name: "many")
        drain(session)
        session.finish()
        expectIdentical(opened, reference, name: "many jumps")
    }

    // MARK: Subtitles

    /// The text lines of a WebVTT file made from the synthetic cues ("Cue 41").
    private func cueLines(_ data: Data?) -> [String] {
        String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: .newlines).filter { $0.hasPrefix("Cue ") }
    }

    func testSubtitlesWithTheLeadIn() {
        // Cues that cross a segment boundary begin in the second before it: the lead-in (the
        // indexed Cluster before the keyframe's) holds them.
        func stream(_ audio: SyntheticMatroska.AudioCodec) -> SyntheticMatroska {
            RemuxTestStreams.make {
                $0.cues = .front; $0.hasTextSubtitles = true; $0.audioCodec = audio
                $0.subtitleCue = { index in (index * 2000 + 1300, 1500, "Cue \(index)") }
            }
        }
        // AAC: a jump reads the lead-in by itself.
        guard let aac = reference(stream(.aac)), let jumped = aheadBackHopEnd(stream(.aac), leadIn: .automatic, name: "AAC + subtitles") else { return }
        expectIdentical(jumped, aac, name: "AAC + subtitles")
        check(cueLines(aac.files["s0seg14.vtt"]).contains("Cue 41"), "the cue shown across 84 s is in segment 14")

        // E-AC-3 needs no lead-in: asked for, the cue in progress is kept; left to itself, a
        // jump does not download a Cluster for it — the first segment written after it lacks
        // that cue, and nothing else differs.
        guard let eac3 = reference(stream(.eac3)), let always = aheadBackHopEnd(stream(.eac3), leadIn: .always, name: "E-AC-3 + subtitles, always"),
              let automatic = aheadBackHopEnd(stream(.eac3), leadIn: .automatic, name: "E-AC-3 + subtitles, automatic") else { return }
        expectIdentical(always, eac3, name: "E-AC-3 + subtitles, always")
        let got = files(in: automatic.output)
        let differing = eac3.files.keys.sorted().filter { got[$0] != eac3.files[$0] }
        eq(differing, ["s0seg14.vtt", "s0seg2.vtt"], "without a lead-in, only the WebVTT of the two segments jumped to differ")
        for (segment, cue) in [(14, "Cue 41"), (2, "Cue 5")] {
            let lines = cueLines(got["s0seg\(segment).vtt"])
            let full = cueLines(eac3.files["s0seg\(segment).vtt"])
            check(full.contains(cue) && !lines.contains(cue), "segment \(segment) lacks the cue that began before it (\(cue))")
            eq(lines, full.filter { $0 != cue }, "and has every cue that begins in it")
        }
    }

    func testACueThatBeganBeforeTheLeadInIsMissingFromTheSegmentJumpedTo() {
        // The golden stream's long cues begin 3.7 s before the boundary they cross: further back
        // than the lead-in (1 s here). Accepted: every player misses the cue in progress where
        // it lands; everything else is identical.
        let stream = RemuxTestStreams.named("subtitles-cues-front")
        guard let reference = reference(stream), let jumped = aheadBackHopEnd(stream, leadIn: .automatic, name: "long cues") else { return }
        let got = files(in: jumped.output)
        let differing = reference.files.keys.sorted().filter { got[$0] != reference.files[$0] }
        eq(differing, ["s0seg17.vtt", "s0seg2.vtt"], "only the WebVTT of segments jumped to, where a long cue was in progress")
        for (segment, cue) in [(17, "Cue 49"), (2, "Cue 4")] {
            let lines = cueLines(got["s0seg\(segment).vtt"])
            let full = cueLines(reference.files["s0seg\(segment).vtt"])
            check(full.contains(cue) && !lines.contains(cue), "segment \(segment) lacks \(cue), begun before the lead-in")
            eq(lines, full.filter { $0 != cue }, "and nothing else")
        }
        eq(jumped.session.jumpFailure, nil, "no failure")
    }

    // MARK: A file still downloading

    /// A file that holds its head (two segments' worth) and its tail (the Cues when they are
    /// at the back), read while the rest arrives.
    private func downloading(_ stream: SyntheticMatroska, name: String) -> (Opened, Reference)? {
        guard let reference = reference(stream) else { return nil }
        let layout = stream.layout()
        let kept = [0..<layout.clusterOffsets[14], (layout.cuesOffset.map { max($0, layout.clusterOffsets[119]) } ?? layout.data.count)..<layout.data.count]
        guard let opened = open(stream, complete: false, content: Self.holed(layout.data, keeping: kept)) else { return nil }
        eq(produce(opened.session, 2), 2, "\(name): the head gives two segments")
        check(opened.session.freezePlaylistFromPlan(), "\(name): the list is frozen from the plan")
        eq(opened.session.pump(maxNewSegments: 2), 0, "\(name): then the pass waits for pieces")
        return (opened, reference)
    }

    private func expectSegments(_ range: Range<Int>, of opened: Opened, toBe reference: Reference, name: String,
                                file: StaticString = #filePath, line: Int = #line) {
        let got = files(in: opened.output)
        for index in range {
            let names = Self.names(ofSegment: index, in: reference.files)
            check(!names.isEmpty && names.allSatisfy { got[$0] == reference.files[$0] },
                  "\(name): segment \(index) is the one a pass in file order writes", file: file, line: line)
        }
    }

    func testPiecesThatArriveOutOfOrder() {
        for streamName in ["hevc-eac3-cues-front", "h264-aac-cues-back-sized-segment"] {
            let stream = RemuxTestStreams.named(streamName)
            guard let (opened, reference) = downloading(stream, name: streamName) else { return }
            let session = opened.session
            let data = opened.layout.data
            let clusters = opened.layout.clusterOffsets

            // Ahead to segment 14 (84 s): nothing of it is on disk.
            eq(session.probeJump(toSegment: 14), .notYet, "\(streamName): the target is not downloaded")
            guard let ahead = session.jump(toSegment: 14) else { return check(false, "\(streamName): the jump ahead is made") }
            eq(session.pump(maxNewSegments: 2), 0, "\(streamName): nothing to write yet")
            eq(session.jumpFailure, nil, "\(streamName): zeros are pieces to come, not a wrong index")
            // Its pieces: the second half first.
            let from = Int(ahead.readOffset), to = clusters[104], middle = (from + to) / 2 + 777
            fill(opened.input, from: data, middle..<to)
            eq(session.pump(maxNewSegments: 2), 0, "\(streamName): the later half alone gives nothing")
            fill(opened.input, from: data, from..<middle)
            eq(session.probeJump(toSegment: 14), .cluster, "\(streamName): the target is there now")
            eq(produce(session, 3), 3, "\(streamName): three segments once the earlier half is there")
            expectSegments(14..<17, of: opened, toBe: reference, name: streamName)
            eq(session.pump(maxNewSegments: 2), 0, "\(streamName): then the pass waits again")

            // Back to segment 5 (30 s), its pieces one second at a time, in order.
            guard let back = session.jump(toSegment: 5) else { return check(false, "\(streamName): the jump back is made") }
            var written = 0
            var cluster = clusters.firstIndex(where: { $0 >= Int(back.readOffset) }) ?? 0
            fill(opened.input, from: data, Int(back.readOffset)..<clusters[cluster])
            while written < 3, cluster < 60 {
                fill(opened.input, from: data, clusters[cluster]..<clusters[cluster + 1])
                written += session.pump(maxNewSegments: 3 - written)
                cluster += 1
            }
            eq(written, 3, "\(streamName): three segments as their seconds arrive")
            check(cluster <= 50, "\(streamName): each one as soon as its own data and the next keyframe are there", "up to cluster \(cluster)")
            expectSegments(5..<8, of: opened, toBe: reference, name: streamName)
            eq(session.missingSegments(), IndexSet([2, 3, 4] + Array(8..<14)), "\(streamName): the rest is still missing")
            eq(session.jumpFailure, nil, "\(streamName): no failure")
            eq(session.writeFailure, nil, "\(streamName): no write failure")
            let names = files(in: opened.output).keys
            check(!names.contains("vseg4.m4s") && !names.contains("vseg8.m4s") && !names.contains("vseg17.m4s"),
                  "\(streamName): nothing else was written")
        }
    }

    func testTheWholeFileArrivingAfterJumpsGivesTheWholeFilm() {
        let streamName = "unknown-size-clusters-cues-back"
        let stream = RemuxTestStreams.named(streamName)
        guard let (opened, reference) = downloading(stream, name: streamName) else { return }
        let session = opened.session
        check(session.jump(toSegment: 14) != nil, "ahead, before the data")
        // Everything arrives; the caller says so once the download is complete.
        fill(opened.input, from: opened.layout.data, 0..<opened.layout.data.count)
        session.setInputComplete(true)
        drain(session)
        session.finish()
        check(session.isTailWritten, "the pass ran from the target to the end")
        jump(session, to: 2, name: streamName)
        eq(produce(session, 20), 12, "the holes behind")
        expectIdentical(opened, reference, name: streamName)
    }

    // MARK: After the end is written

    func testAJumpAfterTheEndFillsTheHolesAndNeverWritesTheEndAgain() {
        // A resume at 70 % played to the end, then a rewind to the beginning.
        let stream = RemuxTestStreams.make {
            $0.cues = .front; $0.clusterCount = 122
            $0.isKeyframe = { index, perCluster in index % perCluster == 0 && index < 120 * perCluster }
        }
        guard let reference = reference(stream), let opened = started(stream, name: "after the end") else { return }
        let session = opened.session
        jump(session, to: 14, name: "after the end")
        drain(session)
        session.finish()
        check(session.isTailWritten && session.progress.finished, "the end is written")
        eq(session.progress.segmentsWritten, 21, "segments 14 to 19 and the tail unit")
        eq(session.tailFillerCount, 1, "one tail unit")
        eq(session.missingSegments(), IndexSet(integersIn: 2..<14), "the head is still missing")
        eq(session.jumpCapability, .available, "and can still be written")
        expectSegments(14..<21, of: opened, toBe: reference, name: "after the end")
        func stamps() -> [String: Date] {
            var result: [String: Date] = [:]
            for name in ["vseg19.m4s", "a0seg19.m4s", "vseg20.m4s", "a0seg20.m4s"] {
                let attributes = try? FileManager.default.attributesOfItem(atPath: opened.output.appendingPathComponent(name).path)
                result[name] = attributes?[.modificationDate] as? Date
            }
            return result
        }
        let before = stamps()
        eq(before.count, 4, "the last segment and the tail unit are on disk")

        eq(session.pump(maxNewSegments: 2), 0, "a finished session pumps nothing by itself")
        jump(session, to: 2, name: "after the end")
        eq(session.nextSegmentIndex, 2, "the cursor is in the hole")
        eq(produce(session, 5), 5, "five of the twelve holes")
        eq(session.nextSegmentIndex, 7, "the cursor follows the pass while it fills")
        eq(produce(session, 30), 7, "the seven others, then the pass stops on the first segment that exists")
        eq(session.nextSegmentIndex, session.progress.segmentsWritten, "at rest: the cursor reads the mark again")
        eq(session.pump(maxNewSegments: 8), 0, "it writes nothing more")
        session.finish()
        eq(session.tailFillerCount, 1, "finish() again writes no second tail")
        eq(stamps(), before, "the last segment and the tail unit were not written again")
        check(session.progress.finished && session.isTailWritten, "still finished")
        eq(session.jump(toSegment: 5), nil, "nothing left to jump to: every segment exists")
        expectIdentical(opened, reference, name: "after the end")
    }

    func testTheLastRealSegmentAsATargetAfterAResumeNearTheEnd() {
        // A resume in the last segment: the pass has nothing to cut, `finish` writes it.
        let stream = RemuxTestStreams.named("h264-aac-cues-front")
        guard let reference = reference(stream), let opened = started(stream, name: "last") else { return }
        let session = opened.session
        jump(session, to: 19, name: "last")
        eq(produce(session, 2), 0, "the last segment ends with the input, not at a cut")
        session.finish()
        check(session.isTailWritten, "written by finish")
        expectSegments(19..<20, of: opened, toBe: reference, name: "last")
        jump(session, to: 2, name: "last")
        eq(produce(session, 30), 17, "segments 2 to 18")
        expectIdentical(opened, reference, name: "last")
    }

    // MARK: Without a jump

    func testWithoutAJumpTheReferencesAreTheGoldenConversion() throws {
        // What the tests above compare with is the conversion the golden file pins.
        let golden = try JSONDecoder().decode(RemuxSequentialGoldenTests.Golden.self, from: Fixtures.data("Remux/sequential-golden.json"))
        for name in ["h264-aac-cues-front", "hevc-eac3-cues-front", "sparse-cues-mid-cluster-keyframes"] {
            guard let reference = reference(RemuxTestStreams.named(name)), let expected = golden.streams[name] else {
                return check(false, "\(name) is in the golden file")
            }
            eq(reference.files.mapValues(Self.sha256), expected.files, "\(name): the reference is the golden conversion")
        }
    }
}
