//
//  LastPosterWatchTests.swift
//  PopcornTimeTests
//
//  When the Mac grids ask for the next page (LastPosterWatch): the last poster's cell
//  appearing, an answer that leaves it on screen (a bounded number of times in a row), and
//  the cells of a scroll view that was replaced. With a CatalogPager, as the grid runs them:
//  an "A - Z" list whose last title never moves, and a refresh asked from the end of page 1.
//

import XCTest
import Foundation
@testable import PopcornKit

final class LastPosterWatchTests: CheckedTestCase {

    func testTheLastPostersCellAsksForTheNextPage() {
        var watch = LastPosterWatch()
        watch.start(list: 1)
        check(!watch.appeared("a", in: 1, last: "c"), "a poster that is not the last asks for nothing")
        check(watch.appeared("c", in: 1, last: "c"), "the last one does")
        check(watch.appeared("c", in: 1, last: "c"), "and again when it comes back on screen")
        check(!watch.appeared("c", in: 1, last: nil), "nothing to ask for an empty list")
    }

    func testAnAnswerThatLeavesTheLastPosterOnScreenAsksForTheNextPage() {
        var watch = LastPosterWatch()
        watch.start(list: 1)
        check(!watch.answered(last: "c"), "the last poster has no cell: its appearance will ask")
        _ = watch.appeared("c", in: 1, last: "c")
        check(watch.answered(last: "c"), "its cell is there: nothing will appear, the page is asked now")
        watch.disappeared("c", in: 1)
        check(!watch.answered(last: "c"), "scrolled away: nothing asked")
        check(!watch.answered(last: nil), "an empty list asks for nothing")
    }

    func testFollowUpsAreBoundedUntilALastPosterAppears() {
        var watch = LastPosterWatch(followUpLimit: 3)
        watch.start(list: 1)
        _ = watch.appeared("z", in: 1, last: "z")
        eq((0..<10).filter { _ in watch.answered(last: "z") }.count, 3, "three pages in a row with no cell appearing, no more")
        // The list grows a new end on screen: its cell appears, the count starts again.
        check(watch.appeared("zz", in: 1, last: "zz"), "a new last poster on screen asks")
        eq((0..<10).filter { _ in watch.answered(last: "zz") }.count, 3, "and three more may follow")
        // A poster that is not the last one does not start the count again.
        _ = watch.appeared("m", in: 1, last: "zz")
        check(!watch.answered(last: "zz"), "another poster appearing changes nothing")

        var none = LastPosterWatch(followUpLimit: 0)
        none.start(list: 1)
        _ = none.appeared("z", in: 1, last: "z")
        check(!none.answered(last: "z"), "no follow-up at all with a limit of 0")
        eq(LastPosterWatch(followUpLimit: -2).followUpLimit, 0, "a negative limit is 0")
    }

    func testANewScrollViewHasNoCellAndIgnoresTheOldOnes() {
        var watch = LastPosterWatch()
        watch.start(list: 1)
        _ = watch.appeared("c", in: 1, last: "c")
        watch.start(list: 2)
        check(!watch.answered(last: "c"), "the new scroll view has no cell yet")
        check(!watch.appeared("c", in: 1, last: "c"), "a cell of the old one asks for nothing")
        check(!watch.answered(last: "c"), "and is not counted")
        // The new one's cell, then the old one's leaving late.
        check(watch.appeared("c", in: 2, last: "c"), "the new scroll view's last poster asks")
        watch.disappeared("c", in: 1)
        check(watch.answered(last: "c"), "the old cell going away does not hide the new one")
        watch.disappeared("c", in: 2)
        check(!watch.answered(last: "c"), "its own does")
    }

    /// "A - Z" with the last title on screen and every page sorted in above
    /// it, as the Mac grid runs it: the pages stop after the limit instead
    /// of following one another to the end of the catalogue.
    func testAnAlphabeticalListDoesNotLoadItselfToTheEnd() {
        var pager = CatalogPager<String>(id: { $0 })
        var watch = LastPosterWatch(followUpLimit: pager.toleratedBarrenPages)
        let sort: ([String]) -> [String] = { $0.sorted() }
        watch.start(list: 1)
        var asked = [Int]()

        /// The source's answer to `request`, then what the grid does with it.
        func answer(_ request: CatalogPager<String>.Request) {
            asked.append(request.page)
            let page = request.page == 1 ? ["m", "z"] : ["a\(request.page)", "b\(request.page)"]
            guard pager.receive(.success(page), for: request, arrange: sort) == .applied else { return }
            if watch.answered(last: pager.items.last), let next = pager.next() { answer(next) }
        }

        answer(pager.reset())
        eq(asked, [1], "the first page; no cell yet")
        // The user scrolls to the end: the last poster's cell appears.
        check(watch.appeared("z", in: 1, last: pager.items.last), "the end of the list on screen")
        answer(pager.next()!)
        eq(asked, [1, 2, 3, 4, 5], "the page the cell asked for, then three while it stays on screen")
        eq(pager.items.last, "z", "the last title never moved")
        check(pager.hasMore && !pager.isLoading, "the list is not at its end, and nothing is on its way")

        // Scrolled up and back down: the cell appears again.
        watch.disappeared("z", in: 1)
        check(watch.appeared("z", in: 1, last: pager.items.last), "back at the end")
        answer(pager.next()!)
        eq(asked, [1, 2, 3, 4, 5, 6, 7, 8, 9], "four more pages")
    }

    /// A refresh asked with the last poster of page 1 on screen, as the Mac
    /// grid runs it: the list comes back at its top in a new scroll view,
    /// and page 2 waits for that one's last cell.
    func testARefreshedListBackAtItsTopDoesNotAskForTheSecondPage() {
        var pager = CatalogPager<String>(id: { $0 })
        var watch = LastPosterWatch()
        watch.start(list: 1)
        _ = pager.receive(.success(["a", "b"]), for: pager.reset())
        check(watch.appeared("b", in: 1, last: pager.items.last), "the end of page 1 on screen")
        _ = pager.receive(.success(["c", "d"]), for: pager.next()!)
        check(!watch.answered(last: pager.items.last), "page 2's last poster is below the screen")

        let refresh = pager.refresh()
        eq(pager.receive(.success(["a", "b"]), for: refresh), .applied, "the refreshed first page lands")
        watch.start(list: 2)
        check(!watch.answered(last: pager.items.last), "page 2 is not asked: the old scroll view's cells do not count")
        // Its cells leave after the new one's came.
        check(!watch.appeared("a", in: 2, last: pager.items.last), "the top of the new list")
        watch.disappeared("b", in: 1)
        check(!watch.answered(last: pager.items.last), "still nothing asked")
        check(watch.appeared("b", in: 2, last: pager.items.last), "until the end of page 1 is on screen again")
    }
}
