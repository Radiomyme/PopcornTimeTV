// MacHomeView.swift — « Accueil », the first section of the Mac app: the
// Home screen shared with iOS (`HomeScreen`) in the window's detail column,
// with what a Mac adds to it — the wide layout at any window width, glass
// chevrons under the pointer, a keyboard cursor (← → ↑ ↓, Return, Space),
// ⌘R, and the window's navigation (`MacNavigator`): a card opens its
// title's page on the stack, « See All » pushes the shelf's own grid on
// the same stack (`MacShelfGridView`): the sidebar stays on Accueil, Back
// returns to the Home as it was.
import Foundation
import AppKit
import SwiftUI
import PopcornKit

/// The Home of the Mac app: its hub, and what a card and a shelf's « See
/// All » do in a window.
@MainActor
enum MacHome {
    /// PopcornKit's hub (`HomeState.shared`: the real hosts, the disk
    /// cache), or — DEBUG launches with `-PTDebugHomeFixtures` — one fed
    /// from recorded answers. One for the app: every window shows it.
    static let state: HomeState = {
        #if DEBUG
        if let recorded = MacDebugHooks.homeState() { return recorded }
        #endif
        return .shared
    }()

    /// A card picked — clicked, or under the keyboard when Return or Space
    /// is pressed: its title's page is pushed, and told what it was opened
    /// for (`MediaPageRequest.home`, the rule iOS follows too).
    static func open(_ selection: HomeSelection, in navigator: MacNavigator) {
        let item = selection.item
        var request = MediaPageRequest.home(item: item, shelfID: selection.shelfID, plays: selection.intent == .play)
        // A show badged "NOUVEL ÉPISODE" opens on that episode, as its
        // episode card would: its season, and Play on it — not the pilot.
        if let episode = HomeTitleFacts.shared.newEpisode(of: item), selection.intent == .details, request.season == nil {
            request.season = episode.season
            request.episode = episode.number
        }
        switch item.kind {
        case .movie: navigator.open(.movie(id: item.imdbId, title: item.title, request: request))
        case .show: navigator.open(.show(id: item.imdbId, title: item.title, request: request))
        }
        MacDoubleClick.swallowSecondClick()
    }

    /// « See All »: the shelf's own cards in its order, under its name,
    /// then its catalogue's next pages — pushed over the Home (Back returns
    /// to it). The watchlist has its own section.
    static func seeAll(_ shelf: HomeShelf, in navigator: MacNavigator) {
        if shelf.seeAll?.catalogue == .watchlist {
            navigator.select(.watchlist)
        } else {
            navigator.open(.shelf(id: shelf.id))
        }
        MacDoubleClick.swallowSecondClick()
    }

    /// Every shelf of posters has a « See All » (Nouveautés 4K, Top 100,
    /// the genres too); a shelf of episodes or resume cards only when a
    /// catalogue continues it.
    static func showsSeeAll(_ shelf: HomeShelf) -> Bool {
        switch shelf.style {
        case .posters, .ranked: return shelf.items.count > 3 || shelf.seeAll != nil
        case .landscape, .hero: return shelf.seeAll != nil
        }
    }
}

struct MacHomeView: View {
    /// The Home is the section on screen. Its page stays alive under the
    /// other sections (`MacRootView`): hidden, it shows no toolbar item,
    /// stops its carousel and takes no key.
    let isShown: Bool

    @EnvironmentObject private var navigator: MacNavigator
    /// Pages pushed over the section's page (`MacRootView`).
    @Environment(\.macStackDepth) private var depth
    /// `.inactive` while another window, or another app, is in front.
    @Environment(\.controlActiveState) private var controlActiveState
    /// The page scrolled past its carousel: the window's bar gets its
    /// title and its background back, as over a grid.
    @State private var pastHero = false

    /// On screen and not covered by a title's page.
    private var isFront: Bool { isShown && depth == 0 }

    var body: some View {
        // Read here: a value read only inside the toolbar's closure would
        // not redraw it.
        let isRefreshing = navigator.home.isRefreshing
        HomeScreen(state: navigator.home,
                   isActive: isFront,
                   // The carousel turns by itself in the window in front
                   // only: not behind the Settings, not behind another app.
                   turnsByItself: controlActiveState != .inactive,
                   initialShelf: initialShelf,
                   pinnedHeroPage: pinnedHeroPage,
                   onPastHero: { past in withAnimation(.easeInOut(duration: 0.2)) { pastHero = past } },
                   // The margins of the Mac's title pages, in a narrow window too.
                   sizeClass: .wide,
                   controls: navigator.homeControls,
                   open: { MacHome.open($0, in: navigator) },
                   seeAll: { MacHome.seeAll($0, in: navigator) },
                   showsSeeAll: MacHome.showsSeeAll)
            #if DEBUG
            // `-PTDebugGlassFallback YES`: the macOS 14 / 15 look.
            .environment(\.glassFallback, UserDefaults.standard.bool(forKey: "PTDebugGlassFallback"))
            #endif
            .toolbar {
                if isShown {
                    // On the trailing side, where the grids have theirs:
                    // without the window's title (over the carousel)
                    // nothing else pushes it there.
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible)
                    } else {
                        ToolbarItem { Spacer() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if isRefreshing {
                            // In the button's place while the lists load.
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 28)
                        } else {
                            Button {
                                navigator.refresh()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .help(Text("Refresh"))
                        }
                    }
                }
            }
            // Past the carousel the cards go under the window's bar: a
            // black shade, not the bar's material and hairline. Solid black
            // over the whole bar — at 92 % the text of the row under it
            // still showed through, a ghost under the window's buttons —
            // then a fade to nothing below it.
            .overlay(alignment: .top) {
                let bar = MacHomeView.barShade.bar, fade = MacHomeView.barShade.fade
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: bar / (bar + fade)),
                                       .init(color: .black.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: bar + fade)
                    .ignoresSafeArea(.container, edges: .top)
                    .opacity(isShown && pastHero ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .modifier(MacHomeToolbarStyle(overHero: isShown, isShown: isShown))
            // A click on the page gives it the keyboard back — from the
            // sidebar's list, say — as a click in a list does.
            .background(MacClickWatcher(isOn: isFront) { navigator.homeControls.requestKeyboard() })
            .onChange(of: isFront) { _, front in
                guard front else {
                    navigator.homeControls.pageHidden()
                    return
                }
                // Back on the Home — from a title's page, the player, another
                // section: the resume cards and the watchlist as they are now
                // (no request), and the lists that are not fresh any more.
                navigator.home.refreshLocal()
                navigator.home.start()
                // The page takes the keyboard back, unless the section was
                // reached with the arrow keys in the sidebar: they stay there.
                if !MacHomeView.cameByPlainKey { navigator.homeControls.requestKeyboard() }
            }
    }

    /// The shade under the window's bar, from the window's top: solid over
    /// the bar's height (the toolbar of a window with a sidebar, 52 points),
    /// then fading over `fade` points.
    static let barShade: (bar: CGFloat, fade: CGFloat) = (52, 40)

    /// The event being handled is a key without ⌘ (the sidebar's arrows;
    /// the Go menu's shortcuts all have ⌘).
    private static var cameByPlainKey: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return !event.modifierFlags.contains(.command)
    }

    private var initialShelf: String? {
        #if DEBUG
        return MacDebugHooks.homeShelf
        #else
        return nil
        #endif
    }

    private var pinnedHeroPage: Int? {
        #if DEBUG
        return MacDebugHooks.homeHeroPage
        #else
        return nil
        #endif
    }
}

/// The Home runs under the window's bar: no bar background (macOS 15+) —
/// over the carousel the artwork, past it a black shade (`MacHomeView`),
/// never the bar's hairline. While another section covers the Home, the
/// bar is the system's. The
/// Home never shows the window's title in its bar (as the Apple TV app):
/// the sidebar says where one is, and a title off the shelves' 52-point
/// edge sat over the scrolling cards.
private struct MacHomeToolbarStyle: ViewModifier {
    let overHero: Bool
    var isShown = true

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbarBackgroundVisibility(overHero ? .hidden : .automatic, for: .windowToolbar)
                .toolbar(removing: isShown ? .title : nil)
        } else {
            content.toolbarBackground(overHero ? .hidden : .automatic, for: .windowToolbar)
        }
    }
}

/// Tells when a click lands on the view it is the background of, without
/// taking it: a monitor on the app's events, not a gesture — a click in a
/// scroll view never reaches a gesture set around or behind its content.
private struct MacClickWatcher: NSViewRepresentable {
    let isOn: Bool
    let onClick: () -> Void

    func makeNSView(context: Context) -> WatcherView { WatcherView() }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.isOn = isOn
        view.onClick = onClick
    }

    final class WatcherView: NSView {
        var isOn = false
        var onClick: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                if let self, self.isOn, event.window === self.window,
                   self.convert(self.bounds, to: nil).contains(event.locationInWindow) {
                    // Once the click has done what it does.
                    DispatchQueue.main.async { self.onClick() }
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// Never a click's target itself.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - See All

/// A Home shelf's « See All »: its cards in the order the Home shows them,
/// under its name, as the Home's poster cards on the Home's grid — then,
/// for a shelf a catalogue continues (`HomeShelf.seeAll`), that catalogue's
/// pages, without the titles already listed. Pushed on the Home's stack.
struct MacShelfGridView: View {
    let shelfID: String

    @EnvironmentObject private var navigator: MacNavigator
    @StateObject private var more = MacShelfMore()
    @State private var width = MacPosterGrid.defaultWidth

    private var shelf: HomeShelf? {
        HomeHarmony(shelves: navigator.home.shelves, hero: []).shelves.first { $0.id == shelfID }
    }

    var body: some View {
        let shelf = self.shelf
        let own = shelf?.items ?? []
        let grid = MacPosterGrid(width: width)
        let seen = Set(own.map(\.imdbId))
        let movies = more.movies.filter { !seen.contains($0.id) }
        let shows = more.shows.filter { !seen.contains($0.id) }
        let text = HomeCardText()
        let ranked = shelf?.style == .ranked
        let hidden = HomeListBadges.hidden(shelfID: shelfID, items: own)
        ScrollView {
            MacPageTitle(title: Text(verbatim: shelf.map(text.title(of:)) ?? ""), sideInset: grid.sideInset)
            LazyVGrid(columns: grid.columns, alignment: .leading, spacing: MacPosterGrid.rowSpacing) {
                ForEach(own) { item in
                    Button {
                        MacHome.open(HomeSelection(item: item, shelfID: shelfID, intent: .details), in: navigator)
                    } label: {
                        if ranked, let rank = item.rank {
                            // A Top's ranks: the reason the shelf exists —
                            // in the top-left corner, off the title the
                            // posters print at their bottom. The card's
                            // own badge there (« NOUVEAU ») is drawn
                            // beside the rank instead of under it.
                            let editorial = text.editorialBadge(of: item).flatMap { hidden.contains($0) ? nil : $0 }
                            MacPosterCard(item: item, size: grid.cellSize)
                                .environment(\.homeHiddenBadges, editorial.map { hidden.union([$0]) } ?? hidden)
                                .overlay(alignment: .topLeading) {
                                    MacRankMark(rank: rank, badge: editorial.map { (text.cardLabel(of: $0), HomeBadgePill.tone(of: $0)) })
                                }
                        } else {
                            MacPosterCard(item: item, size: grid.cellSize)
                        }
                    }
                    .buttonStyle(HomeCardButtonStyle())
                    .contextMenu { HomeCardMenu(item: item, shelfID: shelfID, open: { MacHome.open($0, in: navigator) }) }
                    .accessibilityIdentifier("SeeAll.Card.\(item.id)")
                    .onAppear { if item.id == own.last?.id { more.loadNext(seeAll: shelf?.seeAll) } }
                }
                ForEach(movies, id: \.id) { movie in
                    MacPosterLink(item: movie, size: grid.cellSize)
                        .onAppear { if movie.id == movies.last?.id { more.loadNext(seeAll: shelf?.seeAll) } }
                }
                ForEach(shows, id: \.id) { show in
                    MacPosterLink(item: show, size: grid.cellSize)
                        .onAppear { if show.id == shows.last?.id { more.loadNext(seeAll: shelf?.seeAll) } }
                }
            }
            .padding(.horizontal, grid.sideInset)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .environment(\.homeHiddenBadges, hidden)
            if more.isLoading {
                ProgressView().controlSize(.small).padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .macGridWidth($width)
        .macPageBackground()
        .navigationTitle(Text(verbatim: shelf.map(text.title(of:)) ?? ""))
        .modifier(MacNoBarTitle())
        .accessibilityIdentifier("SeeAll.\(shelfID)")
        .onAppear {
            // A short shelf: its catalogue's first page at once.
            if let shelf, shelf.items.count < 12 { more.loadNext(seeAll: shelf.seeAll) }
        }
    }
}

/// The catalogue pages after a shelf's own cards.
@MainActor
final class MacShelfMore: ObservableObject {
    @Published private(set) var movies: [Movie] = []
    @Published private(set) var shows: [Show] = []
    @Published private(set) var isLoading = false
    private var page = 0
    private var isOver = false
    /// A streaming shelf's catalogue (TMDB), page after page.
    private var pages: TMDBStreamingClient.CataloguePages?

    func loadNext(seeAll: HomeSeeAll?) {
        guard let seeAll, !isLoading, !isOver else { return }
        let next = page + 1
        switch seeAll.catalogue {
        case .movies:
            isLoading = true
            PopcornKit.loadMovies(next, filterBy: seeAll.movieFilter ?? .trending, genre: seeAll.genreFilter) { [weak self] movies, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isLoading = false
                    guard let movies, !movies.isEmpty else { self.isOver = true; return }
                    self.page = next
                    let known = Set(self.movies.map(\.id))
                    self.movies += movies.filter { !known.contains($0.id) }
                }
            }
        case .shows:
            isLoading = true
            PopcornKit.loadShows(next, filterBy: seeAll.showFilter ?? .trending, genre: seeAll.genreFilter) { [weak self] shows, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isLoading = false
                    guard let shows, !shows.isEmpty else { self.isOver = true; return }
                    self.page = next
                    let known = Set(self.shows.map(\.id))
                    self.shows += shows.filter { !known.contains($0.id) }
                }
            }
        case .watchlist:
            isOver = true
        case .streaming:
            if pages == nil { pages = seeAll.streamingPages() }
            guard let pages else { isOver = true; return }
            isLoading = true
            pages.load { [weak self] items in
                guard let self else { return }
                self.isLoading = false
                guard let items, !items.isEmpty else { self.isOver = pages.isOver || items == nil; return }
                self.page = next
                let media = items.compactMap(\.media)
                let movies = Set(self.movies.map(\.id)), shows = Set(self.shows.map(\.id))
                self.movies += media.compactMap { $0 as? Movie }.filter { !movies.contains($0.id) }
                self.shows += media.compactMap { $0 as? Show }.filter { !shows.contains($0.id) }
            }
        }
    }
}

// MARK: - Double click

/// A double click on a card opens its page once. The first click has
/// already pushed the page (a single click opens, as on the grids); the
/// second one lands on whatever the new page has under the pointer — its
/// Play button, on a bad day. It is swallowed here.
@MainActor
enum MacDoubleClick {
    private static var monitor: Any?

    /// Call right after a click changed the page: the clicks that complete
    /// a double click (same place, within the system's interval) are
    /// dropped. Nothing happens when the page was changed by a key.
    static func swallowSecondClick() {
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown else { return }
        disarm()
        let deadline = event.timestamp + NSEvent.doubleClickInterval
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { next in
            guard next.timestamp <= deadline, next.clickCount >= 2 else {
                disarm()
                return next
            }
            if next.type == .leftMouseUp { disarm() }
            #if DEBUG
            if MacDebugHooks.isActive { print("[MacHome] debug: the second click of a double click is dropped (\(next.type == .leftMouseUp ? "up" : "down"))") }
            #endif
            return nil
        }
        // Nothing clicked again: the watch ends with the interval.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
            if ProcessInfo.processInfo.systemUptime > deadline { disarm() }
        }
    }

    private static func disarm() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - A page opened for more than itself

extension MacGlassDetailController {
    /// What the page was opened for besides showing itself (a Home card
    /// that plays, a popcorntime:// link), once the title is on the page:
    /// - a season: the episode list opens on it, when the show has it;
    /// - `autoPlay`: what the page's Play button does, on the same path
    ///   and behind the same choices (the automatic quality or the picker)
    ///   — or, with a season and an episode, what a click on that
    ///   episode's row does; nothing if the show has no such episode.
    ///
    /// A link (`MediaPageRequest.fromLink`) never picks a release by
    /// itself: the quality picker comes up whatever the setting. Nor does a
    /// verification launch (DEBUG, `-PTDebug…`): nothing plays unless a
    /// release is picked there.
    func run(_ request: MediaPageRequest) {
        let loaded: GlassDetailModel? = model
        guard let model = loaded else { return }
        if let season = request.season, model.seasons.contains(season), model.selectedSeason != season {
            model.selectedSeason = season
            actions.selectSeason(season)
        }
        guard request.autoPlay else { return }
        var alwaysAsk = request.fromLink
        #if DEBUG
        if MacDebugHooks.isActive {
            alwaysAsk = true
            print("[MacHome] debug: play asked of \(media.id) — the quality picker, nothing starts by itself")
        }
        #endif
        if let season = request.season, let episode = request.episode {
            guard let id = model.episodes.first(where: { $0.season == season && $0.number == episode })?.id else { return }
            playEpisode(id, alwaysAsk: alwaysAsk)
        } else {
            play(alwaysAsk: alwaysAsk)
        }
    }
}
