import Foundation
import ObjectiveC
import PopcornKit
import PopcornTorrent

// The app side of PopcornTorrent's bounded storage for ONE stream: drives the
// torrent's window on every route the stream can end up on, splits the free
// space (`StorageBudget`) and tells the players how far back they can go.
// Contract for the players: SP/bounded2/engine/API.md.

/// One sample of an HTTP player (VLC, or AVPlayer on PopcornTorrent's URL),
/// read on the main queue about once a second.
struct BoundedPlayerSample {
    /// The playhead, seconds of media on the player's own clock.
    var time: Double
    /// Playing (not paused, not buffering a seek).
    var isPlaying: Bool
}

extension Notification.Name {
    /// Posted on the main queue, object = the `PTTorrentStreamer`, when its
    /// bounded-storage status changes in a way the UI shows: the stream turned
    /// out bounded, or the rewind depth moved by a minute or more
    /// (`BoundedStorageSession.status`).
    static let boundedStorageStatusDidChange = Notification.Name("PTBoundedStorageStatusDidChange")
}

final class BoundedStorageSession {

    /// Which reader drives the window.
    enum Route: String {
        /// Nothing attached yet (loading screen), or between two players.
        case none
        /// `RemuxPlayback` reads the file itself.
        case remux
        /// VLC or AVPlayer read it through PopcornTorrent's HTTP server.
        case http
    }

    /// What the UI can show. Thread-safe snapshot (`status`), refreshed every
    /// second while the stream is bounded.
    struct Status: Equatable {
        /// The stream runs in bounded mode (only a window of the film is on disk).
        var isBounded = false
        var route: Route = .none
        /// The rewind depth the current split gives (seconds of media):
        /// remux, the HLS segments kept behind the playhead; HTTP routes,
        /// the torrent data kept behind the player.
        var rewindDepthSeconds: Double = 0
        /// The same, in whole minutes for the UX ("~N min"); 0 when not bounded.
        var rewindDepthMinutes: Int = 0
        /// The earliest position a rewind can reach now, on the clock of the
        /// player of `route` (remux: AVPlayer's timeline; HTTP: that
        /// player's own time). nil: no limit (not bounded, or nothing known).
        var earliestRewindTime: Double?
        /// The playhead that limit was computed from.
        var playheadTime: Double?
    }

    // MARK: Set-up

    /// Sets a streamer up for bounded storage, BEFORE `startStreaming`:
    /// allowed (the app drives `readPosition` / `consumedBefore` on every
    /// route: remux, VLC and direct AVPlayer, hand-offs included), the
    /// 512 MiB reserve, the media's duration (bitrate) when known. Returns its
    /// session, which follows the stream until it is cancelled. Main queue.
    @discardableResult
    static func prepare(_ streamer: PTTorrentStreamer, durationSeconds: Double?) -> BoundedStorageSession {
        streamer.allowsBoundedStorage = true
        streamer.storageReserve = BoundedStorage.reserveBytes
        if let duration = durationSeconds, duration.isFinite, duration >= 60 {
            streamer.mediaDurationHint = duration
        }
        // Full mode keeps the whole file: only when the remux's HLS copy
        // still fits next to it (`BoundedStorage.fullModeAppWorkingSetSeconds`),
        // else the two fill the volume late in the film (-4).
        streamer.appWorkingSetSeconds = BoundedStorage.fullModeAppWorkingSetSeconds
        // What offline downloads in progress will still write is not free.
        let pending = pendingDownloadBytes()
        streamer.pendingExternalBytes = pending
        #if DEBUG
        if let directory = BoundedStorageDebug.downloadDirectory {
            streamer.downloadDirectoryOverride = directory
        }
        #endif
        let session = BoundedStorageSession(streamer: streamer, durationSeconds: durationSeconds)
        session.lock.withLock { session.lockedPendingDownloads = pending }
        objc_setAssociatedObject(streamer, &associationKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        session.startTimer()
        #if DEBUG
        BoundedStorageDebugHooks.noteStreamer(streamer)
        #endif
        return session
    }

    /// The media's duration in seconds (Movie.runtime, the show's episode
    /// runtime), nil when unknown.
    static func durationHint(for media: Media?) -> Double? {
        #if DEBUG
        if let duration = BoundedStorageDebugHooks.durationSeconds { return duration }
        #endif
        if let movie = media as? Movie, movie.runtime > 0 { return Double(movie.runtime) * 60 }
        if let episode = media as? Episode, let runtime = episode.show?.runtime, runtime > 0 { return Double(runtime) * 60 }
        return nil
    }

    /// The session of `streamer` (nil: not set up with `prepare`, e.g. a
    /// download). Any thread.
    static func session(for streamer: PTTorrentStreamer?) -> BoundedStorageSession? {
        guard let streamer = streamer else { return nil }
        return objc_getAssociatedObject(streamer, &associationKey) as? BoundedStorageSession
    }

    private static var associationKey: UInt8 = 0

    // MARK: Player API (any thread)

    /// The stream runs in bounded mode. Any thread.
    var isBounded: Bool { streamer?.storageMode == .bounded || lock.withLock { lockedStatus.isBounded } }

    var status: Status { lock.withLock { lockedStatus } }

    /// The earliest position a rewind from `playerTime` can reach without
    /// data that is gone, on the clock of the calling player: AVPlayer's
    /// timeline on the remux route (the start of the run of kept HLS
    /// segments holding `playerTime`), the player's own time on the HTTP
    /// routes (mapped conservatively from `lowestAvailableOffset` and the
    /// pieces on disk). nil = no limit (full mode, nothing deleted yet).
    /// Never later than `playerTime`. Any thread (the HTTP route asks the
    /// torrent a few `firstMissingOffset` questions).
    func earliestRewindTime(fromPlayerTime playerTime: Double) -> Double? {
        guard isBounded, playerTime.isFinite else { return nil }
        let remux = lock.withLock { lockedRemux }
        if let remux = remux, !remux.isStoppedForBounded {
            return remux.earliestNativeRewindSeconds(fromPlayerSeconds: playerTime).map { min($0, playerTime) } ?? playerTime
        }
        return httpEarliestRewind(playheadTime: playerTime)
    }

    /// `target` (same clock as `playerTime`) can be reached by a rewind
    /// (`earliestRewindTime`); always true outside bounded mode and for a
    /// forward move.
    func canSeek(to target: Double, fromPlayerTime playerTime: Double) -> Bool {
        guard target.isFinite, target < playerTime else { return true }
        guard let earliest = earliestRewindTime(fromPlayerTime: playerTime) else { return true }
        guard target >= earliest || isRewindTargetOnDisk(target) else {
            noteLimitedRewind(target: target)
            return false
        }
        return true
    }

    /// HTTP routes: a rewind to `target` (the player's clock) below
    /// `earliestRewindTime` still finds its data on disk — what the player
    /// read, or the torrent's window held, before a forward seek left a gap
    /// above it (`BoundedStorage.httpRewindTargetIsOnDisk`; verify-playback 1).
    /// Such a rewind is not limited. False on the remux route (its HLS
    /// segments are the rewind) and outside bounded mode. Any thread.
    func isRewindTargetOnDisk(_ target: Double) -> Bool {
        guard isBounded, target.isFinite, let streamer = streamer, streamer.storageMode == .bounded else { return false }
        if let remux = lock.withLock({ lockedRemux }), !remux.isStoppedForBounded { return false }
        let map = lock.withLock { lockedMap }
        let rate = BoundedStorage.sourceBytesPerSecond(fileSize: streamer.fileSize.longLongValue,
                                                       durationSeconds: streamer.mediaDurationHint)
        return BoundedStorage.httpRewindTargetIsOnDisk(target: target, map: map,
                                                       lowestAvailableOffset: streamer.lowestAvailableOffset,
                                                       bytesPerSecond: rate, marginSeconds: Self.keyframeMarginSeconds,
                                                       firstMissingOffset: { streamer.firstMissingOffset(from: $0) })
    }

    /// A rewind to `target` (the calling player's clock) is out of reach:
    /// what its message says (`isRewindFloorNeverDownloaded`). Called by
    /// `canSeek` and `BoundedStorageUX.limitedRewindTarget`. Any thread.
    func noteLimitedRewind(target: Double) {
        lock.withLock { lockedLastLimitedTarget = target }
    }

    /// Remux route: can a hand-off to VLC (or any HTTP player) resume at
    /// `playerSeconds` (AVPlayer's timeline) — is the torrent data from the
    /// cluster before that position still there or still downloadable?
    /// False when it was deleted (behind `lowestAvailableOffset`) or skipped
    /// and released (a gap the remux read past): VLC would get HTTP 410
    /// there. A position past the remux's reader is downloadable (a far seek
    /// forward: VLC's reads fetch it). True outside bounded mode and without
    /// a remux segment map. Any thread.
    func canResumeOverHTTP(atPlayerSeconds playerSeconds: Double) -> Bool {
        guard isBounded, playerSeconds.isFinite, let streamer = streamer else { return true }
        let remux = lock.withLock { lockedRemux }
        guard let snapshot = remux?.boundedSnapshot(), !snapshot.segmentSourceOffsets.isEmpty else {
            // HTTP routes (direct AVPlayer → VLC): the same clock. Back from
            // the HTTP player's playhead, only as far as its rewind reaches
            // (`earliestRewindTime`); ahead of it, downloadable.
            guard let playhead = lock.withLock({ lockedStatus.route == .http ? lockedStatus.playheadTime : nil }),
                  playerSeconds < playhead,
                  let earliest = httpEarliestRewind(playheadTime: playhead) else { return true }
            return playerSeconds >= earliest || isRewindTargetOnDisk(playerSeconds)
        }
        let segment = RemuxPlayback.segmentIndex(coveringPlayerSeconds: max(0, playerSeconds),
                                                 durations: snapshot.playerDurations,
                                                 targetDuration: snapshot.targetDuration)
        guard segment < snapshot.segmentSourceOffsets.count else { return true }   // past the remux: downloadable
        let offset = snapshot.segmentSourceOffsets[max(0, segment - 1)]
        if offset < streamer.lowestAvailableOffset { return false }
        if offset >= snapshot.readerOffset { return true }
        // Behind the reader: everything from there up to the reader must be on
        // disk and stay there (what the split kept for this hand-off).
        return streamer.contiguousAvailableOffset(before: snapshot.readerOffset) <= offset
    }

    /// HTTP routes: the rewind floor is a part of the file that was never
    /// downloaded (VLC started at a resume point, the gap a forward seek
    /// left), not deleted data — the first byte missing below the server's
    /// read position lies above everything consumed. False on the remux
    /// route (its floor is pruned HLS) and outside bounded mode. Any thread.
    var isRewindFloorNeverDownloaded: Bool {
        guard isBounded, let streamer = streamer else { return false }
        let (remux, target, played) = lock.withLock { (lockedRemux, lockedLastLimitedTarget, lockedPlayed) }
        if let remux = remux, !remux.isStoppedForBounded { return false }
        // The rewind went back into something the user played: its data was
        // downloaded, then deleted — even when a gap a forward seek left
        // above it is what the floor shows (part-3 coverage td1, md2).
        if let target = target, played.contains(target) { return false }
        let floor = streamer.contiguousAvailableOffset(before: max(1, streamer.servedOffset))
        return floor > 0 && floor > streamer.lowestAvailableOffset
    }

    // MARK: Consumers

    /// The remux route starts (`RemuxPlayback.start`). Any thread.
    func attachRemux(_ remux: RemuxPlayback) {
        lock.withLock { lockedRemux = remux }
        #if DEBUG
        DispatchQueue.main.async { BoundedStorageDebugHooks.playbackDidStart() }
        #endif
    }

    /// The remux stopped (`RemuxPlayback.stop`). Any thread.
    func detachRemux(_ remux: RemuxPlayback) {
        lock.withLock { if lockedRemux === remux { lockedRemux = nil } }
    }

    /// An HTTP player (VLC, or AVPlayer on PopcornTorrent's URL) plays the
    /// stream: `sample` gives its position, on the main queue about once a
    /// second (nil: nothing to report yet). `readAheadSeconds`: how far it
    /// reads ahead of its playhead at most (VLC: its caching; AVPlayer: its
    /// forward buffer) — a time-to-offset anchor is only taken that far past
    /// the playhead. Main queue.
    func attachHTTPPlayer(_ owner: AnyObject, readAheadSeconds: Double,
                          sample: @escaping () -> BoundedPlayerSample?) {
        let id = ObjectIdentifier(owner)
        lock.withLock {
            lockedHTTPPlayers.removeAll { $0.id == id }
            lockedHTTPPlayers.append(HTTPPlayer(id: id, readAheadSeconds: max(0, readAheadSeconds), sample: sample))
        }
        #if DEBUG
        DispatchQueue.main.async { BoundedStorageDebugHooks.playbackDidStart() }
        #endif
    }

    /// That player is done (closed, or handed over). Main queue.
    func detachHTTPPlayer(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        lock.withLock { lockedHTTPPlayers.removeAll { $0.id == id } }
    }

    // MARK: Budget split (any thread)

    /// UX (loading screen): the rewind depth in whole minutes — the current
    /// split's (`status.rewindDepthMinutes`) once a player runs, before that
    /// the remux route's split on fresh numbers (no HLS copy yet; the remux
    /// keeps less behind than the HTTP routes: the conservative figure).
    /// 0 when not bounded. Reads the free space; drives nothing. Any thread.
    func estimatedRewindMinutes() -> Int {
        guard isBounded else { return 0 }
        let minutes = status.rewindDepthMinutes
        if minutes > 0 { return minutes }
        return StorageBudget(input(route: .remux, hlsDeletableBytes: 0, outputBytesPerSecond: nil,
                                   readAheadSeconds: 0)).rewindMinutes
    }

    /// The free space this stream may count on: the volume's, minus what
    /// offline downloads in progress will still write. Any thread.
    func usableFreeBytes() -> Int64 {
        let (cached, pending) = lock.withLock { (lockedSavePath, lockedPendingDownloads) }
        return max(0, (Self.freeBytes(at: cached ?? streamer?.savePath) ?? 0) - pending)
    }

    /// The split for the remux route with these HLS numbers and the
    /// torrent's own (fresh free space, bytes on disk). `RemuxPlayback`'s
    /// disk budget in bounded mode.
    func remuxSplit(hlsDeletableBytes: Int64, outputBytesPerSecond: Double?) -> StorageBudget {
        StorageBudget(input(route: .remux, hlsDeletableBytes: hlsDeletableBytes, outputBytesPerSecond: outputBytesPerSecond,
                            readAheadSeconds: 0))
    }

    // MARK: - Internals

    private struct HTTPPlayer {
        let id: ObjectIdentifier
        let readAheadSeconds: Double
        let sample: () -> BoundedPlayerSample?
    }

    private weak var streamer: PTTorrentStreamer?
    private let durationSeconds: Double?
    private let queue = DispatchQueue(label: "bounded.storage", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// The mode was known once (main queue: `mainTick`'s copy of `everDetermined`).
    private var everDeterminedOnMain = false

    // Guarded by `lock`.
    private var lockedStatus = Status()
    private weak var lockedRemux: RemuxPlayback?
    private var lockedHTTPPlayers: [HTTPPlayer] = []
    private var lockedMap = MediaByteMap()
    /// The last HTTP playhead and its read-ahead (earliest rewind).
    private var lockedHTTPReadAhead: Double = 30
    /// Remux route: bytes between the cluster before the playhead and the
    /// reader at the last tick (`StorageBudget.Input.failoverKeepObservedBytes`).
    private var lockedFailoverObserved: Int64?
    /// The streamer's save path, read on main (`mainTick`); kept after the
    /// cancel clears it (its parent is on the same volume).
    private var lockedSavePath: String?
    /// What offline downloads in progress will still write
    /// (`pendingDownloadBytes`, read on main).
    private var lockedPendingDownloads: Int64 = 0

    /// HTTP routes: the server read position last trusted to be the player's
    /// (`HTTPServedTrust`); nil before any.
    private var lockedTrustedServed: Int64?
    /// What the user played in this stream (media seconds, the HTTP players'
    /// clock) and the last rewind target found out of reach: the message of a
    /// limited rewind (`isRewindFloorNeverDownloaded`).
    private var lockedPlayed = PlayedSpans()
    private var lockedLastLimitedTarget: Double?

    // `queue` only.
    private var filter = HTTPSampleFilter()
    private var servedTrust = HTTPServedTrust()
    private var seededSegments = 0
    private var lastLog: TimeInterval = 0
    private var lastUntrustedLog: TimeInterval = 0
    private var lastBudget: Int64 = 0
    private var everDetermined = false
    private var everBounded = false
    private var loggedClosed = false
    private var announcedMinutes: Int?

    private init(streamer: PTTorrentStreamer, durationSeconds: Double?) {
        self.streamer = streamer
        self.durationSeconds = durationSeconds
    }

    deinit {
        timer?.cancel()
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// 1 Hz on the main queue (the HTTP players' samples are read there),
    /// the work on `queue`.
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.mainTick() }
        self.timer = timer
        timer.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func mainTick() {
        // Main-queue reads for the other queues (`input`).
        let path = streamer?.savePath
        let pending = Self.pendingDownloadBytes()
        let hadPath: Bool = lock.withLock {
            let had = lockedSavePath != nil
            if let path = path { lockedSavePath = path }
            lockedPendingDownloads = pending
            return had
        }
        // Cancelled before its mode was known (a magnet refused at its
        // metadata, -5): the streamer clears its save path at cancel and its
        // mode stays undetermined — nothing will ever be driven, stop the
        // timer (verify-playback 2: it ran as long as the streamer lived).
        if path == nil, hadPath, let streamer = streamer, streamer.storageMode == .undetermined, !everDeterminedOnMain {
            stopTimer()
            return
        }
        if let streamer = streamer, streamer.pendingExternalBytes != pending { streamer.pendingExternalBytes = pending }
        let players = lock.withLock { lockedHTTPPlayers }
        // The latest attached player is the one playing (a hand-off attaches
        // the new one before the old one detaches).
        var sample: (BoundedPlayerSample, Double)?
        for player in players.reversed() {
            if let value = player.sample() { sample = (value, player.readAheadSeconds); break }
        }
        queue.async { [weak self] in self?.process(httpSample: sample) }
    }

    /// One second of bounded storage (queue).
    private func process(httpSample: (BoundedPlayerSample, Double)?) {
        guard let streamer = streamer else {
            if everBounded { logClosed() }
            DispatchQueue.main.async { [weak self] in self?.stopTimer() }
            return
        }
        switch streamer.storageMode {
        case .undetermined:
            // Before the metadata, or cancelled (the mode is reset then).
            if everDetermined {
                if everBounded { logClosed() }
                DispatchQueue.main.async { [weak self] in self?.stopTimer() }
            }
            return
        case .full:
            // The film fits: PopcornTorrent's legacy behaviour, nothing to drive.
            if !everDetermined { logMode(streamer, bounded: false) }
            everDetermined = true
            DispatchQueue.main.async { [weak self] in self?.everDeterminedOnMain = true }
            DispatchQueue.main.async { [weak self] in self?.stopTimer() }
            return
        case .bounded:
            if !everDetermined {
                logMode(streamer, bounded: true)
                DispatchQueue.main.async { [weak self] in self?.everDeterminedOnMain = true }
            }
            everDetermined = true
            everBounded = true
        @unknown default:
            return
        }

        let remux = lock.withLock { lockedRemux }
        let snapshot = remux.flatMap { $0.isStoppedForBounded ? nil : $0.boundedSnapshot() }
        let route: Route = snapshot != nil ? .remux : (httpSample != nil ? .http : (lock.withLock { lockedHTTPPlayers.isEmpty } ? .none : .http))

        var split: StorageBudget?
        var earliest: Double?
        var playhead: Double?
        switch route {
        case .remux:
            guard let snapshot = snapshot else { break }
            let budget = StorageBudget(input(route: .remux, hlsDeletableBytes: snapshot.deletableKeptBytes,
                                             outputBytesPerSecond: snapshot.outputBytesPerSecond, readAheadSeconds: 0))
            split = budget
            driveRemux(streamer, snapshot: snapshot, split: budget)
            seedMap(from: snapshot)
            playhead = snapshot.played ?? snapshot.wanted
            if let played = snapshot.played {
                lock.withLock { lockedPlayed.note(time: played + snapshot.timelineStartSeconds, isPlaying: true) }
            }
            if let position = playhead, let remux = remux {
                earliest = remux.earliestNativeRewindSeconds(fromPlayerSeconds: position).map { min($0, position) } ?? position
            }
        case .http:
            // The player's read-ahead in time, plus what its demuxer and
            // prefetch buffers may hold (32 MiB) at the file's bitrate.
            let rate = BoundedStorage.sourceBytesPerSecond(fileSize: streamer.fileSize.longLongValue,
                                                           durationSeconds: streamer.mediaDurationHint)
            let readAhead = httpSample.map { min(Self.maxReadAheadSeconds,
                                                 $0.1 + Double(Self.playerBufferBytes) / max(rate, 1)) }
                ?? lock.withLock { lockedHTTPReadAhead }
            let budget = StorageBudget(input(route: .http, hlsDeletableBytes: 0, outputBytesPerSecond: nil,
                                             readAheadSeconds: readAhead))
            split = budget
            if let sample = httpSample?.0 {
                lock.withLock { lockedPlayed.note(time: sample.time, isPlaying: sample.isPlaying) }
                driveHTTP(streamer, sample: sample, readAhead: readAhead, split: budget)
                playhead = sample.time
                earliest = httpEarliestRewind(playheadTime: sample.time)
            }
        case .none:
            break
        }
        if let budget = split, budget.torrentBudget > 0, budget.torrentBudget != lastBudget {
            streamer.storageBudget = budget.torrentBudget
            lastBudget = budget.torrentBudget
        }
        publish(route: route, split: split, earliest: earliest, playhead: playhead)
        log(streamer, route: route, split: split, snapshot: snapshot, playhead: playhead, earliest: earliest)
    }

    /// The split's input with fresh numbers.
    private func input(route: StorageBudget.Route, hlsDeletableBytes: Int64, outputBytesPerSecond: Double?,
                       readAheadSeconds: Double) -> StorageBudget.Input {
        let streamer = self.streamer
        let fileSize = streamer?.fileSize.longLongValue ?? 0
        let duration = streamer?.mediaDurationHint ?? 0
        let piece = (streamer?.storageStatistics["pieceLength"]?.int64Value) ?? 0
        // The save path is read on the main queue (`mainTick`): the streamer
        // clears it on main at cancel (a nonatomic property), and this runs on
        // the session's queue and the remux's pump queue.
        let (path, pending) = lock.withLock { (lockedSavePath, lockedPendingDownloads) }
        let free = max(0, (Self.freeBytes(at: path) ?? 0) - pending)
        let observedKeep = route == .remux ? lock.withLock { lockedFailoverObserved } : nil
        return StorageBudget.Input(route: route,
                                   freeBytes: free,
                                   torrentBytesOnDisk: streamer?.bytesOnDisk ?? 0,
                                   hlsDeletableBytes: hlsDeletableBytes,
                                   sourceBytesPerSecond: BoundedStorage.sourceBytesPerSecond(fileSize: fileSize,
                                                                                            durationSeconds: duration),
                                   outputBytesPerSecond: outputBytesPerSecond,
                                   pieceLength: piece,
                                   lookaheadSeconds: RemuxPlayback.lookaheadSeconds,
                                   playerReadAheadSeconds: readAheadSeconds,
                                   failoverKeepObservedBytes: observedKeep)
    }

    /// Remux route: release what the remux has read, minus what a hand-off
    /// to VLC at the playhead needs while the split keeps it
    /// (`BoundedStorage.remuxConsumedBefore`). The read position itself is
    /// reported by the remux's pump after every tick.
    private func driveRemux(_ streamer: PTTorrentStreamer, snapshot: RemuxPlayback.BoundedSnapshot, split: StorageBudget) {
        let reader = snapshot.readerOffset
        guard reader > 0 else { return }
        var playheadOffset: Int64?
        let positions = [snapshot.played, snapshot.wanted].compactMap { $0 }
        if let position = positions.min(), !snapshot.segmentSourceOffsets.isEmpty {
            let segment = RemuxPlayback.segmentIndex(coveringPlayerSeconds: max(0, position),
                                                     durations: snapshot.playerDurations,
                                                     targetDuration: snapshot.targetDuration)
            // The segment before the playhead's: VLC seeks to the keyframe at
            // or before its target.
            let index = min(max(0, segment - 1), snapshot.segmentSourceOffsets.count - 1)
            playheadOffset = snapshot.segmentSourceOffsets[index]
        }
        // Nothing reported yet (the item loads at 0): keep everything.
        guard let playheadOffset = playheadOffset else { return }
        // What the torrent can still hold between the playhead and the
        // reader: below `lowestAvailableOffset` the file is deleted for good
        // (`consumedBefore` only grows, nothing is downloaded again). After a
        // rewind behind it, counting those bytes would book torrent space it
        // can never use, taken from the HLS copy (its allowance, the rewind,
        // and the segments ahead of the new playhead) — the keep's target
        // follows this measure.
        let keptFrom = max(playheadOffset, streamer.lowestAvailableOffset)
        lock.withLock { lockedFailoverObserved = max(0, reader - keptFrom) }
        let consumed = BoundedStorage.remuxConsumedBefore(readerOffset: reader, playheadSourceOffset: playheadOffset,
                                                          keepBehindBytes: split.torrentKeepBehindBytes)
        if consumed > streamer.consumedBefore { streamer.consumedBefore = consumed }
    }

    /// Remux route: anchors for a later hand-off to VLC — segment K's media
    /// start (plus the timeline's own start and a margin) needs the file
    /// from its first cluster on.
    private func seedMap(from snapshot: RemuxPlayback.BoundedSnapshot) {
        let count = min(snapshot.segmentSourceOffsets.count, snapshot.mediaDurations.count)
        guard count > seededSegments else { return }
        var start = snapshot.mediaDurations.prefix(seededSegments).reduce(0, +)
        let margin = max(2, snapshot.targetDuration) + snapshot.timelineStartSeconds
        var anchors: [(Double, Int64)] = []
        for index in seededSegments..<count {
            anchors.append((start + margin, snapshot.segmentSourceOffsets[index]))
            start += snapshot.mediaDurations[index]
        }
        seededSegments = count
        lock.withLock { for (time, byte) in anchors { lockedMap.add(time: time, byte: byte) } }
    }

    /// HTTP routes: an anchor per steady second (the server's read position
    /// is past every byte the playhead plus the read-ahead needs), then
    /// release the file below what a rewind of the split's depth needs.
    /// `readPosition` is the HTTP server's.
    private func driveHTTP(_ streamer: PTTorrentStreamer, sample: BoundedPlayerSample, readAhead: Double,
                           split: StorageBudget) {
        let served = streamer.servedOffset
        let rate = BoundedStorage.sourceBytesPerSecond(fileSize: streamer.fileSize.longLongValue,
                                                       durationSeconds: streamer.mediaDurationHint)
        let clock = Self.uptime
        let accepted = filter.accept(clock: clock, time: sample.time, served: served,
                                     isPlaying: sample.isPlaying, bytesPerSecond: rate)
        // The read position is only used once it is trusted to be the
        // player's (`HTTPServedTrust`: a far request that is not playback —
        // tvOS AVFoundation's probe in the middle of an MP4 — must neither
        // release the playhead's data nor give an anchor).
        let isTrusted = servedTrust.note(clock: clock, time: sample.time, served: served, readAheadSeconds: readAhead,
                                         bytesPerSecond: rate, steady: accepted)
        if !isTrusted, served > 0, let trusted = servedTrust.trusted, served > trusted {
            logUntrustedServed(served: served, trusted: trusted, playhead: sample.time)
        }
        let trusted = servedTrust.trusted ?? 0
        let byTime: Int64 = lock.withLock {
            lockedHTTPReadAhead = readAhead
            lockedTrustedServed = servedTrust.trusted
            if accepted && isTrusted { lockedMap.add(time: sample.time + readAhead, byte: served) }
            return lockedMap.lowerBound(atTime: sample.time - split.rewindSeconds)
        }
        // Never more behind the server's read position than the split keeps
        // there (bytes): the time rule follows the average bitrate, and a
        // denser stretch (VBR), a VLC seek that reads through the gap without
        // steady samples, or a wrong runtime would otherwise keep more than
        // the split gave and eat into the reserve and the window ahead.
        let byBytes = trusted > 0 ? trusted - split.torrentKeepBehindBytes : 0
        let consumed = BoundedStorage.httpConsumedBefore(byTime: byTime, byBytes: byBytes,
                                                         served: trusted > 0 ? trusted : served)
        if consumed > streamer.consumedBefore { streamer.consumedBefore = consumed }
    }

    /// One line (at most every 5 s) while the server's read position is
    /// ahead of what playback explains (`HTTPServedTrust`). Session queue.
    private func logUntrustedServed(served: Int64, trusted: Int64, playhead: Double) {
        let now = Self.uptime
        guard now - lastUntrustedLog >= 5 else { return }
        lastUntrustedLog = now
        print(String(format: "[Bounded] read position %.1f MiB not taken as the player's (playhead %.1f s, last trusted %.1f MiB): nothing released for it",
                     Double(served) / 1_048_576, playhead, Double(trusted) / 1_048_576))
    }

    /// Direct AVPlayer route: the data from the server's read position on
    /// is on disk (at least `bytes`, or to the end of the file) — AVPlayer
    /// waiting there is not waiting for the download
    /// (`BoundedDirectStallWatch`). Any thread.
    func hasDataAheadOfReader(bytes: Int64 = 16 << 20) -> Bool {
        guard isBounded, let streamer = streamer else { return false }
        let reader = streamer.servedOffset
        let size = streamer.fileSize.longLongValue
        guard reader > 0, size > 0 else { return false }
        return streamer.firstMissingOffset(from: reader) >= min(size, reader + bytes)
    }

    /// HTTP routes: the earliest time whose bytes are all on disk, and stay
    /// there, up to the server's read position (any thread): the earliest
    /// anchor at or above PopcornTorrent's rewind floor
    /// (`contiguousAvailableOffset(before:)`: deleted data and gaps left by a
    /// forward seek stop it). Margin: one keyframe interval (10 s) past the
    /// anchor.
    private func httpEarliestRewind(playheadTime: Double) -> Double? {
        guard let streamer = streamer, streamer.storageMode == .bounded else { return nil }
        let floor = streamer.contiguousAvailableOffset(before: max(1, streamer.servedOffset))
        // Whole from the file's start up to the reader (nothing released): no limit.
        if floor == 0 { return nil }
        let map = lock.withLock { lockedMap }
        guard let time = map.earliestTime(atOrAbove: floor) else { return playheadTime }
        return min(playheadTime, time + Self.keyframeMarginSeconds)
    }

    static let keyframeMarginSeconds: Double = 10
    /// What an HTTP player's demuxer and prefetch buffers may hold beyond its
    /// own read-ahead (`attachHTTPPlayer`), and the read-ahead's cap.
    static let playerBufferBytes: Int64 = 32 << 20
    static let maxReadAheadSeconds: Double = 240

    private func publish(route: Route, split: StorageBudget?, earliest: Double?, playhead: Double?) {
        let (changed, minutes): (Bool, Int) = lock.withLock {
            var status = lockedStatus
            status.isBounded = true
            status.route = route
            if let split = split {
                status.rewindDepthSeconds = split.rewindSeconds
                status.rewindDepthMinutes = split.rewindMinutes
            }
            status.earliestRewindTime = earliest
            status.playheadTime = playhead
            let wasBounded = lockedStatus.isBounded
            lockedStatus = status
            return (!wasBounded, status.rewindDepthMinutes)
        }
        guard changed || announcedMinutes != minutes else { return }
        announcedMinutes = minutes
        let streamer = self.streamer
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .boundedStorageStatusDidChange, object: streamer)
        }
    }

    /// One line when the mode is known (device session: which mode, on what).
    private func logMode(_ streamer: PTTorrentStreamer, bounded: Bool) {
        let path = lock.withLock { lockedSavePath }
        func mib(_ value: Int64?) -> String { value.map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "-" }
        print("[Bounded] mode=\(bounded ? "bounded" : "full") fileMiB=\(mib(streamer.fileSize.longLongValue)) "
              + "freeMiB=\(mib(Self.freeBytes(at: path))) durationHint=\(Int(streamer.mediaDurationHint)) s")
    }

    /// The bounded stream was cancelled: one line with the free space once the
    /// deletions had time to land (5 s; the torrent's file and the remux's
    /// HLS copy), to compare with the free space at its start (report_4 D,
    /// "space fully recovered"). Session queue.
    private func logClosed() {
        guard !loggedClosed else { return }
        loggedClosed = true
        let path = lock.withLock { lockedSavePath }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            let free = Self.freeBytes(at: path).map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "-"
            print("[Bounded] stream closed: freeMiB=\(free) (5 s after the cancel)")
        }
    }

    /// The "[Bounded]" line, every 10 s (Xcode console; report_4 D).
    private func log(_ streamer: PTTorrentStreamer, route: Route, split: StorageBudget?,
                     snapshot: RemuxPlayback.BoundedSnapshot?, playhead: Double?, earliest: Double?) {
        let now = Self.uptime
        guard now - lastLog >= 10 else { return }
        lastLog = now
        let stats = streamer.storageStatistics
        func mib(_ value: Int64?) -> String { value.map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "-" }
        func stat(_ key: String) -> Int64? { stats[key]?.int64Value }
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
        let (path, pending) = lock.withLock { (lockedSavePath, lockedPendingDownloads) }
        let free = Self.freeBytes(at: path)
        let hls = snapshot.map { $0.deletableKeptBytes }
        let fields: [String] = [
            "route=\(route.rawValue)",
            "freeMiB=\(mib(free))",
            "torrentOnDiskMiB=\(mib(streamer.bytesOnDisk))",
            "hlsKeptMiB=\(mib(hls))",
            "aheadMiB=\(mib(stat("aheadBytes")))",
            "aheadBudgetMiB=\(mib(stat("aheadBudget")))",
            "behindMiB=\(mib(stat("behindBytes")))",
            "pace=\(stat("paceState").map(String.init) ?? "-")",
            "limitKiBs=\(stat("downloadLimit").map { String($0 / 1024) } ?? "-")",
            "readerMiB=\(mib(streamer.readPosition))",
            "remuxReaderMiB=\(mib(snapshot?.readerOffset))",
            "servedMiB=\(mib(streamer.servedOffset))",
            // The read position last taken as the player's (`HTTPServedTrust`).
            "trustedMiB=\(mib(lock.withLock { lockedTrustedServed }))",
            "consumedMiB=\(mib(streamer.consumedBefore))",
            "lowestMiB=\(mib(streamer.lowestAvailableOffset))",
            "playhead=\(seconds(playhead))",
            "earliestRewind=\(seconds(earliest))",
            "rewindMin=\(split?.rewindMinutes ?? 0)",
            "torrentBudgetMiB=\(mib(split?.torrentBudget))",
            "hlsAllowedMiB=\(mib(split?.hlsAllowedBytes))",
            "keepBehindMiB=\(mib(split?.torrentKeepBehindBytes))",
            "freed=\(stat("freedPieces").map(String.init) ?? "-")",
            "diskFull=\(stat("diskFullEvents").map(String.init) ?? "-")",
            "dropped=\(stat("droppedPieces").map(String.init) ?? "-")",
            "punchedMiB=\(mib(stat("punchedBytes")))",
            "punchErrors=\(stat("punchErrors").map(String.init) ?? "-")",
            "reclaimedMiB=\(mib(stat("reclaimedBytes")))",
            "fileErrors=\(stat("fileErrors").map(String.init) ?? "-")",
            "pendingDownloadsMiB=\(mib(pending))",
            // The file was created at its final size before any write (the
            // allocation-runaway fix), and how long the volume has been too
            // full to download (a start fails with -5 after 30 s).
            "presized=\(stat("presized").map(String.init) ?? "-")",
            // Pieces PopcornTorrent found held as written but never verified
            // and fetched again (its backstop of verify-storage F1): expected 0.
            "stuckRestored=\(stat("stuckPiecesRestored").map(String.init) ?? "-")",
            "starvedS=\(seconds(stats["diskStarvedSeconds"]?.doubleValue))",
        ]
        print("[Bounded] " + fields.joined(separator: " "))
    }

    /// Free space of the volume holding `path` (the torrent's directory),
    /// read afresh like PopcornTorrent does (`NSURLVolumeAvailableCapacityKey`
    /// on a new URL: a reused one caches its values).
    /// What the offline downloads in progress will still write to the
    /// volume: Σ (file size − bytes on disk) of those downloading (paused or
    /// finished ones write nothing). Their files are sparse, so the free
    /// space does not show it yet. A download with no peer and no speed for
    /// `stalledDownloadSeconds` (no seed: it writes nothing) is not counted —
    /// it refused bounded streams with -5 for space it would never take
    /// (verify-storage F5); when it moves again the next tick counts it, and
    /// the budget and PopcornTorrent's free space follow. Main queue (the
    /// download manager's list). macOS: 0, the Mac app has no offline
    /// downloads, and asking the manager creates ~/Documents/Downloads
    /// (verify-regressions 1).
    static func pendingDownloadBytes() -> Int64 {
        #if os(macOS)
        return 0
        #else
        let now = uptime
        var pending: Int64 = 0
        var seen: [ObjectIdentifier: TimeInterval] = [:]
        for download in PTTorrentDownloadManager.shared().activeDownloads where download.downloadStatus == .downloading {
            let size = download.fileSize.longLongValue
            guard size > 0 else { continue }
            let status = download.torrentStatus
            let id = ObjectIdentifier(download)
            let moving = status.downloadSpeed > 0 || status.seeds > 0 || status.peers > 0
            guard let lastMoving = moving ? now : downloadLastMoving[id] else { continue }
            seen[id] = lastMoving
            guard now - lastMoving < stalledDownloadSeconds else { continue }
            pending += max(0, size - download.bytesOnDisk)
        }
        downloadLastMoving = seen
        return pending
        #endif
    }

    /// `pendingDownloadBytes`: when each download in progress last had a
    /// peer or a speed (uptime). Main queue.
    private static var downloadLastMoving: [ObjectIdentifier: TimeInterval] = [:]
    static let stalledDownloadSeconds: TimeInterval = 60

    static func freeBytes(at path: String?) -> Int64? {
        let base = path ?? NSTemporaryDirectory()
        for candidate in [base, (base as NSString).deletingLastPathComponent] {
            var url = URL(fileURLWithPath: candidate)
            url.removeAllCachedResourceValues()
            if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
               let capacity = values.volumeAvailableCapacity {
                return Int64(capacity)
            }
        }
        return nil
    }
}

extension PTTorrentStreamer {
    /// Every byte of the streamed file is on disk: bounded mode, PopcornTorrent's
    /// `isFileComplete` (fresh; never once a piece was deleted — there
    /// `totalProgress` is the share downloaded once); full mode,
    /// `totalProgress` reaching 1, exactly as before.
    var isWholeFileOnDisk: Bool {
        storageMode == .bounded ? isFileComplete : StarvationPolicy.isComplete(progress: torrentStatus.totalProgress)
    }
}

// MARK: - Stream errors

/// What a stream failure means for the start-up flows.
enum StreamFailure {
    /// The file does not fit (bounded storage not allowed, or the disk filled
    /// up in full mode): PopcornTorrent -4.
    case notEnoughSpace
    /// Even bounded storage can't run: the free space is below its minimum
    /// working set. `bytesToFree`: what to free (computed: the error carries
    /// a sentence only). PopcornTorrent -5.
    case notEnoughSpaceForBoundedStorage(bytesToFree: Int64)
    /// Another file error (I/O, permissions). PopcornTorrent -6.
    case fileError
    case other

    init(_ error: Error, streamer: PTTorrentStreamer?) {
        let nsError = error as NSError
        guard nsError.domain == PTTorrentStreamerError.errorDomain else { self = .other; return }
        switch nsError.code {
        case PTTorrentStreamerError.Code.notEnoughSpace.rawValue:
            self = .notEnoughSpace
        case PTTorrentStreamerError.Code.notEnoughSpaceForBoundedStorage.rawValue:
            let fileSize = streamer?.fileSize.longLongValue ?? 0
            let duration = streamer?.mediaDurationHint ?? 0
            let free = BoundedStorageSession.session(for: streamer)?.usableFreeBytes()
                ?? BoundedStorageSession.freeBytes(at: streamer?.savePath) ?? 0
            let held = streamer?.bytesOnDisk ?? 0
            // The torrent's real piece length (known from the metadata on):
            // the pins and the minimum ahead are whole pieces of it, not of
            // the 16 MiB assumed when it is unknown (100 MB too much asked
            // with 4 MiB pieces: part-3 coverage run mp2b).
            let piece = streamer?.storageStatistics["pieceLength"]?.int64Value ?? 0
            self = .notEnoughSpaceForBoundedStorage(bytesToFree: fileSize > 0
                ? BoundedStorage.bytesToFree(fileSize: fileSize, durationSeconds: duration, freeBytes: free, heldBytes: held,
                                             pieceLength: piece)
                : 0)
        case PTTorrentStreamerError.Code.file.rawValue:
            self = .fileError
        default:
            self = .other
        }
    }

    /// A disk-space failure (the tvOS flow frees its caches and retries, then
    /// offers a lower quality).
    var isDiskSpace: Bool {
        switch self {
        case .notEnoughSpace, .notEnoughSpaceForBoundedStorage: return true
        case .fileError, .other: return false
        }
    }

    /// The message to show, nil = the error's own description. The strings
    /// are the UX agent's (keys listed in API.md); the English values are
    /// fallbacks until every table has them.
    func message(underlying error: Error) -> String? {
        switch self {
        case .notEnoughSpaceForBoundedStorage(let bytes):
            guard bytes > 0 else {
                return NSLocalizedString("BoundedStorage.NotEnoughSpace.Generic",
                                         value: "Not enough free space to stream this video, even with limited storage. Free some space and try again.",
                                         comment: "Stream refused even in bounded storage; the amount is unknown")
            }
            let amount = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return String(format: NSLocalizedString("BoundedStorage.NotEnoughSpace.Message",
                                                    value: "Not enough free space to stream this video, even with limited storage. Free at least %@ and try again.",
                                                    comment: "Stream refused even in bounded storage; %@ = space to free, e.g. 1.2 GB"),
                          amount)
        case .fileError:
            return String(format: NSLocalizedString("BoundedStorage.FileError.Message",
                                                    value: "The video could not be written to storage (%@).",
                                                    comment: "File error while streaming; %@ = system message"),
                          error.localizedDescription)
        case .notEnoughSpace, .other:
            return nil
        }
    }
}

#if DEBUG
/// DEBUG-only knob of bounded storage, set from a launch argument by the
/// platforms' debug hooks (`-PTDebugDownloadDir`).
enum BoundedStorageDebug {
    /// The torrent's directory instead of PopcornTorrent's default (the
    /// remux output goes there too: one volume for the split).
    static var downloadDirectory: String?
}
#endif
