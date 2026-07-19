

import Foundation
import PopcornTorrent
import PopcornKit
import MediaPlayer.MPMediaItem

/// Walk `NSTemporaryDirectory()/Downloads/` and remove every subfolder.
/// PTTorrentStreamer stores each torrent's partials there under a hash
/// directory and never reclaims them on its own. Call this:
///   • on app launch (`AppDelegate.didFinishLaunching`) — free space
///     accumulated by previous sessions
///   • before each new `startStreaming` call — guard against the
///     "not enough space" assertion in libtorrent (Apple TV sandbox is
///     ~7–12 GB so two abandoned 4K downloads = full disk).
///
/// Standalone function (not a static on `Media`) because Swift forbids
/// calling static methods on a protocol's metatype like `Media.foo()`.
func purgeOrphanTorrentDownloads() {
    let fm = FileManager.default
    let downloads = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("Downloads")
    guard fm.fileExists(atPath: downloads) else { return }
    var freed: Int64 = 0
    let entries = (try? fm.contentsOfDirectory(atPath: downloads)) ?? []
    for entry in entries {
        let p = (downloads as NSString).appendingPathComponent(entry)
        freed += fm.folderSize(atPath: p)
        try? fm.removeItem(atPath: p)
    }
    if freed > 0 {
        print("[Cache] purged stale torrents (freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))")
    }
}

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
        finishedLoadingBlock: @escaping (PreloadTorrentViewController, UIViewController) -> Void)
    {
        if hasDownloaded, let download = associatedDownload {
            return download.play { (videoFileURL, videoFilePath) in
                loadingViewController.streamer = download
                playBlock(videoFileURL, videoFilePath, self, nextEpisode, progress, playViewController, download)
                finishedLoadingBlock(loadingViewController, playViewController)
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
        // fast-resume. Resuming a preallocated partial makes libtorrent read
        // back pieces from disk, and this build crashes in
        // `torrent::on_disk_read_complete` (a memmove overrun at a piece
        // boundary) — a bug in the prebuilt PopcornTorrent/libtorrent we can't
        // patch. So every stream starts clean; re-buffering on replay is the
        // safe trade until the torrent library is replaced/updated.
        PTTorrentStreamer.shared().cancelStreamingAndDeleteData(true)
        purgeOrphanTorrentDownloads()

        if url.hasPrefix("magnet") || (url.hasSuffix(".torrent") && !url.hasPrefix("http")) {
            loadingViewController.streamer = .shared()
            // PTTorrentStreamer dispatches its callbacks on libtorrent's
            // background queue. The blocks below all touch UIKit
            // (loadingViewController.progress / present(playerVc) /
            // alertController.show()) which asserts main-thread. Hop back
            // to main inside each callback so the caller doesn't have to
            // care about the streamer's threading.
            print("[Streamer] startStreaming magnet=\(url.prefix(80))…")
            var lastLoggedTenth: Float = -1
            PTTorrentStreamer.shared().startStreaming(fromFileOrMagnetLink: url, progress: { (status) in
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
                    DispatchQueue.main.async {
                        playBlock(videoFileURL, videoFilePath, self, nextEpisode, progress, playViewController, .shared())
                        finishedLoadingBlock(loadingViewController, playViewController)
                    }
                }, failure: { error in
                    print("[Streamer] FAILURE: \(error.localizedDescription)")
                    DispatchQueue.main.async { errorBlock(error.localizedDescription) }
            })
        } else {
            PopcornKit.downloadTorrentFile(url, completion: { (url, error) in
                // Alamofire hands the response back on its own queue too.
                DispatchQueue.main.async {
                    guard let url = url, error == nil else { errorBlock(error!.localizedDescription); return }
                    self.play(fromFileOrMagnetLink: url, nextEpisodeInSeries: nextEpisode, loadingViewController: loadingViewController, playViewController: playViewController, progress: progress, loadingBlock: loadingBlock, playBlock: playBlock, errorBlock: errorBlock, finishedLoadingBlock: finishedLoadingBlock)
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
    
    /// Boolean value indicating whether the media has been downloaded.
    var hasDownloaded: Bool {
        return PTTorrentDownloadManager.shared().completedDownloads.first(where: {($0.mediaMetadata[MPMediaItemPropertyPersistentID] as? String) == self.id}) != nil
    }
}
