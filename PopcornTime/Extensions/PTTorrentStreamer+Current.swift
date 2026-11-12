

import Foundation
import PopcornKit
import PopcornTorrent

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

    /// The `selectFileToStream` / `selectFileTDownload` block for `link` (a
    /// magnet or a local .torrent file): the magnet's BEP 53 `so=` file when
    /// valid, else the largest video file — the movie, not a sample — as on
    /// macOS (`PlaybackRouting.fileIndexToStream`). Runs on libtorrent's
    /// alerts thread: pure helpers only.
    static func fileSelection(for link: String) -> PTTorrentStreamerSelection {
        let preferredIndex = Torrent.selectedFileIndex(fromMagnet: link)
        return { @Sendable (fileNames: [String], fileSizes: [NSNumber]) -> Int32 in
            let index = PlaybackRouting.fileIndexToStream(names: fileNames,
                                                          sizes: fileSizes.map { $0.int64Value },
                                                          preferredIndex: preferredIndex)
            if fileNames.count > 1 {
                print("[Streamer] multi-file torrent: file #\(index) of \(fileNames.count)\(preferredIndex.map { " (so=\($0))" } ?? "")")
            }
            return Int32(index)
        }
    }
}
