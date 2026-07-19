

import SwiftUI
import PopcornKit
import GCDWebServer
import VLCKit

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
        // VLCKit 4 delivers player callbacks on a background queue by default;
        // restore main-thread delivery before any player exists (same rationale
        // as the iOS/tvOS apps).
        VLCLibrary.sharedEventsConfiguration = VLCEventsLegacyConfiguration()

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
                .onOpenURL { url in
                    // Trakt OAuth callback from the browser:
                    // popcorntime://trakt?code=…&state=…
                    if url.scheme == "popcorntime", url.host == "trakt" {
                        TraktManager.shared.authenticate(url)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            NotificationCenter.default.post(name: .macTraktDidAuthenticate, object: nil)
                        }
                    }
                }
        }
        .windowStyle(.automatic)

        Settings {
            MacSettingsView()
        }
    }
}
