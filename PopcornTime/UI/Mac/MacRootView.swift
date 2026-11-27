import Foundation
import AppKit
import SwiftUI
import PopcornKit

/// NavigationSplitView shell: sidebar → the section's page → detail pages
/// pushed on a stack, so posters behave like links (same flow as the iOS
/// app). The detail is the Liquid Glass page (MacGlassDetailScreen), as on
/// tvOS.
///
/// The window's state lives in `MacNavigator` (sections, pushed pages, the
/// grids' and the search's models, the library state): the pages below
/// are only views of it, so a section left and selected again is exactly
/// as it was. Sections are `MacSection`, « Accueil » (`MacHomeView`)
/// first; the pages that can be pushed are `Movie`, `Show` and `MacRoute`
/// values. popcorntime:// links arrive here (`onOpenURL`) and are shown by
/// the navigator.
struct MacRootView: View {
    @StateObject private var navigator = MacNavigator()
    /// `.key` while this window has the keyboard (`MacFrontNavigator`).
    @Environment(\.controlActiveState) private var controlActiveState
    /// Opens the Settings window (a popcorntime://tab/settings link).
    @Environment(\.openSettings) private var openSettings
    /// Release notes, shown once per version (not on a fresh install, not
    /// over a launch by link).
    @State private var showWhatsNew = false
    @State private var whatsNewCheck = WhatsNewLaunchCheck()
    /// The profile picked in the Switch Profile… sheet.
    @State private var profilePicked: String?
    /// « Vos langues », once per profile, when no other sheet is up
    /// (`LanguagesLaunchQueue`); the profile it was asked for.
    @State private var languagesQueue = LanguagesLaunchQueue()
    @State private var languagesProfile: String?
    #if DEBUG
    /// `-PTDebugPlayTorrent` (BoundedStorageDebugHooks): the player sheet.
    @State private var debugPlayback: MacPendingPlayback?
    #endif

    var body: some View {
        // Read here, so that the destinations below get the current depth
        // (a value read only inside their closures can be stale).
        let depth = navigator.path.count
        NavigationSplitView {
            List(MacSection.allCases, selection: $navigator.section) { item in
                Label { item.title } icon: { Image(systemName: item.symbol) }
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            NavigationStack(path: $navigator.path) {
                page(sectionPage, depth: depth)
                    .navigationDestination(for: Movie.self) {
                        page(MacGlassDetailScreen(media: $0), depth: depth)
                    }
                    .navigationDestination(for: Show.self) {
                        page(MacGlassDetailScreen(media: $0), depth: depth)
                    }
                    // Pages named by value (`MacRoute`: the Home's cards,
                    // the links), pushed with `navigator.open(_:)` or a
                    // `NavigationLink(value:)`.
                    .navigationDestination(for: MacRoute.self) {
                        page(destination(for: $0), depth: depth)
                    }
            }
            // The detail column is black before any page is in it, as the
            // pages are: never the window's grey.
            .background(HomePalette.background.ignoresSafeArea())
        }
        .environmentObject(navigator)
        .environmentObject(navigator.library)
        // The Go menu acts on the window in front (MacCommands): the
        // focused scene's navigator, else the last window that had the
        // keyboard.
        .focusedSceneObject(navigator)
        .onAppear {
            MacFrontNavigator.shared.windowAppeared(navigator)
            navigator.openSettings = { openSettings() }
        }
        .onDisappear { MacFrontNavigator.shared.windowClosed(navigator) }
        // popcorntime:// links (`DeepLink`): a title's page, a section, a
        // search. Trakt's sign-in redirect has the same scheme and is not
        // one of them (`navigator.open(url:)` is false for it).
        .onOpenURL { url in
            // A link that launched the app: no release notes over its page
            // (they show at the next normal launch).
            if whatsNewCheck.linkOpened() { showWhatsNew = false }
            // Nor « Vos langues »: closed unanswered, asked again next launch.
            if languagesQueue.linkOpened(), let profile = languagesProfile {
                LanguagesScreenGate.didCloseUnanswered(profileID: profile)
                languagesProfile = nil
            }
            if navigator.open(url: url) { return }
            // popcorntime://trakt?code=…&state=…, from the browser.
            if url.scheme == "popcorntime", url.host == "trakt" {
                TraktManager.shared.authenticate(url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NotificationCenter.default.post(name: .macTraktDidAuthenticate, object: nil)
                }
            }
        }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { MacFrontNavigator.shared.windowBecameKey(navigator) }
        }
        // Back on the section's page: Trakt's lists are asked again (the
        // local changes already came through `.libraryDidChange`).
        .onChange(of: depth) { _, depth in
            if depth == 0 { navigator.library.reload() }
        }
        .task {
            // A link that came while « Who's Watching? » asked: this window
            // is the first to show the content, it opens it — no release
            // notes over its page, as for a launch by link.
            if let url = ProfileLaunchQuestion.shared.takeHeldLink() {
                _ = whatsNewCheck.linkOpened()
                _ = languagesQueue.linkOpened()
                navigator.open(url: url)
            }
            #if DEBUG
            if ProfilesDebugScreen.take(["sheet"]) != nil {
                try? await Task.sleep(for: .seconds(1))
                navigator.showsProfilePicker = true
            }
            // Verification runs (-PTDebug… launch arguments): no release
            // notes over the page, and the requested section / page.
            if MacDebugHooks.isActive || BoundedStorageDebugHooks.isActive {
                // « Vos langues » only with `-PTDebugLanguagesScreen YES`.
                checkLanguages()
                await runDebugHooks()
                return
            }
            #endif
            // A moment for the link of a launch by link (`onOpenURL`) to
            // arrive first; if it comes after, it closes the notes.
            try? await Task.sleep(for: .milliseconds(300))
            showWhatsNew = whatsNewCheck.check(isFreshInstall: WhatsNewGate.looksLikeFreshInstall())
            // Then « Vos langues », once the notes have gone.
            checkLanguages()
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView { showWhatsNew = false }
        }
        // « Vos langues » waits for the other sheets of the window.
        .onChange(of: showWhatsNew) { _, _ in presentLanguagesIfDue() }
        .onChange(of: navigator.showsProfilePicker) { _, _ in presentLanguagesIfDue() }
        .sheet(isPresented: Binding(get: { languagesQueue.isPresented }, set: { shown in
            if !shown { languagesQueue.finished() }
        }), onDismiss: {
            languagesQueue.finished()
            languagesProfile = nil
        }) {
            MacLanguagesLaunchSheet(profileID: languagesProfile ?? ProfileManager.shared.activeID) {
                languagesQueue.finished()
            }
        }
        // Popcorn Time › Switch Profile… (`MacProfileCommands`). Another
        // profile is made active once the sheet has gone: the window is
        // then made again for it (`ProfileGate`).
        .sheet(isPresented: $navigator.showsProfilePicker, onDismiss: {
            // Last: a switch made in the sheet (the profile in use deleted)
            // waits for it to go, as the pick does (`ProfileGate`).
            defer { ProfileLaunchQuestion.shared.pickerClosed() }
            guard let id = profilePicked else { return }
            profilePicked = nil
            if id != ProfileManager.shared.activeID { ProfileManager.shared.activate(id) }
        }) {
            MacProfilePickerSheet { picked in
                profilePicked = picked
                navigator.showsProfilePicker = false
            }
            .onAppear { ProfileLaunchQuestion.shared.pickerOpened() }
        }
        #if DEBUG
        .sheet(item: $debugPlayback) { item in
            MacPlayerView(playback: item)
                .frame(minWidth: 1024, minHeight: 576)
        }
        // `-PTDebugNoAnimation YES`: a window nobody sees gets no frame,
        // and its animations would never end.
        .transaction { transaction in
            if MacDebugHooks.disablesAnimations {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        #endif
    }

    /// The launch check of « Vos langues » (once per window; the gate lets
    /// one window of the process show it), then shown if nothing else is.
    private func checkLanguages() {
        #if DEBUG
        let harness = MacDebugHooks.isActive || BoundedStorageDebugHooks.isActive
        #else
        let harness = false
        #endif
        let profile = ProfileManager.shared.activeID
        if languagesQueue.check(profileID: profile, harness: harness) { languagesProfile = profile }
        presentLanguagesIfDue()
    }

    /// Shows « Vos langues » when it is due and no other sheet is up; a
    /// sheet that has just gone gets a moment to leave first.
    private func presentLanguagesIfDue() {
        guard languagesQueue.pending else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            _ = languagesQueue.update(blocked: isAnotherSheetUp)
        }
    }

    /// The window's other sheets: the release notes, Switch Profile…, the
    /// debug player.
    private var isAnotherSheetUp: Bool {
        var up = showWhatsNew || navigator.showsProfilePicker
        #if DEBUG
        up = up || debugPlayback != nil
        #endif
        return up
    }

    /// The root of the detail stack: the section's page — over the Home,
    /// which stays alive once it has been shown. A grid comes back as it
    /// was because its model outlives it (`MacNavigator`); the Home's page
    /// state is the views' own (where the page and each shelf are scrolled
    /// to, the carousel's page, the artwork on screen), so the page itself
    /// is kept, hidden: not drawn, not clickable, out of the keyboard loop
    /// and of VoiceOver, its carousel stopped (`MacHomeView.isShown`).
    private var sectionPage: some View {
        let showsHome = navigator.section == .home
        return ZStack {
            if navigator.keepsHome {
                MacHomeView(isShown: showsHome)
                    .opacity(showsHome ? 1 : 0)
                    .allowsHitTesting(showsHome)
                    .disabled(!showsHome)
                    .accessibilityHidden(!showsHome)
            }
            if !showsHome { sectionRoot(navigator.section) }
        }
        // Black from the window's first frame, under every section: no
        // grey flash before the Home's page (or its placeholders) arrives.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HomePalette.background.ignoresSafeArea())
        // The window's title is the section's: the Home sets none of its
        // own (hidden, it would still be its page's), the other pages set
        // this same one.
        .navigationTitle(navigator.section.title)
    }

    /// The page of a sidebar section other than the Home.
    @ViewBuilder
    private func sectionRoot(_ section: MacSection) -> some View {
        switch section {
        case .home:
            // Drawn by `sectionPage`, under the others.
            EmptyView()
        case .movies:
            MacCatalogGridView(model: navigator.movies, title: section.title, systemImage: "film")
        case .shows:
            MacCatalogGridView(model: navigator.shows, title: section.title, systemImage: "tv")
        case .watchlist:
            MacWatchlistView()
        case .search:
            MacSearchView(model: navigator.search)
        }
    }

    /// The page a `MacRoute` names.
    @ViewBuilder
    private func destination(for route: MacRoute) -> some View {
        switch route {
        // A placeholder with the IMDb id: the page loads the real title,
        // then does what it was opened for (`MediaPageRequest`).
        case .movie(let id, let title, let request):
            MacGlassDetailScreen(media: Movie(title: title.isEmpty ? id : title, id: id), request: request)
        case .show(let id, let title, let request):
            MacGlassDetailScreen(media: Show(title: title.isEmpty ? id : title, id: id), request: request)
        case .shelf(let id):
            MacShelfGridView(shelfID: id)
        }
    }

    /// What every page of the stack gets. A page covered by a pushed one
    /// gets no onDisappear, nor onAppear when it is on top again (Back) —
    /// the section's page neither when the stack is popped to it: they
    /// follow the stack's depth instead. Set on each destination: a value
    /// set around the NavigationStack (or on its root) does not reach the
    /// pushed pages — the window's objects are passed the same way.
    private func page<Content: View>(_ content: Content, depth: Int) -> some View {
        content
            .environment(\.macStackDepth, depth)
            .environmentObject(navigator)
            .environmentObject(navigator.library)
    }

    #if DEBUG
    /// `-PTDebugSection`, `-PTDebugSearch`, then `-PTDebugOpenMovie` /
    /// `-PTDebugOpenShow` / `-PTDebugOpenRoute` (pushed once the section
    /// change has emptied the stack; never plays), `-PTDebugOpenURL` (a
    /// link, as `onOpenURL` gets it), `-PTDebugTour`, then the window size
    /// and snapshot hooks (MacDebugHooks).
    @MainActor
    private func runDebugHooks() async {
        await MacDebugHooks.prepareWindow()
        // `-PTDebugPlayTorrent <file>` (BoundedStorageDebugHooks): the
        // player on a local .torrent, as a placeholder movie.
        // `-PTDebugPlayEpisode S01E01` (UpNextDebugHooks): an episode of the
        // made-up show instead, for episode chaining.
        if let episode = MacUpNextDebug.playback {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            debugPlayback = episode
        } else if let file = BoundedStorageDebugHooks.torrentFile {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            print("[BoundedDebug] playing \(file)")
            debugPlayback = MacPendingPlayback(torrent: Torrent(url: file, quality: "1080p"),
                                               media: Movie(title: "Bounded storage test", id: "tt0000000"),
                                               title: "Bounded storage test")
        }
        if let requested = MacDebugHooks.section { navigator.select(requested) }
        if let query = MacDebugHooks.searchQuery {
            navigator.focusSearch()
            navigator.search.text = query
        }
        if let media = MacDebugHooks.media {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let movie = media as? Movie {
                navigator.open(movie)
            } else if let show = media as? Show {
                navigator.open(show)
            }
        }
        if let route = MacDebugHooks.route {
            try? await Task.sleep(nanoseconds: 600_000_000)
            navigator.open(route)
        }
        if let url = MacDebugHooks.url {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            print("[MacDebug] link \(url.absoluteString): \(navigator.open(url: url) ? "opened" : "refused")")
        }
        await MacDebugHooks.runTour(navigator)
        MacDebugHooks.scheduleSnapshot()
    }
    #endif
}

// MARK: - The window

/// The AppKit window the main scene's content is drawn in, as soon as it has
/// one (put by `MacMainWindowScene`, around « Who's Watching? » and the root
/// view alike).
struct MacWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> ReaderView { ReaderView() }
    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MacWindowReader.prepare(window)
        }

        /// Never a click's target.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// The window is black under everything (the pages are): not the
    /// system's dark grey, in a first frame or round the sidebar. It is not
    /// restorable on macOS 14 (macOS 15+: the scene's
    /// `restorationBehavior(.disabled)`), and the safety net knows it is one
    /// of the app's main windows (`MacWindowNet`).
    @MainActor
    static func prepare(_ window: NSWindow) {
        window.backgroundColor = .black
        if #unavailable(macOS 15.0) { window.isRestorable = false }
        MacWindowNet.register(window)
        #if DEBUG
        MacFirstPaintProbe.start(window)
        #endif
    }
}

#if DEBUG
/// `-PTDebugFirstPaint <directory>` (with a MacDebugHooks argument, so that
/// the run is a verification run): the window as the window server has it
/// — the pixels on screen — from the moment the root view is put in it, at
/// 0, 50, 100, 200, 400 and 800 ms, into `<directory>/fp-<ms>.png`. Earlier
/// than the snapshot hooks, which start once the window's task runs.
@MainActor
enum MacFirstPaintProbe {
    private static var started = false

    static func start(_ window: NSWindow) {
        guard MacDebugHooks.isActive, !started,
              let directory = UserDefaults.standard.string(forKey: "PTDebugFirstPaint") else { return }
        started = true
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launch = processStart ?? Date()
        print("[FirstPaint] window #\(window.windowNumber) put in at \(String(format: "%.3f", Date().timeIntervalSince(launch))) s after the launch")
        for ms in [0, 50, 100, 200, 400, 800] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                let url = folder.appendingPathComponent("fp-\(ms).png")
                guard let image = windowServerImage(of: window), image.width > 1 else {
                    print("[FirstPaint] \(ms) ms: no image from the window server (on screen: \(window.isVisible))")
                    return
                }
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("[FirstPaint] \(ms) ms (\(String(format: "%.3f", Date().timeIntervalSince(launch))) s after the launch): \(image.width)×\(image.height) → \(url.lastPathComponent)")
            }
        }
    }

    /// When this process started (the kernel's record of it).
    private static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// CGWindowListCreateImage of the app's own window, looked up at run
    /// time (the macOS 15+ SDKs mark it unavailable), as MacDebugHooks does.
    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func windowServerImage(of window: NSWindow) -> CGImage? {
        guard window.windowNumber > 0, let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: WindowImageFunction.self)
        return create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }
}
#endif

// MARK: - Stack depth

private struct MacStackDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// How many pages are pushed over the section's page (0 = it is on
    /// top). In a NavigationSplitView's NavigationStack (seen on macOS
    /// 27), pushing a page over another does not call the covered page's
    /// onDisappear, and popping back does not call its onAppear (nor the
    /// section page's, popped back to it): a view that must know whether
    /// it is on top compares this with its own depth. MacRootView sets it
    /// on the section's page and on each pushed page.
    var macStackDepth: Int {
        get { self[MacStackDepthKey.self] }
        set { self[MacStackDepthKey.self] = newValue }
    }
}
