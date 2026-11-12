// MacGlassDetailView.swift — the Liquid Glass movie / show page of the Mac
// app: the tvOS page's layout (GlassDetailView) in a resizable window, driven
// by the same GlassDetailModel / GlassDetailActions.
//
// Layout, top to bottom, in one vertical ScrollView over a fixed full-bleed
// artwork layer that extends under the window toolbar:
//   1. hero (first screen, window height minus a peek of the next section):
//      logo / title, metadata, chips, summary card, actions
//   2. shows: season pills, episode shelf, hovered-episode panel
//   3. "Viewers Also Watched", 4. "Cast & Crew", 5. Information / Accessibility
// Sections without data are hidden. Scrolled below the hero, the artwork
// blurs and darkens (GlassBackdropView's dimmed state).
import SwiftUI
import PopcornKit

/// Mac-only state of the page that GlassDetailModel does not carry. Owned by
/// MacGlassDetailController.
@Observable
final class MacGlassPageState {
    /// Episode whose sources (then subtitles) are being fetched: spinner on its still.
    var busyEpisodeID: String?
    /// Play is preparing (sources, subtitles): spinner in the Play button.
    var isPreparingPlay = false
    /// The Movie / Show behind each related item (NavigationLink values). Set
    /// before `model.related`, which redraws the shelf.
    @ObservationIgnored var relatedMedia: [String: Media] = [:]
    /// Play's context menu: always show the quality sheet.
    @ObservationIgnored var chooseQuality: () -> Void = {}
    /// An episode's context menu: the same for that episode.
    @ObservationIgnored var chooseEpisodeQuality: (_ episodeID: String) -> Void = { _ in }
}

struct MacGlassDetailView: View {
    let model: GlassDetailModel
    let actions: GlassDetailActions
    let page: MacGlassPageState

    @State private var artwork: GlassArtwork = .loading
    /// A third of the hero has scrolled away (dimmed artwork). Only this
    /// Bool is state: the offset itself changes on every scroll frame.
    @State private var isPastHero = false
    @State private var heroHeight: CGFloat = 1
    /// The scroll offset (and, macOS 14, the hero's top at rest), not state.
    @State private var scrollTracker = MacScrollTracker()
    /// Last hovered (or clicked) episode: what the episode panel shows.
    @State private var highlightedEpisodeID: String?
    #if DEBUG
    @State private var didDebugScroll = false
    #endif

    enum SectionID: String, Hashable {
        case hero, episodes, related, cast, info
    }

    private static let scrollSpace = "MacGlassDetailScroll"

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            MacGlassHeroView(model: model,
                                             actions: actions,
                                             page: page,
                                             posterCardURL: artwork.posterCardURL,
                                             onExpandSummary: expandSummary)
                                .frame(width: geo.size.width, alignment: .bottomLeading)
                                .frame(minHeight: max(400, geo.size.height - MacGlassMetrics.peek), alignment: .bottomLeading)
                                .background { heroTracker }
                                .id(SectionID.hero)

                            sections
                        }
                        .frame(width: geo.size.width, alignment: .leading)
                        .padding(.bottom, 56)
                    }
                    .coordinateSpace(name: Self.scrollSpace)
                    .macScrollMetrics(.vertical) { metrics in
                        scrollTracker.metrics = metrics
                        updateDimming(heroHeight: heroHeight)
                    }
                    .onPreferenceChange(MacHeroFrameKey.self) { [topInset = geo.safeAreaInsets.top] frame in
                        let height = max(frame.height, 1)
                        if height != heroHeight { heroHeight = height }
                        // macOS 14 only: 15+ reads the scroll geometry itself.
                        if #unavailable(macOS 15.0) {
                            scrollTracker.noteContent(y: frame.minY, inset: topInset)
                        }
                        updateDimming(heroHeight: height)
                    }
                    .onChange(of: geo.safeAreaInsets.top) { _, inset in
                        // After this layout's frame change, if any, has been
                        // seen (`noteContent` re-bases the rest by it).
                        guard #unavailable(macOS 15.0) else { return }
                        let tracker = scrollTracker
                        DispatchQueue.main.async { tracker.insetSettled(inset) }
                    }
                    #if DEBUG
                    .task(id: debugScrollReady) { await debugScroll(proxy) }
                    #endif
                }
                .disabled(model.expandedText != nil)
                .blur(radius: model.expandedText == nil ? 0 : 14)

                if let text = model.expandedText {
                    MacGlassTextSheet(text: text, maxHeight: geo.size.height - 60, onClose: closeSheet)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .zIndex(1)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background {
            GeometryReader { full in
                GlassBackdropView(artwork: artwork, dimmed: isDimmed, size: full.size)
                    .modifier(MacBackdropExtension())
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: model.expandedText)
        .task(id: ArtworkKey(backdrop: model.backdropURL, poster: model.posterURL)) {
            await loadArtwork()
        }
        .onChange(of: model.selectedSeason) { _, _ in highlightedEpisodeID = nil }
    }

    // MARK: Sections

    @ViewBuilder
    private var sections: some View {
        if model.kind == .show, !model.episodes.isEmpty || model.isLoadingEpisodes {
            MacGlassEpisodesSection(model: model,
                                    actions: actions,
                                    page: page,
                                    highlightedEpisodeID: $highlightedEpisodeID,
                                    onExpand: present)
                .id(SectionID.episodes)
        }
        if !model.related.isEmpty || model.isLoadingRelated {
            MacGlassRelatedShelf(items: model.related,
                                 isLoading: model.isLoadingRelated,
                                 page: page)
                .id(SectionID.related)
        }
        if !model.people.isEmpty || model.isLoadingPeople {
            MacGlassCastShelf(people: model.people, isLoading: model.isLoadingPeople)
                .id(SectionID.cast)
        }
        if !model.information.isEmpty || !model.accessibility.isEmpty {
            MacGlassInfoSection(information: model.information, accessibility: model.accessibility)
                .id(SectionID.info)
        }
    }

    // MARK: Scroll → dimmed artwork

    private var heroTracker: some View {
        GeometryReader { hero in
            Color.clear.preference(key: MacHeroFrameKey.self, value: hero.frame(in: .named(Self.scrollSpace)))
        }
    }

    /// Dimmed once a third of the hero has scrolled away (or under the text sheet).
    private var isDimmed: Bool {
        model.expandedText != nil || isPastHero
    }

    /// Writes `isPastHero` only when it flips: the page body is not
    /// re-evaluated on every scroll frame.
    private func updateDimming(heroHeight height: CGFloat) {
        let past = scrollTracker.metrics.offset > height * 0.33
        if past != isPastHero { isPastHero = past }
    }

    // MARK: Text sheet

    private func expandSummary() {
        present(GlassExpandedText(title: model.title,
                                  subtitle: model.metadata.joined(separator: "  ·  "),
                                  body: model.summary))
    }

    private func present(_ text: GlassExpandedText) {
        model.expandedText = text
    }

    private func closeSheet() {
        model.expandedText = nil
    }

    // MARK: Artwork

    private struct ArtworkKey: Hashable {
        let backdrop: URL?
        let poster: URL?
    }

    /// `model.backdropURL`, else `model.backdropFallbackURL` when the first
    /// gives no landscape image, else the poster as ambient light.
    private func loadArtwork() async {
        let loaded = await GlassArtwork.load(backdrop: model.backdropURL, fallbackBackdrop: model.backdropFallbackURL,
                                             poster: model.posterURL, maxPixelSize: MacGlassMetrics.backdropPixels)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.5)) { artwork = loaded }
    }

    // MARK: DEBUG scroll hook

    #if DEBUG
    /// Everything that changes the page's height has arrived.
    private var debugScrollReady: Bool {
        !model.isLoadingRelated && !model.isLoadingPeople && !model.isLoadingEpisodes
    }

    /// `-PTDebugScroll <hero|episodes|related|cast|info>`: scrolls the page
    /// there once its sections have loaded; `-PTDebugExpand
    /// <summary|episode>` then opens that text sheet (MacDebugHooks).
    private func debugScroll(_ proxy: ScrollViewProxy) async {
        let defaults = UserDefaults.standard
        let target = defaults.string(forKey: "PTDebugScroll").flatMap(SectionID.init(rawValue:))
        let expand = defaults.string(forKey: "PTDebugExpand")
        guard debugScrollReady, !didDebugScroll, target != nil || expand != nil else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled else { return }
        didDebugScroll = true
        if let target {
            print("[MacGlass] debug scroll to \(target.rawValue)")
            proxy.scrollTo(target, anchor: .top)
        }
        switch expand {
        case "summary"?:
            expandSummary()
        case "episode"?:
            let episodes = model.episodesOfSelectedSeason
            if let episode = episodes.first(where: { $0.id == model.upNextEpisodeID }) ?? episodes.first {
                present(GlassExpandedText(title: episode.title,
                                          subtitle: MacGlassEpisodePanel.subtitle(of: episode),
                                          body: episode.summary))
            }
        default:
            break
        }
    }
    #endif
}

private struct MacHeroFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// macOS 26: the artwork also shows (mirrored and blurred) under the
/// floating sidebar.
private struct MacBackdropExtension: ViewModifier {
    @Environment(\.glassFallback) private var fallback

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !fallback {
            content.backgroundExtensionEffect()
        } else {
            content
        }
    }
}

// MARK: - Hero

/// First screen: logo or title, metadata, capability chips, summary card and
/// the action row, bottom-left over the artwork (plus a poster card when the
/// artwork is only a poster).
struct MacGlassHeroView: View {
    let model: GlassDetailModel
    let actions: GlassDetailActions
    let page: MacGlassPageState
    /// The artwork is a poster (or missing): show the crisp poster card.
    let posterCardURL: URL?
    let onExpandSummary: () -> Void

    @State private var logoLoaded = false
    /// Starts true so the card is clickable until measured.
    @State private var summaryTruncated = true

    var body: some View {
        HStack(alignment: .bottom, spacing: 36) {
            if let posterCardURL {
                GlassPosterCard(url: posterCardURL, title: model.title, width: 210,
                                cornerRadius: 14, placeholderFont: MacGlassFont.bodyEmphasis)
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 0) {
                titleBlock
                    .padding(.bottom, 16)
                metadataLine
                    .padding(.bottom, model.badges.isEmpty ? 18 : 12)
                if !model.badges.isEmpty {
                    badgesRow
                        .padding(.bottom, 18)
                }
                if !model.summary.isEmpty {
                    summaryCard
                        .padding(.bottom, 22)
                }
                MacGlassActionRow(model: model, actions: actions, page: page)
            }
            .frame(maxWidth: MacGlassMetrics.heroMaxWidth, alignment: .leading)
        }
        .padding(.horizontal, MacGlassMetrics.sideInset)
        .padding(.top, 24)
        .padding(.bottom, 40)
        .animation(.easeOut(duration: 0.3), value: posterCardURL)
    }

    // MARK: Title

    private var titleBlock: some View {
        ZStack(alignment: .bottomLeading) {
            if let logoURL = model.logoURL {
                GlassRemoteImage(url: logoURL, maxPixelSize: 900, contentMode: .fit,
                                 alignment: .bottomLeading,
                                 onLoad: { _ in logoLoaded = true }) { EmptyView() }
                    .frame(maxWidth: 420, maxHeight: 150, alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
                    .accessibilityHidden(true)
            }
            if model.logoURL == nil || !logoLoaded {
                Text(verbatim: model.title)
                    .font(MacGlassFont.heroTitle)
                    .foregroundStyle(GlassPalette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: model.title))
        .accessibilityAddTraits(.isHeader)
        .animation(.easeOut(duration: 0.35), value: logoLoaded)
        .onChange(of: model.logoURL) { _, _ in logoLoaded = false }
    }

    // MARK: Metadata

    private var metadataLine: some View {
        HStack(alignment: .center, spacing: 12) {
            if !model.metadata.isEmpty {
                Text(verbatim: model.metadata.joined(separator: "  ·  "))
                    .font(MacGlassFont.metadata)
                    .foregroundStyle(GlassPalette.primaryText.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let certification = model.certification, !certification.isEmpty {
                GlassChip(text: certification, fontSize: 12)
            }
            if let rating = model.rating, rating > 0 {
                GlassStarRating(stars: rating, size: 13)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
    }

    private var badgesRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.badges.enumerated()), id: \.element.id) { index, badge in
                GlassChip(text: badge.text, systemImage: badge.systemImage, emphasized: index == 0, fontSize: 13)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }

    // MARK: Summary

    /// A clickable card with "MORE" (opens the full text) when the summary is
    /// cut at 3 lines; a plain glass card otherwise.
    @ViewBuilder
    private var summaryCard: some View {
        if summaryTruncated {
            Button(action: onExpandSummary) {
                VStack(alignment: .leading, spacing: 6) {
                    summaryText
                    Text("More")
                        .font(MacGlassFont.small)
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(GlassPalette.secondaryText)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .buttonStyle(MacGlassCardButtonStyle())
        } else {
            summaryText
                .foregroundStyle(GlassPalette.primaryText)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .glassPanel(cornerRadius: MacGlassMetrics.cardCorner)
        }
    }

    private var summaryText: some View {
        Text(verbatim: model.summary)
            .font(MacGlassFont.body)
            .lineSpacing(3)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassReportsTruncation(of: model.summary, font: MacGlassFont.body, lineSpacing: 3)
            .onPreferenceChange(GlassTruncationKey.self) { summaryTruncated = $0 }
    }
}

// MARK: - Action row

struct MacGlassActionRow: View {
    let model: GlassDetailModel
    let actions: GlassDetailActions
    let page: MacGlassPageState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let play = model.play {
                playButton(play)
            }
            if model.hasTrailer {
                Button(action: actions.playTrailer) {
                    Label("Trailer", systemImage: "film")
                        .font(MacGlassFont.bodyEmphasis)
                        .padding(.horizontal, 4)
                }
                .glassActionStyle()
                .controlSize(.extraLarge)
                .fixedSize()
            }
            MacGlassCircleAction(
                systemImage: model.isInWatchlist ? "checkmark" : "plus",
                isOn: model.isInWatchlist,
                caption: model.isInWatchlist ? Text("In Watchlist") : Text("Add to Watchlist"),
                action: actions.toggleWatchlist
            )
            if let watched = model.isWatched {
                MacGlassCircleAction(
                    systemImage: watched ? "eye.fill" : "eye",
                    isOn: watched,
                    caption: watched ? Text("Watched") : Text("Mark as Watched"),
                    action: actions.toggleWatched
                )
            }
        }
    }

    private func playButton(_ play: GlassPlayInfo) -> some View {
        Button(action: actions.play) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    if page.isPreparingPlay {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text("Play")
                    if let s = play.season, let e = play.episode {
                        Text("S\(s) · E\(e)")
                            .opacity(0.8)
                    }
                }
                .font(MacGlassFont.bodyEmphasis)
                if let progress = play.progress, progress > 0 {
                    GlassProgressBar(progress: progress, height: 3, tint: .white)
                        .opacity(0.9)
                        .frame(width: 110)
                }
            }
            .padding(.horizontal, 10)
        }
        .glassActionStyle(prominent: true)
        .controlSize(.extraLarge)
        .fixedSize()
        .contextMenu {
            Button(action: page.chooseQuality) {
                Label("Choose Quality…", systemImage: "slider.horizontal.3")
            }
        }
    }
}
