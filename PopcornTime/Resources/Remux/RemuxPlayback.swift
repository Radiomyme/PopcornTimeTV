

import Foundation
import AVKit
import SwiftUI
import GCDWebServer
import PopcornTorrent
import PopcornKit

/// Drives MKVToHLSRemuxSession against the still-downloading torrent file and
/// serves it to AVPlayer as a **complete VOD** HLS presentation:
///
///  - The media playlist is generated dynamically with the movie's TOTAL
///    duration (from the MKV header): segments already remuxed get their real
///    durations, future ones get the target estimate, and ENDLIST is always
///    present. AVPlayer therefore shows the full timeline and scrubber from
///    the first second — no "live" badge.
///  - Requests for segments that aren't remuxed yet are HELD by the server
///    (long-poll) until the remuxer produces them, so seeking within the
///    downloaded range just works and seeking ahead waits like buffering.
///  - OpenSubtitles subtitles are exposed as native HLS subtitle tracks
///    (SRT → WebVTT converted on demand), so they appear in AVPlayer's own
///    subtitle picker.
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
    private let workQueue = DispatchQueue(label: "remux.pump", qos: .userInitiated)
    private var isPumping = false
    private var idleTicks = 0
    private let inputFile: URL
    private let outputDir: URL
    /// Release name carried the Atmos tag → signal JOC in the dec3 box so the
    /// Apple TV lights the receiver's Atmos badge. Gated on the reliable
    /// `.atmos` tag rather than fragile in-bitstream JOC parsing.
    private let isAtmos: Bool
    weak var streamer: PTTorrentStreamer?
    /// Subtitles offered as native tracks (OpenSubtitles model objects).
    var subtitles: [Subtitle] = []
    var onReady: ((URL) -> Void)?
    var onFailure: ((String) -> Void)?
    private var prepared = false
    private var started = false
    private var finishedRemux = false

    init(localFile: URL, streamer: PTTorrentStreamer?, isAtmos: Bool = false) {
        self.inputFile = localFile
        self.streamer = streamer
        self.isAtmos = isAtmos
        self.outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-\(UUID().uuidString.prefix(8))")
    }

    // MARK: - Server

    func start() {
        installHandlers()
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

    private func installHandlers() {
        // Master playlist: video/audio stream + subtitle group.
        server.addHandler(forMethod: "GET", path: "/master.m3u8", request: GCDWebServerRequest.self) { [weak self] _ in
            guard let self = self else { return GCDWebServerResponse(statusCode: 410) }
            return GCDWebServerDataResponse(data: self.masterPlaylist().data(using: .utf8)!,
                                            contentType: "application/vnd.apple.mpegurl")
        }
        // Video media playlist: full VOD with estimated tail.
        server.addHandler(forMethod: "GET", path: "/video.m3u8", request: GCDWebServerRequest.self) { [weak self] _ in
            guard let self = self else { return GCDWebServerResponse(statusCode: 410) }
            return GCDWebServerDataResponse(data: self.mediaPlaylist(initName: "video_init.mp4", segPrefix: "vseg").data(using: .utf8)!,
                                            contentType: "application/vnd.apple.mpegurl")
        }
        // Audio media playlist (demuxed rendition — carries Atmos signaling).
        server.addHandler(forMethod: "GET", path: "/audio.m3u8", request: GCDWebServerRequest.self) { [weak self] _ in
            guard let self = self else { return GCDWebServerResponse(statusCode: 410) }
            return GCDWebServerDataResponse(data: self.mediaPlaylist(initName: "audio_init.mp4", segPrefix: "aseg").data(using: .utf8)!,
                                            contentType: "application/vnd.apple.mpegurl")
        }
        // Subtitle playlists + payloads.
        server.addHandler(forMethod: "GET", pathRegex: "^/sub_.*\\.m3u8$", request: GCDWebServerRequest.self) { [weak self] request in
            guard let self = self else { return GCDWebServerResponse(statusCode: 410) }
            let lang = request.path.replacingOccurrences(of: "/sub_", with: "").replacingOccurrences(of: ".m3u8", with: "")
            return GCDWebServerDataResponse(data: self.subtitlePlaylist(lang: lang).data(using: .utf8)!,
                                            contentType: "application/vnd.apple.mpegurl")
        }
        server.addHandler(forMethod: "GET", pathRegex: "^/sub_.*\\.vtt$", request: GCDWebServerRequest.self, asyncProcessBlock: { [weak self] request, completion in
            guard let self = self else { completion(GCDWebServerResponse(statusCode: 410)); return }
            let lang = request.path.replacingOccurrences(of: "/sub_", with: "").replacingOccurrences(of: ".vtt", with: "")
            self.vttData(lang: lang) { data in
                if let data = data {
                    completion(GCDWebServerDataResponse(data: data, contentType: "text/vtt"))
                } else {
                    completion(GCDWebServerResponse(statusCode: 404))
                }
            }
        })
        // init segments + media segments (video + audio renditions): long-poll
        // until the remuxer has produced the file (up to 120 s — covers seeks
        // just past the download frontier).
        server.addHandler(forMethod: "GET", pathRegex: "^/(video_init\\.mp4|audio_init\\.mp4|vseg[0-9]+\\.m4s|aseg[0-9]+\\.m4s)$", request: GCDWebServerRequest.self, asyncProcessBlock: { [weak self] request, completion in
            guard let self = self else { completion(GCDWebServerResponse(statusCode: 410)); return }
            let target = self.outputDir.appendingPathComponent(String(request.path.dropFirst()))
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(120)
                while Date() < deadline {
                    if FileManager.default.fileExists(atPath: target.path) {
                        if let response = GCDWebServerFileResponse(file: target.path) {
                            completion(response)
                        } else {
                            completion(GCDWebServerResponse(statusCode: 500))
                        }
                        return
                    }
                    // A segment index past what the movie actually produced
                    // (estimate off by one at the credits): stop waiting once
                    // remuxing has finished for good.
                    if self.finishedRemux { break }
                    Thread.sleep(forTimeInterval: 0.4)
                }
                completion(GCDWebServerResponse(statusCode: 404))
            }
        })
    }

    // MARK: - Playlists

    private var expectedSegments: Int {
        guard let session = session, session.totalDurationSeconds > 0 else { return 0 }
        return Int((session.totalDurationSeconds / session.targetDuration).rounded(.up))
    }

    private func masterPlaylist() -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        // Audio is a demuxed rendition so it can carry CHANNELS — for a Dolby
        // Atmos release that's "16/JOC", the exact token tvOS reads to light
        // the receiver's Atmos badge. (Muxed audio has nowhere to put it.)
        let channels = session?.audioChannelsAttribute ?? (isAtmos ? "16/JOC" : "6")
        lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"\(channels)\",URI=\"audio.m3u8\"")
        var seenLangs = Set<String>()
        for subtitle in subtitles {
            let lang = subtitle.ISO639
            guard !lang.isEmpty, !seenLangs.contains(lang) else { continue }
            seenLangs.insert(lang)
            lines.append("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(subtitle.language)\",LANGUAGE=\"\(lang)\",AUTOSELECT=NO,DEFAULT=NO,URI=\"sub_\(lang).m3u8\"")
        }
        let subsAttr = seenLangs.isEmpty ? "" : ",SUBTITLES=\"subs\""
        // CODECS must list the audio codec (ec-3) for tvOS to treat the audio
        // rendition as Atmos-capable; the video codec is included when the
        // HEVC config has been parsed.
        let codecsAttr = session?.codecsAttribute.map { ",CODECS=\"\($0)\"" } ?? ""
        lines.append("#EXT-X-STREAM-INF:BANDWIDTH=25000000\(codecsAttr),AUDIO=\"aud\"\(subsAttr)")
        lines.append("video.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Video (`video_init.mp4` + `vseg*.m4s`) or audio (`audio_init.mp4` +
    /// `aseg*.m4s`) media playlist. Both renditions share the same segment
    /// grid and durations, so one generator serves both.
    private func mediaPlaylist(initName: String, segPrefix: String) -> String {
        guard let session = session else { return "#EXTM3U\n" }
        let actual = session.segmentSnapshot()
        let target = session.targetDuration
        let total = max(expectedSegments, actual.count)
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int(target.rounded(.up)) + 2)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"\(initName)\"",
        ]
        for index in 0..<total {
            let duration = index < actual.count ? actual[index].duration : target
            lines.append(String(format: "#EXTINF:%.3f,", duration))
            lines.append("\(segPrefix)\(index).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    private func subtitlePlaylist(lang: String) -> String {
        let duration = session?.totalDurationSeconds ?? 7200
        return """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(Int(duration.rounded(.up)) + 1)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(String(format: "%.3f", duration)),
        sub_\(lang).vtt
        #EXT-X-ENDLIST

        """
    }

    // MARK: - Subtitles (SRT → WebVTT on demand)

    private var vttCache: [String: Data] = [:]
    private let vttLock = NSLock()

    private func vttData(lang: String, completion: @escaping (Data?) -> Void) {
        vttLock.lock()
        if let cached = vttCache[lang] { vttLock.unlock(); completion(cached); return }
        vttLock.unlock()
        guard let subtitle = subtitles.first(where: { $0.ISO639 == lang }) else { completion(nil); return }
        PopcornKit.downloadSubtitleFile(subtitle.link, downloadDirectory: outputDir) { [weak self] fileURL, _ in
            guard let self = self, let fileURL = fileURL,
                  let raw = try? Data(contentsOf: fileURL),
                  // OpenSubtitles SRTs are frequently Windows-1252/Latin-1,
                  // not UTF-8 — try in order or accented characters die.
                  let srt = String(data: raw, encoding: .utf8)
                        ?? String(data: raw, encoding: .windowsCP1252)
                        ?? String(data: raw, encoding: .isoLatin1) else { completion(nil); return }
            let vtt = Self.srtToVTT(srt)
            let data = vtt.data(using: .utf8) ?? Data()
            self.vttLock.lock(); self.vttCache[lang] = data; self.vttLock.unlock()
            completion(data)
        }
    }

    /// SRT → WebVTT: header + decimal comma → dot in cue timings.
    static func srtToVTT(_ srt: String) -> String {
        // Normalize line endings FIRST. SRT files use CRLF, and splitting on
        // CharacterSet.newlines treats \r\n as TWO separators — that injected
        // a blank line after every line, and a blank line ends a WebVTT cue,
        // so Apple's parser saw timing-only and text-only fragments
        // ("Couldn't find --> in cue" / "No cue data") and rendered nothing.
        let normalized = srt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var out = "WEBVTT\n\n"
        for line in normalized.components(separatedBy: "\n") {
            if line.contains("-->") {
                out += line.replacingOccurrences(of: ",", with: ".") + "\n"
            } else {
                out += line + "\n"
            }
        }
        return out
    }

    // MARK: - Pump

    private var failedTicks = 0
    private func tick() {
        if session == nil {
            session = try? MKVToHLSRemuxSession(inputFile: inputFile, outputDirectory: outputDir, isAtmos: isAtmos)
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
            let url = URL(string: "http://127.0.0.1:\(server.port)/master.m3u8")!
            print("[Remux] playback ready: \(session.progress.segmentsWritten)/\(expectedSegments) segments — \(url)")
            DispatchQueue.main.async { self.onReady?(url) }
        }
        guard !session.progress.finished else { return }
        let torrentDone = (streamer?.torrentStatus.totalProgress ?? 1.0) >= 0.999
        idleTicks = newSegments == 0 ? idleTicks + 1 : 0
        if torrentDone && idleTicks >= 3 {
            session.finish()
            finishedRemux = true
            print("[Remux] finished: \(session.progress.segmentsWritten) segments, \(Int(session.progress.mediaSeconds))s")
            DispatchQueue.main.async { self.pumpTimer?.invalidate(); self.pumpTimer = nil }
        }
    }

    private func fail(_ message: String) {
        print("[Remux] FAIL: \(message)")
        stop()
        DispatchQueue.main.async { self.onFailure?(message) }
    }

    func stop() {
        pumpTimer?.invalidate()
        pumpTimer = nil
        if server.isRunning { server.stop() }
        try? FileManager.default.removeItem(at: outputDir)
    }

    var statsSummary: String {
        guard let session = session else { return "preparing…" }
        let expected = expectedSegments
        return "\(session.progress.segmentsWritten)/\(expected > 0 ? "\(expected)" : "?") segs · \(Int(session.progress.mediaSeconds))s remuxed"
    }
}

/// AVPlayerViewController wrapper for the remux path with a toggleable nerd
/// stats overlay — `Audio ec-3` is the on-screen proof Apple's renderer gets
/// the raw E-AC-3 and performs the Atmos rendering.
final class RemuxAVPlayerViewController: AVPlayerViewController {

    private var remux: RemuxPlayback?
    private var keepAliveStreamer: PTTorrentStreamer?
    private let statsLabel = UILabel()
    private var statsTimer: Timer?

    func configure(localFile: URL, streamer: PTTorrentStreamer?, title: String, media: Media? = nil, isAtmos: Bool = false) {
        keepAliveStreamer = streamer
        let remux = RemuxPlayback(localFile: localFile, streamer: streamer, isAtmos: isAtmos)
        self.remux = remux
        remux.onReady = { [weak self] playlistURL in
            let item = AVPlayerItem(url: playlistURL)
            let player = AVPlayer(playerItem: item)
            self?.player = player
            player.play()
        }
        // Fetch OpenSubtitles in parallel; they surface as native HLS
        // subtitle tracks in AVPlayer's own picker.
        if let media = media {
            if media.subtitles.isEmpty {
                // SubtitlesManager directly (getSubtitles lives in a
                // tvOS-only extension).
                if let episode = media as? Episode {
                    SubtitlesManager.shared.search(episode, imdbId: episode.show?.id) { subtitles, _ in
                        remux.subtitles = subtitles
                    }
                } else {
                    SubtitlesManager.shared.search(imdbId: media.id) { subtitles, _ in
                        remux.subtitles = subtitles
                    }
                }
            } else {
                remux.subtitles = media.subtitles
            }
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
        // Toggle with "n" (Mac/iPad keyboard) or up-click (Siri Remote).
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

#if os(tvOS)
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .upArrow }) {
            toggleStatsOverlay()
        }
        super.pressesBegan(presses, with: event)
    }
#endif

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
    var media: Media? = nil
    var isAtmos: Bool = false

    func makeUIViewController(context: Context) -> RemuxAVPlayerViewController {
        let vc = RemuxAVPlayerViewController()
        vc.configure(localFile: localFile, streamer: streamer, title: title, media: media, isAtmos: isAtmos)
        return vc
    }

    func updateUIViewController(_ vc: RemuxAVPlayerViewController, context: Context) {}
}
