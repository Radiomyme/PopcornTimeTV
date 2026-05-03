

import SwiftUI
import PopcornKit

/// SwiftUI app entry point for the iOS / iPadOS / Mac (Designed for iPad)
/// build. Re-uses the same `PopcornKit` framework as the tvOS target so the
/// catalog (YTS movies + EZTV/TVMaze shows), torrent streaming pipeline and
/// playback engine are shared. Only the UI layer is iOS-native SwiftUI.
@main
struct PopcornTimeApp: App {
    init() {
        // The first MovieManager / ShowManager call triggers
        // `MediaProviders.shared = YTSEZTVProvider()` lazy init. Pre-warm it
        // here so the UI doesn't pay the cost on first cell render.
        _ = MediaProviders.shared
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
                .tint(.accentColor)
        }
    }
}
