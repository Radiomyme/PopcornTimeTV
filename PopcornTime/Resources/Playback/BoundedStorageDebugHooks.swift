#if DEBUG
import Foundation
import ObjectiveC
import AVFoundation
import PopcornTorrent
#if os(tvOS) || os(iOS)
import UIKit
import AVKit
#endif

/// Verification hooks of bounded storage (offline end-to-end runs on the Mac
/// and the tvOS simulator), compiled only with DEBUG — the app targets do not
/// define it: build with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` on the
/// xcodebuild command line, as for SceneDelegate's and MacDebugHooks' hooks.
/// Launch arguments:
/// - `-PTDebugPlayTorrent <absolute path of a .torrent file>`: once the UI is
///   up, plays it through the app's normal flow (tvOS: `AppDelegate.play`,
///   loading screen and players; macOS: `MacPlayerView` in a sheet), as a
///   placeholder movie (`-PTDebugDuration <s>`: its runtime, the bitrate
///   bounded storage assumes; default unknown = 2 h);
/// - `-PTDebugDownloadDir <dir>`: the torrent's directory (PopcornTorrent
///   `downloadDirectoryOverride`) — and the remux's output too, so the whole
///   stream lives on that volume (e.g. a small APFS disk image);
/// - `-PTDebugLoopbackPort <port>`: PopcornTorrent's shared session listens
///   on 127.0.0.1:<port> only (0 = any), no DHT / LSD / UPnP / NAT-PMP
///   (`PTTorrentsSession+Testing.h`); set up before anything touches the
///   session (call `prepareAtLaunch()` first thing at launch);
/// - `-PTDebugSeek "<target s>@<at s>,…"`: at `at` seconds after playback
///   started (the first player attached), seeks the current player to
///   `target` (seconds of media, the player's own clock) — the way a user's
///   seek does (`.ptDebugSeek`);
/// - `-PTDebugPause "<at s>+<duration s>,…"`: pauses at `at`, resumes
///   `duration` seconds later (`.ptDebugPlayback`);
/// - `-PTDebugQuitAfter <s>`: that long after playback started, cancels the
///   stream (deleting its data, as closing the player does), logs the free
///   space, and quits 3 s later.
/// Coverage hooks (part 3: paths the earlier runs never exercised):
/// - `-PTDebugClosePlayer <s>`: that long after playback started, closes the
///   player through the UI's own close path (tvOS: the VLC player's Menu
///   action, or the dismissal AVKit performs on Menu for the native player;
///   macOS: the sheet's close button, else its Escape shortcut; iOS: the
///   player's close action), then logs the free space, what is left on the
///   volume and the streams still alive at +1…+20 s;
/// - `-PTDebugFailPlayer "<at s>:<decode|starve|missing>,…"`: posts
///   `AVPlayerItemFailedToPlayToEndTime` for the current AVPlayer item with a
///   decode error (→ the VLC hand-off), a CoreMedia -12889 starvation error
///   (→ the native starvation recovery) or an HTTP 404 (missing resource);
///   the app's own failure observer takes it from there;
/// - `-PTDebugRawSeek "<target s>@<at s>,…"`: seeks the current AVPlayer
///   directly, bypassing the app's seek guards (what a remote command or a
///   scrub that skips the AVKit delegate does); paused or playing as it is;
/// - `-PTDebugReopenNetwork "<at s>,…"`: PopcornTorrent's
///   `reopenNetworkForTesting` (what the tvOS app does when it becomes
///   active after more than 5 minutes in the background);
/// - `-PTDebugDownloadTorrent <absolute .torrent path>` (with
///   `-PTDebugDownloadTorrentDir <dir>`, default `<PTDebugDownloadDir>/../offline`,
///   and `-PTDebugDownloadAt <s after launch>`, default 0): an offline
///   download of that torrent, registered with the download manager like the
///   app's own (`BoundedStorageSession.pendingDownloadBytes` sees it), its
///   progress logged every 2 s (with what a -5 refusal would ask to free); stopped (its data deleted) at quit;
/// - `-PTDebugPlayerStateEvery <s>`: the native player's state every `s`
///   seconds (rate, waiting reason, loaded ranges, error log entries);
/// - `-PTDebugHTTPTrace 1`: the streamer's HTTP server traced — every
///   bounded byte-range response (PopcornTorrent's `PTGatedFileResponse`,
///   swizzled: its range when it opens, read errors, how far it got and its
///   longest wait between two chunks when it closes) and GCDWebServer's own
///   verbose log (one line per connection with its status code and bytes);
/// - `-PTDebugLaunchSnapshotAt "<name>@<s after launch>,…"` (macOS): the
///   same, timed from launch (a stream that never starts playing);
/// - `-PTDebugSnapshotAt "<name>@<at s>,…"` (macOS): the player's window
///   into `<-PTDebugBoundedSnapshots dir>/<name>.png`, and its visible texts
///   logged.
/// - `-PTDebugHoleProbe 1`: at launch, the device pre-flight of the volume
///   primitives bounded storage relies on — PopcornTorrent's hole self-test
///   (SEEK_HOLE, SEEK_DATA, F_PUNCHHOLE on a scratch file; the check a stream
///   runs once per volume before it allows bounded storage) in the streams'
///   folder and, on tvOS / iOS, the offline downloads' folder, and the free
///   space by every key the platform has: "[HoleProbe]" lines.
/// Every step logs a "[BoundedDebug]" line. Nothing happens without these
/// arguments.
enum BoundedStorageDebugHooks {
    private static var defaults: UserDefaults { .standard }

    /// The .torrent to play (`-PTDebugPlayTorrent`).
    static var torrentFile: String? { defaults.string(forKey: "PTDebugPlayTorrent") }

    /// `-PTDebugDuration`, seconds (nil: unknown).
    static var durationSeconds: Double? { defaults.string(forKey: "PTDebugDuration").flatMap(Double.init) }

    static var isActive: Bool {
        ["PTDebugPlayTorrent", "PTDebugDownloadDir", "PTDebugLoopbackPort", "PTDebugSeek", "PTDebugPause",
         "PTDebugQuitAfter", "PTDebugClosePlayer", "PTDebugFailPlayer", "PTDebugRawSeek", "PTDebugReopenNetwork",
         "PTDebugDownloadTorrent", "PTDebugSnapshotAt", "PTDebugPlayerStateEvery", "PTDebugLaunchSnapshotAt",
         "PTDebugHTTPTrace"].contains { defaults.object(forKey: $0) != nil }
    }

    /// First thing at launch: the loopback session and the download
    /// directory (before any PopcornTorrent session exists), then the
    /// offline download, if any.
    static func prepareAtLaunch() {
        if isActive {
            // Line-buffered stdout: a run's log keeps every line up to a
            // crash or a kill (a file is block-buffered otherwise).
            setvbuf(stdout, nil, _IOLBF, 0)
        }
        if let directory = defaults.string(forKey: "PTDebugDownloadDir"), !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            BoundedStorageDebug.downloadDirectory = directory
            RemuxPlayback.outputParentOverride = URL(fileURLWithPath: directory, isDirectory: true)
            print("[BoundedDebug] download directory \(directory) (remux output there too)")
        }
        if let port = defaults.string(forKey: "PTDebugLoopbackPort").flatMap(Int32.init) {
            prepareLoopbackSession(port: port)
        }
        startOfflineDownloadIfRequested()
        if defaults.bool(forKey: "PTDebugHTTPTrace") { HTTPTrace.install() }
        if defaults.bool(forKey: "PTDebugHoleProbe") { runHoleProbe() }
        #if os(macOS)
        // `-PTDebugLaunchSnapshotAt "<name>@<s after launch>,…"`: the player's
        // window (or the main one) even when playback never starts.
        for (name, at) in namedTimes(defaults.string(forKey: "PTDebugLaunchSnapshotAt")) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                MainActor.assumeIsolated {
                    MacDebugHooks.snapshotPlayerWindow(named: name, after: 0)
                    print("[BoundedDebug] launch+\(Int(at)) s: snapshot \(name); player shown: \(MacDebugHooks.playerSheet != nil)")
                }
            }
        }
        #endif
    }

    /// `-PTDebugHoleProbe 1`: the pre-flight (see the list above). Off the
    /// main queue; one "[HoleProbe]" line per check.
    private static func runHoleProbe() {
        DispatchQueue.global(qos: .utility).async {
            var folders: [String] = []
            if let streams = PTTorrentStreamer.downloadDirectory() { folders.append(streams) }
            #if !os(macOS)
            // The Mac has no offline downloads (asking creates ~/Documents/Downloads).
            if let downloads = PTTorrentDownload.downloadDirectory() { folders.append(downloads) }
            #endif
            for folder in folders {
                var passed: ObjCBool = false
                let report = PTTorrentStreamer.holeSupportReport(forDirectory: folder, passed: &passed)
                print("[HoleProbe] \(passed.boolValue ? "PASS" : "FAIL") \(report)")
                print("[HoleProbe] free space at \(folder): \(freeSpaceDescription(folder))")
            }
            print("[HoleProbe] done")
        }
    }

    /// The free space of the volume holding `path` by every key this
    /// platform has (tvOS: `volumeAvailableCapacity` only — the figure the
    /// app and PopcornTorrent use; Settings may count purgeable space too).
    private static func freeSpaceDescription(_ path: String) -> String {
        var url = URL(fileURLWithPath: path)
        url.removeAllCachedResourceValues()
        var keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        #if !os(tvOS)
        keys.insert(.volumeAvailableCapacityForImportantUsageKey)
        keys.insert(.volumeAvailableCapacityForOpportunisticUsageKey)
        #endif
        let values = try? url.resourceValues(forKeys: keys)
        func mib(_ value: Int64?) -> String { value.map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "-" }
        var parts = ["available \(mib(values?.volumeAvailableCapacity.map(Int64.init)))",
                     "total \(mib(values?.volumeTotalCapacity.map(Int64.init)))"]
        #if !os(tvOS)
        parts.append("important usage \(mib(values?.volumeAvailableCapacityForImportantUsage))")
        parts.append("opportunistic usage \(mib(values?.volumeAvailableCapacityForOpportunisticUsage))")
        #endif
        return parts.joined(separator: ", ")
    }

    /// `+[PTTorrentsSession prepareSharedSessionForLoopbackTestingOnPort:]`
    /// (not in the package's public headers): looked up at run time.
    private static func prepareLoopbackSession(port: Int32) {
        let selector = NSSelectorFromString("prepareSharedSessionForLoopbackTestingOnPort:")
        guard let cls = NSClassFromString("PTTorrentsSession"),
              let method = class_getClassMethod(cls, selector) else {
            print("[BoundedDebug] loopback testing hook not found in PopcornTorrent — NOT started offline")
            return
        }
        typealias Prepare = @convention(c) (AnyClass, Selector, Int32) -> Void
        let prepare = unsafeBitCast(method_getImplementation(method), to: Prepare.self)
        prepare(cls, selector, port)
        print("[BoundedDebug] PopcornTorrent session: 127.0.0.1:\(port) only, no DHT / LSD / UPnP / NAT-PMP")
    }

    // MARK: Script

    private static var scriptStarted = false

    /// Playback started (a player attached to the stream): schedules the
    /// seek / pause / quit script, once. Main queue.
    static func playbackDidStart() {
        guard isActive, !scriptStarted else { return }
        scriptStarted = true
        print("[BoundedDebug] playback started — script: seek=\(defaults.string(forKey: "PTDebugSeek") ?? "-") "
              + "pause=\(defaults.string(forKey: "PTDebugPause") ?? "-") quitAfter=\(defaults.string(forKey: "PTDebugQuitAfter") ?? "-") "
              + "close=\(defaults.string(forKey: "PTDebugClosePlayer") ?? "-") fail=\(defaults.string(forKey: "PTDebugFailPlayer") ?? "-") "
              + "rawSeek=\(defaults.string(forKey: "PTDebugRawSeek") ?? "-") reopen=\(defaults.string(forKey: "PTDebugReopenNetwork") ?? "-") "
              + "snapshots=\(defaults.string(forKey: "PTDebugSnapshotAt") ?? "-")")
        for (target, at) in pairs(defaults.string(forKey: "PTDebugSeek"), separator: "@") {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                print("[BoundedDebug] t+\(Int(at)) s: seek to \(target) s")
                NotificationCenter.default.post(name: .ptDebugSeek, object: nil, userInfo: ["seconds": target])
            }
        }
        for (at, duration) in pairs(defaults.string(forKey: "PTDebugPause"), separator: "+") {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                print("[BoundedDebug] t+\(Int(at)) s: pause for \(Int(duration)) s")
                NotificationCenter.default.post(name: .ptDebugPlayback, object: nil, userInfo: ["playing": false])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + at + duration) {
                print("[BoundedDebug] t+\(Int(at + duration)) s: resume")
                NotificationCenter.default.post(name: .ptDebugPlayback, object: nil, userInfo: ["playing": true])
            }
        }
        for (target, at) in pairs(defaults.string(forKey: "PTDebugRawSeek"), separator: "@") {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { rawSeek(to: target, at: at) }
        }
        for item in (defaults.string(forKey: "PTDebugFailPlayer") ?? "").split(separator: ",") {
            let parts = item.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let at = parts.first.flatMap(Double.init), at >= 0 else { continue }
            let kind = parts.count > 1 ? parts[1] : "decode"
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { failCurrentPlayer(kind: kind, at: at) }
        }
        for item in (defaults.string(forKey: "PTDebugReopenNetwork") ?? "").split(separator: ",") {
            guard let at = Double(item.trimmingCharacters(in: .whitespaces)), at >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { reopenNetwork(at: at) }
        }
        #if os(macOS)
        for (name, at) in namedTimes(defaults.string(forKey: "PTDebugSnapshotAt")) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                MainActor.assumeIsolated {
                    MacDebugHooks.snapshotPlayerWindow(named: name, after: 0)
                    print("[BoundedDebug] t+\(Int(at)) s: snapshot \(name); player texts: \(MacDebugHooks.playerTexts())")
                }
            }
        }
        #endif
        if let every = defaults.string(forKey: "PTDebugPlayerStateEvery").flatMap(Double.init), every > 0 {
            stateTimer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in logPlayerState() }
        }
        if let close = defaults.string(forKey: "PTDebugClosePlayer").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + close) { closePlayerNow(at: close) }
        }
        if let quit = defaults.string(forKey: "PTDebugQuitAfter").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + quit) { quitNow() }
        }
    }

    /// The streams to cancel at quit (weak: the players own them).
    private static var streamers = NSHashTable<PTTorrentStreamer>.weakObjects()

    /// A stream started by the app (`BoundedStorageSession.prepare`).
    static func noteStreamer(_ streamer: PTTorrentStreamer) {
        streamers.add(streamer)
        // The apps set GCDWebServer's level to warnings at launch (after
        // prepareAtLaunch on the Mac): verbose again once a stream starts.
        if defaults.bool(forKey: "PTDebugHTTPTrace") { HTTPTrace.applyVerboseLevel() }
    }

    private static func quitNow() {
        let directory = BoundedStorageDebug.downloadDirectory
        print("[BoundedDebug] quit: free before cancel \(freeDescription(directory))")
        for streamer in streamers.allObjects { streamer.cancelStreamingAndDeleteData(true) }
        if let download = offlineDownload {
            print("[BoundedDebug] quit: stopping the offline download (\(describe(download)))")
            PTTorrentDownloadManager.shared().stop(download)
            _ = download.delete()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("[BoundedDebug] quit: free after cancel \(freeDescription(directory))")
            exit(0)
        }
    }

    private static func freeDescription(_ directory: String?) -> String {
        guard let free = BoundedStorageSession.freeBytes(at: directory) else { return "?" }
        return String(format: "%.1f MiB", Double(free) / 1_048_576)
    }

    /// "a@b,c@d" → [(a, b), (c, d)] (numbers, seconds).
    static func pairs(_ text: String?, separator: Character) -> [(Double, Double)] {
        guard let text = text else { return [] }
        return text.split(separator: ",").compactMap { item in
            let parts = item.split(separator: separator).map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let first = parts[0], let second = parts[1], first >= 0, second >= 0 else { return nil }
            return (first, second)
        }
    }

    /// "name@b,…" → [(name, b)].
    static func namedTimes(_ text: String?) -> [(String, Double)] {
        guard let text = text else { return [] }
        return text.split(separator: ",").compactMap { item in
            let parts = item.split(separator: "@").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, let at = Double(parts[1]), at >= 0 else { return nil }
            return (parts[0], at)
        }
    }

    // MARK: Close

    /// `-PTDebugClosePlayer`: the UI's own close path, then what is left.
    private static func closePlayerNow(at: Double) {
        let directory = BoundedStorageDebug.downloadDirectory
        print("[BoundedDebug] t+\(Int(at)) s: close the player — free before \(freeDescription(directory)); "
              + "\(streamsDescription()); volume: \(volumeDescription(directory))")
        let how = closeCurrentPlayer()
        print("[BoundedDebug] close: \(how)")
        for delay in [1.0, 2, 3, 5, 10, 20, 30] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                print("[BoundedDebug] after close +\(Int(delay)) s: free \(freeDescription(directory)); "
                      + "\(streamsDescription()); player shown: \(isPlayerShown()); volume: \(volumeDescription(directory))")
            }
        }
    }

    /// The streams the app started that are still alive (the players own
    /// them: none once the player is gone), and PopcornTorrent's session's
    /// registered streams.
    private static func streamsDescription() -> String {
        let alive = streamers.allObjects
        let states = alive.map { streamer -> String in
            let mode: String
            switch streamer.storageMode {
            case .bounded: mode = "bounded"
            case .full: mode = "full"
            default: mode = "undetermined"
            }
            return "\(mode) onDiskMiB=\(Int(streamer.bytesOnDisk / 1_048_576)) session=\(BoundedStorageSession.session(for: streamer) != nil)"
        }
        var registered = "?"
        if let shared = sharedTorrentSession(), shared.responds(to: NSSelectorFromString("streamers")),
           let map = shared.value(forKey: "streamers") as? NSDictionary {
            registered = "\(map.count)"
        }
        return "streams alive \(alive.count) [\(states.joined(separator: "; "))], PopcornTorrent session streams \(registered)"
    }

    /// Top-level entries of the stream's directory with their allocated MiB
    /// (the torrent's folder, the remux's HLS folder).
    private static func volumeDescription(_ directory: String?) -> String {
        guard let directory = directory else { return "?" }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        if entries.isEmpty { return "empty" }
        return entries.sorted().map { entry -> String in
            let root = URL(fileURLWithPath: directory).appendingPathComponent(entry)
            var bytes: Int64 = 0
            var files = 0
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            if let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys) {
                for case let url as URL in walker {
                    guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                    bytes += Int64(values.totalFileAllocatedSize ?? 0)
                    files += 1
                }
            }
            if let values = try? root.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                bytes = Int64(values.totalFileAllocatedSize ?? 0)
                files = 1
            }
            return "\(entry) (\(files) files, \(String(format: "%.1f", Double(bytes) / 1_048_576)) MiB)"
        }.joined(separator: ", ")
    }

    /// The player's close action, as the user triggers it. Returns how.
    private static func closeCurrentPlayer() -> String {
        #if os(macOS)
        return MainActor.assumeIsolated { MacDebugHooks.closePlayerSheet() }
        #elseif os(tvOS)
        let controllers = allViewControllers()
        if let vlc = controllers.last(where: { $0 is PCTPlayerViewController }) as? PCTPlayerViewController {
            vlc.menuPressed()
            return "VLC player: menuPressed() (the remote's Menu button)"
        }
        if let native = controllers.last(where: { $0 is AVPlayerViewController }) {
            guard let presenter = native.presentingViewController else { return "native player not presented — nothing done" }
            // What AVKit does on Menu: the player is dismissed by its presenter.
            presenter.dismiss(animated: true)
            return "native player (\(type(of: native))): dismissed by its presenter, as AVKit does on Menu"
        }
        return "no player shown — nothing done"
        #else
        let controllers = allViewControllers()
        if let remux = controllers.last(where: { $0 is RemuxAVPlayerViewController }) as? RemuxAVPlayerViewController,
           let close = remux.onCloseRequest {
            close()
            return "native player: onCloseRequest (its close button)"
        }
        if let vlc = controllers.last(where: { $0 is VLCPlayerViewController }),
           vlc.responds(to: NSSelectorFromString("close")) {
            vlc.perform(NSSelectorFromString("close"))
            return "VLC player: close() (its close button)"
        }
        if let top = controllers.last(where: { $0.presentingViewController != nil }) {
            top.presentingViewController?.dismiss(animated: true)
            return "\(type(of: top)) dismissed by its presenter"
        }
        return "no player shown — nothing done"
        #endif
    }

    private static func isPlayerShown() -> Bool {
        #if os(macOS)
        return MainActor.assumeIsolated { MacDebugHooks.playerSheet != nil }
        #else
        return allViewControllers().contains { controller in
            guard !controller.isBeingDismissed else { return false }
            if controller is AVPlayerViewController { return true }
            #if os(tvOS)
            return controller is PCTPlayerViewController
            #else
            return controller is VLCPlayerViewController
            #endif
        }
        #endif
    }

    // MARK: AVPlayer

    /// The AVPlayer of the player on screen (native routes), nil for VLC.
    private static func currentAVPlayer() -> AVPlayer? {
        #if os(macOS)
        return MainActor.assumeIsolated { MacDebugHooks.currentAVPlayer() }
        #else
        let players = allViewControllers().compactMap { ($0 as? AVPlayerViewController)?.player }
        return players.last
        #endif
    }

    /// `-PTDebugFailPlayer`: the item "failed to play to its end" with an
    /// error of that class; the app's `AVPlayerItemFailureObserver` reports
    /// it like a real one.
    private static func failCurrentPlayer(kind: String, at: Double) {
        guard let player = currentAVPlayer(), let item = player.currentItem else {
            print("[BoundedDebug] t+\(Int(at)) s: fail player (\(kind)): no AVPlayer item on screen — nothing done")
            return
        }
        let error: NSError
        switch kind {
        case "starve":
            error = NSError(domain: "CoreMediaErrorDomain", code: -12889,
                            userInfo: [NSLocalizedDescriptionKey: "DEBUG: no response for media file (forced starvation)"])
        case "missing":
            let underlying = NSError(domain: "CoreMediaErrorDomain", code: -12938,
                                     userInfo: [NSLocalizedDescriptionKey: "HTTP 404: File Not Found (forced)"])
            error = NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist,
                            userInfo: [NSLocalizedDescriptionKey: "DEBUG: resource unavailable (forced)",
                                       NSUnderlyingErrorKey: underlying])
        default:
            error = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "DEBUG: cannot decode (forced)"])
        }
        print("[BoundedDebug] t+\(Int(at)) s: fail player (\(kind)) at \(String(format: "%.1f", player.currentTime().seconds)) s "
              + "rate \(player.rate) — \(error.domain) \(error.code)")
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item,
                                        userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: error])
    }

    /// `-PTDebugRawSeek`: AVPlayer's own seek, no app guard.
    private static func rawSeek(to target: Double, at: Double) {
        guard let player = currentAVPlayer() else {
            print("[BoundedDebug] t+\(Int(at)) s: raw seek to \(target) s: no AVPlayer on screen — nothing done")
            return
        }
        let now = player.currentTime().seconds
        print("[BoundedDebug] t+\(Int(at)) s: raw AVPlayer seek \(String(format: "%.1f", now)) → \(target) s (rate \(player.rate), no app guard)")
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { done in
            print("[BoundedDebug] raw seek to \(target) s finished=\(done), now \(String(format: "%.1f", player.currentTime().seconds)) s")
        }
    }

    private static var stateTimer: Timer?
    private static var lastErrorEvents = 0

    /// `-PTDebugPlayerStateEvery <s>`: the native player's state (a stall
    /// shows as waiting with nothing loaded ahead), and any new entry of its
    /// item's error log (HTTP status codes of the byte-range requests).
    private static func logPlayerState() {
        guard let player = currentAVPlayer() else { return }
        let item = player.currentItem
        let status: String
        switch player.timeControlStatus {
        case .paused: status = "paused"
        case .playing: status = "playing"
        case .waitingToPlayAtSpecifiedRate: status = "waiting(\(player.reasonForWaitingToPlay?.rawValue ?? "?"))"
        @unknown default: status = "?"
        }
        let now = player.currentTime().seconds
        let ranges = (item?.loadedTimeRanges ?? []).map { $0.timeRangeValue }
            .map { String(format: "%.1f-%.1f", $0.start.seconds, $0.end.seconds) }.joined(separator: ",")
        var line = String(format: "[BoundedDebug] player: t=%.1f rate=%.1f %@ item=%d keepUp=%d empty=%d loaded=[%@]",
                          now, player.rate, status, item?.status.rawValue ?? -1,
                          (item?.isPlaybackLikelyToKeepUp ?? false) ? 1 : 0, (item?.isPlaybackBufferEmpty ?? false) ? 1 : 0, ranges)
        if let access = item?.accessLog()?.events.last {
            line += " bytes=\(access.numberOfBytesTransferred) stalls=\(access.numberOfStalls) requests=\(access.numberOfMediaRequests)"
        }
        print(line)
        if let errors = item?.errorLog()?.events, errors.count > lastErrorEvents {
            for event in errors[lastErrorEvents...] {
                print("[BoundedDebug] player error log: \(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "") uri=\(event.uri ?? "-")")
            }
            lastErrorEvents = errors.count
        } else if (item?.errorLog()?.events.count ?? 0) < lastErrorEvents {
            lastErrorEvents = item?.errorLog()?.events.count ?? 0
        }
    }

    // MARK: Network reopen

    /// `-PTDebugReopenNetwork`: `-[PTTorrentsSession reopenNetworkForTesting]`
    /// (`PTTorrentsSession+Testing.h`, looked up at run time).
    private static func reopenNetwork(at: Double) {
        let selector = NSSelectorFromString("reopenNetworkForTesting")
        guard let shared = sharedTorrentSession(), shared.responds(to: selector) else {
            print("[BoundedDebug] t+\(Int(at)) s: reopenNetworkForTesting not found in PopcornTorrent — nothing done")
            return
        }
        print("[BoundedDebug] t+\(Int(at)) s: PopcornTorrent reopenNetworkForTesting")
        shared.perform(selector)
    }

    /// `+[PTTorrentsSession sharedSession]`, looked up at run time (the
    /// class is not in every build's public headers).
    private static func sharedTorrentSession() -> NSObject? {
        let selector = NSSelectorFromString("sharedSession")
        guard let cls = NSClassFromString("PTTorrentsSession"), let method = class_getClassMethod(cls, selector) else { return nil }
        typealias Shared = @convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>
        return unsafeBitCast(method_getImplementation(method), to: Shared.self)(cls, selector).takeUnretainedValue()
    }

    // MARK: Offline download

    private static var offlineDownload: PTTorrentDownload?
    private static var offlineDownloadTimer: Timer?

    /// `-PTDebugDownloadTorrent`: a download of a local .torrent (another
    /// seeder on the loopback session), in its own directory on the same
    /// volume, listed in `PTTorrentDownloadManager.activeDownloads` like the
    /// app's downloads.
    private static func startOfflineDownloadIfRequested() {
        guard let file = defaults.string(forKey: "PTDebugDownloadTorrent"), !file.isEmpty else { return }
        let directory = defaults.string(forKey: "PTDebugDownloadTorrentDir")
            ?? BoundedStorageDebug.downloadDirectory.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("offline") }
        let delay = defaults.string(forKey: "PTDebugDownloadAt").flatMap(Double.init) ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
            let download = PTTorrentDownload(mediaMetadata: ["persistentID": "tt9999999", "title": "Bounded storage download test"],
                                             downloadStatus: .processing)
            if let directory = directory {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                download.downloadDirectoryOverride = directory
            }
            let manager = PTTorrentDownloadManager.shared()
            if let list = manager.value(forKey: "activeDownloads") as? NSMutableArray {
                list.add(download)
            } else {
                print("[BoundedDebug] download: cannot register with the download manager — pendingDownloadBytes will not see it")
            }
            offlineDownload = download
            download.startDownloading(fromFileOrMagnetLink: file) { _, _ in 0 }
            print("[BoundedDebug] download started: \(file) → \(directory ?? "default directory")")
            offlineDownloadTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                guard let download = offlineDownload else { return }
                // What a -5 refusal of each stream would ask to free now
                // (`StreamFailure`, the same inputs as the player's message).
                let streams = streamers.allObjects.map { streamer -> String in
                    let usable = BoundedStorageSession.session(for: streamer)?.usableFreeBytes() ?? -1
                    let amount = BoundedStorage.bytesToFree(fileSize: streamer.fileSize.longLongValue,
                                                            durationSeconds: streamer.mediaDurationHint,
                                                            freeBytes: usable, heldBytes: streamer.bytesOnDisk)
                    return "usableMiB=\(usable / 1_048_576) heldMiB=\(streamer.bytesOnDisk / 1_048_576) "
                        + "savePath=\(streamer.savePath == nil ? "nil" : "set") bytesToFree=\(amount)"
                }
                print("[BoundedDebug] download: \(describe(download)) pendingDownloadBytesMiB="
                      + "\(BoundedStorageSession.pendingDownloadBytes() / 1_048_576) volume free \(freeDescription(BoundedStorageDebug.downloadDirectory)); "
                      + "streams: \(streams.joined(separator: " | "))")
            }
        }
    }

    private static func describe(_ download: PTTorrentDownload) -> String {
        let status: String
        switch download.downloadStatus {
        case .processing: status = "processing"
        case .downloading: status = "downloading"
        case .paused: status = "paused"
        case .finished: status = "finished"
        case .failed: status = "failed"
        @unknown default: status = "?"
        }
        return "status=\(status) onDiskMiB=\(download.bytesOnDisk / 1_048_576) sizeMiB=\(download.fileSize.longLongValue / 1_048_576)"
    }

    // MARK: View controllers (tvOS / iOS)

    #if os(tvOS) || os(iOS)
    /// Every view controller on screen: the windows' roots, their children
    /// and what they present, in z-order (the last ones on top).
    private static func allViewControllers() -> [UIViewController] {
        var result: [UIViewController] = []
        func visit(_ controller: UIViewController, depth: Int) {
            guard depth < 40 else { return }
            result.append(controller)
            for child in controller.children { visit(child, depth: depth + 1) }
            if let presented = controller.presentedViewController, presented.presentingViewController === controller {
                visit(presented, depth: depth + 1)
            }
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        for window in windows {
            if let root = window.rootViewController { visit(root, depth: 0) }
        }
        return result
    }
    #endif
}

/// `-PTDebugHTTPTrace 1`: what the players ask PopcornTorrent's HTTP server
/// for, and how each answer ends (diagnosis of a native player that stops
/// asking). `PTGatedFileResponse`'s `open:`, `asyncReadDataWithCompletion:`
/// and `close` are swizzled (their ivars `_offset` / `_end` read in place);
/// GCDWebServer's built-in logger prints its verbose lines (status code and
/// bytes of every connection, its errors) on stdout.
private enum HTTPTrace {
    private final class Response {
        let id: Int
        let start: Int64
        let end: Int64
        let opened = Date()
        var served: Int64 = 0
        var chunks = 0
        var last = Date()
        var maxGap: TimeInterval = 0
        var firstAfter: TimeInterval = -1
        init(id: Int, start: Int64, end: Int64) { self.id = id; self.start = start; self.end = end }
    }

    private static let lock = NSLock()
    private static var responses: [ObjectIdentifier: Response] = [:]
    private static var nextID = 0
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func log(_ text: String) {
        lock.lock(); let stamp = formatter.string(from: Date()); lock.unlock()
        print("[HTTPTrace] \(stamp) \(text)")
    }

    private static func mib(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }

    /// An `int64_t` ivar of an Objective-C object, read in place.
    private static func int64Ivar(_ object: AnyObject, _ name: String) -> Int64? {
        guard let ivar = class_getInstanceVariable(type(of: object), name) else { return nil }
        return Unmanaged.passUnretained(object).toOpaque().advanced(by: ivar_getOffset(ivar)).load(as: Int64.self)
    }

    static func install() {
        installServerLogger()
        guard let cls = NSClassFromString("PTGatedFileResponse") else {
            print("[BoundedDebug] HTTP trace: PTGatedFileResponse not found — responses not traced")
            return
        }
        // - (BOOL)open:(NSError **)error
        let openSel = NSSelectorFromString("open:")
        if let method = class_getInstanceMethod(cls, openSel) {
            typealias OpenIMP = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer?) -> ObjCBool
            let original = unsafeBitCast(method_getImplementation(method), to: OpenIMP.self)
            let replacement: @convention(block) (AnyObject, UnsafeMutableRawPointer?) -> ObjCBool = { object, error in
                let start = int64Ivar(object, "_offset") ?? -1, end = int64Ivar(object, "_end") ?? -1
                lock.lock(); nextID += 1; let response = Response(id: nextID, start: start, end: end)
                responses[ObjectIdentifier(object)] = response; lock.unlock()
                log("open #\(response.id) bytes \(start)-\(end - 1) (\(mib(start)) MiB, \(mib(end - start)) MiB long)")
                return original(object, openSel, error)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        // - (void)asyncReadDataWithCompletion:(void (^)(NSData *, NSError *))block
        let readSel = NSSelectorFromString("asyncReadDataWithCompletion:")
        if let method = class_getInstanceMethod(cls, readSel) {
            typealias Completion = @convention(block) (NSData?, NSError?) -> Void
            typealias ReadIMP = @convention(c) (AnyObject, Selector, @escaping Completion) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: ReadIMP.self)
            let replacement: @convention(block) (AnyObject, @escaping Completion) -> Void = { object, completion in
                let key = ObjectIdentifier(object)
                let asked = Date()
                let offset = int64Ivar(object, "_offset") ?? -1
                let wrapped: Completion = { data, error in
                    let now = Date()
                    lock.lock()
                    let response = responses[key]
                    if let response, let data, data.length > 0 {
                        if response.firstAfter < 0 { response.firstAfter = now.timeIntervalSince(response.opened) }
                        response.maxGap = max(response.maxGap, now.timeIntervalSince(response.chunks == 0 ? response.opened : response.last))
                        response.served += Int64(data.length)
                        response.chunks += 1
                        response.last = now
                    }
                    lock.unlock()
                    if let error {
                        log("read error #\(response?.id ?? -1) at \(offset) (\(mib(offset)) MiB) after \(String(format: "%.2f", now.timeIntervalSince(asked))) s: "
                            + "\(error.domain) \(error.code) — the connection ends here")
                    } else if now.timeIntervalSince(asked) > 2 {
                        log("slow read #\(response?.id ?? -1) at \(offset) (\(mib(offset)) MiB): \(String(format: "%.2f", now.timeIntervalSince(asked))) s")
                    }
                    completion(data, error)
                }
                original(object, readSel, wrapped)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        // - (void)close
        let closeSel = NSSelectorFromString("close")
        if let method = class_getInstanceMethod(cls, closeSel) {
            typealias CloseIMP = @convention(c) (AnyObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: CloseIMP.self)
            let replacement: @convention(block) (AnyObject) -> Void = { object in
                let reached = int64Ivar(object, "_offset") ?? -1
                lock.lock(); let response = responses.removeValue(forKey: ObjectIdentifier(object)); lock.unlock()
                if let response {
                    let complete = reached >= response.end
                    log("close #\(response.id) bytes \(response.start)-\(response.end - 1): served \(mib(response.served)) MiB in \(response.chunks) chunks, "
                        + "reached \(reached) (\(complete ? "complete" : "CUT \(mib(response.end - reached)) MiB short")), "
                        + "first data after \(String(format: "%.2f", response.firstAfter)) s, longest wait \(String(format: "%.2f", response.maxGap)) s, "
                        + "open \(String(format: "%.1f", Date().timeIntervalSince(response.opened))) s")
                } else {
                    log("close (untracked) reached \(reached)")
                }
                original(object, closeSel)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        print("[BoundedDebug] HTTP trace on: PTGatedFileResponse open/read/close and GCDWebServer verbose log")
    }

    /// `+[GCDWebServer setLogLevel:1]` (verbose) and `+setBuiltInLogger:` to
    /// stdout (GCDWebServer logs nothing when stderr is not a terminal).
    static func applyVerboseLevel() {
        guard let server = NSClassFromString("GCDWebServer") else { return }
        let levelSel = NSSelectorFromString("setLogLevel:")
        if let method = class_getClassMethod(server, levelSel) {
            typealias SetLevel = @convention(c) (AnyClass, Selector, Int32) -> Void
            unsafeBitCast(method_getImplementation(method), to: SetLevel.self)(server, levelSel, 1)
        }
    }

    private static func installServerLogger() {
        guard let server = NSClassFromString("GCDWebServer") else { return }
        applyVerboseLevel()
        let loggerSel = NSSelectorFromString("setBuiltInLogger:")
        if let method = class_getClassMethod(server, loggerSel) {
            typealias Logger = @convention(block) (Int32, NSString) -> Void
            typealias SetLogger = @convention(c) (AnyClass, Selector, Logger) -> Void
            let names = ["DEBUG", "VERBOSE", "INFO", "WARNING", "ERROR"]
            let logger: Logger = { level, message in
                log("gcd \(level >= 0 && level < 5 ? names[Int(level)] : "\(level)"): \(message)")
            }
            unsafeBitCast(method_getImplementation(method), to: SetLogger.self)(server, loggerSel, logger)
        }
    }
}

extension Notification.Name {
    /// DEBUG: seek the current player; userInfo["seconds"]: Double (media time).
    static let ptDebugSeek = Notification.Name("PTDebugSeek")
    /// DEBUG: pause / play the current player; userInfo["playing"]: Bool.
    static let ptDebugPlayback = Notification.Name("PTDebugPlayback")
}
#endif
