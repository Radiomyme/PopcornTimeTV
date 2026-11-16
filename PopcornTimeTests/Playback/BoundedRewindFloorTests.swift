//
//  BoundedRewindFloorTests.swift
//  PopcornTimeTests
//
//  What a blocked rewind says in bounded storage, on the remux route
//  (BoundedStorageSession.isRewindFloorNeverDownloaded → remuxRewindFloorIsNeverWritten):
//  « This part hasn't been downloaded » when the rewind stops at the edge of what a native
//  jump skipped — a resume at a saved position: the film before it was never converted —,
//  « This part is no longer stored » when it stops at media the disk budget deleted. On the
//  real engine: a RemuxPlayback over a synthetic film whose file is a torrent's (only some of
//  its bytes there), the ticks made by the test on a clock it moves.
//

import XCTest
import Foundation

final class BoundedRewindFloorTests: RemuxSessionTestCase {

    /// The clock of the engine's rules (`RemuxPlayback.uptimeProvider`).
    private final class Clock {
        private let lock = NSLock()
        private var value: TimeInterval = 20_000
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    /// The torrent, as the remux sees it: which bytes of the file are on disk.
    private final class FakeTorrent {
        private let lock = NSLock()
        private var ranges: [Range<Int64>] = []
        let size: Int64
        let bounded: Bool

        init(size: Int, bounded: Bool) {
            self.size = Int64(size)
            self.bounded = bounded
        }

        func add(_ range: Range<Int>) {
            lock.lock(); defer { lock.unlock() }
            ranges.append(Int64(range.lowerBound)..<Int64(range.upperBound))
        }

        func firstMissing(from offset: Int64) -> Int64 {
            lock.lock(); defer { lock.unlock() }
            var position = offset
            while position < size, let range = ranges.first(where: { $0.contains(position) }) { position = range.upperBound }
            return min(position, size)
        }

        var view: RemuxTorrentView {
            RemuxTorrentView(setReadPosition: { _ in },
                             firstMissingOffset: { self.firstMissing(from: $0) },
                             fileSize: { self.size },
                             isBounded: { self.bounded },
                             totalProgress: { self.firstMissing(from: 0) >= self.size ? 1 : 0.5 },
                             isFileComplete: { self.firstMissing(from: 0) >= self.size })
        }
    }

    private struct Rig {
        let remux: RemuxPlayback
        let torrent: FakeTorrent
        let input: URL
    }

    /// Ten minutes of HEVC Main 10 + E-AC-3: a hundred 6 s segments, a Cluster per second, the
    /// keyframe index at the front.
    private static let layout = RemuxTestStreams.make {
        $0.clusterCount = 600
        $0.videoCodec = .hevc
        $0.audioCodec = .eac3
        $0.videoFrameBytes = 600
        $0.cues = .front
    }.layout()

    private let clock = Clock()
    private var rigs: [Rig] = []

    override func setUp() {
        super.setUp()
        let clock = self.clock
        RemuxPlayback.uptimeProvider = { clock.now }
        RemuxPlayback.freeSpaceProvider = { _ in 1 << 42 }
    }

    override func tearDown() {
        rigs.forEach { $0.remux.stop(); $0.remux.runTick(timer: false) }
        rigs = []
        RemuxPlayback.uptimeProvider = nil
        RemuxPlayback.freeSpaceProvider = nil
        super.tearDown()
    }

    /// The bytes of Clusters `clusters` (0: from the file's start; 600: to its end).
    private func bytes(_ clusters: Range<Int>) -> Range<Int> {
        let offsets = Self.layout.clusterOffsets
        let lower = clusters.lowerBound <= 0 ? 0 : offsets[min(clusters.lowerBound, offsets.count - 1)]
        let upper = clusters.upperBound >= offsets.count ? Self.layout.data.count : offsets[clusters.upperBound]
        return lower..<max(lower, upper)
    }

    /// A RemuxPlayback over the film, of which the torrent has Clusters `clusters` so far.
    private func rig(have clusters: [Range<Int>], bounded: Bool) -> Rig? {
        let ranges = clusters.map { bytes($0) }
        guard let files = temporaryInput(Self.holed(Self.layout.data, keeping: ranges)) else { return nil }
        let torrent = FakeTorrent(size: Self.layout.data.count, bounded: bounded)
        ranges.forEach { torrent.add($0) }
        let remux = RemuxPlayback(localFile: files.input, streamer: nil)
        remux.torrentOverride = torrent.view
        remux.startsTicksOnDemand = false
        remux.allowsNativeJumps = true
        let made = Rig(remux: remux, torrent: torrent, input: files.input)
        rigs.append(made)
        return made
    }

    private func download(_ rig: Rig, _ clusters: Range<Int>) {
        let range = bytes(clusters)
        fill(rig.input, from: Self.layout.data, range)
        rig.torrent.add(range)
    }

    private func tick(_ rig: Rig, _ count: Int = 1) {
        for _ in 0..<count {
            clock.advance(1)
            rig.remux.runTick()
        }
    }

    private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 3) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return condition()
    }

    private func floorIsNeverDownloaded(_ rig: Rig) -> Bool {
        BoundedStorageSession.remuxRewindFloorIsNeverWritten(rig.remux)
    }

    // MARK: The floor a native resume leaves

    func testTheFloorOfANativeResumeIsAPartNeverDownloaded() {
        // Bounded storage; the head (40 s) and the Clusters around 70 % of the film are there.
        guard let rig = rig(have: [0..<40, 418..<446], bounded: true) else { return }
        check(!floorIsNeverDownloaded(rig), "nothing converted yet: no floor")
        rig.remux.prepareResume(atFraction: 0.705)
        tick(rig, 2)
        guard rig.remux.session != nil else { return check(false, "the session opens") }
        eq(rig.remux.resumeReadiness, .native, "the resume at 70 % is native")
        check(!floorIsNeverDownloaded(rig), "while the question is up nobody reported a position: no floor to speak of")

        // « Resume at … »: the conversion jumps to segment 70; what it skipped was never written.
        rig.remux.commitResume()
        tick(rig)
        guard let session = rig.remux.session else { return check(false, "the session is there") }
        check(session.hasJumped, "the pass jumped")
        eq(rig.remux.boundedSnapshot()?.wanted, rig.remux.resumeTargetSeconds, "the position wanted is the resume point (the start lock)")
        check(floorIsNeverDownloaded(rig), "before playback ran there: the floor of the resume point is what the jump skipped")

        // Playback runs there: the jump is committed, the skipped segments are given up.
        rig.remux.updatePlaybackPositions(played: 421, wanted: 421.5)
        tick(rig)
        check(!rig.remux.prunedIndexes.isEmpty && rig.remux.holeIndexes.isEmpty, "committed: what was skipped is gone for good")
        let floor = rig.remux.earliestNativeRewindSeconds(fromPlayerSeconds: 421) ?? -1
        eq(floor, session.jumpTarget(forSegment: 70)?.playerStartSeconds, "a rewind from there stops at the resume point's segment")
        check(floorIsNeverDownloaded(rig), "and that floor was never downloaded: « This part hasn't been downloaded »")
        // A hand-off to VLC in that first segment reads from its own Cluster, not the skipped one's.
        if let snapshot = rig.remux.boundedSnapshot(), let start = session.jumpTarget(forSegment: 70)?.playerStartSeconds {
            check(snapshot.neverWritten.contains(69) && !snapshot.neverWritten.contains(70),
                  "the snapshot knows what the jump skipped", "\(snapshot.neverWritten.rangeView.map { "\($0)" })")
            eq(BoundedStorage.remuxHandOffSourceOffset(segment: 70, secondsIntoSegment: 421 + 2.5 - start,
                                                       segmentSourceOffsets: snapshot.segmentSourceOffsets,
                                                       neverWritten: snapshot.neverWritten),
               snapshot.segmentSourceOffsets[70], "a hand-off inside the resume's segment reads from its own Cluster")
        } else {
            check(false, "the snapshot and the resume's segment are there")
        }

        // Further on in the same run: the same floor, the same message.
        download(rig, 446..<500)
        rig.remux.updatePlaybackPositions(played: 440, wanted: 441)
        tick(rig, 3)
        check(floorIsNeverDownloaded(rig), "twenty seconds later: still the edge of what the jump skipped")
        // A report without a played position (a recovery waiting): the wanted one is the reference.
        rig.remux.updatePlaybackPositions(played: nil, wanted: 441)
        check(floorIsNeverDownloaded(rig), "from the position the player needs, when none was played")
        // The head's own run starts at 0:00: no floor below it.
        rig.remux.updatePlaybackPositions(played: 20, wanted: 20)
        check(!floorIsNeverDownloaded(rig), "the head's run goes down to 0:00: nothing skipped below it")
    }

    // MARK: The floor the disk budget makes

    func testTheFloorOfTheDiskBudgetIsDeletedMedia() {
        // The film played in file order, to its end, then the disk fills up.
        guard let rig = rig(have: [0..<16], bounded: false) else { return }
        tick(rig, 2)
        var position = 0.0
        var cluster = 16
        while position < 600 {
            if cluster < 600 {
                download(rig, cluster..<min(600, cluster + 120))
                cluster += 120
            }
            rig.remux.updatePlaybackPositions(played: position, wanted: position)
            tick(rig, 2)
            position += 60
        }
        tick(rig, 5)
        check(rig.remux.isFinished && rig.remux.session?.hasJumped == false, "converted to the end without a jump")
        check(!floorIsNeverDownloaded(rig), "everything is on disk: no floor")

        RemuxPlayback.freeSpaceProvider = { _ in 0 }
        clock.advance(11)
        rig.remux.updatePlaybackPositions(played: 500, wanted: 500)
        check(waitUntil { rig.remux.prunedIndexes.count >= 40 }, "the budget evicted the head", "\(rig.remux.prunedIndexes.count)")
        let floor = rig.remux.earliestNativeRewindSeconds(fromPlayerSeconds: 500) ?? -1
        check(floor > 200 && floor < 500, "a rewind stops where the kept media starts", "\(floor)")
        check(!floorIsNeverDownloaded(rig), "that floor is media that was written, then deleted: « This part is no longer stored »")
        RemuxPlayback.freeSpaceProvider = { _ in 1 << 42 }
    }
}
