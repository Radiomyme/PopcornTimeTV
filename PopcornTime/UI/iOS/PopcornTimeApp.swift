

import SwiftUI
import PopcornKit
import VLCKit
import GCDWebServer

/// SwiftUI app entry point for the iOS / iPadOS / Mac (Designed for iPad)
/// build. Re-uses the same `PopcornKit` framework as the tvOS target so the
/// catalog (YTS movies + EZTV/TVMaze shows), torrent streaming pipeline and
/// playback engine are shared. Only the UI layer is iOS-native SwiftUI.
@main
struct PopcornTimeApp: App {
    init() {
        // VLCKit 4 delivers player delegate callbacks on a background queue by
        // default; VLCPlayerView touches UIKit in them. Restore VLCKit 3.x
        // main-thread delivery before any player is created (see AppDelegate
        // on tvOS for the full rationale).
        VLCLibrary.sharedEventsConfiguration = VLCEventsLegacyConfiguration()

        // Silence GCDWebServer's per-chunk "[DEBUG] Connection sent…" console
        // flood from the torrent streaming server. 3 = warnings and up.
        GCDWebServer.setLogLevel(3)

        // The first MovieManager / ShowManager call triggers
        // `MediaProviders.shared = YTSEZTVProvider()` lazy init. Pre-warm it
        // here so the UI doesn't pay the cost on first cell render.
        _ = MediaProviders.shared

        // Reclaim disk left behind by previous sessions / crashes — torrent
        // partials AND orphaned remux fMP4 output. Same cleanup the tvOS
        // AppDelegate runs at launch; without it a crashed 4K stream can
        // strand ~2× the movie size on disk.
        purgeOrphanTorrentDownloads()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
                .tint(.accentColor)
                .onOpenURL { url in
                    // Trakt's web auth flow finishes by redirecting to
                    // popcorntime://trakt?code=…&state=… — hand it off to
                    // PopcornKit and tell SettingsView to refresh its UI.
                    if url.scheme == "popcorntime", url.host == "trakt" {
                        TraktManager.shared.authenticate(url)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            NotificationCenter.default.post(name: .traktDidAuthenticate, object: nil)
                        }
                    }
                }
        }
    }
}
