//
//  ProfileManagerTests.swift
//  PopcornTimeTests
//
//  The profiles (PopcornKit, ProfileManager): the migration of the data from before profiles into
//  the primary profile, creating / renaming / deleting, the active profile, and each profile's
//  library and preferences kept apart. Then the same against real defaults (a throwaway domain in
//  a temporary folder, as the apps' `DefaultsProfileStorage` reads them): every store kept apart, a
//  deletion that removes one profile's keys and nothing else, a 5.3.0 install migrated, a 5.3.0
//  build still reading the primary profile; and a Trakt answer written into the profile that
//  asked. No keychain, no network, no real clock.
//

import Foundation
import XCTest
@testable import PopcornKit

final class ProfileManagerTests: CheckedTestCase {

    private typealias F = LibraryFixtures

    private final class Ids {
        var next = 0
        func make() -> String { next += 1; return "p\(next)" }
    }

    private func manager(_ storage: MemoryLibraryStorage, center: NotificationCenter = NotificationCenter(),
                         erased: ((Profile) -> Void)? = nil, ids: Ids = Ids()) -> ProfileManager {
        let clock = F.Clock("2026-11-25T12:00:00Z")
        return ProfileManager(storage: storage, defaultName: "Me", center: center, makeID: ids.make, now: { clock.now },
                              eraseExternal: erased ?? { _ in })
    }

    private func library(_ manager: ProfileManager, _ id: String, clock: F.Clock) -> Library {
        return Library(storage: manager.storage(for: id), guideDirectory: nil, remote: .offline,
                       center: NotificationCenter(), now: { clock.now })
    }

    /// What a 5.x install has stored: progress, watched marks, a watchlist, preferences.
    private func storage5x() -> MemoryLibraryStorage {
        return MemoryLibraryStorage([
            "moviesProgress": ["tt0816692": Float(0.55)] as [String: Any],
            "moviesWatchedlist": ["tt1375666"],
            "episodesProgress": ["tt0903747-s1e1": Float(0.42)] as [String: Any],
            "moviesWatchlist": [["imdb_id": "tt0111161", "title": "The Shawshank Redemption", "year": "1994"]],
            "preferredAudioLanguage": "Français",
            "preferredSubtitleLanguage": "English",
        ])
    }

    // MARK: - Migration

    func testAFreshInstallGetsThePrimaryProfile() {
        let storage = MemoryLibraryStorage()
        let profiles = manager(storage)
        eq(profiles.profiles.map(\.id), [Profile.primaryID], "one profile, the primary one")
        eq(profiles.active.name, "Me", "named with the default name")
        eq(profiles.activeID, Profile.primaryID, "and active")
        check(!profiles.asksAtLaunch, "no « Who's Watching? » with one profile")
        check(storage.object(forKey: ProfileManager.profilesKey) is Data, "the list is stored")
        eq(storage.object(forKey: ProfileManager.activeKey) as? String, Profile.primaryID, "the active profile is stored")
    }

    func testTheDataFromBeforeProfilesBecomesThePrimaryProfilesWithoutACopy() {
        let storage = storage5x()
        let before = Set(storage.keys)
        let profiles = manager(storage)
        eq(Set(storage.keys).subtracting(before), [ProfileManager.profilesKey, ProfileManager.activeKey],
           "only the profiles' two keys are added: nothing is copied")
        for key in before {
            check(storage.object(forKey: key) != nil, "\(key) is still where it was (an older build still reads it)")
        }

        let clock = F.Clock("2026-11-25T12:00:00Z")
        let primary = library(profiles, Profile.primaryID, clock: clock)
        check(primary.isWatched("tt1375666"), "the primary profile has the watched movie")
        eq(primary.progress("tt0816692"), 0.55, "…the movie in progress")
        check(primary.continueWatching().contains { $0.mediaID == "tt0816692" }, "…its Continue Watching card")
        check(primary.isInWatchlist("tt0111161"), "…the watchlist")
        eq(profiles.scopedKey("preferredAudioLanguage"), "preferredAudioLanguage", "…and the language preferences, under their keys")
    }

    func testTheMigrationRunsOnce() {
        let storage = storage5x()
        let first = manager(storage)
        _ = try? first.create(name: "Alex", avatar: 3)
        let data = storage.object(forKey: ProfileManager.profilesKey) as? Data

        let second = manager(storage)
        eq(second.profiles.map(\.name), ["Me", "Alex"], "the next launch reads the profiles back")
        eq(storage.object(forKey: ProfileManager.profilesKey) as? Data, data, "and does not write them again")
        eq(second.profiles[1].avatar, 3, "with their avatars")
    }

    func testADamagedListGetsThePrimaryProfileBack() {
        let storage = storage5x()
        storage.set(Data("not json".utf8), forKey: ProfileManager.profilesKey)
        storage.set("p9", forKey: ProfileManager.activeKey)
        let profiles = manager(storage)
        eq(profiles.profiles.map(\.id), [Profile.primaryID], "an unreadable list: the primary profile again")
        eq(profiles.activeID, Profile.primaryID, "an unknown active profile: the primary one")
        eq(storage.object(forKey: ProfileManager.activeKey) as? String, Profile.primaryID, "…stored")
        check(library(profiles, Profile.primaryID, clock: F.Clock("2026-11-25T12:00:00Z")).isWatched("tt1375666"),
              "the data is still the primary profile's")
    }

    func testAListWithoutThePrimaryProfileGetsItBack() {
        let storage = MemoryLibraryStorage()
        let other = Profile(id: "p1", name: "Alex", avatar: 2, createdAt: F.date("2026-11-20T12:00:00Z"))
        storage.set(try? JSONEncoder().encode([other]), forKey: ProfileManager.profilesKey)
        let profiles = manager(storage)
        eq(profiles.profiles.map(\.id), [Profile.primaryID, "p1"], "the primary profile first, the other kept")
    }

    // MARK: - Creating, renaming

    func testCreatingRenamingAndTheirRules() throws {
        let center = NotificationCenter()
        var changes = 0
        let token = center.addObserver(forName: .profilesDidChange, object: nil, queue: nil) { _ in changes += 1 }
        defer { center.removeObserver(token) }
        let profiles = manager(MemoryLibraryStorage(), center: center)

        let alex = try profiles.create(name: "  Alex  ", avatar: 1)
        eq(alex.name, "Alex", "the name is trimmed")
        eq(alex.id, "p1", "a new id")
        eq(profiles.activeID, Profile.primaryID, "a new profile is not made active")
        check(profiles.asksAtLaunch, "two profiles: « Who's Watching? » at launch")
        eq(changes, 1, "a creation is posted")

        func error(_ body: () throws -> Void) -> ProfileManager.ProfileError? {
            do { try body(); return nil } catch { return error as? ProfileManager.ProfileError }
        }
        eq(error { try profiles.create(name: "   ", avatar: 0) }, .emptyName, "an empty name is refused")
        eq(error { try profiles.create(name: "alex", avatar: 0) }, .duplicateName, "the same name, another case, is refused")
        eq(error { try profiles.create(name: "Mé", avatar: 0) }, .duplicateName, "…and with an accent")
        eq(error { try profiles.update("p1", name: "ME") }, .duplicateName, "renaming to another profile's name too")
        eq(error { try profiles.update("nobody", name: "Sam") }, .unknownProfile, "an unknown profile")

        let long = try profiles.create(name: String(repeating: "x", count: 40), avatar: 0)
        eq(long.name.count, ProfileManager.maxNameLength, "a long name is cut")

        try profiles.update("p1", name: "Alexandra", avatar: 7)
        eq(profiles.profile(withID: "p1")?.name, "Alexandra", "renamed")
        eq(profiles.profile(withID: "p1")?.avatar, 7, "another avatar")
        try profiles.update("p1", name: "alexandra")
        eq(profiles.profile(withID: "p1")?.name, "alexandra", "a profile may keep its own name in another case")
        try profiles.update(Profile.primaryID, name: "Dad")
        eq(profiles.active.name, "Dad", "the primary profile can be renamed")

        try profiles.create(name: "Sam", avatar: 2)
        try profiles.create(name: "Kim", avatar: 3)
        eq(profiles.profiles.count, ProfileManager.maxProfiles, "five profiles")
        check(!profiles.canAddProfile, "no sixth")
        eq(error { try profiles.create(name: "Lou", avatar: 4) }, .tooManyProfiles, "a sixth is refused")
    }

    // MARK: - Switching

    func testActivating() throws {
        let center = NotificationCenter()
        var switches = 0
        let token = center.addObserver(forName: .activeProfileDidChange, object: nil, queue: nil) { _ in switches += 1 }
        defer { center.removeObserver(token) }
        let storage = MemoryLibraryStorage()
        let profiles = manager(storage, center: center)
        let alex = try profiles.create(name: "Alex", avatar: 1)

        check(profiles.activate(alex.id), "Alex becomes active")
        eq(profiles.active.name, "Alex", "the active profile")
        eq(switches, 1, "the switch is posted")
        check(profiles.activate(alex.id), "activating it again")
        eq(switches, 1, "…posts nothing")
        check(!profiles.activate("nobody"), "an unknown profile is not activated")
        eq(profiles.activeID, alex.id, "…and nothing changes")

        eq(manager(storage).activeID, alex.id, "the next launch starts with the last profile")
    }

    // MARK: - Each profile's own data

    func testEachProfileHasItsOwnLibrary() throws {
        let storage = storage5x()
        let profiles = manager(storage)
        let alex = try profiles.create(name: "Alex", avatar: 1)
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let me = library(profiles, Profile.primaryID, clock: clock)
        let other = library(profiles, alex.id, clock: clock)

        check(!other.isWatched("tt1375666"), "a new profile has no watched marks")
        check(other.continueWatching().isEmpty, "…no Continue Watching")
        check(other.watchlist(.movie).isEmpty, "…an empty watchlist")

        _ = other.setProgress(0.3, id: "tt0468569", list: .movies, details: PlaybackDetails(title: "The Dark Knight", runtime: 152))
        _ = other.setWatched(true, id: "tt0133093", list: .movies)
        _ = other.addToWatchlist(["imdb_id": "tt0109830", "title": "Forrest Gump", "year": "1994"], id: "tt0109830", list: .movies)
        _ = other.setProgress(0.5, id: "tt0944947-s1e2", list: .episodes)

        eq(Set(other.continueWatching().map(\.mediaID)), ["tt0468569", "tt0944947-s1e2"], "Alex's Continue Watching has Alex's movie and episode")
        check(other.isWatched("tt0133093") && other.isInWatchlist("tt0109830"), "Alex's marks and watchlist")
        check(!me.isWatched("tt0133093"), "Me does not see Alex's watched mark")
        check(!me.isInWatchlist("tt0109830"), "…nor Alex's watchlist")
        check(!me.continueWatching().contains { $0.mediaID == "tt0468569" }, "…nor Alex's movie in progress")
        eq(me.progress("tt0944947-s1e2"), 0, "…nor Alex's episode")
        eq(me.progress("tt0816692"), 0.55, "Me keeps its own progress")

        let alexKeys = storage.keys.filter { $0.hasPrefix("profile.\(alex.id).") }
        check(alexKeys.contains("profile.\(alex.id).moviesProgress"), "Alex's progress is under Alex's prefix", "\(alexKeys)")
        check(alexKeys.contains("profile.\(alex.id).continueWatchingEntries"), "…and Alex's resume entries")
        eq((storage.object(forKey: "moviesProgress") as? [String: Any])?.keys.sorted(), ["tt0816692"], "the primary profile's keys are untouched")

        // The same libraries read again from the storage (a relaunch).
        let again = library(profiles, alex.id, clock: clock)
        eq(Set(again.continueWatching().map(\.mediaID)), ["tt0468569", "tt0944947-s1e2"], "Alex's data is stored, not only in memory")
    }

    func testPreferencesAndTraktAreTheActiveProfiles() throws {
        let profiles = manager(MemoryLibraryStorage())
        let alex = try profiles.create(name: "Alex", avatar: 1)
        eq(profiles.scopedKey("preferredSubtitleLanguage"), "preferredSubtitleLanguage", "the primary profile: the plain key")
        eq(profiles.traktCredentialIdentifier, "trakt", "…and the Trakt account signed in before profiles")
        profiles.activate(alex.id)
        eq(profiles.scopedKey("preferredSubtitleLanguage"), "profile.\(alex.id).preferredSubtitleLanguage", "Alex: under Alex's prefix")
        eq(profiles.traktCredentialIdentifier, "trakt.\(alex.id)", "…and Alex's own Trakt account")
    }

    // MARK: - Deleting

    func testDeletingAProfileRemovesAllOfItsDataAndOnlyIts() throws {
        let storage = storage5x()
        let center = NotificationCenter()
        var switches = 0
        let token = center.addObserver(forName: .activeProfileDidChange, object: nil, queue: nil) { _ in switches += 1 }
        defer { center.removeObserver(token) }
        var erased: [String] = []
        let profiles = manager(storage, center: center, erased: { erased.append($0.id) })
        let alex = try profiles.create(name: "Alex", avatar: 1)
        let sam = try profiles.create(name: "Sam", avatar: 2)
        let clock = F.Clock("2026-11-25T12:00:00Z")
        _ = library(profiles, alex.id, clock: clock).setWatched(true, id: "tt0133093", list: .movies)
        _ = library(profiles, sam.id, clock: clock).setWatched(true, id: "tt0133093", list: .movies)
        storage.set("Deutsch", forKey: "profile.\(alex.id).preferredAudioLanguage")
        profiles.activate(alex.id)
        switches = 0
        let primaryBefore = Dictionary(uniqueKeysWithValues: storage5x().keys.map { ($0, String(describing: storage.object(forKey: $0))) })

        try profiles.delete(alex.id)
        eq(profiles.profiles.map(\.name), ["Me", "Sam"], "Alex is gone")
        check(storage.keys.allSatisfy { !$0.hasPrefix("profile.\(alex.id).") }, "every key of Alex is removed")
        eq(erased, [alex.id], "Alex's Trakt credential is erased")
        eq(profiles.activeID, Profile.primaryID, "the active profile deleted: the primary one is active")
        eq(switches, 1, "…and the switch is posted")
        check(library(profiles, sam.id, clock: clock).isWatched("tt0133093"), "Sam keeps Sam's data")
        for (key, value) in primaryBefore {
            eq(String(describing: storage.object(forKey: key)), value, "the primary profile's \(key) is untouched")
        }

        do {
            try profiles.delete(Profile.primaryID)
            XCTFail("the primary profile was deleted")
        } catch {
            eq(error as? ProfileManager.ProfileError, .cannotDeletePrimary, "the primary profile cannot be deleted")
        }
        check(storage.object(forKey: "moviesWatchedlist") != nil, "…its data stays")
        do {
            try profiles.delete(alex.id)
            XCTFail("a deleted profile was deleted again")
        } catch {
            eq(error as? ProfileManager.ProfileError, .unknownProfile, "deleting it again: unknown")
        }

        let recreated = try profiles.create(name: "Alex", avatar: 1)
        check(!library(profiles, recreated.id, clock: clock).isWatched("tt0133093"), "a new Alex starts empty")
    }

    func testDeletingAnInactiveProfileKeepsTheActiveOne() throws {
        let profiles = manager(MemoryLibraryStorage())
        let alex = try profiles.create(name: "Alex", avatar: 1)
        let sam = try profiles.create(name: "Sam", avatar: 2)
        profiles.activate(sam.id)
        try profiles.delete(alex.id)
        eq(profiles.activeID, sam.id, "Sam stays active")
    }

    // MARK: - A Trakt answer on its way

    func testATraktAnswerGoesToTheProfileThatAsked() throws {
        let storage = storage5x()
        let profiles = manager(storage)
        let alex = try profiles.create(name: "Alex", avatar: 1)
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let libraries = [Profile.primaryID: library(profiles, Profile.primaryID, clock: clock),
                         alex.id: library(profiles, alex.id, clock: clock)]
        _ = libraries[alex.id]!.addToWatchlist(["imdb_id": "tt0109830", "title": "Forrest Gump", "year": "1994"],
                                               id: "tt0109830", list: .movies)
        var shown: [[String]] = []
        // What WatchlistManager.getWatchlist does: asked with Me's account…
        let deliver = profiles.answerForActiveProfile(write: { (profileID, ids: [String]) in
            libraries[profileID]!.replaceWatchlist(ids.map { ["imdb_id": $0, "title": $0, "year": "2001"] }, list: .movies)
        }, show: { shown.append($0) })

        // …Alex is picked while the answer is on its way.
        profiles.activate(alex.id)
        deliver(["tt0120737"])
        check(libraries[Profile.primaryID]!.isInWatchlist("tt0120737"), "Me's Trakt watchlist goes to Me")
        check(!libraries[Profile.primaryID]!.isInWatchlist("tt0111161"), "…in place of Me's list")
        check(libraries[alex.id]!.isInWatchlist("tt0109830"), "Alex's watchlist is not replaced")
        check(!libraries[alex.id]!.isInWatchlist("tt0120737"), "…nor given Me's titles")
        check(storage.object(forKey: "profile.\(alex.id).moviesWatchlist").map { "\($0)".contains("tt0120737") } != true,
              "nothing of Me's list is stored under Alex's keys")
        eq(shown, [], "Alex's screen is not shown Me's list")

        // Asked by Alex, answered while Alex still watches: written and shown.
        let alexAsks = profiles.answerForActiveProfile(write: { (profileID, ids: [String]) in
            _ = libraries[profileID]!.setWatched(true, id: ids[0], list: .movies)
        }, show: { shown.append($0) })
        alexAsks(["tt0133093"])
        check(libraries[alex.id]!.isWatched("tt0133093"), "Alex's own answer is Alex's")
        check(!libraries[Profile.primaryID]!.isWatched("tt0133093"), "…not Me's")
        eq(shown, [["tt0133093"]], "and shown on Alex's screen")

        // Asked by Alex, answered once Alex was deleted: dropped, Alex's keys do not come back.
        var written = 0
        let lateForAlex = profiles.answerForActiveProfile(write: { (_, _: [String]) in written += 1 }, show: { shown.append($0) })
        try profiles.delete(alex.id)
        lateForAlex(["tt0468569"])
        eq(written, 0, "nothing is written for a deleted profile")
        eq(shown.count, 1, "nor shown")
        check(storage.keys.allSatisfy { !$0.hasPrefix("profile.\(alex.id).") }, "no key of Alex's is left")
    }

    // MARK: - Real defaults

    /// A defaults domain of its own for one test: a file in a temporary folder (see
    /// RecentSearchesTests), seen as the apps see the standard defaults (`DefaultsProfileStorage`).
    private final class RealDefaults {
        let domain: String
        let suite: UserDefaults

        init(_ name: String) {
            let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("PopcornTimeTests-defaults")
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            domain = (folder as NSString).appendingPathComponent("\(name)-\(UUID().uuidString)")
            suite = UserDefaults(suiteName: domain)!
            suite.removePersistentDomain(forName: domain)
        }

        func storage() -> DefaultsProfileStorage {
            return DefaultsProfileStorage(defaults: suite, domain: domain)
        }

        /// What is stored, as the defaults' file holds it.
        var stored: [String: Any] {
            return suite.persistentDomain(forName: domain) ?? [:]
        }

        func discard() {
            suite.removePersistentDomain(forName: domain)
            suite.synchronize()
            try? FileManager.default.removeItem(atPath: domain + ".plist")
        }
    }

    private func manager(_ defaults: RealDefaults, ids: [String] = ["p1", "p2", "p3", "p4"]) -> ProfileManager {
        var remaining = ids
        let clock = F.Clock("2026-11-25T12:00:00Z")
        return ProfileManager(storage: defaults.storage(), defaultName: "Me", center: NotificationCenter(),
                              makeID: { remaining.isEmpty ? UUID().uuidString : remaining.removeFirst() },
                              now: { clock.now }, eraseExternal: { _ in })
    }

    private func taste(_ storage: LibraryStorage, clock: F.Clock) -> ProfileTaste {
        return ProfileTaste(storage: storage, center: NotificationCenter(), now: { clock.now })
    }

    /// Two values the same as stored (a dictionary, an array, Data, a number…).
    private func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a = a, let b = b else { return a == nil && b == nil }
        return (a as AnyObject).isEqual(b)
    }

    private static let darkKnight = PlaybackDetails(title: "The Dark Knight", runtime: 152)
    private static let arrival = TasteTitle(imdbID: "tt2543164", kind: .movie, genres: ["Sci-Fi", "Drama"], year: 2016)

    func testEveryStoreIsTheProfilesOwnInRealDefaults() throws {
        let defaults = RealDefaults("profiles-stores")
        defer { defaults.discard() }
        let profiles = manager(defaults)
        let alex = try profiles.create(name: "Alex", avatar: 1)
        let clock = F.Clock("2026-11-25T12:00:00Z")
        let me = library(profiles, Profile.primaryID, clock: clock)
        let them = library(profiles, alex.id, clock: clock)
        let searches = RecentSearches(defaults: defaults.suite, profiles: profiles)

        // Me's data, under the plain keys.
        _ = me.setProgress(0.4, id: "tt0816692", list: .movies)
        searches.add("Interstellar")
        defaults.suite.set("Français", forKey: profiles.scopedKey("preferredAudioLanguage"))
        taste(profiles.storage(for: Profile.primaryID), clock: clock)
            .notePlayback(of: TasteTitle(imdbID: "tt0816692", kind: .movie, genres: ["Sci-Fi"], year: 2014), progress: 1, isFinished: true)

        // Alex's, with Alex active: each store the apps keep per profile.
        profiles.activate(alex.id)
        eq(searches.queries, [], "a screen kept across the switch shows Alex's searches: none")
        _ = them.setProgress(0.3, id: "tt0468569", list: .movies, details: ProfileManagerTests.darkKnight)
        _ = them.setWatched(true, id: "tt0133093", list: .movies)
        _ = them.addToWatchlist(["imdb_id": "tt0109830", "title": "Forrest Gump", "year": "1994"], id: "tt0109830", list: .movies)
        _ = them.acknowledgements.acknowledge("tt0944947", through: EpisodeNumber(season: 1, episode: 3))
        searches.add("Arrival")
        defaults.suite.set("Deutsch", forKey: profiles.scopedKey("preferredAudioLanguage"))
        defaults.suite.set("English", forKey: profiles.scopedKey("preferredSubtitleLanguage"))
        taste(profiles.storage(for: alex.id), clock: clock).notePlayback(of: ProfileManagerTests.arrival, progress: 1, isFinished: true)

        eq(searches.queries, ["Arrival"], "Alex's recent searches")
        eq(defaults.suite.string(forKey: profiles.scopedKey("preferredAudioLanguage")), "Deutsch", "Alex's audio language")
        eq(profiles.traktCredentialIdentifier, "trakt.\(alex.id)", "Alex's Trakt account")

        // Back to Me: nothing of Alex's shows through.
        profiles.activate(Profile.primaryID)
        eq(searches.queries, ["Interstellar"], "Me's recent searches, without Alex's")
        eq(defaults.suite.string(forKey: profiles.scopedKey("preferredAudioLanguage")), "Français", "Me's audio language")
        check(defaults.suite.object(forKey: profiles.scopedKey("preferredSubtitleLanguage")) == nil, "…and no subtitle language of Alex's")
        eq(profiles.traktCredentialIdentifier, "trakt", "Me's Trakt account")
        let meAgain = library(profiles, Profile.primaryID, clock: clock)
        eq(meAgain.progress("tt0816692"), 0.4, "Me's position, read back from the defaults")
        eq(meAgain.progress("tt0468569"), 0, "not Alex's")
        check(!meAgain.isWatched("tt0133093") && !meAgain.isInWatchlist("tt0109830"), "nor Alex's marks and watchlist")
        check(!meAgain.continueWatching().contains { $0.mediaID == "tt0468569" }, "nor Alex's Continue Watching")
        check(defaults.suite.object(forKey: NewEpisodesAcknowledgements.storageKey) == nil, "nor the new episodes Alex has seen")
        let myTaste = taste(profiles.storage(for: Profile.primaryID), clock: clock).snapshot()
        check(myTaste.genres["Drama"] == nil, "nor Alex's taste")

        // Alex's, read back from the defaults (a relaunch).
        let alexAgain = library(profiles, alex.id, clock: clock)
        check(alexAgain.continueWatching().contains { $0.mediaID == "tt0468569" }, "Alex's Continue Watching is stored")
        check(alexAgain.isWatched("tt0133093") && alexAgain.isInWatchlist("tt0109830"), "…Alex's marks and watchlist")
        check(defaults.suite.object(forKey: "profile.\(alex.id).\(NewEpisodesAcknowledgements.storageKey)") != nil, "…the new episodes seen")
        check((taste(profiles.storage(for: alex.id), clock: clock).snapshot().genres["Drama"] ?? 0) > 0, "…Alex's taste")

        // Deleting Alex takes every one of them, and nothing of Me's.
        try profiles.delete(alex.id)
        let left = defaults.stored.keys.filter { $0.hasPrefix("profile.") }
        eq(left.sorted(), [], "nothing of Alex's is left in the defaults")
        eq(searches.queries, ["Interstellar"], "Me keeps Me's searches")
        eq(library(profiles, Profile.primaryID, clock: clock).progress("tt0816692"), 0.4, "…and Me's position")
    }

    func testDeletingFromRealDefaultsRemovesThatProfilesKeysOnly() throws {
        let defaults = RealDefaults("profiles-delete")
        defer { defaults.discard() }
        for (key, value) in storage5x().keys.map({ ($0, storage5x().object(forKey: $0)!) }) {
            defaults.suite.set(value, forKey: key)
        }
        defaults.suite.set(["Dune"], forKey: RecentSearches.defaultsKey)
        defaults.suite.set(true, forKey: "tosAccepted")
        // p10 begins with p1: only "profile.p1." is p1's.
        let profiles = manager(defaults, ids: ["p1", "p10"])
        let p1 = try profiles.create(name: "Alex", avatar: 1)
        let p10 = try profiles.create(name: "Sam", avatar: 2)
        eq([p1.id, p10.id], ["p1", "p10"], "the two ids")
        let clock = F.Clock("2026-11-25T12:00:00Z")
        for id in [p1.id, p10.id] {
            _ = library(profiles, id, clock: clock).setProgress(0.3, id: "tt0468569", list: .movies, details: ProfileManagerTests.darkKnight)
            _ = library(profiles, id, clock: clock).addToWatchlist(["imdb_id": "tt0109830", "title": "Forrest Gump", "year": "1994"],
                                                                   id: "tt0109830", list: .movies)
            defaults.suite.set(["Arrival"], forKey: ProfileManager.prefix(of: id) + RecentSearches.defaultsKey)
            defaults.suite.set("Deutsch", forKey: ProfileManager.prefix(of: id) + "preferredAudioLanguage")
            taste(profiles.storage(for: id), clock: clock).notePlayback(of: ProfileManagerTests.arrival, progress: 1, isFinished: true)
        }
        // Keys the apps never write under a profile: a deletion must not care.
        defaults.suite.set(1, forKey: "profile.p1")
        defaults.suite.set(1, forKey: "profile.p1x.moviesProgress")
        let before = defaults.stored
        check(before.keys.contains("profile.p1.moviesProgress") && before.keys.contains("profile.p10.moviesProgress"),
              "both profiles' data is in the defaults' file", "\(before.keys.sorted())")

        try profiles.delete(p1.id)
        let after = defaults.stored
        let gone = Set(before.keys).subtracting(after.keys)
        check(!gone.isEmpty && gone.allSatisfy { $0.hasPrefix("profile.p1.") }, "only keys under « profile.p1. » are removed",
              "\(gone.sorted())")
        check(!after.keys.contains { $0.hasPrefix("profile.p1.") }, "and every one of them")
        eq(Set(after.keys).subtracting(before.keys), [], "nothing is added")
        for (key, value) in before where !key.hasPrefix("profile.p1.") && key != ProfileManager.profilesKey {
            check(same(after[key], value), "\(key) is unchanged")
        }
        eq(profiles.profiles.map(\.id), [Profile.primaryID, "p10"], "Alex is gone, Sam stays")
        eq(manager(defaults).profiles.map(\.id), [Profile.primaryID, "p10"], "…as the next launch reads it")
    }

    /// What a 5.3.0 install has in its defaults: the library under the plain keys (written by
    /// 5.3.0's `Library`, which used the standard defaults themselves), the preferences, the
    /// searches, the device's settings.
    private func seed530(_ defaults: RealDefaults, clock: F.Clock) {
        let plain = defaults.storage()
        let library = Library(storage: plain, guideDirectory: nil, remote: .offline, center: NotificationCenter(), now: { clock.now })
        _ = library.setProgress(0.55, id: "tt0816692", list: .movies, details: PlaybackDetails(title: "Interstellar", runtime: 169))
        _ = library.setWatched(true, id: "tt1375666", list: .movies)
        _ = library.setProgress(0.42, id: "tt0903747-s1e1", list: .episodes)
        _ = library.addToWatchlist(["imdb_id": "tt0111161", "title": "The Shawshank Redemption", "year": "1994"],
                                   id: "tt0111161", list: .movies)
        _ = library.acknowledgements.acknowledge("tt0944947", through: EpisodeNumber(season: 2, episode: 1))
        defaults.suite.set("Français", forKey: "preferredAudioLanguage")
        defaults.suite.set("English", forKey: "preferredSubtitleLanguage")
        defaults.suite.set(["Dune", "Severance"], forKey: RecentSearches.defaultsKey)
        defaults.suite.set(Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74]), forKey: "subtitleSettings")
        defaults.suite.set(true, forKey: "tosAccepted")
        defaults.suite.set(false, forKey: Library.bulkEpisodeLookupKey)
    }

    func testMigratingA530InstallChangesNothingOfItsData() {
        let defaults = RealDefaults("profiles-530")
        defer { defaults.discard() }
        let clock = F.Clock("2026-11-20T12:00:00Z")
        seed530(defaults, clock: clock)
        let before = defaults.stored
        check(before.keys.contains(ContinueWatchingStore.storageKey), "5.3.0 has stored its Continue Watching entries")

        let profiles = manager(defaults)
        let after = defaults.stored
        eq(Set(after.keys).subtracting(before.keys), [ProfileManager.profilesKey, ProfileManager.activeKey],
           "only the profiles' two keys are added")
        for (key, value) in before {
            check(same(after[key], value), "\(key) is stored exactly as 5.3.0 left it")
        }
        eq(profiles.profiles.map(\.id), [Profile.primaryID], "one profile, the primary one")
        check(!profiles.asksAtLaunch, "no « Who's Watching? » after the update")

        let primary = library(profiles, Profile.primaryID, clock: clock)
        check(primary.isWatched("tt1375666"), "the primary profile has the watched movie")
        eq(primary.progress("tt0903747-s1e1"), 0.42, "…the episode in progress")
        check(primary.continueWatching().contains { $0.mediaID == "tt0816692" && $0.title == "Interstellar" },
              "…the Continue Watching card, with its title")
        check(primary.isInWatchlist("tt0111161"), "…the watchlist")
        eq(RecentSearches(defaults: defaults.suite, profiles: profiles).queries, ["Dune", "Severance"], "…the recent searches")
        eq(defaults.suite.string(forKey: profiles.scopedKey("preferredAudioLanguage")), "Français", "…the audio language")
        check(!primary.isBulkEpisodeLookupEnabled, "the device's settings stay as they were")
        eq(manager(defaults).profiles.map(\.id), [Profile.primaryID], "the next launch migrates nothing again")
    }

    func testA530BuildStillReadsThePrimaryProfileAfterTheUpdate() throws {
        let defaults = RealDefaults("profiles-downgrade")
        defer { defaults.discard() }
        let clock = F.Clock("2026-11-20T12:00:00Z")
        seed530(defaults, clock: clock)

        // The update: two profiles, both used.
        let profiles = manager(defaults)
        let alex = try profiles.create(name: "Alex", avatar: 1)
        _ = library(profiles, Profile.primaryID, clock: clock).setProgress(0.7, id: "tt0816692", list: .movies)
        RecentSearches(defaults: defaults.suite, profiles: profiles).add("Arrival")
        profiles.activate(alex.id)
        _ = library(profiles, alex.id, clock: clock).setWatched(true, id: "tt0133093", list: .movies)
        RecentSearches(defaults: defaults.suite, profiles: profiles).add("The Matrix")
        defaults.suite.set("Deutsch", forKey: profiles.scopedKey("preferredAudioLanguage"))

        // 5.3.0 installed again: it reads the plain keys and knows nothing of profiles.
        let old = Library(storage: defaults.storage(), guideDirectory: nil, remote: .offline, center: NotificationCenter(), now: { clock.now })
        eq(old.progress("tt0816692"), 0.7, "5.3.0 sees the primary profile's latest position")
        check(old.isWatched("tt1375666") && old.isInWatchlist("tt0111161"), "…its marks and watchlist")
        check(!old.isWatched("tt0133093"), "…not Alex's")
        eq(defaults.suite.stringArray(forKey: RecentSearches.defaultsKey), ["Arrival", "Dune", "Severance"], "…the primary profile's searches")
        eq(defaults.suite.string(forKey: "preferredAudioLanguage"), "Français", "…its audio language, not Alex's")
        _ = old.setWatched(true, id: "tt0468569", list: .movies)

        // Updated again: the profiles are all there, and what 5.3.0 did is the primary profile's.
        let again = manager(defaults)
        eq(again.profiles.map(\.name), ["Me", "Alex"], "the profiles survive the round trip")
        eq(again.activeID, alex.id, "the last profile is still the one watching")
        check(library(again, Profile.primaryID, clock: clock).isWatched("tt0468569"), "the primary profile has what 5.3.0 marked")
        let alexLibrary = library(again, alex.id, clock: clock)
        check(alexLibrary.isWatched("tt0133093") && !alexLibrary.isWatched("tt0468569"), "Alex keeps Alex's, and only Alex's")
        eq(RecentSearches(defaults: defaults.suite, profiles: again).queries, ["The Matrix"], "Alex's searches")
    }
}
