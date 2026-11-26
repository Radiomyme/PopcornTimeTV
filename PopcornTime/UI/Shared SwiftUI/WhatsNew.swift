import Foundation

// "What's new in this version": the release notes and the once-per-version
// rule shared by the tvOS, iOS and macOS apps. Foundation only (no SwiftUI, no
// PopcornKit) so the rule can be unit-tested on its own; the screen itself is
// `WhatsNewView`.
//
// The text is bilingual in code rather than in Localizable.strings: the
// notes are only written in English and French, and the screen must read the
// same on all three apps. French is used when the app runs in French (see
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

    /// The notes shown at launch and from Settings: the latest release's
    /// (keep CHANGELOG.md's section of that version in step).
    static let current = v5_4_0

    /// What is new since 5.3.0. Only what a check saw running is announced
    /// (see CHANGELOG.md's "5.4.0" and its known limits); at most eight
    /// items per platform.
    static let v5_4_0 = WhatsNewRelease(version: "5.4.0", items: [
        WhatsNewItem(id: "profiles-tv", symbol: "person.2.circle",
                     titleFR: "Un profil pour chacun",
                     bodyFR: "Jusqu'à cinq profils, chacun avec sa liste, ses reprises et ses langues.",
                     titleEN: "A profile for everyone",
                     bodyEN: "Up to five profiles, each with its own watchlist, progress and languages.",
                     platforms: [.tvOS]),
        WhatsNewItem(id: "profiles", symbol: "person.2.circle",
                     titleFR: "Un profil pour chacun",
                     bodyFR: "Jusqu'à cinq profils, chacun avec sa liste, ses reprises et ses langues.",
                     titleEN: "A profile for everyone",
                     bodyEN: "Up to five profiles, each with its own watchlist, progress and languages.",
                     platforms: [.iOS]),
        WhatsNewItem(id: "profiles-mac", symbol: "person.2.circle",
                     titleFR: "Un profil pour chacun",
                     bodyFR: "Jusqu'à cinq profils, chacun avec sa liste et ses reprises. Changez de profil avec ⇧⌘P.",
                     titleEN: "A profile for everyone",
                     bodyEN: "Up to five profiles, each with its own watchlist and progress. Switch with ⇧⌘P.",
                     platforms: [.macOS]),
        WhatsNewItem(id: "for-you", symbol: "sparkles",
                     titleFR: "Pour vous",
                     bodyFR: "Des suggestions sur l'Accueil, selon ce que vous regardez.",
                     titleEN: "For You",
                     bodyEN: "Suggestions on Home, based on what you watch.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "automatic-language", symbol: "captions.bubble",
                     titleFR: "Langues automatiques",
                     bodyFR: "L'audio et les sous-titres suivent les langues que vous choisissez le plus.",
                     titleEN: "Automatic languages",
                     bodyEN: "Audio and subtitles follow the languages you pick most.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "source", symbol: "character.bubble",
                     titleFR: "Ça démarre plus vite",
                     bodyFR: "De meilleures sources, et les versions dans votre langue en premier.",
                     titleEN: "Faster starts",
                     bodyEN: "Better sources, with releases in your language first.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "services", symbol: "play.tv",
                     titleFR: "Vos services de streaming",
                     bodyFR: "Voyez ce que proposent Netflix, Prime Video ou Disney+, avec une clé TMDB gratuite.",
                     titleEN: "Your streaming services",
                     bodyEN: "See what's on Netflix, Prime Video or Disney+, with a free TMDB key.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "search-tv", symbol: "magnifyingglass",
                     titleFR: "Une seule recherche",
                     bodyFR: "Films et séries s'affichent ensemble.",
                     titleEN: "One search",
                     bodyEN: "Movies and shows, together.",
                     platforms: [.tvOS]),
        WhatsNewItem(id: "downloads-tv", symbol: "arrow.down.circle",
                     titleFR: "Téléchargements",
                     bodyFR: "La progression en un coup d'œil, et la pause ou la suppression d'un simple appui.",
                     titleEN: "Downloads",
                     bodyEN: "Progress at a glance, and pause or delete with one press.",
                     platforms: [.tvOS]),
        WhatsNewItem(id: "player-lists-tv", symbol: "list.bullet",
                     titleFR: "Un lecteur plus fluide",
                     bodyFR: "Les listes de sous-titres et d'audio défilent sans accroc.",
                     titleEN: "A smoother player",
                     bodyEN: "Subtitle and audio lists scroll smoothly.",
                     platforms: [.tvOS]),
    ])

    /// What was new in 5.3.0 (since 5.2.0), kept for the record.
    static let v5_3_0 = WhatsNewRelease(version: "5.3.0", items: [
        WhatsNewItem(id: "home", symbol: "house",
                     titleFR: "Un nouvel écran d'accueil",
                     bodyFR: "L'app s'ouvre sur Accueil : les sorties à la une en grand, puis Reprendre, les nouveaux épisodes de vos séries, les films et séries du moment, les nouveautés 4K, le Top 100 des films et celui des séries, Ma liste et vos genres. Réglages › Accueil choisit les langues et les rangées.",
                     titleEN: "A new Home screen",
                     bodyEN: "The app opens on Home: the featured releases up top, then Continue Watching, new episodes of your shows, trending movies and shows, new in 4K, the Top 100 movies and shows, your Watchlist and your genres. Settings › Home picks the languages and the rows.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "resume-tv", symbol: "play.circle",
                     titleFR: "Reprendre là où vous vous étiez arrêté",
                     bodyFR: "Un film encore en téléchargement reprend à l'endroit enregistré, et les retours en arrière comme les sauts lointains restent dans le lecteur natif, qui reçoit tels quels le Dolby Vision et le Dolby Atmos du fichier. Pendant l'attente, l'écran dit où en est le téléchargement : « Reprise à 22:35 — 45 % · 9,6 Mo/s ».",
                     titleEN: "Resume where you left off",
                     bodyEN: "A film that is still downloading resumes at its saved point, and rewinds and far jumps stay in the native player too, which gets the file's Dolby Vision and Dolby Atmos untouched. While it waits, the screen says how far the download has got: “Resuming at 22:35 — 45% · 9.6 MB/s”.",
                     platforms: [.tvOS]),
        // iPhone / iPad and Mac: the resume was run there; the far jumps and
        // rewinds of the merged tree were not, so they are not announced.
        WhatsNewItem(id: "resume", symbol: "play.circle",
                     titleFR: "Reprendre là où vous vous étiez arrêté",
                     bodyFR: "Un film encore en téléchargement reprend à l'endroit enregistré, sans quitter le lecteur natif : le torrent télécharge d'abord ce passage.",
                     titleEN: "Resume where you left off",
                     bodyEN: "A film that is still downloading resumes at its saved point, without leaving the native player: the torrent fetches that part first.",
                     platforms: [.iOS, .macOS]),
        WhatsNewItem(id: "up-next-tv", symbol: "forward.end",
                     titleFR: "Les épisodes s'enchaînent",
                     bodyFR: "60 s avant la fin (Réglages › Carte Épisode suivant : de 30 à 90 s), la carte « Épisode suivant » propose la suite. Elle démarre tout de suite avec « Lire maintenant », sinon à la fin de l'épisode si « Enchaîner les épisodes » est activé. La suite est prise dans une version proche (le même pack d'abord, sinon le même groupe ou la même qualité), sans redemander la qualité. « Reprendre » relance la version déjà regardée, sans question.",
                     titleEN: "Episodes play on",
                     bodyEN: "60 s before the end (Settings › Next Episode Card: 30 to 90 s), the Next Episode card offers the next one. It starts at once with Play Now, otherwise at the end of the episode when Autoplay Next Episode is on. The next one comes from a matching release (the same pack first, else the same group or quality), without asking for the quality again. Resume replays the release you were watching, with no question.",
                     platforms: [.tvOS]),
        // iPhone / iPad and Mac: the card at 60 s was not seen running there
        // (only its setting, on screen), so its time is not announced.
        WhatsNewItem(id: "up-next", symbol: "forward.end",
                     titleFR: "Les épisodes s'enchaînent",
                     bodyFR: "Avant la fin, la carte « Épisode suivant » propose la suite. Elle démarre tout de suite avec « Lire maintenant », sinon à la fin de l'épisode si « Enchaîner les épisodes » est activé. La suite est prise dans une version proche (le même pack d'abord, sinon le même groupe ou la même qualité), sans redemander la qualité. « Reprendre » relance la version déjà regardée, sans question.",
                     titleEN: "Episodes play on",
                     bodyEN: "Before the end, the Next Episode card offers the next one. It starts at once with Play Now, otherwise at the end of the episode when Autoplay Next Episode is on. The next one comes from a matching release (the same pack first, else the same group or quality), without asking for the quality again. Resume replays the release you were watching, with no question.",
                     platforms: [.iOS, .macOS]),
        WhatsNewItem(id: "detail", symbol: "bolt",
                     titleFR: "Des fiches qui s'ouvrent tout de suite",
                     bodyFR: "Une fiche montre aussitôt ce que l'affiche connaissait, puis se complète ; les sources arrivent une à une.",
                     titleEN: "Pages that open at once",
                     bodyEN: "A page shows straight away what its poster knew, then fills in; sources arrive one by one.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "grids", symbol: "square.grid.3x3",
                     titleFR: "Des grilles qui trient vraiment",
                     bodyFR: "Chaque tri donne sa propre liste, chaque catalogue ses propres genres, et la première page s'affiche dès le lancement depuis la dernière visite. Une page qui échoue propose Réessayer au lieu d'arrêter la liste.",
                     titleEN: "Grids that really sort",
                     bodyEN: "Each sort gives its own list, each catalog its own genres, and the first page shows at launch from your last visit. A page that fails offers Try Again instead of ending the list.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "artwork", symbol: "photo.on.rectangle",
                     titleFR: "Des images plus légères",
                     bodyFR: "Les affiches sont demandées à la taille où elles sont dessinées (jusqu'à 96 % de données en moins), et celles des vieux films ne restent plus grises.",
                     titleEN: "Lighter artwork",
                     bodyEN: "Posters are fetched at the size they're drawn (up to 96% less data), and old movies' posters no longer stay grey.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "tv-grids", symbol: "rectangle.grid.3x2",
                     titleFR: "Des grilles plus riches sur Apple TV",
                     bodyFR: "Six affiches par rangée, le tri et le genre affichés, des marques 4K, Nouveau, Nouvel épisode, vu et progression ; sous chaque affiche son année, sa note et ses formats, et sous l'affiche choisie son titre.",
                     titleEN: "Richer grids on Apple TV",
                     bodyEN: "Six posters per row, the sort and genre shown, 4K, New, New Episode, watched and progress marks; under every poster its year, rating and formats, and under the focused one its title.",
                     platforms: [.tvOS]),
        WhatsNewItem(id: "topshelf", symbol: "tv",
                     titleFR: "Le Top Shelf",
                     bodyFR: "Placez Popcorn Time dans la rangée du haut : l'écran d'accueil de l'Apple TV montre les dernières sorties en plein écran, avec de quoi lire un titre ou ouvrir sa fiche.",
                     titleEN: "The Top Shelf",
                     bodyEN: "Put Popcorn Time in the top row: the Apple TV home screen shows the latest releases full screen, ready to play a title or open its page.",
                     platforms: [.tvOS]),
        WhatsNewItem(id: "mac", symbol: "macwindow",
                     titleFR: "Un Mac plus complet",
                     bodyFR: "L'Accueil en tête de la barre latérale (⌘1), les menus Aller et Lecture, et ⌘R pour actualiser la page.",
                     titleEN: "A fuller Mac app",
                     bodyEN: "Home at the top of the sidebar (⌘1), the Go and Playback menus, and ⌘R to refresh the page.",
                     platforms: [.macOS]),
    ])

    /// What was new in 5.2.0 (since 5.1.0), kept for the record.
    static let v5_2_0 = WhatsNewRelease(version: "5.2.0", items: [
        WhatsNewItem(id: "bitrate", symbol: "speedometer",
                     titleFR: "Une qualité adaptée à votre connexion",
                     bodyFR: "La version recommandée tient compte du débit de chaque fichier et de la vitesse réelle de vos téléchargements ; le choix de qualité affiche ce débit et signale les versions qui risquent de saccader.",
                     titleEN: "Quality that suits your connection",
                     bodyEN: "The recommended release weighs each file's bitrate against the speed your downloads actually reach; the quality picker shows that bitrate and flags releases that may stutter.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "loading", symbol: "hourglass",
                     titleFR: "Un chargement qui dit ce qu'il fait",
                     bodyFR: "L'écran de chargement indique s'il cherche des pairs, récupère les informations du torrent ou met la vidéo en mémoire tampon, avec le temps restant ; une source qui ne répond pas est signalée, et vous pouvez en choisir une autre.",
                     titleEN: "Loading that says what it's doing",
                     bodyEN: "The loading screen says whether it is looking for peers, fetching the torrent's details or buffering, with the time left; a source that doesn't respond is flagged, and you can pick another one.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "lighter", symbol: "arrow.triangle.2.circlepath",
                     titleFR: "Une version plus légère si la lecture saccade",
                     bodyFR: "Quand le téléchargement ne suit pas le débit de la vidéo, l'app propose une version plus légère et bien partagée, qui reprend au même endroit.",
                     titleEN: "A lighter version when playback can't keep up",
                     bodyEN: "When the download can't keep up with the video's bitrate, the app offers a lighter, well-seeded version that resumes at the same point.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "packs", symbol: "rectangle.stack",
                     titleFR: "Le bon épisode dans les packs de saison",
                     bodyFR: "Dans un torrent qui contient toute une saison, l'app retrouve l'épisode choisi par son nom ou son numéro ; s'il n'y figure pas, elle le dit au lieu de lancer un autre épisode.",
                     titleEN: "The right episode from season packs",
                     bodyEN: "When a torrent holds a whole season, the app finds the episode you picked by its name or number; if it isn't there, it says so instead of playing another episode.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "network", symbol: "arrow.down.circle",
                     titleFR: "Des téléchargements plus rapides",
                     bodyFR: "Le moteur torrent ne bride plus les téléchargements : plus de pairs à la fois, tous les trackers interrogés, et un pair lent ne retient plus la lecture. La vidéo peut démarrer plus tôt, et le téléchargement profiter davantage de votre connexion.",
                     titleEN: "Faster downloads",
                     bodyEN: "The torrent engine no longer holds downloads back: more peers at once, every tracker asked, and a slow peer no longer holds playback back. Videos can start sooner, and downloads can make more of your connection.",
                     platforms: [.tvOS, .iOS, .macOS]),
        WhatsNewItem(id: "tv-navigation", symbol: "appletvremote.gen4",
                     titleFR: "Une navigation plus fluide sur Apple TV",
                     bodyFR: "Le bouton Retour de la télécommande ramène à l'écran précédent, y compris pendant un chargement ou la recherche des sources, et le Top 100 comme les autres grilles réapparaissent sans à-coup, sur l'affiche que vous aviez quittée. Lecture/Pause lance un titre depuis son affiche, et un appui long ouvre ses raccourcis.",
                     titleEN: "Smoother navigation on Apple TV",
                     bodyEN: "The remote's Back button takes you to the previous screen, also while something loads or sources are being searched, and the Top 100 and the other grids come back without a jolt, on the poster you left. Play/Pause starts a title from its poster, and a long press opens its shortcuts.",
                     platforms: [.tvOS]),
    ])

    /// What was new in 5.1.0 (since 5.0.0), kept for the record.
    static let v5_1_0 = WhatsNewRelease(version: "5.1.0", items: [
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
        // Not announced on iOS yet: the code ships there too, but the iOS app
        // has never run it (tried on an Apple TV and in the Mac app).
        WhatsNewItem(id: "storage", symbol: "internaldrive",
                     titleFR: "Des films plus gros que l'espace libre",
                     bodyFR: "Un film qui ne tient pas dans l'espace libre se lit quand même : seule la partie autour de la lecture reste sur l'appareil, et le retour en arrière s'arrête à ce qui est encore stocké.",
                     titleEN: "Films larger than the free space",
                     bodyEN: "A film that doesn't fit in the free space plays anyway: only the part around the playhead stays on the device, and rewinds stop at what is still stored.",
                     platforms: [.tvOS, .macOS]),
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

    /// True when the app runs in French: the localization the app resolved
    /// (the three apps ship fr.lproj; iOS since 5.3, with it, es, ar and
    /// pt-BR), so the notes match the rest of the UI, e.g. French for the
    /// languages [German, French] but English for [Italian, French].
    static var prefersFrench: Bool {
        return Bundle.main.preferredLocalizations.first?.lowercased().hasPrefix("fr") ?? false
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Applies the rule; when it says so, marks the notes seen. Returns true
    /// when the caller must present the screen now. `appVersion` and
    /// `release`: the running app's and its notes (the tests give theirs).
    static func checkAtLaunch(isFreshInstall: Bool,
                              launchedFromURL: Bool,
                              defaults: UserDefaults = .standard,
                              appVersion: String = WhatsNewGate.appVersion,
                              release: WhatsNewRelease = WhatsNewGate.release) -> Bool {
        #if DEBUG
        if defaults.bool(forKey: forceKey) { return !launchedFromURL }
        #endif
        let decision = WhatsNewPolicy.decide(appVersion: appVersion,
                                             notesVersion: release.version,
                                             lastSeenVersion: defaults.string(forKey: lastSeenKey),
                                             isFreshInstall: isFreshInstall,
                                             launchedFromURL: launchedFromURL)
        // Once per launch (`WhatsNewLaunchCheck`, `WhatsNewPresenter`), in every build: a device
        // session's console tells whether the notes came up.
        let said: String
        switch decision {
        case .present: said = "present"
        case .markSeenSilently: said = "marked seen silently"
        case .skip: said = "skip"
        }
        print("[WhatsNew] \(said) — last seen \(defaults.string(forKey: lastSeenKey) ?? "none"), notes \(release.version), "
              + "app \(appVersion)\(isFreshInstall ? ", fresh install" : "")\(launchedFromURL ? ", launched from a link" : "")")
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
    /// persisted (not the global or registered defaults): the persistent
    /// domain `domainName` (the app's bundle identifier; the tests give a
    /// suite's name).
    static func looksLikeFreshInstall(defaults: UserDefaults = .standard,
                                      domainName: String? = Bundle.main.bundleIdentifier) -> Bool {
        let persisted = domainName.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        return WhatsNewPolicy.looksLikeFreshInstall(defaultsKeys: Array(persisted.keys))
    }
}

/// The launch check of the SwiftUI apps (iOS, macOS). They learn that a
/// popcorntime:// link opened them only through `onOpenURL`, which SwiftUI
/// may call before or just after the root view's `.task` runs the check:
/// - the link first: the check sees it (`launchedFromURL`): nothing shown,
///   nothing remembered;
/// - the check first, the notes shown, then the link within
///   `linkWindowSeconds`: the notes are closed and forgotten (the version
///   seen before is put back), as if the check had seen the link — the
///   next normal launch shows them.
/// A link later than that is an ordinary one: the notes stay as they are.
/// Pure state; the view keeps it in `@State`.
struct WhatsNewLaunchCheck {
    /// How long after the notes were shown a link still counts as the one
    /// that launched the app.
    static let linkWindowSeconds: TimeInterval = 5

    private(set) var linkArrived = false
    private(set) var checked = false
    /// When the notes were shown at this launch, and the version seen
    /// before (nil: none) — what a late link puts back.
    private var shownAt: TimeInterval?
    private var seenBefore: String?

    /// `.task`: applies the rule (`WhatsNewGate.checkAtLaunch`) once; true
    /// when the notes must be shown now. `now`: a monotonic clock (s).
    mutating func check(isFreshInstall: Bool,
                        defaults: UserDefaults = .standard,
                        appVersion: String = WhatsNewGate.appVersion,
                        release: WhatsNewRelease = WhatsNewGate.release,
                        now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !checked else { return false }
        checked = true
        let before = defaults.string(forKey: WhatsNewGate.lastSeenKey)
        let present = WhatsNewGate.checkAtLaunch(isFreshInstall: isFreshInstall, launchedFromURL: linkArrived,
                                                 defaults: defaults, appVersion: appVersion, release: release)
        if present {
            shownAt = now
            seenBefore = before
        }
        return present
    }

    /// `onOpenURL`: a link arrived. True when the notes this launch showed
    /// must be closed now (they are forgotten in `defaults`).
    mutating func linkOpened(defaults: UserDefaults = .standard,
                             now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        linkArrived = true
        guard let shown = shownAt else { return false }
        shownAt = nil
        guard now - shown <= Self.linkWindowSeconds else { return false }
        if let seenBefore {
            defaults.set(seenBefore, forKey: WhatsNewGate.lastSeenKey)
        } else {
            defaults.removeObject(forKey: WhatsNewGate.lastSeenKey)
        }
        return true
    }
}
