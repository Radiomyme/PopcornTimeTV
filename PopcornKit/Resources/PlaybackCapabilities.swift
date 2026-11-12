

import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia

// CONTRACT FILE — owned by agent D1. Part of PopcornKit (iOS, tvOS, macOS).

/// What the current device can play natively — drives torrent ranking so
/// the picker recommends releases that will actually play well here.
///
/// The `supports…` properties answer live: the display path can change at
/// any time (HDMI / AirPlay / external monitor, a TV without Dolby Vision).
/// Decoder support can't change while the app runs, so VideoToolbox is probed
/// once. `current` is a cached snapshot for hot paths such as sort
/// comparators: `AVPlayer.eligibleForHDRPlayback` costs milliseconds per call
/// (measured ≈4 ms on an M3 Mac), far too slow to evaluate per comparison.
public enum PlaybackCapabilities {

    /// Hardware AV1 decode (A17 Pro / M3 and later). Software AV1 at 4K
    /// stutters on Apple TV, so ranking penalizes AV1 without it.
    public static var supportsAV1HardwareDecode: Bool {
        return decoders.av1
    }

    /// HEVC hardware decode (every supported device but the Apple TV HD).
    public static var supportsHEVCHardwareDecode: Bool {
        return decoders.hevc
    }

    /// The device can render Dolby Vision (decoder + display path).
    public static var supportsDolbyVision: Bool {
        return dolbyVisionSupport(hdrEligible: AVPlayer.eligibleForHDRPlayback)
    }

    /// The device / display path can present HDR10 / HLG.
    public static var supportsHDR: Bool {
        return AVPlayer.eligibleForHDRPlayback
    }

    // MARK: - Snapshot

    /// Value copy of the four capabilities, so a ranking pass evaluates every
    /// torrent against the same answers.
    public struct Snapshot: Equatable, CustomStringConvertible {
        public var av1HardwareDecode: Bool
        public var hevcHardwareDecode: Bool
        public var dolbyVision: Bool
        public var hdr: Bool

        public init(av1HardwareDecode: Bool, hevcHardwareDecode: Bool, dolbyVision: Bool, hdr: Bool) {
            self.av1HardwareDecode = av1HardwareDecode
            self.hevcHardwareDecode = hevcHardwareDecode
            self.dolbyVision = dolbyVision
            self.hdr = hdr
        }

        /// Plays everything natively (e.g. an Apple TV 4K on a Dolby Vision TV).
        public static let everything = Snapshot(av1HardwareDecode: true, hevcHardwareDecode: true,
                                                dolbyVision: true, hdr: true)

        public var description: String {
            return "AV1hw=\(av1HardwareDecode) HEVChw=\(hevcHardwareDecode) DV=\(dolbyVision) HDR=\(hdr)"
        }
    }

    /// How long `current` may be served from cache. Display changes also
    /// invalidate it immediately (AVPlayer HDR notifications).
    public static var snapshotLifetime: TimeInterval = 30

    /// Tests: the answer of `current` whatever the display (nil: probed).
    /// `AVPlayer.eligibleForHDRPlayback` follows the Mac's display (false
    /// while it sleeps), which changed the merge a test checks.
    static var pinnedForTesting: Snapshot?

    /// Cached snapshot of the capabilities (thread-safe).
    public static var current: Snapshot {
        if let pinned = pinnedForTesting { return pinned }
        _ = displayObservers   // installs the invalidation observers once
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let cached = cached, cached.expiry > now {
            lock.unlock()
            return cached.snapshot
        }
        lock.unlock()
        // Probe outside the lock: the display queries are IPC round trips.
        let hdr = AVPlayer.eligibleForHDRPlayback
        let fresh = Snapshot(av1HardwareDecode: decoders.av1,
                             hevcHardwareDecode: decoders.hevc,
                             dolbyVision: dolbyVisionSupport(hdrEligible: hdr),
                             hdr: hdr)
        lock.lock()
        cached = (fresh, now + snapshotLifetime)
        lock.unlock()
        return fresh
    }

    /// Drop the cached snapshot (the next `current` probes again).
    public static func invalidateSnapshot() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    // MARK: - Private

    private static let lock = NSLock()
    private static var cached: (snapshot: Snapshot, expiry: TimeInterval)?

    private static let displayObservers: [NSObjectProtocol] = {
        var names: [Notification.Name] = [AVPlayer.eligibleForHDRPlaybackDidChangeNotification]
        #if os(tvOS)
        names.append(.AVPlayerAvailableHDRModesDidChange)
        #endif
        return names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                invalidateSnapshot()
            }
        }
    }()

    /// Hardware decoders, probed once.
    private static let decoders: (av1: Bool, hevc: Bool, dolbyVision: Bool) = {
        var av1 = false
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        }
        return (av1: av1,
                hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                dolbyVision: VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC))
    }()

    private static func dolbyVisionSupport(hdrEligible: @autoclosure () -> Bool) -> Bool {
        #if os(tvOS)
        // Per display: false on SDR TVs and on HDR10-only sets (many Samsung
        // TVs), where a Dolby Vision-only (profile 5) release has no usable
        // base layer. Deprecated in tvOS 26 in favour of
        // `eligibleForHDRPlayback`, which can't tell DV from HDR10; it still
        // works and the tvOS 17 deployment target keeps it warning-free.
        return AVPlayer.availableHDRModes.contains(.dolbyVision)
        #elseif os(macOS)
        // `availableHDRModes` doesn't exist on macOS: require an HDR display
        // path plus the Dolby Vision decoder (Apple silicon).
        return decoders.dolbyVision && hdrEligible()
        #else
        // iOS 26 (the deployment target) deprecates `availableHDRModes`; every
        // device it runs on decodes Dolby Vision, so HDR eligibility is the
        // remaining condition.
        return hdrEligible()
        #endif
    }
}
