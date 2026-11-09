

import Foundation

// CONTRACT FILE — owned by agent A4. Pure playlist text generation (no I/O)
// so it can be unit-tested headlessly.
//
// Everything served to AVPlayer by `RemuxPlayback` is built here:
//  - one master playlist: a single video variant + an AUDIO group (one
//    demuxed rendition per playable audio track — the only place where
//    `CHANNELS="16/JOC"` can be attached, which is what tvOS reads to light
//    the receiver's Dolby Atmos badge) + a SUBTITLES group (embedded text
//    tracks as segmented WebVTT, then OpenSubtitles files);
//  - VOD media playlists spanning the whole movie from the first request
//    (real durations for the segments cut so far, then the planned
//    durations of the rest when the file's keyframe index is readable, else
//    estimates for the tail adding up to the movie's duration; ENDLIST) so
//    AVPlayer shows the full timeline / scrubber immediately — the session
//    freezes that EXTINF list the first time it is served (`vodDurations`
//    or its own plan, then `media` with it as the actual durations); EVENT
//    playlists (existing segments only, ENDLIST once complete) when the
//    movie's length is unknown;
//  - single-file playlists for external (whole-file) WebVTT subtitles.

enum HLSPlaylists {

    /// An OpenSubtitles track exposed next to the embedded ones.
    struct ExternalSubtitle: Equatable {
        let name: String
        /// BCP 47 language tag ("fr", "en"…).
        let language: String
        /// Playlist URI, e.g. "sub_fr.m3u8".
        let uri: String
        var isDefault: Bool = false
        var autoselect: Bool = true
    }

    /// AVFoundation media characteristics carried by `CHARACTERISTICS`.
    enum Characteristic {
        /// Audio description for the visually impaired.
        static let describesVideo = "public.accessibility.describes-video"
        /// SDH / closed-caption style subtitles.
        static let transcribesDialog = "public.accessibility.transcribes-spoken-dialog"
        static let describesMusicAndSound = "public.accessibility.describes-music-and-sound"
        /// Commentary and other auxiliary audio (`AVMediaCharacteristic.isAuxiliaryContent`):
        /// excluded from AVFoundation's automatic media selection.
        static let auxiliaryContent = "public.auxiliary-content"
    }

    static let audioGroupID = "aud"
    static let subtitleGroupID = "subs"

    /// Master playlist: one video variant + AUDIO group (every audio
    /// rendition) + SUBTITLES group (embedded text tracks then external).
    ///
    /// Invariants enforced here whatever the caller passes: exactly one
    /// `DEFAULT=YES` audio rendition, at most one `DEFAULT=YES` subtitle
    /// rendition, `AUTOSELECT=YES` whenever `DEFAULT=YES`, a forced subtitle
    /// rendition is never `DEFAULT`, and NAMEs are unique within each group.
    /// `averageBandwidth` (optional) adds `AVERAGE-BANDWIDTH`.
    /// `closedCaptionsNone` declares `CLOSED-CAPTIONS=NONE`: without it
    /// AVPlayer assumes CEA-608 captions may hide in the video and lists a
    /// phantom "CC" option (even as the legible group's default) whenever no
    /// subtitle rendition exists — verified on macOS 26.
    static func master(video: MKVToHLSRemuxSession.VideoRendition,
                       audio: [MKVToHLSRemuxSession.AudioRendition],
                       subtitles: [MKVToHLSRemuxSession.SubtitleRendition],
                       external: [ExternalSubtitle],
                       bandwidth: Int,
                       averageBandwidth: Int? = nil,
                       closedCaptionsNone: Bool = true) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]

        // AUDIO group --------------------------------------------------------
        let defaultAudio = audio.firstIndex(where: { $0.isDefault }) ?? (audio.isEmpty ? nil : 0)
        var audioNames = UniqueNames()
        for (position, rendition) in audio.enumerated() {
            let isDefault = position == defaultAudio
            var attributes = [
                "TYPE=AUDIO",
                "GROUP-ID=\(quoted(audioGroupID))",
                "NAME=\(quoted(audioNames.unique(rendition.name)))",
            ]
            if let language = rendition.language, !language.isEmpty {
                attributes.append("LANGUAGE=\(quoted(language))")
            }
            attributes.append("DEFAULT=\(yesNo(isDefault))")
            attributes.append("AUTOSELECT=\(yesNo(isDefault || rendition.autoselect))")
            var characteristics: [String] = []
            if rendition.isAudioDescription { characteristics.append(Characteristic.describesVideo) }
            if rendition.isCommentary { characteristics.append(Characteristic.auxiliaryContent) }
            if !characteristics.isEmpty {
                attributes.append("CHARACTERISTICS=\(quoted(characteristics.joined(separator: ",")))")
            }
            if !rendition.channels.isEmpty {
                attributes.append("CHANNELS=\(quoted(rendition.channels))")
            }
            attributes.append("URI=\(quoted(rendition.playlistName))")
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }

        // SUBTITLES group (embedded first, then external) ---------------------
        let defaultEmbedded = subtitles.firstIndex(where: { $0.isDefault && !$0.isForced })
        let defaultExternal = defaultEmbedded == nil ? external.firstIndex(where: { $0.isDefault }) : nil
        var subtitleNames = UniqueNames()
        for (position, rendition) in subtitles.enumerated() {
            let isDefault = position == defaultEmbedded
            var attributes = [
                "TYPE=SUBTITLES",
                "GROUP-ID=\(quoted(subtitleGroupID))",
                "NAME=\(quoted(subtitleNames.unique(rendition.name)))",
            ]
            if let language = rendition.language, !language.isEmpty {
                attributes.append("LANGUAGE=\(quoted(language))")
            }
            attributes.append("DEFAULT=\(yesNo(isDefault))")
            attributes.append("AUTOSELECT=\(yesNo(isDefault || rendition.autoselect || rendition.isForced))")
            if rendition.isForced { attributes.append("FORCED=YES") }
            if rendition.isSDH {
                attributes.append("CHARACTERISTICS=\(quoted(Characteristic.transcribesDialog + "," + Characteristic.describesMusicAndSound))")
            }
            attributes.append("URI=\(quoted(rendition.playlistName))")
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }
        for (position, subtitle) in external.enumerated() {
            let isDefault = position == defaultExternal
            var attributes = [
                "TYPE=SUBTITLES",
                "GROUP-ID=\(quoted(subtitleGroupID))",
                "NAME=\(quoted(subtitleNames.unique(subtitle.name)))",
            ]
            if !subtitle.language.isEmpty {
                attributes.append("LANGUAGE=\(quoted(subtitle.language))")
            }
            attributes.append("DEFAULT=\(yesNo(isDefault))")
            attributes.append("AUTOSELECT=\(yesNo(isDefault || subtitle.autoselect))")
            attributes.append("URI=\(quoted(subtitle.uri))")
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }

        // Variant ---------------------------------------------------------------
        // CODECS must list every codec of the variant AND of its renditions
        // (HLS spec / Apple authoring spec), each audio codec once.
        var codecs = [video.codecs]
        for rendition in audio where !rendition.codecs.isEmpty && !codecs.contains(rendition.codecs) {
            codecs.append(rendition.codecs)
        }
        var attributes = ["BANDWIDTH=\(max(1, bandwidth))"]
        if let average = averageBandwidth, average > 0 {
            attributes.append("AVERAGE-BANDWIDTH=\(min(average, max(1, bandwidth)))")
        }
        attributes.append("CODECS=\(quoted(codecs.joined(separator: ",")))")
        if let supplemental = video.supplementalCodecs, !supplemental.isEmpty {
            attributes.append("SUPPLEMENTAL-CODECS=\(quoted(supplemental))")
        }
        if video.width > 0, video.height > 0 {
            attributes.append("RESOLUTION=\(video.width)x\(video.height)")
        }
        if let frameRate = video.frameRate, frameRate.isFinite, frameRate > 0 {
            attributes.append("FRAME-RATE=\(String(format: "%.3f", frameRate))")
        }
        attributes.append("VIDEO-RANGE=\(videoRange(video.videoRange))")
        if !audio.isEmpty { attributes.append("AUDIO=\(quoted(audioGroupID))") }
        if !subtitles.isEmpty || !external.isEmpty { attributes.append("SUBTITLES=\(quoted(subtitleGroupID))") }
        if closedCaptionsNone { attributes.append("CLOSED-CAPTIONS=NONE") }
        lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        lines.append(video.playlistName)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Media playlist flavours.
    enum PlaylistType: Equatable {
        /// The whole movie is announced up front (real durations, then
        /// estimates for the segments still to come) and `#EXT-X-ENDLIST`:
        /// AVPlayer fetches it once and shows the full scrubber at once.
        case vod
        /// Movie length unknown (no Duration in the Matroska header): only
        /// the segments listed exist, AVPlayer keeps reloading the playlist,
        /// and `#EXT-X-ENDLIST` is appended once the remux has `ended`.
        /// The type stays EVENT in every update (RFC 8216 §6.2.1: a server
        /// may only append to a playlist, e.g. the ENDLIST tag).
        case event(ended: Bool)
    }

    /// Shortest EXTINF given to an estimated entry (a grid slot already
    /// covered by long real segments, or a remainder that rounds to nothing).
    static let minimumEstimatedDuration = 0.05

    /// Media playlist. `mapURI` nil for WebVTT playlists.
    ///
    /// `.vod` spans the whole movie: the EXTINF list is `vodDurations` (real
    /// durations for the segments cut so far, then estimates for
    /// `expectedSegments` in total), then ENDLIST. A list frozen earlier is
    /// served again byte for byte by passing it as `actualDurations` with
    /// `expectedSegments` 0 (`vodDurations` returns it unchanged).
    ///
    /// `.event` lists `actualDurations` only (estimates ignored).
    ///
    /// `#EXT-X-TARGETDURATION`: the longest EXTINF rounded up, at least the
    /// target rounded up + 2 (8 with the 6 s target). An EVENT playlist
    /// follows the same rule while it grows: its tag rises when a segment
    /// longer than every listed one is appended (a longer keyframe interval;
    /// AVPlayer then reloads at the new interval — macOS 27, 8 → 11 s, no
    /// stall) rather than being sized up front for the longest interval an
    /// encoder declares — AVPlayer stays three target durations behind the
    /// end of a growing playlist, so a large tag keeps it far from the remux
    /// frontier.
    static func media(mapURI: String?,
                      segmentPrefix: String,
                      segmentExtension: String,
                      actualDurations: [Double],
                      expectedSegments: Int,
                      targetDuration: Double,
                      estimatedTotalSeconds: Double? = nil,
                      type: PlaylistType = .vod) -> String {
        let target = targetDuration.isFinite && targetDuration > 0 ? targetDuration : 6
        let durations: [Double]
        if type == .vod {
            durations = vodDurations(actualDurations: actualDurations, expectedSegments: expectedSegments,
                                     targetDuration: target, estimatedTotalSeconds: estimatedTotalSeconds)
        } else {
            durations = sanitized(actualDurations)
        }
        // EXTINF rounded to the nearest integer must not exceed the target
        // duration; keep 2 s of headroom over the target so the tail
        // estimates of later fetches stay valid even when a GOP overshoots.
        let longest = durations.max() ?? 0
        let targetTag = max(Int(longest.rounded(.up)), Int(target.rounded(.up)) + 2)
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetTag)",
            "#EXT-X-MEDIA-SEQUENCE:0",
        ]
        switch type {
        case .vod:
            lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        case .event:
            lines.append("#EXT-X-PLAYLIST-TYPE:EVENT")
            // Without it AVPlayer joins an unfinished EVENT playlist near
            // its live edge (the end) instead of at the movie's start.
            lines.append("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES")
        }
        if let map = mapURI {
            lines.append("#EXT-X-MAP:URI=\(quoted(map))")
        }
        for (index, duration) in durations.enumerated() {
            lines.append("#EXTINF:\(String(format: "%.3f", duration)),")
            lines.append("\(segmentPrefix)\(index).\(segmentExtension)")
        }
        switch type {
        case .vod, .event(ended: true):
            lines.append("#EXT-X-ENDLIST")
        case .event(ended: false):
            break
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The EXTINF list of a `.vod` media playlist: the real durations of the
    /// segments cut so far (`actualDurations`; a value that is not a
    /// positive number becomes 1 ms), then estimates for `expectedSegments`
    /// entries in total (`estimatedTail`). Each estimate is one grid slot:
    /// `targetDuration`, or `leadingTarget` for the first `leadingSlots`
    /// entries (the session's first slots, see
    /// `MKVToHLSRemuxSession.gridBoundary`) — the first one, the segment
    /// being cut, ending at `firstEnd` when given (the session's slots are
    /// then centred on the expected cuts: estimates on that grid). Without
    /// `firstEnd`, the keyframe drift of the real segments (cut at the first
    /// keyframe at or after each grid boundary) is carried over: an
    /// estimated start lands within about one GOP of the real one as long as
    /// every grid slot holds a keyframe (F01: every cut ~2 s after the
    /// boundary). A slot without a keyframe loses a segment index and the
    /// estimates after it drift by a whole slot, for good — the session's
    /// target covers the stream's longest keyframe interval to avoid that,
    /// and the session lists exact durations instead of estimates when the
    /// file's keyframe index is readable.
    /// With `estimatedTotalSeconds` (movie length measured from the start
    /// of the first segment) the LAST entry ends exactly at the movie's end,
    /// and when the drift leaves no room for it the entries before it are
    /// shortened instead of the playlist running past the end: the EXTINF
    /// always add up to the movie, and no entry announces media that doesn't
    /// exist — a seek into such a phantom tail never completes in AVPlayer
    /// while a subtitle rendition is selected (F2, F05). Without it, every
    /// estimate is one slot. Idempotent: the result passed back with
    /// `expectedSegments` 0 comes back unchanged.
    static func vodDurations(actualDurations: [Double], expectedSegments: Int, targetDuration: Double,
                             estimatedTotalSeconds: Double? = nil,
                             leadingTarget: Double? = nil, leadingSlots: Int = 0, firstEnd: Double? = nil) -> [Double] {
        let target = targetDuration.isFinite && targetDuration > 0 ? targetDuration : 6
        let actual = sanitized(actualDurations)
        return actual + estimatedTail(actual: actual, expectedSegments: expectedSegments, target: target,
                                      movieSeconds: estimatedTotalSeconds,
                                      leadingTarget: leadingTarget, leadingSlots: leadingSlots, firstEnd: firstEnd)
    }

    /// Durations as listed: a value that is not a positive number becomes 1 ms.
    private static func sanitized(_ durations: [Double]) -> [Double] {
        durations.map { $0.isFinite && $0 > 0 ? $0 : 0.001 }
    }

    /// Estimated EXTINF of the segments `actual.count ..< expectedSegments`
    /// (see `vodDurations`): one slot each (`leadingTarget` for the entries
    /// below `leadingSlots`, `target` after), the first one ending at
    /// `firstEnd` when that leaves it at least `minimumEstimatedDuration`;
    /// with `movieSeconds`, the last one ends at the movie's end and every
    /// other one ends early enough to leave the remaining entries
    /// `minimumEstimatedDuration` before it.
    static func estimatedTail(actual: [Double], expectedSegments: Int, target: Double, movieSeconds: Double?,
                              leadingTarget: Double? = nil, leadingSlots: Int = 0, firstEnd: Double? = nil) -> [Double] {
        let total = max(expectedSegments, actual.count)
        guard total > actual.count else { return [] }
        let movie = movieSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let minimum = minimumEstimatedDuration
        let leading = leadingTarget.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? target
        var cursor = actual.reduce(0, +)
        var tail: [Double] = []
        tail.reserveCapacity(total - actual.count)
        for k in actual.count..<total {
            var end = cursor + (k < leadingSlots ? leading : target)
            if k == actual.count, let first = firstEnd, first.isFinite, first >= cursor + minimum { end = first }
            if let movie = movie {
                end = k == total - 1 ? movie : min(end, movie - minimum * Double(total - 1 - k))
            }
            let duration = max(minimum, end - cursor)
            tail.append(duration)
            cursor += duration
        }
        return tail
    }

    /// Single-segment VOD playlist for an external (whole-file) WebVTT.
    static func singleFileSubtitle(uri: String, durationSeconds: Double) -> String {
        let duration = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : 7200
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(1, Int(duration.rounded(.up))))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXTINF:\(String(format: "%.3f", duration)),",
            uri,
            "#EXT-X-ENDLIST",
        ].joined(separator: "\n") + "\n"
    }

    /// The WebVTT header line mapping the file's local time 0 to the media
    /// time `mpegts` (90 kHz MPEG-2 PTS units, wrapped to 33 bits).
    static func timestampMapLine(mpegts: Int64) -> String {
        "X-TIMESTAMP-MAP=MPEGTS:\(max(0, mpegts) & 0x1_FFFF_FFFF),LOCAL:00:00:00.000"
    }

    /// `vtt` with exactly one `X-TIMESTAMP-MAP` header line: the one for
    /// `mpegts`, right after the `WEBVTT` line. Any map already in the header
    /// block (up to the first blank line) is dropped, so a converter's
    /// default `MPEGTS:0` can never shadow the real one (AVPlayer reads the
    /// first). Line endings are kept.
    ///
    /// Why: AVPlayer's HLS clock starts at 0 on the first frame, i.e. at the
    /// media time `MKVToHLSRemuxSession.timelineStart90k` — 600 s for a file
    /// cut with ffmpeg -copyts, ~0 normally. Embedded WebVTT segments carry
    /// media times (MPEGTS:0); an external subtitle file is timed from the
    /// movie's start, so its local 0 maps to that first-frame time.
    static func withTimestampMap(_ vtt: String, mpegts: Int64) -> String {
        let map = timestampMapLine(mpegts: mpegts)
        var lines = vtt.components(separatedBy: "\n")
        guard !lines.isEmpty, !(lines.count == 1 && lines[0].isEmpty) else { return "WEBVTT\n" + map + "\n\n" }
        let crlf = lines[0].hasSuffix("\r")
        // Header block: the lines after WEBVTT up to the first blank one.
        var index = 1
        while index < lines.count {
            let line = lines[index].hasSuffix("\r") ? String(lines[index].dropLast()) : lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if line.hasPrefix("X-TIMESTAMP-MAP") { lines.remove(at: index) } else { index += 1 }
        }
        lines.insert(map + (crlf ? "\r" : ""), at: 1)
        // "WEBVTT" alone (no blank line after the header): end the header.
        if lines.count == 2 { lines.append(crlf ? "\r" : ""); lines.append("") }
        return lines.joined(separator: "\n")
    }

    /// Makes a value safe inside a quoted-string attribute (no `"`, CR, LF).
    static func quoted(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(cleaned)\""
    }

    // MARK: - Helpers

    private static func yesNo(_ flag: Bool) -> String { flag ? "YES" : "NO" }

    /// VIDEO-RANGE is an enumerated string: SDR, PQ or HLG only.
    private static func videoRange(_ value: String) -> String {
        switch value.uppercased() {
        case "PQ": return "PQ"
        case "HLG": return "HLG"
        default: return "SDR"
        }
    }

    /// NAME must be unique within a rendition group: suffix duplicates
    /// " (2)", " (3)"…
    private struct UniqueNames {
        private var used = Set<String>()
        mutating func unique(_ name: String) -> String {
            let base = name.isEmpty ? "Piste" : name
            var candidate = base
            var counter = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base) (\(counter))"
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }
}
