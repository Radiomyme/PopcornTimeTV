import Foundation

/// A jump's wait, made known to the torrent engine (pure rule + its HTTP side).
///
/// The remux reads the torrent's file straight from disk: PopcornTorrent never learns that
/// the pass is blocked on a missing piece. In full storage mode its window pieces sit at
/// priority 6–7 with no deadline, and the blocks slow peers hold for them (a peer whose queue
/// was sized at a high rate, then slowed down without stopping) are never taken back: after
/// a resume the pass waited 110 s at the front of a window while 1.1 GB arrived around it.
/// The engine has all of that for a reader of its OWN HTTP server — a « waiter »: the piece
/// becomes urgent, gets a deadline once it is late, and the requests slow peers hold for it
/// are taken back (PopcornTorrent `StreamController::readAsync`, `rescueLatePieces`). So,
/// while a jump somebody waits on is late, the remux asks the engine's server on 127.0.0.1
/// for the bytes it is blocked on, and throws the answer away.
///
/// Only in full storage mode (in bounded mode an HTTP reader also drives the engine's served
/// offset and what it releases), only while a jump's wait is pending and the media the player
/// waits for there (its first two segments) is not written, and only once the pass is LATE: a
/// healthy jump never puts libtorrent into its time-critical mode (any deadline does).
/// Everything is cancelled once those segments are written, at a new jump, at a failure and
/// at `stop()`. (The first segment alone is not the end of the wait: on the rig it was often
/// written within 5 s while the second one waited minutes behind blocks slow peers held.)
enum RemuxWaitNudge {

    /// How the wait is made known. `perPiece`: one small request in flight per missing piece
    /// of the bytes the jump's first two segments need (each one a waiter of its own);
    /// `stream`: one request from the blocking offset to the end of those bytes, read and
    /// thrown away (the engine's server walks it piece after piece); `off`: nothing.
    enum Strategy: String {
        case off
        case stream
        case perPiece
    }

    /// The strategy the app runs (chosen on the loopback rig, `RemuxWaitNudge` tests).
    static let defaultStrategy: Strategy = .perPiece

    /// The strategy in force: `defaultStrategy`, or, in DEBUG builds, `-PTDebugWaitNudge
    /// off|stream|perPiece` (the rig's comparison).
    static var strategy: Strategy {
        #if DEBUG
        if let value = UserDefaults.standard.string(forKey: "PTDebugWaitNudge"), let forced = Strategy(rawValue: value) {
            return forced
        }
        #endif
        return defaultStrategy
    }

    /// The pass is late when it has not moved for at least this long (s)…
    static let minimumLateSeconds: TimeInterval = 8
    /// …and for at least this many times what the bytes it still needs take at the
    /// torrent's current rate.
    static let lateFactor: Double = 2
    /// The bytes looked at from the reader (the largest Cluster the demuxer reads in one
    /// piece, `RemuxPlayback.jumpStallBytes`).
    static let spanCap: Int64 = 64 << 20
    /// Requests in flight at most (`perPiece`): the blocking piece and the next one. The
    /// engine keeps a waiter, and the deadline it gives a late piece, until that piece is on
    /// disk, even once its request is cancelled (PopcornTorrent `closeReader` only drops the
    /// reader): after a cancel at a new jump, at most two pieces of the old place stay
    /// time-critical, not the whole 64 MiB (up to 8 pieces of 8 MiB on the device). The
    /// next ones are asked tick after tick as these arrive.
    static let maximumRequests = 2
    /// What one `perPiece` request asks for (its piece only: it is answered once that
    /// piece is on disk).
    static let probeLength: Int64 = 16 << 10

    struct Input: Equatable {
        var strategy: Strategy = RemuxWaitNudge.defaultStrategy
        var isBounded: Bool
        /// A jump somebody waits on (`RemuxPlayback.isJumpWaiting`).
        var jumpWaiting: Bool
        /// The media the player waits for there is written: the jump's first two segments
        /// (`RemuxPlayback.hasMediaToStart`; its first alone near the film's end).
        var startWritten: Bool
        /// Where the pass reads (`consumedInputOffset`).
        var readerOffset: Int64
        /// How long the reader has not moved, since the jump at most (s).
        var secondsBlocked: TimeInterval
        /// `firstMissingOffset(readerOffset)`: the first byte at or after the reader the
        /// engine does not have on disk.
        var firstMissing: Int64
        /// Where the demuxer itself found zeros (not downloaded) and stopped, if it did.
        var demuxerBlocked: Int64?
        /// Where the bytes of the jump's first two segments end (`RemuxPlayback.jumpNeedEnd`,
        /// the end the share on screen counts to: past the Cluster of the keyframe after
        /// them; the file's end near the end of the film).
        var needEnd: Int64
        var fileSize: Int64
        /// The torrent's piece length and the file offset of a piece boundary (any one);
        /// nil phase: unknown (each request then stands for itself).
        var pieceLength: Int64
        var piecePhase: Int64?
        /// The torrent's download rate (B/s).
        var downloadRate: Int64
        /// Requests were made for this wait already: it was late, it stays so until it ends.
        var alreadyLate: Bool
    }

    /// One request to the engine's server: bytes [offset, end) of the file; `piece`: the
    /// piece it stands for (the key that keeps one request per piece in flight).
    struct Request: Equatable, Hashable {
        let offset: Int64
        let end: Int64
        let piece: Int64
    }

    /// Where the pass is blocked: the lower of the engine's first missing byte from the
    /// reader and the demuxer's own (a piece being verified is missing for the engine and
    /// already zeros-free, or the other way round), never below the reader.
    static func blockingOffset(readerOffset: Int64, firstMissing: Int64, demuxerBlocked: Int64?) -> Int64 {
        var blocked = firstMissing
        if let own = demuxerBlocked, own >= readerOffset { blocked = min(blocked, own) }
        return max(readerOffset, blocked)
    }

    /// The end of the bytes looked at: those of the jump's first two segments, never past
    /// `spanCap` from the reader nor past the file.
    static func spanEnd(_ input: Input) -> Int64 {
        min(input.fileSize, input.readerOffset + spanCap, input.needEnd)
    }

    /// The end of where the blocking byte may be asked for: `spanCap` from the reader. `needEnd`
    /// is a guess past the keyframe two segments on (a quarter segment for its Cluster); on a
    /// 4K remux that Cluster can run several MB further, and it is read whole before the
    /// second segment is cut. Where the demuxer itself stopped on zeros is what the pass reads
    /// next, wherever that is: that byte is asked for even past the guess (only its piece: the
    /// next ones stay within `spanEnd`).
    static func blockingEnd(_ input: Input) -> Int64 {
        min(input.fileSize, input.readerOffset + spanCap)
    }

    /// How long (s) the reader may stand still before the pass is late; nil when nothing
    /// is coming (no rate: there is nobody to take blocks back from).
    static func lateAfter(bytesNeeded: Int64, downloadRate: Int64) -> TimeInterval? {
        guard downloadRate > 0 else { return nil }
        return max(minimumLateSeconds, lateFactor * Double(max(0, bytesNeeded)) / Double(downloadRate))
    }

    /// The piece holding `offset` (an index relative to the phase; any consistent key).
    static func pieceKey(_ offset: Int64, pieceLength: Int64, phase: Int64?) -> Int64 {
        guard pieceLength > 0, let phase = phase else { return offset }
        let shifted = offset - phase
        return shifted >= 0 ? shifted / pieceLength : (shifted - pieceLength + 1) / pieceLength
    }

    /// The requests that should be in flight now (none: cancel them all).
    /// `firstMissing`: the engine's `firstMissingOffset(from:)`, for the pieces after the
    /// blocking one.
    static func requests(_ input: Input, firstMissing: (Int64) -> Int64) -> [Request] {
        guard input.strategy != .off, !input.isBounded, input.jumpWaiting, !input.startWritten,
              input.fileSize > 0, input.readerOffset > 0, input.readerOffset < input.fileSize else { return [] }
        let blocked = blockingOffset(readerOffset: input.readerOffset, firstMissing: input.firstMissing,
                                     demuxerBlocked: input.demuxerBlocked)
        let end = spanEnd(input)
        if blocked >= end {
            // Past the guessed end of the two segments' bytes (`blockingEnd`): only when the pass
            // is shown to be blocked there — the demuxer itself stopped on zeros at or after the
            // reader (it reads the keyframe's Cluster whole). Else nothing the pass needs is
            // missing: it does not wait for the download.
            let demuxerStopped = input.demuxerBlocked.map { $0 >= input.readerOffset } ?? false
            guard demuxerStopped, blocked < blockingEnd(input) else { return [] }
        }
        if !input.alreadyLate {
            guard let late = lateAfter(bytesNeeded: max(0, end - input.readerOffset), downloadRate: input.downloadRate),
                  input.secondsBlocked >= late else { return [] }
        }
        let key = { (offset: Int64) in pieceKey(offset, pieceLength: input.pieceLength, phase: input.piecePhase) }
        switch input.strategy {
        case .off:
            return []
        case .stream:
            // Past the guess: the blocking piece only.
            let streamEnd = blocked < end ? end : min(blockingEnd(input), blocked + max(probeLength, input.pieceLength))
            return [Request(offset: blocked, end: streamEnd, piece: key(blocked))]
        case .perPiece:
            var found: [Request] = []
            var offset = blocked
            // The blocking piece always (checked above), the next ones within `spanEnd`.
            while offset == blocked || offset < end, found.count < maximumRequests {
                found.append(Request(offset: offset, end: min(input.fileSize, offset + probeLength), piece: key(offset)))
                guard input.pieceLength > 0 else { break }
                // The next piece: from its start when the boundaries are known, else the same
                // distance into it; the first byte missing from there (pieces are whole).
                var next = offset + input.pieceLength
                if let phase = input.piecePhase {
                    next = phase + (key(offset) + 1) * input.pieceLength
                }
                guard next < end else { break }
                offset = max(next, firstMissing(next))
            }
            return found
        }
    }

    /// What the executor does with the requests in flight (keyed by piece) to reach
    /// `wanted` (pure). `stream`: a request in flight that started at or before the
    /// blocking offset and ends after it reads its way there — kept.
    struct Plan: Equatable {
        var start: [Request]
        var cancel: [Request]
    }

    static func plan(inFlight: [Request], wanted: [Request], strategy: Strategy) -> Plan {
        if wanted.isEmpty { return Plan(start: [], cancel: inFlight) }
        switch strategy {
        case .off:
            return Plan(start: [], cancel: inFlight)
        case .stream:
            guard let target = wanted.first else { return Plan(start: [], cancel: inFlight) }
            if let running = inFlight.first(where: { $0.offset <= target.offset && $0.end > target.offset }) {
                return Plan(start: [], cancel: inFlight.filter { $0 != running })
            }
            return Plan(start: [target], cancel: inFlight)
        case .perPiece:
            let wantedPieces = Set(wanted.map(\.piece))
            let runningPieces = Set(inFlight.map(\.piece))
            return Plan(start: wanted.filter { !runningPieces.contains($0.piece) },
                        cancel: inFlight.filter { !wantedPieces.contains($0.piece) })
        }
    }
}

/// The requests in flight to the engine's server for one remux (`RemuxWaitNudge`). Any
/// thread; nothing in it waits for an answer. `send` makes a request and returns how to
/// cancel it; it calls its `done` once the request ended (answered, failed, cancelled).
final class RemuxEngineWaiter {
    typealias Send = (_ request: RemuxWaitNudge.Request, _ done: @escaping () -> Void) -> (() -> Void)

    private let lock = NSLock()
    private var running: [RemuxWaitNudge.Request: (id: Int, cancel: () -> Void)] = [:]
    private var nextID = 0
    private var closed = false
    private let send: Send
    /// Called by `close()` (the HTTP sender's session is invalidated there).
    private let onClose: (() -> Void)?
    /// Called (on the sender's queue) when a request in flight ended by itself — answered or
    /// failed, not cancelled here: its piece is likely on disk, the next one can be asked now
    /// rather than at the next 1 s tick (`RemuxPlayback` looks at once).
    var onEnded: ((RemuxWaitNudge.Request) -> Void)?

    init(send: @escaping Send, onClose: (() -> Void)? = nil) {
        self.send = send
        self.onClose = onClose
    }

    var inFlight: [RemuxWaitNudge.Request] {
        lock.lock(); defer { lock.unlock() }
        return Array(running.keys).sorted { $0.offset < $1.offset }
    }

    /// Starts `plan.start`, cancels `plan.cancel`. Nothing after `close()`.
    func apply(_ plan: RemuxWaitNudge.Plan) {
        var cancels: [() -> Void] = []
        lock.lock()
        for request in plan.cancel {
            if let entry = running.removeValue(forKey: request) { cancels.append(entry.cancel) }
        }
        let starts = closed ? [] : plan.start.filter { running[$0] == nil }
        lock.unlock()
        cancels.forEach { $0() }
        for request in starts {
            lock.lock()
            nextID += 1
            let id = nextID
            lock.unlock()
            let cancel = send(request) { [weak self] in self?.ended(request, id: id) }
            lock.lock()
            if closed {
                lock.unlock()
                cancel()
                continue
            }
            running[request] = (id, cancel)
            lock.unlock()
        }
    }

    /// Cancels every request in flight; returns how many there were.
    @discardableResult
    func cancelAll() -> Int {
        lock.lock()
        let all = running.values.map(\.cancel)
        running.removeAll()
        lock.unlock()
        all.forEach { $0() }
        return all.count
    }

    /// Cancels everything for good (`RemuxPlayback.stop()`): no request after it. Returns how
    /// many were in flight.
    @discardableResult
    func close() -> Int {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        let count = cancelAll()
        if !already { onClose?() }
        return count
    }

    private func ended(_ request: RemuxWaitNudge.Request, id: Int) {
        lock.lock()
        let wasRunning = running[request]?.id == id
        if wasRunning { running.removeValue(forKey: request) }
        let closed = self.closed
        let callback = onEnded
        lock.unlock()
        if wasRunning, !closed { callback?(request) }
    }
}

/// The live `RemuxEngineWaiter.Send`: GET requests with a Range header to PopcornTorrent's
/// own HTTP server (`url`: its 127.0.0.1 address, `PlaybackRouting.playableLocalURL`). The
/// answer is read and thrown away (nothing is kept in memory); the session runs on its own
/// queue, never the main one. `invalidate()` cancels everything and lets the session go (it
/// keeps its delegate — this object — until then).
final class RemuxEngineHTTPSender: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let queue: OperationQueue
    private let lock = NSLock()
    private var session: URLSession?
    private var invalidated = false
    private var done: [Int: () -> Void] = [:]

    init(url: URL) {
        self.url = url
        let queue = OperationQueue()
        queue.name = "RemuxEngineHTTPSender"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.queue = queue
        super.init()
    }

    /// The URL the requests go to, or nil when it is not the engine's local server.
    static func loopbackURL(_ url: URL?) -> URL? {
        guard let url = url, url.scheme == "http", url.host == "127.0.0.1" else { return nil }
        return url
    }

    private func currentSession() -> URLSession? {
        lock.lock(); defer { lock.unlock() }
        if invalidated { return nil }
        if let session = session { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // A waiter is answered once its piece is on disk: minutes on a bad swarm.
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 3600
        configuration.httpMaximumConnectionsPerHost = RemuxWaitNudge.maximumRequests + 2
        configuration.waitsForConnectivity = false
        let made = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        session = made
        return made
    }

    func send(_ request: RemuxWaitNudge.Request, done: @escaping () -> Void) -> (() -> Void) {
        guard let session = currentSession(), request.end > request.offset else {
            done()
            return {}
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("bytes=\(request.offset)-\(request.end - 1)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: urlRequest)
        lock.lock()
        self.done[task.taskIdentifier] = done
        lock.unlock()
        task.resume()
        return { [weak task] in task?.cancel() }
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        let current = session
        session = nil
        lock.unlock()
        current?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Thrown away: the request only makes the engine wait for its piece.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let finished = done.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        finished?()
    }
}
