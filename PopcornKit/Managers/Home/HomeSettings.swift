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
/// - `popcornkit.tmdb.apiKey` — String, the user's own TMDB key (a v3 API
///   key or a v4 read access token). The app ships none: TMDB revoked the
///   one it had. Absent: no "On Netflix" shelves.
/// - `popcornkit.home.streamingRegion` — String, ISO 3166-1 code ("FR"):
///   the country whose catalogues the streaming shelves show. Absent: the
///   device's region.
/// - `popcornkit.home.streamingServices` — Data, the JSON of the services
///   chosen (`[StreamingService]`), in the page's order. Absent:
///   `StreamingService.defaults`. An empty list: no « Services » row.
/// - `popcornkit.home.serviceFilter` — Int, the TMDB id of the service the
///   Apple TV's Home is filtered on (its « Services » row). Absent: the
///   usual page.
public struct HomeSettings {

    public enum Key {
        public static let contentLanguages = "popcornkit.home.contentLanguages"
        /// The library's key (`Library.isBulkEpisodeLookupEnabled`).
        public static let sendsFollowedShows = Library.bulkEpisodeLookupKey
        public static let hiddenShelves = "popcornkit.home.hiddenShelves"
        public static let tmdbAPIKey = "popcornkit.tmdb.apiKey"
        public static let streamingRegion = "popcornkit.home.streamingRegion"
        public static let streamingServices = "popcornkit.home.streamingServices"
        public static let serviceFilter = "popcornkit.home.serviceFilter"
    }

    private let defaults: UserDefaults
    private let deviceLanguages: () -> [String]
    private let deviceRegion: () -> String?

    /// - Parameter deviceLanguages: the device's languages, preferred first
    ///   ("fr-FR", "en-US"): `Locale.preferredLanguages` in production.
    /// - Parameter deviceRegion: the device's region ("FR"):
    ///   `Locale.current`'s in production.
    public init(defaults: UserDefaults = .standard,
                deviceLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
                deviceRegion: @escaping () -> String? = { Locale.current.region?.identifier }) {
        self.defaults = defaults
        self.deviceLanguages = deviceLanguages
        self.deviceRegion = deviceRegion
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

    // MARK: Streaming services

    /// The user's TMDB key, nil when none was given.
    public var tmdbAPIKey: String? {
        get {
            guard let key = defaults.string(forKey: Key.tmdbAPIKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else { return nil }
            return key
        }
        nonmutating set {
            let key = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if key.isEmpty { defaults.removeObject(forKey: Key.tmdbAPIKey) } else { defaults.set(key, forKey: Key.tmdbAPIKey) }
        }
    }

    /// The country of the streaming catalogues: the one chosen, else the
    /// device's region, else the United States.
    public var streamingRegion: String {
        get {
            for candidate in [defaults.string(forKey: Key.streamingRegion), deviceRegion()] {
                if let code = candidate.flatMap(HomeSettings.regionCode) { return code }
            }
            return "US"
        }
        nonmutating set {
            if let code = HomeSettings.regionCode(newValue) { defaults.set(code, forKey: Key.streamingRegion) }
        }
    }

    /// "fr" → "FR"; nil for anything that is not two letters ("150", "").
    static func regionCode(_ text: String) -> String? {
        let code = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return code
    }

    /// The services that have a shelf, in the page's order.
    public var streamingServices: [StreamingService] {
        get {
            guard let data = defaults.data(forKey: Key.streamingServices),
                  let services = try? JSONDecoder().decode([StreamingService].self, from: data) else {
                return StreamingService.defaults
            }
            var seen = Set<Int>()
            return services.filter { seen.insert($0.id).inserted }
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Key.streamingServices) }
        }
    }

    /// The services the « Services » row and the grids' filter offer:
    /// none without a TMDB key.
    public var streamingShelves: [StreamingService] {
        return tmdbAPIKey == nil ? [] : streamingServices
    }

    /// The TMDB id of the service the Home is filtered on, nil for none.
    public var homeServiceFilter: Int? {
        get { (defaults.object(forKey: Key.serviceFilter) as? NSNumber)?.intValue }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Key.serviceFilter) } else { defaults.removeObject(forKey: Key.serviceFilter) }
        }
    }

    /// The service the Home shows, when it is still one of the services
    /// offered (a key removed, a service unchecked: the usual page).
    public var homeService: StreamingService? {
        guard let id = homeServiceFilter else { return nil }
        return streamingShelves.first { $0.id == id }
    }
}
