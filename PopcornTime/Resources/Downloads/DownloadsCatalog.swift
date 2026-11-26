// DownloadsCatalog.swift — what the Apple TV's Downloads page says about each
// download: its title, one status line, the order of the rows and the
// folders of the download directory nothing owns. Pure values and functions
// (no PopcornTorrent, no UIKit): the macOS unit tests check them.

import Foundation

/// One row of the Downloads page.
struct DownloadsEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case movie
        /// `show`: the show's title; `title`: the episode's own.
        case episode(show: String, season: Int, number: Int)
    }

    enum Phase: Equatable {
        /// Looking for peers or for the torrent's file list (« Processing »).
        case waiting
        case downloading
        case paused
        /// The engine's reason, when it gave one.
        case failed(String?)
        case finished
    }

    /// The media id (`MPMediaItemPropertyPersistentID`).
    let id: String
    var kind: Kind
    var title: String
    var artworkURL: URL?
    var phase: Phase
    /// 0…1.
    var progress: Double
    /// Download rate, bytes per second (0 when unknown or stalled).
    var bytesPerSecond: Int64
    /// The file's size, when known.
    var totalBytes: Int64?

    /// Downloading, waiting, paused or failed: the « Downloading » section.
    var isActive: Bool { phase != .finished }

    /// Downloading: what Pause All pauses (one still looking for its
    /// sources has nothing to pause yet).
    var isRunning: Bool { phase == .downloading }
}

/// Texts of the Downloads page. `localize` reads Localizable.strings (the
/// tests pass their own); numbers and sizes follow `locale`.
struct DownloadsText {
    var locale: Locale = .current
    var localize: (String) -> String = { Bundle.main.localizedString(forKey: $0, value: nil, table: nil) }

    // MARK: Row

    /// The row's first line: the movie, or the show an episode belongs to.
    func title(of entry: DownloadsEntry) -> String {
        switch entry.kind {
        case .movie: return entry.title
        case .episode(let show, _, _): return show.isEmpty ? entry.title : show
        }
    }

    /// Under an episode's show: « S1 E2 · Title »; nil for a movie.
    func subtitle(of entry: DownloadsEntry) -> String? {
        guard case .episode(let show, let season, let number) = entry.kind else { return nil }
        let code = String(format: localize("Downloads.Episode"), integer(season), integer(number))
        guard !show.isEmpty, !entry.title.isEmpty else { return code }
        return code + " · " + entry.title
    }

    /// One line that says where the download is, only with what is known:
    /// « 42 % · 3.1 MB/s · about 12 min left · 1.1 GB of 2.6 GB »,
    /// « Paused · 42 % · 1.1 GB of 2.6 GB », « Failed — reason », « 2.6 GB ».
    func status(of entry: DownloadsEntry) -> String {
        switch entry.phase {
        case .waiting:
            let waiting = localize("Downloads.Status.Waiting")
            return entry.progress > 0 ? join([waiting, percent(entry.progress)]) : waiting
        case .downloading:
            var parts = [percent(entry.progress)]
            if entry.bytesPerSecond > 0 {
                parts.append(String(format: localize("Downloads.Status.Speed"), bytes(entry.bytesPerSecond)))
                if let left = timeLeft(of: entry) {
                    parts.append(String(format: localize("Downloads.Status.TimeLeft"), left))
                }
            }
            if let amounts = amounts(of: entry) { parts.append(amounts) }
            return join(parts)
        case .paused:
            var parts = [localize("Downloads.Status.Paused"), percent(entry.progress)]
            if let amounts = amounts(of: entry) { parts.append(amounts) }
            return join(parts)
        case .failed(let reason):
            let failed = localize("Downloads.Status.Failed")
            guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return failed }
            return failed + " — " + reason
        case .finished:
            return entry.totalBytes.map(bytes) ?? ""
        }
    }

    /// « 1.1 GB of 2.6 GB », when the size is known.
    func amounts(of entry: DownloadsEntry) -> String? {
        guard let total = entry.totalBytes, total > 0 else { return nil }
        let done = Int64((Double(total) * min(max(entry.progress, 0), 1)).rounded(.down))
        return String(format: localize("Downloads.Status.Of"), bytes(done), bytes(total))
    }

    /// The time left at the current rate, « 12 min » / « 1 h 5 min »; nil
    /// when the size or the rate is unknown, or for more than two days
    /// (a rate that low says nothing useful).
    func timeLeft(of entry: DownloadsEntry) -> String? {
        guard let seconds = DownloadsCatalog.secondsLeft(of: entry) else { return nil }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        // Under a minute still says « 1 min », not « 0 min ».
        return formatter.string(from: max(seconds, 60))
    }

    /// « 42 % » (French) / « 42% » (English). Rounded down: 99.6 % of a file
    /// is not « 100 % » while it still downloads.
    func percent(_ progress: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.locale = locale
        formatter.maximumFractionDigits = 0
        // The epsilon: 0.08 stored as a Float reads 0.0799…, not « 7 % ».
        let value = (min(max(progress, 0), 1) * 100 + 0.001).rounded(.down) / 100
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value * 100)) %"
    }

    func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: count)
    }

    // MARK: Page

    /// Under the title: « Downloads take 3.4 GB · 21 GB free » — the bytes
    /// on disk of the downloads' folders (`DownloadsStore.measureStorage`).
    func storage(used: Int64, free: Int64?) -> String {
        guard let free else { return String(format: localize("Downloads.Storage.Used"), bytes(used)) }
        return String(format: localize("Downloads.Storage"), bytes(used), bytes(free))
    }

    /// Before a download starts: nil when it fits, else why it cannot
    /// (« This download needs 18.4 GB; 6.2 GB is free on this Apple TV. »).
    func spaceWarning(needed: Int64?, free: Int64?) -> String? {
        guard let needed, let free, needed > 0, !DownloadsCatalog.fits(needed: needed, free: free) else { return nil }
        return String(format: localize("Downloads.NoSpace.Message"), bytes(needed), bytes(free))
    }

    /// Why a download stopped, short, in the UI's language (the engine's
    /// own sentences are English and long): « not enough space (1.9 GB to
    /// free) », « this episode is not in the release »…
    func failureReason(_ failure: DownloadsFailure) -> String {
        switch failure {
        case .notEnoughSpace(let bytesToFree):
            guard let bytesToFree, bytesToFree > 0 else { return localize("Downloads.Failure.NoSpace") }
            return String(format: localize("Downloads.Failure.NoSpaceAmount"), bytes(bytesToFree))
        case .fileError: return localize("Downloads.Failure.File")
        case .episodeNotInTorrent: return localize("Downloads.Failure.NoEpisode")
        case .other(let description):
            // A system error is already in the UI's language; the engine's are not.
            return description ?? localize("Downloads.Failure.Other")
        }
    }

    /// The failure as one sentence, for the alert: the reason with a capital.
    func failureSentence(_ failure: DownloadsFailure) -> String {
        let reason = failureReason(failure)
        return reason.prefix(1).uppercased(with: locale) + reason.dropFirst()
    }

    private func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .none
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func join(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Why a download failed (from PopcornTorrent's error codes, through the
/// app's `StreamFailure`).
enum DownloadsFailure: Equatable {
    /// The file does not fit; what to free, when known.
    case notEnoughSpace(bytesToFree: Int64?)
    case fileError
    /// A season pack without the episode asked for.
    case episodeNotInTorrent
    /// Anything else: a system error's own (localized) description, nil for
    /// the engine's (English).
    case other(String?)

    /// What to free for `fileSize` bytes to fit in `free`, with the margin
    /// `DownloadsCatalog.fits` keeps; nil when unknown.
    static func bytesToFree(fileSize: Int64?, free: Int64?) -> Int64? {
        guard let fileSize, let free, fileSize > 0 else { return nil }
        let missing = fileSize + DownloadsCatalog.spaceMargin - free
        return missing > 0 ? missing : nil
    }
}

enum DownloadsCatalog {

    // MARK: Sections

    /// The rows of each section. Downloading: the running ones first, then
    /// the paused, then the failed, each by title; downloaded: by title,
    /// a show's episodes together in season and episode order.
    static func sections(_ entries: [DownloadsEntry]) -> (active: [DownloadsEntry], finished: [DownloadsEntry]) {
        let active = entries.filter(\.isActive).sorted { lhs, rhs in
            let (l, r) = (rank(lhs.phase), rank(rhs.phase))
            return l != r ? l < r : ordered(lhs, rhs)
        }
        let finished = entries.filter { !$0.isActive }.sorted(by: ordered)
        return (active, finished)
    }

    private static func rank(_ phase: DownloadsEntry.Phase) -> Int {
        switch phase {
        case .downloading: return 0
        case .waiting: return 1
        case .paused: return 2
        case .failed: return 3
        case .finished: return 4
        }
    }

    /// By the row's title (the show for an episode), then season, episode.
    private static func ordered(_ lhs: DownloadsEntry, _ rhs: DownloadsEntry) -> Bool {
        let (l, r) = (sortKey(lhs), sortKey(rhs))
        let titles = l.title.localizedStandardCompare(r.title)
        if titles != .orderedSame { return titles == .orderedAscending }
        if l.season != r.season { return l.season < r.season }
        if l.number != r.number { return l.number < r.number }
        return lhs.id < rhs.id
    }

    private static func sortKey(_ entry: DownloadsEntry) -> (title: String, season: Int, number: Int) {
        switch entry.kind {
        case .movie: return (entry.title, 0, 0)
        case .episode(let show, let season, let number): return (show.isEmpty ? entry.title : show, season, number)
        }
    }

    // MARK: Time and space

    /// Seconds left at the current rate; nil when unknown or over two days.
    static func secondsLeft(of entry: DownloadsEntry) -> TimeInterval? {
        guard entry.bytesPerSecond > 0, let total = entry.totalBytes, total > 0 else { return nil }
        let left = Double(total) * (1 - min(max(entry.progress, 0), 1))
        let seconds = left / Double(entry.bytesPerSecond)
        guard seconds.isFinite, seconds <= 2 * 24 * 3600 else { return nil }
        return seconds
    }

    /// Whether `needed` bytes fit in `free`, with room left for the system
    /// and the app (a full Apple TV fails every write, the torrent's too).
    static func fits(needed: Int64, free: Int64) -> Bool {
        needed + spaceMargin <= free
    }

    /// What a download leaves free at the least.
    static let spaceMargin: Int64 = 500 * 1_000_000

    /// Whether a progress change is worth saving to the download's plist:
    /// every 5 % (`step`), or `interval` seconds after the last save.
    static func shouldSave(progress: Double, lastSavedProgress: Double?, now: Date, lastSaved: Date?,
                           step: Double = 0.05, interval: TimeInterval = 30) -> Bool {
        guard let lastSavedProgress, let lastSaved else { return true }
        // The epsilon: 0.06 − 0.01 is 0.0499… in binary.
        return abs(progress - lastSavedProgress) >= step - 1e-9 || now.timeIntervalSince(lastSaved) >= interval
    }

    // MARK: Orphan folders

    /// A child of the download directory.
    struct Folder: Equatable {
        let name: String
        let isDirectory: Bool
        /// It holds a `Metadata*.plist` (a download the manager lists).
        let hasMetadata: Bool
        let modified: Date
    }

    /// The folders of the download directory no download owns: no plist in
    /// them (a download stopped while its magnet resolved, a crash between
    /// the first pieces and the first save), not the folder of any download
    /// in progress (`owned`), untouched for `minimumAge` — a download that
    /// just started writes its plist within seconds.
    static func orphans(_ folders: [Folder], owned: Set<String>, now: Date,
                        minimumAge: TimeInterval = 10 * 60) -> [String] {
        folders.filter { folder in
            folder.isDirectory && !folder.hasMetadata && !owned.contains(folder.name)
                && !folder.name.hasPrefix(".") && now.timeIntervalSince(folder.modified) >= minimumAge
        }.map(\.name)
    }

    /// Whether a file name is a download's plist (`Metadata-file-<n>.plist`,
    /// or `Metadata.plist` of older versions).
    static func isMetadataFile(_ name: String) -> Bool {
        name.hasPrefix("Metadata") && (name as NSString).pathExtension == "plist"
    }
}
