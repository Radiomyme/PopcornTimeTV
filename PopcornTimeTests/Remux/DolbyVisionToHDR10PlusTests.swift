//
//  DolbyVisionToHDR10PlusTests.swift
//  PopcornTimeTests
//
//  HDR10+ made from Dolby Vision 8.1 (« Dolby Vision 8.1 » on HDR10+, or Automatic without a
//  Dolby Vision TV, on tvOS): the RPU reader (`DolbyVisionRPU`), the HDR10+ metadata, its SEI
//  writer / reader and the mapping (`RemuxHDR10Plus`), ported from their command-line
//  harnesses, then the plan and its per-sample transform end to end, and the signalling
//  (SUPPLEMENTAL-CODECS ".../cdm4", the 'cdm4' brand).
//  With PT_DV_FIXTURES set to a folder holding F12_dv81.mkv: every sample of the fixture,
//  through the plan and through a whole session. With PT_HDR10P_DUMP_DIR also set, that
//  session's output (init and media segments, playlists, an Annex B stream, the expected
//  values per frame) is kept in <PT_HDR10P_DUMP_DIR>/F12_dv81-hdr10plus for other tools.
//

import XCTest
import Foundation

final class DolbyVisionToHDR10PlusTests: CheckedTestCase {

    private typealias H = RemuxHDR10Plus
    private typealias Generator = RemuxCodecs.HDR10PlusFromDolbyVision

    // MARK: Bytes

    private static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// The RPU of F12_dv81.mkv's first frame (NAL 62, 422 bytes, emulation bytes in):
    /// L1 (0, 3079, 1148), source PQ 62…3079, no L6, a CM v4.0 set.
    private static let realRPU: [UInt8] = bytes([
        "7c0119080908406136506e203f114e6401000941002007801ffc00fffa7e6fec17f26373ca9a60a7f8bbc14f242c2bba",
        "6cfa941a97d175a07c6219aa8164ae7e11628bae32be73af0b4a33191830b8a18d335503ac32640202590a2834ef60c0",
        "1ee81340041528c0281c1db70003e92fde00225cfdc0522319cec0aa9d96f85fd0b139b8841f3a802b21f1404a7200c0",
        "660f0383fd4b02ec670d991bb4e3ddf8942cbebba065c127c024c202e0fe5adad8e2ff96d8c43c712d311ae6680e9bf4",
        "9809ef955828b7e7400402f250d1ed28149bd470be8dec022a930d1afa5154b4c2b44e74c7c69c97946f800b05239520",
        "3027a643ad79e04996d66418cbe6b118448a39681823ba4088f61b470a876844d8714d12b300001af512b37cfe758e12",
        "b3226500000300800000040000030004000003000e1b112180c3052f1847028a00000300d31f2d7fff80000003000003",
        "0000030030103ec070a980300800603a3e010111f0bc8480301c0040040000b08ff99a8008a080080080016102900100",
        "0ed900100100082400c15ffce00000460a14a70000030228582000000303fe0002d52334b080",
    ].joined())

    /// Seeded generator (SplitMix64): a failure replays.
    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    }

    // MARK: Synthetic RPUs

    private struct RPUWriter {
        var bytes: [UInt8] = []
        var bit = 0
        mutating func put(_ value: UInt64, _ count: Int) {
            for k in stride(from: count - 1, through: 0, by: -1) {
                if bit % 8 == 0 { bytes.append(0) }
                if (value >> UInt64(k)) & 1 == 1 { bytes[bytes.count - 1] |= UInt8(0x80 >> (bit % 8)) }
                bit += 1
            }
        }
        mutating func ue(_ v: UInt64) {
            let x = v + 1
            let n = 64 - x.leadingZeroBitCount
            put(0, n - 1); put(x, n)
        }
        mutating func align() { while bit % 8 != 0 { put(0, 1) } }
    }

    private struct Block { var level: UInt64; var bits: [(UInt64, Int)]; var lengthBytes: UInt64 }

    private static let l1Block = Block(level: 1, bits: [(5, 12), (3500, 12), (1500, 12)], lengthBytes: 5)
    private static let l1Alt = Block(level: 1, bits: [(9, 12), (3000, 12), (1000, 12)], lengthBytes: 5)
    private static let l6Block = Block(level: 6, bits: [(4000, 16), (50, 16), (3200, 16), (400, 16)], lengthBytes: 8)
    private static let l4Block = Block(level: 4, bits: [(100, 12), (200, 12)], lengthBytes: 3)
    private static let l254 = Block(level: 254, bits: [(0, 8), (2, 8)], lengthBytes: 2)
    private static let unknownLevel = Block(level: 77, bits: [(0xABCDEF, 24)], lengthBytes: 9)

    /// The RBSP between 0x19 and the CRC → a complete RPU NAL (CRC, terminator, escaping).
    private static func sealRPU(_ payload: [UInt8], trailingZeros: Int = 0) -> [UInt8] {
        let crc = DolbyVisionRPU.crc32MPEG2(payload)
        var rbsp: [UInt8] = [0x19] + payload
        rbsp += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF), 0x80]
        rbsp += [UInt8](repeating: 0, count: trailingZeros)
        return [0x7C, 0x01] + RemuxCodecs.escapeRBSP(rbsp)
    }

    /// An RPU with a minimal mapping (or use_prev) and the given extension blocks.
    private static func syntheticRPU(compressed: Bool = false, usePrev: Bool = true, sceneRefresh: UInt64 = 1,
                                     v29: [Block], v40: [Block]? = nil, dmPresent: Bool = true, sourceMaxPQ: UInt64 = 3696,
                                     extraZero: Bool = false, trailingZeros: Int = 0) -> [UInt8] {
        var w = RPUWriter()
        w.put(2, 6); w.put(18, 11); w.put(1, 4); w.put(0, 4); w.put(1, 1)
        w.put(0, 1); w.put(0, 2); w.ue(23); w.put(1, 2); w.put(0, 1)
        w.ue(2); w.ue(2); w.ue(4); w.put(0, 1); w.put(compressed ? 1 : 0, 3); w.put(0, 1); w.put(1, 1)
        w.put(dmPresent ? 1 : 0, 1); w.put(usePrev ? 1 : 0, 1)
        if usePrev {
            w.ue(0)
        } else {
            // 3 components, 2 pivots each, one polynomial piece of order 1.
            w.ue(0); w.ue(0); w.ue(0)
            for _ in 0..<3 { w.ue(0); w.put(0, 10); w.put(1023, 10) }
            w.ue(0); w.ue(0)
            for _ in 0..<3 { w.ue(0); w.ue(0); w.put(0, 1); for _ in 0..<2 { w.ue(1); w.put(0, 23) } }
        }
        if dmPresent {
            w.ue(0); w.ue(0); w.ue(sceneRefresh)
            if !compressed {
                w.put(0, 464); w.put(12, 5); w.put(0, 6); w.put(7, 12); w.put(sourceMaxPQ, 12); w.put(42, 10)
            }
            func set(_ blocks: [Block]) {
                w.ue(UInt64(blocks.count)); w.align()
                for block in blocks {
                    w.ue(block.lengthBytes); w.put(block.level, 8)
                    var used = 0
                    for (value, count) in block.bits { w.put(value, count); used += count }
                    w.put(0, Int(block.lengthBytes) * 8 - used)
                }
            }
            set(v29)
            if let v40 { set(v40) }
        }
        w.align()
        var payload = w.bytes
        if extraZero { payload.append(0) }
        return sealRPU(payload, trailingZeros: trailingZeros)
    }

    // MARK: Samples

    private let idrSlice: [UInt8] = [0x26, 0x01, 0xAF, 0x12, 0x34, 0x56]      // IDR_W_RADL
    private let craSlice: [UInt8] = [0x2A, 0x01, 0xAF, 0x77, 0x10]            // CRA
    private let trailSlice: [UInt8] = [0x02, 0x01, 0xD0, 0x99, 0x42]          // TRAIL_R
    private let fakeRPU: [UInt8] = [0x7C, 0x01, 0x19, 0x08, 0x09, 0x00, 0x00, 0x03, 0x01]
    private let hdr10PlusPayload: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01, 0x40, 0x00, 0x00, 0x01, 0x7F]
    private let clliPayload: [UInt8] = [0x03, 0xE8, 0x01, 0x90]

    private func seiNAL(_ messages: [(Int, [UInt8])]) -> [UInt8] {
        var rbsp: [UInt8] = []
        for (type, payload) in messages {
            rbsp.append(UInt8(type))
            rbsp.append(UInt8(payload.count))
            rbsp += payload
        }
        rbsp.append(0x80)
        return [0x4E, 0x01] + RemuxCodecs.escapeRBSP(rbsp)
    }

    private func sample(_ units: [[UInt8]], lengthSize: Int = 4) -> Data {
        var out = Data()
        for unit in units {
            var length = unit.count
            var prefix = [UInt8](repeating: 0, count: lengthSize)
            for k in stride(from: lengthSize - 1, through: 0, by: -1) { prefix[k] = UInt8(length & 0xFF); length >>= 8 }
            out.append(contentsOf: prefix)
            out.append(contentsOf: unit)
        }
        return out
    }

    private func units(_ frame: Data, lengthSize: Int = 4) -> [[UInt8]] {
        var result: [[UInt8]] = []
        let b = [UInt8](frame)
        var pos = 0
        while pos + lengthSize <= b.count {
            var n = 0
            for k in 0..<lengthSize { n = n << 8 | Int(b[pos + k]) }
            pos += lengthSize
            guard pos + n <= b.count else { break }
            result.append(Array(b[pos..<(pos + n)]))
            pos += n
        }
        return result
    }

    private func types(_ frame: Data, lengthSize: Int = 4) -> [UInt8] {
        units(frame, lengthSize: lengthSize).map { ($0[0] >> 1) & 0x3F }
    }

    private func hdr10PlusUnits(_ frame: Data, lengthSize: Int = 4) -> [[UInt8]] {
        units(frame, lengthSize: lengthSize).filter { RemuxCodecs.hevcNALHasHDR10Plus($0) }
    }

    /// The HDR10+ metadata the mapping gives for an RPU.
    private func expectedMetadata(_ rpu: [UInt8]) -> H.Metadata? {
        guard let parsed = DolbyVisionRPU.parse(nal: Data(rpu)), let level1 = parsed.level1 else { return nil }
        return H.metadata(for: Generator.levels(level1: level1, level6: parsed.level6, sourceMaxPQ: parsed.sourceMaxPQ))
    }

    private func dvRecord(profile: Int, compat: Int) -> Data {
        let level = 6
        let b2 = UInt8(profile << 1 | (level >> 5))
        let b3 = UInt8((level & 0x1F) << 3 | 0x04 | 0x01)
        return Data([1, 0, b2, b3, UInt8(compat << 4)] + [UInt8](repeating: 0, count: 19))
    }

    private func track(profile: Int = 8, compat: Int = 1, dolbyVision: Bool = true) -> MKVTrack {
        var track = MKVTrack()
        track.number = 1
        track.kind = .video
        track.codecID = "V_MPEGH/ISO/HEVC"
        track.codecPrivate = Data(SyntheticMatroska.hvcC)
        track.pixelWidth = 3840
        track.pixelHeight = 2160
        track.defaultDurationNs = 41_708_333
        if dolbyVision {
            var mapping = MKVBlockAdditionMapping()
            mapping.idType = profile <= 7 ? 0x64766343 : 0x64767643
            mapping.extraData = dvRecord(profile: profile, compat: compat)
            track.blockAdditionMappings = [mapping]
        }
        return track
    }

    private func plan(_ mode: DolbyVisionPlaybackMode, generate: Bool, frames: [Data], dolbyVision: Bool = true,
                      file: StaticString = #filePath, line: Int = #line) -> RemuxVideoPlan? {
        switch RemuxCodecs.makeVideoPlan(track: track(dolbyVision: dolbyVision), sampleFrames: frames, releaseHintsHDR: false,
                                         dolbyVisionMode: mode, hdr10PlusFromDolbyVision: generate) {
        case .success(let plan): return plan
        case .failure(let error):
            check(false, "plan: \(error)", file: file, line: line)
            return nil
        }
    }

    private var clliSEI: [UInt8] { seiNAL([(144, clliPayload)]) }
    private var dv81Frames: [Data] { (0..<4).map { _ in sample([clliSEI, idrSlice, Self.realRPU]) } }

    private func hasBox(_ data: Data, _ fourCC: String) -> Bool { data.range(of: Data(fourCC.utf8)) != nil }

    // MARK: - RPU reader (port of the harness)

    func testTheRealRPUReads() {
        eq(DolbyVisionRPU.crc32MPEG2(Array("123456789".utf8)), 0x0376E6E7, "CRC-32/MPEG-2 check value")
        guard let m = DolbyVisionRPU.parse(nal: Data(Self.realRPU)) else { return check(false, "F12's first RPU parses") }
        eq(m.level1, DolbyVisionRPU.Level1(minPQ: 0, maxPQ: 3079, avgPQ: 1148), "L1")
        eq(m.level1Source, .v29, "L1 from CM v2.9")
        eq(m.level6, nil, "no L6 in F12")
        check(m.sourceMinPQ == 62 && m.sourceMaxPQ == 3079, "source PQ range", "\(String(describing: m.sourceMinPQ)) \(String(describing: m.sourceMaxPQ))")
        check(m.sceneRefresh && !m.usePrevVDRRPU && !m.dmCompressed && m.dmPresent && m.hasCMv40, "flags", "\(m)")
        check(abs(DolbyVisionRPU.nits(fromPQ: 3079) - 1000.6) < 0.1, "PQ 3079 ≈ 1000.6 cd/m²")
        // The range finder, on a sample and on a slice whose indices don't start at 0.
        let frame = sample([clliSEI, idrSlice, Self.realRPU])
        guard let range = DolbyVisionRPU.rpuNALRange(in: frame, lengthSize: 4) else { return check(false, "the RPU is found") }
        eq([UInt8](frame[range]), Self.realRPU, "the RPU's bytes")
        let padded = Data([0xEE, 0xEE, 0xEE]) + frame
        let slice = padded[3...]
        if let sliced = DolbyVisionRPU.rpuNALRange(in: slice, lengthSize: 4) {
            check(sliced.lowerBound >= 3 && DolbyVisionRPU.parse(nal: slice[sliced]) != nil, "slice-relative range")
        } else {
            check(false, "the RPU is found in a slice")
        }
    }

    func testSyntheticRPUs() {
        let full = DolbyVisionRPU.parse(nal: Data(Self.syntheticRPU(usePrev: false,
                                                                    v29: [Self.l4Block, Self.unknownLevel, Self.l1Block, Self.l6Block],
                                                                    v40: [Self.l254])))
        check(full?.level1 == .init(minPQ: 5, maxPQ: 3500, avgPQ: 1500) && full?.level1Source == .v29, "full mapping: L1", "\(String(describing: full))")
        check(full?.level6 == .init(maxDisplayMasteringLuminance: 4000, minDisplayMasteringLuminance: 50,
                                    maxContentLightLevel: 3200, maxFrameAverageLightLevel: 400), "L6")
        check(full?.sourceMinPQ == 7 && full?.sourceMaxPQ == 3696 && full?.sceneRefresh == true && full?.hasCMv40 == true, "DM fields")

        let compressed = DolbyVisionRPU.parse(nal: Data(Self.syntheticRPU(compressed: true, sceneRefresh: 0, v29: [Self.l1Alt])))
        check(compressed?.dmCompressed == true && compressed?.usePrevVDRRPU == true && compressed?.sourceMaxPQ == nil
              && compressed?.level1?.maxPQ == 3000 && compressed?.sceneRefresh == false && compressed?.hasCMv40 == false,
              "compressed DM + use_prev", "\(String(describing: compressed))")

        // A static level in a compressed DM is ignored, as FFmpeg does: only uncompressed RPUs send L6.
        let compressedL6 = DolbyVisionRPU.parse(nal: Data(Self.syntheticRPU(compressed: true, v29: [Self.l1Alt, Self.l6Block])))
        check(compressedL6 != nil && compressedL6?.level1?.maxPQ == 3000 && compressedL6?.level6 == nil,
              "compressed DM: L1 read, L6 ignored", "\(String(describing: compressedL6))")

        let both = DolbyVisionRPU.parse(nal: Data(Self.syntheticRPU(v29: [Self.l1Block], v40: [Self.l1Alt])))
        check(both?.level1?.maxPQ == 3500 && both?.level1Source == .v29, "CM v2.9 L1 preferred")
        let only40 = DolbyVisionRPU.parse(nal: Data(Self.syntheticRPU(v29: [Self.l4Block], v40: [Self.l1Alt, Self.l254])))
        check(only40?.level1?.maxPQ == 3000 && only40?.level1Source == .v40, "CM v4.0 L1 as a fallback")

        let noL1 = DolbyVisionRPU.parse(nal: Data(Self.syntheticRPU(v29: [Self.l4Block])))
        check(noL1 != nil && noL1?.level1 == nil, "no L1")
        let noDM = DolbyVisionRPU.parse(nal: Data(Self.syntheticRPU(sceneRefresh: 0, v29: [], dmPresent: false)))
        check(noDM?.dmPresent == false && noDM?.level1 == nil, "no DM")
        let padded = DolbyVisionRPU.parse(nal: Data(Self.syntheticRPU(usePrev: false, v29: [Self.l1Block], extraZero: true, trailingZeros: 3)))
        eq(padded?.level1?.maxPQ, 3500, "a zero byte before the CRC and trailing zeros")

        // No sequence info: refused alone, read with the previous one.
        var w = RPUWriter()
        w.put(2, 6); w.put(18, 11); w.put(1, 4); w.put(0, 4); w.put(0, 1)
        w.put(1, 1); w.put(1, 1); w.ue(0)
        w.ue(0); w.ue(0); w.ue(1)
        w.put(0, 464); w.put(12, 5); w.put(0, 6); w.put(7, 12); w.put(3696, 12); w.put(42, 10)
        w.ue(1); w.align(); w.ue(5); w.put(1, 8); w.put(1, 12); w.put(2000, 12); w.put(900, 12); w.put(0, 4)
        w.align()
        let noSequence = Data(Self.sealRPU(w.bytes))
        eq(DolbyVisionRPU.parse(nal: noSequence), nil, "no sequence info, no previous one")
        if let sequence = full?.sequenceInfo {
            eq(DolbyVisionRPU.parse(nal: noSequence, previousSequence: sequence)?.level1?.maxPQ, 2000, "no sequence info, the previous one")
        }
    }

    func testBrokenRPUsAreRefused() {
        let real = Self.realRPU
        var truncatedAccepted = 0
        for n in 0..<real.count where DolbyVisionRPU.parse(nal: Data(real[0..<n])) != nil { truncatedAccepted += 1 }
        eq(truncatedAccepted, 0, "every truncation is refused")

        var wrong = real; wrong[2] = 0x18
        eq(DolbyVisionRPU.parseResult(nal: Data(wrong)), .failure(.badPrefix), "bad prefix")
        wrong = real; wrong[0] = 0x7A
        eq(DolbyVisionRPU.parseResult(nal: Data(wrong)), .failure(.notRPU), "NAL type 61")
        wrong = real; wrong[1] = 0x02
        eq(DolbyVisionRPU.parseResult(nal: Data(wrong)), .failure(.notRPU), "TemporalId 1")
        wrong = real; if let last = wrong.lastIndex(where: { $0 != 0 }) { wrong[last] = 0x81 }
        eq(DolbyVisionRPU.parseResult(nal: Data(wrong)), .failure(.badTerminator), "bad terminator")

        var flipsAccepted = 0
        for bit in stride(from: 24, to: (real.count - 6) * 8, by: 7) {
            var flipped = real
            flipped[bit / 8] ^= UInt8(0x80 >> (bit % 8))
            if DolbyVisionRPU.parse(nal: Data(flipped)) != nil { flipsAccepted += 1 }
        }
        eq(flipsAccepted, 0, "no single-bit flip is accepted (CRC)")

        var rng = SplitMix(state: 0x0062_0019)
        var garbageAccepted = 0
        for _ in 0..<5000 {
            var garbage = (0..<rng.int(0...600)).map { _ in UInt8(rng.int(0...255)) }
            if garbage.count >= 3, rng.int(0...1) == 1 { garbage[0] = 0x7C; garbage[1] = 0x01; garbage[2] = 0x19 }
            if DolbyVisionRPU.parse(nal: Data(garbage)) != nil { garbageAccepted += 1 }
        }
        eq(garbageAccepted, 0, "random NALs are refused")

        // Mutated payloads re-sealed with a valid CRC reach the bit-level syntax: no trap.
        var rbsp = H.removingEmulation(real, from: 2)
        while rbsp.last == 0 { rbsp.removeLast() }
        let payload = Array(rbsp.dropFirst().dropLast(5))
        var parsed = 0
        for iteration in 0..<8000 {
            var p = payload
            switch iteration % 4 {
            case 0:
                for _ in 0..<rng.int(1...8) { let bit = rng.int(0...(p.count * 8 - 1)); p[bit / 8] ^= UInt8(0x80 >> (bit % 8)) }
            case 1:
                p = Array(p.prefix(rng.int(0...(p.count - 1))))
            case 2:
                p = Array(p.prefix(rng.int(0...(p.count - 1)))) + (0..<rng.int(0...64)).map { _ in UInt8(rng.int(0...255)) }
            default:
                p = (0..<rng.int(0...500)).map { _ in UInt8(rng.int(0...255)) }
            }
            if DolbyVisionRPU.parse(nal: Data(Self.sealRPU(p))) != nil { parsed += 1 }
        }
        check(parsed < 8000, "re-sealed mutations: \(parsed) still parse, the rest refused, none traps")

        check(DolbyVisionRPU.rpuNALRange(in: Data([0, 0, 0, 9, 1]), lengthSize: 4) == nil, "overlong length")
        check(DolbyVisionRPU.rpuNALRange(in: Data([0, 0]), lengthSize: 4) == nil, "short prefix")
        let frame = sample([idrSlice, real])
        check(DolbyVisionRPU.rpuNALRange(in: frame, lengthSize: 0) == nil && DolbyVisionRPU.rpuNALRange(in: frame, lengthSize: 5) == nil,
              "length size out of 1…4")
        check(DolbyVisionRPU.rpuNALRange(in: Data(), lengthSize: 4) == nil, "empty sample")
        for _ in 0..<5000 {
            let garbage = Data((0..<rng.int(0...64)).map { _ in UInt8(rng.int(0...255)) })
            _ = DolbyVisionRPU.rpuNALRange(in: garbage, lengthSize: rng.int(1...4))
        }
    }

    // MARK: - HDR10+ writer, reader, mapping (port of the harness)

    func testTheWorkedVector() {
        var m = H.Metadata()
        m.maxscl = [8740, 10000, 7500]
        m.averageMaxRGB = 520
        m.distribution = zip(H.percentageIndexes, [5, 30, 60, 180, 400, 900, 2600, 4200, 9000]).map { H.Metadata.Percentile(percentage: $0, value: $1) }
        let payload = H.t35Payload(m)
        eq(hex(payload), "b5003c0001040140000000444827100ea60082240800142800785000f0c802d1900642580e12d028a2f841a3188ca00000", "payload")
        let nal = H.seiNAL(m)
        eq(hex(nal), "4e010431b5003c000104014000000300444827100ea60082240800142800785000f0c802d1900642580e12d028a2f841a3188ca0000080", "NAL")
        eq(H.parse(seiNAL: nal), m, "parsed back")
        check(m.profile == .a && payload.count == 49, "Profile A, 49 bytes")
        check(RemuxCodecs.hevcNALHasHDR10Plus(nal), "the remux's own detection sees it")
    }

    func testFFmpegFATEValues() {
        // Quoted in mapping.md: TSDML 400, V1 = V8 = 2940, V2 = 255, fraction_bright_pixels 1, knee (0, 0),
        // anchors 102…922, peak 334 cd/m². The other fields are picks of the harness.
        var m = H.Metadata()
        m.targetedSystemDisplayMaximumLuminance = 400
        m.maxscl = [3340, 3000, 2500]
        m.averageMaxRGB = 510
        m.distribution = zip(H.percentageIndexes, [30, 2940, 255, 70, 1340, 1600, 1850, 2700, 2940])
            .map { H.Metadata.Percentile(percentage: $0, value: $1) }
        m.fractionBrightPixels = 1
        m.toneMapping = .init(kneePointX: 0, kneePointY: 0, anchors: [102, 205, 307, 410, 512, 614, 717, 819, 922])
        eq(H.bypassAnchors, [102, 205, 307, 410, 512, 614, 717, 819, 922], "bypass anchors = FATE's")
        let nal = H.seiNAL(m)
        eq(H.parse(seiNAL: nal), m, "round trip")
        eq(H.removingEmulation(nal, from: 2)[1], 64, "payloadSize 64")
        eq(m.profile, .b, "Profile B")
        check(!m.consistencyViolations.isEmpty, "max(MaxSCL) ≠ V8 is flagged by the generator's rules")
        let mapped = H.metadata(for: .init(minPQ: 0, avgPQ: 1500, maxPQ: Int((H.pq(nits: 334) * 4095).rounded())))
        eq(mapped.toneMapping, m.toneMapping, "a 334 cd/m² scene maps to the FATE bypass curve")
    }

    func testReferenceCurves() {
        let a = H.metadata(for: .init(minPQ: 0, avgPQ: 2081, maxPQ: 3079)).toneMapping
        eq(a, .init(kneePointX: 410, kneePointY: 1025, anchors: [307, 546, 725, 853, 938, 989, 1014, 1023, 1023]), "1000/100")
        let b = H.metadata(for: .init(minPQ: 0, avgPQ: 1229, maxPQ: 3388)).toneMapping
        eq(b, .init(kneePointX: 41, kneePointY: 205, anchors: [533, 814, 948, 1003, 1020, 1023, 1023, 1023, 1023]), "2000/10")
        let c = H.metadata(for: .init(minPQ: 0, avgPQ: 2400, maxPQ: 3696)).toneMapping
        eq(c, .init(kneePointX: 205, kneePointY: 2048, anchors: Array(repeating: 1023, count: 9)), "4000/214")
        if let a {
            let peak = H.nits(pqCode: 3079)
            let out = [250.0, 500, 750, peak].map { 400 * H.evaluate(a, at: $0 / peak) }
            check(abs(out[0] - 226.5) < 2 && abs(out[1] - 348.6) < 2 && abs(out[2] - 393.6) < 2 && abs(out[3] - 400) < 0.01,
                  "1000 cd/m² curve outputs", "\(out)")
        }
        for (code, expected) in [(62, 0.005), (819, 2.43), (1229, 10.05), (2081, 100.1), (2851, 599.6),
                                 (3079, 1000.6), (3388, 1998.6), (3696, 3999.7), (4095, 10000)] {
            let value = H.nits(pqCode: code)
            check(abs(value - expected) <= max(0.06, expected * 0.0005), "PQ \(code) → \(value), expected \(expected)")
            check(abs(H.pq(nits: value) * 4095 - Double(code)) < 1e-6, "inverse PQ \(code)")
        }
    }

    /// Whole metadata sets against an independent recomputation of mapping.md §4 (Python, from
    /// the verifier script of the F12 dump): the branches F12 never reaches. F12's scenes all
    /// have max 1000.6 cd/m² and avg ≈ 8 cd/m², so they only take the clamped-knee, N = 3 path.
    func testIndependentVectors() {
        struct Vector {
            var name: String
            var levels: H.Levels
            var maxscl: Int, average: Int, percentiles: [Int], knee: (Int, Int), anchors: [Int]
        }
        let level1 = DolbyVisionRPU.Level1(minPQ: 7, maxPQ: 3696, avgPQ: 2400)   // 4000 / 214 cd/m²
        func l6(_ mastering: UInt16, _ cll: UInt16) -> DolbyVisionRPU.Level6 {
            .init(maxDisplayMasteringLuminance: mastering, minDisplayMasteringLuminance: 50, maxContentLightLevel: cll, maxFrameAverageLightLevel: cll == 0 ? 0 : 400)
        }
        let rollOff4000 = [1023, 1023, 1023, 1023, 1023, 1023, 1023, 1023, 1023]
        let vectors = [
            Vector(name: "bypass: 339 cd/m² fits the 400 cd/m² target", levels: .init(minPQ: 0, avgPQ: 1500, maxPQ: 2600),
                   maxscl: 3391, average: 223, percentiles: [0, 3391, 255, 56, 223, 403, 811, 1212, 3391], knee: (0, 0), anchors: H.bypassAnchors),
            Vector(name: "knee at the average (100 cd/m², not clamped), N = 4", levels: .init(minPQ: 0, avgPQ: 2081, maxPQ: 3079),
                   maxscl: 10006, average: 1001, percentiles: [1, 10006, 255, 197, 1001, 1615, 2889, 4069, 10006], knee: (410, 1025),
                   anchors: [307, 546, 725, 853, 938, 989, 1014, 1023, 1023]),
            Vector(name: "2000 cd/m², N = 8", levels: .init(minPQ: 12, avgPQ: 2290, maxPQ: 3388),
                   maxscl: 19986, average: 1651, percentiles: [1, 19986, 255, 298, 1651, 2756, 5155, 7472, 19986], knee: (338, 1691),
                   anchors: [799, 991, 1021, 1023, 1023, 1023, 1023, 1023, 1023]),
            Vector(name: "4000 cd/m²: N = 10, saturated anchors", levels: Generator.levels(level1: level1, level6: nil),
                   maxscl: 39997, average: 2137, percentiles: [1, 39997, 255, 365, 2137, 3882, 8072, 12478, 39997], knee: (205, 2048),
                   anchors: rollOff4000),
            Vector(name: "black: the 0.1 cd/m² floor, bypass", levels: .init(minPQ: 0, avgPQ: 0, maxPQ: 0),
                   maxscl: 1, average: 0, percentiles: [0, 1, 255, 0, 0, 0, 0, 0, 1], knee: (0, 0), anchors: H.bypassAnchors),
            Vector(name: "L6 MaxCLL 800 under mastering 1000", levels: Generator.levels(level1: level1, level6: l6(1000, 800), sourceMaxPQ: 3696),
                   maxscl: 8000, average: 2137, percentiles: [1, 8000, 255, 365, 2137, 2795, 3895, 4745, 8000], knee: (1024, 2048),
                   anchors: [307, 546, 725, 853, 938, 989, 1014, 1023, 1023]),
            Vector(name: "L6 mastering 1000, MaxCLL unknown", levels: Generator.levels(level1: level1, level6: l6(1000, 0), sourceMaxPQ: 3696),
                   maxscl: 10000, average: 2137, percentiles: [1, 10000, 255, 365, 2137, 2927, 4313, 5432, 10000], knee: (819, 2048),
                   anchors: [409, 682, 853, 950, 999, 1018, 1023, 1023, 1023]),
            Vector(name: "no L6: source_max_pq 3079 bounds the peak", levels: Generator.levels(level1: level1, level6: nil, sourceMaxPQ: 3079),
                   maxscl: 10006, average: 2137, percentiles: [1, 10006, 255, 365, 2137, 2927, 4314, 5434, 10006], knee: (819, 2048),
                   anchors: [410, 682, 853, 950, 999, 1018, 1023, 1023, 1023]),
            Vector(name: "L6 mastering 4000 wins over source_max_pq", levels: Generator.levels(level1: level1, level6: l6(4000, 0), sourceMaxPQ: 3079),
                   maxscl: 39997, average: 2137, percentiles: [1, 39997, 255, 365, 2137, 3882, 8072, 12478, 39997], knee: (205, 2048),
                   anchors: rollOff4000),
        ]
        for vector in vectors {
            let m = H.metadata(for: vector.levels)
            eq(m.maxscl, [vector.maxscl, vector.maxscl, vector.maxscl], "\(vector.name): MaxSCL")
            eq(m.averageMaxRGB, vector.average, "\(vector.name): average_maxrgb")
            eq(m.distribution.map(\.value), vector.percentiles, "\(vector.name): percentiles")
            check(m.toneMapping?.kneePointX == vector.knee.0 && m.toneMapping?.kneePointY == vector.knee.1,
                  "\(vector.name): knee", "\(String(describing: m.toneMapping))")
            eq(m.toneMapping?.anchors, vector.anchors, "\(vector.name): anchors")
            eq(m.targetedSystemDisplayMaximumLuminance, 400, "\(vector.name): TSDML")
            eq(m.consistencyViolations, [], "\(vector.name): rules")
            eq(H.parse(seiNAL: H.seiNAL(m)), m, "\(vector.name): round trip")
        }
        eq(Generator.levels(level1: level1, level6: l6(1000, 0), sourceMaxPQ: 3079).sourceMaxPQ, 0,
           "source_max_pq is not part of the key when L6 gives the mastering peak")
    }

    /// The writer's emulation prevention on generated Profile B sets (the worked vector covers
    /// Profile A). F12's SEIs never need it; these do: a MaxSCL that is a multiple of 256 ends
    /// in zero bits that run into a small average (« 00 00 03 03 » and « 00 00 03 02 »). The
    /// expected bytes come from an independent writer (Python, verifier script).
    func testGeneratedSEIsAreEscaped() {
        let vectors: [(H.Levels, String)] = [
            (.init(minPQ: 309, avgPQ: 698, maxPQ: 1812),   // 51.2 cd/m²: bypass
             "4e010440b5003c0001040140000c80040002000100000303e40800082808005003fcc8002590003e580092d00172f8"
             + "02631808000040000024663353366a0099acdccf9a0080"),
            (.init(minPQ: 364, avgPQ: 618, maxPQ: 3189),   // 1280 cd/m², avg 1 cd/m²: roll-off
             "4e010440b5003c0001040140000c80640032001900000302a408000c28c8005003fcc8001d90002a58012ad00746f8"
             + "12f718c800004100336553936fddcfbdf9bf9fffff0080"),
        ]
        for (levels, expected) in vectors {
            let m = H.metadata(for: levels)
            let nal = H.seiNAL(m)
            eq(hex(nal), expected, "\(levels): the escaped NAL")
            let raw = H.removingEmulation(nal)
            eq(nal.count - raw.count, 1, "\(levels): one emulation_prevention_three_byte")
            eq(raw.count, 69, "\(levels): 69 bytes unescaped")
            var zeros = 0, emulation = false
            for byte in nal { if zeros >= 2, byte <= 2 { emulation = true }; zeros = byte == 0 ? zeros + 1 : 0 }
            check(!emulation, "\(levels): no 00 00 0x (x ≤ 2) left", hex(nal))
            eq(H.parse(seiNAL: nal), m, "\(levels): parsed back")
            eq(m.profile, .b, "\(levels): Profile B")
            eq(m.consistencyViolations, [], "\(levels): rules")
        }
        // Through the generator too: the escaped unit is what goes in the sample.
        let rpu = Self.syntheticRPU(v29: [Block(level: 1, bits: [(309, 12), (1812, 12), (698, 12)], lengthBytes: 5)])
        let out = Generator(lengthSize: 4).transform(sample([idrSlice, rpu]))
        eq(units(out).first.map(hex), vectors[0].1, "the generator writes the escaped unit")
    }

    func testTheMappingOverManyInputs() {
        var cases: [H.Levels] = []
        for minPQ in [0, 12, 62, 700, 1500, 3000, 4095] {
            for avgPQ in [0, 62, 819, 1229, 1800, 2081, 2600, 3079, 4095] {
                for maxPQ in [0, 1, 62, 1000, 2081, 2400, 2500, 2851, 3079, 3388, 3696, 4000, 4095] {
                    cases.append(.init(minPQ: minPQ, avgPQ: avgPQ, maxPQ: maxPQ))
                }
            }
        }
        cases += [.init(minPQ: -5, avgPQ: -1, maxPQ: -9), .init(minPQ: 5000, avgPQ: 9000, maxPQ: 70000),
                  .init(minPQ: 0, avgPQ: 1148, maxPQ: 3079, maxContentLightLevel: 1100, masteringDisplayPeak: 1000),
                  .init(minPQ: 0, avgPQ: 1148, maxPQ: 3079, targetDisplayNits: 0),
                  .init(minPQ: 0, avgPQ: 1148, maxPQ: 4095, targetDisplayNits: 20000),
                  .init(minPQ: 0, avgPQ: 0, maxPQ: 0, maxContentLightLevel: 1, masteringDisplayPeak: 1)]
        var rng = SplitMix(state: 0x2094_0040)
        for _ in 0..<4000 {
            let a = rng.int(0...4095), b = rng.int(0...4095), c = rng.int(0...4095)
            let sorted = [a, b, c].sorted()
            let ordered = rng.int(0...3) != 0
            let cll = rng.int(0...3) == 0 ? rng.int(0...10000) : 0
            let mastering = rng.int(0...3) == 0 ? [1000, 4000, 10000, rng.int(1...10000)][rng.int(0...3)] : 0
            let target = [400, 400, 400, 1000, rng.int(1...10000)][rng.int(0...4)]
            cases.append(ordered
                         ? .init(minPQ: sorted[0], avgPQ: sorted[1], maxPQ: sorted[2], maxContentLightLevel: cll, masteringDisplayPeak: mastering, targetDisplayNits: target)
                         : .init(minPQ: a, avgPQ: b, maxPQ: c, maxContentLightLevel: cll, masteringDisplayPeak: mastering, targetDisplayNits: target))
        }
        var failed: [String] = []
        for levels in cases {
            let m = H.metadata(for: levels)
            let nal = H.seiNAL(for: levels)
            let unescaped = H.removingEmulation(nal)
            var problems: [String] = m.consistencyViolations
            if m.profile != .b { problems.append("profile") }
            if m.distribution[1].value != m.distribution[8].value { problems.append("V1 ≠ V8") }
            if m.fractionBrightPixels != 0 { problems.append("FBP") }
            if Array(nal[0..<2]) != [0x4E, 0x01] || unescaped[2] != 4 || unescaped[3] != 64 || unescaped.count != 69 || unescaped.last != 0x80 {
                problems.append("SEI layout")
            }
            var zeros = 0, emulation = false
            for byte in nal { if zeros >= 2, byte <= 3, byte != 3 { emulation = true }; zeros = byte == 0 ? zeros + 1 : 0 }
            if emulation { problems.append("start code emulation") }
            if H.parse(seiNAL: nal) != m { problems.append("round trip") }
            if let curve = m.toneMapping {
                var previous = -1.0
                for step in 0...200 {
                    let value = H.evaluate(curve, at: Double(step) / 200)
                    if value < previous - 1e-12 { problems.append("curve not monotonic"); break }
                    previous = value
                }
                if abs(H.evaluate(curve, at: 1) - 1) > 1e-9 { problems.append("curve end") }
                if curve.anchors.count != 9 { problems.append("anchors") }
            } else {
                problems.append("no curve")
            }
            let peak = m.distribution[8].value
            if levels.maxContentLightLevel > 0, peak > levels.maxContentLightLevel * 10 { problems.append("MaxCLL bound") }
            if levels.masteringDisplayPeak > 0, peak > levels.masteringDisplayPeak * 10 { problems.append("mastering bound") }
            if peak < 1 { problems.append("black floor") }
            if !problems.isEmpty { failed.append("\(levels): \(problems)") }
        }
        check(failed.isEmpty, "\(cases.count) inputs: rules, layout, round trip, curve", failed.prefix(5).joined(separator: "; "))

        let black = H.metadata(for: .init(minPQ: 0, avgPQ: 0, maxPQ: 0))
        check(black.maxscl == [1, 1, 1] && black.averageMaxRGB == 0 && black.distribution.map(\.value) == [0, 1, 255, 0, 0, 0, 0, 0, 1]
              && black.toneMapping?.anchors == H.bypassAnchors, "black scene", "\(black)")
        let bright = H.metadata(for: .init(minPQ: 4095, avgPQ: 4095, maxPQ: 4095))
        check(bright.maxscl == [100000, 100000, 100000] && bright.averageMaxRGB == 100000, "4095")
        let inverted = H.metadata(for: .init(minPQ: 0, avgPQ: 3500, maxPQ: 2081))
        eq(inverted.averageMaxRGB, inverted.distribution[8].value, "avg > max is clamped to max")
        let minAbove = H.metadata(for: .init(minPQ: 3000, avgPQ: 1229, maxPQ: 3079))
        eq(minAbove.distribution[0].value, minAbove.distribution[4].value, "min > avg is clamped to avg")
    }

    func testTheReaderIsTolerant() {
        let m = H.metadata(for: .init(minPQ: 0, avgPQ: 1148, maxPQ: 3079))
        let nal = H.seiNAL(m)
        var truncatedOK = true
        for length in 0..<(nal.count - 1) where H.parse(seiNAL: Array(nal[0..<length])) != nil { truncatedOK = false }
        check(truncatedOK, "every truncation (but the final 0x80) reads as nil")
        var rng = SplitMix(state: 0x0B5_003C)
        for _ in 0..<10000 {
            var corrupt = nal
            for _ in 0..<rng.int(1...6) { corrupt[rng.int(2...(corrupt.count - 1))] = UInt8(rng.int(0...255)) }
            if rng.int(0...3) == 0 { corrupt = Array(corrupt.prefix(rng.int(0...corrupt.count))) }
            _ = H.parse(seiNAL: corrupt)
        }
        let payload = H.t35Payload(m)
        var raw: [UInt8] = [0x4E, 0x01, 5, 20] + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 1]
        raw += [4, UInt8(payload.count)] + payload + [0x80]
        eq(H.parse(seiNAL: H.escapingEmulation(raw)), m, "HDR10+ after another message")
        eq(H.parse(seiNAL: [0x40, 0x01] + H.removingEmulation(nal, from: 2)), nil, "a VPS is no SEI")
        var other = payload; other[5] = 0x05
        eq(H.parse(t35Payload: other), nil, "another application")
        var v0 = m; v0.applicationVersion = 0
        eq(H.parse(seiNAL: H.seiNAL(v0))?.applicationVersion, 0, "application_version 0")
    }

    func testTheCacheBuildsAShotOnce() {
        let cache = H.Cache(capacity: 4)
        let shot = H.Levels(minPQ: 0, avgPQ: 1148, maxPQ: 3079)
        var same = true
        for _ in 0..<100 { same = same && cache.seiNAL(for: shot) == H.seiNAL(for: shot) }
        check(same && cache.hits == 99 && cache.misses == 1, "1 computation for 100 lookups", "\(cache.hits) / \(cache.misses)")
        for average in 1149...1160 { _ = cache.seiNAL(for: .init(minPQ: 0, avgPQ: average, maxPQ: 3079)) }
        check(cache.count <= 4, "bounded")
        eq(cache.seiNAL(for: shot), H.seiNAL(for: shot), "the same bytes after starting over")
    }

    // MARK: - The plan and its transform

    func testThePlanGeneratesHDR10Plus() {
        guard let plan = plan(.hdr10Plus, generate: true, frames: dv81Frames) else { return }
        eq(plan.codec, .hevc, "plain HEVC")
        eq(plan.supplementalCodecs, plan.codecsString + "/cdm4", "SUPPLEMENTAL-CODECS: the CODECS string with 'cdm4'")
        check(plan.codecsString.hasPrefix("hvc1."), "CODECS hvc1", plan.codecsString)
        check(plan.signalsHDR10Plus, "the plan signals HDR10+")
        eq(plan.videoRange, .pq, "VIDEO-RANGE=PQ")
        check(!hasBox(plan.sampleEntry, "dvvC") && !hasBox(plan.sampleEntry, "dvcC"), "no Dolby Vision box")
        check(plan.summary.hasPrefix("HDR10+ (converti depuis Dolby Vision 8.1)"), "summary", plan.summary)
        guard let transform = plan.transform else { return check(false, "a transform") }
        check(plan.transformReport?().hasPrefix("HDR10+ from Dolby Vision: 0 sample(s)") == true, "a report for the session log",
              plan.transformReport?() ?? "nil")

        let out = transform(sample([clliSEI, idrSlice, Self.realRPU]))
        eq(types(out), [39, 39, 19], "the file's SEI, the HDR10+ SEI, the slice; no RPU")
        let outUnits = units(out)
        eq(outUnits[0], clliSEI, "the file's SEI is byte-identical")
        eq(outUnits[2], idrSlice, "the slice is byte-identical")
        eq(Array(outUnits[1].prefix(2)), [0x4E, 0x01], "prefix SEI header")
        check(RemuxCodecs.hevcNALHasHDR10Plus(outUnits[1]), "the remux's detection sees the generated SEI")
        let parsed = H.parse(seiNAL: outUnits[1])
        eq(parsed, expectedMetadata(Self.realRPU), "parsed back: the mapping of the frame's RPU")
        eq(parsed?.applicationVersion, 1, "application_version 1")
        eq(parsed?.windowCount, 1, "one window")
        eq(parsed?.targetedSystemDisplayMaximumLuminance, 400, "TSDML 400")
        eq(parsed?.maxscl, [10006, 10006, 10006], "MaxSCL = L1 max (1000.6 cd/m²)")
        eq(parsed?.distribution.map(\.percentage), [1, 5, 10, 25, 50, 75, 90, 95, 99], "percentages")
        eq(parsed?.distribution[2].value, 255, "V2 = 255")
        eq(parsed?.distribution[1].value, parsed?.distribution[8].value, "V1 = V8")
        eq(parsed?.fractionBrightPixels, 0, "fraction_bright_pixels 0")
        check(parsed?.toneMapping != nil && parsed?.toneMapping?.anchors != H.bypassAnchors, "a 1000 cd/m² scene gets a roll-off, not the bypass")
        eq(parsed?.consistencyViolations ?? ["nil"], [], "every consistency rule holds")

        // A P picture: the SEI goes first.
        let p = transform(sample([trailSlice, Self.realRPU]))
        eq(types(p), [39, 1], "P: SEI then slice")
        eq(units(p)[0], outUnits[1], "the same shot, the same SEI")

        // AUD, parameter sets and SEI stay in front of it.
        let vps: [UInt8] = [0x40, 0x01, 0x0C], sps: [UInt8] = [0x42, 0x01, 0x01], pps: [UInt8] = [0x44, 0x01, 0xC1], aud: [UInt8] = [0x46, 0x01, 0x50]
        let full = transform(sample([aud, vps, sps, pps, clliSEI, idrSlice, trailSlice, Self.realRPU]))
        eq(types(full), [35, 32, 33, 34, 39, 39, 19, 1], "after AUD / VPS / SPS / PPS / SEI, before the first slice")
        eq(hdr10PlusUnits(full).count, 1, "exactly one HDR10+ SEI")
        check(plan.transformReport?().hasPrefix("HDR10+ from Dolby Vision: 3 sample(s) from their own RPU") == true,
              "the report counts the samples", plan.transformReport?() ?? "nil")
    }

    func testTheFilesOwnHDR10PlusIsKept() {
        let native = seiNAL([(4, hdr10PlusPayload), (144, clliPayload)])
        let frames = (0..<4).map { _ in sample([native, idrSlice, Self.realRPU]) }
        guard let plan = plan(.hdr10Plus, generate: true, frames: frames) else { return }
        check(plan.summary.hasPrefix("HDR10+ (Dolby Vision 8.1 ignoré)"), "summary", plan.summary)
        eq(plan.supplementalCodecs, plan.codecsString + "/cdm4", "signalled as HDR10+")
        let out = plan.transform?(frames[0]) ?? frames[0]
        eq(types(out), [39, 19], "nothing added, no RPU")
        eq(units(out)[0], native, "the file's SEI is byte-identical")

        // HDR10+ of the file's own that starts after the first frames: never doubled.
        guard let generating = self.plan(.hdr10Plus, generate: true, frames: dv81Frames), let transform = generating.transform else { return }
        let later = transform(sample([native, trailSlice, Self.realRPU]))
        eq(types(later), [39, 1], "a later sample with its own HDR10+ gets none")
        eq(hdr10PlusUnits(later), [native], "only the file's")

        // Any HEVC with HDR10+ of its own is signalled, Dolby Vision or not, on every platform.
        let plainFrames = (0..<4).map { _ in sample([native, idrSlice]) }
        var pqTrack = track(dolbyVision: false)
        var colour = MKVColour()
        colour.transferCharacteristics = 16
        colour.primaries = 9
        colour.matrixCoefficients = 9
        pqTrack.colour = colour
        for (variant, expected) in [(pqTrack, true), (track(dolbyVision: false), false)] {
            guard case .success(let plain) = RemuxCodecs.makeVideoPlan(track: variant, sampleFrames: plainFrames, releaseHintsHDR: false) else {
                check(false, "plain HEVC plan"); continue
            }
            eq(plain.codec, .hevc, "plain HEVC")
            if expected {
                eq(plain.videoRange, .pq, "PQ")
                eq(plain.supplementalCodecs, plain.codecsString + "/cdm4", "HDR10+ of the file's own, every platform")
            } else if plain.videoRange != .pq {
                eq(plain.supplementalCodecs, nil, "only PQ variants are signalled")
            }
        }
    }

    func testOtherModesAndPlatformsAreUnchanged() {
        // Generation off (iOS, Mac): HDR10, as before.
        guard let off = plan(.hdr10Plus, generate: false, frames: dv81Frames) else { return }
        check(off.summary.hasPrefix("HDR10 (Dolby Vision 8.1 ignoré, pas de HDR10+)"), "summary", off.summary)
        eq(off.supplementalCodecs, nil, "no SUPPLEMENTAL-CODECS")
        check(off.transformReport == nil, "nothing to report")
        eq(types(off.transform?(dv81Frames[0]) ?? Data()), [39, 19], "RPU dropped, nothing added")

        // HDR10 drops HDR10+ and says nothing of it.
        let native = seiNAL([(4, hdr10PlusPayload), (144, clliPayload)])
        let nativeFrames = (0..<4).map { _ in sample([native, idrSlice, Self.realRPU]) }
        guard let hdr10 = plan(.hdr10, generate: true, frames: nativeFrames) else { return }
        eq(hdr10.supplementalCodecs, nil, "HDR10: no SUPPLEMENTAL-CODECS")
        check(hdr10Plus(in: hdr10.transform?(nativeFrames[0])) == 0, "HDR10: no HDR10+ in the samples")
        guard let hdr10Generated = plan(.hdr10, generate: true, frames: dv81Frames) else { return }
        check(hdr10Plus(in: hdr10Generated.transform?(dv81Frames[0])) == 0, "HDR10: nothing generated")

        // Dolby Vision: unchanged, no composite variant.
        guard let dv = plan(.dolbyVision, generate: true, frames: dv81Frames) else { return }
        eq(dv.codec, .dolbyVision(profile: 8, level: 6, compatibilityID: 1), "Dolby Vision 8.1")
        eq(dv.supplementalCodecs, "dvh1.08.06/db1p", "SUPPLEMENTAL-CODECS of Dolby Vision only")
        check(types(dv.transform?(dv81Frames[0]) ?? dv81Frames[0]).contains(62), "the RPUs stay")
        check(!dv.signalsHDR10Plus, "no 'cdm4'")
    }

    private func hdr10Plus(in frame: Data?) -> Int { frame.map { hdr10PlusUnits($0).count } ?? -1 }

    func testRPUsThatCantBeReadGiveHDR10() {
        let frames = (0..<4).map { _ in sample([clliSEI, idrSlice, fakeRPU]) }
        guard let plan = plan(.hdr10Plus, generate: true, frames: frames) else { return }
        check(plan.summary.hasPrefix("HDR10 (Dolby Vision 8.1 ignoré, pas de HDR10+)"), "summary", plan.summary)
        eq(plan.supplementalCodecs, nil, "no SUPPLEMENTAL-CODECS")
        eq(types(plan.transform?(frames[0]) ?? Data()), [39, 19], "the RPU is still dropped")
        // No RPU at all (F12d): the same.
        let bare = (0..<4).map { _ in sample([clliSEI, idrSlice]) }
        guard let noRPU = self.plan(.hdr10Plus, generate: true, frames: bare) else { return }
        check(noRPU.summary.hasPrefix("HDR10 (Dolby Vision 8.1 ignoré, pas de HDR10+)"), "no RPU: summary", noRPU.summary)
        eq(noRPU.supplementalCodecs, nil, "no RPU: no SUPPLEMENTAL-CODECS")
    }

    func testAMissingL1ReusesTheLastOneUntilTheNextIRAP() {
        let rpuA = Self.realRPU
        // L1 max 3500 (2570 cd/m²) above L6 MaxCLL 2000.
        let l6Low = Block(level: 6, bits: [(4000, 16), (50, 16), (2000, 16), (400, 16)], lengthBytes: 8)
        let rpuB = Self.syntheticRPU(usePrev: false, v29: [Self.l1Block, l6Low])
        let rpuNoL1 = Self.syntheticRPU(v29: [Self.l4Block])
        let rpuCompressed = Self.syntheticRPU(compressed: true, sceneRefresh: 0, v29: [])
        let rpuNoDM = Self.syntheticRPU(sceneRefresh: 0, v29: [], dmPresent: false)
        guard let seiA = expectedMetadata(rpuA).map(H.seiNAL), let seiB = expectedMetadata(rpuB).map(H.seiNAL) else {
            return check(false, "expected SEIs")
        }
        check(seiA != seiB, "two shots, two SEIs")
        eq(expectedMetadata(rpuB)?.maxscl, [20000, 20000, 20000], "MaxSCL capped by L6 MaxCLL")

        let generator = Generator(lengthSize: 4)
        let stream: [(Data, [UInt8]?)] = [
            (sample([idrSlice, rpuA]), seiA),            // its own L1
            (sample([trailSlice, rpuNoL1]), seiA),       // no L1: the last one
            (sample([trailSlice, rpuCompressed]), seiA), // compressed DM without L1: the last one
            (sample([trailSlice, rpuNoDM]), seiA),       // no DM data at all: the last one
            (sample([trailSlice]), seiA),                // no RPU: the last one
            (sample([trailSlice, fakeRPU]), seiA),       // unreadable RPU: the last one
            (sample([trailSlice, rpuB]), seiB),          // a new shot
            (sample([craSlice, rpuNoL1]), nil),          // IRAP: memory cleared, no L1 → none
            (sample([trailSlice]), nil),                 // still none
            (sample([trailSlice, rpuB]), seiB),
            (sample([idrSlice]), nil),                   // IDR without RPU: none
        ]
        var outputs: [Data] = []
        for (index, (input, expected)) in stream.enumerated() {
            let out = generator.transform(input)
            outputs.append(out)
            check(!types(out).contains(62) && !types(out).contains(63), "frame \(index): no RPU")
            if let expected {
                eq(units(out).first, expected, "frame \(index): its SEI")
            } else {
                eq(hdr10PlusUnits(out).count, 0, "frame \(index): no HDR10+")
            }
        }
        eq(generator.fromOwnRPU, 3, "SEIs from the frame's own RPU")
        eq(generator.fromEarlierRPU, 5, "SEIs from an earlier RPU")
        eq(generator.withoutHDR10Plus, 3, "frames without HDR10+")
        eq(generator.withNativeHDR10Plus, 0, "frames with HDR10+ of their own")
        eq(generator.report, "HDR10+ from Dolby Vision: 3 sample(s) from their own RPU, 5 from an earlier one, "
           + "3 without (HDR10), 0 with the file's own · 2 SEI built, 6 reused", "the line the session logs")

        // A pass that starts at the CRA (a jump, a restart) writes the same bytes from there on.
        let fresh = Generator(lengthSize: 4)
        for index in 7..<stream.count {
            eq(fresh.transform(stream[index].0), outputs[index], "frame \(index): the same after a jump")
        }
        // The same frame twice: the same bytes.
        let again = Generator(lengthSize: 4)
        eq(again.transform(stream[0].0), outputs[0], "deterministic")
    }

    /// L6 and source_max_pq are static: kept from the last uncompressed RPU (a compressed DM
    /// never sends them, even when a block says otherwise) until the next IRAP.
    func testStaticLevelsBoundThePeak() {
        let l1: Block = .init(level: 1, bits: [(7, 12), (3696, 12), (2400, 12)], lengthBytes: 5)     // 4000 / 214 cd/m²
        let l6CLL800 = Block(level: 6, bits: [(1000, 16), (50, 16), (800, 16), (400, 16)], lengthBytes: 8)
        let source1000 = Self.syntheticRPU(usePrev: false, v29: [l1], sourceMaxPQ: 3079)            // no L6, source 1000.6 cd/m²
        let compressedWithL6 = Self.syntheticRPU(compressed: true, sceneRefresh: 0, v29: [l1, Self.l6Block])
        let withL6 = Self.syntheticRPU(usePrev: false, v29: [l1, l6CLL800])
        let compressed = Self.syntheticRPU(compressed: true, sceneRefresh: 0, v29: [l1])
        let level1 = DolbyVisionRPU.Level1(minPQ: 7, maxPQ: 3696, avgPQ: 2400)
        let l6 = DolbyVisionRPU.Level6(maxDisplayMasteringLuminance: 1000, minDisplayMasteringLuminance: 50,
                                       maxContentLightLevel: 800, maxFrameAverageLightLevel: 400)
        let bySource = H.seiNAL(for: Generator.levels(level1: level1, level6: nil, sourceMaxPQ: 3079))
        let byL6 = H.seiNAL(for: Generator.levels(level1: level1, level6: l6, sourceMaxPQ: 3696))
        let unbounded = H.seiNAL(for: Generator.levels(level1: level1, level6: nil))
        let stream: [(Data, [UInt8], Int, String)] = [
            (sample([idrSlice, source1000]), bySource, 10006, "no L6: source_max_pq bounds the 4000 cd/m² L1"),
            (sample([trailSlice, compressedWithL6]), bySource, 10006, "compressed DM: its L6 is ignored, the source peak stays"),
            (sample([trailSlice, withL6]), byL6, 8000, "L6 MaxCLL 800"),
            (sample([trailSlice, compressed]), byL6, 8000, "compressed DM: the last L6 stays"),
            (sample([craSlice, compressed]), unbounded, 39997, "IRAP: static levels forgotten, a compressed DM brings none"),
        ]
        let generator = Generator(lengthSize: 4)
        for (input, expected, maxscl, label) in stream {
            let out = generator.transform(input)
            eq(units(out).first, expected, label)
            eq(units(out).first.flatMap { H.parse(seiNAL: $0) }?.maxscl.max(), maxscl, "\(label): MaxSCL")
        }
        eq(generator.fromOwnRPU, 5, "every sample from its own L1")
    }

    func testLayoutsAndTemporalLayers() {
        // A picture of TemporalId 2: the SEI carries it too.
        let tid3Slice: [UInt8] = [0x02, 0x03, 0xD0, 0x11]
        let generator = Generator(lengthSize: 4)
        _ = generator.transform(sample([idrSlice, Self.realRPU]))
        let out = generator.transform(sample([tid3Slice, Self.realRPU]))
        eq(types(out), [39, 1], "SEI then slice")
        eq(units(out).first?.prefix(2).map { $0 }, [0x4E, 0x03], "nuh_temporal_id_plus1 of the picture")

        // 2-byte and 1-byte NAL lengths.
        let two = Generator(lengthSize: 2)
        let out2 = two.transform(sample([clliSEI, idrSlice, Self.realRPU], lengthSize: 2))
        eq(types(out2, lengthSize: 2), [39, 39, 19], "2-byte lengths")
        eq(H.parse(seiNAL: units(out2, lengthSize: 2)[1]), expectedMetadata(Self.realRPU), "2-byte lengths: parsed back")
        let small = Self.syntheticRPU(usePrev: true, v29: [Self.l1Block])
        check(small.count < 256, "a short RPU", "\(small.count)")
        let one = Generator(lengthSize: 1)
        let out1 = one.transform(sample([idrSlice, small], lengthSize: 1))
        eq(types(out1, lengthSize: 1), [39, 19], "1-byte lengths")
        eq(H.parse(seiNAL: units(out1, lengthSize: 1)[0]), expectedMetadata(small), "1-byte lengths: parsed back")

        // A sample that doesn't parse, or is empty, is left as it is.
        let broken = sample([idrSlice, Self.realRPU]).dropLast(3)
        eq(Generator(lengthSize: 4).transform(Data(broken)), Data(broken), "a broken layout stays")
        eq(Generator(lengthSize: 4).transform(Data()), Data(), "empty")
        // Nothing to drop or add: the very same sample.
        let plain = sample([trailSlice])
        eq(Generator(lengthSize: 4).transform(plain), plain, "no RPU, no L1 yet: untouched")
    }

    func testAnnexBSamples() {
        func annexB(_ units: [[UInt8]]) -> Data { Data(units.flatMap { [0, 0, 0, 1] + $0 }) }
        let frames = (0..<4).map { _ in annexB([clliSEI, idrSlice, Self.realRPU]) }
        guard let plan = plan(.hdr10Plus, generate: true, frames: frames), let transform = plan.transform else { return }
        check(plan.summary.hasPrefix("HDR10+ (converti"), "Annex B: generated", plan.summary)
        let out = transform(frames[0])
        eq(types(out), [39, 39, 19], "length-prefixed, with the SEI")
        eq(H.parse(seiNAL: units(out)[1]), expectedMetadata(Self.realRPU), "parsed back")
    }

    func testTheMasterPlaylistSignalsHDR10Plus() {
        guard let plan = plan(.hdr10Plus, generate: true, frames: dv81Frames) else { return }
        let video = MKVToHLSRemuxSession.VideoRendition(codecs: plan.codecsString, supplementalCodecs: plan.supplementalCodecs,
                                                         videoRange: plan.videoRange.rawValue, width: plan.displayWidth,
                                                         height: plan.displayHeight, frameRate: plan.frameRate, summary: plan.summary)
        let master = HLSPlaylists.master(video: video, audio: [], subtitles: [], external: [], bandwidth: 20_000_000)
        check(master.contains("SUPPLEMENTAL-CODECS=\"\(plan.codecsString)/cdm4\""), "SUPPLEMENTAL-CODECS", master)
        check(master.contains("VIDEO-RANGE=PQ"), "VIDEO-RANGE=PQ", master)
        check(master.contains("CODECS=\"\(plan.codecsString)\""), "CODECS", master)
    }

    // MARK: - F12_dv81.mkv (PT_DV_FIXTURES)

    private func fixtureURL(_ name: String) throws -> URL {
        guard let folder = ProcessInfo.processInfo.environment["PT_DV_FIXTURES"], !folder.isEmpty else {
            throw XCTSkip("set PT_DV_FIXTURES to a folder holding \(name)")
        }
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no \(name) in PT_DV_FIXTURES") }
        return url
    }

    /// The video track and every one of its frames, in file (decode) order.
    private func videoFrames(_ url: URL) -> (track: MKVTrack, frames: [MKVFrame])? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value else { return nil }
        defer { try? handle.close() }
        let demuxer = MatroskaDemuxer(reader: EBMLReader(handle: handle) { size })
        demuxer.assumeFullyDownloaded = true
        guard demuxer.parseHeaders(), let video = demuxer.tracks.first(where: { $0.kind == .video }) else { return nil }
        var frames: [MKVFrame] = []
        while let cluster = demuxer.readNextCluster() {
            frames += cluster.filter { $0.trackNumber == video.number }
        }
        return (video, frames)
    }

    /// What an output sample must be for its input: its units minus RPU / EL, one HDR10+ SEI
    /// right before the first slice, holding the mapping of the input's own RPU. nil = right.
    private func problem(output: Data, input: Data, lengthSize: Int) -> String? {
        let inUnits = units(input, lengthSize: lengthSize), outUnits = units(output, lengthSize: lengthSize)
        let outTypes = outUnits.map { ($0[0] >> 1) & 0x3F }
        if outTypes.contains(62) || outTypes.contains(63) { return "RPU / EL left" }
        let hdr10Plus = outUnits.indices.filter { RemuxCodecs.hevcNALHasHDR10Plus(outUnits[$0]) }
        guard hdr10Plus.count == 1, let seiIndex = hdr10Plus.first else { return "\(hdr10Plus.count) HDR10+ SEI" }
        guard let firstVCL = outTypes.firstIndex(where: { $0 < 32 }), firstVCL == seiIndex + 1 else { return "SEI not right before the first slice" }
        var rest = outUnits
        rest.remove(at: seiIndex)
        if rest != inUnits.filter({ let t = ($0[0] >> 1) & 0x3F; return t != 62 && t != 63 }) { return "other units changed" }
        guard let range = DolbyVisionRPU.rpuNALRange(in: input, lengthSize: lengthSize) else { return "no RPU in the input" }
        let expected = expectedMetadata([UInt8](input[range]))
        guard let parsed = H.parse(seiNAL: outUnits[seiIndex]), parsed == expected else { return "SEI ≠ mapping of the frame's RPU" }
        if !parsed.consistencyViolations.isEmpty { return "rules: \(parsed.consistencyViolations)" }
        return nil
    }

    func testEveryF12SampleThroughThePlan() throws {
        let url = try fixtureURL("F12_dv81.mkv")
        guard let loaded = videoFrames(url) else { return check(false, "F12 reads") }
        let (video, frames) = loaded
        eq(frames.count, 719, "F12's video frames")
        let samples = frames.map(\.data)
        let lengthSize = (RemuxCodecs.HvcCRecord(bytes: [UInt8](video.codecPrivate))?.lengthSize) ?? 4
        guard case .success(let plan) = RemuxCodecs.makeVideoPlan(track: video, sampleFrames: Array(samples.prefix(10)), releaseHintsHDR: false,
                                                                  dolbyVisionMode: .hdr10Plus, hdr10PlusFromDolbyVision: true),
              let transform = plan.transform else { return check(false, "an HDR10+ plan with a transform") }
        check(plan.summary.hasPrefix("HDR10+ (converti depuis Dolby Vision 8.1)"), "summary", plan.summary)
        eq(plan.supplementalCodecs, plan.codecsString + "/cdm4", "SUPPLEMENTAL-CODECS")
        eq(plan.videoRange, .pq, "PQ")
        check(!hasBox(plan.sampleEntry, "dvvC"), "no dvvC")

        var problems: [String] = []
        var averagePQ: [Int] = []
        var seis = Set<[UInt8]>()
        for (index, input) in samples.enumerated() {
            let output = transform(input)
            if let problem = problem(output: output, input: input, lengthSize: lengthSize) { problems.append("frame \(index): \(problem)") }
            if let range = DolbyVisionRPU.rpuNALRange(in: input, lengthSize: lengthSize),
               let level1 = DolbyVisionRPU.parse(nal: input[range])?.level1 {
                averagePQ.append(Int(level1.avgPQ))
            }
            if let sei = hdr10PlusUnits(output, lengthSize: lengthSize).first {
                seis.insert(sei)
                if let parsed = H.parse(seiNAL: sei), parsed.maxscl != [10006, 10006, 10006] { problems.append("frame \(index): MaxSCL \(parsed.maxscl)") }
            }
        }
        check(problems.isEmpty, "every sample: no RPU, one HDR10+ SEI before the first slice, the mapping of its RPU",
              problems.prefix(5).joined(separator: "; "))
        // L1 avg_pq moves within 1148…1156 at frames 97, 99, 100, 145…; each sample got the SEI of its own.
        eq(averagePQ.count, 719, "an L1 in every RPU")
        let changes = averagePQ.indices.dropFirst().filter { averagePQ[$0] != averagePQ[$0 - 1] }
        eq(Array(changes.prefix(4)), [97, 99, 100, 145], "L1 change points")
        eq(Set(averagePQ).count, 9, "nine distinct L1 averages")
        check((1...9).contains(seis.count), "one SEI per distinct L1 at most", "\(seis.count)")
    }

    func testTheOtherDolbyVisionFixtures() throws {
        _ = try fixtureURL("F12_dv81.mkv")
        func make(_ name: String) -> RemuxVideoPlan? {
            guard let url = try? fixtureURL(name), let loaded = videoFrames(url) else { return nil }
            if case .success(let plan) = RemuxCodecs.makeVideoPlan(track: loaded.track, sampleFrames: Array(loaded.frames.prefix(10).map(\.data)),
                                                                   releaseHintsHDR: false, dolbyVisionMode: .hdr10Plus,
                                                                   hdr10PlusFromDolbyVision: true) {
                return plan
            }
            return nil
        }
        if let noRPU = make("F12d_dv81_no_rpu.mkv") {
            check(noRPU.summary.hasPrefix("HDR10 (Dolby Vision 8.1 ignoré, pas de HDR10+)"), "F12d: HDR10", noRPU.summary)
            eq(noRPU.supplementalCodecs, nil, "F12d: no SUPPLEMENTAL-CODECS")
        }
        if let hdr10 = make("F02_hevc10_pq_eac3_51.mkv") {
            eq(hdr10.codec, .hevc, "F02: HEVC")
            eq(hdr10.supplementalCodecs, nil, "F02: nothing to signal")
            eq(hdr10.transform == nil, true, "F02: samples untouched")
        }
        if let hlg = make("F12a_dv84_hlg_real.mkv") { eq(hlg.codec, .dolbyVision(profile: 8, level: hlg.codec.level, compatibilityID: 4), "F12a: still 8.4") }
        if let five = make("F12b_dv5.mkv") { eq(five.codec, .dolbyVision(profile: 5, level: five.codec.level, compatibilityID: 0), "F12b: still 5") }
    }

    /// A whole session on F12, as the app runs it on tvOS (HDR10+ asked for, generation on): the
    /// segments it writes, read back sample by sample. With PT_HDR10P_DUMP_DIR, kept there.
    func testAWholeF12Session() throws {
        let url = try fixtureURL("F12_dv81.mkv")
        guard let loaded = videoFrames(url) else { return check(false, "F12 reads") }
        let (video, frames) = loaded
        let lengthSize = (RemuxCodecs.HvcCRecord(bytes: [UInt8](video.codecPrivate))?.lengthSize) ?? 4

        let output: URL
        var temporary: URL?
        if let dump = ProcessInfo.processInfo.environment["PT_HDR10P_DUMP_DIR"], !dump.isEmpty {
            output = URL(fileURLWithPath: dump).appendingPathComponent("F12_dv81-hdr10plus", isDirectory: true)
            try? FileManager.default.removeItem(at: output)
        } else {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PopcornTimeTests-hdr10p-\(UUID().uuidString)", isDirectory: true)
            temporary = folder
            output = folder
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        guard let session = try readySession(url, output: output), let rendition = session.video else { return }
        drain(session)
        session.finish()
        check(session.writeFailure == nil, "no write failure")

        check(rendition.summary.hasPrefix("HDR10+ (converti depuis Dolby Vision 8.1)"), "summary", rendition.summary)
        eq(rendition.supplementalCodecs, rendition.codecs + "/cdm4", "SUPPLEMENTAL-CODECS")
        let master = HLSPlaylists.master(video: rendition, audio: session.audioRenditions, subtitles: session.subtitleRenditions,
                                         external: [], bandwidth: max(1, session.bandwidthEstimate))
        check(master.contains("SUPPLEMENTAL-CODECS=\"\(rendition.codecs)/cdm4\"") && master.contains("VIDEO-RANGE=PQ"), "master playlist", master)

        let initSegment = (try? Data(contentsOf: output.appendingPathComponent("video_init.mp4"))) ?? Data()
        check(initSegment.count > 32 && initSegment.prefix(32).range(of: Data("cdm4".utf8)) != nil, "'cdm4' in the init segment's ftyp")
        check(!hasBox(initSegment, "dvvC") && !hasBox(initSegment, "dby1"), "no Dolby Vision signalling in the init segment")

        // The video segments in playlist order, their samples in decode order.
        let playlist = session.mediaPlaylist(named: rendition.playlistName) ?? ""
        let names = playlist.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var samples: [Data] = []
        for name in names {
            guard let segment = try? Data(contentsOf: output.appendingPathComponent(name)) else { check(false, "\(name) exists"); continue }
            samples += Self.fragmentSamples(segment)
        }
        check(samples.count >= frames.count, "every frame is in the segments", "\(samples.count) samples for \(frames.count) frames")
        var problems: [String] = []
        for (index, frame) in frames.enumerated() where index < samples.count {
            if let problem = problem(output: samples[index], input: frame.data, lengthSize: lengthSize) {
                problems.append("sample \(index): \(problem)")
            }
        }
        // Tail fillers repeat the last keyframe as written: HDR10+ included.
        for index in frames.count..<max(frames.count, samples.count) where hdr10PlusUnits(samples[index], lengthSize: lengthSize).count != 1 {
            problems.append("filler \(index): no HDR10+")
        }
        check(problems.isEmpty, "every written sample: no RPU, one HDR10+ SEI before the first slice, the mapping of its RPU",
              problems.prefix(5).joined(separator: "; "))

        guard temporary == nil else { return }
        // The dump: what the HLS server serves, plus what other tools read.
        do {
            try master.write(to: output.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
            var playlistNames = [rendition.playlistName]
            playlistNames += session.audioRenditions.map(\.playlistName)
            playlistNames += session.subtitleRenditions.map(\.playlistName)
            for name in playlistNames {
                try (session.mediaPlaylist(named: name) ?? "").write(to: output.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            // Annex B elementary stream of the written video (parameter sets before every IRAP), for
            // hdr10plus_tool / ffprobe; the source's RPUs stay readable from F12_dv81.mkv itself.
            let record = RemuxCodecs.HvcCRecord(bytes: [UInt8](video.codecPrivate))
            let parameterSets = (record?.arrays ?? []).filter { [32, 33, 34].contains($0.type) }.flatMap(\.units)
            var annexB = Data()
            for sample in samples {
                let sampleUnits = units(sample, lengthSize: lengthSize)
                if sampleUnits.contains(where: { (16...23).contains(($0[0] >> 1) & 0x3F) }) {
                    for unit in parameterSets { annexB.append(contentsOf: [0, 0, 0, 1] + unit) }
                }
                for unit in sampleUnits { annexB.append(contentsOf: [0, 0, 0, 1] + unit) }
            }
            try annexB.write(to: output.appendingPathComponent("video.hevc"))
            // Per frame (decode order): the source RPU's L1 and the HDR10+ written.
            var rows = ["frame\tl1_min_pq\tl1_avg_pq\tl1_max_pq\ttsdml\tmaxscl\taverage_maxrgb\tpercentiles\tknee_x\tknee_y\tanchors"]
            for (index, frame) in frames.enumerated() where index < samples.count {
                let l1 = DolbyVisionRPU.rpuNALRange(in: frame.data, lengthSize: lengthSize)
                    .flatMap { DolbyVisionRPU.parse(nal: frame.data[$0]) }?.level1
                let written = hdr10PlusUnits(samples[index], lengthSize: lengthSize).first.flatMap { H.parse(seiNAL: $0) }
                rows.append(Self.row(index, level1: l1, written: written))
            }
            try (rows.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("frames.tsv"), atomically: true, encoding: .utf8)
            let contents = """
            F12_dv81.mkv remuxed with « Dolby Vision 8.1 » on HDR10+ and HDR10+ generated from the RPUs (the tvOS setting).
            master.m3u8, video.m3u8, a*/s* playlists: as the HLS server serves them (playlists frozen by the session).
            video_init.mp4 + vseg*.m4s, audio*_init.mp4 + a*seg*.m4s: the fMP4 segments, byte for byte.
            video.hevc: the written video samples as an Annex B stream (VPS/SPS/PPS before every IRAP).
            frames.tsv: per frame in decode order, the source RPU's L1 and the HDR10+ metadata written for it.
            \(frames.count) frames, \(samples.count) written video samples (tail fillers repeat the last keyframe).

            """
            try contents.write(to: output.appendingPathComponent("CONTENTS.txt"), atomically: true, encoding: .utf8)
        } catch {
            check(false, "the dump is written", "\(error)")
        }
    }

    /// One line of frames.tsv ("-" for what is missing).
    private static func row(_ index: Int, level1: DolbyVisionRPU.Level1?, written: H.Metadata?) -> String {
        var fields = [String(index)]
        if let level1 {
            fields += [String(level1.minPQ), String(level1.avgPQ), String(level1.maxPQ)]
        } else {
            fields += ["-", "-", "-"]
        }
        if let written {
            let distribution: [String] = written.distribution.map { "\($0.percentage):\($0.value)" }
            fields.append(String(written.targetedSystemDisplayMaximumLuminance))
            fields.append(written.maxscl.map { String($0) }.joined(separator: ","))
            fields.append(String(written.averageMaxRGB))
            fields.append(distribution.joined(separator: ","))
            if let curve = written.toneMapping {
                fields += [String(curve.kneePointX), String(curve.kneePointY), curve.anchors.map { String($0) }.joined(separator: ",")]
            } else {
                fields += ["-", "-", "-"]
            }
        } else {
            fields += Array(repeating: "-", count: 7)
        }
        return fields.joined(separator: "\t")
    }

    /// A session on `url` as the app makes it on tvOS with HDR10+ asked for, prepared.
    private func readySession(_ url: URL, output: URL, file: StaticString = #filePath, line: Int = #line) throws -> MKVToHLSRemuxSession? {
        var options = MKVToHLSRemuxSession.Options()
        options.dolbyVisionMode = .hdr10Plus
        options.hdr10PlusFromDolbyVision = true
        let session = try MKVToHLSRemuxSession(inputFile: url, outputDirectory: output, options: options)
        session.markInputComplete()
        var result = session.prepare()
        var tries = 0
        while result == .needMoreData, tries < 50 { result = session.prepare(); tries += 1 }
        check(result == .ready, "the session is ready", "\(result)", file: file, line: line)
        return result == .ready ? session : nil
    }

    /// Pumps like `RemuxPlayback.tick` until nothing more comes.
    private func drain(_ session: MKVToHLSRemuxSession) {
        var idle = 0, calls = 0
        while idle < 3, calls < 10_000, session.writeFailure == nil {
            let written = session.pump(maxNewSegments: 2)
            calls += 1
            idle = (written == 0 && !session.stoppedAtInputBudget) ? idle + 1 : 0
        }
    }

    /// A segment written after a jump holds the bytes the pass in file order writes there:
    /// the generator's memory starts over at the keyframe the jump lands on.
    func testAJumpWritesTheSameHDR10PlusBytes() throws {
        let url = try fixtureURL("F12_dv81.mkv")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PopcornTimeTests-hdr10p-jump-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inOrder = root.appendingPathComponent("in-order", isDirectory: true), jumped = root.appendingPathComponent("jumped", isDirectory: true)
        guard let reference = try readySession(url, output: inOrder) else { return }
        drain(reference)
        reference.finish()

        guard let session = try readySession(url, output: jumped) else { return }
        var written = 0, calls = 0
        while written < 2, calls < 100 { written += session.pump(maxNewSegments: 2 - written); calls += 1 }
        guard session.freezePlaylistFromPlan(), session.jumpCapability == .available else {
            throw XCTSkip("F12: no jump available (\(session.jumpCapability))")
        }
        var target = 2
        while session.jumpTarget(forSegment: target + 1) != nil { target += 1 }
        check(session.jump(toSegment: target) != nil, "the pass moves to segment \(target)")
        drain(session)
        session.finish()
        let name = "vseg\(target).m4s"
        let expected = try? Data(contentsOf: inOrder.appendingPathComponent(name))
        let got = try? Data(contentsOf: jumped.appendingPathComponent(name))
        check(expected != nil && expected == got, "\(name): the same bytes after a jump")
        if let got {
            let samples = Self.fragmentSamples(got)
            check(!samples.isEmpty && samples.allSatisfy { hdr10PlusUnits($0).count == 1 }, "\(name): HDR10+ in every sample")
        }
    }

    /// The samples of a one-track fMP4 media segment (moof/traf/trun sizes, then the mdat).
    static func fragmentSamples(_ segment: Data) -> [Data] {
        let b = [UInt8](segment)
        func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        func boxes(_ range: Range<Int>) -> [(type: String, start: Int, body: Range<Int>)] {
            var out: [(String, Int, Range<Int>)] = []
            var pos = range.lowerBound
            while pos + 8 <= range.upperBound {
                let size = u32(pos)
                guard size >= 8, pos + size <= range.upperBound else { break }
                out.append((String(decoding: b[(pos + 4)..<(pos + 8)], as: UTF8.self), pos, (pos + 8)..<(pos + size)))
                pos += size
            }
            return out
        }
        let top = boxes(0..<b.count)
        guard let moof = top.first(where: { $0.type == "moof" }),
              let traf = boxes(moof.body).first(where: { $0.type == "traf" }),
              let trun = boxes(traf.body).first(where: { $0.type == "trun" }) else { return [] }
        let flags = u32(trun.body.lowerBound) & 0xFFFFFF
        let count = u32(trun.body.lowerBound + 4)
        var pos = trun.body.lowerBound + 8
        var dataOffset = 0
        if flags & 0x1 != 0 { dataOffset = u32(pos); pos += 4 }
        if flags & 0x4 != 0 { pos += 4 }
        var sizes: [Int] = []
        for _ in 0..<count {
            if flags & 0x100 != 0 { pos += 4 }
            if flags & 0x200 != 0 { sizes.append(u32(pos)); pos += 4 }
            if flags & 0x400 != 0 { pos += 4 }
            if flags & 0x800 != 0 { pos += 4 }
        }
        var start = moof.start + dataOffset
        var samples: [Data] = []
        for size in sizes where start + size <= b.count {
            samples.append(segment.subdata(in: start..<(start + size)))
            start += size
        }
        return samples
    }
}

private extension RemuxVideoPlan.Codec {
    var level: Int {
        if case .dolbyVision(_, let level, _) = self { return level }
        return -1
    }
}
