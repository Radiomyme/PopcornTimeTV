import Foundation

/// A card of "Continue Watching": a movie to resume, or a show with the
/// episode it continues with. One card per title.
public struct ContinueWatchingItem: Equatable {

    public enum Kind: String {
        case movie
        case show
    }

    public enum Reason: String {
        /// `mediaID` was started and not finished.
        case resume
        /// The show's last episode played was finished: `mediaID` is the next.
        case nextUp
    }

    public let kind: Kind
    public let reason: Reason
    /// The movie's or the show's IMDb id: the card's identity, and what its
    /// artwork is derived from.
    public let imdbID: String
    /// What Play starts: the movie's id, or the episode's ("tt…-sXeY").
    public let mediaID: String
    /// The movie's or the show's title; nil until hydrated (`Library.hydrateMissingTitles`).
    public let title: String?
    public let season: Int?
    public let episode: Int?
    public let episodeTitle: String?
    /// 0…1; 0 for a next episode not started.
    public let progress: Float
    /// Seconds, when a player saved them.
    public let position: TimeInterval?
    public let duration: TimeInterval?
    /// Catalogue runtime in minutes, when known.
    public let runtime: Int?
    /// The title's last activity: what the row is sorted by.
    public let updatedAt: Date

    public var number: EpisodeNumber? {
        guard let season = season, let episode = episode else { return nil }
        return EpisodeNumber(season: season, episode: episode)
    }

    /// Seconds left to watch: from the player's duration when it saved one,
    /// else from the catalogue runtime; nil when neither is known.
    public var remaining: TimeInterval? {
        let fraction = Double(max(0, min(1, progress)))
        if let duration = duration, duration > 0 {
            if let position = position, position <= duration { return duration - position }
            return duration * (1 - fraction)
        }
        if let runtime = runtime, runtime > 0 { return Double(runtime) * 60 * (1 - fraction) }
        return nil
    }

    /// Artwork by IMDb id (metahub): nothing to fetch first.
    public var backdropURL: URL? { return OpenMetadata.backgroundURL(imdbId: imdbID) }
    public var posterURL: URL? { return OpenMetadata.posterURL(imdbId: imdbID) }
    public var logoURL: URL? { return OpenMetadata.logoURL(imdbId: imdbID) }
    /// The episode's still (a 404 for an episode metahub does not know:
    /// fall back to `backdropURL`); nil for a movie.
    public var episodeStillURL: URL? {
        return number.flatMap { LibraryArtwork.episodeStillURL(showID: imdbID, $0) }
    }
}

/// A title of the watchlist, as stored when it was added.
public struct WatchlistItem: Equatable {
    public let kind: ContinueWatchingItem.Kind
    public let imdbID: String
    public let title: String
    public let year: String?
    /// The poster stored with the title, else metahub's by IMDb id.
    public let posterURL: URL?
    /// The genres stored with the title ([] when it was stored without).
    public let genres: [String]

    public var backdropURL: URL? { return OpenMetadata.backgroundURL(imdbId: imdbID) }
}

/// A show the user follows: in the watchlist, or with an episode watched or
/// started recently.
public struct FollowedShow: Equatable {
    public let showID: String
    public let title: String?
    public let isInWatchlist: Bool
    /// The last time an episode was played or marked; nil when none is
    /// known (a show that is only in the watchlist).
    public let lastActivity: Date?
    /// The furthest regular episode watched or started; nil when none.
    public let reached: EpisodeNumber?
}

/// The cards of the row, from the entries. Pure.
enum ContinueWatchingBuilder {

    /// - Parameters:
    ///   - isWatched: the watched mark of a media id.
    ///   - guide: the cached guide of a show, nil when none.
    static func items(entries: [ContinueWatchingEntry], isWatched: (String) -> Bool, guide: (String) -> ShowGuide?,
                      now: Date, policy: LibraryPolicy, limit: Int, kinds: Set<ContinueWatchingItem.Kind>) -> [ContinueWatchingItem] {
        func isFresh(_ date: Date) -> Bool { return now.timeIntervalSince(date) <= policy.rowExpiry }
        var items: [ContinueWatchingItem] = []

        if kinds.contains(.movie) {
            for entry in entries where entry.kind == .movie && isFresh(entry.updatedAt) {
                guard !entry.isFinished, !isWatched(entry.mediaID), !policy.isFinished(progress: entry.progress),
                      policy.isStarted(progress: entry.progress, position: entry.position) else { continue }
                items.append(ContinueWatchingItem(kind: .movie, reason: .resume, imdbID: entry.mediaID, mediaID: entry.mediaID,
                                                  title: entry.title, season: nil, episode: nil, episodeTitle: nil,
                                                  progress: entry.progress, position: entry.position, duration: entry.duration,
                                                  runtime: entry.runtime, updatedAt: entry.updatedAt))
            }
        }

        if kinds.contains(.show) {
            var byShow: [String: [ContinueWatchingEntry]] = [:]
            for entry in entries where entry.kind == .episode {
                guard let showID = entry.showID, entry.number != nil else { continue }
                byShow[showID, default: []].append(entry)
            }
            for (showID, showEntries) in byShow {
                guard let lastActivity = showEntries.map({ $0.updatedAt }).max(), isFresh(lastActivity) else { continue }
                let known = guide(showID)
                let episodes = known?.episodes ?? []
                var watched = Set(showEntries.filter { $0.isFinished || isWatched($0.mediaID) }.compactMap { $0.number })
                for episode in episodes where isWatched(LibraryID.episodeID(showID: showID, episode.number)) {
                    watched.insert(episode.number)
                }
                let records = showEntries.compactMap { entry in
                    entry.number.map { EpisodeRecord(number: $0, progress: entry.progress, position: entry.position, updatedAt: entry.updatedAt) }
                }
                let position = NextUpRule.position(guide: episodes, watched: watched, records: records, now: now, policy: policy)
                // `.start` is a show not really begun (or finished): no card.
                guard let next = position.nextUp, next.reason != .start else { continue }
                // The episode after the last one finished is only known from
                // a guide that says what follows it. A calendar window far
                // ahead (S5E7… for a show left at S1E3) does not: no card
                // until the whole guide is there (`titlesToHydrate`).
                if next.reason == .next {
                    guard let known = known, let last = position.lastPlayed, known.knowsWhatFollows(last) else { continue }
                }
                let entry = showEntries.first { $0.number == next.number }
                items.append(ContinueWatchingItem(
                    kind: .show, reason: next.reason == .resume ? .resume : .nextUp, imdbID: showID,
                    mediaID: entry?.mediaID ?? LibraryID.episodeID(showID: showID, next.number),
                    title: showEntries.compactMap({ $0.title }).first ?? known?.title,
                    season: next.number.season, episode: next.number.episode,
                    episodeTitle: entry?.episodeTitle ?? known?.episode(next.number)?.title,
                    progress: next.progress ?? 0,
                    position: next.progress == nil ? nil : entry?.position,
                    duration: next.progress == nil ? nil : entry?.duration,
                    runtime: showEntries.compactMap({ $0.runtime }).first ?? known?.runtime,
                    updatedAt: lastActivity))
            }
        }

        items.sort { a, b in a.updatedAt == b.updatedAt ? a.imdbID < b.imdbID : a.updatedAt > b.updatedAt }
        return Array(items.prefix(max(0, limit)))
    }
}

/// The user's library: one place that knows what was watched, what is in
/// progress, which shows are followed and what aired since.
///
/// `WatchedlistManager` and `WatchlistManager` keep their API and call this;
/// the Home feed and the Continue Watching row read plain values from it
/// (`ContinueWatchingItem`, `WatchlistItem`, `FollowedShow`,
/// `ShowNewEpisodes`). Reads never touch the network or the disk (after the
/// first one) and are safe from any thread; writes post `.libraryDidChange`
/// on the main thread.
public final class Library {

    /// The active profile's library (`ProfileManager`): its keys of the
    /// standard defaults, the Caches folder (the episode guides are the
    /// same for every profile), the live hosts. One library per profile,
    /// made the first time it is asked and kept: switching profiles back and
    /// forth reads nothing again.
    public static var shared: Library {
        return library(for: ProfileManager.shared.activeID)
    }

    private static let librariesLock = NSLock()
    private static var libraries: [String: Library] = [:]

    /// A profile's library (kept once made).
    public static func library(for profileID: String) -> Library {
        librariesLock.lock(); defer { librariesLock.unlock() }
        if let library = libraries[profileID] { return library }
        let library = make(for: profileID)
        libraries[profileID] = library
        return library
    }

    /// Drops a deleted profile's library.
    static func forget(profileID: String) {
        librariesLock.lock(); defer { librariesLock.unlock() }
        libraries[profileID] = nil
    }

    private static func make(for profileID: String) -> Library {
        #if DEBUG
        // `-PTDebugLibraryInMemory YES` (the tvOS UI tests): the six lists as
        // the launch arguments give them (`-episodesProgress '{ "tt…-s1e2" =
        // "0.42"; }'`), kept in memory — nothing is written to the app's
        // defaults, nothing is cached on disk. The same for a launch with
        // `-PTDebugMovieProgress` / `-PTDebugEpisodeProgress` (tvOS,
        // SceneDelegate: progress injected for this launch only): on the
        // real defaults their titles would be stored as resume entries, or
        // have no card at all once the entries exist.
        let debug = UserDefaults.standard
        if debug.bool(forKey: "PTDebugLibraryInMemory") || debug.string(forKey: "PTDebugMovieProgress") != nil
            || debug.string(forKey: "PTDebugEpisodeProgress") != nil {
            var lists: [String: Any] = [:]
            // Only the primary profile gets the launch arguments' lists.
            for list in [WatchStateStore.List.movies, .episodes, .shows] where profileID == Profile.primaryID {
                for key in [WatchStateStore.watchedKey(list), WatchStateStore.progressKey(list), WatchStateStore.watchlistKey(list)] {
                    lists[key] = UserDefaults.standard.object(forKey: key)
                }
            }
            return Library(storage: MemoryLibraryStorage(lists), guideDirectory: nil, remote: .live, now: Date.init)
        }
        #endif
        return Library(storage: ProfileManager.shared.storage(for: profileID), deviceStorage: UserDefaults.standard,
                       guideDirectory: Library.defaultGuideDirectory, remote: .live, now: Date.init)
    }

    public let policy: LibraryPolicy

    let state: WatchStateStore
    let resume: ContinueWatchingStore
    let guides: ShowGuideCache
    let acknowledgements: NewEpisodesAcknowledgements

    private let storage: LibraryStorage
    /// The device's settings (`isBulkEpisodeLookupEnabled`, a privacy
    /// choice the Home reads too): the same for every profile.
    private let deviceStorage: LibraryStorage
    private let remote: LibraryRemote
    private let now: () -> Date
    private let center: NotificationCenter

    private let lock = NSLock()
    /// The furthest regular episode watched or started, by show; rebuilt
    /// after a write to the episode lists.
    private var reachedByShow: [String: EpisodeNumber]?
    private var isRefreshingAirings = false
    private var isHydrating = false
    /// Ids Cinemeta answered about this session, known to it or not (a
    /// title it does not have is not asked again on every refresh of a row).
    private var hydrationAttempted = Set<String>()

    /// - Parameters:
    ///   - storage: the durable state (the 5.2 lists, the resume entries,
    ///     the acknowledgements).
    ///   - guideDirectory: where episode guides are cached; nil = memory only.
    ///   - remote: the network, as closures.
    ///   - now: the clock.
    ///   - deviceStorage: the device's settings; nil = `storage`.
    public init(storage: LibraryStorage, deviceStorage: LibraryStorage? = nil, guideDirectory: URL?, remote: LibraryRemote,
                policy: LibraryPolicy = .standard, center: NotificationCenter = .default, now: @escaping () -> Date) {
        self.storage = storage
        self.deviceStorage = deviceStorage ?? storage
        self.remote = remote
        self.policy = policy
        self.center = center
        self.now = now
        state = WatchStateStore(storage: storage)
        resume = ContinueWatchingStore(storage: storage, legacy: state, policy: policy, now: now)
        guides = ShowGuideCache(directory: guideDirectory)
        acknowledgements = NewEpisodesAcknowledgements(storage: storage)
    }

    /// Caches/popcornkit-library/guides (purgeable: every guide can be asked
    /// again). The Mac app is not sandboxed: its bundle id keeps two builds
    /// apart there.
    static var defaultGuideDirectory: URL? {
        var folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        #if os(macOS)
        folder = folder?.appendingPathComponent(Bundle.main.bundleIdentifier ?? "PopcornKit", isDirectory: true)
        #endif
        return folder?.appendingPathComponent("popcornkit-library", isDirectory: true).appendingPathComponent("guides", isDirectory: true)
    }

    /// Reads into memory what the first answers take from the disk: the
    /// stored lists (the very first read of 5.3 also makes the resume
    /// entries from the 5.2 lists) and the guide file of every show the row
    /// and the new episodes look at. After it `continueWatching`,
    /// `newEpisodes`, `followedShows`, `titlesToHydrate` and the staleness
    /// check of `refreshNewEpisodes` answer from memory.
    ///
    /// For a caller about to ask them on the main thread with many shows
    /// followed (the Home hub before its first paint:
    /// `HomeLocalHooks.prepare`): call it from a background queue first.
    /// Any thread; a second call finds everything in memory.
    public func preload() {
        var showIDs = Set(followedShowIDs())
        for entry in resume.allEntries() { if let showID = entry.showID { showIDs.insert(showID) } }
        for showID in showIDs { _ = guides.guide(showID) }
    }

    /// Forgets every in-memory copy: the next read loads the storage again
    /// (something else wrote it: a debug hook, a restore).
    public func reloadFromStorage() {
        state.invalidate()
        resume.invalidate()
        acknowledgements.invalidate()
        lock.lock()
        reachedByShow = nil
        lock.unlock()
    }

    // MARK: - Watched and progress

    /// The watched mark of a movie ("tt…") or an episode ("tt…-sXeY").
    public func isWatched(_ mediaID: String) -> Bool {
        return state.isWatched(mediaID, .movies) || state.isWatched(mediaID, .episodes)
    }

    /// The saved progress (0…1) of a movie or an episode; 0 when none.
    public func progress(_ mediaID: String) -> Float {
        let movie = state.progress(mediaID, .movies)
        return movie != 0 ? movie : state.progress(mediaID, .episodes)
    }

    /// The resume entry of a movie or an episode (dates, position, titles).
    public func entry(_ mediaID: String) -> ContinueWatchingEntry? {
        return resume.entry(mediaID)
    }

    func isWatched(_ id: String, _ list: WatchStateStore.List) -> Bool {
        return state.isWatched(id, list)
    }

    // MARK: - Remembered releases

    /// The release `mediaID` (a movie or an episode) was last played from;
    /// nil when its entry has none (saved before 5.3.0, or none).
    public func rememberedRelease(for mediaID: String) -> RememberedRelease? {
        return resume.entry(mediaID)?.release
    }

    /// The release of the show's most recently played episode that has one:
    /// where the show continues from (its last episode finished keeps its
    /// entry, so its release stays known).
    public func rememberedRelease(ofShow showID: String) -> RememberedRelease? {
        return resume.entries(ofShow: showID).sorted(by: ContinueWatchingStore.moreRecent).lazy.compactMap { $0.release }.first
    }

    /// Forgets the release remembered for `mediaID`, or for every episode of
    /// a show (`id` an IMDb show id): it failed to play again (no peer, an
    /// error), the next « Resume » goes through the sources. Returns whether
    /// one was remembered.
    ///
    /// - Parameter sourceKey: only that release (`MagnetLink.sourceKey` of
    ///   the link that failed), from the title's entry and, for an episode,
    ///   from its show's other entries that remember it (a season pack
    ///   replayed for an episode not started: `UpNextResume.Rule.samePack`).
    @discardableResult
    public func forgetRelease(_ id: String, sourceKey: String? = nil) -> Bool {
        return resume.forgetRelease(id, sourceKey: sourceKey)
    }

    func progress(_ id: String, _ list: WatchStateStore.List) -> Float {
        return state.progress(id, list)
    }

    /// The one place a playback position is written (`WatchedlistManager
    /// .setCurrentProgress` calls it): the progress list, the resume entry
    /// with its date, and the watched mark from `policy.watchedFraction`.
    /// 0 deletes the position and the entry. Returns true when the title
    /// became watched by this call.
    @discardableResult
    func setProgress(_ progress: Float, id: String, list: WatchStateStore.List, details: PlaybackDetails? = nil) -> Bool {
        let kind = Library.kind(of: list)
        guard progress.isFinite, progress != 0 else {
            state.setProgress(nil, id, list)
            resume.remove(mediaID: id)
            noteEpisodesChanged(list)
            post(.progress, ids: [id])
            return false
        }
        let wasWatched = state.isWatched(id, list)
        state.setProgress(progress, id, list)
        let becameWatched = policy.isFinished(progress: progress) && state.setWatched(true, id, list)
        // A watched title opened again for a moment (below "started") is
        // not where the user is: its position is saved, as always, but it
        // gets no entry and no date — a watched episode's entry is where its
        // show continues from, and would take the place of the show's last
        // one finished. Played on, it counts.
        let position = details?.position ?? details?.duration.map { Double(progress) * $0 }
        if !wasWatched || policy.isStarted(progress: progress, position: position) {
            resume.record(mediaID: id, kind: kind, progress: progress, isWatched: state.isWatched(id, list), details: details)
        }
        noteEpisodesChanged(list)
        post(becameWatched ? .watched : .progress, ids: [id])
        return becameWatched
    }

    /// Marks a title watched, or clears the mark — which also deletes its
    /// saved position, as it always did. Returns whether the mark changed.
    @discardableResult
    func setWatched(_ isWatched: Bool, id: String, list: WatchStateStore.List, details: PlaybackDetails? = nil) -> Bool {
        let changed: Bool
        if isWatched {
            changed = state.setWatched(true, id, list)
            resume.record(mediaID: id, kind: Library.kind(of: list), progress: nil, isWatched: true, details: details)
        } else {
            let wasWatched = state.setWatched(false, id, list)
            let hadProgress = state.setProgress(nil, id, list)
            // A show keeps one finished entry, where it continues from.
            // When that is the episode un-marked, the furthest one still
            // watched takes its place and its date: the show keeps its card
            // (the next episode is the one un-marked) and stays followed.
            if let removed = resume.remove(mediaID: id), removed.kind == .episode, removed.isFinished,
               let showID = removed.showID, let number = furthestWatchedEpisode(ofShow: showID) {
                let previous = LibraryID.episodeID(showID: showID, number)
                resume.restore(ContinueWatchingEntry(mediaID: previous, kind: .episode, showID: showID, season: number.season,
                                                     episode: number.episode, title: removed.title, runtime: removed.runtime,
                                                     progress: state.progress(previous, .episodes), updatedAt: removed.updatedAt,
                                                     isFinished: true))
            }
            changed = wasWatched || hadProgress
        }
        noteEpisodesChanged(list)
        post(.watched, ids: [id])
        return changed
    }

    /// The furthest regular episode of a show still marked watched.
    private func furthestWatchedEpisode(ofShow showID: String) -> EpisodeNumber? {
        return state.watchedSet(.episodes).compactMap { id -> EpisodeNumber? in
            guard id.hasPrefix(showID), let (show, number) = LibraryID.episode(id), show == showID, !number.isSpecial else { return nil }
            return number
        }.max()
    }

    /// A Trakt sync: adds its watched ids / positions to the local ones
    /// (never replaces them: Trakt's episode ids are TVDB numbers, the
    /// app's are not).
    func mergeFromTrakt(watched ids: [String]? = nil, progress: [String: Float]? = nil, list: WatchStateStore.List) {
        if let ids = ids { state.mergeWatched(ids, list) }
        if let progress = progress { state.mergeProgress(progress, list) }
        noteEpisodesChanged(list)
        post(ids != nil ? .watched : .progress, ids: Set(ids ?? []).union(progress.map { Set($0.keys) } ?? []))
    }

    private static func kind(of list: WatchStateStore.List) -> ContinueWatchingEntry.Kind {
        return list == .movies ? .movie : .episode
    }

    private func noteEpisodesChanged(_ list: WatchStateStore.List) {
        guard list == .episodes else { return }
        lock.lock()
        reachedByShow = nil
        lock.unlock()
    }

    /// IMDb ids of the movies marked watched and of the shows with an
    /// episode watched: what « For You » never offers.
    public func watchedTitleIDs() -> Set<String> {
        var ids = state.watchedSet(.movies)
        for id in state.watchedSet(.episodes) {
            if let (showID, _) = LibraryID.episode(id) { ids.insert(showID) }
        }
        return ids
    }

    // MARK: - Watchlist

    /// Whether a movie or a show (IMDb id) is in the watchlist.
    public func isInWatchlist(_ imdbID: String) -> Bool {
        return state.isInWatchlist(imdbID, .movies) || state.isInWatchlist(imdbID, .shows)
    }

    /// The watchlist's movies or shows, the latest added first.
    public func watchlist(_ kind: ContinueWatchingItem.Kind) -> [WatchlistItem] {
        var seen = Set<String>()
        return state.watchlistJSON(kind == .movie ? .movies : .shows).reversed().compactMap { json in
            guard let id = WatchStateStore.id(ofWatchlistEntry: json), seen.insert(id).inserted else { return nil }
            let stored = ((json["images"] as? [String: Any])?["poster"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            let year = (json["year"] as? String) ?? (json["year"] as? NSNumber)?.stringValue
            return WatchlistItem(kind: kind, imdbID: id, title: (json["title"] as? String) ?? "",
                                 year: year.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 },
                                 posterURL: stored ?? OpenMetadata.posterURL(imdbId: id),
                                 genres: (json["genres"] as? [String]) ?? [])
        }
    }

    func isInWatchlist(_ id: String, _ list: WatchStateStore.List) -> Bool {
        return state.isInWatchlist(id, list)
    }

    @discardableResult
    func addToWatchlist(_ json: [String: Any], id: String, list: WatchStateStore.List) -> Bool {
        let changed = state.addToWatchlist(json, id: id, list)
        if changed { post(.watchlist, ids: [id]) }
        return changed
    }

    /// The stored entry of a watchlisted title gets what it lacked
    /// (`WatchStateStore.completeWatchlistEntry`).
    @discardableResult
    func completeWatchlistEntry(_ json: [String: Any], id: String, list: WatchStateStore.List) -> Bool {
        let changed = state.completeWatchlistEntry(json, id: id, list)
        if changed { post(.watchlist, ids: [id]) }
        return changed
    }

    @discardableResult
    func removeFromWatchlist(id: String, list: WatchStateStore.List) -> Bool {
        let changed = state.removeFromWatchlist(id: id, list)
        if changed { post(.watchlist, ids: [id]) }
        return changed
    }

    func replaceWatchlist(_ json: [[String: Any]], list: WatchStateStore.List) {
        state.replaceWatchlist(json, list)
        post(.watchlist, ids: Set(json.compactMap(WatchStateStore.id(ofWatchlistEntry:))))
    }

    // MARK: - Continue Watching

    /// The row: movies in progress and shows with the episode they continue
    /// with (to resume, or the next one once the last was finished), the
    /// most recently played first, one card per title. No network, no disk
    /// after the first call.
    public func continueWatching(limit: Int = 20, kinds: Set<ContinueWatchingItem.Kind> = [.movie, .show]) -> [ContinueWatchingItem] {
        return ContinueWatchingBuilder.items(entries: resume.allEntries(), isWatched: { self.isWatched($0) },
                                             guide: { self.guides.guide($0) }, now: now(), policy: policy,
                                             limit: limit, kinds: kinds)
    }

    /// Takes a card out of the row. A title to resume loses its saved
    /// position (what "Remove" always did); a show also loses its other
    /// entries, so no other card of it takes the place. Watched marks stay.
    public func removeFromContinueWatching(_ item: ContinueWatchingItem) {
        var ids: Set<String> = [item.imdbID, item.mediaID]
        switch item.kind {
        case .movie:
            state.setProgress(nil, item.mediaID, .movies)
            resume.remove(mediaID: item.mediaID)
        case .show:
            if item.reason == .resume { state.setProgress(nil, item.mediaID, .episodes) }
            ids.formUnion(resume.removeShow(item.imdbID).map { $0.mediaID })
            noteEpisodesChanged(.episodes)
        }
        post(.continueWatching, ids: ids, includeShows: false)
    }

    /// Remembers a show's guide as the provider gave it (a show page opened,
    /// an episode played): what "next up" and new episodes are worked out
    /// from without asking anyone. Only for a show the user follows, unless
    /// `always`.
    public func noteGuide(showID: String, title: String?, status: String? = nil, runtime: Int? = nil, episodes: [GuideEpisode],
                          always: Bool = false) {
        guard LibraryID.isIMDb(showID), !episodes.isEmpty else { return }
        guard always || state.isInWatchlist(showID, .shows) || !resume.entries(ofShow: showID).isEmpty else { return }
        guides.merge(ShowGuide(showID: showID, title: title, status: status, runtime: runtime, episodes: episodes, source: .provider),
                     checkedAt: nil)
    }

    // MARK: - Followed shows

    /// Shows in the watchlist, and shows with an episode watched or started
    /// within `policy.followedActivityWindow`: the latest activity first,
    /// then the watchlist's (the latest added first).
    public func followedShows() -> [FollowedShow] {
        let date = now()
        var activity: [String: (date: Date, title: String?)] = [:]
        for entry in resume.allEntries() where entry.kind == .episode {
            guard let showID = entry.showID else { continue }
            if let known = activity[showID] {
                activity[showID] = (max(known.date, entry.updatedAt), known.title ?? entry.title)
            } else {
                activity[showID] = (entry.updatedAt, entry.title)
            }
        }
        let reached = reachedEpisodes()
        let listed = watchlist(.show)
        let listedIDs = Set(listed.map { $0.imdbID })
        // Followed by activity: an episode played or marked recently enough.
        // (An older activity still dates a watchlisted show, below.)
        let recent = activity.filter { date.timeIntervalSince($0.value.date) <= policy.followedActivityWindow }
        var result = recent.sorted { a, b in a.value.date == b.value.date ? a.key < b.key : a.value.date > b.value.date }.map { showID, value in
            FollowedShow(showID: showID, title: value.title ?? guides.guide(showID)?.title, isInWatchlist: listedIDs.contains(showID),
                         lastActivity: value.date, reached: reached[showID])
        }
        for item in listed where recent[item.imdbID] == nil {
            result.append(FollowedShow(showID: item.imdbID, title: item.title.isEmpty ? nil : item.title, isInWatchlist: true,
                                       lastActivity: activity[item.imdbID]?.date, reached: reached[item.imdbID]))
        }
        return result
    }

    public func followedShowIDs() -> [String] {
        return followedShows().map { $0.showID }
    }

    /// The furthest regular episode watched or started, per show: one pass
    /// over the episode lists, kept until they change.
    private func reachedEpisodes() -> [String: EpisodeNumber] {
        lock.lock()
        if let known = reachedByShow {
            lock.unlock()
            return known
        }
        lock.unlock()
        var reached: [String: EpisodeNumber] = [:]
        func note(_ id: String) {
            guard let (showID, number) = LibraryID.episode(id), !number.isSpecial else { return }
            if let known = reached[showID], known >= number { return }
            reached[showID] = number
        }
        state.watchedSet(.episodes).forEach(note)
        for (id, progress) in state.allProgress(.episodes) where policy.isStarted(progress: progress, position: nil) { note(id) }
        lock.lock()
        reachedByShow = reached
        lock.unlock()
        return reached
    }

    // MARK: - New episodes

    /// The storage key of "ask Cinemeta about every followed show in one
    /// request" (a Bool; absent = on). Off: each show is asked from TVMaze
    /// on its own, so the list of followed shows never leaves in one piece.
    public static let bulkEpisodeLookupKey = "libraryBulkEpisodeLookup"

    public var isBulkEpisodeLookupEnabled: Bool {
        get { return (deviceStorage.object(forKey: Library.bulkEpisodeLookupKey) as? NSNumber)?.boolValue ?? true }
        set { deviceStorage.set(newValue, forKey: Library.bulkEpisodeLookupKey) }
    }

    /// The followed shows with new or upcoming episodes, from what is cached
    /// (no network: `refreshNewEpisodes` brings the airings up to date).
    /// Shows with new episodes first, the latest aired first; then shows with
    /// only upcoming ones, the soonest first.
    public func newEpisodes() -> [ShowNewEpisodes] {
        let date = now()
        let result: [ShowNewEpisodes] = followedShows().compactMap { show in
            guard let guide = guides.guide(show.showID) else { return nil }
            let airings = guide.recentAirings(now: date, policy: policy)
            let watched = Set(airings.map { $0.number }.filter { state.isWatched(LibraryID.episodeID(showID: show.showID, $0), .episodes) })
            let found = NewEpisodesRule.compute(showID: show.showID, showTitle: show.title ?? guide.title, airings: airings,
                                                reached: show.reached, lastActivity: show.lastActivity, watched: watched,
                                                acknowledgedThrough: acknowledgements.mark(show.showID), now: date, policy: policy)
            return found.isEmpty ? nil : found
        }
        return result.sorted { a, b in
            switch (a.latestAiredAt, b.latestAiredAt) {
            case let (x?, y?): return x == y ? a.showID < b.showID : x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let x = a.next?.aired ?? .distantFuture, y = b.next?.aired ?? .distantFuture
                return x == y ? a.showID < b.showID : x < y
            }
        }
    }

    /// The user saw the show's new episodes (its page or its card opened):
    /// the badge goes out until another episode airs.
    public func acknowledgeNewEpisodes(ofShow showID: String) {
        guard let guide = guides.guide(showID) else { return }
        let date = now()
        guard let latest = guide.recentAirings(now: date, policy: policy).filter({ ($0.aired ?? date) <= date }).map({ $0.number }).max(),
              acknowledgements.acknowledge(showID, through: latest) else { return }
        post(.newEpisodes, ids: [showID])
    }

    /// TVMaze is asked about at most this many shows per refresh, one after
    /// the other and this far apart (two requests each, about 20 calls per
    /// 10 s allowed).
    static let tvmazeBatch = 20
    var tvmazeSpacing: TimeInterval = 1.2

    /// Asks the airings of the followed shows whose cached ones are older
    /// than `policy.airingsLifetime` (all of them with `force`): Cinemeta's
    /// calendar, 100 shows per request; TVMaze show by show when the bulk
    /// lookup is off or Cinemeta does not answer. `completion` (main queue)
    /// says whether anything was asked.
    public func refreshNewEpisodes(force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let date = now()
        let stale = followedShowIDs().filter { showID in
            guard !force, let checked = guides.guide(showID)?.checkedAt else { return true }
            let age = date.timeIntervalSince(checked)
            return age >= policy.airingsLifetime || age < 0
        }
        lock.lock()
        let busy = isRefreshingAirings
        if !busy, !stale.isEmpty { isRefreshingAirings = true }
        lock.unlock()
        guard !busy, !stale.isEmpty else {
            if let completion = completion { DispatchQueue.main.async { completion(false) } }
            return
        }

        // The shows Cinemeta's calendar is not asked about (the bulk lookup
        // is off) or did not answer for go to TVMaze — in one chain for all
        // of them: its rate limit is the app's, not a request's.
        let group = DispatchGroup()
        let pending = NSLock()
        var unanswered = Set<String>()
        if isBulkEpisodeLookupEnabled {
            for start in stride(from: 0, to: stale.count, by: LibraryRemote.calendarBatch) {
                let batch = Array(stale[start..<min(start + LibraryRemote.calendarBatch, stale.count)])
                group.enter()
                remote.calendar(batch) { [weak self] answer in
                    if let answer = answer {
                        self?.store(airings: answer, asked: batch, at: date)
                    } else {
                        pending.lock()
                        unanswered.formUnion(batch)
                        pending.unlock()
                    }
                    group.leave()
                }
            }
        } else {
            unanswered = Set(stale)
        }
        let finish = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lock.lock()
                self.isRefreshingAirings = false
                self.lock.unlock()
                self.post(.newEpisodes, ids: Set(stale), includeShows: false)
                completion?(true)
            }
        }
        group.notify(queue: .global(qos: .utility)) { [weak self] in
            guard let self = self else { return }
            pending.lock()
            let left = stale.filter(unanswered.contains)
            pending.unlock()
            self.refreshFromTVMaze(Array(left.prefix(Library.tvmazeBatch)), at: date, completion: finish)
        }
    }

    /// A calendar answer: every show asked is now checked, answered or not
    /// (a show that ended has no airings: not asked again for 6 h either).
    private func store(airings: [ShowGuide], asked: [String], at date: Date) {
        var answered = Set<String>()
        for guide in airings {
            answered.insert(guide.showID)
            learn(guides.merge(guide, checkedAt: date))
        }
        for showID in asked where !answered.contains(showID) {
            guides.merge(ShowGuide(showID: showID, source: .cinemeta), checkedAt: date)
        }
    }

    /// One show after the other, spaced out (TVMaze's rate limit). A show
    /// TVMaze does not have is checked all the same, like one absent from
    /// Cinemeta's calendar: asked every time, it would keep one of the few
    /// places of each refresh. A show TVMaze could not be asked about is not
    /// marked checked: asked again at the next refresh.
    private func refreshFromTVMaze(_ showIDs: [String], at date: Date, completion: @escaping () -> Void) {
        guard let showID = showIDs.first else { return completion() }
        remote.tvmazeGuide(showID) { [weak self] answer in
            guard let self = self else { return completion() }
            switch answer {
            case .found(let guide): self.learn(self.guides.merge(guide, checkedAt: date))
            case .unknown: self.guides.merge(ShowGuide(showID: showID, source: .tvmaze), checkedAt: date)
            case .unreachable: break
            }
            let rest = Array(showIDs.dropFirst())
            guard !rest.isEmpty else { return completion() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.tvmazeSpacing) {
                self.refreshFromTVMaze(rest, at: date, completion: completion)
            }
        }
    }

    /// Titles and the runtime a guide brings to the resume entries that
    /// lack them.
    private func learn(_ guide: ShowGuide) {
        var titles: [EpisodeNumber: String] = [:]
        for episode in guide.episodes { if let title = episode.title { titles[episode.number] = title } }
        resume.fill(imdbID: guide.showID, title: guide.title, runtime: guide.runtime, episodeTitles: titles)
    }

    // MARK: - Hydration

    /// The titles the row cannot name yet (entries migrated from 5.2 only had
    /// ids), the shows it has no guide for, and the shows whose episode in
    /// the row is outside the few episodes known (a calendar window, empty
    /// when the calendar had nothing for the show) or has no title there:
    /// what follows that episode takes the whole guide.
    public func titlesToHydrate() -> [(imdbID: String, kind: ContinueWatchingEntry.Kind)] {
        let date = now()
        var seen = Set<String>()
        var result: [(String, ContinueWatchingEntry.Kind)] = []
        for entry in resume.allEntries() where date.timeIntervalSince(entry.updatedAt) <= policy.rowExpiry {
            var needed = entry.title == nil
            if entry.kind == .episode, !needed {
                if let guide = guides.guide(entry.imdbID) {
                    needed = !guide.isComplete && (entry.episodeTitle == nil || !(entry.number.map(guide.knowsWhatFollows) ?? true))
                } else {
                    needed = true
                }
            }
            guard needed, LibraryID.isIMDb(entry.imdbID), seen.insert(entry.imdbID).inserted else { continue }
            result.append((entry.imdbID, entry.kind))
        }
        return result
    }

    /// Fills in, from Cinemeta by IMDb id, the titles the row cannot name
    /// (most recent first) and the guides of their shows, `limit` at a time
    /// until none is left. What comes back is stored (titles with the
    /// entries, guides on disk), and `.libraryDidChange` is posted after
    /// each batch that brought something.
    ///
    /// A title Cinemeta answered about — it has it or not — is not asked
    /// again this session. One it could not be asked about (the network not
    /// up yet, a timeout) is, by the next call; a batch nobody answered ends
    /// the pass. `completion` (main queue) says whether anything changed.
    public func hydrateMissingTitles(limit: Int = 12, completion: ((Bool) -> Void)? = nil) {
        lock.lock()
        let busy = isHydrating
        isHydrating = true
        lock.unlock()
        guard !busy else {
            if let completion = completion { DispatchQueue.main.async { completion(false) } }
            return
        }
        hydrate(max(1, limit), skipping: [], changed: false, completion: completion)
    }

    /// One batch of `hydrateMissingTitles`, then the next. `skipping`: the
    /// ids that could not be asked about in this pass.
    private func hydrate(_ limit: Int, skipping: Set<String>, changed: Bool, completion: ((Bool) -> Void)?) {
        lock.lock()
        let wanted = Array(titlesToHydrate().filter { !hydrationAttempted.contains($0.imdbID) && !skipping.contains($0.imdbID) }.prefix(limit))
        if wanted.isEmpty { isHydrating = false }
        lock.unlock()
        guard !wanted.isEmpty else {
            if let completion = completion { DispatchQueue.main.async { completion(changed) } }
            return
        }
        let group = DispatchGroup()
        let results = NSLock()
        var answered = Set<String>()
        var filled = Set<String>()
        for (imdbID, kind) in wanted {
            group.enter()
            remote.title(imdbID, kind) { [weak self] answer in
                defer { group.leave() }
                guard let self = self else { return }
                var brought = false
                switch answer {
                case .unreachable:
                    return
                case .unknown:
                    break
                case .found(let found):
                    var titles: [EpisodeNumber: String] = [:]
                    if let guide = found.guide {
                        let merged = self.guides.merge(guide, checkedAt: nil)
                        for episode in merged.episodes { if let title = episode.title { titles[episode.number] = title } }
                    }
                    let named = self.resume.fill(imdbID: imdbID, title: found.title, runtime: found.runtime, episodeTitles: titles)
                    brought = named || found.guide != nil
                }
                results.lock()
                answered.insert(imdbID)
                if brought { filled.insert(imdbID) }
                results.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.hydrationAttempted.formUnion(answered)
            if answered.isEmpty { self.isHydrating = false }
            self.lock.unlock()
            if !filled.isEmpty { self.post(.continueWatching, ids: filled, includeShows: false) }
            // Nobody answered: what is left waits for the next call.
            guard !answered.isEmpty else {
                completion?(changed)
                return
            }
            self.hydrate(limit, skipping: skipping.union(wanted.map { $0.imdbID }).subtracting(answered),
                         changed: changed || !filled.isEmpty, completion: completion)
        }
    }

    // MARK: - Change notification

    /// `.libraryDidChange` on the main thread (right away when already
    /// there). `includeShows`: an episode id also names its show.
    private func post(_ reason: LibraryChange.Reason, ids: Set<String>, includeShows: Bool = true) {
        var all = ids
        if includeShows {
            for id in ids { if let (showID, _) = LibraryID.episode(id) { all.insert(showID) } }
        }
        let center = self.center
        let userInfo: [AnyHashable: Any] = [LibraryChange.idsKey: all, LibraryChange.reasonKey: reason.rawValue]
        let send = { center.post(name: .libraryDidChange, object: self, userInfo: userInfo) }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }
}
