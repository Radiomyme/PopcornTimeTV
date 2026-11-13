

import Foundation
import PopcornKit
import PopcornTorrent

// (Also in the Mac target, for `fileSelection` only.)

#if !os(macOS)
/// One torrent stream at a time on iOS / tvOS, as with the `sharedStreamer`
/// singleton of the CocoaPods PopcornTorrent these apps used before.
///
/// The SPM PopcornTorrent (the package macOS uses too) has no singleton, and
/// one of its streamers must not be reused for another torrent: it keeps the
/// file index it selected for good. So every stream gets a NEW streamer from
/// `startNew()`, which cancels the one before it if it still runs, and the
/// code that stops "the" stream without holding it — the purge before a new
/// stream, the iOS detail page's « Annuler » and cover dismissal — reaches it
/// through `current`. Players and loading screens keep cancelling the
/// instance they were handed. Main thread only.
extension PTTorrentStreamer {

    private static var currentStreamer: PTTorrentStreamer?

    /// The stream in progress — or the last one, maybe already cancelled.
    /// Never a `PTTorrentDownload`: downloads are not streams.
    static var current: PTTorrentStreamer? { currentStreamer }

    /// Cancels the current stream; `deleteData` also deletes its partial.
    /// Cancelling a stream again (its player already did) is harmless.
    static func cancelCurrent(deleteData: Bool) {
        currentStreamer?.cancelStreamingAndDeleteData(deleteData)
    }

    /// A new streamer for the next stream, made current. The previous stream
    /// is cancelled first, its partial kept: deleting it is the caller's
    /// purge (`cancelCurrent(deleteData: true)`, then
    /// `purgeOrphanTorrentDownloads()`).
    static func startNew() -> PTTorrentStreamer {
        cancelCurrent(deleteData: false)
        let streamer = PTTorrentStreamer()
        currentStreamer = streamer
        return streamer
    }
}
#endif

extension PTTorrentStreamer {

    /// The `selectFileToStream` / `selectFileTDownload` block for `link` (a
    /// magnet or a local .torrent file) played for `wanted` (an episode, from
    /// `WantedFile(media:torrent:)`), on every platform:
    /// - in a multi-file torrent, the wanted file (`WantedFile.choice`): an
    ///   episode's file in a season pack — the one the source names
    ///   (Time4Popcorn's `file`), the magnet's `so=`, else the video file
    ///   named after the episode ("S01E03", "1x03"); NO file when the pack
    ///   lacks the episode: the stream (or download) then fails with
    ///   PopcornTorrent's "not in this torrent" error
    ///   (`PTTorrentStreamerErrorNoFileSelected`) instead of playing another
    ///   episode;
    /// - otherwise (single-file torrents, movies, single-episode releases)
    ///   the magnet's BEP 53 `so=` file when valid, else the largest video
    ///   file — not a sample (`PlaybackRouting.fileIndexToStream`).
    /// The block runs on libtorrent's alerts thread: pure helpers only.
    static func fileSelection(for link: String, wanted: WantedFile? = nil, log: String = "[Streamer]") -> PTTorrentStreamerSelection {
        let preferredIndex = Torrent.selectedFileIndex(fromMagnet: link)
        let torrentName = MagnetLink.displayName(of: link)
        #if DEBUG
        let target = StreamFileDebug.wanted ?? wanted
        #else
        let target = wanted
        #endif
        return { @Sendable (fileNames: [String], fileSizes: [NSNumber]) -> Int32 in
            let sizes = fileSizes.map { $0.int64Value }
            let choice = target?.choice(fileNames: fileNames, fileSizes: sizes, preferredIndex: preferredIndex,
                                        torrentName: torrentName) ?? .usualRule
            let index: Int32
            switch choice {
            case .file(let file):
                index = Int32(file)
            case .notInTorrent:
                index = PTTorrentStreamerNoFileIndex
            case .usualRule:
                index = Int32(PlaybackRouting.fileIndexToStream(names: fileNames, sizes: sizes, preferredIndex: preferredIndex))
            }
            if fileNames.count > 1 {
                let picked = index >= 0 && Int(index) < fileNames.count ? "file #\(index) \(fileNames[Int(index)])" : "no file"
                print("\(log) multi-file torrent: \(picked) of \(fileNames.count)"
                      + (preferredIndex.map { " (so=\($0))" } ?? "")
                      + (target.map { " for \($0): \(choice)" } ?? ""))
            }
            return index
        }
    }

    /// `fileSelection(for:wanted:)` for `media` played from `torrent`
    /// (`WantedFile(media:torrent:)`: an episode's numbers, the source's
    /// file name).
    static func fileSelection(for link: String, media: Media, torrent: Torrent?,
                              log: String = "[Streamer]") -> PTTorrentStreamerSelection {
        return fileSelection(for: link, wanted: WantedFile(media: media, torrent: torrent), log: log)
    }
}

#if DEBUG
/// Offline checks of the season-pack selection (the DEBUG players play
/// placeholder movies: BoundedStorageDebugHooks' `-PTDebugPlayTorrent`).
/// Launch arguments, instead of what the media and torrent say:
/// - `-PTDebugWantedEpisode S01E03`: the episode wanted;
/// - `-PTDebugWantedFile <file name>`: the source's name for its file.
enum StreamFileDebug {
    static var wanted: WantedFile? {
        let defaults = UserDefaults.standard
        let file = defaults.string(forKey: "PTDebugWantedFile")
        var season: Int?, episode: Int?
        if let marker = defaults.string(forKey: "PTDebugWantedEpisode")?.lowercased(),
           let e = marker.firstIndex(of: "e"), marker.hasPrefix("s") {
            season = Int(marker[marker.index(after: marker.startIndex)..<e])
            episode = Int(marker[marker.index(after: e)...])
        }
        return WantedFile(season: season, episode: episode, fileName: file)
    }
}
#endif
