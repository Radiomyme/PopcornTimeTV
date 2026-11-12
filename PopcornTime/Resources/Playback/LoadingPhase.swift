import Foundation
#if canImport(PopcornTorrent)
import PopcornTorrent
#endif

// What a loading screen says while a torrent prepares, the same on every
// platform: tvOS `PreloadTorrentViewController`, iOS `MediaDetailView`'s
// streaming overlay, macOS `MacPlayerView`'s loading view.
//
// Before, the Apple TV showed a bare spinner until the stream's first status,
// which PopcornTorrent only sent once the torrent's metadata was in: a magnet
// resolving its metadata, or a swarm that never answers, looked frozen, with
// nothing to tell the two apart and no way out but Menu. PopcornTorrent now
// reports the status from the moment the torrent is added (peers, download
// rate, buffering 0) and says when the metadata is in (`hasMetadata`). With an
// older PopcornTorrent (no status before the metadata) the tracker falls back
// to the time elapsed.
//
// Pure logic and strings (Foundation only); the PopcornTorrent adapter at the
// end reads a streamer. Every key is in the 7 Localizable.strings tables.

/// Why a source looks dead. The loading screen then says so and offers
/// "Choose another source" / "Keep waiting".
enum LoadingStall: Equatable {
    /// No peer connected for `LoadingPhaseTracker.noPeerSeconds` (45 s).
    case noPeers
    /// The torrent's metadata (its file list) still not in
    /// `LoadingPhaseTracker.noDetailsSeconds` (90 s) after the start.
    case noDetails
    /// Metadata in, but the buffering has not moved for
    /// `LoadingPhaseTracker.noDataSeconds` (120 s) and nothing downloads.
    case noData

    /// The message that replaces the phase line.
    var message: String {
        switch self {
        case .noPeers:
            return NSLocalizedString("LoadingPhase.NotResponding.NoPeers",
                                     value: "This source isn't responding (0 peers). Try another source.",
                                     comment: "Loading screen: no peer connected for 45 s; the user can choose another source or keep waiting")
        case .noDetails:
            return NSLocalizedString("LoadingPhase.NotResponding.NoDetails",
                                     value: "This source isn't sending the torrent's details. Try another source.",
                                     comment: "Loading screen: the torrent's metadata (file list) did not arrive in 90 s")
        case .noData:
            return NSLocalizedString("LoadingPhase.NotResponding.NoData",
                                     value: "This source isn't sending any data. Try another source.",
                                     comment: "Loading screen: no buffering progress and no download for 2 min")
        }
    }
}

/// Where the stream's preparation is.
enum LoadingPhase: Equatable {
    /// Nothing known yet: an older PopcornTorrent reports nothing before the
    /// metadata. Line: "Getting the torrent's details…".
    case starting
    /// No peer connected (before or after the metadata, nothing buffered yet).
    case lookingForPeers
    /// Peers connected, the metadata not in yet.
    case gettingDetails(connected: Int)
    /// Buffering until playback can start: progress 0…1 and the estimated
    /// time left (nil while unknown). Line: "42% · Time remaining ~1 min 5 s",
    /// as the Apple TV showed before.
    case buffering(progress: Float, eta: TimeInterval?)
    /// The source is not answering: show `line` (the stall's message) and
    /// offer another source.
    case notResponding(LoadingStall)

    var isBuffering: Bool {
        if case .buffering = self { return true }
        return false
    }

    /// The stall when the source is not answering.
    var stall: LoadingStall? {
        if case .notResponding(let stall) = self { return stall }
        return nil
    }

    var isNotResponding: Bool { stall != nil }

    /// Still waiting for the stream to start downloading (no buffering yet):
    /// the tracker's line then adds the time elapsed.
    var isWaiting: Bool {
        switch self {
        case .starting, .lookingForPeers, .gettingDetails: return true
        case .buffering, .notResponding: return false
        }
    }

    /// The user-facing line (without the time elapsed: see `LoadingPhaseTracker.line`).
    var line: String {
        switch self {
        case .starting:
            return LoadingPhase.gettingDetailsText
        case .lookingForPeers:
            return NSLocalizedString("LoadingPhase.LookingForPeers", value: "Looking for peers…",
                                     comment: "Loading screen: no peer connected yet")
        case .gettingDetails(let connected):
            guard connected > 0 else { return LoadingPhase.gettingDetailsText }
            return String(format: NSLocalizedString("LoadingPhase.GettingDetails.Connected",
                                                    value: "Getting the torrent's details… (%d connected)",
                                                    comment: "Loading screen: peers connected, the torrent's metadata (file list) is being received; %d = connected peers"),
                          connected)
        case .buffering(let progress, let eta):
            let percent = String(format: "%.0f%%", max(0, min(1, progress)) * 100)
            guard let eta = eta else { return percent }
            return percent + " · " + NSLocalizedString("Time remaining", comment: "") + " ~" + LoadingPhase.formatETA(eta)
        case .notResponding(let stall):
            return stall.message
        }
    }

    private static var gettingDetailsText: String {
        NSLocalizedString("LoadingPhase.GettingDetails", value: "Getting the torrent's details…",
                          comment: "Loading screen: the torrent's metadata (file list) is not in yet")
    }

    /// "1 min, 5 sec" / "42 sec" in the user's language ("1 min et 5 s").
    static func formatETA(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = s >= 60 ? [.minute, .second] : [.second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(s)) ?? (s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s")
    }

    /// "5 KB/s": a download rate (bytes/s), the user's units ("5 Ko/s").
    static func formatRate(_ bytesPerSecond: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .binary) + "/s"
    }

    /// "0:42", "12:05": the time spent waiting.
    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Actions (the not-responding state)

    static var chooseAnotherSourceTitle: String {
        NSLocalizedString("LoadingPhase.ChooseAnotherSource", value: "Choose another source",
                          comment: "Loading screen button when the source is not responding: back to the list of sources (quality picker)")
    }

    static var keepWaitingTitle: String {
        NSLocalizedString("LoadingPhase.KeepWaiting", value: "Keep waiting",
                          comment: "Loading screen button when the source is not responding: hide the message and wait again")
    }
}

/// One look at the stream.
struct LoadingSample: Equatable {
    /// Whether the torrent's metadata is in. nil: not known — an older
    /// PopcornTorrent before its first status (nothing else is known then).
    var hasMetadata: Bool?
    var bufferingProgress: Float = 0
    /// Bytes per second (libtorrent's download rate, protocol included).
    var downloadSpeed: Int = 0
    var seeds: Int = 0
    /// Connected peers (seeds included).
    var peers: Int = 0

    static let unknown = LoadingSample(hasMetadata: nil)
}

/// Follows one stream's preparation over time and decides the phase. Feed it
/// every status (the progress block) and once a second from a timer (the
/// stall rules need the clock even when no status comes). Main queue.
///
/// Stall rules (a stall ends by itself once its cause is gone, or when the
/// user chooses "Keep waiting", which re-arms every rule from then):
/// - no peer connected for 45 s (needs a status: not with an older
///   PopcornTorrent before the metadata);
/// - no metadata 90 s after the start;
/// - metadata in, no buffering progress for 120 s, and the download rate
///   below 1 KiB/s.
final class LoadingPhaseTracker {
    static let noPeerSeconds: TimeInterval = 45
    static let noDetailsSeconds: TimeInterval = 90
    static let noDataSeconds: TimeInterval = 120
    /// Below this download rate (bytes/s) nothing is coming (protocol chatter only).
    static let idleDownloadRate = 1024
    /// The waiting lines show the time elapsed from then on.
    static let elapsedShownAfter: TimeInterval = 5
    /// A source buffering for this long while still minutes from playing
    /// (`slowETA`) is slow: the screens offer another one (`isSlow`).
    static let slowAfter: TimeInterval = 30
    static let slowETA: TimeInterval = 180

    /// Monotonic clock (system uptime), the tracker's default time source.
    static func clock() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private(set) var phase: LoadingPhase = .starting
    /// When the stream started (the tracker's creation, unless given).
    let startedAt: TimeInterval
    private(set) var lastUpdate: TimeInterval
    /// A progress callback has come. An older PopcornTorrent calls it only
    /// once the metadata is in.
    var statusArrived = false

    private var lastSample = LoadingSample.unknown
    /// The stall rules count from here at the earliest ("Keep waiting").
    private var armedAt: TimeInterval
    private var lastPeerAt: TimeInterval?
    private var metadataAt: TimeInterval?
    private var bestProgress: Float = 0
    private var progressAt: TimeInterval?
    private var stall: LoadingStall?
    // ETA: smoothed rate of the buffering progress (fraction per second).
    private var etaSample: (progress: Float, time: TimeInterval)?
    private var rateEMA: Double = 0

    init(startedAt: TimeInterval = LoadingPhaseTracker.clock()) {
        self.startedAt = startedAt
        lastUpdate = startedAt
        armedAt = startedAt
    }

    /// Seconds since the start, at the last update.
    var elapsed: TimeInterval { max(0, lastUpdate - startedAt) }

    /// The phase's line; the details phase adds the download rate when
    /// something comes (the metadata exchange: "… (1 connected) · 5 KB/s"),
    /// and the waiting phases the time elapsed after 5 s ("Looking for
    /// peers… · 0:42").
    var line: String {
        var base = phase.line
        if case .gettingDetails(let connected) = phase, connected > 0,
           lastSample.downloadSpeed >= LoadingPhaseTracker.idleDownloadRate {
            base += " · " + LoadingPhase.formatRate(lastSample.downloadSpeed)
        }
        guard phase.isWaiting, elapsed >= LoadingPhaseTracker.elapsedShownAfter else { return base }
        return base + " · " + LoadingPhase.formatElapsed(elapsed)
    }

    /// The source answers but too slowly: buffering for `slowAfter` (30 s)
    /// and still `slowETA` (3 min) or more from playing (or no estimate
    /// yet). Not a stall (no message): the screens show « Choose another
    /// source » beside the progress when there is another one.
    var isSlow: Bool {
        guard case .buffering(let progress, let eta) = phase, let since = metadataAt,
              lastUpdate - since >= LoadingPhaseTracker.slowAfter, progress < 1 else { return false }
        return eta.map { $0 >= LoadingPhaseTracker.slowETA } ?? true
    }

    @discardableResult
    func update(_ sample: LoadingSample, now: TimeInterval = LoadingPhaseTracker.clock()) -> LoadingPhase {
        lastUpdate = max(lastUpdate, now)
        lastSample = sample
        let known = sample.hasMetadata != nil
        let hasMetadata = sample.hasMetadata == true
        let peers = known ? max(0, sample.peers) : 0
        let progress = known ? max(0, min(1, sample.bufferingProgress)) : 0
        let rate = known ? max(0, sample.downloadSpeed) : 0

        if peers > 0 { lastPeerAt = now }
        if hasMetadata && metadataAt == nil {
            metadataAt = now
            progressAt = now
        }
        var progressed = false
        if hasMetadata && progress > bestProgress + 0.0001 {
            bestProgress = progress
            progressAt = now
            progressed = true
        }
        if hasMetadata { updateETA(progress, now: now) }

        // A stall ends once its cause is gone.
        switch stall {
        case .noPeers?: if peers > 0 { stall = nil }
        case .noDetails?: if hasMetadata { stall = nil }
        case .noData?: if progressed { stall = nil }
        case nil: break
        }
        if stall == nil {
            stall = detectStall(known: known, hasMetadata: hasMetadata, peers: peers, rate: rate, now: now)
        }

        if let stall = stall {
            phase = .notResponding(stall)
        } else if !known {
            phase = .starting
        } else if !hasMetadata {
            phase = peers > 0 ? .gettingDetails(connected: peers) : .lookingForPeers
        } else if progress > 0 || peers > 0 || rate >= LoadingPhaseTracker.idleDownloadRate {
            phase = .buffering(progress: progress, eta: eta(progress))
        } else {
            phase = .lookingForPeers
        }
        return phase
    }

    /// The user chose "Keep waiting": the message goes and every stall rule
    /// counts again from `now`.
    func keepWaiting(now: TimeInterval = LoadingPhaseTracker.clock()) {
        stall = nil
        armedAt = now
        update(lastSample, now: now)
    }

    private func detectStall(known: Bool, hasMetadata: Bool, peers: Int, rate: Int, now: TimeInterval) -> LoadingStall? {
        if known && peers == 0 && now - max(lastPeerAt ?? startedAt, armedAt) >= LoadingPhaseTracker.noPeerSeconds {
            return .noPeers
        }
        if !hasMetadata && now - max(startedAt, armedAt) >= LoadingPhaseTracker.noDetailsSeconds {
            return .noDetails
        }
        if hasMetadata && rate < LoadingPhaseTracker.idleDownloadRate
            && now - max(progressAt ?? now, armedAt) >= LoadingPhaseTracker.noDataSeconds {
            return .noData
        }
        return nil
    }

    /// The rate is measured between two increases of the progress (not
    /// between two statuses: most statuses repeat the same value).
    private func updateETA(_ progress: Float, now: TimeInterval) {
        guard let last = etaSample, progress >= last.progress else {
            etaSample = (progress, now)
            return
        }
        guard progress > last.progress, now > last.time else { return }
        let instant = Double(progress - last.progress) / (now - last.time)
        rateEMA = rateEMA == 0 ? instant : 0.7 * rateEMA + 0.3 * instant
        etaSample = (progress, now)
    }

    private func eta(_ progress: Float) -> TimeInterval? {
        guard rateEMA > 0.0001 else { return nil }
        let eta = Double(1 - progress) / rateEMA
        return eta.isFinite && eta > 0 && eta < 3600 ? eta : nil
    }
}

#if canImport(PopcornTorrent)
extension PTTorrentStreamer {
    /// Whether the stream's metadata is in, from a PopcornTorrent that reports
    /// its status before the metadata (`hasMetadata`); nil with an older one.
    /// Looked up at run time, so the app also builds against an older
    /// PopcornTorrent.
    var loadingHasMetadata: Bool? {
        guard responds(to: NSSelectorFromString("hasMetadata")) else { return nil }
        return (value(forKey: "hasMetadata") as? NSNumber)?.boolValue
    }
}

extension LoadingSample {
    /// `streamer`'s state now. `statusArrived`: a progress callback came (an
    /// older PopcornTorrent: the metadata is in).
    init(streamer: PTTorrentStreamer, statusArrived: Bool) {
        let hasMetadata = streamer.loadingHasMetadata ?? (statusArrived ? true : nil)
        guard hasMetadata != nil else {
            self = .unknown
            return
        }
        let status = streamer.torrentStatus
        self.init(hasMetadata: hasMetadata,
                  bufferingProgress: status.bufferingProgress,
                  downloadSpeed: Int(status.downloadSpeed),
                  seeds: Int(status.seeds),
                  peers: Int(status.peers))
    }
}

extension LoadingPhaseTracker {
    /// Updates from `streamer`: call it in the progress block
    /// (`fromCallback: true`) and from a 1 s timer (`false`). nil streamer
    /// (not started yet): only the clock moves.
    @discardableResult
    func update(streamer: PTTorrentStreamer?, fromCallback: Bool,
                now: TimeInterval = LoadingPhaseTracker.clock()) -> LoadingPhase {
        if fromCallback { statusArrived = true }
        guard let streamer = streamer else { return update(.unknown, now: now) }
        return update(LoadingSample(streamer: streamer, statusArrived: statusArrived), now: now)
    }
}
#endif
