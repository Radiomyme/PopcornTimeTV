

import Foundation
import PopcornKit

class MovieDetailViewController: DetailViewController {

    var movie: Movie {
        get {
           return currentItem as! Movie
        } set(new) {
            currentItem = new
        }
    }

    /// The detail storyboard is shared with shows: it embeds an Episodes
    /// container that shows "0 EPISODES" + a "LABEL / Lorem ipsum / Download"
    /// placeholder when no episodes are present (movie case). Collapse the
    /// container's height to 0 on load so a movie page shows only Cast, Info,
    /// Related — same behaviour as the legacy Popcorn UI.
    override func viewDidLoad() {
        super.viewDidLoad()
        episodesContainerViewHeightConstraint.constant = 0
        episodesContainerViewHeightConstraint.priority = .required
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        // Ignore the embedded EpisodesCollectionViewController so it can
        // never reopen the container we just collapsed.
        if let vc = container as? UIViewController, vc === episodesCollectionViewController {
            return
        }
        super.preferredContentSizeDidChange(forChildContentContainer: container)
    }
    
    override func loadMedia(id: String, completion: @escaping (Media?, NSError?) -> Void) {
        PopcornKit.getMovieInfo(id) { (movie, error) in
            guard var movie = movie else {
                completion(nil, error)
                return
            }
            let group = DispatchGroup()
                
            group.enter()
            TraktManager.shared.getRelated(movie) { related, _ in
                movie.related = related
                group.leave()
            }

            group.enter()
            TraktManager.shared.getPeople(forMediaOfType: .movies, id: movie.id) { actors, crew, _ in
                movie.actors = actors
                movie.crew = crew
                group.leave()
            }
            
            group.notify(queue: .main) {
                completion(movie, nil)
            }
        }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if let vc = segue.destination as? DescriptionCollectionViewController, segue.identifier == "embedInformation" {
            vc.headerTitle = "Information".localized
            
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .short
            formatter.allowedUnits = [.hour, .minute]
            
            vc.dataSource = [("Genre".localized, movie.genres.first?.localizedCapitalized ?? "Unknown".localized), ("Released".localized, movie.year), ("Run Time".localized, formatter.string(from: TimeInterval(movie.runtime) * 60) ?? "0 min"), ("Rating".localized, movie.certification)]
            
            informationDescriptionCollectionViewController = vc
        } else if let vc = segue.destination as? CollectionViewController {
            
            if segue.identifier == "embedRelated" {
                relatedCollectionViewController = vc
                relatedCollectionViewController.dataSources = [movie.related]
            } else if segue.identifier == "embedPeople" {
                peopleCollectionViewController = vc
                
                let dataSource = (movie.actors as [AnyHashable]) + (movie.crew as [AnyHashable])
                peopleCollectionViewController.dataSources = [dataSource]
            }
            
            super.prepare(for: segue, sender: sender)
        } else {
            super.prepare(for: segue, sender: sender)
        }
    }
}
