

import SwiftUI
import PopcornKit
import VLCKit

/// SwiftUI app entry point for the iOS / iPadOS / Mac (Designed for iPad)
/// build. Re-uses the same `PopcornKit` framework as the tvOS target so the
/// catalog (YTS movies + EZTV/TVMaze shows), torrent streaming pipeline and
/// playback engine are shared. Only the UI layer is iOS-native SwiftUI.
@main
struct PopcornTimeApp: App {
    init() {
        // GCDWebServer (torrent streaming + remux HLS servers): quiet about
        // the players' cancelled requests (GCDWebServerLogging).
        GCDWebServerLogging.configure()

        // VLCKit 4 delivers player delegate callbacks on a background queue by
        // default; VLCPlayerView touches UIKit in them. Restore VLCKit 3.x
        // main-thread delivery before any player is created (see AppDelegate
        // on tvOS for the full rationale).
        VLCLibrary.sharedEventsConfiguration = VLCEventsLegacyConfiguration()

        // The torrent lists favour releases in the preferred audio language:
        // PopcornKit reads the setting through the app's language names
        // (as the tvOS and Mac apps do at launch).
        PlaybackLanguagePreferences.installReleaseLanguageResolver()
        // A retired « Highest » / « Lowest » quality setting becomes Best
        // Picture / Quick Start before Settings or a page reads it.
        AutomaticQualityChoice.migrateRetiredChoices()
        // The profiles' tastes keep a position saved again in memory a
        // while: written before the app may be killed.
        ProfileTaste.flushes(on: [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification])

        #if DEBUG
        IOSDebugHooks.applySourceSwitches()
        // The offline end-to-end runs (`-PTDebugPlayTorrent` with
        // `-PTDebugLoopbackPort`): the loopback-only torrent session and the
        // download directory, before anything uses them — as the tvOS and
        // Mac apps do at launch.
        BoundedStorageDebugHooks.prepareAtLaunch()
        #endif

        // The first MovieManager / ShowManager call triggers
        // `MediaProviders.shared = YTSEZTVProvider()` lazy init. Pre-warm it
        // here so the UI doesn't pay the cost on first cell render.
        _ = MediaProviders.shared

        // Reclaim disk left behind by previous sessions / crashes — torrent
        // partials AND orphaned remux fMP4 output. Same cleanup the tvOS
        // AppDelegate runs at launch; without it a crashed 4K stream can
        // strand ~2× the movie size on disk.
        purgeOrphanTorrentDownloads()

        // Known before the first Play: is the connection cellular data or a
        // personal hotspot (`CellularStreamingPolicy`)?
        NetworkPathObserver.shared.start()

        // A profile picked (« Who's Watching? », Settings) gets its own
        // Trakt account's lists.
        TraktManager.shared.followActiveProfile()
    }

    var body: some Scene {
        WindowGroup {
            ProfileGate { RootTabView() }
                .preferredColorScheme(.dark)
                .tint(.accentColor)
                .onOpenURL { url in
                    // Trakt's web auth flow finishes by redirecting to
                    // popcorntime://trakt?code=…&state=… — hand it off to
                    // PopcornKit and tell SettingsView to refresh its UI.
                    // (Nothing offers to sign in any more: Trakt refuses the
                    // app's key. Kept for a redirect that still arrives.)
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
