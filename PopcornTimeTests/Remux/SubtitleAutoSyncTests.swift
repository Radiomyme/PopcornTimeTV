//
//  SubtitleAutoSyncTests.swift
//  PopcornTimeTests
//
//  The automatic subtitle sync around the aligner: the setting, the schedule of one downloaded
//  subtitle (`SubtitleAutoSyncPlan`: when to estimate, the dead band, the re-apply threshold,
//  two applications at most), the retimed WebVTT, the coordinator fed like the remux feeds it,
//  the material the remux session copies, the players' rebuild rule (`SubtitleRetimeWatch`) and,
//  with PT_SUBSYNC_FIXTURES set to the folder of the format-coverage MKV fixtures, the whole
//  remux on F05_subs.mkv: an OpenSubtitles file made from its English track, shifted, comes out
//  of `sub_fr.vtt` within 50 ms of that track.
//

import XCTest
import Foundation
@testable import PopcornKit

final class SubtitleAutoSyncTests: RemuxSessionTestCase {

    private typealias F = SyncFilms

    override func tearDown() {
        RemuxPlayback.subtitleSyncScheduleOverride = nil
        RemuxPlayback.readsLocalSubtitleFiles = false
        super.tearDown()
    }

    // MARK: Setting

    func testSettingIsOnByDefault() {
        let defaults = UserDefaults(suiteName: "SubtitleAutoSyncTests-\(UUID().uuidString)")!
        check(SubtitleAutoSyncPreference.isEnabled(in: defaults), "absent: on")
        SubtitleAutoSyncPreference.store(false, in: defaults)
        check(!SubtitleAutoSyncPreference.isEnabled(in: defaults), "turned off")
        SubtitleAutoSyncPreference.store(true, in: defaults)
        check(defaults.object(forKey: SubtitleAutoSyncPreference.defaultsKey) == nil, "on again: the key is removed")
        defaults.set(true, forKey: SubtitleAutoSyncPreference.defaultsKey)
        check(SubtitleAutoSyncPreference.isEnabled(in: defaults), "a stored true (the Toggle's) reads as on")
    }

    // MARK: Schedule and decisions

    private func estimate(_ offset: Double, ratio: Double = 1, confident: Bool = true) -> SubtitleSyncEstimate {
        SubtitleSyncEstimate(transform: SubtitleSyncTransform(ratio: ratio, offset: offset), score: confident ? 0.8 : 0.1,
                             peakToSidelobe: confident ? 12 : 3, peakRatio: confident ? 3 : 1.2, overlapSeconds: 300,
                             referenceKind: .subtitles, subtitleRange: 0...5400, isConfident: confident,
                             rejection: confident ? nil : "peak not distinct (PSR 3.0 < 6.5)")
    }

    func testFirstEstimateWaitsForEnoughReference() {
        let plan = SubtitleAutoSyncPlan()
        check(!plan.isDue(.init(kind: .subtitles, knownSeconds: 239, cues: 100)), "under 4 min: not yet")
        check(!plan.isDue(.init(kind: .subtitles, knownSeconds: 600, cues: 39)), "under 40 cues: not yet")
        check(plan.isDue(.init(kind: .subtitles, knownSeconds: 240, cues: 40)), "4 min and 40 cues: due")
        check(!plan.isDue(.init(kind: .speech, knownSeconds: 600, speechSeconds: 89)), "under 90 s of speech: not yet")
        check(plan.isDue(.init(kind: .speech, knownSeconds: 200, speechSeconds: 90)), "90 s of speech: due")
    }

    func testRefinementDeadBandAndTwoApplications() {
        var plan = SubtitleAutoSyncPlan()
        var outcome = plan.record(estimate(0.84), knownSeconds: 250)
        eq(outcome.transform, SubtitleSyncTransform(ratio: 1, offset: 0.84), "the first confident estimate is applied")
        check(outcome.verdict.hasPrefix("applied"), "logged as applied", outcome.verdict)
        check(!plan.isDue(.init(kind: .subtitles, knownSeconds: 900, cues: 300)), "the refinement waits for 12 more minutes")
        check(plan.isDue(.init(kind: .subtitles, knownSeconds: 970, cues: 300)), "then it is due")
        outcome = plan.record(estimate(0.9), knownSeconds: 970)
        check(outcome.transform == nil && outcome.verdict.hasPrefix("rejected (agrees"), "a move under 0.3 s is not re-applied", outcome.verdict)
        check(plan.isSettled, "a confirmed estimate settles the subtitle")

        var moving = SubtitleAutoSyncPlan()
        _ = moving.record(estimate(0.84), knownSeconds: 250)
        outcome = moving.record(estimate(1.3), knownSeconds: 970)
        eq(outcome.transform?.offset, 1.3, "a move of 0.3 s or more is re-applied")
        eq(moving.applications, 2, "two applications")
        check(moving.isSettled, "and no third")

        var small = SubtitleAutoSyncPlan()
        outcome = small.record(estimate(0.1), knownSeconds: 250)
        check(outcome.transform == nil && outcome.verdict.contains("already in sync"), "inside the 0.15 s dead band: left alone", outcome.verdict)
        var ratio = SubtitleAutoSyncPlan()
        outcome = ratio.record(estimate(0.05, ratio: 25 / 23.976), knownSeconds: 250)
        check(outcome.transform != nil, "a frame-rate ratio is applied even with a tiny offset")

        var rejectedFirst = SubtitleAutoSyncPlan()
        outcome = rejectedFirst.record(estimate(3, confident: false), knownSeconds: 250)
        check(outcome.transform == nil && outcome.verdict.contains("PSR"), "a rejected estimate says why", outcome.verdict)
        check(!rejectedFirst.isSettled, "and the refinement still comes")
        outcome = rejectedFirst.record(estimate(3), knownSeconds: 970)
        eq(outcome.transform?.offset, 3, "the refinement applies")

        var stubborn = SubtitleAutoSyncPlan()
        for known in [250.0, 970, 1690, 2410] { _ = stubborn.record(estimate(3, confident: false), knownSeconds: known) }
        check(stubborn.isSettled, "four rejected estimates: given up")
    }

    // MARK: The retimed file

    private func vttCues(_ data: Data) -> [SubtitleCue] {
        SubtitleConversion.parse(String(decoding: data, as: UTF8.self))
    }

    func testRetimedWebVTT() {
        let cues = [SubtitleCue(start: 0.5, end: 1.5, text: "a", settings: nil), SubtitleCue(start: 1.5, end: 3, text: "b", settings: nil),
                    SubtitleCue(start: 10, end: 12, text: "c &amp; d", settings: "line:10%")]
        func served(_ transform: SubtitleSyncTransform, mpegts: Int64 = 0) -> (String, [SubtitleCue]) {
            let text = RemuxPlayback.withTimestampMap(SubtitleConversion.makeWebVTT(transform.apply(to: cues)), mpegts: mpegts)
            return (text, vttCues(Data(text.utf8)))
        }
        var (text, back) = served(SubtitleSyncTransform(ratio: 1, offset: 2.5))
        eq(back.map(\.start), [3, 4, 12.5], "positive offset: later")
        check(text.contains("X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000"), "the session's map", text)
        (text, back) = served(SubtitleSyncTransform(ratio: 1, offset: -2), mpegts: 54_000_000)
        eq(back.map(\.start), [0, 8], "negative offset: a cue ending before 0 dropped, one across 0 clamped")
        eq(back.map(\.end), [1, 10], "their ends moved")
        check(text.contains("X-TIMESTAMP-MAP=MPEGTS:54000000"), "a movie starting at 600 s keeps its map", text)
        check(text.contains("line:10%"), "cue settings kept")
        (_, back) = served(SubtitleSyncTransform(ratio: 25 / 23.976, offset: 0))
        check(abs(back[2].start - 10 * 25 / 23.976) < 0.001 && abs(back[2].end - 12 * 25 / 23.976) < 0.001, "ratio: scaled",
              "\(back[2].start)-\(back[2].end)")
    }

    // MARK: The coordinator

    /// A film played from 0 in steps of `step` seconds: its embedded cues and the demuxed range of
    /// each step, on the media timeline (the downloaded file's 0 at `start`).
    private func feed(_ sync: SubtitleAutoSync, cues: [SubtitleCue], until end: Double, step: Double = 30, start: Double = 0,
                      from begin: Double = 0) {
        var t = begin
        while t < end {
            let upper = min(end, t + step)
            var material = MKVToHLSRemuxSession.SyncMaterial()
            material.cues[1] = cues.filter { $0.start >= t && $0.start < upper }.map {
                SubtitleCue(start: $0.start + start, end: $0.end + start, text: $0.text, settings: nil)
            }
            material.observed = [(t + start)...(upper + start)]
            sync.ingest(material, timelineStart: start)
            t = upper
        }
        sync.waitUntilIdle()
    }

    private final class Applied {
        var calls: [(key: String, cues: [SubtitleCue])] = []
        var lines: [String] = []
    }

    private func coordinator(_ applied: Applied) -> SubtitleAutoSync {
        let sync = SubtitleAutoSync(schedule: .standard) { line in applied.lines.append(line) }
        sync.onApply = { key, cues in applied.calls.append((key, cues)) }
        sync.configure(tracks: [.init(index: 0, name: "Français (forcés)", isForced: true), .init(index: 1, name: "English", isForced: false)],
                       audio: nil)
        return sync
    }

    func testCoordinatorAppliesAtTheScheduleAndRefines() {
        let duration = 1500.0
        let film = F.film(seed: 7, duration: duration)
        let embedded = F.cues(F.subtitles(film, seed: 71, duration: duration))
        let external = F.cues(F.shift(F.subtitles(film, seed: 72, style: F.Style(jitter: 0.1), duration: duration), ratio: 1, offset: 2.37))
        for start in [0.0, 600] {
            let applied = Applied()
            let sync = coordinator(applied)
            sync.register(key: "fr", language: "fr", cues: external)
            feed(sync, cues: embedded, until: duration, start: start)
            check(applied.calls.count == 1, "start \(start): applied once (the refinement agrees)", applied.lines.joined(separator: " | "))
            if let call = applied.calls.first {
                eq(call.key, "fr", "the key")
                let moved = zip(external, call.cues).map { $1.start - $0.start }
                check(moved.allSatisfy { abs($0 - 2.37) < 0.05 }, "start \(start): every cue moved by +2.37 s", "\(moved.prefix(3))")
            }
            check(applied.lines.contains { $0.hasPrefix("[SubSync] fr: reference embedded track 2 (English), offset +2.3") && $0.contains("applied (moves") },
                  "the log line names the reference and says applied", applied.lines.joined(separator: " | "))
            let plan = sync.plan(forKey: "fr")
            eq(plan?.estimates, 2, "start \(start): the first estimate and the refinement")
            check(plan?.isSettled == true && !sync.wantsMaterial, "settled: the remux stops copying")
        }
    }

    func testCoordinatorLateSubtitleAndReferenceChoice() {
        let duration = 600.0
        let film = F.film(seed: 8, duration: duration)
        let embedded = F.cues(F.subtitles(film, seed: 81, duration: duration))
        let applied = Applied()
        let sync = coordinator(applied)
        check(sync.wantsMaterial && !sync.wantsAudio, "with an English text track: no audio needed")
        feed(sync, cues: embedded, until: duration)
        check(applied.calls.isEmpty, "nothing to sync yet")
        // A file downloaded after the reference was read: estimated at once.
        let late = F.cues(F.shift(F.subtitles(film, seed: 82, duration: duration), ratio: 1, offset: -4.2))
        sync.register(key: "es", language: "es", cues: late)
        sync.waitUntilIdle()
        eq(applied.calls.count, 1, "estimated and applied on arrival")
        let moved = applied.calls.first.map { call in zip(late, call.cues).map { $1.start - $0.start } } ?? []
        check(!moved.isEmpty && moved.allSatisfy { abs($0 + 4.2) < 0.05 }, "moved 4.2 s earlier", "\(moved.prefix(3))")
        check(applied.lines.last?.hasPrefix("[SubSync] es: reference embedded track 2 (English), offset -4.") == true,
              "the offset in the log", applied.lines.last ?? "")

        // No text track, decodable audio: the audio is copied once a downloaded file waits to
        // be synced — not merely because OpenSubtitles lists files (often never downloaded:
        // a whole film decoded for nothing).
        let speech = SubtitleAutoSync(schedule: .standard) { _ in }
        speech.configure(tracks: [.init(index: 0, name: "Forced", isForced: true)],
                         audio: .init(renditionIndex: 0, codec: .eac3, audioSpecificConfig: nil, sampleRate: 48_000, channels: 6, codecDelay: 0))
        speech.waitUntilIdle()
        check(!speech.wantsAudio, "no downloaded file yet: no audio")
        speech.register(key: "fr", language: "fr", cues: late)
        speech.waitUntilIdle()
        check(speech.wantsAudio, "then the audio is wanted")
        let silent = SubtitleAutoSync(schedule: .standard) { _ in }
        silent.configure(tracks: [], audio: .init(renditionIndex: 0, codec: .flac, audioSpecificConfig: nil, sampleRate: 48_000,
                                                  channels: 2, codecDelay: 0))
        silent.register(key: "fr", language: "fr", cues: late)
        silent.waitUntilIdle()
        check(silent.wantsAudio, "FLAC: copied until the decoder is asked")
        var material = MKVToHLSRemuxSession.SyncMaterial()
        material.audio = [.init(data: Data(repeating: 0, count: 64), time: 0, duration: nil)]
        silent.ingest(material, timelineStart: 0)
        silent.waitUntilIdle()
        check(!silent.wantsAudio, "no decoder for it: no audio reference")
    }

    /// A commentary transcript is usually the densest text track, timed on the commentator's
    /// voice: never the reference, and it does not stand in for the speech one either.
    func testCommentaryTrackIsNeverTheReference() {
        let duration = 600.0
        let film = F.film(seed: 9, duration: duration)
        let dialogue = F.cues(F.subtitles(film, seed: 91, duration: duration))
        let commentary = F.cues(F.subtitles(F.film(seed: 99, duration: duration), seed: 92, duration: duration)
                                + F.subtitles(F.film(seed: 98, duration: duration), seed: 93, duration: duration))
            .sorted { $0.start < $1.start }
        check(commentary.count > dialogue.count, "the commentary has more cues", "\(commentary.count) vs \(dialogue.count)")
        let applied = Applied()
        let sync = SubtitleAutoSync(schedule: .standard) { applied.lines.append($0) }
        sync.onApply = { key, cues in applied.calls.append((key, cues)) }
        sync.configure(tracks: [.init(index: 0, name: "English", isForced: false),
                                .init(index: 1, name: "English Commentary", isForced: false, isCommentary: true)],
                       audio: nil)
        sync.register(key: "fr", language: "fr",
                      cues: F.cues(F.shift(F.subtitles(film, seed: 94, duration: duration), ratio: 1, offset: 1.8)))
        var t = 0.0
        while t < duration {
            var material = MKVToHLSRemuxSession.SyncMaterial()
            material.cues[0] = dialogue.filter { $0.start >= t && $0.start < t + 30 }
            material.cues[1] = commentary.filter { $0.start >= t && $0.start < t + 30 }
            material.observed = [t...(t + 30)]
            sync.ingest(material, timelineStart: 0)
            t += 30
        }
        sync.waitUntilIdle()
        check(applied.lines.first?.contains("reference embedded track 1 (English)") == true,
              "the dialogue track, not the denser commentary", applied.lines.joined(separator: " | "))
        check(!applied.lines.contains { $0.contains("Commentary") }, "the commentary is not even listed", applied.lines.joined(separator: " | "))
        eq(applied.calls.first.map { zip($0.cues, F.cues(F.shift(F.subtitles(film, seed: 94, duration: duration), ratio: 1, offset: 1.8)))
            .allSatisfy { abs($0.start - $1.start - 1.8) < 0.05 } }, true, "and the offset is the dialogue's")

        // Only a commentary as text track, decodable audio: the speech reference is needed.
        let speech = SubtitleAutoSync(schedule: .standard) { _ in }
        speech.configure(tracks: [.init(index: 0, name: "Commentary", isForced: false, isCommentary: true)],
                         audio: .init(renditionIndex: 0, codec: .ac3, audioSpecificConfig: nil, sampleRate: 48_000, channels: 2, codecDelay: 0))
        speech.register(key: "fr", language: "fr", cues: dialogue)
        speech.waitUntilIdle()
        check(speech.wantsAudio, "a commentary track does not stand in for the audio")
    }

    /// A decoder that opens but refuses every unit: the audio reference is given up (and said),
    /// instead of the whole film being copied and refused unit by unit.
    func testDecoderRefusingEveryUnitGivesUp() {
        let applied = Applied()
        let sync = SubtitleAutoSync(schedule: .standard) { applied.lines.append($0) }
        sync.configure(tracks: [], audio: .init(renditionIndex: 0, codec: .ac3, audioSpecificConfig: nil, sampleRate: 48_000,
                                                channels: 2, codecDelay: 0))
        sync.register(key: "fr", language: "fr", cues: [SubtitleCue(start: 1, end: 2, text: "a", settings: nil)])
        sync.waitUntilIdle()
        check(sync.wantsAudio, "a decodable codec: the audio is wanted")
        var rng = SyncFilms.RNG(5)
        for batch in 0..<4 {
            var material = MKVToHLSRemuxSession.SyncMaterial()
            material.audio = (0..<40).map { index in
                let time = Double(batch * 40 + index) * 0.032
                return .init(data: Data((0..<768).map { _ in UInt8(truncatingIfNeeded: rng.next()) }), time: time, duration: 0.032)
            }
            sync.ingest(material, timelineStart: 0)
        }
        sync.waitUntilIdle()
        check(!sync.wantsAudio, "every unit refused: no more audio copied")
        check(applied.lines.contains { $0.hasPrefix("[SubSync] no audio reference: the decoder refuses the ac3 units") },
              "and the log says why", applied.lines.joined(separator: " | "))
    }

    /// A film shorter than the refinement interval: once the remux has read all of it, one more
    /// estimate with what it added — a first one that narrowly failed a gate is retried.
    func testFinalEstimateOnceTheWholeFileIsRead() {
        var plan = SubtitleAutoSyncPlan()
        let first = SubtitleAutoSyncPlan.Reference(kind: .speech, knownSeconds: 230, speechSeconds: 95)
        check(plan.isDue(first), "the first estimate")
        _ = plan.record(estimate(2, confident: false), knownSeconds: 230)
        let whole = SubtitleAutoSyncPlan.Reference(kind: .speech, knownSeconds: 360, speechSeconds: 140)
        check(!plan.isDue(whole), "a 6 min film never reaches the 12 min refinement")
        check(plan.isDue(whole, isComplete: true), "but once the whole file is read, a last estimate is due")
        let outcome = plan.record(estimate(2), knownSeconds: 360)
        eq(outcome.transform?.offset, 2, "and it can apply")
        check(!plan.isDue(whole, isComplete: true), "only once: nothing more to read")

        var barely = SubtitleAutoSyncPlan()
        _ = barely.record(estimate(2, confident: false), knownSeconds: 330)
        check(!barely.isDue(.init(kind: .speech, knownSeconds: 360, speechSeconds: 140), isComplete: true),
              "under a minute more reference: not worth another estimate")

        var short = SubtitleAutoSyncPlan()
        let thin = SubtitleAutoSyncPlan.Reference(kind: .subtitles, knownSeconds: 200, cues: 30)
        check(!short.isDue(thin), "a short film under the first thresholds")
        check(short.isDue(thin, isComplete: true), "gets its estimate once it is all read (the gates still decide)")

        // The coordinator: the remux's end makes it due.
        let duration = 360.0
        let film = F.film(seed: 7, duration: duration)
        check(F.subtitles(film, seed: 101, duration: duration).filter { $0.start < 200 }.count >= 10,
              "(the clip speaks before 200 s)", "\(film.count) utterances")
        let embedded = F.cues(F.subtitles(film, seed: 101, duration: duration))
        var schedule = SubtitleAutoSyncSchedule()
        schedule.firstReferenceSeconds = 100
        schedule.firstReferenceCues = 5
        let applied = Applied()
        let sync = SubtitleAutoSync(schedule: schedule) { applied.lines.append($0) }
        sync.configure(tracks: [.init(index: 1, name: "English", isForced: false)], audio: nil)
        sync.register(key: "fr", language: "fr",
                      cues: F.cues(F.shift(F.subtitles(film, seed: 102, duration: duration), ratio: 1, offset: -1.6)))
        feed(sync, cues: embedded, until: duration)
        let before = sync.plan(forKey: "fr")?.estimates ?? 0
        check(before == 1 && (sync.plan(forKey: "fr")?.lastKnownSeconds ?? 999) <= duration - 60,
              "(the first estimate came early enough)", applied.lines.joined(separator: " | "))
        sync.inputFinished()
        sync.waitUntilIdle()
        let after = sync.plan(forKey: "fr")?.estimates ?? 0
        check(after == before + 1, "the remux's end: one more estimate", applied.lines.joined(separator: " | "))
        sync.inputFinished()
        sync.waitUntilIdle()
        eq(sync.plan(forKey: "fr")?.estimates, before + 1, "told twice: still one")
    }

    func testUnion() {
        eq(SubtitleAutoSync.union([5...6, 0...1, 0.5...2, 2.02...3, 10...10]), [0...3, 5...6, 10...10], "merged and sorted")
    }

    // MARK: The players' rule

    func testRetimeWatch() {
        var watch = SubtitleRetimeWatch()
        check(!watch.needsSelectionCheck, "nothing retimed")
        watch.retimed(key: "fr")
        check(watch.needsSelectionCheck, "a retimed file: the selection is checked")
        watch.selectionChecked(shownKey: "en")
        check(!watch.isRebuildDue, "another subtitle on screen: no rebuild")
        check(watch.needsSelectionCheck, "(still watched: the user may switch back to it)")
        watch.retimed(key: "fr")
        watch.selectionChecked(shownKey: nil)
        check(!watch.isRebuildDue, "no subtitle on screen: no rebuild")
        watch.retimed(key: "fr")
        watch.selectionChecked(shownKey: "fr")
        check(!watch.shouldRebuild(isEligible: false), "not now (recovery, PiP…)")
        check(watch.shouldRebuild(isEligible: true), "then rebuilt")
        check(!watch.shouldRebuild(isEligible: true), "once")
        watch.retimed(key: "fr")
        watch.attached()
        check(!watch.needsSelectionCheck && !watch.isRebuildDue, "a new item loads the corrected file")

        // Retimed while another subtitle is on screen, then the user switches back to it on
        // the same item (which may have read the old file before): rebuilt then.
        var later = SubtitleRetimeWatch()
        later.retimed(key: "fr")
        later.selectionChecked(shownKey: "en")
        check(!later.isRebuildDue, "English on screen: no rebuild")
        check(later.needsSelectionCheck, "but the selection is still watched")
        later.selectionChecked(shownKey: "fr")
        check(later.shouldRebuild(isEligible: true), "back on French: rebuilt with the corrected file")
        later.attached()
        check(!later.needsSelectionCheck, "the new item has it")

        eq(SubtitleRetimeWatch.externalKey(languageTag: "pt-BR", name: "Português (Brasil) (OpenSubtitles)"), "pt-br", "OpenSubtitles rendition")
        eq(SubtitleRetimeWatch.externalKey(languageTag: "fr", name: "Français (forcés)"), nil, "the file's own track")
        eq(SubtitleRetimeWatch.externalKey(languageTag: nil, name: "Français (OpenSubtitles)"), nil, "no language")
    }

    /// The rebuild for a retimed file restores the user's subtitles while the new item loads;
    /// on tvOS AVPlayer then replaced them by its automatic pick once the item was ready (the
    /// forced track of the audio language, else none) while the log said « restored ». The
    /// recovery now compares its picks with what the item shows, at readiness and after the
    /// resume, and selects again those it lost (`MediaSelectionSnapshot.reassert`).
    func testRestoredSelectionLostAtReadinessIsFound() {
        typealias Snapshot = MediaSelectionSnapshot
        eq(Snapshot.drifted(wanted: ["French (OpenSubtitles)", "French"], shown: ["French (OpenSubtitles)", "French"]), [],
           "everything held: nothing to redo")
        eq(Snapshot.drifted(wanted: ["French", "French (OpenSubtitles)"], shown: ["French", "French Forced"]), [1],
           "the OpenSubtitles pick replaced by the forced track: found")
        eq(Snapshot.drifted(wanted: ["French", "French (OpenSubtitles)"], shown: ["French", nil]), [1],
           "replaced by nothing: found")
        eq(Snapshot.drifted(wanted: ["French", nil], shown: ["French", "French Forced"]), [1],
           "subtitles the user had turned off, on again: found")
        eq(Snapshot.drifted(wanted: [String?](), shown: []), [], "no pick (automatic selection kept): nothing")
    }

    // MARK: What the remux session copies

    func testSessionCopiesCuesObservedRangesAndAudio() {
        let stream = RemuxTestStreams.named("subtitles-cues-front")
        guard let opened = open(stream, configure: { $0.collectsSyncMaterial = true; $0.collectsSyncAudio = true }) else { return }
        convertInOrder(opened)
        let material = opened.session.takeSyncMaterial()
        let cues = material.cues[0] ?? []
        check(cues.count >= 55, "the text track's cues", "\(cues.count)")
        check(abs((cues.first?.start ?? -1) - 0.3) < 1e-9, "first cue at 0.3 s", "\(cues.first.map { "\($0.start)" } ?? "none")")
        let union = SubtitleAutoSync.union(material.observed)
        check(union.count == 1 && union[0].lowerBound < 0.1 && union[0].upperBound > 119, "one demuxed range over the whole stream", "\(union)")
        eq(opened.session.syncAudioSource?.codec, .aac, "the DEFAULT AAC track is the audio source")
        check(!material.audio.isEmpty && material.audio.allSatisfy { $0.time.isFinite }, "its access units", "\(material.audio.count)")
        check(opened.session.takeSyncMaterial().observed.count <= 1, "taken: only the open run is left")

        guard let quiet = open(stream) else { return }
        convertInOrder(quiet)
        check(quiet.session.takeSyncMaterial().isEmpty, "nothing copied unless asked")
    }

    // MARK: End to end (PT_SUBSYNC_FIXTURES)

    /// The cues of `file`'s text track `codecID`, as the remux reads them.
    private func embeddedCues(_ path: String, codecID: String) -> [SubtitleCue] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        let demuxer = MatroskaDemuxer(reader: EBMLReader(handle: handle, fileLength: { size }))
        demuxer.assumeFullyDownloaded = true
        guard demuxer.parseHeaders(), let track = demuxer.tracks.first(where: { $0.codecID == codecID }) else { return [] }
        demuxer.trackFilter = [track.number]
        let tick = demuxer.secondsPerTick
        var cues: [SubtitleCue] = []
        while let frames = demuxer.readNextCluster() {
            for frame in frames where frame.trackNumber == track.number {
                if let cue = SubtitleConversion.cue(fromMatroskaBlock: frame.data, codecID: track.codecID, codecPrivate: track.codecPrivate,
                                                    start: Double(frame.timestamp) * tick,
                                                    duration: frame.duration.map { Double($0) * tick }, additions: nil) {
                    cues.append(cue)
                }
            }
        }
        return cues
    }

    private func srt(_ cues: [SubtitleCue], shiftedBy shift: Double) -> String {
        func timestamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start + shift)) --> \(timestamp(cue.end + shift))\n\(SubtitleConversion.plainText(cue.text))\n"
        }.joined(separator: "\n")
    }

    func testEndToEndOnF05() throws {
        guard let folder = ProcessInfo.processInfo.environment["PT_SUBSYNC_FIXTURES"], !folder.isEmpty else {
            throw XCTSkip("set PT_SUBSYNC_FIXTURES to the folder of the format-coverage MKV fixtures (F05_subs.mkv)")
        }
        let film = URL(fileURLWithPath: folder).appendingPathComponent("F05_subs.mkv")
        guard FileManager.default.fileExists(atPath: film.path) else { throw XCTSkip("no F05_subs.mkv in PT_SUBSYNC_FIXTURES") }
        let english = embeddedCues(film.path, codecID: "S_TEXT/ASS")
        eq(english.map(\.start), [1.5, 5.5, 9, 14, 17, 23], "F05's English track")
        RemuxPlayback.subtitleSyncScheduleOverride = .quick
        RemuxPlayback.readsLocalSubtitleFiles = true
        // Late by 2.4 s (moved earlier), then early by 1.3 s (moved later: an offset
        // X-TIMESTAMP-MAP could not carry).
        for shift in [2.4, -1.3] {
            guard let files = temporaryInput(Data(srt(english, shiftedBy: shift).utf8)) else { return }
            let subtitleFile = files.input.deletingLastPathComponent().appendingPathComponent("opensubtitles-fr.srt")
            try FileManager.default.moveItem(at: files.input, to: subtitleFile)

            let remux = RemuxPlayback(localFile: film, streamer: nil)
            remux.startsTicksOnDemand = false
            remux.preferredSubtitleLanguages = ["fr"]
            var retimed: [String] = []
            remux.onExternalSubtitleRetimed = { retimed.append($0) }
            remux.subtitles = [Subtitle(language: "French", link: subtitleFile.absoluteString, ISO639: "fr", rating: 0, format: "srt")]
            defer { remux.stop(); remux.runTick(timer: false) }
            let deadline = Date(timeIntervalSinceNow: 20)
            while (remux.subtitleSync?.plan(forKey: "fr")?.estimates ?? 0) == 0, Date() < deadline {
                remux.runTick()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            remux.subtitleSync?.waitUntilIdle()
            let plan = remux.subtitleSync?.plan(forKey: "fr")
            eq(plan?.applications, 1, "shift \(shift): applied")
            check(abs((plan?.applied?.offset ?? 0) + shift) < 0.05, "shift \(shift): the offset found", "\(plan?.applied.map { "\($0)" } ?? "none")")

            var served: Data?
            let fetched = expectation(description: "sub_fr.vtt")
            remux.externalSubtitleData(forKey: "fr") { served = $0; fetched.fulfill() }
            wait(for: [fetched], timeout: 5)
            let cues = served.map(vttCues) ?? []
            eq(cues.count, english.count, "shift \(shift): every cue served")
            let errors = zip(cues, english).map { abs($0.start - $1.start) }
            check(!errors.isEmpty && errors.allSatisfy { $0 <= 0.05 }, "shift \(shift): sub_fr.vtt within 50 ms of the English track",
                  "\(errors)")
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            eq(retimed, ["fr"], "shift \(shift): the owner is told")
        }
    }
}
