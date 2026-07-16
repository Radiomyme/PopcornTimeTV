

import AVFoundation
import VLCKit

/// Player-engine abstraction shared by `VLCEngine` and `AVPlayerEngine`.
///
/// `PCTPlayerViewController` currently drives `VLCMediaPlayer` directly. The
/// goal of this scaffolding is to let a future iteration swap engines based
/// on codec / HDR signaling — AVPlayer is the only path that gets HDR10 and
/// Dolby Vision rendered natively on tvOS, while VLC stays the fallback for
/// MKV containers and codecs AVPlayer can't decode (legacy AVI/Xvid, certain
/// AC3 audio configs, etc.). For now, the protocol exists so the engines can
/// be unit-tested and the codec sniffer can ship; full integration into the
/// player VC is tracked under Phase 7.
public protocol PlaybackEngine: AnyObject {
    var drawable: UIView? { get set }
    var rate: Float { get set }
    var isPlaying: Bool { get }
    /// Time elapsed since the start of the current item, in seconds.
    var currentTime: TimeInterval { get }
    /// Total duration of the current item if known, in seconds.
    var duration: TimeInterval { get }

    func load(url: URL)
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)
}

/// Heuristic that picks an engine for a stream URL. AVPlayer is preferred for
/// `.mp4` / `.m4v` / `.mov` (HDR/DV/Atmos native on tvOS 17+); VLC handles
/// `.mkv` / `.avi` / `.flv` and anything we can't pre-classify.
public enum PlaybackEngineSelector {
    public static func makeEngine(for url: URL,
                                  vlcMediaPlayer: VLCMediaPlayer? = nil) -> PlaybackEngine {
        let path = url.path.lowercased()
        let avPlayerNative = path.hasSuffix(".mp4") || path.hasSuffix(".m4v") || path.hasSuffix(".mov")
        if avPlayerNative {
            return AVPlayerEngine()
        }
        return VLCEngine(player: vlcMediaPlayer ?? VLCMediaPlayer())
    }
}

// MARK: - VLC engine

public final class VLCEngine: PlaybackEngine {
    public let player: VLCMediaPlayer

    public init(player: VLCMediaPlayer = VLCMediaPlayer()) {
        self.player = player
    }

    public var drawable: UIView? {
        get { player.drawable as? UIView }
        set { player.drawable = newValue }
    }

    public var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    public var isPlaying: Bool { player.isPlaying }

    public var currentTime: TimeInterval {
        guard let ms = player.time.value?.doubleValue else { return 0 }
        return ms / 1000.0
    }

    public var duration: TimeInterval {
        if let media = player.media,
           let totalMs = media.length.value?.doubleValue {
            return totalMs / 1000.0
        }
        return 0
    }

    public func load(url: URL) {
        guard let media = VLCMedia(url: url) else { return } // VLCKit 4: failable init
        media.addOptions([
            "network-caching": NSNumber(value: 5000),
            "file-caching":    NSNumber(value: 5000),
            "live-caching":    NSNumber(value: 5000),
            "drop-late-frames": NSNumber(value: 0),
            "skip-frames":      NSNumber(value: 0),
        ])
        player.media = media
    }

    public func play()  { player.play() }
    public func pause() { player.pause() }
    public func stop()  { player.stop() }

    public func seek(to seconds: TimeInterval) {
        player.time = VLCTime(int: Int32(seconds * 1000.0))
    }
}

// MARK: - AVPlayer engine

public final class AVPlayerEngine: PlaybackEngine {
    public let player = AVPlayer()
    public let layer  = AVPlayerLayer()

    public init() {
        layer.player = player
        // tvOS 17+ default. Keep aspect-fit to avoid cropping HDR/DV content.
        layer.videoGravity = .resizeAspect
    }

    public var drawable: UIView? {
        didSet {
            layer.removeFromSuperlayer()
            if let view = drawable {
                layer.frame = view.bounds
                layer.needsDisplayOnBoundsChange = true
                view.layer.addSublayer(layer)
            }
        }
    }

    public var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    public var isPlaying: Bool { player.rate != 0 && player.error == nil }

    public var currentTime: TimeInterval {
        return CMTimeGetSeconds(player.currentTime())
    }

    public var duration: TimeInterval {
        guard let item = player.currentItem else { return 0 }
        let total = CMTimeGetSeconds(item.duration)
        return total.isFinite ? total : 0
    }

    public func load(url: URL) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item  = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 6.0
        // Cap at the maximum the device supports (no artificial bitrate ceiling).
        item.preferredPeakBitRate = 0
        player.replaceCurrentItem(with: item)
    }

    public func play()  { player.play() }
    public func pause() { player.pause() }
    public func stop()  {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    public func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
