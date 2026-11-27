import Foundation

// MARK: - Dolby Vision RPU

/// Reader for one Dolby Vision RPU (HEVC `UNSPEC62` NAL unit).
///
/// Only the fields an HDR10+ generator needs are kept: the scene cut flag,
/// L1 (per-shot min / max / average PQ), L6 (static mastering and content
/// light levels) and the source PQ range. The reshaping curves
/// (`rpu_data_mapping`) are walked over bit by bit, because the display
/// management data sits after them and nothing gives their length.
///
/// The syntax follows dovi_tool (`dolby_vision` crate) and FFmpeg's
/// `dovi_rpudec.c`, which agree on every field read here. An RPU is only
/// trusted when its CRC32 matches, and any inconsistency (truncation, out of
/// range value, unsupported layout) gives `nil` / a `Failure`: this code
/// runs on untrusted downloads and must never trap.
///
/// Stateless: the caller keeps whatever must survive from one RPU to the
/// next (the last full L1 and L6 when a compressed DM omits them, and the
/// sequence info when an RPU leaves it out).
enum DolbyVisionRPU {

    // MARK: Results

    /// Level 1 extension block: PQ codes (0…4095) of the current shot.
    struct Level1: Hashable {
        var minPQ: UInt16
        var maxPQ: UInt16
        var avgPQ: UInt16
    }

    /// Level 6 extension block (static). Luminances in cd/m², except
    /// `minDisplayMasteringLuminance`, in 0.0001 cd/m² like the HDR10
    /// mastering display SEI. A 0 means "unknown".
    struct Level6: Hashable {
        var maxDisplayMasteringLuminance: UInt16
        var minDisplayMasteringLuminance: UInt16
        var maxContentLightLevel: UInt16
        var maxFrameAverageLightLevel: UInt16
    }

    /// Which extension-block set a block came from.
    enum CMVersion: Hashable {
        /// First set, always present with the DM data (L1, L2, L4, L5, L6, L255).
        case v29
        /// Optional second set (L3, L8, L9, L10, L11, L254).
        case v40
    }

    /// The part of `rpu_data_header` needed to walk the mapping data. It is
    /// sent when `vdr_seq_info_present_flag` is 1, which every stream seen so
    /// far does on every RPU; a caller can pass the last one back in for an
    /// RPU that leaves it out.
    struct SequenceInfo: Hashable {
        /// 0 = fixed point, 1 = float32.
        var coefficientDataType: UInt8
        /// Fractional bits of a fixed-point coefficient (32 for float32).
        var coefficientLog2Denom: Int
        var blVideoFullRange: Bool
        var blBitDepth: Int
        var elBitDepth: Int
        var vdrBitDepth: Int
        /// `reserved_zero_3bits`: 1 = compressed display management data.
        var dmCompression: UInt8
        var elSpatialResamplingFilter: Bool
        var disableResidual: Bool
    }

    /// What one RPU says.
    struct Metadata: Hashable {
        var rpuFormat: UInt16
        var vdrRPUProfile: UInt8
        var sequenceInfo: SequenceInfo
        /// `use_prev_vdr_rpu_flag`: the reshaping curves are those of an
        /// earlier RPU. Only the mapping is skipped; the DM data below is
        /// still this frame's own.
        var usePrevVDRRPU: Bool
        /// `vdr_dm_metadata_present_flag`. Without DM data there is no
        /// scene flag and no extension block: keep the previous ones.
        var dmPresent: Bool
        /// Compressed DM: the colour block and the static levels (L6…) are
        /// not sent; only dynamic blocks such as L1 are.
        var dmCompressed: Bool
        var affectedDMMetadataID: UInt8
        var currentDMMetadataID: UInt8
        /// `scene_refresh_flag != 0`: first frame of a new shot.
        var sceneRefresh: Bool
        /// From the uncompressed DM colour block; nil when compressed or absent.
        var sourceMinPQ: UInt16?
        var sourceMaxPQ: UInt16?
        /// L1 of this frame, nil when the RPU carries none.
        var level1: Level1?
        var level1Source: CMVersion?
        /// L6 of this frame; always nil in a compressed DM, which never
        /// carries static levels.
        var level6: Level6?
        /// A CM v4.0 extension set was found and parsed.
        var hasCMv40: Bool
    }

    /// Why an RPU was rejected.
    enum Failure: Error, Hashable {
        /// Not an `UNSPEC62` NAL unit with layer 0.
        case notRPU
        case tooShort
        /// First payload byte is not the 0x19 `rpu_nal_prefix`.
        case badPrefix
        /// Last non-zero byte is not the 0x80 terminator.
        case badTerminator
        /// The stored CRC32/MPEG-2 doesn't match the payload: corrupt or
        /// not really an RPU (F12c-like synthetic data). Never trust it.
        case crcMismatch(stored: UInt32, computed: UInt32)
        /// Valid but uses syntax neither reference parser handles.
        case unsupported(String)
        /// Fields out of range or running past the payload.
        case malformed(String)
    }

    // MARK: Finding the RPU in a sample

    /// Range of the RPU NAL unit (2-byte header included, length prefix
    /// excluded) in a length-prefixed HEVC sample, without copying it.
    /// Picks the last `UNSPEC62` unit with nuh_layer_id 0 and TemporalId 0,
    /// as FFmpeg does (the RPU normally ends the access unit). Returns nil
    /// when there is none, or when the length prefixes don't tile the sample.
    static func rpuNALRange(in sample: UnsafeRawBufferPointer, lengthSize: Int) -> Range<Int>? {
        guard (1...4).contains(lengthSize) else { return nil }
        let n = sample.count
        var found: Range<Int>?
        var pos = 0
        while pos < n {
            guard pos + lengthSize <= n else { return nil }
            var length = 0
            for k in 0..<lengthSize { length = length << 8 | Int(sample[pos + k]) }
            let start = pos + lengthSize
            guard length <= n - start else { return nil }
            if length > 2, isRPUHeader(sample[start], sample[start + 1]) {
                found = start..<(start + length)
            }
            pos = start + length
        }
        return found
    }

    /// `Data` flavour of `rpuNALRange(in:lengthSize:)`; the range is in the
    /// sample's own indices, so `sample[range]` is the NAL unit.
    static func rpuNALRange(in sample: Data, lengthSize: Int) -> Range<Data.Index>? {
        let base = sample.startIndex
        let range = sample.withUnsafeBytes { rpuNALRange(in: $0, lengthSize: lengthSize) }
        return range.map { (base + $0.lowerBound)..<(base + $0.upperBound) }
    }

    /// HEVC NAL header of an RPU: type 62, layer 0, TemporalId 0.
    private static func isRPUHeader(_ b0: UInt8, _ b1: UInt8) -> Bool {
        let type = (b0 >> 1) & 0x3F
        let layerID = ((b0 & 1) << 5) | (b1 >> 3)
        let temporalIDPlus1 = b1 & 0x07
        return b0 & 0x80 == 0 && type == 62 && layerID == 0 && temporalIDPlus1 == 1
    }

    // MARK: Parsing

    /// Parses one RPU NAL unit (HEVC header included, emulation prevention
    /// bytes still in). Nil when it can't be trusted; see `parseResult` for
    /// the reason.
    static func parse(nal: UnsafeRawBufferPointer, previousSequence: SequenceInfo? = nil) -> Metadata? {
        try? parseResult(nal: nal, previousSequence: previousSequence).get()
    }

    static func parse(nal: Data, previousSequence: SequenceInfo? = nil) -> Metadata? {
        nal.withUnsafeBytes { parse(nal: $0, previousSequence: previousSequence) }
    }

    static func parseResult(nal: Data, previousSequence: SequenceInfo? = nil) -> Result<Metadata, Failure> {
        nal.withUnsafeBytes { parseResult(nal: $0, previousSequence: previousSequence) }
    }

    static func parseResult(nal: UnsafeRawBufferPointer, previousSequence: SequenceInfo? = nil) -> Result<Metadata, Failure> {
        guard nal.count >= 3 else { return .failure(.tooShort) }
        guard isRPUHeader(nal[0], nal[1]) else { return .failure(.notRPU) }

        // Unescape first: the CRC and every field are defined on the RBSP.
        var bytes = unescaped(nal, from: 2)
        // Trailing zero bytes are padding; the 0x80 terminator ends the RPU.
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        // 0x19 + at least one payload byte + CRC32 + 0x80.
        guard bytes.count >= 7 else { return .failure(.tooShort) }
        guard bytes[0] == 0x19 else { return .failure(.badPrefix) }
        guard bytes[bytes.count - 1] == 0x80 else { return .failure(.badTerminator) }

        // The CRC is located from the end, never from the parse position:
        // some encoders pad one more zero byte before it.
        let crcStart = bytes.count - 5
        let stored = UInt32(bytes[crcStart]) << 24 | UInt32(bytes[crcStart + 1]) << 16
            | UInt32(bytes[crcStart + 2]) << 8 | UInt32(bytes[crcStart + 3])
        let computed = crc32MPEG2(bytes[1..<crcStart])
        guard stored == computed else { return .failure(.crcMismatch(stored: stored, computed: computed)) }

        // Read only up to the CRC, so running into it shows as an overrun.
        bytes.removeLast(5)
        var reader = BitReader(bytes)
        _ = reader.read(8) // rpu_nal_prefix
        do {
            return .success(try parsePayload(&reader, previousSequence: previousSequence))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.malformed("\(error)"))
        }
    }

    /// `rpu_data_header`, `rpu_data_mapping` (skipped) and `vdr_dm_data`.
    private static func parsePayload(_ r: inout BitReader, previousSequence: SequenceInfo?) throws -> Metadata {
        let rpuType = r.read(6)
        guard rpuType == 2 else { throw Failure.unsupported("rpu_type \(rpuType)") }
        let rpuFormat = UInt16(r.read(11))
        let vdrRPUProfile = UInt8(r.read(4))
        _ = r.read(4) // vdr_rpu_level

        let sequence: SequenceInfo
        if r.readBool() { // vdr_seq_info_present_flag
            _ = r.read(1) // chroma_resampling_explicit_filter_flag
            let coefficientDataType = UInt8(r.read(2))
            guard coefficientDataType <= 1 else { throw Failure.malformed("coefficient_data_type \(coefficientDataType)") }
            var log2Denom = 32
            if coefficientDataType == 0 {
                let denom = try ue(&r)
                guard denom <= 32 else { throw Failure.malformed("coefficient_log2_denom \(denom)") }
                log2Denom = Int(denom)
            }
            _ = r.read(2) // vdr_rpu_normalized_idc
            let fullRange = r.readBool()
            // Both reference parsers stop here for any other format: the
            // bit depths below would be absent.
            guard rpuFormat & 0x700 == 0 else { throw Failure.unsupported("rpu_format \(rpuFormat)") }
            let blDepth = try ue(&r)
            // The upper bits carry ext_mapping_idc, not the depth.
            let elDepth = try ue(&r) & 0xFF
            let vdrDepth = try ue(&r)
            guard blDepth <= 8, elDepth <= 8, vdrDepth <= 8 else {
                throw Failure.malformed("bit depths \(blDepth)/\(elDepth)/\(vdrDepth)")
            }
            _ = r.read(1) // spatial_resampling_filter_flag
            let dmCompression = UInt8(r.read(3))
            guard dmCompression <= 1 else { throw Failure.unsupported("dm compression \(dmCompression)") }
            let elSpatial = r.readBool()
            let disableResidual = r.readBool()
            sequence = SequenceInfo(
                coefficientDataType: coefficientDataType, coefficientLog2Denom: log2Denom,
                blVideoFullRange: fullRange, blBitDepth: Int(blDepth) + 8, elBitDepth: Int(elDepth) + 8,
                vdrBitDepth: Int(vdrDepth) + 8, dmCompression: dmCompression,
                elSpatialResamplingFilter: elSpatial, disableResidual: disableResidual)
        } else {
            // Without it the mapping can't be walked; borrow the caller's.
            guard let previousSequence else { throw Failure.unsupported("no sequence info") }
            sequence = previousSequence
        }

        let dmPresent = r.readBool()
        let dmCompressed = sequence.dmCompression == 1
        guard !(dmCompressed && !dmPresent) else { throw Failure.malformed("compressed DM without DM data") }
        let usePrev = r.readBool()
        if usePrev {
            let prevID = try ue(&r)
            guard prevID <= 15 else { throw Failure.malformed("prev_vdr_rpu_id \(prevID)") }
        } else {
            try skipMapping(&r, sequence: sequence)
        }
        try checkBounds(r, "mapping")

        var metadata = Metadata(
            rpuFormat: rpuFormat, vdrRPUProfile: vdrRPUProfile, sequenceInfo: sequence,
            usePrevVDRRPU: usePrev, dmPresent: dmPresent, dmCompressed: dmCompressed,
            affectedDMMetadataID: 0, currentDMMetadataID: 0, sceneRefresh: false,
            sourceMinPQ: nil, sourceMaxPQ: nil, level1: nil, level1Source: nil, level6: nil,
            hasCMv40: false)
        guard dmPresent else { return metadata }

        let affected = try ue(&r)
        let current = try ue(&r)
        guard affected <= 15, current <= 15 else { throw Failure.malformed("dm_metadata_id \(affected)/\(current)") }
        metadata.affectedDMMetadataID = UInt8(affected)
        metadata.currentDMMetadataID = UInt8(current)
        metadata.sceneRefresh = try ue(&r) != 0

        if !dmCompressed {
            // ycc_to_rgb coef 9×16 + offsets 3×32, rgb_to_lms 9×16,
            // signal_eotf + param0 + param1 3×16, param2 32.
            r.skip(9 * 16 + 3 * 32 + 9 * 16 + 3 * 16 + 32)
            let signalBitDepth = r.read(5)
            // Both references reject this; here it also catches a mapping
            // walk that went out of step.
            guard (8...16).contains(signalBitDepth) else { throw Failure.malformed("signal_bit_depth \(signalBitDepth)") }
            r.skip(2 + 2 + 2) // colour space, chroma format, full range
            metadata.sourceMinPQ = UInt16(r.read(12))
            metadata.sourceMaxPQ = UInt16(r.read(12))
            r.skip(10) // source_diagonal
            try checkBounds(r, "DM colour block")
        }

        // CM v2.9 set: always there with the DM data. Its failure means the
        // stream is out of step, so the whole RPU is rejected.
        let v29 = try extensionSet(&r)

        // CM v4.0 set: optional, detected as dovi_tool does (at least 16
        // bits before the CRC; 56 counting the CRC and 0x80). A failure there
        // keeps the CM v2.9 result: L1 and L6 are CM v2.9 levels.
        var v40: ExtensionSet?
        if r.bitsRemaining >= 16 {
            var probe = r
            v40 = try? extensionSet(&probe)
        }
        metadata.hasCMv40 = v40 != nil

        // L1 belongs to the CM v2.9 set (dovi_tool refuses it in CM v4.0,
        // FFmpeg's v4.0 parser doesn't know it). A CM v4.0 L1 is only a
        // fallback for a non-conforming stream that moved it there.
        if let level1 = v29.level1 {
            metadata.level1 = level1
            metadata.level1Source = .v29
        } else if let level1 = v40?.level1 {
            metadata.level1 = level1
            metadata.level1Source = .v40
        }
        // L6 is a static level: only an uncompressed RPU sends it. One found
        // in a compressed RPU is ignored, as FFmpeg does (it warns and drops
        // static blocks there); the caller keeps the last uncompressed one.
        if !dmCompressed {
            metadata.level6 = v29.level6 ?? v40?.level6
        }
        return metadata
    }

    /// Walks `rpu_data_mapping` (and `rpu_data_nlq`) without keeping it.
    private static func skipMapping(_ r: inout BitReader, sequence: SequenceInfo) throws {
        let rpuID = try ue(&r)
        guard rpuID <= 15 else { throw Failure.malformed("vdr_rpu_id \(rpuID)") }
        _ = try ue(&r) // mapping_color_space
        _ = try ue(&r) // mapping_chroma_format_idc

        var pieces: [Int] = []
        for _ in 0..<3 {
            let pivotsMinus2 = try ue(&r)
            guard pivotsMinus2 <= 7 else { throw Failure.malformed("num_pivots_minus2 \(pivotsMinus2)") }
            r.skip((Int(pivotsMinus2) + 2) * sequence.blBitDepth)
            pieces.append(Int(pivotsMinus2) + 1)
        }
        // rpu_format & 0x700 == 0 is checked with the header, so the
        // residual (NLQ, profile 7 only) depends on this flag alone.
        let useNLQ = !sequence.disableResidual
        if useNLQ {
            let method = r.read(3)
            guard method == 0 else { throw Failure.unsupported("nlq_method_idc \(method)") }
            r.skip(2 * sequence.blBitDepth)
        }
        // Both references read a single set of curves whatever these say;
        // more than one partition would put the reader out of step.
        let xPartitions = try ue(&r)
        let yPartitions = try ue(&r)
        guard xPartitions == 0, yPartitions == 0 else { throw Failure.unsupported("partitions") }
        try checkBounds(r, "pivots")

        for component in 0..<3 {
            for _ in 0..<pieces[component] {
                switch try ue(&r) {
                case 0: // polynomial
                    let orderMinus1 = try ue(&r)
                    guard orderMinus1 <= 1 else { throw Failure.malformed("poly_order_minus1 \(orderMinus1)") }
                    if orderMinus1 == 0, r.readBool() {
                        throw Failure.unsupported("linear_interp_flag")
                    }
                    for _ in 0..<(Int(orderMinus1) + 2) { try skipCoefficient(&r, sequence: sequence, signed: true) }
                case 1: // MMR
                    let orderMinus1 = Int(r.read(2))
                    guard orderMinus1 <= 2 else { throw Failure.malformed("mmr_order_minus1 \(orderMinus1)") }
                    try skipCoefficient(&r, sequence: sequence, signed: true) // mmr_constant
                    for _ in 0..<((orderMinus1 + 1) * 7) { try skipCoefficient(&r, sequence: sequence, signed: true) }
                case let idc:
                    throw Failure.malformed("mapping_idc \(idc)")
                }
                try checkBounds(r, "curves")
            }
        }

        if useNLQ {
            for _ in 0..<3 {
                r.skip(sequence.elBitDepth) // nlq_offset
                // vdr_in_max, linear_deadzone_slope, linear_deadzone_threshold
                for _ in 0..<3 { try skipCoefficient(&r, sequence: sequence, signed: false) }
            }
        }
    }

    /// One mapping coefficient: Exp-Golomb integer part plus a fixed-point
    /// fraction, or a raw float32.
    private static func skipCoefficient(_ r: inout BitReader, sequence: SequenceInfo, signed: Bool) throws {
        if sequence.coefficientDataType == 0 {
            if signed { _ = try se(&r) } else { _ = try ue(&r) }
            r.skip(sequence.coefficientLog2Denom)
        } else {
            r.skip(32)
        }
    }

    private struct ExtensionSet {
        var level1: Level1?
        var level6: Level6?
    }

    /// One extension-block set: count, alignment, then blocks of
    /// `ext_block_length` bytes each. Blocks are not byte-aligned, so every
    /// block is skipped by its declared length whatever its level (as FFmpeg
    /// does): unknown levels and longer future layouts pass untouched.
    private static func extensionSet(_ r: inout BitReader) throws -> ExtensionSet {
        let count = try ue(&r)
        // dovi_tool allows 13 (CM v2.9) and 14 (CM v4.0); leave headroom.
        guard count <= 32 else { throw Failure.malformed("num_ext_blocks \(count)") }
        r.byteAlign() // dm_alignment_zero_bit
        var set = ExtensionSet()
        for _ in 0..<count {
            let lengthBytes = try ue(&r)
            let level = r.read(8)
            try checkBounds(r, "extension block header")
            let lengthBits = Int(lengthBytes) * 8
            guard lengthBits <= r.bitsRemaining else { throw Failure.malformed("ext block L\(level) length \(lengthBytes)") }
            let end = r.bitPosition + lengthBits
            switch level {
            case 1 where lengthBytes >= 5 && set.level1 == nil:
                set.level1 = Level1(minPQ: UInt16(r.read(12)), maxPQ: UInt16(r.read(12)), avgPQ: UInt16(r.read(12)))
            case 6 where lengthBytes >= 8 && set.level6 == nil:
                set.level6 = Level6(
                    maxDisplayMasteringLuminance: UInt16(r.read(16)),
                    minDisplayMasteringLuminance: UInt16(r.read(16)),
                    maxContentLightLevel: UInt16(r.read(16)),
                    maxFrameAverageLightLevel: UInt16(r.read(16)))
            default:
                break
            }
            // The fields read above always fit in the declared length.
            r.skip(end - r.bitPosition)
            try checkBounds(r, "extension block L\(level)")
        }
        return set
    }

    // MARK: Helpers

    private static func checkBounds(_ r: BitReader, _ context: String) throws {
        if r.overrun { throw Failure.malformed("truncated in \(context)") }
    }

    /// ue(v) that fails instead of returning 0 on a run of more than 31
    /// zero bits or on the end of the data (`BitReader.readUE` is lenient).
    private static func ue(_ r: inout BitReader) throws -> UInt32 {
        var leadingZeros = 0
        while !r.readBool() {
            leadingZeros += 1
            guard leadingZeros <= 31, !r.overrun else { throw Failure.malformed("Exp-Golomb code") }
        }
        guard !r.overrun else { throw Failure.malformed("Exp-Golomb code") }
        guard leadingZeros > 0 else { return 0 }
        let suffix = r.read64(leadingZeros)
        guard !r.overrun else { throw Failure.malformed("Exp-Golomb code") }
        return UInt32(clamping: (UInt64(1) << UInt64(leadingZeros)) - 1 + suffix)
    }

    private static func se(_ r: inout BitReader) throws -> Int32 {
        let k = try ue(&r)
        if k & 1 == 1 { return Int32(clamping: (Int64(k) + 1) / 2) }
        return -Int32(clamping: Int64(k) / 2)
    }

    /// RBSP from `start`: drops each emulation_prevention_three_byte
    /// (00 00 03 → 00 00).
    private static func unescaped(_ nal: UnsafeRawBufferPointer, from start: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(max(0, nal.count - start))
        var zeros = 0
        var i = start
        while i < nal.count {
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

    /// CRC-32/MPEG-2 (poly 0x04C11DB7, init 0xFFFFFFFF, no reflection, no
    /// final XOR), the RPU checksum. check("123456789") = 0x0376E6E7.
    static func crc32MPEG2<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = (crc << 8) ^ crcTable[Int(UInt8(truncatingIfNeeded: crc >> 24) ^ byte)]
        }
        return crc
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index) << 24
        for _ in 0..<8 {
            value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1
        }
        return value
    }

    /// Absolute luminance (cd/m²) of a 12-bit PQ code (SMPTE ST 2084), the
    /// unit of L1 and of `source_min_pq` / `source_max_pq`.
    static func nits(fromPQ code: UInt16) -> Double {
        let m1 = 2610.0 / 16384.0
        let m2 = 2523.0 / 4096.0 * 128.0
        let c1 = 3424.0 / 4096.0
        let c2 = 2413.0 / 4096.0 * 32.0
        let c3 = 2392.0 / 4096.0 * 32.0
        let e = pow(Double(min(code, 4095)) / 4095.0, 1.0 / m2)
        return 10000.0 * pow(max(e - c1, 0) / (c2 - c3 * e), 1.0 / m1)
    }
}
