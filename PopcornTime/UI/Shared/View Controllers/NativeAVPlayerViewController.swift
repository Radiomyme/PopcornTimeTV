

import UIKit
import AVKit
import AVFoundation
import PopcornKit
import PopcornTorrent

/// Apple's native `AVPlayerViewController` for `.mp4` / `.m4v` / `.mov`
/// payloads.
///
/// UNUSED since the format-coverage overhaul: the tvOS play flow
/// (`AppDelegate.play(_:torrent:)`) now presents `RemuxAVPlayerViewController`
/// for every non-VLC payload — it plays MP4/MOV directly too, with external
/// subtitles, failure detection and the automatic VLC fallback this class
/// lacks. Kept compiling for reference; safe to delete from the target.
public final class NativeAVPlayerViewController: AVPlayerViewController {

    /// Held to keep the underlying torrent stream alive while AVPlayer is
    /// reading frames. Releasing the streamer cancels the download.
    public var streamer: PTTorrentStreamer?
    public var media:    Media?

    public func configure(url: URL,
                          startPositionPercent: Float = 0,
                          media: Media? = nil,
                          streamer: PTTorrentStreamer? = nil) {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 6.0
        // No explicit bitrate cap — let AVPlayer pick the highest the device
        // can render. On Apple TV 4K this means HEVC 10-bit + HDR10/DV +
        // Atmos when present in the file.
        item.preferredPeakBitRate = 0

        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = true
        self.player = player
        self.streamer = streamer
        self.media = media
        // Surface the file metadata to the now-playing UI on tvOS.
        if let media = media {
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = media.title as NSString
            titleItem.locale = Locale.current
            item.externalMetadata = [titleItem]
        }
        if startPositionPercent > 0 {
            DispatchQueue.main.async {
                self.seekToStart(percent: startPositionPercent)
            }
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        player?.play()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player?.pause()
        // Stop the torrent stream so PopcornTorrent's GCDWebServer is shut
        // down — the file isn't kept around between sessions.
        streamer?.cancelStreamingAndDeleteData(false)
        streamer = nil
    }

    private func seekToStart(percent: Float) {
        guard let item = player?.currentItem else { return }
        let total = CMTimeGetSeconds(item.duration)
        guard total.isFinite, total > 0 else {
            // Duration not yet known — observe and retry once it is.
            var observation: NSKeyValueObservation?
            observation = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
                let d = CMTimeGetSeconds(item.duration)
                guard d.isFinite, d > 0 else { return }
                self?.player?.seek(to: CMTime(seconds: Double(percent) * d, preferredTimescale: 1000))
                observation?.invalidate()
            }
            return
        }
        player?.seek(to: CMTime(seconds: Double(percent) * total, preferredTimescale: 1000))
    }
}
