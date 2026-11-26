// GlassDetailHostingController.swift — the tvOS movie / show page. Hosts
// GlassDetailView and connects it to the app: the same quality chooser and
// players as before (AppDelegate.chooseQuality / play), the watchlist and
// watched lists, downloads, trailers, theme songs, related titles and the
// person page.
//
// MainViewController.showDetail(of:on:autoPlay:) pushes this controller at
// once, with what its caller has of the title (a grid's item, a Home card,
// a link's id): there is no loading screen any more. The title's record,
// then its sources, fill the page as they arrive (PopcornKit's
// `DetailSession`); related titles and cast & crew follow (the logo and the
// episode stills the guide lacks are metahub URLs set by the adapter).
import UIKit
import SwiftUI
import AVKit
import PopcornKit
import PopcornTorrent
import XCDYouTubeKit

final class GlassDetailHostingController: UIHostingController<GlassDetailView>, PTTorrentDownloadManagerListener {

    private let model: GlassDetailModel
    /// The page's load: what it was opened with, then the record and the
    /// sources as they arrive, and a press made before them.
    private let session: DetailSession
    private var movie: Movie?
    /// Episodes linked to the full show (`Show.linkingEpisodes()`).
    private var show: Show?
    /// The page was opened to play right away (a Continue Watching item):
    /// no theme song on that first appearance.
    private var skipsThemeOnce: Bool
    /// Plays once the page is on screen (a Continue Watching item, a
    /// `play` link, Play/Pause on a poster).
    private var autoPlaysOnAppear: Bool
    /// The page appeared before its title was known (a link's bare id, a
    /// show whose TVDB id comes with its record): its theme plays once the
    /// record names it, if the page is still on screen.
    private var themeWaitsForTitle = false
    /// The season a link names: the one the page opens on, when the show
    /// has it.
    private var linkedSeason: Int?
    /// The episode a link names (`popcorntime://show/…?season=2&episode=5`):
    /// the one the shelf opens on, and what a `play` link starts instead of
    /// the episode Play starts.
    private var linkedEpisode: (season: Int, episode: Int)?
    /// `linkedEpisode` is a `play` link's.
    private var playsLinkedEpisode = false

    private var relatedItems: [String: Media] = [:]
    private var people: [String: Person] = [:]
    /// The cast and crew `loadPeople` found, put back on the movie each time
    /// the session hands a new one.
    private var loadedPeople: (actors: [Actor], crew: [Crew])?
    private var trailerEndObserver: NSObjectProtocol?
    /// Related titles and people are asked once, when the record is in.
    private var didLoadExtras = false
    /// The show's guide has been taken in (season chosen, next episode's
    /// sources asked ahead).
    private var didTakeGuide = false
    /// How many episodes the guide handed to the library had.
    private var notedGuideEpisodes = 0
    private var didNoteFirstPaint = false
    /// « Looking for sources… » of a press that waits for the page's sources.
    private var pressCard: SourcesBusyViewController?

    private var media: Media? { movie ?? show }
    /// The capability chips shown so far: a source that answers later only
    /// adds to them (`GlassBadgeMerge`) — a chip on screen never goes.
    private var shownBadges: [GlassBadge] = []

    // MARK: - Opening

    /// `media`: a `Movie` or a `Show`, as much of it as the caller has —
    /// the page shows it at once and loads the rest. `season`: the season
    /// the page opens on (a link's), when the show has it; with `episode`,
    /// the episode its shelf opens on, and the one `autoPlay` plays.
    init(media: Media, autoPlay: Bool = false, season linkedSeason: Int? = nil, episode linkedEpisodeNumber: Int? = nil) {
        GlassDetailWarmUp.pageWasMade()
        skipsThemeOnce = autoPlay
        autoPlaysOnAppear = autoPlay
        self.linkedSeason = linkedSeason
        if media is Show, let linkedSeason, let linkedEpisodeNumber {
            linkedEpisode = (linkedSeason, linkedEpisodeNumber)
            playsLinkedEpisode = autoPlay
        }
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
            // The formats the Home's card showed: the page opens with them.
            shownBadges = GlassBadgeMerge.merged(GlassDetailSeed.takeBadges(of: movie.id), model.badges)
            model.badges = shownBadges
        }
        model.isLoadingRelated = true
        model.isLoadingPeople = true
        super.init(rootView: GlassDetailView(model: model))
        rootView = GlassDetailView(model: model, actions: makeActions())
        navigationItem.title = media.title
        session.onChange = { [weak self] change in self?.sessionChanged(change) }
        // The sources are asked before the page slides in; what a prewarm
        // or an earlier opening left is on the page from its first frame.
        session.start()
        applyContent()
        applyState()
    }

    @available(*, unavailable, message: "Created in code by MainViewController.showDetail")
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        PTTorrentDownloadManager.shared().remove(self)
        if let trailerEndObserver { NotificationCenter.default.removeObserver(trailerEndObserver) }
    }

    /// Whether this is the page of `media` (a link to the page already on
    /// top does not push a second one).
    func shows(_ media: Media) -> Bool {
        return media.id == session.id && (media is Movie) == (session.kind == .movie)
    }

    /// A link to this page while it is on top: its season and episode are
    /// selected, and a `play` link plays.
    func reopen(autoPlay: Bool, season: Int?, episode: Int?) {
        if show != nil, let season {
            linkedSeason = season
            linkedEpisode = episode.map { (season, $0) }
            playsLinkedEpisode = autoPlay && episode != nil
            if session.hasGuide { selectLinkedSeason() }
        }
        if autoPlay { startAutoPlay() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        PTTorrentDownloadManager.shared().add(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The first layout in the window: the next frame shows the title and
        // the controls (the artwork fades in when loaded).
        guard !didNoteFirstPaint, view.window != nil else { return }
        didNoteFirstPaint = true
        DispatchQueue.main.async { [session] in session.noteFirstPaint() }
    }

    // MARK: - The page as it loads

    private func sessionChanged(_ change: DetailSession.Change) {
        if !change.isDisjoint(with: [.metadata, .sources]) { applyContent() }
        if change.contains(.state) { applyState() }
        if change.contains(.metadata), session.hasRecord {
            completeWatchlistEntry()
            if themeWaitsForTitle { playThemeSong() }
        }
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
            shownBadges = GlassBadgeMerge.merged(shownBadges, model.badges)
            if model.badges != shownBadges { model.badges = shownBadges }
        } else if let fresh = session.show {
            let linked = fresh.linkingEpisodes()
            show = linked
            if session.hasGuide, !didTakeGuide { takeGuide(of: linked) }
            GlassDetailAdapter.update(model, with: linked, isLoaded: isLoaded)
            let waitsForGuide = !session.hasGuide && !session.isFinished
            if waitsForGuide {
                // Play is there from the first frame (a ring until the guide
                // says which episode it starts): the row does not shift.
                if model.play == nil { model.play = GlassPlayInfo() }
            }
            if model.isLoadingEpisodes != waitsForGuide { model.isLoadingEpisodes = waitsForGuide }
            if session.hasGuide, linked.episodes.count != notedGuideEpisodes {
                // A followed show's guide is what its Continue Watching card
                // and its new episodes are worked out from (again when
                // EZTV's torrents add an episode to it).
                notedGuideEpisodes = linked.episodes.count
                Library.shared.noteGuide(of: linked)
            }
        }
        let sources = GlassDetailAdapter.sourcesState(session.sources)
        if model.sources != sources { model.sources = sources }
        // Nothing to play after all: no chip promises a format.
        if sources == .none, !model.badges.isEmpty {
            shownBadges = []
            model.badges = []
        }
        if isLoaded { loadExtrasOnce() }
    }

    /// A failure (the page keeps what it shows, Play becomes "Try Again"),
    /// and the card of a press that no longer waits.
    private func applyState() {
        let error = session.failure?.localizedDescription
        if model.loadError != error { model.loadError = error }
        if session.failure != nil, model.isLoadingEpisodes { model.isLoadingEpisodes = false }
        if !session.isPressPending, let card = pressCard {
            // The load failed under a press: its card goes, nothing starts.
            pressCard = nil
            card.finish {}
        }
    }

    /// The show's guide has arrived: the season the page opens on (a
    /// link's, else the next episode's), and the sources of the episode
    /// Play starts, asked ahead — the press finds them, or joins the
    /// request (`EpisodeSourceResolver`).
    private func takeGuide(of show: Show) {
        didTakeGuide = true
        // Opening the page is having seen the new episodes.
        Library.shared.acknowledgeNewEpisodes(ofShow: show.id)
        let season = linkedSeason.flatMap { show.seasonNumbers.contains($0) ? $0 : nil }
            ?? show.latestUnwatchedEpisode()?.season ?? GlassDetailAdapter.firstSeason(of: show)
        if model.selectedSeason != season { model.selectedSeason = season }
        selectLinkedEpisode(in: show)
        if let next = playsLinkedEpisode ? autoPlayTarget as? Episode : GlassDetailAdapter.nextEpisode(in: show) {
            EpisodeSourceResolver.shared.prefetch(showId: show.id, showTitle: show.title,
                                                  season: next.season, episode: next.episode)
        }
    }

    /// A link's season, on a page whose guide is in.
    private func selectLinkedSeason() {
        guard let show, let season = linkedSeason, show.seasonNumbers.contains(season) else { return }
        if model.selectedSeason != season { model.selectedSeason = season }
        selectLinkedEpisode(in: show)
    }

    /// A link's episode: the one the shelf opens on.
    private func selectLinkedEpisode(in show: Show) {
        let id = linkedEpisode.flatMap { linked in
            show.episodes.first { $0.season == linked.season && $0.episode == linked.episode }?.id
        }
        if model.linkedEpisodeID != id { model.linkedEpisodeID = id }
    }

    /// Related titles and cast & crew, once the record is in: their
    /// requests need the title's genres, and join the record's own.
    private func loadExtrasOnce() {
        guard !didLoadExtras else { return }
        didLoadExtras = true
        loadRelated()
        loadPeople()
    }

    private func retry() {
        // What the failed load could not ask is asked with the new one.
        didLoadExtras = false
        model.isLoadingRelated = true
        model.isLoadingPeople = true
        if show != nil, !session.hasGuide { model.isLoadingEpisodes = true }
        session.retry()
    }

    private func loadRelated() {
        model.isLoadingRelated = true
        let finish: ([Media]) -> Void = { [weak self] related in
            DispatchQueue.main.async {
                guard let self else { return }
                self.relatedItems = Dictionary(related.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

    /// Cast & crew (`DetailExtras`: the keyless sources, Trakt only for a
    /// connected account).
    private func loadPeople() {
        guard let media else { return }
        model.isLoadingPeople = true
        DetailExtras.people(forMediaOfType: media is Movie ? .movies : .shows, id: media.id) { [weak self] actors, crew in
            DispatchQueue.main.async {
                guard let self else { return }
                let result = GlassDetailAdapter.people(actors: actors, crew: crew)
                self.people = result.people
                // One face per person: a director who also acts keeps the
                // photo the cast row has, not initials.
                var photos: [String: URL] = [:]
                for person in result.items { if let url = person.imageURL, photos[person.name] == nil { photos[person.name] = url } }
                self.model.people = result.items.map { person in
                    guard person.imageURL == nil, let url = photos[person.name] else { return person }
                    return GlassPerson(id: person.id, name: person.name, role: person.role, imageURL: url)
                }
                self.model.isLoadingPeople = false
                if var movie = self.movie {
                    // Director(s) and Starring rows of the Information card.
                    self.loadedPeople = (actors, crew)
                    movie.actors = actors
                    movie.crew = crew
                    self.movie = movie
                    self.model.information = GlassDetailAdapter.information(for: movie)
                }
            }
        }
    }

    // MARK: - Appearance

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        // The page is the title's, full screen, as in the Apple TV app:
        // no tab bar over its artwork. Gone at once: animated, the bar slid
        // down over the page while it came in (seen at 0.3 s).
        if #available(tvOS 18.0, *) { tabBarController?.setTabBarHidden(true, animated: false) }
        refreshLiveState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if skipsThemeOnce {
            skipsThemeOnce = false
        } else {
            playThemeSong()
        }
        if autoPlaysOnAppear {
            // Once the page has slid in: a chooser presented during the
            // push would be dropped.
            autoPlaysOnAppear = false
            startAutoPlay()
        }
        keepFocusOutOfTheTabBar()
    }

    /// The focus belongs in the page while it is on top (`shouldUpdateFocus`
    /// never lets it go up to the tabs). tvOS can still put it back on a
    /// tab after the page was pushed: when the app returns to the
    /// foreground on a link, the focus comes back to the tab it was on a
    /// moment later — and Menu there would leave the app. The loading
    /// screen of 5.2 hid that: the page that replaced it a second later
    /// took the focus again. The page now takes it back itself, checked for
    /// its first three seconds on screen.
    private func keepFocusOutOfTheTabBar(checksLeft: Int = 6) {
        guard checksLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.navigationController?.topViewController === self, self.viewIfLoaded?.window != nil else { return }
            if self.presentedViewController == nil,
               let tabBarController = self.tabBarController as? TVTabBarController,
               tabBarController.selectedViewController === self.navigationController,
               tabBarController.focusIsInTabBar {
                tabBarController.moveFocus(to: self)
            }
            self.keepFocusOutOfTheTabBar(checksLeft: checksLeft - 1)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        themeWaitsForTitle = false
        ThemeSongManager.shared.stopTheme()
        // A press still waiting for the sources does not start on a page
        // that is left (its own choosers and players do not count: they are
        // presented over it once the press has run).
        if isMovingFromParent || navigationController?.topViewController !== self { cancelPendingPress() }
        // Back to the page under it (the Home, a grid): the tab bar is
        // back too. Another title's page on top keeps it hidden.
        if #available(tvOS 18.0, *), isMovingFromParent,
           !(navigationController?.topViewController is GlassDetailHostingController) {
            tabBarController?.setTabBarHidden(false, animated: animated)
        }
    }

    /// Focus never goes up into the tab bar from the page (as before).
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if let next = context.nextFocusedView, type(of: next) === NSClassFromString("UITabBarButton") {
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }

    /// Watchlist, watched and progress post no notifications: re-read them
    /// whenever the page comes back (from the player, a related title…).
    /// Only changed values are written, so unchanged controls don't redraw.
    private func refreshLiveState() {
        if let movie {
            let inWatchlist = movie.isAddedToWatchlist
            if inWatchlist != model.isInWatchlist { model.isInWatchlist = inWatchlist }
            let watched = movie.isWatched
            if watched != model.isWatched { model.isWatched = watched }
            let play = GlassDetailAdapter.playInfo(for: movie)
            if play != model.play { model.play = play }
            setDownloadState(GlassDetailAdapter.downloadState(of: movie.associatedDownload), of: movie.id)
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
    }

    /// The title's theme — once it is known: a movie's is searched by its
    /// title (an empty one would find any soundtrack), a show's by its TVDB
    /// id. Until then `themeWaitsForTitle`, and the record plays it.
    private func playThemeSong() {
        themeWaitsForTitle = false
        guard GlassSettingsStore.themeSongs else { return }
        if let movie {
            guard movie.hasTitleToShow else {
                themeWaitsForTitle = !session.isFinished
                return
            }
            ThemeSongManager.shared.playMovieTheme(movie.title)
        } else if let show {
            guard let tvdbId = Int(show.tvdbId), tvdbId > 0 else {
                themeWaitsForTitle = !session.hasGuide && !session.isFinished
                return
            }
            ThemeSongManager.shared.playShowTheme(tvdbId)
        }
    }

    // MARK: - Actions

    private func makeActions() -> GlassDetailActions {
        var actions = GlassDetailActions()
        actions.play = { [weak self] in self?.play() }
        actions.retry = { [weak self] in self?.retry() }
        actions.artworkShown = { [weak self] in self?.session.noteArtwork() }
        actions.playEpisode = { [weak self] id in self?.playEpisode(id) }
        actions.playTrailer = { [weak self] in self?.playTrailer() }
        actions.toggleWatchlist = { [weak self] in self?.toggleWatchlist() }
        actions.toggleWatched = { [weak self] in self?.toggleWatched() }
        actions.download = { [weak self] in
            guard let self, let movie = self.movie else { return }
            self.pressDownload(of: movie)
        }
        actions.stopDownload = { [weak self] in
            guard let self, let movie = self.movie else { return }
            self.stopDownload(of: movie)
        }
        actions.deleteDownload = { [weak self] in
            guard let self, let movie = self.movie else { return }
            self.deleteDownload(of: movie)
        }
        actions.downloadEpisode = { [weak self] id in
            guard let self, let episode = self.episode(id) else { return }
            self.pressDownload(of: episode)
        }
        actions.stopEpisodeDownload = { [weak self] id in
            guard let self, let episode = self.episode(id) else { return }
            self.stopDownload(of: episode)
        }
        actions.deleteEpisodeDownload = { [weak self] id in
            guard let self, let episode = self.episode(id) else { return }
            self.deleteDownload(of: episode)
        }
        actions.toggleEpisodeWatched = { [weak self] id in self?.toggleEpisodeWatched(id) }
        actions.openRelated = { [weak self] id in self?.openRelated(id) }
        actions.playRelated = { [weak self] id in self?.openRelated(id, autoPlay: true) }
        actions.openPerson = { [weak self] id in self?.openPerson(id) }
        return actions
    }

    private func episode(_ id: String) -> Episode? {
        show?.episodes.first { $0.id == id }
    }

    /// What Play starts: the movie, or the show's next episode.
    private var playTarget: Media? {
        if let movie { return movie }
        return show.flatMap(GlassDetailAdapter.nextEpisode(in:))
    }

    // MARK: A press before the sources

    /// "autoSelectQuality" is Balanced (Quick Start and Best Picture too,
    /// with their priority): a release is played without asking
    /// (`AppDelegate.chooseQuality`), so a press waits for every source that
    /// may still bring a better one.
    private static var picksQualityAlone: Bool {
        let preference = UserDefaults.standard.string(forKey: "autoSelectQuality") ?? "Off".localized
        return preference == "Balanced".localized
    }

    /// Runs `action` once the page's sources are in — at once when they
    /// are (`DetailSession.press`). Meanwhile the « Looking for sources… »
    /// card of an episode's sources comes up (after 0.4 s: no flash for a
    /// short wait), takes the remote, and Menu cancels the press. A press
    /// made on a page that failed to load does nothing: "Try Again" is
    /// what the page offers then.
    private func whenSourcesAreIn(_ action: @escaping () -> Void) {
        cancelPendingPress()
        let card = SourcesBusyViewController()
        let ranAtOnce = session.press(picksAlone: Self.picksQualityAlone) { [weak self] in
            if self?.pressCard === card { self?.pressCard = nil }
            card.finish(then: action)
        }
        guard !ranAtOnce, session.isPressPending else { return }
        pressCard = card
        card.onCancel = { [weak self] in
            guard let self, self.pressCard === card else { return }
            self.pressCard = nil
            self.session.cancelPress()
        }
        card.isStillWanted = { [weak self] in
            guard let self else { return false }
            return self.navigationController?.topViewController === self && self.viewIfLoaded?.window != nil
        }
        card.showSoon()
    }

    /// The press that waits for the sources is dropped, with its card.
    private func cancelPendingPress() {
        guard let card = pressCard else { return }
        pressCard = nil
        session.cancelPress()
        card.finish {}
    }

    // MARK: Play

    /// Play: same chooser and player as the old Play button (action-sheet
    /// style, anchored on the page).
    private func play() {
        // « Resume »: the release remembered for it replays at once (no
        // sources card, no chooser, no « Resume at …? »: decisions D2, D4).
        if let media = playTarget, playRemembered(media) { return }
        whenSourcesAreIn { [weak self] in
            guard let self, let media = self.playTarget else { return }
            // (The guide came with the sources: the target is known now.)
            if AppDelegate.shared.playRemembered(media) { return }
            // An episode not started: once its releases are in, the one in
            // clear continuity with the show's last release plays (D4).
            AppDelegate.shared.chooseQuality(self.view, media: media, replaysRemembered: true) { torrent in
                AppDelegate.shared.play(media, torrent: torrent)
            }
        }
    }

    /// An episode card: alert-style chooser, as the old episode row.
    private func playEpisode(_ id: String) {
        whenSourcesAreIn { [weak self] in
            // Read once the sources are in: the episode then has EZTV's torrents.
            guard let episode = self?.episode(id) else { return }
            AppDelegate.shared.chooseQuality(nil, media: episode) { torrent in
                AppDelegate.shared.play(episode, torrent: torrent)
            }
        }
    }

    /// What autoplay starts: the episode a `play` link names (nil when the
    /// show has no such episode: another one is not played in its place),
    /// else what Play starts.
    private var autoPlayTarget: Media? {
        guard playsLinkedEpisode, let linkedEpisode else { return playTarget }
        return show?.episodes.first { $0.season == linkedEpisode.season && $0.episode == linkedEpisode.episode }
    }

    /// Autoplay (a Continue Watching item, a `play` link): what Play starts
    /// or the link's episode, with the alert-style chooser the old autoplay
    /// used — once the page's sources are in.
    func startAutoPlay() {
        if let media = autoPlayTarget, playRemembered(media) { return }
        whenSourcesAreIn { [weak self] in
            guard let self else { return }
            guard let media = self.autoPlayTarget else {
                if self.playsLinkedEpisode, let linkedEpisode = self.linkedEpisode {
                    print("[DeepLink] S\(linkedEpisode.season)E\(linkedEpisode.episode) is not in the show's guide: nothing played")
                }
                return
            }
            if AppDelegate.shared.playRemembered(media) { return }
            AppDelegate.shared.chooseQuality(nil, media: media, replaysRemembered: true) { torrent in
                AppDelegate.shared.play(media, torrent: torrent)
            }
        }
    }

    /// The remembered release of `media` (`AppDelegate.playRemembered`);
    /// false: none — the press goes the usual way.
    private func playRemembered(_ media: Media) -> Bool {
        cancelPendingPress()
        guard AppDelegate.shared.playRemembered(media) else { return false }
        return true
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

    /// Re-reads the card's watched state and progress (unwatching deletes the
    /// saved progress), then Play and up-next.
    private func toggleEpisodeWatched(_ id: String) {
        guard let show, let row = model.episodes.firstIndex(where: { $0.id == id }) else { return }
        WatchedlistManager<Episode>.episode.toggle(id, title: TasteTitle(show: show))
        model.episodes[row] = GlassDetailAdapter.refreshed([model.episodes[row]])[0]
        refreshShowProgress(show)
    }

    // MARK: Downloads

    /// Download control pressed: start (choose a quality first) when there is
    /// no download; downloaded, Play or Delete; else the Downloads page's
    /// menu (Pause or Resume, Delete, Show in Downloads) — a press used to
    /// pause or resume without a word, and nothing said how to delete.
    private func pressDownload(of media: Media) {
        let state = currentDownloadState(of: media)
        guard state != .idle, let download = media.associatedDownload else {
            // A new download chooses its release: once the sources are in.
            let id = media.id
            whenSourcesAreIn { [weak self] in
                guard let self else { return }
                // Read once the sources are in: the torrents to choose from.
                let media: Media
                if let movie = self.movie, movie.id == id {
                    media = movie
                } else if let episode = self.episode(id) {
                    media = episode
                } else {
                    return
                }
                AppDelegate.shared.chooseQuality(self.view, media: media) { [weak self] torrent in
                    // Too big for the space left: said now, not as a failure later.
                    if let warning = DownloadsStore.shared.spaceWarning(for: torrent) {
                        let alert = UIAlertController(title: "Downloads.NoSpace.Title".localized, message: warning, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK".localized, style: .default, handler: nil))
                        self?.present(alert, animated: true)
                        return
                    }
                    PTTorrentDownloadManager.shared().startDownloading(fromFileOrMagnetLink: torrent.url, mediaMetadata: media.mediaItemDictionary,
                                                                       selectFileTDownload: PTTorrentStreamer.fileSelection(for: torrent.url, media: media, torrent: torrent))
                    self?.setDownloadState(.pending, of: media.id)
                }
            }
            return
        }
        if state == .downloaded {
            AppDelegate.shared.downloadControl(wasPressedIn: GlassDetailAdapter.buttonState(state),
                                               with: download,
                                               sourceView: view) { [weak self] newState in
                let progress = download.torrentStatus.totalProgress
                self?.setDownloadState(GlassDetailAdapter.downloadState(newState, progress: progress), of: media.id)
            }
            return
        }
        let store = DownloadsStore.shared
        store.refreshNow()
        guard let entry = store.entries.first(where: { $0.id == media.id }) else { return }
        DownloadsActionSheet.present(entry, showsGoToDownloads: true, from: self) { [weak self] action in
            switch action {
            case .pause: store.pause(media.id)
            case .resume: store.resume(media.id)
            case .retry: store.retry(media.id)
            case .play: store.play(media.id)
            case .delete:
                store.delete(media.id)
                self?.setDownloadState(.idle, of: media.id)
            case .showDownloads:
                let tabs = self?.tabBarController as? TVTabBarController
                    ?? AppDelegate.shared.window?.rootViewController as? TVTabBarController
                tabs?.select(.downloads)
            }
            if action == .pause || action == .resume {
                let progress = download.torrentStatus.totalProgress
                self?.setDownloadState(action == .pause ? .paused(progress: Double(progress)) : .downloading(progress: Double(progress)),
                                       of: media.id)
            }
        }
    }

    /// Long-press "Stop Download": asked in the Downloads page's sheet, then
    /// stopped and its files deleted (`DownloadsStore.delete`).
    private func stopDownload(of media: Media) {
        let store = DownloadsStore.shared
        store.refreshNow()
        guard let entry = store.entries.first(where: { $0.id == media.id }) else { return }
        DownloadsActionSheet.confirmDelete(entry, from: self) { [weak self] in
            store.delete(media.id)
            self?.setDownloadState(.idle, of: media.id)
        }
    }

    /// Long-press "Delete Download" on a finished download.
    private func deleteDownload(of media: Media) {
        DownloadsStore.shared.delete(media.id)
        setDownloadState(.idle, of: media.id)
    }

    private func currentDownloadState(of media: Media) -> GlassDownloadState {
        if media is Movie { return model.download ?? .idle }
        return model.episodes.first { $0.id == media.id }?.download ?? .idle
    }

    /// Writes a download state into the movie button or the matching episode.
    private func setDownloadState(_ state: GlassDownloadState, of mediaID: String) {
        if let movie, movie.id == mediaID {
            if model.download != state { model.download = state }
        } else if let row = model.episodes.firstIndex(where: { $0.id == mediaID }),
                  model.episodes[row].download != state {
            model.episodes[row].download = state
        }
    }

    // MARK: PTTorrentDownloadManagerListener

    @objc func torrentStatusDidChange(_ torrentStatus: PTTorrentStatus, for download: PTTorrentDownload) {
        let progress = Double(torrentStatus.totalProgress)
        onMain { [weak self] in
            guard let self, let id = GlassDetailAdapter.mediaID(of: download) else { return }
            let current: GlassDownloadState?
            if self.movie?.id == id {
                current = self.model.download
            } else {
                current = self.model.episodes.first(where: { $0.id == id })?.download
            }
            switch current {
            case .downloading?: self.setDownloadState(.downloading(progress: progress), of: id)
            case .paused?: self.setDownloadState(.paused(progress: progress), of: id)
            default: break
            }
        }
    }

    func downloadStatusDidChange(_ downloadStatus: PTTorrentDownloadStatus, for download: PTTorrentDownload) {
        let state = GlassDetailAdapter.downloadState(DownloadButton.State(downloadStatus),
                                                     progress: download.torrentStatus.totalProgress)
        onMain { [weak self] in
            guard let self, let id = GlassDetailAdapter.mediaID(of: download) else { return }
            self.setDownloadState(state, of: id)
        }
    }

    func downloadDidFail(_ download: PTTorrentDownload, withError error: Error) {
        onMain { [weak self] in
            guard let self, let id = GlassDetailAdapter.mediaID(of: download),
                  self.movie?.id == id || self.model.episodes.contains(where: { $0.id == id }) else { return }
            // The alert is `DownloadsStore`'s, wherever the user is: the button
            // goes back to Download.
            self.setDownloadState(.idle, of: id)
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: Trailer

    /// The movie's YouTube trailer in an AVPlayerViewController (XCDYouTubeKit
    /// stream, 720p then 360p then 240p), dismissed when it ends.
    private func playTrailer() {
        guard let movie, let id = movie.trailerCode else { return }
        ThemeSongManager.shared.stopTheme()
        let playerController = AVPlayerViewController()
        present(playerController, animated: true)

        XCDYouTubeClient.default().getVideoWithIdentifier(id) { [weak self, weak playerController] video, _ in
            DispatchQueue.main.async {
                guard let self, let playerController else { return }
                self.startTrailer(video, of: movie, in: playerController)
            }
        }
    }

    /// Plays the best of 720p, 360p, 240p, or tells why there is nothing to play.
    private func startTrailer(_ video: XCDYouTubeVideo?, of movie: Movie, in playerController: AVPlayerViewController) {
        let preferred = [XCDYouTubeVideoQuality.HD720.rawValue,
                         XCDYouTubeVideoQuality.medium360.rawValue,
                         XCDYouTubeVideoQuality.small240.rawValue]
        let streams = video?.streamURLs ?? [:]
        let url = preferred.lazy.compactMap { quality in
            streams.first { key, _ in Self.quality(of: key) == quality }?.value
        }.first

        guard let url else {
            playerController.dismiss(animated: true) {
                let alert = UIAlertController(title: "Error".localized, message: "Error fetching valid trailer URL from YouTube.".localized, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK".localized, style: .cancel, handler: nil))
                self.present(alert, animated: true)
            }
            return
        }

        let player = AVPlayer(url: url)
        player.currentItem?.externalMetadata = [
            AVMetadataItem.make(key: AVMetadataKey.commonKeyTitle.rawValue as NSString, value: movie.title as NSString),
            AVMetadataItem.make(key: AVMetadataKey.commonKeyDescription.rawValue as NSString, value: movie.summary as NSString),
        ]
        addArtwork(movie.mediumCoverImage, to: player.currentItem)
        playerController.player = player
        player.play()

        if let observer = trailerEndObserver { NotificationCenter.default.removeObserver(observer) }
        trailerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self, weak playerController] _ in
            guard let self else { return }
            if let observer = self.trailerEndObserver { NotificationCenter.default.removeObserver(observer) }
            self.trailerEndObserver = nil
            playerController?.dismiss(animated: true)
        }
    }

    /// XCDYouTubeKit keys its stream URLs by NSNumber quality (and a string
    /// for HLS).
    private static func quality(of key: AnyHashable) -> UInt? {
        if let number = key.base as? NSNumber { return number.uintValue }
        if let value = key.base as? UInt { return value }
        if let value = key.base as? Int, value >= 0 { return UInt(value) }
        return nil
    }

    /// Poster in the trailer's info panel, fetched off the main thread.
    private func addArtwork(_ image: String?, to item: AVPlayerItem?) {
        guard let item, let url = GlassDetailAdapter.url(image) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data else { return }
            DispatchQueue.main.async {
                item.externalMetadata.append(AVMetadataItem.make(key: AVMetadataKey.commonKeyArtwork.rawValue as NSString, value: data as NSData))
            }
        }.resume()
    }

    // MARK: Navigation

    /// A "Viewers Also Watched" poster: its page (`autoPlay`: then its
    /// playback, as Play/Pause on the grid).
    private func openRelated(_ id: String, autoPlay: Bool = false) {
        guard let media = relatedItems[id], let navigationController else { return }
        MainViewController.showDetail(of: media, on: navigationController, autoPlay: autoPlay)
    }

    /// A cast or crew member: their filmography page. Only for a Trakt
    /// person (IMDb "nm…" id) while Trakt answers: PersonViewController asks
    /// Trakt alone, so the keyless people (OpenMetadata: "tvmaze:…",
    /// "cinemeta:…" ids, or any id once Trakt refused the key) would open an
    /// empty page. Their headshots stay focusable so the shelf still scrolls.
    private func openPerson(_ id: String) {
        guard let person = people[id],
              person.imdbId.hasPrefix("nm"), TraktManager.shared.isSignedIn(), !TraktManager.anonymousAccessRefused,
              let navigationController,
              let vc = UIStoryboard.main.instantiateViewController(withIdentifier: "PersonViewController") as? PersonViewController
        else { return }
        vc.currentItem = person
        navigationController.pushViewController(vc, animated: true)
    }
}

#if DEBUG
extension GlassDetailHostingController {
    /// DEBUG launch hook (`-PTDebugFocusSection`, SceneDelegate): moves the
    /// focus into a lower section of the page, once that section has data.
    func debugFocus(section: String) {
        switch section {
        case "episodes":
            // The episode the shelf opens on (a link's, else the up-next
            // one) when it is in the season shown, else the season's first.
            let shown = model.episodesOfSelectedSeason
            let entry = model.entryEpisodeID.flatMap { id in shown.contains { $0.id == id } ? id : nil }
            if let id = entry ?? shown.first?.id { model.focusRequest = .episode(id) }
        case "related":
            if let id = model.related.first?.id { model.focusRequest = .related(id) }
        case "cast":
            if let id = model.people.first?.id { model.focusRequest = .person(id) }
        case "info":
            model.focusRequest = model.information.isEmpty ? .accessibility : .information
        default:
            break
        }
    }

    /// DEBUG launch hook (`-PTDebugQualityPicker`, SceneDelegate): the
    /// quality chooser Play shows, but a pick only logs: nothing plays.
    func debugChooseQuality() {
        guard let media = playTarget else { return }
        AppDelegate.shared.chooseQuality(view, media: media) { torrent in
            print("[Debug] quality picked, not played: \(torrent.quality ?? "?")")
        }
    }

    /// DEBUG launch hook (`-PTDebugPressPlay <seconds>`, SceneDelegate): a
    /// press on Play that many seconds after the page opened — kept until
    /// the sources are in when it comes before them, with its card — whose
    /// chooser only logs a pick: nothing plays.
    func debugPressPlay() {
        print("[Debug] Play pressed (dry run), sources: \(session.sources)")
        whenSourcesAreIn { [weak self] in
            print("[Debug] the press runs (dry run)")
            self?.debugChooseQuality()
        }
    }

    /// DEBUG (`-PTDebugDetailHealAfter <seconds>`): "Try Again".
    func debugRetry() {
        print("[Debug] Try Again pressed")
        retry()
    }

    /// DEBUG (`-PTDebugCancelPress <seconds>`): Menu on the card of a press
    /// that waits for the sources.
    func debugCancelPress() {
        print("[Debug] the pending press is cancelled: \(pressCard != nil)")
        cancelPendingPress()
    }
}
#endif

// MARK: - One set of chips per title

/// What the Home's card said of a title, handed to its page: the page opens
/// with the card's formats (the card is opened, then its page is made).
enum GlassDetailSeed {
    private static var badges: [String: [GlassBadge]] = [:]

    static func note(badges: [GlassBadge], of id: String) {
        Self.badges = badges.isEmpty ? [:] : [id: badges]
    }

    static func takeBadges(of id: String) -> [GlassBadge] {
        defer { badges = [:] }
        return badges[id] ?? []
    }
}

/// The capability chips of a page as its sources answer: a chip shown stays
/// (a later source that lacks the Atmos release does not take "Dolby Atmos"
/// away), a new kind is added, the resolution only goes up. One chip per
/// kind, in the page's order: resolution, Dolby Vision, HDR, audio.
enum GlassBadgeMerge {
    enum Kind: Int, CaseIterable {
        case resolution, dolbyVision, hdr, audio
    }

    static func kind(of badge: GlassBadge) -> Kind {
        switch badge.text {
        case "Dolby Vision": return .dolbyVision
        case "HDR", "HDR10", "HDR10+": return .hdr
        case "Dolby Atmos", "DTS:X": return .audio
        default: return .resolution
        }
    }

    private static func resolutionRank(_ badge: GlassBadge) -> Int {
        switch badge.text {
        case "4K": return 4
        case "1080p": return 3
        case "720p": return 2
        default: return 1
        }
    }

    static func merged(_ shown: [GlassBadge], _ fresh: [GlassBadge]) -> [GlassBadge] {
        var byKind: [Kind: GlassBadge] = [:]
        for badge in shown where byKind[kind(of: badge)] == nil { byKind[kind(of: badge)] = badge }
        for badge in fresh {
            let kind = kind(of: badge)
            if let current = byKind[kind] {
                if kind == .resolution, resolutionRank(badge) > resolutionRank(current) { byKind[kind] = badge }
            } else {
                byKind[kind] = badge
            }
        }
        return Kind.allCases.compactMap { byKind[$0] }
    }

    /// A Home card's formats as the page's chips.
    static func badges(of item: HomeItem) -> [GlassBadge] {
        return item.badges.filter(\.isFormat).map { GlassBadge(text: $0.label) }
    }
}
