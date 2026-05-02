

import Foundation
import PopcornKit
import PopcornTorrent.PTTorrentStreamer
import MediaPlayer.MPMediaItem

extension AppDelegate: PCTPlayerViewControllerDelegate, UIViewControllerTransitioningDelegate {
    
    func chooseQuality(_ sender: UIView?, media: Media, completion: @escaping (Torrent) -> Void) {
        // Default behaviour for the modernized tvOS app: always pick the highest
        // quality torrent available (2160p > 1080p > 720p > 480p > 3D, with
        // HDR/DV/Atmos preferred at equal resolution). The user can override the
        // preference in Settings ("autoSelectQuality" UserDefault).
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

        print("[chooseQuality] media=\(media.title) preference=\(preference) candidates=\(sorted.map { "\($0.quality ?? "?")(\($0.qualityValue))" })")

        if preference == "Highest".localized, let best = sorted.last {
            print("[chooseQuality] picked HIGHEST: quality=\(best.quality ?? "?") url=\(best.url.prefix(120))")
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
    
    func play(_ media: Media, torrent: Torrent) {
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
        loadingViewController.loadView()
        
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
        
        let error: (String) -> Void = { (errorMessage) in
            let alertController = UIAlertController(title: "Error".localized, message: errorMessage, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "OK".localized, style: .cancel, handler: nil))
            alertController.show(animated: true)
        }
        
        let finishedLoading: (PreloadTorrentViewController, UIViewController) -> Void = { (loadingVc, playerVc) in
            let flag = UIDevice.current.userInterfaceIdiom != .tv
            self.dismiss(animated: flag) {
                self.present(playerVc, animated: flag)
            }
        }
        
        media.getSubtitles { [unowned self] subtitles in
            guard self.window?.rootViewController?.presentedViewController === loadingViewController else { return } // Make sure the user is still loading.

            media.subtitles = subtitles

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
