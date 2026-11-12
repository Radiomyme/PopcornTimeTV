// MacGlassDetailScreen.swift — the Mac movie / show page. Loads the title
// (PopcornKit.getMovieInfo / getShowInfo), shows MacGlassDetailView over its
// artwork and connects every button to the app: quality choice ("Auto
// Select Quality" setting or the picker sheet), subtitles then the player sheet
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

    init(media: Media) {
        _controller = State(initialValue: MacGlassDetailController(media: media))
    }

    var body: some View {
        Group {
            if let model = controller.model {
                MacGlassDetailView(model: model, actions: controller.actions, page: controller.page)
                    #if DEBUG
                    // `-PTDebugGlassFallback YES`: the macOS 14 / 15 look.
                    .environment(\.glassFallback, UserDefaults.standard.bool(forKey: "PTDebugGlassFallback"))
                    #endif
            } else {
                placeholder
            }
        }
        .navigationTitle(Text(verbatim: controller.model?.title ?? controller.media.title))
        .modifier(MacGlassToolbarStyle())
        .task { controller.load() }
        .onAppear {
            if ownDepth == nil { ownDepth = stackDepth }
            controller.pageAppeared()
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
            } else {
                controller.pageDisappeared()
            }
        }
        // Popped, or another sidebar section (the stack is emptied).
        .onDisappear { controller.pageDisappeared() }
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

    /// Before the title's info has arrived: a spinner (or the error) on black.
    private var placeholder: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let error = controller.loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(GlassPalette.secondaryText)
                    Text("Error")
                        .font(.title2.bold())
                    Text(verbatim: error)
                        .font(.body)
                        .foregroundStyle(GlassPalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .foregroundStyle(GlassPalette.primaryText)
                .padding(40)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .environment(\.colorScheme, .dark)
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
    /// Nil until the title's info has loaded.
    private(set) var model: GlassDetailModel?
    private(set) var loadError: String?
    let page = MacGlassPageState()

    /// Non-nil presents the player sheet.
    var playback: MacPendingPlayback?
    /// Non-nil presents the quality picker sheet.
    var qualityChoices: MacEpisodeSources?
    /// The movie / episode has no source at all.
    var isShowingNoSources = false

    @ObservationIgnored private(set) var actions = GlassDetailActions()
    @ObservationIgnored private var movie: Movie?
    /// Episodes linked to the full show (`Show.linkingEpisodes()`).
    @ObservationIgnored private var show: Show?
    @ObservationIgnored private var didStartLoading = false
    /// Resolved sources per episode id (Time4Popcorn + EZTV + Torrentio).
    @ObservationIgnored private var episodeTorrents: [String: [Torrent]] = [:]
    /// Seasons whose missing stills were already asked for.
    @ObservationIgnored private var stillSeasons = Set<Int>()
    /// The flow in progress started from the Play button (its spinner).
    @ObservationIgnored private var playFromPlayButton = false
    /// The page is on screen (not covered by a pushed page).
    @ObservationIgnored private var isVisible = false
    /// Bumped by each play flow and when the page goes away: a source or
    /// subtitle answer of an older flow is dropped.
    @ObservationIgnored private var flow = 0

    init(media: Media) {
        self.media = media
        actions = makeActions()
        page.chooseQuality = { [weak self] in self?.play(alwaysAsk: true) }
        page.chooseEpisodeQuality = { [weak self] id in self?.playEpisode(id, alwaysAsk: true) }
    }

    // MARK: Loading

    func load() {
        guard !didStartLoading else { return }
        didStartLoading = true
        if media is Movie {
            PopcornKit.getMovieInfo(media.id) { [weak self] movie, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let movie else {
                        self.loadError = error?.localizedDescription ?? "Unknown Error".localized
                        return
                    }
                    self.present(movie)
                }
            }
        } else {
            PopcornKit.getShowInfo(media.id) { [weak self] show, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let show, !show.seasonNumbers.isEmpty else {
                        self.loadError = error?.localizedDescription
                            ?? "There are no seasons available for the selected show. Please try again later.".localized
                        return
                    }
                    self.present(show)
                }
            }
        }
    }

    private func present(_ movie: Movie) {
        self.movie = movie
        // Backdrop: metahub's 1920 px one, YTS's as the fallback (adapter).
        let model = GlassDetailAdapter.model(for: movie)
        #if DEBUG
        // `-PTDebugAmbient YES`: no backdrop (the poster card layout).
        if UserDefaults.standard.bool(forKey: "PTDebugAmbient") {
            model.backdropURL = nil
            model.backdropFallbackURL = nil
        }
        // `-PTDebugQualitySheet YES`: the quality sheet over the page (never
        // plays: only a pick in the sheet would).
        if UserDefaults.standard.bool(forKey: "PTDebugQualitySheet"), !movie.torrents.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.qualityChoices = MacEpisodeSources(title: movie.title, media: movie,
                                                         torrents: movie.torrents.withMediaRuntime(of: movie).sorted(by: >))
            }
        }
        #endif
        self.model = model
        loadRelated()
        loadPeople()
    }

    private func present(_ loaded: Show) {
        let show = loaded.linkingEpisodes()
        self.show = show
        let season = show.latestUnwatchedEpisode()?.season ?? GlassDetailAdapter.firstSeason(of: show)
        model = GlassDetailAdapter.model(for: show, season: season)
        print("[MacGlass] \(show.title): seasons \(show.seasonNumbers), \(show.episodes.count) episodes")
        loadRelated()
        loadPeople()
        if let season { loadMissingStills(of: season) }
        #if DEBUG
        // `-PTDebugQualitySheet YES` on a show: Play's "Choose Quality…" —
        // the next episode's sources load (spinners on its still and in
        // Play), then the quality sheet (never plays: only a pick would).
        if UserDefaults.standard.bool(forKey: "PTDebugQualitySheet") {
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
        #endif
    }

    /// "Viewers Also Watched": Trakt, else YTS / Cinemeta (OpenMetadata).
    private func loadRelated() {
        guard let model else { return }
        model.isLoadingRelated = true
        let finish: ([Media]) -> Void = { [weak self] related in
            DispatchQueue.main.async {
                guard let self, let model = self.model else { return }
                self.page.relatedMedia = Dictionary(related.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                model.related = GlassDetailAdapter.related(related)
                model.isLoadingRelated = false
            }
        }
        if let movie {
            TraktManager.shared.getRelated(movie) { related, _ in finish(related) }
        } else if let show {
            TraktManager.shared.getRelated(show) { related, _ in finish(related) }
        }
    }

    /// Cast & crew (Trakt, else YTS / Cinemeta / TVMaze), also the movie
    /// Information card's Director(s) and Starring rows.
    private func loadPeople() {
        guard let model else { return }
        model.isLoadingPeople = true
        let isMovie = movie != nil
        TraktManager.shared.getPeople(forMediaOfType: isMovie ? .movies : .shows, id: media.id) { [weak self] actors, crew, _ in
            DispatchQueue.main.async {
                guard let self, let model = self.model else { return }
                model.people = GlassDetailAdapter.people(actors: actors, crew: crew).items
                model.isLoadingPeople = false
                if var movie = self.movie {
                    movie.actors = actors
                    movie.crew = crew
                    self.movie = movie
                    model.information = GlassDetailAdapter.information(for: movie)
                }
            }
        }
    }

    /// TVMaze already gives most episodes a still; ask TMDB only for the
    /// missing ones, one season at a time (the season on screen).
    private func loadMissingStills(of season: Int) {
        guard let show, stillSeasons.insert(season).inserted else { return }
        let missing = show.episodes.filter { $0.season == season && $0.largeBackgroundImage == nil }
        guard !missing.isEmpty else { return }
        let fetch: (Int) -> Void = { [weak self] tmdbId in
            for episode in missing {
                TMDBManager.shared.getEpisodeScreenshots(orTMDBId: tmdbId, season: episode.season, episode: episode.episode) { _, image, _ in
                    guard let image else { return }
                    DispatchQueue.main.async { self?.setStill(image, forEpisode: episode.id) }
                }
            }
        }
        if let tmdbId = show.tmdbId {
            fetch(tmdbId)
        } else {
            TraktManager.shared.getTMDBId(forImdbId: show.id) { [weak self] tmdbId, _ in
                guard let tmdbId else { return }
                DispatchQueue.main.async {
                    self?.show?.tmdbId = tmdbId
                    fetch(tmdbId)
                }
            }
        }
    }

    private func setStill(_ image: String, forEpisode id: String) {
        guard var show, let index = show.episodes.firstIndex(where: { $0.id == id }) else { return }
        show.episodes[index].largeBackgroundImage = image
        self.show = show
        guard let model, let row = model.episodes.firstIndex(where: { $0.id == id }) else { return }
        let episode = show.episodes[index]
        let old = model.episodes[row]
        model.episodes[row] = GlassEpisode(id: old.id, season: old.season, number: old.number,
                                           title: old.title, summary: old.summary,
                                           stillURL: GlassDetailAdapter.url(episode.smallBackgroundImage ?? episode.largeBackgroundImage),
                                           detail: old.detail, isWatched: old.isWatched,
                                           progress: old.progress, download: old.download)
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
        guard let model else { return }
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
        guard let model else { return }
        let play = GlassDetailAdapter.nextEpisode(in: show).map(GlassDetailAdapter.playInfo(for:))
        if play != model.play { model.play = play }
        let upNext = show.latestUnwatchedEpisode()?.id
        if upNext != model.upNextEpisodeID { model.upNextEpisodeID = upNext }
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
        actions.playEpisode = { [weak self] id in self?.playEpisode(id, alwaysAsk: false) }
        actions.playTrailer = { [weak self] in self?.openTrailer() }
        actions.toggleWatchlist = { [weak self] in self?.toggleWatchlist() }
        actions.toggleWatched = { [weak self] in self?.toggleWatched() }
        actions.toggleEpisodeWatched = { [weak self] id in self?.toggleEpisodeWatched(id) }
        actions.selectSeason = { [weak self] season in self?.loadMissingStills(of: season) }
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

    /// Play: the movie, or the show's next episode (`GlassDetailAdapter.nextEpisode`).
    /// `alwaysAsk` (Play's context menu): the quality sheet whatever the setting.
    func play(alwaysAsk: Bool) {
        if let movie {
            playMovie(movie, alwaysAsk: alwaysAsk)
        } else if let show, let episode = GlassDetailAdapter.nextEpisode(in: show) {
            playEpisode(episode.id, alwaysAsk: alwaysAsk, fromPlayButton: true)
        }
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

    /// An episode: its sources (cached), then the automatic quality or the
    /// picker, then subtitles and the player.
    func playEpisode(_ id: String, alwaysAsk: Bool, fromPlayButton: Bool = false) {
        guard !isBusy, let show, let episode = show.episodes.first(where: { $0.id == id }) else { return }
        flow += 1
        let token = flow
        playFromPlayButton = fromPlayButton
        page.busyEpisodeID = id
        if fromPlayButton { page.isPreparingPlay = true }
        let title = "\(show.title) — S\(String(format: "%02d", episode.season))E\(String(format: "%02d", episode.episode))"
        resolveSources(of: episode, in: show) { [weak self] torrents in
            // Dropped once the page has gone (its busy state was ended then).
            guard let self, self.isCurrent(token) else { return }
            let sorted = torrents.withMediaRuntime(of: episode, show: show).sorted(by: >)
            guard !sorted.isEmpty else {
                self.endBusy()
                self.isShowingNoSources = true
                return
            }
            if !alwaysAsk, let pick = MacAutoQuality.pick(from: sorted) {
                self.start(pick, media: episode, title: title)
            } else {
                self.endBusy()
                self.qualityChoices = MacEpisodeSources(title: title, media: episode, torrents: sorted)
            }
        }
    }

    /// Time4Popcorn first, then EZTV / Torrentio — the iOS / tvOS play flow.
    /// Calls back on the main queue.
    private func resolveSources(of episode: Episode, in show: Show, completion answer: @escaping ([Torrent]) -> Void) {
        #if DEBUG
        let completion = MacGlassDebugPointer.delayedSources(answer)
        #else
        let completion = answer
        #endif
        if let cached = episodeTorrents[episode.id] { return completion(cached) }
        guard show.id.hasPrefix("tt") else { return completion(episode.torrents) }
        let base = episode.torrents
        let group = DispatchGroup()
        var aggregated: [Torrent] = []
        var t4p: [Torrent] = []
        var extra: [Torrent] = []
        group.enter()
        TorrentioClient.shared.streams(imdbId: show.id, season: episode.season, episode: episode.episode) { torrents in
            aggregated = torrents
            group.leave()
        }
        group.enter()
        Time4PopcornClient.shared.episodeTorrents(imdbId: show.id, season: episode.season, episode: episode.episode) { torrents in
            t4p = torrents
            group.leave()
        }
        // The Pirate Bay + Knaben, exact episode only (`ExtraTorrentSources`).
        group.enter()
        ExtraTorrentSources.shared.episodeTorrents(imdbId: show.id, showTitle: show.title,
                                                   season: episode.season, episode: episode.episode) { torrents in
            extra = torrents
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            var merged = t4p + base
            for torrent in aggregated where !merged.contains(where: { $0.url == torrent.url }) {
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
            for torrent in ExtraTorrentSources.novel(extra, beside: merged) where torrent.seeds > 0 && seen.insert(infoHash(torrent.url)).inserted {
                merged.append(torrent)
            }
            self?.episodeTorrents[episode.id] = merged
            completion(merged)
        }
    }

    /// Subtitles first (the player offers them), then the player sheet —
    /// unless the page has gone in the meantime (`pageDisappeared`).
    func start(_ torrent: Torrent, media: Media, title: String) {
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
        var target = media
        let finish: ([Subtitle]) -> Void = { [weak self] subtitles in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(token) else { return }
                target.subtitles = subtitles
                self.endBusy()
                // The title's releases go with it: the player offers another
                // source (one that does not answer) or a lighter release
                // (a download slower than the video) from them.
                // Runtimes attached: bitrates for the lighter-release search
                // and the « Choose another source » sheet.
                let sources = ((media as? Episode).flatMap { self.episodeTorrents[$0.id] } ?? media.torrents)
                    .withMediaRuntime(of: media, show: self.show)
                self.playback = MacPendingPlayback(torrent: torrent, media: target, title: title, sources: sources)
            }
        }
        if let episode = media as? Episode {
            SubtitlesManager.shared.search(episode, imdbId: show?.id) { subtitles, _ in finish(subtitles) }
        } else {
            SubtitlesManager.shared.search(imdbId: media.id) { subtitles, _ in finish(subtitles) }
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
        guard let model else { return }
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
        guard var movie, let model else { return }
        movie.isWatched.toggle()
        self.movie = movie
        model.isWatched = movie.isWatched
        let play = GlassDetailAdapter.playInfo(for: movie)
        if play != model.play { model.play = play }
    }

    private func toggleEpisodeWatched(_ id: String) {
        guard let show, let model, let row = model.episodes.firstIndex(where: { $0.id == id }) else { return }
        WatchedlistManager<Episode>.episode.toggle(id)
        model.episodes[row] = GlassDetailAdapter.refreshed([model.episodes[row]])[0]
        refreshShowProgress(show)
    }
}

#if DEBUG
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
