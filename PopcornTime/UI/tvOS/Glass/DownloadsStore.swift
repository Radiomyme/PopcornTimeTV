// DownloadsStore.swift — the Apple TV's offline downloads, between
// PopcornTorrent's download manager and the Downloads page: the rows it
// shows, and what the manager leaves to the app.
//
// The manager (PopcornTorrent, frozen) drops a failed download from both of
// its lists, saves a download's progress only when its file is chosen and
// when it finishes, and resumes nothing after a relaunch on tvOS (its
// foreground observer is iOS-only). So, app-side:
// - a failed download stays listed, with the engine's reason, until it is
//   tried again or deleted (its files with it);
// - the progress is saved every 5 % or 30 s and when the app leaves the
//   foreground: a relaunch shows the percentage reached, not 0 %;
// - at launch, the downloads that were running resume; the ones the user
//   paused stay paused (`userPausedKey`);
// - at launch, folders of the download directory that no download owns (a
//   download stopped while its magnet resolved, a crash before its first
//   save) are deleted.

import UIKit
import Combine
import MediaPlayer.MPMediaItem
import PopcornKit
import PopcornTorrent

final class DownloadsStore: NSObject, ObservableObject, PTTorrentDownloadManagerListener {

    static let shared = DownloadsStore()

    /// Every download, active and finished (`DownloadsCatalog.sections`
    /// orders them).
    @Published private(set) var entries: [DownloadsEntry] = []
    /// Bytes the downloads take on disk; nil until measured.
    @Published private(set) var usedBytes: Int64?
    /// Free bytes on the device; nil when unknown.
    @Published private(set) var freeBytes: Int64?

    /// Downloads downloading, waiting or paused (the tab's badge).
    var activeCount: Int { entries.filter { $0.isActive && !isFailed($0) }.count }

    private var manager: PTTorrentDownloadManager { PTTorrentDownloadManager.shared() }

    /// Failed downloads the manager no longer lists, by media id.
    private var failed: [String: (download: PTTorrentDownload, reason: String?, folder: String?)] = [:]
    /// Ids being deleted: their stop (a « failed » status) is no failure.
    private var deleting: Set<String> = []
    /// When each download's progress was last saved, and at what value.
    private var lastSaves: [String: (progress: Double, date: Date)] = [:]
    private var refreshScheduled = false
    private var lastMeasure = Date.distantPast
    private var started = false
    private let saveQueue = DispatchQueue(label: "DownloadsStore.save", qos: .utility)

    private static let userPausedKey = "downloadsUserPaused"
    /// The file size, kept in the download's plist (`mediaMetadata`): a
    /// download reloaded paused knows it before the torrent's metadata.
    static let fileSizeKey = "downloadFileSize"

    private override init() {
        super.init()
    }

    // MARK: - Launch

    /// At launch (`AppDelegate`): listens to the manager, cleans the
    /// download directory, resumes what was running.
    func start() {
        guard !started else { return }
        started = true
        manager.add(self)
        removeOrphanFolders()
        resumeInterruptedDownloads()
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.willTerminateNotification] {
            center.addObserver(self, selector: #selector(saveAll), name: name, object: nil)
        }
        refreshNow()
        measureStorage()
    }

    /// The downloads paused when the app quit (the manager reloads every
    /// unfinished one paused) go on, unless the user had paused them.
    private func resumeInterruptedDownloads() {
        #if DEBUG
        // Fixtures are never resumed: they would start libtorrent on a fake magnet.
        if DownloadsDebug.isActive { return }
        #endif
        let userPaused = self.userPaused
        for download in manager.activeDownloads where download.downloadStatus == .paused {
            guard let id = Self.mediaID(of: download), !userPaused.contains(id) else { continue }
            print("[Downloads] resuming \(id) after a relaunch")
            download.resume()
        }
    }

    // MARK: - Rows

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Two refreshes a second at most: the engine reports every download
        // several times a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshNow()
        }
    }

    func refreshNow() {
        var seen = Set<String>()
        var rows: [DownloadsEntry] = []
        for download in manager.activeDownloads + manager.completedDownloads {
            guard let entry = entry(of: download), seen.insert(entry.id).inserted else { continue }
            rows.append(entry)
        }
        for (id, failure) in failed where !seen.contains(id) {
            guard var entry = entry(of: failure.download) else { continue }
            entry.phase = .failed(failure.reason)
            entry.bytesPerSecond = 0
            seen.insert(id)
            rows.append(entry)
        }
        if rows != entries { entries = rows }
        if Date().timeIntervalSince(lastMeasure) > 10 { measureStorage() }
    }

    private func entry(of download: PTTorrentDownload) -> DownloadsEntry? {
        let metadata = download.mediaMetadata
        guard let id = Self.mediaID(of: download) else { return nil }
        let title = metadata[MPMediaItemPropertyTitle] as? String ?? ""
        let kind: DownloadsEntry.Kind
        var artwork = metadata[MPMediaItemPropertyArtwork] as? String
        if let type = metadata[MPMediaItemPropertyMediaType] as? NSNumber,
           MPMediaType(rawValue: type.uintValue) == .episode {
            let show = metadata[MPMediaItemPropertyShow] as? [String: Any]
            kind = .episode(show: show?[MPMediaItemPropertyTitle] as? String ?? "",
                            season: metadata[MPMediaItemPropertySeason] as? Int ?? 0,
                            number: metadata[MPMediaItemPropertyEpisode] as? Int ?? 0)
            // The show's poster: every row has a poster of the same shape.
            if let poster = show?[MPMediaItemPropertyArtwork] as? String, !poster.isEmpty { artwork = poster }
        } else {
            kind = .movie
        }
        // The still: an episode's own picture, a movie's backdrop.
        let still = [metadata[MPMediaItemPropertyBackgroundArtwork] as? String,
                     metadata[MPMediaItemPropertyArtwork] as? String]
            .compactMap { $0 }.first { !$0.isEmpty }
        var entry = DownloadsEntry(id: id, kind: kind, title: title,
                                   artworkURL: artwork.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                                   stillURL: still.flatMap(URL.init(string:)),
                                   phase: Self.phase(of: download.downloadStatus),
                                   progress: Double(download.torrentStatus.totalProgress),
                                   bytesPerSecond: Int64(max(download.torrentStatus.downloadSpeed, 0)),
                                   totalBytes: Self.fileSize(of: download))
        if entry.phase == .finished { entry.progress = 1 }
        if entry.phase != .downloading { entry.bytesPerSecond = 0 }
        if let failure = failed[id] {
            entry.phase = .failed(failure.reason)
            entry.bytesPerSecond = 0
        }
        #if DEBUG
        DownloadsDebug.apply(to: &entry)
        #endif
        return entry
    }

    private static func phase(of status: PTTorrentDownloadStatus) -> DownloadsEntry.Phase {
        switch status {
        case .processing: return .waiting
        case .downloading: return .downloading
        case .paused: return .paused
        case .finished: return .finished
        case .failed: return .failed(nil)
        @unknown default: return .waiting
        }
    }

    /// The file's size: the engine's once it knows the torrent (or of the
    /// file on disk, finished), else the one saved with the download.
    private static func fileSize(of download: PTTorrentDownload) -> Int64? {
        let live = download.fileSize.longLongValue
        if live > 0, download.downloadStatus == .downloading || download.downloadStatus == .finished { return live }
        if let saved = download.mediaMetadata[fileSizeKey] as? NSNumber, saved.int64Value > 0 { return saved.int64Value }
        return live > 0 ? live : nil
    }

    static func mediaID(of download: PTTorrentDownload) -> String? {
        download.mediaMetadata[MPMediaItemPropertyPersistentID] as? String
    }

    private func isFailed(_ entry: DownloadsEntry) -> Bool {
        if case .failed = entry.phase { return true }
        return false
    }

    /// The download of a row: listed by the manager, or failed.
    func download(_ id: String) -> PTTorrentDownload? {
        (manager.activeDownloads + manager.completedDownloads).first { Self.mediaID(of: $0) == id } ?? failed[id]?.download
    }

    // MARK: - Actions

    func pause(_ id: String) {
        markUserPaused(id, true)
        #if DEBUG
        if DownloadsDebug.pause(id) { return refreshNow() }
        #endif
        guard let download = download(id), download.downloadStatus == .downloading else { return }
        download.pause()
        save(download)
        refreshNow()
    }

    func resume(_ id: String) {
        markUserPaused(id, false)
        #if DEBUG
        if DownloadsDebug.resume(id) { return refreshNow() }
        #endif
        guard let download = download(id), download.downloadStatus == .paused else { return }
        download.resume()
        refreshNow()
    }

    func pauseAll() {
        for entry in entries where entry.isRunning { pause(entry.id) }
    }

    func resumeAll() {
        for entry in entries where entry.phase == .paused { resume(entry.id) }
    }

    /// Plays a finished download from its file (no torrent).
    func play(_ id: String) {
        guard let download = download(id), download.downloadStatus == .finished else { return }
        let metadata = download.mediaMetadata
        guard let media: Media = Movie(metadata) ?? Episode(metadata) else { return }
        AppDelegate.shared.play(media, torrent: Torrent())
    }

    /// Stops the download if it runs and deletes its files; `completion`
    /// once the folder is gone (or after a few seconds).
    func delete(_ id: String, completion: (() -> Void)? = nil) {
        guard let download = download(id) else { completion?(); return }
        #if DEBUG
        DownloadsDebug.forget(id)
        #endif
        deleting.insert(id)
        markUserPaused(id, false)
        lastSaves[id] = nil
        let folder = download.savePath ?? failed[id]?.folder
        let sharesFolder = folder.map { Self.folderHoldsOtherDownloads($0, of: download) } ?? false
        switch download.downloadStatus {
        case .finished:
            manager.delete(download)
        case .failed:
            // Neither list has it: its files only.
            _ = download.delete()
        default:
            // Stops the torrent, deletes its folder (its own file only when
            // the folder holds another download's episode).
            manager.stop(download)
        }
        failed[id] = nil
        refreshNow()
        // libtorrent deletes a running torrent's files once its writes are
        // done: the folder is checked again, and removed if it is still
        // there and is this download's alone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if let folder, !sharesFolder, Self.isInsideDownloadDirectory(folder),
               FileManager.default.fileExists(atPath: folder) {
                try? FileManager.default.removeItem(atPath: folder)
            }
            self?.deleting.remove(id)
            self?.refreshNow()
            self?.measureStorage()
            completion?()
        }
    }

    /// Starts a failed download again, from its magnet, on the file it had.
    func retry(_ id: String) {
        #if DEBUG
        if DownloadsDebug.resume(id) { return refreshNow() }
        #endif
        guard let failure = failed[id] else { return }
        var metadata = failure.download.mediaMetadata
        guard let link = metadata["filePathOrLink"] as? String, !link.isEmpty else { return }
        failed[id] = nil
        markUserPaused(id, false)
        let stored = (metadata["selectedFileIndex"] as? NSNumber)?.intValue
        metadata["downloadStatus"] = nil
        metadata["progress"] = nil
        let fallback = PTTorrentStreamer.fileSelection(for: link)
        manager.startDownloading(fromFileOrMagnetLink: link, mediaMetadata: metadata) { names, sizes in
            if let stored, stored >= 0, stored < names.count { return Int32(stored) }
            return fallback(names, sizes)
        }
        refreshNow()
    }

    // MARK: - Space

    /// Measures the downloads' size and the free space, off the main thread:
    /// the bytes on disk of each download's folder (allocated, not the
    /// files' nominal size: a download in progress takes what it has).
    func measureStorage() {
        lastMeasure = Date()
        guard let directory = PTTorrentDownload.downloadDirectory() else { return }
        let folders = Set((manager.activeDownloads + manager.completedDownloads).compactMap(\.savePath)
                          + failed.values.compactMap(\.folder))
            .filter(Self.isInsideDownloadDirectory)
        #if DEBUG
        // The fixtures' files are sparse: what they would take.
        let simulated: Int64? = DownloadsDebug.isActive ? DownloadsDebug.simulatedUsedBytes : nil
        #else
        let simulated: Int64? = nil
        #endif
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let used = simulated ?? folders.reduce(Int64(0)) { $0 + FileManager.default.allocatedSize(atPath: $1) }
            let free = Self.freeSpace(at: directory)
            DispatchQueue.main.async {
                if self?.usedBytes != used { self?.usedBytes = used }
                if self?.freeBytes != free { self?.freeBytes = free }
            }
        }
    }

    static func freeSpace(at path: String) -> Int64? {
        // tvOS has no « important usage » capacity: the volume's free space.
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let capacity = values.volumeAvailableCapacity, capacity > 0 {
            return Int64(capacity)
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Before a new download: nil when `torrent` fits, else why it cannot.
    func spaceWarning(for torrent: Torrent) -> String? {
        guard let directory = PTTorrentDownload.downloadDirectory() else { return nil }
        return DownloadsText().spaceWarning(needed: torrent.streamedFileBytes ?? torrent.sizeInBytes,
                                            free: Self.freeSpace(at: directory))
    }

    // MARK: - Saving the progress

    private func saveIfNeeded(_ download: PTTorrentDownload) {
        guard let id = Self.mediaID(of: download), !deleting.contains(id) else { return }
        let progress = Double(download.torrentStatus.totalProgress)
        let last = lastSaves[id]
        guard DownloadsCatalog.shouldSave(progress: progress, lastSavedProgress: last?.progress,
                                          now: Date(), lastSaved: last?.date) else { return }
        save(download)
    }

    /// Writes the download's plist (progress, status, size) off the main thread.
    private func save(_ download: PTTorrentDownload) {
        guard let id = Self.mediaID(of: download), download.savePath != nil,
              download.downloadStatus != .failed else { return }
        let size = download.fileSize.longLongValue
        if size > 0, (download.mediaMetadata[Self.fileSizeKey] as? NSNumber)?.int64Value != size {
            var metadata = download.mediaMetadata
            metadata[Self.fileSizeKey] = NSNumber(value: size)
            download.mediaMetadata = metadata
        }
        lastSaves[id] = (Double(download.torrentStatus.totalProgress), Date())
        saveQueue.async { _ = download.save() }
    }

    /// Every unfinished download, now (the app leaves the foreground).
    @objc private func saveAll() {
        for download in manager.activeDownloads where download.downloadStatus != .processing {
            save(download)
        }
    }

    // MARK: - User-paused downloads

    private var userPaused: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.userPausedKey) ?? [])
    }

    private func markUserPaused(_ id: String, _ paused: Bool) {
        var set = userPaused
        let changed = paused ? set.insert(id).inserted : set.remove(id) != nil
        guard changed else { return }
        UserDefaults.standard.set(Array(set).sorted(), forKey: Self.userPausedKey)
    }

    #if DEBUG
    /// The fixtures (`DownloadsDebug`) are never resumed at launch.
    func noteFixturesUserPaused(_ ids: [String]) {
        for id in ids { markUserPaused(id, true) }
    }
    #endif

    // MARK: - Folders

    /// Folders of the download directory that hold no download and belong
    /// to none: deleted, in the background.
    private func removeOrphanFolders() {
        guard let directory = PTTorrentDownload.downloadDirectory() else { return }
        let owned = Set((manager.activeDownloads + manager.completedDownloads).compactMap {
            $0.savePath.map { ($0 as NSString).lastPathComponent }
        })
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
            let folders: [DownloadsCatalog.Folder] = names.map { name in
                let path = (directory as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDirectory)
                let children = isDirectory.boolValue ? ((try? fm.contentsOfDirectory(atPath: path)) ?? []) : []
                let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
                return .init(name: name, isDirectory: isDirectory.boolValue,
                             hasMetadata: children.contains(where: DownloadsCatalog.isMetadataFile),
                             modified: modified)
            }
            for name in DownloadsCatalog.orphans(folders, owned: owned, now: Date()) {
                let path = (directory as NSString).appendingPathComponent(name)
                let size = fm.allocatedSize(atPath: path)
                try? fm.removeItem(atPath: path)
                print("[Downloads] removed an orphan folder (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
            }
        }
    }

    /// Whether `folder` holds the plist of another download than `download`
    /// (two episodes of one season pack, from before each got its own folder).
    private static func folderHoldsOtherDownloads(_ folder: String, of download: PTTorrentDownload) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let index = (download.mediaMetadata["selectedFileIndex"] as? NSNumber).map { "Metadata-file-\($0.intValue).plist" }
        return names.contains { DownloadsCatalog.isMetadataFile($0) && $0 != index && $0 != "Metadata.plist" }
    }

    /// Whether `folder` is a child of the download directory: never the
    /// directory itself, never anything else.
    private static func isInsideDownloadDirectory(_ folder: String) -> Bool {
        guard let directory = PTTorrentDownload.downloadDirectory() else { return false }
        let parent = (URL(fileURLWithPath: folder).standardizedFileURL.deletingLastPathComponent().path as NSString).standardizingPath
        return parent == (URL(fileURLWithPath: directory).standardizedFileURL.path as NSString).standardizingPath
    }

    // MARK: - PTTorrentDownloadManagerListener

    func torrentStatusDidChange(_ torrentStatus: PTTorrentStatus, for download: PTTorrentDownload) {
        onMain { [weak self] in
            self?.saveIfNeeded(download)
            self?.scheduleRefresh()
        }
    }

    func downloadStatusDidChange(_ downloadStatus: PTTorrentDownloadStatus, for download: PTTorrentDownload) {
        onMain { [weak self] in
            guard let self else { return }
            // Coalesced: a failure reports its status, then the error
            // (`downloadDidFail`), which lists it again as failed.
            self.scheduleRefresh()
            if downloadStatus == .finished {
                self.lastSaves[Self.mediaID(of: download) ?? ""] = nil
                self.measureStorage()
            }
        }
    }

    func downloadDidFail(_ download: PTTorrentDownload, withError error: Error) {
        onMain { [weak self] in
            guard let self, let id = Self.mediaID(of: download), !self.deleting.contains(id) else { return }
            print("[Downloads] \(id) failed: \(error.localizedDescription)")
            // In the UI's language and short: the engine's own sentence is
            // English.
            let failure = Self.failure(of: error, download: download)
            let text = DownloadsText()
            self.failed[id] = (download, text.failureReason(failure), download.savePath)
            self.refreshNow()
            let alert = UIAlertController(title: "Download Failed".localized, message: text.failureSentence(failure) + ".",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK".localized, style: .default, handler: nil))
            alert.show(animated: true)
        }
    }

    /// The failure in the app's terms, as streaming reads it (`StreamFailure`).
    static func failure(of error: Error, download: PTTorrentDownload) -> DownloadsFailure {
        switch StreamFailure(error, streamer: download) {
        case .notEnoughSpace:
            let free = PTTorrentDownload.downloadDirectory().flatMap(freeSpace(at:))
            return .notEnoughSpace(bytesToFree: DownloadsFailure.bytesToFree(fileSize: fileSize(of: download), free: free))
        case .notEnoughSpaceForBoundedStorage(let bytes):
            return .notEnoughSpace(bytesToFree: bytes > 0 ? bytes : nil)
        case .fileError:
            return .fileError
        case .episodeNotInTorrent:
            return .episodeNotInTorrent
        case .other:
            let isEngines = (error as NSError).domain == PTTorrentStreamerError.errorDomain
            return .other(isEngines ? nil : error.localizedDescription)
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

#if DEBUG
/// `-PTDebugDownloadFixtures YES`: before the download manager loads, the
/// download directory gets made-up downloads (screenshots, UI tests): a
/// movie and an episode downloaded, a movie and an episode paused, a 4K
/// movie paused at its start, one « downloading » and one failed. Their
/// files are sparse (they take no space), their magnets fake: they are
/// never resumed. Pause, resume and try again only change their state
/// here; Delete deletes their folders for real.
enum DownloadsDebug {
    /// `YES`: the fixtures; `empty`: none (the earlier ones removed), for
    /// the empty page.
    static var isActive: Bool {
        guard let value = UserDefaults.standard.string(forKey: "PTDebugDownloadFixtures") else { return false }
        return value != "NO" && value != "0"
    }
    private static var writesFixtures: Bool { UserDefaults.standard.string(forKey: "PTDebugDownloadFixtures") != "empty" }

    struct Simulation {
        var phase: DownloadsEntry.Phase
        var progress: Double
        var bytesPerSecond: Int64
    }

    /// The fixtures' made-up states, by media id.
    private(set) static var simulated: [String: Simulation] = [:]
    private(set) static var fixtureIDs: Set<String> = []

    private struct Fixture {
        let id: String
        let title: String
        let poster: String
        let show: (id: String, title: String, poster: String)?
        let season: Int
        let episode: Int
        let size: Int64
        let progress: Double
        let finished: Bool
        let simulation: Simulation?
    }

    private static func poster(_ imdb: String) -> String { "https://images.metahub.space/poster/medium/\(imdb)/img" }
    private static func backdrop(_ imdb: String) -> String { "https://images.metahub.space/background/medium/\(imdb)/img" }

    private static var fixtures: [Fixture] {
        let gb: Int64 = 1_000_000_000
        return [
            Fixture(id: "tt7526136", title: "Heart of the Beast", poster: poster("tt7526136"), show: nil, season: 0, episode: 0,
                    size: 2_640_000_000, progress: 1, finished: true, simulation: nil),
            Fixture(id: "tt0077651", title: "Halloween", poster: poster("tt0077651"), show: nil, season: 0, episode: 0,
                    size: 2_410_000_000, progress: 0.42, finished: false,
                    simulation: Simulation(phase: .downloading, progress: 0.42, bytesPerSecond: 3_100_000)),
            Fixture(id: "tt35538033", title: "Resident Evil", poster: poster("tt35538033"), show: nil, season: 0, episode: 0,
                    size: 18_400_000_000, progress: 0.08, finished: false, simulation: nil),
            Fixture(id: "tt38515310", title: "A Dog's Perfect Christmas", poster: poster("tt38515310"), show: nil, season: 0, episode: 0,
                    size: 1_900_000_000, progress: 0.17, finished: false,
                    simulation: Simulation(phase: .failed(DownloadsText().failureReason(.notEnoughSpace(bytesToFree: 1_900_000_000))),
                                           progress: 0.17, bytesPerSecond: 0)),
            Fixture(id: "tt27995113-1-3", title: "Hunted", poster: "",
                    show: ("tt27995113", "Black Doves", poster("tt27995113")), season: 1, episode: 3,
                    size: 1 * gb + 210_000_000, progress: 1, finished: true, simulation: nil),
            Fixture(id: "tt31510819-1-5", title: "Out of the Frying Pan", poster: "",
                    show: ("tt31510819", "MobLand", poster("tt31510819")), season: 1, episode: 5,
                    size: 1 * gb + 640_000_000, progress: 0.73, finished: false, simulation: nil),
        ]
    }

    /// Writes the fixtures (AppDelegate, before anything uses the manager).
    static func prepareAtLaunch() {
        guard isActive, let directory = PTTorrentDownload.downloadDirectory() else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] where name.hasPrefix("Fixture ") {
            try? fm.removeItem(atPath: (directory as NSString).appendingPathComponent(name))
        }
        guard writesFixtures else { return }
        for (index, fixture) in fixtures.enumerated() {
            let folder = (directory as NSString).appendingPathComponent("Fixture \(index) \(fixture.title)")
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let file = fixture.title.replacingOccurrences(of: " ", with: ".") + ".2026.1080p.WEB.mkv"
            let path = (folder as NSString).appendingPathComponent(file)
            fm.createFile(atPath: path, contents: nil)
            // Sparse: the size is the file's, the space taken nothing.
            if let handle = FileHandle(forWritingAtPath: path) {
                try? handle.truncate(atOffset: UInt64(fixture.size))
                try? handle.close()
            }
            var metadata: [String: Any]
            if let show = fixture.show {
                let showMetadata: [String: Any] = [
                    MPMediaItemPropertyTitle: show.title,
                    MPMediaItemPropertyMediaType: NSNumber(value: MPMediaType.tvShow.rawValue),
                    MPMediaItemPropertyPersistentID: show.id,
                    MPMediaItemPropertyArtwork: show.poster,
                    MPMediaItemPropertyBackgroundArtwork: backdrop(show.id),
                    MPMediaItemPropertySummary: "",
                ]
                metadata = [
                    MPMediaItemPropertyTitle: fixture.title,
                    MPMediaItemPropertyMediaType: NSNumber(value: MPMediaType.episode.rawValue),
                    MPMediaItemPropertyPersistentID: fixture.id,
                    MPMediaItemPropertyArtwork: backdrop(show.id),
                    MPMediaItemPropertyBackgroundArtwork: backdrop(show.id),
                    MPMediaItemPropertySummary: "",
                    MPMediaItemPropertyShow: showMetadata,
                    MPMediaItemPropertyEpisode: fixture.episode,
                    MPMediaItemPropertySeason: fixture.season,
                ]
            } else {
                metadata = [
                    MPMediaItemPropertyTitle: fixture.title,
                    MPMediaItemPropertyMediaType: NSNumber(value: MPMediaType.movie.rawValue),
                    MPMediaItemPropertyPersistentID: fixture.id,
                    MPMediaItemPropertyArtwork: fixture.poster,
                    MPMediaItemPropertyBackgroundArtwork: backdrop(fixture.id),
                    MPMediaItemPropertySummary: "",
                ]
            }
            metadata["filePathOrLink"] = "magnet:?xt=urn:btih:" + String(repeating: "0", count: 39) + String(index) + "&dn=fixture"
            metadata["selectedFileIndex"] = NSNumber(value: 0)
            metadata["selectedFilePath"] = file
            metadata["downloadStatus"] = NSNumber(value: fixture.finished ? PTTorrentDownloadStatus.finished.rawValue : PTTorrentDownloadStatus.paused.rawValue)
            metadata["progress"] = NSNumber(value: Float(fixture.progress))
            metadata[DownloadsStore.fileSizeKey] = NSNumber(value: fixture.size)
            (metadata as NSDictionary).write(toFile: (folder as NSString).appendingPathComponent("Metadata-file-0.plist"), atomically: true)
            if let simulation = fixture.simulation { simulated[fixture.id] = simulation }
        }
        fixtureIDs = Set(fixtures.map(\.id))
        DownloadsStore.shared.noteFixturesUserPaused(Array(fixtureIDs))
        print("[Downloads] \(fixtures.count) fixtures written")
    }

    /// What the fixtures still listed would take on disk.
    static var simulatedUsedBytes: Int64 {
        let listed = Set(DownloadsStore.shared.entries.map(\.id))
        return fixtures.filter { listed.contains($0.id) }
            .reduce(Int64(0)) { $0 + Int64(Double($1.size) * (simulated[$1.id]?.progress ?? $1.progress)) }
    }

    static func apply(to entry: inout DownloadsEntry) {
        guard let simulation = simulated[entry.id] else { return }
        entry.phase = simulation.phase
        entry.progress = simulation.progress
        entry.bytesPerSecond = simulation.bytesPerSecond
    }

    /// A fixture paused: true (the engine is left alone).
    static func pause(_ id: String) -> Bool {
        guard fixtureIDs.contains(id) else { return false }
        if var simulation = simulated[id] {
            simulation.phase = .paused
            simulation.bytesPerSecond = 0
            simulated[id] = simulation
        }
        return true
    }

    /// A fixture resumed (or tried again): « downloading », made up.
    static func resume(_ id: String) -> Bool {
        guard fixtureIDs.contains(id) else { return false }
        let progress = simulated[id]?.progress ?? fixtures.first { $0.id == id }?.progress ?? 0
        simulated[id] = Simulation(phase: .downloading, progress: progress, bytesPerSecond: 2_400_000)
        return true
    }

    static func forget(_ id: String) {
        simulated[id] = nil
    }
}
#endif
