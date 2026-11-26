import Foundation

// Profiles, as on Netflix or Disney+: a few people share one Apple TV (or
// iPhone, or Mac), each with a name, an avatar and their own data.
//
// What is a profile's own (everything else stays the device's):
//   - the library (`Library.shared` is the active profile's): watched marks,
//     playback positions and the Continue Watching entries (with the release
//     to resume), the watchlist, the new episodes already seen;
//   - the preferred audio and subtitle languages and the recent searches
//     (iPhone, iPad; `ProfileManager.scopedKey`);
//   - the taste (`ProfileTaste`: « For You », the languages it learns);
//   - the Trakt account (`ProfileManager.traktCredentialIdentifier`): its
//     lists are synced into the profile that asked for them
//     (`answerForActiveProfile`), and again when another profile becomes
//     active (`TraktManager.followActiveProfile`).
// The device's: the Home's content languages and shelves, the streaming
// services and the TMDB key, the quality and Up Next settings, the subtitle
// appearance and encoding (`SubtitleSettings`: one archive with the size,
// colour and font), the downloads, the caches. The Top Shelf reads no user
// data (the extension cannot read the app's defaults): nothing of it is a
// profile's.
//
// Storage. The profiles' list and the active one are in the standard
// defaults (`profiles`, `activeProfile`). The primary profile — the one
// every install has, made from the data that existed before profiles — keeps
// the keys as they always were ("moviesProgress", "continueWatchingEntries",
// "preferredAudioLanguage"…): migrating is only naming it, nothing is copied
// (tvOS allows the whole defaults domain 1 MB: a copy would double the
// library) and an older build still reads its data. Every other profile has
// the same keys behind its prefix ("profile.<id>.moviesProgress"), so
// deleting it removes every key under the prefix. The primary profile can be
// renamed but not deleted: it is the one the app falls back to.

/// A profile: who is watching.
public struct Profile: Codable, Equatable, Identifiable, Hashable {
    /// The primary profile's id (the data from before profiles).
    public static let primaryID = "primary"

    public let id: String
    public var name: String
    /// An index in the app's avatar list (`ProfileAvatar` in the apps).
    public var avatar: Int
    public let createdAt: Date

    public init(id: String, name: String, avatar: Int, createdAt: Date) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.createdAt = createdAt
    }

    public var isPrimary: Bool { return id == Profile.primaryID }
}

/// Where the profiles' data lives: the standard defaults in the apps, a
/// dictionary in the tests.
public protocol ProfileStorage: LibraryStorage {
    /// Every key stored (to delete a profile's).
    var storedKeys: [String] { get }
}

/// A defaults domain as the profiles' storage: the app's own in the apps
/// (`.standard`), a suite in the tests — the domain is given rather than
/// taken from `Bundle.main`, so the tests delete a profile from real
/// defaults exactly as the apps do.
public final class DefaultsProfileStorage: ProfileStorage {
    public let defaults: UserDefaults
    /// Where the stored keys are listed from.
    private let domain: String?

    public init(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        self.domain = domain
    }

    public func object(forKey key: String) -> Any? {
        return defaults.object(forKey: key)
    }

    public func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public var storedKeys: [String] {
        // The persistent domain only: not the arguments nor the global
        // domain. Without it (no bundle identifier, nothing stored yet),
        // every key the defaults see: a profile's keys are found among
        // them, and nothing else is deleted (only its prefix is).
        let stored = domain.flatMap { defaults.persistentDomain(forName: $0) }
        return Array((stored ?? defaults.dictionaryRepresentation()).keys)
    }
}

extension MemoryLibraryStorage: ProfileStorage {
    public var storedKeys: [String] { return keys }
}

/// A profile's view of the storage: its keys under its prefix ("" for the
/// primary profile). What its `Library` reads and writes.
public final class ProfileScopedStorage: LibraryStorage {
    public let prefix: String
    private let base: LibraryStorage

    public init(base: LibraryStorage, prefix: String) {
        self.base = base
        self.prefix = prefix
    }

    public func object(forKey key: String) -> Any? {
        return base.object(forKey: prefix + key)
    }

    public func set(_ value: Any?, forKey key: String) {
        base.set(value, forKey: prefix + key)
    }
}

public extension Notification.Name {
    /// Posted on the main thread when another profile became the active one
    /// (object: the `ProfileManager`). The apps rebuild their screens.
    static let activeProfileDidChange = Notification.Name("PopcornKit.ProfileManager.activeProfileDidChange")
    /// Posted on the main thread when a profile was added, renamed, given
    /// another avatar or deleted.
    static let profilesDidChange = Notification.Name("PopcornKit.ProfileManager.profilesDidChange")
}

public final class ProfileManager {

    public enum ProfileError: Error, Equatable {
        /// An empty name (once trimmed).
        case emptyName
        /// Another profile already has this name (case and accents ignored).
        case duplicateName
        /// `maxProfiles` profiles exist already.
        case tooManyProfiles
        /// The primary profile cannot be deleted.
        case cannotDeletePrimary
        case unknownProfile
    }

    /// Profiles a device can have (Netflix's number).
    public static let maxProfiles = 5
    /// Characters a name keeps.
    public static let maxNameLength = 20

    static let profilesKey = "profiles"
    static let activeKey = "activeProfile"

    /// The app's profiles, in the standard defaults.
    public static let shared: ProfileManager = {
        #if DEBUG
        // The tvOS UI tests (`-PTDebugLibraryInMemory YES`) never see the
        // simulator's profiles: one primary profile, in memory —
        // `-PTDebugProfiles "Alex,Sam"` adds others (and so the launch
        // screen « Who's Watching? »).
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "PTDebugLibraryInMemory") || defaults.string(forKey: "PTDebugProfiles") != nil {
            let manager = ProfileManager(storage: MemoryLibraryStorage(), defaultName: ProfileManager.localizedDefaultName)
            let names = (defaults.string(forKey: "PTDebugProfiles") ?? "").split(separator: ",")
            for (index, name) in names.enumerated() {
                _ = try? manager.create(name: String(name).trimmingCharacters(in: .whitespaces), avatar: index + 1)
            }
            return manager
        }
        #endif
        return ProfileManager(storage: DefaultsProfileStorage(), defaultName: ProfileManager.localizedDefaultName)
    }()

    /// The primary profile's name when it is made: the app's text, else "Me".
    static var localizedDefaultName: String {
        return Bundle.main.localizedString(forKey: "Profiles.DefaultName", value: "Me", table: nil)
    }

    private let storage: ProfileStorage
    private let center: NotificationCenter
    private let makeID: () -> String
    private let now: () -> Date
    /// Removes what a deleted profile kept outside the storage (its Trakt
    /// credential in the keychain).
    private let eraseExternal: (Profile) -> Void

    private let lock = NSLock()
    private var list: [Profile]
    private var activeProfileID: String

    /// Reads the profiles; the first time (no list stored), makes the
    /// primary profile from the data already there and stores it.
    /// - Parameters:
    ///   - defaultName: the primary profile's name when it is made.
    public init(storage: ProfileStorage, defaultName: String, center: NotificationCenter = .default,
                makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
                now: @escaping () -> Date = Date.init,
                eraseExternal: ((Profile) -> Void)? = nil) {
        self.storage = storage
        self.center = center
        self.makeID = makeID
        self.now = now
        self.eraseExternal = eraseExternal ?? { profile in
            try? OAuthCredential.delete(withIdentifier: ProfileManager.traktCredentialIdentifier(of: profile.id))
        }

        let isFirstLaunchWithProfiles = storage.object(forKey: ProfileManager.profilesKey) == nil
        var stored: [Profile] = []
        if let data = storage.object(forKey: ProfileManager.profilesKey) as? Data,
           let decoded = try? ProfileManager.decoder.decode([Profile].self, from: data) {
            stored = decoded
        }
        // The migration: a first launch with profiles — a fresh install or
        // an update — gets the primary profile, holding what is stored.
        // A list without it (damaged) gets it back too: the data under the
        // plain keys must always have an owner.
        var migrated = false
        if !stored.contains(where: { $0.isPrimary }) {
            let name = String(defaultName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ProfileManager.maxNameLength))
            stored.insert(Profile(id: Profile.primaryID, name: name.isEmpty ? "Me" : name, avatar: 0, createdAt: now()), at: 0)
            migrated = true
        }
        list = stored
        let active = storage.object(forKey: ProfileManager.activeKey) as? String
        activeProfileID = active.flatMap { id in stored.contains { $0.id == id } ? id : nil } ?? Profile.primaryID
        if migrated { save() }
        if active != activeProfileID { storage.set(activeProfileID, forKey: ProfileManager.activeKey) }
        if isFirstLaunchWithProfiles, ProfileManager.isUsedInstall(storage) { keepEarlierNone() }
    }

    /// Before 5.4, « None » in Settings removed the language keys; since,
    /// a key never set means « Automatic » (the language the profile picks
    /// itself) and « None » is stored. An update keeps the meaning a 5.3.0
    /// install had — nothing, as a « None » chosen — until « Automatic » is
    /// picked. (A setting never opened can't be told from a « None ».)
    private func keepEarlierNone() {
        for key in ProfileManager.languageKeys where storage.object(forKey: key) == nil {
            storage.set(AudioLanguagePreference.noneValue, forKey: key)
        }
    }

    /// The primary profile's language settings (Settings' keys).
    static let languageKeys = [AudioLanguagePreference.defaultsKey, "preferredSubtitleLanguage"]

    /// The storage holds what a used app writes (the keys `WhatsNewPolicy`
    /// tells an update from a fresh install by, and the recent searches):
    /// the terms accepted, the notes version last seen — the only trace of
    /// many iPhone and Mac installs, which have no terms to accept —, a
    /// setting, watch progress, watched or watchlist entries.
    static func isUsedInstall(_ storage: ProfileStorage) -> Bool {
        let settings = Set(["tosAccepted", "lastWhatsNewVersion", "autoSelectQuality", "streamOnCellular",
                            "themeSongVolume", RecentSearches.defaultsKey]).union(languageKeys)
        let usage = ["Progress", "Watchedlist", "Watchlist"]
        return storage.storedKeys.contains { key in settings.contains(key) || usage.contains { key.hasSuffix($0) } }
    }

    // MARK: Reading

    /// The profiles, the primary one first, then by creation.
    public var profiles: [Profile] {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    public var activeID: String {
        lock.lock(); defer { lock.unlock() }
        return activeProfileID
    }

    public var active: Profile {
        lock.lock(); defer { lock.unlock() }
        return list.first { $0.id == activeProfileID } ?? list[0]
    }

    public func profile(withID id: String) -> Profile? {
        lock.lock(); defer { lock.unlock() }
        return list.first { $0.id == id }
    }

    /// « Who's Watching? » at launch: only when there is a choice to make.
    public var asksAtLaunch: Bool {
        return profiles.count > 1
    }

    public var canAddProfile: Bool {
        return profiles.count < ProfileManager.maxProfiles
    }

    // MARK: Keys

    /// The prefix of a profile's keys: "" for the primary profile (its keys
    /// are the ones from before profiles), "profile.<id>." for the others.
    public static func prefix(of id: String) -> String {
        return id == Profile.primaryID ? "" : "profile.\(id)."
    }

    /// `key` as the active profile stores it (a preference of the person
    /// watching: the audio and subtitle languages).
    public func scopedKey(_ key: String) -> String {
        return ProfileManager.prefix(of: activeID) + key
    }

    /// A profile's storage: what its library reads and writes.
    public func storage(for id: String) -> LibraryStorage {
        return ProfileScopedStorage(base: storage, prefix: ProfileManager.prefix(of: id))
    }

    /// The keychain identifier of a profile's Trakt credential: "trakt" for
    /// the primary profile (the account signed in before profiles).
    public static func traktCredentialIdentifier(of id: String) -> String {
        return id == Profile.primaryID ? "trakt" : "trakt.\(id)"
    }

    /// The active profile's Trakt credential identifier.
    public var traktCredentialIdentifier: String {
        return ProfileManager.traktCredentialIdentifier(of: activeID)
    }

    /// For a request whose answer comes back later — Trakt's watchlist,
    /// watched marks and positions, asked with the active profile's
    /// credential: binds the answer to the profile active now. `write` gets
    /// it with that profile's id whatever profile is active by then (a
    /// profile picked while the answer was on its way must not get another
    /// one's list in place of its own); `show`, the screen that asked, only
    /// while that profile is still the active one. Nothing at all once that
    /// profile was deleted: its keys would come back with no profile to
    /// own them, and no deletion to remove them.
    ///
    /// Call it in the same main-thread step as the request, before
    /// anything can switch profiles: the credential and the profile are
    /// then the same one's.
    public func answerForActiveProfile<Answer>(write: @escaping (_ profileID: String, Answer) -> Void,
                                               show: ((Answer) -> Void)? = nil) -> (Answer) -> Void {
        let asker = activeID
        return { [weak self] answer in
            guard let self = self, self.profile(withID: asker) != nil else { return }
            write(asker, answer)
            if self.activeID == asker { show?(answer) }
        }
    }

    // MARK: Writing

    /// Adds a profile (not made active).
    @discardableResult
    public func create(name: String, avatar: Int) throws -> Profile {
        lock.lock()
        let clean: String
        do {
            guard list.count < ProfileManager.maxProfiles else { throw ProfileError.tooManyProfiles }
            clean = try validated(name, excluding: nil)
        } catch {
            lock.unlock()
            throw error
        }
        var id = makeID()
        while list.contains(where: { $0.id == id }) || id == Profile.primaryID { id = makeID() }
        let profile = Profile(id: id, name: clean, avatar: avatar, createdAt: now())
        list.append(profile)
        save()
        lock.unlock()
        post(.profilesDidChange)
        return profile
    }

    /// Renames a profile and/or gives it another avatar.
    public func update(_ id: String, name: String? = nil, avatar: Int? = nil) throws {
        lock.lock()
        do {
            guard let index = list.firstIndex(where: { $0.id == id }) else { throw ProfileError.unknownProfile }
            if let name = name { list[index].name = try validated(name, excluding: id) }
            if let avatar = avatar { list[index].avatar = avatar }
        } catch {
            lock.unlock()
            throw error
        }
        save()
        lock.unlock()
        post(.profilesDidChange)
    }

    /// Deletes a profile and every piece of its data. Deleting the active
    /// profile makes the primary one active.
    public func delete(_ id: String) throws {
        lock.lock()
        guard id != Profile.primaryID else { lock.unlock(); throw ProfileError.cannotDeletePrimary }
        guard let index = list.firstIndex(where: { $0.id == id }) else { lock.unlock(); throw ProfileError.unknownProfile }
        let profile = list.remove(at: index)
        let wasActive = activeProfileID == id
        if wasActive {
            activeProfileID = Profile.primaryID
            storage.set(activeProfileID, forKey: ProfileManager.activeKey)
        }
        save()
        let prefix = ProfileManager.prefix(of: id)
        for key in storage.storedKeys where key.hasPrefix(prefix) {
            storage.set(nil, forKey: key)
        }
        lock.unlock()
        eraseExternal(profile)
        Library.forget(profileID: id)
        ProfileTaste.forget(profileID: id)
        post(.profilesDidChange)
        if wasActive { post(.activeProfileDidChange) }
    }

    /// Makes a profile the active one. False when it does not exist; true
    /// (and nothing posted) when it already is.
    @discardableResult
    public func activate(_ id: String) -> Bool {
        lock.lock()
        guard list.contains(where: { $0.id == id }) else { lock.unlock(); return false }
        let changed = activeProfileID != id
        activeProfileID = id
        storage.set(id, forKey: ProfileManager.activeKey)
        lock.unlock()
        if changed { post(.activeProfileDidChange) }
        return true
    }

    // MARK: Private

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// The name trimmed and cut to `maxNameLength`; throws when it is empty
    /// or another profile has it. Under the lock.
    private func validated(_ name: String, excluding id: String?) throws -> String {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ProfileManager.maxNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ProfileError.emptyName }
        let folded = clean.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let taken = list.contains { profile in
            profile.id != id && profile.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded
        }
        guard !taken else { throw ProfileError.duplicateName }
        return clean
    }

    /// Under the lock.
    private func save() {
        if let data = try? ProfileManager.encoder.encode(list) {
            storage.set(data, forKey: ProfileManager.profilesKey)
        }
    }

    private func post(_ name: Notification.Name) {
        if Thread.isMainThread {
            center.post(name: name, object: self)
        } else {
            DispatchQueue.main.async { self.center.post(name: name, object: self) }
        }
    }
}
