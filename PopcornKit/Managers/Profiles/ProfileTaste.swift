import Foundation

// What a profile likes, learnt from what it does — nothing asked, nothing
// sent: no network, no account. One model per profile, under the profile's
// keys (`ProfileManager.storage(for:)`): a profile deleted takes its taste
// with it, « Reset » in Settings › Profiles clears it.
//
// The model is a handful of decaying weights:
//
//   - features of the titles the profile played, finished, gave up on or
//     added to its list: genres, decade, movie or show, people (directors,
//     the first actors). Not the original language: no source the app reads
//     says it of a movie or a show (a release's dub is not it);
//   - the choices it makes while watching: audio and subtitle languages,
//     the quality of the release it played.
//
// Every weight halves every `Policy.halfLife` (60 days): what was watched
// last week counts more than what was watched last year. An event updates
// the weights at once (no recomputation of the history), and the same event
// twice is counted once: each title remembers what it has added so far
// (`TitleRecord.credited`) and only the difference with what it is worth
// now is applied — a movie played 3 times, then finished, is a movie
// finished; a movie finished then marked unwatched is nothing again. A
// title known by its id only (marked watched from a list) waits with its
// worth until its features are known; features learnt later (people, from
// its page) take over what the poorer ones were credited.
//
// It is small and written seldom: tvOS gives the whole defaults domain
// 1 MB, shared by up to five profiles and their libraries. A play's
// position saved every 30 s changes nothing that matters to the taste and
// is written at most every `Policy.quietSaveInterval` (or at the pause,
// `flush`); the model keeps `Policy.maxTitles` titles and stays under
// `Policy.maxStoredBytes`.
//
// Read by the Home (« For You », `HomeLocalHooks`), by the players (an audio
// or subtitle language the profile never set itself, `preferredChoice`) and
// by Settings › Profiles (`topAffinities`, `reset`).

// MARK: - What an event is about

/// The features of a movie or a show the taste is learnt from.
public struct TasteTitle: Equatable, Sendable {

    public enum Kind: String, Codable, Sendable {
        case movie
        case show
    }

    /// IMDb id of the movie or of the show (an episode counts for its show).
    public var imdbID: String
    public var kind: Kind
    public var genres: [String]
    public var year: Int?
    /// Directors and the first actors.
    public var people: [String]

    public init(imdbID: String, kind: Kind, genres: [String] = [], year: Int? = nil, people: [String] = []) {
        self.imdbID = imdbID
        self.kind = kind
        self.genres = genres
        self.year = year
        self.people = people
    }
}

public extension TasteTitle {

    init(movie: Movie) {
        self.init(imdbID: movie.id, kind: .movie, genres: movie.genres, year: Int(movie.year.prefix(4)),
                  people: TasteTitle.people(crew: movie.crew, actors: movie.actors))
    }

    init(show: Show) {
        self.init(imdbID: show.id, kind: .show, genres: show.genres, year: Int(show.year.prefix(4)),
                  people: TasteTitle.people(crew: show.crew, actors: show.actors))
    }

    /// A Home card's title: the movie, or the show (of an episode card too).
    /// Its genres and year, no people: a card does not carry them.
    init(item: HomeItem) {
        self.init(imdbID: item.imdbId, kind: item.kind == .movie ? .movie : .show, genres: item.genres, year: item.year)
    }

    /// A movie, or the show of an episode (nil: an episode without its show).
    init?(media: Media) {
        if let movie = media as? Movie {
            self.init(movie: movie)
        } else if let show = media as? Show {
            self.init(show: show)
        } else if let show = (media as? Episode)?.show {
            self.init(show: show)
        } else {
            return nil
        }
    }

    private static func people(crew: [Crew], actors: [Actor]) -> [String] {
        let directors = crew.filter { $0.job.localizedCaseInsensitiveContains("director") && !$0.job.localizedCaseInsensitiveContains("photography") }
            .prefix(2).map(\.name)
        return Array((directors + actors.prefix(3).map(\.name)).filter { !$0.isEmpty }.prefix(5))
    }
}

/// A choice made while watching.
public enum TasteChoice: Equatable, Sendable {
    /// An audio language (ISO 639-1).
    case audio(String)
    /// A subtitle language (ISO 639-1); nil: subtitles off.
    case subtitle(String?)
    /// The quality of the release played ("2160p", "1080p", "720p", "480p").
    case quality(String)

    public enum Kind: String, CaseIterable, Sendable {
        case audio
        case subtitle
        case quality
    }

    public var kind: Kind {
        switch self {
        case .audio: return .audio
        case .subtitle: return .subtitle
        case .quality: return .quality
        }
    }

    /// "audio:fr", "subtitle:off", "quality:1080p".
    var key: String {
        switch self {
        case .audio(let code): return "audio:\(code.lowercased())"
        case .subtitle(let code): return "subtitle:\(code?.lowercased() ?? TasteChoice.off)"
        case .quality(let label): return "quality:\(label.lowercased())"
        }
    }

    static let off = "off"
}

// MARK: - What the model says

/// One facet of the taste, for Settings › Profiles.
public struct TasteAffinity: Hashable, Sendable {

    public enum Facet: String, CaseIterable, Sendable {
        case genre
        case decade
        case kind
        /// Never learnt (see the file's header): no affinity has it.
        case language
        case person
    }

    public var facet: Facet
    /// The genre (Cinemeta's name: "Sci-Fi"), the decade ("1990"), "movie"
    /// or "show", the person's name.
    public var value: String
    /// −1…1: 1 is the facet the profile likes most.
    public var score: Double

    public init(facet: Facet, value: String, score: Double) {
        self.facet = facet
        self.value = value
        self.score = score
    }
}

/// The taste at one moment, as plain values: what the Home ranks with. Pure
/// (Hashable, Sendable): the Home's builder reads it on its own queue.
public struct TasteSnapshot: Hashable, Sendable {
    /// Cinemeta's genre name → −1…1.
    public var genres: [String: Double]
    /// First year of the decade → −1…1.
    public var decades: [Int: Double]
    /// "movie" / "show" → −1…1.
    public var kinds: [String: Double]
    /// IMDb ids not to recommend: played, finished, given up on, listed.
    public var excluded: Set<String>
    /// How much the profile has done, decayed: under `minimumSignal` there is
    /// nothing to recommend with.
    public var signal: Double

    public static let minimumSignal = 1.5

    public init(genres: [String: Double] = [:], decades: [Int: Double] = [:], kinds: [String: Double] = [:],
                excluded: Set<String> = [], signal: Double = 0) {
        self.genres = genres
        self.decades = decades
        self.kinds = kinds
        self.excluded = excluded
        self.signal = signal
    }

    /// Enough was learnt to rank titles by it.
    public var isConfident: Bool {
        return signal >= TasteSnapshot.minimumSignal && genres.values.contains { $0 > 0 }
    }

    /// How much the profile should like a card, about −1…1: its genres first
    /// (the first ones count more), then its decade, movie or show, and a
    /// little of its rating (between two titles it likes alike, the better).
    public func score(_ item: HomeItem) -> Double {
        return score(kind: item.kind.rawValue, genres: item.genres, year: item.year, rating: item.rating)
    }

    public func score(kind: String, genres: [String], year: Int?, rating: Double?) -> Double {
        let decade = year.map { decades[TasteSnapshot.decade(of: $0)] ?? 0 } ?? 0
        let kindScore = kinds[kind] ?? 0
        let ratingScore = rating.flatMap { $0 > 0 ? max(-1, min(1, ($0 - 6.5) / 2.5)) : nil } ?? 0
        return 0.6 * genreScore(genres) + 0.15 * decade + 0.1 * kindScore + 0.15 * ratingScore
    }

    /// How much the profile likes a title's genres, about −1…1: the first
    /// ones count more. 0 for genres it never met, or none. « For You »
    /// requires some (a title it likes only for its decade or its rating
    /// is not a pick for it).
    public func genreScore(_ genres: [String]) -> Double {
        let weights = [1.0, 0.7, 0.5]
        var score = 0.0
        var total = 0.0
        for (index, genre) in TasteSnapshot.genreKeys(genres).prefix(weights.count).enumerated() {
            score += weights[index] * (self.genres[genre] ?? 0)
            total += weights[index]
        }
        return total > 0 ? score / total : 0
    }

    /// The genres under one spelling each (Cinemeta's: "Sci-Fi", "Sport"),
    /// without repeats, in order.
    static func genreKeys(_ genres: [String]) -> [String] {
        var seen = Set<String>()
        return genres.compactMap { ProfileTaste.genreKey($0) }.filter { seen.insert($0).inserted }
    }

    static func decade(of year: Int) -> Int {
        return year / 10 * 10
    }
}

// MARK: - The engine

/// A profile's taste. `ProfileTaste.shared` is the active profile's.
public final class ProfileTaste {

    public struct Policy: Sendable {
        /// A weight halves in this much time.
        public var halfLife: TimeInterval = 60 * 86_400
        /// A title played less than this…
        public var abandonedFraction: Float = 0.25
        /// … and not played again for this long was given up on.
        public var abandonedAfter: TimeInterval = 14 * 86_400
        /// What a title is worth.
        public var finished = 1.0
        public var started = 0.3
        public var abandoned = -0.6
        public var watchlisted = 0.4
        /// Taken out of the list without being watched.
        public var unwatchlisted = -0.15
        /// A show: what each finished episode adds, up to `showMaximum`.
        public var perEpisode = 0.2
        public var showMaximum = 1.4
        /// How much each feature of a title takes of its worth.
        public var genreFactor = 1.0
        public var decadeFactor = 0.5
        public var kindFactor = 0.3
        public var personFactor = 0.4
        /// Titles remembered (the most recent kept).
        public var maxTitles = 200
        /// Features kept (the strongest).
        public var maxFeatures = 200
        /// The stored model at most (its oldest titles go first): five
        /// profiles stay well under the 1 MB tvOS allows the whole defaults
        /// domain, next to their libraries.
        public var maxStoredBytes = 64_000
        /// A change that matters to nothing the taste says (a play's
        /// position saved again, the time it was played) is written at most
        /// this often, or at the pause (`flush`).
        public var quietSaveInterval: TimeInterval = 30 * 60
        /// A learnt choice is used when it is at least this much of its kind…
        public var choiceShare = 0.6
        /// … and was made about this many times (decayed: two picks made a
        /// few days apart weigh a little under 2, so it takes three).
        public var choiceMinimum = 2.0

        /// The finished episodes a show remembers: past these, more add
        /// nothing to its worth (`showMaximum`). Two more than that, so
        /// unmarking a recent one leaves it at its ceiling.
        public var savedEpisodes: Int {
            return Int(((showMaximum - started) / perEpisode).rounded(.up)) + 2
        }

        public init() {}

        public static let standard = Policy()
    }

    /// Posted on the main queue when a taste changed in a way that matters to
    /// the screens (reset, a play, the list); the object is the taste.
    public static let didChangeNotification = Notification.Name("PopcornKit.ProfileTaste.didChange")

    /// The key of the model in the profile's storage.
    public static let storageKey = "tasteProfile"

    // MARK: One per profile

    /// The active profile's taste (`ProfileManager`).
    public static var shared: ProfileTaste {
        return taste(for: ProfileManager.shared.activeID)
    }

    private static let tastesLock = NSLock()
    private static var tastes: [String: ProfileTaste] = [:]

    /// A profile's taste (kept once made). The first time a profile has one,
    /// its watchlist seeds it (`seed(from:)`).
    public static func taste(for profileID: String) -> ProfileTaste {
        tastesLock.lock(); defer { tastesLock.unlock() }
        if let taste = tastes[profileID] { return taste }
        let taste = ProfileTaste(storage: ProfileManager.shared.storage(for: profileID))
        if !taste.hasStoredModel { taste.seed(from: Library.library(for: profileID)) }
        #if DEBUG
        // `-PTDebugTasteGenres "Sci-Fi,Drama"` (UI tests, screenshots): the
        // profile picked first has finished three movies of these genres.
        if profileID == ProfileManager.shared.activeID, let genres = UserDefaults.standard.string(forKey: "PTDebugTasteGenres"), taste.isEmpty {
            let list = genres.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for index in 0..<3 {
                taste.notePlayback(of: TasteTitle(imdbID: "tt99999\(index)", kind: .movie, genres: list, year: 2015),
                                   progress: 1, isFinished: true)
            }
        }
        #endif
        tastes[profileID] = taste
        return taste
    }

    /// Writes every profile's quiet changes (`flush`) — a player of another
    /// profile may still have some.
    public static func flushAll() {
        tastesLock.lock()
        let all = Array(tastes.values)
        tastesLock.unlock()
        all.forEach { $0.flush() }
    }

    /// The app calls it at launch with its notifications for leaving the
    /// foreground and quitting: what was kept in memory is written before
    /// the app may be killed (`flushAll`).
    public static func flushes(on names: [Notification.Name], center: NotificationCenter = .default) {
        for name in names {
            _ = center.addObserver(forName: name, object: nil, queue: nil) { _ in flushAll() }
        }
    }

    /// Drops a deleted profile's taste (its keys are gone with the profile's).
    static func forget(profileID: String) {
        tastesLock.lock(); defer { tastesLock.unlock() }
        tastes[profileID] = nil
    }

    // MARK: State

    public let policy: Policy
    private let storage: LibraryStorage
    private let now: () -> Date
    private let center: NotificationCenter
    private let lock = NSLock()
    private var model: Model
    private let hasStoredModel: Bool
    /// The model in memory differs from the stored one (a quiet change).
    private var isSavePending = false
    private var lastSave: Date

    public init(storage: LibraryStorage, policy: Policy = .standard, center: NotificationCenter = .default,
                now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.policy = policy
        self.center = center
        self.now = now
        lastSave = now()
        // A model of another version is started over (and seeded again):
        // version 1 was never released.
        if let data = storage.object(forKey: ProfileTaste.storageKey) as? Data,
           let stored = try? ProfileTaste.decoder.decode(Model.self, from: data), stored.version == Model.currentVersion {
            model = stored
            hasStoredModel = true
        } else {
            model = Model()
            hasStoredModel = false
        }
    }

    // MARK: Events

    /// A movie or an episode played up to `progress` (0…1); `isFinished`:
    /// the library counts it as watched. `episodeID` for an episode: its
    /// show counts each finished episode once.
    public func notePlayback(of title: TasteTitle, progress: Float, isFinished: Bool, episodeID: String? = nil) {
        update(title) { record, now in
            record.lastPlayedAt = now
            record.abandoned = false
            // A show remembers how far its furthest episode went too: one
            // left past a quarter is not given up on (`sweep`).
            record.progress = max(record.progress, progress)
            if record.kind == TasteTitle.Kind.show.rawValue {
                record.started = true
                if isFinished, let episodeID { record.insertFinished(episodeID, policy: policy) }
            } else {
                record.started = record.started || progress > 0
                record.finished = record.finished || isFinished
            }
        }
    }

    /// Marked watched (or not any more) by hand. `episodeID` for an episode
    /// of `title`'s show.
    public func noteWatched(_ isWatched: Bool, of title: TasteTitle, episodeID: String? = nil) {
        update(title) { record, _ in
            if let episodeID {
                if isWatched { record.insertFinished(episodeID, policy: policy) } else { record.finishedEpisodes.remove(episodeID) }
            } else {
                record.finished = isWatched
                if !isWatched { record.progress = 0; record.started = false; record.abandoned = false }
            }
        }
    }

    /// The same, from the library's ids ("tt…" or "tt…-s1e2"), with the
    /// movie or the show when the caller has it (`title`). Without it, the
    /// title counts once its features are known (played, listed, marked
    /// from its page), and is an exclusion until then.
    public func noteWatched(_ isWatched: Bool, mediaID: String, kind: TasteTitle.Kind, title: TasteTitle? = nil) {
        if let (showID, _) = LibraryID.episode(mediaID) {
            let show = title.flatMap { $0.kind == .show && $0.imdbID == showID ? $0 : nil }
            noteWatched(isWatched, of: show ?? TasteTitle(imdbID: showID, kind: .show), episodeID: mediaID)
        } else if kind == .show {
            // An episode under another provider's id: only its show says
            // which title it counts for.
            guard let title, title.kind == .show else { return }
            noteWatched(isWatched, of: title, episodeID: mediaID)
        } else {
            noteWatched(isWatched, of: title ?? TasteTitle(imdbID: mediaID, kind: kind))
        }
    }

    /// Added to the list, or taken out of it.
    public func noteWatchlist(_ isAdded: Bool, of title: TasteTitle) {
        noteWatchlist(isAdded, of: title, notifies: true, persists: true)
    }

    private func noteWatchlist(_ isAdded: Bool, of title: TasteTitle, notifies: Bool, persists: Bool) {
        update(title, notifies: notifies, persists: persists) { record, _ in record.watchlisted = isAdded }
    }

    /// A choice made while watching.
    public func note(_ choice: TasteChoice) {
        let now = self.now()
        lock.lock()
        var decayed = model.choices[choice.key] ?? Decayed()
        decayed.add(1, at: now, halfLife: policy.halfLife)
        model.choices[choice.key] = decayed
        save()
        lock.unlock()
    }

    /// True the first time it is asked about a media id ("tt…" or
    /// "tt…-s1e2"; the last 200 are remembered): a play's quality is
    /// counted once, not at every saved position. Written with the play
    /// that follows.
    public func isFirstPlay(of mediaID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !model.played.contains(mediaID) else { return false }
        model.played.append(mediaID)
        if model.played.count > 200 { model.played.removeFirst(model.played.count - 200) }
        isSavePending = true
        return true
    }

    /// Writes what changed quietly since the last write (a position saved
    /// again): `PlaybackRecorder` calls it at the pause and at the end of a
    /// play, the app when it leaves the foreground (`flushes(on:)`).
    public func flush() {
        lock.lock()
        if isSavePending { save() }
        lock.unlock()
    }

    /// The titles started long ago and left early are given up on. Cheap:
    /// run when the Home reads the taste (launch, profile switch, a change).
    public func sweep() {
        let now = self.now()
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for (id, var record) in model.titles where !record.abandoned && record.started && !record.finished && record.finishedEpisodes.isEmpty {
            guard let played = record.lastPlayedAt, now.timeIntervalSince(played) >= policy.abandonedAfter,
                  record.progress < policy.abandonedFraction else { continue }
            record.abandoned = true
            credit(&record, now: now)
            model.titles[id] = record
            changed = true
        }
        if changed { save() }
    }

    /// Forgets everything learnt (Settings › Profiles › Reset). Nothing is
    /// seeded again: the profile starts over from what it does next.
    public func reset() {
        lock.lock()
        model = Model()
        model.seeded = true
        save()
        lock.unlock()
        post()
    }

    /// The first taste of a profile that existed before tastes did: its
    /// watchlist (the one place the library keeps genres and years). One
    /// write for the whole list.
    func seed(from library: Library) {
        lock.lock()
        let seeded = model.seeded
        lock.unlock()
        guard !seeded else { return }
        for kind in [ContinueWatchingItem.Kind.movie, .show] {
            for entry in library.watchlist(kind).reversed() {
                noteWatchlist(true, of: TasteTitle(imdbID: entry.imdbID, kind: kind == .movie ? .movie : .show,
                                                   genres: entry.genres, year: entry.year.flatMap { Int($0.prefix(4)) }),
                              notifies: false, persists: false)
            }
        }
        lock.lock()
        model.seeded = true
        trim()
        save()
        lock.unlock()
    }

    // MARK: Reads

    /// The taste as the Home ranks with it. `alsoExcluded`: what the library
    /// knows was watched that the taste never saw.
    public func snapshot(alsoExcluded: Set<String> = []) -> TasteSnapshot {
        sweep()
        let now = self.now()
        lock.lock(); defer { lock.unlock() }
        var genres: [String: Double] = [:]
        var decades: [Int: Double] = [:]
        var kinds: [String: Double] = [:]
        for (key, decayed) in model.features {
            let value = decayed.value(at: now, halfLife: policy.halfLife)
            guard let (facet, name) = Feature.parse(key) else { continue }
            switch facet {
            case .genre: genres[name] = value
            case .decade: if let year = Int(name) { decades[year] = value }
            case .kind: kinds[name] = value
            case .language, .person: break
            }
        }
        var excluded = alsoExcluded
        for (id, record) in model.titles where record.started || record.finished || record.abandoned
            || !record.finishedEpisodes.isEmpty || record.watchlisted == true {
            excluded.insert(id)
        }
        return TasteSnapshot(genres: ProfileTaste.normalized(genres), decades: ProfileTaste.normalized(decades),
                             kinds: ProfileTaste.normalized(kinds), excluded: excluded,
                             signal: model.signal.value(at: now, halfLife: policy.halfLife))
    }

    /// The strongest facets, best first, at most `limit` per facet: what
    /// Settings › Profiles shows. Only what the profile likes (score > 0).
    public func topAffinities(limit: Int = 3) -> [TasteAffinity.Facet: [TasteAffinity]] {
        let now = self.now()
        lock.lock()
        var byFacet: [TasteAffinity.Facet: [String: Double]] = [:]
        for (key, decayed) in model.features {
            guard let (facet, name) = Feature.parse(key) else { continue }
            byFacet[facet, default: [:]][name] = decayed.value(at: now, halfLife: policy.halfLife)
        }
        lock.unlock()
        var result: [TasteAffinity.Facet: [TasteAffinity]] = [:]
        for (facet, values) in byFacet {
            let top = ProfileTaste.normalized(values).filter { $0.value > 0.05 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(limit).map { TasteAffinity(facet: facet, value: $0.key, score: $0.value) }
            if !top.isEmpty { result[facet] = top }
        }
        return result
    }

    /// The choice the profile makes most of a kind, when it makes it often
    /// enough (`Policy.choiceShare`, `choiceMinimum`). For subtitles, "off"
    /// is a choice too: nil then, as when nothing was learnt —
    /// `prefersSubtitlesOff` tells them apart.
    public func preferredChoice(_ kind: TasteChoice.Kind) -> String? {
        guard let (value, _) = leadingChoice(kind), value != TasteChoice.off else { return nil }
        return value
    }

    /// The profile turns subtitles off, mostly.
    public var prefersSubtitlesOff: Bool {
        return leadingChoice(.subtitle)?.value == TasteChoice.off
    }

    /// Choices of a kind with their decayed counts, most made first.
    public func choices(_ kind: TasteChoice.Kind) -> [(value: String, count: Double)] {
        let now = self.now()
        let prefix = kind.rawValue + ":"
        lock.lock(); defer { lock.unlock() }
        return model.choices.compactMap { key, decayed -> (value: String, count: Double)? in
            guard key.hasPrefix(prefix) else { return nil }
            return (String(key.dropFirst(prefix.count)), decayed.value(at: now, halfLife: policy.halfLife))
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
    }

    /// Nothing learnt yet (or everything reset).
    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return model.features.isEmpty && model.choices.isEmpty
    }

    private func leadingChoice(_ kind: TasteChoice.Kind) -> (value: String, count: Double)? {
        let all = choices(kind)
        let total = all.reduce(0) { $0 + $1.count }
        guard let first = all.first, total > 0, first.count >= policy.choiceMinimum,
              first.count / total >= policy.choiceShare else { return nil }
        return first
    }

    // MARK: Updating

    /// Changes a title's record, then credits the difference of its worth.
    /// Written and announced only when it changed something the taste says
    /// (`persists` false: written by the caller, the seed); otherwise kept
    /// for the next write (`Policy.quietSaveInterval`, `flush`).
    private func update(_ title: TasteTitle, notifies: Bool = true, persists: Bool = true,
                        _ change: (inout TitleRecord, Date) -> Void) {
        guard !title.imdbID.isEmpty else { return }
        let now = self.now()
        lock.lock()
        let old = model.titles[title.imdbID]
        var record = old ?? TitleRecord(kind: title.kind.rawValue)
        let adopted = adopt(ProfileTaste.features(of: title), into: &record, now: now)
        change(&record, now)
        record.updatedAt = now
        let credited = credit(&record, now: now)
        model.titles[title.imdbID] = record
        let matters = adopted || credited || old.map { ProfileTaste.differs($0, record, policy: policy) } ?? true
        if matters, persists {
            trim()
            save()
        } else {
            isSavePending = true
            if persists, now.timeIntervalSince(lastSave) >= policy.quietSaveInterval { save() }
        }
        lock.unlock()
        if notifies, matters { post() }
    }

    /// The record says something else to the taste (what it is worth, what
    /// it excludes, whether it may be given up on): not only a later time
    /// or a few more percent of a play.
    static func differs(_ old: TitleRecord, _ new: TitleRecord, policy: Policy) -> Bool {
        return old.kind != new.kind || old.features != new.features || old.started != new.started
            || old.finished != new.finished || old.abandoned != new.abandoned || old.watchlisted != new.watchlisted
            || old.finishedEpisodes != new.finishedEpisodes
            || (old.progress < policy.abandonedFraction) != (new.progress < policy.abandonedFraction)
    }

    /// Features learnt late (a title known by its id or from its list, then
    /// played from its page with its people): the richer set replaces the
    /// record's, and what was credited moves onto it — not counted again as
    /// something new (`signal`). True when the set changed.
    private func adopt(_ features: [String], into record: inout TitleRecord, now: Date) -> Bool {
        guard features.count > record.features.count else { return false }
        let moved = record.credited.value(at: now, halfLife: policy.halfLife)
        if moved != 0 {
            apply(-moved, to: record.features, now: now)
            apply(moved, to: features, now: now)
        }
        record.features = features
        return true
    }

    /// Applies `worth(record) - credited` to the record's features (under
    /// the lock); true when something was applied. A title whose features
    /// are not known yet keeps its whole worth for when they are: only an
    /// exclusion until then, and nothing learnt (`signal`) from it.
    @discardableResult
    private func credit(_ record: inout TitleRecord, now: Date) -> Bool {
        guard !record.features.isEmpty else { return false }
        let target = worth(of: record)
        let delta = target - record.credited.value(at: now, halfLife: policy.halfLife)
        guard abs(delta) > 0.0001 else { return false }
        apply(delta, to: record.features, now: now)
        model.signal.add(abs(delta), at: now, halfLife: policy.halfLife)
        record.credited = Decayed(value: target, at: now)
        return true
    }

    /// Adds `amount` of a title's worth to its features, each its share
    /// (`share(of:genres:)`).
    private func apply(_ amount: Double, to features: [String], now: Date) {
        let genres = features.filter { Feature.parse($0)?.0 == .genre }.count
        for key in features {
            let share = ProfileTaste.share(of: key, genres: genres, policy: policy)
            guard share > 0 else { continue }
            var decayed = model.features[key] ?? Decayed()
            decayed.add(amount * share, at: now, halfLife: policy.halfLife)
            model.features[key] = decayed
        }
    }

    /// What a title is worth now.
    func worth(of record: TitleRecord) -> Double {
        var worth: Double
        if record.abandoned {
            worth = policy.abandoned
        } else if record.kind == TasteTitle.Kind.show.rawValue, !record.finishedEpisodes.isEmpty {
            worth = min(policy.showMaximum, policy.started + policy.perEpisode * Double(record.finishedEpisodes.count))
        } else if record.finished {
            worth = policy.finished
        } else if record.started {
            worth = policy.started
        } else {
            worth = 0
        }
        if record.watchlisted == true {
            worth += policy.watchlisted
        } else if record.watchlisted == false, worth == 0 {
            worth = policy.unwatchlisted
        }
        return worth
    }

    /// The oldest titles and the weakest features go first (under the lock).
    /// A title dropped keeps what it credited in the features.
    private func trim() {
        if model.titles.count > policy.maxTitles {
            dropOldestTitles(model.titles.count - policy.maxTitles)
        }
        if model.features.count > policy.maxFeatures {
            let now = self.now()
            let weakest = model.features.sorted { abs($0.value.value(at: now, halfLife: policy.halfLife)) < abs($1.value.value(at: now, halfLife: policy.halfLife)) }
                .prefix(model.features.count - policy.maxFeatures)
            for (key, _) in weakest { model.features[key] = nil }
        }
    }

    private func dropOldestTitles(_ count: Int) {
        let oldest = model.titles.sorted { $0.value.updatedAt != $1.value.updatedAt ? $0.value.updatedAt < $1.value.updatedAt : $0.key < $1.key }
            .prefix(count)
        for (id, _) in oldest { model.titles[id] = nil }
    }

    /// Under the lock. Over `Policy.maxStoredBytes` (long titles, many
    /// people), the oldest titles go a tenth at a time until it fits.
    private func save() {
        guard var data = try? ProfileTaste.encoder.encode(model) else { return }
        while data.count > policy.maxStoredBytes, !model.titles.isEmpty {
            dropOldestTitles(max(1, model.titles.count / 10))
            guard let smaller = try? ProfileTaste.encoder.encode(model) else { return }
            data = smaller
        }
        storage.set(data, forKey: ProfileTaste.storageKey)
        isSavePending = false
        lastSave = now()
    }

    private func post() {
        let center = self.center
        let send = { center.post(name: ProfileTaste.didChangeNotification, object: self) }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }

    // MARK: Features

    /// A title's features ("genre:Sci-Fi", "decade:2010", "kind:movie",
    /// "person:…"): at most 3 genres and 5 people.
    static func features(of title: TasteTitle) -> [String] {
        let genres = TasteSnapshot.genreKeys(title.genres).prefix(3)
        var features = genres.map { Feature.key(.genre, $0) }
        if let year = title.year, year > 1800 { features.append(Feature.key(.decade, String(TasteSnapshot.decade(of: year)))) }
        if !genres.isEmpty || title.year != nil { features.append(Feature.key(.kind, title.kind.rawValue)) }
        var people = Set<String>()
        for person in title.people where people.insert(person).inserted && people.count <= 5 {
            features.append(Feature.key(.person, person))
        }
        return features
    }

    /// The share of a title's worth a feature of it takes; `genres`: how
    /// many genres the title has. Three genres do not make a title count
    /// three times more than one.
    static func share(of key: String, genres: Int, policy: Policy) -> Double {
        switch Feature.parse(key)?.0 {
        case .genre?: return genres > 0 ? policy.genreFactor / Double(genres).squareRoot() : 0
        case .decade?: return policy.decadeFactor
        case .kind?: return policy.kindFactor
        case .person?: return policy.personFactor
        case .language?, nil: return 0
        }
    }

    /// One spelling per genre: Cinemeta's ("Sci-Fi" for "Science Fiction"),
    /// else the catalogs' own for the genres Cinemeta lacks ("Reality-TV",
    /// not `capitalized`'s "Reality-Tv": the strings' keys), else the name
    /// capitalised. nil for an empty one.
    public static func genreKey(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return HomeBuilder.cinemetaGenre(trimmed) ?? otherGenres[trimmed.lowercased()] ?? trimmed.capitalized
    }

    /// YTS's, TVMaze's and IMDb's genres whose spelling `capitalized` breaks.
    private static let otherGenres: [String: String] = [
        "reality-tv": "Reality-TV", "reality tv": "Reality-TV", "reality": "Reality-TV",
        "talk-show": "Talk-Show", "talk show": "Talk-Show",
        "game-show": "Game-Show", "game show": "Game-Show",
        "film-noir": "Film-Noir", "film noir": "Film-Noir",
        "diy": "DIY",
    ]

    /// Divided by the largest magnitude: −1…1.
    static func normalized<Key: Hashable>(_ values: [Key: Double]) -> [Key: Double] {
        let largest = values.values.map(abs).max() ?? 0
        guard largest > 0.0001 else { return [:] }
        return values.mapValues { $0 / largest }
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}

// MARK: - Stored model
//
// Short keys, defaults left out, times in whole seconds: a title takes
// about 250 bytes, a full model of 200 well-known titles about 60 KB.

/// A weight that halves every `halfLife`: stored as its value at `at`.
struct Decayed: Codable, Equatable {
    var value: Double = 0
    var at: Date = .distantPast

    init(value: Double = 0, at: Date = .distantPast) {
        self.value = value
        self.at = at
    }

    func value(at now: Date, halfLife: TimeInterval) -> Double {
        guard value != 0 else { return 0 }
        let elapsed = max(0, now.timeIntervalSince(at))
        return value * pow(0.5, elapsed / halfLife)
    }

    mutating func add(_ amount: Double, at now: Date, halfLife: TimeInterval) {
        value = value(at: now, halfLife: halfLife) + amount
        at = now
    }

    enum CodingKeys: String, CodingKey {
        case value = "v"
        case at = "t"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(Double.self, forKey: .value)
        at = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .at))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(TitleRecord.seconds(at), forKey: .at)
    }
}

/// What the taste remembers of a title.
struct TitleRecord: Codable, Equatable {
    var kind: String
    /// Feature keys (`ProfileTaste.features(of:)`); each takes its share of
    /// the title's worth (`ProfileTaste.share(of:genres:policy:)`).
    var features: [String] = []
    /// How far it was played (a show: its furthest episode).
    var progress: Float = 0
    var started = false
    var finished = false
    var abandoned = false
    /// nil: never listed; false: taken out of the list.
    var watchlisted: Bool?
    /// A show's episodes finished ("tt…-s1e2"), up to `Policy.savedEpisodes`.
    var finishedEpisodes: Set<String> = []
    var lastPlayedAt: Date?
    /// What the title has added to the features so far.
    var credited = Decayed()
    var updatedAt: Date = .distantPast

    init(kind: String) {
        self.kind = kind
    }

    /// Counts a finished episode; past `Policy.savedEpisodes` the show is at
    /// its ceiling already, and another one is not kept.
    mutating func insertFinished(_ episodeID: String, policy: ProfileTaste.Policy) {
        guard finishedEpisodes.count < policy.savedEpisodes else { return }
        finishedEpisodes.insert(episodeID)
    }

    enum CodingKeys: String, CodingKey {
        case kind = "k", features = "f", progress = "p", started = "s", finished = "d", abandoned = "a"
        case watchlisted = "w", finishedEpisodes = "e", lastPlayedAt = "l", credited = "c", updatedAt = "u"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        features = try container.decodeIfPresent([String].self, forKey: .features) ?? []
        progress = try container.decodeIfPresent(Float.self, forKey: .progress) ?? 0
        started = try container.decodeIfPresent(Bool.self, forKey: .started) ?? false
        finished = try container.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        abandoned = try container.decodeIfPresent(Bool.self, forKey: .abandoned) ?? false
        watchlisted = try container.decodeIfPresent(Bool.self, forKey: .watchlisted)
        finishedEpisodes = Set(try container.decodeIfPresent([String].self, forKey: .finishedEpisodes) ?? [])
        lastPlayedAt = try container.decodeIfPresent(Double.self, forKey: .lastPlayedAt).map(Date.init(timeIntervalSince1970:))
        credited = try container.decodeIfPresent(Decayed.self, forKey: .credited) ?? Decayed()
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if !features.isEmpty { try container.encode(features, forKey: .features) }
        // Three decimals are plenty for a fraction of a play.
        if progress > 0 { try container.encode((progress * 1000).rounded() / 1000, forKey: .progress) }
        if started { try container.encode(true, forKey: .started) }
        if finished { try container.encode(true, forKey: .finished) }
        if abandoned { try container.encode(true, forKey: .abandoned) }
        try container.encodeIfPresent(watchlisted, forKey: .watchlisted)
        if !finishedEpisodes.isEmpty { try container.encode(finishedEpisodes.sorted(), forKey: .finishedEpisodes) }
        try container.encodeIfPresent(lastPlayedAt.map(TitleRecord.seconds), forKey: .lastPlayedAt)
        if credited.value != 0 { try container.encode(credited, forKey: .credited) }
        try container.encode(TitleRecord.seconds(updatedAt), forKey: .updatedAt)
    }

    /// A time to the second, as stored.
    static func seconds(_ date: Date) -> Int64 {
        return Int64(date.timeIntervalSince1970.rounded())
    }
}

private struct Model: Codable {
    /// 2: short keys, a title's features as keys only.
    static let currentVersion = 2
    var version = Model.currentVersion
    /// The watchlist was read once (`ProfileTaste.seed`).
    var seeded = false
    /// "genre:Sci-Fi", "decade:1990", "kind:movie", "person:…".
    var features: [String: Decayed] = [:]
    /// "audio:fr", "subtitle:off", "quality:1080p".
    var choices: [String: Decayed] = [:]
    /// IMDb id → record.
    var titles: [String: TitleRecord] = [:]
    /// Everything credited, in magnitude: how much is known.
    var signal = Decayed()
    /// Media ids whose play was counted (`isFirstPlay`), the latest last.
    var played: [String] = []
}

private enum Feature {
    static func key(_ facet: TasteAffinity.Facet, _ value: String) -> String {
        return "\(facet.rawValue):\(value)"
    }

    static func parse(_ key: String) -> (TasteAffinity.Facet, String)? {
        guard let colon = key.firstIndex(of: ":"), let facet = TasteAffinity.Facet(rawValue: String(key[..<colon])) else { return nil }
        return (facet, String(key[key.index(after: colon)...]))
    }
}
