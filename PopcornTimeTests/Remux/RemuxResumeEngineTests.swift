//
//  RemuxResumeEngineTests.swift
//  PopcornTimeTests
//
//  RemuxPlayback's native jumps, on the real engine: a RemuxPlayback over a synthetic film
//  whose file is a torrent's — preallocated, only some of its bytes there, more arriving —
//  with a stand-in for the torrent (`RemuxTorrentView`) that knows which bytes are on disk and
//  records where it is told to download. No server and no timer: the test makes the ticks,
//  on a clock it moves. What is checked: the prepared resume (the torrent is turned to the
//  resume point in both storage modes, only once segments 0 and 1 are written), the accepted
//  resume (the jump, its first segment — the bytes a conversion in file order writes there),
//  « from the beginning », the start lock, holes (a request held then served, a stale one
//  that moves nothing, the disk budget that neither counts nor evicts them), the end of the
//  film written without the head, the provisional jump of bounded storage (committed,
//  undone), and what is left when the session can't jump any more. And that with native jumps
//  switched off, or simply never needed, the conversion is the one in file order.
//

import XCTest
import Foundation
import GCDWebServer

final class RemuxResumeEngineTests: RemuxSessionTestCase {

    // MARK: The rig

    /// The clock of every rule of the engine (`RemuxPlayback.uptimeProvider`).
    private final class Clock {
        private let lock = NSLock()
        private var value: TimeInterval = 10_000
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    /// The torrent, as the remux sees it: which bytes of the file are on disk, and where it
    /// was told to download.
    private final class FakeTorrent {
        private let lock = NSLock()
        private var ranges: [Range<Int64>] = []
        private var positions: [Int64] = []
        let size: Int64
        var bounded = false

        init(size: Int, have: [Range<Int>]) {
            self.size = Int64(size)
            have.forEach { add($0) }
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

        var readPositions: [Int64] { lock.lock(); defer { lock.unlock() }; return positions }

        /// (The closures keep the torrent alive as long as the remux has them.)
        var view: RemuxTorrentView {
            RemuxTorrentView(setReadPosition: { offset in self.lock.lock(); self.positions.append(offset); self.lock.unlock() },
                             firstMissingOffset: { self.firstMissing(from: $0) },
                             fileSize: { self.size },
                             isBounded: { self.bounded },
                             // The share of the file that is there: never 1 while a byte is missing.
                             totalProgress: { self.firstMissing(from: 0) >= self.size ? 1 : 0.5 },
                             isFileComplete: { self.firstMissing(from: 0) >= self.size })
        }
    }

    private struct Rig {
        let remux: RemuxPlayback
        let torrent: FakeTorrent
        let input: URL
        let layout: SyntheticMatroska.Layout
        var session: MKVToHLSRemuxSession { remux.session! }
    }

    /// What a held or answered request got.
    private final class Answer {
        private let lock = NSLock()
        private var responses: [GCDWebServerResponse?] = []
        func record(_ response: GCDWebServerResponse?) { lock.lock(); responses.append(response); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return responses.count }
        var status: Int? { lock.lock(); defer { lock.unlock() }; return (responses.first ?? nil)?.statusCode }
    }

    private let clock = Clock()
    private var rigs: [Rig] = []

    /// Ten minutes of HEVC Main 10 + E-AC-3 (the user's kind of film, in small): a hundred 6 s
    /// segments, a Cluster per second, the keyframe index at the front.
    private static let film: SyntheticMatroska = RemuxTestStreams.make {
        $0.clusterCount = 600
        $0.videoCodec = .hevc
        $0.audioCodec = .eac3
        $0.videoFrameBytes = 600
        $0.cues = .front
    }
    private static let filmLayout = film.layout()
    /// The same film converted in file order by a session alone (the files, by name).
    private static var inOrder: [String: Data] = [:]

    override func setUp() {
        super.setUp()
        let clock = self.clock
        RemuxPlayback.uptimeProvider = { clock.now }
        RemuxPlayback.freeSpaceProvider = { _ in 1 << 42 }
    }

    override func tearDown() {
        // Stopped, and whatever tick was under way is over.
        rigs.forEach { $0.remux.stop(); $0.remux.runTick(timer: false) }
        rigs = []
        RemuxPlayback.uptimeProvider = nil
        RemuxPlayback.freeSpaceProvider = nil
        super.tearDown()
    }

    /// The bytes of Clusters `clusters` (0: from the file's start — header and index —, 600:
    /// to its end).
    private func bytes(_ layout: SyntheticMatroska.Layout, _ clusters: Range<Int>) -> Range<Int> {
        let offsets = layout.clusterOffsets
        let lower = clusters.lowerBound <= 0 ? 0 : offsets[min(clusters.lowerBound, offsets.count - 1)]
        let upper = clusters.upperBound >= offsets.count ? layout.data.count : offsets[clusters.upperBound]
        return lower..<max(lower, upper)
    }

    /// A RemuxPlayback over the film, of which the torrent has Clusters `have` so far.
    private func rig(have clusters: [Range<Int>], stream: SyntheticMatroska? = nil, bounded: Bool = false, jumps: Bool = true,
                     file: StaticString = #filePath, line: Int = #line) -> Rig? {
        let layout = stream?.layout() ?? Self.filmLayout
        let ranges = clusters.map { bytes(layout, $0) }
        guard let files = temporaryInput(Self.holed(layout.data, keeping: ranges), file: file, line: line) else { return nil }
        let torrent = FakeTorrent(size: layout.data.count, have: ranges)
        torrent.bounded = bounded
        let remux = RemuxPlayback(localFile: files.input, streamer: nil)
        remux.torrentOverride = torrent.view
        remux.startsTicksOnDemand = false
        remux.allowsNativeJumps = jumps
        let made = Rig(remux: remux, torrent: torrent, input: files.input, layout: layout)
        rigs.append(made)
        return made
    }

    /// Pieces arrive: Clusters `clusters` are written to the file and known to the torrent.
    private func download(_ rig: Rig, _ clusters: Range<Int>) {
        let range = bytes(rig.layout, clusters)
        fill(rig.input, from: rig.layout.data, range)
        rig.torrent.add(range)
    }

    /// `count` timer ticks, a second apart.
    private func tick(_ rig: Rig, _ count: Int = 1) {
        for _ in 0..<count {
            clock.advance(1)
            rig.remux.runTick()
        }
    }

    /// Lets the callbacks sent to the main queue run.
    private func drainMain() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 3) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return condition()
    }

    private func request(_ rig: Rig, _ name: String) -> Answer {
        let answer = Answer()
        rig.remux.handleMediaRequest(name: name, byteRange: nil) { answer.record($0) }
        return answer
    }

    private func exists(_ rig: Rig, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: rig.remux.outputDirectory.appendingPathComponent(name).path)
    }

    /// The film converted in file order by a session alone, once.
    private func reference() -> [String: Data] {
        if Self.inOrder.isEmpty, let opened = open(Self.film) {
            convertInOrder(opened)
            Self.inOrder = files(in: opened.output)
        }
        return Self.inOrder
    }

    /// The saved position of most tests: 423 s of 600, in segment 70 (420…426 s).
    private static let seventyPercent: Float = 0.705

    /// A rig whose torrent has the head (segments 0 and 1, no more) and the Clusters around
    /// 70 % of the film; a resume prepared there and found native. The pass is at segment 2.
    private func preparedAtSeventyPercent(bounded: Bool = false, head: Range<Int> = 0..<16, stream: SyntheticMatroska? = nil,
                                          file: StaticString = #filePath, line: Int = #line) -> Rig? {
        guard let rig = rig(have: [head, 418..<446], stream: stream, bounded: bounded, file: file, line: line) else { return nil }
        rig.remux.prepareResume(atFraction: Self.seventyPercent)
        tick(rig, 2)
        guard rig.remux.session != nil else {
            check(false, "the session opens", file: file, line: line)
            return nil
        }
        eq(rig.remux.resumeReadiness, .native, "the resume at 70 % is native", file: file, line: line)
        return rig
    }

    // MARK: The prepared resume

    func testTheTorrentIsTurnedToTheResumePointOnlyOnceSegments0And1AreWritten() {
        for bounded in [false, true] {
            let mode = bounded ? "bounded" : "full"
            // The head arrives slowly: four seconds of film, then eight, then sixteen.
            guard let rig = rig(have: [0..<4, 418..<446], bounded: bounded) else { return }
            var readiness: [NativeResumeReadiness] = []
            rig.remux.onResumeReadinessChanged = { readiness.append($0) }
            rig.remux.prepareResume(atFraction: Self.seventyPercent)
            tick(rig, 2)
            eq(rig.remux.resumeReadiness, .pending, "\(mode): nothing is known before the first segment")
            eq(rig.session.progress.segmentsWritten, 0, "\(mode): four seconds are no segment")
            download(rig, 4..<8)
            tick(rig, 10)
            eq(rig.session.progress.segmentsWritten, 1, "\(mode): segment 0")
            eq(rig.session.jumpCapability, .available, "\(mode): the session knows it can jump")
            eq(rig.remux.resumeReadiness, .pending,
               "\(mode): but segment 1 is not written: still pending — twelve seconds in, a slow head is no reason for VLC")
            eq(rig.remux.resumeTargetSeconds, nil, "\(mode): no target yet")
            let before = rig.torrent.readPositions
            if bounded {
                check(!before.isEmpty && before.allSatisfy { $0 > 0 && $0 <= Int64(rig.layout.clusterOffsets[8]) },
                      "bounded: so far the torrent follows the head's reader, as before", "\(before)")
            } else {
                eq(before, [], "full: the torrent was told nothing so far")
            }
            download(rig, 8..<16)
            tick(rig)
            drainMain()
            eq(rig.session.progress.segmentsWritten, 2, "\(mode): segments 0 and 1")
            eq(rig.remux.resumeReadiness, .native, "\(mode): the resume is native")
            eq(readiness, [.native], "\(mode): the owner hears it once, on the main queue")
            let seconds = rig.remux.resumeTargetSeconds ?? -1
            check(abs(seconds - 423) < 0.01, "\(mode): 70.5 % of ten minutes", "\(seconds)")
            guard let target = rig.session.jumpTarget(forPlayerSeconds: seconds) else { return check(false, "\(mode): the target is known") }
            eq(target.segment, 70, "\(mode): segment 70")
            eq(target.readOffset, Int64(rig.layout.clusterOffsets[420]), "\(mode): read from the Cluster of its keyframe (E-AC-3: no lead-in)")
            eq(rig.torrent.readPositions.last, target.readOffset, "\(mode): the torrent is turned to the resume point")
            tick(rig, 3)
            let after = rig.torrent.readPositions.dropFirst(before.count)
            check(after.count == 4 && after.allSatisfy { $0 == target.readOffset }, "\(mode): and stays there while the question is up", "\(Array(after))")
            eq(rig.session.progress.segmentsWritten, 2, "\(mode): nothing is written at the resume point before the answer")
            check(!rig.session.hasJumped && rig.remux.holeIndexes.isEmpty && !rig.remux.isJumpWaiting, "\(mode): and the pass has not moved")
            eq(rig.remux.boundedSnapshot()?.readerOffset, rig.session.consumedInputOffset, "\(mode): nothing is held back for it")
        }
    }

    func testAResumeInsideWhatTheHeadPassWroteNeedsNoSteering() {
        guard let rig = rig(have: [0..<60]) else { return }
        rig.remux.prepareResume(atFraction: 0.035)   // 21 s: segment 3
        tick(rig, 2)
        check(rig.session.progress.segmentsWritten >= 8, "the head pass wrote past the resume point", "\(rig.session.progress.segmentsWritten)")
        eq(rig.remux.resumeReadiness, .native, "native")
        eq(rig.torrent.readPositions, [], "nothing to turn the torrent to")
        rig.remux.commitResume()
        tick(rig)
        check(!rig.session.hasJumped && !rig.remux.isJumpWaiting, "and no jump to make: its segment exists")
        check(rig.remux.hasMedia(fromPlayerSeconds: 21), "the media is there")
        check(abs((rig.remux.resumeTargetSeconds ?? 0) - 21) < 0.01, "21 s", "\(rig.remux.resumeTargetSeconds ?? -1)")
        eq(rig.remux.boundedSnapshot()?.wanted, rig.remux.resumeTargetSeconds, "the position wanted is the resume point all the same")
    }

    func testTheReadinessIsVLCOnlyWhenTheFileCannotBeJumpedIn() {
        // No keyframe index.
        var noIndex = Self.film
        noIndex.cues = .none
        guard let plain = rig(have: [0..<16], stream: noIndex) else { return }
        var heard: [NativeResumeReadiness] = []
        plain.remux.onResumeReadinessChanged = { heard.append($0) }
        plain.remux.prepareResume(atFraction: Self.seventyPercent)
        tick(plain, 3)
        drainMain()
        guard case .vlcOnly(let reason) = plain.remux.resumeReadiness else { return check(false, "no index: VLC only", "\(plain.remux.resumeReadiness)") }
        check(!reason.isEmpty && heard == [.vlcOnly(reason)], "the owner hears why", reason)
        eq(plain.torrent.readPositions, [], "and nothing is steered")
        plain.remux.commitResume()
        tick(plain, 2)
        check(!plain.session.hasJumped && plain.remux.boundedSnapshot()?.wanted == nil, "« Resume at » is not the remux's to serve: nothing moves")

        // The index is not read in time: the first bytes take ten seconds to come.
        guard let slow = rig(have: [418..<446]) else { return }
        slow.remux.prepareResume(atFraction: Self.seventyPercent)
        tick(slow, 7)
        eq(slow.remux.resumeReadiness, .pending, "seven seconds: still pending")
        tick(slow, 2)
        guard case .vlcOnly(let late) = slow.remux.resumeReadiness else { return check(false, "eight seconds without knowing: VLC only") }
        check(late.contains("8 s"), "the reason says so", late)
        download(slow, 0..<16)
        tick(slow, 3)
        check(slow.remux.resumeReadiness == .vlcOnly(late) && slow.torrent.readPositions.isEmpty, "the answer does not change afterwards")

        // The index points at something that is not a Cluster at the resume point: found out
        // while the question is up, as soon as those bytes are there.
        var wrong = Self.film
        wrong.cueOffsetErrors = [420: 7]
        guard let probed = rig(have: [0..<16], stream: wrong) else { return }
        probed.remux.prepareResume(atFraction: Self.seventyPercent)
        tick(probed, 2)
        eq(probed.remux.resumeReadiness, .native, "nothing says the index is wrong before the bytes are there")
        let steered = probed.torrent.readPositions.last ?? -1
        check(steered > Int64(probed.layout.clusterOffsets[400]), "the torrent is turned there", "\(steered)")
        download(probed, 418..<446)
        tick(probed)
        guard case .vlcOnly(let found) = probed.remux.resumeReadiness else { return check(false, "the probe finds out") }
        check(found.contains("Cluster"), "and says what", found)
        check((probed.torrent.readPositions.last ?? -1) <= Int64(probed.layout.clusterOffsets[16]), "the torrent goes back to the head",
              "\(probed.torrent.readPositions.suffix(2))")
        let count = probed.torrent.readPositions.count
        tick(probed, 2)
        eq(probed.torrent.readPositions.count, count, "full mode: and is told nothing more")
    }

    // MARK: The accepted resume

    /// What a player waits for before it makes its item at a position the conversion jumped
    /// to (run E6 of the end-to-end matrix: an item made before gave up on the held segment
    /// after 5.84 s and never played again): two segments there, as at 0:00 — not just the
    /// first one, whatever the position inside it.
    func testMediaToStartAtAJumpIsTwoSegmentsThere() {
        // The torrent has the head and, at 70 %, just enough to cut segment 70 (Clusters 420…425
        // and the keyframe that ends it).
        guard let rig = rig(have: [0..<16, 418..<427]) else { return }
        rig.remux.prepareResume(atFraction: Self.seventyPercent)
        tick(rig, 2)
        eq(rig.remux.resumeReadiness, .native, "the resume at 70 % is native")
        guard let target = rig.remux.resumeTargetSeconds else { return check(false, "the resume point is known") }
        check(!rig.remux.hasMediaToStart(fromPlayerSeconds: target), "before the answer nothing is written there")
        rig.remux.commitResume()
        tick(rig)
        drainMain()
        eq(rig.session.progress.segmentsWritten, 71, "the jump wrote segment 70, and no more: the torrent has no more")
        check(rig.remux.hasMedia(fromPlayerSeconds: target, cushion: 0), "the segment of the resume point is on disk")
        check(!rig.remux.hasMediaToStart(fromPlayerSeconds: target), "one segment is not media to start on")
        check(!rig.remux.hasMediaToStart(fromPlayerSeconds: 420), "nor from that segment's very first instant")
        check(!rig.remux.hasMediaToStart(fromPlayerSeconds: 425.9), "nor from its last")
        // The next pieces arrive: segment 71.
        download(rig, 427..<433)
        tick(rig)
        eq(rig.session.progress.segmentsWritten, 72, "segment 71 is written")
        check(rig.remux.hasMediaToStart(fromPlayerSeconds: target), "two segments at the resume point: the player makes its item")
        check(rig.remux.hasMediaToStart(fromPlayerSeconds: 420) && rig.remux.hasMediaToStart(fromPlayerSeconds: 425.9),
              "from anywhere in the first of them")
        check(!rig.remux.hasMediaToStart(fromPlayerSeconds: 426), "not from the second: the third is not written")
        check(!rig.remux.hasMediaToStart(fromPlayerSeconds: 200), "never in a hole")
        check(rig.remux.hasMediaToStart(fromPlayerSeconds: 0), "at 0:00 the first two segments are the same rule")
        check(!rig.remux.hasMediaToStart(fromPlayerSeconds: 6), "segment 1 alone (segment 2 is a hole) is not")
        check(!rig.remux.hasMediaToStart(fromPlayerSeconds: .nan), "no position, no media")
    }

    func testCommitJumpsAndTheFirstSegmentIsTheOneWrittenInFileOrder() {
        guard let rig = preparedAtSeventyPercent() else { return }
        var states: [RemuxPlayback.JumpState] = []
        rig.remux.onJumpStateChanged = { states.append($0) }
        let target = rig.session.jumpTarget(forSegment: 70)
        rig.remux.commitResume()
        eq(rig.remux.boundedSnapshot()?.wanted, rig.remux.resumeTargetSeconds, "from the answer on, the position wanted is the resume point")
        tick(rig)
        drainMain()
        check(rig.session.hasJumped, "the pass jumped at the next tick")
        eq(rig.remux.holeIndexes, IndexSet(integersIn: 2..<70), "what it skipped are holes")
        eq(rig.remux.prunedIndexes, IndexSet(), "not pruned segments")
        let written = rig.session.progress.segmentsWritten
        check(written >= 72 && rig.session.nextSegmentIndex == written, "it wrote the first segments there in the same tick", "\(written)")
        eq(states, [.waiting(playerSeconds: rig.remux.resumeTargetSeconds ?? -1)], "the owner hears that it waits, with the position")
        check(rig.remux.isJumpWaiting, "a jump somebody waits on")
        check(rig.torrent.readPositions.contains(target?.readOffset ?? -1), "the torrent is told where the pass reads")
        tick(rig)
        eq(rig.torrent.readPositions.last, rig.session.consumedInputOffset, "then follows its reader, in full mode too")

        // The segments are the ones a conversion in file order writes there.
        let expected = reference()
        let got = files(in: rig.remux.outputDirectory)
        for name in ["vseg70.m4s", "a0seg70.m4s", "vseg71.m4s", "a0seg71.m4s"] {
            check(got[name] != nil && got[name] == expected[name], "\(name) is byte-identical to the one written in file order")
        }
        for name in ["video.m3u8", "audio0.m3u8"] {
            eq(rig.session.mediaPlaylist(named: name), playlistsInOrder()[name], "\(name) is the list of the conversion in file order")
        }
        check(got["vseg2.m4s"] == nil && got["vseg69.m4s"] == nil, "nothing was written for the holes")

        // What exists, what does not.
        check(rig.remux.hasMedia(fromPlayerSeconds: 423), "media at the resume point")
        check(!rig.remux.hasMedia(fromPlayerSeconds: 200), "none in a hole — the frontier alone would have said yes")
        check(rig.remux.hasMedia(fromPlayerSeconds: 0), "the first two segments are there")
        check(!rig.remux.hasMedia(fromPlayerSeconds: 5, cushion: 10), "but not 10 s of media from 5 s (segment 2 is a hole)")
        check(!rig.remux.hasMedia(fromPlayerSeconds: 440, cushion: 30), "nor 30 s from 440 s: the frontier")
        check(rig.remux.isAvailable(playerSeconds: 200), "a hole is not « gone for good »")
        eq(rig.remux.earliestNativeRewindSeconds(fromPlayerSeconds: 425), rig.session.jumpTarget(forSegment: 70)?.playerStartSeconds,
           "a rewind from there reaches the start of the jump's first segment without a hole")
        eq(rig.remux.earliestNativeRewindSeconds(fromPlayerSeconds: 200), nil, "a hole has no media of its own")
        check(!rig.remux.isFinished, "not finished")

        // Playback runs there: the wait is over.
        rig.remux.updatePlaybackPositions(played: 421, wanted: 421.5)
        drainMain()
        eq(states.last, .landed(playerSeconds: 421), "landed")
        check(!rig.remux.isJumpWaiting, "nobody waits any more")
    }

    private var cachedPlaylists: [String: String] = [:]
    /// The playlists of the conversion in file order.
    private func playlistsInOrder() -> [String: String] {
        if cachedPlaylists.isEmpty, let opened = open(Self.film) {
            produce(opened.session, 2)
            cachedPlaylists = playlists(opened.session)
        }
        return cachedPlaylists
    }

    func testCommitBeforeTheReadinessIsKnownIsTakenWhenItIsNative() {
        guard let rig = rig(have: [0..<4, 418..<446]) else { return }
        rig.remux.prepareResume(atFraction: Self.seventyPercent)
        tick(rig)
        rig.remux.commitResume()     // a decided start: no question to wait for
        tick(rig)
        check(!rig.session.hasJumped, "nothing to jump to yet")
        download(rig, 4..<16)
        tick(rig, 2)
        eq(rig.remux.resumeReadiness, .native, "native")
        check(rig.session.hasJumped && rig.remux.holeIndexes == IndexSet(integersIn: 2..<70), "and the jump was made at once")
        check(exists(rig, "vseg70.m4s"), "segment 70 is written")
    }

    func testFromTheBeginningTurnsTheTorrentBackToTheHead() {
        for bounded in [false, true] {
            let mode = bounded ? "bounded" : "full"
            guard let rig = preparedAtSeventyPercent(bounded: bounded) else { return }
            let target = rig.session.jumpTarget(forSegment: 70)?.readOffset ?? -1
            eq(rig.torrent.readPositions.last, target, "\(mode): turned to the resume point")
            rig.remux.cancelResume()
            rig.remux.runTick(timer: false)     // after what the answer queued
            let reader = rig.session.consumedInputOffset
            check(reader > 0 && reader <= Int64(rig.layout.clusterOffsets[16]), "\(mode): the pass reads the head", "\(reader)")
            eq(rig.torrent.readPositions.last, reader, "\(mode): the torrent is turned back to it")
            let count = rig.torrent.readPositions.count
            tick(rig, 3)
            if bounded {
                check(rig.torrent.readPositions.count == count + 3 && rig.torrent.readPositions.suffix(3).allSatisfy { $0 == reader },
                      "bounded: and follows the reader at every tick, as before")
            } else {
                eq(rig.torrent.readPositions.count, count, "full: and is told nothing more")
            }
            rig.remux.commitResume()
            rig.remux.updatePlaybackPositions(played: nil, wanted: 0)
            tick(rig, 2)
            check(!rig.session.hasJumped && rig.remux.holeIndexes.isEmpty, "\(mode): no jump afterwards, whatever is asked")
            eq(rig.remux.boundedSnapshot()?.wanted, 0, "\(mode): and no start lock: the player is at 0")
            // The film goes on from the head.
            download(rig, 16..<40)
            tick(rig, 2)
            check(rig.session.progress.segmentsWritten >= 5 && exists(rig, "vseg4.m4s"), "\(mode): the head pass goes on",
                  "\(rig.session.progress.segmentsWritten)")
        }
    }

    // MARK: The start lock

    func testTheStartLockHoldsTheResumePointAgainstAnItemLoadingAtZero() {
        guard let rig = preparedAtSeventyPercent() else { return }
        let resume = rig.remux.resumeTargetSeconds ?? -1
        rig.remux.commitResume()
        // The item is attached at once and loads at 0: it reports 0 until its seek is issued.
        rig.remux.updatePlaybackPositions(played: nil, wanted: 0)
        eq(rig.remux.boundedSnapshot()?.wanted, resume, "an item at 0 before its seek: the position wanted stays the resume point")
        tick(rig)
        check(rig.session.hasJumped && rig.session.nextSegmentIndex >= 72, "the jump is made")
        for _ in 0..<3 {
            rig.remux.updatePlaybackPositions(played: nil, wanted: 0)
            tick(rig)
        }
        check(rig.session.nextSegmentIndex >= 72 && rig.remux.isJumpWaiting, "three more reports of 0: the pass stays at the resume point")
        rig.remux.updatePlaybackPositions(played: nil, wanted: nil)
        eq(rig.remux.boundedSnapshot()?.wanted, resume, "a report without a position neither")
        // The seek is issued: the player reports the resume point. The lock is lifted.
        rig.remux.updatePlaybackPositions(played: nil, wanted: resume)
        eq(rig.remux.boundedSnapshot()?.wanted, resume, "the player's own report")
        // From now on a position near 0 is the user's: the pass goes back to the hole there.
        rig.remux.updatePlaybackPositions(played: nil, wanted: 13)
        eq(rig.remux.boundedSnapshot()?.wanted, 13, "the lock is lifted: 13 s is 13 s")
        tick(rig)
        check(rig.session.nextSegmentIndex >= 72, "seen once: not yet")
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        eq(rig.session.nextSegmentIndex, 2, "seen again 0.3 s later: the pass jumps back to segment 2, the hole at 13 s")

        // Playback having run lifts it too.
        guard let played = preparedAtSeventyPercent() else { return }
        played.remux.commitResume()
        tick(played)
        played.remux.updatePlaybackPositions(played: 5, wanted: 5)
        eq(played.remux.boundedSnapshot()?.wanted, 5, "a position that was played: no lock")
    }

    // MARK: Holes

    func testARequestForAHoleIsHeldThenServedAndAStaleOneMovesNothing() {
        guard let rig = preparedAtSeventyPercent() else { return }
        rig.remux.commitResume()
        tick(rig)
        rig.remux.updatePlaybackPositions(played: 421, wanted: 421)
        let served = request(rig, "vseg70.m4s")
        eq(served.status, 200, "a segment written after the jump is served")

        // AVPlayer asks again for a segment of the position it left (it does).
        let stale = request(rig, "vseg30.m4s")
        eq(stale.count, 0, "a request for a hole is held, not answered 404")
        eq(rig.remux.heldRequestCount, 1, "held")
        let cursor = rig.session.nextSegmentIndex
        for _ in 0..<4 {
            rig.remux.updatePlaybackPositions(played: 421, wanted: 421)
            tick(rig)
        }
        eq(rig.session.nextSegmentIndex, cursor, "four ticks later the pass has not moved: a request alone decides nothing")
        check(stale.count == 0 && rig.remux.heldRequestCount == 1, "and the request is still held")
        check(rig.remux.holeIndexes.contains(30), "segment 30 is still a hole")

        // The player itself goes there: the pass jumps back, and the request is served as soon
        // as the bytes are.
        rig.remux.updatePlaybackPositions(played: 421, wanted: 181)
        tick(rig)
        eq(rig.session.nextSegmentIndex, cursor, "the position is seen once: not yet")
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        eq(rig.session.nextSegmentIndex, 30, "seen again 0.3 s later: the pass is at segment 30")
        check(rig.torrent.readPositions.last == rig.session.jumpTarget(forSegment: 30)?.readOffset, "and the torrent is turned there")
        eq(stale.count, 0, "its bytes are not there: still held")
        download(rig, 176..<200)
        tick(rig)
        check(waitUntil { stale.count == 1 }, "the request is answered once the segment is written")
        eq(stale.status, 200, "with the segment")
        let got = files(in: rig.remux.outputDirectory)
        check(got["vseg30.m4s"] != nil && got["vseg30.m4s"] == reference()["vseg30.m4s"], "which is the one written in file order")
        check(!rig.remux.holeIndexes.contains(30) && rig.remux.holeIndexes.contains(29), "30 is no hole any more, 29 still is")
        eq(rig.remux.earliestNativeRewindSeconds(fromPlayerSeconds: 185), rig.session.jumpTarget(forSegment: 30)?.playerStartSeconds,
           "a rewind from there stops at the hole before it")
    }

    func testTheDiskBudgetNeitherCountsNorEvictsHoles() {
        // The head pass wrote segments 0…5 before the answer.
        guard let rig = preparedAtSeventyPercent(head: 0..<40) else { return }
        eq(rig.session.progress.segmentsWritten, 6, "six segments from the head")
        rig.remux.commitResume()
        tick(rig)
        let holes = rig.remux.holeIndexes
        eq(holes, IndexSet(integersIn: 6..<70), "the holes")
        // The output rate is measured on what exists: the holes' planned seconds don't divide it.
        let bytes = rig.session.segmentBytes()
        let durations = rig.session.segmentDurations()
        let existing = (0..<bytes.count).filter { !holes.contains($0) }
        let real = Double(existing.reduce(Int64(0)) { $0 + bytes[$1] }) / existing.reduce(0.0) { $0 + durations[$1] }
        let diluted = RemuxPlayback.outputBytesPerSecond(segmentBytes: bytes, durations: durations) ?? 0
        let measured = RemuxPlayback.outputBytesPerSecond(segmentBytes: bytes, durations: durations, excluding: holes) ?? 0
        check(abs(measured - real) < 1 && diluted < real / 5, "the rate without the holes is the real one (with them, a tenth)",
              "real \(Int(real)), measured \(Int(measured)), diluted \(Int(diluted))")
        // The budget's own measure, taken again with the holes there (it is every 10 s).
        clock.advance(11)
        tick(rig)
        let snapshot = rig.remux.boundedSnapshot()
        check(abs((snapshot?.outputBytesPerSecond ?? 0) - real) < real / 50, "what the disk budget measures, and bounded storage is told, too",
              "\(snapshot?.outputBytesPerSecond ?? 0) / \(real)")
        eq(snapshot?.pruned, holes, "which sees the holes as not on disk")
        eq(snapshot?.deletableKeptBytes, existing.filter { $0 >= 1 }.reduce(Int64(0)) { $0 + bytes[$1] }, "and counts only what is")

        // A disk with no room left for the copy: everything unprotected goes — the head's
        // segments 1…5 (playback is at the resume point) — and no hole does.
        RemuxPlayback.freeSpaceProvider = { _ in 0 }
        clock.advance(11)
        rig.remux.updatePlaybackPositions(played: 421, wanted: 421)
        tick(rig)
        check(waitUntil { rig.remux.prunedIndexes.count >= 5 }, "the budget evicted", "\(rig.remux.prunedIndexes)")
        eq(rig.remux.prunedIndexes, IndexSet(integersIn: 1...5), "the unprotected segments that exist, and only them")
        eq(rig.remux.holeIndexes, holes, "the holes are still holes: writable")
        check(waitUntil { !self.exists(rig, "vseg3.m4s") } && exists(rig, "vseg0.m4s") && exists(rig, "vseg70.m4s"), "on disk: as said")
        // A hole is held; a pruned segment behind the playhead is gone.
        eq(request(rig, "vseg30.m4s").count, 0, "a hole: held")
        eq(request(rig, "vseg3.m4s").status, 404, "a pruned segment behind what was played: 404")
    }

    // MARK: The end of the film

    func testTheEndIsWrittenWithoutTheHeadAndAHoleIsFilledAfterIt() {
        // The torrent has the head and everything from 89 % on; a resume at 90 %.
        guard let rig = rig(have: [0..<16, 534..<600]) else { return }
        rig.remux.prepareResume(atFraction: 0.905)     // 543 s: segment 90
        tick(rig, 2)
        eq(rig.remux.resumeReadiness, .native, "native")
        rig.remux.commitResume()
        tick(rig)
        check(rig.session.hasJumped && rig.remux.holeIndexes == IndexSet(integersIn: 2..<90), "the pass is at 90 %")
        rig.remux.updatePlaybackPositions(played: 541, wanted: 541)
        tick(rig, 6)
        // The file is far from complete (the whole head is missing), yet everything the pass
        // has left to read is there: the film's end is written.
        check(rig.torrent.firstMissing(from: 0) < rig.torrent.size, "the file is not complete")
        check(rig.session.isTailWritten && rig.session.progress.finished, "the end of the film is written all the same")
        eq(rig.session.progress.segmentsWritten, rig.session.expectedSegmentCount, "every listed segment is published")
        check(rig.remux.isFinished, "the remux is finished: at rest")
        eq(rig.remux.holeIndexes, IndexSet(integersIn: 2..<90), "with its holes")
        let expected = reference()
        let got = files(in: rig.remux.outputDirectory)
        let tail = got.keys.filter { RemuxPlayback.segmentIndex($0).map { $0 >= 90 } ?? false }
        check(tail.count >= 20 && tail.allSatisfy { got[$0] == expected[$0] }, "the last segments are those of the conversion in file order",
              "\(tail.count) files")
        check(rig.remux.hasMedia(fromPlayerSeconds: 595), "media up to the very end")
        check(rig.remux.hasMedia(fromPlayerSeconds: 590, cushion: 60), "nothing is missing after the end")

        // Back into a hole, after the end: the pass runs again, below the end.
        rig.remux.updatePlaybackPositions(played: 541, wanted: 61)
        tick(rig)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        eq(rig.session.nextSegmentIndex, 10, "the pass jumped back to segment 10")
        check(!rig.remux.isFinished, "not at rest any more")
        let held = request(rig, "vseg10.m4s")
        tick(rig, 4)
        // Its input is NOT complete there: the zeros are bytes still to come, not film.
        check(rig.session.jumpFailure == nil && rig.remux.failureReason == nil, "the missing bytes are not taken for data")
        check(held.count == 0 && rig.remux.holeIndexes.contains(10), "nothing is written from them: the request is held")
        download(rig, 16..<534)
        tick(rig, 2)
        check(waitUntil { held.count == 1 } && held.status == 200, "the bytes arrive: the hole is filled, the request served")
        check(files(in: rig.remux.outputDirectory)["vseg10.m4s"] == expected["vseg10.m4s"], "with the segment of the conversion in file order")

        // The player goes on through what was skipped: the pass fills it, meets the segments
        // written at 90 %, and is at rest again — the end is not written twice.
        var position = 61.0
        while position < 560 {
            rig.remux.updatePlaybackPositions(played: position, wanted: position)
            tick(rig, 2)
            position += 90
        }
        eq(rig.remux.holeIndexes, IndexSet(integersIn: 2..<10), "every hole from segment 10 on is filled")
        check(rig.remux.isFinished, "finished again")
        let all = files(in: rig.remux.outputDirectory)
        let differing = all.keys.filter { RemuxPlayback.segmentIndex($0) != nil && all[$0] != expected[$0] }
        eq(differing.sorted(), [], "every segment on disk is the one of the conversion in file order")
        eq(all.keys.filter { RemuxPlayback.segmentIndex($0) != nil }.count, expected.keys.filter { name in
            RemuxPlayback.segmentIndex(name).map { $0 < 2 || $0 >= 10 } ?? false
        }.count, "and all of them but the eight holes are there, once")
    }

    func testAFarRequestThePlayerDoesNotReportIsPumpedTowardNeverJumpedTo() {
        // Played from 0:00; the torrent has the first 200 s. The pump holds at the lookahead
        // limit of the player's position: segment 30.
        guard let rig = rig(have: [0..<200]) else { return }
        rig.remux.updatePlaybackPositions(played: 2, wanted: 2)
        tick(rig, 2)
        _ = rig.session.mediaPlaylist(named: "video.m3u8")
        tick(rig, 6)
        eq(rig.session.nextSegmentIndex, 30, "the lookahead of the player's position is written: the pump holds")
        // AVPlayer asks for a segment six minutes ahead (a seek it has given up, a prefetch);
        // the player reports nothing there.
        let far = request(rig, "vseg60.m4s")
        tick(rig, 3)
        check(!rig.session.hasJumped && rig.remux.holeIndexes.isEmpty, "a request alone: no jump, whatever is missing on the way")
        eq(rig.session.nextSegmentIndex, 33, "the pump goes toward it in file order, as far as the bytes go")
        eq(far.count, 0, "and the request is held")
        eq(rig.torrent.readPositions, [], "the torrent is told nothing")
        // The player's next report, still at the start, supersedes it: the pump holds again.
        rig.remux.updatePlaybackPositions(played: 4, wanted: 4)
        download(rig, 200..<260)
        tick(rig, 2)
        eq(rig.session.nextSegmentIndex, 33, "superseded by the player's report: nothing more is written for it")
    }

    func testOnDemandTicksMakeTheJumpsWithoutWaitingForTheTimer() {
        // The real clock, and the engine's own ticks (there is no timer here: `start()` was
        // not called): the answer starts one, a position reported in a hole schedules them.
        RemuxPlayback.uptimeProvider = nil
        guard let rig = rig(have: [0..<16, 176..<200, 418..<446]) else { return }
        rig.remux.prepareResume(atFraction: Self.seventyPercent)
        rig.remux.runTick()
        rig.remux.runTick()
        eq(rig.remux.resumeReadiness, .native, "native")
        rig.remux.startsTicksOnDemand = true
        rig.remux.commitResume()
        // (Generous deadlines on the real clock: there is no timer at all here, so ANY tick is
        // the engine's own; a loaded machine only delays them.)
        check(waitUntil({ self.exists(rig, "vseg70.m4s") }, seconds: 8), "the answer starts a tick itself: the jump is made at once")
        rig.remux.updatePlaybackPositions(played: 421, wanted: 421)
        let reported = Date()
        rig.remux.updatePlaybackPositions(played: 421, wanted: 181)     // one report, in a hole
        check(waitUntil({ self.exists(rig, "vseg30.m4s") }, seconds: 8),
              "a position reported in a hole gets its ticks: seen, seen again, jumped to")
        let took = Date().timeIntervalSince(reported)
        check(took >= 0.25, "not before the stability wait", "\(took)")
        // The design's bound is about a second after the last jump (the gate's interval); 4 s
        // leaves room for a loaded machine yet still fails an on-demand tick that waits for a
        // second gate interval or a periodic re-evaluation.
        check(took < 4, "served within the gate's interval, not seconds later", "\(took)")
        rig.remux.startsTicksOnDemand = false
    }

    // MARK: Bounded storage: the provisional jump

    func testABoundedJumpIsProvisionalThenCommittedOncePlaybackRanThere() {
        guard let rig = preparedAtSeventyPercent(bounded: true, head: 0..<40) else { return }
        let readerAtHead = rig.session.consumedInputOffset
        let offsets = rig.session.segmentSourceOffsets()
        eq(rig.session.nextSegmentIndex, 6, "the head pass is at segment 6")
        rig.remux.commitResume()
        check((rig.remux.boundedSnapshot()?.readerOffset ?? .max) <= min(readerAtHead, offsets[5]),
              "from the answer on, nothing below the head's reader is released")
        tick(rig)
        check(rig.session.hasJumped && rig.session.nextSegmentIndex >= 72, "the pass jumped")
        let reader = rig.session.consumedInputOffset
        check(reader > Int64(rig.layout.clusterOffsets[420]), "its reader is at the resume point", "\(reader)")
        // Provisional: bounded storage is told the old reader, the skipped segments stay holes.
        eq(rig.remux.boundedSnapshot()?.readerOffset, min(readerAtHead, offsets[5]), "bounded storage still sees the head's reader: nothing more is released")
        eq(rig.remux.holeIndexes, IndexSet(integersIn: 6..<70), "what was skipped is still writable")
        eq(rig.remux.prunedIndexes, IndexSet(), "nothing is given up")
        eq(rig.torrent.readPositions.last, reader, "the torrent downloads where the pass reads")
        // The player waits at the resume point: still provisional.
        rig.remux.updatePlaybackPositions(played: nil, wanted: 420.5)
        tick(rig, 2)
        check(rig.remux.prunedIndexes.isEmpty && rig.remux.boundedSnapshot()?.readerOffset == min(readerAtHead, offsets[5]), "waiting there changes nothing")
        // What bounded storage releases from that snapshot (its own rule, with no keep at all):
        // nothing above the head's floor, though the player reports 70 %.
        let floor = min(readerAtHead, offsets[5])
        let provisional = rig.remux.boundedSnapshot().flatMap { BoundedStorageSession.remuxRelease($0, keepBehindBytes: 0) }
        check(provisional.map { $0.consumedBefore <= floor } ?? false, "bounded storage deletes nothing above the head's floor",
              "\(String(describing: provisional)) / \(floor)")
        check(rig.remux.rewindFloorIsNeverWritten(fromPlayerSeconds: 425), "the floor of a rewind from there is something never written")

        // Playback runs there: committed.
        rig.remux.updatePlaybackPositions(played: 421, wanted: 421.5)
        tick(rig)
        eq(rig.remux.prunedIndexes, IndexSet(integersIn: 6..<70), "what was skipped is given up")
        eq(rig.remux.holeIndexes, IndexSet(), "no hole is left")
        eq(rig.remux.boundedSnapshot()?.readerOffset, rig.session.consumedInputOffset, "bounded storage sees the real reader again: the head is released")
        let committed = rig.remux.boundedSnapshot().flatMap { BoundedStorageSession.remuxRelease($0, keepBehindBytes: 0) }
        check(committed.map { $0.consumedBefore > floor } ?? false, "and its release goes past the head's floor",
              "\(String(describing: committed)) / \(floor)")
        check(!rig.remux.isAvailable(playerSeconds: 200), "a position before the resume point is gone for good")
        eq(rig.remux.earliestNativeRewindSeconds(fromPlayerSeconds: 425), rig.session.jumpTarget(forSegment: 70)?.playerStartSeconds,
           "a rewind stops at the resume point's segment")
        check(rig.remux.rewindFloorIsNeverWritten(fromPlayerSeconds: 425), "and what lies before it was never written (« not downloaded »)")
        check(!rig.remux.rewindFloorIsNeverWritten(fromPlayerSeconds: 20), "which is not the case of the head's own start")
        check(!rig.remux.requestJump(toPlayerSeconds: 200, reason: .requested), "an explicit jump into what is gone is refused: VLC there, as before")
        check(rig.remux.requestJump(toPlayerSeconds: 425, reason: .requested), "one to what exists is not")
        rig.remux.runTick(timer: false)
        // No way back: the player going to the head now moves nothing.
        rig.remux.updatePlaybackPositions(played: 421, wanted: 10)
        tick(rig)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        tick(rig)
        check(rig.session.nextSegmentIndex >= 72 && exists(rig, "vseg70.m4s"), "after the commit a return to the head undoes nothing")
    }

    func testABoundedJumpIsUndoneWhenThePlayerGoesBackFirst() {
        guard let rig = preparedAtSeventyPercent(bounded: true, head: 0..<40) else { return }
        var states: [RemuxPlayback.JumpState] = []
        rig.remux.onJumpStateChanged = { states.append($0) }
        let readerAtHead = rig.session.consumedInputOffset
        rig.remux.commitResume()
        tick(rig)
        let written = rig.session.progress.segmentsWritten
        check(rig.session.nextSegmentIndex == written && written >= 72 && exists(rig, "vseg70.m4s"), "the pass jumped and wrote there")
        // The item still loads at 0: the start lock, not a return.
        rig.remux.updatePlaybackPositions(played: nil, wanted: 0)
        tick(rig, 2)
        check(rig.session.nextSegmentIndex == written, "an item loading at 0 undoes nothing")
        // The seek is issued, then — before anything played there — the user goes back to 0:10.
        rig.remux.updatePlaybackPositions(played: nil, wanted: 420.2)
        // While the player is at the resume point, bounded storage deletes nothing of the head (its own rule, no keep at all).
        let release = rig.remux.boundedSnapshot().flatMap { BoundedStorageSession.remuxRelease($0, keepBehindBytes: 0) }
        check(release.map { $0.consumedBefore <= readerAtHead } ?? false, "nothing of the head is released while the jump is provisional",
              "\(String(describing: release)) / \(readerAtHead)")
        rig.remux.updatePlaybackPositions(played: nil, wanted: 10)
        tick(rig)
        check(rig.session.nextSegmentIndex == written, "seen once: not yet")
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        drainMain()
        eq(rig.session.nextSegmentIndex, 6, "seen again: the pass is back at the old frontier")
        check(!exists(rig, "vseg70.m4s") && !exists(rig, "a0seg71.m4s"), "what it wrote at the resume point is deleted")
        eq(rig.remux.holeIndexes, IndexSet(integersIn: 6..<written), "and is a hole again, like everything it had skipped")
        eq(rig.remux.prunedIndexes, IndexSet(), "nothing is lost: the head's data was kept")
        check(!rig.remux.isJumpWaiting && states.last == .landed(playerSeconds: 10), "the wait is over: the player is at 0:10", "\(states)")
        let reader = rig.session.consumedInputOffset
        check(reader <= readerAtHead && rig.torrent.readPositions.last == reader, "the torrent is turned back to the head", "\(reader) / \(readerAtHead)")
        eq(rig.remux.boundedSnapshot()?.readerOffset, reader, "and bounded storage sees the real reader")
        // The film goes on in file order, past the old frontier.
        download(rig, 40..<80)
        rig.remux.updatePlaybackPositions(played: 12, wanted: 12)
        tick(rig, 3)
        let expected = reference()
        let got = files(in: rig.remux.outputDirectory)
        check(rig.session.nextSegmentIndex >= 12, "the pass writes on from segment 6", "\(rig.session.nextSegmentIndex)")
        check((6..<12).allSatisfy { got["vseg\($0).m4s"] != nil && got["vseg\($0).m4s"] == expected["vseg\($0).m4s"] },
              "with the segments of the conversion in file order")
        // And the user can go to 70 % again: a new jump, provisional again.
        download(rig, 418..<446)
        rig.remux.updatePlaybackPositions(played: 12, wanted: 421)
        tick(rig)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        check(rig.session.nextSegmentIndex >= 70 && exists(rig, "vseg70.m4s"), "a far seek jumps there again")
        check(got["vseg70.m4s"] == nil && files(in: rig.remux.outputDirectory)["vseg70.m4s"] == expected["vseg70.m4s"], "and writes segment 70 anew, the same")
    }

    // MARK: A far seek during playback

    func testAFarSeekJumpsOnceThePositionIsStableAndANearOnePumpsThrough() {
        guard let rig = rig(have: [0..<80, 418..<446]) else { return }
        var states: [RemuxPlayback.JumpState] = []
        rig.remux.onJumpStateChanged = { states.append($0) }
        rig.remux.updatePlaybackPositions(played: 2, wanted: 2)
        tick(rig, 2)
        _ = rig.session.mediaPlaylist(named: "video.m3u8")      // AVPlayer has the playlists
        tick(rig, 2)
        let frontier = rig.session.progress.segmentsWritten
        check(frontier >= 12 && !rig.session.hasJumped, "played from 0:00: twelve segments, in file order", "\(frontier)")
        eq(rig.torrent.readPositions, [], "full mode: the torrent is told nothing")
        // A seek 30 s ahead, inside what is written: nothing to do.
        rig.remux.updatePlaybackPositions(played: 20, wanted: 50)
        tick(rig, 2)
        check(!rig.session.hasJumped, "a target that exists: no jump")
        // A seek 40 s past the frontier whose bytes are all on disk (they arrived since the
        // last tick): the pass pumps through — nothing is skipped.
        download(rig, 80..<140)
        rig.remux.updatePlaybackPositions(played: 20, wanted: 121)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        tick(rig)
        check(!rig.session.hasJumped && rig.remux.holeIndexes.isEmpty, "a near target whose way is downloaded: pumped through, no hole")
        check(exists(rig, "vseg20.m4s") && rig.session.progress.segmentsWritten >= 22, "and its segment is written", "\(rig.session.progress.segmentsWritten)")
        let pumped = rig.session.progress.segmentsWritten
        // A scrub: the position passes through 200 s, 300 s, then stops at 421 s.
        for seconds in [200.0, 300.0] {
            rig.remux.updatePlaybackPositions(played: 20, wanted: seconds)
            clock.advance(0.3)
            rig.remux.runTick(timer: false)
        }
        check(!rig.session.hasJumped, "positions a scrub passes through: no jump")
        rig.remux.updatePlaybackPositions(played: 20, wanted: 421)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        check(!rig.session.hasJumped, "where it stops, seen once: not yet")
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        drainMain()
        check(rig.session.hasJumped && exists(rig, "vseg70.m4s"), "stable for 0.3 s: the pass jumps there")
        eq(states, [.waiting(playerSeconds: 421)], "the owner hears it, with the position the player wants")
        let high = rig.session.progress.segmentsWritten
        eq(rig.remux.holeIndexes, IndexSet(integersIn: pumped..<70), "what lies between is a hole")
        check(high >= 72, "segments are written there", "\(high)")
        // Back to where playback was: its media exists, nobody waits any more, nothing moves.
        rig.remux.updatePlaybackPositions(played: 20, wanted: 21)
        drainMain()
        check(!rig.remux.isJumpWaiting && states.last == .landed(playerSeconds: 21), "the player went back to media that exists: the wait is over")
        // The player's lookahead there reaches the old frontier: the pass goes back to it.
        tick(rig, 2)
        eq(rig.session.nextSegmentIndex, pumped, "the pass is back at the old frontier: playback there goes on natively")
        check(rig.torrent.readPositions.last == rig.session.consumedInputOffset, "the torrent with it")
        drainMain()
        check(!rig.remux.isJumpWaiting && states.last == .landed(playerSeconds: 21),
              "a hole ahead of a player that plays on media: nobody waits on that jump", "\(states)")

        // A seek 60 s ahead of the pass whose bytes are NOT on disk is far too: a jump.
        rig.remux.updatePlaybackPositions(played: 40, wanted: 200)
        tick(rig)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        eq(rig.session.nextSegmentIndex, 33, "a near target whose way is not downloaded: the pass jumps to it")
        rig.remux.updatePlaybackPositions(played: 40, wanted: 41)
        tick(rig, 2)
        eq(rig.session.nextSegmentIndex, pumped, "and back")

        // requestJump: an explicit decision is taken at once.
        check(rig.remux.requestJump(toPlayerSeconds: 5, reason: .requested), "a position whose media exists: accepted (nothing to jump to)")
        rig.remux.runTick(timer: false)
        eq(rig.session.nextSegmentIndex, pumped, "and the pass does not move")
        check(!rig.remux.requestJump(toPlayerSeconds: .nan, reason: .requested), "not a position: refused")
        download(rig, 296..<320)
        rig.remux.updatePlaybackPositions(played: 20, wanted: 301)
        check(rig.remux.requestJump(toPlayerSeconds: 301, reason: .requested), "a hole: accepted")
        rig.remux.runTick(timer: false)
        drainMain()
        check(exists(rig, "vseg50.m4s"), "and the pass is sent there at once, without waiting for a stable report")
        eq(states.last, .waiting(playerSeconds: 301), "a wait, at that position")
        check(!rig.remux.requestJump(toPlayerSeconds: 301, reason: .requested) || rig.remux.isAvailable(playerSeconds: 301),
              "a position that is not pruned stays acceptable")
    }

    func testAJumpBackIsWaitedOnUntilPlaybackRunsInWhatItWrote() {
        guard let rig = preparedAtSeventyPercent() else { return }
        var states: [RemuxPlayback.JumpState] = []
        rig.remux.onJumpStateChanged = { states.append($0) }
        rig.remux.commitResume()
        tick(rig)
        rig.remux.updatePlaybackPositions(played: 421, wanted: 421.5)
        drainMain()
        check(!rig.remux.isJumpWaiting && states.last == .landed(playerSeconds: 421), "the resume landed", "\(states)")

        // The user goes back four minutes, into what the resume skipped; those bytes are not
        // there yet. The last position PLAYED is still the one before the seek — ahead of the
        // destination, where media exists: that is no landing (the player shows « Resuming
        // at … » for as long as the engine says the jump is waited on).
        rig.remux.updatePlaybackPositions(played: 425, wanted: 181)
        tick(rig)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        drainMain()
        eq(rig.session.nextSegmentIndex, 30, "the pass jumped back to segment 30")
        eq(states.last, .waiting(playerSeconds: 181), "a wait, at the position the player wants")
        for _ in 0..<3 {
            rig.remux.updatePlaybackPositions(played: 425, wanted: 181)
            tick(rig)
        }
        drainMain()
        check(rig.remux.isJumpWaiting && states.last == .waiting(playerSeconds: 181),
              "the position played before the jump back is not a landing: still waited on", "\(states)")
        check(!rig.remux.hasMedia(fromPlayerSeconds: 181), "nothing to play there yet")

        // The bytes arrive and the segments are written: still waited on until playback runs there.
        download(rig, 176..<220)
        tick(rig, 2)
        check(exists(rig, "vseg30.m4s") && rig.remux.hasMedia(fromPlayerSeconds: 181), "the hole is being filled")
        rig.remux.updatePlaybackPositions(played: 425, wanted: 181)
        drainMain()
        check(rig.remux.isJumpWaiting, "written, not played yet: still waited on")
        rig.remux.updatePlaybackPositions(played: 182, wanted: 182.5)
        drainMain()
        check(!rig.remux.isJumpWaiting && states.last == .landed(playerSeconds: 182), "playback runs in what the jump wrote: landed", "\(states)")

        // Another jump back, further — and the player returns to the resume point before it is
        // served: media exists there, beyond what is still a hole. Nobody waits any more.
        rig.remux.updatePlaybackPositions(played: 184, wanted: 61)
        tick(rig)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        drainMain()
        eq(rig.session.nextSegmentIndex, 10, "the pass jumped back to segment 10")
        check(rig.remux.isJumpWaiting && states.last == .waiting(playerSeconds: 61), "waited on")
        rig.remux.updatePlaybackPositions(played: 184, wanted: 423)
        drainMain()
        check(!rig.remux.isJumpWaiting && states.last == .landed(playerSeconds: 423),
              "the player went to media that exists outside the jump's run: the wait is over", "\(states)")
    }

    func testAShortJumpBackIsNotLandedOnThePositionPlayedBeforeIt() {
        // Resumed at 70 %, played on to 440 s (segment 73): segments 70 to 74 are written.
        guard let rig = preparedAtSeventyPercent() else { return }
        var states: [RemuxPlayback.JumpState] = []
        rig.remux.onJumpStateChanged = { states.append($0) }
        rig.remux.commitResume()
        tick(rig)
        rig.remux.updatePlaybackPositions(played: 421, wanted: 421.5)
        drainMain()
        check(!rig.remux.isJumpWaiting && states.last == .landed(playerSeconds: 421), "the resume landed", "\(states)")
        rig.remux.updatePlaybackPositions(played: 440, wanted: 440)
        tick(rig, 2)
        check((70...73).allSatisfy { exists(rig, "vseg\($0).m4s") }, "segments 70 to 73 are written")

        // A short skip back, to 409 s: two holes (68, 69) before the resume's segment; their
        // bytes are not there yet.
        rig.remux.updatePlaybackPositions(played: 440, wanted: 409)
        tick(rig)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        drainMain()
        eq(rig.session.nextSegmentIndex, 68, "the pass jumped back to segment 68")
        eq(states.last, .waiting(playerSeconds: 409), "a wait, at the position the player wants")

        // The bytes arrive: 68 and 69 are written, and the run from 68 joins the segments
        // written since the resume — the run now holds 440 s, the position PLAYED before the
        // seek, which the player keeps reporting (and one a hair after it, sampled while the
        // jump was decided). Neither is a landing.
        download(rig, 400..<418)
        tick(rig, 3)
        check(exists(rig, "vseg68.m4s") && exists(rig, "vseg69.m4s"), "the two holes are filled")
        for played in [440, 440.4, 440] {
            rig.remux.updatePlaybackPositions(played: played, wanted: 409)
            drainMain()
        }
        check(rig.remux.isJumpWaiting && states.last == .waiting(playerSeconds: 409),
              "the position played before the jump back is not a landing, even inside the run", "\(states)")

        // Playback runs at the destination: landed there.
        rig.remux.updatePlaybackPositions(played: 409.6, wanted: 410)
        drainMain()
        check(!rig.remux.isJumpWaiting && states.last == .landed(playerSeconds: 409.6), "playback runs at the destination: landed", "\(states)")

        // Another short skip back (to segment 65, a hole), its bytes arrive, then a seek forward
        // past the old position, inside the run: played well beyond the position of the jump,
        // it is a landing too.
        rig.remux.updatePlaybackPositions(played: 412, wanted: 395)
        tick(rig)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        drainMain()
        eq(rig.session.nextSegmentIndex, 65, "the pass jumped back to segment 65")
        download(rig, 388..<400)
        tick(rig, 3)
        check(exists(rig, "vseg65.m4s") && exists(rig, "vseg67.m4s"), "the holes 65…67 are filled")
        if rig.remux.isJumpWaiting {
            rig.remux.updatePlaybackPositions(played: 412.5, wanted: 430)
            drainMain()
            check(rig.remux.isJumpWaiting, "a hair after the position of the jump: still waited on")
            rig.remux.updatePlaybackPositions(played: 430, wanted: 430.5)
            drainMain()
            check(!rig.remux.isJumpWaiting && states.last == .landed(playerSeconds: 430), "played beyond it: landed", "\(states)")
        } else {
            check(false, "the second skip back is waited on", "\(states)")
        }
    }

    // MARK: The session can't jump any more

    func testAJumpTheIndexLiesAboutFailsAndTheHolesArePruned() {
        // The cue of the keyframe at 420 s points to the Cluster of 421 s: a Cluster all right
        // (the probe can't tell), but the planned keyframe is not in it.
        var lying = Self.film
        let offsets = Self.filmLayout.clusterOffsets
        lying.cueOffsetErrors = [420: offsets[421] - offsets[420]]
        guard let rig = preparedAtSeventyPercent(stream: lying) else { return }
        var failures: [(String, Double)] = []
        var states: [RemuxPlayback.JumpState] = []
        var halted: [String] = []
        rig.remux.onJumpFailed = { failures.append(($0, $1)) }
        rig.remux.onJumpStateChanged = { states.append($0) }
        rig.remux.onHalted = { halted.append($0) }
        let held = request(rig, "vseg30.m4s")
        rig.remux.commitResume()
        tick(rig, 2)
        drainMain()
        guard let failure = failures.first else { return check(false, "the owner hears that the jump failed", "\(states)") }
        check(failure.0.contains("keyframe") && abs(failure.1 - 423) < 0.01, "why, and the position to play another way", "\(failure)")
        eq(failures.count, 1, "once")
        check(states.first == .waiting(playerSeconds: rig.remux.resumeTargetSeconds ?? -1) && states.last == .failed(failure.0), "waiting, then failed")
        eq(halted, [failure.0], "the remux has stopped producing: halted, after it")
        eq(rig.remux.failureReason, failure.0, "for that reason")
        check(!rig.remux.isJumpWaiting, "nobody waits")
        eq(rig.remux.holeIndexes, IndexSet(), "no hole is writable any more")
        eq(rig.remux.prunedIndexes, IndexSet(integersIn: 2..<70), "what was skipped is pruned")
        check(!rig.remux.isAvailable(playerSeconds: 200) && !exists(rig, "vseg70.m4s"), "gone for good, and nothing was written at the target")
        eq(request(rig, "vseg0.m4s").status, 200, "what exists is still served")
        eq(request(rig, "vseg70.m4s").status, 404, "the jump's own segment will never exist: 404 at once")
        eq(request(rig, "vseg75.m4s").status, 404, "nor anything past it")
        // A pruned segment far from the playhead is held, as before, until the owner stops
        // the remux (it does, to hand over to VLC).
        eq(held.count, 0, "the request for what was a hole is still held")
        rig.remux.stop()
        check(waitUntil { held.count == 1 } && held.status == 410, "and gets its 410 at stop()", "\(held.status ?? 0)")
    }

    // MARK: Which segment a position is in

    func testAResumePointAHairBeforeASegmentIsInTheSegmentBefore() {
        // 70 % of 600 s as a Float is 419.99999 s: the last frame of segment 69. The player's
        // seek loads that segment, so that is where the pass goes — no boundary tolerance for
        // a position that is chosen, not reported.
        guard let rig = rig(have: [0..<16, 412..<446]) else { return }
        rig.remux.prepareResume(atFraction: 0.7)
        tick(rig, 2)
        let seconds = rig.remux.resumeTargetSeconds ?? -1
        check(seconds < 420 && seconds > 419.99, "the resume point is a hair before 420 s", "\(seconds)")
        eq(rig.torrent.readPositions.last, Int64(rig.layout.clusterOffsets[414]), "the torrent is turned to segment 69's Cluster")
        rig.remux.commitResume()
        tick(rig)
        eq(rig.remux.holeIndexes, IndexSet(integersIn: 2..<69), "the pass jumped to segment 69")
        check(exists(rig, "vseg69.m4s") && exists(rig, "vseg70.m4s"), "and wrote it, then the next")
        check(rig.remux.hasMedia(fromPlayerSeconds: seconds), "media at the resume point")
    }

    func testAReportedPositionAHairEarlyGoesBackOnlyIfAVPlayerAsksForThatSegment() {
        guard let rig = preparedAtSeventyPercent() else { return }
        rig.remux.commitResume()
        tick(rig)
        rig.remux.updatePlaybackPositions(played: 421, wanted: 421)
        let cursor = rig.session.nextSegmentIndex
        // AVPlayer settled on the start of segment 70 and reports it 30 ms early (it does).
        for _ in 0..<3 {
            rig.remux.updatePlaybackPositions(played: 421, wanted: 419.97)
            clock.advance(0.4)
            rig.remux.runTick()
        }
        eq(rig.session.nextSegmentIndex, cursor, "a position a hair before segment 70 is segment 70's: the pass does not go back to 69")
        // Unless AVPlayer itself asks for segment 69: the position is then a target inside it.
        download(rig, 412..<418)
        let asked = request(rig, "vseg69.m4s")
        eq(asked.count, 0, "segment 69 is a hole: held")
        rig.remux.updatePlaybackPositions(played: 421, wanted: 419.97)
        tick(rig)
        clock.advance(0.3)
        rig.remux.runTick(timer: false)
        check(waitUntil { asked.count == 1 } && asked.status == 200, "asked for and reported: the pass goes back and writes it")
        check(files(in: rig.remux.outputDirectory)["vseg69.m4s"] == reference()["vseg69.m4s"], "the segment of the conversion in file order")
        tick(rig, 2)
        check(rig.session.nextSegmentIndex >= cursor && rig.remux.holeIndexes == IndexSet(integersIn: 2..<69),
              "then moves over what exists, back to the frontier", "\(rig.session.nextSegmentIndex)")
    }

    // MARK: More ways a jump ends

    func testAnIndexThatPointsIntoZerosIsFoundOutOnceThoseBytesAreThere() {
        // The cue of the keyframe at 420 s is 7 bytes off: inside the Cluster's size field,
        // which is zeros — what a piece still to come looks like.
        var wrong = Self.film
        wrong.cueOffsetErrors = [420: 7]
        guard let rig = rig(have: [0..<16], stream: wrong) else { return }
        var failures: [(String, Double)] = []
        rig.remux.onJumpFailed = { failures.append(($0, $1)) }
        rig.remux.prepareResume(atFraction: Self.seventyPercent)
        tick(rig, 2)
        eq(rig.remux.resumeReadiness, .native, "nothing says the index is wrong before the bytes are there")
        rig.remux.commitResume()      // the user answers before they are
        tick(rig, 4)
        drainMain()
        check(rig.session.hasJumped && failures.isEmpty && rig.remux.isJumpWaiting, "the pass waits for the bytes: zeros are « not yet »")
        download(rig, 418..<446)
        tick(rig)
        drainMain()
        eq(failures.count, 1, "the torrent has them now: zeros there are data, and not a Cluster — the jump failed")
        check(failures.first?.0.contains("Cluster") == true && abs((failures.first?.1 ?? 0) - 423) < 0.01, "why and where", "\(failures)")
        check(rig.remux.failureReason != nil && rig.remux.prunedIndexes == IndexSet(integersIn: 2..<70) && !rig.remux.isJumpWaiting,
              "the remux halted, its holes pruned")
    }

    func testAJumpThatProducesNothingAlthoughItsDataIsOnDiskFails() {
        // The torrent says Clusters 418…499 are on disk; the file has the Cluster at 420 s
        // and zeros after it (data that never reaches the file). The pass reads one Cluster
        // and waits for the next for ever.
        let layout = Self.filmLayout
        guard let files = temporaryInput(Self.holed(layout.data, keeping: [bytes(layout, 0..<16), bytes(layout, 420..<421)])) else { return }
        let torrent = FakeTorrent(size: layout.data.count, have: [bytes(layout, 0..<16), bytes(layout, 418..<500)])
        let remux = RemuxPlayback(localFile: files.input, streamer: nil)
        remux.torrentOverride = torrent.view
        remux.startsTicksOnDemand = false
        let rig = Rig(remux: remux, torrent: torrent, input: files.input, layout: layout)
        rigs.append(rig)
        let stallBytes = RemuxPlayback.jumpStallBytes
        RemuxPlayback.jumpStallBytes = 100_000
        defer { RemuxPlayback.jumpStallBytes = stallBytes }
        var failures: [(String, Double)] = []
        remux.onJumpFailed = { failures.append(($0, $1)) }
        remux.prepareResume(atFraction: Self.seventyPercent)
        tick(rig, 2)
        remux.commitResume()
        tick(rig, 3)
        drainMain()
        check(rig.session.hasJumped && failures.isEmpty && !exists(rig, "vseg70.m4s"), "three ticks: nothing written, not failed yet")
        tick(rig, 2)
        drainMain()
        eq(failures.count, 1, "nothing after three idle ticks with the data on disk: the jump failed")
        check(failures.first?.0.contains("nothing is produced") == true, "why", "\(failures)")
        check(remux.failureReason != nil && remux.holeIndexes.isEmpty, "halted, no hole left writable")

        // The same wait with the bytes simply not there yet is no failure.
        guard let waiting = self.rig(have: [0..<16]) else { return }
        var failed = 0
        waiting.remux.onJumpFailed = { _, _ in failed += 1 }
        waiting.remux.prepareResume(atFraction: Self.seventyPercent)
        tick(waiting, 2)
        waiting.remux.commitResume()
        tick(waiting, 12)
        drainMain()
        check(waiting.session.hasJumped && failed == 0 && waiting.remux.isJumpWaiting && waiting.remux.failureReason == nil,
              "twelve seconds without the bytes: still waiting, natively")
    }

    func testAFarSeekIntoTheLastSegmentIsWrittenByTheFinishNotFailed() {
        // The last real segment (594…600 s) is cut by `finish()` only, three idle ticks after
        // the input is complete: those ticks are no stall. Its bytes are on disk (the
        // torrent's tail pin) when the seek comes. The segment before it is cut by the pump.
        for (wanted, segment) in [(597.0, 99), (590.0, 98)] {
            guard let rig = rig(have: [0..<80, 580..<600]) else { return }
            var failures: [(String, Double)] = []
            rig.remux.onJumpFailed = { failures.append(($0, $1)) }
            rig.remux.updatePlaybackPositions(played: 2, wanted: 2)
            tick(rig, 2)
            _ = rig.session.mediaPlaylist(named: "video.m3u8")
            tick(rig, 2)
            rig.remux.updatePlaybackPositions(played: 20, wanted: wanted)
            clock.advance(0.3); rig.remux.runTick(timer: false)
            clock.advance(0.3); rig.remux.runTick(timer: false)
            check(rig.session.hasJumped, "\(wanted) s: the pass jumped")
            for _ in 0..<6 {
                rig.remux.updatePlaybackPositions(played: 20, wanted: wanted)
                tick(rig)
                drainMain()
            }
            check(failures.isEmpty && rig.remux.failureReason == nil, "\(wanted) s: no failure", "\(failures)")
            check(rig.session.isTailWritten && exists(rig, "vseg\(segment).m4s") && exists(rig, "vseg99.m4s"),
                  "\(wanted) s: segment \(segment) and the film's end are written natively")
            check(files(in: rig.remux.outputDirectory)["vseg99.m4s"] == reference()["vseg99.m4s"],
                  "\(wanted) s: the last segment of the conversion in file order")
        }
    }

    func testASeekToTheVeryEndJumpsToTheLastSegmentNotThroughTheWholeDownload() {
        // A scrub to the end of a film still downloading: the position is at or past the end
        // of the list (600 s of 600), or a hair before it. No jump point covers that index;
        // the last real segment is where the pass goes — not the download in file order.
        // The torrent has the head and its pinned tail.
        for (wanted, explicit) in [(600.0, false), (601.5, false), (600.0, true), (599.97, true)] {
            let label = "\(wanted) s" + (explicit ? " (requestJump)" : "")
            guard let rig = rig(have: [0..<80, 588..<600]) else { return }
            var failures: [(String, Double)] = []
            rig.remux.onJumpFailed = { failures.append(($0, $1)) }
            rig.remux.updatePlaybackPositions(played: 2, wanted: 2)
            tick(rig, 2)
            _ = rig.session.mediaPlaylist(named: "video.m3u8")
            tick(rig, 2)
            let frontier = rig.session.progress.segmentsWritten
            check(!rig.session.hasJumped && frontier < 20, "\(label): played from 0:00, in file order", "\(frontier)")
            check(!rig.remux.hasMedia(fromPlayerSeconds: 120, cushion: 0),
                  "\(label): no media at the exact start of a segment not written")
            rig.remux.updatePlaybackPositions(played: 20, wanted: wanted)
            if explicit {
                check(rig.remux.requestJump(toPlayerSeconds: wanted, reason: .requested), "\(label): accepted")
                rig.remux.runTick(timer: false)
            } else {
                clock.advance(0.3); rig.remux.runTick(timer: false)
                clock.advance(0.3); rig.remux.runTick(timer: false)
            }
            eq(rig.session.nextSegmentIndex, 99, "\(label): the pass jumped to the last real segment")
            let tail = Int64(bytes(rig.layout, 588..<600).lowerBound)
            check(rig.torrent.readPositions.contains { $0 >= tail }, "\(label): the torrent is turned there",
                  "\(rig.torrent.readPositions)")
            for _ in 0..<6 {
                rig.remux.updatePlaybackPositions(played: 20, wanted: wanted)
                tick(rig)
                drainMain()
            }
            check(failures.isEmpty && rig.remux.failureReason == nil, "\(label): no failure", "\(failures)")
            check(rig.session.isTailWritten && exists(rig, "vseg99.m4s"), "\(label): the film's end is written natively")
            check(rig.remux.hasMedia(fromPlayerSeconds: wanted, cushion: 0), "\(label): and there is media to play there")
            check(rig.remux.holeIndexes.contains(frontier), "\(label): what lies between is a hole, not pruned")
        }
    }

    func testAnIndexThatLiesAboutTheLastKeyframeFailsTheJumpAtTheFinish() {
        // 6 s GOPs; the cue of the keyframe at 594 s (cue point 99, segment 99, the last)
        // points to the Cluster of 595 s: a Cluster, without that keyframe, and no other
        // keyframe before the end of the input. The finish must not write a tail that ends
        // the film without segment 99.
        var lying = Self.film
        lying.isKeyframe = { index, perCluster in index % (6 * perCluster) == 0 }
        let offsets = lying.layout().clusterOffsets
        lying.cueOffsetErrors = [99: offsets[595] - offsets[594]]
        guard let rig = rig(have: [0..<80, 580..<600], stream: lying) else { return }
        var failures: [(String, Double)] = []
        rig.remux.onJumpFailed = { failures.append(($0, $1)) }
        rig.remux.updatePlaybackPositions(played: 2, wanted: 2)
        tick(rig, 2)
        _ = rig.session.mediaPlaylist(named: "video.m3u8")
        tick(rig, 2)
        rig.remux.updatePlaybackPositions(played: 20, wanted: 597)
        clock.advance(0.3); rig.remux.runTick(timer: false)
        clock.advance(0.3); rig.remux.runTick(timer: false)
        check(rig.session.hasJumped, "the pass jumped")
        for _ in 0..<6 {
            rig.remux.updatePlaybackPositions(played: 20, wanted: 597)
            tick(rig)
            drainMain()
        }
        eq(failures.count, 1, "the jump failed, once")
        check(failures.first?.0.contains("input ends before the indexed keyframe") == true
              && abs((failures.first?.1 ?? 0) - 597) < 0.01, "why, and the position to play another way", "\(failures)")
        check(!rig.session.isTailWritten && !exists(rig, "vseg99.m4s"), "no tail ends the film without its last segment")
        check(rig.remux.failureReason != nil && !rig.remux.isJumpWaiting, "the remux halted, nobody waits")
    }

    func testThePreparedResumeTurnsVLCOnlyWhenTheSessionLosesItsPlanDuringTheQuestion() {
        // The index lists a keyframe at 30.3 s that the stream does not have: the plan is
        // made (nothing contradicts it in the first seconds), then abandoned when the head
        // pass gets there.
        var contradicted = Self.film
        contradicted.cueTimeErrors = [30: 300]
        guard let rig = rig(have: [0..<16], stream: contradicted) else { return }
        var heard: [NativeResumeReadiness] = []
        rig.remux.onResumeReadinessChanged = { heard.append($0) }
        rig.remux.prepareResume(atFraction: Self.seventyPercent)
        tick(rig, 2)
        guard rig.remux.resumeReadiness == .native else { return check(false, "native while nothing contradicts the index", "\(rig.remux.resumeReadiness)") }
        let steered = rig.torrent.readPositions.last ?? -1
        download(rig, 16..<60)
        tick(rig, 3)
        drainMain()
        guard case .vlcOnly(let reason) = rig.remux.resumeReadiness else {
            return check(false, "the plan is abandoned: VLC only", "\(rig.session.jumpCapability)")
        }
        check(heard.count == 2 && heard.last == .vlcOnly(reason), "the owner hears the change", "\(heard)")
        check(steered > Int64(rig.layout.clusterOffsets[400]) && (rig.torrent.readPositions.last ?? -1) <= Int64(rig.layout.clusterOffsets[60]),
              "the torrent goes back to the head", "\(rig.torrent.readPositions.suffix(2))")
        rig.remux.commitResume()
        tick(rig, 2)
        check(!rig.session.hasJumped && rig.remux.failureReason == nil, "« Resume at » is VLC's; the remux goes on from the head")
        check(rig.session.progress.segmentsWritten >= 8, "which it does", "\(rig.session.progress.segmentsWritten)")
    }

    // MARK: Without jumps: the conversion in file order

    /// Plays the film from 0:00 to its end as a player does (reports once a second, a minute
    /// of film each), every byte arriving as it goes. Returns the files written.
    private func playThrough(_ rig: Rig) -> [String: Data] {
        tick(rig, 2)
        _ = rig.session.mediaPlaylist(named: "video.m3u8")
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
        return files(in: rig.remux.outputDirectory)
    }

    func testWithNativeJumpsOffTheEngineIsTheOneBeforeThem() {
        let expected = reference()
        check(expected.count > 200, "the reference conversion", "\(expected.count) files")
        // The hidden switch off: a resume is VLC's, the torrent is told nothing, and a far
        // position is pumped toward in file order.
        guard let off = rig(have: [0..<16, 418..<446], jumps: false) else { return }
        off.remux.prepareResume(atFraction: Self.seventyPercent)
        tick(off, 2)
        eq(off.remux.resumeReadiness, .vlcOnly("native jumps are off (PTNativeJumpsDisabled)"), "a prepared resume is VLC's")
        off.remux.commitResume()
        check(!off.remux.requestJump(toPlayerSeconds: 421, reason: .requested), "an explicit jump is refused")
        off.remux.updatePlaybackPositions(played: nil, wanted: 421)
        for _ in 0..<3 {
            clock.advance(0.4)
            off.remux.runTick()
        }
        check(!off.session.hasJumped && off.remux.holeIndexes.isEmpty && !off.remux.isJumpWaiting, "a far position: no jump")
        eq(off.session.progress.segmentsWritten, 2, "the pump waits for the bytes in file order")
        eq(off.remux.boundedSnapshot()?.wanted, 421, "and no start lock")
        let got = playThrough(off)
        check(off.remux.isFinished && off.session.isTailWritten, "the conversion runs to its end")
        check(!off.session.hasJumped, "without a jump")
        eq(off.torrent.readPositions, [], "full mode: the torrent was never told where to download")
        eq(got.keys.sorted(), expected.keys.sorted(), "the same files")
        eq(got.keys.filter { got[$0] != expected[$0] }.sorted(), [], "byte for byte")
        eq(playlists(off.session), {
            guard let opened = open(Self.film) else { return [:] }
            convertInOrder(opened)
            return playlists(opened.session)
        }(), "and the same playlists")

        // The switch's own name and default.
        eq(RemuxPlayback.nativeJumpsDisabledKey, "PTNativeJumpsDisabled", "the hidden switch")
        check(RemuxPlayback.nativeJumpsEnabled, "absent: native jumps are on")
    }

    func testAFilmPlayedInFileOrderNeverJumpsAndWritesTheSameBytes() {
        let expected = reference()
        for bounded in [false, true] {
            let mode = bounded ? "bounded" : "full"
            guard let rig = rig(have: [0..<16], bounded: bounded) else { return }
            let got = playThrough(rig)
            check(rig.remux.isFinished && !rig.session.hasJumped && rig.remux.holeIndexes.isEmpty, "\(mode): played to the end without a jump")
            eq(got.keys.filter { got[$0] != expected[$0] }.sorted(), [], "\(mode): every file is the one of the conversion in file order")
            eq(got.count, expected.count, "\(mode): all of them")
            if bounded {
                let positions = rig.torrent.readPositions
                check(!positions.isEmpty && positions == positions.sorted(), "bounded: the torrent followed the reader, forward only")
            } else {
                eq(rig.torrent.readPositions, [], "full: the torrent was told nothing")
                // The disk fills up: the budget deletes what is far from the playhead. The floor
                // of a rewind is then media that WAS written — not something a jump skipped.
                RemuxPlayback.freeSpaceProvider = { _ in 0 }
                clock.advance(11)
                rig.remux.updatePlaybackPositions(played: 500, wanted: 500)
                check(waitUntil { rig.remux.prunedIndexes.count >= 40 }, "full: the budget evicted the head", "\(rig.remux.prunedIndexes.count)")
                let floor = rig.remux.earliestNativeRewindSeconds(fromPlayerSeconds: 500) ?? -1
                check(floor > 200 && floor < 500, "full: a rewind stops where the kept media starts", "\(floor)")
                check(!rig.remux.rewindFloorIsNeverWritten(fromPlayerSeconds: 500), "full: which is deleted media, not media never written")
                check(rig.remux.isFinished && rig.remux.holeIndexes.isEmpty, "full: pruned segments are no holes")
                RemuxPlayback.freeSpaceProvider = { _ in 1 << 42 }
            }
        }
    }
}
