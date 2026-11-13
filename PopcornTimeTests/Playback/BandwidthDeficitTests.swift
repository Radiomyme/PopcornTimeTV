//
//  BandwidthDeficitTests.swift
//  PopcornTimeTests
//
//  BandwidthDeficitWatch's rules (BandwidthDeficit.swift): when a stream that the
//  download cannot keep up with gets the "lighter release" offer, and which release is
//  offered, on recorded Torrentio answers. (Port of the deficit harness: 42 checks.)
//

import XCTest
import Foundation
@testable import PopcornKit

private let mbit = 1_000_000.0 / 8

private typealias W = BandwidthDeficitWatch
private func sample(_ t: Double, started: Bool = true, playing: Bool = true, stalled: Bool = false, bitrate: Double? = 72 * mbit,
            rate: Double? = 27 * mbit, complete: Bool = false, paced: Bool = false, catchesUp: Bool? = true,
            playhead: Double? = nil) -> W.Sample {
    W.Sample(now: t, hasStarted: started, wantsPlayback: playing, isStalled: stalled, bitrate: bitrate, rate: rate,
             isComplete: complete, isStoragePaced: paced, catchesUp: catchesUp, playhead: playhead)
}
/// Feeds one sample a second from `from` to `to` (inclusive); the first reason and when.
private func simulate(_ watch: inout W, _ from: Int, _ to: Int, _ make: (Double) -> W.Sample) -> (W.Reason, Double)? {
    for t in from...to { if let r = watch.note(make(Double(t))) { return (r, Double(t)) } }
    return nil
}

private func describe(_ t: Torrent?) -> String {
    guard let t = t else { return "nil" }
    return "\(t.quality ?? "?") \(t.seeds) seeds ≈ \(Int(StreamBandwidth.megabitsPerSecond(t.estimatedBitrate ?? 0))) Mb/s"
}

final class BandwidthDeficitTests: CheckedTestCase {

    func testBandwidthDeficitWatch() {
        let fixtures = Fixtures.url("Torrentio")
        // MARK: 1. Sustained deficit

        var w = W()
        let r1 = simulate(&w, 0, 60) { sample($0) }
        check(r1?.0 == .sustainedDeficit && r1?.1 == 30, "27 vs 72 Mb/s: offer after 30 s — \(String(describing: r1))")
        w = W()
        check(simulate(&w, 0, 120) { sample($0, rate: 70 * mbit) } == nil, "70 vs 72 Mb/s (> 90 %): no offer")
        w = W()
        let r64 = simulate(&w, 0, 120) { sample($0, rate: 64 * mbit) }
        check(r64?.0 == .sustainedDeficit, "64 vs 72 Mb/s (< 90 %): offer")
        w = W()
        check(simulate(&w, 0, 120) { sample($0, started: false) } == nil, "never before playback started")
        w = W()
        check(simulate(&w, 0, 120) { sample($0, complete: true) } == nil, "never once the file is complete")
        w = W()
        check(simulate(&w, 0, 120) { sample($0, paced: true) } == nil, "never while bounded storage paces the download")
        w = W()
        check(simulate(&w, 0, 120) { sample($0, catchesUp: false) } == nil, "never when the download finishes first")
        w = W()
        check(simulate(&w, 0, 120) { sample($0, bitrate: nil) } == nil, "no bitrate: nothing")
        w = W()
        check(simulate(&w, 0, 120) { sample($0, rate: nil) } == nil, "no rate measured yet: nothing")
        // A pause resets the count (the buffer grows meanwhile).
        w = W()
        let paused = simulate(&w, 0, 100) { t in sample(t, playing: !(20...40).contains(t)) }
        check(paused?.1 == 71, "pause from 20 to 40 s: the 30 s count restarts at 41 → offer at 71 — \(String(describing: paused))")
        // A rate recovering above 90 % resets too.
        w = W()
        let recovered = simulate(&w, 0, 100) { t in sample(t, rate: t == 25 ? 70 * mbit : 27 * mbit) }
        check(recovered?.1 == 56, "one good sample at 25 s: offer at 56 — \(String(describing: recovered))")
        // Stalled (waiting for data) counts as wanting playback.
        w = W()
        check(simulate(&w, 0, 60) { sample($0, playing: false, stalled: true) }?.1 == 30, "stalled: the deficit counts")
        // Unknown projection counts as catching up.
        w = W()
        check(simulate(&w, 0, 60) { sample($0, catchesUp: nil) }?.1 == 30, "projection unknown: offer")

        // MARK: 2. Repeated starvation

        var tuning = W.Tuning(); tuning.deficitSeconds = 10_000   // isolate the stall rule
        w = W(tuning: tuning)
        // Stalls at 10-14 s (4 s) and 100-103 s (3 s).
        let stalls = simulate(&w, 0, 200) { t in sample(t, stalled: (10...14).contains(t) || (100...103).contains(t)) }
        check(stalls?.0 == .repeatedStarvation && stalls?.1 == 103, "two stalls ≥ 3 s within 5 min: offer at 103 — \(String(describing: stalls))")
        w = W(tuning: tuning)
        check(simulate(&w, 0, 200) { t in sample(t, stalled: (10...11).contains(t) || (100...101).contains(t)) } == nil,
              "2 s stalls do not count")
        w = W(tuning: tuning)
        check(simulate(&w, 0, 500) { t in sample(t, stalled: (10...14).contains(t) || (400...404).contains(t)) } == nil,
              "stalls 390 s apart (> 5 min): no offer")
        w = W(tuning: tuning)
        check(simulate(&w, 0, 200) { t in sample(t, stalled: (10...14).contains(t) || (100...104).contains(t), rate: 80 * mbit) } == nil,
              "stalls but the rate is above the bitrate (a seek, not the connection): no offer")
        w = W(tuning: tuning)
        check(simulate(&w, 0, 200) { t in sample(t, started: t > 50, stalled: (10...14).contains(t) || (100...104).contains(t)) } == nil,
              "the initial buffering is not a stall")
        w = W(tuning: tuning)
        let long = simulate(&w, 0, 200) { t in sample(t, stalled: (10...60).contains(t) || (100...104).contains(t)) }
        check(long?.1 == 103, "one long stall counts once: offer at the second (103) — \(String(describing: long))")

        // Waits right after a seek (the data there was never downloaded) are the seek's.
        w = W(tuning: tuning)
        var position = 0.0
        let seeks = simulate(&w, 0, 200) { (t: Double) -> W.Sample in
            // Two seeks forward (at 10 and 100 s), each followed by a 4 s wait.
            let stalled = (10...14).contains(t) || (100...104).contains(t)
            if t == 10 { position += 600 } else if t == 100 { position += 900 } else if !stalled { position += 1 }
            return sample(t, stalled: stalled, rate: 60 * mbit, playhead: position)
        }
        check(seeks == nil, "two waits right after seeks (rate 60 < 72 Mb/s): no offer — \(String(describing: seeks))")
        w = W(tuning: tuning)
        position = 0
        let late = simulate(&w, 0, 200) { (t: Double) -> W.Sample in
            // A seek at 10 s, then real starvation at 40-44 s and 100-104 s.
            let stalled = (40...44).contains(t) || (100...104).contains(t)
            if t == 10 { position += 600 } else if !stalled { position += 1 }
            return sample(t, stalled: stalled, rate: 60 * mbit, playhead: position)
        }
        check(late?.0 == .repeatedStarvation && late?.1 == 103, "stalls long after a seek still count — \(String(describing: late))")
        w = W(tuning: tuning)
        position = 0
        let pausedThenStalls = simulate(&w, 0, 200) { (t: Double) -> W.Sample in
            // Paused 20-60 s (the playhead stays: no seek), then two stalls.
            let pausedNow = (20...60).contains(t)
            let stalled = (70...74).contains(t) || (120...124).contains(t)
            if !pausedNow && !stalled { position += 1 }
            return sample(t, playing: !pausedNow, stalled: stalled, rate: 60 * mbit, playhead: position)
        }
        check(pausedThenStalls?.1 == 123, "a pause is no seek — \(String(describing: pausedThenStalls))")

        // MARK: 3. Projection

        check(W.downloadFinishesFirst(contiguousAhead: 0, remaining: 1e9, rate: 3.41e6, bitrate: 9.1e6) == false,
              "nothing ahead, 1 GB left: playback catches up first")
        // 60 % ahead of a 3700 s, 33 GB film at 27 vs 72 Mb/s: catch-up after 0.6*3700/(1-0.375) = 3552 s;
        // the download (40 % left = 13.3 GB at 3.41 MB/s) ends after 3913 s → stall.
        let size = 33.36e9
        check(W.downloadFinishesFirst(contiguousAhead: 0.6 * size, remaining: 0.4 * size, rate: 3.41e6, bitrate: size / 3700) == false,
              "60 % ahead, 40 % left: still stalls near the end")
        check(W.downloadFinishesFirst(contiguousAhead: 0.8 * size, remaining: 0.2 * size, rate: 3.41e6, bitrate: size / 3700) == true,
              "80 % ahead, 20 % left: the download finishes first")
        check(W.downloadFinishesFirst(contiguousAhead: 0, remaining: 1e9, rate: 10e6, bitrate: 9e6) == true, "rate above the bitrate")
        check(W.downloadFinishesFirst(contiguousAhead: 5e8, remaining: 0, rate: 0, bitrate: 9e6) == true, "nothing left")
        check(W.downloadFinishesFirst(contiguousAhead: 5e8, remaining: 1e6, rate: 0, bitrate: 9e6) == false, "stalled download")

        // MARK: 4. Lighter release, live Torrentio data (Game of Thrones S01E01)

        let data = try! Data(contentsOf: fixtures.appendingPathComponent("got_s01e01.json"))
        let json = (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["streams"] as! [[String: Any]]
        let got = json.compactMap { TorrentioClient.torrent(fromStream: $0) }.withMediaRuntime(3660)
        let fgt = got.first { $0.url.contains("605b8f1c0032682c4826caf68db37b361199b2de") }!
        let fgtRate = fgt.estimatedBitrate!
        check(abs(StreamBandwidth.megabitsPerSecond(fgtRate) - 72.9) < 0.8, "FGT ≈ 72.9 Mb/s")
        let measured = 3.41e6
        let lighter = W.lighterRelease(than: fgtRate, playing: fgt.url, among: got, downloadRate: measured)
        print("GOT, FGT playing at 27 Mb/s measured → \(describe(lighter))")
        check(lighter != nil, "a lighter release exists")
        if let l = lighter {
            check(l.url != fgt.url, "not the playing one")
            check((l.estimatedBitrate ?? .infinity) <= 0.85 * measured, "fits 85 % of the measured rate: \(describe(l))")
            check(l.seeds >= Torrent.minimumSeedsForQuickStart(l.qualityValue), "healthy swarm: \(describe(l))")
        }
        let slow = W.lighterRelease(than: fgtRate, playing: fgt.url, among: got, downloadRate: 0.4e6)
        print("GOT, FGT playing at 3.2 Mb/s measured → \(describe(slow))")
        check(slow != nil && (slow!.estimatedBitrate ?? .infinity) <= 0.85 * 0.4e6, "3.2 Mb/s: a release under 2.7 Mb/s")
        // Playing the lightest known release: nothing lighter.
        let lightest = got.filter { $0.estimatedBitrate != nil && $0.seeds > 0 }.min { $0.estimatedBitrate! < $1.estimatedBitrate! }!
        check(W.lighterRelease(than: lightest.estimatedBitrate!, playing: lightest.url, among: got, downloadRate: measured) == nil,
              "the lightest release: nothing lighter (\(describe(lightest)))")
        // Releases without an estimate are never offered.
        let unknown = Torrent(url: "magnet:?xt=urn:btih:ff&dn=Game.of.Thrones.S01E01.720p", quality: "720p", seeds: 900)
        check(W.lighterRelease(than: fgtRate, playing: fgt.url, among: [fgt, unknown], downloadRate: measured) == nil,
              "no estimate: not offered")
        // Without seeds: never.
        let dead = got.first { $0.estimatedBitrate.map { $0 < 0.5 * fgtRate } ?? false }!
        check(W.lighterRelease(than: fgtRate, playing: fgt.url, among: [fgt, Torrent(url: dead.url, quality: dead.quality ?? "", seeds: 0, size: dead.size).withMediaRuntime(3660)],
                               downloadRate: measured) == nil, "0 seeds: not offered")
        // Lighter but still too heavy for the download, or a thin swarm: not offered (review).
        let heavyish = Torrent(url: "magnet:?xt=urn:btih:e1&dn=Game.of.Thrones.S01E01.2160p.WEB.x265-H.mkv", quality: "2160p", seeds: 200,
                               size: "18 GB").withMediaRuntime(3660)   // ≈ 42 Mb/s: lighter than 73, too heavy for 27
        check(W.lighterRelease(than: fgtRate, playing: fgt.url, among: [fgt, heavyish], downloadRate: measured) == nil,
              "43 Mb/s on a 27 Mb/s download: not offered")
        let thinLight = Torrent(url: "magnet:?xt=urn:btih:e2&dn=Game.of.Thrones.S01E01.1080p.WEB.x264-T.mkv", quality: "1080p", seeds: 3,
                                size: "2 GB").withMediaRuntime(3660)
        check(W.lighterRelease(than: fgtRate, playing: fgt.url, among: [fgt, thinLight], downloadRate: measured) == nil,
              "1080p with 3 seeds (floor 10): not offered")
        let sameHash = Torrent(url: "magnet:?xt=urn:btih:605B8F1C0032682C4826CAF68DB37B361199B2DE&dn=other.mkv", quality: "720p", seeds: 300,
                               size: "1 GB").withMediaRuntime(3660)
        check(W.lighterRelease(than: fgtRate, playing: fgt.url, among: [fgt, sameHash], downloadRate: measured) == nil,
              "the playing torrent under another magnet: not offered")
        // The offer at 27 Mb/s fits and is healthy (was: a 43 Mb/s 2160p).
        let all = W.lighterRelease(than: fgtRate, playing: fgt.url, among: got, downloadRate: measured)
        check(all.map { ($0.estimatedBitrate ?? .infinity) <= 0.85 * measured && $0.seeds >= Torrent.minimumSeedsForQuickStart($0.qualityValue) } == true,
              "the offer fits and is healthy: \(describe(all))")

        // Within 80 % of the playing bitrate: not "lighter".
        let close = got.filter { ($0.estimatedBitrate ?? 0) > 0.8 * fgtRate && $0.url != fgt.url }
        check(close.allSatisfy { W.lighterRelease(than: fgtRate, playing: fgt.url, among: [fgt, $0], downloadRate: measured) == nil },
              "releases above 80 % of the bitrate are not offered (\(close.count))")
    }
}
