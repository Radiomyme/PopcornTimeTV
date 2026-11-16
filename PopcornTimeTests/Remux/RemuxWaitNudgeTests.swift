//
//  RemuxWaitNudgeTests.swift
//  PopcornTimeTests
//
//  A late jump's wait made known to the torrent engine (`RemuxWaitNudge`): the pure rule in
//  tables (when the pass is late, what is asked for, what is cancelled), the executor that
//  keeps the requests in flight, the steering while they are, and the rule at work in a
//  RemuxPlayback over a holed synthetic film with a fake engine that records every request
//  and every read position — no request while the reader advances, requests only once late,
//  none once the jump's first two segments are written (what the player waits for: the first
//  alone does not end it), none in bounded storage, and after a cancel and a new
//  jump the remux's own report is the last word on where the engine reads.
//

import XCTest
import Foundation

final class RemuxWaitNudgeTests: RemuxSessionTestCase {

    // MARK: The rule (pure)

    private static let mib: Int64 = 1 << 20
    private static let piece: Int64 = 8 << 20

    /// A blocked full-mode wait at 3 000 MiB with 40 MiB to go, 6 MB/s, 20 s still.
    private func input(_ change: (inout RemuxWaitNudge.Input) -> Void = { _ in }) -> RemuxWaitNudge.Input {
        var value = RemuxWaitNudge.Input(strategy: .perPiece, isBounded: false, jumpWaiting: true, startWritten: false,
                                         readerOffset: 3000 * Self.mib, secondsBlocked: 20,
                                         firstMissing: 3002 * Self.mib, demuxerBlocked: nil,
                                         needEnd: 3040 * Self.mib, fileSize: 12_000 * Self.mib,
                                         pieceLength: Self.piece, piecePhase: 0, downloadRate: 6_000_000,
                                         alreadyLate: false)
        change(&value)
        return value
    }

    /// Every piece from 3000 MiB on is missing, except those listed.
    private func missing(except onDisk: Set<Int64> = []) -> (Int64) -> Int64 {
        { offset in
            var at = offset
            while onDisk.contains(at / Self.piece) { at = (at / Self.piece + 1) * Self.piece }
            return at
        }
    }

    func testLatenessIsAtLeastEightSecondsAndTwiceWhatTheBytesTake() {
        eq(RemuxWaitNudge.lateAfter(bytesNeeded: 40 * Self.mib, downloadRate: 0), nil, "nothing comes: nobody to take blocks from")
        eq(RemuxWaitNudge.lateAfter(bytesNeeded: 1 * Self.mib, downloadRate: 10_000_000), 8, "a small need: 8 s at least")
        let late = RemuxWaitNudge.lateAfter(bytesNeeded: 76_000_000, downloadRate: 10_000_000) ?? -1
        check(abs(late - 15.2) < 0.001, "76 MB at 10 MB/s: twice 7.6 s", "\(late)")
    }

    func testAHealthyJumpIsNeverNudged() {
        // 40 MiB at 6 MB/s take 7 s: late after 14 s.
        eq(RemuxWaitNudge.requests(input { $0.secondsBlocked = 4.7 }, firstMissing: missing()), [],
           "4.7 s (a healthy jump on the device): nothing")
        eq(RemuxWaitNudge.requests(input { $0.secondsBlocked = 8.9 }, firstMissing: missing()), [],
           "8.9 s (the slowest healthy one): nothing")
        eq(RemuxWaitNudge.requests(input { $0.secondsBlocked = 13.9 }, firstMissing: missing()), [], "13.9 s: not yet")
        check(!RemuxWaitNudge.requests(input { $0.secondsBlocked = 14 }, firstMissing: missing()).isEmpty, "14 s: late")
        eq(RemuxWaitNudge.requests(input { $0.secondsBlocked = 1000; $0.downloadRate = 0 }, firstMissing: missing()), [],
           "nothing coming at all: nothing asked")
    }

    func testOnlyAWaitingJumpInFullModeBeforeItsFirstSegment() {
        let ready = input()
        check(!RemuxWaitNudge.requests(ready, firstMissing: missing()).isEmpty, "the late full-mode wait asks")
        eq(RemuxWaitNudge.requests(input { $0.isBounded = true }, firstMissing: missing()), [], "bounded storage: never")
        eq(RemuxWaitNudge.requests(input { $0.jumpWaiting = false }, firstMissing: missing()), [], "no jump waits: nothing")
        eq(RemuxWaitNudge.requests(input { $0.startWritten = true }, firstMissing: missing()), [],
           "the jump's first two segments written: nothing")
        eq(RemuxWaitNudge.requests(input { $0.strategy = .off }, firstMissing: missing()), [], "switched off: nothing")
        eq(RemuxWaitNudge.requests(input { $0.readerOffset = 0 }, firstMissing: missing()), [], "no reader yet: nothing")
        eq(RemuxWaitNudge.requests(input { $0.firstMissing = 3040 * Self.mib }, firstMissing: missing()), [],
           "everything the two segments need is on disk: the pass does not wait for the download")
        eq(RemuxWaitNudge.requests(input { $0.firstMissing = 3000 * Self.mib + 70 * Self.mib; $0.needEnd = 4000 * Self.mib },
                                   firstMissing: missing()), [],
           "the first missing byte is beyond 64 MiB from the reader: nothing")
        eq(RemuxWaitNudge.requests(input { $0.firstMissing = $0.fileSize; $0.needEnd = $0.fileSize }, firstMissing: missing()), [],
           "the rest of the file is there: nothing")
    }

    func testOnePerMissingPieceOfTheTwoSegmentsFromTheBlockingByte() {
        // Pieces of 8 MiB: 375 holds 3000…3008 MiB. 375 is missing from 3002 MiB (the reader's
        // first missing byte), 376 is on disk, 377…379 are missing; the need ends at 3040 MiB.
        let found = RemuxWaitNudge.requests(input(), firstMissing: missing(except: [376]))
        eq(found.map(\.offset), [3002 * Self.mib, 377 * Self.piece],
           "the blocking byte, then the next missing piece from its start (376 is on disk), two at most")
        eq(found.map(\.piece), [375, 377], "one per piece")
        // 375 arrives: the next ones are asked, still two at most.
        let after = RemuxWaitNudge.requests(input { $0.firstMissing = 377 * Self.piece; $0.alreadyLate = true },
                                            firstMissing: missing(except: [375, 376]))
        eq(after.map(\.piece), [377, 378], "the window slides piece by piece")
        check(found.allSatisfy { $0.end - $0.offset == RemuxWaitNudge.probeLength }, "each a small range")
        // The demuxer saw zeros earlier than the engine's first missing byte (a piece it holds as
        // verifying): the lower wins, never below the reader.
        eq(RemuxWaitNudge.requests(input { $0.demuxerBlocked = 3001 * Self.mib }, firstMissing: missing()).first?.offset,
           3001 * Self.mib, "the demuxer's own blocked byte when lower")
        eq(RemuxWaitNudge.requests(input { $0.demuxerBlocked = 2990 * Self.mib }, firstMissing: missing()).first?.offset,
           3002 * Self.mib, "never below the reader")
        // At most 64 MiB from the reader, at most `maximumRequests`.
        let far = RemuxWaitNudge.requests(input { $0.needEnd = 4000 * Self.mib; $0.secondsBlocked = 60 }, firstMissing: missing())
        check(far.last.map { $0.offset < 3064 * Self.mib } ?? false, "64 MiB from the reader at most", "\(far.map(\.offset))")
        let small = RemuxWaitNudge.requests(input { $0.pieceLength = 256 << 10; $0.needEnd = 3060 * Self.mib; $0.secondsBlocked = 60 },
                                            firstMissing: { $0 })
        eq(small.count, RemuxWaitNudge.maximumRequests, "small pieces: no more than \(RemuxWaitNudge.maximumRequests) in flight")
    }

    func testACancelLeavesTwoEngineWaitersAtMost() {
        // The device's case: pieces of 8 MiB, the two segments' bytes beyond 64 MiB, all missing.
        // The engine keeps the waiter of a cancelled request until its piece is on disk, so
        // whatever is in flight at a new jump stays time-critical there for a while: never
        // more than the blocking piece and the next one.
        let found = RemuxWaitNudge.requests(input { $0.firstMissing = $0.readerOffset; $0.needEnd = 3200 * Self.mib; $0.secondsBlocked = 60 },
                                            firstMissing: missing())
        eq(RemuxWaitNudge.maximumRequests, 2, "two requests in flight at most")
        eq(found.map(\.piece), [375, 376], "the blocking piece and the next one, not the 8 pieces of the 64 MiB")
    }

    func testTheStreamStrategyIsOneRequestToTheEndOfTheNeed() {
        let found = RemuxWaitNudge.requests(input { $0.strategy = .stream }, firstMissing: missing())
        eq(found, [RemuxWaitNudge.Request(offset: 3002 * Self.mib, end: 3040 * Self.mib, piece: 375)],
           "from the blocking byte to the end of the two segments")
    }

    func testOnceLateTheWaitStaysLateUntilItEnds() {
        // The reader moved: blocked 1 s only, but this wait was found late already.
        check(!RemuxWaitNudge.requests(input { $0.secondsBlocked = 1; $0.alreadyLate = true }, firstMissing: missing()).isEmpty,
              "late it stays")
        eq(RemuxWaitNudge.requests(input { $0.secondsBlocked = 1; $0.alreadyLate = true; $0.startWritten = true },
                                   firstMissing: missing()), [], "until its first two segments are written")
    }

    func testTheByteTheDemuxerStoppedOnIsAskedForEvenPastTheGuessedEnd() {
        // The device's geometry: the share ends a quarter segment past the keyframe two segments
        // on (needEnd 3040 MiB), but that keyframe's Cluster runs further and is read whole
        // before the second segment is cut. The pass waits at the Cluster's start (3036 MiB);
        // its first missing piece starts past the guess (381: 3048 MiB) and slow peers hold it.
        let blockedPastGuess = input {
            $0.readerOffset = 3036 * Self.mib
            $0.firstMissing = 3048 * Self.mib
            $0.demuxerBlocked = 3050 * Self.mib
            $0.secondsBlocked = 120
            $0.alreadyLate = true
        }
        let found = RemuxWaitNudge.requests(blockedPastGuess, firstMissing: missing())
        eq(found.map(\.offset), [3048 * Self.mib], "the blocking piece is asked for, past the guessed end")
        eq(found.map(\.piece), [381], "that piece only: the next ones stay within the share's end")
        let late = RemuxWaitNudge.requests(input {
            $0 = blockedPastGuess
            $0.alreadyLate = false
            $0.secondsBlocked = 8
        }, firstMissing: missing())
        eq(late.map(\.piece), [381], "found late (8 s still: little left before the guessed end) — asked")
        eq(RemuxWaitNudge.requests(input {
            $0 = blockedPastGuess
            $0.alreadyLate = false
            $0.secondsBlocked = 7
        }, firstMissing: missing()), [], "7 s: not late yet")
        eq(RemuxWaitNudge.requests(input { $0 = blockedPastGuess; $0.demuxerBlocked = nil }, firstMissing: missing()), [],
           "the demuxer did not stop there: nothing the pass is shown to need is missing")
        eq(RemuxWaitNudge.requests(input { $0 = blockedPastGuess; $0.demuxerBlocked = 3000 * Self.mib }, firstMissing: missing()), [],
           "a stop behind the reader is no proof")
        eq(RemuxWaitNudge.requests(input {
            $0 = blockedPastGuess
            $0.firstMissing = 3101 * Self.mib
            $0.demuxerBlocked = 3101 * Self.mib
        }, firstMissing: missing()), [], "never more than 64 MiB from the reader")
        eq(RemuxWaitNudge.requests(input { $0 = blockedPastGuess; $0.isBounded = true }, firstMissing: missing()), [],
           "bounded storage: never")
        eq(RemuxWaitNudge.requests(input { $0 = blockedPastGuess; $0.startWritten = true }, firstMissing: missing()), [],
           "the two segments written: nothing")
        let stream = RemuxWaitNudge.requests(input { $0 = blockedPastGuess; $0.strategy = .stream }, firstMissing: missing())
        eq(stream, [RemuxWaitNudge.Request(offset: 3048 * Self.mib, end: 3048 * Self.mib + Self.piece, piece: 381)],
           "stream: the blocking piece only")
    }

    func testAnAnsweredRequestIsToldACancelledOneIsNot() {
        let server = FakeServer()
        let waiter = RemuxEngineWaiter(send: server.send)
        var ended: [RemuxWaitNudge.Request] = []
        waiter.onEnded = { ended.append($0) }
        typealias R = RemuxWaitNudge.Request
        let a = R(offset: 10, end: 20, piece: 1), b = R(offset: 64, end: 74, piece: 2)
        waiter.apply(.init(start: [a, b], cancel: []))
        waiter.apply(.init(start: [], cancel: [b]))
        server.answerAll()
        eq(ended, [a], "the answered one is told (the next piece can be asked at once), not the cancelled one")
        waiter.apply(.init(start: [b], cancel: []))
        eq(waiter.close(), 1, "close() says how many were in flight (its log line)")
        server.answerAll()
        eq(ended, [a], "nothing is told after close()")
        eq(waiter.close(), 0, "a second close() cancels nothing")
    }

    func testThePieceKeyFollowsThePhase() {
        eq(RemuxWaitNudge.pieceKey(100, pieceLength: 0, phase: 0), 100, "unknown piece length: the offset itself")
        eq(RemuxWaitNudge.pieceKey(100, pieceLength: 64, phase: nil), 100, "unknown phase: the offset itself")
        eq(RemuxWaitNudge.pieceKey(100, pieceLength: 64, phase: 0), 1, "aligned")
        eq(RemuxWaitNudge.pieceKey(100, pieceLength: 64, phase: 40), 0, "a file starting mid-piece: 40…104 is one piece")
        eq(RemuxWaitNudge.pieceKey(30, pieceLength: 64, phase: 40), -1, "and before it, the piece before")
    }

    func testThePlanKeepsOneRequestPerPieceAndCancelsTheRest() {
        typealias R = RemuxWaitNudge.Request
        let a = R(offset: 10, end: 20, piece: 1), b = R(offset: 64, end: 74, piece: 2), c = R(offset: 128, end: 138, piece: 3)
        let moved = R(offset: 70, end: 80, piece: 2)
        eq(RemuxWaitNudge.plan(inFlight: [], wanted: [a, b], strategy: .perPiece), .init(start: [a, b], cancel: []), "all new")
        eq(RemuxWaitNudge.plan(inFlight: [a, b], wanted: [moved, c], strategy: .perPiece), .init(start: [c], cancel: [a]),
           "piece 2 is asked already (whatever the byte); piece 1 arrived: cancelled; piece 3 new")
        eq(RemuxWaitNudge.plan(inFlight: [a, b], wanted: [], strategy: .perPiece), .init(start: [], cancel: [a, b]), "nothing wanted: all go")
        let stream = R(offset: 10, end: 200, piece: 1)
        eq(RemuxWaitNudge.plan(inFlight: [stream], wanted: [R(offset: 70, end: 200, piece: 2)], strategy: .stream),
           .init(start: [], cancel: []), "stream: the request in flight reads its way to the new blocking byte")
        eq(RemuxWaitNudge.plan(inFlight: [stream], wanted: [R(offset: 5, end: 200, piece: 0)], strategy: .stream),
           .init(start: [R(offset: 5, end: 200, piece: 0)], cancel: [stream]), "stream: blocked before it: a new one")
    }

    func testSteeringReportsTheBlockingByteWhileRequestsAreInFlight() {
        eq(RemuxSteering.readPosition(isStopped: false, preparedOffset: nil, isBounded: false, hasJumped: true,
                                      readerOffset: 1000, nudgeOffset: 1500), 1500, "full mode: the blocking byte")
        eq(RemuxSteering.readPosition(isStopped: false, preparedOffset: nil, isBounded: false, hasJumped: true,
                                      readerOffset: 1000, nudgeOffset: 900), 1000, "never below the reader")
        eq(RemuxSteering.readPosition(isStopped: false, preparedOffset: nil, isBounded: true, hasJumped: true,
                                      readerOffset: 1000, nudgeOffset: 1500), 1000, "bounded: the reader, always")
        eq(RemuxSteering.readPosition(isStopped: false, preparedOffset: nil, isBounded: false, hasJumped: true,
                                      readerOffset: 1000, nudgeOffset: nil), 1000, "no request: the reader")
        eq(RemuxSteering.readPosition(isStopped: true, preparedOffset: nil, isBounded: false, hasJumped: true,
                                      readerOffset: 1000, nudgeOffset: 1500), nil, "stopped: nothing")
    }

    // MARK: The executor

    /// The engine's server, faked: what was asked, cancelled, answered.
    private final class FakeServer {
        private let lock = NSLock()
        private(set) var asked: [RemuxWaitNudge.Request] = []
        private(set) var cancelled: [RemuxWaitNudge.Request] = []
        private var pending: [(RemuxWaitNudge.Request, () -> Void)] = []

        var send: RemuxEngineWaiter.Send {
            { request, done in
                self.lock.lock(); self.asked.append(request); self.pending.append((request, done)); self.lock.unlock()
                return { self.lock.lock(); self.cancelled.append(request); self.lock.unlock() }
            }
        }

        var askedCount: Int { lock.lock(); defer { lock.unlock() }; return asked.count }
        var cancelledCount: Int { lock.lock(); defer { lock.unlock() }; return cancelled.count }
        var allAsked: [RemuxWaitNudge.Request] { lock.lock(); defer { lock.unlock() }; return asked }
        var allCancelled: [RemuxWaitNudge.Request] { lock.lock(); defer { lock.unlock() }; return cancelled }

        /// The engine answers every request still open (its piece arrived).
        func answerAll() {
            lock.lock(); let all = pending; pending = []; lock.unlock()
            all.forEach { $0.1() }
        }
    }

    func testTheExecutorStartsCancelsAndForgetsWhatEnded() {
        let server = FakeServer()
        var closed = 0
        let waiter = RemuxEngineWaiter(send: server.send, onClose: { closed += 1 })
        typealias R = RemuxWaitNudge.Request
        let a = R(offset: 10, end: 20, piece: 1), b = R(offset: 64, end: 74, piece: 2)
        waiter.apply(.init(start: [a, b], cancel: []))
        eq(waiter.inFlight, [a, b], "both in flight")
        waiter.apply(.init(start: [a], cancel: []))
        eq(server.askedCount, 2, "one request per key: nothing twice")
        server.answerAll()
        eq(waiter.inFlight, [], "answered: no longer in flight")
        waiter.apply(.init(start: [a], cancel: []))
        eq(waiter.cancelAll(), 1, "cancelAll counts what it cancelled")
        eq(server.allCancelled, [a], "and cancels it")
        waiter.close()
        waiter.close()
        eq(closed, 1, "closed once")
        waiter.apply(.init(start: [b], cancel: []))
        eq(server.askedCount, 3, "nothing is asked after close()")
    }

    func testTheLiveSenderOnlyGoesToTheLoopback() {
        eq(RemuxEngineHTTPSender.loopbackURL(URL(string: "http://127.0.0.1:50321/film.mkv")), URL(string: "http://127.0.0.1:50321/film.mkv"),
           "127.0.0.1: yes")
        eq(RemuxEngineHTTPSender.loopbackURL(URL(string: "http://0.0.0.0:50321/")), nil, "0.0.0.0 (the engine's own report): never")
        eq(RemuxEngineHTTPSender.loopbackURL(URL(string: "http://192.168.1.2:50321/")), nil, "another host: never")
        eq(RemuxEngineHTTPSender.loopbackURL(URL(fileURLWithPath: "/tmp/film.mkv")), nil, "a file: never")
        eq(RemuxEngineHTTPSender.loopbackURL(nil), nil, "none: never")
    }

    func testTheLiveSenderIsLetGoAfterInvalidate() {
        weak var weakSender: RemuxEngineHTTPSender?
        // (Its own pool: what Foundation autoreleases here would outlive the check otherwise.)
        autoreleasepool {
            let sender = RemuxEngineHTTPSender(url: URL(string: "http://127.0.0.1:9/film.mkv")!)
            weakSender = sender
            let waiter = RemuxEngineWaiter(send: { sender.send($0, done: $1) }, onClose: { sender.invalidate() })
            // Port 9 refuses at once: the request ends by itself.
            waiter.apply(.init(start: [RemuxWaitNudge.Request(offset: 0, end: 16, piece: 0)], cancel: []))
            waiter.close()
        }
        let deadline = Date(timeIntervalSinceNow: 3)
        while weakSender != nil, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
        check(weakSender == nil, "the session let its delegate go: no cycle left after close()")
    }

    // MARK: In a RemuxPlayback (fake engine over a holed film)

    private final class Clock {
        private let lock = NSLock()
        private var value: TimeInterval = 50_000
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    /// The torrent and its server: the bytes on disk, every read position it was given — by
    /// the remux or, when it serves a request, by itself — and the requests to its server.
    private final class FakeEngine {
        private let lock = NSLock()
        private var ranges: [Range<Int64>] = []
        private var positions: [(Int64, String)] = []
        let size: Int64
        let pieceLength: Int64
        var bounded = false
        var rate: Int64 = 1_000_000
        let server = FakeServer()

        init(size: Int, pieceLength: Int64, have: [Range<Int>]) {
            self.size = Int64(size)
            self.pieceLength = pieceLength
            have.forEach { add($0) }
        }

        func add(_ range: Range<Int>) {
            lock.lock(); defer { lock.unlock() }
            ranges.append(Int64(range.lowerBound)..<Int64(range.upperBound))
        }

        func firstMissing(from offset: Int64) -> Int64 {
            lock.lock(); defer { lock.unlock() }
            var position = max(0, offset)
            while position < size, let range = ranges.first(where: { $0.contains(position) }) { position = range.upperBound }
            return min(position, size)
        }

        /// The engine moves its own read position (a reader of its server was served).
        func movedByItsServer(to offset: Int64) {
            lock.lock(); positions.append((offset, "server")); lock.unlock()
        }

        var reported: [(Int64, String)] { lock.lock(); defer { lock.unlock() }; return positions }
        var lastPosition: (Int64, String)? { reported.last }

        var view: RemuxTorrentView {
            var view = RemuxTorrentView(setReadPosition: { offset in self.lock.lock(); self.positions.append((offset, "remux")); self.lock.unlock() },
                                        firstMissingOffset: { self.firstMissing(from: $0) },
                                        fileSize: { self.size },
                                        isBounded: { self.bounded },
                                        totalProgress: { self.firstMissing(from: 0) >= self.size ? 1 : 0.5 },
                                        isFileComplete: { self.firstMissing(from: 0) >= self.size })
            view.pieceLength = { self.pieceLength }
            view.downloadRate = { self.rate }
            view.requestRange = server.send
            return view
        }
    }

    private struct Rig {
        let remux: RemuxPlayback
        let engine: FakeEngine
        let input: URL
        let layout: SyntheticMatroska.Layout
        var session: MKVToHLSRemuxSession { remux.session! }
    }

    private let clock = Clock()
    private var rigs: [Rig] = []

    /// Ten minutes of HEVC + E-AC-3, a Cluster per second, the index at the front (the
    /// resume tests' film).
    private static let film: SyntheticMatroska = RemuxTestStreams.make {
        $0.clusterCount = 600
        $0.videoCodec = .hevc
        $0.audioCodec = .eac3
        $0.videoFrameBytes = 600
        $0.cues = .front
    }
    private static let layout = film.layout()

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

    private func bytes(_ clusters: Range<Int>) -> Range<Int> {
        let offsets = Self.layout.clusterOffsets
        let lower = clusters.lowerBound <= 0 ? 0 : offsets[min(clusters.lowerBound, offsets.count - 1)]
        let upper = clusters.upperBound >= offsets.count ? Self.layout.data.count : offsets[clusters.upperBound]
        return lower..<max(lower, upper)
    }

    /// The head on disk (segments 0 and 1), a resume prepared at 70 % (segment 70, Cluster
    /// 420) and accepted: the pass has jumped there, where nothing is on disk yet.
    private func jumpedIntoNothing(bounded: Bool = false, file: StaticString = #filePath, line: Int = #line) -> Rig? {
        let have = [bytes(0..<16)]
        guard let files = temporaryInput(Self.holed(Self.layout.data, keeping: have), file: file, line: line) else { return nil }
        // Pieces of 4 KiB: a few dozen in the two segments at 70 %.
        let engine = FakeEngine(size: Self.layout.data.count, pieceLength: 4096, have: have)
        engine.bounded = bounded
        let remux = RemuxPlayback(localFile: files.input, streamer: nil)
        remux.torrentOverride = engine.view
        remux.startsTicksOnDemand = false
        remux.allowsNativeJumps = true
        let rig = Rig(remux: remux, engine: engine, input: files.input, layout: Self.layout)
        rigs.append(rig)
        remux.prepareResume(atFraction: 0.705)
        tick(rig, 2)
        guard remux.resumeReadiness == .native else {
            check(false, "the resume at 70 % is native", file: file, line: line)
            return nil
        }
        remux.commitResume()
        tick(rig)
        guard rig.session.hasJumped, remux.isJumpWaiting else {
            check(false, "the pass jumped and the player waits", file: file, line: line)
            return nil
        }
        return rig
    }

    private func tick(_ rig: Rig, _ count: Int = 1) {
        for _ in 0..<count {
            clock.advance(1)
            rig.remux.runTick()
        }
    }

    private func download(_ rig: Rig, _ clusters: Range<Int>) {
        let range = bytes(clusters)
        fill(rig.input, from: Self.layout.data, range)
        rig.engine.add(range)
    }

    func testNothingIsAskedWhileTheReaderAdvances() {
        guard let rig = jumpedIntoNothing() else { return }
        // A Cluster a second arrives, from the one before the keyframe on: the reader moves at
        // every tick, for 20 s.
        for cluster in 418..<438 {
            download(rig, cluster..<(cluster + 1))
            tick(rig)
        }
        eq(rig.engine.server.askedCount, 0, "a wait whose reader moves is never late: nothing asked")
    }

    func testRequestsOnlyOnceLateThenOnePerMissingPieceAndNoneAfterTheFirstSegment() {
        guard let rig = jumpedIntoNothing() else { return }
        let reader = rig.session.consumedInputOffset
        tick(rig, 6)
        eq(rig.engine.server.askedCount, 0, "7 s blocked: not late yet (8 s at least)")
        tick(rig, 2)
        let asked = rig.engine.server.allAsked
        check(!asked.isEmpty, "late: the engine is asked", "\(asked)")
        eq(asked.first?.offset, rig.engine.firstMissing(from: reader), "first at the byte the pass is blocked on")
        let needEnd = rig.session.jumpTarget(forSegment: 72)?.readOffset ?? -1
        check(asked.allSatisfy { $0.offset >= reader && $0.offset < needEnd }, "only within the two segments' bytes",
              "\(asked.map(\.offset)) reader \(reader) need end \(needEnd)")
        eq(Set(asked.map(\.piece)).count, asked.count, "one per piece")
        // Every piece from the blocking byte to the end of the two segments is missing: one
        // request each, up to the cap (the fake's pieces are 4 KiB from the head's end).
        let phase = rig.engine.firstMissing(from: 0) % 4096
        let blockedKey = RemuxWaitNudge.pieceKey(asked.first?.offset ?? 0, pieceLength: 4096, phase: phase)
        let lastKey = RemuxWaitNudge.pieceKey(min(needEnd, reader + RemuxWaitNudge.spanCap) - 1, pieceLength: 4096, phase: phase)
        eq(asked.count, min(RemuxWaitNudge.maximumRequests, Int(lastKey - blockedKey + 1)),
           "each missing piece, up to \(RemuxWaitNudge.maximumRequests)")
        tick(rig, 3)
        eq(rig.engine.server.askedCount, asked.count, "nothing asked twice while they are in flight")
        eq(rig.engine.lastPosition?.0, asked.first?.offset, "the engine is told to read at the blocking byte")

        // The first pieces arrive (two Clusters): the hole moves, what arrived is cancelled,
        // the next pieces are asked.
        download(rig, 418..<422)
        tick(rig)
        check(rig.session.consumedInputOffset > reader, "the reader moved")
        check(rig.engine.server.cancelledCount > 0, "the requests of the pieces that arrived are cancelled")
        check(rig.engine.server.askedCount > asked.count, "the next missing pieces are asked (the wait stays late)")

        // Segment 70 can be cut (Clusters 420…425 and the keyframe that ends it): the first
        // segment is written, the player still waits for the second — still asked for.
        download(rig, 418..<427)
        tick(rig)
        eq(rig.session.progress.segmentsWritten, 71, "the jump's first segment is written, not the second")
        let reader71 = rig.session.consumedInputOffset
        let open71 = Set(rig.engine.server.allAsked).subtracting(rig.engine.server.allCancelled)
        check(!open71.isEmpty && open71.allSatisfy { $0.offset >= reader71 },
              "the second segment's missing pieces are in flight, none behind the reader", "\(open71.map(\.offset)) reader \(reader71)")

        // The rest of the two segments arrives: both are written, everything goes.
        download(rig, 418..<446)
        tick(rig)
        check(rig.session.progress.segmentsWritten >= 72, "the first two segments are written")
        let count = rig.engine.server.askedCount
        tick(rig, 10)
        eq(rig.engine.server.askedCount, count, "nothing asked once the player's media is there")
        let open = Set(rig.engine.server.allAsked).subtracting(rig.engine.server.allCancelled)
        eq(open.count, 0, "and nothing left in flight: \(open.map(\.offset))")
    }

    func testTheClusterOfTheKeyframeAfterTheTwoSegmentsIsAskedFor() {
        guard let rig = jumpedIntoNothing() else { return }
        guard let after = rig.session.jumpTarget(forSegment: 72) else { return check(false, "segment 72 is a jump target") }
        // Everything up to the Cluster of segment 72's keyframe (Cluster 432): segment 70 is
        // cut, segment 71 waits for that Cluster — it ends there. The pass is blocked at or
        // past where a jump to segment 72 would read (its read offset, here its keyframe's
        // Cluster: no lead-in), on bytes the share on screen counts.
        download(rig, 418..<432)
        tick(rig)
        eq(rig.session.progress.segmentsWritten, 71, "the first segment is written, the second waits")
        let reader = rig.session.consumedInputOffset
        let blocked = rig.engine.firstMissing(from: reader)
        check(blocked >= after.readOffset, "blocked past segment 72's lead-in", "blocked \(blocked) lead-in \(after.readOffset)")
        let end = RemuxPlayback.jumpNeedEnd(rig.session, segment: 70, fileSize: rig.engine.size) ?? 0
        check(blocked < end, "inside the bytes the share counts", "blocked \(blocked) end \(end)")
        tick(rig, 10)
        let asked = rig.engine.server.allAsked
        eq(asked.first?.offset, blocked, "late: the engine is asked for the byte the pass is blocked on")
        check(asked.allSatisfy { $0.offset < end }, "never past the end the share counts to", "\(asked.map(\.offset)) end \(end)")
        // It arrives: both segments are written, everything goes.
        download(rig, 432..<446)
        tick(rig)
        check(rig.session.progress.segmentsWritten >= 72, "the first two segments are written")
        let open = Set(rig.engine.server.allAsked).subtracting(rig.engine.server.allCancelled)
        eq(open.count, 0, "nothing left in flight: \(open.map(\.offset))")
    }

    func testNeverInBoundedStorage() {
        guard let rig = jumpedIntoNothing(bounded: true) else { return }
        tick(rig, 30)
        eq(rig.engine.server.askedCount, 0, "bounded storage: never")
    }

    func testAfterACancelAndANewJumpTheRemuxReportIsTheLastWord() {
        guard let rig = jumpedIntoNothing() else { return }
        tick(rig, 9)
        let asked = rig.engine.server.allAsked
        guard let first = asked.first else { return check(false, "late: asked") }
        // The user goes back: a new jump into a hole near the start (the player reports it).
        rig.remux.updatePlaybackPositions(played: 423, wanted: 200)
        check(rig.remux.requestJump(toPlayerSeconds: 200, reason: .rewind), "a jump back is asked")
        tick(rig)
        eq(Set(rig.engine.server.allCancelled), Set(asked), "every request of the old wait is cancelled at the new jump")
        guard let target = rig.session.jumpTarget(forSegment: 33) else { return check(false, "segment 33 is a jump target") }
        check(rig.engine.reported.contains { $0.0 == target.readOffset && $0.1 == "remux" }, "the engine is told the new place")
        // The engine answers the cancelled request late (its piece arrived): it moves its own
        // read position there, as PopcornTorrent does for any reader it serves.
        rig.engine.movedByItsServer(to: first.offset)
        eq(rig.engine.lastPosition?.1, "server", "for a moment the engine reads at the old place")
        tick(rig)
        let last = rig.engine.lastPosition
        eq(last?.1, "remux", "the next tick's report is the last word")
        check((last?.0 ?? 0) < first.offset && (last?.0 ?? 0) >= target.readOffset, "at the new jump's reader",
              "\(String(describing: last)) target \(target.readOffset)")
        eq(rig.engine.server.allAsked.filter { $0.offset >= first.offset }.count, asked.count, "nothing asked again at the old place")
    }

    func testANewJumpDoesNotShowThePreviousWaitsShare() {
        guard let rig = jumpedIntoNothing() else { return }
        tick(rig, 3)
        guard let old = rig.remux.waitProgress, let oldTarget = old.targetSeconds else {
            return check(false, "the resume's wait has its progress")
        }
        // One step back (10 s, within a segment's tolerance of the label): a new jump into a
        // hole, made in a tick that is not the timer's.
        let back = oldTarget - 10
        rig.remux.updatePlaybackPositions(played: oldTarget, wanted: back)
        check(rig.remux.requestJump(toPlayerSeconds: back, reason: .rewind), "a jump back is asked")
        rig.remux.runTick(timer: false)
        check(rig.remux.isJumpWaiting, "the new jump waits")
        let shown = rig.remux.waitProgress
        check(shown == nil || shown?.targetSeconds != oldTarget,
              "the old wait's share is not left under the new position", "\(String(describing: shown?.targetSeconds))")
        tick(rig)
        check(rig.remux.waitProgress != nil, "the next timer tick gives the new wait's own")
    }

    func testStopCancelsEverythingAndAsksNothingMore() {
        guard let rig = jumpedIntoNothing() else { return }
        tick(rig, 9)
        let asked = rig.engine.server.allAsked
        check(!asked.isEmpty, "late: asked")
        rig.remux.stop()
        eq(Set(rig.engine.server.allCancelled), Set(asked), "stop() cancels every request")
        rig.remux.runTick()
        eq(rig.engine.server.askedCount, asked.count, "and nothing is asked after it")
    }
}
