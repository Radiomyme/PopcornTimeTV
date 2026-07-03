

import UIKit
import PopcornKit

class ShowDetailViewController: DetailViewController {

    var show: Show {
        get {
            return currentItem as! Show
        } set(new) {
            currentItem = new
        }
    }
    
    override func loadMedia(id: String, completion: @escaping (Media?, NSError?) -> Void) {
        PopcornKit.getShowInfo(id) { (show, error) in
            
            if let error = error {
                completion(nil, error)
                return
            }
            
            guard var show = show, let season = show.latestUnwatchedEpisode()?.season ?? show.seasonNumbers.first else {
                let error = NSError(domain: "com.popcorntimetv.popcorntime.error", code: -243, userInfo: [NSLocalizedDescriptionKey: "There are no seasons available for the selected show. Please try again later.".localized])
                completion(nil, error)
                return
            }
            
            self.currentSeason = season
            
            let group = DispatchGroup()
            
            group.enter()
            TraktManager.shared.getRelated(show) { related, _ in
                show.related = related
                group.leave()
            }

            group.enter()
            TraktManager.shared.getPeople(forMediaOfType: .shows, id: show.id) { actors, crew, _ in
                show.actors = actors
                show.crew = crew
                group.leave()
            }
            
            group.enter()
            self.loadEpisodeMetadata(for: show) { episodes in
                show.episodes = episodes
                group.leave()
            }
            
            group.notify(queue: .main) {
                completion(show, nil)
            }
        }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "embedEpisodes" {
            super.prepare(for: segue, sender: sender)
            change(to: currentSeason)
        } else if let vc = segue.destination as? DescriptionCollectionViewController, segue.identifier == "embedInformation" {
            vc.headerTitle = "Information".localized
            
            vc.dataSource = [("Genre".localized, show.genres.first?.localizedCapitalized ?? "Unknown".localized), ("Released".localized, show.year), ("Run Time".localized, "\(show.runtime ?? 0) min"), ("Network".localized, show.network ?? "TV")]
            
            informationDescriptionCollectionViewController = vc
        } else if let vc = segue.destination as? CollectionViewController {
            
            if segue.identifier == "embedRelated" {
                relatedCollectionViewController = vc
                relatedCollectionViewController.dataSources = [show.related]
            } else if segue.identifier == "embedPeople" {
                peopleCollectionViewController = vc
                
                let dataSource = (show.actors as [AnyHashable]) + (show.crew as [AnyHashable])
                peopleCollectionViewController.dataSources = [dataSource]
            }
            
            super.prepare(for: segue, sender: sender)
        } else {
            super.prepare(for: segue, sender: sender)
        }
    }
    
    func loadEpisodeMetadata(for show: Show, completion: @escaping ([Episode]) -> Void) {
        // The provider (TVMaze) already supplies a per-episode still in
        // `largeBackgroundImage`, so only reach out to TMDB for episodes
        // that are still missing artwork. This matters now that a show's
        // detail carries its full episode guide — long-running series would
        // otherwise fire hundreds of screenshot requests on open.
        let group = DispatchGroup()

        var episodes = [Episode]()
        let lock = NSLock()

        for episode in show.episodes {
            if episode.largeBackgroundImage != nil {
                lock.lock(); episodes.append(episode); lock.unlock()
                continue
            }
            var episode = episode
            group.enter()
            TMDBManager.shared.getEpisodeScreenshots(forShowWithImdbId: show.id, orTMDBId: show.tmdbId, season: episode.season, episode: episode.episode, completion: { (tmdbId, image, error) in
                if let image = image { episode.largeBackgroundImage = image }
                if let tmdbId = tmdbId { episode.show?.tmdbId = tmdbId }
                lock.lock(); episodes.append(episode); lock.unlock()
                group.leave()
            })
        }

        group.notify(queue: .main) {
            episodes.sort { $0.season == $1.season ? $0.episode < $1.episode : $0.season < $1.season }
            completion(episodes)
        }
    }

    
    func change(to season: Int) {
        let localizedSeason = NumberFormatter.localizedString(from: NSNumber(value: season), number: .none)
        seasonsLabel.text = "Season".localized + " \(localizedSeason)"
        currentSeason = season
        episodesCollectionViewController.dataSource = show.episodes.filter({$0.season == season}).sorted(by: { $0.episode < $1.episode })
        episodesCollectionViewController.collectionView?.reloadData()
    }
}
