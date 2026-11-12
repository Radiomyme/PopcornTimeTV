// GlassDetailAdapter.swift — turns PopcornKit's Movie / Show / Episode / Actor /
// Crew, the watched / watchlist managers and (tvOS) the torrent downloads into
// the plain values of GlassDetailModel (GlassDetailModel.swift). Pure mapping,
// no UI: GlassDetailHostingController (tvOS) and MacGlassDetailScreen (macOS)
// call these when the page opens and every time something changes.
//
// Image URLs are passed as the models expose them: PopcornKit's ImageProxy has
// already rewritten yts.* hosts at model construction. Logos and missing
// backdrops come from metahub (OpenMetadata), keyless.
import Foundation
import PopcornKit
#if os(tvOS)
import PopcornTorrent
import MediaPlayer.MPMediaItem
#endif

enum GlassDetailAdapter {

    // MARK: - Pages

    /// Everything a movie page shows that is known once `getMovieInfo` has
    /// answered. Related titles, cast and the logo arrive later.
    static func model(for movie: Movie) -> GlassDetailModel {
        GlassDetailModel(kind: .movie,
                         title: movie.title,
                         logoURL: OpenMetadata.logoURL(imdbId: movie.id),
                         // YTS backgrounds are about 900 px wide: metahub's
                         // 1920 px one first, YTS's if metahub has none.
                         backdropURL: OpenMetadata.backgroundURL(imdbId: movie.id) ?? url(movie.largeBackgroundImage),
                         backdropFallbackURL: url(movie.largeBackgroundImage),
                         posterURL: url(movie.mediumCoverImage ?? movie.largeCoverImage),
                         metadata: [movie.year, runtime(minutes: movie.runtime), genres(movie.genres)].compactMap(nonEmpty),
                         certification: certificationBadge(movie.certification),
                         rating: stars(movie.rating),
                         badges: badges(for: movie.torrents),
                         summary: summary(movie.summary),
                         play: playInfo(for: movie),
                         hasTrailer: movie.trailerCode != nil,
                         isInWatchlist: movie.isAddedToWatchlist,
                         isWatched: movie.isWatched,
                         download: downloadState(of: movie),
                         information: information(for: movie),
                         accessibility: accessibility)
    }

    /// A show page. `show` must already have its episodes linked
    /// (`Show.linkingEpisodes()`), `season` is the season the shelf opens on.
    static func model(for show: Show, season: Int?) -> GlassDetailModel {
        let next = nextEpisode(in: show)
        return GlassDetailModel(kind: .show,
                                title: show.title,
                                logoURL: OpenMetadata.logoURL(imdbId: show.id),
                                // TVMaze only has portrait art: metahub's landscape
                                // backdrop first (a 404 falls back to the poster).
                                backdropURL: OpenMetadata.backgroundURL(imdbId: show.id) ?? url(show.largeBackgroundImage),
                                posterURL: url(show.mediumCoverImage ?? show.largeCoverImage),
                                metadata: [show.year, seasonCount(show.seasonNumbers.count), genres(show.genres), show.network].compactMap(nonEmpty),
                                summary: summary(show.summary),
                                play: next.map(playInfo(for:)),
                                isInWatchlist: show.isAddedToWatchlist,
                                seasons: show.seasonNumbers,
                                selectedSeason: season,
                                episodes: episodes(of: show),
                                upNextEpisodeID: show.latestUnwatchedEpisode()?.id,
                                information: information(for: show),
                                accessibility: accessibility)
    }

    // MARK: - Play

    /// The episode the show page's Play button starts: the one to continue
    /// (`latestUnwatchedEpisode`), else the first episode of the first season.
    /// None when that episode has not aired yet (no Play button, rather than
    /// one that ends on "No torrents found").
    static func nextEpisode(in show: Show) -> Episode? {
        let next = show.latestUnwatchedEpisode() ?? firstSeason(of: show).flatMap { first in
            show.episodes.filter { $0.season == first }.min { $0.episode < $1.episode }
        }
        return next.flatMap { $0.isAvailableToPlay ? $0 : nil }
    }

    /// The first real season: season 0 (specials, listed by EZTV only) comes
    /// first in `seasonNumbers` but is not where a show starts.
    static func firstSeason(of show: Show) -> Int? {
        show.seasonNumbers.first { $0 > 0 } ?? show.seasonNumbers.first
    }

    static func playInfo(for movie: Movie) -> GlassPlayInfo {
        GlassPlayInfo(progress: progress(WatchedlistManager<Movie>.movie.currentProgress(movie.id)))
    }

    static func playInfo(for episode: Episode) -> GlassPlayInfo {
        GlassPlayInfo(season: episode.season,
                      episode: episode.episode,
                      progress: progress(WatchedlistManager<Episode>.episode.currentProgress(episode.id)))
    }

    /// Saved playback progress worth showing as a bar (not started and
    /// finished titles show none).
    private static func progress(_ value: Float) -> Double? {
        value > 0.01 && value < 0.97 ? Double(value) : nil
    }

    // MARK: - Episodes

    /// Every episode, sorted by season then number, one per id.
    static func episodes(of show: Show) -> [GlassEpisode] {
        let downloads = downloadStates()
        var seen = Set<String>()
        return show.episodes
            .sorted { $0.season == $1.season ? $0.episode < $1.episode : $0.season < $1.season }
            .filter { seen.insert($0.id).inserted }
            .map { episode(for: $0, of: show, downloads: downloads) }
    }

    /// `downloads`: download state by episode id; nil hides every download
    /// affordance (macOS).
    static func episode(for episode: Episode, of show: Show, downloads: [String: GlassDownloadState]?) -> GlassEpisode {
        GlassEpisode(id: episode.id,
                     season: episode.season,
                     number: episode.episode,
                     title: episode.title.isEmpty ? String(localized: "Episode \(episode.episode)") : episode.title,
                     summary: episode.summary,
                     stillURL: url(episode.smallBackgroundImage ?? episode.largeBackgroundImage),
                     detail: [airDate(episode.firstAirDate), show.runtime.flatMap { $0 > 0 ? "\($0) min" : nil }]
                        .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                     isWatched: WatchedlistManager<Episode>.episode.isAdded(episode.id),
                     progress: progress(WatchedlistManager<Episode>.episode.currentProgress(episode.id)),
                     download: downloads.map { $0[episode.id] ?? .idle })
    }

    /// Re-reads what can change while the page is open (watched, progress,
    /// downloads) and keeps the rest (still, title…).
    static func refreshed(_ episodes: [GlassEpisode]) -> [GlassEpisode] {
        let downloads = downloadStates()
        return episodes.map { episode in
            var episode = episode
            episode.isWatched = WatchedlistManager<Episode>.episode.isAdded(episode.id)
            episode.progress = progress(WatchedlistManager<Episode>.episode.currentProgress(episode.id))
            episode.download = downloads.map { $0[episode.id] ?? .idle }
            return episode
        }
    }

    private static func airDate(_ date: Date) -> String? {
        guard date > Date(timeIntervalSince1970: 0) else { return nil }   // unknown = .distantPast
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }

    // MARK: - Downloads

    /// The movie's download state; nil on macOS (no downloads there: the
    /// Download button is hidden).
    static func downloadState(of movie: Movie) -> GlassDownloadState? {
        #if os(tvOS)
        return downloadState(of: movie.associatedDownload)
        #else
        return nil
        #endif
    }

    /// Download state by media id; nil on macOS.
    static func downloadStates() -> [String: GlassDownloadState]? {
        #if os(tvOS)
        return downloadsByMediaID().mapValues { downloadState(of: $0) }
        #else
        return nil
        #endif
    }

    #if os(tvOS)
    /// `PTTorrentDownload` by the media id it carries, the active download
    /// first (the same order as `Media.associatedDownload`).
    static func downloadsByMediaID() -> [String: PTTorrentDownload] {
        let manager = PTTorrentDownloadManager.shared()
        var result: [String: PTTorrentDownload] = [:]
        for download in manager.activeDownloads + manager.completedDownloads {
            guard let id = download.mediaMetadata[MPMediaItemPropertyPersistentID] as? String,
                  result[id] == nil else { continue }
            result[id] = download
        }
        return result
    }

    /// Media id of a download (`MPMediaItemPropertyPersistentID`).
    static func mediaID(of download: PTTorrentDownload) -> String? {
        download.mediaMetadata[MPMediaItemPropertyPersistentID] as? String
    }

    /// Same mapping as the old DownloadButton (`DownloadButton.State(_:)`):
    /// no download or a failed one = idle.
    static func downloadState(of download: PTTorrentDownload?) -> GlassDownloadState {
        guard let download else { return .idle }
        return downloadState(DownloadButton.State(download.downloadStatus),
                             progress: download.torrentStatus.totalProgress)
    }

    static func downloadState(_ state: DownloadButton.State, progress: Float) -> GlassDownloadState {
        switch state {
        case .normal: return .idle
        case .pending: return .pending
        case .downloading: return .downloading(progress: Double(progress))
        case .paused: return .paused(progress: Double(progress))
        case .downloaded: return .downloaded
        }
    }

    /// The inverse, for `AppDelegate.downloadControl(wasPressedIn:…)`.
    static func buttonState(_ state: GlassDownloadState) -> DownloadButton.State {
        switch state {
        case .idle: return .normal
        case .pending: return .pending
        case .downloading: return .downloading
        case .paused: return .paused
        case .downloaded: return .downloaded
        }
    }
    #endif

    // MARK: - Related, cast & crew

    /// One item per id (a title Trakt lists twice would break the shelf).
    static func related(_ items: [Media]) -> [GlassRelatedItem] {
        var seen = Set<String>()
        return items
            .filter { seen.insert($0.id).inserted }
            .map { item in
                let year = (item as? Movie)?.year ?? (item as? Show)?.year
                return GlassRelatedItem(id: item.id,
                                        title: item.title,
                                        subtitle: year.flatMap(nonEmpty),
                                        posterURL: url(item.mediumCoverImage ?? item.largeCoverImage))
            }
    }

    /// Actors then crew, as the old "Cast & Crew" row. Each entry gets a
    /// unique id (someone can be both director and actor); `people` maps it
    /// back to the Person for the person page.
    static func people(actors: [Actor], crew: [Crew]) -> (items: [GlassPerson], people: [String: Person]) {
        var items: [GlassPerson] = []
        var people: [String: Person] = [:]
        func add(_ person: Person, prefix: String, role: String) {
            var id = "\(prefix):\(person.imdbId)"
            if people[id] != nil { id += ":\(items.count)" }
            people[id] = person
            items.append(GlassPerson(id: id, name: person.name, role: nonEmpty(role), imageURL: url(person.mediumImage)))
        }
        actors.forEach { add($0, prefix: "cast", role: $0.characterName) }
        // One entry per crew member, with every job ("Director, Writer").
        var order: [String] = []
        var first: [String: Crew] = [:]
        var jobs: [String: [String]] = [:]
        for member in crew {
            let key = member.name.lowercased()
            if first[key] == nil { order.append(key); first[key] = member }
            if !member.job.isEmpty, !(jobs[key]?.contains(member.job) ?? false) { jobs[key, default: []].append(member.job) }
        }
        for key in order {
            add(first[key]!, prefix: "crew", role: (jobs[key] ?? []).joined(separator: ", "))
        }
        return (items, people)
    }

    // MARK: - Information / Accessibility

    /// Genre, Director(s), Starring (the old left column), Released, Run Time
    /// and Rating. Empty values are left out.
    static func information(for movie: Movie) -> [GlassInfoRow] {
        let directors = movie.crew.filter { $0.roleType == .director }.map(\.name)
        let actors = movie.actors.prefix(4).map(\.name)
        let rows: [(String, String?)] = [
            ("Genre".localized, genres(movie.genres) ?? "Unknown".localized),
            ((directors.count == 1 ? "Director" : "Directors").localized, directors.isEmpty ? nil : directors.joined(separator: ", ")),
            ("Starring".localized, actors.isEmpty ? nil : actors.joined(separator: ", ")),
            ("Released".localized, movie.year),
            ("Run Time".localized, runtime(minutes: movie.runtime)),
            ("Rating".localized, movie.certification.localized),
        ]
        return infoRows(rows)
    }

    /// Genre, Released, Run Time and Network, as the old Information box.
    static func information(for show: Show) -> [GlassInfoRow] {
        let rows: [(String, String?)] = [
            ("Genre".localized, genres(show.genres) ?? "Unknown".localized),
            ("Released".localized, show.year),
            ("Run Time".localized, show.runtime.map { "\($0) min" }),
            ("Network".localized, show.network ?? "TV"),
        ]
        return infoRows(rows)
    }

    static let accessibility = [
        GlassInfoRow(key: "SDH",
                     value: "Subtitles for the deaf and Hard of Hearing (SDH) refer to subtitles in the original language with the addition of relevant non-dialog information.".localized)
    ]

    private static func infoRows(_ rows: [(String, String?)]) -> [GlassInfoRow] {
        rows.compactMap { key, value in value.flatMap(nonEmpty).map { GlassInfoRow(key: key, value: $0) } }
    }

    // MARK: - Hero pieces

    /// Capability chips, only from what the torrents really offer: the best
    /// resolution, then Dolby Vision / HDR10(+), then Dolby Atmos / DTS:X.
    static func badges(for torrents: [Torrent]) -> [GlassBadge] {
        guard !torrents.isEmpty else { return [] }
        var badges: [GlassBadge] = []
        let best = torrents.map(\.qualityValue).max()
        if best == .uhd2160 {
            badges.append(GlassBadge(text: "4K"))
        } else if let best, best != .unknown {
            badges.append(GlassBadge(text: best.displayLabel))
        }
        let tags = torrents.reduce(VideoTags()) { $0.union($1.tags) }
        if tags.contains(.dolbyVision) { badges.append(GlassBadge(text: "Dolby Vision")) }
        if tags.contains(.hdr10Plus) {
            badges.append(GlassBadge(text: "HDR10+"))
        } else if tags.contains(.hdr10) {
            badges.append(GlassBadge(text: "HDR10"))
        }
        if tags.contains(.atmos) {
            badges.append(GlassBadge(text: "Dolby Atmos"))
        } else if tags.contains(.dtsX) {
            badges.append(GlassBadge(text: "DTS:X"))
        }
        return badges
    }

    /// "2 hr, 18 min" (short units, the old page's format); nil for 0.
    static func runtime(minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.hour, .minute]
        return formatter.string(from: TimeInterval(minutes) * 60)
    }

    /// API rating 0…100 → 0…5 stars in halves; nil when unrated.
    static func stars(_ rating: Float) -> Double? {
        guard rating > 0 else { return nil }
        return min(5, (Double(rating) / 20 * 2).rounded() / 2)
    }

    /// The certification chip; placeholders ("Unrated", "Unknown") show none.
    static func certificationBadge(_ certification: String) -> String? {
        let value = certification.trimmingCharacters(in: .whitespaces)
        let placeholders: Set<String> = ["", "unrated", "unknown", "n/a", "not rated"]
        return placeholders.contains(value.lowercased()) ? nil : value
    }

    /// Up to three genres, translated when Localizable.strings knows them
    /// ("Drama" → "Drame").
    private static func genres(_ genres: [String]) -> String? {
        nonEmpty(genres.prefix(3).map { $0.localizedCapitalized.localized }.joined(separator: ", "))
    }

    private static func seasonCount(_ count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return String(localized: "1 Season")
        default: return String(localized: "\(count) Seasons")
        }
    }

    private static func summary(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func url(_ string: String?) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        return URL(string: string)
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return string
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Show {
    /// Copy whose episodes point back to a show that has the full episode
    /// list. The provider sets `episode.show` before the episodes are filled
    /// in (YTSEZTVProvider.mergedEpisodes), so an episode's show has none:
    /// `AppDelegate.play` then finds no next episode and Up Next never shows.
    /// One level is enough: `play` hands its own `episode.show` on to the
    /// next episode.
    func linkingEpisodes() -> Show {
        let full = self
        var linked = self
        linked.episodes = episodes.map { episode in
            var episode = episode
            episode.show = full
            return episode
        }
        return linked
    }
}
