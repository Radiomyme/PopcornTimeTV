import Foundation

/// Which posters of a grid have a cell on screen, and when the last one asks
/// for the next page. For the grids that only hear a cell come and go (the
/// Mac's `LazyVGrid`: `onAppear` / `onDisappear`). A plain value, unit-tested
/// (`LastPosterWatchTests`); the grid asks its `CatalogPager` when told to.
///
/// The rules it holds:
/// - the last poster's cell coming on screen asks for the next page;
/// - an answer that leaves the last poster where it was, on screen, brings
///   no such appearance (the network's first page over the saved one with
///   the same titles, an "A - Z" page sorted in above the last title): the
///   next page is asked at once, `followUpLimit` times in a row at most. An
///   "A - Z" page nearly always lands above the last title: with no limit
///   the pages followed one another to the end of the catalogue while that
///   poster stayed on screen (18 pages in 7 seconds, and going on). The
///   count starts again when a last poster's cell appears: the user came
///   back to the end, or the list grew a new end on screen;
/// - a new scroll view (another list, a refreshed one back at its top) has
///   no cell yet, and what the cells of the one it replaces still report is
///   ignored. (They were taken for the new one's: a refresh asked with the
///   end of the first page on screen asked for the second page while the
///   grid was back at its top.)
public struct LastPosterWatch {

    /// Pages in a row that may be asked for with no cell appearing.
    public let followUpLimit: Int

    /// The scroll view the cells are counted for.
    private var list = 0
    private var shown = Set<String>()
    private var followUps = 0

    public init(followUpLimit: Int = 3) {
        self.followUpLimit = max(0, followUpLimit)
    }

    /// A new scroll view, `list`: none of its cells exists yet.
    public mutating func start(list: Int) {
        self.list = list
        shown = []
        followUps = 0
    }

    /// A cell of the scroll view `list` appeared; `last`: the list's last
    /// poster. True: it is that one's, the next page is wanted.
    public mutating func appeared(_ id: String, in list: Int, last: String?) -> Bool {
        guard list == self.list else { return false }
        shown.insert(id)
        guard id == last else { return false }
        followUps = 0
        return true
    }

    /// A cell of the scroll view `list` went away.
    public mutating func disappeared(_ id: String, in list: Int) {
        guard list == self.list else { return }
        shown.remove(id)
    }

    /// An answer was applied; `last`: the list's last poster now. True: its
    /// cell is already there and will not appear again, the next page is
    /// wanted now.
    public mutating func answered(last: String?) -> Bool {
        guard let last, shown.contains(last), followUps < followUpLimit else { return false }
        followUps += 1
        return true
    }
}
