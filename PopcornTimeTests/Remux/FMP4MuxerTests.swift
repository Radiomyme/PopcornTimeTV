//
//  FMP4MuxerTests.swift
//  PopcornTimeTests
//
//  FMP4Muxer.mediaSegment: the moof + mdat of a segment, now assembled in one buffer (each
//  sample copied once). The layout must be what it was: moof, an mdat holding every sample in
//  track order, and data offsets that point at them.
//

import XCTest
import Foundation

final class FMP4MuxerTests: CheckedTestCase {

    private func u32(_ data: Data, _ offset: Int) -> Int {
        let bytes = [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + 4])
        return Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
    }

    /// The children of a box body: (type, body range).
    private func boxes(_ data: Data, _ range: Range<Int>) -> [(type: String, body: Range<Int>)] {
        var result: [(String, Range<Int>)] = []
        var position = range.lowerBound
        while position + 8 <= range.upperBound {
            let size = u32(data, position)
            guard size >= 8, position + size <= range.upperBound else { break }
            let type = String(decoding: data[data.startIndex + position + 4 ..< data.startIndex + position + 8], as: UTF8.self)
            result.append((type, position + 8 ..< position + size))
            position += size
        }
        return result
    }

    private func sample(_ byte: UInt8, _ count: Int, sync: Bool = true, offset: Int32 = 0) -> FMP4Muxer.Sample {
        FMP4Muxer.Sample(data: Data(repeating: byte, count: count), duration: 3000, sync: sync, compositionOffset: offset)
    }

    private let video = FMP4Muxer.TrackConfig(trackID: 1, timescale: 90_000, handler: .video, width: 320, height: 240,
                                              language: "und", sampleEntry: Data([0, 0, 0, 8, 0x61, 0x76, 0x63, 0x31]))
    private let audio = FMP4Muxer.TrackConfig(trackID: 2, timescale: 48_000, handler: .audio, width: 0, height: 0,
                                              language: "und", sampleEntry: Data([0, 0, 0, 8, 0x6D, 0x70, 0x34, 0x61]))

    func testSegmentLayout() {
        let videoSamples = [sample(0xA1, 700), sample(0xA2, 300, sync: false, offset: 3000), sample(0xA3, 50, sync: false, offset: -3000)]
        let audioSamples = [sample(0xB1, 32), sample(0xB2, 48)]
        let segment = FMP4Muxer.mediaSegment(sequence: 7, trackSamples: [(video, 90_000, videoSamples), (audio, 48_000, audioSamples)])

        let top = boxes(segment, 0..<segment.count)
        eq(top.map { $0.type }, ["moof", "mdat"], "a moof, then one mdat")
        guard top.count == 2 else { return }
        let moofSize = top[0].body.upperBound
        let payload = videoSamples.reduce(0) { $0 + $1.data.count } + audioSamples.reduce(0) { $0 + $1.data.count }
        eq(top[1].body.count, payload, "the mdat holds exactly the samples")
        eq(segment.count, moofSize + 8 + payload, "nothing else in the segment")

        // The samples, in track order then sample order, byte for byte.
        var expected = Data()
        for sample in videoSamples + audioSamples { expected.append(sample.data) }
        check(segment.subdata(in: top[1].body) == expected, "every sample is in the mdat, in order")

        // Each track's data offset (from the moof's start) points at its first sample.
        let trafs = boxes(segment, top[0].body).filter { $0.type == "traf" }
        eq(trafs.count, 2, "one traf per track")
        var offsets: [Int] = []
        var counts: [Int] = []
        for traf in trafs {
            guard let trun = boxes(segment, traf.body).first(where: { $0.type == "trun" }) else { continue }
            counts.append(u32(segment, trun.body.lowerBound + 4))
            offsets.append(u32(segment, trun.body.lowerBound + 8))
        }
        eq(counts, [3, 2], "the sample counts")
        eq(offsets, [moofSize + 8, moofSize + 8 + 1050], "the data offsets: past the mdat header, the audio after the video")
        check(offsets.count == 2 && segment[offsets[0]] == 0xA1 && segment[offsets[1]] == 0xB1, "they point at the first samples")
        let mfhd = boxes(segment, top[0].body).first { $0.type == "mfhd" }
        eq(mfhd.map { u32(segment, $0.body.lowerBound + 4) }, 7, "the sequence number")
    }

    func testATrackWithoutSampleAndAnEmptySegment() {
        let segment = FMP4Muxer.mediaSegment(sequence: 1, trackSamples: [(video, 0, [sample(0xC1, 10)]), (audio, 0, [])])
        let top = boxes(segment, 0..<segment.count)
        check(top.map { $0.type } == ["moof", "mdat"] && top.last?.body.count == 10, "a track without sample adds nothing to the mdat")
        let empty = FMP4Muxer.mediaSegment(sequence: 1, trackSamples: [(video, 0, [])])
        let parts = boxes(empty, 0..<empty.count)
        check(parts.map { $0.type } == ["moof", "mdat"] && parts.last?.body.count == 0, "no sample at all: an empty mdat, no crash")
    }

    func testManySamplesKeepTheirBytes() {
        // A segment the size of a real one's sample table: 144 samples of growing sizes.
        let samples = (0..<144).map { sample(UInt8(truncatingIfNeeded: $0 &+ 1), 1000 + $0 * 7, sync: $0 == 0) }
        let segment = FMP4Muxer.mediaSegment(sequence: 2, trackSamples: [(video, 0, samples)])
        let top = boxes(segment, 0..<segment.count)
        guard top.count == 2 else { return check(false, "moof + mdat") }
        var position = top[1].body.lowerBound
        var intact = true
        for sample in samples {
            intact = intact && segment.subdata(in: position ..< position + sample.data.count) == sample.data
            position += sample.data.count
        }
        check(intact && position == segment.count, "144 samples, each where the sample table says")
    }
}
