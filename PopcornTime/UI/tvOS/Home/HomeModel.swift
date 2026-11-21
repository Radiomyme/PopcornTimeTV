// HomeModel.swift — the state of the Home tab's page: which hero item the
// billboard shows, which card it follows once the focus is in the shelves,
// and where the focus goes back to. The shelves themselves are the hub's
// (`HomeState`, PopcornKit); what the page does goes through `HomeActions`,
// filled by `HomeHostingController`.
import SwiftUI
import PopcornKit

/// What can hold the focus on the page.
enum HomeFocus: Hashable {
    case play
    case info
    case watchlist
    /// Try Again, when the hub could not load.
    case retry
    case card(shelf: String, item: String)
    case seeAll(shelf: String)

    /// The shelf of a card or of a See All card.
    var shelf: String? {
        switch self {
        case .card(let shelf, _), .seeAll(let shelf): return shelf
        default: return nil
        }
    }

    /// One of the buttons at the top of the page.
    var isHeader: Bool { shelf == nil }
}

/// What the page asks of its host.
struct HomeActions {
    /// The title's page.
    var open: (_ item: HomeItem, _ shelf: String?) -> Void = { _, _ in }
    /// Plays the title (the page, then its playback).
    var play: (_ item: HomeItem, _ shelf: String?) -> Void = { _, _ in }
    /// The grid a shelf's See All card opens.
    var seeAll: (HomeShelf) -> Void = { _ in }
    var isInWatchlist: (HomeItem) -> Bool = { _ in false }
    var toggleWatchlist: (HomeItem) -> Void = { _ in }
    /// nil: the card cannot be marked (a show without an episode).
    var isWatched: (HomeItem) -> Bool? = { _ in nil }
    var toggleWatched: (HomeItem) -> Void = { _ in }
    var removeFromContinueWatching: (HomeItem) -> Void = { _ in }
    /// The page filtered on a service goes back to the usual one (Menu at
    /// its top, as « All » does).
    var showUsualPage: () -> Void = {}
}

/// What a focus move asks of the scroll view.
enum HomeFocusEffect: Equatable {
    case none
    /// Back to the top of the page.
    case scrollToTop
    /// The shelf under the billboard's band.
    case scrollToShelf(String)
    /// The focus belongs elsewhere (back on the card it left).
    case redirect(HomeFocus)
}

@MainActor
@Observable
final class HomePageModel {

    /// What starts the page.
    enum Header: Equatable {
        /// Nothing to show yet: placeholders.
        case skeleton
        /// The billboard on the hero items, with its buttons.
        case hero
        /// The hub could not load: a message and Try Again.
        case error
        /// Shelves without a hero: the page starts with the first one.
        case none
    }

    let home: HomeState
    @ObservationIgnored var actions = HomeActions()
    @ObservationIgnored let text = HomeText.standard
    let backdrop = HomeBackdrop()

    // MARK: Billboard

    /// Which hero item the billboard shows at the top.
    private(set) var heroIndex = 0
    /// The card the billboard follows once the focus is in the shelves.
    private(set) var followed: HomeItem?
    /// The focus is below the header: the billboard is compact and follows it.
    private(set) var isInShelves = false
    /// The page's content has the focus (not the tab bar, not another screen).
    private(set) var contentHasFocus = false
    /// The focus is in the tab bar (the host says so; true at launch).
    @ObservationIgnored var tabBarHasFocus = true
    /// Is the focus, as UIKit has it, inside the page? (The host answers:
    /// the page's own focus state keeps its last value when the focused
    /// card is removed, or while the page is off screen.)
    @ObservationIgnored var focusIsInPage: () -> Bool = { true }
    /// Asks UIKit to bring the focus into the page (the host).
    @ObservationIgnored var pullFocus: () -> Void = {}
    /// Where the page is giving the focus (`redirect`), until it is there.
    @ObservationIgnored private(set) var pendingFocus: HomeFocus?
    /// The last focus update UIKit made came from the remote (a direction:
    /// the host says so), not from the page (`redirect`, its steps).
    @ObservationIgnored private var lastFocusUpdateWasUsers = false
    @ObservationIgnored private var pageIsAtTop = true
    /// Bumped when the user's library changes: the cards' menus are read again.
    private(set) var libraryVersion = 0
    /// The hero changes by itself (off: a DEBUG hook pinned it, or the tab is hidden).
    var autoAdvances = true
    /// The tab is on screen.
    var isVisible = false

    // MARK: Focus

    /// Set to move the focus (the host, a DEBUG hook); the view takes it.
    var focusRequest: HomeFocus?
    /// Set to bring a shelf under the band before it gets the focus (DEBUG hooks).
    var scrollRequest: String?
    /// Where the focus was last, in the page.
    @ObservationIgnored private(set) var lastFocus: HomeFocus?
    /// Where the focus goes back when it returns to the page (from a title's
    /// page, from a grid): the card it left.
    private(set) var returnFocus: HomeFocus?
    /// The shelf that has the focus (nil: the top of the page).
    private var currentShelf: String?
    /// The place of the card that had the focus last: its shelf's in the
    /// page, its own in the shelf.
    @ObservationIgnored private var lastCard: (shelf: Int, item: Int) = (0, 0)
    @ObservationIgnored private var followTask: Task<Void, Never>?
    /// The artwork of what comes next (the shelf below, the hero's next page).
    @ObservationIgnored private let prefetcher = ArtworkPrefetcher()
    @ObservationIgnored private var lastFocusChange = Date.distantPast

    /// How long the focus rests on a card before the billboard follows it.
    static let followDelay: TimeInterval = 0.25
    /// How long the hero shows an item before the next.
    static let heroInterval: TimeInterval = 9

    init(home: HomeState) {
        self.home = home
        // Kept for the app's life, like the tab.
        NotificationCenter.default.addObserver(forName: .libraryDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryVersion += 1 }
        }
    }

    // MARK: What the page shows

    var header: Header {
        if home.isUnavailable { return .error }
        if !home.heroItems.isEmpty { return .hero }
        return home.shelves.isEmpty ? .skeleton : .none
    }

    var heroItem: HomeItem? {
        let items = home.heroItems
        return items.isEmpty ? nil : items[min(heroIndex, items.count - 1)]
    }

    /// What the compact billboard shows: the card it follows; before the
    /// focus has been on any, on a page without a hero, the page's first card.
    var compactItem: HomeItem? {
        return followed ?? (header == .none ? home.shelves.first?.items.first : nil)
    }

    /// The billboard is in its compact form, at the top of the screen.
    var showsCompact: Bool {
        return header == .none || isInShelves
    }

    /// The compact billboard stands under the tab bar: a page without a
    /// hero, at its top (the tab bar is on screen there).
    var compactIsUnderTabBar: Bool {
        guard header == .none else { return false }
        return currentShelf == nil || currentShelf == home.shelves.first?.id
    }

    /// The focus of the page when nothing says otherwise.
    var preferredFocus: HomeFocus? {
        if let returnFocus, exists(returnFocus) { return returnFocus }
        switch header {
        case .hero: return .play
        case .error: return .retry
        case .skeleton: return nil
        case .none:
            guard let shelf = home.shelves.first, let item = shelf.items.first else { return nil }
            return .card(shelf: shelf.id, item: item.id)
        }
    }

    func item(_ focus: HomeFocus?) -> (item: HomeItem, shelf: HomeShelf)? {
        guard case .card(let shelfID, let itemID)? = focus, let shelf = home.shelf(shelfID),
              let item = shelf.items.first(where: { $0.id == itemID }) else { return nil }
        return (item, shelf)
    }

    private func exists(_ focus: HomeFocus) -> Bool {
        switch focus {
        case .play, .info, .watchlist: return header == .hero
        case .retry: return header == .error
        case .card: return item(focus) != nil
        case .seeAll(let shelf): return home.shelf(shelf)?.seeAll != nil
        }
    }

    // MARK: Focus

    /// The focus moved (nil: out of the page). Says what the scroll view
    /// has to do; the billboard and the backdrop follow by themselves.
    func focusMoved(from old: HomeFocus?, to new: HomeFocus?) -> HomeFocusEffect {
        let effect = effectOfFocusMove(from: old, to: new)
        #if DEBUG
        HomeDebug.trace("focus \(old.map { "\($0)" } ?? "nil") -> \(new.map { "\($0)" } ?? "nil"): \(effect)")
        #endif
        return effect
    }

    private func effectOfFocusMove(from old: HomeFocus?, to new: HomeFocus?) -> HomeFocusEffect {
        lastFocusChange = Date()
        // The user moved on from the card a pick kept the focus on (or the
        // focus went up to the top: Menu).
        if let card = serviceCard, new != card, lastFocusUpdateWasUsers || new?.isHeader == true { serviceCard = nil }
        // The page is giving the focus to a card (`redirect`): there, or
        // on a stop on the way, which is not a move of the user's.
        var arrived = false
        if let pending = pendingFocus, let new {
            if new == pending {
                pendingFocus = nil
                // The stops on the way may have moved the page: the shelf goes
                // back under the band.
                arrived = true
            } else if lastFocusUpdateWasUsers {
                // The user moved before the focus got there: the move is
                // his, and the page stops pulling the focus to its target.
                #if DEBUG
                HomeDebug.trace("focus not given to \(pending): the user moved first")
                #endif
                pendingFocus = nil
                returnFocus = nil
            } else {
                contentHasFocus = true
                return .none
            }
        }
        // The card that had the focus is gone (taken out of Continue
        // Watching, a refresh): the focus goes to the card that took its
        // place, not wherever the focus engine fell back to.
        // (A move along the same shelf is the user's, or as good.)
        if let old, case .card(let shelf, _) = old, !exists(old), new?.shelf != shelf,
           let wanted = replacement(for: old, orElsewhere: new == nil), wanted != new {
            return redirect(to: wanted)
        }
        // The page of the card that has the focus is asked ahead
        // (`DetailStore.prewarm`: 0.4 s on it, two at a time), as on the
        // grids; nil when the focus is on a button or out of the page.
        DetailStore.shared.prewarm(item(new)?.item)
        guard let new else {
            contentHasFocus = false
            // The page went back to its top before the focus left it.
            returnToHeroAtTheTop()
            return .none
        }
        if !contentHasFocus { contentHasFocus = true }
        // Back in the page (from a title's page, from a grid by the tab
        // bar): on the card it left, wherever the focus engine landed first.
        // (Not "the focus was nowhere before": the focus state of a page
        // off screen keeps its last value.)
        if let wanted = returnFocus {
            returnFocus = nil
            if wanted != new, exists(wanted) { return redirect(to: wanted) }
        }
        lastFocus = new

        guard let shelfID = new.shelf else {
            // A button at the top.
            followTask?.cancel()
            currentShelf = nil
            guard isInShelves else { return .none }
            withAnimation(.easeInOut(duration: 0.35)) { isInShelves = false }
            showHeroBackdrop()
            return .scrollToTop
        }

        let entering = !isInShelves
        if entering { withAnimation(.easeInOut(duration: 0.35)) { isInShelves = true } }
        if let (card, shelf) = item(new) {
            lastCard = (home.shelves.firstIndex { $0.id == shelf.id } ?? 0, shelf.items.firstIndex { $0.id == card.id } ?? 0)
            follow(card, immediately: entering || followed == nil)
        } else if entering {
            // See All: the billboard stays on the card it showed last.
            showFollowedBackdrop()
        }
        guard shelfID != currentShelf || entering || arrived else { return .none }
        if shelfID != currentShelf { prefetchShelf(after: shelfID) }
        currentShelf = shelfID
        // Without a hero the first shelf is the top of the page.
        if header == .none, shelfID == home.shelves.first?.id { return .scrollToTop }
        return .scrollToShelf(shelfID)
    }

    /// The focus has to go to `wanted`, which is not where it is. A card:
    /// the page turns to its shelf at once (the billboard too); the view
    /// brings the shelf under the band, then gives it the focus.
    func redirect(to wanted: HomeFocus) -> HomeFocusEffect {
        pendingFocus = wanted
        pageMovesFocus()
        if let shelfID = wanted.shelf {
            if !isInShelves { withAnimation(.easeInOut(duration: 0.35)) { isInShelves = true } }
            currentShelf = shelfID
            if let card = item(wanted)?.item { follow(card, immediately: true) } else { showFollowedBackdrop() }
        }
        return .redirect(wanted)
    }

    /// Where the focus goes before `item` leaves `shelfID`: the card after
    /// it, else the one before, else the first card of the next shelf, else
    /// the top. nil when the focus is not on that card.
    func neighbour(of item: HomeItem, in shelfID: String) -> HomeFocus? {
        guard lastFocus == .card(shelf: shelfID, item: item.id), let shelf = home.shelf(shelfID),
              let index = shelf.items.firstIndex(where: { $0.id == item.id }) else { return nil }
        if index + 1 < shelf.items.count { return .card(shelf: shelfID, item: shelf.items[index + 1].id) }
        if index > 0 { return .card(shelf: shelfID, item: shelf.items[index - 1].id) }
        let shelves = home.shelves
        if let place = shelves.firstIndex(where: { $0.id == shelfID }), place + 1 < shelves.count,
           let first = shelves[place + 1].items.first {
            return .card(shelf: shelves[place + 1].id, item: first.id)
        }
        return header == .hero ? .play : nil
    }

    /// The shelves changed. The card that had the focus may be gone (taken
    /// out of Continue Watching from its menu, replaced by a refresh) with
    /// the focus left nowhere — the focus state does not always say so:
    /// where the focus has to go then, nil when there is nothing to do.
    func focusAfterShelvesChanged() -> HomeFocus? {
        guard isVisible, !tabBarHasFocus, let last = lastFocus, case .card = last, !exists(last) else { return nil }
        return replacement(for: last, orElsewhere: true)
    }

    /// What takes the place of a card that is gone: the card now at its
    /// place in its shelf (the last one when it was the last). The shelf
    /// gone too, and the focus nowhere (`elsewhere`): the first card of the
    /// shelf now at that place in the page, else the top.
    private func replacement(for focus: HomeFocus, orElsewhere elsewhere: Bool) -> HomeFocus? {
        guard case .card(let shelfID, _) = focus else { return nil }
        if let shelf = home.shelf(shelfID), !shelf.items.isEmpty {
            return .card(shelf: shelfID, item: shelf.items[min(lastCard.item, shelf.items.count - 1)].id)
        }
        guard elsewhere else { return nil }
        let shelves = home.shelves
        guard let shelf = shelves.indices.contains(lastCard.shelf) ? shelves[lastCard.shelf] : shelves.last,
              let first = shelf.items.first else { return preferredFocus }
        return .card(shelf: shelf.id, item: first.id)
    }

    /// The billboard follows `item`: at once, or once the focus has rested
    /// on it (a row scrolled through does not load every backdrop it crosses).
    private func follow(_ item: HomeItem, immediately: Bool) {
        followTask?.cancel()
        guard !immediately else { return setFollowed(item) }
        followTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(HomePageModel.followDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.setFollowed(item)
        }
    }

    /// The backdrop of the card the compact billboard shows.
    private func showFollowedBackdrop() {
        if let item = compactItem { backdrop.show(backdropSource(of: item)) }
    }

    private func setFollowed(_ item: HomeItem) {
        if followed != item {
            withAnimation(.easeInOut(duration: 0.25)) { followed = item }
        }
        backdrop.show(backdropSource(of: item))
    }

    /// A card's backdrop. A card of the « Services » row has no artwork:
    /// the page's own, its hero's (once a service is picked, that
    /// service's titles), not the last title the focus left behind.
    private func backdropSource(of item: HomeItem) -> HomeBackdrop.Source? {
        guard HomeServiceCard.isServiceCard(item) else { return HomeBackdrop.Source(item) }
        let title = heroItem ?? home.shelves.first { $0.id != HomeShelfID.services }?.items.first
        return title.map(HomeBackdrop.Source.init)
    }

    /// The page leaves the screen (a title's page is pushed, another tab is
    /// selected): the focus will come back where it was. The artwork asked
    /// ahead for the shelves is not fetched behind that page (as the shared
    /// Home screen does); the next shelf the focus enters asks again, and
    /// what is already decoded is skipped.
    func pageWillDisappear() {
        isVisible = false
        prefetcher.cancel()
        // A focus still on its way to a card stops there (it would pull the
        // focus into the page of another tab): it comes back to that card.
        if let pending = pendingFocus {
            pendingFocus = nil
            if !pending.isHeader { returnFocus = pending }
        } else if let lastFocus, !lastFocus.isHeader {
            returnFocus = lastFocus
        }
    }

    /// UIKit moved the focus (the host, from `didUpdateFocus`): `byUser`,
    /// with a direction of the remote; `inPage`, onto something of the page.
    /// The user taking the focus out of the page (Up to the tab bar) while
    /// the page was giving it to a card: the page stops; Down comes back to
    /// that card.
    func focusUpdated(byUser: Bool, inPage: Bool) {
        lastFocusUpdateWasUsers = byUser
        guard byUser, !inPage, let pending = pendingFocus else { return }
        #if DEBUG
        HomeDebug.trace("focus not given to \(pending): the user left the page")
        #endif
        pendingFocus = nil
        returnFocus = pending.isHeader ? nil : pending
    }

    /// The page itself moves the focus (a step of `redirect`): the moves
    /// that follow are its stops, not the user's.
    func pageMovesFocus() {
        lastFocusUpdateWasUsers = false
    }

    /// The page's scroll view is at its top, or left it. At its top while
    /// the focus is elsewhere: tvOS scrolls a tab's page up when its tab bar
    /// takes the focus, and the selected tab pressed again does too. The
    /// page is then the one of a launch again, with its hero. (Where the
    /// focus goes back to is kept: Down from the tab bar returns to the
    /// card it left.)
    func pageScrolled(toTop isAtTop: Bool) {
        #if DEBUG
        HomeDebug.trace("page \(isAtTop ? "at" : "below") its top (content focus \(contentHasFocus), in shelves \(isInShelves))")
        #endif
        pageIsAtTop = isAtTop
        returnToHeroAtTheTop()
    }

    private func returnToHeroAtTheTop() {
        guard pageIsAtTop, !contentHasFocus, isInShelves, header != .none else { return }
        currentShelf = nil
        followTask?.cancel()
        withAnimation(.easeInOut(duration: 0.35)) { isInShelves = false }
        showHeroBackdrop()
    }

    /// `wanted` becomes the page's default focus (`preferredFocus`), until
    /// the focus is there or the page gives up.
    func prefer(_ wanted: HomeFocus) {
        returnFocus = wanted
    }

    /// The focus could not be given where the page wanted it: the page
    /// stops trying (the view then takes the focus as it is).
    func abandonPendingFocus() {
        #if DEBUG
        HomeDebug.trace("focus not given to \(pendingFocus.map { "\($0)" } ?? "nil"): given up")
        #endif
        pendingFocus = nil
        returnFocus = nil
        currentShelf = nil
    }

    /// Menu below the top: where the focus goes back up to.
    func takeTopFocus() -> HomeFocus? {
        returnFocus = nil
        serviceCard = nil
        return preferredFocus
    }

    // MARK: The « Services » row

    /// The card of the « Services » row the focus stays on while the page
    /// is rebuilt for a service picked (`keepFocus(on:)`).
    @ObservationIgnored private var serviceCard: HomeFocus?
    @ObservationIgnored private var serviceCardSince = Date.distantPast

    /// A service was picked (or « All ») from `card`'s row: once the page
    /// is rebuilt, the focus is on `card` (the service picked, or the one
    /// that was on) with its row under the band — not on « All », which
    /// comes and goes at the start of the row and where the focus fell
    /// (a second Select then undid the pick).
    func keepFocus(on card: HomeFocus) {
        serviceCard = card
        serviceCardSince = Date()
        // What the focus does next is the page's (Select moved nothing).
        pageMovesFocus()
    }

    /// The shelves changed: the card the focus has to be on after a pick,
    /// nil when there is none. Kept while the page refreshes (its shelves
    /// come in one by one, the hero above them), until the user moves.
    func focusAfterServicePick() -> HomeFocus? {
        guard let card = serviceCard else { return nil }
        guard isVisible, Date().timeIntervalSince(serviceCardSince) < 30 else {
            serviceCard = nil
            return nil
        }
        guard exists(card) else { return nil }
        if !home.isRefreshing { serviceCard = nil }
        return card
    }

    /// The service the page is filtered on: the selected card of the
    /// « Services » row (nil: the usual page).
    var filteredService: HomeItem? {
        return home.shelf(HomeShelfID.services)?.items.first(where: HomeServiceCard.isSelected)
    }

    /// A page filtered on a service none of whose lists came (TMDB refused
    /// the key, or did not answer; nothing saved): the error header.
    var serviceFailed: Bool {
        return home.isUnavailable && filteredService != nil
    }

    /// A page filtered on a service with none of its shelves yet: they are
    /// being asked (placeholders), or the service listed nothing.
    var hasOnlyServicesRow: Bool {
        return filteredService != nil && home.shelves.allSatisfy { $0.id == HomeShelfID.services }
    }

    /// Menu has somewhere to go back to inside the page.
    var canGoBackToTop: Bool {
        guard contentHasFocus, let shelf = currentShelf else { return false }
        return header != .none || shelf != home.shelves.first?.id
    }

    // MARK: Hero

    /// The hero items changed (a refresh): the billboard keeps its title
    /// when it is still there.
    func heroItemsChanged(from old: [HomeItem]) {
        let items = home.heroItems
        if heroIndex < old.count, let kept = items.firstIndex(where: { $0.imdbId == old[heroIndex].imdbId }) {
            heroIndex = kept
        } else {
            heroIndex = min(heroIndex, max(items.count - 1, 0))
        }
        if !isInShelves {
            showHeroBackdrop()
        } else if let followed, HomeServiceCard.isServiceCard(followed) {
            // On a service's card: the hero of the page it now shows.
            backdrop.show(backdropSource(of: followed))
        }
    }

    func showHero(_ index: Int) {
        let count = home.heroItems.count
        guard count > 0 else { return }
        let wrapped = ((index % count) + count) % count
        if wrapped != heroIndex {
            withAnimation(.easeInOut(duration: 0.35)) { heroIndex = wrapped }
        }
        prefetchHeroLogo(after: wrapped)
        if !isInShelves { showHeroBackdrop() }
    }

    /// The logo of the hero's next page, fetched while this one shows
    /// (its backdrop has its own loader, which keeps no more than two in
    /// memory: it is not fetched ahead).
    private func prefetchHeroLogo(after index: Int) {
        let items = home.heroItems
        guard items.count > 1, let logo = items[(index + 1) % items.count].logoURL else { return }
        prefetcher.prefetch(urls: [logo], width: homePixels(680))
    }

    /// The focus came to a shelf: the first cards of the one below it are
    /// fetched at the size they are drawn (PopcornKit's `ArtworkPrefetcher`).
    private func prefetchShelf(after shelfID: String) {
        guard let index = home.shelves.firstIndex(where: { $0.id == shelfID }),
              home.shelves.indices.contains(index + 1) else { return }
        let next = home.shelves[index + 1]
        let items = next.items.prefix(10)
        switch next.style {
        case .landscape:
            prefetcher.prefetch(urls: items.compactMap { HomeLandscapeArt.urls(of: $0).first },
                                width: homePixels(TVHomeLayout.landscape.width))
        case .ranked:
            prefetcher.prefetch(urls: items.compactMap { HomePosterArt.urls(of: $0).first },
                                width: homePixels(TVHomeLayout.rankedPosterWidth))
        case .posters, .hero:
            prefetcher.prefetch(urls: items.compactMap { HomePosterArt.urls(of: $0).first },
                                width: homePixels(TVHomeLayout.poster.width))
        }
    }

    /// The page is on screen (again). Back from a title's page with the
    /// focus in the shelves, the backdrop is the followed card's, which is
    /// still the one shown: nothing is loaded or faded (it was set to the
    /// hero's here, and came back to the card's 0.3 s later — the hero's
    /// picture under the card's billboard meanwhile).
    func pageAppeared() {
        if isInShelves, followed != nil {
            showFollowedBackdrop()
        } else {
            showHeroBackdrop()
        }
    }

    /// The backdrop of the top of the page: the hero item's (without a
    /// hero: the first card's, like the billboard).
    func showHeroBackdrop() {
        backdrop.show((heroItem ?? (followed == nil ? compactItem : nil)).map(HomeBackdrop.Source.init))
    }

    /// Left on the first button and Right on the last one turn the hero's
    /// pages. A press that also moved the focus onto that button is not one:
    /// the button must have had the focus before it.
    func heroMove(_ direction: MoveCommandDirection, focus: HomeFocus?) {
        guard header == .hero, !isInShelves, home.heroItems.count > 1,
              Date().timeIntervalSince(lastFocusChange) > 0.2 else { return }
        switch (direction, focus) {
        case (.left, .play?): showHero(heroIndex - 1)
        case (.right, .watchlist?): showHero(heroIndex + 1)
        default: break
        }
    }

    /// The hero may turn its page by itself now.
    var heroAutoAdvances: Bool {
        return autoAdvances && isVisible && header == .hero && !isInShelves && home.heroItems.count > 1
    }
}
