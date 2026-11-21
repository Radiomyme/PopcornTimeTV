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
            setAudioLanguage: { GlassSettingsStore.store(languageCode: $0, forKey: PlaybackLanguagePreferences.audioLanguageDefaultsKey) },
            setSubtitleLanguage: { GlassSettingsStore.store(languageCode: $0, forKey: PlaybackLanguagePreferences.subtitleLanguageDefaultsKey) },
            setThemeSongs: { GlassSettingsStore.themeSongs = $0 },
            readThemeSongs: { GlassSettingsStore.themeSongs },
            setAutoPlayNext: { UpNextPreferences.autoPlayNext = $0 },
            readAutoPlayNext: { UpNextPreferences.autoPlayNext },
            setUpNextCardLead: { UpNextPreferences.cardLeadSeconds = $0 },
            readUpNextCardLead: { UpNextPreferences.cardLeadSeconds },
            upNextCardLeadChoices: UpNextCountdown.cardLeadChoices,
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
            setStreamingRegion: { GlassSettingsStore.store(streamingRegion: $0) },
            setStreamingServices: { GlassSettingsStore.store(streamingServices: $0) },
            loadStreamingServices: { GlassSettingsStore.streamingServices(region: $0, completion: $1) },
            loadStreamingRegions: { GlassSettingsStore.streamingRegions(completion: $0) },
            regionName: { GlassSettingsStore.regionName($0) })

        let audio = PlaybackLanguagePreferences.preferredAudioLanguageCode
        let subtitles = PlaybackLanguagePreferences.preferredSubtitleLanguageCode
        model = GlassSettingsModel(autoQuality: GlassSettingsStore.autoQuality,
                                   audioLanguage: audio,
                                   subtitleLanguage: subtitles,
                                   themeSongs: GlassSettingsStore.themeSongs,
                                   version: Bundle.main.displayVersion,
                                   languages: GlassSettingsStore.languages(including: [audio, subtitles]),
                                   actions: actions)
        #if DEBUG
        // `-PTDebugSettingsRow <row>` (homeLanguages, homeShelves, homeLookup,
        // tmdbKey, streamingRegion, streamingServices…):
        // the row that takes the focus; `-PTDebugSettingsPicker <picker>`
        // (homeLanguages, homeShelves…): the sheet open at first display.
        let row: GlassSettingsRowID
        switch UserDefaults.standard.string(forKey: "PTDebugSettingsRow") {
        case "homeLanguages": row = .homeLanguages
        case "homeShelves": row = .homeShelves
        case "homeLookup": row = .homeLookup
        case "autoPlayNext": row = .autoPlayNext
        case "upNextCard": row = .upNextCard
        case "tmdbKey": row = .tmdbKey
        case "streamingRegion": row = .streamingRegion
        case "streamingServices": row = .streamingServices
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
    /// stored value to the *localized* title ("Highest".localized), so that is
    /// what is stored; nil means Off (always ask).
    static var autoQuality: GlassSettingsAutoQuality {
        autoQuality(fromStored: defaults.string(forKey: autoQualityKey))
    }

    static func store(autoQuality: GlassSettingsAutoQuality) {
        defaults.set(autoQuality == .off ? nil : autoQuality.titleKey.localized, forKey: autoQualityKey)
    }

    /// Recognizes a stored value written in any language the app ships (or
    /// the raw English key), so a change of UI language keeps the setting.
    static func autoQuality(fromStored value: String?) -> GlassSettingsAutoQuality {
        guard let value, !value.isEmpty else { return .off }
        return GlassSettingsAutoQuality.allCases.first { spellings(of: $0.titleKey).contains(value) } ?? .off
    }

    /// Launch: rewrites a value stored under another UI language (e.g. English
    /// "Highest" before the app had a French localization) in the current one,
    /// so the quality chooser still matches it.
    static func normalizeStoredAutoQuality() {
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

    /// Stored as the language name in the current UI language ("Français"),
    /// the convention of the iOS / macOS settings; nil removes the preference.
    static func store(languageCode code: String?, forKey key: String) {
        defaults.set(code.map(PlaybackLanguagePreferences.storedName(forCode:)), forKey: key)
    }

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
        var shelves = HomeShelfID.order.filter { $0 != HomeShelfID.hero }
        // The « Services » row, under Continue Watching, once there is a key.
        if settings.tmdbAPIKey != nil {
            shelves.insert(HomeShelfID.services, at: min(1, shelves.count))
        }
        let genres = HomeState.shared.shelves.map(\.id).filter { HomeShelfID.genre(of: $0) != nil }
            + hidden.filter { HomeShelfID.genre(of: $0) != nil }.sorted()
        for id in genres where !shelves.contains(id) { shelves.append(id) }
        return GlassSettingsHome(languages: languages,
                                 hiddenShelves: hidden,
                                 groupedEpisodeLookup: Library.shared.isBulkEpisodeLookupEnabled,
                                 languageChoices: languageChoices,
                                 shelfChoices: shelves.map { GlassSettingsChoice(id: $0, title: text.title(ofShelf: $0)) },
                                 hasTMDBKey: settings.tmdbAPIKey != nil,
                                 isTMDBKeyRefused: TMDBStreamingClient.shared.isKeyRefused,
                                 streamingRegion: settings.streamingRegion,
                                 streamingServices: settings.streamingServices.map { GlassSettingsChoice(id: String($0.id), title: $0.name) })
    }

    // MARK: Streaming services ("popcornkit.tmdb.apiKey", "popcornkit.home.streamingRegion", "popcornkit.home.streamingServices")

    /// Checks the key with TMDB; keeps it unless TMDB refused it. nil
    /// removes the key (the streaming shelves go). The Home then asks the
    /// lists it now reads, or drops the shelves it no longer has.
    @MainActor
    static func store(tmdbKey key: String?, completion: @escaping (Bool?) -> Void) {
        let settings = HomeSettings(defaults: defaults)
        guard let key else {
            settings.tmdbAPIKey = nil
            HomeState.shared.refreshLocal()
            return completion(nil)
        }
        TMDBStreamingClient.shared.check(key: key) { verdict in
            DispatchQueue.main.async {
                if verdict != false {
                    settings.tmdbAPIKey = key
                    HomeState.shared.refreshLocal()
                    // The services' logos, for the Home's « Services » row.
                    streamingServices(region: settings.streamingRegion) { _ in }
                }
                completion(verdict)
            }
        }
    }

    /// The chosen services then follow the country as soon as TMDB lists
    /// its services (`streamingServices(region:)`), picker open or not.
    @MainActor
    static func store(streamingRegion code: String) {
        let settings = HomeSettings(defaults: defaults)
        settings.streamingRegion = code
        HomeState.shared.refreshLocal()
        streamingServices(region: settings.streamingRegion) { _ in }
    }

    /// The services TMDB listed last (their logos), by id.
    @MainActor private static var knownServices: [Int: StreamingService] = [:]

    @MainActor
    static func store(streamingServices choices: [GlassSettingsChoice]) {
        let settings = HomeSettings(defaults: defaults)
        let stored = Dictionary(settings.streamingServices.map { ($0.id, $0) }) { first, _ in first }
        settings.streamingServices = choices.compactMap { choice in
            guard let id = Int(choice.id) else { return nil }
            return knownServices[id] ?? stored[id] ?? StreamingService(id: id, name: choice.title)
        }
        HomeState.shared.refreshLocal()
    }

    /// Also matches the chosen services to the country's (TMDB's logos and
    /// names, the country's id of a service — Amazon Prime Video is 119 in
    /// France, 9 in the United States —, and none the country lacks:
    /// `StreamingService.matching`). Only for the country chosen now: an
    /// answer for a country left meanwhile changes nothing.
    @MainActor
    static func streamingServices(region: String, completion: @escaping ([GlassSettingsChoice]?) -> Void) {
        TMDBStreamingClient.shared.services(region: region) { services in
            DispatchQueue.main.async {
                guard let services else { return completion(nil) }
                for service in services { knownServices[service.id] = service }
                if HomeSettings(defaults: defaults).adoptServices(services, listedFor: region) {
                    HomeState.shared.refreshLocal()
                }
                completion(services.map { GlassSettingsChoice(id: String($0.id), title: $0.name) })
            }
        }
    }

    /// TMDB's countries, else every country the system knows; by name.
    static func streamingRegions(completion: @escaping ([GlassSettingsChoice]) -> Void) {
        TMDBStreamingClient.shared.regions { codes in
            let all = (codes?.isEmpty == false ? codes! : Locale.Region.isoRegions.map(\.identifier))
                .filter { $0.count == 2 }
            let choices = Set(all).map { GlassSettingsChoice(id: $0, title: regionName($0)) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            DispatchQueue.main.async { completion(choices) }
        }
    }

    static func regionName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
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
