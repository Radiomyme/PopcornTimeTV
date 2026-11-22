// HomeShelfRow.swift — one shelf of the Home (iOS and macOS): its title on
// the page's left edge with "See All" facing it, then a row of cards that
// scrolls sideways and snaps on a card. The row's first card starts on the
// same edge as the title and its last visible card is cut (`HomeLayout`).
import Foundation
import SwiftUI
import PopcornKit

/// Where each shelf was scrolled to, by shelf id: a row that left the
/// screen (the page is lazy) comes back where the user left it. A plain
/// object, not observed: a row scrolling must not redraw the page.
final class HomeScrollMemory {
    var positions: [String: String] = [:]
}

struct HomeShelfRow: View {
    let shelf: HomeShelf
    let layout: HomeLayout
    let text: HomeCardText
    let memory: HomeScrollMemory
    let open: (HomeSelection) -> Void
    /// Nil: the shelf has no "See All".
    let seeAll: ((HomeShelf) -> Void)?

    /// The id of the card on the row's leading edge.
    @State private var position: String?
    /// The keyboard's cursor and the pointer (the Mac); nil on iOS.
    @Environment(\.homeControls) private var controls
    #if os(macOS)
    /// The pointer is over the shelf: its paging chevrons show.
    @State private var isHovered = false
    /// Which way the row can still scroll, told by the scroll view
    /// (macOS 15+; nil: worked out from the cards).
    @State private var ends: HomeShelfEnds?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: layout.headerSpacing) {
            HomeShelfHeader(title: text.title(of: shelf), layout: layout,
                            seeAll: seeAll.map { seeAll in { seeAll(shelf) } })
                .accessibilityIdentifier("Home.Header.\(shelf.id)")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: layout.cardSpacing) {
                    ForEach(shelf.items) { item in
                        let place = HomeCursorCard(shelf: shelf.id, item: item.id)
                        Button {
                            open(HomeSelection(item: item, shelfID: shelf.id, intent: intent))
                        } label: {
                            card(item)
                        }
                        .buttonStyle(HomeCardButtonStyle(isSelected: controls?.cursorCard == place,
                                                         isHoverForced: controls?.shownAsHovered == "\(shelf.id)/\(item.id)",
                                                         onHover: { inside in
                                                             controls?.pointer(inside, on: place)
                                                             // The title's page is asked ahead while the
                                                             // pointer rests on its card (`DetailStore`:
                                                             // 0.4 s on it, two at a time), as on the grids.
                                                             // A service card has no page.
                                                             guard !isServices else { return }
                                                             if inside {
                                                                 DetailStore.shared.prewarm(item)
                                                             } else if let media = item.media {
                                                                 DetailStore.shared.stopPrewarm(of: media)
                                                             }
                                                         }))
                        // A service card is not a title: no menu.
                        .modifier(HomeTitleMenu(item: item, shelfID: shelf.id, isOn: !isServices, open: open))
                        .accessibilityLabel(Text(verbatim: isServices ? item.title : text.accessibilityLabel(of: item)))
                        .accessibilityAddTraits(isServices && HomeServiceCard.isSelected(item) ? .isSelected : [])
                        .accessibilityIdentifier("Home.Card.\(item.id)")
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, layout.sideInset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            // A card that dips or lifts is not cut by its row.
            .scrollClipDisabled()
            .scrollPosition(id: $position, anchor: .leading)
            .environment(\.homeHiddenBadges, HomeListBadges.hidden(shelfID: shelf.id, items: shelf.items))
            #if os(macOS)
            .modifier(HomeShelfEndsReader { ends = $0 })
            .overlay(alignment: .topLeading) { chevron(forward: false) }
            .overlay(alignment: .topTrailing) { chevron(forward: true) }
            #endif
        }
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .onAppear {
            if position == nil { position = memory.positions[shelf.id] }
            // The keyboard may have come to this shelf before it was drawn.
            reveal(controls?.cursorCard, animated: false)
        }
        .onChange(of: position) { _, new in memory.positions[shelf.id] = new }
        .onChange(of: controls?.cursorCard) { _, card in reveal(card, animated: true) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Home.Section.\(shelf.id)")
    }

    /// The « Services » row: its cards pick a service (`HomeServiceTile`).
    private var isServices: Bool { shelf.id == HomeShelfID.services }

    /// A Continue Watching card resumes; every other card opens its page.
    private var intent: HomeSelection.Intent {
        shelf.id == HomeShelfID.continueWatching ? .play : .details
    }

    @ViewBuilder
    private func card(_ item: HomeItem) -> some View {
        if isServices {
            HomeServiceTile(item: item, layout: layout)
        } else {
            titleCard(item)
        }
    }

    @ViewBuilder
    private func titleCard(_ item: HomeItem) -> some View {
        switch shelf.style {
        case .landscape:
            // A row of one episode (a single new episode of the user's
            // shows): one wide card, not a card and an empty row.
            HomeLandscapeCard(item: item, shelfID: shelf.id, layout: layout, text: text,
                              isWide: shelf.items.count == 1 && shelf.id != HomeShelfID.continueWatching)
        case .ranked:
            HomeRankedCard(item: item, shelfID: shelf.id, layout: layout, text: text)
        case .posters, .hero:
            HomePosterCard(item: item, shelfID: shelf.id, layout: layout, text: text)
        }
    }

    // MARK: Paging

    /// The index of the card on the row's leading edge.
    private var leadingIndex: Int {
        position.flatMap { id in shelf.items.firstIndex { $0.id == id } } ?? 0
    }

    /// How many cards the row shows whole (a ranked card is counted at its
    /// widest: the row then pages a little short rather than past a card).
    private var wholeCards: Int {
        let card: CGFloat
        switch shelf.style {
        case .landscape: card = layout.landscapeWidth
        case .ranked: card = layout.rankedCardWidth
        case .posters, .hero: card = layout.posterWidth
        }
        return HomeShelfPaging.wholeCards(row: layout.width - layout.sideInset, card: card, spacing: layout.cardSpacing)
    }

    /// The keyboard came on a card of this shelf: the row scrolls just
    /// enough to show it whole.
    private func reveal(_ card: HomeCursorCard?, animated: Bool) {
        guard let card, card.shelf == shelf.id, let index = shelf.items.firstIndex(where: { $0.id == card.item }) else { return }
        let leading = leadingIndex
        let target = HomeShelfPaging.reveal(index, leading: leading, whole: wholeCards)
        guard target != leading else { return }
        withAnimation(animated ? .easeInOut(duration: 0.25) : nil) { position = shelf.items[target].id }
    }

    #if os(macOS)
    private func canPage(forward: Bool) -> Bool {
        if let ends { return forward ? ends.forward : ends.back }
        return forward ? leadingIndex + wholeCards < shelf.items.count : leadingIndex > 0
    }

    /// A glass chevron on the row's edge, at mid-height of the artwork,
    /// while the pointer is over the shelf and the row goes on that way: a
    /// mouse has no sideways scroll. The same control as the shelves of a
    /// title's page (`MacGlassShelf`).
    private func chevron(forward: Bool) -> some View {
        let artwork: CGFloat
        switch shelf.style {
        case .landscape: artwork = layout.landscapeHeight
        case .ranked: artwork = layout.rankedPosterHeight
        case .posters, .hero: artwork = layout.posterHeight
        }
        let visible = (isHovered || controls?.shownAsHovered == shelf.id) && canPage(forward: forward)
        return Button {
            let target = HomeShelfPaging.page(from: leadingIndex, forward: forward, count: shelf.items.count, whole: wholeCards)
            guard shelf.items.indices.contains(target) else { return }
            withAnimation(.easeInOut(duration: 0.35)) { position = shelf.items[target].id }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 22, height: 22)
        }
        .buttonBorderShape(.circle)
        .glassActionStyle()
        .controlSize(.extraLarge)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, max(0, artwork / 2 - 22))
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        // Hidden: out of the keyboard loop too.
        .disabled(!visible)
        .animation(.easeOut(duration: 0.15), value: visible)
        // The row itself scrolls with VoiceOver; the chevrons are a pointer affordance.
        .accessibilityHidden(true)
    }
    #endif
}

#if os(macOS)
/// Which way a shelf can still scroll.
private struct HomeShelfEnds: Equatable {
    var back = false
    var forward = false
}

/// Reads a row's ends from its scroll view (macOS 15+; before, the row
/// counts its cards).
private struct HomeShelfEndsReader: ViewModifier {
    let onChange: (HomeShelfEnds) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: HomeShelfEnds.self) { geometry in
                HomeShelfEnds(back: geometry.contentOffset.x > 1 - geometry.contentInsets.leading,
                              forward: geometry.contentOffset.x + geometry.containerSize.width
                                  < geometry.contentSize.width + geometry.contentInsets.trailing - 1)
            } action: { _, ends in
                onChange(ends)
            }
        } else {
            content
        }
    }
}
#endif

/// A title card's menu (`HomeCardMenu`); none on a card that is not a
/// title (the « Services » row's): not even an empty one.
private struct HomeTitleMenu: ViewModifier {
    let item: HomeItem
    let shelfID: String
    let isOn: Bool
    let open: (HomeSelection) -> Void

    func body(content: Content) -> some View {
        if isOn {
            content.contextMenu { HomeCardMenu(item: item, shelfID: shelfID, open: open) }
        } else {
            content
        }
    }
}

/// A shelf's title and, facing it, "See All" when a grid lists more.
struct HomeShelfHeader: View {
    let title: String
    let layout: HomeLayout
    var seeAll: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: title)
                .font(HomeFont.shelfTitle(layout.sizeClass))
                .foregroundStyle(GlassPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let seeAll {
                Button(action: seeAll) {
                    HStack(spacing: 3) {
                        Text("Home.SeeAll")
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .fontWeight(.bold)
                    }
                    .font(HomeFont.shelfAction)
                    .foregroundStyle(GlassPalette.secondaryText)
                    // A comfortable target around a small label.
                    .padding(.vertical, 6)
                    .padding(.leading, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Home.SeeAll".localized + ", " + title))
                .fixedSize()
            }
        }
        .padding(.horizontal, layout.sideInset)
    }
}

/// A shelf that is still loading: the row's shape, without content.
struct HomeShelfSkeleton: View {
    let style: HomeShelf.Style
    let layout: HomeLayout
    let text: HomeCardText

    var body: some View {
        VStack(alignment: .leading, spacing: layout.headerSpacing) {
            Text(verbatim: "Placeholder shelf")
                .font(HomeFont.shelfTitle(layout.sizeClass))
                .padding(.horizontal, layout.sideInset)
            // Not a scroll view: there is nothing to scroll to yet.
            HStack(alignment: .top, spacing: layout.cardSpacing) {
                ForEach(0..<count, id: \.self) { index in
                    switch style {
                    case .landscape:
                        HomeLandscapeCard(item: .skeleton(index), shelfID: "skeleton", layout: layout, text: text, isSkeleton: true)
                    case .ranked:
                        HomeRankedCard(item: .skeleton(index, rank: index + 1), shelfID: "skeleton", layout: layout, text: text, isSkeleton: true)
                    case .posters, .hero:
                        HomePosterCard(item: .skeleton(index), shelfID: "skeleton", layout: layout, text: text, isSkeleton: true)
                    }
                }
            }
            .padding(.leading, layout.sideInset)
            .frame(width: layout.width, alignment: .leading)
            .clipped()
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    /// As many cards as the row shows, the cut one included.
    private var count: Int {
        let width = style == .landscape ? layout.landscapeWidth : layout.posterWidth
        return Int((layout.width / (width + layout.cardSpacing)).rounded(.up))
    }
}
