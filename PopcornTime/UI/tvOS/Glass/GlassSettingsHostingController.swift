// GlassSettingsHostingController.swift — puts `GlassSettingsView` in the
// Settings tab and connects it to the app's preferences (UserDefaults, Trakt,
// cache, What's New). The view itself knows nothing of the app.

import UIKit
import SwiftUI
import PopcornKit
import PopcornTorrent.PTTorrentDownloadManager

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
            measureCache: { GlassSettingsStore.cacheSize() },
            clearCache: { AppDelegate.aggressivelyFreeDiskSpace() },
            hasActiveDownloads: { !PTTorrentDownloadManager.shared().activeDownloads.isEmpty },
            isTraktSignedIn: { TraktManager.shared.isSignedIn() },
            signOutOfTrakt: { try? TraktManager.shared.logout() },
            showWhatsNew: {
                guard let root = AppDelegate.shared.window?.rootViewController else { return }
                WhatsNewPresenter.present(from: root)
            })

        let audio = PlaybackLanguagePreferences.preferredAudioLanguageCode
        let subtitles = PlaybackLanguagePreferences.preferredSubtitleLanguageCode
        model = GlassSettingsModel(autoQuality: GlassSettingsStore.autoQuality,
                                   audioLanguage: audio,
                                   subtitleLanguage: subtitles,
                                   themeSongs: GlassSettingsStore.themeSongs,
                                   version: Bundle.main.displayVersion,
                                   languages: GlassSettingsStore.languages(including: [audio, subtitles]),
                                   actions: actions)
        super.init(rootView: GlassSettingsView(model: model))
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

    // MARK: Cache

    /// Bytes in the folders `AppDelegate.aggressivelyFreeDiskSpace()` empties:
    /// the temporary folder (stream partials, remux output, subtitles) and Caches.
    static func cacheSize() -> Int64 {
        let fm = FileManager.default
        var total = fm.folderSize(atPath: NSTemporaryDirectory())
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            total += fm.folderSize(atPath: caches.path)
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
