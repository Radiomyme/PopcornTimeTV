

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

public extension String {
    /// The text in the quotation marks of `locale` (by default the UI's
    /// language, the one the sentence around it is in), “ ” when it has
    /// none: « Dune » in French — with the no-break spaces French puts
    /// inside guillemets, as the app's own strings do, so a mark never ends
    /// a line alone.
    func quotedForDisplay(locale: Locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")) -> String {
        let open = locale.quotationBeginDelimiter ?? "“"
        let close = locale.quotationEndDelimiter ?? "”"
        guard open == "«" else { return open + self + close }
        return open + "\u{00A0}" + self + "\u{00A0}" + close
    }
}
