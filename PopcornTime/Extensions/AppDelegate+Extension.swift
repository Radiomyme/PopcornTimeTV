

import Foundation
import PopcornKit
import PopcornTorrent
import MediaPlayer.MPMediaItem
import AlamofireImage

extension AppDelegate: PCTPlayerViewControllerDelegate, UIViewControllerTransitioningDelegate {

    /// Free every cache we control to reclaim sandbox space when libtorrent
    /// reports "not enough space". On Apple TV the per-app sandbox is
    /// fairly small (~7-12 GB) and a 4K HEVC torrent at 6-10 GB sits right
    /// on the edge — wiping image caches / HTTP caches typically
    /// recovers a few hundred MB to several GB, enough to push the same
    /// torrent through.
    static func aggressivelyFreeDiskSpace() {
        let fm = FileManager.default

        // 1) Stale torrent partials under tmp/Downloads/ (already a no-op
        //    in the common case since we purge before each stream, but
        //    guards against partial leftovers from the failed start).
        //    Deleted before the retry measures the free space.
        purgeOrphanTorrentDownloads(waitsForDeletion: true)

        // 2) Foundation URLCache (HTTP responses cached by Alamofire).
        URLCache.shared.removeAllCachedResponses()

        // 3) AlamofireImage's URLCache (covers both Alamofire HTTP and
        //    AlamofireImage's poster downloads). We don't try to reach the
        //    in-memory `ImageCache` because each `UIImageView.af` extension
        //    can attach its own and there's no global accessor.
        ImageDownloader.defaultURLCache().removeAllCachedResponses()
        // The artwork pipeline's own cache (posters, backdrops, logos):
        // emptied through its URLCache, which would otherwise keep its
        // files open after step 5 unlinks them.
        ArtworkPipeline.shared.removeAllCachedData()

        // 4) Anything left in NSTemporaryDirectory() that isn't claimed
        //    by an active streamer (after step 1).
        let tmp = NSTemporaryDirectory()
        if let entries = try? fm.contentsOfDirectory(atPath: tmp) {
            for entry in entries where entry != "Downloads" {
                let p = (tmp as NSString).appendingPathComponent(entry)
                try? fm.removeItem(atPath: p)
            }
        }

        // 5) NSCachesDirectory for the app — system reclaims this on
        //    pressure but doing it ourselves makes the freed bytes visible
        //    to libtorrent immediately. Never Caches/Downloads: on tvOS the
        //    offline downloads (PTTorrentDownloadManager) live there.
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            if let entries = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
                for entry in entries where entry.lastPathComponent != Self.offlineDownloadsFolderName {
                    try? fm.removeItem(at: entry)
                }
            }
        }
        print("[Cache] aggressivelyFreeDiskSpace done")
    }

    /// The folder of the offline downloads under Caches on tvOS
    /// (PTTorrentDownloadManager's `Caches/Downloads`): never wiped by
    /// `aggressivelyFreeDiskSpace`.
    static let offlineDownloadsFolderName = "Downloads"
}

extension AppDelegate {

    /// Sources that did not answer, per movie / episode id (the loading
    /// screen's « Choose another source »), as `sourceKey`s: left out of
    /// that title's pickers and automatic picks for this session — an
    /// episode's aggregators would list them again.
    static var unansweredSources: [String: Set<String>] = [:]

    /// A source's identity across providers: the magnet's info-hash
    /// (lower-cased), else the URL (a .torrent).
    static func sourceKey(_ url: String) -> String {
        return MagnetLink.sourceKey(of: url)
    }

    /// The episode whose sources are being fetched: a second request
    /// meanwhile (a second press) is dropped.
    private static var fetchingSourcesFor: String?

    /// - Parameter excluding: `sourceKey`s left out of the choice (sources
    ///   that did not answer), on top of `unansweredSources` for the media.
    /// - Parameter replaysRemembered: an episode's Play / Home card (not a
    ///   link, not an episode row): once its sources are in, what was
    ///   played replays without the chooser (`playRemembered`: a pack only
    ///   VLC plays when no native release is listed, a release in clear
    ///   continuity with the show's last one, D4).
    func chooseQuality(_ sender: UIView?, media: Media, excluding: Set<String> = [], replaysRemembered: Bool = false,
                       completion: @escaping (Torrent) -> Void) {
        // « Vos langues »: the releases sort for this title's type (Continue
        // Watching and links come here without a page).
        PlaybackLanguagePreferences.focusTitle(media)
        let excluded = excluding.union(AppDelegate.unansweredSources[media.id] ?? [])
        // Episodes: EZTV only carries what its uploaders pushed, so before
        // picking a quality, ask the Torrentio aggregator (YTS/RARBG-archive/
        // 1337x/TorrentGalaxy/…) AND the Time4Popcorn backend for that exact
        // episode and merge both. This fills gaps (old seasons EZTV lacks)
        // and adds extra releases. Movies are already merged at detail-load
        // time by the provider. The requests take up to 3 s (the resolver's
        // deadline) before a chooser, longer before a release played without
        // asking or « No torrents found » (`isEnough` below): a busy card
        // says so meanwhile (and takes the remote: no second press; Menu
        // cancels).
        if let episode = media as? Episode, let showId = episode.show?.id, showId.hasPrefix("tt") {
            guard AppDelegate.fetchingSourcesFor == nil else {
                print("[chooseQuality] sources of \(AppDelegate.fetchingSourcesFor ?? "?") still loading: request for \(episode.id) dropped")
                return
            }
            AppDelegate.fetchingSourcesFor = episode.id
            var cancelled = false
            let busy = SourcesBusyViewController()
            busy.onCancel = {
                guard !cancelled else { return }
                cancelled = true
                AppDelegate.fetchingSourcesFor = nil
                print("[chooseQuality] sources of \(episode.id): cancelled")
            }
            // The screen the request came from (a show's page; under a player
            // for Up Next). Back pressed before the card showed (its first
            // 0.4 s) left it: the request is dropped then, instead of the card,
            // then the chooser, coming over the grid for a page the user left.
            let origin = activeViewController
            let originLeft: () -> Bool = { [weak self, weak origin] in
                guard let self = self, let origin = origin else { return true }
                return origin !== self.activeViewController || origin.viewIfLoaded?.window == nil
            }
            busy.isStillWanted = { !originLeft() }
            busy.showSoon()

            // DEBUG `-PTDebugSourcesDelay <s>`: the sources answer that much
            // later (the busy card on screen, Menu to cancel it).
            #if DEBUG
            let answerDelay = UserDefaults.standard.string(forKey: "PTDebugSourcesDelay").flatMap(Double.init) ?? 0
            #else
            let answerDelay: TimeInterval = 0
            #endif
            // The episode with these sources merged in: Time4Popcorn primary,
            // EZTV + Torrentio + TPB / Knaben as fallback (a TPB / Knaben
            // copy of a listed torrent keeps the listed row), the show's
            // runtime on every candidate first — with their sizes it gives
            // the bitrates, so the merge keeps the releases the connection
            // can carry (`precedesInListing`).
            let list: (EpisodeSourceResolver.Sources) -> [Torrent] = { sources in
                sources.merged(withBase: episode.torrents, runtime: Torrent.mediaRuntime(of: episode))
                    .filter { !excluded.contains(AppDelegate.sourceKey($0.url)) }
            }
            let augment: (EpisodeSourceResolver.Sources, Bool) -> Episode = { sources, isLate in
                var augmented = episode
                augmented.torrents = list(sources)
                print("[chooseQuality] episode S\(episode.season)E\(episode.episode): \(sources.time4Popcorn.count) t4p + \(episode.torrents.count) EZTV + \(sources.torrentio.count) aggregated + \(sources.extra.count) TPB/Knaben -> \(augmented.torrents.count)"
                      + (sources.isComplete ? "" : " (not in yet: \(sources.missing.map { $0.rawValue }.joined(separator: ", ")))")
                      + (excluded.isEmpty ? "" : " (\(excluded.count) source(s) that did not answer left out)"))
                // The callers play the bare episode (its own list is EZTV's):
                // its stream learns the merged list from here — another
                // source, a lighter release (`BandwidthDeficitMonitor`). A
                // list completed after the chooser never replaces the one
                // of another title chosen since.
                if isLate {
                    PlaybackStreamContext.noteLateSources(augmented.torrents, forMediaID: episode.id)
                } else {
                    PlaybackStreamContext.noteSources(augmented.torrents, forMediaID: episode.id)
                }
                return augmented
            }
            // The three sources behind one deadline (`EpisodeSourceResolver`):
            // the chooser comes with what answered in time — a source that is
            // down no longer holds every episode for its 10 s timeout — and
            // an answer is kept for the next press (another source, Up Next,
            // the page's prefetch).
            // A list a source may still complete is only good for a chooser,
            // where the user picks among several releases. What is decided
            // without asking — an automatic quality, a lone torrent played at
            // once, « No torrents found » — waits for every source still
            // expected (not one on the bench: a host that is down).
            let picksAlone = AppDelegate.picksQualityAlone
            EpisodeSourceResolver.shared.resolve(showId: showId, showTitle: episode.show?.title,
                                                 season: episode.season, episode: episode.episode,
                                                 isEnough: { sources in
                let count = list(sources).count
                if count > 1, !picksAlone { return true }
                return count > 0 && sources.awaited.isEmpty
            }, completion: { [weak self] sources in
                DispatchQueue.main.asyncAfter(deadline: .now() + answerDelay) {
                    guard !cancelled else { return }
                    if originLeft() {
                        print("[chooseQuality] sources of \(episode.id): the page was left, no chooser")
                        busy.onCancel?()
                        busy.finish {}
                        return
                    }
                    AppDelegate.fetchingSourcesFor = nil
                    let augmented = augment(sources, false)
                    busy.finish {
                        if replaysRemembered, self?.playRemembered(augmented, candidates: augmented.torrents) == true { return }
                        self?.presentQualityChoice(sender, media: augmented, completion: completion)
                    }
                }
            }, late: { sources in
                // A source answered after the chooser came up: the stream's
                // other releases (another source, a lighter one) know it.
                guard !cancelled else { return }
                _ = augment(sources, true)
            })
            return
        }
        var media = media
        if !excluded.isEmpty {
            media.torrents.removeAll { excluded.contains(AppDelegate.sourceKey($0.url)) }
        }
        presentQualityChoice(sender, media: media, completion: completion)
    }

    /// "autoSelectQuality" is Balanced (Quick Start and Best Picture too,
    /// with their priority): a release is played without asking
    /// (`presentQualityChoice`).
    private static var picksQualityAlone: Bool {
        let preference = UserDefaults.standard.string(forKey: "autoSelectQuality") ?? "Off".localized
        return preference == "Balanced".localized
    }

    private func presentQualityChoice(_ sender: UIView?, media: Media, completion: @escaping (Torrent) -> Void) {
        // Auto-pick behaviour is controlled by the "autoSelectQuality" setting:
        //   Balanced — highest resolution the swarm can stream fast and the
        //     connection can carry (skips a lightly-seeded 4K for a
        //     well-seeded 1080p, and a 4K remux heavier than the measured
        //     connection: `Torrent.balancedPick`), steered by its priority
        //     (Quick Start / Balanced / Best Picture: `SourcePreferences`);
        //   Off      — always ask.
        // (« Highest » and « Lowest » were retired after 5.4.0: launch turns
        // them into Best Picture and Quick Start,
        // `AutomaticQualityChoice.migrateRetiredChoices`.)
        // Default to "Off" (always show the picker) so the user can weigh
        // quality vs seeds themselves — the rich chooser below stars the
        // recommended pick and pre-focuses it, so accepting the smart default
        // is still one click. Choose Quick Start, Balanced or Best Picture
        // in Settings to auto-pick instead.
        let preference = UserDefaults.standard.string(forKey: "autoSelectQuality") ?? "Off".localized
        // Runtime attached so each release has an estimated bitrate (size /
        // runtime) for the recommendation and the labels; the connection is
        // measured from now on (idempotent).
        ConnectionSpeed.shared.start()
        let torrents   = media.torrents.withMediaRuntime(of: media)
        var sorted     = torrents.sorted(by: <)

        #if targetEnvironment(simulator)
        // The tvOS Simulator runs on the Mac with no HEVC HW decoder, so 4K
        // HEVC takes minutes to start and stutters. Cap auto-pick at 1080p
        // for simulator runs only — the real Apple TV 4K still gets the
        // 2160p stream.
        let simulatorCap: VideoQuality = .hd1080
        sorted = sorted.filter { $0.qualityValue <= simulatorCap }
        if sorted.isEmpty { sorted = torrents.sorted(by: <) }
        print("[chooseQuality] simulator cap applied: max=\(simulatorCap)")
        #endif

        let connection = StreamBandwidth.connectionEstimate
        print("[chooseQuality] media=\(media.title) preference=\(preference) connection=\(connection.map { String(format: "%.1f Mb/s", StreamBandwidth.megabitsPerSecond($0)) } ?? "unknown") candidates=\(sorted.map { "\($0.quality ?? "?")(\($0.qualityValue)) s\($0.seeds)\($0.estimatedBitrate.map { String(format: " %.0fMb/s", StreamBandwidth.megabitsPerSecond($0)) } ?? "")" })")

        if preference == "Balanced".localized, let best = Torrent.balancedPick(from: sorted, connection: connection) {
            print("[chooseQuality] picked BALANCED: quality=\(best.quality ?? "?") seeds=\(best.seeds) fit=\(best.bandwidthFit(connection: connection))")
            return completion(best)
        }
        guard media.torrents.count > 1 else {
            if let torrent = media.torrents.first {
                completion(torrent)
            } else {
                let alertController = UIAlertController(title: "No torrents found".localized, message: "Torrents could not be found for the specified media.".localized, preferredStyle: .alert)
                // .cancel: Menu closes it on the Apple TV.
                alertController.addAction(UIAlertAction(title: "OK".localized, style: .cancel, handler: nil))
                alertController.show(animated: true)
            }
            return
        }

        let style: UIAlertController.Style = sender == nil ? .alert : .actionSheet
        let blurStyle: UIBlurEffect.Style  = style == .alert ? .extraLight : .dark
        let alertController = UIAlertController(title: "Choose Quality".localized, message: nil, preferredStyle: style, blurStyle: blurStyle)

        // Enrich each row with seeds + size + estimated bitrate so the best
        // quality/seeds ratio is visible at a glance (like the iOS/macOS
        // pickers), and star the recommended `balancedPick`. A release likely
        // too heavy for the connection starts with "⚠︎", explained once in
        // the alert's message (a "(may stutter)" in each row made them too
        // long). Best resolution first. The source (TPB, Knaben · 1337x, a
        // Torrentio indexer…) when the row has room, and the language tag
        // last (`Torrent.tvChooserLabel`, shared with the Up Next chooser).
        let recommendedURL = Torrent.balancedPick(from: sorted, connection: connection)?.url
        var recommendedAction: UIAlertAction?
        var flagged = false
        for torrent in sorted.reversed() {
            let tooHeavy = torrent.bandwidthFit(connection: connection).isTooHeavy
            if tooHeavy { flagged = true }
            let label = torrent.tvChooserLabel(recommended: torrent.url == recommendedURL, tooHeavy: tooHeavy)
            let action = UIAlertAction(title: label, style: .default) { _ in completion(torrent) }
            alertController.addAction(action)
            if torrent.url == recommendedURL { recommendedAction = action }
        }
        if flagged {
            alertController.message = "⚠︎ " + BandwidthText.warning(connection: connection)
        }

        alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
        // Put initial focus on the recommended pick.
        if let recommendedAction = recommendedAction { alertController.preferredAction = recommendedAction }
        alertController.popoverPresentationController?.sourceView = sender
        alertController.show(animated: true)
    }

    func play(_ media: Media, torrent: Torrent) {
        play(media, torrent: torrent, hasAutoCleanedForDiskFull: false)
    }

    /// Internal entry point so the disk-full handler can call back with a
    /// flag noting we already burnt through every cache and should stop
    /// looping if the same torrent fails again.
    private func play(_ media: Media,
                      torrent: Torrent,
                      hasAutoCleanedForDiskFull: Bool) {
        // What `playRemembered` decided belongs to that one playback: another
        // title or release drops it (its patience, its forgetting, its start).
        if let remembered = AppDelegate.rememberedReplay, remembered.mediaID != media.id || remembered.url != torrent.url {
            AppDelegate.rememberedReplay = nil
        }
        PlaybackStreamContext.dropRequestedStart(unlessFor: torrent.url)
        if UIDevice.current.hasCellularCapabilites && reachability.connection != .wifi && !UserDefaults.standard.bool(forKey: "streamOnCellular")  {

            let alertController = UIAlertController(title: "Cellular Data is turned off for streaming".localized, message: nil, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "Turn On".localized, style: .default) { [unowned self] _ in
                UserDefaults.standard.set(true, forKey: "streamOnCellular")
                self.play(media, torrent: torrent)
            })
            alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
            return alertController.show(animated: true)
        }

        // A playback starts (the loading screen, then the player): the
        // decoded posters and backdrops are not needed while a film plays,
        // their memory goes (the disk cache keeps them).
        ArtworkPipeline.shared.purgeMemory()

        let storyboard = UIStoryboard.main
        var media = media
        
        let currentProgress = media is Movie ? WatchedlistManager<Movie>.movie.currentProgress(media.id) : WatchedlistManager<Episode>.episode.currentProgress(media.id)
        var nextEpisode: Episode?
        #if DEBUG
        // `-PTDebugResumeTrace` (BoundedStorageDebugHooks): the saved
        // progress this playback starts from, as the library gave it.
        if UserDefaults.standard.object(forKey: "PTDebugResumeTrace") != nil {
            print("[ResumeDebug] play(\(media.id)): saved progress read = \(currentProgress)")
        }
        #endif

        let loadingViewController = storyboard.instantiateViewController(withIdentifier: "PreloadTorrentViewController") as! PreloadTorrentViewController
        loadingViewController.transitioningDelegate = self
        // loadViewIfNeeded, NOT loadView(): calling loadView() directly wires
        // the outlets but bypasses UIKit's loading machinery, so viewDidLoad
        // never fires — anything the controller sets up there silently
        // doesn't exist (this is why the buffering %/ETA label never showed).
        loadingViewController.loadViewIfNeeded()
        
        let backgroundImage: String?
        
        if let episode = media as? Episode, let show = episode.show {
            backgroundImage = show.largeBackgroundImage
            var episodesLeftInShow = [Episode]()
            
            for season in show.seasonNumbers where season >= episode.season {
                episodesLeftInShow += show.episodes.filter({$0.season == season}).sorted(by: { $0.episode < $1.episode })
            }
            
            if let index = episodesLeftInShow.firstIndex(of: episode) {
                episodesLeftInShow.removeFirst(index + 1)
            }
            
            // Up Next proposes the following episode only once it can be
            // played: the guide also lists announced episodes (future air
            // date, no torrent), which would end on "No torrents found".
            nextEpisode = episodesLeftInShow.first.flatMap { $0.isAvailableToPlay ? $0 : nil }
            nextEpisode?.show = episode.show
        } else {
            backgroundImage = media.largeBackgroundImage
        }
        
        if let image = backgroundImage, let url = URL(string: image) {
            loadingViewController.backgroundImageView?.af.setImage(withURL: url)
        }
        loadingViewController.titleLabel.text = media.title
        // Episode chaining (5.3.0): this playback's session, begun by the
        // player that plays it (`UpNextTVLink.attach`); nil for a movie.
        let upNext = UpNextTVLink(media: media)
        // « Resume » replaying the remembered release (`playRemembered`): a
        // source that does not answer is offered another one sooner (D5).
        if let remembered = AppDelegate.rememberedReplay, remembered.mediaID == media.id, remembered.url == torrent.url {
            loadingViewController.noPeerPatience = UpNextResume.patience
        }
        
        // The detail page's theme song must not play over the buffering
        // screen and the movie (the page also stops it when it disappears).
        ThemeSongManager.shared.stopTheme()
        // Presented at once, its content fading in (`fadesInOnAppear`): UIKit
        // drops the remote's presses while a presentation animates (1 s from
        // a page), so Back pressed as the screen came in was lost.
        loadingViewController.fadesInOnAppear = true
        present(loadingViewController, animated: false)
        
        // `failure`: what PopcornTorrent's error means (nil: another error,
        // judged by its text as before).
        let failed: (String, StreamFailure?) -> Void = { [weak self] (errorMessage, failure) in
            guard let self = self else { return }

            // libtorrent's "not enough space" message is reported in
            // localized form (`There is not enough space to download the
            // torrent. Please clear at least 7.86 GB…`). Apple TV's app
            // sandbox is way smaller than the disk space shown in Réglages
            // — typically 7-10 GB usable — so picking a 4K HEVC release on
            // a fresh launch reliably trips this. Detect the substring (in
            // both English and French to cover the localized libtorrent
            // build) and offer a one-tap downgrade to the next-lower
            // quality torrent rather than an unhelpful OK alert.
            // PopcornTorrent's codes first: -4 (doesn't fit / disk full) and
            // -5 (not even bounded storage can run: the message says how
            // much to free) both are disk-space failures; -6 (another file
            // error) is not.
            let isDiskFullError = failure.map { $0.isDiskSpace }
                ?? (errorMessage.localizedCaseInsensitiveContains("not enough space")
                    || errorMessage.localizedCaseInsensitiveContains("pas assez d'espace")
                    || errorMessage.localizedCaseInsensitiveContains("not enough disk"))
            // -5: the computed amount to free goes into the lower-quality offer.
            let spaceToFree: String? = {
                if case .notEnoughSpaceForBoundedStorage(let bytes)? = failure, bytes > 0 { return errorMessage }
                return nil
            }()

            // Find a smaller candidate from the same media — strictly
            // smaller `qualityValue` than what we just tried (a known
            // resolution, never a 3D release), the best ranked of those.
            // Not the next row of the ranking, which is usually the same
            // resolution; and the failed torrent need not be in
            // `media.torrents` (an episode's extra-source rows are not).
            // « Resume » on the remembered release: it failed, it is
            // forgotten — not for this Apple TV's own lack of space.
            if !isDiskFullError {
                AppDelegate.forgetRememberedReleaseIfReplayed(mediaID: media.id, url: torrent.url)
            }

            let smaller: Torrent? = media.torrents
                .filter { $0.qualityValue < torrent.qualityValue && $0.qualityValue > .threeD }
                .max(by: <)

            // Always tear down the half-started loading VC so we can
            // present the alert cleanly.
            let dismissThen: (@escaping () -> Void) -> Void = { next in
                if self.window?.rootViewController?.presentedViewController != nil {
                    self.dismiss(animated: false, completion: next)
                } else {
                    next()
                }
            }

            dismissThen {
                if isDiskFullError && !hasAutoCleanedForDiskFull {
                    // First disk-full hit: silently nuke every cache we
                    // can reach (URLCache, Alamofire/AlamofireImage caches,
                    // tmp/Caches dirs, leftover torrent partials), then
                    // retry the *same* torrent. The user never sees a
                    // popup unless it fails again.
                    print("[Play] disk-full → wiping all caches and retrying \(torrent.quality ?? "?")")
                    AppDelegate.aggressivelyFreeDiskSpace()
                    self.play(media, torrent: torrent, hasAutoCleanedForDiskFull: true)
                    return
                }

                if isDiskFullError, let fallback = smaller {
                    // Second hit (or no auto-clean possible) — offer the
                    // user the next-lower quality.
                    let title = String(format: NSLocalizedString("DiskFull.Title", value: "Not enough space for this %@ release",
                                                                 comment: "Alert title when a release does not fit; %@ = its quality (1080p, 2160p…)"),
                                       torrent.quality ?? "?")
                    let body  = spaceToFree.map {
                        $0 + "\n\n" + NSLocalizedString("BoundedStorage.TryLowerQuality", value: "Try a lower quality?",
                                                        comment: "After the space to free, offers a smaller release")
                    } ?? NSLocalizedString("DiskFull.Message",
                                           value: "The Apple TV does not have enough room in the app's cache to download this torrent. Try a lower quality?",
                                           comment: "Alert message when a release does not fit the Apple TV's app cache")
                    let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
                    let retryTitle = fallback.quality.map {
                        String(format: NSLocalizedString("DiskFull.RetryIn", value: "Try again in %@",
                                                         comment: "Button: play the smaller release; %@ = its quality (720p…)"), $0)
                    } ?? NSLocalizedString("DiskFull.RetryLower", value: "Try a lower quality",
                                           comment: "Button: play a smaller release (its quality unknown)")
                    alert.addAction(UIAlertAction(title: retryTitle, style: .default) { _ in
                        self.play(media, torrent: fallback)
                    })
                    alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                    alert.show(animated: true)
                } else if case .episodeNotInTorrent? = failure {
                    // A season pack without the episode (PopcornTorrent -9):
                    // left out of this title's pickers and automatic picks
                    // (an automatic pick took the same pack again), and the
                    // quality picker one press away.
                    AppDelegate.unansweredSources[media.id, default: []].insert(AppDelegate.sourceKey(torrent.url))
                    // « Choose another source » only when one is known (the
                    // stream's list minus this one and those left out), as on
                    // the loading screen: with none, the picker ended on « No
                    // torrents found ». Menu closes the alert either way.
                    let excluded = AppDelegate.unansweredSources[media.id] ?? []
                    let known = PlaybackStreamContext.of(loadingViewController.streamer)?.sources ?? media.torrents
                    let hasOtherSource = known.contains { !excluded.contains(AppDelegate.sourceKey($0.url)) }
                    let alert = UIAlertController(title: "Error".localized, message: errorMessage, preferredStyle: .alert)
                    if hasOtherSource {
                        alert.addAction(UIAlertAction(title: LoadingPhase.chooseAnotherSourceTitle, style: .default) { _ in
                            self.chooseQuality(nil, media: media) { torrent in
                                self.play(media, torrent: torrent)
                            }
                        })
                        alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                    } else {
                        alert.addAction(UIAlertAction(title: "OK".localized, style: .cancel, handler: nil))
                    }
                    alert.show(animated: true)
                } else {
                    // Any other failure (a torrent error, a file error, a
                    // release that does not fit with no smaller one): the
                    // same way out when another source is known — this
                    // alert used to end on « OK », back on the page. The
                    // failed source is left out of that one choice only (an
                    // automatic pick would take it again); it is not
                    // remembered as dead.
                    let failedKey = AppDelegate.sourceKey(torrent.url)
                    let excluded = (AppDelegate.unansweredSources[media.id] ?? []).union([failedKey])
                    let known = PlaybackStreamContext.of(loadingViewController.streamer)?.sources ?? media.torrents
                    let hasOtherSource = !torrent.url.isEmpty
                        && known.contains { !excluded.contains(AppDelegate.sourceKey($0.url)) }
                    let alert = UIAlertController(title: "Error".localized, message: errorMessage, preferredStyle: .alert)
                    if hasOtherSource {
                        alert.addAction(UIAlertAction(title: LoadingPhase.chooseAnotherSourceTitle, style: .default) { _ in
                            self.chooseQuality(nil, media: media, excluding: [failedKey]) { torrent in
                                self.play(media, torrent: torrent)
                            }
                        })
                        alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                    } else {
                        alert.addAction(UIAlertAction(title: "OK".localized, style: .cancel, handler: nil))
                    }
                    alert.show(animated: true)
                }
            }
        }
        
        let error: (String) -> Void = { failed($0, nil) }
        let streamFailed: (StreamFailure, String) -> Void = { failed($1, $0) }

        let finishedLoading: (PreloadTorrentViewController, UIViewController) -> Void = { [weak self] (loadingVc, playerVc) in
            guard let self = self else { return }
            // Back closed the loading screen: no player for a title the user left.
            guard !loadingVc.isCancelled else {
                print("[Play] finishedLoading after Back — no player")
                return
            }
            let flag = UIDevice.current.userInterfaceIdiom != .tv
            print("[Play] finishedLoading — presenting player VC")
            // The remembered release answered: its 20 s patience and its
            // forgetting were for this start only.
            if let remembered = AppDelegate.rememberedReplay, remembered.mediaID == media.id { AppDelegate.rememberedReplay = nil }
            // A start « Resume » decided that this stream did not take (a
            // finished download plays from disk) is not left for a later one.
            PlaybackStreamContext.dropRequestedStart(unlessFor: nil)
            // If something is presented (loading VC), dismiss it then push
            // the player. If nothing is presented (loading was raced /
            // already gone), present the player directly on the root.
            // Once the player covers the screen, the artwork memory goes
            // again: between the loading screen and the player, the screen
            // underneath shows for a moment and decodes its posters anew.
            let purge = { ArtworkPipeline.shared.purgeMemory() }
            if self.window?.rootViewController?.presentedViewController != nil {
                self.dismiss(animated: flag) {
                    self.present(playerVc, animated: flag, completion: purge)
                }
            } else {
                self.present(playerVc, animated: flag, completion: purge)
            }
        }
        
        // The OpenSubtitles search runs ALONGSIDE the stream. It used to come
        // first, the stream starting only in its completion: every playback
        // waited for OpenSubtitles before contacting a single peer (up to
        // the request's timeout when it did not answer), with a bare spinner
        // meanwhile. The players take the list when they start
        // (`Media.play` hands it over once the stream is ready) or as it
        // arrives (`SubtitleSearch`); a title searched in the last half hour
        // has it at once.
        let trace = PlaybackStartTrace(title: media.title)
        loadingViewController.startTrace = trace
        trace.begin(.subtitles)
        SubtitleSearch.shared.search(for: media) { subtitles in
            trace.reach(.subtitles, detail: "\(subtitles.count) language(s)")
        }
        // One turn later, as the search's completion came at the earliest:
        // the loading screen's first frame does not wait for the previous
        // stream's clean-up (`Media.play`).
        DispatchQueue.main.async { [unowned self] in
            // Back in the meantime: nothing starts.
            guard !loadingViewController.isCancelled else {
                print("[Play] Back before the stream started — \(media.title) not started")
                PlaybackStreamContext.dropRequestedStart(unlessFor: nil)
                if AppDelegate.rememberedReplay?.mediaID == media.id { AppDelegate.rememberedReplay = nil }
                return
            }
            media.subtitles = SubtitleSearch.shared.answer(for: media) ?? []
            print("[Play] starting streamer for \(media.title) — subtitles "
                  + (media.subtitles.isEmpty ? "searched alongside" : "known (\(media.subtitles.count))"))
            // Only a display name that clearly names a VLC-only container
            // (AVI, TS, WMV…) starts on VLC directly. Everything else starts
            // on the native AVPlayer controller, which re-routes on the REAL
            // file name once the torrent is ready (YTS display names carry no
            // extension): MKV/WebM → on-the-fly fMP4/HLS remux (native HDR10 /
            // Dolby Vision, true Atmos), MP4/MOV → AVPlayer directly. When
            // AVFoundation can't play the payload it hands the SAME torrent
            // stream over to VLC (see `handOffToVLC`).
            if PlaybackRouting.route(forMagnet: torrent.url) == .vlc {
                let playViewController = storyboard.instantiateViewController(withIdentifier: "PCTPlayerViewController") as! PCTPlayerViewController
                playViewController.delegate = self
                // A title saved part-way is offered « Resume Playing » at that
                // point; a finished (or nearly finished, ≥ 95 %) one restarts
                // from the beginning without asking, as on the native players
                // and the iOS VLC player. (A native → VLC hand-off,
                // `handOffToVLC`, passes its own position as is.)
                let startPosition = ResumePolicy.startPosition(forSavedProgress: currentProgress)
                playViewController.upNextLink = upNext
                media.play(fromFileOrMagnetLink: torrent.url, torrent: torrent, nextEpisodeInSeries: nextEpisode, loadingViewController: loadingViewController, playViewController: playViewController, progress: startPosition, errorBlock: error, streamFailureBlock: streamFailed, finishedLoadingBlock: finishedLoading)
                return
            }

            let nativeViewController = RemuxAVPlayerViewController()
            nativeViewController.modalPresentationStyle = .fullScreen
            let hasAtmos = torrent.tags.contains(.atmos)
            let hintsHDR = !torrent.tags.isDisjoint(with: [.hdr10, .hdr10Plus, .dolbyVision])
            // Downloads (`hasDownloaded`) flow through these same blocks.
            let playBlock: (URL, URL, Media, Episode?, Float, UIViewController, PTTorrentStreamer) -> Void = { videoFileURL, videoFilePath, playMedia, nextOfBefore, progress, viewController, streamer in
                guard let nativeViewController = viewController as? RemuxAVPlayerViewController else { return }
                nativeViewController.onFallback = { [weak self, weak nativeViewController] reason, resumeFraction, resumeDecided in
                    guard let self = self, let nativeViewController = nativeViewController else { return }
                    self.handOffToVLC(from: nativeViewController,
                                      media: playMedia,
                                      videoFileURL: videoFileURL,
                                      videoFilePath: videoFilePath,
                                      progress: resumeFraction,
                                      resumeDecided: resumeDecided,
                                      nextEpisode: nextOfBefore,
                                      streamer: streamer,
                                      reason: reason)
                }
                // Saved progress: resumed natively (direct MP4, payload on
                // disk) or asked about (remux of a still-downloading file).
                // Episodes get "Up Next" before the end (60 s by default,
                // Settings › Next Episode Card); accepting it
                // closes this player (stream cancelled) and then plays
                // `upNext` through the normal flow, like the VLC player.
                nativeViewController.configure(localFile: videoFilePath,
                                               remoteURL: videoFileURL,
                                               streamer: streamer,
                                               title: playMedia.title,
                                               media: playMedia,
                                               isAtmos: hasAtmos,
                                               releaseHintsHDR: hintsHDR,
                                               startPosition: progress,
                                               nextEpisode: nextOfBefore,
                                               onPlayNext: { [weak self] episode in
                                                   self?.playNext(episode)
                                               },
                                               upNext: upNext)
            }
            media.play(fromFileOrMagnetLink: torrent.url,
                       torrent: torrent,
                       nextEpisodeInSeries: nextEpisode,
                       loadingViewController: loadingViewController,
                       playViewController: nativeViewController,
                       progress: currentProgress,
                       playBlock: playBlock,
                       errorBlock: error,
                       streamFailureBlock: streamFailed,
                       finishedLoadingBlock: finishedLoading)
        }
    }

    /// The native player gave up (container / codecs AVFoundation can't
    /// play, item failure, readiness timeout): continue on VLC with the SAME
    /// torrent stream — not restarted — from the position the native player
    /// reached. The native controller is flagged as handing off, so its
    /// dismissal keeps the stream alive; VLC owns it from here (cancels it
    /// when the user leaves).
    /// - Parameter resumeDecided: the user chose « Reprendre » in the native
    ///   player, or was watching when it failed — VLC continues at
    ///   `progress` without asking. False (e.g. a DTS-only MKV rejected
    ///   before the native resume question): VLC asks « Resume Playing /
    ///   Start from Beginning » itself.
    private func handOffToVLC(from nativeViewController: RemuxAVPlayerViewController,
                              media: Media,
                              videoFileURL: URL,
                              videoFilePath: URL,
                              progress: Float,
                              resumeDecided: Bool,
                              nextEpisode: Episode?,
                              streamer: PTTorrentStreamer,
                              reason: String) {
        print("[Play] native player → VLC fallback (\(reason)) at \(Int(progress * 100)) %"
              + (resumeDecided ? "" : " — VLC asks whether to resume"))
        let vlcViewController = UIStoryboard.main.instantiateViewController(withIdentifier: "PCTPlayerViewController") as! PCTPlayerViewController
        vlcViewController.delegate = self
        // Only skip VLC's own resume question when it was already answered
        // (« Reprendre » in the native player) or playback was under way.
        vlcViewController.resumesWithoutPrompt = resumeDecided
        // The episode's session goes on in the VLC player.
        vlcViewController.upNextLink = nativeViewController.upNextLink
        vlcViewController.play(media,
                               fromURL: videoFileURL,
                               localURL: videoFilePath,
                               progress: progress,
                               nextEpisode: nextEpisode,
                               directory: videoFilePath.deletingLastPathComponent(),
                               streamer: streamer)
        let presentVLC = { [weak self] in
            guard let self = self else { return }
            // The page underneath showed between the two players.
            self.present(vlcViewController, animated: true) { ArtworkPipeline.shared.purgeMemory() }
        }
        // Dismiss from the PRESENTER: it takes down the native player and
        // anything still presented over it (calling dismiss on the player
        // itself would only close such an alert, and VLC could then not be
        // presented).
        if let presenter = nativeViewController.presentingViewController {
            presenter.dismiss(animated: false, completion: presentVLC)
        } else {
            presentVLC()
        }
    }
    
    func downloadButton(_ button: DownloadButton, wasPressedWith download: PTTorrentDownload, didDeleteHandler: (() -> Void)? = nil) {
        downloadControl(wasPressedIn: button.downloadState, with: download, sourceView: button, stateDidChange: { state in
            button.downloadState = state
        }, didDeleteHandler: didDeleteHandler)
    }

    /// A download control showing `state` was pressed (a `DownloadButton`, or
    /// the glass detail page's Download buttons): downloaded → Play / Delete
    /// Download sheet, downloading → pause, paused → resume. `stateDidChange`
    /// receives the control's new state.
    func downloadControl(wasPressedIn state: DownloadButton.State, with download: PTTorrentDownload, sourceView: UIView?, stateDidChange: @escaping (DownloadButton.State) -> Void, didDeleteHandler: (() -> Void)? = nil) {
        switch state {
        case .downloaded:
            let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet, blurStyle: .dark)
            
            alertController.addAction(UIAlertAction(title: "Play".localized, style: .default) { _ in
                AppDelegate.shared.play(Movie(download.mediaMetadata) ?? Episode(download.mediaMetadata)!, torrent: Torrent()) // No torrent metadata necessary, media is loaded from disk.
            })
            alertController.addAction(UIAlertAction(title: "Delete Download".localized, style: .destructive) { _ in
                PTTorrentDownloadManager.shared().delete(download)
                stateDidChange(.normal)
                didDeleteHandler?()
            })
            alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
            
            alertController.popoverPresentationController?.sourceView = sourceView
            alertController.show(animated: true)
        case .downloading:
            download.pause()
            stateDidChange(.paused)
        case .paused:
            download.resume()
            stateDidChange(.downloading)
        default:
            break
        }
    }
    
    func downloadButton(_ button: DownloadButton?, wantsToStop download: PTTorrentDownload, didStopHandler: (() -> Void)? = nil) {
        let alertController = UIAlertController(title: "Stop Download".localized, message: "Are you sure you want to stop the download?".localized, preferredStyle: .alert)
        
        alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
        
        alertController.addAction(UIAlertAction(title: "Stop".localized, style: .destructive) { _ in
            PTTorrentDownloadManager.shared().stop(download)
            button?.downloadState = .normal
            didStopHandler?()
        })
        
        alertController.show(animated: true)
    }
    
    func download(_ download: PTTorrentDownload, failedWith error: Error) {
        let alertController = UIAlertController(title: "Download Failed".localized, message: error.localizedDescription, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK".localized, style: .default, handler: nil))
        alertController.show(animated: true)
    }
    
    // MARK: - PCTPlayerViewControllerDelegate

    /// The next episode the way it was played before 5.3: its sources,
    /// then the quality setting (chooser or automatic pick). Episode
    /// chaining's fallback (`UpNextSession.Host.fallBack`) when the plan
    /// cannot start it; the plan itself starts through `play` directly.
    func playNext(_ episode: Episode) {
        print("[UpNext] playNext \(episode.id): today's flow (sources, quality)")
        chooseQuality(nil, media: episode) { [unowned self] torrent in
            self.play(episode, torrent: torrent)
        }
    }

    // MARK: - « Resume »: the release remembered (episode chaining, 5.3.0)

    /// The remembered release `playRemembered` is starting, for that one
    /// playback (`play` drops it for another title or release, and once the
    /// stream has started): its patience (D5), and its failure forgets it
    /// (`forgetRememberedReleaseIfReplayed`).
    static var rememberedReplay: (mediaID: String, url: String)?

    /// « Resume » (a Continue Watching card, the page's Play): the release
    /// remembered for `media` replays at once — no « Looking for sources »
    /// card, no chooser (decision D2: and no « Resume at …? » question: the
    /// saved position is passed as decided, the remux resumes natively by a
    /// jump). An episode not started yet replays the show's last pack when
    /// it holds it — a pack only VLC plays once its releases show no native
    /// one —, else, its releases known, the one in clear continuity with the
    /// show's last release (same group or class, D4). The same rule as the
    /// iPhone / iPad and the Mac (`UpNextResume.choice`). False: nothing to
    /// replay (or that source did not answer this session) — the caller's
    /// usual flow.
    /// - Parameter candidates: the episode's releases when known (nil: not
    ///   yet; `chooseQuality(replaysRemembered:)` asks again with them).
    @discardableResult
    func playRemembered(_ media: Media, candidates: [Torrent]? = nil) -> Bool {
        let excluded = AppDelegate.unansweredSources[media.id] ?? []
        guard let choice = UpNextResume.choice(mediaID: media.id, candidates: candidates, excluded: excluded) else { return false }
        print(choice.logLine(mediaID: media.id))
        let key = AppDelegate.sourceKey(choice.torrent.url)
        if excluded.contains(key) {
            print("[UpNext] resume \(media.id): the remembered release did not answer this session — today's flow")
            return false
        }
        guard choice.replaysRemembered else {
            // Another release of the episode, in clear continuity (D4): no
            // remembered release to wait less for or to forget.
            AppDelegate.rememberedReplay = nil
            play(media, torrent: choice.torrent)
            return true
        }
        let saved = media is Movie ? WatchedlistManager<Movie>.movie.currentProgress(media.id)
            : WatchedlistManager<Episode>.episode.currentProgress(media.id)
        let start = choice.rule == .sameRelease ? ResumePolicy.startPosition(forSavedProgress: saved) : 0
        if start > 0 {
            // D2: Resume was the answer — no question, a native jump.
            PlaybackStreamContext.requestStart(start, forURL: choice.torrent.url)
            print("[UpNext] resume \(media.id): \(Int(start * 100)) % passed as decided (no question)")
        }
        AppDelegate.rememberedReplay = (media.id, choice.torrent.url)
        play(media, torrent: choice.torrent)
        return true
    }

    /// A remembered release that failed (no peer in `UpNextResume.patience`,
    /// a stream error) is forgotten wherever the title remembers it — for an
    /// episode, its show's pack too (`Library.forgetRelease(_:sourceKey:)`):
    /// the next « Resume » or Home card asks again.
    static func forgetRememberedReleaseIfReplayed(mediaID: String, url: String?) {
        guard let remembered = rememberedReplay, remembered.mediaID == mediaID,
              url == nil || url == remembered.url else { return }
        rememberedReplay = nil
        let forgotten = Library.shared.forgetRelease(mediaID, sourceKey: AppDelegate.sourceKey(remembered.url))
        print("[UpNext] resume \(mediaID): the remembered release failed — " + (forgotten ? "forgotten" : "nothing to forget"))
    }
    
    private func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        guard let rootViewController = window?.rootViewController else { return }
        rootViewController.present(viewControllerToPresent, animated: flag, completion: completion)
    }
    
    private func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard let rootViewController = window?.rootViewController else { return }
        rootViewController.dismiss(animated: flag, completion: completion)
    }
    
    // MARK: - Presentation
    
    private var activeViewController: UIViewController? {
        return (mainTabBarController?.selectedViewController as? UINavigationController)?.viewControllers.last
    }
    
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        // The loading screen is presented without animation and fades its
        // content in itself (`fadesInOnAppear`): no 1 s transition during
        // which UIKit would drop Back.
        return nil
    }
    
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        if dismissed is PreloadTorrentViewController && activeViewController is GlassDetailHostingController {
            return PreloadTorrentViewControllerAnimatedTransitioning(isPresenting: false)
        }
        return nil
    }
}

/// « Looking for sources… » over the page while an episode's sources load
/// (`chooseQuality`: Torrentio, Time4Popcorn, TPB / Knaben, up to 10 s).
/// Before, nothing showed for those seconds and the page stayed live: a
/// second press started a second request (two pickers, or two streams).
/// Modal (the remote goes to it), shown only if the wait passes
/// `delay` (no flash for a quick answer); Menu cancels the request.
final class SourcesBusyViewController: UIViewController {
    /// Menu pressed: the request is dropped (its answer ignored).
    var onCancel: (() -> Void)?
    /// Whether the card should still come (false: the screen it was asked
    /// from was left meanwhile; the request is then cancelled).
    var isStillWanted: () -> Bool = { true }

    private enum State { case idle, presenting, shown, finished }
    private var state = State.idle
    private var pendingFinish: (() -> Void)?
    private static let delay: TimeInterval = 0.4

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        card.layer.cornerRadius = 28
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        let label = UILabel()
        label.text = SourcesBusyViewController.text
        label.textColor = .white
        label.font = .systemFont(ofSize: 32, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 900),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -48),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 72),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -72),
        ])
        view.accessibilityViewIsModal = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Presented without animation (UIKit drops the remote's presses while
        // a presentation animates: Menu then was lost): the card fades in here.
        view.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) { self.view.alpha = 1 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: SourcesBusyViewController.text)
    }

    static var text: String {
        NSLocalizedString("Sources.Loading", value: "Looking for sources…",
                          comment: "Busy card while an episode's sources (torrents) are fetched before the quality choice")
    }

    /// Presents the card over the top-most screen after `delay`, unless
    /// `finish` came first.
    func showSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + SourcesBusyViewController.delay) { [self] in
            guard state == .idle else { return }
            guard isStillWanted() else {
                state = .finished
                onCancel?()
                return
            }
            // Not over a screen still leaving (a player closing for Up
            // Next): UIKit would drop the presentation.
            guard let presenter = SourcesBusyViewController.topMostViewController(),
                  presenter.presentedViewController == nil, presenter.viewIfLoaded?.window != nil else {
                state = .finished
                return
            }
            state = .presenting
            presenter.present(self, animated: false) { [self] in
                guard state == .presenting else { return }
                state = .shown
                if cancelRequested {
                    cancelRequested = false
                    cancelFromMenu()
                    return
                }
                if let next = pendingFinish {
                    pendingFinish = nil
                    finish(then: next)
                }
            }
            // A presentation UIKit refused never calls back: the request
            // must not wait for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                guard state == .presenting, presentingViewController == nil else { return }
                state = .finished
                if let next = pendingFinish {
                    pendingFinish = nil
                    next()
                }
            }
        }
    }

    /// The sources are in: the card goes (if it came), then `next`.
    func finish(then next: @escaping () -> Void) {
        switch state {
        case .idle:
            state = .finished
            next()
        case .presenting:
            pendingFinish = next
        case .shown:
            state = .finished
            dismiss(animated: true, completion: next)
        case .finished:
            next()
        }
    }

    /// Menu came while the card was being presented: applied once it is.
    private var cancelRequested = false

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else { return super.pressesBegan(presses, with: event) }
        switch state {
        case .shown: cancelFromMenu()
        case .presenting: cancelRequested = true
        case .idle, .finished: break
        }
    }

    // Menu's other phases stay here too: passed on, they reached the screen
    // under the card (its navigation controller pops on the press's end).
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else { return super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else { return super.pressesCancelled(presses, with: event) }
    }

    /// A link opens another screen (`AppDelegate.open`): shown, the card goes
    /// and its request is dropped as with Menu, then `next`. False when it
    /// is not shown (being presented, or leaving): the caller waits instead.
    func cancel(then next: @escaping () -> Void) -> Bool {
        guard state == .shown else { return false }
        state = .finished
        onCancel?()
        dismiss(animated: false, completion: next)
        return true
    }

    private func cancelFromMenu() {
        state = .finished
        onCancel?()
        dismiss(animated: true)
    }

    /// The foreground scene's key window's top-most presented controller.
    static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        var top = (scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
