

import Foundation

/// Remuxes a Matroska file (HEVC/H.264 video + E-AC-3/AC-3 audio) into
/// fragmented-MP4 HLS segments that AVPlayer can play natively — giving true
/// Dolby Atmos (E-AC-3 JOC) and HDR on Apple hardware, bypassing VLC's audio
/// pipeline entirely. Pure repackaging: codec bitstreams are copied, never
/// re-encoded.
///
/// Scope (deliberate MVP):
///  - Video: V_MPEGH/ISO/HEVC (hvcC CodecPrivate) or V_MPEG4/ISO/AVC (avcC).
///    MKV block payloads for these are already length-prefixed NAL units —
///    byte-identical to MP4 sample data.
///  - Audio: A_EAC3 / A_AC3 (raw syncframes; dec3/dac3 built from the first
///    frame header).
///  - Output: init.mp4 + rolling .m4s segments + an HLS playlist.
///  - No seeking in the MVP (playlist is EVENT; ENDLIST on completion).

// MARK: - Bit reader (for (E-)AC-3 header parsing)

struct BitReader {
    private let data: [UInt8]
    private var bitPos = 0
    init(_ data: [UInt8]) { self.data = data }
    mutating func read(_ count: Int) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = bitPos >> 3
            guard byte < data.count else { return value << 1 }
            let bit = (data[byte] >> (7 - UInt8(bitPos & 7))) & 1
            value = (value << 1) | UInt32(bit)
            bitPos += 1
        }
        return value
    }
}

// MARK: - EBML primitives

/// Minimal EBML reader over a random-access file. Reads are chunked so a
/// still-downloading file can be parsed as far as data exists.
final class EBMLReader {
    private let handle: FileHandle
    private(set) var offset: UInt64
    let fileLength: () -> UInt64

    init(handle: FileHandle, offset: UInt64 = 0, fileLength: @escaping () -> UInt64) {
        self.handle = handle
        self.offset = offset
        self.fileLength = fileLength
    }

    var available: UInt64 { let len = fileLength(); return len > offset ? len - offset : 0 }

    func seek(to newOffset: UInt64) { offset = newOffset }

    func readBytes(_ count: Int) -> Data? {
        guard count >= 0, available >= UInt64(count) else { return nil }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        offset += UInt64(count)
        return data
    }

    func peekByte() -> UInt8? {
        guard available >= 1 else { return nil }
        try? handle.seek(toOffset: offset)
        return (try? handle.read(upToCount: 1))?.first
    }

    /// EBML element ID: length from leading zeros, marker bit KEPT.
    func readElementID() -> UInt32? {
        guard let first = peekByte() else { return nil }
        let length = Self.vintLength(first)
        guard length >= 1, length <= 4, let bytes = readBytes(length) else { return nil }
        var id: UInt32 = 0
        for b in bytes { id = (id << 8) | UInt32(b) }
        return id
    }

    /// EBML data size: marker bit STRIPPED. Returns nil at EOF; `unknown`
    /// (all value bits set) is reported as UInt64.max.
    func readElementSize() -> UInt64? {
        guard let first = peekByte() else { return nil }
        let length = Self.vintLength(first)
        guard length >= 1, length <= 8, let bytes = readBytes(length) else { return nil }
        var value = UInt64(bytes[0] & (0xFF >> UInt8(length)))
        for b in bytes.dropFirst() { value = (value << 8) | UInt64(b) }
        // All-ones payload = "unknown size" (streamed element).
        let allOnes = (UInt64(1) << (7 * length)) - 1
        return value == allOnes ? UInt64.max : value
    }

    static func vintLength(_ firstByte: UInt8) -> Int {
        guard firstByte != 0 else { return 0 }
        return firstByte.leadingZeroBitCount + 1
    }

    static func uint(_ data: Data) -> UInt64 {
        var v: UInt64 = 0
        for b in data { v = (v << 8) | UInt64(b) }
        return v
    }

    static func float(_ data: Data) -> Double {
        if data.count == 4 { return Double(Float(bitPattern: UInt32(uint(data)))) }
        if data.count == 8 { return Double(bitPattern: uint(data)) }
        return 0
    }
}

// MARK: - Matroska model

struct MKVTrack {
    enum Kind { case video, audio, other }
    var number: UInt64 = 0
    var kind: Kind = .other
    var codecID: String = ""
    var codecPrivate: Data = Data()
    var defaultDurationNs: UInt64 = 0
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var samplingFrequency: Double = 0
    var channels: Int = 0
}

struct MKVFrame {
    let trackNumber: UInt64
    /// Absolute timestamp in TimestampScale units (usually milliseconds).
    let timestamp: Int64
    let keyframe: Bool
    let data: Data
}

// MARK: - Matroska demuxer

final class MatroskaDemuxer {
    // Element IDs
    private enum ID {
        static let ebml: UInt32 = 0x1A45DFA3
        static let segment: UInt32 = 0x18538067
        static let info: UInt32 = 0x1549A966
        static let timestampScale: UInt32 = 0x2AD7B1
        static let tracks: UInt32 = 0x1654AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let defaultDuration: UInt32 = 0x23E383
        static let videoSettings: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let audioSettings: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let channels: UInt32 = 0x9F
        static let cluster: UInt32 = 0x1F43B675
        static let clusterTimestamp: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let referenceBlock: UInt32 = 0xFB
    }

    let reader: EBMLReader
    private(set) var timestampScale: UInt64 = 1_000_000 // ns per tick → 1ms default
    private(set) var tracks: [MKVTrack] = []
    private var segmentDataStart: UInt64 = 0

    init(reader: EBMLReader) { self.reader = reader }

    /// Parses up to and including the Tracks element. Returns false if the
    /// header isn't fully available yet (caller can retry once more of the
    /// file has downloaded).
    func parseHeaders() -> Bool {
        reader.seek(to: 0)
        guard let ebmlID = reader.readElementID(), ebmlID == ID.ebml,
              let ebmlSize = reader.readElementSize(), ebmlSize != UInt64.max else { return false }
        reader.seek(to: reader.offset + ebmlSize)

        guard let segID = reader.readElementID(), segID == ID.segment,
              reader.readElementSize() != nil else { return false }
        segmentDataStart = reader.offset

        // Walk Segment children until Tracks parsed (Cluster means we've gone
        // past the header zone — with Tracks already found we're done).
        while true {
            let elementStart = reader.offset
            guard let id = reader.readElementID(), let size = reader.readElementSize() else { return false }
            switch id {
            case ID.info:
                guard size != UInt64.max, let body = reader.readBytes(Int(size)) else { return false }
                parseInfo(body)
            case ID.tracks:
                guard size != UInt64.max, let body = reader.readBytes(Int(size)) else { return false }
                parseTracks(body)
                return !tracks.isEmpty
            case ID.cluster:
                reader.seek(to: elementStart)
                return !tracks.isEmpty
            default:
                guard size != UInt64.max else { return false }
                reader.seek(to: reader.offset + size)
            }
        }
    }

    private func parseInfo(_ body: Data) {
        iterate(body) { id, payload in
            if id == ID.timestampScale { timestampScale = EBMLReader.uint(payload) }
        }
    }

    private func parseTracks(_ body: Data) {
        iterate(body) { id, payload in
            guard id == ID.trackEntry else { return }
            var track = MKVTrack()
            iterate(payload) { fieldID, fieldData in
                switch fieldID {
                case ID.trackNumber: track.number = EBMLReader.uint(fieldData)
                case ID.trackType:
                    let type = EBMLReader.uint(fieldData)
                    track.kind = type == 1 ? .video : (type == 2 ? .audio : .other)
                case ID.codecID: track.codecID = String(data: fieldData, encoding: .utf8) ?? ""
                case ID.codecPrivate: track.codecPrivate = fieldData
                case ID.defaultDuration: track.defaultDurationNs = EBMLReader.uint(fieldData)
                case ID.videoSettings:
                    iterate(fieldData) { vID, vData in
                        if vID == ID.pixelWidth { track.pixelWidth = Int(EBMLReader.uint(vData)) }
                        if vID == ID.pixelHeight { track.pixelHeight = Int(EBMLReader.uint(vData)) }
                    }
                case ID.audioSettings:
                    iterate(fieldData) { aID, aData in
                        if aID == ID.samplingFrequency { track.samplingFrequency = EBMLReader.float(aData) }
                        if aID == ID.channels { track.channels = Int(EBMLReader.uint(aData)) }
                    }
                default: break
                }
            }
            tracks.append(track)
        }
    }

    /// In-memory EBML child iteration.
    private func iterate(_ data: Data, _ visit: (UInt32, Data) -> Void) {
        let bytes = [UInt8](data)
        var pos = 0
        while pos < bytes.count {
            let idLen = EBMLReader.vintLength(bytes[pos])
            guard idLen >= 1, idLen <= 4, pos + idLen <= bytes.count else { return }
            var id: UInt32 = 0
            for i in 0..<idLen { id = (id << 8) | UInt32(bytes[pos + i]) }
            pos += idLen
            guard pos < bytes.count else { return }
            let sizeLen = EBMLReader.vintLength(bytes[pos])
            guard sizeLen >= 1, sizeLen <= 8, pos + sizeLen <= bytes.count else { return }
            var size = UInt64(bytes[pos] & (0xFF >> UInt8(sizeLen)))
            for i in 1..<sizeLen { size = (size << 8) | UInt64(bytes[pos + i]) }
            pos += sizeLen
            guard pos + Int(size) <= bytes.count else { return }
            visit(id, data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + Int(size))))
            pos += Int(size)
        }
    }

    static func containsLongZeroRun(_ data: Data, threshold: Int = 64 * 1024) -> Bool {
        var run = 0
        var found = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                if byte == 0 {
                    run += 1
                    if run >= threshold { found = true; break }
                } else {
                    run = 0
                }
            }
        }
        return found
    }

    /// Reads the next complete cluster's frames. Returns nil when no full
    /// cluster is available yet (EOF or still downloading).
    func readNextCluster() -> [MKVFrame]? {
        while true {
            let elementStart = reader.offset
            guard let id = reader.readElementID(), let size = reader.readElementSize() else { return nil }
            guard size != UInt64.max else { return nil } // streamed cluster: unsupported in MVP
            if id != ID.cluster {
                reader.seek(to: reader.offset + size)
                continue
            }
            guard let body = reader.readBytes(Int(size)) else {
                reader.seek(to: elementStart) // incomplete — retry later
                return nil
            }
            // Torrent payloads are PREALLOCATED at full file size: regions not
            // yet downloaded read as zeros. A >=64 KiB zero run can't occur
            // inside a real cluster (compressed AV data), so treat it as
            // not-downloaded-yet: rewind and retry on a later pump.
            if Self.containsLongZeroRun(body) {
                reader.seek(to: elementStart)
                return nil
            }
            var clusterTime: Int64 = 0
            var frames: [MKVFrame] = []
            iterate(body) { childID, payload in
                switch childID {
                case ID.clusterTimestamp:
                    clusterTime = Int64(EBMLReader.uint(payload))
                case ID.simpleBlock:
                    frames.append(contentsOf: parseBlock(payload, clusterTime: clusterTime, isSimple: true, hasReference: false))
                case ID.blockGroup:
                    var blockData: Data?
                    var hasReference = false
                    iterate(payload) { gID, gData in
                        if gID == ID.block { blockData = gData }
                        if gID == ID.referenceBlock { hasReference = true }
                    }
                    if let blockData = blockData {
                        frames.append(contentsOf: parseBlock(blockData, clusterTime: clusterTime, isSimple: false, hasReference: hasReference))
                    }
                default: break
                }
            }
            return frames
        }
    }

    /// Block layout: track vint, s16 relative timestamp, flags byte, optional
    /// lacing table, then frame data. Handles no/Xiph/fixed/EBML lacing.
    private func parseBlock(_ data: Data, clusterTime: Int64, isSimple: Bool, hasReference: Bool) -> [MKVFrame] {
        let bytes = [UInt8](data)
        var pos = 0
        guard !bytes.isEmpty else { return [] }
        let trackLen = EBMLReader.vintLength(bytes[0])
        guard trackLen >= 1, bytes.count > trackLen + 3 else { return [] }
        var track = UInt64(bytes[0] & (0xFF >> UInt8(trackLen)))
        for i in 1..<trackLen { track = (track << 8) | UInt64(bytes[i]) }
        pos = trackLen
        let relative = Int16(bitPattern: (UInt16(bytes[pos]) << 8) | UInt16(bytes[pos + 1]))
        pos += 2
        let flags = bytes[pos]; pos += 1
        let keyframe = isSimple ? (flags & 0x80) != 0 : !hasReference
        let lacing = (flags >> 1) & 0x3
        let timestamp = clusterTime + Int64(relative)

        var sizes: [Int] = []
        switch lacing {
        case 0:
            sizes = [bytes.count - pos]
        case 2: // fixed
            guard pos < bytes.count else { return [] }
            let count = Int(bytes[pos]) + 1; pos += 1
            let each = (bytes.count - pos) / count
            sizes = Array(repeating: each, count: count)
        case 1: // Xiph
            guard pos < bytes.count else { return [] }
            let count = Int(bytes[pos]) + 1; pos += 1
            var total = 0
            for _ in 0..<(count - 1) {
                var size = 0
                while pos < bytes.count { let b = Int(bytes[pos]); pos += 1; size += b; if b != 255 { break } }
                sizes.append(size); total += size
            }
            sizes.append(bytes.count - pos - total)
        case 3: // EBML
            guard pos < bytes.count else { return [] }
            let count = Int(bytes[pos]) + 1; pos += 1
            var total = 0
            var previous = 0
            for i in 0..<(count - 1) {
                guard pos < bytes.count else { return [] }
                let len = EBMLReader.vintLength(bytes[pos])
                guard len >= 1, pos + len <= bytes.count else { return [] }
                var raw = UInt64(bytes[pos] & (0xFF >> UInt8(len)))
                for j in 1..<len { raw = (raw << 8) | UInt64(bytes[pos + j]) }
                pos += len
                if i == 0 {
                    previous = Int(raw)
                } else {
                    // Signed delta: raw - (2^(7*len-1) - 1)
                    let bias = (1 << (7 * len - 1)) - 1
                    previous += Int(raw) - bias
                }
                sizes.append(previous); total += previous
            }
            sizes.append(bytes.count - pos - total)
        default:
            return []
        }

        var frames: [MKVFrame] = []
        var cursor = pos
        for (index, size) in sizes.enumerated() {
            guard size >= 0, cursor + size <= bytes.count else { break }
            let payload = data.subdata(in: (data.startIndex + cursor)..<(data.startIndex + cursor + size))
            // Laced frames share the block timestamp; the muxer spaces audio
            // frames by their fixed frame duration anyway.
            frames.append(MKVFrame(trackNumber: track, timestamp: timestamp, keyframe: keyframe || index > 0 && frames.first?.keyframe == true, data: payload))
            cursor += size
        }
        return frames
    }
}

// MARK: - MP4 box building

struct BoxWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func u24(_ v: UInt32) { data.append(contentsOf: [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    mutating func u32(_ v: UInt32) { data.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFFFFFF)) }
    mutating func fourCC(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func zeros(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: n)) }
}

func box(_ type: String, _ build: (inout BoxWriter) -> Void) -> Data {
    var w = BoxWriter()
    build(&w)
    var out = BoxWriter()
    out.u32(UInt32(w.data.count + 8))
    out.fourCC(type)
    out.bytes(w.data)
    return out.data
}

func fullBox(_ type: String, version: UInt8, flags: UInt32, _ build: (inout BoxWriter) -> Void) -> Data {
    return box(type) { w in
        w.u8(version)
        w.u24(flags)
        build(&w)
    }
}

// MARK: - fMP4 muxer

final class FMP4Muxer {

    struct TrackConfig {
        let trackID: UInt32
        let timescale: UInt32
        let isVideo: Bool
        let width: Int
        let height: Int
        let channels: Int
        let sampleRate: Double
        let codecID: String
        let codecPrivate: Data
        /// First audio frame, used to synthesize dec3/dac3.
        var firstAudioFrame: Data = Data()
    }

    struct Sample {
        let data: Data
        let duration: UInt32   // in track timescale
        let sync: Bool
        /// PTS − DTS in track timescale (B-frame reorder). trun v1, signed.
        var compositionOffset: Int32 = 0
    }

    /// ftyp + moov for the given tracks.
    static func initSegment(tracks: [TrackConfig]) -> Data {
        var out = Data()
        out.append(box("ftyp") { w in
            w.fourCC("iso6"); w.u32(1)
            w.fourCC("iso6"); w.fourCC("cmfc"); w.fourCC("mp41")
        })
        out.append(box("moov") { moov in
            moov.bytes(fullBox("mvhd", version: 0, flags: 0) { w in
                w.u32(0); w.u32(0)          // times
                w.u32(1000)                  // timescale
                w.u32(0)                     // duration (fragmented)
                w.u32(0x00010000); w.u16(0x0100); w.u16(0) // rate, volume
                w.zeros(8)
                for v in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000] { w.u32(UInt32(v)) }
                w.zeros(24)
                w.u32(UInt32(tracks.count + 1)) // next track id
            })
            for track in tracks {
                moov.bytes(trak(track))
            }
            moov.bytes(box("mvex") { mvex in
                for track in tracks {
                    mvex.bytes(fullBox("trex", version: 0, flags: 0) { w in
                        w.u32(track.trackID)
                        w.u32(1) // default sample description
                        w.u32(0); w.u32(0); w.u32(0)
                    })
                }
            })
        })
        return out
    }

    private static func trak(_ track: TrackConfig) -> Data {
        return box("trak") { trak in
            trak.bytes(fullBox("tkhd", version: 0, flags: 3) { w in
                w.u32(0); w.u32(0)
                w.u32(track.trackID)
                w.u32(0); w.u32(0)
                w.zeros(8)
                w.u16(0); w.u16(0)
                w.u16(track.isVideo ? 0 : 0x0100); w.u16(0)
                for v in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000] { w.u32(UInt32(v)) }
                w.u32(UInt32(track.width) << 16)
                w.u32(UInt32(track.height) << 16)
            })
            trak.bytes(box("mdia") { mdia in
                mdia.bytes(fullBox("mdhd", version: 0, flags: 0) { w in
                    w.u32(0); w.u32(0)
                    w.u32(track.timescale)
                    w.u32(0)
                    w.u16(0x55C4); w.u16(0) // und
                })
                mdia.bytes(fullBox("hdlr", version: 0, flags: 0) { w in
                    w.u32(0)
                    w.fourCC(track.isVideo ? "vide" : "soun")
                    w.zeros(12)
                    w.bytes(Data((track.isVideo ? "Video\0" : "Audio\0").utf8))
                })
                mdia.bytes(box("minf") { minf in
                    if track.isVideo {
                        minf.bytes(fullBox("vmhd", version: 0, flags: 1) { w in w.zeros(8) })
                    } else {
                        minf.bytes(fullBox("smhd", version: 0, flags: 0) { w in w.u32(0) })
                    }
                    minf.bytes(box("dinf") { dinf in
                        dinf.bytes(fullBox("dref", version: 0, flags: 0) { w in
                            w.u32(1)
                            w.bytes(fullBox("url ", version: 0, flags: 1) { _ in })
                        })
                    })
                    minf.bytes(box("stbl") { stbl in
                        stbl.bytes(fullBox("stsd", version: 0, flags: 0) { w in
                            w.u32(1)
                            w.bytes(sampleEntry(track))
                        })
                        stbl.bytes(fullBox("stts", version: 0, flags: 0) { w in w.u32(0) })
                        stbl.bytes(fullBox("stsc", version: 0, flags: 0) { w in w.u32(0) })
                        stbl.bytes(fullBox("stsz", version: 0, flags: 0) { w in w.u32(0); w.u32(0) })
                        stbl.bytes(fullBox("stco", version: 0, flags: 0) { w in w.u32(0) })
                    })
                })
            })
        }
    }

    private static func sampleEntry(_ track: TrackConfig) -> Data {
        if track.isVideo {
            let isHEVC = track.codecID.contains("HEVC")
            return box(isHEVC ? "hvc1" : "avc1") { w in
                w.zeros(6); w.u16(1) // reserved + data-reference-index
                w.zeros(16)
                w.u16(UInt16(track.width)); w.u16(UInt16(track.height))
                w.u32(0x00480000); w.u32(0x00480000) // 72 dpi
                w.u32(0)
                w.u16(1)              // frame count
                w.zeros(32)           // compressor name
                w.u16(0x0018)         // depth
                w.u16(0xFFFF)         // pre-defined
                // hvcC / avcC straight from Matroska CodecPrivate.
                w.bytes(box(isHEVC ? "hvcC" : "avcC") { c in c.bytes(track.codecPrivate) })
            }
        }
        let isEAC3 = track.codecID.contains("EAC3") || track.codecID.contains("E-AC-3")
        return box(isEAC3 ? "ec-3" : "ac-3") { w in
            w.zeros(6); w.u16(1)
            w.zeros(8)
            w.u16(UInt16(track.channels)); w.u16(16)
            w.u32(0)
            w.u32(UInt32(track.sampleRate) << 16)
            if isEAC3 {
                w.bytes(box("dec3") { c in c.bytes(dec3Payload(firstFrame: track.firstAudioFrame, sampleRate: track.sampleRate)) })
            } else {
                w.bytes(box("dac3") { c in c.bytes(dac3Payload(firstFrame: track.firstAudioFrame)) })
            }
        }
    }

    /// EC3SpecificBox (ETSI TS 102 366 F.6) synthesized from the first
    /// E-AC-3 syncframe's BSI fields.
    static func dec3Payload(firstFrame: Data, sampleRate: Double) -> Data {
        let bytes = [UInt8](firstFrame)
        var fscod: UInt32 = 0, bsid: UInt32 = 16, bsmod: UInt32 = 0
        var acmod: UInt32 = 7, lfeon: UInt32 = 1
        var frmsiz: UInt32 = 0
        var numblkscod: UInt32 = 3
        if bytes.count > 6, bytes[0] == 0x0B, bytes[1] == 0x77 {
            var reader = BitReader(Array(bytes[2...]))
            _ = reader.read(2)            // strmtyp
            _ = reader.read(3)            // substreamid
            frmsiz = reader.read(11)
            fscod = reader.read(2)
            if fscod == 3 {
                _ = reader.read(2)        // fscod2 (halved rates)
                numblkscod = 3
            } else {
                numblkscod = reader.read(2)
            }
            acmod = reader.read(3)
            lfeon = reader.read(1)
            bsid = reader.read(5)
        }
        let blocksPerFrame: [UInt32] = [1, 2, 3, 6]
        let samples = 256 * blocksPerFrame[Int(numblkscod)]
        let frameBytes = (frmsiz + 1) * 2
        let dataRate = sampleRate > 0 ? UInt32((Double(frameBytes) * 8 * (sampleRate / Double(samples))) / 1000) : 0

        var w = BoxWriter()
        // data_rate(13) num_ind_sub-1(3)
        w.u16(UInt16((min(dataRate, 0x1FFF) << 3) | 0))
        // fscod(2) bsid(5) reserved(1) asvc(1) bsmod(3) acmod(3) lfeon(1) reserved(3) num_dep_sub(4)
        var bits: UInt32 = 0
        bits |= (fscod & 0x3) << 22
        bits |= (bsid & 0x1F) << 17
        bits |= (0) << 16          // reserved
        bits |= (0) << 15          // asvc
        bits |= (bsmod & 0x7) << 12
        bits |= (acmod & 0x7) << 9
        bits |= (lfeon & 0x1) << 8
        bits |= (0) << 5           // reserved(3)
        bits |= (0) << 1           // num_dep_sub(4)
        bits |= 0                  // reserved(1)
        w.u24(bits)
        return w.data
    }

    /// AC3SpecificBox for plain AC-3.
    static func dac3Payload(firstFrame: Data) -> Data {
        let bytes = [UInt8](firstFrame)
        var fscod: UInt32 = 0, bsid: UInt32 = 8, bsmod: UInt32 = 0, acmod: UInt32 = 7, lfeon: UInt32 = 1, frmsizecod: UInt32 = 0
        if bytes.count > 6, bytes[0] == 0x0B, bytes[1] == 0x77 {
            var reader = BitReader(Array(bytes[4...])) // skip syncword+crc
            fscod = reader.read(2)
            frmsizecod = reader.read(6)
            bsid = reader.read(5)
            bsmod = reader.read(3)
            acmod = reader.read(3)
            // (dsurmod/cmixlev bits skipped for brevity)
            lfeon = 1
        }
        var w = BoxWriter()
        var bits: UInt32 = 0
        bits |= (fscod & 0x3) << 22
        bits |= (bsid & 0x1F) << 17
        bits |= (bsmod & 0x7) << 14
        bits |= (acmod & 0x7) << 11
        bits |= (lfeon & 0x1) << 10
        bits |= ((frmsizecod >> 1) & 0x1F) << 5
        w.u24(bits)
        return w.data
    }

    /// One moof+mdat for a set of per-track samples.
    static func mediaSegment(sequence: UInt32,
                             trackSamples: [(config: TrackConfig, baseDecodeTime: UInt64, samples: [Sample])]) -> Data {
        // moof size depends on itself (data offsets) → build with placeholder
        // offsets first, then rebuild with the now-known moof size.
        func buildMoof(dataOffsets: [UInt32]) -> Data {
            return box("moof") { moof in
                moof.bytes(fullBox("mfhd", version: 0, flags: 0) { w in w.u32(sequence) })
                for (index, entry) in trackSamples.enumerated() {
                    moof.bytes(box("traf") { traf in
                        traf.bytes(fullBox("tfhd", version: 0, flags: 0x020000) { w in // default-base-is-moof
                            w.u32(entry.config.trackID)
                        })
                        traf.bytes(fullBox("tfdt", version: 1, flags: 0) { w in
                            w.u64(entry.baseDecodeTime)
                        })
                        // trun v1: data-offset | duration | size | flags |
                        // signed composition offsets (B-frame reorder).
                        traf.bytes(fullBox("trun", version: 1, flags: 0x000F01) { w in
                            w.u32(UInt32(entry.samples.count))
                            w.u32(dataOffsets[index])
                            for sample in entry.samples {
                                w.u32(sample.duration)
                                w.u32(UInt32(sample.data.count))
                                w.u32(sample.sync ? 0x02000000 : 0x01010000)
                                w.u32(UInt32(bitPattern: sample.compositionOffset))
                            }
                        })
                    })
                }
            }
        }
        let placeholder = buildMoof(dataOffsets: Array(repeating: 0, count: trackSamples.count))
        let moofSize = placeholder.count
        var offsets: [UInt32] = []
        var running = UInt32(moofSize + 8) // past mdat header
        for entry in trackSamples {
            offsets.append(running)
            running += entry.samples.reduce(0) { $0 + UInt32($1.data.count) }
        }
        let moof = buildMoof(dataOffsets: offsets)

        var mdat = BoxWriter()
        var payloadSize = 0
        for entry in trackSamples { for sample in entry.samples { payloadSize += sample.data.count } }
        mdat.u32(UInt32(payloadSize + 8))
        mdat.fourCC("mdat")
        for entry in trackSamples { for sample in entry.samples { mdat.bytes(sample.data) } }

        return moof + mdat.data
    }
}

// MARK: - Remux session (drives demux → segments → HLS playlist)

final class MKVToHLSRemuxSession {

    struct Progress {
        var segmentsWritten: Int = 0
        var mediaSeconds: Double = 0
        var finished: Bool = false
    }

    let outputDirectory: URL
    private let demuxer: MatroskaDemuxer
    private var videoTrack: MKVTrack?
    private var audioTrack: MKVTrack?
    private var videoConfig: FMP4Muxer.TrackConfig?
    private var audioConfig: FMP4Muxer.TrackConfig?
    private let targetSegmentSeconds: Double

    private var pendingVideo: [MKVFrame] = []
    private var pendingAudio: [MKVFrame] = []
    private var sequence: UInt32 = 0
    private var videoDecodeTime: UInt64 = 0
    private var audioDecodeTime: UInt64 = 0
    private var playlistSegments: [(duration: Double, name: String)] = []
    private(set) var progress = Progress()

    init(inputFile: URL, outputDirectory: URL, targetSegmentSeconds: Double = 6) throws {
        self.outputDirectory = outputDirectory
        self.targetSegmentSeconds = targetSegmentSeconds
        let handle = try FileHandle(forReadingFrom: inputFile)
        let path = inputFile.path
        let reader = EBMLReader(handle: handle) {
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        }
        self.demuxer = MatroskaDemuxer(reader: reader)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    var playlistURL: URL { outputDirectory.appendingPathComponent("stream.m3u8") }

    /// Parse headers and write init.mp4. Call once; returns false while the
    /// file hasn't downloaded enough header bytes yet.
    func prepare() -> Bool {
        guard demuxer.parseHeaders() else { return false }
        videoTrack = demuxer.tracks.first(where: { $0.kind == .video && ($0.codecID.contains("HEVC") || $0.codecID.contains("AVC")) })
        audioTrack = demuxer.tracks.first(where: { $0.kind == .audio && ($0.codecID.contains("AC3") || $0.codecID.contains("EAC3")) })
        guard let video = videoTrack, let audio = audioTrack else { return false }

        videoConfig = FMP4Muxer.TrackConfig(trackID: 1, timescale: 90000, isVideo: true,
                                            width: video.pixelWidth, height: video.pixelHeight,
                                            channels: 0, sampleRate: 0,
                                            codecID: video.codecID, codecPrivate: video.codecPrivate)
        audioConfig = FMP4Muxer.TrackConfig(trackID: 2, timescale: UInt32(audio.samplingFrequency), isVideo: false,
                                            width: 0, height: 0,
                                            channels: audio.channels, sampleRate: audio.samplingFrequency,
                                            codecID: audio.codecID, codecPrivate: audio.codecPrivate)
        return true
    }

    /// Pump: read available clusters, cut segments at keyframes near the
    /// target duration. Returns the number of NEW segments written.
    @discardableResult
    func pump(maxNewSegments: Int = Int.max) -> Int {
        var newSegments = 0
        while newSegments < maxNewSegments, let frames = demuxer.readNextCluster() {
            for frame in frames {
                if frame.trackNumber == videoTrack?.number { pendingVideo.append(frame) }
                else if frame.trackNumber == audioTrack?.number {
                    if audioConfig?.firstAudioFrame.isEmpty == true { audioConfig?.firstAudioFrame = frame.data }
                    pendingAudio.append(frame)
                }
            }
            newSegments += cutSegmentsIfReady()
        }
        return newSegments
    }

    /// Flush trailing samples and finalize the playlist.
    func finish() {
        writeSegment(upTo: pendingVideo.count)
        writePlaylist(ended: true)
        progress.finished = true
    }

    /// Write init.mp4 once the first audio frame is known (dec3 needs it).
    private var wroteInit = false
    private func writeInitIfNeeded() {
        guard !wroteInit, let video = videoConfig, let audio = audioConfig, !audio.firstAudioFrame.isEmpty else { return }
        let data = FMP4Muxer.initSegment(tracks: [video, audio])
        try? data.write(to: outputDirectory.appendingPathComponent("init.mp4"))
        wroteInit = true
    }

    private func cutSegmentsIfReady() -> Int {
        writeInitIfNeeded()
        guard wroteInit else { return 0 }
        var written = 0
        // Find a keyframe that closes >= target seconds of video.
        while true {
            guard let firstTs = pendingVideo.first?.timestamp else { break }
            var cutIndex: Int? = nil
            for (index, frame) in pendingVideo.enumerated() where index > 0 && frame.keyframe {
                if Double(frame.timestamp - firstTs) / 1000.0 >= targetSegmentSeconds {
                    cutIndex = index
                    break
                }
            }
            guard let cut = cutIndex else { break }
            writeSegment(upTo: cut)
            written += 1
        }
        return written
    }

    private func writeSegment(upTo videoCount: Int) {
        guard wroteInit, videoCount > 0, videoCount <= pendingVideo.count else { return }
        let videoFrames = Array(pendingVideo[0..<videoCount])
        pendingVideo.removeFirst(videoCount)
        // Audio: everything up to the end timestamp of the video slice.
        let endTs = pendingVideo.first?.timestamp ?? Int64.max
        let audioCut = pendingAudio.firstIndex(where: { $0.timestamp >= endTs }) ?? pendingAudio.count
        let audioFrames = Array(pendingAudio[0..<audioCut])
        pendingAudio.removeFirst(audioCut)

        guard let videoCfg = videoConfig, let audioCfg = audioConfig else { return }

        // Video: MKV block timestamps are PTS (presentation order) while the
        // frames are stored in DECODE order — with B-frames, PTS deltas are
        // not durations. Use a fixed decode-order duration (DefaultDuration,
        // else smallest positive PTS delta) and carry the reorder as signed
        // composition offsets (PTS − DTS) per sample.
        let duration90k: UInt32 = {
            if let ns = videoTrack?.defaultDurationNs, ns > 0 {
                return UInt32(UInt64(ns) * 9 / 100_000)
            }
            let sorted = videoFrames.map { $0.timestamp }.sorted()
            let deltas = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.filter { $0 > 0 }
            return UInt32((deltas.min() ?? 42) * 90)
        }()
        var videoSamples: [FMP4Muxer.Sample] = []
        for (index, frame) in videoFrames.enumerated() {
            let dts = Int64(videoDecodeTime) + Int64(index) * Int64(duration90k)
            let pts = frame.timestamp * 90
            videoSamples.append(.init(data: frame.data, duration: duration90k,
                                      sync: frame.keyframe,
                                      compositionOffset: Int32(clamping: pts - dts)))
        }
        // Audio samples: fixed frame duration from the syncframe (1536 typical).
        let audioFrameDuration = Self.eac3SamplesPerFrame(audioCfg.firstAudioFrame)
        let audioSamples = audioFrames.map { FMP4Muxer.Sample(data: $0.data, duration: audioFrameDuration, sync: true) }

        let segment = FMP4Muxer.mediaSegment(sequence: sequence + 1, trackSamples: [
            (videoCfg, videoDecodeTime, videoSamples),
            (audioCfg, audioDecodeTime, audioSamples),
        ])
        let name = "seg\(sequence).m4s"
        try? segment.write(to: outputDirectory.appendingPathComponent(name))

        let segmentSeconds = Double(videoSamples.reduce(0) { $0 + $1.duration }) / 90000.0
        videoDecodeTime += UInt64(videoSamples.reduce(0) { $0 + $1.duration })
        audioDecodeTime += UInt64(audioSamples.reduce(0) { $0 + $1.duration })
        playlistSegments.append((segmentSeconds, name))
        sequence += 1
        progress.segmentsWritten = Int(sequence)
        progress.mediaSeconds += segmentSeconds
        writePlaylist(ended: false)
    }

    static func eac3SamplesPerFrame(_ firstFrame: Data) -> UInt32 {
        let bytes = [UInt8](firstFrame)
        guard bytes.count > 6, bytes[0] == 0x0B, bytes[1] == 0x77 else { return 1536 }
        var reader = BitReader(Array(bytes[2...]))
        _ = reader.read(2); _ = reader.read(3); _ = reader.read(11)
        let fscod = reader.read(2)
        if fscod == 3 { return 1536 }
        let numblkscod = reader.read(2)
        let blocks: [UInt32] = [1, 2, 3, 6]
        return 256 * blocks[Int(numblkscod)]
    }

    private func writePlaylist(ended: Bool) {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int(targetSegmentSeconds.rounded(.up)) + 1)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:\(ended ? "VOD" : "EVENT")",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for segment in playlistSegments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append(segment.name)
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        try? lines.joined(separator: "\n").appending("\n")
            .write(to: playlistURL, atomically: true, encoding: .utf8)
    }
}
