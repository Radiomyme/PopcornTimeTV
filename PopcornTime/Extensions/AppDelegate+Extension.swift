

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
        purgeOrphanTorrentDownloads()

        // 2) Foundation URLCache (HTTP responses cached by Alamofire).
        URLCache.shared.removeAllCachedResponses()

        // 3) AlamofireImage's URLCache (covers both Alamofire HTTP and
        //    AlamofireImage's poster downloads). We don't try to reach the
        //    in-memory `ImageCache` because each `UIImageView.af` extension
        //    can attach its own and there's no global accessor.
        ImageDownloader.defaultURLCache().removeAllCachedResponses()

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
    
    func chooseQuality(_ sender: UIView?, media: Media, completion: @escaping (Torrent) -> Void) {
        // Episodes: EZTV only carries what its uploaders pushed, so before
        // picking a quality, ask the Torrentio aggregator (YTS/RARBG-archive/
        // 1337x/TorrentGalaxy/…) AND the Time4Popcorn backend for that exact
        // episode and merge both. This fills gaps (old seasons EZTV lacks)
        // and adds extra releases. Movies are already merged at detail-load
        // time by the provider.
        if let episode = media as? Episode, let showId = episode.show?.id, showId.hasPrefix("tt") {
            let group = DispatchGroup()
            var aggregated: [Torrent] = []
            var t4p: [Torrent] = []
            var extra: [Torrent] = []

            group.enter()
            TorrentioClient.shared.streams(imdbId: showId, season: episode.season, episode: episode.episode) { torrents in
                aggregated = torrents
                group.leave()
            }
            // The Pirate Bay + Knaben, exact episode only (`ExtraTorrentSources`).
            group.enter()
            ExtraTorrentSources.shared.episodeTorrents(imdbId: showId, showTitle: episode.show?.title,
                                                       season: episode.season, episode: episode.episode) { torrents in
                extra = torrents
                group.leave()
            }
            group.enter()
            Time4PopcornClient.shared.episodeTorrents(imdbId: showId, season: episode.season, episode: episode.episode) { torrents in
                t4p = torrents
                group.leave()
            }

            group.notify(queue: .main) { [weak self] in
                var augmented = episode
                // T4P primary, EZTV + Torrentio + TPB / Knaben as fallback (a
                // TPB / Knaben copy of a listed torrent keeps the listed row).
                let legacy = episode.torrents + aggregated
                augmented.torrents = TorrentioClient.merge(t4p, with: legacy + ExtraTorrentSources.novel(extra, beside: t4p + legacy))
                print("[chooseQuality] episode S\(episode.season)E\(episode.episode): \(t4p.count) t4p + \(episode.torrents.count) EZTV + \(aggregated.count) aggregated + \(extra.count) TPB/Knaben -> \(augmented.torrents.count)")
                self?.presentQualityChoice(sender, media: augmented, completion: completion)
            }
            return
        }
        presentQualityChoice(sender, media: media, completion: completion)
    }

    private func presentQualityChoice(_ sender: UIView?, media: Media, completion: @escaping (Torrent) -> Void) {
        // Auto-pick behaviour is controlled by the "autoSelectQuality" setting:
        //   Highest (default on the Apple TV) — always the top resolution
        //     (2160p + HDR/DV/Atmos) for the best picture on a 4K TV, accepting
        //     that a lightly-seeded 4K release takes longer to buffer;
        //   Balanced — highest resolution the swarm can stream fast (skips a
        //     lightly-seeded 4K for a well-seeded 1080p);
        //   Lowest   — smallest/fastest;
        //   Off      — always ask.
        // Default to "Off" (always show the picker) so the user can weigh
        // quality vs seeds themselves — the rich chooser below stars the
        // recommended pick and pre-focuses it, so accepting the smart default
        // is still one click. Set Highest/Balanced/Lowest in Settings to
        // auto-pick instead.
        let preference = UserDefaults.standard.string(forKey: "autoSelectQuality") ?? "Off".localized
        var sorted     = media.torrents.sorted(by: <)

        #if targetEnvironment(simulator)
        // The tvOS Simulator runs on the Mac with no HEVC HW decoder, so 4K
        // HEVC takes minutes to start and stutters. Cap auto-pick at 1080p
        // for simulator runs only — the real Apple TV 4K still gets the
        // 2160p stream.
        let simulatorCap: VideoQuality = .hd1080
        sorted = sorted.filter { $0.qualityValue <= simulatorCap }
        if sorted.isEmpty { sorted = media.torrents.sorted(by: <) }
        print("[chooseQuality] simulator cap applied: max=\(simulatorCap)")
        #endif

        print("[chooseQuality] media=\(media.title) preference=\(preference) candidates=\(sorted.map { "\($0.quality ?? "?")(\($0.qualityValue)) s\($0.seeds)" })")

        if preference == "Highest".localized, let best = sorted.last {
            print("[chooseQuality] picked HIGHEST: quality=\(best.quality ?? "?") seeds=\(best.seeds) url=\(best.url.prefix(120))")
            return completion(best)
        }
        if preference == "Balanced".localized, let best = balancedPick(from: sorted) {
            print("[chooseQuality] picked BALANCED: quality=\(best.quality ?? "?") seeds=\(best.seeds)")
            return completion(best)
        }
        // Lowest = the smallest resolution bucket, but the BEST-playing
        // release inside it (the comparator puts penalized AVI / CAM / AV1-
        // without-hardware releases first within a bucket).
        if preference == "Lowest".localized,
           let lowestBucket = sorted.first?.qualityValue,
           let worst = sorted.last(where: { $0.qualityValue == lowestBucket }) {
            print("[chooseQuality] picked LOWEST: quality=\(worst.quality ?? "?")")
            return completion(worst)
        }

        guard media.torrents.count > 1 else {
            if let torrent = media.torrents.first {
                completion(torrent)
            } else {
                let alertController = UIAlertController(title: "No torrents found".localized, message: "Torrents could not be found for the specified media.".localized, preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: "OK".localized, style: .default, handler: nil))
                alertController.show(animated: true)
            }
            return
        }

        let style: UIAlertController.Style = sender == nil ? .alert : .actionSheet
        let blurStyle: UIBlurEffect.Style  = style == .alert ? .extraLight : .dark
        let alertController = UIAlertController(title: "Choose Quality".localized, message: nil, preferredStyle: style, blurStyle: blurStyle)

        // Enrich each row with seeds + size so the best quality/seeds ratio is
        // visible at a glance (like the iOS/macOS pickers), and star the
        // recommended `balancedPick`. Best resolution first. The source (TPB,
        // Knaben · 1337x, a Torrentio indexer…) comes last, and the separators
        // are narrow: tvOS shrinks a row too long for the sheet, then cuts its
        // middle (the seeds); the focused row scrolls to show it all.
        let recommendedURL = Torrent.balancedPick(from: sorted)?.url
        var recommendedAction: UIAlertAction?
        for torrent in sorted.reversed() {
            var label = torrent.qualityLabel.isEmpty ? "—" : torrent.qualityLabel
            label += "  ·  \(torrent.seeds) seeds"
            if let size = torrent.size, !size.isEmpty { label += "  ·  \(size)" }
            if let source = torrent.sourceLabel { label += "  ·  \(source)" }
            if torrent.url == recommendedURL { label = "⭐︎ " + label }
            let action = UIAlertAction(title: label, style: .default) { _ in completion(torrent) }
            alertController.addAction(action)
            if torrent.url == recommendedURL { recommendedAction = action }
        }

        alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
        // Put initial focus on the recommended pick.
        if let recommendedAction = recommendedAction { alertController.preferredAction = recommendedAction }
        alertController.popoverPresentationController?.sourceView = sender
        alertController.show(animated: true)
    }

    private func balancedPick(from torrents: [Torrent]) -> Torrent? {
        return Torrent.balancedPick(from: torrents)
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
        if UIDevice.current.hasCellularCapabilites && reachability.connection != .wifi && !UserDefaults.standard.bool(forKey: "streamOnCellular")  {

            let alertController = UIAlertController(title: "Cellular Data is turned off for streaming".localized, message: nil, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "Turn On".localized, style: .default) { [unowned self] _ in
                UserDefaults.standard.set(true, forKey: "streamOnCellular")
                self.play(media, torrent: torrent)
            })
            alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
            return alertController.show(animated: true)
        }
        
        let storyboard = UIStoryboard.main
        var media = media
        
        let currentProgress = media is Movie ? WatchedlistManager<Movie>.movie.currentProgress(media.id) : WatchedlistManager<Episode>.episode.currentProgress(media.id)
        var nextEpisode: Episode?
        
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
        
        // The detail page's theme song must not play over the buffering
        // screen and the movie (the page also stops it when it disappears).
        ThemeSongManager.shared.stopTheme()
        present(loadingViewController, animated: true)
        
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
                    let title = "Espace insuffisant pour ce film en \(torrent.quality ?? "?")"
                    let body  = spaceToFree.map {
                        $0 + "\n\n" + NSLocalizedString("BoundedStorage.TryLowerQuality", value: "Try a lower quality?",
                                                        comment: "After the space to free, offers a smaller release")
                    } ?? "L'Apple TV n'a pas assez de place dans le cache de l'app pour télécharger ce torrent. Essayer une qualité inférieure ?"
                    let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Réessayer en \(fallback.quality ?? "qualité inférieure")", style: .default) { _ in
                        self.play(media, torrent: fallback)
                    })
                    alert.addAction(UIAlertAction(title: "Annuler", style: .cancel, handler: nil))
                    alert.show(animated: true)
                } else {
                    let alert = UIAlertController(title: "Error".localized, message: errorMessage, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK".localized, style: .cancel, handler: nil))
                    alert.show(animated: true)
                }
            }
        }
        
        let error: (String) -> Void = { failed($0, nil) }
        let streamFailed: (StreamFailure, String) -> Void = { failed($1, $0) }

        let finishedLoading: (PreloadTorrentViewController, UIViewController) -> Void = { [weak self] (loadingVc, playerVc) in
            guard let self = self else { return }
            let flag = UIDevice.current.userInterfaceIdiom != .tv
            print("[Play] finishedLoading — presenting player VC")
            // If something is presented (loading VC), dismiss it then push
            // the player. If nothing is presented (loading was raced /
            // already gone), present the player directly on the root.
            if self.window?.rootViewController?.presentedViewController != nil {
                self.dismiss(animated: flag) {
                    self.present(playerVc, animated: flag)
                }
            } else {
                self.present(playerVc, animated: flag)
            }
        }
        
        media.getSubtitles { [unowned self] subtitles in
            // The legacy guard was
            //   `presentedViewController === loadingViewController`
            // but with the modernized SubtitlesManager (stub returning
            // an empty array via `DispatchQueue.main.async`), this closure
            // fires before `present(loadingViewController, animated: true)`
            // finishes its animation, so the guard always failed and the
            // streamer never started — the spinner sat there forever. We
            // accept that the loading VC may not yet be on screen; once
            // PTTorrentStreamer's `readyToPlay` fires we dismiss whatever
            // is presented and push the player anyway.
            print("[Play] subtitles=\(subtitles.count) starting streamer for \(media.title)")
            media.subtitles = subtitles

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
                media.play(fromFileOrMagnetLink: torrent.url, nextEpisodeInSeries: nextEpisode, loadingViewController: loadingViewController, playViewController: playViewController, progress: startPosition, errorBlock: error, streamFailureBlock: streamFailed, finishedLoadingBlock: finishedLoading)
                return
            }

            let nativeViewController = RemuxAVPlayerViewController()
            nativeViewController.modalPresentationStyle = .fullScreen
            let hasAtmos = torrent.tags.contains(.atmos)
            let hintsHDR = !torrent.tags.isDisjoint(with: [.hdr10, .hdr10Plus, .dolbyVision])
            // Downloads (`hasDownloaded`) flow through these same blocks.
            let playBlock: (URL, URL, Media, Episode?, Float, UIViewController, PTTorrentStreamer) -> Void = { videoFileURL, videoFilePath, playMedia, upNext, progress, viewController, streamer in
                guard let nativeViewController = viewController as? RemuxAVPlayerViewController else { return }
                nativeViewController.onFallback = { [weak self, weak nativeViewController] reason, resumeFraction, resumeDecided in
                    guard let self = self, let nativeViewController = nativeViewController else { return }
                    self.handOffToVLC(from: nativeViewController,
                                      media: playMedia,
                                      videoFileURL: videoFileURL,
                                      videoFilePath: videoFilePath,
                                      progress: resumeFraction,
                                      resumeDecided: resumeDecided,
                                      nextEpisode: upNext,
                                      streamer: streamer,
                                      reason: reason)
                }
                // Saved progress: resumed natively (direct MP4, payload on
                // disk) or asked about (remux of a still-downloading file).
                // Episodes get "Up Next" 30 s before the end; accepting it
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
                                               nextEpisode: upNext,
                                               onPlayNext: { [weak self] episode in
                                                   self?.playNext(episode)
                                               })
            }
            media.play(fromFileOrMagnetLink: torrent.url,
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
        vlcViewController.play(media,
                               fromURL: videoFileURL,
                               localURL: videoFilePath,
                               progress: progress,
                               nextEpisode: nextEpisode,
                               directory: videoFilePath.deletingLastPathComponent(),
                               streamer: streamer)
        let presentVLC = { [weak self] in
            guard let self = self else { return }
            self.present(vlcViewController, animated: true)
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

    func playNext(_ episode: Episode) {
        chooseQuality(nil, media: episode) { [unowned self] torrent in
            self.play(episode, torrent: torrent)
        }
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
        return (tabBarController.selectedViewController as? UINavigationController)?.viewControllers.last
    }
    
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        if presented is PreloadTorrentViewController && activeViewController is GlassDetailHostingController {
            return PreloadTorrentViewControllerAnimatedTransitioning(isPresenting: true)
        }
        return nil
        
    }
    
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        if dismissed is PreloadTorrentViewController && activeViewController is GlassDetailHostingController {
            return PreloadTorrentViewControllerAnimatedTransitioning(isPresenting: false)
        }
        return nil
    }
}
