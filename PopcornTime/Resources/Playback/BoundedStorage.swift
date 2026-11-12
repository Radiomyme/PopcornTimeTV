import Foundation

// Bounded storage, app side: pure logic (no PopcornTorrent, no UIKit), shared
// by tvOS, iOS and macOS and compiled alone by the unit benches.
//
// A film larger than the free space streams in "bounded" mode
// (PopcornTorrent `PTStorageModeBounded`): the torrent keeps only a window of
// the file, and the app tells it what it may delete (`consumedBefore`) and
// what it reads next (`readPosition`). Two consumers share the free space:
// the torrent's window and, on the remux route, the HLS copy AVPlayer plays
// (its segments behind the playhead are the native rewind). `StorageBudget`
// splits that space (report_4 B4); `MediaByteMap` maps media times to file
// offsets conservatively for the HTTP routes (VLC, direct MP4), which read
// the file through PopcornTorrent's server and have no segment map of their
// own. The glue to PopcornTorrent and the players is
// `BoundedStorageSession` (BoundedStorageSession.swift).

enum BoundedStorage {
    static let kiB: Int64 = 1 << 10
    static let miB: Int64 = 1 << 20
    static let giB: Int64 = 1 << 30

    /// Free space bounded storage never uses (the user's decision): 512 MiB,
    /// given to PopcornTorrent as `storageReserve` and kept out of every
    /// budget below.
    static let reserveBytes: Int64 = 512 << 20

    /// Head and tail pins of PopcornTorrent's window (`kHeadPinLimit`, 64 MiB;
    /// the tail: whole pieces for 8 MiB, 2 to 10 of them — `tailPinPieces`),
    /// and the piece length assumed when it is not known yet (the largest
    /// common one: budgets come out a little high, never short).
    static let headPinBytes: Int64 = 64 << 20
    static let assumedPieceLength: Int64 = 16 << 20

    /// PopcornTorrent's tail pin in bytes for `pieceLength`
    /// (`tailPinPieces` of PTBoundedLogic.cpp: ⌈8 MiB / piece⌉ pieces, 2…10).
    static func tailPinBytes(pieceLength: Int64) -> Int64 {
        let piece = max(16 * kiB, pieceLength)
        let forBytes = (8 * miB + piece - 1) / piece
        return max(2, min(forBytes, 10)) * piece
    }

    /// The bitrate PopcornTorrent assumes when the duration is unknown:
    /// the file over 2 hours.
    static let assumedDurationSeconds: Double = 2 * 3600

    /// Source bytes per second of media: `fileSize / duration` (2 h when the
    /// duration is unknown or absurd).
    static func sourceBytesPerSecond(fileSize: Int64, durationSeconds: Double) -> Double {
        let duration = durationSeconds.isFinite && durationSeconds >= 60 ? durationSeconds : assumedDurationSeconds
        return Double(max(0, fileSize)) / duration
    }

    /// The least free space PopcornTorrent needs to stream `fileSize` bytes
    /// in bounded mode (its `planBudget` minimum working set: reserve, pins,
    /// max(256 MiB, 60 s) ahead, the in-flight allowance and 240 s of the
    /// app's HLS copy), with `pieceLength` (0: `assumedPieceLength`). Used to
    /// tell the user how much to free when the stream is refused
    /// (`PTTorrentStreamerErrorNotEnoughSpaceForBoundedStorage`), whose error
    /// carries only a sentence.
    static func minimumFreeBytes(fileSize: Int64, durationSeconds: Double, pieceLength: Int64 = 0,
                                 reserve: Int64 = reserveBytes) -> Int64 {
        let piece = pieceLength > 0 ? max(pieceLength, 16 * kiB) : assumedPieceLength
        let bps = sourceBytesPerSecond(fileSize: fileSize, durationSeconds: durationSeconds)
        let pins = headPinBytes + tailPinBytes(pieceLength: piece)
        let minAhead = roundUp(max(256 * miB, Int64(60 * bps)), to: piece)
        let inflight = max(32 * miB, 4 * piece)
        // The app's HLS copy (240 s) and its headroom (`kAppHeadroomBytes`,
        // `kAppHeadroomSeconds` of PTBoundedLogic.hpp: the segment being written).
        let appHeadroom = max(32 * miB, Int64(20 * bps))
        return max(0, reserve) + pins + minAhead + inflight + Int64(240 * bps) + appHeadroom
    }

    /// Media the app keeps next to the WHOLE file in full mode, in seconds
    /// at the file's bitrate (PopcornTorrent `appWorkingSetSeconds`): the
    /// remux's HLS segments no disk budget deletes — 180 s behind and 180 s
    /// ahead of the playhead (`RemuxPlayback.minimumKeepBehindSeconds`,
    /// `lookaheadSeconds`) — plus the segment being written and a margin.
    /// A film that fits only without them streams bounded instead: in full
    /// mode the torrent (sparse) and the HLS copy would fill the volume
    /// together and the download would fail late in the film (-4).
    static let fullModeAppWorkingSetSeconds: Double = 400

    /// HTTP routes, a rewind to `target` (media seconds) that lies below the
    /// earliest point of the run of data ending at the server's read position
    /// (`BoundedStorageSession.httpEarliestRewind`): is it still served from
    /// data on disk — a stretch the player read, or the torrent's window held,
    /// before a forward seek left a gap above it (verify-playback 1: Mac
    /// vgap1, tvOS tvb1)? The player resumes from the keyframe before
    /// `target`, at or above `low = lowerBound(target − margin)` (a lower
    /// bound: `MediaByteMap`). `low` must be at or above
    /// `lowestAvailableOffset` — nothing below it is ever read, so never an
    /// HTTP 410 — and the file on disk from `low` up to an ESTIMATE of the
    /// offset of `target + margin`: `low`'s anchor plus the media time since
    /// it at the average bitrate. A wrong estimate only lets the player go on
    /// into a part it then downloads (above the floor, never deleted data);
    /// a gap a forward seek left (never downloaded) stays out of reach, as the
    /// user's rule asks. Pure.
    static func httpRewindTargetIsOnDisk(target: Double, map: MediaByteMap, lowestAvailableOffset: Int64,
                                         bytesPerSecond: Double, marginSeconds: Double,
                                         firstMissingOffset: (Int64) -> Int64) -> Bool {
        guard target.isFinite, target >= 0, bytesPerSecond.isFinite, bytesPerSecond > 0 else { return false }
        let anchor = map.anchor(atOrBefore: target - marginSeconds)
        let low = anchor?.byte ?? 0
        guard low >= max(0, lowestAvailableOffset) else { return false }
        let since = max(0, target + marginSeconds - (anchor?.time ?? 0))
        let estimate = low + Int64(since * bytesPerSecond)
        return firstMissingOffset(low) >= estimate
    }

    /// HTTP routes' release (`consumedBefore`): the larger of the time rule
    /// (`byTime`: the file below what a rewind of the split's depth needs,
    /// from the time → offset map) and the byte rule (`byBytes`: the server's
    /// read position minus what the split keeps behind it) — never past the
    /// read position `served` (0: unknown, the time rule alone).
    static func httpConsumedBefore(byTime: Int64, byBytes: Int64, served: Int64) -> Int64 {
        guard served > 0 else { return max(0, byTime) }
        return max(0, min(served, max(byTime, byBytes)))
    }

    /// The bytes to free so that a refused stream can run: what
    /// `minimumFreeBytes` asks beyond the free space now (and what the
    /// file already holds), rounded up to 100 MB so the message never asks
    /// for less than needed. 0 when it fits already.
    static func bytesToFree(fileSize: Int64, durationSeconds: Double, freeBytes: Int64, heldBytes: Int64 = 0,
                            pieceLength: Int64 = 0) -> Int64 {
        let needed = minimumFreeBytes(fileSize: fileSize, durationSeconds: durationSeconds, pieceLength: pieceLength)
            - max(0, freeBytes) - max(0, heldBytes)
        guard needed > 0 else { return 0 }
        let step: Int64 = 100_000_000
        return (needed + step - 1) / step * step
    }

    static func roundUp(_ value: Int64, to multiple: Int64) -> Int64 {
        guard multiple > 0 else { return value }
        return (max(0, value) + multiple - 1) / multiple * multiple
    }

    // MARK: Remux route

    /// The offset below which the torrent may delete the file on the REMUX
    /// route (`consumedBefore`), never past what the remux has read
    /// (`readerOffset`, strictly forward): the torrent keeps what a hand-off
    /// to VLC AT THE PLAYHEAD needs — from `playheadSourceOffset`, the
    /// source offset of the Matroska cluster that starts the segment before
    /// the playhead's (VLC seeks to the keyframe at or before its target) —
    /// up to the reader, as long as the budget gives it `keepBehindBytes`
    /// behind the reader. When space is short that keep is cut first
    /// (`StorageBudget`): the bound moves up toward the reader. nil
    /// `playheadSourceOffset` (no position yet, or before the first
    /// segment): only the budget decides.
    static func remuxConsumedBefore(readerOffset: Int64, playheadSourceOffset: Int64?, keepBehindBytes: Int64) -> Int64 {
        let reader = max(0, readerOffset)
        let byBudget = reader - max(0, keepBehindBytes)
        let floor = max(byBudget, playheadSourceOffset.map { max(0, $0) } ?? byBudget)
        return min(reader, max(0, floor))
    }

    /// The first segment of the run of kept segments that ends at
    /// `playheadSegment` (written, not pruned): the earliest segment a native
    /// rewind reaches without a hole. Segment 0 counts only when the run
    /// reaches it. nil when the playhead's segment itself is not available.
    static func earliestContiguousKeptSegment(playheadSegment: Int, written: Int, pruned: IndexSet) -> Int? {
        guard playheadSegment >= 0, playheadSegment < written, !pruned.contains(playheadSegment) else { return nil }
        var first = playheadSegment
        while first > 0 && !pruned.contains(first - 1) { first -= 1 }
        return first
    }
}

// MARK: - Budget split (report_4 B4)

/// How the free space is split in bounded mode, re-evaluated with fresh
/// numbers (every few seconds): never-used reserve, the torrent's window
/// (PopcornTorrent `storageBudget`: pins, in-flight data, data ahead of the
/// reader and data kept behind it) and, on the remux route, the HLS copy
/// (`RemuxPlayback`'s allowance: one lookahead ahead of the playhead plus
/// the native rewind behind it). Priorities, highest first:
///  1. the reserve (512 MiB), the pins, the in-flight allowance and
///     PopcornTorrent's minimum ahead (max(256 MiB, 60 s));
///  2. remux: the HLS lookahead (180 s) and 60 s of HLS rewind;
///     HTTP routes: 60 s kept behind the player;
///  3. the torrent's ahead window up to its target (~5 min, at most 1 GiB);
///  4. remux: the torrent data between the playhead and the reader (what a
///     hand-off to VLC at the playhead needs, ~180 s) — dropped first when
///     space is short;
///  5. the rest: the native rewind (remux: HLS behind; HTTP routes: the
///     torrent kept behind the player).
/// Pure: the same numbers always give the same split.
struct StorageBudget: Equatable {

    enum Route: String, Equatable {
        /// The remux reads the file and keeps an HLS copy.
        case remux
        /// VLC or AVPlayer read the file through PopcornTorrent's HTTP server.
        case http
    }

    struct Input: Equatable {
        var route: Route
        /// Free space of the volume now (fresh reading).
        var freeBytes: Int64
        /// Bytes the torrent file holds on disk now (`bytesOnDisk`).
        var torrentBytesOnDisk: Int64
        /// Deletable HLS segments kept on disk now (remux route; 0 otherwise).
        var hlsDeletableBytes: Int64 = 0
        /// Source bitrate (file size / duration), bytes per second of media.
        var sourceBytesPerSecond: Double
        /// The remux's output rate (bytes per second of media); nil: the
        /// source rate.
        var outputBytesPerSecond: Double? = nil
        /// The torrent's piece length (0: unknown).
        var pieceLength: Int64 = 0
        var reserveBytes: Int64 = BoundedStorage.reserveBytes
        /// The remux lookahead (`RemuxPlayback.lookaheadSeconds`).
        var lookaheadSeconds: Double = 180
        /// HTTP routes: how far (s of media) the player reads ahead of its
        /// playhead at most (kept between the playhead and the reader).
        var playerReadAheadSeconds: Double = 30
        /// Remux: the bytes now between the cluster before the playhead and
        /// the remux's reader (AVPlayer's own requests can pull the reader
        /// past one lookahead). The keep's target follows it, between
        /// (lookahead + `failoverMarginSeconds`) and twice that. nil: unknown.
        var failoverKeepObservedBytes: Int64? = nil
    }

    /// What both consumers may use together: free + torrent + HLS − reserve.
    var roomBytes: Int64 = 0
    /// PopcornTorrent `storageBudget`: pins + in-flight + ahead + kept behind.
    var torrentBudget: Int64 = 0
    var torrentAheadBytes: Int64 = 0
    /// What the torrent may keep behind its reader (remux: the playhead →
    /// reader data for a VLC hand-off at the playhead; HTTP: the rewind
    /// window plus the player's read-ahead).
    var torrentKeepBehindBytes: Int64 = 0
    /// Remux: `RemuxPlayback`'s allowance of deletable segments in bounded
    /// mode (HLS ahead + behind); 0 on HTTP routes.
    var hlsAllowedBytes: Int64 = 0
    var hlsAheadBytes: Int64 = 0
    var hlsBehindBytes: Int64 = 0
    /// Native rewind depth the split gives (s of media): HLS behind / the
    /// output rate (remux), or the torrent kept behind the playhead / the
    /// source rate (HTTP).
    var rewindSeconds: Double = 0
    /// Remux: the span behind each position the eviction never deletes in
    /// bounded mode (`RemuxPlayback.minimumKeepBehindSeconds` = 180 s
    /// normally, down to 60 s when the HLS rewind is shorter).
    var protectBehindSeconds: Double = 180
    /// The playhead → reader keep (remux) was cut below its target.
    var failoverKeepCut = false

    static let minimumRewindSeconds: Double = 60
    /// Beyond the lookahead, what the playhead → reader keep covers: the
    /// segment before the playhead's (VLC seeks to the keyframe at or before
    /// its target) and the pump's bursts past the lookahead (3 segments).
    static let failoverMarginSeconds: Double = 45
    static let aheadTargetSeconds: Double = 300
    static let headroomSeconds: Double = 20

    init() {}

    init(_ input: Input) {
        let piece = input.pieceLength > 0 ? max(input.pieceLength, 16 * BoundedStorage.kiB) : BoundedStorage.assumedPieceLength
        let src = input.sourceBytesPerSecond.isFinite && input.sourceBytesPerSecond > 0 ? input.sourceBytesPerSecond : 0
        let out = (input.outputBytesPerSecond.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }) ?? src
        let lookahead = max(0, input.lookaheadSeconds)
        let pins = BoundedStorage.headPinBytes + BoundedStorage.tailPinBytes(pieceLength: piece)
        let inflight = max(32 * BoundedStorage.miB, 4 * piece)
        let minAhead = BoundedStorage.roundUp(max(256 * BoundedStorage.miB, Int64(60 * src)), to: piece)
        let aheadTarget = min(max(Int64(Self.aheadTargetSeconds * src), minAhead), max(minAhead, BoundedStorage.giB))

        let hls = input.route == .remux ? max(0, input.hlsDeletableBytes) : 0
        let room = max(0, input.freeBytes) + max(0, input.torrentBytesOnDisk) + hls - max(0, input.reserveBytes)
        roomBytes = room

        switch input.route {
        case .remux:
            let hlsAhead = Int64(lookahead * out)
            let hlsBehindMin = Int64(Self.minimumRewindSeconds * out)
            let headroom = max(32 * BoundedStorage.miB, Int64(Self.headroomSeconds * out))
            var rest = room - (pins + inflight + minAhead) - hlsAhead - hlsBehindMin - headroom
            let extraAhead = min(aheadTarget - minAhead, max(0, rest))
            rest -= extraAhead
            let keepFloor = Int64((lookahead + Self.failoverMarginSeconds) * src)
            let keepTarget = min(max(keepFloor, input.failoverKeepObservedBytes ?? 0), 2 * keepFloor)
            let keep = min(keepTarget, max(0, rest))
            rest -= keep
            torrentAheadBytes = minAhead + extraAhead
            torrentKeepBehindBytes = keep
            failoverKeepCut = keep < keepTarget
            torrentBudget = pins + inflight + torrentAheadBytes + keep
            // What the HLS copy may keep: what is left once the torrent has
            // its budget and the headroom (the segment being written) is set
            // aside — the same as `room − torrentBudget − headroom` while the
            // torrent is within its budget, less when it holds more (its
            // excess is already out of the free space).
            let torrentStillToAdd = max(0, torrentBudget - max(0, input.torrentBytesOnDisk))
            let allowed = max(0, input.freeBytes) + hls - max(0, input.reserveBytes) - torrentStillToAdd - headroom
            hlsAllowedBytes = max(0, allowed)
            hlsAheadBytes = min(hlsAhead, hlsAllowedBytes)
            hlsBehindBytes = max(0, hlsAllowedBytes - hlsAhead)
            rewindSeconds = out > 0 ? Double(hlsBehindBytes) / out : 0
            protectBehindSeconds = min(180, max(Self.minimumRewindSeconds, rewindSeconds.rounded(.down)))
        case .http:
            let readAhead = Int64(max(0, input.playerReadAheadSeconds) * src)
            let behindMin = Int64(Self.minimumRewindSeconds * src) + readAhead
            // Left free above the reserve: partial pieces, holes not punched
            // yet, the in-flight data of a seek (the torrent is held to its
            // budget in bytes on this route: `httpConsumedBefore`).
            let headroom = max(32 * BoundedStorage.miB, Int64(Self.headroomSeconds * src))
            var rest = room - (pins + inflight + minAhead) - behindMin - headroom
            let extraAhead = min(aheadTarget - minAhead, max(0, rest))
            rest -= extraAhead
            torrentAheadBytes = minAhead + extraAhead
            torrentKeepBehindBytes = behindMin + max(0, rest)
            torrentBudget = pins + inflight + torrentAheadBytes + torrentKeepBehindBytes
            rewindSeconds = src > 0 ? Double(max(0, torrentKeepBehindBytes - readAhead)) / src : 0
            protectBehindSeconds = 180
        }
    }

    /// Rewind depth in whole minutes, for the UX ("~N min"): rounded down,
    /// at least 1 while any rewind is kept.
    var rewindMinutes: Int {
        guard rewindSeconds.isFinite, rewindSeconds > 0 else { return 0 }
        return max(1, Int(rewindSeconds / 60))
    }
}

// MARK: - Media time → file offset (HTTP routes)

/// A conservative map from media time to file offset: a staircase of
/// anchors (t, b) meaning "a player that resumes at a time ≥ t needs the
/// file from an offset ≥ b". It is only ever a LOWER bound of the real
/// offset, so:
///  - deleting the file below `lowerBound(atTime: t − K)` keeps every byte a
///    rewind to t − K needs (`consumedBefore` of the HTTP routes);
///  - every time ≥ `earliestTime(atOrAbove: b)` needs nothing below b (the
///    earliest rewind once the file below b is gone).
/// Anchors come from the remux's segment map (the cluster each segment
/// starts with, carried over a hand-off to VLC) and from the HTTP routes
/// themselves: while a player plays steadily, its server read position
/// at a playhead p is past every byte p + its read-ahead needs, so
/// (p + `readAheadSeconds`, read position) is a lower bound. Dropping an
/// anchor only lowers the bound: the map is thinned when it grows.
struct MediaByteMap: Equatable {
    struct Anchor: Equatable {
        var time: Double
        var byte: Int64
    }

    /// Times strictly increasing, bytes strictly increasing.
    private(set) var anchors: [Anchor] = []
    /// The map is thinned (every other anchor dropped) past this count.
    var capacity = 4096

    init() {}

    /// Adds the lower bound "from `time` on, offsets ≥ `byte`". Anchors it
    /// makes redundant (later, not higher) go; a redundant new one is
    /// ignored.
    mutating func add(time: Double, byte: Int64) {
        guard time.isFinite, time >= 0, byte > 0 else { return }
        if lowerBound(atTime: time) >= byte { return }
        let index = anchors.firstIndex { $0.time >= time } ?? anchors.count
        // Later anchors not above the new byte are implied by it.
        var end = index
        while end < anchors.count && anchors[end].byte <= byte { end += 1 }
        anchors.replaceSubrange(index..<end, with: [Anchor(time: time, byte: byte)])
        if anchors.count > max(16, capacity) {
            // Keep the last one (the highest bound) and every other one.
            let last = anchors[anchors.count - 1]
            anchors = anchors.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            if anchors.last != last { anchors.append(last) }
        }
    }

    /// The highest anchored offset at or before `time` (0: none).
    func lowerBound(atTime time: Double) -> Int64 {
        guard time.isFinite else { return 0 }
        var low = 0, high = anchors.count
        while low < high {
            let mid = (low + high) / 2
            if anchors[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? 0 : anchors[low - 1].byte
    }

    /// The anchor giving `lowerBound(atTime: time)`: the last one at or
    /// before `time` (nil: none).
    func anchor(atOrBefore time: Double) -> Anchor? {
        guard time.isFinite else { return nil }
        var low = 0, high = anchors.count
        while low < high {
            let mid = (low + high) / 2
            if anchors[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : anchors[low - 1]
    }

    /// The earliest anchored time whose offset is at least `byte` (nil:
    /// none — no time is known to need only data at or above it). Binary
    /// search (bytes increase with times).
    func earliestTime(atOrAbove byte: Int64) -> Double? {
        var low = 0, high = anchors.count
        while low < high {
            let mid = (low + high) / 2
            if anchors[mid].byte >= byte { high = mid } else { low = mid + 1 }
        }
        return low < anchors.count ? anchors[low].time : nil
    }

    var isEmpty: Bool { anchors.isEmpty }
}

/// Feeds `MediaByteMap` from an HTTP player's 1 Hz samples (pure): only
/// steady playback gives an anchor — the playhead advanced at about 1× since
/// the previous sample, the server's read position did not move back nor
/// jump, and the last seek (any other playhead move) is at least
/// `settleSeconds` old, so the read position belongs to the request that
/// serves the playhead (PopcornTorrent switches its primary reader after
/// 2 s of silence).
struct HTTPSampleFilter: Equatable {
    var settleSeconds: Double = 6
    private var lastTime: Double?
    private var lastServed: Int64?
    private var lastClock: Double?
    private var steadySince: Double?

    init(settleSeconds: Double = 6) { self.settleSeconds = settleSeconds }

    /// One sample (`clock`: monotonic seconds; `time`: the playhead, s of
    /// media; `served`: the server's read position). Returns true when it is
    /// an anchor candidate. `bytesPerSecond`: the source rate, bounds a
    /// plausible read position move.
    mutating func accept(clock: Double, time: Double, served: Int64, isPlaying: Bool, bytesPerSecond: Double) -> Bool {
        defer { lastTime = time; lastServed = served; lastClock = clock }
        guard time.isFinite, time >= 0, served > 0, let lastTime, let lastServed, let lastClock else {
            steadySince = nil
            return false
        }
        let elapsed = clock - lastClock
        let advanced = time - lastTime
        let moved = served - lastServed
        let maxMove = Int64(max(32.0 * 1_048_576, 8 * max(0, bytesPerSecond) * max(1, elapsed)))
        let steady = isPlaying && elapsed > 0 && elapsed < 5
            && advanced >= 0.4 * elapsed && advanced <= 2.5 * elapsed + 0.5
            && moved >= 0 && moved <= maxMove
        if !steady {
            steadySince = nil
            return false
        }
        if steadySince == nil { steadySince = clock }
        return clock - (steadySince ?? clock) >= settleSeconds
    }
}

/// HTTP routes: is PopcornTorrent's server read position (`servedOffset`)
/// the playing player's? The release's byte rule (`httpConsumedBefore`),
/// the time → offset anchors and the rewind floor all take it to be, but
/// PopcornTorrent makes any request its read position when the streaming one
/// is closed (or silent for 2 s): tvOS AVFoundation reads a few MB in the
/// middle of an MP4 two seconds after the start, and that single sample
/// released ~560 MiB below it — the data AVPlayer was about to play (HTTP
/// 410, playback stopped for good: part-3 coverage runs td2–td4, 3 starts
/// of 4). A read position is trusted when:
///  - it is at or behind the last trusted one (releasing less is safe);
///  - it is ahead of it by at most `aheadMarginBytes` (32 MiB + 30 s of the
///    bitrate: what a player reads between two samples) plus half the
///    bitrate over the media played or skipped since (a seek moves the
///    playhead first; half: a variable bitrate);
///  - none is trusted yet: within twice the bitrate over the playhead and
///    the read-ahead, plus 4 player buffers (a start, a hand-off at a
///    position);
///  - or it is a live, steady read: the sample filter accepts it
///    (`HTTPSampleFilter`, 6 s of steady playback) and it moved forward in
///    the last `activeSeconds` — a request that stopped reading (the probe)
///    never is.
/// Pure.
struct HTTPServedTrust: Equatable {
    static let activeSeconds: Double = 3
    static let playerBufferBytes: Int64 = 32 << 20

    /// The last trusted read position (nil: none yet).
    private(set) var trusted: Int64?
    private var trustedTime: Double = 0
    private var lastServed: Int64 = 0
    private var lastAdvance: Double?

    init() {}

    /// How far ahead of the last trusted position a read position may be,
    /// on top of the media played since.
    static func aheadMarginBytes(bytesPerSecond: Double) -> Int64 {
        playerBufferBytes + Int64(30 * max(0, bytesPerSecond))
    }

    /// One sample (`clock`: monotonic seconds; `time`: the playhead, s of
    /// media; `served`: the server's read position; `steady`: the sample
    /// filter accepted it). Returns true when `served` is trusted (then the
    /// new `trusted`).
    mutating func note(clock: Double, time: Double, served: Int64, readAheadSeconds: Double,
                       bytesPerSecond: Double, steady: Bool) -> Bool {
        guard served > 0, time.isFinite else { return false }
        if served > lastServed { lastAdvance = clock }
        lastServed = served
        let rate = max(0, bytesPerSecond.isFinite ? bytesPerSecond : 0)
        let live = steady && (lastAdvance.map { clock - $0 <= Self.activeSeconds } ?? false)
        let ok: Bool
        if let previous = trusted {
            let allowed = Self.aheadMarginBytes(bytesPerSecond: rate) + Int64(0.5 * rate * max(0, time - trustedTime))
            ok = served <= previous || served - previous <= allowed || live
        } else {
            let allowed = 4 * Self.playerBufferBytes + Int64(2 * rate * (max(0, time) + max(0, readAheadSeconds)))
            ok = served <= allowed || live
        }
        if ok {
            trusted = served
            trustedTime = time
        }
        return ok
    }
}

/// The stretches of the film the user played in this stream (media
/// seconds): a rewind blocked inside one of them reached data that was
/// downloaded and then deleted ("no longer stored"), whatever else blocks it
/// — a gap a forward seek left above it makes the floor look "never
/// downloaded" (part-3 coverage runs td1, md2). Pure.
struct PlayedSpans: Equatable {
    struct Span: Equatable {
        var start: Double
        var end: Double
    }
    /// A playhead move forward of at most this between two samples continues
    /// the span (1 Hz samples; a late one).
    static let maxStepSeconds: Double = 5
    static let capacity = 256

    private(set) var spans: [Span] = []
    private var current: Span?

    init() {}

    /// One sample of the playhead (`isPlaying`: it plays now).
    mutating func note(time: Double, isPlaying: Bool) {
        guard time.isFinite, time >= 0, isPlaying else { close(); return }
        if var span = current, time >= span.end, time - span.end <= Self.maxStepSeconds {
            span.end = time
            current = span
            return
        }
        close()
        current = Span(start: time, end: time)
    }

    /// `time` lies in a played stretch (± `margin`).
    func contains(_ time: Double, margin: Double = 2) -> Bool {
        guard time.isFinite else { return false }
        return (spans + (current.map { [$0] } ?? [])).contains { time >= $0.start - margin && time <= $0.end + margin }
    }

    private mutating func close() {
        guard let span = current else { return }
        current = nil
        guard span.end > span.start else { return }
        spans.append(span)
        if spans.count > Self.capacity { spans.removeFirst(spans.count - Self.capacity) }
    }
}

/// Bounded storage, direct AVPlayer route (an MP4 read through
/// PopcornTorrent's server): AVPlayer waits at the same time for
/// `stallSeconds` while the data it needs next is on disk. macOS AVPlayer,
/// when a far seek's first data comes late, back-fills the gap from the end
/// of the `moov` to its target; that range reaches deleted data, the server
/// cuts the response, and AVPlayer's loader then stops requesting for good,
/// waiting with no error (part-3 coverage runs md2–md5, 4 of 4). Rebuilding
/// the item at the playhead clears it (md5). At most `maxRebuildsAtOnePosition`
/// rebuilds for one position. Pure.
struct BoundedDirectStallWatch {
    static let stallSeconds: TimeInterval = 8
    static let maxRebuildsAtOnePosition = 2
    /// Why: the rebuild's log line, the VLC hand-off reason should the
    /// rebuilt item never get ready (the same style as `StuckPlaybackWatch`).
    static let reason = "Lecture directe en attente avec les données sur le disque : élément reconstruit (stockage limité)"

    private var still: (time: Double, since: TimeInterval)?
    private var rebuilt: (time: Double, count: Int)?

    init() {}

    /// One 1 Hz sample. `isWaiting`: the item is ready and AVPlayer waits to
    /// play at its rate; `isEligible`: bounded mode, direct route, no
    /// recovery running, the data ahead of the read position on disk.
    /// Returns the time to rebuild the item at, once the playhead stood
    /// still that long.
    mutating func note(time: Double, clock: TimeInterval, isWaiting: Bool, isEligible: Bool) -> Double? {
        guard isWaiting, isEligible, time.isFinite, time >= 0 else { still = nil; return nil }
        guard let current = still, abs(current.time - time) < 0.05 else {
            still = (time, clock)
            return nil
        }
        guard clock - current.since >= Self.stallSeconds else { return nil }
        still = nil
        if let done = rebuilt, abs(done.time - time) < 1 {
            guard done.count < Self.maxRebuildsAtOnePosition else { return nil }
            rebuilt = (time, done.count + 1)
        } else {
            rebuilt = (time, 1)
        }
        return time
    }
}
