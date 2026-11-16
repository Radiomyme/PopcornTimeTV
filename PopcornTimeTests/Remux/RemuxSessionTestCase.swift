//
//  RemuxSessionTestCase.swift
//  PopcornTimeTests
//
//  What the remux session's tests share: the synthetic streams they convert (`RemuxTestStreams`),
//  a session opened on one of them and driven like `RemuxPlayback.tick` drives it, and the
//  SHA-256 of what it wrote. The temporary folders are removed after each test.
//

import XCTest
import Foundation
import CryptoKit

/// The streams of the sequential golden file (`Fixtures/Remux/sequential-golden.json`), which
/// the jump tests convert too: one per thing a jump has to get right.
enum RemuxTestStreams {
    static let all: [(name: String, stream: SyntheticMatroska)] = [
        ("h264-aac-no-index", make { $0.clusterCount = 60 }),
        ("h264-aac-cues-front", make { $0.cues = .front }),
        ("h264-aac-cues-back-sized-segment", make { $0.cues = .back; $0.segmentSizeKnown = true }),
        ("hevc-eac3-cues-front", make { $0.videoCodec = .hevc; $0.audioCodec = .eac3; $0.videoFrameBytes = 600; $0.cues = .front }),
        ("laced-aac-cues-back", make { $0.audioFramesPerBlock = 4; $0.cues = .back }),
        ("subtitles-cues-front", make { $0.hasTextSubtitles = true; $0.cues = .front }),
        ("unknown-size-clusters-cues-back", make { $0.unknownSizeClusters = true; $0.cues = .back }),
        // A 2.4 s GOP whose keyframes fall inside the clusters, one in two indexed, laced
        // E-AC-3 that declares its frame duration.
        ("sparse-cues-mid-cluster-keyframes", make {
            $0.isKeyframe = { index, _ in index % 60 == 0 }
            $0.cueStride = 2
            $0.cues = .front
            $0.audioCodec = .eac3
            $0.audioFramesPerBlock = 3
            $0.audioDeclaresFrameDuration = true
        }),
    ]

    /// 120 s of media (twenty 6 s segments with the default 1 s GOP), then `change`.
    static func make(_ change: (inout SyntheticMatroska) -> Void) -> SyntheticMatroska {
        var stream = SyntheticMatroska()
        stream.clusterCount = 120
        change(&stream)
        return stream
    }

    static func named(_ name: String) -> SyntheticMatroska {
        guard let found = all.first(where: { $0.name == name }) else { fatalError("no test stream named \(name)") }
        return found.stream
    }
}

class RemuxSessionTestCase: CheckedTestCase {

    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    struct Opened {
        let session: MKVToHLSRemuxSession
        /// The Matroska file the session reads, and the folder it writes to.
        let input: URL
        let output: URL
        let layout: SyntheticMatroska.Layout
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A new temporary folder holding `data` as synthetic.mkv, and the path of an output folder.
    func temporaryInput(_ data: Data, file: StaticString = #filePath, line: Int = #line) -> (input: URL, output: URL)? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopcornTimeTests-remux-\(UUID().uuidString)", isDirectory: true)
        let input = directory.appendingPathComponent("synthetic.mkv")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: input)
        } catch {
            check(false, "the synthetic stream is written", "\(error)", file: file, line: line)
            return nil
        }
        directories.append(directory)
        return (input, directory.appendingPathComponent("hls", isDirectory: true))
    }

    /// A prepared session on `stream`. `complete`: the input is a finished download (else a file
    /// still downloading: its zeros are pieces to come). `content`: what the file holds instead
    /// of the whole stream (a holed copy of it).
    /// `configure`: what a test sets on the session before `prepare`.
    func open(_ stream: SyntheticMatroska, complete: Bool = true, content: Data? = nil,
              configure: (MKVToHLSRemuxSession) -> Void = { _ in },
              file: StaticString = #filePath, line: Int = #line) -> Opened? {
        let layout = stream.layout()
        guard let files = temporaryInput(content ?? layout.data, file: file, line: line) else { return nil }
        guard let session = try? MKVToHLSRemuxSession(inputFile: files.input, outputDirectory: files.output) else {
            check(false, "the session opens", file: file, line: line)
            return nil
        }
        configure(session)
        if complete { session.markInputComplete() }
        var result = session.prepare()
        var tries = 0
        while result == .needMoreData, tries < 20 { result = session.prepare(); tries += 1 }
        check(result == .ready, "the synthetic stream is playable natively", "\(result)", file: file, line: line)
        return result == .ready ? Opened(session: session, input: files.input, output: files.output, layout: layout) : nil
    }

    /// Pumps until `count` more segments are written, or nothing more comes (three idle calls);
    /// returns how many were.
    @discardableResult
    func produce(_ session: MKVToHLSRemuxSession, _ count: Int) -> Int {
        var done = 0, idle = 0
        while done < count, idle < 3, session.writeFailure == nil {
            let written = session.pump(maxNewSegments: min(2, count - done))
            done += written
            idle = (written == 0 && !session.stoppedAtInputBudget) ? idle + 1 : 0
        }
        return done
    }

    /// Pumps like `RemuxPlayback.tick` until the input is exhausted (three idle calls) or the
    /// session stops; returns the number of `pump` calls.
    @discardableResult
    func drain(_ session: MKVToHLSRemuxSession, maxCalls: Int = 100_000) -> Int {
        var idle = 0, calls = 0
        while idle < 3, calls < maxCalls, session.writeFailure == nil {
            let written = session.pump(maxNewSegments: 2)
            calls += 1
            idle = (written == 0 && !session.stoppedAtInputBudget) ? idle + 1 : 0
        }
        return calls
    }

    /// The conversion in file order, as the app runs it: two segments (what `onReady` waits
    /// for), the playlists AVPlayer then fetches (which freezes their list), the rest, the end.
    func convertInOrder(_ opened: Opened) {
        produce(opened.session, 2)
        _ = opened.session.mediaPlaylist(named: "video.m3u8")
        drain(opened.session)
        opened.session.finish()
    }

    /// `data` as a preallocated file that holds only `kept`: zeros everywhere else, as a
    /// torrent file whose other pieces are still to come.
    static func holed(_ data: Data, keeping kept: [Range<Int>]) -> Data {
        var result = Data(count: data.count)
        for range in kept {
            let clamped = max(0, range.lowerBound)..<min(data.count, range.upperBound)
            guard !clamped.isEmpty else { continue }
            result.replaceSubrange(clamped, with: data.subdata(in: clamped))
        }
        return result
    }

    /// Writes bytes `range` of `data` at their place in the file: pieces that arrive.
    func fill(_ file: URL, from data: Data, _ range: Range<Int>, fileID: StaticString = #filePath, line: Int = #line) {
        let clamped = max(0, range.lowerBound)..<min(data.count, range.upperBound)
        guard !clamped.isEmpty else { return }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(clamped.lowerBound))
            try handle.write(contentsOf: data.subdata(in: clamped))
        } catch {
            check(false, "bytes \(clamped) are written to the input file", "\(error)", file: fileID, line: line)
        }
    }

    /// Every file of the output folder, by name.
    func files(in directory: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            result[name] = try? Data(contentsOf: directory.appendingPathComponent(name))
        }
        return result
    }

    /// The names of `files` that are media of segment `index` (vseg, a{i}seg, s{j}seg).
    static func names(ofSegment index: Int, in files: [String: Data]) -> [String] {
        files.keys.filter { name in
            guard let range = name.range(of: "seg"), let dot = name.lastIndex(of: "."), range.upperBound <= dot else { return false }
            return Int(name[range.upperBound..<dot]) == index
        }.sorted()
    }

    /// The playlists of every rendition, as served.
    func playlists(_ session: MKVToHLSRemuxSession) -> [String: String] {
        var result: [String: String] = [:]
        var names = ["video.m3u8"]
        names += session.audioRenditions.map(\.playlistName)
        names += session.subtitleRenditions.map(\.playlistName)
        for name in names { result[name] = session.mediaPlaylist(named: name) ?? "" }
        return result
    }

    /// What the master playlist is made from: codecs, range, channels.
    func renditions(_ session: MKVToHLSRemuxSession) -> String {
        var parts: [String] = []
        if let video = session.video { parts.append("\(video.codecs) \(video.videoRange) \(video.width)x\(video.height)") }
        parts += session.audioRenditions.map { "\($0.codecs) \($0.channels)\($0.isAtmos ? " atmos" : "")" }
        parts += session.subtitleRenditions.map { "subs \($0.name)" }
        return parts.joined(separator: " | ")
    }
}
