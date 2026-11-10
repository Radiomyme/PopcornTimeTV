

import Foundation

// MARK: - MP4 box building

struct BoxWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func u24(_ v: UInt32) { data.append(contentsOf: [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    mutating func u32(_ v: UInt32) { data.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFFFFFF)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func fourCC(_ s: String) {
        var bytes = Array(s.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        data.append(contentsOf: bytes)
    }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func zeros(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: max(0, n))) }
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

/// Codec-agnostic fragmented-MP4 (CMAF-style) writer. The codec-specific
/// part — the complete sample entry box (`hvc1`, `ec-3`, `mp4a`, `fLaC`…) —
/// is built by `RemuxCodecs` and handed in through `TrackConfig.sampleEntry`.
final class FMP4Muxer {

    struct TrackConfig {
        enum Handler { case video, audio }

        let trackID: UInt32
        let timescale: UInt32
        let handler: Handler
        /// Presentation (display) size for `tkhd`; 0 for audio.
        let width: Int
        let height: Int
        /// ISO 639-2/T three-letter code for `mdhd` ("und" when unknown).
        let language: String
        /// Complete sample entry box for `stsd`.
        let sampleEntry: Data

        var isVideo: Bool { handler == .video }

        init(trackID: UInt32, timescale: UInt32, handler: Handler,
             width: Int = 0, height: Int = 0, language: String = "und", sampleEntry: Data) {
            self.trackID = trackID
            self.timescale = timescale
            self.handler = handler
            self.width = width
            self.height = height
            self.language = language
            self.sampleEntry = sampleEntry
        }
    }

    struct Sample {
        let data: Data
        let duration: UInt32   // in track timescale
        let sync: Bool
        /// PTS − DTS in track timescale (B-frame reorder). trun v1, signed.
        var compositionOffset: Int32 = 0
    }

    /// ftyp + moov for the given tracks. `extraBrands` are appended to the
    /// compatible brands (e.g. "dby1" for Dolby Vision).
    static func initSegment(tracks: [TrackConfig], extraBrands: [String] = []) -> Data {
        var out = Data()
        out.append(box("ftyp") { w in
            w.fourCC("iso6"); w.u32(1)
            w.fourCC("iso6"); w.fourCC("cmfc"); w.fourCC("mp41")
            for brand in extraBrands where brand.utf8.count == 4 { w.fourCC(brand) }
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
                w.u32(UInt32((tracks.map { $0.trackID }.max() ?? 0) + 1)) // next track id
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

    /// ISO 639-2/T code packed into 15 bits (3 × 5-bit letters − 0x60).
    static func packedLanguage(_ code: String) -> UInt16 {
        let letters = Array(code.lowercased().utf8)
        guard letters.count == 3, letters.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return 0x55C4 } // "und"
        return (UInt16(letters[0] - 0x60) << 10) | (UInt16(letters[1] - 0x60) << 5) | UInt16(letters[2] - 0x60)
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
                w.u32(UInt32(max(0, track.width)) << 16)
                w.u32(UInt32(max(0, track.height)) << 16)
            })
            trak.bytes(box("mdia") { mdia in
                mdia.bytes(fullBox("mdhd", version: 0, flags: 0) { w in
                    w.u32(0); w.u32(0)
                    w.u32(track.timescale)
                    w.u32(0)
                    w.u16(packedLanguage(track.language)); w.u16(0)
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
                            w.bytes(track.sampleEntry)
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

    /// One moof+mdat for a set of per-track samples.
    ///
    /// A track with NO sample gets a traf with only tfhd + tfdt — valid ISO
    /// BMFF (trun is optional), but AVPlayer stalls on such HLS segments: the
    /// session never relies on it (it writes a stretched filler frame
    /// instead); kept only as a last resort that can't crash anything.
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
                        guard !entry.samples.isEmpty else { return }
                        // trun: data-offset | duration | size | flags, plus
                        // signed composition offsets (v1, B-frame reorder)
                        // only when some sample actually has one.
                        let hasOffsets = entry.samples.contains { $0.compositionOffset != 0 }
                        traf.bytes(fullBox("trun", version: hasOffsets ? 1 : 0, flags: hasOffsets ? 0x000F01 : 0x000701) { w in
                            w.u32(UInt32(entry.samples.count))
                            w.u32(dataOffsets[index])
                            for sample in entry.samples {
                                w.u32(sample.duration)
                                w.u32(UInt32(sample.data.count))
                                w.u32(sample.sync ? 0x02000000 : 0x01010000)
                                if hasOffsets { w.u32(UInt32(bitPattern: sample.compositionOffset)) }
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
