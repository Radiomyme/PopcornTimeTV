//
//  TopShelfReloaderTests.swift
//  PopcornTimeTests
//
//  When the Apple TV app tells the system that its Top Shelf may have changed: a refresh of
//  the Home that brought new lists (and a change of the library, once the extension can read
//  it: followsLibrary) is noted while the app is in front, and told once when it leaves the
//  foreground; in the background a burst of changes is told once, at once. The Home is a
//  HomeFeed on recorded answers.
//

import Foundation
import XCTest
@testable import PopcornKit

final class TopShelfReloaderTests: CheckedTestCase {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = HomeFixture.now
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return date }
            set { lock.lock(); date = newValue; lock.unlock() }
        }
    }

    private var sandbox: HomeSandbox!
    private var network: HomeFakeNetwork!
    private var clock: Clock!
    private var reloads = 0
    private var inFront = true
    /// The app's "left the foreground" notification, one of its own per test.
    private var leave = Notification.Name("")

    override func setUp() {
        super.setUp()
        sandbox = HomeSandbox()
        network = HomeFakeNetwork()
        clock = Clock()
        reloads = 0
        inFront = true
        leave = Notification.Name("PopcornTimeTests.leave.\(UUID().uuidString)")
    }

    override func tearDown() {
        sandbox.discard()
        super.tearDown()
    }

    /// Follows the library unless told otherwise: the rule is the same for both, and a library
    /// change is the easiest one to make.
    private func makeReloader(followsLibrary: Bool = true) -> TopShelfReloader {
        let reloader = TopShelfReloader(followsLibrary: followsLibrary, leavesForeground: [leave], isInFront: { [unowned self] in self.inFront },
                                        reload: { [unowned self] in self.reloads += 1 })
        reloader.start()
        return reloader
    }

    private func makeFeed() -> HomeFeed {
        let clock = self.clock!
        var options = HomeFeed.Options(requestDeadline: .infinity, phaseGrace: .infinity)
        options.light = true
        return HomeFeed(store: HomeStore(directory: sandbox.directory, now: { clock.now }), transport: network.transport,
                        defaults: sandbox.defaults, deviceLanguages: { ["en-US"] }, options: options, now: { clock.now })
    }

    private func refresh(_ feed: HomeFeed, file: StaticString = #filePath, line: Int = #line) {
        var done = false
        feed.refresh { done = true }
        check(homeWait { done }, "the refresh ends", file: file, line: line)
        homeSettle(0.05)
    }

    private func libraryChanges(_ count: Int = 1) {
        for _ in 0..<count { NotificationCenter.default.post(name: .libraryDidChange, object: nil) }
    }

    private func leaveTheForeground() {
        NotificationCenter.default.post(name: leave, object: nil)
    }

    func testTheLibraryIsNotFollowedWhileTheExtensionCannotReadIt() {
        eq(TopShelfReloader.followsLibrary, false, "no App Group: the extension does not show the library")
        let reloader = makeReloader(followsLibrary: TopShelfReloader.followsLibrary)
        libraryChanges(3)
        leaveTheForeground()
        eq(reloads, 0, "in front: a change of the library is not even noted")
        inFront = false
        libraryChanges()
        homeSettle(0.1)
        eq(reloads, 0, "in the background: nothing told")

        // The Home still is.
        inFront = true
        refresh(makeFeed())
        leaveTheForeground()
        eq(reloads, 1, "a refresh of the Home that brought new lists is told")
        _ = reloader
    }

    func testChangesAreToldWhenTheAppLeavesTheForeground() {
        let reloader = makeReloader()
        leaveTheForeground()
        eq(reloads, 0, "nothing changed: nothing to tell")

        // A film saves its position every few seconds: noted, not told.
        libraryChanges(5)
        homeSettle(0.05)
        eq(reloads, 0, "in front: the shelf cannot be seen")
        leaveTheForeground()
        eq(reloads, 1, "told when the app leaves the foreground")
        leaveTheForeground()
        eq(reloads, 1, "once")

        libraryChanges()
        leaveTheForeground()
        eq(reloads, 2, "the next change, the next time")

        // Started twice: still one observer of each.
        reloader.start()
        libraryChanges()
        leaveTheForeground()
        eq(reloads, 3, "one call, not two")
    }

    func testARefreshOfTheHomeCountsWhenItBroughtSomething() {
        let reloader = makeReloader()
        let feed = makeFeed()
        refresh(feed)
        eq(reloads, 0, "in front: only noted")
        leaveTheForeground()
        eq(reloads, 1, "new lists: told")

        // Everything is fresh: the refresh asks nothing and changes nothing.
        refresh(feed)
        leaveTheForeground()
        eq(reloads, 1, "a refresh that asked nothing is no news")

        // Five hours later every list is asked again.
        clock.now = HomeFixture.now.addingTimeInterval(5 * 3600)
        refresh(feed)
        leaveTheForeground()
        eq(reloads, 2, "newer lists: told")

        // A hub that reached nothing and has nothing: no news either.
        let other = HomeSandbox()
        defer { other.discard() }
        let down = HomeFakeNetwork()
        down.down = Set(HomeRequest.Host.allCases)
        let empty = HomeFeed(store: HomeStore(directory: other.directory), transport: down.transport, defaults: other.defaults)
        refresh(empty)
        leaveTheForeground()
        eq(reloads, 2, "an empty page is not a change")
        _ = reloader
    }

    func testInTheBackgroundABurstIsToldOnce() {
        let reloader = makeReloader()
        inFront = false
        libraryChanges(4)
        eq(reloads, 0, "not in the middle of the burst")
        check(homeWait { self.reloads == 1 }, "told at the next turn of the main queue")
        homeSettle(0.1)
        eq(reloads, 1, "once for the burst")
        leaveTheForeground()
        eq(reloads, 1, "nothing left to tell")

        // The next change in the background is told too.
        libraryChanges()
        check(homeWait { self.reloads == 2 }, "the next change")
        _ = reloader
    }

    func testAReloaderGoneBeforeItsFlushTellsNothing() {
        var reloader: TopShelfReloader? = makeReloader()
        inFront = false
        // The flush is scheduled for the next turn of the main queue; the reloader goes first.
        libraryChanges()
        reloader = nil
        homeSettle(0.1)
        eq(reloads, 0, "the scheduled flush finds no reloader")
        _ = reloader
    }

    func testAReloaderThatIsGoneTellsNothing() {
        var reloader: TopShelfReloader? = makeReloader()
        libraryChanges()
        reloader = nil
        leaveTheForeground()
        homeSettle(0.05)
        eq(reloads, 0, "its observers left with it")
        _ = reloader
    }
}
