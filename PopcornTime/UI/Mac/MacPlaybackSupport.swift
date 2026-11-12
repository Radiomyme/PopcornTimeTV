import SwiftUI
import PopcornKit

/// Everything the player sheet needs to start streaming.
struct MacPendingPlayback: Identifiable {
    let id = UUID()
    let torrent: Torrent
    let media: Media
    let title: String
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
            Button("Cancel", role: .cancel) { onPick(nil) }
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 380)
    }
}

/// The "Auto Select Quality" setting (MacSettingsView, key
/// "autoSelectQuality"), applied the same way as the iOS page.
enum MacAutoQuality {
    /// The torrent to play without asking, or nil when the setting is
    /// "Always Ask" ("") and the picker must be shown.
    static func pick(from torrents: [Torrent], defaults: UserDefaults = .standard) -> Torrent? {
        let setting = defaults.string(forKey: "autoSelectQuality") ?? "Balanced"
        guard !setting.isEmpty else { return nil }
        let sorted = torrents.sorted(by: >)   // best quality first
        switch setting {
        case "Highest":
            return sorted.first
        case "Lowest":
            // Smallest resolution bucket, best-playing release inside it.
            let lowestBucket = sorted.last?.qualityValue
            return sorted.first { $0.qualityValue == lowestBucket }
        default:
            return Torrent.balancedPick(from: sorted)
        }
    }
}

/// Saves how far the Mac players got when they close. The Mac does not
/// resume: this exists so that ≥ 80 % marks the movie / episode watched
/// (WatchedlistManager.setCurrentProgress) and the show page's "up next"
/// advances. Same rules as the iOS players (VideoPlayerWrapper
/// `saveProgressIfNeeded`, VLCWatchProgress): the session protects its
/// `resumePoint` — read when the player opens, nothing for a finished
/// title — and a smaller fraction replaces it only when the session played
/// past it (`highWater`, the furthest position reached;
/// `ResumePolicy.progressToSave`).
enum MacPlaybackProgress {
    /// The native player at close: `fraction` where it stopped.
    static func save(_ fraction: Float, for media: Media, resumePoint: Float, highWater: Float) {
        guard fraction.isFinite, fraction > 0 else { return }
        let current = min(fraction, 1)
        guard let value = ResumePolicy.progressToSave(current: current, resumePoint: resumePoint,
                                                      highWater: max(highWater, current), userRestarted: false) else {
            print("[Player] progress \(Int(current * 100)) % not saved — keeps the resume point at \(Int(resumePoint * 100)) %")
            return
        }
        store(value, for: media)
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
    static func store(_ value: Float, for media: Media) {
        guard value.isFinite, value > 0 else { return }
        let fraction = min(value, 1)
        if let movie = media as? Movie {
            WatchedlistManager<Movie>.movie.setCurrentProgress(fraction, for: movie.id, with: .finished)
        } else if let episode = media as? Episode {
            WatchedlistManager<Episode>.episode.setCurrentProgress(fraction, for: episode.id, with: .finished)
        }
    }
}
