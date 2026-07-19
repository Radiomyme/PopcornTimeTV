

import Foundation
import PopcornKit
import PopcornTorrent.PTTorrentStreamer
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
        //    to libtorrent immediately.
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            if let entries = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
                for entry in entries {
                    try? fm.removeItem(at: entry)
                }
            }
        }
        print("[Cache] aggressivelyFreeDiskSpace done")
    }
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

            group.enter()
            TorrentioClient.shared.streams(imdbId: showId, season: episode.season, episode: episode.episode) { torrents in
                aggregated = torrents
                group.leave()
            }
            group.enter()
            Time4PopcornClient.shared.episodeTorrents(imdbId: showId, season: episode.season, episode: episode.episode) { torrents in
                t4p = torrents
                group.leave()
            }

            group.notify(queue: .main) { [weak self] in
                var augmented = episode
                // T4P primary, EZTV + Torrentio as fallback.
                augmented.torrents = TorrentioClient.merge(t4p, with: episode.torrents + aggregated)
                print("[chooseQuality] episode S\(episode.season)E\(episode.episode): \(t4p.count) t4p + \(episode.torrents.count) EZTV + \(aggregated.count) aggregated -> \(augmented.torrents.count)")
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
        let preference = UserDefaults.standard.string(forKey: "autoSelectQuality") ?? "Highest".localized
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
        if preference == "Lowest".localized, let worst = sorted.first {
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

        for torrent in sorted.reversed() {
            alertController.addAction(UIAlertAction(title: torrent.quality, style: .default) { _ in
                completion(torrent)
            })
        }

        alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
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
            
            nextEpisode = !episodesLeftInShow.isEmpty ? episodesLeftInShow.removeFirst() : nil
            nextEpisode?.show = episode.show
        } else {
            backgroundImage = media.largeBackgroundImage
        }
        
        if let image = backgroundImage, let url = URL(string: image) {
            loadingViewController.backgroundImageView?.af.setImage(withURL: url)
        }
        loadingViewController.titleLabel.text = media.title
        
        present(loadingViewController, animated: true)
        
        let error: (String) -> Void = { [weak self] (errorMessage) in
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
            let isDiskFullError = errorMessage.localizedCaseInsensitiveContains("not enough space")
                               || errorMessage.localizedCaseInsensitiveContains("pas assez d'espace")
                               || errorMessage.localizedCaseInsensitiveContains("not enough disk")

            // Find a smaller candidate from the same media — strictly
            // smaller `qualityValue` than what we just tried.
            let smaller: Torrent? = {
                let candidates = media.torrents.sorted(by: <)
                guard let currentIdx = candidates.firstIndex(where: { $0.url == torrent.url }) else {
                    return candidates.dropLast().last
                }
                return currentIdx == 0 ? nil : candidates[currentIdx - 1]
            }()

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
                    let body  = "L'Apple TV n'a pas assez de place dans le cache de l'app pour télécharger ce torrent. Essayer une qualité inférieure ?"
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

            // MKV with DD+ audio: remux to fMP4/HLS on the fly and play via
            // AVPlayer — Apple's renderer gets the raw E-AC-3, i.e. real
            // Atmos (VLC's passthrough is broken in the bundled 4.0 alpha).
            if RemuxPlayback.canRemux(magnet: torrent.url, tags: torrent.tags) {
                let remuxVc = RemuxAVPlayerViewController()
                remuxVc.modalPresentationStyle = .fullScreen
                let mediaTitle = media.title
                let hasAtmos = torrent.tags.contains(.atmos)
                let playBlock: (URL, URL, Media, Episode?, Float, UIViewController, PTTorrentStreamer) -> Void = { _, videoFilePath, playMedia, _, _, viewController, streamer in
                    (viewController as? RemuxAVPlayerViewController)?
                        .configure(localFile: videoFilePath, streamer: streamer, title: mediaTitle, media: playMedia, isAtmos: hasAtmos)
                }
                media.play(fromFileOrMagnetLink: torrent.url,
                           nextEpisodeInSeries: nextEpisode,
                           loadingViewController: loadingViewController,
                           playViewController: remuxVc,
                           progress: currentProgress,
                           playBlock: playBlock,
                           errorBlock: error,
                           finishedLoadingBlock: finishedLoading)
                return
            }

            // Codec sniff: AVPlayer renders HDR10 / Dolby Vision / Atmos
            // natively on tvOS 17+ but only handles .mp4/.m4v/.mov.
            // Almost all YTS torrents are .mkv → fall back to PCTPlayer/VLC.
            if AppDelegate.shouldUseAVPlayer(forMagnet: torrent.url) {
                let avVc = NativeAVPlayerViewController()
                avVc.modalPresentationStyle = .fullScreen
                let captured = media
                let mediaCopy = media
                let playBlock: (URL, URL, Media, Episode?, Float, UIViewController, PTTorrentStreamer) -> Void = { videoFileURL, _, _, _, progress, viewController, streamer in
                    guard let avVc = viewController as? NativeAVPlayerViewController else { return }
                    avVc.configure(url: videoFileURL,
                                   startPositionPercent: progress,
                                   media: captured,
                                   streamer: streamer)
                }
                _ = mediaCopy
                mediaCopy.play(fromFileOrMagnetLink: torrent.url,
                               nextEpisodeInSeries: nextEpisode,
                               loadingViewController: loadingViewController,
                               playViewController: avVc,
                               progress: currentProgress,
                               playBlock: playBlock,
                               errorBlock: error,
                               finishedLoadingBlock: finishedLoading)
                return
            }

            let playViewController = storyboard.instantiateViewController(withIdentifier: "PCTPlayerViewController") as! PCTPlayerViewController
            playViewController.delegate = self
            media.play(fromFileOrMagnetLink: torrent.url, nextEpisodeInSeries: nextEpisode, loadingViewController: loadingViewController, playViewController: playViewController, progress: currentProgress, errorBlock: error, finishedLoadingBlock: finishedLoading)
        }
    }

    /// Inspect the magnet's `dn=` (display name, set by the torrent creator
    /// to the file name) for an extension AVPlayer can decode. Without this
    /// the user lands on a black PCTPlayerViewController for unsupported
    /// containers (mkv with proprietary subtitle tracks, etc.). YTS encodes
    /// most 4K HEVC inside `.mkv` containers — those keep going to VLC.
    fileprivate static func shouldUseAVPlayer(forMagnet magnet: String) -> Bool {
        guard let dn = magnet.components(separatedBy: "&dn=").last?
                .components(separatedBy: "&").first?
                .removingPercentEncoding?.lowercased()
        else { return false }
        let avFriendly = [".mp4", ".m4v", ".mov"]
        return avFriendly.contains(where: { dn.hasSuffix($0) })
    }
    
    func downloadButton(_ button: DownloadButton, wasPressedWith download: PTTorrentDownload, didDeleteHandler: (() -> Void)? = nil) {
        switch button.downloadState {
        case .downloaded:
            let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet, blurStyle: .dark)
            
            alertController.addAction(UIAlertAction(title: "Play".localized, style: .default) { _ in
                AppDelegate.shared.play(Movie(download.mediaMetadata) ?? Episode(download.mediaMetadata)!, torrent: Torrent()) // No torrent metadata necessary, media is loaded from disk.
            })
            alertController.addAction(UIAlertAction(title: "Delete Download".localized, style: .destructive) { _ in
                PTTorrentDownloadManager.shared().delete(download)
                button.downloadState = .normal
                didDeleteHandler?()
            })
            alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
            
            alertController.popoverPresentationController?.sourceView = button
            alertController.show(animated: true)
        case .downloading:
            download.pause()
            button.downloadState = .paused
        case .paused:
            download.resume()
            button.downloadState = .downloading
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
        if presented is PreloadTorrentViewController && activeViewController is DetailViewController {
            return PreloadTorrentViewControllerAnimatedTransitioning(isPresenting: true)
        }
        return nil
        
    }
    
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        if dismissed is PreloadTorrentViewController && activeViewController is DetailViewController {
            return PreloadTorrentViewControllerAnimatedTransitioning(isPresenting: false)
        }
        return nil
    }
}
