

import Foundation
import AVKit
import SwiftUI
import GCDWebServer
import PopcornTorrent
import PopcornKit

/// Phase 2 of the remux engine: drives MKVToHLSRemuxSession against the
/// still-downloading torrent file, serves the HLS output over localhost, and
/// plays it with AVPlayer — Apple's renderer receives the untouched E-AC-3
/// (Atmos) bitstream. Used on iOS, macOS (Designed for iPad) and tvOS.
final class RemuxPlayback {

    /// Remux candidates: MKV payload whose release name carries DD+/E-AC-3.
    static func canRemux(magnet: String, tags: VideoTags) -> Bool {
        guard tags.contains(.eac3) else { return false }
        guard let dn = magnet.components(separatedBy: "&dn=").last?
            .components(separatedBy: "&").first?
            .removingPercentEncoding?.lowercased() else { return false }
        return dn.hasSuffix(".mkv")
    }

    private(set) var session: MKVToHLSRemuxSession?
    private let server = GCDWebServer()
    private var pumpTimer: Timer?
    /// All remux work happens off-main: pumping reads/writes gigabytes and
    /// froze the UI when it ran on the main thread.
    private let workQueue = DispatchQueue(label: "remux.pump", qos: .userInitiated)
    private var isPumping = false
    private var idleTicks = 0
    private let inputFile: URL
    private let outputDir: URL
    weak var streamer: PTTorrentStreamer?
    /// Called once enough segments exist to start playback.
    var onReady: ((URL) -> Void)?
    var onFailure: ((String) -> Void)?
    private var prepared = false
    private var started = false

    init(localFile: URL, streamer: PTTorrentStreamer?) {
        self.inputFile = localFile
        self.streamer = streamer
        self.outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-\(UUID().uuidString.prefix(8))")
    }

    func start() {
        server.addGETHandler(forBasePath: "/", directoryPath: outputDir.path,
                             indexFilename: nil, cacheAge: 0, allowRangeRequests: true)
        try? server.start(options: [GCDWebServerOption_Port: 50710,
                                    GCDWebServerOption_BindToLocalhost: true,
                                    GCDWebServerOption_AutomaticallySuspendInBackground: false])
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPumping else { return }
            self.isPumping = true
            self.workQueue.async {
                self.tick()
                self.isPumping = false
            }
        }
    }

    private var failedTicks = 0
    private func tick() {
        if session == nil {
            session = try? MKVToHLSRemuxSession(inputFile: inputFile, outputDirectory: outputDir)
        }
        guard let session = session else { return }
        if !prepared {
            prepared = session.prepare()
            if !prepared {
                failedTicks += 1
                if failedTicks > 90 { fail("Remux: MKV headers never became parseable") }
                return
            }
        }
        // Cap per-tick work so a mostly-downloaded file doesn't remux in one
        // giant I/O burst that starves AVPlayer's own segment reads.
        let newSegments = session.pump(maxNewSegments: 6)
        if !started, session.progress.segmentsWritten >= 2 {
            started = true
            let url = URL(string: "http://127.0.0.1:\(server.port)/stream.m3u8")!
            print("[Remux] playback ready: \(session.progress.segmentsWritten) segments — \(url)")
            DispatchQueue.main.async { self.onReady?(url) }
        }
        // Completion → VOD: when the demuxer has drained the file (no new
        // segments for a few ticks) and the torrent reports done, flush the
        // tail and write ENDLIST. AVPlayer then switches from live-style
        // EVENT (no scrubbing) to full VOD transport controls.
        guard !session.progress.finished else { return }
        let torrentDone = (streamer?.torrentStatus.totalProgress ?? 1.0) >= 0.999
        idleTicks = newSegments == 0 ? idleTicks + 1 : 0
        if torrentDone && idleTicks >= 3 {
            session.finish()
            print("[Remux] finished (VOD): \(session.progress.segmentsWritten) segments, \(Int(session.progress.mediaSeconds))s")
            DispatchQueue.main.async { self.pumpTimer?.invalidate(); self.pumpTimer = nil }
        }
    }

    private func fail(_ message: String) {
        print("[Remux] FAIL: \(message)")
        stop()
        onFailure?(message)
    }

    func stop() {
        pumpTimer?.invalidate()
        pumpTimer = nil
        if server.isRunning { server.stop() }
        try? FileManager.default.removeItem(at: outputDir)
    }

    var statsSummary: String {
        guard let session = session else { return "preparing…" }
        return "\(session.progress.segmentsWritten) segs · \(Int(session.progress.mediaSeconds))s remuxed"
    }
}

/// AVPlayerViewController wrapper for the remux path, with a built-in nerd
/// stats overlay (in contentOverlayView) proving what AVPlayer is playing —
/// the Audio line reading `ec-3` means Apple's renderer gets the raw E-AC-3
/// and performs the Atmos rendering itself.
final class RemuxAVPlayerViewController: AVPlayerViewController {

    private var remux: RemuxPlayback?
    private var keepAliveStreamer: PTTorrentStreamer?
    private let statsLabel = UILabel()
    private var statsTimer: Timer?

    func configure(localFile: URL, streamer: PTTorrentStreamer?, title: String) {
        keepAliveStreamer = streamer
        let remux = RemuxPlayback(localFile: localFile, streamer: streamer)
        self.remux = remux
        remux.onReady = { [weak self] playlistURL in
            let item = AVPlayerItem(url: playlistURL)
            let player = AVPlayer(playerItem: item)
            self?.player = player
            player.play()
        }
        remux.start()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        statsLabel.font = .monospacedSystemFont(ofSize: UIDevice.current.userInterfaceIdiom == .tv ? 23 : 12, weight: .medium)
        statsLabel.textColor = .white
        statsLabel.numberOfLines = 0
        statsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        if let overlay = contentOverlayView {
            overlay.addSubview(statsLabel)
            NSLayoutConstraint.activate([
                statsLabel.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 20),
                statsLabel.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            ])
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStats()
        }
        // Visible briefly at start (proof-of-Atmos), then out of the way.
        // Toggle back anytime with the "n" key (Mac / iPad keyboard).
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.statsLabel.isHidden = true
        }
    }

    override var canBecomeFirstResponder: Bool { return true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        let stats = UIKeyCommand(input: "n", modifierFlags: [], action: #selector(toggleStatsOverlay))
        stats.wantsPriorityOverSystemBehavior = true
        return [stats]
    }

    @objc private func toggleStatsOverlay() {
        statsLabel.isHidden.toggle()
    }

    private func refreshStats() {
        var lines = ["Engine  MKV remux → AVPlayer (native)"]
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
                    let atmos = cc == "ec-3" ? "  → Dolby (Atmos-capable, Apple renderer)" : ""
                    lines.append("Audio   \(cc)  \(channels) ch\(atmos)")
                }
            }
        }
        lines.append("Remux   \(remux?.statsSummary ?? "-")")
        statsLabel.text = " " + lines.joined(separator: "\n ") + " "
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        statsTimer?.invalidate()
        player?.pause()
        remux?.stop()
        keepAliveStreamer?.cancelStreamingAndDeleteData(false)
        keepAliveStreamer = nil
    }
}

/// SwiftUI bridge for the iOS / macOS app.
struct RemuxPlayerView: UIViewControllerRepresentable {
    let localFile: URL
    let title: String
    let streamer: PTTorrentStreamer?

    func makeUIViewController(context: Context) -> RemuxAVPlayerViewController {
        let vc = RemuxAVPlayerViewController()
        vc.configure(localFile: localFile, streamer: streamer, title: title)
        return vc
    }

    func updateUIViewController(_ vc: RemuxAVPlayerViewController, context: Context) {}
}
