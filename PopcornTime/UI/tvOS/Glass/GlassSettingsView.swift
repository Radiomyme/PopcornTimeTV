// GlassSettingsView.swift — the tvOS Settings tab, in Liquid Glass.
//
// Pure SwiftUI: no PopcornKit, no pods, no app types. Everything it reads or
// changes goes through `GlassSettingsModel` (values) and `GlassSettingsActions`
// (closures), filled by `GlassSettingsHostingController`, so the page can be
// compiled alone with mock values (the screenshot harness lives outside the
// repo; it builds with DEBUG for the switches below).
//
// Texts are English keys looked up in the app's Localizable.strings (en, fr…).
//
// Focus: rows are Buttons with `GlassSettingsRowStyle`, which draws the focus
// state itself from @Environment(\.isFocused) (custom glass gets no system
// focus effect on tvOS). No GlassEffectContainer is used.
import SwiftUI

// MARK: - Model

/// "Auto Select Quality" choices. For balanced, `titleKey` is both the
/// Localizable.strings key and, localized, the value the quality chooser
/// compares the stored preference to (`AppDelegate.presentQualityChoice`);
/// off is stored as no value (the chooser then always asks).
enum GlassSettingsAutoQuality: String, CaseIterable, Identifiable {
    /// Quick Start, Balanced and Best Picture are the balanced pick
    /// (`Torrent.balancedPick`) with its three priorities (`SourcePriority`).
    case quickStart, balanced, bestPicture, off

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .quickStart: return "Quick Start"
        case .balanced: return "Balanced"
        case .bestPicture: return "Best Picture"
        case .off: return "Always Ask"
        }
    }

    var detailKey: String {
        switch self {
        case .quickStart: return "The most shared source first, even with a lesser picture."
        case .balanced: return "The best quality that starts quickly."
        case .bestPicture: return "The best picture among the sources shared widely enough."
        case .off: return "Choose the source every time; the recommended one is starred."
        }
    }
}

/// A language offered by the audio and subtitle pickers.
struct GlassSettingsLanguage: Identifiable, Hashable {
    /// ISO 639-1 code ("fr").
    let code: String
    /// Name in the current UI language ("Français").
    let name: String
    var id: String { code }
}

/// One line of a list where several can be checked (the Home's content
/// languages, its shelves).
struct GlassSettingsChoice: Identifiable, Hashable {
    let id: String
    /// In the current UI language.
    let title: String
}

/// The Home tab's settings, as the page shows them.
struct GlassSettingsHome: Equatable {
    /// ISO 639-1 codes of the languages whose titles the Home shows; empty: every language.
    var languages: [String] = []
    /// Ids of the shelves the Home does not show.
    var hiddenShelves: Set<String> = []
    /// The followed shows go to Cinemeta in one request (new episodes).
    var groupedEpisodeLookup = true
    /// The languages offered, in display order.
    var languageChoices: [GlassSettingsChoice] = []
    /// The shelves that can be hidden, in the Home's order.
    var shelfChoices: [GlassSettingsChoice] = []
    /// The user gave a TMDB key: the streaming shelves can be asked.
    var hasTMDBKey = false
    /// TMDB refused that key at its last request (401).
    var isTMDBKeyRefused = false
    /// ISO 3166-1 code of the country of the streaming catalogues ("FR").
    var streamingRegion = "US"
    /// The services that have a shelf, in the Home's order (id: TMDB's
    /// provider id).
    var streamingServices: [GlassSettingsChoice] = []
}

/// What the page does, provided by its host.
struct GlassSettingsActions {
    var setAutoQuality: (GlassSettingsAutoQuality) -> Void = { _ in }
    /// A language row's choice, as a tag: "auto" (never set: the language
    /// the profile picks itself), "" (« None »), else an ISO code.
    var setAudioLanguage: (String) -> Void = { _ in }
    var setSubtitleLanguage: (String) -> Void = { _ in }
    /// The "auto" choice's name: « Automatic (French) » with the language
    /// it stands for now (true: subtitles).
    var automaticLanguageName: (Bool) -> String = { _ in glassSettingsLocalized("Settings.Language.Automatic") }
    var setThemeSongs: (Bool) -> Void = { _ in }
    /// The stored Theme Songs state, re-read by `refresh()` (a fresh install
    /// turns theme songs on after this page was created). nil: never re-read.
    var readThemeSongs: (() -> Bool)? = nil
    /// « Autoplay Next Episode » (`UpNextPreferences.autoPlayNext`, on by
    /// default): written, and re-read by `refresh()`. nil: never re-read.
    var setAutoPlayNext: (Bool) -> Void = { _ in }
    var readAutoPlayNext: (() -> Bool)? = nil
    /// « Next Episode Card »: seconds before the end of an episode its card
    /// comes (`UpNextPreferences.cardLead`, 60 by default), one of
    /// `upNextCardLeadChoices`: written, and re-read by `refresh()`.
    var setUpNextCardLead: (Int) -> Void = { _ in }
    var readUpNextCardLead: (() -> Int)? = nil
    var upNextCardLeadChoices: [Int] = [30, 45, 60, 90]
    /// « Maximum Resolution » of the automatic choice, in lines (0: no
    /// limit; `SourcePreferences.maximumResolution`): written, and re-read
    /// by `refresh()`.
    var setMaximumResolution: (Int) -> Void = { _ in }
    var readMaximumResolution: (() -> Int)? = nil
    var maximumResolutionChoices: [GlassSettingsChoice] = []
    /// « Prefer Your Language » (`SourcePreferences.languageFirst`, on by
    /// default): written, and re-read by `refresh()`.
    var setLanguageFirst: (Bool) -> Void = { _ in }
    var readLanguageFirst: (() -> Bool)? = nil
    /// Bytes the clearable cache holds now. Called off the main thread.
    var measureCache: @Sendable () -> Int64 = { 0 }
    /// Empties the cache. Called on the main thread.
    var clearCache: () -> Void = {}
    /// True while a download is in progress (clearing the cache would cut it).
    var hasActiveDownloads: () -> Bool = { false }
    var isTraktSignedIn: () -> Bool = { false }
    var signOutOfTrakt: () -> Void = {}
    var showWhatsNew: () -> Void = {}
    /// The Home tab's settings as stored now (read when the page appears).
    /// nil: the page has no Home section.
    var readHome: (() -> GlassSettingsHome)? = nil
    /// Empty: every language.
    var setHomeLanguages: ([String]) -> Void = { _ in }
    var setHiddenHomeShelves: (Set<String>) -> Void = { _ in }
    var setGroupedEpisodeLookup: (Bool) -> Void = { _ in }
    /// Checks a TMDB key, then keeps it unless TMDB refused it (nil: the
    /// key is removed). The completion (main queue) gets TMDB's verdict:
    /// nil when it could not be asked (the key is kept).
    var setTMDBKey: (String?, @escaping (Bool?) -> Void) -> Void = { _, done in done(nil) }
    /// Asks TMDB again about the stored key (« Vérifier à nouveau »); the
    /// key stays whatever the answer. The completion (main queue) gets the
    /// verdict, nil when TMDB did not answer.
    var checkTMDBKeyAgain: (@escaping (Bool?) -> Void) -> Void = { done in done(nil) }
    /// The key sheet's QR code: TMDB's API settings page, where the key is
    /// (never the key itself). nil: no code.
    var tmdbKeyQRCode: () -> CGImage? = { nil }
    var setStreamingRegion: (String) -> Void = { _ in }
    var setStreamingServices: ([GlassSettingsChoice]) -> Void = { _ in }
    /// The services of a country, the most watched first (main queue; nil:
    /// TMDB did not answer).
    var loadStreamingServices: (String, @escaping ([GlassSettingsChoice]?) -> Void) -> Void = { _, done in done(nil) }
    /// The countries TMDB has catalogues for, by name (main queue).
    var loadStreamingRegions: (@escaping ([GlassSettingsChoice]) -> Void) -> Void = { done in done([]) }
    /// "France" for "FR".
    var regionName: (String) -> String = { $0 }
    /// The active profile, re-read by `refresh()`. nil: no Profiles section.
    var readProfile: (() -> GlassSettingsProfile)? = nil
    /// « Who's Watching? » over the app (its own Manage Profiles button
    /// edits the profiles).
    var showProfiles: () -> Void = {}
    /// Your Preferences: what the active profile's taste learned, a facet a
    /// line, best first.
    var readTaste: () -> [GlassSettingsTasteLine] = { [] }
    /// Forgets what it learned.
    var resetTaste: () -> Void = {}
}

/// The active profile as the Profiles section shows it.
struct GlassSettingsProfile: Equatable {
    var name: String
    /// Its avatar (`ProfileAvatar`), the Switch Profile row's icon.
    var avatar: Int
    /// Its strongest genres ("Drama · Science Fiction"); nil: nothing learned yet.
    var preferences: String? = nil
}

/// A line of Your Preferences: a facet ("Genres") and its values, joined.
struct GlassSettingsTasteLine: Identifiable, Equatable {
    var id: String
    var title: String
    var values: String
}

/// The page's state. Changes go through the methods, which call the actions.
final class GlassSettingsModel: ObservableObject {
    @Published private(set) var autoQuality: GlassSettingsAutoQuality
    /// The language rows' tags (`GlassSettingsActions.setAudioLanguage`).
    @Published private(set) var audioLanguage: String
    @Published private(set) var subtitleLanguage: String
    @Published private(set) var themeSongs: Bool
    /// Episode chaining: the next episode starts on its own at the end of
    /// a countdown (off: the card stays, nothing starts by itself).
    @Published private(set) var autoPlayNext: Bool
    /// Seconds before the end the next episode's card comes.
    @Published private(set) var upNextCardLead: Int
    /// In lines; 0: no limit.
    @Published private(set) var maximumResolution: Int
    /// « Dolby Vision 8.1 » (`DolbyVisionPlaybackMode`, device-wide).
    @Published private(set) var dolbyVisionMode = DolbyVisionPlaybackMode.stored()
    @Published private(set) var languageFirst: Bool
    @Published private(set) var isTraktSignedIn: Bool
    /// nil while it is being measured.
    @Published private(set) var cacheBytes: Int64?
    /// nil: no Home section.
    @Published private(set) var home: GlassSettingsHome?
    /// The services of the chosen country, once TMDB answered.
    @Published private(set) var streamingServiceChoices: [GlassSettingsChoice]?
    /// The countries offered, once known.
    @Published private(set) var streamingRegionChoices: [GlassSettingsChoice]?
    /// A key is being checked with TMDB.
    @Published private(set) var isCheckingTMDBKey = false
    /// nil: no Profiles section.
    @Published private(set) var profile: GlassSettingsProfile?
    /// Your Preferences, read when its sheet opens (`loadTaste`).
    @Published private(set) var taste: [GlassSettingsTasteLine] = []
    /// "5.1.0 (2)".
    let version: String
    /// Offered by the language pickers, in display order.
    let languages: [GlassSettingsLanguage]
    let actions: GlassSettingsActions

    init(autoQuality: GlassSettingsAutoQuality, audioLanguage: String, subtitleLanguage: String,
         themeSongs: Bool, version: String, languages: [GlassSettingsLanguage],
         actions: GlassSettingsActions) {
        self.autoQuality = autoQuality
        self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage
        self.themeSongs = themeSongs
        self.autoPlayNext = actions.readAutoPlayNext?() ?? true
        self.upNextCardLead = actions.readUpNextCardLead?() ?? 60
        self.maximumResolution = actions.readMaximumResolution?() ?? 0
        self.languageFirst = actions.readLanguageFirst?() ?? true
        self.version = version
        self.languages = languages
        self.actions = actions
        self.isTraktSignedIn = actions.isTraktSignedIn()
        self.home = actions.readHome?()
        self.profile = actions.readProfile?()
    }

    // MARK: Home

    /// Checks or unchecks a content language. The last one unchecked is
    /// "every language" again (an empty list), and so is "All Languages".
    func toggle(homeLanguage code: String?) {
        guard var home else { return }
        if let code {
            if let index = home.languages.firstIndex(of: code) {
                home.languages.remove(at: index)
            } else {
                home.languages.append(code)
            }
        } else {
            home.languages = []
        }
        self.home = home
        actions.setHomeLanguages(home.languages)
    }

    /// Shows or hides a shelf of the Home.
    func toggle(homeShelf id: String) {
        guard var home else { return }
        if home.hiddenShelves.contains(id) { home.hiddenShelves.remove(id) } else { home.hiddenShelves.insert(id) }
        self.home = home
        actions.setHiddenHomeShelves(home.hiddenShelves)
    }

    func toggleGroupedEpisodeLookup() {
        guard var home else { return }
        home.groupedEpisodeLookup.toggle()
        self.home = home
        actions.setGroupedEpisodeLookup(home.groupedEpisodeLookup)
    }

    // MARK: Streaming services

    /// Gives, replaces or removes (nil, "") the TMDB key; `completion`
    /// gets TMDB's verdict (true: kept, false: refused, nil: not asked).
    func setTMDBKey(_ key: String?, completion: @escaping (Bool?) -> Void) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        isCheckingTMDBKey = true
        actions.setTMDBKey(key?.isEmpty == false ? key : nil) { [weak self] verdict in
            guard let self else { return }
            self.isCheckingTMDBKey = false
            if let stored = self.actions.readHome?() { self.home = stored }
            // Another key: the services offered are asked again.
            self.streamingServiceChoices = nil
            completion(verdict)
        }
    }

    /// Checks the stored key with TMDB again; `completion` gets the verdict
    /// (true: taken, false: refused, nil: no answer). The row then says
    /// « Définie » or « Refusée ».
    func checkTMDBKeyAgain(completion: @escaping (Bool?) -> Void) {
        isCheckingTMDBKey = true
        actions.checkTMDBKeyAgain { [weak self] verdict in
            guard let self else { return }
            self.isCheckingTMDBKey = false
            if let stored = self.actions.readHome?() { self.home = stored }
            completion(verdict)
        }
    }

    func select(streamingRegion code: String) {
        guard var home, home.streamingRegion != code else { return }
        home.streamingRegion = code
        self.home = home
        streamingServiceChoices = nil
        actions.setStreamingRegion(code)
    }

    /// Checks or unchecks a service: a checked one goes last on the page.
    func toggle(streamingService choice: GlassSettingsChoice) {
        guard var home else { return }
        if let index = home.streamingServices.firstIndex(where: { $0.id == choice.id }) {
            home.streamingServices.remove(at: index)
        } else {
            home.streamingServices.append(choice)
        }
        self.home = home
        actions.setStreamingServices(home.streamingServices)
    }

    /// Asks the chosen country's services (once per country and key).
    func loadStreamingServiceChoices() {
        guard let home, home.hasTMDBKey, streamingServiceChoices == nil else { return }
        let region = home.streamingRegion
        actions.loadStreamingServices(region) { [weak self] choices in
            guard let self, self.home?.streamingRegion == region, let choices else { return }
            // The chosen services, matched to the country's meanwhile.
            if let stored = self.actions.readHome?() { self.home = stored }
            self.streamingServiceChoices = choices
        }
    }

    func loadStreamingRegionChoices() {
        guard streamingRegionChoices == nil else { return }
        actions.loadStreamingRegions { [weak self] choices in
            self?.streamingRegionChoices = choices
        }
    }

    /// The services the picker lists: the chosen ones first (they may not
    /// be in the country's list), then the country's others.
    var streamingServiceOptions: [GlassSettingsChoice] {
        let chosen = home?.streamingServices ?? []
        let ids = Set(chosen.map(\.id))
        return chosen + (streamingServiceChoices ?? []).filter { !ids.contains($0.id) }
    }

    var streamingRegionOptions: [GlassSettingsChoice] {
        let current = home?.streamingRegion ?? "US"
        let all = streamingRegionChoices ?? []
        return all.contains { $0.id == current } ? all : [GlassSettingsChoice(id: current, title: actions.regionName(current))] + all
    }

    /// "Netflix, Disney+ +2", "Aucun".
    var streamingServicesSummary: String {
        let names = (home?.streamingServices ?? []).map(\.title)
        guard !names.isEmpty else { return glassSettingsLocalized("None") }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }

    var streamingRegionSummary: String {
        actions.regionName(home?.streamingRegion ?? "US")
    }

    var tmdbKeySummary: String {
        guard home?.hasTMDBKey == true else { return glassSettingsLocalized("Settings.TMDBKey.Missing") }
        return glassSettingsLocalized(home?.isTMDBKeyRefused == true ? "Settings.TMDBKey.Refused.Short" : "Settings.TMDBKey.Set")
    }

    /// "Toutes", "Anglais, Français", "Anglais, Français +2".
    var homeLanguagesSummary: String {
        guard let home, !home.languages.isEmpty else { return glassSettingsLocalized("Home.Settings.All") }
        let names = home.languages.map { code in home.languageChoices.first { $0.id == code }?.title ?? code }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }

    /// "Toutes", "11 sur 13".
    var homeShelvesSummary: String {
        guard let home else { return "" }
        let hidden = home.shelfChoices.filter { home.hiddenShelves.contains($0.id) }.count
        guard hidden > 0 else { return glassSettingsLocalized("Home.Settings.All") }
        return String(format: glassSettingsLocalized("Home.Settings.Shelves.Count"),
                      home.shelfChoices.count - hidden, home.shelfChoices.count)
    }

    func select(autoQuality: GlassSettingsAutoQuality) {
        self.autoQuality = autoQuality
        actions.setAutoQuality(autoQuality)
    }

    func select(audioLanguage tag: String) {
        audioLanguage = tag
        actions.setAudioLanguage(tag)
    }

    func select(subtitleLanguage tag: String) {
        subtitleLanguage = tag
        actions.setSubtitleLanguage(tag)
    }

    func toggleThemeSongs() {
        themeSongs.toggle()
        actions.setThemeSongs(themeSongs)
    }

    func toggleAutoPlayNext() {
        autoPlayNext.toggle()
        actions.setAutoPlayNext(autoPlayNext)
    }

    func select(maximumResolution lines: Int) {
        maximumResolution = lines
        actions.setMaximumResolution(lines)
    }

    func select(dolbyVisionMode mode: DolbyVisionPlaybackMode) {
        dolbyVisionMode = mode
        mode.store()
    }

    /// « No Limit », « 1080p »…
    var maximumResolutionText: String {
        actions.maximumResolutionChoices.first { $0.id == String(maximumResolution) }?.title
            ?? glassSettingsLocalized("No Limit")
    }

    func toggleLanguageFirst() {
        languageFirst.toggle()
        actions.setLanguageFirst(languageFirst)
    }

    /// The language row says something only when an audio language is in
    /// use (« None » leaves nothing to prefer).
    var showsLanguageFirst: Bool { audioLanguage != "" }

    func select(upNextCardLead seconds: Int) {
        upNextCardLead = seconds
        actions.setUpNextCardLead(seconds)
    }

    /// "60 s avant la fin".
    func upNextCardLeadText(_ seconds: Int) -> String {
        String(format: glassSettingsLocalized("Settings.UpNextCard.Value"), seconds)
    }

    func signOutOfTrakt() {
        actions.signOutOfTrakt()
        isTraktSignedIn = actions.isTraktSignedIn()
    }

    /// Re-reads what can change outside the page (Trakt session, theme songs,
    /// cache size).
    func refresh() {
        isTraktSignedIn = actions.isTraktSignedIn()
        if let stored = actions.readThemeSongs?(), stored != themeSongs { themeSongs = stored }
        if let stored = actions.readAutoPlayNext?(), stored != autoPlayNext { autoPlayNext = stored }
        if let stored = actions.readUpNextCardLead?(), stored != upNextCardLead { upNextCardLead = stored }
        if let stored = actions.readMaximumResolution?(), stored != maximumResolution { maximumResolution = stored }
        if DolbyVisionPlaybackMode.stored() != dolbyVisionMode { dolbyVisionMode = DolbyVisionPlaybackMode.stored() }
        if let stored = actions.readLanguageFirst?(), stored != languageFirst { languageFirst = stored }
        if let stored = actions.readHome?(), stored != home { home = stored }
        if let stored = actions.readProfile?(), stored != profile { profile = stored }
        cacheBytes = nil
        let measure = actions.measureCache
        DispatchQueue.global(qos: .utility).async {
            let bytes = measure()
            DispatchQueue.main.async { self.cacheBytes = bytes }
        }
    }

    /// Clears the cache; `completion` (main thread) gets the bytes reclaimed,
    /// measured before and after (the measuring runs off the main thread).
    func clearCache(completion: @escaping (Int64) -> Void) {
        let measure = actions.measureCache
        DispatchQueue.global(qos: .userInitiated).async {
            let before = measure()
            DispatchQueue.main.async {
                self.actions.clearCache()
                DispatchQueue.global(qos: .userInitiated).async {
                    let after = measure()
                    DispatchQueue.main.async {
                        self.cacheBytes = after
                        completion(max(0, before - after))
                    }
                }
            }
        }
    }

    // MARK: Profiles

    /// Your Preferences as learned now.
    func loadTaste() {
        taste = actions.readTaste()
    }

    /// Forgets what the active profile's taste learned: the sheet shows its
    /// empty state, the row its « Nothing yet ».
    func resetTaste() {
        actions.resetTaste()
        taste = actions.readTaste()
        if let stored = actions.readProfile?(), stored != profile { profile = stored }
    }

    /// A language row's value: « Automatic (French) », « None » or the language.
    func languageName(_ tag: String, subtitles: Bool) -> String {
        if tag == GlassSettingsModel.automaticTag { return actions.automaticLanguageName(subtitles) }
        if tag.isEmpty { return glassSettingsLocalized("None") }
        return languages.first { $0.code == tag }?.name ?? tag
    }

    /// The tag of the language rows' automatic choice.
    static let automaticTag = "auto"
}

/// Localizable.strings lookup in the app bundle (English key when missing).
func glassSettingsLocalized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

private func glassSettingsByteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - Glass on/off switch (screenshots, DEBUG builds only)

#if DEBUG
private struct GlassSettingsFallbackKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// true forces the tvOS 17–25 look where Liquid Glass exists, for
    /// side-by-side screenshots.
    var glassSettingsFallback: Bool {
        get { self[GlassSettingsFallbackKey.self] }
        set { self[GlassSettingsFallbackKey.self] = newValue }
    }
}
#else
extension EnvironmentValues {
    /// Liquid Glass wherever the system has it.
    var glassSettingsFallback: Bool { false }
}
#endif

enum GlassSettingsPalette {
    /// The app accent (AccentColor, dark appearance).
    static let accent = Color(red: 0.949, green: 0.290, blue: 0.235)
    static let secondaryText = Color.white.opacity(0.68)
    static let tertiaryText = Color.white.opacity(0.5)
}

// MARK: - Page

/// The rows that open a picker.
enum GlassSettingsPicker: String, Identifiable {
    case quality, upNextCard, audio, subtitles, homeLanguages, homeShelves, streamingRegion, streamingServices, tmdbKey
    case taste, maximumResolution, dolbyVision
    var id: String { rawValue }
}

/// Rows that can hold the focus (default focus, screenshots).
enum GlassSettingsRowID: Hashable {
    case quality, autoPlayNext, upNextCard, audio, subtitles, themeSongs, clearCache, trakt, version
    case homeLanguages, homeShelves, homeLookup
    case tmdbKey, streamingRegion, streamingServices
    case switchProfile, profilePreferences
    case maximumResolution, languageFirst, dolbyVision
}

struct GlassSettingsView: View {
    @ObservedObject var model: GlassSettingsModel
    #if DEBUG
    /// Picker open at first display (screenshots, DEBUG builds only).
    var initialPicker: GlassSettingsPicker?
    #endif
    /// The row that gets the focus when the page first takes it.
    var defaultFocusRow: GlassSettingsRowID = .quality

    @State private var picker: GlassSettingsPicker?
    @State private var confirmClear = false
    @State private var clearResult: Int64?
    @State private var showClearResult = false
    @State private var confirmSignOut = false
    /// TMDB's verdict on the key just entered, for the alert that tells it.
    @State private var tmdbKeyVerdict: Bool??
    /// The verdict is on the stored key checked again (« Vérifier à
    /// nouveau »), not on a key just entered: its own texts.
    @State private var tmdbKeyRechecked = false
    @State private var showTMDBKeyVerdict = false
    @FocusState private var focusedRow: GlassSettingsRowID?

    var body: some View {
        // Fits a 1080p screen under the tab bar; the scroll view only matters
        // if a host leaves less room (the focus engine scrolls to the row).
        ScrollView {
            page
                .padding(.horizontal, 90)
                .padding(.bottom, 40)
        }
        // 90 pt from the screen's edge, as the Home and the grids (the
        // system's side safe area came on top: the title started at 170).
        .ignoresSafeArea(.container, edges: .horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { GlassSettingsBackdrop().ignoresSafeArea() }
        .defaultFocus($focusedRow, defaultFocusRow)
        #if DEBUG
        .onAppear {
            if initialPicker == .taste { model.loadTaste() }
            if let initialPicker { picker = initialPicker }
        }
        #endif
        .fullScreenCover(item: $picker) { picker in
            pickerSheet(picker)
        }
        .alert(glassSettingsLocalized("Clear Cache"), isPresented: $confirmClear) {
            if model.actions.hasActiveDownloads() {
                SwiftUI.Button(glassSettingsLocalized("OK"), role: .cancel) {}
            } else {
                SwiftUI.Button(glassSettingsLocalized("Clear Cache"), role: .destructive) {
                    model.clearCache { reclaimed in
                        clearResult = reclaimed
                        showClearResult = true
                    }
                }
                SwiftUI.Button(glassSettingsLocalized("Cancel"), role: .cancel) {}
            }
        } message: {
            Text(clearCacheMessage)
        }
        .alert(glassSettingsLocalized("Cache Cleared"), isPresented: $showClearResult) {
            SwiftUI.Button(glassSettingsLocalized("OK"), role: .cancel) {}
        } message: {
            if let clearResult, clearResult > 0 {
                Text(String(format: glassSettingsLocalized("%@ reclaimed."), glassSettingsByteString(clearResult)))
            } else {
                Text(glassSettingsLocalized("Cache was already empty, no disk space was reclaimed."))
            }
        }
        .alert(glassSettingsLocalized("Sign Out of Trakt"), isPresented: $confirmSignOut) {
            SwiftUI.Button(glassSettingsLocalized("Sign Out"), role: .destructive) { model.signOutOfTrakt() }
            SwiftUI.Button(glassSettingsLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(glassSettingsLocalized("Are you sure you want to Sign Out?"))
        }
        .alert(glassSettingsLocalized("Settings.TMDBKey"), isPresented: $showTMDBKeyVerdict) {
            SwiftUI.Button(glassSettingsLocalized("OK"), role: .cancel) {}
        } message: {
            switch (tmdbKeyVerdict, tmdbKeyRechecked) {
            case (.some(.some(true)), false): Text(glassSettingsLocalized("Settings.TMDBKey.Accepted"))
            case (.some(.some(false)), false): Text(glassSettingsLocalized("Settings.TMDBKey.Refused"))
            case (_, false): Text(glassSettingsLocalized("Settings.TMDBKey.Unchecked"))
            case (.some(.some(true)), true): Text(glassSettingsLocalized("Settings.TMDBKey.Check.Accepted"))
            case (.some(.some(false)), true): Text(glassSettingsLocalized("Settings.TMDBKey.Check.Refused"))
            case (_, true): Text(glassSettingsLocalized("Settings.TMDBKey.Check.Unanswered"))
            }
        }
    }

    private func saveTMDBKey(_ key: String?) {
        let removing = key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        model.setTMDBKey(key) { verdict in
            guard !removing else { return }
            tmdbKeyVerdict = .some(verdict)
            tmdbKeyRechecked = false
            showTMDBKeyVerdict = true
        }
    }

    private func checkTMDBKeyAgain() {
        model.checkTMDBKeyAgain { verdict in
            tmdbKeyVerdict = .some(verdict)
            tmdbKeyRechecked = true
            showTMDBKeyVerdict = true
        }
    }

    /// Page title, then two columns of sections.
    private var page: some View {
        VStack(alignment: .leading, spacing: 30) {
            // Same place, size and weight as the other tabs' titles
            // (MainViewController.installInBodyHeader).
            Text(glassSettingsLocalized("Settings"))
                .font(.system(size: 75, weight: .heavy))
                .foregroundStyle(.white)
                .frame(height: 100)
                .padding(.top, 16)

            HStack(alignment: .top, spacing: 60) {
                VStack(alignment: .leading, spacing: 44) {
                    playbackSection
                    detailPagesSection
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 44) {
                    if model.profile != nil { profilesSection }
                    if model.home != nil { homeSection }
                    if model.home != nil { streamingSection }
                    storageSection
                    if model.isTraktSignedIn { accountSection }
                    aboutSection
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Sections

    private var playbackSection: some View {
        GlassSettingsSection(title: "Playback",
                             footer: "Audio and subtitles in these languages are picked automatically when the file or OpenSubtitles offers them.") {
            GlassSettingsRow(symbol: "sparkles.tv", tint: .orange, title: "Auto Select Quality",
                             value: glassSettingsLocalized(model.autoQuality.titleKey)) { picker = .quality }
                .focused($focusedRow, equals: .quality)
                .accessibilityIdentifier("Settings.Row.quality")
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "rectangle.compress.vertical", tint: .orange, title: "Maximum Resolution",
                             value: model.maximumResolutionText) { picker = .maximumResolution }
                .focused($focusedRow, equals: .maximumResolution)
                .accessibilityIdentifier("Settings.Row.maximumResolution")
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "sparkles.rectangle.stack", tint: .orange, title: DolbyVisionPlaybackMode.settingTitle,
                             detail: DolbyVisionPlaybackMode.settingFooterKey,
                             value: model.dolbyVisionMode.title) { picker = .dolbyVision }
                .focused($focusedRow, equals: .dolbyVision)
                .accessibilityIdentifier("Settings.Row.dolbyVision")
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "play.square.stack.fill", tint: .green, title: "Settings.AutoPlayNext",
                             detail: "Settings.AutoPlayNext.Footer", detailLines: 3,
                             value: glassSettingsLocalized(model.autoPlayNext ? "On" : "Off"),
                             showsChevron: false) { model.toggleAutoPlayNext() }
                .focused($focusedRow, equals: .autoPlayNext)
                .accessibilityIdentifier("Settings.Row.autoPlayNext")
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "timer", tint: .green, title: "Settings.UpNextCard",
                             value: model.upNextCardLeadText(model.upNextCardLead)) { picker = .upNextCard }
                .focused($focusedRow, equals: .upNextCard)
                .accessibilityIdentifier("Settings.Row.upNextCard")
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "speaker.wave.2.fill", tint: .blue, title: "Audio Language",
                             value: model.languageName(model.audioLanguage, subtitles: false)) { picker = .audio }
                .focused($focusedRow, equals: .audio)
            if model.showsLanguageFirst {
                GlassSettingsDivider()
                GlassSettingsRow(symbol: "text.bubble.fill", tint: .blue, title: "Prefer Your Language",
                                 detail: "A release in your audio language comes before a higher resolution in another language.",
                                 detailLines: 3,
                                 value: glassSettingsLocalized(model.languageFirst ? "On" : "Off"),
                                 showsChevron: false) { model.toggleLanguageFirst() }
                    .focused($focusedRow, equals: .languageFirst)
                    .accessibilityIdentifier("Settings.Row.languageFirst")
            }
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "captions.bubble.fill", tint: .teal, title: "Subtitle Language",
                             value: model.languageName(model.subtitleLanguage, subtitles: true)) { picker = .subtitles }
                .focused($focusedRow, equals: .subtitles)
        }
    }

    private var detailPagesSection: some View {
        GlassSettingsSection(title: "Detail Pages",
                             footer: "Plays the soundtrack of the movie or the theme of the show on its page.") {
            GlassSettingsRow(symbol: "music.note", tint: .pink, title: "Theme Songs",
                             value: glassSettingsLocalized(model.themeSongs ? "On" : "Off"),
                             showsChevron: false) { model.toggleThemeSongs() }
                .focused($focusedRow, equals: .themeSongs)
        }
    }

    /// The Home tab: what it shows, and what it asks about the user's shows.
    private var homeSection: some View {
        GlassSettingsSection(title: "Home", footer: nil) {
            GlassSettingsRow(symbol: "globe", tint: .indigo, title: "Languages",
                             detail: "Home.Settings.Languages.Detail",
                             value: model.homeLanguagesSummary) { picker = .homeLanguages }
                .focused($focusedRow, equals: .homeLanguages)
                .accessibilityIdentifier("Settings.Row.homeLanguages")
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "rectangle.stack.fill", tint: .purple, title: "Shown Shelves",
                             detail: "Home.Settings.Shelves.Detail",
                             value: model.homeShelvesSummary) { picker = .homeShelves }
                .focused($focusedRow, equals: .homeShelves)
                .accessibilityIdentifier("Settings.Row.homeShelves")
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "square.stack.3d.down.right.fill", tint: .green, title: "Grouped Episode Lookup",
                             detail: "Home.Settings.Lookup.Detail",
                             value: glassSettingsLocalized(model.home?.groupedEpisodeLookup == true ? "On" : "Off"),
                             showsChevron: false) { model.toggleGroupedEpisodeLookup() }
                .focused($focusedRow, equals: .homeLookup)
                .accessibilityIdentifier("Settings.Row.homeLookup")
        }
    }

    /// The Home's « Services » row and the grids' « Service » filter: the
    /// user's TMDB key, the country, the services. The footer credits
    /// JustWatch and carries TMDB's notice, as TMDB's terms ask, and says
    /// that Popcorn Time does not play from these services.
    private var streamingSection: some View {
        GlassSettingsSection(title: "Settings.Streaming", footer: "Settings.Streaming.Footer") {
            GlassSettingsRow(symbol: "key.fill", tint: .yellow, title: "Settings.TMDBKey",
                             detail: "Settings.TMDBKey.Detail",
                             value: model.isCheckingTMDBKey ? "…" : model.tmdbKeySummary) { picker = .tmdbKey }
            .focused($focusedRow, equals: .tmdbKey)
            .accessibilityIdentifier("Settings.Row.tmdbKey")
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "flag.fill", tint: .blue, title: "Settings.StreamingRegion",
                             value: model.streamingRegionSummary) {
                model.loadStreamingRegionChoices()
                picker = .streamingRegion
            }
            .focused($focusedRow, equals: .streamingRegion)
            .accessibilityIdentifier("Settings.Row.streamingRegion")
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "play.tv.fill", tint: .red, title: "Settings.StreamingServices",
                             value: model.streamingServicesSummary) {
                model.loadStreamingServiceChoices()
                picker = .streamingServices
            }
            .focused($focusedRow, equals: .streamingServices)
            .accessibilityIdentifier("Settings.Row.streamingServices")
        }
    }

    /// Two rows: Switch Profile, its icon the profile's own avatar (the
    /// picker's Manage Profiles edits them), and Your Preferences.
    private var profilesSection: some View {
        GlassSettingsSection(title: "Profiles", footer: "Profiles.Footer") {
            if let profile = model.profile {
                GlassSettingsRow(symbol: "", tint: .clear, leading: AnyView(ProfileAvatarView(avatar: profile.avatar, size: 56)),
                                 title: "Profiles.Switch", value: profile.name) { model.actions.showProfiles() }
                    .focused($focusedRow, equals: .switchProfile)
                    .accessibilityIdentifier("Settings.Row.switchProfile")
                GlassSettingsDivider()
                GlassSettingsRow(symbol: "sparkles", tint: .pink, title: "Profiles.Taste",
                                 value: profile.preferences ?? glassSettingsLocalized("Profiles.Taste.Nothing")) {
                    model.loadTaste()
                    picker = .taste
                }
                .focused($focusedRow, equals: .profilePreferences)
                .accessibilityIdentifier("Settings.Row.profilePreferences")
            }
        }
    }

    private var storageSection: some View {
        GlassSettingsSection(title: "Storage",
                             footer: "Temporary video files, posters and network caches.") {
            GlassSettingsRow(symbol: "internaldrive.fill", tint: .gray, title: "Clear Cache",
                             value: model.cacheBytes.map(glassSettingsByteString) ?? "…",
                             showsChevron: false) { confirmClear = true }
                .focused($focusedRow, equals: .clearCache)
        }
    }

    private var accountSection: some View {
        GlassSettingsSection(title: "Account", footer: nil) {
            GlassSettingsRow(symbol: "person.crop.circle.badge.xmark", tint: .red, title: "Sign Out of Trakt",
                             value: nil, showsChevron: false) { confirmSignOut = true }
                .focused($focusedRow, equals: .trakt)
        }
    }

    private var aboutSection: some View {
        GlassSettingsSection(title: "About",
                             footer: "Popcorn Time is free and open-source software.") {
            GlassSettingsRow(symbol: "info.circle.fill", tint: GlassSettingsPalette.accent, title: "Version",
                             subtitle: "What's New", value: model.version) { model.actions.showWhatsNew() }
                .focused($focusedRow, equals: .version)
        }
    }

    private var clearCacheMessage: String {
        if model.actions.hasActiveDownloads() {
            return glassSettingsLocalized("A download is in progress. Clear the cache once it has finished.")
        }
        let size = model.cacheBytes.map(glassSettingsByteString) ?? "…"
        return String(format: glassSettingsLocalized("About %@ will be freed."), size)
    }

    // MARK: Pickers

    @ViewBuilder
    private func pickerSheet(_ picker: GlassSettingsPicker) -> some View {
        switch picker {
        case .quality:
            GlassSettingsPickerSheet(
                title: "Auto Select Quality",
                message: "Choose a default quality. If said quality is available, it will be automatically selected.",
                options: GlassSettingsAutoQuality.allCases.map {
                    .init(id: $0.rawValue, title: glassSettingsLocalized($0.titleKey),
                          detail: glassSettingsLocalized($0.detailKey))
                },
                selectedID: model.autoQuality.rawValue,
                onSelect: { id in
                    if let quality = GlassSettingsAutoQuality(rawValue: id) { model.select(autoQuality: quality) }
                    self.picker = nil
                },
                onCancel: { self.picker = nil })
        case .maximumResolution:
            GlassSettingsPickerSheet(
                title: "Maximum Resolution",
                message: "The automatic choice stays at or below it. Higher sources stay in the list.",
                options: [.init(id: "0", title: glassSettingsLocalized("No Limit"), detail: nil)]
                    + model.actions.maximumResolutionChoices.map { .init(id: $0.id, title: $0.title, detail: nil) },
                selectedID: String(model.maximumResolution),
                onSelect: { id in
                    if let lines = Int(id) { model.select(maximumResolution: lines) }
                    self.picker = nil
                },
                onCancel: { self.picker = nil })
        case .dolbyVision:
            GlassSettingsPickerSheet(
                title: DolbyVisionPlaybackMode.settingTitle,
                message: DolbyVisionPlaybackMode.settingFooterKey,
                options: DolbyVisionPlaybackMode.allCases.map { .init(id: $0.rawValue, title: $0.title, detail: nil) },
                selectedID: model.dolbyVisionMode.rawValue,
                onSelect: { id in
                    if let mode = DolbyVisionPlaybackMode(rawValue: id) { model.select(dolbyVisionMode: mode) }
                    self.picker = nil
                },
                onCancel: { self.picker = nil })
        case .upNextCard:
            GlassSettingsPickerSheet(
                title: "Settings.UpNextCard",
                message: "Settings.UpNextCard.Message",
                options: model.actions.upNextCardLeadChoices.map {
                    .init(id: String($0), title: model.upNextCardLeadText($0), detail: nil)
                },
                selectedID: String(model.upNextCardLead),
                onSelect: { id in
                    if let seconds = Int(id) { model.select(upNextCardLead: seconds) }
                    self.picker = nil
                },
                onCancel: { self.picker = nil })
        case .audio:
            GlassSettingsPickerSheet(
                title: "Audio Language",
                message: "Choose a preferred audio language. When the file carries a matching audio track, it will be selected automatically.",
                options: languageOptions(subtitles: false),
                selectedID: model.audioLanguage,
                onSelect: { id in
                    model.select(audioLanguage: id)
                    self.picker = nil
                },
                onCancel: { self.picker = nil })
        case .subtitles:
            GlassSettingsPickerSheet(
                title: "Subtitle Language",
                message: "Choose a default language for the player subtitles.",
                options: languageOptions(subtitles: true),
                selectedID: model.subtitleLanguage,
                onSelect: { id in
                    model.select(subtitleLanguage: id)
                    self.picker = nil
                },
                onCancel: { self.picker = nil })
        case .homeLanguages:
            // Several can be checked: a press checks or unchecks, Menu closes.
            GlassSettingsPickerSheet(
                title: "Content Languages",
                message: "Home.Settings.Languages.Message",
                options: [.init(id: "", title: glassSettingsLocalized("All Languages"), detail: nil)]
                    + (model.home?.languageChoices ?? []).map { .init(id: $0.id, title: $0.title, detail: nil) },
                selectedID: model.home?.languages.first ?? "",
                checkedIDs: Set(model.home?.languages ?? []).union(model.home?.languages.isEmpty == false ? [] : [""]),
                onSelect: { id in model.toggle(homeLanguage: id.isEmpty ? nil : id) },
                onCancel: { self.picker = nil })
        case .homeShelves:
            GlassSettingsPickerSheet(
                title: "Home Shelves",
                message: "Home.Settings.Shelves.Message",
                options: (model.home?.shelfChoices ?? []).map { .init(id: $0.id, title: $0.title, detail: nil) },
                selectedID: model.home?.shelfChoices.first?.id ?? "",
                checkedIDs: Set((model.home?.shelfChoices ?? []).map(\.id)).subtracting(model.home?.hiddenShelves ?? []),
                onSelect: { id in model.toggle(homeShelf: id) },
                onCancel: { self.picker = nil })
        case .tmdbKey:
            GlassSettingsTextSheet(
                title: "Settings.TMDBKey",
                message: "Settings.TMDBKey.Message",
                placeholder: "Settings.TMDBKey.Placeholder",
                removeTitle: model.home?.hasTMDBKey == true ? "Settings.TMDBKey.Remove" : nil,
                checkTitle: model.home?.hasTMDBKey == true ? "Settings.TMDBKey.Check" : nil,
                qrCode: model.actions.tmdbKeyQRCode(),
                qrCaption: "Settings.TMDBKey.QR",
                onSave: { key in
                    self.picker = nil
                    saveTMDBKey(key)
                },
                onCheck: {
                    self.picker = nil
                    checkTMDBKeyAgain()
                },
                onRemove: {
                    self.picker = nil
                    saveTMDBKey(nil)
                },
                onCancel: { self.picker = nil })
        case .streamingRegion:
            GlassSettingsPickerSheet(
                title: "Settings.StreamingRegion",
                message: "Settings.StreamingRegion.Message",
                options: model.streamingRegionOptions.map { .init(id: $0.id, title: $0.title, detail: nil) },
                selectedID: model.home?.streamingRegion ?? "",
                onSelect: { id in
                    model.select(streamingRegion: id)
                    self.picker = nil
                },
                onCancel: { self.picker = nil })
        case .streamingServices:
            // Several can be checked: a press checks or unchecks, Menu closes.
            GlassSettingsPickerSheet(
                title: "Settings.StreamingServices",
                message: model.home?.hasTMDBKey == true ? "Settings.StreamingServices.Message" : "Settings.StreamingServices.NoKey",
                options: model.streamingServiceOptions.map { .init(id: $0.id, title: $0.title, detail: nil) },
                selectedID: model.home?.streamingServices.first?.id ?? model.streamingServiceOptions.first?.id ?? "",
                checkedIDs: Set((model.home?.streamingServices ?? []).map(\.id)),
                onSelect: { id in
                    if let choice = model.streamingServiceOptions.first(where: { $0.id == id }) { model.toggle(streamingService: choice) }
                },
                onCancel: { self.picker = nil })
        case .taste:
            GlassSettingsTasteSheet(
                lines: model.taste,
                profileName: model.profile?.name ?? "",
                onReset: { model.resetTaste() },
                onClose: { self.picker = nil })
        }
    }

    /// « Automatic (French) » (what it does, under it), "None" (id "")
    /// then every language.
    private func languageOptions(subtitles: Bool) -> [GlassSettingsPickerSheet.Option] {
        [.init(id: GlassSettingsModel.automaticTag, title: model.languageName(GlassSettingsModel.automaticTag, subtitles: subtitles),
               detail: glassSettingsLocalized("Settings.Language.Automatic.Footer")),
         .init(id: "", title: glassSettingsLocalized("None"), detail: nil)]
            + model.languages.map { .init(id: $0.code, title: $0.name, detail: nil) }
    }
}

// MARK: - Building blocks

/// Section title, a glass card holding the rows, and an optional footer.
private struct GlassSettingsSection<Rows: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder var rows: Rows
    @Environment(\.glassSettingsFallback) private var fallback

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(glassSettingsLocalized(title))
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(GlassSettingsPalette.secondaryText)
                .padding(.leading, 28)
            VStack(spacing: 0) { rows }
                .padding(10)
                .modifier(GlassSettingsCard(cornerRadius: 34, fallback: fallback))
            if let footer {
                Text(glassSettingsLocalized(footer))
                    .font(.system(size: 23))
                    .foregroundStyle(GlassSettingsPalette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
            }
        }
    }
}

/// Regular Liquid Glass on tvOS 26+, an ultra-thin material with a hairline
/// before. Also the profile editor's card (ProfileViews.swift).
struct GlassSettingsCard: ViewModifier {
    let cornerRadius: CGFloat
    let fallback: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(tvOS 26.0, *), !fallback {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(Color.white.opacity(0.14), lineWidth: 1) }
        }
    }
}

private struct GlassSettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 1)
            .padding(.leading, 104)
            .padding(.trailing, 24)
    }
}

/// A focusable row: tinted symbol tile, title (and subtitle), value, chevron.
private struct GlassSettingsRow: View {
    let symbol: String
    let tint: Color
    /// Drawn in the 56 pt icon slot instead of the tinted symbol (the
    /// profile's avatar).
    var leading: AnyView? = nil
    let title: String
    var subtitle: String? = nil
    /// One sentence that says what the setting does, under the title and
    /// the value, on the row's full width (two lines at most; `detailLines`).
    var detail: String? = nil
    /// « Autoplay Next Episode »'s sentence takes three lines in French.
    var detailLines = 2
    let value: String?
    var showsChevron = true
    let action: () -> Void

    var body: some View {
        SwiftUI.Button(action: action) {
            HStack(spacing: 24) {
                if let leading {
                    leading
                        .frame(width: 56, height: 56)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(tint.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                if let detail {
                    VStack(alignment: .leading, spacing: 5) {
                        titleAndValue
                        Text(glassSettingsLocalized(detail))
                            .font(.system(size: 23, weight: .medium))
                            .opacity(0.6)
                            .lineLimit(detailLines)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 14)
                } else {
                    titleAndValue
                }
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 90)
            // Its whole height, whatever the column offers: the « Clé TMDB »
            // row (the fourth section of the right column) got less, its
            // two lines ran out of its platter.
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(GlassSettingsRowStyle())
    }

    /// The title (and subtitle), the value and the chevron, on one line.
    private var titleAndValue: some View {
        HStack(spacing: 24) {
            // A long title (Italian "Seleziona Automaticamente la
            // Qualità") wraps to a second line instead of pushing the
            // value out; the value keeps its width.
            VStack(alignment: .leading, spacing: 2) {
                Text(glassSettingsLocalized(title))
                    .font(.system(size: 31, weight: .medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(glassSettingsLocalized(subtitle))
                        .font(.system(size: 23, weight: .medium))
                        .opacity(0.6)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 16)
            if let value {
                Text(value)
                    .font(.system(size: 29))
                    .opacity(0.65)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
            }
            if showsChevron {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 24, weight: .semibold))
                    .opacity(0.4)
            }
        }
    }
}

/// Focus visual of the rows: unfocused, plain white text on the card;
/// focused, a bright platter (white-tinted glass on tvOS 26+, opaque white
/// before) with dark text, slightly lifted with a shadow.
struct GlassSettingsRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused
        @Environment(\.glassSettingsFallback) private var fallback

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .contentShape(shape)
                .background { platter(shape) }
                .scaleEffect(configuration.isPressed ? 1.01 : (isFocused ? 1.04 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 22, y: 14)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }

        @ViewBuilder
        private func platter(_ shape: RoundedRectangle) -> some View {
            if isFocused {
                if #available(tvOS 26.0, *), !fallback {
                    Color.clear.glassEffect(.regular.tint(.white.opacity(0.9)), in: shape)
                } else {
                    shape.fill(Color.white.opacity(0.94))
                }
            }
        }
    }
}

/// Glass sheet listing the choices of one setting; the current one has a
/// checkmark and the focus. Menu closes it without changing anything.
struct GlassSettingsPickerSheet: View {
    struct Option: Identifiable {
        /// "" for "None".
        let id: String
        let title: String
        let detail: String?
    }

    let title: String
    let message: String?
    let options: [Option]
    /// The current choice: it has the focus when the sheet opens.
    let selectedID: String
    /// A list where several lines can be checked: the checked ones. A press
    /// then checks or unchecks (the host keeps the sheet open); nil: one
    /// choice, the checkmark is on `selectedID`.
    var checkedIDs: Set<String>? = nil
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focusedID: String?
    @Environment(\.glassSettingsFallback) private var fallback

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text(glassSettingsLocalized(title))
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 58)
                if let message {
                    Text(glassSettingsLocalized(message))
                        .font(.system(size: 24))
                        .foregroundStyle(GlassSettingsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 58)
                }
                // Clipped to the panel; the side padding leaves room for the
                // focused row's lift.
                ScrollView {
                    // Not lazy: the default focus must reach the current choice
                    // even when it is far down the list (≈40 rows at most).
                    VStack(spacing: 6) {
                        ForEach(options) { option in
                            optionRow(option)
                        }
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 36)
                }
            }
            .padding(.top, 44)
            .padding(.bottom, 20)
            .frame(width: 1000)
            .frame(maxHeight: 880)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(GlassSettingsCard(cornerRadius: 50, fallback: fallback))
        }
        .defaultFocus($focusedID, selectedID)
        .onExitCommand(perform: onCancel)
        .presentationBackground(.clear)
        .accessibilityIdentifier("Settings.Picker")
    }

    private func optionRow(_ option: Option) -> some View {
        SwiftUI.Button { onSelect(option.id) } label: {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .font(.system(size: 31, weight: .medium))
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 22, weight: .medium))
                            .opacity(0.65)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .opacity((checkedIDs?.contains(option.id) ?? (option.id == selectedID)) ? 1 : 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, option.detail == nil ? 18 : 16)
        }
        .buttonStyle(GlassSettingsRowStyle(cornerRadius: 22))
        .focused($focusedID, equals: option.id)
    }
}

/// Your Preferences (Settings › Profiles), a glass sheet like the pickers:
/// what the active profile's taste learned, a facet a line — not focusable,
/// there is nothing to choose — and Reset Preferences, the one focus. Reset
/// asks in the card itself (a system alert stacked a second glass layer
/// over this one): the question and its message take the header's place,
/// then Reset Preferences and Cancel, the focus on Cancel; Menu cancels.
/// Nothing learned: the title and one line on the header's edge (no footer
/// over it: one explanation, not two), the line holding the focus so that
/// Menu still reaches the sheet. Menu closes it.
struct GlassSettingsTasteSheet: View {
    let lines: [GlassSettingsTasteLine]
    /// For the confirmation (« Forget what was learned for « Alex »? »).
    let profileName: String
    let onReset: () -> Void
    let onClose: () -> Void

    @State private var confirmReset = false
    @FocusState private var focus: Focus?
    @Environment(\.glassSettingsFallback) private var fallback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Focus: Hashable { case reset, confirm, cancel }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text(confirmReset ? String(format: glassSettingsLocalized("Profiles.Taste.ResetConfirm"), profileName)
                                  : glassSettingsLocalized("Profiles.Taste"))
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("Profiles.Taste.Title")
                    .padding(.horizontal, 58)
                if confirmReset || !lines.isEmpty {
                    Text(glassSettingsLocalized(confirmReset ? "Profiles.Taste.ResetMessage" : "Profiles.Taste.Footer"))
                        .font(.system(size: 24))
                        .foregroundStyle(GlassSettingsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 58)
                }
                if confirmReset {
                    confirmation
                } else if lines.isEmpty {
                    empty
                } else {
                    facts
                }
            }
            .padding(.top, 44)
            .padding(.bottom, 20)
            .frame(width: 1000)
            .frame(maxHeight: 880)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(GlassSettingsCard(cornerRadius: 50, fallback: fallback))
        }
        .onExitCommand { confirmReset ? ask(false) : onClose() }
        .presentationBackground(.clear)
    }

    /// Swaps the facts for the question (or back), the focus on Cancel (or
    /// back on Reset Preferences).
    private func ask(_ asking: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { confirmReset = asking }
        DispatchQueue.main.async { focus = asking ? .cancel : .reset }
    }

    /// Reset Preferences in red, then Cancel, the default.
    private var confirmation: some View {
        VStack(spacing: 0) {
            cardRow(glassSettingsLocalized("Profiles.Taste.Reset"), color: GlassSettingsPalette.accent) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { confirmReset = false }
                onReset()
            }
            .focused($focus, equals: .confirm)
            .accessibilityIdentifier("Profiles.Taste.ResetConfirm")
            cardRow(glassSettingsLocalized("Cancel")) { ask(false) }
                .focused($focus, equals: .cancel)
                .accessibilityIdentifier("Profiles.Taste.ResetCancel")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 36)
    }

    /// A full-width row of the card (Settings' row style). No colour: the
    /// row style's own, white at rest and black on the focused platter — a
    /// fixed white would vanish there.
    private func cardRow(_ title: String, color: Color? = nil, action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) {
            Group {
                if let color { Text(title).foregroundStyle(color) } else { Text(title) }
            }
                .font(.system(size: 31, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.vertical, 18)
        }
        .buttonStyle(GlassSettingsRowStyle(cornerRadius: 22))
    }

    /// The facts, then Reset Preferences under them.
    private var facts: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 1)
                        .padding(.horizontal, 26)
                }
                HStack(spacing: 0) {
                    Text(line.title)
                        .font(.system(size: 31, weight: .medium))
                        .foregroundStyle(GlassSettingsPalette.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 24)
                    Text(line.values)
                        .font(.system(size: 31))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 18)
                // One element a facet: « Genres, Drama · Science Fiction ».
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("Profiles.Taste.\(line.id)")
            }
            // Red words on the card, still red on the focused white platter
            // (large text): never red on red.
            cardRow(glassSettingsLocalized("Profiles.Taste.Reset"), color: GlassSettingsPalette.accent) { ask(true) }
                .focused($focus, equals: .reset)
                .accessibilityIdentifier("Profiles.Taste.Reset")
                .padding(.top, 16)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 36)
    }

    /// On the header's edge, as the facts' rows: leading, not centred
    /// under a leading title.
    private var empty: some View {
        Text(glassSettingsLocalized("Profiles.Taste.Empty"))
            .font(.system(size: 29))
            .foregroundStyle(GlassSettingsPalette.secondaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 26)
            // The sheet's one focus target, drawn as nothing: without one,
            // Menu would not reach the sheet.
            .focusable()
            .focusEffectDisabled()
            .accessibilityIdentifier("Profiles.Taste.Empty")
            .padding(.horizontal, 58)
    }
}

/// Glass sheet with one text field (the TMDB key). Selecting the field
/// opens tvOS's full-screen keyboard — the one the iPhone offers to type
/// into (« Apple TV Keyboard » notification, or the Remote in Control
/// Center), so a long key can be pasted from the phone. Beside it, a QR
/// code a phone opens TMDB's API page with, to copy the key there. Menu
/// closes it.
struct GlassSettingsTextSheet: View {
    let title: String
    let message: String?
    let placeholder: String
    /// nil: no « Remove » button.
    let removeTitle: String?
    /// nil: no « Check Again » button (no key stored).
    var checkTitle: String? = nil
    /// A QR code shown beside the text, on a light plate; nil: none.
    var qrCode: CGImage? = nil
    /// The line under the QR code, saying what it opens.
    var qrCaption: String? = nil
    let onSave: (String) -> Void
    var onCheck: () -> Void = {}
    let onRemove: () -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Field?
    @Environment(\.glassSettingsFallback) private var fallback

    private enum Field: Hashable { case text, save, check, remove, cancel }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 26) {
                // The sheet's name for the UI tests, on its title only: on
                // the whole sheet it would replace its controls' own.
                Text(glassSettingsLocalized(title))
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("Settings.TextSheet")
                // The code beside the text and the field; the buttons under
                // both, on the sheet's whole width.
                HStack(alignment: .top, spacing: 50) {
                    form
                    if let qrCode {
                        qrPanel(qrCode)
                    }
                }
                buttons
            }
            .padding(58)
            .frame(width: qrCode == nil ? 1100 : 1500)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(GlassSettingsCard(cornerRadius: 50, fallback: fallback))
        }
        .defaultFocus($focused, .text)
        .onExitCommand(perform: onCancel)
        .presentationBackground(.clear)
    }

    /// The code on a white plate (a phone reads it on a dark screen), drawn
    /// pixel for pixel, and one line under it. Not focusable.
    private func qrPanel(_ image: CGImage) -> some View {
        let caption = qrCaption.map(glassSettingsLocalized) ?? ""
        return VStack(spacing: 18) {
            Image(image, scale: 1, label: Text(caption))
                .resizable()
                .interpolation(.none)
                .frame(width: 248, height: 248)
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                // One image element, named by the line under it.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(caption))
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("Settings.TMDBKey.QR")
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(GlassSettingsPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 280)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let message {
                Text(glassSettingsLocalized(message))
                    .font(.system(size: 24))
                    .foregroundStyle(GlassSettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(glassSettingsLocalized(placeholder), text: $text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .focused($focused, equals: .text)
                .onSubmit { if !trimmed.isEmpty { focused = .save } }
                .accessibilityIdentifier("Settings.TMDBKey.Field")
        }
    }

    private var buttons: some View {
        HStack(spacing: 24) {
            SwiftUI.Button(glassSettingsLocalized("Save")) { onSave(trimmed) }
                .disabled(trimmed.isEmpty)
                .focused($focused, equals: .save)
            if let checkTitle {
                SwiftUI.Button(glassSettingsLocalized(checkTitle), action: onCheck)
                    .focused($focused, equals: .check)
                    .accessibilityIdentifier("Settings.TMDBKey.Check")
            }
            if let removeTitle {
                SwiftUI.Button(glassSettingsLocalized(removeTitle), role: .destructive, action: onRemove)
                    .focused($focused, equals: .remove)
            }
            SwiftUI.Button(glassSettingsLocalized("Cancel"), role: .cancel, action: onCancel)
                .focused($focused, equals: .cancel)
        }
    }
}

/// The page backdrop: the black of the other pages (the Home, the grids),
/// with a faint light at the top for the glass cards to refract.
private struct GlassSettingsBackdrop: View {
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color.white.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: 1100)
        }
    }
}
