//
//  JumpWaitProgress.swift
//  PopcornKit
//
//  What « Resuming at 22:35… » can say while the conversion waits for the media at a position
//  it jumped to (a resume, a far seek, a rewind into what a jump skipped).
//
//  Why (Apple TV, 16 November 2026, 5.3.0's first device session): a « Resume » from a show's
//  page waited 110 s under « Resuming at 22:35… » with nothing moving on screen, while the
//  engine brought the 160 MiB around the target — its front pieces last. The viewer could not
//  tell a slow download from a frozen app. The share of the bytes the player needs there that
//  is already on disk, and the download rate, say it: « Resuming at 22:35 — 45% · 9.6 MB/s ».
//  Counted piece by piece, not only from the front: on the device the front pieces came last,
//  and a contiguous count would have shown the same number for 100 s.
//

import Foundation

/// One look at a wait for the media at a position the conversion jumped to (pure value; the remux
/// refreshes it on its 1 s tick, the player formats it).
public struct JumpWaitProgress: Equatable {
    /// The position waited on (player timeline, s); nil when not known yet (a resume whose position
    /// the conversion has not placed).
    public var targetSeconds: Double?
    /// The segment of that position; nil when not known yet.
    public var segment: Int?
    /// Seconds since the wait began (the jump; for a resume not jumped yet, its preparation).
    public var waitedSeconds: TimeInterval
    /// Seconds the viewer has waited for this position, when longer than `waitedSeconds`: a resume's
    /// jump starts its own clock, but « Resuming at … » was up (with its share) since the resume was
    /// prepared — the label keeps its detail across the jump (`labelClockStart`). nil: `waitedSeconds`.
    public var labelSeconds: TimeInterval?
    /// A jump was made (false: a resume still on its way to its jump).
    public var isJump: Bool
    /// Bytes of the file the player needs to start there (`JumpWaitProgressRule` says which); nil
    /// when not known.
    public var neededBytes: Int64?
    /// Of those, the bytes on disk now; nil when not known.
    public var onDiskBytes: Int64?
    /// The share shown (0…1): never lower than before for the same target, 1 only once the media
    /// to start there is written (`isMediaReady`); nil when the bytes needed are not known.
    public var shownFraction: Double?
    /// The media to start at the target is written (the player can make its item there).
    public var isMediaReady: Bool
    /// The engine's download rate (bytes/s) and connected peers.
    public var bytesPerSecond: Int
    public var peers: Int
    /// Diagnostics (the `[Resume] jump wait` lines): where the conversion reads, the first byte
    /// missing from there, its piece in the file (0: the file's first piece), and the engine's
    /// window (0…1).
    public var reader: Int64?
    public var firstMissing: Int64?
    public var firstMissingPiece: Int?
    public var window: Double?

    public init(targetSeconds: Double?, segment: Int?, waitedSeconds: TimeInterval, isJump: Bool,
                neededBytes: Int64? = nil, onDiskBytes: Int64? = nil, shownFraction: Double? = nil,
                isMediaReady: Bool = false, bytesPerSecond: Int = 0, peers: Int = 0, reader: Int64? = nil,
                firstMissing: Int64? = nil, firstMissingPiece: Int? = nil, window: Double? = nil,
                labelSeconds: TimeInterval? = nil) {
        self.targetSeconds = targetSeconds
        self.labelSeconds = labelSeconds
        self.segment = segment
        self.waitedSeconds = waitedSeconds
        self.isJump = isJump
        self.neededBytes = neededBytes
        self.onDiskBytes = onDiskBytes
        self.shownFraction = shownFraction
        self.isMediaReady = isMediaReady
        self.bytesPerSecond = bytesPerSecond
        self.peers = peers
        self.reader = reader
        self.firstMissing = firstMissing
        self.firstMissingPiece = firstMissingPiece
        self.window = window
    }
}

/// The rules of `JumpWaitProgress` (pure — the tests drive them).
///
/// The bytes the player needs to start at a jump's target: from the jump's read offset (the
/// Cluster it starts reading at, lead-in included) to the end of what `RemuxPlayback.hasMediaToStart`
/// asks for — the target's segment through the first instant of the next one, which the
/// conversion writes once it has read the Cluster of the keyframe that ends that next segment (the
/// keyframe two segments after the target's, from the file's keyframe index; the Cluster's end is
/// not in the index, the app estimates it: `RemuxPlayback.waitProgressEnd`).
public enum JumpWaitProgressRule {
    /// No share for a wait shorter than this (s): a jump over media that comes at once shows
    /// « Resuming at … » alone, never a number that flickers.
    public static let minimumWaitSeconds: TimeInterval = 1
    /// The probe step (bytes) when the piece length is not known (no engine statistics).
    public static let unknownPieceStep: Int64 = 1 << 20
    /// The `[Resume] jump wait` lines: at these seconds of the wait, then every `logEverySeconds`.
    public static let logSteps = [2, 5, 10]
    public static let logEverySeconds = 10

    /// Bytes on disk in [`start`, `end`), counted piece by piece — a missing piece does not hide the
    /// pieces after it — from the engine's `firstMissingOffset` (`firstMissing(offset)`: the first
    /// offset at or after `offset` not on disk, `offset` itself when its piece is missing).
    /// `pieceLength`: the torrent's (≤ 0: unknown, probed every `unknownPieceStep`, which can only
    /// count less); `pieceBoundary`: any offset of the file where a piece starts (the engine's tail
    /// pin start; 0 for a file that starts the torrent).
    public static func bytesOnDisk(from start: Int64, to end: Int64, pieceLength: Int64, pieceBoundary: Int64,
                                   firstMissing: (Int64) -> Int64) -> Int64 {
        var position = max(0, start)
        guard end > position else { return 0 }
        var total: Int64 = 0
        var probes = 0
        while position < end, probes < 1_000_000 {
            probes += 1
            let missing = max(position, firstMissing(position))
            total += min(missing, end) - position
            guard missing < end else { break }
            // The piece of `missing` is not on disk: go on at the next piece.
            position = nextPieceStart(after: missing, pieceLength: pieceLength, pieceBoundary: pieceBoundary)
        }
        return min(total, end - max(0, start))
    }

    /// The first piece start strictly after `offset` (file offsets).
    public static func nextPieceStart(after offset: Int64, pieceLength: Int64, pieceBoundary: Int64) -> Int64 {
        guard pieceLength > 0 else { return offset + unknownPieceStep }
        let base = ((pieceBoundary % pieceLength) + pieceLength) % pieceLength
        let delta = offset - base
        let index = delta >= 0 ? delta / pieceLength : -((-delta + pieceLength - 1) / pieceLength)
        return base + (index + 1) * pieceLength
    }

    /// The piece of the file holding `offset` — 0 for the file's first piece, which may start in the
    /// file before it (the `[Measure] torrent` line gives the torrent index of the file's first
    /// piece); nil when the piece length is not known.
    public static func filePiece(of offset: Int64, pieceLength: Int64, pieceBoundary: Int64) -> Int? {
        guard pieceLength > 0, offset >= 0 else { return nil }
        let base = ((pieceBoundary % pieceLength) + pieceLength) % pieceLength
        guard offset >= base else { return 0 }
        return Int((offset - base) / pieceLength) + (base > 0 ? 1 : 0)
    }

    /// The share to show: `onDisk` of `needed`, never more than 99 % while the media is not written
    /// (the last bytes of the Cluster that ends the second segment, the cut itself), 100 % once it
    /// is (`isMediaReady`, whatever the count). nil when the bytes needed are not known.
    public static func fraction(onDisk: Int64?, needed: Int64?, isMediaReady: Bool) -> Double? {
        if isMediaReady { return 1 }
        guard let needed = needed, needed > 0, let onDisk = onDisk else { return nil }
        return min(0.99, max(0, Double(onDisk) / Double(needed)))
    }

    /// Whether the wait shows more than « Resuming at … »: not before `minimumWaitSeconds`.
    /// Measured on the label's clock (`labelSeconds`), not the jump's: a resume's jump does not take
    /// away the share the label already showed.
    public static func showsDetail(_ progress: JumpWaitProgress) -> Bool {
        max(progress.waitedSeconds, progress.labelSeconds ?? 0) >= minimumWaitSeconds
    }

    /// When the label's wait began (uptime, s): a resume's jump (`isResumeJump`) continues the wait
    /// of the resume's preparation (`resumeStartedAt`, the steering or the first tick — the label was
    /// up, its share counted for the same segment); any other jump starts its own wait.
    public static func labelClockStart(jumpStartedAt: TimeInterval, isResumeJump: Bool,
                                       resumeStartedAt: TimeInterval?) -> TimeInterval {
        guard isResumeJump, let resume = resumeStartedAt, resume.isFinite else { return jumpStartedAt }
        return min(jumpStartedAt, resume)
    }

    /// The percentage shown (0…100), nil when none is (wait too short, bytes needed not known).
    public static func shownPercent(_ progress: JumpWaitProgress) -> Int? {
        guard showsDetail(progress), let fraction = progress.shownFraction else { return nil }
        if progress.isMediaReady || fraction >= 1 { return 100 }
        return min(99, max(0, Int((fraction * 100).rounded(.down))))
    }

    /// The rate shown (bytes/s), nil when none is (wait too short, nothing coming in).
    public static func shownRate(_ progress: JumpWaitProgress) -> Int? {
        guard showsDetail(progress), progress.bytesPerSecond > 0 else { return nil }
        return progress.bytesPerSecond
    }

    /// The `[Resume] jump wait` step due after `waited` seconds of a wait, when `lastLogged` was the
    /// last step logged (nil: none): +2, +5, +10 s, then every 10 s; nil when none is due. A late
    /// tick that crossed several steps logs the last one only.
    public static func logStep(waited: TimeInterval, lastLogged: Int?) -> Int? {
        guard waited.isFinite, waited >= Double(logSteps[0]) else { return nil }
        let seconds = Int(waited.rounded(.down))
        let due: Int
        if let last = logSteps.last(where: { $0 <= seconds }), seconds < logSteps[logSteps.count - 1] + logEverySeconds {
            due = last
        } else {
            due = seconds / logEverySeconds * logEverySeconds
        }
        guard due > (lastLogged ?? 0) else { return nil }
        return due
    }

    /// "[Resume] jump wait +5 s: reader 5732921423, first missing 5740000000 (piece 683 of the
    /// file), on disk 12345678 of 80000000 bytes of the target (15 %), window 45 %, 9.6 MB/s, 17 peers".
    public static func logLine(step: Int, _ progress: JumpWaitProgress) -> String {
        var line = "[Resume] jump wait +\(step) s: reader \(progress.reader.map { "\($0)" } ?? "?")"
        line += ", first missing \(progress.firstMissing.map { "\($0)" } ?? "?")"
        if let piece = progress.firstMissingPiece { line += " (piece \(piece) of the file)" }
        if let needed = progress.neededBytes {
            line += ", on disk \(progress.onDiskBytes.map { "\($0)" } ?? "?") of \(needed) bytes of the target"
        } else {
            line += ", bytes of the target not known"
        }
        if let fraction = progress.shownFraction {
            let percent = progress.isMediaReady || fraction >= 1 ? 100 : min(99, Int((fraction * 100).rounded(.down)))
            line += " (\(percent) %)"
        }
        if progress.isMediaReady { line += ", media written" }
        if let window = progress.window { line += ", window \(Int((window * 100).rounded())) %" }
        line += String(format: ", %.1f MB/s, %d peers", Double(max(0, progress.bytesPerSecond)) / 1_000_000, max(0, progress.peers))
        if let target = progress.targetSeconds, let segment = progress.segment {
            line += String(format: " — target %.1f s, segment %d", target, segment)
        }
        return line
    }
}

/// Keeps the share shown from going backwards for the same target (pure — the tests drive it): a
/// count can drop by a piece (bounded storage, a piece failing its hash and fetched again), the
/// screen does not. A new target starts again from its own count.
public struct JumpWaitProgressTracker: Equatable {
    public struct Key: Equatable {
        public let segment: Int?
        public let startOffset: Int64?
        public init(segment: Int?, startOffset: Int64?) {
            self.segment = segment
            self.startOffset = startOffset
        }
    }

    public private(set) var key: Key?
    public private(set) var best: Double?

    public init() {}

    /// The share to show for `key` now that the count says `fraction` (nil: not known).
    public mutating func shown(_ fraction: Double?, for key: Key) -> Double? {
        if self.key != key {
            self.key = key
            best = nil
        }
        guard let fraction = fraction, fraction.isFinite else { return best }
        let value = max(best ?? 0, min(1, max(0, fraction)))
        best = value
        return value
    }

    /// Forgets the target (the wait is over).
    public mutating func reset() {
        key = nil
        best = nil
    }
}
