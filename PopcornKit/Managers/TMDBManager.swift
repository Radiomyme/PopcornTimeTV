

import Foundation
import Alamofire

open class TMDBManager: NetworkManager {

    public static let shared = TMDBManager()

    private static func firstFilePath(in dict: [String: Any], key: String, prefix: String) -> String? {
        guard let array = dict[key] as? [[String: Any]],
              let path  = array.first?["file_path"] as? String else { return nil }
        return prefix + path
    }

    private func fetchJSON(_ url: String,
                           parameters: [String: Any],
                           completion: @escaping ([String: Any]?, NSError?) -> Void) {
        AF.request(url, parameters: parameters).validate().responseData { response in
            switch response.result {
            case .success(let data):
                guard
                    let raw  = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                    let dict = raw as? [String: Any]
                else { completion(nil, nil); return }
                completion(dict, nil)
            case .failure(let error):
                completion(nil, error as NSError)
            }
        }
    }

    open func getPoster(forMediaOfType type: TMDB.MediaType,
                        withImdbId imdb: String? = nil,
                        orTMDBId tmdb: Int? = nil,
                        completion: @escaping (Int?, String?, NSError?) -> Void) {

        guard let id = tmdb else {
            guard let id = imdb else { completion(nil, nil, nil); return }
            TraktManager.shared.getTMDBId(forImdbId: id) { tmdb, error in
                guard let tmdb = tmdb else { completion(nil, nil, error); return }
                self.getPoster(forMediaOfType: type, orTMDBId: tmdb, completion: completion)
            }
            return
        }

        fetchJSON(TMDB.base + "/" + type.rawValue + "/\(id)" + TMDB.images,
                  parameters: TMDB.defaultHeaders) { dict, error in
            guard let dict = dict else { completion(id, nil, error); return }
            completion(id, TMDBManager.firstFilePath(in: dict, key: "posters", prefix: "https://image.tmdb.org/t/p/w1000"), nil)
        }
    }

    open func getSeasonPoster(ofShowWithImdbId imdb: String? = nil,
                              orTMDBId tmdb: Int? = nil,
                              season: Int,
                              completion: @escaping (Int?, String?, NSError?) -> Void) {
        guard let id = tmdb else {
            guard let id = imdb else { completion(nil, nil, nil); return }
            TraktManager.shared.getTMDBId(forImdbId: id) { tmdb, error in
                guard let tmdb = tmdb else { completion(nil, nil, error); return }
                self.getSeasonPoster(orTMDBId: tmdb, season: season, completion: completion)
            }
            return
        }

        fetchJSON(TMDB.base + TMDB.tv + "/\(id)" + TMDB.season + "/\(season)" + TMDB.images,
                  parameters: TMDB.defaultHeaders) { dict, error in
            guard let dict = dict else { completion(id, nil, error); return }
            completion(id, TMDBManager.firstFilePath(in: dict, key: "posters", prefix: "https://image.tmdb.org/t/p/w500"), nil)
        }
    }

    open func getEpisodeScreenshots(forShowWithImdbId imdb: String? = nil,
                                    orTMDBId tmdb: Int? = nil,
                                    season: Int,
                                    episode: Int,
                                    completion: @escaping (Int?, String?, NSError?) -> Void) {
        guard let id = tmdb else {
            guard let id = imdb else { completion(nil, nil, nil); return }
            TraktManager.shared.getTMDBId(forImdbId: id) { tmdb, error in
                guard let tmdb = tmdb else { completion(nil, nil, error); return }
                self.getEpisodeScreenshots(orTMDBId: tmdb, season: season, episode: episode, completion: completion)
            }
            return
        }

        fetchJSON(TMDB.base + TMDB.tv + "/\(id)" + TMDB.season + "/\(season)" + TMDB.episode + "/\(episode)" + TMDB.images,
                  parameters: TMDB.defaultHeaders) { dict, error in
            guard let dict = dict else { completion(id, nil, error); return }
            completion(id, TMDBManager.firstFilePath(in: dict, key: "stills", prefix: "https://image.tmdb.org/t/p/w1920"), nil)
        }
    }

    open func getCharacterHeadshots(forPersonWithImdbId imdb: String? = nil,
                                    orTMDBId tmdb: Int? = nil,
                                    completion: @escaping (Int?, String?, NSError?) -> Void) {
        guard let id = tmdb else {
            guard let id = imdb else { completion(nil, nil, nil); return }
            TraktManager.shared.getTMDBId(forImdbId: id) { tmdb, error in
                guard let tmdb = tmdb else { completion(nil, nil, error); return }
                self.getCharacterHeadshots(orTMDBId: tmdb, completion: completion)
            }
            return
        }

        fetchJSON(TMDB.base + TMDB.person + "/\(id)" + TMDB.images,
                  parameters: TMDB.defaultHeaders) { dict, error in
            guard let dict = dict else { completion(id, nil, error); return }
            completion(id, TMDBManager.firstFilePath(in: dict, key: "profiles", prefix: "https://image.tmdb.org/t/p/w1000"), nil)
        }
    }

    open func getLogo(forMediaOfType type: Trakt.MediaType,
                      id: String,
                      completion: @escaping (String?, NSError?) -> Void) {
        fetchJSON(Fanart.base + (type == .movies ? Fanart.movies : Fanart.tv) + "/\(id)",
                  parameters: Fanart.defaultParameters) { dict, error in
            guard let dict = dict else { completion(nil, error); return }
            let typeString = type == .movies ? "movie" : "tv"
            let logos = dict["hd\(typeString)logo"] as? [[String: Any]]
            let image = logos?.first(where: { ($0["lang"] as? String) == "en" })?["url"] as? String
            completion(image, nil)
        }
    }
}
