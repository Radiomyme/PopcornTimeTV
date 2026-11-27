

import SwiftUI
import NaturalLanguage
import PopcornKit
import AVKit
import PopcornTorrent

/// The torrents found for one episode, ready to drive a quality-picker sheet.
struct EpisodeSources: Identifiable {
    let id = UUID()
    let title: String
    let torrents: [Torrent]
    /// The episode these sources play — subtitles, watched progress.
    var episode: Episode? = nil
    /// What they play when it is not an episode (a movie: « Choose another
    /// source » after a source that did not answer).
    var playMedia: Media? = nil
}

@MainActor
final class MediaDetailViewModel: ObservableObject {
    @Published var enrichedMovie: Movie?
    @Published var enrichedShow:  Show?
    @Published var loading = false
    /// Why the last load failed. The page shows it, with Retry, when it has
    /// nothing else to show (`loadFailure`).
    @Published var errorMessage: String?
    /// A load ended without the title: nothing to show but the error.
    @Published private(set) var loadFailed = false
    /// Episode torrents (EZTV) augmented with Torrentio + Time4Popcorn for
    /// the chosen episode. `nil` until augmentation finishes; a reload of the
    /// page keeps it until the new answer arrives.
    @Published var augmentedEpisodeTorrents: [Torrent]?

    /// Non-nil once an episode's sources are resolved → presents the quality
    /// picker sheet. `loadingSourcesFor` marks which episode is resolving.
    @Published var episodeSources: EpisodeSources?
    @Published var loadingSourcesFor: String?   // episode id currently fetching
    @Published var noSourcesMessage: String?

    /// The episode a show page's Play button starts: the library's "next
    /// up" (`GlassDetailAdapter.nextEpisode`, that is `Show.watchPosition()`
    /// and PopcornKit's `NextUpRule` — the answer of the Continue Watching
    /// row and of the tvOS and Mac pages): the one to resume, the next one
    /// after the last one finished, else the first of the first real season
    /// — never a season-0 special, never an episode that has not aired.
    /// Nil: nothing to play yet.
    @Published private(set) var nextEpisode: Episode?
    /// Watched marks and progress of the show's episodes, by episode id.
    @Published private(set) var episodeMarks: [String: EpisodeMark] = [:]
    /// The movie's, or the next episode's, saved progress (0…1) worth a bar
    /// under Play.
    @Published private(set) var playProgress: Double?
    @Published private(set) var isInWatchlist = false
    @Published private(set) var isMovieWatched = false

    /// Fetch a specific episode's torrents, **T4P first** then falling back to
    /// EZTV + Torrentio, and publish them for the quality picker.
    func loadEpisodeSources(_ episode: Episode, showId: String) {
        guard showId.hasPrefix("tt") else { return }
        loadingSourcesFor = episode.id
        noSourcesMessage = nil
        let base = episode.torrents   // EZTV (already attached to the episode)
        // The three extra sources behind one deadline (`EpisodeSourceResolver`):
        // the picker comes with what answered in time — a source that is
        // down no longer holds the tap for its 10 s timeout — and an answer
        // is kept for the next tap.
        // T4P primary (base of the merge), EZTV + Torrentio + TPB / Knaben
        // as fallback, the show's runtime on every candidate before the
        // merge (with their sizes it gives the bitrates, so the merge
        // keeps the releases the connection can carry and the picker
        // shows them), then sorted best-quality-first for the picker.
        let runtime = Torrent.mediaRuntime(of: episode, show: enrichedShow)
        let list: (EpisodeSourceResolver.Sources) -> [Torrent] = { sources in
            sources.merged(withBase: base, runtime: runtime).sorted(by: >)
        }
        EpisodeSourceResolver.shared.resolve(showId: showId, showTitle: episode.show?.title,
                                             season: episode.season, episode: episode.episode,
                                             // The picker needs a release to show: « No torrents
                                             // found » is only said once every source has answered.
                                             isEnough: { !list($0).isEmpty }) { [weak self] sources in
            guard let self = self else { return }
            self.loadingSourcesFor = nil
            let merged = list(sources)
            let title = "S\(episode.season)E\(episode.episode)" + (episode.title.isEmpty ? "" : " · \(episode.title)")
            if merged.isEmpty {
                self.noSourcesMessage = title + "\n" + "Torrents could not be found for the specified media.".localized
            } else {
                self.episodeSources = EpisodeSources(title: title, torrents: merged,
                                                     episode: self.playable(episode))
            }
        }
    }

    // MARK: Loading

    /// The page's load (PopcornKit's `DetailSession`): the page shows at
    /// once what its caller had of the title, the title's record fills in
    /// what is missing, and the sources arrive one by one — the page used
    /// to show a spinner until the slowest of them had answered.
    private var session: DetailSession?
    /// Related titles and people are asked once per title.
    private var extrasLoadedFor: String?
    /// The cast, crew and related titles found: put back on the title each
    /// time the session hands a new one.
    private var movieExtras: (related: [Movie], actors: [Actor], crew: [Crew]) = ([], [], [])
    private var showExtras: (related: [Show], actors: [Actor], crew: [Crew]) = ([], [], [])

    /// The sources are still searched (the "Choose Quality" list says so;
    /// Play shows a spinner until one is known).
    @Published private(set) var isSearchingSources = false
    /// Play was pressed before the sources were in: it starts when they
    /// are, and a second press cancels it.
    @Published private(set) var isPlayPending = false
    /// A show's episode list is what it will be: its guide is in, or
    /// nothing more comes. Before that the show is on the page (its record)
    /// with no episodes: a link's episode cannot be found yet.
    @Published private(set) var isGuideSettled = false

    /// The season and the episode a link names (`DeepLink.show`): the
    /// season the episode list opens on, when the show has it. Set before
    /// `load`.
    var linkedSeason: Int?
    var linkedEpisode: Int?

    /// Opens the page, or comes back to it (after a related title or the
    /// player): what the title's load has is on the page at once — an
    /// answer of the last ten minutes is not asked again (`DetailStore`).
    func load(_ media: Media) {
        // Back on the page: its load goes on, or has ended, with what the
        // page shows — a new one would start again from the grid's object
        // (and a failed reload would put the error over the page). Only a
        // failed load is asked again ("Try Again" asks it at once).
        if let session, session.id == media.id, (session.kind == .movie) == (media is Movie), session.failure == nil {
            return
        }
        errorMessage = nil
        loadFailed = false
        #if DEBUG
        // `-PTDebugDetailError`: the page's error state, without a network.
        if IOSDebugHooks.forcesDetailError {
            loading = false
            loadFailed = true
            errorMessage = "Please check your internet connection and try again.".localized
            return
        }
        IOSDebugHooks.applyDetailTamperingOnce()
        // The episode-chaining bench's made-up show (`UpNextDebugHooks`):
        // its guide and seeded local releases, never asked of a service.
        if media.id == UpNextDebugHooks.showID {
            let played = UpNextDebugHooks.episodeToPlay
            let show = UpNextDebugHooks.fakeShow(playing: played?.torrent.url, at: played.map {
                EpisodeNumber(season: $0.episode.season, episode: $0.episode.episode)
            })
            enrichedShow = show
            isGuideSettled = true
            loading = false
            refreshWatchState(of: media, reloaded: true)
            print("[UpNextDebug] the made-up show's page, offline: \(show.episodes.count) episode(s), "
                  + "Play starts \(nextEpisode.map { "S\($0.season)E\($0.episode)" } ?? "nothing")")
            return
        }
        #endif
        guard let session = DetailSession(media: media) else { return }
        self.session?.onChange = nil
        self.session = session
        if extrasLoadedFor != media.id {
            movieExtras = ([], [], [])
            showExtras = ([], [], [])
        }
        loading = true
        session.onChange = { [weak self, weak session] change in
            guard let self, let session, session === self.session else { return }
            self.apply(session, change, media: media)
        }
        session.start()
        apply(session, [.metadata, .sources, .state], media: media)
        DispatchQueue.main.async { session.noteFirstPaint() }
    }

    /// "Try Again": the same title asked again, from scratch.
    func retry(_ media: Media) {
        guard let session, session.failure != nil else { return load(media) }
        errorMessage = nil
        loadFailed = false
        loading = true
        session.retry()
    }

    /// What the session has is put on the page: the title (what the page
    /// was opened with, completed by its record, with the torrents known so
    /// far), where the search for sources stands, a failure.
    private func apply(_ session: DetailSession, _ change: DetailSession.Change, media: Media) {
        let isLoaded = session.hasRecord || session.isFinished
        if !change.isDisjoint(with: [.metadata, .sources]) {
            if var movie = session.movie {
                // A title known by its id alone (a Continue Watching card)
                // keeps the page's placeholder until its record is in.
                if isLoaded || movie.hasSummaryToShow || !movie.torrents.isEmpty {
                    movie.related = movieExtras.related
                    if !movieExtras.actors.isEmpty { movie.actors = movieExtras.actors }
                    if !movieExtras.crew.isEmpty { movie.crew = movieExtras.crew }
                    enrichedMovie = movie
                    refreshWatchState(of: media)
                }
            } else if let fresh = session.show {
                if isLoaded || fresh.hasSummaryToShow {
                    var show = fresh.linkingEpisodes()
                    show.related = showExtras.related
                    if !showExtras.actors.isEmpty { show.actors = showExtras.actors }
                    show.crew = showExtras.crew
                    let hadEpisodes = !(enrichedShow?.episodes.isEmpty ?? true)
                    enrichedShow = show
                    if session.hasGuide {
                        // A followed show's guide is what its Continue
                        // Watching card and its new episodes are worked out
                        // from; opening the page is having seen the new
                        // ones (as on tvOS and the Mac).
                        Library.shared.noteGuide(of: show)
                        if !hadEpisodes { Library.shared.acknowledgeNewEpisodes(ofShow: show.id) }
                    }
                    // Picks the episode Play starts and looks for its
                    // sources — again when EZTV's torrents arrive: they are
                    // part of its list. The same episode keeps the sources
                    // found for it until the new ones arrive.
                    refreshWatchState(of: media, reloaded: session.hasGuide)
                }
            }
            if change.contains(.metadata), session.hasRecord {
                // A title put in the watchlist before its record was in
                // (the page answers at once) gets what its entry lacked.
                if let movie = enrichedMovie {
                    WatchlistManager<Movie>.movie.complete(movie)
                } else if let show = enrichedShow {
                    WatchlistManager<Show>.show.complete(show)
                }
            }
            if isLoaded, extrasLoadedFor != media.id, session.failure == nil {
                extrasLoadedFor = media.id
                if let movie = session.movie { loadRelatedAndPeople(of: movie) }
                if let show = session.show { loadRelatedAndPeople(of: show) }
            }
        }
        let searching = session.sources.isSearching && session.failure == nil
        if isSearchingSources != searching { isSearchingSources = searching }
        if isPlayPending != session.isPressPending { isPlayPending = session.isPressPending }
        let guideSettled = session.hasGuide || session.isFinished
        if isGuideSettled != guideSettled { isGuideSettled = guideSettled }
        if let failure = session.failure {
            // Nothing to play, and a failure is why: the page says so, with
            // "Try Again" (`loadFailure`).
            enrichedMovie = nil
            enrichedShow = nil
            errorMessage = failure.localizedDescription
            loadFailed = true
        }
        let isLoading = !session.isFinished
        if loading != isLoading { loading = isLoading }
    }

    /// Play can be pressed: something to play is known, or a movie's
    /// sources are still searched (the press is kept until they are in).
    var canPressPlay: Bool {
        if !torrents.isEmpty || isPlayPending { return true }
        return enrichedMovie != nil && isSearchingSources
    }

    /// Play was pressed: `action` now when the sources are in, else once
    /// they are (`DetailSession.press`); a press while one waits cancels it.
    /// - Parameter picksAlone: a release will be played without asking.
    func pressPlay(picksAlone: Bool, _ action: @escaping () -> Void) {
        guard let session else { return action() }
        if session.isPressPending { return session.cancelPress() }
        session.press(picksAlone: picksAlone, action)
    }

    /// The page goes away: a press that waits for the sources starts nothing.
    func cancelPendingPlay() {
        session?.cancelPress()
    }

    /// Fills the related titles and cast rows from the keyless sources
    /// (YTS, Cinemeta, TVMaze); Trakt only for a connected account
    /// (`DetailExtras`).
    private func loadRelatedAndPeople(of movie: Movie) {
        DetailExtras.related(movie) { [weak self] related in
            DispatchQueue.main.async {
                guard let self, self.session?.id == movie.id else { return }
                self.movieExtras.related = related
                self.enrichedMovie?.related = related
            }
        }
        DetailExtras.people(forMediaOfType: .movies, id: movie.id) { [weak self] actors, crew in
            DispatchQueue.main.async {
                guard let self, self.session?.id == movie.id else { return }
                self.movieExtras.actors = actors
                self.movieExtras.crew = crew
                if !actors.isEmpty { self.enrichedMovie?.actors = actors }
                self.enrichedMovie?.crew = crew
            }
        }
    }

    private func loadRelatedAndPeople(of show: Show) {
        DetailExtras.related(show) { [weak self] related in
            DispatchQueue.main.async {
                guard let self, self.session?.id == show.id else { return }
                self.showExtras.related = related
                self.enrichedShow?.related = related
            }
        }
        DetailExtras.people(forMediaOfType: .shows, id: show.id) { [weak self] actors, crew in
            DispatchQueue.main.async {
                guard let self, self.session?.id == show.id else { return }
                self.showExtras.actors = actors
                self.showExtras.crew = crew
                if !actors.isEmpty { self.enrichedShow?.actors = actors }
                self.enrichedShow?.crew = crew
            }
        }
    }

    /// The episode the Play button starts: `nextEpisode`, kept in step with
    /// the sources looked up for it (`augmentedEpisodeTorrents`).
    private func targetEpisode(of show: Show) -> Episode? {
        nextEpisode
    }

    /// The reason to show when the page could not load at all.
    var loadFailure: String? {
        guard loadFailed, enrichedMovie == nil, enrichedShow == nil else { return nil }
        return errorMessage ?? "Please check your internet connection and try again.".localized
    }

    /// The season the episode list opens on: the next episode's, else the
    /// first real one (season 0, the specials, comes first in the list).
    func openingSeason(of show: Show) -> Int? {
        if let linkedSeason, show.seasonNumbers.contains(linkedSeason) { return linkedSeason }
        return nextEpisode?.season ?? GlassDetailAdapter.firstSeason(of: show)
    }

    /// Re-reads what the buttons and playback change — the watchlist, the
    /// watched marks, the progress — and moves a show's Play button to the
    /// episode that is next now. `media` stands in until the page has loaded.
    /// `reloaded`: the show was loaded again (its episodes, with their EZTV
    /// torrents, are new objects): Play's sources are looked up again.
    func refreshWatchState(of media: Media, reloaded: Bool = false) {
        if let movie = enrichedMovie ?? (media as? Movie) {
            isInWatchlist = movie.isAddedToWatchlist
            isMovieWatched = movie.isWatched
            playProgress = GlassDetailAdapter.playInfo(for: movie).progress
        } else if let show = enrichedShow {
            isInWatchlist = show.isAddedToWatchlist
            // The library's snapshot in memory (`Library`): no list decoded
            // per episode.
            let library = Library.shared
            var marks: [String: EpisodeMark] = [:]
            for episode in show.episodes {
                let watched = library.isWatched(episode.id)
                let progress = library.progress(episode.id)
                guard watched || progress > 0 else { continue }
                marks[episode.id] = EpisodeMark(isWatched: watched, progress: progress > 0.01 && progress < 0.97 ? Double(progress) : nil)
            }
            episodeMarks = marks
            let next = GlassDetailAdapter.nextEpisode(in: show)
            playProgress = next.flatMap { GlassDetailAdapter.playInfo(for: $0).progress }
            if next?.id != nextEpisode?.id {
                // Another episode is next: its own sources, not the ones
                // found for the previous one.
                nextEpisode = next
                augmentedEpisodeTorrents = nil
                augmentEpisodeTorrents(for: show)
            } else if reloaded, let next {
                // The same episode, reloaded: the list found for it stays
                // until the new answer replaces it.
                nextEpisode = next
                augmentEpisodeTorrents(for: show)
            }
        } else if let show = media as? Show {
            isInWatchlist = show.isAddedToWatchlist
        }
    }

    /// The "+" button: in or out of the watchlist (`WatchlistManager`).
    func toggleWatchlist(of media: Media) {
        if var movie = enrichedMovie ?? (media as? Movie) {
            movie.isAddedToWatchlist.toggle()
        } else if var show = enrichedShow ?? (media as? Show) {
            show.isAddedToWatchlist.toggle()
        }
        refreshWatchState(of: media)
    }

    func toggleWatched(_ episode: Episode, of media: Media) {
        WatchedlistManager<Episode>.episode.toggle(episode.id, title: (enrichedShow ?? (media as? Show)).map(TasteTitle.init(show:)))
        refreshWatchState(of: media)
    }

    func toggleMovieWatched(of media: Media) {
        guard let movie = enrichedMovie ?? (media as? Movie) else { return }
        WatchedlistManager<Movie>.movie.toggle(movie.id, title: TasteTitle(movie: movie))
        refreshWatchState(of: media)
    }

    /// EZTV carries only what its uploaders pushed, so ask Torrentio, The
    /// Pirate Bay / Knaben and the Time4Popcorn backend for the episode Play
    /// starts too and merge — through `EpisodeSourceResolver`, as the
    /// episode rows and the other apps: one deadline, and the answer is kept
    /// for the press and for the next visit of the page (a reload asks
    /// nothing again while it is fresh).
    ///
    /// Play picks a release without asking: it waits for every source still
    /// expected (a source on the resolver's bench, that has not answered
    /// lately, is not waited for), and the list is completed when a late
    /// one answers.
    private func augmentEpisodeTorrents(for show: Show) {
        guard show.id.hasPrefix("tt"), let episode = targetEpisode(of: show) else { return }
        let base = episode.torrents
        let runtime = Torrent.mediaRuntime(of: episode, show: show)
        let apply: (EpisodeSourceResolver.Sources) -> Void = { [weak self] sources in
            // Play moved to another episode meanwhile: not its sources.
            guard let self, self.nextEpisode?.id == episode.id else { return }
            // T4P primary, EZTV + Torrentio + TPB / Knaben as fallback, the
            // show's runtime on every candidate first (`Sources.merged`).
            self.augmentedEpisodeTorrents = sources.merged(withBase: base, runtime: runtime)
        }
        EpisodeSourceResolver.shared.resolve(showId: show.id, showTitle: show.title,
                                             season: episode.season, episode: episode.episode,
                                             isEnough: { $0.awaited.isEmpty },
                                             completion: apply, late: apply)
    }

    /// Sorted torrents (best quality first). For a Show, prefer the augmented
    /// episode list (EZTV + Torrentio + T4P) once ready, else the EZTV-only
    /// torrents of the first available unwatched episode.
    /// Runtimes attached: each release's bitrate (size / runtime) for the
    /// recommendation and the labels.
    var torrents: [Torrent] {
        if let movie = enrichedMovie { return movie.torrents.withMediaRuntime(of: movie).sorted(by: >) }
        if let show = enrichedShow {
            let runtime = Torrent.mediaRuntime(of: show)
            if let augmented = augmentedEpisodeTorrents { return augmented.withMediaRuntime(runtime).sorted(by: >) }
            return (targetEpisode(of: show)?.torrents ?? []).withMediaRuntime(runtime).sorted(by: >)
        }
        return []
    }

    /// What the Play button plays: the movie, or the show's target
    /// episode (subtitles are searched and progress saved for THAT episode,
    /// not for the show).
    var defaultPlaybackMedia: Media? {
        if let movie = enrichedMovie { return movie }
        if let show = enrichedShow, let episode = targetEpisode(of: show) { return playable(episode) }
        return nil
    }

    /// The episode with its show attached (OpenSubtitles searches episodes
    /// by the SHOW's imdb id).
    func playable(_ episode: Episode) -> Episode {
        var episode = episode
        if episode.show == nil { episode.show = enrichedShow }
        return episode
    }
}

/// One playback session shown in the full-screen cover. The engine is chosen
/// from the REAL payload file name (`PlaybackRouting`) once the torrent is
/// ready: MKV/WebM → remux → AVPlayer, MP4/MOV → AVPlayer directly, other
/// containers → VLC. A native engine that fails swaps `engine` to `.vlc` IN
/// PLACE (same `id`, so the cover stays up and the torrent stream is handed
/// over, not restarted).
private struct PendingPlayback: Identifiable {
    let id = UUID()
    /// The torrent's local HTTP endpoint (`PlaybackRouting.playableLocalURL`).
    let url: URL
    /// The payload on disk (still downloading) — remux input, routing name.
    let localFile: URL
    var engine: PlaybackRoute
    let title: String
    let streamer: PTTorrentStreamer?
    /// The movie or episode being played (subtitles, watched progress).
    let media: Media
    /// Release name carried the Atmos tag — signal JOC in the remux dec3 box.
    let isAtmos: Bool
    /// Release name carried HDR / DV tags (remux VIDEO-RANGE hint).
    let releaseHintsHDR: Bool
    /// 0…1 position to resume at.
    var startPosition: Float
}

/// The full-screen player for one `PendingPlayback`.
private struct PlaybackScreen: View {
    let playback: PendingPlayback
    let onFallback: (_ reason: String, _ resumeFraction: Float, _ resumeDecided: Bool) -> Void
    let onClose: () -> Void
    /// Episode chaining (5.3.0): the session of this episode's playback
    /// (nil: a movie, the last episode — the player does what it did).
    var upNext: UpNextSession? = nil
    /// « Choose Version » on the card: the next episode's releases, over
    /// the player (playback goes on behind).
    var upNextChooser: Binding<UpNextChooserRequest?> = .constant(nil)
    var onUpNextPicked: (Torrent) -> Void = { _ in }
    var onUpNextChooserDismissed: () -> Void = {}

    var body: some View {
        engine
            // A film starts, on whichever engine (remux, AVPlayer, VLC): the
            // decoded posters and backdrops are not needed while it plays,
            // their memory goes (the disk cache keeps them).
            .onAppear { ArtworkPipeline.shared.purgeMemory() }
            // The download can't keep up with this release: a lighter one at
            // the same position, or carry on (every engine reports to it).
            .overlay(alignment: .top) {
                if let monitor = PlaybackStreamContext.of(playback.streamer)?.deficit {
                    BandwidthDeficitBanner(monitor: monitor)
                }
            }
            // « Next episode »: bottom trailing, inside the safe area, above
            // AVKit's transport bar.
            .overlay(alignment: .bottomTrailing) {
                if let upNext {
                    UpNextCardOverlay(session: upNext)
                }
            }
            .sheet(item: upNextChooser, onDismiss: onUpNextChooserDismissed) { request in
                QualityPickerSheet(title: request.title, torrents: request.torrents, onSelect: onUpNextPicked)
            }
    }

    @ViewBuilder
    private var engine: some View {
        switch playback.engine {
        case .remux:
            RemuxPlayerView(localFile: playback.localFile,
                            remoteURL: playback.url,
                            title: playback.title,
                            streamer: playback.streamer,
                            media: playback.media,
                            isAtmos: playback.isAtmos,
                            releaseHintsHDR: playback.releaseHintsHDR,
                            startPosition: playback.startPosition,
                            onFallback: onFallback,
                            onClose: onClose)
                .ignoresSafeArea()
                // Audio / subtitle tracks are native HLS renditions here
                // (AVKit's own menus) — only the close button is ours.
                .overlay(alignment: .topTrailing) {
                    PlayerChromeButtons(subtitles: nil, onClose: onClose)
                }
        case .avPlayer:
            DirectPlayerScreen(playback: playback, onFallback: onFallback, onClose: onClose)
        case .vlc:
            // Resumes where the native player stopped (fallback), at the
            // saved progress the user chose to resume at (« Reprendre à … »
            // on a still-downloading MKV: VLC seeks over HTTP ranges), or at
            // the saved progress (container VLC-only from the start).
            VLCPlayerView(url: playback.url,
                          title: playback.title,
                          streamer: playback.streamer,
                          // Picked for this file (`SubtitleHashLookup.pick`).
                          subtitles: SubtitleHashLookup.pick(playback.media.subtitles, forFile: playback.localFile),
                          media: playback.media,
                          startPosition: playback.startPosition)
                .ignoresSafeArea()
        }
    }
}

/// The « next episode » card over the player (`UpNextCardView`), as long as
/// the session has one to show.
private struct UpNextCardOverlay: View {
    @ObservedObject var session: UpNextSession
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let card = session.card {
                UpNextCardView(card: card,
                               playNow: { session.accept() },
                               cancel: { session.cancel() },
                               chooseVersion: { session.chooseVersion() })
                    .padding(.trailing, 16)
                    // Above AVKit's transport bar (taller in portrait).
                    .padding(.bottom, verticalSizeClass == .compact ? 64 : 96)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.card?.kind)
        .animation(.easeInOut(duration: 0.3), value: session.card == nil)
    }
}

/// « Choose Version » on the « next episode » card: the chooser's list, the
/// release planned first.
private struct UpNextChooserRequest: Identifiable {
    let id = UUID()
    let plan: UpNextPlan

    var title: String { UpNextText.episodeTitle(plan.episode) }

    var torrents: [Torrent] {
        var list = plan.sources.sorted(by: >)
        if let planned = plan.torrent {
            list.removeAll { $0.url == planned.url }
            list.insert(planned, at: 0)
        }
        return list
    }
}

/// MP4 / M4V / MOV straight into AVPlayer, with OpenSubtitles drawn over the
/// video (a progressive file has no sidecar subtitle tracks of its own).
private struct DirectPlayerScreen: View {
    let playback: PendingPlayback
    let onFallback: (_ reason: String, _ resumeFraction: Float, _ resumeDecided: Bool) -> Void
    let onClose: () -> Void
    @StateObject private var subtitles: SubtitleCueController
    @State private var didAutoSelectSubtitle = false
    /// The OpenSubtitles moviehash of the file (`SubtitleHashLookup`): its
    /// rows switch the overlay to the subtitles made for this file.
    @State private var hashLookup: SubtitleHashLookup?

    init(playback: PendingPlayback,
         onFallback: @escaping (_ reason: String, _ resumeFraction: Float, _ resumeDecided: Bool) -> Void,
         onClose: @escaping () -> Void) {
        self.playback = playback
        self.onFallback = onFallback
        self.onClose = onClose
        _subtitles = StateObject(wrappedValue: SubtitleCueController(subtitles: playback.media.subtitles,
                                                                     releaseNames: SubtitleFileContext.releaseNames(ofFile: playback.localFile)))
    }

    var body: some View {
        let streamer = playback.streamer
        let cues = subtitles
        ZStack {
            VideoPlayerWrapper(url: PlaybackRouting.playableLocalURL(playback.url, fileName: playback.localFile.lastPathComponent),
                               title: playback.title,
                               media: playback.media,
                               startPosition: playback.startPosition,
                               // Completion only (1.0): at 0.999 up to 0.1 % is still missing.
                               // Also lets a starved player wait for more data.
                               downloadProgress: { streamer?.torrentStatus.totalProgress ?? 1 },
                               // The whole file on disk (bounded storage: never once a
                               // piece was deleted), and the stream's bounded storage.
                               boundedStorage: BoundedStorageSession.session(for: streamer),
                               isPayloadComplete: { streamer?.isWholeFileOnDisk ?? true },
                               onPlayerReady: { player in
                                   // Not during the view update that created it.
                                   DispatchQueue.main.async { cues.attach(to: player) }
                               },
                               onItemReplaced: { item in
                                   // Rebuilt after download starvation: the overlay
                                   // coordinates with the new item's own subtitles.
                                   cues.bindNativeSubtitles(of: item)
                               },
                               onFallback: onFallback,
                               onCannotContinue: onClose,
                               deficitMonitor: PlaybackStreamContext.of(streamer)?.deficit)
                .ignoresSafeArea()
            SubtitleOverlayText(controller: subtitles)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            PlayerChromeButtons(subtitles: subtitles, onClose: onClose)
        }
        .onAppear {
            subtitles.loadSubtitlesIfNeeded(for: playback.media)
            if hashLookup == nil,
               let lookup = SubtitleHashLookup.make(file: playback.localFile, streamer: playback.streamer, media: playback.media) {
                lookup.onMatches = { [weak subtitles] rows in subtitles?.applyMovieHashMatches(rows) }
                hashLookup = lookup
                lookup.start()
            }
        }
        // Preferred subtitle language, once the list is known. `$available`
        // fires before the property changes — hop a turn.
        .onReceive(subtitles.$available.receive(on: DispatchQueue.main)) { list in
            guard !didAutoSelectSubtitle, !list.isEmpty else { return }
            didAutoSelectSubtitle = true
            if subtitles.selected == nil { subtitles.autoSelectPreferred() }
        }
        .onDisappear {
            subtitles.detach()
            hashLookup?.stop()
            hashLookup = nil
        }
    }
}

/// Close button (+ subtitle menu on the direct path) over AVKit's controls —
/// an AVPlayerViewController embedded in a SwiftUI cover has no "Done"
/// button of its own. Fades out of the way after a few seconds but stays
/// tappable.
private struct PlayerChromeButtons: View {
    let subtitles: SubtitleCueController?
    let onClose: () -> Void
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: 12) {
            if let subtitles = subtitles {
                SubtitleMenuButton(controller: subtitles)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.top, 8)
        .padding(.trailing, 16)
        .opacity(dimmed ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.4), value: dimmed)
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            dimmed = true
        }
    }
}

struct MediaDetailView: View {
    let media: Media
    /// The season and the episode a link names (`DeepLink.show`): the
    /// season the episode list opens on, when the show has it. A
    /// `request`'s season and episode count as these when they are nil.
    var linkedSeason: Int? = nil
    var linkedEpisode: Int? = nil
    /// What the page is opened for besides showing itself (the Home's
    /// Continue Watching cards and Play, a popcorntime:// link): see
    /// `runRequest`.
    var request = MediaPageRequest()
    /// `request` was acted on: once per page.
    @State private var didRunRequest = false
    /// A link to this page while it was on top (`AppRouter.open(url:)`):
    /// acted on in place of `request`.
    @State private var handedRequest: MediaPageRequest?
    /// Names this page to the router (`AppRouter.pageAppeared`).
    @State private var pageToken = UUID()
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.mediaStackTab) private var stackTab
    @StateObject private var viewModel = MediaDetailViewModel()
    @State private var pendingPlayback: PendingPlayback?
    @State private var startingStream = false
    /// The player's cover is on screen, until its dismissal is over
    /// (`onDismiss`): `pendingPlayback` is cleared as it starts to go.
    @State private var isCoverUp = false
    @State private var bufferProgress: Float = 0
    @State private var seedsCount: Int = 0
    @State private var peersCount: Int = 0
    @State private var downloadKbps: Double = 0
    @State private var streamErrorMessage: String?
    /// The stream failed because the torrent lacks the episode (a season
    /// pack, PopcornTorrent -9): the overlay offers another source.
    @State private var streamFailedNotInTorrent = false
    /// Bounded storage (the film is larger than the free space): the
    /// overlay's « Limited storage: you can rewind about N min » line, and
    /// when it was last computed (it reads the free space).
    @State private var boundedNote: String?
    @State private var boundedNoteAt: TimeInterval = 0
    /// The stream's preparation (`LoadingPhaseTracker`): the overlay's line
    /// from the first second, and the « source not answering » state.
    @State private var loadingTracker = LoadingPhaseTracker()
    @State private var loadingPhase: LoadingPhase = .starting
    @State private var loadingLine = LoadingPhase.starting.line
    @State private var loadingStreamer: PTTorrentStreamer?
    /// Buffering, but minutes from playing (`LoadingPhaseTracker.isSlow`).
    @State private var loadingSlow = false
    /// What the overlay prepares: « Choose another source » leaves it out.
    @State private var loadingSource: StreamSource?
    /// « Lighter version »: played once the cover is gone (`endPlayback`).
    @State private var pendingSwitch: PendingSwitch?
    /// Episode chaining (5.3.0): the session of the episode playing; the
    /// next episode, played once the cover is gone (`endPlayback`, as
    /// `pendingSwitch`); today's flow for it instead (the episode's sources
    /// and chooser), also once the cover is gone; the card's « Choose
    /// Version » list over the player, and the release picked in it.
    @State private var upNext: UpNextSession?
    @State private var pendingNext: UpNextPlan?
    @State private var pendingNextFallback: Episode?
    @State private var upNextChooser: UpNextChooserRequest?
    @State private var upNextPicked: Torrent?
    /// When the stream being prepared started (D5: a remembered release that
    /// does not answer), and whether that wait already brought the choice up.
    @State private var loadingStartedAt: TimeInterval = 0
    @State private var rememberedStalled = false
    @State private var safariURL: IdentifiableURL?
    /// The season the episode list shows: `openingSeason` once the show has
    /// loaded and after the player closes (the next episode's), else the one
    /// picked in the menu. Nil before the show has loaded. Not 0: that is
    /// the specials' season. Set, not derived from the next episode at each
    /// redraw: marking the season's last episode watched would move the
    /// list to the next season under the finger.
    @State private var selectedSeason: Int?
    /// The hero shows the title's logo: the text title is left out.
    @State private var heroShowsLogo = false
    /// The whole list of a movie's sources (it opens on the best three).
    @State private var showsAllSources = false
    /// The page scrolled past its hero: the top bar gets a background and
    /// the title.
    @State private var scrolledPastHero = false
    /// A stream asked for on cellular data while the setting is off
    /// (`CellularStreamingPolicy`): played if the user turns it on.
    @State private var cellularRequest: PlayRequest?
    /// The English synopsis opened in full ("Plus").
    @State private var showsWholeSynopsis = false
    /// The synopsis's height on three lines, and whole: "Plus" shows when
    /// the three lines cut it, whatever its length in characters.
    @State private var synopsisShownHeight: CGFloat = 0
    @State private var synopsisWholeHeight: CGFloat = 0
    @AppStorage("autoSelectQuality") private var autoQuality = "Balanced"
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        GeometryReader { proxy in
            let hero = heroSize(in: proxy.size)
            let topInset = proxy.safeAreaInsets.top
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 20) {
                        MediaDetailHero(media: media, size: hero, showsLogo: $heroShowsLogo)
                        VStack(alignment: .leading, spacing: 20) {
                            actionRow
                            summary
                            if viewModel.enrichedMovie != nil {
                                movieTorrentList
                            } else if let show = viewModel.enrichedShow, !show.episodes.isEmpty {
                                seasonEpisodeSection(show)
                            }
                        }
                        // A reading width on an iPad; the full width on an iPhone.
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity)
                        // The rows that scroll sideways run to the screen's
                        // edge, their cards starting on the text's edge.
                        let inset = (proxy.size.width - min(proxy.size.width, 792)) / 2 + 16
                        castSection(inset: inset)
                        relatedSection(inset: inset)
                    }
                    .padding(.bottom, 32)
                }
                // The system's own edge effect would blur the top of the
                // hero under the status bar; the page draws its bar
                // background itself once the hero is gone (below).
                .scrollEdgeEffectHidden(true, for: .top)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y > hero.height - topInset - 12
                } action: { _, past in
                    withAnimation(.easeInOut(duration: 0.2)) { scrolledPastHero = past }
                }
                // Past the hero the text would run under the clock and the back
                // button: a bar's background there, fading out at its bottom.
                Rectangle()
                    .fill(.bar)
                    .frame(height: topInset + 14)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black, location: 0.75),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .opacity(scrolledPastHero ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // The hero runs under the navigation bar, up to the screen's edge.
            .ignoresSafeArea(.container, edges: .top)
        }
        .navigationTitle(media.title)
        .navigationBarTitleDisplayMode(.inline)
        // Over the hero the title is its logo, or the text right under it;
        // the bar only names the page once the hero has scrolled away.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(verbatim: viewModel.enrichedMovie?.title ?? viewModel.enrichedShow?.title ?? media.title)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(scrolledPastHero ? 1 : 0)
                    .accessibilityHidden(!scrolledPastHero)
            }
        }
        .task {
            viewModel.linkedSeason = linkedSeason ?? request.season
            viewModel.linkedEpisode = linkedEpisode ?? request.episode
            // « Vos langues »: the release lists sort for this title's type.
            PlaybackLanguagePreferences.focusTitle(media)
            viewModel.load(media)
        }
        .onAppear {
            viewModel.refreshWatchState(of: media)
            if let stackTab { router?.pageAppeared(pageToken, media: media, in: stackTab) { reopen($0) } }
        }
        // A press that waits for the sources starts nothing on a page that
        // was left.
        .onDisappear {
            viewModel.cancelPendingPlay()
            if let stackTab { router?.pageDisappeared(pageToken, in: stackTab) }
            // A page that leaves with no player up holds no link back.
            if !isPlayerUp { router?.playerChanged(pageToken, isUp: false) }
        }
        // A link that arrives while this page prepares a stream or shows
        // the player waits until both are over (`AppRouter.playerChanged`).
        .onChange(of: isPlayerUp) { _, up in router?.playerChanged(pageToken, isUp: up) }
        .onChange(of: pendingPlayback != nil) { _, shown in if shown { isCoverUp = true } }
        // The episode list opens on the next episode's season, once.
        .onChange(of: viewModel.enrichedShow?.id) { _, _ in
            guard selectedSeason == nil, let show = viewModel.enrichedShow else { return }
            selectedSeason = viewModel.openingSeason(of: show)
        }
        // A mark or a position saved elsewhere (another device through
        // Trakt, the Continue Watching row): the marks and Play follow. Not
        // while the player is up: it saves its position as it plays, and
        // its close refreshes everything.
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { notification in
            guard pendingPlayback == nil else { return }
            let ids = LibraryChange.ids(of: notification)
            guard ids.isEmpty || ids.contains(media.id) else { return }
            viewModel.refreshWatchState(of: media)
        }
        .fullScreenCover(item: $pendingPlayback, onDismiss: {
            // The user left the player (nothing starts); nothing at all when
            // the session already started the next episode or fell back.
            upNext?.playerClosed()
            upNext = nil
            upNextChooser = nil
            upNextPicked = nil
            endPlayback()
            // After `endPlayback`: a « Lighter version » it starts keeps
            // the page busy.
            isCoverUp = false
            // The player saved how far it got: the marks, the progress and
            // the episode Play starts next — and the list follows it.
            viewModel.refreshWatchState(of: media)
            if let show = viewModel.enrichedShow, let season = viewModel.openingSeason(of: show) {
                selectedSeason = season
            }
        }) { item in
            // Read the live state: a fallback mutates the engine in place.
            PlaybackScreen(playback: pendingPlayback ?? item,
                           onFallback: { reason, resumeFraction, resumeDecided in
                               handOffToVLC(reason: reason, resumeFraction: resumeFraction, resumeDecided: resumeDecided)
                           },
                           onClose: {
                               // At once: no countdown may start the next
                               // episode while the cover goes down.
                               upNext?.playerClosed()
                               pendingPlayback = nil
                           },
                           upNext: upNext,
                           upNextChooser: $upNextChooser,
                           onUpNextPicked: { torrent in
                               upNextPicked = torrent
                               upNextChooser = nil
                           },
                           onUpNextChooserDismissed: {
                               // After the sheet is gone: a pick closes the cover.
                               let picked = upNextPicked
                               upNextPicked = nil
                               if let picked { upNext?.chose(picked) } else { upNext?.choiceCancelled() }
                           })
        }
        .sheet(item: $safariURL) { item in
            SafariSheet(url: item.url)
                .ignoresSafeArea()
        }
        .sheet(item: $viewModel.episodeSources) { sources in
            QualityPickerSheet(title: sources.title, torrents: sources.torrents) { torrent in
                viewModel.episodeSources = nil
                requestPlay(torrent, media: sources.episode ?? sources.playMedia ?? media, sources: sources.torrents)
            }
        }
        .alert("No torrents found",
               isPresented: Binding(get: { viewModel.noSourcesMessage != nil },
                                    set: { if !$0 { viewModel.noSourcesMessage = nil } })) {
            Button("OK", role: .cancel) { viewModel.noSourcesMessage = nil }
        } message: {
            Text(verbatim: viewModel.noSourcesMessage ?? "")
        }
        .alert("Cellular Data is turned off for streaming",
               isPresented: Binding(get: { cellularRequest != nil },
                                    set: { if !$0 { cellularRequest = nil } })) {
            Button("Turn On") {
                guard let request = cellularRequest else { return }
                cellularRequest = nil
                CellularStreamingPolicy.allow()
                play(request.torrent, media: request.media, sources: request.sources, startOverride: request.startOverride,
                     rememberedID: request.rememberedID)
            }
            Button("Cancel", role: .cancel) { cellularRequest = nil }
        }
        .overlay { streamingOverlay }
        // A page opened to play, or on a season: once it knows enough.
        .onChange(of: requestTrigger, initial: true) { _, _ in runRequest() }
        #if DEBUG
        // `-PTDebugPressPlay`: Play, once the sources are known and only
        // when it cannot start a stream (the cellular question or the
        // "Always Ask" quality sheet comes up instead).
        .onChange(of: viewModel.torrents.isEmpty) { _, isEmpty in
            guard !isEmpty, IOSDebugHooks.pressesPlay, viewModel.episodeSources == nil, cellularRequest == nil else { return }
            let asksFirst = CellularStreamingPolicy.decision(isExpensive: NetworkPathObserver.shared.isExpensive) == .askFirst
            // The made-up show of the episode-chaining bench plays local
            // .torrent files only (`UpNextDebugHooks`): its Play may start one.
            guard autoQuality.isEmpty || asksFirst || media.id == UpNextDebugHooks.showID else {
                print("[iOSDebug] Play not pressed: it would start a stream")
                return
            }
            playFirstAvailable()
        }
        .onChange(of: viewModel.loading) { _, loading in
            guard !loading, IOSDebugHooks.seedsWatchlist, !viewModel.isInWatchlist else { return }
            viewModel.toggleWatchlist(of: media)
        }
        // `-PTDebugPlayTorrent <file>` (BoundedStorageDebugHooks) on the page
        // of the placeholder movie (`-PTDebugOpenMovie tt0000000`): that
        // local .torrent plays through the page's normal flow — the offline
        // end-to-end runs, as on tvOS and the Mac.
        .task {
            guard let file = BoundedStorageDebugHooks.torrentFile, media.id == "tt0000000",
                  pendingPlayback == nil, !startingStream else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            print("[BoundedDebug] playing \(file)")
            play(Torrent(url: file, quality: "1080p"), media: Movie(title: "Bounded storage test", id: "tt0000000"))
        }
        // `-PTDebugPlayEpisode S01E01` with `-PTDebugPlayTorrent <file>` on
        // the made-up show's page (`-PTDebugOpenShow tt0000001`, offline:
        // `MediaDetailViewModel.load`): that episode plays from the local
        // .torrent through the page's normal flow (episode chaining bench).
        .task {
            guard media.id == UpNextDebugHooks.showID, let (episode, torrent) = UpNextDebugHooks.episodeToPlay,
                  pendingPlayback == nil, !startingStream else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            print("[UpNextDebug] playing S\(episode.season)E\(episode.episode) from \(torrent.url)")
            play(torrent, media: episode, sources: episode.torrents)
        }
        #endif
    }

    /// A stream is being prepared, or the player is on screen.
    private var isPlayerUp: Bool { startingStream || pendingPlayback != nil || isCoverUp }

    /// What `runRequest` waits for: the show and its guide (a season, an episode), then
    /// the sources Play picks from — for a show, the list completed by every
    /// source still expected, the one a tap on Play would wait for.
    private var requestTrigger: [Bool] {
        [viewModel.enrichedShow != nil, viewModel.isGuideSettled, !viewModel.torrents.isEmpty,
         viewModel.augmentedEpisodeTorrents != nil, viewModel.canPressPlay]
    }

    /// Acts on `request`, once. A season: the episode list opens on it. To
    /// play: what a tap would do, on the same path and behind the same
    /// questions (cellular data, "Always Ask") — the episode's row when the
    /// link names one (its sources sheet; nothing when the show has no such
    /// episode), else the Play button.
    private func runRequest() {
        let request = handedRequest ?? self.request
        guard !didRunRequest, request != MediaPageRequest() else { return }
        if media is Show {
            // The page shows the show from its record, before its guide:
            // the season and the episode are looked for once it is in.
            guard let show = viewModel.enrichedShow, viewModel.isGuideSettled else { return }
            if let season = request.season, show.episodes.contains(where: { $0.season == season }) { selectedSeason = season }
            if request.autoPlay, let season = request.season, let number = request.episode {
                didRunRequest = true
                if let episode = show.episodes.first(where: { $0.season == season && $0.episode == number }) {
                    viewModel.loadEpisodeSources(episode, showId: show.id)
                }
                return
            }
            guard request.autoPlay else { didRunRequest = true; return }
            guard viewModel.augmentedEpisodeTorrents != nil else { return }
        }
        // A movie's sources may still be searched: the press is kept, as a
        // tap on Play keeps it (`pressPlay`, the page's one-step open).
        guard request.autoPlay, viewModel.canPressPlay else { return }
        didRunRequest = true
        // A link (`MediaPageRequest.fromLink`) never picks alone: the
        // quality sheet comes up, the user chooses what plays.
        let picksAlone = request.picksAlone(automaticQuality: !autoQuality.isEmpty)
        viewModel.pressPlay(picksAlone: picksAlone) {
            #if DEBUG
            // A verification launch never starts a stream by itself: Play is
            // pressed only when a question comes up instead (as `-PTDebugPressPlay`).
            let asksFirst = CellularStreamingPolicy.decision(isExpensive: NetworkPathObserver.shared.isExpensive) == .askFirst
            if IOSDebugHooks.isActive, picksAlone, !asksFirst {
                print("[iOSDebug] Play not pressed for the page's request: it would start a stream")
                return
            }
            #endif
            // A link never replays a remembered release either.
            playFirstAvailable(alwaysAsks: !picksAlone, replaysRemembered: !request.fromLink)
        }
    }

    /// A link to this page while it is on top: its season opens, and a
    /// `play` link plays (`runRequest`), as on a page it had opened.
    private func reopen(_ link: MediaPageRequest) {
        if link.season != nil {
            viewModel.linkedSeason = link.season
            viewModel.linkedEpisode = link.episode
        }
        handedRequest = link
        didRunRequest = false
        runRequest()
    }

    /// The hero's size: the full width; 3:4 of it on an iPhone in portrait
    /// (a 16:9 strip under the navigation bar would be a sliver), at most
    /// about half the screen on an iPad or in landscape.
    private func heroSize(in container: CGSize) -> CGSize {
        let height = horizontalSizeClass == .compact && container.height > container.width
            ? container.width * 0.75
            : min(container.width * 9 / 16, container.height * 0.55)
        return CGSize(width: container.width, height: max(height, 180))
    }

    /// Season picker + episode list. Tapping an episode resolves its sources
    /// (T4P first, then EZTV/Torrentio) and presents the quality picker; an
    /// episode that has not aired yet cannot be tapped.
    @ViewBuilder
    private func seasonEpisodeSection(_ show: Show) -> some View {
        let season = selectedSeason ?? viewModel.openingSeason(of: show) ?? show.seasonNumbers.first ?? 1
        let episodes = show.episodes.filter { $0.season == season }.sorted { $0.episode < $1.episode }

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodes").font(.headline)
                Spacer()
                if show.seasonNumbers.count > 1 {
                    Picker("Season", selection: Binding(get: { season }, set: { selectedSeason = $0 })) {
                        ForEach(show.seasonNumbers, id: \.self) { s in
                            Text("Season \(s)").tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            ForEach(episodes, id: \.id) { episode in
                let mark = viewModel.episodeMarks[episode.id]
                Button {
                    viewModel.loadEpisodeSources(episode, showId: show.id)
                } label: {
                    EpisodeRow(episode: episode,
                               mark: mark,
                               isLoading: viewModel.loadingSourcesFor == episode.id,
                               isNext: viewModel.nextEpisode?.id == episode.id)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.loadingSourcesFor != nil || !episode.isAvailableToPlay)
                .contextMenu {
                    Button {
                        viewModel.toggleWatched(episode, of: media)
                    } label: {
                        if mark?.isWatched == true {
                            Label("Mark as Unwatched", systemImage: "eye.slash")
                        } else {
                            Label("Mark as Watched", systemImage: "eye")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var streamingOverlay: some View {
        if startingStream {
            VStack(spacing: 14) {
                if loadingPhase.isBuffering {
                    ProgressView(value: Double(bufferProgress))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .frame(width: 240)
                } else if !loadingPhase.isNotResponding && streamErrorMessage == nil {
                    ProgressView()
                }
                // From the first second: peers, the torrent's details,
                // buffering — or that the source is not answering. Not under
                // a failure (the line stopped where the stream did).
                if streamErrorMessage == nil {
                    Text(loadingLine)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                if seedsCount > 0 || peersCount > 0 {
                    Text(verbatim: [String(format: "Sources.Seeds".localized, seedsCount),
                                   String(format: "Sources.Peers".localized, peersCount),
                                   formatKbps(downloadKbps)].joined(separator: " · "))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let note = boundedNote, streamErrorMessage == nil {
                    Label(note, systemImage: BoundedStorageUX.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let err = streamErrorMessage {
                    Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal, 8)
                    // A season pack without the episode: the title's other releases.
                    if streamFailedNotInTorrent, !otherSources.isEmpty {
                        Button(LoadingPhase.chooseAnotherSourceTitle) { chooseAnotherSource() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if loadingPhase.isNotResponding || rememberedStalled, streamErrorMessage == nil {
                    if !otherSources.isEmpty {
                        Button(LoadingPhase.chooseAnotherSourceTitle) { chooseAnotherSource() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(LoadingPhase.keepWaitingTitle) { keepWaiting() }
                        .buttonStyle(.bordered)
                } else if loadingSlow, streamErrorMessage == nil, !otherSources.isEmpty {
                    // Alive but minutes from playing: another source,
                    // beside the progress.
                    Button(LoadingPhase.chooseAnotherSourceTitle) { chooseAnotherSource() }
                        .buttonStyle(.bordered)
                }
                Button("Cancel", role: .cancel) { cancelStream() }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 24)
            // The stall rules need the clock even when no status comes.
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                guard startingStream, streamErrorMessage == nil, let streamer = loadingStreamer else { return }
                updateLoadingPhase(streamer: streamer, fromCallback: false)
                checkRememberedPatience()
            }
            #if DEBUG
            .onChange(of: loadingPhase.isNotResponding) { _, stalled in
                guard stalled else { return }
                BandwidthDebugHooks.loadingStalled(choose: otherSources.isEmpty ? nil : { chooseAnotherSource() },
                                                   keepWaiting: { keepWaiting() })
            }
            #endif
        }
    }

    /// D5: a remembered release replayed without asking (« Resume ») that
    /// has no peer after `UpNextResume.patience` (20 s, not 45 s): « Choose
    /// another source » / « Keep waiting » come up.
    private func checkRememberedPatience() {
        guard !rememberedStalled, let source = loadingSource, source.rememberedID != nil, !loadingPhase.isNotResponding,
              ProcessInfo.processInfo.systemUptime - loadingStartedAt >= UpNextResume.patience,
              seedsCount == 0, peersCount == 0, bufferProgress == 0 else { return }
        rememberedStalled = true
        print("[UpNext] resume: the remembered release has no peer after \(Int(UpNextResume.patience)) s — "
              + "« Choose another source » offered")
    }

    /// The loading phase from the stream (progress block, 1 s timer).
    private func updateLoadingPhase(streamer: PTTorrentStreamer, fromCallback: Bool) {
        guard startingStream, streamer === loadingStreamer else { return }
        loadingPhase = loadingTracker.update(streamer: streamer, fromCallback: fromCallback)
        loadingLine = loadingTracker.line
        loadingSlow = loadingTracker.isSlow
    }

    /// « Keep waiting »: the message goes, every stall rule counts again.
    private func keepWaiting() {
        // D5 asked once: the usual rules from now on.
        if rememberedStalled, let source = loadingSource {
            rememberedStalled = false
            loadingSource = StreamSource(torrent: source.torrent, media: source.media, sources: source.sources)
        }
        loadingTracker.keepWaiting()
        loadingPhase = loadingTracker.phase
        loadingLine = loadingTracker.line
    }

    /// The title's other releases (the source being prepared left out).
    private var otherSources: [Torrent] {
        guard let source = loadingSource else { return [] }
        return source.sources.filter { $0.url != source.torrent.url }
    }

    /// « Choose another source » (a source that does not answer): this
    /// stream stops and the quality picker comes back without it.
    private func chooseAnotherSource() {
        guard let source = loadingSource else { return }
        if let id = source.rememberedID { forgetRemembered(id, url: source.torrent.url, reason: "« Choose another source »") }
        let others = otherSources.sorted(by: >)
        print("[iOS Detail] choose another source (instead of \(source.torrent.quality ?? "?"))")
        cancelStream()
        guard !others.isEmpty else { return }
        let episode = source.media as? Episode
        let title = episode.map { "S\($0.season)E\($0.episode)" + ($0.title.isEmpty ? "" : " · \($0.title)") } ?? source.media.title
        viewModel.episodeSources = EpisodeSources(title: title, torrents: others, episode: episode,
                                                  playMedia: episode == nil ? source.media : nil)
    }

    private func formatKbps(_ kbps: Double) -> String {
        if kbps >= 1024 { return String(format: "%.1f MB/s", kbps / 1024) }
        return String(format: "%.0f KB/s", kbps)
    }

    private func cancelStream() {
        PTTorrentStreamer.cancelCurrent(deleteData: true)
        // Also the next episode waiting for the cover to go down.
        pendingNext = nil
        pendingNextFallback = nil
        rememberedStalled = false
        startingStream = false
        loadingStreamer = nil
        bufferProgress = 0
        seedsCount = 0
        peersCount = 0
        downloadKbps = 0
        streamErrorMessage = nil
        streamFailedNotInTorrent = false
        boundedNote = nil
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                // Before the sources are in, the press is kept and starts
                // when they are; a second press cancels it.
                viewModel.pressPlay(picksAlone: !autoQuality.isEmpty) { playFirstAvailable() }
            } label: {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        if viewModel.isPlayPending || (viewModel.isSearchingSources && viewModel.torrents.isEmpty) {
                            // The sources are still searched.
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        if viewModel.isPlayPending {
                            Text("Cancel")
                        } else {
                            // Partly watched: Play resumes, and says so.
                            if viewModel.playProgress != nil { Text("Resume") } else { Text("Play") }
                            // A show: which episode Play starts.
                            if let episode = viewModel.nextEpisode {
                                Text("S\(episode.season) · E\(episode.episode)")
                                    .fontWeight(.regular)
                            }
                        }
                    }
                    .font(.headline)
                    if let progress = viewModel.playProgress, !viewModel.isPlayPending {
                        // Partly watched: where Play resumes, and what is left.
                        HStack(spacing: 6) {
                            GlassProgressBar(progress: progress, height: 4, tint: .white)
                                .frame(width: 56)
                            if let left = remainingText(progress: progress) {
                                Text(verbatim: left)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                        }
                    }
                }
                .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : 300, minHeight: 36)
            }
            .glassActionStyle(prominent: true)
            .disabled(!viewModel.canPressPlay)
            .accessibilityIdentifier("Detail.Play")

            if let trailerURL = trailerURL {
                Button {
                    safariURL = IdentifiableURL(url: trailerURL)
                } label: {
                    Image(systemName: "play.rectangle")
                        .font(.title3)
                        .frame(width: 30, height: 36)
                }
                .glassActionStyle()
                .accessibilityLabel(Text("Trailer"))
            }

            Button {
                viewModel.toggleWatchlist(of: media)
            } label: {
                Image(systemName: viewModel.isInWatchlist ? "checkmark" : "plus")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 36)
            }
            .glassActionStyle()
            .accessibilityLabel(viewModel.isInWatchlist ? Text("Remove from Watchlist") : Text("Add to Watchlist"))
            .accessibilityIdentifier("Detail.Watchlist")

            if media is Movie {
                Button {
                    viewModel.toggleMovieWatched(of: media)
                } label: {
                    Image(systemName: viewModel.isMovieWatched ? "eye.fill" : "eye")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30, height: 36)
                }
                .glassActionStyle()
                .accessibilityLabel(viewModel.isMovieWatched ? Text("Mark as Unwatched") : Text("Mark as Watched"))
            }

            if horizontalSizeClass != .compact { Spacer(minLength: 0) }
        }
    }

    /// Build a YouTube watch URL from the YTS `yt_trailer_code` if available
    /// on the enriched movie. We send the user to Safari (or
    /// SFSafariViewController) rather than embedding XCDYouTubeKit — that
    /// pod's iOS-8 deployment target broke under Xcode 26's libarclite
    /// removal, and Safari handles AirPlay / picture-in-picture for free.
    private var trailerURL: URL? {
        if let movie = viewModel.enrichedMovie ?? (media as? Movie),
           let raw = movie.trailer, !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return nil
    }

    @ViewBuilder
    private var summary: some View {
        if let movie = viewModel.enrichedMovie {
            VStack(alignment: .leading, spacing: 8) {
                if !heroShowsLogo {
                    Text(verbatim: movie.title).font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                }
                factsLine(metadataLine(year: movie.year, runtime: movie.runtime, certification: movie.certification),
                          rating: movie.rating, imdbId: movie.id)
                formatChips(imdbId: movie.id, torrents: viewModel.torrents)
                synopsis(movie.summary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let show = viewModel.enrichedShow {
            VStack(alignment: .leading, spacing: 8) {
                if !heroShowsLogo {
                    Text(verbatim: show.title).font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                }
                factsLine("\(show.year)\(show.network.map { " · \($0)" } ?? "")", rating: show.rating, imdbId: show.id)
                synopsis(show.summary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let failure = viewModel.loadFailure {
            // The page could not load: say why, and offer to try again.
            ContentUnavailableView {
                Label("Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: failure)
            } actions: {
                Button("Try Again") { viewModel.retry(media) }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("Detail.LoadError")
        } else {
            // Loading: the title the grid already knows, then a spinner.
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: media.title).font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView().frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var movieTorrentList: some View {
        if !viewModel.torrents.isEmpty || viewModel.isSearchingSources {
            let recommended = Torrent.recommendedURL(in: viewModel.torrents)
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose Quality").font(.headline)
                ForEach(shownSources(recommended: recommended), id: \.url) { torrent in
                    Button {
                        requestPlay(torrent, media: viewModel.enrichedMovie ?? media, sources: viewModel.torrents)
                    } label: {
                        SourceRow(torrent: torrent, recommended: torrent.url == recommended)
                            .glassSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), fallback: .regularMaterial)
                    }
                    .buttonStyle(.plain)
                }
                // The best three first; the rest on demand.
                if viewModel.torrents.count > Self.sourcesShown {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { showsAllSources.toggle() }
                    } label: {
                        HStack {
                            Text(verbatim: showsAllSources
                                 ? "Sources.ShowFewer".localized
                                 : String(format: "Sources.ShowAll".localized, viewModel.torrents.count))
                            Spacer()
                            Image(systemName: showsAllSources ? "chevron.up" : "chevron.down")
                                .font(.footnote.weight(.semibold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("Detail.AllSources")
                }
                // The sources answer one by one: the list grows, and says
                // while others are still searched.
                if viewModel.isSearchingSources {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Sources.Loading")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("Detail.SearchingSources")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.25), value: viewModel.torrents.count)
        }
    }

    @ViewBuilder
    private func castSection(inset: CGFloat) -> some View {
        if let movie = viewModel.enrichedMovie {
            DetailCastRow(directors: directorNames(movie.crew), actors: movie.actors, inset: inset)
        } else if let show = viewModel.enrichedShow {
            DetailCastRow(directors: directorNames(show.crew), actors: show.actors, inset: inset)
        }
    }

    @ViewBuilder
    private func relatedSection(inset: CGFloat) -> some View {
        if let movie = viewModel.enrichedMovie, !movie.related.isEmpty {
            DetailRelatedRow(items: movie.related, inset: inset)
        } else if let show = viewModel.enrichedShow, !show.related.isEmpty {
            DetailRelatedRow(items: show.related, inset: inset)
        }
    }

    private func directorNames(_ crew: [Crew]) -> [String] {
        var seen = Set<String>()
        return crew.filter { $0.roleType == .director }.map(\.name).filter { seen.insert($0).inserted }
    }

    /// "2026 · 2 h 25 min · -12": the durations as the Home writes them,
    /// the age rating as the user's country writes it.
    private func metadataLine(year: String, runtime: Int, certification: String) -> String {
        var parts: [String] = []
        if !year.isEmpty           { parts.append(year) }
        if let runtime = HomeCardText().duration(minutes: runtime) { parts.append(runtime) }
        if let rating = MediaDetailView.ageRating(certification) { parts.append(rating) }
        return parts.joined(separator: " · ")
    }

    /// An American rating ("PG-13", "TV-MA") as a French reader knows it
    /// ("-12", "-16"; nothing for a film for all); unchanged in English.
    static func ageRating(_ certification: String, language: String? = Locale.current.language.languageCode?.identifier) -> String? {
        let value = certification.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "Unrated", value != "NR", value != "Not Rated" else { return nil }
        guard language == "fr" else { return value }
        switch value.uppercased() {
        case "G", "TV-G", "TV-Y", "TV-Y7", "PG", "TV-PG": return nil
        case "PG-13", "TV-14": return "-12"
        case "R", "TV-MA": return "-16"
        case "NC-17": return "-18"
        default: return value
        }
    }

    /// The rating first, as on the Home's carousel — the app's rating of
    /// the title (`HomeTitleFacts`) — then the facts: "★ 7,9 · 2026 ·
    /// 2 h 25 min".
    private func factsLine(_ facts: String, rating: Float, imdbId: String) -> some View {
        let known = HomeTitleFacts.shared.facts(of: imdbId)?.rating
        let value = known ?? (rating > 0 ? Double(rating) / 10 : nil)
        return HStack(spacing: 6) {
            if let value {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(GlassPalette.star)
                Text(verbatim: value.formatted(.number.precision(.fractionLength(1))))
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                if !facts.isEmpty { Text(verbatim: "·") }
            }
            if !facts.isEmpty { Text(verbatim: facts) }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// The formats of the releases the page lists ("4K", "DV", "ATMOS"), as
    /// the Apple TV's and the Mac's pages tell them (`GlassDetailAdapter.badges`):
    /// what Play can really start. Until the releases are in, those the card
    /// that opened the page showed (`HomeTitleFacts`), as the Home's carousel
    /// draws them.
    @ViewBuilder
    private func formatChips(imdbId: String, torrents: [Torrent]) -> some View {
        let badges = torrents.isEmpty ? HomeTitleFacts.shared.facts(of: imdbId)?.badges.filter(\.isFormat) ?? []
            : MediaDetailView.formats(of: torrents)
        let shown = badges.filter { $0 != .hdr || !badges.contains(.dolbyVision) }
        if !shown.isEmpty {
            HStack(spacing: 6) {
                ForEach(shown, id: \.self) { badge in
                    HomeBadgePill(label: HomeCardText().cardLabel(of: badge), tone: .format)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: shown.map { HomeCardText().label(of: $0) }.joined(separator: ", ")))
        }
    }

    /// The formats the page's releases carry, in the Home's order.
    static func formats(of torrents: [Torrent]) -> [HomeBadge] {
        let tags = torrents.reduce(VideoTags()) { $0.union($1.tags) }
        var found: Set<HomeBadge> = []
        if torrents.contains(where: { $0.qualityValue == .uhd2160 }) { found.insert(.uhd) }
        if tags.contains(.dolbyVision) { found.insert(.dolbyVision) }
        if !tags.isDisjoint(with: [.hdr10, .hdr10Plus, .hlg]) { found.insert(.hdr) }
        if tags.contains(.atmos) { found.insert(.atmos) }
        return HomeBadge.allCases.filter(found.contains)
    }

    /// The synopsis; one the sources give in English only, under another
    /// language, says so above it and opens on three lines ("Plus" shows
    /// the rest).
    private func synopsis(_ text: String) -> some View {
        let foreign = MediaDetailView.isForeign(text)
        return VStack(alignment: .leading, spacing: 4) {
            if foreign {
                Text("Detail.Summary.InEnglish")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            Text(verbatim: text)
                .font(foreign ? .subheadline : .body)
                .foregroundStyle(foreign ? .secondary : .primary)
                .lineLimit(foreign && !showsWholeSynopsis ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { synopsisShownHeight = $0 }
                .background(alignment: .top) {
                    // The whole text at the same width, unseen: measured only.
                    Text(verbatim: text)
                        .font(foreign ? .subheadline : .body)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { synopsisWholeHeight = $0 }
                        .accessibilityHidden(true)
                }
            if foreign && !showsWholeSynopsis && synopsisWholeHeight > synopsisShownHeight + 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showsWholeSynopsis = true }
                } label: {
                    Text("More").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("Detail.Synopsis.More")
            }
        }
        .padding(.top, 4)
    }

    /// The text is in English while the app is not.
    static func isForeign(_ text: String) -> Bool {
        let app = Locale.current.language.languageCode?.identifier ?? "en"
        guard app != "en", text.count > 40 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english
    }

    /// How many of a movie's sources the page lists before "All Sources".
    private static let sourcesShown = 3

    /// The best three sources (the recommended one among them), or all.
    private func shownSources(recommended: String?) -> [Torrent] {
        let all = viewModel.torrents
        guard !showsAllSources, all.count > Self.sourcesShown else { return all }
        var shown = Array(all.prefix(Self.sourcesShown))
        if let recommended, !shown.contains(where: { $0.url == recommended }),
           let pick = all.first(where: { $0.url == recommended }) {
            shown[shown.count - 1] = pick
        }
        return shown
    }

    /// "il reste 1 h 24 min" beside Resume: a movie's runtime less what
    /// was watched.
    private func remainingText(progress: Double) -> String? {
        guard let movie = viewModel.enrichedMovie, movie.runtime > 0 else { return nil }
        let left = Int((Double(movie.runtime) * (1 - progress)).rounded())
        guard let duration = HomeCardText().duration(minutes: left) else { return nil }
        return String(format: "Home.Card.Remaining".localized, duration)
    }

    /// - Parameter alwaysAsks: the quality sheet whatever the automatic
    ///   quality (a link's request).
    ///   - replaysRemembered: the release remembered for the title plays
    ///     without asking (« Resume », decision D2; a pack or a release in
    ///     clear continuity for an episode not started, D4) — not for a link.
    private func playFirstAvailable(alwaysAsks: Bool = false, replaysRemembered: Bool = true) {
        let torrents = viewModel.torrents   // sorted best-quality first
        guard !torrents.isEmpty else { return }
        let playMedia = viewModel.defaultPlaybackMedia ?? media
        if replaysRemembered, let replay = rememberedReplay(for: playMedia, among: torrents) {
            requestPlay(replay.torrent, media: playMedia, sources: torrents, startOverride: replay.start,
                        rememberedID: replay.forgets)
            return
        }
        let pick: Torrent?
        switch alwaysAsks ? "" : autoQuality {
        case "":
            // "Always Ask": the quality sheet, never a silent pick.
            presentQualityPicker(for: viewModel.defaultPlaybackMedia ?? media, torrents: torrents)
            return
        default:
            // Balanced, with its priority (Quick Start / Balanced / Best
            // Picture: `SourcePreferences`).
            pick = Torrent.balancedPick(from: torrents)
        }
        if let pick = pick { requestPlay(pick, media: viewModel.defaultPlaybackMedia ?? media, sources: torrents) }
    }

    /// Play replays what was played (episode chaining, 5.3.0): the release
    /// remembered for the title — « Resume » at the saved position, passed
    /// as DECIDED (D2: no « Resume at … ? » question, the native resume by a
    /// jump) —, the season pack the show was played from when it holds the
    /// episode, else for an episode not started a release of the page's in
    /// clear continuity with the show's last one (same group, same class:
    /// D4). nil: the usual flow (automatic quality, or the chooser).
    /// `forgets`: the id whose remembered release is dropped if it fails.
    private func rememberedReplay(for playMedia: Media, among torrents: [Torrent]) -> (torrent: Torrent, start: Float?, forgets: String?)? {
        #if DEBUG
        // A verification launch never starts a stream on a real title: only
        // the bench's made-up show (local .torrent files) replays.
        if IOSDebugHooks.isActive, !playMedia.id.hasPrefix(UpNextDebugHooks.showID) { return nil }
        #endif
        // The same rule as the Apple TV and the Mac (`UpNextResume.choice`):
        // the title's release, the show's pack (native first: a pack only
        // VLC plays when no native release is listed), a release in clear
        // continuity with the show's last one.
        guard let choice = UpNextResume.choice(mediaID: playMedia.id, candidates: torrents) else {
            if playMedia is Episode { print("[UpNext] resume \(playMedia.id): nothing to replay without asking — usual flow") }
            return nil
        }
        print(choice.logLine(mediaID: playMedia.id))
        let saved = ResumePolicy.startPosition(forSavedProgress: Self.savedProgress(for: playMedia))
        let start: Float? = choice.rule == .sameRelease && saved > 0 ? saved : nil
        // A remembered release is forgotten if it fails — wherever the title
        // remembers it (`forgetRemembered`); another release is not.
        return (choice.torrent, start, choice.replaysRemembered ? playMedia.id : nil)
    }

    /// The quality sheet for `playMedia` (a movie, or an episode with its
    /// show attached): the user picks the release.
    private func presentQualityPicker(for playMedia: Media, torrents: [Torrent]) {
        let episode = playMedia as? Episode
        let title = episode.map { "S\($0.season)E\($0.episode)" + ($0.title.isEmpty ? "" : " · \($0.title)") } ?? playMedia.title
        viewModel.episodeSources = EpisodeSources(title: title, torrents: torrents, episode: episode,
                                                  playMedia: episode == nil ? playMedia : nil)
    }

    /// Every tap that starts a stream comes through here: on cellular data
    /// (or a personal hotspot) with "Stream on Cellular Data" off, the user
    /// is asked first (`CellularStreamingPolicy`).
    /// `startOverride` / `rememberedID`: see `play`.
    private func requestPlay(_ torrent: Torrent, media playMedia: Media, sources: [Torrent], startOverride: Float? = nil,
                             rememberedID: String? = nil) {
        // A release chosen while a press waits for the sources (« Choose
        // Quality », an episode's sheet): the press is dropped — run later,
        // it would stop this stream and start its own pick. From the press's
        // own action, nothing is pending any more: no effect.
        viewModel.cancelPendingPlay()
        guard CellularStreamingPolicy.decision(isExpensive: NetworkPathObserver.shared.isExpensive) == .stream else {
            cellularRequest = PlayRequest(torrent: torrent, media: playMedia, sources: sources, startOverride: startOverride,
                                          rememberedID: rememberedID)
            return
        }
        play(torrent, media: playMedia, sources: sources, startOverride: startOverride, rememberedID: rememberedID)
    }

    /// Watched progress (0…1) saved by the native / VLC players.
    private static func savedProgress(for media: Media) -> Float {
        if let movie = media as? Movie { return WatchedlistManager<Movie>.movie.currentProgress(movie.id) }
        if let episode = media as? Episode { return WatchedlistManager<Episode>.episode.currentProgress(episode.id) }
        return 0
    }

    /// Stream `torrent` and, once it is ready, open the player picked from
    /// the REAL payload name. `playMedia` is the movie or the EPISODE;
    /// `sources`: the title's releases (another source, a lighter release);
    /// `startOverride`: where to start (0…1), decided by the user — a
    /// switch to a lighter release, « Resume » on a remembered release.
    /// `rememberedID`: a remembered release replayed (see `StreamSource`).
    /// `reclaimsAtOnce`: the previous stream's data is deleted before this
    /// one starts, not a moment later (the next episode: bounded storage).
    private func play(_ torrent: Torrent, media playMedia: Media, sources: [Torrent] = [], startOverride: Float? = nil,
                      rememberedID: String? = nil, reclaimsAtOnce: Bool = false) {
        startingStream = true
        loadingStartedAt = ProcessInfo.processInfo.systemUptime
        rememberedStalled = false
        loadingTracker = LoadingPhaseTracker()
        loadingPhase = .starting
        loadingLine = LoadingPhase.starting.line
        loadingSlow = false
        loadingSource = StreamSource(torrent: torrent, media: playMedia,
                                     sources: PlaybackStreamContext.withDebugSources(sources.isEmpty ? playMedia.torrents : sources),
                                     rememberedID: rememberedID)
        bufferProgress = 0
        seedsCount = 0
        peersCount = 0
        downloadKbps = 0
        streamErrorMessage = nil
        streamFailedNotInTorrent = false
        boundedNote = nil
        boundedNoteAt = 0
        let mediaTitle = playMedia.title
        let magnet = torrent.url
        let isAtmos = torrent.tags.contains(.atmos)
        let hintsHDR = !torrent.tags.isDisjoint(with: [.hdr10, .hdr10Plus, .dolbyVision])
        // A finished (or nearly finished) title restarts from the beginning
        // on every engine — VLC too, which resumes without asking (the native
        // players apply the same rule again).
        let startPosition = startOverride.map { ResumePolicy.handOffFraction(reached: $0) }
            ?? ResumePolicy.startPosition(forSavedProgress: Self.savedProgress(for: playMedia))
        // Clean slate before a new stream: stop the previous stream and
        // reclaim disk from prior torrent partials + orphaned remux output
        // (same as tvOS). Then a new streamer, current until the next stream
        // (the SPM PopcornTorrent has no singleton).
        PTTorrentStreamer.cancelCurrent(deleteData: true)
        purgeOrphanTorrentDownloads(waitsForDeletion: reclaimsAtOnce)
        #if DEBUG
        if reclaimsAtOnce { UpNextIOSDebug.logTorrentCache("before the next episode's stream") }
        #endif
        let streamer = PTTorrentStreamer.startNew()
        loadingStreamer = streamer
        // A film larger than the free space streams in bounded storage
        // (every player route drives the torrent's window).
        BoundedStorageSession.prepare(streamer, durationSeconds: BoundedStorageSession.durationHint(for: playMedia))
        // The release, the title's other releases and how to switch: every
        // engine reports to the stream's deficit watch, the cover shows its
        // offer; « Lighter version » closes the cover, then `endPlayback`
        // plays the release from where this one was.
        let context = PlaybackStreamContext.attach(to: streamer, media: playMedia, sourceURL: magnet, torrent: torrent,
                                                   sources: loadingSource?.sources, decidedStart: startOverride)
        let known = context.sources
        context.onSwitch = { lighter, fraction in
            pendingSwitch = PendingSwitch(torrent: lighter, media: playMedia, sources: known, start: fraction)
            pendingPlayback = nil
        }
        print("[iOS Detail] starting torrent: \(magnet.prefix(80))…")
        // The `[Start]` trace of this playback, and the OpenSubtitles search
        // alongside the stream: the players find its answer when they start
        // instead of searching (and holding their start) then (`SubtitleSearch`).
        let trace = PlaybackStartTrace(title: mediaTitle)
        streamer.startTrace = trace
        trace.begin(.subtitles)
        SubtitleSearch.shared.search(for: playMedia) { found in
            trace.reach(.subtitles, detail: "\(found.count) language(s)")
        }

        let progress: PTTorrentStreamerProgress = { status in
            DispatchQueue.main.async {
                updateLoadingPhase(streamer: streamer, fromCallback: true)
                bufferProgress = status.bufferingProgress
                seedsCount = Int(status.seeds)
                peersCount = Int(status.peers)
                // libtorrent reports bytes/s; surface as KB/s.
                downloadKbps = Double(status.downloadSpeed) / 1024.0
                // Bounded storage's line: every 5 s at most, at once when
                // the stream turns out bounded.
                let now = ProcessInfo.processInfo.systemUptime
                if now - boundedNoteAt >= 5
                    || (boundedNote == nil && BoundedStorageSession.session(for: streamer)?.isBounded == true) {
                    boundedNoteAt = now
                    boundedNote = BoundedStorageUX.loadingNote(for: streamer)
                }
            }
        }
        let readyToPlay: PTTorrentStreamerReadyToPlay = { fileURL, filePath in
            DispatchQueue.main.async {
                guard streamer === loadingStreamer else { return }
                startingStream = false
                loadingStreamer = nil
                // Route on the REAL payload name (magnet display names often
                // carry no extension). Unknown → remux, which fails fast to VLC.
                let route = PlaybackRouting.route(forFileName: filePath.lastPathComponent)
                print("[iOS Detail] ready: \(filePath.lastPathComponent) → \(route)")
                streamer.noteStartBuffered(fileName: filePath.lastPathComponent)
                // The streamer reports `http://0.0.0.0:<port>/`: every engine
                // gets 127.0.0.1 and the payload's name, as on macOS.
                pendingPlayback = PendingPlayback(url: PlaybackRouting.playableLocalURL(fileURL, fileName: filePath.lastPathComponent),
                                                  localFile: filePath,
                                                  engine: route,
                                                  title: mediaTitle,
                                                  streamer: streamer,
                                                  media: playMedia,
                                                  isAtmos: isAtmos,
                                                  releaseHintsHDR: hintsHDR,
                                                  startPosition: startPosition)
                // An episode: the « next episode » card and its chaining.
                if let episode = playMedia as? Episode { beginUpNext(for: episode, streamer: streamer) }
            }
        }
        let failure: PTTorrentStreamerFailure = { error in
            // Not enough space even for bounded storage (-5: how much to
            // free), another file error (-6), or the error's own text.
            let failure = StreamFailure(error, streamer: streamer)
            let message = failure.message(underlying: error) ?? error.localizedDescription
            let notInTorrent: Bool = { if case .episodeNotInTorrent = failure { return true }; return false }()
            DispatchQueue.main.async {
                streamErrorMessage = message
                streamFailedNotInTorrent = notInTorrent
                // A remembered release that fails to start is not offered again.
                if let id = rememberedID, streamer === loadingStreamer { forgetRemembered(id, url: torrent.url, reason: "stream failed") }
                // Keep the overlay open so the user sees the error and can dismiss
                // explicitly via the "Annuler" button.
                bufferProgress = 0
            }
            print("[iOS Detail] streaming failure: \(error.localizedDescription)")
        }

        // The streamed file, as on tvOS and macOS
        // (`PTTorrentStreamer.fileSelection`): an episode's own file in a
        // season pack (none when the pack lacks it: the stream fails), else
        // the magnet's BEP 53 `so=` file when valid, else the largest video
        // file. Torrentio's packs stay filtered out of the iOS episode
        // sources (`TorrentioClient.dropsEpisodePacks`).
        streamer.startStreaming(fromMultiTorrentFileOrMagnetLink: magnet,
                                progress: progress,
                                readyToPlay: readyToPlay,
                                failure: failure,
                                selectFileToStream: streamer.measuringSelection(PTTorrentStreamer.fileSelection(for: magnet, media: playMedia, torrent: torrent)))
    }

    /// A native engine gave up: continue on VLC with the SAME stream. The
    /// engine is swapped in place (same cover), from the reached position
    /// (at most 99.5 %: a failure in the end credits doesn't restart the
    /// movie). `resumeDecided` is informational here: the iOS VLC player
    /// has no resume question of its own — it continues at `resumeFraction`
    /// either way, as when VLC is the first engine.
    private func handOffToVLC(reason: String, resumeFraction: Float, resumeDecided: Bool) {
        guard var playback = pendingPlayback, playback.engine != .vlc else { return }
        print("[iOS Detail] native player → VLC fallback (\(reason)) at \(Int(resumeFraction * 100)) %"
              + (resumeDecided ? "" : " (resume not decided by the user)"))
        playback.engine = .vlc
        playback.startPosition = resumeFraction
        pendingPlayback = playback
    }

    /// The player cover closed (any engine): stop the torrent. The players
    /// already cancel it themselves; this also covers the direct AVPlayer
    /// path, which has no hook into the streamer.
    private func endPlayback() {
        PTTorrentStreamer.cancelCurrent(deleteData: false)
        // « Lighter version »: the cover is gone, its stream cancelled.
        if let next = pendingSwitch {
            pendingSwitch = nil
            play(next.torrent, media: next.media, sources: next.sources, startOverride: next.start)
        } else if let next = pendingNext, let torrent = next.torrent {
            // The next episode: the finished one's stream is cancelled and
            // its data deleted (`play`: at once) before the new one starts —
            // the same pack again would be « torrent in use » (-7) otherwise.
            pendingNext = nil
            print("[UpNext] iOS: the cover is down, S\(next.episode.season)E\(next.episode.episode) starts "
                  + "(\(torrent.quality ?? "?"), rule=\(next.rule.rawValue))")
            play(torrent, media: next.episode, sources: next.sources, reclaimsAtOnce: true)
        } else if let episode = pendingNextFallback {
            pendingNextFallback = nil
            runUpNextFallback(episode)
        }
        pendingNext = nil
    }

    // MARK: Episode chaining (5.3.0)

    /// The episode's playback is on screen: its session (nil — a movie, the
    /// last episode, a show without its guide — and the player does what it
    /// did before 5.3).
    private func beginUpNext(for episode: Episode, streamer: PTTorrentStreamer) {
        var episode = episode
        // The guide is what the next episode is read from: the page's show
        // when the episode came without it.
        if let show = viewModel.enrichedShow, episode.show?.episodes.isEmpty ?? true,
           episode.show == nil || episode.show?.id == show.id {
            episode.show = show
        }
        upNext = UpNextSession.begin(episode: episode, streamer: streamer, host: upNextHost())
    }

    /// What the session does on iPhone / iPad: the next episode plays as
    /// « Lighter version » does — the cover closes, then `endPlayback` plays
    /// it through `play` (the finished stream cancelled, its data deleted).
    private func upNextHost() -> UpNextSession.Host {
        UpNextSession.Host(
            startNext: { plan in
                guard plan.torrent != nil, pendingPlayback != nil else { return false }
                pendingNext = plan
                // The page's loading card is up while the cover goes down:
                // no bare page between the two players.
                showLoadingForNextEpisode()
                pendingPlayback = nil
                return true
            },
            fallBack: { episode in
                // Today's flow for the episode (its sources, the chooser),
                // once the cover is gone.
                if pendingPlayback != nil {
                    pendingNextFallback = episode
                    pendingPlayback = nil
                } else {
                    runUpNextFallback(episode)
                }
            },
            chooseVersion: { plan in
                guard pendingPlayback != nil else { return }
                let request = UpNextChooserRequest(plan: plan)
                guard !request.torrents.isEmpty else {
                    // Nothing to choose from yet: the session goes on.
                    DispatchQueue.main.async { upNext?.choiceCancelled() }
                    return
                }
                upNextChooser = request
            },
            closePlayer: { pendingPlayback = nil })
    }

    /// The fallback of the session: what a tap on the episode's row does.
    private func runUpNextFallback(_ episode: Episode) {
        guard let showID = episode.show?.id ?? viewModel.enrichedShow?.id else { return }
        print("[UpNext] iOS: today's flow for S\(episode.season)E\(episode.episode) (its sources, the chooser)")
        viewModel.loadEpisodeSources(viewModel.playable(episode), showId: showID)
    }

    /// The loading card while the cover goes down (`play` then fills it).
    private func showLoadingForNextEpisode() {
        startingStream = true
        loadingStreamer = nil
        loadingSource = nil
        loadingTracker = LoadingPhaseTracker()
        loadingPhase = .starting
        loadingLine = LoadingPhase.starting.line
        loadingSlow = false
        bufferProgress = 0
        seedsCount = 0
        peersCount = 0
        downloadKbps = 0
        streamErrorMessage = nil
        streamFailedNotInTorrent = false
        boundedNote = nil
    }

    /// A remembered release that failed is forgotten: « Resume » goes back
    /// to the usual flow for it.
    private func forgetRemembered(_ id: String, url: String, reason: String) {
        // That release, wherever the title remembers it (an episode not
        // started replays its show's pack: the pack is the show's).
        let forgotten = Library.shared.forgetRelease(id, sourceKey: MagnetLink.sourceKey(of: url))
        print("[UpNext] resume fallback \(id): \(reason) — the remembered release is "
              + (forgotten ? "forgotten" : "already gone"))
    }
}

/// A stream the user asked for, held while the cellular question shows.
private struct PlayRequest {
    let torrent: Torrent
    let media: Media
    let sources: [Torrent]
    var startOverride: Float? = nil
    var rememberedID: String? = nil
}

/// The stream the overlay prepares.
private struct StreamSource {
    let torrent: Torrent
    let media: Media
    /// The title's releases.
    let sources: [Torrent]
    /// A remembered release replayed (episode chaining): the id whose
    /// release is forgotten when it fails; it is waited for
    /// `UpNextResume.patience` (D5) before « Choose another source ».
    var rememberedID: String? = nil
}

/// « Lighter version »: what plays once the cover has closed.
private struct PendingSwitch {
    let torrent: Torrent
    let media: Media
    let sources: [Torrent]
    /// 0…1.
    let start: Float
}

/// Quality picker shown after selecting an episode — lists every resolved
/// source (best quality first) and plays the chosen one.
private struct QualityPickerSheet: View {
    let title: String
    let torrents: [Torrent]
    let onSelect: (Torrent) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let recommended = Torrent.recommendedURL(in: torrents)
        NavigationStack {
            List(torrents, id: \.url) { torrent in
                Button {
                    onSelect(torrent)
                } label: {
                    SourceRow(torrent: torrent, recommended: torrent.url == recommended)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#if DEBUG
/// The episode-chaining bench on iPhone / iPad: what the torrent cache holds
/// when the next episode's stream starts (the finished one's data must be
/// gone: bounded storage, « torrent in use »).
enum UpNextIOSDebug {
    static func logTorrentCache(_ moment: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("Downloads")
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let sizes = folders.map { folder -> String in
            var bytes: Int64 = 0
            if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                for case let file as URL in walker {
                    bytes += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
                }
            }
            return "\(folder.lastPathComponent.prefix(12)) \(bytes / 1_048_576) MiB"
        }
        print("[UpNextDebug] torrent cache \(moment): \(folders.count) folder(s)" + (sizes.isEmpty ? "" : " — " + sizes.joined(separator: ", ")))
    }
}
#endif
