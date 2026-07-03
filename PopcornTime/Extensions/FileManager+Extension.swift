

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
