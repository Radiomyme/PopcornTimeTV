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
import NaturalLanguage
import PopcornKit

/// Mac-only state of the page that GlassDetailModel does not carry. Owned by
/// MacGlassDetailController.
@Observable
final class MacGlassPageState {
    /// Episode whose sources (then subtitles) are being fetched: spinner on its still.
    var busyEpisodeID: String?
    /// Play is preparing (sources, subtitles): spinner in the Play button.
    var isPreparingPlay = false
    /// A click on Play (or on an episode) made before the page's sources
    /// were in waits for them: Play shows a spinner and reads "Cancel".
    var isWaitingForSources = false
    /// The Movie / Show behind each related item (NavigationLink values). Set
    /// before `model.related`, which redraws the shelf.
    @ObservationIgnored var relatedMedia: [String: Media] = [:]
    /// The title's IMDb id: its facts as the Home tells them (`HomeTitleFacts`).
    @ObservationIgnored var imdbId: String?
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
                                .background(alignment: .leading) { heroScrim(width: geo.size.width) }
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

    /// The text side of the hero: black from 75 % on the left edge to
    /// nothing past the middle, faded at its top and bottom — the
    /// synopsis reads on a light, busy artwork too.
    private func heroScrim(width: CGFloat) -> some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0),
                               .init(color: .black.opacity(0.5), location: 0.5),
                               .init(color: .black.opacity(0), location: 1)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(width: max(width * 0.62, 560))
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.35),
                                       .init(color: .black, location: 0.85),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .opacity(isPastHero ? 0 : 1)
            .animation(.easeOut(duration: 0.25), value: isPastHero)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        actions.artworkShown()
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
            if let episode = episodes.first(where: { $0.id == model.entryEpisodeID }) ?? episodes.first {
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
                    .padding(.bottom, newEpisode == nil ? (showsBadgesRow ? 12 : 18) : 10)
                if let newEpisode {
                    newEpisodeLine(newEpisode)
                        .padding(.bottom, showsBadgesRow ? 12 : 18)
                }
                if showsBadgesRow {
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
                MacGlassLogo(url: logoURL, isLoaded: $logoLoaded)
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

    /// The episode a show's "NOUVEL ÉPISODE" is about, as the Home lists
    /// it (`HomeTitleFacts`).
    private var newEpisode: HomeEpisode? {
        guard model.kind == .show, let id = page.imdbId else { return nil }
        return HomeTitleFacts.shared.newEpisode(ofShow: id)
    }

    /// "NOUVEL ÉPISODE  S2 · É9 · ven. 13 nov.": the Home's pill, then
    /// which episode and when.
    private func newEpisodeLine(_ episode: HomeEpisode) -> some View {
        let text = HomeCardText()
        return HStack(spacing: 8) {
            HomeBadgePill(label: text.cardLabel(of: .newEpisode), size: .large)
            Text(verbatim: [text.number(of: episode), episode.airDate.map(text.day)].compactMap { $0 }.joined(separator: " · "))
                .font(MacGlassFont.metadata.weight(.semibold))
                .foregroundStyle(GlassPalette.primaryText)
        }
        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
        .accessibilityElement(children: .combine)
    }

    /// The Home's facts line: the app's rating of the title first (the one
    /// its cards show, `HomeTitleFacts`), then year, length, genres, and the
    /// age rating as a French reader knows it ("-12"; nothing for a film
    /// for all) — "★ 7,6 · 2023 · 2 h 5 min · Action, Drame · -12".
    private var metadataLine: some View {
        let score = page.imdbId.flatMap { HomeTitleFacts.shared.facts(of: $0)?.rating } ?? model.score
        var parts = model.metadata
        if let certification = model.certification, let age = MacGlassHeroView.ageRating(certification) { parts.append(age) }
        return HStack(alignment: .center, spacing: 6) {
            if let score {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(GlassPalette.star)
                Text(verbatim: score.formatted(.number.precision(.fractionLength(1))))
                    .fontWeight(.semibold)
                if !parts.isEmpty { Text(verbatim: "·") }
            }
            if !parts.isEmpty {
                Text(verbatim: parts.joined(separator: " · "))
            }
        }
        .font(MacGlassFont.metadata)
        .foregroundStyle(GlassPalette.primaryText.opacity(0.9))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
    }

    /// An American rating ("PG-13", "TV-MA") as a French reader knows it
    /// ("-12", "-16"; nothing for a film for all); unchanged in English.
    static func ageRating(_ certification: String) -> String? {
        let value = certification.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "Unrated", value != "NR", value != "Not Rated" else { return nil }
        let language = Bundle.main.preferredLocalizations.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? $0 }
        guard language == "fr" else { return value }
        switch value.uppercased() {
        case "G", "TV-G", "TV-Y", "TV-Y7", "PG", "TV-PG": return nil
        case "PG-13", "TV-14": return "-12"
        case "R", "TV-MA": return "-16"
        case "NC-17": return "-18"
        default: return value
        }
    }

    /// A capability chip in the Home's words: "DV", "ATMOS", "HDR", as on
    /// the cards and the carousel (one vocabulary in the whole app).
    static func chipText(_ text: String) -> String {
        let card = HomeCardText()
        switch text {
        case "Dolby Vision": return card.cardLabel(of: .dolbyVision)
        case "Dolby Atmos": return card.cardLabel(of: .atmos)
        case "HDR10", "HDR10+": return card.cardLabel(of: .hdr)
        default: return text
        }
    }

    /// The row of the capability chips. A movie's is there from the first
    /// frame, before its sources are known ("Looking for sources…", then
    /// the chips as the sources answer): the hero is laid out from the
    /// bottom, and a row added later would push the title up.
    private var showsBadgesRow: Bool {
        model.loadError != nil || !model.badges.isEmpty || (model.kind == .movie && model.sources != .ready)
    }

    private var badgesRow: some View {
        HStack(spacing: 8) {
            if let error = model.loadError {
                GlassLoadErrorNote(message: error, fontSize: 14)
            } else {
                ForEach(Array(model.badges.enumerated()), id: \.element.id) { index, badge in
                    GlassChip(text: MacGlassHeroView.chipText(badge.text), systemImage: badge.systemImage, emphasized: index == 0, fontSize: 13)
                        .transition(.opacity)
                }
                if model.kind == .movie, model.sources != .ready {
                    GlassSourcesNote(state: model.sources, fontSize: 13)
                        .padding(.leading, model.badges.isEmpty ? 0 : 4)
                }
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
        .animation(.easeOut(duration: 0.25), value: model.badges)
        .animation(.easeOut(duration: 0.25), value: model.sources)
        .animation(.easeOut(duration: 0.25), value: model.loadError)
    }

    // MARK: Summary

    /// The synopsis straight on the artwork's shade, not on glass (glass is
    /// for controls): three lines, then "MORE" (opens the full text) when it
    /// is cut. One the sources give in English only, under a French app,
    /// says so above it ("RÉSUMÉ (EN ANGLAIS)").
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if MacGlassHeroView.isForeign(model.summary) {
                Text("Detail.Summary.InEnglish")
                    .font(MacGlassFont.small)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(GlassPalette.secondaryText)
            }
            Button {
                if summaryTruncated { onExpandSummary() }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    summaryText
                        .foregroundStyle(GlassPalette.primaryText.opacity(0.88))
                    if summaryTruncated {
                        Text("More")
                            .font(MacGlassFont.small)
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(GlassPalette.primaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 640, alignment: .leading)
        .shadow(color: .black.opacity(0.6), radius: 8, y: 1)
    }

    /// The text is in English while the app is not.
    static func isForeign(_ text: String) -> Bool {
        let app = Bundle.main.preferredLocalizations.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? $0 } ?? "en"
        guard app != "en", text.count > 40 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english
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
            // "Try Again" takes Play's place on a page that could not load,
            // show or movie.
            if let play = model.play ?? (model.loadError == nil ? nil : GlassPlayInfo()) {
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
        let failed = model.loadError != nil
        // A click made before the sources waits for them: the button then
        // cancels it. (The controller's `play` does, on the same action.)
        let waits = page.isWaitingForSources && !failed
        return Button(action: failed ? actions.retry : actions.play) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    if failed {
                        Image(systemName: "arrow.clockwise")
                        Text("Try Again")
                    } else {
                        if page.isPreparingPlay || waits || model.sources == .searching {
                            // Not ProgressView: the glass button scales on hover / press.
                            MacGlassSpinner(diameter: 16)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        if waits {
                            Text("Cancel")
                        } else {
                            Text("Play")
                            if let s = play.season, let e = play.episode {
                                Text("S\(s) · E\(e)")
                                    .opacity(0.8)
                            }
                        }
                    }
                }
                .font(MacGlassFont.bodyEmphasis)
                if !failed, !waits, let progress = play.progress, progress > 0 {
                    GlassProgressBar(progress: progress, height: 3, tint: GlassPalette.accent)
                        .frame(width: 110)
                }
            }
            .padding(.horizontal, 10)
        }
        .help(waits ? Text("Sources.Loading") : Text(verbatim: ""))
        // The page's main action, as on the Home's carousel: solid white.
        .buttonStyle(HomePrimaryButtonStyle())
        .fixedSize()
        .contextMenu {
            Button(action: page.chooseQuality) {
                Label("Choose Quality…", systemImage: "slider.horizontal.3")
            }
        }
        #if DEBUG
        .macGlassDebugAnchor("play")
        #endif
    }
}

// MARK: - Logo

/// A title's logo on its page at the Home carousel's size: its transparent
/// margins cut off (`HomeMeasuredLogo`), so that a logo drawn small in a
/// large canvas still fills the 420 × 160 box; a black logo drawn white.
/// A logo too dark for the artwork is not drawn: the title in type stays.
private struct MacGlassLogo: View {
    let url: URL
    @Binding var isLoaded: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var logo: HomeMeasuredLogo?

    var body: some View {
        Group {
            if let logo, logo.isReadable {
                Image(glassImage: logo.image)
                    .renderingMode(logo.isDark ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: 420, maxHeight: 160, alignment: .bottomLeading)
                    .transition(.opacity)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
        .accessibilityHidden(true)
        .task(id: url) {
            if let cached = HomeMeasuredLogo.cached(url) {
                logo = cached
                isLoaded = cached.isReadable
                return
            }
            guard let image = await GlassImageCache.shared.image(for: url, maxPixelSize: (420 * max(displayScale, 1)).rounded(.up)),
                  !Task.isCancelled else { return }
            let measured = await Task.detached(priority: .userInitiated) { HomeMeasuredLogo.measure(image) }.value
            guard !Task.isCancelled else { return }
            HomeMeasuredLogo.store(measured, for: url)
            withAnimation(.easeOut(duration: 0.25)) { logo = measured }
            isLoaded = measured.isReadable
        }
    }
}
