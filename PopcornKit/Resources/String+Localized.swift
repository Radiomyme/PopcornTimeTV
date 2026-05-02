

import Foundation

public extension String {
    /// Returns this string localized through the main bundle (or PopcornKit's
    /// own bundle if no app-level localization is found). Public so PopcornKit
    /// can use it inside default argument values of public APIs.
    var localized: String {
        let main = Bundle.main.localizedString(forKey: self, value: nil, table: nil)
        if main != self { return main }
        return Bundle(for: TraktManager.self).localizedString(forKey: self, value: self, table: nil)
    }
}
