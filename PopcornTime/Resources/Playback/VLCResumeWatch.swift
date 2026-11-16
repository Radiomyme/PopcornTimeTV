import Foundation

/// A VLC player's resume, watched until playback really runs (pure: the
/// players sample VLC about once a second, the tests replay recorded runs).
///
/// A VLC player opens the stream at 0:00 and seeks to the resume point once
/// the input is seekable. VLC says nothing about how that goes: its state is
/// `.playing` and `isPlaying` is true from `play()` on, and its clock shows
/// 00:00 or the target, frozen, for as long as it waits for the data there —
/// seconds with a demuxer that jumps through the file's index, the whole
/// download from the head to the target without one (half an hour for a
/// resume at 1 h 40 of a 9 GB film: the stall of 5.2.0, where the players
/// hid their spinner at VLC's first time point and showed nothing). So the
/// players keep a visible « Resuming at … » state until this watch says the
/// clock runs, and after `offerDelay` of waiting they offer a way out.
///
/// - `arrived`: the clock ran `arrivalAdvance` seconds, sample after sample,
///   from `targetTolerance` before the target on (a seek lands on the
///   keyframe before it). A clock that only SHOWS the target does not count.
/// - `arrived`, elsewhere: the clock ran `elsewhereAdvance` seconds anywhere
///   else, `seekSettle` after the seek was issued. Playback runs, so nothing
///   may stay over the picture, but VLC's clock is not at the target: under
///   libavformat's demuxer a file with text subtitle tracks plays at the
///   target and reports a time that restarts near 0:00 (VLCKit 4.0.0a21,
///   measured in the tvOS simulator, both storage modes), and a seek VLC
///   lost plays on from the head. The clock cannot tell them apart, and
///   another seek freezes the first one's clock for good: nothing is
///   re-issued, the state just goes away.
/// - `offer`: `offerDelay` of waiting while VLC is asked to play, until
///   `keepWaiting(now:)` (30 s more) or the arrival.
struct VLCResumeWatch {

    enum Phase: Equatable {
        /// Not there yet: the spinner and « Resuming at … » stay up.
        case waiting
        /// Waited `offerDelay`: « Keep waiting » / « Start from the beginning ».
        case offer
        /// Playback runs: the resume state goes away, for good.
        case arrived
    }

    /// Where the clock ran when the watch arrived.
    enum Arrival: Equatable {
        case atTarget
        /// Not at the target: VLC's clock is off, or its seek was lost.
        case elsewhere
    }

    /// How far before the target the resume seek may land and still be there.
    static let targetTolerance: Double = 5
    /// Seconds the clock must run at the target.
    static let arrivalAdvance: Double = 2
    /// Seconds the clock must run anywhere else (more: there is no target to
    /// vouch for it).
    static let elsewhereAdvance: Double = 3
    /// After the seek is issued VLC may report the old position for a while
    /// (up to ~2 s with a real audio output): a clock running away from the
    /// target is only believed from this long after the seek.
    static let seekSettle: TimeInterval = 2
    /// Waiting this long brings the offer.
    static let offerDelay: TimeInterval = 30
    /// What a run may miss of `arrivalAdvance` / `elsewhereAdvance`: the
    /// players' timers are a few hundredths late or early, and two samples
    /// "a second apart" must count as a second of clock.
    static let samplingSlack: Double = 0.2
    /// Samples closer than this to the last one are skipped (the macOS
    /// player refreshes twice a second; VLC's time may not have moved).
    static let minimumSampleInterval: TimeInterval = 0.75
    /// One sample never adds more than this to the wait: an app suspended
    /// for minutes does not come back to the offer.
    static let longestCountedStep: TimeInterval = 2

    /// The resume point in seconds of VLC's clock; nil while the film's
    /// length is not known (`setTarget`).
    private(set) var target: Double?
    private(set) var phase: Phase = .waiting
    /// Set with `.arrived`.
    private(set) var arrival: Arrival?
    /// Seconds waited since the start or the last `keepWaiting`, counted
    /// while VLC is asked to play.
    private(set) var waited: TimeInterval = 0

    private var lastObservation: TimeInterval
    private var seekIssuedAt: TimeInterval?
    /// The last sample taken: VLC's clock (s) and when.
    private var last: (clock: Double, at: TimeInterval)?
    /// The first sample, of the run of samples the clock has been advancing
    /// through, that is at the target / late enough after the seek.
    private var targetAnchor: Double?
    private var elsewhereAnchor: Double?

    /// - Parameters:
    ///   - target: the resume point in seconds of VLC's clock, nil when the
    ///     film's length is not known yet.
    ///   - now: a monotonic clock (seconds), the same for every call.
    init(target: Double?, now: TimeInterval) {
        self.target = Self.valid(target)
        lastObservation = now
    }

    private static func valid(_ target: Double?) -> Double? {
        target.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// The target, once the film's length is known. The first one stays.
    mutating func setTarget(_ seconds: Double) {
        guard target == nil else { return }
        target = Self.valid(seconds)
    }

    /// The player just sent VLC to the resume point.
    mutating func seekIssued(now: TimeInterval) {
        seekIssuedAt = now
        elsewhereAnchor = nil
    }

    /// « Keep waiting »: the offer comes back `offerDelay` later.
    mutating func keepWaiting(now: TimeInterval) {
        guard phase != .arrived else { return }
        phase = .waiting
        waited = 0
        lastObservation = now
    }

    /// One sample of VLC.
    /// - Parameters:
    ///   - time: VLC's clock in seconds; nil before its first time point.
    ///   - isPlaying: VLC is asked to play (true through a stall: VLC has no
    ///     buffering state). A paused VLC neither arrives nor waits.
    ///   - now: the monotonic clock of `init`.
    mutating func observe(time: Double?, isPlaying: Bool, now: TimeInterval) -> Phase {
        guard phase != .arrived else { return .arrived }
        if isPlaying { waited += min(max(0, now - lastObservation), Self.longestCountedStep) }
        lastObservation = now
        if let clock = time, clock.isFinite, isPlaying {
            note(clock: clock, at: now)
        } else {
            last = nil
            targetAnchor = nil
            elsewhereAnchor = nil
        }
        if phase == .waiting, waited >= Self.offerDelay { phase = .offer }
        return phase
    }

    private mutating func note(clock: Double, at now: TimeInterval) {
        if let previous = last {
            let wall = now - previous.at
            guard wall >= Self.minimumSampleInterval else { return }
            let step = clock - previous.clock
            // Running: forward, and no faster than playback catching up.
            // Frozen, back, or a jump: the run starts again here.
            if !(step > 0 && step <= wall * 2 + 0.5) {
                targetAnchor = nil
                elsewhereAnchor = nil
            }
        }
        last = (clock, now)
        if let target = target, clock >= target - Self.targetTolerance {
            if let anchor = targetAnchor {
                if clock - anchor >= Self.arrivalAdvance - Self.samplingSlack { arrive(.atTarget) }
            } else {
                targetAnchor = clock
            }
            return
        }
        targetAnchor = nil
        guard let seek = seekIssuedAt, now >= seek + Self.seekSettle else { return }
        if let anchor = elsewhereAnchor {
            if clock - anchor >= Self.elsewhereAdvance - Self.samplingSlack { arrive(.elsewhere) }
        } else {
            elsewhereAnchor = clock
        }
    }

    private mutating func arrive(_ arrival: Arrival) {
        phase = .arrived
        self.arrival = arrival
    }
}

/// One resume of a VLC player as its screen follows it — what the tvOS, iOS
/// and macOS VLC players share around the watch: the target once the film's
/// length is known, the label, the Play/Pause presses kept for the arrival,
/// and the "[Resume] VLC: …" lines (one per decision, with its timing).
struct VLCResumeWait {
    private(set) var watch: VLCResumeWatch
    /// The resume point, 0…1.
    let fraction: Float
    private let startedAt: TimeInterval
    private var seekIssuedAt: TimeInterval?
    private(set) var durationSeconds: Double?
    /// Play/Pause was pressed during the wait: VLC is not paused while it
    /// gets there (the press would stay a pause through the arrival, or be
    /// lost), the player pauses it at the arrival instead.
    private(set) var pausesAtArrival = false

    init(fraction: Float, durationSeconds: Double?, now: TimeInterval) {
        self.fraction = fraction
        startedAt = now
        let duration = Self.valid(durationSeconds)
        self.durationSeconds = duration
        watch = VLCResumeWatch(target: duration.map { Double(fraction) * $0 }, now: now)
        print("[Resume] VLC: resuming at \(position) — the state stays up until playback runs there")
    }

    private static func valid(_ duration: Double?) -> Double? {
        duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// "1:40:00", or "70 %" while the film's length is not known.
    var position: String { VLCResumeText.position(fraction: fraction, durationSeconds: durationSeconds) }

    /// « Resuming at 1:40:00… »
    var label: String { VLCResumeText.resumingAt(position) }

    var phase: VLCResumeWatch.Phase { watch.phase }

    /// The player just sent VLC to the resume point.
    mutating func seekIssued(now: TimeInterval) {
        seekIssuedAt = now
        watch.seekIssued(now: now)
        print(String(format: "[Resume] VLC: seek issued to %@, %.1f s after the start", position, now - startedAt))
    }

    /// One sample of VLC (about once a second): `VLCResumeWatch.observe`,
    /// with the film's length (seconds, nil while VLC does not know it).
    mutating func sample(time: Double?, isPlaying: Bool, durationSeconds: Double?, now: TimeInterval) -> VLCResumeWatch.Phase {
        if self.durationSeconds == nil, let duration = Self.valid(durationSeconds) {
            self.durationSeconds = duration
            watch.setTarget(Double(fraction) * duration)
        }
        let before = watch.phase
        let phase = watch.observe(time: time, isPlaying: isPlaying, now: now)
        guard phase != before else { return phase }
        let clock = time.map { ResumePolicy.clockString(seconds: $0) } ?? "no time yet"
        switch phase {
        case .offer:
            print(String(format: "[Resume] VLC: not at %@ after %.0f s of waiting (VLC's clock: %@) — offer shown",
                         position, watch.waited, clock))
        case .arrived:
            let sinceSeek = seekIssuedAt.map { String(format: ", %.1f s after the seek", now - $0) } ?? ""
            if watch.arrival == .elsewhere {
                print(String(format: "[Resume] VLC: playback runs, at %@ on VLC's clock instead of %@ (its clock is off, or its seek was lost) — state lifted %.1f s after the start%@",
                             clock, position, now - startedAt, sinceSeek))
            } else {
                print(String(format: "[Resume] VLC: playback runs at the target (%@) — %.1f s after the start%@",
                             clock, now - startedAt, sinceSeek))
            }
        case .waiting:
            break
        }
        return phase
    }

    /// « Keep waiting ».
    mutating func keepWaiting(now: TimeInterval) {
        watch.keepWaiting(now: now)
        print(String(format: "[Resume] VLC: answer: keep waiting (%.0f s after the start)", now - startedAt))
    }

    /// Play/Pause during the wait: kept for the arrival. Returns the new intent.
    @discardableResult
    mutating func togglePauseAtArrival() -> Bool {
        pausesAtArrival.toggle()
        print("[Resume] VLC: Play/Pause during the wait — " + (pausesAtArrival ? "pause kept for the arrival" : "playback wanted at the arrival"))
        return pausesAtArrival
    }

    /// The wait ends without an arrival: the player closes, or the user
    /// starts from the beginning.
    func logEnded(_ why: String, now: TimeInterval) {
        guard watch.phase != .arrived else { return }
        print(String(format: "[Resume] VLC: %@ %.1f s into the wait for %@", why, now - startedAt, position))
    }

    /// The monotonic clock the players sample with.
    static var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// « Start from the beginning » of the slow-resume offer, for the watched
/// progress. The app offers it after its own resume failed to arrive, so it
/// is not yet the user's choice to start the film over: the saved resume
/// point stays protected (D8) until playback from 0:00 has really run for
/// `confirmSeconds` — then it is (`VLCWatchProgress.restartFromBeginning`).
/// A user who restarts, finds it still slow and closes to resume elsewhere
/// (another release, the native player) finds the resume point where it was.
enum VLCSlowResumeRestart {
    /// How far into the film playback from 0:00 must get before the restart
    /// counts as the user's.
    static let confirmSeconds: Double = 180

    /// The watched progress of the media opened again at 0:00: from the
    /// start, `progress`'s saved point still protected, and nothing of the
    /// resume's input kept — neither its last position (a save before the
    /// new input's first tick would store it) nor its high water (the wait
    /// counts as at the resume point, which would let a later smaller
    /// position replace it).
    static func progress(restartingFrom progress: VLCWatchProgress) -> VLCWatchProgress {
        VLCWatchProgress(startPosition: 0, resumePoint: progress.resumePoint)
    }

    /// The restart is the user's: VLC's clock (seconds, from 0:00) is past
    /// `confirmSeconds`. nil (no time yet) is not.
    static func isConfirmed(clockSeconds: Double?) -> Bool {
        guard let seconds = clockSeconds, seconds.isFinite else { return false }
        return seconds >= confirmSeconds
    }

    /// The new input's clock must first be seen near 0:00 for a later
    /// `confirmSeconds` to count. A time tick of the abandoned input can
    /// still be queued when the media is opened again: it brings back the
    /// resume point's clock (past 3:00), which alone would confirm the
    /// restart a second after the answer and give the resume point away.
    static let startSeconds: Double = 60

    /// VLC's clock after « Start from the beginning », sample by sample.
    struct Confirmation {
        /// A sample before `startSeconds` was seen: the reopened input runs.
        private(set) var sawStart = false

        /// true once: the clock went from near 0:00 to past `confirmSeconds`.
        mutating func note(clockSeconds: Double?) -> Bool {
            guard let seconds = clockSeconds, seconds.isFinite, seconds >= 0 else { return false }
            if seconds < VLCSlowResumeRestart.startSeconds {
                sawStart = true
                return false
            }
            return sawStart && VLCSlowResumeRestart.isConfirmed(clockSeconds: seconds)
        }
    }
}

#if DEBUG
/// `-PTDebugVLCResumeOffer "<wait|start>@<s>"`: that long after a VLC
/// player's slow-resume offer appears (default 3 s), presses « Keep waiting »
/// or « Start from the beginning » — the simulator has no remote (end-to-end
/// runs; every time for "wait", so the offer comes back).
enum VLCResumeDebugHooks {
    static func offerShown(keepWaiting: @escaping () -> Void, fromStart: (() -> Void)?) {
        guard let text = UserDefaults.standard.string(forKey: "PTDebugVLCResumeOffer") else { return }
        let parts = text.split(separator: "@").map { $0.trimmingCharacters(in: .whitespaces) }
        let action = parts.first ?? "wait"
        let delay = parts.count > 1 ? Double(parts[1]) ?? 3 : 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if action == "start", let fromStart = fromStart {
                print("[ResumeDebug] pressing « Start from the beginning »")
                fromStart()
            } else {
                print("[ResumeDebug] pressing « Keep waiting »" + (action == "start" ? " (no « Start from the beginning » in this offer)" : ""))
                keepWaiting()
            }
        }
    }
}
#endif

/// The texts of a VLC player's resume state (every key is in the 7
/// Localizable.strings tables: VLCResumeWatchTests checks it).
enum VLCResumeText {

    /// Over the video while the resume is on its way; `position` is the
    /// resume point ("1:40:00", or "70 %" while the length is not known).
    static func resumingAt(_ position: String) -> String {
        String(format: NSLocalizedString("VLC.Resume.At", value: "Resuming at %@…",
                                         comment: "VLC player, over the video while it gets to the resume point; %@ = the position (1:40:00)"),
               position)
    }

    /// The offer's message, `VLCResumeWatch.offerDelay` into the wait.
    static var slow: String {
        NSLocalizedString("VLC.Resume.Slow", value: "Resuming is taking longer than expected.",
                          comment: "VLC player: the resume point is not reached after 30 s; two buttons follow")
    }

    static var keepWaiting: String {
        NSLocalizedString("VLC.Resume.KeepWaiting", value: "Keep waiting",
                          comment: "VLC player, button of the slow-resume offer: go on waiting for the resume point")
    }

    static var fromStart: String {
        NSLocalizedString("VLC.Resume.FromStart", value: "Start from the beginning",
                          comment: "VLC player, button of the slow-resume offer: give up the resume point and play from 0:00")
    }

    /// The message of the VLC player's own resume question (a file only VLC
    /// plays: DTS / TrueHD-only audio, AVI, TS…).
    static var questionMessage: String {
        NSLocalizedString("VLC.Resume.Question.Message",
                          value: "This file plays with the VLC player: resuming goes through VLC.",
                          comment: "VLC player's own resume question (Resume Playing / Start from Beginning): this file is not played by the native player")
    }

    /// The keys above, as the tables must have them.
    static let localizationKeys = ["VLC.Resume.At", "VLC.Resume.Slow", "VLC.Resume.KeepWaiting",
                                   "VLC.Resume.FromStart", "VLC.Resume.Question.Message"]

    /// The resume point as the label shows it: the clock time once the
    /// film's length is known, the percentage before.
    static func position(fraction: Float, durationSeconds: Double?) -> String {
        ResumePolicy.resumeLabel(fraction: fraction, durationSeconds: durationSeconds ?? 0)
    }
}
