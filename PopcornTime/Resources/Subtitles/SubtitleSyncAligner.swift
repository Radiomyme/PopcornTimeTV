import Foundation
import Accelerate

// Automatic subtitle sync. Pure Foundation + Accelerate (no UIKit /
// PopcornKit) so the remux engine and a headless harness can both use it.
//
// It finds the map t' = ratio·t + offset that lines a downloaded subtitle
// up with the playing file, from what is known so far:
//   - the reference is either another subtitle track of the same file (only
//     its cue timings matter, so any language works) or a soft speech
//     probability decoded from the audio, each with a known/unknown mask so
//     a partly read file is not mistaken for silence;
//   - both sides become 0…1 activity signals; the score at each offset is
//     the weighted Pearson correlation over the known overlap, so a few
//     minutes of reference against a whole film still score on the same
//     scale as a full reference;
//   - a 20 Hz FFT cross-correlation (vDSP) of the high-passed signals scans
//     ±60 s for each frame-rate ratio (scene-scale structure removed, since
//     unrelated films share it), then a prefix-sum search on the 100 Hz
//     reference refines the offset to 1 ms;
//   - a confident result needs a clear, unique peak (peak-to-sidelobe and
//     best/second-peak ratios); anything else is reported and left alone.
// Stateless and thread-safe: every call works on its own buffers.

/// Map from external-subtitle time to media time: t' = ratio·t + offset.
struct SubtitleSyncTransform: Equatable {
    var ratio: Double
    var offset: Double

    static let identity = SubtitleSyncTransform(ratio: 1, offset: 0)

    func map(_ time: Double) -> Double { ratio * time + offset }

    /// Largest disagreement between two maps over `range` (both are linear,
    /// so the ends of the range bound it).
    func distance(to other: SubtitleSyncTransform, over range: ClosedRange<Double>) -> Double {
        max(abs(map(range.lowerBound) - other.map(range.lowerBound)),
            abs(map(range.upperBound) - other.map(range.upperBound)))
    }

    /// Retimed copy of `cues`. The cues themselves move (rather than an HLS
    /// X-TIMESTAMP-MAP, which clamps negative offsets): a cue that now ends at
    /// or before 0 is dropped, a start before 0 is clamped.
    func apply(to cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.compactMap { cue in
            let start = map(cue.start), end = map(cue.end)
            guard start.isFinite, end.isFinite, end > 0 else { return nil }
            var moved = cue
            moved.start = max(0, start)
            moved.end = end
            return moved.end > moved.start ? moved : nil
        }
    }
}

/// One stretch of subtitle (or speech) activity, in seconds.
struct SubtitleSyncSpan: Equatable {
    var start: Double
    var end: Double
}

/// What the external subtitle is aligned against, on a 100 Hz grid from t = 0.
struct SubtitleSyncReference {
    enum Kind: Equatable { case subtitles, speech }

    static let rate: Double = 100
    /// Longest timeline kept, whatever the input claims: bounds the memory
    /// (two Float arrays of 2.2 M samples) and the FFT size.
    static let maxDuration: Double = 6 * 3600

    let kind: Kind
    /// Activity 0…1 per 10 ms (cue shown / speech probability).
    let values: [Float]
    /// 1 where the reference is known, 0 where it is not (not yet read,
    /// skipped by a seek): unknown must not count as silence.
    let weights: [Float]
    /// Reference cues inside the observed ranges (0 for speech).
    let cueCount: Int
    /// Seconds of known reference.
    let knownSeconds: Double
    /// Seconds of activity inside the known reference (cue time or summed
    /// speech probability), for the "enough material yet?" schedule.
    let activeSeconds: Double
    /// First…last known instant, nil when nothing is known.
    let knownRange: ClosedRange<Double>?

    /// Embedded text-subtitle cues of the same file. `observed` are the media
    /// time ranges the demuxer has read so far: only there does "no cue"
    /// mean "nobody speaks".
    init(cues: [SubtitleCue], observed: [ClosedRange<Double>]) {
        self.init(spans: SubtitleSyncAligner.speechSpans(from: cues), observed: observed)
    }

    init(spans: [SubtitleSyncSpan], observed: [ClosedRange<Double>]) {
        let rate = Self.rate
        let horizon = observed.map(\.upperBound).filter(\.isFinite).max().map { min($0, Self.maxDuration) } ?? 0
        let count = horizon > 0 ? Int((horizon * rate).rounded(.up)) : 0
        var weights = [Float](repeating: 0, count: count)
        let known = SubtitleSyncAligner.merged(observed.map { SubtitleSyncSpan(start: $0.lowerBound, end: $0.upperBound) },
                                               limit: horizon)
        SubtitleSyncAligner.accumulate(known, rate: rate, into: &weights)
        var values = [Float](repeating: 0, count: count)
        let active = SubtitleSyncAligner.merged(spans, limit: horizon)
        SubtitleSyncAligner.accumulate(active, rate: rate, into: &values)
        // Weights are coverage fractions: a sample half known is a
        // half-weight sample of the same value.
        for i in 0..<count { values[i] = min(1, values[i]); weights[i] = min(1, weights[i]) }
        self.kind = .subtitles
        self.values = values
        self.weights = weights
        self.cueCount = spans.filter { span in known.contains { $0.start <= span.start && span.start < $0.end } }.count
        (knownSeconds, activeSeconds, knownRange) = Self.statistics(values, weights)
    }

    /// Speech probability from the audio track, `rate` values per second
    /// starting at `startTime`; NaN marks unknown samples. Values are clamped
    /// to 0…1 and resampled to the 100 Hz grid.
    init(speechProbability probability: [Float], rate sourceRate: Double = 100, startTime: Double = 0) {
        let rate = Self.rate
        let valid = sourceRate.isFinite && sourceRate > 0 && startTime.isFinite && !probability.isEmpty
        let end = valid ? min(startTime + Double(probability.count) / sourceRate, Self.maxDuration) : 0
        let count = end > 0 ? Int((end * rate).rounded(.up)) : 0
        var values = [Float](repeating: 0, count: count)
        var weights = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let source = ((Double(i) + 0.5) / rate - startTime) * sourceRate
            guard source >= 0 else { continue }
            let j = Int(source)
            guard j < probability.count else { break }
            let p = probability[j]
            guard p.isFinite else { continue }
            values[i] = min(1, max(0, p))
            weights[i] = 1
        }
        self.kind = .speech
        self.values = values
        self.weights = weights
        self.cueCount = 0
        (knownSeconds, activeSeconds, knownRange) = Self.statistics(values, weights)
    }

    private static func statistics(_ values: [Float], _ weights: [Float]) -> (Double, Double, ClosedRange<Double>?) {
        var known: Float = 0, active: Float = 0
        vDSP_sve(weights, 1, &known, vDSP_Length(weights.count))
        vDSP_dotpr(values, 1, weights, 1, &active, vDSP_Length(values.count))
        let first = weights.firstIndex { $0 > 0 }, last = weights.lastIndex { $0 > 0 }
        let range = first.flatMap { f in last.map { Double(f) / rate...Double($0 + 1) / rate } }
        return (Double(known) / rate, Double(active) / rate, range)
    }
}

/// Result of one alignment attempt.
struct SubtitleSyncEstimate {
    var transform: SubtitleSyncTransform
    /// Weighted Pearson correlation at the refined peak (−1…1).
    var score: Double
    /// (peak − sidelobe mean) / sidelobe standard deviation on the 20 Hz curve.
    var peakToSidelobe: Double
    /// (peak − median) / (second peak − median), second peak outside the
    /// main lobe (and never closer than ±0.5 s).
    var peakRatio: Double
    /// Known reference seconds under the subtitle at the chosen offset.
    var overlapSeconds: Double
    /// External cues lying mostly over known reference at that offset.
    var overlapCues: Int = 0
    var referenceKind: SubtitleSyncReference.Kind
    /// External cue span (first start…last end) in subtitle time, used to
    /// measure how far two estimates move the subtitle.
    var subtitleRange: ClosedRange<Double>
    var isConfident: Bool
    /// Why the estimate is not usable (nil when confident).
    var rejection: String?

    /// The map to apply, nil when the estimate must be left alone.
    var acceptedTransform: SubtitleSyncTransform? { isConfident ? transform : nil }

    /// "offset +0.84 s, ratio 1, confidence 0.62/14.1/3.2, overlap 240 s / 52
    /// cues" (score / peak-to-sidelobe / peak ratio): the shared part of the
    /// "[SubSync]" log line.
    var summary: String {
        String(format: "offset %+.2f s, ratio ", transform.offset) + SubtitleSyncAligner.ratioLabel(transform.ratio)
            + String(format: ", confidence %.2f/%.1f/%.1f, overlap %.0f s / %d cues",
                     score, peakToSidelobe, peakRatio, overlapSeconds, overlapCues)
    }

    static func rejected(_ why: String, kind: SubtitleSyncReference.Kind, range: ClosedRange<Double> = 0...0) -> SubtitleSyncEstimate {
        SubtitleSyncEstimate(transform: .identity, score: 0, peakToSidelobe: 0, peakRatio: 0, overlapSeconds: 0,
                             referenceKind: kind, subtitleRange: range, isConfident: false, rejection: why)
    }
}

enum SubtitleSyncAligner {

    /// Thresholds a peak must pass, calibrated on synthetic films (dialogue
    /// scenes, action stretches, jittered / missing / extra cues, a noisy
    /// soft VAD): unrelated subtitle or speech references never reached a
    /// peak-to-sidelobe of 5.2 or a peak ratio of 2.1 in 2,450 trials, while
    /// 10–15 min of real reference gives 9+ and 3.5+. The score floor is
    /// only a sanity check: over a few minutes an unrelated film can still
    /// correlate at 0.6, which is why it is not the main test. Fewer than 30
    /// cues over the known reference let jitter move the peak by 0.1 s.
    struct Gates {
        var minScore: Double
        var minPeakToSidelobe: Double
        var minPeakRatio: Double
        /// Seconds of known reference under the subtitle.
        var minOverlap: Double
        /// External cues over known reference.
        var minCues: Int

        static let subtitles = Gates(minScore: 0.2, minPeakToSidelobe: 6.5, minPeakRatio: 2, minOverlap: 60, minCues: 30)
        static let speech = Gates(minScore: 0.1, minPeakToSidelobe: 6.5, minPeakRatio: 2, minOverlap: 60, minCues: 30)
    }

    struct Options {
        /// Search range for the offset, seconds each way.
        var maxOffset: Double = 60
        /// Speed ratios tried: PAL speed-up (25/23.976) and its inverse
        /// first, then the 1.001 NTSC pair, which only shows over long spans.
        var ratios: [Double] = [1, 25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24]
        /// A ratio is only tried when it drifts at least this much (seconds)
        /// across the known reference: below that it is indistinguishable
        /// from an offset and would win on noise. The 1.001 pair thus waits
        /// for ~17 min of reference; 25/23.976 is tried from the start.
        var minRatioDrift: Double = 1
        /// Score a ratio other than 1 must gain over ratio 1 to be chosen.
        var ratioMargin: Double = 0.02
        /// Cue display time counted at most (reading-time tails and stuck
        /// cues otherwise smear the signal); ffsubsync uses 10 s.
        var maxCueDuration: Double = 10
        /// nil: `Gates.subtitles` or `Gates.speech` by reference kind.
        var gates: Gates?

        init() {}
    }

    /// Grid of the FFT search (50 ms): ±60 s is 2,401 lags and a 3 h film
    /// fits a 2^18-point transform.
    static let coarseRate: Double = 20
    /// High-pass window of the FFT search. Scene-scale structure (dialogue
    /// stretches vs action, intros) looks alike in unrelated films and makes
    /// broad false hills; only cue-scale detail belongs to one film.
    static let detrendWindow: Double = 5
    /// Half-width of the onset windows of the speech refinement.
    static let onsetWindow: Double = 0.3

    // MARK: - Estimating

    /// Aligns external `cues` (as parsed, in subtitle time, never already
    /// retimed) against `reference`. Always returns; an estimate that is not
    /// confident carries the reason. Costs ~1 ms with a few minutes of
    /// reference, ~50 ms against a whole 3 h film (Apple silicon Mac), with
    /// a transient peak of ~50 MB over the reference itself — mostly the
    /// 100 Hz prefix sums, kept in Double: in Float, a difference of two
    /// sums a million samples long would lose the precision the fine pass
    /// needs. The metadata filter alone is ~3 µs per cue, so a caller
    /// estimating more than once keeps `speechSpans(from:)` and calls
    /// `estimate(spans:)`.
    static func estimate(cues: [SubtitleCue], reference: SubtitleSyncReference, options: Options = Options()) -> SubtitleSyncEstimate {
        estimate(spans: speechSpans(from: cues, maxDuration: max(0.1, options.maxCueDuration)), reference: reference, options: options)
    }

    static func estimate(spans rawSpans: [SubtitleSyncSpan], reference: SubtitleSyncReference, options: Options = Options()) -> SubtitleSyncEstimate {
        let kind = reference.kind
        let gates = options.gates ?? (kind == .subtitles ? .subtitles : .speech)
        let maxCue = options.maxCueDuration.isFinite ? max(0.1, options.maxCueDuration) : 10
        let spans = merged(rawSpans.map { SubtitleSyncSpan(start: $0.start, end: min($0.end, $0.start + maxCue)) },
                           limit: SubtitleSyncReference.maxDuration)
        guard spans.count >= 3, let first = spans.first, let last = spans.last else {
            return .rejected("too few subtitle cues (\(spans.count))", kind: kind)
        }
        let range = first.start...last.end
        guard let known = reference.knownRange, reference.knownSeconds >= gates.minOverlap else {
            return .rejected(String(format: "not enough reference (%.0f s known)", reference.knownSeconds), kind: kind, range: range)
        }
        let maxOffset = options.maxOffset.isFinite ? min(max(options.maxOffset, 1), 600) : 60
        let lagRadius = Int((maxOffset * coarseRate).rounded(.up))

        // Ratio candidates that can be told apart from an offset here.
        let knownSpan = known.upperBound - known.lowerBound
        var ratios = [1.0]
        for ratio in options.ratios where ratio.isFinite && ratio > 0.5 && ratio < 2 && abs(ratio - 1) > 1e-9 {
            if abs(ratio - 1) * knownSpan >= options.minRatioDrift, !ratios.contains(where: { abs($0 - ratio) < 1e-9 }) {
                ratios.append(ratio)
            }
        }

        // Only the stretch of subtitle that can meet the known reference
        // matters: both signals start a little before it (on the 50 ms grid).
        let origin = (max(0, known.lowerBound - maxOffset - 2) * coarseRate).rounded(.down) / coarseRate
        let horizon = known.upperBound + maxOffset + 2
        guard let ref = PreparedReference(reference, from: origin, to: known.upperBound) else {
            return .rejected("flat reference (no activity contrast)", kind: kind, range: range)
        }
        let subtitleCount = Int(((min(last.end * (ratios.max() ?? 1), horizon) - origin) * coarseRate).rounded(.up)) + 2
        let size = nextPowerOfTwo(max(16, max(subtitleCount, ref.coarseCount) + lagRadius + 1))
        guard let correlator = Correlator(size: size) else {
            return .rejected("FFT setup failed", kind: kind, range: range)
        }
        let refSpectra = (x: correlator.spectrum(ref.coarseX), m: correlator.spectrum(ref.coarseM), x2: correlator.spectrum(ref.coarseX2))

        // Coarse pass: one ρ(offset) curve per ratio. Ratio 1 keeps the slot
        // unless another ratio beats it by the margin.
        var unity: Curve?
        var other: (ratio: Double, curve: Curve, top: Double)?
        for ratio in ratios {
            let scaled = spans.map { SubtitleSyncSpan(start: $0.start * ratio, end: $0.end * ratio) }
            let curve = coarseCurve(scaled, ref: ref, refSpectra: refSpectra, correlator: correlator, lagRadius: lagRadius,
                                    horizon: horizon, minOverlap: gates.minOverlap)
            if ratio == 1 { unity = curve; continue }
            guard let peak = curve.peak, curve.values[peak] > (other?.top ?? -.infinity) else { continue }
            other = (ratio, curve, curve.values[peak])
        }
        var best: (ratio: Double, curve: Curve)?
        if let unity = unity, let u = unity.peak {
            best = (1, unity)
            if let other = other, other.top >= unity.values[u] + options.ratioMargin { best = (other.ratio, other.curve) }
        } else if let other = other {
            best = (other.ratio, other.curve)
        }
        guard let (ratio, curve) = best, let peak = curve.peak else {
            return .rejected(String(format: "not enough reference under the subtitle (%.0f s)", (unity?.maxOverlap ?? 0) / coarseRate),
                             kind: kind, range: range)
        }
        let shape = curve.shape(around: peak, rate: coarseRate)

        // Fine pass on the 100 Hz reference, 10 ms then 1 ms steps. Against
        // subtitles both sides share the same conventions, so whole cues
        // are matched; against speech only cue starts are, because the
        // reading-time tail after each line would drag the whole-cue match
        // early by about half its length.
        let coarseOffset = Double(peak - lagRadius) / coarseRate
        let scorer = SpanScorer(spans: spans.compactMap { span -> SubtitleSyncSpan? in
            let scaled = SubtitleSyncSpan(start: span.start * ratio, end: span.end * ratio)
            return scaled.end + coarseOffset > origin - 1 && scaled.start + coarseOffset < known.upperBound + 1 ? scaled : nil
        }, ref: ref)
        let objective: (Double) -> Double = kind == .subtitles ? { scorer.pearson(at: $0).rho } : { scorer.onsetContrast(at: $0) }
        var bestOffset = coarseOffset, bestValue = objective(coarseOffset)
        for (step, reach) in [(0.01, kind == .subtitles ? 0.15 : 0.3), (0.001, 0.012)] {
            let centre = bestOffset
            for k in -Int((reach / step).rounded())...Int((reach / step).rounded()) {
                let candidate = centre + Double(k) * step
                let value = objective(candidate)
                if value > bestValue { bestValue = value; bestOffset = candidate }
            }
        }
        let (score, overlap) = scorer.pearson(at: bestOffset)

        var estimate = SubtitleSyncEstimate(
            transform: SubtitleSyncTransform(ratio: ratio, offset: (bestOffset * 1000).rounded() / 1000),
            score: score, peakToSidelobe: shape.peakToSidelobe, peakRatio: shape.peakRatio,
            overlapSeconds: overlap, overlapCues: scorer.knownSpans(at: bestOffset),
            referenceKind: kind, subtitleRange: range, isConfident: false, rejection: nil)
        if overlap < gates.minOverlap {
            estimate.rejection = String(format: "overlap %.0f s < %.0f s", overlap, gates.minOverlap)
        } else if estimate.overlapCues < gates.minCues {
            estimate.rejection = "only \(estimate.overlapCues) cues over the reference (< \(gates.minCues))"
        } else if abs(bestOffset) > maxOffset - 0.5 {
            estimate.rejection = "peak at the edge of the ±\(Int(maxOffset)) s search"
        } else if !(score >= gates.minScore) {
            estimate.rejection = String(format: "weak peak (score %.2f < %.2f)", score, gates.minScore)
        } else if !(shape.peakToSidelobe >= gates.minPeakToSidelobe) {
            estimate.rejection = String(format: "peak not distinct (PSR %.1f < %.1f)", shape.peakToSidelobe, gates.minPeakToSidelobe)
        } else if !(shape.peakRatio >= gates.minPeakRatio) {
            estimate.rejection = String(format: "ambiguous (second peak ratio %.2f < %.2f)", shape.peakRatio, gates.minPeakRatio)
        } else {
            estimate.isConfident = true
        }
        return estimate
    }

    // MARK: - Progressive use

    /// The estimate to trust after a `later` one, made with more material,
    /// follows an `earlier` one: the later wins when confident (it saw a
    /// superset of the reference); otherwise a confident earlier estimate
    /// stands, since a later miss is usually a noisier stretch, not proof
    /// the first was wrong.
    static func combine(_ earlier: SubtitleSyncEstimate?, _ later: SubtitleSyncEstimate) -> SubtitleSyncEstimate {
        if later.isConfident { return later }
        if let earlier = earlier, earlier.isConfident { return earlier }
        return later
    }

    /// Below this the subtitle is left untouched (unnoticeable, and a
    /// rebuild is not free).
    static let deadBand: Double = 0.15
    /// An applied correction is only replaced when the new one moves the
    /// subtitle at least this much somewhere in its span.
    static let minMove: Double = 0.3
    static let maxApplications = 2

    /// Whether `candidate` should be applied now, given the transform
    /// already applied (nil: none) and how many times one was. The reason
    /// goes to the "[SubSync]" log either way.
    static func decision(for candidate: SubtitleSyncEstimate, applied: SubtitleSyncTransform?, applications: Int) -> (apply: Bool, reason: String) {
        guard candidate.isConfident else { return (false, candidate.rejection ?? "not confident") }
        guard applications < maxApplications else { return (false, "already applied \(applications) times") }
        let range = candidate.subtitleRange
        if let applied = applied {
            let move = candidate.transform.distance(to: applied, over: range)
            return move >= minMove ? (true, String(format: "moves %.2f s from the applied sync", move))
                                   : (false, String(format: "agrees with the applied sync (%.2f s)", move))
        }
        let move = candidate.transform.distance(to: .identity, over: range)
        if candidate.transform.ratio == 1 && abs(candidate.transform.offset) < deadBand {
            return (false, String(format: "already in sync (%.2f s)", move))
        }
        return (true, String(format: "moves up to %.2f s", move))
    }

    // MARK: - Cue preparation

    /// Cue spans that stand for speech: metadata (empty, sound descriptions
    /// in brackets, note-only lines, site ads and subtitle credits at the
    /// ends) is dropped, display time is clamped to `maxDuration`.
    static func speechSpans(from cues: [SubtitleCue], maxDuration: Double = 10) -> [SubtitleSyncSpan] {
        let ordered = cues.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }.sorted { $0.start < $1.start }
        var spans: [SubtitleSyncSpan] = []
        spans.reserveCapacity(ordered.count)
        for (index, cue) in ordered.enumerated() {
            let nearEnds = index < 3 || index >= ordered.count - 3
            guard !isMetadata(cue.text, nearEnds: nearEnds) else { continue }
            let start = max(0, cue.start)
            let end = min(cue.end, start + maxDuration)
            if end > start { spans.append(SubtitleSyncSpan(start: start, end: end)) }
        }
        return spans
    }

    static func isMetadata(_ payload: String, nearEnds: Bool) -> Bool {
        let text = stripTags(payload)
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return true }
        let lower = text.lowercased()
        if adMarkers.contains(where: lower.contains) { return true }
        if nearEnds, creditMarkers.contains(where: lower.contains) { return true }
        return lines.allSatisfy { line in
            if line.unicodeScalars.allSatisfy({ noteScalars.contains($0) || CharacterSet.whitespaces.contains($0) || CharacterSet.punctuationCharacters.contains($0) }) {
                return true
            }
            guard let open = line.unicodeScalars.first, let close = line.unicodeScalars.last,
                  let expected = brackets[open] else { return false }
            return close == expected
        }
    }

    private static let adMarkers = ["opensubtitles", "www.", "http://", "https://", "subscene", "yifysubtitles", "addic7ed"]
    private static let creditMarkers = ["subtitle", "subtitulad", "sous-titr", "sottotitol", "untertitel", "legenda",
                                        "synced by", "sync by", "synchro", "ripped by", "traduction", "translated by", "transcript"]
    private static let noteScalars: Set<Unicode.Scalar> = ["♪", "♫", "♬", "♩", "#", "*"]
    private static let brackets: [Unicode.Scalar: Unicode.Scalar] = [
        "(": ")", "[": "]", "{": "}", "（": "）", "【": "】", "［": "］", "「": "」", "『": "』", "〔": "〕", "<": ">",
    ]

    /// Cue payloads carry WebVTT tags (<i>, <b>…) and escaped entities.
    private static func stripTags(_ payload: String) -> String {
        var out = String.UnicodeScalarView()
        var inTag = false
        for scalar in payload.unicodeScalars {
            if inTag {
                if scalar == ">" { inTag = false }
            } else if scalar == "<" {
                inTag = true
            } else {
                out.append(scalar)
            }
        }
        return String(out).replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func ratioLabel(_ ratio: Double) -> String {
        let named: [(Double, String)] = [(1, "1"), (25 / 23.976, "25/23.976"), (23.976 / 25, "23.976/25"),
                                         (24 / 23.976, "24/23.976"), (23.976 / 24, "23.976/24"),
                                         (25 / 24, "25/24"), (24 / 25, "24/25")]
        return named.first { abs($0.0 - ratio) < 1e-9 }?.1 ?? String(format: "%.6f", ratio)
    }

    // MARK: - Signals

    /// Sorted union of `spans`, clipped to [0, limit].
    static func merged(_ spans: [SubtitleSyncSpan], limit: Double) -> [SubtitleSyncSpan] {
        let clean = spans.compactMap { span -> SubtitleSyncSpan? in
            guard span.start.isFinite, span.end.isFinite else { return nil }
            let start = max(0, span.start), end = min(limit, span.end)
            return end > start ? SubtitleSyncSpan(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var out: [SubtitleSyncSpan] = []
        out.reserveCapacity(clean.count)
        for span in clean {
            if let lastEnd = out.last?.end, span.start <= lastEnd {
                out[out.count - 1].end = max(lastEnd, span.end)
            } else {
                out.append(span)
            }
        }
        return out
    }

    /// Adds each span's coverage of every sample (area sampling, so edges
    /// between grid points keep sub-sample timing). `spans` must be disjoint.
    static func accumulate(_ spans: [SubtitleSyncSpan], rate: Double, into samples: inout [Float]) {
        let count = samples.count
        guard count > 0 else { return }
        for span in spans {
            let a = span.start * rate, b = span.end * rate
            guard b > 0, a < Double(count) else { continue }
            let first = max(0, Int(a)), last = min(count - 1, Int(b.rounded(.up)) - 1)
            guard first <= last else { continue }
            for i in first...last {
                let lo = max(a, Double(i)), hi = min(b, Double(i + 1))
                if hi > lo { samples[i] += Float(hi - lo) }
            }
        }
    }

    static func nextPowerOfTwo(_ n: Int) -> Int {
        var size = 2
        while size < n { size <<= 1 }
        return size
    }
}

// MARK: - Prepared reference

/// The known reference between `origin` and its last known instant: 100 Hz
/// prefix sums for the fine pass, and the high-passed 20 Hz series the FFT
/// pass correlates.
private struct PreparedReference {
    /// Media time of sample 0 of every series below.
    let origin: Double
    let coarseX: [Float]      // w·(v − local mean), 50 ms
    let coarseM: [Float]      // w
    let coarseX2: [Float]     // w·(v − local mean)²
    let prefixX: [Double]     // running Σ w·(v − μ) at 100 Hz, μ = known mean
    let prefixM: [Double]     // running Σ w
    let prefixX2: [Double]    // running Σ w·(v − μ)²

    var coarseCount: Int { coarseX.count }

    init?(_ reference: SubtitleSyncReference, from start: Double, to end: Double) {
        let rate = SubtitleSyncReference.rate
        let available = min(reference.values.count, reference.weights.count)
        let first = min(available, max(0, Int((start * rate).rounded(.down))))
        let last = min(available, max(first, Int((end * rate).rounded(.up))))
        let n = last - first
        guard n > 0 else { return nil }
        let v = reference.values[first..<last], w = reference.weights[first..<last]
        var sumW = 0.0, sumWV = 0.0
        for i in first..<last where w[i] > 0 { sumW += Double(w[i]); sumWV += Double(w[i] * v[i]) }
        guard sumW > 0 else { return nil }
        let mean = sumWV / sumW
        var px = [Double](repeating: 0, count: n + 1)
        var pm = [Double](repeating: 0, count: n + 1)
        var px2 = [Double](repeating: 0, count: n + 1)
        for k in 0..<n {
            let weight = Double(w[first + k]), centred = Double(v[first + k]) - mean
            px[k + 1] = px[k] + weight * centred
            pm[k + 1] = pm[k] + weight
            px2[k + 1] = px2[k] + weight * centred * centred
        }
        // All speech or all silence: nothing to line edges up with.
        guard px2[n] / sumW > 1e-4 else { return nil }
        origin = Double(first) / rate
        prefixX = px
        prefixM = pm
        prefixX2 = px2

        // 50 ms means, then minus the weighted local mean over the detrend
        // window (unknown samples count for nothing on either side).
        let factor = Int(rate / SubtitleSyncAligner.coarseRate)
        let coarse = (n + factor - 1) / factor
        var cw = [Double](repeating: 0, count: coarse), cv = cw
        for k in 0..<coarse {
            let lo = k * factor, hi = min(n, lo + factor)
            let weight = pm[hi] - pm[lo]
            cw[k] = weight / Double(factor)
            cv[k] = weight > 0 ? (px[hi] - px[lo]) / weight + mean : 0
        }
        let local = SubtitleSyncAligner.localMeans(cv, weights: cw)
        var cx = [Float](repeating: 0, count: coarse), cx2 = cx
        for k in 0..<coarse where cw[k] > 0 {
            let d = cv[k] - local[k]
            cx[k] = Float(cw[k] * d)
            cx2[k] = Float(cw[k] * d * d)
        }
        coarseX = cx
        coarseM = cw.map { Float($0) }
        coarseX2 = cx2
    }
}

// MARK: - Coarse pass (FFT)

/// ρ per lag on the 20 Hz grid; index i ↔ offset (i − lagRadius)/20 s.
private struct Curve {
    var values: [Double]
    var valid: [Bool]
    var maxOverlap: Double
    var peak: Int?

    /// Main lobe: from the peak outwards while above half its height over
    /// the median, then on while still falling (so its shoulders are never
    /// taken for a second peak), at least ±0.5 s. The second peak is the
    /// best lag outside it; the sidelobe statistics use lags at least 1 s out.
    func shape(around peak: Int, rate: Double) -> (peakToSidelobe: Double, peakRatio: Double) {
        let validValues = zip(values, valid).filter(\.1).map(\.0).sorted()
        guard validValues.count > 16 else { return (0, 0) }
        let median = validValues[validValues.count / 2]
        let top = values[peak]
        let half = median + 0.5 * (top - median)
        var lo = peak, hi = peak
        while lo > 0, valid[lo - 1], values[lo - 1] > half || values[lo - 1] <= values[lo] { lo -= 1 }
        while hi < values.count - 1, valid[hi + 1], values[hi + 1] > half || values[hi + 1] <= values[hi] { hi += 1 }
        let minLobe = Int((0.5 * rate).rounded(.up)), minSide = Int(rate.rounded(.up))
        lo = min(lo, peak - minLobe); hi = max(hi, peak + minLobe)
        var second = -Double.infinity
        var sum = 0.0, sumSquares = 0.0, count = 0.0
        for i in values.indices where valid[i] && (i < lo || i > hi) {
            second = max(second, values[i])
            if i < peak - minSide || i > peak + minSide {
                sum += values[i]; sumSquares += values[i] * values[i]; count += 1
            }
        }
        // No sidelobe left (a single broad hill): nothing proves uniqueness.
        guard count >= 16, second.isFinite else { return (0, 0) }
        let mean = sum / count
        let deviation = max(sqrt(max(0, sumSquares / count - mean * mean)), 1e-9)
        let peakToSidelobe = (top - mean) / deviation
        let peakRatio = (top - median) / max(second - median, 1e-9)
        return (peakToSidelobe, min(peakRatio, 1000))
    }
}

extension SubtitleSyncAligner {

    /// Weighted Pearson correlation of the high-passed subtitle activity
    /// against the high-passed known reference at every lag: six FFT
    /// correlations give the weighted sums over the overlap (weights =
    /// reference known × subtitle extent), so a partial reference scores on
    /// the same scale as a full one.
    fileprivate static func coarseCurve(_ spans: [SubtitleSyncSpan], ref: PreparedReference,
                                        refSpectra: (x: Spectrum, m: Spectrum, x2: Spectrum),
                                        correlator: Correlator, lagRadius: Int, horizon: Double,
                                        minOverlap: Double) -> Curve {
        let lags = 2 * lagRadius + 1
        var curve = Curve(values: [Double](repeating: 0, count: lags), valid: [Bool](repeating: false, count: lags),
                          maxOverlap: 0, peak: nil)
        guard let first = spans.first, let last = spans.last else { return curve }
        let origin = ref.origin
        let end = min(last.end, horizon)
        let count = min(correlator.size - lagRadius - 1, Int(((end - origin) * coarseRate).rounded(.up)) + 1)
        guard count > 0, end > max(first.start, origin) else { return curve }
        let local = spans.map { SubtitleSyncSpan(start: $0.start - origin, end: $0.end - origin) }
        var coverage = [Float](repeating: 0, count: count)
        accumulate(merged(local, limit: end - origin), rate: coarseRate, into: &coverage)
        var extent = [Float](repeating: 0, count: count)
        accumulate([SubtitleSyncSpan(start: max(0, first.start - origin), end: end - origin)], rate: coarseRate, into: &extent)

        // y = e·(s − local mean of s), s = coverage / extent.
        let e = extent.map(Double.init)
        let s = zip(coverage, extent).map { $1 > 0 ? Double($0 / $1) : 0 }
        let mean = localMeans(s, weights: e)
        var y = [Float](repeating: 0, count: count), y2 = y
        for k in 0..<count where e[k] > 0 {
            let d = s[k] - mean[k]
            y[k] = Float(e[k] * d)
            y2[k] = Float(e[k] * d * d)
        }
        let ys = correlator.spectrum(y), y2s = correlator.spectrum(y2), es = correlator.spectrum(extent)

        let num = correlator.correlate(refSpectra.x, ys, lagRadius: lagRadius)
        let sx = correlator.correlate(refSpectra.x, es, lagRadius: lagRadius)
        let sxx = correlator.correlate(refSpectra.x2, es, lagRadius: lagRadius)
        let sy = correlator.correlate(refSpectra.m, ys, lagRadius: lagRadius)
        let syy = correlator.correlate(refSpectra.m, y2s, lagRadius: lagRadius)
        let w = correlator.correlate(refSpectra.m, es, lagRadius: lagRadius)

        curve.maxOverlap = Double(w.max() ?? 0)
        let floor = max(minOverlap * coarseRate, 0.5 * curve.maxOverlap)
        for i in 0..<lags {
            let weight = Double(w[i])
            guard weight >= floor, weight > 0 else { continue }
            let mx = Double(sx[i]), my = Double(sy[i])
            let cov = Double(num[i]) - mx * my / weight
            let vx = Double(sxx[i]) - mx * mx / weight
            let vy = Double(syy[i]) - my * my / weight
            guard vx > 1e-6 * weight, vy > 1e-6 * weight else { continue }
            let rho = cov / sqrt(vx * vy)
            guard rho.isFinite else { continue }
            curve.values[i] = rho
            curve.valid[i] = true
            if curve.peak.map({ rho > curve.values[$0] }) ?? true { curve.peak = i }
        }
        return curve
    }

    /// Weighted mean of `values` over a centred `detrendWindow` box.
    fileprivate static func localMeans(_ values: [Double], weights: [Double]) -> [Double] {
        let n = values.count
        let half = Int((detrendWindow * coarseRate / 2).rounded())
        var pw = [Double](repeating: 0, count: n + 1), pv = pw
        for k in 0..<n {
            pw[k + 1] = pw[k] + weights[k]
            pv[k + 1] = pv[k] + weights[k] * values[k]
        }
        var out = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let lo = max(0, k - half), hi = min(n, k + half + 1)
            let weight = pw[hi] - pw[lo]
            out[k] = weight > 0 ? (pv[hi] - pv[lo]) / weight : 0
        }
        return out
    }
}

// MARK: - Fine pass (prefix sums)

/// Exact scores at any real offset: the subtitle is piecewise constant, so
/// every sum is a difference of interpolated 100 Hz prefix sums at span
/// edges, O(cues) per offset with no resampling.
private struct SpanScorer {
    let spans: [SubtitleSyncSpan]
    let ref: PreparedReference
    let start: Double, end: Double, nu: Double

    init(spans: [SubtitleSyncSpan], ref: PreparedReference) {
        self.spans = spans
        self.ref = ref
        start = spans.first?.start ?? 0
        end = spans.last?.end ?? 0
        let active = spans.reduce(0) { $0 + ($1.end - $1.start) }
        nu = end > start ? active / (end - start) : 0
    }

    /// Weighted Pearson of cue presence (unfiltered) against the reference,
    /// and the known overlap in seconds. With y = presence − ν every term is
    /// a sum over spans plus one over the whole extent.
    func pearson(at offset: Double) -> (rho: Double, overlap: Double) {
        let w = integral(ref.prefixM, start + offset, end + offset)
        let overlap = w / SubtitleSyncReference.rate
        guard w > 0, nu > 0, nu < 1 else { return (-1, overlap) }
        var ax = 0.0, am = 0.0
        for span in spans {
            ax += integral(ref.prefixX, span.start + offset, span.end + offset)
            am += integral(ref.prefixM, span.start + offset, span.end + offset)
        }
        let sx = integral(ref.prefixX, start + offset, end + offset)
        let sxx = integral(ref.prefixX2, start + offset, end + offset)
        let sy = am - nu * w
        let num = ax - nu * sx
        let syy = (1 - nu) * (1 - nu) * am + nu * nu * (w - am)
        let cov = num - sx * sy / w
        let vx = sxx - sx * sx / w, vy = syy - sy * sy / w
        guard vx > 1e-9 * w, vy > 1e-9 * w else { return (-1, overlap) }
        let rho = cov / sqrt(vx * vy)
        return (rho.isFinite ? rho : -1, overlap)
    }

    /// Spans at least half over known reference.
    func knownSpans(at offset: Double) -> Int {
        spans.reduce(0) { count, span in
            let known = integral(ref.prefixM, span.start + offset, span.end + offset) / SubtitleSyncReference.rate
            return count + (known >= 0.5 * (span.end - span.start) ? 1 : 0)
        }
    }

    /// Σ over cue starts of (reference activity just after − just before).
    func onsetContrast(at offset: Double) -> Double {
        let d = SubtitleSyncAligner.onsetWindow
        var total = 0.0
        for span in spans {
            let t = span.start + offset
            total += integral(ref.prefixX, t, t + d) - integral(ref.prefixX, t - d, t)
        }
        return total
    }

    /// Σ of the 100 Hz series over [a, b) seconds, linear inside a sample.
    private func integral(_ prefix: [Double], _ a: Double, _ b: Double) -> Double {
        cumulative(prefix, b) - cumulative(prefix, a)
    }

    private func cumulative(_ prefix: [Double], _ time: Double) -> Double {
        let n = prefix.count - 1
        let x = (time - ref.origin) * SubtitleSyncReference.rate
        guard n > 0, x > 0 else { return 0 }
        guard x < Double(n) else { return prefix[n] }
        let i = Int(x)
        return prefix[i] + (x - Double(i)) * (prefix[i + 1] - prefix[i])
    }
}

// MARK: - FFT

/// Packed real spectrum (vDSP zrip layout: DC in re[0], Nyquist in im[0]).
private struct Spectrum {
    var re: [Float]
    var im: [Float]
}

/// Real FFT correlation of fixed power-of-two size with vDSP. Correlations
/// are only read at |lag| ≤ lagRadius, and the size leaves that much zero
/// padding past both signals, so circular wrap-around never reaches them.
/// vDSP's DFT setups, not `vDSP_create_fftsetup`: same packed layout and
/// scaling as `vDSP_fft_zrip` (checked to float precision at 2^18), but
/// creating and destroying an FFT setup of a whole film's size (2^18) left
/// about 2 MB more footprint each time, never given back (measured on
/// macOS), where the DFT setups stay flat. One setup pair per estimate.
private final class Correlator {
    let size: Int
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup

    init?(size: Int) {
        // The DFT wants 16 · 2^k at least.
        guard size >= 16, size & (size - 1) == 0, size <= 1 << 24,
              let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else { return nil }
        guard let inverse = vDSP_DFT_zrop_CreateSetup(forward, vDSP_Length(size), .INVERSE) else {
            vDSP_DFT_DestroySetup(forward)
            return nil
        }
        self.size = size
        self.forward = forward
        self.inverse = inverse
    }

    deinit {
        vDSP_DFT_DestroySetup(inverse)
        vDSP_DFT_DestroySetup(forward)
    }

    func spectrum(_ signal: [Float]) -> Spectrum {
        let half = size / 2
        var padded = [Float](repeating: 0, count: size)
        let used = min(signal.count, size)
        if used > 0 { padded.replaceSubrange(0..<used, with: signal[0..<used]) }
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_DFT_Execute(forward, split.realp, split.imagp, split.realp, split.imagp)
            }
        }
        return Spectrum(re: re, im: im)
    }

    /// c[l] = Σ_t a[t + l]·b[t] for l in −lagRadius…lagRadius (index l + lagRadius).
    func correlate(_ a: Spectrum, _ b: Spectrum, lagRadius: Int) -> [Float] {
        let half = size / 2
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var ar = a.re, ai = a.im, br = b.re, bi = b.im
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                ar.withUnsafeMutableBufferPointer { arp in
                    ai.withUnsafeMutableBufferPointer { aip in
                        br.withUnsafeMutableBufferPointer { brp in
                            bi.withUnsafeMutableBufferPointer { bip in
                                var sa = DSPSplitComplex(realp: arp.baseAddress!, imagp: aip.baseAddress!)
                                var sb = DSPSplitComplex(realp: brp.baseAddress!, imagp: bip.baseAddress!)
                                var out = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                // conj(B)·A on every bin; bin 0 packs two real
                                // values (DC, Nyquist) and is redone by hand.
                                vDSP_zvmul(&sb, 1, &sa, 1, &out, 1, vDSP_Length(half), -1)
                                rp[0] = arp[0] * brp[0]
                                ip[0] = aip[0] * bip[0]
                                vDSP_DFT_Execute(inverse, out.realp, out.imagp, out.realp, out.imagp)
                            }
                        }
                    }
                }
            }
        }
        // The forward transform scales by 2 (twice: both inputs), the inverse by N.
        let scale = 1 / Float(4 * size)
        var lags = [Float](repeating: 0, count: 2 * lagRadius + 1)
        for k in -lagRadius...lagRadius {
            let index = k >= 0 ? k : size + k
            let value = index & 1 == 0 ? re[index >> 1] : im[index >> 1]
            lags[k + lagRadius] = value * scale
        }
        return lags
    }
}
