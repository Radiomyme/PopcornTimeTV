

import Foundation
import UniformTypeIdentifiers

extension URL {

    /// Returns the **MIME** type of the current file. If an error occurs, `"application/octet-stream"` is returned.
    var contentType: String {
        let defaultMime = "application/octet-stream"
        guard !pathExtension.isEmpty else { return defaultMime }
        // UTType (UniformTypeIdentifiers, iOS/tvOS 14+) replaces the legacy
        // `UTTypeCreatePreferredIdentifierForTag` / `UTTypeCopyPreferredTagWithClass`
        // CFString-bridge dance with a typed Swift API.
        return UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? defaultMime
    }
}
