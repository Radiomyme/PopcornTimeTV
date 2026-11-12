// GlassEpisodesSection.swift — shows only: season pills, the episode shelf and
// a glass panel with the focused episode's summary.
import SwiftUI

struct GlassEpisodesSection: View {
    let model: GlassDetailModel
    let actions: GlassDetailActions
    var focus: FocusState<GlassFocusTarget?>.Binding
    /// Episode whose summary the panel shows (last focused card).
    let highlightedEpisodeID: String?
    let onExpand: (GlassExpandedText) -> Void

    static let cardWidth: CGFloat = 400

    var body: some View {
        let episodes = model.episodesOfSelectedSeason
        VStack(alignment: .leading, spacing: 18) {
            seasonsRow(episodeCount: episodes.count)
            if episodes.isEmpty && model.isLoadingEpisodes {
                placeholderShelf
            } else {
                shelf(episodes)
            }
            if let episode = panelEpisode(in: episodes) {
                GlassEpisodePanel(episode: episode) {
                    onExpand(GlassExpandedText(
                        title: episode.title,
                        subtitle: GlassEpisodePanel.subtitle(of: episode),
                        body: episode.summary))
                }
                .focused(focus, equals: .episodeSummary)
                .padding(.horizontal, GlassMetrics.sideInset)
            }
        }
        .padding(.top, GlassMetrics.topInset)
    }

    private func panelEpisode(in episodes: [GlassEpisode]) -> GlassEpisode? {
        if let id = highlightedEpisodeID, let hit = episodes.first(where: { $0.id == id }) { return hit }
        if let id = model.upNextEpisodeID, let hit = episodes.first(where: { $0.id == id }) { return hit }
        return episodes.first
    }

    // MARK: Seasons

    @ViewBuilder
    private func seasonsRow(episodeCount: Int) -> some View {
        let count = (episodeCount == 1 ? Text("1 Episode") : Text("\(episodeCount) Episodes"))
            .font(GlassFont.caption)
            .foregroundStyle(GlassPalette.secondaryText)
        if model.seasons.count > 1 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(model.seasons, id: \.self) { season in
                            SwiftUI.Button {
                                guard model.selectedSeason != season else { return }
                                model.selectedSeason = season
                                actions.selectSeason(season)
                            } label: {
                                Text("Season \(season)")
                                    .font(GlassFont.captionBold)
                                    .fixedSize()
                            }
                            .buttonStyle(GlassPillButtonStyle(selected: model.selectedSeason == season))
                            .focused(focus, equals: .season(season))
                            .id(season)
                        }
                        count.padding(.leading, 18)
                    }
                    .padding(.vertical, 18)
                }
                .contentMargins(.horizontal, GlassMetrics.sideInset, for: .scrollContent)
                .scrollClipDisabled()
                .focusSection()
                // Coming down from the hero lands on the selected season.
                .defaultFocus(focus, .season(model.selectedSeason ?? model.seasons[0]), priority: .userInitiated)
                .onAppear {
                    if let selected = model.selectedSeason { proxy.scrollTo(selected, anchor: .center) }
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                if let season = model.seasons.first ?? model.selectedSeason {
                    Text("Season \(season)").font(GlassFont.sectionTitle)
                } else {
                    Text("Episodes").font(GlassFont.sectionTitle)
                }
                count
            }
            .foregroundStyle(GlassPalette.primaryText)
            .padding(.horizontal, GlassMetrics.sideInset)
            .padding(.vertical, 10)
        }
    }

    // MARK: Shelf

    private func shelf(_ episodes: [GlassEpisode]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(episodes) { episode in
                        VStack(alignment: .leading, spacing: 0) {
                            SwiftUI.Button { actions.playEpisode(episode.id) } label: {
                                GlassEpisodeStill(episode: episode, width: Self.cardWidth)
                            }
                            .glassCardStyle()
                            .focused(focus, equals: .episode(episode.id))
                            .contextMenu { menu(for: episode) }
                            .accessibilityLabel(Text("S\(episode.season) · E\(episode.number)")
                                                + Text(verbatim: ", " + episode.title))

                            GlassEpisodeCaption(episode: episode)
                                .padding(.top, 22)
                        }
                        .frame(width: Self.cardWidth, alignment: .leading)
                        .id(episode.id)
                    }
                }
                .padding(.vertical, 26)
            }
            .contentMargins(.horizontal, GlassMetrics.sideInset, for: .scrollContent)
            .scrollClipDisabled()
            .focusSection()
            // Entering the shelf lands on the last focused episode, else the up-next one.
            .defaultFocus(focus, .episode(entryEpisodeID(in: episodes) ?? ""), priority: .userInitiated)
            .onAppear { scrollToStart(of: episodes, proxy: proxy) }
            .onChange(of: model.selectedSeason) { _, _ in
                scrollToStart(of: model.episodesOfSelectedSeason, proxy: proxy)
            }
        }
    }

    private func entryEpisodeID(in episodes: [GlassEpisode]) -> String? {
        if let id = highlightedEpisodeID, episodes.contains(where: { $0.id == id }) { return id }
        if let id = model.upNextEpisodeID, episodes.contains(where: { $0.id == id }) { return id }
        return episodes.first?.id
    }

    /// The up-next episode when it is in this season, else the first one.
    private func scrollToStart(of episodes: [GlassEpisode], proxy: ScrollViewProxy) {
        let target = episodes.first(where: { $0.id == model.upNextEpisodeID }) ?? episodes.first
        guard let target else { return }
        proxy.scrollTo(target.id, anchor: .leading)
    }

    @ViewBuilder
    private func menu(for episode: GlassEpisode) -> some View {
        SwiftUI.Button { actions.toggleEpisodeWatched(episode.id) } label: {
            if episode.isWatched {
                Label("Mark as Unwatched", systemImage: "eye.slash")
            } else {
                Label("Mark as Watched", systemImage: "eye")
            }
        }
        if let download = episode.download {
            GlassDownloadMenu(state: download,
                              primary: { actions.downloadEpisode(episode.id) },
                              stop: { actions.stopEpisodeDownload(episode.id) },
                              delete: { actions.deleteEpisodeDownload(episode.id) })
        }
    }

    private var placeholderShelf: some View {
        HStack(spacing: 40) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: Self.cardWidth, height: Self.cardWidth * 9 / 16)
            }
        }
        .padding(.horizontal, GlassMetrics.sideInset)
        .padding(.vertical, 26)
        .accessibilityHidden(true)
    }
}

/// Season pill. Selected = accent glass. Focused = bright glass with dark
/// text (custom style: the selection change must not change the button's
/// identity, which switching system styles would do).
struct GlassPillButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, selected: selected)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.glassFallback) private var fallback

        var body: some View {
            configuration.label
                .padding(.horizontal, 34)
                .padding(.vertical, 16)
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .modifier(PillSurface(selected: selected, isFocused: isFocused, fallback: fallback))
                .scaleEffect(configuration.isPressed ? 1.04 : (isFocused ? 1.1 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 18, y: 12)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.18), value: selected)
        }
    }

    private struct PillSurface: ViewModifier {
        let selected: Bool
        let isFocused: Bool
        let fallback: Bool

        func body(content: Content) -> some View {
            if #available(tvOS 26.0, *), !fallback {
                // The glass depends on the selection only (it changes on a
                // press, not on a focus move); the focused platter is a fill
                // above it. A glass swapped on focus logged "glassEffect()
                // tried to update multiple times per frame" when focus was
                // moved into the pills by code while their row scrolled.
                content
                    .background {
                        if isFocused { Capsule().fill(Color.white.opacity(0.88)) }
                    }
                    .glassEffect(glass, in: .capsule)
            } else {
                content
                    .background {
                        Capsule().fill(isFocused ? AnyShapeStyle(Color.white.opacity(0.92))
                                       : selected ? AnyShapeStyle(GlassPalette.accent)
                                       : AnyShapeStyle(Color.white.opacity(0.16)))
                    }
                    .overlay {
                        Capsule().stroke(Color.white.opacity(isFocused || selected ? 0 : 0.2), lineWidth: 1)
                    }
            }
        }

        @available(tvOS 26.0, *)
        private var glass: Glass {
            selected ? .regular.tint(GlassPalette.accent.opacity(0.85)) : .regular
        }
    }
}

// MARK: - Episode tile

/// Episode code, title and runtime / air date under the still (outside the
/// focusable card, so it stays legible whatever the card's focus platter).
struct GlassEpisodeCaption: View {
    let episode: GlassEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("S\(episode.season) · E\(episode.number)")
                .font(GlassFont.small)
                .foregroundStyle(GlassPalette.secondaryText)
            Text(verbatim: episode.title)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(GlassPalette.primaryText)
                .lineLimit(1)
            if let detail = episode.detail {
                Text(verbatim: detail)
                    .font(GlassFont.small)
                    .foregroundStyle(GlassPalette.tertiaryText)
                    .lineLimit(1)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .accessibilityHidden(true)
    }
}

/// 16:9 still with progress bar, watched check and download badge.
struct GlassEpisodeStill: View {
    let episode: GlassEpisode
    let width: CGFloat

    var body: some View {
        let height = width * 9 / 16
        GlassRemoteImage(url: episode.stillURL, maxPixelSize: width * 1.5) {
            ZStack {
                LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(verbatim: "\(episode.number)")
                    .font(.system(size: 84, weight: .heavy))
                    .foregroundStyle(Color.white.opacity(0.25))
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay(alignment: .bottom) {
            if let progress = episode.progress, progress > 0, !episode.isWatched {
                GlassProgressBar(progress: progress, height: 7)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if episode.isWatched {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(GlassPalette.accent))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    .padding(14)
            }
        }
        .overlay(alignment: .topLeading) {
            if let download = episode.download, download != .idle {
                GlassEpisodeDownloadBadge(state: download)
                    .padding(14)
            }
        }
    }
}

/// Small download state badge on an episode still.
struct GlassEpisodeDownloadBadge: View {
    let state: GlassDownloadState

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.55))
            GlassDownloadRing(state: state, lineWidth: 3.5)
                .padding(4)
            Image(systemName: GlassActionRow.downloadSymbol(state))
                .font(.system(size: state == .downloaded ? 20 : 17, weight: .bold))
                .foregroundStyle(state == .downloaded ? GlassPalette.accent : .white)
        }
        .frame(width: 46, height: 46)
    }
}

// MARK: - Focused episode panel

struct GlassEpisodePanel: View {
    let episode: GlassEpisode
    let action: () -> Void

    /// "S1 · E3  ·  42 min" (the code goes through Localizable.strings).
    static func subtitle(of episode: GlassEpisode) -> String {
        String(localized: "S\(episode.season) · E\(episode.number)") + (episode.detail.map { "  ·  " + $0 } ?? "")
    }

    var body: some View {
        SwiftUI.Button(action: action) {
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("S\(episode.season) · E\(episode.number)")
                        .font(GlassFont.captionBold)
                        .foregroundStyle(.secondary)
                    Text(verbatim: episode.title)
                        .font(.system(size: 34, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    statusLine
                }
                .frame(width: 520, alignment: .leading)

                Text(verbatim: episode.summary.isEmpty ? " " : episode.summary)
                    .font(.system(size: 28, weight: .regular))
                    .lineSpacing(4)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210, alignment: .topLeading)
        }
        .buttonStyle(GlassCardButtonStyle(focusScale: 1.012))
        .animation(.easeOut(duration: 0.2), value: episode.id)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 14) {
            if let detail = episode.detail {
                Text(verbatim: detail)
            }
            if episode.isWatched {
                Label("Watched", systemImage: "checkmark")
            }
            if let download = episode.download, download != .idle {
                GlassDownloadText.caption(download)
            }
        }
        .font(GlassFont.small)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
