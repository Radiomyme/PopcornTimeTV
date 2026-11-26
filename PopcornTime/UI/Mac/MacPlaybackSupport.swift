import SwiftUI
import PopcornKit

/// Everything the player sheet needs to start streaming.
struct MacPendingPlayback: Identifiable {
    let id = UUID()
    let torrent: Torrent
    let media: Media
    let title: String
    /// The title's releases (the quality sheet's list): where the player
    /// looks for another source (a source that does not answer) and for a
    /// lighter release (a download slower than the video). Empty:
    /// `media.torrents`.
    var sources: [Torrent] = []
    /// 0…1 position the user already chose to start at — a switch to a
    /// lighter release continues where the other one was; 0: the player
    /// starts at the title's saved position, if any (`ResumePolicy.start`).
    var startFraction: Float = 0
    /// A release remembered for the title (« Resume », a Home card:
    /// `MacUpNextResume`): seconds without a peer before the loading screen
    /// offers another source (decision D5, `UpNextResume.patience`) — and the
    /// release is forgotten then, or when it fails. nil: the usual 45 s.
    var patience: TimeInterval?

    /// `sources`, else the media's own list (DEBUG: plus
    /// `-PTDebugLighterTorrent`), each with the media's runtime when it has
    /// none: its bitrate for the « Choose another source » picker.
    var knownSources: [Torrent] {
        let runtime = Torrent.mediaRuntime(of: media)
        return PlaybackStreamContext.withDebugSources(sources.isEmpty ? media.torrents : sources)
            .map { $0.mediaRuntime == nil ? $0.withMediaRuntime(runtime) : $0 }
    }
}

/// A movie's or an episode's sources, driving the quality-picker sheet.
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
        // The Settings sheets' build: the title, the list, then a bar with
        // Cancel at its trailing end (Escape).
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
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
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onPick(nil) }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, minHeight: 380)
    }
}

/// The "Auto Select Quality" setting (MacSettingsView, key
/// "autoSelectQuality"), applied the same way as the iOS page.
enum MacAutoQuality {
    /// The setting picks a release itself (anything but "Always Ask").
    static var picksAlone: Bool {
        !(UserDefaults.standard.string(forKey: "autoSelectQuality") ?? "Balanced").isEmpty
    }

    /// The torrent to play without asking, or nil when the setting is
    /// "Always Ask" ("") and the picker must be shown.
    static func pick(from torrents: [Torrent], defaults: UserDefaults = .standard) -> Torrent? {
        let setting = defaults.string(forKey: "autoSelectQuality") ?? "Balanced"
        guard !setting.isEmpty else { return nil }
        let sorted = torrents.sorted(by: >)   // best quality first
        // Highest / Lowest choose among the releases in the preferred audio
        // language when there are seeded ones; Balanced does it itself.
        let pool = Torrent.preferredLanguagePool(sorted)
        switch setting {
        case "Highest":
            return pool.first
        case "Lowest":
            // Smallest resolution bucket, best-playing release inside it.
            let lowestBucket = pool.last?.qualityValue
            return pool.first { $0.qualityValue == lowestBucket }
        default:
            return Torrent.balancedPick(from: sorted)
        }
    }
}

/// Saves how far the Mac players got: when they close, and every 30 s of
/// native playback (`isCheckpointDue`). The next play resumes there
/// (`ResumePolicy.start`), ≥ 80 % marks the movie / episode watched
/// (WatchedlistManager.setCurrentProgress), the show page's "up next"
/// advances and the title has its Continue Watching entry (`PlaybackRecorder`).
/// Same rules as the iOS players (VideoPlayerWrapper
/// `saveProgressIfNeeded`, VLCWatchProgress): the session protects its
/// `resumePoint` — read when the player opens, nothing for a finished
/// title — and a smaller fraction replaces it only when the session played
/// past it (`highWater`, the furthest position reached;
/// `ResumePolicy.progressToSave`).
enum MacPlaybackProgress {
    /// One player at a time on the Mac, ticking on the main thread.
    private static var checkpoint = PlaybackCheckpoint()

    /// From a player's 1 Hz tick: true every 30 s (`PlaybackCheckpoint`) —
    /// time to save the position, so a crash or a forced quit loses half a
    /// minute of an uninterrupted session, not all of it.
    static func isCheckpointDue() -> Bool {
        checkpoint.isDue()
    }

    /// The native player at close (`.finished`) or at a checkpoint
    /// (`.watching`): `fraction` where it is, into `profileID`'s library —
    /// the profile that started the play (`PlaybackRecorder.save`).
    static func save(_ fraction: Float, for media: Media, resumePoint: Float, highWater: Float,
                     status: Trakt.WatchedStatus, profileID: String) {
        guard fraction.isFinite, fraction > 0 else { return }
        let current = min(fraction, 1)
        guard let value = ResumePolicy.progressToSave(current: current, resumePoint: resumePoint,
                                                      highWater: max(highWater, current), userRestarted: false) else {
            print("[Player] progress \(Int(current * 100)) % not saved — keeps the resume point at \(Int(resumePoint * 100)) %")
            return
        }
        store(value, for: media, status: status, profileID: profileID)
    }

    /// The point a session opening now protects: the saved progress, 0
    /// for none or a finished title (`ResumePolicy.startPosition(forSavedProgress:)`).
    static func resumePoint(for media: Media) -> Float {
        ResumePolicy.startPosition(forSavedProgress: saved(for: media))
    }

    /// The progress saved for the movie / episode (0 = none).
    static func saved(for media: Media) -> Float {
        if let movie = media as? Movie { return WatchedlistManager<Movie>.movie.currentProgress(movie.id) }
        if let episode = media as? Episode { return WatchedlistManager<Episode>.episode.currentProgress(episode.id) }
        return 0
    }

    /// Writes a value already checked against the saved one (`save`, or
    /// the VLC fallback's own check, MacVLCController.stop).
    static func store(_ value: Float, for media: Media, status: Trakt.WatchedStatus, profileID: String) {
        guard value.isFinite, value > 0 else { return }
        // With the titles: the Continue Watching entry.
        PlaybackRecorder.save(min(value, 1), of: media, status: status, profileID: profileID)
    }
}
