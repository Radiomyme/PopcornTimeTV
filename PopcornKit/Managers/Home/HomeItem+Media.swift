import Foundation

/// From a card to the objects the rest of the app works with: a detail
/// page opens a `Movie` / `Show` (and loads the full record by its id).
public extension HomeItem {

    /// The card as a Cinemeta-style meta: the form `Movie(cinemeta:)` and
    /// `Show(cinemeta:)` read.
    private var meta: [String: Any] {
        var meta: [String: Any] = ["id": imdbId, "name": title, "genres": genres]
        if let year = year { meta["releaseInfo"] = String(year) }
        if let rating = rating { meta["imdbRating"] = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rating) }
        if let runtime = runtimeMinutes { meta["runtime"] = "\(runtime) min" }
        if let summary = summary { meta["description"] = summary }
        if let poster = posterURL { meta["poster"] = poster.absoluteString }
        if let backdrop = backdropURL { meta["background"] = backdrop.absoluteString }
        return meta
    }

    /// The movie of a movie card (title, year, rating, artwork, trailer; no
    /// torrents: the detail page loads them), nil for a show's card.
    var movie: Movie? {
        guard kind == .movie, var movie = Movie(cinemeta: meta) else { return nil }
        if let code = trailerCode { movie.trailer = "https://www.youtube.com/watch?v=\(code)" }
        return movie
    }

    /// The show of a show or episode card (no episodes: the detail page
    /// loads them), nil for a movie's card.
    var show: Show? {
        guard kind == .show else { return nil }
        return Show(cinemeta: meta)
    }

    /// `movie` or `show`.
    var media: Media? {
        return kind == .movie ? movie : show
    }
}
