

import Foundation
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
/// `.gz` suffix makes the server return the plain file, in its original
/// code page (`SubEncoding`) and format (`SubFormat`) — both are kept on the
/// `Subtitle` so the players can decode/convert it (VLC's
/// `addPlaybackSlave` reads it directly).
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
                let subtitles = SubtitlesManager.bestSubtitles(from: rows)
                print("[Subtitles] \(url) -> \(rows.count) rows, \(subtitles.count) languages")
                DispatchQueue.main.async { completion(subtitles, nil) }
            }
        }
    }

    /// Best subtitle per language (`ISO639`), sorted by language name.
    ///
    /// Rows split over several CDs (`SubSumCD` > 1) are dropped: one file only
    /// covers part of the movie. The others are ranked by, in order:
    /// 1. format — SubRip / WebVTT / ASS-SSA first; MicroDVD / SubViewer
    ///    (.sub), .txt, MPL2, TMPlayer, SAMI next (converted on the fly, but
    ///    frame-based or lossy); anything else last;
    /// 2. not hearing-impaired before hearing-impaired (kept when it's all
    ///    there is);
    /// 3. not flagged bad (`SubBad`) before flagged;
    /// 4. rating × 10 000 + download count (rating is sparse — most rows are
    ///    0.0 — so "the one everyone uses" wins within a tier).
    static func bestSubtitles(from rows: [[String: Any]]) -> [Subtitle] {
        var subtitles = [Subtitle]()
        for info in rows {
            guard
                let rawLink = field(info["SubDownloadLink"]),
                let ISO639 = field(info["ISO639"]),
                let localizedLanguageName = languageName(ISO639: ISO639, englishName: field(info["LanguageName"]))
            else { continue }
            if let parts = Int(field(info["SubSumCD"]) ?? ""), parts > 1 { continue }
            // Without ".gz" the server returns the plain file.
            let link = rawLink.hasSuffix(".gz") ? String(rawLink.dropLast(3)) : rawLink
            let format = field(info["SubFormat"])?.lowercased()
            let hearingImpaired = field(info["SubHearingImpaired"]) == "1"
            let score = SubtitlesManager.score(format: format,
                                               hearingImpaired: hearingImpaired,
                                               flaggedBad: field(info["SubBad"]) == "1",
                                               rating: Double(field(info["SubRating"]) ?? "") ?? 0,
                                               downloads: Double(field(info["SubDownloadsCnt"]) ?? "") ?? 0)
            let subtitle = Subtitle(language: localizedLanguageName,
                                    link: link,
                                    ISO639: ISO639,
                                    rating: score,
                                    format: format,
                                    encoding: field(info["SubEncoding"]),
                                    releaseName: field(info["MovieReleaseName"]),
                                    hearingImpaired: hearingImpaired,
                                    frameRate: Double(field(info["MovieFPS"]) ?? ""))

            if let index = subtitles.firstIndex(where: { $0.ISO639 == ISO639 }) {
                if score > subtitles[index].rating {
                    subtitles[index] = subtitle
                }
            } else {
                subtitles.append(subtitle)
            }
        }
        subtitles.sort(by: { $0.language < $1.language })
        return subtitles
    }

    /// Lexicographic score: each criterion outweighs everything after it
    /// (rating × 10 000 ≤ 100 000; downloads are capped below 10^10).
    static func score(format: String?, hearingImpaired: Bool, flaggedBad: Bool, rating: Double, downloads: Double) -> Double {
        let formatRank: Double
        switch format ?? "" {
        case "srt", "vtt", "webvtt", "ass", "ssa":
            formatRank = 3
        case "":
            formatRank = 2.5        // not reported; almost always SubRip
        case "sub", "txt", "mpl", "mpl2", "smi", "sami", "tmp":
            formatRank = 2
        default:
            formatRank = 1          // psb, jss, dks…: only VLC may read them
        }
        let popularity = max(0, min(rating * 10_000 + downloads, 9e9))
        return formatRank * 1e12
            + (hearingImpaired ? 0 : 1e11)
            + (flaggedBad ? 0 : 1e10)
            + popularity
    }

    /// Localized, capitalized language name — including OpenSubtitles' own
    /// codes (pb = Brazilian Portuguese, zt = Traditional Chinese, …) that
    /// `Locale` doesn't know, which used to drop those rows.
    private static func languageName(ISO639: String, englishName: String?) -> String? {
        let locale = Locale.current
        let name: String?
        switch ISO639.lowercased() {
        case "pb": name = locale.localizedString(forIdentifier: "pt_BR")
        case "zt": name = locale.localizedString(forIdentifier: "zh_Hant")
        case "ze": name = locale.localizedString(forLanguageCode: "zh").map { "\($0) (bilingue)" }
        case "sp": name = locale.localizedString(forIdentifier: "es_ES")
        case "ea": name = locale.localizedString(forIdentifier: "es_419")
        case "me": name = locale.localizedString(forLanguageCode: "cnr")
        default:   name = locale.localizedString(forLanguageCode: ISO639)
        }
        return (name ?? englishName)?.localizedCapitalized
    }

    /// OpenSubtitles sends every value as a string; tolerate numbers, and
    /// treat empty strings as missing.
    private static func field(_ value: Any?) -> String? {
        let text: String?
        if let string = value as? String {
            text = string
        } else if let number = value as? NSNumber {
            text = number.stringValue
        } else {
            text = nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Legacy XML-RPC session no-ops, kept so existing call sites build.
    public func login(_ completion: ((NSError?) -> Void)?) {
        DispatchQueue.main.async { completion?(nil) }
    }

    open func logout(completion: ((NSError?) -> Void)? = nil) {
        DispatchQueue.main.async { completion?(nil) }
    }
}
