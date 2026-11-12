import Foundation
import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import PopcornTorrent

// Bounded storage, what the user sees (report_4 C3; engine contract:
// SP/bounded2/engine/API.md). Only bounded streams change anything here: in
// full mode (the film fits) `BoundedStorageSession.isBounded` is false, every
// rewind is allowed as before and nothing new is shown.
//
// The user's decision: a rewind further back than what is still on disk is
// BLOCKED — no new download, no hand-off to VLC for a rewind. The players move
// such a seek to the earliest point still available (the same rule on every
// player: tvOS / iOS / macOS, native and VLC) and say why in a short message;
// rewinds inside what is kept stay native (HDR / Dolby Vision / Atmos kept),
// forward seeks are unchanged.

enum BoundedStorageUX {

    // MARK: Strings (every key is in the 7 Localizable.strings tables)

    /// Loading screen, bounded stream: the rewind it gives, in whole minutes
    /// ("~N min"); 0 = not known yet.
    static func loadingNote(minutes: Int) -> String {
        guard minutes > 0 else {
            return NSLocalizedString("BoundedStorage.Loading.Generic",
                                     value: "Limited storage: rewinding will be limited",
                                     comment: "Loading screen: the film is larger than the free space, only part of it stays on disk")
        }
        return String(format: NSLocalizedString("BoundedStorage.Loading.Minutes",
                                                value: "Limited storage: you can rewind about %d min",
                                                comment: "Loading screen: the film is larger than the free space; %d = minutes a rewind can reach"),
                      minutes)
    }

    /// The loading screen's line for `streamer`'s stream; nil in full mode
    /// or before the mode is known. Reads the free space: call it about once
    /// every few seconds at most. Main queue.
    static func loadingNote(for streamer: PTTorrentStreamer?) -> String? {
        guard let session = BoundedStorageSession.session(for: streamer), session.isBounded else { return nil }
        return loadingNote(minutes: session.estimatedRewindMinutes())
    }

    /// A rewind was stopped at the earliest point still on disk.
    static var rewindLimitedMessage: String {
        NSLocalizedString("BoundedStorage.RewindLimited",
                          value: "This part is no longer stored (limited storage).",
                          comment: "Short message over the video: a rewind went further back than what is still on disk")
    }

    /// A rewind was stopped where the file was never downloaded (HTTP
    /// routes: VLC started at a resume point, the gap of a forward seek).
    static var rewindNotDownloadedMessage: String {
        NSLocalizedString("BoundedStorage.RewindNotDownloaded",
                          value: "This part hasn't been downloaded (limited storage).",
                          comment: "Short message over the video: a rewind went back to a part of the film that was never downloaded (limited storage)")
    }

    /// The message for a rewind `session` just limited: deleted data (the
    /// usual case, and any target the user played), or a part never
    /// downloaded.
    static func rewindLimitedMessage(for session: BoundedStorageSession?) -> String {
        session?.isRewindFloorNeverDownloaded == true ? rewindNotDownloadedMessage : rewindLimitedMessage
    }

    /// Native playback can't go on and the hand-off to VLC would need data
    /// that is already deleted.
    static var cannotContinueTitle: String {
        NSLocalizedString("BoundedStorage.CannotContinue.Title", value: "Playback stopped",
                          comment: "Alert title: playback can't continue, the needed part of the film was deleted (limited storage)")
    }

    static var cannotContinueMessage: String {
        NSLocalizedString("BoundedStorage.CannotContinue.Message",
                          value: "This part of the video is no longer stored (limited storage), so playback can't continue here.",
                          comment: "Alert message: playback can't continue, the needed part of the film was deleted (limited storage)")
    }

    /// SF Symbol of the messages.
    static let symbolName = "externaldrive.badge.exclamationmark"

    // MARK: VLC

    /// The option that makes VLC read a Matroska file with libavformat's
    /// demuxer instead of its own (`vlcMediaOptions`).
    static let vlcAVFormatDemuxOption = ":demux=avformat"

    /// VLCKit 4 media options for a bounded Matroska stream (none in full
    /// mode, for other containers, or when `session` is nil: VLC as today).
    ///
    /// VLC's own Matroska demuxer, over HTTP, does not seek through the
    /// Cues: it reads every byte from the last cluster it has seen up to the
    /// target (VLCKit 4.0.0a21; it treats Cues as hints it checks by reading
    /// the clusters, which only a local file makes cheap). Bounded storage
    /// deleted part of those bytes (HTTP 410: VLC stops for good) or never
    /// downloaded them (all of them at download speed). libavformat's
    /// demuxer seeks through the Cues (pinned with the tail) at once: it
    /// reads the head (≤ 30 MB, inside PopcornTorrent's Matroska head pin),
    /// the Cues, then the target. Its cost: the file's own TEXT subtitle
    /// tracks (SRT, ASS/SSA, WebVTT) come with no codec — listed, never
    /// shown (`isUndecodableVLCTrack` keeps them out of the menus; image
    /// subtitles keep theirs) — and the tracks lose their names. OpenSubtitles
    /// subtitles are not affected (a separate input). So libavformat's only
    /// where VLC's own would fail or crawl, or where nothing is lost:
    /// - no text subtitle track in the file (its Tracks, read from the pinned
    ///   head on disk): libavformat's, from the start too — every far seek
    ///   then goes straight to its target;
    /// - text subtitles, opened AT A POSITION (a hand-off from the native
    ///   player, a resume): VLC's own when everything from the head to that
    ///   position is still on disk and nothing was released yet (it reads it
    ///   locally, as in full mode: `ownDemuxerReadsOnlyLocalData`), else
    ///   libavformat's (their subtitles are then lost; the preferred
    ///   language goes to OpenSubtitles);
    /// - text subtitles, from the START: VLC's own (subtitles kept; a far
    ///   forward seek reads everything in between, as in full mode);
    /// - the file's tracks unknown (head unreadable, no `streamer`):
    ///   libavformat's at a position (VLC's own would read deleted data),
    ///   VLC's own from the start.
    static func vlcMediaOptions(url: URL, session: BoundedStorageSession?, startPosition: Float,
                                streamer: PTTorrentStreamer? = nil) -> [String] {
        guard let session = session, session.isBounded, isMatroska(url) else { return [] }
        let name = url.lastPathComponent
        let at = startPosition > 0 ? "at \(Int(startPosition * 100)) %" : "from the start"
        #if DEBUG
        // Measurements (`-PTDebugVLCDemux mkv|avformat`): force one demuxer.
        if let forced = UserDefaults.standard.string(forKey: "PTDebugVLCDemux") {
            print("[Bounded] VLC opens \(name) \(at) with the \(forced) demuxer (forced, DEBUG)")
            return forced == "avformat" ? [vlcAVFormatDemuxOption] : []
        }
        #endif
        let textTracks = streamer.flatMap(localFile(of:)).flatMap(matroskaTextSubtitleTrackCount)
        let useAVFormat: Bool
        let why: String
        switch (textTracks, startPosition > 0) {
        case (0?, _):
            useAVFormat = true; why = "no text subtitle track"
        case (_?, true):
            if let streamer = streamer, ownDemuxerReadsOnlyLocalData(streamer, fraction: startPosition) {
                useAVFormat = false; why = "keeps its \(textTracks ?? 0) text subtitle track(s); everything up to there is on disk"
            } else {
                useAVFormat = true; why = "its \(textTracks ?? 0) text subtitle track(s) are lost: VLC's own demuxer would read deleted or missing data"
            }
        case (_?, false):
            useAVFormat = false; why = "keeps its \(textTracks ?? 0) text subtitle track(s); far seeks read through"
        case (nil, true):
            useAVFormat = true; why = "tracks unknown; VLC's own demuxer would read deleted or missing data"
        case (nil, false):
            useAVFormat = false; why = "tracks unknown"
        }
        print("[Bounded] VLC opens \(name) \(at) with \(useAVFormat ? "libavformat's demuxer (seeks through the Cues)" : "its own demuxer") — \(why)")
        return useAVFormat ? [vlcAVFormatDemuxOption] : []
    }

    /// How much VLC's own demuxer may read from the head to reach a start
    /// position on disk (`ownDemuxerReadsOnlyLocalData`): a local read, a few
    /// seconds on an Apple TV.
    static let ownDemuxerLocalReadLimit: Int64 = 1 << 30

    /// VLC's own Matroska demuxer opened at `fraction` reads the file from
    /// its head to the target: true when that is a local read — nothing
    /// released yet (`lowestAvailableOffset` 0), every byte from the start to
    /// past the target on disk (the target's offset estimated from the
    /// fraction, + 25 % and 64 MiB for a variable bitrate), at most
    /// `ownDemuxerLocalReadLimit`. Main queue.
    static func ownDemuxerReadsOnlyLocalData(_ streamer: PTTorrentStreamer, fraction: Float) -> Bool {
        let size = streamer.fileSize.longLongValue
        guard size > 0, fraction > 0, fraction < 1, streamer.lowestAvailableOffset == 0 else { return false }
        let estimate = Int64(Double(size) * Double(fraction))
        let needed = min(size, estimate + estimate / 4 + (64 << 20))
        return needed <= ownDemuxerLocalReadLimit && streamer.firstMissingOffset(from: 0) >= needed
    }

    /// The streamer's file on disk (its save path + file name, as its
    /// readyToPlay file URL); nil before it is known.
    static func localFile(of streamer: PTTorrentStreamer) -> URL? {
        guard let directory = streamer.savePath, let name = streamer.fileName else { return nil }
        return URL(fileURLWithPath: directory).appendingPathComponent(name)
    }

    /// A Matroska / WebM file name.
    static func isMatroska(_ url: URL) -> Bool {
        ["mkv", "mka", "mk3d", "webm"].contains(url.pathExtension.lowercased())
    }

    /// The text subtitle tracks (SRT, ASS/SSA, WebVTT) in the Tracks of the
    /// Matroska file at `localFile` — read from its head (on disk: the remux
    /// probe or PopcornTorrent's head pin fetched it); nil when it can't be
    /// read (not downloaded yet, not Matroska). A few KB of reads.
    static func matroskaTextSubtitleTrackCount(_ localFile: URL) -> Int? {
        guard localFile.isFileURL, let handle = try? FileHandle(forReadingFrom: localFile) else { return nil }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else { return nil }
        let demuxer = MatroskaDemuxer(reader: EBMLReader(handle: handle, fileLength: { size }))
        guard demuxer.parseHeaders(), !demuxer.tracks.isEmpty else { return nil }
        return demuxer.tracks.filter { $0.kind == .subtitle && MatroskaDemuxer.textSubtitleCodecs.contains($0.codecID) }.count
    }

    /// VLC_CODEC_UNKNOWN ("undf"): the codec of a track no decoder takes —
    /// libavformat's demuxer gives it to Matroska text subtitles. Such a
    /// track is left out of the subtitle menus and the automatic choice
    /// (selecting it shows nothing; the preferred language then goes to
    /// OpenSubtitles).
    static func isUndecodableVLCTrack(codec: UInt32) -> Bool {
        codec == 0x6664_6E75   // VLC_FOURCC('u','n','d','f'), little-endian
    }

    /// VLC's clock steps back by itself just after a start or a seek at a
    /// position (its first estimate is the target, then the keyframe it
    /// decodes from: 2604.0 → 2602.2 s after a hand-off in part 2's run
    /// fhand2, which the time-tick check took for a rewind past the limit —
    /// a forced seek and the message, for nothing). `VLCPlayheadWatch`
    /// ignores backward moves up to this size.
    static let vlcClockJitterSeconds: Double = 5
    /// How long after a seek of its own a VLC player follows its clock
    /// without checking it (`VLCPlayheadWatch`).
    static let vlcSeekSettleSeconds: TimeInterval = 4

    // MARK: Rewind policy

    /// How far past the earliest available point a limited rewind lands:
    /// the remux's earliest point is a segment start, so the seek lands
    /// inside the first kept segment, never on its edge.
    static let landingMarginSeconds: Double = 0.5
    /// A move back of at most this is never limited (`limitedRewindTarget`).
    static let rewindJitterSeconds: Double = 2

    /// Where a seek to `target` from `playhead` (seconds, both on the
    /// calling player's clock: AVPlayer's timeline on the remux route, the
    /// player's own time on the HTTP routes) may go: nil = as asked (a
    /// forward seek, full mode, no limit, or a rewind within what is kept);
    /// else the earliest point still available (never past `playhead`) —
    /// the rewind is limited there. Any thread.
    static func limitedRewindTarget(_ target: Double, from playhead: Double, session: BoundedStorageSession?) -> Double? {
        // A step back of a moment is no rewind: AVPlayer lands a little before
        // a precise seek (1538.0 → 1537.5 s after the direct route's item
        // rebuild, part-3 run imd1: a forced seek and the message, for
        // nothing). The data just played is still there.
        guard target.isFinite, playhead.isFinite, playhead - target > rewindJitterSeconds else { return nil }
        guard let session = session, target < playhead, session.isBounded,
              let earliest = session.earliestRewindTime(fromPlayerTime: playhead), target < earliest else { return nil }
        // HTTP routes: data still on disk before a gap a forward seek left
        // (verify-playback 1): played natively, not limited.
        if session.isRewindTargetOnDisk(target) { return nil }
        session.noteLimitedRewind(target: target)
        return max(0, min(playhead, earliest + landingMarginSeconds))
    }

    /// How far ahead a reverse scan is checked, in seconds of wall time
    /// (`reverseScanLimit`: the players look once a second).
    static let reverseScanLookaheadSeconds: Double = 1.5

    /// A reverse scan — a held rewind: AVPlayer at a negative rate, which
    /// AVKit offers over the direct route's HTTP (Siri Remote, IR remote,
    /// macOS J) — is no time jump: nothing limited it while it ran
    /// (verify-playback 3, Mac rev2 / rev3: it went through deleted data,
    /// AVPlayer got HTTP 410). The players check it every second: where it
    /// must stop (the earliest point still available) once the next
    /// `reverseScanLookaheadSeconds` at `rate` would take it further back
    /// than what is kept; nil while it may go on, for a forward rate, and
    /// outside bounded mode. `playedReference`: the last position playback
    /// reached (a scan does not move it). Main queue.
    static func reverseScanLimit(time: Double, rate: Float, playedReference: Double?,
                                 session: BoundedStorageSession?) -> Double? {
        guard rate < 0, time.isFinite, let reference = playedReference, let session = session, session.isBounded else { return nil }
        let ahead = max(0, time + Double(rate) * reverseScanLookaheadSeconds)
        return limitedRewindTarget(ahead, from: reference, session: session)
    }

    /// The forward rate a stopped reverse scan resumes at: the player's
    /// default rate (the speed the user chose), else 1.
    static func resumeRate(after player: AVPlayer) -> Float {
        if #available(iOS 16.0, tvOS 16.0, macOS 13.0, *), player.defaultRate > 0 { return player.defaultRate }
        return 1
    }

    /// One log line per limited rewind ("[Bounded] …", next to the session's).
    static func logLimited(player: String, target: Double, playhead: Double, landing: Double) {
        print(String(format: "[Bounded] %@: rewind %.1f → %.1f s blocked (no longer stored) — earliest %.1f s",
                     player, playhead, target, landing))
    }
}

/// The VLC players' time-tick safety net for bounded storage: VLC's time
/// went back by a path not limited where it was made (their own seeks and
/// jumps are). A rewind is a move back of more than
/// `BoundedStorageUX.vlcClockJitterSeconds` from the furthest time seen
/// since the player last moved the playhead itself (VLC's own settling
/// after a start or seek, and small steps, never count), outside the
/// `vlcSeekSettleSeconds` after such a move. Main queue (the players' ticks).
struct VLCPlayheadWatch {
    private var reference: Double?
    private var lastOwnSeek: Date?

    /// The player is about to move VLC's playhead itself (a start at a
    /// position, a seek, a jump, a limited rewind).
    mutating func noteOwnSeek(at date: Date = Date()) {
        lastOwnSeek = date
    }

    /// VLC's time is `seconds` now: the time it moved back from when that is
    /// a rewind to check against the limit (then the new reference), else nil.
    mutating func rewind(to seconds: Double, at date: Date = Date()) -> Double? {
        if let seek = lastOwnSeek, date.timeIntervalSince(seek) < BoundedStorageUX.vlcSeekSettleSeconds {
            reference = seconds
            return nil
        }
        guard let previous = reference, seconds < previous else {
            reference = seconds
            return nil
        }
        guard seconds < previous - BoundedStorageUX.vlcClockJitterSeconds else { return nil }
        reference = seconds
        return previous
    }
}

/// A message of the macOS players' overlay (`View.boundedStorageToast`).
struct BoundedStorageToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// How long it stays up.
    static let visibleSeconds: TimeInterval = 4
}

/// SwiftUI: the short message over the video (macOS players).
struct BoundedStorageToast: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: BoundedStorageUX.symbolName)
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Shows `toast` at the top of the view while it is set.
    func boundedStorageToast(_ toast: BoundedStorageToastMessage?) -> some View {
        overlay(alignment: .top) {
            if let toast = toast {
                BoundedStorageToast(message: toast.text)
                    .padding(.top, 52)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toast)
    }
}

#if canImport(UIKit)
/// UIKit: the short message over the video (tvOS and iOS players): a
/// capsule at the top of the player that fades out by itself.
final class BoundedStorageToastView: UIView {

    /// Shows `message` at the top of `container`, replacing the one already
    /// up there (its timer restarts). Main queue.
    static func show(_ message: String, in container: UIView) {
        let toast = container.subviews.lazy.compactMap { $0 as? BoundedStorageToastView }.first ?? install(in: container)
        container.bringSubviewToFront(toast)
        toast.present(message)
    }

    static let visibleSeconds: TimeInterval = 4

    private let label = UILabel()
    private let blur: UIVisualEffectView
    private var hideWork: DispatchWorkItem?

    private static var isTV: Bool { UIDevice.current.userInterfaceIdiom == .tv }

    private static func install(in container: UIView) -> BoundedStorageToastView {
        let toast = BoundedStorageToastView()
        toast.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toast)
        let guide = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            // tvOS: the top is free (the transport bar is at the bottom);
            // iOS: below the close button and AVKit's top controls.
            toast.topAnchor.constraint(equalTo: guide.topAnchor, constant: isTV ? 40 : 64),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 20),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -20),
        ])
        return toast
    }

    private init() {
#if os(tvOS)
        blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
#else
        blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
#endif
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        let isTV = Self.isTV
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.clipsToBounds = true
        blur.layer.cornerCurve = .continuous
        addSubview(blur)

        let font: UIFont = isTV ? .systemFont(ofSize: 29, weight: .semibold)
                                : UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        label.font = font
        label.adjustsFontForContentSizeCategory = !isTV
        label.textColor = .white
        label.numberOfLines = 2
        label.textAlignment = .natural
        let icon = UIImageView(image: UIImage(systemName: BoundedStorageUX.symbolName,
                                              withConfiguration: UIImage.SymbolConfiguration(font: font)))
        icon.tintColor = .white
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = isTV ? 14 : 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)

        let vertical: CGFloat = isTV ? 16 : 10
        let horizontal: CGFloat = isTV ? 30 : 16
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: vertical),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -vertical),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: horizontal),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -horizontal),
        ])
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = isTV ? 16 : 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A capsule (two lines: a rounded rectangle).
        blur.layer.cornerRadius = min(bounds.height / 2, Self.isTV ? 36 : 22)
    }

    private func present(_ message: String) {
        label.text = message
        accessibilityLabel = message
        hideWork?.cancel()
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.4) { self?.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds, execute: work)
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
#endif
