import Foundation

/// What a poster of a grid (Movies, Shows, Watchlist, Search) says about its
/// title: the line under the focused poster (title · year · rating ·
/// runtime or seasons) and the small marks on the artwork (4K, New, New
/// Episode, watched, progress).
///
/// Built from what the list already carries and from the library's memory:
/// never a request. A plain value with the clock injected, so its rules are
/// unit-tested (`PosterCardTests`); a grid only draws it.
public struct PosterCard: Equatable, Sendable {

    public var title: String
    public var year: Int?
    /// 0…10 with one decimal (the lists' ratings are IMDb's); nil: not rated.
    public var rating: Double?
    /// A movie's length, an episode's for a show; nil: unknown.
    public var runtimeMinutes: Int?
    /// A show's seasons aired so far, when the list knows.
    public var seasons: Int?
    /// The marks on the artwork, in display order: 4K, then New or New Episode.
    public var badges: [HomeBadge]
    public var isWatched: Bool
    /// 0…1 of a started title that is not watched; nil otherwise.
    public var progress: Double?
    public var isInWatchlist: Bool

    public init(title: String, year: Int? = nil, rating: Double? = nil, runtimeMinutes: Int? = nil, seasons: Int? = nil,
                badges: [HomeBadge] = [], isWatched: Bool = false, progress: Double? = nil, isInWatchlist: Bool = false) {
        self.title = title
        self.year = year
        self.rating = rating
        self.runtimeMinutes = runtimeMinutes
        self.seasons = seasons
        self.badges = badges
        self.isWatched = isWatched
        self.progress = progress
        self.isInWatchlist = isInWatchlist
    }

    // MARK: - Rules

    public struct Rules: Sendable {
        /// "New": added (a movie) or premiered (a show) within this.
        public var newAge: TimeInterval = 14 * 86_400
        /// "New Episode": the show's latest episode aired within this.
        public var newEpisodeAge: TimeInterval = 7 * 86_400
        /// A movie just added is "New" only when it is of this year or of
        /// this many years before: the catalog adds releases of old movies
        /// every day (a 1975 title uploaded yesterday is not a new movie).
        public var newMovieYears = 1
        /// Below this a title was only opened: no progress bar. The
        /// library's own "started" threshold.
        public var startedProgress = 0.02

        public init() {}

        public static let standard = Rules()
    }

    /// What the library knows of a title, read by the caller
    /// (`PosterLibrary`) so that the card stays a pure value.
    public struct WatchState: Equatable, Sendable {
        public var isWatched: Bool
        /// 0…1: the movie's position, or the position in the episode of a
        /// show the user is in the middle of.
        public var progress: Double
        public var isInWatchlist: Bool
        /// When the latest episode the library lists as new for a followed
        /// show aired.
        public var newEpisodeDate: Date?

        public init(isWatched: Bool = false, progress: Double = 0, isInWatchlist: Bool = false, newEpisodeDate: Date? = nil) {
            self.isWatched = isWatched
            self.progress = progress
            self.isInWatchlist = isInWatchlist
            self.newEpisodeDate = newEpisodeDate
        }
    }

    // MARK: - From the models

    public init(movie: Movie, watch: WatchState = WatchState(), now: Date, rules: Rules = .standard) {
        let year = PosterCard.year(movie.year)
        var badges: [HomeBadge] = []
        if movie.hasUHDRelease { badges.append(.uhd) }
        let recentMovie = year.map { $0 >= CatalogDates.year(of: now) - rules.newMovieYears } ?? false
        if (recentMovie && PosterCard.isWithin(movie.dateAdded, rules.newAge, of: now))
            || PosterCard.isWithin(movie.releaseDate, rules.newAge, of: now) {
            badges.append(.new)
        }
        self.init(title: movie.title, year: year, rating: PosterCard.rating(movie.rating),
                  runtimeMinutes: movie.runtime > 0 ? movie.runtime : nil,
                  badges: HomeBadge.ordered(badges), isWatched: watch.isWatched,
                  progress: PosterCard.progress(watch, rules: rules), isInWatchlist: watch.isInWatchlist)
    }

    public init(show: Show, watch: WatchState = WatchState(), now: Date, rules: Rules = .standard) {
        var badges: [HomeBadge] = []
        // A show that just premiered is new as a whole; later, its episodes are.
        if PosterCard.isWithin(show.releaseDate, rules.newAge, of: now) {
            badges.append(.new)
        } else if PosterCard.isWithin(show.latestEpisodeDate, rules.newEpisodeAge, of: now)
                    || PosterCard.isWithin(watch.newEpisodeDate, rules.newEpisodeAge, of: now) {
            badges.append(.newEpisode)
        }
        // What the list kept, else the latest season of the episodes the
        // show came with: a show listed with this week's releases only
        // (season 5) is in its fifth season, it does not have "1 season".
        // Specials and the seasons soaps number by year are not seasons.
        let seasons = show.seasonCount ?? show.seasonNumbers.filter { $0 > 0 && $0 < 1900 }.max()
        self.init(title: show.title, year: PosterCard.year(show.year), rating: PosterCard.rating(show.rating),
                  runtimeMinutes: show.runtime.flatMap { $0 > 0 ? $0 : nil },
                  seasons: seasons.flatMap { $0 > 0 ? $0 : nil },
                  badges: HomeBadge.ordered(badges), isWatched: false,
                  progress: PosterCard.progress(watch, rules: rules), isInWatchlist: watch.isInWatchlist)
    }

    // MARK: - Pieces

    /// "2026" → 2026; "", "0" and anything that is not a year → nil.
    static func year(_ text: String) -> Int? {
        guard let year = Int(text.prefix(4)), (1880...2200).contains(year) else { return nil }
        return year
    }

    /// The models' 0…100 → 0…10 with one decimal; 0 is "not rated".
    static func rating(_ percentage: Float) -> Double? {
        guard percentage > 0 else { return nil }
        return min(10, (Double(percentage)).rounded() / 10)
    }

    /// `date` is in the last `age` seconds (never in the future: a release
    /// date announced is not a release).
    static func isWithin(_ date: Date?, _ age: TimeInterval, of now: Date) -> Bool {
        guard let date = date else { return false }
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed <= age
    }

    static func progress(_ watch: WatchState, rules: Rules) -> Double? {
        guard !watch.isWatched, watch.progress >= rules.startedProgress, watch.progress < 1 else { return nil }
        return watch.progress
    }
}

// MARK: - The library's side

/// The library's answers for the posters of a grid, from its memory.
/// Movies are looked up one by one (dictionary reads); what the shows need
/// (the episode in progress, the new episodes of the followed ones) is
/// gathered once and kept until the library changes (`invalidate`).
public final class PosterLibrary {

    private let library: Library
    /// What the Home (and the screens before) said of the titles.
    private let facts: HomeTitleFacts
    private var showProgress: [String: Double]?
    private var newEpisodes: [String: Date]?

    public init(library: Library = .shared, facts: HomeTitleFacts = .shared) {
        self.library = library
        self.facts = facts
    }

    /// The library changed: the shows' answers are gathered again.
    public func invalidate() {
        showProgress = nil
        newEpisodes = nil
    }

    public func watchState(ofMovie id: String) -> PosterCard.WatchState {
        return PosterCard.WatchState(isWatched: library.isWatched(id), progress: Double(library.progress(id)),
                                     isInWatchlist: library.isInWatchlist(id))
    }

    public func watchState(ofShow id: String) -> PosterCard.WatchState {
        if showProgress == nil {
            var progress: [String: Double] = [:]
            // The episode the user stopped in the middle of; a next episode
            // not started has nothing to show a bar for.
            for item in library.continueWatching(limit: 200, kinds: [.show]) where item.reason == .resume {
                progress[item.imdbID] = Double(item.progress)
            }
            showProgress = progress
        }
        if newEpisodes == nil {
            var aired: [String: Date] = [:]
            for show in library.newEpisodes() {
                if let date = show.latestAiredAt { aired[show.showID] = date }
            }
            newEpisodes = aired
        }
        return PosterCard.WatchState(isWatched: false, progress: showProgress?[id] ?? 0,
                                     isInWatchlist: library.isInWatchlist(id), newEpisodeDate: newEpisodes?[id])
    }

    /// The card of a movie or a show of a grid; nil for anything else.
    /// Told as the Home tells the title (`HomeTitleFacts`): the same
    /// rating, formats and title on the Home, in a grid and in Search.
    public func card(for media: Media, now: Date = Date(), rules: PosterCard.Rules = .standard) -> PosterCard? {
        if let movie = media as? Movie {
            return PosterCard(movie: movie, watch: watchState(ofMovie: movie.id), now: now, rules: rules).told(by: facts, imdbId: movie.id)
        }
        if let show = media as? Show {
            return PosterCard(show: show, watch: watchState(ofShow: show.id), now: now, rules: rules).told(by: facts, imdbId: show.id)
        }
        return nil
    }
}

extension PosterCard {
    /// This card as `facts` already tell its title (`HomeTitleFacts.harmonize`).
    func told(by facts: HomeTitleFacts, imdbId: String) -> PosterCard {
        let told = facts.harmonized(HomeTitleFacts.Facts(title: title, year: year, rating: rating, badges: badges), of: imdbId)
        var card = self
        card.title = told.title
        card.year = told.year
        card.rating = told.rating
        card.badges = told.badges
        return card
    }
}
