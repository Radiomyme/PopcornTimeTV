import Foundation

// Languages by content type (« Vos langues »): each profile chooses how it
// watches three kinds of titles — live action (« Films et séries »),
// cartoons (« Dessins animés ») and Japanese animation (« Animés ») — with an
// audio choice (Automatic, the title's original version « VO », a language)
// and a subtitle choice (Automatic, Off, a language) for each.
//
// - `ContentLanguageChoices` is a profile's choice, stored under its prefix
//   (`ContentLanguageSettings.storageKey`). Nothing stored = Automatic
//   everywhere: the players do what they did before.
// - `TitleOrigin` is what decides a title's type and original language,
//   gathered from the metadata the app loads anyway (Cinemeta's genres and
//   countries, YTS's language, TVMaze's type and language) and kept on disk
//   by IMDb id (`TitleOriginStore`): the players, Continue Watching and the
//   downloads don't carry it.
// - `ContentClassifier` turns an origin into a type and an original
//   language (pure).
// - `ContentLanguages` is the title being looked at or played (`focus`):
//   `AudioLanguagePreference.current` and the apps' players read its plan,
//   so the release ranking and the track choice agree with the profile's
//   choice for that type.

// MARK: - The types

/// The three kinds of titles a profile chooses its languages for.
public enum ContentType: String, CaseIterable, Codable, Sendable {
    /// Live action: everything that is not animation (« Films et séries »).
    case movie
    /// Animation not from Japan (« Dessins animés »).
    case cartoon
    /// Japanese animation (« Animés »).
    case anime

    /// The key of its name in Localizable.strings.
    public var titleKey: String {
        switch self {
        case .movie: return "Languages.Type.Movie"
        case .cartoon: return "Languages.Type.Cartoon"
        case .anime: return "Languages.Type.Anime"
        }
    }

    /// The key of its one-line description in Localizable.strings.
    public var detailKey: String { titleKey + ".Detail" }
}

/// A type's audio choice.
public enum ContentAudioChoice: Hashable, Sendable {
    /// The profile's preferred (or learnt) audio language, as before.
    case automatic
    /// The title's original language (« VO »); Automatic when unknown.
    case original
    /// That language (ISO 639-1).
    case language(String)

    public static let automaticTag = "auto"
    public static let originalTag = "original"

    /// What a picker and the storage hold: "auto", "original" or the code.
    public var tag: String {
        switch self {
        case .automatic: return ContentAudioChoice.automaticTag
        case .original: return ContentAudioChoice.originalTag
        case .language(let code): return code
        }
    }

    /// A tag read back; anything unknown or empty is Automatic.
    public init(tag: String?) {
        switch tag?.trimmingCharacters(in: .whitespaces).lowercased() {
        case nil, "", ContentAudioChoice.automaticTag?: self = .automatic
        case ContentAudioChoice.originalTag?: self = .original
        case let code?: self = .language(code)
        }
    }
}

/// A type's subtitle choice.
public enum ContentSubtitleChoice: Hashable, Sendable {
    /// The profile's subtitle setting (or learnt language), as before.
    case automatic
    /// No subtitles turned on (forced ones still show for the language heard).
    case off
    /// That language (ISO 639-1).
    case language(String)

    public static let automaticTag = "auto"
    public static let offTag = "off"

    public var tag: String {
        switch self {
        case .automatic: return ContentSubtitleChoice.automaticTag
        case .off: return ContentSubtitleChoice.offTag
        case .language(let code): return code
        }
    }

    public init(tag: String?) {
        switch tag?.trimmingCharacters(in: .whitespaces).lowercased() {
        case nil, "", ContentSubtitleChoice.automaticTag?: self = .automatic
        case ContentSubtitleChoice.offTag?: self = .off
        case let code?: self = .language(code)
        }
    }
}

/// One type's choice.
public struct ContentLanguageChoice: Hashable, Sendable {
    public var audio: ContentAudioChoice
    public var subtitles: ContentSubtitleChoice

    public init(audio: ContentAudioChoice = .automatic, subtitles: ContentSubtitleChoice = .automatic) {
        self.audio = audio
        self.subtitles = subtitles
    }

    public static let automatic = ContentLanguageChoice()

    public var isAutomatic: Bool { self == .automatic }
}

/// A profile's choices, one per type (Automatic when never chosen).
public struct ContentLanguageChoices: Equatable, Sendable {
    private var values: [ContentType: ContentLanguageChoice]

    public init(_ values: [ContentType: ContentLanguageChoice] = [:]) {
        self.values = values.filter { !$0.value.isAutomatic }
    }

    public static let automatic = ContentLanguageChoices()

    public subscript(type: ContentType) -> ContentLanguageChoice {
        get { values[type] ?? .automatic }
        set { values[type] = newValue.isAutomatic ? nil : newValue }
    }

    /// Nothing chosen: the players do as they did before.
    public var isAllAutomatic: Bool { values.isEmpty }

    /// The stored form: {"anime": {"audio": "original", "subtitles": "fr"}}
    /// (property-list types only: the defaults and the tests' memory store).
    public var propertyList: [String: [String: String]] {
        var plist: [String: [String: String]] = [:]
        for (type, choice) in values {
            plist[type.rawValue] = ["audio": choice.audio.tag, "subtitles": choice.subtitles.tag]
        }
        return plist
    }

    /// Reads the stored form; anything unreadable is Automatic.
    public init(propertyList: Any?) {
        var values: [ContentType: ContentLanguageChoice] = [:]
        for (key, value) in (propertyList as? [String: Any]) ?? [:] {
            guard let type = ContentType(rawValue: key), let fields = value as? [String: Any] else { continue }
            values[type] = ContentLanguageChoice(audio: ContentAudioChoice(tag: fields["audio"] as? String),
                                                 subtitles: ContentSubtitleChoice(tag: fields["subtitles"] as? String))
        }
        self.init(values)
    }

    /// "anime=original/fr;cartoon=fr/auto;movie=auto/off": type=audio/subtitles
    /// tags (`-PTDebugContentLanguages`, tests).
    public init(debugString: String) {
        var values: [ContentType: ContentLanguageChoice] = [:]
        for entry in debugString.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let type = ContentType(rawValue: parts[0].lowercased()) else { continue }
            let tags = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
            values[type] = ContentLanguageChoice(audio: ContentAudioChoice(tag: tags.first),
                                                 subtitles: ContentSubtitleChoice(tag: tags.count > 1 ? tags[1] : nil))
        }
        self.init(values)
    }
}

public extension Notification.Name {
    /// Posted on the main queue when a profile's languages by type changed
    /// (object: the profile's id).
    static let contentLanguagesDidChange = Notification.Name("PopcornKit.ContentLanguages.didChange")
}

// MARK: - Per profile storage

/// Where a profile keeps its choices and whether « Vos langues » was shown.
/// The keys are behind the profile's prefix (`ProfileManager.storage(for:)`),
/// so deleting a profile deletes them. Nothing to migrate: a key never set
/// means Automatic, and « never asked » (the screen shows once, also after
/// an update).
public enum ContentLanguageSettings {

    /// The choices (`ContentLanguageChoices.propertyList`).
    public static let storageKey = "contentLanguages"
    /// True once « Vos langues » was answered (« Continuer » or « Plus tard »).
    public static let askedKey = "contentLanguagesAsked"

    public static func choices(in storage: LibraryStorage) -> ContentLanguageChoices {
        return ContentLanguageChoices(propertyList: storage.object(forKey: storageKey))
    }

    public static func save(_ choices: ContentLanguageChoices, in storage: LibraryStorage) {
        storage.set(choices.isAllAutomatic ? nil : choices.propertyList, forKey: storageKey)
        ContentLanguages.invalidate()
    }

    public static func wasAsked(in storage: LibraryStorage) -> Bool {
        return storage.object(forKey: askedKey) as? Bool ?? false
    }

    public static func markAsked(_ asked: Bool = true, in storage: LibraryStorage) {
        storage.set(asked ? true : nil, forKey: askedKey)
    }

    // The app's profiles.

    public static func choices(forProfile id: String) -> ContentLanguageChoices {
        let stored = choices(in: ProfileManager.shared.storage(for: id))
        #if DEBUG
        // `-PTDebugContentLanguages "anime=original/fr;cartoon=fr/auto"`
        // (screenshots, UI tests): a profile that chose nothing has these.
        if stored.isAllAutomatic, let seed = UserDefaults.standard.string(forKey: "PTDebugContentLanguages") {
            return ContentLanguageChoices(debugString: seed)
        }
        #endif
        return stored
    }

    /// Saves a profile's choices and tells the screens (main queue).
    public static func save(_ choices: ContentLanguageChoices, forProfile id: String) {
        save(choices, in: ProfileManager.shared.storage(for: id))
        let post = { NotificationCenter.default.post(name: .contentLanguagesDidChange, object: id) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    /// The active profile's choices.
    public static var active: ContentLanguageChoices {
        return choices(forProfile: ProfileManager.shared.activeID)
    }

    public static func wasAsked(profile id: String) -> Bool {
        return wasAsked(in: ProfileManager.shared.storage(for: id))
    }

    public static func markAsked(profile id: String, _ asked: Bool = true) {
        markAsked(asked, in: ProfileManager.shared.storage(for: id))
    }
}

// MARK: - What a title is

/// What decides a title's type and original language. Kept by IMDb id (a
/// movie's, or the show's for its episodes) in `TitleOriginStore`.
public struct TitleOrigin: Codable, Equatable, Sendable {

    public enum Source: String, Codable, Sendable {
        case cinemeta
        case yts
        case tvmaze
        case tmdb
        /// The title's genres as the app's model holds them (no record yet).
        case genres
        /// Inferred from the first country (`ContentClassifier.language(ofRegion:)`).
        case country

        /// How much a field from this source is trusted (higher wins).
        var rank: Int {
            switch self {
            case .cinemeta, .tvmaze, .tmdb: return 3
            case .yts: return 2
            case .genres, .country: return 1
            }
        }

        var label: String {
            switch self {
            case .cinemeta: return "Cinemeta"
            case .yts: return "YTS"
            case .tvmaze: return "TVMaze"
            case .tmdb: return "TMDB"
            case .genres: return "genres"
            case .country: return "country"
            }
        }
    }

    /// nil: no genre information.
    public var isAnimation: Bool?
    public var animationSource: Source?
    /// ISO 639-1 (or 639-3), normalized (`ContentClassifier.normalizedLanguageCode`).
    public var originalLanguage: String?
    public var languageSource: Source?
    /// ISO 3166 code of the FIRST country listed (the main production
    /// country: Frozen is "United States, Japan").
    public var firstCountry: String?
    /// When it was last noted (seconds since 1970; the store's eviction).
    public var updated: TimeInterval

    public init(isAnimation: Bool? = nil, animationSource: Source? = nil,
                originalLanguage: String? = nil, languageSource: Source? = nil,
                firstCountry: String? = nil, updated: TimeInterval = 0) {
        self.isAnimation = isAnimation
        self.animationSource = animationSource
        self.originalLanguage = originalLanguage
        self.languageSource = languageSource
        self.firstCountry = firstCountry
        self.updated = updated
    }

    /// This origin with `other`'s fields where they are at least as trusted.
    func merged(with other: TitleOrigin) -> TitleOrigin {
        var result = self
        if let animation = other.isAnimation, let source = other.animationSource,
           (result.animationSource?.rank ?? 0) <= source.rank {
            result.isAnimation = animation
            result.animationSource = source
        }
        if let language = other.originalLanguage, let source = other.languageSource,
           (result.languageSource?.rank ?? 0) <= source.rank {
            result.originalLanguage = language
            result.languageSource = source
        }
        if let country = other.firstCountry { result.firstCountry = country }
        result.updated = max(result.updated, other.updated)
        return result
    }

    /// The same facts (the time aside).
    func hasSameFacts(as other: TitleOrigin) -> Bool {
        var a = self, b = other
        a.updated = 0
        b.updated = 0
        return a == b
    }
}

// MARK: - Reading the sources

public extension TitleOrigin {

    /// From a Cinemeta meta (movie or series): IMDb's genres and the first
    /// of its countries ("Japan, United States"). Cinemeta has no language.
    init?(cinemeta meta: [String: Any], now: Date = Date()) {
        let genres = (meta["genres"] as? [String]) ?? (meta["genre"] as? [String])
        let country = (meta["country"] as? String).flatMap(ContentClassifier.firstRegion(ofCountries:))
        guard genres != nil || country != nil else { return nil }
        self.init(updated: now.timeIntervalSince1970)
        if let genres, !genres.isEmpty {
            isAnimation = ContentClassifier.isAnimation(genres: genres)
            animationSource = .cinemeta
        }
        firstCountry = country
    }

    /// From a YTS movie (`list_movies` / `movie_details`): its `language`
    /// (TMDB's code). YTS's genres are not trusted for animation (it tags
    /// live action with effects "Animation": Rampage, Alita), except
    /// "Animation" with Japanese.
    init?(yts movie: [String: Any], now: Date = Date()) {
        let language = ContentClassifier.normalizedLanguageCode(movie["language"] as? String)
        guard let language else { return nil }
        self.init(originalLanguage: language, languageSource: .yts, updated: now.timeIntervalSince1970)
        if language == "ja", let genres = movie["genres"] as? [String], ContentClassifier.isAnimation(genres: genres) {
            isAnimation = true
            animationSource = .yts
        }
    }

    /// From a TVMaze show object: `type` "Animation" or the genre "Anime"
    /// say animation, `language` is a name ("Japanese"). A record built from
    /// Cinemeta's meta (`TVMazeShowDirectory.record(fromCinemeta:)`, no
    /// `id`) has Cinemeta's genres and country instead.
    init?(tvmaze show: [String: Any], now: Date = Date()) {
        self.init(updated: now.timeIntervalSince1970)
        let genres = show["genres"] as? [String] ?? []
        if show["id"] is Int {
            let type = (show["type"] as? String)?.lowercased()
            if type != nil || !genres.isEmpty {
                isAnimation = type == "animation" || ContentClassifier.isAnimation(genres: genres)
                animationSource = .tvmaze
            }
            if let code = ContentClassifier.languageCode(ofEnglishName: show["language"] as? String) {
                originalLanguage = code
                languageSource = .tvmaze
            }
        } else {
            if !genres.isEmpty {
                isAnimation = ContentClassifier.isAnimation(genres: genres)
                animationSource = .cinemeta
            }
            firstCountry = (show["country"] as? String).flatMap(ContentClassifier.firstRegion(ofCountries:))
        }
        guard isAnimation != nil || originalLanguage != nil || firstCountry != nil else { return nil }
    }

    /// From TMDB's `/movie/{id}`, `/tv/{id}` or `/find` answers.
    init?(tmdb details: [String: Any], now: Date = Date()) {
        self.init(updated: now.timeIntervalSince1970)
        if let code = ContentClassifier.normalizedLanguageCode(details["original_language"] as? String) {
            originalLanguage = code
            languageSource = .tmdb
        }
        let genreIDs = (details["genre_ids"] as? [Int]) ?? ((details["genres"] as? [[String: Any]])?.compactMap { $0["id"] as? Int })
        if let genreIDs, !genreIDs.isEmpty {
            isAnimation = genreIDs.contains(16)
            animationSource = .tmdb
        }
        if let country = (details["origin_country"] as? [String])?.first, country.count == 2 {
            firstCountry = country.uppercased()
        }
        guard isAnimation != nil || originalLanguage != nil || firstCountry != nil else { return nil }
    }
}

// MARK: - The rules

/// A title's type and original language from its origin (pure).
public enum ContentClassifier {

    /// Genres that say animation: IMDb's "Animation", TVMaze's "Anime".
    public static func isAnimation(genres: [String]) -> Bool {
        return genres.contains { genre in
            let key = genre.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
            return key == "animation" || key == "anime" || key == "animated" || key == "animacion"
        }
    }

    /// The type: animation and Japanese (by its original language or its
    /// first country) → anime; animation otherwise, origin unknown included
    /// → cartoon; not animation or no genre information → movie.
    /// `fallbackGenres`: the model's genres, read only while the store has
    /// no record of the title at all. A record without genres (YTS's
    /// language alone) means the model's genres may be YTS's own, which tag
    /// live action « Animation » (Rampage): the title stays live action
    /// until Cinemeta or TVMaze say otherwise.
    public static func classify(_ origin: TitleOrigin?, fallbackGenres: [String] = []) -> ContentType {
        return classification(origin, fallbackGenres: fallbackGenres).type
    }

    /// The type and what it was read from, for the log:
    /// "Animation (Cinemeta) · ja (YTS) · first country JP".
    public static func classification(_ origin: TitleOrigin?, fallbackGenres: [String] = []) -> (type: ContentType, why: String) {
        var isAnimation = origin?.isAnimation
        var source = origin?.animationSource
        if origin == nil, !fallbackGenres.isEmpty {
            isAnimation = self.isAnimation(genres: fallbackGenres)
            source = .genres
        }
        guard let animation = isAnimation, let source else { return (.movie, "no genre information") }
        guard animation else { return (.movie, "not animation (\(source.label))") }
        var why = ["Animation (\(source.label))"]
        if let language = origin?.originalLanguage { why.append("\(language) (\(origin?.languageSource?.label ?? "?"))") }
        if let country = origin?.firstCountry { why.append("first country \(country)") }
        let japanese = origin?.originalLanguage == "ja" || origin?.firstCountry == "JP"
        if origin?.originalLanguage == nil && origin?.firstCountry == nil { why.append("origin unknown") }
        return (japanese ? .anime : .cartoon, why.joined(separator: " · "))
    }

    /// The original language: the sources' (YTS, TVMaze, TMDB), else the
    /// language of the first country when it has only one in practice
    /// (`singleLanguageRegions`); nil otherwise: « VO » is then Automatic.
    public static func originalLanguage(of origin: TitleOrigin?) -> (code: String, source: TitleOrigin.Source)? {
        if let code = origin?.originalLanguage { return (code, origin?.languageSource ?? .country) }
        if let region = origin?.firstCountry, let code = confidentLanguage(ofRegion: region) { return (code, .country) }
        return nil
    }

    /// Why a title's original language is unknown (the log).
    public static func unknownLanguageReason(of origin: TitleOrigin?) -> String {
        if let region = origin?.firstCountry { return "first country \(region) has several languages, no source gave one" }
        return "no source gave its language or country"
    }

    /// Countries whose titles are almost all in one language: only these
    /// stand in for a title's original language. Belgium, Switzerland,
    /// India, Canada… are left out (a Belgian film is French or Dutch).
    public static let singleLanguageRegions: Set<String> = [
        "US", "GB", "IE", "AU", "NZ",
        "FR", "DE", "AT", "IT", "ES", "PT", "NL", "DK", "SE", "NO", "IS", "FI",
        "PL", "CZ", "SK", "HU", "RO", "BG", "GR", "HR", "SI", "RS", "LT", "LV", "EE", "RU", "TR",
        "JP", "KR", "CN", "TW", "HK", "TH", "VN", "ID", "IR", "IL", "EG",
        "BR", "MX", "AR", "CL", "CO", "PE", "UY", "VE", "CU",
    ]

    /// `language(ofRegion:)` for a single-language country only.
    public static func confidentLanguage(ofRegion region: String) -> String? {
        guard singleLanguageRegions.contains(region.uppercased()) else { return nil }
        return language(ofRegion: region)
    }

    /// A source's language code, normalized: TMDB's "xx" (no language) →
    /// nil, "cn" (Cantonese) → "zh", "sh" → "sr", the deprecated codes, and
    /// Norwegian Bokmål / Nynorsk → "no" (the pickers' code).
    public static func normalizedLanguageCode(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        let primary = String(raw.prefix { $0 != "-" && $0 != "_" })
        guard (2...3).contains(primary.count), primary.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        if ["xx", "und", "zxx", "mul"].contains(primary) { return nil }
        let aliases = ["cn": "zh", "sh": "sr", "iw": "he", "in": "id", "ji": "yi", "mo": "ro", "nb": "no", "nn": "no"]
        return aliases[primary] ?? primary
    }

    /// "Japanese" → "ja" (TVMaze's names).
    public static func languageCode(ofEnglishName name: String?) -> String? {
        return HomeLanguages.code(ofEnglishName: name?.trimmingCharacters(in: .whitespaces)).flatMap(normalizedLanguageCode)
    }

    /// The first country of Cinemeta's list ("Japan, United States" → "JP").
    public static func firstRegion(ofCountries countries: String) -> String? {
        guard let first = countries.split(separator: ",").first else { return nil }
        return regionCode(ofCountryName: String(first))
    }

    /// An English country name → ISO 3166 code; IMDb's spellings that are
    /// not Foundation's, and historical countries, included.
    public static func regionCode(ofCountryName name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        return regionsByName[key]
    }

    private static let regionsByName: [String: String] = {
        let english = Locale(identifier: "en_US_POSIX")
        var map: [String: String] = [:]
        for region in Locale.Region.isoRegions {
            let id = region.identifier
            guard id.count == 2, id.allSatisfy({ $0.isLetter }),
                  let name = english.localizedString(forRegionCode: id)?.lowercased() else { continue }
            map[name] = id
        }
        let aliases: [String: String] = [
            "usa": "US", "us": "US", "uk": "GB", "united kingdom": "GB", "great britain": "GB", "england": "GB",
            "china": "CN", "czech republic": "CZ", "turkey": "TR", "korea": "KR", "republic of korea": "KR",
            "west germany": "DE", "east germany": "DE", "soviet union": "RU", "ussr": "RU",
            "yugoslavia": "RS", "federal republic of yugoslavia": "RS", "serbia and montenegro": "RS",
            "czechoslovakia": "CZ", "hong kong sar china": "HK", "macau": "MO", "macao": "MO",
            "ivory coast": "CI", "burma": "MM", "russia": "RU", "vietnam": "VN", "iran": "IR",
        ]
        for (name, code) in aliases where map[name] == nil { map[name] = code }
        return map
    }()

    /// A country's main language ("JP" → "ja", "BE" → "nl", "CH" → "de").
    public static func language(ofRegion region: String) -> String? {
        let maximal = Locale.Language(identifier: "und-" + region.uppercased()).maximalIdentifier
        let code = Locale.Language(identifier: maximal).languageCode?.identifier
        guard let code, code != "und" else { return nil }
        return normalizedLanguageCode(code)
    }
}

// MARK: - The store

/// The titles' origins, by IMDb id, kept on disk (Caches): the players,
/// Continue Watching and the downloads know a title by its id only.
/// Filled by the metadata the app loads anyway (`note`), and asked for when
/// missing (`ensureOrigin`). Thread-safe.
public final class TitleOriginStore {

    public static let shared = TitleOriginStore(
        // Not under the unit tests: they would write into the user's caches.
        fileURL: NSClassFromString("XCTestCase") != nil ? nil
            : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("popcornkit-title-origins.json"))

    /// Titles kept (the oldest noted go first).
    static let capacity = 4000

    private let fileURL: URL?
    private let lock = NSLock()
    private var origins: [String: TitleOrigin] = [:]
    private var loaded = false
    private var saveScheduled = false
    private let saveQueue = DispatchQueue(label: "PopcornKit.TitleOriginStore.save", qos: .utility)

    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public func origin(for imdbID: String) -> TitleOrigin? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return origins[imdbID]
    }

    /// Adds what a source said of a title (`TitleOrigin(cinemeta:)`…).
    /// True when that changed what is known.
    @discardableResult
    public func note(_ origin: TitleOrigin?, for imdbID: String) -> Bool {
        guard let origin, imdbID.hasPrefix("tt") else { return false }
        lock.lock()
        loadLocked()
        let before = origins[imdbID]
        let after = before.map { $0.merged(with: origin) } ?? origin
        origins[imdbID] = after
        let changed = before.map { !$0.hasSameFacts(as: after) } ?? true
        // Only new facts are written (a list read again writes nothing).
        let schedule = changed && !saveScheduled && fileURL != nil
        if schedule { saveScheduled = true }
        lock.unlock()
        if changed { ContentLanguages.invalidate() }
        if schedule {
            saveQueue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.save() }
        }
        return changed
    }

    /// Forgets everything (tests).
    public func removeAll() {
        lock.lock(); origins = [:]; loaded = true; lock.unlock()
        ContentLanguages.invalidate()
    }

    /// Writes the file now.
    public func save() {
        lock.lock()
        saveScheduled = false
        var snapshot = origins
        lock.unlock()
        guard let url = fileURL else { return }
        if snapshot.count > TitleOriginStore.capacity {
            for (key, _) in snapshot.sorted(by: { $0.value.updated < $1.value.updated }).prefix(snapshot.count - TitleOriginStore.capacity) {
                snapshot[key] = nil
            }
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: TitleOrigin].self, from: data) else { return }
        origins = stored.merging(origins) { stored, noted in stored.merged(with: noted) }
    }

    // MARK: Asking when missing

    /// Asks the metadata of a title whose origin lacks its genres: the
    /// TVMaze record of a show (Cinemeta's when TVMaze doesn't know it),
    /// Cinemeta's meta of a movie (and of a show without a country). Calls
    /// back on the main queue, true when something new was learnt.
    public func ensureOrigin(imdbID: String, isShow: Bool, completion: ((Bool) -> Void)? = nil) {
        let done: (Bool) -> Void = { changed in DispatchQueue.main.async { completion?(changed) } }
        guard imdbID.hasPrefix("tt") else { return done(false) }
        let known = origin(for: imdbID)
        if known?.isAnimation != nil, known?.originalLanguage != nil || known?.firstCountry != nil { return done(false) }
        let cinemeta: (Bool) -> Void = { [weak self] changedBefore in
            CinemetaClient.meta(isShow ? .series : .movie, imdbId: imdbID) { meta in
                let changed = meta.map { self?.note(TitleOrigin(cinemeta: $0), for: imdbID) ?? false } ?? false
                done(changedBefore || changed)
            }
        }
        guard isShow else { return cinemeta(false) }
        TVMazeShowDirectory.shared.record(imdbID) { [weak self] lookup in
            var changed = false
            if case .known(let record) = lookup { changed = self?.note(TitleOrigin(tvmaze: record), for: imdbID) ?? false }
            let now = self?.origin(for: imdbID)
            if now?.isAnimation == nil || (now?.originalLanguage == nil && now?.firstCountry == nil) {
                cinemeta(changed)
            } else {
                done(changed)
            }
        }
    }
}

// MARK: - A title's plan

/// What a profile's choice means for one title.
public struct TitleLanguagePlan: Equatable, Sendable {

    public enum AudioReason: Equatable, Sendable {
        /// The type's audio is Automatic.
        case automatic
        /// « VO », the original language known (from that source).
        case original(TitleOrigin.Source)
        /// « VO », but the original language is unknown: Automatic.
        case originalUnknown
        /// A language chosen for the type.
        case chosen
    }

    public enum Subtitles: Equatable, Sendable {
        case automatic
        case off
        case language(String)
    }

    public let imdbID: String
    public let type: ContentType
    /// What the type was read from (the log).
    public let typeReason: String
    public let choice: ContentLanguageChoice
    /// The title's original language when known.
    public let originalLanguage: String?
    /// The audio language this title must play in; nil: the profile's
    /// automatic rule (its setting, else its learnt language).
    public let audio: String?
    public let audioReason: AudioReason
    public let subtitles: Subtitles

    public init(imdbID: String, choices: ContentLanguageChoices, origin: TitleOrigin?,
                fallbackGenres: [String] = [], forcedType: ContentType? = nil) {
        let classification = ContentClassifier.classification(origin, fallbackGenres: fallbackGenres)
        let type = forcedType ?? classification.type
        let choice = choices[type]
        let original = ContentClassifier.originalLanguage(of: origin)
        self.imdbID = imdbID
        self.type = type
        self.typeReason = forcedType != nil ? "forced by -PTDebugContentType" : classification.why
        self.choice = choice
        self.originalLanguage = original?.code
        switch choice.audio {
        case .automatic:
            audio = nil
            audioReason = .automatic
        case .original:
            audio = original?.code
            audioReason = original.map { .original($0.source) } ?? .originalUnknown
        case .language(let code):
            audio = code
            audioReason = .chosen
        }
        switch choice.subtitles {
        case .automatic: subtitles = .automatic
        case .off: subtitles = .off
        case .language(let code): subtitles = .language(code)
        }
    }

    /// Nothing chosen for this title's type.
    public var isAutomatic: Bool { audio == nil && subtitles == .automatic }
}

// MARK: - The title being looked at or played

/// The title whose page is open or which plays (`focus`), and its plan for
/// the active profile (`focusedPlan`): what `AudioLanguagePreference.current`
/// and the apps' players read. Thread-safe.
public enum ContentLanguages {

    /// A title as the store knows it.
    public struct Title: Equatable, Sendable {
        /// The movie's, or the show's for an episode.
        public var imdbID: String
        public var isShow: Bool
        /// What the log names it by.
        public var name: String
        /// The model's genres (used only while the store knows nothing).
        public var genres: [String]

        public init(imdbID: String, isShow: Bool, name: String, genres: [String] = []) {
            self.imdbID = imdbID
            self.isShow = isShow
            self.name = name
            self.genres = genres
        }

        /// A movie, a show, or an episode's show (its id from the episode's
        /// own when the show is missing: "tt0903747-s1e2"); nil otherwise.
        public init?(media: Media) {
            if let movie = media as? Movie {
                self.init(imdbID: movie.id, isShow: false, name: movie.title, genres: movie.genres)
            } else if let show = media as? Show {
                self.init(imdbID: show.id, isShow: true, name: show.title, genres: show.genres)
            } else if let episode = media as? Episode {
                if let show = episode.show, show.id.hasPrefix("tt") {
                    self.init(imdbID: show.id, isShow: true, name: "\(show.title) S\(episode.season)E\(episode.episode)",
                              genres: show.genres)
                } else if episode.id.hasPrefix("tt"), let dash = episode.id.firstIndex(of: "-") {
                    self.init(imdbID: String(episode.id[..<dash]), isShow: true, name: episode.title)
                } else {
                    return nil
                }
            } else {
                return nil
            }
            guard imdbID.hasPrefix("tt") else { return nil }
        }
    }

    /// Where the plans read (tests swap it).
    public struct Environment {
        public var activeProfileID: () -> String
        public var choices: (_ profileID: String) -> ContentLanguageChoices
        public var origins: TitleOriginStore
        /// `-PTDebugContentType <movie|cartoon|anime>` (DEBUG): every title is that type.
        public var forcedType: () -> ContentType?

        public init(activeProfileID: @escaping () -> String, choices: @escaping (String) -> ContentLanguageChoices,
                    origins: TitleOriginStore, forcedType: @escaping () -> ContentType? = { nil }) {
            self.activeProfileID = activeProfileID
            self.choices = choices
            self.origins = origins
            self.forcedType = forcedType
        }

        public static let standard = Environment(
            activeProfileID: { ProfileManager.shared.activeID },
            choices: { ContentLanguageSettings.choices(forProfile: $0) },
            origins: .shared,
            forcedType: { ContentLanguages.debugForcedType })
    }

    public static var environment: Environment {
        get { lock.lock(); defer { lock.unlock() }; return _environment }
        set { lock.lock(); _environment = newValue; generation &+= 1; cache = nil; lock.unlock() }
    }

    /// `-PTDebugContentType <movie|cartoon|anime>` (DEBUG builds only).
    public static var debugForcedType: ContentType? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "PTDebugContentType").flatMap { ContentType(rawValue: $0.lowercased()) }
        #else
        return nil
        #endif
    }

    /// `-PTDebugContentType` given (any value, "log" too): the players log
    /// what each title's type was read from.
    public static var logsClassification: Bool {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "PTDebugContentType") != nil
        #else
        return false
        #endif
    }

    // MARK: Focus

    /// The title whose page opened or which starts playing.
    public static func focus(on media: Media) {
        guard let title = Title(media: media) else { return }
        focus(on: title)
    }

    public static func focus(on title: Title) {
        lock.lock()
        if _focused != title {
            _focused = title
            generation &+= 1
            cache = nil
        }
        lock.unlock()
    }

    /// A player starts `title` (nil: a title without an IMDb id, played
    /// Automatic). It is also focused; a page opened later (another Mac
    /// window) moves the focus but not what the players read
    /// (`playingPlan`), until the next player starts.
    public static func beginPlaying(_ title: Title?) {
        lock.lock()
        _playing = .some(title)
        if let title { _focused = title }
        generation &+= 1
        cache = nil
        playingCache = nil
        lock.unlock()
    }

    /// No title (tests).
    public static func clearFocus() {
        lock.lock(); _focused = nil; _playing = nil; generation &+= 1; cache = nil; playingCache = nil; lock.unlock()
    }

    public static var focused: Title? {
        lock.lock(); defer { lock.unlock() }
        return _focused
    }

    /// The focused title's plan for the active profile; nil without a focus.
    /// Cached until the focus, the profile, its choices or the title's
    /// origin change (read on every comparison of a release sort).
    public static var focusedPlan: TitleLanguagePlan? {
        return cachedPlan(playing: false)
    }

    /// The plan of the title the last player started (`beginPlaying`): what
    /// the players' track and subtitle picks read, whatever page opened
    /// since. The focused title's before any player started.
    public static var playingPlan: TitleLanguagePlan? {
        return cachedPlan(playing: true)
    }

    private static func cachedPlan(playing: Bool) -> TitleLanguagePlan? {
        lock.lock()
        let target: Title?
        if playing, let started = _playing { target = started } else { target = _focused }
        guard let title = target else { lock.unlock(); return nil }
        let environment = _environment
        let generation = self.generation
        let known = playing ? playingCache : cache
        lock.unlock()
        let profileID = environment.activeProfileID()
        if let known, known.generation == generation, known.profileID == profileID, known.title == title {
            return known.plan
        }
        let plan = makePlan(for: title, profileID: profileID, environment: environment)
        lock.lock()
        if self.generation == generation {
            let entry = Cache(generation: generation, profileID: profileID, title: title, plan: plan)
            if playing { playingCache = entry } else { cache = entry }
        }
        lock.unlock()
        return plan
    }

    /// A title's plan for the active profile, focused or not.
    public static func plan(for title: Title) -> TitleLanguagePlan {
        let environment = self.environment
        return makePlan(for: title, profileID: environment.activeProfileID(), environment: environment)
    }

    public static func plan(for media: Media) -> TitleLanguagePlan? {
        return Title(media: media).map { plan(for: $0) }
    }

    /// The audio language a title must play in for the active profile (nil:
    /// the profile's automatic rule). Quick when nothing is chosen.
    public static func audioOverride(forTitle imdbID: String, isShow: Bool) -> String? {
        let environment = self.environment
        let profileID = environment.activeProfileID()
        let choices = environment.choices(profileID)
        guard !choices.isAllAutomatic || environment.forcedType() != nil else { return nil }
        if let focused = focused, focused.imdbID == imdbID { return focusedPlan?.audio }
        let title = Title(imdbID: imdbID, isShow: isShow, name: imdbID)
        return makePlan(for: title, profileID: profileID, environment: environment, choices: choices).audio
    }

    /// Asks the metadata of a title the store doesn't know well enough;
    /// `completion` (main queue) says whether its plan may have changed.
    /// Nothing is asked while the active profile keeps every type Automatic
    /// (and no `-PTDebugContentType`): its plans change nothing then.
    public static func ensureOrigin(of title: Title, completion: ((Bool) -> Void)? = nil) {
        let environment = self.environment
        guard isInUse(environment) else {
            if let completion { DispatchQueue.main.async { completion(false) } }
            return
        }
        environment.origins.ensureOrigin(imdbID: title.imdbID, isShow: title.isShow, completion: completion)
    }

    /// The active profile chose something, or a debug argument asks for the types.
    public static var isInUse: Bool { isInUse(environment) }

    private static func isInUse(_ environment: Environment) -> Bool {
        return !environment.choices(environment.activeProfileID()).isAllAutomatic
            || environment.forcedType() != nil || logsClassification
    }

    /// Something a plan reads changed (a profile's choices, an origin).
    public static func invalidate() {
        lock.lock(); generation &+= 1; cache = nil; lock.unlock()
    }

    // MARK: State

    private static func makePlan(for title: Title, profileID: String, environment: Environment,
                                 choices: ContentLanguageChoices? = nil) -> TitleLanguagePlan {
        let origin = environment.origins.origin(for: title.imdbID)
        let plan = TitleLanguagePlan(imdbID: title.imdbID,
                                     choices: choices ?? environment.choices(profileID),
                                     origin: origin,
                                     fallbackGenres: title.genres,
                                     forcedType: environment.forcedType())
        if plan.audioReason == .originalUnknown { logUnknownOriginal(of: title, origin: origin) }
        return plan
    }

    /// « VO » fell back to Automatic: said once per title (the release
    /// ranking reads plans many times).
    private static func logUnknownOriginal(of title: Title, origin: TitleOrigin?) {
        lock.lock()
        let first = loggedUnknownOriginals.insert(title.imdbID).inserted
        lock.unlock()
        guard first else { return }
        print("[Languages] \(title.name) (\(title.imdbID)): original version unknown → automatic (\(ContentClassifier.unknownLanguageReason(of: origin)))")
    }

    /// The titles whose unknown original language was logged.
    public static var loggedUnknownOriginalIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return loggedUnknownOriginals
    }

    private struct Cache {
        let generation: UInt64
        let profileID: String
        let title: Title
        let plan: TitleLanguagePlan
    }

    private static let lock = NSLock()
    private static var _environment = Environment.standard
    private static var _focused: Title?
    /// nil: no player started; .some(nil): one played a title without an id.
    private static var _playing: Title??
    private static var generation: UInt64 = 0
    private static var cache: Cache?
    private static var playingCache: Cache?
    private static var loggedUnknownOriginals: Set<String> = []
}
