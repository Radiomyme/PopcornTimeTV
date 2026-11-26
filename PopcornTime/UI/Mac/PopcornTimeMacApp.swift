

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
///
/// Two `App`s with the same scenes: the window's restoration is turned off
/// in the scene on macOS 15 and later (`restorationBehavior`, which a
/// scene builder cannot apply under `if #available` with an `else`); on
/// macOS 14 the window itself is not restorable (`MacWindowReader`).
@main
enum PopcornTimeMacMain {
    static func main() {
        if #available(macOS 15.0, *) {
            PopcornTimeMacApp.main()
        } else {
            PopcornTimeMacApp14.main()
        }
    }
}

/// macOS 15 and later.
@available(macOS 15.0, *)
struct PopcornTimeMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    init() { MacAppLaunch.prepare() }

    var body: some Scene {
        // A window state macOS kept from a run that was killed (a crash, a
        // forced quit) made the app start with no window at all: none is
        // saved any more. The window opens at its default size and place.
        MacMainWindowScene()
            .restorationBehavior(.disabled)
        MacSecondaryScenes()
    }
}

/// macOS 14: the same scenes; `MacWindowReader` makes the window not
/// restorable.
struct PopcornTimeMacApp14: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    init() { MacAppLaunch.prepare() }

    var body: some Scene {
        MacMainWindowScene()
        MacSecondaryScenes()
    }
}

/// What the app does before its first scene.
enum MacAppLaunch {
    static func prepare() {
        // The torrent lists favour releases in the preferred audio language:
        // PopcornKit reads the setting through the app's language names.
        AudioLanguagePreference.resolver = { PlaybackLanguagePreferences.isoCode(for: $0) }
        // GCDWebServer (torrent streaming + remux HLS servers): quiet about
        // the players' cancelled requests. First: -PTDebugHTTPTrace replaces it.
        GCDWebServerLogging.configure()
        #if DEBUG
        // Bounded-storage verification runs: the loopback-only torrent
        // session and the download directory, before anything uses them.
        BoundedStorageDebugHooks.prepareAtLaunch()
        MacKeyWindowTrace.installIfRequested()
        // A verification run's log goes to a file and the run is often
        // ended by a signal: every line is written as it is printed.
        if MacDebugHooks.isActive {
            setlinebuf(stdout)
            MacDebugHooks.noteLaunch()
        }
        #endif
        // VLCKit 4 delivers player callbacks on a background queue by default;
        // restore main-thread delivery before any player exists (same rationale
        // as the iOS/tvOS apps).
        VLCLibrary.sharedEventsConfiguration = VLCEventsLegacyConfiguration()

        // Pre-warm the provider chain (same as the iOS app).
        _ = MediaProviders.shared
        // Reclaim torrent partials + orphaned remux output from previous
        // sessions/crashes.
        #if DEBUG
        // Not in a snapshot run (-PTDebugSection, -PTDebugTour…): it plays
        // nothing, and the temporary folder is shared with any other copy
        // of the app on this Mac — one that is streaming would lose its
        // file. (The bounded-storage runs do play: they purge as usual.)
        if MacDebugHooks.isActive && !BoundedStorageDebugHooks.isActive { return }
        // Nor in a run that streams into its own `-PTDebugDownloadDir`.
        if BoundedStorageDebugHooks.leavesTemporaryFolderAlone { return }
        #endif
        purgeOrphanTorrentDownloads()
    }
}

/// The app's window: the sidebar, the sections and the pages.
struct MacMainWindowScene: Scene {
    var body: some Scene {
        // Named, so that the safety net (`MacWindowNet`) can open one.
        WindowGroup(id: MacWindowNet.mainWindowID) {
            // popcorntime:// URLs — the links to a title, a section, a
            // search, and Trakt's sign-in redirect — are the window's
            // (`MacRootView.onOpenURL`).
            ProfileGate { MacRootView() }
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 640)
        }
        // Not restored any more: a new window opens at this size, centred.
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.automatic)
        .commands {
            // View › Show / Hide Sidebar, then the app's own menus.
            SidebarCommands()
            MacGoCommands()
            MacPlaybackCommands()
        }
    }
}

/// The Settings and the release notes' window.
struct MacSecondaryScenes: Scene {
    var body: some Scene {
        Settings {
            // Dark as the app's window: not a light panel beside it.
            // Made again for another profile: its language preferences.
            ProfileScoped { MacSettingsView() }
                .preferredColorScheme(.dark)
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
        // The menus exist with no window open: the safety net opens the
        // app's window with this action (`MacWindowNet`).
        let _ = MacWindowNet.keep(openWindow)
        Button("What's New…") { openWindow(id: MacWhatsNewWindow.id) }
    }
}

// MARK: - A window, always

/// The app never stays open with no window of its own after a launch: if
/// none is there a moment after the launch (a window state macOS restored
/// from a killed run did that), one is opened; and a click on the Dock icon
/// with no window open opens one.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacWindowNet.checkAfterLaunch()
        #if DEBUG
        MacWindowNet.runDebugCheck()
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A window kept in the Dock is brought back by the system (true).
        guard !MacWindowNet.hasMainWindow else { return true }
        MacWindowNet.openMainWindow(reason: "reopen")
        return false
    }
}

/// The app's main windows (those `MacRootView` is drawn in) and how to open
/// one when there is none.
@MainActor
enum MacWindowNet {
    static let mainWindowID = "main"

    /// The windows `MacRootView` has been put in (`MacWindowReader`).
    private static let windows = NSHashTable<NSWindow>.weakObjects()
    /// The scenes' window opener, kept from the menus (which exist with no
    /// window open).
    private static var openWindow: OpenWindowAction?

    static func keep(_ action: OpenWindowAction) {
        openWindow = action
    }

    static func register(_ window: NSWindow) {
        if !windows.contains(window) {
            // Closed, it no longer counts — even while the app is hidden.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { windows.remove(window) } }
            }
        }
        windows.add(window)
        #if DEBUG
        debugWindowRegistered(window)
        #endif
    }

    /// A main window is open: on screen, in the Dock, or not closed in an
    /// app that is hidden (⌘H, a login item opened hidden: its windows are
    /// not visible, yet they are there — a second one must not open).
    static var hasMainWindow: Bool {
        windows.allObjects.contains(where: isOpen)
    }

    static var mainWindowCount: Int {
        windows.allObjects.filter(isOpen).count
    }

    private static func isOpen(_ window: NSWindow) -> Bool {
        window.isVisible || window.isMiniaturized || NSApp.isHidden
    }

    /// One second after the launch, then half a second later (a slow
    /// launch may still be opening its window): no main window at either
    /// look, one is opened.
    static func checkAfterLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard !hasMainWindow else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard !hasMainWindow else { return }
                openMainWindow(reason: "launch")
            }
        }
    }

    static func openMainWindow(reason: String) {
        if let openWindow {
            openWindow(id: mainWindowID)
            log("no window (\(reason)): opened one with the scene's opener")
        } else if let item = newWindowMenuItem, let menu = item.menu {
            // File › New Window, as a click.
            menu.performActionForItem(at: menu.index(of: item))
            log("no window (\(reason)): opened one with File › New Window")
        } else {
            log("no window (\(reason)): nothing can open one")
        }
    }

    /// File › New Window (⌘N), whatever the menu's language.
    private static var newWindowMenuItem: NSMenuItem? {
        guard let items = NSApp.mainMenu?.items else { return nil }
        for menu in items.compactMap(\.submenu) {
            if let item = menu.items.first(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }) {
                return item
            }
        }
        return nil
    }

    private static func log(_ text: String) {
        #if DEBUG
        print("[WindowNet] \(text)")
        #endif
    }
}

#if DEBUG
/// `-PTDebugWindowNet <launch|reopen>` (with a `-PTDebug…` argument of
/// MacDebugHooks', e.g. `-PTDebugSnapshot`, so that the run is a
/// verification run): proves the safety net in process.
/// - `launch`: the first main window is closed as soon as it is on screen
///   (the app is then as a launch with no window leaves it); the net must
///   open one. At 4 s the run says how many main windows there are, writes
///   `windownet-launch.png` beside `-PTDebugSnapshot`'s file and quits.
/// - `reopen`: at 3 s every main window is closed; 1.5 s later the run says
///   how many there are (none: a window the user closes stays closed), then
///   sends the app the Apple event a click on its Dock icon sends
///   (`kAEReopenApplication`); 2 s later it says how many there are, writes
///   `windownet-reopen.png` and quits.
/// - `hidden`: the app hides itself at once (as ⌘H in its first second, or
///   a login item opened hidden); at 4 s the run says how many main windows
///   are registered and open (one: the net must not have opened a second),
///   then quits.
/// Each main window's `isRestorable` is logged when it opens.
extension MacWindowNet {
    private static var debugMode: String? {
        guard MacDebugHooks.isActive else { return nil }
        return UserDefaults.standard.string(forKey: "PTDebugWindowNet")?.lowercased()
    }

    private static var debugClosedLaunchWindow = false

    static func debugWindowRegistered(_ window: NSWindow) {
        guard MacDebugHooks.isActive else { return }
        print("[WindowNet] main window #\(window.windowNumber) \(window.identifier?.rawValue ?? "-"): isRestorable \(window.isRestorable)"
              + " · background \(window.backgroundColor.usingColorSpace(.sRGB).map { String(format: "%.3f %.3f %.3f", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? "?")"
              + " · main windows \(mainWindowCount)")
        if debugMode == "launch", !debugClosedLaunchWindow {
            debugClosedLaunchWindow = true
            DispatchQueue.main.async {
                window.close()
                print("[WindowNet] debug: the launch window is closed · main windows \(mainWindowCount)")
            }
        }
    }

    static func runDebugCheck() {
        guard let mode = debugMode else { return }
        let directory = UserDefaults.standard.string(forKey: "PTDebugSnapshot")
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        if mode == "hidden" {
            NSApp.hide(nil)
            print("[WindowNet] debug hidden: the app hides itself at launch")
        }
        Task { @MainActor in
            switch mode {
            case "hidden":
                try? await Task.sleep(for: .seconds(4))
                print("[WindowNet] debug hidden: app hidden \(NSApp.isHidden) · main windows \(mainWindowCount) "
                      + "(registered \(windows.allObjects.count)) at 4 s")
            case "launch":
                try? await Task.sleep(for: .seconds(4))
                print("[WindowNet] debug launch: main windows \(mainWindowCount) at 4 s")
                await debugSnapshot("windownet-launch", in: directory)
            case "reopen":
                try? await Task.sleep(for: .seconds(3))
                print("[WindowNet] debug reopen: main windows \(mainWindowCount) before closing")
                for window in windows.allObjects where window.isVisible { window.close() }
                try? await Task.sleep(for: .seconds(1.5))
                print("[WindowNet] debug reopen: main windows \(mainWindowCount) 1.5 s after closing them")
                let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(0x6165_7674),     // 'aevt'
                                                    eventID: AEEventID(0x7261_7070),          // 'rapp'
                                                    targetDescriptor: .currentProcess(),
                                                    returnID: AEReturnID(kAutoGenerateReturnID),
                                                    transactionID: AETransactionID(kAnyTransactionID))
                do {
                    _ = try reopen.sendEvent(options: [.noReply], timeout: 5)
                    print("[WindowNet] debug reopen: reopen Apple event sent")
                } catch {
                    print("[WindowNet] debug reopen: the Apple event failed: \(error)")
                }
                try? await Task.sleep(for: .seconds(2))
                print("[WindowNet] debug reopen: main windows \(mainWindowCount) 2 s after the reopen event")
                await debugSnapshot("windownet-reopen", in: directory)
            default:
                print("[WindowNet] debug: unknown mode \(mode)")
                return
            }
            try? await Task.sleep(for: .seconds(0.5))
            NSApp.terminate(nil)
        }
    }

    private static func debugSnapshot(_ name: String, in directory: URL?) async {
        guard let directory, let window = windows.allObjects.first(where: \.isVisible) else {
            print("[WindowNet] debug: no snapshot (\(directory == nil ? "no -PTDebugSnapshot" : "no main window"))")
            return
        }
        let url = directory.appendingPathComponent(name + ".png")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let image = MacFirstPaintProbe.windowServerImage(of: window), image.width > 1,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else {
            print("[WindowNet] debug: no snapshot (the window server gave no image)")
            return
        }
        print("[WindowNet] debug: snapshot \(image.width)×\(image.height) → \(url.path)")
    }
}

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
