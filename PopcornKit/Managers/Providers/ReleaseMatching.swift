import Foundation

// Pure Foundation (plus `ReleaseName` from Torrent.swift): the release-name
// matching behind the extra torrent indexes (The Pirate Bay, Knaben) and the
// Top 100 catalog, unit-tested headlessly against recorded API answers.

// MARK: - Indexed releases

/// A torrent listed by an extra index (The Pirate Bay's apibay API, the
/// Knaben meta-index), before it becomes a `Torrent`.
public struct IndexedRelease: Equatable {
    /// The torrent name as the index lists it.
    public var name: String
    /// Lower-cased info-hash (40 hex digits, or 32 base32 letters).
    public var infoHash: String
    public var seeders: Int
    public var peers: Int
    public var bytes: Int64?
    /// Where it comes from, as the torrent picker shows it: "TPB",
    /// "Knaben · 1337x".
    public var source: String
    /// The Pirate Bay category (201 Movies, 207 HD Movies, 205 TV shows…).
    public var category: Int?
    /// The IMDb id the index files it under ("tt0816692"), nil when none.
    /// Often missing, sometimes wrong: supporting evidence only.
    public var imdb: String?

    public init(name: String, infoHash: String, seeders: Int, peers: Int, bytes: Int64?,
                source: String, category: Int? = nil, imdb: String? = nil) {
        self.name = name
        self.infoHash = infoHash
        self.seeders = seeders
        self.peers = peers
        self.bytes = bytes
        self.source = source
        self.category = category
        self.imdb = imdb
    }

    /// The lower-cased info-hash, nil when it isn't one: neither 40 hex digits
    /// nor 32 base32 letters, or all zeros (apibay's "No results returned"
    /// placeholder).
    static func normalizedInfoHash(_ raw: String?) -> String? {
        guard let hash = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        let isHex = hash.count == 40 && hash.allSatisfy { $0.isHexDigit }
        let isBase32 = hash.count == 32 && hash.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("2"..."7").contains($0)
        }
        guard isHex || isBase32, hash.contains(where: { $0 != "0" }) else { return nil }
        return hash
    }

    /// A "tt" + digits IMDb id, nil for "", "tt", "0" and the like.
    static func normalizedImdb(_ raw: String?) -> String? {
        guard var id = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty else { return nil }
        if !id.hasPrefix("tt") { id = "tt" + id }
        let digits = id.dropFirst(2)
        guard digits.count >= 5, digits.allSatisfy({ $0.isASCII && $0.isNumber }), digits.contains(where: { $0 != "0" }) else { return nil }
        return id
    }

    /// One entry per info-hash, in order: the first listing wins (its name
    /// and source), with the best seed / peer counts of its duplicates.
    public static func deduplicated(_ releases: [IndexedRelease]) -> [IndexedRelease] {
        var indexByHash: [String: Int] = [:]
        var result: [IndexedRelease] = []
        for release in releases {
            if let index = indexByHash[release.infoHash] {
                result[index].seeders = max(result[index].seeders, release.seeders)
                result[index].peers = max(result[index].peers, release.peers)
                if result[index].imdb == nil { result[index].imdb = release.imdb }
            } else {
                indexByHash[release.infoHash] = result.count
                result.append(release)
            }
        }
        return result
    }

    /// Human size the merge code reads back (`TorrentioClient.sizeInBytes`):
    /// "4.52 GB", "850 MB". POSIX decimal point whatever the locale.
    var sizeString: String? {
        guard let bytes = bytes, bytes > 0 else { return nil }
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

// MARK: - Release-name matching

/// Matches index release names to one movie / one episode, and reads the
/// title a release names (Top 100). Precision first: a torrent of the wrong
/// film or episode is worse than none, so a name only matches when it names
/// the title exactly, from its first word, and the year (movies) or the exact
/// SxxEyy (episodes).
public enum ReleaseMatch {

    // MARK: Normalization

    /// Lower-cased, accent-folded words: "&" read "and", apostrophes dropped,
    /// every other non-alphanumeric character a separator. "Ocean's Eleven" →
    /// oceans eleven · "Spider-Man: Brand New Day" → spider man brand new day.
    public static func words(_ raw: String) -> [String] {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "`", with: "")
        return folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    private static let bracketGroup = try! NSRegularExpression(pattern: "[\\[\\(\\{]([^\\[\\]\\(\\)\\{\\}]*)[\\]\\)\\}]")
    private static let leadingYear = try! NSRegularExpression(pattern: "^\\s*((?:19|20)\\d{2})(?!\\d)")
    private static let anyYear = try! NSRegularExpression(pattern: "(?<!\\d)((?:19|20)\\d{2})(?!\\d)")

    /// The release name without its bracketed groups — "[1080p]", "[TGx]",
    /// "(BBC - Seasons 1 to 17 - Complete)", "[AmÃ©lie Poulain]" — except a
    /// group opening on a year, kept as its years: "(2021)", "[2021 - Norway]"
    /// → 2021; "(1972-1990)" → 1972 1990 (a pack of several films).
    /// "&nbsp;" / "&amp;" decoded.
    public static func cleaned(_ name: String) -> String {
        var text = decoded(name)
        // Innermost groups first, a few rounds for nested ones.
        for _ in 0..<3 {
            let ns = text as NSString
            let matches = bracketGroup.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { break }
            var result = ""
            var cursor = 0
            for match in matches {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let content = ns.substring(with: match.range(at: 1))
                let range = NSRange(location: 0, length: (content as NSString).length)
                if leadingYear.firstMatch(in: content, range: range) != nil {
                    let years = anyYear.matches(in: content, range: range).map { (content as NSString).substring(with: $0.range(at: 1)) }
                    result += " " + years.joined(separator: " ") + " "
                } else {
                    result += " "
                }
                cursor = NSMaxRange(match.range)
            }
            result += ns.substring(from: cursor)
            text = result
        }
        return text
    }

    /// "&nbsp;" / "&amp;" decoded (apibay names carry them).
    static func decoded(_ name: String) -> String {
        return name
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The words inside the bracketed groups `cleaned` drops: "The Godfather
    /// (Trilogy) (1972-1990)" → trilogy 1972 1990.
    static func bracketWords(_ name: String) -> [String] {
        let text = decoded(name)
        let ns = text as NSString
        return bracketGroup.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .flatMap { words(ns.substring(with: $0.range(at: 1))) }
    }

    /// A plausible release year: four digits, 1900 … next year.
    static func year(_ word: String) -> Int? {
        guard word.count == 4, word.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(word) else { return nil }
        return (1900...(currentYear + 1)).contains(value) ? value : nil
    }

    private static let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())

    /// Edition words a release may put between the title and the year
    /// ("Interstellar IMAX 2014", "Dune Extended 1984", "Aliens DC (1986)").
    static let editionWords: Set<String> = [
        "imax", "extended", "remastered", "unrated", "uncut", "theatrical", "directors", "cut", "dc", "criterion",
        "restored",
    ]

    /// Two-word editions ("Blade Runner Final Cut 1982", "Alien Special
    /// Edition 1979", "Top Gun Open Matte 1986").
    static let editionPhrases: [[String]] = [
        ["final", "cut"], ["special", "edition"], ["open", "matte"], ["collectors", "edition"],
        ["anniversary", "edition"], ["ultimate", "edition"], ["extended", "edition"], ["criterion", "collection"],
    ]

    /// A language a release may name right before its year ("Parasite
    /// Korean 2019").
    static let languageWords: Set<String> = [
        "english", "french", "german", "spanish", "italian", "portuguese", "dutch", "swedish", "danish",
        "norwegian", "finnish", "polish", "russian", "turkish", "korean", "japanese", "chinese", "mandarin",
        "cantonese", "hindi", "tamil", "telugu", "thai",
    ]

    /// Words that make a release several films, not one ("The Godfather
    /// (Trilogy)", "Toy Story Quadrilogy", "Star Wars Complete Saga").
    static let packWords: Set<String> = [
        "trilogy", "trilogia", "duology", "dilogy", "quadrilogy", "quadrilogia", "tetralogy", "pentalogy",
        "hexalogy", "anthology", "boxset", "saga", "collection", "filmography", "pack",
    ]

    /// Words that make a release the bonus material, not the film, when they
    /// name its type ("2001.A.Space.Odyssey.1968.EXTRAS.DVDRip").
    static let extrasWords: Set<String> = ["extras", "bonus", "featurette", "featurettes"]

    /// Roman numerals of sequels: a title without a number may be followed by
    /// "Part I" / "Chapter One", never "Part II".
    private static let romanNumerals: Set<String> = ["ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]

    /// Words that start the technical part of a release name (resolution,
    /// source, codec, language): "Interstellar.1080p.BluRay…".
    static let technicalWords: Set<String> = [
        "4k", "uhd", "hdr", "hdr10", "dv", "bluray", "bdrip", "brrip", "bdremux", "remux", "web", "webrip", "webdl",
        "hdrip", "dvdrip", "dvdscr", "hdtv", "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "xvid", "divx",
        "proper", "repack", "internal", "limited", "multi", "multisubs", "dual", "vff", "vfq", "truefrench", "french",
        "ita", "eng", "esp", "spa", "ger", "nf", "amzn", "dsnp", "hmax", "atvp", "pcok", "hulu", "imax", "extended",
        "remastered", "unrated", "uncut", "hybrid",
    ]

    static func isTechnical(_ word: String) -> Bool {
        if technicalWords.contains(word) { return true }
        // 720p, 1080p, 2160p, 1080i
        if (word.hasSuffix("p") || word.hasSuffix("i")), word.count >= 4,
           word.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        return false
    }

    /// Words of a title, without a leading "the".
    static func titleWords(_ title: String) -> [String] {
        var result = words(cleaned(title))
        if result.count > 1, result.first == "the" { result.removeFirst() }
        return result
    }

    /// The forms a title may take in release names, as joined words: the
    /// title; without its "and" when it is written "&" ("Fast & Furious" →
    /// "Fast Furious"); with its non-ASCII letters dropped rather than
    /// folded ("Shōgun" → "Shgun").
    static func titleForms(_ title: String) -> [[String]] {
        var forms = [titleWords(title)]
        if title.contains("&") {
            let raw = title.replacingOccurrences(of: "&", with: " ")
            forms.append(titleWords(raw))
        }
        let ascii = String(String.UnicodeScalarView(title.unicodeScalars.filter(\.isASCII)))
        if ascii != title { forms.append(titleWords(ascii)) }
        return forms.filter { !$0.isEmpty }
    }

    /// Index just past `title` at the start of `tokens` (a leading "the"
    /// ignored on both sides), comparing joined words so word breaks may
    /// differ ("Spiderman" for "Spider-Man"), nil when the release doesn't
    /// start with it.
    static func end(of title: [String], in tokens: [String], allowLeadingThe: Bool = true) -> Int? {
        let target = title.joined()
        guard !target.isEmpty else { return nil }
        var index = allowLeadingThe && tokens.first == "the" && title.first != "the" ? 1 : 0
        var joined = ""
        while index < tokens.count, joined.count < target.count {
            joined += tokens[index]
            index += 1
            if joined == target { return index }
            if !target.hasPrefix(joined) { return nil }
        }
        return nil
    }

    // MARK: Movies

    /// What identifies a movie in release names.
    public struct MovieIdentity: Equatable {
        /// Its title, then known aliases (YTS's English title, Cinemeta's name…).
        public var titles: [String]
        /// Its release year(s): the sources don't always agree (Amélie: 2001
        /// on YTS, 2002 on Cinemeta).
        public var years: Set<Int>
        public var imdbId: String
        /// IMDb ids of other films with the same title and year ("The
        /// Odyssey" 2026: three of them): a release the index files under one
        /// of them is that film's, whatever its name.
        public var namesakeIds: Set<String>

        public init(titles: [String], years: Set<Int>, imdbId: String, namesakeIds: Set<String> = []) {
            self.titles = titles
            self.years = years
            self.imdbId = imdbId
            self.namesakeIds = namesakeIds
        }
    }

    /// True when `name` is a release of `movie`, that film alone:
    /// - the release starts with the title (or an alias), then optional
    ///   edition words ("Final Cut", "DC"), "Part I" / "Chapter One" (a title
    ///   without a number), "aka <another title>", a known alias or one
    ///   language word, then one of its years: "Interstellar.2014.1080p",
    ///   "Dune (2021) [1080p]", "Interstellar IMAX 2014", "Parasite Korean
    ///   2019". "It Chapter Two 2019", "Aliens 1986", "Halloween 2018" (for
    ///   the 1978 film), "Up in the Air 2009", "Fix Us 2019" never match;
    /// - or the title followed by technical words only, with no year anywhere,
    ///   when the index files the release under the movie's own IMDb id
    ///   (`indexImdb`): "Interstellar 1080p BluRay". The id alone is never
    ///   enough (the index's ids are sometimes wrong), and a different id
    ///   doesn't veto an exact title + year — except a namesake's
    ///   (`MovieIdentity.namesakeIds`);
    /// - and never a pack of several films ("The Godfather (Trilogy)
    ///   (1972-1990)", "Halloween 1978-2009", "John Wick 2014 Chapter 2 2017",
    ///   "Rocky 1976 13CD") or its bonus material alone ("… 1968 EXTRAS DVDRip").
    public static func isRelease(_ name: String, of movie: MovieIdentity, indexImdb: String? = nil) -> Bool {
        return movieMatch(name, of: movie, indexImdb: indexImdb) != nil
    }

    /// Where the title of `movie` ends in the release's words (`words(cleaned(name))`)
    /// when `name` is a release of it (`isRelease`), else nil.
    static func movieMatch(_ name: String, of movie: MovieIdentity, indexImdb: String?) -> Int? {
        if let indexImdb = indexImdb, movie.namesakeIds.contains(indexImdb) { return nil }
        let tokens = words(cleaned(name))
        let aliases = movie.titles.flatMap(titleForms)
        for title in movie.titles {
            for form in titleForms(title) {
                guard let end = end(of: form, in: tokens) else { continue }
                let index = afterEditions(tokens, from: end, title: form, aliases: aliases)
                if index < tokens.count, let year = year(tokens[index]) {
                    guard movie.years.contains(year) else { continue }   // another year: another film
                    if isPackOrExtras(name, tokens: tokens, titleEnd: end, yearIndex: index)
                        || saysOtherFilm(name, tokens: tokens, titleEnd: end) { return nil }
                    return end
                }
                if let indexImdb = indexImdb, indexImdb == movie.imdbId,
                   !tokens.contains(where: { year($0) != nil }),
                   index == tokens.count || isTechnical(tokens[index]),
                   !isPackOrExtras(name, tokens: tokens, titleEnd: end, yearIndex: nil) {
                    return end
                }
            }
        }
        return nil
    }

    /// Index past what a release may put between the title and its year:
    /// edition words and phrases, "Part I" / "Chapter One" after a title
    /// without a number, "aka <title>" (up to six words), a known alias, one
    /// language word right before a year.
    static func afterEditions(_ tokens: [String], from start: Int, title: [String], aliases: [[String]]) -> Int {
        let numbered = title.contains { word in word.allSatisfy(\.isNumber) || romanNumerals.contains(word) }
        var index = start
        var aliasUsed = false
        while index < tokens.count {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : ""
            if editionPhrases.contains(where: { $0 == [token, next] }) { index += 2; continue }
            if editionWords.contains(token) { index += 1; continue }
            if !numbered, ["part", "chapter"].contains(token), ["i", "1", "one"].contains(next) { index += 2; continue }
            if token == "aka" {
                // "Parasite.aka.Gisaengchung.2019": the alias, then the year.
                var probe = index + 1
                while probe < tokens.count, probe - index <= 6, year(tokens[probe]) == nil, !isTechnical(tokens[probe]) { probe += 1 }
                guard probe < tokens.count, year(tokens[probe]) != nil, probe > index + 1 else { break }
                index = probe
                break
            }
            if !aliasUsed, let alias = aliases.compactMap({ alias -> Int? in
                guard alias != title, let end = end(of: alias, in: Array(tokens[index...]), allowLeadingThe: false) else { return nil }
                return index + end
            }).max() {
                // "Hope.Hopeu.2026": the title, then another known title.
                aliasUsed = true
                index = alias
                continue
            }
            if languageWords.contains(token), index + 1 < tokens.count, year(next) != nil { index += 1 }
            break
        }
        return index
    }

    private static let yearRange = try! NSRegularExpression(pattern: "(?<![0-9])(?:19|20)[0-9]{2}\\s*[-\u{2013}\u{2014}~]\\s*(?:19|20)[0-9]{2}(?![0-9])")
    /// Bonus material shipped with the film ("DC + Featurettes", "with extras").
    private static let includedExtras = try! NSRegularExpression(pattern: "(\\+|\\bwith\\b|\\bplus\\b|\\band\\b|&)[\\s._-]*(extras|bonus|featurettes?)", options: .caseInsensitive)

    /// A pack of several films, or a film's bonus material alone: a year
    /// range ("1978-2009"), another year after the film's before the
    /// technical part ("Home Alone 1990 2 1992 3 1997"), a pack word after the
    /// title or in brackets ("(Trilogy)", "Quadrilogy", "Complete Saga", "4
    /// Film Collection", "Box Set", "Double Feature"), a multi-CD split
    /// ("13CD", "CD1"), or bonus words naming the release type ("1968 EXTRAS
    /// DVDRip").
    static func isPackOrExtras(_ name: String, tokens: [String], titleEnd: Int, yearIndex: Int?) -> Bool {
        let text = decoded(name)
        let range = NSRange(location: 0, length: (text as NSString).length)
        if yearRange.firstMatch(in: text, range: range) != nil { return true }
        let extrasIncluded = includedExtras.firstMatch(in: text, range: range) != nil
        if let yearIndex = yearIndex {
            for token in tokens[(yearIndex + 1)...] {
                if isTechnical(token) { break }
                if year(token) != nil && token != tokens[yearIndex] { return true }
                if extrasWords.contains(token) && !extrasIncluded { return true }
            }
            let zone = Array(tokens[(yearIndex + 1)...].prefix { !isTechnical($0) })
            if zip(zone, zone.dropFirst()).contains(where: { $0 == "making" && $1 == "of" }) { return true }
        }
        // Pack words name the release before its technical part ("…
        // Quadrilogy 1080p", not the "-SAGA" group of "Alien.1979.xvid.saga"),
        // or in brackets ("(Trilogy)").
        let start = min(titleEnd, tokens.count)
        let zone = Array(tokens[start...].prefix { !isTechnical($0) }) + bracketWords(name)
        for (index, word) in zone.enumerated() {
            let previous = index > 0 ? zone[index - 1] : ""
            let next = index + 1 < zone.count ? zone[index + 1] : ""
            if packWords.contains(word), !(word == "collection" && previous == "criterion") { return true }
            if (word == "box" && next == "set") || (word == "double" && next == "feature") { return true }
            if ["movies", "films", "film"].contains(word), let count = Int(previous), (2...30).contains(count) { return true }
        }
        // Split across CDs, anywhere: "13CD", "2CD", "CD1", "CD 2".
        let rest = Array(tokens[start...])
        for (index, word) in rest.enumerated() {
            let next = index + 1 < rest.count ? rest[index + 1] : ""
            if word.hasSuffix("cd"), word.count <= 4, Int(word.dropLast(2)) != nil { return true }
            if word.hasPrefix("cd"), word.count <= 4, Int(word.dropFirst(2)) != nil { return true }
            if word == "cd", let number = Int(next), number < 10 { return true }
        }
        return false
    }

    /// The uploader says it is another film of that name: "The Odyssey 2026
    /// (NOT The Chris Nolan FILM)", "… not the 2021 movie".
    static func saysOtherFilm(_ name: String, tokens: [String], titleEnd: Int) -> Bool {
        let rest = Array(tokens[min(titleEnd, tokens.count)...]) + bracketWords(name)
        for (index, word) in rest.enumerated() where word == "not" {
            guard index + 1 < rest.count, ["the", "a"].contains(rest[index + 1]) else { continue }
            if rest[(index + 2)...].prefix(6).contains(where: { ["film", "movie", "version"].contains($0) }) { return true }
        }
        return false
    }

    /// A version a streaming picker shouldn't offer for the film: 3D
    /// (side-by-side, over-under), RiffTrax (a comedy commentary mixed over
    /// the film), a fan edit. `titleEnd`: index past the title in
    /// `words(cleaned(name))`, so a title's own words never count ("Step Up 3D").
    static func isOtherVersion(_ name: String, titleEnd: Int) -> Bool {
        let all = words(cleaned(name))
        let rest = Array(all[min(titleEnd, all.count)...]) + bracketWords(name)
        let set = Set(rest)
        if !set.isDisjoint(with: ["3d", "hsbs", "fsbs", "sbs", "htab", "ftab", "hou", "rifftrax", "fanedit"]) { return true }
        return zip(rest, rest.dropFirst()).contains { pair in
            (["half", "full", "h", "f"].contains(pair.0) && ["sbs", "ou", "tab"].contains(pair.1))
                || (pair.0 == "riff" && pair.1 == "trax") || (pair.0 == "fan" && pair.1 == "edit")
        }
    }

    /// "Title Year" readings of a movie release name, most likely first: the
    /// words before a year (not the first word: "1917 2019"), trailing
    /// edition words dropped. Two at most: "Wonder.Woman.1984.2020" →
    /// ("wonder woman", 1984), ("wonder woman 1984", 2020). Empty when the
    /// name has no year after a title ("Akira Kurosawa Boxset").
    public static func movieTitleCandidates(_ name: String) -> [(title: String, year: Int)] {
        let tokens = words(cleaned(name))
        var result: [(title: String, year: Int)] = []
        for index in tokens.indices.dropFirst() {
            guard let year = year(tokens[index]) else { continue }
            var title = Array(tokens[..<index])
            while title.count > 1, let last = title.last, editionWords.contains(last) { title.removeLast() }
            result.append((title.joined(separator: " "), year))
            if result.count == 2 { break }
        }
        return result
    }

    // MARK: Episodes

    /// What identifies a show in release names.
    public struct ShowIdentity: Equatable {
        /// Its title, then its alternate titles (TVMaze akas).
        public var titles: [String]
        /// The year it premiered.
        public var year: Int?
        /// ISO country code of its network ("US", "GB"), nil when unknown.
        public var country: String?
        /// Another show has the same name ("The Office" US / UK, "Dark Matter"
        /// 2015 / 2024, "Shameless" UK / US): a release must then name its
        /// year or country ("Dark Matter 2024 S02E05", "The Office US S02E01").
        public var isAmbiguous: Bool
        /// TVMaze ids of the shows of the same name: one that can't have the
        /// requested episode (a one-season namesake, for S03E08) doesn't make
        /// it ambiguous (`ExtraTorrentSources` asks TVMaze).
        public var namesakeIds: [Int]

        public init(titles: [String], year: Int?, country: String?, isAmbiguous: Bool, namesakeIds: [Int] = []) {
            self.titles = titles
            self.year = year
            self.country = country
            self.isAmbiguous = isAmbiguous
            self.namesakeIds = namesakeIds
        }
    }

    /// Country words of release names and the ISO codes they stand for.
    static let countryWords: [String: String] = ["us": "US", "uk": "GB", "gb": "GB", "au": "AU", "nz": "NZ", "ca": "CA"]

    /// The show part of a release name: its words before the first episode /
    /// season marker (SxxEyy, NxNN, "S01", "Season", "Complete"…), a trailing
    /// year and country split off and a leading "the" dropped.
    /// "Dark Matter 2024 S02E05 …" → (dark matter, 2024, nil) · "The Office
    /// US S02E01 …" → (office, nil, US) · "MobLand (2025) S02E07 …" → (mobland,
    /// 2025, nil). Nil without any marker, or when nothing precedes it.
    public static func showPart(of name: String) -> (words: [String], year: Int?, country: String?)? {
        guard let reading = showReadings(of: name).first else { return nil }
        return (reading.words, reading.year, reading.country)
    }

    /// One reading of the show part of a release name.
    public struct ShowReading: Equatable {
        public var words: [String]
        public var year: Int?
        public var country: String?
        /// "the" started the name ("The Bear S05E01").
        public var leadingThe: Bool
        /// Filler words ("the", "and", "of") were trimmed off its end.
        public var trimmedFiller: Bool
    }

    /// The readings of a release name's show part, before its first episode /
    /// season marker: `showPart`'s (a trailing year, country and filler word
    /// split off), then — when different — the words as they are, only a
    /// trailing year split off: "The Last of Us S02E01" reads (last, country
    /// US) and (last of us). Empty without a marker or a show part.
    public static func showReadings(of name: String) -> [ShowReading] {
        let tokens = words(cleaned(name))
        guard let marker = tokens.firstIndex(where: isSeasonMarker), marker > 0 else { return [] }
        return showReadings(tokens: tokens, marker: marker)
    }

    static func showReadings(tokens: [String], marker: Int) -> [ShowReading] {
        let leadingThe = tokens.first == "the"
        var part = Array(tokens[..<marker])
        var year: Int?
        var country: String?
        var trimmedFiller = false
        var lastWasYear = false
        while part.count > 1, let last = part.last {
            let wasYear = lastWasYear
            lastWasYear = false
            if year == nil || wasYear, let value = self.year(last) {
                // "Animaniacs (1993-1999)": the first year of a run.
                year = min(year ?? value, value)
                lastWasYear = true
            } else if country == nil, let code = countryWords[last] {
                country = code
            } else if ["the", "and", "of"].contains(last) {
                // "The Sopranos: The Complete Series" → "the sopranos the"
                trimmedFiller = true
            } else {
                break
            }
            part.removeLast()
        }
        if part.count > 1, part.first == "the" { part.removeFirst() }
        guard !part.isEmpty else { return [] }
        var readings = [ShowReading(words: part, year: year, country: country, leadingThe: leadingThe, trimmedFiller: trimmedFiller)]
        var raw = Array(tokens[..<marker])
        if raw.count > 1, raw.first == "the" { raw.removeFirst() }
        var rawYear: Int?
        while raw.count > 1, let last = raw.last, let value = self.year(last) {
            rawYear = min(rawYear ?? value, value)
            raw.removeLast()
        }
        if raw != part {
            readings.append(ShowReading(words: raw, year: rawYear, country: nil, leadingThe: leadingThe, trimmedFiller: false))
        }
        return readings
    }

    private static let seasonEpisodeToken = try! NSRegularExpression(pattern: "^(s\\d{1,2}(e\\d{1,3})*|\\d{1,2}x\\d{2,3}|s\\d{1,2}e\\d{1,3}e?\\d{0,3})$")

    /// An episode / season token: "s02e07", "s01", "3x05", "season", "complete"…
    static func isSeasonMarker(_ token: String) -> Bool {
        if ReleaseName.seasonWords.contains(token) || ReleaseName.packWords.contains(token) { return true }
        let ns = token as NSString
        return seasonEpisodeToken.firstMatch(in: token, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// True when `name` is a release of exactly that episode of `show`: the
    /// exact SxxEyy alone (`ReleaseName.episodeScope` = requested episode:
    /// no season pack, double episode or range, which would stream another
    /// file), and a show part naming the show exactly — its title or an
    /// alternate title, or an acronym of its last words ("Law and Order
    /// SVU") — with a year / country that agrees with the show's when the
    /// release names one, and that names one when the show's name is
    /// ambiguous. "The Office Movers S02E01" is not "The Office"; "Dark S02E05
    /// … MATTER" is not "Dark Matter".
    public static func isRelease(_ name: String, season: Int, episode: Int, of show: ShowIdentity) -> Bool {
        guard ReleaseName.episodeScope(of: name, season: season, episode: episode) == .requestedEpisode else { return false }
        let tokens = words(cleaned(name))
        guard let marker = tokens.firstIndex(where: isSeasonMarker), marker > 0 else { return false }
        // A year right after the episode marker ("Shogun.S01E01.2024.1080p")
        // identifies the show when it is its premiere year (otherwise it may
        // be an episode title: never a reason to refuse).
        let yearAfterMarker = marker + 1 < tokens.count ? year(tokens[marker + 1]) : nil
        let forms = show.titles.reduce(into: Set<String>()) { $0.formUnion(showForms($1, keepingCountry: true)) }
        for reading in showReadings(tokens: tokens, marker: marker) where forms.contains(reading.words.joined()) {
            if agrees(reading, yearAfterMarker: yearAfterMarker, with: show) { return true }
        }
        return false
    }

    /// The year / country a release reading names agree with the show's, and
    /// name it when the show's name is ambiguous.
    static func agrees(_ reading: ShowReading, yearAfterMarker: Int?, with show: ShowIdentity) -> Bool {
        var identified = false
        if let year = reading.year {
            if let showYear = show.year {
                guard year == showYear else { return false }
                identified = true
            } else if show.isAmbiguous {
                return false
            }
        }
        if let country = reading.country {
            if let showCountry = show.country {
                guard country == showCountry.uppercased() else { return false }
                identified = true
            } else if show.isAmbiguous {
                return false
            }
        }
        if !identified, let year = yearAfterMarker, year == show.year { identified = true }
        return !show.isAmbiguous || identified
    }

    /// Joined-word forms of a show title for `isRelease(_:season:episode:of:)`:
    /// the title forms with a trailing year / country dropped ("Doctor Who
    /// (2005)"), plus its first words followed by the acronym of the others
    /// ("Law & Order: Special Victims Unit" → "lawandordersvu"). Never the
    /// acronym of the whole title: "BB" is not "Breaking Bad".
    static func showForms(_ title: String, keepingCountry: Bool = false) -> Set<String> {
        var result = Set<String>()
        if keepingCountry {
            // The title as it is, but a trailing year: "The Last of Us" →
            // "lastofus" ("us" is no country there).
            for var form in titleForms(title) {
                if form.count > 1, let last = form.last, year(last) != nil { form.removeLast() }
                result.insert(form.joined())
            }
        }
        for var form in titleForms(title) {
            while form.count > 1, let last = form.last, year(last) != nil || countryWords[last] != nil {
                form.removeLast()
            }
            result.insert(form.joined())
            if form.count >= 3 {
                for start in 1..<(form.count - 1) {
                    let acronym = form[start...].compactMap(\.first).map(String.init).joined()
                    result.insert(form[..<start].joined() + acronym)
                }
            }
        }
        result.remove("")
        return result
    }

    /// True when two show names are the same name (ambiguity check): equal
    /// joined words, a leading "the" and a trailing year / country ignored.
    public static func sameShowName(_ a: String, _ b: String) -> Bool {
        let strip: (String) -> String = { title in
            var form = titleWords(title)
            while form.count > 1, let last = form.last, year(last) != nil || countryWords[last] != nil {
                form.removeLast()
            }
            return form.joined()
        }
        let left = strip(a)
        return !left.isEmpty && left == strip(b)
    }

    /// The identity of a show from its TVMaze entry (`lookup/shows?imdb=`):
    /// name, premiere year, network (or streaming service) country; its
    /// alternate titles (`/shows/{id}/akas`) and `extraTitles` (the app's
    /// title, when another source named it differently) as more titles; and
    /// ambiguous when a TVMaze search of its name (`search/shows?q=`) lists
    /// another show of the same name.
    public static func showIdentity(tvmaze show: [String: Any], akas: [String], searchResults: [[String: Any]]?,
                                    extraTitles: [String] = []) -> ShowIdentity {
        let name = (show["name"] as? String) ?? ""
        var titles: [String] = []
        for title in [name] + akas + extraTitles where !title.isEmpty && !titles.contains(title) {
            titles.append(title)
        }
        let year = ((show["premiered"] as? String).flatMap { Int($0.prefix(4)) })
        let network = (show["network"] as? [String: Any]) ?? (show["webChannel"] as? [String: Any])
        let country = (network?["country"] as? [String: Any])?["code"] as? String
        let ownId = show["id"] as? Int
        let namesakes = (searchResults ?? []).compactMap { result -> Int? in
            guard let other = result["show"] as? [String: Any], let otherName = other["name"] as? String,
                  let otherId = other["id"] as? Int, otherId != ownId, sameShowName(otherName, name) else { return nil }
            return otherId
        }
        // Unknown (search failed): assume a namesake, the strict reading.
        let ambiguous = searchResults == nil || !namesakes.isEmpty
        return ShowIdentity(titles: titles, year: year, country: country, isAmbiguous: ambiguous, namesakeIds: namesakes)
    }

    /// The alternate titles of a TVMaze `/shows/{id}/akas` answer that
    /// English-language releases may use: the international one (no country)
    /// and the English-speaking countries' ("The Doll" for "Lalka"). Other
    /// countries' titles are left out: a free-text index search is wider than
    /// EZTV's per-show listing, and a foreign title can be another show's.
    public static func englishAkas(_ akas: [[String: Any]]) -> [String] {
        let english: Set<String> = ["US", "GB", "CA", "AU", "NZ", "IE"]
        return akas.compactMap { aka in
            guard let name = aka["name"] as? String, !name.isEmpty else { return nil }
            guard let code = (aka["country"] as? [String: Any])?["code"] as? String else { return name }
            return english.contains(code) ? name : nil
        }
    }

    /// The words a search for a title sends to an index: accent-folded,
    /// punctuation and bracketed groups removed. "Spider-Man: Brand New Day"
    /// → "spider man brand new day", "It's Always Sunny" → "its always sunny".
    public static func searchTerms(_ title: String) -> String {
        return words(cleaned(title)).joined(separator: " ")
    }
}

// MARK: - Filtering index results

public extension ReleaseMatch {

    /// The releases of `movie` among an index's search results, minus those
    /// that can't stream (disc images, archives, BD / DVD structures) and the
    /// versions a picker shouldn't offer (3D, RiffTrax, fan edits).
    static func movieReleases(_ releases: [IndexedRelease], of movie: MovieIdentity) -> [IndexedRelease] {
        return releases.filter { release in
            guard let titleEnd = movieMatch(release.name, of: movie, indexImdb: release.imdb) else { return false }
            return !isOtherVersion(release.name, titleEnd: titleEnd)
                && !ReleaseName.isLikelyUnplayable(fileName: nil, title: release.name)
        }
    }

    /// The releases of exactly one episode of `show` among an index's search
    /// results, minus those that can't stream.
    static func episodeReleases(_ releases: [IndexedRelease], season: Int, episode: Int,
                                of show: ShowIdentity) -> [IndexedRelease] {
        return releases.filter { release in
            isRelease(release.name, season: season, episode: episode, of: show)
                && !ReleaseName.isLikelyUnplayable(fileName: nil, title: release.name)
        }
    }
}

// MARK: - Top 100

/// The titles of The Pirate Bay's top-100 lists, grouped and ranked before
/// they are resolved to IMDb titles (`Top100Resolver`).
public struct Top100Group: Equatable {
    /// "m:interstellar|2014", "s:mobland", "i:tt0816692": the title the
    /// releases name, or the IMDb id when they name none readably.
    public var key: String
    /// Readings of the title (and year) for a Cinemeta search, most likely
    /// first: "Wonder.Woman.1984.2020" reads ("wonder woman", 1984) then
    /// ("wonder woman 1984", 2020).
    public var readings: [Reading]
    /// The year the releases name (movies: always; shows: when named).
    public var year: Int? { readings.first?.year }
    /// The releases (name + the index's IMDb id) in popularity order.
    public var entries: [Entry]
    /// Seeders of all its torrents together: the ranking.
    public var seeders: Int
    /// Position of its first torrent in the merged lists (ties).
    public var firstIndex: Int

    public struct Entry: Equatable {
        public var name: String
        public var imdb: String?
    }

    public struct Reading: Equatable {
        public var title: String
        public var year: Int?
    }

    /// The index's IMDb ids for the group, most frequent first.
    public var imdbIds: [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for entry in entries {
            guard let id = entry.imdb else { continue }
            if counts[id] == nil { order.append(id) }
            counts[id, default: 0] += 1
        }
        return order.enumerated()
            .sorted { counts[$0.element]! != counts[$1.element]! ? counts[$0.element]! > counts[$1.element]! : $0.offset < $1.offset }
            .map(\.element)
    }
}

public enum Top100Ranking {

    /// Movie titles of top-100 lists (several categories merged: Movies, HD,
    /// UHD), each with its releases, most seeded first. A release whose name
    /// reads no "Title Year" counts under its IMDb id; without one either
    /// (box sets, collections) it is left out.
    public static func movieGroups(_ releases: [IndexedRelease]) -> [Top100Group] {
        return groups(releases) { release in
            let candidates = ReleaseMatch.movieTitleCandidates(release.name)
            if let first = candidates.first {
                // Same key for "The Odyssey 2026" and "Odyssey 2026".
                let words = ReleaseMatch.titleWords(first.title)
                return ("m:" + words.joined() + "|\(first.year)",
                        candidates.map { Top100Group.Reading(title: $0.title, year: $0.year) })
            }
            if let imdb = release.imdb { return ("i:" + imdb, []) }
            return nil
        }
    }

    /// Show titles of top-100 lists (TV, HD TV, UHD TV merged): episodes and
    /// season packs grouped by the show they name ("MobLand S02E07 …",
    /// "The Mentalist Season 1 2 3 …"), most seeded first.
    public static func showGroups(_ releases: [IndexedRelease]) -> [Top100Group] {
        return groups(releases) { release in
            let readings = ReleaseMatch.showReadings(of: release.name)
            if let part = readings.first {
                // Searched with its "The" ("The Bear", not "Bear").
                func title(_ reading: ReleaseMatch.ShowReading) -> Top100Group.Reading {
                    let the = reading.leadingThe && reading.words.first != "the"
                    return Top100Group.Reading(title: (the ? "the " : "") + reading.words.joined(separator: " "), year: reading.year)
                }
                // The words as they are first when trimming took a word of the
                // title: "The Last of Us" (not "The Last", another show).
                var searches = readings.map(title)
                if part.trimmedFiller { searches.reverse() }
                return ("s:" + part.words.joined() + (part.year.map { "|\($0)" } ?? "") + (part.country.map { "|\($0)" } ?? ""),
                        searches)
            }
            if let imdb = release.imdb { return ("i:" + imdb, []) }
            return nil
        }
    }

    private static func groups(_ releases: [IndexedRelease],
                               key: (IndexedRelease) -> (String, [Top100Group.Reading])?) -> [Top100Group] {
        var groups: [Top100Group] = []
        var indexByKey: [String: Int] = [:]
        for (position, release) in IndexedRelease.deduplicated(releases).enumerated() {
            guard let (groupKey, readings) = key(release) else { continue }
            let entry = Top100Group.Entry(name: release.name, imdb: release.imdb)
            if let index = indexByKey[groupKey] {
                groups[index].entries.append(entry)
                groups[index].seeders += release.seeders
            } else {
                indexByKey[groupKey] = groups.count
                groups.append(Top100Group(key: groupKey, readings: readings, entries: [entry],
                                          seeders: release.seeders, firstIndex: position))
            }
        }
        return groups.sorted { $0.seeders != $1.seeders ? $0.seeders > $1.seeders : $0.firstIndex < $1.firstIndex }
    }
}

// MARK: - Cinemeta validation

/// Decides whether a Cinemeta meta is the title a top-100 group names.
public enum CinemetaMatching {

    /// First year of a Cinemeta `releaseInfo` / `year` ("2014", "2025–",
    /// "2008–2013").
    public static func startYear(_ meta: [String: Any]) -> Int? {
        let info = (meta["releaseInfo"] as? String) ?? (meta["year"] as? String) ?? ""
        return Int(info.prefix(4))
    }

    /// A real entry: a name and a poster. IMDb also lists stubs Cinemeta
    /// serves bare ("Interstellar (2014)", tt4288316, the id TPB files the
    /// YIFY Interstellar under).
    static func isComplete(_ meta: [String: Any]) -> Bool {
        guard let name = meta["name"] as? String, !name.isEmpty,
              let poster = meta["poster"] as? String, !poster.isEmpty else { return false }
        return true
    }

    static func id(_ meta: [String: Any]) -> String? {
        return IndexedRelease.normalizedImdb((meta["imdb_id"] as? String) ?? (meta["id"] as? String))
    }

    /// The movie meta (`/meta/movie/<id>`) is the film the group names: a
    /// complete movie entry (one year, not a series' "2025–") whose title and
    /// year a release names exactly (`ReleaseMatch.isRelease`), or — for a
    /// release the index files under this very id — whose title starts the
    /// release, followed later by a year within one of the meta's, with no
    /// number in between ("Amelie [AmÃ©lie Poulain].2001" for Amélie, 2002 on
    /// Cinemeta; "Ballerina From the World of John Wick 2025"; never the box
    /// set "Home Alone 1, 2, 3, 4, 5 - Family Comedy 1990-2012").
    public static func movieMetaMatches(_ meta: [String: Any], group: Top100Group) -> Bool {
        guard isComplete(meta), let id = id(meta), let name = meta["name"] as? String,
              let info = (meta["releaseInfo"] as? String) ?? (meta["year"] as? String),
              info.count == 4, let year = Int(info) else { return false }
        let identity = ReleaseMatch.MovieIdentity(titles: [name], years: [year], imdbId: id)
        let nameJoined = ReleaseMatch.words(ReleaseMatch.cleaned(name)).joined()
        for entry in group.entries {
            if ReleaseMatch.isRelease(entry.name, of: identity, indexImdb: entry.imdb) { return true }
            guard entry.imdb == id else { continue }
            let tokens = ReleaseMatch.words(ReleaseMatch.cleaned(entry.name))
            for form in ReleaseMatch.titleForms(name) {
                // Between the title and the year: editions, "The Movie", words
                // of the meta's own name — or, with the exact year, other words
                // ("Ballerina From the World of John Wick 2025" for "Ballerina",
                // 2025); never a later film's ("Wicked For Good 2025" filed
                // under Wicked's id, 2024). No number: "Home Alone 1, 2, 3".
                guard let end = ReleaseMatch.end(of: form, in: tokens),
                      let yearIndex = tokens[end...].firstIndex(where: { ReleaseMatch.year($0) != nil }),
                      let found = ReleaseMatch.year(tokens[yearIndex]), abs(found - year) <= 1,
                      !tokens[end..<yearIndex].contains(where: { $0.allSatisfy(\.isNumber) }),
                      !ReleaseMatch.isPackOrExtras(entry.name, tokens: tokens, titleEnd: end, yearIndex: yearIndex)
                else { continue }
                let between = tokens[end..<yearIndex]
                let onlyFiller = between.allSatisfy { word in
                    ReleaseMatch.editionWords.contains(word) || ReleaseMatch.isTechnical(word)
                        || ["the", "movie", "film"].contains(word) || (word.count >= 3 && nameJoined.contains(word))
                }
                if onlyFiller || found == year { return true }
            }
            // The same words but its articles ("Lord.of.the.Rings.Fellowship.of.Ring.2001"),
            // or the subtitle alone ("The Mandalorian and Grogu (2026)" for "Star
            // Wars: The Mandalorian and Grogu").
            let wanted = [name] + (name.range(of: ":").map { [String(name[$0.upperBound...])] } ?? [])
            guard !ReleaseMatch.isPackOrExtras(entry.name, tokens: tokens, titleEnd: 0, yearIndex: nil) else { continue }
            for reading in ReleaseMatch.movieTitleCandidates(entry.name) where abs(reading.year - year) <= 1 {
                let words = contentWords(reading.title)
                if !words.isEmpty, wanted.contains(where: { contentWords($0) == words }) { return true }
            }
        }
        return false
    }

    /// A title's words without articles and "of" / "and".
    static func contentWords(_ title: String) -> [String] {
        let small: Set<String> = ["the", "a", "an", "of", "and"]
        return ReleaseMatch.words(ReleaseMatch.cleaned(title)).filter { !small.contains($0) }
    }

    /// The search result (`/catalog/movie/top/search=`) that is exactly the
    /// group's title and year, nil when none (or when only incomplete).
    public static func movieSearchMatch(_ metas: [[String: Any]], title: String, year: Int) -> [String: Any]? {
        let wanted = ReleaseMatch.titleWords(title).joined()
        return metas.first { meta in
            guard isComplete(meta), id(meta) != nil, let name = meta["name"] as? String,
                  let info = meta["releaseInfo"] as? String, info.count == 4, Int(info) == year else { return false }
            return ReleaseMatch.titleForms(name).contains { $0.joined() == wanted }
        }
    }

    /// The series meta (`/meta/series/<id>`, `{}` for a movie id) is the
    /// show the group names: a complete entry whose name is the group's show
    /// name (or, for releases filed under this very id, starts it), with a
    /// start year within one of the year the releases name, if any.
    public static func showMetaMatches(_ meta: [String: Any], group: Top100Group) -> Bool {
        guard isComplete(meta), let id = id(meta), let name = meta["name"] as? String else { return false }
        if let year = group.year, let start = startYear(meta), abs(year - start) > 1 { return false }
        let forms = ReleaseMatch.showForms(name, keepingCountry: true)
        let nameJoined = ReleaseMatch.words(ReleaseMatch.cleaned(name)).joined()
        /// What may follow the title in a release filed under this very id:
        /// nothing, a year, a date, a country, "TV Series", "Complete", technical
        /// words, words of the meta's name — never another title's words
        /// ("Dexter Resurrection" filed under Dexter's id).
        func onlyFiller(_ words: ArraySlice<String>) -> Bool {
            return words.allSatisfy { word in
                word.allSatisfy(\.isNumber) || ReleaseMatch.countryWords[word] != nil || ReleaseMatch.isTechnical(word)
                    || showFillerWords.contains(word) || (word.count >= 3 && nameJoined.contains(word))
            }
        }
        for entry in group.entries {
            let readings = ReleaseMatch.showReadings(of: entry.name)
            guard !readings.isEmpty else {
                // No season marker ("The Daily Show 2026 03 31 …", "The Venture
                // Bros. (Seasons 1-6 +Commentary)"): its title first, under this id.
                let tokens = ReleaseMatch.words(ReleaseMatch.cleaned(entry.name))
                if entry.imdb == id, ReleaseMatch.titleForms(name).contains(where: { form in
                    guard let end = ReleaseMatch.end(of: form, in: tokens) else { return false }
                    return onlyFiller(tokens[end...].prefix(1))
                }) {
                    return true
                }
                continue
            }
            if readings.contains(where: { forms.contains($0.words.joined()) }) { return true }
            if entry.imdb == id, readings.contains(where: { reading in
                ReleaseMatch.titleForms(name).contains { form in
                    guard let end = ReleaseMatch.end(of: form, in: reading.words) else { return false }
                    return onlyFiller(reading.words[end...])
                }
            }) {
                return true
            }
        }
        return false
    }

    /// Words a show's release may add after its title.
    static let showFillerWords: Set<String> = [
        "tv", "series", "show", "complete", "collection", "uncut", "remastered", "the", "and", "of",
    ]

    /// The series search result whose name is exactly the group's show name
    /// (and start year, when the releases name one): the most popular such.
    public static func showSearchMatch(_ metas: [[String: Any]], title: String, year: Int?) -> [String: Any]? {
        return metas.first { meta in
            guard isComplete(meta), id(meta) != nil, let name = meta["name"] as? String else { return false }
            if let year = year {
                guard let start = startYear(meta), abs(start - year) <= 1 else { return false }
            }
            return ReleaseMatch.sameShowName(name, title)
        }
    }
}
