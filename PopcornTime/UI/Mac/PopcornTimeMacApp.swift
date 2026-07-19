

import SwiftUI
import PopcornKit
import GCDWebServer

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
        // Silence GCDWebServer's per-chunk "[DEBUG] Connection sent…" console
        // flood from both the torrent streaming server and the remux HLS
        // server. 3 = warnings and up (same as the iOS/tvOS apps).
        GCDWebServer.setLogLevel(3)

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
