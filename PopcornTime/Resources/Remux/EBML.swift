

import Foundation

// MARK: - Bit reader

/// MSB-first bit reader shared by every bitstream parser of the remux engine
/// ((E-)AC-3 BSI, HEVC/AVC SPS VUI, AV1 sequence header, FLAC/MP3/Opus frame
/// headers). Reading past the end yields zero bits and sets `overrun`.
struct BitReader {
    private let data: [UInt8]
    private(set) var bitPosition = 0
    private(set) var overrun = false

    init(_ data: [UInt8]) { self.data = data }
    init(_ data: Data) { self.data = [UInt8](data) }

    var bitsRemaining: Int { max(0, data.count * 8 - bitPosition) }
    var isAtEnd: Bool { bitsRemaining == 0 }

    /// Reads `count` bits (0…32), MSB first.
    mutating func read(_ count: Int) -> UInt32 {
        precondition(count >= 0 && count <= 32, "BitReader.read supports 0…32 bits")
        var value: UInt32 = 0
        for _ in 0..<count {
            value <<= 1
            let byte = bitPosition >> 3
            if byte < data.count {
                value |= UInt32((data[byte] >> (7 - UInt8(bitPosition & 7))) & 1)
            } else {
                overrun = true
            }
            bitPosition += 1
        }
        return value
    }

    /// Reads `count` bits (0…64), MSB first.
    mutating func read64(_ count: Int) -> UInt64 {
        precondition(count >= 0 && count <= 64)
        if count <= 32 { return UInt64(read(count)) }
        let high = UInt64(read(count - 32))
        let low = UInt64(read(32))
        return (high << 32) | low
    }

    mutating func readBool() -> Bool { read(1) == 1 }

    mutating func skip(_ count: Int) {
        guard count > 0 else { return }
        bitPosition += count
        if bitPosition > data.count * 8 { overrun = true }
    }

    mutating func byteAlign() {
        let rem = bitPosition & 7
        if rem != 0 { skip(8 - rem) }
    }

    /// Unsigned Exp-Golomb code, ue(v) (H.264 / HEVC).
    mutating func readUE() -> UInt32 {
        var leadingZeros = 0
        while !readBool() {
            leadingZeros += 1
            if leadingZeros > 31 || overrun { return 0 }
        }
        guard leadingZeros > 0 else { return 0 }
        let suffix = read64(leadingZeros)
        return UInt32(clamping: (UInt64(1) << UInt64(leadingZeros)) - 1 + suffix)
    }

    /// Signed Exp-Golomb code, se(v).
    mutating func readSE() -> Int32 {
        let k = readUE()
        if k & 1 == 1 { return Int32(clamping: (Int64(k) + 1) / 2) }
        return -Int32(clamping: Int64(k) / 2)
    }
}

// MARK: - EBML element helpers

/// Stateless EBML helpers for in-memory element bodies.
enum EBML {
    /// Length (1…8) of a VINT from its first byte; 0 for an invalid 0x00 byte.
    static func vintLength(_ firstByte: UInt8) -> Int {
        guard firstByte != 0 else { return 0 }
        return firstByte.leadingZeroBitCount + 1
    }

    /// Big-endian unsigned integer element payload.
    static func uint(_ data: Data) -> UInt64 {
        var v: UInt64 = 0
        for b in data.prefix(8) { v = (v << 8) | UInt64(b) }
        return v
    }

    /// Unsigned integer payload; an EMPTY element takes the schema default
    /// (RFC 8794 §6.3: "an Empty Element with a default value is that value").
    static func uint(_ data: Data, default defaultValue: UInt64) -> UInt64 {
        data.isEmpty ? defaultValue : uint(data)
    }

    /// Boolean-like unsigned integer flag (any non-zero value is true);
    /// an empty element takes `defaultValue`.
    static func flag(_ data: Data, default defaultValue: Bool) -> Bool {
        data.isEmpty ? defaultValue : uint(data) != 0
    }

    /// Big-endian two's-complement signed integer element payload.
    static func sint(_ data: Data) -> Int64 {
        guard !data.isEmpty else { return 0 }
        let bytes = [UInt8](data.prefix(8))
        var v: Int64 = (bytes[0] & 0x80) != 0 ? -1 : 0
        for b in bytes { v = (v << 8) | Int64(b) }
        return v
    }

    /// IEEE float element payload (4 or 8 bytes).
    static func float(_ data: Data) -> Double {
        if data.count == 4 { return Double(Float(bitPattern: UInt32(truncatingIfNeeded: uint(data)))) }
        if data.count == 8 { return Double(bitPattern: uint(data)) }
        return 0
    }

    /// Float payload validated for use as a physical quantity: nil when the
    /// element has an invalid length or holds NaN / ±infinity.
    static func finiteFloat(_ data: Data) -> Double? {
        guard data.isEmpty || data.count == 4 || data.count == 8 else { return nil }
        let value = float(data)
        return value.isFinite ? value : nil
    }

    /// String / UTF-8 element payload (trailing NULs stripped).
    static func string(_ data: Data) -> String {
        var bytes = [UInt8](data)
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads a VINT data size at `pos` in `bytes` (marker bit stripped).
    /// Returns nil when truncated; all-ones ("unknown") is reported as UInt64.max.
    static func readSize(_ bytes: [UInt8], at pos: Int) -> (value: UInt64, length: Int)? {
        guard pos >= 0, pos < bytes.count else { return nil }
        let length = vintLength(bytes[pos])
        guard length >= 1, length <= 8, pos + length <= bytes.count else { return nil }
        var value = UInt64(bytes[pos] & (0xFF >> UInt8(length)))
        for i in 1..<length { value = (value << 8) | UInt64(bytes[pos + i]) }
        let allOnes = (UInt64(1) << (7 * UInt64(length))) - 1
        return (value == allOnes ? UInt64.max : value, length)
    }

    /// Reads an element ID at `pos` (marker bit KEPT), 1…4 bytes.
    static func readID(_ bytes: [UInt8], at pos: Int) -> (id: UInt32, length: Int)? {
        guard pos >= 0, pos < bytes.count else { return nil }
        let length = vintLength(bytes[pos])
        guard length >= 1, length <= 4, pos + length <= bytes.count else { return nil }
        var id: UInt32 = 0
        for i in 0..<length { id = (id << 8) | UInt32(bytes[pos + i]) }
        return (id, length)
    }

    // MARK: Raw-buffer decoding (hot path, no copies)

    /// Outcome of decoding an element header (ID + data size) from memory.
    enum Header: Equatable {
        /// A well-formed header. `size` is `UInt64.max` for an unknown size.
        case element(id: UInt32, size: UInt64, headerLength: Int)
        /// The buffer ends inside the header.
        case truncated
        /// A VINT lead byte of the header is 0x00, or a byte of the ID is
        /// (no Matroska element ID contains a 0x00 byte). In a preallocated,
        /// still-downloading file it marks bytes that haven't been written
        /// yet — e.g. a piece boundary falling inside a Cluster ID.
        case zero
        /// Invalid ID / size encoding.
        case malformed
    }

    /// Element IDs whose VINT_DATA bits are all 0 or all 1 are reserved
    /// (RFC 8794 §5) and never appear in a valid stream.
    static func isReservedID(_ id: UInt32, length: Int) -> Bool {
        let valueBits = UInt32(7 * length)
        let mask: UInt32 = (UInt32(1) << valueBits) - 1
        let value = id & mask
        return value == 0 || value == mask
    }

    /// Decodes the element header at `pos` of `raw`.
    static func header(in raw: UnsafeRawBufferPointer, at pos: Int) -> Header {
        guard pos >= 0, pos < raw.count else { return .truncated }
        let first = raw[pos]
        if first == 0 { return .zero }
        let idLength = vintLength(first)
        guard idLength <= 4 else { return .malformed }
        guard pos + idLength <= raw.count else { return .truncated }
        var id = UInt32(first)
        for i in 1..<idLength {
            let byte = raw[pos + i]
            if byte == 0 { return .zero }
            id = (id << 8) | UInt32(byte)
        }
        if isReservedID(id, length: idLength) { return .malformed }
        let sizePos = pos + idLength
        guard sizePos < raw.count else { return .truncated }
        let sizeFirst = raw[sizePos]
        if sizeFirst == 0 { return .zero }
        let sizeLength = vintLength(sizeFirst)
        guard sizePos + sizeLength <= raw.count else { return .truncated }
        var value = UInt64(sizeFirst & (0xFF >> UInt8(sizeLength)))
        for i in 1..<sizeLength { value = (value << 8) | UInt64(raw[sizePos + i]) }
        let allOnes = (UInt64(1) << (7 * UInt64(sizeLength))) - 1
        return .element(id: id, size: value == allOnes ? UInt64.max : value, headerLength: idLength + sizeLength)
    }

    /// Raw VINT value at `pos` (marker bit stripped, all-ones NOT mapped to
    /// "unknown" — used for lace sizes). nil when invalid or truncated.
    static func vint(in raw: UnsafeRawBufferPointer, at pos: Int) -> (value: UInt64, length: Int)? {
        guard pos >= 0, pos < raw.count else { return nil }
        let length = vintLength(raw[pos])
        guard length >= 1, pos + length <= raw.count else { return nil }
        var value = UInt64(raw[pos] & (0xFF >> UInt8(length)))
        for i in 1..<length { value = (value << 8) | UInt64(raw[pos + i]) }
        return (value, length)
    }

    /// Big-endian unsigned integer from a raw slice (first 8 bytes at most).
    static func uint(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> UInt64 {
        var v: UInt64 = 0
        var i = range.lowerBound
        let end = min(range.upperBound, range.lowerBound + 8)
        while i < end { v = (v << 8) | UInt64(raw[i]); i += 1 }
        return v
    }

    /// Iterates the direct children of a master element body held in a raw
    /// buffer, yielding each child's body range (no copy). Stops silently at
    /// the first malformed / truncated / unknown-size child.
    static func forEachChild(in raw: UnsafeRawBufferPointer, _ visit: (_ id: UInt32, _ body: Range<Int>) -> Void) {
        var pos = 0
        while pos < raw.count {
            guard case let .element(id, size, headerLength) = header(in: raw, at: pos),
                  size != UInt64.max else { return }
            let start = pos + headerLength
            guard size <= UInt64(raw.count - start) else { return }
            let end = start + Int(size)
            visit(id, start..<end)
            pos = end
        }
    }

    /// Iterates the direct children of an in-memory master element body.
    /// Stops silently at the first malformed / truncated / unknown-size child.
    static func forEachChild(_ data: Data, _ visit: (UInt32, Data) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var pos = 0
            while pos < raw.count {
                guard case let .element(id, size, headerLength) = header(in: raw, at: pos),
                      size != UInt64.max else { return }
                let start = pos + headerLength
                guard size <= UInt64(raw.count - start) else { return }
                let end = start + Int(size)
                let lower = data.startIndex + start
                visit(id, data.subdata(in: lower..<(lower + Int(size))))
                pos = end
            }
        }
    }
}

// MARK: - File-backed EBML reader

/// Minimal EBML reader over a random-access (possibly still downloading)
/// file. Reads are bounded by `fileLength()` so a partially downloaded file
/// can be parsed as far as data exists.
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
        if count == 0 { return Data() }
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

    /// Exactly `count` bytes at absolute `position`, without moving the
    /// cursor; nil when they are not all available (yet).
    func bytes(at position: UInt64, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        let length = fileLength()
        guard position <= length, length - position >= UInt64(count) else { return nil }
        try? handle.seek(toOffset: position)
        guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    /// Up to `maxCount` bytes at absolute `position` (fewer near the end of
    /// the available data), without moving the cursor.
    func peek(at position: UInt64, maxCount: Int) -> Data {
        let length = fileLength()
        guard maxCount > 0, position < length else { return Data() }
        let count = Int(min(UInt64(maxCount), length - position))
        try? handle.seek(toOffset: position)
        return (try? handle.read(upToCount: count)) ?? Data()
    }

    /// Element header at absolute `position` (does not move the cursor).
    /// `.truncated` when the header isn't fully available.
    func header(at position: UInt64) -> EBML.Header {
        let bytes = peek(at: position, maxCount: 12)
        return bytes.withUnsafeBytes { EBML.header(in: $0, at: 0) }
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
        let allOnes = (UInt64(1) << (7 * UInt64(length))) - 1
        return value == allOnes ? UInt64.max : value
    }

    static func vintLength(_ firstByte: UInt8) -> Int { EBML.vintLength(firstByte) }
    static func uint(_ data: Data) -> UInt64 { EBML.uint(data) }
    static func float(_ data: Data) -> Double { EBML.float(data) }
}
