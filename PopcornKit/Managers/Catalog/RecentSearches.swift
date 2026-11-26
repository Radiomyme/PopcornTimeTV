import Foundation

/// The searches the user ran last, most recent first, shown by the search
/// screen before anything is typed. Stored as a plain string array in the
/// defaults it is given (`.standard` in the apps, a throwaway domain in the
/// tests), under the active profile's key: the primary profile keeps the
/// plain key of the searches from before profiles, the others
/// "profile.<id>.recentSearches" (deleted with the profile). A child's
/// profile is not shown what a parent searched.
public struct RecentSearches {

    public static let defaultsKey = "recentSearches"
    /// How many are kept.
    public static let limit = 8

    private let defaults: UserDefaults
    private let profiles: ProfileManager?

    /// - Parameter profiles: whose active profile the searches are; nil:
    ///   the app's (`ProfileManager.shared`).
    public init(defaults: UserDefaults = .standard, profiles: ProfileManager? = nil) {
        self.defaults = defaults
        self.profiles = profiles
    }

    /// The active profile's key, read at each access: a screen kept across
    /// a switch of profiles reads the new one's searches.
    private var storageKey: String {
        return (profiles ?? ProfileManager.shared).scopedKey(RecentSearches.defaultsKey)
    }

    /// Most recent first.
    public var queries: [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    /// Remembers a search that was run (submitted, or a result of it opened).
    public func add(_ query: String) {
        store(RecentSearches.list(queries, adding: query))
    }

    public func remove(_ query: String) {
        let key = RecentSearches.key(query)
        store(queries.filter { RecentSearches.key($0) != key })
    }

    public func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    private func store(_ list: [String]) {
        if list.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(list, forKey: storageKey)
        }
    }

    /// `list` with `query` in front: trimmed, at least two characters, the
    /// same search typed with another case or accents moved up rather than
    /// listed twice, at most `limit` entries.
    public static func list(_ list: [String], adding query: String, limit: Int = RecentSearches.limit) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return list }
        let wanted = key(trimmed)
        return Array(([trimmed] + list.filter { key($0) != wanted }).prefix(max(0, limit)))
    }

    /// What makes two searches the same one.
    static func key(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
