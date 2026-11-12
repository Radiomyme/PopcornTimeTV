// GlassDetailModel.swift — the data and the callbacks behind GlassDetailView,
// the Liquid Glass movie / show page of the tvOS app.
//
// Everything here is a plain value or a closure: no PopcornKit, no pods and no
// app classes, so the views also compile on their own with mock data (a
// screenshot harness kept outside the repo). The integrator fills a `GlassDetailModel` from Movie /
// Show / Episode and wires `GlassDetailActions` to the existing app code.
//
// Strings in the model are shown as they are (Text(verbatim:)): pass them
// already localized and formatted. The views localize only their own chrome
// ("Play", "Trailer", section titles…) through Localizable.strings.
import SwiftUI
import Observation

/// What the page is about. Shows get the season pills and the episode shelf.
enum GlassMediaKind: Equatable {
    case movie
    case show
}

/// State of a download control (the movie's Download button or one episode).
enum GlassDownloadState: Equatable {
    case idle
    /// Queued, waiting for metadata / peers. Drawn as a spinning ring.
    case pending
    /// 0…1.
    case downloading(progress: Double)
    /// 0…1.
    case paused(progress: Double)
    case downloaded

    var progress: Double? {
        switch self {
        case .downloading(let p), .paused(let p): return min(max(p, 0), 1)
        default: return nil
        }
    }
}

/// Content of the Play button. `nil` in the model hides the button.
struct GlassPlayInfo: Equatable {
    /// Shows: the episode Play starts ("Play  S2 · E5"). Nil for movies.
    var season: Int? = nil
    var episode: Int? = nil
    /// 0…1 when the movie / episode was partly watched: drawn as a thin bar
    /// under the label. The player itself still asks "Resume / Start Over".
    var progress: Double? = nil
}

/// A capability chip under the metadata line ("4K", "Dolby Vision", "Atmos"…).
/// Only pass what the torrents really offer.
struct GlassBadge: Identifiable, Equatable {
    var id: String { text }
    let text: String
    /// Optional SF Symbol drawn before the text.
    var systemImage: String? = nil
}

struct GlassEpisode: Identifiable, Equatable {
    /// Any stable id (the integrator's key to find the Episode back).
    let id: String
    let season: Int
    let number: Int
    let title: String
    let summary: String
    /// 16:9 still. Nil draws a placeholder with the episode number.
    let stillURL: URL?
    /// Short secondary line, already formatted: "42 min" or "12 Mar 2024".
    let detail: String?
    var isWatched: Bool = false
    /// 0…1, partly watched. 0 or nil = no bar.
    var progress: Double? = nil
    /// Nil hides every download affordance for this episode.
    var download: GlassDownloadState? = nil
}

struct GlassRelatedItem: Identifiable, Equatable {
    let id: String
    let title: String
    /// Usually the year.
    let subtitle: String?
    /// 2:3 poster.
    let posterURL: URL?
}

struct GlassPerson: Identifiable, Equatable {
    let id: String
    let name: String
    /// Character name for actors, job for crew.
    let role: String?
    /// Square-ish headshot; nil draws a monogram.
    let imageURL: URL?

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

/// One key / value line of the Information and Accessibility cards.
struct GlassInfoRow: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let value: String
}

/// Text shown full screen by the glass text sheet (the old "…More" page).
struct GlassExpandedText: Equatable {
    let title: String
    /// Optional line under the title (episode code, air date…).
    var subtitle: String? = nil
    let body: String
}

/// Every focusable place of the page. Used for the initial focus, for focus
/// requests (`GlassDetailModel.focusRequest`) and reported back through
/// `GlassDetailActions.focusChanged`.
enum GlassFocusTarget: Hashable {
    case play, trailer, watchlist, watched, download, summary
    case season(Int)
    case episode(String)
    case episodeSummary
    case related(String)
    case person(String)
    case information, accessibility

    /// True for the controls of the first screen (hero).
    var isHero: Bool {
        switch self {
        case .play, .trailer, .watchlist, .watched, .download, .summary: return true
        default: return false
        }
    }
}

/// The page's state. Fill it on the main thread; sections can arrive one by
/// one (set the matching `isLoading…` flag while they load: the section then
/// shows placeholders, and it disappears when it ends up empty).
@Observable
final class GlassDetailModel {
    var kind: GlassMediaKind
    var title: String
    /// Fanart.tv logo (transparent PNG). Nil, or a failed load, shows `title`.
    var logoURL: URL?
    /// Landscape artwork filling the screen. A portrait image here (TVMaze
    /// shows) or nil switches to the "ambient" look: blurred poster behind,
    /// crisp poster card in the hero.
    var backdropURL: URL?
    /// Landscape artwork tried when `backdropURL` gives none (a movie's small
    /// YTS background behind metahub's 1920 px one).
    var backdropFallbackURL: URL?
    /// 2:3 poster, used for the ambient look and the poster card.
    var posterURL: URL?
    /// Joined with " · ": movie ["2026", "2 h 18 min", "Science Fiction, Adventure"],
    /// show ["3 Seasons", "HBO", "2019 – 2023"].
    var metadata: [String]
    /// "PG-13", drawn as an outlined badge after the metadata line.
    var certification: String?
    /// 0…5 stars in halves (API rating / 20). Nil hides the stars.
    var rating: Double?
    var badges: [GlassBadge]
    var summary: String

    /// Nil hides Play (shows with nothing to continue).
    var play: GlassPlayInfo?
    var hasTrailer: Bool
    var isInWatchlist: Bool
    /// Nil hides the Watched toggle (shows have no watched state).
    var isWatched: Bool?
    /// Nil hides the Download button (shows: downloads are per episode).
    var download: GlassDownloadState?

    /// Shows: season numbers in display order.
    var seasons: [Int]
    /// The season whose episodes the shelf shows. The view sets it when a
    /// season pill is pressed (then calls `GlassDetailActions.selectSeason`).
    var selectedSeason: Int?
    /// Every episode of every season; the shelf filters on `selectedSeason`.
    var episodes: [GlassEpisode]
    /// Episode the shelf scrolls to first (the next one to watch).
    var upNextEpisodeID: String?

    var related: [GlassRelatedItem]
    var people: [GlassPerson]
    var information: [GlassInfoRow]
    var accessibility: [GlassInfoRow]

    var isLoadingEpisodes = false
    var isLoadingRelated = false
    var isLoadingPeople = false

    /// Non-nil presents the glass text sheet. The view sets it from the
    /// summary cards and clears it when the sheet closes.
    var expandedText: GlassExpandedText?
    /// Set to move focus programmatically (e.g. back to the episode that was
    /// playing). The view consumes it and resets it to nil.
    var focusRequest: GlassFocusTarget?

    init(kind: GlassMediaKind,
         title: String,
         logoURL: URL? = nil,
         backdropURL: URL? = nil,
         backdropFallbackURL: URL? = nil,
         posterURL: URL? = nil,
         metadata: [String] = [],
         certification: String? = nil,
         rating: Double? = nil,
         badges: [GlassBadge] = [],
         summary: String = "",
         play: GlassPlayInfo? = GlassPlayInfo(),
         hasTrailer: Bool = false,
         isInWatchlist: Bool = false,
         isWatched: Bool? = nil,
         download: GlassDownloadState? = nil,
         seasons: [Int] = [],
         selectedSeason: Int? = nil,
         episodes: [GlassEpisode] = [],
         upNextEpisodeID: String? = nil,
         related: [GlassRelatedItem] = [],
         people: [GlassPerson] = [],
         information: [GlassInfoRow] = [],
         accessibility: [GlassInfoRow] = []) {
        self.kind = kind
        self.title = title
        self.logoURL = logoURL
        self.backdropURL = backdropURL
        self.backdropFallbackURL = backdropFallbackURL
        self.posterURL = posterURL
        self.metadata = metadata
        self.certification = certification
        self.rating = rating
        self.badges = badges
        self.summary = summary
        self.play = play
        self.hasTrailer = hasTrailer
        self.isInWatchlist = isInWatchlist
        self.isWatched = isWatched
        self.download = download
        self.seasons = seasons
        self.selectedSeason = selectedSeason
        self.episodes = episodes
        self.upNextEpisodeID = upNextEpisodeID
        self.related = related
        self.people = people
        self.information = information
        self.accessibility = accessibility
    }

    /// Episodes of the selected season (all episodes when no season is set).
    var episodesOfSelectedSeason: [GlassEpisode] {
        guard let season = selectedSeason else { return episodes }
        return episodes.filter { $0.season == season }
    }
}

/// What the page asks the app to do. The views never call app code: every
/// button ends up in one of these closures (all no-ops by default).
struct GlassDetailActions {
    /// Play button: the movie, or `model.play`'s episode for a show.
    var play: () -> Void = {}
    /// An episode card was selected.
    var playEpisode: (_ episodeID: String) -> Void = { _ in }
    var playTrailer: () -> Void = {}
    var toggleWatchlist: () -> Void = {}
    /// Movies only.
    var toggleWatched: () -> Void = {}

    /// Movie Download button pressed. Same state machine as today's
    /// DownloadButton: idle → choose quality and start, downloading → pause,
    /// paused → resume, downloaded → Play / Delete options.
    var download: () -> Void = {}
    /// Context menu (long press) "Stop Download" on an active movie download.
    var stopDownload: () -> Void = {}
    /// Context menu "Delete Download" on a downloaded movie.
    var deleteDownload: () -> Void = {}

    /// Episode context menu: Download / Pause / Resume (same state machine as `download`).
    var downloadEpisode: (_ episodeID: String) -> Void = { _ in }
    var stopEpisodeDownload: (_ episodeID: String) -> Void = { _ in }
    var deleteEpisodeDownload: (_ episodeID: String) -> Void = { _ in }
    /// Episode context menu: Mark as Watched / Unwatched.
    var toggleEpisodeWatched: (_ episodeID: String) -> Void = { _ in }

    /// Called after the view has set `model.selectedSeason`.
    var selectSeason: (_ season: Int) -> Void = { _ in }
    var openRelated: (_ itemID: String) -> Void = { _ in }
    /// Play/Pause on a related title (tvOS): its page, then its playback.
    var playRelated: (_ itemID: String) -> Void = { _ in }
    var openPerson: (_ personID: String) -> Void = { _ in }

    /// Every focus move (nil when focus leaves the page), e.g. to restore
    /// focus after playback.
    var focusChanged: (_ target: GlassFocusTarget?) -> Void = { _ in }
}
