

import Foundation
import PopcornKit

extension Episode {

    /// Aired (an unknown date counts as aired) or already offered by a
    /// torrent. The episode guide also lists announced episodes, with a future
    /// air date and no torrent: they can't be played yet.
    var isAvailableToPlay: Bool {
        firstAirDate <= Date() || !torrents.isEmpty
    }
}

extension Show {
    
    /**
     The episode the user's history leads to: the one to resume, the next one after the last one finished, or — when that one has not aired yet — the episode awaited. `nil` for a show not begun (or finished).

     The rule is `NextUpRule` (PopcornKit), shared with Play, the Continue Watching row and the other platforms: the last episode *played* counts (not the highest one touched), an episode only opened does not, specials and gaps in the numbering are stepped over.

     - Parameter episodes:  Optionally pass in a specific subset of the shows episodes. Otherwise `episodes` array on this object will be used.

     - Returns: Latest unwatched, or currently watching, episode, if any.
     */
    func latestUnwatchedEpisode(from episodes: [Episode]? = nil) -> Episode? {
        let episodes = episodes ?? self.episodes
        guard episodes.filter({$0.show == self}).count == episodes.count else { return nil } // Make sure all of the episodes are of the current show.
        return watchPosition(in: episodes).current
    }
}
