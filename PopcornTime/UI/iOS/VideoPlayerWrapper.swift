

import SwiftUI
import AVKit

/// Wraps `AVPlayerViewController` so SwiftUI can present it full-screen.
/// AVPlayer is the right call on iOS / iPadOS / Mac — it has hardware HEVC,
/// HDR10, Dolby Vision and Atmos rendering, AirPlay 4K, picture-in-picture,
/// and all the standard transport controls Apple users expect. MKV files
/// won't open through this path; they'll need a VLC alternative which a
/// future revision can plug in via the same `PlaybackEngine` protocol the
/// tvOS app uses.
struct VideoPlayerWrapper: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = true
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        if #available(iOS 14, *) {
            vc.canStartPictureInPictureAutomaticallyFromInline = true
        }
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) {
        vc.player?.pause()
        vc.player = nil
    }
}
