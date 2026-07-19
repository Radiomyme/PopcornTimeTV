

import SwiftUI
import PopcornKit

/// Detail screen for a movie or show, mirroring the iPad `MediaDetailView`
/// layout: 16:9 hero backdrop, title + metadata line, prominent Lecture
/// button, "Qualités disponibles" cards, and (for shows) a season picker with
/// episode cards. Same PopcornKit enrichment + Torrentio/T4P augmentation.
struct MacMediaDetailView: View {
    let media: Media

    @State private var enrichedMovie: Movie?
    @State private var enrichedShow: Show?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var selectedSeason = 0
    /// Episode → augmented torrents (filled lazily per episode).
    @State private var episodeTorrents: [String: [Torrent]] = [:]
    @State private var loadingSourcesFor: String?
    @State private var playback: MacPendingPlayback?
    /// Episode whose quality picker is displayed.
    @State private var qualityChoices: MacEpisodeSources?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                summary
                if let message = errorMessage {
                    Text(message).foregroundStyle(.red)
                }
                if let movie = enrichedMovie {
                    movieTorrentList(movie)
                }
                if let show = enrichedShow {
                    seasonEpisodeSection(show)
                }
                castSection
                relatedSection
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(media.title)
        .task { load() }
        .sheet(item: $playback) { item in
            MacPlayerView(playback: item)
                .frame(minWidth: 1024, minHeight: 576)
        }
        .sheet(item: $qualityChoices) { sources in
            MacQualityPickerSheet(title: sources.title, torrents: sources.torrents) { torrent in
                qualityChoices = nil
                if let torrent = torrent {
                    start(torrent, media: sources.media, title: sources.title)
                }
            }
        }
    }

    // MARK: Hero (16:9 backdrop, capped height — same rules as iPad)

    @ViewBuilder
    private var hero: some View {
        let backdrop = enrichedMovie?.largeBackgroundImage
            ?? enrichedShow?.largeBackgroundImage
            ?? media.largeBackgroundImage
        if let urlString = backdrop, let url = URL(string: urlString) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 340)
                .overlay {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFill() }
                        else { Color(nsColor: .underPageBackgroundColor) }
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: Summary (title, metadata line, synopsis, action row)

    @ViewBuilder
    private var summary: some View {
        if let movie = enrichedMovie {
            VStack(alignment: .leading, spacing: 8) {
                Text(movie.title).font(.title.bold())
                HStack(spacing: 10) {
                    Text(metadataLine(year: movie.year, runtime: movie.runtime,
                                      certification: movie.certification, rating: 0))
                        .font(.subheadline).foregroundStyle(.secondary)
                    StarRatingView(rating: movie.rating)
                }
                Text(movie.summary).font(.body).padding(.top, 4)
                actionRow(torrents: movie.torrents.sorted(by: >), media: movie, title: movie.title)
                    .padding(.top, 8)
            }
        } else if let show = enrichedShow {
            VStack(alignment: .leading, spacing: 8) {
                Text(show.title).font(.title.bold())
                HStack(spacing: 10) {
                    Text("\(show.year)\(show.network.map { " · \($0)" } ?? "")")
                        .font(.subheadline).foregroundStyle(.secondary)
                    StarRatingView(rating: show.rating)
                }
                Text(show.summary).font(.body).padding(.top, 4)
            }
        } else if loading {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func actionRow(torrents: [Torrent], media: Media, title: String) -> some View {
        HStack(spacing: 12) {
            Button {
                if let best = torrents.first { start(best, media: media, title: title) }
            } label: {
                Label("Lecture", systemImage: "play.fill")
                    .font(.headline)
                    .frame(minWidth: 180)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(torrents.isEmpty)

            if let movie = enrichedMovie, let raw = movie.trailer, !raw.isEmpty, let url = URL(string: raw) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "play.rectangle").font(.title3)
                        .padding(.vertical, 8).padding(.horizontal, 14)
                }
                .buttonStyle(.bordered)
                .help("Bande-annonce")
            }
        }
    }

    // MARK: Movie quality cards ("Qualités disponibles" — same as iPad)

    @ViewBuilder
    private func movieTorrentList(_ movie: Movie) -> some View {
        let torrents = movie.torrents.sorted(by: >)
        if !torrents.isEmpty {
            let recommended = Torrent.recommendedURL(in: torrents)
            VStack(alignment: .leading, spacing: 8) {
                Text("Qualités disponibles").font(.headline)
                ForEach(torrents, id: \.url) { torrent in
                    Button {
                        start(torrent, media: movie, title: movie.title)
                    } label: {
                        TorrentPickerRow(torrent: torrent, recommended: torrent.url == recommended)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Season picker + episode cards (same as iPad)

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
                    .frame(maxWidth: 180)
                }
            }

            ForEach(episodes, id: \.id) { episode in
                Button {
                    resolveEpisodeSources(episode, show: show)
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
                            if !episode.summary.isEmpty {
                                Text(episode.summary)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        if loadingSourcesFor == episode.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.tint).font(.title2)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(loadingSourcesFor != nil)
            }
        }
    }

    /// T4P first, then EZTV/Torrentio — matching the iOS/tvOS play flow — then
    /// present the quality picker.
    private func resolveEpisodeSources(_ episode: Episode, show: Show) {
        guard loadingSourcesFor == nil else { return }
        loadingSourcesFor = episode.id
        let title = "\(show.title) — S\(String(format: "%02d", episode.season))E\(String(format: "%02d", episode.episode))"
        let finish: ([Torrent]) -> Void = { torrents in
            DispatchQueue.main.async {
                loadingSourcesFor = nil
                let sorted = torrents.sorted(by: >)
                guard !sorted.isEmpty else { errorMessage = "Aucune source pour cet épisode."; return }
                qualityChoices = MacEpisodeSources(title: title, media: episode, torrents: sorted)
            }
        }
        if let cached = episodeTorrents[episode.id] { finish(cached); return }
        guard show.id.hasPrefix("tt") else { finish(episode.torrents); return }
        let base = episode.torrents
        TorrentioClient.shared.streams(imdbId: show.id, season: episode.season, episode: episode.episode) { aggregated in
            Time4PopcornClient.shared.episodeTorrents(imdbId: show.id, season: episode.season, episode: episode.episode) { t4p in
                var merged = t4p + base
                for torrent in aggregated where !merged.contains(where: { $0.url == torrent.url }) {
                    merged.append(torrent)
                }
                DispatchQueue.main.async { episodeTorrents[episode.id] = merged }
                finish(merged)
            }
        }
    }

    // MARK: Data

    @ViewBuilder
    private var castSection: some View {
        if let movie = enrichedMovie {
            CastScroller(directors: directorNames(movie.crew), actors: movie.actors)
        } else if let show = enrichedShow {
            CastScroller(directors: directorNames(show.crew), actors: show.actors)
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        if let movie = enrichedMovie, !movie.related.isEmpty {
            RelatedRow(title: "Vus aussi", items: movie.related)
        } else if let show = enrichedShow, !show.related.isEmpty {
            RelatedRow(title: "Vus aussi", items: show.related)
        }
    }

    private func directorNames(_ crew: [Crew]) -> [String] {
        var seen = Set<String>()
        return crew.filter { $0.roleType == .director }.map(\.name).filter { seen.insert($0).inserted }
    }

    private func metadataLine(year: String, runtime: Int, certification: String, rating: Float) -> String {
        var parts: [String] = []
        if !year.isEmpty { parts.append(year) }
        if runtime > 0 { parts.append("\(runtime) min") }
        if !certification.isEmpty, certification != "Unrated" { parts.append(certification) }
        if rating > 0 { parts.append(String(format: "★ %.1f", rating / 10.0)) }
        return parts.joined(separator: " · ")
    }

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

/// An episode's resolved sources, driving the quality-picker sheet.
struct MacEpisodeSources: Identifiable {
    let id = UUID()
    let title: String
    let media: Media
    let torrents: [Torrent]
}

/// Quality picker sheet — the Mac equivalent of the iPad QualityPickerSheet.
struct MacQualityPickerSheet: View {
    let title: String
    let torrents: [Torrent]
    let onPick: (Torrent?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline).lineLimit(2)
            ScrollView {
                let recommended = Torrent.recommendedURL(in: torrents)
                VStack(spacing: 8) {
                    ForEach(torrents, id: \.url) { torrent in
                        Button {
                            onPick(torrent)
                        } label: {
                            TorrentPickerRow(torrent: torrent, recommended: torrent.url == recommended)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("Annuler", role: .cancel) { onPick(nil) }
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 380)
    }
}
