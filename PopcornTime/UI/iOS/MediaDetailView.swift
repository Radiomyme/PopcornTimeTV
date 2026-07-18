

import SwiftUI
import PopcornKit
import AVKit
import PopcornTorrent

/// The torrents found for one episode, ready to drive a quality-picker sheet.
struct EpisodeSources: Identifiable {
    let id = UUID()
    let title: String
    let torrents: [Torrent]
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
                self.episodeSources = EpisodeSources(title: title, torrents: merged)
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
}

/// Picks AVPlayer for AV-friendly containers (.mp4 / .m4v / .mov — HDR10,
/// Dolby Vision, Atmos all native on tvOS/iOS) and VLC for everything else
/// (.mkv / .avi / unknown — most YTS 4K HEVC ships in MKV containers that
/// AVFoundation can't open at all).
private enum PreferredEngine {
    case avPlayer
    case vlc
    /// MKV with DD+ audio: remux to fMP4/HLS on the fly and play via
    /// AVPlayer for true Dolby Atmos (see RemuxPlayback).
    case remux
}

private func sniffEngine(for url: URL, magnetFallback: String?) -> PreferredEngine {
    let candidates: [String] = {
        var out: [String] = []
        out.append(url.path.lowercased())
        if let magnet = magnetFallback,
           let dn = magnet.components(separatedBy: "&dn=").last?
                          .components(separatedBy: "&").first?
                          .removingPercentEncoding?.lowercased() {
            out.append(dn)
        }
        return out
    }()
    let avFriendly = [".mp4", ".m4v", ".mov"]
    if candidates.contains(where: { c in avFriendly.contains { c.hasSuffix($0) } }) {
        return .avPlayer
    }
    return .vlc
}

private struct PendingPlayback: Identifiable {
    let id = UUID()
    let url: URL
    let engine: PreferredEngine
    let title: String
    let streamer: PTTorrentStreamer?
    /// Local path of the (still downloading) payload — remux engine input.
    var localFile: URL? = nil
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
        .fullScreenCover(item: $pendingPlayback) { item in
            Group {
                switch item.engine {
                case .avPlayer:
                    VideoPlayerWrapper(url: item.url)
                case .vlc:
                    VLCPlayerView(url: item.url, title: item.title, streamer: item.streamer)
                case .remux:
                    RemuxPlayerView(localFile: item.localFile ?? item.url, title: item.title, streamer: item.streamer, media: media)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $safariURL) { item in
            SafariSheet(url: item.url)
                .ignoresSafeArea()
        }
        .sheet(item: $viewModel.episodeSources) { sources in
            QualityPickerSheet(title: sources.title, torrents: sources.torrents) { torrent in
                viewModel.episodeSources = nil
                play(torrent)
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
                Text(metadataLine(year: movie.year, runtime: movie.runtime, certification: movie.certification, rating: movie.rating))
                    .font(.subheadline).foregroundStyle(.secondary)
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
                Text("\(show.year)\(show.network.map { " · \($0)" } ?? "")")
                    .font(.subheadline).foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Qualités disponibles").font(.headline)
                ForEach(viewModel.torrents, id: \.url) { torrent in
                    Button {
                        play(torrent)
                    } label: {
                        HStack {
                            Image(systemName: "film")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(torrent.quality ?? "—").font(.subheadline.weight(.semibold))
                                Text("\(torrent.seeds) seeds · \(torrent.size ?? "—")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.tint)
                                .font(.title2)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        case "Lowest":  pick = torrents.last
        default:        pick = Torrent.balancedPick(from: torrents)  // Balanced / choose-each-time
        }
        if let pick = pick { play(pick) }
    }

    private func play(_ torrent: Torrent) {
        startingStream = true
        bufferProgress = 0
        seedsCount = 0
        peersCount = 0
        downloadKbps = 0
        streamErrorMessage = nil
        let streamer = PTTorrentStreamer.shared()
        let mediaTitle = media.title
        let magnet = torrent.url
        streamer.cancelStreamingAndDeleteData(false)
        print("[iOS Detail] starting torrent: \(magnet.prefix(80))…")
        streamer.startStreaming(fromFileOrMagnetLink: torrent.url, progress: { status in
            DispatchQueue.main.async {
                bufferProgress = status.bufferingProgress
                seedsCount = Int(status.seeds)
                peersCount = Int(status.peers)
                // libtorrent reports bytes/s; surface as KB/s.
                downloadKbps = Double(status.downloadSpeed) / 1024.0
            }
        }, readyToPlay: { fileURL, filePath in
            DispatchQueue.main.async {
                startingStream = false
                var engine = sniffEngine(for: fileURL, magnetFallback: magnet)
                if engine == .vlc && RemuxPlayback.canRemux(magnet: magnet, tags: torrent.tags) {
                    engine = .remux
                }
                pendingPlayback = PendingPlayback(url: fileURL,
                                                  engine: engine,
                                                  title: mediaTitle,
                                                  streamer: streamer,
                                                  localFile: filePath)
            }
        }, failure: { error in
            DispatchQueue.main.async {
                streamErrorMessage = error.localizedDescription
                // Keep the overlay open so the user sees the error and can dismiss
                // explicitly via the "Annuler" button.
                bufferProgress = 0
            }
            print("[iOS Detail] streaming failure: \(error.localizedDescription)")
        })
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
        NavigationStack {
            List(torrents, id: \.url) { torrent in
                Button {
                    onSelect(torrent)
                } label: {
                    HStack {
                        Image(systemName: "film").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(torrent.quality ?? "—").font(.subheadline.weight(.semibold))
                            Text("\(torrent.seeds) seeds · \(torrent.size ?? "—")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "play.circle.fill").foregroundStyle(.tint).font(.title2)
                    }
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
