

import Foundation

/// Reclaim disk from the two caches that otherwise leak — especially after a
/// crash, and on BOTH the tvOS and iOS/macOS builds:
///
///   • torrent partials under `NSTemporaryDirectory()/Downloads/<hash>/`
///     (PTTorrentStreamer never cleans them itself), and
///   • remux fMP4 output under `NSTemporaryDirectory()/remux-XXXX/`
///     (RemuxPlayback only deletes its own folder on a clean `stop()`; a crash
///     orphans the whole remuxed copy — up to another ~14 GB for a 4K film,
///     which is why usage could hit ~2× the movie size).
///
/// Call this on app launch (tvOS `AppDelegate`, iOS `PopcornTimeApp.init`) and
/// before each new stream (`Media.play` on tvOS, `MediaDetailView.play` on
/// iOS). Safe before playback: the *new* remux folder is created afterwards and
/// any previous player was already torn down, so only orphans are removed.
///
/// The leftovers are out of the way when this returns (renamed aside:
/// `TorrentCachePurge.setAside`), and deleted right after on a background
/// queue — the main thread no longer enumerates and deletes thousands of
/// files at launch and between Play and the stream's start. Their space is
/// thus reclaimed a moment later: a caller that needs it at once (the retry
/// after a « not enough space » failure) passes `waitsForDeletion`.
func purgeOrphanTorrentDownloads(waitsForDeletion: Bool = false) {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    TorrentCachePurge.setAside(in: tmp)
    let delete = {
        let freed = TorrentCachePurge.deleteSetAside(in: tmp)
        if freed > 0 {
            print("[Cache] purged stale torrent/remux caches (freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))")
        }
    }
    if waitsForDeletion {
        // After any deletion already queued (they run one at a time).
        TorrentCachePurge.queue.sync(execute: delete)
    } else {
        TorrentCachePurge.queue.async(execute: delete)
    }
}
