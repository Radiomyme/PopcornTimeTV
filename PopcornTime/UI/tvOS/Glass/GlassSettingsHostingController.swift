// GlassSettingsHostingController.swift — puts `GlassSettingsView` in the
// Settings tab and connects it to the app's preferences (UserDefaults, Trakt,
// cache, What's New). The view itself knows nothing of the app.

import UIKit
import SwiftUI
import PopcornKit
import class PopcornTorrent.PTTorrentDownloadManager

/// Root of the Settings tab (installed by `TVTabBarController`).
final class GlassSettingsHostingController: UIHostingController<GlassSettingsView> {
    private let model: GlassSettingsModel

    init() {
        let actions = GlassSettingsActions(
            setAutoQuality: { GlassSettingsStore.store(autoQuality: $0) },
            setAudioLanguage: { PlaybackLanguagePreferences.store(.init(tag: $0), subtitles: false) },
            setSubtitleLanguage: { PlaybackLanguagePreferences.store(.init(tag: $0), subtitles: true) },
            automaticLanguageName: { PlaybackLanguagePreferences.automaticName(subtitles: $0) },
            setThemeSongs: { GlassSettingsStore.themeSongs = $0 },
            readThemeSongs: { GlassSettingsStore.themeSongs },
            setAutoPlayNext: { UpNextPreferences.autoPlayNext = $0 },
            readAutoPlayNext: { UpNextPreferences.autoPlayNext },
            setUpNextCardLead: { UpNextPreferences.cardLeadSeconds = $0 },
            readUpNextCardLead: { UpNextPreferences.cardLeadSeconds },
            upNextCardLeadChoices: UpNextCountdown.cardLeadChoices,
            setMaximumResolution: { GlassSettingsStore.store(maximumResolution: $0) },
            readMaximumResolution: { SourcePreferences.maximumResolution?.rawValue ?? 0 },
            maximumResolutionChoices: SourcePreferences.maximumResolutionChoices.map {
                GlassSettingsChoice(id: String($0.rawValue), title: $0.settingsLabel)
            },
            setLanguageFirst: { UserDefaults.standard.set($0, forKey: SourcePreferences.languageFirstKey) },
            readLanguageFirst: { SourcePreferences.languageFirst },
            measureCache: { GlassSettingsStore.cacheSize() },
            clearCache: { AppDelegate.aggressivelyFreeDiskSpace() },
            hasActiveDownloads: { !PTTorrentDownloadManager.shared().activeDownloads.isEmpty },
            isTraktSignedIn: { TraktManager.shared.isSignedIn() },
            signOutOfTrakt: { try? TraktManager.shared.logout() },
            showWhatsNew: {
                guard let root = AppDelegate.shared.window?.rootViewController else { return }
                WhatsNewPresenter.present(from: root)
            },
            readHome: { GlassSettingsStore.home },
            setHomeLanguages: { GlassSettingsStore.store(homeLanguages: $0) },
            setHiddenHomeShelves: { GlassSettingsStore.store(hiddenHomeShelves: $0) },
            setGroupedEpisodeLookup: { GlassSettingsStore.store(groupedEpisodeLookup: $0) },
            setTMDBKey: { GlassSettingsStore.store(tmdbKey: $0, completion: $1) },
            checkTMDBKeyAgain: { GlassSettingsStore.checkTMDBKeyAgain(completion: $0) },
            tmdbKeyQRCode: { GlassSettingsStore.tmdbKeyQRCode() },
            setStreamingRegion: { GlassSettingsStore.store(streamingRegion: $0) },
            setStreamingServices: { GlassSettingsStore.store(streamingServices: $0) },
            loadStreamingServices: { GlassSettingsStore.streamingServices(region: $0, completion: $1) },
            loadStreamingRegions: { GlassSettingsStore.streamingRegions(completion: $0) },
            regionName: { GlassSettingsStore.regionName($0) },
            readProfile: {
                let profile = ProfileManager.shared.active
                return GlassSettingsProfile(name: profile.name, avatar: profile.avatar,
                                            preferences: ProfileTasteModel.summary())
            },
            showProfiles: {
                guard let root = AppDelegate.shared.window?.rootViewController else { return }
                ProfilesPresenter.present(from: root)
            },
            readTaste: {
                ProfileTasteModel.lines(of: .shared).map {
                    GlassSettingsTasteLine(id: $0.id, title: $0.title, values: $0.values.joined(separator: " · "))
                }
            },
            resetTaste: { ProfileTaste.shared.reset() })

        // Never set, « None » or a language: three states the rows tell apart.
        let audio = PlaybackLanguagePreferences.audioSetting
        let subtitles = PlaybackLanguagePreferences.subtitleSetting
        model = GlassSettingsModel(autoQuality: GlassSettingsStore.autoQuality,
                                   audioLanguage: audio.tag,
                                   subtitleLanguage: subtitles.tag,
                                   themeSongs: GlassSettingsStore.themeSongs,
                                   version: Bundle.main.displayVersion,
                                   languages: GlassSettingsStore.languages(including: [audio.code, subtitles.code]),
                                   actions: actions)
        #if DEBUG
        // `-PTDebugSettingsRow <row>` (homeLanguages, homeShelves, homeLookup,
        // maximumResolution, languageFirst, tmdbKey, streamingRegion, streamingServices, switchProfile,
        // profilePreferences…): the row that takes the focus;
        // `-PTDebugSettingsPicker <picker>` (homeLanguages, homeShelves,
        // taste…): the sheet open at first display.
        let row: GlassSettingsRowID
        switch UserDefaults.standard.string(forKey: "PTDebugSettingsRow") {
        case "homeLanguages": row = .homeLanguages
        case "homeShelves": row = .homeShelves
        case "homeLookup": row = .homeLookup
        case "autoPlayNext": row = .autoPlayNext
        case "upNextCard": row = .upNextCard
        case "maximumResolution": row = .maximumResolution
        case "languageFirst": row = .languageFirst
        case "dolbyVision": row = .dolbyVision
        case "tmdbKey": row = .tmdbKey
        case "streamingRegion": row = .streamingRegion
        case "streamingServices": row = .streamingServices
        case "switchProfile": row = .switchProfile
        case "profilePreferences": row = .profilePreferences
        default: row = .quality
        }
        let picker = UserDefaults.standard.string(forKey: "PTDebugSettingsPicker").flatMap(GlassSettingsPicker.init(rawValue:))
        super.init(rootView: GlassSettingsView(model: model, initialPicker: picker, defaultFocusRow: row))
        #else
        super.init(rootView: GlassSettingsView(model: model))
        #endif
    }

    @available(*, unavailable, message: "Created in code by TVTabBarController")
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.refresh()
    }
}

/// Reading and writing the preferences the Settings page shows, in the formats
/// the rest of the app reads.
enum GlassSettingsStore {
    private static var defaults: UserDefaults { .standard }

    // MARK: Auto Select Quality ("autoSelectQuality")

    private static let autoQualityKey = "autoSelectQuality"

    /// The quality chooser (`AppDelegate.presentQualityChoice`) compares the
    /// stored value to the *localized* title ("Balanced".localized), so that
    /// is what is stored; nil means Off (always ask).
    /// Quick Start and Best Picture are stored as Balanced (what the
    /// quality chooser and Up Next read) with their `SourcePriority`.
    static var autoQuality: GlassSettingsAutoQuality {
        let stored = autoQuality(fromStored: defaults.string(forKey: autoQualityKey))
        guard stored == .balanced else { return stored }
        switch SourcePreferences.priority {
        case .quickStart: return .quickStart
        case .balanced: return .balanced
        case .picture: return .bestPicture
        }
    }

    static func store(autoQuality: GlassSettingsAutoQuality) {
        let stored: GlassSettingsAutoQuality
        let priority: SourcePriority
        switch autoQuality {
        case .quickStart: (stored, priority) = (.balanced, .quickStart)
        case .bestPicture: (stored, priority) = (.balanced, .picture)
        default: (stored, priority) = (autoQuality, .balanced)
        }
        defaults.set(stored == .off ? nil : stored.titleKey.localized, forKey: autoQualityKey)
        // Balanced is the default: nothing stored, nothing left behind.
        defaults.set(priority == .balanced ? nil : priority.rawValue, forKey: SourcePreferences.priorityKey)
    }

    /// Recognizes a stored value written in any language the app ships (or
    /// the raw English key), so a change of UI language keeps the setting.
    /// Only Balanced is stored (Quick Start and Best Picture are Balanced
    /// with their priority); anything else is Off.
    static func autoQuality(fromStored value: String?) -> GlassSettingsAutoQuality {
        guard let value, !value.isEmpty else { return .off }
        return spellings(of: GlassSettingsAutoQuality.balanced.titleKey).contains(value) ? .balanced : .off
    }

    /// 0 removes the limit.
    static func store(maximumResolution lines: Int) {
        defaults.set(lines > 0 ? lines : nil, forKey: SourcePreferences.maximumResolutionKey)
    }

    /// Launch: rewrites a value stored under another UI language (e.g. English
    /// "Balanced" before the app had a French localization) in the current one,
    /// so the quality chooser still matches it. A retired « Highest » or
    /// « Lowest » first becomes Best Picture or Quick Start
    /// (`AutomaticQualityChoice.migrateRetiredChoices`): read as Off here,
    /// it would have turned into Always Ask.
    static func normalizeStoredAutoQuality() {
        AutomaticQualityChoice.migrateRetiredChoices(in: defaults)
        guard let stored = defaults.string(forKey: autoQualityKey) else { return }
        let quality = autoQuality(fromStored: stored)
        let canonical: String? = quality == .off ? nil : quality.titleKey.localized
        if canonical != stored { defaults.set(canonical, forKey: autoQualityKey) }
    }

    /// The key, its current translation and its translation in every
    /// localization of the app bundle.
    private static func spellings(of key: String) -> Set<String> {
        var result: Set<String> = [key, key.localized]
        for localization in Bundle.main.localizations {
            guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings",
                                              inDirectory: nil, forLocalization: localization),
                  let table = NSDictionary(contentsOfFile: path) as? [String: String],
                  let value = table[key] else { continue }
            result.insert(value)
        }
        return result
    }

    // MARK: Languages ("preferredAudioLanguage", "preferredSubtitleLanguage")
    // Written by `PlaybackLanguagePreferences.store(_:subtitles:)`, as on
    // the iPhone and the Mac.

    /// The picker languages, sorted by name, plus any current choice outside them.
    static func languages(including current: [String?]) -> [GlassSettingsLanguage] {
        var codes = PlaybackLanguagePreferences.sortedPickerLanguageCodes
        for code in current.compactMap({ $0 }) where !codes.contains(code) {
            codes.insert(code, at: 0)
        }
        return codes.map { GlassSettingsLanguage(code: $0, name: PlaybackLanguagePreferences.displayName(forCode: $0)) }
    }

    // MARK: Theme songs ("themeSongVolume", read by ThemeSongManager)

    /// Volume written when theme songs are turned on: 0.25, the volume a
    /// fresh install always had (ThemeSongManager scales it further).
    static let themeSongOnVolume: Float = 0.25

    static var themeSongs: Bool {
        get { defaults.float(forKey: "themeSongVolume") > 0 }
        set { defaults.set(newValue ? themeSongOnVolume : 0, forKey: "themeSongVolume") }
    }

    // MARK: Home ("popcornkit.home.contentLanguages", "popcornkit.home.hiddenShelves", "libraryBulkEpisodeLookup")

    /// Languages a title is often shot in, offered as content languages
    /// next to the ones already chosen and the device's.
    private static let homeLanguageCodes = [
        "en", "fr", "es", "de", "it", "pt", "nl", "sv", "da", "no", "fi", "pl", "cs", "hu", "ro", "el", "tr", "ru", "uk",
        "ar", "he", "fa", "hi", "ta", "te", "ml", "bn", "ja", "ko", "zh", "th", "vi", "id",
    ]

    /// The Home tab's settings as the hub reads them (`HomeSettings`), with
    /// the choices the page offers.
    @MainActor
    static var home: GlassSettingsHome {
        let settings = HomeSettings(defaults: defaults)
        let languages = settings.contentLanguages
        var codes = homeLanguageCodes
        for code in languages + HomeSettings.defaultLanguages(device: Locale.preferredLanguages) where !codes.contains(code) {
            codes.append(code)
        }
        let locale = Locale.current
        let languageChoices = codes.map { code in
            GlassSettingsChoice(id: code, title: (locale.localizedString(forLanguageCode: code) ?? code).capitalized(with: locale))
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // The fixed shelves in the Home's order (the hero is the page
        // itself), then the genre shelves on screen or hidden earlier.
        let hidden = settings.hiddenShelves
        let text = HomeText.standard
        streaming.reload()
        let hasKey = streaming.hasKey
        // The « Services » row, under Continue Watching, once there is a key.
        var shelves = StreamingSettingsStore.shelves(HomeShelfID.order.filter { $0 != HomeShelfID.hero }, hasKey: hasKey)
        let genres = HomeState.shared.shelves.map(\.id).filter { HomeShelfID.genre(of: $0) != nil }
            + hidden.filter { HomeShelfID.genre(of: $0) != nil }.sorted()
        for id in genres where !shelves.contains(id) { shelves.append(id) }
        return GlassSettingsHome(languages: languages,
                                 hiddenShelves: hidden,
                                 groupedEpisodeLookup: Library.shared.isBulkEpisodeLookupEnabled,
                                 languageChoices: languageChoices,
                                 shelfChoices: shelves.map { GlassSettingsChoice(id: $0, title: text.title(ofShelf: $0)) },
                                 hasTMDBKey: hasKey,
                                 isTMDBKeyRefused: streaming.keyState == .refused,
                                 streamingRegion: streaming.region,
                                 streamingServices: streaming.chosenServices.map { GlassSettingsChoice(id: $0.id, title: $0.title) })
    }

    // MARK: Streaming services ("popcornkit.tmdb.apiKey", "popcornkit.home.streamingRegion", "popcornkit.home.streamingServices")

    /// The streaming section's rules and storage, shared with the iPhone,
    /// iPad and Mac settings (PopcornKit's `StreamingSettingsStore` and
    /// `TMDBKeySettings`); its changes rebuild the app's hub. One for the
    /// app: it keeps the services TMDB listed last (their logos).
    @MainActor static let streaming = StreamingSettingsStore(hub: HomeState.shared, settings: HomeSettings(defaults: defaults))

    /// Checks the key with TMDB; keeps it unless TMDB refused it. nil
    /// removes the key (the streaming shelves go). The Home then asks the
    /// lists it now reads, or drops the shelves it no longer has.
    @MainActor
    static func store(tmdbKey key: String?, completion: @escaping (Bool?) -> Void) {
        guard let key else {
            streaming.removeKey()
            return completion(nil)
        }
        streaming.saveKey(key) { completion($0.accepted) }
    }

    /// Asks TMDB again about the stored key (« Vérifier à nouveau »): the
    /// key stays; a refusal shows as « Refusée ». The completion gets the
    /// verdict, nil when TMDB did not answer.
    @MainActor
    static func checkTMDBKeyAgain(completion: @escaping (Bool?) -> Void) {
        streaming.checkKeyAgain { completion($0?.accepted ?? nil) }
    }

    /// The QR code of the key sheet: TMDB's API settings page, never the key.
    static func tmdbKeyQRCode() -> CGImage? {
        return TMDBKeySettings.apiPageQRCode(scale: 8)
    }

    /// The chosen services then follow the country as soon as TMDB lists
    /// its services (`streamingServices(region:)`), picker open or not.
    @MainActor
    static func store(streamingRegion code: String) {
        streaming.select(region: code)
    }

    @MainActor
    static func store(streamingServices choices: [GlassSettingsChoice]) {
        streaming.setServices(choices.map { StreamingChoice(id: $0.id, title: $0.title) })
    }

    /// Also matches the chosen services to the country's
    /// (`StreamingSettingsStore.loadServices`).
    @MainActor
    static func streamingServices(region: String, completion: @escaping ([GlassSettingsChoice]?) -> Void) {
        streaming.loadServices(region: region) { choices in
            completion(choices?.map { GlassSettingsChoice(id: $0.id, title: $0.title) })
        }
    }

    /// TMDB's countries, else every country the system knows; by name.
    @MainActor
    static func streamingRegions(completion: @escaping ([GlassSettingsChoice]) -> Void) {
        streaming.loadRegions { choices in
            completion(choices.map { GlassSettingsChoice(id: $0.id, title: $0.title) })
        }
    }

    @MainActor
    static func regionName(_ code: String) -> String {
        streaming.regionName(code)
    }

    /// Empty: every language. The hub reads its settings when it builds the
    /// page: the shelves on screen follow at once, without a request.
    @MainActor
    static func store(homeLanguages codes: [String]) {
        HomeSettings(defaults: defaults).contentLanguages = codes
        HomeState.shared.refreshLocal()
    }

    @MainActor
    static func store(hiddenHomeShelves ids: Set<String>) {
        HomeSettings(defaults: defaults).hiddenShelves = ids
        HomeState.shared.refreshLocal()
    }

    /// One switch for the hub and the library (`Library.bulkEpisodeLookupKey`):
    /// on, the followed shows' ids go to Cinemeta in one request; off, the
    /// library asks TVMaze show by show.
    @MainActor
    static func store(groupedEpisodeLookup enabled: Bool) {
        Library.shared.isBulkEpisodeLookupEnabled = enabled
        HomeState.shared.refreshLocal()
    }

    // MARK: Cache

    /// Bytes in the folders `AppDelegate.aggressivelyFreeDiskSpace()` empties:
    /// the temporary folder (stream partials, remux output, subtitles) and
    /// Caches — but not Caches/Downloads, the offline downloads it keeps (the
    /// row and the "will be freed" figure counted them, and never went down).
    /// Allocated bytes: a stream's file is a hole at the film's full size.
    static func cacheSize() -> Int64 {
        let fm = FileManager.default
        var total = fm.allocatedSize(atPath: NSTemporaryDirectory())
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let entries = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent != AppDelegate.offlineDownloadsFolderName {
                total += fm.allocatedSize(atPath: entry.path)
            }
        }
        return total
    }

    // MARK: Launch

    /// One-time and per-launch fixes of stored preferences (AppDelegate, at launch).
    static func migrateStoredPreferences() {
        normalizeStoredAutoQuality()
        SubtitleSettings.migrateLegacyLanguage()
    }
}
