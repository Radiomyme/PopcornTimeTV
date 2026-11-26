//
//  ProfileManagerTests.swift
//  PopcornTimeTests
//
//  The profiles (PopcornKit, ProfileManager): the migration of the data from before profiles into
//  the primary profile, creating / renaming / deleting, the active profile, and each profile's
//  library and preferences kept apart. No UserDefaults, no keychain, no network, no real clock.
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
        try? first.create(name: "Alex", avatar: 3)
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
}
