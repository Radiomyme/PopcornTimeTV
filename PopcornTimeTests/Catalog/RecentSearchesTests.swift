//
//  RecentSearchesTests.swift
//  PopcornTimeTests
//
//  The search screen's recent searches (RecentSearches) and the "stream on cellular" rule
//  (CellularStreamingPolicy), each against its own throwaway defaults domain.
//

import XCTest
import Foundation
@testable import PopcornKit

/// A defaults domain for one test, as a file in a temporary folder (see BandwidthTests).
private func testDomain(_ name: String) -> String {
    let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("PopcornTimeTests-defaults")
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    return (folder as NSString).appendingPathComponent(name)
}

private func throwawayDefaults(_ domain: String) -> UserDefaults {
    let suite = UserDefaults(suiteName: domain)!
    suite.removePersistentDomain(forName: domain)
    return suite
}

private func discardDefaults(_ suite: UserDefaults, _ domain: String) {
    suite.removePersistentDomain(forName: domain)
    suite.synchronize()
    try? FileManager.default.removeItem(atPath: domain + ".plist")
}

final class RecentSearchesTests: CheckedTestCase {

    func testListRules() {
        eq(RecentSearches.list([], adding: "Dune"), ["Dune"], "first search")
        eq(RecentSearches.list(["Dune"], adding: "  Alien  "), ["Alien", "Dune"], "most recent first, trimmed")
        eq(RecentSearches.list(["Alien", "Dune"], adding: "dune"), ["dune", "Alien"], "the same search moves up, as typed last")
        eq(RecentSearches.list(["Amélie"], adding: "amelie"), ["amelie"], "accents do not make another search")
        eq(RecentSearches.list(["Dune"], adding: " "), ["Dune"], "blank is not a search")
        eq(RecentSearches.list(["Dune"], adding: "a"), ["Dune"], "one letter is not kept")
        eq(RecentSearches.list(["Dune"], adding: "It"), ["It", "Dune"], "two letters are")
        let many = (1...12).map { "search \($0)" }
        let capped = many.reduce([String]()) { RecentSearches.list($0, adding: $1) }
        eq(capped.count, RecentSearches.limit, "capped")
        eq(capped.first, "search 12", "the newest is first")
        eq(capped.last, "search 5", "the oldest fall off")
        eq(RecentSearches.list(["a1", "b2", "c3"], adding: "d4", limit: 2), ["d4", "a1"], "a custom limit")
    }

    func testStore() {
        let domain = testDomain("recent-searches")
        let defaults = throwawayDefaults(domain)
        defer { discardDefaults(defaults, domain) }
        let recents = RecentSearches(defaults: defaults)
        eq(recents.queries, [], "empty at first")
        recents.add("Dune")
        recents.add("Severance")
        recents.add("DUNE")
        eq(recents.queries, ["DUNE", "Severance"], "stored most recent first, one per search")
        eq(RecentSearches(defaults: defaults).queries, ["DUNE", "Severance"], "read back by another instance")
        recents.remove("severance")
        eq(recents.queries, ["DUNE"], "removed whatever its case")
        recents.remove("DUNE")
        check(defaults.object(forKey: RecentSearches.defaultsKey) == nil, "no empty array left behind")
        recents.add("Alien")
        recents.clear()
        eq(recents.queries, [], "cleared")
    }
}

final class CellularStreamingPolicyTests: CheckedTestCase {

    func testDecision() {
        let domain = testDomain("cellular-policy")
        let defaults = throwawayDefaults(domain)
        defer { discardDefaults(defaults, domain) }
        eq(CellularStreamingPolicy.decision(isExpensive: false, defaults: defaults), .stream, "Wi-Fi streams")
        eq(CellularStreamingPolicy.decision(isExpensive: true, defaults: defaults), .askFirst, "cellular asks first by default")
        defaults.set(false, forKey: CellularStreamingPolicy.defaultsKey)
        eq(CellularStreamingPolicy.decision(isExpensive: true, defaults: defaults), .askFirst, "setting off: asks")
        CellularStreamingPolicy.allow(in: defaults)
        check(defaults.bool(forKey: "streamOnCellular"), "Turn On writes the setting the Settings screen shows")
        eq(CellularStreamingPolicy.decision(isExpensive: true, defaults: defaults), .stream, "setting on: streams on cellular")
        eq(CellularStreamingPolicy.decision(isExpensive: false, defaults: defaults), .stream, "and on Wi-Fi")
    }
}
