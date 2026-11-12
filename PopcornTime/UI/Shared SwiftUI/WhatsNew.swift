import Foundation

// "What's new in this version": the release notes and the once-per-version
// rule shared by the tvOS, iOS and macOS apps. Foundation only (no SwiftUI, no
// PopcornKit) so the rule can be unit-tested on its own; the screen itself is
// `WhatsNewView`.
//
// The text is bilingual in code rather than in Localizable.strings: the iOS
// target ships no .strings files (the macOS one ships Localizable.strings
// since 5.1, for its detail pages), and the screen must read the same on all
// three. French is used when the app runs in French (see
// `WhatsNewGate.prefersFrench`).

/// Platforms an item is announced on.
enum WhatsNewPlatform: Hashable {
    case tvOS, iOS, macOS

    /// The platform this binary was built for.
    static var current: WhatsNewPlatform {
        #if os(tvOS)
        return .tvOS
        #elseif os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}

/// One line of the release notes: an SF Symbol, a title and one sentence.
struct WhatsNewItem: Identifiable {
    let id: String
    let symbol: String
    let titleFR: String
    let bodyFR: String
    let titleEN: String
    let bodyEN: String
    let platforms: Set<WhatsNewPlatform>

    func title(french: Bool) -> String { french ? titleFR : titleEN }
    func body(french: Bool) -> String { french ? bodyFR : bodyEN }
}

/// The notes of one release. `version` is the marketing version they describe;
/// it is also the value remembered once the screen has been seen.
struct WhatsNewRelease {
    let version: String
    let items: [WhatsNewItem]

    /// "5.1.0" -> "5.1", "5.1.2" -> "5.1.2": the version as shown in the title.
    var shortVersion: String {
        var parts = version.split(separator: ".").map(String.init)
        while parts.count > 2, parts.last == "0" { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    func items(for platform: WhatsNewPlatform) -> [WhatsNewItem] {
        items.filter { $0.platforms.contains(platform) }
    }

    /// What is new since 5.0.0 (keep the README's release notes in step).
    static let current = WhatsNewRelease(version: "5.1.0", items: [
        WhatsNewItem(id: "liquid-glass", symbol: "sparkles.tv",
                     titleFR: "Nouveau design Liquid Glass sur Apple TV",
                     bodyFR: "Les fiches des films et des séries, épisodes compris, ont été redessinées en verre translucide.",
                     titleEN: "A new Liquid Glass look on Apple TV",
                     bodyEN: "Movie and show pages, episodes included, have been redesigned in translucent Liquid Glass.",
                     platforms: [.tvOS]),
        WhatsNewItem(id: "people", symbol: "person.2.crop.square.stack",
                     titleFR: "Distribution et titres similaires",
                     bodyFR: "Les fiches retrouvent la distribution avec photos, des titres similaires et le logo du titre, sans compte Trakt.",
                     titleEN: "Cast and similar titles",
                     bodyEN: "Pages show the cast with photos, similar titles and the title's logo again, with no Trakt account.",
                     platforms: [.tvOS]),
        WhatsNewItem(id: "settings", symbol: "slider.horizontal.3",
                     titleFR: "Réglages simplifiés",
                     bodyFR: "Une page plus courte avec l'essentiel, et l'app s'affiche désormais en français sur Apple TV.",
                     titleEN: "Simpler Settings",
                     bodyEN: "A shorter page with just the essentials, and the Apple TV app now also speaks French.",
                     platforms: [.tvOS]),
        WhatsNewItem(id: "hdr", symbol: "sparkles.rectangle.stack",
                     titleFR: "Dolby Vision et HDR, sans conversion",
                     bodyFR: "Dolby Vision (profils 5 et 8), HDR10 et HLG sont lus tels qu'ils ont été encodés, sur beaucoup plus de films.",
                     titleEN: "Dolby Vision and HDR, untouched",
                     bodyEN: "Dolby Vision (profiles 5 and 8), HDR10 and HLG play exactly as encoded, on far more films.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "audio", symbol: "hifispeaker.2",
                     titleFR: "Dolby Atmos et toutes les pistes compatibles",
                     bodyFR: "Chaque piste compatible du fichier (langues, Dolby Digital, Atmos, AAC, FLAC…) se choisit dans le lecteur.",
                     titleEN: "Dolby Atmos and every compatible audio track",
                     bodyEN: "Every compatible track in the file (languages, Dolby Digital, Atmos, AAC, FLAC…) can be picked in the player.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "formats", symbol: "film.stack",
                     titleFR: "Bien plus de fichiers lus nativement",
                     bodyFR: "Les fichiers MKV (H.264, HEVC, Dolby Vision) passent par le lecteur d'Apple ; VLC ne prend le relais qu'en dernier recours.",
                     titleEN: "Far more files play natively",
                     bodyEN: "MKV files (H.264, HEVC, Dolby Vision) go through Apple's player; VLC only steps in as a last resort.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "subtitles", symbol: "captions.bubble",
                     titleFR: "Sous-titres intégrés et plus fiables",
                     bodyFR: "Les sous-titres texte du fichier (SRT, ASS, WebVTT) apparaissent dans le lecteur, et un sous-titre lent à télécharger ne retarde jamais le début du film de plus de 15 s environ.",
                     titleEN: "Built-in, more reliable subtitles",
                     bodyEN: "The file's own text subtitles (SRT, ASS, WebVTT) show up in the player, and a slow subtitle download never delays the start by more than about 15 s.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "resume", symbol: "forward.end",
                     titleFR: "Reprise et sauts dans la vidéo plus fiables",
                     bodyFR: "La lecture reprend là où vous l'aviez laissée, et un grand saut en avant ne bloque plus la lecture.",
                     titleEN: "More reliable resume and long jumps",
                     bodyEN: "Playback picks up where you left off, and a long jump ahead no longer gets stuck.",
                     platforms: [.tvOS, .iOS]),
        WhatsNewItem(id: "top100", symbol: "chart.line.uptrend.xyaxis",
                     titleFR: "Le Top 100",
                     bodyFR: "Un nouveau tri pour les films et les séries : les titres les plus partagés du moment sur The Pirate Bay.",
                     titleEN: "The Top 100",
                     bodyEN: "A new sort for movies and shows: the most shared titles of the moment on The Pirate Bay.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "sources", symbol: "magnifyingglass",
                     titleFR: "Plus de sources, une meilleure recherche",
                     bodyFR: "The Pirate Bay et Knaben (1337x, TorrentGalaxy, Nyaa…) ajoutent des torrents vérifiés titre par titre, et la recherche trouve aussi les titres absents des catalogues.",
                     titleEN: "More sources, better search",
                     bodyEN: "The Pirate Bay and Knaben (1337x, TorrentGalaxy, Nyaa…) add torrents checked title by title, and search also finds titles missing from the catalogs.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "picker", symbol: "list.star",
                     titleFR: "Un choix de qualité plus clair",
                     bodyFR: "Chaque source affiche sa qualité, ses seeds et sa taille ; la meilleure est recommandée.",
                     titleEN: "A clearer quality picker",
                     bodyEN: "Each source shows its quality, seeds and size; the best one is recommended.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "episodes", symbol: "list.number",
                     titleFR: "Des épisodes plus fiables",
                     bodyFR: "Les fichiers d'une autre série rangés par erreur sous le même titre sont écartés, ainsi que les saisons fantômes qu'ils ajoutaient.",
                     titleEN: "More reliable episodes",
                     bodyEN: "Files of another show filed under the same title by mistake are left out, along with the seasons they made up.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "mac-app", symbol: "macbook",
                     titleFR: "Une vraie app Mac",
                     bodyFR: "Popcorn Time tourne nativement sur macOS, avec le Dolby Atmos spatialisé sur le Mac et les AirPods.",
                     titleEN: "A real Mac app",
                     bodyEN: "Popcorn Time runs natively on macOS, with Dolby Atmos spatialized on the Mac and AirPods.",
                     platforms: [.macOS]),
        WhatsNewItem(id: "mac-glass", symbol: "macwindow",
                     titleFR: "Fiches Liquid Glass sur Mac",
                     bodyFR: "Les fiches reprennent la mise en page de l'Apple TV : grande image, logo, épisodes, distribution, titres similaires, et « Ma liste » dans la barre latérale.",
                     titleEN: "Liquid Glass pages on the Mac",
                     bodyEN: "Pages take the Apple TV layout: full-size artwork, logo, episodes, cast, similar titles, and a Watchlist in the sidebar.",
                     platforms: [.macOS]),
        WhatsNewItem(id: "detail", symbol: "person.2.crop.square.stack",
                     titleFR: "Des fiches plus riches",
                     bodyFR: "Distribution, note en étoiles et titres similaires sur chaque fiche.",
                     titleEN: "Richer detail pages",
                     bodyEN: "Cast, star rating and related titles on every page.",
                     platforms: [.iOS]),
    ])
}

/// The once-per-version rule, as a pure function of its inputs.
enum WhatsNewPolicy {

    enum Decision: Equatable {
        /// Show the screen, and remember `release.version` as seen.
        case present
        /// Don't show it, but remember `release.version` as seen (fresh install).
        case markSeenSilently
        /// Don't show it and remember nothing (already seen, notes of a later
        /// version seen, URL launch, or notes written for a later version
        /// than this build).
        case skip
    }

    /// - Parameters:
    ///   - appVersion: the running `CFBundleShortVersionString`.
    ///   - notesVersion: the version the notes describe (`WhatsNewRelease.version`).
    ///   - lastSeenVersion: the notes version remembered last time, nil if never.
    ///   - isFreshInstall: first launch of a new install. The notes are not news
    ///     to a new user, so they are marked seen without being shown.
    ///   - launchedFromURL: launched to open a URL (Top Shelf / deep link), which
    ///     goes straight to playback. Nothing is remembered, so the notes show
    ///     on the next normal launch (a fresh install is still marked: its
    ///     next launch must not announce anything).
    static func decide(appVersion: String,
                       notesVersion: String,
                       lastSeenVersion: String?,
                       isFreshInstall: Bool,
                       launchedFromURL: Bool) -> Decision {
        // Never announce notes written for a version this build is not (yet).
        guard appVersion.compare(notesVersion, options: .numeric) != .orderedAscending else { return .skip }
        // Already seen, or notes of a later version seen (a downgrade).
        if let lastSeenVersion,
           lastSeenVersion.compare(notesVersion, options: .numeric) != .orderedAscending { return .skip }
        if isFreshInstall { return .markSeenSilently }
        if launchedFromURL { return .skip }
        return .present
    }

    /// iOS and macOS have no first-launch marker (no Terms of Service gate):
    /// an install is taken as fresh when none of the keys a used app writes
    /// exists yet: settings, watch progress, watched and watchlist entries,
    /// or an earlier "seen" marker.
    ///
    /// Known limit on macOS: before 5.1 the Mac app wrote only changed
    /// settings (it records no progress or watched entries), so a Mac that
    /// never changed a setting is taken as new and does not get the 5.1 notes.
    /// From 5.1 on, `lastWhatsNewVersion` is written at every first launch of
    /// a version, so later notes reach every install.
    static func looksLikeFreshInstall(defaultsKeys: [String]) -> Bool {
        let settingsKeys: Set<String> = [
            WhatsNewGate.lastSeenKey, "tosAccepted", "autoSelectQuality", "streamOnCellular",
            "preferredAudioLanguage", "preferredSubtitleLanguage", "themeSongVolume",
        ]
        let usageSuffixes = ["Progress", "Watchedlist", "Watchlist"]
        return !defaultsKeys.contains { key in
            settingsKeys.contains(key) || usageSuffixes.contains { key.hasSuffix($0) }
        }
    }
}

/// `WhatsNewPolicy` bound to UserDefaults and the main bundle.
enum WhatsNewGate {
    /// UserDefaults key: the notes version last shown (or skipped on a fresh install).
    static let lastSeenKey = "lastWhatsNewVersion"

    #if DEBUG
    /// Launch with `-WhatsNewForce YES` to show the screen on every launch.
    /// Compiled only with DEBUG, which the app targets do not define: build
    /// with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` on the xcodebuild
    /// command line to get it (no test hook ships in a normal build).
    static let forceKey = "WhatsNewForce"
    #endif

    static var release: WhatsNewRelease { .current }

    /// True when the app runs in French. tvOS / macOS: the localization the
    /// app resolved (they ship fr.lproj), so the notes match the rest of the
    /// UI, e.g. French for the languages [German, French] but English for
    /// [Italian, French]. iOS ships no .lproj: the first of the user's
    /// languages that is English or French.
    static var prefersFrench: Bool {
        #if os(tvOS) || os(macOS)
        return Bundle.main.preferredLocalizations.first?.lowercased().hasPrefix("fr") ?? false
        #else
        return Bundle.preferredLocalizations(from: ["en", "fr"], forPreferences: Locale.preferredLanguages).first == "fr"
        #endif
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Applies the rule; when it says so, marks the notes seen. Returns true
    /// when the caller must present the screen now.
    static func checkAtLaunch(isFreshInstall: Bool,
                              launchedFromURL: Bool,
                              defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        if defaults.bool(forKey: forceKey) { return !launchedFromURL }
        #endif
        let decision = WhatsNewPolicy.decide(appVersion: appVersion,
                                             notesVersion: release.version,
                                             lastSeenVersion: defaults.string(forKey: lastSeenKey),
                                             isFreshInstall: isFreshInstall,
                                             launchedFromURL: launchedFromURL)
        switch decision {
        case .present, .markSeenSilently:
            defaults.set(release.version, forKey: lastSeenKey)
        case .skip:
            break
        }
        return decision == .present
    }

    /// Fresh-install test for the iOS and macOS apps (see
    /// `WhatsNewPolicy.looksLikeFreshInstall`), on the keys this app has
    /// persisted (not the global or registered defaults).
    static func looksLikeFreshInstall(defaults: UserDefaults = .standard) -> Bool {
        let persisted = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        return WhatsNewPolicy.looksLikeFreshInstall(defaultsKeys: Array(persisted.keys))
    }
}
