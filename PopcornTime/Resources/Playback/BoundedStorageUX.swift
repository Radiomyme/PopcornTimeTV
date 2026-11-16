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
// rewind is allowed as before and nothing new is shown — except VLC's
// Matroska demuxer (`vlcDemuxChoice`), chosen for every stream: opened at a
// position on a file that is still downloading, VLC needs a demuxer that
// jumps there in full mode as much as in bounded mode.
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

    /// The demuxer VLC reads a Matroska stream with (`vlcDemuxChoice`).
    enum VLCDemux: Equatable {
        /// VLC's own Matroska demuxer (no option). Keeps the file's text
        /// subtitles and the names of its tracks and chapters. Over HTTP it
        /// does not seek through the Cues: it reads every byte from the last
        /// cluster it has seen up to the target.
        case own
        /// libavformat's (`vlcAVFormatDemuxOption`). Seeks through the Cues:
        /// the head, the Cues, then the target. The file's TEXT subtitle
        /// tracks come with no codec (listed, never shown) and the tracks
        /// lose their names.
        case avformat

        /// The VLCKit media options that select it (before the player gets
        /// the media).
        var mediaOptions: [String] {
            switch self {
            case .own: return []
            case .avformat: return [BoundedStorageUX.vlcAVFormatDemuxOption]
            }
        }
    }

    /// Which demuxer VLC opens a stream with, and why (the reason goes to
    /// the "[Bounded] VLC opens …" line). Pure: `vlcMediaOptions` reads the
    /// facts.
    ///
    /// VLC's own Matroska demuxer, over HTTP, does not seek through the
    /// Cues: it reads every byte from the last cluster it has seen up to the
    /// target (VLCKit 4.0.0a21; it treats Cues as hints it checks by reading
    /// the clusters, which only a local file makes cheap). Opened AT A
    /// POSITION on a file that is still downloading, that is the whole file
    /// from its head to the target at download speed — half an hour for a
    /// resume at 1 h 40 of a 9 GB film, whatever the storage mode (5.2.0
    /// only looked at bounded streams) — or, in bounded storage, data that
    /// is already deleted (HTTP 410: VLC stops for good). libavformat's
    /// demuxer seeks through the Cues (pinned with the tail) at once: it
    /// reads the head (≤ 30 MB, inside PopcornTorrent's Matroska head pin),
    /// the Cues, then the target. Its cost: the file's own TEXT subtitle
    /// tracks (SRT, ASS/SSA, WebVTT) come with no codec — listed, never
    /// shown (`isUndecodableVLCTrack` keeps them out of the menus; image
    /// subtitles keep theirs) — and the tracks lose their names. OpenSubtitles
    /// subtitles are not affected (a separate input). So libavformat's only
    /// where VLC's own would fail or crawl, or where nothing is lost.
    ///
    /// AT A POSITION (a resume, a hand-off from the native player), in both
    /// storage modes:
    /// - everything from the head to that position is on disk and nothing
    ///   was released (`ownReadsOnlyLocalData`): VLC's own — a local read,
    ///   the text subtitles are kept. (Bounded storage, a file with no text
    ///   subtitle track or unknown tracks: libavformat's all the same, as
    ///   before — nothing to keep.)
    /// - full storage, everything up to there on disk but more than
    ///   `ownDemuxerLocalReadLimit` to read (`everythingOnDisk`: a native
    ///   film handed over late, its whole head downloaded) and the file has,
    ///   or may have, text subtitle tracks: VLC's own all the same. On such
    ///   a file libavformat's clock is off after the jump (it counts from
    ///   where it landed: 00:23 for 1:10:00, runs S1 / S3 / S4 of
    ///   rs-vlc-demux.md, fixtures in the tvOS simulator), so the bar, the
    ///   scrubs and the saved progress would all be wrong, and the
    ///   subtitles would go; the long local read is covered by the
    ///   « Resuming at … » state. A file with no text track keeps the limit
    ///   (libavformat's clock is right there, and nothing is lost).
    /// - else libavformat's: it goes straight to the target — unless the
    ///   file is known to have no Cues (full storage): nothing jumps then,
    ///   VLC's own reads through and keeps the subtitles.
    ///
    /// From the START:
    /// - full mode: VLC's own, as always (subtitles and names kept; a far
    ///   forward seek reads everything in between);
    /// - bounded storage, no text subtitle track in the file (its Tracks,
    ///   read from the pinned head on disk): libavformat's — every far seek
    ///   then goes straight to its target;
    /// - bounded storage, text subtitles or unknown tracks: VLC's own.
    ///
    /// - Parameters:
    ///   - isMatroska: the stream is a Matroska / WebM file (else VLC as it is).
    ///   - isBounded: the stream runs in bounded storage.
    ///   - startsAtPosition: VLC opens at a position, not at 0:00.
    ///   - textSubtitleTracks: the file's text subtitle tracks; nil = its
    ///     Tracks could not be read.
    ///   - ownReadsOnlyLocalData: `ownDemuxerReadsOnlyLocalData` for the
    ///     start position.
    ///   - everythingOnDisk: the same without `ownDemuxerLocalReadLimit`
    ///     (implied by `ownReadsOnlyLocalData`); only full storage reads it.
    ///   - hasCues: the file has a keyframe index a demuxer can find (nil =
    ///     unknown, taken as « it has one »). Without one no demuxer jumps:
    ///     full storage then keeps VLC's own; the bounded rows do not look
    ///     at it.
    static func vlcDemuxChoice(isMatroska: Bool, isBounded: Bool, startsAtPosition: Bool,
                               textSubtitleTracks: Int?, ownReadsOnlyLocalData: Bool,
                               hasCues: Bool?, everythingOnDisk: Bool = false) -> (VLCDemux, why: String) {
        guard isMatroska else { return (.own, "not a Matroska file") }
        let tracks = textSubtitleTracks ?? 0
        guard isBounded else {
            // Full mode: nothing is ever deleted, so VLC's own demuxer never
            // fails — it only crawls when it must read what is not downloaded.
            guard startsAtPosition else {
                return (.own, "full storage, from the start: far seeks read through")
            }
            if ownReadsOnlyLocalData {
                return (.own, "everything up to there is on disk" + (tracks > 0 ? "; keeps its \(tracks) text subtitle track(s)" : ""))
            }
            if everythingOnDisk, textSubtitleTracks != 0 {
                return (.own, "everything up to there is on disk (past the quick local read: a longer one); "
                              + (tracks > 0 ? "keeps its \(tracks) text subtitle track(s)" : "tracks unknown")
                              + " — libavformat's clock would be off on them")
            }
            if hasCues == false {
                // No index: libavformat's reads the whole file up to the
                // target just as VLC's own does (measured, tvOS simulator:
                // runs N1 / N2 of rs-vlc-demux.md) — nothing to gain, the
                // subtitles and the names to lose.
                return (.own, "no keyframe index (Cues) in the file: no demuxer can jump there, VLC's own reads through"
                              + (tracks > 0 ? " and keeps its \(tracks) text subtitle track(s)" : ""))
            }
            let lost: String
            switch textSubtitleTracks {
            case 0?: lost = "no text subtitle track"
            case let count?: lost = "its \(count) text subtitle track(s) are lost"
            case nil: lost = "tracks unknown"
            }
            return (.avformat, "\(lost): VLC's own demuxer would read the whole file up to there at download speed")
        }
        // Bounded storage: the rows of 5.2.0, as they were.
        switch (textSubtitleTracks, startsAtPosition) {
        case (0?, _):
            return (.avformat, "no text subtitle track")
        case (_?, true):
            if ownReadsOnlyLocalData {
                return (.own, "keeps its \(tracks) text subtitle track(s); everything up to there is on disk")
            }
            return (.avformat, "its \(tracks) text subtitle track(s) are lost: VLC's own demuxer would read deleted or missing data")
        case (_?, false):
            return (.own, "keeps its \(tracks) text subtitle track(s); far seeks read through")
        case (nil, true):
            return (.avformat, "tracks unknown; VLC's own demuxer would read deleted or missing data")
        case (nil, false):
            return (.own, "tracks unknown")
        }
    }

    /// VLCKit 4 media options for a Matroska stream of the app, in both
    /// storage modes: the demuxer `vlcDemuxChoice` picks for a start at
    /// `startPosition` (0…1; a position when the players seek there:
    /// `VLCWatchProgress.seeksAtStart`). None for other containers and when
    /// `session` is nil (not a stream: VLC as it is). One "[Bounded] VLC
    /// opens …" line per call. Main queue.
    static func vlcMediaOptions(url: URL, session: BoundedStorageSession?, startPosition: Float,
                                streamer: PTTorrentStreamer? = nil) -> [String] {
        guard let session = session, isMatroska(url) else { return [] }
        let name = url.lastPathComponent
        // The players' own rule: a start at 0 or at the very end (a finished
        // title) plays from the beginning.
        let startsAtPosition = VLCWatchProgress.seeksAtStart(startPosition)
        let at = startsAtPosition ? "at \(Int(startPosition * 100)) %" : "from the start"
        let isBounded = session.isBounded
        let storage = isBounded ? "bounded" : "full"
        #if DEBUG
        // Measurements: `-PTDebugVLCDemux mkv|avformat|<a VLC demux module>`
        // forces one demuxer, in both storage modes ("mkv" / "own": VLC's
        // own; any other name goes to VLC as ":demux=<name>", e.g.
        // mkv_trusted); `-PTDebugVLCOptions ":opt,:opt=value"` adds raw
        // media options to the choice (e.g. ":mkv-seek-percent").
        let extra = (UserDefaults.standard.string(forKey: "PTDebugVLCOptions") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !extra.isEmpty { print("[Bounded] VLC media options added (forced, DEBUG): \(extra)") }
        if let forced = UserDefaults.standard.string(forKey: "PTDebugVLCDemux"), !forced.isEmpty {
            print("[Bounded] VLC opens \(name) \(at) with the \(forced) demuxer (forced, DEBUG; \(storage) storage)")
            switch forced {
            case "mkv", "own": return extra
            case "avformat": return [vlcAVFormatDemuxOption] + extra
            default: return [":demux=\(forced)"] + extra
            }
        }
        #endif
        let file = streamer.flatMap(localFile(of:))
        let head = file.flatMap(matroskaHead)
        // The Cluster VLC's own demuxer must read up to, from the Cues when
        // they are on disk: a fraction of the size is off by the bitrate's
        // swings (and its margin would refuse a hand-off whose download
        // frontier is just past the playhead).
        let targetOffset = startsAtPosition ? file.flatMap { matroskaClusterOffset($0, fraction: startPosition) } : nil
        let isLocal = startsAtPosition
            && (streamer.map { ownDemuxerReadsOnlyLocalData($0, fraction: startPosition, targetOffset: targetOffset) } ?? false)
        let isOnDisk = isLocal || (startsAtPosition && !isBounded
            && (streamer.map { ownDemuxerReadsOnlyLocalData($0, fraction: startPosition, targetOffset: targetOffset, limit: nil) } ?? false))
        let (demux, why) = vlcDemuxChoice(isMatroska: true, isBounded: isBounded, startsAtPosition: startsAtPosition,
                                          textSubtitleTracks: head?.textSubtitleTracks, ownReadsOnlyLocalData: isLocal,
                                          hasCues: head?.hasCues, everythingOnDisk: isOnDisk)
        let module: String
        switch (demux, head?.hasCues) {
        case (.own, _): module = "its own demuxer"
        case (.avformat, false?): module = "libavformat's demuxer (no Cues in the file: it reads through)"
        case (.avformat, _): module = "libavformat's demuxer (seeks through the Cues)"
        }
        let reach = targetOffset.map { String(format: "; the target's Cluster at %.1f MiB", Double($0) / 1_048_576) } ?? ""
        print("[Bounded] VLC opens \(name) \(at) with \(module) — \(why) (\(storage) storage\(reach))")
        #if DEBUG
        return demux.mediaOptions + extra
        #else
        return demux.mediaOptions
        #endif
    }

    /// How much VLC's own demuxer may read from the head to reach a start
    /// position on disk (`ownDemuxerReadsOnlyLocalData`): a local read, a few
    /// seconds on an Apple TV.
    static let ownDemuxerLocalReadLimit: Int64 = 1 << 30

    /// VLC's own Matroska demuxer opened at `fraction` reads the file from
    /// its head to the target: true when that is a local read — nothing
    /// released yet (`lowestAvailableOffset` 0), every byte from the start to
    /// past the target on disk (the target's offset estimated from the
    /// fraction, + 25 % and 64 MiB for a variable bitrate — or, given,
    /// `targetOffset`, the target's Cluster from the Cues, +
    /// `targetClusterMargin`), at most `limit` (nil: no limit). Main queue.
    static func ownDemuxerReadsOnlyLocalData(_ streamer: PTTorrentStreamer, fraction: Float, targetOffset: UInt64? = nil,
                                             limit: Int64? = ownDemuxerLocalReadLimit) -> Bool {
        ownDemuxerReadsOnlyLocalData(fileSize: streamer.fileSize.longLongValue, fraction: fraction,
                                     lowestAvailableOffset: streamer.lowestAvailableOffset,
                                     firstMissingOffset: streamer.firstMissingOffset(from: 0),
                                     targetOffset: targetOffset, limit: limit)
    }

    /// What must be on disk past the target's Cluster when its offset is
    /// known (`ownDemuxerReadsOnlyLocalData`): that Cluster and the next
    /// few seconds (≈ 2 s at 72 Mb/s) — what VLC decodes from to the target.
    static let targetClusterMargin: Int64 = 16 << 20

    /// The rule of `ownDemuxerReadsOnlyLocalData(_:fraction:)` on the
    /// torrent's numbers: the file's size, the lowest offset still on disk,
    /// the first byte missing from the head and, when the Cues give it, the
    /// offset of the target's Cluster. Pure.
    static func ownDemuxerReadsOnlyLocalData(fileSize size: Int64, fraction: Float, lowestAvailableOffset: Int64,
                                             firstMissingOffset: Int64, targetOffset: UInt64? = nil,
                                             limit: Int64? = ownDemuxerLocalReadLimit) -> Bool {
        guard size > 0, fraction > 0, fraction < 1, lowestAvailableOffset == 0 else { return false }
        let needed: Int64
        if let offset = targetOffset, offset < UInt64(size) {
            needed = min(size, Int64(offset) + targetClusterMargin)
        } else {
            let estimate = Int64(Double(size) * Double(fraction))
            needed = min(size, estimate + estimate / 4 + (64 << 20))
        }
        return needed <= (limit ?? .max) && firstMissingOffset >= needed
    }

    /// The offset of the Cluster that holds the last indexed keyframe at or
    /// before `fraction` of the Matroska file at `localFile` (its video
    /// track's Cues, its length from the Segment Info); nil when the Cues or
    /// the length are not on disk or not there. Reads the head and the Cues
    /// (a few MB at most).
    static func matroskaClusterOffset(_ localFile: URL, fraction: Float) -> UInt64? {
        guard fraction > 0, fraction < 1, localFile.isFileURL,
              let handle = try? FileHandle(forReadingFrom: localFile) else { return nil }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else { return nil }
        let demuxer = MatroskaDemuxer(reader: EBMLReader(handle: handle, fileLength: { size }))
        guard demuxer.parseHeaders(), demuxer.durationSeconds > 0,
              let track = (demuxer.tracks.first { $0.kind == .video } ?? demuxer.tracks.first)?.number,
              case .available = demuxer.loadCueIndex(trackNumber: track) else { return nil }
        let ticks = Int64(Double(fraction) * demuxer.durationSeconds / demuxer.secondsPerTick)
        return demuxer.cueEntries.last { $0.ticks <= ticks }?.clusterOffset
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

    /// What `vlcDemuxChoice` needs from a Matroska file's head.
    struct MatroskaHead: Equatable {
        /// Its text subtitle tracks (SRT, ASS/SSA, WebVTT).
        let textSubtitleTracks: Int
        /// It has a keyframe index (Cues) a demuxer can find: listed in a
        /// SeekHead, or met before the first Cluster. false only when that
        /// is certain; nil: not known (the SeekHead that would list it, or
        /// the elements before the first Cluster, are not downloaded).
        let hasCues: Bool?
    }

    /// The Tracks and the place of the Cues of the Matroska file at
    /// `localFile` — read from its head (on disk: the remux probe or
    /// PopcornTorrent's head pin fetched it); nil when it can't be read (not
    /// downloaded yet, not Matroska). A few KB of reads; the Cues themselves
    /// are read only in the rare file whose first SeekHead does not list
    /// them (mkvmerge's second SeekHead, at the end of the file).
    static func matroskaHead(_ localFile: URL) -> MatroskaHead? {
        guard localFile.isFileURL, let handle = try? FileHandle(forReadingFrom: localFile) else { return nil }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else { return nil }
        let demuxer = MatroskaDemuxer(reader: EBMLReader(handle: handle, fileLength: { size }))
        guard demuxer.parseHeaders(), !demuxer.tracks.isEmpty else { return nil }
        let textTracks = demuxer.tracks.filter { $0.kind == .subtitle && MatroskaDemuxer.textSubtitleCodecs.contains($0.codecID) }.count
        return MatroskaHead(textSubtitleTracks: textTracks, hasCues: hasFindableCues(demuxer))
    }

    /// `MatroskaHead.hasCues` for a demuxer whose headers were just parsed.
    private static func hasFindableCues(_ demuxer: MatroskaDemuxer) -> Bool? {
        if demuxer.cuesPosition != nil { return true }   // the first SeekHead lists them
        // Not listed: the elements between the headers and the first Cluster
        // (where ffmpeg's reserved index space puts them), by their headers.
        var position = demuxer.reader.offset
        var reachedFirstCluster = false
        walk: for _ in 0..<64 {
            guard case let .element(id, elementSize, headerLength) = demuxer.reader.header(at: position) else { break }
            switch id {
            case MatroskaDemuxer.ID.cues: return true
            case MatroskaDemuxer.ID.cluster: reachedFirstCluster = true; break walk
            default:
                guard elementSize != UInt64.max else { break walk }
                position += UInt64(headerLength) + elementSize
            }
        }
        // A second SeekHead may list them (only a definite « no Cues
        // element » counts as none).
        let track = demuxer.tracks.first { $0.kind == .video }?.number ?? demuxer.tracks[0].number
        let index = demuxer.loadCueIndex(trackNumber: track)
        if demuxer.cuesPosition != nil { return true }
        if case .notYet = index { return nil }
        return reachedFirstCluster ? false : nil
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

    /// One log line per limited rewind ("[Bounded] …", next to the session's),
    /// with the reason its message gives (`rewindLimitedMessage(for:)`).
    static func logLimited(player: String, target: Double, playhead: Double, landing: Double,
                           session: BoundedStorageSession?) {
        let why = session?.isRewindFloorNeverDownloaded == true ? "never downloaded" : "no longer stored"
        print(String(format: "[Bounded] %@: rewind %.1f → %.1f s blocked (%@) — earliest %.1f s",
                     player, playhead, target, why, landing))
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
