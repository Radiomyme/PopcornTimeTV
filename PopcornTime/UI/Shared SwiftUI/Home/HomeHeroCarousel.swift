// HomeHeroCarousel.swift — the carousel at the top of the Home (iOS and
// macOS): the featured titles, one page each — the backdrop edge to edge
// under the top bar, melting into the page's background; the title's logo
// (or its name), what it is, its badges, its synopsis where there is room,
// and Play / Watchlist / Information.
//
// The pages turn by themselves every few seconds (`HomeHeroPager`): not
// while a finger or a pointer is on them, not off screen, never with
// Reduce Motion. Swiping turns them at any time; on the Mac, so do the
// glass chevrons that show under the pointer and the ← → keys
// (`HomeControls`).
import Foundation
import SwiftUI
import PopcornKit

struct HomeHeroCarousel: View {
    let items: [HomeItem]
    let layout: HomeLayout
    let text: HomeCardText
    /// The top safe area the artwork runs under.
    let topInset: CGFloat
    /// The Home is the screen in front (not covered by a page, its tab shown).
    let isActive: Bool
    /// The page shown first, which then stays (verification launches).
    var pinnedPage: Int? = nil
    let open: (HomeSelection) -> Void

    @State private var pager = HomeHeroPager()
    /// The id of the page the scroll view rests on.
    @State private var position: String?
    /// The carousel has not scrolled out of the page.
    @State private var isInView = true
    /// The part of the carousel under bars at its sides: the iPad's sidebar
    /// in landscape. The pages run under it (`HomeHeroPage.leadingInset`).
    @State private var sideInsets = HomeHeroSides()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    /// The keyboard and the pointer (the Mac); nil on iOS.
    @Environment(\.homeControls) private var controls

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    HomeHeroPage(item: item, layout: layout, text: text, topInset: topInset,
                                 leadingInset: sideInsets.leading, trailingInset: sideInsets.trailing, open: open)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $position)
        // The iPad's sidebar in landscape floats over the page, and its
        // width is a safe area at the carousel's side. A scroll view puts
        // its content after that inset: the pages would be as wide as the
        // part beside the bar, and the end of the page before would show
        // under the bar's glass. So the pages ignore it — each is as wide
        // as the carousel and draws its own artwork under the bar — and
        // only their text keeps clear of it. (Measured outside the
        // modifier: inside it, the scroll view has no safe area left.)
        .ignoresSafeArea(.container, edges: .horizontal)
        .onGeometryChange(for: HomeHeroSides.self) {
            HomeHeroSides(leading: $0.safeAreaInsets.leading, trailing: $0.safeAreaInsets.trailing)
        } action: { sideInsets = $0 }
        .frame(height: layout.heroHeight)
        .overlay(alignment: layout.centersHero ? .bottom : .bottomTrailing) {
            if items.count > 1 {
                HomeHeroIndicators(count: items.count, current: pager.frontIndex)
                    .padding(.bottom, layout.centersHero ? 10 : 22)
                    .padding(.trailing, layout.centersHero ? 0 : layout.sideInset)
            }
        }
        #if os(macOS)
        .overlay(alignment: .leading) { chevron(forward: false) }
        .overlay(alignment: .trailing) { chevron(forward: true) }
        #endif
        .onHover { pager.isHovered = $0 }
        .modifier(HomeScrollActivity(touched: { pager.isTouched = $0 }, inView: { isInView = $0 }))
        .onChange(of: position) { _, new in
            if let new { pager.current = new }
        }
        // ← → while the keyboard is on the carousel.
        .onChange(of: controls?.heroTurn) { _, asked in
            if let asked { turn(forward: asked.forward) }
        }
        // What Return opens while no card is picked — and only while the
        // carousel shows.
        .onChange(of: pager.front, initial: true) { _, front in controls?.heroFront = front }
        // The next page's backdrop and logo are fetched while this one
        // shows (PopcornKit's `ArtworkPrefetcher`): a turn finds them decoded.
        .onChange(of: pager.next, initial: true) { _, next in
            guard let next, let item = items.first(where: { $0.id == next }) else { return }
            HomeHeroPage.prefetch(item, layout: layout, scale: displayScale)
        }
        .onChange(of: isInView, initial: true) { _, shows in controls?.heroShows = shows }
        .onChange(of: items.map(\.id), initial: true) { _, ids in
            pager.update(pages: ids)
            if let pinnedPage, position == nil, ids.indices.contains(pinnedPage) { pager.current = ids[pinnedPage] }
            // The scroll view rests where the pager says: on the page it
            // was on while that page is still featured, else on the first.
            if position != pager.front { position = pager.front }
        }
        .onChange(of: reduceMotion, initial: true) { _, reduce in pager.reducesMotion = reduce }
        .onChange(of: isVisible, initial: true) { _, visible in pager.isVisible = visible }
        .task(id: Turn(front: pager.front, runs: pager.autoAdvances && pinnedPage == nil)) {
            // One wait per page in front: any change — a swipe, a finger
            // down, the page hidden — starts it again from zero.
            guard pager.autoAdvances, pinnedPage == nil else { return }
            try? await Task.sleep(for: .seconds(HomeHeroPager.interval))
            guard !Task.isCancelled, pager.autoAdvances else { return }
            turn(forward: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Home.Hero")
    }

    private var isVisible: Bool {
        isActive && isInView && scenePhase == .active
    }

    /// To the next or the previous page, the first after the last.
    private func turn(forward: Bool) {
        guard let target = forward ? pager.next : pager.previous else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { position = target }
    }

    #if os(macOS)
    /// A glass chevron on the carousel's edge while the pointer is over
    /// it: a mouse has no sideways swipe. The same control as the shelves'.
    private func chevron(forward: Bool) -> some View {
        let visible = items.count > 1 && (pager.isHovered || controls?.shownAsHovered == HomeShelfID.hero)
        return Button {
            turn(forward: forward)
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 14, weight: .bold))
                .frame(width: 18, height: 18)
        }
        .buttonBorderShape(.circle)
        .glassActionStyle()
        .controlSize(.large)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        // In the page's margin: clear of the title and the text column.
        // (An overlay keeps clear of a bar over the page's side by itself:
        // its content stays in the safe area the pages ignore.)
        .padding(.horizontal, 8)
        // Centred on the artwork that shows under the window's bar.
        .padding(.top, topInset)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        // Hidden: out of the keyboard loop too.
        .disabled(!visible)
        .animation(.easeOut(duration: 0.15), value: visible)
        // VoiceOver scrolls the carousel itself; the chevrons are a pointer affordance.
        .accessibilityHidden(true)
    }
    #endif

    private struct Turn: Equatable {
        let front: String?
        let runs: Bool
    }
}

/// The carousel's side safe areas (the iPad's sidebar in landscape).
struct HomeHeroSides: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

/// What the scroll views say about the carousel: a finger is on it, and it
/// is still in the page's visible part. Both need iOS 18 / macOS 15; before,
/// the Mac's pointer still pauses the carousel (`onHover`).
private struct HomeScrollActivity: ViewModifier {
    let touched: (Bool) -> Void
    let inView: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    touched(phase == .tracking || phase == .interacting || phase == .decelerating)
                }
                .onScrollVisibilityChange(threshold: 0.4) { inView($0) }
        } else {
            content
        }
    }
}

/// The dots under the hero: the page in front is a longer mark.
private struct HomeHeroIndicators: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == current ? 0.95 : 0.38))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }
}

// MARK: - One page

extension HomeHeroPage {
    /// Starts loading `item`'s backdrop and logo at the sizes its page
    /// draws them (`HomeArtwork` then finds them in memory).
    static func prefetch(_ item: HomeItem, layout: HomeLayout, scale: CGFloat) {
        if let backdrop = item.backdropURL {
            ArtworkPrefetcher.shared.prefetch(urls: [backdrop], width: layout.heroPixelSize(scale: scale))
        }
        if let logo = item.logoURL {
            ArtworkPrefetcher.shared.prefetch(urls: [logo], width: (layout.heroLogoSize.width * scale).rounded(.up))
        }
    }
}

struct HomeHeroPage: View {
    let item: HomeItem
    let layout: HomeLayout
    let text: HomeCardText
    let topInset: CGFloat
    /// The bars over the page's sides (the iPad's sidebar in landscape):
    /// the artwork runs under them, the text keeps clear of them.
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    let open: (HomeSelection) -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.homeLibraryVersion) private var libraryVersion

    private var centered: Bool { layout.centersHero }
    /// The page, bars included.
    private var pageWidth: CGFloat { layout.width + leadingInset + trailingInset }

    private func selection(_ intent: HomeSelection.Intent) -> HomeSelection {
        HomeSelection(item: item, shelfID: HomeShelfID.hero, intent: intent)
    }

    var body: some View {
        ZStack(alignment: centered ? .bottom : .bottomLeading) {
            backdrop
            shade
            content
        }
        // A fixed box: the backdrop is wider than the page (16:9 filling a
        // taller frame), and a flexible frame would grow to it.
        .frame(width: pageWidth, height: layout.heroHeight)
        .clipped()
        .contentShape(Rectangle())
        // The artwork opens the page; the buttons sit above it.
        .onTapGesture { open(selection(.details)) }
        .homeCardSource(id: selection(.details).sourceID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: text.accessibilityLabel(of: item)))
        .accessibilityIdentifier("Home.Hero.\(item.id)")
    }

    private var backdrop: some View {
        HomeArtwork(urls: [item.backdropURL].compactMap { $0 }, maxPixelSize: layout.heroPixelSize(scale: displayScale)) { _ in
            HomePalette.placeholder
        }
        .frame(width: pageWidth, height: layout.heroHeight)
        .clipped()
        .accessibilityHidden(true)
    }

    /// What keeps the text readable on any artwork, and the artwork's
    /// bottom edge out of sight: it ends on the page's background.
    private var shade: some View {
        ZStack {
            // Under the clock and the top bar's buttons.
            LinearGradient(colors: [Color.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: topInset + 56)
                .frame(maxHeight: .infinity, alignment: .top)
            if !centered {
                // The text column's side.
                LinearGradient(colors: [HomePalette.background.opacity(0.72), HomePalette.background.opacity(0.3), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: leadingInset + layout.width * 0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .clear, location: centered ? 0.34 : 0.42),
                                   .init(color: HomePalette.background.opacity(0.62), location: centered ? 0.66 : 0.74),
                                   .init(color: HomePalette.background.opacity(0.94), location: 0.9),
                                   .init(color: HomePalette.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var content: some View {
        VStack(alignment: centered ? .center : .leading, spacing: centered ? 10 : 12) {
            HomeHeroLogo(item: item, layout: layout)
            facts
            if !item.badges.isEmpty { badges }
            if layout.showsHeroSynopsis, let summary = text.heroSynopsis(of: item) {
                Text(verbatim: summary)
                    .font(HomeFont.heroSynopsis)
                    .foregroundStyle(GlassPalette.primaryText.opacity(0.86))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
                .padding(.top, centered ? 4 : 6)
        }
        .frame(width: layout.heroTextWidth, alignment: centered ? .center : .leading)
        .padding(.leading, centered ? 0 : layout.sideInset)
        .padding(.bottom, centered ? 36 : 30)
        // Beside the bars, centred in the part of the page they leave.
        .padding(.leading, leadingInset)
        .padding(.trailing, centered ? trailingInset : 0)
    }

    /// "★ 8,1 · Film · 2026 · 2 h 14 min · Action".
    private var facts: some View {
        HStack(spacing: 6) {
            if let rating = text.rating(of: item) {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(GlassPalette.star)
                Text(verbatim: rating).fontWeight(.semibold)
                Text(verbatim: "·")
            }
            Text(verbatim: text.heroFacts(of: item, genres: centered ? 1 : 2))
        }
        .font(HomeFont.heroFacts)
        .foregroundStyle(GlassPalette.primaryText.opacity(0.92))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
    }

    private var badges: some View {
        HStack(spacing: 6) {
            // As on the cards: "DV" says HDR too.
            let shown = item.badges.filter { $0 != .hdr || !item.badges.contains(.dolbyVision) }
            ForEach(shown.prefix(centered ? 4 : 5), id: \.self) { badge in
                // The cards' badge, larger: the same shape and capitals.
                HomeBadgePill(label: text.cardLabel(of: badge),
                              tone: HomeBadgePill.tone(of: badge), size: .large)
            }
            // Which episode is new, and when: "S2 · É9 · ven. 13 nov.".
            if let episode = HomeTitleFacts.shared.newEpisode(of: item) {
                Text(verbatim: [text.number(of: episode), episode.airDate.map(text.day)].compactMap { $0 }.joined(separator: " · "))
                    .font(HomeFont.heroFacts.weight(.semibold))
                    .foregroundStyle(GlassPalette.primaryText)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    .padding(.leading, 2)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button {
                open(selection(.play))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.headline)
                .frame(minWidth: centered ? 148 : 120, minHeight: 36)
            }
            .homePrimaryActionStyle()
            .accessibilityIdentifier("Home.Hero.Play")

            let inWatchlist = HomeLibraryActions.isInWatchlist(item)
            let watchlistLabel: LocalizedStringKey = inWatchlist ? "Remove from Watchlist" : "Add to Watchlist"
            Button {
                HomeLibraryActions.toggleWatchlist(item)
            } label: {
                Image(systemName: inWatchlist ? "checkmark" : "plus")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 36)
            }
            .glassActionStyle()
            .accessibilityLabel(Text(watchlistLabel))
            .accessibilityIdentifier("Home.Hero.Watchlist")

            Button {
                open(selection(.details))
            } label: {
                Image(systemName: "info")
                    .font(.title3)
                    .frame(width: 30, height: 36)
            }
            .glassActionStyle()
            .accessibilityLabel(Text("Information"))
            .accessibilityIdentifier("Home.Hero.Info")
        }
    }
}

/// The title of a hero page: its logo, in a box of a fixed size, or its
/// name in type — while the logo is on its way (a hero never shows Play
/// without saying what it plays; the logo fades in over it), when the title
/// has none, and when its logo would not read on the dark artwork:
/// - a logo drawn in black or nearly (made for a light page) is drawn as a
///   white silhouette;
/// - a coloured logo too dark for the shade (under 3:1) gives way to the
///   name in type.
private struct HomeHeroLogo: View {
    let item: HomeItem
    let layout: HomeLayout

    @Environment(\.displayScale) private var displayScale
    @State private var logo: HomeMeasuredLogo?

    init(item: HomeItem, layout: HomeLayout) {
        self.item = item
        self.layout = layout
        _logo = State(initialValue: item.logoURL.flatMap { HomeMeasuredLogo.cached($0) })
    }

    var body: some View {
        let size = layout.heroLogoSize
        let alignment: Alignment = layout.centersHero ? .bottom : .bottomLeading
        ZStack(alignment: alignment) {
            if let logo, logo.isReadable {
                Image(glassImage: logo.image)
                    .renderingMode(logo.isDark ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.white)
                    .transition(.opacity)
            } else {
                Text(verbatim: item.title)
                    .font(HomeFont.heroTitle(layout.sizeClass))
                    .foregroundStyle(GlassPalette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(layout.centersHero ? .center : .leading)
                    // Gone at once when the logo comes: the logo fades in
                    // alone, never drawn over the title in type.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .frame(width: size.width, height: size.height, alignment: alignment)
        .shadow(color: .black.opacity(0.5), radius: 12, y: 2)
        .accessibilityHidden(true)
        .task(id: item.logoURL) {
            guard let url = item.logoURL, logo == nil else { return }
            let pixels = (max(size.width, size.height) * displayScale).rounded(.up)
            guard let image = await GlassImageCache.shared.image(for: url, maxPixelSize: pixels), !Task.isCancelled else { return }
            let measured = await Task.detached(priority: .userInitiated) { HomeMeasuredLogo.measure(image) }.value
            guard !Task.isCancelled else { return }
            HomeMeasuredLogo.store(measured, for: url)
            withAnimation(.easeOut(duration: 0.25)) { logo = measured }
        }
    }
}

/// A title's logo as the Home's dark artwork needs it, measured once off
/// the main thread on a 32 × 32 thumbnail (the Apple TV billboard's rule):
/// its transparent margins cut off, whether it is black (drawn white) or
/// too dark to read (not drawn: the name in type).
final class HomeMeasuredLogo: @unchecked Sendable {
    let image: GlassPlatformImage
    let isDark: Bool
    let isLowContrast: Bool

    var isReadable: Bool { !isLowContrast }

    init(image: GlassPlatformImage, isDark: Bool = false, isLowContrast: Bool = false) {
        self.image = image
        self.isDark = isDark
        self.isLowContrast = isLowContrast
    }

    private static let cache: NSCache<NSURL, HomeMeasuredLogo> = {
        let cache = NSCache<NSURL, HomeMeasuredLogo>()
        cache.countLimit = 40
        return cache
    }()

    static func cached(_ url: URL) -> HomeMeasuredLogo? { cache.object(forKey: url as NSURL) }
    static func store(_ logo: HomeMeasuredLogo, for url: URL) { cache.setObject(logo, forKey: url as NSURL) }

    nonisolated static func measure(_ image: GlassPlatformImage) -> HomeMeasuredLogo {
        let side = 32
        guard let cgImage = image.glassCGImage,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return HomeMeasuredLogo(image: image)
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return HomeMeasuredLogo(image: image) }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var luminance = 0.0, luma = 0.0, alpha = 0.0
        var minX = side, maxX = -1, minY = side, maxY = -1
        for y in 0..<side {
            for x in 0..<side {
                let index = (y * side + x) * 4
                let a = Double(pixels[index + 3])
                // Premultiplied: the luma is already weighted by the alpha.
                luma += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
                if a > 0 {
                    func linear(_ value: UInt8) -> Double {
                        let c = min(Double(value) / a, 1)
                        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                    }
                    luminance += a * (0.2126 * linear(pixels[index]) + 0.7152 * linear(pixels[index + 1]) + 0.0722 * linear(pixels[index + 2]))
                }
                alpha += a
                if pixels[index + 3] > 20 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard alpha > 0, maxX >= minX, maxY >= minY else { return HomeMeasuredLogo(image: image) }
        let isDark = luma / alpha < 0.16
        // (L + 0.05) / (0.02 + 0.05) < 3 against the shade's ~0.02.
        let isLowContrast = !isDark && luminance / alpha < 0.16
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height), cells = CGFloat(side)
        let crop = CGRect(x: CGFloat(max(minX - 1, 0)) / cells * width, y: CGFloat(max(minY - 1, 0)) / cells * height,
                          width: CGFloat(min(maxX + 2, side) - max(minX - 1, 0)) / cells * width,
                          height: CGFloat(min(maxY + 2, side) - max(minY - 1, 0)) / cells * height).integral
        guard crop.width < width - 1 || crop.height < height - 1, let cropped = cgImage.cropping(to: crop) else {
            return HomeMeasuredLogo(image: image, isDark: isDark, isLowContrast: isLowContrast)
        }
        return HomeMeasuredLogo(image: .glassImage(cropped), isDark: isDark, isLowContrast: isLowContrast)
    }
}
