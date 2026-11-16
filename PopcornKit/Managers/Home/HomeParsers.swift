import Foundation

/// The raw JSON of each source → `HomeEntry`. Pure: `now` is a parameter,
/// nothing is read from the outside. Only what does not depend on the
/// user's settings is decided here (an episode without an IMDb id, a CAM
/// release); languages, ratings and popularity are kept with the entry and
/// filtered by `HomeBuilder`, so a change of settings needs no request.
///
/// nil means "not an answer of this source" (an error page, another JSON):
/// the loader counts it as a failure. [] is an answer.
enum HomeParse {

    /// Longest summary kept (a card shows three or four lines).
    static let summaryLimit = 420

    static func entries(_ data: Data, parser: HomeSource.Parser, now: Date) -> [HomeEntry]? {
        switch parser {
        case .cinemeta(let kind): return cinemetaCatalogue(data, kind: kind, now: now)
        case .cinemetaMeta(let kind): return cinemetaMeta(data, kind: kind, now: now)
        case .yts: return ytsMovies(data)
        case .tvmaze: return tvmazeSchedule(data)
        case .apibay(let kind): return apibayTop(data, kind: kind)
        }
    }

    // MARK: - Cinemeta

    /// A catalog: {"metas": […]} (top, imdbRating, year, genre) or
    /// {"metasDetailed": […]} (calendar-videos, last-videos). Entries without
    /// a poster are bare stubs (the "year" catalog lists announced titles) and
    /// are left out. A series keeps the episodes around `now` only: the
    /// catalog carries every episode, 84 % of its weight.
    static func cinemetaCatalogue(_ data: Data, kind: HomeItem.Kind, now: Date) -> [HomeEntry]? {
        guard let root = object(data) as? [String: Any],
              let metas = (root["metas"] ?? root["metasDetailed"]) as? [Any] else { return nil }
        var seen = Set<String>()
        return metas.compactMap { cinemetaEntry($0 as? [String: Any], kind: kind, now: now) }
            .filter { seen.insert($0.item.imdbId).inserted }
    }

    /// One meta: {"meta": {…}}. [] when Cinemeta does not know the id ({} or
    /// an empty meta).
    static func cinemetaMeta(_ data: Data, kind: HomeItem.Kind, now: Date) -> [HomeEntry]? {
        guard let root = object(data) as? [String: Any] else { return nil }
        guard let entry = cinemetaEntry(root["meta"] as? [String: Any], kind: kind, now: now) else { return [] }
        return [entry]
    }

    static func cinemetaEntry(_ meta: [String: Any]?, kind: HomeItem.Kind, now: Date) -> HomeEntry? {
        guard let meta = meta,
              let imdbId = string(meta["imdb_id"]) ?? string(meta["id"]), isImdbId(imdbId),
              let name = string(meta["name"]),
              let poster = string(meta["poster"]) else { return nil }
        // A series listed in a movie catalog (it happens for specials) stays a series.
        let actualKind: HomeItem.Kind
        switch string(meta["type"]) {
        case "series": actualKind = .show
        case "movie": actualKind = .movie
        default: actualKind = kind
        }
        let rating = double(meta["imdbRating"]).flatMap { $0 > 0 ? min($0, 10) : nil }
        let trailers = (meta["trailerStreams"] as? [[String: Any]])?.compactMap { string($0["ytId"]) }
            ?? (meta["trailers"] as? [[String: Any]])?.compactMap { string($0["source"]) } ?? []
        let item = HomeItem(
            imdbId: imdbId, kind: actualKind, title: name.removingHtmlEncoding,
            year: leadingYear(string(meta["releaseInfo"]) ?? string(meta["year"])),
            rating: rating,
            genres: strings(meta["genres"] ?? meta["genre"]),
            summary: summary(string(meta["description"])),
            runtimeMinutes: leadingInt(string(meta["runtime"])).flatMap { $0 > 0 ? $0 : nil },
            posterURL: URL(string: HomeArtwork.larger(poster)),
            backdropURL: string(meta["background"]).flatMap { URL(string: HomeArtwork.larger($0)) },
            logoURL: string(meta["logo"]).flatMap(URL.init(string:)),
            trailerCode: trailers.first,
            date: CatalogDates.date(from: string(meta["released"])))
        var entry = HomeEntry(item: item)
        if actualKind == .show, let videos = meta["videos"] as? [[String: Any]] {
            entry.episodes = episodes(cinemetaVideos: videos, now: now)
        }
        return entry
    }

    /// How far back and ahead of the fetch a series' episodes are kept, and
    /// how many: enough for "aired in the last two weeks", "next week", and
    /// a cache that stays right for the days it may be shown.
    static let episodeWindow: (past: TimeInterval, future: TimeInterval, count: Int) = (45 * 86_400, 21 * 86_400, 12)

    /// The episodes of a Cinemeta `videos` list around `now`, oldest first
    /// (specials — season 0 — and undated episodes left out).
    static func episodes(cinemetaVideos videos: [[String: Any]], now: Date) -> [HomeEpisode] {
        let from = now.addingTimeInterval(-episodeWindow.past), to = now.addingTimeInterval(episodeWindow.future)
        let dated: [HomeEpisode] = videos.compactMap { video in
            guard let season = int(video["season"]), season > 0, season < HomeBuilder.Rules.yearNumberedSeason,
                  let number = int(video["episode"]) ?? int(video["number"]), number > 0,
                  let aired = CatalogDates.date(from: string(video["released"]) ?? string(video["firstAired"])),
                  aired >= from, aired <= to else { return nil }
            return HomeEpisode(season: season, number: number,
                               title: string(video["name"]) ?? string(video["title"]),
                               stillURL: string(video["thumbnail"]).flatMap(URL.init(string:)),
                               airDate: aired)
        }
        let sorted = dated.sorted {
            let a = $0.airDate ?? .distantPast, b = $1.airDate ?? .distantPast
            return a != b ? a < b : ($0.season, $0.number) < ($1.season, $1.number)
        }
        // The latest aired ones and the next ones, not a whole season dropped at once.
        let aired = sorted.filter { ($0.airDate ?? .distantPast) <= now }
        let upcoming = sorted.filter { ($0.airDate ?? .distantPast) > now }
        let keptUpcoming = upcoming.prefix(episodeWindow.count / 3)
        return Array(aired.suffix(episodeWindow.count - keptUpcoming.count)) + keptUpcoming
    }

    // MARK: - YTS

    /// list_movies.json: {"status":"ok","data":{"movie_count":…,"movies":[…]}}.
    /// A page past the end, or a year without a movie yet, has no "movies"
    /// key: an empty answer.
    static func ytsMovies(_ data: Data) -> [HomeEntry]? {
        guard let root = object(data) as? [String: Any], string(root["status"]) == "ok",
              let payload = root["data"] as? [String: Any] else { return nil }
        var seen = Set<String>()
        return ((payload["movies"] as? [Any]) ?? []).compactMap { ytsEntry($0 as? [String: Any]) }
            .filter { seen.insert($0.item.imdbId).inserted }
    }

    static func ytsEntry(_ movie: [String: Any]?) -> HomeEntry? {
        // YTS names some films by their original title ("title") and gives
        // the English one beside it: the English one, as the rest of the app.
        guard let movie = movie, let imdbId = string(movie["imdb_code"]), isImdbId(imdbId),
              let title = string(movie["title_english"]) ?? string(movie["title"]) else { return nil }
        let torrents = (movie["torrents"] as? [[String: Any]]) ?? []
        let qualities = Set(torrents.compactMap { string($0["quality"]) })
        let added = double(movie["date_uploaded_unix"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        // The covers are on a host some ISPs block: through the image proxy,
        // like everywhere else in the app.
        let cover = string(movie["large_cover_image"]) ?? string(movie["medium_cover_image"])
        let background = string(movie["background_image_original"]) ?? string(movie["background_image"])
        // Where the image loader goes when the proxy has no answer for a
        // cover: metahub's artwork of the same title.
        ArtworkAlternates.register(imdbID: imdbId, poster: ImageProxy.proxied(cover), backdrop: ImageProxy.proxied(background))
        let item = HomeItem(
            imdbId: imdbId, kind: .movie, title: title.removingHtmlEncoding,
            year: int(movie["year"]).flatMap { $0 > 0 ? $0 : nil },
            rating: double(movie["rating"]).flatMap { $0 > 0 ? min($0, 10) : nil },
            genres: strings(movie["genres"]),
            summary: summary(string(movie["summary"]) ?? string(movie["description_full"])),
            runtimeMinutes: int(movie["runtime"]).flatMap { $0 > 0 ? $0 : nil },
            posterURL: ImageProxy.proxied(cover).flatMap(URL.init(string:)),
            backdropURL: ImageProxy.proxied(background).flatMap(URL.init(string:)),
            trailerCode: string(movie["yt_trailer_code"]),
            badges: qualities.contains("2160p") ? [.uhd] : [],
            date: added)
        return HomeEntry(item: item, language: string(movie["language"])?.lowercased(), qualities: qualities.count)
    }

    // MARK: - TVMaze

    /// The least popular shows kept (TVMaze's weight, 0…100): the shelves
    /// ask for 90 and more, the rest of the kept ones give titles and
    /// posters to the Top 48 h. Below, a day is mostly local news.
    static let tvmazeMinimumWeight = 80

    /// schedule?country=US&date= (the show under "show") and
    /// schedule/web?date= (under "_embedded.show"): one entry per episode.
    /// Left out: no IMDb id (the key of everything here), specials (no
    /// number), the soaps numbered by year (season 2026), no air time.
    ///
    /// Artwork: TVMaze's own posters are its "original_untouched" files,
    /// 0.5 to 2 MB each (its "medium" ones are 210 px wide): the show's
    /// poster and backdrop are metahub's, by IMDb id (44–114 KB; 32 posters
    /// out of 32 for the popular shows scheduled on 2026-11-12/13). The
    /// episode's still is TVMaze's when it has one (300–500 KB): metahub's
    /// only exists for half of these episodes.
    static func tvmazeSchedule(_ data: Data) -> [HomeEntry]? {
        guard let episodes = object(data) as? [Any] else { return nil }
        return episodes.compactMap { tvmazeEntry($0 as? [String: Any]) }
    }

    static func tvmazeEntry(_ episode: [String: Any]?) -> HomeEntry? {
        guard let episode = episode,
              let show = (episode["show"] ?? (episode["_embedded"] as? [String: Any])?["show"]) as? [String: Any],
              let imdbId = string((show["externals"] as? [String: Any])?["imdb"]), isImdbId(imdbId),
              let name = string(show["name"]),
              let season = int(episode["season"]), season > 0, season < HomeBuilder.Rules.yearNumberedSeason,
              let number = int(episode["number"]), number > 0,
              let aired = CatalogDates.date(from: string(episode["airstamp"])) else { return nil }
        let weight = int(show["weight"]) ?? 0
        guard weight >= tvmazeMinimumWeight else { return nil }
        let still = (episode["image"] as? [String: Any]).flatMap { string($0["original"]) ?? string($0["medium"]) }
        let item = HomeItem(
            imdbId: imdbId, kind: .show, title: name.removingHtmlEncoding,
            year: leadingYear(string(show["premiered"])),
            rating: double((show["rating"] as? [String: Any])?["average"]).flatMap { $0 > 0 ? min($0, 10) : nil },
            genres: strings(show["genres"]),
            summary: summary(string(show["summary"])?.strippedOfHtml),
            runtimeMinutes: (int(episode["runtime"]) ?? int(show["averageRuntime"]) ?? int(show["runtime"])).flatMap { $0 > 0 ? $0 : nil },
            posterURL: HomeArtwork.poster(imdbId),
            backdropURL: HomeArtwork.backdrop(imdbId),
            episode: HomeEpisode(season: season, number: number, title: string(episode["name"]),
                                 stillURL: still.flatMap(URL.init(string:)), airDate: aired),
            date: aired)
        return HomeEntry(item: item, language: HomeLanguages.code(ofEnglishName: string(show["language"])),
                         weight: weight, showType: string(show["type"]))
    }

    // MARK: - apibay

    /// A precompiled list (top 100, top 100 of the last 48 hours): one entry
    /// per IMDb id, most seeded first, the seeders of its releases summed.
    /// Theater recordings and screeners (`VideoTags.cam`) and releases
    /// without an IMDb id are left out. The entry has no title yet: the
    /// builder takes it, with the poster, from the lists already loaded.
    static func apibayTop(_ data: Data, kind: HomeItem.Kind) -> [HomeEntry]? {
        guard let releases = object(data) as? [Any] else { return nil }
        struct Group {
            var seeders = 0
            var bestSeeders = -1
            var bestName = ""
            var tags: VideoTags = []
            var uhd = false
            var added: Double = 0
            var bestLanguages: Set<String>?
        }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for case let release as [String: Any] in releases {
            guard let name = string(release["name"]), let imdbId = string(release["imdb"]), isImdbId(imdbId) else { continue }
            let tags = VideoTags.parse(name)
            guard !tags.contains(.cam) else { continue }
            // A hostile or broken mirror's huge counts must not overflow the sum.
            let seeders = Int(min(max(double(release["seeders"]) ?? 0, 0), 10_000_000))
            if groups[imdbId] == nil { order.append(imdbId) }
            var group = groups[imdbId] ?? Group()
            group.seeders += seeders
            if seeders > group.bestSeeders {
                group.bestSeeders = seeders
                group.bestName = name
                group.bestLanguages = HomeLanguages.named(inRelease: name)
            }
            group.tags.formUnion(tags)
            let category = int(release["category"])
            if category == 211 || category == 212 || ReleaseName.tokens(name).contains("2160") { group.uhd = true }
            group.added = max(group.added, double(release["added"]) ?? 0)
            groups[imdbId] = group
        }
        let entries: [HomeEntry] = order.compactMap { imdbId in
            guard let group = groups[imdbId] else { return nil }
            var badges: [HomeBadge] = []
            if group.uhd { badges.append(.uhd) }
            if group.tags.contains(.dolbyVision) { badges.append(.dolbyVision) }
            if !group.tags.isDisjoint(with: [.hdr10, .hdr10Plus, .hlg]) { badges.append(.hdr) }
            if group.tags.contains(.atmos) { badges.append(.atmos) }
            let item = HomeItem(imdbId: imdbId, kind: kind, title: "", badges: badges,
                                date: group.added > 0 ? Date(timeIntervalSince1970: group.added) : nil)
            return HomeEntry(item: item, seeders: group.seeders, releaseName: group.bestName,
                             releaseLanguages: group.bestLanguages?.sorted())
        }
        // Stable: equal seeders keep the list's order.
        return entries.enumerated()
            .sorted { ($0.element.seeders ?? 0) != ($1.element.seeders ?? 0) ? ($0.element.seeders ?? 0) > ($1.element.seeders ?? 0) : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The title a card would show names the release: apibay files some
    /// releases under another title's IMDb id. True when the release spells
    /// the title ("S W A T Exiles" for "SWAT Exiles") or has most of its
    /// words (all of them for a one or two word title; "Law.and.Order" for
    /// "Law & Order"), and, for a movie whose release names a year, that
    /// year is the title's within one.
    static func names(_ releaseName: String, title: String, year: Int?, kind: HomeItem.Kind) -> Bool {
        let fold: (String) -> [String] = { text in
            let plain = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            return ReleaseName.tokens(plain).filter { !["the", "a", "an", "and", "of"].contains($0) }
        }
        let wanted = fold(title), tokens = fold(releaseName)
        guard !wanted.isEmpty else { return false }
        let present = Set(tokens)
        let found = wanted.filter(present.contains).count
        let hasWords = wanted.count <= 2 ? found == wanted.count : found * 3 >= wanted.count * 2
        let spelling = HomeBuilder.titleKey(title)
        let spelled = spelling.count >= 4 && HomeBuilder.titleKey(releaseName).contains(spelling)
        guard hasWords || spelled else { return false }
        if kind == .movie, let year = year {
            let years = tokens.compactMap { $0.count == 4 ? Int($0) : nil }.filter { (1900...2100).contains($0) }
            // The title itself may be a year ("1917", "2012"): any year close enough will do.
            if !years.isEmpty, !years.contains(where: { abs($0 - year) <= 1 }) { return false }
        }
        return true
    }

    // MARK: - JSON helpers

    static func isImdbId(_ text: String) -> Bool {
        let digits = text.dropFirst(2)
        return text.hasPrefix("tt") && digits.count >= 5 && digits.count <= 10 && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func object(_ data: Data) -> Any? {
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// A non-empty trimmed string.
    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func strings(_ value: Any?) -> [String] {
        return ((value as? [Any]) ?? []).compactMap(string)
    }

    /// A JSON number or a numeric string ("8.4", 8.4, 8).
    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil } }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = double(value), abs(number) < 9e15 else { return nil }
        return Int(number)
    }

    /// "2025–" → 2025, "2026-10-30" → 2026.
    private static func leadingYear(_ text: String?) -> Int? {
        guard let year = leadingInt(text.map { String($0.prefix(4)) }), (1880...2200).contains(year) else { return nil }
        return year
    }

    /// "145 min" → 145.
    private static func leadingInt(_ text: String?) -> Int? {
        guard let text = text else { return nil }
        return Int(text.prefix { $0.isASCII && $0.isNumber })
    }

    private static func summary(_ text: String?) -> String? {
        guard let text = text?.removingHtmlEncoding.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.count > summaryLimit else { return text }
        return String(text.prefix(summaryLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Artwork

/// metahub (Stremio's artwork service): images by IMDb id. A missing image
/// is a 404 after a redirect. The addresses by id are `OpenMetadata`'s (the
/// ones the detail pages and the library's cards use).
enum HomeArtwork {

    /// Catalogs list the small poster (about 230 px wide) and the medium
    /// backdrop: the medium poster (580 × 860) and the large backdrop
    /// (1920 × 1080, the same weight as the medium one) instead.
    static func larger(_ url: String) -> String {
        return url.replacingOccurrences(of: "images.metahub.space/poster/small/", with: "images.metahub.space/poster/medium/")
            .replacingOccurrences(of: "images.metahub.space/background/medium/", with: "images.metahub.space/background/large/")
    }

    static func poster(_ imdbId: String) -> URL? { OpenMetadata.posterURL(imdbId: imdbId) }
    static func backdrop(_ imdbId: String) -> URL? { OpenMetadata.backgroundURL(imdbId: imdbId) }
    static func logo(_ imdbId: String) -> URL? { OpenMetadata.logoURL(imdbId: imdbId) }
}

// MARK: - Languages

/// Languages as the sources name them: YTS an ISO 639-1 code, TVMaze the
/// English name, apibay words of the release name.
enum HomeLanguages {

    /// English name, lower-cased → ISO 639-1 code.
    private static let codesByName: [String: String] = {
        let english = Locale(identifier: "en_US_POSIX")
        var map: [String: String] = [:]
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) where code.count == 2 {
            if let name = english.localizedString(forLanguageCode: code)?.lowercased(), map[name] == nil { map[name] = code }
        }
        // TVMaze's spellings that are not Foundation's.
        map["chinese"] = "zh"
        map["norwegian"] = "no"
        map["tagalog"] = "tl"
        map["panjabi"] = "pa"
        return map
    }()

    /// "English" → "en"; nil when unknown.
    static func code(ofEnglishName name: String?) -> String? {
        guard let name = name?.lowercased() else { return nil }
        return codesByName[name]
    }

    /// "fr-FR" / "fr_CA" / "FR" → "fr".
    static func code(ofIdentifier identifier: String) -> String? {
        let code = identifier.lowercased().prefix { $0 != "-" && $0 != "_" }
        return code.count == 2 || code.count == 3 ? String(code) : nil
    }

    /// Words of a release name that say which language its audio is in.
    private static let releaseWords: [String: String] = [
        "english": "en", "eng": "en",
        "french": "fr", "fre": "fr", "truefrench": "fr", "vff": "fr", "vfq": "fr", "vfi": "fr", "vf": "fr", "vostfr": "fr",
        "telugu": "te", "tel": "te", "tamil": "ta", "tam": "ta", "hindi": "hi", "hin": "hi",
        "malayalam": "ml", "mal": "ml", "kannada": "kn", "kan": "kn", "bengali": "bn", "ben": "bn",
        "punjabi": "pa", "marathi": "mr", "gujarati": "gu",
        "italian": "it", "ita": "it", "german": "de", "ger": "de", "deu": "de",
        "spanish": "es", "spa": "es", "esp": "es", "latino": "es", "lat": "es", "castellano": "es",
        "portuguese": "pt", "por": "pt", "dublado": "pt", "russian": "ru", "rus": "ru",
        "korean": "ko", "kor": "ko", "japanese": "ja", "jpn": "ja", "jap": "ja", "chinese": "zh", "chi": "zh",
        "polish": "pl", "pol": "pl", "dutch": "nl", "turkish": "tr", "arabic": "ar", "thai": "th",
        "ukrainian": "uk", "swedish": "sv", "danish": "da", "norwegian": "no", "finnish": "fi",
    ]

    /// The languages a release name states ("(2026) 1080p Telugu HQ HDRip" →
    /// te; "ITA-ENG" → it, en), nil when it states none or says "multi" /
    /// "dual": then the release is in its original language, or carries it.
    /// Only the words after the year, the episode or the resolution count:
    /// before, they are the title ("The English Patient", "Mal").
    static func named(inRelease name: String) -> Set<String>? {
        let tokens = ReleaseName.tokens(name)
        guard let start = technicalStart(tokens) else { return nil }
        var found = Set<String>()
        for token in tokens[start...] {
            if token == "multi" || token == "dual" { return nil }
            if let code = releaseWords[token] { found.insert(code) }
        }
        return found.isEmpty ? nil : found
    }

    /// Index of the first token that is not the title: a year, a season
    /// marker ("s 02 e 03": the tokens split letters from digits), a
    /// resolution ("1080 p").
    private static func technicalStart(_ tokens: [String]) -> Int? {
        for index in tokens.indices.dropFirst() {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : ""
            if token.count == 4, let year = Int(token), (1900...2100).contains(year) { return index }
            if ["480", "576", "720", "1080", "2160"].contains(token), next == "p" || next == "i" { return index }
            if token == "s", Int(next) != nil { return index }
        }
        return nil
    }
}
