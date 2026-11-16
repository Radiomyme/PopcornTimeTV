//
//  MatroskaCueOffsetsTests.swift
//  PopcornTimeTests
//
//  What the demuxer needs to move through a file by its keyframe index (Cues): the Cluster of
//  every indexed keyframe, the indexed Cluster before another one, a look at what really lies
//  at an offset the index gives, and `jump(toClusterAt:)` — which starts reading there, both
//  ways, waits for a Cluster that is not downloaded, and never resynchronises on another
//  Cluster when the index lied.
//

import XCTest
import Foundation

final class MatroskaCueOffsetsTests: RemuxSessionTestCase {

    private var handles: [FileHandle] = []

    override func tearDown() {
        handles.forEach { try? $0.close() }
        handles = []
        super.tearDown()
    }

    /// A demuxer with its headers parsed on `stream` (or on `content`, a holed copy of it).
    private func demuxer(_ stream: SyntheticMatroska, content: Data? = nil, complete: Bool = true,
                         file: StaticString = #filePath, line: Int = #line) -> (MatroskaDemuxer, SyntheticMatroska.Layout, URL)? {
        let layout = stream.layout()
        guard let files = temporaryInput(content ?? layout.data, file: file, line: line),
              let handle = try? FileHandle(forReadingFrom: files.input) else {
            check(false, "the stream opens", file: file, line: line)
            return nil
        }
        handles.append(handle)
        let size = UInt64(layout.data.count)
        let demuxer = MatroskaDemuxer(reader: EBMLReader(handle: handle) { size })
        demuxer.assumeFullyDownloaded = complete
        guard demuxer.parseHeaders() else {
            check(false, "the headers parse", file: file, line: line)
            return nil
        }
        return (demuxer, layout, files.input)
    }

    private func indexed(_ change: (inout SyntheticMatroska) -> Void) -> SyntheticMatroska {
        RemuxTestStreams.make { $0.cues = .front; change(&$0) }
    }

    /// The video frames' timestamps of a cluster read.
    private func videoTicks(_ frames: [MKVFrame]?) -> [Int64] {
        (frames ?? []).filter { $0.trackNumber == 1 }.map(\.timestamp)
    }

    // MARK: The index

    func testTheIndexKeepsTheClusterOfEveryKeyframe() {
        let variants: [(String, SyntheticMatroska)] = [
            ("Cues at the front", indexed { _ in }),
            ("Cues at the back", indexed { $0.cues = .back; $0.segmentSizeKnown = true }),
            ("a sparse index", indexed { $0.cueStride = 5 }),
            ("keyframes inside the clusters", indexed { $0.isKeyframe = { index, _ in index % 60 == 0 } }),
            ("unknown-size clusters", indexed { $0.cues = .back; $0.unknownSizeClusters = true }),
        ]
        for (name, stream) in variants {
            guard let (demuxer, layout, _) = demuxer(stream) else { return }
            check(demuxer.cueEntries.isEmpty, "\(name): no entry before the index is loaded")
            let expected = layout.cuePoints.map { MatroskaDemuxer.CueEntry(ticks: $0.ticks, clusterOffset: UInt64($0.writtenOffset)) }
            eq(demuxer.loadCueIndex(trackNumber: 1), .available(expected.map(\.ticks)), "\(name): the times are returned as before")
            eq(demuxer.cueEntries, expected, "\(name): one entry per time, with the offset of its Cluster")
            check(!expected.isEmpty && expected.allSatisfy { demuxer.clusterOffset(forCueTicks: $0.ticks) == $0.clusterOffset },
                  "\(name): every indexed time finds its Cluster")
            check(expected.allSatisfy { entry in layout.clusterOffsets.contains(Int(entry.clusterOffset)) },
                  "\(name): and each offset is where a Cluster starts")
            eq(demuxer.clusterOffset(forCueTicks: (expected.last?.ticks ?? 0) + 1), nil, "\(name): a time the index does not list has none")
            eq(demuxer.clusterOffset(forCueTicks: -5), nil, "\(name): nor a time before it")
        }
    }

    func testAnIndexForAnotherTrackOrNoneLeavesNoEntry() {
        guard let (demuxer, _, _) = demuxer(indexed { _ in }) else { return }
        eq(demuxer.loadCueIndex(trackNumber: 2), .unavailable("no cue point for track 2"), "the index lists the video track only")
        check(demuxer.cueEntries.isEmpty, "no entry for a track without cue points")
        guard let (plain, _, _) = self.demuxer(RemuxTestStreams.make { _ in }) else { return }
        eq(plain.loadCueIndex(trackNumber: 1), .unavailable("no Cues element"), "a file without Cues")
        check(plain.cueEntries.isEmpty && plain.indexedClusterOffset(before: UInt64.max) == nil, "nothing to jump through")
    }

    func testTheOrderOfTheIndexIsJudgedAmongTheTracksOwnCuePoints() {
        // Cues in mux order: a subtitle cue point 40 ms before the video cue point it follows.
        let muxOrder = indexed { $0.hasTextSubtitles = true; $0.subtitleCuesBefore = [10: 40] }
        guard let (demuxer, layout, _) = demuxer(muxOrder) else { return }
        let expected = layout.cuePoints.map { MatroskaDemuxer.CueEntry(ticks: $0.ticks, clusterOffset: UInt64($0.writtenOffset)) }
        eq(demuxer.loadCueIndex(trackNumber: 1), .available(expected.map(\.ticks)),
           "another track's cue point earlier than the one before it leaves the video index usable")
        eq(demuxer.cueEntries, expected, "with every video keyframe, and none of the subtitle's")

        // The video track's own times going backward still make the index unusable.
        let backward = indexed { $0.cueTimeErrors = [10: -2_000] }
        guard let (wrong, _, _) = self.demuxer(backward) else { return }
        guard case .unavailable(let reason) = wrong.loadCueIndex(trackNumber: 1) else {
            return check(false, "a video index going backward is refused")
        }
        check(reason.contains("CueTime going backward"), "why", reason)
    }

    func testTheIndexedClusterBeforeAnother() {
        guard let (demuxer, layout, _) = demuxer(indexed { _ in }) else { return }
        _ = demuxer.loadCueIndex(trackNumber: 1)
        let offsets = layout.clusterOffsets.map { UInt64($0) }
        eq(demuxer.indexedClusterOffset(before: offsets[40]), offsets[39], "the cluster indexed just before")
        eq(demuxer.indexedClusterOffset(before: offsets[40] + 1), offsets[40], "strictly before: one byte further, the cluster itself")
        eq(demuxer.indexedClusterOffset(before: offsets[0]), nil, "nothing before the first indexed cluster")
        eq(demuxer.indexedClusterOffset(before: UInt64.max), offsets[119], "the last one, from past the end")

        // A sparse index: the previous INDEXED cluster, however far.
        guard let (sparse, sparseLayout, _) = self.demuxer(indexed { $0.cueStride = 5 }) else { return }
        _ = sparse.loadCueIndex(trackNumber: 1)
        let sparseOffsets = sparseLayout.clusterOffsets.map { UInt64($0) }
        eq(sparse.indexedClusterOffset(before: sparseOffsets[40]), sparseOffsets[35], "five clusters back with one keyframe in five indexed")
        eq(sparse.indexedClusterOffset(before: sparseOffsets[38]), sparseOffsets[35], "from a cluster the index does not list too")

        // Several keyframes of one cluster: one offset, counted once.
        guard let (dense, denseLayout, _) = self.demuxer(indexed { $0.isKeyframe = { index, _ in index % 5 == 0 } }) else { return }
        _ = dense.loadCueIndex(trackNumber: 1)
        let denseOffsets = denseLayout.clusterOffsets.map { UInt64($0) }
        eq(dense.cueEntries.filter { $0.clusterOffset == denseOffsets[7] }.count, 5, "five indexed keyframes in cluster 7")
        eq(dense.indexedClusterOffset(before: denseOffsets[7]), denseOffsets[6], "the cluster before it, not itself")
    }

    // MARK: Probing

    func testAProbeTellsAClusterFromZerosFromAnythingElse() {
        let stream = indexed { $0.cues = .back }
        let layout = stream.layout()
        let offsets = layout.clusterOffsets
        guard let (demuxer, _, _) = demuxer(stream) else { return }
        let start = demuxer.reader.offset
        check(offsets.allSatisfy { demuxer.probeCluster(at: UInt64($0)) == .cluster }, "a Cluster at every Cluster's offset")
        eq(demuxer.probeCluster(at: UInt64(offsets[50] + 7)), .notACluster, "the inside of a cluster")
        eq(demuxer.probeCluster(at: UInt64(layout.cuesOffset ?? 0)), .notACluster, "another element (the Cues)")
        eq(demuxer.probeCluster(at: 0), .notACluster, "the EBML header")
        eq(demuxer.probeCluster(at: UInt64(layout.data.count + 100)), .notACluster, "past the end of a complete file")
        eq(demuxer.reader.offset, start, "a probe does not move the reader")

        // The same file while it downloads: the head and the tail only.
        let head = offsets[10], tail = layout.cuesOffset ?? layout.data.count
        let partial = Self.holed(layout.data, keeping: [0..<head, tail..<layout.data.count])
        guard let (downloading, _, input) = self.demuxer(stream, content: partial, complete: false) else { return }
        eq(downloading.probeCluster(at: UInt64(offsets[5])), .cluster, "a cluster of the head")
        eq(downloading.probeCluster(at: UInt64(offsets[50])), .notYet, "zeros where a cluster will be: not downloaded yet")
        eq(downloading.probeCluster(at: UInt64(layout.data.count + 100)), .notYet, "past the data of a file still downloading")
        // Only the first bytes of the cluster arrived: its first child is still to come.
        fill(input, from: layout.data, offsets[50]..<(offsets[50] + 12))
        eq(downloading.probeCluster(at: UInt64(offsets[50])), .notYet, "a Cluster header whose first child is not there yet")
        fill(input, from: layout.data, offsets[50]..<offsets[51])
        eq(downloading.probeCluster(at: UInt64(offsets[50])), .cluster, "the cluster, once downloaded")
        // Complete, zeros are what the file holds.
        downloading.assumeFullyDownloaded = true
        eq(downloading.probeCluster(at: UInt64(offsets[60])), .notACluster, "zeros in a complete file are not a Cluster to wait for")
    }

    // MARK: Jumping

    func testAJumpStartsReadingAtThatClusterBothWays() {
        guard let (demuxer, layout, _) = demuxer(indexed { _ in }) else { return }
        let offsets = layout.clusterOffsets.map { UInt64($0) }
        eq(videoTicks(demuxer.readNextCluster()).first, 0, "the first cluster in file order")
        eq(videoTicks(demuxer.readNextCluster()).first, 1000, "then the second")

        demuxer.jump(toClusterAt: offsets[50])
        eq(demuxer.reader.offset, offsets[50], "the reader is at the cluster asked for")
        let ahead = demuxer.readNextCluster()
        eq(videoTicks(ahead).first, 50_000, "forward: the frames of cluster 50")
        check(!(ahead ?? []).isEmpty && (ahead ?? []).allSatisfy { $0.clusterOffset == offsets[50] }, "tagged with its offset")
        eq(videoTicks(demuxer.readNextCluster()).first, 51_000, "then file order again")

        demuxer.jump(toClusterAt: offsets[10])
        let back = demuxer.readNextCluster()
        eq(videoTicks(back).first, 10_000, "backward: the frames of cluster 10")
        check((back ?? []).allSatisfy { $0.clusterOffset == offsets[10] }, "tagged with its own offset, not the one left")
        eq(videoTicks(demuxer.readNextCluster()).first, 11_000, "and on from there")
        eq(demuxer.jumpFailure, nil, "nothing failed")
        eq(demuxer.implausibleClusters, 0, "a step back of 40 s is not damage")
    }

    func testAJumpIntoUnknownSizeClustersForgetsTheOneBeingRead() {
        guard let (demuxer, layout, _) = demuxer(indexed { $0.cues = .back; $0.unknownSizeClusters = true }) else { return }
        let offsets = layout.clusterOffsets.map { UInt64($0) }
        _ = demuxer.readNextCluster()
        demuxer.jump(toClusterAt: offsets[70])
        let frames = demuxer.readNextCluster()
        eq(videoTicks(frames).first, 70_000, "the cluster asked for")
        eq(videoTicks(frames).count, 25, "its own frames only: it ends where the next one starts")
        check((frames ?? []).allSatisfy { $0.clusterOffset == offsets[70] }, "none tagged as a continuation of the cluster left")
        eq(videoTicks(demuxer.readNextCluster()).first, 71_000, "then the next")
    }

    func testAJumpWaitsForAClusterNotDownloadedYet() {
        let stream = indexed { _ in }
        let layout = stream.layout()
        let offsets = layout.clusterOffsets
        let partial = Self.holed(layout.data, keeping: [0..<offsets[10]])
        guard let (demuxer, _, input) = demuxer(stream, content: partial, complete: false) else { return }
        demuxer.jump(toClusterAt: UInt64(offsets[50]))
        check(demuxer.readNextCluster() == nil && demuxer.readNextCluster() == nil, "nothing to read: the cluster is zeros")
        eq(demuxer.jumpFailure, nil, "zeros are not a failure: the piece is to come")
        eq(demuxer.reader.offset, UInt64(offsets[50]), "the reader waits where it landed")
        // The second half of the cluster first, then its start: pieces arrive in any order.
        let middle = (offsets[50] + offsets[51]) / 2
        fill(input, from: layout.data, middle..<offsets[51])
        check(demuxer.readNextCluster() == nil, "half a cluster (its end) is not a cluster")
        fill(input, from: layout.data, offsets[50]..<middle)
        eq(videoTicks(demuxer.readNextCluster()).first, 50_000, "the whole cluster, once both halves are there")
        check(demuxer.readNextCluster() == nil, "then it waits for cluster 51")
        eq(demuxer.jumpFailure, nil, "still no failure")
    }

    func testAWrongOffsetIsNeverResynchronisedOn() {
        guard let (demuxer, layout, _) = demuxer(indexed { _ in }) else { return }
        let offsets = layout.clusterOffsets.map { UInt64($0) }
        _ = demuxer.readNextCluster()
        // Seven bytes into cluster 50: the next real Cluster is 51, which a resynchronisation
        // would find — another second of the movie than the one asked for.
        demuxer.jump(toClusterAt: offsets[50] + 7)
        check(demuxer.readNextCluster() == nil, "nothing is read from an offset that is not a Cluster")
        check(demuxer.jumpFailure != nil, "and the demuxer says the index is wrong", demuxer.jumpFailure ?? "nil")
        eq(demuxer.reader.offset, offsets[50] + 7, "the reader did not go looking further")
        check(demuxer.readNextCluster() == nil && demuxer.readNextCluster() == nil, "nor does it at the next calls")
        // Another jump is another attempt.
        demuxer.jump(toClusterAt: offsets[50])
        eq(demuxer.jumpFailure, nil, "a new jump clears the failure")
        eq(videoTicks(demuxer.readNextCluster()).first, 50_000, "and reads the cluster it lands on")
    }

    func testReadingInFileOrderStillResynchronisesAfterDamage() {
        // The rule above is the jump's only: the same damage met in file order is skipped as
        // before (the next Cluster is the next second of the movie).
        let stream = indexed { _ in }
        let layout = stream.layout()
        var damaged = layout.data
        let offsets = layout.clusterOffsets
        damaged.replaceSubrange(offsets[3]..<(offsets[3] + 4), with: [0xFF, 0xFF, 0xFF, 0xFF])
        guard let (demuxer, _, _) = demuxer(stream, content: damaged) else { return }
        var firsts: [Int64] = []
        for _ in 0..<8 {
            guard let frames = demuxer.readNextCluster() else { break }
            if let first = videoTicks(frames).first { firsts.append(first) }
        }
        eq(Array(firsts.prefix(5)), [0, 1000, 2000, 4000, 5000], "cluster 3 is lost, cluster 4 found")
        eq(demuxer.jumpFailure, nil, "no jump, no jump failure")
    }

    // MARK: Laced tracks

    func testLacedTracksAreNoted() {
        guard let (laced, _, _) = demuxer(indexed { $0.audioFramesPerBlock = 4 }) else { return }
        check(laced.lacedTracks.isEmpty, "nothing known before a block is read")
        _ = laced.readNextCluster()
        eq(laced.lacedTracks, [2], "the audio track is laced, the video is not")
        guard let (plain, _, _) = demuxer(indexed { _ in }) else { return }
        _ = plain.readNextCluster()
        check(plain.lacedTracks.isEmpty, "one frame per block: not laced")
    }
}
