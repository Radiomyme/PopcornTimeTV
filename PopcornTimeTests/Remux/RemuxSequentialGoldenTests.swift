//
//  RemuxSequentialGoldenTests.swift
//  PopcornTimeTests
//
//  The conversion in file order must not change: whatever the session learns to do (move to
//  another segment of its plan and come back), a film played from 0:00 to the end gets the
//  files it always got. `Fixtures/Remux/sequential-golden.json` holds the SHA-256 of every file
//  the session wrote for eight synthetic streams (`RemuxTestStreams`) BEFORE it could jump —
//  taken on rs-base, where MKVToHLSRemuxer.swift and MatroskaDemuxer.swift are those of
//  afe6903 — and of the playlists it served; this test converts them again and compares.
//
//  To record the file again (only when a change of the sequential output is meant):
//    PT_REMUX_GOLDEN_OUT=/path/sequential-golden.json xctest -XCTest \
//      PopcornTimeTests.RemuxSequentialGoldenTests <PopcornTimeTests.xctest>
//

import XCTest
import Foundation

final class RemuxSequentialGoldenTests: RemuxSessionTestCase {

    struct Golden: Codable, Equatable {
        struct Stream: Codable, Equatable {
            /// SHA-256 of the synthetic stream itself: the generator did not change either.
            var input: String
            var segments: Int
            var tailFillers: Int
            var fromKeyframeIndex: Bool
            /// Codecs, range and channels: what the master playlist is made from.
            var renditions: String
            /// File or playlist name → SHA-256.
            var files: [String: String]
            var playlists: [String: String]
        }
        var base: String
        var streams: [String: Stream]
    }

    /// Converts `stream` in file order and describes the result.
    private func convert(_ stream: SyntheticMatroska) -> Golden.Stream? {
        guard let opened = open(stream) else { return nil }
        convertInOrder(opened)
        let session = opened.session
        check(session.writeFailure == nil && session.progress.finished, "converted to the end", session.writeFailure ?? "")
        return Golden.Stream(input: Self.sha256(opened.layout.data),
                             segments: session.progress.segmentsWritten,
                             tailFillers: session.tailFillerCount,
                             fromKeyframeIndex: session.isPlaylistFromKeyframeIndex,
                             renditions: renditions(session),
                             files: files(in: opened.output).mapValues(Self.sha256),
                             playlists: playlists(session).mapValues { Self.sha256(Data($0.utf8)) })
    }

    func testAConversionInFileOrderWritesWhatItAlwaysWrote() throws {
        var converted: [String: Golden.Stream] = [:]
        for (name, stream) in RemuxTestStreams.all {
            guard let result = convert(stream) else { return }
            converted[name] = result
        }
        if let destination = ProcessInfo.processInfo.environment["PT_REMUX_GOLDEN_OUT"], !destination.isEmpty {
            let golden = Golden(base: "afe6903 (rs-base aba7581)", streams: converted)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(golden).write(to: URL(fileURLWithPath: destination))
            print("RemuxSequentialGoldenTests: golden file written to \(destination)")
            return
        }
        let golden = try JSONDecoder().decode(Golden.self, from: Fixtures.data("Remux/sequential-golden.json"))
        eq(golden.streams.keys.sorted(), RemuxTestStreams.all.map(\.name).sorted(), "the golden file lists the test streams")
        for (name, _) in RemuxTestStreams.all {
            guard let expected = golden.streams[name], let got = converted[name] else { continue }
            eq(got.input, expected.input, "\(name): the synthetic stream is the one the golden file was taken on")
            eq(got.segments, expected.segments, "\(name): segment count")
            eq(got.tailFillers, expected.tailFillers, "\(name): tail fillers")
            eq(got.fromKeyframeIndex, expected.fromKeyframeIndex, "\(name): list from the keyframe index")
            eq(got.renditions, expected.renditions, "\(name): renditions")
            eq(got.files.keys.sorted(), expected.files.keys.sorted(), "\(name): the same files")
            let changed = expected.files.keys.sorted().filter { got.files[$0] != expected.files[$0] }
            check(changed.isEmpty, "\(name): every file is byte-identical to the golden conversion",
                  "\(changed.count) differ: \(changed.prefix(6))")
            let playlists = expected.playlists.keys.sorted().filter { got.playlists[$0] != expected.playlists[$0] }
            check(playlists.isEmpty && got.playlists.count == expected.playlists.count, "\(name): the playlists are the same text",
                  "\(playlists)")
        }
    }

    /// What the golden streams are there for: each one is converted the way its name says.
    func testTheGoldenStreamsCoverWhatTheyAreNamedFor() throws {
        let golden = try JSONDecoder().decode(Golden.self, from: Fixtures.data("Remux/sequential-golden.json"))
        func stream(_ name: String) -> Golden.Stream? {
            let found = golden.streams[name]
            check(found != nil, "\(name) is in the golden file")
            return found
        }
        guard let plain = stream("h264-aac-no-index"), let front = stream("h264-aac-cues-front"),
              let hevc = stream("hevc-eac3-cues-front"), let subtitles = stream("subtitles-cues-front") else { return }
        check(!plain.fromKeyframeIndex, "without Cues the list is estimated")
        for (name, entry) in golden.streams where name != "h264-aac-no-index" {
            check(entry.fromKeyframeIndex, "\(name): the list comes from the keyframe index")
        }
        eq(front.segments, 20, "120 s of 1 s GOPs: twenty 6 s segments")
        check(hevc.renditions.hasPrefix("hvc1.2.4.L120") && hevc.renditions.contains(" PQ ")
              && hevc.renditions.contains("ec-3 16/JOC atmos"), "HEVC Main 10 PQ + E-AC-3 Atmos", hevc.renditions)
        check(subtitles.files.keys.contains("s0seg0.vtt") && subtitles.playlists["subs0.m3u8"] != nil, "a WebVTT rendition")
    }
}
