//
//  DolbyVisionPlaybackModeTests.swift
//  PopcornTimeTests
//
//  « Dolby Vision 8.1 » (Settings): a Dolby Vision profile 8 stream with an HDR10 base plays
//  as Dolby Vision (signalled, RPUs kept), as HDR10 (no DV signalling, RPUs and HDR10+
//  dynamic metadata dropped, a steady picture) or as HDR10+ (no DV, HDR10+ kept when the
//  file has it). Plus the SEI rewriting behind it. With PT_DV_FIXTURES set to a folder
//  holding F12_dv81.mkv (format-coverage fixtures), the same on real samples.
//

import XCTest
import Foundation

final class DolbyVisionPlaybackModeTests: CheckedTestCase {

    // MARK: Streams

    /// DOVIDecoderConfigurationRecord: version 1.0, `profile`, level 6, RPU + BL, `compat`.
    private func dvRecord(profile: Int, compat: Int) -> Data {
        let level = 6
        let b2 = UInt8(profile << 1 | (level >> 5))
        let b3 = UInt8((level & 0x1F) << 3 | 0x04 | 0x01)
        return Data([1, 0, b2, b3, UInt8(compat << 4)] + [UInt8](repeating: 0, count: 19))
    }

    private func track(profile: Int = 8, compat: Int = 1) -> MKVTrack {
        var track = MKVTrack()
        track.number = 1
        track.kind = .video
        track.codecID = "V_MPEGH/ISO/HEVC"
        track.codecPrivate = Data(SyntheticMatroska.hvcC)
        track.pixelWidth = 3840
        track.pixelHeight = 2160
        track.defaultDurationNs = 41_708_333
        var mapping = MKVBlockAdditionMapping()
        mapping.idType = profile <= 7 ? 0x64766343 : 0x64767643
        mapping.extraData = dvRecord(profile: profile, compat: compat)
        track.blockAdditionMappings = [mapping]
        return track
    }

    /// HDR10+ T.35 message payload (header + a few metadata bytes, one with 00 00 01).
    private let hdr10PlusPayload: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01, 0x40, 0x00, 0x00, 0x01, 0x7F]
    /// Another registered T.35 message (not HDR10+): kept.
    private let otherT35Payload: [UInt8] = [0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34]
    /// Content light level (SEI 144).
    private let clliPayload: [UInt8] = [0x03, 0xE8, 0x01, 0x90]

    private func seiNAL(_ messages: [(Int, [UInt8])]) -> [UInt8] {
        var rbsp: [UInt8] = []
        for (type, payload) in messages {
            rbsp.append(UInt8(type))
            rbsp.append(UInt8(payload.count))
            rbsp += payload
        }
        rbsp.append(0x80)
        return [0x4E, 0x01] + RemuxCodecs.escapeRBSP(rbsp)          // prefix SEI, layer 0, tid 1
    }

    private let idrSlice: [UInt8] = [0x26, 0x01, 0xAF, 0x12, 0x34, 0x56]   // IDR_W_RADL
    private let rpu: [UInt8] = [0x7C, 0x01, 0x19, 0x08, 0x09, 0x00, 0x00, 0x03, 0x01]  // NAL 62

    private func sample(_ units: [[UInt8]]) -> Data {
        var out = Data()
        for unit in units {
            let n = UInt32(unit.count)
            out.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            out.append(contentsOf: unit)
        }
        return out
    }

    private func units(_ frame: Data) -> [[UInt8]] {
        var result: [[UInt8]] = []
        let b = [UInt8](frame)
        var pos = 0
        while pos + 4 <= b.count {
            let n = Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
            pos += 4
            guard pos + n <= b.count else { break }
            result.append(Array(b[pos..<(pos + n)]))
            pos += n
        }
        return result
    }

    private func types(_ frame: Data) -> [UInt8] { units(frame).map { ($0[0] >> 1) & 0x3F } }

    private func frames(hdr10Plus: Bool) -> [Data] {
        let sei = seiNAL(hdr10Plus ? [(4, hdr10PlusPayload), (144, clliPayload)] : [(144, clliPayload)])
        return (0..<4).map { _ in sample([sei, idrSlice, rpu]) }
    }

    private func plan(_ mode: DolbyVisionPlaybackMode, hdr10Plus: Bool = true,
                      profile: Int = 8, compat: Int = 1) -> RemuxVideoPlan? {
        switch RemuxCodecs.makeVideoPlan(track: track(profile: profile, compat: compat),
                                         sampleFrames: frames(hdr10Plus: hdr10Plus), releaseHintsHDR: false,
                                         dolbyVisionMode: mode) {
        case .success(let plan): return plan
        case .failure(let error):
            check(false, "plan: \(error)")
            return nil
        }
    }

    private func hasBox(_ entry: Data, _ fourCC: String) -> Bool {
        entry.range(of: Data(fourCC.utf8)) != nil
    }

    // MARK: The three modes

    func testDolbyVisionKeepsTheSignallingAndTheRPUs() {
        guard let plan = plan(.dolbyVision) else { return }
        eq(plan.codec, .dolbyVision(profile: 8, level: 6, compatibilityID: 1), "codec")
        eq(plan.supplementalCodecs, "dvh1.08.06/db1p", "SUPPLEMENTAL-CODECS")
        check(hasBox(plan.sampleEntry, "dvvC"), "dvvC in the sample entry")
        let out = plan.transform?(frames(hdr10Plus: true)[0]) ?? frames(hdr10Plus: true)[0]
        check(types(out).contains(62), "the RPU stays")
        check(RemuxCodecs.hevcNALHasHDR10Plus(units(out)[0]), "HDR10+ stays")
    }

    func testHDR10DropsDolbyVisionAndHDR10Plus() {
        guard let plan = plan(.hdr10) else { return }
        eq(plan.codec, .hevc, "plain HEVC")
        eq(plan.supplementalCodecs, nil, "no SUPPLEMENTAL-CODECS")
        eq(plan.videoRange, .pq, "VIDEO-RANGE=PQ")
        check(!hasBox(plan.sampleEntry, "dvvC") && !hasBox(plan.sampleEntry, "dvcC"), "no DV configuration box")
        check(hasBox(plan.sampleEntry, "colr"), "colr kept")
        check(plan.summary.hasPrefix("HDR10 (Dolby Vision 8.1 ignoré)"), "summary: \(plan.summary)")
        guard let transform = plan.transform else { return check(false, "a transform") }
        let out = transform(frames(hdr10Plus: true)[0])
        eq(types(out), [39, 19], "SEI (without HDR10+) + slice, no RPU")
        let sei = units(out)[0]
        check(!RemuxCodecs.hevcNALHasHDR10Plus(sei), "no HDR10+ left")
        let messages = RemuxCodecs.seiMessages(rbsp: unescape(sei))
        eq(messages, [RemuxCodecs.SEIMessage(type: 144, payload: clliPayload)], "the CLL message stays")
        eq(units(out)[1], idrSlice, "the slice is untouched")
    }

    func testHDR10PlusKeepsItsMetadataWithoutDolbyVision() {
        guard let plan = plan(.hdr10Plus) else { return }
        eq(plan.codec, .hevc, "plain HEVC")
        eq(plan.supplementalCodecs, nil, "no SUPPLEMENTAL-CODECS")
        check(!hasBox(plan.sampleEntry, "dvvC"), "no dvvC")
        check(plan.summary.hasPrefix("HDR10+ (Dolby Vision 8.1 ignoré)"), "summary: \(plan.summary)")
        let input = frames(hdr10Plus: true)[0]
        let out = plan.transform?(input) ?? input
        eq(types(out), [39, 19], "no RPU")
        eq(units(out)[0], units(input)[0], "the SEI is byte-identical")
    }

    func testHDR10PlusWithoutItsMetadataSaysHDR10() {
        guard let plan = plan(.hdr10Plus, hdr10Plus: false) else { return }
        eq(plan.codec, .hevc, "plain HEVC")
        check(plan.summary.hasPrefix("HDR10 (Dolby Vision 8.1 ignoré, pas de HDR10+)"), "summary: \(plan.summary)")
    }

    func testOtherProfilesIgnoreTheSetting() {
        // Profile 8.4 (HLG base) and profile 5 (no HDR10 base) stay Dolby Vision.
        guard let hlg = plan(.hdr10, compat: 4), let five = plan(.hdr10, profile: 5, compat: 0) else { return }
        eq(hlg.codec, .dolbyVision(profile: 8, level: 6, compatibilityID: 4), "8.4 stays DV")
        eq(five.codec, .dolbyVision(profile: 5, level: 6, compatibilityID: 0), "5 stays DV")
    }

    func testTheSettingIsStoredDeviceWide() {
        let defaults = UserDefaults(suiteName: "DolbyVisionPlaybackModeTests")!
        defaults.removePersistentDomain(forName: "DolbyVisionPlaybackModeTests")
        eq(DolbyVisionPlaybackMode.stored(in: defaults), .automatic, "absent = automatic")
        DolbyVisionPlaybackMode.hdr10.store(in: defaults)
        eq(defaults.string(forKey: "dolbyVision81Playback"), "hdr10", "key")
        eq(DolbyVisionPlaybackMode.stored(in: defaults), .hdr10, "read back")
        DolbyVisionPlaybackMode.dolbyVision.store(in: defaults)
        eq(defaults.string(forKey: "dolbyVision81Playback"), "dolbyVision", "Dolby Vision is kept as a choice")
        DolbyVisionPlaybackMode.automatic.store(in: defaults)
        eq(defaults.object(forKey: "dolbyVision81Playback") == nil, true, "the default removes the key")
        defaults.set("bogus", forKey: "dolbyVision81Playback")
        eq(DolbyVisionPlaybackMode.stored(in: defaults), .automatic, "unknown = automatic")
        eq(DolbyVisionPlaybackMode.automatic.resolved(displaySupportsDolbyVision: true), .dolbyVision, "a Dolby Vision TV")
        eq(DolbyVisionPlaybackMode.automatic.resolved(displaySupportsDolbyVision: false), .hdr10Plus, "another HDR TV")
        eq(DolbyVisionPlaybackMode.hdr10.resolved(displaySupportsDolbyVision: true), .hdr10, "a choice stays")
        defaults.removePersistentDomain(forName: "DolbyVisionPlaybackModeTests")
    }

    // MARK: SEI rewriting

    private func unescape(_ nal: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for byte in nal.dropFirst(2) {
            if zeros >= 2, byte == 3 { zeros = 0; continue }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    func testEmulationPreventionRoundTrips() {
        let rbsp: [UInt8] = [0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x02, 0xFF, 0x80]
        let escaped = RemuxCodecs.escapeRBSP(rbsp)
        eq(escaped, [0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x03,
                     0x00, 0x00, 0x03, 0x02, 0xFF, 0x80], "escaped")
        eq(unescape([0x4E, 0x01] + escaped), rbsp, "round trip")
    }

    func testAnSEIWithOnlyHDR10PlusGoes() {
        let sei = seiNAL([(4, hdr10PlusPayload)])
        check(RemuxCodecs.hevcNALHasHDR10Plus(sei), "detected")
        check(RemuxCodecs.hevcSEIWithoutHDR10Plus(sei) == nil, "nothing left: the NAL goes")
        let frame = sample([sei, idrSlice])
        eq(types(RemuxCodecs.strippingHDR10Plus(frame, lengthSize: 4)), [19], "only the slice stays")
    }

    func testAMixedSEIKeepsTheOtherMessages() {
        let sei = seiNAL([(144, clliPayload), (4, hdr10PlusPayload), (4, otherT35Payload)])
        guard let kept = RemuxCodecs.hevcSEIWithoutHDR10Plus(sei) else { return check(false, "a NAL remains") }
        eq(Array(kept.prefix(2)), [0x4E, 0x01], "NAL header kept")
        eq(RemuxCodecs.seiMessages(rbsp: unescape(kept)),
           [RemuxCodecs.SEIMessage(type: 144, payload: clliPayload), RemuxCodecs.SEIMessage(type: 4, payload: otherT35Payload)],
           "CLL and the other T.35 message stay, in order")
        eq(kept, seiNAL([(144, clliPayload), (4, otherT35Payload)]), "the same bytes as a NAL written without it")
    }

    func testAFrameWithoutHDR10PlusIsUntouched() {
        let frame = sample([seiNAL([(144, clliPayload)]), idrSlice, rpu])
        eq(RemuxCodecs.strippingHDR10Plus(frame, lengthSize: 4), frame, "same bytes")
        let broken = frame.prefix(frame.count - 3)
        eq(RemuxCodecs.strippingHDR10Plus(broken, lengthSize: 4), broken, "a layout that doesn't parse stays")
    }

    // MARK: Real samples (PT_DV_FIXTURES)

    func testARealDolbyVision81Stream() throws {
        guard let folder = ProcessInfo.processInfo.environment["PT_DV_FIXTURES"], !folder.isEmpty else {
            throw XCTSkip("set PT_DV_FIXTURES to a folder holding F12_dv81.mkv")
        }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("F12_dv81.mkv")
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value else {
            throw XCTSkip("no F12_dv81.mkv in PT_DV_FIXTURES")
        }
        defer { try? handle.close() }
        let demuxer = MatroskaDemuxer(reader: EBMLReader(handle: handle) { size })
        demuxer.assumeFullyDownloaded = true
        guard demuxer.parseHeaders(), let video = demuxer.tracks.first(where: { $0.kind == .video }) else {
            return check(false, "the headers parse")
        }
        var samples: [Data] = []
        while samples.count < 48, let cluster = demuxer.readNextCluster() {
            samples += cluster.filter { $0.trackNumber == video.number }.map(\.data)
        }
        check(samples.count >= 12, "frames read: \(samples.count)")
        let withRPU = samples.filter { types($0).contains(62) }.count
        check(withRPU > 0, "the fixture carries RPUs (\(withRPU))")

        func make(_ mode: DolbyVisionPlaybackMode) -> RemuxVideoPlan? {
            if case .success(let plan) = RemuxCodecs.makeVideoPlan(track: video, sampleFrames: Array(samples.prefix(12)),
                                                                   releaseHintsHDR: false, dolbyVisionMode: mode) {
                return plan
            }
            check(false, "\(mode) plan")
            return nil
        }
        guard let dv = make(.dolbyVision), let hdr10 = make(.hdr10), let hdr10Plus = make(.hdr10Plus) else { return }
        eq(dv.codec, .dolbyVision(profile: 8, level: dv.codec.dvLevel, compatibilityID: 1), "DV 8.1 by default")
        check(dv.supplementalCodecs?.hasPrefix("dvh1.08.") == true, "SUPPLEMENTAL-CODECS")
        for plan in [hdr10, hdr10Plus] {
            eq(plan.codec, .hevc, "plain HEVC")
            eq(plan.supplementalCodecs, nil, "no SUPPLEMENTAL-CODECS")
            eq(plan.videoRange, .pq, "PQ")
            check(!hasBox(plan.sampleEntry, "dvvC"), "no dvvC")
            guard let transform = plan.transform else { check(false, "a transform"); continue }
            for (index, frame) in samples.enumerated() {
                let out = transform(frame)
                check(!types(out).contains(62) && !types(out).contains(63), "frame \(index): no RPU / EL")
                eq(types(out), types(frame).filter { $0 != 62 && $0 != 63 }, "frame \(index): the other NAL units stay")
            }
        }
        check(hdr10.summary.hasPrefix("HDR10 (Dolby Vision 8.1 ignoré"), "summary: \(hdr10.summary)")
    }
}

private extension RemuxVideoPlan.Codec {
    var dvLevel: Int {
        if case .dolbyVision(_, let level, _) = self { return level }
        return -1
    }
}
