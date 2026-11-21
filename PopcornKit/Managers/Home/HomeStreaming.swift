import Foundation

/// Browsing by streaming service ("Netflix", "Disney+"): what each service
/// offers in the user's country, from TMDB's `discover` with its watch
/// providers (JustWatch's data, which TMDB asks apps to credit).
///
/// - The Apple TV's Home has a « Services » row (`HomeShelfID.services`):
///   one card per service the user chose (`HomeSettings.streamingServices`).
///   Picking one filters the page (`HomeSettings.homeServiceFilter`): it then
///   shows that service's shelves only — popular, recent and top rated
///   movies and shows — under a hero of its popular titles; « All » brings
///   the usual page back.
/// - The Movies and Shows grids have a « Service » filter that pages through
///   a service's catalogue (`TMDBStreamingClient.titles`).
///
/// TMDB knows its titles by TMDB ids: the client gives every answer its
/// titles' IMDb ids before the parser reads it (the hub and the app know
/// titles by IMDb id), and a title without one is left out.

// MARK: - Service

/// A streaming service as TMDB lists it (a "watch provider").
public struct StreamingService: Codable, Hashable, Sendable, Identifiable {
    /// TMDB's provider id: 8 is Netflix in every country.
    public var id: Int
    public var name: String
    /// TMDB's logo path ("/pbpMk2JmcoNnQwx5JGpXngfoWtp.jpg").
    public var logoPath: String?

    public init(id: Int, name: String, logoPath: String? = nil) {
        self.id = id
        self.name = name
        self.logoPath = logoPath
    }

    public var logoURL: URL? {
        return logoPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w300" + $0) }
    }

    /// The services of someone who chose none, in a country: the four that
    /// are in most countries. No logo: a card without one shows the name
    /// (choosing the services in Settings stores TMDB's logos — and TMDB's
    /// entries, so these are TMDB's own names: a card keeps the name the
    /// user first saw when Settings loads the country's list). Amazon Prime
    /// Video is provider 119 in most countries, 9 in a few (`primeVideo9`).
    public static func defaults(for region: String) -> [StreamingService] {
        return [
            StreamingService(id: 8, name: "Netflix"),
            StreamingService(id: primeVideo9.contains(region.uppercased()) ? 9 : 119, name: "Amazon Prime Video"),
            StreamingService(id: 337, name: "Disney Plus"),
            StreamingService(id: 350, name: "Apple TV"),
        ]
    }

    /// The countries where TMDB lists Amazon Prime Video as provider 9, and
    /// has no 119 (TMDB's providers, 2026-11-21: 119 in 129 countries, 9 in
    /// these five, never both).
    static let primeVideo9: Set<String> = ["AT", "DE", "GB", "JP", "US"]

    /// The service as the country knows it: Amazon Prime Video's id of
    /// that country (`primeVideo9`), with its name and logo (the same logo
    /// under both ids on TMDB); any other service as it is. What a list
    /// chosen in another country, or stored before the country mattered,
    /// reads back as (`HomeSettings.streamingServices`), before Settings
    /// matches it to the country's whole list (`matching`).
    func inRegion(_ region: String) -> StreamingService {
        guard id == 9 || id == 119 else { return self }
        var service = self
        service.id = StreamingService.primeVideo9.contains(region.uppercased()) ? 9 : 119
        return service
    }

    /// The services chosen, as a country's list (`available`, TMDB's
    /// services there) has them: the same id when the country has it, else
    /// the country's service of the same name (Amazon Prime Video: 119 in
    /// France, 9 in the United States), else left out — the country has no
    /// such service, and its page would be empty. In the chosen order, each
    /// once; TMDB's entry (its name and logo today).
    public static func matching(_ chosen: [StreamingService], in available: [StreamingService]) -> [StreamingService] {
        func key(_ name: String) -> String {
            return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
        }
        let byId = Dictionary(available.map { ($0.id, $0) }) { first, _ in first }
        let byName = Dictionary(available.map { (key($0.name), $0) }) { first, _ in first }
        var seen = Set<Int>()
        return chosen.compactMap { byId[$0.id] ?? byName[key($0.name)] }.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - The country's services

extension HomeSettings {
    /// After TMDB listed a country's services (`available`): the chosen
    /// services matched to them (`StreamingService.matching`), only while
    /// `region` is still the country chosen — an answer for a country left
    /// meanwhile changes nothing. true: the stored choice changed.
    @discardableResult
    public func adoptServices(_ available: [StreamingService], listedFor region: String) -> Bool {
        guard streamingRegion == HomeSettings.regionCode(region) else { return false }
        let chosen = streamingServices
        let matched = StreamingService.matching(chosen, in: available)
        guard matched != chosen else { return false }
        streamingServices = matched
        return true
    }
}

/// The order of a service's titles.
public enum StreamingSort: String, Codable, CaseIterable, Sendable {
    /// Most popular first (TMDB's popularity: what is watched now).
    case popular
    /// Latest released first, up to today.
    case recent
    /// Best rated first, among titles with many votes.
    case topRated
}

// MARK: - The grids' sorts with a service

extension MovieManager.Filters {
    /// The order of a service's catalogue this sort of the Movies grid
    /// means; nil: one TMDB's lists cannot follow (Trending, Top 100: The
    /// Pirate Bay's seeders; Recently Added: when YTS got the title). The
    /// grid offers only the others while a service is chosen: its Sort
    /// control never names an order the list is not in.
    public var streamingSort: StreamingSort? {
        switch self {
        case .popularity: return .popular
        case .year: return .recent
        case .rating: return .topRated
        case .trending, .top100, .date: return nil
        }
    }

    /// The sorts of the Movies grid while a service is chosen, in the
    /// grid's order: Popular, Top Rated, New.
    public static var streamingArray: [MovieManager.Filters] { array.filter { $0.streamingSort != nil } }
}

extension ShowManager.Filters {
    /// The order of a service's catalogue this sort of the Shows grid
    /// means; nil: one TMDB's lists cannot follow (Trending, Top 100,
    /// Recently Added, A - Z). See `MovieManager.Filters.streamingSort`.
    public var streamingSort: StreamingSort? {
        switch self {
        case .popularity: return .popular
        case .year: return .recent
        case .rating: return .topRated
        case .trending, .top100, .date, .name: return nil
        }
    }

    /// The sorts of the Shows grid while a service is chosen, in the grid's
    /// order: Popular, Top Rated, New.
    public static var streamingArray: [ShowManager.Filters] { array.filter { $0.streamingSort != nil } }
}

// MARK: - Shelves

extension HomeShelfID {
    /// The Apple TV's row of service cards, the page's filter.
    public static let services = "services"

    static let streamingPrefix = "streaming-"

    /// A filtered page's shelf: "streaming-8-movie-popular".
    public static func streaming(_ service: Int, _ kind: HomeItem.Kind, _ sort: StreamingSort) -> String {
        return "\(streamingPrefix)\(service)-\(kind.rawValue)-\(sort.rawValue)"
    }

    /// The service, kind and order of a streaming shelf; nil for the other shelves.
    public static func streaming(of id: String) -> (service: Int, kind: HomeItem.Kind, sort: StreamingSort)? {
        guard id.hasPrefix(streamingPrefix) else { return nil }
        let parts = id.dropFirst(streamingPrefix.count).split(separator: "-")
        guard parts.count == 3, let service = Int(parts[0]), let kind = HomeItem.Kind(rawValue: String(parts[1])),
              let sort = StreamingSort(rawValue: String(parts[2])) else { return nil }
        return (service, kind, sort)
    }

    /// A shelf made of the hosts' lists: not one of the user's own
    /// (`local`), nor the « Services » row, which is made of the settings
    /// alone. A page without any is "unavailable" when the hosts failed.
    public static func isRemote(_ id: String) -> Bool {
        return !local.contains(id) && id != services
    }

    /// The TMDB provider id of a streaming shelf, nil for the other shelves.
    public static func streamingService(of id: String) -> Int? {
        return streaming(of: id)?.service
    }

    /// The English title of a streaming shelf, a format whose argument is
    /// the service ("Popular Movies on %@").
    static func streamingTitle(_ kind: HomeItem.Kind, _ sort: StreamingSort) -> String {
        switch (sort, kind) {
        case (.popular, .movie): return "Popular Movies on %@"
        case (.popular, .show): return "Popular Shows on %@"
        case (.recent, .movie): return "New Movies on %@"
        case (.recent, .show): return "New Shows on %@"
        case (.topRated, .movie): return "Top Rated Movies on %@"
        case (.topRated, .show): return "Top Rated Shows on %@"
        }
    }

    /// The shelves of a filtered page, in order.
    static let streamingShelves: [(kind: HomeItem.Kind, sort: StreamingSort)] = [
        (.movie, .popular), (.show, .popular), (.movie, .recent), (.show, .recent), (.movie, .topRated), (.show, .topRated),
    ]
}

/// The cards of the « Services » row: one per service, and « All » first
/// while the page is filtered. They are not titles: `serviceId` tells what
/// a card picks.
public enum HomeServiceCard {
    static let prefix = "service-"
    /// The id of the « All » card.
    public static let allId = "service-all"

    static func item(_ service: StreamingService, selected: Bool) -> HomeItem {
        return HomeItem(id: "\(prefix)\(service.id)", imdbId: "\(prefix)\(service.id)", kind: .movie, title: service.name,
                        posterURL: service.logoURL, rank: selected ? 1 : nil)
    }

    static func all(title: String) -> HomeItem {
        return HomeItem(id: allId, imdbId: allId, kind: .movie, title: title)
    }

    /// What a card of the row picks: a service's id, nil for « All ».
    /// Not a service card: `.none` (`isServiceCard` false).
    public static func serviceId(of item: HomeItem) -> Int? {
        return item.id.hasPrefix(prefix) ? Int(item.id.dropFirst(prefix.count)) : nil
    }

    public static func isServiceCard(_ item: HomeItem) -> Bool {
        return item.id.hasPrefix(prefix)
    }

    public static func isAll(_ item: HomeItem) -> Bool {
        return item.id == allId
    }

    /// The card of the service the page shows.
    public static func isSelected(_ item: HomeItem) -> Bool {
        return item.rank == 1
    }
}

// MARK: - Sources

extension HomeSource {
    static let tmdbPrefix = "tmdb-"

    /// The first page of a service's titles of one kind in a country, in an
    /// order: "tmdb-FR-8-movie-popular". In English, as the app names its
    /// titles (`TMDBStreamingClient.language`); « recent » stops at
    /// `today`, which the key does not hold (seen at the next refresh).
    ///
    /// Any answer, even an empty one, is a complete list: a small service,
    /// or a short « top rated » list, is fresh for its 12 hours and
    /// replaces a longer one (titles left the service, maybe all of them).
    /// The client answers nothing rather than a page with holes (a lookup
    /// without an answer), so a short answer is an honest one.
    static func streaming(service: Int, kind: HomeItem.Kind, sort: StreamingSort, region: String, today: String,
                          language: String? = nil) -> HomeSource {
        return HomeSource(key: "\(tmdbPrefix)\(region)-\(service)-\(kind.rawValue)-\(sort.rawValue)",
                          request: HomeRequest(host: .tmdb, path: TMDBStreamingClient.discoverPath(
                            service: service, kind: kind, region: region, page: 1, sort: sort, today: today, language: language)),
                          parser: .tmdbDiscover(kind), minimum: 0, allowsEmpty: true)
    }

    /// The region, service, kind and order of a streaming list's key.
    static func streaming(ofKey key: String) -> (region: String, service: Int, kind: HomeItem.Kind, sort: StreamingSort)? {
        guard key.hasPrefix(tmdbPrefix) else { return nil }
        let parts = key.dropFirst(tmdbPrefix.count).split(separator: "-")
        guard parts.count == 4, let service = Int(parts[1]), let kind = HomeItem.Kind(rawValue: String(parts[2])),
              let sort = StreamingSort(rawValue: String(parts[3])) else { return nil }
        return (String(parts[0]), service, kind, sort)
    }
}

// MARK: - Parser

extension HomeParse {

    /// A `discover` page as the client hands it over: {"results": […]},
    /// each result with the "imdb_id" the client found for it. A result
    /// without one is left out (the app cannot open it).
    static func tmdbDiscover(_ data: Data, kind: HomeItem.Kind) -> [HomeEntry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [Any] else { return nil }
        var seen = Set<String>()
        return results.compactMap { tmdbEntry($0 as? [String: Any], kind: kind) }
            .filter { seen.insert($0.item.imdbId).inserted }
    }

    static func tmdbEntry(_ result: [String: Any]?, kind: HomeItem.Kind) -> HomeEntry? {
        func text(_ key: String) -> String? {
            guard let value = (result?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        guard let imdbId = text("imdb_id"), isImdbId(imdbId),
              let title = text(kind == .movie ? "title" : "name") ?? text(kind == .movie ? "original_title" : "original_name") else { return nil }
        let date = text(kind == .movie ? "release_date" : "first_air_date")
        let year = date.flatMap { Int($0.prefix(4)) }.flatMap { (1880...2200).contains($0) ? $0 : nil }
        let votes = (result?["vote_count"] as? NSNumber)?.intValue ?? 0
        let rating = ((result?["vote_average"] as? NSNumber)?.doubleValue)
            .flatMap { $0 > 0 && $0.isFinite && votes >= 10 ? min($0, 10) : nil }
        let genres = ((result?["genre_ids"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber).flatMap { TMDBStreamingClient.genreNames[$0.intValue] } }
        var summary = text("overview")
        if let long = summary, long.count > summaryLimit {
            summary = String(long.prefix(summaryLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        let item = HomeItem(
            imdbId: imdbId, kind: kind, title: title, year: year, rating: rating, genres: genres, summary: summary,
            posterURL: text("poster_path").flatMap { URL(string: "https://image.tmdb.org/t/p/w500" + $0) } ?? HomeArtwork.poster(imdbId),
            backdropURL: text("backdrop_path").flatMap { URL(string: "https://image.tmdb.org/t/p/w1280" + $0) } ?? HomeArtwork.backdrop(imdbId),
            logoURL: HomeArtwork.logo(imdbId),
            date: CatalogDates.date(from: date))
        return HomeEntry(item: item, language: text("original_language"))
    }
}
