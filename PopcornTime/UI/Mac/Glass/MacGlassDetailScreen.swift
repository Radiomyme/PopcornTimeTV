// MacGlassDetailScreen.swift — the Mac movie / show page. Shows
// MacGlassDetailView over its artwork at once, with what its caller has of
// the title (a grid's item, a Home card, an id): the title's record, then
// its sources, fill the page as they arrive (PopcornKit's `DetailSession`).
// Connects every button to the app: quality choice ("Auto Select Quality"
// setting or the picker sheet), subtitles then the player sheet
// (MacPlayerView), episode sources (Time4Popcorn + EZTV + Torrentio),
// watchlist and watched lists, the trailer in the browser, related titles
// and cast & crew. The Mac counterpart of GlassDetailHostingController
// (tvOS), without downloads, theme songs or person pages.
import SwiftUI
import AppKit
import PopcornKit

struct MacGlassDetailScreen: View {
    @State private var controller: MacGlassDetailController
    /// Pages pushed over the grid now (MacRootView's stack).
    @Environment(\.macStackDepth) private var stackDepth
    /// This page's own depth, recorded when it first appears.
    @State private var ownDepth: Int?
    /// Told when the page is on top (a link to its title comes to it).
    @EnvironmentObject private var navigator: MacNavigator

    /// What the page was opened for besides showing itself (a Home card
    /// that plays, a popcorntime:// link): run once, when the title is on
    /// the page (`MacGlassDetailController.run`, MacHomeView.swift).
    private let request: MediaPageRequest
    @State private var didRunRequest = false

    /// `media`: a `Movie` or a `Show`, as much of it as the caller has.
    /// `season` / `episode`: a link's — the season the page opens on and
    /// the episode its shelf shows first, when the show has them.
    /// `autoPlay`: then what the page's Play button does, or with a season
    /// and an episode what a click on that episode does.
    init(media: Media, season: Int? = nil, episode: Int? = nil, autoPlay: Bool = false) {
        self.init(media: media, request: MediaPageRequest(autoPlay: autoPlay, season: season, episode: episode))
    }

    /// A page opened for `request` as it was asked — a link's included
    /// (`MediaPageRequest.fromLink`: its Play never picks a release alone).
    init(media: Media, request: MediaPageRequest) {
        _controller = State(initialValue: MacGlassDetailController(media: media, season: request.season, episode: request.episode))
        self.request = request
    }

    var body: some View {
        MacGlassDetailView(model: controller.model, actions: controller.actions, page: controller.page)
            #if DEBUG
            // `-PTDebugGlassFallback YES`: the macOS 14 / 15 look.
            .environment(\.glassFallback, UserDefaults.standard.bool(forKey: "PTDebugGlassFallback"))
            #endif
        .navigationTitle(Text(verbatim: controller.model.title.isEmpty ? controller.media.title : controller.model.title))
        .modifier(MacGlassToolbarStyle())
        .task { controller.load() }
        .onAppear {
            if ownDepth == nil { ownDepth = stackDepth }
            controller.pageAppeared()
            navigator.pageAppeared(controller, depth: ownDepth ?? stackDepth)
        }
        // The page shows at once (detail-fast): a movie's request runs then
        // (Play holds the click until its sources are in), a show's once
        // its guide says which seasons and episodes it has.
        .onChange(of: controller.isReadyForRequest, initial: true) { _, ready in
            guard ready, !didRunRequest else { return }
            didRunRequest = true
            controller.run(request)
        }
        // The stack does not call onDisappear / onAppear on a page that a
        // pushed page covers / uncovers: its depth tells. A related title
        // pushed over this page: the play flow in progress must not open
        // the player (now or after Back). Back to this page: the live state
        // (watchlist, watched, progress) is read again.
        .onChange(of: stackDepth) { _, depth in
            guard let ownDepth else { return }
            if depth == ownDepth {
                controller.pageAppeared()
                navigator.pageAppeared(controller, depth: depth)
            } else {
                controller.pageDisappeared()
            }
        }
        // Popped, or another sidebar section (the stack is emptied).
        .onDisappear {
            controller.pageDisappeared()
            navigator.pageDisappeared(controller)
        }
        .sheet(item: $controller.playback, onDismiss: { controller.playerClosed() }) { item in
            MacPlayerView(playback: item)
                .frame(minWidth: 1024, minHeight: 576)
        }
        .sheet(item: $controller.qualityChoices) { sources in
            MacQualityPickerSheet(title: sources.title, torrents: sources.torrents) { torrent in
                controller.qualityChoices = nil
                if let torrent {
                    controller.start(torrent, media: sources.media, title: sources.title)
                }
            }
        }
        .alert(Text("No torrents found"),
               isPresented: Binding(get: { controller.isShowingNoSources },
                                    set: { if !$0 { controller.isShowingNoSources = false } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Torrents could not be found for the specified media.")
        }
    }
}

/// The artwork runs under the window toolbar: no toolbar background, and no
/// window title over it (macOS 15+; the hero shows the logo / title).
private struct MacGlassToolbarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .toolbar(removing: .title)
        } else {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

// MARK: - Controller

@Observable
final class MacGlassDetailController {
    let media: Media
    /// The page's content: what it was opened with, then the title's
    /// record and its sources as they arrive.
    let model: GlassDetailModel
    let page = MacGlassPageState()

    /// Non-nil presents the player sheet.
    var playback: MacPendingPlayback?
    /// Non-nil presents the quality picker sheet.
    var qualityChoices: MacEpisodeSources?
    /// The movie / episode has no source at all.
    var isShowingNoSources = false

    @ObservationIgnored private(set) var actions = GlassDetailActions()
    /// The page's load, and a click made before the sources are in.
    @ObservationIgnored private let session: DetailSession
    @ObservationIgnored private var movie: Movie?
    /// Episodes linked to the full show (`Show.linkingEpisodes()`).
    @ObservationIgnored private var show: Show?
    @ObservationIgnored private var didStartLoading = false
    /// The season and the episode a link names.
    @ObservationIgnored private var linkedSeason: Int?
    @ObservationIgnored private var linkedEpisode: Int?
    /// A link handed to the page while it is on top (`reopen`) before its
    /// guide said which seasons the show has: acted on once it has.
    @ObservationIgnored private var handedRequest: MediaPageRequest?
    /// The cast and crew found, put back on the movie each time the
    /// session hands a new one.
    @ObservationIgnored private var loadedPeople: (actors: [Actor], crew: [Crew])?
    /// Related titles and people are asked once, when the record is in.
    @ObservationIgnored private var didLoadExtras = false
    /// The show's guide has been taken in (season chosen, next episode's
    /// sources asked ahead).
    @ObservationIgnored private var didTakeGuide = false
    /// How many episodes the guide handed to the library had.
    @ObservationIgnored private var notedGuideEpisodes = 0
    /// Resolved sources per episode id (Time4Popcorn + EZTV + Torrentio):
    /// the page's cache, only of lists every source answered for.
    @ObservationIgnored private var episodeTorrents: [String: [Torrent]] = [:]
    /// The list last resolved per episode id — possibly without a source
    /// that was not in yet, then replaced by the complete one: what the
    /// player takes as the title's other releases (`start`).
    @ObservationIgnored private var resolvedTorrents: [String: [Torrent]] = [:]
    /// The flow in progress started from the Play button (its spinner).
    @ObservationIgnored private var playFromPlayButton = false
    /// The page is on screen (not covered by a pushed page).
    @ObservationIgnored private var isVisible = false
    /// Bumped by each play flow and when the page goes away: a source or
    /// subtitle answer of an older flow is dropped.
    @ObservationIgnored private var flow = 0

    /// The page's request (`run`) can be acted on: a movie at once, a show
    /// once its guide is in.
    var isReadyForRequest: Bool {
        !(media is Show) || !model.isLoadingEpisodes
    }

    init(media: Media, season: Int? = nil, episode: Int? = nil) {
        self.media = media
        linkedSeason = season
        linkedEpisode = episode
        // Only movies and shows have a page (anything else: its id, as a movie).
        session = DetailSession(media: media) ?? DetailSession(media: Movie(title: media.title, id: media.id))!
        if let show = session.show {
            let linked = show.linkingEpisodes()
            self.show = linked
            model = GlassDetailAdapter.model(for: linked, season: nil, isLoaded: false)
            model.isLoadingEpisodes = true
        } else {
            let movie = session.movie ?? Movie(title: media.title, id: media.id)
            self.movie = movie
            model = GlassDetailAdapter.model(for: movie, isLoaded: false)
        }
        model.isLoadingRelated = true
        model.isLoadingPeople = true
        actions = makeActions()
        page.imdbId = media.id
        page.chooseQuality = { [weak self] in self?.play(alwaysAsk: true) }
        page.chooseEpisodeQuality = { [weak self] id in self?.playEpisode(id, alwaysAsk: true) }
        applyContent()
    }

    /// Whether this is the page of that title.
    func shows(id: String, isMovie: Bool) -> Bool {
        session.id == id && (session.kind == .movie) == isMovie
    }

    /// A link to this page while it is on top (`MacNavigator.open(url:)`):
    /// its season and the episode the shelf shows first, and what a `play`
    /// link plays — as on a page it had opened (`run`).
    func reopen(_ request: MediaPageRequest) {
        if let season = request.season {
            linkedSeason = season
            linkedEpisode = request.episode
            if didTakeGuide, let show {
                model.linkedEpisodeID = request.episode.flatMap { episode in
                    show.episodes.first { $0.season == season && $0.episode == episode }?.id
                }
            }
        }
        if isReadyForRequest {
            run(request)
        } else {
            handedRequest = request
        }
    }

    // MARK: Loading

    /// Starts the page's load (once, when the page appears: SwiftUI may
    /// make a controller it never shows). What a prewarm or an earlier
    /// opening left is on the page at once.
    func load() {
        guard !didStartLoading else { return }
        didStartLoading = true
        #if DEBUG
        MacGlassDetailDebug.applyTamperingOnce()
        #endif
        session.onChange = { [weak self] change in self?.sessionChanged(change) }
        session.start()
        applyContent()
        applyState()
        // The page is on screen: its first frame follows this turn.
        DispatchQueue.main.async { [session] in session.noteFirstPaint() }
        #if DEBUG
        // `-PTDebugPressPlay <seconds>` (only with `-PTDebugHoverBusy YES`,
        // under which nothing can play): a click on Play that long after
        // the page appeared — before its sources, when they are held.
        if MacGlassDebugPointer.isRequested, UserDefaults.standard.double(forKey: "PTDebugPressPlay") > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + UserDefaults.standard.double(forKey: "PTDebugPressPlay")) { [weak self] in
                print("[MacGlass] debug: Play clicked (dry run)")
                self?.play(alwaysAsk: false)
            }
        }
        #endif
    }

    private func sessionChanged(_ change: DetailSession.Change) {
        if !change.isDisjoint(with: [.metadata, .sources]) { applyContent() }
        if change.contains(.state) { applyState() }
        if change.contains(.metadata), session.hasRecord { completeWatchlistEntry() }
    }

    /// The record is in: a title put in the watchlist before it was (the
    /// page answers from its first frame) gets what its entry lacked — a
    /// link's title, a Continue Watching card's year and genres.
    private func completeWatchlistEntry() {
        if let movie {
            WatchlistManager<Movie>.movie.complete(movie)
        } else if let show {
            WatchlistManager<Show>.show.complete(show)
        }
    }

    /// The record, then the sources, are in: the movie or the show and the
    /// page's fields follow (only what changed is written).
    private func applyContent() {
        let isLoaded = session.hasRecord || session.isFinished
        if var fresh = session.movie {
            if let loadedPeople {
                fresh.actors = loadedPeople.actors
                fresh.crew = loadedPeople.crew
            }
            movie = fresh
            GlassDetailAdapter.update(model, with: fresh, isLoaded: isLoaded)
            // The Home's length: "2 h 5 min", as on its cards and carousel.
            if let old = GlassDetailAdapter.runtime(minutes: fresh.runtime),
               let new = HomeCardText().duration(minutes: fresh.runtime), old != new,
               let index = model.metadata.firstIndex(of: old) {
                model.metadata[index] = new
            }
            #if DEBUG
            // `-PTDebugAmbient YES`: no backdrop (the poster card layout).
            if UserDefaults.standard.bool(forKey: "PTDebugAmbient") {
                model.backdropURL = nil
                model.backdropFallbackURL = nil
            }
            #endif
        } else if let fresh = session.show {
            let linked = fresh.linkingEpisodes()
            show = linked
            if session.hasGuide, !didTakeGuide { takeGuide(of: linked) }
            GlassDetailAdapter.update(model, with: linked, isLoaded: isLoaded)
            if session.hasGuide || session.isFinished { applyPlayTarget(of: linked) }
            let waitsForGuide = !session.hasGuide && !session.isFinished
            // Play is there from the first frame (a spinner until the guide
            // says which episode it starts): the row does not shift.
            if waitsForGuide, model.play == nil { model.play = GlassPlayInfo() }
            if model.isLoadingEpisodes != waitsForGuide { model.isLoadingEpisodes = waitsForGuide }
            if session.hasGuide, linked.episodes.count != notedGuideEpisodes {
                // A followed show's guide is what its Continue Watching card
                // and its new episodes are worked out from.
                notedGuideEpisodes = linked.episodes.count
                Library.shared.noteGuide(of: linked)
            }
        }
        let sources = GlassDetailAdapter.sourcesState(session.sources)
        if model.sources != sources { model.sources = sources }
        if isLoaded, didStartLoading { loadExtrasOnce() }
        if let handed = handedRequest, isReadyForRequest {
            handedRequest = nil
            run(handed)
        }
        #if DEBUG
        if session.isFinished, session.failure == nil { runDebugHooksOnce() }
        #endif
    }

    /// A failure (the page keeps what it shows, Play becomes "Try Again"),
    /// and whether a click waits for the sources.
    private func applyState() {
        let error = session.failure?.localizedDescription
        if model.loadError != error { model.loadError = error }
        if session.failure != nil, model.isLoadingEpisodes { model.isLoadingEpisodes = false }
        if page.isWaitingForSources != session.isPressPending { page.isWaitingForSources = session.isPressPending }
        #if DEBUG
        if session.isFinished, session.failure == nil { runDebugHooksOnce() }
        #endif
    }

    /// The show's guide has arrived: the season the page opens on (a
    /// link's, else the next episode's), the episode its shelf shows first,
    /// and the sources of the episode Play starts, asked ahead — the click
    /// finds them, or joins the request (`EpisodeSourceResolver`).
    private func takeGuide(of show: Show) {
        didTakeGuide = true
        // Opening the page is having seen the new episodes.
        Library.shared.acknowledgeNewEpisodes(ofShow: show.id)
        let season = linkedSeason.flatMap { show.seasonNumbers.contains($0) ? $0 : nil }
            ?? show.latestUnwatchedEpisode()?.season ?? GlassDetailAdapter.firstSeason(of: show)
        if model.selectedSeason != season { model.selectedSeason = season }
        if let linkedSeason, let linkedEpisode {
            model.linkedEpisodeID = show.episodes.first { $0.season == linkedSeason && $0.episode == linkedEpisode }?.id
        }
        print("[MacGlass] \(show.title): seasons \(show.seasonNumbers), \(show.episodes.count) episodes")
        if let next = playTarget(in: show) {
            EpisodeSourceResolver.shared.prefetch(showId: show.id, showTitle: show.title,
                                                  season: next.season, episode: next.episode)
        }
    }

    /// Related titles and cast & crew, once the record is in: their
    /// requests need the title's genres, and join the record's own.
    private func loadExtrasOnce() {
        guard !didLoadExtras else { return }
        didLoadExtras = true
        loadRelated()
        loadPeople()
    }

    /// "Try Again": the same title asked again, from scratch.
    private func retry() {
        didLoadExtras = false
        model.isLoadingRelated = true
        model.isLoadingPeople = true
        if show != nil, !session.hasGuide { model.isLoadingEpisodes = true }
        session.retry()
    }

    #if DEBUG
    @ObservationIgnored private var didRunDebugHooks = false

    /// `-PTDebugQualitySheet YES`, once the page has loaded: the quality
    /// sheet over a movie's page (never plays: only a pick in the sheet
    /// would); on a show, Play's "Choose Quality…" — the next episode's
    /// sources load (spinners on its still and in Play), then the sheet.
    private func runDebugHooksOnce() {
        guard !didRunDebugHooks, UserDefaults.standard.bool(forKey: "PTDebugQualitySheet") else { return }
        didRunDebugHooks = true
        if let movie, !movie.torrents.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.qualityChoices = MacEpisodeSources(title: movie.title, media: movie,
                                                         torrents: movie.torrents.withMediaRuntime(of: movie).sorted(by: >))
            }
        } else if let show {
            let episodeID = GlassDetailAdapter.nextEpisode(in: show)?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                print("[MacGlass] debug: Choose Quality… for \(episodeID ?? "?")")
                self?.page.chooseQuality()
                let anchors = (episodeID.map { ["episode-" + $0] } ?? []) + ["play"]
                Task { @MainActor in
                    MacGlassDebugPointer.wiggleIfRequested(over: anchors) { [weak self] in self?.page.busyEpisodeID != nil }
                    await self?.runDebugKeyScenario(episodeAnchor: anchors.first ?? "play")
                }
            }
        }
    }
    #endif

    /// "Viewers Also Watched": the keyless sources (YTS / Cinemeta), Trakt
    /// only for a connected account (`DetailExtras`).
    private func loadRelated() {
        model.isLoadingRelated = true
        let finish: ([Media]) -> Void = { [weak self] related in
            DispatchQueue.main.async {
                guard let self else { return }
                self.page.relatedMedia = Dictionary(related.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.model.related = GlassDetailAdapter.related(related)
                self.model.isLoadingRelated = false
            }
        }
        if let movie {
            DetailExtras.related(movie) { finish($0) }
        } else if let show {
            DetailExtras.related(show) { finish($0) }
        }
    }

    /// Cast & crew (YTS / Cinemeta / TVMaze), also the movie Information
    /// card's Director(s) and Starring rows.
    private func loadPeople() {
        model.isLoadingPeople = true
        let isMovie = movie != nil
        DetailExtras.people(forMediaOfType: isMovie ? .movies : .shows, id: media.id) { [weak self] actors, crew in
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.people = GlassDetailAdapter.people(actors: actors, crew: crew).items
                self.model.isLoadingPeople = false
                if var movie = self.movie {
                    self.loadedPeople = (actors, crew)
                    movie.actors = actors
                    movie.crew = crew
                    self.movie = movie
                    self.model.information = GlassDetailAdapter.information(for: movie)
                }
            }
        }
    }

    // MARK: Visibility

    func pageAppeared() {
        isVisible = true
        refreshLiveState()
    }

    /// The page left the screen (a related title pushed over it — seen
    /// through the stack depth, MacGlassDetailScreen —, popped, another
    /// sidebar section): the play flow in progress is abandoned — its
    /// sources / subtitles answer must not present the player over another
    /// page, or when coming back. The page's own sheets don't count.
    func pageDisappeared() {
        guard playback == nil, qualityChoices == nil else { return }
        isVisible = false
        flow += 1
        // A click still waiting for the sources starts nothing on a page
        // that was left.
        session.cancelPress()
        endBusy()
    }

    /// A flow started as `token` may still present something.
    private func isCurrent(_ token: Int) -> Bool {
        isVisible && token == flow
    }

    // MARK: Live state

    /// Watchlist, watched and progress post no notifications: re-read them
    /// when the page comes back and when the player closes. Only changed
    /// values are written, so unchanged controls don't redraw.
    func refreshLiveState() {
        if let movie {
            let inWatchlist = movie.isAddedToWatchlist
            if inWatchlist != model.isInWatchlist { model.isInWatchlist = inWatchlist }
            let watched = movie.isWatched
            if watched != model.isWatched { model.isWatched = watched }
            let play = GlassDetailAdapter.playInfo(for: movie)
            if play != model.play { model.play = play }
        } else if let show {
            let inWatchlist = show.isAddedToWatchlist
            if inWatchlist != model.isInWatchlist { model.isInWatchlist = inWatchlist }
            refreshShowProgress(show)
            let episodes = GlassDetailAdapter.refreshed(model.episodes)
            if episodes != model.episodes { model.episodes = episodes }
        }
    }

    /// Play's episode and the shelf's up-next episode, after a watched change.
    private func refreshShowProgress(_ show: Show) {
        // Before the guide Play is a placeholder: nothing to work out yet.
        guard session.hasGuide || session.isFinished else { return }
        let (play, upNext) = GlassDetailAdapter.showProgress(of: show)
        if play != model.play { model.play = play }
        if upNext != model.upNextEpisodeID { model.upNextEpisodeID = upNext }
        applyPlayTarget(of: show)
    }

    /// The episode Play starts: the one the page was opened for — a Home
    /// card's new episode or season premiere, a link's — while it is not
    /// watched; else the one the user's history leads to. A card that says
    /// « S6 · É1 » opens a page whose Play reads « Lire S6 · É1 », not the
    /// pilot.
    private func playTarget(in show: Show) -> Episode? {
        if let linkedSeason, let linkedEpisode,
           let linked = show.episodes.first(where: { $0.season == linkedSeason && $0.episode == linkedEpisode }),
           !Library.shared.isWatched(linked.id) {
            return linked
        }
        return GlassDetailAdapter.nextEpisode(in: show)
    }

    /// Play's label follows `playTarget` when it is not the history's.
    private func applyPlayTarget(of show: Show) {
        guard linkedSeason != nil, let target = playTarget(in: show),
              target.id != GlassDetailAdapter.nextEpisode(in: show)?.id else { return }
        let play = GlassDetailAdapter.playInfo(for: target)
        if play != model.play { model.play = play }
    }

    /// The player sheet closed (it saves the progress): Play, the stills and
    /// the watched states follow. Read again a moment later: the player's
    /// own onDisappear (the save) may run after this.
    func playerClosed() {
        endBusy()
        refreshLiveState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshLiveState()
        }
    }

    // MARK: Actions

    private func makeActions() -> GlassDetailActions {
        var actions = GlassDetailActions()
        actions.play = { [weak self] in self?.play(alwaysAsk: false) }
        actions.retry = { [weak self] in self?.retry() }
        actions.artworkShown = { [weak self] in self?.session.noteArtwork() }
        actions.playEpisode = { [weak self] id in self?.playEpisode(id, alwaysAsk: false) }
        actions.playTrailer = { [weak self] in self?.openTrailer() }
        actions.toggleWatchlist = { [weak self] in self?.toggleWatchlist() }
        actions.toggleWatched = { [weak self] in self?.toggleWatched() }
        actions.toggleEpisodeWatched = { [weak self] id in self?.toggleEpisodeWatched(id) }
        return actions
    }

    /// A flow is running (sources, subtitles) or the player is up.
    private var isBusy: Bool {
        page.busyEpisodeID != nil || page.isPreparingPlay || playback != nil || qualityChoices != nil
    }

    private func endBusy() {
        page.busyEpisodeID = nil
        page.isPreparingPlay = false
    }

    /// Runs `action` once the page's sources are in — at once when they
    /// are (`DetailSession.press`). Meanwhile Play shows a spinner and
    /// reads "Cancel": a click on it drops the click that waits. Nothing
    /// runs on a page that failed to load ("Try Again" is what it offers).
    /// - Parameter picksAlone: a release will be played without asking: it
    ///   waits for every source that may still bring a better one.
    private func whenSourcesAreIn(picksAlone: Bool, _ action: @escaping () -> Void) {
        guard !isBusy else { return }
        session.press(picksAlone: picksAlone, action)
    }

    /// Play: the movie, or the show's next episode (`GlassDetailAdapter.nextEpisode`).
    /// `alwaysAsk` (Play's context menu): the quality sheet whatever the setting.
    func play(alwaysAsk: Bool) {
        // Play reads "Cancel" while a click waits for the sources.
        if session.isPressPending { return session.cancelPress() }
        // « Resume » (and a Home card that plays): the release remembered,
        // at once (decisions D2, D4).
        if !alwaysAsk, resumeRememberedRelease() { return }
        whenSourcesAreIn(picksAlone: !alwaysAsk && MacAutoQuality.picksAlone) { [weak self] in
            guard let self else { return }
            if let movie = self.movie {
                self.playMovie(movie, alwaysAsk: alwaysAsk)
            } else if let show = self.show, let episode = self.playTarget(in: show) {
                self.resolveAndPlay(episode.id, alwaysAsk: alwaysAsk, fromPlayButton: true)
            }
        }
    }

    /// « Resume » replays the release the title was played from, without
    /// the sources, the picker or the « Resume at … ? » question: its saved
    /// position is a decided start, resumed natively by a jump of the
    /// conversion (`MacUpNextResume`, decision D2); an episode not started
    /// whose season pack the show was played from holds it plays from that
    /// pack (D4). False: nothing remembered — the usual flow.
    private func resumeRememberedRelease() -> Bool {
        guard !isBusy else { return false }
        let media: Media
        let title: String
        if let movie {
            media = movie
            title = movie.title
        } else if let show, let episode = playTarget(in: show) {
            media = episode
            title = "\(show.title) — S\(String(format: "%02d", episode.season))E\(String(format: "%02d", episode.episode))"
        } else {
            return false
        }
        let resolved = (media as? Episode).flatMap { resolvedTorrents[$0.id] }
        let sources = resolved ?? media.torrents
        guard let pending = MacUpNextResume.playback(for: media, title: title, sources: sources, candidates: resolved) else { return false }
        flow += 1
        playFromPlayButton = true
        start(pending.torrent, media: media, title: title, startFraction: pending.startFraction, patience: pending.patience)
        return true
    }

    private func playMovie(_ movie: Movie, alwaysAsk: Bool) {
        guard !isBusy else { return }
        // The runtime gives each release its bitrate (size / runtime): the
        // automatic pick and the sheet weigh it against the connection.
        let torrents = movie.torrents.withMediaRuntime(of: movie).sorted(by: >)
        guard !torrents.isEmpty else {
            isShowingNoSources = true
            return
        }
        flow += 1
        playFromPlayButton = true
        if !alwaysAsk, let pick = MacAutoQuality.pick(from: torrents) {
            start(pick, media: movie, title: movie.title)
        } else {
            qualityChoices = MacEpisodeSources(title: movie.title, media: movie, torrents: torrents)
        }
    }

    /// An episode card: once the page's sources are in (EZTV's torrents
    /// are part of its choice), its own sources, then the automatic quality
    /// or the picker, then subtitles and the player.
    func playEpisode(_ id: String, alwaysAsk: Bool) {
        whenSourcesAreIn(picksAlone: !alwaysAsk && MacAutoQuality.picksAlone) { [weak self] in
            self?.resolveAndPlay(id, alwaysAsk: alwaysAsk, fromPlayButton: false)
        }
    }

    /// An episode: its sources (cached), then the automatic quality or the
    /// picker, then subtitles and the player.
    private func resolveAndPlay(_ id: String, alwaysAsk: Bool, fromPlayButton: Bool) {
        guard !isBusy, let show, let episode = show.episodes.first(where: { $0.id == id }) else { return }
        flow += 1
        let token = flow
        playFromPlayButton = fromPlayButton
        page.busyEpisodeID = id
        if fromPlayButton { page.isPreparingPlay = true }
        let title = "\(show.title) — S\(String(format: "%02d", episode.season))E\(String(format: "%02d", episode.episode))"
        resolveSources(of: episode, in: show, picksAlone: !alwaysAsk && MacAutoQuality.picksAlone) { [weak self] torrents in
            // Dropped once the page has gone (its busy state was ended then).
            guard let self, self.isCurrent(token) else { return }
            let sorted = torrents.withMediaRuntime(of: episode, show: show).sorted(by: >)
            guard !sorted.isEmpty else {
                self.endBusy()
                self.isShowingNoSources = true
                return
            }
            // Play / a Home card on an episode not started: the release in
            // clear continuity with the show's last one, or its pack (D4).
            if !alwaysAsk, fromPlayButton,
               let pending = MacUpNextResume.playback(for: episode, title: title, sources: sorted, candidates: sorted) {
                self.start(pending.torrent, media: episode, title: title, startFraction: pending.startFraction,
                           patience: pending.patience)
            } else if !alwaysAsk, let pick = MacAutoQuality.pick(from: sorted) {
                self.start(pick, media: episode, title: title)
            } else {
                self.endBusy()
                self.qualityChoices = MacEpisodeSources(title: title, media: episode, torrents: sorted)
            }
        }
    }

    /// Time4Popcorn first, then EZTV / Torrentio — the iOS / tvOS play flow.
    /// `picksAlone`: a release will be played without asking (the automatic
    /// quality). Calls back on the main queue.
    private func resolveSources(of episode: Episode, in show: Show, picksAlone: Bool,
                                completion answer: @escaping ([Torrent]) -> Void) {
        #if DEBUG
        let completion = MacGlassDebugPointer.delayedSources(answer)
        #else
        let completion = answer
        #endif
        if let cached = episodeTorrents[episode.id] { return completion(cached) }
        guard show.id.hasPrefix("tt") else { return completion(episode.torrents) }
        let base = episode.torrents
        // The three extra sources behind one deadline (`EpisodeSourceResolver`):
        // the list comes with what answered in time — a source that is down
        // no longer holds the click for its 10 s timeout. A list completed
        // afterwards replaces it (the next click, the player's other
        // sources).
        let merge: (EpisodeSourceResolver.Sources) -> [Torrent] = { sources in
            var merged = sources.time4Popcorn + base
            for torrent in sources.torrentio where !merged.contains(where: { $0.url == torrent.url }) {
                merged.append(torrent)
            }
            // TPB / Knaben (seeded, `ExtraTorrentSources.minSeeders`): only
            // torrents no other source lists, one entry per info-hash (their
            // magnets name the torrent and trackers their own way).
            func infoHash(_ url: String) -> String {
                guard let range = url.range(of: "btih:", options: .caseInsensitive) else { return url }
                return url[range.upperBound...].prefix { $0 != "&" }.lowercased()
            }
            var seen = Set(merged.map { infoHash($0.url) })
            for torrent in ExtraTorrentSources.novel(sources.extra, beside: merged) where torrent.seeds > 0 && seen.insert(infoHash(torrent.url)).inserted {
                merged.append(torrent)
            }
            return merged
        }
        // Kept for the page only once every source has answered, and none
        // with a failure (the resolver asks that one again at the next click).
        let keep: (EpisodeSourceResolver.Sources) -> [Torrent] = { [weak self] sources in
            let merged = merge(sources)
            self?.resolvedTorrents[episode.id] = merged
            if sources.isComplete, sources.failed.isEmpty { self?.episodeTorrents[episode.id] = merged }
            return merged
        }
        EpisodeSourceResolver.shared.resolve(showId: show.id, showTitle: show.title,
                                             season: episode.season, episode: episode.episode,
                                             // A list a source may still complete is good for the
                                             // sheet, where the user picks. The automatic quality
                                             // waits for every source still expected (not one on
                                             // the bench), « No torrents found » for all of them.
                                             isEnough: { sources in
            !merge(sources).isEmpty && (!picksAlone || sources.awaited.isEmpty)
        }, completion: { sources in
            completion(keep(sources))
        }, late: { sources in
            _ = keep(sources)
        })
    }

    /// The player sheet at once — unless the page has gone in the meantime
    /// (`pageDisappeared`). The OpenSubtitles search starts here and runs
    /// alongside the stream (`SubtitleSearch`): the sheet used to wait for
    /// its answer before the torrent was even added.
    /// - Parameters:
    ///   - startFraction: a decided start (« Resume » of a remembered
    ///     release): no question, a native resume there.
    ///   - patience: a remembered release's patience (D5).
    func start(_ torrent: Torrent, media: Media, title: String, startFraction: Float = 0, patience: TimeInterval? = nil) {
        #if DEBUG
        // The spinner hooks click the page: nothing may play in those runs.
        if MacGlassDebugPointer.isRequested {
            print("[MacGlass] debug: start(\(torrent.quality ?? "?")) refused (spinner / key-window hooks)")
            endBusy()
            return
        }
        #endif
        let token = flow
        if let episode = media as? Episode { page.busyEpisodeID = episode.id }
        if playFromPlayButton { page.isPreparingPlay = true }
        SubtitleSearch.shared.prefetch(for: media, showId: show?.id)
        var target = media
        // A title searched in the last half hour has its list at once.
        target.subtitles = SubtitleSearch.shared.answer(for: media, showId: show?.id) ?? []
        // An episode carries its show and its guide: the player offers the
        // next episode (episode chaining).
        if var episode = target as? Episode, episode.show?.episodes.isEmpty ?? true, let show {
            episode.show = show
            target = episode
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.endBusy()
            // The title's releases go with it: the player offers another
            // source (one that does not answer) or a lighter release
            // (a download slower than the video) from them.
            // Runtimes attached: bitrates for the lighter-release search
            // and the « Choose another source » sheet. An episode: the list
            // its release was picked from (`resolvedTorrents` — the bare
            // episode only has EZTV's).
            let sources = ((media as? Episode).flatMap { self.resolvedTorrents[$0.id] } ?? media.torrents)
                .withMediaRuntime(of: media, show: self.show)
            self.playback = MacPendingPlayback(torrent: torrent, media: target, title: title, sources: sources,
                                               startFraction: startFraction, patience: patience)
        }
    }

    /// The YouTube trailer in the default browser.
    private func openTrailer() {
        guard let movie else { return }
        let url = movie.trailer.flatMap(URL.init(string:)).flatMap { $0.scheme == nil ? nil : $0 }
            ?? movie.trailerCode.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }
        if let url { NSWorkspace.shared.open(url) }
    }

    private func toggleWatchlist() {
        if var movie {
            movie.isAddedToWatchlist.toggle()
            self.movie = movie
            model.isInWatchlist = movie.isAddedToWatchlist
        } else if var show {
            show.isAddedToWatchlist.toggle()
            self.show = show
            model.isInWatchlist = show.isAddedToWatchlist
        }
    }

    /// Unwatching also deletes the saved progress (WatchedlistManager.remove),
    /// so Play's progress bar is read again too.
    private func toggleWatched() {
        guard var movie else { return }
        movie.isWatched.toggle()
        self.movie = movie
        model.isWatched = movie.isWatched
        let play = GlassDetailAdapter.playInfo(for: movie)
        if play != model.play { model.play = play }
    }

    private func toggleEpisodeWatched(_ id: String) {
        guard let show, let row = model.episodes.firstIndex(where: { $0.id == id }) else { return }
        WatchedlistManager<Episode>.episode.toggle(id)
        model.episodes[row] = GlassDetailAdapter.refreshed([model.episodes[row]])[0]
        refreshShowProgress(show)
    }
}

#if DEBUG
// MARK: - DEBUG: the states of a page as it loads

/// `-PTDebugDetailMetadataDelay <s>`, `-PTDebugDetailSourcesDelay <s>`,
/// `-PTDebugDetailLastSourceDelay <s>`, `-PTDebugDetailSourcesFail YES`,
/// `-PTDebugDetailFail YES`: the title's record and its sources come late,
/// or fail (`DetailStore.Tampering`), so that each state of the page can
/// be looked at. `-PTDebugPressPlay <s>` clicks Play that long after the
/// page appeared (with `-PTDebugHoverBusy YES` nothing can play: `start`
/// refuses).
enum MacGlassDetailDebug {
    private static var didApply = false

    static func applyTamperingOnce() {
        guard !didApply else { return }
        didApply = true
        let defaults = UserDefaults.standard
        var tampering = DetailStore.Tampering()
        tampering.metadataDelay = defaults.double(forKey: "PTDebugDetailMetadataDelay")
        tampering.sourcesDelay = defaults.double(forKey: "PTDebugDetailSourcesDelay")
        tampering.lastSourceDelay = defaults.double(forKey: "PTDebugDetailLastSourceDelay")
        tampering.sourcesFail = defaults.bool(forKey: "PTDebugDetailSourcesFail")
        tampering.fails = defaults.bool(forKey: "PTDebugDetailFail")
        DetailStore.shared.tampering = tampering
    }
}

// MARK: - DEBUG: spinners under the pointer

/// Verification hooks of the page's spinners (with `-PTDebugOpenShow <id>
/// -PTDebugQualitySheet YES`):
/// - `-PTDebugSourcesDelay <seconds>`: an episode's sources answer that much
///   later, so its still and Play keep their spinners up;
/// - `-PTDebugHoverBusy YES`: meanwhile (the app is activated), synthetic
///   pointer moves go in and out of the busy still, then Play, every 0.35 s
///   (mouse events sent to the window: the real cursor does not move), as a
///   user's pointer does right after the click — the lift and glass hover
///   animations run around the spinners. The targets are found through
///   `macGlassDebugAnchor`. `-PTDebugPressBusy YES` also clicks them while
///   the episode is busy (a no-op then: a flow is running); nothing ever
///   plays in these runs (`start` refuses).
enum MacGlassDebugPointer {
    static let isRequested = UserDefaults.standard.bool(forKey: "PTDebugHoverBusy")
        || UserDefaults.standard.bool(forKey: "PTDebugKeyScenario")

    /// Anchor views by name (`macGlassDebugAnchor`).
    @MainActor static let anchors = NSMapTable<NSString, NSView>.strongToWeakObjects()

    static func delayedSources(_ answer: @escaping ([Torrent]) -> Void) -> ([Torrent]) -> Void {
        let delay = UserDefaults.standard.double(forKey: "PTDebugSourcesDelay")
        guard delay > 0 else { return answer }
        return { torrents in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { answer(torrents) } }
    }

    /// `names`: anchors to hover in turn (`episode-<id>`, `play`).
    @MainActor
    static func wiggleIfRequested(over names: [String], isBusy: @escaping () -> Bool) {
        guard UserDefaults.standard.bool(forKey: "PTDebugHoverBusy") else { return }
        let press = UserDefaults.standard.bool(forKey: "PTDebugPressBusy")
        let seconds = max(4, UserDefaults.standard.double(forKey: "PTDebugSourcesDelay") - 1.5)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            var clicks = 0
            let end = Date().addingTimeInterval(seconds)
            var step = 0
            var outside: (NSWindow, NSPoint)?
            while Date() < end {
                let name = names[(step / 2) % names.count]
                if step.isMultiple(of: 2) {
                    // Looked up again at each step: the page may scroll meanwhile.
                    if let anchor = anchors.object(forKey: name as NSString), let window = anchor.window {
                        let rect = anchor.convert(anchor.bounds, to: nil)
                        if step < 2 * names.count { print("[MacGlass] debug hover: \(name) @ \(NSStringFromRect(rect))") }
                        let point = NSPoint(x: rect.midX, y: rect.midY)
                        send(.mouseMoved, at: point, in: window)
                        outside = (window, NSPoint(x: window.frame.width - 30, y: 30))
                        if press, isBusy() {
                            try? await Task.sleep(nanoseconds: 60_000_000)
                            send(.leftMouseDown, at: point, in: window)
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            send(.leftMouseUp, at: point, in: window)
                            clicks += 1
                        }
                    } else if step < 2 * names.count {
                        print("[MacGlass] debug hover: \(name) not found")
                    }
                } else if let (window, point) = outside {
                    send(.mouseMoved, at: point, in: window)
                }
                step += 1
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            if let (window, point) = outside { send(.mouseMoved, at: point, in: window) }
            print("[MacGlass] debug hover: \(step) moves, \(clicks) clicks, key window: \(NSApp.keyWindow != nil)")
        }
    }

    /// A mouse event at `point` (window coordinates).
    @MainActor
    static func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                                             pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0) else { return }
        window.sendEvent(event)
    }
}

extension MacGlassDetailController {
    /// `-PTDebugKeyScenario YES` (with `-PTDebugQualitySheet YES`): once the
    /// quality sheet is up, the page's other windows in turn — the sheet
    /// closed (as Cancel does), the episode's tooltip (pointer resting on
    /// the still), Play's and the episode's context menus (opened by a
    /// synthetic right click, cancelled 1.5 s later) — for
    /// `-PTDebugKeyWindowTrace` (PopcornTimeMacApp).
    @MainActor
    func runDebugKeyScenario(episodeAnchor: String) async {
        guard UserDefaults.standard.bool(forKey: "PTDebugKeyScenario") else { return }
        for _ in 0..<600 where qualityChoices == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        print("[KeyTrace] scenario: quality sheet \(qualityChoices == nil ? "never shown" : "up")")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        print("[KeyTrace] scenario: closing the quality sheet")
        qualityChoices = nil
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        print("[KeyTrace] scenario: resting on \(episodeAnchor) (tooltip)")
        await MacGlassDebugPointer.rest(on: episodeAnchor, seconds: 5)
        for anchor in ["play", episodeAnchor] {
            print("[KeyTrace] scenario: context menu of \(anchor): \(MacGlassDebugPointer.rightClick(anchor))")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        print("[KeyTrace] scenario: done")
    }
}

extension MacGlassDebugPointer {
    /// A right click on the anchor (its context menu); the menu is cancelled
    /// 1.5 s after it opens.
    @MainActor
    static func rightClick(_ name: String) -> String {
        guard let (window, point) = visibleCenter(of: name) else { return "anchor not visible" }
        menuObserver.map(NotificationCenter.default.removeObserver)
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            print("[KeyTrace] scenario: menu open (\(menu.items.map(\.title)))")
            // The menu tracks in its own run loop mode: a common-modes timer.
            let timer = Timer(timeInterval: 1.5, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
        // No right-mouse-up: over the open menu, it would pick an item.
        send(.mouseMoved, at: point, in: window)
        send(.rightMouseDown, at: point, in: window)
        return "clicked at \(NSStringFromPoint(point))"
    }

    @MainActor private static var menuObserver: NSObjectProtocol?

    /// The pointer resting on the anchor (small moves every 0.25 s).
    @MainActor
    static func rest(on name: String, seconds: Double) async {
        guard let (window, point) = visibleCenter(of: name) else {
            print("[KeyTrace] scenario: \(name) not visible")
            return
        }
        let end = Date().addingTimeInterval(seconds)
        var nudge: CGFloat = 0
        while Date() < end {
            send(.mouseMoved, at: NSPoint(x: point.x + nudge, y: point.y), in: window)
            nudge = nudge == 0 ? 1 : 0
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// The anchor's center when it is inside its window's content.
    @MainActor
    private static func visibleCenter(of name: String) -> (NSWindow, NSPoint)? {
        guard let anchor = anchors.object(forKey: name as NSString), let window = anchor.window else { return nil }
        let rect = anchor.convert(anchor.bounds, to: nil)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        guard window.contentLayoutRect.contains(point) || (window.contentView?.bounds.contains(point) ?? false) else { return nil }
        return (window, point)
    }
}

/// An empty view behind a hover target, registered by name.
private struct MacGlassDebugAnchorView: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        MacGlassDebugPointer.anchors.setObject(view, forKey: name as NSString)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        MacGlassDebugPointer.anchors.setObject(nsView, forKey: name as NSString)
    }
}

extension View {
    /// DEBUG, with `-PTDebugHoverBusy YES` only: a hover target of
    /// MacGlassDebugPointer.
    @ViewBuilder
    func macGlassDebugAnchor(_ name: String) -> some View {
        if MacGlassDebugPointer.isRequested {
            background(MacGlassDebugAnchorView(name: name))
        } else {
            self
        }
    }
}
#endif
