

import SwiftUI
import PopcornKit

/// Native macOS app entry point. Shares the whole core with iOS/tvOS —
/// PopcornKit (catalog, torrents metadata, subtitles), PopcornTorrent (SPM,
/// libtorrent built natively for macOS) and the MKV→fMP4/HLS remux engine —
/// but presents a real Mac UI (NavigationSplitView) and plays through AVKit's
/// `AVPlayerView`, so Dolby Atmos content is spatialized by macOS itself
/// (built-in speakers / AirPods) instead of being stereo-downmixed like the
/// iOS-app-on-Mac build.
@main
struct PopcornTimeMacApp: App {
    init() {
        // Pre-warm the provider chain (same as the iOS app).
        _ = MediaProviders.shared
        // Reclaim torrent partials + orphaned remux output from previous
        // sessions/crashes.
        purgeOrphanTorrentDownloads()
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.automatic)
    }
}
