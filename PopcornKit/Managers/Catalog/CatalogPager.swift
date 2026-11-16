import Foundation

/// The pages of one catalogue grid (Movies, Shows): which page to ask for
/// next, what an answer does to the list, and when the list is at its end.
/// A plain value with no clock, no network and no UI, so its rules are
/// unit-tested (`CatalogPagerTests`); a grid only runs the requests it hands
/// out and gives the answers back.
///
/// The rules it holds:
/// - an answer is applied only to the list it was asked for (`generation`):
///   one that lands after another filter was picked, or after a newer
///   refresh, is dropped;
/// - a refresh keeps the list on screen until its first page arrives, and an
///   empty or failed refresh never replaces a list that has titles;
/// - a new list may show the first page saved by an earlier load while the
///   network's is on its way (`receiveSnapshot`); that answer then replaces
///   it as a refresh's would;
/// - one entry per id, in arrival order;
/// - a page that adds nothing visible (only titles already listed, or none
///   of the wanted genre) asks for the next one at once: no cell would ever
///   appear to trigger it. After `toleratedBarrenPages` of them in a row the
///   list is at its end;
/// - a failure keeps the list and waits for `retry()`, which asks again for
///   what failed: the page that is missing, or the refresh.
///
/// One pager for the iOS and the Mac grids (each platform's stream had
/// written its own; this is the one that is kept, with the load error as
/// the `NSError` the Mac page titles its message from).
public struct CatalogPager<Item> {

    /// One page to load. Give it back with the answer (`receive`).
    public struct Request: Equatable {
        /// 1-based.
        public let page: Int
        /// The list this page belongs to.
        public let generation: Int
        /// A refresh of a list that stays on screen meanwhile.
        public let isRefresh: Bool
    }

    public enum Outcome: Equatable {
        /// The answer of a list that is gone: nothing changed.
        case stale
        /// Applied; the grid asks for more when it needs to.
        case applied
        /// Applied but nothing new is on screen: load this page now.
        case continueWith(Request)
    }

    /// Pages in a row that may add nothing before the list is taken to be
    /// at its end.
    public var toleratedBarrenPages: Int

    /// The titles to show, one per id.
    public private(set) var items: [Item] = []
    /// A request is out.
    public private(set) var isLoading = false
    /// That request is a refresh: `items` is still the previous list.
    public private(set) var isRefreshing = false
    /// False once the catalogue has no further page.
    public private(set) var hasMore = true
    /// The last request failed: why. Cleared by `retry`, `reset` and
    /// `refresh`.
    public private(set) var error: NSError?
    /// That request was a refresh: `retry` refreshes again.
    private var refreshFailed = false
    /// `items` is the saved first page of the list (`receiveSnapshot`),
    /// waiting for the network's.
    private var showsSnapshot = false
    /// Bumped by `reset` and `refresh`.
    public private(set) var generation = 0

    private let id: (Item) -> String
    private var ids = Set<String>()
    private var nextPage = 1
    private var barrenPages = 0
    /// The source filters its pages (a genre): an empty page is then one
    /// without a match, not the end of the catalogue.
    private var isFiltered = false

    public init(toleratedBarrenPages: Int = 3, id: @escaping (Item) -> String) {
        self.toleratedBarrenPages = max(1, toleratedBarrenPages)
        self.id = id
    }

    /// True before anything was asked for or answered: nothing to show and
    /// nothing to say yet.
    public var isIdle: Bool {
        generation == 0
    }

    // MARK: Requests

    /// Starts a new list (another filter or genre): the old one goes.
    /// `filtered`: the source filters its pages, so an empty one may be
    /// followed by pages with titles.
    public mutating func reset(filtered: Bool = false) -> Request {
        generation += 1
        items = []
        ids = []
        nextPage = 1
        barrenPages = 0
        hasMore = true
        error = nil
        refreshFailed = false
        showsSnapshot = false
        isFiltered = filtered
        isLoading = true
        isRefreshing = false
        return Request(page: 1, generation: generation, isRefresh: false)
    }

    /// Loads the first page again; the list stays until it arrives. A page
    /// still on its way for the old list is dropped when it lands.
    public mutating func refresh() -> Request {
        guard !items.isEmpty else { return reset(filtered: isFiltered) }
        generation += 1
        error = nil
        refreshFailed = false
        showsSnapshot = false
        isLoading = true
        isRefreshing = true
        return Request(page: 1, generation: generation, isRefresh: true)
    }

    /// The next page, or nil when one is already on its way, the list is at
    /// its end, or the last request failed (`retry`).
    public mutating func next() -> Request? {
        guard !isIdle, !isLoading, hasMore, error == nil else { return nil }
        isLoading = true
        return Request(page: nextPage, generation: generation, isRefresh: false)
    }

    /// After a failure: what failed, again — the page that is missing, or
    /// the refresh (the list on screen stays meanwhile, as for any refresh).
    /// Never the page after the list in a refresh's place: on a list at its
    /// end (the Top 100 is one page) that page is empty, and the error would
    /// go without anything having been refreshed.
    public mutating func retry() -> Request? {
        guard !isIdle, !isLoading, error != nil else { return nil }
        if refreshFailed { return refresh() }
        error = nil
        hasMore = true
        isLoading = true
        return Request(page: nextPage, generation: generation, isRefresh: false)
    }

    // MARK: Answers

    /// The first page saved by an earlier load of the list `request` (from
    /// `reset`) starts, shown at once while the network's is on its way. The
    /// request stays out (no paging meanwhile), and its answer replaces this
    /// list as a refresh's would: an empty or failed one keeps it. False
    /// (nothing changed) for another request, a list already showing
    /// titles, or an empty snapshot.
    @discardableResult
    public mutating func receiveSnapshot(_ snapshot: [Item], for request: Request,
                                         arrange: (([Item]) -> [Item])? = nil) -> Bool {
        guard request.generation == generation, request.page == 1, !request.isRefresh,
              isLoading, items.isEmpty else { return false }
        let fresh = snapshot.filter { ids.insert(id($0)).inserted }
        guard !fresh.isEmpty else { return false }
        items = fresh
        if let arrange { items = arrange(items) }
        nextPage = 2
        showsSnapshot = true
        return true
    }

    /// Applies the answer to `request`: the page, or why it failed.
    /// `arrange` reorders the whole list after a page was added (an
    /// alphabetical sort the source cannot do across pages).
    @discardableResult
    public mutating func receive(_ result: Result<[Item], NSError>, for request: Request,
                                 arrange: (([Item]) -> [Item])? = nil) -> Outcome {
        guard request.generation == generation else { return .stale }
        isLoading = false
        isRefreshing = false
        // The network's first page over the saved one: a refresh.
        let replaces = request.isRefresh || (showsSnapshot && request.page == 1)
        showsSnapshot = false

        let page: [Item]
        switch result {
        case .failure(let failure):
            error = failure
            refreshFailed = replaces
            return .applied
        case .success(let loaded):
            page = loaded
        }

        if replaces {
            // An empty first page while titles are on screen is a hiccup of
            // the source, not a catalogue that emptied: keep them.
            guard !page.isEmpty else { return .applied }
            items = []
            ids = []
            nextPage = 1
            barrenPages = 0
            hasMore = true
        }

        let fresh = page.filter { ids.insert(id($0)).inserted }
        if page.isEmpty && !isFiltered {
            hasMore = false
            return .applied
        }
        nextPage = request.page + 1
        guard !fresh.isEmpty else {
            barrenPages += 1
            guard barrenPages < toleratedBarrenPages else {
                hasMore = false
                return .applied
            }
            isLoading = true
            return .continueWith(Request(page: nextPage, generation: generation, isRefresh: false))
        }
        barrenPages = 0
        items.append(contentsOf: fresh)
        if let arrange { items = arrange(items) }
        return .applied
    }
}
