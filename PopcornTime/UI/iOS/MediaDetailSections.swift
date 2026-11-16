

import SwiftUI
import Vision
import PopcornKit

/// What the user did with one episode (`WatchedlistManager`): read once when
/// the page loads and again after playback, not at every redraw of a row.
struct EpisodeMark: Equatable {
    var isWatched: Bool
    /// 0…1 when partly watched (not started and finished episodes: nil).
    var progress: Double?
}

/// The artwork at the top of a detail page, edge to edge under the
/// navigation bar: metahub's landscape backdrop when it has one (the sources'
/// own "background" is often the poster again: TVMaze and Time4Popcorn only
/// carry portrait art), else the poster as blurred ambient light with the
/// crisp poster over it, else a gradient. The title's logo sits at the
/// bottom when metahub has one — unless the backdrop already prints the
/// title (key art: "SPIDER-MAN BRAND NEW DAY" across the image), which is
/// then the hero's title, framed so that it shows whole
/// (`BackdropTitle`).
struct MediaDetailHero: View {
    let media: Media
    let size: CGSize
    /// Set once the title is on screen in the artwork (its logo, or the
    /// backdrop's own lettering): the page then leaves the title's text out.
    @Binding var showsLogo: Bool

    @State private var artwork: GlassArtwork = .loading
    /// What the backdrop prints of the title, once read (nil: not read yet).
    @State private var printed: BackdropTitle?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            // Legibility of the status bar and of the bar buttons at the
            // top, and a fade into the page at the bottom.
            LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                                   .init(color: .black.opacity(0), location: 0.3),
                                   .init(color: .black.opacity(0), location: 0.55),
                                   .init(color: Color(.systemBackground), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            logo
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: media.id) {
            var backdrop = OpenMetadata.backgroundURL(imdbId: media.id)
            var fallback = GlassDetailAdapter.url(media.largeBackgroundImage)
            #if DEBUG
            // `-PTDebugAmbient`: as for a title without landscape art.
            if IOSDebugHooks.forcesAmbientHero { backdrop = nil; fallback = nil }
            #endif
            artwork = await GlassArtwork.load(backdrop: backdrop,
                                              fallbackBackdrop: fallback,
                                              // metahub's poster for a page opened by id alone (a link, a hook).
                                              poster: GlassDetailAdapter.url(media.mediumCoverImage ?? media.largeCoverImage)
                                                  ?? OpenMetadata.posterURL(imdbId: media.id),
                                              maxPixelSize: 1600)
            if case .landscape(let image, _) = artwork, let cgImage = image.cgImage {
                printed = await BackdropTitle.read(cgImage, title: media.title)
                if printed?.isPrinted == true { showsLogo = true }
            } else {
                printed = BackdropTitle(isPrinted: false, centerX: 0.5)
            }
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        switch artwork {
        case .loading:
            Color(.secondarySystemBackground)
        case .landscape(let image, _):
            // A printed title is kept in the frame: the image is moved
            // sideways so that its lettering is centred, within its edges.
            let drawnWidth = max(size.width, size.height * image.size.width / max(image.size.height, 1))
            let centerX = printed?.isPrinted == true ? printed?.centerX ?? 0.5 : 0.5
            let offset = min(0, max(size.width - drawnWidth, size.width / 2 - centerX * drawnWidth))
            Image(glassImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: drawnWidth, height: size.height)
                .offset(x: offset)
                .frame(width: size.width, height: size.height, alignment: .leading)
                .clipped()
                .accessibilityHidden(true)
        case .ambient(let blurred, let posterURL):
            ZStack {
                Image(glassImage: blurred)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(1.2)
                    .clipped()
                    .accessibilityHidden(true)
                let posterWidth = min(160, size.height * 0.42)
                GlassPosterCard(url: posterURL, title: media.title, width: posterWidth,
                                cornerRadius: 14, placeholderFont: .headline,
                                // The card's height (2:3) in the screen's pixels.
                                maxPixelSize: (posterWidth * 1.5 * max(displayScale, 1)).rounded(.up))
                    // Below the navigation bar, which the hero runs under.
                    .padding(.top, size.height * 0.16)
            }
        case .none:
            LinearGradient(colors: [GlassPalette.accent.opacity(0.35), Color(.systemBackground)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
        }
    }

    /// The title's transparent logo, when the backdrop is a real one (over
    /// the poster layout it would cover the poster) that does not print the
    /// title itself — the logo then waits for the backdrop to be read.
    @ViewBuilder
    private var logo: some View {
        if artwork.isLandscape, printed?.isPrinted == false, let url = OpenMetadata.logoURL(imdbId: media.id) {
            GlassRemoteImage(url: url, maxPixelSize: 800, contentMode: .fit, alignment: .bottomLeading,
                             onLoad: { _ in showsLogo = true }) {
                Color.clear
            }
            .frame(width: min(260, size.width * 0.6), height: min(90, size.height * 0.3), alignment: .bottomLeading)
            .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            .accessibilityHidden(true)
        }
    }
}

/// Whether a backdrop prints the title (key art), and where: read on the
/// device with Vision's text recognition once per page (its accurate mode:
/// the fast one does not read display lettering; about 0.1 s on a 1280-pixel
/// backdrop once its model is loaded).
struct BackdropTitle: Equatable {
    var isPrinted: Bool
    /// The lettering's centre across the image, 0…1.
    var centerX: CGFloat

    /// The words of a title worth looking for: four letters or more,
    /// folded ("Brand New Day" → BRAND); a title of short words only
    /// ("Up") is looked for whole.
    static func words(of title: String) -> [String] {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).uppercased()
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 }
        let whole = folded.filter { $0.isLetter || $0.isNumber }
        return words.isEmpty ? (whole.count >= 2 ? [whole] : []) : words
    }

    static func read(_ image: CGImage, title: String) async -> BackdropTitle {
        let words = words(of: title)
        guard !words.isEmpty else { return BackdropTitle(isPrinted: false, centerX: 0.5) }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            // Lettering, not credits: a line at least 4 % of the image high.
            request.minimumTextHeight = 0.04
            try? VNImageRequestHandler(cgImage: image).perform([request])
            var boxes: [CGRect] = []
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first, candidate.confidence > 0.3 else { continue }
                let text = candidate.string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .uppercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
                let squeezed = text.replacingOccurrences(of: " ", with: "")
                if words.contains(where: { text.contains($0) || squeezed.contains($0) }) {
                    boxes.append(observation.boundingBox)
                }
            }
            guard let first = boxes.first else { return BackdropTitle(isPrinted: false, centerX: 0.5) }
            let union = boxes.dropFirst().reduce(first) { $0.union($1) }
            return BackdropTitle(isPrinted: true, centerX: union.midX)
        }.value
    }
}

/// One source of a movie's list, in the app's language: its quality and
/// whether it is the recommended one, then where it comes from, its swarm
/// ("178 sources · 12 pairs"; nothing when the counts are a catalogue's
/// placeholder 100 / 100), its size ("7,19 Go") and its bitrate.
struct SourceRow: View {
    let torrent: Torrent
    let recommended: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: torrent.qualityLabel.isEmpty ? "—" : torrent.qualityLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if recommended {
                        Text("Picker.Recommended")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                Text(detailText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let warning = torrent.bandwidthWarning() {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.tint)
                .font(.title2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The swarm and the size; not the provider's code ("EXT", "Rutor"),
    /// which says nothing to a viewer.
    private var detailText: AttributedString {
        AttributedString(SourceRow.detail(of: torrent))
    }

    /// "178 sources · 12 pairs · 7,19 Go · ≈ 7 Mb/s".
    static func detail(of torrent: Torrent) -> String {
        var parts: [String] = []
        // YTS lists 100 / 100 for a release it has no count for.
        let placeholder = torrent.seeds == 100 && torrent.peers == 100
        if !placeholder {
            parts.append(String(format: "Sources.Seeds".localized, torrent.seeds))
            if torrent.peers > 0 { parts.append(String(format: "Sources.Peers".localized, torrent.peers)) }
        }
        if let bytes = torrent.sizeInBytes, bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        } else if let size = torrent.size, !size.isEmpty {
            parts.append(size)
        }
        if let bitrate = torrent.bitrateLabel { parts.append(bitrate) }
        return parts.joined(separator: " · ")
    }
}

/// One line of the episode list: number, title, summary, what the user did
/// with it (watched, progress) and whether it can be played yet.
struct EpisodeRow: View {
    let episode: Episode
    let mark: EpisodeMark?
    /// Its sources are being looked for.
    let isLoading: Bool
    /// The episode the page's Play button starts.
    let isNext: Bool

    private var isWatched: Bool { mark?.isWatched ?? false }
    private var isAvailable: Bool { episode.isAvailableToPlay }

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(episode.episode)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(isNext ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isWatched ? .secondary : .primary)
                    .lineLimit(2)
                if !isAvailable, let date = airDate {
                    // Announced, not aired: when it will be.
                    Label { Text(verbatim: date) } icon: { Image(systemName: "calendar") }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if !episode.summary.isEmpty,
                   episode.summary != "No summary available.".localized {
                    Text(verbatim: episode.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let progress = mark?.progress {
                    GlassProgressBar(progress: progress, height: 4)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), fallback: .regularMaterial)
        .opacity(isAvailable ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(isWatched ? Text("Watched") : Text(verbatim: ""))
    }

    /// The episode's title; a source's "Episode 2" in the app's language.
    private var title: String {
        HomeCardText.isGenericEpisodeTitle(episode.title)
            ? String(format: "Episode %lld".localized, episode.episode) : episode.title
    }

    private var airDate: String? {
        guard episode.firstAirDate > Date(timeIntervalSince1970: 0) else { return nil }   // unknown = .distantPast
        return DateFormatter.localizedString(from: episode.firstAirDate, dateStyle: .medium, timeStyle: .none)
    }

    @ViewBuilder
    private var trailing: some View {
        if isLoading {
            ProgressView()
        } else if !isAvailable {
            EmptyView()
        } else if isWatched {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.title2)
        } else {
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.tint)
                .font(.title2)
        }
    }
}

// MARK: - Rows of the Home's kind

/// A row of a title's page that scrolls sideways (cast, related titles):
/// its title on the page's text edge, its cards starting on that edge and
/// running to the screen's edge, so the next card shows — the Home's rows.
private struct DetailShelf<Content: View>: View {
    let title: LocalizedStringKey
    /// The page's text edge, from the screen's leading edge.
    let inset: CGFloat
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(HomeFont.shelfTitle(.compact))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, inset)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) { content() }
            }
            .contentMargins(.horizontal, inset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

/// "Distribution et équipe": the directors, then the actors in round
/// photos — those with a photo first (in their billing order), so that a
/// row does not open on initials when the source has no picture of the
/// leads.
struct DetailCastRow: View {
    let directors: [String]
    let actors: [Actor]
    let inset: CGFloat

    var body: some View {
        if !directors.isEmpty || !actors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                DetailShelf(title: "Cast & Crew", inset: inset, spacing: 14) {
                    ForEach(Array(DetailCastRow.ordered(actors).prefix(20).enumerated()), id: \.offset) { _, actor in
                        VStack(spacing: 6) {
                            GlassRemoteImage(url: DetailCastRow.photo(of: actor), maxPixelSize: 216) {
                                ZStack {
                                    Circle().fill(Color.white.opacity(0.1))
                                    Text(verbatim: actor.initials).font(.headline).foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                            Text(verbatim: actor.name).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                            Text(verbatim: actor.characterName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 84)
                        .accessibilityElement(children: .combine)
                    }
                }
                if !directors.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(directors.count > 1 ? LocalizedStringKey("Directors") : LocalizedStringKey("Director"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: directors.joined(separator: ", "))
                            .font(.caption)
                    }
                    .padding(.horizontal, inset)
                }
            }
        }
    }

    static func photo(of actor: Actor) -> URL? {
        (actor.mediumImage ?? actor.smallImage).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    static func ordered(_ actors: [Actor]) -> [Actor] {
        actors.filter { photo(of: $0) != nil } + actors.filter { photo(of: $0) == nil }
    }
}

/// "Vous aimerez aussi": the Home's poster cards (title on two lines,
/// "★ 7,9 · 2026", NOUVEAU), each opening its page.
struct DetailRelatedRow<Item: CatalogItem>: View {
    let items: [Item]
    let inset: CGFloat

    var body: some View {
        if !items.isEmpty {
            let layout = HomeLayout(width: 402, height: 800, sizeClass: .compact)
            let size = CGSize(width: layout.posterWidth, height: layout.posterHeight)
            DetailShelf(title: "Viewers Also Watched", inset: inset) {
                ForEach(items, id: \.id) { item in
                    NavigationLink(value: item) {
                        PosterCard(media: item, size: size)
                            // Its own width, so that a long title wraps
                            // onto the second line the card keeps for it.
                            .frame(width: size.width, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(HomeCardButtonStyle())
                }
            }
            .environment(\.homeHiddenBadges, HomeListBadges.hidden(items: items.map { GridCard.item($0) }))
        }
    }
}
