import Foundation
import AVFoundation
import PopcornKit
#if canImport(PopcornTorrent)
import PopcornTorrent
#endif

// The `[Start]` lines of a playback's start (PopcornKit's
// `PlaybackStartTrace`: sources, subtitles, metadata, buffer, remux prepare,
// first frame, each with its milliseconds). The trace is created by the play
// flow and travels with the stream's streamer, like `PlaybackStreamContext`:
// the loading screens, the remux and the players of the three platforms mark
// their phase on it without knowing one another, and it follows a native →
// VLC hand-off.

#if canImport(PopcornTorrent)
extension PTTorrentStreamer {

    private static var startTraceKey: UInt8 = 0

    /// The trace of this stream's start (nil: none — a stream started
    /// without one).
    var startTrace: PlaybackStartTrace? {
        get { objc_getAssociatedObject(self, &PTTorrentStreamer.startTraceKey) as? PlaybackStartTrace }
        set { objc_setAssociatedObject(self, &PTTorrentStreamer.startTraceKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// The torrent's metadata is in (`LoadingPhaseTracker`, at every status
    /// and once a second): the `metadata` phase, the first time.
    func noteStartMetadata(peers: Int) {
        startTrace?.reach(.metadata, detail: "\(max(0, peers)) peer(s)")
    }

    /// The stream is ready to play (PopcornTorrent's `readyToPlay`): the
    /// `buffer` phase — and the `[Measure]` lines of the torrent, of what the
    /// engine waited for and of the counters at that moment. Any thread.
    func noteStartBuffered(fileName: String) {
        startTrace?.reach(.buffer, detail: fileName)
        noteStartMeasureGeometry()
        // The head and the tail the engine waited for: whichever came since
        // the last sample is logged now, before `ready`.
        noteStartMeasureRequiredEnds(atReady: true)
        noteStartMeasure(.ready)
    }

    /// The player really plays: the `first frame` phase and its `[Measure]`
    /// line. Main thread (the players' first-frame marks).
    func noteStartFirstFrame(detail: String) {
        startTrace?.reach(.firstFrame, detail: detail)
        noteStartMeasure(.firstFrame, detail: detail)
    }
}

// MARK: - [Measure] lines

// The engine's side of the start (PopcornKit's `PlaybackStartMeasure`, study
// b2 « A1 »): the torrent's pieces, what PopcornTorrent waits for before
// `readyToPlay`, the first peer and piece, and the bytes, rate and peers at
// each step, so that a session on a real swarm gives the numbers. Logging
// only — read from PopcornTorrent's public API at the moments the app already
// reaches (no timer, nothing awaited, nothing reordered) — and in every
// build, not only DEBUG: the user's Apple TV runs a release build.
extension PTTorrentStreamer {

    private static var startMeasureKey: UInt8 = 0
    private static let startMeasureLock = NSLock()

    /// This stream's measure, made at first use. Any thread.
    var startMeasure: PlaybackStartMeasure {
        PTTorrentStreamer.startMeasureLock.lock()
        defer { PTTorrentStreamer.startMeasureLock.unlock() }
        if let measure = objc_getAssociatedObject(self, &PTTorrentStreamer.startMeasureKey) as? PlaybackStartMeasure {
            return measure
        }
        let measure = PlaybackStartMeasure()
        objc_setAssociatedObject(self, &PTTorrentStreamer.startMeasureKey, measure, .OBJC_ASSOCIATION_RETAIN)
        return measure
    }

    /// `selection` (the `selectFileToStream` block), also giving the file
    /// list and the file chosen to this stream's measure: the selected file's
    /// offset and the torrent's size (piece count) come from it. Same answer.
    func measuringSelection(_ selection: @escaping PTTorrentStreamerSelection) -> PTTorrentStreamerSelection {
        let measure = startMeasure
        return { names, sizes in
            let index = selection(names, sizes)
            measure.noteFiles(sizes: sizes.map { $0.int64Value }, selected: Int(index))
            return index
        }
    }

    /// The counters now. Cheap: atomic properties, one piece-state pass, one
    /// `stat` (the file's allocated bytes) — called a handful of times per
    /// stream.
    func startMeasureSample() -> PlaybackStartMeasure.Sample {
        let status = torrentStatus
        let configured = hasMetadata
        return PlaybackStartMeasure.Sample(fileBytes: totalDownloaded.longLongValue,
                                           bytesOnDisk: configured ? bytesOnDisk : nil,
                                           headOnDisk: configured ? firstMissingOffset(from: 0) : nil,
                                           downloadRate: Int(status.downloadSpeed),
                                           peers: Int(status.peers), seeds: Int(status.seeds),
                                           engineSeconds: timeSinceStart > 0 ? timeSinceStart : nil)
    }

    /// A stream of the engine, measured: not a finished offline download
    /// played from its file (`PTTorrentDownload.play`), which waits for no
    /// piece.
    private var isMeasuredStream: Bool { !(self is PTTorrentDownload) }

    /// Logs `step`'s `[Measure]` line, once per stream (a jump's only for
    /// the start's jump, `PlaybackStartMeasure.admits`; `segment`: its
    /// remux segment). Any thread.
    func noteStartMeasure(_ step: PlaybackStartMeasure.Step, detail: String? = nil, segment: Int? = nil) {
        guard isMeasuredStream else { return }
        let measure = startMeasure
        guard measure.isPending(step) else { return }
        measure.reach(step, sample: startMeasureSample(), sinceTrace: startTrace?.sinceStart(), detail: detail,
                      segment: segment)
    }

    /// The loading screens' status samples (0.5 s status, 1 s timer): the
    /// first connected peer and the first piece of the file on disk. Two
    /// comparisons once both are logged.
    func noteStartMeasureStatus() {
        guard isMeasuredStream else { return }
        let measure = startMeasure
        if measure.isPending(.firstPeer), torrentStatus.peers > 0 { noteStartMeasure(.firstPeer) }
        if measure.isPending(.firstPiece), totalDownloaded.longLongValue > 0 { noteStartMeasure(.firstPiece) }
        noteStartMeasureRequiredEnds()
    }

    /// `[Measure] head on disk` / `tail on disk`: the first sample at which
    /// the head, then the tail, that the engine waits for before
    /// `readyToPlay` (its rule, `PlaybackStartMeasure.Readiness`) is on disk
    /// in full — which of the two ended the start buffer. Nothing once both
    /// are logged; nothing before the metadata.
    private func noteStartMeasureRequiredEnds(atReady: Bool = false) {
        guard isMeasuredStream, hasMetadata else { return }
        let measure = startMeasure
        guard measure.isPending(.headOnDisk) || measure.isPending(.tailOnDisk) else { return }
        let statistics = storageStatistics
        guard let pieceLength = statistics["pieceLength"]?.int64Value, pieceLength > 0,
              let fileSize = statistics["fileSize"]?.int64Value, fileSize > 0,
              let rule = PlaybackStartMeasure.Readiness.engineRule(measure.geometry(pieceLength: pieceLength, fileSize: fileSize),
                                                                    bounded: statistics["bounded"]?.boolValue ?? isStorageBounded)
        else { return }
        let tailStart = fileSize - rule.tailBytes
        let due = PlaybackStartMeasure.requiredEnds(rule, fileSize: fileSize, headOnDisk: firstMissingOffset(from: 0),
                                                    tailOnDisk: rule.tailBytes > 0 && isRangeAvailable(tailStart, length: rule.tailBytes),
                                                    atReady: atReady)
        for (step, detail) in due where measure.isPending(step) { noteStartMeasure(step, detail: detail) }
    }

    /// The torrent's and the readiness requirement's `[Measure]` lines, once
    /// the engine's statistics are there (at `readyToPlay`).
    private func noteStartMeasureGeometry() {
        guard isMeasuredStream else { return }
        let statistics = storageStatistics
        guard let pieceLength = statistics["pieceLength"]?.int64Value, pieceLength > 0,
              let fileSize = statistics["fileSize"]?.int64Value, fileSize > 0 else {
            startMeasure.logGeometry(pieceLength: 0, fileSize: 0, bounded: isStorageBounded, tailPinStart: nil, headPinEnd: nil)
            return
        }
        startMeasure.logGeometry(pieceLength: pieceLength, fileSize: fileSize,
                                 bounded: statistics["bounded"]?.boolValue ?? isStorageBounded,
                                 tailPinStart: statistics["tailPinStart"]?.int64Value,
                                 headPinEnd: statistics["headPinEnd"]?.int64Value)
    }
}
#endif

/// Calls back once, on the main queue, when `player` first plays for real
/// (`timeControlStatus` turns `.playing`: AVPlayer is presenting the media,
/// not merely asked to): the `first frame` mark of the native players.
final class FirstFrameWatch {
    private var observation: NSKeyValueObservation?

    init(player: AVPlayer, onFirstFrame: @escaping () -> Void) {
        observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            DispatchQueue.main.async {
                guard let self = self, self.observation != nil else { return }
                self.invalidate()
                onFirstFrame()
            }
        }
    }

    func invalidate() {
        observation?.invalidate()
        observation = nil
    }

    deinit { observation?.invalidate() }
}
