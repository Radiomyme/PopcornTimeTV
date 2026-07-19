

import SwiftUI
import PopcornKit

/// Detail screen for a movie or show: artwork, synopsis, quality picker and
/// play. Uses the exact same PopcornKit enrichment + Torrentio/T4P
/// augmentation as the iOS `MediaDetailView`.
struct MacMediaDetailView: View {
    let media: Media

    @State private var enrichedMovie: Movie?
    @State private var enrichedShow: Show?
    @State private var loading = true
    @State private var errorMessage: String?
    /// Episode → augmented torrents (filled lazily per episode).
    @State private var episodeTorrents: [String: [Torrent]] = [:]
    @State private var playback: MacPendingPlayback?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let message = errorMessage {
                    Text(message).foregroundStyle(.red)
                }
                if let show = enrichedShow {
                    episodeList(show)
                }
            }
            .padding(24)
        }
        .navigationTitle(media.title)
        .task { load() }
        .sheet(item: $playback) { item in
            MacPlayerView(playback: item)
                .frame(minWidth: 1024, minHeight: 576)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            AsyncImage(url: (media.mediumCoverImage ?? media.smallCoverImage).flatMap { URL(string: $0) }) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFill() }
                else { Color(nsColor: .underPageBackgroundColor) }
            }
            .frame(width: 220, height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 8)

            VStack(alignment: .leading, spacing: 12) {
                Text(media.title).font(.largeTitle.weight(.bold))
                if let movie = enrichedMovie {
                    Text("\(movie.year) · \(movie.runtime) min")
                        .foregroundStyle(.secondary)
                    Text(movie.summary).font(.body).foregroundStyle(.primary)
                        .frame(maxWidth: 600, alignment: .leading)
                } else if let show = enrichedShow {
                    Text(show.year).foregroundStyle(.secondary)
                    Text(show.summary).font(.body)
                        .frame(maxWidth: 600, alignment: .leading)
                }
                if loading { ProgressView() }
                if let movie = enrichedMovie, !movie.torrents.isEmpty {
                    playMenu(title: movie.title, torrents: movie.torrents.sorted(by: >), media: movie)
                }
            }
            Spacer()
        }
    }

    /// "Lecture" button exposing one entry per quality.
    private func playMenu(title: String, torrents: [Torrent], media: Media) -> some View {
        Menu {
            ForEach(Array(torrents.enumerated()), id: \.offset) { _, torrent in
                Button("\(torrent.quality ?? "?") — \(torrent.seeds) seeds") {
                    start(torrent, media: media, title: title)
                }
            }
        } label: {
            Label("Lecture", systemImage: "play.fill")
        }
        .menuStyle(.button)
        .controlSize(.large)
        .disabled(torrents.isEmpty)
    }

    // MARK: Episodes (shows)

    private func episodeList(_ show: Show) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Épisodes").font(.title2.weight(.semibold))
            ForEach(show.episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }, id: \.id) { episode in
                HStack {
                    VStack(alignment: .leading) {
                        Text("S\(String(format: "%02d", episode.season))E\(String(format: "%02d", episode.episode)) — \(episode.title)")
                            .font(.body.weight(.medium))
                    }
                    Spacer()
                    let torrents = episodeTorrents[episode.id] ?? episode.torrents
                    playMenu(title: "\(show.title) — \(episode.title)",
                             torrents: torrents.sorted(by: >),
                             media: episode)
                        .onAppear { augment(episode, showId: show.id) }
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    /// EZTV alone is thin — merge Torrentio + Time4Popcorn for the episode,
    /// exactly like the iOS/tvOS play flows.
    private func augment(_ episode: Episode, showId: String) {
        guard showId.hasPrefix("tt"), episodeTorrents[episode.id] == nil else { return }
        let base = episode.torrents
        TorrentioClient.shared.streams(imdbId: showId, season: episode.season, episode: episode.episode) { aggregated in
            Time4PopcornClient.shared.episodeTorrents(imdbId: showId, season: episode.season, episode: episode.episode) { t4p in
                DispatchQueue.main.async {
                    var merged = t4p + base
                    for torrent in aggregated where !merged.contains(where: { $0.url == torrent.url }) {
                        merged.append(torrent)
                    }
                    episodeTorrents[episode.id] = merged
                }
            }
        }
    }

    // MARK: Data

    private func load() {
        guard enrichedMovie == nil && enrichedShow == nil else { return }
        if media is Movie {
            PopcornKit.getMovieInfo(media.id) { movie, error in
                DispatchQueue.main.async {
                    loading = false
                    enrichedMovie = movie
                    errorMessage = error?.localizedDescription
                }
            }
        } else if media is Show {
            PopcornKit.getShowInfo(media.id) { show, error in
                DispatchQueue.main.async {
                    loading = false
                    enrichedShow = show
                    errorMessage = error?.localizedDescription
                }
            }
        }
    }

    /// Fetch subtitles then hand off to the player sheet.
    private func start(_ torrent: Torrent, media: Media, title: String) {
        var target = media
        if let episode = media as? Episode {
            SubtitlesManager.shared.search(episode, imdbId: enrichedShow?.id) { subtitles, _ in
                DispatchQueue.main.async {
                    target.subtitles = subtitles
                    playback = MacPendingPlayback(torrent: torrent, media: target, title: title)
                }
            }
        } else {
            SubtitlesManager.shared.search(imdbId: media.id) { subtitles, _ in
                DispatchQueue.main.async {
                    target.subtitles = subtitles
                    playback = MacPendingPlayback(torrent: torrent, media: target, title: title)
                }
            }
        }
    }
}

/// Everything the player sheet needs to start streaming.
struct MacPendingPlayback: Identifiable {
    let id = UUID()
    let torrent: Torrent
    let media: Media
    let title: String
}
