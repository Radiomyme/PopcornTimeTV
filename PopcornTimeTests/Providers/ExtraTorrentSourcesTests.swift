//
//  ExtraTorrentSourcesTests.swift
//  PopcornTimeTests
//
//  ExtraTorrentSources: index releases turned into Torrent rows (magnets, labels, quality
//  buckets, tags), the merge with the regular sources, episodes, cams, duplicates and
//  namesakes, on recorded apibay / Knaben answers. (Port of the torrent harness: 30 checks.)
//

import XCTest
import Foundation
@testable import PopcornKit

private let fixtures = Fixtures.url("Sources")
private func loadFixture(_ name: String) -> Data { try! Data(contentsOf: fixtures.appendingPathComponent(name)) }

final class ExtraTorrentSourcesTests: CheckedTestCase {

    func testExtraTorrentSources() {
        let interstellar = ReleaseMatch.MovieIdentity(titles: ["Interstellar"], years: [2014], imdbId: "tt0816692")
        let tpb = PirateBayClient.releases(fromJSON: loadFixture("tpb_q_interstellar_2014.json"))
        let knaben = KnabenClient.releases(fromJSON: loadFixture("kn_interstellar_2014.json")) ?? []
        let all = IndexedRelease.deduplicated(tpb + knaben)
        let torrents = ExtraTorrentSources.movieTorrents(from: all, movie: interstellar)
        check(torrents.count >= 30, "torrents \(torrents.count)")

        let yify = torrents.first { $0.url.contains("89599bf4dc369a3a8eca26411c5ccf922d78b486") }
        check(yify != nil, "YIFY torrent present")
        if let yify = yify {
            check(yify.url.hasPrefix("magnet:?xt=urn:btih:89599bf4dc369a3a8eca26411c5ccf922d78b486&dn=Interstellar"), "magnet \(yify.url.prefix(90))")
            check(yify.url.contains("&tr=udp%3A%2F%2Ftracker%2Eopentrackr%2Eorg"), "public trackers")
            check(yify.quality.hasSuffix(" — TPB") && yify.quality.hasPrefix("1080p"), "label \(yify.quality!)")
            check(yify.qualityValue == .hd1080, "bucket \(yify.qualityValue)")
            check(yify.seeds == 1090 && yify.health == .unknown, "seeds \(yify.seeds)")
            check(TorrentioClient.sizeInBytes(yify.size).map { abs($0 - 2426656522) < 20_000_000 } ?? false, "size round trip \(yify.size ?? "nil")")
        }
        let uhd = torrents.first { $0.quality.contains("Knaben · YTS") }
        check(uhd != nil, "a Knaben-only (YTS) release labelled 'Knaben · YTS': \(torrents.map { $0.quality! }.prefix(8))")
        let remux = torrents.first { $0.url.lowercased().contains("d8d05ebec7303f05a7243986e8c7d0e201b0ac0d") }
        check(remux.map { $0.qualityValue == .uhd2160 && $0.tags.contains(.dolbyVision) && $0.tags.contains(.atmos) } ?? false, "UHD remux tags \(remux?.quality ?? "nil")")

        // Merge: a YTS-like base (one 1080p) + the extra torrents.
        var base = torrents.filter { $0.url.contains("89599bf4") }
        base[0].quality = "1080p"
        let merged = TorrentioClient.merge(base, with: torrents)
        check(Set(merged.compactMap { TorrentioClient.infoHash(fromMagnet: $0.url) }).count == merged.count, "merge deduped by hash")
        check(merged.filter { $0.url.contains("89599bf4") }.count == 1 && merged.first { $0.url.contains("89599bf4") }?.quality == "1080p", "existing entry wins")
        check(merged.count > 1 && merged.count <= base.count + 4 * TorrentioClient.maxPerQuality + 4, "merge caps per quality: \(merged.count)")
        check(merged.allSatisfy { (TorrentioClient.sizeInBytes($0.size) ?? 0) <= TorrentioClient.maxSizeBytes }, "merge size cap")
        print("merged Interstellar:")
        for torrent in merged { print("   \(torrent.quality!)  seeds=\(torrent.seeds) size=\(torrent.size ?? "?")") }

        // Episodes.
        let mob = ReleaseMatch.ShowIdentity(titles: ["MobLand"], year: 2025, country: nil, isAmbiguous: false)
        let episodes = ReleaseMatch.episodeReleases(KnabenClient.releases(fromJSON: loadFixture("kn_mobland_s02e07.json")) ?? [], season: 2, episode: 7, of: mob)
            .map(ExtraTorrentSources.torrent(from:))
        check(episodes.count >= 12 && episodes.allSatisfy { $0.quality.contains(" — Knaben · ") }, "episode torrents \(episodes.count)")
        check(episodes.contains { $0.quality.hasSuffix("Knaben · Nyaa") }, "Nyaa short name")

        // Fix round: bare TS, extras only when new, seeds floor, same name + size.
        check(VideoTags.parse("IT 2017 TS x264").contains(.cam), "bare TS after the year is a cam")
        check(VideoTags.parse("Movie.2019.TS.XviD-GRP").contains(.cam), "TS before the codec")
        check(VideoTags.parse("Superman.2025.1080p.TS.READNFO.x264.AC3-AOC").contains(.cam), "TS after the resolution")
        check(!VideoTags.parse("Movie (2017).ts").contains(.cam) && !VideoTags.parse("Movie.2017.1080p.WEB.ts").contains(.cam), ".ts extension is no cam")
        check(!VideoTags.parse("Its.Always.Sunny.S01E01.1080p").contains(.cam), "no TS word, no cam")
        let legacyCopy = Torrent(health: .unknown, url: "magnet:?xt=urn:btih:89599bf4dc369a3a8eca26411c5ccf922d78b486", quality: "1080p — ThePirateBay", seeds: 300, peers: 1, size: "2 GB")
        let deadCopy = Torrent(health: .unknown, url: "magnet:?xt=urn:btih:d8d05ebec7303f05a7243986e8c7d0e201b0ac0d", quality: "2160p — X", seeds: 0, peers: 0, size: "9 GB")
        let novel = ExtraTorrentSources.novel(torrents, beside: [legacyCopy, deadCopy])
        check(!novel.contains { $0.url.contains("89599bf4") }, "a seeded legacy copy keeps its row")
        check(novel.contains { $0.url.lowercased().contains("d8d05ebe") }, "a dead legacy copy doesn't hide the extra")
        check(novel.count == torrents.count - 1, "only the duplicate dropped")
        check(torrents.allSatisfy { $0.seeds >= ExtraTorrentSources.minSeeders }, "seeds floor \(ExtraTorrentSources.minSeeders)")
        let twins = [IndexedRelease(name: "Movie 2020 576p SSN", infoHash: String(repeating: "1", count: 40), seeders: 40, peers: 0, bytes: 1_000_000, source: "TPB"),
                     IndexedRelease(name: "Movie.2020.576p.SSN", infoHash: String(repeating: "2", count: 40), seeders: 1, peers: 0, bytes: 1_000_000, source: "TPB"),
                     IndexedRelease(name: "Movie 2020 576p SSN", infoHash: String(repeating: "3", count: 40), seeders: 5, peers: 0, bytes: 2_000_000, source: "TPB"),
                     IndexedRelease(name: "Movie 2020 576p SSN", infoHash: String(repeating: "4", count: 40), seeders: 4, peers: 0, bytes: 1_000_000, source: "Knaben · 1337x")]
        check(ExtraTorrentSources.offerable(twins).map(\.infoHash) == [String(repeating: "1", count: 40), String(repeating: "3", count: 40)], "same name + size: best seeded only")
        check(ExtraTorrentSources.movieTerms("The Intouchables") == "intouchables" && ExtraTorrentSources.movieTerms("The Thing") == "thing" && ExtraTorrentSources.movieTerms("The") == "the", "query without a leading 'the'")
        check(ExtraTorrentSources.episodeTerms("Law & Order: Special Victims Unit") == ["law and order special victims unit", "law and order svu"], "SVU acronym query: \(ExtraTorrentSources.episodeTerms("Law & Order: Special Victims Unit"))")
        check(ExtraTorrentSources.episodeTerms("Andor") == ["andor"], "plain title, one query")
        let odysseyMetas: [[String: Any]] = [["id": "tt33764258", "name": "The Odyssey", "releaseInfo": "2026", "poster": "p"],
                                             ["id": "tt41605854", "name": "The Odyssey", "releaseInfo": "2026", "poster": "p"],
                                             ["id": "tt40188305", "name": "Odyssey", "releaseInfo": "2026", "poster": "p"],
                                             ["id": "tt0118414", "name": "The Odyssey", "releaseInfo": "1997", "poster": "p"],
                                             ["id": "tt99999999", "name": "The Odyssey", "releaseInfo": "2026"]]
        let odysseyIdentity = ReleaseMatch.MovieIdentity(titles: ["The Odyssey"], years: [2026], imdbId: "tt33764258")
        check(ExtraTorrentSources.namesakes(of: odysseyIdentity, among: odysseyMetas) == ["tt41605854", "tt40188305"], "namesakes: same title + year, complete, not itself: \(ExtraTorrentSources.namesakes(of: odysseyIdentity, among: odysseyMetas))")
    }
}
