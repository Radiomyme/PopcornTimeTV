import Foundation

/// The streaming shelves ("On Netflix", "On Disney+"): what each service
/// offers in the user's country, from TMDB's `discover` with its watch
/// providers (JustWatch's data, which TMDB asks apps to credit).
///
/// One shelf per service the user chose (`HomeSettings.streamingServices`),
/// made of two lists — the service's most popular movies and shows in that
/// country, page 1 of each — and a See All that pages through the whole
/// catalogue (`TMDBStreamingClient.CataloguePages`). TMDB knows its titles
/// by TMDB ids: the client gives every answer its titles' IMDb ids before
/// the parser reads it (the hub and the app know titles by IMDb id), and a
/// title without one is left out.

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
        return logoPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w154" + $0) }
    }

    /// The services of someone who chose none: the four that are in most
    /// countries.
    public static let defaults: [StreamingService] = [
        StreamingService(id: 8, name: "Netflix"),
        StreamingService(id: 119, name: "Prime Video"),
        StreamingService(id: 337, name: "Disney+"),
        StreamingService(id: 350, name: "Apple TV+"),
    ]
}

// MARK: - Shelves

extension HomeShelfID {
    static let streamingPrefix = "streaming-"

    /// The id of a service's shelf: "streaming-8".
    public static func streaming(_ service: Int) -> String {
        return "\(streamingPrefix)\(service)"
    }

    /// The TMDB provider id of a streaming shelf, nil for the other shelves.
    public static func streamingService(of id: String) -> Int? {
        guard id.hasPrefix(streamingPrefix) else { return nil }
        return Int(id.dropFirst(streamingPrefix.count))
    }
}

// MARK: - Sources

extension HomeSource {
    static let tmdbPrefix = "tmdb-"

    /// One page of a service's catalogue in a country, most popular first:
    /// "tmdb-FR-8-movie". The language of the titles and summaries follows
    /// the device's; the key does not (a change of language is seen at the
    /// next refresh).
    static func streaming(service: Int, kind: HomeItem.Kind, region: String, language: String? = nil) -> HomeSource {
        return HomeSource(key: "\(tmdbPrefix)\(region)-\(service)-\(kind.rawValue)",
                          request: HomeRequest(host: .tmdb, path: TMDBStreamingClient.discoverPath(service: service, kind: kind,
                                                                                               region: region, page: 1,
                                                                                               language: language)),
                          parser: .tmdbDiscover(kind), minimum: 10, allowsEmpty: true)
    }

    /// The region, service and kind of a streaming list's key.
    static func streaming(ofKey key: String) -> (region: String, service: Int, kind: HomeItem.Kind)? {
        guard key.hasPrefix(tmdbPrefix) else { return nil }
        let parts = key.dropFirst(tmdbPrefix.count).split(separator: "-")
        guard parts.count == 3, let service = Int(parts[1]), let kind = HomeItem.Kind(rawValue: String(parts[2])) else { return nil }
        return (String(parts[0]), service, kind)
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
