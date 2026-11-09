

import Foundation
import Compression

// MARK: - Matroska model

/// SMPTE ST 2086 mastering display metadata (Matroska `MasteringMetadata`).
struct MKVMasteringMetadata: Equatable {
    var primaryRX: Double?, primaryRY: Double?
    var primaryGX: Double?, primaryGY: Double?
    var primaryBX: Double?, primaryBY: Double?
    var whitePointX: Double?, whitePointY: Double?
    var luminanceMax: Double?
    var luminanceMin: Double?
}

/// Matroska `Video/Colour` element. Code points follow ISO/IEC 23091-4
/// (same numbering as H.264/HEVC VUI): e.g. transfer 16 = PQ, 18 = HLG,
/// primaries 9 = BT.2020, matrix 9 = BT.2020 NCL.
struct MKVColour: Equatable {
    var matrixCoefficients: Int?
    var bitsPerChannel: Int?
    var chromaSubsamplingHorz: Int?
    var chromaSubsamplingVert: Int?
    /// 0 unspecified, 1 broadcast (limited), 2 full, 3 defined by matrix/transfer.
    var range: Int?
    var transferCharacteristics: Int?
    var primaries: Int?
    var maxCLL: Int?
    var maxFALL: Int?
    var mastering: MKVMasteringMetadata?
}

/// Matroska `BlockAdditionMapping` (e.g. Dolby Vision `dvcC` / `dvvC`).
struct MKVBlockAdditionMapping: Equatable {
    var idValue: UInt64?
    var idName: String?
    /// `BlockAddIDType`, a big-endian FourCC packed in an integer
    /// (0x64766343 = "dvcC", 0x64767643 = "dvvC").
    var idType: UInt32 = 0
    var extraData: Data = Data()

    var idTypeFourCC: String {
        let bytes = [UInt8(idType >> 24 & 0xFF), UInt8(idType >> 16 & 0xFF), UInt8(idType >> 8 & 0xFF), UInt8(idType & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// One Matroska `ContentEncoding` entry of a track.
struct MKVContentEncoding: Equatable {
    enum Algorithm: Equatable {
        case zlib
        case bzlib
        case lzo1x
        /// Header stripping: `settings` must be PREPENDED to every frame.
        case headerStripping
        case encryption
        /// Unknown `ContentCompAlgo` (compression), or unknown
        /// `ContentEncodingType` (neither compression nor encryption).
        case unknown(UInt64)
    }
    var order: UInt64 = 0
    /// Bit field: 1 = frame contents, 2 = CodecPrivate, 4 = next encoding.
    var scope: UInt64 = 1
    var algorithm: Algorithm = .zlib
    /// `ContentCompSettings` (the stripped header bytes for header stripping).
    var settings: Data = Data()

    /// True for the algorithms the demuxer reverses (zlib, header stripping).
    var isReversible: Bool {
        switch algorithm {
        case .zlib, .headerStripping: return true
        default: return false
        }
    }
}

struct MKVTrack {
    enum Kind { case video, audio, subtitle, other }

    var number: UInt64 = 0
    var uid: UInt64 = 0
    var kind: Kind = .other
    var codecID: String = ""
    /// CodecPrivate with any CodecPrivate-scoped content encoding already reversed.
    var codecPrivate: Data = Data()
    var name: String?
    /// ISO 639-2 language (Matroska default is "eng" when the element is absent).
    var language: String = "eng"
    /// `LanguageBCP47` (0x22B59D) — takes precedence over `language` when present.
    var languageBCP47: String?
    var flagEnabled = true
    /// Matroska default for FlagDefault is 1.
    var flagDefault = true
    var flagForced = false
    var flagHearingImpaired = false
    var flagVisualImpaired = false
    var flagTextDescriptions = false
    var flagOriginal = false
    var flagCommentary = false
    /// Nanoseconds per frame (`DefaultDuration`), 0 when absent.
    var defaultDurationNs: UInt64 = 0
    var codecDelayNs: UInt64 = 0
    var seekPreRollNs: UInt64 = 0

    // Video
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var displayWidth: Int?
    var displayHeight: Int?
    /// 0 pixels (default), 1 cm, 2 inches, 3 display aspect ratio, 4 unknown.
    var displayUnit: Int = 0
    var colour: MKVColour?

    // Audio
    var samplingFrequency: Double = 8000
    var outputSamplingFrequency: Double?
    var channels: Int = 1
    var bitDepth: Int?

    var blockAdditionMappings: [MKVBlockAdditionMapping] = []
    /// Ordered as they must be REVERSED when reading (highest order first).
    var contentEncodings: [MKVContentEncoding] = []
    /// Set when a CodecPrivate-scoped content encoding could not be reversed
    /// (bzlib/lzo/encryption, or a corrupt zlib stream): `codecPrivate` is
    /// then still encoded and unusable.
    var codecPrivateEncodingFailed = false

    /// True when the track uses an encoding the demuxer can't undo
    /// (encryption, bzlib, lzo…). Such tracks must be treated as unsupported.
    var hasUnsupportedContentEncoding: Bool {
        if codecPrivateEncodingFailed { return true }
        return contentEncodings.contains { enc in
            guard enc.scope & 1 != 0 else { return false }
            return !enc.isReversible
        }
    }

    /// Best language tag for HLS `LANGUAGE` (BCP 47), nil for "und"/empty.
    var bcp47Language: String? {
        if let bcp = languageBCP47?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bcp.isEmpty, bcp.lowercased() != "und" {
            return bcp
        }
        // `Language` uses the legacy "Matroska languages form": an ISO 639-2
        // code, optionally followed by "-<country>" ("fre-ca", "por-br").
        let raw = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = raw.split(separator: "-", maxSplits: 1).map(String.init)
        guard let base = parts.first, !base.isEmpty,
              base != "und", base != "zxx", base != "mis", base != "mul" else { return nil }
        let primary = MKVTrack.iso639_1(fromISO639_2: base) ?? base
        if parts.count == 2, !parts[1].isEmpty { return primary + "-" + parts[1].uppercased() }
        return primary
    }

    /// ISO 639-2 (B or T) → ISO 639-1 for the common languages; nil when unknown.
    static func iso639_1(fromISO639_2 code: String) -> String? {
        iso639Table[code.lowercased()]
    }

    private static let iso639Table: [String: String] = [
        "eng": "en", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "spa": "es", "ita": "it",
        "por": "pt", "dut": "nl", "nld": "nl", "rus": "ru", "jpn": "ja", "chi": "zh", "zho": "zh",
        "kor": "ko", "ara": "ar", "heb": "he", "hin": "hi", "tur": "tr", "pol": "pl", "cze": "cs",
        "ces": "cs", "slo": "sk", "slk": "sk", "hun": "hu", "rum": "ro", "ron": "ro", "gre": "el",
        "ell": "el", "swe": "sv", "nor": "no", "nob": "nb", "nno": "nn", "dan": "da", "fin": "fi",
        "ice": "is", "isl": "is", "ukr": "uk", "bul": "bg", "hrv": "hr", "srp": "sr", "slv": "sl",
        "est": "et", "lav": "lv", "lit": "lt", "vie": "vi", "tha": "th", "ind": "id", "may": "ms",
        "msa": "ms", "per": "fa", "fas": "fa", "cat": "ca", "baq": "eu", "eus": "eu", "glg": "gl",
        "wel": "cy", "cym": "cy", "gle": "ga", "alb": "sq", "sqi": "sq", "mac": "mk", "mkd": "mk",
        "bos": "bs", "arm": "hy", "hye": "hy", "geo": "ka", "kat": "ka", "tam": "ta", "tel": "te",
        "ben": "bn", "urd": "ur", "fil": "fil", "tgl": "tl", "lat": "la", "epo": "eo", "afr": "af",
        "swa": "sw", "kaz": "kk", "uzb": "uz", "aze": "az", "mon": "mn", "nep": "ne", "sin": "si",
        "khm": "km", "lao": "lo", "bur": "my", "mya": "my", "amh": "am", "som": "so", "yor": "yo",
        // Additional ISO 639-1 mappings (B and T codes).
        "tib": "bo", "bod": "bo", "scc": "sr", "scr": "hr", "bel": "be", "pan": "pa", "guj": "gu",
        "mar": "mr", "kan": "kn", "mal": "ml", "ori": "or", "asm": "as", "pus": "ps", "kur": "ku",
        "yid": "yi", "ltz": "lb", "fao": "fo", "bre": "br", "cos": "co", "oci": "oc", "roh": "rm",
        "gla": "gd", "mlt": "mt", "tat": "tt", "kir": "ky", "tuk": "tk", "tgk": "tg", "uig": "ug",
        "hau": "ha", "ibo": "ig", "zul": "zu", "xho": "xh", "sna": "sn", "kin": "rw", "mlg": "mg",
        "mao": "mi", "mri": "mi", "smo": "sm", "jav": "jv", "sun": "su", "hat": "ht", "que": "qu",
        "nav": "nv", "ina": "ia", "div": "dv", "san": "sa", "snd": "sd", "tir": "ti", "orm": "om",
        "wol": "wo", "ful": "ff", "lin": "ln", "nya": "ny", "sot": "st", "tsn": "tn", "tso": "ts",
        "ssw": "ss", "ven": "ve", "nbl": "nr", "sme": "se", "iku": "iu", "kal": "kl", "abk": "ab",
        "oss": "os", "che": "ce", "chv": "cv", "bak": "ba", "kom": "kv", "aym": "ay", "grn": "gn",
        "lug": "lg", "run": "rn", "sag": "sg", "twi": "tw", "ewe": "ee", "aka": "ak", "bam": "bm",
        "kas": "ks", "fry": "fy", "lim": "li", "wln": "wa", "srd": "sc", "glv": "gv", "cor": "kw",
        "ido": "io", "vol": "vo", "ile": "ie", "nau": "na", "fij": "fj", "ton": "to", "tah": "ty",
        "mah": "mh", "hmo": "ho", "cha": "ch", "her": "hz", "kik": "ki", "kua": "kj", "ndo": "ng",
        "nde": "nd", "kon": "kg", "iii": "ii", "zha": "za", "chu": "cu", "pli": "pi", "ave": "ae",
        "bis": "bi", "bih": "bh", "dzo": "dz", "ipk": "ik", "kau": "kr", "ike": "iu", "aar": "aa",
    ]
}

struct MKVFrame {
    let trackNumber: UInt64
    /// Absolute timestamp in TimestampScale units (usually milliseconds).
    let timestamp: Int64
    let keyframe: Bool
    /// Frame payload with frame-scoped content encodings already reversed
    /// (header stripping re-applied, zlib inflated).
    let data: Data
    /// `BlockDuration` (TimestampScale units) when the block carried one —
    /// mandatory for subtitle cues. nil for SimpleBlocks / absent.
    var duration: Int64? = nil
    /// `BlockAdditions` keyed by `BlockAddID` (WebVTT cue settings, …).
    var additions: [UInt64: Data] = [:]
}

// MARK: - Matroska demuxer

/// Incremental Matroska / WebM demuxer over a file that may still be
/// downloading. Torrent payloads are PREALLOCATED at full size: bytes that
/// haven't been downloaded read as zeros, so every structure that would
/// require a 0x00 byte where real data must be non-zero (element IDs, sizes),
/// a zero run inside a block payload that the codec can't produce
/// (`MissingDataCheck`), or a zero tail running into zeros / the end of the
/// data is treated as "not downloaded yet": the call returns nil and the
/// same cluster is retried later. Once `assumeFullyDownloaded` is set, zeros
/// are real bytes (skipped as damage / padding) and the end of data is final.
final class MatroskaDemuxer {
    // Element IDs
    enum ID {
        static let ebml: UInt32 = 0x1A45DFA3
        static let docType: UInt32 = 0x4282
        static let segment: UInt32 = 0x18538067
        static let seekHead: UInt32 = 0x114D9B74
        static let info: UInt32 = 0x1549A966
        static let timestampScale: UInt32 = 0x2AD7B1
        static let duration: UInt32 = 0x4489
        static let muxingApp: UInt32 = 0x4D80
        static let writingApp: UInt32 = 0x5741
        static let tracks: UInt32 = 0x1654AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackUID: UInt32 = 0x73C5
        static let trackType: UInt32 = 0x83
        static let flagEnabled: UInt32 = 0xB9
        static let flagDefault: UInt32 = 0x88
        static let flagForced: UInt32 = 0x55AA
        static let flagHearingImpaired: UInt32 = 0x55AB
        static let flagVisualImpaired: UInt32 = 0x55AC
        static let flagTextDescriptions: UInt32 = 0x55AD
        static let flagOriginal: UInt32 = 0x55AE
        static let flagCommentary: UInt32 = 0x55AF
        static let name: UInt32 = 0x536E
        static let language: UInt32 = 0x22B59C
        static let languageBCP47: UInt32 = 0x22B59D
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let codecDelay: UInt32 = 0x56AA
        static let seekPreRoll: UInt32 = 0x56BB
        static let defaultDuration: UInt32 = 0x23E383
        static let videoSettings: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let displayWidth: UInt32 = 0x54B0
        static let displayHeight: UInt32 = 0x54BA
        static let displayUnit: UInt32 = 0x54B2
        static let colour: UInt32 = 0x55B0
        static let matrixCoefficients: UInt32 = 0x55B1
        static let bitsPerChannel: UInt32 = 0x55B2
        static let chromaSubsamplingHorz: UInt32 = 0x55B3
        static let chromaSubsamplingVert: UInt32 = 0x55B4
        static let range: UInt32 = 0x55B9
        static let transferCharacteristics: UInt32 = 0x55BA
        static let primaries: UInt32 = 0x55BB
        static let maxCLL: UInt32 = 0x55BC
        static let maxFALL: UInt32 = 0x55BD
        static let masteringMetadata: UInt32 = 0x55D0
        static let primaryRChromaticityX: UInt32 = 0x55D1
        static let primaryRChromaticityY: UInt32 = 0x55D2
        static let primaryGChromaticityX: UInt32 = 0x55D3
        static let primaryGChromaticityY: UInt32 = 0x55D4
        static let primaryBChromaticityX: UInt32 = 0x55D5
        static let primaryBChromaticityY: UInt32 = 0x55D6
        static let whitePointChromaticityX: UInt32 = 0x55D7
        static let whitePointChromaticityY: UInt32 = 0x55D8
        static let luminanceMax: UInt32 = 0x55D9
        static let luminanceMin: UInt32 = 0x55DA
        static let audioSettings: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let outputSamplingFrequency: UInt32 = 0x78B5
        static let channels: UInt32 = 0x9F
        static let bitDepth: UInt32 = 0x6264
        static let blockAdditionMapping: UInt32 = 0x41E4
        static let blockAddIDValue: UInt32 = 0x41F0
        static let blockAddIDName: UInt32 = 0x41A4
        static let blockAddIDType: UInt32 = 0x41E7
        static let blockAddIDExtraData: UInt32 = 0x41ED
        static let contentEncodings: UInt32 = 0x6D80
        static let contentEncoding: UInt32 = 0x6240
        static let contentEncodingOrder: UInt32 = 0x5031
        static let contentEncodingScope: UInt32 = 0x5032
        static let contentEncodingType: UInt32 = 0x5033
        static let contentCompression: UInt32 = 0x5034
        static let contentCompAlgo: UInt32 = 0x4254
        static let contentCompSettings: UInt32 = 0x4255
        static let contentEncryption: UInt32 = 0x5035
        static let cluster: UInt32 = 0x1F43B675
        static let clusterTimestamp: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let blockDuration: UInt32 = 0x9B
        static let referenceBlock: UInt32 = 0xFB
        static let blockAdditions: UInt32 = 0x75A1
        static let blockMore: UInt32 = 0xA6
        static let blockAddID: UInt32 = 0xEE
        static let blockAdditional: UInt32 = 0xA5
        static let cues: UInt32 = 0x1C53BB6B
        static let seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB
        static let seekPosition: UInt32 = 0x53AC
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueTrack: UInt32 = 0xF7
        static let cueClusterPosition: UInt32 = 0xF1
        static let chapters: UInt32 = 0x1043A770
        static let tags: UInt32 = 0x1254C367
        static let attachments: UInt32 = 0x1941A469
        static let void: UInt32 = 0xEC
        static let crc32: UInt32 = 0xBF
        // Cluster-level children that are skipped (listed so stray ones are recognised).
        static let silentTracks: UInt32 = 0x5854
        static let position: UInt32 = 0xA7
        static let prevSize: UInt32 = 0xAB
        static let encryptedBlock: UInt32 = 0xAF
        static let discardPadding: UInt32 = 0x75A2
    }

    // MARK: Tunables

    /// The generic rule: a run of zeros this long inside a block can't be
    /// real data — a region of the preallocated file not downloaded yet.
    /// Used where a shorter legitimate run can't be ruled out: codecs the
    /// remux doesn't play natively (DTS, TrueHD, Vorbis…), image subtitles,
    /// sync-word audio whose sync word is stripped (header stripping),
    /// encodings the demuxer can't undo, and video codecs whose payload may
    /// hold zero stuffing (MPEG-1/2, VfW, QuickTime). See `missingDataCheck`.
    static let zeroRunThreshold = 64 * 1024
    /// libtorrent's block size: a piece missing from a preallocated file is
    /// at least this long, so any run this long is a hole for every codec
    /// whose blocks never legitimately hold one (see `missingDataCheck`):
    /// entropy-coded video without emulation prevention (AV1, VP8/VP9,
    /// MPEG-4 Part 2, Theora…), the compressed audio the remux plays
    /// natively, text subtitles and zlib frames.
    static let blockZeroRunThreshold = 16 * 1024
    /// Length-prefixed AVC / HEVC: emulation prevention forbids 0x000000
    /// inside a NAL unit and a NAL unit never ends with 0x00 (H.264 / H.265
    /// §7.4.1-7.4.2), so a valid sample holds at most 3 consecutive zero
    /// bytes (leading bytes of a 4-byte length prefix), 5 at worst next to an
    /// HEVC NAL header starting with 0x00. A run of 64 zeros STRICTLY INSIDE a
    /// NAL unit is therefore a region not downloaded yet (a missing 16 KiB
    /// block, or the unwritten part of one being written). 64 keeps a >10×
    /// margin over the worst valid run (e.g. an encoder skipping emulation
    /// prevention in a short SEI field) and is the scan's probe stride.
    static let nalZeroRunThreshold = 64
    /// Zero runs that END a NAL unit (trailing_zero_8bits / zero stuffing that
    /// lax Annex B → length-prefixed converters such as ffmpeg's leave inside
    /// the preceding NAL unit) are tolerated below this length, a whole
    /// missing libtorrent block.
    static let nalTrailingZeroLimit = 16 * 1024
    /// A zero run this long (libtorrent's block size) inside a header body
    /// (Info / Tracks, e.g. inside a large CodecPrivate) is a missing piece.
    /// A zero byte where an element header must start is never valid EBML:
    /// while downloading it always means "not written yet", whatever the
    /// length of the gap (once complete, such gaps are skipped as damage).
    static let zeroGapThreshold = 16 * 1024
    /// Known-size clusters up to this size are read in one I/O; larger ones
    /// (or corrupt sizes) are parsed child by child. Typical clusters are
    /// 1–60 MB (5 s of a UHD remux); the cap bounds peak memory on Apple TV.
    static let maxInMemoryClusterSize: UInt64 = 64 * 1024 * 1024
    /// Upper bound for the EBML header, Info and Tracks bodies.
    static let maxHeaderElementSize: UInt64 = 64 * 1024 * 1024
    /// Upper bound for one cluster child (a block) in child-by-child mode.
    static let maxBlockSize: UInt64 = 256 * 1024 * 1024
    /// Decompression-bomb guard for zlib frames / CodecPrivate.
    static let maxInflatedSize = 64 * 1024 * 1024
    /// Bytes scanned per call when hunting for the next Cluster after garbage.
    static let resyncScanBudget = 64 * 1024 * 1024
    /// Upper bound for a SeekHead body read during `parseHeaders` (mkvmerge's
    /// and ffmpeg's are ~100 bytes; one Seek per cluster stays far below).
    static let maxSeekHeadSize: UInt64 = 1024 * 1024
    /// Upper bound for the Cues body `loadCueIndex` reads (a 3 h UHD remux
    /// with a cue point per 0.5 s keyframe holds ~1 MB).
    static let maxCuesSize: UInt64 = 32 * 1024 * 1024

    let reader: EBMLReader
    private(set) var docType: String = "matroska"
    private(set) var timestampScale: UInt64 = 1_000_000 // ns per tick → 1ms default
    /// Total duration in seconds, from the Segment Info header (0 if absent).
    private(set) var durationSeconds: Double = 0
    /// Info/MuxingApp ("Lavf60.16.100" for ffmpeg / libavformat, "libebml
    /// v1.4.4 + libmatroska v1.7.1" for mkvmerge…), nil when absent. Tells
    /// what the header Duration measures: libavformat writes the END time of
    /// the last frame (from Matroska time 0), mkvmerge the LENGTH from the
    /// first timestamp.
    private(set) var muxingApp: String?
    /// Info/WritingApp ("mkvmerge v80.0 ('…') 64-bit", "HandBrake 1.8.0",
    /// "Lavf60.16.100"…), nil when absent. Diagnostics.
    private(set) var writingApp: String?
    private(set) var tracks: [MKVTrack] = []
    private var segmentDataStart: UInt64 = 0
    /// End (absolute offset) of the Segment's data when its size is known;
    /// nil for an unknown-size Segment. See `loadCueIndex`.
    private var segmentDataEnd: UInt64?
    /// Absolute file offset of the Cues element: from the SeekHead (or a
    /// SeekHead it points to), or seen while walking the top-level elements
    /// before the first Cluster. nil while unknown. See `loadCueIndex`.
    private(set) var cuesPosition: UInt64?
    /// SeekHeads a SeekHead points to (mkvmerge's second one, at the end of
    /// the file), not read yet: `loadCueIndex` looks for the Cues there.
    private var pendingSeekHeads: [UInt64] = []

    /// When set, `readNextCluster()` only returns frames of these track
    /// numbers; other tracks' blocks are skipped without being copied,
    /// decoded or checked for missing pieces. nil (default) = every track.
    var trackFilter: Set<UInt64>?

    /// Set once the file is known to be completely downloaded. Zero-filled
    /// regions are then real bytes (padding / damage) rather than pieces
    /// still to come: they're skipped instead of waited for, and the end of
    /// the file is final. While false, the end of the available data counts
    /// as "not downloaded yet" (a zero tail reaching it is waited for).
    var assumeFullyDownloaded = false {
        didSet {
            // A region recorded as "still zero" while downloading may be real
            // zero bytes: never let it block a complete file.
            if assumeFullyDownloaded { blockedProbe = nil }
        }
    }

    /// Known-size clusters up to this size are read in one I/O; larger ones
    /// (or corrupt sizes) are parsed child by child.
    var inMemoryClusterLimit: UInt64 = MatroskaDemuxer.maxInMemoryClusterSize

    init(reader: EBMLReader) { self.reader = reader }

    /// Seconds per TimestampScale tick.
    var secondsPerTick: Double { Double(timestampScale) / 1_000_000_000 }

    // MARK: Private state

    /// How a track's block payloads are checked for regions of a preallocated
    /// file that are not downloaded yet (zero-filled), while downloading.
    enum MissingDataCheck: Equatable {
        /// Uncompressed payloads (PCM…): zero runs are digital silence.
        case none
        /// A zero run of at least this many bytes anywhere in the block after
        /// its track number: timestamp, flags, lace header or frames.
        case zeroRun(Int)
        /// Length-prefixed AVC / HEVC NAL units (`lengthSize`-byte prefixes):
        /// a zero run of `nalZeroRunThreshold` bytes inside a NAL unit, or of
        /// `nalTrailingZeroLimit` bytes anywhere.
        case nalUnits(lengthSize: Int)
    }

    /// Per-track data needed on the hot path.
    private struct TrackRuntime {
        var defaultDurationNs: UInt64
        /// Frame-scoped encodings, highest order first.
        var frameEncodings: [MKVContentEncoding]
        /// False when one of `frameEncodings` can't be reversed: frames are
        /// then returned untouched (the track is flagged unsupported).
        var decodesFrames: Bool
        /// Codec-aware missing-piece heuristic for this track's payloads.
        var missingDataCheck: MissingDataCheck
    }

    /// A region that was entirely zero (not downloaded) when the last call
    /// gave up. While it stays zero, the same cluster can't complete, so the
    /// next call returns nil without re-reading it.
    private struct ZeroProbe {
        var anchor: UInt64
        var region: ZeroRegion
    }

    private struct ZeroRegion {
        var offset: UInt64
        var length: Int
        /// Tail rule: the byte right after the cluster, which must ALSO still
        /// be zero (or past the end of the data) for the cluster to stay
        /// incomplete — a cluster ending in 0x00 followed by real data is done.
        var following: UInt64? = nil
    }

    private enum ClusterOutcome {
        case complete([MKVFrame])
        /// Not fully downloaded; `region` is the zero area that blocked it
        /// (nil when the data simply isn't there yet).
        case incomplete(ZeroRegion?)
    }

    private enum BlockOutcome {
        case done
        /// A zero region (absolute file offset, probe length) — a long zero
        /// run in the payload, or a zeroed child of a BlockGroup.
        case notDownloaded(UInt64, Int)
    }

    private enum ResyncOutcome {
        case found(UInt64)
        case blocked
        case progressed
    }

    private var runtimeByNumber: [UInt64: TrackRuntime] = [:]
    private var blockedProbe: ZeroProbe?
    /// Non-nil while hunting for the next Cluster after unparseable bytes.
    private var resyncFrom: UInt64?
    /// End of the last cluster returned, and its timestamp: blocks found
    /// right there (a cluster whose size was too small, or an unknown-size
    /// cluster that hit the end of a growing file) continue that cluster.
    private var lastClusterEnd: UInt64?
    private var lastClusterTimestamp: Int64 = 0

    private func resetState() {
        docType = "matroska"
        timestampScale = 1_000_000
        durationSeconds = 0
        muxingApp = nil
        writingApp = nil
        tracks = []
        segmentDataStart = 0
        segmentDataEnd = nil
        cuesPosition = nil
        pendingSeekHeads = []
        runtimeByNumber = [:]
        blockedProbe = nil
        resyncFrom = nil
        lastClusterEnd = nil
        lastClusterTimestamp = 0
    }

    // MARK: - Headers

    /// Parses up to and including the Tracks element. Returns false if the
    /// header isn't fully available yet (caller can retry once more of the
    /// file has downloaded). Re-callable: every call starts from scratch.
    /// Returns as soon as Info and Tracks are both parsed (or at the first
    /// Cluster), so a caller can reject unplayable tracks without waiting
    /// for the multi-MB Attachments (fonts) that often precede the first
    /// Cluster; `readNextCluster()` skips those by size. A file whose header
    /// ends without Tracks is reported parsed with no tracks (fail fast).
    func parseHeaders() -> Bool {
        resetState()
        reader.seek(to: 0)

        guard case let .element(ebmlID, ebmlSize, ebmlHeaderLength) = reader.header(at: 0),
              ebmlID == ID.ebml, ebmlSize != UInt64.max, ebmlSize <= Self.maxHeaderElementSize,
              let ebmlBody = headerBody(at: UInt64(ebmlHeaderLength), size: ebmlSize) else { return false }
        EBML.forEachChild(ebmlBody) { id, payload in
            if id == ID.docType { docType = EBML.string(payload) }
        }

        // Segment (tolerating top-level Void / CRC-32 before it).
        var position = UInt64(ebmlHeaderLength) + ebmlSize
        while true {
            guard case let .element(id, size, headerLength) = reader.header(at: position) else { return false }
            if id == ID.segment {
                position += UInt64(headerLength)
                if size != UInt64.max {
                    let (end, overflow) = position.addingReportingOverflow(size)
                    segmentDataEnd = overflow ? nil : end
                }
                break
            }
            guard id == ID.void || id == ID.crc32, size != UInt64.max else { return false }
            position += UInt64(headerLength) + size
        }
        segmentDataStart = position

        // Walk the Segment's children until Info + Tracks (Info may come after
        // Tracks); a SeekHead's small body is read (where the Cues are), and
        // Void / Tags / Attachments / Cues met on the way are skipped by size
        // without reading their bodies (a Cues element's position is noted).
        var tracksParsed = false
        var infoParsed = false
        while true {
            let header = reader.header(at: position)
            guard case let .element(id, size, headerLength) = header else {
                let damaged: Bool
                switch header {
                case .malformed: damaged = true
                // In a complete file, zero bytes / the end of the data are final.
                case .zero, .truncated: damaged = assumeFullyDownloaded
                case .element: damaged = false
                }
                if damaged, tracksParsed {
                    // Damage after a complete Tracks element: readNextCluster()
                    // resynchronises on the next Cluster.
                    reader.seek(to: position)
                    finishHeaders()
                    return true
                }
                return false
            }
            let bodyStart = position + UInt64(headerLength)
            switch id {
            case ID.cluster:
                reader.seek(to: position)
                finishHeaders()
                // A file whose header ends without Tracks has no playable
                // track: report it parsed (empty) so the caller fails fast.
                return true
            case ID.info, ID.tracks:
                guard size != UInt64.max, size <= Self.maxHeaderElementSize,
                      let body = headerBody(at: bodyStart, size: size) else { return false }
                if id == ID.info {
                    if !infoParsed { parseInfo(body) }
                    infoParsed = true
                } else if !tracksParsed {
                    parseTracks(body)
                    tracksParsed = true
                }
                position = bodyStart + size
                if infoParsed && tracksParsed {
                    reader.seek(to: position)
                    finishHeaders()
                    return true
                }
            case ID.ebml, ID.segment:
                // A second (chained) segment before any cluster.
                guard tracksParsed else { return false }
                reader.seek(to: position)
                finishHeaders()
                return true
            case ID.seekHead:
                // Where the Cues are (the keyframe index, `loadCueIndex`).
                guard size != UInt64.max else { return false }
                if size <= Self.maxSeekHeadSize, let body = headerBody(at: bodyStart, size: size) {
                    noteSeekEntries(body, at: position)
                }
                position = bodyStart + size
            default:
                guard size != UInt64.max else { return false }
                if id == ID.cues, cuesPosition == nil { cuesPosition = position }
                position = bodyStart + size
            }
        }
    }

    /// Records the Cues and further SeekHead positions a SeekHead body
    /// (located at `own`) lists. Positions are relative to the Segment's data.
    private func noteSeekEntries(_ body: Data, at own: UInt64) {
        EBML.forEachChild(body) { id, seek in
            guard id == ID.seek else { return }
            var target: UInt32?
            var offset: UInt64?
            EBML.forEachChild(seek) { field, payload in
                if field == ID.seekID, (1...4).contains(payload.count) {
                    target = payload.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                } else if field == ID.seekPosition, (1...8).contains(payload.count) {
                    offset = EBML.uint(payload)
                }
            }
            guard let element = target, let relative = offset else { return }
            let (absolute, overflow) = segmentDataStart.addingReportingOverflow(relative)
            guard !overflow else { return }
            if element == ID.cues, cuesPosition == nil {
                cuesPosition = absolute
            } else if element == ID.seekHead, absolute != own, !pendingSeekHeads.contains(absolute) {
                pendingSeekHeads.append(absolute)
            }
        }
    }

    /// Body of a header element (EBML header, Info, Tracks); nil when it isn't
    /// available or may still contain a zero-filled (not downloaded) region:
    /// a zero run of a BitTorrent piece's minimum size, a 0x00 byte where a
    /// child header must be (any length of zeros: e.g. a block being
    /// written), or a zero tail running into zeros / the end of the data
    /// after the element (the download frontier).
    /// Parsing a half-downloaded Tracks would silently drop tracks.
    private func headerBody(at offset: UInt64, size: UInt64) -> Data? {
        guard let body = reader.bytes(at: offset, count: Int(size)) else { return nil }
        guard !assumeFullyDownloaded, !body.isEmpty else { return body }
        let incomplete = body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            if Self.firstZeroRun(raw, from: 0, to: raw.count, threshold: Self.zeroGapThreshold) != nil { return true }
            if Self.hasZeroHeader(raw) { return true }
            return raw[raw.count - 1] == 0 && nextByteIsZero(at: offset + size)
        }
        return incomplete ? nil : body
    }

    /// Master elements of the header bodies that the parser descends into.
    static func isParsedHeaderMaster(_ id: UInt32) -> Bool {
        switch id {
        case ID.trackEntry, ID.videoSettings, ID.audioSettings, ID.colour, ID.masteringMetadata,
             ID.blockAdditionMapping, ID.contentEncodings, ID.contentEncoding, ID.contentCompression:
            return true
        default:
            return false
        }
    }

    /// True when a child header of `raw` (descending into the masters the
    /// parser reads) has a 0x00 byte where no valid header does: a region of
    /// a preallocated file not downloaded yet.
    static func hasZeroHeader(_ raw: UnsafeRawBufferPointer, depth: Int = 0) -> Bool {
        var pos = 0
        while pos < raw.count {
            switch EBML.header(in: raw, at: pos) {
            case .zero:
                return true
            case .truncated, .malformed:
                return false
            case let .element(id, size, headerLength):
                let start = pos + headerLength
                guard size != UInt64.max, size <= UInt64(raw.count - start) else { return false }
                let end = start + Int(size)
                if depth < 6, isParsedHeaderMaster(id),
                   hasZeroHeader(UnsafeRawBufferPointer(rebasing: raw[start..<end]), depth: depth + 1) {
                    return true
                }
                pos = end
            }
        }
        return false
    }

    private func finishHeaders() {
        runtimeByNumber = [:]
        for track in tracks {
            let frameEncodings = track.contentEncodings.filter { $0.scope & 1 != 0 }
            runtimeByNumber[track.number] = TrackRuntime(
                defaultDurationNs: track.defaultDurationNs,
                frameEncodings: frameEncodings,
                decodesFrames: frameEncodings.allSatisfy { $0.isReversible },
                missingDataCheck: Self.missingDataCheck(for: track))
        }
    }

    private func parseInfo(_ body: Data) {
        var scale: UInt64 = 1_000_000
        var rawDuration: Double = 0
        EBML.forEachChild(body) { id, payload in
            switch id {
            case ID.timestampScale:
                let value = EBML.uint(payload, default: 1_000_000)
                scale = value == 0 ? 1_000_000 : value
            case ID.duration:
                if let value = EBML.finiteFloat(payload), value > 0 { rawDuration = value }
            case ID.muxingApp:
                let name = EBML.string(payload).trimmingCharacters(in: .whitespacesAndNewlines)
                if muxingApp == nil, !name.isEmpty { muxingApp = name }
            case ID.writingApp:
                let name = EBML.string(payload).trimmingCharacters(in: .whitespacesAndNewlines)
                if writingApp == nil, !name.isEmpty { writingApp = name }
            default:
                break
            }
        }
        timestampScale = scale
        let seconds = rawDuration * Double(scale) / 1_000_000_000
        durationSeconds = seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func parseTracks(_ body: Data) {
        var numbers = Set<UInt64>()
        EBML.forEachChild(body) { id, payload in
            guard id == ID.trackEntry else { return }
            let track = parseTrackEntry(payload)
            // TrackNumber 0 is invalid and numbers must be unique: blocks
            // couldn't be attributed to such tracks.
            guard track.number != 0, !numbers.contains(track.number) else { return }
            numbers.insert(track.number)
            tracks.append(track)
        }
    }

    private func parseTrackEntry(_ body: Data) -> MKVTrack {
        var track = MKVTrack()
        var sawTrackType = false
        EBML.forEachChild(body) { id, data in
            switch id {
            case ID.trackNumber: track.number = EBML.uint(data)
            case ID.trackUID: track.uid = EBML.uint(data)
            case ID.trackType:
                sawTrackType = true
                switch EBML.uint(data) {
                case 1: track.kind = .video
                case 2: track.kind = .audio
                case 0x11: track.kind = .subtitle // 17 = subtitle
                default: track.kind = .other
                }
            case ID.flagEnabled: track.flagEnabled = EBML.flag(data, default: true)
            case ID.flagDefault: track.flagDefault = EBML.flag(data, default: true)
            case ID.flagForced: track.flagForced = EBML.flag(data, default: false)
            case ID.flagHearingImpaired: track.flagHearingImpaired = EBML.flag(data, default: false)
            case ID.flagVisualImpaired: track.flagVisualImpaired = EBML.flag(data, default: false)
            case ID.flagTextDescriptions: track.flagTextDescriptions = EBML.flag(data, default: false)
            case ID.flagOriginal: track.flagOriginal = EBML.flag(data, default: false)
            case ID.flagCommentary: track.flagCommentary = EBML.flag(data, default: false)
            case ID.name:
                let name = EBML.string(data)
                track.name = name.isEmpty ? nil : name
            case ID.language:
                let language = EBML.string(data).trimmingCharacters(in: .whitespacesAndNewlines)
                track.language = language.isEmpty ? "eng" : language
            case ID.languageBCP47:
                let tag = EBML.string(data).trimmingCharacters(in: .whitespacesAndNewlines)
                track.languageBCP47 = tag.isEmpty ? nil : tag
            case ID.codecID: track.codecID = EBML.string(data)
            case ID.codecPrivate: track.codecPrivate = data
            case ID.codecDelay: track.codecDelayNs = EBML.uint(data)
            case ID.seekPreRoll: track.seekPreRollNs = EBML.uint(data)
            case ID.defaultDuration: track.defaultDurationNs = EBML.uint(data)
            case ID.videoSettings: parseVideo(data, into: &track)
            case ID.audioSettings: parseAudio(data, into: &track)
            case ID.blockAdditionMapping: track.blockAdditionMappings.append(parseBlockAdditionMapping(data))
            case ID.contentEncodings: track.contentEncodings.append(contentsOf: parseContentEncodings(data))
            default: break
            }
        }
        if !sawTrackType {
            // TrackType is mandatory; infer it from the CodecID prefix when absent.
            if track.codecID.hasPrefix("V_") { track.kind = .video }
            else if track.codecID.hasPrefix("A_") { track.kind = .audio }
            else if track.codecID.hasPrefix("S_") { track.kind = .subtitle }
        }
        // Decoders start with the HIGHEST ContentEncodingOrder (stable for ties).
        track.contentEncodings = track.contentEncodings.enumerated()
            .sorted { $0.element.order != $1.element.order ? $0.element.order > $1.element.order : $0.offset < $1.offset }
            .map { $0.element }
        reverseCodecPrivateEncodings(&track)
        return track
    }

    private func parseVideo(_ body: Data, into track: inout MKVTrack) {
        EBML.forEachChild(body) { id, data in
            switch id {
            case ID.pixelWidth: track.pixelWidth = Int(clamping: EBML.uint(data))
            case ID.pixelHeight: track.pixelHeight = Int(clamping: EBML.uint(data))
            case ID.displayWidth: track.displayWidth = Int(clamping: EBML.uint(data))
            case ID.displayHeight: track.displayHeight = Int(clamping: EBML.uint(data))
            case ID.displayUnit: track.displayUnit = Int(clamping: EBML.uint(data, default: 0))
            case ID.colour: track.colour = parseColour(data)
            default: break
            }
        }
    }

    private func parseColour(_ body: Data) -> MKVColour {
        var colour = MKVColour()
        func int(_ data: Data, default value: UInt64? = nil) -> Int {
            Int(clamping: value.map { EBML.uint(data, default: $0) } ?? EBML.uint(data))
        }
        EBML.forEachChild(body) { id, data in
            switch id {
            case ID.matrixCoefficients: colour.matrixCoefficients = int(data, default: 2)
            case ID.bitsPerChannel: colour.bitsPerChannel = int(data, default: 0)
            case ID.chromaSubsamplingHorz: colour.chromaSubsamplingHorz = int(data)
            case ID.chromaSubsamplingVert: colour.chromaSubsamplingVert = int(data)
            case ID.range: colour.range = int(data, default: 0)
            case ID.transferCharacteristics: colour.transferCharacteristics = int(data, default: 2)
            case ID.primaries: colour.primaries = int(data, default: 2)
            case ID.maxCLL: colour.maxCLL = int(data)
            case ID.maxFALL: colour.maxFALL = int(data)
            case ID.masteringMetadata: colour.mastering = parseMastering(data)
            default: break
            }
        }
        return colour
    }

    private func parseMastering(_ body: Data) -> MKVMasteringMetadata {
        var mastering = MKVMasteringMetadata()
        EBML.forEachChild(body) { id, data in
            let value = EBML.finiteFloat(data)
            switch id {
            case ID.primaryRChromaticityX: mastering.primaryRX = value
            case ID.primaryRChromaticityY: mastering.primaryRY = value
            case ID.primaryGChromaticityX: mastering.primaryGX = value
            case ID.primaryGChromaticityY: mastering.primaryGY = value
            case ID.primaryBChromaticityX: mastering.primaryBX = value
            case ID.primaryBChromaticityY: mastering.primaryBY = value
            case ID.whitePointChromaticityX: mastering.whitePointX = value
            case ID.whitePointChromaticityY: mastering.whitePointY = value
            case ID.luminanceMax: mastering.luminanceMax = value
            case ID.luminanceMin: mastering.luminanceMin = value
            default: break
            }
        }
        return mastering
    }

    private func parseAudio(_ body: Data, into track: inout MKVTrack) {
        EBML.forEachChild(body) { id, data in
            switch id {
            case ID.samplingFrequency:
                if data.isEmpty {
                    track.samplingFrequency = 8000
                } else if let value = EBML.finiteFloat(data), value > 0 {
                    track.samplingFrequency = value
                }
            case ID.outputSamplingFrequency:
                if let value = EBML.finiteFloat(data), value > 0 { track.outputSamplingFrequency = value }
            case ID.channels:
                let value = Int(clamping: EBML.uint(data, default: 1))
                track.channels = value > 0 ? value : 1
            case ID.bitDepth:
                let value = Int(clamping: EBML.uint(data))
                track.bitDepth = value > 0 ? value : nil
            default:
                break
            }
        }
    }

    private func parseBlockAdditionMapping(_ body: Data) -> MKVBlockAdditionMapping {
        var mapping = MKVBlockAdditionMapping()
        EBML.forEachChild(body) { id, data in
            switch id {
            case ID.blockAddIDValue: mapping.idValue = EBML.uint(data)
            case ID.blockAddIDName:
                let name = EBML.string(data)
                mapping.idName = name.isEmpty ? nil : name
            case ID.blockAddIDType: mapping.idType = UInt32(truncatingIfNeeded: EBML.uint(data))
            case ID.blockAddIDExtraData: mapping.extraData = data
            default: break
            }
        }
        return mapping
    }

    private func parseContentEncodings(_ body: Data) -> [MKVContentEncoding] {
        var encodings: [MKVContentEncoding] = []
        EBML.forEachChild(body) { id, data in
            guard id == ID.contentEncoding else { return }
            var encoding = MKVContentEncoding()
            var type: UInt64 = 0
            var compAlgo: UInt64 = 0
            EBML.forEachChild(data) { childID, childData in
                switch childID {
                case ID.contentEncodingOrder: encoding.order = EBML.uint(childData, default: 0)
                case ID.contentEncodingScope: encoding.scope = EBML.uint(childData, default: 1)
                case ID.contentEncodingType: type = EBML.uint(childData, default: 0)
                case ID.contentCompression:
                    EBML.forEachChild(childData) { compID, compData in
                        if compID == ID.contentCompAlgo { compAlgo = EBML.uint(compData, default: 0) }
                        if compID == ID.contentCompSettings { encoding.settings = compData }
                    }
                default:
                    break
                }
            }
            switch type {
            case 0:
                switch compAlgo {
                case 0: encoding.algorithm = .zlib
                case 1: encoding.algorithm = .bzlib
                case 2: encoding.algorithm = .lzo1x
                case 3: encoding.algorithm = .headerStripping
                default: encoding.algorithm = .unknown(compAlgo)
                }
            case 1:
                encoding.algorithm = .encryption
            default:
                encoding.algorithm = .unknown(type)
            }
            encodings.append(encoding)
        }
        return encodings
    }

    /// Reverses the CodecPrivate-scoped encodings (scope bit 2), highest
    /// order first. Like libavformat, an absent/empty CodecPrivate is left alone.
    private func reverseCodecPrivateEncodings(_ track: inout MKVTrack) {
        for encoding in track.contentEncodings where encoding.scope & 2 != 0 {
            guard !track.codecPrivate.isEmpty else { return }
            switch encoding.algorithm {
            case .headerStripping:
                track.codecPrivate = encoding.settings + track.codecPrivate
            case .zlib:
                guard let inflated = MatroskaZlib.inflate(track.codecPrivate, maxOutputSize: Self.maxInflatedSize) else {
                    track.codecPrivateEncodingFailed = true
                    return
                }
                track.codecPrivate = inflated
            default:
                track.codecPrivateEncodingFailed = true
                return
            }
        }
    }

    /// Codecs whose payloads are not entropy-coded: a long zero run there is
    /// silence / black, not a missing piece.
    static func isZeroTolerantCodec(_ codecID: String) -> Bool {
        codecID.hasPrefix("A_PCM/") || codecID == "A_MS/ACM" || codecID == "V_UNCOMPRESSED"
    }

    /// Sync-word audio the remux plays natively (AC-3, E-AC-3, MP3, MP2):
    /// every frame starts with a sync word (0x0B77, 0xFFF…) and is at most
    /// 4 KiB (AC-3 3840 B, E-AC-3 4096 B, MPEG audio 2881 B), so a laced
    /// block never holds 16 KiB of zeros — it would swallow several sync
    /// words. (A frame stored without its sync word — header stripping —
    /// loses that guarantee.)
    static let syncWordAudioCodecs: Set<String> = ["A_AC3", "A_AC3/BSID9", "A_AC3/BSID10", "A_EAC3",
                                                   "A_MPEG/L3", "A_MPEG/L2"]
    /// Entropy-coded audio the remux plays natively: digital silence codes
    /// to a few bytes per frame (FLAC constant subframes, ALAC zero-run
    /// mode, AAC zero spectra — an AAC frame is ≤ 768 B per channel and ends
    /// with its END element; Opus silence is a few bytes, and the zero
    /// padding of a hard-CBR Opus packet stays under 8 KB), so no legitimate
    /// block of theirs holds 16 KiB of zeros.
    static let compactSilenceAudioCodecs: Set<String> = ["A_AAC", "A_AAC/MPEG2/LC", "A_AAC/MPEG4/LC",
                                                         "A_AAC/MPEG2/LC/SBR", "A_AAC/MPEG4/LC/SBR",
                                                         "A_FLAC", "A_ALAC", "A_OPUS"]
    /// Text subtitles (the remux's WebVTT renditions, same list as
    /// `SubtitleConversion.isTextSubtitleCodec`): UTF-8 text holds no zeros.
    static let textSubtitleCodecs: Set<String> = ["S_TEXT/UTF8", "S_TEXT/ASCII", "S_TEXT/SSA", "S_TEXT/ASS",
                                                  "S_TEXT/WEBVTT", "S_SSA", "S_ASS",
                                                  "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS"]

    /// Codec-aware missing-piece heuristic for a track's block payloads.
    /// `blockZeroRunThreshold` (16 KiB, a whole missing libtorrent block)
    /// wherever no legitimate block holds that many zeros: zlib frames
    /// (deflate output has no long zero runs), the native compressed audio
    /// (see `syncWordAudioCodecs`, `compactSilenceAudioCodecs`), text
    /// subtitles, and entropy-coded video; the NAL walk for AVC / HEVC; the
    /// generic `zeroRunThreshold` elsewhere; nothing for uncompressed
    /// payloads, whose silence really is zeros.
    static func missingDataCheck(for track: MKVTrack) -> MissingDataCheck {
        let codecID = track.codecID
        if isZeroTolerantCodec(codecID) { return .none }
        let frameEncodings = track.contentEncodings.filter { $0.scope & 1 != 0 }
        let encoded = frameEncodings.filter { $0.algorithm != .headerStripping }
        if !encoded.isEmpty {
            // The stored bytes are the encoding's output: zlib's (deflate)
            // never holds a long zero run; encryption / bzlib / lzo /
            // unknown encodings (never remuxed) keep the generic rule.
            return encoded.allSatisfy { $0.algorithm == .zlib } ? .zeroRun(blockZeroRunThreshold) : .zeroRun(zeroRunThreshold)
        }
        let id = codecID.trimmingCharacters(in: .whitespaces).uppercased()
        if syncWordAudioCodecs.contains(id) {
            // Header stripping removes exactly the sync word.
            return .zeroRun(frameEncodings.isEmpty ? blockZeroRunThreshold : zeroRunThreshold)
        }
        if compactSilenceAudioCodecs.contains(id) || textSubtitleCodecs.contains(id) {
            return .zeroRun(blockZeroRunThreshold)
        }
        // Other audio (DTS, TrueHD, Vorbis… — not remuxed), image subtitles,
        // buttons…: the generic rule.
        guard codecID.hasPrefix("V_") else { return .zeroRun(zeroRunThreshold) }
        switch codecID {
        case "V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC":
            // Stripped header bytes shift the NAL structure: no NAL walk.
            guard frameEncodings.isEmpty else { return .zeroRun(blockZeroRunThreshold) }
            return .nalUnits(lengthSize: nalLengthSize(codecID: codecID, codecPrivate: track.codecPrivate))
        case "V_MPEG1", "V_MPEG2", "V_MS/VFW/FOURCC", "V_QUICKTIME":
            // MPEG-1/2 video may stuff zero bytes before start codes; VfW /
            // QuickTime payloads can be anything, uncompressed included.
            return .zeroRun(zeroRunThreshold)
        default:
            // Other compressed video (AV1, VP8/VP9, MPEG-4 Part 2, Theora…):
            // no emulation prevention, but entropy-coded frames never hold
            // 16 KiB of zeros.
            return .zeroRun(blockZeroRunThreshold)
        }
    }

    /// NAL length-prefix size from avcC (byte 4) / hvcC (byte 21); 4 when
    /// CodecPrivate isn't a version-1 configuration record.
    static func nalLengthSize(codecID: String, codecPrivate: Data) -> Int {
        let bytes = [UInt8](codecPrivate.prefix(23))
        if codecID == "V_MPEG4/ISO/AVC", bytes.count >= 5, bytes[0] == 1 { return Int(bytes[4] & 0x03) + 1 }
        if codecID == "V_MPEGH/ISO/HEVC", bytes.count >= 23, bytes[0] == 1 { return Int(bytes[21] & 0x03) + 1 }
        return 4
    }

    // MARK: - Element classes

    /// Level-1 (and root) element IDs: one of them at a cluster-child
    /// position ends an unknown-size (or oversized) cluster.
    static func isTopLevelID(_ id: UInt32) -> Bool {
        switch id {
        case ID.cluster, ID.cues, ID.tags, ID.chapters, ID.attachments, ID.seekHead,
             ID.info, ID.tracks, ID.ebml, ID.segment:
            return true
        default:
            return false
        }
    }

    static func isClusterChildID(_ id: UInt32) -> Bool {
        switch id {
        case ID.clusterTimestamp, ID.simpleBlock, ID.blockGroup, ID.position, ID.prevSize,
             ID.silentTracks, ID.encryptedBlock, ID.void, ID.crc32:
            return true
        default:
            return false
        }
    }

    // MARK: - Zero-run helpers

    /// Index of the first byte of a run of at least `threshold` zero bytes
    /// within `raw[from..<to]`, or nil. Probes one byte per `threshold`
    /// bytes, so it costs almost nothing on real (non-zero) data.
    static func firstZeroRun(_ raw: UnsafeRawBufferPointer, from: Int, to: Int, threshold: Int) -> Int? {
        let lower = max(0, from)
        let upper = min(raw.count, to)
        guard upper > lower else { return nil }
        if threshold <= 1 {
            var i = lower
            while i < upper { if raw[i] == 0 { return i }; i += 1 }
            return nil
        }
        guard upper - lower >= threshold else { return nil }
        // Any run of `threshold` bytes contains a probe position (spacing = threshold).
        var probe = lower + threshold - 1
        while probe < upper {
            if raw[probe] != 0 {
                probe += threshold
                continue
            }
            var start = probe
            while start > lower && raw[start - 1] == 0 { start -= 1 }
            var end = probe + 1
            while end < upper && raw[end] == 0 && end - start < threshold { end += 1 }
            if end - start >= threshold { return start }
            // `end` is non-zero (or the limit): the next run starts after it.
            probe = end + threshold
        }
        return nil
    }

    /// Maximal zero run containing `index` (raw[index] == 0), scanning at
    /// most `cap` bytes in each direction.
    static func zeroRun(_ raw: UnsafeRawBufferPointer, around index: Int, cap: Int) -> Range<Int> {
        var lower = index
        let lowerLimit = index > cap ? index - cap : 0
        while lower > lowerLimit && raw[lower - 1] == 0 { lower -= 1 }
        var upper = index + 1
        let upperLimit = raw.count - index > cap ? index + cap : raw.count
        while upper < upperLimit && raw[upper] == 0 { upper += 1 }
        return lower..<upper
    }

    static func containsLongZeroRun(_ data: Data, threshold: Int = 64 * 1024) -> Bool {
        data.withUnsafeBytes { raw in
            firstZeroRun(raw, from: 0, to: raw.count, threshold: max(1, threshold)) != nil
        }
    }

    /// First region of a block (`raw`, its frames `laces`) that reads as not
    /// downloaded yet, as a probe range of `raw`: while it stays all zero,
    /// the block stays incomplete. nil when the block looks complete. One
    /// pass, probing one byte per threshold on real data. A `.zeroRun` scan
    /// starts at `zeroRunStart`, the byte right after the track number: a
    /// missing block that begins in the relative timestamp, the flags or the
    /// lace header zeroes those bytes too (a run that long is never real
    /// data there either) — counted from the first frame byte, it would
    /// fall a few bytes short of the threshold.
    static func missingRegion(_ raw: UnsafeRawBufferPointer, laces: [Range<Int>], check: MissingDataCheck,
                              zeroRunStart: Int) -> Range<Int>? {
        switch check {
        case .none:
            return nil
        case .zeroRun(let threshold):
            guard let start = firstZeroRun(raw, from: zeroRunStart, to: raw.count, threshold: threshold) else { return nil }
            return start..<(start + threshold)
        case .nalUnits(let lengthSize):
            for lace in laces {
                if let region = nalMissingRegion(raw, frame: lace, lengthSize: lengthSize) { return region }
            }
            return nil
        }
    }

    /// Length-prefixed AVC / HEVC frame `raw[frame]`: the first zero run that
    /// can't be real data. A run of `nalTrailingZeroLimit` bytes always
    /// qualifies (a whole missing block). A shorter run of at least
    /// `nalZeroRunThreshold` bytes qualifies when it lies inside a NAL unit;
    /// one that ENDS a NAL unit (reaching the next length prefix, possibly
    /// into its leading zero bytes, or the end of the frame) is trailing
    /// stuffing. When the length prefixes don't tile the frame (Annex B in
    /// disguise, damage), only a run that swallowed the broken prefix counts.
    static func nalMissingRegion(_ raw: UnsafeRawBufferPointer, frame: Range<Int>, lengthSize: Int) -> Range<Int>? {
        var from = frame.lowerBound
        var walk: NALWalk?
        while let start = firstZeroRun(raw, from: from, to: frame.upperBound, threshold: nalZeroRunThreshold) {
            var end = start + nalZeroRunThreshold
            while end < frame.upperBound && raw[end] == 0 && end - start < nalTrailingZeroLimit { end += 1 }
            let run = start..<end
            if run.count >= nalTrailingZeroLimit { return run }
            // NAL boundaries are only needed for the (rare) suspicious frame.
            let units = walk ?? nalWalk(raw, frame: frame, lengthSize: lengthSize)
            walk = units
            switch units {
            case .units(let prefixes):
                if !endsNALUnit(run, prefixes: prefixes, frameEnd: frame.upperBound, lengthSize: lengthSize) { return run }
            case .broken(let position):
                if position >= run.lowerBound && position <= run.upperBound { return run }
            }
            from = end
        }
        return nil
    }

    enum NALWalk: Equatable {
        /// Offsets of every length prefix; the units tile the frame exactly.
        case units([Int])
        /// The prefix at this offset is zero, truncated or overruns the frame.
        case broken(at: Int)
    }

    /// Walks the length prefixes of an AVC / HEVC frame `raw[frame]`.
    static func nalWalk(_ raw: UnsafeRawBufferPointer, frame: Range<Int>, lengthSize: Int) -> NALWalk {
        let size = min(max(lengthSize, 1), 4)
        var prefixes: [Int] = []
        var pos = frame.lowerBound
        while pos < frame.upperBound {
            guard frame.upperBound - pos >= size else { return .broken(at: pos) }
            var length = 0
            for i in 0..<size { length = length << 8 | Int(raw[pos + i]) }
            guard length > 0, length <= frame.upperBound - pos - size else { return .broken(at: pos) }
            prefixes.append(pos)
            pos += size + length
        }
        return .units(prefixes)
    }

    /// True when the zero run ends a NAL unit: it reaches the end of the
    /// frame, or a length prefix (running into its leading zero bytes).
    static func endsNALUnit(_ run: Range<Int>, prefixes: [Int], frameEnd: Int, lengthSize: Int) -> Bool {
        if run.upperBound == frameEnd { return true }
        // Last prefix starting at or before the first byte after the run.
        var low = 0, high = prefixes.count
        while low < high {
            let mid = (low + high) / 2
            if prefixes[mid] <= run.upperBound { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return false }
        let prefix = prefixes[low - 1]
        return prefix > run.lowerBound && run.upperBound < prefix + lengthSize
    }

    /// True when `region` is still entirely zero (or not available yet).
    private func isStillZero(_ offset: UInt64, length: Int) -> Bool {
        let bytes = reader.peek(at: offset, maxCount: max(1, length))
        if bytes.isEmpty { return true }
        return bytes.withUnsafeBytes { raw in
            var i = 0
            while i < raw.count { if raw[i] != 0 { return false }; i += 1 }
            return true
        }
    }

    /// The region that blocked the last call still blocks the cluster.
    private func isStillBlocked(_ region: ZeroRegion) -> Bool {
        guard isStillZero(region.offset, length: region.length) else { return false }
        if let following = region.following { return isStillZero(following, length: 1) }
        return true
    }

    /// The byte right after a cluster / header element is 0x00 (not
    /// downloaded / not written). Past the end of the available data it is
    /// not downloaded yet either, unless the file is known to be complete:
    /// a zero tail reaching EOF may be the end of a block still to come
    /// (the last block of a multi-file torrent's file can be < 16 KiB).
    private func nextByteIsZero(at offset: UInt64) -> Bool {
        guard let byte = reader.peek(at: offset, maxCount: 1).first else { return !assumeFullyDownloaded }
        return byte == 0
    }

    /// Where a `.zero` header has its first 0x00 byte (the ID's first byte,
    /// a later ID byte, or the size's lead byte): the point to probe.
    private func zeroByteInHeader(at position: UInt64) -> UInt64 {
        let bytes = reader.peek(at: position, maxCount: 12)
        guard let index = bytes.firstIndex(of: 0) else { return position }
        return position + UInt64(index - bytes.startIndex)
    }

    /// Same, for a header held in memory.
    static func zeroByteInHeader(_ raw: UnsafeRawBufferPointer, at position: Int) -> Int {
        var index = position
        let end = min(raw.count, position + 12)
        while index < end {
            if raw[index] == 0 { return index }
            index += 1
        }
        return position
    }

    /// Offset of the first non-zero byte at or after `offset`, before
    /// `limit` (or the end of the data), scanning at most 64 MiB.
    private func firstNonZero(from offset: UInt64, limit: UInt64?) -> UInt64? {
        var position = offset
        let end = min(limit ?? UInt64.max, reader.fileLength(), offset + 64 * 1024 * 1024)
        while position < end {
            let chunk = reader.peek(at: position, maxCount: Int(min(UInt64(1 << 20), end - position)))
            if chunk.isEmpty { return nil }
            if let index = chunk.firstIndex(where: { $0 != 0 }) {
                return position + UInt64(index - chunk.startIndex)
            }
            position += UInt64(chunk.count)
        }
        return nil
    }

    // MARK: - Keyframe index (Cues)

    /// Outcome of `loadCueIndex`.
    enum CueIndex: Equatable {
        /// Block timestamps (TimestampScale ticks, as `MKVFrame.timestamp`)
        /// of the track's indexed keyframes, strictly increasing.
        case available([Int64])
        /// Not downloaded yet (the element, its body or a SeekHead leading
        /// to it reads as zeros / lies past the data): try again later.
        /// `readBody`: the attempt read a whole body (costly to repeat).
        case notYet(readBody: Bool)
        /// No usable index: no Cues element, a malformed one, or no cue
        /// point for the track. Not worth retrying.
        case unavailable(String)
    }

    /// The keyframe index of track `trackNumber` from the Cues element (its
    /// position comes from the SeekHead, a SeekHead it points to, or the
    /// top-level walk before the first Cluster). Re-callable, cheap while
    /// the element's header isn't downloaded (12 bytes read). Strict: the
    /// whole body must be valid EBML — a 0x00 byte where an element header
    /// must start, or a body whose last byte and the byte after it are
    /// zero (the download frontier), is a region not downloaded yet; any
    /// other inconsistency (an unexpected element, CueTimes going backward,
    /// a CuePoint without CueTime) makes the index unusable. Only cue points
    /// whose CueClusterPosition lies inside the file count — inside the
    /// Segment while the file is downloading: a file that grows as it
    /// downloads (not preallocated) hasn't reached those clusters yet. The
    /// reader's cursor is not moved.
    func loadCueIndex(trackNumber: UInt64) -> CueIndex {
        if cuesPosition == nil {
            // mkvmerge lists the Cues in a second SeekHead (at the end) when
            // the first one had no room left.
            while let seekHead = pendingSeekHeads.first {
                let header = reader.header(at: seekHead)
                guard case let .element(id, size, headerLength) = header else {
                    if case .malformed = header { pendingSeekHeads.removeFirst(); continue }
                    if assumeFullyDownloaded { pendingSeekHeads.removeFirst(); continue }
                    return .notYet(readBody: false)
                }
                guard id == ID.seekHead, size != UInt64.max, size <= Self.maxSeekHeadSize else {
                    pendingSeekHeads.removeFirst()
                    continue
                }
                guard let body = headerBody(at: seekHead + UInt64(headerLength), size: size) else {
                    if assumeFullyDownloaded { pendingSeekHeads.removeFirst(); continue }
                    return .notYet(readBody: true)
                }
                pendingSeekHeads.removeFirst()
                noteSeekEntries(body, at: seekHead)
                if cuesPosition != nil { break }
            }
        }
        guard let position = cuesPosition else { return .unavailable("no Cues element") }
        let header = reader.header(at: position)
        guard case let .element(id, size, headerLength) = header else {
            if case .malformed = header { return .unavailable("malformed Cues header") }
            return assumeFullyDownloaded ? .unavailable("Cues header missing") : .notYet(readBody: false)
        }
        guard id == ID.cues else {
            return .unavailable(String(format: "the Cues position holds element 0x%X", id))
        }
        guard size != UInt64.max, size > 0, size <= Self.maxCuesSize else {
            return .unavailable("Cues size \(size == UInt64.max ? "unknown" : String(size))")
        }
        let bodyStart = position + UInt64(headerLength)
        guard let body = reader.bytes(at: bodyStart, count: Int(size)) else {
            return assumeFullyDownloaded ? .unavailable("Cues truncated") : .notYet(readBody: false)
        }
        if !assumeFullyDownloaded, body.last == 0, nextByteIsZero(at: bodyStart + size) {
            return .notYet(readBody: true)
        }
        let fileLength = reader.fileLength()
        let clusterLimit = assumeFullyDownloaded ? fileLength : max(fileLength, segmentDataEnd ?? 0)
        var times: [Int64] = []
        var previous: UInt64?
        var failure: CueIndex?
        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            func fail(_ reason: String) { if failure == nil { failure = .unavailable(reason) } }
            /// Children of a master body, strictly: false (and `failure`) on a
            /// zero / truncated / malformed header or an overrun.
            func walk(_ range: Range<Int>, _ visit: (UInt32, Range<Int>) -> Void) -> Bool {
                var pos = range.lowerBound
                while pos < range.upperBound {
                    let child = EBML.header(in: UnsafeRawBufferPointer(rebasing: raw[pos..<range.upperBound]), at: 0)
                    guard case let .element(id, size, headerLength) = child else {
                        if case .zero = child, !assumeFullyDownloaded {
                            if failure == nil { failure = .notYet(readBody: true) }
                        } else {
                            fail("malformed Cues element")
                        }
                        return false
                    }
                    let start = pos + headerLength
                    guard size != UInt64.max, size <= UInt64(range.upperBound - start) else {
                        fail("malformed Cues element")
                        return false
                    }
                    visit(id, start..<(start + Int(size)))
                    pos = start + Int(size)
                }
                return true
            }
            _ = walk(0..<raw.count) { id, pointBody in
                guard failure == nil else { return }
                switch id {
                case ID.void, ID.crc32:
                    return
                case ID.cuePoint:
                    break
                default:
                    fail(String(format: "element 0x%X in Cues", id))
                    return
                }
                var time: UInt64?
                var indexed = false
                let complete = walk(pointBody) { field, fieldBody in
                    guard failure == nil else { return }
                    switch field {
                    case ID.cueTime:
                        guard (1...8).contains(fieldBody.count) else { return fail("CueTime size \(fieldBody.count)") }
                        time = EBML.uint(raw, fieldBody)
                    case ID.cueTrackPositions:
                        var track: UInt64?
                        var cluster: UInt64?
                        _ = walk(fieldBody) { positionField, valueBody in
                            guard (1...8).contains(valueBody.count) else { return }
                            if positionField == ID.cueTrack { track = EBML.uint(raw, valueBody) }
                            if positionField == ID.cueClusterPosition { cluster = EBML.uint(raw, valueBody) }
                        }
                        if track == trackNumber, let offset = cluster {
                            let (absolute, overflow) = segmentDataStart.addingReportingOverflow(offset)
                            if !overflow, absolute < clusterLimit { indexed = true }
                        }
                    default:
                        break
                    }
                }
                guard complete, failure == nil else { return }
                guard let value = time else { return fail("CuePoint without CueTime") }
                if let last = previous, value < last { return fail("CueTime going backward (\(value) after \(last))") }
                previous = value
                let ticks = Int64(clamping: value)
                if indexed, times.last != ticks { times.append(ticks) }
            }
        }
        if let failure = failure { return failure }
        guard !times.isEmpty else { return .unavailable("no cue point for track \(trackNumber)") }
        return .available(times)
    }

    // MARK: - Clusters

    /// Reads the next complete cluster's frames, in file order. Returns nil
    /// when no full cluster is available yet (EOF, still downloading, or the
    /// end of the segment); the next call retries from the same place. May
    /// return an empty array (empty cluster, filtered tracks, skipped
    /// damage): call again.
    func readNextCluster() -> [MKVFrame]? {
        if let probe = blockedProbe {
            if !assumeFullyDownloaded, probe.anchor == reader.offset, isStillBlocked(probe.region) { return nil }
            blockedProbe = nil
        }
        while true {
            if let from = resyncFrom {
                switch resync(from: from) {
                case .found(let position):
                    resyncFrom = nil
                    lastClusterEnd = nil
                    reader.seek(to: position)
                case .blocked:
                    return nil
                case .progressed:
                    return []
                }
            }

            let start = reader.offset
            switch reader.header(at: start) {
            case .truncated:
                return nil
            case .zero:
                if assumeFullyDownloaded {
                    resyncFrom = start
                    continue
                }
                blockedProbe = ZeroProbe(anchor: start, region: ZeroRegion(offset: zeroByteInHeader(at: start), length: 1))
                return nil
            case .malformed:
                resyncFrom = start + 1
                continue
            case let .element(id, size, headerLength):
                let bodyStart = start + UInt64(headerLength)
                if id == ID.cluster {
                    let outcome: ClusterOutcome
                    if size == UInt64.max || size > inMemoryClusterLimit {
                        outcome = readClusterChildByChild(start: start, bodyStart: bodyStart,
                                                          declaredEnd: size == UInt64.max ? nil : bodyStart + size,
                                                          inheritedTimestamp: nil)
                    } else {
                        outcome = readClusterInMemory(bodyStart: bodyStart, size: size)
                    }
                    return finish(outcome, start: start)
                }
                if id == ID.simpleBlock || id == ID.blockGroup || id == ID.clusterTimestamp, start == lastClusterEnd {
                    // Blocks right after a cluster: it was cut short (wrong
                    // size, or unknown size at the end of a growing file).
                    let outcome = readClusterChildByChild(start: start, bodyStart: start, declaredEnd: nil,
                                                          inheritedTimestamp: lastClusterTimestamp)
                    return finish(outcome, start: start)
                }
                if id == ID.ebml || id == ID.segment {
                    // A chained segment / concatenated file: this stream ends here.
                    if assumeFullyDownloaded { reader.seek(to: max(start, reader.fileLength())) }
                    return nil
                }
                if Self.isTopLevelID(id) || Self.isClusterChildID(id) {
                    // Cues, Tags, Attachments (multi-MB fonts)…: skipped by
                    // size without reading their body.
                    guard size != UInt64.max else {
                        resyncFrom = start + 1
                        continue
                    }
                    if id == ID.cues, cuesPosition == nil { cuesPosition = start }
                    reader.seek(to: bodyStart + size)
                    // A Void / CRC-32 right after a cluster keeps the
                    // continuation possible; anything else ends it.
                    let keepsContinuation = start == lastClusterEnd && (id == ID.void || id == ID.crc32)
                    lastClusterEnd = keepsContinuation ? bodyStart + size : nil
                    continue
                }
                // Not a Matroska Level-1 element: damage, resynchronise.
                resyncFrom = start + 1
            }
        }
    }

    private func finish(_ outcome: ClusterOutcome, start: UInt64) -> [MKVFrame]? {
        switch outcome {
        case .complete(let frames):
            return frames
        case .incomplete(let region):
            reader.seek(to: start)
            if let region = region {
                blockedProbe = ZeroProbe(anchor: start, region: region)
            }
            return nil
        }
    }

    /// Known-size cluster: one read, then an in-memory walk of its children.
    private func readClusterInMemory(bodyStart: UInt64, size: UInt64) -> ClusterOutcome {
        guard let body = reader.bytes(at: bodyStart, count: Int(size)) else { return .incomplete(nil) }
        let declaredEnd = bodyStart + size
        return body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ClusterOutcome in
            var pos = 0
            var timestamp: Int64?
            var blocks: [(range: Range<Int>, simple: Bool)] = []
            var end = declaredEnd
            var checkTail = true

            scan: while pos < raw.count {
                switch EBML.header(in: raw, at: pos) {
                case .zero:
                    let zeroPos = Self.zeroByteInHeader(raw, at: pos)
                    if assumeFullyDownloaded {
                        // Real zero bytes: skip the gap if a child follows it.
                        let gap = Self.zeroRun(raw, around: zeroPos, cap: raw.count)
                        if gap.upperBound < raw.count,
                           case let .element(nextID, _, _) = EBML.header(in: raw, at: gap.upperBound),
                           Self.isClusterChildID(nextID) {
                            pos = gap.upperBound
                            continue scan
                        }
                        checkTail = false
                        break scan
                    }
                    // No element header holds a 0x00 byte: while the file is
                    // downloading, this is a region not written yet, whatever
                    // its length (a missing 16 KiB block, the unwritten part of
                    // one being written, the frontier, the short last block of
                    // a file). Wait; once complete, it's skipped as damage.
                    return .incomplete(ZeroRegion(offset: bodyStart + UInt64(zeroPos), length: 1))
                case .truncated, .malformed:
                    break scan
                case let .element(id, childSize, headerLength):
                    if Self.isTopLevelID(id) {
                        // The declared size overshoots: the cluster ends here.
                        end = bodyStart + UInt64(pos)
                        checkTail = false
                        break scan
                    }
                    let childStart = pos + headerLength
                    guard childSize != UInt64.max, childSize <= UInt64(raw.count - childStart) else { break scan }
                    let childEnd = childStart + Int(childSize)
                    switch id {
                    case ID.clusterTimestamp:
                        if timestamp == nil { timestamp = Int64(clamping: EBML.uint(raw, childStart..<childEnd)) }
                    case ID.simpleBlock:
                        blocks.append((childStart..<childEnd, true))
                    case ID.blockGroup:
                        blocks.append((childStart..<childEnd, false))
                    default:
                        break // Void, CRC-32, Position, PrevSize…
                    }
                    pos = childEnd
                }
            }

            // The cluster ends with zero bytes and so does what follows it (or
            // the data ends there): the download frontier may be inside the
            // last block (a zero tail too short for the run heuristics).
            // Wait until either side changes.
            if checkTail, !assumeFullyDownloaded, raw.count > 0, raw[raw.count - 1] == 0,
               nextByteIsZero(at: declaredEnd) {
                return .incomplete(ZeroRegion(offset: declaredEnd - 1, length: 1, following: declaredEnd))
            }

            var frames: [MKVFrame] = []
            if let clusterTimestamp = timestamp {
                frames.reserveCapacity(blocks.count)
                for block in blocks {
                    let blockRaw = UnsafeRawBufferPointer(rebasing: raw[block.range])
                    let outcome = processBlockElement(blockRaw, fileOffset: bodyStart + UInt64(block.range.lowerBound),
                                                      simple: block.simple, clusterTimestamp: clusterTimestamp,
                                                      into: &frames)
                    if case let .notDownloaded(offset, length) = outcome {
                        return .incomplete(ZeroRegion(offset: offset, length: length))
                    }
                }
            }
            reader.seek(to: end)
            lastClusterEnd = end
            if let clusterTimestamp = timestamp { lastClusterTimestamp = clusterTimestamp }
            return .complete(frames)
        }
    }

    /// Unknown-size (live / streamed) or oversized cluster: children are read
    /// one by one until the next Level-1 element, the declared end, or EOF.
    private func readClusterChildByChild(start: UInt64, bodyStart: UInt64, declaredEnd: UInt64?,
                                         inheritedTimestamp: Int64?) -> ClusterOutcome {
        var pos = bodyStart
        var ownTimestamp: Int64?
        var children: [(data: Data, offset: UInt64, simple: Bool)] = []
        var end = bodyStart
        var resyncAt: UInt64?
        var checkTail = true

        walk: while true {
            if let limit = declaredEnd, pos >= limit {
                end = limit
                break walk
            }
            switch reader.header(at: pos) {
            case .truncated:
                if declaredEnd == nil, pos >= reader.fileLength() {
                    // EOF at a child boundary ends an unknown-size cluster —
                    // unless, while downloading, its last byte is 0x00: the
                    // frontier may lie inside that last child (tail rule).
                    if !assumeFullyDownloaded, pos > bodyStart, reader.peek(at: pos - 1, maxCount: 1).first == 0 {
                        return .incomplete(ZeroRegion(offset: pos - 1, length: 1, following: pos))
                    }
                    end = pos
                    break walk
                }
                return .incomplete(nil)
            case .zero:
                if assumeFullyDownloaded {
                    // Real zero bytes: skip the gap when a child follows it;
                    // otherwise drop the rest of a sized cluster, or
                    // resynchronise after an unknown-size one.
                    if let next = firstNonZero(from: pos, limit: declaredEnd),
                       case let .element(nextID, _, _) = reader.header(at: next), Self.isClusterChildID(nextID) {
                        pos = next
                        continue walk
                    }
                    if let limit = declaredEnd { end = limit } else { end = pos; resyncAt = pos }
                    checkTail = false
                    break walk
                }
                // No element header holds a 0x00 byte: not downloaded yet,
                // whatever the length of the zero region (see the in-memory path).
                return .incomplete(ZeroRegion(offset: zeroByteInHeader(at: pos), length: 1))
            case .malformed:
                if let limit = declaredEnd { end = limit } else { end = pos; resyncAt = pos + 1 }
                checkTail = false
                break walk
            case let .element(id, size, headerLength):
                if Self.isTopLevelID(id) {
                    end = pos // reader stays AT the next Level-1 element
                    checkTail = false
                    break walk
                }
                guard size != UInt64.max, size <= Self.maxBlockSize else {
                    if let limit = declaredEnd { end = limit } else { end = pos; resyncAt = pos + 1 }
                    checkTail = false
                    break walk
                }
                let childStart = pos + UInt64(headerLength)
                let childEnd = childStart + size
                if let limit = declaredEnd, childEnd > limit {
                    end = limit // malformed child: drop the rest of the cluster
                    break walk
                }
                if id == ID.clusterTimestamp || id == ID.simpleBlock || id == ID.blockGroup {
                    guard let data = reader.bytes(at: childStart, count: Int(size)) else { return .incomplete(nil) }
                    if id == ID.clusterTimestamp {
                        if ownTimestamp == nil { ownTimestamp = Int64(clamping: EBML.uint(data)) }
                    } else {
                        children.append((data, childStart, id == ID.simpleBlock))
                    }
                }
                // Other children (Void, CRC-32…) are skipped without reading.
                pos = childEnd
            }
        }

        // Same tail rule as in-memory clusters, for a size-bounded cluster.
        if checkTail, let limit = declaredEnd, end == limit, !assumeFullyDownloaded, limit > bodyStart,
           reader.peek(at: limit - 1, maxCount: 1).first == 0, nextByteIsZero(at: limit) {
            return .incomplete(ZeroRegion(offset: limit - 1, length: 1, following: limit))
        }

        var frames: [MKVFrame] = []
        let timestamp = ownTimestamp ?? inheritedTimestamp
        if let clusterTimestamp = timestamp {
            for child in children {
                let outcome = child.data.withUnsafeBytes { raw in
                    processBlockElement(raw, fileOffset: child.offset, simple: child.simple,
                                        clusterTimestamp: clusterTimestamp, into: &frames)
                }
                if case let .notDownloaded(offset, length) = outcome {
                    return .incomplete(ZeroRegion(offset: offset, length: length))
                }
            }
        }
        reader.seek(to: end)
        if let resyncAt = resyncAt {
            resyncFrom = resyncAt
            lastClusterEnd = nil
        } else {
            lastClusterEnd = end
            if let clusterTimestamp = timestamp { lastClusterTimestamp = clusterTimestamp }
        }
        return .complete(frames)
    }

    // MARK: - Resynchronisation

    /// Scans forward from `from` for the next plausible Cluster (its ID, a
    /// valid size, then a cluster child). Never skips a region that is still
    /// zero-filled (not downloaded) unless `assumeFullyDownloaded`.
    private func resync(from: UInt64) -> ResyncOutcome {
        let chunkSize = 1 << 20
        let overlap = Self.zeroRunThreshold
        var position = from
        var scanned = 0
        while scanned < Self.resyncScanBudget {
            let chunk = reader.peek(at: position, maxCount: chunkSize)
            guard chunk.count >= 4 else {
                resyncFrom = position
                if assumeFullyDownloaded, position >= reader.fileLength() {
                    reader.seek(to: max(reader.offset, reader.fileLength()))
                }
                return .blocked
            }
            var candidate: Int?
            var zeroAt: Int?
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                zeroAt = assumeFullyDownloaded ? nil
                    : Self.firstZeroRun(raw, from: 0, to: raw.count, threshold: Self.zeroRunThreshold)
                let limit = zeroAt ?? raw.count
                var i = 0
                while i + 4 <= limit {
                    if raw[i] == 0x1F, raw[i + 1] == 0x43, raw[i + 2] == 0xB6, raw[i + 3] == 0x75 {
                        candidate = i
                        return
                    }
                    i += 1
                }
            }
            if let candidate = candidate {
                let clusterStart = position + UInt64(candidate)
                switch validateCluster(at: clusterStart) {
                case .valid:
                    return .found(clusterStart)
                case .pending(let zeroAt):
                    // Its first child isn't downloaded yet: wait right here.
                    resyncFrom = clusterStart
                    blockedProbe = ZeroProbe(anchor: reader.offset, region: ZeroRegion(offset: zeroAt, length: 1))
                    return .blocked
                case .invalid:
                    position = clusterStart + 1
                    scanned += candidate + 1
                    continue
                }
            }
            if let zeroAt = zeroAt {
                // Missing pieces ahead: resume just before them once filled.
                resyncFrom = position + UInt64(max(0, zeroAt - 3))
                blockedProbe = ZeroProbe(anchor: reader.offset,
                                         region: ZeroRegion(offset: position + UInt64(zeroAt), length: Self.zeroRunThreshold))
                return .blocked
            }
            // Keep an overlap so neither a split Cluster ID nor a split
            // zero run is missed at the chunk boundary.
            let advance = chunk.count > overlap + 4 ? chunk.count - overlap : max(1, chunk.count - 3)
            if chunk.count < chunkSize, advance < chunk.count {
                // End of the available data: wait for more.
                resyncFrom = position + UInt64(max(0, chunk.count - 3))
                if assumeFullyDownloaded { reader.seek(to: max(reader.offset, reader.fileLength())) }
                return .blocked
            }
            position += UInt64(advance)
            scanned += advance
        }
        resyncFrom = position
        return .progressed
    }

    private enum ClusterCandidate {
        case valid
        case invalid
        /// Its header or first child isn't downloaded yet (zero byte at the offset).
        case pending(UInt64)
    }

    /// A Cluster ID found by the resync scan is accepted when a plausible
    /// size and a cluster child follow it.
    private func validateCluster(at offset: UInt64) -> ClusterCandidate {
        let header = reader.header(at: offset)
        if case .zero = header, !assumeFullyDownloaded { return .pending(zeroByteInHeader(at: offset)) }
        guard case let .element(id, size, headerLength) = header, id == ID.cluster else { return .invalid }
        let childOffset = offset + UInt64(headerLength)
        switch reader.header(at: childOffset) {
        case let .element(childID, childSize, childHeaderLength):
            guard Self.isClusterChildID(childID), childSize != UInt64.max else { return .invalid }
            if size != UInt64.max, childSize > size || UInt64(childHeaderLength) + childSize > size { return .invalid }
            return .valid
        case .zero:
            return assumeFullyDownloaded ? .invalid : .pending(zeroByteInHeader(at: childOffset))
        case .truncated:
            // End of the available data: wait for more (a growing file).
            return assumeFullyDownloaded ? .invalid : .pending(childOffset)
        case .malformed:
            return .invalid
        }
    }

    // MARK: - Blocks

    /// SimpleBlock body, or BlockGroup body (Block + BlockDuration +
    /// ReferenceBlock + BlockAdditions).
    private func processBlockElement(_ raw: UnsafeRawBufferPointer, fileOffset: UInt64, simple: Bool,
                                     clusterTimestamp: Int64, into frames: inout [MKVFrame]) -> BlockOutcome {
        if simple {
            return processBlock(raw, fileOffset: fileOffset, simple: true, hasReference: false,
                                duration: nil, additions: [:], clusterTimestamp: clusterTimestamp, into: &frames)
        }
        var blockRange: Range<Int>?
        var hasReference = false
        var duration: Int64?
        var additions: [UInt64: Data] = [:]
        var pos = 0
        while pos < raw.count {
            let header = EBML.header(in: raw, at: pos)
            if case .zero = header, !assumeFullyDownloaded {
                // A zeroed child (e.g. its ReferenceBlock) would silently turn
                // the frame into a keyframe: treat it as not downloaded.
                return .notDownloaded(fileOffset + UInt64(Self.zeroByteInHeader(raw, at: pos)), 1)
            }
            guard case let .element(id, size, headerLength) = header, size != UInt64.max,
                  size <= UInt64(raw.count - pos - headerLength) else { break }
            let range = (pos + headerLength)..<(pos + headerLength + Int(size))
            pos = range.upperBound
            switch id {
            case ID.block:
                if blockRange == nil { blockRange = range }
            case ID.referenceBlock:
                hasReference = true
            case ID.blockDuration:
                duration = Int64(clamping: EBML.uint(raw, range))
            case ID.blockAdditions:
                let additionsRaw = UnsafeRawBufferPointer(rebasing: raw[range])
                EBML.forEachChild(in: additionsRaw) { moreID, moreRange in
                    guard moreID == ID.blockMore else { return }
                    let moreRaw = UnsafeRawBufferPointer(rebasing: additionsRaw[moreRange])
                    var addID: UInt64 = 1
                    var payload: Data?
                    EBML.forEachChild(in: moreRaw) { fieldID, fieldRange in
                        if fieldID == ID.blockAddID {
                            addID = fieldRange.isEmpty ? 1 : EBML.uint(moreRaw, fieldRange)
                        } else if fieldID == ID.blockAdditional {
                            payload = Self.copy(moreRaw, fieldRange)
                        }
                    }
                    if let payload = payload { additions[addID] = payload }
                }
            default:
                break // ReferencePriority, CodecState, DiscardPadding, Void…
            }
        }
        guard let range = blockRange else { return .done }
        return processBlock(UnsafeRawBufferPointer(rebasing: raw[range]),
                            fileOffset: fileOffset + UInt64(range.lowerBound), simple: false,
                            hasReference: hasReference, duration: duration, additions: additions,
                            clusterTimestamp: clusterTimestamp, into: &frames)
    }

    /// Block layout: track vint, s16 relative timestamp, flags byte, optional
    /// lacing table, then frame data. Handles no/Xiph/fixed/EBML lacing.
    private func processBlock(_ raw: UnsafeRawBufferPointer, fileOffset: UInt64, simple: Bool, hasReference: Bool,
                              duration: Int64?, additions: [UInt64: Data], clusterTimestamp: Int64,
                              into frames: inout [MKVFrame]) -> BlockOutcome {
        // A track-number VINT never starts with 0x00: while downloading, a
        // zero there is the start of a region not written yet — a missing
        // block that begins exactly at the block body, or inside its size
        // field (the size then reads too small and the cluster scan stops in
        // the frame's data). Checked before anything else (track filter
        // included): dropping it would lose the frame, or the rest of the
        // cluster, for good. An empty block waits too while the byte after
        // it is still zero; a genuinely empty block followed by real data is
        // dropped like any damage. Once complete, both are dropped below.
        if !assumeFullyDownloaded {
            if let lead = raw.first, lead == 0 { return .notDownloaded(fileOffset, 1) }
            if raw.isEmpty, nextByteIsZero(at: fileOffset) { return .notDownloaded(fileOffset, 1) }
        }
        guard let (trackNumber, trackLength) = EBML.vint(in: raw, at: 0), trackLength <= 8,
              raw.count >= trackLength + 3,
              let runtime = runtimeByNumber[trackNumber] else { return .done }
        if let filter = trackFilter, !filter.contains(trackNumber) { return .done }

        let relative = Int16(bitPattern: UInt16(raw[trackLength]) << 8 | UInt16(raw[trackLength + 1]))
        let flags = raw[trackLength + 2]
        let keyframe = simple ? (flags & 0x80) != 0 : !hasReference
        let lacing = (flags >> 1) & 0x03
        guard let laces = Self.laceRanges(raw, from: trackLength + 3, lacing: lacing) else {
            // Lacing that doesn't add up because the block still holds a
            // region not written yet: wait (see `undecodableLacingHole`).
            // Otherwise — or once complete — inconsistent lacing is damage:
            // drop the block.
            if !assumeFullyDownloaded,
               let hole = Self.undecodableLacingHole(raw, trackLength: trackLength, lacing: lacing,
                                                     check: runtime.missingDataCheck) {
                return .notDownloaded(fileOffset + UInt64(hole.lowerBound), hole.count)
            }
            return .done
        }
        // Zero-filled regions of a preallocated file in the block, codec-aware
        // (AVC / HEVC: 64-byte runs inside a NAL unit; other compressed
        // video, native compressed audio, text subtitles, zlib frames: 16 KiB;
        // anything else: 64 KiB; PCM exempt), scanned from the byte after the
        // track number (see `missingRegion`).
        if !assumeFullyDownloaded,
           let hole = Self.missingRegion(raw, laces: laces, check: runtime.missingDataCheck, zeroRunStart: trackLength) {
            return .notDownloaded(fileOffset + UInt64(hole.lowerBound), hole.count)
        }

        let blockTimestamp = Self.saturatingAdd(clusterTimestamp, Int64(relative))
        let count = laces.count
        for (index, lace) in laces.enumerated() {
            guard let data = decodeFrame(raw, lace, runtime), !data.isEmpty else { continue }
            let offset = index == 0 ? 0 : laceOffset(index, runtime.defaultDurationNs)
            var frameDuration: Int64?
            if let duration = duration {
                if count == 1 || runtime.defaultDurationNs == 0 {
                    frameDuration = duration
                } else if index < count - 1 {
                    frameDuration = laceOffset(index + 1, runtime.defaultDurationNs) - offset
                } else {
                    let remaining = Self.saturatingAdd(duration, -offset)
                    frameDuration = remaining > 0 ? remaining : max(0, laceOffset(1, runtime.defaultDurationNs))
                }
            }
            frames.append(MKVFrame(trackNumber: trackNumber,
                                   timestamp: Self.saturatingAdd(blockTimestamp, offset),
                                   keyframe: keyframe, data: data,
                                   duration: frameDuration, additions: additions))
        }
        return .done
    }

    /// Ranges of the laced frames (relative to the block), or nil when the
    /// lacing is inconsistent with the block size. Like libavformat, the last
    /// frame of a Xiph / EBML lace must not be empty.
    static func laceRanges(_ raw: UnsafeRawBufferPointer, from start: Int, lacing: UInt8) -> [Range<Int>]? {
        let end = raw.count
        var pos = start
        guard pos <= end else { return nil }
        switch lacing {
        case 0:
            return [pos..<end]
        case 1: // Xiph
            guard pos < end else { return nil }
            let count = Int(raw[pos]) + 1
            pos += 1
            var sizes: [Int] = []
            sizes.reserveCapacity(count)
            var total = 0
            for _ in 0..<(count - 1) {
                var size = 0
                while true {
                    guard pos < end else { return nil }
                    let byte = Int(raw[pos])
                    pos += 1
                    size += byte
                    if byte != 255 { break }
                }
                sizes.append(size)
                total += size
                guard total < end else { return nil }
            }
            guard end - pos > total else { return nil }
            sizes.append(end - pos - total)
            return contiguousRanges(from: pos, sizes: sizes)
        case 3: // EBML
            guard pos < end else { return nil }
            let count = Int(raw[pos]) + 1
            pos += 1
            var sizes: [Int] = []
            sizes.reserveCapacity(count)
            var total = 0
            if count > 1 {
                guard let (first, length) = EBML.vint(in: raw, at: pos), first <= UInt64(end) else { return nil }
                pos += length
                var previous = Int(first)
                sizes.append(previous)
                total = previous
                for _ in 1..<(count - 1) {
                    guard let (rawDelta, deltaLength) = EBML.vint(in: raw, at: pos) else { return nil }
                    pos += deltaLength
                    // Signed VINT: subtract 2^(7n-1) - 1.
                    let bias = (Int64(1) << (7 * Int64(deltaLength) - 1)) - 1
                    let size = Int64(previous) + (Int64(rawDelta) - bias)
                    guard size >= 0, size <= Int64(end) else { return nil }
                    previous = Int(size)
                    sizes.append(previous)
                    total += previous
                    guard total < end else { return nil }
                }
            }
            guard end - pos > total else { return nil }
            sizes.append(end - pos - total)
            return contiguousRanges(from: pos, sizes: sizes)
        case 2: // fixed-size
            guard pos < end else { return nil }
            let count = Int(raw[pos]) + 1
            pos += 1
            let remaining = end - pos
            guard remaining % count == 0 else { return nil }
            let each = remaining / count
            return (0..<count).map { (pos + $0 * each)..<(pos + ($0 + 1) * each) }
        default:
            return nil
        }
    }

    /// Index of the LEAD byte of the first EBML lace size that is 0x00 — the
    /// sizes walked as `laceRanges` reads them, up to the first one it can't
    /// decode — or nil (not EBML lacing, or no such byte). A VINT never
    /// starts with 0x00, so that byte is a region of a preallocated file not
    /// written yet (or damage) and turns non-zero once written. No other
    /// zero of a lace header qualifies: a non-lead byte of a size (2560 =
    /// 4A 00), a Xiph size byte (255 = FF 00, an empty frame) or a frame
    /// count of 0 can be real data, still 0x00 after the fill.
    static func laceHeaderZero(_ raw: UnsafeRawBufferPointer, from start: Int, lacing: UInt8) -> Int? {
        let end = raw.count
        guard lacing == 3, start < end else { return nil }
        let count = Int(raw[start]) + 1
        var pos = start + 1
        guard count > 1 else { return nil }
        for _ in 0..<(count - 1) {
            guard pos < end else { return nil }
            if raw[pos] == 0 { return pos }
            guard let (_, length) = EBML.vint(in: raw, at: pos) else { return nil }
            pos += length
        }
        return nil
    }

    /// While downloading, the region a block whose lacing doesn't add up
    /// (`laceRanges` failed) waits for, as a probe range of `raw` — nil when
    /// the block is damage (dropped): an EBML lace size whose lead byte is
    /// 0x00 (`laceHeaderZero`), else a zero run that the track's rule
    /// (`check`; NAL units: a whole missing block) says can't be real data,
    /// from the byte after the track number — e.g. a missing block starting
    /// inside the last size, which zeroes only bytes that may be 0x00. Never
    /// a byte that can legitimately stay 0x00 (see `laceHeaderZero`): the
    /// probe would keep the cluster blocked after the fill, until the
    /// download completes. A run is probed over `check`'s whole threshold,
    /// one byte of which at least turns non-zero once written.
    static func undecodableLacingHole(_ raw: UnsafeRawBufferPointer, trackLength: Int, lacing: UInt8,
                                      check: MissingDataCheck) -> Range<Int>? {
        if let lead = laceHeaderZero(raw, from: trackLength + 3, lacing: lacing) { return lead..<(lead + 1) }
        let threshold: Int
        switch check {
        case .none: return nil
        case .zeroRun(let run): threshold = run
        case .nalUnits: threshold = nalTrailingZeroLimit
        }
        guard let start = firstZeroRun(raw, from: trackLength, to: raw.count, threshold: threshold) else { return nil }
        return start..<(start + threshold)
    }

    private static func contiguousRanges(from start: Int, sizes: [Int]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(sizes.count)
        var cursor = start
        for size in sizes {
            ranges.append(cursor..<(cursor + size))
            cursor += size
        }
        return ranges
    }

    /// Timestamp offset (TimestampScale ticks, rounded) of the `index`-th
    /// laced frame: index × DefaultDuration. 0 without DefaultDuration.
    private func laceOffset(_ index: Int, _ defaultDurationNs: UInt64) -> Int64 {
        guard index > 0, defaultDurationNs > 0 else { return 0 }
        let ticks = (Double(index) * Double(defaultDurationNs) / Double(timestampScale)).rounded()
        return Self.clampedInt64(ticks)
    }

    private func decodeFrame(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ runtime: TrackRuntime) -> Data? {
        guard runtime.decodesFrames, !runtime.frameEncodings.isEmpty else { return Self.copy(raw, range) }
        var data: Data?
        for encoding in runtime.frameEncodings {
            switch encoding.algorithm {
            case .headerStripping:
                var output = Data(capacity: encoding.settings.count + (data?.count ?? range.count))
                output.append(encoding.settings)
                if let current = data {
                    output.append(current)
                } else if !range.isEmpty, let base = raw.baseAddress {
                    output.append(base.advanced(by: range.lowerBound).assumingMemoryBound(to: UInt8.self),
                                  count: range.count)
                }
                data = output
            case .zlib:
                let input = data ?? Self.copy(raw, range)
                guard let inflated = MatroskaZlib.inflate(input, maxOutputSize: Self.maxInflatedSize) else {
                    return nil // corrupt frame: dropped
                }
                data = inflated
            default:
                return Self.copy(raw, range)
            }
        }
        return data ?? Self.copy(raw, range)
    }

    // MARK: - Small helpers

    static func copy(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> Data {
        guard !range.isEmpty, let base = raw.baseAddress else { return Data() }
        return Data(bytes: base.advanced(by: range.lowerBound), count: range.count)
    }

    static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return sum }
        return b > 0 ? Int64.max : Int64.min
    }

    static func clampedInt64(_ value: Double) -> Int64 {
        guard value.isFinite else { return 0 }
        if value >= 9.2e18 { return Int64.max }
        if value <= -9.2e18 { return Int64.min }
        return Int64(value)
    }
}

// MARK: - zlib (Matroska ContentCompAlgo 0)

/// Inflates zlib-wrapped DEFLATE (RFC 1950: 2-byte header, raw DEFLATE,
/// Adler-32 trailer) with Apple's Compression framework, whose
/// `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951).
enum MatroskaZlib {
    static func inflate(_ input: Data, maxOutputSize: Int) -> Data? {
        // Header (2) + smallest DEFLATE stream (2) + Adler-32 (4).
        guard input.count >= 8 else { return nil }
        return input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data? in
            let cmf = source[0], flg = source[1]
            // CM = 8 (deflate), window ≤ 32 KiB, FCHECK, no preset dictionary.
            guard cmf & 0x0F == 8, cmf >> 4 <= 7,
                  (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0, flg & 0x20 == 0,
                  let base = source.baseAddress else { return nil }

            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                return nil
            }
            defer { compression_stream_destroy(stream) }

            let chunkSize = max(16 * 1024, min(1 << 20, input.count * 4))
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { chunk.deallocate() }

            stream.pointee.src_ptr = base.advanced(by: 2).assumingMemoryBound(to: UInt8.self)
            stream.pointee.src_size = input.count - 2
            var output = Data()
            while true {
                stream.pointee.dst_ptr = chunk
                stream.pointee.dst_size = chunkSize
                let sourceBefore = stream.pointee.src_size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.pointee.dst_size
                if produced > 0 {
                    guard output.count + produced <= maxOutputSize else { return nil }
                    output.append(chunk, count: produced)
                }
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { return nil }
                // No progress at all: truncated / invalid stream.
                if produced == 0 && stream.pointee.src_size == sourceBefore { return nil }
            }
            // The stream is the whole frame: its last 4 bytes are the Adler-32
            // of the inflated data (big-endian).
            let trailer = source.count - 4
            let expected = UInt32(source[trailer]) << 24 | UInt32(source[trailer + 1]) << 16
                | UInt32(source[trailer + 2]) << 8 | UInt32(source[trailer + 3])
            guard adler32(output) == expected else { return nil }
            return output
        }
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var index = 0
            while index < raw.count {
                // 5552 = largest n with 255n(n+1)/2 + (n+1)(65520) < 2^32.
                let end = min(raw.count, index + 5552)
                while index < end {
                    a &+= UInt32(raw[index])
                    b &+= a
                    index += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        return b << 16 | a
    }
}
