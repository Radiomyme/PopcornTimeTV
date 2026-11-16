import Foundation

/// The OpenSubtitles search of the title being played, shared by the play
/// flows and every player.
///
/// Before, the Apple TV and the Mac searched the subtitles FIRST and only
/// then started the stream: every playback waited for OpenSubtitles before
/// contacting a single peer — up to the session's 60 s when it did not
/// answer — and each player searched again when the first answer was empty.
/// Now the play flow starts the search (`prefetch`) and the stream together,
/// and the players ask here:
///
/// - `answer(for:)`: the list when the search has answered (possibly empty)
///   — a player that starts after it shows it at once, with no wait;
/// - `search(for:completion:)`: the list once it is known (a player that
///   can show it at any time: VLC, the overlay of the direct AVPlayer path);
/// - `search(for:waitingAtMost:update:)`: for a player that has to hold its
///   start for the list (the remux lists subtitles in the master playlist
///   AVPlayer reads once): the list, or — `hold` seconds after the search
///   BEGAN, not after this call — an empty one to start with, then the real
///   one when it comes.
///
/// One request per title at a time; an answer is kept `lifetime` (30 min: a
/// retry, another source, a lighter release, a replay search nothing), a
/// failure `failureLifetime` (the player that starts right after it does not
/// wait for the same failure again). A request that has not answered after
/// `giveUpAfter` counts as failed; its answer is still kept if it comes.
/// Completions run on the main queue. Any thread.
public final class SubtitleSearch {

    public static let shared = SubtitleSearch()

    /// How long a player's start may wait for the list, counted from the
    /// moment the search began (the user's Play).
    public static var startHold: TimeInterval = 4
    /// How long an answer is reused.
    public static var lifetime: TimeInterval = 30 * 60
    /// How long a failed search is not tried again.
    public static var failureLifetime: TimeInterval = 60
    /// A request still unanswered after this long counts as failed.
    public static var giveUpAfter: TimeInterval = 15

    /// Searches `media` (an episode by `showId`, else by its own show's id).
    typealias Fetch = (_ media: Media, _ showId: String?, _ completion: @escaping ([Subtitle], NSError?) -> Void) -> Void

    private struct Entry {
        let startedAt: TimeInterval
        /// The request's number: a late answer of an older request of the
        /// same title is recognised by it.
        let token: Int
        var subtitles: [Subtitle]?
        var failed = false
        var answeredAt: TimeInterval?
        var waiters: [([Subtitle]) -> Void] = []
    }

    private let fetch: Fetch
    private let now: () -> TimeInterval
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let deliver: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var nextToken = 0

    /// - Parameters:
    ///   - fetch: the search itself (default: `SubtitlesManager`).
    ///   - now: a monotonic clock, in seconds.
    ///   - after: runs a block after a delay (the hold's end, the give-up).
    ///   - deliver: runs a completion (default: asynchronously on the main queue).
    init(fetch: @escaping Fetch = SubtitleSearch.openSubtitles,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
         },
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.fetch = fetch
        self.now = now
        self.after = after
        self.deliver = deliver
    }

    // MARK: API

    /// Starts the search for `media` unless its answer is known or its
    /// request is running. `showId`: the show's imdb id for an episode whose
    /// own `show` may be missing.
    public func prefetch(for media: Media, showId: String? = nil) {
        guard let key = Self.key(for: media, showId: showId) else { return }
        lock.lock()
        let request = startIfNeeded(key: key, media: media, showId: showId)
        lock.unlock()
        request?()
    }

    /// The list of `media` when its search has answered — an empty one when
    /// it found nothing or failed — and nil while it is not known.
    public func answer(for media: Media, showId: String? = nil) -> [Subtitle]? {
        guard let key = Self.key(for: media, showId: showId) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return usableEntry(key)?.subtitles
    }

    /// The list of `media`, once: at once when it is known, else when the
    /// search (started here if need be) answers, fails or is given up.
    public func search(for media: Media, showId: String? = nil, completion: @escaping ([Subtitle]) -> Void) {
        guard let key = Self.key(for: media, showId: showId) else {
            deliver { completion([]) }
            return
        }
        lock.lock()
        if let known = usableEntry(key)?.subtitles {
            lock.unlock()
            deliver { completion(known) }
            return
        }
        let request = startIfNeeded(key: key, media: media, showId: showId)
        entries[key]?.waiters.append(completion)
        lock.unlock()
        request?()
    }

    /// For a start that waits for the list: `update(list, true)` when the
    /// search answers, or — `hold` seconds after the search began (at once
    /// when that is already past) — `update([], false)` to start without it,
    /// then `update(list, true)` when it does answer.
    public func search(for media: Media, showId: String? = nil, waitingAtMost hold: TimeInterval,
                       update: @escaping (_ subtitles: [Subtitle], _ isFinal: Bool) -> Void) {
        guard let key = Self.key(for: media, showId: showId) else {
            deliver { update([], true) }
            return
        }
        lock.lock()
        if let known = usableEntry(key)?.subtitles {
            lock.unlock()
            deliver { update(known, true) }
            return
        }
        let request = startIfNeeded(key: key, media: media, showId: showId)
        let startedAt = entries[key]?.startedAt ?? now()
        // Both run through `deliver` (one serial queue): no race on `answered`.
        var answered = false
        entries[key]?.waiters.append { subtitles in
            answered = true
            update(subtitles, true)
        }
        let remaining = startedAt + hold - now()
        lock.unlock()
        request?()
        let release = { [deliver] in
            deliver {
                guard !answered else { return }
                update([], false)
            }
        }
        if remaining > 0 { after(remaining, release) } else { release() }
    }

    /// How many answers and requests are held (the tests).
    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Forgets every answer (the requests in flight still complete).
    public func removeAll() {
        lock.lock()
        entries = entries.filter { $0.value.subtitles == nil }
        lock.unlock()
    }

    // MARK: Requests

    /// The entry of `key` when it is still good: a running request, or an
    /// answer young enough. Under `lock`.
    private func usableEntry(_ key: String) -> Entry? {
        guard let entry = entries[key] else { return nil }
        return isGood(entry) ? entry : nil
    }

    /// A running request, or an answer young enough. Under `lock`.
    private func isGood(_ entry: Entry) -> Bool {
        guard let answeredAt = entry.answeredAt else { return true }
        let lifetime = entry.failed ? Self.failureLifetime : Self.lifetime
        return now() - answeredAt <= lifetime
    }

    /// Under `lock`: a new entry for `key` unless one is usable. Returns the
    /// request to run once the lock is released.
    private func startIfNeeded(key: String, media: Media, showId: String?) -> (() -> Void)? {
        guard usableEntry(key) == nil else { return nil }
        // The answers too old to serve go with it: one was left per title
        // played, for the life of the app.
        entries = entries.filter { isGood($0.value) }
        nextToken += 1
        let token = nextToken
        entries[key] = Entry(startedAt: now(), token: token)
        return { [weak self] in
            guard let self = self else { return }
            self.fetch(media, showId) { [weak self] subtitles, error in
                self?.finish(key: key, token: token, subtitles: subtitles, failed: error != nil)
            }
            self.after(Self.giveUpAfter) { [weak self] in
                self?.finish(key: key, token: token, subtitles: [], failed: true, isGiveUp: true)
            }
        }
    }

    private func finish(key: String, token: Int, subtitles: [Subtitle], failed: Bool, isGiveUp: Bool = false) {
        lock.lock()
        guard var entry = entries[key], entry.token == token else {
            lock.unlock()
            return
        }
        if entry.answeredAt != nil {
            // Already settled. A real answer that comes after the give-up
            // (or after its own failure was noted) replaces it; anything
            // else changes nothing.
            guard !isGiveUp, !failed, entry.failed else {
                lock.unlock()
                return
            }
        }
        let waiters = entry.waiters
        entry.waiters = []
        entry.subtitles = subtitles
        entry.failed = failed
        entry.answeredAt = now()
        let elapsed = entry.answeredAt! - entry.startedAt
        entries[key] = entry
        lock.unlock()
        print("[Subtitles] search of \(key): "
              + (isGiveUp ? "no answer after \(Int(Self.giveUpAfter)) s, given up"
                 : failed ? "failed" : "\(subtitles.count) language(s)")
              + " in \(PlaybackStartTrace.milliseconds(elapsed)) ms")
        guard !waiters.isEmpty else { return }
        deliver { waiters.forEach { $0(subtitles) } }
    }

    // MARK: Keys

    /// What identifies a search: the movie's imdb id, or the show's (else
    /// its title, as `SubtitlesManager` then searches by text) with the
    /// season and episode. nil: nothing to search with.
    static func key(for media: Media, showId: String? = nil) -> String? {
        if let episode = media as? Episode {
            let show = showId ?? episode.show?.id ?? ""
            let anchor = show.hasPrefix("tt") ? show : "q:" + (episode.show?.title ?? episode.title)
            guard anchor != "q:" else { return nil }
            return "\(anchor) S\(episode.season)E\(episode.episode)"
        }
        return media.id.isEmpty ? nil : media.id
    }

    /// The OpenSubtitles queries of the play flows: a movie by its imdb id,
    /// an episode by its show's imdb id + season + episode.
    static func openSubtitles(_ media: Media, showId: String?, completion: @escaping ([Subtitle], NSError?) -> Void) {
        #if DEBUG
        // The bench (`-PTDebugNoSubtitleSearch YES`, and always for its
        // made-up show): no search leaves the device, nothing is found.
        let show = showId ?? (media as? Episode)?.show?.id
        if UserDefaults.standard.bool(forKey: "PTDebugNoSubtitleSearch") || show == EpisodeSourceResolver.debugShowID {
            print("[UpNextDebug] subtitle search of \(media.id) skipped (bench)")
            completion([], nil)
            return
        }
        #endif
        if let episode = media as? Episode {
            SubtitlesManager.shared.search(episode, imdbId: showId ?? episode.show?.id, completion: completion)
        } else {
            SubtitlesManager.shared.search(imdbId: media.id, completion: completion)
        }
    }
}
