import Foundation

// HDR10+ (SMPTE ST 2094-40, application 4, version 1) for the remux engine:
// the metadata itself, its prefix SEI NAL unit (writer and reader), and the
// mapping that turns a Dolby Vision 8.1 RPU's L1 (and L6) levels into it.
//
// Why a mapping at all: a Dolby Vision 8.1 file carries an HDR10 base layer
// plus per-shot RPU metadata. A TV without Dolby Vision only gets the static
// HDR10 brightness, while an HDR10+ TV can follow the scene if the stream
// carries ST 2094-40 data. No public DV → HDR10+ algorithm exists, so the one
// below is a documented heuristic: statistics derived from L1 (min / avg / max
// PQ codes), a Profile B tone curve that is the identity (Samsung's "bypass")
// when the scene fits the target display, and a knee + Bezier roll-off
// otherwise.
//
// Specs and references followed: SMPTE ST 2094-40:2020 (§8.3-8.7), the
// ITU-T T.35 header of HDR10+ (country 0xB5, provider 0x003C, oriented code
// 0x0001, application 4), FFmpeg's `av_dynamic_hdr_plus_to_t35` /
// `av_dynamic_hdr_plus_from_t35` (bit widths and order), hdr10plus_tool's
// validator (version 1, one window, the 9-entry percentile index list,
// Profile A / B), ITU-T H.265 §7.3.5 (sei_message) and §7.4.2 (emulation
// prevention). Pure Foundation.

/// HDR10+ metadata, its SEI NAL unit and the Dolby Vision → HDR10+ mapping.
enum RemuxHDR10Plus {

    /// The percentage index list of ApplicationVersion 1 (ST 2094-40 §8.5): 99 stands
    /// for 99.98 %, and the 5 % and 10 % slots are not part of the distribution.
    static let percentageIndexes = [1, 5, 10, 25, 50, 75, 90, 95, 99]

    /// The value of the 10 % slot when the index list is `percentageIndexes`
    /// (ST 2094-40 §8.5: V2 = 0.00255, not a statistic).
    static let tenPercentSlotValue = 255

    /// Target display of the generated curve, cd/m². 400 is what real HDR10+ streams
    /// carry (FFmpeg's FATE sample, Samsung's authoring preview level).
    static let defaultTargetDisplayNits = 400

    /// Bezier anchors of the identity curve with 9 anchors (P_i = i/10, the bypass a
    /// Samsung-authored stream carries when the scene fits the target display):
    /// round(1024 · i / 10), capped at 1023.
    static let bypassAnchors: [Int] = (1...9).map { min(1023, Int((1024.0 * Double($0) / 10).rounded())) }

    /// ITU-T T.35 header of an HDR10+ message: country, terminal provider,
    /// provider-oriented code and application identifier (the version byte follows).
    static let t35Header: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]

    /// NAL unit header of the generated SEI: prefix SEI (type 39), layer 0,
    /// TemporalId 0 — the base layer every picture of an 8.1 stream is in.
    static let nalHeader: [UInt8] = [0x4E, 0x01]
}

// MARK: - Metadata

extension RemuxHDR10Plus {

    /// ST 2094-40 metadata of one processing window (the whole picture).
    ///
    /// Units are the bitstream's own: `maxscl`, `averageMaxRGB` and the distribution
    /// values are linear light in 0.00001 of 10000 cd/m² (raw = cd/m² × 10, 0…100000);
    /// the target display luminance is whole cd/m²; knee points are /4095, anchors /1023,
    /// `fractionBrightPixels` /1000 (0 = not calculated).
    struct Metadata: Equatable {

        /// One entry of the maxRGB distribution: an integer percentage and its value.
        struct Percentile: Equatable {
            var percentage: Int
            var value: Int
        }

        /// The Bezier tone curve (tone_mapping_flag = 1).
        struct ToneMapping: Equatable {
            var kneePointX: Int
            var kneePointY: Int
            var anchors: [Int]
        }

        /// hdr10plus_tool's classification: A = statistics only (no curve, target 0),
        /// B = a curve for a non-zero target display.
        enum Profile: Equatable {
            case a
            case b
            case unknown
        }

        var applicationVersion = 1
        var targetedSystemDisplayMaximumLuminance = 0
        /// MaxSCL of R, G, B.
        var maxscl = [0, 0, 0]
        var averageMaxRGB = 0
        var distribution: [Percentile] = []
        var fractionBrightPixels = 0
        /// nil: tone_mapping_flag = 0.
        var toneMapping: ToneMapping?
        /// nil: color_saturation_mapping_flag = 0 (the only value version 1 allows).
        var colorSaturationWeight: Int?

        /// Read side only — the writer always writes one window and no actual-peak
        /// grids (version 1 allows nothing else). A parsed stream that declares more
        /// windows keeps the first one (the whole picture) here.
        var windowCount = 1
        var hasTargetedDisplayActualPeakLuminance = false
        var hasMasteringDisplayActualPeakLuminance = false

        var profile: Profile {
            if let toneMapping, !toneMapping.anchors.isEmpty, targetedSystemDisplayMaximumLuminance > 0 { return .b }
            if toneMapping == nil, targetedSystemDisplayMaximumLuminance == 0 { return .a }
            return .unknown
        }

        /// Every rule a generated set must keep (empty when it keeps them all).
        ///
        /// ST 2094-40 version 1 and hdr10plus_tool's validator: application version 1, one
        /// window, no actual-peak grids, no saturation mapping, the 9-entry index list with
        /// V2 = 255, every statistic within 0…100000, the target display within 0…10000
        /// and non-zero exactly when a curve is sent, at most 9 anchors of 10 bits. On top
        /// of that, internal consistency (no source says a TV rejects inconsistent data;
        /// this is a precaution): the distribution — the 1 % slot and 25 %…99.98 %, the
        /// 5 % / 10 % slots being outside it — never decreases, max(MaxSCL) equals its last
        /// value so both readings of the curve's s = 1 agree (§8.7), the average stays at
        /// or below it, it is never 0 (MaxSCL 0 means « not calculated »), and the curve's
        /// anchors never decrease.
        var consistencyViolations: [String] {
            var issues: [String] = []
            if applicationVersion != 1 { issues.append("application_version \(applicationVersion) ≠ 1") }
            if windowCount != 1 { issues.append("num_windows \(windowCount) ≠ 1") }
            if hasTargetedDisplayActualPeakLuminance { issues.append("targeted display actual peak flag set") }
            if hasMasteringDisplayActualPeakLuminance { issues.append("mastering display actual peak flag set") }
            if colorSaturationWeight != nil { issues.append("color_saturation_mapping_flag set") }
            if !(0...10000).contains(targetedSystemDisplayMaximumLuminance) {
                issues.append("targeted_system_display_maximum_luminance \(targetedSystemDisplayMaximumLuminance) out of 0…10000")
            }
            if (targetedSystemDisplayMaximumLuminance > 0) != (toneMapping != nil) {
                issues.append("target display \(targetedSystemDisplayMaximumLuminance) with tone_mapping_flag \(toneMapping != nil ? 1 : 0)")
            }
            if maxscl.count != 3 { issues.append("\(maxscl.count) MaxSCL values") }
            for value in maxscl + [averageMaxRGB] + distribution.map(\.value) where !(0...100000).contains(value) {
                issues.append("statistic \(value) out of 0…100000")
            }
            if distribution.map(\.percentage) != RemuxHDR10Plus.percentageIndexes {
                issues.append("percentage indexes \(distribution.map(\.percentage))")
            } else {
                if distribution[2].value != RemuxHDR10Plus.tenPercentSlotValue { issues.append("10 % slot \(distribution[2].value) ≠ 255") }
                let cumulative = [0, 3, 4, 5, 6, 7, 8].map { distribution[$0].value }
                if zip(cumulative, cumulative.dropFirst()).contains(where: { $0 > $1 }) {
                    issues.append("distribution decreases: \(cumulative)")
                }
                let last = distribution[8].value
                if last < 1 { issues.append("99.98 % value 0") }
                if maxscl.max() != last { issues.append("max(MaxSCL) \(maxscl.max() ?? -1) ≠ 99.98 % value \(last)") }
                if averageMaxRGB > last { issues.append("average_maxrgb \(averageMaxRGB) > 99.98 % value \(last)") }
            }
            if !(0...1000).contains(fractionBrightPixels) { issues.append("fraction_bright_pixels \(fractionBrightPixels)") }
            if let toneMapping {
                if !(0...4095).contains(toneMapping.kneePointX) || !(0...4095).contains(toneMapping.kneePointY) {
                    issues.append("knee (\(toneMapping.kneePointX), \(toneMapping.kneePointY)) out of 0…4095")
                }
                if !(1...9).contains(toneMapping.anchors.count) { issues.append("\(toneMapping.anchors.count) Bezier anchors") }
                if toneMapping.anchors.contains(where: { !(0...1023).contains($0) }) { issues.append("anchor out of 0…1023") }
                if zip(toneMapping.anchors, toneMapping.anchors.dropFirst()).contains(where: { $0 > $1 }) {
                    issues.append("anchors decrease: \(toneMapping.anchors)")
                }
            }
            return issues
        }
    }
}

// MARK: - PQ (SMPTE ST 2084)

extension RemuxHDR10Plus {

    private static let m1 = 2610.0 / 16384
    private static let m2 = 2523.0 / 4096 * 128
    private static let c1 = 3424.0 / 4096
    private static let c2 = 2413.0 / 4096 * 32
    private static let c3 = 2392.0 / 4096 * 32

    /// ST 2084 EOTF: a normalised PQ value (0…1) to cd/m² (0…10000).
    static func nits(pq value: Double) -> Double {
        guard value > 0 else { return 0 }
        let x = pow(min(value, 1), 1 / m2)
        return 10000 * pow(max(x - c1, 0) / (c2 - c3 * x), 1 / m1)
    }

    /// cd/m² of a 12-bit PQ code (Dolby Vision L1 / L6 PQ fields, code / 4095).
    static func nits(pqCode code: Int) -> Double {
        nits(pq: Double(min(max(code, 0), 4095)) / 4095)
    }

    /// ST 2084 inverse EOTF: cd/m² (0…10000) to a normalised PQ value (0…1).
    static func pq(nits value: Double) -> Double {
        guard value > 0 else { return 0 }
        let y = pow(min(value, 10000) / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    /// cd/m² to the 17-bit statistic unit (0.1 cd/m²), clamped to the field's range.
    static func rawStatistic(nits value: Double) -> Int {
        min(max(Int((value * 10).rounded()), 0), 100000)
    }
}

// MARK: - Dolby Vision → HDR10+ mapping

extension RemuxHDR10Plus {

    /// What the mapping reads from one Dolby Vision RPU — also the cache key: the
    /// output depends on nothing else, so a shot (whose RPUs repeat the same L1) maps
    /// to one SEI computed once.
    struct Levels: Hashable {
        /// L1 min_pq, avg_pq, max_pq: 12-bit PQ codes (0…4095) over the shot's
        /// reduced pixel set. avg is a mean of PQ-coded maxRGB, not of linear light.
        var minPQ: Int
        var avgPQ: Int
        var maxPQ: Int
        /// L6 MaxCLL, cd/m²; 0 = unknown.
        var maxContentLightLevel = 0
        /// L6 max_display_mastering_luminance, cd/m²; 0 = unknown.
        var masteringDisplayPeak = 0
        /// The RPU's source_max_pq (12-bit PQ code, the mastering display's peak):
        /// the mastering bound when `masteringDisplayPeak` is 0 (CM v2.9 streams
        /// often send no L6). Kept as a code so it bounds L1 max exactly; 0 = unknown.
        var sourceMaxPQ = 0
        /// Target display of the curve (TSDML), cd/m².
        var targetDisplayNits = RemuxHDR10Plus.defaultTargetDisplayNits
    }

    /// The HDR10+ metadata of one RPU's levels (Profile B, one window, version 1).
    ///
    /// - Scene peak: L1 max in cd/m², no higher than MaxCLL or the mastering peak when
    ///   L6 gives them, the mastering peak being source_max_pq when L6 doesn't (L1 max
    ///   is measured on 2×2-averaged pixels, the static values bound the content;
    ///   mapping.md §3 pitfall 2), and at least 0.1 cd/m² so a black shot never sends MaxSCL 0
    ///   (« not calculated »). Average and minimum are kept at or below it, so inputs
    ///   out of order (avg > max, min > avg) still give an ordered set.
    /// - MaxSCL R = G = B = the peak; average_maxrgb = L1 avg converted as is (the exact
    ///   inverse of dovi_tool's HDR10+ → L1, though it reads a PQ-domain mean as a
    ///   linear one); fraction_bright_pixels 0 (« not calculated »: it needs pixels).
    /// - Distribution: DV has no histogram, so it is interpolated in the PQ domain between
    ///   min, avg and max (1 % near min, 50 % = avg, 99.98 % = peak). The 5 % slot carries
    ///   the peak too (the 99.99 % reading libplacebo and real streams give it), the 10 %
    ///   slot the spec's constant 255.
    /// - Curve: a scene that fits the target display gets the identity (knee 0, anchors
    ///   i/10); a brighter one keeps shadows and mid-tones on the identity line up to a
    ///   knee near the average, then rolls off with a Bezier whose first anchor matches
    ///   the slope at the knee (ST 2094-40 §8.7 note), raised to degree 10 so it always
    ///   sends 9 anchors.
    static func metadata(for levels: Levels) -> Metadata {
        var peak = nits(pqCode: levels.maxPQ)
        if levels.maxContentLightLevel > 0 { peak = min(peak, Double(levels.maxContentLightLevel)) }
        if levels.masteringDisplayPeak > 0 {
            peak = min(peak, Double(levels.masteringDisplayPeak))
        } else if levels.sourceMaxPQ > 0 {
            peak = min(peak, nits(pqCode: levels.sourceMaxPQ))
        }
        peak = max(peak, 0.1)
        let average = min(nits(pqCode: levels.avgPQ), peak)
        let minimum = min(nits(pqCode: levels.minPQ), average)

        let pqMin = pq(nits: minimum), pqAverage = pq(nits: average), pqPeak = pq(nits: peak)
        func below(_ fraction: Double) -> Int { rawStatistic(nits: nits(pq: pqMin + fraction * (pqAverage - pqMin))) }
        func above(_ fraction: Double) -> Int { rawStatistic(nits: nits(pq: pqAverage + fraction * (pqPeak - pqAverage))) }
        let peakRaw = rawStatistic(nits: peak)
        var values = [below(0.10), peakRaw, tenPercentSlotValue, below(0.70), rawStatistic(nits: average),
                      above(0.20), above(0.45), above(0.60), peakRaw]
        // The distribution (1 % then 25 %…99.98 %) never decreases and ends on the peak;
        // the interpolation already orders it, this only absorbs rounding.
        var floor = 0
        for index in [0, 3, 4, 5, 6, 7, 8] {
            values[index] = min(max(values[index], floor), peakRaw)
            floor = values[index]
        }

        let target = min(max(levels.targetDisplayNits, 1), 10000)
        var metadata = Metadata()
        metadata.targetedSystemDisplayMaximumLuminance = target
        metadata.maxscl = [peakRaw, peakRaw, peakRaw]
        metadata.averageMaxRGB = min(rawStatistic(nits: average), peakRaw)
        metadata.distribution = zip(percentageIndexes, values).map { Metadata.Percentile(percentage: $0, value: $1) }
        metadata.toneMapping = toneCurve(peak: peak, average: average, target: Double(target))
        return metadata
    }

    /// The Profile B curve of a scene: identity when the peak fits the target display,
    /// else a knee on the identity line and a slope-matched Bezier roll-off.
    static func toneCurve(peak: Double, average: Double, target: Double) -> Metadata.ToneMapping {
        guard peak > target else { return Metadata.ToneMapping(kneePointX: 0, kneePointY: 0, anchors: bypassAnchors) }
        // Knee at the average (nits in = nits out), kept within 5 %…50 % of the target and
        // under half the peak, so the roll-off always has room.
        let knee = min(max(average, 0.05 * target), 0.5 * target, 0.5 * peak)
        let kneeX = knee / peak, kneeY = knee / target
        // Slope the Bezier must start with (in its normalised segment) to continue the
        // linear part: B'(0) = N·P1 = (K_F / K_s)·(1 − K_s)/(1 − K_F).
        let slope = (peak - knee) / (target - knee)
        let degree = min(max(Int(slope.rounded(.up)), 2), 10)
        var points = [0, min(slope / Double(degree), 1)] + [Double](repeating: 1, count: degree - 1)
        // Degree elevation keeps the same curve and keeps the points non-decreasing.
        while points.count < 11 { points = elevated(points) }
        let anchors = points[1...9].map { min(max(Int(($0 * 1023).rounded()), 0), 1023) }
        return Metadata.ToneMapping(kneePointX: Int((kneeX * 4095).rounded()),
                                    kneePointY: Int((kneeY * 4095).rounded()),
                                    anchors: anchors)
    }

    /// Bernstein degree elevation n → n + 1:
    /// Q_0 = P_0, Q_i = i/(n+1)·P_(i−1) + (1 − i/(n+1))·P_i, Q_(n+1) = P_n.
    static func elevated(_ points: [Double]) -> [Double] {
        let n = points.count - 1
        guard n >= 0 else { return points }
        var raised = [points[0]]
        if n >= 1 {
            for i in 1...n {
                let t = Double(i) / Double(n + 1)
                raised.append(t * points[i - 1] + (1 - t) * points[i])
            }
        }
        raised.append(points[n])
        return raised
    }

    /// The curve of `toneMapping` at s (normalised scene light, 1 = the peak) in
    /// normalised target light (1 = the target display), as ST 2094-40 §8.7 defines it.
    static func evaluate(_ toneMapping: Metadata.ToneMapping, at s: Double) -> Double {
        let kneeX = Double(toneMapping.kneePointX) / 4095
        let kneeY = Double(toneMapping.kneePointY) / 4095
        if s < kneeX { return kneeX > 0 ? kneeY / kneeX * s : 0 }
        let points = [0] + toneMapping.anchors.map { Double($0) / 1023 } + [1]
        let degree = points.count - 1
        let t = kneeX < 1 ? min(max((s - kneeX) / (1 - kneeX), 0), 1) : 1
        var value = 0.0
        var binomial = 1.0
        for k in 0...degree {
            if k > 0 { binomial = binomial * Double(degree - k + 1) / Double(k) }
            value += binomial * pow(t, Double(k)) * pow(1 - t, Double(degree - k)) * points[k]
        }
        return kneeY + (1 - kneeY) * value
    }
}

// MARK: - Writer

extension RemuxHDR10Plus {

    /// The SEI payload: T.35 header, application version, then the ST 2094-40 fields
    /// (FFmpeg's widths and order), zero-padded to a byte boundary. One window and no
    /// actual-peak grids, whatever the read-side fields say; values are clamped to
    /// their field widths.
    static func t35Payload(_ metadata: Metadata) -> [UInt8] {
        var writer = HDR10PlusBitWriter()
        for byte in t35Header { writer.write(Int(byte), 8) }
        writer.write(metadata.applicationVersion, 8)
        writer.write(1, 2)                                                   // num_windows
        writer.write(metadata.targetedSystemDisplayMaximumLuminance, 27)
        writer.write(0, 1)                                                   // targeted actual peak flag
        for index in 0..<3 { writer.write(index < metadata.maxscl.count ? metadata.maxscl[index] : 0, 17) }
        writer.write(metadata.averageMaxRGB, 17)
        let distribution = metadata.distribution.prefix(15)
        writer.write(distribution.count, 4)
        for entry in distribution {
            writer.write(entry.percentage, 7)
            writer.write(entry.value, 17)
        }
        writer.write(metadata.fractionBrightPixels, 10)
        writer.write(0, 1)                                                   // mastering actual peak flag
        if let toneMapping = metadata.toneMapping {
            writer.write(1, 1)
            writer.write(toneMapping.kneePointX, 12)
            writer.write(toneMapping.kneePointY, 12)
            let anchors = toneMapping.anchors.prefix(15)
            writer.write(anchors.count, 4)
            for anchor in anchors { writer.write(anchor, 10) }
        } else {
            writer.write(0, 1)
        }
        if let weight = metadata.colorSaturationWeight {
            writer.write(1, 1)
            writer.write(weight, 6)
        } else {
            writer.write(0, 1)
        }
        return writer.finish()
    }

    /// The complete prefix SEI NAL unit (header 4E 01, one user_data_registered_itu_t_t35
    /// message, rbsp trailing bits), with emulation prevention, WITHOUT a length prefix
    /// or start code — the caller adds its stream's NAL length field.
    static func seiNAL(_ metadata: Metadata) -> [UInt8] {
        let payload = t35Payload(metadata)
        var raw = nalHeader
        func ffCoded(_ value: Int) {
            var rest = value
            while rest >= 255 { raw.append(0xFF); rest -= 255 }
            raw.append(UInt8(rest))
        }
        ffCoded(4)                                                           // user_data_registered_itu_t_t35
        ffCoded(payload.count)
        raw += payload
        raw.append(0x80)                                                     // rbsp_trailing_bits
        return escapingEmulation(raw)
    }

    /// The SEI NAL unit of one RPU's levels.
    static func seiNAL(for levels: Levels) -> [UInt8] {
        seiNAL(metadata(for: levels))
    }

    /// H.265 §7.4.2: an emulation_prevention_three_byte after every 0x0000 followed by a
    /// byte ≤ 0x03 (the zero count restarts after it). Generated payloads can hit it:
    /// small statistics are long runs of zero bits (a MaxSCL that is a multiple of 256
    /// followed by a dim average gives 00 00 03 03).
    static func escapingEmulation(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 16 + 1)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte <= 0x03 {
                out.append(0x03)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// The inverse: drops every emulation_prevention_three_byte (0x0000 03 → 0x0000).
    static func removingEmulation(_ bytes: [UInt8], from start: Int = 0) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(max(0, bytes.count - start))
        var zeros = 0
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if zeros >= 2, byte == 0x03 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}

// MARK: - Reader

extension RemuxHDR10Plus {

    /// The HDR10+ metadata of an SEI NAL unit (escaped, 2-byte header, no length
    /// prefix): the first registered ITU-T T.35 message (type 4) with the HDR10+ header
    /// that parses. nil when the unit is not an SEI, holds no such message, or is
    /// truncated. Other messages around it are skipped, so it also reads a file's own
    /// SEI units (x265 puts several messages in one).
    static func parse(seiNAL nal: [UInt8]) -> Metadata? {
        guard nal.count > 2 else { return nil }
        let type = (nal[0] >> 1) & 0x3F
        guard type == 39 || type == 40 else { return nil }
        let rbsp = removingEmulation(nal, from: 2)
        var position = 0
        while position < rbsp.count {
            // rbsp_trailing_bits: a lone 0x80 followed only by zero bytes.
            if rbsp[position] == 0x80, rbsp[(position + 1)...].allSatisfy({ $0 == 0 }) { return nil }
            var payloadType = 0
            while position < rbsp.count, rbsp[position] == 0xFF { payloadType += 255; position += 1 }
            guard position < rbsp.count else { return nil }
            payloadType += Int(rbsp[position]); position += 1
            var payloadSize = 0
            while position < rbsp.count, rbsp[position] == 0xFF { payloadSize += 255; position += 1 }
            guard position < rbsp.count else { return nil }
            payloadSize += Int(rbsp[position]); position += 1
            guard payloadSize <= rbsp.count - position else { return nil }
            if payloadType == 4, let metadata = parse(t35Payload: Array(rbsp[position..<(position + payloadSize)])) {
                return metadata
            }
            position += payloadSize
        }
        return nil
    }

    /// The HDR10+ metadata of a T.35 payload (starting with the 0xB5 country code — also
    /// the form of CoreMedia's HDR10PlusPerFrameData). Tolerant of what real streams
    /// carry beyond version 1 (any application version, up to 3 windows, actual-peak
    /// grids, a saturation weight); only the first window is kept. nil when the header
    /// is not HDR10+'s, num_windows is 0 or a field runs past the end.
    static func parse(t35Payload payload: [UInt8]) -> Metadata? {
        guard payload.starts(with: t35Header) else { return nil }
        var reader = HDR10PlusBitReader(payload, fromByte: t35Header.count)
        var metadata = Metadata()
        do {
            metadata.applicationVersion = try reader.read(8)
            metadata.windowCount = try reader.read(2)
            guard metadata.windowCount >= 1 else { return nil }
            // Extra windows' geometry: 6 × 16 + 8 + 3 × 16 + 1 bits each.
            for _ in 1..<metadata.windowCount { try reader.skip(153) }
            metadata.targetedSystemDisplayMaximumLuminance = try reader.read(27)
            metadata.hasTargetedDisplayActualPeakLuminance = try reader.read(1) == 1
            if metadata.hasTargetedDisplayActualPeakLuminance {
                let rows = try reader.read(5), columns = try reader.read(5)
                try reader.skip(rows * columns * 4)
            }
            for window in 0..<metadata.windowCount {
                let maxscl = [try reader.read(17), try reader.read(17), try reader.read(17)]
                let average = try reader.read(17)
                let count = try reader.read(4)
                var distribution: [Metadata.Percentile] = []
                for _ in 0..<count {
                    let percentage = try reader.read(7)
                    distribution.append(Metadata.Percentile(percentage: percentage, value: try reader.read(17)))
                }
                let fraction = try reader.read(10)
                if window == 0 {
                    metadata.maxscl = maxscl
                    metadata.averageMaxRGB = average
                    metadata.distribution = distribution
                    metadata.fractionBrightPixels = fraction
                }
            }
            metadata.hasMasteringDisplayActualPeakLuminance = try reader.read(1) == 1
            if metadata.hasMasteringDisplayActualPeakLuminance {
                let rows = try reader.read(5), columns = try reader.read(5)
                try reader.skip(rows * columns * 4)
            }
            for window in 0..<metadata.windowCount {
                var toneMapping: Metadata.ToneMapping?
                if try reader.read(1) == 1 {
                    let kneeX = try reader.read(12), kneeY = try reader.read(12)
                    let count = try reader.read(4)
                    var anchors: [Int] = []
                    for _ in 0..<count { anchors.append(try reader.read(10)) }
                    toneMapping = Metadata.ToneMapping(kneePointX: kneeX, kneePointY: kneeY, anchors: anchors)
                }
                var weight: Int?
                if try reader.read(1) == 1 { weight = try reader.read(6) }
                if window == 0 {
                    metadata.toneMapping = toneMapping
                    metadata.colorSaturationWeight = weight
                }
            }
        } catch {
            return nil
        }
        return metadata
    }
}

// MARK: - Cache

extension RemuxHDR10Plus {

    /// SEI NAL units already built, by levels. The RPUs of a shot repeat the same L1, so
    /// a pass computes (PQ curves, Bezier) once per shot and then copies bytes.
    ///
    /// Not thread-safe: use it from one serial queue (the remux pump).
    final class Cache {

        /// Distinct levels kept before the cache starts over (shots of one session
        /// rarely reach it; starting over only costs one computation per shot).
        let capacity: Int
        private var units: [Levels: [UInt8]] = [:]
        private(set) var hits = 0
        private(set) var misses = 0

        init(capacity: Int = 512) {
            self.capacity = max(1, capacity)
        }

        /// The SEI NAL unit (escaped, no length prefix) of `levels`.
        func seiNAL(for levels: Levels) -> [UInt8] {
            if let unit = units[levels] {
                hits += 1
                return unit
            }
            misses += 1
            if units.count >= capacity { units.removeAll(keepingCapacity: true) }
            let unit = RemuxHDR10Plus.seiNAL(for: levels)
            units[levels] = unit
            return unit
        }

        var count: Int { units.count }
    }
}

// MARK: - Bits

/// MSB-first writer of the ST 2094-40 fields; each value is clamped to its width.
private struct HDR10PlusBitWriter {
    private(set) var bytes: [UInt8] = []
    private var accumulator: UInt8 = 0
    private var bitCount = 0

    mutating func write(_ value: Int, _ count: Int) {
        let limit = (1 << count) - 1
        let field = min(max(value, 0), limit)
        for shift in stride(from: count - 1, through: 0, by: -1) {
            accumulator = accumulator << 1 | UInt8((field >> shift) & 1)
            bitCount += 1
            if bitCount == 8 {
                bytes.append(accumulator)
                accumulator = 0
                bitCount = 0
            }
        }
    }

    /// Pads with zero bits to the next byte boundary and returns the bytes.
    mutating func finish() -> [UInt8] {
        if bitCount > 0 {
            bytes.append(accumulator << UInt8(8 - bitCount))
            accumulator = 0
            bitCount = 0
        }
        return bytes
    }
}

/// MSB-first reader that throws instead of reading past the end (a truncated or
/// lying payload must give nil, never zeros that look like data).
private struct HDR10PlusBitReader {
    struct Overrun: Error {}

    private let bytes: [UInt8]
    private var position: Int

    init(_ bytes: [UInt8], fromByte start: Int) {
        self.bytes = bytes
        position = start * 8
    }

    mutating func read(_ count: Int) throws -> Int {
        guard count >= 0, count <= 32, position + count <= bytes.count * 8 else { throw Overrun() }
        var value = 0
        for _ in 0..<count {
            value = value << 1 | Int((bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1)
            position += 1
        }
        return value
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, position + count <= bytes.count * 8 else { throw Overrun() }
        position += count
    }
}
