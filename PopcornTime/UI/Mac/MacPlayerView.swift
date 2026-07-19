

import SwiftUI
import AVKit
import PopcornKit
import PopcornTorrent

/// Native macOS player: torrent stream → (remux | direct) → AVKit
/// `AVPlayerView`. Because this is a REAL Mac app (not iOS-on-Mac), macOS
/// spatializes the E-AC-3/JOC audio itself — Dolby Atmos renders on built-in
/// speakers and AirPods, which the "Designed for iPad" build never could.
struct MacPlayerView: View {
    let playback: MacPendingPlayback
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller = MacPlayerController()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let player = controller.player {
                MacAVPlayerRepresentable(player: player)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    ProgressView(value: controller.buffering, total: 1.0)
                        .frame(width: 320)
                    Text(controller.statusLine).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }

            if controller.showStats {
                Text(controller.statsText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(16)
            }

            // Close + stats keyboard controls.
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .padding(12)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // Hidden toggle bound to "n" — same shortcut as iOS/tvOS.
            Button("") { controller.showStats.toggle() }
                .keyboardShortcut("n", modifiers: [])
                .opacity(0)
        }
        .background(Color.black)
        .onAppear { controller.start(playback) }
        .onDisappear { controller.stop() }
    }
}

/// Owns the torrent stream, the remux session and the AVPlayer.
@MainActor
final class MacPlayerController: ObservableObject {
    @Published var player: AVPlayer?
    @Published var buffering: Double = 0
    @Published var statusLine = "Connexion aux sources…"
    @Published var showStats = true
    @Published var statsText = ""

    private var remux: RemuxPlayback?
    private var statsTimer: Timer?
    private var stopped = false
    /// alextud's PopcornTorrent has no singleton — each stream owns an instance.
    private let streamer = PTTorrentStreamer()

    func start(_ playback: MacPendingPlayback) {
        let magnet = playback.torrent.url
        // Reclaim prior torrent partials + orphaned remux output (shared
        // cross-platform helper — same disk-bounding as iOS/tvOS).
        purgeOrphanTorrentDownloads()

        let isAtmos = playback.torrent.tags.contains(.atmos)
        let subtitles = playback.media.subtitles

        streamer.startStreaming(fromMultiTorrentFileOrMagnetLink: magnet, progress: { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self, self.player == nil else { return }
                self.buffering = Double(status.bufferingProgress)
                self.statusLine = String(format: "Buffering %.0f%% · %d seeds · %d KB/s",
                                         status.bufferingProgress * 100, status.seeds,
                                         status.downloadSpeed / 1024)
            }
        }, readyToPlay: { [weak self] videoFileURL, videoFilePath in
            DispatchQueue.main.async {
                guard let self = self, !self.stopped else { return }
                // On macOS there is no VLC fallback, so EVERY .mkv goes
                // through the remuxer (it handles HEVC/H.264 + E-AC-3/AC-3 —
                // not just the DD+ Atmos case iOS/tvOS gates on).
                if videoFilePath.path.lowercased().hasSuffix(".mkv") {
                    self.startRemux(localFile: videoFilePath, isAtmos: isAtmos, subtitles: subtitles)
                } else {
                    // AVPlayer-friendly payloads (mp4/m4v/mov) play straight
                    // from the torrent's local HTTP endpoint. alextud's
                    // GCDWebServer reports its URL as 0.0.0.0 — rewrite to
                    // 127.0.0.1 (routable, and matches the local server).
                    var components = URLComponents(url: videoFileURL, resolvingAgainstBaseURL: false)
                    if components?.host == "0.0.0.0" { components?.host = "127.0.0.1" }
                    self.attachPlayer(to: components?.url ?? videoFileURL)
                }
            }
        }, failure: { [weak self] (error: Error) in
            DispatchQueue.main.async { self?.statusLine = "Échec: \(error.localizedDescription)" }
        }, selectFileToStream: { (fileNames: [String], fileSizes: [NSNumber]) -> Int32 in
            // Multi-file torrents: stream the largest file (the movie payload).
            guard let maxIndex = fileSizes.indices.max(by: { fileSizes[$0].int64Value < fileSizes[$1].int64Value })
                else { return 0 }
            return Int32(maxIndex)
        })

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
    }

    private func startRemux(localFile: URL, isAtmos: Bool, subtitles: [Subtitle]) {
        statusLine = "Remuxage MKV → HLS…"
        let remux = RemuxPlayback(localFile: localFile,
                                  streamer: streamer,
                                  isAtmos: isAtmos)
        remux.subtitles = subtitles
        self.remux = remux
        remux.onReady = { [weak self] playlistURL in
            DispatchQueue.main.async { self?.attachPlayer(to: playlistURL) }
        }
        remux.onFailure = { [weak self] message in
            DispatchQueue.main.async { self?.statusLine = "Remux impossible: \(message)" }
        }
        remux.start()
    }

    private func attachPlayer(to url: URL) {
        let item = AVPlayerItem(url: url)
        // Let macOS spatialize the 5.1 + Atmos objects (built-in speakers /
        // AirPods) — this is the whole point of the native Mac app.
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        let player = AVPlayer(playerItem: item)
        self.player = player
        player.play()
        // Auto-hide the stats after the proof-of-Atmos glance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.showStats = false
        }
    }

    private func refreshStats() {
        // Prune played remux segments as the playhead advances.
        if let time = player?.currentTime().seconds, time.isFinite {
            remux?.pruneSegments(playheadSeconds: time)
        }
        var lines = ["Engine  MKV remux → AVPlayer (macOS natif)"]
        if let item = player?.currentItem {
            for track in item.tracks {
                guard let assetTrack = track.assetTrack,
                      let desc = (assetTrack.formatDescriptions as? [CMFormatDescription])?.first else { continue }
                let sub = CMFormatDescriptionGetMediaSubType(desc)
                let cc = String(bytes: [UInt8(sub >> 24 & 0xff), UInt8(sub >> 16 & 0xff), UInt8(sub >> 8 & 0xff), UInt8(sub & 0xff)], encoding: .ascii) ?? "?"
                if assetTrack.mediaType == .video {
                    let size = assetTrack.naturalSize
                    lines.append("Video   \(cc)  \(Int(size.width))×\(Int(size.height))")
                } else if assetTrack.mediaType == .audio {
                    var channels = 0
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                        channels = Int(asbd.pointee.mChannelsPerFrame)
                    }
                    let atmos = cc == "ec-3" ? "  → Dolby (Atmos, rendu spatial macOS)" : ""
                    lines.append("Audio   \(cc)  \(channels) ch\(atmos)")
                }
            }
        }
        lines.append("Remux   \(remux?.statsSummary ?? "-")")
        statsText = " " + lines.joined(separator: "\n ") + " "
    }

    func stop() {
        stopped = true
        statsTimer?.invalidate()
        statsTimer = nil
        player?.pause()
        player = nil
        remux?.stop()
        remux = nil
        streamer.cancelStreamingAndDeleteData(false)
    }
}

/// AVKit's native macOS player view (controls, PiP, fullscreen).
struct MacAVPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
