import Foundation

/// A page opens on what the caller already has — a grid's item, a Home
/// card, a link's id — and its record arrives a moment later. What the page
/// already shows must not change under the user's eyes (another wording of
/// the summary, another year): the record only gives what the caller's
/// object lacks. Its people, its trailer, its runtime, a show's network and
/// episodes come that way; the title, the summary, the year, the rating, the
/// genres and the artwork stay the caller's when it had them (a summary its
/// source cut short gives way to a whole one: `DetailMerge.summary`).
///
/// The record's torrents are the page's (a caller's are a list's: YTS's own
/// only).
public extension Movie {

    /// `self` (what the page was opened with) completed by `record`.
    func completed(by record: Movie) -> Movie {
        return Movie(shown: self, completedBy: record)
    }

    /// Whether the title is one to show: not the placeholder of a movie made
    /// from an id alone (a link, a Continue Watching entry).
    var hasTitleToShow: Bool { DetailMerge.isTitle(title, id: id) }

    /// Whether the summary is one a source wrote, not the models' "No
    /// summary available.": a page that has not loaded yet shows none
    /// rather than that.
    var hasSummaryToShow: Bool { DetailMerge.isSummary(summary) }

    private init(shown: Movie, completedBy record: Movie) {
        id = shown.id
        tmdbId = shown.tmdbId ?? record.tmdbId
        let keepsTitle = shown.hasTitleToShow
        title = keepsTitle ? shown.title : record.title
        slug = keepsTitle ? shown.slug : record.slug
        year = DetailMerge.isYear(shown.year) ? shown.year : record.year
        rating = shown.rating > 0 ? shown.rating : record.rating
        runtime = shown.runtime > 0 ? shown.runtime : record.runtime
        summary = DetailMerge.summary(shown: shown.summary, record: record.summary)
        trailer = shown.trailer ?? record.trailer
        certification = DetailMerge.isCertification(shown.certification) ? shown.certification : record.certification
        largeBackgroundImage = shown.largeBackgroundImage ?? record.largeBackgroundImage
        largeCoverImage = shown.largeCoverImage ?? record.largeCoverImage
        crew = shown.crew.isEmpty ? record.crew : shown.crew
        actors = shown.actors.isEmpty ? record.actors : shown.actors
        related = shown.related.isEmpty ? record.related : shown.related
        torrents = record.torrents
        subtitles = shown.subtitles.isEmpty ? record.subtitles : shown.subtitles
        genres = shown.genres.isEmpty ? record.genres : shown.genres
        releaseDate = shown.releaseDate ?? record.releaseDate
        logoImage = shown.logoImage ?? record.logoImage
    }
}

public extension Show {

    /// `self` (what the page was opened with) completed by `record`: the
    /// record's episodes, network, runtime and status; the rest only where
    /// `self` has none.
    func completed(by record: Show) -> Show {
        return Show(shown: self, completedBy: record)
    }

    /// Whether the title is one to show (see `Movie.hasTitleToShow`).
    var hasTitleToShow: Bool { DetailMerge.isTitle(title, id: id) }

    /// Whether the summary is one a source wrote (see `Movie.hasSummaryToShow`).
    var hasSummaryToShow: Bool { DetailMerge.isSummary(summary) }

    private init(shown: Show, completedBy record: Show) {
        id = shown.id
        tmdbId = shown.tmdbId ?? record.tmdbId
        tvdbId = (Int(shown.tvdbId) ?? 0) > 0 ? shown.tvdbId : record.tvdbId
        let keepsTitle = shown.hasTitleToShow
        title = keepsTitle ? shown.title : record.title
        slug = keepsTitle ? shown.slug : record.slug
        year = DetailMerge.isYear(shown.year) ? shown.year : record.year
        rating = shown.rating > 0 ? shown.rating : record.rating
        summary = DetailMerge.summary(shown: shown.summary, record: record.summary)
        network = shown.network ?? record.network
        airDay = shown.airDay ?? record.airDay
        airTime = shown.airTime ?? record.airTime
        runtime = (shown.runtime ?? 0) > 0 ? shown.runtime : record.runtime
        status = shown.status ?? record.status
        largeBackgroundImage = shown.largeBackgroundImage ?? record.largeBackgroundImage
        largeCoverImage = shown.largeCoverImage ?? record.largeCoverImage
        crew = shown.crew.isEmpty ? record.crew : shown.crew
        actors = shown.actors.isEmpty ? record.actors : shown.actors
        related = shown.related.isEmpty ? record.related : shown.related
        episodes = record.episodes
        genres = shown.genres.isEmpty ? record.genres : shown.genres
        releaseDate = shown.releaseDate ?? record.releaseDate
        logoImage = shown.logoImage ?? record.logoImage
    }
}

enum DetailMerge {

    /// A real title: not empty, not the models' "Unknown" default, not the
    /// id itself (the DEBUG hooks open a title by its id alone).
    static func isTitle(_ title: String, id: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != id && trimmed != "Unknown".localized && trimmed != "Unknown"
    }

    /// "2024", not "" nor the "0" of a source without a year.
    static func isYear(_ year: String) -> Bool {
        return (Int(year.prefix(4)) ?? 0) > 0
    }

    /// A summary a source wrote, not the models' "No summary available.".
    static func isSummary(_ summary: String) -> Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "No summary available.".localized && trimmed != "No summary available."
    }

    /// A summary its source cut short: Cinemeta's lists end theirs after
    /// some 230 characters ("…to prevent a terrible fu...").
    static func isCut(_ summary: String) -> Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("...") || trimmed.hasSuffix("…")
    }

    /// The summary a page keeps: the one it shows — unless it has none, or
    /// shows one its source cut short while the record has it whole (the
    /// text then only grows at its end, where it was cut).
    static func summary(shown: String, record: String) -> String {
        guard isSummary(record) else { return shown }
        guard isSummary(shown) else { return record }
        return isCut(shown) && !isCut(record) ? record : shown
    }

    /// "PG-13", not the models' "Unrated" default.
    static func isCertification(_ certification: String) -> Bool {
        let trimmed = certification.trimmingCharacters(in: .whitespaces).lowercased()
        return !["", "unrated", "unknown", "n/a", "not rated"].contains(trimmed)
    }
}
