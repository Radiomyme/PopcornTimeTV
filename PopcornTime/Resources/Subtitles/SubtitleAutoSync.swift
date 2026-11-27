import Foundation

// Automatic sync of the OpenSubtitles files the remux serves (« Automatic
// Subtitle Sync » in Settings). A downloaded subtitle is often made for
// another release of the film: a few seconds early or late, or drifting at a
// 25 / 23.976 frame-rate ratio. While the film plays, the remux copies what
// it demuxes (MKVToHLSRemuxSession.SyncMaterial) and this class aligns each
// downloaded file against:
//   1. an embedded TEXT subtitle track of the same file (any language: only
//      its timings matter), never a forced-only one (too few cues) nor a
//      commentary transcript (timed on the commentator, not the film);
//   2. otherwise the speech activity of the DEFAULT audio track, decoded
//      with Apple's decoders (SpeechActivityDetector: centre channel when
//      the layout has one, else mid), for AC-3, E-AC-3 and AAC.
// The alignment itself is SubtitleSyncAligner's. This class decides when to
// estimate (SubtitleAutoSyncPlan) and hands the retimed cues to the remux,
// which serves them under the same URI; the players rebuild their item when
// that subtitle is the one on screen (SubtitleRetimeWatch).
// Embedded subtitles are never retimed; the direct (MP4) and VLC routes are
// not concerned.
//
// Threading: one serial utility queue owns the state. The pump queue only
// hands over copies (`configure`, `ingest`); `register` may come from any
// thread; `onApply` is called on the sync queue.

/// « Automatic Subtitle Sync »: device-wide, on unless turned off.
enum SubtitleAutoSyncPreference {
    static let defaultsKey = "automaticSubtitleSync"
    static let titleKey = "Settings.SubtitleSync"
    static let footerKey = "Settings.SubtitleSync.Footer"

    /// Absent: on.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: defaultsKey) as? Bool) ?? true
    }

    /// The default removes the key.
    static func store(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled ? nil : false, forKey: defaultsKey)
    }
}

/// When the automatic sync estimates, and with which aligner settings.
struct SubtitleAutoSyncSchedule {
    /// Embedded-track reference: known seconds and cues before the first
    /// estimate (fewer: thin material is mostly rejected anyway).
    var firstReferenceSeconds: Double = 240
    var firstReferenceCues = 40
    /// Speech reference: seconds of detected speech before the first estimate.
    var firstSpeechSeconds: Double = 90
    /// More known reference (s) before each later estimate: the refinement,
    /// which recovered every case the first estimate rejected in the
    /// aligner's harness.
    var refineAfterSeconds: Double = 720
    /// Once the remux has read the whole file, one more estimate when the
    /// reference grew by this much (s) since the last one: a film shorter
    /// than `refineAfterSeconds` would otherwise get a single attempt, and a
    /// first estimate that narrowly failed a gate would never be retried.
    var finalGainSeconds: Double = 60
    /// Estimates per subtitle at most; past the second, only while none was
    /// confident.
    var maxEstimates = 4
    /// An embedded track still under `firstReferenceCues` after this much
    /// known reference is not waited for: the speech reference takes over.
    var sparseTrackSeconds: Double = 600
    var aligner = SubtitleSyncAligner.Options()

    static let standard = SubtitleAutoSyncSchedule()

    /// For a 30 s test clip (the end-to-end test and the DEBUG launch hook
    /// `-PTDebugSubtitleSyncQuick YES`): every threshold scaled down to what
    /// such a clip has. Never for real playback: these gates were not
    /// calibrated against unrelated films.
    static let quick: SubtitleAutoSyncSchedule = {
        var schedule = SubtitleAutoSyncSchedule()
        schedule.firstReferenceSeconds = 10
        schedule.firstReferenceCues = 3
        schedule.firstSpeechSeconds = 3
        schedule.refineAfterSeconds = 15
        schedule.finalGainSeconds = 5
        schedule.sparseTrackSeconds = 60
        schedule.aligner.maxOffset = 10
        schedule.aligner.ratios = [1]
        // F05_subs: its English track against itself shifted scores 1.00 /
        // PSR 3.4–3.8 / peak ratio 2.1; against its Spanish track (other
        // timings) 0.39 / 2.0 / 1.1, rejected.
        schedule.aligner.gates = SubtitleSyncAligner.Gates(minScore: 0.6, minPeakToSidelobe: 3, minPeakRatio: 1.5,
                                                           minOverlap: 5, minCues: 3)
        return schedule
    }()
}

/// The schedule and the decisions of ONE downloaded subtitle. Pure: the
/// tests cover it.
struct SubtitleAutoSyncPlan {
    /// What the reference holds now.
    struct Reference: Equatable {
        var kind: SubtitleSyncReference.Kind
        /// Seconds of known reference.
        var knownSeconds: Double
        /// Embedded cues standing for speech (subtitle reference).
        var cues: Int = 0
        /// Seconds of detected speech (speech reference).
        var speechSeconds: Double = 0
    }

    let schedule: SubtitleAutoSyncSchedule
    private(set) var estimates = 0
    /// Known reference at the last estimate.
    private(set) var lastKnownSeconds: Double = 0
    /// The estimate to trust so far (`SubtitleSyncAligner.combine`).
    private(set) var best: SubtitleSyncEstimate?
    /// The map applied (nil: the file as downloaded).
    private(set) var applied: SubtitleSyncTransform?
    private(set) var applications = 0

    init(schedule: SubtitleAutoSyncSchedule = .standard) {
        self.schedule = schedule
    }

    /// Nothing more to do for this subtitle: applied twice, out of
    /// estimates, or a confident estimate confirmed by the refinement.
    var isSettled: Bool {
        applications >= SubtitleSyncAligner.maxApplications || estimates >= max(1, schedule.maxEstimates)
            || (estimates >= 2 && best?.isConfident == true)
    }

    /// An estimate is due with `reference`: the first once there is enough
    /// of it, each later one `refineAfterSeconds` of known reference later.
    /// `isComplete` (the remux has read the whole file: no more reference
    /// will come) also makes one last estimate due when the reference grew
    /// by `finalGainSeconds` since the last one — the first one included,
    /// for a short film under the first thresholds: the aligner's gates
    /// still decide whether it is applied.
    func isDue(_ reference: Reference, isComplete: Bool = false) -> Bool {
        guard !isSettled else { return false }
        if isComplete, reference.knownSeconds >= lastKnownSeconds + schedule.finalGainSeconds {
            return true
        }
        if estimates == 0 {
            switch reference.kind {
            case .subtitles:
                return reference.knownSeconds >= schedule.firstReferenceSeconds && reference.cues >= schedule.firstReferenceCues
            case .speech:
                return reference.speechSeconds >= schedule.firstSpeechSeconds
            }
        }
        return reference.knownSeconds >= lastKnownSeconds + schedule.refineAfterSeconds
    }

    /// Takes `estimate` (made with `knownSeconds` of reference). Returns the
    /// map to apply now (nil: leave the subtitle as it is) and the end of
    /// the "[SubSync]" log line: "applied (…)" or "rejected (…)".
    mutating func record(_ estimate: SubtitleSyncEstimate, knownSeconds: Double) -> (transform: SubtitleSyncTransform?, verdict: String) {
        estimates += 1
        lastKnownSeconds = knownSeconds
        let candidate = SubtitleSyncAligner.combine(best, estimate)
        best = candidate
        let decision = SubtitleSyncAligner.decision(for: candidate, applied: applied, applications: applications)
        guard decision.apply else {
            // A rejected estimate says why itself; a confident one that is
            // not applied, why not.
            return (nil, "rejected (\(estimate.isConfident ? decision.reason : estimate.rejection ?? decision.reason))")
        }
        applied = candidate.transform
        applications += 1
        return (candidate.transform, "applied (\(decision.reason))")
    }
}

/// The automatic sync of one remux session (see the top of the file).
final class SubtitleAutoSync {

    /// An embedded subtitle rendition of the session.
    struct EmbeddedTrack: Equatable {
        let index: Int
        let name: String
        let isForced: Bool
        /// A commentary transcript (`MKVToHLSRemuxSession.isCommentary`):
        /// often the densest text track, timed on the commentator's voice,
        /// not the film's dialogue.
        var isCommentary = false

        /// Its cues can stand for the film's dialogue: neither forced (too
        /// few cues) nor a commentary.
        var isReferenceCandidate: Bool { !isForced && !isCommentary }
    }

    /// A downloaded subtitle being synced.
    private struct External {
        let language: String
        /// The file version of its key (`register`).
        let generation: Int
        /// As parsed from the download, subtitle time: every estimate is
        /// made from these, never from a retimed copy.
        let cues: [SubtitleCue]
        let spans: [SubtitleSyncSpan]
        var plan: SubtitleAutoSyncPlan
    }

    /// The reference now: what it holds, its name in the log, and how to
    /// build it (only when an estimate is due: it is the costly part).
    private struct ReferenceNow {
        let stats: SubtitleAutoSyncPlan.Reference
        let name: String
        let build: () -> SubtitleSyncReference
    }

    let schedule: SubtitleAutoSyncSchedule
    /// The retimed cues of a subtitle (its key, the generation it was
    /// registered with), to serve from now on. Set before the first
    /// `register`; called on the sync queue.
    var onApply: ((_ key: String, _ generation: Int, _ cues: [SubtitleCue]) -> Void)?

    private let queue = DispatchQueue(label: "remux.subsync", qos: .utility)
    private let log: (String) -> Void

    private let flagLock = NSLock()
    private var lockedWantsMaterial = true
    private var lockedWantsAudio = false

    // Sync-queue state.
    private var tracks: [EmbeddedTrack] = []
    private var audioSource: MKVToHLSRemuxSession.SyncAudioSource?
    private var detector: SpeechActivityDetector?
    private var detectorUnavailable = false
    /// Embedded cues by rendition index, media timeline.
    private var embeddedCues: [Int: [SubtitleCue]] = [:]
    /// `SubtitleSyncAligner.speechSpans` of `embeddedCues`, by rendition
    /// index, with the cue count they were made from.
    private var embeddedSpans: [Int: (count: Int, spans: [SubtitleSyncSpan])] = [:]
    /// Media time ranges demuxed, merged and sorted.
    private var observed: [ClosedRange<Double>] = []
    /// Media time of the player's 0 (the session's `timelineStart90k`): the
    /// downloaded files are timed from there.
    private var timelineStart: Double = 0
    private var externals: [String: External] = [:]
    /// The remux has read the whole file: no more reference will come
    /// (`inputFinished`).
    private var isComplete = false
    /// Access units the decoder refused in a row (`decode`).
    private var refusedInARow = 0

    init(schedule: SubtitleAutoSyncSchedule = .standard, log: @escaping (String) -> Void = { print($0) }) {
        self.schedule = schedule
        self.log = log
    }

    // MARK: Pump queue (cheap: everything is handed to the sync queue)

    /// Whether the remux should copy what it demuxes: until every
    /// downloaded subtitle is settled.
    var wantsMaterial: Bool { flagLock.withLock { lockedWantsMaterial } }
    /// Whether it should copy the audio too: a speech reference is needed
    /// (no usable embedded text track) and a downloaded file is waiting to
    /// be synced. Not before one is registered: OpenSubtitles often lists
    /// files that are never downloaded (no subtitle shown, none prefetched),
    /// and decoding a whole film for them would be wasted. A file picked
    /// mid-film starts the speech reference from where the remux reads
    /// then; the one prefetched for the preferred language is registered
    /// before playback starts.
    var wantsAudio: Bool { flagLock.withLock { lockedWantsAudio } }

    /// The session is prepared: its subtitle renditions and the audio it may decode.
    func configure(tracks: [EmbeddedTrack], audio: MKVToHLSRemuxSession.SyncAudioSource?) {
        queue.async { [self] in
            self.tracks = tracks
            audioSource = audio
            let text = tracks.filter(\.isReferenceCandidate)
            let reference = text.isEmpty
                ? (audio.map { "audio \($0.codec.rawValue) (track \($0.renditionIndex + 1)) when needed" } ?? "none (no text track, no decodable audio)")
                : "embedded track" + (text.count > 1 ? "s " : " ") + text.map { "\($0.index + 1) (\($0.name))" }.joined(separator: ", ")
            log("[SubSync] session ready: reference \(reference)")
            updateFlags()
        }
    }

    /// The remux has read the whole file (pump queue): what is known now is
    /// all the reference there will be — one last estimate may be due
    /// (`SubtitleAutoSyncPlan.isDue`).
    func inputFinished() {
        queue.async { [self] in
            guard !isComplete else { return }
            isComplete = true
            evaluate()
        }
    }

    /// What the remux demuxed since the last call; `timelineStart` in
    /// seconds (the session's `timelineStart90k`).
    func ingest(_ material: MKVToHLSRemuxSession.SyncMaterial, timelineStart: Double) {
        queue.async { [self] in
            if timelineStart.isFinite { self.timelineStart = max(0, timelineStart) }
            for (index, cues) in material.cues { embeddedCues[index, default: []].append(contentsOf: cues) }
            if !material.observed.isEmpty { observed = Self.union(observed + material.observed) }
            decode(material.audio)
            evaluate()
        }
    }

    // MARK: Any thread

    /// A downloaded subtitle, as parsed (subtitle time), under `key` (the
    /// remux's `sub_{key}`), `language` for the log. A key registered again
    /// starts over — another row's file for that language (the moviehash
    /// match) gets a fresh plan. `generation`: the remux's version of the
    /// key's file, handed back with its retimed cues (`onApply`); a lower one
    /// than the key's (a late call for a file already replaced) is ignored.
    func register(key: String, language: String, cues: [SubtitleCue], generation: Int = 0) {
        queue.async { [self] in
            if let known = externals[key], known.generation > generation { return }
            if let known = externals[key], known.generation < generation {
                log("[SubSync] \(language): another file replaces the one being synced — starting over")
            }
            let spans = SubtitleSyncAligner.speechSpans(from: cues, maxDuration: schedule.aligner.maxCueDuration)
            externals[key] = External(language: language, generation: generation, cues: cues, spans: spans,
                                      plan: SubtitleAutoSyncPlan(schedule: schedule))
            evaluate()
        }
    }

    /// Waits for what was handed over so far (tests).
    func waitUntilIdle() {
        queue.sync {}
    }

    /// The plan of `key` (tests, logs).
    func plan(forKey key: String) -> SubtitleAutoSyncPlan? {
        queue.sync { externals[key]?.plan }
    }

    /// The generation `key` was registered with (tests).
    func generation(forKey key: String) -> Int? {
        queue.sync { externals[key]?.generation }
    }

    // MARK: Sync queue

    private func decode(_ units: [MKVToHLSRemuxSession.SyncAudioUnit]) {
        guard !units.isEmpty, !detectorUnavailable else { return }
        if detector == nil {
            guard let source = audioSource else { return }
            let codec: SpeechActivityDetector.Codec
            switch source.codec {
            case .ac3: codec = .ac3
            case .eac3: codec = .eac3
            case .aac:
                guard let config = source.audioSpecificConfig else { detectorUnavailable = true; return }
                codec = .aac(audioSpecificConfig: config)
            default:
                detectorUnavailable = true
                return
            }
            guard let made = SpeechActivityDetector(codec: codec, sampleRate: source.sampleRate,
                                                    channelCount: source.channels, codecDelay: source.codecDelay) else {
                detectorUnavailable = true
                log("[SubSync] no audio reference: no decoder for \(source.codec.rawValue) here")
                updateFlags()
                return
            }
            detector = made
        }
        guard let detector else { return }
        for unit in units {
            if detector.decode(accessUnit: unit.data, presentationTime: unit.time, duration: unit.duration) {
                refusedInARow = 0
                continue
            }
            refusedInARow += 1
            // A decoder that opened but refuses every unit (a codec variant
            // it does not take, a damaged configuration) would have the
            // whole film copied for nothing: given up, once it never decoded.
            if refusedInARow >= Self.maxRefusedUnits, detector.accessUnitsDecoded == 0 {
                detectorUnavailable = true
                self.detector = nil
                log("[SubSync] no audio reference: the decoder refuses the \(audioSource?.codec.rawValue ?? "audio") units "
                    + "(\(refusedInARow) in a row, none decoded)")
                updateFlags()
                return
            }
        }
    }

    /// Refused access units in a row, none ever decoded, before the speech
    /// reference is given up (a few seconds of audio: a damaged stretch at
    /// the start of a good track decodes again well before).
    static let maxRefusedUnits = 100

    /// Estimates every subtitle whose turn it is, applies what is decided.
    private func evaluate() {
        defer { updateFlags() }
        let pending = externals.filter { !$0.value.plan.isSettled }.keys.sorted()
        guard !pending.isEmpty, let reference = currentReference() else { return }
        var built: SubtitleSyncReference?
        for key in pending {
            guard var external = externals[key], external.plan.isDue(reference.stats, isComplete: isComplete) else { continue }
            let ref = built ?? reference.build()
            built = ref
            let estimate = SubtitleSyncAligner.estimate(spans: external.spans, reference: ref, options: schedule.aligner)
            let (transform, verdict) = external.plan.record(estimate, knownSeconds: reference.stats.knownSeconds)
            externals[key] = external
            log("[SubSync] \(external.language): reference \(reference.name), \(estimate.summary), \(verdict)")
            if let transform { onApply?(key, external.generation, transform.apply(to: external.cues)) }
        }
    }

    /// The reference to align on now: the embedded text track with the most
    /// cues (not a forced one nor a commentary, not one too sparse to wait
    /// for), else the
    /// speech of the decoded audio. On the downloaded files' timeline.
    private func currentReference() -> ReferenceNow? {
        let shift = timelineStart
        let known = observed.compactMap { range -> ClosedRange<Double>? in
            let lower = max(0, range.lowerBound - shift), upper = range.upperBound - shift
            return upper > lower ? lower...upper : nil
        }
        let knownSeconds = known.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        var bestTrack: (track: EmbeddedTrack, spans: [SubtitleSyncSpan])?
        for track in tracks where track.isReferenceCandidate {
            let spans = spans(ofTrack: track.index)
            if spans.count > (bestTrack?.spans.count ?? -1) { bestTrack = (track, spans) }
        }
        if let best = bestTrack,
           !(knownSeconds >= schedule.sparseTrackSeconds && best.spans.count < schedule.firstReferenceCues) {
            let shifted = best.spans.compactMap { span -> SubtitleSyncSpan? in
                let start = max(0, span.start - shift), end = span.end - shift
                return end > start ? SubtitleSyncSpan(start: start, end: end) : nil
            }
            return ReferenceNow(stats: .init(kind: .subtitles, knownSeconds: knownSeconds, cues: shifted.count),
                                name: "embedded track \(best.track.index + 1) (\(best.track.name))",
                                build: { SubtitleSyncReference(spans: shifted, observed: known) })
        }
        guard let detector else { return nil }
        let activity = detector.activity()
        return ReferenceNow(stats: .init(kind: .speech, knownSeconds: activity.knownSeconds, speechSeconds: activity.speechSeconds),
                            name: "audio \(detector.channelSource.rawValue)",
                            build: { SubtitleSyncReference(speechProbability: activity.probabilities,
                                                           rate: Double(SpeechActivity.slotsPerSecond), startTime: -shift) })
    }

    private func spans(ofTrack index: Int) -> [SubtitleSyncSpan] {
        let cues = embeddedCues[index] ?? []
        if let cached = embeddedSpans[index], cached.count == cues.count { return cached.spans }
        let spans = SubtitleSyncAligner.speechSpans(from: cues, maxDuration: schedule.aligner.maxCueDuration)
        embeddedSpans[index] = (cues.count, spans)
        return spans
    }

    /// Whether the embedded tracks can serve as the reference (else the
    /// speech one is needed): one that is neither forced nor a commentary,
    /// and not too sparse.
    private var embeddedSuffices: Bool {
        let text = tracks.filter(\.isReferenceCandidate)
        guard !text.isEmpty else { return false }
        let knownSeconds = observed.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard knownSeconds >= schedule.sparseTrackSeconds else { return true }
        return text.contains { spans(ofTrack: $0.index).count >= schedule.firstReferenceCues }
    }

    private func updateFlags() {
        let settled = !externals.isEmpty && externals.values.allSatisfy(\.plan.isSettled)
        let material = !settled
        // Only for a registered file still to sync (see `wantsAudio`).
        let audio = material && !externals.isEmpty && audioSource != nil
            && !detectorUnavailable && !embeddedSuffices
        flagLock.withLock {
            lockedWantsMaterial = material
            lockedWantsAudio = audio
        }
    }

    /// Sorted union of `ranges` (touching or overlapping ranges merged).
    static func union(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for range in ranges.filter({ $0.lowerBound.isFinite && $0.upperBound.isFinite }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound + 0.05 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }
}

/// The players' side: an OpenSubtitles file the remux retimed reaches
/// AVPlayer only through a new item (it reads each WebVTT once per item).
/// When the retimed file is the subtitle on screen, the item is rebuilt in
/// place (`PlaybackStarvationRecovery.rebuildNow`: position, play / pause
/// state and the user's audio and subtitle choice kept), as it is when the
/// user switches to it later on the same item; otherwise nothing happens —
/// the next item loaded serves the corrected file. Pure: the tests cover it.
struct SubtitleRetimeWatch {
    /// Why: the rebuild's log line.
    static let reason = "Sous-titres OpenSubtitles recalés : élément reconstruit avec la version synchronisée"

    /// Keys retimed since the current item loaded its files. Kept until the
    /// next item: one retimed while another subtitle was on screen may have
    /// been read by this item earlier (the user switches back to it), and
    /// AVPlayer could show its old cues again.
    private(set) var retimedKeys: Set<String> = []
    /// The subtitle on screen was retimed: an item to rebuild.
    private(set) var isRebuildDue = false

    init() {}

    /// The remux serves a retimed file for `key`.
    mutating func retimed(key: String) {
        retimedKeys.insert(key)
    }

    /// Whether the selection has to be checked (asynchronously, by the
    /// owner, at each sample): until the current item is replaced, while a
    /// retimed file could come on screen.
    var needsSelectionCheck: Bool { !retimedKeys.isEmpty && !isRebuildDue }

    /// The owner checked the item's subtitle selection: `shownKey` is the
    /// key of the OpenSubtitles rendition on screen (nil: none, or one of
    /// the file's own tracks). A retimed one on screen — now, or later
    /// after a switch back to it — makes the rebuild due.
    mutating func selectionChecked(shownKey: String?) {
        if let shownKey, retimedKeys.contains(shownKey) { isRebuildDue = true }
    }

    /// A new current item: it loads the files as they are served now.
    mutating func attached() {
        retimedKeys.removeAll()
        isRebuildDue = false
    }

    /// One sample (~1 Hz). True — once — when the item is to be rebuilt and
    /// the owner can do it now (`isEligible`: no recovery, resume question,
    /// start seek, Picture in Picture, AirPlay nor background). Not
    /// eligible: asked again at the next sample.
    mutating func shouldRebuild(isEligible: Bool) -> Bool {
        guard isRebuildDue, isEligible else { return false }
        isRebuildDue = false
        return true
    }

    /// The remux key ("fr", "pt-br") of an OpenSubtitles rendition from its
    /// LANGUAGE tag, nil when `name` is not an OpenSubtitles rendition's
    /// (`PlaybackLanguagePreferences.externalSubtitleNameMarker`).
    static func externalKey(languageTag: String?, name: String?) -> String? {
        guard let name, name.range(of: "(OpenSubtitles)", options: .caseInsensitive) != nil,
              let tag = languageTag, !tag.isEmpty else { return nil }
        let key = RemuxPlayback.externalKey(languageTag: tag)
        return key.isEmpty ? nil : key
    }
}
