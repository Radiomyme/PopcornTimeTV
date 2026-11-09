

import Foundation
import CoreMedia
import VideoToolbox

// CONTRACT FILE — owned by agent A2 (codec layer). Signatures below are the
// agreed API between the demuxer, the session and the HLS layer; extend
// freely, but do not rename / remove members without updating callers.
//
// Turns a demuxed Matroska track (+ its first frames) into everything the
// fMP4 / HLS layers need: a complete ISO-BMFF sample entry (configuration
// box + colour / HDR / Dolby Vision boxes), the RFC 6381 codec string, the
// HLS signalling (VIDEO-RANGE, SUPPLEMENTAL-CODECS, CHANNELS) and exact
// per-frame durations. Pure Foundation (+ CoreMedia / VideoToolbox
// constants): no UIKit / AVKit / PopcornKit.
//
// Specs followed: ISO/IEC 14496-12 (ISO BMFF), 14496-15 (AVC/HEVC file
// format), 14496-3 (AudioSpecificConfig), 14496-1 (esds descriptors),
// ITU-T H.264 / H.265 (SPS, VUI, SEI), ETSI TS 102 366 (AC-3 / E-AC-3, incl.
// Annex E bsi() and Annex F dac3 / dec3), ETSI TS 103 420 (E-AC-3 JOC),
// AV1 bitstream + AV1-ISOBMFF, Dolby Vision streams within the ISO BMFF
// v2.x, Opus in ISOBMFF, FLAC in ISOBMFF, the ALAC magic cookie and the
// Apple HLS Authoring Specification.

/// Why a track (or the whole file) can't go through the native remux path.
struct RemuxUnsupported: Error, CustomStringConvertible, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { reason }
}

/// HLS `VIDEO-RANGE`.
enum RemuxVideoRange: String {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"
}

/// Colour description code points (ISO/IEC 23091-2, same numbering as the
/// H.264/HEVC VUI and the Matroska Colour element).
struct RemuxColorInfo: Equatable {
    var primaries: Int?
    var transfer: Int?
    var matrix: Int?
    var fullRange: Bool?
    var bitDepth: Int?
}

/// Everything the session / HLS layer needs to mux and signal a video track.
struct RemuxVideoPlan {
    enum Codec: Equatable {
        case avc
        case hevc
        case av1
        /// Dolby Vision carried in HEVC. `compatibilityID` is
        /// `dv_bl_signal_compatibility_id` (1 = HDR10, 2 = SDR, 4 = HLG, 0 = none).
        case dolbyVision(profile: Int, level: Int, compatibilityID: Int)
    }

    let codec: Codec
    /// Complete visual sample entry box (`avc1` / `hvc1` / `dvh1` / `av01`)
    /// including its configuration box and, when known, `colr`, `pasp`,
    /// `mdcv`, `clli`, `dvcC`/`dvvC`.
    let sampleEntry: Data
    /// RFC 6381 token for the variant's `CODECS` (e.g. "hvc1.2.4.L153.B0").
    let codecsString: String
    /// HLS `SUPPLEMENTAL-CODECS` (Dolby Vision profile 8 back-compatible
    /// streams, e.g. "dvh1.08.06/db1p"); nil otherwise.
    let supplementalCodecs: String?
    let videoRange: RemuxVideoRange
    /// Presentation size (tkhd / RESOLUTION), aspect ratio applied.
    let displayWidth: Int
    let displayHeight: Int
    /// Coded size (sample entry width/height).
    let codedWidth: Int
    let codedHeight: Int
    /// Nominal frame rate (from DefaultDuration) for `FRAME-RATE`, if known.
    let frameRate: Double?
    /// Human readable, for logs / the stats overlay ("HEVC Main 10 · HDR10 · 3840×2160").
    let summary: String
    /// Optional per-sample payload rewrite (e.g. dropping Dolby Vision
    /// profile 7 enhancement-layer NAL units). nil = copy bytes untouched.
    let transform: ((Data) -> Data)?
}

/// Everything the session / HLS layer needs to mux and signal an audio track.
struct RemuxAudioPlan {
    enum Codec: String {
        case ac3, eac3, aac, flac, opus, mp3, alac
    }

    let codec: Codec
    /// Complete audio sample entry box (`ac-3`, `ec-3`, `mp4a`, `fLaC`, `Opus`,
    /// `alac`, or QuickTime-style `.mp3` / `.mp2` — AVFoundation ignores MPEG-1/2
    /// audio declared as `mp4a` + esds OTI 0x6B/0x69).
    let sampleEntry: Data
    /// RFC 6381 token ("ac-3", "ec-3", "mp4a.40.2", "mp4a.40.5", "mp4a.40.29",
    /// "fLaC", "Opus", "alac", "mp4a.40.34" for MP3, "mp4a.40.33" for MP2).
    /// Verified against AVPlayer's HLS variant check: lowercase "opus" and the
    /// OTI forms "mp4a.6B" / "mp4a.69" make the variant unplayable ("Cannot
    /// Open", CoreMedia -15517 — Opus stereo and 5.1 alike); "Opus" plays.
    let codecsString: String
    /// HLS `CHANNELS` ("2", "6", "8", or "16/JOC" for Dolby Atmos in E-AC-3):
    /// the channels Apple's decoder outputs, never more (E-AC-3 caps at 7.1).
    let channelsAttribute: String
    /// Decoded channel count (same number as `channelsAttribute` except Atmos).
    let channelCount: Int
    /// Track timescale (normally the sample rate; 48000 for Opus).
    let timescale: UInt32
    let isAtmos: Bool
    /// Human readable ("E-AC-3 5.1 · Dolby Atmos", "AAC-LC 2.0", "FLAC 7.1 24 bits").
    let summary: String
    /// Duration of one demuxed frame (block payload) in `timescale` units.
    let frameDuration: (Data) -> UInt32
    /// Fallback duration when a frame can't be parsed.
    let nominalFrameDuration: UInt32
    /// Optional per-frame payload rewrite applied BEFORE muxing (e.g.
    /// stripping stray ADTS headers from AAC blocks). nil = copy untouched.
    let transform: ((Data) -> Data)?
}

/// Parsed E-AC-3 access unit (all syncframes of one block).
struct EAC3Info: Equatable {
    struct Substream: Equatable {
        var independent: Bool
        var substreamID: Int
        var fscod: Int
        var bsid: Int
        var bsmod: Int
        var acmod: Int
        var lfeon: Int
        var frameBytes: Int
        /// `chanmap` (dependent substreams only), 16 bits.
        var chanmap: Int?
    }
    var sampleRate: Int
    var blocksPerSyncframe: Int
    /// PCM samples per access unit (256 × blocks × independent substream-0
    /// syncframes in the block: 1536 for a normal Matroska E-AC-3 block).
    var samplesPerFrame: Int
    /// Syncframes of the first frame set: independent substream 0, its
    /// dependent substreams, then any further independent substream (+ deps).
    var substreams: [Substream]
    /// Total decoded channels incl. LFE (5.1 = 6, 7.1 = 8).
    var channelCount: Int
    /// Data rate in kbit/s over all substreams.
    var dataRateKbps: Int
    /// `flag_ec3_extension_type_a` found in the BSI `addbsi` (Dolby Atmos JOC).
    var hasJOC: Bool
    var jocComplexityIndex: Int?
    /// (A2 addition) True when every syncframe's bsi() was parsed through
    /// `addbsi` without running out of data — i.e. `hasJOC == false` is a
    /// real "no Atmos" answer, not an unknown.
    var bsiComplete: Bool = true
    /// (A2 addition) Channel locations of the main program as a 16-bit
    /// E-AC-3 `chanmap`-style mask (bit 15 = L … bit 0 = LFE).
    var channelMask: Int = 0
}

/// Parsed AC-3 syncframe header.
struct AC3Info: Equatable {
    var fscod: Int
    var frmsizecod: Int
    var bsid: Int
    var bsmod: Int
    var acmod: Int
    var lfeon: Int
    var sampleRate: Int
    var bitrateKbps: Int
    var channelCount: Int
    /// (A2 additions) syncframe size in bytes, and the optional bsi fields.
    var frameBytes: Int = 0
    var cmixlev: Int? = nil
    var surmixlev: Int? = nil
    var dsurmod: Int? = nil
}

enum RemuxCodecs {

    /// Classification from the Matroska CodecID alone (before any frame).
    enum Support: Equatable {
        case supported
        /// Decodable but needs an on-device lossless re-encode (PCM → FLAC).
        case needsTranscode
        case unsupported(String)
    }

    static func videoSupport(codecID: String) -> Support {
        let id = codecID.uppercased()
        switch id {
        case "V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC":
            return .supported
        case "V_AV1":
            return av1HardwareDecodeAvailable ? .supported : .unsupported("AV1 sans décodage matériel")
        case "V_VP8":
            return .unsupported("VP8 non pris en charge par AVPlayer")
        case "V_VP9":
            return .unsupported("VP9 non pris en charge par AVPlayer")
        case "V_MPEG1":
            return .unsupported("MPEG-1 vidéo non pris en charge par AVPlayer")
        case "V_MPEG2":
            return .unsupported("MPEG-2 vidéo non pris en charge par AVPlayer")
        case "V_MPEGI/ISO/VVC":
            return .unsupported("VVC (H.266) non pris en charge par AVPlayer")
        case "V_THEORA":
            return .unsupported("Theora non pris en charge par AVPlayer")
        case "V_PRORES":
            return .unsupported("ProRes en Matroska non pris en charge par AVPlayer")
        case "V_MS/VFW/FOURCC":
            return .unsupported("Vidéo VfW (AVI) non prise en charge par AVPlayer")
        case "V_QUICKTIME":
            return .unsupported("Vidéo QuickTime en Matroska non prise en charge par AVPlayer")
        case "V_UNCOMPRESSED":
            return .unsupported("Vidéo non compressée non prise en charge par AVPlayer")
        case "V_DIRAC":
            return .unsupported("Dirac non pris en charge par AVPlayer")
        case "V_FFV1":
            return .unsupported("FFV1 non pris en charge par AVPlayer")
        case "":
            return .unsupported("Piste vidéo sans codec")
        default:
            if id.hasPrefix("V_MPEG4/ISO/") { return .unsupported("MPEG-4 Part 2 (DivX/Xvid) non pris en charge par AVPlayer") }
            if id.hasPrefix("V_MPEG4/MS/") { return .unsupported("MS-MPEG-4 (DivX 3) non pris en charge par AVPlayer") }
            if id.hasPrefix("V_REAL/") { return .unsupported("RealVideo non pris en charge par AVPlayer") }
            return .unsupported("Codec vidéo \(codecID) non pris en charge par AVPlayer")
        }
    }

    static func audioSupport(codecID: String) -> Support {
        let id = codecID.uppercased()
        switch id {
        case "A_AC3", "A_AC3/BSID9", "A_AC3/BSID10", "A_EAC3":
            return .supported
        case "A_AAC", "A_AAC/MPEG2/LC", "A_AAC/MPEG4/LC", "A_AAC/MPEG2/LC/SBR", "A_AAC/MPEG4/LC/SBR":
            return .supported
        case "A_FLAC", "A_OPUS", "A_MPEG/L3", "A_MPEG/L2", "A_ALAC":
            return .supported
        case "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE":
            return .needsTranscode
        case "A_TRUEHD":
            return .unsupported("TrueHD non décodable par Apple")
        case "A_MLP":
            return .unsupported("MLP non décodable par Apple")
        case "A_VORBIS":
            return .unsupported("Vorbis non pris en charge par AVPlayer")
        case "A_MS/ACM":
            return .unsupported("Audio ACM (AVI) non pris en charge par AVPlayer")
        case "A_TTA1":
            return .unsupported("TTA non pris en charge par AVPlayer")
        case "A_WAVPACK4":
            return .unsupported("WavPack non pris en charge par AVPlayer")
        case "A_MPEG/L1":
            return .unsupported("MPEG-1 Layer I non pris en charge par AVPlayer")
        case "":
            return .unsupported("Piste audio sans codec")
        default:
            if id.hasPrefix("A_DTS") { return .unsupported("DTS non décodable par Apple") }
            if id.hasPrefix("A_AAC/") { return .unsupported("AAC Main/SSR/LTP non décodable par Apple") }
            if id.hasPrefix("A_REAL/") { return .unsupported("RealAudio non pris en charge par AVPlayer") }
            if id.hasPrefix("A_QUICKTIME") { return .unsupported("Audio QuickTime (QDesign) non pris en charge par AVPlayer") }
            return .unsupported("Codec audio \(codecID) non pris en charge par AVPlayer")
        }
    }

    /// AV1 can only go native where VideoToolbox decodes it in hardware
    /// (A17 Pro / M3 and later). Elsewhere AV1 stays on VLC (dav1d).
    static var av1HardwareDecodeAvailable: Bool {
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        }
        return false
    }

    /// Build the video plan. `sampleFrames` = the first few demuxed frames of
    /// the track (used e.g. to sniff Dolby Vision RPUs / AV1 sequence headers
    /// when CodecPrivate is incomplete). `releaseTags` hints are NOT used for
    /// codec decisions, only as a last-resort VIDEO-RANGE hint.
    static func makeVideoPlan(track: MKVTrack, sampleFrames: [Data], releaseHintsHDR: Bool) -> Result<RemuxVideoPlan, RemuxUnsupported> {
        if case .unsupported(let reason) = videoSupport(codecID: track.codecID) {
            return .failure(RemuxUnsupported(reason))
        }
        switch track.codecID.uppercased() {
        case "V_MPEG4/ISO/AVC":
            return makeAVCPlan(track: track, sampleFrames: sampleFrames, releaseHintsHDR: releaseHintsHDR)
        case "V_MPEGH/ISO/HEVC":
            return makeHEVCPlan(track: track, sampleFrames: sampleFrames, releaseHintsHDR: releaseHintsHDR)
        case "V_AV1":
            return makeAV1Plan(track: track, sampleFrames: sampleFrames, releaseHintsHDR: releaseHintsHDR)
        default:
            return .failure(RemuxUnsupported("Codec vidéo \(track.codecID) non pris en charge par AVPlayer"))
        }
    }

    /// Build the audio plan from the track + its first frame.
    /// `releaseTaggedAtmos` is only a fallback when the E-AC-3 BSI can't be
    /// parsed far enough to find the JOC extension.
    static func makeAudioPlan(track: MKVTrack, firstFrame: Data, releaseTaggedAtmos: Bool) -> Result<RemuxAudioPlan, RemuxUnsupported> {
        switch audioSupport(codecID: track.codecID) {
        case .unsupported(let reason):
            return .failure(RemuxUnsupported(reason))
        case .needsTranscode:
            return .failure(RemuxUnsupported("PCM : réencodage FLAC requis (RemuxAudioTranscoder)"))
        case .supported:
            break
        }
        let id = track.codecID.uppercased()
        if id.hasPrefix("A_AC3") || id == "A_EAC3" {
            return makeDolbyAudioPlan(track: track, firstFrame: firstFrame, releaseTaggedAtmos: releaseTaggedAtmos)
        }
        if id.hasPrefix("A_AAC") { return makeAACPlan(track: track, firstFrame: firstFrame) }
        switch id {
        case "A_FLAC": return makeFLACPlan(track: track, firstFrame: firstFrame)
        case "A_OPUS": return makeOpusPlan(track: track, firstFrame: firstFrame)
        case "A_MPEG/L3", "A_MPEG/L2": return makeMPEGAudioPlan(track: track, firstFrame: firstFrame)
        case "A_ALAC": return makeALACPlan(track: track, firstFrame: firstFrame)
        default: return .failure(RemuxUnsupported("Codec audio \(track.codecID) non pris en charge par AVPlayer"))
        }
    }

    // MARK: Helpers exposed for headless unit tests

    /// RFC 6381 / ISO 14496-15 Annex E codec string from an HEVCDecoderConfigurationRecord:
    /// `hvc1.<A|B|C?><profile_idc>.<32 compat flags bit-reversed, hex>.<L|H><level_idc>.<constraint bytes>`.
    static func hevcCodecString(hvcC: Data) -> String? {
        let b = [UInt8](hvcC)
        guard b.count >= 13, b[0] <= 1 else { return nil }
        return hevcCodecString(profileTierLevel: Array(b[1...12]), sampleEntry: "hvc1")
    }

    /// `avc1.PPCCLL` (profile_idc, constraint flags, level_idc of the avcC, uppercase hex).
    static func avcCodecString(avcC: Data) -> String? {
        let b = [UInt8](avcC)
        guard b.count >= 4, b[0] == 1 else { return nil }
        return String(format: "avc1.%02X%02X%02X", b[1], b[2], b[3])
    }

    /// `av01.P.LLT.DD` (+ `.M.CCC.cp.tc.mc.F` when `color` has primaries,
    /// transfer and matrix) from an AV1CodecConfigurationRecord.
    static func av1CodecString(av1C: Data, color: RemuxColorInfo?) -> String? {
        let b = [UInt8](av1C)
        guard b.count >= 4, b[0] == 0x81 else { return nil }
        let profile = Int(b[1] >> 5)
        let level = Int(b[1] & 0x1F)
        let tier = (b[2] >> 7) & 1
        let highBitDepth = (b[2] >> 6) & 1 == 1
        let twelveBit = (b[2] >> 5) & 1 == 1
        let monochrome = Int((b[2] >> 4) & 1)
        let ssx = Int((b[2] >> 3) & 1), ssy = Int((b[2] >> 2) & 1)
        let csp = Int(b[2] & 3)
        let bitDepth = (profile == 2 && highBitDepth) ? (twelveBit ? 12 : 10) : (highBitDepth ? 10 : 8)
        var s = String(format: "av01.%d.%02d%@.%02d", profile, level, tier == 1 ? "H" : "M", bitDepth)
        if let c = color, let cp = c.primaries, let tc = c.transfer, let mc = c.matrix {
            let chroma = "\(ssx)\(ssy)\(ssx == 1 && ssy == 1 ? csp : 0)"
            s += String(format: ".%d.%@.%02d.%02d.%02d.%d", monochrome, chroma, cp, tc, mc, (c.fullRange ?? false) ? 1 : 0)
        }
        return s
    }

    /// Colour description + bit depth from the first SPS of an hvcC (VUI).
    static func hevcColorInfo(hvcC: Data) -> RemuxColorInfo? {
        guard let record = HvcCRecord(bytes: [UInt8](hvcC)),
              let spsNAL = record.nalUnits(ofType: 33).first,
              let sps = parseHEVCSPS(spsNAL) else { return nil }
        var color = sps.video.color
        color.bitDepth = sps.bitDepthLuma
        return color
    }

    /// Colour description + bit depth from the first SPS of an avcC (VUI).
    static func avcColorInfo(avcC: Data) -> RemuxColorInfo? {
        guard let record = AvcCRecord(bytes: [UInt8](avcC)),
              let spsNAL = record.sps.first,
              let sps = parseAVCSPS(spsNAL) else { return nil }
        var color = sps.video.color
        color.bitDepth = sps.bitDepthLuma
        return color
    }

    /// Parses every (E-)AC-3 syncframe of one Matroska block (full Annex E bsi()).
    static func eac3Info(_ frame: Data) -> EAC3Info? {
        let bytes = [UInt8](frame)
        var syncframes: [DolbySyncframe] = []
        var pos = 0
        while pos + 6 <= bytes.count, let sf = parseDolbySyncframe(bytes, at: pos) {
            syncframes.append(sf)
            pos += sf.frameBytes
        }
        guard let first = syncframes.first, first.isIndependent else { return nil }

        // First frame set: everything up to the next independent substream 0.
        var setEnd = syncframes.count
        for i in 1..<max(1, syncframes.count) where syncframes[i].isIndependent && syncframes[i].substreamID == 0 {
            setEnd = i
            break
        }
        let frameSet = Array(syncframes[0..<setEnd])

        // Main program = independent substream 0 + the dependent substreams that follow it.
        var mask = dolbyChannelMask(acmod: first.acmod, lfeon: first.lfeon)
        for sf in frameSet.dropFirst() {
            guard !sf.isIndependent else { break }
            mask |= sf.chanmap ?? dolbyChannelMask(acmod: sf.acmod, lfeon: sf.lfeon)
        }

        let samples = syncframes.filter { $0.isIndependent && $0.substreamID == 0 }.reduce(0) { $0 + 256 * $1.blocks }
        let totalBytes = syncframes.reduce(0) { $0 + $1.frameBytes }
        let dataRate = samples > 0 ? Int((Double(totalBytes) * 8 * Double(first.sampleRate) / Double(samples) / 1000).rounded()) : 0
        let joc = syncframes.first { $0.hasJOC }

        return EAC3Info(
            sampleRate: first.sampleRate,
            blocksPerSyncframe: first.blocks,
            samplesPerFrame: samples,
            substreams: frameSet.map {
                EAC3Info.Substream(independent: $0.isIndependent, substreamID: $0.substreamID, fscod: $0.fscod,
                                   bsid: $0.bsid, bsmod: $0.bsmod, acmod: $0.acmod, lfeon: $0.lfeon,
                                   frameBytes: $0.frameBytes, chanmap: $0.chanmap)
            },
            channelCount: dolbyChannelCount(mask),
            dataRateKbps: dataRate,
            hasJOC: joc != nil,
            jocComplexityIndex: joc?.jocComplexity,
            bsiComplete: syncframes.allSatisfy { $0.bsiComplete },
            channelMask: mask)
    }

    /// AC-3 syncframe header (bsid ≤ 10), incl. cmixlev / surmixlev / dsurmod / lfeon.
    static func ac3Info(_ frame: Data) -> AC3Info? {
        return parseAC3Header([UInt8](frame), at: 0)
    }

    /// EC3SpecificBox payload (ETSI TS 102 366 F.6), + the ETSI TS 103 420
    /// JOC extension (`flag_ec3_extension_type_a`, `complexity_index_type_a`)
    /// when `signalAtmos`.
    static func dec3Payload(_ info: EAC3Info, signalAtmos: Bool) -> Data {
        var w = BitWriter()
        w.write(UInt32(min(max(info.dataRateKbps, 0), 0x1FFF)), 13)
        let independentIndexes = info.substreams.indices.filter { info.substreams[$0].independent }
        w.write(UInt32(min(max(independentIndexes.count - 1, 0), 7)), 3)
        for (n, index) in independentIndexes.prefix(8).enumerated() {
            let ind = info.substreams[index]
            let next = n + 1 < independentIndexes.count ? independentIndexes[n + 1] : info.substreams.count
            let dependents = info.substreams[(index + 1)..<next].filter { !$0.independent }
            w.write(UInt32(ind.fscod & 3), 2)
            w.write(UInt32(ind.bsid & 0x1F), 5)
            w.write(0, 1)                                // reserved
            w.write(0, 1)                                // asvc
            w.write(UInt32(ind.bsmod & 7), 3)
            w.write(UInt32(ind.acmod & 7), 3)
            w.write(UInt32(ind.lfeon & 1), 1)
            w.write(0, 3)                                // reserved
            w.write(UInt32(min(dependents.count, 15)), 4)
            if dependents.isEmpty {
                w.write(0, 1)                            // reserved
            } else {
                var loc = 0
                for dep in dependents {
                    loc |= dec3ChanLoc(fromChanmap: dep.chanmap ?? dolbyChannelMask(acmod: dep.acmod, lfeon: dep.lfeon))
                }
                w.write(UInt32(loc), 9)
            }
        }
        if signalAtmos {
            w.write(0, 7)                                // reserved
            w.write(1, 1)                                // flag_ec3_extension_type_a
            w.write(UInt32(min(max(info.jocComplexityIndex ?? 16, 0), 255)), 8)
        }
        return Data(w.finish())
    }

    /// AC3SpecificBox payload (ETSI TS 102 366 F.4): fscod bsid bsmod acmod
    /// lfeon bit_rate_code + 5 reserved bits.
    static func dac3Payload(_ info: AC3Info) -> Data {
        var w = BitWriter()
        w.write(UInt32(info.fscod & 3), 2)
        w.write(UInt32(info.bsid & 0x1F), 5)
        w.write(UInt32(info.bsmod & 7), 3)
        w.write(UInt32(info.acmod & 7), 3)
        w.write(UInt32(info.lfeon & 1), 1)
        w.write(UInt32((info.frmsizecod >> 1) & 0x1F), 5)
        w.write(0, 5)
        return Data(w.finish())
    }

    /// AudioSpecificConfig for an AAC track: CodecPrivate when present
    /// (`A_AAC`), else synthesized from the legacy CodecID + track fields
    /// (AOT 2, sampling index or explicit 24-bit rate, channelConfiguration,
    /// GASpecificConfig zeros; `…/SBR` and implicit HE-AAC tracks get the
    /// explicit backward-compatible SBR signalling Apple's encoder writes:
    /// sync extension 0x2B7, AOT 5, sbrPresentFlag, extension sampling index).
    static func aacAudioSpecificConfig(track: MKVTrack) -> Data? {
        let id = track.codecID.uppercased()
        if id == "A_AAC", !track.codecPrivate.isEmpty { return track.codecPrivate }
        let profileAOT: Int
        if id.hasSuffix("/MAIN") { profileAOT = 1 }
        else if id.hasSuffix("/SSR") { profileAOT = 3 }
        else if id.hasSuffix("/LTP") { profileAOT = 4 }
        else { profileAOT = 2 }

        let rate = safeInt(track.samplingFrequency)
        let outRate = safeInt(track.outputSamplingFrequency ?? track.samplingFrequency)
        guard rate > 0, rate <= 0xFFFFFF else { return nil }
        var sbr = id.hasSuffix("/SBR") || (outRate == 2 * rate)
        var coreRate = rate
        var extRate = outRate
        if sbr {
            if outRate == 2 * rate {
                coreRate = rate; extRate = outRate
            } else if rate > 24000 {
                // SamplingFrequency already carries the output rate.
                coreRate = rate / 2; extRate = rate
            } else {
                coreRate = rate; extRate = rate * 2
            }
        }
        if profileAOT != 2 { sbr = false }

        let channelConfig: Int
        switch track.channels {
        case 1...6: channelConfig = track.channels
        case 8: channelConfig = 7
        default: channelConfig = 0
        }

        var w = BitWriter()
        w.write(UInt32(profileAOT), 5)
        writeSamplingFrequency(&w, coreRate)
        w.write(UInt32(channelConfig), 4)
        w.write(0, 3)                                // frameLengthFlag, dependsOnCoreCoder, extensionFlag
        if sbr {
            w.write(0x2B7, 11)                       // syncExtensionType
            w.write(5, 5)                            // extensionAudioObjectType = SBR
            w.write(1, 1)                            // sbrPresentFlag
            writeSamplingFrequency(&w, extRate)
        }
        return Data(w.finish())
    }

    /// Block size (samples) from a FLAC frame header (sync 0xFFF8/0xFFF9),
    /// incl. the 8/16-bit block sizes stored after the UTF-8 coded number.
    static func flacBlockSize(_ frame: Data) -> Int? {
        guard frame.count >= 6 else { return nil }
        let s = frame.startIndex
        let b0 = frame[s], b1 = frame[s + 1], b2 = frame[s + 2]
        guard b0 == 0xFF, b1 & 0xFE == 0xF8 else { return nil }
        let code = Int(b2 >> 4)
        var pos = 4
        let lead = frame[s + pos]
        let utf8Length: Int
        if lead & 0x80 == 0 { utf8Length = 1 }
        else if lead & 0xE0 == 0xC0 { utf8Length = 2 }
        else if lead & 0xF0 == 0xE0 { utf8Length = 3 }
        else if lead & 0xF8 == 0xF0 { utf8Length = 4 }
        else if lead & 0xFC == 0xF8 { utf8Length = 5 }
        else if lead & 0xFE == 0xFC { utf8Length = 6 }
        else if lead == 0xFE { utf8Length = 7 }
        else { return nil }
        pos += utf8Length
        switch code {
        case 1: return 192
        case 2...5: return 576 << (code - 2)
        case 6:
            guard pos < frame.count else { return nil }
            return Int(frame[s + pos]) + 1
        case 7:
            guard pos + 1 < frame.count else { return nil }
            return (Int(frame[s + pos]) << 8 | Int(frame[s + pos + 1])) + 1
        case 8...15: return 256 << (code - 8)
        default: return nil
        }
    }

    /// PCM samples at 48 kHz of one Opus packet (RFC 6716 §3.1 TOC: frame
    /// size from the config, × frame count code 0/1/2/3).
    static func opusPacketSamples48k(_ packet: Data) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        let frameSamples: Int
        switch config {
        case 0...11: frameSamples = [480, 960, 1920, 2880][config & 3]       // SILK 10/20/40/60 ms
        case 12...15: frameSamples = [480, 960][config & 1]                  // Hybrid 10/20 ms
        default: frameSamples = [120, 240, 480, 960][config & 3]             // CELT 2.5/5/10/20 ms
        }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count >= 2 else { return nil }
            frames = Int(packet[packet.startIndex + 1] & 0x3F)
            guard frames > 0 else { return nil }
        }
        let total = frameSamples * frames
        return total <= 5760 ? total : nil   // a packet never exceeds 120 ms
    }

    /// PCM samples of an MPEG-1/2/2.5 audio block (Layer I 384, Layer II
    /// 1152, Layer III 1152 / 576 LSF), summed over every complete frame the
    /// block holds.
    static func mpegAudioFrameSamples(_ frame: Data) -> Int? {
        let bytes = [UInt8](frame)
        var pos = 0
        var total = 0
        while pos + 4 <= bytes.count, let header = MPEGAudioHeader(bytes, at: pos) {
            total += header.samplesPerFrame
            guard let length = header.frameBytes, length > 0 else { break }
            pos += length
        }
        return total > 0 ? total : nil
    }
}

// MARK: - Bit writer

extension RemuxCodecs {

    /// MSB-first bit writer (dec3, dac3, AudioSpecificConfig).
    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var accumulator: UInt32 = 0
        private var bitCount = 0

        mutating func write(_ value: UInt32, _ count: Int) {
            guard count > 0 else { return }
            for shift in stride(from: count - 1, through: 0, by: -1) {
                accumulator = (accumulator << 1) | ((value >> UInt32(shift)) & 1)
                bitCount += 1
                if bitCount == 8 {
                    bytes.append(UInt8(accumulator & 0xFF))
                    accumulator = 0
                    bitCount = 0
                }
            }
        }

        /// Pads with zero bits to the next byte boundary and returns the bytes.
        mutating func finish() -> [UInt8] {
            if bitCount > 0 {
                bytes.append(UInt8((accumulator << UInt32(8 - bitCount)) & 0xFF))
                accumulator = 0
                bitCount = 0
            }
            return bytes
        }
    }
}

// MARK: - Shared byte / box helpers

extension RemuxCodecs {

    fileprivate static func be16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    fileprivate static func be24(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 16 | Int(b[i + 1]) << 8 | Int(b[i + 2]) }
    fileprivate static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    fileprivate static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    fileprivate static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    /// Double → Int that never traps (NaN / ±∞ / out of range from a corrupt
    /// Matroska float element → 0 or the clamped bound).
    fileprivate static func safeInt(_ value: Double?) -> Int {
        guard let v = value, v.isFinite else { return 0 }
        if v >= 9.0e18 { return Int.max }
        if v <= -9.0e18 { return Int.min }
        return Int(v.rounded())
    }

    fileprivate static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    /// ISO/IEC 14496-12 VisualSampleEntry + child boxes.
    fileprivate static func visualSampleEntry(_ type: String, width: Int, height: Int, children: [Data]) -> Data {
        return box(type) { w in
            w.zeros(6); w.u16(1)                         // reserved, data_reference_index
            w.zeros(16)                                  // pre_defined, reserved, pre_defined[3]
            w.u16(UInt16(clamping: width)); w.u16(UInt16(clamping: height))
            w.u32(0x00480000); w.u32(0x00480000)         // 72 dpi
            w.u32(0)                                     // reserved
            w.u16(1)                                     // frame_count
            w.zeros(32)                                  // compressorname
            w.u16(0x0018)                                // depth
            w.i16(-1)                                    // pre_defined
            for child in children { w.bytes(child) }
        }
    }

    /// ISO/IEC 14496-12 AudioSampleEntry (version 0) + child boxes.
    fileprivate static func audioSampleEntry(_ type: String, channels: Int, sampleSize: Int, sampleRate: Int, children: [Data]) -> Data {
        return box(type) { w in
            w.zeros(6); w.u16(1)                         // reserved, data_reference_index
            w.zeros(8)                                   // reserved (version, revision, vendor)
            w.u16(UInt16(clamping: channels))
            w.u16(UInt16(clamping: sampleSize))
            w.u16(0); w.u16(0)                           // pre_defined, reserved
            w.u32(sampleRate > 0 && sampleRate <= 65535 ? UInt32(sampleRate) << 16 : 0)
            for child in children { w.bytes(child) }
        }
    }

    /// `colr` nclx: primaries, transfer, matrix (u16 each), full_range_flag(1) + reserved(7).
    fileprivate static func colrBox(_ c: RemuxColorInfo) -> Data {
        return box("colr") { w in
            w.fourCC("nclx")
            w.u16(UInt16(clamping: c.primaries ?? 2))
            w.u16(UInt16(clamping: c.transfer ?? 2))
            w.u16(UInt16(clamping: c.matrix ?? 2))
            w.u8((c.fullRange ?? false) ? 0x80 : 0x00)
        }
    }

    fileprivate static func paspBox(h: Int, v: Int) -> Data {
        return box("pasp") { w in w.u32(UInt32(clamping: h)); w.u32(UInt32(clamping: v)) }
    }

    /// Normalizes a Matroska chromaticity (CIE 1931 x/y, 0…1). Some muxers
    /// store the SEI integer (0.00002 units) instead — accept those too.
    fileprivate static func normalizedChromaticity(_ value: Double?) -> Double? {
        guard let v = value, v.isFinite, v >= 0 else { return nil }
        if v <= 1.0 { return v }
        if v <= 50000 { return v / 50000 }
        return nil
    }

    /// `mdcv` (SMPTE ST 2086) from Matroska MasteringMetadata: display
    /// primaries in G, B, R order (0.00002 units), white point, max / min
    /// luminance (0.0001 cd/m²) — same 24-byte layout as the HEVC SEI.
    fileprivate static func mdcvPayload(_ m: MKVMasteringMetadata) -> [UInt8]? {
        guard let rx = normalizedChromaticity(m.primaryRX), let ry = normalizedChromaticity(m.primaryRY),
              let gx = normalizedChromaticity(m.primaryGX), let gy = normalizedChromaticity(m.primaryGY),
              let bx = normalizedChromaticity(m.primaryBX), let by = normalizedChromaticity(m.primaryBY),
              let wx = normalizedChromaticity(m.whitePointX), let wy = normalizedChromaticity(m.whitePointY),
              var maxL = m.luminanceMax, maxL.isFinite, maxL > 0 else { return nil }
        var minL = m.luminanceMin ?? 0
        if !minL.isFinite || minL < 0 { minL = 0 }
        if maxL > 10000 { maxL /= 10000; minL /= 10000 }     // stored in 0.0001 cd/m² units
        func chroma(_ v: Double) -> UInt16 { UInt16(clamping: safeInt(v * 50000)) }
        func lum(_ v: Double) -> UInt32 { UInt32(clamping: safeInt(v * 10000)) }
        var w = BoxWriter()
        for v in [gx, gy, bx, by, rx, ry, wx, wy] { w.u16(chroma(v)) }
        w.u32(lum(maxL)); w.u32(lum(minL))
        return [UInt8](w.data)
    }

    /// `mdcv` / `clli` boxes: Matroska Colour first, then the stream's own
    /// SEI (HEVC/AVC mastering display colour volume 137, content light level 144).
    fileprivate static func hdrMetadataBoxes(colour: MKVColour?, seiMDCV: [UInt8]?, seiCLLI: [UInt8]?) -> [Data] {
        var boxes: [Data] = []
        if let payload = colour?.mastering.flatMap(mdcvPayload) ?? seiMDCV, payload.count == 24 {
            boxes.append(box("mdcv") { $0.bytes(payload) })
        }
        if let colour = colour, colour.maxCLL != nil || colour.maxFALL != nil {
            boxes.append(box("clli") { w in
                w.u16(UInt16(clamping: colour.maxCLL ?? 0))
                w.u16(UInt16(clamping: colour.maxFALL ?? 0))
            })
        } else if let payload = seiCLLI, payload.count == 4 {
            boxes.append(box("clli") { $0.bytes(payload) })
        }
        return boxes
    }
}

// MARK: - NAL unit helpers (AVC / HEVC)

extension RemuxCodecs {

    /// True when the buffer starts with an Annex B start code.
    fileprivate static func startsWithStartCode(_ b: [UInt8]) -> Bool {
        if b.count >= 4, b[0] == 0, b[1] == 0, b[2] == 0, b[3] == 1 { return true }
        if b.count >= 3, b[0] == 0, b[1] == 0, b[2] == 1 { return true }
        return false
    }

    /// NAL units of an Annex B byte stream (start codes and trailing zero bytes removed).
    fileprivate static func annexBNALUnits(_ b: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var start = -1
        var i = 0
        let n = b.count
        while i + 2 < n {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start, b[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(Array(b[start..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n {
            var end = n
            while end > start, b[end - 1] == 0 { end -= 1 }
            if end > start { units.append(Array(b[start..<end])) }
        }
        return units
    }

    /// NAL units of a length-prefixed access unit; nil when the lengths don't
    /// tile the buffer exactly (corrupt, or not length-prefixed at all).
    fileprivate static func lengthPrefixedNALUnits(_ b: [UInt8], lengthSize: Int) -> [[UInt8]]? {
        guard (1...4).contains(lengthSize) else { return nil }
        var units: [[UInt8]] = []
        var pos = 0
        while pos < b.count {
            guard pos + lengthSize <= b.count else { return nil }
            var length = 0
            for k in 0..<lengthSize { length = length << 8 | Int(b[pos + k]) }
            pos += lengthSize
            guard length <= b.count - pos else { return nil }
            if length > 0 { units.append(Array(b[pos..<(pos + length)])) }
            pos += length
        }
        return units
    }

    /// NAL units of a sample in either layout.
    fileprivate static func nalUnits(of frame: Data, lengthSize: Int, annexB: Bool) -> [[UInt8]] {
        let b = [UInt8](frame)
        if annexB { return annexBNALUnits(b) }
        return lengthPrefixedNALUnits(b, lengthSize: lengthSize) ?? []
    }

    /// Annex B access unit → 4-byte length-prefixed NAL units.
    fileprivate static func annexBToLengthPrefixed(_ frame: Data) -> Data {
        let units = annexBNALUnits([UInt8](frame))
        guard !units.isEmpty else { return frame }
        var out = Data(capacity: frame.count + 4 * units.count)
        for unit in units {
            let n = UInt32(unit.count)
            out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            out.append(contentsOf: unit)
        }
        return out
    }

    /// Drops the HEVC NAL units whose `nal_unit_type` is in `types` from a
    /// length-prefixed sample, rewriting the NAL list. Returns the input
    /// untouched when nothing matches or the layout doesn't parse.
    static func strippingHEVCNALUnits(_ frame: Data, lengthSize: Int, types: Set<UInt8>) -> Data {
        guard (1...4).contains(lengthSize) else { return frame }
        return frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            let n = raw.count
            var keep: [Range<Int>] = []
            var dropped = false
            var pos = 0
            while pos < n {
                guard pos + lengthSize <= n else { return frame }
                var length = 0
                for k in 0..<lengthSize { length = length << 8 | Int(raw[pos + k]) }
                let start = pos + lengthSize
                guard length <= n - start else { return frame }
                if length > 0, types.contains((raw[start] >> 1) & 0x3F) {
                    dropped = true
                } else {
                    keep.append(pos..<(start + length))
                }
                pos = start + length
            }
            guard dropped else { return frame }
            var out = Data(capacity: n)
            for range in keep {
                out.append(raw.baseAddress!.advanced(by: range.lowerBound).assumingMemoryBound(to: UInt8.self), count: range.count)
            }
            return out
        }
    }

    /// RBSP of a NAL unit: drops emulation_prevention_three_byte (0x000003 → 0x0000).
    fileprivate static func unescapeRBSP(_ nal: [UInt8], from start: Int, limit: Int = Int.max) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(nal.count, limit))
        var zeros = 0
        var i = start
        while i < nal.count, out.count < limit {
            let byte = nal[i]
            i += 1
            if zeros >= 2, byte == 0x03 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// Mastering display (SEI 137) and content light level (SEI 144)
    /// payloads from SEI NAL units — byte-identical to `mdcv` / `clli`.
    fileprivate static func hdrSEIPayloads(_ nals: [[UInt8]], hevc: Bool) -> (mdcv: [UInt8]?, clli: [UInt8]?) {
        var mdcv: [UInt8]?
        var clli: [UInt8]?
        for nal in nals {
            guard let first = nal.first else { continue }
            let isSEI = hevc ? ((first >> 1) & 0x3F == 39 && nal.count > 2) : (first & 0x1F == 6)
            guard isSEI else { continue }
            let rbsp = unescapeRBSP(nal, from: hevc ? 2 : 1)
            var pos = 0
            while pos < rbsp.count {
                if pos == rbsp.count - 1 { break }                  // rbsp_trailing_bits
                var type = 0
                while pos < rbsp.count, rbsp[pos] == 0xFF { type += 255; pos += 1 }
                guard pos < rbsp.count else { break }
                type += Int(rbsp[pos]); pos += 1
                var size = 0
                while pos < rbsp.count, rbsp[pos] == 0xFF { size += 255; pos += 1 }
                guard pos < rbsp.count else { break }
                size += Int(rbsp[pos]); pos += 1
                guard pos + size <= rbsp.count else { break }
                if type == 137, size >= 24, mdcv == nil { mdcv = Array(rbsp[pos..<(pos + 24)]) }
                if type == 144, size >= 4, clli == nil { clli = Array(rbsp[pos..<(pos + 4)]) }
                pos += size
            }
        }
        return (mdcv, clli)
    }

    /// Table E-1 sample aspect ratios (aspect_ratio_idc 1…16), shared by H.264 and HEVC.
    fileprivate static let vuiSampleAspectRatios: [Int: (Int, Int)] = [
        1: (1, 1), 2: (12, 11), 3: (10, 11), 4: (16, 11), 5: (40, 33), 6: (24, 11), 7: (20, 11), 8: (32, 11),
        9: (80, 33), 10: (18, 11), 11: (15, 11), 12: (64, 33), 13: (160, 99), 14: (4, 3), 15: (3, 2), 16: (2, 1),
    ]

    /// Facts read from a sequence header (SPS VUI / AV1 sequence header).
    struct StreamVideoInfo {
        var width = 0
        var height = 0
        /// VUI sample aspect ratio (nil when absent / unspecified).
        var sampleAspectRatio: (Int, Int)?
        /// VUI colour description (nil fields when absent; `fullRange` set
        /// when video_signal_type is present).
        var color = RemuxColorInfo()
        /// Frame rate from VUI timing info, when present.
        var timingFrameRate: Double?
    }

    /// Reads the VUI fields shared by H.264 and HEVC up to and including
    /// the colour description. Returns false on overrun.
    fileprivate static func readVUIAspectAndColour(_ r: inout BitReader, into info: inout StreamVideoInfo) -> Bool {
        var sar: (Int, Int)?
        var color = RemuxColorInfo()
        if r.readBool() {                                       // aspect_ratio_info_present_flag
            let idc = Int(r.read(8))
            if idc == 255 {
                let w = Int(r.read(16)), h = Int(r.read(16))
                if w > 0, h > 0 { sar = (w, h) }
            } else {
                sar = vuiSampleAspectRatios[idc]
            }
        }
        if r.readBool() { r.skip(1) }                           // overscan_info_present / appropriate
        if r.readBool() {                                       // video_signal_type_present_flag
            r.skip(3)                                           // video_format
            color.fullRange = r.readBool()
            if r.readBool() {                                   // colour_description_present_flag
                color.primaries = Int(r.read(8))
                color.transfer = Int(r.read(8))
                color.matrix = Int(r.read(8))
            }
        }
        guard !r.overrun else { return false }
        info.sampleAspectRatio = sar
        info.color = color
        return true
    }
}

// MARK: - AVC (H.264)

extension RemuxCodecs {

    struct AVCSPSInfo {
        var profileIDC = 0
        var constraintFlags = 0
        var levelIDC = 0
        var chromaFormatIDC = 1
        var bitDepthLuma = 8
        var bitDepthChroma = 8
        var video = StreamVideoInfo()
    }

    /// AVCDecoderConfigurationRecord (ISO/IEC 14496-15 §5.3.3.1).
    struct AvcCRecord {
        var version: UInt8 = 1
        var profile: UInt8 = 0
        var compatibility: UInt8 = 0
        var level: UInt8 = 0
        var lengthSize = 4
        var sps: [[UInt8]] = []
        var pps: [[UInt8]] = []
        /// Bytes after the PPS list (high-profile chroma / bit depth + SPS ext).
        var trailing: [UInt8] = []

        init() {}

        init?(bytes b: [UInt8]) {
            guard b.count >= 7 else { return nil }
            version = b[0]
            profile = b[1]; compatibility = b[2]; level = b[3]
            lengthSize = Int(b[4] & 3) + 1
            var pos = 6
            for _ in 0..<Int(b[5] & 0x1F) {
                guard pos + 2 <= b.count else { return nil }
                let n = RemuxCodecs.be16(b, pos); pos += 2
                guard pos + n <= b.count else { return nil }
                if n > 0 { sps.append(Array(b[pos..<(pos + n)])) }
                pos += n
            }
            guard pos < b.count else {
                // Truncated after the SPS list: tolerate a missing PPS count.
                return
            }
            let ppsCount = Int(b[pos]); pos += 1
            for _ in 0..<ppsCount {
                guard pos + 2 <= b.count else { return nil }
                let n = RemuxCodecs.be16(b, pos); pos += 2
                guard pos + n <= b.count else { return nil }
                if n > 0 { pps.append(Array(b[pos..<(pos + n)])) }
                pos += n
            }
            trailing = Array(b[pos...])
        }

        func serialized() -> [UInt8] {
            var out: [UInt8] = [1, profile, compatibility, level, 0xFC | UInt8(lengthSize - 1), 0xE0 | UInt8(min(sps.count, 31))]
            for unit in sps.prefix(31) { out += [UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)] + unit }
            out.append(UInt8(min(pps.count, 255)))
            for unit in pps.prefix(255) { out += [UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)] + unit }
            out += trailing
            return out
        }
    }

    /// H.264 seq_parameter_set_data() through the VUI colour description / timing.
    static func parseAVCSPS(_ nal: [UInt8]) -> AVCSPSInfo? {
        guard nal.count >= 4, nal[0] & 0x1F == 7 else { return nil }
        let rbsp = unescapeRBSP(nal, from: 1, limit: 4096)
        var r = BitReader(rbsp)
        var info = AVCSPSInfo()
        info.profileIDC = Int(r.read(8))
        info.constraintFlags = Int(r.read(8))
        info.levelIDC = Int(r.read(8))
        guard r.readUE() <= 31 else { return nil }              // seq_parameter_set_id
        var separateColourPlane = false
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(info.profileIDC) {
            info.chromaFormatIDC = Int(r.readUE())
            guard info.chromaFormatIDC <= 3 else { return nil }
            if info.chromaFormatIDC == 3 { separateColourPlane = r.readBool() }
            info.bitDepthLuma = Int(r.readUE()) + 8
            info.bitDepthChroma = Int(r.readUE()) + 8
            guard info.bitDepthLuma <= 14, info.bitDepthChroma <= 14 else { return nil }
            r.skip(1)                                           // qpprime_y_zero_transform_bypass_flag
            if r.readBool() {                                   // seq_scaling_matrix_present_flag
                for i in 0..<(info.chromaFormatIDC != 3 ? 8 : 12) where r.readBool() {
                    skipAVCScalingList(&r, size: i < 6 ? 16 : 64)
                }
            }
        }
        guard r.readUE() <= 12 else { return nil }              // log2_max_frame_num_minus4
        let pocType = r.readUE()
        if pocType == 0 {
            guard r.readUE() <= 12 else { return nil }          // log2_max_pic_order_cnt_lsb_minus4
        } else if pocType == 1 {
            r.skip(1)                                           // delta_pic_order_always_zero_flag
            _ = r.readSE(); _ = r.readSE()                      // offset_for_non_ref_pic, top_to_bottom
            let cycle = r.readUE()
            guard cycle <= 255 else { return nil }
            for _ in 0..<cycle { _ = r.readSE() }
        } else if pocType != 2 {
            return nil
        }
        _ = r.readUE()                                          // max_num_ref_frames
        r.skip(1)                                               // gaps_in_frame_num_value_allowed_flag
        let widthMbs = Int(r.readUE()) + 1
        let heightMapUnits = Int(r.readUE()) + 1
        let frameMbsOnly = r.readBool()
        if !frameMbsOnly { r.skip(1) }                          // mb_adaptive_frame_field_flag
        r.skip(1)                                               // direct_8x8_inference_flag
        var crop = (left: 0, right: 0, top: 0, bottom: 0)
        if r.readBool() {
            crop = (Int(r.readUE()), Int(r.readUE()), Int(r.readUE()), Int(r.readUE()))
        }
        guard !r.overrun, widthMbs <= 1024, heightMapUnits <= 1024 else { return nil }
        let chromaArrayType = separateColourPlane ? 0 : info.chromaFormatIDC
        let subWidthC = (chromaArrayType == 1 || chromaArrayType == 2) ? 2 : 1
        let subHeightC = chromaArrayType == 1 ? 2 : 1
        let cropUnitX = chromaArrayType == 0 ? 1 : subWidthC
        let cropUnitY = (chromaArrayType == 0 ? 1 : subHeightC) * (frameMbsOnly ? 1 : 2)
        info.video.width = widthMbs * 16 - cropUnitX * (crop.left + crop.right)
        info.video.height = (frameMbsOnly ? 1 : 2) * heightMapUnits * 16 - cropUnitY * (crop.top + crop.bottom)
        guard info.video.width > 0, info.video.height > 0 else { return nil }

        if r.readBool() {                                       // vui_parameters_present_flag
            var vui = info.video
            if readVUIAspectAndColour(&r, into: &vui) {
                info.video = vui
                if r.readBool() { _ = r.readUE(); _ = r.readUE() }   // chroma_loc_info
                if r.readBool() {                                    // timing_info_present_flag
                    let units = r.read(32), scale = r.read(32)
                    if !r.overrun, units > 0, scale > 0 {
                        let fps = Double(scale) / (2 * Double(units))
                        if fps >= 1, fps <= 300 { info.video.timingFrameRate = fps }
                    }
                }
            }
        }
        return info
    }

    fileprivate static func skipAVCScalingList(_ r: inout BitReader, size: Int) {
        var last = 8, next = 8
        for _ in 0..<size {
            if next != 0 {
                let delta = Int(r.readSE())
                next = ((last + delta) % 256 + 256) % 256
            }
            if next != 0 { last = next }
            if r.overrun { return }
        }
    }

    fileprivate static func avcProfileName(_ profile: Int, constraints: Int) -> String {
        switch profile {
        case 66: return (constraints & 0x40) != 0 ? "Constrained Baseline" : "Baseline"
        case 77: return "Main"
        case 88: return "Extended"
        case 100: return "High"
        case 110: return "High 10"
        case 122: return "High 4:2:2"
        case 244: return "High 4:4:4"
        case 118, 128: return "Multiview High"
        default: return "profil \(profile)"
        }
    }

    fileprivate static func makeAVCPlan(track: MKVTrack, sampleFrames: [Data], releaseHintsHDR: Bool) -> Result<RemuxVideoPlan, RemuxUnsupported> {
        let codecPrivate = [UInt8](track.codecPrivate)
        var record = AvcCRecord()
        var rebuild = false
        var parsedRecord: AvcCRecord?
        if startsWithStartCode(codecPrivate) {
            // Annex B CodecPrivate (non-conforming muxers): rebuild an avcC.
            for unit in annexBNALUnits(codecPrivate) {
                switch unit[0] & 0x1F {
                case 7: record.sps.append(unit)
                case 8: record.pps.append(unit)
                default: break
                }
            }
            rebuild = true
        } else if let parsed = AvcCRecord(bytes: codecPrivate) {
            record = parsed
            if parsed.version == 1 { parsedRecord = parsed } else { rebuild = true }
        } else {
            rebuild = true
        }

        // Sample layout: length-prefixed with avcC's size, else Annex B.
        var annexBSamples = false
        if let first = sampleFrames.first(where: { !$0.isEmpty }) {
            let bytes = [UInt8](first)
            if lengthPrefixedNALUnits(bytes, lengthSize: record.lengthSize) == nil, startsWithStartCode(bytes) {
                annexBSamples = true
            }
        }
        if annexBSamples, record.lengthSize != 4 { record.lengthSize = 4; rebuild = true }

        // In-band parameter sets (avc3-style CodecPrivate): take them from the first frames.
        if record.sps.isEmpty || record.pps.isEmpty {
            rebuild = true
            for frame in sampleFrames {
                for unit in nalUnits(of: frame, lengthSize: record.lengthSize, annexB: annexBSamples) {
                    let type = unit[0] & 0x1F
                    if type == 7, record.sps.isEmpty { record.sps.append(unit) }
                    if type == 8, record.pps.isEmpty { record.pps.append(unit) }
                }
                if !record.sps.isEmpty, !record.pps.isEmpty { break }
            }
        }
        guard let spsNAL = record.sps.first, !record.pps.isEmpty else {
            return .failure(RemuxUnsupported("H.264 : paramètres SPS/PPS introuvables"))
        }
        guard let sps = parseAVCSPS(spsNAL) else {
            return .failure(RemuxUnsupported("H.264 : SPS illisible"))
        }
        // Apple's H.264 decoder is 8-bit 4:2:0 only (Hi10P / 4:2:2 / 4:4:4 → VLC).
        if sps.bitDepthLuma > 8 || sps.bitDepthChroma > 8 {
            return .failure(RemuxUnsupported("H.264 \(sps.bitDepthLuma) bits (Hi10P) non pris en charge par AVPlayer"))
        }
        if sps.chromaFormatIDC >= 2 {
            return .failure(RemuxUnsupported("H.264 \(sps.chromaFormatIDC == 2 ? "4:2:2" : "4:4:4") non pris en charge par AVPlayer"))
        }

        let avcC: [UInt8]
        if rebuild || parsedRecord == nil {
            record.profile = spsNAL[1]
            record.compatibility = spsNAL[2]
            record.level = spsNAL[3]
            if [100, 110, 122, 144].contains(sps.profileIDC) {
                record.trailing = [0xFC | UInt8(sps.chromaFormatIDC & 3), 0xF8 | UInt8((sps.bitDepthLuma - 8) & 7),
                                   0xF8 | UInt8((sps.bitDepthChroma - 8) & 7), 0]
            } else {
                record.trailing = []
            }
            avcC = record.serialized()
        } else {
            avcC = codecPrivate
        }
        guard let codecs = avcCodecString(avcC: Data(avcC)) else {
            return .failure(RemuxUnsupported("H.264 : configuration avcC invalide"))
        }

        let firstNALs = sampleFrames.first.map { nalUnits(of: $0, lengthSize: record.lengthSize, annexB: annexBSamples) } ?? []
        let sei = hdrSEIPayloads(firstNALs, hevc: false)
        var streamColor = sps.video.color
        streamColor.bitDepth = sps.bitDepthLuma
        let color = resolveColor(track: track, stream: streamColor, dolbyVisionCompatibility: nil, releaseHintsHDR: releaseHintsHDR)
        let geometry = resolveGeometry(track: track, streamWidth: sps.video.width, streamHeight: sps.video.height,
                                       streamSAR: sps.video.sampleAspectRatio)

        var children: [Data] = [box("avcC") { $0.bytes(avcC) }]
        if hasColorDescription(color) { children.append(colrBox(color)) }
        if let pasp = geometry.pasp { children.append(paspBox(h: pasp.0, v: pasp.1)) }
        children += hdrMetadataBoxes(colour: track.colour, seiMDCV: sei.mdcv, seiCLLI: sei.clli)
        let entry = visualSampleEntry("avc1", width: geometry.codedWidth, height: geometry.codedHeight, children: children)

        let range = videoRange(transfer: color.transfer)
        let fps = frameRate(track: track, streamFrameRate: sps.video.timingFrameRate)
        let label = "H.264 " + avcProfileName(sps.profileIDC, constraints: sps.constraintFlags)
        let transform: ((Data) -> Data)? = annexBSamples ? { annexBToLengthPrefixed($0) } : nil
        return .success(RemuxVideoPlan(
            codec: .avc, sampleEntry: entry, codecsString: codecs, supplementalCodecs: nil, videoRange: range,
            displayWidth: geometry.displayWidth, displayHeight: geometry.displayHeight,
            codedWidth: geometry.codedWidth, codedHeight: geometry.codedHeight, frameRate: fps,
            summary: videoSummary(label, rangeLabel: rangeName(range), geometry: geometry, fps: fps, note: nil),
            transform: transform))
    }
}

// MARK: - HEVC (H.265) + Dolby Vision

extension RemuxCodecs {

    struct HEVCSPSInfo {
        /// general_profile_space … general_level_idc (12 bytes, = hvcC bytes 1…12).
        var profileTierLevel: [UInt8] = []
        var maxSubLayersMinus1 = 0
        var temporalIdNesting = false
        var chromaFormatIDC = 1
        var bitDepthLuma = 8
        var bitDepthChroma = 8
        var video = StreamVideoInfo()
        var profileIDC: Int { profileTierLevel.isEmpty ? 0 : Int(profileTierLevel[0] & 0x1F) }
    }

    /// HEVCDecoderConfigurationRecord (ISO/IEC 14496-15 §8.3.3.1).
    struct HvcCRecord {
        struct NALArray {
            var completeness: Bool
            var type: UInt8
            var units: [[UInt8]]
        }
        /// Bytes 0…21 (everything before numOfArrays).
        var header: [UInt8]
        var arrays: [NALArray]

        var lengthSize: Int { Int(header[21] & 3) + 1 }

        init(header: [UInt8], arrays: [NALArray]) {
            self.header = header
            self.arrays = arrays
        }

        init?(bytes b: [UInt8]) {
            guard b.count >= 23 else { return nil }
            header = Array(b[0..<22])
            arrays = []
            var pos = 23
            for _ in 0..<Int(b[22]) {
                guard pos + 3 <= b.count else { return nil }
                var array = NALArray(completeness: b[pos] & 0x80 != 0, type: b[pos] & 0x3F, units: [])
                let count = RemuxCodecs.be16(b, pos + 1)
                pos += 3
                for _ in 0..<count {
                    guard pos + 2 <= b.count else { return nil }
                    let n = RemuxCodecs.be16(b, pos); pos += 2
                    guard pos + n <= b.count else { return nil }
                    if n > 0 { array.units.append(Array(b[pos..<(pos + n)])) }
                    pos += n
                }
                arrays.append(array)
            }
        }

        func nalUnits(ofType type: UInt8) -> [[UInt8]] {
            arrays.filter { $0.type == type }.flatMap { $0.units }
        }

        func serialized() -> [UInt8] {
            var out = header
            out[0] = 1
            let nonEmpty = arrays.filter { !$0.units.isEmpty }
            out.append(UInt8(min(nonEmpty.count, 255)))
            for array in nonEmpty.prefix(255) {
                out.append((array.completeness ? 0x80 : 0) | (array.type & 0x3F))
                out += [UInt8(array.units.count >> 8), UInt8(array.units.count & 0xFF)]
                for unit in array.units { out += [UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)] + unit }
            }
            return out
        }
    }

    /// H.265 seq_parameter_set_rbsp() through the VUI: profile_tier_level
    /// with sub-layers, conformance window, sub-layer ordering, scaling lists,
    /// PCM, short-term RPS (incl. inter-RPS prediction), long-term refs, VUI.
    static func parseHEVCSPS(_ nal: [UInt8]) -> HEVCSPSInfo? {
        guard nal.count >= 15, (nal[0] >> 1) & 0x3F == 33 else { return nil }
        let rbsp = unescapeRBSP(nal, from: 2, limit: 8192)
        guard rbsp.count >= 13 else { return nil }
        var info = HEVCSPSInfo()
        info.profileTierLevel = Array(rbsp[1...12])
        var r = BitReader(rbsp)
        r.skip(4)                                               // sps_video_parameter_set_id
        let maxSubLayersMinus1 = Int(r.read(3))
        info.maxSubLayersMinus1 = maxSubLayersMinus1
        info.temporalIdNesting = r.readBool()
        guard maxSubLayersMinus1 <= 6 else { return nil }
        r.skip(96)                                              // general PTL (88) + general_level_idc (8)
        var subProfilePresent: [Bool] = [], subLevelPresent: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 {
            subProfilePresent.append(r.readBool())
            subLevelPresent.append(r.readBool())
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 { r.skip(2) }       // reserved_zero_2bits
        }
        for i in 0..<maxSubLayersMinus1 {
            if subProfilePresent[i] { r.skip(88) }
            if subLevelPresent[i] { r.skip(8) }
        }
        guard r.readUE() <= 15 else { return nil }              // sps_seq_parameter_set_id
        info.chromaFormatIDC = Int(r.readUE())
        guard info.chromaFormatIDC <= 3 else { return nil }
        var separateColourPlane = false
        if info.chromaFormatIDC == 3 { separateColourPlane = r.readBool() }
        let picWidth = Int(r.readUE()), picHeight = Int(r.readUE())
        guard picWidth > 0, picHeight > 0, picWidth <= 16888, picHeight <= 16888 else { return nil }
        var crop = (left: 0, right: 0, top: 0, bottom: 0)
        if r.readBool() {                                       // conformance_window_flag
            crop = (Int(r.readUE()), Int(r.readUE()), Int(r.readUE()), Int(r.readUE()))
        }
        let chromaArrayType = separateColourPlane ? 0 : info.chromaFormatIDC
        let subWidthC = (chromaArrayType == 1 || chromaArrayType == 2) ? 2 : 1
        let subHeightC = chromaArrayType == 1 ? 2 : 1
        info.video.width = picWidth - subWidthC * (crop.left + crop.right)
        info.video.height = picHeight - subHeightC * (crop.top + crop.bottom)
        guard info.video.width > 0, info.video.height > 0 else { return nil }
        info.bitDepthLuma = Int(r.readUE()) + 8
        info.bitDepthChroma = Int(r.readUE()) + 8
        guard info.bitDepthLuma <= 16, info.bitDepthChroma <= 16, !r.overrun else { return nil }

        // From here on a parse failure only loses the VUI (size / depth are known).
        let log2MaxPocLsb = Int(r.readUE()) + 4
        guard log2MaxPocLsb <= 16 else { return info }
        let orderingInfoPresent = r.readBool()
        for _ in (orderingInfoPresent ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
            _ = r.readUE(); _ = r.readUE(); _ = r.readUE()      // max_dec_pic_buffering, num_reorder, latency
        }
        for _ in 0..<6 { _ = r.readUE() }                       // CB / TB sizes, transform hierarchy depths
        if r.readBool() {                                       // scaling_list_enabled_flag
            if r.readBool() { skipHEVCScalingListData(&r) }     // sps_scaling_list_data_present_flag
        }
        r.skip(2)                                               // amp_enabled, sample_adaptive_offset_enabled
        if r.readBool() {                                       // pcm_enabled_flag
            r.skip(8)                                           // pcm bit depths
            _ = r.readUE(); _ = r.readUE()
            r.skip(1)                                           // pcm_loop_filter_disabled_flag
        }
        let numShortTermRefPicSets = Int(r.readUE())
        guard numShortTermRefPicSets <= 64, !r.overrun,
              skipHEVCShortTermRefPicSets(&r, count: numShortTermRefPicSets) else { return info }
        if r.readBool() {                                       // long_term_ref_pics_present_flag
            let count = Int(r.readUE())
            guard count <= 32 else { return info }
            for _ in 0..<count { r.skip(log2MaxPocLsb + 1) }    // lt_ref_pic_poc_lsb_sps + used_by_curr_pic_lt
        }
        r.skip(2)                                               // sps_temporal_mvp_enabled, strong_intra_smoothing
        guard !r.overrun else { return info }
        if r.readBool() {                                       // vui_parameters_present_flag
            var vui = info.video
            if readVUIAspectAndColour(&r, into: &vui) {
                info.video = vui
                if r.readBool() { _ = r.readUE(); _ = r.readUE() }   // chroma_loc_info
                r.skip(3)                                    // neutral_chroma, field_seq, frame_field_info
                if r.readBool() {                            // default_display_window_flag
                    _ = r.readUE(); _ = r.readUE(); _ = r.readUE(); _ = r.readUE()
                }
                if r.readBool() {                            // vui_timing_info_present_flag
                    let units = r.read(32), scale = r.read(32)
                    if !r.overrun, units > 0, scale > 0 {
                        let fps = Double(scale) / Double(units)
                        if fps >= 1, fps <= 300 { info.video.timingFrameRate = fps }
                    }
                }
            }
        }
        return info
    }

    /// scaling_list_data() (H.265 §7.3.4).
    fileprivate static func skipHEVCScalingListData(_ r: inout BitReader) {
        for sizeID in 0..<4 {
            var matrixID = 0
            while matrixID < 6 {
                if !r.readBool() {                              // scaling_list_pred_mode_flag
                    _ = r.readUE()                              // scaling_list_pred_matrix_id_delta
                } else {
                    let coefficients = min(64, 1 << (4 + (sizeID << 1)))
                    if sizeID > 1 { _ = r.readSE() }            // scaling_list_dc_coef_minus8
                    for _ in 0..<coefficients { _ = r.readSE() }
                }
                if r.overrun { return }
                matrixID += sizeID == 3 ? 3 : 1
            }
        }
    }

    /// st_ref_pic_set(i) for i in 0..<count (H.265 §7.3.7), tracking each
    /// set's DeltaPocS0/S1 exactly as equations 7-61 / 7-62 derive them, so
    /// inter-RPS-predicted sets read the right number of flags.
    fileprivate static func skipHEVCShortTermRefPicSets(_ r: inout BitReader, count: Int) -> Bool {
        var sets: [(s0: [Int], s1: [Int])] = []
        for index in 0..<count {
            let interPrediction = index != 0 && r.readBool()
            if interPrediction {
                // delta_idx_minus1 only exists in slice headers: RefRpsIdx = index − 1.
                let ref = sets[index - 1]
                let sign = r.readBool()
                let absDelta = Int(r.readUE()) + 1
                guard absDelta <= 32768 else { return false }
                let deltaRps = sign ? -absDelta : absDelta
                let refCount = ref.s0.count + ref.s1.count
                var useDelta: [Bool] = []
                for _ in 0...refCount {
                    let used = r.readBool()                     // used_by_curr_pic_flag
                    useDelta.append(used ? true : r.readBool()) // use_delta_flag (inferred 1)
                }
                var s0: [Int] = [], s1: [Int] = []
                for j in stride(from: ref.s1.count - 1, through: 0, by: -1) {
                    let dPoc = ref.s1[j] + deltaRps
                    if dPoc < 0, useDelta[ref.s0.count + j] { s0.append(dPoc) }
                }
                if deltaRps < 0, useDelta[refCount] { s0.append(deltaRps) }
                for j in 0..<ref.s0.count {
                    let dPoc = ref.s0[j] + deltaRps
                    if dPoc < 0, useDelta[j] { s0.append(dPoc) }
                }
                for j in stride(from: ref.s0.count - 1, through: 0, by: -1) {
                    let dPoc = ref.s0[j] + deltaRps
                    if dPoc > 0, useDelta[j] { s1.append(dPoc) }
                }
                if deltaRps > 0, useDelta[refCount] { s1.append(deltaRps) }
                for j in 0..<ref.s1.count {
                    let dPoc = ref.s1[j] + deltaRps
                    if dPoc > 0, useDelta[ref.s0.count + j] { s1.append(dPoc) }
                }
                guard s0.count <= 32, s1.count <= 32 else { return false }
                sets.append((s0, s1))
            } else {
                let negatives = Int(r.readUE()), positives = Int(r.readUE())
                guard negatives <= 16, positives <= 16 else { return false }
                var s0: [Int] = [], s1: [Int] = []
                var poc = 0
                for _ in 0..<negatives {
                    poc -= Int(r.readUE()) + 1                  // delta_poc_s0_minus1
                    r.skip(1)                                   // used_by_curr_pic_s0_flag
                    s0.append(poc)
                }
                poc = 0
                for _ in 0..<positives {
                    poc += Int(r.readUE()) + 1                  // delta_poc_s1_minus1
                    r.skip(1)                                   // used_by_curr_pic_s1_flag
                    s1.append(poc)
                }
                sets.append((s0, s1))
            }
            if r.overrun { return false }
        }
        return true
    }

    /// Codec string from the 12 profile_tier_level bytes (hvcC bytes 1…12).
    fileprivate static func hevcCodecString(profileTierLevel b: [UInt8], sampleEntry: String) -> String {
        let profileSpace = Int((b[0] >> 6) & 3)
        let tier = (b[0] >> 5) & 1
        let profileIDC = Int(b[0] & 0x1F)
        let compat = UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4])
        var reversed: UInt32 = 0
        for bit in 0..<32 where compat & (1 << UInt32(bit)) != 0 { reversed |= 1 << UInt32(31 - bit) }
        var constraints = Array(b[5..<11])
        while let last = constraints.last, last == 0 { constraints.removeLast() }
        var s = sampleEntry + "." + ["", "A", "B", "C"][profileSpace] + String(profileIDC)
        s += "." + String(reversed, radix: 16, uppercase: true)
        s += "." + (tier == 1 ? "H" : "L") + String(b[11])
        for byte in constraints { s += String(format: ".%02X", byte) }
        return s
    }

    fileprivate static func hevcProfileName(_ sps: HEVCSPSInfo) -> String {
        switch sps.profileIDC {
        case 1: return "Main"
        case 2: return "Main 10"
        case 3: return "Main Still Picture"
        case 4: return sps.bitDepthLuma > 8 ? "RExt \(sps.bitDepthLuma) bits" : "RExt"
        default: return "profil \(sps.profileIDC)"
        }
    }

    /// Dolby Vision DOVIDecoderConfigurationRecord (24 bytes).
    struct DolbyVisionConfig: Equatable {
        var versionMajor: Int
        var versionMinor: Int
        var profile: Int
        var level: Int
        var rpuPresent: Bool
        var elPresent: Bool
        var blPresent: Bool
        var compatibilityID: Int
        /// The record padded / truncated to 24 bytes.
        var record: [UInt8]

        init?(_ data: Data) {
            let b = [UInt8](data)
            guard b.count >= 5 else { return nil }
            versionMajor = Int(b[0]); versionMinor = Int(b[1])
            profile = Int(b[2] >> 1)
            level = Int((b[2] & 1) << 5 | b[3] >> 3)
            rpuPresent = b[3] & 0x04 != 0
            elPresent = b[3] & 0x02 != 0
            blPresent = b[3] & 0x01 != 0
            compatibilityID = Int(b[4] >> 4)
            record = Array(b.prefix(24)) + [UInt8](repeating: 0, count: max(0, 24 - b.count))
        }

        /// `dvcC` (profile ≤ 7), `dvvC` (8…10), `dvwC` (> 10) holding the 24-byte record.
        var configBox: Data {
            let type = profile <= 7 ? "dvcC" : (profile <= 10 ? "dvvC" : "dvwC")
            let payload = record
            return box(type) { $0.bytes(payload) }
        }
    }

    static let dolbyVisionConfigTypes: Set<UInt32> = [0x64766343 /* dvcC */, 0x64767643 /* dvvC */, 0x64767743 /* dvwC */]

    /// The track's Dolby Vision configuration from its BlockAdditionMapping.
    static func dolbyVisionConfig(of track: MKVTrack) -> DolbyVisionConfig? {
        for mapping in track.blockAdditionMappings where dolbyVisionConfigTypes.contains(mapping.idType) {
            if let config = DolbyVisionConfig(mapping.extraData) { return config }
        }
        return nil
    }

    /// Synthesizes hvcC bytes 0…21 from an SPS (when CodecPrivate had none usable).
    fileprivate static func hvcCHeader(from sps: HEVCSPSInfo, lengthSize: Int) -> [UInt8] {
        var h: [UInt8] = [1]
        h += sps.profileTierLevel                               // bytes 1…12
        h += [0xF0, 0x00]                                       // min_spatial_segmentation_idc = 0
        h += [0xFC]                                             // parallelismType = 0
        h += [0xFC | UInt8(sps.chromaFormatIDC & 3)]
        h += [0xF8 | UInt8((sps.bitDepthLuma - 8) & 7), 0xF8 | UInt8((sps.bitDepthChroma - 8) & 7)]
        h += [0, 0]                                             // avgFrameRate
        h += [UInt8(((sps.maxSubLayersMinus1 + 1) & 7) << 3) | (sps.temporalIdNesting ? 0x04 : 0) | UInt8((lengthSize - 1) & 3)]
        return h
    }

    fileprivate static func makeHEVCPlan(track: MKVTrack, sampleFrames: [Data], releaseHintsHDR: Bool) -> Result<RemuxVideoPlan, RemuxUnsupported> {
        let codecPrivate = [UInt8](track.codecPrivate)
        var record: HvcCRecord?
        var annexBConfig: [[UInt8]] = []
        if startsWithStartCode(codecPrivate) {
            annexBConfig = annexBNALUnits(codecPrivate)
        } else if codecPrivate.count >= 23, codecPrivate[0] <= 1 {
            record = HvcCRecord(bytes: codecPrivate)
        }
        var rebuild = record == nil || codecPrivate.first != 1
        var lengthSize = record?.lengthSize ?? 4

        // Sample layout: length-prefixed (normal) or Annex B (broken muxers).
        var annexBSamples = false
        if let first = sampleFrames.first(where: { !$0.isEmpty }) {
            let bytes = [UInt8](first)
            if lengthPrefixedNALUnits(bytes, lengthSize: lengthSize) == nil, startsWithStartCode(bytes) {
                annexBSamples = true
            }
        }
        if annexBSamples, lengthSize != 4 { lengthSize = 4; rebuild = true }

        // Parameter sets: hvcC arrays, else (hev1-style) the first keyframe's in-band NAL units.
        var parameterSets: [UInt8: [[UInt8]]] = [32: [], 33: [], 34: []]
        var otherArrays: [HvcCRecord.NALArray] = []
        for array in record?.arrays ?? [] {
            if parameterSets[array.type] != nil { parameterSets[array.type]! += array.units } else { otherArrays.append(array) }
        }
        for unit in annexBConfig where unit.count >= 2 {
            let type = (unit[0] >> 1) & 0x3F
            if parameterSets[type] != nil { parameterSets[type]!.append(unit) }
        }
        let missingInConfig = parameterSets.values.contains { $0.isEmpty }
        if missingInConfig {
            rebuild = true
            for frame in sampleFrames {
                var found: [UInt8: [[UInt8]]] = [:]
                for unit in nalUnits(of: frame, lengthSize: lengthSize, annexB: annexBSamples) where unit.count >= 2 {
                    let type = (unit[0] >> 1) & 0x3F
                    if parameterSets[type]?.isEmpty == true { found[type, default: []].append(unit) }
                }
                for (type, units) in found { parameterSets[type] = units }
                if !parameterSets.values.contains(where: { $0.isEmpty }) { break }
            }
        }
        guard let spsNAL = parameterSets[33]?.first, !(parameterSets[34]?.isEmpty ?? true), !(parameterSets[32]?.isEmpty ?? true) else {
            return .failure(RemuxUnsupported("HEVC : paramètres VPS/SPS/PPS introuvables"))
        }
        guard let sps = parseHEVCSPS(spsNAL) else {
            return .failure(RemuxUnsupported("HEVC : SPS illisible"))
        }
        if sps.chromaFormatIDC >= 2 {
            return .failure(RemuxUnsupported("HEVC \(sps.chromaFormatIDC == 2 ? "4:2:2" : "4:4:4") non pris en charge par AVPlayer"))
        }
        if sps.bitDepthLuma > 10 || sps.bitDepthChroma > 10 {
            return .failure(RemuxUnsupported("HEVC \(sps.bitDepthLuma) bits non pris en charge par AVPlayer"))
        }

        // hvcC: verbatim when complete, else rebuilt (hvc1 requires the parameter sets in the sample entry).
        var header: [UInt8]
        if let existing = record, existing.header.count == 22, existing.header[1] & 0x1F != 0 {
            header = existing.header
            header[21] = (header[21] & 0xFC) | UInt8((lengthSize - 1) & 3)
            // Keep the record's profile fields only if they agree with the SPS profile.
            if Int(header[1] & 0x1F) != sps.profileIDC, sps.profileIDC != 0 {
                header = hvcCHeader(from: sps, lengthSize: lengthSize)
                rebuild = true
            }
        } else {
            header = hvcCHeader(from: sps, lengthSize: lengthSize)
            rebuild = true
        }
        let hvcC: [UInt8]
        if rebuild {
            var arrays: [HvcCRecord.NALArray] = []
            for type: UInt8 in [32, 33, 34] {
                arrays.append(HvcCRecord.NALArray(completeness: true, type: type, units: parameterSets[type] ?? []))
            }
            arrays += otherArrays.map { HvcCRecord.NALArray(completeness: false, type: $0.type, units: $0.units) }
            hvcC = HvcCRecord(header: header, arrays: arrays).serialized()
        } else {
            hvcC = codecPrivate
        }

        // Dolby Vision.
        var sawRPU = false, sawEL = false
        for frame in sampleFrames.prefix(12) {
            for unit in nalUnits(of: frame, lengthSize: lengthSize, annexB: annexBSamples) {
                let type = (unit[0] >> 1) & 0x3F
                if type == 62 { sawRPU = true }
                if type == 63 { sawEL = true }
            }
        }
        let dv = dolbyVisionConfig(of: track)
        var dvMode: (profile: Int, level: Int, compat: Int)?
        var stripDolbyVisionLayers = false
        var note: String?
        var noteNeedsRange = false
        if let dv = dv {
            switch dv.profile {
            case _ where dv.profile == 5 || (dv.profile == 8 && [1, 2, 4].contains(dv.compatibilityID)):
                if sawRPU {
                    dvMode = (dv.profile, dv.level, dv.compatibilityID)
                } else {
                    // Signalling DV without RPUs (NAL 62) in the samples makes
                    // Apple's decoder fail (-12137): play the base layer instead.
                    note = "Dolby Vision \(dv.profile) sans RPU — couche de base"
                }
            case 7:
                stripDolbyVisionLayers = true
                note = "Dolby Vision 7 (double couche) lu en HDR10"
            default:
                note = "Dolby Vision \(dv.profile) ignoré — couche de base"
            }
        } else if sawEL {
            stripDolbyVisionLayers = true
            note = "Dolby Vision double couche sans configuration — lu en HDR10"
        } else if sawRPU {
            note = "Dolby Vision sans configuration — lu en "
            noteNeedsRange = true
        }

        // Colour, geometry, HDR metadata.
        let firstNALs = sampleFrames.first.map { nalUnits(of: $0, lengthSize: lengthSize, annexB: annexBSamples) } ?? []
        let seiNALs = (record?.arrays ?? []).filter { $0.type == 39 || $0.type == 40 }.flatMap { $0.units } + firstNALs
        let sei = hdrSEIPayloads(seiNALs, hevc: true)
        var streamColor = sps.video.color
        streamColor.bitDepth = sps.bitDepthLuma
        // Profile 5 (IPTPQc2) has no meaningful nclx: never synthesize one for it.
        let dvCompat: Int? = dvMode.flatMap { $0.profile == 5 ? nil : $0.compat } ?? (stripDolbyVisionLayers ? 6 : nil)
        let color = resolveColor(track: track, stream: streamColor, dolbyVisionCompatibility: dvCompat, releaseHintsHDR: releaseHintsHDR)
        let geometry = resolveGeometry(track: track, streamWidth: sps.video.width, streamHeight: sps.video.height,
                                       streamSAR: sps.video.sampleAspectRatio)
        let fps = frameRate(track: track, streamFrameRate: sps.video.timingFrameRate)

        // Box order as Apple's own writer emits it: hvcC, dvcC/dvvC, colr, pasp, mdcv, clli.
        var children: [Data] = [box("hvcC") { $0.bytes(hvcC) }]
        if let dv = dv, dvMode != nil { children.append(dv.configBox) }
        if hasColorDescription(color) { children.append(colrBox(color)) }
        if let pasp = geometry.pasp { children.append(paspBox(h: pasp.0, v: pasp.1)) }
        children += hdrMetadataBoxes(colour: track.colour, seiMDCV: sei.mdcv, seiCLLI: sei.clli)

        let hevcCodecs = hevcCodecString(profileTierLevel: Array(hvcC[1...12]), sampleEntry: "hvc1")
        let baseLabel = "HEVC " + hevcProfileName(sps)
        var transforms: [(Data) -> Data] = []
        if annexBSamples { transforms.append { annexBToLengthPrefixed($0) } }
        if stripDolbyVisionLayers {
            let size = lengthSize
            transforms.append { strippingHEVCNALUnits($0, lengthSize: size, types: [62, 63]) }
        }
        let transform: ((Data) -> Data)? = transforms.isEmpty ? nil : { data in transforms.reduce(data) { $1($0) } }

        if let mode = dvMode {
            let level = String(format: "%02d", mode.level)
            if mode.profile == 5 {
                let entry = visualSampleEntry("dvh1", width: geometry.codedWidth, height: geometry.codedHeight, children: children)
                return .success(RemuxVideoPlan(
                    codec: .dolbyVision(profile: 5, level: mode.level, compatibilityID: mode.compat),
                    sampleEntry: entry, codecsString: "dvh1.05.\(level)", supplementalCodecs: nil, videoRange: .pq,
                    displayWidth: geometry.displayWidth, displayHeight: geometry.displayHeight,
                    codedWidth: geometry.codedWidth, codedHeight: geometry.codedHeight, frameRate: fps,
                    summary: videoSummary("Dolby Vision 5", rangeLabel: nil, geometry: geometry, fps: fps, note: nil),
                    transform: transform))
            }
            let (brand, range, rangeLabel): (String, RemuxVideoRange, String)
            switch mode.compat {
            case 1: (brand, range, rangeLabel) = ("db1p", .pq, "HDR10")
            case 2: (brand, range, rangeLabel) = ("db2g", .sdr, "SDR")
            default: (brand, range, rangeLabel) = ("db4h", .hlg, "HLG")
            }
            let entry = visualSampleEntry("hvc1", width: geometry.codedWidth, height: geometry.codedHeight, children: children)
            return .success(RemuxVideoPlan(
                codec: .dolbyVision(profile: 8, level: mode.level, compatibilityID: mode.compat),
                sampleEntry: entry, codecsString: hevcCodecs, supplementalCodecs: "dvh1.08.\(level)/\(brand)", videoRange: range,
                displayWidth: geometry.displayWidth, displayHeight: geometry.displayHeight,
                codedWidth: geometry.codedWidth, codedHeight: geometry.codedHeight, frameRate: fps,
                summary: videoSummary("Dolby Vision 8.\(mode.compat) (\(rangeLabel))", rangeLabel: nil, geometry: geometry, fps: fps, note: nil),
                transform: transform))
        }

        let range = videoRange(transfer: color.transfer)
        if noteNeedsRange, let prefix = note { note = prefix + rangeName(range) }
        let entry = visualSampleEntry("hvc1", width: geometry.codedWidth, height: geometry.codedHeight, children: children)
        return .success(RemuxVideoPlan(
            codec: .hevc, sampleEntry: entry, codecsString: hevcCodecs, supplementalCodecs: nil, videoRange: range,
            displayWidth: geometry.displayWidth, displayHeight: geometry.displayHeight,
            codedWidth: geometry.codedWidth, codedHeight: geometry.codedHeight, frameRate: fps,
            summary: videoSummary(baseLabel, rangeLabel: rangeName(range), geometry: geometry, fps: fps, note: note),
            transform: transform))
    }
}

// MARK: - AV1

extension RemuxCodecs {

    struct AV1SequenceHeader {
        var profile = 0
        var level = 0
        var tier = 0
        var bitDepth = 8
        var highBitDepth = false
        var twelveBit = false
        var monochrome = false
        var subsamplingX = 1
        var subsamplingY = 1
        var chromaSamplePosition = 0
        var color = RemuxColorInfo()
        var maxWidth = 0
        var maxHeight = 0
        var frameRate: Double?
    }

    /// OBUs of a low-overhead bitstream (type, header+payload bytes, payload range).
    fileprivate static func av1OBUs(_ b: [UInt8]) -> [(type: Int, obu: [UInt8], payload: Range<Int>)] {
        var out: [(type: Int, obu: [UInt8], payload: Range<Int>)] = []
        var pos = 0
        while pos < b.count {
            let header = b[pos]
            guard header & 0x80 == 0 else { break }             // obu_forbidden_bit
            let type = Int((header >> 3) & 0x0F)
            let hasExtension = header & 0x04 != 0
            let hasSize = header & 0x02 != 0
            var cursor = pos + 1 + (hasExtension ? 1 : 0)
            guard cursor <= b.count else { break }
            var size = b.count - cursor
            if hasSize {
                var value = 0
                var shift = 0
                var ok = false
                while cursor < b.count, shift < 56 {
                    let byte = b[cursor]; cursor += 1
                    value |= Int(byte & 0x7F) << shift
                    shift += 7
                    if byte & 0x80 == 0 { ok = true; break }
                }
                guard ok else { break }
                size = value
            }
            guard size >= 0, cursor + size <= b.count else { break }
            let payloadStart = cursor - pos
            out.append((type: type, obu: Array(b[pos..<(cursor + size)]), payload: payloadStart..<(payloadStart + size)))
            pos = cursor + size
        }
        return out
    }

    /// AV1 sequence_header_obu() through color_config().
    static func parseAV1SequenceHeader(_ payload: [UInt8]) -> AV1SequenceHeader? {
        var r = BitReader(payload)
        var h = AV1SequenceHeader()
        h.profile = Int(r.read(3))
        r.skip(1)                                               // still_picture
        let reduced = r.readBool()                              // reduced_still_picture_header
        if reduced {
            h.level = Int(r.read(5))
        } else {
            var decoderModelInfoPresent = false
            var bufferDelayLength = 0
            if r.readBool() {                                   // timing_info_present_flag
                let units = r.read(32), scale = r.read(32)
                if r.readBool() {                               // equal_picture_interval
                    var leadingZeros = 0                        // num_ticks_per_picture_minus_1 uvlc()
                    while !r.readBool() { leadingZeros += 1; if leadingZeros >= 32 || r.overrun { return nil } }
                    let value = leadingZeros > 0 ? Double(r.read64(leadingZeros)) + Double((UInt64(1) << UInt64(leadingZeros)) - 1) : 0
                    if units > 0, scale > 0 {
                        let fps = Double(scale) / (Double(units) * (value + 1))
                        if fps >= 1, fps <= 300 { h.frameRate = fps }
                    }
                }
                decoderModelInfoPresent = r.readBool()
                if decoderModelInfoPresent {
                    bufferDelayLength = Int(r.read(5)) + 1
                    r.skip(32)                                  // num_units_in_decoding_tick
                    r.skip(5); r.skip(5)                        // buffer_removal_time / frame_presentation_time lengths
                }
            }
            let initialDisplayDelayPresent = r.readBool()
            let operatingPoints = Int(r.read(5)) + 1
            for i in 0..<operatingPoints {
                r.skip(12)                                      // operating_point_idc
                let level = Int(r.read(5))
                let tier = level > 7 ? Int(r.read(1)) : 0
                if i == 0 { h.level = level; h.tier = tier }
                if decoderModelInfoPresent, r.readBool() {
                    r.skip(bufferDelayLength * 2 + 1)           // decoder/encoder buffer delay, low_delay_mode_flag
                }
                if initialDisplayDelayPresent, r.readBool() { r.skip(4) }
            }
        }
        let widthBits = Int(r.read(4)) + 1
        let heightBits = Int(r.read(4)) + 1
        h.maxWidth = Int(r.read(widthBits)) + 1
        h.maxHeight = Int(r.read(heightBits)) + 1
        if !reduced, r.readBool() {                             // frame_id_numbers_present_flag
            r.skip(4); r.skip(3)
        }
        r.skip(3)                                               // use_128x128_superblock, filter_intra, intra_edge
        if !reduced {
            r.skip(4)                                           // interintra, masked, warped, dual_filter
            let orderHint = r.readBool()
            if orderHint { r.skip(2) }                          // jnt_comp, ref_frame_mvs
            var forceScreenContentTools = 2
            if !r.readBool() { forceScreenContentTools = Int(r.read(1)) }   // seq_choose_screen_content_tools
            if forceScreenContentTools > 0, !r.readBool() { r.skip(1) }    // seq_choose_integer_mv / force
            if orderHint { r.skip(3) }                          // order_hint_bits_minus_1
        }
        r.skip(3)                                               // superres, cdef, restoration
        // color_config()
        h.highBitDepth = r.readBool()
        if h.profile == 2, h.highBitDepth {
            h.twelveBit = r.readBool()
            h.bitDepth = h.twelveBit ? 12 : 10
        } else {
            h.bitDepth = h.highBitDepth ? 10 : 8
        }
        h.monochrome = h.profile == 1 ? false : r.readBool()
        var cp = 2, tc = 2, mc = 2
        if r.readBool() {                                       // color_description_present_flag
            cp = Int(r.read(8)); tc = Int(r.read(8)); mc = Int(r.read(8))
            h.color.primaries = cp; h.color.transfer = tc; h.color.matrix = mc
        }
        if h.monochrome {
            h.color.fullRange = r.readBool()
            h.subsamplingX = 1; h.subsamplingY = 1
        } else if cp == 1, tc == 13, mc == 0 {
            h.color.fullRange = true
            h.subsamplingX = 0; h.subsamplingY = 0
        } else {
            h.color.fullRange = r.readBool()
            switch h.profile {
            case 0: h.subsamplingX = 1; h.subsamplingY = 1
            case 1: h.subsamplingX = 0; h.subsamplingY = 0
            default:
                if h.bitDepth == 12 {
                    h.subsamplingX = Int(r.read(1))
                    h.subsamplingY = h.subsamplingX == 1 ? Int(r.read(1)) : 0
                } else {
                    h.subsamplingX = 1; h.subsamplingY = 0
                }
            }
            if h.subsamplingX == 1, h.subsamplingY == 1 { h.chromaSamplePosition = Int(r.read(2)) }
        }
        h.color.bitDepth = h.bitDepth
        guard !r.overrun else { return nil }
        return h
    }

    fileprivate static func makeAV1Plan(track: MKVTrack, sampleFrames: [Data], releaseHintsHDR: Bool) -> Result<RemuxVideoPlan, RemuxUnsupported> {
        let codecPrivate = [UInt8](track.codecPrivate)
        let hasRecord = codecPrivate.count >= 4 && codecPrivate[0] == 0x81
        var configOBUs: [UInt8] = hasRecord ? Array(codecPrivate[4...]) : codecPrivate

        // Sequence header: configOBUs first, then the first frames.
        func sequenceHeaderOBU(in bytes: [UInt8]) -> (obu: [UInt8], header: AV1SequenceHeader)? {
            for obu in av1OBUs(bytes) where obu.type == 1 {
                if let header = parseAV1SequenceHeader(Array(obu.obu[obu.payload])) { return (obu.obu, header) }
            }
            return nil
        }
        var found = sequenceHeaderOBU(in: configOBUs)
        if found == nil {
            configOBUs = []
            for frame in sampleFrames {
                if let header = sequenceHeaderOBU(in: [UInt8](frame)) {
                    // Store it with obu_has_size_field = 1, as configOBUs require.
                    var obu = header.obu
                    if obu[0] & 0x02 == 0 {
                        let headerLength = (obu[0] & 0x04 != 0) ? 2 : 1
                        let payload = Array(obu[headerLength...])
                        var size = payload.count
                        var leb: [UInt8] = []
                        repeat {
                            var byte = UInt8(size & 0x7F)
                            size >>= 7
                            if size > 0 { byte |= 0x80 }
                            leb.append(byte)
                        } while size > 0
                        obu = [obu[0] | 0x02] + Array(obu[1..<headerLength]) + leb + payload
                    }
                    configOBUs = obu
                    found = (obu, header.header)
                    break
                }
            }
        }
        guard let sequence = found?.header else {
            return .failure(RemuxUnsupported("AV1 : en-tête de séquence introuvable"))
        }
        guard sequence.profile == 0 else {
            return .failure(RemuxUnsupported("AV1 profil \(sequence.profile == 1 ? "High" : "Professional") non pris en charge par AVPlayer"))
        }
        guard sequence.bitDepth <= 10 else {
            return .failure(RemuxUnsupported("AV1 \(sequence.bitDepth) bits non pris en charge par AVPlayer"))
        }

        var av1C: [UInt8]
        if hasRecord {
            av1C = Array(codecPrivate[0..<4]) + configOBUs
        } else {
            let b1 = UInt8(sequence.profile << 5) | UInt8(sequence.level & 0x1F)
            var b2 = UInt8(sequence.tier << 7)
            if sequence.highBitDepth { b2 |= 0x40 }
            if sequence.twelveBit { b2 |= 0x20 }
            if sequence.monochrome { b2 |= 0x10 }
            b2 |= UInt8(sequence.subsamplingX << 3) | UInt8(sequence.subsamplingY << 2) | UInt8(sequence.chromaSamplePosition & 3)
            av1C = [0x81, b1, b2, 0x00] + configOBUs
        }

        let color = resolveColor(track: track, stream: sequence.color, dolbyVisionCompatibility: nil, releaseHintsHDR: releaseHintsHDR)
        guard let codecs = av1CodecString(av1C: Data(av1C), color: hasColorDescription(color) ? color : nil) else {
            return .failure(RemuxUnsupported("AV1 : configuration av1C invalide"))
        }
        let geometry = resolveGeometry(track: track, streamWidth: track.pixelWidth > 0 ? nil : sequence.maxWidth,
                                       streamHeight: track.pixelHeight > 0 ? nil : sequence.maxHeight, streamSAR: nil)
        var children: [Data] = [box("av1C") { $0.bytes(av1C) }]
        if hasColorDescription(color) { children.append(colrBox(color)) }
        if let pasp = geometry.pasp { children.append(paspBox(h: pasp.0, v: pasp.1)) }
        children += hdrMetadataBoxes(colour: track.colour, seiMDCV: nil, seiCLLI: nil)
        let entry = visualSampleEntry("av01", width: geometry.codedWidth, height: geometry.codedHeight, children: children)
        let range = videoRange(transfer: color.transfer)
        let fps = frameRate(track: track, streamFrameRate: sequence.frameRate)
        let label = "AV1 Main" + (sequence.bitDepth > 8 ? " \(sequence.bitDepth)" : "")
        return .success(RemuxVideoPlan(
            codec: .av1, sampleEntry: entry, codecsString: codecs, supplementalCodecs: nil, videoRange: range,
            displayWidth: geometry.displayWidth, displayHeight: geometry.displayHeight,
            codedWidth: geometry.codedWidth, codedHeight: geometry.codedHeight, frameRate: fps,
            summary: videoSummary(label, rangeLabel: rangeName(range), geometry: geometry, fps: fps, note: nil),
            transform: nil))
    }
}

// MARK: - Encoder settings: declared keyframe interval (x264 / x265)

extension RemuxCodecs {

    /// The maximum keyframe interval, in frames, that an x264 / x265 encode
    /// declares in its settings string — the `user_data_unregistered` SEI
    /// (payload type 5) both encoders write in the first access unit
    /// ("x264 - core 164 … options: … keyint=250 keyint_min=23 …"; x265:
    /// "x265 (build 199) … options: … keyint=250 min-keyint=25 …"), found in
    /// `sampleFrames` (the first pictures; length-prefixed with the avcC /
    /// hvcC size, or Annex B) or in the hvcC SEI arrays (mkvmerge moves
    /// x265's there). nil for another codec or encoder, when the string is
    /// absent, or for `keyint=infinite` (x264 `--keyint infinite`).
    static func declaredKeyframeInterval(codecID: String, codecPrivate: Data, sampleFrames: [Data]) -> Int? {
        let id = codecID.uppercased()
        let hevc: Bool
        switch id {
        case "V_MPEG4/ISO/AVC": hevc = false
        case "V_MPEGH/ISO/HEVC": hevc = true
        default: return nil
        }
        let privateBytes = [UInt8](codecPrivate)
        var lengthSize = 4
        var units: [[UInt8]] = []
        if startsWithStartCode(privateBytes) {
            units += annexBNALUnits(privateBytes)
        } else if hevc, let record = HvcCRecord(bytes: privateBytes) {
            lengthSize = record.lengthSize
            units += record.nalUnits(ofType: 39) + record.nalUnits(ofType: 40)
        } else if !hevc, privateBytes.count >= 5, privateBytes[0] == 1 {
            lengthSize = Int(privateBytes[4] & 3) + 1
        }
        for frame in sampleFrames where !frame.isEmpty {
            let bytes = [UInt8](frame)
            units += lengthPrefixedNALUnits(bytes, lengthSize: lengthSize)
                ?? (startsWithStartCode(bytes) ? annexBNALUnits(bytes) : [])
        }
        for nal in units {
            guard let first = nal.first else { continue }
            let isSEI = hevc ? ((first >> 1) & 0x3F == 39 || (first >> 1) & 0x3F == 40) && nal.count > 2 : first & 0x1F == 6
            guard isSEI else { continue }
            let rbsp = unescapeRBSP(nal, from: hevc ? 2 : 1)
            var pos = 0
            while pos + 1 < rbsp.count {
                var type = 0
                while pos < rbsp.count, rbsp[pos] == 0xFF { type += 255; pos += 1 }
                guard pos < rbsp.count else { break }
                type += Int(rbsp[pos]); pos += 1
                var size = 0
                while pos < rbsp.count, rbsp[pos] == 0xFF { size += 255; pos += 1 }
                guard pos < rbsp.count else { break }
                size += Int(rbsp[pos]); pos += 1
                guard pos + size <= rbsp.count else { break }
                // user_data_unregistered: a 16-byte UUID, then the settings text.
                if type == 5, size > 16 {
                    let text = String(decoding: rbsp[(pos + 16)..<(pos + size)].map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
                    if let keyint = keyframeInterval(fromEncoderSettings: text) { return keyint }
                }
                pos += size
            }
        }
        return nil
    }

    /// `keyint=N` of an x264 / x265 settings string (see
    /// `declaredKeyframeInterval`); nil when the text is not one of theirs,
    /// has no such option, or declares `keyint=infinite`.
    static func keyframeInterval(fromEncoderSettings text: String) -> Int? {
        guard text.hasPrefix("x264") || text.hasPrefix("x265") else { return nil }
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\0" || $0 == "\n" }) where token.hasPrefix("keyint=") {
            let value = token.dropFirst("keyint=".count)
            guard let frames = Int(value), frames > 0 else { return nil }
            return frames
        }
        return nil
    }
}

// MARK: - Video: colour, geometry, summary

extension RemuxCodecs {

    struct VideoGeometry {
        var codedWidth: Int
        var codedHeight: Int
        var displayWidth: Int
        var displayHeight: Int
        /// `pasp` hSpacing:vSpacing when the pixel aspect ratio isn't 1:1.
        var pasp: (Int, Int)?
    }

    /// Coded size = the stream's cropped size (else Matroska PixelWidth/Height).
    /// Display size: Matroska DisplayWidth/Height (any unit → a ratio), else
    /// the VUI sample aspect ratio, else square pixels.
    fileprivate static func resolveGeometry(track: MKVTrack, streamWidth: Int?, streamHeight: Int?, streamSAR: (Int, Int)?) -> VideoGeometry {
        // Every input is clamped to 1…65535 (a corrupt element must never overflow the math below).
        func dimension(_ value: Int?) -> Int? {
            guard let v = value, v > 0 else { return nil }
            return min(v, 65535)
        }
        let codedWidth = dimension(streamWidth) ?? dimension(track.pixelWidth) ?? 1
        let codedHeight = dimension(streamHeight) ?? dimension(track.pixelHeight) ?? 1
        var sar: (Int, Int)?
        if track.displayWidth != nil || track.displayHeight != nil,
           let dw = dimension(track.displayWidth ?? (track.pixelWidth > 0 ? track.pixelWidth : codedWidth)),
           let dh = dimension(track.displayHeight ?? (track.pixelHeight > 0 ? track.pixelHeight : codedHeight)) {
            // DAR = dw/dh → SAR = (dw × codedHeight) : (dh × codedWidth).
            sar = (dw * codedHeight, dh * codedWidth)
        }
        if sar == nil, let s = streamSAR, s.0 > 0, s.1 > 0, s.0 <= 65535, s.1 <= 65535 { sar = s }
        guard let ratio = sar, ratio.0 != ratio.1, Double(ratio.0) / Double(ratio.1) > 0.25, Double(ratio.0) / Double(ratio.1) < 4 else {
            return VideoGeometry(codedWidth: codedWidth, codedHeight: codedHeight, displayWidth: codedWidth,
                                 displayHeight: codedHeight, pasp: nil)
        }
        let g = gcd(ratio.0, ratio.1)
        let h = ratio.0 / g, v = ratio.1 / g          // ≤ 65535² < UInt32.max
        let displayWidth = min(65535, max(1, safeInt(Double(codedWidth) * Double(h) / Double(v))))
        return VideoGeometry(codedWidth: codedWidth, codedHeight: codedHeight, displayWidth: displayWidth,
                             displayHeight: codedHeight, pasp: (h, v))
    }

    /// Colour resolution: Matroska Colour → stream (VUI / AV1 colour config)
    /// → Dolby Vision compatibility id → release HDR hint (PQ) → unknown (SDR).
    static func resolveColor(track: MKVTrack, stream: RemuxColorInfo?, dolbyVisionCompatibility: Int?, releaseHintsHDR: Bool) -> RemuxColorInfo {
        // 0 = reserved (primaries/transfer) or identity/RGB (matrix — never
        // right for YUV video), 2 = unspecified, 3 = reserved.
        func valid(_ value: Int?) -> Int? {
            guard let v = value, v > 0, v != 2, v != 3, v < 256 else { return nil }
            return v
        }
        let mkv = track.colour
        var c = RemuxColorInfo()
        c.primaries = valid(mkv?.primaries) ?? valid(stream?.primaries)
        c.transfer = valid(mkv?.transferCharacteristics) ?? valid(stream?.transfer)
        c.matrix = valid(mkv?.matrixCoefficients) ?? valid(stream?.matrix)
        switch mkv?.range {
        case 1: c.fullRange = false
        case 2: c.fullRange = true
        default: c.fullRange = stream?.fullRange
        }
        c.bitDepth = stream?.bitDepth ?? mkv?.bitsPerChannel.flatMap { $0 > 0 ? $0 : nil }

        if c.transfer == nil, let compat = dolbyVisionCompatibility {
            switch compat {
            case 1, 6: c.transfer = 16
            case 4: c.transfer = 18
            case 2: c.transfer = 1; c.primaries = c.primaries ?? 1; c.matrix = c.matrix ?? 1
            default: break
            }
        }
        if c.transfer == nil, releaseHintsHDR, (c.bitDepth ?? 10) >= 10 {
            c.transfer = 16
        }
        if let t = c.transfer, t == 16 || t == 18 {
            c.primaries = c.primaries ?? 9
            c.matrix = c.matrix ?? 9
        }
        return c
    }

    fileprivate static func hasColorDescription(_ c: RemuxColorInfo) -> Bool {
        c.primaries != nil || c.transfer != nil || c.matrix != nil
    }

    fileprivate static func videoRange(transfer: Int?) -> RemuxVideoRange {
        switch transfer {
        case 16: return .pq
        case 18: return .hlg
        default: return .sdr
        }
    }

    fileprivate static func rangeName(_ range: RemuxVideoRange) -> String {
        switch range {
        case .pq: return "HDR10"
        case .hlg: return "HLG"
        case .sdr: return "SDR"
        }
    }

    /// FRAME-RATE: Matroska DefaultDuration, else the stream's timing info.
    fileprivate static func frameRate(track: MKVTrack, streamFrameRate: Double?) -> Double? {
        if track.defaultDurationNs > 0 {
            let fps = 1e9 / Double(track.defaultDurationNs)
            if fps >= 1, fps <= 300 { return fps }
        }
        return streamFrameRate
    }

    fileprivate static func formatFrameRate(_ fps: Double) -> String {
        if abs(fps - fps.rounded()) < 0.005 { return String(format: "%.0f", fps) }
        var s = String(format: "%.3f", fps)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    fileprivate static func videoSummary(_ label: String, rangeLabel: String?, geometry: VideoGeometry, fps: Double?, note: String?) -> String {
        var parts = [label]
        if let rangeLabel = rangeLabel { parts.append(rangeLabel) }
        parts.append("\(geometry.displayWidth)×\(geometry.displayHeight)")
        if let fps = fps { parts.append("\(formatFrameRate(fps)) i/s") }
        if let note = note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - AC-3 / E-AC-3

extension RemuxCodecs {

    /// One (E-)AC-3 syncframe as walked inside a Matroska block.
    struct DolbySyncframe {
        var isAC3: Bool
        /// 0 independent, 1 dependent, 2 independent (converted from AC-3). AC-3 frames: 0.
        var strmtyp: Int
        var substreamID: Int
        var frameBytes: Int
        var fscod: Int
        var sampleRate: Int
        var blocks: Int
        var acmod: Int
        var lfeon: Int
        var bsid: Int
        var bsmod: Int
        var chanmap: Int?
        var hasJOC: Bool
        var jocComplexity: Int?
        var bsiComplete: Bool
        var isIndependent: Bool { strmtyp != 1 }
    }

    /// AC-3 frame size in 16-bit words for 48 / 44.1 / 32 kHz, by frmsizecod >> 1
    /// (A/52 Table 5.18; 44.1 kHz adds 1 word for odd frmsizecod).
    fileprivate static let ac3FrameWords: [[Int]] = [
        [64, 69, 96], [80, 87, 120], [96, 104, 144], [112, 121, 168], [128, 139, 192], [160, 174, 240],
        [192, 208, 288], [224, 243, 336], [256, 278, 384], [320, 348, 480], [384, 417, 576], [448, 487, 672],
        [512, 557, 768], [640, 696, 960], [768, 835, 1152], [896, 975, 1344], [1024, 1114, 1536],
        [1152, 1253, 1728], [1280, 1393, 1920],
    ]
    fileprivate static let ac3Bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
    fileprivate static let ac3ChannelsByAcmod = [2, 1, 2, 3, 3, 4, 4, 5]

    fileprivate static func parseAC3Header(_ b: [UInt8], at o: Int) -> AC3Info? {
        guard o + 8 <= b.count, b[o] == 0x0B, b[o + 1] == 0x77 else { return nil }
        var r = BitReader(Array(b[(o + 4)..<(o + 8)]))
        let fscod = Int(r.read(2))
        let frmsizecod = Int(r.read(6))
        let bsid = Int(r.read(5))
        let bsmod = Int(r.read(3))
        let acmod = Int(r.read(3))
        var cmixlev: Int?, surmixlev: Int?, dsurmod: Int?
        if acmod & 1 != 0, acmod != 1 { cmixlev = Int(r.read(2)) }
        if acmod & 4 != 0 { surmixlev = Int(r.read(2)) }
        if acmod == 2 { dsurmod = Int(r.read(2)) }
        let lfeon = Int(r.read(1))
        guard fscod != 3, frmsizecod < 38, bsid <= 10 else { return nil }
        let shift = max(bsid, 8) - 8
        let words = ac3FrameWords[frmsizecod >> 1][fscod] + (fscod == 1 ? (frmsizecod & 1) : 0)
        return AC3Info(fscod: fscod, frmsizecod: frmsizecod, bsid: bsid, bsmod: bsmod, acmod: acmod, lfeon: lfeon,
                       sampleRate: [48000, 44100, 32000][fscod] >> shift,
                       bitrateKbps: ac3Bitrates[frmsizecod >> 1] >> shift,
                       channelCount: ac3ChannelsByAcmod[acmod] + lfeon,
                       frameBytes: words * 2, cmixlev: cmixlev, surmixlev: surmixlev, dsurmod: dsurmod)
    }

    /// Parses one syncframe at `o`: AC-3 (bsid ≤ 10) header, or the full
    /// E-AC-3 bsi() of ETSI TS 102 366 Annex E (E.1.2.2) through addbsi.
    fileprivate static func parseDolbySyncframe(_ b: [UInt8], at o: Int) -> DolbySyncframe? {
        guard o + 6 <= b.count, b[o] == 0x0B, b[o + 1] == 0x77 else { return nil }
        let bsidPeek = Int(b[o + 5] >> 3)
        if bsidPeek <= 10 {
            guard let ac3 = parseAC3Header(b, at: o) else { return nil }
            return DolbySyncframe(isAC3: true, strmtyp: 0, substreamID: 0, frameBytes: ac3.frameBytes, fscod: ac3.fscod,
                                  sampleRate: ac3.sampleRate, blocks: 6, acmod: ac3.acmod, lfeon: ac3.lfeon, bsid: ac3.bsid,
                                  bsmod: ac3.bsmod, chanmap: nil, hasJOC: false, jocComplexity: nil, bsiComplete: true)
        }
        guard bsidPeek <= 16 else { return nil }
        let frmsiz = (Int(b[o + 2] & 0x07) << 8) | Int(b[o + 3])
        let frameBytes = (frmsiz + 1) * 2
        guard frameBytes >= 6 else { return nil }
        var r = BitReader(Array(b[(o + 2)..<min(b.count, o + frameBytes)]))

        let strmtyp = Int(r.read(2))
        guard strmtyp != 3 else { return nil }
        let substreamID = Int(r.read(3))
        r.skip(11)                                              // frmsiz
        let fscod = Int(r.read(2))
        let sampleRate: Int
        let numblkscod: Int
        if fscod == 3 {
            let fscod2 = Int(r.read(2))
            guard fscod2 != 3 else { return nil }
            sampleRate = [24000, 22050, 16000][fscod2]
            numblkscod = 3
        } else {
            sampleRate = [48000, 44100, 32000][fscod]
            numblkscod = Int(r.read(2))
        }
        let blocks = [1, 2, 3, 6][numblkscod]
        let acmod = Int(r.read(3))
        let lfeon = Int(r.read(1))
        let bsid = Int(r.read(5))
        var bsmod = 0
        var chanmap: Int?
        var hasJOC = false
        var jocComplexity: Int?

        r.skip(5)                                               // dialnorm
        if r.readBool() { r.skip(8) }                           // compre → compr
        if acmod == 0 {                                         // 1+1: second channel
            r.skip(5)                                           // dialnorm2
            if r.readBool() { r.skip(8) }                       // compr2e → compr2
        }
        if strmtyp == 1, r.readBool() {                         // chanmape
            chanmap = Int(r.read(16))
        }
        if r.readBool() {                                       // mixmdate
            if acmod > 2 { r.skip(2) }                          // dmixmod
            if acmod & 1 != 0, acmod > 2 { r.skip(6) }          // ltrtcmixlev, lorocmixlev
            if acmod & 4 != 0 { r.skip(6) }                     // ltrtsurmixlev, lorosurmixlev
            if lfeon == 1, r.readBool() { r.skip(5) }           // lfemixlevcode → lfemixlevcod
            if strmtyp == 0 {
                if r.readBool() { r.skip(6) }                   // pgmscle → pgmscl
                if acmod == 0, r.readBool() { r.skip(6) }       // pgmscl2e → pgmscl2
                if r.readBool() { r.skip(6) }                   // extpgmscle → extpgmscl
                switch r.read(2) {                              // mixdef
                case 1: r.skip(5)                               // premixcmpsel, drcsrc, premixcmpscl
                case 2: r.skip(12)                              // mixdata
                case 3:
                    let mixdeflen = Int(r.read(5))
                    r.skip(8 * (mixdeflen + 2))                 // mixdata (+ mixdatafill)
                default: break
                }
                if acmod < 2 {
                    if r.readBool() { r.skip(14) }              // paninfoe → panmean, paninfo
                    if acmod == 0, r.readBool() { r.skip(14) }  // paninfo2e → panmean2, paninfo2
                }
                if r.readBool() {                               // frmmixcfginfoe
                    if numblkscod == 0 {
                        r.skip(5)                               // blkmixcfginfo[0]
                    } else {
                        for _ in 0..<blocks where r.readBool() { r.skip(5) }   // blkmixcfginfoe → blkmixcfginfo
                    }
                }
            }
        }
        if r.readBool() {                                       // infomdate
            bsmod = Int(r.read(3))
            r.skip(2)                                           // copyrightb, origbs
            if acmod == 2 { r.skip(4) }                         // dsurmod, dheadphonmod
            if acmod >= 6 { r.skip(2) }                         // dsurexmod
            if r.readBool() { r.skip(8) }                       // audprodie → mixlevel, roomtyp, adconvtyp
            if acmod == 0, r.readBool() { r.skip(8) }           // audprodi2e → mixlevel2, roomtyp2, adconvtyp2
            if fscod < 3 { r.skip(1) }                          // sourcefscod
        }
        if strmtyp == 0, numblkscod != 3 { r.skip(1) }          // convsync
        if strmtyp == 2 {
            let blkid = numblkscod == 3 ? true : r.readBool()
            if blkid { r.skip(6) }                              // frmsizecod
        }
        if r.readBool() {                                       // addbsie
            let addbsil = Int(r.read(6))
            // addbsi, (addbsil + 1) bytes. ETSI TS 103 420: reserved(7)
            // flag_ec3_extension_type_a(1) [complexity_index_type_a(8)].
            let first = r.read(8)
            var remaining = addbsil
            if !r.overrun, first & 1 == 1 {
                hasJOC = true
                if remaining >= 1 {
                    let complexity = r.read(8)
                    if !r.overrun { jocComplexity = Int(complexity) }
                    remaining -= 1
                }
            }
            r.skip(8 * remaining)
        }
        return DolbySyncframe(isAC3: false, strmtyp: strmtyp, substreamID: substreamID, frameBytes: frameBytes, fscod: fscod,
                              sampleRate: sampleRate, blocks: blocks, acmod: acmod, lfeon: lfeon, bsid: bsid, bsmod: bsmod,
                              chanmap: chanmap, hasJOC: hasJOC, jocComplexity: jocComplexity, bsiComplete: !r.overrun)
    }

    /// Channel locations of an acmod/lfeon pair as an E-AC-3 chanmap mask
    /// (Table E.1.4: bit 15 = L, 14 = C, 13 = R, 12 = Ls, 11 = Rs, … 8 = Cs, … 0 = LFE).
    static func dolbyChannelMask(acmod: Int, lfeon: Int) -> Int {
        let L = 1 << 15, C = 1 << 14, R = 1 << 13, Ls = 1 << 12, Rs = 1 << 11, Cs = 1 << 8
        var mask: Int
        switch acmod {
        case 0: mask = L | R                                    // 1+1 (Ch1, Ch2)
        case 1: mask = C
        case 2: mask = L | R
        case 3: mask = L | C | R
        case 4: mask = L | R | Cs
        case 5: mask = L | C | R | Cs
        case 6: mask = L | R | Ls | Rs
        default: mask = L | C | R | Ls | Rs
        }
        if lfeon == 1 { mask |= 1 }
        return mask
    }

    /// Channels in a chanmap mask (pair locations count twice).
    static func dolbyChannelCount(_ mask: Int) -> Int {
        let pairs: Set<Int> = [10, 9, 6, 5, 4, 2]               // Lc/Rc, Lrs/Rrs, Lsd/Rsd, Lw/Rw, Vhl/Vhr, Lts/Rts
        var count = 0
        for bit in 0..<16 where mask & (1 << bit) != 0 { count += pairs.contains(bit) ? 2 : 1 }
        return count
    }

    /// dec3 `chan_loc` (ETSI TS 102 366 Table F.6.1) from a chanmap mask.
    /// Table F.6.1 bit k is `1 << k` (bit 0 = LSB of the 9-bit field):
    /// Lc/Rc 0x001, Lrs/Rrs 0x002, Cs 0x004, Ts 0x008, Lsd/Rsd 0x010,
    /// Lw/Rw 0x020, Lvh/Rvh 0x040, Cvh 0x080, LFE2 0x100.
    /// This is how Apple both writes and reads the field: AudioFile's own
    /// dec3 for real dependent substreams is 0x001 (chanmap Lc/Rc), 0x002
    /// (Lrs/Rrs), 0x00C (Cs+Ts), 0x010 (Lsd/Rsd), 0x020 (Lw/Rw), 0x040
    /// (Lvh/Rvh), 0x084 (Cs+Cvh), 0x088 (Ts+Cvh), 0x022 (Lrs/Rrs + Lw/Rw);
    /// CoreAudio maps 0x002 to EAC3_7_1_A and 0x080 to EAC3_6_1_C (Vhc).
    /// A chan_loc that disagrees with the substreams' chanmap makes Apple's
    /// decoder output garbage (the old MSB-first 0x080 for a Lrs/Rrs 7.1
    /// stream decoded as a broken 6.1). ffmpeg's `(chanmap >> 5) & 0x1F` is
    /// wrong too (Lrs/Rrs → 0x010 = Lsd/Rsd).
    /// chanmap (bit 15 = L … bit 0 = LFE): Lc/Rc 10, Lrs/Rrs 9, Cs 8, Ts 7,
    /// Lsd/Rsd 6, Lw/Rw 5, Lvh/Rvh 4, Cvh 3, (2 reserved), LFE2 1.
    static func dec3ChanLoc(fromChanmap mask: Int) -> Int {
        var loc = 0
        for k in 0..<8 where mask & (1 << (10 - k)) != 0 { loc |= 1 << k }
        if mask & 0x2 != 0 { loc |= 1 << 8 }
        return loc
    }

    /// Most channels Apple's E-AC-3 decoder outputs: its layouts stop at
    /// 7.1 (EAC3_7_1_A…H). A program with more (e.g. 5.1 + Lrs/Rrs + Lw/Rw)
    /// is decoded as 7.1 (format list [EAC3_7_1_A, 5.1]), so CHANNELS and
    /// the sample entry never claim more than that.
    static let appleEAC3MaxChannels = 8

    /// PCM samples of a Matroska (E-)AC-3 block: 256 × blocks for every
    /// independent substream-0 syncframe (AC-3 syncframes: 1536).
    static func dolbyBlockSamples(_ frame: Data) -> Int? {
        return frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            var pos = 0
            var samples = 0
            while pos + 6 <= raw.count, raw[pos] == 0x0B, raw[pos + 1] == 0x77 {
                let bsid = Int(raw[pos + 5] >> 3)
                var size: Int
                if bsid <= 10 {
                    let fscod = Int(raw[pos + 4] >> 6), frmsizecod = Int(raw[pos + 4] & 0x3F)
                    guard fscod != 3, frmsizecod < 38 else { break }
                    size = 2 * (ac3FrameWords[frmsizecod >> 1][fscod] + (fscod == 1 ? (frmsizecod & 1) : 0))
                    samples += 1536
                } else if bsid <= 16 {
                    let strmtyp = Int(raw[pos + 2] >> 6)
                    let substreamID = Int((raw[pos + 2] >> 3) & 7)
                    size = ((Int(raw[pos + 2] & 7) << 8) | Int(raw[pos + 3])) * 2 + 2
                    let fscod = Int(raw[pos + 4] >> 6)
                    let numblkscod = fscod == 3 ? 3 : Int((raw[pos + 4] >> 4) & 3)
                    if strmtyp != 1, substreamID == 0 { samples += 256 * [1, 2, 3, 6][numblkscod] }
                } else {
                    break
                }
                pos += size
            }
            return samples > 0 ? samples : nil
        }
    }

    fileprivate static func dolbyLayoutName(mask: Int, channels: Int) -> String {
        let lfe = (mask & 1 != 0 ? 1 : 0) + (mask & 2 != 0 ? 1 : 0)
        return "\(channels - lfe).\(lfe)"
    }

    fileprivate static func makeDolbyAudioPlan(track: MKVTrack, firstFrame: Data, releaseTaggedAtmos: Bool) -> Result<RemuxAudioPlan, RemuxUnsupported> {
        let bytes = [UInt8](firstFrame.prefix(16))
        guard bytes.count >= 6, bytes[0] == 0x0B, bytes[1] == 0x77 else {
            return .failure(RemuxUnsupported("AC-3/E-AC-3 : trame illisible"))
        }
        // Decide by the bitstream, not the CodecID (mislabelled tracks exist).
        let isEAC3 = (bytes[5] >> 3) > 10 || (eac3Info(firstFrame)?.substreams.count ?? 1) > 1
        if !isEAC3 {
            guard let info = ac3Info(firstFrame) else {
                return .failure(RemuxUnsupported("AC-3 : en-tête de trame illisible"))
            }
            let dac3 = box("dac3") { $0.bytes(dac3Payload(info)) }
            let entry = audioSampleEntry("ac-3", channels: info.channelCount, sampleSize: 16, sampleRate: info.sampleRate, children: [dac3])
            let main = ac3ChannelsByAcmod[info.acmod]
            return .success(RemuxAudioPlan(
                codec: .ac3, sampleEntry: entry, codecsString: "ac-3", channelsAttribute: String(info.channelCount),
                channelCount: info.channelCount, timescale: UInt32(info.sampleRate), isAtmos: false,
                summary: "AC-3 \(main).\(info.lfeon)",
                frameDuration: { UInt32(clamping: dolbyBlockSamples($0) ?? 1536) }, nominalFrameDuration: 1536, transform: nil))
        }
        guard let info = eac3Info(firstFrame), info.sampleRate > 0, info.samplesPerFrame > 0 else {
            return .failure(RemuxUnsupported("E-AC-3 : en-tête de trame illisible"))
        }
        let atmos = info.hasJOC || (!info.bsiComplete && releaseTaggedAtmos)
        let dec3 = box("dec3") { $0.bytes(dec3Payload(info, signalAtmos: atmos)) }
        // What Apple's decoder outputs: the main program (independent
        // substream 0 + the locations its dependent substreams add, as the
        // dec3 chan_loc announces them — 7.1 for 5.1 + Lrs/Rrs), capped at
        // 7.1. Sample entry channelcount, CHANNELS and the summary all use it.
        // (AVFoundation's format description keeps the 5.1 core in its main
        // ASBD and lists the full layout first in its format list, exactly as
        // for Apple's own AudioFile-written 7.1 E-AC-3 MP4.)
        let channels = min(info.channelCount, appleEAC3MaxChannels)
        let entry = audioSampleEntry("ec-3", channels: channels, sampleSize: 16, sampleRate: info.sampleRate, children: [dec3])
        let nominal = UInt32(clamping: info.samplesPerFrame)
        var summary = "E-AC-3 " + dolbyLayoutName(mask: info.channelMask, channels: channels)
        if atmos { summary += " · Dolby Atmos" }
        return .success(RemuxAudioPlan(
            codec: .eac3, sampleEntry: entry, codecsString: "ec-3",
            channelsAttribute: atmos ? "16/JOC" : String(channels),
            channelCount: channels, timescale: UInt32(info.sampleRate), isAtmos: atmos, summary: summary,
            frameDuration: { UInt32(clamping: dolbyBlockSamples($0) ?? Int(nominal)) }, nominalFrameDuration: nominal, transform: nil))
    }
}

// MARK: - AAC

extension RemuxCodecs {

    fileprivate static let aacSamplingFrequencies = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    fileprivate static func writeSamplingFrequency(_ w: inout BitWriter, _ rate: Int) {
        if let index = aacSamplingFrequencies.firstIndex(of: rate) {
            w.write(UInt32(index), 4)
        } else {
            w.write(0xF, 4)
            w.write(UInt32(rate & 0xFFFFFF), 24)
        }
    }

    struct AudioSpecificConfig {
        /// First AOT of the config (5 / 29 for explicit hierarchical SBR / PS).
        var signalledObjectType = 0
        /// Core object type (2 = LC for HE-AAC).
        var coreObjectType = 0
        var sampleRate = 0
        var extensionSampleRate: Int?
        var channelConfiguration = 0
        var sbr = false
        var ps = false
        var frameLength = 1024
    }

    fileprivate static func readAudioObjectType(_ r: inout BitReader) -> Int {
        let aot = Int(r.read(5))
        return aot == 31 ? 32 + Int(r.read(6)) : aot
    }

    fileprivate static func readSamplingFrequency(_ r: inout BitReader) -> Int {
        let index = Int(r.read(4))
        if index == 0xF { return Int(r.read(24)) }
        return index < aacSamplingFrequencies.count ? aacSamplingFrequencies[index] : 0
    }

    /// ISO/IEC 14496-3 §1.6.2.1 AudioSpecificConfig: AOT (escape 31),
    /// sampling frequency (escape 0xF), channelConfiguration, explicit
    /// SBR/PS (AOT 5/29), GASpecificConfig frameLengthFlag, and the
    /// backward-compatible sync extensions 0x2B7 (SBR) / 0x548 (PS).
    static func parseAudioSpecificConfig(_ bytes: [UInt8]) -> AudioSpecificConfig? {
        guard bytes.count >= 2 else { return nil }
        var r = BitReader(bytes)
        var c = AudioSpecificConfig()
        c.signalledObjectType = readAudioObjectType(&r)
        c.coreObjectType = c.signalledObjectType
        c.sampleRate = readSamplingFrequency(&r)
        c.channelConfiguration = Int(r.read(4))
        if c.coreObjectType == 5 || c.coreObjectType == 29 {
            c.sbr = true
            c.ps = c.coreObjectType == 29
            c.extensionSampleRate = readSamplingFrequency(&r)
            c.coreObjectType = readAudioObjectType(&r)
            if c.coreObjectType == 22 { r.skip(4) }             // extensionChannelConfiguration
        }
        if [1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23].contains(c.coreObjectType) {
            c.frameLength = r.readBool() ? 960 : 1024           // frameLengthFlag
            if r.readBool() { r.skip(14) }                      // dependsOnCoreCoder → coreCoderDelay
            let extensionFlag = r.readBool()
            if c.channelConfiguration == 0 {
                // program_config_element(): can't be skipped cheaply; the
                // channel count then comes from the track.
                guard !r.overrun, c.sampleRate > 0 else { return nil }
                return c
            }
            if c.coreObjectType == 6 || c.coreObjectType == 20 { r.skip(3) }   // layerNr
            if extensionFlag {
                if c.coreObjectType == 22 { r.skip(16) }        // numOfSubFrame, layer_length
                if [17, 19, 20, 23].contains(c.coreObjectType) { r.skip(3) }   // resilience flags
                r.skip(1)                                       // extensionFlag3
            }
        }
        // Backward-compatible explicit signalling.
        if !c.sbr, r.bitsRemaining >= 16 {
            var probe = r
            if probe.read(11) == 0x2B7 {
                let extensionType = readAudioObjectType(&probe)
                if extensionType == 5, probe.readBool() {
                    c.sbr = true
                    c.extensionSampleRate = readSamplingFrequency(&probe)
                    if probe.bitsRemaining >= 12, probe.read(11) == 0x548, probe.readBool() {
                        c.ps = true
                    }
                }
                if !probe.overrun { r = probe }
            }
        }
        guard c.sampleRate > 0 else { return nil }
        return c
    }

    /// esds FullBox: ES_Descriptor(0x03) { ES_ID 0, flags 0,
    /// DecoderConfigDescriptor(0x04) { OTI, streamType audio, bufferSizeDB,
    /// max/avg bitrate, [DecoderSpecificInfo(0x05)] }, SLConfigDescriptor(0x06) = 2 }.
    fileprivate static func esdsBox(objectTypeIndication: UInt8, decoderSpecificInfo: [UInt8]?,
                                    bufferSizeDB: Int, maxBitrate: Int, avgBitrate: Int) -> Data {
        func descriptor(_ tag: UInt8, _ payload: [UInt8]) -> [UInt8] {
            let n = payload.count
            return [tag, 0x80 | UInt8((n >> 21) & 0x7F), 0x80 | UInt8((n >> 14) & 0x7F), 0x80 | UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)] + payload
        }
        let buffer = UInt32(clamping: bufferSizeDB), maxRate = UInt32(clamping: maxBitrate), avgRate = UInt32(clamping: avgBitrate)
        var config: [UInt8] = [objectTypeIndication, 0x15]       // streamType 5 (audio) << 2 | upStream 0 | reserved 1
        config += [UInt8((buffer >> 16) & 0xFF), UInt8((buffer >> 8) & 0xFF), UInt8(buffer & 0xFF)]
        for v in [maxRate, avgRate] { config += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        if let dsi = decoderSpecificInfo { config += descriptor(0x05, dsi) }
        var es: [UInt8] = [0, 0, 0]                               // ES_ID, flags
        es += descriptor(0x04, config)
        es += descriptor(0x06, [0x02])
        let payload = descriptor(0x03, es)
        return fullBox("esds", version: 0, flags: 0) { $0.bytes(payload) }
    }

    /// Removes a stray ADTS header (sync 0xFFF, layer 0, 7 or 9 bytes) when
    /// it covers exactly this block.
    static func strippingADTSHeader(_ frame: Data) -> Data {
        guard frame.count > 9 else { return frame }
        let s = frame.startIndex
        guard frame[s] == 0xFF, frame[s + 1] & 0xF6 == 0xF0 else { return frame }
        let headerLength = frame[s + 1] & 1 == 1 ? 7 : 9
        let frameLength = (Int(frame[s + 3] & 0x03) << 11) | (Int(frame[s + 4]) << 3) | Int(frame[s + 5] >> 5)
        guard frameLength == frame.count, frameLength > headerLength else { return frame }
        return frame.subdata(in: (s + headerLength)..<frame.endIndex)
    }

    fileprivate static func aacLayoutName(channelConfiguration: Int, channels: Int) -> String {
        switch channelConfiguration {
        case 1: return "1.0"
        case 2: return "2.0"
        case 3: return "3.0"
        case 4: return "4.0"
        case 5: return "5.0"
        case 6: return "5.1"
        case 7, 12, 14: return "7.1"
        case 11: return "6.1"
        case 13: return "22.2"
        default: return genericLayoutName(channels)
        }
    }

    fileprivate static func makeAACPlan(track: MKVTrack, firstFrame: Data) -> Result<RemuxAudioPlan, RemuxUnsupported> {
        guard let ascData = aacAudioSpecificConfig(track: track) else {
            return .failure(RemuxUnsupported("AAC : configuration introuvable"))
        }
        let asc = [UInt8](ascData)
        guard let config = parseAudioSpecificConfig(asc) else {
            return .failure(RemuxUnsupported("AAC : AudioSpecificConfig illisible"))
        }
        switch config.coreObjectType {
        case 2: break
        case 1: return .failure(RemuxUnsupported("AAC Main non décodable par Apple"))
        case 3: return .failure(RemuxUnsupported("AAC SSR non décodable par Apple"))
        case 4: return .failure(RemuxUnsupported("AAC LTP non décodable par Apple"))
        case 42: return .failure(RemuxUnsupported("xHE-AAC (USAC) non pris en charge"))
        default: return .failure(RemuxUnsupported("AAC (type d'objet \(config.coreObjectType)) non pris en charge"))
        }
        let channelsFromConfig: [Int: Int] = [1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 8, 11: 7, 12: 8, 13: 24, 14: 8]
        var channels = channelsFromConfig[config.channelConfiguration] ?? min(max(track.channels, 1), 64)
        // HE-AACv2 (PS) decodes a mono core to stereo.
        if config.ps, channels == 1 { channels = 2 }
        let outRate = safeInt(track.outputSamplingFrequency)
        let implicitSBR = !config.sbr && outRate > 0 && outRate == 2 * config.sampleRate
        let codecs: String
        let profileName: String
        if config.ps {
            codecs = "mp4a.40.29"; profileName = "HE-AACv2"
        } else if config.sbr || implicitSBR {
            codecs = "mp4a.40.5"; profileName = "HE-AAC"
        } else {
            codecs = "mp4a.40.2"; profileName = "AAC-LC"
        }
        let esds = esdsBox(objectTypeIndication: 0x40, decoderSpecificInfo: asc, bufferSizeDB: 768 * max(channels, 1),
                           maxBitrate: 0, avgBitrate: 0)
        let entry = audioSampleEntry("mp4a", channels: channels, sampleSize: 16, sampleRate: config.sampleRate, children: [esds])
        let frameLength = UInt32(config.frameLength)
        return .success(RemuxAudioPlan(
            codec: .aac, sampleEntry: entry, codecsString: codecs, channelsAttribute: String(channels),
            channelCount: channels, timescale: UInt32(config.sampleRate), isAtmos: false,
            summary: "\(profileName) \(config.ps ? "2.0" : aacLayoutName(channelConfiguration: config.channelConfiguration, channels: channels))",
            frameDuration: { _ in frameLength }, nominalFrameDuration: frameLength,
            transform: { strippingADTSHeader($0) }))
    }
}

// MARK: - FLAC, Opus, MPEG audio, ALAC

extension RemuxCodecs {

    fileprivate static func genericLayoutName(_ channels: Int) -> String {
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

    struct FLACStreamInfo {
        var minBlockSize: Int
        var maxBlockSize: Int
        var sampleRate: Int
        var channels: Int
        var bitsPerSample: Int
        /// The 34-byte STREAMINFO body.
        var bytes: [UInt8]
    }

    /// STREAMINFO from a Matroska FLAC CodecPrivate ("fLaC" + metadata blocks,
    /// or the blocks alone).
    static func flacStreamInfo(codecPrivate: Data) -> FLACStreamInfo? {
        var b = [UInt8](codecPrivate)
        if b.count >= 4, b[0] == 0x66, b[1] == 0x4C, b[2] == 0x61, b[3] == 0x43 { b.removeFirst(4) }   // "fLaC"
        var pos = 0
        while pos + 4 <= b.count {
            let type = b[pos] & 0x7F
            let length = be24(b, pos + 1)
            pos += 4
            guard pos + length <= b.count else { return nil }
            if type == 0 {
                guard length >= 34 else { return nil }
                let s = Array(b[pos..<(pos + 34)])
                let rate = Int(s[10]) << 12 | Int(s[11]) << 4 | Int(s[12] >> 4)
                let channels = Int((s[12] >> 1) & 7) + 1
                let bps = (Int(s[12] & 1) << 4 | Int(s[13] >> 4)) + 1
                return FLACStreamInfo(minBlockSize: be16(s, 0), maxBlockSize: be16(s, 2), sampleRate: rate,
                                      channels: channels, bitsPerSample: bps, bytes: s)
            }
            if b[pos - 4] & 0x80 != 0 { break }                 // last-metadata-block
            pos += length
        }
        return nil
    }

    fileprivate static func makeFLACPlan(track: MKVTrack, firstFrame: Data) -> Result<RemuxAudioPlan, RemuxUnsupported> {
        guard let info = flacStreamInfo(codecPrivate: track.codecPrivate) else {
            return .failure(RemuxUnsupported("FLAC : STREAMINFO introuvable"))
        }
        guard info.sampleRate > 0, info.sampleRate <= 384000 else {
            return .failure(RemuxUnsupported("FLAC : fréquence d'échantillonnage invalide"))
        }
        guard info.bitsPerSample <= 24 else {
            return .failure(RemuxUnsupported("FLAC \(info.bitsPerSample) bits non pris en charge"))
        }
        let dfLa = fullBox("dfLa", version: 0, flags: 0) { w in
            w.u8(0x80)                                          // last-metadata-block | STREAMINFO
            w.u24(34)
            w.bytes(info.bytes)
        }
        let entry = audioSampleEntry("fLaC", channels: info.channels, sampleSize: info.bitsPerSample,
                                     sampleRate: info.sampleRate, children: [dfLa])
        let nominal = UInt32(info.maxBlockSize > 0 ? info.maxBlockSize : 4096)
        return .success(RemuxAudioPlan(
            codec: .flac, sampleEntry: entry, codecsString: "fLaC", channelsAttribute: String(info.channels),
            channelCount: info.channels, timescale: UInt32(info.sampleRate), isAtmos: false,
            summary: "FLAC \(genericLayoutName(info.channels)) \(info.bitsPerSample) bits",
            frameDuration: { UInt32(clamping: flacBlockSize($0) ?? Int(nominal)) }, nominalFrameDuration: nominal, transform: nil))
    }

    fileprivate static func makeOpusPlan(track: MKVTrack, firstFrame: Data) -> Result<RemuxAudioPlan, RemuxUnsupported> {
        let b = [UInt8](track.codecPrivate)
        guard b.count >= 19, Array(b[0..<8]) == Array("OpusHead".utf8), b[8] >> 4 == 0 else {
            return .failure(RemuxUnsupported("Opus : OpusHead invalide"))
        }
        let channels = Int(b[9])
        let preSkip = le16(b, 10)
        let inputRate = le32(b, 12)
        let gain = le16(b, 16)
        let family = Int(b[18])
        guard channels >= 1, channels <= 8 else {
            return .failure(RemuxUnsupported("Opus \(channels) canaux non pris en charge"))
        }
        // RFC 7845 §5.1.1: family 0 = mono / stereo, family 1 = Vorbis channel
        // order, 1…8 channels (5.1, 7.1…). Apple's Opus decoder handles both
        // (AVAssetReader decodes every channel of 3.0 / 5.1 / 7.1 fMP4, and
        // AVPlayer plays them over HLS); families 2/3 (ambisonics) and 255
        // (unmapped) have no Apple output layout.
        guard family == 0 || family == 1 else {
            return .failure(RemuxUnsupported("Opus (famille de canaux \(family)) non pris en charge"))
        }
        guard family != 0 || channels <= 2 else { return .failure(RemuxUnsupported("Opus : OpusHead invalide")) }
        var mapping: [UInt8] = []
        if family != 0 {
            guard b.count >= 21 + channels else { return .failure(RemuxUnsupported("Opus : table de canaux incomplète")) }
            mapping = Array(b[19..<(21 + channels)])           // StreamCount, CoupledCount, ChannelMapping[]
            // StreamCount ≥ 1, CoupledCount ≤ StreamCount, every entry a
            // decoded channel (< StreamCount + CoupledCount) or 255 (silence).
            let streams = Int(mapping[0]), coupled = Int(mapping[1])
            guard streams >= 1, coupled <= streams,
                  mapping.dropFirst(2).allSatisfy({ Int($0) < streams + coupled || $0 == 255 }) else {
                return .failure(RemuxUnsupported("Opus : table de canaux invalide"))
            }
        }
        let dOps = box("dOps") { w in
            w.u8(0)                                             // Version
            w.u8(UInt8(channels))                               // OutputChannelCount
            w.u16(UInt16(preSkip))                              // PreSkip
            w.u32(inputRate)                                    // InputSampleRate
            w.u16(UInt16(truncatingIfNeeded: gain))             // OutputGain (s16)
            w.u8(UInt8(family))                                 // ChannelMappingFamily
            w.bytes(mapping)
        }
        // Apple's own layout (AudioFile's MP4 writer, every channel count from
        // mono to 7.1): AudioSampleEntry channelcount = 2 (the ISO BMFF
        // template value), the real count lives in dOps OutputChannelCount.
        let entry = audioSampleEntry("Opus", channels: 2, sampleSize: 16, sampleRate: 48000, children: [dOps])
        return .success(RemuxAudioPlan(
            codec: .opus, sampleEntry: entry, codecsString: "Opus", channelsAttribute: String(channels),
            channelCount: channels, timescale: 48000, isAtmos: false, summary: "Opus \(genericLayoutName(channels))",
            frameDuration: { UInt32(clamping: opusPacketSamples48k($0) ?? 960) }, nominalFrameDuration: 960, transform: nil))
    }

    /// MPEG-1/2/2.5 audio frame header.
    struct MPEGAudioHeader {
        /// 1 = MPEG-1, 2 = MPEG-2, 25 = MPEG-2.5.
        var version: Int
        var layer: Int
        var bitrateKbps: Int
        var sampleRate: Int
        var padding: Int
        var channels: Int
        var samplesPerFrame: Int
        /// nil for free-format streams.
        var frameBytes: Int?

        init?(_ b: [UInt8], at o: Int) {
            guard o + 4 <= b.count, b[o] == 0xFF, b[o + 1] & 0xE0 == 0xE0 else { return nil }
            let versionBits = Int((b[o + 1] >> 3) & 3)
            let layerBits = Int((b[o + 1] >> 1) & 3)
            let bitrateIndex = Int(b[o + 2] >> 4)
            let rateIndex = Int((b[o + 2] >> 2) & 3)
            guard versionBits != 1, layerBits != 0, bitrateIndex != 15, rateIndex != 3 else { return nil }
            version = versionBits == 3 ? 1 : (versionBits == 2 ? 2 : 25)
            layer = 4 - layerBits
            padding = Int((b[o + 2] >> 1) & 1)
            channels = (b[o + 3] >> 6) == 3 ? 1 : 2
            let baseRate = [44100, 48000, 32000][rateIndex]
            sampleRate = version == 1 ? baseRate : (version == 2 ? baseRate / 2 : baseRate / 4)
            let tables: [[Int]]
            if version == 1 {
                tables = [[0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
                          [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
                          [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]]
            } else {
                let l23 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
                tables = [[0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256], l23, l23]
            }
            bitrateKbps = tables[layer - 1][bitrateIndex]
            switch layer {
            case 1: samplesPerFrame = 384
            case 2: samplesPerFrame = 1152
            default: samplesPerFrame = version == 1 ? 1152 : 576
            }
            if bitrateKbps == 0 {
                frameBytes = nil
            } else if layer == 1 {
                frameBytes = (12 * bitrateKbps * 1000 / sampleRate + padding) * 4
            } else {
                frameBytes = (samplesPerFrame / 8) * bitrateKbps * 1000 / sampleRate + padding
            }
        }
    }

    /// HLS CODECS token for MPEG audio: RFC 6381 MPEG-4 audio object types
    /// 34 (Layer III) / 33 (Layer II). AVPlayer rejects the variant ("Cannot
    /// Open", -15517) for the OTI forms "mp4a.6B" / "mp4a.69".
    fileprivate static func mpegAudioCodecsString(layer: Int, version: Int) -> String {
        return layer == 3 ? "mp4a.40.34" : "mp4a.40.33"
    }

    fileprivate static func makeMPEGAudioPlan(track: MKVTrack, firstFrame: Data) -> Result<RemuxAudioPlan, RemuxUnsupported> {
        guard let header = MPEGAudioHeader([UInt8](firstFrame.prefix(4)), at: 0) else {
            return .failure(RemuxUnsupported("MPEG audio : en-tête de trame illisible"))
        }
        guard header.layer == 2 || header.layer == 3 else {
            return .failure(RemuxUnsupported("MPEG-1 Layer I non pris en charge par AVPlayer"))
        }
        // AVFoundation ignores an `mp4a` track whose esds says MPEG-1/2 audio
        // (OTI 0x6B / 0x69: the track isn't even listed) and fails AOT 34; it
        // decodes the QuickTime-style `.mp3` / `.mp2` sample entries.
        let entry = audioSampleEntry(header.layer == 3 ? ".mp3" : ".mp2", channels: header.channels, sampleSize: 16,
                                     sampleRate: header.sampleRate, children: [])
        let nominal = UInt32(header.samplesPerFrame)
        return .success(RemuxAudioPlan(
            codec: .mp3, sampleEntry: entry, codecsString: mpegAudioCodecsString(layer: header.layer, version: header.version),
            channelsAttribute: String(header.channels), channelCount: header.channels,
            timescale: UInt32(header.sampleRate), isAtmos: false,
            summary: "\(header.layer == 3 ? "MP3" : "MP2") \(genericLayoutName(header.channels))",
            frameDuration: { UInt32(clamping: mpegAudioFrameSamples($0) ?? Int(nominal)) }, nominalFrameDuration: nominal, transform: nil))
    }

    /// ALACSpecificConfig (24 bytes) + optional channel layout tag from a
    /// magic cookie: raw config, or wrapped in 'frma' / 'alac' atoms (+ 'chan').
    static func alacCookie(_ codecPrivate: Data) -> (config: [UInt8], channelLayoutTag: UInt32?)? {
        var b = [UInt8](codecPrivate)
        func atomType(_ bytes: [UInt8]) -> String? {
            guard bytes.count >= 8 else { return nil }
            return String(bytes: bytes[4..<8], encoding: .ascii)
        }
        if atomType(b) == "frma" {
            let size = Int(be32(b, 0))
            guard size >= 8, size <= b.count else { return nil }
            b.removeFirst(size)
        }
        if atomType(b) == "alac", b.count >= 12 + 24 {
            b.removeFirst(12)                                   // size, 'alac', version/flags
        }
        guard b.count >= 24 else { return nil }
        let config = Array(b[0..<24])
        var tag: UInt32?
        var pos = 24
        while pos + 8 <= b.count {
            let size = Int(be32(b, pos))
            guard size >= 8, pos + size <= b.count else { break }
            if atomType(Array(b[pos..<(pos + 8)])) == "chan", size >= 16 { tag = be32(b, pos + 12) }
            pos += size
        }
        return (config, tag)
    }

    /// Samples of one ALAC packet: the partial-frame sample count when the
    /// first element header carries one, else `frameLength`.
    static func alacPacketSamples(_ packet: Data, frameLength: Int) -> Int {
        var r = BitReader([UInt8](packet.prefix(8)))
        let tag = r.read(3)
        guard tag == 0 || tag == 1 || tag == 3 else { return frameLength }   // SCE / CPE / LFE
        r.skip(4 + 12)                                          // element instance tag, unused header
        let partial = r.readBool()
        r.skip(3)                                               // bytes shifted, escape flag
        guard partial else { return frameLength }
        let samples = Int(r.read(32))
        return (!r.overrun && samples > 0 && samples <= frameLength) ? samples : frameLength
    }

    fileprivate static func makeALACPlan(track: MKVTrack, firstFrame: Data) -> Result<RemuxAudioPlan, RemuxUnsupported> {
        guard let cookie = alacCookie(track.codecPrivate) else {
            return .failure(RemuxUnsupported("ALAC : configuration introuvable"))
        }
        let c = cookie.config
        let frameLength = Int(be32(c, 0))
        let bitDepth = Int(c[5])
        let channels = Int(c[9])
        let sampleRate = Int(be32(c, 20))
        guard frameLength > 0, frameLength <= 65536, (1...8).contains(channels), [16, 20, 24, 32].contains(bitDepth), sampleRate > 0 else {
            return .failure(RemuxUnsupported("ALAC : configuration invalide"))
        }
        let alacBox = fullBox("alac", version: 0, flags: 0) { $0.bytes(c) }
        var children = [alacBox]
        // ALAC's own default layouts (C L R… order) for > 2 channels.
        let defaultTags: [Int: UInt32] = [3: 114 << 16 | 3, 4: 116 << 16 | 4, 5: 120 << 16 | 5, 6: 124 << 16 | 6,
                                          7: 142 << 16 | 7, 8: 127 << 16 | 8]
        if channels > 2, let tag = cookie.channelLayoutTag ?? defaultTags[channels] {
            children.append(fullBox("chan", version: 0, flags: 0) { w in w.u32(tag); w.u32(0); w.u32(0) })
        }
        let entry = audioSampleEntry("alac", channels: channels, sampleSize: bitDepth, sampleRate: sampleRate, children: children)
        return .success(RemuxAudioPlan(
            codec: .alac, sampleEntry: entry, codecsString: "alac", channelsAttribute: String(channels),
            channelCount: channels, timescale: UInt32(sampleRate), isAtmos: false,
            summary: "ALAC \(genericLayoutName(channels)) \(bitDepth) bits",
            frameDuration: { UInt32(alacPacketSamples($0, frameLength: frameLength)) },
            nominalFrameDuration: UInt32(frameLength), transform: nil))
    }
}
