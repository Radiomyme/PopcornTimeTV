import Foundation

/// The OpenSubtitles hash of a video file ("moviehash"): what its
/// `/search/moviebytesize-N/moviehash-H` search takes to find the subtitles
/// made for, or linked to, that exact file.
///
/// hash = file size + every little-endian 64-bit word of the first 64 KiB +
/// every word of the last 64 KiB, modulo 2^64, written as 16 lowercase hex
/// digits (the reference implementations: OpenSubtitles' own, subliminal's
/// refiner). Only the two ends of the file are read, which suits a torrent:
/// the head comes first, and the streamer fetches the tail early (the MKV
/// keyframe index, the MP4 moov).
public enum OpenSubtitlesHash {

    /// Bytes read at each end.
    public static let chunkSize = 65_536

    /// The hash of a file of `fileSize` bytes from its first and last
    /// `chunkSize` bytes; nil when the file is smaller than two chunks (the
    /// reference implementations refuse those) or a chunk is short.
    public static func hash(fileSize: Int64, head: Data, tail: Data) -> String? {
        guard let headSum = sum(of: head), let tailSum = sum(of: tail) else { return nil }
        return hash(fileSize: fileSize, headSum: headSum, tailSum: tailSum)
    }

    /// The hash from the two sums (`sum(of:)`): the head's can be taken
    /// once it is on disk and kept, the tail's later — bounded storage may
    /// delete the head before the tail arrives.
    public static func hash(fileSize: Int64, headSum: UInt64, tailSum: UInt64) -> String? {
        guard fileSize >= Int64(2 * chunkSize) else { return nil }
        return format(UInt64(fileSize) &+ headSum &+ tailSum)
    }

    /// The wrapping sum of the little-endian 64-bit words of one end of the
    /// file, exactly `chunkSize` bytes; nil otherwise.
    public static func sum(of chunk: Data) -> UInt64? {
        guard chunk.count == chunkSize else { return nil }
        return chunk.withUnsafeBytes { raw -> UInt64 in
            var total: UInt64 = 0
            var offset = 0
            while offset < chunkSize {
                total &+= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                offset += 8
            }
            return total
        }
    }

    /// Where the tail chunk starts in a file of `fileSize` bytes.
    public static func tailOffset(fileSize: Int64) -> Int64 {
        max(0, fileSize - Int64(chunkSize))
    }

    /// Reads `chunkSize` bytes at `offset` of `file`; nil when the file
    /// can't be opened or holds fewer bytes there (a file still being
    /// written, smaller on disk than its final size).
    public static func readChunk(of file: URL, at offset: Int64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            guard let data = try handle.read(upToCount: chunkSize), data.count == chunkSize else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// The hash of a complete file on disk (`fileSize`: its size, read from
    /// the file when nil).
    public static func hash(ofFileAt file: URL, fileSize: Int64? = nil) -> String? {
        let size = fileSize ?? ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size >= Int64(2 * chunkSize),
              let head = readChunk(of: file, at: 0),
              let tail = readChunk(of: file, at: tailOffset(fileSize: size)) else { return nil }
        return hash(fileSize: size, head: head, tail: tail)
    }

    static func format(_ value: UInt64) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
