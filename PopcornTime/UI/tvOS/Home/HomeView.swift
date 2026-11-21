// HomeView.swift — the Home tab of the Apple TV app: the first screen.
//
// Layers, back to front:
//   1. the backdrop of the title the billboard shows (HomeBackdropView);
//   2. one vertical scroll view: the hero billboard with its buttons, then
//      the shelves, in the order the hub gives them (lazy rows of lazy cards);
//   3. once the focus is in the shelves, a copy of the backdrop over the top
//      band of the screen (the rows scroll under it and fade out at its
//      edge) and, on it, the compact billboard that follows the focused card.
//
// The focus drives everything: at the top the billboard presents the hero
// items; Down puts the focused shelf under the band, and the billboard then
// shows the card the focus rests on. A focus move only re-evaluates this
// body (it reads the focus): the rows are Equatable and are left alone, and
// the scroll view only moves when the focus changes shelf.
//
// Host it full screen in a UIHostingController (HomeHostingController): the
// view ignores the safe area and lays itself out for 1920 × 1080.
import SwiftUI
import PopcornKit

struct HomeView: View {
    let model: HomePageModel

    @FocusState private var focus: HomeFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The page's focus scope: where its default focus is evaluated again
    /// when the focus has to be given to a card (`moveFocus`).
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var pageScope
    /// The placeholders: at once on a page that has never had data (a
    /// first launch; the disk's page is painted before the first frame,
    /// `HomeHostingController`) — the tab was an empty backdrop under the
    /// tab bar for a third of a second. After a first paint (a refresh that
    /// emptied the page), only when the data takes a moment.
    @State private var showsSkeleton: Bool

    init(model: HomePageModel) {
        self.model = model
        _showsSkeleton = State(initialValue: !model.home.hasLoaded)
    }

    private static let top = "Home.Top"
    private static let page = "Home.Page"

    /// The page's scroll view is at its top.
    private struct HomeAtTopKey: PreferenceKey {
        static let defaultValue = true
        static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value && nextValue() }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                HomeBackdropView(backdrop: model.backdrop, lowered: model.showsCompact, size: size)

                page(size)

                // Over the top band while the focus is in the shelves: the
                // rows above the focused one go under it.
                HomeBackdropView(backdrop: model.backdrop, lowered: true, size: size)
                    .mask(alignment: .top) {
                        LinearGradient(stops: [.init(color: .black, location: 0),
                                               .init(color: .black, location: 0.90),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: band + 18)
                    }
                    .opacity(model.showsCompact ? 1 : 0)
                    .allowsHitTesting(false)

                if model.showsCompact {
                    HomeCompactBillboard(model: model)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if model.home.isOffline, model.header != .error {
                    HomeOfflineNote()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, TVHomeLayout.side)
                        .padding(.top, model.isInShelves ? 54 : 150)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.3), value: model.home.isOffline)
        .onPlayPauseCommand(perform: playPausePressed)
        // Menu below the top goes back up; at the top of a page filtered on
        // a service, back to the usual page (as « All »); at the top of the
        // usual page there is no handler: the system takes it, as on the
        // other tabs.
        .onExitCommand(perform: model.canGoBackToTop ? { backToTop() }
                       : model.filteredService != nil ? { model.actions.showUsualPage() } : nil)
        .onAppear { model.pageAppeared() }
        .onChange(of: model.home.heroItems) { old, _ in model.heroItemsChanged(from: old) }
        .task(id: model.header == .skeleton) {
            guard model.header == .skeleton else { return showsSkeleton = false }
            guard model.home.hasLoaded else { return showsSkeleton = true }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { withAnimation(.easeIn(duration: 0.2)) { showsSkeleton = true } }
        }
        .task(id: HeroTurn(index: model.heroIndex, active: model.heroAutoAdvances && !reduceMotion)) {
            // The hero turns its page by itself while nothing else is going on.
            guard model.heroAutoAdvances, !reduceMotion, !UIAccessibility.isVoiceOverRunning else { return }
            try? await Task.sleep(nanoseconds: UInt64(HomePageModel.heroInterval * 1_000_000_000))
            if !Task.isCancelled { model.showHero(model.heroIndex + 1) }
        }
    }

    private struct HeroTurn: Hashable {
        let index: Int
        let active: Bool
    }

    /// The height of the band the compact billboard keeps.
    private var band: CGFloat {
        return compactBand + (model.compactIsUnderTabBar ? TVHomeLayout.tabBarBand : 0)
    }

    /// The compact billboard's own height: shorter without a synopsis.
    private var compactBand: CGFloat {
        return TVHomeLayout.compactBand(showsSynopsis: model.text.showsSourceText)
    }

    // MARK: Page

    private func page(_ size: CGSize) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Not in the lazy stack: its buttons can take the focus
                    // from anywhere in the page (Menu from the tenth shelf).
                    header(size)
                        .id(HomeView.top)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: HomeAtTopKey.self,
                                                       value: geometry.frame(in: .named(HomeView.page)).minY > -2)
                            }
                        }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.home.shelves) { shelf in
                            HomeShelfRow(shelf: shelf, title: model.text.title(of: shelf),
                                         libraryVersion: model.libraryVersion, text: model.text,
                                         focus: $focus, actions: cardActions)
                                .equatable()
                                .id(shelf.id)
                        }
                        if model.header == .skeleton, showsSkeleton {
                            HomeShelfSkeleton(style: .posters)
                            HomeShelfSkeleton(style: .posters)
                        } else if model.hasOnlyServicesRow, !model.home.isUnavailable {
                            // A service just picked: its shelves are on
                            // their way, or it listed nothing — never the
                            // row alone without a word.
                            if model.home.isRefreshing {
                                HomeShelfSkeleton(style: .posters)
                                HomeShelfSkeleton(style: .posters)
                            } else {
                                Text("No results")
                                    .font(GlassFont.body)
                                    .foregroundStyle(GlassPalette.secondaryText)
                                    .padding(.horizontal, TVHomeLayout.side)
                                    .padding(.top, 20)
                                    .accessibilityIdentifier("Home.Services.Empty")
                            }
                        }
                    }
                }
                .padding(.bottom, TVHomeLayout.bottomPadding(viewport: size.height))
                .frame(width: size.width, alignment: .leading)
            }
            .coordinateSpace(name: HomeView.page)
            .scrollClipDisabled()
            .focusScope(pageScope)
            // The page is back at its top: with the focus elsewhere (the
            // tab bar took it), the hero is back too.
            .onPreferenceChange(HomeAtTopKey.self) { atTop in
                model.pageScrolled(toTop: atTop)
            }
            .defaultFocus($focus, model.preferredFocus)
            .onChange(of: focus) { old, new in
                focusMoved(from: old, to: new, proxy: proxy, viewport: size.height)
            }
            .onChange(of: model.home.shelves) { _, _ in
                // A page without a hero: its first card's backdrop.
                if model.header == .none { model.showHeroBackdrop() }
                // A service picked from its row: the focus stays on its card,
                // the row under the band (once the new row is laid out).
                if let card = model.focusAfterServicePick() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if model.serviceFailed { return showServiceFailure() }
                        if focus == card { return scroll(to: HomeShelfID.services, proxy: proxy, viewport: size.height, animated: true) }
                        if case .redirect(let target) = model.redirect(to: card) {
                            moveFocus(to: target, proxy: proxy, viewport: size.height)
                        }
                    }
                    return
                }
                // The focused card is gone: the one that took its place.
                guard let wanted = model.focusAfterShelvesChanged() else { return }
                if case .redirect(let target) = model.redirect(to: wanted) {
                    moveFocus(to: target, proxy: proxy, viewport: size.height)
                }
            }
            .onChange(of: model.home.isUnavailable) { _, unavailable in
                if unavailable, model.serviceFailed { showServiceFailure() }
            }
            .onChange(of: model.focusRequest) { _, request in
                guard let request else { return }
                model.focusRequest = nil
                focus = request
            }
            .onChange(of: model.scrollRequest) { _, shelf in
                guard let shelf else { return }
                model.scrollRequest = nil
                scroll(to: shelf, proxy: proxy, viewport: size.height, animated: false)
            }
        }
    }

    @ViewBuilder
    private func header(_ size: CGSize) -> some View {
        let heroHeight = TVHomeLayout.heroHeight(viewport: size.height)
        switch model.header {
        case .hero:
            HomeHeroHeader(model: model, focus: $focus, height: heroHeight)
                .frame(width: size.width, alignment: .leading)
        case .error:
            HomeErrorHeader(isRefreshing: model.home.isRefreshing, service: model.filteredService?.title, focus: $focus) {
                Task { await model.home.refresh(force: true) }
            }
            .frame(width: size.width, height: model.home.shelves.isEmpty ? size.height : heroHeight)
        case .skeleton:
            HomeHeroSkeleton(height: heroHeight)
                .opacity(showsSkeleton ? 1 : 0)
        case .none:
            // The band of the compact billboard, under the tab bar.
            Color.clear
                .frame(width: size.width, height: compactBand + TVHomeLayout.tabBarBand)
        }
    }

    private var cardActions: HomeCardActions {
        let actions = model.actions
        return HomeCardActions(
            select: { item, shelf in
                // A resume card resumes; any other card opens its page.
                if shelf.id == HomeShelfID.continueWatching {
                    actions.play(item, shelf.id)
                } else {
                    actions.open(item, shelf.id)
                }
            },
            play: { item, shelf in actions.play(item, shelf.id) },
            seeAll: actions.seeAll,
            isInWatchlist: actions.isInWatchlist,
            toggleWatchlist: actions.toggleWatchlist,
            isWatched: actions.isWatched,
            toggleWatched: actions.toggleWatched,
            removeFromContinueWatching: { item in
                // Once the menu has closed and the focus is back on the
                // card: the focus goes to the card next to it first — a
                // card removed under the focus leaves the focus nowhere.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    if let next = model.neighbour(of: item, in: HomeShelfID.continueWatching) { focus = next }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { actions.removeFromContinueWatching(item) }
                }
            })
    }

    // MARK: Focus

    private func focusMoved(from old: HomeFocus?, to new: HomeFocus?, proxy: ScrollViewProxy, viewport: CGFloat) {
        switch model.focusMoved(from: old, to: new) {
        case .none:
            break
        case .redirect(let wanted):
            moveFocus(to: wanted, proxy: proxy, viewport: viewport)
        case .scrollToTop:
            withAnimation(.easeInOut(duration: reduceMotion ? 0.01 : 0.4)) {
                proxy.scrollTo(HomeView.top, anchor: .top)
            }
        case .scrollToShelf(let shelf):
            scroll(to: shelf, proxy: proxy, viewport: viewport, animated: true)
        }
    }

    /// Gives the focus to `wanted`. A card: its shelf under the band first
    /// (its row is lazy, and may be far from where the page is), then the
    /// focus once the scroll has settled — set while the page still moves,
    /// the focus stays where it is.
    ///
    /// What was seen in the tvOS 26.5 simulator, and what this does with it:
    /// - from a card, the focus state moves the focus to any card or button;
    /// - from a button of the top (where Down from the tab bar lands), it
    ///   does not move it to a card, however long one waits: the card is
    ///   made the page's default focus and the default focus is evaluated
    ///   again (`resetFocus`), which puts the focus on a card on screen —
    ///   not always that one, but under the band's backdrop, not seen —
    ///   and the focus state goes on from there;
    /// - with the focus outside the page, UIKit brings it into the page
    ///   first; with the focus nowhere (the focused card was removed, or
    ///   drawn again in a row that changed: UIKit may still place it in the
    ///   page, where nothing shows it), too — the card made the page's
    ///   default focus first, where the focus then lands.
    /// Six steps at most, 0.3 s apart; then the page gives up and takes the
    /// focus as it is.
    private func moveFocus(to wanted: HomeFocus, proxy: ScrollViewProxy, viewport: CGFloat, attempt: Int = 0) {
        if attempt == 0, let shelf = wanted.shelf {
            scroll(to: shelf, proxy: proxy, viewport: viewport, animated: true)
        }
        let delay = attempt > 0 ? 0.3 : wanted.shelf == nil ? 0.02 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // There already, or given up.
            guard model.pendingFocus == wanted else { return }
            guard attempt < 6 else {
                model.abandonPendingFocus()
                return focusMoved(from: nil, to: focus, proxy: proxy, viewport: viewport)
            }
            let isInPage = model.focusIsInPage()
            #if DEBUG
            HomeDebug.trace("focus to \(wanted): step \(attempt), from \(focus.map { "\($0)" } ?? "nil"), in page \(isInPage)")
            #endif
            // The moves this step causes are stops on the way, not the
            // user's (a move of the user's ends the redirect).
            model.pageMovesFocus()
            if !isInPage || (focus == nil && wanted.shelf != nil) {
                if wanted.shelf != nil { model.prefer(wanted) }
                model.pullFocus()
            } else if wanted.shelf != nil, focus?.isHeader ?? true {
                // The card as the page's default focus, then (once the
                // view has it) the default focus evaluated again.
                model.prefer(wanted)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard model.pendingFocus == wanted else { return }
                    model.pageMovesFocus()
                    resetFocus(in: pageScope)
                }
            } else {
                focus = wanted
            }
            moveFocus(to: wanted, proxy: proxy, viewport: viewport, attempt: attempt + 1)
        }
    }

    /// Puts a shelf right under the billboard's band.
    private func scroll(to shelfID: String, proxy: ScrollViewProxy, viewport: CGFloat, animated: Bool) {
        guard let shelf = model.home.shelf(shelfID) else { return }
        let anchor = UnitPoint(x: 0, y: TVHomeLayout.anchor(band: compactBand,
                                                          rowHeight: TVHomeLayout.rowHeight(of: shelf.style),
                                                          viewport: viewport))
        guard animated else { return proxy.scrollTo(shelfID, anchor: anchor) }
        withAnimation(.easeInOut(duration: reduceMotion ? 0.01 : 0.4)) {
            proxy.scrollTo(shelfID, anchor: anchor)
        }
    }

    /// None of the picked service's lists came: the message at the top of
    /// the page, with Try Again, which gets the focus — the row (« All »
    /// included) stays under it. On the service's card, the row under the
    /// band, the message had scrolled away: the row alone, without a word.
    private func showServiceFailure() {
        guard focus?.shelf != nil || !model.focusIsInPage() else { return }
        _ = model.takeTopFocus()
        focus = .retry
    }

    private func backToTop() {
        guard let target = model.takeTopFocus() else { return }
        focus = target
    }

    /// The remote's Play/Pause: plays the focused card, or the hero's title
    /// from its buttons.
    private func playPausePressed() {
        if let (item, shelf) = model.item(focus) {
            model.actions.play(item, shelf.id)
        } else if focus?.isHeader == true, focus != .retry, let item = model.heroItem {
            model.actions.play(item, nil)
        }
    }
}
