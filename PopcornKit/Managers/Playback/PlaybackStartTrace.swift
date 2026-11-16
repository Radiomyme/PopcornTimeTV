import Foundation

/// One playback's start as `[Start]` log lines, from Play to the first frame:
/// one line per phase with the time the phase took and the time since Play,
/// then a total. Before, the `[Play]`, `[Streamer]`, `[Remux]` and `[Player]`
/// lines carried no time at all: what a change to the start-up gained could
/// not be read from the app's logs.
///
///     [Start] sources: 1240 ms — S02E05: 14 torrents (T4P 3 · Torrentio 9 · TPB/Knaben 2)
///     [Start] subtitles: 830 ms (t+830 ms) — 23 language(s)
///     [Start] metadata: 3200 ms (t+3200 ms) — 12 peer(s)
///     [Start] buffer: 8100 ms (t+11300 ms) — Show.S02E05.1080p.mkv
///     [Start] remux prepare: 420 ms (t+11720 ms) — 2 segment(s)
///     [Start] first frame: 900 ms (t+12620 ms) — AVPlayer (remux)
///     [Start] total: 12620 ms to the first frame — Show (subtitles 830 ms · metadata 3200 ms · …)
///
/// The trace starts when the stream is asked for (the user's Play, or the
/// pick in the quality chooser). `metadata`, `buffer`, `remux prepare` and
/// `first frame` follow one another: each lasts from the end of the one
/// before it (the trace's start for the first). `subtitles` runs alongside
/// them, from its `begin`. `sources` (an episode's sources) comes before the
/// trace, with the chooser in between: its line is logged on its own
/// (`sourcesLine`). A phase is reached once; a route without it (no remux
/// for an MP4 or on VLC, no metadata for a finished download) just has no
/// line. Any thread.
public final class PlaybackStartTrace {

    public enum Phase: String, CaseIterable {
        case sources
        case subtitles
        case metadata
        case buffer
        case remuxPrepare = "remux prepare"
        case firstFrame = "first frame"

        /// Follows the phase before it (see the type's comment).
        var isSequential: Bool {
            switch self {
            case .sources, .subtitles: return false
            case .metadata, .buffer, .remuxPrepare, .firstFrame: return true
            }
        }
    }

    public let title: String
    private let now: () -> TimeInterval
    private let log: (String) -> Void
    private let lock = NSLock()
    private let startedAt: TimeInterval
    /// Where the next sequential phase starts.
    private var cursor: TimeInterval
    private var begun: [Phase: TimeInterval] = [:]
    private var durations: [Phase: TimeInterval] = [:]

    /// - Parameters:
    ///   - now: a monotonic clock, in seconds (the tests give their own).
    ///   - log: where the lines go (default: the console).
    public init(title: String,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                log: @escaping (String) -> Void = { print($0) }) {
        self.title = title
        self.now = now
        self.log = log
        startedAt = now()
        cursor = startedAt
    }

    /// `phase` starts now. Without it, a sequential phase starts where the
    /// one before it ended and the others at the trace's start.
    public func begin(_ phase: Phase) {
        let time = now()
        lock.lock()
        if durations[phase] == nil { begun[phase] = time }
        lock.unlock()
    }

    /// `phase` is over: its line is logged, once (false: it already was).
    /// `first frame` also logs the total.
    @discardableResult
    public func reach(_ phase: Phase, detail: String? = nil) -> Bool {
        let time = now()
        lock.lock()
        guard durations[phase] == nil else {
            lock.unlock()
            return false
        }
        let start = begun[phase] ?? (phase.isSequential ? cursor : startedAt)
        let elapsed = max(0, time - start)
        durations[phase] = elapsed
        if phase.isSequential { cursor = max(cursor, time) }
        let sinceStart = max(0, time - startedAt)
        let total = phase == .firstFrame ? totalLine(sinceStart: sinceStart) : nil
        lock.unlock()
        log(Self.line(phase, elapsed: elapsed, sinceStart: sinceStart, detail: detail))
        if let total = total { log(total) }
        return true
    }

    /// How long `phase` took (seconds); nil until it is reached.
    public func duration(of phase: Phase) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return durations[phase]
    }

    /// Seconds since the trace started: the `t+` of its lines (the
    /// `[Measure]` lines use it too).
    public func sinceStart() -> TimeInterval {
        return max(0, now() - startedAt)
    }

    /// Under `lock`.
    private func totalLine(sinceStart: TimeInterval) -> String {
        let parts = Phase.allCases.compactMap { phase in
            durations[phase].map { "\(phase.rawValue) \(Self.milliseconds($0)) ms" }
        }
        return "[Start] total: \(Self.milliseconds(sinceStart)) ms to the first frame — \(title) (\(parts.joined(separator: " · ")))"
    }

    // MARK: Lines

    /// `[Start] <phase>: <elapsed> ms (t+<since the start> ms) — <detail>`.
    public static func line(_ phase: Phase, elapsed: TimeInterval, sinceStart: TimeInterval? = nil, detail: String? = nil) -> String {
        var line = "[Start] \(phase.rawValue): \(milliseconds(elapsed)) ms"
        if let sinceStart = sinceStart { line += " (t+\(milliseconds(sinceStart)) ms)" }
        if let detail = detail, !detail.isEmpty { line += " — \(detail)" }
        return line
    }

    /// The line of an episode's sources (`EpisodeSourceResolver`): they are
    /// fetched before the quality chooser, so before any trace starts.
    public static func sourcesLine(elapsed: TimeInterval, detail: String) -> String {
        return line(.sources, elapsed: elapsed, detail: detail)
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds * 1000, 1e12).rounded())
    }
}
