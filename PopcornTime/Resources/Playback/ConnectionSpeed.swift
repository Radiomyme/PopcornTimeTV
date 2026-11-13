import Foundation
import PopcornKit
import PopcornTorrent

/// What this device's connection — and the swarms it streams from — really
/// delivers, measured on the streams themselves.
///
/// Every stream posts its status (`PTTorrentStatusDidChangeNotification`,
/// main queue, every 0.5 s plus every finished piece). Per stream a `Meter`
/// keeps a moving window of the download rate (25 s, at least 15 s of data,
/// the first 6 s after the first byte ignored: peer connections are still
/// ramping up) and the stream's PEAK sustained rate: in bounded mode the
/// download slows to the playback rate once the window ahead is full, and a
/// finished file stops it, so only the best window measures the capacity.
/// A stream is the lower of the connection and its swarm: only windows with
/// at least `minimumPeers` connected peers count for the connection (a thin
/// swarm measures itself), never a window before the metadata (the metadata
/// exchange) nor an offline download (it shares the line with a stream).
/// The peaks of recent streams form a `History` (UserDefaults, 12 streams,
/// 90 days); its `estimate` is a weighted 90th percentile, recent streams
/// weighing more (half-life 14 days): every sample can only underestimate
/// the connection, so the estimate leans to the best ones. The estimate is
/// published under
/// `StreamBandwidth.connectionEstimateDefaultsKey`, where `Torrent.balancedPick`
/// and the pickers read it (PopcornKit cannot see this app type).
///
/// Thread-safe (one lock); the notification path is a dictionary lookup and
/// a time comparison for the many status posts that come closer than
/// 0.45 s. Rates are in BYTES per second, like libtorrent's.
///
/// Call `start()` once before streams start (app launch); the quality
/// pickers also call it, so it runs whenever a quality was chosen.
final class ConnectionSpeed {

    static let shared = ConnectionSpeed(persists: !ConnectionSpeed.isDebugRun)

    /// Length of the moving window behind `sustainedRate(of:)` (seconds):
    /// a rate change shows fully in it after that long.
    static var windowSeconds: TimeInterval { Tuning().window }

    /// A DEBUG run of the offline hooks (local swarm on 127.0.0.1).
    private static var isDebugRun: Bool {
        #if DEBUG
        return BoundedStorageDebugHooks.isActive
        #else
        return false
        #endif
    }

    struct Tuning {
        /// Seconds after the first downloaded byte of a stream left out.
        var warmup: TimeInterval = 6
        /// Length of the moving window.
        var window: TimeInterval = 25
        /// Data the window needs before it gives a rate.
        var minimumSpan: TimeInterval = 15
        /// Status posts closer than this to the previous sample are skipped.
        var sampleInterval: TimeInterval = 0.45
        /// A longer silence (stream finished, stopped, resumed) restarts the window.
        var gapReset: TimeInterval = 10
        /// A stream whose peak stays below this (64 KB/s ≈ 0.5 Mbit/s) measured
        /// a dead swarm, not the connection: not recorded.
        var minimumPeak: Double = 64 * 1024
        /// Connected peers (seeds included) a window needs to count for the
        /// connection: fewer, and the swarm is the bottleneck.
        var minimumPeers = 8
        var historyLimit = 12
        var halfLife: TimeInterval = 14 * 86_400
        var maximumAge: TimeInterval = 90 * 86_400
        var percentile = 0.9
    }

    // MARK: Per stream

    /// Moving-window download rate of one stream.
    struct Meter {
        private(set) var samples: [(time: TimeInterval, rate: Double)] = []
        /// When the stream first downloaded something (warm-up start).
        private(set) var activeSince: TimeInterval?
        private(set) var lastTime: TimeInterval?
        /// Time-weighted mean rate of the current window, nil until it spans `minimumSpan`.
        private(set) var sustained: Double?
        /// Best `sustained` of the stream so far.
        private(set) var peak: Double?

        /// False when the sample came too soon after the previous one (skipped).
        @discardableResult
        mutating func add(rate: Double, at time: TimeInterval, tuning: Tuning) -> Bool {
            if let last = lastTime {
                if time - last < tuning.sampleInterval && time >= last { return false }
                if time - last > tuning.gapReset || time < last {
                    samples.removeAll()
                    activeSince = nil
                    sustained = nil
                }
            }
            lastTime = time
            let rate = rate.isFinite ? max(0, rate) : 0
            if activeSince == nil {
                guard rate > 0 else { return true }
                activeSince = time
            }
            guard time - activeSince! >= tuning.warmup else { return true }
            samples.append((time, rate))
            if let stale = samples.firstIndex(where: { $0.time >= time - tuning.window }), stale > 0 {
                samples.removeFirst(stale)
            }
            guard samples.count >= 2, time - samples[0].time >= tuning.minimumSpan else { return true }
            var bytes = 0.0, seconds = 0.0
            for i in 1..<samples.count {
                // Each rate holds since the previous sample (at most 2 s of it).
                let dt = min(samples[i].time - samples[i - 1].time, 2)
                bytes += samples[i].rate * dt
                seconds += dt
            }
            guard seconds > 0 else { return true }
            let mean = bytes / seconds
            sustained = mean
            peak = max(peak ?? 0, mean)
            return true
        }
    }

    // MARK: Across streams

    /// Peak sustained rates of recent streams.
    struct History {
        struct Entry: Equatable {
            var id: String
            var rate: Double
            var date: Date
        }
        private(set) var entries: [Entry] = []

        init(entries: [Entry] = []) {
            self.entries = entries
        }

        /// Sets the entry `id` (a stream) to `rate` at `date`, or adds it; keeps the newest `limit`.
        mutating func record(id: String, rate: Double, date: Date, limit: Int) {
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].rate = max(entries[index].rate, rate)
                entries[index].date = date
            } else {
                entries.append(Entry(id: id, rate: rate, date: date))
            }
            entries.sort { $0.date < $1.date }
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
        }

        /// Weighted `tuning.percentile` of the entries no older than
        /// `maximumAge`, each weighing 0.5^(age / halfLife); nil when none.
        func estimate(at date: Date, tuning: Tuning) -> Double? {
            let weighted = entries.compactMap { entry -> (rate: Double, weight: Double)? in
                let age = max(0, date.timeIntervalSince(entry.date))
                guard age <= tuning.maximumAge, entry.rate.isFinite, entry.rate > 0 else { return nil }
                return (entry.rate, pow(0.5, age / tuning.halfLife))
            }.sorted { $0.rate < $1.rate }
            let total = weighted.reduce(0) { $0 + $1.weight }
            guard total > 0 else { return nil }
            var cumulative = 0.0
            for item in weighted {
                cumulative += item.weight
                if cumulative >= tuning.percentile * total * (1 - 1e-9) { return item.rate }
            }
            return weighted.last?.rate
        }

        var propertyList: [[String: Any]] {
            return entries.map { ["id": $0.id, "rate": $0.rate, "date": $0.date.timeIntervalSince1970] }
        }

        init(propertyList: Any?) {
            let list = propertyList as? [[String: Any]] ?? []
            entries = list.compactMap { item in
                guard let id = item["id"] as? String,
                      let rate = (item["rate"] as? NSNumber)?.doubleValue,
                      let date = (item["date"] as? NSNumber)?.doubleValue else { return nil }
                return Entry(id: id, rate: rate, date: Date(timeIntervalSince1970: date))
            }.sorted { $0.date < $1.date }
        }
    }

    // MARK: State

    static let historyDefaultsKey = "PTConnectionSpeedHistory"

    private struct Stream {
        weak var object: AnyObject?
        var meter = Meter()
        let entryID = UUID().uuidString
        var recordedPeak = 0.0
        /// Best sustained rate while well connected (`Tuning.minimumPeers`):
        /// what the history records for this stream.
        var connectionPeak = 0.0

        init(object: AnyObject) {
            self.object = object
        }
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    /// False: measures in memory only, never writes the history or the
    /// estimate (DEBUG verification runs on a loopback swarm, whose rates
    /// would become this Mac's / Apple TV's "connection").
    private let persists: Bool
    private let tuning: Tuning
    private let clock: () -> TimeInterval
    private let now: () -> Date
    private var started = false
    private var observer: NSObjectProtocol?
    private var streams: [ObjectIdentifier: Stream] = [:]
    private var latest: ObjectIdentifier?
    private var history: History

    init(defaults: UserDefaults = .standard,
         persists: Bool = true,
         tuning: Tuning = Tuning(),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.persists = persists
        self.tuning = tuning
        self.clock = clock
        self.now = now
        self.history = History(propertyList: defaults.array(forKey: ConnectionSpeed.historyDefaultsKey))
    }

    // MARK: API

    /// Starts measuring every stream (idempotent, any thread) and refreshes
    /// the published estimate (its weights decay with time).
    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        publishEstimateLocked()
        lock.unlock()
        observer = NotificationCenter.default.addObserver(forName: .PTTorrentStatusDidChange, object: nil, queue: nil) { [weak self] note in
            // Streams only (an offline download shares the line), from
            // their metadata on (before it: the metadata exchange's trickle,
            // which would start the warm-up too early).
            guard let streamer = note.object as? PTTorrentStreamer, !(streamer is PTTorrentDownload),
                  streamer.loadingHasMetadata != false else { return }
            let status = streamer.torrentStatus
            self?.record(rate: Double(status.downloadSpeed), from: streamer, peers: Int(status.peers))
        }
    }

    /// What the connection + typical swarms deliver, in bytes/s (the
    /// published `StreamBandwidth.connectionEstimate`); nil until a stream
    /// measured it.
    var estimate: Double? {
        let value = defaults.double(forKey: StreamBandwidth.connectionEstimateDefaultsKey)
        return value.isFinite && value > 0 ? value : nil
    }

    /// Sustained download rate (bytes/s, moving window) of the stream that
    /// reported last, if it reported within 3 s; nil before its window has
    /// enough data.
    var currentSustainedRate: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let id = latest, let stream = streams[id], stream.object != nil,
              let last = stream.meter.lastTime, clock() - last <= 3 else { return nil }
        return stream.meter.sustained
    }

    /// Sustained download rate (bytes/s) of `streamer`'s stream, nil before
    /// its window has enough data.
    func sustainedRate(of streamer: AnyObject) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let stream = streams[ObjectIdentifier(streamer)], stream.object === streamer else { return nil }
        return stream.meter.sustained
    }

    /// Best sustained rate (bytes/s) `streamer`'s stream reached so far.
    func peakSustainedRate(of streamer: AnyObject) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let stream = streams[ObjectIdentifier(streamer)], stream.object === streamer else { return nil }
        return stream.meter.peak
    }

    /// Forgets every measurement (the estimate becomes unknown).
    func forget() {
        lock.lock(); defer { lock.unlock() }
        streams.removeAll()
        latest = nil
        history = History()
        if persists { defaults.removeObject(forKey: ConnectionSpeed.historyDefaultsKey) }
        publishEstimateLocked()
    }

    /// One status of `source`'s stream: its download rate (bytes/s) at
    /// `time` (monotonic seconds; default now) with `peers` connected (nil:
    /// unknown, counts as well connected). Called by the notification
    /// observer; internal for the tests.
    func record(rate: Double, from source: AnyObject, at time: TimeInterval? = nil, peers: Int? = nil) {
        let time = time ?? clock()
        let id = ObjectIdentifier(source)
        lock.lock(); defer { lock.unlock() }
        if streams[id]?.object !== source {
            streams = streams.filter { $0.value.object != nil }   // streams that ended
            streams[id] = Stream(object: source)
        }
        guard streams[id]!.meter.add(rate: rate, at: time, tuning: tuning) else { return }
        latest = id
        // The connection only from windows a thin swarm did not limit.
        if let sustained = streams[id]!.meter.sustained, (peers ?? Int.max) >= tuning.minimumPeers {
            streams[id]!.connectionPeak = max(streams[id]!.connectionPeak, sustained)
        }
        let stream = streams[id]!
        let peak = stream.connectionPeak
        guard peak >= tuning.minimumPeak, peak > stream.recordedPeak * 1.03 else { return }
        streams[id]!.recordedPeak = peak
        history.record(id: stream.entryID, rate: peak, date: now(), limit: tuning.historyLimit)
        if persists {
            defaults.set(history.propertyList, forKey: ConnectionSpeed.historyDefaultsKey)
        }
        publishEstimateLocked()
        #if DEBUG
        let estimate = history.estimate(at: now(), tuning: tuning) ?? 0
        print(String(format: "[ConnectionSpeed] stream peak %.1f Mb/s -> connection estimate %.1f Mb/s (%ld streams)",
                     StreamBandwidth.megabitsPerSecond(peak), StreamBandwidth.megabitsPerSecond(estimate), history.entries.count))
        #endif
    }

    private func publishEstimateLocked() {
        guard persists else { return }
        if let estimate = history.estimate(at: now(), tuning: tuning) {
            defaults.set(estimate, forKey: StreamBandwidth.connectionEstimateDefaultsKey)
        } else {
            defaults.removeObject(forKey: StreamBandwidth.connectionEstimateDefaultsKey)
        }
    }
}

// MARK: - Picker texts

extension Torrent {

    /// "≈ 72 Mb/s": the release's estimated bitrate, nil without an estimate
    /// (size or runtime unknown, a pack's size).
    var bitrateLabel: String? {
        guard let bitrate = estimatedBitrate else { return nil }
        return String(format: NSLocalizedString("Bandwidth.Bitrate", value: "≈ %d Mb/s",
                                                comment: "Quality picker: estimated video bitrate of a release, in megabits per second; %d = the number"),
                      BandwidthText.wholeMegabits(bitrate))
    }

    /// One-line warning for a release likely too heavy for the connection
    /// (`bandwidthFit`), nil when it fits or nothing is known. With a
    /// measured connection it says what the downloads reach.
    func bandwidthWarning(connection: Double? = StreamBandwidth.connectionEstimate) -> String? {
        let fit = bandwidthFit(connection: connection)
        guard fit.isTooHeavy else { return nil }
        return BandwidthText.warning(connection: connection)
    }
}

enum BandwidthText {
    /// Bytes/s → whole megabits per second, at least 1.
    static func wholeMegabits(_ bytesPerSecond: Double) -> Int {
        let value = StreamBandwidth.megabitsPerSecond(bytesPerSecond)
        guard value.isFinite else { return 1 }
        return max(1, Int(value.rounded()))
    }

    /// The warning of a release too heavy for `connection` (bytes/s; nil:
    /// not measured yet, the release is merely very heavy). The measure is
    /// what recent streams reached — the line, or its swarms: "your
    /// downloads", not "your connection".
    static func warning(connection: Double?) -> String {
        guard let connection = connection, connection > 0 else {
            return NSLocalizedString("Bandwidth.Warning.Heavy", value: "Very heavy: may stutter",
                                     comment: "Quality picker: very high bitrate release (4K remux) while the connection speed is not known yet")
        }
        return String(format: NSLocalizedString("Bandwidth.Warning.Connection",
                                                value: "May stutter: your downloads reach about %d Mb/s",
                                                comment: "Quality picker: the release's bitrate is above what recent streams downloaded; %d = that speed in megabits per second"),
                      wholeMegabits(connection))
    }

    /// Megabits per second for a sentence: one decimal under 10 ("5.4"),
    /// whole above ("72"), in the user's locale; rounded `up` (a bitrate
    /// needed) or down (a rate obtained), so a release heavier than the
    /// download never reads as the same number.
    static func megabits(_ bytesPerSecond: Double, roundingUp up: Bool) -> String {
        var value = StreamBandwidth.megabitsPerSecond(bytesPerSecond)
        if !value.isFinite || value < 0 { value = 0 }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = value < 10 ? 1 : 0
        formatter.roundingMode = up ? .up : .down
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }
}
