import Foundation

// The library's side of the hub.
//
// The Home engine (this folder) asks for its local shelves through
// `HomeLocalHooks`; the user's library (Managers/Library) answers plain
// values: `ContinueWatchingItem`, `WatchlistItem`, `FollowedShow`,
// `ShowNewEpisodes`. This file is the bridge between the two:
//
//   - the library's values as cards (`HomeItem`);
//   - the hooks answered by a library (`HomeLocalHooks(library:)`);
//   - a hub that recomputes its local shelves when the library changes
//     (`HomeFeed.followChanges(of:)`).
//
// `HomeFeed.shared` is made with both for `Library.shared`: the apps have
// nothing to set. What stays theirs: `Library.acknowledgeNewEpisodes(ofShow:)`
// when a show's card is opened.

// MARK: - Cards

public extension HomeItem {

    /// A Continue Watching card of the library: a movie to resume, or a
    /// show with the episode it continues with — to resume (`progress`
    /// above 0), or the next one once the last was finished (`progress` 0,
    /// a whole episode left). The artwork is by IMDb id; the episode has
    /// its still.
    ///
    /// nil while the library cannot name the title (an entry migrated from
    /// 5.2 only has ids, until `Library.hydrateMissingTitles` names it): a
    /// card without a title is not shown.
    init?(resuming card: ContinueWatchingItem) {
        guard let title = card.title, !title.isEmpty else { return nil }
        let episode = card.number.map {
            HomeEpisode(season: $0.season, number: $0.episode, title: card.episodeTitle, stillURL: card.episodeStillURL)
        }
        self.init(imdbId: card.imdbID, kind: card.kind == .movie ? .movie : .show, title: title,
                  runtimeMinutes: card.runtime, posterURL: card.posterURL, backdropURL: card.backdropURL,
                  logoURL: card.logoURL, episode: episode, date: card.updatedAt,
                  progress: Double(max(0, min(1, card.progress))),
                  remainingMinutes: card.remaining.map { max(1, Int(($0 / 60).rounded())) })
    }

    /// A title of the watchlist, with what was stored when it was added
    /// (title, year, poster, genres). nil when it was stored without a title.
    init?(watchlisted entry: WatchlistItem) {
        guard !entry.title.isEmpty else { return nil }
        self.init(imdbId: entry.imdbID, kind: entry.kind == .movie ? .movie : .show, title: entry.title,
                  year: entry.year.flatMap { Int($0.prefix(4)) }, genres: entry.genres,
                  posterURL: entry.posterURL, backdropURL: entry.backdropURL,
                  logoURL: OpenMetadata.logoURL(imdbId: entry.imdbID))
    }

    /// The card of a followed show's news: its most recent new episode,
    /// else — nothing new — the next one to air. Badged like the cards a
    /// hub without a library makes from Cinemeta's calendar
    /// (`HomeBuilder`): "Upcoming",
    /// "Series Premiere", "New Season", or "New Episode" when it aired
    /// within the builder's `newEpisodeAge` (a week).
    ///
    /// nil when the library cannot name the show, or has nothing to say.
    init?(newEpisodesOf show: ShowNewEpisodes, now: Date) {
        guard let title = show.showTitle, !title.isEmpty, let episode = show.latest ?? show.next else { return nil }
        var badges: [HomeBadge] = []
        if let aired = episode.aired, aired > now {
            badges.append(.upcoming)
        } else if episode.episode == 1 {
            badges.append(episode.season == 1 ? .premiere : .newSeason)
        } else if let aired = episode.aired, now.timeIntervalSince(aired) < HomeBuilder.Rules().newEpisodeAge {
            badges.append(.newEpisode)
        }
        self.init(imdbId: show.showID, kind: .show, title: title,
                  posterURL: show.posterURL, backdropURL: show.backdropURL, logoURL: show.logoURL, badges: badges,
                  episode: HomeEpisode(season: episode.season, number: episode.episode, title: episode.title,
                                       stillURL: show.stillURL(of: episode), airDate: episode.aired),
                  date: episode.aired)
    }
}

// MARK: - Hooks

public extension HomeLocalHooks {

    /// The hooks answered by `library`. Every answer comes from what the
    /// library has in memory (it never asks the network to answer), so they
    /// keep the hooks' contract — `prepare` is where it reads its files
    /// into memory first, off the main queue (`Library.preload`: a guide
    /// per followed show). `willRefresh` is where the library is told
    /// to bring its airings and its missing titles up to date, on its own
    /// time — it posts `.libraryDidChange` when something came back
    /// (`HomeFeed.followChanges(of:)` then recomputes the local shelves).
    ///
    /// The followed shows' episodes have one owner, the library: it asks
    /// their airings itself (`refreshNewEpisodes`: Cinemeta's calendar, or
    /// TVMaze show by show) and its rule says which are new
    /// (`NewEpisodesRule`). So `followedShowIds` is left unanswered: the hub
    /// does not download the same calendar a second time, and adds no card
    /// of its own — under its simpler rule, an episode being watched would
    /// be shown as new next to its Continue Watching card.
    ///
    /// - Parameters:
    ///   - library: the user's library.
    ///   - resumeLimit: Continue Watching cards asked (a shelf shows 30).
    ///   - now: the clock of the "New Episode" / "Upcoming" badges.
    init(library: Library, resumeLimit: Int = 30, now: @escaping () -> Date = Date.init) {
        self.init()
        prepare = { library.preload() }
        continueWatching = {
            HomeLocalHooks.described(library.continueWatching(limit: resumeLimit).compactMap(HomeItem.init(resuming:)), by: library)
        }
        watchlist = {
            HomeLocalHooks.alternating(library.watchlist(.movie).compactMap(HomeItem.init(watchlisted:)),
                                       library.watchlist(.show).compactMap(HomeItem.init(watchlisted:)))
        }
        newEpisodes = {
            let date = now()
            return HomeLocalHooks.described(library.newEpisodes().compactMap { HomeItem(newEpisodesOf: $0, now: date) }, by: library)
        }
        isWatched = { imdbId, season, episode in
            library.isWatched(LibraryID.episodeID(showID: imdbId, EpisodeNumber(season: season, episode: episode)))
        }
        willRefresh = {
            // Only what is older than 6 h is asked; a title is asked until
            // Cinemeta has answered about it.
            library.refreshNewEpisodes()
            library.hydrateMissingTitles()
        }
    }

    /// The cards with the year and the genres of their titles, for the
    /// titles of the watchlist: it is the one place the library keeps them
    /// (a resume entry and a guide have a title and a runtime), and it is in
    /// memory. A title watched and watchlisted then has its genres on
    /// whichever card the hub counts it by (`HomeBuilder.genreChoices` takes
    /// each title once, resume cards and new episodes first: a card without
    /// genres there hid the watchlist's). Other titles stay as they are —
    /// nothing is asked for them.
    internal static func described(_ cards: [HomeItem], by library: Library) -> [HomeItem] {
        guard !cards.isEmpty else { return cards }
        let wanted = Set(cards.map(\.imdbId))
        var stored: [String: HomeItem] = [:]
        for kind in Set(cards.map(\.kind)) {
            for entry in library.watchlist(kind == .movie ? .movie : .show) where wanted.contains(entry.imdbID) {
                if let card = HomeItem(watchlisted: entry) { stored[entry.imdbID] = card }
            }
        }
        return cards.map { card in stored[card.imdbId].map(card.filling(from:)) ?? card }
    }

    /// One shelf for the two lists of the watchlist. Each is ordered (the
    /// latest added first) but nothing dates a movie against a show: one of
    /// each in turn, so a long list of one kind does not push the other out
    /// of the shelf.
    internal static func alternating<T>(_ first: [T], _ second: [T]) -> [T] {
        var result: [T] = []
        result.reserveCapacity(first.count + second.count)
        for index in 0..<max(first.count, second.count) {
            if index < first.count { result.append(first[index]) }
            if index < second.count { result.append(second[index]) }
        }
        return result
    }
}

// MARK: - Following the library

public extension HomeFeed {

    /// Recomputes the local shelves whenever `library` changes — a title
    /// played, marked, added to the watchlist or named, airings refreshed
    /// (`.libraryDidChange`) — without any request (`refreshLocal`). A burst
    /// of changes (a season marked watched) recomputes them once.
    ///
    /// The hub does not keep the observation: remove the returned token
    /// from `center` to stop (`HomeFeed.shared` follows `Library.shared`
    /// for the app's life).
    @discardableResult
    func followChanges(of library: Library, center: NotificationCenter = .default) -> NSObjectProtocol {
        let burst = Burst()
        // No queue: the library posts on the main thread, and a change is
        // only noted here.
        return center.addObserver(forName: .libraryDidChange, object: library, queue: nil) { [weak self] _ in
            guard burst.begin() else { return }
            DispatchQueue.main.async {
                burst.end()
                self?.refreshLocal()
            }
        }
    }
}

/// True for the first change of a burst, until its recomputation started.
private final class Burst: @unchecked Sendable {
    private let lock = NSLock()
    private var isPending = false

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isPending else { return false }
        isPending = true
        return true
    }

    func end() {
        lock.lock()
        isPending = false
        lock.unlock()
    }
}
