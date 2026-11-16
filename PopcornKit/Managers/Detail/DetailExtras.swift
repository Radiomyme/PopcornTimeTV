import Foundation

/// What a title's page shows under its first screen: related titles, cast
/// and crew. They come from the keyless sources (`OpenMetadata`: YTS,
/// Cinemeta, TVMaze). Trakt, which refuses the app's key, is only asked
/// when a Trakt account is connected — `TraktManager` then falls back to
/// the same sources when it fails. (Every launch's first page used to send
/// Trakt two requests that could only be refused, and wait for both.)
public enum DetailExtras {

    /// Titles to suggest next to `media`, on the main queue.
    public static func related<T: Media>(_ media: T, completion: @escaping ([T]) -> Void) {
        guard TraktManager.shared.isSignedIn(), !TraktManager.anonymousAccessRefused else {
            return OpenMetadata.related(media) { related in completion(related.compactMap { $0 as? T }) }
        }
        TraktManager.shared.getRelated(media) { related, _ in completion(related) }
    }

    /// Cast and crew of a movie (`.movies`) or a show (`.shows`).
    public static func people(forMediaOfType type: Trakt.MediaType, id: String,
                              completion: @escaping ([Actor], [Crew]) -> Void) {
        guard TraktManager.shared.isSignedIn(), !TraktManager.anonymousAccessRefused else {
            return OpenMetadata.people(forMediaOfType: type, id: id, completion: completion)
        }
        TraktManager.shared.getPeople(forMediaOfType: type, id: id) { actors, crew, _ in completion(actors, crew) }
    }
}
