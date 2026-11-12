

import Foundation
import PopcornTorrent
import PopcornKit
import MediaPlayer.MPMediaItem

// `purgeOrphanTorrentDownloads()` now lives in TorrentCacheCleanup.swift so it
// can be shared with the iOS/macOS target (this file is tvOS-only).

extension Media {
    
    /**
     Start playing movie or episode locally.
     
     - Parameter fromFileOrMagnetLink:  The url pointing to a .torrent file, a web adress pointing to a .torrent file to be downloaded or a magnet link.
     - Parameter nextEpisodeInSeries:   If media is an episode, pass in the next episode of the series, if applicable, for a better UX for the user.
     - Parameter loadingViewController: The view controller that will be presented while the torrent is processing to display updates to the user.
     - Parameter playViewController:    View controller to be presented to start playing the movie when loading is complete.
     - Parameter progress:              The users playback progress for the current media.
     - Parameter loadingBlock:          Block that handels updating loadingViewController UI. Defaults to updaing the progress of buffering, download speed and number of seeds.
     - Parameter playBlock:             Block that handels setting up playViewController. If playViewController is a subclass of PCTPlayerViewController, default behaviour is to call `play:fromURL:progress:directory` on playViewController.
     - Parameter errorBlock:            Block thats called when the request fails or torrent fails processing/downloading with error message parameter.
     - Parameter finishedLoadingBlock:  Block thats called when torrent is finished loading.
     */
    func play(
        fromFileOrMagnetLink url: String,
        nextEpisodeInSeries nextEpisode: Episode? = nil,
        loadingViewController: PreloadTorrentViewController,
        playViewController: UIViewController,
        progress: Float,
        loadingBlock: @escaping (PTTorrentStatus, PreloadTorrentViewController) -> Void = { (status, viewController) in
        viewController.progress = status.bufferingProgress
        viewController.speed = Int(status.downloadSpeed)
        viewController.seeds = Int(status.seeds)
        },
        playBlock: @escaping (URL, URL, Media, Episode?, Float, UIViewController, PTTorrentStreamer) -> Void = { (videoFileURL, videoFilePath, media, nextEpisode, progress, viewController, streamer) in
        if let viewController = viewController as? PCTPlayerViewController {
            viewController.play(media, fromURL: videoFileURL, localURL: videoFilePath, progress: progress, nextEpisode: nextEpisode, directory: videoFilePath.deletingLastPathComponent(), streamer: streamer)
        }
        },
        errorBlock: @escaping (String) -> Void,
        streamFailureBlock: ((StreamFailure, String) -> Void)? = nil,
        finishedLoadingBlock: @escaping (PreloadTorrentViewController, UIViewController) -> Void)
    {
        // The loading screen's « Choose another source » (a source that does
        // not answer) goes back to the quality picker for this movie or
        // episode, without this source (`AppDelegate.chooseAnotherSource`).
        // The first call only: a .torrent URL comes back here as a local file.
        if loadingViewController.media == nil {
            loadingViewController.media = self
            loadingViewController.sourceURL = url
        }
        if let download = completedDownload {
            return download.play { (videoFileURL, videoFilePath) in
                // The SPM PopcornTorrent answers a finished download at once,
                // with its file URL (no web server): keep the asynchronous
                // hand-off the players were written for.
                DispatchQueue.main.async {
                    loadingViewController.streamer = download
                    playBlock(videoFileURL, videoFilePath, self, nextEpisode, progress, playViewController, download)
                    finishedLoadingBlock(loadingViewController, playViewController)
                }
            }
        }

        // Wipe any leftover torrent partials before starting a new stream.
        // PTTorrentStreamer caches under `NSTemporaryDirectory()/Downloads/<hash>/...`
        // and only cleans the *current* torrent on cancel — failed streams,
        // app crashes, or user-aborted previews leave orphan folders that
        // each weigh several GB. Apple TV's per-app sandbox tops out around
        // 7-12 GB of usable space, so two abandoned 4K attempts are enough
        // to make the next "Highest" pick fail with "not enough space".
        //
        // NOTE: we intentionally do NOT try to keep a movie's partial for
        // fast-resume. The CocoaPods PopcornTorrent (libtorrent 1.2.1) crashed
        // reading a resumed partial back (`torrent::on_disk_read_complete`, a
        // memmove overrun at a piece boundary), and the SPM PopcornTorrent's
        // resume path hasn't been tried on the Apple TV. So every stream
        // starts clean; re-buffering on replay is the safe trade.
        PTTorrentStreamer.cancelCurrent(deleteData: true)
        purgeOrphanTorrentDownloads()

        if url.hasPrefix("magnet") || (url.hasSuffix(".torrent") && !url.hasPrefix("http")) {
            // A new streamer per stream (the SPM PopcornTorrent has no
            // singleton); it is the current one until the next stream.
            let streamer = PTTorrentStreamer.startNew()
            loadingViewController.streamer = streamer
            // The release, this title's other releases (an episode's are the
            // augmented list `chooseQuality` merged) and how to switch: the
            // players offer a lighter release when the download can't keep
            // up (`BandwidthDeficitMonitor`). The switch closes the player,
            // then plays the release through the normal flow, starting where
            // the other one was (taken by the new stream's context).
            let context = PlaybackStreamContext.attach(to: streamer, media: self,
                                                       sourceURL: loadingViewController.sourceURL ?? url)
            context.onSwitch = { [media = self] torrent, fraction in
                PlaybackStreamContext.requestStart(fraction, forURL: torrent.url)
                AppDelegate.shared.play(media, torrent: torrent)
            }
            // A film larger than the free space streams in bounded storage
            // (every player route drives the torrent's window).
            BoundedStorageSession.prepare(streamer, durationSeconds: BoundedStorageSession.durationHint(for: self))
            // PTTorrentStreamer dispatches its callbacks on libtorrent's
            // background queue. The blocks below all touch UIKit
            // (loadingViewController.progress / present(playerVc) /
            // alertController.show()) which asserts main-thread. Hop back
            // to main inside each callback so the caller doesn't have to
            // care about the streamer's threading.
            //
            // The streamed file: the magnet's BEP 53 `so=` file (Torrentio
            // `fileIdx`) when valid, else the largest video file, as on
            // macOS (`PTTorrentStreamer.fileSelection`); only that file's
            // pieces are wanted. Season packs stay filtered out of iOS/tvOS
            // episode results for now (`TorrentioClient.dropsEpisodePacks`
            // says why).
            print("[Streamer] startStreaming magnet=\(url.prefix(80))…")
            var lastLoggedTenth: Float = -1
            streamer.startStreaming(fromMultiTorrentFileOrMagnetLink: url, progress: { (status) in
                // Sample every 10% of buffering so the log doesn't drown the console.
                let bucket = (status.bufferingProgress * 10).rounded(.down)
                if bucket != lastLoggedTenth {
                    lastLoggedTenth = bucket
                    print(String(format: "[Streamer] buffering=%.0f%% seeds=%d peers=%d down=%dKB/s",
                                 status.bufferingProgress * 100,
                                 status.seeds, status.peers,
                                 status.downloadSpeed / 1024))
                }
                DispatchQueue.main.async { loadingBlock(status, loadingViewController) }
                }, readyToPlay: { (videoFileURL, videoFilePath) in
                    print("[Streamer] readyToPlay url=\(videoFileURL)")
                    // The streamer reports `http://0.0.0.0:<port>/`: the
                    // players get 127.0.0.1 and the payload's name, as on
                    // macOS (VLC opens it directly).
                    let playableURL = PlaybackRouting.playableLocalURL(videoFileURL, fileName: videoFilePath.lastPathComponent)
                    DispatchQueue.main.async {
                        playBlock(playableURL, videoFilePath, self, nextEpisode, progress, playViewController, streamer)
                        finishedLoadingBlock(loadingViewController, playViewController)
                    }
                }, failure: { error in
                    print("[Streamer] FAILURE: \(error.localizedDescription)")
                    // Not enough space even for bounded storage (-5: the
                    // message says how much to free), another file error
                    // (-6), or the error's own text.
                    let failure = StreamFailure(error, streamer: streamer)
                    let message = failure.message(underlying: error) ?? error.localizedDescription
                    DispatchQueue.main.async {
                        if let streamFailureBlock = streamFailureBlock {
                            streamFailureBlock(failure, message)
                        } else {
                            errorBlock(message)
                        }
                    }
            }, selectFileToStream: PTTorrentStreamer.fileSelection(for: url))
        } else {
            PopcornKit.downloadTorrentFile(url, completion: { (url, error) in
                // Alamofire hands the response back on its own queue too.
                DispatchQueue.main.async {
                    guard let url = url, error == nil else { errorBlock(error!.localizedDescription); return }
                    self.play(fromFileOrMagnetLink: url, nextEpisodeInSeries: nextEpisode, loadingViewController: loadingViewController, playViewController: playViewController, progress: progress, loadingBlock: loadingBlock, playBlock: playBlock, errorBlock: errorBlock, streamFailureBlock: streamFailureBlock, finishedLoadingBlock: finishedLoadingBlock)
                }
            })
        }
    }
    
    /**
     Retrieves subtitles from OpenSubtitles
     
     - Parameter id:    `nil` by default. The imdb id of the media will be used by default.
     
     - Parameter completion: The completion handler for the request containing an array of subtitles
     */
    func getSubtitles(forId id: String? = nil, completion: @escaping ([Subtitle]) -> Void) {
        let id = id ?? self.id
        if let episode = self as? Episode {
            // OpenSubtitles indexes episodes by SHOW imdb id + season +
            // episode — no Trakt roundtrip needed to resolve the episode's
            // own imdb id.
            SubtitlesManager.shared.search(episode, imdbId: episode.show?.id) { (subtitles, _) in
                completion(subtitles)
            }
        } else {
            SubtitlesManager.shared.search(imdbId: id) { (subtitles, _) in
                completion(subtitles)
            }
        }
    }
    
    /// The download, either completed or downloading, that is associated with this media object.
    var associatedDownload: PTTorrentDownload? {
        let array = PTTorrentDownloadManager.shared().activeDownloads + PTTorrentDownloadManager.shared().completedDownloads
        return array.first(where: {($0.mediaMetadata[MPMediaItemPropertyPersistentID] as? String) == self.id})
    }
    
    
    /// Boolean value indicating whether the media is currently downloading.
    var isDownloading: Bool {
        return PTTorrentDownloadManager.shared().activeDownloads.first(where: {($0.mediaMetadata[MPMediaItemPropertyPersistentID] as? String) == self.id}) != nil
    }
    
    /// The completed download of this media, if any. Playback uses this one, not
    /// `associatedDownload`: an unfinished entry of the same media (e.g. one left
    /// by the CocoaPods PopcornTorrent, which the SPM one resumes into another
    /// folder) comes first there, and a paused download never answers `play`.
    var completedDownload: PTTorrentDownload? {
        return PTTorrentDownloadManager.shared().completedDownloads.first(where: {($0.mediaMetadata[MPMediaItemPropertyPersistentID] as? String) == self.id})
    }

    /// Boolean value indicating whether the media has been downloaded.
    var hasDownloaded: Bool {
        return completedDownload != nil
    }
}
