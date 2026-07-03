

import Alamofire

/// Manager for subtitle search.
///
/// Backed by the OpenSubtitles legacy REST API (rest.opensubtitles.org).
/// Unlike the retired XML-RPC endpoint this is plain JSON over GET and needs
/// no login roundtrip — just a User-Agent header. Search parameters are path
/// components that must be joined in alphabetical order:
///
///   movies:   /search/imdbid-0111161
///   episodes: /search/episode-2/imdbid-0944947/season-1
///
/// Each result row carries a direct `SubDownloadLink` (gzip); dropping the
/// `.gz` suffix makes the server return the plain .srt, which VLC's
/// `addPlaybackSlave` consumes directly.
open class SubtitlesManager: NetworkManager {

    /// Creates new instance of SubtitlesManager class
    public static let shared = SubtitlesManager()

    private static let base = "https://rest.opensubtitles.org/search"
    // The literal "TemporaryUserAgent" is the documented anonymous UA for
    // the legacy REST endpoint; custom UAs get 414'd.
    private static let headers: HTTPHeaders = [
        "User-Agent": "TemporaryUserAgent",
        "Accept":     "application/json",
    ]

    /**
     Search subtitles for a movie or an episode.

     - Parameter episode:    The show episode. When set (together with its show's imdb id passed via `imdbId`, or its own `imdbId`), season/episode filters are applied.
     - Parameter imdbId:     The imdb id of the movie — or of the show when `episode` is provided.
     - Parameter limit:      Unused (kept for source compatibility with the legacy XML-RPC signature).

     - Parameter completion: Called on the main queue with the best subtitle per language, sorted by language name.
     */
    open func search(_ episode: Episode? = nil,
                     imdbId: String? = nil,
                     limit: String = "500",
                     completion: @escaping ([Subtitle], NSError?) -> Void) {

        var components: [String] = []
        if let episode = episode {
            let showImdb = imdbId ?? episode.show?.id
            guard let showImdb = showImdb, showImdb.hasPrefix("tt") else {
                // No imdb anchor — fall back to a free-text query.
                let query = "\(episode.show?.title ?? episode.title)".slugged.replacingOccurrences(of: "-", with: " ")
                components = ["episode-\(episode.episode)",
                              "query-\(query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query)",
                              "season-\(episode.season)"]
                return request(components: components, completion: completion)
            }
            components = ["episode-\(episode.episode)",
                          "imdbid-\(showImdb.replacingOccurrences(of: "tt", with: ""))",
                          "season-\(episode.season)"]
        } else if let imdbId = imdbId {
            components = ["imdbid-\(imdbId.replacingOccurrences(of: "tt", with: ""))"]
        } else {
            DispatchQueue.main.async { completion([], nil) }
            return
        }
        request(components: components, completion: completion)
    }

    private func request(components: [String], completion: @escaping ([Subtitle], NSError?) -> Void) {
        // Alphabetical order of path components is a hard API requirement.
        let url = SubtitlesManager.base + "/" + components.sorted().joined(separator: "/")
        self.manager.request(url, headers: SubtitlesManager.headers).validate().responseData { response in
            switch response.result {
            case .failure(let error):
                print("[Subtitles] \(url) FAILED: \(error.localizedDescription)")
                DispatchQueue.main.async { completion([], error.underlyingError as NSError? ?? error as NSError) }
            case .success(let data):
                let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
                var subtitles = [Subtitle]()
                for info in rows {
                    guard
                        let link = (info["SubDownloadLink"] as? String)?.replacingOccurrences(of: ".gz", with: ""),
                        let ISO639 = info["ISO639"] as? String,
                        let localizedLanguageName = Locale.current.localizedString(forLanguageCode: ISO639)?.localizedCapitalized
                    else { continue }
                    let rating = Double(info["SubRating"] as? String ?? "") ?? 0
                    let downloads = Double(info["SubDownloadsCnt"] as? String ?? "") ?? 0
                    // Rating is sparse (most rows are 0.0); weight it with the
                    // download count so "the one everyone uses" wins per language.
                    let score = rating * 10_000 + downloads
                    let subtitle = Subtitle(language: localizedLanguageName, link: link, ISO639: ISO639, rating: score)

                    if let index = subtitles.firstIndex(where: { $0.ISO639 == ISO639 }) {
                        if score > subtitles[index].rating {
                            subtitles[index] = subtitle
                        }
                    } else {
                        subtitles.append(subtitle)
                    }
                }
                subtitles.sort(by: { $0.language < $1.language })
                print("[Subtitles] \(url) -> \(rows.count) rows, \(subtitles.count) languages")
                DispatchQueue.main.async { completion(subtitles, nil) }
            }
        }
    }

    /// Legacy XML-RPC session no-ops, kept so existing call sites build.
    public func login(_ completion: ((NSError?) -> Void)?) {
        DispatchQueue.main.async { completion?(nil) }
    }

    open func logout(completion: ((NSError?) -> Void)? = nil) {
        DispatchQueue.main.async { completion?(nil) }
    }
}
