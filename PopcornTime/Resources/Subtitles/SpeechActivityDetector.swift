

import Foundation
import AudioToolbox
import Accelerate

// Speech activity of a film's soundtrack, the audio reference of the
// automatic subtitle sync when the file has no embedded text subtitle to
// align against. Pure Foundation + AudioToolbox + Accelerate (no UIKit /
// PopcornKit) so the headless harness can compile it on its own.
//
// Input: the compressed access units of ONE audio track (AC-3, E-AC-3 or
// AAC, exactly as Matroska stores them) with their presentation time in
// seconds on the source timeline. They are decoded with Apple's own
// decoders (AudioConverter: no licence, nothing to ship), and only the
// channel that carries the dialogue is kept: the CENTRE channel when the
// decoder's output layout has one (found by its label: the decoders put it
// at index 1 for AC-3/E-AC-3, 0 for AAC), else the mid (L+R)/2.
//
// Output: one soft speech probability per 10 ms slot (`SpeechActivity`) —
// the 100 Hz grid ffsubsync and alass use — plus "unknown" for every slot
// that was never decoded (not downloaded, skipped by a seek): the aligner
// must not read silence there. Per slot, cues are combined by a logistic:
//   - centred speech-band level (300–3400 Hz, each bin weighted by the
//     dialogue signal's share against the comparison signal: centre
//     against L/R, mid against side) above an adaptive noise floor (the
//     10th percentile over 8 s: minimum statistics, follows music and
//     ambience that come and go),
//   - syllabic modulation of that level (2–8 Hz: speech rises and falls
//     4–5 times a second, sustained score does not) — the strongest cue,
//   - harmonicity (voiced pitch 70–400 Hz in the band-passed signal),
//   - dominance of the dialogue signal over the comparison signal where it
//     is active: dialogue is mixed to the centre, music and effects mostly
//     to the sides,
// then smoothed (gaps under 250 ms merged, blips under 150 ms dropped,
// 150 ms hangover) like the auditok / alass post-processing. Band ratio
// and dominance margin are computed for the harness but weigh nothing:
// with physically signed weights the fit left them at zero.
//
// Memory: one byte per slot (3 h = 1.08 MB), capped at `maxSlots` so a
// garbage timestamp cannot grow it; a few seconds of per-slot features and
// fixed decoder buffers on top.
//
// Threading: NOT thread-safe. One serial queue owns an instance: it is
// created, fed and read there (the remux pump only copies each access unit
// and its time and hands them off, it never calls into this class).

/// Soft speech probability per 10 ms slot on the source timeline:
/// slot i covers [i / 100, (i + 1) / 100) seconds.
struct SpeechActivity {
    static let slotsPerSecond = 100

    /// One byte per slot: 0 = unknown (never decoded), 1...255 = speech
    /// probability (code − 1) / 254.
    let codes: [UInt8]
    /// Slots with a known value.
    let knownSlots: Int
    /// Known slots whose probability is at least 0.5.
    let speechSlots: Int

    var knownSeconds: Double { Double(knownSlots) / Double(Self.slotsPerSecond) }
    var speechSeconds: Double { Double(speechSlots) / Double(Self.slotsPerSecond) }

    /// nil when the slot is unknown (or outside the timeline).
    func probability(atSlot slot: Int) -> Float? {
        guard slot >= 0, slot < codes.count, codes[slot] != 0 else { return nil }
        return Float(codes[slot] - 1) / 254
    }

    func probability(at seconds: Double) -> Float? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return probability(atSlot: Int(seconds * Double(Self.slotsPerSecond)))
    }

    /// Every slot from 0 s as a probability, NaN where unknown: the form the
    /// aligner's speech reference takes (4 bytes per slot, so build it only
    /// for an estimate).
    var probabilities: [Float] {
        codes.map { $0 == 0 ? .nan : Float($0 - 1) / 254 }
    }

    static func code(for probability: Float) -> UInt8 {
        guard probability.isFinite else { return 1 }
        return UInt8(1 + (min(max(probability, 0), 1) * 254).rounded())
    }
}

final class SpeechActivityDetector {

    enum Codec: Equatable {
        case ac3
        case eac3
        /// AudioSpecificConfig: Matroska CodecPrivate, or the one the remux
        /// synthesizes for legacy CodecIDs (`RemuxCodecs.aacAudioSpecificConfig`).
        case aac(audioSpecificConfig: Data)
    }

    /// Which signal the detector listens to (for the "[SubSync]" log).
    enum ChannelSource: String {
        /// The layout's centre channel: dialogue, little music.
        case centre
        /// (L + R) / 2: a stereo mix.
        case mid
        /// A single channel.
        case mono
        /// Mean of every channel: the layout could not be read.
        case downmix
    }

    /// Logistic weights of the slot features: a logistic regression with
    /// non-negative weights, fitted on synthetic dialogue (macOS voices,
    /// French and English) mixed under music and effects at −10…0 dB SNR,
    /// then rounded and checked on held-out voices, sentences and mixes.
    /// The harness can pass others to compare.
    struct Weights {
        var intercept: Float
        var level: Float
        var modulation: Float
        var harmonicity: Float
        var bandRatio: Float
        var dominance: Float
        var dominanceMargin: Float

        /// Centre channel: dominance over L/R is a strong cue there.
        static let centre = Weights(intercept: -4.9, level: 0.12, modulation: 0.4, harmonicity: 2.7,
                                    bandRatio: 0, dominance: 0.11, dominanceMargin: 0)
        /// Mid of a stereo mix (also mono / unknown layouts).
        static let stereo = Weights(intercept: -2.1, level: 0.03, modulation: 0.68, harmonicity: 0,
                                    bandRatio: 0, dominance: 0.07, dominanceMargin: 0)

        static func standard(for source: ChannelSource) -> Weights {
            source == .centre ? centre : stereo
        }
    }

    /// Per-slot features before the logistic, for the harness only
    /// (`featureObserver`).
    struct SlotFeatures {
        /// Speech-band level above the adaptive floor, dB (0…30).
        var level: Float
        /// RMS of the 2–8 Hz modulation of that level, dB.
        var modulation: Float
        /// Voicing, 0…1.
        var harmonicity: Float
        /// Speech band against the full band, dB (−30…0).
        var bandRatio: Float
        /// Dialogue channel against the others in the speech band, dB
        /// (±15), scaled down where `level` is under 10 dB.
        var dominance: Float
        /// `dominance` above its own adaptive floor, dB (0…30).
        var dominanceMargin: Float
    }

    static let slotsPerSecond = SpeechActivity.slotsPerSecond
    /// Timeline ceiling (6 h): later slots are ignored, so memory stays
    /// bounded whatever timestamps a damaged file carries.
    static let maxSlots = 6 * 3600 * slotsPerSecond

    /// Which signal is analysed; known once the decoder's layout is.
    var channelSource: ChannelSource { mix.source }
    /// Channel labels of the decoded (or given PCM) audio, in order; empty
    /// while the decoder has not reported its layout.
    var channelLabels: [AudioChannelLabel] { decoder?.channelLabels ?? pcmLabels }
    /// Output rate of the decoder (for HE-AAC, the rate of the layer the
    /// decoder outputs: the core rate on macOS 27, still the whole speech band).
    let sampleRate: Double

    /// Counters for the log and the tests.
    private(set) var accessUnitsDecoded = 0
    private(set) var accessUnitsRejected = 0
    private(set) var framesDecoded = 0
    /// Timeline restarts (seek, hole, rejected unit).
    private(set) var discontinuities = 0

    /// Harness hook: every committed slot with its features. nil in the app.
    var featureObserver: ((Int, SlotFeatures) -> Void)? {
        get { analyzer.featureObserver }
        set { analyzer.featureObserver = newValue }
    }
    /// Harness hook: the dialogue signal (centre / mid) as analysed, with
    /// the source time of its first sample. nil in the app.
    var signalObserver: ((UnsafeBufferPointer<Float>, Double) -> Void)?

    private let decoder: AccessUnitDecoder?
    private let pcmLabels: [AudioChannelLabel]
    private let analyzer: Analyzer
    private var mix: ChannelMix
    private let customWeights: Weights?
    private let channelCount: Int
    /// Seconds subtracted from every presentation time: Matroska CodecDelay
    /// (the block timestamp is the time of decoded sample CodecDelay).
    private let codecDelay: Double
    /// Nominal access-unit duration, used when the caller passes none.
    private let nominalUnitDuration: Double
    /// Presentation time the next access unit should have, nil at a restart.
    private var expectedNextTime: Double?
    private var lastUnitTime: Double?
    private let mixBuffer: UnsafeMutablePointer<Float>
    private let otherBuffer: UnsafeMutablePointer<Float>
    private let mixCapacity: Int

    /// Decodes `codec` with AudioConverter. nil when the platform has no
    /// decoder for it or the configuration is unusable.
    ///
    /// - Parameters:
    ///   - sampleRate: the track's sampling frequency (AAC: the rate the
    ///     AudioSpecificConfig describes wins when they differ).
    ///   - channelCount: the track's channel count.
    ///   - codecDelay: Matroska CodecDelay in seconds (usually 0).
    init?(codec: Codec, sampleRate: Double, channelCount: Int, codecDelay: Double = 0,
          weights: Weights? = nil) {
        guard sampleRate.isFinite, sampleRate >= 8000, sampleRate <= 192_000,
              channelCount >= 1, channelCount <= 16,
              let decoder = AccessUnitDecoder(codec: codec, sampleRate: sampleRate, channelCount: channelCount)
        else { return nil }
        self.decoder = decoder
        pcmLabels = []
        self.sampleRate = decoder.outputRate
        self.channelCount = decoder.channels
        self.codecDelay = codecDelay.isFinite ? max(0, codecDelay) : 0
        nominalUnitDuration = Double(decoder.framesPerPacket) / decoder.outputRate
        mix = ChannelMix(labels: decoder.channelLabels, channels: decoder.channels)
        customWeights = weights
        analyzer = Analyzer(sampleRate: decoder.outputRate, weights: weights ?? .standard(for: mix.source))
        mixCapacity = AccessUnitDecoder.outputCapacity
        mixBuffer = .allocate(capacity: mixCapacity)
        otherBuffer = .allocate(capacity: mixCapacity)
    }

    /// PCM entry point (tests, or audio that is already decoded): Float32
    /// interleaved, one label per channel (`kAudioChannelLabel_*`).
    init(pcmSampleRate: Double, channelLabels: [AudioChannelLabel], weights: Weights? = nil) {
        decoder = nil
        pcmLabels = channelLabels
        sampleRate = pcmSampleRate
        channelCount = max(1, channelLabels.count)
        codecDelay = 0
        nominalUnitDuration = 0.02
        mix = ChannelMix(labels: channelLabels, channels: max(1, channelLabels.count))
        customWeights = weights
        analyzer = Analyzer(sampleRate: pcmSampleRate, weights: weights ?? .standard(for: mix.source))
        mixCapacity = AccessUnitDecoder.outputCapacity
        mixBuffer = .allocate(capacity: mixCapacity)
        otherBuffer = .allocate(capacity: mixCapacity)
    }

    deinit {
        mixBuffer.deallocate()
        otherBuffer.deallocate()
    }

    // MARK: Feeding

    /// Decodes one access unit (one Matroska frame).
    ///
    /// - Parameters:
    ///   - presentationTime: seconds on the source timeline (Matroska
    ///     timestamp + shift, × TimestampScale). Laced frames that share their
    ///     block's timestamp are taken as following the previous one.
    ///   - duration: the unit's duration in seconds when the caller knows it
    ///     (E-AC-3 units can hold fewer than 6 blocks); nominal otherwise.
    /// - Returns: false when the unit was rejected (garbage, no decoder).
    @discardableResult
    func decode(accessUnit: Data, presentationTime: Double, duration: Double? = nil) -> Bool {
        guard let decoder else { return false }
        guard Self.isPlausible(presentationTime), !accessUnit.isEmpty,
              accessUnit.count <= AccessUnitDecoder.maxPacketBytes else {
            reject()
            return false
        }
        let unitDuration = duration.flatMap { $0.isFinite && $0 > 0 && $0 < 1 ? $0 : nil } ?? nominalUnitDuration
        if !continues(at: presentationTime, unitDuration: unitDuration) {
            restart(at: presentationTime - codecDelay)
        }
        advance(past: presentationTime, unitDuration: unitDuration)

        if !mix.knowsLayout, !decoder.channelLabels.isEmpty {
            // Some decoders only report their layout once a frame was parsed.
            mix = ChannelMix(labels: decoder.channelLabels, channels: decoder.channels)
            analyzer.weights = customWeights ?? .standard(for: mix.source)
        }
        var produced = 0
        let decoded = decoder.decode(accessUnit) { samples, frames in
            produced += frames
            analyzeInterleaved(samples, frames: frames)
        }
        framesDecoded += produced
        // A unit that decodes to nothing (garbage the decoder skipped) would
        // shift every later sample one unit early: restart instead.
        let ok = decoded && produced > 0
        if ok {
            accessUnitsDecoded += 1
        } else {
            reject()
        }
        return ok
    }

    /// Analyses interleaved Float32 PCM (PCM detectors only). A time that
    /// does not follow the previous buffer starts a new run.
    func analyze(interleaved samples: UnsafeBufferPointer<Float>, presentationTime: Double) {
        guard decoder == nil, let base = samples.baseAddress, Self.isPlausible(presentationTime) else { return }
        let frames = samples.count / channelCount
        guard frames > 0 else { return }
        let duration = Double(frames) / sampleRate
        if !continues(at: presentationTime, unitDuration: duration) {
            restart(at: presentationTime)
        }
        advance(past: presentationTime, unitDuration: duration)
        var done = 0
        while done < frames {
            let n = min(mixCapacity, frames - done)
            analyzeInterleaved(base + done * channelCount, frames: n)
            done += n
        }
    }

    /// Commits every pending slot: the end of the stream (or of the data
    /// that will ever come). Later input starts a new run.
    func finish() {
        analyzer.endRun()
        expectedNextTime = nil
        lastUnitTime = nil
        decoder?.reset()
    }

    /// Speech activity so far. With `includingPending`, the last few
    /// seconds (still waiting for the floor's look-ahead) are included with
    /// the context available now; they are recomputed when more audio comes.
    func activity(includingPending: Bool = true) -> SpeechActivity {
        if includingPending { analyzer.commitProvisionally() }
        return analyzer.activity
    }

    // MARK: Private

    /// Times far outside any film (damaged timestamps) are refused before
    /// they reach slot arithmetic.
    private static func isPlausible(_ time: Double) -> Bool {
        time.isFinite && abs(time) <= Double(maxSlots / slotsPerSecond) + 3600
    }

    /// A NaN or infinity would poison the filters' state for the rest of
    /// the run: such samples become silence, absurd values are clipped.
    private static func sanitize(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        var energy: Float = 0
        vDSP_svesq(samples, 1, &energy, vDSP_Length(count))
        guard !energy.isFinite || energy > 256 * Float(count) else { return }
        for i in 0..<count {
            let v = samples[i]
            samples[i] = v.isFinite ? min(max(v, -16), 16) : 0
        }
    }

    private func continues(at time: Double, unitDuration: Double) -> Bool {
        guard let expected = expectedNextTime, let last = lastUnitTime else { return false }
        if time == last { return true }      // laced frame without DefaultDuration
        let tolerance = max(0.012, 0.5 * unitDuration)
        return abs(time - expected) <= tolerance
    }

    /// The unit at `time` is taken: the next one is expected right after
    /// it. A laced frame repeats its block's timestamp (no DefaultDuration):
    /// it follows the previous frame, so the expected time moves on from
    /// there — from `time` itself, the next block (at block time + n units)
    /// would look like a hole and restart the run at every block.
    private func advance(past time: Double, unitDuration: Double) {
        let laced = time == lastUnitTime && expectedNextTime != nil
        expectedNextTime = (laced ? expectedNextTime ?? time : time) + unitDuration
        lastUnitTime = time
    }

    private func restart(at runStart: Double) {
        if expectedNextTime != nil || analyzer.hasRun { discontinuities += 1 }
        decoder?.reset()
        analyzer.beginRun(at: runStart)
    }

    private func reject() {
        accessUnitsRejected += 1
        // The samples of the lost unit are missing: the next one restarts
        // the timeline instead of being placed one unit early.
        expectedNextTime = nil
        lastUnitTime = nil
        decoder?.reset()
    }

    private func analyzeInterleaved(_ samples: UnsafePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            let n = min(mixCapacity, frames - done)
            let hasOther = mix.render(samples + done * channelCount, channels: channelCount, frames: n,
                                      into: mixBuffer, other: otherBuffer)
            Self.sanitize(mixBuffer, count: n)
            if hasOther { Self.sanitize(otherBuffer, count: n) }
            if let signalObserver {
                signalObserver(UnsafeBufferPointer(start: mixBuffer, count: n), analyzer.nextSampleTime)
            }
            analyzer.process(mixBuffer, other: hasOther ? otherBuffer : nil, count: n)
            done += n
        }
    }
}

// MARK: - Channel choice

/// How the decoded channels become the dialogue signal and the "other"
/// signal the dominance cue compares it with. Channels are identified by
/// their layout label, never by index: AC-3/E-AC-3 output L C R Ls Rs LFE,
/// AAC C L R Ls Rs LFE, FLAC L R C LFE Ls Rs.
private struct ChannelMix {
    let source: SpeechActivityDetector.ChannelSource
    /// (channel, gain) pairs summed into the dialogue signal.
    let primary: [(Int, Float)]
    /// (channel, gain) pairs summed into the comparison signal; empty = none.
    let other: [(Int, Float)]
    /// False when the layout was unknown (no labels): a later, known layout
    /// replaces this mix.
    let knowsLayout: Bool

    init(labels: [AudioChannelLabel], channels: Int) {
        let usable = labels.count == channels ? labels : []
        knowsLayout = !usable.isEmpty || channels == 1
        let centre = usable.firstIndex(of: kAudioChannelLabel_Center)
        let left = usable.firstIndex(of: kAudioChannelLabel_Left)
        let right = usable.firstIndex(of: kAudioChannelLabel_Right)
        if channels == 1 {
            source = .mono
            primary = [(0, 1)]
            other = []
        } else if let centre, channels >= 3 {
            source = .centre
            primary = [(centre, 1)]
            if let left, let right {
                other = [(left, 0.5), (right, 0.5)]
            } else {
                other = []
            }
        } else if let left, let right {
            source = .mid
            primary = [(left, 0.5), (right, 0.5)]
            other = [(left, 0.5), (right, -0.5)]
        } else {
            source = .downmix
            let gain = 1 / Float(channels)
            primary = (0..<channels).map { ($0, gain) }
            other = []
        }
    }

    /// Writes `frames` samples of the dialogue signal (and the comparison
    /// signal when there is one) from interleaved input. Returns whether
    /// `other` was written.
    func render(_ input: UnsafePointer<Float>, channels: Int, frames: Int,
                into output: UnsafeMutablePointer<Float>, other otherOutput: UnsafeMutablePointer<Float>) -> Bool {
        Self.sum(primary, input, channels, frames, output)
        guard !other.isEmpty else { return false }
        Self.sum(other, input, channels, frames, otherOutput)
        return true
    }

    private static func sum(_ terms: [(Int, Float)], _ input: UnsafePointer<Float>, _ channels: Int,
                            _ frames: Int, _ output: UnsafeMutablePointer<Float>) {
        let n = vDSP_Length(frames)
        let stride = vDSP_Stride(channels)
        vDSP_vclr(output, 1, n)
        for (channel, gain) in terms {
            var g = gain
            vDSP_vsma(input + channel, stride, &g, output, 1, output, 1, n)
        }
    }
}

// MARK: - Decoder

/// AudioConverter fed one access unit at a time, Float32 interleaved out
/// at the native channel count and rate (decoding is the whole cost:
/// asking for one channel or a lower rate saves nothing, and AAC ignores
/// the channel map anyway).
private final class AccessUnitDecoder {
    static let outputCapacity = 4096
    /// Larger "access units" are garbage (E-AC-3 tops out near 4 KB per
    /// syncframe, a Matroska block of AC-3 well under 64 KB).
    static let maxPacketBytes = 1 << 18
    /// Returned by the input callback once its unit is consumed: the
    /// converter hands back what it decoded and keeps its state.
    private static let unitConsumed: OSStatus = 0x7375_6E31   // 'sun1'

    let channels: Int
    let outputRate: Double
    let framesPerPacket: Int
    private(set) var channelLabels: [AudioChannelLabel]

    private let converter: AudioConverterRef
    private let output: UnsafeMutablePointer<Float>
    private var packet: UnsafeMutableRawPointer
    private var packetCapacity: Int
    private var packetSize = 0
    private var packetPending = false
    /// Handed to the converter by the input callback, which reads it after
    /// the callback returns: it must outlive the call (a pointer taken with
    /// `withUnsafeMutablePointer` would not).
    private let packetDescription: UnsafeMutablePointer<AudioStreamPacketDescription>

    init?(codec: SpeechActivityDetector.Codec, sampleRate: Double, channelCount: Int) {
        var input = AudioStreamBasicDescription()
        var cookie: Data?
        switch codec {
        case .ac3, .eac3:
            input.mFormatID = codec == .ac3 ? kAudioFormatAC3 : kAudioFormatEnhancedAC3
            input.mSampleRate = sampleRate
            input.mChannelsPerFrame = UInt32(channelCount)
            input.mFramesPerPacket = 1536
        case .aac(let config):
            // The decoder wants an MPEG-4 ES descriptor as its cookie; it
            // also tells the real format (HE-AAC: SBR at twice the rate).
            guard config.count >= 2 else { return nil }
            let esds = Self.elementaryStreamDescriptor(audioSpecificConfig: config)
            guard let format = Self.richestFormat(cookie: esds) else { return nil }
            input = format
            cookie = esds
        }
        let rate = input.mSampleRate > 0 ? input.mSampleRate : sampleRate
        let channels = Int(input.mChannelsPerFrame > 0 ? input.mChannelsPerFrame : UInt32(channelCount))
        guard channels >= 1, channels <= 16 else { return nil }
        input.mSampleRate = rate
        input.mChannelsPerFrame = UInt32(channels)
        var pcm = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var created: AudioConverterRef?
        guard AudioConverterNew(&input, &pcm, &created) == noErr, let converter = created else { return nil }
        if let cookie {
            let status = cookie.withUnsafeBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie,
                                                 UInt32(raw.count), base)
            }
            guard status == noErr else {
                AudioConverterDispose(converter)
                return nil
            }
        }
        self.converter = converter
        self.channels = channels
        outputRate = rate
        framesPerPacket = Int(input.mFramesPerPacket > 0 ? input.mFramesPerPacket : 1024)
        channelLabels = Self.outputLabels(converter, channels: channels)
        output = .allocate(capacity: Self.outputCapacity * channels)
        packetCapacity = 8192
        packet = .allocate(byteCount: packetCapacity, alignment: 16)
        packetDescription = .allocate(capacity: 1)
        packetDescription.initialize(to: AudioStreamPacketDescription())
    }

    deinit {
        AudioConverterDispose(converter)
        output.deallocate()
        packet.deallocate()
        packetDescription.deallocate()
    }

    func reset() {
        AudioConverterReset(converter)
        packetPending = false
    }

    /// Decodes one unit; `sink` receives each decoded block (interleaved).
    /// false when the decoder refused it (it is then reset).
    func decode(_ unit: Data, sink: (UnsafePointer<Float>, Int) -> Void) -> Bool {
        if unit.count > packetCapacity {
            packet.deallocate()
            packetCapacity = max(unit.count, packetCapacity * 2)
            packet = .allocate(byteCount: packetCapacity, alignment: 16)
        }
        unit.withUnsafeBytes { raw in
            if let base = raw.baseAddress { packet.copyMemory(from: base, byteCount: raw.count) }
        }
        packetSize = unit.count
        packetPending = true
        let me = Unmanaged.passUnretained(self).toOpaque()
        var ok = true
        // Output arrives in blocks of up to `outputCapacity` frames; one
        // unit decodes to at most a few thousand, the bound only stops a
        // misbehaving decoder from looping.
        for _ in 0..<64 {
            var frames = UInt32(Self.outputCapacity)
            var buffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                      mDataByteSize: UInt32(Self.outputCapacity * channels * 4),
                                      mData: UnsafeMutableRawPointer(output)))
            let status = AudioConverterFillComplexBuffer(converter, Self.inputProc, me, &frames, &buffers, nil)
            let produced = Int(min(frames, UInt32(Self.outputCapacity)))
            if produced > 0, status == noErr || status == Self.unitConsumed {
                sink(output, produced)
            }
            if status == Self.unitConsumed { break }
            if status != noErr { ok = false; break }
            if produced == 0 { break }
        }
        if !ok || packetPending {
            // Refused, or never asked for: drop whatever state it holds.
            AudioConverterReset(converter)
            packetPending = false
            ok = false
        }
        if ok, channelLabels.isEmpty {
            channelLabels = Self.outputLabels(converter, channels: channels)
        }
        return ok
    }

    private static let inputProc: AudioConverterComplexInputDataProc = { _, packets, data, descriptions, user in
        guard let user else { packets.pointee = 0; return unitConsumed }
        let me = Unmanaged<AccessUnitDecoder>.fromOpaque(user).takeUnretainedValue()
        guard me.packetPending else {
            packets.pointee = 0
            return unitConsumed
        }
        me.packetPending = false
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mData = me.packet
        data.pointee.mBuffers.mDataByteSize = UInt32(me.packetSize)
        data.pointee.mBuffers.mNumberChannels = UInt32(me.channels)
        me.packetDescription.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                    mDataByteSize: UInt32(me.packetSize))
        descriptions?.pointee = me.packetDescription
        packets.pointee = 1
        return noErr
    }

    /// Format of the stream the cookie describes; for HE-AAC the richest
    /// layer (SBR, output rate) so the decoder outputs the full band.
    private static func richestFormat(cookie: Data) -> AudioStreamBasicDescription? {
        cookie.withUnsafeBytes { raw -> AudioStreamBasicDescription? in
            guard let base = raw.baseAddress else { return nil }
            var size: UInt32 = 0
            if AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList, UInt32(raw.count), base, &size) == noErr,
               size >= UInt32(MemoryLayout<AudioFormatListItem>.size) {
                var items = [AudioFormatListItem](repeating: AudioFormatListItem(),
                                                  count: Int(size) / MemoryLayout<AudioFormatListItem>.size)
                if AudioFormatGetProperty(kAudioFormatProperty_FormatList, UInt32(raw.count), base, &size, &items) == noErr,
                   let first = items.first, first.mASBD.mSampleRate > 0 {
                    return first.mASBD
                }
            }
            var format = AudioStreamBasicDescription()
            format.mFormatID = kAudioFormatMPEG4AAC
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(raw.count), base, &size, &format) == noErr,
                  format.mSampleRate > 0 else { return nil }
            return format
        }
    }

    /// MPEG-4 ES_Descriptor (ISO 14496-1) around an AudioSpecificConfig:
    /// what an `esds` box holds after its version/flags, the form Apple's
    /// AAC decoder takes as its magic cookie.
    static func elementaryStreamDescriptor(audioSpecificConfig config: Data) -> Data {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data {
            var out = Data([tag])
            let n = body.count
            out.append(contentsOf: [UInt8(0x80 | ((n >> 21) & 0x7F)), UInt8(0x80 | ((n >> 14) & 0x7F)),
                                    UInt8(0x80 | ((n >> 7) & 0x7F)), UInt8(n & 0x7F)])
            out.append(body)
            return out
        }
        var decoderConfig = Data([0x40, 0x15])           // objectTypeIndication MPEG-4 audio, audio stream
        decoderConfig.append(contentsOf: [0, 0, 0])      // bufferSizeDB
        decoderConfig.append(contentsOf: [0, 0, 0, 0])   // maxBitrate
        decoderConfig.append(contentsOf: [0, 0, 0, 0])   // avgBitrate
        decoderConfig.append(descriptor(0x05, config))
        var es = Data([0, 0, 0])                         // ES_ID, flags
        es.append(descriptor(0x04, decoderConfig))
        es.append(descriptor(0x06, Data([0x02])))        // SLConfig: predefined MP4
        return descriptor(0x03, es)
    }

    /// Labels of the decoder's output channels, in order; empty when the
    /// layout is unknown or does not match the channel count.
    private static func outputLabels(_ converter: AudioConverterRef, channels: Int) -> [AudioChannelLabel] {
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterOutputChannelLayout, &size, nil) == noErr,
              size >= UInt32(descriptionsOffset) else { return [] }
        // A tag-only layout is 12 bytes: allocate at least the full struct
        // so reading its fields never runs past the buffer.
        let capacity = max(Int(size), MemoryLayout<AudioChannelLayout>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        guard AudioConverterGetProperty(converter, kAudioConverterOutputChannelLayout, &size, raw) == noErr else { return [] }
        let labels = channelLabels(of: raw, size: Int(size))
        return labels.count == channels ? labels : []
    }

    private static let descriptionsOffset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) ?? 12

    /// Expands a layout given by tag, bitmap or descriptions to labels.
    private static func channelLabels(of raw: UnsafeRawPointer, size: Int) -> [AudioChannelLabel] {
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            return descriptionLabels(raw, size: size)
        }
        var expanded: UInt32 = 0
        var key: UInt32
        let property: AudioFormatPropertyID
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            key = layout.pointee.mChannelBitmap.rawValue
            property = kAudioFormatProperty_ChannelLayoutForBitmap
        } else {
            key = tag
            property = kAudioFormatProperty_ChannelLayoutForTag
        }
        guard AudioFormatGetPropertyInfo(property, 4, &key, &expanded) == noErr,
              expanded >= UInt32(descriptionsOffset) else { return [] }
        let capacity = max(Int(expanded), MemoryLayout<AudioChannelLayout>.size)
        let full = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { full.deallocate() }
        full.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        guard AudioFormatGetProperty(property, 4, &key, &expanded, full) == noErr else { return [] }
        return descriptionLabels(full, size: Int(expanded))
    }

    private static func descriptionLabels(_ raw: UnsafeRawPointer, size: Int) -> [AudioChannelLabel] {
        let count = Int(raw.assumingMemoryBound(to: AudioChannelLayout.self).pointee.mNumberChannelDescriptions)
        guard count > 0, descriptionsOffset + count * MemoryLayout<AudioChannelDescription>.stride <= size else { return [] }
        let descriptions = (raw + descriptionsOffset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { descriptions[$0].mChannelLabel }
    }
}

// MARK: - Analysis

/// Speech-band features per 10 ms slot, then the probability, on runs of
/// contiguous audio. The floor and the smoothing look up to 4 s around a
/// slot, so slots are committed in chunks, `context` slots behind the input.
private final class Analyzer {
    private static let floorRadius = 400          // ±4 s: the 10th-percentile window
    private static let floorStep = 25             // floor computed every 250 ms, interpolated
    private static let context = 500              // slots of context on each side of a chunk
    private static let chunk = 1000               // slots committed per pass
    private static let warmupSeconds = 0.05       // after a decoder reset the MDCT overlap is missing

    let sampleRate: Double
    var weights: SpeechActivityDetector.Weights
    var featureObserver: ((Int, SpeechActivityDetector.SlotFeatures) -> Void)?

    // Timeline -------------------------------------------------------------
    private var codes: [UInt8] = []
    private var knownSlots = 0
    private var speechSlots = 0
    private(set) var hasRun = false
    private var runStart = 0.0                    // source time of run sample 0
    private var runSamples = 0                    // samples analysed in this run
    private let slotSamples: Double               // nominal samples per slot

    // Band-pass (state persists inside a run) --------------------------------
    private static let bandSections = 4
    private let bandSetup: vDSP_biquad_Setup
    private var bandDelay: [Float]
    private var otherDelay: [Float]
    private let bandSignal: UnsafeMutablePointer<Float>
    private let bandOther: UnsafeMutablePointer<Float>
    private static let blockCapacity = AccessUnitDecoder.outputCapacity

    // Current slot ------------------------------------------------------------
    private var slot = Int.min                    // Int.min: none yet in this run
    private var slotEnd = 0                       // run sample index where it ends
    private var sumBand: Float = 0, sumTotal: Float = 0, sumOther: Float = 0
    private var slotCount = 0
    private var hasOther = false

    // Pitch cue on the band signal decimated to ~8 kHz -------------------------
    private let decimation: Int
    private let harmonicWindow: Int
    private let minLag: Int, maxLag: Int
    private var decimated: [Float] = []
    private var decimatedBase = 0                 // decimated run index of decimated[0]
    private var correlation: [Float]

    // Centred speech-band energy: a short spectrum of the dialogue signal
    // and of the comparison signal, each bin weighted by the dialogue's
    // share (a soft centre extraction): music bleeding into the centre, or
    // spread across a stereo mix, is mostly in the comparison signal too.
    private let fftLog2: vDSP_Length
    private let fftSize: Int
    private let fftSetup: FFTSetup
    private let fftWindow: UnsafeMutablePointer<Float>
    private let fftInput: UnsafeMutablePointer<Float>
    private let fftReal: UnsafeMutablePointer<Float>
    private let fftImag: UnsafeMutablePointer<Float>
    private let powerSignal: UnsafeMutablePointer<Float>
    private let powerOther: UnsafeMutablePointer<Float>
    private let bandBins: Range<Int>
    private var history: [Float] = []             // dialogue signal, run index historyBase
    private var historyOther: [Float] = []
    private var historyBase = 0

    // Features of the run not committed yet (slot of index 0 = pendingStart) ----
    private var pendingStart = 0
    private var committedEnd = 0                  // absolute slot: committed below it
    private var pBand: [Float] = []               // speech-band level, dB
    private var pCentred: [Float] = []            // centred speech-band level, dB
    private var pTotal: [Float] = []              // full-band level, dB
    private var pOther: [Float] = []              // comparison signal's band level, dB
    private var pHarm: [Float] = []
    private var pKnown: [Bool] = []

    init(sampleRate: Double, weights: SpeechActivityDetector.Weights) {
        self.sampleRate = sampleRate
        self.weights = weights
        slotSamples = sampleRate / Double(SpeechActivity.slotsPerSecond)
        // 4th-order Butterworth high-pass at 300 Hz and low-pass at 3.4 kHz:
        // the telephone band, where dialogue lives and rumble/LFE does not.
        let top = min(3400, 0.42 * sampleRate)
        var coefficients: [Double] = []
        for q in [0.5412, 1.3066] { coefficients += Self.biquad(highPass: true, frequency: 300, q: q, rate: sampleRate) }
        for q in [0.5412, 1.3066] { coefficients += Self.biquad(highPass: false, frequency: top, q: q, rate: sampleRate) }
        bandSetup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(Self.bandSections))!
        bandDelay = [Float](repeating: 0, count: 2 * Self.bandSections + 2)
        otherDelay = bandDelay
        bandSignal = .allocate(capacity: Self.blockCapacity)
        bandOther = .allocate(capacity: Self.blockCapacity)
        decimation = max(1, Int(sampleRate / 8000))
        let decimatedRate = sampleRate / Double(decimation)
        harmonicWindow = Int(0.032 * decimatedRate)
        minLag = max(2, Int(decimatedRate / 400))      // 400 Hz pitch
        maxLag = Int(decimatedRate / 70)               // 70 Hz pitch
        correlation = [Float](repeating: 0, count: maxLag - minLag + 1)
        // ~20 ms spectrum (1024 points at 48 kHz).
        var log2n: vDSP_Length = 6
        while Double(1 << log2n) < 0.02 * sampleRate, log2n < 14 { log2n += 1 }
        fftLog2 = log2n
        fftSize = 1 << Int(log2n)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        fftWindow = .allocate(capacity: fftSize)
        vDSP_hann_window(fftWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftInput = .allocate(capacity: fftSize)
        fftReal = .allocate(capacity: fftSize / 2)
        fftImag = .allocate(capacity: fftSize / 2)
        powerSignal = .allocate(capacity: fftSize / 2)
        powerOther = .allocate(capacity: fftSize / 2)
        let binWidth = sampleRate / Double(fftSize)
        let lowBin = max(1, Int((300 / binWidth).rounded()))
        bandBins = lowBin..<max(lowBin + 1, min(fftSize / 2, Int((top / binWidth).rounded()) + 1))
    }

    deinit {
        vDSP_biquad_DestroySetup(bandSetup)
        vDSP_destroy_fftsetup(fftSetup)
        for buffer in [bandSignal, bandOther, fftWindow, fftInput, fftReal, fftImag, powerSignal, powerOther] {
            buffer.deallocate()
        }
    }

    var activity: SpeechActivity {
        SpeechActivity(codes: codes, knownSlots: knownSlots, speechSlots: speechSlots)
    }

    /// Source time of the next sample `process` expects.
    var nextSampleTime: Double { runStart + Double(runSamples) / sampleRate }

    func beginRun(at time: Double) {
        endRun()
        hasRun = true
        runStart = time
        runSamples = 0
        for i in bandDelay.indices { bandDelay[i] = 0; otherDelay[i] = 0 }
        slot = Int.min
        resetSlotSums()
        decimated.removeAll(keepingCapacity: true)
        decimatedBase = 0
        history.removeAll(keepingCapacity: true)
        historyOther.removeAll(keepingCapacity: true)
        historyBase = 0
        let first = min(SpeechActivityDetector.maxSlots,
                        max(0, Int((time * Double(SpeechActivity.slotsPerSecond)).rounded(.down))))
        pendingStart = first
        committedEnd = first
    }

    /// Commits the whole pending run with the context it has.
    func endRun() {
        guard hasRun else { return }
        if slot != Int.min { emitSlot() }
        commit(final: true)
        clearPending()
        hasRun = false
    }

    func commitProvisionally() {
        guard hasRun else { return }
        commit(final: true, provisional: true)
    }

    /// One block (at most `blockCapacity` samples) of the dialogue signal,
    /// and of the comparison signal when there is one.
    func process(_ signal: UnsafePointer<Float>, other: UnsafePointer<Float>?, count n: Int) {
        guard n > 0, n <= Self.blockCapacity else { return }
        if !hasRun { beginRun(at: 0) }
        hasOther = other != nil
        let length = vDSP_Length(n)
        bandDelay.withUnsafeMutableBufferPointer {
            vDSP_biquad(bandSetup, $0.baseAddress!, signal, 1, bandSignal, 1, length)
        }
        if let other {
            otherDelay.withUnsafeMutableBufferPointer {
                vDSP_biquad(bandSetup, $0.baseAddress!, other, 1, bandOther, 1, length)
            }
        }
        // Decimated band signal for the pitch cue (the band ends below 4 kHz).
        var k = (decimation - runSamples % decimation) % decimation
        while k < n {
            decimated.append(bandSignal[k])
            k += decimation
        }
        history.append(contentsOf: UnsafeBufferPointer(start: signal, count: n))
        if let other { historyOther.append(contentsOf: UnsafeBufferPointer(start: other, count: n)) }

        let warmup = Int(Self.warmupSeconds * sampleRate)
        var j = 0
        while j < n {
            if slot == Int.min { startSlot(at: runSamples + j) }
            let end = min(n, slotEnd - runSamples)
            let from = max(j, warmup - runSamples)
            if end > from {
                let m = vDSP_Length(end - from)
                var value: Float = 0
                vDSP_svesq(bandSignal + from, 1, &value, m); sumBand += value
                vDSP_svesq(signal + from, 1, &value, m); sumTotal += value
                if other != nil { vDSP_svesq(bandOther + from, 1, &value, m); sumOther += value }
                slotCount += end - from
            }
            j = max(end, j + 1)
            if runSamples + j >= slotEnd {
                emitSlot()
                startSlot(at: slotEnd, next: slot + 1)
            }
        }
        runSamples += n
        // Keep only what the next pitch window can reach.
        let keep = harmonicWindow + maxLag + 1 + n / decimation
        if decimated.count > keep {
            let drop = decimated.count - keep
            decimated.removeFirst(drop)
            decimatedBase += drop
        }
        if history.count > fftSize {
            let drop = history.count - fftSize
            history.removeFirst(drop)
            if historyOther.count >= drop { historyOther.removeFirst(drop) } else { historyOther.removeAll() }
            historyBase += drop
        }
        if pBand.count - (committedEnd - pendingStart) >= Self.chunk + Self.context {
            commit(final: false)
        }
    }

    // MARK: Slots

    /// Starts the slot holding run sample `index` (or `next` when the
    /// previous slot just ended there) and finds the sample where it ends.
    private func startSlot(at index: Int, next: Int? = nil) {
        let perSecond = Double(SpeechActivity.slotsPerSecond)
        slot = next ?? Int(((runStart + Double(index) / sampleRate) * perSecond).rounded(.down))
        let boundary = (Double(slot + 1) / perSecond - runStart) * sampleRate
        slotEnd = max(index + 1, Int(boundary.rounded(.up)))
    }

    private func resetSlotSums() {
        sumBand = 0; sumTotal = 0; sumOther = 0; slotCount = 0
    }

    /// Stores the current slot's features (unknown when under half covered).
    private func emitSlot() {
        defer { resetSlotSums() }
        let index = slot - pendingStart
        guard slot >= 0, slot < SpeechActivityDetector.maxSlots, index >= 0 else { return }
        while pBand.count < index { appendUnknown() }
        let known = Double(slotCount) >= 0.5 * slotSamples
        let n = Float(max(1, slotCount))
        let band = 10 * log10(sumBand / n + 1e-10)
        let total = 10 * log10(sumTotal / n + 1e-10)
        let other: Float = hasOther ? 10 * log10(sumOther / n + 1e-10) : .nan
        let harm = known ? harmonicity(endingAt: slotEnd) : 0
        let centred = known ? centredBandLevel(endingAt: slotEnd) : -100
        if index < pBand.count {
            pBand[index] = band; pCentred[index] = centred; pTotal[index] = total; pOther[index] = other
            pHarm[index] = harm; pKnown[index] = known
        } else {
            pBand.append(band); pCentred.append(centred); pTotal.append(total); pOther.append(other)
            pHarm.append(harm); pKnown.append(known)
        }
    }

    private func appendUnknown() {
        pBand.append(-100); pCentred.append(-100); pTotal.append(-100); pOther.append(.nan)
        pHarm.append(0); pKnown.append(false)
    }

    /// Speech-band energy (dB) of the ~20 ms before run sample `end`, each
    /// bin weighted by P / (P + O): the dialogue signal's share of the bin.
    private func centredBandLevel(endingAt end: Int) -> Float {
        let last = end - historyBase
        guard last > 0, last <= history.count else { return -100 }
        let first = last - fftSize
        let comparable = historyOther.count == history.count
        power(of: history, from: first, into: powerSignal)
        if comparable { power(of: historyOther, from: first, into: powerOther) }
        var sum: Float = 0
        for bin in bandBins {
            let p = powerSignal[bin]
            sum += comparable ? p * p / (p + powerOther[bin] + 1e-12) : p
        }
        return 10 * log10(sum / Float(fftSize * fftSize) + 1e-10)
    }

    /// Power spectrum of the Hann-windowed `fftSize` samples starting at
    /// `first` (zeros before the run's first sample).
    private func power(of samples: [Float], from first: Int, into output: UnsafeMutablePointer<Float>) {
        let skip = max(0, -first)
        vDSP_vclr(fftInput, 1, vDSP_Length(fftSize))
        samples.withUnsafeBufferPointer { buffer in
            let count = fftSize - skip
            vDSP_vmul(buffer.baseAddress! + first + skip, 1, fftWindow + skip, 1, fftInput + skip, 1, vDSP_Length(count))
        }
        var split = DSPSplitComplex(realp: fftReal, imagp: fftImag)
        fftInput.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, fftLog2, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, output, 1, vDSP_Length(fftSize / 2))
    }

    /// Peak of the normalised autocorrelation of the decimated band signal
    /// over pitch lags (70–400 Hz), in the 32 ms before run sample `end`:
    /// high for voiced speech, low for noise and most effects.
    private func harmonicity(endingAt end: Int) -> Float {
        let last = (end + decimation - 1) / decimation - decimatedBase
        let start = last - harmonicWindow - maxLag
        guard start >= 0, last <= decimated.count else { return 0 }
        let lags = maxLag - minLag + 1
        return decimated.withUnsafeBufferPointer { buffer -> Float in
            let base = buffer.baseAddress! + start
            let window = base + maxLag
            var energy: Float = 0
            vDSP_svesq(window, 1, &energy, vDSP_Length(harmonicWindow))
            guard energy > 1e-9 else { return 0 }
            // correlation[k] = Σ base[k + p] · window[p], lag = maxLag − k.
            correlation.withUnsafeMutableBufferPointer { out in
                vDSP_conv(base, 1, window, 1, out.baseAddress!, 1, vDSP_Length(lags), vDSP_Length(harmonicWindow))
            }
            var best: Float = 0
            for k in 0..<lags {
                var lagged: Float = 0
                vDSP_svesq(base + k, 1, &lagged, vDSP_Length(harmonicWindow))
                guard lagged > 1e-9 else { continue }
                best = max(best, correlation[k] / (energy * lagged).squareRoot())
            }
            return min(1, best)
        }
    }

    // MARK: Commit

    private func clearPending() {
        pBand.removeAll(keepingCapacity: true); pCentred.removeAll(keepingCapacity: true)
        pTotal.removeAll(keepingCapacity: true)
        pOther.removeAll(keepingCapacity: true); pHarm.removeAll(keepingCapacity: true)
        pKnown.removeAll(keepingCapacity: true)
    }

    /// Scores the pending window and writes the slots ready to commit: all
    /// but the last `context` slots, or every slot when `final`. A
    /// provisional commit writes them without moving `committedEnd`, so the
    /// next pass rewrites them with their full look-ahead.
    private func commit(final: Bool, provisional: Bool = false) {
        let available = pBand.count
        let from = committedEnd - pendingStart
        let to = final ? available : available - Self.context
        guard to > from else { return }
        let lo = max(0, from - Self.context)
        let observer = provisional ? nil : featureObserver
        let probabilities = score(lo..<available, observe: from..<to, observer: observer)
        for i in from..<to {
            write(pKnown[i] ? SpeechActivity.code(for: probabilities[i - lo]) : 0, at: pendingStart + i)
        }
        guard !provisional else { return }
        committedEnd = pendingStart + to
        // Keep `context` slots before the commit point for the next pass.
        let drop = max(0, to - Self.context)
        if drop > 0 {
            pBand.removeFirst(drop); pCentred.removeFirst(drop); pTotal.removeFirst(drop); pOther.removeFirst(drop)
            pHarm.removeFirst(drop); pKnown.removeFirst(drop)
            pendingStart += drop
        }
    }

    private func write(_ code: UInt8, at slot: Int) {
        guard slot >= 0, slot < SpeechActivityDetector.maxSlots else { return }
        if codes.count <= slot { codes.append(contentsOf: repeatElement(0, count: slot + 1 - codes.count)) }
        let old = codes[slot]
        if old != 0 { knownSlots -= 1; if old >= 128 { speechSlots -= 1 } }
        if code != 0 { knownSlots += 1; if code >= 128 { speechSlots += 1 } }
        codes[slot] = code
    }

    /// Speech probability of every pending slot in `range` (pending indices).
    private func score(_ range: Range<Int>, observe: Range<Int>,
                       observer: ((Int, SpeechActivityDetector.SlotFeatures) -> Void)?) -> [Float] {
        let n = range.count
        let band = Array(pBand[range]), total = Array(pTotal[range]), other = Array(pOther[range])
        let known = Array(pKnown[range])
        let comparable = other.contains { !$0.isNaN }

        let centred = Array(pCentred[range])
        let floor = Self.slidingPercentile(centred, known: known, fraction: 0.1)
        var level = [Float](repeating: 0, count: n)
        for i in 0..<n { level[i] = min(max(centred[i] - floor[i], 0), 30) }

        // Syllabic modulation: 2–8 Hz band-pass of the level, RMS over 0.5 s.
        var bandPass = Biquad100(bandPassAt: 4, q: 0.5)
        let modulation = Self.movingRMS(level.map { bandPass.run($0) }, radius: 25)

        // Dominance only counts where the dialogue signal is active: a centre
        // channel carrying room tone over silent sides is not speech.
        var dominance = [Float](repeating: 0, count: n)
        if comparable {
            for i in 0..<n where !other[i].isNaN {
                dominance[i] = min(max(band[i] - other[i], -15), 15) * min(1, level[i] / 10)
            }
        }
        let dominanceFloor = comparable ? Self.slidingPercentile(dominance, known: known, fraction: 0.1) : dominance
        let voicing = Self.movingAverage(Array(pHarm[range]), radius: 2)

        let w = weights
        var p = [Float](repeating: 0, count: n)
        for i in 0..<n where known[i] {
            let f = SpeechActivityDetector.SlotFeatures(
                level: level[i], modulation: modulation[i], harmonicity: voicing[i],
                bandRatio: min(max(band[i] - total[i], -30), 0),
                dominance: dominance[i],
                dominanceMargin: min(max(dominance[i] - dominanceFloor[i], 0), 30))
            var z = w.intercept + w.level * f.level + w.modulation * f.modulation + w.harmonicity * f.harmonicity
            z += w.bandRatio * f.bandRatio + w.dominance * f.dominance + w.dominanceMargin * f.dominanceMargin
            if band[i] < -70 { z -= 8 }           // near digital silence: never speech
            p[i] = 1 / (1 + exp(-z))
            if let observer, observe.contains(range.lowerBound + i) {
                observer(pendingStart + range.lowerBound + i, f)
            }
        }
        // Merge gaps under 250 ms, drop blips under 150 ms, 150 ms hangover.
        var smooth = Self.movingAverage(p, radius: 2)
        smooth = Self.minFilter(Self.maxFilter(smooth, radius: 12), radius: 12)
        smooth = Self.maxFilter(Self.minFilter(smooth, radius: 7), radius: 7)
        var hold: Float = 0
        for i in 0..<n {
            hold = max(smooth[i], hold - 1 / 15)
            smooth[i] = hold
        }
        return smooth
    }

    // MARK: Helpers

    /// Low percentile of the known values within ±`floorRadius`, computed
    /// every `floorStep` slots and interpolated (minimum statistics).
    private static func slidingPercentile(_ values: [Float], known: [Bool], fraction: Float) -> [Float] {
        let n = values.count
        guard n > 0 else { return [] }
        var anchors: [(Int, Float)] = []
        var window: [Float] = []
        window.reserveCapacity(2 * floorRadius + 1)
        var center = 0
        while true {
            window.removeAll(keepingCapacity: true)
            for i in max(0, center - floorRadius)..<min(n, center + floorRadius + 1) where known[i] {
                window.append(values[i])
            }
            if !window.isEmpty {
                window.sort()
                anchors.append((center, window[min(window.count - 1, Int(Float(window.count) * fraction))]))
            }
            if center >= n - 1 { break }
            center = min(n - 1, center + floorStep)
        }
        guard !anchors.isEmpty else { return [Float](repeating: -100, count: n) }
        var out = [Float](repeating: anchors[0].1, count: n)
        var a = 0
        for i in 0..<n {
            while a + 1 < anchors.count, anchors[a + 1].0 <= i { a += 1 }
            if a + 1 < anchors.count, i > anchors[a].0 {
                let (x0, y0) = anchors[a], (x1, y1) = anchors[a + 1]
                out[i] = y0 + (y1 - y0) * Float(i - x0) / Float(x1 - x0)
            } else {
                out[i] = anchors[a].1
            }
        }
        return out
    }

    private static func movingAverage(_ x: [Float], radius: Int) -> [Float] {
        let n = x.count
        guard n > 0 else { return [] }
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] }
        return (0..<n).map { i in
            let a = max(0, i - radius), b = min(n, i + radius + 1)
            return (prefix[b] - prefix[a]) / Float(b - a)
        }
    }

    private static func movingRMS(_ x: [Float], radius: Int) -> [Float] {
        movingAverage(x.map { $0 * $0 }, radius: radius).map { $0.squareRoot() }
    }

    private static func maxFilter(_ x: [Float], radius: Int) -> [Float] {
        slidingExtreme(x, radius: radius, keepsMax: true)
    }

    private static func minFilter(_ x: [Float], radius: Int) -> [Float] {
        slidingExtreme(x, radius: radius, keepsMax: false)
    }

    /// Sliding max or min over ±radius (monotonic deque, O(n)).
    private static func slidingExtreme(_ x: [Float], radius: Int, keepsMax: Bool) -> [Float] {
        let n = x.count
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        var deque = [Int](repeating: 0, count: n)
        var head = 0, tail = 0, next = 0
        for i in 0..<n {
            while next <= min(n - 1, i + radius) {
                while tail > head, keepsMax ? x[deque[tail - 1]] <= x[next] : x[deque[tail - 1]] >= x[next] {
                    tail -= 1
                }
                deque[tail] = next
                tail += 1
                next += 1
            }
            while deque[head] < i - radius { head += 1 }
            out[i] = x[deque[head]]
        }
        return out
    }

    /// RBJ cookbook section as [b0, b1, b2, a1, a2] (vDSP order).
    private static func biquad(highPass: Bool, frequency: Double, q: Double, rate: Double) -> [Double] {
        let w = 2 * Double.pi * frequency / rate
        let alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        let b0 = (highPass ? (1 + c) / 2 : (1 - c) / 2) / a0
        let b1 = (highPass ? -(1 + c) : (1 - c)) / a0
        return [b0, b1, b0, -2 * c / a0, (1 - alpha) / a0]
    }
}

/// Scalar biquad on the 100 Hz feature series (RBJ band-pass, 0 dB peak).
private struct Biquad100 {
    private let b0: Float, b2: Float, a1: Float, a2: Float
    private var z1: Float = 0, z2: Float = 0

    init(bandPassAt frequency: Double, q: Double) {
        let w = 2 * Double.pi * frequency / Double(SpeechActivity.slotsPerSecond)
        let alpha = sin(w) / (2 * q), a0 = 1 + alpha
        b0 = Float(alpha / a0)
        b2 = Float(-alpha / a0)
        a1 = Float(-2 * cos(w) / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func run(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = -a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
