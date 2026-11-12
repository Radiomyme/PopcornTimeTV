#if DEBUG
import Foundation
import AppKit
import AVKit
import SwiftUI
import PopcornKit

/// Verification hooks of the Mac app, compiled only with DEBUG (the app
/// targets do not define it: build with
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` on the xcodebuild command
/// line). Launch arguments:
/// - `-PTDebugSection <movies|shows|search|watchlist>`: select that section;
/// - `-PTDebugOpenMovie <IMDb id>` / `-PTDebugOpenShow <IMDb id>`: push that
///   title's page at launch (never plays anything);
/// - `-PTDebugScroll <hero|episodes|related|cast|info>`: scroll the open page
///   there once its sections have loaded (MacGlassDetailView);
/// - `-PTDebugExpand <summary|episode>`: then open that full-text sheet;
/// - `-PTDebugGlassFallback YES`: draw the page with the macOS 14 / 15
///   materials instead of Liquid Glass (the in-process snapshot cannot draw
///   accent-tinted glass: the scroll view holding it comes out blank);
/// - `-PTDebugAmbient YES`: open a movie page without its backdrop (the
///   blurred poster and poster card layout);
/// - `-PTDebugWindowSize <width>x<height>`: the window's size, e.g. 1400x900;
/// - `-PTDebugSnapshot <absolute .png path>` with `-PTDebugSnapshotDelay
///   <seconds>` (default 8): renders the window into that PNG
///   (`-PTDebugSnapshotAll YES` also writes every capture method's image);
/// - `-PTDebugQuit YES`: quit after the snapshot;
/// - `-PTDebugBoundedSnapshots <directory>` (bounded storage, with
///   BoundedStorageDebugHooks' `-PTDebugPlayTorrent`): the player's window
///   into `<directory>/bounded-loading.png` once the loading screen shows
///   the bounded-storage line, and `bounded-toast.png` once a rewind is
///   limited (MacPlayerView, `snapshotPlayerWindow`).
/// - `-PTDebugFilter <raw value>` (e.g. top100): the Movies and Shows grids'
///   filter at launch;
/// - `-PTDebugQualitySheet YES`: a movie page opens its quality sheet once
///   loaded (never plays); the snapshot then also writes the sheet into
///   `<name>.sheet.png`;
/// - `-PTDebugTop100Offline YES`: The Pirate Bay off and the cached Top 100
///   lists deleted (the grids' error state).
/// Any of them also skips the release notes sheet. Nothing happens without
/// these arguments.
enum MacDebugHooks {
    private static var defaults: UserDefaults { .standard }
    private static let keys = ["PTDebugSection", "PTDebugOpenMovie", "PTDebugOpenShow", "PTDebugScroll",
                               "PTDebugExpand", "PTDebugGlassFallback", "PTDebugAmbient", "PTDebugWindowSize",
                               "PTDebugSnapshot", "PTDebugQuit", "PTDebugFilter", "PTDebugQualitySheet",
                               "PTDebugTop100Offline"]

    static var isActive: Bool {
        keys.contains { defaults.object(forKey: $0) != nil }
    }

    static var section: MacSection? {
        switch defaults.string(forKey: "PTDebugSection")?.lowercased() {
        case "movies"?: return .movies
        case "shows"?: return .shows
        case "search"?: return .search
        case "watchlist"?: return .watchlist
        default: return nil
        }
    }

    /// `-PTDebugTop100Offline`: The Pirate Bay off, no cached Top 100. Once,
    /// before the first grid loads.
    static func applySourceSwitches() {
        guard defaults.bool(forKey: "PTDebugTop100Offline"), PirateBayClient.isEnabled else { return }
        PirateBayClient.isEnabled = false
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        for kind in ["movie", "series"] {
            if let url = caches?.appendingPathComponent("popcornkit-top100-\(kind).json") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        print("[MacDebug] The Pirate Bay off, Top 100 cache deleted")
    }

    /// `-PTDebugFilter`: the Movies grid's filter at launch.
    static var movieFilter: MovieManager.Filters? {
        defaults.string(forKey: "PTDebugFilter").flatMap(MovieManager.Filters.init(rawValue:))
    }

    /// `-PTDebugFilter`: the Shows grid's filter at launch.
    static var showFilter: ShowManager.Filters? {
        defaults.string(forKey: "PTDebugFilter").flatMap(ShowManager.Filters.init(rawValue:))
    }

    /// A placeholder with the IMDb id: the page loads the real title.
    static var media: Media? {
        if let id = defaults.string(forKey: "PTDebugOpenMovie") { return Movie(title: id, id: id) }
        if let id = defaults.string(forKey: "PTDebugOpenShow") { return Show(title: id, id: id) }
        return nil
    }

    /// The app's main window (the largest visible non-panel window).
    @MainActor
    private static var mainWindow: NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// `-PTDebugWindowSize`: resizes and centers the main window (once it is
    /// on screen: up to 5 s).
    @MainActor
    static func prepareWindow() async {
        guard let value = defaults.string(forKey: "PTDebugWindowSize") else { return }
        for _ in 0..<50 where mainWindow == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let parts = value.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = mainWindow else {
            print("[MacDebug] window size \(value): no window or bad size")
            return
        }
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: parts[0], height: parts[1]))
        window.setFrame(NSRect(origin: window.frame.origin, size: frame.size), display: true)
        window.center()
        print("[MacDebug] window \(Int(window.frame.width))×\(Int(window.frame.height))")
    }

    /// `-PTDebugSnapshot`: after the delay, the window into a PNG; then
    /// `-PTDebugQuit` quits.
    @MainActor
    static func scheduleSnapshot() {
        guard let path = defaults.string(forKey: "PTDebugSnapshot") else { return }
        let delay = defaults.string(forKey: "PTDebugSnapshotDelay").flatMap(Double.init) ?? 8
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            snapshot(to: URL(fileURLWithPath: path))
            if defaults.bool(forKey: "PTDebugQuit") {
                try? await Task.sleep(nanoseconds: 500_000_000)
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Snapshot

    /// `-PTDebugBoundedSnapshots`: the player's sheet (else the key window) into
    /// `<directory>/<name>.png`, `delay` seconds from now, once per name.
    @MainActor
    static func snapshotPlayerWindow(named name: String, after delay: Double) {
        guard let directory = defaults.string(forKey: "PTDebugBoundedSnapshots"),
              !takenPlayerSnapshots.contains(name) else { return }
        takenPlayerSnapshots.insert(name)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            // The player is a sheet (its own window); the app may not be active.
            let window = NSApp.windows.first { $0.isVisible && $0.isSheet } ?? NSApp.keyWindow
            snapshot(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"), window: window)
        }
    }

    @MainActor
    private static var takenPlayerSnapshots: Set<String> = []

    // MARK: Player sheet (bounded storage coverage hooks)

    /// The player's sheet (`MacPlayerView`), nil once it is closed.
    @MainActor
    static var playerSheet: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.isSheet }
    }

    /// `-PTDebugClosePlayer` (BoundedStorageDebugHooks): closes the player the
    /// way the user does — its close button (pressed through accessibility,
    /// like a click), else its Escape shortcut. Returns how.
    @MainActor
    static func closePlayerSheet() -> String {
        guard let sheet = playerSheet else { return "no player sheet — nothing done" }
        let buttons = accessibilityNodes(in: sheet).filter { $0.role == NSAccessibility.Role.button.rawValue }
        let labels = buttons.map { $0.label.isEmpty ? "?" : $0.label }
        // The xmark button (SwiftUI names it after its symbol, "Close" or similar).
        if let close = buttons.last(where: { node in
            let label = node.label.lowercased()
            return label.contains("close") || label.contains("xmark") || label.contains("fermer")
        }), close.press() {
            return "close button pressed (accessibility; buttons: \(labels))"
        }
        // The same button's shortcut: Escape, as a key equivalent of the sheet.
        func escape(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                             charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
        }
        if let down = escape(.keyDown) {
            if sheet.performKeyEquivalent(with: down) { return "Escape shortcut (key equivalent; buttons: \(labels))" }
            sheet.makeKey()
            NSApp.sendEvent(down)
            if let up = escape(.keyUp) { NSApp.sendEvent(up) }
            return "Escape key event sent to the sheet (no button matched; buttons: \(labels))"
        }
        return "nothing could close the sheet (buttons: \(labels))"
    }

    /// The AVPlayer of the player sheet (native routes), nil for VLC.
    @MainActor
    static func currentAVPlayer() -> AVPlayer? {
        guard let root = playerSheet?.contentView else { return nil }
        func find(_ view: NSView, depth: Int) -> AVPlayerView? {
            if let player = view as? AVPlayerView { return player }
            guard depth < 60 else { return nil }
            for sub in view.subviews { if let found = find(sub, depth: depth + 1) { return found } }
            return nil
        }
        return find(root, depth: 0)?.player
    }

    /// The texts the player sheet shows (its accessibility static texts):
    /// the status line, the bounded-storage note, a toast.
    @MainActor
    static func playerTexts() -> [String] {
        guard let sheet = playerSheet else { return ["<no player sheet>"] }
        var texts: [String] = []
        for node in accessibilityNodes(in: sheet) where node.role == NSAccessibility.Role.staticText.rawValue {
            let text = node.value.isEmpty ? node.label : node.value
            if !text.isEmpty, !texts.contains(text) { texts.append(text) }
        }
        return texts
    }

    /// One accessibility element: role, label, value, and its press action.
    private struct AccessibilityNode {
        let role: String
        let label: String
        let value: String
        let press: () -> Bool
    }

    /// The accessibility tree under the sheet's content view (SwiftUI builds
    /// it on demand), depth-first. Read through the informal accessibility
    /// methods (SwiftUI's elements implement them, not always the protocol).
    @MainActor
    private static func accessibilityNodes(in window: NSWindow) -> [AccessibilityNode] {
        var nodes: [AccessibilityNode] = []
        var count = 0
        func visit(_ element: Any, depth: Int) {
            guard depth < 40, count < 4000, let object = element as? NSObject else { return }
            count += 1
            func string(_ name: String) -> String {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { return "" }
                return (object.perform(selector)?.takeUnretainedValue() as? String) ?? ""
            }
            let label = string("accessibilityLabel")
            nodes.append(AccessibilityNode(role: string("accessibilityRole"),
                                           label: label.isEmpty ? string("accessibilityTitle") : label,
                                           value: string("accessibilityValue"),
                                           press: {
                let selector = NSSelectorFromString("accessibilityPerformPress")
                guard object.responds(to: selector) else { return false }
                typealias Press = @convention(c) (NSObject, Selector) -> Bool
                return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
            }))
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            guard object.responds(to: childrenSelector),
                  let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [Any] else { return }
            for child in children { visit(child, depth: depth + 1) }
        }
        if let root = window.contentView { visit(root, depth: 0) }
        return nodes
    }

    @MainActor
    private static func snapshot(to url: URL, window explicitWindow: NSWindow? = nil) {
        guard let window = explicitWindow ?? mainWindow else {
            print("[MacDebug] snapshot: no window")
            return
        }
        // The window server's image has the real composited pixels (glass,
        // materials); the two in-process renders are fallbacks.
        let captures: [(String, CGImage?)] = [
            ("window", windowServerImage(of: window)),
            ("layer", layerImage(of: window)),
            ("cacheDisplay", cachedDisplayImage(of: window)),
        ]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if defaults.bool(forKey: "PTDebugSnapshotAll") {
            for (name, image) in captures {
                guard let image else { continue }
                let variant = url.deletingPathExtension().appendingPathExtension(name).appendingPathExtension("png")
                write(image, to: variant)
            }
        }
        // The first image that is not blank, else the in-process render
        // anyway (a dark, dimmed page can look flat at 32×32).
        let usable = captures.first { $0.1.map(isUsable) ?? false }
        guard let (method, image) = (usable ?? captures.first { $0.0 == "layer" && $0.1 != nil })
            .map({ ($0.0, $0.1!) }) else {
            print("[MacDebug] snapshot: every capture method failed")
            return
        }
        write(image, to: url)
        print("[MacDebug] snapshot (\(method), \(image.width)×\(image.height)) → \(url.path)")
        // A sheet is a window of its own: written beside the page.
        if let sheet = window.attachedSheet, let image = windowServerImage(of: sheet) ?? layerImage(of: sheet) {
            let sheetURL = url.deletingPathExtension().appendingPathExtension("sheet").appendingPathExtension("png")
            write(image, to: sheetURL)
            print("[MacDebug] sheet snapshot (\(image.width)×\(image.height)) → \(sheetURL.path)")
        }
    }

    private static func write(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: url)
        } catch {
            print("[MacDebug] snapshot: cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    /// CGWindowListCreateImage of the app's own window (no screen recording
    /// permission needed for one's own windows). Looked up at run time: the
    /// macOS 15+ SDKs mark it unavailable.
    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    @MainActor
    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: WindowImageFunction.self)
        let includingWindow: UInt32 = 1 << 3                     // kCGWindowListOptionIncludingWindow
        let options: UInt32 = (1 << 0) | (1 << 3)                 // BoundsIgnoreFraming | BestResolution
        return create(.null, includingWindow, UInt32(window.windowNumber), options)?.takeRetainedValue()
    }

    @MainActor
    private static func layerImage(of window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return nil }
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }

    @MainActor
    private static func cachedDisplayImage(of window: NSWindow) -> CGImage? {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// Not empty: some opaque pixels with some variation (a blank render is
    /// fully transparent or one flat color).
    private static func isUsable(_ image: CGImage) -> Bool {
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var opaque = 0
        var minLuma = 255, maxLuma = 0
        for index in 0..<(side * side) {
            let p = index * 4
            guard pixels[p + 3] > 200 else { continue }
            opaque += 1
            let luma = (Int(pixels[p]) * 3 + Int(pixels[p + 1]) * 6 + Int(pixels[p + 2])) / 10
            minLuma = min(minLuma, luma)
            maxLuma = max(maxLuma, luma)
        }
        return opaque > side * side / 2 && maxLuma - minLuma > 12
    }
}
#endif
