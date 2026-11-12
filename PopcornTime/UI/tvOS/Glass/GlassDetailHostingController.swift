// GlassDetailHostingController.swift — the tvOS movie / show page. Hosts
// GlassDetailView and connects it to the app: the same quality chooser and
// players as before (AppDelegate.chooseQuality / play), the watchlist and
// watched lists, downloads, trailers, theme songs, related titles and the
// person page.
//
// MainViewController.loadDetail(of:behind:autoPlay:) loads the core media
// info behind the loading screen (`loadCore`), then pushes this controller.
// Related titles, cast & crew and missing episode stills load after the page
// is shown and fill it as they arrive (the logo is a metahub URL set by the
// adapter).
import UIKit
import SwiftUI
import AVKit
import PopcornKit
import PopcornTorrent
import XCDYouTubeKit

final class GlassDetailHostingController: UIHostingController<GlassDetailView>, PTTorrentDownloadManagerListener {

    private let model: GlassDetailModel
    private var movie: Movie?
    /// Episodes linked to the full show (`Show.linkingEpisodes()`).
    private var show: Show?
    /// The page was opened to play right away (a Continue Watching item):
    /// no theme song on that first appearance.
    private var skipsThemeOnce: Bool

    private var relatedItems: [String: Media] = [:]
    private var people: [String: Person] = [:]
    /// Seasons whose missing stills were already asked for.
    private var stillSeasons = Set<Int>()
    private var trailerEndObserver: NSObjectProtocol?

    private var media: Media? { movie ?? show }

    // MARK: - Loading

    /// The part of the page loaded behind the loading screen: the movie or
    /// show info (with the episode guide). Calls back on the main queue. A
    /// show without any episode fails with the old "no seasons" error.
    static func loadCore(of media: Media, completion: @escaping (Media?, NSError?) -> Void) {
        if media is Movie {
            PopcornKit.getMovieInfo(media.id) { movie, error in
                DispatchQueue.main.async { completion(movie, error) }
            }
            return
        }
        PopcornKit.getShowInfo(media.id) { show, error in
            DispatchQueue.main.async {
                if let error { return completion(nil, error) }
                guard let show, !show.seasonNumbers.isEmpty else {
                    let error = NSError(domain: "com.popcorntimetv.popcorntime.error", code: -243, userInfo: [NSLocalizedDescriptionKey: "There are no seasons available for the selected show. Please try again later.".localized])
                    return completion(nil, error)
                }
                completion(show, nil)
            }
        }
    }

    /// `media` is what `loadCore` returned (a Movie or a Show).
    init(media: Media, autoPlay: Bool = false) {
        skipsThemeOnce = autoPlay
        if let movie = media as? Movie {
            self.movie = movie
            model = GlassDetailAdapter.model(for: movie)
        } else {
            let show = (media as! Show).linkingEpisodes()
            self.show = show
            let season = show.latestUnwatchedEpisode()?.season ?? GlassDetailAdapter.firstSeason(of: show)
            model = GlassDetailAdapter.model(for: show, season: season)
        }
        super.init(rootView: GlassDetailView(model: model))
        rootView = GlassDetailView(model: model, actions: makeActions())
        navigationItem.title = media.title
    }

    @available(*, unavailable, message: "Created in code by MainViewController.loadDetail")
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        PTTorrentDownloadManager.shared().remove(self)
        if let trailerEndObserver { NotificationCenter.default.removeObserver(trailerEndObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        PTTorrentDownloadManager.shared().add(self)
        loadRelated()
        loadPeople()
        if let season = model.selectedSeason { loadMissingStills(of: season) }
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
            TraktManager.shared.getRelated(movie) { related, _ in finish(related) }
        } else if let show {
            TraktManager.shared.getRelated(show) { related, _ in finish(related) }
        }
    }

    /// Trakt cast & crew. The call only answers once every headshot is known,
    /// which is why the page no longer waits for it.
    private func loadPeople() {
        guard let media else { return }
        model.isLoadingPeople = true
        TraktManager.shared.getPeople(forMediaOfType: media is Movie ? .movies : .shows, id: media.id) { [weak self] actors, crew, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let result = GlassDetailAdapter.people(actors: actors, crew: crew)
                self.people = result.people
                self.model.people = result.items
                self.model.isLoadingPeople = false
                if var movie = self.movie {
                    // Director(s) and Starring rows of the Information card.
                    movie.actors = actors
                    movie.crew = crew
                    self.movie = movie
                    self.model.information = GlassDetailAdapter.information(for: movie)
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
            // Resolve the show's TMDB id once instead of once per episode.
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
        guard let row = model.episodes.firstIndex(where: { $0.id == id }) else { return }
        let episode = show.episodes[index]
        let old = model.episodes[row]
        model.episodes[row] = GlassEpisode(id: old.id, season: old.season, number: old.number,
                                           title: old.title, summary: old.summary,
                                           stillURL: GlassDetailAdapter.url(episode.smallBackgroundImage ?? episode.largeBackgroundImage),
                                           detail: old.detail, isWatched: old.isWatched,
                                           progress: old.progress, download: old.download)
    }

    // MARK: - Appearance

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        refreshLiveState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if skipsThemeOnce {
            skipsThemeOnce = false
        } else {
            playThemeSong()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        ThemeSongManager.shared.stopTheme()
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
        let play = GlassDetailAdapter.nextEpisode(in: show).map(GlassDetailAdapter.playInfo(for:))
        if play != model.play { model.play = play }
        let upNext = show.latestUnwatchedEpisode()?.id
        if upNext != model.upNextEpisodeID { model.upNextEpisodeID = upNext }
    }

    private func playThemeSong() {
        guard GlassSettingsStore.themeSongs else { return }
        if let movie {
            ThemeSongManager.shared.playMovieTheme(movie.title)
        } else if let show, let tvdbId = Int(show.tvdbId), tvdbId > 0 {
            ThemeSongManager.shared.playShowTheme(tvdbId)
        }
    }

    // MARK: - Actions

    private func makeActions() -> GlassDetailActions {
        var actions = GlassDetailActions()
        actions.play = { [weak self] in self?.play() }
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
        actions.selectSeason = { [weak self] season in self?.loadMissingStills(of: season) }
        actions.openRelated = { [weak self] id in self?.openRelated(id) }
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

    /// Play: same chooser and player as the old Play button (action-sheet
    /// style, anchored on the page).
    private func play() {
        guard let media = playTarget else { return }
        AppDelegate.shared.chooseQuality(view, media: media) { torrent in
            AppDelegate.shared.play(media, torrent: torrent)
        }
    }

    /// An episode card: alert-style chooser, as the old episode row.
    private func playEpisode(_ id: String) {
        guard let episode = episode(id) else { return }
        AppDelegate.shared.chooseQuality(nil, media: episode) { torrent in
            AppDelegate.shared.play(episode, torrent: torrent)
        }
    }

    /// Autoplay (a Continue Watching item): what Play starts, with the
    /// alert-style chooser the old autoplay used.
    func startAutoPlay() {
        guard let media = playTarget else { return }
        AppDelegate.shared.chooseQuality(nil, media: media) { torrent in
            AppDelegate.shared.play(media, torrent: torrent)
        }
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
        WatchedlistManager<Episode>.episode.toggle(id)
        model.episodes[row] = GlassDetailAdapter.refreshed([model.episodes[row]])[0]
        refreshShowProgress(show)
    }

    // MARK: Downloads

    /// Download control pressed: start (choose a quality first) when there is
    /// no download, else pause / resume / Play-or-Delete like DownloadButton.
    private func pressDownload(of media: Media) {
        let state = currentDownloadState(of: media)
        guard state != .idle, let download = media.associatedDownload else {
            AppDelegate.shared.chooseQuality(view, media: media) { [weak self] torrent in
                PTTorrentDownloadManager.shared().startDownloading(fromFileOrMagnetLink: torrent.url, mediaMetadata: media.mediaItemDictionary,
                                                                   selectFileTDownload: PTTorrentStreamer.fileSelection(for: torrent.url, media: media, torrent: torrent))
                self?.setDownloadState(.pending, of: media.id)
            }
            return
        }
        AppDelegate.shared.downloadControl(wasPressedIn: GlassDetailAdapter.buttonState(state),
                                           with: download,
                                           sourceView: view) { [weak self] newState in
            let progress = download.torrentStatus.totalProgress
            self?.setDownloadState(GlassDetailAdapter.downloadState(newState, progress: progress), of: media.id)
        }
    }

    /// Long-press "Stop Download": the old confirmation alert.
    private func stopDownload(of media: Media) {
        guard let download = media.associatedDownload else { return }
        AppDelegate.shared.downloadButton(nil, wantsToStop: download) { [weak self] in
            self?.setDownloadState(.idle, of: media.id)
        }
    }

    /// Long-press "Delete Download" on a finished download.
    private func deleteDownload(of media: Media) {
        guard let download = media.associatedDownload else { return }
        PTTorrentDownloadManager.shared().delete(download)
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
            AppDelegate.shared.download(download, failedWith: error)
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

    /// A "Viewers Also Watched" poster: the loading screen, then its page.
    private func openRelated(_ id: String) {
        guard let media = relatedItems[id], let navigationController else { return }
        MainViewController.showDetail(of: media, on: navigationController)
    }

    /// A cast or crew member: their filmography page. Only for a Trakt
    /// person (IMDb "nm…" id) while Trakt answers: PersonViewController asks
    /// Trakt alone, so the keyless people (OpenMetadata: "tvmaze:…",
    /// "cinemeta:…" ids, or any id once Trakt refused the key) would open an
    /// empty page. Their headshots stay focusable so the shelf still scrolls.
    private func openPerson(_ id: String) {
        guard let person = people[id],
              person.imdbId.hasPrefix("nm"), !TraktManager.anonymousAccessRefused,
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
            if let id = model.upNextEpisodeID ?? model.episodesOfSelectedSeason.first?.id { model.focusRequest = .episode(id) }
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
}
#endif
