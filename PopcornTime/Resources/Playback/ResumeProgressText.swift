import Foundation
import PopcornKit

// « Resuming at 22:35 — 45% · 9.6 MB/s »: the label under the spinner while the media at a
// position the conversion jumped to is downloaded (a decided start, an answered resume, a far
// jump, a rewind into what a jump skipped). The share of the bytes the player needs there that is
// on disk, and the download rate (`JumpWaitProgress`, refreshed by the remux once a second); the
// rate alone when the bytes needed are not known; « Resuming at 22:35… » alone for the first
// second of a wait. Every key is in the 7 Localizable.strings tables.

extension ResumePolicy {

    /// The label for `position` ("22:35") with `progress` (nil: none known).
    static func resumingText(position: String, progress: JumpWaitProgress?) -> String {
        guard let progress = progress, let detail = resumingDetail(progress) else { return resumingText(position: position) }
        return String(format: NSLocalizedString("Player.Resuming.Detail", value: "Resuming at %1$@ — %2$@",
                                                comment: "Player: under the spinner while the media at a resume point or a jump's target downloads. %1$@ = the position (\"1:40:00\"), %2$@ = how far it is (\"45% · 9.6 MB/s\", or the rate alone)"),
                      position, detail)
    }

    /// "45% · 9.6 MB/s", "9.6 MB/s", "45%"; nil when there is nothing to say yet.
    static func resumingDetail(_ progress: JumpWaitProgress) -> String? {
        var parts: [String] = []
        if let percent = JumpWaitProgressRule.shownPercent(progress) {
            parts.append(String(format: NSLocalizedString("Player.Resuming.Percent", value: "%d%%",
                                                          comment: "Player: the share of the media needed at the resume point already downloaded (\"45%\"; French « 45 % »)"),
                                percent))
        }
        if let rate = JumpWaitProgressRule.shownRate(progress) {
            // The loading screen's formatter ("9.6 MB/s", « 9,6 Mo/s »).
            parts.append(LoadingPhase.formatRate(rate))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The progress of `remuxProgress` when it is the wait for `targetSeconds` (the position the label
    /// shows; nil: the start's resume, whose position the remux places itself), else nil. A progress
    /// for another target (a jump made since) is not shown under this label.
    static func progress(_ remuxProgress: JumpWaitProgress?, forTarget targetSeconds: Double?) -> JumpWaitProgress? {
        guard let progress = remuxProgress else { return nil }
        guard let wanted = targetSeconds, wanted.isFinite else { return progress }
        guard let target = progress.targetSeconds else { return nil }
        return abs(target - wanted) <= progressTargetToleranceSeconds ? progress : nil
    }

    /// How far (s) the label's position and the remux's target may lie apart and still be the same
    /// wait: within a segment (the label shows the user's position, the remux may hold the
    /// segment's start).
    static let progressTargetToleranceSeconds: Double = 12

    /// tvOS: the wait of a jump (a far seek, a rewind into a hole) paused by the user — the
    /// recovery waits for play (`PlaybackStarvationRecovery.isWaitingForPlay`): « Reprise à … »
    /// and its spinner go, the pause shows as a pause (once the media was written the label
    /// said « 100 % » over a spinner for minutes, with nothing telling to press play). Not the
    /// start's resume, under its cover (`isResumingNatively`: its own life).
    static func hidesJumpLabelOnPause(isWaitingForPlay: Bool, isResumingNatively: Bool, isLabelShown: Bool) -> Bool {
        isWaitingForPlay && !isResumingNatively && isLabelShown
    }

    /// tvOS: where AVKit's seek goes after a navigation made while a native resume's item is put
    /// in place, before its start seek (`awaitingStartSeek`, item not ready): the player has no
    /// clock yet — AVKit's proposed target is meaningless (seen: -9223372036854776 s) and its
    /// seek, landing after the resume's, put the film at 0:00. The resume point instead; nil:
    /// the navigation is AVKit's as usual.
    static func startSeekOverride(isResumingNatively: Bool, awaitingStartSeek: Bool, isItemReady: Bool,
                                  resumeTarget: Double?) -> Double? {
        guard isResumingNatively, awaitingStartSeek || !isItemReady,
              let target = resumeTarget, target.isFinite, target >= 0 else { return nil }
        return target
    }
}
