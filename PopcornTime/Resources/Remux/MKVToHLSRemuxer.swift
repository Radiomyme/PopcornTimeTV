

import Foundation

// CONTRACT FILE — owned by agent A4 (session orchestration).
//
// Remuxes a (still downloading) Matroska/WebM file into demuxed fMP4 HLS
// renditions that AVPlayer plays natively: one video rendition, one audio
// rendition per playable audio track (Dolby Atmos E-AC-3 JOC, E-AC-3, AC-3,
// AAC, FLAC, Opus, MP3, PCM→FLAC), and one segmented WebVTT rendition per
// text subtitle track. Codec bitstreams are copied, never re-encoded (except
// PCM → FLAC, lossless).
//
// Pipeline: EBMLReader → MatroskaDemuxer → RemuxCodecs (plans, sample
// entries, durations) → FMP4Muxer (init + moof/mdat) → files on disk, served
// by RemuxPlayback through playlists built by HLSPlaylists.
//
// Output file names (relative to `outputDirectory`), all segment indexes
// share the video grid K = 0, 1, 2…:
//   video_init.mp4, vseg{K}.m4s
//   audio{i}_init.mp4, a{i}seg{K}.m4s      (i = AudioRendition.index)
//   s{j}seg{K}.vtt                          (j = SubtitleRendition.index)
//   (temporary, never served: `<one of those names>.part<k>` / `.assembling`
//   while the last listed segment absorbs media past the end the frozen VOD
//   playlists announce — see `appendOverflowFragment`)
//
// Segments: segment K starts at a video keyframe — the first one at or after
// grid boundary K (`gridBoundary`: 6 s slots for segments 0 and 1, then slots
// of the session target, `targetDuration`, raised for long-GOP VOD files so
// that every slot holds a keyframe), or, when the file's keyframe index
// (Matroska Cues) was read before the VOD playlists were frozen, the keyframe
// the plan made from that index says (`CutPlan`): the frozen EXTINF list is
// then exact instead of estimated (`mediaPlaylist(named:)`).
//
// Timeline: presentation time (s) = (Matroska timestamp + shift) ×
// TimestampScale / 1e9, `shift` ≥ 0 only compensating negative timestamps.
// Video tfdt/PTS, audio tfdt and WebVTT cue times all live on that single
// timeline (WebVTT uses X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000) —
// except AAC, whose tfdt is 2112 − CodecDelay samples later because Apple's
// decoder discards that many priming samples (`aacPrimingCompensation`).
// Video PTS are made strictly unique (duplicate source timestamps nudged
// by one 90 kHz tick). AVPlayer shows the earliest presentation time of
// segment 0 (`timelineStart90k`) as time 0; RemuxPlayback maps external
// (movie-relative) subtitle files to it. A header Duration that is the END
// time of a movie starting late (ffmpeg -copyts: first frame at 600 s,
// Duration 630 s) is detected — only for files written by libavformat
// (Info/MuxingApp "Lavf…"), the one muxer that writes an end time — and the
// movie length becomes Duration − first time (`segmentCountSeconds`);
// mkvmerge and unknown writers keep the Duration as the length.
//
// Disk writes: every file of a segment index (vseg + every a{i}seg + every
// s{j}seg) is written before the segment is published (`progress`,
// `segmentDurations()`, EVENT playlists). A failed write (disk
// full…) keeps the segment pending: the next `pump` calls retry it before
// cutting anything else, and after `maxWriteAttempts` failures in a row (at
// once during `finish`) the session stops for good with `writeFailure` set.
//
// Threading: `prepare`, `pump` and `finish` run on ONE serial queue (the
// caller's pump queue). `progress`, `segmentDurations()`, the renditions and
// the other read-only accessors may be called from any thread (lock).
//
// Empty audio windows (a commentary track that ends early, a late-starting
// track…): the playlist of every audio rendition lists every segment index,
// so a{i}seg{K}.m4s must always exist AND hold at least one sample. Verified
// with AVPlayer (macOS 26, A4 harness): a fragment without samples (traf with
// only tfhd + tfdt) or with a zero-byte sample makes AVPlayer stop its
// buffered range at the last real sample and wait forever
// (WaitingToMinimizeStalls) as soon as that rendition is selected — even long
// before the gap. A fragment holding ONE real frame whose duration is
// stretched over the whole window plays straight through (the renderer plays
// that frame then silence). The filler is the track's smallest frame seen so
// far (ties → the most recent): digital silence for VBR codecs (AAC, Opus,
// FLAC…), the track's tail for CBR AC-3 / E-AC-3. `#EXT-X-GAP` can't be used:
// the VOD playlist is fetched once, before the emptiness of future windows
// is known.

final class MKVToHLSRemuxSession {

    struct Options {
        /// Release name carried an Atmos tag — fallback signal when the
        /// E-AC-3 BSI can't be parsed far enough to detect JOC.
        var releaseTaggedAtmos = false
        /// Release name carried HDR/DV tags — last-resort VIDEO-RANGE hint.
        var releaseHintsHDR = false
        /// Preferred audio languages, ISO 639-1 / BCP 47 ("fr"), priority order.
        var preferredAudioLanguages: [String] = []
        /// Preferred subtitle languages, ISO 639-1 / BCP 47, priority order.
        var preferredSubtitleLanguages: [String] = []
        /// Base segment target: the width of the first grid slots, and the
        /// session target unless the stream's keyframes are further apart
        /// (see `targetDuration`).
        var targetSegmentSeconds: Double = 6

        init() {}
    }

    enum PrepareResult: Equatable {
        /// Header (or the first frames needed to build codec configs) not downloaded yet.
        case needMoreData
        /// Video + at least one audio rendition are playable natively.
        case ready
        /// Nothing playable natively (no supported video, or no supported
        /// audio track) — caller must fall back to VLC immediately.
        case unsupported(String)
    }

    struct Progress: Equatable {
        var segmentsWritten = 0
        var mediaSeconds = 0.0
        var finished = false
    }

    struct VideoRendition: Equatable {
        let codecs: String
        let supplementalCodecs: String?
        /// "SDR" / "PQ" / "HLG".
        let videoRange: String
        let width: Int
        let height: Int
        let frameRate: Double?
        let summary: String
        var initName: String { "video_init.mp4" }
        var playlistName: String { "video.m3u8" }
        var segmentPrefix: String { "vseg" }
    }

    struct AudioRendition: Equatable {
        let index: Int
        /// Unique within the group ("Français (VFF) — E-AC-3 5.1 Atmos").
        let name: String
        /// BCP 47, nil when undetermined.
        let language: String?
        let isDefault: Bool
        let autoselect: Bool
        /// HLS CHANNELS ("2", "6", "16/JOC").
        let channels: String
        /// RFC 6381 codec token ("ec-3", "mp4a.40.2"…).
        let codecs: String
        let isAtmos: Bool
        let summary: String
        /// Director's commentary (→ CHARACTERISTICS public.auxiliary-content, AUTOSELECT=NO).
        var isCommentary = false
        /// Audio description for the visually impaired (→ CHARACTERISTICS describes-video).
        var isAudioDescription = false
        /// Matroska TrackNumber of the source track (diagnostics).
        var trackNumber: UInt64 = 0
        var initName: String { "audio\(index)_init.mp4" }
        var playlistName: String { "audio\(index).m3u8" }
        var segmentPrefix: String { "a\(index)seg" }
    }

    struct SubtitleRendition: Equatable {
        let index: Int
        let name: String
        let language: String?
        let isDefault: Bool
        let isForced: Bool
        let autoselect: Bool
        /// Hearing-impaired / SDH track (→ CHARACTERISTICS transcribes-spoken-dialog…).
        var isSDH = false
        /// Matroska TrackNumber of the source track (diagnostics).
        var trackNumber: UInt64 = 0
        var playlistName: String { "subs\(index).m3u8" }
        var segmentPrefix: String { "s\(index)seg" }
    }

    let outputDirectory: URL
    let options: Options

    init(inputFile: URL, outputDirectory: URL, options: Options = Options()) throws {
        self.outputDirectory = outputDirectory
        self.options = options
        self.lockedTarget = options.targetSegmentSeconds
        let handle = try FileHandle(forReadingFrom: inputFile)
        self.fileHandle = handle
        // fstat on the open descriptor: cheap enough for the reader, which
        // asks for the length before every read (the torrent file grows or,
        // when preallocated, fills in while we read it).
        let reader = EBMLReader(handle: handle) { MKVToHLSRemuxSession.currentLength(of: handle) }
        self.demuxer = MatroskaDemuxer(reader: reader)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? fileHandle.close()
    }

    /// Parse headers + first frames, decide renditions, write init segments.
    /// Call repeatedly until it returns something other than `.needMoreData`.
    func prepare() -> PrepareResult {
        if let outcome = outcome { return outcome }

        if !headerParsed {
            // Fail fast on non-Matroska payloads (an MP4/AVI renamed .mkv…):
            // a preallocated torrent file reads as zeros until downloaded,
            // so only judge once the first bytes are real.
            if let magic = readMagic(), magic != [0, 0, 0, 0], magic != [0x1A, 0x45, 0xDF, 0xA3] {
                return conclude(.unsupported("Fichier non Matroska"))
            }
            guard demuxer.parseHeaders() else { return .needMoreData }
            headerParsed = true
            var duration = demuxer.durationSeconds
            if duration.isFinite, duration > Self.maxHeaderDurationSeconds {
                log(String(format: "header Duration %.0f s is beyond %.0f days: ignored, as if absent — EVENT playlists "
                           + "(the real segments only)", duration, Self.maxHeaderDurationSeconds / 86_400))
                duration = 0
            }
            let (muxingApp, writingApp) = (demuxer.muxingApp, demuxer.writingApp)
            lock.withLock {
                lockedHeaderParsed = true
                lockedMuxingApp = muxingApp
                lockedWritingApp = writingApp
                lockedDuration = duration.isFinite ? max(0, duration) : 0
                // Corrected once the first frame's time is known (replayBufferedFrames).
                lockedCountSeconds = lockedDuration
            }
            if let reason = selectTracks() { return conclude(.unsupported(reason)) }
            // The keyframe index, when its Cues are already there (a
            // complete file, a torrent whose tail came first).
            loadCueIndexIfNeeded()
        }

        // Codec configurations need real frames (first E-AC-3 syncframe for
        // dec3, in-band parameter sets, DV RPUs…): buffer clusters — every
        // frame is kept and replayed into the muxer afterwards.
        while true {
            if buffer.sawVideoKeyframe {
                let missing = audioCandidates.filter { (buffer.audioFrames[$0.number] ?? 0) == 0 }
                if missing.isEmpty { break }
                if bufferedVideoSpan > 10 || demuxerAtEnd {
                    log("audio tracks without data after \(Int(bufferedVideoSpan)) s of video, ignored: "
                        + missing.map { "#\($0.number) \($0.codecID)" }.joined(separator: ", "))
                    audioCandidates.removeAll { track in missing.contains { $0.number == track.number } }
                    if audioCandidates.isEmpty {
                        return conclude(.unsupported("Aucune donnée audio exploitable"))
                    }
                    break
                }
            } else if bufferedVideoSpanAny > 30 || (demuxerAtEnd && buffer.anyVideo) {
                return conclude(.unsupported("Aucune image clé vidéo"))
            }
            let gotCluster: Bool = autoreleasepool {
                defer { noteInputConsumed() }
                guard let frames = demuxer.readNextCluster() else { return false }
                bufferPrepareFrames(frames)
                return true
            }
            if !gotCluster {
                if demuxerAtEnd {
                    // Whole file consumed: decide with what we have.
                    if buffer.sawVideoKeyframe || buffer.anyVideo { continue }
                    return conclude(.unsupported("Aucune image vidéo"))
                }
                return .needMoreData
            }
        }

        if let reason = buildPlansAndRenditions() { return conclude(.unsupported(reason)) }
        if let reason = writeInitSegments() { return conclude(.unsupported(reason)) }
        // From now on only the tracks in use are demuxed: blocks of the
        // others (an unused TrueHD / DTS track next to its AC-3 core, image
        // subtitles…) are skipped unread — neither copied nor checked for
        // pieces still missing. (nil during prepare: every candidate counts.)
        demuxer.trackFilter = Set(routes.keys)
        replayBufferedFrames()
        return conclude(.ready)
    }

    /// Demux available clusters and cut segments on the video grid. Returns
    /// the number of NEW segments written (a segment = vseg + every a{i}seg
    /// + every s{j}seg of the same index; a window the last listed segment
    /// absorbs counts as one, see `appendOverflowFragment`).
    @discardableResult
    func pump(maxNewSegments: Int = Int.max) -> Int {
        guard outcome == .ready, !isFinished, maxNewSegments > 0, writeFailure == nil else { return 0 }
        // Until the VOD list is frozen: the keyframe index, once downloaded.
        loadCueIndexIfNeeded()
        activatePlanIfPossible()
        var written = 0
        if let pending = pendingWrite {
            // A segment whose files couldn't be written (disk full…) goes
            // first: nothing after it may be published before it.
            guard commit(pending) else { return 0 }
            written = 1
        }
        if written < maxNewSegments {
            written += autoreleasepool { cutReadySegments(limit: maxNewSegments - written) }
        }
        while written < maxNewSegments && pendingWrite == nil {
            // One pool per cluster: file reads hand back autoreleased NSData;
            // without draining, every cluster read stays resident until the
            // caller's pool drains (memory grew with the file size — measured).
            let produced: Int? = autoreleasepool {
                defer { noteInputConsumed() }
                guard let frames = demuxer.readNextCluster() else { return nil }
                for frame in frames { route(frame) }
                return cutReadySegments(limit: maxNewSegments - written)
            }
            guard let count = produced else { break }
            written += count
        }
        return written
    }

    /// Flush trailing samples (end of file).
    func finish() {
        guard !isFinished else { return }
        // From here on a failed write is final (no more `pump` to retry it).
        isFinished = true
        lock.withLock { lockedFinishing = true }
        if outcome == .ready, let video = videoOutput, writeFailure == nil {
            // A segment still waiting to be written: last attempt.
            if let pending = pendingWrite { commit(pending) }
            if writeFailure == nil {
                for output in audioOutputs where output.transcoder != nil && !output.transcoderFailed {
                    appendTranscoded(output.transcoder?.flush() ?? [], to: output)
                    noteTranscoderFailure(output)
                }
                // Nothing more will be demuxed: cut the remaining grid segments
                // without waiting for audio that can't arrive any more, so the
                // segment count matches the playlist, then the trailing one.
                cutReadySegments(limit: Int.max, waitForAudio: false)
                if let plan = plan, overflow == nil, segmentIndex + 1 < plan.realCount {
                    // Tail fillers pad the count the frozen list announces.
                    dropPlan(reason: String(format: "the input ends before the planned keyframe at %.3f s",
                                            Double(plan.cuts90k[segmentIndex] - (video.originPTS ?? 0)) / 90_000))
                }
            }
            if writeFailure == nil && overflow != nil {
                // The absorbing last listed segment: its final fragment, then
                // the whole segment (every remaining cue in its WebVTT).
                if !video.pending.isEmpty { appendOverflowFragment(videoCount: video.pending.count, cutPTS: nil) }
                finishOverflow()
            } else if writeFailure == nil && !video.pending.isEmpty {
                // The last listed segment: its last frame reaches the end the
                // playlists announced (tail fillers do it otherwise). Its
                // WebVTT segment takes every remaining cue.
                let isLastListed = segmentIndex + 1 >= expectedSegmentCount
                writeSegment(videoCount: video.pending.count, cutPTS: nil, extendTo: isLastListed ? announcedEnd90k : nil)
            }
            if writeFailure == nil { writeTailFillers() }
            let published = lock.withLock { (lockedProgress.segmentsWritten, lockedProgress.mediaSeconds) }
            log("finished: \(published.0) segments, \(String(format: "%.1f", published.1)) s"
                + (writeFailure.map { " · stopped by a write failure (\($0))" } ?? "")
                + (video.nudgedPTS > 0 ? " · \(video.nudgedPTS) duplicate video timestamp(s) nudged" : "")
                + audioOutputs.map { a in
                    (a.resyncs > 0 || a.dropped > 0 || a.fillerWindows > 0)
                        ? " · a\(a.index): \(a.resyncs) resync(s), \(a.dropped) dropped, \(a.fillerWindows) filled window(s)" : ""
                }.joined())
        }
        lock.withLock { lockedProgress.finished = true }
    }

    /// Thread-safe snapshot.
    var progress: Progress { lock.withLock { lockedProgress } }

    /// Movie duration from the Matroska header (0 when absent, or beyond
    /// `maxHeaderDurationSeconds`).
    var totalDurationSeconds: Double { lock.withLock { lockedDuration } }

    /// A header Duration above this (7 days) is corrupt — e.g. written in
    /// nanoseconds instead of TimestampScale ticks: a 2 h movie then reads
    /// as 7.2e9 s — and is treated as absent (EVENT playlists listing the
    /// real segments only): a VOD list spans the Duration in grid slots, so
    /// such a value would have the first media playlist hold millions of
    /// EXTINF entries (gigabytes, minutes of CPU). Every announced count and
    /// planned list derives from the Duration kept, never from the raw one.
    static let maxHeaderDurationSeconds: Double = 7 * 24 * 3600

    /// The session's segment target (s): the grid step from slot
    /// `leadingGridSlots` on (`gridBoundary`), what an estimated EXTINF
    /// stands for. `options.targetSegmentSeconds` (6 s) unless the stream's
    /// keyframes are further apart in a VOD session: then the longest
    /// keyframe interval the encoder declares (x264 / x265 `keyint`, see
    /// `RemuxCodecs.declaredKeyframeInterval`) or the longest one seen
    /// before segment 0 is cut, + `targetMargin`, at most
    /// `maxTargetSeconds` — so that every grid slot holds a keyframe and no
    /// segment index is lost. An EVENT session (no header Duration) keeps
    /// the base target: it estimates nothing (see `decideTarget`). Decided
    /// before segment 0 is cut, constant from the moment it is published
    /// (before `onReady`). Thread-safe.
    var targetDuration: Double { lock.withLock { lockedTarget } }

    /// Grid slots that keep `options.targetSegmentSeconds` whatever the
    /// session target: RemuxPlayback's onReady waits for 2 segments, so the
    /// startup needs the same media as with 6 s segments.
    static let leadingGridSlots = 2
    /// Added to the longest keyframe interval (declared or seen) when the
    /// target has to cover it: timestamp rounding, slight frame-rate jitter.
    static let targetMargin = 0.25
    /// Upper bound of the session target.
    static let maxTargetSeconds = 20.0

    /// Start (90 kHz) of grid slot `k`: `origin` + k × `base` for the first
    /// `leadingGridSlots` slots. After them, slots of `target` centred on
    /// the keyframes the cutter is expected to meet: slot k starts at
    /// `anchor` − target / 2 + (k − `leadingGridSlots`) × target, `anchor`
    /// being the keyframe that started segment `leadingGridSlots` (origin +
    /// `leadingGridSlots` × base until it is known). Anchored there, a
    /// leading slot without a keyframe can't put the target-wide slots out
    /// of step with the segments; half a slot early, a segment's start
    /// lands in [its slot's start, + one keyframe interval) — within half a
    /// slot of the slot's middle, where the estimated VOD list puts it
    /// (`HLSPlaylists.estimatedTail`, `firstEnd`). With `target` == `base`,
    /// the uniform grid origin + k × base.
    static func gridBoundary(_ k: Int, origin: Int64, base: Double, target: Double, anchor: Int64? = nil) -> Int64 {
        guard target != base, k > leadingGridSlots else {
            return origin + Int64((Double(k) * base * 90_000).rounded())
        }
        let start = anchor ?? origin + Int64((Double(leadingGridSlots) * base * 90_000).rounded())
        return start - Int64((target * 45_000).rounded()) + Int64((Double(k - leadingGridSlots) * target * 90_000).rounded())
    }

    /// Grid slots covering `duration` s (see `gridBoundary`): the segment
    /// count the VOD playlists announce. `anchorSeconds`: the anchor of the
    /// target-wide slots, from the origin (default `leadingGridSlots` ×
    /// base). `expectedSegmentCount(duration:target:)` when `target` ==
    /// `base`.
    static func gridSegmentCount(duration: Double, base: Double, target: Double, anchorSeconds: Double? = nil) -> Int {
        guard target != base else { return expectedSegmentCount(duration: duration, target: base) }
        guard duration.isFinite, duration > 0 else { return 0 }
        let step = max(0.5, base)
        let slot = max(step, target)
        let leading = Double(leadingGridSlots) * step
        if duration <= leading { return Int((duration / step).rounded(.up)) }
        let firstSlotStart = (anchorSeconds ?? leading) - slot / 2
        // Segment j ≥ `leadingGridSlots` starts in slot j, before the movie's end.
        return leadingGridSlots + max(1, Int(((duration - firstSlotStart) / slot).rounded(.up)))
    }

    /// Valid once `prepare()` returned `.ready`.
    var video: VideoRendition? { lock.withLock { lockedVideo } }
    var audioRenditions: [AudioRendition] { lock.withLock { lockedAudio } }
    var subtitleRenditions: [SubtitleRendition] { lock.withLock { lockedSubtitles } }

    /// Actual durations (seconds) of the segments cut so far, by index.
    func segmentDurations() -> [Double] { lock.withLock { lockedDurations } }

    /// The EXTINF list AVPlayer sees for every media playlist of this session:
    /// the frozen VOD list once frozen; nil before the freeze and for EVENT
    /// sessions (whose list is `segmentDurations()`).
    func playerTimelineDurations() -> [Double]? { lock.withLock { lockedVODDurations } }

    /// The frozen VOD list came from the file's keyframe index (exact, see
    /// `mediaPlaylist(named:)`) rather than estimates. Diagnostics; thread-safe.
    var isPlaylistFromKeyframeIndex: Bool { lock.withLock { lockedPlanFrozen } }

    /// Tail fillers written at the end (`writeTailFillers`): 0 or 1 when the
    /// announced count matched the media — always with a list from the
    /// keyframe index (more: lost segment indexes of an estimated list, a
    /// header Duration longer than the media, an input ending before a
    /// planned keyframe); 1 for an EVENT session (its tail unit).
    /// Diagnostics; thread-safe.
    var tailFillerCount: Int { lock.withLock { lockedTailFillers } }

    /// Estimated peak bandwidth (bit/s) for the variant's BANDWIDTH.
    var bandwidthEstimate: Int {
        let duration = lock.withLock { lockedCountSeconds }
        let size = Double(Self.currentLength(of: fileHandle))
        guard duration > 0, size > 0 else { return 25_000_000 }
        let average = size * 8 / duration
        return max(2_000_000, Int(min(average * 1.5, Double(Int32.max))))
    }

    /// One-line summary for logs / stats overlay.
    var statsSummary: String {
        let snapshot = progress
        let expected = expectedSegmentCount
        var parts = ["\(snapshot.segmentsWritten)/\(expected > 0 ? String(expected) : "?") segments",
                     "\(Int(snapshot.mediaSeconds)) s remuxed"]
        let (audioCount, subtitleCount) = lock.withLock { (lockedAudio.count, lockedSubtitles.count) }
        if lockedVideoAvailable {
            parts.append("video + \(audioCount) audio" + (subtitleCount > 0 ? " + \(subtitleCount) subtitles" : ""))
        }
        if snapshot.finished { parts.append("finished") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Additional read-only accessors (thread-safe)

    /// Segment count announced by the VOD playlists: the grid slots covering
    /// the duration (`gridSegmentCount`; ceil(duration / target) while the
    /// target is the base one), the duration being the header's — or the
    /// movie length when that Duration is an end time (see
    /// `segmentCountSeconds`); the planned segments while a keyframe-index
    /// plan is in force. Once the playlists are frozen, their count (the
    /// same, unless the media had already run past that count, or the count
    /// comes from the keyframe index: see `mediaPlaylist(named:)`).
    var expectedSegmentCount: Int {
        let (frozen, planned, seconds, target, anchor) = lock.withLock {
            (lockedVODDurations?.count, lockedPlannedList?.count, lockedCountSeconds, lockedTarget, lockedGridAnchorSeconds)
        }
        return frozen ?? planned
            ?? Self.gridSegmentCount(duration: seconds, base: options.targetSegmentSeconds, target: target, anchorSeconds: anchor)
    }

    static func expectedSegmentCount(duration: Double, target: Double) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int((duration / max(0.5, target)).rounded(.up))
    }

    /// First presentation time (s) above which the meaning of the header
    /// Duration matters (see `headerDurationKind`): below it, an end time
    /// and a length differ by less than this.
    static let endTimeDurationThreshold: Double = 30

    /// What the header Duration of a movie starting at `start` measures.
    enum HeaderDurationKind: Equatable {
        /// First frame near Matroska time 0 (≤ `endTimeDurationThreshold`):
        /// end time and length coincide, the Duration is used as is.
        case normal
        /// The END time of the last frame, from Matroska time 0: what
        /// libavformat writes (`mkv->duration = max(ts + duration)`), e.g.
        /// ffmpeg -copyts keeping a 600 s start. Movie length = Duration −
        /// first time.
        case endTime
        /// A LENGTH from the first timestamp: mkvmerge's
        /// (`max_timestamp_and_duration − min_timestamp_in_file`), a
        /// Duration shorter than the first timestamp, or an unknown writer
        /// (the non-truncating choice: a phantom tail is filled, content is
        /// never cut).
        case length
    }

    /// Info/MuxingApp written by ffmpeg / libavformat ("Lavf60.16.100",
    /// "Lavf" with -fflags +bitexact; HandBrake's MKV muxer is libavformat too).
    static func isLibavformatMuxer(_ muxingApp: String?) -> Bool {
        muxingApp?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Lavf") == true
    }

    /// The interpretation of the header Duration (see `HeaderDurationKind`).
    static func headerDurationKind(headerDuration: Double, firstPresentationSeconds start: Double,
                                   muxingApp: String?) -> HeaderDurationKind {
        guard headerDuration.isFinite, headerDuration > 0, start.isFinite, start > endTimeDurationThreshold else {
            return .normal
        }
        guard headerDuration > start else { return .length }
        return isLibavformatMuxer(muxingApp) ? .endTime : .length
    }

    /// Seconds the VOD segment count is computed from. Normally the header
    /// Duration (counted from Matroska time 0). libavformat files that keep
    /// their source timestamps (ffmpeg -copyts: first frame at 600 s) write
    /// the Duration as the END time of the movie (630 s): counting from 0
    /// would announce 100 segments for 30 s of media (tail fillers, 404s past
    /// the end), so their movie length is Duration − first time. Every other
    /// writer keeps the header Duration: mkvmerge writes a length (a file
    /// delayed by 40 s, or part 2 of a split set starting at 1200 s, would
    /// otherwise lose its last 40 s / 20 min), and an unknown writer gets the
    /// choice that never cuts content.
    static func segmentCountSeconds(headerDuration: Double, firstPresentationSeconds start: Double,
                                    muxingApp: String? = nil) -> Double {
        guard headerDuration.isFinite, headerDuration > 0 else { return 0 }
        switch headerDurationKind(headerDuration: headerDuration, firstPresentationSeconds: start, muxingApp: muxingApp) {
        case .endTime: return headerDuration - start
        case .normal, .length: return headerDuration
        }
    }

    /// Movie length (s) on the playlist timeline — what the VOD playlists'
    /// EXTINF add up to: from the first segment's start to the movie's end
    /// (once frozen, their sum: the same, unless the media had already run
    /// past the header's length). Before the first segment is cut: the movie
    /// length from the header (`segmentCountSeconds`). 0 when the header has
    /// no Duration.
    var playlistDurationSeconds: Double {
        lock.withLock {
            if let frozen = lockedVODDurations { return frozen.reduce(0, +) }
            return lockedPlaylistSeconds > 0 ? lockedPlaylistSeconds : lockedCountSeconds
        }
    }

    /// Earliest presentation time of the video timeline, 90 kHz: segment 0's
    /// start (its smallest PTS, = its tfdt), which AVPlayer shows as time 0.
    /// Before segment 0 is cut: the first keyframe's (`mediaStartSeconds`).
    var timelineStart90k: Int64 {
        lock.withLock { lockedTimelineStart90k ?? Int64((lockedMediaStart * 90_000).rounded()) }
    }

    /// WebVTT segments written so far (every subtitle rendition has them
    /// all): WebVTT segment K is written with video segment K, so this is
    /// `progress.segmentsWritten`.
    var subtitleSegmentsWritten: Int { lock.withLock { lockedProgress.segmentsWritten } }

    /// Bytes of the media segment files published so far (video, audio,
    /// WebVTT, tail fillers; init segments excluded). Thread-safe.
    var bytesWritten: Int64 { lock.withLock { lockedBytesWritten } }

    /// Bytes on disk of each published segment index (vseg + every a{i}seg +
    /// every s{j}seg), aligned with
    /// `segmentDurations()` — what RemuxPlayback sizes its rewind window
    /// with (output rate, bytes kept behind the playhead). Thread-safe.
    func segmentBytes() -> [Int64] { lock.withLock { lockedSegmentBytes } }

    /// Source file offset of each published segment index, aligned with
    /// `segmentDurations()`: the start of the Matroska Cluster holding the
    /// segment's first video frame (its keyframe) — where a player resuming
    /// in that segment (VLC at that time) starts reading the file. Tail
    /// fillers and an absorbing last segment repeat the last real offset (a
    /// lower bound). Non-decreasing. Thread-safe.
    func segmentSourceOffsets() -> [Int64] { lock.withLock { lockedSourceOffsets } }

    /// The demuxer's position in the input file once the header is parsed:
    /// the next byte it will read, below which it never reads again (it
    /// only moves forward; a cluster that isn't complete yet is retried from
    /// its start, which this offset does not pass). 0 before the header is
    /// parsed. Bounded storage releases the file below it (minus what a
    /// hand-off at the playhead needs). Thread-safe.
    var consumedInputOffset: Int64 { lock.withLock { lockedConsumedInput } }

    /// Publishes the demuxer's position (`consumedInputOffset`, strictly
    /// forward). Pump queue.
    private func noteInputConsumed() {
        guard headerParsed else { return }
        let offset = Int64(clamping: demuxer.reader.offset)
        lock.withLock { lockedConsumedInput = max(lockedConsumedInput, offset) }
    }

    /// Info/MuxingApp and Info/WritingApp of the input (nil when absent or
    /// before the header is parsed). Thread-safe.
    var muxingApp: String? { lock.withLock { lockedMuxingApp } }
    var writingApp: String? { lock.withLock { lockedWritingApp } }

    /// How the header Duration was interpreted (valid once `prepare()`
    /// returned `.ready`; `.normal` before). Thread-safe.
    var headerDurationKind: HeaderDurationKind { lock.withLock { lockedDurationKind } }

    /// Set when a segment's files could not be written `maxWriteAttempts`
    /// times in a row (or once during `finish`): the session then stops
    /// producing — `pump` / `finish` do nothing more. User-facing reason
    /// ("Espace disque insuffisant"…), nil while healthy. Thread-safe.
    var writeFailure: String? { lock.withLock { lockedWriteFailure } }

    /// A segment is waiting for its files to be written again (the next
    /// `pump` retries it). Pump-queue only.
    var isWaitingToWrite: Bool { pendingWrite != nil }

    /// Failed attempts in a row after which a segment write is given up.
    static let maxWriteAttempts = 6

    /// User-facing reason for a failed remux write: the volume is full (the
    /// usual cause — tvOS keeps apps to a few GB), or anything else.
    static func writeFailureMessage(_ error: Error) -> String {
        isOutOfSpace(error as NSError) ? "Espace disque insuffisant"
            : "Écriture du remux impossible (\(error.localizedDescription))"
    }

    static func isOutOfSpace(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(ENOSPC) || error.code == Int(EDQUOT)) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }

    /// Tells the session the input file is fully downloaded: `prepare()`
    /// then stops waiting for frames that will never come (tiny files, audio
    /// tracks without data). Pump-queue only.
    func markInputComplete() {
        inputComplete = true
        // Zeros are now real data (e.g. digital silence in a PCM track), not
        // regions of a preallocated file still waiting to be downloaded.
        demuxer.assumeFullyDownloaded = true
    }

    /// True once the EBML header + Tracks have been parsed.
    var isHeaderParsed: Bool { lock.withLock { lockedHeaderParsed } }

    /// Presentation time (s) of the first video frame of segment 0.
    var mediaStartSeconds: Double { lock.withLock { lockedMediaStart } }

    /// Media playlist served for `video.m3u8`, `audio{i}.m3u8` or
    /// `subs{j}.m3u8` (nil for an unknown name or before `.ready`).
    /// Thread-safe — RemuxPlayback's HTTP handlers serve exactly this text.
    ///  - Duration in the header: VOD spanning the whole movie, ENDLIST. The
    ///    EXTINF list: the real durations of the segments cut so far, then
    ///    either (a) the PLANNED durations of the rest, when the file's
    ///    keyframe index (Matroska Cues) is readable and consistent with the
    ///    stream (`loadCueIndex`, `CutPlan`): the grid rule applied to the
    ///    indexed keyframes, which the cutter then follows keyframe for
    ///    keyframe — real segments only, plus the one tail unit an estimated
    ///    list also ends with when no segment starts in the movie's last grid
    ///    slot (never padding for slots the keyframes leave empty earlier on);
    ///    exact, up to how much the open-GOP leading pictures before a
    ///    keyframe vary between cuts (their typical span is measured at the
    ///    cuts made so far) and the split of the last frame between the last
    ///    segment and its tail unit; or (b) estimates, one grid slot
    ///    each (`targetDuration` from slot `leadingGridSlots` on), whose last
    ///    entry ends exactly at the movie's end (see
    ///    `HLSPlaylists.vodDurations`): a real start
    ///    lands within one keyframe interval of its estimate — within half a
    ///    slot once the target was raised (the target-wide slots are centred
    ///    on the expected cuts, see `gridBoundary`) — as long as every grid
    ///    slot holds a keyframe, which the session target ensures for the
    ///    keyframe intervals the encoder declares or the stream shows before
    ///    segment 0 is cut. The EXTINF add up to the Matroska duration,
    ///    measured from the first segment's start. That list is FROZEN the
    ///    first time a VOD playlist is generated once segment 0 is published
    ///    (RemuxPlayback's onReady waits for it, so every playlist AVPlayer
    ///    gets is frozen; `playerTimelineDurations`): every rendition and
    ///    every later request — later AVPlayerItems included — get
    ///    byte-identical text (RFC 8216 §4.3.3.5: a VOD playlist cannot
    ///    change). Its count is fixed then: tail fillers pad the real
    ///    segments up to it (`writeTailFillers`). The real count can't exceed
    ///    it with a correct header — segment k ≥ 1 needs a keyframe at or
    ///    after grid boundary k, before the movie's end — and the list always
    ///    includes the segment being cut; when the media still runs past it
    ///    (a header Duration shorter than the media), that last listed
    ///    segment absorbs the rest (`appendOverflowFragment`): nothing is
    ///    dropped. A playlist first generated after the remux has finished
    ///    lists exactly the segments that exist.
    ///  - No Duration (or one beyond `maxHeaderDurationSeconds`, treated as
    ///    absent): EVENT playlist listing only the segments that exist
    ///    (AVPlayer reloads it while the remux progresses; every rendition
    ///    lists the same segments, append-only; base 6 s slots whatever the
    ///    keyframe interval, see `decideTarget`; TARGETDURATION as in
    ///    `HLSPlaylists.media`), ENDLIST appended once the remux has
    ///    finished. A VOD playlist would end at the segments that existed
    ///    when AVPlayer fetched it (once).
    func mediaPlaylist(named name: String) -> String? {
        let base = name.hasSuffix(".m3u8") ? String(name.dropLast(".m3u8".count)) : name
        let state = lock.withLock {
            (ready: lockedVideo != nil, audio: lockedAudio.count, subtitles: lockedSubtitles.count,
             durations: lockedDurations, duration: lockedDuration, finished: lockedProgress.finished,
             target: lockedTarget)
        }
        guard state.ready else { return nil }
        func index(after prefix: String) -> Int? {
            guard base.hasPrefix(prefix) else { return nil }
            let digits = base.dropFirst(prefix.count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(digits)
        }
        let mapURI: String?
        let prefix: String
        let ext: String
        if base == "video" {
            mapURI = "video_init.mp4"; prefix = "vseg"; ext = "m4s"
        } else if let i = index(after: "audio"), i < state.audio {
            mapURI = "audio\(i)_init.mp4"; prefix = "a\(i)seg"; ext = "m4s"
        } else if let j = index(after: "subs"), j < state.subtitles {
            // Same grid as the video; WebVTT segment K is written with video K.
            mapURI = nil; prefix = "s\(j)seg"; ext = "vtt"
        } else {
            return nil
        }
        if state.duration > 0 {
            // The frozen list, served as is (`vodDurations` returns it unchanged).
            return HLSPlaylists.media(mapURI: mapURI, segmentPrefix: prefix, segmentExtension: ext,
                                      actualDurations: vodPlaylistDurations(), expectedSegments: 0,
                                      targetDuration: state.target)
        }
        return HLSPlaylists.media(mapURI: mapURI, segmentPrefix: prefix, segmentExtension: ext,
                                  actualDurations: state.durations, expectedSegments: 0, targetDuration: state.target,
                                  type: .event(ended: state.finished))
    }

    /// The EXTINF list of the VOD media playlists (see `mediaPlaylist`):
    /// the frozen one; else built now — the real durations so far, then the
    /// planned durations of the rest when a keyframe-index plan is active
    /// (`lockedPlannedList`, kept current by the pump), else estimates up to
    /// the announced count (at least one entry past the segments cut so far
    /// while the remux runs: the one being cut always ends up existing;
    /// `HLSPlaylists.vodDurations`), or exactly the segments that exist once
    /// the remux has finished — and frozen when segment 0 is published
    /// (before that, provisional: RemuxPlayback serves no playlist yet).
    /// While `finish()` runs (milliseconds), a first freeze waits for it (on
    /// the caller's thread, at most 5 s): it then lists exactly what exists.
    private func vodPlaylistDurations() -> [Double] {
        for _ in 0..<500 {
            guard lock.withLock({ lockedVODDurations == nil && lockedFinishing && !lockedProgress.finished }) else { break }
            usleep(10_000)
        }
        let (list, note): ([Double], String?) = lock.withLock {
            if let frozen = lockedVODDurations { return (frozen, nil) }
            let finished = lockedProgress.finished
            if !finished, !lockedDurations.isEmpty, let planned = lockedPlannedList {
                lockedVODDurations = planned
                lockedPlanFrozen = true
                return (planned, "VOD playlists frozen: \(planned.count) segments, exact (keyframe index)")
            }
            let base = options.targetSegmentSeconds
            let leading = Self.leadingGridSlots
            let announced = Self.gridSegmentCount(duration: lockedCountSeconds, base: base, target: lockedTarget,
                                                  anchorSeconds: lockedGridAnchorSeconds)
            // Target-wide slots are centred on the cuts (`gridBoundary`): the
            // segment being cut, k, is listed as ending where segment k + 1 is
            // expected — the start of segment `leading` (where the slots are
            // anchored) + (k + 1 − `leading`) slots — whatever drift the
            // segments cut since then carry.
            var firstEnd: Double?
            if lockedTarget != base, lockedDurations.count >= leading {
                let anchor = lockedDurations.prefix(leading).reduce(0, +)
                firstEnd = anchor + Double(lockedDurations.count + 1 - leading) * lockedTarget
            }
            let list = HLSPlaylists.vodDurations(actualDurations: lockedDurations,
                                                 expectedSegments: finished ? 0 : max(announced, lockedCutCount + 1),
                                                 targetDuration: lockedTarget,
                                                 estimatedTotalSeconds: lockedPlaylistSeconds > 0 ? lockedPlaylistSeconds : lockedCountSeconds,
                                                 leadingTarget: base, leadingSlots: leading, firstEnd: firstEnd)
            guard finished || !lockedDurations.isEmpty else { return (list, nil) }
            lockedVODDurations = list
            return (list, "VOD playlists frozen: \(list.count) segments, "
                    + (finished ? "every one written" : "\(lockedDurations.count) real, the rest estimated"
                       + String(format: " (%.2f s slots)", lockedTarget)))
        }
        if let note = note { log(note) }
        return list
    }

    // MARK: - Private: state

    private let fileHandle: FileHandle
    private let demuxer: MatroskaDemuxer
    /// Guards every `locked…` member (read from the HTTP threads).
    private let lock = NSLock()
    private var lockedProgress = Progress()
    private var lockedDurations: [Double] = []
    private var lockedVideo: VideoRendition?
    private var lockedAudio: [AudioRendition] = []
    private var lockedSubtitles: [SubtitleRendition] = []
    private var lockedHeaderParsed = false
    private var lockedDuration = 0.0
    /// Seconds the segment count is computed from (`segmentCountSeconds`):
    /// the header Duration, corrected once the first frame's time is known.
    private var lockedCountSeconds = 0.0
    private var lockedMediaStart = 0.0
    /// Segment 0's start (90 kHz) once it is cut.
    private var lockedTimelineStart90k: Int64?
    /// Movie length on the playlist timeline (from the first segment's
    /// start to the header's end of the movie), 0 when unknown.
    private var lockedPlaylistSeconds = 0.0
    private var lockedWriteFailure: String?
    private var lockedBytesWritten: Int64 = 0
    private var lockedSegmentBytes: [Int64] = []
    /// `segmentSourceOffsets()`, `consumedInputOffset`.
    private var lockedSourceOffsets: [Int64] = []
    private var lockedConsumedInput: Int64 = 0
    private var lockedMuxingApp: String?
    private var lockedWritingApp: String?
    private var lockedDurationKind: HeaderDurationKind = .normal
    /// The EXTINF list of every VOD media playlist, frozen the first time one
    /// is generated once segment 0 is published (`vodPlaylistDurations`);
    /// nil before, and for EVENT sessions.
    private var lockedVODDurations: [Double]?
    /// Segments cut so far by `cutReadySegments` (published, being written or
    /// waiting for their files).
    private var lockedCutCount = 0
    /// `finish()` is running: the final count is about to be known.
    private var lockedFinishing = false
    /// `targetDuration` (the base target until decided, see `decideTarget`).
    private var lockedTarget: Double
    /// The EXTINF list a freeze takes while a keyframe-index plan is active
    /// (`CutPlan.durations`, refreshed at each publish); nil otherwise.
    private var lockedPlannedList: [Double]?
    /// The frozen list came from the keyframe-index plan: the cutter follows it.
    private var lockedPlanFrozen = false
    /// End (90 kHz) of the last published segment: where the next one starts.
    private var lockedPublishedEnd90k: Int64 = 0
    /// Tail fillers published (`tailFillerCount`).
    private var lockedTailFillers = 0
    /// Where the target-wide grid slots start (s from the origin): the
    /// keyframe that started segment `leadingGridSlots` (`gridBoundary`).
    private var lockedGridAnchorSeconds: Double?
    private var lockedVideoAvailable: Bool { lock.withLock { lockedVideo != nil } }

    // Pump-queue-only state below.
    private var outcome: PrepareResult?
    private var headerParsed = false
    private var isFinished = false
    private var videoTrack: MKVTrack?
    private var audioCandidates: [MKVTrack] = []
    private var subtitleCandidates: [MKVTrack] = []
    private var buffer = PrepareBuffer()
    private var videoOutput: VideoOutput?
    private var audioOutputs: [AudioOutput] = []
    private var subtitleOutputs: [SubtitleOutput] = []
    private var routes: [UInt64: Route] = [:]
    /// Added to every Matroska timestamp so the timeline never goes negative.
    private var shiftTicks: Int64 = 0
    /// First video keyframe (Matroska ticks, unshifted): audio before it is trimmed.
    private var videoStartTicks: Int64 = 0
    /// Index of the next video segment to cut (== segments written).
    private var segmentIndex = 0
    /// tfdt (90 kHz) of every video segment written.
    private var segmentStarts90k: [Int64] = []
    /// A unit whose files couldn't all be written yet (see `commit`).
    private var pendingWrite: PendingWrite?
    /// Failed write attempts in a row.
    private var failedWriteAttempts = 0
    /// The last segment the frozen VOD playlists list, while it absorbs the
    /// media past the end they announce (`appendOverflowFragment`).
    private var overflow: Overflow?
    /// The session target once decided (`decideTarget`, before segment 0 is
    /// cut); nil before. The pump queue's copy of `lockedTarget`.
    private var gridTarget: Double?
    /// The keyframe interval (frames) the encoder declares (x264 / x265
    /// settings SEI); nil when unknown.
    private var declaredKeyint: Int?
    /// The video track's keyframe index (Matroska Cues): `loadCueIndexIfNeeded`.
    private var cueIndex: CueIndexState = .pending
    /// Uptime before which no new index attempt reads a whole Cues body
    /// again (one did, in vain).
    private var cueRetryAt: TimeInterval = 0
    /// Block timestamps (ticks) of the keyframes demuxed while the index may
    /// still be used: every indexed time among them must be one of them.
    private var seenKeyframeTicks: [Int64] = []
    /// PTS (90 kHz) of the keyframe that started segment k + 1, for every
    /// segment k cut so far (`cutReadySegments`).
    private var cutKeyframes90k: [Int64] = []
    /// For every cut whose segment was written: how far (90 kHz) the next
    /// segment starts before its keyframe — the leading pictures of an open
    /// GOP (decoded after the keyframe, shown before it). 0 for closed GOPs.
    private var leadingOffsets90k: [Int64] = []
    /// The keyframe-index plan the cutter follows (`makeCutPlan`); nil: the
    /// grid rule (`gridBoundary`).
    private var plan: CutPlan?

    private enum CueIndexState {
        /// Not loaded yet (not downloaded, or not tried).
        case pending
        /// Loaded: the video track's CueTimes (ticks), waiting for a plan.
        case available([Int64])
        /// Used, rejected or too late (the list is frozen): no more attempts.
        case done

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    private struct Overflow {
        /// The absorbing segment (the last listed one).
        let index: Int
        /// Fragments written so far (`<segment file name>.part<k>`, never
        /// served), and their media seconds / bytes.
        var parts = 0
        var seconds = 0.0
        var bytes: Int64 = 0
        /// End (90 kHz) of the last fragment.
        var end90k: Int64 = 0
    }

    /// Segment boundaries planned from the keyframe index (`makeCutPlan`):
    /// the grid rule applied to the indexed keyframes from the segment being
    /// built to the movie's end, then — when no planned segment starts in the
    /// movie's last grid slot — the one tail unit an estimated list ends with
    /// there (as `writeTailFillers` will write it).
    private struct CutPlan {
        /// PTS (90 kHz) of the keyframe starting segment k + 1, for every
        /// segment k but the last real one: the cuts made so far, then the
        /// planned ones.
        let cuts90k: [Int64]
        /// Tail units after the last real segment: 0 or 1.
        let fillerCount: Int
        /// Where the last real segment ends: the movie's end, minus one frame
        /// with a tail unit.
        let fillerStart90k: Int64
        /// The movie's end (90 kHz): where the last entry ends.
        let movieEnd90k: Int64

        /// Segments holding media (the tail unit excluded).
        var realCount: Int { cuts90k.count + 1 }

        /// The EXTINF list: `published` (the real durations of the published
        /// segments), then the planned durations of the others, the next one
        /// starting at `publishedEnd90k`; a planned segment starts
        /// `leadOffset90k` before its keyframe (open-GOP leading pictures, as
        /// measured at the cuts made so far), the last entry ends at the
        /// movie's end. nil when an entry wouldn't be positive (an
        /// inconsistent plan).
        func durations(published: [Double], publishedEnd90k: Int64, leadOffset90k: Int64 = 0) -> [Double]? {
            let total = realCount + fillerCount
            var list = published
            var cursor = publishedEnd90k
            var k = published.count
            while k < total {
                let end: Int64
                if k + 1 < realCount {
                    end = cuts90k[k] - leadOffset90k
                } else if k + 1 == realCount {
                    end = fillerCount > 0 ? fillerStart90k : movieEnd90k
                } else {
                    end = movieEnd90k
                }
                guard end > cursor else { return nil }
                list.append(Double(end - cursor) / 90_000)
                cursor = end
                k += 1
            }
            return list
        }
    }

    private struct PlanRejection: Error {
        let reason: String
    }

    /// Longest interval between consecutive indexed keyframes a plan accepts:
    /// a sparser index would make segments that long.
    static let maxIndexGapSeconds = 30.0
    /// Keyframes recorded for the index check, at most.
    private static let maxSeenKeyframes = 200_000

    private struct SegmentFile {
        let name: String
        let data: Data
    }

    /// Files published together — a segment index (vseg + every a{i}seg +
    /// every s{j}seg), a tail filler — and the update that makes them
    /// visible to the HTTP side (segment count, durations…), run once every
    /// file is on disk.
    private struct PendingWrite {
        var files: [SegmentFile]
        let publish: () -> Void
    }

    private enum Route { case video, audio(Int), subtitle(Int) }

    private struct PrepareBuffer {
        var frames: [MKVFrame] = []
        var sawVideoKeyframe = false
        var anyVideo = false
        var firstVideoTicks: Int64?
        var lastVideoTicks: Int64?
        var firstAnyVideoTicks: Int64?
        var lastAnyVideoTicks: Int64?
        var audioFrames: [UInt64: Int] = [:]
    }

    private final class VideoOutput {
        let track: MKVTrack
        let plan: RemuxVideoPlan
        let config: FMP4Muxer.TrackConfig
        /// Frames of the segment being built, decode order, [0] is a keyframe.
        var pending: [MKVFrame] = []
        /// Grid origin: PTS (90 kHz) of the first keyframe.
        var originPTS: Int64?
        /// Highest PTS demuxed so far (90 kHz).
        var latestPTS: Int64 = 0
        /// Last DTS written (keeps DTS strictly increasing across segments).
        var lastDTS: Int64?
        /// Typical frame duration (90 kHz), for one-frame segments.
        var typicalDuration: Int64
        var measuredFrameRate = false
        /// Payload of the last keyframe written (tail fillers).
        var lastKeyframePayload: Data?
        /// Duration given to the last sample written (90 kHz).
        var lastSampleDuration: Int64 = 0
        /// Output PTS of the previous segment: a source repeating a block
        /// timestamp across the cut must not yield a duplicate either.
        var previousSegmentPTS: Set<Int64> = []
        /// Samples whose PTS had to be nudged (duplicate source timestamps).
        var nudgedPTS = 0

        init(track: MKVTrack, plan: RemuxVideoPlan, config: FMP4Muxer.TrackConfig) {
            self.track = track
            self.plan = plan
            self.config = config
            let fromDefault = track.defaultDurationNs > 0 ? Int64((Double(track.defaultDurationNs) * 9e-5).rounded()) : 0
            self.typicalDuration = fromDefault > 0 ? fromDefault : 3754 // 23.976 fps
        }
    }

    private struct AudioSample {
        var dts: Int64
        var duration: Int64
        let data: Data
    }

    private final class AudioOutput {
        let index: Int
        let track: MKVTrack
        let plan: RemuxAudioPlan
        let config: FMP4Muxer.TrackConfig
        let transcoder: RemuxAudioTranscoder?
        let timescale: Int64
        /// Added to every decode time written (tfdt) — track timescale. AAC:
        /// Apple's decoder always discards 2112 priming samples and presents
        /// decoded sample 2112 at the tfdt, while Matroska timestamps the
        /// first decoded sample (see `aacPrimingCompensation`). 0 otherwise.
        /// `pending` / `nextDTS` stay on the media timeline; `writtenEnd` and
        /// every segment window comparison use the shifted (tfdt) timeline,
        /// like Apple's own segmenter (audio cut on decode time).
        let decodeOffset: Int64
        var pending: [AudioSample] = []
        /// Running decode time (track timescale); nil until the first kept frame.
        var nextDTS: Int64?
        /// Matroska timestamp of the previous frame (laced frames share one).
        var lastSourceTicks: Int64?
        /// Dropping frames after a backwards timestamp jump.
        var catchingUp = false
        /// End (track timescale, tfdt timeline) of the last sample written to a segment.
        var writtenEnd: Int64?
        /// Frame used to fill windows where the track has no packet (see the
        /// header comment): the smallest seen so far, ties → most recent.
        var fillerFrame: Data?

        // Transcoded (PCM → FLAC) tracks only.
        /// Media time (track timescale) of the next PCM sample pushed.
        var inputCursor: Int64?
        /// PCM samples represented by the packets received so far.
        var emittedSamples: Int64 = 0
        /// Source holes not yet applied: after `position` input samples, the
        /// timeline jumps `length` ticks ahead (the encoder's one-block
        /// latency means the packet that holds that position comes later).
        var pendingGaps: [(position: Int64, length: Int64)] = []
        /// The encoder failed: the rendition lives on with filler frames.
        var transcoderFailed = false

        func noteFrame(_ data: Data) {
            guard !data.isEmpty else { return }
            if let current = fillerFrame, current.count < data.count { return }
            fillerFrame = data
        }
        var resyncs = 0
        var dropped = 0
        var fillerWindows = 0

        init(index: Int, track: MKVTrack, plan: RemuxAudioPlan, config: FMP4Muxer.TrackConfig,
             transcoder: RemuxAudioTranscoder?, decodeOffset: Int64) {
            self.index = index
            self.track = track
            self.plan = plan
            self.config = config
            self.transcoder = transcoder
            self.timescale = Int64(max(1, plan.timescale))
            self.decodeOffset = decodeOffset
        }

        /// Decode time written to the fMP4 for a media-timeline time.
        func tfdt(_ mediaTime: Int64) -> Int64 { mediaTime + decodeOffset }
    }

    private final class SubtitleOutput {
        let index: Int
        let track: MKVTrack
        var cues: [SubtitleCue] = []
        init(index: Int, track: MKVTrack) {
            self.index = index
            self.track = track
        }
    }

    // MARK: - Private: prepare

    @discardableResult
    private func conclude(_ result: PrepareResult) -> PrepareResult {
        outcome = result
        if case .unsupported(let reason) = result { log("unsupported: \(reason)") }
        return result
    }

    private func readMagic() -> [UInt8]? {
        guard Self.currentLength(of: fileHandle) >= 4 else { return nil }
        do {
            try fileHandle.seek(toOffset: 0)
            guard let data = try fileHandle.read(upToCount: 4), data.count == 4 else { return nil }
            return [UInt8](data)
        } catch {
            return nil
        }
    }

    /// All the input has been consumed AND the caller said the file is
    /// complete (a growing / preallocated torrent file can't tell by itself).
    private var demuxerAtEnd: Bool { inputComplete && demuxer.reader.available == 0 }
    private var inputComplete = false

    private var bufferedVideoSpan: Double {
        guard let first = buffer.firstVideoTicks, let last = buffer.lastVideoTicks else { return 0 }
        return Double(last - first) * Double(demuxer.timestampScale) / 1e9
    }

    private var bufferedVideoSpanAny: Double {
        guard let first = buffer.firstAnyVideoTicks, let last = buffer.lastAnyVideoTicks else { return 0 }
        return Double(last - first) * Double(demuxer.timestampScale) / 1e9
    }

    /// Picks the video track and the audio / subtitle candidates. Returns
    /// the reason when nothing can be played natively.
    private func selectTracks() -> String? {
        let tracks = demuxer.tracks
        let videoTracks = tracks.filter { $0.kind == .video && $0.flagEnabled }
        guard !videoTracks.isEmpty else { return "Aucune piste vidéo" }
        var videoReasons: [String] = []
        for track in videoTracks.filter({ $0.flagDefault }) + videoTracks.filter({ !$0.flagDefault }) {
            if track.hasUnsupportedContentEncoding {
                videoReasons.append("Piste vidéo encodée (ContentEncoding non géré)")
                continue
            }
            switch RemuxCodecs.videoSupport(codecID: track.codecID) {
            case .supported:
                videoTrack = track
            case .needsTranscode:
                videoReasons.append("Vidéo \(track.codecID) non prise en charge")
            case .unsupported(let reason):
                videoReasons.append(reason)
            }
            if videoTrack != nil { break }
        }
        guard videoTrack != nil else { return videoReasons.first ?? "Vidéo non prise en charge" }

        let audioTracks = tracks.filter { $0.kind == .audio && $0.flagEnabled }
        var rejected: [String] = []
        for track in audioTracks {
            guard !track.hasUnsupportedContentEncoding else {
                rejected.append(track.codecID + " chiffré/compressé")
                continue
            }
            switch RemuxCodecs.audioSupport(codecID: track.codecID) {
            case .supported:
                audioCandidates.append(track)
            case .needsTranscode where RemuxAudioTranscoder.canTranscode(track: track):
                audioCandidates.append(track)
            case .needsTranscode:
                rejected.append(track.codecID)
            case .unsupported:
                rejected.append(track.codecID)
            }
        }
        if !rejected.isEmpty {
            log("audio tracks skipped (not native): " + rejected.joined(separator: ", "))
        }
        if audioCandidates.isEmpty {
            if audioTracks.isEmpty { return "Aucune piste audio" }
            var unique: [String] = []
            for codec in rejected where !unique.contains(codec) { unique.append(codec) }
            return "Audio non pris en charge nativement (\(unique.joined(separator: ", ")))"
        }
        subtitleCandidates = tracks.filter {
            $0.kind == .subtitle && $0.flagEnabled && !$0.hasUnsupportedContentEncoding
                && SubtitleConversion.isTextSubtitleCodec($0.codecID)
        }
        return nil
    }

    private func bufferPrepareFrames(_ frames: [MKVFrame]) {
        guard let videoNumber = videoTrack?.number else { return }
        for frame in frames {
            if frame.trackNumber == videoNumber {
                buffer.anyVideo = true
                buffer.firstAnyVideoTicks = buffer.firstAnyVideoTicks ?? frame.timestamp
                buffer.lastAnyVideoTicks = max(buffer.lastAnyVideoTicks ?? frame.timestamp, frame.timestamp)
                // Frames before the first keyframe can't be decoded: drop.
                if !buffer.sawVideoKeyframe && !frame.keyframe { continue }
                buffer.sawVideoKeyframe = true
                buffer.firstVideoTicks = buffer.firstVideoTicks ?? frame.timestamp
                buffer.lastVideoTicks = max(buffer.lastVideoTicks ?? frame.timestamp, frame.timestamp)
                buffer.frames.append(frame)
            } else if audioCandidates.contains(where: { $0.number == frame.trackNumber }) {
                buffer.audioFrames[frame.trackNumber, default: 0] += 1
                buffer.frames.append(frame)
            } else if subtitleCandidates.contains(where: { $0.number == frame.trackNumber }) {
                buffer.frames.append(frame)
            }
        }
    }

    private struct AudioChoice {
        let track: MKVTrack
        let plan: RemuxAudioPlan
        let transcoder: RemuxAudioTranscoder?
        let isCommentary: Bool
        let isAudioDescription: Bool
    }

    /// Builds the codec plans, then the renditions (names, DEFAULT…).
    private func buildPlansAndRenditions() -> String? {
        guard let videoTrack = videoTrack else { return "Vidéo non prise en charge" }

        // Video -----------------------------------------------------------
        let sampleFrames = Array(buffer.frames.lazy.filter { $0.trackNumber == videoTrack.number }.prefix(10).map(\.data))
        let videoPlan: RemuxVideoPlan
        switch RemuxCodecs.makeVideoPlan(track: videoTrack, sampleFrames: sampleFrames, releaseHintsHDR: options.releaseHintsHDR) {
        case .success(let plan): videoPlan = plan
        case .failure(let error): return error.reason
        }
        declaredKeyint = RemuxCodecs.declaredKeyframeInterval(codecID: videoTrack.codecID, codecPrivate: videoTrack.codecPrivate,
                                                              sampleFrames: sampleFrames)

        // Audio -----------------------------------------------------------
        var choices: [AudioChoice] = []
        var failures: [String] = []
        var sawEAC3 = false
        for track in audioCandidates {
            guard let firstFrame = buffer.frames.first(where: { $0.trackNumber == track.number }) else { continue }
            let commentary = Self.isCommentary(track)
            let description = Self.isAudioDescription(track)
            if case .needsTranscode = RemuxCodecs.audioSupport(codecID: track.codecID) {
                guard let transcoder = RemuxAudioTranscoder(track: track) else {
                    failures.append("#\(track.number) \(track.codecID): transcodeur indisponible")
                    continue
                }
                choices.append(AudioChoice(track: track, plan: transcoder.plan, transcoder: transcoder,
                                           isCommentary: commentary, isAudioDescription: description))
                continue
            }
            // The release-name Atmos hint only ever applies to the FIRST
            // E-AC-3 track that isn't a commentary / audio description (the
            // main mix), and only as a fallback when the BSI can't be read.
            let isEAC3 = track.codecID.uppercased().hasPrefix("A_EAC3")
            let isMainCandidate = isEAC3 && !commentary && !description
            let atmosHint = options.releaseTaggedAtmos && isMainCandidate && !sawEAC3
            if isMainCandidate { sawEAC3 = true }
            switch RemuxCodecs.makeAudioPlan(track: track, firstFrame: firstFrame.data, releaseTaggedAtmos: atmosHint) {
            case .success(let plan):
                choices.append(AudioChoice(track: track, plan: plan, transcoder: nil,
                                           isCommentary: commentary, isAudioDescription: description))
            case .failure(let error):
                failures.append("#\(track.number) \(track.codecID): \(error.reason)")
            }
        }
        if !failures.isEmpty { log("audio plans failed: " + failures.joined(separator: " | ")) }
        guard !choices.isEmpty else {
            var codecs: [String] = []
            for track in audioCandidates where !codecs.contains(track.codecID) { codecs.append(track.codecID) }
            return "Audio non pris en charge nativement (\(codecs.joined(separator: ", ")))"
        }

        // Pick DEFAULT, cap to 8 renditions (file order kept).
        var defaultChoice = chooseDefaultAudio(choices)
        if choices.count > Self.maxAudioRenditions {
            let keep = Set(rankForCap(choices, defaultIndex: defaultChoice).prefix(Self.maxAudioRenditions))
            let kept = choices.indices.filter { keep.contains($0) }
            log("audio renditions capped to \(Self.maxAudioRenditions) (of \(choices.count))")
            defaultChoice = kept.firstIndex(of: defaultChoice) ?? 0
            choices = kept.map { choices[$0] }
        }

        // Audio renditions + outputs.
        var renditions: [AudioRendition] = []
        var names: [String] = []
        var audioOutputs: [AudioOutput] = []
        for (index, choice) in choices.enumerated() {
            var name = Self.audioName(track: choice.track, plan: choice.plan, transcoded: choice.transcoder != nil, position: index)
            name = Self.uniqueName(name, among: names)
            names.append(name)
            var rendition = AudioRendition(index: index,
                                           name: name,
                                           language: choice.track.bcp47Language,
                                           isDefault: index == defaultChoice,
                                           autoselect: index == defaultChoice || !(choice.isCommentary || choice.isAudioDescription),
                                           channels: choice.plan.channelsAttribute,
                                           codecs: choice.plan.codecsString,
                                           isAtmos: choice.plan.isAtmos,
                                           summary: choice.plan.summary)
            rendition.isCommentary = choice.isCommentary
            rendition.isAudioDescription = choice.isAudioDescription
            rendition.trackNumber = choice.track.number
            renditions.append(rendition)
            let config = FMP4Muxer.TrackConfig(trackID: 1,
                                               timescale: UInt32(max(1, choice.plan.timescale)),
                                               handler: .audio,
                                               language: Self.iso639_2T(choice.track),
                                               sampleEntry: choice.plan.sampleEntry)
            let offset = choice.plan.codec == .aac && choice.transcoder == nil
                ? Self.aacPrimingCompensation(codecDelayNs: choice.track.codecDelayNs,
                                              timescale: Int64(max(1, choice.plan.timescale)))
                : 0
            audioOutputs.append(AudioOutput(index: index, track: choice.track, plan: choice.plan,
                                            config: config, transcoder: choice.transcoder, decodeOffset: offset))
        }

        // Subtitles -------------------------------------------------------
        var subtitleRenditions: [SubtitleRendition] = []
        var subtitleOutputs: [SubtitleOutput] = []
        let defaultSubtitle = chooseDefaultSubtitle(subtitleCandidates)
        var subtitleNames: [String] = []
        for (index, track) in subtitleCandidates.enumerated() {
            let forced = Self.isForced(track)
            let sdh = Self.isSDH(track)
            let name = Self.uniqueName(Self.subtitleName(track: track, forced: forced, sdh: sdh, position: index),
                                       among: subtitleNames)
            subtitleNames.append(name)
            var rendition = SubtitleRendition(index: index,
                                              name: name,
                                              language: track.bcp47Language,
                                              isDefault: index == defaultSubtitle,
                                              isForced: forced,
                                              autoselect: true)
            rendition.isSDH = sdh
            rendition.trackNumber = track.number
            subtitleRenditions.append(rendition)
            subtitleOutputs.append(SubtitleOutput(index: index, track: track))
        }

        // Video rendition + output.
        let videoRendition = VideoRendition(codecs: videoPlan.codecsString,
                                            supplementalCodecs: videoPlan.supplementalCodecs,
                                            videoRange: videoPlan.videoRange.rawValue,
                                            width: videoPlan.displayWidth,
                                            height: videoPlan.displayHeight,
                                            frameRate: videoPlan.frameRate,
                                            summary: videoPlan.summary)
        let videoConfig = FMP4Muxer.TrackConfig(trackID: 1, timescale: 90_000, handler: .video,
                                                width: videoPlan.displayWidth, height: videoPlan.displayHeight,
                                                language: "und", sampleEntry: videoPlan.sampleEntry)
        self.videoOutput = VideoOutput(track: videoTrack, plan: videoPlan, config: videoConfig)
        self.audioOutputs = audioOutputs
        self.subtitleOutputs = subtitleOutputs
        routes = [videoTrack.number: .video]
        for output in audioOutputs { routes[output.track.number] = .audio(output.index) }
        for output in subtitleOutputs { routes[output.track.number] = .subtitle(output.index) }

        lock.withLock {
            lockedVideo = videoRendition
            lockedAudio = renditions
            lockedSubtitles = subtitleRenditions
        }
        log("video: \(videoPlan.summary) [\(videoPlan.codecsString)\(videoPlan.supplementalCodecs.map { " + " + $0 } ?? "")] \(videoPlan.videoRange.rawValue)")
        for rendition in renditions {
            log("audio\(rendition.index): \(rendition.name) [\(rendition.codecs), CHANNELS \(rendition.channels)]\(rendition.isDefault ? " DEFAULT" : "")")
        }
        for rendition in subtitleRenditions {
            log("subs\(rendition.index): \(rendition.name)\(rendition.isForced ? " FORCED" : "")\(rendition.isDefault ? " DEFAULT" : "")")
        }
        return nil
    }

    private func writeInitSegments() -> String? {
        guard let video = videoOutput else { return "Vidéo non prise en charge" }
        var brands: [String] = []
        if case .dolbyVision = video.plan.codec { brands.append("dby1") }
        do {
            try FMP4Muxer.initSegment(tracks: [video.config], extraBrands: brands)
                .write(to: outputDirectory.appendingPathComponent("video_init.mp4"), options: .atomic)
            for output in audioOutputs {
                try FMP4Muxer.initSegment(tracks: [output.config])
                    .write(to: outputDirectory.appendingPathComponent("audio\(output.index)_init.mp4"), options: .atomic)
            }
        } catch {
            return Self.writeFailureMessage(error)
        }
        return nil
    }

    /// Timeline origin + replays every buffered frame through the muxer.
    private func replayBufferedFrames() {
        guard let videoNumber = videoTrack?.number else { return }
        let videoFrames = buffer.frames.filter { $0.trackNumber == videoNumber }
        videoStartTicks = videoFrames.first?.timestamp ?? 0
        // Negative timestamps (encoder delay kept by some muxers): shift the
        // whole timeline so no PTS / DTS / tfdt goes below zero.
        let minimum = videoFrames.map(\.timestamp).min() ?? 0
        shiftTicks = minimum < 0 ? -minimum : 0
        let start = Double(videoStartTicks + shiftTicks) * Double(demuxer.timestampScale) / 1e9
        let (header, muxingApp, writingApp) = lock.withLock { (lockedDuration, lockedMuxingApp, lockedWritingApp) }
        let kind = Self.headerDurationKind(headerDuration: header, firstPresentationSeconds: start, muxingApp: muxingApp)
        let countSeconds = Self.segmentCountSeconds(headerDuration: header, firstPresentationSeconds: start, muxingApp: muxingApp)
        let writer = "MuxingApp \"\(muxingApp ?? "?")\", WritingApp \"\(writingApp ?? "?")\""
        switch kind {
        case .endTime:
            log(String(format: "header Duration %.3f s is the end time of a movie starting at %.3f s (%@: libavformat "
                       + "writes an end time): movie length %.3f s", header, start, writer, countSeconds))
        case .length:
            let why = header <= start ? "shorter than the first timestamp"
                : "not libavformat — mkvmerge writes a length, an unknown writer must not be cut"
            log(String(format: "header Duration %.3f s kept as the movie length, first frame at %.3f s (%@: %@)",
                       header, start, writer, why))
        case .normal:
            break
        }
        lock.withLock {
            lockedMediaStart = start
            lockedCountSeconds = countSeconds
            lockedDurationKind = kind
        }
        let frames = buffer.frames
        buffer = PrepareBuffer()
        for frame in frames { route(frame) }
    }

    // MARK: - Private: routing

    private func route(_ frame: MKVFrame) {
        switch routes[frame.trackNumber] {
        case .video?: handleVideo(frame)
        case .audio(let index)?: handleAudio(frame, output: audioOutputs[index])
        case .subtitle(let index)?: handleSubtitle(frame, output: subtitleOutputs[index])
        case nil: break
        }
    }

    private func handleVideo(_ frame: MKVFrame) {
        guard let video = videoOutput else { return }
        if video.originPTS == nil {
            guard frame.keyframe else { return }
            video.originPTS = units(frame.timestamp, 90_000)
        }
        if frame.keyframe, !cueIndex.isDone, seenKeyframeTicks.count < Self.maxSeenKeyframes {
            seenKeyframeTicks.append(frame.timestamp)
        }
        video.pending.append(frame)
        video.latestPTS = max(video.latestPTS, units(frame.timestamp, 90_000))
    }

    private func handleAudio(_ frame: MKVFrame, output: AudioOutput) {
        if let transcoder = output.transcoder {
            handleTranscoded(frame, output: output, transcoder: transcoder)
            return
        }
        let frameDuration = Int64(output.plan.frameDuration(frame.data))
        let duration = frameDuration > 0 ? frameDuration : Int64(max(1, output.plan.nominalFrameDuration))
        let source = units(frame.timestamp, output.timescale)
        // Laced frames without DefaultDuration share the block timestamp:
        // only the first frame of a block can be compared with the source.
        let laceContinuation = output.lastSourceTicks == frame.timestamp
        output.lastSourceTicks = frame.timestamp

        if output.nextDTS == nil {
            // Audio that ends before the first video frame would start the
            // rendition before the video: trim it. Judged on the decode
            // timeline: AAC keeps the ~2 frames before the video that its
            // decoder discards as priming (see `decodeOffset`).
            if output.tfdt(source + duration) <= units(videoStartTicks, output.timescale) { return }
            output.nextDTS = max(-output.decodeOffset, source)
        } else if laceContinuation {
            // Same block as the previous frame: follow its fate.
            if output.catchingUp { output.dropped += 1; return }
        } else if let running = output.nextDTS {
            let drift = source - running
            let threshold = max(3 * duration, output.timescale / 10)
            if output.catchingUp {
                // Backwards jump in progress: drop until within half a frame.
                if drift < -duration / 2 { output.dropped += 1; return }
                output.catchingUp = false
            } else if drift > threshold {
                // Hole in the source: stretch the previous sample (still
                // pending) over it, else start the next one later (gap).
                if var last = output.pending.popLast() {
                    last.duration += drift
                    output.pending.append(last)
                }
                output.nextDTS = source
                output.resyncs += 1
            } else if drift < -threshold {
                output.catchingUp = true
                output.resyncs += 1
                if drift < -duration / 2 { output.dropped += 1; return }
                output.catchingUp = false
            }
        }
        guard let dts = output.nextDTS else { return }
        let data = output.plan.transform?(frame.data) ?? frame.data
        output.noteFrame(data)
        output.pending.append(AudioSample(dts: dts, duration: duration, data: data))
        output.nextDTS = dts + duration
    }

    /// PCM → FLAC. PCM is sample-exact: packets are timed from the first
    /// input frame + the samples emitted, and source timestamps are checked
    /// against the samples pushed so far, like passthrough tracks: a hole of
    /// up to 10 s is encoded as digital silence (sample-exact), a longer
    /// discontinuity stretches the packet holding that position, a backwards
    /// jump drops input until it is caught up. An encoder failure keeps the
    /// rendition alive with filler frames (empty windows) instead of
    /// stalling it.
    private func handleTranscoded(_ frame: MKVFrame, output: AudioOutput, transcoder: RemuxAudioTranscoder) {
        guard !output.transcoderFailed else { return }
        let samples = Int64(transcoder.inputSampleCount(of: frame.data))
        let source = units(frame.timestamp, output.timescale)
        let laceContinuation = output.lastSourceTicks == frame.timestamp
        output.lastSourceTicks = frame.timestamp
        if output.nextDTS == nil {
            output.nextDTS = max(0, source)
            output.inputCursor = max(0, source)
        } else if laceContinuation {
            if output.catchingUp { output.dropped += 1; return }
        } else if let cursor = output.inputCursor {
            let drift = source - cursor
            // Like passthrough (3 blocks, at least 100 ms), but at most 0.5 s:
            // PCM blocks can be long, and the cursor is sample-exact.
            let threshold = max(min(3 * max(samples, 1), output.timescale / 2), output.timescale / 10)
            if output.catchingUp {
                if drift < -max(samples, 1) / 2 { output.dropped += 1; return }
                output.catchingUp = false
            } else if drift > threshold {
                output.resyncs += 1
                if drift <= output.timescale * Self.maxPCMSilencePaddingSeconds {
                    // Sample-exact: the hole becomes digital silence in the
                    // stream (FLAC codes it as constant subframes — tiny).
                    pushSilence(samples: drift, output: output, transcoder: transcoder)
                    if output.transcoderFailed { return }
                } else {
                    // A long discontinuity: the timeline jumps after the
                    // samples pushed so far (the packet holding that position
                    // is stretched, see `appendTranscoded`).
                    output.pendingGaps.append((position: Int64(transcoder.samplesReceived), length: drift))
                }
                output.inputCursor = source
            } else if drift < -threshold {
                output.catchingUp = true
                output.resyncs += 1
                if drift < -max(samples, 1) / 2 { output.dropped += 1; return }
                output.catchingUp = false
            }
        }
        output.inputCursor = (output.inputCursor ?? 0) + samples
        appendTranscoded(transcoder.push(frame.data), to: output)
        noteTranscoderFailure(output)
    }

    private func appendTranscoded(_ packets: [RemuxAudioTranscoder.Packet], to output: AudioOutput) {
        for packet in packets where packet.samples > 0 {
            let start = output.emittedSamples
            let end = start + Int64(packet.samples)
            // A hole right before this packet: stretch the previous sample
            // (else start this one later — a gap between segments).
            while let gap = output.pendingGaps.first, gap.position <= start {
                output.pendingGaps.removeFirst()
                if var last = output.pending.popLast() {
                    last.duration += gap.length
                    output.pending.append(last)
                }
                output.nextDTS = (output.nextDTS ?? 0) + gap.length
            }
            // A hole inside this packet (encoder blocks ignore it): the
            // packet plays, then the silence of the hole.
            var duration = Int64(packet.samples)
            while let gap = output.pendingGaps.first, gap.position < end {
                output.pendingGaps.removeFirst()
                duration += gap.length
            }
            output.noteFrame(packet.data)
            let dts = output.nextDTS ?? 0
            output.pending.append(AudioSample(dts: dts, duration: duration, data: packet.data))
            output.nextDTS = dts + duration
            output.emittedSamples = end
        }
    }

    /// Longest hole in a PCM track filled with encoded silence; longer ones
    /// (a timestamp discontinuity rather than missing blocks) are stretched.
    private static let maxPCMSilencePaddingSeconds: Int64 = 10

    /// Pushes `samples` of digital silence (source layout: 0x80 for unsigned
    /// 8-bit, zero bytes otherwise) through the encoder, one second at a time.
    private func pushSilence(samples: Int64, output: AudioOutput, transcoder: RemuxAudioTranscoder) {
        let format = transcoder.format
        let fill: UInt8 = format.kind == .unsigned8 ? 0x80 : 0
        var remaining = samples
        let chunk = Int64(max(1, format.sampleRate))
        while remaining > 0, !output.transcoderFailed {
            let count = min(remaining, chunk)
            let silence = Data(repeating: fill, count: Int(count) * format.inputBytesPerFrame)
            appendTranscoded(transcoder.push(silence), to: output)
            noteTranscoderFailure(output)
            remaining -= count
        }
    }

    /// Logs an encoder failure once and makes sure the rendition can still
    /// be filled (a FLAC frame of silence when nothing was encoded yet).
    private func noteTranscoderFailure(_ output: AudioOutput) {
        guard !output.transcoderFailed, let transcoder = output.transcoder, transcoder.hasFailed else { return }
        output.transcoderFailed = true
        output.pendingGaps.removeAll()
        if output.fillerFrame == nil {
            let format = transcoder.format
            let count = 1024
            let silence = [UInt8](repeating: 0, count: count * format.outputBytesPerFrame)
            output.fillerFrame = silence.withUnsafeBytes {
                RemuxAudioTranscoder.verbatimFrame(pcm: $0, frames: count, format: format, frameNumber: 0)
            }
        }
        log("audio\(output.index): PCM→FLAC encoder failed on track #\(output.track.number) — "
            + "the rendition continues with silence")
    }

    private func handleSubtitle(_ frame: MKVFrame, output: SubtitleOutput) {
        let secondsPerTick = Double(demuxer.timestampScale) / 1e9
        let start = Double(frame.timestamp + shiftTicks) * secondsPerTick
        let duration = frame.duration.map { Double($0) * secondsPerTick }
        let additions = frame.additions[1] ?? frame.additions.values.first
        guard var cue = SubtitleConversion.cue(fromMatroskaBlock: frame.data,
                                               codecID: output.track.codecID,
                                               codecPrivate: output.track.codecPrivate,
                                               start: start,
                                               duration: duration,
                                               additions: additions) else { return }
        guard cue.end > 0 else { return }
        cue.start = max(0, cue.start)
        guard cue.end > cue.start else { return }
        output.cues.append(cue)
    }

    // MARK: - Private: segmenting

    /// Cuts the segments whose end is known (at most `limit`): with a
    /// keyframe-index plan, at its next planned keyframe (`plannedCut`);
    /// else at the first keyframe after the next grid boundary. Returns how
    /// many were written — an overflow fragment of the absorbing last listed
    /// segment counts as one.
    @discardableResult
    private func cutReadySegments(limit: Int, waitForAudio: Bool = true) -> Int {
        guard let video = videoOutput, let origin = video.originPTS else { return 0 }
        var written = 0
        while written < limit {
            // The session target, before the first cut.
            if gridTarget == nil, !decideTarget(final: !waitForAudio) { break }
            let cut: Int
            switch plannedCut() {
            case .at(let index):
                cut = index
            case .wait, .last:
                // The planned keyframe isn't demuxed yet / the last planned
                // segment runs to the end of the input (`finish`).
                return written
            case .none:
                // Absolute grid: segment k ends at the first keyframe at or
                // after grid boundary k + 1 (`gridBoundary`) that comes after
                // its own start. The real starts stay within one keyframe
                // interval after their boundaries — and the estimated VOD
                // list close to them — only while every grid slot holds a
                // keyframe: a slot without one loses a segment index for
                // good, hence a target covering the longest keyframe
                // interval (`decideTarget`). The windows an absorbing segment
                // takes in stay on that grid.
                let grid = segmentIndex + (overflow?.parts ?? 0)
                let boundary = gridBoundary(grid + 1, origin: origin)
                guard let index = video.pending.indices.dropFirst().first(where: {
                    video.pending[$0].keyframe && units(video.pending[$0].timestamp, 90_000) >= boundary
                }) else { return written }
                cut = index
            }
            let cutPTS = units(video.pending[cut].timestamp, 90_000)
            // Wait until every audio rendition has demuxed past the cut (the
            // audio of this window may still be ahead in the file), unless
            // the video is already 10 s further than that track's last packet
            // (sparse / ended audio, e.g. a commentary that stops early) —
            // measured per track, so an ended track never delays later cuts.
            if waitForAudio && video.latestPTS - cutPTS <= Self.audioWaitLimit90k {
                let lagging = audioOutputs.contains { output in
                    // A failed encoder produces nothing more: never wait for it.
                    if output.transcoderFailed { return false }
                    guard let next = output.nextDTS else {
                        return video.latestPTS - origin <= Self.audioWaitLimit90k
                    }
                    let next90k = output.tfdt(next) * 90_000 / output.timescale
                    return next90k < cutPTS && video.latestPTS - next90k <= Self.audioWaitLimit90k
                }
                if lagging { break }
            }
            // Frozen VOD playlists whose last listed segment is the one being
            // filled: no segment can be listed after it, so it absorbs the
            // window. Otherwise the segment is claimed — a playlist frozen
            // from now on lists the one after it too — atomically with that
            // check (playlists are frozen on the HTTP threads).
            let absorb: Bool = lock.withLock {
                if let frozen = lockedVODDurations, segmentIndex >= frozen.count - 1 { return true }
                lockedCutCount = segmentIndex + 1
                return false
            }
            // Not on disk yet (disk full…): kept pending, retried by `pump`.
            if absorb {
                guard appendOverflowFragment(videoCount: cut, cutPTS: cutPTS) else { break }
            } else {
                let before = segmentIndex
                let committed = writeSegment(videoCount: cut, cutPTS: cutPTS)
                if segmentIndex > before {
                    cutKeyframes90k.append(cutPTS)
                    if cutKeyframes90k.count == Self.leadingGridSlots {
                        // The target-wide slots start here (`gridBoundary`).
                        let anchor = Double(cutPTS - origin) / 90_000
                        lock.withLock { lockedGridAnchorSeconds = anchor }
                    }
                }
                guard committed else { break }
                activatePlanIfPossible()
            }
            written += 1
        }
        return written
    }

    // MARK: - Private: grid target and keyframe-index plan

    /// Start (90 kHz) of grid slot `k` for this session (`gridBoundary`).
    private func gridBoundary(_ k: Int, origin: Int64) -> Int64 {
        let base = options.targetSegmentSeconds
        let anchor = cutKeyframes90k.count >= Self.leadingGridSlots ? cutKeyframes90k[Self.leadingGridSlots - 1] : nil
        return Self.gridBoundary(k, origin: origin, base: base, target: gridTarget ?? base, anchor: anchor)
    }

    /// The width of a grid slot from `leadingGridSlots` on (s): the session
    /// target once decided.
    private var slotSeconds: Double { gridTarget ?? options.targetSegmentSeconds }

    /// Decides the session target (`targetDuration`) before segment 0 is
    /// cut. VOD: the base target, raised to the longest keyframe interval
    /// the encoder declares (`declaredKeyint` × the frame duration) or that
    /// the keyframes demuxed up to segment 0's cut keyframe (the first one
    /// at or after origin + base) show, + `targetMargin`, at most
    /// `maxTargetSeconds`; segment 0 is cut on the base grid whatever the
    /// outcome. EVENT (no header Duration): the base target, at once — its
    /// playlists list only the segments cut, so nothing is estimated and no
    /// segment index can be lost, while a longer target would lengthen the
    /// segments and the TARGETDURATION, which AVPlayer keeps three times
    /// away from the end of a growing playlist (a starvation rebuild near
    /// the remux frontier would not play). Returns false while segment 0's
    /// cut keyframe isn't demuxed yet (`final`: the input is exhausted,
    /// decide with what there is).
    private func decideTarget(final: Bool) -> Bool {
        guard let video = videoOutput, let origin = video.originPTS else { return false }
        let base = options.targetSegmentSeconds
        if lock.withLock({ lockedDuration <= 0 }) {
            gridTarget = base
            log(String(format: "segment target %.2f s: EVENT playlists (no header Duration) list the real segments only", base))
            return true
        }
        let boundary = origin + Int64((base * 90_000).rounded())
        var keys: [Int64] = []
        var reachedCut = false
        for frame in video.pending where frame.keyframe {
            let pts = units(frame.timestamp, 90_000)
            keys.append(pts)
            if keys.count > 1 && pts >= boundary { reachedCut = true; break }
        }
        guard reachedCut || final else { return false }
        keys.sort()
        let longestGap = zip(keys, keys.dropFirst()).map { Double($1 - $0) / 90_000 }.max() ?? 0
        let declared = declaredKeyint.map { Double($0) * nominalFrameSeconds(video) }
        var target = base
        if let declared = declared { target = max(target, declared + Self.targetMargin) }
        if longestGap > base { target = max(target, longestGap + Self.targetMargin) }
        target = min(Self.maxTargetSeconds, max(base, (target * 1000).rounded(.up) / 1000))
        gridTarget = target
        lock.withLock { lockedTarget = target }
        var why: [String] = []
        if let frames = declaredKeyint, let seconds = declared {
            why.append(String(format: "encoder keyint=%d (%.2f s)", frames, seconds))
        }
        why.append(String(format: "longest keyframe interval before the first cut %.2f s", longestGap))
        log(String(format: "segment target %.2f s", target)
            + (target != base ? " from segment \(Self.leadingGridSlots) on" : "") + ": " + why.joined(separator: ", "))
        return true
    }

    /// The video's frame duration (s): DefaultDuration, else the median step
    /// between the presentation times demuxed so far (23.976 fps without).
    private func nominalFrameSeconds(_ video: VideoOutput) -> Double {
        if video.track.defaultDurationNs > 0 { return Double(video.track.defaultDurationNs) / 1e9 }
        let times = video.pending.map { units($0.timestamp, 90_000) }.sorted()
        let steps = zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        return steps.isEmpty ? 1001.0 / 24_000 : Double(steps[steps.count / 2]) / 90_000
    }

    /// Loads the video track's keyframe index while it can still shape the
    /// VOD playlists (a VOD session whose list isn't frozen): during
    /// `prepare`, then at each `pump`. Cheap while the Cues aren't downloaded
    /// (a header read); after an attempt that read a whole body in vain, the
    /// next one waits at least a second. Pump-queue only.
    private func loadCueIndexIfNeeded() {
        guard case .pending = cueIndex, let track = videoTrack else { return }
        let (isVOD, frozen) = lock.withLock { (lockedDuration > 0, lockedVODDurations != nil) }
        guard isVOD, !frozen else {
            abandonCueIndex()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= cueRetryAt else { return }
        switch demuxer.loadCueIndex(trackNumber: track.number) {
        case .available(let ticks):
            cueIndex = .available(ticks)
            log("keyframe index: \(ticks.count) cue point(s) for video track #\(track.number)")
        case .notYet(let readBody):
            if readBody { cueRetryAt = now + 1 }
        case .unavailable(let reason):
            abandonCueIndex()
            log("no keyframe index (\(reason)): the VOD playlists will estimate the segments not cut yet")
        }
    }

    private func abandonCueIndex() {
        cueIndex = .done
        seenKeyframeTicks = []
    }

    /// Once the index is loaded and segment 0 is cut — and while the VOD
    /// list isn't frozen — plans the remaining cuts (`makeCutPlan`): the
    /// cutter follows the plan from now on, and the next freeze takes the
    /// planned list. Pump-queue only.
    private func activatePlanIfPossible() {
        guard case .available(let ticks) = cueIndex, plan == nil, segmentIndex >= 1, overflow == nil,
              let target = gridTarget else { return }
        // Segment 0 published: the planned list continues from a real end.
        let (published, frozen) = lock.withLock { (lockedDurations.count, lockedVODDurations != nil) }
        guard published >= 1 || frozen else { return }
        defer { abandonCueIndex() }
        guard !frozen else { return }
        let candidate: CutPlan
        switch makeCutPlan(indexTicks: ticks, target: target) {
        case .success(let made): candidate = made
        case .failure(let rejection):
            log("keyframe index not used (\(rejection.reason)): the VOD playlists will estimate the segments not cut yet")
            return
        }
        let accepted: Bool = lock.withLock {
            guard lockedVODDurations == nil,
                  let list = candidate.durations(published: lockedDurations, publishedEnd90k: lockedPublishedEnd90k,
                                                 leadOffset90k: typicalLeadingOffset90k) else { return false }
            lockedPlannedList = list
            return true
        }
        guard accepted else {
            log("keyframe index not used (inconsistent plan): the VOD playlists will estimate the segments not cut yet")
            return
        }
        plan = candidate
        log("keyframe index plan from segment \(segmentIndex): \(candidate.realCount) segments"
            + (candidate.fillerCount > 0 ? " + \(candidate.fillerCount) tail filler(s)" : "")
            + String(format: ", up to %.3f s", Double(candidate.movieEnd90k - (segmentStarts90k.first ?? 0)) / 90_000))
    }

    /// The cuts the grid rule makes on the indexed keyframes (`ticks`, the
    /// video track's CueTimes, converted like block timestamps by `units`),
    /// continuing from the segment being built (`segmentIndex`, started by
    /// the last cut), then one tail unit when no planned segment starts in
    /// the movie's last grid slot, the last entry ending at the movie's end.
    /// Grid slots the indexed keyframes leave empty earlier on (keyframes
    /// further apart than a slot) are simply not listed: the list is never
    /// padded up to the slot count. Rejected unless every indexed time among
    /// the keyframes demuxed so far is one of them, the index ends before the
    /// movie's end (the header's) within one slot or keyframe interval, and
    /// no two consecutive indexed keyframes are more than
    /// `maxIndexGapSeconds` apart.
    private func makeCutPlan(indexTicks ticks: [Int64], target: Double) -> Result<CutPlan, PlanRejection> {
        guard let video = videoOutput, let origin = video.originPTS, let start = cutKeyframes90k.last,
              let movieEnd = announcedEnd90k else {
            return .failure(PlanRejection(reason: "no movie end"))
        }
        guard let low = seenKeyframeTicks.min(), let high = seenKeyframeTicks.max() else {
            return .failure(PlanRejection(reason: "no keyframe demuxed to check it against"))
        }
        let seen = Set(seenKeyframeTicks)
        // CueTime is unsigned: a muxer cues a keyframe with a negative
        // timestamp (encoder delay kept) at 0 — not a time of the stream.
        let checked = ticks.filter { $0 >= low && $0 <= high && !($0 == 0 && low < 0 && !seen.contains(0)) }
        guard !checked.isEmpty else {
            return .failure(PlanRejection(reason: "none of its \(ticks.count) times among the \(seen.count) keyframes demuxed"))
        }
        if let wrong = checked.first(where: { !seen.contains($0) }) {
            return .failure(PlanRejection(reason: String(format: "indexed time %.3f s is not a keyframe of the stream",
                                                         Double(units(wrong, 90_000) - origin) / 90_000)))
        }
        let times = ticks.map { units($0, 90_000) }
        let longestGap = zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0
        guard Double(longestGap) <= Self.maxIndexGapSeconds * 90_000 else {
            return .failure(PlanRejection(reason: String(format: "indexed keyframes up to %.1f s apart", Double(longestGap) / 90_000)))
        }
        guard let last = times.last, last < movieEnd else {
            return .failure(PlanRejection(reason: "it runs past the header's movie end"))
        }
        let slack = max(longestGap, Int64((target * 90_000).rounded())) + 90_000
        guard movieEnd - last <= slack else {
            return .failure(PlanRejection(reason: String(format: "the header's movie end is %.1f s after the last indexed keyframe",
                                                         Double(movieEnd - last) / 90_000)))
        }
        // The cutter's rule (`gridBoundary`), the target-wide slots anchored
        // at the keyframe that starts segment `leadingGridSlots` — the real
        // one, or the planned one when the plan starts before it.
        let base = options.targetSegmentSeconds
        let leading = Self.leadingGridSlots
        var cuts = cutKeyframes90k
        var grid = segmentIndex
        var next = times.firstIndex(where: { $0 > start }) ?? times.count
        while true {
            let anchor = cuts.count >= leading ? cuts[leading - 1] : nil
            let boundary = Self.gridBoundary(grid + 1, origin: origin, base: base, target: target, anchor: anchor)
            while next < times.count && times[next] < boundary { next += 1 }
            guard next < times.count, times[next] < movieEnd else { break }
            cuts.append(times[next])
            next += 1
            grid += 1
        }
        // The planned cuts lie before the movie's end; the segment being
        // built must start before it too (media running past a header
        // Duration from the start).
        guard start < movieEnd else {
            return .failure(PlanRejection(reason: String(format: "segment %d, being cut, starts %.3f s after the header's movie end",
                                                         segmentIndex, Double(start - movieEnd) / 90_000)))
        }
        // No planned segment starts in the movie's last grid slot (the
        // movie's last keyframe lies before it — typically a remainder of a
        // few ms past a slot boundary): one tail unit, exactly as an estimated
        // list ends there, so the media don't depend on whether the index was
        // read; AVPlayer needs media up to the end the playlist announces
        // (without it, after subtitles on → off, it can stop at the video's
        // last frame: F05, round 9). A last keyframe within one frame of the
        // movie's end leaves no room for it: the last segment ends the list.
        let countSeconds = lock.withLock { lockedCountSeconds }
        let anchor = cuts.count >= leading ? cuts[leading - 1] : nil
        let announced = Self.gridSegmentCount(duration: countSeconds, base: base, target: target,
                                              anchorSeconds: anchor.map { Double($0 - origin) / 90_000 })
        let lastSlotStart = Self.gridBoundary(max(0, announced - 1), origin: origin, base: base, target: target, anchor: anchor)
        let lastStart = cuts.last ?? start
        let frame = max(1, video.typicalDuration)
        let fillers = lastStart < lastSlotStart && movieEnd - frame > lastStart ? 1 : 0
        return .success(CutPlan(cuts90k: cuts, fillerCount: fillers, fillerStart90k: movieEnd - Int64(fillers) * frame,
                                movieEnd90k: movieEnd))
    }

    private enum PlannedCut {
        /// No plan in force: the grid rule decides.
        case none
        /// The segment being built ends at this pending video frame.
        case at(Int)
        /// Its planned keyframe isn't demuxed yet.
        case wait
        /// It is the last planned segment: it runs to the end of the input.
        case last
    }

    /// Where the plan ends the segment being built: at the pending keyframe
    /// whose PTS is the planned cut. A keyframe past it without one AT it —
    /// the index disagrees with the stream — abandons the plan (logged once)
    /// and the grid rule takes over: the frozen list stays as it is (tail
    /// fillers or the absorbing last listed segment reconcile the count). A
    /// freeze that took estimates instead, or a plan whose list can't be
    /// formed, ends it too (the grid rule is what the estimates stand for).
    private func plannedCut() -> PlannedCut {
        guard let plan = plan, let video = videoOutput else { return .none }
        let usable = lock.withLock { lockedVODDurations == nil ? lockedPlannedList != nil : lockedPlanFrozen }
        guard usable else {
            dropPlan(reason: nil)
            return .none
        }
        guard overflow == nil else { return .none }
        guard segmentIndex + 1 < plan.realCount else { return .last }
        let wanted = plan.cuts90k[segmentIndex]
        for index in video.pending.indices.dropFirst() where video.pending[index].keyframe {
            let pts = units(video.pending[index].timestamp, 90_000)
            if pts == wanted { return .at(index) }
            if pts > wanted {
                dropPlan(reason: String(format: "no keyframe at the planned %.3f s, the next one at %.3f s",
                                        Double(wanted - (video.originPTS ?? 0)) / 90_000,
                                        Double(pts - (video.originPTS ?? 0)) / 90_000))
                return .none
            }
        }
        return .wait
    }

    /// Abandons the keyframe-index plan; `reason` (logged) when the stream
    /// disagreed with it.
    private func dropPlan(reason: String?) {
        plan = nil
        let frozenFromPlan: Bool = lock.withLock {
            lockedPlannedList = nil
            return lockedPlanFrozen
        }
        guard let reason = reason else { return }
        log("keyframe index plan abandoned at segment \(segmentIndex) (\(reason)): cutting on the grid from here; "
            + (frozenFromPlan ? "the frozen VOD playlists keep the planned list" : "the VOD playlists will be estimated"))
    }

    /// Under `lock`, after a publish: the list a freeze would take now.
    private func refreshPlannedListLocked() {
        guard lockedVODDurations == nil, let plan = plan else { return }
        lockedPlannedList = plan.durations(published: lockedDurations, publishedEnd90k: lockedPublishedEnd90k,
                                           leadOffset90k: typicalLeadingOffset90k)
    }

    /// The leading-picture offset a planned segment start is given: the
    /// median of those measured at the cuts written so far (0 before any).
    private var typicalLeadingOffset90k: Int64 {
        let sorted = leadingOffsets90k.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// How far (90 kHz) the video may run ahead of an audio track before the
    /// segmenter stops waiting for it.
    private static let audioWaitLimit90k: Int64 = 10 * 90_000

    /// The media fragments (moof + mdat) of one window, named
    /// `vseg{index}.m4s` / `a{i}seg{index}.m4s` + `suffix`: the first
    /// `videoCount` pending video frames and every audio packet timed before
    /// `cutPTS` (all when nil — the final window); those frames and packets
    /// are consumed. `extendTo` (final window only): the last frame lasts
    /// until then if that is within one segment. nil when there is no such
    /// window.
    private func makeFragments(index: Int, sequence: UInt32, videoCount: Int, cutPTS: Int64?, extendTo: Int64?,
                               suffix: String) -> (files: [SegmentFile], videoStart: Int64, videoEnd: Int64, frames: Int)? {
        guard let video = videoOutput, videoCount > 0, videoCount <= video.pending.count else { return nil }
        let frames = Array(video.pending.prefix(videoCount))
        video.pending.removeFirst(videoCount)

        // Video: PTS from the Matroska timestamps; DTS[i] = i-th smallest PTS
        // of the segment (strictly increasing) → B-frames, open GOPs and
        // variable frame rate get exact timing; CTO = PTS − DTS (signed).
        let pts = Self.uniquePresentationTimes(frames.map { units($0.timestamp, 90_000) },
                                               excluding: video.previousSegmentPTS, nudged: &video.nudgedPTS)
        video.previousSegmentPTS = Set(pts)
        var dts: [Int64] = []
        dts.reserveCapacity(frames.count)
        var previous = video.lastDTS
        for value in pts.sorted() {
            let next = previous.map { max(value, $0 + 1) } ?? max(0, value)
            dts.append(next)
            previous = next
        }
        var durations = [Int64](repeating: 0, count: frames.count)
        for i in 0..<(frames.count - 1) { durations[i] = dts[i + 1] - dts[i] }
        if frames.count > 1 {
            video.typicalDuration = Self.median(Array(durations[0..<(frames.count - 1)])) ?? video.typicalDuration
        }
        // Last sample: end exactly where the next segment will start (its
        // smallest PTS — the cut keyframe, or a leading picture of an open
        // GOP right after it, already demuxed) so consecutive segments tile
        // the timeline with no gap / overlap; the median frame duration when
        // unknown (final segment) or implausible.
        var lastDuration = max(1, video.typicalDuration)
        if cutPTS != nil, let lastDTS = dts.last,
           let nextStart = video.pending.prefix(8).map({ units($0.timestamp, 90_000) }).min() {
            let gap = nextStart - lastDTS
            if gap > 0 && gap <= 4 * lastDuration { lastDuration = gap }
        }
        if cutPTS == nil, let end = extendTo, let lastDTS = dts.last {
            // DTS[last] is the segment's latest PTS (sorted PTS): the track
            // ends at DTS[last] + its duration.
            let reach = end - lastDTS
            if reach > lastDuration && reach <= Self.maxEndExtension90k(slotSeconds) {
                lastDuration = reach
            }
        }
        durations[frames.count - 1] = lastDuration
        video.lastDTS = dts.last
        video.lastSampleDuration = lastDuration
        var samples: [FMP4Muxer.Sample] = []
        samples.reserveCapacity(frames.count)
        for (i, frame) in frames.enumerated() {
            let payload = video.plan.transform?(frame.data) ?? frame.data
            if frame.keyframe { video.lastKeyframePayload = payload }
            samples.append(FMP4Muxer.Sample(data: payload,
                                            duration: UInt32(clamping: durations[i]),
                                            sync: frame.keyframe,
                                            compositionOffset: Int32(clamping: pts[i] - dts[i])))
        }
        let videoStart = dts[0]
        var files = [SegmentFile(name: "vseg\(index).m4s" + suffix,
                                 data: FMP4Muxer.mediaSegment(sequence: sequence, trackSamples: [(video.config, UInt64(videoStart), samples)]))]

        // Audio: same window, packets whose decode time (tfdt timeline) is
        // before the next segment's start.
        let videoEnd = dts[frames.count - 1] + durations[frames.count - 1]
        for output in audioOutputs {
            let take: Int
            if let cut = cutPTS {
                take = output.pending.firstIndex(where: { output.tfdt($0.dts) * 90_000 >= cut * output.timescale })
                    ?? output.pending.count
            } else {
                take = output.pending.count
            }
            let chunk = output.pending.prefix(take)
            output.pending.removeFirst(take)
            let baseTime: Int64
            var audioSamples = chunk.map {
                FMP4Muxer.Sample(data: $0.data, duration: UInt32(clamping: $0.duration), sync: true)
            }
            if let first = chunk.first {
                baseTime = output.tfdt(first.dts)
                if let last = chunk.last { output.writtenEnd = output.tfdt(last.dts + last.duration) }
            } else {
                // Empty window (track not started yet / already ended): one
                // filler frame stretched over the window (see header).
                baseTime = max((videoStart * output.timescale) / 90_000, output.writtenEnd ?? 0)
                let windowEnd = ((cutPTS ?? videoEnd) * output.timescale) / 90_000
                if let filler = output.fillerFrame {
                    let span = max(1, windowEnd - baseTime)
                    audioSamples = [FMP4Muxer.Sample(data: filler, duration: UInt32(clamping: span), sync: true)]
                    output.writtenEnd = baseTime + span
                    output.fillerWindows += 1
                }
            }
            files.append(SegmentFile(name: "a\(output.index)seg\(index).m4s" + suffix,
                                     data: FMP4Muxer.mediaSegment(sequence: sequence, trackSamples: [(output.config, UInt64(max(0, baseTime)), audioSamples)])))
        }
        return (files, videoStart, videoEnd, frames.count)
    }

    /// Writes segment `segmentIndex`: the first `videoCount` pending video
    /// frames, every audio packet timed before `cutPTS` (all when nil — the
    /// final segment), and the WebVTT segment of the same index. `extendTo`
    /// (final segment only): the last frame lasts until then if that is
    /// within one segment. Returns false when the files couldn't all be
    /// written: the segment is then pending (not published) — see `commit`.
    @discardableResult
    private func writeSegment(videoCount: Int, cutPTS: Int64?, extendTo: Int64? = nil) -> Bool {
        let index = segmentIndex
        // Where the segment's first frame (its keyframe) sits in the source.
        let sourceOffset = Int64(clamping: videoOutput?.pending.first?.clusterOffset ?? 0)
        guard let video = videoOutput,
              let window = makeFragments(index: index, sequence: UInt32(clamping: index + 1), videoCount: videoCount,
                                         cutPTS: cutPTS, extendTo: extendTo, suffix: "") else { return false }
        var files = window.files
        let videoStart = window.videoStart
        let videoEnd = window.videoEnd
        let duration = Double(videoEnd - videoStart) / 90_000
        if let cut = cutPTS, cut >= videoEnd, cut - videoEnd < 90_000 {
            leadingOffsets90k.append(cut - videoEnd)
        }
        if index == 0 {
            // Movie length on the playlist timeline: from this segment's
            // start (its earliest PTS — a leading B-frame may precede the
            // keyframe) to the header's end of the movie, which runs from
            // Matroska time 0 and moves with the negative-timestamp shift
            // (right for a normal file and for a libavformat end-time
            // Duration, see `segmentCountSeconds`). A Duration that is a
            // LENGTH from the first timestamp (shorter than it, mkvmerge, an
            // unknown writer of a late-starting file) is the length as is.
            let shift = Double(shiftTicks) * Double(demuxer.timestampScale) / 1e9
            lock.withLock {
                let fromStart = lockedDuration + shift - Double(videoStart) / 90_000
                let isLength = lockedDurationKind == .length
                lockedPlaylistSeconds = lockedDuration > 0 ? (fromStart > 0 && !isLength ? fromStart : lockedDuration) : 0
                lockedTimelineStart90k = videoStart
            }
        }
        segmentStarts90k.append(videoStart)
        segmentIndex += 1
        var updatedVideo: VideoRendition?
        if !video.measuredFrameRate, window.frames > 1 {
            video.measuredFrameRate = true
            if let current = lock.withLock({ lockedVideo }), current.frameRate == nil, video.typicalDuration > 0 {
                let rate = (90_000 / Double(video.typicalDuration) * 1000).rounded() / 1000
                updatedVideo = VideoRendition(codecs: current.codecs, supplementalCodecs: current.supplementalCodecs,
                                              videoRange: current.videoRange, width: current.width, height: current.height,
                                              frameRate: rate, summary: current.summary)
            }
        }
        // The WebVTT segment of this index, in the same unit: every subtitle
        // rendition lists as many segments as the video (EVENT playlists
        // included). The final segment's is open-ended.
        files += makeSubtitleSegment(index, end: cutPTS == nil ? nil : videoEnd)
        let count = segmentIndex
        let bytes = Self.totalBytes(files)
        return commit(PendingWrite(files: files) { [weak self] in
            guard let self = self else { return }
            self.lock.withLock {
                self.lockedDurations.append(duration)
                self.lockedSourceOffsets.append(max(sourceOffset, self.lockedSourceOffsets.last ?? 0))
                self.lockedSegmentBytes.append(bytes)
                self.lockedBytesWritten += bytes
                self.lockedProgress.segmentsWritten = count
                self.lockedProgress.mediaSeconds += duration
                self.lockedPublishedEnd90k = videoEnd
                if let updated = updatedVideo { self.lockedVideo = updated }
                self.refreshPlannedListLocked()
            }
        })
    }

    /// Media past the end the frozen VOD playlists announce (a header
    /// Duration shorter than the media): no segment can be listed after the
    /// last listed one, so that segment absorbs it — AVPlayer plays a last
    /// segment holding more than its EXTINF through to the real end (A6
    /// round 6: 54 s past a 246 s announced end, DidPlayToEnd at the real
    /// end). Each window becomes one more fragment of that segment, written
    /// right away to `<segment file name>.part<k>` (never served) so the
    /// overflow never piles up in memory; `finishOverflow` assembles the
    /// segment at the end of the input. Returns false when the fragment
    /// couldn't be written yet (pending, see `commit`).
    @discardableResult
    private func appendOverflowFragment(videoCount: Int, cutPTS: Int64?) -> Bool {
        let index = segmentIndex
        var state = overflow ?? Overflow(index: index)
        guard let window = makeFragments(index: index, sequence: UInt32(clamping: index + 1 + state.parts),
                                         videoCount: videoCount, cutPTS: cutPTS, extendTo: nil,
                                         suffix: ".part\(state.parts)") else { return false }
        if overflow == nil {
            segmentStarts90k.append(window.videoStart)
            log("media past the end the VOD playlists announce: segment \(index), the last one they list, absorbs it")
        }
        state.parts += 1
        state.seconds += Double(window.videoEnd - window.videoStart) / 90_000
        state.bytes += Self.totalBytes(window.files)
        state.end90k = window.videoEnd
        overflow = state
        return commit(PendingWrite(files: window.files) {})
    }

    /// End of the input with an absorbing segment (`appendOverflowFragment`):
    /// its fragments are concatenated into `vseg{K}.m4s` / `a{i}seg{K}.m4s`
    /// (each part deleted once copied, then an atomic rename: a held request
    /// never sees a partial file), its WebVTT segment takes every remaining
    /// cue, and it is published as one segment. A failure is final (we are
    /// in `finish`).
    private func finishOverflow() {
        guard let state = overflow, writeFailure == nil, pendingWrite == nil else { return }
        let index = state.index
        let fm = FileManager.default
        for name in ["vseg\(index).m4s"] + audioOutputs.map({ "a\($0.index)seg\(index).m4s" }) {
            let assembling = outputDirectory.appendingPathComponent(name + ".assembling")
            do {
                guard fm.createFile(atPath: assembling.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: assembling.path])
                }
                let handle = try FileHandle(forWritingTo: assembling)
                do {
                    defer { try? handle.close() }
                    for k in 0..<state.parts {
                        let part = outputDirectory.appendingPathComponent(name + ".part\(k)")
                        try handle.write(contentsOf: Data(contentsOf: part))
                        try? fm.removeItem(at: part)
                    }
                }
                try fm.moveItem(at: assembling, to: outputDirectory.appendingPathComponent(name))
            } catch {
                noteWriteFailure(error, name: name)
                return
            }
        }
        overflow = nil
        segmentIndex += 1
        let files = makeSubtitleSegment(index, end: nil)
        let count = segmentIndex
        let bytes = state.bytes + Self.totalBytes(files)
        commit(PendingWrite(files: files) { [weak self] in
            guard let self = self else { return }
            self.lock.withLock {
                self.lockedDurations.append(state.seconds)
                self.lockedSourceOffsets.append(self.lockedSourceOffsets.last ?? 0)
                self.lockedSegmentBytes.append(bytes)
                self.lockedBytesWritten += bytes
                self.lockedProgress.segmentsWritten = count
                self.lockedProgress.mediaSeconds += state.seconds
                self.lockedPublishedEnd90k = state.end90k
            }
        })
        log("segment \(index) absorbed \(state.parts) window(s): \(String(format: "%.1f", state.seconds)) s")
    }

    /// Estimated VOD playlists announce one segment per grid slot up front
    /// (`gridSegmentCount`); a list from the keyframe index announces the
    /// planned segments, plus one tail unit when none starts in the last
    /// slot (see `makeCutPlan`). When the movie has no keyframe after the
    /// last grid boundary (frequent: the remainder is often < 1 s), fewer
    /// segments exist than an estimated list announces and AVPlayer —
    /// verified — waits forever on the missing one at the credits (404s, no
    /// DidPlayToEnd / FailedToPlayToEnd). Each missing index gets a tiny valid
    /// segment instead (a tail unit): one copy of the last keyframe (one
    /// frame) at the true end — the picture of the stream's last keyframe,
    /// shown up to one keyframe interval after its own time (a one-frame flash
    /// back right before the end) — one filler frame per audio rendition, an
    /// empty WebVTT per subtitle rendition — AVPlayer then reaches the end
    /// normally.
    /// A session without a header Duration (EVENT playlists) ends the same
    /// way, with one tail unit: without it the last video segment ends
    /// before the audio (F32: 29.989 s, the AAC rendition 30.016 s, 71 ms
    /// later in decode time), and after a seek into it AVPlayer
    /// intermittently stalls at the video's end instead of reaching
    /// DidPlayToEnd — F05, the same media with a Duration and this tail
    /// unit, never did. The last unit lasts until the end the playlists
    /// stand for when that is later than one frame, within one target
    /// duration: the announced end (VOD), or the end of the audio content
    /// (EVENT: the latest audio rendition's, before its filler frame).
    private func writeTailFillers() {
        guard let video = videoOutput, let keyframe = video.lastKeyframePayload, let end = video.lastDTS else { return }
        let isEvent = lock.withLock { lockedDuration <= 0 }
        let missing = isEvent ? 1 : min(expectedSegmentCount - segmentIndex, Self.maxTailFillers)
        guard missing > 0 else { return }
        var start = end + video.lastSampleDuration
        let frameDuration = max(1, video.typicalDuration)
        let tailEnd = isEvent ? audioEnd90k : announcedEnd90k
        var written = 0
        for number in 0..<missing {
            let index = segmentIndex
            let sequence = UInt32(clamping: index + 1)
            // The last filler lasts until `tailEnd`: a seek anywhere in the
            // VOD playlist finds a frame; an EVENT video reaches the end of
            // the audio content.
            var duration = frameDuration
            if number == missing - 1, let reach = tailEnd.map({ $0 - start }),
               reach > duration, reach <= Self.maxEndExtension90k(slotSeconds) {
                duration = reach
            }
            let sample = FMP4Muxer.Sample(data: keyframe, duration: UInt32(clamping: duration), sync: true)
            var files = [SegmentFile(name: "vseg\(index).m4s",
                                     data: FMP4Muxer.mediaSegment(sequence: sequence, trackSamples: [(video.config, UInt64(start), [sample])]))]
            for output in audioOutputs {
                let base = max((start * output.timescale) / 90_000, output.writtenEnd ?? 0)
                let span = max(1, (duration * output.timescale) / 90_000)
                let samples = output.fillerFrame.map { [FMP4Muxer.Sample(data: $0, duration: UInt32(clamping: span), sync: true)] } ?? []
                output.writtenEnd = base + span
                files.append(SegmentFile(name: "a\(output.index)seg\(index).m4s",
                                         data: FMP4Muxer.mediaSegment(sequence: sequence, trackSamples: [(output.config, UInt64(base), samples)])))
            }
            for output in subtitleOutputs {
                files.append(SegmentFile(name: "s\(output.index)seg\(index).vtt",
                                         data: Data(SubtitleConversion.makeWebVTT([], timestampMap: true).utf8)))
            }
            segmentStarts90k.append(start)
            segmentIndex += 1
            start += duration
            let count = segmentIndex
            let seconds = Double(duration) / 90_000
            let bytes = Self.totalBytes(files)
            let end = start
            let committed = commit(PendingWrite(files: files) { [weak self] in
                guard let self = self else { return }
                self.lock.withLock {
                    self.lockedDurations.append(seconds)
                    self.lockedSourceOffsets.append(self.lockedSourceOffsets.last ?? 0)
                    self.lockedSegmentBytes.append(bytes)
                    self.lockedBytesWritten += bytes
                    self.lockedProgress.segmentsWritten = count
                    self.lockedPublishedEnd90k = end
                    self.lockedTailFillers += 1
                }
            })
            guard committed else { break }
            written += 1
        }
        log("\(written) tail filler segment(s) written ("
            + (isEvent ? "no header Duration: the session ends like a VOD one" : "no keyframe after the last grid boundary") + ")")
    }

    /// End of the movie on the 90 kHz timeline as announced by the VOD
    /// playlists (first segment start + header duration); nil when unknown.
    private var announcedEnd90k: Int64? {
        guard let origin = segmentStarts90k.first else { return nil }
        let seconds = lock.withLock { lockedPlaylistSeconds }
        guard seconds > 0 else { return nil }
        return origin + Int64((seconds * 90_000).rounded())
    }

    /// End (90 kHz, presentation timeline) of the audio rendition that ends
    /// last, from what is written so far; nil before any audio sample.
    /// AAC's decode times are `decodeOffset` ahead of presentation.
    private var audioEnd90k: Int64? {
        audioOutputs.compactMap { output in
            output.writtenEnd.map { ($0 - output.decodeOffset) * 90_000 / output.timescale }
        }.max()
    }

    /// Longest stretch given to the very last frame to reach the end the
    /// playlists stand for: beyond one segment the header duration is wrong,
    /// not rounded (VOD), or the audio is not a short overshoot (EVENT).
    private static func maxEndExtension90k(_ target: Double) -> Int64 {
        Int64((max(0.5, target) * 90_000).rounded())
    }

    /// Bound on tail fillers: more missing segments means a wrong header
    /// duration, not a short last GOP.
    private static let maxTailFillers = 60

    /// The WebVTT segment `k` of every subtitle rendition, written with video
    /// segment `k` — i.e. once the cluster holding the keyframe that starts
    /// segment k + 1 is demuxed: in a file interleaved by timestamp, the
    /// subtitle blocks of the window come before it (one stored after it
    /// still reaches segment k + 1 when its cue overlaps that window). It
    /// holds every cue overlapping its window, widened to cover both the
    /// actual video segment [start, `end`) and its grid slot (an estimated VOD
    /// list stands for the slots; kept with an exact list too, so the WebVTT
    /// files never depend on whether the keyframe index was read) —
    /// open-ended for the final segment (`end` nil): duplicates across
    /// segments are expected by the HLS spec (cues spanning a boundary are
    /// repeated) and merged by the player.
    private func makeSubtitleSegment(_ k: Int, end: Int64?) -> [SegmentFile] {
        guard !subtitleOutputs.isEmpty, let video = videoOutput, let origin = video.originPTS,
              k < segmentStarts90k.count else { return [] }
        let gridStart = Double(gridBoundary(k, origin: origin))
        let gridEnd = Double(gridBoundary(k + 1, origin: origin))
        let low = k == 0 ? -Double.infinity : min(gridStart, Double(segmentStarts90k[k])) / 90_000
        let high = end.map { max(gridEnd, Double($0)) / 90_000 } ?? Double.infinity
        var files: [SegmentFile] = []
        for output in subtitleOutputs {
            let cues = output.cues.filter { $0.end > low && $0.start < high }
            let text = SubtitleConversion.makeWebVTT(cues, timestampMap: true)
            files.append(SegmentFile(name: "s\(output.index)seg\(k).vtt", data: Data(text.utf8)))
            // Cues ending before the next window can't be needed again.
            if let end = end {
                let nextLow = min(gridEnd, Double(end)) / 90_000
                output.cues.removeAll { $0.end <= nextLow }
            }
        }
        return files
    }

    /// Writes every file of `unit`, then publishes it. When a write fails the
    /// unit (minus the files already written) stays in `pendingWrite`: `pump`
    /// retries it before cutting anything else, so a segment is never counted
    /// — nor anything after it published — before its files exist; after
    /// `maxWriteAttempts` failures in a row (at once during `finish`) the
    /// session gives up (`writeFailure`). Returns true once published.
    @discardableResult
    private func commit(_ unit: PendingWrite) -> Bool {
        var remaining = unit
        while let file = remaining.files.first {
            do {
                // Atomic (temp file + rename): the HTTP long-poll serves a file
                // as soon as it exists, so it must never see a partial write.
                try file.data.write(to: outputDirectory.appendingPathComponent(file.name), options: .atomic)
            } catch {
                pendingWrite = remaining
                noteWriteFailure(error, name: file.name)
                return false
            }
            remaining.files.removeFirst()
        }
        pendingWrite = nil
        failedWriteAttempts = 0
        remaining.publish()
        return true
    }

    private static func totalBytes(_ files: [SegmentFile]) -> Int64 {
        files.reduce(0) { $0 + Int64($1.data.count) }
    }

    private func noteWriteFailure(_ error: Error, name: String) {
        failedWriteAttempts += 1
        let giveUp = isFinished || failedWriteAttempts >= Self.maxWriteAttempts
        if failedWriteAttempts == 1 || giveUp {
            log("write failed for \(name) (attempt \(failedWriteAttempts)"
                + (giveUp ? ", giving up" : ", retried at the next pump") + "): \(error.localizedDescription)")
        }
        guard giveUp else { return }
        let message = Self.writeFailureMessage(error)
        lock.withLock { if lockedWriteFailure == nil { lockedWriteFailure = message } }
    }

    // MARK: - Private: timing helpers

    /// Matroska ticks (+ shift) → `timescale` units, rounded to nearest.
    private func units(_ ticks: Int64, _ timescale: Int64) -> Int64 {
        let nanoseconds = Double(ticks + shiftTicks) * Double(demuxer.timestampScale)
        return Int64((nanoseconds * Double(timescale) / 1_000_000_000).rounded())
    }

    static func median(_ values: [Int64]) -> Int64? {
        let positive = values.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return nil }
        return positive[positive.count / 2]
    }

    /// Makes presentation times strictly unique, in decode order: a value
    /// already taken (earlier in the segment, or in `excluding` — the
    /// previous segment) moves one 90 kHz tick later until free. Some muxers
    /// repeat a block timestamp (VLC-muxed F01: two frames at 83 ms, two at
    /// 208 ms); two samples with one PTS make decoders drop a frame.
    static func uniquePresentationTimes(_ values: [Int64], excluding previous: Set<Int64>, nudged: inout Int) -> [Int64] {
        var used = previous
        used.reserveCapacity(previous.count + values.count)
        var result = values
        for i in result.indices {
            var value = result[i]
            if used.contains(value) {
                repeat { value += 1 } while used.contains(value)
                nudged += 1
            }
            used.insert(value)
            result[i] = value
        }
        return result
    }

    /// Priming discarded by Apple's AAC decoder (AudioToolbox on every
    /// platform, AAC-LC and HE-AAC alike, in samples of the track timescale
    /// = core sample rate) when no edit list says otherwise.
    static let appleAACPrimingSamples: Int64 = 2112

    /// Decode-time offset for an AAC track. Apple presents decoded sample
    /// 2112 at the fragment's tfdt; Matroska presents decoded sample
    /// `CodecDelay` (usually absent → 0) at the block timestamp — measured
    /// on 13 fixtures: AAC-LC played 44 ms early (2112 / 48 kHz), HE-AAC
    /// 88 ms (2112 / 24 kHz core). Shifting every tfdt by 2112 − CodecDelay
    /// puts each sample back at its Matroska time, from the start and after
    /// any seek (Apple's own HLS segmenter output relies on the same 2112).
    /// An `elst` can't do it: with media_time 2112 Apple trims 2112 more.
    static func aacPrimingCompensation(codecDelayNs: UInt64, timescale: Int64) -> Int64 {
        let delay = Int64((Double(codecDelayNs) * Double(max(1, timescale)) / 1e9).rounded())
        return min(max(appleAACPrimingSamples - delay, 0), appleAACPrimingSamples)
    }

    private static func currentLength(of handle: FileHandle) -> UInt64 {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return 0 }
        return UInt64(max(0, info.st_size))
    }

    private func log(_ message: String) {
        print("[Remux] \(message)")
    }

    // MARK: - Rendition policy (static, unit-tested)

    static let maxAudioRenditions = 8

    /// Higher is better: Atmos > lossless multichannel > E-AC-3 > AC-3 >
    /// AAC multichannel > other multichannel > stereo/mono (same order).
    static func audioQualityScore(codec: RemuxAudioPlan.Codec, channels: Int, isAtmos: Bool, transcoded: Bool) -> Int {
        let lossless = codec == .flac || codec == .alac || transcoded
        let rank: Int
        if isAtmos { rank = 6 }
        else if lossless { rank = 5 }
        else if codec == .eac3 { rank = 4 }
        else if codec == .ac3 { rank = 3 }
        else if codec == .aac { rank = 2 }
        else { rank = 1 }
        return (channels > 2 || isAtmos ? 100 : 0) + rank * 10 + min(channels, 9)
    }

    private func quality(_ choice: AudioChoice) -> Int {
        Self.audioQualityScore(codec: choice.plan.codec, channels: choice.plan.channelCount,
                               isAtmos: choice.plan.isAtmos, transcoded: choice.transcoder != nil)
    }

    /// First preferred language with a (non commentary / description) track
    /// → its best-quality track; else the FlagDefault track; else the first.
    private func chooseDefaultAudio(_ choices: [AudioChoice]) -> Int {
        let eligible = choices.indices.filter { !choices[$0].isCommentary && !choices[$0].isAudioDescription }
        for preferred in options.preferredAudioLanguages {
            guard let wanted = Self.normalizedLanguage(preferred) else { continue }
            var best: Int?
            for index in eligible where Self.normalizedLanguage(choices[index].track.bcp47Language) == wanted {
                if best == nil || quality(choices[index]) > quality(choices[best!]) { best = index }
            }
            if let best = best { return best }
        }
        if let flagged = eligible.first(where: { choices[$0].track.flagDefault }) { return flagged }
        return eligible.first ?? 0
    }

    /// Order in which renditions survive the 8-rendition cap.
    private func rankForCap(_ choices: [AudioChoice], defaultIndex: Int) -> [Int] {
        let preferred = options.preferredAudioLanguages.compactMap { Self.normalizedLanguage($0) }
        return choices.indices.sorted { a, b in
            func key(_ i: Int) -> (Int, Int, Int, Int) {
                let language = Self.normalizedLanguage(choices[i].track.bcp47Language)
                let languageRank = language.flatMap { preferred.firstIndex(of: $0) } ?? preferred.count
                return (i == defaultIndex ? 0 : 1,
                        choices[i].isCommentary || choices[i].isAudioDescription ? 1 : 0,
                        languageRank,
                        -quality(choices[i]))
            }
            let (ka, kb) = (key(a), key(b))
            return ka != kb ? ka < kb : a < b
        }
    }

    /// First non-forced track in the FIRST preferred subtitle language
    /// (non-SDH preferred), else none.
    private func chooseDefaultSubtitle(_ tracks: [MKVTrack]) -> Int? {
        guard let first = options.preferredSubtitleLanguages.first,
              let wanted = Self.normalizedLanguage(first) else { return nil }
        let matches = tracks.indices.filter {
            !Self.isForced(tracks[$0]) && Self.normalizedLanguage(tracks[$0].bcp47Language) == wanted
        }
        return matches.first(where: { !Self.isSDH(tracks[$0]) }) ?? matches.first
    }

    // MARK: Track classification

    private static func nameTokens(_ track: MKVTrack) -> [String] {
        (track.name ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func isCommentary(_ track: MKVTrack) -> Bool {
        if track.flagCommentary { return true }
        let name = (track.name ?? "").lowercased()
        return name.contains("comment") || name.contains("kommentar")
    }

    static func isAudioDescription(_ track: MKVTrack) -> Bool {
        if track.flagVisualImpaired { return true }
        let name = (track.name ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return name.contains("audiodescription") || name.contains("audio description")
            || name.contains("descriptive") || name.contains("audio-description")
    }

    static func isForced(_ track: MKVTrack) -> Bool {
        if track.flagForced { return true }
        let tokens = nameTokens(track)
        return tokens.contains { $0 == "forced" || $0 == "force" || $0 == "forces" }
    }

    static func isSDH(_ track: MKVTrack) -> Bool {
        if track.flagHearingImpaired { return true }
        let tokens = nameTokens(track)
        if tokens.contains(where: { $0 == "sdh" || $0 == "hi" || $0 == "cc" }) { return true }
        let name = (track.name ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return name.contains("malentendant") || name.contains("sourds") || name.contains("hearing impaired")
    }

    // MARK: Languages

    /// ISO 639-2/B → ISO 639-2/T (the 20 codes that differ).
    static let bibliographicToTerminology: [String: String] = [
        "fre": "fra", "ger": "deu", "chi": "zho", "cze": "ces", "dut": "nld", "gre": "ell", "per": "fas",
        "rum": "ron", "slo": "slk", "ice": "isl", "mac": "mkd", "may": "msa", "alb": "sqi", "arm": "hye",
        "baq": "eus", "bur": "mya", "geo": "kat", "tib": "bod", "wel": "cym", "mao": "mri",
    ]

    /// `mdhd` language: ISO 639-2/T, "und" when unknown.
    static func iso639_2T(_ track: MKVTrack) -> String {
        if let bcp = track.languageBCP47, !bcp.isEmpty, let code = iso639_2T(fromTag: bcp) { return code }
        return iso639_2T(fromTag: track.language) ?? "und"
    }

    static func iso639_2T(fromTag tag: String) -> String? {
        let primary = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        guard primary.count == 2 || primary.count == 3, primary.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return nil }
        if primary.count == 3 {
            if let terminology = bibliographicToTerminology[primary] { return terminology }
            return primary
        }
        guard let alpha3 = Locale.LanguageCode(primary).identifier(.alpha3), alpha3.count == 3 else { return nil }
        return alpha3
    }

    /// Primary language subtag normalized to ISO 639-1 when one exists
    /// ("fre" / "fra" / "fr-FR" → "fr"); nil for empty / undetermined.
    static func normalizedLanguage(_ tag: String?) -> String? {
        guard let tag = tag else { return nil }
        let primary = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        guard !primary.isEmpty, !["und", "zxx", "mis", "mul"].contains(primary) else { return nil }
        if primary.count == 3 {
            if let short = MKVTrack.iso639_1(fromISO639_2: primary) { return short }
            let terminology = bibliographicToTerminology[primary] ?? primary
            if let short = Locale.LanguageCode(terminology).identifier(.alpha2), short.count == 2 { return short }
        }
        return primary
    }

    /// French display name ("Français", "Portugais (Brésil)"), nil when unknown.
    static func languageDisplayName(_ tag: String?) -> String? {
        guard let tag = tag, normalizedLanguage(tag) != nil else { return nil }
        let french = Locale(identifier: "fr")
        let name = (tag.contains("-") ? french.localizedString(forIdentifier: tag) : nil)
            ?? french.localizedString(forLanguageCode: tag)
        guard let found = name, !found.isEmpty else { return nil }
        return found.prefix(1).uppercased() + found.dropFirst()
    }

    // MARK: Names

    /// "5.1", "7.1", "2.0"…
    static func channelLayoutLabel(_ channels: Int) -> String {
        switch channels {
        case 1: return "1.0"
        case 2: return "2.0"
        case 3: return "3.0"
        case 4: return "4.0"
        case 5: return "5.0"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels) canaux"
        }
    }

    static func codecLabel(codec: RemuxAudioPlan.Codec, codecsString: String, codecID: String, transcoded: Bool) -> String {
        switch codec {
        case .eac3: return "E-AC-3"
        case .ac3: return "AC-3"
        case .aac:
            if codecsString.hasSuffix(".29") { return "HE-AAC v2" }
            if codecsString.hasSuffix(".5") { return "HE-AAC" }
            return "AAC"
        case .flac: return transcoded ? "PCM" : "FLAC"
        case .opus: return "Opus"
        case .mp3:
            let id = codecID.uppercased()
            if id.hasSuffix("/L2") { return "MP2" }
            if id.hasSuffix("/L1") { return "MP1" }
            return "MP3"
        case .alac: return "ALAC"
        }
    }

    /// "Français — VFF · E-AC-3 5.1 Atmos"; "Piste 2 · AC-3 2.0" without language.
    static func audioName(track: MKVTrack, plan: RemuxAudioPlan, transcoded: Bool, position: Int) -> String {
        let language = languageDisplayName(track.bcp47Language)
        var name = language ?? "Piste \(position + 1)"
        if let extra = cleanedTrackName(track, languageName: language) { name += " — " + extra }
        var codec = codecLabel(codec: plan.codec, codecsString: plan.codecsString, codecID: track.codecID, transcoded: transcoded)
        codec += " " + channelLayoutLabel(plan.channelCount)
        if plan.isAtmos { codec += " Atmos" }
        return name + " · " + codec
    }

    /// "Français (forcés)", "Anglais (SDH)", "Anglais — Commentaire".
    static func subtitleName(track: MKVTrack, forced: Bool, sdh: Bool, position: Int) -> String {
        let language = languageDisplayName(track.bcp47Language)
        var name = language ?? "Piste \(position + 1)"
        if let extra = cleanedTrackName(track, languageName: language, dropping: ["forced", "force", "forces", "sdh", "hi", "cc"]) {
            name += " — " + extra
        }
        var qualifiers: [String] = []
        if forced { qualifiers.append("forcés") }
        if sdh { qualifiers.append("SDH") }
        if !qualifiers.isEmpty { name += " (" + qualifiers.joined(separator: ", ") + ")" }
        return name
    }

    /// Track Name worth showing (not empty, not just the language again).
    private static func cleanedTrackName(_ track: MKVTrack, languageName: String?, dropping words: Set<String> = []) -> String? {
        guard var raw = track.name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.count > 48 { raw = String(raw.prefix(47)) + "…" }
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let folded = fold(raw)
        var redundant: Set<String> = [fold(track.language)]
        if let languageName = languageName { redundant.insert(fold(languageName)) }
        if let bcp = track.bcp47Language {
            redundant.insert(fold(bcp))
            if let english = Locale(identifier: "en").localizedString(forLanguageCode: bcp) { redundant.insert(fold(english)) }
            if let native = Locale(identifier: bcp).localizedString(forLanguageCode: bcp) { redundant.insert(fold(native)) }
        }
        let remaining = folded.split(separator: " ").map(String.init).filter { !words.contains($0) }.joined(separator: " ")
        if remaining.isEmpty || redundant.contains(folded) || redundant.contains(remaining) { return nil }
        return raw
    }

    static func uniqueName(_ name: String, among existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var counter = 2
        while taken.contains("\(name) (\(counter))".lowercased()) { counter += 1 }
        return "\(name) (\(counter))"
    }
}
