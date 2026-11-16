//
//  TopShelfTestSupport.swift
//  PopcornTimeTests
//
//  What the Top Shelf tests share: the Home a light refresh leaves (the five lists the
//  extension asks, from Fixtures/Home), and the app's French strings read in the source tree
//  — the extension ships the app's Localizable.strings.
//

import Foundation
import XCTest
@testable import PopcornKit

enum TopShelfFixture {

    /// The lists of a light refresh at `HomeFixture.now`.
    static func lists() -> [String: HomeSourceList] {
        let year = CatalogDates.year(of: HomeFixture.now)
        let lists = [
            HomeFixture.list(.movieTop, "cm_movie_top.json"), HomeFixture.list(.seriesTop, "cm_series_top.json"),
            HomeFixture.list(.ytsNew(year), "yts_new_2026.json"), HomeFixture.list(.yts4K, "yts_4k.json"),
            HomeFixture.list(.topUHD, "tpb_211.json"),
        ]
        return Dictionary(uniqueKeysWithValues: lists.map { ($0.key, $0) })
    }

    /// The page those lists make, as the extension's hub builds it (a light plan, a hero of ten).
    static func snapshot(_ lists: [String: HomeSourceList] = TopShelfFixture.lists()) -> HomeSnapshot {
        var rules = HomeBuilder.Rules()
        rules.light = true
        rules.heroLimit = 10
        return HomeSnapshot(shelves: HomeBuilder.shelves(HomeFixture.inputs(lists), rules: rules))
    }

    /// A page made by hand: shelf id → its cards.
    static func snapshot(_ shelves: KeyValuePairs<String, [HomeItem]>) -> HomeSnapshot {
        return HomeSnapshot(shelves: shelves.map { HomeShelf(id: $0.key, style: HomeBuilder.style(of: $0.key), items: $0.value) })
    }

    /// The app's strings of a language ("fr"), from PopcornTime/<language>.lproj.
    static func strings(_ language: String, file: StaticString = #filePath, line: Int = #line) -> [String: String] {
        let folder = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PopcornTime/\(language).lproj/Localizable.strings")
        let strings = NSDictionary(contentsOf: folder) as? [String: String]
        check(strings != nil, "\(language): the strings file reads", file: file, line: line)
        return strings ?? [:]
    }

    /// The shelf in French, as a French Apple TV shows it.
    static let french: TopShelfModel.Texts = {
        let strings = TopShelfFixture.strings("fr")
        return TopShelfModel.Texts(localize: { strings[$0] ?? $0 }, locale: Locale(identifier: "fr_FR"))
    }()

    /// The keys themselves (English), en_US numbers.
    static let english = TopShelfModel.Texts(localize: { $0 }, locale: Locale(identifier: "en_US"))

    /// Where a hand-made card's backdrop is.
    enum Backdrop {
        /// metahub: a real backdrop.
        case real
        /// YTS's blurred "background", through the image proxy.
        case yts
        case none
    }

    /// A card made by hand: poster on metahub, backdrop where told.
    static func item(_ imdbId: String, _ title: String, kind: HomeItem.Kind = .movie, backdrop: Backdrop = .real, poster: Bool = true,
                     badges: [HomeBadge] = [], episode: HomeEpisode? = nil) -> HomeItem {
        let backdropURL: URL?
        switch backdrop {
        case .real: backdropURL = URL(string: "https://images.metahub.space/background/large/\(imdbId)/img")
        case .yts: backdropURL = URL(string: "https://images.weserv.nl/?url=https%3A//yts.gg/assets/images/movies/\(imdbId)/background.jpg")
        case .none: backdropURL = nil
        }
        return HomeItem(imdbId: imdbId, kind: kind, title: title, year: 2026, rating: 7.26, genres: ["Sci-Fi", "Drama"],
                        summary: "A summary.", runtimeMinutes: 101,
                        posterURL: poster ? URL(string: "https://images.metahub.space/poster/medium/\(imdbId)/img") : nil,
                        backdropURL: backdropURL, badges: badges, episode: episode)
    }
}
