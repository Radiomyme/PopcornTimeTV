

import Foundation
import ObjectMapper

private struct Static {
    static var movieInstance: WatchlistManager<Movie>? = nil
    static var showInstance: WatchlistManager<Show>? = nil
}

typealias jsonArray = [[String : Any]]

/// Class for managing a users watchlist.
///
/// Since 5.3.0 a façade over `Library.shared`: `isAdded` is a set lookup (it
/// used to rebuild every model of the list with ObjectMapper), a title is
/// stored once, and a change posts `.libraryDidChange`. The UserDefaults keys
/// and the stored JSON are the ones of 4.x / 5.x.
open class WatchlistManager<N: Media> {
    
    private let currentType: Trakt.MediaType
    
    /// Creates new instance of WatchlistManager class with type of Shows.
    public class var show: WatchlistManager<Show> {
        DispatchQueue.once(token: "ShowWatchlist") {
            Static.showInstance = WatchlistManager<Show>()
        }
        return Static.showInstance!
    }
    
    /// Creates new instance of WatchlistManager class with type of Movies.
    public class var movie: WatchlistManager<Movie> {
        DispatchQueue.once(token: "MovieWatchlist") {
            Static.movieInstance = WatchlistManager<Movie>()
        }
        return Static.movieInstance!
    }
    
    private init?() {
        switch N.self {
        case is Movie.Type:
            currentType = .movies
        case is Show.Type:
            currentType = .shows
        default:
            return nil
        }
    }
    
    /**
     Toggles media in users watchlist and syncs with Trakt if available.
     
     - Parameter media: The media to add or remove.
     */
    open func toggle(_ media: N) {
        isAdded(media) ? remove(media): add(media)
    }
    
    /**
     Adds media to users watchlist and syncs with Trakt if available.
     
     - Parameter media: The media to add.
     */
    open func add(_ media: N) {
        TraktManager.shared.add(media.id, toWatchlistOfType: currentType)
        Library.shared.addToWatchlist(Mapper<N>().toJSON(media), id: media.id, list: currentType)
        // A watchlisted show is followed: its guide is what new episodes are
        // worked out from.
        if let show = media as? Show { Library.shared.noteGuide(of: show, always: true) }
        if let title = TasteTitle(media: media) { ProfileTaste.shared.noteWatchlist(true, of: title) }
    }
    
    /**
     The title's record has arrived on its page: if the title is in the watchlist, its stored entry gets what it lacked — the page can be added to the list before its record is in (a link's id, a Continue Watching card), and the Watchlist would show a card without a title or a year.

     - Parameter media: The title, completed by its record.
     */
    open func complete(_ media: N) {
        guard isAdded(media) else { return }
        Library.shared.completeWatchlistEntry(Mapper<N>().toJSON(media), id: media.id, list: currentType)
    }

    /**
     Removes media from users watchlist and syncs with Trakt if available.
     
     - Parameter media: The media to remove.
     */
    open func remove(_ media: N) {
        TraktManager.shared.remove(media.id, fromWatchlistOfType: currentType)
        Library.shared.removeFromWatchlist(id: media.id, list: currentType)
        if let title = TasteTitle(media: media) { ProfileTaste.shared.noteWatchlist(false, of: title) }
    }
    
    /**
     Checks media is in the watchlist.
     
     - Parameter media: The media.
     
     - Returns: Boolean indicating if media is in the users watchlist.
     */
    open func isAdded(_ media: N) -> Bool {
        return Library.shared.isInWatchlist(media.id, currentType)
    }
    
    /**
     Gets watchlist locally first and then from Trakt if available.
     
     - Parameter completion: If Trakt is available, completion will be called with a more up-to-date watchlist that will replace the locally stored one and should be reloaded for the user.
     
     - Returns: Locally stored watchlist (may be out of date if user has authenticated with trakt).
     */
    @discardableResult open func getWatchlist(_ completion: (([N]) -> Void)? = nil) -> [N] {
        TraktManager.shared.getWatchlist(forMediaOfType: N.self) { [unowned self] (medias, error) in
            guard error == nil else {return}
            Library.shared.replaceWatchlist(Mapper<N>().toJSONArray(medias), list: self.currentType)
            completion?(medias)
        }
        
        return storedWatchlist()
    }

    /**
     The locally stored watchlist only, without asking Trakt: what to read again on `.libraryDidChange` (asking Trakt there would replace the list, which posts the notification again).
     */
    open func storedWatchlist() -> [N] {
        // Decoded once per change of the list; one entry per title (5.2
        // could store the same title twice).
        return Library.shared.state.watchlistModels(currentType) { array in
            var seen = Set<String>()
            return Mapper<N>().mapArray(JSONArray: array).filter { seen.insert($0.id).inserted }
        }
    }
}
