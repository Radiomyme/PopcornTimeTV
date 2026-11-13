

import Foundation
import AppKit
import SwiftUI
import PopcornKit
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
        // GCDWebServer (torrent streaming + remux HLS servers): quiet about
        // the players' cancelled requests. First: -PTDebugHTTPTrace replaces it.
        GCDWebServerLogging.configure()
        #if DEBUG
        // Bounded-storage verification runs: the loopback-only torrent
        // session and the download directory, before anything uses them.
        BoundedStorageDebugHooks.prepareAtLaunch()
        MacKeyWindowTrace.installIfRequested()
        #endif
        // VLCKit 4 delivers player callbacks on a background queue by default;
        // restore main-thread delivery before any player exists (same rationale
        // as the iOS/tvOS apps).
        VLCLibrary.sharedEventsConfiguration = VLCEventsLegacyConfiguration()

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

#if DEBUG
/// `-PTDebugKeyWindowTrace YES`: every `-[NSWindow makeKeyWindow]` sent to a
/// window that cannot become key (AppKit then logs "Warning: -[NSWindow
/// makeKeyWindow] called on … which returned NO from canBecomeKeyWindow")
/// prints the window and the call stack, to tell our calls from AppKit's.
enum MacKeyWindowTrace {
    static func installIfRequested() {
        guard UserDefaults.standard.bool(forKey: "PTDebugKeyWindowTrace"),
              let method = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.makeKey)) else { return }
        typealias MakeKey = @convention(c) (NSWindow, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: MakeKey.self)
        let selector = #selector(NSWindow.makeKey)
        let replacement: @convention(block) (NSWindow) -> Void = { window in
            if !window.canBecomeKey {
                let parent = window.parent.map { "\(type(of: $0)) #\($0.windowNumber)" } ?? "none"
                print("[KeyTrace] makeKeyWindow on \(type(of: window)) #\(window.windowNumber) frame \(NSStringFromRect(window.frame)) "
                      + "parent \(parent) sheet \(window.isSheet) key now: \(NSApp.keyWindow.map { "\(type(of: $0)) #\($0.windowNumber)" } ?? "none")")
                print(Thread.callStackSymbols.prefix(28).map { "[KeyTrace]   " + $0 }.joined(separator: "\n"))
            }
            original(window, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        print("[KeyTrace] on")
    }
}
#endif
