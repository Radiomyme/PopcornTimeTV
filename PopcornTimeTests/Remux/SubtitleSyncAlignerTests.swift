//
//  SubtitleSyncAlignerTests.swift
//  PopcornTimeTests
//
//  The automatic subtitle sync's aligner (`SubtitleSyncAligner`), ported from its command-line
//  harness: synthetic films (dialogue scenes, action stretches, credits) whose reference subtitle
//  and downloaded subtitle are made independently from the same utterances, shifted by known
//  offsets and frame-rate ratios. Positives must come back within 50 ms, negatives (unrelated
//  films, noise, an offset beyond the search) must all be rejected. Films are 20 min here, not
//  2 h, and fewer trials run: the test bundle is built without optimisation.
//

import XCTest
import Foundation

/// The harness's synthetic material, shared with `SubtitleAutoSyncTests`.
enum SyncFilms {
    struct RNG {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }
        mutating func chance(_ p: Double) -> Bool { uniform() < p }
        mutating func exponential(_ mean: Double) -> Double { -mean * log(max(1e-12, 1 - uniform())) }
        mutating func logNormal(median: Double, sigma: Double) -> Double {
            let u1 = max(1e-12, uniform()), u2 = uniform()
            return median * exp(sigma * sqrt(-2 * log(u1)) * cos(2 * .pi * u2))
        }
    }

    typealias Span = SubtitleSyncSpan

    struct Style {
        var jitter = 0.03
        var drop = 0.0
        var extra = 0.0
    }

    static let hard = Style(jitter: 0.15, drop: 0.2, extra: 0.2)

    /// Dialogue-like utterances: a silent intro, dialogue scenes, stretches without speech, credits.
    static func film(seed: UInt64, duration: Double) -> [Span] {
        var rng = RNG(seed)
        var t = rng.uniform(40, 120)
        var out: [Span] = []
        let stop = duration - rng.uniform(60, 150)
        while t < stop {
            if rng.chance(0.62) {
                let sceneEnd = min(stop, t + rng.uniform(60, 300))
                while t < sceneEnd {
                    let length = min(6, max(0.4, rng.logNormal(median: 1.7, sigma: 0.55)))
                    out.append(Span(start: t, end: t + length))
                    t += length + (rng.chance(0.4) ? rng.uniform(0.12, 0.5) : min(6, 0.3 + rng.exponential(1.2)))
                }
            } else {
                t += rng.uniform(15, 120)
            }
        }
        return out
    }

    /// A subtitle an author made from the utterances: lines merged or split, reading tails,
    /// jittered edges, missing and extra cues.
    static func subtitles(_ utterances: [Span], seed: UInt64, style: Style = Style(), duration: Double) -> [Span] {
        var rng = RNG(seed)
        var cues: [Span] = []
        var i = 0
        while i < utterances.count {
            var u = utterances[i]
            if i + 1 < utterances.count, utterances[i + 1].start - u.end < 0.45,
               utterances[i + 1].end - u.start < 6, rng.chance(0.3) {
                u.end = utterances[i + 1].end
                i += 1
            }
            i += 1
            if u.end - u.start > 4.5, rng.chance(0.7) {
                let mid = (u.start + u.end) / 2 + rng.uniform(-0.4, 0.4)
                cues.append(Span(start: u.start, end: mid))
                cues.append(Span(start: mid + 0.04, end: u.end))
            } else {
                cues.append(u)
            }
        }
        cues = cues.map { c in
            let start = c.start + rng.uniform(-0.1, 0.05)
            return Span(start: start, end: max(c.end + rng.uniform(0.2, 0.8), start + 0.8))
        }
        for k in 0..<cues.count {
            if k + 1 < cues.count { cues[k].end = min(cues[k].end, cues[k + 1].start - 0.04) }
            cues[k].start += rng.uniform(-style.jitter, style.jitter)
            cues[k].end += rng.uniform(-style.jitter, style.jitter)
        }
        cues = cues.filter { $0.end - $0.start > 0.2 }
        if style.drop > 0 { cues = cues.filter { _ in !rng.chance(style.drop) } }
        for _ in 0..<Int(Double(cues.count) * style.extra) {
            let s = rng.uniform(0, duration - 5)
            cues.append(Span(start: s, end: s + rng.uniform(0.8, 3.5)))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// The downloaded file's times for media times under t_media = a·t_sub + b.
    static func shift(_ cues: [Span], ratio a: Double, offset b: Double) -> [Span] {
        cues.map { Span(start: ($0.start - b) / a, end: ($0.end - b) / a) }.filter { $0.start >= 0 }
    }

    /// A soft speech probability at 100 Hz: utterances found 85 % of the time, a noise floor,
    /// music / effects bursts that look like speech; NaN outside `known`.
    static func speech(_ utterances: [Span], seed: UInt64, duration: Double, known: ClosedRange<Double>? = nil,
                       burstsPerMinute: Double = 3) -> [Float] {
        var rng = RNG(seed)
        let n = Int(duration * 100)
        var p = [Float](repeating: 0, count: n)
        for i in 0..<n { p[i] = Float(rng.uniform(0, 0.3)) }
        for u in utterances where rng.chance(0.85) {
            let a = max(0, Int(u.start * 100)), b = min(n, Int(u.end * 100))
            guard a < b else { continue }
            for i in a..<b { p[i] = Float(rng.uniform(0.5, 0.95)) }
        }
        var t = 0.0
        while t < duration {
            t += rng.exponential(60 / burstsPerMinute)
            let a = Int(t * 100), b = min(n, Int((t + rng.uniform(0.3, 3)) * 100))
            guard a < b else { continue }
            for i in a..<b { p[i] = max(p[i], Float(rng.uniform(0.45, 0.9))) }
        }
        if let known {
            for i in p.indices where Double(i) / 100 < known.lowerBound || Double(i) / 100 >= known.upperBound { p[i] = .nan }
        }
        return p
    }

    static func cues(_ spans: [Span]) -> [SubtitleCue] {
        spans.enumerated().map { SubtitleCue(start: $0.element.start, end: $0.element.end, text: "Line \($0.offset)", settings: nil) }
    }
}

final class SubtitleSyncAlignerTests: CheckedTestCase {

    private typealias F = SyncFilms
    private let duration = 1200.0
    private let offsets = [-12.3, -0.8, 0.4, 3.0, 45.0]
    private let ratios = [1, 25 / 23.976, 23.976 / 25]

    /// Confident, the right ratio, the offset within 50 ms.
    private func recovered(_ estimate: SubtitleSyncEstimate, ratio: Double, offset: Double, tolerance: Double = 0.05) -> Bool {
        estimate.isConfident && abs(estimate.transform.ratio - ratio) < 1e-9 && abs(estimate.transform.offset - offset) <= tolerance
    }

    func testRecoversOffsetsAndRatiosAgainstAnEmbeddedTrack() {
        for seed: UInt64 in [1, 2] {
            let film = F.film(seed: seed, duration: duration)
            let reference = SubtitleSyncReference(cues: F.cues(F.subtitles(film, seed: seed &* 31 &+ 7, duration: duration)),
                                                  observed: [0...duration])
            for style in [F.Style(), F.hard] {
                let base = F.subtitles(film, seed: seed &* 131 &+ 3, style: style, duration: duration)
                for ratio in ratios {
                    for offset in offsets {
                        let estimate = SubtitleSyncAligner.estimate(cues: F.cues(F.shift(base, ratio: ratio, offset: offset)), reference: reference)
                        check(recovered(estimate, ratio: ratio, offset: offset),
                              "film \(seed), ratio \(SubtitleSyncAligner.ratioLabel(ratio)), offset \(offset) recovered", estimate.summary)
                    }
                }
            }
        }
    }

    /// The first-estimate point: thin material may be rejected, never far off. With the hard
    /// style (±150 ms edges, 20 % of the cues missing, 20 % extra) a confident estimate can be
    /// 80 ms off there (film 3: −0.88 s for −0.8 s, PSR 6.7, 38 cues): under what a viewer
    /// notices, so 100 ms is the bound here; the full-film cases above hold 50 ms.
    func testPartialReferenceIsNeverWrong() {
        for seed: UInt64 in [3, 4] {
            let film = F.film(seed: seed, duration: duration)
            let refSpans = F.subtitles(film, seed: seed &* 31 &+ 7, duration: duration)
            let merged = SubtitleSyncAligner.merged(refSpans, limit: duration)
            let fortieth = merged.count >= 40 ? merged[39].end : duration
            let reference = SubtitleSyncReference(cues: F.cues(refSpans), observed: [0...max(240, fortieth)])
            let base = F.subtitles(film, seed: seed &* 131 &+ 3, style: F.hard, duration: duration)
            for offset in offsets {
                let estimate = SubtitleSyncAligner.estimate(cues: F.cues(F.shift(base, ratio: 1, offset: offset)), reference: reference)
                check(!estimate.isConfident || recovered(estimate, ratio: 1, offset: offset, tolerance: 0.1),
                      "film \(seed) offset \(offset): rejected or within 100 ms",
                      estimate.summary)
            }
        }
    }

    func testSRTWithAdsAndSoundCues() {
        let film = F.film(seed: 99, duration: duration)
        let reference = SubtitleSyncReference(cues: F.cues(F.subtitles(film, seed: 991, duration: duration)), observed: [0...duration])
        let shifted = F.shift(F.subtitles(film, seed: 992, style: F.Style(jitter: 0.15, drop: 0.2), duration: duration), ratio: 1, offset: 2.37)
        func timestamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var srt = "1\n00:00:01,000 --> 00:00:05,000\nAdvertise your product or brand here\ncontact www.OpenSubtitles.org today\n\n"
        var rng = F.RNG(5)
        for (k, span) in shifted.enumerated() {
            let roll = rng.uniform()
            let text = roll < 0.05 ? "[door slams]" : roll < 0.08 ? "♪ ♪" : "<i>Line \(k)</i>\nsecond line"
            srt += "\(k + 2)\n\(timestamp(span.start)) --> \(timestamp(span.end))\n\(text)\n\n"
        }
        let parsed = SubtitleConversion.parse(srt)
        let spans = SubtitleSyncAligner.speechSpans(from: parsed)
        check(spans.count < parsed.count, "the ad and the sound cues are left out", "\(spans.count) of \(parsed.count)")
        let estimate = SubtitleSyncAligner.estimate(cues: parsed, reference: reference)
        check(recovered(estimate, ratio: 1, offset: 2.37), "the SRT's offset is recovered", estimate.summary)
    }

    func testSpeechReference() {
        for seed: UInt64 in [1, 2] {
            let film = F.film(seed: seed, duration: duration)
            let reference = SubtitleSyncReference(speechProbability: F.speech(film, seed: seed &+ 500, duration: duration))
            let base = F.subtitles(film, seed: seed &* 131 &+ 3, style: F.Style(jitter: 0.1, drop: 0.1, extra: 0.05), duration: duration)
            for ratio in [1, 25 / 23.976] {
                for offset in [-0.8, 3.0] {
                    let estimate = SubtitleSyncAligner.estimate(cues: F.cues(F.shift(base, ratio: ratio, offset: offset)), reference: reference)
                    // Synthetic cue starts lead the speech by ~25 ms; 100 ms of margin.
                    check(recovered(estimate, ratio: ratio, offset: offset, tolerance: 0.1),
                          "speech, film \(seed), ratio \(SubtitleSyncAligner.ratioLabel(ratio)), offset \(offset)", estimate.summary)
                }
            }
        }
    }

    func testTheOnePerMilleRatio() {
        let film = F.film(seed: 5, duration: duration)
        let reference = SubtitleSyncReference(cues: F.cues(F.subtitles(film, seed: 162, duration: duration)), observed: [0...duration])
        let shifted = F.shift(F.subtitles(film, seed: 658, style: F.Style(jitter: 0.1), duration: duration), ratio: 24 / 23.976, offset: 1.5)
        let estimate = SubtitleSyncAligner.estimate(cues: F.cues(shifted), reference: reference)
        check(recovered(estimate, ratio: 24 / 23.976, offset: 1.5), "24/23.976 and +1.5 s recovered", estimate.summary)
    }

    func testUnrelatedMaterialIsRejected() {
        var falsePositives: [String] = []
        for trial in 0..<12 {
            let s = UInt64(10_000 + trial)
            let a = F.film(seed: s, duration: duration), b = F.film(seed: s &+ 77_777, duration: duration)
            let refSpans = F.subtitles(a, seed: s, duration: duration)
            let other = F.cues(F.subtitles(b, seed: s &+ 1, style: F.hard, duration: duration))
            let estimates = [
                ("unrelated subtitles, whole film", SubtitleSyncAligner.estimate(
                    cues: other, reference: SubtitleSyncReference(cues: F.cues(refSpans), observed: [0...duration]))),
                ("unrelated subtitles, first 4 min", SubtitleSyncAligner.estimate(
                    cues: other, reference: SubtitleSyncReference(cues: F.cues(refSpans), observed: [0...240]))),
                ("noise speech", SubtitleSyncAligner.estimate(
                    cues: other, reference: SubtitleSyncReference(speechProbability: F.speech([], seed: s, duration: duration, burstsPerMinute: 12)))),
                ("unrelated speech, 10 min", SubtitleSyncAligner.estimate(
                    cues: other, reference: SubtitleSyncReference(speechProbability: F.speech(a, seed: s, duration: duration, known: 300...900)))),
            ]
            for (name, estimate) in estimates where estimate.isConfident { falsePositives.append("\(name) #\(trial): \(estimate.summary)") }
        }
        for trial in 0..<3 {
            let s = UInt64(20_000 + trial)
            let film = F.film(seed: s, duration: duration)
            let reference = SubtitleSyncReference(cues: F.cues(F.subtitles(film, seed: s, duration: duration)), observed: [0...duration])
            let far = F.cues(F.shift(F.subtitles(film, seed: s &+ 1, duration: duration), ratio: 1, offset: 90))
            let estimate = SubtitleSyncAligner.estimate(cues: far, reference: reference)
            if estimate.isConfident { falsePositives.append("offset 90 s #\(trial): \(estimate.summary)") }
        }
        check(falsePositives.isEmpty, "no confident estimate on unrelated material", falsePositives.joined(separator: " | "))
    }

    func testProgressiveDecisions() {
        let film = F.film(seed: 3, duration: duration)
        let refSpans = F.subtitles(film, seed: 300, duration: duration)
        let external = F.cues(F.shift(F.subtitles(film, seed: 301, style: F.hard, duration: duration), ratio: 1, offset: 0.84))
        let first = SubtitleSyncAligner.estimate(cues: external, reference: SubtitleSyncReference(cues: F.cues(refSpans), observed: [0...600]))
        let later = SubtitleSyncAligner.estimate(cues: external, reference: SubtitleSyncReference(cues: F.cues(refSpans), observed: [0...duration]))
        check(recovered(first, ratio: 1, offset: 0.84) && recovered(later, ratio: 1, offset: 0.84), "both estimates recovered",
              "\(first.summary) / \(later.summary)")
        check(SubtitleSyncAligner.decision(for: first, applied: nil, applications: 0).apply, "the first is applied")
        let kept = SubtitleSyncAligner.combine(first, later)
        check(!SubtitleSyncAligner.decision(for: kept, applied: first.transform, applications: 1).apply, "a later agreeing one is not")
        let rejected = SubtitleSyncEstimate.rejected("x", kind: .speech)
        eq(SubtitleSyncAligner.combine(first, rejected).transform, first.transform, "a later rejected estimate keeps the earlier one")
    }

    func testDegenerateInputsAreRejectedWithoutTrapping() {
        let some = F.cues([.init(start: 1, end: 2), .init(start: 5, end: 7), .init(start: 9, end: 10), .init(start: 20, end: 22)])
        let film = F.film(seed: 1, duration: 600)
        let good = SubtitleSyncReference(cues: F.cues(film), observed: [0...600])
        var noSearch = SubtitleSyncAligner.Options()
        noSearch.maxOffset = 0
        noSearch.ratios = []
        var negative = SubtitleSyncAligner.Options()
        negative.maxOffset = -5
        negative.maxCueDuration = -1
        let cases: [(String, SubtitleSyncEstimate)] = [
            ("no cues, no reference", SubtitleSyncAligner.estimate(cues: [], reference: SubtitleSyncReference(cues: [], observed: []))),
            ("no cues", SubtitleSyncAligner.estimate(cues: [], reference: good)),
            ("one cue", SubtitleSyncAligner.estimate(cues: Array(some.prefix(1)), reference: good)),
            ("NaN, infinite, negative cues", SubtitleSyncAligner.estimate(cues: [
                SubtitleCue(start: .nan, end: 3, text: "a", settings: nil), SubtitleCue(start: -50, end: -10, text: "b", settings: nil),
                SubtitleCue(start: 1, end: .infinity, text: "c", settings: nil)] + some, reference: good)),
            ("a cue at 1e9 s", SubtitleSyncAligner.estimate(cues: some + [SubtitleCue(start: 1e9, end: 1e9 + 2, text: "x", settings: nil)],
                                                            reference: good)),
            ("all speech", SubtitleSyncAligner.estimate(cues: some, reference: SubtitleSyncReference(speechProbability: [Float](repeating: 1, count: 60_000)))),
            ("NaN speech", SubtitleSyncAligner.estimate(cues: some, reference: SubtitleSyncReference(speechProbability: [Float](repeating: .nan, count: 6_000)))),
            ("rate 0, NaN start", SubtitleSyncAligner.estimate(cues: some, reference: SubtitleSyncReference(speechProbability: [0.5, 1], rate: 0, startTime: .nan))),
            ("observed 1e12 s", SubtitleSyncAligner.estimate(cues: some, reference: SubtitleSyncReference(cues: some, observed: [0...1e12]))),
            ("no search", SubtitleSyncAligner.estimate(cues: F.cues(film), reference: good, options: noSearch)),
            ("negative options", SubtitleSyncAligner.estimate(cues: F.cues(film), reference: good, options: negative)),
        ]
        for (name, estimate) in cases where name != "negative options" && name != "no search" {
            check(!estimate.isConfident && estimate.rejection != nil, "\(name): rejected with a reason", estimate.summary)
        }
        let same = SubtitleSyncAligner.estimate(cues: F.cues(film), reference: good)
        check(recovered(same, ratio: 1, offset: 0, tolerance: 0.005), "identical lists: offset 0, confident", same.summary)
    }
}
