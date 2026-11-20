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

    /// The services of someone who chose none: the four that are in most
    /// countries. No logo: a card without one shows the name (choosing the
    /// services in Settings stores TMDB's logos).
    public static let defaults: [StreamingService] = [
        StreamingService(id: 8, name: "Netflix"),
        StreamingService(id: 119, name: "Prime Video"),
        StreamingService(id: 337, name: "Disney+"),
        StreamingService(id: 350, name: "Apple TV+"),
    ]
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
    /// order: "tmdb-FR-8-movie-popular". The language of the titles and
    /// summaries follows the device's, and « recent » stops at `today`; the
    /// key holds neither (they are seen at the next refresh).
    static func streaming(service: Int, kind: HomeItem.Kind, sort: StreamingSort, region: String, today: String,
                          language: String? = nil) -> HomeSource {
        return HomeSource(key: "\(tmdbPrefix)\(region)-\(service)-\(kind.rawValue)-\(sort.rawValue)",
                          request: HomeRequest(host: .tmdb, path: TMDBStreamingClient.discoverPath(
                            service: service, kind: kind, region: region, page: 1, sort: sort, today: today, language: language)),
                          parser: .tmdbDiscover(kind), minimum: 10, allowsEmpty: true)
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
