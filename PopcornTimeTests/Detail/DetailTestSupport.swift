//
//  DetailTestSupport.swift
//  PopcornTimeTests
//
//  What the tests of a title's page share: a store whose sources are answered by hand, on a
//  clock moved by hand, and the movies, shows and torrents they answer with.
//

import Foundation
@testable import PopcornKit

func detailTorrent(_ hash: String, quality: String = "1080p", seeds: Int = 50) -> Torrent {
    Torrent(url: "magnet:?xt=urn:btih:\(hash)&dn=Some.Film.2024.\(quality)", quality: quality, seeds: seeds)
}

/// A movie as a grid has it (title, year, summary) — no torrents unless given.
func detailBaseMovie(_ id: String = "tt15239678", title: String = "Dune: Part Two", torrents: [Torrent] = []) -> Movie {
    var movie = Movie(cinemeta: ["id": id, "name": title, "releaseInfo": "2024", "imdbRating": "8.5",
                                 "description": "The grid's summary.", "genres": ["Action", "Adventure"],
                                 "poster": "https://images.metahub.space/poster/small/\(id)/img"])!
    movie.torrents = torrents
    return movie
}

/// The same movie as a source's record: another wording, and what a grid lacks.
func detailRecord(_ id: String = "tt15239678", title: String = "Dune: Part Two (2024)") -> Movie {
    return Movie(yts: ["imdb_code": id, "title": title, "year": 2023, "rating": 7.1, "runtime": 166,
                       "description_full": "The source's own, longer summary.", "mpa_rating": "PG-13",
                       "yt_trailer_code": "Way9Dexny3w", "genres": ["Sci-Fi"],
                       "cast": [["name": "Timothée Chalamet", "character_name": "Paul Atreides", "imdb_code": "3154303"]]])!
}

func detailShow(_ id: String = "tt0944947", title: String = "Game of Thrones", episodes: [(Int, Int)] = [],
                torrents: Bool = false) -> Show {
    var show = Show(tvmaze: ["id": 82, "name": title, "premiered": "2011-04-17", "summary": "<p>The record's summary.</p>",
                             "runtime": 60, "network": ["name": "HBO"], "genres": ["Drama"]], imdbId: id)!
    show.episodes = episodes.map { season, number in
        var episode = Episode(title: "Episode \(number)", id: "\(id)-s\(season)e\(number)", show: nil, episode: number, season: season)
        if torrents { episode.torrents = [detailTorrent("e\(season)x\(number)")] }
        return episode
    }
    return show
}

/// A movie's lists with these providers in.
func detailLists(yts: [Torrent]? = nil, torrentio: [Torrent]? = nil, t4p: [Torrent]? = nil, extra: [Torrent]? = nil,
                 failed: [MovieSources.Provider] = []) -> MovieSources {
    var lists = MovieSources()
    lists.missing = []
    if let yts = yts { lists.yts = yts; lists.ytsKnowsTitle = true } else { lists.missing.append(.yts) }
    if let torrentio = torrentio { lists.torrentio = torrentio } else { lists.missing.append(.torrentio) }
    if let t4p = t4p { lists.time4Popcorn = t4p } else { lists.missing.append(.time4Popcorn) }
    if let extra = extra { lists.extra = extra } else { lists.missing.append(.extra) }
    lists.failed = failed
    for provider in failed { lists.missing.removeAll { $0 == provider } }
    return lists
}

/// The sources of the store: each request recorded, answered by hand.
final class FakeDetailSources {
    private(set) var requests: [(request: DetailStore.Request, send: (DetailEvent) -> Void)] = []

    var fetch: DetailStore.Fetch {
        { [self] request, send in self.requests.append((request, send)) }
    }

    var ids: [String] { requests.map { $0.request.id } }

    /// Tells `event` to the latest request for `id` (the latest of all without one).
    func send(_ event: DetailEvent, to id: String? = nil) {
        (id.flatMap { id in requests.last { $0.request.id == id } } ?? requests.last)?.send(event)
    }
}

struct DetailHarness {
    let store: DetailStore
    let sources: FakeDetailSources
    let clock: ManualClock
    let lines: () -> [String]
    private let log: (String) -> Void

    init() {
        let sources = FakeDetailSources()
        let clock = ManualClock()
        var lines: [String] = []
        self.sources = sources
        self.clock = clock
        store = DetailStore(fetch: sources.fetch, now: clock.now, after: clock.after)
        self.lines = { lines }
        log = { lines.append($0) }
    }

    func session(_ media: Media) -> DetailSession {
        // The merge at once (the app does it off the main queue).
        return DetailSession(media: media, store: store, now: clock.now, after: clock.after,
                             merge: { work, done in done(work()) }, log: log)!
    }
}
