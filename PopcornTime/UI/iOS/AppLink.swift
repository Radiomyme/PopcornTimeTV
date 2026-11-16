// AppLink.swift — the iOS app's tabs, and what a popcorntime:// link asks it
// for. No SwiftUI: PopcornKit's `DeepLink` says what the URL means, this
// file says what the iOS app does with it (unit-tested); `AppRouter` shows it.
import Foundation
import PopcornKit

/// The root tabs of the iOS app, in bar order (`RootTabView`).
///
/// Settings is not one of them: on an iPhone the bar holds five entries, and
/// they are Home, Movies, Shows, Watchlist and Search. Settings opens from
/// the gear of every root screen (`RootToolbar`).
enum AppTab: String, Hashable, CaseIterable {
    case home
    case movies
    case shows
    case watchlist
    case search
}

/// What a page is opened for besides showing itself: the Home's Continue
/// Watching cards and Play button, a popcorntime://play link, a link to a
/// season.
struct MediaPageRequest: Hashable {
    /// Once the page knows its sources, do what its Play button does — on
    /// the same path and behind the same questions (cellular data, "Always
    /// Ask") — or, with `season` and `episode`, what a tap on that
    /// episode's row does.
    var autoPlay = false
    /// A show's page opens its episode list on this season.
    var season: Int?
    var episode: Int?
    /// Asked by a popcorntime:// link — from a web page, a message, a QR
    /// code: not a gesture made in the app. Such a page never picks a
    /// release by itself: `autoPlay` brings the quality picker up whatever
    /// the automatic quality, and the user chooses what plays.
    var fromLink = false

    /// The release is picked without asking: the automatic quality is on
    /// (not "Always Ask") and the request comes from the app itself.
    func picksAlone(automaticQuality: Bool) -> Bool {
        automaticQuality && !fromLink
    }

    /// What a Home card picked asks of its title's page (iOS and the Mac):
    /// - a card that only opens its page: an episode's card opens the
    ///   show on that episode's season;
    /// - a Continue Watching card, the carousel's Play, Space on a title:
    ///   what the page's own Play button does — for a show, the episode the
    ///   library says is next (a resume card's own);
    /// - Space on an episode's card elsewhere (a new episode, an episode
    ///   just aired): that episode, as a tap on its row of the page.
    static func home(item: HomeItem, shelfID: String, plays: Bool) -> MediaPageRequest {
        let namesEpisode = !(plays && shelfID == HomeShelfID.continueWatching)
        return MediaPageRequest(autoPlay: plays, season: namesEpisode ? item.episode?.season : nil,
                                episode: namesEpisode ? item.episode?.number : nil)
    }
}

/// A link, as the iOS app answers it.
enum AppLinkAction: Equatable {
    enum Kind: Equatable {
        case movie
        case show
    }

    /// Show this tab.
    case tab(AppTab)
    /// Open the Settings sheet (Settings is not a tab on iOS).
    case settings
    /// Show the Search tab; a non-empty text is typed and searched.
    case search(String)
    /// Push a title's page on the tab in front.
    case page(kind: Kind, id: String, title: String?, request: MediaPageRequest)

    /// Nil for a link the iOS app has no screen for (Downloads).
    init?(_ link: DeepLink) {
        switch link {
        case let .movie(id, title, play):
            self = .page(kind: .movie, id: id, title: title, request: MediaPageRequest(autoPlay: play, fromLink: true))
        case let .show(id, title, season, episode, play):
            // An episode without its season names nothing.
            let episode = season == nil ? nil : episode
            self = .page(kind: .show, id: id, title: title, request: MediaPageRequest(autoPlay: play, season: season, episode: episode, fromLink: true))
        case let .search(query):
            self = .search(query)
        case let .tab(tab):
            switch tab {
            case .home: self = .tab(.home)
            case .movies: self = .tab(.movies)
            case .shows: self = .tab(.shows)
            case .watchlist: self = .tab(.watchlist)
            case .search: self = .search("")
            case .settings: self = .settings
            case .downloads: return nil
            }
        }
    }

    /// From a URL the system hands the app; nil when it is not a link the
    /// app shows (Trakt's sign-in redirect has the same scheme and is not).
    init?(url: URL) {
        guard let link = DeepLink(url: url) else { return nil }
        self.init(link)
    }
}

/// Links that arrive while a stream is being prepared or the player is up
/// (iOS). Pushing a page — or changing tabs — under the full-screen player
/// would cover the page that presents it: the stream could stop, or the
/// new page would only show once the player closes. Such a link is held,
/// the latest one only, and shown once every player is gone — as a page to
/// look at: a link that asked to play no longer plays, minutes later.
struct AppLinkHold {
    /// The pages whose stream or player is up.
    private var busy: Set<UUID> = []
    private(set) var held: AppLinkAction?

    var isBusy: Bool { !busy.isEmpty }

    /// A link arrived: returned to be shown now, or held (nil).
    mutating func receive(_ action: AppLinkAction) -> AppLinkAction? {
        guard isBusy else { return action }
        held = action.withoutPlay
        return nil
    }

    /// A page's stream or player came up, or is gone (`token` names the
    /// page). Returns the held link once nothing is up any more.
    mutating func playerChanged(_ token: UUID, isUp: Bool) -> AppLinkAction? {
        if isUp {
            busy.insert(token)
            return nil
        }
        busy.remove(token)
        guard !isBusy, let action = held else { return nil }
        held = nil
        return action
    }
}

extension AppLinkAction {
    /// The same link, asking for the page only.
    var withoutPlay: AppLinkAction {
        guard case .page(let kind, let id, let title, var request) = self else { return self }
        request.autoPlay = false
        return .page(kind: kind, id: id, title: title, request: request)
    }
}
