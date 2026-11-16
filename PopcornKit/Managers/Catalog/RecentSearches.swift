import Foundation

/// The searches the user ran last, most recent first, shown by the search
/// screen before anything is typed. Stored as a plain string array in the
/// defaults it is given (`.standard` in the apps, a throwaway domain in the
/// tests).
public struct RecentSearches {

    public static let defaultsKey = "recentSearches"
    /// How many are kept.
    public static let limit = 8

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Most recent first.
    public var queries: [String] {
        defaults.stringArray(forKey: RecentSearches.defaultsKey) ?? []
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
        defaults.removeObject(forKey: RecentSearches.defaultsKey)
    }

    private func store(_ list: [String]) {
        if list.isEmpty {
            defaults.removeObject(forKey: RecentSearches.defaultsKey)
        } else {
            defaults.set(list, forKey: RecentSearches.defaultsKey)
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
