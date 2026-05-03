

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

struct MediaDetailView: View {
    let media: Media
    @StateObject private var viewModel = MediaDetailViewModel()
    @State private var presentedURL: URL?
    @State private var startingStream = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                actionRow
                summary
                torrentList
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle(media.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.load(media) }
        .fullScreenCover(item: $presentedURL) { url in
            VideoPlayerWrapper(url: url)
                .ignoresSafeArea()
        }
        .overlay {
            if startingStream { ProgressView("Démarrage du stream…").padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)) }
        }
    }

    @ViewBuilder
    private var hero: some View {
        if let urlStr = media.largeBackgroundImage, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Color(.systemGray6)
                }
            }
            .aspectRatio(16/9, contentMode: .fill)
            .frame(maxWidth: .infinity)
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

            Button {
                // Watchlist — stub for now.
            } label: {
                Image(systemName: "plus")
                    .font(.title3)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 18)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let movie = viewModel.enrichedMovie {
            VStack(alignment: .leading, spacing: 8) {
                Text(movie.title).font(.title2.bold())
                Text(metadataLine(year: movie.year, runtime: movie.runtime, certification: movie.certification, rating: movie.rating))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(movie.summary)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.top, 4)
            }
        } else if let show = viewModel.enrichedShow {
            VStack(alignment: .leading, spacing: 8) {
                Text(show.title).font(.title2.bold())
                Text("\(show.year)\(show.network.map { " · \($0)" } ?? "")")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(show.summary)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.top, 4)
            }
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
                            Spacer()
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.tint)
                                .font(.title2)
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
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
        let streamer = PTTorrentStreamer.shared()
        streamer.cancelStreamingAndDeleteData(false)
        streamer.startStreaming(fromFileOrMagnetLink: torrent.url, progress: { _ in
            // Hook a progress UI here later.
        }, readyToPlay: { fileURL, _ in
            DispatchQueue.main.async {
                startingStream = false
                presentedURL = fileURL
            }
        }, failure: { error in
            DispatchQueue.main.async {
                startingStream = false
            }
            print("[iOS Detail] streaming failure: \(error.localizedDescription)")
        })
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }
