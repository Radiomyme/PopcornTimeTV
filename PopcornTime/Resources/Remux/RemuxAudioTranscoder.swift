import Foundation
import AudioToolbox

// CONTRACT FILE — owned by agent A5. Lossless on-device re-encode for audio
// that Apple's HLS stack can't take as-is from Matroska: raw PCM
// (A_PCM/INT/LIT, A_PCM/INT/BIG, A_PCM/FLOAT/IEEE) → FLAC via AudioToolbox.
//
// Blu-ray remuxes often carry LPCM (2.0 / 5.1 / 7.1, 16 or 24 bits). Apple
// can't play raw PCM inside fMP4 HLS, but it plays FLAC there, so the PCM is
// re-encoded with Apple's own FLAC encoder (`AudioConverter` → ACFLACEncoder,
// libFLAC-based, shipped on macOS, iOS and tvOS; fixed 4608-sample blocks,
// compression level 0) and muxed as `fLaC` + `dfLa`.
//
// Encoder behaviour this file accounts for (measured, macOS 27 / tvOS 26 / iOS 26):
//  - block k is emitted once block k+1 is complete (one block of latency);
//  - a stream shorter than one block produces nothing at end of stream →
//    `flush()` writes that single frame itself (verbatim subframes);
//  - the magic cookie is a complete `dfLa` box (STREAMINFO, last-block flag set).
//
// Bit-exactness:
//  - 16 / 24-bit integer (either endianness) → FLAC of the same depth, exact.
//  - 8-bit (unsigned, as in WAVE / Matroska) → 16-bit FLAC (value << 8), exact.
//  - Other integer depths use their byte container (9…16 → 16, 17…24 → 24).
//  - 32-bit integer → 24-bit FLAC (top 24 bits): Apple's FLAC encoder only
//    accepts 16 and 24-bit sources. Exact for 24-bit content padded to 32.
//  - 32/64-bit float → 24-bit integer (round to nearest, clipped): FLAC has
//    no float samples.
// Channel order: Matroska PCM uses the WAVE order (FL FR FC LFE BL BR SL SR),
// which is also FLAC's canonical order for every channel count 1…8. The
// converter is configured with identical input/output channel layouts so
// that AudioToolbox never reorders or remixes anything.
//
// Threading: an instance is driven from ONE serial queue (the session's
// `remux.pump` queue); calls are additionally serialized by a lock. Nothing
// here touches the main thread.

final class RemuxAudioTranscoder {

    struct Packet {
        let data: Data
        /// PCM samples (per channel) represented by this packet.
        let samples: UInt32
    }

    /// Layout of the Matroska PCM payload and of the FLAC stream it becomes.
    struct PCMFormat: Equatable {
        enum SampleKind: Equatable {
            /// 8-bit, unsigned (offset binary), as in WAVE / Matroska / ffmpeg.
            case unsigned8
            case signedLittleEndian
            case signedBigEndian
            case floatLittleEndian
        }

        let kind: SampleKind
        /// Bytes per sample in the Matroska block (1…4 for integers, 4 or 8 for floats).
        let containerBytes: Int
        let channels: Int
        let sampleRate: Int
        /// Bits per sample of the FLAC stream (16 or 24).
        let outputBits: Int

        var inputBytesPerFrame: Int { containerBytes * channels }
        var outputBytesPerSample: Int { outputBits / 8 }
        var outputBytesPerFrame: Int { outputBytesPerSample * channels }

        /// True when every source bit survives (integer ≤ 24 bits).
        var isBitExact: Bool {
            switch kind {
            case .unsigned8: return true
            case .signedLittleEndian, .signedBigEndian: return containerBytes <= 3
            case .floatLittleEndian: return false
            }
        }

        static let supportedCodecIDs: Set<String> = ["A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE"]
        static let maxSampleRate = 192_000
        static let minSampleRate = 8_000

        /// nil when the track isn't PCM or its parameters are out of range.
        init?(track: MKVTrack) {
            guard let format = PCMFormat.validate(track: track).format else { return nil }
            self = format
        }

        private init(kind: SampleKind, containerBytes: Int, channels: Int, sampleRate: Int, outputBits: Int) {
            self.kind = kind
            self.containerBytes = containerBytes
            self.channels = channels
            self.sampleRate = sampleRate
            self.outputBits = outputBits
        }

        /// Either a format or a short French reason why the track can't be encoded.
        fileprivate static func validate(track: MKVTrack) -> (format: PCMFormat?, failure: String?) {
            let codecID = track.codecID.uppercased()
            guard supportedCodecIDs.contains(codecID) else {
                return (nil, "\(track.codecID) n'est pas du PCM")
            }
            guard (1...8).contains(track.channels) else {
                return (nil, "PCM \(track.channels) canaux non pris en charge (FLAC : 8 au maximum)")
            }
            let rateValue = track.samplingFrequency.rounded()
            guard rateValue.isFinite, rateValue >= Double(minSampleRate), rateValue <= Double(maxSampleRate) else {
                return (nil, "PCM à \(String(format: "%.0f", track.samplingFrequency)) Hz non pris en charge")
            }
            let rate = Int(rateValue)

            if codecID == "A_PCM/FLOAT/IEEE" {
                let depth = track.bitDepth ?? 32
                guard depth == 32 || depth == 64 else {
                    return (nil, "PCM flottant \(depth) bits non pris en charge")
                }
                return (PCMFormat(kind: .floatLittleEndian, containerBytes: depth / 8, channels: track.channels,
                                  sampleRate: rate, outputBits: 24), nil)
            }

            let depth = track.bitDepth ?? 16
            guard (1...32).contains(depth) else {
                return (nil, "PCM \(depth) bits non pris en charge")
            }
            let container = (depth + 7) / 8
            let kind: SampleKind
            if container == 1 {
                kind = .unsigned8
            } else {
                kind = codecID == "A_PCM/INT/BIG" ? .signedBigEndian : .signedLittleEndian
            }
            let outputBits = container <= 2 ? 16 : 24
            return (PCMFormat(kind: kind, containerBytes: container, channels: track.channels,
                              sampleRate: rate, outputBits: outputBits), nil)
        }
    }

    // MARK: - Contract API

    /// True when `track` is a PCM layout this transcoder can encode
    /// (1…8 channels, 8…32-bit integer or 32/64-bit float, 8…192 kHz) AND
    /// the platform's FLAC encoder accepts that configuration.
    static func canTranscode(track: MKVTrack) -> Bool {
        return unsupportedReason(track: track) == nil
    }

    /// nil when `track` can be transcoded, else a short French reason (logs).
    static func unsupportedReason(track: MKVTrack) -> String? {
        let checked = PCMFormat.validate(track: track)
        guard let format = checked.format else { return checked.failure ?? "PCM non pris en charge" }
        return encoderAvailable(for: format) ? nil : "Encodeur FLAC indisponible pour ce PCM"
    }

    /// Plan describing the ENCODED output (fLaC sample entry with the
    /// encoder's STREAMINFO in `dfLa`, codecs "fLaC", timescale = sample rate).
    let plan: RemuxAudioPlan

    /// Source / output layout this instance converts.
    let format: PCMFormat
    /// Samples per FLAC packet (block size) of the encoder (4608 for Apple's).
    let framesPerPacket: UInt32
    /// The 34-byte STREAMINFO advertised in `dfLa`.
    let streamInfo: Data

    /// Total PCM samples (per channel) accepted by `push`.
    var samplesReceived: UInt64 { lock.lock(); defer { lock.unlock() }; return receivedFrames }
    /// Total PCM samples (per channel) represented by the packets returned so far.
    var samplesEmitted: UInt64 { lock.lock(); defer { lock.unlock() }; return emittedFrames }
    /// Set once the encoder reported an unexpected error; further pushes return nothing.
    var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }

    /// Number of whole PCM samples (per channel) in one Matroska block payload.
    func inputSampleCount(of frame: Data) -> Int {
        frame.count / format.inputBytesPerFrame
    }

    init?(track: MKVTrack) {
        guard let format = PCMFormat.validate(track: track).format,
              let created = RemuxAudioTranscoder.makeConverter(format) else { return nil }
        let converter = created.converter

        // Packet geometry.
        let fpp = created.output.mFramesPerPacket > 0 ? created.output.mFramesPerPacket : 4608
        var maxPacket: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        if AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize,
                                     &propertySize, &maxPacket) != noErr || maxPacket == 0 {
            // Worst case FLAC frame: verbatim subframes + headers/footer.
            maxPacket = fpp * UInt32(format.outputBytesPerFrame) + UInt32(64 + 2 * format.channels)
        }

        // STREAMINFO from the encoder's magic cookie, normalized.
        var cookieStreamInfo: Data?
        var cookieSize: UInt32 = 0
        if AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &cookieSize, nil) == noErr,
           cookieSize > 0 {
            var cookie = Data(count: Int(cookieSize))
            let status = cookie.withUnsafeMutableBytes { raw -> OSStatus in
                AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &cookieSize, raw.baseAddress!)
            }
            if status == noErr {
                cookieStreamInfo = RemuxAudioTranscoder.streamInfo(fromMagicCookie: cookie.prefix(Int(cookieSize)))
            }
        }
        let info: Data
        if let candidate = cookieStreamInfo,
           RemuxAudioTranscoder.streamInfo(candidate, matches: format, blockSize: Int(fpp)) {
            info = RemuxAudioTranscoder.sanitizedStreamInfo(candidate)
        } else {
            info = RemuxAudioTranscoder.makeStreamInfo(blockSize: Int(fpp), sampleRate: format.sampleRate,
                                                       channels: format.channels, bitsPerSample: format.outputBits)
        }

        self.format = format
        self.converter = converter
        self.framesPerPacket = fpp
        self.maxOutputPacketSize = Int(maxPacket)
        self.streamInfo = info
        self.plan = RemuxAudioTranscoder.makePlan(format: format, streamInfo: info, framesPerPacket: fpp)
    }

    deinit {
        AudioConverterDispose(converter)
        inputChunk?.deallocate()
        outputBuffer?.deallocate()
        outputDescriptions?.deallocate()
    }

    /// Feed one Matroska block payload of interleaved PCM. Returns the FLAC
    /// packets completed so far (possibly none — the encoder buffers).
    ///
    /// Latency: Apple's FLAC encoder emits block k only once block k+1 is
    /// complete, so up to 2 × `framesPerPacket` − 1 samples (≈ 190 ms at
    /// 48 kHz) can be in flight; `flush()` returns the rest. Packet times
    /// must therefore come from the emitted sample count, not from the
    /// timestamps of the blocks just pushed.
    func push(_ frame: Data) -> [Packet] {
        lock.lock(); defer { lock.unlock() }
        guard !failed, !finished, !frame.isEmpty else { return [] }
        appendInput(frame)
        return encode(endOfStream: false)
    }

    /// Drain the encoder at end of stream.
    func flush() -> [Packet] {
        lock.lock(); defer { lock.unlock() }
        guard !failed, !finished else { return [] }
        finished = true
        if !carry.isEmpty {
            print("[Remux] PCM→FLAC: dropping \(carry.count) trailing byte(s) of an incomplete sample frame")
            carry.removeAll()
        }
        // Apple's encoder silently drops a whole stream shorter than one
        // block (< 4608 samples) at end of stream: write that single frame
        // ourselves (verbatim subframes, still lossless).
        let shortStream = pendingFrameCount
        if fedFrames == 0 && shortStream > 0 && shortStream < Int(framesPerPacket) {
            let packet = pending.withUnsafeBytes { raw in
                RemuxAudioTranscoder.verbatimFrame(
                    pcm: UnsafeRawBufferPointer(rebasing: raw[pendingReadOffset...]),
                    frames: shortStream, format: format, frameNumber: 0)
            }
            pending.removeAll()
            pendingReadOffset = 0
            fedFrames += UInt64(shortStream)
            emittedFrames += UInt64(shortStream)
            return [Packet(data: packet, samples: UInt32(shortStream))]
        }
        let packets = encode(endOfStream: true)
        if !failed && emittedFrames != fedFrames {
            print("[Remux] PCM→FLAC: \(fedFrames) samples encoded but \(emittedFrames) emitted")
        }
        return packets
    }

    // MARK: - State

    private let converter: AudioConverterRef
    private let maxOutputPacketSize: Int
    private let lock = NSLock()

    /// Encoder-ready PCM (packed little-endian 16/24-bit) not yet handed to the converter.
    private var pending: [UInt8] = []
    private var pendingReadOffset = 0
    /// Trailing bytes of an incomplete sample frame from the previous push.
    private var carry: [UInt8] = []

    /// Memory handed to the converter by the input callback; must stay valid
    /// until the next callback, so it's only replaced from inside the callback.
    private var inputChunk: UnsafeMutableRawPointer?
    private var inputChunkCapacity = 0

    private var outputBuffer: UnsafeMutableRawPointer?
    private var outputDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    private var outputPacketCapacity = 0

    private var receivedFrames: UInt64 = 0
    private var fedFrames: UInt64 = 0
    private var emittedFrames: UInt64 = 0
    private var signalEndOfStream = false
    private var finished = false
    private var failed = false

    /// Returned by the input callback when the PCM buffer runs dry mid-stream:
    /// the converter stops, keeps its partial block and returns what it has.
    private static let needMoreInputStatus: OSStatus = 0x6D6F7265 // 'more'
    private static let maxPacketsPerCall = 8

    // MARK: - Input

    private var pendingFrameCount: Int {
        (pending.count - pendingReadOffset) / format.outputBytesPerFrame
    }

    private func appendInput(_ frame: Data) {
        if carry.isEmpty {
            frame.withUnsafeBytes { raw in appendWholeFrames(raw) }
        } else {
            // Rare: a block ended mid sample frame; prepend its tail.
            var joined = carry
            joined.append(contentsOf: frame)
            carry.removeAll(keepingCapacity: true)
            joined.withUnsafeBytes { raw in appendWholeFrames(raw) }
        }
    }

    /// Converts every whole sample frame of `raw` and keeps the remainder in `carry`.
    private func appendWholeFrames(_ raw: UnsafeRawBufferPointer) {
        let bytesPerFrame = format.inputBytesPerFrame
        let frames = raw.count / bytesPerFrame
        let used = frames * bytesPerFrame
        if used < raw.count {
            carry.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[used...]))
        }
        guard frames > 0 else { return }
        if pendingReadOffset > 0 && pendingReadOffset == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingReadOffset = 0
        }
        pending.append(contentsOf: RemuxAudioTranscoder.convert(UnsafeRawBufferPointer(rebasing: raw[0..<used]),
                                                                frames: frames, format: format))
        receivedFrames += UInt64(frames)
    }

    /// Matroska PCM → packed little-endian signed 16 or 24-bit, interleaved.
    static func convert(_ src: UnsafeRawBufferPointer, frames: Int, format: PCMFormat) -> [UInt8] {
        let samples = frames * format.channels
        let outBytes = format.outputBytesPerSample
        precondition(src.count >= samples * format.containerBytes)
        return [UInt8](unsafeUninitializedCapacity: samples * outBytes) { out, count in
            let s = src.bindMemory(to: UInt8.self)
            switch (format.kind, format.containerBytes) {
            case (.unsigned8, _):
                for i in 0..<samples {
                    let value = (Int16(s[i]) - 128) << 8
                    out[2 * i] = UInt8(truncatingIfNeeded: value)
                    out[2 * i + 1] = UInt8(truncatingIfNeeded: value >> 8)
                }
            case (.signedLittleEndian, 2), (.signedLittleEndian, 3):
                if samples > 0 {
                    UnsafeMutableRawPointer(out.baseAddress!).copyMemory(from: s.baseAddress!, byteCount: samples * outBytes)
                }
            case (.signedBigEndian, 2):
                for i in 0..<samples {
                    out[2 * i] = s[2 * i + 1]
                    out[2 * i + 1] = s[2 * i]
                }
            case (.signedBigEndian, 3):
                for i in 0..<samples {
                    out[3 * i] = s[3 * i + 2]
                    out[3 * i + 1] = s[3 * i + 1]
                    out[3 * i + 2] = s[3 * i]
                }
            case (.signedLittleEndian, _): // 4 bytes → top 24 bits
                for i in 0..<samples {
                    out[3 * i] = s[4 * i + 1]
                    out[3 * i + 1] = s[4 * i + 2]
                    out[3 * i + 2] = s[4 * i + 3]
                }
            case (.signedBigEndian, _): // 4 bytes → top 24 bits
                for i in 0..<samples {
                    out[3 * i] = s[4 * i + 2]
                    out[3 * i + 1] = s[4 * i + 1]
                    out[3 * i + 2] = s[4 * i]
                }
            case (.floatLittleEndian, 8):
                for i in 0..<samples {
                    var bits: UInt64 = 0
                    for b in 0..<8 { bits |= UInt64(s[8 * i + b]) << UInt64(8 * b) }
                    let value = int24(fromUnit: Double(bitPattern: bits))
                    out[3 * i] = UInt8(truncatingIfNeeded: value)
                    out[3 * i + 1] = UInt8(truncatingIfNeeded: value >> 8)
                    out[3 * i + 2] = UInt8(truncatingIfNeeded: value >> 16)
                }
            case (.floatLittleEndian, _):
                for i in 0..<samples {
                    let bits = UInt32(s[4 * i]) | UInt32(s[4 * i + 1]) << 8
                        | UInt32(s[4 * i + 2]) << 16 | UInt32(s[4 * i + 3]) << 24
                    let value = int24(fromUnit: Double(Float(bitPattern: bits)))
                    out[3 * i] = UInt8(truncatingIfNeeded: value)
                    out[3 * i + 1] = UInt8(truncatingIfNeeded: value >> 8)
                    out[3 * i + 2] = UInt8(truncatingIfNeeded: value >> 16)
                }
            }
            count = samples * outBytes
        }
    }

    /// Float sample (nominal −1…1) → signed 24-bit, round to nearest, clipped.
    @inline(__always)
    static func int24(fromUnit x: Double) -> Int32 {
        if x.isNaN { return 0 }
        let scaled = (x * 8_388_608).rounded()
        if scaled >= 8_388_607 { return 8_388_607 }
        if scaled <= -8_388_608 { return -8_388_608 }
        return Int32(scaled)
    }

    // MARK: - Encoding

    private func encode(endOfStream: Bool) -> [Packet] {
        var packets: [Packet] = []
        signalEndOfStream = endOfStream
        defer {
            signalEndOfStream = false
            compactPending()
        }
        while true {
            let heldByConverter = fedFrames > emittedFrames ? Int(fedFrames - emittedFrames) : 0
            let available = pendingFrameCount + heldByConverter
            var wanted: Int
            if endOfStream {
                wanted = available / Int(framesPerPacket) + 1
            } else {
                wanted = available / Int(framesPerPacket)
                if wanted == 0 { break }
            }
            wanted = min(wanted, RemuxAudioTranscoder.maxPacketsPerCall)
            ensureOutputCapacity(packets: wanted)
            guard let outputBuffer = outputBuffer, let descriptions = outputDescriptions else { break }

            let byteCapacity = wanted * maxOutputPacketSize
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(format.channels),
                                      mDataByteSize: UInt32(byteCapacity),
                                      mData: outputBuffer))
            var ioPackets = UInt32(wanted)
            let status = AudioConverterFillComplexBuffer(converter, RemuxAudioTranscoder.inputCallback,
                                                         Unmanaged.passUnretained(self).toOpaque(),
                                                         &ioPackets, &bufferList, descriptions)
            let produced = Int(ioPackets)
            for index in 0..<produced {
                let description = descriptions[index]
                let start = Int(description.mStartOffset)
                let length = Int(description.mDataByteSize)
                guard length > 0, start >= 0, start + length <= byteCapacity else { continue }
                let data = Data(bytes: outputBuffer.advanced(by: start), count: length)
                let samples = sampleCount(of: data, description: description, endOfStream: endOfStream)
                emittedFrames += UInt64(samples)
                packets.append(Packet(data: data, samples: samples))
            }
            if status != noErr && status != RemuxAudioTranscoder.needMoreInputStatus {
                failed = true
                print("[Remux] PCM→FLAC: encoder error \(status), track dropped from here on")
                break
            }
            if produced == 0 { break }
            if !endOfStream && produced < wanted { break }
        }
        return packets
    }

    /// Exact PCM duration of one FLAC packet.
    private func sampleCount(of data: Data, description: AudioStreamPacketDescription, endOfStream: Bool) -> UInt32 {
        if let blockSize = RemuxAudioTranscoder.flacFrameBlockSize(data) {
            return UInt32(blockSize)
        }
        if description.mVariableFramesInPacket > 0 {
            return description.mVariableFramesInPacket
        }
        if endOfStream && fedFrames > emittedFrames {
            let remaining = fedFrames - emittedFrames
            if remaining < UInt64(framesPerPacket) { return UInt32(remaining) }
        }
        return framesPerPacket
    }

    private func compactPending() {
        guard pendingReadOffset > 0 else { return }
        if pendingReadOffset >= pending.count {
            pending.removeAll(keepingCapacity: true)
        } else {
            pending.removeSubrange(0..<pendingReadOffset)
        }
        pendingReadOffset = 0
    }

    private func ensureOutputCapacity(packets: Int) {
        guard packets > outputPacketCapacity else { return }
        outputBuffer?.deallocate()
        outputDescriptions?.deallocate()
        let capacity = max(packets, RemuxAudioTranscoder.maxPacketsPerCall)
        outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: capacity * maxOutputPacketSize, alignment: 16)
        outputDescriptions = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: capacity)
        outputDescriptions?.initialize(repeating: AudioStreamPacketDescription(), count: capacity)
        outputPacketCapacity = capacity
    }

    private static let inputCallback: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, outDescriptions, userData in
        outDescriptions?.pointee = nil
        guard let userData = userData else {
            ioNumberDataPackets.pointee = 0
            return RemuxAudioTranscoder.needMoreInputStatus
        }
        let transcoder = Unmanaged<RemuxAudioTranscoder>.fromOpaque(userData).takeUnretainedValue()
        return transcoder.provideInput(ioNumberDataPackets, ioData)
    }

    /// AudioConverter input callback body (runs synchronously inside
    /// `AudioConverterFillComplexBuffer`, i.e. under `lock`).
    private func provideInput(_ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                              _ ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        // Interleaved PCM = exactly one AudioBuffer (`mBuffers`). Accessed
        // directly: `UnsafeMutableAudioBufferListPointer` lives in the CoreAudio
        // overlay, which AudioToolbox doesn't re-export on iOS / tvOS.
        let hasBuffer = ioData.pointee.mNumberBuffers > 0
        let available = pendingFrameCount
        guard available > 0, hasBuffer else {
            ioNumberDataPackets.pointee = 0
            if hasBuffer {
                ioData.pointee.mBuffers.mData = nil
                ioData.pointee.mBuffers.mDataByteSize = 0
            }
            // Empty + noErr = end of stream (the encoder then emits its last,
            // possibly short, block); mid-stream we only pause the converter.
            return signalEndOfStream ? noErr : RemuxAudioTranscoder.needMoreInputStatus
        }
        let frames = min(max(1, Int(ioNumberDataPackets.pointee)), available)
        let byteCount = frames * format.outputBytesPerFrame
        if byteCount > inputChunkCapacity {
            // The previous chunk is no longer referenced: the converter only
            // needs it until this next callback.
            inputChunk?.deallocate()
            let capacity = max(byteCount, Int(framesPerPacket) * format.outputBytesPerFrame)
            inputChunk = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
            inputChunkCapacity = capacity
        }
        guard let chunk = inputChunk else {
            ioNumberDataPackets.pointee = 0
            return RemuxAudioTranscoder.needMoreInputStatus
        }
        pending.withUnsafeBytes { raw in
            chunk.copyMemory(from: raw.baseAddress!.advanced(by: pendingReadOffset), byteCount: byteCount)
        }
        pendingReadOffset += byteCount
        fedFrames += UInt64(frames)
        ioData.pointee.mBuffers.mNumberChannels = UInt32(format.channels)
        ioData.pointee.mBuffers.mData = chunk
        ioData.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
        ioNumberDataPackets.pointee = UInt32(frames)
        return noErr
    }

    // MARK: - Converter setup

    private struct ProbeKey: Hashable {
        let sampleRate: Int
        let channels: Int
        let outputBits: Int
    }

    private static var probeCache: [ProbeKey: Bool] = [:]
    private static let probeLock = NSLock()

    /// Whether this platform's AudioToolbox can encode `format` to FLAC (cached).
    static func encoderAvailable(for format: PCMFormat) -> Bool {
        let key = ProbeKey(sampleRate: format.sampleRate, channels: format.channels, outputBits: format.outputBits)
        probeLock.lock()
        if let cached = probeCache[key] {
            probeLock.unlock()
            return cached
        }
        probeLock.unlock()
        var available = false
        if let created = makeConverter(format) {
            AudioConverterDispose(created.converter)
            available = true
        }
        probeLock.lock()
        probeCache[key] = available
        probeLock.unlock()
        return available
    }

    /// Creates the PCM → FLAC converter with identical input/output channel
    /// layouts (no reordering, no remix).
    private static func makeConverter(_ format: PCMFormat) -> (converter: AudioConverterRef, output: AudioStreamBasicDescription)? {
        var input = AudioStreamBasicDescription(
            mSampleRate: Double(format.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(format.outputBytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(format.outputBytesPerFrame),
            mChannelsPerFrame: UInt32(format.channels),
            mBitsPerChannel: UInt32(format.outputBits),
            mReserved: 0)
        var output = AudioStreamBasicDescription()
        output.mFormatID = kAudioFormatFLAC
        output.mSampleRate = Double(format.sampleRate)
        output.mChannelsPerFrame = UInt32(format.channels)
        output.mFormatFlags = format.outputBits == 24
            ? AudioFormatFlags(kAppleLosslessFormatFlag_24BitSourceData)
            : AudioFormatFlags(kAppleLosslessFormatFlag_16BitSourceData)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &output) == noErr else { return nil }

        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter = converter else { return nil }

        // Apple's FLAC encoder maps the codec quality to compression level 0
        // (Min) or 5 (anything else). Level 0 encodes 1.5–2.5× faster for
        // 2–4 % bigger frames — still bit-exact, and size is irrelevant for
        // segments served over loopback — so favour CPU (Apple TV, battery).
        var quality = UInt32(kAudioConverterQuality_Min)
        _ = AudioConverterSetProperty(converter, kAudioConverterCodecQuality,
                                      UInt32(MemoryLayout<UInt32>.size), &quality)

        if !alignChannelLayouts(converter, channels: format.channels) {
            AudioConverterDispose(converter)
            return nil
        }

        var current = AudioStreamBasicDescription()
        var currentSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioConverterGetProperty(converter, kAudioConverterCurrentOutputStreamDescription,
                                     &currentSize, &current) == noErr, current.mFramesPerPacket > 0 {
            output = current
        }
        return (converter, output)
    }

    /// FLAC's canonical channel order for 1…8 channels as Apple layout tags
    /// (what Apple's FLAC encoder reports by default; same order as WAVE).
    static func flacChannelLayoutTag(channels: Int) -> AudioChannelLayoutTag {
        switch channels {
        case 1: return kAudioChannelLayoutTag_Mono          // C
        case 2: return kAudioChannelLayoutTag_Stereo        // L R
        case 3: return kAudioChannelLayoutTag_MPEG_3_0_A    // L R C
        case 4: return kAudioChannelLayoutTag_WAVE_4_0_B    // L R Rls Rrs
        case 5: return kAudioChannelLayoutTag_MPEG_5_0_A    // L R C Ls Rs
        case 6: return kAudioChannelLayoutTag_MPEG_5_1_A    // L R C LFE Ls Rs
        case 7: return kAudioChannelLayoutTag_WAVE_6_1      // L R C LFE Cs Ls Rs
        default: return kAudioChannelLayoutTag_WAVE_7_1     // L R C LFE Rls Rrs Ls Rs
        }
    }

    /// Makes the converter's input layout identical to its output layout so
    /// the samples go through in their original order. Returns false only if
    /// the layouts are known to differ and can't be aligned.
    private static func alignChannelLayouts(_ converter: AudioConverterRef, channels: Int) -> Bool {
        var outputSize: UInt32 = 0
        if AudioConverterGetPropertyInfo(converter, kAudioConverterOutputChannelLayout, &outputSize, nil) == noErr,
           outputSize >= UInt32(MemoryLayout<AudioChannelLayout>.size) {
            let layout = UnsafeMutableRawPointer.allocate(byteCount: Int(outputSize), alignment: 16)
            defer { layout.deallocate() }
            var size = outputSize
            if AudioConverterGetProperty(converter, kAudioConverterOutputChannelLayout, &size, layout) == noErr {
                if AudioConverterSetProperty(converter, kAudioConverterInputChannelLayout, size, layout) == noErr {
                    return true
                }
                // Not settable: fine as long as the input already matches.
                return channelLayoutsMatch(converter)
            }
        }
        // No readable output layout: pin both sides to FLAC's canonical order.
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = flacChannelLayoutTag(channels: channels)
        let size = UInt32(MemoryLayout<AudioChannelLayout>.size)
        let setOutput = AudioConverterSetProperty(converter, kAudioConverterOutputChannelLayout, size, &layout)
        let setInput = AudioConverterSetProperty(converter, kAudioConverterInputChannelLayout, size, &layout)
        if setOutput == noErr && setInput == noErr { return true }
        return channels <= 2 || channelLayoutsMatch(converter)
    }

    private static func channelLayoutsMatch(_ converter: AudioConverterRef) -> Bool {
        func read(_ property: AudioConverterPropertyID) -> Data? {
            var size: UInt32 = 0
            guard AudioConverterGetPropertyInfo(converter, property, &size, nil) == noErr, size > 0 else { return nil }
            var data = Data(count: Int(size))
            let status = data.withUnsafeMutableBytes { raw in
                AudioConverterGetProperty(converter, property, &size, raw.baseAddress!)
            }
            return status == noErr ? data.prefix(Int(size)) : nil
        }
        guard let input = read(kAudioConverterInputChannelLayout),
              let output = read(kAudioConverterOutputChannelLayout) else { return true } // nothing to remap
        return input == output
    }

    // MARK: - FLAC metadata

    /// Extracts the 34-byte STREAMINFO body from the encoder's magic cookie,
    /// whatever its wrapping: a complete `dfLa` box (what Apple returns: size,
    /// 'dfLa', version/flags, metadata blocks), "fLaC" + metadata blocks, bare
    /// metadata blocks, or a bare STREAMINFO body.
    static func streamInfo(fromMagicCookie cookie: Data) -> Data? {
        let bytes = [UInt8](cookie)

        func firstStreamInfo(blocksAt start: Int) -> Data? {
            var position = start
            while position + 4 <= bytes.count {
                let header = bytes[position]
                let length = Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
                if header & 0x7F == 0 {
                    guard length == 34, position + 4 + 34 <= bytes.count else { return nil }
                    return Data(bytes[(position + 4)..<(position + 38)])
                }
                if header & 0x80 != 0 { return nil }
                position += 4 + length
            }
            return nil
        }

        func find(_ tag: String) -> Int? {
            let pattern = Array(tag.utf8)
            guard bytes.count >= pattern.count else { return nil }
            for index in 0...(bytes.count - pattern.count) where Array(bytes[index..<(index + pattern.count)]) == pattern {
                return index
            }
            return nil
        }

        if let index = find("dfLa"), index >= 4, let info = firstStreamInfo(blocksAt: index + 8) {
            return info
        }
        if let index = find("fLaC"), let info = firstStreamInfo(blocksAt: index + 4) {
            return info
        }
        if let info = firstStreamInfo(blocksAt: 0) {
            return info
        }
        return bytes.count == 34 ? cookie : nil
    }

    /// STREAMINFO fields (FLAC format §8.2).
    struct StreamInfoFields: Equatable {
        var minBlockSize: Int
        var maxBlockSize: Int
        var minFrameSize: Int
        var maxFrameSize: Int
        var sampleRate: Int
        var channels: Int
        var bitsPerSample: Int
        var totalSamples: UInt64
    }

    static func parseStreamInfo(_ info: Data) -> StreamInfoFields? {
        guard info.count == 34 else { return nil }
        let b = [UInt8](info)
        let packed = b[10..<18].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return StreamInfoFields(
            minBlockSize: Int(b[0]) << 8 | Int(b[1]),
            maxBlockSize: Int(b[2]) << 8 | Int(b[3]),
            minFrameSize: Int(b[4]) << 16 | Int(b[5]) << 8 | Int(b[6]),
            maxFrameSize: Int(b[7]) << 16 | Int(b[8]) << 8 | Int(b[9]),
            sampleRate: Int(packed >> 44),
            channels: Int((packed >> 41) & 0x7) + 1,
            bitsPerSample: Int((packed >> 36) & 0x1F) + 1,
            totalSamples: packed & 0xF_FFFF_FFFF)
    }

    private static func streamInfo(_ info: Data, matches format: PCMFormat, blockSize: Int) -> Bool {
        guard let fields = parseStreamInfo(info) else { return false }
        return fields.sampleRate == format.sampleRate
            && fields.channels == format.channels
            && fields.bitsPerSample == format.outputBits
            && fields.maxBlockSize == blockSize
            && fields.minBlockSize >= 16 && fields.minBlockSize <= fields.maxBlockSize
    }

    /// Streaming output: frame sizes, total samples and MD5 are unknown when
    /// the init segment is written → zero them ("unknown" in the FLAC spec).
    private static func sanitizedStreamInfo(_ info: Data) -> Data {
        var bytes = [UInt8](info)
        for index in 4..<10 { bytes[index] = 0 }  // min / max frame size
        bytes[13] &= 0xF0                         // keep bps, clear total-samples bits 35…32
        for index in 14..<34 { bytes[index] = 0 } // total samples bits 31…0 + MD5
        return Data(bytes)
    }

    /// Fallback STREAMINFO when the cookie can't be used: fixed block size,
    /// unknown frame sizes, total samples and MD5.
    static func makeStreamInfo(blockSize: Int, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        var w = BoxWriter()
        w.u16(UInt16(clamping: blockSize))
        w.u16(UInt16(clamping: blockSize))
        w.u24(0)
        w.u24(0)
        let packed = (UInt64(sampleRate & 0xFFFFF) << 44)
            | (UInt64((channels - 1) & 0x7) << 41)
            | (UInt64((bitsPerSample - 1) & 0x1F) << 36)
        w.u64(packed)
        w.zeros(16)
        return w.data
    }

    /// `samplerate` of the sample entry (16.16): the rate itself when it fits,
    /// else "the greatest expressible regular division of that rate", else
    /// 65535 (FLAC-in-ISOBMFF §3.3.1; also what Apple's own MP4 writer does:
    /// 96 / 192 kHz → 48000, 176.4 kHz → 44100). Decoders take the real rate
    /// from STREAMINFO (verified: AVFoundation decodes 96/176.4/192 kHz
    /// bit-exactly whatever this field holds).
    static func sampleEntryRate(_ sampleRate: Int) -> UInt32 {
        var rate = sampleRate
        while rate > 65535 && rate % 2 == 0 { rate /= 2 }
        return UInt32(min(rate, 65535)) << 16
    }

    /// `fLaC` AudioSampleEntry + `dfLa` (STREAMINFO, last-metadata-block set).
    static func sampleEntry(streamInfo: Data, channels: Int, bitsPerSample: Int, sampleRate: Int) -> Data {
        let dfLa = fullBox("dfLa", version: 0, flags: 0) { w in
            w.u8(0x80)                    // last-metadata-block = 1, type 0 = STREAMINFO
            w.u24(UInt32(streamInfo.count))
            w.bytes(streamInfo)
        }
        return box("fLaC") { w in
            w.zeros(6)                    // SampleEntry.reserved
            w.u16(1)                      // data_reference_index
            w.zeros(8)                    // AudioSampleEntry.reserved[2]
            w.u16(UInt16(channels))       // channelcount
            w.u16(UInt16(bitsPerSample))  // samplesize
            w.u16(0)                      // pre_defined
            w.u16(0)                      // reserved
            w.u32(sampleEntryRate(sampleRate))
            w.bytes(dfLa)
        }
    }

    private static func makePlan(format: PCMFormat, streamInfo: Data, framesPerPacket: UInt32) -> RemuxAudioPlan {
        let layoutNames = ["", "1.0", "2.0", "3.0", "4.0", "5.0", "5.1", "6.1", "7.1"]
        let layout = format.channels < layoutNames.count ? layoutNames[format.channels] : "\(format.channels) canaux"
        var description = "FLAC \(layout) \(format.outputBits) bits"
        if format.sampleRate > 48_000 {
            let kHz = Double(format.sampleRate) / 1000
            description += kHz == kHz.rounded() ? " \(Int(kHz)) kHz" : String(format: " %.1f kHz", kHz)
        }
        if format.kind == .floatLittleEndian {
            description += " (PCM flottant converti en 24 bits)"
        } else if format.isBitExact {
            description += " (PCM réencodé sans perte)"
        } else {
            description += " (PCM 32 bits réduit à 24 bits)"
        }
        let nominal = framesPerPacket
        return RemuxAudioPlan(
            codec: .flac,
            sampleEntry: sampleEntry(streamInfo: streamInfo, channels: format.channels,
                                     bitsPerSample: format.outputBits, sampleRate: format.sampleRate),
            codecsString: "fLaC",
            channelsAttribute: "\(format.channels)",
            channelCount: format.channels,
            timescale: UInt32(format.sampleRate),
            isAtmos: false,
            summary: description,
            frameDuration: { packet in
                RemuxAudioTranscoder.flacFrameBlockSize(packet).map { UInt32($0) } ?? nominal
            },
            nominalFrameDuration: nominal,
            transform: nil)
    }

    /// Block size (samples per channel) of a FLAC frame, from its header
    /// (FLAC format §9.1); nil when `frame` doesn't start with a valid header.
    static func flacFrameBlockSize(_ frame: Data) -> Int? {
        guard frame.count >= 6 else { return nil }
        return frame.withUnsafeBytes { raw -> Int? in
            let b = raw.bindMemory(to: UInt8.self)
            guard b[0] == 0xFF, b[1] & 0xFE == 0xF8 else { return nil }
            let blockCode = Int(b[2] >> 4)
            let rateCode = Int(b[2] & 0x0F)
            guard blockCode != 0, rateCode != 15, b[3] >> 4 <= 10, b[3] & 0x01 == 0 else { return nil }
            // UTF-8-like coded frame / sample number.
            let lead = b[4]
            var codedLength = 1
            if lead & 0x80 != 0 {
                var mask: UInt8 = 0x40
                codedLength = 1
                while lead & mask != 0 && codedLength < 7 {
                    codedLength += 1
                    mask >>= 1
                }
                guard codedLength >= 2 else { return nil } // 10xxxxxx is a continuation byte
            }
            let tail = 4 + codedLength
            switch blockCode {
            case 1: return 192
            case 2...5: return 576 << (blockCode - 2)
            case 6:
                guard tail < b.count else { return nil }
                return Int(b[tail]) + 1
            case 7:
                guard tail + 1 < b.count else { return nil }
                return (Int(b[tail]) << 8 | Int(b[tail + 1])) + 1
            default: return 256 << (blockCode - 8)
            }
        }
    }

    // MARK: - Verbatim FLAC frame (short streams)

    /// One complete FLAC frame (FLAC format §9) holding `frames` samples
    /// (1…65536) of `pcm` (packed little-endian 16/24-bit, interleaved) as
    /// independent VERBATIM subframes: fixed-blocksize header with an explicit
    /// block size, CRC-8, subframes, CRC-16.
    static func verbatimFrame(pcm: UnsafeRawBufferPointer, frames: Int, format: PCMFormat, frameNumber: UInt64) -> Data {
        precondition(frames >= 1 && frames <= 65536 && pcm.count >= frames * format.outputBytesPerFrame)
        let rate = flacSampleRateCode(format.sampleRate)
        var frame: [UInt8] = [0xFF, 0xF8]                         // sync + fixed-blocksize strategy
        frame.append((frames <= 256 ? 0x60 : 0x70) | rate.code)   // explicit 8/16-bit block size
        let sizeCode: UInt8 = format.outputBits == 24 ? 0x6 : 0x4
        frame.append(UInt8(format.channels - 1) << 4 | sizeCode << 1) // independent channels
        frame.append(contentsOf: utf8CodedNumber(frameNumber))
        if frames <= 256 {
            frame.append(UInt8(frames - 1))
        } else {
            frame.append(UInt8((frames - 1) >> 8))
            frame.append(UInt8((frames - 1) & 0xFF))
        }
        frame.append(contentsOf: rate.trailer)
        frame.append(crc8(frame[...]))
        let bytesPerSample = format.outputBytesPerSample
        frame.reserveCapacity(frame.count + format.channels * (1 + frames * bytesPerSample) + 2)
        let samples = pcm.bindMemory(to: UInt8.self)
        for channel in 0..<format.channels {
            frame.append(0x02) // zero bit, type 000001 = VERBATIM, no wasted bits
            for index in 0..<frames {
                let base = (index * format.channels + channel) * bytesPerSample
                for byte in stride(from: bytesPerSample - 1, through: 0, by: -1) {
                    frame.append(samples[base + byte]) // little → big endian
                }
            }
        }
        let crc = crc16(frame[...])
        frame.append(UInt8(crc >> 8))
        frame.append(UInt8(crc & 0xFF))
        return Data(frame)
    }

    /// Frame-header sample-rate code and the bytes it implies after the block size.
    static func flacSampleRateCode(_ rate: Int) -> (code: UInt8, trailer: [UInt8]) {
        let table: [Int: UInt8] = [88_200: 1, 176_400: 2, 192_000: 3, 8_000: 4, 16_000: 5, 22_050: 6,
                                   24_000: 7, 32_000: 8, 44_100: 9, 48_000: 10, 96_000: 11]
        if let code = table[rate] { return (code, []) }
        if rate % 1000 == 0 && rate / 1000 <= 255 { return (12, [UInt8(rate / 1000)]) }
        if rate <= 65535 { return (13, [UInt8(rate >> 8), UInt8(rate & 0xFF)]) }
        if rate % 10 == 0 && rate / 10 <= 65535 { return (14, [UInt8((rate / 10) >> 8), UInt8((rate / 10) & 0xFF)]) }
        return (0, []) // "from STREAMINFO"
    }

    /// FLAC's UTF-8-style coded frame number (1…7 bytes, up to 36 bits).
    static func utf8CodedNumber(_ value: UInt64) -> [UInt8] {
        if value < 0x80 { return [UInt8(value)] }
        var length = 2
        while length < 7 && value >= (UInt64(1) << UInt64(5 * length + 1)) { length += 1 }
        var bytes = [UInt8](repeating: 0, count: length)
        var rest = value
        for index in stride(from: length - 1, through: 1, by: -1) {
            bytes[index] = 0x80 | UInt8(rest & 0x3F)
            rest >>= 6
        }
        bytes[0] = UInt8(truncatingIfNeeded: 0xFF00 >> length) | UInt8(truncatingIfNeeded: rest)
        return bytes
    }

    /// CRC-8, polynomial x⁸+x²+x+1 (0x07), init 0 — FLAC frame header.
    static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    /// CRC-16, polynomial x¹⁶+x¹⁵+x²+1 (0x8005), init 0 — FLAC frame footer.
    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        }
        return crc
    }
}
