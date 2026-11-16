import Foundation

/// The hub's settings, read and written through the `UserDefaults` it is
/// given (the app's standard ones in production, a scratch suite in tests).
///
/// Keys:
///
/// - `popcornkit.home.contentLanguages` — [String], ISO 639-1 codes ("en",
///   "fr"). The shelves made of YTS, TVMaze and apibay keep the titles whose
///   original language is one of these (46 % of YTS's additions and 30 % of
///   the popular scheduled shows are in other languages). Absent: English,
///   French and the device's language. An empty array: every language.
/// - `libraryBulkEpisodeLookup` (`Library.bulkEpisodeLookupKey`) — Bool.
///   "New Episodes of Your Shows" asks Cinemeta for the episodes of the
///   shows the user follows: their IMDb ids go to Cinemeta in ONE request
///   (public ids, no account, but the whole list at once). False: that
///   request is never made and the shelf only shows what the library knows
///   by itself. Absent / true: made. The library's own key, not one of the
///   hub's: its refresh of the airings sends the same list to the same
///   host, and one choice of the user covers both (the library then asks
///   TVMaze show by show). In the apps the request is the library's alone
///   (`HomeLocalHooks(library:)`); the hub makes it for hooks that give
///   `followedShowIds`.
/// - `popcornkit.home.hiddenShelves` — [String], ids of the shelves the user
///   hid (`HomeShelfID`). Absent: none.
public struct HomeSettings {

    public enum Key {
        public static let contentLanguages = "popcornkit.home.contentLanguages"
        /// The library's key (`Library.isBulkEpisodeLookupEnabled`).
        public static let sendsFollowedShows = Library.bulkEpisodeLookupKey
        public static let hiddenShelves = "popcornkit.home.hiddenShelves"
    }

    private let defaults: UserDefaults
    private let deviceLanguages: () -> [String]

    /// - Parameter deviceLanguages: the device's languages, preferred first
    ///   ("fr-FR", "en-US"): `Locale.preferredLanguages` in production.
    public init(defaults: UserDefaults = .standard,
                deviceLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.deviceLanguages = deviceLanguages
    }

    /// English, French and the device's first language.
    public static func defaultLanguages(device: [String]) -> [String] {
        var languages = ["en", "fr"]
        if let code = device.first.flatMap(HomeLanguages.code(ofIdentifier:)), !languages.contains(code) {
            languages.append(code)
        }
        return languages
    }

    /// ISO 639-1 codes of the languages the shelves keep; []: all of them.
    public var contentLanguages: [String] {
        get {
            guard let stored = defaults.array(forKey: Key.contentLanguages) as? [String] else {
                return HomeSettings.defaultLanguages(device: deviceLanguages())
            }
            var seen = Set<String>()
            return stored.compactMap(HomeLanguages.code(ofIdentifier:)).filter { seen.insert($0).inserted }
        }
        nonmutating set { defaults.set(newValue, forKey: Key.contentLanguages) }
    }

    /// Back to English, French and the device's language.
    public func resetContentLanguages() {
        defaults.removeObject(forKey: Key.contentLanguages)
    }

    /// The list of followed shows may be sent to Cinemeta in one request
    /// (feeds-live §5.7). On by default; the setting is an opt-out, and the
    /// same stored value as `Library.isBulkEpisodeLookupEnabled`.
    public var sendsFollowedShowsToCinemeta: Bool {
        get { (defaults.object(forKey: Key.sendsFollowedShows) as? NSNumber)?.boolValue ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.sendsFollowedShows) }
    }

    /// Ids of the shelves the user hid.
    public var hiddenShelves: Set<String> {
        get { Set((defaults.array(forKey: Key.hiddenShelves) as? [String]) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Key.hiddenShelves) }
    }

    public func setShelf(_ id: String, hidden: Bool) {
        var shelves = hiddenShelves
        if hidden { shelves.insert(id) } else { shelves.remove(id) }
        hiddenShelves = shelves
    }
}
