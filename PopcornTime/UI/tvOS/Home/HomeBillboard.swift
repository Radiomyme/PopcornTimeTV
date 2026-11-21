// HomeBillboard.swift — the billboard of the Home tab. At the top of the
// page it presents the hero items (logo or title, facts, pills, synopsis,
// Play / More Info / Watchlist, page dots); once the focus is in the shelves
// a compact form of it stays at the top of the screen and shows the focused
// card. Also here: what takes the billboard's place while the hub loads or
// when it could not.
//
// The pieces have fixed slots (title, pills, facts, synopsis): changing the
// title never moves what is under it.
import SwiftUI
import PopcornKit

// MARK: - Title, facts, pills, synopsis

struct HomeBillboardInfo: View {
    let item: HomeItem
    /// The form shown over the shelves: smaller, two lines of synopsis.
    let compact: Bool
    let text: HomeText

    @State private var logoLoaded: Bool

    init(item: HomeItem, compact: Bool, text: HomeText) {
        self.item = item
        self.compact = compact
        self.text = text
        // A logo already decoded is shown at once, without the title in
        // type under it for a frame.
        let cached = HomeBillboardInfo.logoURL(of: item).flatMap {
            HomeLogoImage.cached($0, maxPixelSize: HomeBillboardInfo.logoPixels(compact: compact))
        }
        _logoLoaded = State(initialValue: cached.map { $0.fits(minimumAspect: compact ? 1.2 : 0) } ?? false)
    }

    /// The card's logo, else metahub's by IMDb id (it may not exist: the
    /// title then stays in type).
    private static func logoURL(of item: HomeItem) -> URL? {
        return item.logoURL ?? OpenMetadata.logoURL(imdbId: item.imdbId)
    }

    private static func logoPixels(compact: Bool) -> CGFloat {
        return homePixels(compact ? 520 : 680)
    }

    private var badges: [HomeBadge] { item.badges }
    private var progressNote: String? { text.progressNote(of: item) }
    private var hasPills: Bool { !badges.isEmpty || progressNote != nil }
    /// The hero gives a title without pills their room; the compact
    /// billboard always keeps the pills' row, empty or not: it changes
    /// title at every move along a row, and its title, pills and facts
    /// must stay where they are (the title jumped ~50 pt between a card
    /// with pills and one without).
    private var hasPillsRow: Bool { compact || hasPills }

    /// The compact slot holds a logo up to 82 pt high or two lines of
    /// title; a one-line title at its top leaves less of a gap above the
    /// pills than the 104 pt it had when it stood on them.
    private var titleHeight: CGFloat { compact ? 90 : 200 }
    /// The logo's box: its slot, the pills' room too when there are none.
    private var logoBox: HomeLogoBox {
        let slot = titleHeight + (hasPillsRow ? 0 : pillsHeight)
        return compact ? .compact(height: min(slot - 8, 140)) : .hero(height: min(slot - 10, 190))
    }
    /// The compact title stands at the top of its slot (its first line is
    /// where the eye looks for it at every move); the hero's on the pills.
    private var titleAlignment: Alignment { compact ? .topLeading : .bottomLeading }
    private var pillsHeight: CGFloat { compact ? 50 : 62 }
    private var summaryFont: Font { compact ? .system(size: 26, weight: .regular) : GlassFont.body }
    private var summaryLine: CGFloat { compact ? 35 : 41 }
    private var summaryLines: Int { compact ? 2 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Without pills the title takes their room: the lines under it
            // stay where they are.
            titleBlock
                .frame(height: titleHeight + (hasPillsRow ? 0 : pillsHeight), alignment: titleAlignment)
            if hasPillsRow {
                pillsRow
                    .frame(height: pillsHeight, alignment: .bottomLeading)
            }
            factsLine
                .frame(height: 38, alignment: .leading)
                .padding(.top, compact ? 12 : 18)
            // The sources' synopses are English: under another language
            // the billboard has no synopsis line (`HomeText.showsSourceText`),
            // and keeps its title, pills and facts; the band over the
            // shelves is then shorter (`TVHomeLayout.compactBandWithoutSynopsis`).
            if let summary = text.summary(of: item) {
                Text(verbatim: summary)
                    .font(summaryFont)
                    .lineSpacing(4)
                    .foregroundStyle(GlassPalette.primaryText.opacity(0.9))
                    .lineLimit(summaryLines)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
                    .frame(maxWidth: compact ? 860 : 900, alignment: .topLeading)
                    .frame(height: summaryLine * CGFloat(summaryLines), alignment: .topLeading)
                    .padding(.top, compact ? 8 : 14)
            }
        }
        .frame(width: 1040, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityIdentifier(compact ? "Home.Billboard" : "Home.Hero.Title")
    }

    private var accessibilityLabel: String {
        return ([item.title] + text.facts(of: item).map(\.string) + badges.map(text.label(of:)) + [text.summary(of: item) ?? ""])
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: Title

    /// The title's logo when the card has one and it loads; the title in
    /// type meanwhile, and for good when it does not.
    private var titleBlock: some View {
        let logoURL = HomeBillboardInfo.logoURL(of: item)
        return ZStack(alignment: titleAlignment) {
            if let logoURL {
                HomeLogoImage(url: logoURL, maxPixelSize: HomeBillboardInfo.logoPixels(compact: compact),
                              minimumAspect: compact ? 1.2 : 0, box: logoBox) { logoLoaded = true }
                    .frame(maxWidth: logoBox.maxWidth, maxHeight: logoBox.maxHeight, alignment: titleAlignment)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
            }
            if logoURL == nil || !logoLoaded {
                // Not a working title nobody could correct ("Untitled …",
                // D3): the panel then says nothing until the logo comes.
                Text(verbatim: item.cardTitle)
                    .font(.system(size: compact ? 52 : 76, weight: .heavy))
                    .foregroundStyle(GlassPalette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.55), radius: 14, y: 4)
                    // Compact, at the top of its slot: the capitals' top
                    // on the logos' top (the line's leading above them is
                    // ~13 pt at this size; measured on screen).
                    .padding(.top, compact ? -13 : 0)
                    .frame(maxWidth: 1000, alignment: titleAlignment)
                    // Gone at once when the logo comes: the logo fades in
                    // alone, never drawn over the title in type.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: logoLoaded)
    }

    // MARK: Pills

    /// "New" in the cards' red pill, the formats as outlined chips; a resume
    /// card: its progress and what is left.
    private var pillsRow: some View {
        HStack(spacing: 12) {
            if let progress = item.progress, progress > 0 {
                GlassProgressBar(progress: progress, height: 7)
                    .frame(width: 240)
            }
            if let progressNote {
                Text(verbatim: progressNote)
                    .font(GlassFont.captionBold)
                    .foregroundStyle(GlassPalette.primaryText)
                    .padding(.trailing, 8)
            }
            ForEach(badges, id: \.self) { badge in
                if badge.isFormat {
                    GlassChip(text: badge.label, fontSize: compact ? 20 : 22)
                } else {
                    // What is new: the cards' red pill, one drawing of it
                    // across the app (`HomeCardBadge`), a size up.
                    Image(uiImage: GridPill.image(text.label(of: badge).uppercased(with: text.locale), style: .accent,
                                                  font: .systemFont(ofSize: compact ? 19 : 21, weight: .bold)))
                        .fixedSize()
                }
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }

    // MARK: Facts

    private var factsLine: some View {
        let facts = text.facts(of: item)
        return HStack(spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 {
                    Text(verbatim: "  ·  ").foregroundStyle(GlassPalette.tertiaryText)
                }
                switch fact {
                case .text(let string):
                    Text(verbatim: string)
                case .rating(let rating):
                    HStack(spacing: 7) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(GlassPalette.star)
                        Text(verbatim: rating)
                    }
                }
            }
        }
        .font(GlassFont.metadata)
        .foregroundStyle(GlassPalette.primaryText.opacity(0.9))
        .lineLimit(1)
        .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
    }
}

// MARK: - Logo

/// The size a title's logo is drawn at: the same area whatever its shape —
/// a wide banner ("Severance") and a square stack ("Black Doves") read as
/// the same weight — within a minimum width and a maximum height.
struct HomeLogoBox: Equatable {
    var area: CGFloat
    var minWidth: CGFloat
    var maxWidth: CGFloat
    var maxHeight: CGFloat

    /// The compact billboard over the shelves: about 400 × 120.
    static func compact(height: CGFloat) -> HomeLogoBox {
        return HomeLogoBox(area: 400 * 120, minWidth: 260, maxWidth: 520, maxHeight: height)
    }

    /// The hero billboard and the detail page.
    static func hero(height: CGFloat) -> HomeLogoBox {
        return HomeLogoBox(area: 560 * 170, minWidth: 340, maxWidth: 680, maxHeight: height)
    }

    func size(of image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let aspect = image.width / image.height
        var width = (area * aspect).squareRoot()
        width = min(max(width, minWidth), maxWidth)
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}

/// A title's logo, bottom-left in its frame, as the Home's dark backdrops
/// need it. Measured once, off the main thread, on a thumbnail of it:
/// - its transparent margins are cut off (many logos float in a wider
///   canvas: the title then started right of the page's left margin, and
///   looked smaller than its slot);
/// - a logo drawn in black or a dark colour, for a light page, is shown as
///   a white silhouette.
struct HomeLogoImage: View {
    let url: URL
    let maxPixelSize: CGFloat
    /// A logo less wide than this for its height is not drawn (and
    /// `onLoad` not called): in the compact billboard's low slot a square
    /// emblem is a stamp, and the title in type says more.
    var minimumAspect: CGFloat = 0
    /// The size it is drawn at (`HomeLogoBox`); none: as big as its frame lets it.
    var box: HomeLogoBox? = nil
    let onLoad: () -> Void

    @State private var logo: Logo?

    final class Logo: @unchecked Sendable {
        let image: GlassPlatformImage
        let isDark: Bool
        /// Coloured, but too dark for the veil (under 3:1): the title is
        /// shown in type instead (a white silhouette of a filled logo is a blob).
        let isLowContrast: Bool

        init(image: GlassPlatformImage, isDark: Bool, isLowContrast: Bool = false) {
            self.image = image
            self.isDark = isDark
            self.isLowContrast = isLowContrast
        }

        func fits(minimumAspect: CGFloat) -> Bool {
            return !isLowContrast && image.size.width >= image.size.height * minimumAspect
        }
    }

    init(url: URL, maxPixelSize: CGFloat, minimumAspect: CGFloat = 0, box: HomeLogoBox? = nil, onLoad: @escaping () -> Void) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.minimumAspect = minimumAspect
        self.box = box
        self.onLoad = onLoad
        _logo = State(initialValue: HomeLogoImage.cached(url, maxPixelSize: maxPixelSize))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let logo, logo.fits(minimumAspect: minimumAspect) {
                let size = box?.size(of: logo.image.size)
                Image(glassImage: logo.image)
                    .renderingMode(logo.isDark ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.white)
                    .frame(width: size?.width, height: size?.height)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            if let logo { return logo.fits(minimumAspect: minimumAspect) ? onLoad() : () }
            guard let image = await GlassImageCache.shared.image(for: url, maxPixelSize: maxPixelSize), !Task.isCancelled else { return }
            let prepared = await Task.detached(priority: .userInitiated) { HomeLogoImage.prepare(image) }.value
            guard !Task.isCancelled else { return }
            // A cropped logo keeps its whole decoded image: that is its cost.
            let cost = image.glassCGImage.map { $0.bytesPerRow * $0.height } ?? 0
            HomeLogoImage.prepared.setObject(prepared, forKey: HomeLogoImage.key(url, maxPixelSize), cost: cost)
            withAnimation(.easeOut(duration: 0.25)) { logo = prepared }
            if prepared.fits(minimumAspect: minimumAspect) { onLoad() }
        }
    }

    /// The relative luminance a logo needs for 3:1 on the Home's veil.
    nonisolated static let minimumLuminance = 0.16

    /// The logos already measured: one seen before is drawn at once. Bound
    /// in bytes too (a logo is up to ~1360 px wide, some 2–3 MB decoded):
    /// these are outside the artwork pipeline's own memory bound.
    private static let prepared: NSCache<NSString, Logo> = {
        let cache = NSCache<NSString, Logo>()
        cache.countLimit = 80
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    private static func key(_ url: URL, _ maxPixelSize: CGFloat) -> NSString {
        return "\(Int(maxPixelSize))|\(url.absoluteString)" as NSString
    }

    /// The logo when it is decoded and measured already (no I/O).
    static func cached(_ url: URL, maxPixelSize: CGFloat) -> Logo? {
        return prepared.object(forKey: key(url, maxPixelSize))
    }

    /// Measures a logo on a 32 × 32 thumbnail: what it draws (its
    /// transparent margins cut off, one cell of the thumbnail kept around
    /// it) and whether it reads on the Home's dark veil, the transparent
    /// pixels left out:
    /// - black or nearly (an average luma under a sixth of white, a logo
    ///   for a light page): drawn as a white silhouette;
    /// - coloured but under 3:1 against near-black (its average WCAG
    ///   relative luminance: a dark red "Black Doves", a navy blue): not
    ///   drawn, the title stays in type.
    nonisolated static func prepare(_ image: GlassPlatformImage) -> Logo {
        let side = 32
        guard let cgImage = image.glassCGImage,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Logo(image: image, isDark: false)
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return Logo(image: image, isDark: false) }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var luminance = 0.0, luma = 0.0, alpha = 0.0
        var minX = side, maxX = -1, minY = side, maxY = -1
        for y in 0..<side {
            for x in 0..<side {
                let index = (y * side + x) * 4
                // Premultiplied: the luma is already weighted by the alpha;
                // for the relative luminance the colour is divided by it.
                let a = Double(pixels[index + 3])
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
        guard alpha > 0, maxX >= minX, maxY >= minY else { return Logo(image: image, isDark: false) }
        let isDark = luma / alpha < 0.16
        // (L + 0.05) / (0.02 + 0.05) < 3 against the veil's ~0.02.
        let isLowContrast = !isDark && luminance / alpha < HomeLogoImage.minimumLuminance
        // The rows of the bitmap context start at the top of the image.
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height), cells = CGFloat(side)
        let crop = CGRect(x: CGFloat(max(minX - 1, 0)) / cells * width, y: CGFloat(max(minY - 1, 0)) / cells * height,
                          width: CGFloat(min(maxX + 2, side) - max(minX - 1, 0)) / cells * width,
                          height: CGFloat(min(maxY + 2, side) - max(minY - 1, 0)) / cells * height).integral
        guard crop.width < width - 1 || crop.height < height - 1, let cropped = cgImage.cropping(to: crop) else {
            return Logo(image: image, isDark: isDark, isLowContrast: isLowContrast)
        }
        return Logo(image: .glassImage(cropped), isDark: isDark, isLowContrast: isLowContrast)
    }
}

// MARK: - The top of the page: the hero

/// The billboard on the hero items, with its buttons: the first screen of
/// the page, the first shelf showing under it.
struct HomeHeroHeader: View {
    let model: HomePageModel
    var focus: FocusState<HomeFocus?>.Binding
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            ZStack(alignment: .bottomLeading) {
                if let item = model.heroItem {
                    HomeBillboardInfo(item: item, compact: false, text: model.text)
                        .id(item.id)
                        .transition(.opacity)
                }
            }
            // Out of the way once the focus is in the shelves: the compact
            // billboard takes over. Not the buttons: one that is not drawn
            // cannot take the focus, and Up and Menu come back to them (they
            // are under the band's backdrop by then).
            .opacity(model.isInShelves ? 0 : 1)
            actionRow
                .padding(.top, 30)
        }
        .padding(.horizontal, TVHomeLayout.side)
        .padding(.bottom, 30)
        .frame(height: height, alignment: .bottomLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Home.Hero")
    }

    private var actionRow: some View {
        let item = model.heroItem
        // Read so the Watchlist button follows the library.
        let _ = model.libraryVersion
        let listed = item.map(model.actions.isInWatchlist) ?? false
        return HStack(alignment: .center, spacing: 30) {
            SwiftUI.Button {
                if let item { model.actions.play(item, nil) }
            } label: {
                Label("Home.Play", systemImage: "play.fill")
                    .font(GlassFont.bodyEmphasis)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 4)
            }
            // Neutral glass like its neighbours, solid white once focused
            // (`GlassPrimaryButtonStyle`), as Play on the title's page.
            .glassActionStyle(prominent: true)
            .focused(focus, equals: .play)
            .accessibilityIdentifier("Home.Play")

            SwiftUI.Button {
                if let item { model.actions.open(item, nil) }
            } label: {
                Label("More Info", systemImage: "info.circle")
                    .font(GlassFont.bodyEmphasis)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .glassActionStyle()
            .focused(focus, equals: .info)
            .accessibilityIdentifier("Home.Info")

            SwiftUI.Button {
                if let item { model.actions.toggleWatchlist(item) }
            } label: {
                Label("Watchlist", systemImage: listed ? "checkmark" : "plus")
                    .font(GlassFont.bodyEmphasis)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .glassActionStyle()
            .focused(focus, equals: .watchlist)
            .accessibilityLabel(listed ? Text("Remove from Watchlist") : Text("Add to Watchlist"))
            .accessibilityIdentifier("Home.Watchlist")

            Spacer(minLength: 40)
            HomePageDots(count: model.home.heroItems.count, index: model.heroIndex)
                .opacity(model.isInShelves ? 0 : 1)
        }
        .focusSection()
        .onMoveCommand { direction in
            model.heroMove(direction, focus: focus.wrappedValue)
        }
    }
}

/// Which hero item is shown: a longer dot among the others.
struct HomePageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<max(count, 0), id: \.self) { page in
                Capsule()
                    .fill(Color.white.opacity(page == index ? 0.95 : 0.34))
                    .frame(width: page == index ? 30 : 10, height: 10)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
        .opacity(count > 1 ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(index + 1) / \(count)"))
        .accessibilityIdentifier("Home.HeroPage")
        .accessibilityValue(Text(verbatim: "\(index)"))
    }
}

// MARK: - Over the shelves: the compact billboard

/// The focused card, at the top of the screen, while the focus is in the
/// shelves. Not focusable, not in the scroll view: it never moves.
struct HomeCompactBillboard: View {
    let model: HomePageModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let item = model.compactItem {
                HomeBillboardInfo(item: item, compact: true, text: model.text)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .frame(width: 1040, alignment: .topLeading)
        .padding(.leading, TVHomeLayout.side)
        // The screen's top safe margin; under the tab bar when it shows.
        .padding(.top, model.compactIsUnderTabBar ? TVHomeLayout.tabBarBand : 60)
    }
}

// MARK: - Instead of the billboard

/// The hub could not load and has nothing saved.
struct HomeErrorHeader: View {
    let isRefreshing: Bool
    var focus: FocusState<HomeFocus?>.Binding
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 84, weight: .semibold))
                .foregroundStyle(GlassPalette.secondaryText)
            Text("Home.Unavailable.Title")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(GlassPalette.primaryText)
            Text("Home.Unavailable.Message")
                .font(GlassFont.body)
                .foregroundStyle(GlassPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 980)
            // Not disabled while it refreshes: a disabled button cannot keep
            // the focus, and with nothing else on the page it would fall to
            // the tab bar (from the tab bar Menu goes to Home, and from Home
            // leaves the app: here, at once). A press then does nothing.
            SwiftUI.Button {
                if !isRefreshing { retry() }
            } label: {
                HStack(spacing: 14) {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Try Again")
                }
                .font(GlassFont.bodyEmphasis)
                .padding(.horizontal, 22)
                .padding(.vertical, 4)
            }
            .glassActionStyle(prominent: true)
            .focused(focus, equals: .retry)
            .padding(.top, 18)
            .accessibilityIdentifier("Home.Retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Home.Unavailable")
    }
}

/// Before the first data: the billboard's shapes, where its pieces will be.
struct HomeHeroSkeleton: View {
    let height: CGFloat
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            block(width: 460, height: 120, corner: 18)
            block(width: 560, height: 26, corner: 8).padding(.top, 38)
            VStack(alignment: .leading, spacing: 15) {
                block(width: 880, height: 24, corner: 8)
                block(width: 840, height: 24, corner: 8)
                block(width: 520, height: 24, corner: 8)
            }
            .padding(.top, 26)
            HStack(spacing: 30) {
                block(width: 230, height: 78, corner: 39)
                block(width: 270, height: 78, corner: 39)
                block(width: 210, height: 78, corner: 39)
            }
            .padding(.top, 36)
        }
        .padding(.horizontal, TVHomeLayout.side)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .bottomLeading)
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Spinner.Loading"))
        .accessibilityIdentifier("Home.Loading")
    }

    private func block(width: CGFloat, height: CGFloat, corner: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.white.opacity(0.13))
            .frame(width: width, height: height)
    }
}

/// The last refresh reached no source: what is shown was saved earlier.
struct HomeOfflineNote: View {
    var body: some View {
        Label("Home.Offline", systemImage: "wifi.slash")
            .font(GlassFont.captionBold)
            .foregroundStyle(GlassPalette.primaryText)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .glassSurface(Capsule(), fallback: .thinMaterial)
            .accessibilityIdentifier("Home.Offline")
    }
}
