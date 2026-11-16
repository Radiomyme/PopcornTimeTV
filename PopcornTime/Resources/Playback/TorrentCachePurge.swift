import Foundation

/// The purge of what earlier streams left in the temporary directory —
/// torrent partials under `Downloads/<hash>/` and remux output under
/// `remux-XXXX/` (`purgeOrphanTorrentDownloads()`) — in two steps, so that
/// it no longer holds the main thread:
///
/// 1. `setAside`: every leftover is RENAMED into a `purged-<uuid>/` folder.
///    A rename on the same volume is immediate, and it is done when the
///    call returns: the stream that starts next finds neither its torrent's
///    previous folder nor an old HLS copy, and what it creates under the
///    same names is its own.
/// 2. `deleteSetAside`: those folders are deleted, off the main thread.
///
/// Before, the purge enumerated every file for its size (for one log line)
/// and deleted everything synchronously on the main thread, at launch and
/// between the press on Play and the stream's start: an HLS copy a crash
/// left holds thousands of segments. Deleting in the background without the
/// rename would not do: the next stream of the same torrent recreates the
/// very folder being deleted.
enum TorrentCachePurge {

    /// Name prefix of the folders the leftovers are moved into.
    static let trashPrefix = "purged-"

    /// Deletions run one at a time, off the main thread.
    static let queue = DispatchQueue(label: "popcorn.cache-purge", qos: .utility)

    /// Step 1. Returns the folder the leftovers of `temporaryDirectory` were
    /// moved into, nil when there was none.
    @discardableResult
    static func setAside(in temporaryDirectory: URL, fileManager fm: FileManager = .default) -> URL? {
        let trash = temporaryDirectory.appendingPathComponent(trashPrefix + UUID().uuidString, isDirectory: true)
        var moved = 0
        func move(_ source: URL, as name: String) {
            do {
                if moved == 0 { try fm.createDirectory(at: trash, withIntermediateDirectories: true) }
                try fm.moveItem(at: source, to: trash.appendingPathComponent(name))
                moved += 1
            } catch {
                // Not renamed (it should not happen within one volume):
                // deleted in place, as the purge always did.
                try? fm.removeItem(at: source)
            }
        }
        // Torrent partials: Downloads/<hash>/…
        let downloads = temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
        for entry in (try? fm.contentsOfDirectory(atPath: downloads.path)) ?? [] {
            move(downloads.appendingPathComponent(entry), as: "Downloads-" + entry)
        }
        // Orphaned remux output: remux-XXXX/ (left when the player crashed
        // before `RemuxPlayback.stop()` ran).
        for entry in (try? fm.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? [] where entry.hasPrefix("remux-") {
            move(temporaryDirectory.appendingPathComponent(entry), as: entry)
        }
        return moved > 0 ? trash : nil
    }

    /// Step 2. Deletes every `purged-*` folder of `temporaryDirectory` — this
    /// run's and any a crash left before it was deleted — and returns the
    /// bytes they held on disk.
    @discardableResult
    static func deleteSetAside(in temporaryDirectory: URL, fileManager fm: FileManager = .default) -> Int64 {
        var freed: Int64 = 0
        for entry in (try? fm.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? [] where entry.hasPrefix(trashPrefix) {
            let folder = temporaryDirectory.appendingPathComponent(entry, isDirectory: true)
            freed += allocatedSize(of: folder, fileManager: fm)
            try? fm.removeItem(at: folder)
        }
        return freed
    }

    /// Allocated bytes, not logical sizes: a stream's file is created at its
    /// final size (a hole) and bounded storage punches out what it consumed
    /// — the logical size of a 13 GB film says nothing of what deleting it
    /// frees (verify-storage F4: "freed 13 GB" for 1-2 GB really freed).
    static func allocatedSize(of directory: URL, fileManager fm: FileManager = .default) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: keys)
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
