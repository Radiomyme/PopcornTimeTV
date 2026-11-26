

import Foundation
import ObjectMapper

private struct Static {
    static var episodeInstance: WatchedlistManager<Episode>? = nil
    static var movieInstance: WatchedlistManager<Movie>? = nil
}

/// Class for managing a users watch history. **Only available for movies, and episodes**.
///
/// Since 5.3.0 a façade: the lists live in `Library.shared`, which serves the
/// reads from memory (they used to re-read the whole UserDefaults list on
/// every call), dates every position saved (the Continue Watching row) and
/// posts `.libraryDidChange` after a write. The UserDefaults keys and their
/// shapes are the ones of 4.x / 5.x.
open class WatchedlistManager<N: Media & Hashable> {
    
    private let currentType: Trakt.MediaType
    
    /// Creates new instance of WatchedlistManager class with type of Episodes.
    public class var episode: WatchedlistManager<Episode> {
        DispatchQueue.once(token: "EpisodeWatchedlist") {
            Static.episodeInstance = WatchedlistManager<Episode>()
        }
        return Static.episodeInstance!
    }
    
    /// Creates new instance of WatchlistManager class with type of Movies.
    public class var movie: WatchedlistManager<Movie> {
        DispatchQueue.once(token: "MovieWatchedlist") {
            Static.movieInstance = WatchedlistManager<Movie>()
        }
        return Static.movieInstance!
    }
    
    private init?() {
        switch N.self {
        case is Movie.Type:
            currentType = .movies
        case is Episode.Type:
            currentType = .episodes
        default:
            return nil
        }
    }
    
    /**
     Toggles a users watched status on the passed in media id and syncs with Trakt if available.
     
     - Parameter id: The imdbId for movie or tvdbId for episode.
     */
    open func toggle(_ id: String) {
        isAdded(id) ? remove(id): add(id)
    }
    
    /**
     Adds movie or episode to watchedlist and syncs with Trakt if available.
     
     - Parameter id: The imdbId or tvdbId of the movie or episode.
     */
    open func add(_ id: String) {
        TraktManager.shared.add(id, toWatchedlistOfType: currentType)
        Library.shared.setWatched(true, id: id, list: currentType)
        ProfileTaste.shared.noteWatched(true, mediaID: id, kind: currentType == .movies ? .movie : .show)
    }
    
    /**
     Removes movie or episode from a users watchedlist, sets its progress to 0.0 and syncs with Trakt if available.
     
     - Parameter id: The imdbId for movie or tvdbId for episode.
     */
    open func remove(_ id: String) {
        TraktManager.shared.remove(id, fromWatchedlistOfType: currentType)
        TraktManager.shared.scrobble(id, progress: 0, type: currentType, status: .finished)
        Library.shared.setWatched(false, id: id, list: currentType)
        ProfileTaste.shared.noteWatched(false, mediaID: id, kind: currentType == .movies ? .movie : .show)
    }
    
    /**
     Checks if movie or episode is in the watchedlist.
     
     - Parameter id: The imdbId for movie or tvdbId for episode.
     
     - Returns: Boolean indicating if movie or episode is in watchedlist.
     */
    open func isAdded(_ id: String) -> Bool {
        return Library.shared.isWatched(id, currentType)
    }
    
    /**
     Gets watchedlist locally first and then from Trakt.
     
     - Parameter completion: Called if local watchedlist was updated from trakt.
     
     - Returns: Locally stored watchedlist imdbId's (may be out of date if user has authenticated with trakt).
     */
    @discardableResult open func getWatched(completion: (([N]) -> Void)? = nil) -> [String] {
        // Into the marks of the profile whose account was asked, whoever is
        // watching when the answer arrives.
        let list = currentType
        let deliver = ProfileManager.shared.answerForActiveProfile(write: { (profileID, medias: [N]) in
            // Added to the local marks, never in their place: Trakt names
            // an episode by its TVDB number, the app by "tt…-sXeY".
            Library.library(for: profileID).mergeFromTrakt(watched: medias.map({ $0.id }), list: list)
        }, show: completion)
        TraktManager.shared.getWatched(forMediaOfType: N.self) { (medias, error) in
            guard error == nil else { return }
            deliver(medias)
        }
        
        return storedWatched()
    }

    /**
     The locally stored watched imdbId's only, without asking Trakt: what to read again on `.libraryDidChange`.
     */
    open func storedWatched() -> [String] {
        return Library.shared.state.watchedIDs(currentType)
    }
    
    /**
     Stores movie progress and syncs with Trakt if available.
     
     - Parameter progress:  The progress of the playing video. Possible values range from 0...1.
     - Parameter id:        The imdbId for movies and tvdbId for episodes of the media that is playing.
     - Parameter status:    The status of the item.
     */
    open func setCurrentProgress(_ progress: Float, for id: String, with status: Trakt.WatchedStatus) {
        setCurrentProgress(progress, for: id, with: status, details: nil)
    }

    /**
     Stores movie progress like `setCurrentProgress(_:for:with:)`, with what the player knows about the title (`PlaybackRecorder.save` builds it): its titles, the position and the duration in seconds. They go to the title's Continue Watching entry.

     The one place a playback position is written: `Library.setProgress` stores the fraction, dates the entry and marks the title watched from 80 % (`LibraryPolicy.watchedFraction`).
     */
    public func setCurrentProgress(_ progress: Float, for id: String, with status: Trakt.WatchedStatus, details: PlaybackDetails?) {
        TraktManager.shared.scrobble(id, progress: progress, type: currentType, status: status)
        if Library.shared.setProgress(progress, id: id, list: currentType, details: details) {
            TraktManager.shared.add(id, toWatchedlistOfType: currentType)
        }
    }
    
    /**
     Retrieves latest progress from Trakt and updates local storage.
     
     - Important: Local watchedlist may be more up-to-date than Trakt version but local version will be replaced with Trakt version regardless.
     
     - Parameter completion: Optional completion handler called when progress has been retrieved from trakt. May never be called if user hasn't authenticated with Trakt.
     
     - Returns: Locally stored progress (may be out of date if user has authenticated with trakt).
     */
    @discardableResult open func getProgress(completion: (([N: Float]) -> Void)? = nil) -> [String: Float] {
        // Into the positions of the profile whose account was asked, whoever
        // is watching when the answer arrives (one title lookup per entry
        // comes first: seconds).
        let list = currentType
        let deliver = ProfileManager.shared.answerForActiveProfile(write: { (profileID, dict: [N: Float]) in
            var progress: [String: Float] = [:]
            for (media, value) in dict { progress[media.id] = value }
            Library.library(for: profileID).mergeFromTrakt(progress: progress, list: list)
        }, show: completion)
        TraktManager.shared.getPlaybackProgress(forMediaOfType: N.self) { (dict, error) in
            guard error == nil else { return }
            deliver(dict)
        }
        
        return Library.shared.state.allProgress(currentType)
    }
    
    /**
     Gets watched progress for movie or epsiode.
     
     - Parameter id: The imdbId for movie or tvdbId for episode.
     
     - Returns: The users last play position progress from 0.0 to 1.0 (if any).
     */
    open func currentProgress(_ id: String) -> Float {
        return Library.shared.progress(id, currentType)
    }
    
    /**
     Retrieves media that the user is currently watching.
     
     - Parameter completion: Optional completion handler called when on deck media has been retrieved from trakt. May never be called if user hasn't authenticated with Trakt.
     
     - Returns: Locally stored on deck media id's (may be out of date if user has authenticated with trakt).
     */
    @discardableResult open func getOnDeck(completion: (([N]) -> Void)? = nil) -> [String] {
        let local = Set(Library.shared.state.allProgress(currentType).keys).subtracting(Library.shared.state.watchedSet(currentType))
        // Without a completion there is nothing to wait for. (The group used
        // to be entered either way: with no Trakt account neither callback
        // ever ran, and each call leaked the group and its notify block.)
        guard let completion = completion else { return Array(local) }

        let group = DispatchGroup()
        
        var updatedWatched:  [N] = []
        var updatedProgress: [N] = []
        
        group.enter()
        getWatched() { updated in
            updatedWatched = updated
            group.leave()
        }
        
        group.enter()
        getProgress() { updated in
            updatedProgress = Array(updated.keys)
            group.leave()
        }
        
        group.notify(queue: .main) {
            completion(Array(Set(updatedProgress).subtracting(updatedWatched)))
        }
        
        return Array(local)
    }
}
