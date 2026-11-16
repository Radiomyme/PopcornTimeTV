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
                    .padding(.bottom, showsBadgesRow ? 20 : 30)
                if showsBadgesRow {
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

    /// The logo, measured and cropped as the Home's billboard draws it
    /// (`HomeLogoImage`: transparent margins cut off, a dark logo in white)
    /// and at the same size: from a Home card the page opens on the logo
    /// the Home had, decoded already. The title in type stands in the same
    /// slot until the logo is there, then leaves at once: the two are never
    /// drawn together (two titles, one over the other, offset).
    private var titleBlock: some View {
        let logoURL = model.logoURL
        // A logo too dark for the veil is not drawn: the title stays in type.
        let logoReady = logoLoaded || logoURL.map { HomeLogoImage.cached($0, maxPixelSize: GlassHeroView.logoPixels)?.fits(minimumAspect: 0) ?? false } ?? false
        return ZStack(alignment: .bottomLeading) {
            if let logoURL {
                HomeLogoImage(url: logoURL, maxPixelSize: GlassHeroView.logoPixels, box: .hero(height: 190)) { logoLoaded = true }
                    .frame(maxWidth: 680, maxHeight: 190, alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
                    .accessibilityHidden(true)
            }
            if logoURL == nil || !logoReady {
                Text(verbatim: model.title)
                    .font(GlassFont.heroTitle)
                    .foregroundStyle(GlassPalette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
            }
        }
        // The slot has the logo's height from the first frame: the lines
        // under it never move when the logo replaces the title.
        .frame(height: logoURL == nil ? nil : 190, alignment: .bottomLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: model.title))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("Detail.Title")
        .onChange(of: model.logoURL) { _, _ in logoLoaded = false }
    }

    /// The Home's hero logo size (`HomeBillboardInfo`): one decoded copy for both.
    private static var logoPixels: CGFloat { homePixels(680) }

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
            // "★ 7,5", as on the Home's billboard and cards.
            if let score = model.score, score > 0 {
                HStack(spacing: 7) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(GlassPalette.star)
                    Text(verbatim: score.formatted(.number.precision(.fractionLength(1))))
                        .font(GlassFont.metadata)
                        .foregroundStyle(GlassPalette.primaryText.opacity(0.88))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(String(format: "Home.Rating".localized,
                                                score.formatted(.number.precision(.fractionLength(1))))))
            } else if let rating = model.rating, rating > 0 {
                GlassStarRating(stars: rating, size: 25)
            }
            // Last on the line: arriving with the record, it moves nothing.
            // The US ratings ("PG-13", "R") are not France's age labels:
            // shown in English only.
            if HomeText.appLanguageIsEnglish, let certification = model.certification, !certification.isEmpty {
                GlassChip(text: certification)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.certification)
        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
    }

    /// The row of the capability chips. A movie's is there from the first
    /// frame, before its sources are known ("Looking for sources…", then
    /// the chips as the sources answer): the hero is laid out from the
    /// bottom, and a row added later would push the title up.
    private var showsBadgesRow: Bool {
        model.loadError != nil || !model.badges.isEmpty || (model.kind == .movie && model.sources != .ready)
    }

    private var badgesRow: some View {
        HStack(spacing: 12) {
            if let error = model.loadError {
                GlassLoadErrorNote(message: error)
            } else {
                ForEach(Array(model.badges.enumerated()), id: \.element.id) { index, badge in
                    GlassChip(text: badge.text, systemImage: badge.systemImage, emphasized: index == 0)
                        .transition(.opacity)
                }
                // A source may still add a chip: nothing is drawn in its
                // place (an empty grey chip read as a broken one); the chip
                // fades in at the end of the row, where it moves nothing,
                // and Play shows its ring meanwhile.
                if model.kind == .movie, model.sources != .ready,
                   !(model.sources.isSearching && !model.badges.isEmpty) {
                    GlassSourcesNote(state: model.sources)
                        .padding(.leading, model.badges.isEmpty ? 0 : 6)
                }
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .animation(.easeOut(duration: 0.25), value: model.badges)
        .animation(.easeOut(duration: 0.25), value: model.sources)
        .animation(.easeOut(duration: 0.25), value: model.loadError)
    }

    // MARK: Summary

    /// The synopsis set on the artwork's veil, like the Home's billboard —
    /// no glass under body text. Cut at 3 lines it is focusable, with
    /// "MORE" (opens the full text); its focus is a light glass around it.
    /// The sources' synopses are English: under another language a line
    /// above it says so ("Résumé (en anglais)").
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
                        .opacity(0.72)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .buttonStyle(GlassSummaryButtonStyle())
            .padding(.horizontal, -24)
            .focused(focus, equals: .summary)
            .accessibilityIdentifier("Detail.Summary")
        } else {
            summaryText
                .foregroundStyle(GlassPalette.primaryText)
        }
    }

    private var summaryText: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !HomeText.appLanguageIsEnglish {
                Text("Detail.Summary.InEnglish")
                    .font(GlassFont.small)
                    .opacity(0.62)
            }
            Text(verbatim: model.summary)
                .font(GlassFont.body)
                .lineSpacing(4)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassReportsTruncation(of: model.summary, font: GlassFont.body, lineSpacing: 4)
                .onPreferenceChange(GlassTruncationKey.self) { summaryTruncated = $0 }
        }
        .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
    }
}

/// The synopsis's focus: nothing at rest (the text is on the veil), a light
/// glass around it once focused, with a small lift.
private struct GlassSummaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.glassFallback) private var fallback

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: GlassMetrics.cardCorner, style: .continuous)
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .background { if isFocused { surface(shape) } }
                .scaleEffect(configuration.isPressed ? 1.0 : (isFocused ? 1.02 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 22, y: 14)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }

        @ViewBuilder
        private func surface(_ shape: RoundedRectangle) -> some View {
            if #available(tvOS 26.0, *), !fallback {
                Color.clear.glassEffect(.regular.tint(.white.opacity(0.88)), in: shape)
            } else {
                shape.fill(Color.white.opacity(0.92))
            }
        }
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
            // "Try Again" takes Play's place (and its focus) on a page that
            // could not load, show or movie.
            if let play = model.play ?? (model.loadError == nil ? nil : GlassPlayInfo()) {
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
        let failed = model.loadError != nil
        return SwiftUI.Button(action: failed ? actions.retry : actions.play) {
            VStack(spacing: 6) {
                HStack(spacing: 14) {
                    if failed {
                        Image(systemName: "arrow.clockwise")
                        Text("Try Again")
                    } else {
                        // The sources are still searched: a ring in place of
                        // the triangle. The button stays live — a press is
                        // kept until a source is in.
                        ZStack {
                            Image(systemName: "play.fill").opacity(model.sources == .searching ? 0 : 1)
                            if model.sources == .searching { GlassSpinner(size: 26) }
                        }
                        Text("Play")
                        if let s = play.season, let e = play.episode {
                            Text("S\(s) · E\(e)")
                                .opacity(0.78)
                        }
                    }
                }
                .font(GlassFont.bodyEmphasis)
                if !failed, let progress = play.progress, progress > 0 {
                    // On the button's white once it is focused: dark.
                    GlassProgressBar(progress: progress, height: 5, tint: focused == .play ? .black : .white)
                        .opacity(0.9)
                        .frame(width: 150)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 4)
            .animation(.easeOut(duration: 0.2), value: model.sources)
        }
        .glassActionStyle(prominent: true)
        // Its ideal size only: with the progress bar and a Trailer button
        // beside it, the row otherwise stretched it vertically and squeezed
        // the summary card above (seen on tvOS 27.2).
        .fixedSize()
        .focused(focus, equals: .play)
        .accessibilityIdentifier(failed ? "Detail.Retry" : "Detail.Play")
        .accessibilityValue(!failed && model.sources == .searching ? Text("Sources.Loading") : Text(verbatim: ""))
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
