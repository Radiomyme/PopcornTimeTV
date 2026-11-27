//
//  WhatsNewTests.swift
//  PopcornTimeTests
//
//  The "What's new" screen of the three apps (`PopcornTime/UI/Shared SwiftUI/WhatsNew.swift`,
//  compiled into this bundle): the once-per-version rule (`WhatsNewPolicy`) and the notes
//  themselves (`WhatsNewRelease.current`).
//
//  The version the notes describe must be the app's: `decide` never shows notes written for a
//  later version than the running app, so notes "5.3.0" in an app still numbered 5.2.0 would
//  never appear, without any error. The app's version is read here from the project file in the
//  source tree (every `MARKETING_VERSION = …;` of `PopcornTime.xcodeproj/project.pbxproj`):
//  this bundle has no host app, and its own Info.plist carries no version. The test is skipped
//  when the sources are not next to the bundle, like the other tests that read the tree.
//

import XCTest

final class WhatsNewTests: CheckedTestCase {

    private typealias Policy = WhatsNewPolicy

    private func decide(app: String, notes: String, seen: String?, fresh: Bool = false, url: Bool = false) -> Policy.Decision {
        Policy.decide(appVersion: app, notesVersion: notes, lastSeenVersion: seen, isFreshInstall: fresh, launchedFromURL: url)
    }

    // MARK: The rule

    func testNotesNewerThanTheAppAreNeverShown() {
        eq(decide(app: "5.2.0", notes: "5.3.0", seen: "5.2.0"), .skip, "an app still numbered 5.2.0: nothing")
        eq(decide(app: "5.2.0", notes: "5.3.0", seen: nil, fresh: true), .skip, "not even marked on a fresh install")
        eq(decide(app: "5.2.9", notes: "5.3.0", seen: nil), .skip, "numbers compared as numbers")
        eq(decide(app: "5.10.0", notes: "5.3.0", seen: "5.2.0"), .present, "5.10 is after 5.3")
    }

    func testNotesAlreadySeenAreNotShownAgain() {
        eq(decide(app: "5.3.0", notes: "5.3.0", seen: "5.3.0"), .skip, "seen")
        eq(decide(app: "5.3.0", notes: "5.3.0", seen: "5.4.0"), .skip, "a later version's notes seen (a downgrade)")
        eq(decide(app: "5.3.1", notes: "5.3.0", seen: "5.3.0"), .skip, "a bug-fix build with the same notes")
    }

    func testAFreshInstallIsMarkedWithoutShowing() {
        eq(decide(app: "5.3.0", notes: "5.3.0", seen: nil, fresh: true), .markSeenSilently, "a new user: nothing to announce")
        eq(decide(app: "5.3.0", notes: "5.3.0", seen: nil, fresh: true, url: true), .markSeenSilently,
           "also when its first launch opens a link: its next launch must announce nothing")
    }

    func testALaunchByLinkShowsNothingAndRemembersNothing() {
        eq(decide(app: "5.3.0", notes: "5.3.0", seen: "5.2.0", url: true), .skip, "Top Shelf / deep link: straight to the link")
        // Nothing was remembered, so the next normal launch still shows the notes.
        eq(decide(app: "5.3.0", notes: "5.3.0", seen: "5.2.0"), .present, "the next normal launch")
    }

    /// The real path of an update: 5.2.0's notes were seen, the app is now 5.3.0. The notes show
    /// once; `WhatsNewGate.checkAtLaunch` then remembers the notes' version, and the next launch
    /// shows nothing.
    func testAnUpdateFrom520ShowsTheNotesOnce() {
        let notes = WhatsNewRelease.current.version
        var seen: String? = "5.2.0"
        var shown = 0
        for launch in 1...3 {
            let decision = decide(app: notes, notes: notes, seen: seen)
            if decision == .present { shown += 1 }
            if decision == .present || decision == .markSeenSilently { seen = notes }   // as checkAtLaunch does
            eq(decision, launch == 1 ? .present : .skip, "launch \(launch)")
        }
        eq(shown, 1, "shown exactly once")
        eq(seen, notes, "remembered: the notes' version")
    }

    func testAnInstallIsFreshOnlyWithoutAnyKeyAUsedAppWrites() {
        check(Policy.looksLikeFreshInstall(defaultsKeys: []), "no key: fresh")
        check(Policy.looksLikeFreshInstall(defaultsKeys: ["NSWindow Frame main", "AppleLanguages"]), "only system keys: fresh")
        check(!Policy.looksLikeFreshInstall(defaultsKeys: [WhatsNewGate.lastSeenKey]), "notes seen before: not fresh")
        check(!Policy.looksLikeFreshInstall(defaultsKeys: ["moviesProgress"]), "watch progress: not fresh")
        check(!Policy.looksLikeFreshInstall(defaultsKeys: ["autoSelectQuality"]), "a setting: not fresh")
    }

    // MARK: The gate the apps call (`WhatsNewGate`, `WhatsNewLaunchCheck`), on a defaults suite

    /// A UserDefaults suite of its own, emptied, and its name (the persistent domain the
    /// fresh-install test reads).
    private func suite(_ name: String, lastSeen: String? = nil) -> (UserDefaults, String) {
        let domain = "PopcornTimeTests.WhatsNew.\(name)"
        UserDefaults().removePersistentDomain(forName: domain)
        let defaults = UserDefaults(suiteName: domain)!
        if let lastSeen { defaults.set(lastSeen, forKey: WhatsNewGate.lastSeenKey) }
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: domain) }
        return (defaults, domain)
    }

    private func gate(_ defaults: UserDefaults, app: String = "5.3.0", fresh: Bool = false, url: Bool = false) -> Bool {
        WhatsNewGate.checkAtLaunch(isFreshInstall: fresh, launchedFromURL: url, defaults: defaults,
                                   appVersion: app, release: .v5_3_0)
    }

    private var lastSeen: (UserDefaults) -> String? { { $0.string(forKey: WhatsNewGate.lastSeenKey) } }

    func testTheGateShowsAnUpdateFrom520OnceAndRemembersTheNotesVersion() {
        let (defaults, _) = suite("update520", lastSeen: "5.2.0")
        check(gate(defaults), "launch 1 after the update: shown")
        eq(lastSeen(defaults), "5.3.0", "the notes' version is remembered")
        check(!gate(defaults), "launch 2: nothing")
        check(!gate(defaults), "launch 3: nothing")
        eq(lastSeen(defaults), "5.3.0", "still the notes' version")
    }

    func testTheGateRemembersTheNotesVersionNotTheAppsOnABugFixBuild() {
        let (defaults, _) = suite("update531", lastSeen: "5.2.0")
        check(gate(defaults, app: "5.3.1"), "5.3.1 with the 5.3.0 notes, from 5.2.0: shown")
        eq(lastSeen(defaults), "5.3.0", "remembered: the notes' version, not 5.3.1")
        check(!gate(defaults, app: "5.3.1"), "then nothing")
    }

    func testTheGateShowsAnUpdateFrom510AndFromNoMarkerOnce() {
        let (from510, _) = suite("update510", lastSeen: "5.1.0")
        check(gate(from510), "from 5.1.0: shown")
        check(!gate(from510), "once")
        let (noMarker, _) = suite("noMarker")
        check(gate(noMarker), "a used install without any marker (before 5.1): shown")
        eq(lastSeen(noMarker), "5.3.0", "and remembered")
    }

    func testTheGateMarksAFreshInstallWithoutShowing() {
        let (defaults, _) = suite("fresh")
        check(!gate(defaults, fresh: true), "a fresh install: nothing shown")
        eq(lastSeen(defaults), "5.3.0", "but marked: its next launch announces nothing")
        check(!gate(defaults), "next launch: nothing")
    }

    func testTheGateShowsNothingAndRemembersNothingOnALaunchByLink() {
        let (defaults, _) = suite("link", lastSeen: "5.2.0")
        check(!gate(defaults, url: true), "launched by a link: nothing shown")
        eq(lastSeen(defaults), "5.2.0", "nothing remembered")
        check(gate(defaults), "the next normal launch shows the notes")
    }

    func testTheGateShowsNothingInAnAppOlderThanItsNotes() {
        let (defaults, _) = suite("older", lastSeen: "5.2.0")
        check(!gate(defaults, app: "5.2.0"), "an app still numbered 5.2.0")
        eq(lastSeen(defaults), "5.2.0", "nothing remembered")
    }

    func testAFreshInstallIsReadFromTheAppsOwnPersistedKeys() {
        let (defaults, domain) = suite("freshKeys")
        check(WhatsNewGate.looksLikeFreshInstall(defaults: defaults, domainName: domain), "nothing persisted: fresh")
        defaults.set(true, forKey: "NSFullScreenMenuItemEverywhere")
        check(WhatsNewGate.looksLikeFreshInstall(defaults: defaults, domainName: domain), "a system key only: fresh")
        defaults.set(0.4, forKey: "moviesProgress")
        check(!WhatsNewGate.looksLikeFreshInstall(defaults: defaults, domainName: domain), "watch progress: not fresh")
        let (seen, seenDomain) = suite("freshKeysSeen", lastSeen: "5.2.0")
        check(!WhatsNewGate.looksLikeFreshInstall(defaults: seen, domainName: seenDomain), "notes seen before: not fresh")
        check(WhatsNewGate.looksLikeFreshInstall(defaults: seen, domainName: nil), "no domain to read: fresh")
    }

    /// iOS / Mac: the link of a launch by link arrives (`onOpenURL`) BEFORE the check.
    func testALinkBeforeTheLaunchCheckShowsAndRemembersNothing() {
        let (defaults, _) = suite("linkFirst", lastSeen: "5.2.0")
        var launch = WhatsNewLaunchCheck()
        check(!launch.linkOpened(defaults: defaults, now: 10), "nothing to close yet")
        check(!launch.check(isFreshInstall: false, defaults: defaults, appVersion: "5.3.0", release: .v5_3_0, now: 10.3),
              "the check sees the link: nothing shown")
        eq(lastSeen(defaults), "5.2.0", "nothing remembered")
        var next = WhatsNewLaunchCheck()
        check(next.check(isFreshInstall: false, defaults: defaults, appVersion: "5.3.0", release: .v5_3_0, now: 50),
              "the next normal launch shows the notes")
    }

    /// iOS / Mac: the link arrives just AFTER the check showed the notes: they close and are forgotten.
    func testALinkRightAfterTheLaunchCheckClosesTheNotesAndForgetsThem() {
        let (defaults, _) = suite("linkAfter", lastSeen: "5.2.0")
        var launch = WhatsNewLaunchCheck()
        check(launch.check(isFreshInstall: false, defaults: defaults, appVersion: "5.3.0", release: .v5_3_0, now: 10),
              "shown")
        eq(lastSeen(defaults), "5.3.0", "marked when shown")
        check(launch.linkOpened(defaults: defaults, now: 10.4), "the link 0.4 s later closes them")
        eq(lastSeen(defaults), "5.2.0", "and the version seen before is put back")
        check(!launch.linkOpened(defaults: defaults, now: 10.6), "a second link closes nothing more")
        check(!launch.check(isFreshInstall: false, defaults: defaults, appVersion: "5.3.0", release: .v5_3_0, now: 11),
              "the check runs once per launch")
        var next = WhatsNewLaunchCheck()
        check(next.check(isFreshInstall: false, defaults: defaults, appVersion: "5.3.0", release: .v5_3_0, now: 99),
              "the next normal launch shows them")

        let (none, _) = suite("linkAfterNoMarker")
        var first = WhatsNewLaunchCheck()
        check(first.check(isFreshInstall: false, defaults: none, appVersion: "5.3.0", release: .v5_3_0, now: 0), "shown")
        check(first.linkOpened(defaults: none, now: 1), "closed by the link")
        eq(lastSeen(none), nil, "no marker before: none after")
    }

    /// A link long after the notes showed is an ordinary link: the notes stay seen.
    func testALaterLinkLeavesTheNotesAlone() {
        let (defaults, _) = suite("linkLate", lastSeen: "5.2.0")
        var launch = WhatsNewLaunchCheck()
        check(launch.check(isFreshInstall: false, defaults: defaults, appVersion: "5.3.0", release: .v5_3_0, now: 10), "shown")
        check(!launch.linkOpened(defaults: defaults, now: 10 + WhatsNewLaunchCheck.linkWindowSeconds + 1),
              "a link after the window closes nothing")
        eq(lastSeen(defaults), "5.3.0", "the notes stay seen")

        let (fresh, _) = suite("linkFresh")
        var install = WhatsNewLaunchCheck()
        check(!install.check(isFreshInstall: true, defaults: fresh, appVersion: "5.3.0", release: .v5_3_0, now: 0),
              "a fresh install: nothing shown")
        check(!install.linkOpened(defaults: fresh, now: 0.5), "nothing to close")
        eq(lastSeen(fresh), "5.3.0", "still marked: its next launch announces nothing")
    }

    // MARK: The notes

    func testTheCurrentNotesAre550AndTheEarlierOnesAreKept() {
        eq(WhatsNewRelease.current.version, "5.5.0", "current")
        eq(WhatsNewRelease.current.shortVersion, "5.5", "the title's number")
        eq(WhatsNewRelease.v5_4_1.version, "5.4.1", "5.4.1 kept")
        eq(WhatsNewRelease.v5_4_0.version, "5.4.0", "5.4.0 kept")
        eq(WhatsNewRelease.v5_3_0.version, "5.3.0", "5.3.0 kept")
        eq(WhatsNewRelease.v5_2_0.version, "5.2.0", "5.2.0 kept")
        eq(WhatsNewRelease.v5_1_0.version, "5.1.0", "5.1.0 kept")
    }

    func testEveryItemHasItsFourTextsAndASymbol() {
        for release in [WhatsNewRelease.current, .v5_4_1, .v5_4_0, .v5_3_0, .v5_2_0, .v5_1_0] {
            for item in release.items {
                let texts = [item.titleFR, item.bodyFR, item.titleEN, item.bodyEN, item.symbol]
                check(texts.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                      "\(release.version) \(item.id): four texts and a symbol", "\(texts)")
                check(!item.platforms.isEmpty, "\(release.version) \(item.id): on at least one platform")
                eq(item.title(french: true), item.titleFR, "\(item.id): French title")
                eq(item.body(french: false), item.bodyEN, "\(item.id): English body")
            }
        }
    }

    func testIdsAreUniqueInARelease() {
        for release in [WhatsNewRelease.current, .v5_4_1, .v5_4_0, .v5_3_0, .v5_2_0, .v5_1_0] {
            let ids = release.items.map(\.id)
            eq(Set(ids).count, ids.count, "\(release.version): unique ids (\(ids))")
        }
    }

    func testEachPlatformGetsOneToEightItems() {
        for platform in [WhatsNewPlatform.tvOS, .iOS, .macOS] {
            let count = WhatsNewRelease.current.items(for: platform).count
            check((1...8).contains(count), "\(platform): 1 to 8 items", "\(count)")
        }
    }

    /// The product's rule: native first. The notes never offer VLC as the way to play.
    func testTheCurrentNotesNeverOfferVLC() {
        for item in WhatsNewRelease.current.items {
            for text in [item.titleFR, item.bodyFR, item.titleEN, item.bodyEN] {
                check(!text.localizedCaseInsensitiveContains("VLC"), "\(item.id): no VLC in the notes", text)
            }
        }
    }

    func testTheNotesVersionIsTheProjectsMarketingVersion() throws {
        let repository = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = repository.appendingPathComponent("PopcornTime.xcodeproj/project.pbxproj")
        guard let text = try? String(contentsOf: project, encoding: .utf8) else {
            throw XCTSkip("the sources are not next to the test bundle")
        }
        let regex = try NSRegularExpression(pattern: #"MARKETING_VERSION = ([^;]+);"#)
        let versions = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        }
        check(versions.count >= 10, "every target's MARKETING_VERSION is read", "\(versions.count)")
        eq(Set(versions), [WhatsNewRelease.current.version], "every target is numbered as the notes")
        // And the app shows them: the rule lets notes of its own version through.
        eq(decide(app: versions.first ?? "", notes: WhatsNewRelease.current.version, seen: "5.2.0"), .present,
           "an app updated from 5.2.0 shows the notes")
    }
}
