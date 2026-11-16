#if DEBUG
import Foundation
import PopcornKit

/// The episode-chaining bench (offline runs on the loopback rig), compiled
/// only with DEBUG (`SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` on the
/// xcodebuild command line, as for `BoundedStorageDebugHooks`). Nothing
/// happens without these launch arguments:
///
/// - `-PTDebugPlayEpisode S01E01` with `-PTDebugPlayTorrent <abs .torrent>`:
///   plays that episode of a made-up show, `tt0000001` « PT Test Show »
///   (`-PTDebugEpisodeCount <n>` episodes of season 1, default 3; runtime
///   from `-PTDebugDuration <s>`), from that local .torrent, through the
///   platform's normal flow. `episodeToPlay` gives the episode and its
///   torrent; Apple TV: `SceneDelegate` plays it (`AppDelegate.play`). The
///   made-up show's sources and subtitles are never asked of a real
///   service (`EpisodeSourceResolver.debugShowID`, `SubtitleSearch`).
/// - `-PTDebugEpisodeSources <a .json file, or the JSON itself>`: each
///   episode's releases, LOCAL .torrent files only (a magnet or a URL is
///   refused), seeded into `EpisodeSourceResolver` (no source is asked) and
///   listed as the made-up episodes' own torrents:
///   ```
///   { "S01E02": [ { "torrent": "/abs/Test.Show.S01E02.1080p.HEVC-PTT.torrent",
///                   "quality": "1080p HEVC", "name": "Test.Show.S01E02.1080p.HEVC-PTT.mkv",
///                   "size": "300 MB", "seeds": 5, "provider": "Torrentio" } ],
///     "S01E03": [ … ] }
///   ```
///   `name` (the payload's file name; default: the .torrent's) is what the
///   group, the container and the episode are read from; `provider` lands
///   in the Torrentio list (default), "T4P" or "TPB/Knaben".
/// - `-PTDebugUpNextAnswer <accept|cancel|choose>@<s>`: the card answers
///   itself `s` seconds after it shows (accept also answers « Still
///   watching? »).
/// - `-PTDebugUpNextCardAt <s>`: the card at that position of the file
///   (short test episodes) instead of 30 s before its end.
/// - `-PTDebugUpNextStillAfter <n>`: « Still watching? » after n episodes
///   chained with no action (default 3).
/// - `-PTDebugNoSubtitleSearch YES`: no subtitle search leaves the device
///   (`SubtitleSearch.openSubtitles`; always so for the made-up show).
/// Every step logs a "[UpNextDebug]" line; the session's own lines are "[UpNext]".
enum UpNextDebugHooks {
    private static var defaults: UserDefaults { .standard }

    static let showID = EpisodeSourceResolver.debugShowID

    /// `-PTDebugPlayEpisode` as a season / episode number.
    static var episodeNumber: EpisodeNumber? {
        guard let marker = defaults.string(forKey: "PTDebugPlayEpisode") else { return nil }
        return parse(marker)
    }

    /// "S01E02" / "s1e2" → S1E2.
    static func parse(_ marker: String) -> EpisodeNumber? {
        let text = marker.lowercased().trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("s"), let e = text.firstIndex(of: "e"),
              let season = Int(text[text.index(after: text.startIndex)..<e]),
              let episode = Int(text[text.index(after: e)...]), season >= 0, episode > 0 else { return nil }
        return EpisodeNumber(season: season, episode: episode)
    }

    // MARK: The made-up show

    /// The episode to play and its torrent (`-PTDebugPlayEpisode` with
    /// `-PTDebugPlayTorrent`); nil without them.
    static var episodeToPlay: (episode: Episode, torrent: Torrent)? {
        guard let number = episodeNumber, let file = BoundedStorageDebugHooks.torrentFile else { return nil }
        let show = fakeShow(playing: file, at: number)
        guard var episode = show.episodes.first(where: { $0.season == number.season && $0.episode == number.episode }) else {
            print("[UpNextDebug] \(number) is not an episode of the made-up show")
            return nil
        }
        episode.show = show
        let torrent = episode.torrents.first { $0.url == file } ?? Torrent(url: file, quality: "1080p")
        return (episode, torrent)
    }

    /// « PT Test Show » (tt0000001): season 1, `-PTDebugEpisodeCount`
    /// episodes (default 3, at least the one played), each listing its
    /// seeded releases — and the episode played, `file`.
    static func fakeShow(playing file: String? = nil, at played: EpisodeNumber? = nil) -> Show {
        let count = max(defaults.string(forKey: "PTDebugEpisodeCount").flatMap(Int.init) ?? 3, played?.episode ?? 1)
        var show = Show(title: "PT Test Show", id: showID, slug: "pt-test-show", summary: "The episode-chaining bench.")
        if let seconds = BoundedStorageDebugHooks.durationSeconds, seconds > 0 { show.runtime = max(1, Int((seconds / 60).rounded())) }
        let sources = seededSources()
        var episodes: [Episode] = []
        for number in 1...count {
            let key = EpisodeNumber(season: played?.season ?? 1, episode: number)
            var torrents = sources[key] ?? []
            if key == played, let file = file, !torrents.contains(where: { $0.url == file }) {
                torrents.insert(Torrent(url: file, quality: "1080p"), at: 0)
            }
            episodes.append(Episode(title: "Test Episode \(number)", id: LibraryID.episodeID(showID: showID, key),
                                    slug: "test-episode-\(number)", summary: "Episode \(number) of the bench.",
                                    torrents: torrents, show: nil, episode: key.episode, season: key.season,
                                    firstAirDate: Date(timeIntervalSince1970: 1_600_000_000)))
        }
        show.episodes = episodes
        return show
    }

    // MARK: Seeded sources

    private static var parsed: [EpisodeNumber: [Torrent]]?

    /// `-PTDebugEpisodeSources`, read once: the releases of each episode.
    static func seededSources() -> [EpisodeNumber: [Torrent]] {
        if let parsed = parsed { return parsed }
        var result: [EpisodeNumber: [Torrent]] = [:]
        defer { parsed = result }
        guard let argument = defaults.string(forKey: "PTDebugEpisodeSources"), !argument.isEmpty else { return result }
        let data: Data?
        if argument.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            data = argument.data(using: .utf8)
        } else {
            data = FileManager.default.contents(atPath: argument)
        }
        guard let data = data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: [[String: Any]]] else {
            print("[UpNextDebug] -PTDebugEpisodeSources: not a {\"S01E02\": [ … ]} JSON — nothing seeded")
            return result
        }
        for (marker, entries) in json {
            guard let number = parse(marker) else {
                print("[UpNextDebug] -PTDebugEpisodeSources: \(marker) is no episode — skipped")
                continue
            }
            result[number] = entries.compactMap(torrent(from:))
        }
        return result
    }

    /// One entry: a LOCAL .torrent file, never a magnet nor a URL.
    private static func torrent(from entry: [String: Any]) -> Torrent? {
        guard let path = entry["torrent"] as? String, path.hasPrefix("/"), path.lowercased().hasSuffix(".torrent"),
              FileManager.default.fileExists(atPath: path) else {
            print("[UpNextDebug] refused (local .torrent files only): \(entry["torrent"] ?? "nil")")
            return nil
        }
        let quality = (entry["quality"] as? String) ?? "1080p"
        let name = entry["name"] as? String
        let provider = entry["provider"] as? String
        let label = quality + (provider.map { Torrent.sourceSeparator + $0 } ?? "")
        let tags = VideoTags.parse(quality).union(name.map(VideoTags.parse) ?? [])
        return Torrent(url: path, quality: label, seeds: (entry["seeds"] as? Int) ?? 0, peers: (entry["peers"] as? Int) ?? 0,
                       size: entry["size"] as? String, tags: tags, fileName: name)
    }

    /// At launch (`BoundedStorageDebugHooks.prepareAtLaunch`): the seeded
    /// sources go into the resolver.
    static func prepareAtLaunch() {
        let sources = seededSources()
        guard !sources.isEmpty else { return }
        let raw = defaults.string(forKey: "PTDebugEpisodeSources") ?? ""
        let providers = (try? JSONSerialization.jsonObject(with: raw.hasPrefix("{") ? Data(raw.utf8)
                                                               : (FileManager.default.contents(atPath: raw) ?? Data()))) as? [String: [[String: Any]]]
        for (number, torrents) in sources {
            var seeded = EpisodeSourceResolver.Sources()
            let marker = providers?.keys.first { parse($0) == number }
            let entries = marker.flatMap { providers?[$0] } ?? []
            for (index, torrent) in torrents.enumerated() {
                let provider = index < entries.count ? (entries[index]["provider"] as? String ?? "") : ""
                switch provider.lowercased() {
                case "t4p", "time4popcorn": seeded.time4Popcorn.append(torrent)
                case "tpb", "knaben", "tpb/knaben", "extra": seeded.extra.append(torrent)
                default: seeded.torrentio.append(torrent)
                }
            }
            EpisodeSourceResolver.shared.seed(seeded, showId: showID, season: number.season, episode: number.episode)
        }
        print("[UpNextDebug] made-up show \(showID): \(sources.count) episode(s) seeded, "
              + "\(sources.values.map(\.count).reduce(0, +)) release(s); answer=\(defaults.string(forKey: "PTDebugUpNextAnswer") ?? "-") "
              + "cardAt=\(defaults.string(forKey: "PTDebugUpNextCardAt") ?? "-") stillAfter=\(defaults.string(forKey: "PTDebugUpNextStillAfter") ?? "-")")
    }

    // MARK: The card

    /// The tuning with `-PTDebugUpNextCardAt` / `-PTDebugUpNextStillAfter`.
    static func tuning(_ base: UpNextCountdown.Tuning) -> UpNextCountdown.Tuning {
        var tuning = base
        if let at = defaults.string(forKey: "PTDebugUpNextCardAt").flatMap(Double.init), at >= 0 { tuning.cardAtOverride = at }
        if let after = defaults.string(forKey: "PTDebugUpNextStillAfter").flatMap(Int.init), after >= 0 { tuning.stillWatchingAfter = after }
        return tuning
    }

    /// `-PTDebugUpNextAnswer`: the answer and its delay.
    static var answer: (action: String, after: Double)? {
        guard let raw = defaults.string(forKey: "PTDebugUpNextAnswer")?.lowercased() else { return nil }
        let parts = raw.split(separator: "@").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let action = parts.first, ["accept", "cancel", "choose"].contains(action) else { return nil }
        return (action, parts.count > 1 ? max(0, Double(parts[1]) ?? 3) : 3)
    }

    /// The card of `session` showed: its scripted answer, once.
    @MainActor
    static func scheduleAnswer(for session: UpNextSession) {
        guard let answer = answer else { return }
        print("[UpNextDebug] card up: \(answer.action) in \(answer.after) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + answer.after) { [weak session] in
            MainActor.assumeIsolated {
                guard let session = session else { return }
                print("[UpNextDebug] answer \(answer.action)")
                switch answer.action {
                case "accept": session.accept()
                case "cancel": session.cancel()
                default: session.chooseVersion()
                }
            }
        }
    }
}
#endif
