

import Foundation

extension Bundle {

    /// "5.1.0 (2)": `CFBundleShortVersionString` and, in parentheses,
    /// `CFBundleVersion`, written as is (never with the locale's separators).
    var displayVersion: String {
        Bundle.displayVersion(short: object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                              build: object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// "5.1.0 (2)"; "5.1.0" without a build; "?" without a version.
    static func displayVersion(short: String?, build: String?) -> String {
        let version = short.flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }
}
