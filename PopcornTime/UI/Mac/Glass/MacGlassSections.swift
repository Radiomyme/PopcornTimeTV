// MacGlassSections.swift — lower sections of the Mac glass detail page: the
// episodes of a show (season pills, stills shelf, hovered-episode panel),
// "Viewers Also Watched" posters, "Cast & Crew" headshots and the
// Information / Accessibility cards. Same content as the tvOS sections
// (GlassEpisodesSection, GlassShelves), sized for a window and the pointer.
import SwiftUI
import PopcornKit

// MARK: - Episodes

struct MacGlassEpisodesSection: View {
    let model: GlassDetailModel
    let actions: GlassDetailActions
    let page: MacGlassPageState
    /// Last hovered (or clicked) episode: what the panel shows.
    @Binding var highlightedEpisodeID: String?
    let onExpand: (GlassExpandedText) -> Void

    private static let stillWidth = MacGlassMetrics.stillWidth
    private static let stillHeight = MacGlassMetrics.stillWidth * 9 / 16

    var body: some View {
        let episodes = model.episodesOfSelectedSeason
        VStack(alignment: .leading, spacing: 4) {
            seasonsRow(episodeCount: episodes.count)
            if episodes.isEmpty && model.isLoadingEpisodes {
                placeholderShelf
            } else {
                MacGlassShelf(items: episodes,
                              itemWidth: Self.stillWidth,
                              spacing: 20,
                              chevronCenter: Self.stillHeight / 2,
                              anchorID: model.upNextEpisodeID,
                              scrollToken: model.selectedSeason ?? -1) { episode in
                    tile(episode)
                }
            }
            if let episode = panelEpisode(in: episodes) {
                MacGlassEpisodePanel(episode: episode) {
                    onExpand(GlassExpandedText(title: episode.title,
                                               subtitle: MacGlassEpisodePanel.subtitle(of: episode),
                                               body: episode.summary))
                }
                .padding(.horizontal, MacGlassMetrics.sideInset)
                .padding(.top, 2)
            }
        }
        .padding(.top, MacGlassMetrics.sectionSpacing)
    }

    /// The hovered episode, else the up-next one, else the season's first.
    private func panelEpisode(in episodes: [GlassEpisode]) -> GlassEpisode? {
        if let id = highlightedEpisodeID, let hit = episodes.first(where: { $0.id == id }) { return hit }
        if let id = model.upNextEpisodeID, let hit = episodes.first(where: { $0.id == id }) { return hit }
        return episodes.first
    }

    // MARK: Seasons

    @ViewBuilder
    private func seasonsRow(episodeCount: Int) -> some View {
        let count = (episodeCount == 1 ? Text("1 Episode") : Text("\(episodeCount) Episodes"))
            .font(MacGlassFont.caption)
            .foregroundStyle(GlassPalette.secondaryText)
        if model.seasons.count > 1 {
            // A plain row when the pills fit, a scrolling one otherwise: the
            // part of a scroll view its content leaves uncovered draws an
            // opaque background on macOS.
            ViewThatFits(in: .horizontal) {
                pillsRow(count: count)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        pillsRow(count: count)
                    }
                    .onAppear {
                        if let selected = model.selectedSeason { proxy.scrollTo(selected, anchor: .center) }
                    }
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if let season = model.seasons.first ?? model.selectedSeason {
                    Text("Season \(season)").font(MacGlassFont.sectionTitle)
                } else {
                    Text("Episodes").font(MacGlassFont.sectionTitle)
                }
                count
            }
            .foregroundStyle(GlassPalette.primaryText)
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            .padding(.horizontal, MacGlassMetrics.sideInset)
            .padding(.vertical, 6)
        }
    }

    private func pillsRow(count: some View) -> some View {
        HStack(spacing: 10) {
            ForEach(model.seasons, id: \.self) { season in
                Button {
                    guard model.selectedSeason != season else { return }
                    model.selectedSeason = season
                    actions.selectSeason(season)
                } label: {
                    Text("Season \(season)")
                        .font(MacGlassFont.captionBold)
                        .fixedSize()
                }
                .buttonStyle(MacGlassPillButtonStyle(selected: model.selectedSeason == season))
                .id(season)
            }
            count.padding(.leading, 10)
        }
        .padding(.horizontal, MacGlassMetrics.sideInset)
        .padding(.vertical, 10)
    }

    // MARK: Shelf

    private func tile(_ episode: GlassEpisode) -> some View {
        Button {
            highlightedEpisodeID = episode.id
            actions.playEpisode(episode.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                MacGlassEpisodeStill(episode: episode,
                                     width: Self.stillWidth,
                                     isBusy: page.busyEpisodeID == episode.id)
                    .macGlassLift(RoundedRectangle(cornerRadius: MacGlassMetrics.stillCorner, style: .continuous))
                MacGlassEpisodeCaption(episode: episode)
            }
        }
        .buttonStyle(MacGlassHoverButtonStyle())
        .onHover { inside in
            if inside { highlightedEpisodeID = episode.id }
        }
        .contextMenu { menu(for: episode) }
        .help(Text(verbatim: episode.title))
        .accessibilityLabel(Text("S\(episode.season) · E\(episode.number)") + Text(verbatim: ", " + episode.title))
    }

    @ViewBuilder
    private func menu(for episode: GlassEpisode) -> some View {
        Button { actions.playEpisode(episode.id) } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button { page.chooseEpisodeQuality(episode.id) } label: {
            Label("Choose Quality…", systemImage: "slider.horizontal.3")
        }
        Divider()
        Button { actions.toggleEpisodeWatched(episode.id) } label: {
            if episode.isWatched {
                Label("Mark as Unwatched", systemImage: "eye.slash")
            } else {
                Label("Mark as Watched", systemImage: "eye")
            }
        }
    }

    private var placeholderShelf: some View {
        HStack(spacing: 20) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: MacGlassMetrics.stillCorner, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: Self.stillWidth, height: Self.stillHeight)
            }
        }
        .padding(.horizontal, MacGlassMetrics.sideInset)
        .padding(.vertical, 16)
        .accessibilityHidden(true)
    }
}

/// Episode code, title and air date / runtime under the still.
struct MacGlassEpisodeCaption: View {
    let episode: GlassEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("S\(episode.season) · E\(episode.number)")
                .font(MacGlassFont.small)
                .foregroundStyle(GlassPalette.secondaryText)
            Text(verbatim: episode.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GlassPalette.primaryText)
                .lineLimit(1)
            if let detail = episode.detail {
                Text(verbatim: detail)
                    .font(MacGlassFont.small)
                    .foregroundStyle(GlassPalette.tertiaryText)
                    .lineLimit(1)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
        .accessibilityHidden(true)
    }
}

/// 16:9 still with progress bar, watched check and a spinner while its
/// sources load.
struct MacGlassEpisodeStill: View {
    let episode: GlassEpisode
    let width: CGFloat
    var isBusy = false

    var body: some View {
        let height = width * 9 / 16
        GlassRemoteImage(url: episode.stillURL, maxPixelSize: width * 2) {
            ZStack {
                LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(verbatim: "\(episode.number)")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(Color.white.opacity(0.25))
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay(alignment: .bottom) {
            if let progress = episode.progress, progress > 0, !episode.isWatched {
                GlassProgressBar(progress: progress, height: 4)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if episode.isWatched {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(GlassPalette.accent))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                    .padding(8)
            }
        }
        .overlay {
            if isBusy {
                ZStack {
                    Color.black.opacity(0.45)
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.white)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isBusy)
    }
}

/// Glass panel under the shelf: the hovered episode's summary; "More" opens
/// the full text when it is cut.
struct MacGlassEpisodePanel: View {
    let episode: GlassEpisode
    let onMore: () -> Void

    @State private var isTruncated = false

    /// "S1 · E3  ·  42 min" (the code goes through Localizable.strings).
    static func subtitle(of episode: GlassEpisode) -> String {
        String(localized: "S\(episode.season) · E\(episode.number)") + (episode.detail.map { "  ·  " + $0 } ?? "")
    }

    /// Fixed (as on tvOS): hovering along the shelf changes the episode
    /// shown, never the height of the page below.
    static let height: CGFloat = 124

    var body: some View {
        // One view whatever the summary's length (no glass rebuilt while the
        // pointer moves along the shelf); clickable only when it is cut.
        Button {
            if isTruncated { onMore() }
        } label: {
            content
        }
        .buttonStyle(MacGlassCardButtonStyle(hoverScale: 1.005))
        .allowsHitTesting(isTruncated)
        .animation(.easeOut(duration: 0.15), value: episode.id)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 5) {
                Text("S\(episode.season) · E\(episode.number)")
                    .font(MacGlassFont.captionBold)
                    .foregroundStyle(GlassPalette.secondaryText)
                Text(verbatim: episode.title)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                statusLine
            }
            .frame(width: 250, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: episode.summary.isEmpty ? " " : episode.summary)
                    .font(MacGlassFont.body)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .glassReportsTruncation(of: episode.summary, font: MacGlassFont.body, lineSpacing: 3)
                    .onPreferenceChange(GlassTruncationKey.self) { isTruncated = $0 }
                // Always laid out: the text doesn't move when it appears.
                Text("More")
                    .font(MacGlassFont.small)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(GlassPalette.secondaryText)
                    .opacity(isTruncated ? 1 : 0)
                    .accessibilityHidden(!isTruncated)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            if let detail = episode.detail {
                Text(verbatim: detail)
            }
            if episode.isWatched {
                Label("Watched", systemImage: "checkmark")
            }
        }
        .font(MacGlassFont.small)
        .foregroundStyle(GlassPalette.secondaryText)
        .lineLimit(1)
    }
}

// MARK: - Viewers Also Watched

struct MacGlassRelatedShelf: View {
    let items: [GlassRelatedItem]
    let isLoading: Bool
    let page: MacGlassPageState

    private static let width = MacGlassMetrics.posterWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGlassSectionHeader(title: "Viewers Also Watched")
            if items.isEmpty && isLoading {
                HStack(spacing: 20) {
                    ForEach(0..<8, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: MacGlassMetrics.posterCorner, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: Self.width, height: Self.width * 1.5)
                    }
                }
                .padding(.horizontal, MacGlassMetrics.sideInset)
                .padding(.vertical, 16)
                .accessibilityHidden(true)
            } else {
                MacGlassShelf(items: items, itemWidth: Self.width, spacing: 20,
                              chevronCenter: Self.width * 0.75) { item in
                    tile(item)
                }
            }
        }
        .padding(.top, MacGlassMetrics.sectionSpacing)
    }

    /// A link to the title's own glass page (same navigation stack).
    @ViewBuilder
    private func tile(_ item: GlassRelatedItem) -> some View {
        if let movie = page.relatedMedia[item.id] as? Movie {
            NavigationLink(value: movie) { lockup(item) }
                .buttonStyle(MacGlassHoverButtonStyle())
                .help(Text(verbatim: item.title))
        } else if let show = page.relatedMedia[item.id] as? Show {
            NavigationLink(value: show) { lockup(item) }
                .buttonStyle(MacGlassHoverButtonStyle())
                .help(Text(verbatim: item.title))
        } else {
            lockup(item)
        }
    }

    private func lockup(_ item: GlassRelatedItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassRemoteImage(url: item.posterURL, maxPixelSize: Self.width * 2) {
                ZStack {
                    LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom)
                    Text(verbatim: item.title)
                        .font(MacGlassFont.captionBold)
                        .foregroundStyle(GlassPalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(12)
                }
            }
            .frame(width: Self.width, height: Self.width * 1.5)
            .clipped()
            .macGlassLift(RoundedRectangle(cornerRadius: MacGlassMetrics.posterCorner, style: .continuous))

            Text(verbatim: item.title)
                .font(MacGlassFont.captionBold)
                .foregroundStyle(GlassPalette.primaryText)
                .lineLimit(1)
                .padding(.top, 10)
            if let subtitle = item.subtitle {
                Text(verbatim: subtitle)
                    .font(MacGlassFont.small)
                    .foregroundStyle(GlassPalette.tertiaryText)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 5, y: 1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cast & Crew

struct MacGlassCastShelf: View {
    let people: [GlassPerson]
    let isLoading: Bool

    private static let size = MacGlassMetrics.headshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGlassSectionHeader(title: "Cast & Crew")
            if people.isEmpty && isLoading {
                HStack(spacing: 14) {
                    ForEach(0..<9, id: \.self) { _ in
                        Circle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: Self.size, height: Self.size)
                            .frame(width: MacGlassMetrics.personWidth)
                    }
                }
                .padding(.horizontal, MacGlassMetrics.sideInset)
                .padding(.vertical, 16)
                .accessibilityHidden(true)
            } else {
                // Not clickable: the Mac app has no person page.
                MacGlassShelf(items: people, itemWidth: MacGlassMetrics.personWidth, spacing: 14,
                              chevronCenter: Self.size / 2) { person in
                    MacGlassPersonLockup(person: person, size: Self.size)
                }
            }
        }
        .padding(.top, MacGlassMetrics.sectionSpacing)
    }
}

/// Round headshot (or monogram on glass) with name and role.
struct MacGlassPersonLockup: View {
    let person: GlassPerson
    let size: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Text(verbatim: person.initials)
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: size, height: size)
                    .glassSurface(Circle(), fallback: .thinMaterial)
                if person.imageURL != nil {
                    GlassRemoteImage(url: person.imageURL, maxPixelSize: size * 2) { Color.clear }
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                }
            }
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

            VStack(spacing: 2) {
                Text(verbatim: person.name)
                    .font(MacGlassFont.captionBold)
                    .foregroundStyle(GlassPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let role = person.role, !role.isEmpty {
                    Text(verbatim: role)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(GlassPalette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        }
        .frame(width: MacGlassMetrics.personWidth)
        .help(Text(verbatim: [person.name, person.role].compactMap { $0 }.joined(separator: " — ")))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Information / Accessibility

struct MacGlassInfoSection: View {
    let information: [GlassInfoRow]
    let accessibility: [GlassInfoRow]

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            if !information.isEmpty {
                card(title: "Information", rows: information)
            }
            if !accessibility.isEmpty {
                card(title: "Accessibility", rows: accessibility)
            }
        }
        .fixedSize(horizontal: false, vertical: true)   // both cards take the taller height
        .padding(.horizontal, MacGlassMetrics.sideInset)
        .padding(.top, MacGlassMetrics.sectionSpacing + 6)
    }

    private func card(title: LocalizedStringKey, rows: [GlassInfoRow]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 9) {
                ForEach(rows) { row in
                    GridRow {
                        Text(verbatim: row.key)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(GlassPalette.secondaryText)
                            .gridColumnAlignment(.leading)
                        Text(verbatim: row.value)
                            .font(.system(size: 13))
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .foregroundStyle(GlassPalette.primaryText)
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel(cornerRadius: MacGlassMetrics.cardCorner)
    }
}
