import Foundation

/// Keyless metadata sources standing in for Trakt and TMDB. The API keys this
/// app ships are dead: Trakt answers 403 Forbidden to every call (with or
/// without the key), TMDB answers "Invalid API key". Checked 2026-11-10.
///
/// - metahub.space (Stremio's public artwork service): logo, landscape
///   backdrop and poster by IMDb id. A missing image is a 404 after a redirect.
/// - YTS (movies): cast with character names and headshots (mapped by
///   `Movie(yts:)` from `movie_details?with_cast`) and 4 suggested movies.
/// - Cinemeta (Stremio's public catalog, `v3-cinemeta.strem.io`): directors and
///   writers of a title, and per-genre "top" catalogs for related titles.
/// - TVMaze (shows): cast with headshots and the creators.
///
/// `TraktManager.getRelated` / `getPeople` fall back to this when Trakt fails.
/// Every completion runs on the main queue.
public enum OpenMetadata {

    // MARK: - Artwork (metahub)

    private static let metahub = "https://images.metahub.space"

    /// Transparent title logo (PNG, about 800×310).
    public static func logoURL(imdbId: String) -> URL? {
        artwork("logo/medium", imdbId)
    }

    /// Landscape backdrop (1920×1080 JPEG).
    public static func backgroundURL(imdbId: String) -> URL? {
        artwork("background/large", imdbId)
    }

    /// 2:3 poster (about 580×860).
    public static func posterURL(imdbId: String) -> URL? {
        artwork("poster/medium", imdbId)
    }

    /// Cinemeta catalogs list small posters (about 230 px wide): ask metahub
    /// for the medium size instead.
    static func largerPoster(_ url: String) -> String {
        url.replacingOccurrences(of: "images.metahub.space/poster/small/", with: "images.metahub.space/poster/medium/")
    }

    private static func artwork(_ kind: String, _ imdbId: String) -> URL? {
        guard imdbId.hasPrefix("tt"), imdbId.count > 2 else { return nil }
        return URL(string: "\(metahub)/\(kind)/\(imdbId)/img")
    }

    // MARK: - People

    /// Cast and crew of a movie or a show.
    /// - Movies: Cinemeta's billed actors in billing order (YTS's headshots
    ///   and characters for the ones YTS lists), YTS's other actors, then
    ///   Cinemeta's directors and writers (names only).
    /// - Shows: TVMaze's cast (with headshots and characters) and creators.
    public static func people(forMediaOfType type: Trakt.MediaType, id: String,
                              completion: @escaping ([Actor], [Crew]) -> Void) {
        switch type {
        case .movies: moviePeople(imdbId: id, completion: completion)
        case .shows: showPeople(imdbId: id, completion: completion)
        default: DispatchQueue.main.async { completion([], []) }
        }
    }

    private static func moviePeople(imdbId: String, completion: @escaping ([Actor], [Crew]) -> Void) {
        let group = DispatchGroup()
        var ytsActors: [Actor] = []
        var meta: [String: Any]?

        if let provider = MediaProviders.shared as? YTSEZTVProvider {
            group.enter()
            provider.ytsMovieDetails(imdbId: imdbId) { movie in
                ytsActors = movie.flatMap(Movie.init(yts:))?.actors ?? []
                group.leave()
            }
        }
        group.enter()
        cinemetaMeta(type: "movie", imdbId: imdbId) { result in
            meta = result
            group.leave()
        }
        group.notify(queue: .main) {
            // Cinemeta's cast is in billing order, YTS's 4 actors are not
            // (The Dark Knight: Morgan Freeman first, no Bale or Ledger):
            // billing order, each actor with YTS's headshot and character
            // when YTS has them, then the YTS actors Cinemeta doesn't list.
            let key: (String) -> String = {
                $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            }
            let ytsByName = Dictionary(ytsActors.map { (key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
            var actors: [Actor] = []
            var known = Set<String>()
            for name in strings(meta?["cast"]) where known.insert(key(name)).inserted {
                actors.append(ytsByName[key(name)] ?? Actor(name: name, characterName: "", imdbId: "cinemeta:\(name)"))
            }
            for actor in ytsActors where known.insert(key(actor.name)).inserted {
                actors.append(actor)
            }
            var crew: [Crew] = []
            var seenCrew = Set<String>()
            for name in strings(meta?["director"]) where seenCrew.insert("d:" + name).inserted {
                crew.append(Crew(name: name, job: "Director".localized, roleType: .director, imdbId: "cinemeta:\(name)"))
            }
            for name in strings(meta?["writer"]) where seenCrew.insert("w:" + name).inserted {
                crew.append(Crew(name: name, job: "Writer".localized, roleType: .writer, imdbId: "cinemeta:\(name)"))
            }
            completion(actors, crew)
        }
    }

    private static func showPeople(imdbId: String, completion: @escaping ([Actor], [Crew]) -> Void) {
        let finish: ([Actor], [Crew]) -> Void = { actors, crew in
            DispatchQueue.main.async { completion(actors, crew) }
        }
        tvmazeShowId(imdbId: imdbId) { tvmazeId in
            guard let tvmazeId else { return finish([], []) }
            json("https://api.tvmaze.com/shows/\(tvmazeId)?embed[]=cast&embed[]=crew") { object in
                let embedded = (object as? [String: Any])?["_embedded"] as? [String: Any]
                var actors: [Actor] = []
                var seenActors = Set<Int>()
                for entry in embedded?["cast"] as? [[String: Any]] ?? [] {
                    guard let person = entry["person"] as? [String: Any],
                          let personId = person["id"] as? Int, seenActors.insert(personId).inserted,
                          let name = person["name"] as? String else { continue }
                    let character = (entry["character"] as? [String: Any])?["name"] as? String ?? ""
                    actors.append(Actor(name: name, characterName: character,
                                        imdbId: "tvmaze:\(personId)", largeImage: image(person["image"])))
                }
                var crew: [Crew] = []
                var seenCrew = Set<Int>()
                for entry in embedded?["crew"] as? [[String: Any]] ?? [] {
                    guard (entry["type"] as? String) == "Creator",
                          let person = entry["person"] as? [String: Any],
                          let personId = person["id"] as? Int, seenCrew.insert(personId).inserted,
                          let name = person["name"] as? String else { continue }
                    crew.append(Crew(name: name, job: "Creator".localized, roleType: .writer,
                                     imdbId: "tvmaze:\(personId)", largeImage: image(person["image"])))
                }
                finish(actors, crew)
            }
        }
    }

    // MARK: - Related titles

    /// How many related titles a page shows at most.
    static let relatedLimit = 12

    /// Titles to suggest next to `media`, without Trakt.
    /// - Movies: YTS's 4 suggestions, then Cinemeta's top movies of the
    ///   title's main genre that share the most genres with it.
    /// - Shows: Cinemeta's top series of the main genre, same ranking.
    public static func related(_ media: Media, completion: @escaping ([Media]) -> Void) {
        if let movie = media as? Movie {
            let group = DispatchGroup()
            var suggestions: [Movie] = []
            var similar: [Movie] = []
            if let provider = MediaProviders.shared as? YTSEZTVProvider {
                group.enter()
                provider.movieSuggestions(imdbId: movie.id) { movies in
                    suggestions = movies
                    group.leave()
                }
            }
            group.enter()
            sameGenre(type: "movie", genres: movie.genres, excluding: movie.id) { metas in
                similar = metas.compactMap(Movie.init(cinemeta:))
                group.leave()
            }
            group.notify(queue: .main) {
                completion(unique(suggestions + similar, excluding: movie.id))
            }
        } else if let show = media as? Show {
            sameGenre(type: "series", genres: show.genres, excluding: show.id) { metas in
                completion(unique(metas.compactMap(Show.init(cinemeta:)), excluding: show.id))
            }
        } else {
            DispatchQueue.main.async { completion([]) }
        }
    }

    private static func unique<T: Media>(_ items: [T], excluding id: String) -> [Media] {
        var seen: Set<String> = [id]
        return Array(items.filter { seen.insert($0.id).inserted }.prefix(relatedLimit))
    }

    /// Cinemeta's genres (the `top` catalog's genre filter) for the genres
    /// PopcornKit's sources use (YTS, TVMaze, Trakt), lowercased.
    private static let cinemetaGenres: [String: String] = {
        var map: [String: String] = [:]
        for genre in ["Action", "Adventure", "Animation", "Biography", "Comedy", "Crime", "Documentary",
                      "Drama", "Family", "Fantasy", "History", "Horror", "Mystery", "Romance", "Sci-Fi",
                      "Sport", "Thriller", "War", "Western"] {
            map[genre.lowercased()] = genre
        }
        map["science-fiction"] = "Sci-Fi"
        map["science fiction"] = "Sci-Fi"
        map["sports"] = "Sport"
        map["children"] = "Family"
        map["anime"] = "Animation"
        map["supernatural"] = "Fantasy"
        map["espionage"] = "Thriller"
        map["legal"] = "Crime"
        map["medical"] = "Drama"
        map["music"] = "Biography"
        map["musical"] = "Romance"
        map["film-noir"] = "Crime"
        return map
    }()

    /// Cinemeta's top titles of the first known genre, ranked by how many of
    /// `genres` they share (catalog order breaks ties), without `excluding`.
    private static func sameGenre(type: String, genres: [String], excluding id: String,
                                  completion: @escaping ([[String: Any]]) -> Void) {
        let wanted = genres.compactMap { cinemetaGenres[$0.lowercased()] }
        guard let main = wanted.first else { return DispatchQueue.main.async { completion([]) } }
        let wantedSet = Set(wanted)
        catalog(type: type, genre: main) { metas in
            let ranked = metas.enumerated()
                .filter { ($0.element["id"] as? String) != id }
                .map { index, meta -> (Int, Int, [String: Any]) in
                    let theirs = Set(strings(meta["genres"] ?? meta["genre"]))
                    return (theirs.intersection(wantedSet).count, index, meta)
                }
                .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
                .map(\.2)
            DispatchQueue.main.async { completion(ranked) }
        }
    }

    // MARK: - Cinemeta / TVMaze requests

    private static let cinemeta = "https://v3-cinemeta.strem.io"

    /// Catalogs are large (100–600 KB): keep the ones already fetched.
    private static let catalogCache = NSCache<NSString, NSArray>()

    private static func catalog(type: String, genre: String, completion: @escaping ([[String: Any]]) -> Void) {
        let key = "\(type)/\(genre)" as NSString
        if let hit = catalogCache.object(forKey: key) as? [[String: Any]] { return completion(hit) }
        let encoded = genre.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? genre
        json("\(cinemeta)/catalog/\(type)/top/genre=\(encoded).json") { object in
            let metas = (object as? [String: Any])?["metas"] as? [[String: Any]] ?? []
            if !metas.isEmpty { catalogCache.setObject(metas as NSArray, forKey: key) }
            completion(metas)
        }
    }

    private static func cinemetaMeta(type: String, imdbId: String, completion: @escaping ([String: Any]?) -> Void) {
        json("\(cinemeta)/meta/\(type)/\(imdbId).json") { object in
            completion((object as? [String: Any])?["meta"] as? [String: Any])
        }
    }

    private static func tvmazeShowId(imdbId: String, completion: @escaping (Int?) -> Void) {
        // Answers with a 301 to /shows/{id}, which URLSession follows.
        json("https://api.tvmaze.com/lookup/shows?imdb=\(imdbId)") { object in
            completion((object as? [String: Any])?["id"] as? Int)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    /// GET + JSON decode; nil on any failure. Calls back on a background queue.
    private static func json(_ urlString: String, completion: @escaping (Any?) -> Void) {
        guard let url = URL(string: urlString) else { return completion(nil) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            guard error == nil, let data,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return completion(nil)
            }
            completion(try? JSONSerialization.jsonObject(with: data))
        }.resume()
    }

    private static func strings(_ value: Any?) -> [String] {
        ((value as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// TVMaze `image` object → the medium portrait (proxied like other TVMaze art).
    private static func image(_ value: Any?) -> String? {
        let dict = value as? [String: Any]
        return ImageProxy.proxied(dict?["medium"] as? String ?? dict?["original"] as? String)
    }
}
