//
//  LoadingPhaseTests.swift
//  PopcornTimeTests
//
//  LoadingPhase: what the loading screen says the download is doing (metadata, peers,
//  first pieces, slow source), from the streamer's status samples. (Port: 42 checks.)
//

import XCTest
import Foundation

private func meta(_ m: Bool?, p: Float = 0, rate: Int = 0, peers: Int = 0) -> LoadingSample {
    LoadingSample(hasMetadata: m, bufferingProgress: p, downloadSpeed: rate, seeds: 0, peers: peers)
}

final class LoadingPhaseTests: CheckedTestCase {

    func testLoadingPhase() {
        // 1. Older PopcornTorrent: nothing before the metadata -> elapsed time, then no details at 90 s.
        do {
            let t = LoadingPhaseTracker(startedAt: 1000)
            var ph = t.update(.unknown, now: 1001)
            check(ph == .starting && t.line == "Getting the torrent's details…", "old fork: starting, no elapsed before 5 s", t.line)
            ph = t.update(.unknown, now: 1006)
            check(t.line == "Getting the torrent's details… · 0:06", "old fork: elapsed after 5 s", t.line)
            ph = t.update(.unknown, now: 1089.9)
            check(ph == .starting, "old fork: still starting at 89.9 s (no peer rule without a status)", "\(ph)")
            ph = t.update(.unknown, now: 1090)
            check(ph == .notResponding(.noDetails), "old fork: no details at 90 s", "\(ph)")
            check(t.line == "This source isn't sending the torrent's details. Try another source.", "no-details message, no elapsed", t.line)
            // The first callback of an older PopcornTorrent: the metadata is in.
            t.statusArrived = true
            ph = t.update(meta(true, p: 0.05, rate: 300_000, peers: 4), now: 1091)
            check(ph.isBuffering && !ph.isNotResponding, "old fork: first status -> buffering, stall gone", "\(ph)")
        }

        // 2. New PopcornTorrent, dead swarm: looking for peers, 0 peers for 45 s.
        do {
            let t = LoadingPhaseTracker(startedAt: 0)
            var ph = t.update(meta(false), now: 0.5)
            check(ph == .lookingForPeers && t.line == "Looking for peers…", "no peer: looking for peers", t.line)
            ph = t.update(meta(false), now: 44.9)
            check(ph == .lookingForPeers && t.line == "Looking for peers… · 0:44", "still looking at 44.9 s, elapsed shown", t.line)
            ph = t.update(meta(false), now: 45)
            check(ph == .notResponding(.noPeers) && t.line == "This source isn't responding (0 peers). Try another source.", "no peers at 45 s", t.line)
            // A peer shows up: the stall ends by itself.
            ph = t.update(meta(false, rate: 2000, peers: 3), now: 46)
            check(ph == .gettingDetails(connected: 3) && t.line == "Getting the torrent's details… (3 connected) · 2 KB/s · 0:46", "a late peer: getting details (3 connected), the metadata exchange's rate", t.line)
            // Metadata in, downloading: buffering with %.
            ph = t.update(meta(true, p: 0, rate: 400_000, peers: 5), now: 47)
            check(ph == .buffering(progress: 0, eta: nil) && t.line == "0%", "metadata: buffering 0 %", t.line)
            t.update(meta(true, p: 0.1, rate: 400_000, peers: 5), now: 48)
            ph = t.update(meta(true, p: 0.2, rate: 400_000, peers: 5), now: 49)
            if case .buffering(let p, let eta?) = ph {
                check(abs(p - 0.2) < 0.001 && abs(eta - 8) < 0.5, "ETA from the progress rate (0.1/s -> 8 s)", "\(p) \(eta)")
            } else { check(false, "ETA known", "\(ph)") }
            check(t.line == "20% · Time remaining ~8 sec", "buffering line (localized ETA)", t.line)
        }

        // 3. Peers seen, then lost: 45 s from the last peer.
        do {
            let t = LoadingPhaseTracker(startedAt: 0)
            t.update(meta(false, peers: 2), now: 10)
            var ph = t.update(meta(false), now: 54.9)
            check(ph == .lookingForPeers, "45 s counted from the last peer (not yet at 54.9 s)", "\(ph)")
            ph = t.update(meta(false), now: 55)
            check(ph == .notResponding(.noPeers), "no peers 45 s after the last one", "\(ph)")
        }

        // 4. Peers but no metadata for 90 s.
        do {
            let t = LoadingPhaseTracker(startedAt: 0)
            var ph = t.update(meta(false, rate: 50, peers: 2), now: 89)
            check(ph == .gettingDetails(connected: 2), "peers, no metadata at 89 s", "\(ph)")
            ph = t.update(meta(false, rate: 50, peers: 2), now: 90)
            check(ph == .notResponding(.noDetails), "no metadata 90 s after the start", "\(ph)")
            ph = t.update(meta(true, peers: 2), now: 91)
            check(ph == .buffering(progress: 0, eta: nil), "metadata ends the no-details stall", "\(ph)")
        }

        // 5. Metadata in, buffering stuck with nothing coming for 120 s; a busy download is not a stall.
        do {
            let t = LoadingPhaseTracker(startedAt: 0)
            t.update(meta(true, p: 0.3, rate: 500_000, peers: 6), now: 5)
            var ph = t.update(meta(true, p: 0.3, rate: 500_000, peers: 6), now: 200)
            check(ph.isBuffering, "progress stuck but downloading (500 KB/s): no stall", "\(ph)")
            ph = t.update(meta(true, p: 0.3, rate: 0, peers: 6), now: 124.9 + 80)
            check(ph == .notResponding(.noData), "stuck since 5 s, nothing coming: no data", "\(ph)")
            ph = t.update(meta(true, p: 0.3, rate: 300_000, peers: 6), now: 206)
            check(ph == .notResponding(.noData), "no data: a burst of rate alone does not end it", "\(ph)")
            ph = t.update(meta(true, p: 0.31, rate: 300_000, peers: 6), now: 207)
            check(ph.isBuffering, "progress again ends the no-data stall", "\(ph)")
            let u = LoadingPhaseTracker(startedAt: 0)
            u.update(meta(true, p: 0, rate: 0, peers: 0), now: 1)
            ph = u.update(meta(true, p: 0, rate: 0, peers: 0), now: 2)
            check(ph == .lookingForPeers, "metadata, 0 peers, nothing buffered: looking for peers", "\(ph)")
            ph = u.update(meta(true, p: 0, rate: 0, peers: 0), now: 45)
            check(ph == .notResponding(.noPeers), ".torrent file with a dead swarm: no peers at 45 s", "\(ph)")
        }

        // 6. Keep waiting re-arms every rule from then.
        do {
            let t = LoadingPhaseTracker(startedAt: 0)
            t.update(meta(false), now: 45)
            check(t.phase == .notResponding(.noPeers), "stall before keep waiting", "\(t.phase)")
            t.keepWaiting(now: 50)
            check(t.phase == .lookingForPeers, "keep waiting hides the message", "\(t.phase)")
            var ph = t.update(meta(false), now: 94.9)
            check(ph == .lookingForPeers, "re-armed: nothing until 45 s after keep waiting", "\(ph)")
            ph = t.update(meta(false), now: 95)
            check(ph == .notResponding(.noPeers), "re-armed: no peers 45 s after keep waiting", "\(ph)")
            let u = LoadingPhaseTracker(startedAt: 0)
            u.update(meta(false, peers: 1), now: 90)
            u.keepWaiting(now: 91)
            ph = u.update(meta(false, peers: 1), now: 180)
            check(ph == .gettingDetails(connected: 1), "re-armed no-details: not before 90 s after keep waiting", "\(ph)")
            ph = u.update(meta(false, peers: 1), now: 181)
            check(ph == .notResponding(.noDetails), "re-armed no-details at 90 s after keep waiting", "\(ph)")
        }

        // 6b. Pre-metadata rate: below 1 KiB/s (protocol chatter) not shown.
        do {
            let t = LoadingPhaseTracker(startedAt: 0)
            t.update(meta(false, rate: 500, peers: 1), now: 2)
            check(t.line == "Getting the torrent's details… (1 connected)", "no rate under 1 KiB/s", t.line)
            t.update(meta(false, rate: 5632, peers: 1), now: 3)
            check(t.line == "Getting the torrent's details… (1 connected) · 6 KB/s", "rate shown before the metadata", t.line)
        }

        // 6c. A slow but alive source (isSlow): buffering 30 s, ETA over 3 min or none.
        do {
            let t = LoadingPhaseTracker(startedAt: 0)
            t.update(meta(true, p: 0, rate: 30_000, peers: 6), now: 1)
            check(!t.isSlow, "slow: not at the start of the buffering")
            var now = 1.0, p: Float = 0
            while now < 31 { now += 1; p += 0.001; t.update(meta(true, p: p, rate: 30_000, peers: 6), now: now) }
            check(t.phase.isBuffering && t.isSlow, "slow: 0.1 %/s after 30 s (ETA ~16 min)", "\(t.phase)")
            let u = LoadingPhaseTracker(startedAt: 0)
            u.update(meta(true, p: 0, rate: 3_000_000, peers: 40), now: 1)
            var q: Float = 0, at = 1.0
            while at < 40 { at += 1; q = min(0.95, q + 0.02); u.update(meta(true, p: q, rate: 3_000_000, peers: 40), now: at) }
            check(!u.isSlow, "not slow: 2 %/s (ETA under a minute)", "\(u.phase)")
            let v = LoadingPhaseTracker(startedAt: 0)
            v.update(meta(true, p: 0, rate: 4000, peers: 2), now: 1)
            v.update(meta(true, p: 0, rate: 4000, peers: 2), now: 40)
            check(v.isSlow && !v.phase.isNotResponding, "no progress, alive (4 KB/s) after 39 s: slow, not a stall", "\(v.phase)")
            v.update(meta(false), now: 41)
            check(!v.isSlow, "not slow outside buffering")
        }

        // 7. Formats.
        check(LoadingPhase.formatElapsed(65) == "1:05" && LoadingPhase.formatElapsed(5) == "0:05" && LoadingPhase.formatElapsed(725) == "12:05", "elapsed m:ss")
        check(LoadingPhase.formatETA(65) == "1 min, 5 sec" && LoadingPhase.formatETA(42) == "42 sec" && LoadingPhase.formatETA(120) == "2 min",
              "ETA localized (DateComponentsFormatter .short)", LoadingPhase.formatETA(65) + " | " + LoadingPhase.formatETA(42) + " | " + LoadingPhase.formatETA(120))
        check(LoadingPhase.formatRate(5500) == "5 KB/s" && LoadingPhase.formatRate(0) == "Zero KB/s" || LoadingPhase.formatRate(5500) == "5 KB/s",
              "rate format", LoadingPhase.formatRate(5500))
        check(LoadingPhase.chooseAnotherSourceTitle == "Choose another source" && LoadingPhase.keepWaitingTitle == "Keep waiting", "action titles")
        check(LoadingPhase.buffering(progress: 1.2, eta: nil).line == "100%", "progress clamped")
    }
}
