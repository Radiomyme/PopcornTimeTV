

import SwiftUI
import PopcornKit
import AVKit
import PopcornTorrent

/// The torrents found for one episode, ready to drive a quality-picker sheet.
struct EpisodeSources: Identifiable {
    let id = UUID()
    let title: String
    let torrents: [Torrent]
    /// The episode these sources play — subtitles, watched progress.
    var episode: Episode? = nil
}

@MainActor
final class MediaDetailViewModel: ObservableObject {
    @Published var enrichedMovie: Movie?
    @Published var enrichedShow:  Show?
    @Published var loading = false
    @Published var errorMessage: String?
    /// Episode torrents (EZTV) augmented with Torrentio + Time4Popcorn for
    /// the chosen episode. `nil` until augmentation finishes.
    @Published var augmentedEpisodeTorrents: [Torrent]?

    /// Non-nil once an episode's sources are resolved → presents the quality
    /// picker sheet. `loadingSourcesFor` marks which episode is resolving.
    @Published var episodeSources: EpisodeSources?
    @Published var loadingSourcesFor: String?   // episode id currently fetching
    @Published var noSourcesMessage: String?

    /// Fetch a specific episode's torrents, **T4P first** then falling back to
    /// EZTV + Torrentio, and publish them for the quality picker.
    func loadEpisodeSources(_ episode: Episode, showId: String) {
        guard showId.hasPrefix("tt") else { return }
        loadingSourcesFor = episode.id
        noSourcesMessage = nil
        let base = episode.torrents   // EZTV (already attached to the episode)
        let group = DispatchGroup()
        var t4p: [Torrent] = []
        var aggregated: [Torrent] = []

        group.enter()
        Time4PopcornClient.shared.episodeTorrents(imdbId: showId, season: episode.season, episode: episode.episode) { torrents in
            t4p = torrents
            group.leave()
        }
        group.enter()
        TorrentioClient.shared.streams(imdbId: showId, season: episode.season, episode: episode.episode) { torrents in
            aggregated = torrents
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.loadingSourcesFor = nil
            // T4P primary (base of the merge), EZTV + Torrentio as fallback,
            // then sorted best-quality-first for the picker.
            let merged = TorrentioClient.merge(t4p, with: base + aggregated).sorted(by: >)
            let title = "S\(episode.season)E\(episode.episode)" + (episode.title.isEmpty ? "" : " · \(episode.title)")
            if merged.isEmpty {
                self.noSourcesMessage = "Aucune source trouvée pour \(title)."
            } else {
                self.episodeSources = EpisodeSources(title: title, torrents: merged,
                                                     episode: self.playable(episode))
            }
        }
    }

    func load(_ media: Media) {
        loading = true
        errorMessage = nil
        if media is Movie {
            PopcornKit.getMovieInfo(media.id) { [weak self] movie, error in
                DispatchQueue.main.async {
                    self?.loading = false
                    self?.enrichedMovie = movie
                    self?.errorMessage = error?.localizedDescription
                }
            }
        } else if media is Show {
            PopcornKit.getShowInfo(media.id) { [weak self] show, error in
                DispatchQueue.main.async {
                    self?.loading = false
                    self?.enrichedShow = show
                    self?.errorMessage = error?.localizedDescription
                    if let show = show { self?.augmentEpisodeTorrents(for: show) }
                }
            }
        }
    }

    /// The episode the "Lecture" button will play (first unwatched, else first).
    private func targetEpisode(of show: Show) -> Episode? {
        show.episodes.first(where: { !$0.isWatched }) ?? show.episodes.first
    }

    /// EZTV carries only what its uploaders pushed, so ask Torrentio and the
    /// Time4Popcorn backend for the chosen episode too and merge — matching
    /// the tvOS play flow so the Mac/iOS series screen gets the same sources.
    private func augmentEpisodeTorrents(for show: Show) {
        guard show.id.hasPrefix("tt"), let episode = targetEpisode(of: show) else { return }
        let base = episode.torrents
        let group = DispatchGroup()
        var aggregated: [Torrent] = []
        var t4p: [Torrent] = []

        group.enter()
        TorrentioClient.shared.streams(imdbId: show.id, season: episode.season, episode: episode.episode) { torrents in
            aggregated = torrents
            group.leave()
        }
        group.enter()
        Time4PopcornClient.shared.episodeTorrents(imdbId: show.id, season: episode.season, episode: episode.episode) { torrents in
            t4p = torrents
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            // T4P primary, EZTV + Torrentio as fallback.
            self?.augmentedEpisodeTorrents = TorrentioClient.merge(t4p, with: base + aggregated)
        }
    }

    /// Sorted torrents (best quality first). For a Show, prefer the augmented
    /// episode list (EZTV + Torrentio + T4P) once ready, else the EZTV-only
    /// torrents of the first available unwatched episode.
    var torrents: [Torrent] {
        if let movie = enrichedMovie { return movie.torrents.sorted(by: >) }
        if let show = enrichedShow {
            if let augmented = augmentedEpisodeTorrents { return augmented.sorted(by: >) }
            return (targetEpisode(of: show)?.torrents ?? []).sorted(by: >)
        }
        return []
    }

    /// What the "Lecture" button plays: the movie, or the show's target
    /// episode (subtitles are searched and progress saved for THAT episode,
    /// not for the show).
    var defaultPlaybackMedia: Media? {
        if let movie = enrichedMovie { return movie }
        if let show = enrichedShow, let episode = targetEpisode(of: show) { return playable(episode) }
        return nil
    }

    /// The episode with its show attached (OpenSubtitles searches episodes
    /// by the SHOW's imdb id).
    func playable(_ episode: Episode) -> Episode {
        var episode = episode
        if episode.show == nil { episode.show = enrichedShow }
        return episode
    }
}

/// One playback session shown in the full-screen cover. The engine is chosen
/// from the REAL payload file name (`PlaybackRouting`) once the torrent is
/// ready: MKV/WebM → remux → AVPlayer, MP4/MOV → AVPlayer directly, other
/// containers → VLC. A native engine that fails swaps `engine` to `.vlc` IN
/// PLACE (same `id`, so the cover stays up and the torrent stream is handed
/// over, not restarted).
private struct PendingPlayback: Identifiable {
    let id = UUID()
    /// The torrent's local HTTP endpoint (as reported by the streamer).
    let url: URL
    /// The payload on disk (still downloading) — remux input, routing name.
    let localFile: URL
    var engine: PlaybackRoute
    let title: String
    let streamer: PTTorrentStreamer?
    /// The movie or episode being played (subtitles, watched progress).
    let media: Media
    /// Release name carried the Atmos tag — signal JOC in the remux dec3 box.
    let isAtmos: Bool
    /// Release name carried HDR / DV tags (remux VIDEO-RANGE hint).
    let releaseHintsHDR: Bool
    /// 0…1 position to resume at.
    var startPosition: Float
}

/// The full-screen player for one `PendingPlayback`.
private struct PlaybackScreen: View {
    let playback: PendingPlayback
    let onFallback: (_ reason: String, _ resumeFraction: Float, _ resumeDecided: Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        switch playback.engine {
        case .remux:
            RemuxPlayerView(localFile: playback.localFile,
                            remoteURL: playback.url,
                            title: playback.title,
                            streamer: playback.streamer,
                            media: playback.media,
                            isAtmos: playback.isAtmos,
                            releaseHintsHDR: playback.releaseHintsHDR,
                            startPosition: playback.startPosition,
                            onFallback: onFallback,
                            onClose: onClose)
                .ignoresSafeArea()
                // Audio / subtitle tracks are native HLS renditions here
                // (AVKit's own menus) — only the close button is ours.
                .overlay(alignment: .topTrailing) {
                    PlayerChromeButtons(subtitles: nil, onClose: onClose)
                }
        case .avPlayer:
            DirectPlayerScreen(playback: playback, onFallback: onFallback, onClose: onClose)
        case .vlc:
            // Resumes where the native player stopped (fallback), at the
            // saved progress the user chose to resume at (« Reprendre à … »
            // on a still-downloading MKV: VLC seeks over HTTP ranges), or at
            // the saved progress (container VLC-only from the start).
            VLCPlayerView(url: playback.url,
                          title: playback.title,
                          streamer: playback.streamer,
                          subtitles: playback.media.subtitles,
                          media: playback.media,
                          startPosition: playback.startPosition)
                .ignoresSafeArea()
        }
    }
}

/// MP4 / M4V / MOV straight into AVPlayer, with OpenSubtitles drawn over the
/// video (a progressive file has no sidecar subtitle tracks of its own).
private struct DirectPlayerScreen: View {
    let playback: PendingPlayback
    let onFallback: (_ reason: String, _ resumeFraction: Float, _ resumeDecided: Bool) -> Void
    let onClose: () -> Void
    @StateObject private var subtitles: SubtitleCueController
    @State private var didAutoSelectSubtitle = false

    init(playback: PendingPlayback,
         onFallback: @escaping (_ reason: String, _ resumeFraction: Float, _ resumeDecided: Bool) -> Void,
         onClose: @escaping () -> Void) {
        self.playback = playback
        self.onFallback = onFallback
        self.onClose = onClose
        _subtitles = StateObject(wrappedValue: SubtitleCueController(subtitles: playback.media.subtitles))
    }

    var body: some View {
        let streamer = playback.streamer
        let cues = subtitles
        ZStack {
            VideoPlayerWrapper(url: PlaybackRouting.playableLocalURL(playback.url, fileName: playback.localFile.lastPathComponent),
                               title: playback.title,
                               media: playback.media,
                               startPosition: playback.startPosition,
                               // Completion only (1.0): at 0.999 up to 0.1 % is still missing.
                               // Also lets a starved player wait for more data.
                               downloadProgress: { streamer?.torrentStatus.totalProgress ?? 1 },
                               onPlayerReady: { player in
                                   // Not during the view update that created it.
                                   DispatchQueue.main.async { cues.attach(to: player) }
                               },
                               onItemReplaced: { item in
                                   // Rebuilt after download starvation: the overlay
                                   // coordinates with the new item's own subtitles.
                                   cues.bindNativeSubtitles(of: item)
                               },
                               onFallback: onFallback)
                .ignoresSafeArea()
            SubtitleOverlayText(controller: subtitles)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            PlayerChromeButtons(subtitles: subtitles, onClose: onClose)
        }
        .onAppear { subtitles.loadSubtitlesIfNeeded(for: playback.media) }
        // Preferred subtitle language, once the list is known. `$available`
        // fires before the property changes — hop a turn.
        .onReceive(subtitles.$available.receive(on: DispatchQueue.main)) { list in
            guard !didAutoSelectSubtitle, !list.isEmpty else { return }
            didAutoSelectSubtitle = true
            if subtitles.selected == nil { subtitles.autoSelectPreferred() }
        }
        .onDisappear { subtitles.detach() }
    }
}

/// Close button (+ subtitle menu on the direct path) over AVKit's controls —
/// an AVPlayerViewController embedded in a SwiftUI cover has no "Done"
/// button of its own. Fades out of the way after a few seconds but stays
/// tappable.
private struct PlayerChromeButtons: View {
    let subtitles: SubtitleCueController?
    let onClose: () -> Void
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: 12) {
            if let subtitles = subtitles {
                SubtitleMenuButton(controller: subtitles)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fermer")
        }
        .padding(.top, 8)
        .padding(.trailing, 16)
        .opacity(dimmed ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.4), value: dimmed)
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            dimmed = true
        }
    }
}

struct MediaDetailView: View {
    let media: Media
    @StateObject private var viewModel = MediaDetailViewModel()
    @State private var pendingPlayback: PendingPlayback?
    @State private var startingStream = false
    @State private var bufferProgress: Float = 0
    @State private var seedsCount: Int = 0
    @State private var peersCount: Int = 0
    @State private var downloadKbps: Double = 0
    @State private var streamErrorMessage: String?
    @State private var safariURL: IdentifiableURL?
    @State private var selectedSeason: Int = 0
    @AppStorage("autoSelectQuality") private var autoQuality = "Balanced"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                actionRow
                summary
                if viewModel.enrichedMovie != nil {
                    movieTorrentList
                } else if let show = viewModel.enrichedShow, !show.episodes.isEmpty {
                    seasonEpisodeSection(show)
                }
                castSection
                relatedSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle(media.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.load(media) }
        .onChange(of: viewModel.enrichedShow?.id) { _, _ in
            if selectedSeason == 0, let first = viewModel.enrichedShow?.seasonNumbers.first {
                selectedSeason = first
            }
        }
        .fullScreenCover(item: $pendingPlayback, onDismiss: endPlayback) { item in
            // Read the live state: a fallback mutates the engine in place.
            PlaybackScreen(playback: pendingPlayback ?? item,
                           onFallback: { reason, resumeFraction, resumeDecided in
                               handOffToVLC(reason: reason, resumeFraction: resumeFraction, resumeDecided: resumeDecided)
                           },
                           onClose: { pendingPlayback = nil })
        }
        .sheet(item: $safariURL) { item in
            SafariSheet(url: item.url)
                .ignoresSafeArea()
        }
        .sheet(item: $viewModel.episodeSources) { sources in
            QualityPickerSheet(title: sources.title, torrents: sources.torrents) { torrent in
                viewModel.episodeSources = nil
                play(torrent, media: sources.episode ?? media)
            }
        }
        .alert("Aucune source",
               isPresented: Binding(get: { viewModel.noSourcesMessage != nil },
                                    set: { if !$0 { viewModel.noSourcesMessage = nil } })) {
            Button("OK", role: .cancel) { viewModel.noSourcesMessage = nil }
        } message: {
            Text(viewModel.noSourcesMessage ?? "")
        }
        .overlay { streamingOverlay }
    }

    /// Season picker + episode list. Tapping an episode resolves its sources
    /// (T4P first, then EZTV/Torrentio) and presents the quality picker.
    @ViewBuilder
    private func seasonEpisodeSection(_ show: Show) -> some View {
        let season = selectedSeason == 0 ? (show.seasonNumbers.first ?? 1) : selectedSeason
        let episodes = show.episodes.filter { $0.season == season }.sorted { $0.episode < $1.episode }

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Épisodes").font(.headline)
                Spacer()
                if show.seasonNumbers.count > 1 {
                    Picker("Saison", selection: $selectedSeason) {
                        ForEach(show.seasonNumbers, id: \.self) { s in
                            Text("Saison \(s)").tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            ForEach(episodes, id: \.id) { episode in
                Button {
                    viewModel.loadEpisodeSources(episode, showId: show.id)
                } label: {
                    HStack(spacing: 12) {
                        Text("\(episode.episode)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.title.isEmpty ? "Épisode \(episode.episode)" : episode.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if !episode.summary.isEmpty,
                               episode.summary != "No summary available.".localized {
                                Text(episode.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        if viewModel.loadingSourcesFor == episode.id {
                            ProgressView()
                        } else {
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.tint)
                                .font(.title2)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.loadingSourcesFor != nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var streamingOverlay: some View {
        if startingStream {
            VStack(spacing: 14) {
                ProgressView(value: Double(bufferProgress))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(width: 240)
                Text(bufferProgress > 0
                     ? String(format: "Buffering · %.0f %%", bufferProgress * 100)
                     : "Recherche de peers…")
                    .font(.headline)
                if seedsCount > 0 || peersCount > 0 {
                    Text("\(seedsCount) seeds · \(peersCount) peers · \(formatKbps(downloadKbps))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let err = streamErrorMessage {
                    Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal, 8)
                }
                Button("Annuler", role: .cancel) { cancelStream() }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 24)
        }
    }

    private func formatKbps(_ kbps: Double) -> String {
        if kbps >= 1024 { return String(format: "%.1f MB/s", kbps / 1024) }
        return String(format: "%.0f KB/s", kbps)
    }

    private func cancelStream() {
        PTTorrentStreamer.shared().cancelStreamingAndDeleteData(true)
        startingStream = false
        bufferProgress = 0
        seedsCount = 0
        peersCount = 0
        downloadKbps = 0
        streamErrorMessage = nil
    }

    @ViewBuilder
    private var hero: some View {
        if let urlStr = media.largeBackgroundImage, let url = URL(string: urlStr) {
            // `Color.clear` carries the 16:9 aspect ratio; the AsyncImage is
            // overlaid on top and clipped. We cap the height at 320 so on a
            // wide / tall Mac window the hero doesn't push the rest of the
            // detail off the fold. `aspectRatio(.fit)` (vs `.fill`) is
            // critical: with `.fill` SwiftUI grows the view past the parent
            // width on tall narrow viewports, dragging the surrounding VStack
            // wider than the window and clipping summary/torrent text on
            // both sides.
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 320)
                .overlay {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Color(.systemGray6)
                        }
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                playFirstAvailable()
            } label: {
                Label("Lecture", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.torrents.isEmpty)

            if let trailerURL = trailerURL {
                Button {
                    safariURL = IdentifiableURL(url: trailerURL)
                } label: {
                    Image(systemName: "play.rectangle")
                        .font(.title3)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 18)
                }
                .buttonStyle(.bordered)
            }

            Button {
                // Watchlist - stub for now.
            } label: {
                Image(systemName: "plus")
                    .font(.title3)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 18)
            }
            .buttonStyle(.bordered)
        }
    }

    /// Build a YouTube watch URL from the YTS `yt_trailer_code` if available
    /// on the enriched movie. We send the user to Safari (or
    /// SFSafariViewController) rather than embedding XCDYouTubeKit — that
    /// pod's iOS-8 deployment target broke under Xcode 26's libarclite
    /// removal, and Safari handles AirPlay / picture-in-picture for free.
    private var trailerURL: URL? {
        if let movie = viewModel.enrichedMovie ?? (media as? Movie),
           let raw = movie.trailer, !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return nil
    }

    @ViewBuilder
    private var summary: some View {
        if let movie = viewModel.enrichedMovie {
            VStack(alignment: .leading, spacing: 8) {
                Text(movie.title).font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(metadataLine(year: movie.year, runtime: movie.runtime, certification: movie.certification, rating: 0))
                        .font(.subheadline).foregroundStyle(.secondary)
                    StarRatingView(rating: movie.rating)
                }
                .fixedSize(horizontal: false, vertical: true)
                Text(movie.summary)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let show = viewModel.enrichedShow {
            VStack(alignment: .leading, spacing: 8) {
                Text(show.title).font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("\(show.year)\(show.network.map { " · \($0)" } ?? "")")
                        .font(.subheadline).foregroundStyle(.secondary)
                    StarRatingView(rating: show.rating)
                }
                .fixedSize(horizontal: false, vertical: true)
                Text(show.summary)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if viewModel.loading {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var movieTorrentList: some View {
        if !viewModel.torrents.isEmpty {
            let recommended = Torrent.recommendedURL(in: viewModel.torrents)
            VStack(alignment: .leading, spacing: 8) {
                Text("Qualités disponibles").font(.headline)
                ForEach(viewModel.torrents, id: \.url) { torrent in
                    Button {
                        play(torrent, media: viewModel.enrichedMovie ?? media)
                    } label: {
                        TorrentPickerRow(torrent: torrent, recommended: torrent.url == recommended)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var castSection: some View {
        if let movie = viewModel.enrichedMovie {
            CastScroller(directors: directorNames(movie.crew), actors: movie.actors)
        } else if let show = viewModel.enrichedShow {
            CastScroller(directors: directorNames(show.crew), actors: show.actors)
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        if let movie = viewModel.enrichedMovie, !movie.related.isEmpty {
            RelatedRow(title: "Vus aussi", items: movie.related)
        } else if let show = viewModel.enrichedShow, !show.related.isEmpty {
            RelatedRow(title: "Vus aussi", items: show.related)
        }
    }

    private func directorNames(_ crew: [Crew]) -> [String] {
        var seen = Set<String>()
        return crew.filter { $0.roleType == .director }.map(\.name).filter { seen.insert($0).inserted }
    }

    private func metadataLine(year: String, runtime: Int, certification: String, rating: Float) -> String {
        var parts: [String] = []
        if !year.isEmpty           { parts.append(year) }
        if runtime > 0             { parts.append("\(runtime) min") }
        if !certification.isEmpty,
           certification != "Unrated" { parts.append(certification) }
        if rating > 0              { parts.append(String(format: "★ %.1f", rating / 10.0)) }
        return parts.joined(separator: " · ")
    }

    private func playFirstAvailable() {
        let torrents = viewModel.torrents   // sorted best-quality first
        guard !torrents.isEmpty else { return }
        let pick: Torrent?
        switch autoQuality {
        case "Highest": pick = torrents.first
        case "Lowest":
            // Smallest resolution bucket, best-playing release inside it
            // (the list is sorted best first, so its first entry wins).
            let lowestBucket = torrents.last?.qualityValue
            pick = torrents.first(where: { $0.qualityValue == lowestBucket })
        default:        pick = Torrent.balancedPick(from: torrents)  // Balanced / choose-each-time
        }
        if let pick = pick { play(pick, media: viewModel.defaultPlaybackMedia ?? media) }
    }

    /// Watched progress (0…1) saved by the native / VLC players.
    private static func savedProgress(for media: Media) -> Float {
        if let movie = media as? Movie { return WatchedlistManager<Movie>.movie.currentProgress(movie.id) }
        if let episode = media as? Episode { return WatchedlistManager<Episode>.episode.currentProgress(episode.id) }
        return 0
    }

    /// Stream `torrent` and, once it is ready, open the player picked from
    /// the REAL payload name. `playMedia` is the movie or the EPISODE.
    private func play(_ torrent: Torrent, media playMedia: Media) {
        startingStream = true
        bufferProgress = 0
        seedsCount = 0
        peersCount = 0
        downloadKbps = 0
        streamErrorMessage = nil
        let streamer = PTTorrentStreamer.shared()
        let mediaTitle = playMedia.title
        let magnet = torrent.url
        let isAtmos = torrent.tags.contains(.atmos)
        let hintsHDR = !torrent.tags.isDisjoint(with: [.hdr10, .hdr10Plus, .dolbyVision])
        // A finished (or nearly finished) title restarts from the beginning
        // on every engine — VLC too, which resumes without asking (the native
        // players apply the same rule again).
        let startPosition = ResumePolicy.startPosition(forSavedProgress: Self.savedProgress(for: playMedia))
        // Clean slate before a new stream: reset the streamer and reclaim disk
        // from prior torrent partials + orphaned remux output (same as tvOS).
        streamer.cancelStreamingAndDeleteData(true)
        purgeOrphanTorrentDownloads()
        print("[iOS Detail] starting torrent: \(magnet.prefix(80))…")

        let progress: PTTorrentStreamerProgress = { status in
            DispatchQueue.main.async {
                bufferProgress = status.bufferingProgress
                seedsCount = Int(status.seeds)
                peersCount = Int(status.peers)
                // libtorrent reports bytes/s; surface as KB/s.
                downloadKbps = Double(status.downloadSpeed) / 1024.0
            }
        }
        let readyToPlay: PTTorrentStreamerReadyToPlay = { fileURL, filePath in
            DispatchQueue.main.async {
                startingStream = false
                // Route on the REAL payload name (magnet display names often
                // carry no extension). Unknown → remux, which fails fast to VLC.
                let route = PlaybackRouting.route(forFileName: filePath.lastPathComponent)
                print("[iOS Detail] ready: \(filePath.lastPathComponent) → \(route)")
                pendingPlayback = PendingPlayback(url: fileURL,
                                                  localFile: filePath,
                                                  engine: route,
                                                  title: mediaTitle,
                                                  streamer: streamer,
                                                  media: playMedia,
                                                  isAtmos: isAtmos,
                                                  releaseHintsHDR: hintsHDR,
                                                  startPosition: startPosition)
            }
        }
        let failure: PTTorrentStreamerFailure = { error in
            DispatchQueue.main.async {
                streamErrorMessage = error.localizedDescription
                // Keep the overlay open so the user sees the error and can dismiss
                // explicitly via the "Annuler" button.
                bufferProgress = 0
            }
            print("[iOS Detail] streaming failure: \(error.localizedDescription)")
        }

        // Single-file API only, even when the magnet carries a BEP 53 `so=`
        // index (kept in the magnet: harmless). The iOS/tvOS PopcornTorrent
        // pod (1.3.15 binary) keeps a GLOBAL "user selects the file" flag
        // after a cancel when its multi-file API was used — the next
        // single-file stream or any download then calls a nil block and
        // crashes — and in multi-file mode it still serves the torrent's
        // LARGEST file, not the `so=` one. (Season packs are filtered out of
        // the episode sources on iOS/tvOS for that reason; the macOS
        // streamer honours `so=` per instance.)
        streamer.startStreaming(fromFileOrMagnetLink: magnet,
                                progress: progress,
                                readyToPlay: readyToPlay,
                                failure: failure)
    }

    /// A native engine gave up: continue on VLC with the SAME stream. The
    /// engine is swapped in place (same cover), from the reached position
    /// (at most 99.5 %: a failure in the end credits doesn't restart the
    /// movie). `resumeDecided` is informational here: the iOS VLC player
    /// has no resume question of its own — it continues at `resumeFraction`
    /// either way, as when VLC is the first engine.
    private func handOffToVLC(reason: String, resumeFraction: Float, resumeDecided: Bool) {
        guard var playback = pendingPlayback, playback.engine != .vlc else { return }
        print("[iOS Detail] native player → VLC fallback (\(reason)) at \(Int(resumeFraction * 100)) %"
              + (resumeDecided ? "" : " (resume not decided by the user)"))
        playback.engine = .vlc
        playback.startPosition = resumeFraction
        pendingPlayback = playback
    }

    /// The player cover closed (any engine): stop the torrent. The players
    /// already cancel it themselves; this also covers the direct AVPlayer
    /// path, which has no hook into the streamer.
    private func endPlayback() {
        PTTorrentStreamer.shared().cancelStreamingAndDeleteData(false)
    }
}

/// Quality picker shown after selecting an episode — lists every resolved
/// source (best quality first) and plays the chosen one.
private struct QualityPickerSheet: View {
    let title: String
    let torrents: [Torrent]
    let onSelect: (Torrent) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let recommended = Torrent.recommendedURL(in: torrents)
        NavigationStack {
            List(torrents, id: \.url) { torrent in
                Button {
                    onSelect(torrent)
                } label: {
                    TorrentPickerRow(torrent: torrent, recommended: torrent.url == recommended)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
