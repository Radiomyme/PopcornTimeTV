// GlassDetailView.swift — the Liquid Glass movie / show page of the tvOS app.
//
// Layout, top to bottom, in one vertical ScrollView over a fixed full-bleed
// artwork layer:
//   1. hero (first screen): logo / title, metadata, chips, summary card, actions
//   2. shows: season pills, episode shelf, focused-episode panel
//   3. "Viewers Also Watched", 4. "Cast & Crew", 5. Information / Accessibility
// Sections without data are hidden. When focus leaves the hero the artwork
// blurs and darkens; each section scrolls to the top when it takes focus.
//
// Host it full screen in a UIHostingController pushed on the app's navigation
// controller: GlassDetailView(model: model, actions: actions). The view
// ignores the safe area and applies its own 1920×1080 insets (GlassMetrics).
import SwiftUI

struct GlassDetailView: View {
    let model: GlassDetailModel
    var actions: GlassDetailActions

    @FocusState private var focus: GlassFocusTarget?
    @State private var artwork: GlassArtwork = .loading
    @State private var highlightedEpisodeID: String?
    /// Where focus goes back to when the text sheet closes.
    @State private var focusBeforeSheet: GlassFocusTarget?

    init(model: GlassDetailModel, actions: GlassDetailActions = GlassDetailActions()) {
        self.model = model
        self.actions = actions
    }

    private enum SectionID: Hashable {
        case hero, episodes, related, cast, info
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                GlassBackdropView(artwork: artwork, dimmed: !heroIsActive, size: geo.size)
                // Below the first screen, the blurred art turns light on a bright
                // picture (a taupe under grey roles and labels): half black
                // more, about 70 % in all with the backdrop's own dim.
                Color.black
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(heroIsActive ? 0 : 0.5)
                    .animation(.easeInOut(duration: 0.45), value: heroIsActive)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                // With the backdrop's own scrim, the Home billboard's left
                // veil (`HomeBackdropView`): the page a card opens reads like
                // the Home, and the text holds on a bright picture.
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                       .init(color: .black.opacity(0.50), location: 0.36),
                                       .init(color: .black.opacity(0.18), location: 0.60),
                                       .init(color: .black.opacity(0), location: 0.82)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(heroIsActive ? 1 : 0)
                    .animation(.easeInOut(duration: 0.45), value: heroIsActive)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                // The top, as on the Home (`HomeBackdropView`): a light sky
                // was a pale band over the page (60 % and more of black over
                // the first quarter).
                LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0),
                                       .init(color: .black.opacity(0.60), location: 0.25),
                                       .init(color: .black.opacity(0), location: 0.42)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(heroIsActive ? 1 : 0)
                    .animation(.easeInOut(duration: 0.45), value: heroIsActive)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            GlassHeroView(model: model,
                                          actions: actions,
                                          posterCardURL: artwork.posterCardURL,
                                          focus: $focus,
                                          focused: focus,
                                          onExpandSummary: expandSummary)
                                .frame(width: geo.size.width,
                                       height: geo.size.height - GlassMetrics.peek,
                                       alignment: .bottomLeading)
                                .id(SectionID.hero)

                            sections
                        }
                        .frame(width: geo.size.width, alignment: .leading)
                        .padding(.bottom, GlassMetrics.bottomInset + 40)
                    }
                    .scrollClipDisabled()
                    .defaultFocus($focus, initialFocus)
                    .onChange(of: focus) { old, new in
                        focusMoved(from: old, to: new, proxy: proxy)
                    }
                }
                .disabled(model.expandedText != nil)
                .blur(radius: model.expandedText == nil ? 0 : 16)

                if let text = model.expandedText {
                    GlassTextSheet(text: text, onClose: closeSheet)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .zIndex(1)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.25), value: model.expandedText)
        .task(id: ArtworkKey(backdrop: model.backdropURL, poster: model.posterURL)) {
            await loadArtwork()
        }
        .onAppear {
            if let request = model.focusRequest {
                model.focusRequest = nil
                focus = request
            }
        }
        .onChange(of: model.focusRequest) { _, request in
            guard let request else { return }
            model.focusRequest = nil
            focus = request
        }
        .onPlayPauseCommand(perform: playPausePressed)
    }

    /// The remote's Play/Pause, as in the TV app: plays the focused episode,
    /// a related title in focus (its page, then its playback, as on the
    /// grid), else what the Play button plays — from the first screen, the
    /// seasons and the episode summary; never from the cast or the
    /// information, nor under the full summary.
    private func playPausePressed() {
        guard model.expandedText == nil else { return }
        switch focus {
        case .episode(let id)?:
            actions.playEpisode(id)
        case .related(let id)?:
            actions.playRelated(id)
        case .person?, .information?, .accessibility?:
            return
        default:
            if model.loadError != nil {
                actions.retry()
            } else if model.play != nil {
                actions.play()
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var sections: some View {
        if model.kind == .show, !model.episodes.isEmpty || model.isLoadingEpisodes {
            GlassEpisodesSection(model: model,
                                 actions: actions,
                                 focus: $focus,
                                 highlightedEpisodeID: highlightedEpisodeID,
                                 onExpand: present)
                .id(SectionID.episodes)
        }
        if !model.related.isEmpty || model.isLoadingRelated {
            GlassRelatedShelf(items: model.related,
                              isLoading: model.isLoadingRelated,
                              focus: $focus,
                              open: actions.openRelated)
                .id(SectionID.related)
        }
        if !model.people.isEmpty || model.isLoadingPeople {
            GlassCastShelf(people: model.people,
                           isLoading: model.isLoadingPeople,
                           focus: $focus,
                           open: actions.openPerson)
                .id(SectionID.cast)
        }
        if !model.information.isEmpty || !model.accessibility.isEmpty {
            GlassInfoSection(information: model.information,
                             accessibility: model.accessibility,
                             focus: $focus)
                .id(SectionID.info)
        }
    }

    // MARK: Focus

    /// Play (or "Try Again" in its place), else Watchlist (always present).
    private var initialFocus: GlassFocusTarget {
        model.play != nil || model.loadError != nil ? .play : .watchlist
    }

    private var heroIsActive: Bool {
        guard model.expandedText == nil else { return false }
        return focus?.isHero ?? true
    }

    private func section(of target: GlassFocusTarget?) -> SectionID? {
        switch target {
        case nil: return nil
        case .play?, .trailer?, .watchlist?, .watched?, .download?, .summary?: return .hero
        case .season?, .episode?, .episodeSummary?: return .episodes
        case .related?: return .related
        case .person?: return .cast
        case .information?, .accessibility?: return .info
        }
    }

    private func focusMoved(from old: GlassFocusTarget?, to new: GlassFocusTarget?, proxy: ScrollViewProxy) {
        actions.focusChanged(new)
        if case .episode(let id)? = new { highlightedEpisodeID = id }
        guard let newSection = section(of: new), newSection != section(of: old) else { return }
        // Snap the section that takes focus to the top (the hero: back to the first screen).
        withAnimation(.easeInOut(duration: 0.45)) {
            proxy.scrollTo(newSection, anchor: .top)
        }
    }

    // MARK: Text sheet

    private func expandSummary() {
        present(GlassExpandedText(title: model.title,
                                  subtitle: model.metadata.joined(separator: "  ·  "),
                                  body: model.summary))
    }

    private func present(_ text: GlassExpandedText) {
        focusBeforeSheet = focus
        model.expandedText = text
    }

    private func closeSheet() {
        model.expandedText = nil
        let target = focusBeforeSheet
        DispatchQueue.main.async { focus = target }
    }

    // MARK: Artwork

    /// A landscape backdrop that is a montage, measured off the main thread.
    private static func isMontage(_ artwork: GlassArtwork) async -> Bool {
        guard case .landscape(let image, _) = artwork, let cgImage = image.glassCGImage else { return false }
        return await Task.detached(priority: .userInitiated) { HomeCollage.isCollage(cgImage) }.value
    }

    private struct ArtworkKey: Hashable {
        let backdrop: URL?
        let poster: URL?
    }

    private func loadArtwork() async {
        var loaded = await GlassArtwork.load(backdrop: model.backdropURL, fallbackBackdrop: model.backdropFallbackURL,
                                             poster: model.posterURL)
        // A backdrop made of tiles (`HomeCollage`): the other source's
        // backdrop when it is a real one, else the poster as ambient light
        // (with the crisp poster card).
        if await GlassDetailView.isMontage(loaded) {
            var replacement = GlassArtwork.none
            if let fallback = model.backdropFallbackURL, fallback != model.backdropURL {
                replacement = await GlassArtwork.load(backdrop: fallback, poster: nil)
            }
            let replacementIsMontage = await GlassDetailView.isMontage(replacement)
            if !replacement.isLandscape || replacementIsMontage {
                replacement = await GlassArtwork.load(backdrop: nil, poster: model.posterURL)
            }
            if replacement != .none { loaded = replacement }
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.5)) { artwork = loaded }
        actions.artworkShown()
    }
}
