

import Foundation

// CONTRACT FILE — owned by agent B1. Shared by the tvOS, iOS and macOS apps.
// Pure Foundation: no UIKit / AVFoundation / PopcornKit.

/// Which engine a payload should START on. Every AVPlayer route falls back
/// to VLC at runtime when AVFoundation rejects the media.
enum PlaybackRoute: Equatable {
    /// Matroska / WebM → on-the-fly fMP4/HLS remux → AVPlayer.
    case remux
    /// MP4 / M4V / MOV → AVPlayer directly.
    case avPlayer
    /// Everything else (AVI, TS/M2TS, WMV, FLV, MPEG-PS, OGM…) → VLC.
    case vlc
}

enum PlaybackRouting {

    /// Matroska family: remuxed to fMP4/HLS for AVPlayer (the remuxer itself
    /// decides — within seconds — whether the tracks are playable natively).
    static let remuxExtensions: Set<String> = ["mkv", "mk3d", "webm"]

    /// ISO BMFF / QuickTime: AVPlayer opens these directly.
    static let avPlayerExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// Video containers AVFoundation can't open and the remuxer doesn't
    /// handle: they start on VLC.
    /// Deliberately absent: tokens that double as release-name tags at the
    /// end of a magnet `dn` ("….DV", "….HEVC", "….H264", "…-EVO"). Routing a
    /// Dolby Vision release to VLC on a name tag would throw away HDR/Atmos;
    /// the rare raw stream with such an extension still reaches VLC through
    /// the remuxer's fast "not Matroska" failure.
    static let vlcExtensions: Set<String> = [
        "avi", "divx",                                  // AVI (Xvid / DivX)
        "ts", "m2ts", "mts", "m2t", "tp", "trp",        // MPEG transport streams (Blu-ray, HDTV)
        "wmv", "asf", "wm",                             // Windows Media
        "flv", "f4v",                                   // Flash video
        "mpg", "mpeg", "mpe", "m1v", "m2v", "mpv",      // MPEG program / elementary streams
        "vob", "dat",                                   // DVD / VCD
        "ogm", "ogv", "ogg",                            // Ogg
        "3gp", "3g2",                                   // 3GPP
        "rm", "rmvb", "rv",                             // RealMedia
        "nut", "mxf", "ivf", "y4m", "amv", "bik", "nsv",
    ]

    /// Lowercased extension of a file name, path or URL string ("" when
    /// none). Only the last path component is considered.
    static func fileExtension(of name: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A full URL string: keep its path only (drops ?query / #fragment).
        if base.contains("://"), let url = URL(string: base) {
            base = url.path
        }
        if let separator = base.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            base = String(base[base.index(after: separator)...])
        }
        // A leading dot is a hidden file name, not an extension.
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
        return base[base.index(after: dot)...].lowercased()
    }

    /// Route for a file name or path (case-insensitive extension sniff).
    /// Unknown / missing extension → `.remux` when `fallbackToRemux` (the
    /// remuxer itself fails fast on non-Matroska input), else `.vlc`.
    static func route(forFileName name: String, fallbackToRemux: Bool = true) -> PlaybackRoute {
        let ext = fileExtension(of: name)
        if remuxExtensions.contains(ext) { return .remux }
        if avPlayerExtensions.contains(ext) { return .avPlayer }
        if vlcExtensions.contains(ext) { return .vlc }
        return fallbackToRemux ? .remux : .vlc
    }

    /// The `dn=` display name of a magnet link, percent-decoded, if any.
    /// `dn` may appear anywhere in the query; `+` means a space (form
    /// encoding, used by YTS / Torrentio); HTML-escaped `&amp;` separators
    /// are tolerated.
    static func displayName(fromMagnet magnet: String) -> String? {
        var query = Substring(magnet)
        if let questionMark = magnet.firstIndex(of: "?") {
            query = magnet[magnet.index(after: questionMark)...]
        }
        let normalized = query.replacingOccurrences(of: "&amp;", with: "&")
        for pair in normalized.split(separator: "&", omittingEmptySubsequences: true) {
            guard let equals = pair.firstIndex(of: "="),
                  pair[..<equals].lowercased() == "dn" else { continue }
            // '+' → ' ' BEFORE percent-decoding, so an encoded "%2B" stays a '+'.
            let raw = pair[pair.index(after: equals)...].replacingOccurrences(of: "+", with: " ")
            let decoded = (raw.removingPercentEncoding ?? raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return decoded.isEmpty ? nil : decoded
        }
        return nil
    }

    // MARK: - Additions (B1)

    /// Route suggested by a magnet's display name, nil when it has none.
    /// Only a hint: YTS display names carry no extension (→ `.remux`), the
    /// players re-route on the REAL file name once the torrent is ready.
    static func route(forMagnet magnet: String) -> PlaybackRoute? {
        displayName(fromMagnet: magnet).map { route(forFileName: $0) }
    }

    /// True when the name carries a known video container extension.
    static func isVideoFileName(_ name: String) -> Bool {
        let ext = fileExtension(of: name)
        return remuxExtensions.contains(ext) || avPlayerExtensions.contains(ext) || vlcExtensions.contains(ext)
    }

    /// Companion files of a release that are certainly not the video.
    static let nonVideoExtensions: Set<String> = [
        "srt", "ass", "ssa", "sub", "idx", "vtt", "sup", "smi",          // subtitles
        "jpg", "jpeg", "png", "gif", "bmp", "webp", "tbn",              // artwork
        "txt", "nfo", "sfv", "md5", "url", "htm", "html", "pdf", "log", // text
        "torrent", "exe", "lnk",
    ]

    /// Index of the file to stream from a multi-file torrent.
    /// - `preferredIndex` (BEP 53 `so=` from the magnet, e.g. a Torrentio
    ///   season pack's episode) wins when it is in range and doesn't name an
    ///   obvious companion file (subtitles, artwork, text);
    /// - else, with `sizes`, the largest video file (largest file overall
    ///   when no name looks like a video);
    /// - else the first video file whose name doesn't look like a sample /
    ///   trailer, then the first video file, then 0.
    static func fileIndexToStream(names: [String], sizes: [Int64]? = nil, preferredIndex: Int?) -> Int {
        guard !names.isEmpty else { return 0 }
        if let preferred = preferredIndex, names.indices.contains(preferred),
           !nonVideoExtensions.contains(fileExtension(of: names[preferred])) {
            return preferred
        }
        let videoIndices = names.indices.filter { isVideoFileName(names[$0]) }
        if let sizes = sizes, sizes.count == names.count {
            let candidates = videoIndices.isEmpty ? Array(names.indices) : videoIndices
            // Strictly larger only: ties resolve to the first file.
            var best = candidates[0]
            for index in candidates.dropFirst() where sizes[index] > sizes[best] {
                best = index
            }
            return best
        }
        if let main = videoIndices.first(where: { !looksLikeExtra(names[$0]) }) {
            return main
        }
        return videoIndices.first ?? 0
    }

    /// Sample / trailer / bonus clips that ship next to the main video.
    static func looksLikeExtra(_ name: String) -> Bool {
        let tokens = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let extras: Set<String> = ["sample", "trailer", "teaser", "featurette", "extras", "bonus"]
        return tokens.contains(where: { extras.contains($0) })
    }

    /// The torrent's local HTTP endpoint made friendly to AVFoundation:
    /// PopcornTorrent reports `http://0.0.0.0:<port>/` — the host becomes
    /// `127.0.0.1` (a routable loopback address) and, when the URL has no
    /// path, the payload's file name is appended (the streamer serves its
    /// file on every path) so AVFoundation sees the container extension.
    static func playableLocalURL(_ url: URL, fileName: String? = nil) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if components.host == "0.0.0.0" { components.host = "127.0.0.1" }
        if let fileName = fileName, !fileName.isEmpty,
           components.path.isEmpty || components.path == "/" {
            // The setter percent-encodes whatever a path can't carry.
            components.path = "/" + fileName
        }
        return components.url ?? url
    }

    /// Human-readable reason for logs / UI when a container goes to VLC.
    static func vlcReason(forFileName name: String) -> String {
        let ext = fileExtension(of: name)
        return ext.isEmpty
            ? "Conteneur non pris en charge par AVPlayer"
            : "Conteneur .\(ext) non pris en charge par AVPlayer"
    }
}

/// Resume / watched-progress rules shared by the native players (pure, so
/// the harness can test them).
enum ResumePolicy {

    /// A saved progress at or beyond this restarts from the beginning (the
    /// title was finished).
    static let restartThreshold: Float = 0.95

    /// How far past the resume point playback must have gone this session
    /// to count as "watched past it" (≈ 14 s of a 2 h movie).
    static let watchedPastMargin: Float = 0.002

    /// 0…1 position to resume at for a saved `progress`; 0 = from the start.
    static func startPosition(forSavedProgress progress: Float) -> Float {
        progress > 0 && progress < restartThreshold ? progress : 0
    }

    /// The fraction to store when the player closes, or nil to keep the
    /// stored value untouched.
    ///
    /// The saved resume point (`resumePoint`, 0 = none) is never replaced by
    /// a SMALLER fraction unless the user chose to start over
    /// (`userRestarted`) or watched past it during this session
    /// (`highWater`, the furthest position reached) and then went back.
    /// So a resume that could not be honoured (playback started at 0) and a
    /// quick exit never destroy it, locally or on Trakt.
    static func progressToSave(current: Float, resumePoint: Float, highWater: Float, userRestarted: Bool) -> Float? {
        guard resumePoint > 0, !userRestarted else { return current }
        if current >= resumePoint { return current }
        if highWater > resumePoint + watchedPastMargin { return current }
        return nil
    }

    /// "1:02:03" (≥ 1 h) / "42:10" — a playback position for prompts
    /// (nearest second: a Float fraction × duration lands just below it).
    static func clockString(seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Text of the "resume at" choice: the exact clock time when the
    /// duration is known, else the percentage.
    static func resumeLabel(fraction: Float, durationSeconds: Double) -> String {
        if durationSeconds.isFinite, durationSeconds > 0, fraction.isFinite {
            return clockString(seconds: Double(fraction) * durationSeconds)
        }
        return fraction.isFinite ? "\(Int((fraction * 100).rounded())) %" : "0 %"
    }

    /// 0…1 position of `time` in `duration`, nil while either is unknown
    /// (NaN / ∞ — e.g. an EVENT playlist before its ENDLIST) or ≤ 0.
    static func fraction(time: Double, duration: Double) -> Float? {
        guard time.isFinite, duration.isFinite, duration > 0, time >= 0 else { return nil }
        return Float(min(time / duration, 1))
    }

    // MARK: Hand-off to VLC (native player → VLC fallback)

    /// A hand-off never continues past this point: VLC still plays the very
    /// end (and its exit then saves a finished progress) instead of being
    /// handed the last frame.
    static let handOffMaxFraction: Float = 0.995

    /// 0…1 position VLC continues at when a native player hands over after
    /// playback reached `reached`: that fraction, clamped to
    /// `handOffMaxFraction`. Unlike a SAVED resume point
    /// (`startPosition(forSavedProgress:)`, ≥ 0.95 = finished → start over),
    /// a hand-off in the end credits must not restart the movie at 0:00.
    static func handOffFraction(reached: Float) -> Float {
        guard reached.isFinite else { return 0 }
        return min(max(reached, 0), handOffMaxFraction)
    }

    /// Whether VLC may continue at the handed-over position without its own
    /// « Reprendre / Depuis le début » question: the user chose « Reprendre »
    /// in the native player (quick resume through VLC), or native playback
    /// had started (the user was watching). Otherwise nobody decided — e.g.
    /// a DTS-only MKV rejected before the native resume question — and VLC
    /// asks.
    static func handOffResumeDecided(userChoseQuickResume: Bool, playbackStarted: Bool) -> Bool {
        userChoseQuickResume || playbackStarted
    }

    /// Why a remux player hands over to VLC when the user's position lies
    /// in segments the remux deleted for good (a rewind past the native
    /// rewind window, or back into a span a far seek skipped): AVPlayer asked
    /// for a pruned segment, or the user moved the playhead there while a
    /// starvation recovery waited.
    static let rewindPastBufferReason = "Retour en arrière au-delà de la mémoire tampon native"

    /// Where VLC continues (player timeline, s) when AVPlayer requested the
    /// pruned segment starting at `prunedSegmentStart` while the playhead
    /// (`currentTime()`, which already reports a pending seek target) is at
    /// `playhead`: the earlier of the two, so nothing the user is about to
    /// watch is skipped — the playhead when it lies before that segment
    /// (« recommencer » in the kept segment 0 while AVPlayer prefetches the
    /// pruned segment 1), that segment's start for a scrub into it. An
    /// unknown playhead (nil, NaN, negative) gives the segment's start.
    static func handOffTime(prunedSegmentStart: Double, playhead: Double?) -> Double {
        guard let now = playhead, now.isFinite, now >= 0 else { return prunedSegmentStart }
        return min(now, prunedSegmentStart)
    }
}

/// The last position playback actually REACHED — what the native players
/// report as `played` to `RemuxPlayback.updatePlaybackPositions(played:wanted:)`
/// (pure — the harness tests it; sampled ~1 Hz by the players' stats
/// timers). The remux protects the segments around it from pruning.
///
/// After a seek past the remux frontier `currentTime()` already reports the
/// target while AVPlayer waits for the held segment
/// (`.waitingToPlayAtSpecifiedRate`): taking that for the played position
/// would let the region being watched and its unplayed lookahead be
/// deleted (the target is reported apart, as `wanted`). And the status
/// alone is not enough: `currentTime()` jumps to the target a few
/// milliseconds BEFORE `timeControlStatus` leaves `.playing` (measured on a
/// held HLS segment).
/// So a sample counts only when playback runs there — playing, item ready,
/// no starvation recovery — AND the time moved forward continuously from the
/// previous sample (whatever its state): by at most the wall time elapsed ×
/// `maxRate` + `slackSeconds`. A seek is a jump; the next sample, once
/// playing at the target, counts.
struct PlayedPositionTracker {
    /// Highest playback rate AVKit offers (2×).
    static let maxRate: Double = 2
    /// Timer / clock jitter tolerated on top of the elapsed wall time (s).
    static let slackSeconds: Double = 1

    /// Last position playback reached (player timeline, s); nil until
    /// playback has played somewhere.
    private(set) var lastPlayedTime: Double?
    private var previous: (time: Double, clock: TimeInterval)?

    init() {}

    /// One sample. `time`: the player's `currentTime()`; `clock`: a
    /// monotonic clock in seconds (`ProcessInfo.systemUptime`).
    mutating func note(time: Double, clock: TimeInterval, isPlaying: Bool, isItemReady: Bool, isRecovering: Bool) {
        let before = previous
        previous = time.isFinite && time >= 0 && clock.isFinite ? (time, clock) : nil
        guard isPlaying, isItemReady, !isRecovering, let last = before, let now = previous else { return }
        let advanced = now.time - last.time
        let elapsed = max(0, now.clock - last.clock)
        guard advanced >= 0, advanced <= elapsed * Self.maxRate + Self.slackSeconds else { return }
        lastPlayedTime = now.time
    }
}

/// When the native players retry after DOWNLOAD STARVATION (pure — the
/// harness tests it; `PlaybackStarvationRecovery` drives it).
enum StarvationPolicy {

    /// Remuxed media needed past the resume point before a new item is
    /// built (VOD playlist: the header gave the duration).
    static let remuxCushionSeconds: Double = 10
    /// Same for an EVENT playlist (header without Duration): AVPlayer keeps
    /// three target durations away from the end of a growing playlist, and
    /// an EVENT list's TARGETDURATION is 8 (its longest EXTINF rounded up, at
    /// least the 6 s target + 2): 3 × 8 = 24 s. A long-GOP list's tag grows
    /// (13 for G04N), yet an item pre-positioned 24 s before the remux
    /// frontier was measured to start at once (0.04–0.5 s).
    static let eventPlaylistCushionSeconds: Double = 24
    /// Playback past the previous resume point that counts as progress
    /// (resets the recovery attempt budget).
    static let progressMarginSeconds: Double = 5
    /// Direct (progressive MP4) path: share of the payload that must arrive
    /// after the failure before retrying…
    static let directProgressDelta: Float = 0.004
    /// …or, once this long has passed, any new data at all.
    static let directRetryDelay: TimeInterval = 15
    /// A rebuilt item must be ready (and positioned) within this — no
    /// extensions — else the recovery gives up: VLC at the resume time.
    static let rebuildReadyTimeout: TimeInterval = 30
    /// Remux stall cap: a recovery that has waited this long while the
    /// torrent kept downloading (`remuxStallProgressDelta`) but the remux
    /// frontier did not move gives up — VLC at the saved time (the swarm
    /// delivers other parts of the file, which VLC's byte-range reads make
    /// the torrent fetch at the playhead; the in-order remux can't).
    static let remuxStallCapSeconds: TimeInterval = 180
    /// Download growth (share of the payload) that makes a frozen remux
    /// frontier a stall rather than a dead swarm.
    static let remuxStallProgressDelta: Float = 0.01

    /// The payload is entirely downloaded. libtorrent's `totalProgress`
    /// reaches exactly 1.0 only when every wanted byte is there — at 0.999
    /// up to 0.1 % of the file (tens of MB on a 4K release) is still missing.
    static func isComplete(progress: Float) -> Bool {
        progress >= 1
    }

    /// Remux path: segments exist far enough past `resumeTime` (both on the
    /// player timeline: `frontierSeconds` = remuxed media, from the first
    /// segment's start), or the remux has finished.
    static func remuxDataReady(frontierSeconds: Double, finished: Bool, resumeTime: Double, durationKnown: Bool) -> Bool {
        if finished { return true }
        guard frontierSeconds.isFinite, resumeTime.isFinite else { return false }
        return frontierSeconds >= resumeTime + (durationKnown ? remuxCushionSeconds : eventPlaylistCushionSeconds)
    }

    /// Direct path: the torrent completed, grew by `directProgressDelta`
    /// since the failure, or grew at all after `directRetryDelay`.
    static func directDataReady(progress: Float, progressAtFailure: Float, waited: TimeInterval) -> Bool {
        if isComplete(progress: progress) { return true }
        if progress >= progressAtFailure + directProgressDelta { return true }
        return waited >= directRetryDelay && progress > progressAtFailure
    }

    /// Direct path, knowing where the item starved (`failurePosition`) and
    /// where the recovery now resumes (`resumeTime`, the user's target after
    /// a seek during the wait): a target more than
    /// `userSeekThresholdSeconds` before the failure position was played
    /// already — its bytes are on disk — so it is ready at once; any other
    /// target waits for more data (`directDataReady(progress:…)`).
    static func directDataReady(resumeTime: Double, failurePosition: Double, progress: Float,
                                progressAtFailure: Float, waited: TimeInterval) -> Bool {
        if resumeTime.isFinite, failurePosition.isFinite, resumeTime >= 0,
           resumeTime < failurePosition - userSeekThresholdSeconds {
            return true
        }
        return directDataReady(progress: progress, progressAtFailure: progressAtFailure, waited: waited)
    }

    /// Smallest move of the player's time between two polls of a waiting
    /// recovery that counts as a user seek: the failed item never plays nor
    /// requests anything again, so its time only moves when the user moves
    /// it (AVKit's transport bar stays usable under the buffering overlay).
    static let userSeekThresholdSeconds: Double = 1

    /// The user's new target when the player's time went from `lastObserved`
    /// (the previous poll) to `observed` by more than
    /// `userSeekThresholdSeconds`; nil when it didn't move (or a time is
    /// unknown: NaN, negative, no previous poll).
    static func userSeekTarget(observed: Double, lastObserved: Double?) -> Double? {
        guard let last = lastObserved, last.isFinite, observed.isFinite, observed >= 0 else { return nil }
        return abs(observed - last) > userSeekThresholdSeconds ? observed : nil
    }

    /// Playback got clearly past the previous resume point (nil = none yet).
    static func madeProgress(position: Double, since lastResume: Double?) -> Bool {
        guard let last = lastResume, position.isFinite, last.isFinite else { return false }
        return position > last + progressMarginSeconds
    }

    /// Where to resume after a failure at `position`: a rebuilt item that
    /// failed again just behind its resume point (its seek may land up to
    /// 2 s early, or it never started) resumes at that point again instead
    /// of drifting backwards attempt after attempt; a real jump back (more
    /// than the margin) is kept.
    static func resumeTime(position: Double, lastResume: Double?) -> Double {
        guard let last = lastResume, last.isFinite, position.isFinite else { return position }
        return position < last && last - position <= progressMarginSeconds ? last : position
    }
}

/// The remux stall cap of a waiting starvation recovery (pure — polled
/// ~1 Hz by `PlaybackStarvationRecovery`). Gives up once the remux frontier
/// has not moved for `cap` seconds while the torrent's `totalProgress` grew
/// by at least `progressDelta` over that same time. With no download
/// activity there is no cap: a dead swarm keeps the spinner (the user can
/// close; VLC would be just as stuck without data). Any frontier movement
/// restarts the window.
struct RemuxStallWatch {
    let cap: TimeInterval
    let progressDelta: Float
    private var frontier: Double?
    private var progressAtMove: Float = 0
    private var movedAt: TimeInterval = 0

    init(cap: TimeInterval = StarvationPolicy.remuxStallCapSeconds,
         progressDelta: Float = StarvationPolicy.remuxStallProgressDelta) {
        self.cap = cap
        self.progressDelta = progressDelta
    }

    /// - Parameters:
    ///   - frontierSeconds: remuxed media (player timeline, s).
    ///   - torrentProgress: the torrent's `totalProgress` (0…1).
    ///   - waited: seconds since the recovery started waiting.
    /// - Returns: true when the stall cap is reached (hand over to VLC).
    mutating func shouldGiveUp(frontierSeconds: Double, torrentProgress: Float, waited: TimeInterval) -> Bool {
        let progress = torrentProgress.isFinite ? torrentProgress : 0
        guard frontierSeconds.isFinite, waited.isFinite else { return false }
        if let last = frontier, frontierSeconds <= last + 0.001 {
            return waited - movedAt >= cap && progress - progressAtMove >= progressDelta
        }
        // First sample, or the frontier moved: the window restarts here.
        frontier = frontierSeconds
        progressAtMove = progress
        movedAt = waited
        return false
    }
}

/// A user's seek target the native REMUX path can't reach soon (pure — the
/// harness tests it). Sampled ~1 Hz by the remux owners — at every tick of
/// their stats timer, with the held seek target or none — and by
/// `PlaybackStarvationRecovery` while it waits for data for a user target
/// (its watch starts from the owners' `downloadHistory`).
///
/// PopcornTorrent downloads IN ORDER — sequential mode and a piece-deadline
/// window that follows the pieces it finished — and the remux reads the file
/// itself, so nothing moves that window to a far target: the remux frontier
/// gets there at the download's pace (a scrub 30 min ahead in a movie
/// downloading at 1.2× its bitrate: ~22 min of spinner). VLC's byte-range
/// reads make PopcornTorrent fetch the target's pieces first. So a target the
/// frontier can't reach within about AVPlayer's own hold of a seek (`bound`:
/// AVPlayer fails a held seek after ~37–42 s) at its CURRENT pace — the
/// download's, or the remux pump's when the pump is what bounds the frontier —
/// goes to VLC AT that target; one it reaches sooner stays native (HDR / Dolby
/// Vision / Atmos).
///
/// The gap alone doesn't tell: over data already on disk the remux pumps
/// toward the target many times faster than real time (F3 x23: 2400 s of a
/// complete 1 h file in about a second). So the watch MEASURES the frontier's
/// pace, BETWEEN its moves: the frontier moves in whole segment steps (6 s for
/// 2 s GOPs, ~10.5 s for x264's keyint 250), so the pace is the advance A from
/// the first move of a span to the latest over the time E between them (a
/// window holding a single step would read one segment per window whatever the
/// pace). The span is the latest run of moves with no freeze (a gap longer
/// than the window and `freezeFactor` × a neighbouring gap), and the frontier
/// must still be moving (its latest move no older than `staleFactor` × the
/// span's mean gap, half a window at least): a frozen frontier is the stall
/// cap's case when the download grows elsewhere (`RemuxStallWatch`), a dead
/// swarm's otherwise — both unchanged.
///
/// A pump-ahead over bytes already on disk is told by its SHAPE, at any
/// speed: a burst (the pump writes for up to ~0.8 s per tick toward a far
/// target), then a sharp deceleration once the frontier reaches the download's
/// edge. The span starts after the latest interval that moved the frontier
/// more than `decelerationFactor` × the fastest pace the moves after it allow
/// (two steps at least), when the frontier also outran the download up to
/// there: it advanced more than `pumpProgressFactor` × what the download's
/// progress over that time, plus one progress step, is worth at the
/// frontier-per-progress rate of the moves after it (two download changes at
/// least; with the progress unknown, the deceleration alone). A dip of the
/// download slows the frontier and the progress together, so it is not cut as
/// a pump-ahead; a steady frontier — a fast download, or a pump over bytes on
/// disk — is measured at whatever pace it shows.
///
/// The download must be running (`downloadProgress`, when given): below 1 (a
/// complete payload never decides), its latest run of changes (no freeze)
/// holding two changes or more, the latest no older than `staleFactor` × the
/// interval before it (half a window at least); and the span starts no
/// earlier than one interval before that run — moves before it are the remux
/// writing bytes already on disk while the swarm stalled (F3 x18d: a far seek
/// while the swarm stalls, the swarm back seconds later). Per-piece
/// publication passes: a streamer that sets `totalProgress` only when a
/// piece finishes (7–15 s apart for 16 MiB pieces near the bitrate — the
/// CocoaPods PopcornTorrent the iOS / tvOS apps used), the SPM one of every
/// app every 0.5 s. The cadence is per piece when the latest interval is
/// `coarseProgressSeconds` or more — unless the one before it is shorter (a
/// fine cadence that paused stays fine).
///
/// A pause or a slowdown of the download does not decide alone. The watch
/// keeps the download's changes of the last `downloadMemorySeconds` across
/// measurements (`reset()` keeps them: the owners feed it at every tick, and
/// the recovery's watch starts from the owners' —
/// `init(window:bound:downloadHistory:)`), and reads the download's LAG
/// behind its earlier rate: the clock less the time its progress would have
/// taken at that rate. That rate is read over the kept changes up to the
/// start of the time judged (and the measurement's first sample), over
/// `minRateSeconds` at least, as a lower bound — their progress over their
/// time plus the longest interval among them. The lag stays put while the
/// download keeps that rate and grows by the time a pause or a slowdown
/// loses; it is read at a change, and between two changes linearly. The
/// time it grew over the span — or since the reference below —, at most
/// `maxLostSeconds` and at most the time the rate was read over (a watch
/// that just started, with a first change seconds after its first sample,
/// vouches for no more), comes out of the time the paces divide by and out
/// of the elapsed part of the reach test. Nothing restarts or blocks a
/// decision, and jitter or recurring fast / slow stretches are averaged over
/// the span like the frontier's own moves. Without such a rate (a watch
/// whose first change is too recent) nothing is credited.
///
/// What the credit costs (measured, accepted): it is relative to the earlier
/// rate, and it shortens the paces' divisor, so the reach estimate falls by
/// about the lost time × (1 + the distance left / the span's advance) —
/// several times `maxLostSeconds` early in a span.
///  - A pause followed by a download FASTER than before it is only partly
///    credited (the faster pace repays the lag): a target the frontier
///    reaches 35–40 s after a short stall at the seek can go to VLC (with
///    natural rate noise ~1 point more often at most; up to ~50 % when a
///    2–6 s stall at the seek is followed by twice the pace).
///  - A LASTING slowdown within the kept changes is credited like a pause,
///    up to the cap in each watch (the recovery's starts from the same
///    changes), until the slower pace fills them: a far decision comes
///    ~13–18 s later, and a target 1.5–2.5 bounds away may stay native
///    until the frontier reaches it (~70–118 s after the seek, HDR / Atmos
///    kept). A return burst of ~5× or more, when a swarm that stalled at
///    the seek comes back, does the same.
///
/// Two paces come from the span: the central A / E (the logged estimate) and
/// an upper bound (A + credit) / (E − `moveQuantizationSeconds` − lost time):
/// observed move times are quantized by the 1 Hz timers (the owners' tick
/// after the remux pump's), and a frontier that only jumps when a piece
/// completes moves up to a piece later than the bytes allow — the bytes on
/// disk then lie less than one piece past it —, so, per piece, one piece's
/// worth of media (the largest progress step at the span's
/// frontier-per-progress rate, at most the smallest step seen) is credited,
/// unless the progress shows the file growing block by block (a move seen
/// between two piece completions). A download running at a fine cadence
/// since a reference sample — the measurement's start, or the tick before
/// the download's run began — bounds the pace too: the frontier's advance
/// since then over that time, less `referenceQuantizationSeconds` (the
/// frontier at the reference lags the bytes on disk, so the advance only
/// over-counts) and less the time the download lost since. The target goes
/// to VLC when, at the central pace, the frontier needs more than `bound`
/// from now AND, at the upper pace, it could not have reached the target
/// within `bound` of the span's first move (or the reference), the time the
/// download lost meanwhile left out.
///
/// Timings (the round-13 simulator, 400 runs per cell; the owners' watch with
/// its samples from before the seek, then the recovery's from AVPlayer's
/// failure): a target 90 s of download past the edge goes to VLC at the
/// second or third frontier step with a fine cadence (x37: ~11 s at most; the
/// Mac with per-second rate noise: p95 10–21 s), p95 within ~19 s with pieces
/// 0.6–1.3 s apart, ~9–35 s with pieces 1.6–3 s apart (~16 s typically;
/// piece-gated or very jittery pieces the longest), and in two or three piece
/// times with pieces 5–15 s apart (x37 / R8-#7: ~17–20 s with pieces 5–7 s
/// apart, ~24 s at 10 s, ~35 s at 15 s); after a pump-ahead, up to ~17 s at a
/// fine cadence. A download alternating fast and slow stretches is judged at
/// its average pace (p95 ~15 s; up to ~37 s with stretches of 10–15 s). A
/// target the frontier reaches within the bound of the seek — or of the end
/// of a stall, a pause or a dip, the download then no faster than before
/// it — stays native: at a steady pace at most 0.5 % of such cases go to VLC
/// in the model (~2.5 % with a piece-gated frontier whose pieces come ~1.5 s
/// apart, 6 s segments at 3×), up to ~4–5 % with very jittery
/// pieces of a piece-gated frontier or a slowdown between pieces 7 s apart,
/// ~3 % with a per-second rate noise of 0.5 and ~6.5 % with fast / slow
/// stretches of 10–15 s. Never by the gap alone, mid-drag, on a frozen
/// frontier, on a complete payload or once the remux has finished.
///
/// `shouldHandOff(target:frontierSeconds:downloadProgress:remuxFinished:now:)`:
///  - the download's changes are kept (`downloadMemorySeconds`), whatever
///    the rest;
///  - no target, a frontier already at the target or a finished remux:
///    nothing is measured (reset);
///  - a new target — none measured yet, or it moved by more than
///    `StarvationPolicy.userSeekThresholdSeconds` (a scrub that moves every
///    tick never decides): a new measurement starts at this sample;
///  - else the sample is recorded (a frontier move, a download change) and,
///    once the conditions above hold, the target goes to VLC when the
///    frontier needs more than `bound` seconds to reach it.
struct FarTargetWatch {
    /// The shortest freeze (s): a longer gap between frontier moves (or
    /// download changes), also `freezeFactor` × a neighbouring gap, ends
    /// their run; half of it is the least staleness tolerated.
    static let windowSeconds: TimeInterval = 6
    /// The longest the frontier may still need to reach the target for it to
    /// stay native (s): about AVPlayer's own hold of a seek.
    static let boundSeconds: TimeInterval = 45
    /// The period of the owners' tick, of the recovery's poll and of the
    /// remux pump's timer (s).
    static let tickSeconds: TimeInterval = 1
    /// How much shorter (s) the time between two observed frontier moves may
    /// be than between the segment crossings they show: each move is seen at
    /// the owners' tick after the remux pump's timer, and when the two timers
    /// are in phase (within the pump's 100 ms leeway) one move can be seen a
    /// tick later than the other (one tick is not enough there: measured).
    static let moveQuantizationSeconds: TimeInterval = 1.5
    /// The same between the reference sample and an observed move (s): the
    /// move's own delay, and the download's restart within the tick before
    /// its first change.
    static let referenceQuantizationSeconds: TimeInterval = 2.5
    /// A pump-ahead's end: an interval that moved the frontier more than this
    /// many times the fastest pace the moves after it allow…
    static let decelerationFactor: Double = 1.5
    /// …after the frontier advanced more than this many times what the
    /// download brought meanwhile (its progress, plus one progress step, at
    /// the frontier-per-progress rate of the moves after the interval), when
    /// the progress is known.
    static let pumpProgressFactor: Double = 2
    /// A gap this many times a neighbouring one (and longer than the window)
    /// is a freeze.
    static let freezeFactor: Double = 2.5
    /// The latest frontier move (download change) older than this many times
    /// the span's mean gap (the latest interval), and than half a window: it
    /// stopped.
    static let staleFactor: Double = 1.5
    /// Download changes this far apart (s) or more come per piece; closer
    /// ones are a fine cadence (the streamer's 0.5 s refresh, seen at the 1 Hz
    /// tick: about 1 s apart). A cadence of 2 s is per piece: a piece-gated
    /// frontier there needs the piece credit. The cost, with ~10 s segments:
    /// pieces 1.6–2.6 s apart leave a target 1.5–1.7 bounds away native about
    /// twice as often as a 2.5 s threshold would (~24 % vs ~12 % in the
    /// model) — a threshold that sends near targets to VLC needlessly (up to
    /// ~10 % with pieces 1.5–2.5 s apart).
    static let coarseProgressSeconds: TimeInterval = 1.6
    /// The longest a piece-gated move lags behind its piece's download change
    /// (s): the remux pump's timer, then the owners' tick.
    static let pieceLagSeconds: TimeInterval = 1.5
    /// Moves and download changes older than this (s) are forgotten.
    static let historySeconds: TimeInterval = 90
    /// The download's changes kept across measurements (s): its rate before a
    /// span (two piece intervals of 15 s at least).
    static let downloadMemorySeconds: TimeInterval = 40
    /// The least time (s) the download's earlier rate is read over: a watch
    /// with less history before the span reads it over its first changes.
    static let minRateSeconds: TimeInterval = 4
    /// The most download time (s) a pause or a slowdown is credited, in each
    /// watch. A slower pace that lasts is credited like a pause until it
    /// fills `downloadMemorySeconds`; the cap bounds the time credited, not
    /// how far the reach estimate moves (the costs in the type doc).
    static let maxLostSeconds: TimeInterval = 8
    /// Why: the VLC hand-off's reason (logs, stats line).
    static let reason = "Position choisie trop loin devant le téléchargement : VLC la lit directement"

    let window: TimeInterval
    let bound: TimeInterval
    /// Seconds the frontier needs from now to reach the target at the
    /// central pace of the latest sample (logs); nil while none is measured.
    private(set) var estimatedSecondsToTarget: Double?
    /// The target being measured, as when its measurement started.
    private var target: Double?
    /// The measurement's first sample (monotonic clock, frontier).
    private var started: (time: TimeInterval, frontier: Double) = (0, 0)
    /// The previous sample's frontier and download progress.
    private var lastFrontier = 0.0
    private var lastProgress: Float?
    /// The samples at which the frontier grew (monotonic clock, frontier,
    /// download progress then), oldest first, and its smallest step in this
    /// measurement.
    private var moves: [(time: TimeInterval, frontier: Double, progress: Double)] = []
    private var smallestStep = Double.infinity
    /// The samples at which the download progress grew (clock, progress),
    /// oldest first, and its largest step in this measurement.
    private var changes: [(time: TimeInterval, progress: Float)] = []
    private var largestChange: Float = 0
    /// The download's changes (clock, progress), the last
    /// `downloadMemorySeconds`, kept across measurements, and its latest value.
    private var download: [(time: TimeInterval, progress: Float)] = []
    private var downloadLatest: Float?
    /// The download before the measurement, as at its start: the kept changes,
    /// then its first sample when that shows progress they don't.
    private var cadenceBefore: [(time: TimeInterval, progress: Float)] = []

    /// - Parameter downloadHistory: the download's recent changes another
    ///   watch kept for the same torrent (its `downloadHistory`), oldest
    ///   first: the new watch starts knowing the download's pace.
    init(window: TimeInterval = FarTargetWatch.windowSeconds, bound: TimeInterval = FarTargetWatch.boundSeconds,
         downloadHistory: [(time: TimeInterval, progress: Float)] = []) {
        self.window = window
        self.bound = bound
        for change in downloadHistory where change.time.isFinite && change.progress.isFinite {
            guard change.progress > downloadLatest ?? -.infinity,
                  change.time > download.last?.time ?? -.infinity else { continue }
            download.append(change)
            downloadLatest = change.progress
        }
    }

    /// The download's changes the watch keeps (clock, progress; the last
    /// `downloadMemorySeconds`, oldest first) — what a new watch for the same
    /// torrent starts from (`init(window:bound:downloadHistory:)`).
    var downloadHistory: [(time: TimeInterval, progress: Float)] { download }

    /// Forgets the measurement (not the download's recent changes).
    mutating func reset() {
        target = nil
        lastProgress = nil
        moves = []
        smallestStep = .infinity
        changes = []
        largestChange = 0
        cadenceBefore = []
        estimatedSecondsToTarget = nil
    }

    /// One sample (~1 Hz).
    /// - Parameters:
    ///   - target: the user's target (player timeline, s); nil = none.
    ///   - frontierSeconds: the remux frontier (remuxed media, player
    ///     timeline, s).
    ///   - downloadProgress: the torrent's `totalProgress` (0…1); nil =
    ///     unknown (no download condition).
    ///   - remuxFinished: every segment was written (the target can't be
    ///     download-bound).
    ///   - now: a monotonic clock in seconds (`ProcessInfo.systemUptime`).
    /// - Returns: true when the target goes to VLC now.
    mutating func shouldHandOff(target wanted: Double?, frontierSeconds: Double, downloadProgress: Float? = nil,
                                remuxFinished: Bool, now: TimeInterval) -> Bool {
        let progress = downloadProgress.flatMap { $0.isFinite ? $0 : nil }
        if let progress = progress, now.isFinite {
            if let latest = downloadLatest, progress > latest { download.append((now, progress)) }
            downloadLatest = progress
            download.removeAll { now - $0.time > Self.downloadMemorySeconds }
        }
        guard let wanted = wanted, wanted.isFinite, wanted >= 0, frontierSeconds.isFinite, now.isFinite,
              !remuxFinished, frontierSeconds < wanted else {
            reset()
            return false
        }
        guard let measured = target, abs(wanted - measured) <= StarvationPolicy.userSeekThresholdSeconds else {
            reset()
            target = wanted
            started = (now, frontierSeconds)
            cadenceBefore = download.filter { $0.time < now - 0.001 }
            if let progress = progress, progress > cadenceBefore.last?.progress ?? -.infinity {
                cadenceBefore.append((now, progress))
            }
            lastFrontier = frontierSeconds
            lastProgress = progress
            return false
        }
        if let progress = progress {
            if let last = lastProgress, progress > last {
                changes.append((now, progress))
                largestChange = max(largestChange, progress - last)
            }
            lastProgress = progress
        }
        if frontierSeconds > lastFrontier + 0.001 {
            smallestStep = min(smallestStep, frontierSeconds - lastFrontier)
            moves.append((now, frontierSeconds, Double(lastProgress ?? 0)))
        }
        lastFrontier = frontierSeconds
        moves.removeAll { now - $0.time > Self.historySeconds }
        changes.removeAll { now - $0.time > Self.historySeconds }
        estimatedSecondsToTarget = nil
        // The download is running (two changes in its latest run, the latest
        // still due); moves before that run come from bytes already on disk.
        // At a fine cadence it has been running since `reference` (the
        // sample, and the first change of the run).
        var earliest = -TimeInterval.infinity
        var perPiece = progress == nil
        var reference: (time: TimeInterval, run: TimeInterval)?
        if let progress = progress {
            let run = Self.runStart(changes.map { $0.time }, window: window)
            let last = changes.count - 1
            guard progress < 1, run < last else { return false }
            let interval = changes[last].time - changes[last - 1].time
            guard now - changes[last].time <= max(window / 2, Self.staleFactor * interval) else { return false }
            earliest = changes[run].time - (changes[run + 1].time - changes[run].time)
            // A fine cadence whose latest interval is a pause stays fine.
            let pausedFine = last >= 2 && changes[last - 1].time - changes[last - 2].time < Self.coarseProgressSeconds
            perPiece = interval >= Self.coarseProgressSeconds && !pausedFine
            if !perPiece {
                reference = run == 0 && changes[0].time - started.time < Self.coarseProgressSeconds
                    ? (started.time, started.time) : (changes[run].time - Self.tickSeconds, changes[run].time)
            }
        }
        // The span: the latest run of moves, while the download runs, from
        // the end of a pump-ahead.
        guard let latest = moves.last else { return false }
        var first = Self.runStart(moves.map { $0.time }, window: window)
        while first < moves.count - 1, moves[first].time < earliest { first += 1 }
        var cut = moves.count - 4
        while cut >= first {
            if pumpAheadEnds(after: cut, from: first, progressKnown: progress != nil) { first = cut + 1; break }
            cut -= 1
        }
        var central = Double.infinity, upper = Double.infinity
        var origin = latest.time, originRun = latest.time
        let steps = moves.count - 1 - first
        if steps >= 1 {
            let elapsed = latest.time - moves[first].time
            let advanced = latest.frontier - moves[first].frontier
            // A frontier that stopped (or receded) decides nothing.
            guard advanced > 0.001,
                  now - latest.time <= max(window / 2, Self.staleFactor * elapsed / Double(steps)) else { return false }
            // A frontier that may only jump when a piece completes lags the
            // bytes on disk by up to a piece: credit one piece's worth of
            // media, unless the file is seen growing block by block (a move
            // of the span that came between two piece completions).
            var credit = 0.0
            if perPiece {
                let lag = Self.pieceLagSeconds
                let blockByBlock = progress != nil && moves[first...].contains { move in
                    changes.contains { $0.time < move.time - lag }
                        && !changes.contains { $0.time <= move.time && $0.time >= move.time - lag }
                }
                if !blockByBlock {
                    let spanProgress = latest.progress - moves[first].progress
                    credit = progress != nil && spanProgress > 0
                        ? min(smallestStep, Double(largestChange) * advanced / spanProgress) : smallestStep
                }
            }
            let time = elapsed - Self.moveQuantizationSeconds - lostTime(from: moves[first].time, to: latest.time)
            central = advanced / elapsed
            upper = time > 0 ? (advanced + credit) / time : .infinity
            origin = moves[first].time
            originRun = origin
        }
        // A fine-cadence download since the reference bounds the pace too.
        if let reference = reference, latest.time - reference.time > Self.referenceQuantizationSeconds,
           now - latest.time <= max(window / 2, Self.staleFactor * (latest.time - reference.time)) {
            let atReference = moves.last { $0.time <= reference.time }?.frontier ?? started.frontier
            if latest.frontier > atReference + 0.001 {
                let advance = latest.frontier - atReference
                let time = latest.time - reference.time - Self.referenceQuantizationSeconds
                central = min(central, advance / time)
                let running = time - lostTime(from: reference.run, to: latest.time)
                if running > 0 { upper = min(upper, advance / running) }
                if reference.time < origin { (origin, originRun) = reference }
            }
        }
        guard upper.isFinite else { return false }
        let remaining = wanted - frontierSeconds
        let eta = remaining / central - (now - latest.time)
        estimatedSecondsToTarget = eta
        let running = latest.time - origin - lostTime(from: originRun, to: latest.time)
        return eta > bound && running + remaining / upper > bound
    }

    /// The download time lost from `start` to `end` (s): how much the
    /// download's lag behind its earlier rate grew — the lag at a change is
    /// its clock less the time its progress would have taken at that rate,
    /// read between the changes around a time linearly (after the latest
    /// one: as there). The rate: the kept changes up to `start` (over
    /// `minRateSeconds` at least) — their progress over their time plus the
    /// longest interval among them. Within [0, `maxLostSeconds`], and no more
    /// than that time (a rate read over a few seconds vouches for no more);
    /// 0 without such a rate.
    private func lostTime(from start: TimeInterval, to end: TimeInterval) -> TimeInterval {
        let history = cadenceBefore + changes
        guard let first = history.first,
              let last = history.lastIndex(where: { $0.time <= max(start, first.time + Self.minRateSeconds) + 0.001 }),
              last >= 1 else { return 0 }
        let longest = (1...last).map { history[$0].time - history[$0 - 1].time }.max() ?? 0
        let measured = history[last].time - first.time + longest
        let rate = Double(history[last].progress - first.progress) / measured
        guard rate > 0 else { return 0 }
        func changeLag(_ i: Int) -> Double { history[i].time - Double(history[i].progress - first.progress) / rate }
        func lag(at time: TimeInterval) -> Double {
            guard let k = history.lastIndex(where: { $0.time <= time + 0.001 }) else { return changeLag(0) }
            guard k + 1 < history.count else { return changeLag(k) }
            let share = (time - history[k].time) / (history[k + 1].time - history[k].time)
            return changeLag(k) + (changeLag(k + 1) - changeLag(k)) * share
        }
        return min(max(0, lag(at: end) - lag(at: start)), Self.maxLostSeconds, measured)
    }

    /// A pump-ahead over bytes already on disk ends at move `cut + 1`: the
    /// interval before it moved the frontier `decelerationFactor` × faster
    /// than the moves after it (two steps at least) allow, and — the
    /// download's progress known — the frontier had advanced since move
    /// `first` more than `pumpProgressFactor` × what the download brought
    /// meanwhile (plus one progress step), at the frontier-per-progress rate
    /// of the moves after it (two download changes at least).
    private func pumpAheadEnds(after cut: Int, from first: Int, progressKnown: Bool) -> Bool {
        let latest = moves[moves.count - 1], end = moves[cut + 1]
        let pace = (end.frontier - moves[cut].frontier) / (end.time - moves[cut].time)
        let after = latest.frontier - end.frontier, afterTime = latest.time - end.time
        guard afterTime > Self.moveQuantizationSeconds,
              pace > Self.decelerationFactor * after / (afterTime - Self.moveQuantizationSeconds) else { return false }
        guard progressKnown else { return true }
        let afterProgress = latest.progress - end.progress
        guard afterProgress > 0, changes.filter({ $0.time > end.time && $0.time <= latest.time }).count >= 2 else {
            return false
        }
        let before = end.frontier - moves[first].frontier
        let downloaded = end.progress - moves[first].progress + Double(largestChange)
        return before > Self.pumpProgressFactor * (after / afterProgress) * downloaded
    }

    /// Index of the first entry of the latest run of `times` (ascending)
    /// with no freeze: a gap longer than `window` and `freezeFactor` × a
    /// neighbouring gap starts a new run at the entry that ends it.
    private static func runStart(_ times: [TimeInterval], window: TimeInterval) -> Int {
        var start = times.count - 1
        while start >= 1 {
            let gap = times[start] - times[start - 1]
            var neighbour = TimeInterval.infinity
            if start >= 2 { neighbour = times[start - 1] - times[start - 2] }
            if start + 1 < times.count { neighbour = min(neighbour, times[start + 1] - times[start]) }
            if neighbour.isFinite, gap > max(window, freezeFactor * neighbour) { break }
            start -= 1
        }
        return max(start, 0)
    }
}

/// Safety net for a native REMUX item stuck on complete data (pure — the
/// harness tests it; sampled ~1 Hz by the remux owners' stats timers).
///
/// Once the remux has finished, every byte of the presentation is local: a
/// ready item the user wants playing (`rate != 0`) whose time has not moved
/// for `stuckSeconds` will not recover by waiting. AVPlayer can sit in
/// `.waitingToPlayAtSpecifiedRate` there for good without posting a failure
/// — measured (F3 x20) on an item attached before the remux finished, after
/// subtitles on → off: a VOD item frozen 10 ms before its end, an EVENT item
/// whose seek into the last segment never completes (an item AVPlayer
/// started live: `LiveBornItemWatch` now replaces it once the remux has
/// finished, and this net stays its backstop). Nothing else reacts
/// (`AVPlayerItemFailureObserver` ignores stalls, no starvation recovery
/// runs), so the owners act on `decide(at:endZoneStart:)`:
///  - `.naturalEnd`: the position lies in the end zone — the last
///    `naturalEndWindowSeconds` of the presentation, or its last segment
///    (`endZoneStart`): what AVPlayer does at an item's end — pause;
///  - `.rebuild`: anywhere else — a fresh item at that position
///    (`PlaybackStarvationRecovery.rebuildNow`), at most
///    `maxRebuildsPerPosition` times for one position (`samePositionSeconds`);
///  - `.fallback`: stuck there once more — VLC at that position (`reason`).
///
/// A sample counts only when the owner says it `isEligible` (remux route,
/// remux finished, no starvation recovery, no VLC hand-off, app active, no
/// AirPlay, no Picture in Picture), the item is ready and the user wants
/// playback. Any other sample, a time that moved (by more than
/// `frozenToleranceSeconds`) or more than `maxSampleGapSeconds` between two
/// samples (timers suspended) restarts the observation. So start-up
/// buffering (remux not finished, item not ready), a user pause (rate 0), a
/// seek that completes (the time moves) and backgrounding never fire it.
struct StuckPlaybackWatch {
    /// A time frozen this long (while eligible) is stuck.
    static let stuckSeconds: TimeInterval = 6
    /// Timer jitter tolerated on that duration: the sample taken 6 ticks
    /// after the first frozen one counts even when the 1 Hz timer fired a
    /// few milliseconds early (else the decision slips a whole tick).
    static let clockJitterSeconds: TimeInterval = 0.25
    /// End zone: the last second of the presentation (or its last segment).
    static let naturalEndWindowSeconds: Double = 1
    /// Rebuilds for one position before VLC takes over there.
    static let maxRebuildsPerPosition = 2
    /// Stuck positions this close count as the same position.
    static let samePositionSeconds: Double = StarvationPolicy.progressMarginSeconds
    /// A larger gap between two samples restarts the observation.
    static let maxSampleGapSeconds: TimeInterval = 3
    /// A time that moved less than this hasn't moved (AVPlayer reports the
    /// very same time while stuck; 0.5× playback moves 0.5 s per sample).
    static let frozenToleranceSeconds: Double = 0.1
    /// Why: the rebuild's log line, the VLC hand-off reason.
    static let reason = "Lecture native bloquée sur des données complètes"

    enum Action: Equatable {
        case naturalEnd
        case rebuild
        case fallback
    }

    /// Where the time froze, and since when (sample clock).
    private var frozen: (time: Double, since: TimeInterval)?
    private var lastClock: TimeInterval?
    private var rebuildPosition: Double?
    /// Rebuilds decided for the current stuck position (`decide`).
    private(set) var rebuildsAtPosition = 0

    init() {}

    /// One sample (~1 Hz). `time`: the player's `currentTime()` (a pending
    /// seek target included); `clock`: a monotonic clock in seconds
    /// (`ProcessInfo.systemUptime`); `wantsPlayback`: `rate != 0`.
    /// - Returns: the stuck position once the time has stayed frozen for
    ///   `stuckSeconds` of eligible samples (± `clockJitterSeconds`; the
    ///   observation then restarts), else nil.
    mutating func note(time: Double, clock: TimeInterval, wantsPlayback: Bool, isItemReady: Bool,
                       isEligible: Bool) -> Double? {
        let previousClock = lastClock
        lastClock = clock.isFinite ? clock : nil
        guard isEligible, wantsPlayback, isItemReady, time.isFinite, time >= 0, clock.isFinite else {
            frozen = nil
            return nil
        }
        guard let anchor = frozen, let previous = previousClock, clock - previous <= Self.maxSampleGapSeconds,
              abs(time - anchor.time) <= Self.frozenToleranceSeconds else {
            frozen = (time, clock)
            return nil
        }
        guard clock - anchor.since >= Self.stuckSeconds - Self.clockJitterSeconds else { return nil }
        frozen = nil
        return time
    }

    /// What to do about an item stuck at `time` (`note`'s result).
    /// `endZoneStart`: where the natural-end zone starts (`endZoneStart(…)`),
    /// nil when unknown. Counts the rebuilds per position: the third time at
    /// the same position (± `samePositionSeconds`) is `.fallback`.
    mutating func decide(at time: Double, endZoneStart: Double?) -> Action {
        if let start = endZoneStart, start.isFinite, time >= start { return .naturalEnd }
        if let position = rebuildPosition, abs(time - position) <= Self.samePositionSeconds {
            guard rebuildsAtPosition < Self.maxRebuildsPerPosition else { return .fallback }
            rebuildsAtPosition += 1
        } else {
            rebuildPosition = time
            rebuildsAtPosition = 1
        }
        return .rebuild
    }

    /// Start of the natural-end zone (player timeline, s): the earlier of
    /// `naturalEndWindowSeconds` before the end and the start of the last
    /// segment. `segmentDurations` is the EXTINF list AVPlayer plays — the
    /// owners pass `playerTimelineDurations() ?? segmentDurations()`: a VOD
    /// session's frozen list (estimated entries included), an EVENT
    /// session's real durations —, so the zone lies on AVPlayer's timeline,
    /// not the remux's (an estimated entry starts within one keyframe
    /// interval of its real segment — within half a slot once the target was
    /// raised). The end is the later of that list's sum and the item's own
    /// `itemDuration` (a VOD playlist's announced length); the last segment
    /// is that list's last entry (often a short tail unit). nil when both are
    /// unknown.
    static func endZoneStart(segmentDurations: [Double], itemDuration: Double?) -> Double? {
        let mediaEnd = segmentDurations.reduce(0, +)
        guard mediaEnd.isFinite else { return nil }
        var end = mediaEnd
        if let duration = itemDuration, duration.isFinite, duration > end { end = duration }
        guard end > 0 else { return nil }
        var start = end - naturalEndWindowSeconds
        if let last = segmentDurations.last, last > 0 { start = min(start, mediaEnd - last) }
        return max(0, start)
    }
}

/// Replaces, once, a native REMUX item that AVPlayer STARTED on live EVENT
/// playlists (pure — the harness tests it; sampled ~1 Hz by the remux
/// owners' stats timers).
///
/// A file without a Matroska Duration is served as EVENT playlists (no
/// ENDLIST until the remux has finished), so the item attached at onReady
/// starts "live". AVFoundation keeps that item's live bookkeeping after it
/// sees ENDLIST ("Live/Event reached end of playlist. Switched to VOD" in
/// the CoreMedia log) — measured on macOS 26 (round-6 X20 findings): the
/// segments of the last live version of the playlist keep "rolling out" in
/// wall-clock time, and once its whole listed duration has gone by since
/// that reload (about 24 s for a 30 s presentation, 5 and 10 min for 300 /
/// 660 s ones) the item's seekable range collapses to [end, end] and its
/// duration can turn bogus (42 s for a 300 s movie). From then on every
/// seek outside the buffered range, every switch to an audio / subtitle
/// rendition not loaded yet (and, in F3 x20, subtitles turned off) makes the
/// segment pump answer "end of stream": the item freezes for good without
/// posting a stall or a failure — or the new rendition is placed after the
/// end. An item that starts on the finished playlists (EVENT + ENDLIST)
/// never does that. So once the remux has finished, the owners rebuild such
/// an item once in place (`PlaybackStarvationRecovery.rebuildNow`, its play
/// / pause state and position kept: under 0.3 s without picture), before
/// the collapse; the rebuilt item sees ENDLIST at its first load and is
/// never watched.
struct LiveBornItemWatch {
    /// Why: the rebuild's log line.
    static let reason = "Élément AVPlayer démarré en direct (EVENT) : reconstruit une fois la fin du remux connue"

    /// The live-born item still to rebuild.
    private(set) var pendingItem: ObjectIdentifier?

    init() {}

    /// A new current item (the first one, or a replacement): it is live-born
    /// — and remembered — when the session has no header Duration
    /// (`isEventSession`: EVENT playlists) and the remux hasn't finished yet;
    /// any other item clears the watch (a replacement attached after the
    /// finish sees ENDLIST at once).
    mutating func attached(_ item: ObjectIdentifier, isEventSession: Bool, remuxFinished: Bool) {
        pendingItem = isEventSession && !remuxFinished ? item : nil
    }

    /// One sample (~1 Hz). True — once: the watch then forgets the item —
    /// when `current` is the live-born item, the remux has finished and the
    /// owner can rebuild now (`isEligible`: remux route, no recovery running,
    /// no VLC hand-off, no start seek pending, app active, no AirPlay, no
    /// Picture in Picture). Not eligible yet → asked again at the next
    /// sample; another current item → nothing to do.
    mutating func shouldRebuild(current: ObjectIdentifier?, remuxFinished: Bool, isEligible: Bool) -> Bool {
        guard let pending = pendingItem, let current = current, current == pending else { return false }
        guard remuxFinished, isEligible else { return false }
        pendingItem = nil
        return true
    }
}

/// Watched progress of one VLC session — the iOS VLC player
/// (`VLCPlayerViewController`) and the tvOS one (`PCTPlayerViewController`) —
/// under the native players' rules (`ResumePolicy.progressToSave`, as in
/// `RemuxAVPlayerViewController.saveProgress`). Pure: the harness tests it.
///
/// VLC opens the stream at 0:00 and seeks to `startPosition` once the input
/// is seekable, by position (`VLCMediaPlayer.position`: no duration needed).
/// The tick that issues the seek still carries the old position, and with a
/// real audio output the next one may too (VLCKit 4.0.0a21: up to ~2 s on a
/// local file); then VLC reports the target, and holds it while a slow
/// torrent still fetches the data there. So until VLC reports a position near
/// `startPosition` (or the user moves the playhead), the session's position
/// is at least `startPosition`, and it is `startPosition` itself when VLC
/// never played: an early close (VLC error, slow torrent) keeps the
/// hand-off / resume position, never 0:00.
struct VLCWatchProgress {
    /// How far before `startPosition` the resume seek may land (on a
    /// keyframe) and still count as there.
    static let startTolerance: Float = 0.01

    /// Where VLC starts (0…1): a native player's hand-off position or the
    /// saved progress. No seek (0, ≥ 1) = from the beginning; 0 once the
    /// user chose to start over (`restartFromBeginning()`).
    private(set) var startPosition: Float
    /// The saved point this session protects: what the title had saved when
    /// the player opened — its resume point, or the native player's save at
    /// the hand-off once native playback ran (made with these rules, its own
    /// high water and « Reprendre du début »). Never `startPosition` as such:
    /// after a rewind handed over before the resume point, VLC must not
    /// replace a point the user never watched past.
    /// (`ResumePolicy.startPosition(forSavedProgress:)` of the stored value:
    /// a finished title protects nothing.)
    let resumePoint: Float
    /// The user chose to start over in the VLC player's own question (tvOS:
    /// « Start from Beginning »): VLC plays from 0:00 and `resumePoint` is no
    /// longer protected (`ResumePolicy.progressToSave`). The iOS VLC player
    /// asks no such question: a restart chosen in the native player reaches
    /// it through `resumePoint` (the native save at the hand-off).
    private(set) var userRestarted: Bool
    /// VLC's reported position is the session's: the resume seek landed (or
    /// there was none), or the user moved the playhead.
    private(set) var followsPlayer: Bool
    /// Last position VLC reported (0…1); nil until VLC played.
    private(set) var lastPosition: Float?
    /// Furthest session position reached.
    private(set) var highWater: Float = 0

    init(startPosition: Float, resumePoint: Float, userRestarted: Bool = false) {
        self.startPosition = userRestarted ? 0 : startPosition
        self.resumePoint = resumePoint
        self.userRestarted = userRestarted
        followsPlayer = !Self.seeksAtStart(self.startPosition)
    }

    /// VLC seeks to `position` before playing on: 0 < position < 1.
    static func seeksAtStart(_ position: Float) -> Bool {
        position > 0 && position < 1
    }

    /// The session's position: VLC's once it follows the player, at least
    /// `startPosition` before that, `startPosition` when VLC never reported
    /// one. nil when VLC never played and had nothing to resume.
    var current: Float? {
        guard let last = lastPosition else {
            return Self.seeksAtStart(startPosition) ? startPosition : nil
        }
        return followsPlayer ? last : max(startPosition, last)
    }

    /// One position VLC reported while playing or paused (`position`, 0…1).
    /// A negative or NaN value (no input) is ignored.
    mutating func note(position: Double) {
        guard position.isFinite, position >= 0 else { return }
        let fraction = Float(min(position, 1))
        if !followsPlayer, fraction >= startPosition - Self.startTolerance { followsPlayer = true }
        lastPosition = fraction
        if let current = current { highWater = max(highWater, current) }
    }

    /// The user moved the playhead (slider, ±10 s / ±30 s, scrub): VLC's
    /// position counts from now on, even before the resume point.
    mutating func userMovedPlayhead() {
        followsPlayer = true
    }

    /// The user answered « Depuis le début » before VLC played: no resume
    /// seek, VLC's position counts from 0:00, and `resumePoint` is no longer
    /// protected. The high water is kept.
    mutating func restartFromBeginning() {
        userRestarted = true
        startPosition = 0
        followsPlayer = true
    }

    /// The fraction to store, nil to keep the stored value.
    func progressToSave() -> Float? {
        guard let current = current else { return nil }
        return ResumePolicy.progressToSave(current: current, resumePoint: resumePoint,
                                           highWater: max(highWater, current), userRestarted: userRestarted)
    }
}
