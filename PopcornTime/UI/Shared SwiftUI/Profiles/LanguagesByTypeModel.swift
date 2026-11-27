// « Vos langues » (languages by content type): what the three apps' screens
// bind to — the launch screen shown once per profile, and the editor of
// Settings › Profiles (the Mac's Profiles pane) — and when the launch
// screen shows.
//
// - `LanguagesByTypeModel`: one profile's choices (`ContentLanguageChoices`,
//   PopcornKit), the option lists of the pickers and their titles.
// - `LanguagesScreenGate`: the once-per-profile rule, its flag and the
//   DEBUG hooks (`-PTDebugLanguagesScreen YES`).
// - `LanguagesLaunchQueue`: the SwiftUI apps' sequencing — the screen waits
//   until no other sheet (What's New, Settings…) is up.
// - `LanguagesLaunchPresenter` (tvOS): the same over UIKit's presentations.
//
// Shared by the tvOS, iOS and macOS apps and the unit tests.

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import PopcornKit

/// A string of the feature (Localizable.strings, "Languages.*").
func languagesLocalized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: LanguagesStrings.english[key], table: nil)
}

/// The English texts, where no strings file is loaded (the unit tests).
enum LanguagesStrings {
    static let english: [String: String] = [
        "Languages.Title": "Your Languages",
        "Languages.Message": "Choose how to watch each kind of content.",
        "Languages.Continue": "Continue",
        "Languages.Later": "Later",
        "Languages.Type.Movie": "Movies & Shows",
        "Languages.Type.Movie.Detail": "Everything that isn’t animated",
        "Languages.Type.Cartoon": "Cartoons",
        "Languages.Type.Cartoon.Detail": "Animation from outside Japan",
        "Languages.Type.Anime": "Anime",
        "Languages.Type.Anime.Detail": "Japanese animation",
        "Languages.Audio": "Audio",
        "Languages.Subtitles": "Subtitles",
        "Languages.Automatic": "Automatic",
        "Languages.Original": "Original Version",
        "Languages.Original.Short": "Original",
        "Languages.Off": "Off",
        "Languages.Settings.Row": "Languages by Type",
        "Languages.Settings.Footer": "Each profile has its own.",
        "Languages.Done": "Done",
    ]
}

// MARK: - The editor's state

/// One profile's languages by type, as the launch screen and the Settings
/// editor show them. `.settings` saves each change at once; `.launchScreen`
/// keeps them until « Continuer » (`finish(saving: true)`), and « Plus
/// tard » (`finish(saving: false)`) leaves everything Automatic.
@MainActor
final class LanguagesByTypeModel: ObservableObject {

    enum Mode: Equatable {
        /// « Vos langues » at launch.
        case launchScreen
        /// Settings › Profiles › « Langues par type » (the Mac's pane too).
        case settings
    }

    /// A picker's row: `id` is the tag the model reads and writes.
    struct Option: Identifiable, Hashable {
        let id: String
        let title: String
    }

    let profileID: String
    let mode: Mode
    /// The three types, in the screens' order.
    let types: [ContentType] = ContentType.allCases
    @Published private(set) var choices: ContentLanguageChoices

    private let storage: LibraryStorage
    private let isActiveProfile: Bool
    /// The storage is the app's profile's (`ProfileManager.shared`): a save
    /// tells the screens.
    private let isAppProfile: Bool

    /// A profile's (the active one by default): another one's on the Mac's
    /// Profiles pane.
    convenience init(profileID: String = ProfileManager.shared.activeID, mode: Mode = .settings) {
        self.init(storage: ProfileManager.shared.storage(for: profileID), profileID: profileID, mode: mode,
                  isActiveProfile: profileID == ProfileManager.shared.activeID, isAppProfile: true)
        // With `-PTDebugContentLanguages` (DEBUG) a profile that chose nothing shows the seed.
        choices = ContentLanguageSettings.choices(forProfile: profileID)
    }

    /// Tests: a storage of their own.
    init(storage: LibraryStorage, profileID: String, mode: Mode, isActiveProfile: Bool = false, isAppProfile: Bool = false) {
        self.storage = storage
        self.profileID = profileID
        self.mode = mode
        self.isActiveProfile = isActiveProfile
        self.isAppProfile = isAppProfile
        self.choices = ContentLanguageSettings.choices(in: storage)
    }

    // MARK: Options

    /// Automatic, « Version originale (VO) », then the languages by name.
    let audioOptions: [Option] = [
        Option(id: ContentAudioChoice.automaticTag, title: languagesLocalized("Languages.Automatic")),
        Option(id: ContentAudioChoice.originalTag, title: languagesLocalized("Languages.Original")),
    ] + LanguagesByTypeModel.languageOptions

    /// Automatic, « Désactivés », then the languages by name.
    let subtitleOptions: [Option] = [
        Option(id: ContentSubtitleChoice.automaticTag, title: languagesLocalized("Languages.Automatic")),
        Option(id: ContentSubtitleChoice.offTag, title: languagesLocalized("Languages.Off")),
    ] + LanguagesByTypeModel.languageOptions

    /// The Settings pickers' languages (`PlaybackLanguagePreferences.pickerLanguageCodes`).
    static var languageOptions: [Option] {
        PlaybackLanguagePreferences.sortedPickerLanguageCodes.map {
            Option(id: $0, title: PlaybackLanguagePreferences.displayName(forCode: $0))
        }
    }

    // MARK: Reading and writing (tags)

    func choice(for type: ContentType) -> ContentLanguageChoice { choices[type] }

    func setChoice(_ choice: ContentLanguageChoice, for type: ContentType) {
        guard choices[type] != choice else { return }
        choices[type] = choice
        if mode == .settings { save() }
    }

    func audioTag(for type: ContentType) -> String { choices[type].audio.tag }

    func setAudioTag(_ tag: String, for type: ContentType) {
        var choice = choices[type]
        choice.audio = ContentAudioChoice(tag: tag)
        setChoice(choice, for: type)
    }

    func subtitleTag(for type: ContentType) -> String { choices[type].subtitles.tag }

    func setSubtitleTag(_ tag: String, for type: ContentType) {
        var choice = choices[type]
        choice.subtitles = ContentSubtitleChoice(tag: tag)
        setChoice(choice, for: type)
    }

    /// For a SwiftUI `Picker` over `audioOptions` (tags).
    func audioBinding(for type: ContentType) -> Binding<String> {
        Binding(get: { [unowned self] in audioTag(for: type) }, set: { [unowned self] in setAudioTag($0, for: type) })
    }

    /// For a SwiftUI `Picker` over `subtitleOptions` (tags).
    func subtitleBinding(for type: ContentType) -> Binding<String> {
        Binding(get: { [unowned self] in subtitleTag(for: type) }, set: { [unowned self] in setSubtitleTag($0, for: type) })
    }

    // MARK: Titles

    /// « Films et séries », « Dessins animés », « Animés ».
    static func title(of type: ContentType) -> String { languagesLocalized(type.titleKey) }

    /// « Tout sauf l’animation », « L’animation hors Japon », « L’animation japonaise ».
    static func detail(of type: ContentType) -> String { languagesLocalized(type.detailKey) }

    /// A row's audio value: « Automatique » (« Automatique (Anglais) » for
    /// the active profile once it has a language), « VO », « Français ».
    func audioValue(for type: ContentType) -> String {
        switch choices[type].audio {
        case .automatic: return automaticName(subtitles: false)
        case .original: return languagesLocalized("Languages.Original.Short")
        case .language(let code): return PlaybackLanguagePreferences.displayName(forCode: code)
        }
    }

    /// A row's subtitle value: « Automatique », « Désactivés », « Français ».
    func subtitleValue(for type: ContentType) -> String {
        switch choices[type].subtitles {
        case .automatic: return automaticName(subtitles: true)
        case .off: return languagesLocalized("Languages.Off")
        case .language(let code): return PlaybackLanguagePreferences.displayName(forCode: code)
        }
    }

    /// The value of Settings' « Langues par type » row: « Automatique »,
    /// else the types chosen (« Dessins animés, Animés »).
    var settingsRowValue: String {
        let changed = types.filter { !choices[$0].isAutomatic }
        guard !changed.isEmpty else { return languagesLocalized("Languages.Automatic") }
        return changed.map(LanguagesByTypeModel.title(of:)).joined(separator: ", ")
    }

    private func automaticName(subtitles: Bool) -> String {
        // What Automatic stands for is the active profile's setting or taste.
        isActiveProfile ? PlaybackLanguagePreferences.automaticName(subtitles: subtitles) : languagesLocalized("Languages.Automatic")
    }

    // MARK: Actions

    /// Writes the choices (posts `.contentLanguagesDidChange` for the app's profiles).
    func save() {
        if isAppProfile {
            ContentLanguageSettings.save(choices, forProfile: profileID)
        } else {
            ContentLanguageSettings.save(choices, in: storage)
        }
    }

    /// The launch screen's « Continuer » (`saving`) or « Plus tard »: the
    /// profile won't be asked again. A Settings editor just keeps what it saved.
    func finish(saving: Bool) {
        if saving { save() }
        guard mode == .launchScreen else { return }
        if !saving { choices = ContentLanguageSettings.choices(in: storage) }
        ContentLanguageSettings.markAsked(in: storage)
        LanguagesScreenGate.didFinish(profileID: profileID)
        print("[Languages] screen answered for profile \(profileID): \(saving ? "continue" : "later")")
    }
}

// MARK: - When the launch screen shows

/// Once per profile: at the first launch (or pick of the profile) after
/// this version is installed — new profiles and existing ones —, never for
/// a launch to open a link (nothing is remembered: next launch), never in
/// the UI tests' runs unless forced.
enum LanguagesScreenGate {

    #if DEBUG
    /// `-PTDebugLanguagesScreen YES`: shown at every launch and profile pick
    /// (screenshots, UI tests; DEBUG builds only).
    static let forceKey = "PTDebugLanguagesScreen"
    /// `-PTLanguagesAsked YES`: never shown (a test run that must not meet it).
    static let skipKey = "PTLanguagesAsked"
    #endif

    /// The rule (pure).
    /// - Parameters:
    ///   - asked: the profile answered it already.
    ///   - forced: `-PTDebugLanguagesScreen YES`.
    ///   - launchedFromURL: launched (or the profile picked) to open a link.
    ///   - harness: a UI test or debug-hook run (in-memory profiles,
    ///     `IOSDebugHooks.isActive`, `MacDebugHooks.isActive`).
    static func shouldPresent(asked: Bool, forced: Bool, launchedFromURL: Bool, harness: Bool) -> Bool {
        if launchedFromURL { return false }
        if forced { return true }
        if harness { return false }
        return !asked
    }

    /// The rule for a profile (the active one by default), and once per
    /// process and profile — several Mac windows ask, one shows it
    /// (`claim`). Logs its answer. `harness`: the caller's own debug hooks
    /// (`IOSDebugHooks.isActive`, `MacDebugHooks.isActive`); the in-memory
    /// profiles of the tvOS UI tests are seen here.
    @MainActor
    static func shouldPresent(profileID: String = ProfileManager.shared.activeID, launchedFromURL: Bool,
                              harness: Bool = false, defaults: UserDefaults = .standard) -> Bool {
        let asked = ContentLanguageSettings.wasAsked(profile: profileID)
        let present = shouldPresent(asked: asked, forced: isForced(defaults), launchedFromURL: launchedFromURL,
                                    harness: harness || isTestHarness(defaults))
        guard present else {
            print("[Languages] screen: skip for profile \(profileID) (\(asked ? "answered" : launchedFromURL ? "launched by a link" : "test run"))")
            return false
        }
        guard claim(profileID: profileID) else { return false }
        print("[Languages] screen: present for profile \(profileID)")
        return true
    }

    static func isForced(_ defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        return defaults.bool(forKey: forceKey)
        #else
        return false
        #endif
    }

    /// The UI tests' and screenshots' runs: in-memory profiles
    /// (`-PTDebugLibraryInMemory`, `-PTDebugProfiles`) or `-PTLanguagesAsked YES`.
    static func isTestHarness(_ defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        return defaults.bool(forKey: "PTDebugLibraryInMemory") || defaults.string(forKey: "PTDebugProfiles") != nil
            || defaults.bool(forKey: skipKey)
        #else
        return false
        #endif
    }

    // Once per process and profile (the Mac's windows).

    @MainActor private static var claimed: Set<String> = []

    /// True for the first caller for this profile in this process.
    @MainActor
    static func claim(profileID: String) -> Bool {
        claimed.insert(profileID).inserted
    }

    /// The screen went away unanswered (a link closed it): it may show
    /// again at the next launch, not again in this one.
    @MainActor
    static func didCloseUnanswered(profileID: String) {
        print("[Languages] screen closed unanswered for profile \(profileID)")
    }

    /// The screen was answered (`LanguagesByTypeModel.finish`): forced
    /// runs show it again at the next profile pick.
    @MainActor
    static func didFinish(profileID: String) {
        if isForced() { claimed.remove(profileID) }
    }
}

// MARK: - SwiftUI apps: one sheet at a time

/// The iPhone's / iPad's and the Mac's launch sequencing, as pure state the
/// root view keeps in `@State`:
/// 1. `check(...)` in the root's `.task`, after What's New's check: the
///    gate's answer is remembered (`pending`);
/// 2. `update(blocked:)` each time the root's other sheets change (What's
///    New, Settings, Switch Profile…): true when the screen must be shown
///    now (`isPresented`);
/// 3. `linkOpened()` (`onOpenURL`): a link closes it or keeps it from
///    showing (nothing remembered);
/// 4. `finished()` when the sheet closed (the model marked the profile).
struct LanguagesLaunchQueue: Equatable {
    private(set) var checked = false
    private(set) var pending = false
    private(set) var isPresented = false
    private(set) var linkArrived = false

    /// The launch check. True when the screen is due (shown once nothing
    /// else is: `update(blocked:)`).
    @MainActor
    mutating func check(profileID: String = ProfileManager.shared.activeID, harness: Bool = false,
                        defaults: UserDefaults = .standard) -> Bool {
        guard !checked else { return pending }
        checked = true
        pending = LanguagesScreenGate.shouldPresent(profileID: profileID, launchedFromURL: linkArrived,
                                                    harness: harness, defaults: defaults)
        return pending
    }

    /// The check's rule with its answer given (tests).
    mutating func check(gateSays present: Bool) {
        guard !checked else { return }
        checked = true
        pending = present && !linkArrived
    }

    /// True when the screen must show now: due, and nothing else up.
    mutating func update(blocked: Bool) -> Bool {
        guard pending, !blocked, !isPresented else { return false }
        pending = false
        isPresented = true
        return true
    }

    /// A link arrived: true when a shown screen must close now.
    mutating func linkOpened() -> Bool {
        linkArrived = true
        pending = false
        guard isPresented else { return false }
        isPresented = false
        return true
    }

    /// The sheet closed.
    mutating func finished() {
        isPresented = false
        pending = false
    }
}

// MARK: - tvOS: after the other launch screens

#if os(tvOS)
/// The Apple TV's launch hook: the screen waits until the window's root
/// presents nothing — the Terms of Service, What's New, a player — then
/// shows once. SceneDelegate calls `schedule` after installing the tab bar
/// (and `ProfilesPresenter` after a profile pick); `AppDelegate.open(_:)`
/// calls `cancelForLink()`.
@MainActor
enum LanguagesLaunchPresenter {

    /// Makes the screen; it calls `finish` once answered (the presenter
    /// dismisses it).
    typealias MakeScreen = (_ finish: @escaping () -> Void) -> UIViewController

    private static weak var presented: UIViewController?
    private static var waiting: Timer?
    private static var profileID: String?

    /// How long the other launch screens get to come up first (What's New
    /// and the Terms of Service are presented asynchronously).
    static let firstLook: TimeInterval = 1.0
    static let interval: TimeInterval = 0.5

    static var isShowing: Bool { presented != nil }

    /// Shows the screen once the root presents nothing, when the gate says so.
    static func schedule(in window: UIWindow, launchedFromURL: Bool, makeScreen: @escaping MakeScreen) {
        cancelWaiting()
        let profile = ProfileManager.shared.activeID
        guard LanguagesScreenGate.shouldPresent(profileID: profile, launchedFromURL: launchedFromURL) else { return }
        profileID = profile
        Task { @MainActor [weak window] in
            try? await Task.sleep(nanoseconds: UInt64(firstLook * 1_000_000_000))
            guard profileID == profile else { return }
            waiting = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak window] _ in
                MainActor.assumeIsolated { tryPresent(in: window, profile: profile, makeScreen: makeScreen) }
            }
            tryPresent(in: window, profile: profile, makeScreen: makeScreen)
        }
    }

    private static func tryPresent(in window: UIWindow?, profile: String, makeScreen: MakeScreen) {
        guard let window, profileID == profile, ProfileManager.shared.activeID == profile else { return cancelWaiting() }
        guard presented == nil, let root = window.rootViewController, root.presentedViewController == nil else { return }
        cancelWaiting()
        let screen = makeScreen({ dismiss(animated: true) })
        presented = screen
        root.present(screen, animated: true)
    }

    /// A link opens: the screen closes (or never shows) without being
    /// marked — next launch asks again.
    static func cancelForLink() {
        cancelWaiting()
        if let profileID, presented != nil { LanguagesScreenGate.didCloseUnanswered(profileID: profileID) }
        dismiss(animated: false)
    }

    static func dismiss(animated: Bool) {
        profileID = nil
        guard let screen = presented else { return }
        presented = nil
        screen.presentingViewController?.dismiss(animated: animated)
    }

    private static func cancelWaiting() {
        waiting?.invalidate()
        waiting = nil
    }
}
#endif
