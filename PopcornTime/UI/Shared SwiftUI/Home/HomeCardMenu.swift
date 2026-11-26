// HomeCardMenu.swift — what a long press (iOS) or a secondary click (macOS)
// on a card of the Home offers, and the library calls behind it: the
// watchlist, the watched mark, taking a card out of Continue Watching,
// sharing the title's popcorntime:// link.
//
// Everything goes through the app's managers (`WatchlistManager`,
// `WatchedlistManager`, `Library`): the same writes as the detail pages',
// and the hub's local shelves follow by themselves (`.libraryDidChange`).
import Foundation
import SwiftUI
import PopcornKit
#if os(macOS)
import AppKit
#endif

/// The library, for a card.
enum HomeLibraryActions {

    static func isInWatchlist(_ item: HomeItem) -> Bool {
        Library.shared.isInWatchlist(item.imdbId)
    }

    /// In or out of the watchlist, with what the card knows of the title
    /// (its name, year, poster, genres: what a watchlist entry stores).
    static func toggleWatchlist(_ item: HomeItem) {
        if let movie = item.movie {
            WatchlistManager<Movie>.movie.toggle(movie)
        } else if let show = item.show {
            WatchlistManager<Show>.show.toggle(show)
        }
    }

    /// The id a watched mark is kept under: the movie's, or the episode's
    /// of an episode card. Nil for a show's card: a show as a whole has no
    /// mark.
    static func watchedID(of item: HomeItem) -> String? {
        if let episode = item.episode {
            return LibraryID.episodeID(showID: item.imdbId, EpisodeNumber(season: episode.season, episode: episode.number))
        }
        return item.kind == .movie ? item.imdbId : nil
    }

    static func isWatched(_ item: HomeItem) -> Bool {
        watchedID(of: item).map { Library.shared.isWatched($0) } ?? false
    }

    static func toggleWatched(_ item: HomeItem) {
        guard let id = watchedID(of: item) else { return }
        if item.episode != nil {
            WatchedlistManager<Episode>.episode.toggle(id, title: TasteTitle(item: item))
        } else {
            WatchedlistManager<Movie>.movie.toggle(id, title: TasteTitle(item: item))
        }
    }

    /// Takes the title's card out of Continue Watching (its saved position
    /// goes with it; the watched marks stay).
    static func removeFromContinueWatching(_ item: HomeItem) {
        let library = Library.shared
        guard let card = library.continueWatching(limit: library.policy.maxEntries).first(where: { $0.imdbID == item.imdbId }) else { return }
        library.removeFromContinueWatching(card)
    }

    /// popcorntime://movie/tt… or popcorntime://show/tt…: opens the title's
    /// page in the app, on any of its platforms.
    static func link(to item: HomeItem) -> URL? {
        switch item.kind {
        case .movie: return DeepLink.movie(id: item.imdbId, title: item.title).url
        case .show: return DeepLink.show(id: item.imdbId, title: item.title).url
        }
    }

    #if os(macOS)
    /// Puts a link on the clipboard, as a URL and as its text.
    static func copy(_ link: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([link as NSURL])
        pasteboard.setString(link.absoluteString, forType: .string)
    }
    #endif
}

/// The menu of a card, the same on every card, as in the TV app: Play (or
/// Resume), the title's page, My List, Watched, Share, then the
/// destructive entry.
struct HomeCardMenu: View {
    let item: HomeItem
    let shelfID: String
    let open: (HomeSelection) -> Void

    // Read so the menu is rebuilt after a change of the library.
    @Environment(\.homeLibraryVersion) private var libraryVersion

    private var resumes: Bool { shelfID == HomeShelfID.continueWatching }

    /// "S6 · É1" on an episode's card (not a resume card: Resume says it).
    private var episodeNumber: String? {
        guard !resumes, let episode = item.episode else { return nil }
        return HomeCardText().number(of: episode)
    }

    /// "Reprendre", "Lire", or "Lire S6 · É1" on an episode's card.
    private var playTitle: Text {
        if resumes { return Text("Resume") }
        return episodeNumber.map { Text("Play \($0)") } ?? Text("Play")
    }

    var body: some View {
        // Through the title's page and its Play button, as the hero's Play.
        Button {
            open(HomeSelection(item: item, shelfID: shelfID, intent: .play))
        } label: {
            Label { playTitle } icon: { icon("play.fill") }
        }
        Button {
            open(HomeSelection(item: item, shelfID: shelfID, intent: .details))
        } label: {
            Label { Text("Home.Menu.Details") } icon: { icon("info.circle") }
        }

        // Typed: a ternary of two literals would be a String, shown as it
        // is instead of looked up in the strings table.
        let inWatchlist = HomeLibraryActions.isInWatchlist(item)
        let watchlistTitle: LocalizedStringKey = inWatchlist ? "Remove from Watchlist" : "Add to Watchlist"
        Button {
            HomeLibraryActions.toggleWatchlist(item)
        } label: {
            Label { Text(watchlistTitle) } icon: { icon(inWatchlist ? "bookmark.slash" : "bookmark") }
        }

        if HomeLibraryActions.watchedID(of: item) != nil {
            let watched = HomeLibraryActions.isWatched(item)
            let watchedTitle: LocalizedStringKey = watched ? "Mark as Unwatched" : "Mark as Watched"
            Button {
                HomeLibraryActions.toggleWatched(item)
            } label: {
                // An episode's card says which episode: "Marquer S6 · É1 comme vu".
                Label { episodeNumber.map { Text(watched ? "Mark \($0) as Unwatched" : "Mark \($0) as Watched") } ?? Text(watchedTitle) } icon: { icon(watched ? "eye.slash" : "eye") }
            }
        }

        if let link = HomeLibraryActions.link(to: item) {
            #if os(macOS)
            // On a Mac a link is copied, then pasted where it is wanted.
            Button {
                HomeLibraryActions.copy(link)
            } label: {
                Label("Home.Menu.CopyLink", systemImage: "link")
            }
            #else
            ShareLink(item: link, subject: Text(verbatim: item.title)) {
                Label { Text("Home.Menu.ShareLink") } icon: { icon("square.and.arrow.up") }
            }
            #endif
        }

        if resumes {
            Divider()
            Button(role: .destructive) {
                HomeLibraryActions.removeFromContinueWatching(item)
            } label: {
                Label { Text("Home.Menu.RemoveFromContinueWatching") } icon: { icon("minus.circle", destructive: true) }
            }
        }
    }

    /// A menu's icon in the app's accent (red for the destructive entry):
    /// UIKit draws a menu's symbols in the window's tint — the system's
    /// blue — whatever SwiftUI's `.tint` says, unless they carry their colour.
    private func icon(_ name: String, destructive: Bool = false) -> Image {
        #if os(iOS)
        let color = destructive ? UIColor.systemRed : UIColor(GlassPalette.accent)
        if let image = UIImage(systemName: name)?.withTintColor(color, renderingMode: .alwaysOriginal) {
            return Image(uiImage: image)
        }
        #endif
        return Image(systemName: name)
    }
}
