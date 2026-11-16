//
//  SyntheticMatroska.swift
//  PopcornTimeTests
//
//  A small Matroska byte stream made in memory for the remux engine's tests: one video track
//  (H.264: a hand-written 320×240 SPS / PPS; or HEVC Main 10: the parameter sets of a real
//  stream — slices that are only a NAL header and filler, nothing here is ever decoded), one
//  audio track (AAC-LC stereo; E-AC-3 5.1 with the Atmos extension flag: a real syncframe
//  header, then filler; or 16-bit PCM, which the remux transcodes to FLAC) and, on request, a
//  second audio track, a text subtitle track, video frames in decode order (B frames) and cue
//  points that list the other tracks too. The remux copies bitstreams, so
//  everything it does with a real file it does with this one: header, tracks, clusters, cuts on
//  the keyframe grid or on the keyframe index, fMP4 segments on disk. What a test bends is a
//  field of this struct: where the keyframes are, a cluster's timestamp, the TimestampScale,
//  whether the file has a keyframe index (Cues) and where, how its clusters are sized, how its
//  audio is laced. The defaults write what they always wrote, byte for byte.
//

import Foundation

struct SyntheticMatroska {
    /// One cluster per `clusterMilliseconds` of media.
    var clusterCount = 30
    var clusterMilliseconds = 1000
    var framesPerCluster = 25
    /// Size of a video frame (bytes, NAL length prefix included).
    var videoFrameBytes = 200
    /// Whether video frame `index` (0, 1, 2… over the whole stream) is a keyframe. Default: the
    /// first of every cluster (a 1 s GOP).
    var isKeyframe: (_ index: Int, _ framesPerCluster: Int) -> Bool = { index, perCluster in index % perCluster == 0 }
    /// Cluster index → the Timestamp written for it instead of its real one (damage).
    var clusterTimestamps: [Int: UInt64] = [:]
    var timestampScale: UInt64 = 1_000_000
    /// The TimestampScale the header declares, when it lies (damage); the ticks are still
    /// written in `timestampScale`.
    var declaredTimestampScale: UInt64?
    /// Whether the header carries a Duration (without one the remux makes EVENT playlists).
    var hasDuration = true

    enum VideoCodec { case h264, hevc }
    enum AudioCodec { case aac, eac3, pcm }
    var videoCodec: VideoCodec = .h264
    var audioCodec: AudioCodec = .aac
    /// Audio frames per block. Above 1 the block is laced (fixed-size lacing): its frames share
    /// the block's timestamp unless `audioDeclaresFrameDuration`, and the last ones play after
    /// the end of the cluster the block is in.
    var audioFramesPerBlock = 1
    /// The audio track carries a DefaultDuration (the demuxer then times the frames of a lace).
    var audioDeclaresFrameDuration = false
    /// A second audio track (track 4, listed right after the first; never laced): a film's
    /// commentary or other language, of another codec than the first one.
    var secondAudioCodec: AudioCodec?
    /// The video frames after each cluster's keyframe are stored in decode order, in groups of
    /// three — a P frame, then the two B frames it is shown after (presentation order 3, 1, 2,
    /// 6, 4, 5…) — as every real HEVC and most H.264 releases are. Blocks carry their
    /// presentation time, so they are not in time order inside a cluster.
    var reorderedVideoFrames = false
    /// A text subtitle track (S_TEXT/UTF8, track 3), its cues from `subtitleCue`.
    var hasTextSubtitles = false
    /// Cue `index` (0, 1, 2…, in time order). Default: a cue every 2 s, 1.5 s long, every fifth
    /// one 4.5 s long (it spans a segment boundary from well before it).
    var subtitleCue: (_ index: Int) -> (startMs: Int, durationMs: Int, text: String) = { index in
        (index * 2000 + 300, index % 5 == 4 ? 4500 : 1500, "Cue \(index)")
    }

    enum CuesPlacement { case none, front, back }
    /// The keyframe index: a Cues element before the first Cluster or after the last one, a cue
    /// point per indexed video keyframe (CueTime, CueTrack 1, CueClusterPosition).
    var cues: CuesPlacement = .none
    /// Every `cueStride`-th keyframe is indexed (1: all of them; more: a sparse index).
    var cueStride = 1
    /// Tracks each video cue point ALSO lists (a CueTrackPositions per track, after track 1's,
    /// same Cluster): mkvmerge indexes audio and subtitle tracks too.
    var cuesAlsoListTracks: [UInt8] = []
    /// Cue point (0, 1, 2… among those written) → bytes added to its CueClusterPosition (damage:
    /// an index that points somewhere else).
    var cueOffsetErrors: [Int: Int] = [:]
    /// Cue point → ticks added to its CueTime (damage: an index that lists a time where the
    /// stream has no keyframe).
    var cueTimeErrors: [Int: Int64] = [:]
    /// Cue point (0, 1, 2… among those written) → a cue point of track 3 written right after
    /// it, at that cue point's CueTime minus these ticks: Cues in mux order (libavformat before
    /// 5.0), where a subtitle timed between a keyframe's DTS and its PTS follows its cue. The
    /// subtitle's CueClusterPosition is the keyframe's Cluster.
    var subtitleCuesBefore: [Int: Int64] = [:]
    /// With Cues: a SeekHead, first child of the Segment, that says where they are (every real
    /// muxer writes one; without it the remux only finds Cues it walks over).
    var hasSeekHead = true
    /// The Segment declares its size (mkvmerge, ffmpeg on a seekable output) instead of
    /// "unknown" (a streamed file).
    var segmentSizeKnown = false
    /// Clusters of unknown size (a live / streamed file): each ends where the next one starts.
    var unknownSizeClusters = false

    var durationSeconds: Double { Double(clusterCount * clusterMilliseconds) / 1000 }

    // MARK: EBML

    private static func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        // An 8-byte size: the simplest valid coding, whatever the length.
        return id + size8(UInt64(payload.count)) + payload
    }

    private static func size8(_ value: UInt64) -> [UInt8] {
        var size: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) { size.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
        return size
    }

    private static func uint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = value
        repeat { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 } while rest > 0
        return bytes
    }

    /// An unsigned integer on 8 bytes, whatever its value: an element that holds one keeps its
    /// size, so a position can be written before it is known.
    private static func uint8(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> UInt64(56 - 8 * $0)) & 0xFF) }
    }

    private static func float(_ value: Double) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { Array($0) }
    }

    private static let clusterID: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
    private static let cuesID: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]
    /// Size of one CuePoint as `cuePoint` writes it (one CueTrackPositions), of each more
    /// CueTrackPositions in it, and of the SeekHead as `seekHead` does.
    private static let cuePointBytes = 62
    private static let cueTrackPositionsBytes = 36
    private static let seekHeadBytes = 54

    // MARK: Codec configuration

    /// H.264 Baseline 3.0, 320×240, 8-bit 4:2:0: profile_idc 66, constraint flags 0xC0,
    /// level_idc 30, then sps_id 0, log2_max_frame_num 4, poc type 0, log2_max_poc_lsb 4,
    /// 1 reference frame, 20 × 15 macroblocks, frame_mbs_only, no cropping, no VUI.
    static let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x1E, 0xF4, 0x0A, 0x0F, 0xC8]
    static let pps: [UInt8] = [0x68, 0xCE, 0x38, 0x80]

    /// avcC: version 1, 4-byte NAL lengths, one SPS, one PPS.
    static var avcC: [UInt8] {
        [1, sps[1], sps[2], sps[3], 0xFF, 0xE1, 0, UInt8(sps.count)] + sps + [1, 0, UInt8(pps.count)] + pps
    }

    /// hvcC of a real x265 stream (HEVC Main 10, level 4, 4-byte NAL lengths; one VPS, one SPS,
    /// one PPS): what the remux reads the profile, the bit depth and the sample entry from.
    static let hvcC: [UInt8] = {
        let hex = "010220000000b0000000000078f000fcfdfafa00000b03a00001001840010c01ffff022000000300b0000003000003007815c0"
            + "90a100010024420101022000000300b00000030000030078a003c0801107cad8815ee45954d424402402a2000100084401c0"
            + "2cb8d45364"
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }()

    /// AudioSpecificConfig: AAC-LC, 48 kHz, stereo.
    static let audioSpecificConfig: [UInt8] = [0x11, 0x90]
    /// 1024 samples at 48 kHz.
    static let audioFrameMilliseconds = 1024.0 / 48.0
    /// 6 blocks of 256 samples at 48 kHz.
    static let eac3FrameMilliseconds = 1536.0 / 48.0
    static let eac3FrameBytes = 64

    /// The start of an E-AC-3 syncframe of `eac3FrameBytes` bytes (ETSI TS 102 366, E.1.2):
    /// independent substream 0, 48 kHz, 6 blocks, 3/2 + LFE, bsid 16, no mixing nor
    /// informational metadata, then addbsi with the Atmos (JOC) extension flag, complexity 16.
    static let eac3Header: [UInt8] = {
        var bits: [Bool] = []
        func put(_ value: Int, _ count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> shift) & 1 == 1) }
        }
        put(0x0B77, 16)                     // syncword
        put(0, 2); put(0, 3)                // strmtyp, substreamid
        put(eac3FrameBytes / 2 - 1, 11)     // frmsiz (16-bit words − 1)
        put(0, 2); put(3, 2)                // fscod 48 kHz, numblkscod 6 blocks
        put(7, 3); put(1, 1)                // acmod 3/2, lfeon
        put(16, 5); put(31, 5)              // bsid, dialnorm
        put(0, 1); put(0, 1); put(0, 1)     // compre, mixmdate, infomdate
        put(1, 1); put(1, 6)                // addbsie, addbsil (2 bytes)
        put(0x01, 8); put(16, 8)            // flag_ec3_extension_type_a, complexity_index_type_a
        while bits.count % 8 != 0 { bits.append(true) }
        return stride(from: 0, to: bits.count, by: 8).map { start in
            bits[start..<(start + 8)].reduce(UInt8(0)) { $0 << 1 | ($1 ? 1 : 0) }
        }
    }()

    /// 16-bit stereo PCM, 1920 samples a block at 48 kHz.
    static let pcmFrameMilliseconds = 40.0

    private var audioFrameMs: Double { Self.frameMilliseconds(audioCodec) }

    private static func frameMilliseconds(_ codec: AudioCodec) -> Double {
        switch codec {
        case .aac: return Self.audioFrameMilliseconds
        case .eac3: return Self.eac3FrameMilliseconds
        case .pcm: return Self.pcmFrameMilliseconds
        }
    }

    private func audioPayload(_ index: Int) -> [UInt8] { Self.audioPayload(index, codec: audioCodec) }

    private static func audioPayload(_ index: Int, codec: AudioCodec) -> [UInt8] {
        switch codec {
        case .aac:
            return [0x21] + (0..<31).map { UInt8(truncatingIfNeeded: 0x40 | ((index &+ $0) & 0x3F)) }
        case .eac3:
            let header = Self.eac3Header
            return header + (header.count..<Self.eac3FrameBytes).map { UInt8(truncatingIfNeeded: 0x40 | ((index &+ $0) & 0x3F)) }
        case .pcm:
            // A quiet sawtooth: 1920 frames of two little-endian 16-bit samples.
            return (0..<(1920 * 4)).map { UInt8(truncatingIfNeeded: $0 % 2 == 0 ? (index &* 7 &+ $0) & 0xFF : 0x01) }
        }
    }

    // MARK: The stream

    /// The stream and where its parts are.
    struct Layout {
        let data: Data
        /// Absolute offset of the Segment's data: what the positions of the Cues and of the
        /// SeekHead are relative to.
        let segmentDataStart: Int
        /// Absolute offset of each Cluster element.
        let clusterOffsets: [Int]
        /// The cue points written, in order: the CueTime (ticks), the cluster holding that
        /// keyframe, and the absolute offset its CueClusterPosition stands for (the cluster's,
        /// unless `cueOffsetErrors` moved it).
        let cuePoints: [(ticks: Int64, cluster: Int, writtenOffset: Int)]
        /// Absolute offset of the Cues element; nil without one.
        let cuesOffset: Int?
    }

    func data() -> Data { layout().data }

    func layout() -> Layout {
        var head: [UInt8] = []
        head += Self.element([0x1A, 0x45, 0xDF, 0xA3], Self.element([0x42, 0x82], Array("matroska".utf8)))

        var info = Self.element([0x2A, 0xD7, 0xB1], Self.uint(declaredTimestampScale ?? timestampScale))
        if hasDuration {
            // In TimestampScale ticks.
            info += Self.element([0x44, 0x89], Self.float(durationSeconds * 1e9 / Double(timestampScale)))
        }
        info += Self.element([0x4D, 0x80], Array("PopcornTimeTests".utf8))

        var video = Self.element([0xD7], [1]) + Self.element([0x73, 0xC5], [1]) + Self.element([0x83], [1])
        switch videoCodec {
        case .h264:
            video += Self.element([0x86], Array("V_MPEG4/ISO/AVC".utf8))
            video += Self.element([0x63, 0xA2], Self.avcC)
            video += Self.element([0xE0], Self.element([0xB0], Self.uint(320)) + Self.element([0xBA], Self.uint(240)))
        case .hevc:
            video += Self.element([0x86], Array("V_MPEGH/ISO/HEVC".utf8))
            video += Self.element([0x63, 0xA2], Self.hvcC)
            // BT.2020 non-constant luminance, SMPTE ST 2084 (PQ), BT.2020 primaries.
            let colour = Self.element([0x55, 0xB1], [9]) + Self.element([0x55, 0xBA], [16]) + Self.element([0x55, 0xBB], [9])
            video += Self.element([0xE0], Self.element([0xB0], Self.uint(1920)) + Self.element([0xBA], Self.uint(1080))
                                  + Self.element([0x55, 0xB0], colour))
        }
        var audio = Self.element([0xD7], [2]) + Self.element([0x73, 0xC5], [2]) + Self.element([0x83], [2])
        if audioDeclaresFrameDuration {
            audio += Self.element([0x23, 0xE3, 0x83], Self.uint(UInt64((audioFrameMs * 1_000_000).rounded())))
        }
        switch audioCodec {
        case .aac:
            audio += Self.element([0x86], Array("A_AAC".utf8))
            audio += Self.element([0x63, 0xA2], Self.audioSpecificConfig)
            audio += Self.element([0xE1], Self.element([0xB5], Self.float(48_000)) + Self.element([0x9F], [2]))
        case .eac3:
            audio += Self.element([0x86], Array("A_EAC3".utf8))
            audio += Self.element([0xE1], Self.element([0xB5], Self.float(48_000)) + Self.element([0x9F], [6]))
        case .pcm:
            audio += Self.element([0x86], Array("A_PCM/INT/LIT".utf8))
            audio += Self.element([0xE1], Self.element([0xB5], Self.float(48_000)) + Self.element([0x9F], [2])
                                  + Self.element([0x62, 0x64], [16]))
        }
        var trackEntries = Self.element([0xAE], video) + Self.element([0xAE], audio)
        if let second = secondAudioCodec {
            var entry = Self.element([0xD7], [4]) + Self.element([0x73, 0xC5], [4]) + Self.element([0x83], [2])
            switch second {
            case .aac:
                entry += Self.element([0x86], Array("A_AAC".utf8))
                entry += Self.element([0x63, 0xA2], Self.audioSpecificConfig)
                entry += Self.element([0xE1], Self.element([0xB5], Self.float(48_000)) + Self.element([0x9F], [2]))
            case .eac3:
                entry += Self.element([0x86], Array("A_EAC3".utf8))
                entry += Self.element([0xE1], Self.element([0xB5], Self.float(48_000)) + Self.element([0x9F], [6]))
            case .pcm:
                entry += Self.element([0x86], Array("A_PCM/INT/LIT".utf8))
                entry += Self.element([0xE1], Self.element([0xB5], Self.float(48_000)) + Self.element([0x9F], [2])
                                      + Self.element([0x62, 0x64], [16]))
            }
            trackEntries += Self.element([0xAE], entry)
        }
        if hasTextSubtitles {
            var subtitles = Self.element([0xD7], [3]) + Self.element([0x73, 0xC5], [3]) + Self.element([0x83], [0x11])
            subtitles += Self.element([0x86], Array("S_TEXT/UTF8".utf8))
            trackEntries += Self.element([0xAE], subtitles)
        }
        let headers = Self.element([0x15, 0x49, 0xA9, 0x66], info) + Self.element([0x16, 0x54, 0xAE, 0x6B], trackEntries)

        // The clusters, and the keyframes an index would list.
        let ticksPerMillisecond = 1_000_000.0 / Double(timestampScale)
        var clusters: [[UInt8]] = []
        var keyframes: [(ticks: Int64, cluster: Int)] = []
        var audioIndex = 0
        var secondAudioIndex = 0
        var subtitleIndex = 0
        for cluster in 0..<clusterCount {
            let startMs = cluster * clusterMilliseconds
            let clusterTicks = clusterTimestamps[cluster] ?? UInt64((Double(startMs) * ticksPerMillisecond).rounded())
            var body = Self.element([0xE7], Self.uint(clusterTicks))
            // Blocks in time order, as a muxer interleaves them (video frames: in decode order).
            var blocks: [(ms: Double, bytes: [UInt8])] = []
            for slot in 0..<framesPerCluster {
                // The frame stored in decode slot `slot`, and when that slot is.
                var frame = slot
                if reorderedVideoFrames, slot > 0, (slot - 1) / 3 * 3 + 3 < framesPerCluster {
                    frame = [2, -1, -1][(slot - 1) % 3] + slot
                }
                let slotMs = Double(slot * clusterMilliseconds) / Double(framesPerCluster)
                let ms = Double(frame * clusterMilliseconds) / Double(framesPerCluster)
                let index = cluster * framesPerCluster + frame
                let key = isKeyframe(index, framesPerCluster)
                // A length-prefixed NAL unit: an IDR slice or a non-IDR one (H.264 types 5 and
                // 1; HEVC IDR_W_RADL and TRAIL_R), then filler that is never zero (a zero run
                // reads as "not downloaded yet").
                let nalLength = max(2, videoFrameBytes - 4)
                var payload: [UInt8] = [UInt8(nalLength >> 24), UInt8((nalLength >> 16) & 0xFF), UInt8((nalLength >> 8) & 0xFF),
                                        UInt8(nalLength & 0xFF)]
                switch videoCodec {
                case .h264:
                    payload.append(key ? 0x65 : 0x41)
                    payload += (1..<nalLength).map { UInt8(truncatingIfNeeded: 0x80 | ((index &* 31 &+ $0) & 0x7F)) }
                case .hevc:
                    payload += [key ? 0x26 : 0x02, 0x01]
                    payload += (2..<nalLength).map { UInt8(truncatingIfNeeded: 0x80 | ((index &* 31 &+ $0) & 0x7F)) }
                }
                let relativeTicks = ms * ticksPerMillisecond
                blocks.append((slotMs, Self.simpleBlock(track: 1, relativeTicks: relativeTicks, keyframe: key, payload: payload)))
                if key {
                    let relative = Int64(Int16(clamping: Int(relativeTicks.rounded())))
                    keyframes.append((Int64(clamping: clusterTicks) + relative, cluster))
                }
            }
            let clusterEndMs = Double(startMs + clusterMilliseconds)
            while Double(audioIndex) * audioFrameMs < clusterEndMs {
                let ms = Double(audioIndex) * audioFrameMs - Double(startMs)
                if audioFramesPerBlock <= 1 {
                    blocks.append((ms, Self.simpleBlock(track: 2, relativeTicks: ms * ticksPerMillisecond, keyframe: true,
                                                        payload: audioPayload(audioIndex))))
                    audioIndex += 1
                } else {
                    // Fixed-size lacing: the frame count − 1, then the frames, all one size.
                    var payload: [UInt8] = [UInt8(audioFramesPerBlock - 1)]
                    for frame in 0..<audioFramesPerBlock { payload += audioPayload(audioIndex + frame) }
                    blocks.append((ms, Self.simpleBlock(track: 2, relativeTicks: ms * ticksPerMillisecond, keyframe: true,
                                                        payload: payload, lacing: 0x04)))
                    audioIndex += audioFramesPerBlock
                }
            }
            if let second = secondAudioCodec {
                let frameMs = Self.frameMilliseconds(second)
                while Double(secondAudioIndex) * frameMs < clusterEndMs {
                    let ms = Double(secondAudioIndex) * frameMs - Double(startMs)
                    blocks.append((ms, Self.simpleBlock(track: 4, relativeTicks: ms * ticksPerMillisecond, keyframe: true,
                                                        payload: Self.audioPayload(secondAudioIndex &+ 17, codec: second))))
                    secondAudioIndex += 1
                }
            }
            if hasTextSubtitles {
                while subtitleCue(subtitleIndex).startMs < startMs + clusterMilliseconds {
                    let cue = subtitleCue(subtitleIndex)
                    let ms = Double(cue.startMs - startMs)
                    let relative = UInt16(bitPattern: Int16(clamping: Int((ms * ticksPerMillisecond).rounded())))
                    let block = Self.element([0xA1], [0x83, UInt8(relative >> 8), UInt8(relative & 0xFF), 0x00] + Array(cue.text.utf8))
                    let duration = Self.element([0x9B], Self.uint(UInt64((Double(cue.durationMs) * ticksPerMillisecond).rounded())))
                    blocks.append((ms, Self.element([0xA0], block + duration)))
                    subtitleIndex += 1
                }
            }
            for block in blocks.sorted(by: { $0.ms < $1.ms }) { body += block.bytes }
            clusters.append(unknownSizeClusters ? Self.clusterID + [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + body
                                                : Self.element(Self.clusterID, body))
        }

        // Where everything goes. Every element that holds a position has a fixed size, so the
        // positions can be computed before the elements are written.
        let indexed = cues == .none ? [] : keyframes.enumerated().filter { $0.offset % max(1, cueStride) == 0 }.map(\.element)
        let cuesBytes = cues == .none ? 0
            : Self.cuesID.count + 8 + (indexed.count + subtitleCuesBefore.keys.filter { $0 < indexed.count }.count) * Self.cuePointBytes
                + indexed.count * cuesAlsoListTracks.count * Self.cueTrackPositionsBytes
        let seekHeadBytes = cues != .none && hasSeekHead ? Self.seekHeadBytes : 0
        let clustersStart = seekHeadBytes + headers.count + (cues == .front ? cuesBytes : 0)
        var relativeOffsets: [Int] = []
        var position = clustersStart
        for cluster in clusters {
            relativeOffsets.append(position)
            position += cluster.count
        }
        let cuesRelative = cues == .front ? seekHeadBytes + headers.count : position
        let segmentBytes = position + (cues == .back ? cuesBytes : 0)

        var cuesElement: [UInt8] = []
        var cuePoints: [(ticks: Int64, cluster: Int, writtenOffset: Int)] = []
        if cues != .none {
            var points: [UInt8] = []
            for (index, keyframe) in indexed.enumerated() {
                let written = relativeOffsets[keyframe.cluster] + (cueOffsetErrors[index] ?? 0)
                let ticks = keyframe.ticks + (cueTimeErrors[index] ?? 0)
                points += Self.cuePoint(ticks: UInt64(max(0, ticks)), relativeClusterOffset: UInt64(max(0, written)),
                                        alsoTracks: cuesAlsoListTracks)
                cuePoints.append((ticks, keyframe.cluster, written))
                if let earlier = subtitleCuesBefore[index] {
                    points += Self.cuePoint(ticks: UInt64(max(0, ticks - earlier)), relativeClusterOffset: UInt64(max(0, written)),
                                            track: 3)
                }
            }
            cuesElement = Self.element(Self.cuesID, points)
        }

        // Segment: of unknown size (everything that follows), or declaring it.
        head += [0x18, 0x53, 0x80, 0x67] + (segmentSizeKnown ? Self.size8(UInt64(segmentBytes))
                                                              : [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let segmentDataStart = head.count
        var bytes = head
        if seekHeadBytes > 0 { bytes += Self.seekHead(cuesRelativeOffset: UInt64(cuesRelative)) }
        bytes += headers
        if cues == .front { bytes += cuesElement }
        for cluster in clusters { bytes += cluster }
        if cues == .back { bytes += cuesElement }
        return Layout(data: Data(bytes), segmentDataStart: segmentDataStart,
                      clusterOffsets: relativeOffsets.map { $0 + segmentDataStart },
                      cuePoints: cuePoints.map { ($0.ticks, $0.cluster, $0.writtenOffset + segmentDataStart) },
                      cuesOffset: cues == .none ? nil : cuesRelative + segmentDataStart)
    }

    private static func simpleBlock(track: UInt8, relativeTicks: Double, keyframe: Bool, payload: [UInt8],
                                    lacing: UInt8 = 0) -> [UInt8] {
        let relative = UInt16(bitPattern: Int16(clamping: Int(relativeTicks.rounded())))
        return element([0xA3], [0x80 | track, UInt8(relative >> 8), UInt8(relative & 0xFF), (keyframe ? 0x80 : 0x00) | lacing] + payload)
    }

    /// CuePoint { CueTime, CueTrackPositions { CueTrack, CueClusterPosition } }, `cuePointBytes` long
    /// (plus `cueTrackPositionsBytes` for each of `alsoTracks`, listed at the same Cluster).
    private static func cuePoint(ticks: UInt64, relativeClusterOffset: UInt64, track: UInt8 = 1, alsoTracks: [UInt8] = []) -> [UInt8] {
        var positions: [UInt8] = []
        for listed in [track] + alsoTracks {
            positions += element([0xB7], element([0xF7], [listed]) + element([0xF1], uint8(relativeClusterOffset)))
        }
        return element([0xBB], element([0xB3], uint8(ticks)) + positions)
    }

    /// SeekHead { Seek { SeekID Cues, SeekPosition } }, `seekHeadBytes` long.
    private static func seekHead(cuesRelativeOffset: UInt64) -> [UInt8] {
        let seek = element([0x53, 0xAB], cuesID) + element([0x53, 0xAC], uint8(cuesRelativeOffset))
        return element([0x11, 0x4D, 0x9B, 0x74], element([0x4D, 0xBB], seek))
    }

    /// Writes the stream to a new file in a fresh temporary directory; returns the file and a
    /// directory for the remux output next to it.
    func write() throws -> (input: URL, output: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopcornTimeTests-remux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("synthetic.mkv")
        try data().write(to: input)
        return (input, directory.appendingPathComponent("hls", isDirectory: true), directory)
    }
}
