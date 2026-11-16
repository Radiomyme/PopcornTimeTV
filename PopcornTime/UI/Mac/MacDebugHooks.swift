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
/// - `-PTDebugSection <home|movies|shows|search|watchlist>`: the window
///   opens on that section (a `MacSection` raw value);
/// - `-PTDebugHomeFixtures <folder>`: the Home is fed from recorded answers
///   (`HomeRecordedTransport`; the repository's PopcornTimeTests/Fixtures/Home)
///   instead of the network, from an empty cache of its own, with the clock
///   of the day they were recorded: the same page at every launch.
///   `-PTDebugHomeState <skeleton|offline|error>` (with the fixtures): the
///   placeholders (no request is ever answered), the cached page with the
///   offline note, or the error page;
/// - `-PTDebugHomeShelf <shelf id>`: the Home scrolls to that shelf once it
///   is on the page; `-PTDebugHomeHeroPage <n>`: the carousel shows its n-th
///   page (from 0) and does not turn by itself;
/// - `-PTDebugOpenURL <url>`: the URL is handed to the window's link handler
///   a moment after launch, as `onOpenURL` gets it (a popcorntime:// link);
/// - `-PTDebugSettingsPane <playback|home|about>`: the Settings window
///   opens on that pane; `-PTDebugSettingsSheet <languages|shelves>`: on the
///   Home's pane, with that list in its sheet;
/// - `-PTDebugSearch <text>`: the Search section with that text in its field
///   (the live search runs as if it had been typed); `-PTDebugSearchOffline
///   YES`: every search fails as it does offline;
/// - `-PTDebugOpenMovie <IMDb id>` / `-PTDebugOpenShow <IMDb id>`: push that
///   title's page at launch (never plays anything);
/// - `-PTDebugOpenRoute <movie|show>:<IMDb id>`: the same page through a
///   `MacRoute` (the hook the Home of stage 2 uses);
/// - `-PTDebugTour <steps>`: a comma-separated script run on the window's
///   `MacNavigator` once the above are done (`runTour`): a section's name
///   selects it; `wait:<seconds>`; `scroll:<n|last>` puts the grid's n-th poster
///   at the top; `filter:<raw value>`; `genre:<raw value>`;
///   `seeall:<movies|shows>:<raw value>`
///   (« see all »: the section on that filter); `refresh`; `back`;
///   `open:<movie|show>:<IMDb id>` pushes that title's page (a `MacRoute`);
///   `fail` / `failmore` / `empty` answer the grid's next page with an
///   offline error (from an empty grid / under the posters) or an empty
///   list, and `retry` is its Try Again;
///   `togglewatchlist:<n>` / `togglewatched:<n>` toggle the n-th poster's
///   state (as its right-click menu does); `hover:<x>:<y>` moves a synthetic
///   pointer there (points from the window's top-left corner);
///   `lift:<n>` draws the n-th poster as under the pointer (an app that is
///   not in front gets no pointer events: the synthetic pointer then does
///   nothing);
///   `rightclick:<x>:<y>` opens the context menu there, logs its items and
///   cancels it a second later; `click:<x>:<y>[:2]` clicks there (`:2`: a
///   double click); `type:<text>` sets the search field;
///   `activate` / `deactivate` bring the app in front and give the front back
///   (the menus act on the focused scene, the pointer on the active app;
///   macOS only grants it to an app launched from the app in front);
///   `menus[:<title>…]` logs the main menu's items with their shortcuts and
///   whether they are enabled; `menu:<title>:<item>` picks one; `find` is
///   ⌘F's action; `focus` logs the window's first responder;
///   `snap:<name>` writes the window into `<name>.png` beside
///   `-PTDebugSnapshot`'s file. Each step logs the grids' state.
///   On the Home: `waithome[:<seconds>]` waits for its page (10 s at most);
///   `key:<left|right|up|down|return|space|esc>` sends that key to the
///   window as if typed (the page must have the keyboard), `key:<character>:cmd`
///   a ⌘ shortcut through the app's event queue and `shortcut:<menu>:<item>`
///   the one of that menu item; `press:<…>` gives
///   the same key straight to the page's rules (`HomeControls`), whoever has
///   the keyboard; `cursor:<shelf id>:<n>` puts the keyboard on the n-th card
///   of a shelf (`cursor` alone: back on the carousel); `homeshelf:<shelf
///   id>` scrolls the page to a shelf; `homehover:<hero|shelf id|shelf
///   id/n>` draws the carousel, a shelf or a card as under the pointer
///   (`homehover` alone: nothing); `homeopen:<hero|shelf id>:<n>[:play]`
///   is a click on that card (`:play`: Space on it; nothing ever starts by
///   itself in these runs, see `MacGlassDetailController.run`);
///   `homeseeall:<shelf id>` is its « See All »; `url:<link>` hands a link
///   to the window; `settings` opens the Settings window and
///   `snapsettings:<name>` writes it (and its sheet) into `<name>.png`;
///   `snapwhatsnew:<name>` writes the "What's New" window (opened by
///   `menu:<app menu>:<What's New… item>` after `activate`);
///   `sheet` logs what the sheet over the window says; `exit` ends the
///   run there (a window under a sheet does not quit with `-PTDebugQuit`);
/// - `-PTDebugScroll <hero|episodes|related|cast|info>`: scroll the open page
///   there once its sections have loaded (MacGlassDetailView);
/// - `-PTDebugExpand <summary|episode>`: then open that full-text sheet;
/// - `-PTDebugGlassFallback YES`: draw the page with the macOS 14 / 15
///   materials instead of Liquid Glass (the in-process snapshot cannot draw
///   accent-tinted glass: the scroll view holding it comes out blank);
/// - `-PTDebugAmbient YES`: open a movie page without its backdrop (the
///   blurred poster and poster card layout);
/// - `-PTDebugNoAnimation YES`: every animation of the window ends at once.
///   A window that is not shown (a locked session, a sleeping display) gets
///   no frame: an animated scroll then never moves, and the snapshot shows
///   where it started;
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
/// - the resume of a film still downloading (with BoundedStorageDebugHooks'
///   `-PTDebugPlayTorrent`; its `-PTDebugResumeAnswer <resume|start>`,
///   `-PTDebugResumeAnswerAfter <s>`, `-PTDebugResumeTrace 1` and
///   `-PTDebugRemuxOutputDir <dir>` work on the Mac as on tvOS): the loading
///   screen's resume question answers itself (`resumeQuestionShown`), and
///   with `-PTDebugBoundedSnapshots <directory>` the player's window is
///   written into `resume-question.png` when the question shows and
///   `resume-cover.png` a second after a native resume was accepted (the
///   black cover, the spinner and « Resuming at … »).
/// Any of them also skips the release notes sheet. Nothing happens without
/// these arguments.
enum MacDebugHooks {
    private static var defaults: UserDefaults { .standard }
    private static let keys = ["PTDebugSection", "PTDebugOpenMovie", "PTDebugOpenShow", "PTDebugScroll",
                               "PTDebugExpand", "PTDebugGlassFallback", "PTDebugAmbient", "PTDebugWindowSize",
                               "PTDebugSnapshot", "PTDebugQuit", "PTDebugFilter", "PTDebugQualitySheet",
                               "PTDebugTop100Offline", "PTDebugSearch", "PTDebugSearchOffline", "PTDebugOpenRoute",
                               "PTDebugTour", "PTDebugHomeFixtures", "PTDebugHomeState", "PTDebugHomeShelf",
                               "PTDebugHomeHeroPage", "PTDebugOpenURL", "PTDebugSettingsSheet", "PTDebugNoAnimation",
                               "PTDebugSettingsPane"]

    static var isActive: Bool {
        keys.contains { defaults.object(forKey: $0) != nil }
    }

    /// When the hooks were first used (the app's `init`): the tour's steps
    /// say how long after.
    private static let launchUptime = ProcessInfo.processInfo.systemUptime

    /// Called from the app's `init`: starts the tour's clock.
    static func noteLaunch() {
        _ = launchUptime
    }

    static var section: MacSection? {
        defaults.string(forKey: "PTDebugSection").flatMap { MacSection(rawValue: $0.lowercased()) }
    }

    /// `-PTDebugSearch`: the text typed in the Search field.
    static var searchQuery: String? {
        defaults.string(forKey: "PTDebugSearch")
    }

    /// `-PTDebugSearchOffline YES`: every search fails as it does offline
    /// (the Search page's error state).
    @MainActor
    static var failingSearch: MacSearchModel? {
        guard defaults.bool(forKey: "PTDebugSearchOffline") else { return nil }
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                              userInfo: [NSLocalizedDescriptionKey: URLError(.notConnectedToInternet).localizedDescription])
        return MacSearchModel(searchMovies: { _, completion in completion(nil, offline) },
                              searchShows: { _, completion in completion(nil, offline) })
    }

    /// `-PTDebugOpenRoute <movie|show>:<IMDb id>`.
    static var route: MacRoute? {
        guard let parts = defaults.string(forKey: "PTDebugOpenRoute")?.split(separator: ":").map(String.init),
              parts.count == 2 else { return nil }
        switch parts[0] {
        case "movie": return .movie(id: parts[1], title: parts[1])
        case "show": return .show(id: parts[1], title: parts[1])
        default: return nil
        }
    }

    /// `-PTDebugNoAnimation YES`.
    static var disablesAnimations: Bool {
        defaults.bool(forKey: "PTDebugNoAnimation")
    }

    /// `-PTDebugOpenURL`: a link for the window's handler.
    static var url: URL? {
        defaults.string(forKey: "PTDebugOpenURL").flatMap(URL.init(string:))
    }

    /// `-PTDebugSettingsPane <playback|home|about>`.
    static var settingsPane: String? {
        defaults.string(forKey: "PTDebugSettingsPane")?.lowercased()
    }

    /// `-PTDebugSettingsSheet <languages|shelves>`.
    static var settingsSheet: String? {
        defaults.string(forKey: "PTDebugSettingsSheet")?.lowercased()
    }

    // MARK: Home

    static var homeShelf: String? {
        defaults.string(forKey: "PTDebugHomeShelf")
    }

    static var homeHeroPage: Int? {
        defaults.object(forKey: "PTDebugHomeHeroPage") == nil ? nil : defaults.integer(forKey: "PTDebugHomeHeroPage")
    }

    /// `-PTDebugHomeFixtures`: a hub of its own, on recorded answers (as
    /// the iOS app's `IOSDebugHooks.homeState()`). Nil without the argument
    /// (the app's hub, the real hosts).
    @MainActor
    static func homeState() -> HomeState? {
        guard let folder = defaults.string(forKey: "PTDebugHomeFixtures"), !folder.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        let mode = defaults.string(forKey: "PTDebugHomeState")?.lowercased()
        let recorded = HomeRecordedTransport(directory: directory)
        recorded.mode = mode == "skeleton" ? .silent : (mode == "error" ? .down : .replay)
        // Its own cache, emptied: every launch is a first load of the
        // same answers, and the app's real cache is left alone.
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("popcornkit-home-debug", isDirectory: true)
        try? FileManager.default.removeItem(at: cache)
        // "New", "this week" and the schedules asked are counted from the
        // day the answers were recorded, not from today.
        let recordedAt = HomeRecordedTransport.recordedDate(in: directory) ?? Date()
        // The placeholders stay as long as the snapshot needs them.
        let options = HomeFeed.Options(requestDeadline: mode == "skeleton" ? 600 : 15)
        let feed = HomeFeed(store: HomeStore(directory: cache, now: { recordedAt }), transport: recorded.transport,
                            hooks: HomeLocalHooks(library: .shared), options: options, now: { recordedAt })
        feed.followChanges(of: .shared)
        let state = HomeState(feed: feed)
        print("[MacDebug] Home fed from \(folder) as of \(recordedAt)" + (mode.map { ", state \($0)" } ?? ""))
        if mode == "offline" {
            // The page is loaded and cached from the recordings, then no
            // host answers a forced refresh: the cached page, offline.
            feed.start {
                recorded.mode = .down
                feed.refresh(force: true) { print("[MacDebug] Home offline: \(state.isOffline), \(state.shelves.count) shelves") }
            }
        }
        return state
    }

    /// A card of the Home by shelf id and index ("hero": the carousel).
    @MainActor
    private static func homeCard(_ shelfID: String, _ index: Int, in navigator: MacNavigator) -> (item: HomeItem, shelfID: String)? {
        // The cards in the order the page draws them (`HomeHarmony.deduplicated`).
        let items = shelfID == HomeShelfID.hero ? navigator.home.heroItems
            : HomeHarmony.deduplicated(navigator.home.shelves).first { $0.id == shelfID }?.items ?? []
        return items.indices.contains(index) ? (items[index], shelfID) : nil
    }

    /// A key sent as a typed one, down then up: to the window for a plain
    /// key (an app that is not in front has no key window to route it to),
    /// through the app's event queue with ⌘ (`command`) — a menu shortcut,
    /// seen by the menus as the event being handled.
    @MainActor
    private static func sendKey(_ name: String, command: Bool, to window: NSWindow) -> String {
        let keys: [String: (code: UInt16, characters: String)] = [
            "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
            "return": (36, "\r"), "space": (49, " "), "esc": (53, "\u{1b}"),
        ]
        // With ⌘, any other name is the character typed with it ("r"; on
        // an AZERTY keyboard the digit keys type & é " ').
        guard let key = keys[name] ?? (command ? (code: UInt16(0), characters: name) : nil) else { return "unknown key" }
        var flags: NSEvent.ModifierFlags = (123...126).contains(key.code) ? [.numericPad, .function] : []
        if command { flags.insert(.command) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
                                               isARepeat: false, keyCode: key.code) else { return "no event" }
            if command {
                NSApp.postEvent(event, atStart: false)
            } else {
                window.sendEvent(event)
            }
        }
        return "sent (first responder: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"))"
    }

    /// `-PTDebugTour viewtree[:<x>]`: the window's views whose frame starts
    /// left of `x` (the sidebar's column), with their layers — what the
    /// in-process snapshot is given to draw there.
    @MainActor
    private static func logViewTree(of window: NSWindow, maxX: Double) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        print("[MacDebug] view tree (window appearance \(window.effectiveAppearance.name.rawValue), background \(String(describing: window.backgroundColor)), opaque \(window.isOpaque)):")
        func describe(_ layer: CALayer?) -> String {
            guard let layer else { return "no layer" }
            let background = layer.backgroundColor.flatMap { NSColor(cgColor: $0) }.map { String(describing: $0) } ?? "-"
            return "\(type(of: layer)) bg \(background) opacity \(layer.opacity) sublayers \(layer.sublayers?.count ?? 0)"
                + (layer.sublayers ?? []).prefix(6).map { " [\(type(of: $0)) \($0.compositingFilter.map { "filter \($0)" } ?? "") hidden \($0.isHidden)]" }.joined()
        }
        func visit(_ view: NSView, depth: Int) {
            let frame = view.convert(view.bounds, to: nil)
            guard depth < 30, Double(frame.minX) < maxX else { return }
            var extra = ""
            if let effect = view as? NSVisualEffectView {
                extra = " material \(effect.material.rawValue) blending \(effect.blendingMode.rawValue) state \(effect.state.rawValue)"
            }
            if let text = view as? NSTextField {
                extra += " text \"\(text.stringValue)\" color \(String(describing: text.textColor))"
            }
            print("[MacDebug]   " + String(repeating: "  ", count: depth) + "\(type(of: view)) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
                  + (view.isHidden ? " HIDDEN" : "") + " alpha \(view.alphaValue) · \(view.effectiveAppearance.name.rawValue.replacingOccurrences(of: "NSAppearanceName", with: ""))"
                  + extra + " · " + describe(view.layer))
            for sub in view.subviews { visit(sub, depth: depth + 1) }
        }
        visit(root, depth: 0)
    }

    /// The Settings window, once it is on screen.
    @MainActor
    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0 !== mainWindow && !($0 is NSPanel) && $0.contentView != nil
            && ($0.identifier?.rawValue.contains("Settings") ?? false) }
    }

    // MARK: Tour

    /// `-PTDebugTour`: the script's steps, in order, on the window's
    /// navigator — what a user does with the sidebar, the toolbar and the
    /// posters' menus, without a pointer.
    @MainActor
    static func runTour(_ navigator: MacNavigator) async {
        guard let script = defaults.string(forKey: "PTDebugTour") else { return }
        func state() -> String {
            let movies = navigator.movies, shows = navigator.shows
            return "section \(navigator.section.rawValue) · movies \(movies.items.count) (\(movies.filter.rawValue), top \(movies.scrolledID ?? "-"))"
                + " · shows \(shows.items.count) (\(shows.filter.rawValue), top \(shows.scrolledID ?? "-"))"
                + " · search \(navigator.search.movies.count)+\(navigator.search.shows.count) \(navigator.search.session.phase)"
                + " · watchlist \(navigator.library.watchlistIDs.count) · watched \(navigator.library.watchedMovieIDs.count)"
                + " · home \(navigator.home.shelves.count) shelves, hero \(navigator.home.heroItems.count)"
                + (navigator.home.isRefreshing ? ", refreshing" : "") + (navigator.home.isOffline ? ", offline" : "")
                + (navigator.home.isUnavailable ? ", unavailable" : "")
                + ", front \(navigator.homeControls.heroFront ?? "-")"
                + ", cursor \(navigator.homeControls.cursorCard.map { "\($0.shelf)/\($0.item)" } ?? "-")"
                + " · pages \(navigator.path.count)"
        }
        // The posters of the section on screen.
        func poster(_ index: Int) -> Media? {
            switch navigator.section {
            case .home: return nil
            case .movies: return navigator.movies.items.indices.contains(index) ? navigator.movies.items[index] : nil
            case .shows: return navigator.shows.items.indices.contains(index) ? navigator.shows.items[index] : nil
            case .watchlist:
                let all: [Media] = navigator.library.watchlistMovies + navigator.library.watchlistShows
                return all.indices.contains(index) ? all[index] : nil
            case .search:
                let all: [Media] = navigator.search.movies + navigator.search.shows
                return all.indices.contains(index) ? all[index] : nil
            }
        }
        for step in script.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let parts = step.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "wait":
                try? await Task.sleep(nanoseconds: UInt64(max(0, Double(argument) ?? 1) * 1_000_000_000))
            case "scroll":
                // `scroll:last`: the grid's last poster.
                switch navigator.section {
                case .movies: navigator.movies.debugScroll(toIndex: Int(argument) ?? navigator.movies.items.count - 1)
                case .shows: navigator.shows.debugScroll(toIndex: Int(argument) ?? navigator.shows.items.count - 1)
                default: break
                }
            case "filter":
                switch navigator.section {
                case .movies:
                    if let filter = MovieManager.Filters(rawValue: argument) { navigator.movies.setFilter(filter) }
                case .shows:
                    if let filter = ShowManager.Filters(rawValue: argument) { navigator.shows.setFilter(filter) }
                default: break
                }
            case "genre":
                if let genre = NetworkManager.Genres(rawValue: argument) {
                    switch navigator.section {
                    case .movies: navigator.movies.setGenre(genre)
                    case .shows: navigator.shows.setGenre(genre)
                    default: break
                    }
                }
            case "seeall":
                let raw = parts.count > 2 ? parts[2] : ""
                if argument == "movies", let filter = MovieManager.Filters(rawValue: raw) {
                    navigator.showMovies(filter: filter)
                } else if argument == "shows", let filter = ShowManager.Filters(rawValue: raw) {
                    navigator.showShows(filter: filter)
                }
            case "fail", "failmore", "empty":
                // A made-up answer: offline for `fail` (an empty grid) and
                // `failmore` (under the posters), an empty list for `empty`.
                let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                      userInfo: [NSLocalizedDescriptionKey: URLError(.notConnectedToInternet).localizedDescription])
                let fromStart = parts[0] != "failmore"
                switch navigator.section {
                case .movies: navigator.movies.debugAnswer(parts[0] == "empty" ? .success([]) : .failure(offline), fromStart: fromStart)
                case .shows: navigator.shows.debugAnswer(parts[0] == "empty" ? .success([]) : .failure(offline), fromStart: fromStart)
                default: break
                }
            case "retry":
                switch navigator.section {
                case .movies: navigator.movies.retry()
                case .shows: navigator.shows.retry()
                default: navigator.refresh()
                }
            case "open":
                // `open:<movie|show>:<IMDb id>`: that title's page, by route.
                if parts.count > 2 {
                    navigator.open(argument == "show" ? .show(id: parts[2], title: parts[2]) : .movie(id: parts[2], title: parts[2]))
                }
            case "refresh":
                navigator.refresh()
            case "back":
                navigator.goBack()
            case "togglewatchlist":
                if let media = poster(Int(argument) ?? 0) { navigator.library.toggleWatchlist(media) }
            case "togglewatched":
                if let movie = poster(Int(argument) ?? 0) as? Movie { navigator.library.toggleWatched(movie) }
            case "activate":
                // The menus act on the focused scene and the pointer on the
                // active app: for the few steps that need it.
                tourPreviousApp = NSWorkspace.shared.frontmostApplication
                NSApp.activate(ignoringOtherApps: true)
                mainWindow?.makeKeyAndOrderFront(nil)
            case "deactivate":
                // Back to the app that was in front.
                tourPreviousApp?.activate()
                tourPreviousApp = nil
            case "shortcut":
                // `shortcut:<menu>:<item>`: that item's key equivalent, typed.
                if parts.count > 2, let window = mainWindow,
                   let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == argument }),
                   let item = menu.items.first(where: { $0.title == parts[2] }), !item.keyEquivalent.isEmpty {
                    print("[MacDebug] shortcut \(argument) › \(parts[2]): \(sendKey(item.keyEquivalent, command: true, to: window))")
                } else {
                    print("[MacDebug] shortcut: no such item, or no key")
                }
            case "menus":
                logMenus(named: parts.dropFirst().filter { !$0.isEmpty })
            case "menu":
                if parts.count > 2 { print("[MacDebug] menu \(argument) › \(parts[2]): \(performMenuItem(menu: argument, item: parts[2]))") }
            case "focus":
                let responder = mainWindow?.firstResponder
                let field = (responder as? NSTextView)?.delegate
                print("[MacDebug] first responder: \(responder.map { String(describing: type(of: $0)) } ?? "none")"
                      + (field.map { " (editor of \(type(of: $0)))" } ?? "")
                      + " · key window: \(mainWindow?.isKeyWindow == true) · app active: \(NSApp.isActive)")
            case "find":
                // ⌘F's action.
                navigator.focusSearch()
            case "hover":
                if let window = mainWindow, parts.count > 2, let x = Double(argument), let y = Double(parts[2]) {
                    // Window coordinates start at the bottom-left corner.
                    MacGlassDebugPointer.send(.mouseMoved, at: NSPoint(x: x, y: Double(window.frame.height) - y), in: window)
                }
            case "lift":
                // The n-th poster drawn as under the pointer (`lift:` alone: none).
                navigator.library.debugLiftedID = Int(argument).flatMap(poster)?.id
            case "click":
                // `click:<x>:<y>[:2]`: a click there (`:2`: a double click),
                // through the app's event queue as a real one comes.
                if let window = mainWindow, parts.count > 2, let x = Double(argument), let y = Double(parts[2]) {
                    let point = NSPoint(x: x, y: Double(window.frame.height) - y)
                    let clicks = parts.count > 3 && parts[3] == "2" ? 2 : 1
                    var time = ProcessInfo.processInfo.systemUptime
                    for count in 1...clicks {
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                              clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) {
                                NSApp.postEvent(event, atStart: false)
                            }
                            time += 0.04
                        }
                    }
                }
            case "rightclick":
                if let window = mainWindow, parts.count > 2, let x = Double(argument), let y = Double(parts[2]) {
                    rightClick(at: NSPoint(x: x, y: Double(window.frame.height) - y), in: window)
                }
            case "waithome":
                // The Home's page: loaded, something on it, its refresh over.
                let limit = Double(argument) ?? 10
                let start = Date()
                while Date().timeIntervalSince(start) < limit,
                      !(navigator.home.hasLoaded && !navigator.home.isRefreshing
                        && (!navigator.home.shelves.isEmpty || navigator.home.isUnavailable)) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            case "key":
                // `key:<name>[:cmd]`.
                if let window = mainWindow {
                    let command = parts.count > 2 && parts[2] == "cmd"
                    print("[MacDebug] key \(command ? "⌘" : "")\(argument): \(sendKey(argument, command: command, to: window))")
                }
            case "press":
                let keys: [String: HomeControls.Key] = ["left": .left, "right": .right, "up": .up, "down": .down,
                                                        "return": .open, "space": .play, "esc": .cancel]
                if let key = keys[argument] {
                    let outcome = navigator.homeControls.press(key, shelves: HomeHarmony.deduplicated(navigator.home.shelves), heroItems: navigator.home.heroItems)
                    if case .pick(let pick) = outcome {
                        print("[MacDebug] press \(argument): \(pick.plays ? "play" : "open") \(pick.shelfID)/\(pick.item.id)")
                        MacHome.open(HomeSelection(item: pick.item, shelfID: pick.shelfID, intent: pick.plays ? .play : .details), in: navigator)
                    } else {
                        print("[MacDebug] press \(argument): \(outcome)")
                    }
                }
            case "cursor":
                // `cursor:<shelf id>:<n>`; `cursor` alone: back on the carousel.
                let card = parts.count > 2 ? homeCard(argument, Int(parts[2]) ?? 0, in: navigator) : nil
                navigator.homeControls.moveCursor(to: card.map { HomeCursorCard(shelf: $0.shelfID, item: $0.item.id) })
            case "homeshelf":
                navigator.homeControls.show(shelf: argument)
            case "homehover":
                // `hero`, a shelf's id, or `<shelf id>/<n>` (the n-th card).
                let target = argument.split(separator: "/").map(String.init)
                if target.count == 2, let card = homeCard(target[0], Int(target[1]) ?? 0, in: navigator) {
                    navigator.homeControls.shownAsHovered = "\(card.shelfID)/\(card.item.id)"
                } else {
                    navigator.homeControls.shownAsHovered = argument.isEmpty ? nil : argument
                }
            case "homeopen":
                if parts.count > 2, let card = homeCard(argument, Int(parts[2]) ?? 0, in: navigator) {
                    // As the card's own button: a Continue Watching card resumes.
                    let plays = (parts.count > 3 && parts[3] == "play") || card.shelfID == HomeShelfID.continueWatching
                    MacHome.open(HomeSelection(item: card.item, shelfID: card.shelfID, intent: plays ? .play : .details), in: navigator)
                }
            case "homeseeall":
                if let shelf = navigator.home.shelf(argument) { MacHome.seeAll(shelf, in: navigator) }
            case "url":
                // The whole rest of the step: a link has colons of its own.
                let text = String(step.dropFirst("url:".count))
                if let url = URL(string: text) {
                    print("[MacDebug] link \(text): \(navigator.open(url: url) ? "opened" : "refused")")
                }
            case "settings":
                navigator.openSettings()
            case "snapsettings":
                if let directory = defaults.string(forKey: "PTDebugSnapshot").map({ URL(fileURLWithPath: $0).deletingLastPathComponent() }) {
                    if let window = settingsWindow {
                        await snapshot(to: directory.appendingPathComponent(argument + ".png"), window: window)
                    } else {
                        print("[MacDebug] snapsettings: no Settings window (\(NSApp.windows.map { $0.identifier?.rawValue ?? "?" }))")
                    }
                }
            case "viewtree":
                if let window = mainWindow { logViewTree(of: window, maxX: Double(argument) ?? 260) }
            case "sheet":
                // What the sheet over the window says (its texts and buttons).
                if let sheet = mainWindow?.attachedSheet {
                    let nodes = accessibilityNodes(in: sheet)
                    var texts: [String] = []
                    for node in nodes {
                        let text = node.value.isEmpty ? node.label : node.value
                        if !text.isEmpty, !texts.contains(text) { texts.append(text) }
                    }
                    print("[MacDebug] sheet \(Int(sheet.frame.width))×\(Int(sheet.frame.height)): \(texts.prefix(24))")
                    if argument == "tree" { logViewTree(of: sheet, maxX: 10_000) }
                } else {
                    print("[MacDebug] sheet: none")
                }
            case "exit":
                // The run ends here, whatever is on screen: a window under a
                // sheet refuses to quit (`-PTDebugQuit`).
                print("[MacDebug] tour exit")
                fflush(stdout)
                exit(0)
            case "type":
                navigator.search.text = argument
            case "snap":
                if let directory = defaults.string(forKey: "PTDebugSnapshot").map({ URL(fileURLWithPath: $0).deletingLastPathComponent() }) {
                    await snapshot(to: directory.appendingPathComponent(argument + ".png"))
                }
            case "snapwhatsnew":
                // The "What's New" window (Popcorn Time › What's New…), a
                // window of its own beside the main one.
                if let directory = defaults.string(forKey: "PTDebugSnapshot").map({ URL(fileURLWithPath: $0).deletingLastPathComponent() }) {
                    if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil
                        && ($0.identifier?.rawValue.contains(MacWhatsNewWindow.id) ?? false) }) {
                        print("[MacDebug] What's New window \(Int(window.frame.width))×\(Int(window.frame.height))")
                        await snapshot(to: directory.appendingPathComponent(argument + ".png"), window: window)
                    } else {
                        print("[MacDebug] snapwhatsnew: no What's New window (\(NSApp.windows.map { $0.identifier?.rawValue ?? "?" }))")
                    }
                }
            default:
                if let section = MacSection(rawValue: parts[0]) {
                    navigator.select(section)
                } else {
                    print("[MacDebug] tour: unknown step \(step)")
                    continue
                }
            }
            print("[MacDebug] tour \(step) → \(state()) · \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - launchUptime)) s")
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
            await snapshot(to: URL(fileURLWithPath: path))
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
            await snapshot(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"), window: window)
        }
    }

    @MainActor
    private static var takenPlayerSnapshots: Set<String> = []

    /// The Mac player's resume question is on screen: its snapshot
    /// (`resume-question`), its texts in the log, and — `-PTDebugResumeAnswer
    /// resume|start` (BoundedStorageDebugHooks) — `answer` called with it
    /// `-PTDebugResumeAnswerAfter` seconds later (true: « Resume at … »).
    @MainActor
    static func resumeQuestionShown(answer: @escaping (Bool) -> Void) {
        snapshotPlayerWindow(named: "resume-question", after: 0.5)
        guard let scripted = BoundedStorageDebugHooks.resumeAnswer else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(scripted.after * 1_000_000_000))
            print("[BoundedDebug] resume question answered by the script: \(scripted.resume ? "resume" : "start"); "
                  + "player texts: \(playerTexts())")
            answer(scripted.resume)
        }
    }

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

    /// `-PTDebugTour rightclick`: a right click at `point` (window
    /// coordinates); the context menu it opens is logged, then cancelled a
    /// second later (no item is picked).
    @MainActor
    private static func rightClick(at point: NSPoint, in window: NSWindow) {
        contextMenuObserver.map(NotificationCenter.default.removeObserver)
        contextMenuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            print("[MacDebug] context menu: \(menu.items.map { $0.isSeparatorItem ? "——" : $0.title })")
            // The menu tracks in its own run loop mode.
            let timer = Timer(timeInterval: 1, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
        // No right-mouse-up: over the open menu, it would pick an item.
        MacGlassDebugPointer.send(.mouseMoved, at: point, in: window)
        MacGlassDebugPointer.send(.rightMouseDown, at: point, in: window)
        contextMenuObserver.map(NotificationCenter.default.removeObserver)
        contextMenuObserver = nil
    }

    @MainActor
    private static var contextMenuObserver: NSObjectProtocol?

    /// The app in front before `-PTDebugTour activate`.
    @MainActor
    private static var tourPreviousApp: NSRunningApplication?

    /// `-PTDebugTour menus`: the main menu's menus (those named, else all),
    /// each item with its shortcut and whether it is enabled now.
    @MainActor
    private static func logMenus(named titles: [String]) {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu, titles.isEmpty || titles.contains(menu.title) else { continue }
            menu.update()
            print("[MacDebug] menu \(menu.title):")
            for item in menu.items {
                if item.isSeparatorItem {
                    print("[MacDebug]   ——")
                    continue
                }
                var keys = ""
                if !item.keyEquivalent.isEmpty {
                    let flags = item.keyEquivalentModifierMask
                    keys = "  [" + (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                        + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
                        + (item.keyEquivalent == " " ? "Space" : item.keyEquivalent.unicodeScalars.map { $0.value < 0x7F ? String($0) : String(format: "U+%04X", $0.value) }.joined()) + "]"
                }
                let sub = item.submenu.map { " ▸ \($0.items.map { ($0.state == .on ? "✓" : "") + $0.title })" } ?? ""
                print("[MacDebug]   \(item.title)\(keys)\(item.isEnabled ? "" : "  (disabled)")\(sub)")
            }
        }
    }

    /// `-PTDebugTour menu:<title>:<item>`: picks that item, as a click does.
    @MainActor
    private static func performMenuItem(menu title: String, item itemTitle: String) -> String {
        guard let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == title }) else { return "no such menu" }
        menu.update()
        guard let index = menu.items.firstIndex(where: { $0.title == itemTitle }) else { return "no such item" }
        guard menu.items[index].isEnabled else { return "disabled" }
        menu.performActionForItem(at: index)
        return "picked"
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
    private static func snapshot(to url: URL, window explicitWindow: NSWindow? = nil) async {
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
        // (The window server's image of a window that is not shown is not
        // nil but empty: the in-process render then.)
        if let sheet = window.attachedSheet,
           let image = windowServerImage(of: sheet).flatMap({ isUsable($0) ? $0 : nil }) ?? layerImage(of: sheet) {
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
        if window.isSheet {
            // A sheet's own material is not drawn in process: its texts
            // (light, the app is dark) would be on nothing.
            context.setFillColor(CGColor(gray: 0.13, alpha: 1))
            context.fill(view.bounds)
            window.displayIfNeeded()
            CATransaction.flush()
        }
        // Liquid Glass (macOS 26+): a glass panel — the sidebar — is an
        // NSGlassEffectView whose material is drawn by a hosting view laid
        // over its content. Rendered in process that view is an opaque
        // white sheet: the sidebar was a blank white column in every
        // snapshot, on a screen where it is dark glass with its list. The
        // sheet is left out of the render; the panel then renders as
        // nothing at all (neither the glass nor the vibrant list is drawn
        // in process), and a stand-in is drawn in its place.
        let covers = glassCovers(in: view)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        covers.forEach { $0.isHidden = true }
        CATransaction.commit()
        layer.render(in: context)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        covers.forEach { $0.isHidden = false }
        CATransaction.commit()
        drawSidebarStandIn(for: view, in: context)
        return context.makeImage()
    }

    /// The lists inside the window's glass panels (the sidebar's), each
    /// with its panel.
    @MainActor
    private static func sidebarLists(in root: NSView) -> [(list: NSTableView, panel: NSView)] {
        var lists: [(NSTableView, NSView)] = []
        func visit(_ view: NSView, depth: Int, panel: NSView?) {
            guard depth < 40 else { return }
            let panel = panel ?? (String(describing: type(of: view)) == "NSGlassEffectView" ? view : nil)
            if let panel, let table = view as? NSTableView {
                lists.append((table, panel))
                return
            }
            for sub in view.subviews { visit(sub, depth: depth + 1, panel: panel) }
        }
        visit(root, depth: 0, panel: nil)
        return lists
    }

    /// Stands in for the sidebar in an in-process render, which cannot
    /// draw it (see `layerImage`): a plain dark panel, and the list's rows
    /// where the real ones are — the sections' names and symbols, the row
    /// selected in the real list highlighted. A line at the bottom says so
    /// in the image: this part is a drawing of the list's state, not its
    /// pixels.
    @MainActor
    private static func drawSidebarStandIn(for root: NSView, in context: CGContext) {
        let lists = sidebarLists(in: root)
        guard !lists.isEmpty else { return }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (table, panel) in lists {
            let frame = root.convert(panel.convert(panel.bounds, to: nil), from: nil)
            // Under what the render did draw there (the window's buttons).
            context.saveGState()
            context.setBlendMode(.destinationOver)
            context.setFillColor(CGColor(gray: 0.11, alpha: 1))
            context.fill(frame)
            context.restoreGState()
            for row in 0..<table.numberOfRows {
                let rect = root.convert(table.convert(table.rect(ofRow: row), to: nil), from: nil)
                let selected = table.selectedRowIndexes.contains(row)
                if selected {
                    context.setFillColor(CGColor(gray: 1, alpha: 0.14))
                    context.addPath(CGPath(roundedRect: rect.insetBy(dx: 10, dy: 1), cornerWidth: 8, cornerHeight: 8, transform: nil))
                    context.fillPath()
                }
                // The list is `MacSection.allCases`, in order.
                let name = MacSection.allCases.indices.contains(row) ? MacSection.allCases[row].titleKey.localized : "?"
                var textX = rect.minX + 24
                if MacSection.allCases.indices.contains(row),
                   let symbol = NSImage(systemSymbolName: MacSection.allCases[row].symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) {
                    let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
                        symbol.draw(in: bounds)
                        NSColor.white.withAlphaComponent(selected ? 1 : 0.85).set()
                        bounds.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(at: NSPoint(x: rect.minX + 24, y: rect.midY - symbol.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
                    textX += 26
                }
                let text = NSAttributedString(string: name, attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(selected ? 1 : 0.85),
                ])
                text.draw(at: NSPoint(x: textX, y: rect.midY - text.size().height / 2))
            }
            let note = NSAttributedString(string: "sidebar redrawn by the snapshot hook", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.white.withAlphaComponent(0.4),
            ])
            note.draw(at: NSPoint(x: frame.minX + 12, y: frame.minY + 10))
        }
    }

    /// The layers that draw the material of the window's glass panels
    /// (see `layerImage`): none before macOS 26.
    @MainActor
    private static func glassCovers(in root: NSView) -> [CALayer] {
        var covers: [CALayer] = []
        func visit(_ view: NSView, depth: Int) {
            guard depth < 40 else { return }
            if String(describing: type(of: view)) == "NSGlassEffectView" {
                for sub in view.subviews where String(describing: type(of: sub)).hasPrefix("_NSCoreHostingView") {
                    if let layer = sub.layer, !layer.isHidden { covers.append(layer) }
                }
            }
            for sub in view.subviews { visit(sub, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return covers
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
