//
//  SpeechActivityDetectorTests.swift
//  PopcornTimeTests
//
//  The speech reference of the automatic subtitle sync (`SpeechActivityDetector`), ported from
//  its harness: synthetic dialogue (voiced harmonics at a syllable rate) under music, read from
//  the channel the layout's labels say carries it; hostile input; and, with PT_SUBSYNC_FIXTURES
//  set to the folder of the format-coverage fixtures, real AC-3 / E-AC-3 / AAC tracks decoded
//  by Apple's decoders.
//

import XCTest
import Foundation
import AudioToolbox

final class SpeechActivityDetectorTests: CheckedTestCase {

    /// 24 kHz: the 300–3400 Hz band with room to spare, half the work of 48 kHz.
    private let rate = 24_000.0

    /// Utterances of 0.8–3 s with pauses of 0.6–3 s.
    private func utterances(seconds: Double, seed: UInt64) -> [ClosedRange<Double>] {
        var rng = SyncFilms.RNG(seed)
        var out: [ClosedRange<Double>] = []
        var t = 1.5
        while t < seconds - 4 {
            let length = rng.uniform(0.8, 3)
            out.append(t...(t + length))
            t += length + rng.uniform(0.6, 3)
        }
        return out
    }

    /// Interleaved PCM: a voice (140 Hz harmonics, 4.5 syllables a second) during `speech`, a
    /// chord under it all the time. `layout` "centre" puts the voice in the centre channel and
    /// the chord on L / R (labels C, L, R: the centre FIRST, as AAC lays it out); "stereo" puts
    /// both in L and R.
    private func pcm(seconds: Double, speech: [ClosedRange<Double>], stereo: Bool) -> (samples: [Float], labels: [AudioChannelLabel]) {
        let labels: [AudioChannelLabel] = stereo ? [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
            : [kAudioChannelLabel_Center, kAudioChannelLabel_Left, kAudioChannelLabel_Right]
        let channels = labels.count, frames = Int(seconds * rate)
        var out = [Float](repeating: 0, count: frames * channels)
        var phase = 0.0, k = 0
        for i in 0..<frames {
            let t = Double(i) / rate
            while k < speech.count && speech[k].upperBound <= t { k += 1 }
            var voice = 0.0
            if k < speech.count, speech[k].contains(t) {
                phase += 2 * .pi * (140 + 20 * sin(2 * .pi * 0.7 * t)) / rate
                var v = 0.0
                for h in 1...20 { v += sin(Double(h) * phase) / Double(h) }
                voice = 0.25 * v * max(0, sin(2 * .pi * 4.5 * (t - speech[k].lowerBound)))
            }
            let music = 0.05 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277 * t) + sin(2 * .pi * 330 * t))
            if stereo {
                out[i * 2] = Float(voice + music)
                out[i * 2 + 1] = Float(voice - 0.8 * music)
            } else {
                out[i * 3] = Float(voice)
                out[i * 3 + 1] = Float(music)
                out[i * 3 + 2] = Float(0.9 * music)
            }
        }
        return (out, labels)
    }

    private func analyse(_ samples: [Float], labels: [AudioChannelLabel]) -> SpeechActivityDetector {
        let detector = SpeechActivityDetector(pcmSampleRate: rate, channelLabels: labels)
        let channels = labels.count, frames = samples.count / channels
        var done = 0
        samples.withUnsafeBufferPointer { all in
            while done < frames {
                let n = min(4800, frames - done)
                detector.analyze(interleaved: UnsafeBufferPointer(rebasing: all[(done * channels)..<((done + n) * channels)]),
                                 presentationTime: Double(done) / rate)
                done += n
            }
        }
        detector.finish()
        return detector
    }

    /// Share of slots at p ≥ 0.5 well inside the utterances, and well away from them.
    private func shares(_ activity: SpeechActivity, _ speech: [ClosedRange<Double>]) -> (inside: Double, outside: Double) {
        var inside = (0, 0), outside = (0, 0)
        for slot in 0..<activity.codes.count {
            guard let p = activity.probability(atSlot: slot) else { continue }
            let t = Double(slot) / 100
            if speech.contains(where: { t >= $0.lowerBound + 0.2 && t < $0.upperBound - 0.2 }) {
                inside = (inside.0 + (p >= 0.5 ? 1 : 0), inside.1 + 1)
            } else if !speech.contains(where: { t >= $0.lowerBound - 0.4 && t < $0.upperBound + 0.4 }) {
                outside = (outside.0 + (p >= 0.5 ? 1 : 0), outside.1 + 1)
            }
        }
        return (Double(inside.0) / Double(max(1, inside.1)), Double(outside.0) / Double(max(1, outside.1)))
    }

    func testCentreChannelFoundByItsLabel() {
        let speech = utterances(seconds: 40, seed: 3)
        let (samples, labels) = pcm(seconds: 40, speech: speech, stereo: false)
        let detector = analyse(samples, labels: labels)
        eq(detector.channelSource, .centre, "the centre (first channel here) is the dialogue signal")
        let activity = detector.activity()
        let (inside, outside) = shares(activity, speech)
        check(inside > 0.9, "speech found in the utterances", "\(inside)")
        check(outside < 0.05, "no speech in the music between them", "\(outside)")
        check(abs(activity.knownSeconds - 40) < 0.2, "every slot known", "\(activity.knownSeconds)")
        check(activity.probability(at: 41) == nil, "past the audio: unknown")
    }

    func testStereoMid() {
        let speech = utterances(seconds: 40, seed: 4)
        let (samples, labels) = pcm(seconds: 40, speech: speech, stereo: true)
        let detector = analyse(samples, labels: labels)
        eq(detector.channelSource, .mid, "L + R: the mid")
        let (inside, outside) = shares(detector.activity(), speech)
        check(inside > 0.8 && outside < 0.1, "speech told from music in the mid", "inside \(inside), outside \(outside)")
    }

    /// The detector's output is the aligner's speech reference: cues made from the utterances,
    /// shifted, come back.
    func testDetectorFeedsTheAligner() {
        let speech = utterances(seconds: 120, seed: 3)
        let (samples, labels) = pcm(seconds: 120, speech: speech, stereo: false)
        let activity = analyse(samples, labels: labels).activity()
        let cues = speech.enumerated().compactMap { index, span -> SubtitleCue? in
            let start = span.lowerBound - 1.7
            return start >= 0 ? SubtitleCue(start: start, end: span.upperBound - 1.7 + 0.5, text: "Line \(index)", settings: nil) : nil
        }
        var options = SubtitleSyncAligner.Options()
        options.ratios = [1]
        // Two minutes, 29 cues: the full gates want a longer film (PSR 5.0 here, 6.5 needed).
        options.gates = SubtitleSyncAligner.Gates(minScore: 0.3, minPeakToSidelobe: 4, minPeakRatio: 1.5, minOverlap: 60, minCues: 20)
        let estimate = SubtitleSyncAligner.estimate(cues: cues, reference: SubtitleSyncReference(speechProbability: activity.probabilities),
                                                    options: options)
        check(estimate.isConfident && abs(estimate.transform.offset - 1.7) <= 0.1, "+1.7 s recovered from the audio", estimate.summary)
    }

    /// Laced audio without DefaultDuration: every frame of a block carries the block's timestamp.
    /// Each frame follows the previous one, and the next block (at block time + n frames) still
    /// continues the run — it used to restart it at every block (decoder reset, warm-up lost:
    /// 61 s of 170 s known in a probe).
    func testLacedFramesKeepOneRun() {
        let speech = utterances(seconds: 60, seed: 6)
        let (samples, labels) = pcm(seconds: 60, speech: speech, stereo: false)
        let detector = SpeechActivityDetector(pcmSampleRate: rate, channelLabels: labels)
        let channels = labels.count, frame = 480, lace = 4
        samples.withUnsafeBufferPointer { all in
            var done = 0
            while done + frame <= all.count / channels {
                let blockTime = Double(done - done % (frame * lace)) / rate
                detector.analyze(interleaved: UnsafeBufferPointer(rebasing: all[(done * channels)..<((done + frame) * channels)]),
                                 presentationTime: blockTime)
                done += frame
            }
        }
        detector.finish()
        eq(detector.discontinuities, 0, "one run across the laced blocks")
        let activity = detector.activity()
        check(abs(activity.knownSeconds - 60) < 0.2, "every slot known", "\(activity.knownSeconds)")
        let (inside, outside) = shares(activity, speech)
        check(inside > 0.9 && outside < 0.05, "and the speech is where it is", "inside \(inside), outside \(outside)")
    }

    func testHostileInput() {
        var rng = SyncFilms.RNG(42)
        func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8(truncatingIfNeeded: rng.next()) }) }
        let configurations: [(String, SpeechActivityDetector.Codec, Int)] = [
            ("AC-3", .ac3, 2), ("E-AC-3", .eac3, 6), ("AAC", .aac(audioSpecificConfig: Data([0x11, 0x90])), 2),
        ]
        for (name, codec, channels) in configurations {
            guard let detector = SpeechActivityDetector(codec: codec, sampleRate: 48_000, channelCount: channels) else {
                check(false, "\(name): a decoder exists")
                continue
            }
            var accepted = 0
            for index in 0..<300 {
                var unit = random([0, 1, 7, 64, 768, 1536, 4096][index % 7])
                if index % 3 == 0, unit.count > 2 { unit[0] = 0x0B; unit[1] = 0x77 }
                if detector.decode(accessUnit: unit, presentationTime: Double(index) * 0.032) { accepted += 1 }
            }
            for time in [Double.nan, .infinity, -1e12, 1e300] {
                check(!detector.decode(accessUnit: random(768), presentationTime: time), "\(name): time \(time) refused")
            }
            check(accepted <= 3, "\(name): garbage is refused", "\(accepted) accepted")
            check(detector.activity().codes.count <= SpeechActivityDetector.maxSlots, "\(name): the timeline stays bounded")
        }
        for (rate, channels) in [(0.0, 2), (-48_000, 2), (.nan, 2), (48_000, 0), (48_000, 64)] {
            check(SpeechActivityDetector(codec: .ac3, sampleRate: rate, channelCount: channels) == nil, "rate \(rate), \(channels) channels: no detector")
        }
        // PCM with NaN, infinities and huge values: no trap, finite output.
        let detector = SpeechActivityDetector(pcmSampleRate: rate, channelLabels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
        var samples = [Float](repeating: 0.1, count: 96_000)
        for i in stride(from: 0, to: samples.count, by: 97) { samples[i] = [Float.nan, .infinity, 1e30][i % 3] }
        samples.withUnsafeBufferPointer { detector.analyze(interleaved: $0, presentationTime: 0) }
        detector.finish()
        check(detector.activity().probabilities.allSatisfy { $0.isNaN || (0...1).contains($0) }, "probabilities stay in 0…1")
    }

    // MARK: Real tracks (PT_SUBSYNC_FIXTURES)

    /// Every audio frame of `name`'s tracks, demuxed by the app's own demuxer.
    static func audioTracks(_ name: String) throws -> [(track: MKVTrack, frames: [(data: Data, time: Double)])] {
        guard let folder = ProcessInfo.processInfo.environment["PT_SUBSYNC_FIXTURES"], !folder.isEmpty else {
            throw XCTSkip("set PT_SUBSYNC_FIXTURES to the folder of the format-coverage MKV fixtures")
        }
        let path = (folder as NSString).appendingPathComponent(name)
        guard let handle = FileHandle(forReadingAtPath: path) else { throw XCTSkip("no \(name) in PT_SUBSYNC_FIXTURES") }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        let demuxer = MatroskaDemuxer(reader: EBMLReader(handle: handle, fileLength: { size }))
        demuxer.assumeFullyDownloaded = true
        guard demuxer.parseHeaders() else { throw XCTSkip("\(name): headers unreadable") }
        var tracks: [UInt64: (track: MKVTrack, frames: [(data: Data, time: Double)])] = [:]
        for track in demuxer.tracks where track.kind == .audio { tracks[track.number] = (track, []) }
        demuxer.trackFilter = Set(tracks.keys)
        let tick = demuxer.secondsPerTick
        while let frames = demuxer.readNextCluster() {
            for frame in frames where tracks[frame.trackNumber] != nil {
                tracks[frame.trackNumber]?.frames.append((frame.data, Double(frame.timestamp) * tick))
            }
        }
        return tracks.values.sorted { $0.track.number < $1.track.number }
    }

    func testRealTracksDecode() throws {
        let expectations: [(String, String, SpeechActivityDetector.ChannelSource)] = [
            ("F02_hevc10_pq_eac3_51.mkv", "A_EAC3", .centre),
            ("F05_subs.mkv", "A_AAC", .mid),
            ("F03_hevc_sdr_ac3_20.mkv", "A_AC3", .mid),
        ]
        for (file, codecID, source) in expectations {
            guard let (track, frames) = try Self.audioTracks(file).first(where: { $0.track.codecID == codecID }) else {
                check(false, "\(file): a \(codecID) track")
                continue
            }
            let codec: SpeechActivityDetector.Codec
            switch codecID {
            case "A_AC3": codec = .ac3
            case "A_EAC3": codec = .eac3
            default: codec = .aac(audioSpecificConfig: track.codecPrivate)
            }
            guard let detector = SpeechActivityDetector(codec: codec, sampleRate: track.samplingFrequency, channelCount: track.channels,
                                                        codecDelay: Double(track.codecDelayNs) / 1e9) else {
                check(false, "\(file): Apple's \(codecID) decoder")
                continue
            }
            for frame in frames { detector.decode(accessUnit: frame.data, presentationTime: frame.time) }
            detector.finish()
            eq(detector.channelSource, source, "\(file): the dialogue signal")
            eq(detector.accessUnitsRejected, 0, "\(file): every unit decodes")
            let span = (frames.last?.time ?? 0) - (frames.first?.time ?? 0)
            check(abs(detector.activity().knownSeconds - span) < 1, "\(file): the whole track is known",
                  "\(detector.activity().knownSeconds) s of \(span) s")

            // The same frames as laced blocks of 4 without DefaultDuration (each frame at its
            // block's timestamp): still one run, the whole track known.
            guard let laced = SpeechActivityDetector(codec: codec, sampleRate: track.samplingFrequency, channelCount: track.channels,
                                                     codecDelay: Double(track.codecDelayNs) / 1e9) else { continue }
            for (index, frame) in frames.enumerated() {
                laced.decode(accessUnit: frame.data, presentationTime: frames[index - index % 4].time)
            }
            laced.finish()
            eq(laced.discontinuities, 0, "\(file), laced: one run")
            check(abs(laced.activity().knownSeconds - span) < 1, "\(file), laced: the whole track is known",
                  "\(laced.activity().knownSeconds) s of \(span) s")
        }
    }
}
