//
//  LateSubtitlesWatchTests.swift
//  PopcornTimeTests
//
//  LateSubtitlesWatch: the OpenSubtitles list that comes after AVPlayer read the remux's master
//  playlist gets the item rebuilt once, when the player can.
//

import XCTest
import Foundation

final class LateSubtitlesWatchTests: CheckedTestCase {

    func testAListInTheMasterNeedsNothing() {
        var watch = LateSubtitlesWatch()
        // The search answered while the stream prepared: no player has read a master yet.
        watch.listArrived(isEmpty: false, masterServed: false)
        check(!watch.shouldRebuild(isEligible: true), "the list lands in the master the item reads: no rebuild")
    }

    func testAListAfterTheMasterRebuildsTheItemOnce() {
        var watch = LateSubtitlesWatch()
        // A finished download: the player started at the end of the hold, OpenSubtitles answers after.
        watch.listArrived(isEmpty: false, masterServed: true)
        check(watch.isPending, "an item to rebuild")
        check(!watch.shouldRebuild(isEligible: false), "not while the player cannot (a start seek, a recovery, AirPlay…)")
        check(watch.shouldRebuild(isEligible: true), "rebuilt at the first sample it can")
        check(!watch.shouldRebuild(isEligible: true), "…once")
    }

    func testAnEmptyListRebuildsNothing() {
        var watch = LateSubtitlesWatch()
        watch.listArrived(isEmpty: true, masterServed: true)
        check(!watch.shouldRebuild(isEligible: true), "nothing found, or a failed search: the item stays")
    }

    func testAnItemBuiltMeanwhileHasTheList() {
        var watch = LateSubtitlesWatch()
        watch.listArrived(isEmpty: false, masterServed: true)
        // A starvation recovery replaced the item before the watch could: its master has the list.
        watch.attached()
        check(!watch.shouldRebuild(isEligible: true), "no second rebuild for a list the new item already has")
    }
}
