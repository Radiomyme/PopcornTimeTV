import Foundation

/// The torrent engine's side of a playback's start, measured: `[Measure]`
/// lines next to the `[Start]` ones, so that a session on a real swarm says
/// where the bytes and the seconds before the first frame went (study b2,
/// « A1 »: the piece length, the first peer, what the engine waited for, the
/// bytes and the rate at each step).
///
///     [Measure] torrent: piece 1048576 B (1.0 MiB), 7713 piece(s), 8086691840 B; file #0 of 1, 8086691840 B at offset 0 (pieces 0…7712)
///     [Measure] readiness (engine rule, recomputed by the app): head 20 piece(s) = 20971520 B of the file + tail 2 piece(s) = 1122304 B; tail pinned from 8079278080 (7413760 B), head pin 0 B; full
///     [Measure] first peer: engine +1980 ms — file 0 B · 120000 B/s · 1 peer(s), 1 seed(s)
///     [Measure] ready: t+16365 ms (engine +16200 ms) — file 30408704 B (29.0 MiB) · on disk 30408704 B (29.0 MiB) · head 20971520 B (20.0 MiB) · 4823449 B/s (4.6 MiB/s) · 11 peer(s), 9 seed(s)
///
/// Only logging: nothing here changes what the engine or the players do.
/// The app fills it from what PopcornTorrent's public API gives (the file
/// list of the selection block, `storageStatistics`, `torrentStatus`,
/// `totalDownloaded`, `bytesOnDisk`, `firstMissingOffsetFrom:`,
/// `timeSinceStart`); what that API does not give is not guessed. Each step
/// is logged once per stream. Any thread.
public final class PlaybackStartMeasure {

    /// The steps measured, in the order they usually come.
    public enum Step: String, CaseIterable {
        /// The first status with a connected peer (sampled: the loading
        /// screen's 0.5 s status and 1 s timer).
        case firstPeer = "first peer"
        /// The first status with a piece of the selected file verified on
        /// disk (same sampling).
        case firstPiece = "first piece"
        /// PopcornTorrent's `readyToPlay`: the pieces it waits for are there.
        case ready
        /// The remux's first segments are written (`[Start] remux prepare`):
        /// how much of the file it read for them.
        case remuxReady = "remux ready"
        /// A native resume: the engine is steered to the resume point
        /// (`[Resume] steering`).
        case resumeSteering = "resume steering"
        /// The start's jump is decided (`[Resume] jump decided`): the first
        /// jump before the first frame. A jump after it (a far seek or a
        /// rewind once the film plays) is no part of the start: not logged.
        case jumpDecided = "jump decided"
        /// That same jump's first segment is written (`[Resume] first segment
        /// … written`): the media at the resume point is on disk. Not logged
        /// for another segment (the jump was replaced before it was written).
        case jumpWritten = "jump written"
        /// The player plays (`[Start] first frame`).
        case firstFrame = "first frame"
    }

    /// The stream's counters at one moment.
    public struct Sample: Equatable {
        /// `totalDownloaded`: in full mode the bytes of the selected file's
        /// pieces that are on disk (verified); in bounded mode every piece
        /// downloaded once, deleted or not. Not the bytes received from peers
        /// (protocol, other files' pieces and pieces failing their hash are
        /// not in it).
        public var fileBytes: Int64
        /// `bytesOnDisk`: bytes of the file allocated on disk (holes
        /// excluded); nil before the metadata.
        public var bytesOnDisk: Int64?
        /// `firstMissingOffsetFrom: 0`: how much of the file's start is on
        /// disk without a gap; nil before the metadata.
        public var headOnDisk: Int64?
        /// libtorrent's download rate (payload and protocol), bytes/s.
        public var downloadRate: Int
        public var peers: Int
        public var seeds: Int
        /// `timeSinceStart`: seconds since PopcornTorrent started the stream.
        public var engineSeconds: TimeInterval?

        public init(fileBytes: Int64, bytesOnDisk: Int64? = nil, headOnDisk: Int64? = nil, downloadRate: Int,
                    peers: Int, seeds: Int, engineSeconds: TimeInterval? = nil) {
            self.fileBytes = fileBytes
            self.bytesOnDisk = bytesOnDisk
            self.headOnDisk = headOnDisk
            self.downloadRate = downloadRate
            self.peers = peers
            self.seeds = seeds
            self.engineSeconds = engineSeconds
        }
    }

    /// Where the selected file lies in the torrent.
    public struct Geometry: Equatable {
        public let pieceLength: Int64
        public let fileSize: Int64
        /// From the selection block's file list (every file's size, in
        /// torrent order — libtorrent's offsets are their running sum, pad
        /// files included); nil when that list was not seen.
        public let fileOffset: Int64?
        public let torrentSize: Int64?
        public let fileIndex: Int?
        public let fileCount: Int?

        public init(pieceLength: Int64, fileSize: Int64, fileOffset: Int64? = nil, torrentSize: Int64? = nil,
                    fileIndex: Int? = nil, fileCount: Int? = nil) {
            self.pieceLength = pieceLength
            self.fileSize = fileSize
            self.fileOffset = fileOffset
            self.torrentSize = torrentSize
            self.fileIndex = fileIndex
            self.fileCount = fileCount
        }

        /// The selection's file list: `sizes` in torrent order, `selected`
        /// the file streamed. nil for an index out of range.
        public init?(pieceLength: Int64, fileSize: Int64, sizes: [Int64], selected: Int) {
            guard selected >= 0, selected < sizes.count else { return nil }
            self.init(pieceLength: pieceLength, fileSize: fileSize,
                      fileOffset: sizes[..<selected].reduce(0, +), torrentSize: sizes.reduce(0, +),
                      fileIndex: selected, fileCount: sizes.count)
        }

        public var isValid: Bool { pieceLength > 0 && fileSize > 0 }

        /// The torrent's pieces (all files); nil without the file list.
        public var torrentPieceCount: Int? {
            guard pieceLength > 0, let total = torrentSize, total > 0 else { return nil }
            return Int((total + pieceLength - 1) / pieceLength)
        }

        /// The pieces holding the file's bytes (torrent piece indices); nil
        /// without the file's offset.
        public var filePieces: ClosedRange<Int>? {
            guard isValid, let offset = fileOffset else { return nil }
            return Int(offset / pieceLength)...Int((offset + fileSize - 1) / pieceLength)
        }
    }

    /// What PopcornTorrent waits for before `readyToPlay`, recomputed by the
    /// app from the engine's rule (PopcornTorrent `configureController`, fork
    /// c6296c22): the engine does not publish it. `MIN_PIECES` = 3 % of the
    /// file in pieces, from 1 to 20, from the file's first piece; then the
    /// file's last 1 piece (`MIN_PIECES` ≤ 6) or 2. Bounded mode waits for
    /// at most that many head pieces (no more than its window, which the
    /// engine does not publish).
    public struct Readiness: Equatable {
        public let headPieces: Int
        public let tailPieces: Int
        /// Bytes of the file the head pieces hold (the first one may start
        /// in the file before it in a multi-file torrent).
        public let headBytes: Int64
        public let tailBytes: Int64
        /// The head and tail pieces, a piece in both counted once.
        public let distinctPieces: Int
        /// Bounded mode: `headPieces` is an upper bound.
        public let headIsUpperBound: Bool
        /// The file's offset was unknown: the bytes assume it starts on a
        /// piece boundary (a single-file torrent always does).
        public let assumesAlignedFile: Bool

        public static func engineRule(_ geometry: Geometry, bounded: Bool) -> Readiness? {
            guard geometry.isValid else { return nil }
            let pieceLength = geometry.pieceLength, size = geometry.fileSize
            // C++: int = (int64 × 0.03) / int — truncated.
            let minimum = max(1, min(Int(Double(size) * 0.03 / Double(pieceLength)), 20))
            let tail = minimum <= 6 ? 1 : 2
            let offset = geometry.fileOffset ?? 0
            let firstPiece = offset / pieceLength
            let lastPiece = (offset + size - 1) / pieceLength
            let headEnd = (firstPiece + Int64(minimum)) * pieceLength
            let headBytes = max(0, min(offset + size, headEnd) - offset)
            let tailFirst = lastPiece - Int64(tail) + 1
            let tailBytes = max(0, offset + size - max(offset, tailFirst * pieceLength))
            var pieces = Set<Int64>()
            for index in 0..<Int64(minimum) { pieces.insert(firstPiece + index) }
            for index in 0..<Int64(tail) { pieces.insert(lastPiece - index) }
            return Readiness(headPieces: minimum, tailPieces: tail, headBytes: headBytes, tailBytes: tailBytes,
                             distinctPieces: pieces.count, headIsUpperBound: bounded,
                             assumesAlignedFile: geometry.fileOffset == nil)
        }
    }

    private let log: (String) -> Void
    private let lock = NSLock()
    private var reached: Set<Step> = []
    private var files: (sizes: [Int64], selected: Int)?
    private var geometryLogged = false
    /// The segment the start's `jumpDecided` line named.
    private var decidedJumpSegment: Int?

    public init(log: @escaping (String) -> Void = { print($0) }) {
        self.log = log
    }

    // MARK: Recording

    /// The selection block's answer: every file's size, the file streamed
    /// (none when it chose no file).
    public func noteFiles(sizes: [Int64], selected: Int) {
        lock.lock()
        if files == nil, selected >= 0, selected < sizes.count { files = (sizes, selected) }
        lock.unlock()
    }

    /// Whether `step` is still to be logged (cheap: lets the caller skip
    /// reading the counters).
    public func isPending(_ step: Step) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !reached.contains(step)
    }

    /// Logs `step`, once (false: it already was, or it is no part of the
    /// start — `admits`). `sinceTrace`: seconds since the `[Start]` trace
    /// began (its `t+`), when there is one. `segment`: the remux segment of
    /// a jump step.
    @discardableResult
    public func reach(_ step: Step, sample: Sample, sinceTrace: TimeInterval?, detail: String? = nil,
                      segment: Int? = nil) -> Bool {
        lock.lock()
        guard !reached.contains(step),
              Self.admits(step, reached: reached, decidedSegment: decidedJumpSegment, segment: segment) else {
            lock.unlock()
            return false
        }
        reached.insert(step)
        if step == .jumpDecided { decidedJumpSegment = segment }
        lock.unlock()
        log(Self.line(step, sample: sample, sinceTrace: sinceTrace, detail: detail))
        return true
    }

    /// The torrent's and the readiness requirement's lines, once, when the
    /// engine's statistics are known (at `readyToPlay`). `pieceLength` and
    /// `fileSize` come from `storageStatistics`; `tailPinStart` and
    /// `headPinEnd` too (file offsets).
    @discardableResult
    public func logGeometry(pieceLength: Int64, fileSize: Int64, bounded: Bool,
                            tailPinStart: Int64?, headPinEnd: Int64?) -> Bool {
        lock.lock()
        guard !geometryLogged else {
            lock.unlock()
            return false
        }
        geometryLogged = true
        let files = self.files
        lock.unlock()
        let geometry = files.flatMap { Geometry(pieceLength: pieceLength, fileSize: fileSize, sizes: $0.sizes, selected: $0.selected) }
            ?? Geometry(pieceLength: pieceLength, fileSize: fileSize)
        log(Self.torrentLine(geometry))
        log(Self.readinessLine(geometry, bounded: bounded, tailPinStart: tailPinStart, headPinEnd: headPinEnd))
        return true
    }

    /// Whether `step` belongs to the start, given the steps `reached`: a
    /// jump is the start's only before the first frame, and its « written »
    /// line only for the segment its « decided » line named (and only after
    /// it). The other steps always do (once).
    public static func admits(_ step: Step, reached: Set<Step>, decidedSegment: Int?, segment: Int?) -> Bool {
        switch step {
        case .jumpDecided:
            return !reached.contains(.firstFrame)
        case .jumpWritten:
            guard !reached.contains(.firstFrame), reached.contains(.jumpDecided) else { return false }
            guard let decided = decidedSegment, let segment = segment else { return true }
            return decided == segment
        default:
            return true
        }
    }

    // MARK: Lines

    /// `[Measure] <step>: t+<ms> ms (engine +<ms> ms) — <counters>[ — <detail>]`.
    public static func line(_ step: Step, sample: Sample, sinceTrace: TimeInterval?, detail: String? = nil) -> String {
        var clocks: [String] = []
        if let since = sinceTrace { clocks.append("t+\(milliseconds(since)) ms") }
        if let engine = sample.engineSeconds { clocks.append("engine +\(milliseconds(engine)) ms") }
        var line = "[Measure] \(step.rawValue):"
        if let first = clocks.first {
            line += " " + first
            if clocks.count > 1 { line += " (\(clocks[1]))" }
        }
        line += " — " + counters(sample)
        if let detail = detail, !detail.isEmpty { line += " — " + detail }
        return line
    }

    /// `file <B> · on disk <B> · head <B> · <B/s> · <n> peer(s), <n> seed(s)`.
    public static func counters(_ sample: Sample) -> String {
        var parts = ["file \(bytes(sample.fileBytes))"]
        if let onDisk = sample.bytesOnDisk { parts.append("on disk \(bytes(onDisk))") }
        if let head = sample.headOnDisk { parts.append("head \(bytes(head))") }
        parts.append(rate(sample.downloadRate))
        parts.append("\(max(0, sample.peers)) peer(s), \(max(0, sample.seeds)) seed(s)")
        return parts.joined(separator: " · ")
    }

    /// `[Measure] torrent: piece <B>, <n> piece(s), <B>; file #<i> of <n>, <B> at offset <B> (pieces a…b)`.
    public static func torrentLine(_ geometry: Geometry) -> String {
        guard geometry.isValid else { return "[Measure] torrent: unknown (no piece length or file size from the engine)" }
        var line = "[Measure] torrent: piece \(bytes(geometry.pieceLength))"
        if let count = geometry.torrentPieceCount, let total = geometry.torrentSize {
            line += ", \(count) piece(s), \(total) B"
        } else {
            line += ", piece count unknown (no file list)"
        }
        line += "; file"
        if let index = geometry.fileIndex, let count = geometry.fileCount { line += " #\(index) of \(count)," }
        line += " \(geometry.fileSize) B"
        if let offset = geometry.fileOffset {
            line += " at offset \(offset)"
            if let pieces = geometry.filePieces { line += " (pieces \(pieces.lowerBound)…\(pieces.upperBound))" }
        } else {
            line += " at an unknown offset"
        }
        return line
    }

    /// `[Measure] readiness (engine rule, recomputed by the app): head <n> piece(s) = <B> of the file + tail <n> piece(s) = <B>; tail pinned from <offset> (<B>), head pin <B>`.
    public static func readinessLine(_ geometry: Geometry, bounded: Bool, tailPinStart: Int64?, headPinEnd: Int64?) -> String {
        guard let rule = Readiness.engineRule(geometry, bounded: bounded) else {
            return "[Measure] readiness: unknown (no piece length or file size)"
        }
        var line = "[Measure] readiness (engine rule, recomputed by the app): head "
            + (rule.headIsUpperBound ? "at most " : "")
            + "\(rule.headPieces) piece(s) = \(rule.headBytes) B of the file + tail \(rule.tailPieces) piece(s) = \(rule.tailBytes) B"
        if rule.distinctPieces < rule.headPieces + rule.tailPieces { line += " (\(rule.distinctPieces) distinct piece(s))" }
        if rule.assumesAlignedFile { line += " (offset unknown: file assumed piece-aligned)" }
        var pins: [String] = []
        if let tail = tailPinStart, tail >= 0, tail < geometry.fileSize {
            pins.append("tail pinned from \(tail) (\(geometry.fileSize - tail) B)")
        }
        if let head = headPinEnd { pins.append("head pin \(max(0, head)) B") }
        if !pins.isEmpty { line += "; " + pins.joined(separator: ", ") }
        line += bounded ? "; bounded" : "; full"
        return line
    }

    /// `<n> B (<x> MiB)`, the MiB part from 1 MiB on.
    static func bytes(_ value: Int64) -> String {
        let mebibytes = Double(value) / 1_048_576
        return mebibytes >= 1 ? String(format: "%lld B (%.1f MiB)", value, mebibytes) : "\(value) B"
    }

    /// `<n> B/s (<x> MiB/s)`, the MiB/s part from 1 MiB/s on.
    static func rate(_ bytesPerSecond: Int) -> String {
        let value = max(0, bytesPerSecond)
        let mebibytes = Double(value) / 1_048_576
        return mebibytes >= 1 ? String(format: "%d B/s (%.1f MiB/s)", value, mebibytes) : "\(value) B/s"
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds * 1000, 1e12).rounded())
    }
}
