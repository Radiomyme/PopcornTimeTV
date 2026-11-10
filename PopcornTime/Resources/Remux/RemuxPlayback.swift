

import Foundation
import GCDWebServer
import PopcornTorrent
import PopcornKit

/// Drives MKVToHLSRemuxSession against the still-downloading torrent file and
/// serves it to AVPlayer as a **complete VOD** HLS presentation:
///
///  - The media playlists span the movie's TOTAL duration (from the MKV
///    header) from the first request: segments already remuxed get their
///    real durations; the others get their PLANNED durations when the
///    file's keyframe index (Matroska Cues) is readable at that point — a
///    complete file, or a torrent whose last pieces came first
///    (PopcornTorrent fetches them before `readyToPlay`) — which makes the
///    list exact (`MKVToHLSRemuxSession.isPlaylistFromKeyframeIndex`);
///    otherwise one-grid-slot estimates adding up to that duration
///    (`targetDuration`, raised for long-GOP files so that no segment index
///    is lost), each starting within one keyframe interval of its segment's
///    media start — within half a slot once the target was raised. ENDLIST
///    is always present. AVPlayer therefore shows the full timeline and
///    scrubber from the first second — no "live" badge. That EXTINF list is
///    FROZEN the first time a media playlist is served
///    (`MKVToHLSRemuxSession.mediaPlaylist`; AVPlayer's seconds live on it:
///    `playerTimelineDurations()`): every rendition, every later request
///    and every later AVPlayerItem (a starvation rebuild, an audio switch)
///    gets byte-identical playlists (RFC 8216 §4.3.3.5: a VOD playlist
///    cannot change). AVPlayer re-times a segment it seeks into to its
///    listed start, so an estimated entry off its media start shifts the
///    picture against the clock until the next seek — by that much, or, on
///    a fresh item, which can place that segment at its listed start plus
///    the offset of a segment it had prebuffered, by the difference of the
///    two offsets: up to about one slot; and after
///    a subtitle rendition was turned on then off, AVPlayer can stall ~10 ms
///    before the end of a movie whose end it plays from such a segment (no
///    DidPlayToEnd) — the players' stuck-on-complete-data watch handles
///    that. A file whose header has no Duration (or an absurd one, beyond
///    `MKVToHLSRemuxSession.maxHeaderDurationSeconds`) gets EVENT playlists
///    instead (existing segments only, reloaded by AVPlayer, append-only;
///    ENDLIST once the remux has finished). The master playlist is
///    byte-stable once served too, except that OpenSubtitles renditions
///    assigned later (`subtitles`) are listed in the masters fetched after
///    that. An OpenSubtitles file whose download or conversion failed
///    DEFINITIVELY (`ExternalSubtitleFailure`: an HTTP 404 / 410…, a quota
///    page or a file that doesn't convert) before a served master listed it
///    is left out (`externalRenditions`; one that fails later stays listed,
///    and so does one whose failure was TRANSIENT — no answer, HTTP 429 /
///    5xx — which is tried again) — the preferred-language one is fetched as
///    soon as the list is known, `onReady` waiting for it
///    (`readyFetchHoldSeconds` at most): when it can't be shown, no
///    rendition carries that language, so AVFoundation (OS 27) can offer its
///    own translation into it instead.
///  - Requests for segments that aren't remuxed yet are HELD by the server
///    (long-poll) until the remuxer produces them, so seeking within the
///    downloaded range just works and seeking ahead waits like buffering.
///    Held requests sit in a waiter table resolved by one timer — no thread
///    is blocked, however many AVPlayer (and its retries) keeps open.
///  - Audio is demuxed: one rendition per playable audio track (the only way
///    to attach `CHANNELS="16/JOC"`, the token tvOS reads to light the
///    receiver's Dolby Atmos badge). Embedded text subtitles are segmented
///    WebVTT renditions; OpenSubtitles files are exposed as extra subtitle
///    renditions (converted to WebVTT on demand). All of them appear in
///    AVPlayer's own audio / subtitle pickers.
///  - Anything the remuxer can't play natively (DTS/TrueHD-only audio, VP9,
///    a non-Matroska payload…) is reported through `onFailure` within
///    seconds, so the caller can fall back to VLC.
///  - The owner reports where its player is about once a second
///    (`updatePlaybackPositions`): `played`, the last position playback
///    actually reached, and `wanted`, where the player needs data now (the
///    playhead, a pending seek target, a starvation recovery's resume time).
///    Those are AVPlayer seconds, on the timeline of the playlists it was
///    served (the frozen EXTINF list): every position, anchor and segment
///    span below is mapped through that list (`playerTimeline`), never
///    through the durations the remux really cut.
///  - The remux runs at most `lookaheadSeconds` (L, ≈ 3 min) past its
///    anchor: the furthest of the segments under `played` and `wanted` and
///    of the segments AVPlayer requested that are still wanted — received in
///    the last `requestAnchorLifetime` (30 s: AVPlayer re-requests a segment
///    it still waits for every few seconds), and either after the owner's
///    latest report or within one lookahead window of the reported `wanted`
///    segment. A seek or resume far ahead pulls the remux there at once (its
///    request comes first), while an abandoned one stops pulling it at the
///    next report (after 30 s without reports): the remux copy ahead of the
///    player stays at about L.
///  - A disk budget bounds the remux copy (`allowedKeptBytes`): the free
///    space + the deletable segments the remux keeps − a 2 GiB reserve −
///    what the torrent still has to write − one lookahead at the output
///    rate. It is re-evaluated every 10 s, every 256 MiB written and after a
///    failed write; in between, the remux's and the torrent's own writes
///    and deletions cancel out in it. While the written segments fit,
///    nothing is deleted: the span a far seek skipped stays, and going back
///    there plays natively. Over the budget, the written segment furthest
///    from every position — `played` and `wanted` (0 while neither is
///    reported: an item not positioned yet loads segment 0 first), the
///    start of the lookahead anchor (a far request not reported yet) and,
///    while it lies ahead of `played` or `wanted`, the start of the sticky
///    budget anchor (the highest anchor the pump wrote toward: it does not
///    fall back when AVPlayer's requests age out during a pause nor when the
///    playhead moves back, only after a jump of more than L + 3 min away
///    from it — `stickyBudgetAnchor`) — goes first, in every rendition:
///    from the pump before its next write (a pump-ahead on a tight disk
///    deletes what it skips as it writes it) and after each report. Never deleted: init segments, segment 0 of every rendition (a
///    fresh AVPlayerItem loads it first) and, for each of those positions X,
///    every segment overlapping [X − 3 min, X + L]. Linear playback thus
///    deletes the oldest segments behind `played` first: a rewind window as
///    long as the budget allows (`keepBehindSeconds`) and never shorter
///    than 3 min, and a pause, or a rewind within that window, plays on
///    natively — what the remux already wrote ahead of it stays too. A
///    deleted segment is gone for good (`prunedIndexes`, `isAvailable`
///    false, 404 once playback needs it; the remux never writes it again).
///  - A segment that can't be written (disk full…) is never announced as
///    existing; the budget is re-evaluated (fresh free space) and enforced
///    before each retry, and after a few failed retries the remux stops:
///    `onFailure` before `onReady`, else `onHalted` (once) and
///    `failureReason` is set.
///
/// HTTP semantics, which the players rely on — 404 means "this will NEVER
/// exist", and is only ever given for media segments and unknown names:
///  - Playlists (`master.m3u8`, `video.m3u8`, `audio{i}.m3u8`,
///    `subs{j}.m3u8`): 200 with the text described above (404 only before
///    `onReady`, when no client knows the URL yet, and for a rendition the
///    session doesn't have).
///  - Media segments (init + vseg / a{i}seg / s{j}seg):
///    - 200 (or 206 for a byte range): the file.
///    - 404: a pruned segment once playback needs it (it then fires
///      `onUnavailableSegmentRequested`, whose doc has the exact rule), an
///      index past the end of a finished or halted remux, or a rendition
///      the session doesn't have. AVPlayer retries a 404 with a growing
///      backoff for about 30 s, then posts FailedToPlayToEnd
///      (NSURLErrorFileDoesNotExist -1100 ← CoreMedia -12938): the players
///      hand over to VLC on the signals above instead of waiting for that.
///    - A pruned segment more than about one segment AHEAD of the playhead
///      (AVPlayer prefetching into a deleted span) is held like a segment
///      still to come, until a report newer than the request puts the
///      playhead within about one segment of it (404 then), the hold
///      deadline (503) or `stop()` (410): the media AVPlayer has buffered
///      keeps playing natively meanwhile. One the playhead is in or about to
///      reach, or one behind the last played position (a rewind past the
///      kept media), answers 404 at once; one the playhead jumped past, or
///      that an item still loading at 0 asks for before its resume seek,
///      stays held (details: `onUnavailableSegmentRequested`).
///    - Anything that may still appear is held (long-poll,
///      `longPollTimeout`). When the hold deadline passes, the answer is 503
///      with `Retry-After: 1`, never 404. A third request for the same name
///      answers the oldest held one with 503 (AVPlayer re-requesting after
///      its own timeout).
///  - External subtitles (`sub_{key}.m3u8`, `sub_{key}.vtt`, OpenSubtitles):
///    a key of `subtitles`, or one a served master playlist listed, is
///    never answered 404. When its download or its conversion fails,
///    `sub_{key}.vtt` answers 200 with an empty WebVTT carrying the
///    session's X-TIMESTAMP-MAP (the failure is logged once) — at once, and
///    for `externalSubtitleRetryInterval` without a new download, after a
///    DEFINITIVE failure or after `externalSubtitleTransientAttempts`
///    TRANSIENT ones in a row; after a single transient failure the request
///    is held for another attempt `externalSubtitleTransientRetryDelay`
///    later instead (when its own bound, below, ends after that attempt's
///    start), and answered that way only when it fails too or takes more
///    than `externalSubtitleRetryHoldSeconds`. Whatever attempt it waits for
///    — the prefetch's, one it started, a retry — a request is held at most
///    `externalSubtitleRequestHoldSeconds` from its arrival: AVPlayer keeps
///    an item that selected the rendition unready until the file is
///    answered, so a slow or silent OpenSubtitles host must not push it past
///    the owners' readiness timeout. It then gets the empty WebVTT and the
///    download goes on: its file, if it comes, serves the next requests (an
///    item a recovery rebuilds). AVPlayer plays on without that subtitle — a
///    404 on a selected rendition would keep the item from becoming ready,
///    or fail it later (-1100), and the players take a 404 for "gone, hand
///    over to VLC". Any other key is an unknown name: 404.
///  - 410 once `stop()` ran (every held request — a media segment's or a
///    `sub_{key}.vtt` — gets it exactly once).
final class RemuxPlayback {

    // CONTRACT (A4 implements, B1 consumes) ---------------------------------

    /// Matroska-family payloads (.mkv / .mk3d / .webm) — the remuxer decides
    /// itself (fast) whether the tracks are playable natively.
    static func canAttemptRemux(fileName: String) -> Bool {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (trimmed as NSString).pathExtension.lowercased()
        return ["mkv", "mk3d", "webm"].contains(ext)
    }

    /// Preferred audio / subtitle languages (ISO 639-1, priority order) —
    /// set before `start()`; drive the DEFAULT renditions.
    var preferredAudioLanguages: [String] = []
    var preferredSubtitleLanguages: [String] = []
    /// Release name carried HDR / DV tags (last-resort VIDEO-RANGE hint).
    var releaseHintsHDR = false

    /// Human-readable renditions for stats overlays ("Vidéo HEVC Main 10 ·
    /// HDR10 · 3840×2160", "Audio 1: Français — E-AC-3 5.1 Atmos (défaut)"…).
    var renditionSummary: [String] {
        guard let session = session, let video = session.video else { return [] }
        var lines = ["Vidéo \(video.summary)"]
        for rendition in session.audioRenditions {
            lines.append("Audio \(rendition.index + 1): \(rendition.name)\(rendition.isDefault ? " (défaut)" : "")")
        }
        for rendition in session.subtitleRenditions {
            lines.append("Sous-titres \(rendition.index + 1): \(rendition.name)\(rendition.isDefault ? " (défaut)" : "")")
        }
        let external = externalRenditions(defaultAllowed: false)
        if !external.isEmpty {
            lines.append("OpenSubtitles: " + external.map(\.language).joined(separator: ", "))
        }
        return lines
    }

    // -----------------------------------------------------------------------

    /// Set to true BEFORE `start()` when the caller is still fetching
    /// OpenSubtitles results, false (or assign `subtitles`) when done:
    /// `onReady` is then held up to ~5 s so the subtitles make it into the
    /// master playlist (AVPlayer fetches it only once), then — while the
    /// preferred-language file is being fetched (`subtitles`) — up to
    /// `readyFetchHoldSeconds` more. Default false.
    var externalSubtitlesPending: Bool {
        get { stateLock.withLock { lockedSubtitlesPending } }
        set { stateLock.withLock { lockedSubtitlesPending = newValue } }
    }

    /// The remux session (created on the pump queue at the first tick).
    var session: MKVToHLSRemuxSession? { stateLock.withLock { lockedSession } }

    /// Why the remux stopped for good, nil while it is healthy: the reason
    /// given to `onFailure` (before `onReady`), or — after `onReady` — the
    /// reason given to `onHalted` (a segment that couldn't be written: disk
    /// full…). Thread-safe. Lets the player tell "the remux itself failed →
    /// VLC" from "the download is slow at the playhead" (AVPlayer stalls and
    /// -12889 errors look the same in both cases).
    var failureReason: String? { stateLock.withLock { lockedFailureReason } }

    /// The torrent being downloaded into `localFile` (nil: a local file).
    /// Only a COMPLETE download lets the remux treat the file as final.
    weak var streamer: PTTorrentStreamer? {
        didSet { if streamer != nil { stateLock.withLock { lockedHadStreamer = true } } }
    }

    /// Subtitles offered as native tracks (OpenSubtitles model objects).
    /// Assigned from the main thread, read by the HTTP handlers (locked).
    /// The file the master playlist flags DEFAULT — the first preferred
    /// language, when the movie has no non-forced track of its own in it —
    /// is fetched as soon as the list is known and segment 0 exists, and
    /// `onReady` waits for it at most `readyFetchHoldSeconds` beyond the
    /// `externalSubtitlesPending` hold: one that definitively can't be shown
    /// is then left out of the master (`externalRenditions`).
    var subtitles: [Subtitle] {
        get { stateLock.withLock { lockedSubtitles } }
        set {
            stateLock.withLock {
                lockedSubtitles = newValue
                lockedSubtitlesPending = false
            }
            workQueue.async { [weak self] in self?.prefetchPreferredExternalSubtitle() }
        }
    }

    /// Called once on the main queue with the master playlist URL.
    var onReady: ((URL) -> Void)?
    /// Called once on the main queue when native playback is impossible
    /// (unsupported tracks, unreadable file…) — fall back to VLC.
    var onFailure: ((String) -> Void)?

    // SHARED API (fix round 4: A4 implements, B1 + harnesses consume) -------

    /// Called ONCE on the main queue when the session stops producing AFTER onReady
    /// (write failure / disk full). Never called after stop(), never before onReady (onFailure covers that).
    var onHalted: ((_ reason: String) -> Void)? {
        get { stateLock.withLock { lockedOnHalted } }
        set { stateLock.withLock { lockedOnHalted = newValue } }
    }
    /// Called on the main queue when AVPlayer requests a media segment that was pruned and will never be
    /// served again, once playback is about to need it (`prunedRequestDecision`), together with that
    /// request's 404:
    ///  - at once when the playhead is in the segment or within about one segment before it — the
    ///    playhead of the owner's latest report, or, once playback has run, a lower one when AVPlayer
    ///    requested kept segments far behind it since (a seek back that report doesn't know yet:
    ///    « recommencer » in the kept segment 0 while segment 1 is pruned) — and for a segment that starts
    ///    at or before the last played position when nothing hints at such a seek (a rewind past the kept
    ///    media);
    ///  - otherwise the request is HELD — AVPlayer plays what it has buffered natively meanwhile — until a
    ///    report NEWER than the request puts the playhead in the segment or within about one segment
    ///    before it. A request the playhead has jumped past, or one an item makes while still loading at 0
    ///    before its resume seek (nothing played yet), stays held: no 404, no callback; the hold deadline
    ///    (503) or `stop()` (410) answers it.
    /// Argument: that segment's start on the PLAYER timeline (seconds, 0-based) — which can lie a few
    /// seconds AHEAD of the playhead: hand over at min(playhead, argument). Coalesced: at most once per 2 s.
    /// Segment 0 is never pruned, but an AVPlayerItem that is NOT positioned before it loads (it starts
    /// at 0) may prefetch segments 1, 2… before its seek: requests of those can fire this too if they were
    /// pruned. Position a fresh item before attaching it (or ignore the callback until its seek is done).
    var onUnavailableSegmentRequested: ((_ playerSeconds: Double) -> Void)? {
        get { stateLock.withLock { lockedOnUnavailable } }
        set { stateLock.withLock { lockedOnUnavailable = newValue } }
    }
    /// False when the segment covering `playerSeconds` (the player timeline: `playerTimeline`) was pruned
    /// (deleted for good, `prunedIndexes`).
    func isAvailable(playerSeconds: Double) -> Bool {
        guard playerSeconds.isFinite, let session = session else { return true }
        return !isPruned(Self.segmentIndex(coveringPlayerSeconds: max(0, playerSeconds),
                                           durations: Self.playerTimeline(session),
                                           targetDuration: session.targetDuration))
    }
    /// Test hook: overrides the free-space query of the output volume (nil = the real query).
    /// A provider returning nil for a URL falls back to the real query.
    static var freeSpaceProvider: ((URL) -> Int64?)?
    /// Test hook: long-poll deadline for held segment requests (default 120 s).
    static var longPollTimeout: TimeInterval = 120

    // SHARED API (fix round 6: A6 implements, B3 + harnesses consume) -------

    /// Positions of the owner's player, reported about once a second (main queue) — INCLUDING while a
    /// starvation recovery waits. Cheap and thread-safe.
    ///  - played: the last position playback actually reached (`PlayedPositionTracker.lastPlayedTime`);
    ///    nil before playback has run.
    ///  - wanted: where the player needs data now: while a starvation recovery waits, its `resumeTime`;
    ///    otherwise `player.currentTime()` (the playhead, or a pending seek target — AVPlayer reports the
    ///    target at once). nil when unknown (not finite, < 0).
    /// Drives the lookahead of the remux, the disk budget's deletions and the answers to requests for
    /// pruned segments (see the class doc and `onUnavailableSegmentRequested`).
    /// A report with neither position counts as no report: AVPlayer's recent requests alone anchor the
    /// lookahead, and the budget protects the anchor's region and segment 0's.
    func updatePlaybackPositions(played: Double?, wanted: Double?) {
        let played = played.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let wanted = wanted.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let now = Self.uptime
        stateLock.withLock {
            lockedPlayedSeconds = played
            lockedWantedSeconds = wanted
            lockedPositionsReportedAt = played != nil || wanted != nil ? now : nil
        }
        noteWantedPastRemux(wanted)
        enforceDiskBudget(.report)
        // Requests for pruned segments held until a report newer than them: decided now.
        resolveHeldRequestsSoon()
    }

    /// True once the remux has finished: every segment of the presentation was written (some may have
    /// been pruned since). Thread-safe.
    var isFinished: Bool { stateLock.withLock { lockedFinished } }

    /// Indexes of the segments deleted for good (never 0), in every rendition. Thread-safe copy.
    var prunedIndexes: IndexSet { stateLock.withLock { lockedPruned } }

    // -----------------------------------------------------------------------

    /// The rewind depth (s) the current disk budget gives linear playback
    /// (`rewindSeconds(allowedKeptBytes:outputBytesPerSecond:)` of the latest
    /// evaluation): what the allowance holds beyond one lookahead, at least
    /// `minimumKeepBehindSeconds` (kept behind every position whatever the
    /// budget). Diagnostics — no fixed window decides what goes: the budget
    /// deletes the segments furthest from the positions first. Thread-safe.
    var keepBehindSeconds: Double {
        let (allowed, rate) = stateLock.withLock { (lockedAllowedKeptBytes, lockedBudgetRate) }
        return Self.rewindSeconds(allowedKeptBytes: allowed, outputBytesPerSecond: rate)
    }

    /// Highest segment index deleted so far (-1: none). Diagnostics: the
    /// pruned indexes need not be contiguous (`prunedIndexes`). Thread-safe.
    var prunedThrough: Int { stateLock.withLock { lockedPruned.last ?? -1 } }

    private let server = GCDWebServer()
    /// Serial pump queue; each tick drains its own autorelease pool (the
    /// session also drains one per cluster).
    private let workQueue = DispatchQueue(label: "remux.pump", qos: .userInitiated, autoreleaseFrequency: .workItem)
    /// Resolves held (long-poll) requests: one timer, no thread per request.
    private let holdQueue = DispatchQueue(label: "remux.longpoll", qos: .userInitiated)
    /// Disk-budget evaluations a report asks for (the pump evaluates on its
    /// own queue), each followed by an eviction pass.
    private let budgetQueue = DispatchQueue(label: "remux.budget", qos: .utility)
    private let inputFile: URL
    private let outputDir: URL
    /// Release name carried the Atmos tag: passed to the session as a
    /// fallback hint for the FIRST E-AC-3 track when the JOC extension can't
    /// be read from the bitstream itself.
    private let isAtmos: Bool

    // Guarded by `stateLock` (touched from main, the pump queue and the
    // HTTP threads).
    private let stateLock = NSLock()
    private var lockedSession: MKVToHLSRemuxSession?
    private var lockedSubtitles: [Subtitle] = []
    private var lockedSubtitlesPending = false
    private var lockedStopped = false
    private var lockedFinished = false
    /// Segment indexes deleted for good (never 0).
    private var lockedPruned = IndexSet()
    /// Positions of the owner's latest report (`updatePlaybackPositions`),
    /// and when it was received (uptime; nil: no report, or one that knew
    /// neither position).
    private var lockedPlayedSeconds: Double?
    private var lockedWantedSeconds: Double?
    private var lockedPositionsReportedAt: TimeInterval?
    /// Media segments requested in the last `requestAnchorLifetime` (pruned
    /// ones excepted): index → uptime of the latest request (stale entries are
    /// dropped whenever the anchor is computed). They anchor the lookahead,
    /// and tell `prunedRequestDecision` where AVPlayer plays when the owner's
    /// latest report predates a seek.
    private var lockedRecentRequests: [Int: TimeInterval] = [:]
    /// The sticky budget anchor (segment index; nil until the pump first
    /// wrote toward an anchor): raised by the pump (`raiseStickyAnchor`),
    /// set to the lookahead anchor by an eviction pass once it no longer
    /// reaches the positions (`stickyBudgetAnchor`).
    private var lockedStickyAnchor: Int?
    private var lockedFailureReason: String?
    /// A streamer was handed in at some point: once it is gone, the input is
    /// no longer treated as a complete local file.
    private var lockedHadStreamer = false
    private var lockedLoggedMaster = false
    /// Keys of the external renditions listed by the master playlists served
    /// so far: their `sub_{key}` resources are never answered 404.
    private var lockedAdvertisedExternalKeys = Set<String>()
    /// BANDWIDTH of the first master playlist served: later ones repeat it
    /// (the estimate follows the size of a growing file).
    private var lockedMasterBandwidth: Int?
    /// The last reported `wanted` position lay past the remuxed range
    /// (logged once per such episode).
    private var lockedWantedPastRemux = false
    private var lockedOnHalted: ((String) -> Void)?
    private var lockedOnUnavailable: ((Double) -> Void)?
    /// Uptime of the last `onUnavailableSegmentRequested` (coalescing).
    private var lockedLastUnavailable: TimeInterval?
    /// Disk budget of the latest evaluation (`allowedKeptBytes`; 0 until one
    /// succeeded), the output rate it measured (nil: none yet), when it ran
    /// (uptime; nil: never, with a known output rate) and the session's
    /// `bytesWritten` at that moment.
    private var lockedAllowedKeptBytes: Int64 = 0
    private var lockedBudgetRate: Double?
    private var lockedBudgetEvaluatedAt: TimeInterval?
    private var lockedBudgetEvaluatedBytes: Int64 = 0
    private var lockedBudgetInFlight = false
    private var lockedLoggedAllowance: Int64?
    /// Uptime of the last eviction log, and the segments evicted since it
    /// (the log is coalesced).
    private var lockedEvictionLoggedAt: TimeInterval?
    private var lockedEvictedSinceLog = 0
    private var pumpTimer: DispatchSourceTimer?
    /// Serializes eviction passes (pump, reports, budget queue): each
    /// computes its victims and adds them to `lockedPruned` as one step.
    /// Taken before `stateLock`, never while holding it.
    private let pruneLock = NSLock()
    /// Serializes serving a media file with deleting one (evictions,
    /// `stop()`'s cleanup): see `answer`. Taken before `stateLock` /
    /// `holdLock` / the session's lock, never while holding them.
    private let fileLock = NSLock()

    // Held requests, guarded by `holdLock` (never taken with `stateLock` held).
    private let holdLock = NSLock()
    private var heldRequests: [HeldRequest] = []
    private var holdTimer: DispatchSourceTimer?
    private var holdClosed = false

    // Pump-queue-only state.
    private var prepared = false
    private var readyFired = false
    private var failed = false
    private var waitingTicks = 0
    private var stalledCompleteTicks = 0
    private var readyHoldTicks = 0
    /// When `onReady` stops waiting for the preferred OpenSubtitles file
    /// (`fireReadyIfDue`; nil until it waits for one).
    private var readyFetchDeadline: DispatchTime?
    /// OpenSubtitles keys fetched ahead of the master playlist, once each
    /// (`prefetchPreferredExternalSubtitle`).
    private var prefetchedExternalKeys = Set<String>()
    private var idleTicks = 0

    /// How far (s) the remux may run past its anchor (see `lookaheadAnchor`).
    /// AVPlayer always finds that much ready beyond what it asked for (the
    /// pump produces ≥ 36 s of media per tick when the input is there), while
    /// a complete file or a fast swarm no longer gets remuxed to the end.
    static let lookaheadSeconds: Double = 180
    /// A media request keeps anchoring the lookahead this long (s) after it
    /// was received: AVPlayer re-requests a segment it still waits for every
    /// few seconds (its -12889 retries, the third-request eviction), so a far
    /// seek that is still pending stays fresh while an abandoned one ages out.
    /// What the pump already wrote for such a request stays protected by the
    /// disk budget after it aged out (a pause: AVPlayer, its buffer full,
    /// asks for nothing), as long as it lies near the positions
    /// (`stickyBudgetAnchor`).
    static let requestAnchorLifetime: TimeInterval = 30

    /// Behind each position (`played`, `wanted`, the starts of the lookahead
    /// anchor and of the sticky budget anchor) the disk budget never deletes
    /// the segments of this many seconds, whatever the free space: a rewind
    /// of up to this much always lands on cached files, and plays on
    /// natively — what the remux wrote ahead of the playhead before the
    /// rewind stays (`stickyBudgetAnchor`).
    static let minimumKeepBehindSeconds: Double = 180
    /// Free space the disk budget never uses (2 GiB): the system, the
    /// torrent's own bookkeeping and the bitrate of the future content.
    static let rewindReserveBytes: Int64 = 2 << 30
    /// The disk budget is re-evaluated every this many seconds (at most)…
    static let budgetRefreshInterval: TimeInterval = 10
    /// …once the remux wrote this many bytes since its last evaluation
    /// (256 MiB), so a fast pump-ahead can't outrun it, and after every
    /// failed segment write.
    static let budgetRefreshBytes: Int64 = 256 << 20
    /// Period of the held-request resolver (s).
    static let holdResolveInterval: TimeInterval = 0.25
    /// Held requests for one name beyond which the oldest is answered 503.
    static let maxHeldRequestsPerName = 2
    /// `onUnavailableSegmentRequested` fires at most once per this many seconds.
    static let unavailableCoalesceInterval: TimeInterval = 2

    init(localFile: URL, streamer: PTTorrentStreamer?, isAtmos: Bool = false) {
        self.inputFile = localFile
        self.streamer = streamer
        self.lockedHadStreamer = streamer != nil
        self.isAtmos = isAtmos
        // The "remux-" prefix is what purgeOrphanTorrentDownloads() sweeps.
        self.outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-\(UUID().uuidString.prefix(8))")
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        installHandlers()
        var options: [String: Any] = [GCDWebServerOption_Port: 50710,
                                      GCDWebServerOption_BindToLocalhost: true]
        #if !os(macOS)
        // iOS/tvOS-only option (ties into UIApplication background suspension).
        options[GCDWebServerOption_AutomaticallySuspendInBackground] = false
        #endif
        do {
            try server.start(options: options)
        } catch {
            // Port still held by a previous player (or anything else): any
            // free port will do — the playlist URL carries it.
            options[GCDWebServerOption_Port] = 0
            do {
                try server.start(options: options)
            } catch {
                workQueue.async { self.fail("Serveur HLS local indisponible") }
                return
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        // First tick immediately: an unsupported file is reported at once.
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        stateLock.withLock { pumpTimer = timer }
        timer.resume()
    }

    /// Idempotent; callable from any thread. Every held request — media
    /// segment or `sub_{key}.vtt` — is answered (410) exactly once; later
    /// requests get 410 too.
    func stop() {
        let (alreadyStopped, timer) = stateLock.withLock { () -> (Bool, DispatchSourceTimer?) in
            if lockedStopped { return (true, nil) }
            lockedStopped = true
            let current = pumpTimer
            pumpTimer = nil
            return (false, current)
        }
        guard !alreadyStopped else { return }
        timer?.cancel()
        let held: [HeldRequest] = holdLock.withLock {
            holdClosed = true
            let all = heldRequests
            heldRequests.removeAll()
            holdTimer?.cancel()
            holdTimer = nil
            return all
        }
        for request in held { request.completion(GCDWebServerResponse(statusCode: 410)) }
        // The held `sub_{key}.vtt` requests too (their handler answers 410
        // once stopped); none is held, and no download starts, from now on.
        // The prefetch keeps waiting for its attempt, whose end does nothing
        // more after stop().
        let heldSubtitleRequests: [ExternalVTTWaiter] = vttLock.withLock {
            vttClosed = true
            let requests = vttWaiters.values.flatMap { $0.filter(\.isRequest) }
            vttWaiters = vttWaiters.mapValues { $0.filter { !$0.isRequest } }
            return requests
        }
        heldSubtitleRequests.forEach { $0.completion(nil) }
        if server.isRunning { server.stop() }
        // Delete the output after any in-flight tick (same serial queue),
        // and release the session (closes the input file) there too. Under
        // `fileLock`: a file being handed to GCDWebServer is opened first.
        let directory = outputDir
        let fileLock = self.fileLock
        workQueue.async { [weak self] in
            if let self = self { self.stateLock.withLock { self.lockedSession = nil } }
            fileLock.withLock { _ = try? FileManager.default.removeItem(at: directory) }
        }
    }

    private var isStopped: Bool { stateLock.withLock { lockedStopped } }

    // MARK: - HTTP handlers

    private static let playlistType = "application/vnd.apple.mpegurl"

    private func installHandlers() {
        // Master playlist.
        server.addHandler(forMethod: "GET", path: "/master.m3u8", request: GCDWebServerRequest.self) { [weak self] _ in
            guard let self = self, let text = self.masterPlaylist() else { return GCDWebServerResponse(statusCode: 404) }
            return GCDWebServerDataResponse(data: Data(text.utf8), contentType: Self.playlistType)
        }
        // Media playlists: video.m3u8, audio{i}.m3u8, subs{j}.m3u8.
        server.addHandler(forMethod: "GET", pathRegex: "^/(video|audio[0-9]+|subs[0-9]+)\\.m3u8$", request: GCDWebServerRequest.self) { [weak self] request in
            guard let self = self else { return GCDWebServerResponse(statusCode: 410) }
            let name = String(request.path.dropFirst())
            guard let text = self.mediaPlaylist(named: name) else { return GCDWebServerResponse(statusCode: 404) }
            return GCDWebServerDataResponse(data: Data(text.utf8), contentType: Self.playlistType)
        }
        // External (OpenSubtitles) subtitle playlists + payloads: never 404
        // for a key a served master listed (see the class comment).
        server.addHandler(forMethod: "GET", pathRegex: "^/sub_[A-Za-z0-9-]+\\.m3u8$", request: GCDWebServerRequest.self) { [weak self] request in
            guard let self = self else { return GCDWebServerResponse(statusCode: 410) }
            let key = Self.externalKey(fromPath: request.path, suffix: ".m3u8")
            guard self.servesExternalSubtitle(key: key) else { return GCDWebServerResponse(statusCode: 404) }
            let duration = self.movieDurationSeconds
            let text = HLSPlaylists.singleFileSubtitle(uri: "sub_\(key).vtt", durationSeconds: duration)
            return GCDWebServerDataResponse(data: Data(text.utf8), contentType: Self.playlistType)
        }
        server.addHandler(forMethod: "GET", pathRegex: "^/sub_[A-Za-z0-9-]+\\.vtt$", request: GCDWebServerRequest.self, asyncProcessBlock: { [weak self] request, completion in
            guard let self = self else { completion(GCDWebServerResponse(statusCode: 410)); return }
            let key = Self.externalKey(fromPath: request.path, suffix: ".vtt")
            guard self.servesExternalSubtitle(key: key) else { completion(GCDWebServerResponse(statusCode: 404)); return }
            self.externalVTT(forKey: key, isRequest: true) { [weak self] data in
                // stop() ran: 410, like every held request.
                guard let self = self, !self.isStopped else { completion(GCDWebServerResponse(statusCode: 410)); return }
                // Download / conversion failed, the request's hold ran out (or
                // the subtitle was withdrawn): a WebVTT without cues, on the
                // same timeline as a real one.
                let body = data ?? Data(Self.emptyExternalVTT(mpegts: self.session?.timelineStart90k ?? 0).utf8)
                completion(GCDWebServerDataResponse(data: body, contentType: "text/vtt"))
            }
        })
        // Init segments + media segments of every rendition: served at once
        // when on disk, else held (long-poll, `longPollTimeout`) until the
        // remuxer produces them — covers seeks just past the download
        // frontier. See the class comment for the status codes.
        let mediaRegex = "^/(video_init\\.mp4|audio[0-9]+_init\\.mp4|vseg[0-9]+\\.m4s|a[0-9]+seg[0-9]+\\.m4s|s[0-9]+seg[0-9]+\\.vtt)$"
        server.addHandler(forMethod: "GET", pathRegex: mediaRegex, request: GCDWebServerRequest.self, asyncProcessBlock: { [weak self] request, completion in
            guard let self = self else { completion(GCDWebServerResponse(statusCode: 410)); return }
            let name = String(request.path.dropFirst())
            let byteRange: NSRange? = request.hasByteRange() ? request.byteRange : nil
            self.handleMediaRequest(name: name, byteRange: byteRange, completion: completion)
        })
    }

    private static func contentType(for name: String) -> String {
        if name.hasSuffix(".vtt") { return "text/vtt" }
        if name.hasPrefix("a") { return "audio/mp4" }
        return "video/mp4"
    }

    /// True when `name` will never exist: an index past the end of a
    /// finished remux — or of one halted by a write failure — or a
    /// rendition number the session doesn't have.
    private func isBeyondEnd(name: String, index: Int?) -> Bool {
        let (ended, session) = stateLock.withLock { (lockedFinished || lockedFailureReason != nil, lockedSession) }
        guard let session = session else { return false }
        if let rendition = Self.renditionNumber(name), session.video != nil {
            if name.hasPrefix("audio") || (name.hasPrefix("a") && name.contains("seg")) {
                if rendition >= session.audioRenditions.count { return true }
            } else if name.hasPrefix("s") && rendition >= session.subtitleRenditions.count {
                return true
            }
        }
        guard ended else { return false }
        // WebVTT segment K is written with video segment K: one count for all.
        if let index = index { return index >= session.progress.segmentsWritten }
        return true // init segment still missing after the remux ended
    }

    // MARK: - Held requests (long-poll)

    /// A media request waiting for its file (or, for a pruned segment, for
    /// playback to need it: `prunedRequestDecision`).
    private final class HeldRequest {
        let name: String
        let index: Int?
        let byteRange: NSRange?
        /// Uptime when the request came in: a pruned segment's request is
        /// decided by a report newer than it (or by the playhead estimate).
        let receivedAt: TimeInterval
        /// Uptime after which the answer is 503 + Retry-After.
        let deadline: TimeInterval
        let completion: GCDWebServerCompletionBlock

        init(name: String, index: Int?, byteRange: NSRange?, receivedAt: TimeInterval, deadline: TimeInterval,
             completion: @escaping GCDWebServerCompletionBlock) {
            self.name = name
            self.index = index
            self.byteRange = byteRange
            self.receivedAt = receivedAt
            self.deadline = deadline
            self.completion = completion
        }
    }

    private enum Resolution {
        case hold
        case serve
        /// Will never exist (past the end, halted, no such rendition).
        case notFound
        /// A pruned segment playback needs now: 404, and
        /// `onUnavailableSegmentRequested`.
        case pruned
        /// Hold deadline passed: 503 + Retry-After: 1.
        case retryLater
        /// `stop()` ran.
        case gone
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// GCDWebServer handler thread: answers at once when possible, else holds.
    private func handleMediaRequest(name: String, byteRange: NSRange?, completion: @escaping GCDWebServerCompletionBlock) {
        let index = Self.segmentIndex(name)
        let now = Self.uptime
        // A request for a segment that exists or may still be produced
        // anchors the lookahead; one for a pruned segment doesn't (it never
        // comes back).
        if let index = index, !isPruned(index) { noteRequested(index) }
        let request = HeldRequest(name: name, index: index, byteRange: byteRange, receivedAt: now,
                                  deadline: now + max(0, Self.longPollTimeout), completion: completion)
        let resolution = self.resolution(for: request, now: now)
        if case .hold = resolution {
            hold(request)
        } else {
            answer(request, resolution)
        }
    }

    private func resolution(for request: HeldRequest, now: TimeInterval) -> Resolution {
        if isStopped { return .gone }
        if let index = request.index, isPruned(index) {
            // Deleted for good: 404 once playback needs it, held until then
            // (a prefetch ahead of the playhead).
            switch prunedRequestDecision(index: index, receivedAt: request.receivedAt) {
            case .notFound: return .pruned
            case .hold: return now >= request.deadline ? .retryLater : .hold
            }
        }
        if FileManager.default.fileExists(atPath: outputDir.appendingPathComponent(request.name).path) { return .serve }
        if isBeyondEnd(name: request.name, index: request.index) { return .notFound }
        if now >= request.deadline { return .retryLater }
        return .hold
    }

    /// Answers `request` (any thread); a pruned segment's 404 tells the player
    /// too (`onUnavailableSegmentRequested`, coalesced). A file is served under
    /// `fileLock`, which every deletion takes: the resolution is redone there,
    /// so `GCDWebServerFileResponse` — whose init lstat's the file, a DEBUG
    /// `GWS_DNOT_REACHED` abort when it vanished — and the completion, where
    /// GCDWebServer opens it, see the file the check saw; once it is open, a
    /// deletion no longer matters. A segment evicted since the first
    /// resolution gets what a pruned one gets (404, or held).
    private func answer(_ request: HeldRequest, _ resolution: Resolution) {
        var resolution = resolution
        if case .serve = resolution {
            let served: Bool = fileLock.withLock {
                resolution = self.resolution(for: request, now: Self.uptime)
                guard case .serve = resolution else { return false }
                request.completion(response(for: request, .serve))
                return true
            }
            if served { return }
            if case .hold = resolution { hold(request); return }
        }
        request.completion(response(for: request, resolution))
        if case .pruned = resolution, let index = request.index { noteUnavailableRequest(index: index) }
    }

    private func response(for request: HeldRequest, _ resolution: Resolution) -> GCDWebServerResponse {
        switch resolution {
        case .serve:
            let path = outputDir.appendingPathComponent(request.name).path
            let file = request.byteRange.flatMap { GCDWebServerFileResponse(file: path, byteRange: $0) }
                ?? GCDWebServerFileResponse(file: path)
            guard let response = file else {
                // Not a readable regular file (no deletion can run meanwhile:
                // `answer` serves under `fileLock`).
                return GCDWebServerResponse(statusCode: 500)
            }
            response.contentType = Self.contentType(for: request.name)
            return response
        case .notFound, .pruned:
            return GCDWebServerResponse(statusCode: 404)
        case .retryLater, .hold:
            let response = GCDWebServerResponse(statusCode: 503)
            response.setValue("1", forAdditionalHeader: "Retry-After")
            return response
        case .gone:
            return GCDWebServerResponse(statusCode: 410)
        }
    }

    /// Adds `request` to the table (the third one for a name evicts the
    /// oldest with 503) and makes sure the resolver timer runs.
    private func hold(_ request: HeldRequest) {
        var evicted: HeldRequest?
        let accepted: Bool = holdLock.withLock {
            guard !holdClosed else { return false }
            let same = heldRequests.filter { $0.name == request.name }
            if same.count >= Self.maxHeldRequestsPerName, let oldest = same.first {
                heldRequests.removeAll { $0 === oldest }
                evicted = oldest
            }
            heldRequests.append(request)
            if holdTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: holdQueue)
                timer.schedule(deadline: .now() + Self.holdResolveInterval, repeating: Self.holdResolveInterval,
                               leeway: .milliseconds(50))
                timer.setEventHandler { [weak self] in self?.resolveHeldRequests() }
                holdTimer = timer
                timer.resume()
            }
            return true
        }
        guard accepted else {
            request.completion(GCDWebServerResponse(statusCode: 410))
            return
        }
        if let oldest = evicted { oldest.completion(response(for: oldest, .retryLater)) }
    }

    /// Resolver pass (hold queue): serves what appeared, 404s what will never
    /// exist (a pruned segment: once playback needs it), 503s what passed its
    /// deadline. A request is answered only by whoever removes it from the
    /// table (here, an eviction or `stop()`), so exactly once.
    private func resolveHeldRequests() {
        let snapshot = holdLock.withLock { heldRequests }
        let now = Self.uptime
        var resolved: [(HeldRequest, Resolution)] = []
        for request in snapshot {
            let resolution = self.resolution(for: request, now: now)
            if case .hold = resolution { continue }
            resolved.append((request, resolution))
        }
        let answers: [(HeldRequest, Resolution)] = holdLock.withLock {
            var taken: [(HeldRequest, Resolution)] = []
            for (request, resolution) in resolved {
                guard let position = heldRequests.firstIndex(where: { $0 === request }) else { continue }
                heldRequests.remove(at: position)
                taken.append((request, resolution))
            }
            if heldRequests.isEmpty {
                holdTimer?.cancel()
                holdTimer = nil
            }
            return taken
        }
        for (request, resolution) in answers { answer(request, resolution) }
    }

    /// Resolve held requests right away (a segment was just committed, the
    /// remux finished or halted, the owner reported positions) instead of at
    /// the next timer tick.
    private func resolveHeldRequestsSoon() {
        let any = holdLock.withLock { !heldRequests.isEmpty }
        guard any else { return }
        holdQueue.async { [weak self] in self?.resolveHeldRequests() }
    }

    /// Requests currently held (diagnostics / tests). Thread-safe.
    var heldRequestCount: Int { holdLock.withLock { heldRequests.count } }

    /// A pruned segment playback needs was requested (`prunedRequestDecision`):
    /// tell the player (main queue, coalesced) where that segment starts on
    /// the player timeline (`playerTimeline`).
    private func noteUnavailableRequest(index: Int) {
        guard let session = session else { return }
        let start = Self.segmentStart(index: index, durations: Self.playerTimeline(session),
                                      targetDuration: session.targetDuration)
        let now = Self.uptime
        let fire: Bool = stateLock.withLock {
            guard !lockedStopped, lockedOnUnavailable != nil else { return false }
            if let last = lockedLastUnavailable, now - last < Self.unavailableCoalesceInterval { return false }
            lockedLastUnavailable = now
            return true
        }
        guard fire else { return }
        print("[Remux] pruned segment \(index) requested (starts at \(String(format: "%.1f", start)) s) — not available any more")
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isStopped else { return }
            self.onUnavailableSegmentRequested?(start)
        }
    }

    // MARK: - Requests for pruned segments

    /// What a request for a pruned segment gets (`prunedRequestDecision`).
    enum PrunedRequestDecision: Equatable {
        /// Held (long-poll): playback doesn't need it now (a prefetch ahead of
        /// the playhead, a request the player moved past), or no report says
        /// where playback is.
        case hold
        /// 404 now, and `onUnavailableSegmentRequested`.
        case notFound
    }

    /// When a request for the pruned segment `index`, received at
    /// `receivedAt` (uptime), is answered (pure). The playhead is the latest
    /// report's `wanted ?? played` (`reportedAt`: when it came; none → hold).
    /// Segment spans are on the player timeline: `durations` is what the
    /// media playlists list (`playerTimeline`; past its end, the target
    /// grid), `written` the segments written so far (default: every entry of
    /// `durations`). Playback NEEDS the segment when the playhead lies from
    /// its start − margin to its end + margin; the margin is about one
    /// segment: the target duration, or the previous segment's duration when
    /// longer (+ 1 ms: summed durations).
    ///  - A report newer than the request decides: needed → 404 + callback;
    ///    else hold — a prefetch ahead (AVPlayer keeps playing what it has
    ///    buffered), or a request the playhead jumped past (the player gave it
    ///    up: its deadline answers it, unless the playhead comes back).
    ///  - Otherwise the latest report may predate a seek; 404 + callback at
    ///    once only when one of these holds, else hold until a newer report:
    ///    - needed by the playhead estimate. That is the reported playhead,
    ///      lowered — once playback has run (`played` known) — to the start of
    ///      every kept segment (`requests`: index → uptime of its latest
    ///      request; written, not in `pruned`) requested after that report and
    ///      ending more than `protectBehind` before the reported playhead:
    ///      AVPlayer plays where the owner hasn't reported yet (a seek back;
    ///      « recommencer » in the kept segment 0 while segment 1 is pruned).
    ///      While nothing has played, AVPlayer's requests near 0 are the
    ///      item's own loading before its resume seek, not a seek;
    ///    - a rewind past the kept media the report doesn't know yet: the
    ///      segment starts at or before `played`, and no such request lowered
    ///      the estimate.
    static func prunedRequestDecision(index: Int, durations: [Double], written: Int? = nil, targetDuration: Double,
                                      receivedAt: TimeInterval, played: Double?, wanted: Double?,
                                      reportedAt: TimeInterval?, requests: [Int: TimeInterval], pruned: IndexSet,
                                      protectBehind: Double = RemuxPlayback.minimumKeepBehindSeconds) -> PrunedRequestDecision {
        guard let playhead = wanted ?? played, let reportedAt = reportedAt else { return .hold }
        let written = min(max(0, written ?? durations.count), durations.count)
        let target = max(0.5, targetDuration)
        var starts = [Double](repeating: 0, count: durations.count + 1)
        for (k, duration) in durations.enumerated() { starts[k + 1] = starts[k] + duration }
        func start(_ k: Int) -> Double {
            k <= durations.count ? starts[max(0, k)] : starts[durations.count] + Double(k - durations.count) * target
        }
        let duration = index >= 0 && index < durations.count ? durations[index] : target
        let previous = index >= 1 && index - 1 < durations.count ? durations[index - 1] : 0
        let margin = max(target, previous) + 0.001
        func needs(_ position: Double) -> Bool {
            position >= start(index) - margin && position <= start(index) + duration + margin
        }
        if reportedAt > receivedAt { return needs(playhead) ? .notFound : .hold }
        // Nothing has played yet: AVPlayer's requests near 0 are the item's
        // own loading before its resume seek — no sign of a seek, no rewind.
        guard let played = played else { return needs(playhead) ? .notFound : .hold }
        var estimate = playhead
        for (other, at) in requests where at > reportedAt && other >= 0 && other < written && !pruned.contains(other) {
            if start(other + 1) < playhead - protectBehind { estimate = min(estimate, start(other)) }
        }
        if needs(estimate) { return .notFound }
        // A rewind past the kept media the owner hasn't reported yet: the
        // segment lies at or behind where playback has been, and AVPlayer
        // asked for nothing kept far behind the reported playhead since.
        return estimate == playhead && start(index) <= played ? .notFound : .hold
    }

    /// `prunedRequestDecision` on the current state. Any thread.
    private func prunedRequestDecision(index: Int, receivedAt: TimeInterval) -> PrunedRequestDecision {
        guard let session = session else { return .hold }
        let durations = Self.playerTimeline(session)
        let written = session.progress.segmentsWritten
        let (played, wanted, reportedAt, requests, pruned) = stateLock.withLock {
            (lockedPlayedSeconds, lockedWantedSeconds, lockedPositionsReportedAt, lockedRecentRequests, lockedPruned)
        }
        return Self.prunedRequestDecision(index: index, durations: durations, written: written,
                                          targetDuration: session.targetDuration,
                                          receivedAt: receivedAt, played: played, wanted: wanted, reportedAt: reportedAt,
                                          requests: requests, pruned: pruned)
    }

    // MARK: - Playlists

    private var expectedSegments: Int { session?.expectedSegmentCount ?? 0 }

    /// Movie length on the playlist timeline (what the VOD media playlists
    /// add up to; the header Duration corrected for an end-time Duration),
    /// for the single-segment OpenSubtitles playlists.
    private var movieDurationSeconds: Double {
        guard let session = session else { return 7200 }
        let length = session.playlistDurationSeconds
        if length > 0 { return length }
        let progress = session.progress
        return progress.finished && progress.mediaSeconds > 0 ? progress.mediaSeconds : 7200
    }

    /// The master playlist. Byte-stable once served: the renditions and the
    /// video attributes are fixed once the session is ready (the frame rate
    /// is measured on segment 0, before `onReady`), and BANDWIDTH — estimated
    /// from the input's size, which grows with a sparse download — is the
    /// first one served. Only `subtitles` assigned after a master was served
    /// change it, for the items created after that: their renditions are
    /// added (`externalRenditions` leaves out those whose file failed
    /// definitively first).
    private func masterPlaylist() -> String? {
        guard let session = session, let video = session.video else { return nil }
        let audio = session.audioRenditions
        let embedded = session.subtitleRenditions
        let external = externalRenditions(defaultAllowed: !embedded.contains { $0.isDefault })
        let estimate = session.bandwidthEstimate
        let bandwidth: Int = stateLock.withLock {
            let first = lockedMasterBandwidth ?? estimate
            lockedMasterBandwidth = first
            return first
        }
        let text = HLSPlaylists.master(video: video, audio: audio, subtitles: embedded, external: external,
                                       bandwidth: bandwidth, averageBandwidth: bandwidth * 2 / 3)
        let advertised = external.map { Self.externalKey(fromPath: "/" + $0.uri, suffix: ".m3u8") }
        let firstServe: Bool = stateLock.withLock {
            lockedAdvertisedExternalKeys.formUnion(advertised)
            defer { lockedLoggedMaster = true }
            return !lockedLoggedMaster
        }
        if firstServe {
            let channels = audio.map { "\($0.codecs)/\($0.channels)" }.joined(separator: ", ")
            print("[Remux] master.m3u8 served — \(video.codecs)\(video.supplementalCodecs.map { " + " + $0 } ?? "") \(video.videoRange) · audio [\(channels)] · \(embedded.count) sous-titres intégrés + \(external.count) OpenSubtitles")
        }
        return text
    }

    /// VOD spanning the whole movie (EXTINF adding up to the header's
    /// Duration, frozen the first time one is served: byte-identical for
    /// every rendition and every later request), or EVENT + ENDLIST once
    /// finished when the header has no Duration — built by the session
    /// itself (one implementation for the app and the test harnesses).
    private func mediaPlaylist(named name: String) -> String? {
        session?.mediaPlaylist(named: name)
    }

    // MARK: - External subtitles (OpenSubtitles → WebVTT on demand)

    /// One rendition per language (first subtitle of each language wins —
    /// SubtitlesManager already keeps the best one per language); the first
    /// one in the first preferred language is DEFAULT when `defaultAllowed`
    /// (the movie has no DEFAULT subtitle track of its own). A language
    /// whose file failed DEFINITIVELY (`externalVTT`: its latest attempt,
    /// `ExternalSubtitleFailure.definitive`) is left out, unless a served
    /// master listed it already: those stay listed — no master loses a
    /// rendition to a failure — so an item a recovery rebuilds finds the
    /// options of the one it replaces. A transient failure (no answer, 429,
    /// 5xx) keeps it listed: AVPlayer's request of it tries again.
    /// With no rendition in that language, AVFoundation (OS 27) offers its
    /// own translation into it, which `PlaybackLanguagePreferences` ranks
    /// after OpenSubtitles; the next file in the preferred language, if
    /// any, becomes the DEFAULT one.
    private func externalRenditions(defaultAllowed: Bool) -> [HLSPlaylists.ExternalSubtitle] {
        var seen = Set<String>()
        var result: [HLSPlaylists.ExternalSubtitle] = []
        let preferred = preferredSubtitleLanguages.first.flatMap { MKVToHLSRemuxSession.normalizedLanguage($0) }
        var defaultTaken = !defaultAllowed
        let failed = vttLock.withLock { Set(vttFailures.filter { $0.value.kind == .definitive }.keys) }
        let advertised = stateLock.withLock { lockedAdvertisedExternalKeys }
        for subtitle in subtitles {
            let key = Self.externalKey(for: subtitle)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            if failed.contains(key) && !advertised.contains(key) { continue }
            let language = Self.bcp47(for: subtitle)
            let display = MKVToHLSRemuxSession.languageDisplayName(language) ?? subtitle.language
            var rendition = HLSPlaylists.ExternalSubtitle(name: "\(display) (OpenSubtitles)",
                                                          language: language,
                                                          uri: "sub_\(key).m3u8")
            if !defaultTaken, let preferred = preferred,
               MKVToHLSRemuxSession.normalizedLanguage(language) == preferred {
                rendition.isDefault = true
                defaultTaken = true
            }
            result.append(rendition)
        }
        return result
    }

    private func externalSubtitle(forKey key: String) -> Subtitle? {
        subtitles.first { Self.externalKey(for: $0) == key }
    }

    /// `sub_{key}` is served (never 404): a current subtitle, or one a served
    /// master playlist listed (AVPlayer may still request it).
    private func servesExternalSubtitle(key: String) -> Bool {
        externalSubtitle(forKey: key) != nil || stateLock.withLock { lockedAdvertisedExternalKeys.contains(key) }
    }

    /// A WebVTT without any cue, with the X-TIMESTAMP-MAP a converted file
    /// gets (`withTimestampMap`): the answer for an external subtitle whose
    /// download or conversion failed.
    static func emptyExternalVTT(mpegts: Int64) -> String {
        "WEBVTT\n" + HLSPlaylists.timestampMapLine(mpegts: mpegts) + "\n\n"
    }

    /// BCP 47 tag of an OpenSubtitles language (their own codes mapped by
    /// `Subtitle.bcp47Language`: pb → pt-BR, zt → zh-Hant, sp → es-ES…).
    private static func bcp47(for subtitle: Subtitle) -> String {
        subtitle.ISO639.lowercased() == "pob" ? "pt-BR" : subtitle.bcp47Language
    }

    /// URL-safe key ("fr", "pt-br"): the language code, else the name.
    private static func externalKey(for subtitle: Subtitle) -> String {
        let source = subtitle.ISO639.isEmpty ? subtitle.language : bcp47(for: subtitle)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return String(source.lowercased().unicodeScalars.filter { allowed.contains($0) }.map(Character.init))
    }

    private static func externalKey(fromPath path: String, suffix: String) -> String {
        String(path.dropFirst("/sub_".count).dropLast(suffix.count)).lowercased()
    }

    /// A DEFINITIVE failure of an OpenSubtitles download or conversion
    /// (`ExternalSubtitleFailure`), or the `externalSubtitleTransientAttempts`-th
    /// transient one in a row, is not retried for this long (s): AVPlayer's
    /// retries and the items a recovery rebuilds get the empty WebVTT at once
    /// instead of hitting OpenSubtitles again. Test hook (set before
    /// `start()`): default 60 s.
    static var externalSubtitleRetryInterval: TimeInterval = 60
    /// Transient failures in a row (the prefetch's, then a held request's
    /// retry) after which a key waits `externalSubtitleRetryInterval` like a
    /// definitive failure.
    static let externalSubtitleTransientAttempts = 2
    /// Pause (s) between a transient failure and the next attempt: a server
    /// that answered 429 / 503 (Retry-After), or a network blip, gets a
    /// moment. Test hook (set before `start()`): default 1 s.
    static var externalSubtitleTransientRetryDelay: TimeInterval = 1
    /// How long (s) an attempt that follows a transient failure holds the
    /// requests waiting for it, its pause excluded — or less, a request's
    /// own bound (`externalSubtitleRequestHoldSeconds`) ending first: a slow
    /// retry answers them with the empty WebVTT then, and goes on — its
    /// file, if it comes, serves the next requests. Test hook (set before
    /// `start()`): default 5 s.
    static var externalSubtitleRetryHoldSeconds: TimeInterval = 5
    /// How long (s), at most, a `sub_{key}.vtt` request is held from its
    /// arrival, whatever attempt it waits for (the prefetch's, one it
    /// started, a transient failure's retry): it then gets the empty
    /// WebVTT, and the attempt goes on — its file, if it comes, is cached
    /// for the next requests and the items a recovery rebuilds. AVPlayer
    /// keeps an item that selected the rendition unready until the file is
    /// answered, and the owners give a new item 30 s to become ready (not
    /// extended once the payload is complete), the recovery's rebuild 30 s
    /// too: 15 s leaves a slow but successful download its subtitles on the
    /// first item when it ends within ~15 s of that item's request (~17 s
    /// from the prefetch's start: `onReady` waits up to
    /// `readyFetchHoldSeconds` for it), and that item ~15 s of margin; a
    /// slower file shows only on an item created once it is cached (a
    /// recovery's rebuild). Test hook (set before `start()`): default 15 s.
    static var externalSubtitleRequestHoldSeconds: TimeInterval = 15

    /// How an OpenSubtitles download or conversion failed (`externalVTT`).
    enum ExternalSubtitleFailure: Equatable {
        /// The file can't be had: the server rejected the link (an HTTP 4xx
        /// other than 408 / 425 / 429: 404, 410, 403…), the link can't be
        /// fetched at all (malformed, a redirect loop…), or the file it
        /// served doesn't convert (a quota HTML page, an unparsable file).
        case definitive
        /// It may work in a moment: no answer (timeout, offline, DNS, a
        /// connection lost…), a server error (5xx), a rate limit or a request
        /// timeout (429, 408, 425), a file saved but unreadable, or any error
        /// not recognized as definitive.
        case transient
    }

    /// The latest failed attempt of a key (`externalVTT`).
    struct ExternalSubtitleFailureRecord: Equatable {
        /// Uptime of that failure.
        var at: TimeInterval
        var kind: ExternalSubtitleFailure
        /// Transient failures in a row up to it (0 when it is definitive).
        var transientInARow: Int
    }

    /// The kind of a failed download (pure), from the error
    /// `PopcornKit.downloadSubtitleFile` returned: Alamofire's `AFError`
    /// bridged to NSError (this file does not import Alamofire) — its
    /// description states a rejected status ("Response status code was
    /// unacceptable: 503."), its payload keeps a failed task's URLError
    /// (`sessionTaskFailed`) — or any NSError, its underlying errors
    /// included. nil (neither file nor error): transient.
    static func externalDownloadFailure(_ error: Error?) -> ExternalSubtitleFailure {
        guard let error = error else { return .transient }
        if let status = rejectedHTTPStatus(error) {
            return (400..<500).contains(status) && ![408, 425, 429].contains(status) ? .definitive : .transient
        }
        if let code = urlErrorCode(in: error) {
            return definitiveURLErrorCodes.contains(code) ? .definitive : .transient
        }
        return .transient
    }

    /// URLError codes no retry can fix: a malformed or unsupported link, a
    /// redirect loop or a redirect to nowhere, a missing local file, a link
    /// App Transport Security refuses.
    static let definitiveURLErrorCodes: Set<Int> = [
        NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorHTTPTooManyRedirects,
        NSURLErrorRedirectToNonExistentLocation, NSURLErrorFileDoesNotExist, NSURLErrorFileIsDirectory,
        NSURLErrorNoPermissionsToReadFile, NSURLErrorAppTransportSecurityRequiresSecureConnection,
    ]

    /// The HTTP status a response validation rejected (Alamofire's
    /// `unacceptableStatusCode`, from its description), nil for any other
    /// error.
    static func rejectedHTTPStatus(_ error: Error) -> Int? {
        let marker = "Response status code was unacceptable: "
        let text = (error as NSError).localizedDescription
        guard let range = text.range(of: marker) else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    /// The code of the first URLError in `error`: itself, its
    /// NSUnderlyingErrorKey chain, or an Error stored in its payload (a
    /// Swift error's associated values: AFError's `sessionTaskFailed`) —
    /// a few levels deep at most.
    static func urlErrorCode(in error: Error) -> Int? {
        func search(_ value: Any, depth: Int) -> Int? {
            if let error = value as? Error {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain { return nsError.code }
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error, depth < 4,
                   let code = search(underlying, depth: depth + 1) { return code }
            }
            guard depth < 4 else { return nil }
            for child in Mirror(reflecting: value).children {
                if let code = search(child.value, depth: depth + 1) { return code }
            }
            return nil
        }
        return search(error, depth: 0)
    }

    /// When the next attempt for a key may start (pure): nil — not before
    /// `retryInterval` has passed since a definitive failure, or since the
    /// `transientAttempts`-th transient one in a row (the caller gets no
    /// file); otherwise the delay (s) from `now`: 0 after no failure, the
    /// rest of `transientDelay` after a transient one.
    static func externalAttemptDelay(after failure: ExternalSubtitleFailureRecord?, now: TimeInterval,
                                     retryInterval: TimeInterval, transientAttempts: Int,
                                     transientDelay: TimeInterval) -> TimeInterval? {
        guard let failure = failure else { return 0 }
        if failure.kind == .definitive || failure.transientInARow >= transientAttempts {
            return now - failure.at < retryInterval ? nil : 0
        }
        return max(0, failure.at + transientDelay - now)
    }

    /// When a held `sub_{key}.vtt` request gets the empty WebVTT if no file
    /// came by then (pure, uptime): its own deadline (`deadline`: its
    /// arrival + `externalSubtitleRequestHoldSeconds`), or the end of the
    /// hold of the retry it waits for (`retryHoldEnd`, nil for an attempt
    /// that follows no transient failure) when that comes first.
    static func externalRequestRelease(deadline: TimeInterval, retryHoldEnd: TimeInterval?) -> TimeInterval {
        min(deadline, retryHoldEnd ?? deadline)
    }

    /// Whether a request held for an attempt that just failed transiently
    /// (at `failedAt`) waits for the retry `retryDelay` later (pure): only
    /// when its own deadline ends after that retry's start — otherwise the
    /// retry can't serve it, and it gets the empty WebVTT at once.
    static func externalRequestWaitsForRetry(deadline: TimeInterval, failedAt: TimeInterval,
                                             retryDelay: TimeInterval) -> Bool {
        deadline > failedAt + max(0, retryDelay)
    }

    /// Someone waiting for a key's attempt (`externalVTT`).
    private struct ExternalVTTWaiter {
        /// An HTTP request (`sub_{key}.vtt`): its arrival +
        /// `externalSubtitleRequestHoldSeconds`, the latest it is answered,
        /// whatever attempt it waits for (`externalRequestRelease`: a retry's
        /// hold may end it sooner). nil: the prefetch, answered at the end of
        /// every attempt.
        let deadline: TimeInterval?
        let completion: (Data?) -> Void
        var isRequest: Bool { deadline != nil }
    }

    private var vttCache: [String: Data] = [:]
    /// The latest failed attempt of a key (removed by a successful one).
    private var vttFailures: [String: ExternalSubtitleFailureRecord] = [:]
    /// Keys whose failure was logged (once per key).
    private var vttLoggedFailures = Set<String>()
    /// Keys with an attempt in flight — or about to start, a transient
    /// failure's retry — and who waits for it. A waiter leaves it when it is
    /// answered (the attempt's end, its release, `stop()`), under `vttLock`:
    /// nothing is answered twice.
    private var vttWaiters: [String: [ExternalVTTWaiter]] = [:]
    /// Keys whose attempt in flight follows a transient failure: when the
    /// requests it holds stop waiting (uptime, `externalSubtitleRetryHoldSeconds`).
    private var vttRetryHoldEnds: [String: TimeInterval] = [:]
    /// `stop()` ran: no request is held, no attempt starts.
    private var vttClosed = false
    private let vttLock = NSLock()

    /// The converted WebVTT of `key`; nil when it can't be had: the download
    /// or the conversion failed — definitively, or transiently
    /// `externalSubtitleTransientAttempts` times in a row (negative-cached
    /// for `externalSubtitleRetryInterval` either way) — or the key is no
    /// longer in `subtitles`; nil too when it comes too late for a request:
    /// its hold ran out (the attempt goes on), or `stop()` ran. Fetched when
    /// AVPlayer asks for `sub_{key}.vtt` (`isRequest`), or ahead of the
    /// master playlist for the preferred language
    /// (`prefetchPreferredExternalSubtitle`); one attempt per key at a time.
    /// After a transient failure, the next attempt starts
    /// `externalSubtitleTransientRetryDelay` later: at the next request, or
    /// at once for the requests that waited for the failed one and still
    /// may — held at most `externalSubtitleRetryHoldSeconds` beyond that
    /// pause. Whatever it waits for, a request is held at most
    /// `externalSubtitleRequestHoldSeconds` from now (`releaseExternalRequests`).
    private func externalVTT(forKey key: String, isRequest: Bool, completion: @escaping (Data?) -> Void) {
        vttLock.lock()
        if let cached = vttCache[key] { vttLock.unlock(); completion(cached); return }
        // stop() ran: nothing waits (a request's handler answers 410).
        if vttClosed { vttLock.unlock(); completion(nil); return }
        let now = Self.uptime
        let waiter = ExternalVTTWaiter(deadline: isRequest ? now + Self.externalSubtitleRequestHoldSeconds : nil,
                                       completion: completion)
        if vttWaiters[key] != nil {
            // An attempt for this language is in flight (or due) — a retry
            // past its hold no longer keeps a request waiting.
            if let deadline = waiter.deadline,
               Self.externalRequestRelease(deadline: deadline, retryHoldEnd: vttRetryHoldEnds[key]) <= now {
                vttLock.unlock()
                completion(nil)
                return
            }
            vttWaiters[key]?.append(waiter)
            if let deadline = waiter.deadline { releaseExternalRequests(key: key, at: deadline, retryHold: false) }
            vttLock.unlock()
            return
        }
        guard let delay = Self.externalAttemptDelay(after: vttFailures[key], now: now,
                                                    retryInterval: Self.externalSubtitleRetryInterval,
                                                    transientAttempts: Self.externalSubtitleTransientAttempts,
                                                    transientDelay: Self.externalSubtitleTransientRetryDelay),
              externalSubtitle(forKey: key) != nil else {
            vttLock.unlock()
            completion(nil)
            return
        }
        vttWaiters[key] = [waiter]
        let holdEnd = vttFailures[key]?.kind == .transient ? now + delay + Self.externalSubtitleRetryHoldSeconds : nil
        vttRetryHoldEnds[key] = holdEnd
        if let deadline = waiter.deadline { releaseExternalRequests(key: key, at: deadline, retryHold: false) }
        if let end = holdEnd { releaseExternalRequests(key: key, at: end, retryHold: true) }
        vttLock.unlock()
        startExternalAttempt(key: key, after: delay)
    }

    /// At `time` (uptime) — a request's deadline, or the end of a retry's
    /// hold (`retryHold`) — answers with nil, the empty WebVTT, every
    /// request held for `key`'s attempt whose release
    /// (`externalRequestRelease`) is due by then. The attempt goes on: its
    /// file, if it comes, is cached. A request answered meanwhile (its
    /// attempt ended, `stop()` ran) no longer waits: nothing is answered
    /// twice, and nothing after `stop()`. One-shot timer, 50 ms leeway.
    private func releaseExternalRequests(key: String, at time: TimeInterval, retryHold: Bool) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + max(0, time - Self.uptime), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            // One shot (and the handler lets go of the timer it retains).
            timer.cancel()
            guard let self = self else { return }
            self.vttLock.lock()
            let holdEnd = self.vttRetryHoldEnds[key]
            let due = { (waiter: ExternalVTTWaiter) -> Bool in
                waiter.deadline.map { Self.externalRequestRelease(deadline: $0, retryHoldEnd: holdEnd) <= time } ?? false
            }
            let waiting = self.vttWaiters[key] ?? []
            let released = waiting.filter(due)
            if !released.isEmpty { self.vttWaiters[key] = waiting.filter { !due($0) } }
            self.vttLock.unlock()
            guard !released.isEmpty else { return }
            print("[Remux] sub_\(key).vtt: " + (retryHold
                ? "the OpenSubtitles retry takes longer than " + String(format: "%g s", Self.externalSubtitleRetryHoldSeconds)
                : "no OpenSubtitles file " + String(format: "%g s", Self.externalSubtitleRequestHoldSeconds) + " after the request")
                + ": an empty WebVTT for the \(released.count) request(s) waiting, the download goes on")
            released.forEach { $0.completion(nil) }
        }
        timer.resume()
    }

    /// Downloads and converts `key`'s file `delay` s from now for its
    /// waiters (`vttWaiters`), then `finishExternalAttempt`.
    private func startExternalAttempt(key: String, after delay: TimeInterval) {
        guard delay <= 0 else {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.startExternalAttempt(key: key, after: 0)
            }
            return
        }
        guard !isStopped, let subtitle = externalSubtitle(forKey: key) else {
            finishExternalAttempt(key: key, data: nil, failure: nil)
            return
        }
        // MicroDVD files are timed in frames: the remuxed video's own frame
        // rate beats OpenSubtitles' MovieFPS (which describes the release the
        // subtitle was made for).
        let videoFrameRate = session?.video?.frameRate
        // One file per language: two languages whose downloads suggest the
        // same file name must not overwrite each other.
        let directory = outputDir
        PopcornKit.downloadSubtitleFile(subtitle.link, fileName: "sub_\(key)", downloadDirectory: directory) { [weak self] fileURL, error in
            DispatchQueue.global(qos: .userInitiated).async {
                // Stopped meanwhile (the player closed during the download):
                // the download recreated the output directory `stop()`
                // deletes — delete it again.
                guard let self = self, !self.isStopped else {
                    try? FileManager.default.removeItem(at: directory)
                    self?.finishExternalAttempt(key: key, data: nil, failure: nil)
                    return
                }
                guard let fileURL = fileURL else {
                    let reason = error.flatMap { error in
                        Self.rejectedHTTPStatus(error).map { "HTTP \($0)" } ?? Self.urlErrorCode(in: error).map { "URL error \($0)" }
                    }
                    self.finishExternalAttempt(key: key, data: nil, failure: (Self.externalDownloadFailure(error),
                        "OpenSubtitles download failed (\(subtitle.ISO639)\(reason.map { ", " + $0 } ?? ""))"))
                    return
                }
                guard let raw = try? Data(contentsOf: fileURL) else {
                    self.finishExternalAttempt(key: key, data: nil,
                                               failure: (.transient, "OpenSubtitles file unreadable (\(subtitle.ISO639))"))
                    return
                }
                // Encoding (SubEncoding / BOM / language code page), format
                // (SRT, MicroDVD, SubViewer, ASS…) → WebVTT, without the
                // converter's MPEGTS:0 map: the right one is added below.
                guard let vtt = SubtitleConversion.webVTT(fromSubtitleData: raw,
                                                          formatHint: subtitle.format,
                                                          encodingHint: subtitle.encoding,
                                                          languageHint: subtitle.ISO639,
                                                          frameRate: videoFrameRate ?? subtitle.frameRate,
                                                          timestampMap: false) else {
                    self.finishExternalAttempt(key: key, data: nil,
                                               failure: (.definitive, "OpenSubtitles file not convertible (\(subtitle.ISO639), \(subtitle.format ?? "?"))"))
                    return
                }
                // Read now: segment 0 — the timeline's start — exists (AVPlayer
                // asks for a .vtt after the master playlist, and the preferred
                // file is fetched ahead of it only once segment 0 exists).
                let start90k = self.session?.timelineStart90k ?? 0
                self.finishExternalAttempt(key: key, data: Data(Self.withTimestampMap(vtt, mpegts: start90k).utf8), failure: nil)
            }
        }
    }

    /// The end of an attempt for `key`: caches the file, or records the
    /// failure (`failure`: its kind and log text; nil when the remux was
    /// stopped or the key withdrawn: nothing recorded) — then answers the
    /// waiters, except that after a transient failure below
    /// `externalSubtitleTransientAttempts` in a row the HTTP requests whose
    /// own deadline ends after the next attempt's start
    /// (`externalRequestWaitsForRetry`) stay held for it,
    /// `externalSubtitleTransientRetryDelay` later
    /// (`externalSubtitleRetryHoldSeconds` at most beyond that pause, never
    /// past their deadline).
    private func finishExternalAttempt(key: String, data: Data?,
                                       failure: (kind: ExternalSubtitleFailure, text: String)?) {
        vttLock.lock()
        let now = Self.uptime
        var record: ExternalSubtitleFailureRecord?
        if let data = data {
            vttCache[key] = data
            vttFailures[key] = nil
        } else if let failure = failure {
            let previous = vttFailures[key].flatMap { $0.kind == .transient ? $0.transientInARow : nil } ?? 0
            record = ExternalSubtitleFailureRecord(at: now, kind: failure.kind,
                                                   transientInARow: failure.kind == .transient ? previous + 1 : 0)
            vttFailures[key] = record
        }
        vttRetryHoldEnds[key] = nil
        let mayRetry = !vttClosed && record.map {
            $0.kind == .transient && $0.transientInARow < Self.externalSubtitleTransientAttempts
        } == true
        var answered: [ExternalVTTWaiter] = []
        var held: [ExternalVTTWaiter] = []
        for waiter in vttWaiters.removeValue(forKey: key) ?? [] {
            if mayRetry, let deadline = waiter.deadline,
               Self.externalRequestWaitsForRetry(deadline: deadline, failedAt: now,
                                                 retryDelay: Self.externalSubtitleTransientRetryDelay) {
                held.append(waiter)
            } else {
                answered.append(waiter)
            }
        }
        let retry = !held.isEmpty
        if retry {
            let holdEnd = now + Self.externalSubtitleTransientRetryDelay + Self.externalSubtitleRetryHoldSeconds
            vttWaiters[key] = held
            vttRetryHoldEnds[key] = holdEnd
            releaseExternalRequests(key: key, at: holdEnd, retryHold: true)
        }
        let answeredRequests = answered.filter(\.isRequest).count
        let firstFailure = record != nil && vttLoggedFailures.insert(key).inserted
        vttLock.unlock()
        if let record = record, let failure = failure {
            let pause = String(format: "%g s", Self.externalSubtitleTransientRetryDelay)
            let empty = "an empty WebVTT (no subtitles), the download is retried after "
                + "\(Int(Self.externalSubtitleRetryInterval)) s at the earliest"
            if firstFailure {
                // The line naming the language, once per key. Listed by a
                // served master: AVPlayer may ask for it; else the masters
                // leave a definitive failure out (`externalRenditions`).
                let listed = stateLock.withLock { lockedAdvertisedExternalKeys.contains(key) }
                print("[Remux] \(failure.text): " + (record.kind == .transient
                    ? "temporary — sub_\(key) stays listed and is tried again \(pause) later for a request of it "
                        + "(\(Self.externalSubtitleTransientAttempts) attempts in a row at most, then like a definitive failure)"
                    : listed
                        ? "sub_\(key).vtt is served as " + empty
                        : "sub_\(key) is left out of the master playlists served from now on (no OpenSubtitles rendition in that language)"))
            } else if !mayRetry && answeredRequests > 0 {
                print("[Remux] sub_\(key).vtt: OpenSubtitles failed again"
                      + (record.kind == .transient ? " (\(record.transientInARow) attempts in a row)" : ", definitively")
                      + " — " + empty)
            }
            if mayRetry && answeredRequests > 0 {
                print("[Remux] sub_\(key).vtt: an empty WebVTT for the \(answeredRequests) request(s) waiting whose "
                      + String(format: "%g s", Self.externalSubtitleRequestHoldSeconds)
                      + " hold ends before another attempt could start")
            }
            if retry {
                print("[Remux] sub_\(key).vtt: another OpenSubtitles attempt in \(pause) for the \(held.count) request(s) waiting")
            }
        }
        if retry { startExternalAttempt(key: key, after: Self.externalSubtitleTransientRetryDelay) }
        answered.forEach { $0.completion(data) }
    }

    /// External files are timed from the movie's start, while AVPlayer's
    /// clock starts at 0 on the first frame, i.e. at the media time
    /// `mpegts` (90 kHz: the session's `timelineStart90k` — 600 s for a file
    /// cut with ffmpeg -copyts, ~0 normally). Maps the file's local 0 there;
    /// any map already present is replaced (see `HLSPlaylists.withTimestampMap`).
    static func withTimestampMap(_ vtt: String, mpegts: Int64 = 0) -> String {
        HLSPlaylists.withTimestampMap(vtt, mpegts: mpegts)
    }

    // MARK: - Pump

    private func makeOptions() -> MKVToHLSRemuxSession.Options {
        var options = MKVToHLSRemuxSession.Options()
        options.releaseTaggedAtmos = isAtmos
        options.releaseHintsHDR = releaseHintsHDR
        options.preferredAudioLanguages = preferredAudioLanguages
        options.preferredSubtitleLanguages = preferredSubtitleLanguages
        return options
    }

    /// The input file is final. No streamer from the start = a local / already
    /// downloaded file. Otherwise only a COMPLETE download counts:
    /// `totalProgress` is libtorrent's progress_ppm / 1e6 and reaches exactly
    /// 1.0 once every wanted piece is verified (PopcornTorrent's finished
    /// alert also sets 1); at 0.999 up to 0.1 % of the file — tens of MB on a
    /// 4K remux — can still be zero-filled, and `markInputComplete()` would
    /// make the demuxer take those holes for data (corrupt frames, early
    /// finish that truncates the movie). A streamer that was handed in and
    /// has since been released does not count as complete either.
    private var isInputComplete: Bool {
        guard let streamer = streamer else { return !stateLock.withLock { lockedHadStreamer } }
        return streamer.torrentStatus.totalProgress >= 1.0
    }

    /// Segments in one lookahead window (`lookaheadSeconds` on the target
    /// grid): the window within which `lookaheadAnchor` keeps a request
    /// older than the owner's latest report.
    static func lookaheadSegments(targetDuration: Double) -> Int {
        max(1, Int((lookaheadSeconds / max(0.5, targetDuration)).rounded(.up)))
    }

    /// One past the last segment the pump may write for `anchor` (pure):
    /// every segment that starts less than `lookahead` after the anchor's
    /// start on the player timeline `durations` (`playerTimeline`; past its
    /// end, the target grid), at least the anchor itself. All of them lie in
    /// the region the disk budget protects around the anchor, [start −
    /// 3 min, start + L] (`evictionVictims`) — also when segments are longer
    /// than the target (a long GOP is one segment): a pump step never writes
    /// what the next eviction pass deletes. anchor + `lookaheadSegments` on
    /// a regular target grid.
    static func lookaheadLimit(anchor: Int, durations: [Double], targetDuration: Double,
                               lookahead: Double = RemuxPlayback.lookaheadSeconds) -> Int {
        let first = max(0, anchor)
        let target = max(0.5, targetDuration)
        var start = segmentStart(index: first, durations: durations, targetDuration: target)
        let end = start + max(0, lookahead)
        var limit = first
        while start < end {
            start += limit < durations.count ? max(0, durations[limit]) : target
            limit += 1
        }
        return max(first + 1, limit)
    }

    /// The segment the lookahead is anchored on (the pump may write up to
    /// `lookaheadLimit`, and keeps bursting until anchor + 3):
    /// the furthest of the segments covering `played` and `wanted` (on the
    /// player timeline `durations`, `playerTimeline`) and of the requested
    /// segments that are still wanted. A request is still wanted
    /// while it is recent (`requestAnchorLifetime`, at `now`) and, once the
    /// owner reports positions (`reportedAt`), either newer than its latest
    /// report or within one lookahead window of the segment of `wanted`
    /// (`played` when `wanted` is nil): a report of a position far below a
    /// stale far request supersedes it at once. Without reports, recency
    /// alone decides. `requests`: segment index → uptime of its latest
    /// request. 0 when nothing is known.
    static func lookaheadAnchor(played: Double?, wanted: Double?, reportedAt: TimeInterval?,
                                requests: [Int: TimeInterval], now: TimeInterval,
                                durations: [Double], targetDuration: Double) -> Int {
        func segment(_ seconds: Double) -> Int {
            segmentIndex(coveringPlayerSeconds: seconds, durations: durations, targetDuration: targetDuration)
        }
        var anchor = 0
        if let played = played { anchor = max(anchor, segment(played)) }
        if let wanted = wanted { anchor = max(anchor, segment(wanted)) }
        let reference = (wanted ?? played).map(segment)
        let window = lookaheadSegments(targetDuration: targetDuration)
        for (index, at) in requests where index > anchor && now - at <= requestAnchorLifetime {
            if let reportedAt = reportedAt, at <= reportedAt, let reference = reference, index > reference + window {
                continue // superseded by the owner's latest report
            }
            anchor = index
        }
        return anchor
    }

    /// `lookaheadAnchor` on the current state, on the player timeline
    /// (`playerTimeline`; drops the requests that aged out).
    private func currentLookaheadAnchor(_ session: MKVToHLSRemuxSession) -> Int {
        currentLookaheadAnchor(durations: Self.playerTimeline(session), targetDuration: session.targetDuration)
    }

    /// `lookaheadAnchor` on the current state with these player-timeline
    /// `durations` (drops the requests that aged out).
    private func currentLookaheadAnchor(durations: [Double], targetDuration: Double) -> Int {
        let now = Self.uptime
        let (played, wanted, reportedAt, requests) = stateLock.withLock {
            () -> (Double?, Double?, TimeInterval?, [Int: TimeInterval]) in
            lockedRecentRequests = lockedRecentRequests.filter { now - $0.value <= Self.requestAnchorLifetime }
            return (lockedPlayedSeconds, lockedWantedSeconds, lockedPositionsReportedAt, lockedRecentRequests)
        }
        return Self.lookaheadAnchor(played: played, wanted: wanted, reportedAt: reportedAt, requests: requests,
                                    now: now, durations: durations, targetDuration: targetDuration)
    }

    private func tick() {
        guard !isStopped, !failed, failureReason == nil else { return }
        if lockedSessionValue == nil {
            do {
                let created = try MKVToHLSRemuxSession(inputFile: inputFile, outputDirectory: outputDir, options: makeOptions())
                stateLock.withLock { lockedSession = created }
            } catch {
                waitingTicks += 1
                if waitingTicks > 90 { fail("Remux : fichier vidéo introuvable") }
                return
            }
        }
        guard let session = lockedSessionValue else { return }
        let inputComplete = isInputComplete
        if inputComplete { session.markInputComplete() }

        if !prepared {
            switch session.prepare() {
            case .ready:
                prepared = true
            case .unsupported(let reason):
                // P0: never leave AVPlayer spinning on something it can't
                // play — the caller switches to VLC right away.
                fail(reason)
                return
            case .needMoreData:
                waitingTicks += 1
                if inputComplete { stalledCompleteTicks += 1 }
                if !session.isHeaderParsed && waitingTicks > 90 {
                    fail("Remux : en-têtes MKV illisibles")
                } else if waitingTicks > 240 || stalledCompleteTicks > 3 {
                    fail("Remux : aucune image vidéo exploitable")
                }
                return
            }
        }

        // Pump. Normal budget: 6 segments per tick (a mostly-downloaded file
        // must not remux in one giant I/O burst that starves AVPlayer's own
        // reads); while the anchor (a seek or resume target, a request past
        // the frontier) is ahead of what exists, keep going for up to ~0.8 s
        // per tick. Never past the lookahead limit (disk use). Held requests
        // are resolved as soon as their segment is committed. The disk budget
        // is enforced before the first write and after every step, so a
        // pump-ahead on a tight disk deletes what it skips as it writes it. A
        // write that failed (disk full: another writer, the torrent) gets a
        // fresh budget evaluation and an eviction pass at once, and again
        // before its retry at the next tick (`maxWriteAttempts` ticks in all).
        // The anchor is re-evaluated after every step: a report that
        // supersedes a far request stops a burst toward it at once. An anchor
        // the pump writes toward, or whose whole lookahead is written already,
        // raises the sticky budget anchor (`stickyBudgetAnchor`).
        // The target is read afresh at every step: the session may settle it
        // when it cuts segment 0.
        let tickStart = Date()
        var anchor = currentLookaheadAnchor(session)
        enforceDiskBudget(.pump, forceEvaluation: session.isWaitingToWrite, anchor: anchor)
        var produced = 0
        var heldAtLimit = false
        while true {
            let before = session.progress.segmentsWritten
            let limit = Self.lookaheadLimit(anchor: anchor, durations: Self.playerTimeline(session),
                                            targetDuration: session.targetDuration)
            if before >= limit { heldAtLimit = true; raiseStickyAnchor(to: anchor); break }
            let count = session.pump(maxNewSegments: min(2, limit - before))
            produced += count
            if count > 0 {
                raiseStickyAnchor(to: anchor)
                resolveHeldRequestsSoon()
            }
            if session.isWaitingToWrite {
                enforceDiskBudget(.pump, forceEvaluation: true, anchor: anchor)
                break
            }
            if count == 0 { break }
            anchor = currentLookaheadAnchor(session)
            enforceDiskBudget(.pump, anchor: anchor)
            let written = session.progress.segmentsWritten
            if produced >= 6 && written >= anchor + 3 { break }
            if Date().timeIntervalSince(tickStart) > 0.8 { break }
        }
        if let reason = session.writeFailure {
            haltAfterWriteFailure(reason)
            return
        }

        var progress = session.progress
        if !progress.finished {
            // Ticks held at the lookahead limit or retrying a failed write
            // say nothing about the input being exhausted: not idle (else a
            // complete file would be finished long before its end).
            if heldAtLimit || session.isWaitingToWrite {
                idleTicks = 0
            } else {
                idleTicks = produced == 0 ? idleTicks + 1 : 0
            }
            if inputComplete && idleTicks >= 3 {
                session.finish()
                progress = session.progress
                stateLock.withLock { lockedFinished = true }
                stateLock.withLock { pumpTimer?.cancel(); pumpTimer = nil }
                if let reason = session.writeFailure {
                    haltAfterWriteFailure(reason)
                    return
                }
                // Any tail filler the list needs exists now, and anything past
                // the list's end never will.
                resolveHeldRequestsSoon()
                if progress.segmentsWritten == 0 {
                    fail("Remux : aucun segment produit")
                    return
                }
            }
        }

        fireReadyIfDue(countsHoldTick: true)
    }

    /// How long (s) `onReady` may wait for the preferred-language
    /// OpenSubtitles file beyond the `externalSubtitlesPending` hold — only
    /// while that file is being fetched (`fireReadyIfDue`).
    static let readyFetchHoldSeconds: TimeInterval = 2

    /// Fires `onReady` once (pump queue) as soon as playback can start: two
    /// segments are written (one once the remux finished); a pending
    /// OpenSubtitles search had up to 5 ticks to land in the master playlist
    /// (`externalSubtitlesPending`, unless the remux finished: AVPlayer
    /// fetches it only once — only the pump's ticks, `countsHoldTick`,
    /// count); and the preferred-language OpenSubtitles file, while it is
    /// being fetched (`prefetchPreferredExternalSubtitle`), had up to
    /// `readyFetchHoldSeconds` more, so that a file which definitively can't
    /// be shown is left out of the master (`externalRenditions`). Called by
    /// every tick, when that fetch ends and when its time is up.
    private func fireReadyIfDue(countsHoldTick: Bool) {
        guard !readyFired, !failed, !isStopped, failureReason == nil, let session = lockedSessionValue else { return }
        let progress = session.progress
        let preferredKey = prefetchPreferredExternalSubtitle()
        let enough = progress.segmentsWritten >= 2 || (progress.finished && progress.segmentsWritten >= 1)
        guard enough else { return }
        // Give a pending OpenSubtitles search a few seconds to land in
        // the master playlist (fetched only once by AVPlayer).
        if externalSubtitlesPending && readyHoldTicks < 5 && !progress.finished {
            if countsHoldTick { readyHoldTicks += 1 }
            return
        }
        // Then the preferred-language file, while it downloads (a definitive
        // failure leaves it out of the master: AVFoundation may translate
        // instead).
        if let key = preferredKey, vttLock.withLock({ vttWaiters[key] != nil }) {
            if readyFetchDeadline == nil {
                let deadline = DispatchTime.now() + Self.readyFetchHoldSeconds
                readyFetchDeadline = deadline
                workQueue.asyncAfter(deadline: deadline) { [weak self] in self?.fireReadyIfDue(countsHoldTick: false) }
                print("[Remux] playback ready once the preferred OpenSubtitles file sub_\(key) is fetched "
                      + "(\(Int(Self.readyFetchHoldSeconds)) s at most)")
            }
            if let deadline = readyFetchDeadline, DispatchTime.now() < deadline { return }
            print("[Remux] the preferred OpenSubtitles file sub_\(key) is still downloading after "
                  + "\(Int(Self.readyFetchHoldSeconds)) s: the master playlist lists it anyway")
        }
        readyFired = true
        let url = URL(string: "http://127.0.0.1:\(server.port)/master.m3u8")!
        print("[Remux] playback ready: \(progress.segmentsWritten)/\(expectedSegments) segments — \(url)")
        for line in renditionSummary { print("[Remux]   \(line)") }
        let callback = onReady
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isStopped else { return }
            callback?(url)
        }
    }

    /// Starts fetching, once, the OpenSubtitles file the master playlist
    /// flags DEFAULT (`externalRenditions`: the first preferred language,
    /// when the movie has no non-forced subtitle track of its own in it) —
    /// as soon as the list is known (`subtitles`), the session is prepared
    /// (its own tracks decide) and segment 0 exists (the conversion maps the
    /// file to the timeline's start). A definitive failure learned before a
    /// master is served leaves that file out of it; the next file in the
    /// preferred language, if any, then becomes the DEFAULT one and is
    /// fetched in turn. A transient one keeps it listed (and DEFAULT):
    /// AVPlayer's request of it tries again (`externalVTT`). The end of each
    /// fetch re-checks the ready hold (`fireReadyIfDue`).
    /// Returns the key of that DEFAULT file (nil: none). Pump queue.
    @discardableResult
    private func prefetchPreferredExternalSubtitle() -> String? {
        guard prepared, !isStopped, let session = lockedSessionValue, session.progress.segmentsWritten >= 1 else { return nil }
        let defaultAllowed = !session.subtitleRenditions.contains { $0.isDefault }
        guard let rendition = externalRenditions(defaultAllowed: defaultAllowed).first(where: { $0.isDefault }) else { return nil }
        let key = Self.externalKey(fromPath: "/" + rendition.uri, suffix: ".m3u8")
        if prefetchedExternalKeys.insert(key).inserted {
            externalVTT(forKey: key, isRequest: false) { [weak self] _ in
                guard let self = self else { return }
                self.workQueue.async { [weak self] in self?.fireReadyIfDue(countsHoldTick: false) }
            }
        }
        return key
    }

    private var lockedSessionValue: MKVToHLSRemuxSession? { stateLock.withLock { lockedSession } }

    /// A segment's files couldn't be written `maxWriteAttempts` times in a
    /// row (disk full…). Before `onReady`: `onFailure` (VLC reads the torrent
    /// file itself and needs no extra disk). After it: the pump stops for
    /// good, `failureReason` is set and `onHalted(reason)` is called once on
    /// main (never after `stop()`), so the player hands over to VLC at the
    /// current position at once. What exists keeps being served; every
    /// request for a segment that will never exist gets 404 at once
    /// (`isBeyondEnd`) — held ones included — instead of being held:
    /// AVPlayer would retry those 404s for about 30 s before posting
    /// FailedToPlayToEnd (-1100). The output directory is left to `stop()`
    /// (the player stops this object when it hands off). Pump queue only.
    private func haltAfterWriteFailure(_ reason: String) {
        guard readyFired else {
            fail(reason)
            return
        }
        let first: Bool = stateLock.withLock {
            defer { if lockedFailureReason == nil { lockedFailureReason = reason } }
            return lockedFailureReason == nil
        }
        stateLock.withLock { pumpTimer?.cancel(); pumpTimer = nil }
        guard first else { return }
        let written = lockedSessionValue?.progress.segmentsWritten ?? 0
        print("[Remux] write failure after playback started — remux halted at \(written) segments: \(reason)")
        resolveHeldRequestsSoon()
        // After the onReady dispatch (same main queue, FIFO).
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isStopped else { return }
            self.onHalted?(reason)
        }
    }

    /// Pump queue only. Reports at most once, never after `onReady`.
    private func fail(_ message: String) {
        guard !failed, !readyFired else { return }
        failed = true
        stateLock.withLock { if lockedFailureReason == nil { lockedFailureReason = message } }
        print("[Remux] FAIL: \(message)")
        stop()
        // Capture the callback itself: the VLC fallback must be triggered
        // even if the owner lets go of this object meanwhile.
        let callback = onFailure
        DispatchQueue.main.async { callback?(message) }
    }

    // MARK: - Segment pruning

    /// Numeric index of a media segment (`vsegN.m4s`, `a{i}segN.m4s`,
    /// `s{j}segN.vtt`), nil for init segments / anything else.
    static func segmentIndex(_ name: String) -> Int? {
        guard name.hasSuffix(".m4s") || name.hasSuffix(".vtt"),
              let range = name.range(of: "seg", options: .backwards) else { return nil }
        let digits = name[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Rendition number of `audio{i}_init.mp4` / `a{i}seg…` / `s{j}seg…`.
    private static func renditionNumber(_ name: String) -> Int? {
        let body: Substring
        if name.hasPrefix("audio") { body = name.dropFirst("audio".count) }
        else if name.hasPrefix("a") || name.hasPrefix("s") { body = name.dropFirst() }
        else { return nil }
        let digits = body.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Segment `index` was deleted for good. Index 0 never is: any fresh
    /// AVPlayerItem (a starvation rebuild, an audio-rendition restore) loads
    /// it first, whatever its target.
    private func isPruned(_ index: Int) -> Bool {
        index > 0 && stateLock.withLock { lockedPruned.contains(index) }
    }

    /// A media segment request: anchors the lookahead while it is still
    /// wanted (`lookaheadAnchor`); evidence of where AVPlayer plays for
    /// `prunedRequestDecision`.
    private func noteRequested(_ index: Int) {
        let now = Self.uptime
        stateLock.withLock { lockedRecentRequests[index] = now }
    }

    /// The segment durations AVPlayer's clock runs on — the PLAYER timeline:
    /// the EXTINF list every media playlist of the session serves, i.e. its
    /// frozen VOD list (`playerTimelineDurations()`, which can differ from
    /// what the remux really cuts), else — an EVENT session, whose playlists
    /// list the written segments, or a VOD one before its first playlist —
    /// the durations of the segments written so far. Every position (`played`,
    /// `wanted`, `isAvailable`, the callback's argument), anchor and segment
    /// span is mapped through it (past its end: the target grid); byte and
    /// rate maths keep `segmentDurations()`.
    private static func playerTimeline(_ session: MKVToHLSRemuxSession) -> [Double] {
        session.playerTimelineDurations() ?? session.segmentDurations()
    }

    /// Index of the segment whose span [start, end) holds `playerSeconds`
    /// (0-based) on the player timeline `durations` (`playerTimeline`) —
    /// past its end: estimated on the target grid.
    static func segmentIndex(coveringPlayerSeconds playerSeconds: Double, durations: [Double], targetDuration: Double) -> Int {
        var elapsed = 0.0
        for (index, duration) in durations.enumerated() {
            elapsed += duration
            if playerSeconds < elapsed { return index }
        }
        return durations.count + Int(max(0, playerSeconds - elapsed) / max(0.5, targetDuration))
    }

    /// Start (s) of segment `index` on the player timeline `durations`: the
    /// sum of the durations before it — past their end, estimated on the
    /// target grid (the inverse of `segmentIndex(coveringPlayerSeconds:…)`).
    static func segmentStart(index: Int, durations: [Double], targetDuration: Double) -> Double {
        let written = min(max(0, index), durations.count)
        return durations.prefix(written).reduce(0, +)
            + Double(max(0, index - durations.count)) * max(0.5, targetDuration)
    }

    /// Thin wrapper kept for the test harnesses: equivalent to
    /// `updatePlaybackPositions(played: playheadSeconds, wanted: playheadSeconds)`,
    /// `playheadSeconds` being a position playback actually REACHED. It moves
    /// the lookahead there; over the disk budget, the segments furthest from
    /// it go first — never segment 0, nor those overlapping
    /// [playheadSeconds − `minimumKeepBehindSeconds`, playheadSeconds + L].
    func pruneSegments(playheadSeconds: Double) {
        updatePlaybackPositions(played: playheadSeconds, wanted: playheadSeconds)
    }

    /// Logs (once per episode) a reported `wanted` position past the remuxed
    /// range (the player-timeline start of the next segment to write) while
    /// the remux is still producing: the pump runs ahead to it.
    private func noteWantedPastRemux(_ wanted: Double?) {
        guard let session = session else { return }
        let progress = session.progress
        let remuxed = Self.segmentStart(index: progress.segmentsWritten, durations: Self.playerTimeline(session),
                                        targetDuration: session.targetDuration)
        let past = wanted.map { !progress.finished && $0 > remuxed + session.targetDuration } ?? false
        let episodeStarts: Bool = stateLock.withLock {
            defer { lockedWantedPastRemux = past }
            return past && !lockedWantedPastRemux
        }
        if episodeStarts, let wanted = wanted {
            print("[Remux] wanted position \(String(format: "%.1f", wanted)) s is past the remuxed range "
                  + "(\(String(format: "%.1f", remuxed)) s): the remux pumps ahead to it")
        }
    }

    // MARK: - Disk budget

    /// Who runs an eviction pass (`enforceDiskBudget`).
    private enum BudgetPass {
        /// The pump queue: the budget is re-evaluated first when stale, and
        /// the files are deleted at once (the next write finds the space).
        case pump
        /// An owner's report (main): a stale budget is re-evaluated on
        /// `budgetQueue` (which then runs its own pass); the files are deleted
        /// on a background queue.
        case report
        /// `budgetQueue`, right after an evaluation: the files are deleted at
        /// once.
        case afterEvaluation
    }

    /// Evicts, in every rendition, what the disk budget doesn't allow: while
    /// the deletable segments kept on disk exceed the allowance of the latest
    /// evaluation, the unprotected one furthest from the positions
    /// (`budgetPositions`: `played` and `wanted`, 0 while neither is
    /// reported, the start of the lookahead anchor — `anchor`, else the
    /// current one — and the start of the sticky budget anchor, first moved
    /// down to the lookahead anchor when it no longer reaches the positions:
    /// `stickyBudgetAnchor`) goes first (`evictionVictims`).
    /// `forceEvaluation` (the pump, after a failed write) re-evaluates the
    /// budget first whatever its age. Each index goes into `prunedIndexes`
    /// first (404 / `onUnavailableSegmentRequested` from then on), then its
    /// files are deleted. Any thread; passes are serialized (`pruneLock`).
    private func enforceDiskBudget(_ pass: BudgetPass, forceEvaluation: Bool = false, anchor: Int? = nil) {
        guard let session = session else { return }
        switch pass {
        case .pump: if forceEvaluation || budgetIsStale { evaluateDiskBudget() }
        case .report: scheduleBudgetEvaluationIfStale()
        case .afterEvaluation: break
        }
        // Segment spans and positions on the player timeline; bytes as written.
        let durations = Self.playerTimeline(session)
        let bytes = session.segmentBytes()
        let target = session.targetDuration
        let anchorIndex = anchor ?? currentLookaheadAnchor(durations: durations, targetDuration: target)
        let anchorStart = Self.segmentStart(index: anchorIndex, durations: durations, targetDuration: target)
        let (victims, allowed, positions, pruned): ([Int], Int64, [Double], IndexSet) = pruneLock.withLock {
            let (played, wanted, pruned, allowed, stickyStart) = stateLock.withLock {
                () -> (Double?, Double?, IndexSet, Int64, Double?) in
                let sticky = Self.stickyBudgetAnchor(lockedStickyAnchor, anchor: anchorIndex,
                                                     played: lockedPlayedSeconds, wanted: lockedWantedSeconds,
                                                     durations: durations, targetDuration: target)
                lockedStickyAnchor = sticky
                // Only when it adds something: at the anchor it is the anchor.
                let stickyStart = sticky.flatMap { $0 == anchorIndex ? nil
                    : Self.segmentStart(index: $0, durations: durations, targetDuration: target) }
                return (lockedPlayedSeconds, lockedWantedSeconds, lockedPruned, lockedAllowedKeptBytes, stickyStart)
            }
            let positions = Self.budgetPositions(played: played, wanted: wanted, anchorStart: anchorStart,
                                                 stickyStart: stickyStart)
            let victims = Self.evictionVictims(durations: durations, segmentBytes: bytes, pruned: pruned,
                                               positions: positions, allowedKeptBytes: allowed)
            guard !victims.isEmpty else { return ([], allowed, positions, pruned) }
            let evicted = IndexSet(victims)
            stateLock.withLock { lockedPruned.formUnion(evicted) }
            return (victims, allowed, positions, pruned.union(evicted))
        }
        guard !victims.isEmpty else { return }
        let names = [session.video?.segmentPrefix ?? "vseg"]
            .map { ($0, "m4s") }
            + session.audioRenditions.map { ($0.segmentPrefix, "m4s") }
            + session.subtitleRenditions.map { ($0.segmentPrefix, "vtt") }
        let directory = outputDir
        let fileLock = self.fileLock
        let delete = {
            let fm = FileManager.default
            for index in victims {
                // Per index: a file being handed to GCDWebServer is opened
                // first (`answer`), and a request waits for one index at most.
                fileLock.withLock {
                    for (prefix, ext) in names {
                        try? fm.removeItem(at: directory.appendingPathComponent("\(prefix)\(index).\(ext)"))
                    }
                }
            }
        }
        if case .report = pass { DispatchQueue.global(qos: .utility).async(execute: delete) } else { delete() }
        // Coalesced log: at most one line per `budgetRefreshInterval`.
        let now = Self.uptime
        let earlier: Int? = stateLock.withLock {
            if let last = lockedEvictionLoggedAt, now - last < Self.budgetRefreshInterval {
                lockedEvictedSinceLog += victims.count
                return nil
            }
            lockedEvictionLoggedAt = now
            let earlier = lockedEvictedSinceLog
            lockedEvictedSinceLog = 0
            return earlier
        }
        guard let earlier = earlier else { return }
        let count = min(durations.count, bytes.count)
        let kept = count > 1 ? (1..<count).reduce(Int64(0)) { pruned.contains($1) ? $0 : $0 + bytes[$1] } : 0
        print("[Remux] disk budget: evicted segment(s) \(Self.rangesDescription(IndexSet(victims)))"
              + (earlier > 0 ? " (+\(earlier) since the last log)" : "")
              + ", the furthest from \(positions.map { String(format: "%.1f", $0) }.joined(separator: " / ")) s; "
              + String(format: "deletable segments kept %.1f MB, allowed %.1f MB", Double(kept) / 1e6, Double(allowed) / 1e6))
    }

    /// The positions the disk budget protects around (pure): `played` and
    /// `wanted` — 0 while neither is known: a fresh item that isn't
    /// positioned yet loads segment 0 and prefetches from there (its resume
    /// seek comes once it is ready) —, `anchorStart`, the start of the
    /// lookahead anchor segment, and `stickyStart`, the start of the sticky
    /// budget anchor segment (`stickyBudgetAnchor`; nil when it is the
    /// anchor) when it lies ahead of one of those reported positions: it
    /// keeps what the pump wrote ahead of where playback is — behind all of
    /// them (playback moved on while the pump wrote nothing: a finished
    /// remux) it would only keep media behind their 3 min.
    static func budgetPositions(played: Double?, wanted: Double?, anchorStart: Double,
                                stickyStart: Double? = nil) -> [Double] {
        let reported = [played, wanted].compactMap { $0 }
        let positions = reported.isEmpty ? [0] : reported
        let sticky = stickyStart.flatMap { start in positions.contains { start > $0 } ? start : nil }
        return positions + [anchorStart] + (sticky.map { [$0] } ?? [])
    }

    /// The sticky budget anchor an eviction pass protects around (pure; a
    /// segment index, nil while the pump never wrote toward an anchor).
    /// `sticky` is the highest lookahead anchor the pump wrote toward or
    /// held at its limit for (`raiseStickyAnchor`): it follows the anchor
    /// forward — a far one the pump runs to included —, and does NOT fall
    /// back with it when AVPlayer's requests age out (a pause > 30 s with a
    /// full buffer: AVPlayer asks for nothing) nor when the playhead moves
    /// back (a rewind). So the lookahead the pump already wrote ahead of the
    /// region being played, up to sticky + L, stays protected: playing on
    /// after a pause, or after a rewind within the kept media, never runs
    /// into a hole the budget made (the pump never writes an evicted segment
    /// again). It is set to the current `anchor` only once its protected
    /// region [start − `protectBehind`, start + `lookahead`] no longer
    /// reaches the region of any position — `played`, `wanted` or the
    /// anchor's start: none within `protectBehind` + `lookahead` (6 min) of
    /// its start. That is a jump away from it: back from a far seek (its
    /// target region is evictable again, like the span the seek skipped), a
    /// rewind by more than about 6 min, or a far resume target leaving behind
    /// the start-up region an unpositioned item made the pump write. It
    /// writes nothing: it keeps what the pump wrote for an earlier anchor
    /// (never past that anchor + L) — past the positions' own regions, after
    /// a pause AVPlayer's forward buffer, after a rewind by D that plus D, at
    /// most 6 min.
    static func stickyBudgetAnchor(_ sticky: Int?, anchor: Int, played: Double?, wanted: Double?,
                                   durations: [Double], targetDuration: Double,
                                   protectBehind: Double = RemuxPlayback.minimumKeepBehindSeconds,
                                   lookahead: Double = RemuxPlayback.lookaheadSeconds) -> Int? {
        guard let sticky = sticky, sticky != anchor else { return sticky }
        let start = segmentStart(index: sticky, durations: durations, targetDuration: targetDuration)
        let anchorStart = segmentStart(index: anchor, durations: durations, targetDuration: targetDuration)
        let reach = max(0, protectBehind) + max(0, lookahead)
        let near = [played, wanted, anchorStart].compactMap { $0 }.contains { abs(start - $0) <= reach }
        return near ? sticky : anchor
    }

    /// The pump wrote toward `anchor`, or holds at its lookahead limit (its
    /// whole lookahead is written): raises the sticky budget anchor to it
    /// (`stickyBudgetAnchor`). Pump queue.
    private func raiseStickyAnchor(to anchor: Int) {
        stateLock.withLock { lockedStickyAnchor = max(lockedStickyAnchor ?? anchor, anchor) }
    }

    /// The disk budget (pure): how many bytes of deletable segments —
    /// written, not pruned, index ≥ 1, every rendition — the remux may keep
    /// on disk:
    /// `availableBytes + keptDeletableBytes − reserveBytes − remainingTorrentBytes − lookaheadSeconds × rate`,
    /// at least 0. `available + kept` is the room the remux would have if it
    /// kept nothing; the reserve (2 GiB) is never used; what the torrent still
    /// has to write is the torrent's; one lookahead at the output rate stays
    /// free for what no budget evicts (the protected segments around the
    /// positions, the segment being written). Between two evaluations the
    /// value stands: the remux's and the torrent's own writes and deletions
    /// cancel out in the formula. Free space or a rate that is unknown,
    /// zero or not finite → 0: every unprotected segment goes.
    static func allowedKeptBytes(availableBytes: Int64?, keptDeletableBytes: Int64, remainingTorrentBytes: Int64,
                                 outputBytesPerSecond: Double?, lookaheadSeconds: Double = RemuxPlayback.lookaheadSeconds,
                                 reserveBytes: Int64 = RemuxPlayback.rewindReserveBytes) -> Int64 {
        guard let available = availableBytes, let rate = outputBytesPerSecond, rate.isFinite, rate > 0 else { return 0 }
        let room = Double(available) + Double(max(0, keptDeletableBytes)) - Double(max(0, reserveBytes))
            - Double(max(0, remainingTorrentBytes)) - max(0, lookaheadSeconds) * rate
        guard room.isFinite, room > 0 else { return 0 }
        return room >= Double(Int64.max) ? Int64.max : Int64(room)
    }

    /// The rewind depth (s) a budget of `allowedKeptBytes` gives linear
    /// playback, which keeps [played − W, played + lookahead] (pure):
    /// `allowed / rate − lookahead`, at least `minimum` — what the budget
    /// protects behind every position anyway. Unknown, zero or non-finite
    /// rate → `minimum`.
    static func rewindSeconds(allowedKeptBytes: Int64, outputBytesPerSecond: Double?,
                              lookaheadSeconds: Double = RemuxPlayback.lookaheadSeconds,
                              minimum: Double = RemuxPlayback.minimumKeepBehindSeconds) -> Double {
        guard let rate = outputBytesPerSecond, rate.isFinite, rate > 0 else { return minimum }
        let seconds = Double(max(0, allowedKeptBytes)) / rate - max(0, lookaheadSeconds)
        return seconds.isFinite ? max(minimum, seconds) : minimum
    }

    /// The disk budget's evictions (pure), in order: while the deletable
    /// segments kept on disk — written (`segmentBytes`, per index, every
    /// rendition; their spans on the player timeline `durations`, which may
    /// list more segments than were written), not in `pruned`, index ≥ 1 —
    /// exceed `allowedKeptBytes`, the unprotected one furthest from every
    /// position.
    /// Protected: segment 0, and every segment overlapping
    /// [X − protectBehind, X + lookahead] for a position X. Distance from X:
    /// X − the segment's end when it ends at or before X (behind), else its
    /// start − (X + lookahead) (ahead); the smallest over the positions
    /// counts, and ties go to the lower index. Empty when everything fits —
    /// also when only protected segments are left over the budget.
    static func evictionVictims(durations: [Double], segmentBytes: [Int64], pruned: IndexSet, positions: [Double],
                                allowedKeptBytes: Int64,
                                protectBehind: Double = RemuxPlayback.minimumKeepBehindSeconds,
                                lookahead: Double = RemuxPlayback.lookaheadSeconds) -> [Int] {
        let count = min(durations.count, segmentBytes.count)
        guard count > 1 else { return [] }
        var kept: Int64 = 0
        for index in 1..<count where !pruned.contains(index) { kept += max(0, segmentBytes[index]) }
        guard kept > allowedKeptBytes else { return [] }
        let xs = positions.filter { $0.isFinite }
        var candidates: [(distance: Double, index: Int)] = []
        var start = durations[0]
        for index in 1..<count {
            let end = start + durations[index]
            if !pruned.contains(index) {
                var distance = Double.infinity
                var isProtected = false
                for x in xs {
                    if end >= x - protectBehind && start <= x + lookahead { isProtected = true; break }
                    distance = min(distance, end <= x ? x - end : start - (x + lookahead))
                }
                if !isProtected { candidates.append((distance, index)) }
            }
            start = end
        }
        candidates.sort { $0.distance != $1.distance ? $0.distance > $1.distance : $0.index < $1.index }
        var victims: [Int] = []
        for candidate in candidates {
            guard kept > allowedKeptBytes else { break }
            victims.append(candidate.index)
            kept -= max(0, segmentBytes[candidate.index])
        }
        return victims
    }

    /// "1…69, 131…140" (logs).
    private static func rangesDescription(_ indexes: IndexSet) -> String {
        indexes.rangeView.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)…\($0.upperBound - 1)" }
            .joined(separator: ", ")
    }

    /// Output rate (bytes per second of media) measured on the segments
    /// written so far — the larger of the whole output's average and the
    /// average of the `kept` segments (the span the budget keeps on disk), so
    /// a budget over high-bitrate scenes isn't sized with a lower overall
    /// average. nil until a second of media is written.
    static func outputBytesPerSecond(segmentBytes: [Int64], durations: [Double], kept: Range<Int>? = nil) -> Double? {
        let count = min(segmentBytes.count, durations.count)
        guard count > 0 else { return nil }
        func average(_ range: Range<Int>) -> Double? {
            let seconds = durations[range].reduce(0, +)
            let bytes = segmentBytes[range].reduce(0, +)
            guard seconds >= 1, bytes > 0 else { return nil }
            return Double(bytes) / seconds
        }
        guard let overall = average(0..<count) else { return nil }
        if let kept = kept?.clamped(to: 0..<count), !kept.isEmpty, let local = average(kept) {
            return max(overall, local)
        }
        return overall
    }

    /// Free space of the volume holding `url` (or its parent while it
    /// doesn't exist), read afresh on every call, from any thread:
    /// `volumeAvailableCapacityForImportantUsage`, falling back to
    /// `volumeAvailableCapacity` (the only one tvOS has);
    /// `freeSpaceProvider` first. Foundation caches resource values on a URL
    /// instance, and a cache filled off the main run loop (the pump, the
    /// budget queue) never expires: each query goes through a NEW URL with
    /// an empty cache, never through `url` itself (every copy of which
    /// shares one cache).
    static func availableCapacity(of url: URL) -> Int64? {
        if let provider = freeSpaceProvider, let value = provider(url) { return value }
        for path in [url.path, url.deletingLastPathComponent().path] {
            var candidate = URL(fileURLWithPath: path)
            candidate.removeAllCachedResourceValues()
            #if os(tvOS)
            guard let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityKey]) else { continue }
            if let capacity = values.volumeAvailableCapacity { return Int64(capacity) }
            #else
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
            guard let values = try? candidate.resourceValues(forKeys: keys) else { continue }
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
            if let capacity = values.volumeAvailableCapacity { return Int64(capacity) }
            if let important = values.volumeAvailableCapacityForImportantUsage { return important }
            #endif
        }
        return nil
    }

    /// Bytes the torrent still has to write: fileSize × (1 − totalProgress)
    /// while a streamer is attached (a preallocated torrent file has its full
    /// size from the start, its missing pieces take no space yet), else 0.
    private var remainingTorrentBytes: Int64 {
        guard let streamer = streamer else { return 0 }
        let progress = Double(streamer.torrentStatus.totalProgress)
        let size = ((try? FileManager.default.attributesOfItem(atPath: inputFile.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, progress.isFinite else { return 0 }
        return Int64(Double(size) * min(1, max(0, 1 - progress)))
    }

    /// The disk budget is due for a re-evaluation: never evaluated, last
    /// evaluated `budgetRefreshInterval` ago, or the remux wrote
    /// `budgetRefreshBytes` since — and none is running on `budgetQueue`.
    private var budgetIsStale: Bool {
        let written = session?.bytesWritten ?? 0
        return stateLock.withLock { !lockedBudgetInFlight && isBudgetStaleLocked(writtenBytes: written) }
    }

    /// `budgetIsStale` without the in-flight test. `stateLock` held.
    private func isBudgetStaleLocked(writtenBytes: Int64) -> Bool {
        guard let at = lockedBudgetEvaluatedAt else { return true }
        return Self.uptime - at >= Self.budgetRefreshInterval
            || writtenBytes - lockedBudgetEvaluatedBytes >= Self.budgetRefreshBytes
    }

    /// A report's pass: a stale budget is re-evaluated on `budgetQueue` (one
    /// evaluation at a time), followed there by an eviction pass.
    private func scheduleBudgetEvaluationIfStale() {
        let written = session?.bytesWritten ?? 0
        let schedule: Bool = stateLock.withLock {
            guard !lockedBudgetInFlight, isBudgetStaleLocked(writtenBytes: written) else { return false }
            lockedBudgetInFlight = true
            return true
        }
        guard schedule else { return }
        budgetQueue.async { [weak self] in
            guard let self = self else { return }
            self.evaluateDiskBudget()
            self.stateLock.withLock { self.lockedBudgetInFlight = false }
            self.enforceDiskBudget(.afterEvaluation)
        }
    }

    /// Re-evaluates the disk budget (any thread) with a FRESH free-space
    /// reading (`availableCapacity`), the deletable segments kept now, what
    /// the torrent still has to write and the output rate; logs it when the
    /// allowance moved by more than 20 %. While no output rate is measurable
    /// yet nothing changes: the allowance stays 0 and "not evaluated".
    private func evaluateDiskBudget() {
        guard let session = session else { return }
        let writtenBytes = session.bytesWritten
        let durations = session.segmentDurations()
        let bytes = session.segmentBytes()
        let pruned = stateLock.withLock { lockedPruned }
        // Every segment on disk the budget could delete: all written ones but
        // segment 0 and the pruned ones.
        let count = min(durations.count, bytes.count)
        var kept = IndexSet(integersIn: min(1, count)..<count)
        kept.subtract(pruned)
        let span = kept.first.flatMap { first in kept.last.map { first..<($0 + 1) } }
        guard let rate = Self.outputBytesPerSecond(segmentBytes: bytes, durations: durations, kept: span) else { return }
        let keptBytes = kept.reduce(Int64(0)) { $0 + bytes[$1] }
        let available = Self.availableCapacity(of: outputDir)
        let remaining = remainingTorrentBytes
        let allowed = Self.allowedKeptBytes(availableBytes: available, keptDeletableBytes: keptBytes,
                                            remainingTorrentBytes: remaining, outputBytesPerSecond: rate)
        let changed: Bool = stateLock.withLock {
            lockedAllowedKeptBytes = allowed
            lockedBudgetRate = rate
            lockedBudgetEvaluatedAt = Self.uptime
            lockedBudgetEvaluatedBytes = writtenBytes
            if let logged = lockedLoggedAllowance, abs(Double(allowed) - Double(logged)) <= 0.2 * Double(logged) { return false }
            lockedLoggedAllowance = allowed
            return true
        }
        if changed {
            func gb(_ value: Int64?) -> String { value.map { String(format: "%.2f GB", Double($0) / 1e9) } ?? "?" }
            let rewind = Self.rewindSeconds(allowedKeptBytes: allowed, outputBytesPerSecond: rate)
            print("[Remux] disk budget: \(gb(allowed)) of segments may stay on disk (free \(gb(available)), "
                  + "own kept \(gb(keptBytes)), reserve \(gb(Self.rewindReserveBytes)), torrent left \(gb(remaining)), "
                  + "lookahead \(gb(Int64(Self.lookaheadSeconds * rate))), remux \(String(format: "%.2f", rate / 1e6)) MB/s)"
                  + " — rewind window of linear playback ≈ \(rewind >= 1e7 ? "∞" : "\(Int(rewind.rounded())) s")")
        }
    }

    var statsSummary: String {
        guard let session = session else { return "préparation…" }
        return session.statsSummary
    }
}
