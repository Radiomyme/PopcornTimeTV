// HomeScreen.swift — the "Accueil" screen shared by iOS and macOS: the
// carousel, then the hub's shelves (`HomeState`, PopcornKit), with their
// placeholders, the offline note and the error page.
//
// The screen knows nothing of the navigation that hosts it: a card picked
// is handed to `open`, a shelf's "See All" to `seeAll`, and each platform
// shows its own pages. Sizes follow the space given (`HomeLayout`).
//
// With a TMDB key the page has a « Services » row (`HomeServiceTile`): a
// card of it is never handed to `open` — it filters the page through the
// screen's own hub (`HomeState.pick(service:)`), and the filtered page's
// states are drawn here (`HomeServicePage`, `HomeServiceState`).
//
// On a Mac the window hands it its `HomeControls`: the page then takes the
// keyboard — ← → turn the carousel, ↓ goes down to the shelves, the arrows
// walk the cards, Return opens the card under the keyboard (or the
// pointer), Space plays the keyboard's card, Escape lets go — and its carousel and shelves
// show glass chevrons under the pointer.
//
//     HomeScreen(state: .shared, open: { selection in … }, seeAll: { shelf in … })
import Foundation
import SwiftUI
import PopcornKit

struct HomeScreen: View {
    let state: HomeState
    /// False while a page covers the Home or another tab shows: the
    /// carousel stops turning. (iOS tells by itself: the screen disappears.
    /// A Mac navigation stack does not say when its root is covered.)
    var isActive = true
    /// False where the carousel must wait although the Home is in front:
    /// a Mac window that is not the active one.
    var turnsByItself = true
    /// A shelf to scroll to once it is on the page (a link, a verification
    /// launch).
    var initialShelf: String? = nil
    /// The carousel's page shown first, which then stays (verification).
    var pinnedHeroPage: Int? = nil
    /// The page scrolled past its carousel (or back): the host's top bar
    /// gets its title and its background then.
    var onPastHero: (Bool) -> Void = { _ in }
    /// How dark the host's top shade is as the page scrolls (iOS): set
    /// here, read only by the shade, so a scroll never redraws the page.
    var scrollShade: HomeScrollShade? = nil
    /// The layout whatever the width; nil: by the width (`HomeLayout`). The
    /// Mac keeps the wide one — the margins of its title pages — in a
    /// narrow window too.
    var sizeClass: HomeLayout.SizeClass? = nil
    /// The keyboard's cursor and the pointer (the Mac's `HomeControls`,
    /// owned by its window); nil: none, and the page takes no key.
    var controls: HomeControls? = nil
    let open: (HomeSelection) -> Void
    let seeAll: (HomeShelf) -> Void
    /// Which shelves have a "See All": by default the ones a catalogue grid
    /// continues (`HomeShelf.seeAll`). iOS lists any shelf's own cards.
    var showsSeeAll: (HomeShelf) -> Bool = { $0.seeAll != nil }

    @State private var memory = HomeScrollMemory()
    @State private var libraryVersion = 0
    @State private var isShown = false
    @State private var hasAppeared = false
    @State private var didScrollToShelf = false
    /// The placeholders of a first load (`HomeFirstPaint`).
    @State private var paint = Paint.undecided
    /// A first load waited as long as it may: what it has is shown, and
    /// stays, until that refresh is over.
    @State private var patienceSpent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// The artwork of the shelf below the last one drawn, fetched ahead.
    @State private var prefetcher = ArtworkPrefetcher()

    private enum Paint {
        /// Nothing known yet: the disk has not been read.
        case undecided
        /// A first load whose top of the page is not whole: placeholders.
        case waiting
        /// The page shows what the hub has.
        case shown
    }

    private let text = HomeCardText()

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            let layout = HomeLayout(width: proxy.size.width, height: proxy.size.height + topInset, sizeClass: sizeClass)
            ScrollViewReader { reader in
                ScrollView {
                    page(layout: layout, topInset: topInset)
                }
                .modifier(HomeShadeLevel(shade: scrollShade, hasHero: showsHero))
                .modifier(HomePastHero(threshold: layout.heroHeight - topInset - 12, hasHero: showsHero) { past in
                    // Past its carousel the page's keys are its shelves' only.
                    controls?.isPastHero = past
                    onPastHero(past)
                })
                // The artwork runs under the top bar, up to the screen's edge.
                .ignoresSafeArea(.container, edges: .top)
                .refreshable { await state.refresh(force: true) }
                .onChange(of: state.shelves.map(\.id), initial: true) { _, ids in
                    guard let initialShelf, !didScrollToShelf, ids.contains(initialShelf) else { return }
                    didScrollToShelf = true
                    // After this update: the row has to be in the page first.
                    DispatchQueue.main.async {
                        reader.scrollTo(initialShelf, anchor: UnitPoint(x: 0.5, y: 0.16))
                    }
                }
                .onChange(of: controls?.shelfRequest) { _, request in
                    guard let request, state.shelves.contains(where: { $0.id == request.shelf }) else { return }
                    scroll(reader, to: request.shelf, anchor: UnitPoint(x: 0.5, y: 0.16))
                }
                // The keyboard went to another shelf, or back to the
                // carousel: the page follows it.
                .onChange(of: controls?.cursorCard) { old, card in
                    // The keyboard's card: its page is asked ahead, as the
                    // pointer's is (`DetailStore.prewarm`). Off its card,
                    // the warm-up goes back to the card under the pointer.
                    DetailStore.shared.prewarm(controls?.warmCard.flatMap(item(at:)))
                    guard old?.shelf != card?.shelf else { return }
                    if let card {
                        scroll(reader, to: card.shelf, anchor: .center)
                    } else {
                        scroll(reader, to: HomeScreen.topID, anchor: .top)
                    }
                }
            }
        }
        .background(HomePalette.background.ignoresSafeArea())
        .environment(\.homeControls, controls)
        .modifier(HomeKeyboard(controls: controls, isOn: isActive, press: press))
        .onChange(of: state.shelves) { _, _ in controls?.shelvesChanged(shownShelves) }
        .environment(\.homeLibraryVersion, libraryVersion)
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in libraryVersion &+= 1 }
        .onChange(of: PaintKey(loaded: state.hasLoaded, shelves: state.shelves.map(\.id), hasHero: !state.heroItems.isEmpty,
                               isRefreshing: state.isRefreshing), initial: true) { _, _ in settle() }
        .task(id: paint) {
            // A host that hangs does not hold the page.
            guard paint == .waiting else { return }
            try? await Task.sleep(for: .seconds(HomeFirstPaint.patience))
            guard !Task.isCancelled, paint == .waiting else { return }
            patienceSpent = true
            withAnimation(.easeOut(duration: 0.3)) { paint = .shown }
        }
        // Disk first, then what is not fresh any more; cheap when called again.
        .task { state.start() }
        .onAppear {
            isShown = true
            // Back on the Home (from a page, the player, another tab): the
            // resume cards and the watchlist as they are now, no request.
            if hasAppeared { state.refreshLocal() }
            hasAppeared = true
        }
        .onDisappear {
            isShown = false
            prefetcher.cancel()
        }
        // A container: an identifier on a plain view would be given to
        // every element inside that has none.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Home.Screen")
    }

    /// The card under the keyboard, as the hub has it now.
    private func item(at card: HomeCursorCard) -> HomeItem? {
        state.shelves.first { $0.id == card.shelf }?.items.first { $0.id == card.item }
    }

    /// A shelf came on the page: the first cards of the one below it are
    /// fetched at the size they will be drawn (PopcornKit's
    /// `ArtworkPrefetcher`), so they show at once when scrolled to.
    private func prefetchShelf(after shelf: HomeShelf, layout: HomeLayout) {
        guard let index = state.shelves.firstIndex(where: { $0.id == shelf.id }),
              state.shelves.indices.contains(index + 1) else { return }
        let next = state.shelves[index + 1]
        let items = next.items.prefix(8)
        switch next.style {
        case .landscape:
            prefetcher.prefetch(urls: items.compactMap { $0.landscapeURLs.first },
                                width: (layout.landscapeWidth * displayScale).rounded(.up))
        case .ranked:
            prefetcher.prefetch(urls: items.compactMap(\.posterURL),
                                width: (layout.rankedPosterWidth * displayScale).rounded(.up))
        case .posters, .hero:
            prefetcher.prefetch(urls: items.compactMap(\.posterURL),
                                width: (layout.posterWidth * displayScale).rounded(.up))
        }
    }

    /// The id of the page's first block (the carousel, or the space kept
    /// for the top bar): where the page scrolls back to.
    private static let topID = "Home.Top"

    /// Scrolls the page to one of its blocks, eased (at once with Reduce
    /// Motion). After the update that asked for it: asked during it, the
    /// scroll view does not move.
    private func scroll(_ reader: ScrollViewProxy, to id: String, anchor: UnitPoint) {
        let animation: Animation? = reduceMotion || controls?.scrollsAnimated == false ? nil : .easeInOut(duration: 0.3)
        DispatchQueue.main.async {
            withAnimation(animation) { reader.scrollTo(id, anchor: anchor) }
        }
    }

    /// A key of the page (`HomeControls`): true when it was the page's.
    private func press(_ key: HomeControls.Key) -> Bool {
        guard let controls, isActive, !isLoading else { return false }
        switch controls.press(key, shelves: shownShelves, heroItems: state.heroItems, leading: { memory.positions[$0] }) {
        case .ignored:
            return false
        case .handled:
            return true
        case .pick(let pick):
            choose(HomeSelection(item: pick.item, shelfID: pick.shelfID, intent: pick.plays ? .play : .details))
            return true
        }
    }

    /// A card picked (a tap, a click, Return or Space): a service card
    /// filters the page through its hub; any other is the host's to open.
    private func choose(_ selection: HomeSelection) {
        if state.pick(service: selection.item) { return }
        open(selection)
    }

    /// The page filtered on a service, and what it shows (nothing more
    /// than the usual page without one). TMDB's client is asked about the
    /// key only when a picked service's lists failed: the usual page never
    /// touches it.
    private var servicePage: HomeServicePage {
        let failed = state.isUnavailable && HomeServiceCard.picked(in: state.shelves) != nil
        return HomeServicePage(shelves: state.shelves, isRefreshing: state.isRefreshing, isUnavailable: state.isUnavailable,
                               isKeyRefused: failed && TMDBStreamingClient.shared.isKeyRefused)
    }

    /// A shelf's « See All »: never the « Services » row's (its cards are
    /// not titles).
    private func seeAllAction(for shelf: HomeShelf) -> ((HomeShelf) -> Void)? {
        shelf.id != HomeShelfID.services && showsSeeAll(shelf) ? seeAll : nil
    }

    /// The shelves as the page draws them (`HomeHarmony.deduplicated`):
    /// what the keyboard walks.
    private var shownShelves: [HomeShelf] { HomeHarmony.deduplicated(state.shelves) }

    private var isEmpty: Bool { state.shelves.isEmpty && state.heroItems.isEmpty }
    /// Something besides the « Services » row, which is made of the
    /// settings alone: a usual page that reached no host and has nothing
    /// cached says so, rather than show the row by itself.
    private var hasTitles: Bool { !state.heroItems.isEmpty || state.shelves.contains { $0.id != HomeShelfID.services } }
    /// Nothing to show yet: the disk has not been read, or a first load is
    /// on its way — also past its patience while it has brought nothing
    /// (hosts that hang): an empty page is only said empty, or failed, once
    /// the refresh is over.
    private var isLoading: Bool { paint != .shown || (isEmpty && state.isRefreshing) }
    private var showsHero: Bool { isLoading || !state.heroItems.isEmpty }

    private struct PaintKey: Equatable {
        let loaded: Bool
        let shelves: [String]
        let hasHero: Bool
        let isRefreshing: Bool
    }

    /// Placeholders or content (`HomeFirstPaint`): the cache's page shows at
    /// once; a first load — and a Retry from the error page — shows when
    /// the top of the page is whole, the refresh is over, or its patience
    /// has run out.
    private func settle() {
        guard state.hasLoaded else { return }
        if !state.isRefreshing { patienceSpent = false }
        let shelves = state.shelves.map(\.id), hasHero = !state.heroItems.isEmpty
        let cold = HomeFirstPaint.isCold(shelves: shelves, hasHero: hasHero)
        let ready = HomeFirstPaint.isReady(shelves: shelves, hasHero: hasHero, isRefreshing: state.isRefreshing,
                                           hidden: HomeSettings().hiddenShelves)
        switch paint {
        case .undecided:
            paint = !cold || ready ? .shown : .waiting
        case .waiting:
            if ready { withAnimation(.easeOut(duration: 0.3)) { paint = .shown } }
        case .shown:
            if HomeFirstPaint.waitsAgain(isEmpty: isEmpty, isCold: cold, isReady: ready, patienceSpent: patienceSpent) { paint = .waiting }
        }
    }

    @ViewBuilder
    private func page(layout: HomeLayout, topInset: CGFloat) -> some View {
        let servicePage = self.servicePage
        if isLoading {
            HomeSkeleton(layout: layout, text: text)
        } else if state.isUnavailable && !hasTitles && servicePage == .usual {
            HomeUnavailable { Task { await state.refresh(force: true) } }
                .frame(width: layout.width, height: layout.height - topInset)
                .padding(.top, topInset)
        } else if isEmpty {
            HomeNothing()
                .frame(width: layout.width, height: layout.height - topInset)
                .padding(.top, topInset)
        } else {
            // One rating and one set of badges per title, on every shelf.
            let harmony = HomeHarmony(shelves: state.shelves, hero: state.heroItems, deduplicates: true)
            LazyVStack(alignment: .leading, spacing: layout.shelfSpacing) {
                if state.heroItems.isEmpty {
                    // No carousel (hidden, or no title to feature): the
                    // first shelf starts under the top bar.
                    Color.clear.frame(height: topInset)
                        .id(HomeScreen.topID)
                } else {
                    HomeHeroCarousel(items: harmony.hero, layout: layout, text: text, topInset: topInset,
                                     isActive: isActive && isShown && turnsByItself, pinnedPage: pinnedHeroPage, open: choose)
                        // The first shelf's title sits close under the hero.
                        .padding(.bottom, -layout.shelfSpacing * 0.4)
                        .id(HomeScreen.topID)
                }
                if state.isOffline {
                    HomeOfflineNote(detail: text.offlineDetail(lastUpdated: state.lastUpdated), layout: layout)
                }
                ForEach(harmony.shelves) { shelf in
                    HomeShelfRow(shelf: shelf, layout: layout, text: text, memory: memory, open: choose,
                                 seeAll: seeAllAction(for: shelf))
                        .onAppear { prefetchShelf(after: shelf, layout: layout) }
                }
                if servicePage.showsRowOnly {
                    // A service just picked, one that listed nothing, or
                    // one whose lists failed: never the row alone without
                    // a word.
                    HomeServiceState(page: servicePage, layout: layout, text: text) {
                        Task { await state.refresh(force: true) }
                    }
                } else if state.isRefreshing && state.shelves.count < 4 {
                    // A first load that has shown its first shelves and is
                    // still asking for the rest.
                    HomeShelfSkeleton(style: .posters, layout: layout, text: text)
                        .modifier(HomePulse())
                }
            }
            .padding(.bottom, 36)
            .animation(.easeInOut(duration: 0.3), value: state.shelves.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: state.isOffline)
        }
    }
}

/// The same title on several shelves (and in the carousel) is told the
/// same way everywhere: one rating — the one of the list fetched last —
/// and, on its title cards, every badge any of its cards has (an episode
/// card keeps its own editorial badge: it is about that episode).
struct HomeHarmony {
    let shelves: [HomeShelf]
    let hero: [HomeItem]

    /// - Parameter deduplicates: the page as the Home draws it
    ///   (`deduplicated`); false for a shelf listed on its own (See All),
    ///   which keeps the shelf's order.
    init(shelves: [HomeShelf], hero: [HomeItem], deduplicates: Bool = false) {
        var rating: [String: (value: Double, date: Date)] = [:]
        var formats: [String: Set<HomeBadge>] = [:]
        var editorial: [String: Set<HomeBadge>] = [:]
        func note(_ item: HomeItem, date: Date) {
            // Equal dates: the first list read keeps it.
            if let value = item.rating, value > 0, rating[item.imdbId].map({ date > $0.date }) ?? true {
                rating[item.imdbId] = (value, date)
            }
            formats[item.imdbId, default: []].formUnion(item.badges.filter(\.isFormat))
            if item.episode == nil {
                editorial[item.imdbId, default: []].formUnion(item.badges.filter { !$0.isFormat && $0 != .upcoming })
            }
        }
        for shelf in shelves {
            for item in shelf.items { note(item, date: shelf.updatedAt ?? .distantPast) }
        }
        for item in hero { note(item, date: .distantPast) }

        func harmonized(_ item: HomeItem) -> HomeItem {
            var item = item
            if let known = rating[item.imdbId] { item.rating = known.value }
            var badges = Set(item.badges).union(formats[item.imdbId] ?? [])
            if item.episode == nil { badges.formUnion(editorial[item.imdbId] ?? []) }
            item.badges = HomeBadge.allCases.filter(badges.contains)
            return item
        }
        let harmonizedShelves = shelves.map { shelf in
            var shelf = shelf
            shelf.items = shelf.items.map(harmonized)
            return shelf
        }
        self.shelves = deduplicates ? HomeHarmony.deduplicated(harmonizedShelves) : harmonizedShelves
        self.hero = hero.map(harmonized)
        // The rest of the app (grids, Search, a title's page) tells these
        // titles as the Home does. A service card is not a title.
        HomeTitleFacts.shared.record(HomeServiceCard.titles(harmonizedShelves.flatMap(\.items)) + self.hero)
        HomeTitleFacts.shared.recordNewEpisodes(in: harmonizedShelves)
    }

    /// The shelves whose order is the point: they are never reordered —
    /// nor are the « Services » row and a service's shelves
    /// (`HomeShelfID.keepsItsOrder`: popular, new, top rated).
    static let keepsOrder: Set<String> = [HomeShelfID.continueWatching, HomeShelfID.watchlist, HomeShelfID.forYou,
                                          HomeShelfID.topMovies, HomeShelfID.topShows]

    static func keepsOrder(_ id: String) -> Bool {
        keepsOrder.contains(id) || HomeShelfID.keepsItsOrder(id)
    }

    /// The user's own shelves: built from the library on the device, they
    /// arrive apart from the catalogue's, so they never reorder the
    /// catalogue's shelves (a row would jump under the eyes when they come).
    /// « For You » is ranked by the profile's taste and picks among the
    /// catalogue's titles: it pushes none of them down the shelves below.
    static let personal: Set<String> = [HomeShelfID.continueWatching, HomeShelfID.watchlist, HomeShelfID.yourShows,
                                        HomeShelfID.forYou]

    /// A page that does not repeat its headline titles: a title already
    /// shown higher up in the catalogue's shelves goes to the end of a
    /// later one (Reprendre, Ma liste and the ranked shelves keep their
    /// order; the user's own shelves and the episode cards do not count).
    /// The new episodes of the user's shows leave out a show that Continue
    /// Watching already resumes; a shelf left empty goes.
    static func deduplicated(_ shelves: [HomeShelf]) -> [HomeShelf] {
        var seen: Set<String> = []
        let resumed = Set(shelves.first { $0.id == HomeShelfID.continueWatching }?.items.map(\.imdbId) ?? [])
        return shelves.compactMap { shelf in
            var shelf = shelf
            if shelf.id == HomeShelfID.yourShows {
                shelf.items.removeAll { resumed.contains($0.imdbId) }
                if shelf.items.isEmpty { return nil }
            }
            if !keepsOrder(shelf.id), shelf.style != .ranked {
                func shown(_ item: HomeItem) -> Bool { item.episode == nil && seen.contains(item.imdbId) }
                let fresh = shelf.items.filter { !shown($0) }
                // A shelf of titles all shown above keeps its own order.
                if !fresh.isEmpty {
                    shelf.items = fresh + shelf.items.filter(shown)
                }
            }
            // An episode's card is about that episode, not its show's title.
            if !personal.contains(shelf.id) { seen.formUnion(shelf.items.filter { $0.episode == nil }.map(\.imdbId)) }
            return shelf
        }
    }
}

// `HomeTitleFacts` (one rating, one set of formats and one title per title in the whole
// app) lives in PopcornKit (HomeModel.swift): the Apple TV's grids read it too.

/// The page under a keyboard (the Mac): it can be the window's key view,
/// takes the keyboard when its host asks (`HomeControls.requestKeyboard`),
/// and hands the arrows, Return, Space and Escape to `press` — which says
/// whether the key was the page's. Nothing without controls, and nothing
/// on iOS.
private struct HomeKeyboard: ViewModifier {
    let controls: HomeControls?
    /// The page is in front: a page that is covered takes no key.
    let isOn: Bool
    let press: (HomeControls.Key) -> Bool

    #if os(macOS)
    @FocusState private var hasKeyboard: Bool
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        if let controls {
            content
                .focusable(isOn)
                .focusEffectDisabled()
                .focused($hasKeyboard)
                .onKeyPress(phases: [.down, .repeat]) { keyPress in
                    // ⌘, ⌥ and ⌃ combinations are the menus' and the system's.
                    guard isOn, keyPress.modifiers.isDisjoint(with: [.command, .option, .control]),
                          let key = HomeKeyboard.key(keyPress.key) else { return .ignored }
                    return press(key) ? .handled : .ignored
                }
                .onChange(of: controls.keyboardRequests, initial: true) { _, _ in takeKeyboard() }
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if os(macOS)
    /// Makes the page the window's key view. Let go first: the focus
    /// state may still say the page has the keyboard when another column's
    /// list (AppKit's, the sidebar) took it — set to what it already is,
    /// it would move nothing.
    private func takeKeyboard() {
        guard isOn else { return }
        hasKeyboard = false
        // After this update: the page has to be focusable first.
        DispatchQueue.main.async { hasKeyboard = true }
    }

    private static func key(_ key: KeyEquivalent) -> HomeControls.Key? {
        switch key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        case .return: return .open
        case .space: return .play
        case .escape: return .cancel
        default: return nil
        }
    }
    #endif
}

/// Tells when the page has scrolled past the carousel (iOS 18 / macOS 15).
private struct HomePastHero: ViewModifier {
    let threshold: CGFloat
    let hasHero: Bool
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    // Without a carousel the bar is over the shelves at once.
                    hasHero ? geometry.contentOffset.y > threshold : geometry.contentOffset.y > 4
                } action: { _, past in
                    onChange(past)
                }
        } else {
            content
        }
    }
}

/// How dark a host's top shade is: 0 while the carousel rests under the
/// status bar, 1 once anything else could reach it. Observed by the shade
/// alone.
@Observable
final class HomeScrollShade {
    var level: Double = 0
}

/// Feeds `HomeScrollShade` from the page's offset (iOS 18 / macOS 15): the
/// shade is opaque after 124 points of a carousel — long before the
/// carousel's text, buttons or dots get near the status bar — and after
/// 24 points of a page without one. In steps of a twentieth.
private struct HomeShadeLevel: ViewModifier {
    let shade: HomeScrollShade?
    let hasHero: Bool

    func body(content: Content) -> some View {
        if let shade, #available(iOS 18.0, macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Double.self) { geometry in
                    let offset = Double(geometry.contentOffset.y + geometry.contentInsets.top)
                    let level: Double = hasHero ? (offset - 24) / 100 : offset / 24
                    let clamped: Double = min(max(level, 0), 1)
                    return (clamped * 20).rounded() / 20
                } action: { _, level in
                    shade.level = level
                }
        } else {
            content
        }
    }
}

// MARK: - Placeholders

/// The page before its first content: the carousel's block and three
/// shelves of the final sizes, so nothing moves when the content arrives.
struct HomeSkeleton: View {
    let layout: HomeLayout
    let text: HomeCardText

    var body: some View {
        VStack(alignment: .leading, spacing: layout.shelfSpacing) {
            ZStack(alignment: layout.centersHero ? .bottom : .bottomLeading) {
                LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.03), HomePalette.background],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: layout.centersHero ? .center : .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: layout.heroLogoSize.width * 0.8, height: layout.heroLogoSize.height * 0.55)
                    Capsule().fill(Color.white.opacity(0.08)).frame(width: 190, height: 12)
                    HStack(spacing: 12) {
                        Capsule().fill(Color.white.opacity(0.12)).frame(width: 170, height: 46)
                        Circle().fill(Color.white.opacity(0.08)).frame(width: 46, height: 46)
                        Circle().fill(Color.white.opacity(0.08)).frame(width: 46, height: 46)
                    }
                    .padding(.top, 6)
                }
                .padding(.leading, layout.centersHero ? 0 : layout.sideInset)
                .padding(.bottom, layout.centersHero ? 36 : 30)
            }
            .frame(width: layout.width, height: layout.heroHeight)
            .padding(.bottom, -layout.shelfSpacing * 0.4)
            HomeShelfSkeleton(style: .posters, layout: layout, text: text)
            HomeShelfSkeleton(style: .posters, layout: layout, text: text)
            HomeShelfSkeleton(style: .landscape, layout: layout, text: text)
        }
        .padding(.bottom, 36)
        .modifier(HomePulse())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Spinner.Loading"))
        .accessibilityIdentifier("Home.Skeleton")
    }
}

/// A slow breath on the placeholders; still with Reduce Motion.
struct HomePulse: ViewModifier {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

// MARK: - Status

/// Over the first shelf while the page comes from the cache because no
/// source answered: says so, and how old the page is.
struct HomeOfflineNote: View {
    let detail: String?
    let layout: HomeLayout

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GlassPalette.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text("You're Offline")
                    .font(HomeFont.cardTitle)
                    .foregroundStyle(GlassPalette.primaryText)
                if let detail {
                    Text(verbatim: detail)
                        .font(HomeFont.cardDetail)
                        .foregroundStyle(GlassPalette.secondaryText)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, layout.sideInset)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Home.Offline")
    }
}

/// No source answered and nothing is cached: why, and a way to ask again.
struct HomeUnavailable: View {
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Home.Unavailable.Title", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Please check your internet connection and try again.")
        } actions: {
            Button("Try Again", action: retry)
                .glassActionStyle(prominent: true)
                .accessibilityIdentifier("Home.Retry")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Home.Unavailable")
    }
}

/// Every shelf is hidden (the Home's settings).
struct HomeNothing: View {
    var body: some View {
        ContentUnavailableView {
            Label("Home.Empty.Title", systemImage: "rectangle.stack")
        } description: {
            Text("Home.Empty.Detail")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Home.Empty")
    }
}
