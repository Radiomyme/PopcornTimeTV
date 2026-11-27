import Foundation
import PopcornKit
import PopcornTorrent

// The OpenSubtitles moviehash of the file being played. The search at
// Play (`SubtitleSearch`, by imdb id) lists every subtitle of the title,
// and the players start with the best one per language (the plain score,
// refined by the file's release name and length: `SubtitleMatching`).
// Once the first and the last 64 KiB of the file are on disk — the head
// comes first, the streamer fetches the tail early (MKV keyframe index, MP4
// moov) and bounded storage pins the head — this computes the file's hash
// and asks OpenSubtitles for the subtitles made for, or linked to, that
// exact file. Its rows of the title played win their language: the remux
// replaces the file it serves (`RemuxPlayback.applyMovieHashMatches`), the
// overlay switches (`SubtitleCueController.applyMovieHashMatches`). The
// automatic sync (`SubtitleAutoSync`) stays the safety net for what is
// still off. The VLC players do not look the hash up: switching the slave
// VLC already shows is not worth its risks; one started after a lookup of
// the same file found rows (a hand-off from AVPlayer, a replay) offers the
// files they found (`pick(_:forFile:)`), as its next load.

/// The moviehash lookup of one playback (see the top of the file).
/// `start` / `stop` and `onMatches` on the main queue.
final class SubtitleHashLookup {

    /// The title played: the hash rows of other titles are dropped.
    struct Title: Equatable {
        var imdbId: String?
        var showImdbId: String?
        var season: Int?
        var episode: Int?

        init(imdbId: String? = nil, showImdbId: String? = nil, season: Int? = nil, episode: Int? = nil) {
            self.imdbId = imdbId
            self.showImdbId = showImdbId
            self.season = season
            self.episode = episode
        }

        /// A movie by its imdb id; an episode by its show's, season and
        /// episode. nil: nothing to recognise the rows by.
        init?(media: Media?) {
            if let episode = media as? Episode {
                guard let show = episode.show?.id, show.hasPrefix("tt") else { return nil }
                self.init(showImdbId: show, season: episode.season, episode: episode.episode)
            } else if let id = media?.id, id.hasPrefix("tt") {
                self.init(imdbId: id)
            } else {
                return nil
            }
        }

        func rows(of all: [Subtitle]) -> [Subtitle] {
            SubtitleMatching.rowsForTitle(all, imdbId: imdbId, showImdbId: showImdbId, season: season, episode: episode)
        }
    }

    /// The moviehash search (default: `SubtitlesManager`, main-queue completion).
    typealias Search = (_ hash: String, _ fileSize: Int64, _ completion: @escaping ([Subtitle], NSError?) -> Void) -> Void

    /// How often the ends of the file are looked for (s).
    static var pollInterval: TimeInterval = 1

    let file: URL
    let title: Title
    /// The rows of the title (non-empty), once, on the main queue.
    var onMatches: (([Subtitle]) -> Void)?

    private let fileSize: () -> Int64
    private let isRangeOnDisk: (_ offset: Int64, _ length: Int64) -> Bool
    private let search: Search
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "subtitles.moviehash", qos: .utility)
    // Queue state.
    private var timer: DispatchSourceTimer?
    private var headSum: UInt64?
    private var isDone = false

    /// Answers of the moviehash search by "hash/size", for the life of the
    /// app: an item rebuilt, a replay or another route of the same file
    /// does not ask again.
    private static var answers: [String: [Subtitle]] = [:]
    /// The title's rows found for a file (its path), for the life of the app.
    private static var matchesByFile: [String: [Subtitle]] = [:]
    private static let answersLock = NSLock()

    /// The moviehash rows a lookup of `file` found so far (empty: none, or
    /// not looked up yet).
    static func knownMatches(forFile file: URL) -> [Subtitle] {
        answersLock.withLock { matchesByFile[file.standardizedFileURL.path] ?? [] }
    }

    /// `list` with each language's row picked for `file` (its release names
    /// and the moviehash rows a lookup of it found: `SubtitleMatching`), for
    /// a player that loads a subtitle once and does not look the hash up
    /// itself (VLC). `file` nil: `list` as it is.
    static func pick(_ list: [Subtitle], forFile file: URL?) -> [Subtitle] {
        guard let file, !list.isEmpty else { return list }
        return SubtitleMatching.choose(list, file: SubtitleFileContext(releaseNames: SubtitleFileContext.releaseNames(ofFile: file)),
                                       hashRows: knownMatches(forFile: file))
    }

    /// - Parameters:
    ///   - fileSize: the file's final size (the torrent's), ≤ 0 while unknown.
    ///   - isRangeOnDisk: whether `length` bytes at `offset` are on disk now.
    init(file: URL, title: Title, fileSize: @escaping () -> Int64,
         isRangeOnDisk: @escaping (_ offset: Int64, _ length: Int64) -> Bool,
         search: @escaping Search = { hash, size, completion in
             SubtitlesManager.shared.search(movieHash: hash, fileSize: size, completion: completion)
         },
         log: @escaping (String) -> Void = { print($0) }) {
        self.file = file
        self.title = title
        self.fileSize = fileSize
        self.isRangeOnDisk = isRangeOnDisk
        self.search = search
        self.log = log
    }

    /// The lookup of `file` played from `streamer` (nil: a local file,
    /// whole on disk), nil when `media` gives nothing to recognise the
    /// title's rows by.
    static func make(file: URL, streamer: PTTorrentStreamer?, media: Media?) -> SubtitleHashLookup? {
        guard let title = Title(media: media) else { return nil }
        #if DEBUG
        // The bench (`-PTDebugNoSubtitleSearch YES`, and its made-up show):
        // no OpenSubtitles request leaves the device, as `SubtitleSearch`.
        if UserDefaults.standard.bool(forKey: "PTDebugNoSubtitleSearch") || title.showImdbId == EpisodeSourceResolver.debugShowID {
            return nil
        }
        #endif
        guard let streamer else {
            let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
            return SubtitleHashLookup(file: file, title: title, fileSize: { size }, isRangeOnDisk: { _, _ in true })
        }
        return SubtitleHashLookup(file: file, title: title,
                                  fileSize: { [weak streamer] in streamer?.fileSize.longLongValue ?? 0 },
                                  isRangeOnDisk: { [weak streamer] offset, length in
                                      streamer?.isRangeAvailable(offset, length: length) ?? false
                                  })
    }

    /// Looks for the file's ends every `pollInterval` until the hash is
    /// known and searched, or `stop`.
    func start() {
        queue.async { [self] in
            guard timer == nil, !isDone else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(200))
            source.setEventHandler { [weak self] in self?.poll() }
            timer = source
            source.resume()
        }
    }

    /// Nothing more is looked for nor delivered.
    func stop() {
        queue.async { [self] in
            isDone = true
            timer?.cancel()
            timer = nil
        }
        onMatches = nil
    }

    /// Runs one poll now (tests).
    func pollNow() {
        queue.sync { poll() }
    }

    // MARK: Queue

    private func poll() {
        guard !isDone else { return }
        let size = fileSize()
        let chunk = Int64(OpenSubtitlesHash.chunkSize)
        guard size >= 2 * chunk else {
            if size > 0 { finish("[Subtitles] moviehash: the file is too small (\(size) bytes)") }
            return
        }
        // The head's sum is kept as soon as it is read: bounded storage may
        // delete what was played before the tail arrives.
        if headSum == nil, isRangeOnDisk(0, chunk), let head = OpenSubtitlesHash.readChunk(of: file, at: 0) {
            headSum = OpenSubtitlesHash.sum(of: head)
        }
        let tailOffset = OpenSubtitlesHash.tailOffset(fileSize: size)
        guard let headSum, isRangeOnDisk(tailOffset, chunk),
              let tail = OpenSubtitlesHash.readChunk(of: file, at: tailOffset),
              let tailSum = OpenSubtitlesHash.sum(of: tail),
              let hash = OpenSubtitlesHash.hash(fileSize: size, headSum: headSum, tailSum: tailSum) else { return }
        isDone = true
        timer?.cancel()
        timer = nil
        let cacheKey = "\(hash)/\(size)"
        if let known = Self.answersLock.withLock({ Self.answers[cacheKey] }) {
            deliver(hash: hash, size: size, rows: known)
            return
        }
        search(hash, size) { [weak self] rows, error in
            guard let self else { return }
            if let error {
                self.log("[Subtitles] moviehash \(hash) size \(size): search failed (\(error.localizedDescription))")
                return
            }
            Self.answersLock.withLock { Self.answers[cacheKey] = rows }
            self.queue.async { self.deliver(hash: hash, size: size, rows: rows) }
        }
    }

    private func finish(_ message: String) {
        isDone = true
        timer?.cancel()
        timer = nil
        log(message)
    }

    private func deliver(hash: String, size: Int64, rows: [Subtitle]) {
        let mine = title.rows(of: rows)
        log(Self.summary(hash: hash, size: size, allRows: rows.count, titleRows: mine))
        guard !mine.isEmpty else { return }
        Self.answersLock.withLock { Self.matchesByFile[file.standardizedFileURL.path] = mine }
        DispatchQueue.main.async { [weak self] in
            self?.onMatches?(mine)
        }
    }

    /// "[Subtitles] moviehash 8e245d9679d31e12 size 12909756: 3 rows for
    /// this title, en → 'breakdance' (hash match)": the row each language
    /// would take among the hash rows alone.
    static func summary(hash: String, size: Int64, allRows: Int, titleRows: [Subtitle]) -> String {
        var line = "[Subtitles] moviehash \(hash) size \(size): \(titleRows.count) row\(titleRows.count == 1 ? "" : "s") for this title"
        if allRows > titleRows.count { line += " (\(allRows - titleRows.count) of other titles ignored)" }
        var languages: [String] = []
        for row in titleRows where !languages.contains(row.ISO639) { languages.append(row.ISO639) }
        let picks = languages.compactMap { code -> String? in
            guard let best = SubtitleMatching.rank(titleRows.filter { $0.ISO639 == code }, file: SubtitleFileContext()).first else { return nil }
            return "\(code) → '\(best.releaseName ?? best.fileName ?? "?")' (hash match)"
        }
        return picks.isEmpty ? line : line + ", " + picks.joined(separator: ", ")
    }
}
