import Foundation
import Combine
import ObjectiveC
import PopcornKit
import PopcornTorrent
#if os(iOS) || os(macOS)
import SwiftUI
#endif
#if os(tvOS)
import UIKit
#endif

// A release heavier than what the download sustains plays in fits and
// starts: a 72 Mb/s UHD remux fed at 27 Mb/s stalls every few seconds, and the
// players' starvation handling (wait, rebuild, VLC) can only wait for data
// that comes too slowly. While a stream plays, `BandwidthDeficitMonitor`
// compares the release's bitrate with the stream's sustained download rate
// (`ConnectionSpeed`) and, when the download clearly can't keep up, offers a
// lighter release of the same movie / episode that fits the measured rate,
// resuming at the current position — or to carry on ("Continue": not asked
// again for this stream). Every route and platform: the native players
// (remux, direct MP4) and VLC on tvOS, iOS and macOS.
//
// - `PlaybackStreamContext`: what the players know about a stream besides its
//   streamer (title, release, the title's other releases, how to switch),
//   attached to the streamer so it follows a native → VLC hand-off.
// - `BandwidthDeficitWatch`: the rules (pure, testable).
// - `BandwidthDeficitMonitor`: samples the stream and the player once a
//   second, publishes the offer the players show.
// - `BandwidthDeficitBanner` (iOS / macOS, SwiftUI) and
//   `BandwidthDeficitToastController` (tvOS, both players).
// - `BandwidthDebugHooks` (DEBUG): launch arguments that make each path
//   testable offline.

// MARK: - The stream's context

/// What the players know about one stream besides its streamer: the movie or
/// episode, the release it plays, the other releases of the same title and
/// how this platform plays one of them instead. Attached to the streamer
/// (`attach`): it follows the stream through a hand-off from the native
/// player to VLC. Main queue.
final class PlaybackStreamContext {
    let media: Media
    /// The URL the stream started from (magnet, .torrent path or URL).
    let sourceURL: String
    /// The release playing, runtime attached (a bare `Torrent(url:)` when
    /// the URL is not in the title's list: nothing known but the URL).
    let torrent: Torrent
    /// Every known release of the same movie / episode, runtime attached
    /// (the playing one included): where a lighter release is looked for.
    let sources: [Torrent]
    /// A start position (0…1) the user already decided — a switch to a
    /// lighter release: the players start there without asking.
    var decidedStart: Float?
    /// Plays `torrent` from `fraction` (0…1) instead of this stream: the
    /// platform's play flow (tvOS: `AppDelegate.play`; iOS: the detail
    /// page; macOS: the player sheet). nil: no switch possible here.
    var onSwitch: ((Torrent, Float) -> Void)?
    private(set) weak var streamer: PTTorrentStreamer?
    /// Watches the download against the release's bitrate while it plays.
    private(set) lazy var deficit = BandwidthDeficitMonitor(context: self)

    private init(streamer: PTTorrentStreamer, media: Media, sourceURL: String, torrent: Torrent, sources: [Torrent]) {
        self.streamer = streamer
        self.media = media
        self.sourceURL = sourceURL
        self.torrent = torrent
        self.sources = sources
    }

    /// Attaches a context to `streamer` (before it starts) and starts
    /// measuring the connection (`ConnectionSpeed.start`, idempotent).
    /// `torrent`: the release (default: the one of `media.torrents` with
    /// `sourceURL`); `sources`: the title's releases (default
    /// `media.torrents`); `decidedStart`: see `decidedStart` (default: a
    /// start requested for `sourceURL` with `requestStart`).
    @discardableResult
    static func attach(to streamer: PTTorrentStreamer, media: Media, sourceURL: String,
                       torrent: Torrent? = nil, sources: [Torrent]? = nil,
                       decidedStart: Float? = nil) -> PlaybackStreamContext {
        ConnectionSpeed.shared.start()
        let runtime = Torrent.mediaRuntime(of: media)
        func withRuntime(_ torrent: Torrent) -> Torrent {
            torrent.mediaRuntime == nil ? torrent.withMediaRuntime(runtime) : torrent
        }
        var list = withDebugSources(sources ?? knownSources(of: media)).map(withRuntime)
        let playing = withRuntime(torrent ?? list.first { $0.url == sourceURL } ?? Torrent(url: sourceURL))
        if !list.contains(where: { $0.url == playing.url }) { list.append(playing) }
        let context = PlaybackStreamContext(streamer: streamer, media: media, sourceURL: sourceURL,
                                            torrent: playing, sources: list)
        context.decidedStart = decidedStart ?? takeRequestedStart(for: sourceURL)
        objc_setAssociatedObject(streamer, &associationKey, context, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        print("[Deficit] stream context: \(media.title) — \(playing.quality ?? "?"), \(list.count) release(s) known"
              + (playing.estimatedBitrate.map { String(format: ", ≈ %.0f Mb/s", StreamBandwidth.megabitsPerSecond($0)) } ?? "")
              + (context.decidedStart.map { String(format: ", decided start %.0f %%", $0 * 100) } ?? ""))
        return context
    }

    /// `decidedStart`, once: the first player of the stream starts there; a
    /// later hand-off to VLC on the same stream passes its own position.
    func takeDecidedStart() -> Float? {
        defer { decidedStart = nil }
        return decidedStart
    }

    /// The releases a quality picker offered for a title (an episode's
    /// merged list: T4P, EZTV, Torrentio, TPB / Knaben): the next streams of
    /// that title know them even when the caller plays the bare episode
    /// (tvOS: `chooseQuality`'s completion gives only the torrent, and the
    /// callers play the episode whose own list is EZTV's).
    static func noteSources(_ torrents: [Torrent], forMediaID id: String) {
        notedSources = (id, torrents)
    }

    private static var notedSources: (id: String, torrents: [Torrent])?

    /// `media.torrents`, or the list noted for it when that one is longer.
    private static func knownSources(of media: Media) -> [Torrent] {
        guard let noted = notedSources, noted.id == media.id, noted.torrents.count > media.torrents.count else {
            return media.torrents
        }
        return noted.torrents
    }

    /// `list`, plus (DEBUG) the releases of `BandwidthDebugHooks` it lacks.
    static func withDebugSources(_ list: [Torrent]) -> [Torrent] {
        #if DEBUG
        return list + BandwidthDebugHooks.extraSources().filter { extra in !list.contains { $0.url == extra.url } }
        #else
        return list
        #endif
    }

    /// The context of `streamer` (nil: none attached, e.g. a download).
    static func of(_ streamer: PTTorrentStreamer?) -> PlaybackStreamContext? {
        guard let streamer = streamer else { return nil }
        return objc_getAssociatedObject(streamer, &associationKey) as? PlaybackStreamContext
    }

    private static var associationKey: UInt8 = 0

    /// The next stream of `url` starts at `fraction`, decided by the user
    /// (tvOS: the switch goes through `AppDelegate.play`, which reads the
    /// saved progress; the context created for that stream takes this one).
    static func requestStart(_ fraction: Float, forURL url: String) {
        requestedStart = (url, fraction)
    }

    private static var requestedStart: (url: String, fraction: Float)?

    private static func takeRequestedStart(for url: String) -> Float? {
        guard let requested = requestedStart, requested.url == url else { return nil }
        requestedStart = nil
        return requested.fraction
    }
}

// MARK: - Rules

/// When the download clearly can't keep up with the release (pure logic,
/// one sample a second while a stream plays):
/// - its sustained rate stays below `ratio` (90 %) of the release's bitrate
///   for `deficitSeconds` (30 s) of playback (the user wants playback: a
///   pause resets the count — the buffer grows meanwhile);
/// - or playback stalled for want of data (`stallSeconds`, 3 s at least)
///   twice within `stallWindow` (5 min), with a rate below the bitrate. A
///   wait that starts within `seekGrace` (10 s) of a seek is the seek's
///   (the data there was never downloaded), not a deficit: not counted.
/// Never while the file is complete, while bounded storage paces the
/// download (the window ahead is full: the pace is the storage's, not the
/// connection's), nor when the download will finish before playback catches
/// up with it (`downloadFinishesFirst`).
struct BandwidthDeficitWatch {
    struct Tuning {
        var ratio = 0.9
        var deficitSeconds: TimeInterval = 30
        var stallSeconds: TimeInterval = 3
        var stallWindow: TimeInterval = 300
        var stallsToOffer = 2
        /// Stalls starting this soon after a seek are not counted.
        var seekGrace: TimeInterval = 10
        /// A playhead further than this from where playback would be is a seek.
        var seekJump: TimeInterval = 5
    }

    struct Sample {
        var now: TimeInterval
        /// Playback started (a frame played).
        var hasStarted: Bool
        /// The user wants playback (not paused).
        var wantsPlayback: Bool
        /// Playback waits for data.
        var isStalled: Bool
        /// The release's bitrate, bytes/s.
        var bitrate: Double?
        /// What the download sustains, bytes/s.
        var rate: Double?
        var isComplete: Bool
        var isStoragePaced: Bool
        /// false when the download will finish before playback catches up
        /// with it; nil: unknown (counts as catching up).
        var catchesUp: Bool?
        /// The player's position (seconds), to tell seeks from playback.
        var playhead: Double? = nil
    }

    enum Reason: String {
        case sustainedDeficit
        case repeatedStarvation
    }

    var tuning = Tuning()
    private(set) var deficitSince: TimeInterval?
    /// Starts of the stalls counted in the window.
    private(set) var stalls: [TimeInterval] = []
    private var stalledSince: TimeInterval?
    private var stallCounted = false
    private var lastPlayhead: (position: Double, at: TimeInterval, playing: Bool)?
    private(set) var lastSeekAt: TimeInterval?

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// The reason to offer a lighter release now, nil when there is none.
    mutating func note(_ sample: Sample) -> Reason? {
        if let position = sample.playhead, position.isFinite {
            if let last = lastPlayhead {
                let expected = last.position + (last.playing ? sample.now - last.at : 0)
                if abs(position - expected) > tuning.seekJump { lastSeekAt = sample.now }
            }
            lastPlayhead = (position, sample.now, sample.wantsPlayback && !sample.isStalled)
        }
        if sample.hasStarted && sample.isStalled {
            if stalledSince == nil {
                stalledSince = sample.now
                stallCounted = false
            }
            if !stallCounted, let since = stalledSince, sample.now - since >= tuning.stallSeconds {
                stallCounted = true
                // A seek's own wait is not a deficit.
                if lastSeekAt.map({ since - $0 > tuning.seekGrace }) ?? true {
                    stalls.append(since)
                }
            }
        } else {
            stalledSince = nil
        }
        stalls.removeAll { sample.now - $0 > tuning.stallWindow }

        guard sample.hasStarted, !sample.isComplete, !sample.isStoragePaced,
              let bitrate = sample.bitrate, bitrate > 0, let rate = sample.rate, rate >= 0,
              sample.catchesUp != false else {
            deficitSince = nil
            return nil
        }
        let short = rate < tuning.ratio * bitrate
        if short && (sample.wantsPlayback || sample.isStalled) {
            if deficitSince == nil { deficitSince = sample.now }
        } else {
            deficitSince = nil
        }
        if let since = deficitSince, sample.now - since >= tuning.deficitSeconds { return .sustainedDeficit }
        if stalls.count >= tuning.stallsToOffer && rate < bitrate { return .repeatedStarvation }
        return nil
    }

    /// Whether the download completes before playback reaches the end of
    /// the data downloaded ahead of it: `contiguousAhead` bytes ahead of the
    /// playhead, `remaining` bytes still to download, at `rate` bytes/s for
    /// a release of `bitrate` bytes/s. The frontier moves at rate / bitrate
    /// media seconds per second, playback at 1: playback catches it up after
    /// ahead / (1 − rate / bitrate) seconds; the download ends after
    /// remaining / rate.
    static func downloadFinishesFirst(contiguousAhead: Double, remaining: Double, rate: Double, bitrate: Double) -> Bool {
        guard bitrate > 0, rate < bitrate else { return true }
        guard rate > 0 else { return remaining <= 0 }
        let catchUp = max(0, contiguousAhead) / bitrate / (1 - rate / bitrate)
        let finish = max(0, remaining) / rate
        return finish <= catchUp
    }

    /// A release worth switching to: clearly lighter than `bitrate` (≤ 80 %
    /// of it, its bitrate known), within what the download sustains
    /// (`StreamBandwidth.fit` against `downloadRate`: ≤ 85 % of it) and with
    /// a healthy swarm (`Torrent.minimumSeedsForQuickStart`) — not a lighter
    /// release that would stall too, nor a gamble on a few seeds. The best
    /// of them by `Torrent.balancedPick` (highest resolution, then the best
    /// playability); nil when none: the offer then has « Continue » only.
    static func lighterRelease(than bitrate: Double, playing url: String, among sources: [Torrent],
                               downloadRate: Double, bitrateOf: (Torrent) -> Double? = { $0.estimatedBitrate }) -> Torrent? {
        let playing = MagnetLink.sourceKey(of: url)
        let lighter = sources.filter { candidate in
            guard candidate.url != url, MagnetLink.sourceKey(of: candidate.url) != playing,
                  candidate.seeds >= Torrent.minimumSeedsForQuickStart(candidate.qualityValue),
                  let candidateBitrate = bitrateOf(candidate) else { return false }
            return candidateBitrate <= bitrate * 0.8
                && !StreamBandwidth.fit(bitrate: candidateBitrate, connection: downloadRate).isTooHeavy
        }
        guard !lighter.isEmpty else { return nil }
        return Torrent.balancedPick(from: lighter, connection: downloadRate)
    }
}

// MARK: - Monitor

/// One stream's deficit watch (`PlaybackStreamContext.deficit`): once a
/// second while a player is attached it reads the stream (download rate,
/// file size, completion, bounded storage's pace, the data ahead of the
/// playhead) and the player (`PlaybackState`), and publishes `offer` when
/// the download clearly can't keep up. The players show the offer and call
/// `acceptLighter` / `continueWatching`. Shown at most until the user acts,
/// or `visibleSeconds`; an offer that timed out may come back after
/// `reofferAfter`; after either action it never comes back for this stream.
/// Main queue.
final class BandwidthDeficitMonitor: ObservableObject {

    /// What the player says once a second.
    struct PlaybackState {
        /// Seconds, the player's timeline.
        var playhead: Double?
        var duration: Double?
        /// A frame played.
        var hasStarted: Bool
        /// The user wants playback (not paused).
        var wantsPlayback: Bool
        /// Waiting for data; nil: inferred from a playhead that does not
        /// move while playback is wanted (VLC reports no buffering state).
        var isStalled: Bool?
    }

    /// The offer the players show.
    struct Offer: Identifiable, Equatable {
        let id = UUID()
        /// Bytes/s.
        let releaseBitrate: Double
        /// Bytes/s.
        let downloadRate: Double
        /// The release to switch to (nil: none fits — "Continue" only).
        let lighter: Torrent?
        let reason: BandwidthDeficitWatch.Reason

        var message: String { BandwidthDeficitText.message(releaseBitrate: releaseBitrate, downloadRate: downloadRate) }

        static func == (lhs: Offer, rhs: Offer) -> Bool { lhs.id == rhs.id }
    }

    /// How long an unanswered offer stays: on tvOS the toast takes the
    /// remote, so shorter there.
    #if os(tvOS)
    static var visibleSeconds: TimeInterval = 15
    #else
    static var visibleSeconds: TimeInterval = 30
    #endif
    static var reofferAfter: TimeInterval = 300

    @Published private(set) var offer: Offer?

    private weak var context: PlaybackStreamContext?
    private var watch: BandwidthDeficitWatch
    private struct Player {
        weak var owner: AnyObject?
        let state: () -> PlaybackState?
        let switchTo: ((Torrent, Float) -> Void)?
    }
    private var players: [Player] = []
    private var timer: Timer?
    /// "Continue" or a lighter release chosen: never again for this stream.
    private(set) var isSettled = false
    private var shownAt: TimeInterval?
    private var hiddenAt: TimeInterval?
    private var lastState: PlaybackState?
    /// Stall inference (VLC): the last playhead and when it last moved.
    private var lastPlayhead: Double?
    private var lastMoveAt: TimeInterval?
    private var lastLogAt: TimeInterval = -.infinity
    /// Bounded storage: when the download was last paced (the window ahead
    /// full). The moving window still holds those slow samples for a while.
    private var lastPacedAt: TimeInterval?
    #if DEBUG
    private var startedAt: TimeInterval?
    #endif

    init(context: PlaybackStreamContext) {
        self.context = context
        var tuning = BandwidthDeficitWatch.Tuning()
        #if DEBUG
        if let seconds = BandwidthDebugHooks.deficitSeconds { tuning.deficitSeconds = seconds }
        #endif
        watch = BandwidthDeficitWatch(tuning: tuning)
    }

    deinit {
        timer?.invalidate()
    }

    private static func clock() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A player plays the stream (the latest attached is the one asked):
    /// `state` once a second; `switchTo`: how it leaves for a lighter
    /// release (closes itself, then `context.onSwitch`); nil = the owner's
    /// `onSwitch` closes it.
    func attach(_ owner: AnyObject, switchTo: ((Torrent, Float) -> Void)? = nil,
                state: @escaping () -> PlaybackState?) {
        players.removeAll { $0.owner == nil || $0.owner === owner }
        players.append(Player(owner: owner, state: state, switchTo: switchTo))
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The player left (closed, or handed the stream over).
    func detach(_ owner: AnyObject) {
        players.removeAll { $0.owner == nil || $0.owner === owner }
        guard players.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        lastPlayhead = nil
        lastMoveAt = nil
    }

    /// Where playback is (0…1, at most `ResumePolicy.handOffMaxFraction`),
    /// from the last sample; nil when unknown.
    var currentFraction: Float? {
        guard let state = lastState, let time = state.playhead, let duration = state.duration,
              let fraction = ResumePolicy.fraction(time: time, duration: duration) else { return nil }
        return ResumePolicy.handOffFraction(reached: fraction)
    }

    /// "Continue": the offer goes, never again for this stream.
    func continueWatching() {
        guard offer != nil || !isSettled else { return }
        isSettled = true
        offer = nil
        print("[Deficit] continue: not asked again for this stream")
    }

    /// "Lighter version": the offer goes and the player leaves for the
    /// lighter release at the current position. False when there is none.
    @discardableResult
    func acceptLighter() -> Bool {
        guard let offer = offer, let lighter = offer.lighter, let context = context else { return false }
        isSettled = true
        self.offer = nil
        let fraction = currentFraction ?? 0
        print(String(format: "[Deficit] lighter version: %@ (%@) at %.1f %%", lighter.quality ?? "?",
                     BandwidthDeficitMonitor.bitrateText(of: lighter), fraction * 100))
        players.removeAll { $0.owner == nil }
        if let switchTo = players.last?.switchTo {
            switchTo(lighter, fraction)
        } else if let onSwitch = context.onSwitch {
            onSwitch(lighter, fraction)
        } else {
            print("[Deficit] no switch path on this screen")
        }
        return true
    }

    private static func bitrateText(of torrent: Torrent) -> String {
        guard let bitrate = releaseBitrate(of: torrent) else { return "bitrate unknown" }
        return String(format: "≈ %.0f Mb/s", StreamBandwidth.megabitsPerSecond(bitrate))
    }

    /// A release's bitrate (bytes/s): its estimate (size / runtime), or the
    /// DEBUG override.
    static func releaseBitrate(of torrent: Torrent) -> Double? {
        #if DEBUG
        if let override = BandwidthDebugHooks.bitrateOverride(for: torrent.url) { return override }
        #endif
        return torrent.estimatedBitrate
    }

    // MARK: Tick

    private func tick() {
        players.removeAll { $0.owner == nil }
        guard let context = context, let streamer = context.streamer, let player = players.last,
              let state = player.state() else { return }
        let now = Self.clock()
        lastState = state
        let stalled = state.isStalled ?? inferredStall(state, now: now)
        let duration = state.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let fileBytes = streamer.fileSize.longLongValue
        let bitrate = streamBitrate(fileBytes: fileBytes, duration: duration, context: context)
        let bounded = streamer.storageMode == .bounded
        // The current window's rate, both modes. Bounded storage paces the
        // download to playback once the window ahead is full: no verdict
        // then, nor for a window's length after (the moving window still
        // holds the paced samples). Unpaced, the window ahead drains, and
        // what comes now is what the swarm and the line give (not the
        // stream's best window: a swarm that slowed down would never show).
        let measured = ConnectionSpeed.shared.sustainedRate(of: streamer)
        #if DEBUG
        let rate = BandwidthDebugHooks.measuredRate ?? measured
        #else
        let rate = measured
        #endif
        let pacedNow = bounded && (streamer.storageStatistics["paceState"]?.intValue ?? 0) != 0
        if pacedNow { lastPacedAt = now }
        let paced = pacedNow || lastPacedAt.map { now - $0 < ConnectionSpeed.windowSeconds } == true
        var complete = streamer.isWholeFileOnDisk
        var catchesUp: Bool?
        if let playhead = state.playhead, let duration = duration, playhead.isFinite, fileBytes > 0 {
            let offset = Int64(max(0, min(1, playhead / duration)) * Double(fileBytes))
            let frontier = streamer.firstMissingOffset(from: offset)
            if frontier >= fileBytes {
                // Everything from here to the end is on disk (a resume
                // part-way, a long pause): playback can't starve.
                complete = true
            } else if let bitrate = bitrate, let rate = rate {
                let ahead = Double(max(0, frontier - offset))
                let remaining = Double(fileBytes) * Double(max(0, 1 - streamer.torrentStatus.totalProgress))
                catchesUp = !BandwidthDeficitWatch.downloadFinishesFirst(contiguousAhead: ahead, remaining: remaining,
                                                                          rate: rate, bitrate: bitrate)
            }
        }
        let noted = watch.note(BandwidthDeficitWatch.Sample(now: now, hasStarted: state.hasStarted,
                                                             wantsPlayback: state.wantsPlayback, isStalled: stalled,
                                                             bitrate: bitrate, rate: rate, isComplete: complete,
                                                             isStoragePaced: paced, catchesUp: catchesUp,
                                                             playhead: state.playhead))
        #if DEBUG
        if state.hasStarted, startedAt == nil { startedAt = now }
        let forced = BandwidthDebugHooks.forceAfter.flatMap { after in
            startedAt.flatMap { now - $0 >= after ? BandwidthDeficitWatch.Reason.sustainedDeficit : nil }
        }
        let reason = noted ?? forced
        if now - lastLogAt >= 10 {
            lastLogAt = now
            print(String(format: "[Deficit] t=%.0f started=%@ playing=%@ stalled=%@ bitrate=%@ rate=%@ (%@) complete=%@ paced=%@ catchesUp=%@ deficitFor=%@ stalls=%ld",
                         state.playhead ?? -1, "\(state.hasStarted)", "\(state.wantsPlayback)", "\(stalled)",
                         bitrate.map { String(format: "%.1fMb/s", StreamBandwidth.megabitsPerSecond($0)) } ?? "-",
                         rate.map { String(format: "%.1fMb/s", StreamBandwidth.megabitsPerSecond($0)) } ?? "-",
                         bounded ? "bounded" : "full", "\(complete)", "\(paced)", catchesUp.map { "\($0)" } ?? "-",
                         watch.deficitSince.map { String(format: "%.0fs", now - $0) } ?? "-", watch.stalls.count))
        }
        #else
        let reason = noted
        #endif
        if let shown = shownAt, offer != nil, now - shown >= Self.visibleSeconds {
            print("[Deficit] offer timed out (no answer): may come back in \(Int(Self.reofferAfter)) s")
            offer = nil
            shownAt = nil
            hiddenAt = now
        }
        guard offer == nil, !isSettled, let found = reason else { return }
        if let hidden = hiddenAt, now - hidden < Self.reofferAfter { return }
        guard let releaseBitrate = bitrate else { return }
        let downloadRate = rate ?? releaseBitrate / 3
        let lighter = BandwidthDeficitWatch.lighterRelease(than: releaseBitrate, playing: context.torrent.url,
                                                           among: context.sources, downloadRate: downloadRate,
                                                           bitrateOf: Self.releaseBitrate(of:))
        let offer = Offer(releaseBitrate: releaseBitrate, downloadRate: downloadRate, lighter: lighter, reason: found)
        print(String(format: "[Deficit] OFFER (%@): release ≈ %.1f Mb/s, download ≈ %.1f Mb/s (%@) at %.0f s — lighter: %@",
                     found.rawValue, StreamBandwidth.megabitsPerSecond(releaseBitrate),
                     StreamBandwidth.megabitsPerSecond(downloadRate), bounded ? "bounded" : "full",
                     state.playhead ?? -1,
                     lighter.map { "\($0.quality ?? "?") \(Self.bitrateText(of: $0)) \($0.seeds) seeds" } ?? "none"))
        self.offer = offer
        shownAt = now
        #if DEBUG
        BandwidthDebugHooks.offerShown(offer, monitor: self)
        #endif
    }

    /// The release's bitrate (bytes/s): the file's real size over the
    /// player's duration when both are known (and plausible), else the
    /// release's estimate (size label / runtime).
    private func streamBitrate(fileBytes: Int64, duration: Double?, context: PlaybackStreamContext) -> Double? {
        #if DEBUG
        if let override = BandwidthDebugHooks.bitrateOverride(for: context.torrent.url) { return override }
        #endif
        if fileBytes > 0, let duration = duration, duration >= 60 {
            let rate = Double(fileBytes) / duration
            if StreamBandwidth.plausibleBitrates.contains(rate) { return rate }
        }
        return context.torrent.estimatedBitrate
    }

    /// VLC: playback wanted while the playhead has not moved for 2 s.
    private func inferredStall(_ state: PlaybackState, now: TimeInterval) -> Bool {
        guard let playhead = state.playhead, playhead.isFinite else { return false }
        if let last = lastPlayhead, abs(playhead - last) < 0.2 {
            // unchanged
        } else {
            lastPlayhead = playhead
            lastMoveAt = now
        }
        guard state.hasStarted, state.wantsPlayback, let moved = lastMoveAt else { return false }
        return now - moved >= 2
    }
}

// MARK: - Texts

enum BandwidthDeficitText {
    /// "This version needs ~72 Mb/s, the download only gives ~27: playback
    /// will stall." One decimal under 10 Mb/s ("~5.5 … ~4.6"), the bitrate
    /// rounded up and the rate down: never "~5 … ~5".
    static func message(releaseBitrate: Double, downloadRate: Double) -> String {
        String(format: NSLocalizedString("BandwidthDeficit.Message",
                                         value: "This version needs ~%1$@ Mb/s, the download only gives ~%2$@: playback will stall.",
                                         comment: "Over the video when the download is slower than the release's bitrate; %1$@ = the release's bitrate, %2$@ = the download rate, both in megabits per second (\"72\", \"5.5\")"),
               BandwidthText.megabits(releaseBitrate, roundingUp: true), BandwidthText.megabits(downloadRate, roundingUp: false))
    }

    static var lighterTitle: String {
        NSLocalizedString("BandwidthDeficit.Lighter", value: "Lighter version",
                          comment: "Button over the video: switch to a lighter release of the same movie / episode, resuming at the current time")
    }

    static var continueTitle: String {
        NSLocalizedString("BandwidthDeficit.Continue", value: "Continue",
                          comment: "Button over the video: keep this release (the bandwidth warning is not shown again for this stream)")
    }
}

// MARK: - SwiftUI banner (iOS, macOS)

#if os(iOS) || os(macOS)
/// The offer at the top of the player, non-blocking: the video plays on
/// under it. Nothing when there is no offer.
struct BandwidthDeficitBanner: View {
    @ObservedObject var monitor: BandwidthDeficitMonitor

    var body: some View {
        VStack {
            if let offer = monitor.offer {
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        Text(offer.message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    HStack(spacing: 10) {
                        if offer.lighter != nil {
                            Button(BandwidthDeficitText.lighterTitle) { monitor.acceptLighter() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button(BandwidthDeficitText.continueTitle) { monitor.continueWatching() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(14)
                .frame(maxWidth: 520, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .environment(\.colorScheme, .dark)
                // Below the bounded-storage capsule (a limited rewind: 52 /
                // 64 pt from the top, about 40 pt high), which may show too.
                .padding(.top, BandwidthDeficitBanner.topInset)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: monitor.offer)
    }

    #if os(macOS)
    static let topInset: CGFloat = 104
    #else
    static let topInset: CGFloat = 116
    #endif
}
#endif

// MARK: - tvOS toast

#if os(tvOS)
/// The offer over the tvOS players: a card at the top, presented over the
/// playing video (`.overFullScreen`); Menu = "Continue". (The VLC player's
/// own remote handling leaves no room for focusable buttons in its view, and
/// AVKit hides its contextual actions while the native player waits for
/// data.) It takes the remote while it shows (15 s at most): « Continue » is
/// focused (a click meant for the player keeps this release: nothing
/// restarts), clicks in its first second are ignored, and Play/Pause still
/// reaches the player (`onPlayPause`). VoiceOver reads the message.
final class BandwidthDeficitToastController: UIViewController {
    private let offer: BandwidthDeficitMonitor.Offer
    private let onLighter: () -> Void
    private let onContinue: () -> Void
    private let onPlayPause: (() -> Void)?
    private var lighterButton: UIButton?
    private var continueButton: UIButton?
    private var answered = false
    /// Clicks before this (system uptime) are ignored: a press meant for the
    /// player as the card appears.
    private var acceptsClicksAt: TimeInterval = .infinity

    init(offer: BandwidthDeficitMonitor.Offer, onLighter: @escaping () -> Void, onContinue: @escaping () -> Void,
         onPlayPause: (() -> Void)? = nil) {
        self.offer = offer
        self.onLighter = onLighter
        self.onContinue = onContinue
        self.onPlayPause = onPlayPause
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The offer this toast shows.
    var offerID: UUID { offer.id }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        card.layer.cornerRadius = 24
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        let label = UILabel()
        label.text = offer.message
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .callout)
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
        icon.tintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let messageRow = UIStackView(arrangedSubviews: [icon, label])
        messageRow.spacing = 16
        messageRow.alignment = .center

        var buttons: [UIButton] = []
        if offer.lighter != nil {
            let button = UIButton(type: .system)
            button.setTitle(BandwidthDeficitText.lighterTitle, for: .normal)
            button.addTarget(self, action: #selector(lighterTapped), for: .primaryActionTriggered)
            lighterButton = button
            buttons.append(button)
        }
        let continueButton = UIButton(type: .system)
        continueButton.setTitle(BandwidthDeficitText.continueTitle, for: .normal)
        continueButton.addTarget(self, action: #selector(continueTapped), for: .primaryActionTriggered)
        self.continueButton = continueButton
        buttons.append(continueButton)
        let buttonRow = UIStackView(arrangedSubviews: buttons)
        buttonRow.spacing = 40

        let stack = UIStackView(arrangedSubviews: [messageRow, buttonRow])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 1100),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -40),
        ])
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [continueButton ?? lighterButton].compactMap { $0 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        acceptsClicksAt = ProcessInfo.processInfo.systemUptime + 1
        UIAccessibility.post(notification: .announcement, argument: offer.message)
    }

    private var acceptsClicks: Bool { ProcessInfo.processInfo.systemUptime >= acceptsClicksAt }

    @objc private func lighterTapped() {
        guard !answered, acceptsClicks else { return }
        answered = true
        onLighter()
    }

    @objc private func continueTapped() {
        guard !answered, acceptsClicks else { return }
        answered = true
        onContinue()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            guard !answered else { return }
            answered = true
            onContinue()
            return
        }
        if presses.contains(where: { $0.type == .playPause }), let onPlayPause = onPlayPause {
            onPlayPause()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // Menu's end (and Play/Pause's) stay here too: passed on, they reached
    // the player under the toast, whose Menu handling acts on the press's end.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu || ($0.type == .playPause && onPlayPause != nil) }) { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu || ($0.type == .playPause && onPlayPause != nil) }) { return }
        super.pressesCancelled(presses, with: event)
    }
}
#endif

// MARK: - DEBUG hooks

#if DEBUG
/// Offline verification of the bandwidth-deficit paths (compiled with DEBUG
/// only, like `BoundedStorageDebugHooks`). Launch arguments:
/// - `-PTDebugReleaseBitrate <bytes/s>`: the playing release's bitrate
///   (default: the file's size over the player's duration, else the
///   release's estimate);
/// - `-PTDebugMeasuredRate <bytes/s>`: the download rate the monitor uses
///   (default: `ConnectionSpeed`'s measure of the stream);
/// - `-PTDebugDeficitSeconds <s>`: the sustained-deficit time (default 30);
/// - `-PTDebugForceDeficit <s>`: the offer that long after playback started,
///   whatever the rates;
/// - `-PTDebugLighterTorrent <absolute .torrent path>` (+
///   `-PTDebugLighterBitrate <bytes/s>`, default 200000, and
///   `-PTDebugLighterQuality <label>`, default "720p"): a lighter release
///   of the playing title (100 seeds), offered by "Lighter version";
/// - `-PTDebugDeficitAction "<lighter|continue>@<s>"`: that long after the
///   offer appears, presses its button (the UI's own path);
/// - `-PTDebugLoadingAction "<choose|wait>@<s>"` (macOS, iOS): that long
///   after the loading screen says the source is not answering, presses
///   « Choose another source » or « Keep waiting ».
/// Every step logs a "[Deficit]" line.
enum BandwidthDebugHooks {
    private static var defaults: UserDefaults { .standard }

    private static func number(_ key: String) -> Double? {
        defaults.string(forKey: key).flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    static var releaseBitrate: Double? { number("PTDebugReleaseBitrate") }
    static var measuredRate: Double? { number("PTDebugMeasuredRate") }
    static var deficitSeconds: Double? { number("PTDebugDeficitSeconds") }
    static var forceAfter: Double? { number("PTDebugForceDeficit") }

    static var lighterTorrentFile: String? { defaults.string(forKey: "PTDebugLighterTorrent") }

    /// The bitrate of `url`: the lighter torrent's, or the playing release's
    /// override (any other URL).
    static func bitrateOverride(for url: String) -> Double? {
        if let file = lighterTorrentFile, url == file { return number("PTDebugLighterBitrate") ?? 200_000 }
        return releaseBitrate
    }

    /// The lighter release (`-PTDebugLighterTorrent`), as a source of the title.
    static func extraSources() -> [Torrent] {
        guard let file = lighterTorrentFile, !file.isEmpty else { return [] }
        return [Torrent(url: file, quality: defaults.string(forKey: "PTDebugLighterQuality") ?? "720p", seeds: 100, peers: 100)]
    }

    /// `-PTDebugLoadingAction`: the loading screen says the source is not
    /// answering; `choose` is nil when there is no other source.
    static func loadingStalled(choose: (() -> Void)?, keepWaiting: @escaping () -> Void) {
        guard let text = defaults.string(forKey: "PTDebugLoadingAction") else { return }
        let parts = text.split(separator: "@").map { $0.trimmingCharacters(in: .whitespaces) }
        let action = parts.first ?? "choose"
        let delay = parts.count > 1 ? Double(parts[1]) ?? 3 : 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if action == "wait" {
                print("[Deficit] debug: pressing keep waiting")
                keepWaiting()
            } else if let choose = choose {
                print("[Deficit] debug: pressing choose another source")
                choose()
            } else {
                print("[Deficit] debug: no other source to choose")
            }
        }
    }

    /// `-PTDebugDeficitAction`: presses the offer's button `at` seconds after it appeared.
    static func offerShown(_ offer: BandwidthDeficitMonitor.Offer, monitor: BandwidthDeficitMonitor) {
        guard let text = defaults.string(forKey: "PTDebugDeficitAction") else { return }
        let parts = text.split(separator: "@").map { $0.trimmingCharacters(in: .whitespaces) }
        let action = parts.first ?? "lighter"
        let delay = parts.count > 1 ? Double(parts[1]) ?? 3 : 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak monitor] in
            guard let monitor = monitor, monitor.offer?.id == offer.id else { return }
            print("[Deficit] debug: pressing \(action)")
            if action == "continue" { monitor.continueWatching() } else { monitor.acceptLighter() }
        }
    }
}
#endif
