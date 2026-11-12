

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
        #if DEBUG
        // Bounded-storage verification runs: the loopback-only torrent
        // session and the download directory, before anything uses them.
        BoundedStorageDebugHooks.prepareAtLaunch()
        #endif
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

        // The release notes again (they show once at launch, in a sheet):
        // Popcorn Time › What's New… and Settings › About.
        Window("What's New", id: MacWhatsNewWindow.id) {
            MacWhatsNewWindow()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                MacWhatsNewCommand()
            }
        }
    }
}

/// Content of the "What's New" window; Continue closes it.
struct MacWhatsNewWindow: View {
    static let id = "whatsnew"
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        WhatsNewView { dismissWindow(id: Self.id) }
    }
}

/// Popcorn Time › What's New…
private struct MacWhatsNewCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("What's New…") { openWindow(id: MacWhatsNewWindow.id) }
    }
}
