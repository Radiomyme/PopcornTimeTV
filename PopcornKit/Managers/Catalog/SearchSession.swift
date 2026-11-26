import Foundation

/// A live search answered by several sources at once (movies and shows):
/// which query is the current one, which answers still count, and what the
/// page shows meanwhile. Pure — the owner debounces the typing, runs the
/// searches and reports each answer with the token `begin` gave it.
///
/// An answer carrying an older token is dropped: the results of « bat »
/// landing after those of « batman » never replace them.
public struct SearchSession<Kind: Hashable> {

    public enum Phase: Equatable {
        /// Nothing typed (or too little): the page's starting state.
        case idle
        /// Searching, nothing found yet.
        case searching
        /// At least one source found something (`isSearching` while others
        /// are still out).
        case results
        /// Every source answered, none found anything.
        case empty
        /// Nothing found and at least one source failed: its message.
        case failed(String)
    }

    /// Shortest query worth sending while typing (one letter matches half
    /// the catalogue). Submitted (Return), one character is a query: « X »,
    /// « M » and « 9 » are titles.
    public static var minimumLength: Int { 2 }

    /// The query being searched or shown, normalised; "" when idle.
    public private(set) var query = ""
    /// Identifies the current query; goes with every answer.
    public private(set) var token = 0
    public private(set) var phase: Phase = .idle

    private let kinds: Set<Kind>
    private var pending: Set<Kind> = []
    private var found: Set<Kind> = []
    private var errors: [String] = []

    /// The sources of the current query that failed (their messages), even
    /// when another one found something: the page says what is missing, and
    /// the same query may be sent again.
    public private(set) var failures: [Kind: String] = [:]

    /// - Parameter kinds: the sources every query is sent to.
    public init(kinds: [Kind]) {
        self.kinds = Set(kinds)
    }

    /// Some sources have not answered the current query yet.
    public var isSearching: Bool { !pending.isEmpty }

    /// Trimmed, with runs of white space collapsed: « the  wire » and
    /// « the wire  » are the same query.
    public static func normalised(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The field's text (after the debounce, or `submitted` with Return).
    /// Returns the token to search with — nil when there is nothing to send:
    /// too short (the page goes back to `idle`; one character is enough
    /// when submitted), or the query already being searched or shown.
    public mutating func begin(_ text: String, submitted: Bool = false) -> Int? {
        let wanted = Self.normalised(text)
        guard wanted.count >= (submitted ? 1 : Self.minimumLength) else {
            clear()
            return nil
        }
        // The same query again: only one a source failed is worth another
        // try (all its sources are asked again).
        if wanted.caseInsensitiveCompare(query) == .orderedSame {
            guard !isSearching, !failures.isEmpty else { return nil }
        }
        token += 1
        query = wanted
        pending = kinds
        found = []
        errors = []
        failures = [:]
        phase = .searching
        return token
    }

    /// Back to the starting state; answers on their way are dropped.
    public mutating func clear() {
        token += 1
        query = ""
        pending = []
        found = []
        errors = []
        failures = [:]
        phase = .idle
    }

    /// One source's answer. False when it is stale (another query since, or
    /// that source already answered): the caller must not show it.
    @discardableResult
    public mutating func receive(_ kind: Kind, count: Int, error: String?, token answered: Int) -> Bool {
        guard answered == token, pending.remove(kind) != nil else { return false }
        if count > 0 { found.insert(kind) }
        if let error, !error.isEmpty {
            errors.append(error)
            if count == 0 { failures[kind] = error }
        }
        if !found.isEmpty {
            phase = .results
        } else if pending.isEmpty {
            phase = errors.first.map(Phase.failed) ?? .empty
        }
        return true
    }
}

extension SearchSession {

    /// Where the focus goes when the rows of a new answer replace those it
    /// was on (the Apple TV's Search, one row per kind): on the same title
    /// when its row still lists it, otherwise on the first title of its row,
    /// otherwise on the first title of the first row. `focused` is nil when
    /// the focus is not on a title (the keyboard): the first row's first.
    public static func focusAfterReplacing<ID: Equatable>(_ focused: (kind: Kind, id: ID)?,
                                                          rows: [(kind: Kind, items: [ID])]) -> (row: Int, item: Int) {
        guard let focused = focused, let row = rows.firstIndex(where: { $0.kind == focused.kind }) else { return (0, 0) }
        return (row, rows[row].items.firstIndex(of: focused.id) ?? 0)
    }
}
