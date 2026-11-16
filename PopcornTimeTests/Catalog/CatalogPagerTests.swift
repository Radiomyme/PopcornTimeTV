//
//  CatalogPagerTests.swift
//  PopcornTimeTests
//
//  The paging rules of the catalogue grids (CatalogPager): stale answers, one entry per id,
//  pages that add nothing, the end of the list, a refresh that keeps the grid, failures and
//  Retry (of a page, of a refresh). One pager for the iOS and the Mac grids: the cases of both
//  streams' tests are here.
//

import XCTest
import Foundation
@testable import PopcornKit

private typealias Pager = CatalogPager<String>
private func pager(tolerated: Int = 3) -> Pager { Pager(toleratedBarrenPages: tolerated) { $0 } }
private let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

final class CatalogPagerTests: CheckedTestCase {

    func testFirstPagesAndTheEnd() {
        var p = pager()
        check(p.isIdle, "idle before the first reset")
        check(p.next() == nil, "nothing to ask for while idle")
        check(p.retry() == nil, "nothing to retry while idle")

        let first = p.reset()
        eq(first, Pager.Request(page: 1, generation: 1, isRefresh: false), "reset asks for page 1")
        check(p.isLoading && !p.isRefreshing && p.items.isEmpty && !p.isIdle, "loading the first page")
        check(p.next() == nil, "no second request while one is out")

        eq(p.receive(.success(["a", "b"]), for: first), .applied, "first page applied")
        eq(p.items, ["a", "b"], "first page listed")
        check(!p.isLoading && p.hasMore && p.error == nil, "ready for more")

        let second = p.next()
        eq(second, Pager.Request(page: 2, generation: 1, isRefresh: false), "then page 2")
        eq(p.receive(.success(["c"]), for: second!), .applied, "second page applied")
        eq(p.items, ["a", "b", "c"], "pages in arrival order")

        let third = p.next()
        eq(third?.page, 3, "then page 3")
        eq(p.receive(.success([]), for: third!), .applied, "an empty page is the end")
        check(!p.hasMore && !p.isLoading, "the list is at its end")
        check(p.next() == nil, "nothing after the end")
        eq(p.items, ["a", "b", "c"], "the list is kept at its end")
    }

    func testOneEntryPerID() {
        var p = pager()
        let first = p.reset()
        _ = p.receive(.success(["a", "b", "a"]), for: first)
        eq(p.items, ["a", "b"], "a title twice in one page is listed once")
        let second = p.next()!
        _ = p.receive(.success(["b", "c", "a", "d"]), for: second)
        eq(p.items, ["a", "b", "c", "d"], "titles of an earlier page are not listed again")
    }

    func testStaleAnswersAreDropped() {
        var p = pager()
        let old = p.reset()
        let new = p.reset()   // another filter picked while the first page loads
        eq(new.generation, old.generation + 1, "each list has its generation")
        eq(p.receive(.success(["old"]), for: old), .stale, "the old list's answer is dropped")
        check(p.items.isEmpty && p.isLoading, "and the new request is still out")
        eq(p.receive(.failure(offline), for: old), .stale, "the old list's failure too")
        check(p.error == nil, "no error from a list that is gone")
        eq(p.receive(.success(["new"]), for: new), .applied, "the current list's answer is applied")
        eq(p.items, ["new"], "only the current list shows")
    }

    func testPagesThatAddNothingLoadTheNextOne() {
        var p = pager(tolerated: 3)
        _ = p.receive(.success(["a", "b"]), for: p.reset())
        let second = p.next()!
        // Page 2 only repeats page 1: no cell appears, so no cell can ask for page 3.
        let outcome = p.receive(.success(["b", "a"]), for: second)
        eq(outcome, .continueWith(Pager.Request(page: 3, generation: 1, isRefresh: false)), "asks for page 3 at once")
        check(p.isLoading && p.hasMore, "page 3 is on its way")
        check(p.next() == nil, "not asked twice")
        eq(p.receive(.success(["c"]), for: Pager.Request(page: 3, generation: 1, isRefresh: false)), .applied, "page 3 adds a title")
        eq(p.items, ["a", "b", "c"], "the list goes on")
        eq(p.next()?.page, 4, "then page 4")
    }

    func testRepeatedBarrenPagesEndTheList() {
        var p = pager(tolerated: 3)
        _ = p.receive(.success(["a"]), for: p.reset())
        var request = p.next()!
        var asked = [request.page]
        var outcome = p.receive(.success(["a"]), for: request)
        while case .continueWith(let next) = outcome {
            asked.append(next.page)
            request = next
            outcome = p.receive(.success(["a"]), for: request)
        }
        eq(asked, [2, 3, 4], "three pages in a row may add nothing")
        check(!p.hasMore && !p.isLoading, "then the list ends instead of looping")
        eq(p.items, ["a"], "nothing was added")

        // A page with a new title in between starts the count again.
        var q = pager(tolerated: 2)
        _ = q.receive(.success(["a"]), for: q.reset())
        guard case .continueWith(let third) = q.receive(.success(["a"]), for: q.next()!) else { return XCTFail("expected page 3") }
        eq(q.receive(.success(["b"]), for: third), .applied, "page 3 adds a title")
        guard case .continueWith = q.receive(.success(["a", "b"]), for: q.next()!) else { return XCTFail("the count restarted") }
        check(q.hasMore, "one barren page after a full one is not the end")
    }

    func testGenreFilterEmptyPageIsNotTheEnd() {
        var p = pager(tolerated: 3)
        let first = p.reset(filtered: true)
        // No title of the genre in the first 100 torrents: page 2 may have some.
        guard case .continueWith(let second) = p.receive(.success([]), for: first) else { return XCTFail("expected page 2") }
        eq(second.page, 2, "an empty filtered page asks for the next one")
        eq(p.receive(.success(["a"]), for: second), .applied, "page 2 has one")
        eq(p.items, ["a"], "listed")
        var outcome = p.receive(.success([]), for: p.next()!)
        var pages = 0
        while case .continueWith(let next) = outcome { pages += 1; outcome = p.receive(.success([]), for: next) }
        eq(pages, 2, "empty filtered pages stop after the tolerated count")
        check(!p.hasMore, "the filtered list ends")

        // The filter is remembered by a refresh of an empty list, forgotten by a plain reset.
        var q = pager()
        _ = q.reset(filtered: true)
        let again = q.refresh()
        check(!again.isRefresh, "refreshing an empty list starts it over")
        guard case .continueWith = q.receive(.success([]), for: again) else { return XCTFail("still filtered") }
        eq(q.receive(.success([]), for: q.reset()), .applied, "unfiltered: an empty page is the end")
        check(!q.hasMore, "ended")
    }

    func testRefreshKeepsTheListUntilItArrives() {
        var p = pager()
        _ = p.receive(.success(["a", "b"]), for: p.reset())
        _ = p.receive(.success(["c"]), for: p.next()!)
        let refresh = p.refresh()
        eq(refresh, Pager.Request(page: 1, generation: 2, isRefresh: true), "a refresh asks for page 1 of a new generation")
        eq(p.items, ["a", "b", "c"], "the grid keeps its titles meanwhile")
        check(p.isLoading && p.isRefreshing, "refreshing")
        check(p.next() == nil, "no paging during a refresh")

        eq(p.receive(.success(["n", "a"]), for: refresh), .applied, "the new first page arrives")
        eq(p.items, ["n", "a"], "and replaces the list")
        check(!p.isRefreshing && !p.isLoading && p.hasMore, "refreshed")
        eq(p.next()?.page, 2, "paging starts again at page 2")
    }

    func testRefreshDropsThePageInFlight() {
        var p = pager()
        _ = p.receive(.success(["a"]), for: p.reset())
        let second = p.next()!
        let refresh = p.refresh()
        eq(p.receive(.success(["late"]), for: second), .stale, "page 2 of the old list is dropped")
        eq(p.items, ["a"], "the list is unchanged")
        check(p.isLoading && p.isRefreshing, "the refresh is still out")
        _ = p.receive(.success(["x"]), for: refresh)
        eq(p.items, ["x"], "then the refresh applies")
    }

    func testEmptyOrFailedRefreshKeepsTheList() {
        var p = pager()
        _ = p.receive(.success(["a", "b"]), for: p.reset())
        eq(p.receive(.success([]), for: p.refresh()), .applied, "an empty refresh is applied")
        eq(p.items, ["a", "b"], "but never empties a list that has titles")
        check(p.hasMore && p.error == nil && !p.isRefreshing, "and the list goes on")
        eq(p.next()?.page, 2, "from where it was")

        var q = pager()
        _ = q.receive(.success(["a", "b"]), for: q.reset())
        eq(q.receive(.failure(offline), for: q.refresh()), .applied, "a failed refresh is applied")
        eq(q.items, ["a", "b"], "the list stays")
        check(q.error == offline && !q.isRefreshing && !q.isLoading, "with the error")
        check(q.next() == nil, "paging waits for Retry")
    }

    func testRetryAfterAFailedRefreshRefreshesAgain() {
        // Retry asks again for what failed. (It asked for the page after the list: on a list at
        // its end that page is empty, so the error went and nothing had been refreshed.)
        var p = pager()
        _ = p.receive(.success(["a", "b"]), for: p.reset())
        _ = p.receive(.success([]), for: p.next()!)   // one page, like the Top 100
        check(!p.hasMore, "the list is at its end")
        _ = p.receive(.failure(offline), for: p.refresh())
        check(p.error == offline && p.items == ["a", "b"], "the refresh failed: the list stays, with the error")

        let again = p.retry()
        eq(again, Pager.Request(page: 1, generation: 3, isRefresh: true), "Retry is the refresh again, not the page after the list")
        check(p.isLoading && p.isRefreshing && p.error == nil, "refreshing: the error clears while it loads")
        eq(p.items, ["a", "b"], "and the list stays meanwhile")
        check(p.retry() == nil && p.next() == nil, "one request at a time")

        // It fails again: still a refresh to retry.
        _ = p.receive(.failure(offline), for: again!)
        check(p.error == offline && p.items == ["a", "b"] && !p.isRefreshing, "failed again: nothing changed")
        let third = p.retry()
        eq(third, Pager.Request(page: 1, generation: 4, isRefresh: true), "Retry refreshes once more")
        eq(p.receive(.success(["n", "a"]), for: third!), .applied, "this time it lands")
        eq(p.items, ["n", "a"], "the new first page replaces the list")
        check(p.error == nil && p.hasMore && p.retry() == nil, "refreshed: nothing left to retry")

        // The failure of a page after that is that page's: Retry asks for it, not for a refresh.
        let second = p.next()!
        _ = p.receive(.failure(offline), for: second)
        eq(p.retry(), Pager.Request(page: 2, generation: 4, isRefresh: false), "a failed page is retried as a page")

        // Another way out of a failed refresh forgets it: ⌘R, or another list.
        var q = pager()
        _ = q.receive(.success(["a"]), for: q.reset())
        _ = q.receive(.failure(offline), for: q.refresh())
        let manual = q.refresh()
        check(manual.isRefresh && q.error == nil, "a refresh over a failed one")
        _ = q.receive(.success(["b"]), for: manual)
        _ = q.receive(.failure(offline), for: q.next()!)
        eq(q.retry()?.isRefresh, false, "then a failed page is retried as a page")
        _ = q.receive(.success(["a"]), for: q.reset())
        _ = q.receive(.failure(offline), for: q.refresh())
        let other = q.reset(filtered: true)
        _ = q.receive(.failure(offline), for: other)
        eq(q.retry(), Pager.Request(page: 1, generation: other.generation, isRefresh: false), "a new list's first page is retried as a first page")

        // A filtered list (a genre in the Top 100): the retried refresh stays filtered.
        var f = pager()
        _ = f.receive(.success(["a"]), for: f.reset(filtered: true))
        _ = f.receive(.failure(offline), for: f.refresh())
        let filtered = f.retry()!
        check(filtered.isRefresh, "Retry refreshes the filtered list too")
        eq(f.receive(.success([]), for: filtered), .applied, "an empty refresh is applied")
        eq(f.items, ["a"], "and still never empties a list that has titles")
    }

    func testFailureAndRetry() {
        var p = pager()
        let first = p.reset()
        eq(p.receive(.failure(offline), for: first), .applied, "failure applied")
        check(p.items.isEmpty && !p.isLoading && !p.isIdle, "nothing listed")
        check(p.error == offline, "the reason is kept")
        check(p.next() == nil, "no paging over a failure")
        let again = p.retry()
        eq(again, Pager.Request(page: 1, generation: 1, isRefresh: false), "Retry asks for the first page again")
        check(p.error == nil && p.isLoading, "the error clears while it loads")
        check(p.retry() == nil, "one retry at a time")
        _ = p.receive(.success(["a"]), for: again!)
        eq(p.items, ["a"], "listed after the retry")

        // A later page that fails keeps the list; Retry asks for that page.
        _ = p.receive(.success(["b"]), for: p.next()!)
        let third = p.next()!
        _ = p.receive(.failure(offline), for: third)
        check(p.error == offline && p.hasMore && !p.isLoading, "error shown, list not ended")
        eq(p.items, ["a", "b"], "the list is kept")
        check(p.next() == nil, "no automatic retry (the last poster appearing must not hammer the source)")
        let again3 = p.retry()
        eq(again3?.page, 3, "Retry asks for page 3")
        check(p.error == nil && p.isLoading, "error cleared while it loads")
        eq(p.receive(.success(["c"]), for: again3!), .applied, "it lands")
        eq(p.items, ["a", "b", "c"], "and the list goes on")
        check(p.retry() == nil, "nothing to retry without a failure")
    }

    func testArrangeReordersTheWholeList() {
        var p = pager()
        let sort: ([String]) -> [String] = { $0.sorted() }
        _ = p.receive(.success(["m", "c"]), for: p.reset(), arrange: sort)
        eq(p.items, ["c", "m"], "first page sorted")
        _ = p.receive(.success(["a", "z", "c"]), for: p.next()!, arrange: sort)
        eq(p.items, ["a", "c", "m", "z"], "the whole list stays sorted as pages arrive")
    }

    func testSnapshotShowsUntilTheNetworksFirstPage() {
        var p = pager()
        let first = p.reset()
        check(p.receiveSnapshot(["old1", "old2", "old1"], for: first), "the saved first page is shown")
        eq(p.items, ["old1", "old2"], "once per id")
        check(p.isLoading && !p.isRefreshing, "the network's page is still on its way, the grid is not dimmed")
        check(p.next() == nil, "no paging over the snapshot")
        check(!p.receiveSnapshot(["other"], for: first), "a second snapshot changes nothing")

        eq(p.receive(.success(["new1", "old1"]), for: first), .applied, "the network's page lands")
        eq(p.items, ["new1", "old1"], "and replaces the snapshot")
        eq(p.next()?.page, 2, "then page 2")
    }

    func testSnapshotIsKeptOverAnEmptyOrFailedAnswer() {
        var p = pager()
        let first = p.reset()
        p.receiveSnapshot(["old"], for: first)
        eq(p.receive(.success([]), for: first), .applied, "an empty first page")
        eq(p.items, ["old"], "keeps the snapshot")
        check(p.hasMore, "the list is not at its end")
        eq(p.next()?.page, 2, "the next page follows the snapshot's")

        var q = pager()
        let start = q.reset()
        q.receiveSnapshot(["old"], for: start)
        _ = q.receive(.failure(offline), for: start)
        eq(q.items, ["old"], "a failure keeps the snapshot")
        let again = q.retry()
        eq(again, Pager.Request(page: 1, generation: 2, isRefresh: true), "Retry refreshes the first page")
        _ = q.receive(.success(["new"]), for: again!)
        eq(q.items, ["new"], "which replaces the snapshot")
    }

    func testSnapshotOnlyForTheFirstPageOfTheCurrentList() {
        var p = pager()
        let old = p.reset()
        let current = p.reset()
        check(!p.receiveSnapshot(["x"], for: old), "not for a list that is gone")
        check(!p.receiveSnapshot([], for: current), "not an empty snapshot")
        _ = p.receive(.success(["a"]), for: current)
        let second = p.next()!
        check(!p.receiveSnapshot(["x"], for: second), "not for page 2")
        let refresh = p.refresh()
        check(!p.receiveSnapshot(["x"], for: refresh), "not for a refresh: its list is on screen")
        eq(p.items, ["a"], "nothing changed")

        // A refresh pulled while the snapshot shows: the first answer is dropped.
        var q = pager()
        let first = q.reset()
        q.receiveSnapshot(["old"], for: first)
        let pulled = q.refresh()
        check(pulled.isRefresh && q.isRefreshing, "the snapshot stays while the refresh loads")
        eq(q.receive(.success(["late"]), for: first), .stale, "the first load's answer is dropped")
        _ = q.receive(.success(["new"]), for: pulled)
        eq(q.items, ["new"], "the refresh's page replaces the snapshot")
    }

    func testSnapshotIsArranged() {
        var p = pager()
        let sort: ([String]) -> [String] = { $0.sorted() }
        let first = p.reset()
        p.receiveSnapshot(["m", "c"], for: first, arrange: sort)
        eq(p.items, ["c", "m"], "the snapshot in the list's order")
        _ = p.receive(.success(["z", "a"]), for: first, arrange: sort)
        eq(p.items, ["a", "z"], "then the network's")
    }
}
