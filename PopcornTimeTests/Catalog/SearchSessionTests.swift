//
//  SearchSessionTests.swift
//  PopcornTimeTests
//
//  SearchSession (PopcornKit): a live search answered by two sources — the answers of an
//  older query never show, and the page knows when to say "No results".
//

import XCTest
import Foundation
@testable import PopcornKit

final class SearchSessionTests: CheckedTestCase {

    private enum Kind { case movies, shows }
    private typealias Session = SearchSession<Kind>

    private func session() -> Session { Session(kinds: [.movies, .shows]) }

    func testNormalisation() {
        eq(Session.normalised("  the   wire \n"), "the wire", "trimmed, white space collapsed")
        eq(Session.normalised(" \t "), "", "blank")
    }

    func testTooShortStaysIdle() {
        var s = session()
        eq(s.phase, .idle, "new: idle")
        check(s.begin("") == nil && s.begin(" ") == nil && s.begin("a") == nil, "nothing to send")
        eq(s.phase, .idle, "still idle")
        check(!s.isSearching, "not searching")
    }

    func testResultsArriveSourceBySource() {
        var s = session()
        guard let token = s.begin(" Batman ") else { return check(false, "token") }
        eq(s.query, "Batman", "normalised query")
        check(s.phase == .searching && s.isSearching, "searching")
        check(s.receive(.movies, count: 12, error: nil, token: token), "movies accepted")
        check(s.phase == .results && s.isSearching, "results shown while the shows are still out")
        check(s.receive(.shows, count: 0, error: nil, token: token), "shows accepted")
        check(s.phase == .results && !s.isSearching, "done")
        check(!s.receive(.shows, count: 3, error: nil, token: token), "a second answer of the same source is dropped")
    }

    func testStaleAnswerNeverShows() {
        var s = session()
        let bat = s.begin("bat")!
        let batman = s.begin("batman")!
        check(bat != batman, "a new token per query")
        check(!s.receive(.movies, count: 40, error: nil, token: bat), "« bat » landing late is dropped")
        check(s.phase == .searching, "and changes nothing")
        check(s.receive(.movies, count: 5, error: nil, token: batman), "« batman » is shown")
        check(!s.receive(.shows, count: 9, error: nil, token: bat), "the other stale answer too")
        check(s.isSearching, "the current shows answer is still awaited")
        check(s.receive(.shows, count: 1, error: nil, token: batman), "and accepted")
    }

    func testNoResultsAndFailure() {
        var s = session()
        var token = s.begin("zzzz")!
        s.receive(.movies, count: 0, error: nil, token: token)
        eq(s.phase, .searching, "one empty answer is not the end")
        s.receive(.shows, count: 0, error: nil, token: token)
        eq(s.phase, .empty, "both empty: No results")

        // Offline: an error, not "No results".
        token = s.begin("dune")!
        s.receive(.movies, count: 0, error: "The Internet connection appears to be offline.", token: token)
        s.receive(.shows, count: 0, error: "The Internet connection appears to be offline.", token: token)
        eq(s.phase, .failed("The Internet connection appears to be offline."), "both failed: the message")

        // One source down, the other found something: results.
        token = s.begin("dune 2")!
        s.receive(.movies, count: 0, error: "timeout", token: token)
        s.receive(.shows, count: 2, error: nil, token: token)
        eq(s.phase, .results, "a partial failure still shows what was found")
    }

    func testSameQueryIsNotSentTwice() {
        var s = session()
        let token = s.begin("dune")!
        check(s.begin("dune ") == nil && s.begin("DUNE") == nil, "the same query while it is searched")
        s.receive(.movies, count: 1, error: nil, token: token)
        s.receive(.shows, count: 1, error: nil, token: token)
        check(s.begin(" dune") == nil, "nor once it is shown (Return on the same text)")
        eq(s.token, token, "the token did not move")
        // A failed search is worth another try with the same text.
        let failing = s.begin("dune 3")!
        s.receive(.movies, count: 0, error: "offline", token: failing)
        s.receive(.shows, count: 0, error: "offline", token: failing)
        check(s.begin("dune 3") != nil, "a failed query can be sent again")
    }

    func testOneCharacterIsAQueryWhenSubmitted() {
        var s = session()
        check(s.begin("X") == nil, "typed: one letter waits for a second")
        eq(s.phase, .idle, "idle")
        guard let token = s.begin(" X ", submitted: true) else { return check(false, "Return sends « X »") }
        eq(s.query, "X", "the query")
        eq(s.phase, .searching, "searching")
        check(s.receive(.movies, count: 1, error: nil, token: token), "« X » (2022) found")
        check(s.begin("", submitted: true) == nil, "Return on an empty field sends nothing")
        eq(s.phase, .idle, "and goes back to the start")
    }

    func testOneSourceFailedIsSaidAndCanBeAskedAgain() {
        var s = session()
        let token = s.begin("dune")!
        s.receive(.movies, count: 18, error: nil, token: token)
        s.receive(.shows, count: 0, error: "timeout", token: token)
        eq(s.phase, .results, "the movies are shown")
        eq(s.failures, [.shows: "timeout"], "the shows that could not be searched are known")
        guard let again = s.begin("dune", submitted: true) else { return check(false, "⌘R / Return asks the same query again") }
        check(again != token, "a new token")
        eq(s.failures, [:], "forgotten until the new answers")
        check(s.begin("dune", submitted: true) == nil, "not twice while it is out")
        s.receive(.movies, count: 18, error: nil, token: again)
        s.receive(.shows, count: 3, error: nil, token: again)
        check(s.failures.isEmpty && s.phase == .results, "both answered")
        check(s.begin("dune", submitted: true) == nil, "nothing failed: the query is kept")
        // An error that came with titles is not a failure of that source.
        let partial = s.begin("dune 2")!
        s.receive(.movies, count: 4, error: "one mirror down", token: partial)
        s.receive(.shows, count: 0, error: nil, token: partial)
        eq(s.failures, [:], "titles found: nothing to retry")
        s.clear()
        eq(s.failures, [:], "cleared")
    }

    func testClearingDropsAnswersOnTheirWay() {
        var s = session()
        let token = s.begin("dune")!
        check(s.begin("d") == nil, "the field shortened under the minimum")
        check(s.phase == .idle && s.query.isEmpty && !s.isSearching, "back to the starting state")
        check(!s.receive(.movies, count: 7, error: nil, token: token), "the answer on its way is dropped")
        eq(s.phase, .idle, "idle stays")
        check(s.begin("dune") != nil, "the same text can be searched again after a clear")
    }
}
