

import Foundation

extension FileManager {
    func fileSize(atPath path: String) -> Int64 {
        // `attributesOfItem` returns `[FileAttributeKey: Any]` — the .size
        // value is bridged from NSNumber, so we go through `as? NSNumber`
        // (which can fail) instead of `as! Int64` (which never produces nil
        // — the warning).
        guard let attrs = try? attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
    
    /// Bytes the file or folder at `path` takes on disk: allocated blocks,
    /// not logical sizes (a stream's file is a hole at its full size, and
    /// bounded storage punches out what it consumed).
    func allocatedSize(atPath path: String) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let url = URL(fileURLWithPath: path)
        func size(of file: URL) -> Int64 {
            let values = try? file.resourceValues(forKeys: keys)
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return size(of: url) }
        var total: Int64 = 0
        if let enumerator = enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let file as URL in enumerator { total += size(of: file) }
        }
        return total
    }

    func folderSize(atPath path: String) -> Int64 {
        var size: Int64 = 0
        do {
            for file in try subpathsOfDirectory(atPath: path) {
                size += fileSize(atPath: (path as NSString).appendingPathComponent(file) as String)
            }
        } catch {
            print("Error reading directory.")
        }
        return size
    }
}
