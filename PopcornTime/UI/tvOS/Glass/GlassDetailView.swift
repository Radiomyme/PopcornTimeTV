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

    /// Play, else Watchlist (always present).
    private var initialFocus: GlassFocusTarget {
        model.play != nil ? .play : .watchlist
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

    private struct ArtworkKey: Hashable {
        let backdrop: URL?
        let poster: URL?
    }

    private func loadArtwork() async {
        let loaded = await GlassArtwork.load(backdrop: model.backdropURL, fallbackBackdrop: model.backdropFallbackURL,
                                             poster: model.posterURL)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.5)) { artwork = loaded }
    }
}
