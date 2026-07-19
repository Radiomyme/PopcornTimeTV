

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
/// Lives in its own file (added to every app target) and computes sizes inline
/// so it has no cross-target dependency.
func purgeOrphanTorrentDownloads() {
    let fm = FileManager.default
    let tmp = NSTemporaryDirectory() as NSString
    var freed: Int64 = 0

    func directorySize(_ path: String) -> Int64 {
        guard let en = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let sub as String in en {
            let attrs = try? fm.attributesOfItem(atPath: (path as NSString).appendingPathComponent(sub))
            total += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    // 1. Torrent partials: Downloads/<hash>/…
    let downloads = tmp.appendingPathComponent("Downloads")
    if fm.fileExists(atPath: downloads) {
        for entry in (try? fm.contentsOfDirectory(atPath: downloads)) ?? [] {
            let p = (downloads as NSString).appendingPathComponent(entry)
            freed += directorySize(p)
            try? fm.removeItem(atPath: p)
        }
    }

    // 2. Orphaned remux output: remux-XXXX/ (leaks when the player crashes
    //    before RemuxPlayback.stop() runs).
    for entry in (try? fm.contentsOfDirectory(atPath: tmp as String)) ?? [] where entry.hasPrefix("remux-") {
        let p = tmp.appendingPathComponent(entry)
        freed += directorySize(p)
        try? fm.removeItem(atPath: p)
    }

    if freed > 0 {
        print("[Cache] purged stale torrent/remux caches (freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))")
    }
}
