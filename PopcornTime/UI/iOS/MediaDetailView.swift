

import SwiftUI
import PopcornKit
import AVKit
import PopcornTorrent

@MainActor
final class MediaDetailViewModel: ObservableObject {
    @Published var enrichedMovie: Movie?
    @Published var enrichedShow:  Show?
    @Published var loading = false
    @Published var errorMessage: String?

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
                }
            }
        }
    }

    /// Sorted torrents (best quality first). When the underlying media is a
    /// Show with episodes, returns the torrents of the first available
    /// unwatched episode — matches the tvOS auto-pick behaviour.
    var torrents: [Torrent] {
        if let movie = enrichedMovie { return movie.torrents.sorted(by: >) }
        if let show = enrichedShow {
            // Pick the first unwatched episode, or fall back to the first
            // available one. The legacy tvOS app has a richer
            // `latestUnwatchedEpisode()` helper that walks WatchedlistManager,
            // but for the SwiftUI surface this simpler pick is enough.
            let next = show.episodes.first(where: { !$0.isWatched }) ?? show.episodes.first
            return (next?.torrents ?? []).sorted(by: >)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                actionRow
                summary
                torrentList
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle(media.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.load(media) }
        .fullScreenCover(item: $pendingPlayback) { item in
            Group {
                switch item.engine {
                case .avPlayer:
                    VideoPlayerWrapper(url: item.url)
                case .vlc:
                    VLCPlayerView(url: item.url, title: item.title, streamer: item.streamer)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $safariURL) { item in
            SafariSheet(url: item.url)
                .ignoresSafeArea()
        }
        .overlay { streamingOverlay }
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
    private var torrentList: some View {
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
        guard let best = viewModel.torrents.first else { return }
        play(best)
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
        }, readyToPlay: { fileURL, _ in
            DispatchQueue.main.async {
                startingStream = false
                let engine = sniffEngine(for: fileURL, magnetFallback: magnet)
                pendingPlayback = PendingPlayback(url: fileURL,
                                                  engine: engine,
                                                  title: mediaTitle,
                                                  streamer: streamer)
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
