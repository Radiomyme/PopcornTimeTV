// GlassHeroView.swift — first screen of the glass detail page: logo or title,
// metadata, capability chips, summary card and the action row, bottom-left
// over the artwork (plus a poster card when the artwork is only a poster).
import SwiftUI

struct GlassHeroView: View {
    let model: GlassDetailModel
    let actions: GlassDetailActions
    /// The artwork is a poster (or missing): show the crisp poster card.
    let posterCardURL: URL?
    var focus: FocusState<GlassFocusTarget?>.Binding
    /// Current focus (drives the captions of the round buttons).
    let focused: GlassFocusTarget?
    let onExpandSummary: () -> Void

    @State private var logoLoaded = false
    /// Starts true so the card is focusable until measured.
    @State private var summaryTruncated = true

    var body: some View {
        HStack(alignment: .bottom, spacing: 64) {
            if let posterCardURL {
                GlassPosterCard(url: posterCardURL, title: model.title)
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 0) {
                titleBlock
                    .padding(.bottom, 24)
                metadataLine
                    .padding(.bottom, model.badges.isEmpty ? 30 : 20)
                if !model.badges.isEmpty {
                    badgesRow
                        .padding(.bottom, 30)
                }
                if !model.summary.isEmpty {
                    summaryCard
                        .padding(.bottom, 40)
                }
                GlassActionRow(model: model, actions: actions, focus: focus, focused: focused)
            }
            .frame(maxWidth: posterCardURL == nil ? 1100 : 1040, alignment: .leading)
        }
        .padding(.leading, GlassMetrics.sideInset)
        .padding(.trailing, GlassMetrics.sideInset)
        .padding(.bottom, 36)
        .animation(.easeOut(duration: 0.3), value: posterCardURL)
    }

    // MARK: Title

    private var titleBlock: some View {
        ZStack(alignment: .bottomLeading) {
            if let logoURL = model.logoURL {
                GlassRemoteImage(url: logoURL, maxPixelSize: 1000, contentMode: .fit,
                                 alignment: .bottomLeading,
                                 onLoad: { _ in logoLoaded = true }) { EmptyView() }
                    .frame(maxWidth: 680, maxHeight: 230, alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
                    .accessibilityHidden(true)
            }
            if model.logoURL == nil || !logoLoaded {
                Text(verbatim: model.title)
                    .font(GlassFont.heroTitle)
                    .foregroundStyle(GlassPalette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
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
        HStack(alignment: .center, spacing: 20) {
            if !model.metadata.isEmpty {
                Text(verbatim: model.metadata.joined(separator: "  ·  "))
                    .font(GlassFont.metadata)
                    .foregroundStyle(GlassPalette.primaryText.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let certification = model.certification, !certification.isEmpty {
                GlassChip(text: certification)
            }
            if let rating = model.rating, rating > 0 {
                GlassStarRating(stars: rating, size: 25)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
    }

    private var badgesRow: some View {
        HStack(spacing: 12) {
            ForEach(Array(model.badges.enumerated()), id: \.element.id) { index, badge in
                GlassChip(text: badge.text, systemImage: badge.systemImage, emphasized: index == 0)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }

    // MARK: Summary

    /// A focusable card with "MORE" (opens the full text) when the summary is
    /// cut at 3 lines; a plain glass card otherwise.
    @ViewBuilder
    private var summaryCard: some View {
        if summaryTruncated {
            SwiftUI.Button(action: onExpandSummary) {
                VStack(alignment: .leading, spacing: 10) {
                    summaryText
                    Text("More")
                        .font(GlassFont.small)
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 24)
            }
            .buttonStyle(GlassCardButtonStyle(focusScale: 1.025))
            .focused(focus, equals: .summary)
        } else {
            summaryText
                .foregroundStyle(GlassPalette.primaryText)
                .padding(.horizontal, 34)
                .padding(.vertical, 24)
                .glassPanel()
        }
    }

    private var summaryText: some View {
        Text(verbatim: model.summary)
            .font(GlassFont.body)
            .lineSpacing(4)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassReportsTruncation(of: model.summary, font: GlassFont.body, lineSpacing: 4)
            .onPreferenceChange(GlassTruncationKey.self) { summaryTruncated = $0 }
    }
}

// MARK: - Action row

struct GlassActionRow: View {
    let model: GlassDetailModel
    let actions: GlassDetailActions
    var focus: FocusState<GlassFocusTarget?>.Binding
    let focused: GlassFocusTarget?

    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            if let play = model.play {
                playButton(play)
            }
            if model.hasTrailer {
                SwiftUI.Button(action: actions.playTrailer) {
                    Label("Trailer", systemImage: "film")
                        .font(GlassFont.bodyEmphasis)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .glassActionStyle()
                .focused(focus, equals: .trailer)
            }
            GlassCircleAction(
                systemImage: model.isInWatchlist ? "checkmark" : "plus",
                isOn: model.isInWatchlist,
                caption: model.isInWatchlist ? Text("In Watchlist") : Text("Add to Watchlist"),
                isFocused: focused == .watchlist,
                // First in the row: keep the caption inside the left margin.
                captionLeading: model.play == nil && !model.hasTrailer,
                action: actions.toggleWatchlist
            )
            .focused(focus, equals: .watchlist)

            if let watched = model.isWatched {
                GlassCircleAction(
                    systemImage: watched ? "eye.fill" : "eye",
                    isOn: watched,
                    caption: watched ? Text("Watched") : Text("Mark as Watched"),
                    isFocused: focused == .watched,
                    action: actions.toggleWatched
                )
                .focused(focus, equals: .watched)
            }

            if let download = model.download {
                GlassCircleAction(
                    systemImage: Self.downloadSymbol(download),
                    isOn: download == .downloaded,
                    caption: GlassDownloadText.caption(download),
                    isFocused: focused == .download,
                    ring: download,
                    action: actions.download
                )
                .focused(focus, equals: .download)
                .contextMenu {
                    GlassDownloadMenu(state: download,
                                      primary: actions.download,
                                      stop: actions.stopDownload,
                                      delete: actions.deleteDownload)
                }
            }
        }
        .focusSection()
    }

    private func playButton(_ play: GlassPlayInfo) -> some View {
        SwiftUI.Button(action: actions.play) {
            VStack(spacing: 6) {
                HStack(spacing: 14) {
                    Image(systemName: "play.fill")
                    Text("Play")
                    if let s = play.season, let e = play.episode {
                        Text("S\(s) · E\(e)")
                            .opacity(0.78)
                    }
                }
                .font(GlassFont.bodyEmphasis)
                if let progress = play.progress, progress > 0 {
                    GlassProgressBar(progress: progress, height: 5, tint: .white)
                        .opacity(0.9)
                        .frame(width: 150)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 4)
        }
        .glassActionStyle(prominent: true)
        // Its ideal size only: with the progress bar and a Trailer button
        // beside it, the row otherwise stretched it vertically and squeezed
        // the summary card above (seen on tvOS 27.2).
        .fixedSize()
        .focused(focus, equals: .play)
    }

    static func downloadSymbol(_ state: GlassDownloadState) -> String {
        switch state {
        case .idle, .pending, .downloading: return "arrow.down"
        case .paused: return "pause.fill"
        case .downloaded: return "arrow.down.to.line"
        }
    }
}

/// Download wording shared by the movie button and the episode cards.
enum GlassDownloadText {
    static func caption(_ state: GlassDownloadState) -> Text {
        switch state {
        case .idle: return Text("Download")
        case .pending: return Text("Pending")
        case .downloading(let p): return Text("Downloading") + Text(verbatim: "  " + percent(p))
        case .paused(let p): return Text("Paused") + Text(verbatim: "  " + percent(p))
        case .downloaded: return Text("Downloaded")
        }
    }

    static func percent(_ progress: Double) -> String {
        min(max(progress, 0), 1).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Long-press menu of a download control (today's long press = Stop Download).
struct GlassDownloadMenu: View {
    let state: GlassDownloadState
    let primary: () -> Void
    let stop: () -> Void
    let delete: () -> Void

    var body: some View {
        switch state {
        case .idle:
            SwiftUI.Button(action: primary) { Label("Download", systemImage: "arrow.down") }
        case .pending:
            SwiftUI.Button(role: .destructive, action: stop) { Label("Stop Download", systemImage: "xmark") }
        case .downloading:
            SwiftUI.Button(action: primary) { Label("Pause", systemImage: "pause.fill") }
            SwiftUI.Button(role: .destructive, action: stop) { Label("Stop Download", systemImage: "xmark") }
        case .paused:
            SwiftUI.Button(action: primary) { Label("Resume", systemImage: "play.fill") }
            SwiftUI.Button(role: .destructive, action: stop) { Label("Stop Download", systemImage: "xmark") }
        case .downloaded:
            SwiftUI.Button(action: primary) { Label("Options", systemImage: "ellipsis") }
            SwiftUI.Button(role: .destructive, action: delete) { Label("Delete Download", systemImage: "trash") }
        }
    }
}

/// Round glass icon button; its caption appears under it while it has focus.
struct GlassCircleAction: View {
    let systemImage: String
    /// "On" state (in watchlist, watched, downloaded): accent-colored icon.
    var isOn = false
    let caption: Text
    let isFocused: Bool
    /// Align the caption on the button's leading edge instead of centering it.
    var captionLeading = false
    var ring: GlassDownloadState? = nil
    let action: () -> Void

    var body: some View {
        SwiftUI.Button(action: action) {
            ZStack {
                if let ring {
                    GlassDownloadRing(state: ring, lineWidth: 4)
                        .frame(width: 58, height: 58)
                }
                Image(systemName: systemImage)
                    .font(.system(size: ring?.progress != nil || ring == .pending ? 24 : 32, weight: .bold))
                    .foregroundStyle(isOn ? AnyShapeStyle(GlassPalette.accent) : AnyShapeStyle(.primary))
            }
            .frame(width: 64, height: 64)
        }
        .buttonBorderShape(.circle)
        .glassActionStyle()
        .overlay(alignment: captionLeading ? .bottomLeading : .bottom) {
            caption
                .font(GlassFont.captionBold)
                .foregroundStyle(GlassPalette.primaryText)
                .fixedSize()
                .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                .offset(y: 56)
                .opacity(isFocused ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: isFocused)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(caption)
    }
}
