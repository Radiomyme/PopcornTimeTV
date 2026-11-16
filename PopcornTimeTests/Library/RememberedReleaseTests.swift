//
//  RememberedReleaseTests.swift
//  PopcornTimeTests
//
//  The release remembered with each Continue Watching entry (PopcornKit RememberedRelease,
//  key "rl"): what « Resume », the Home cards and the next episode replay without asking.
//  Codable both ways; an entry saved before 5.3.0 reads and writes back byte for byte; the
//  magnet stored short (tvOS keeps the whole preferences domain under 1 MB) but still the
//  same torrent; every save of a player stores it (PlaybackDetails reads the registry);
//  a finished episode's release stays with the show; forgetting one; the budget of 200
//  entries; « Resume » and the Home card's choice (UpNextResume). No UserDefaults, no
//  network, no real clock.
//

import XCTest
import Foundation
@testable import PopcornKit

private typealias F = LibraryFixtures

/// The longest magnet of Torrentio's recorded list (dozens of trackers).
private let torrentioMagnet: String = {
    let data = Fixtures.data("Torrentio/got_s01e01.json")
    let streams = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["streams"] as? [[String: Any]] ?? []
    return streams.compactMap(TorrentioClient.torrent(fromStream:)).map(\.url).max { $0.utf8.count < $1.utf8.count } ?? ""
}()

private let hashKey = "0123456789abcdef0123456789abcdef01234567"

private func episode(_ season: Int, _ number: Int, show: String = "tt0944947") -> Episode {
    var show = Show(title: "Game of Thrones", id: show)
    show.runtime = 55
    return Episode(title: "Episode \(number)", id: LibraryID.episodeID(showID: show.id, EpisodeNumber(season: season, episode: number)),
                   show: show, episode: number, season: season)
}

final class RememberedReleaseTests: CheckedTestCase {

    override func tearDown() {
        PlaybackReleaseRegistry.removeAll()
        super.tearDown()
    }

    private func library(_ storage: LibraryStorage = MemoryLibraryStorage(), clock: F.Clock) -> Library {
        Library(storage: storage, guideDirectory: nil, remote: .offline, center: NotificationCenter(), now: { clock.now })
    }

    private func makeRelease(_ link: String, quality: String = "1080p HEVC DD+ — ThePirateBay", fileName: String? = nil,
                         files: PackFiles? = nil, played: Int? = nil, at date: Date = F.date("2026-11-15T10:00:00Z")) -> RememberedRelease {
        let torrent = Torrent(url: link, quality: quality, seeds: 12, size: "1.2 GB", fileName: fileName)
        return RememberedRelease(torrent: torrent, files: files, playedIndex: played, at: date)
    }

    // MARK: Codable

    func testCodableBothWays() throws {
        let files = PackFiles(names: ["Show.S01/Show.S01E01.1080p.HEVC-PTT.mkv", "Show.S01/Show.S01E02.1080p.HEVC-PTT.mkv",
                                      "Show.S01/Show.S01E04.1080p.HEVC-PTT.mkv", "Show.S01/sample.mkv"], sizes: [3, 3, 3, 1])
        let original = makeRelease("magnet:?xt=urn:btih:\(hashKey)&dn=Show.S01.1080p.HEVC-PTT&tr=udp%3A%2F%2Ftracker.example%3A1337",
                               files: files, played: 1)
        eq(original.fileName, "Show.S01E02.1080p.HEVC-PTT.mkv", "the file played")
        eq(original.group, "PTT", "the group")
        eq(original.quality, "1080p HEVC DD+", "the quality, without its source")
        eq(original.provider, "ThePirateBay", "the source")
        check(original.isMultiFile, "a pack")
        eq(original.packEpisodes, "1:1-2,4", "its episodes, the sample left out")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RememberedRelease.self, from: data)
        eq(decoded, original, "round trip")
        let json = String(data: data, encoding: .utf8) ?? ""
        check(!json.contains("\"k\""), "the source key is not written twice", json)
        // The torrent it replays.
        let torrent = decoded.torrent
        eq(torrent.url, original.link, "the same link")
        eq(torrent.qualityLabel, "1080p HEVC DD+", "the quality label")
        eq(torrent.sourceLabel, "ThePirateBay", "the source label")
        eq(torrent.releaseFileName, "Show.S01E02.1080p.HEVC-PTT.mkv", "« Resume »: the same file")
        eq(decoded.packTorrent.releaseFileName, nil, "another episode of the pack: no file name")
        eq(decoded.packHolds(EpisodeNumber(season: 1, episode: 4)), true, "E04 is in the pack")
        eq(decoded.packHolds(EpisodeNumber(season: 1, episode: 3)), false, "E03 is not")
        eq(makeRelease("magnet:?xt=urn:btih:\(hashKey)&dn=x.mkv").packHolds(EpisodeNumber(season: 1, episode: 1)), nil, "not a pack: unknown")
        eq(RememberedRelease.decode(episodes: "1:1-3;2:5"), [F.number(1, 1), F.number(1, 2), F.number(1, 3), F.number(2, 5)], "decoded")
        eq(RememberedRelease.encode(episodes: [F.number(2, 5), F.number(1, 3), F.number(1, 1), F.number(1, 2)]), "1:1-3;2:5", "encoded")
    }

    func testAnOldEntryReadsAndWritesBackByteForByte() throws {
        let old = """
        [{"d":2700,"e":3,"et":"Breaker of Chains","f":true,"i":"tt0944947-s4e3","k":"episode","p":0.97,"ps":2619,"r":55,"s":4,"sh":"tt0944947","t":"Game of Thrones","u":1763200000},{"i":"tt0816692","k":"movie","p":0.4,"ps":4056,"t":"Interstellar","u":1763100000}]
        """
        let entries = try JSONDecoder().decode([ContinueWatchingEntry].self, from: Data(old.utf8))
        check(entries.allSatisfy { $0.release == nil }, "no release")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        eq(String(data: try encoder.encode(entries), encoding: .utf8), old, "written back byte for byte")
        // An unreadable release is no release: the entry stays.
        let broken = #"[{"i":"tt0816692","k":"movie","p":0.4,"rl":{"x":1},"u":1763100000}]"#
        let read = try JSONDecoder().decode([ContinueWatchingEntry].self, from: Data(broken.utf8))
        eq(read.count, 1, "the entry reads")
        eq(read.first?.release, nil, "without its release")
    }

    // MARK: The short magnet

    func testTheMagnetIsShortAndTheSameTorrent() {
        check(torrentioMagnet.utf8.count > 600, "a long recorded magnet", "\(torrentioMagnet.utf8.count) bytes")
        let short = RememberedRelease.shortenedLink(torrentioMagnet)
        check(short.utf8.count <= 400, "≤ 400 bytes", "\(short.utf8.count): \(short)")
        eq(MagnetLink.sourceKey(of: short), MagnetLink.sourceKey(of: torrentioMagnet), "the same info-hash")
        check(MagnetLink.rawParameters("tr", in: short).count <= 3, "3 trackers at most")
        check(MagnetLink.rawParameters("tr", in: short).count >= 1, "some kept")
        let fullName = MagnetLink.displayName(of: torrentioMagnet) ?? ""
        let kept = MagnetLink.displayName(of: short) ?? ""
        check(kept.count >= 40 && fullName.hasPrefix(kept), "its name's start", kept)
        eq(MagnetLink.displayName(of: RememberedRelease.shortenedLink("magnet:?xt=urn:btih:\(hashKey)&dn=Show.S01E01.1080p-GRP.mkv")),
           "Show.S01E01.1080p-GRP.mkv", "a short name, whole")
        // A long name is cut; so= is kept.
        let longName = String(repeating: "Very.Long.Release.Name.", count: 12) + "S01E01.1080p-GRP.mkv"
        let pack = "magnet:?xt=urn:btih:\(hashKey.uppercased())&dn=\(longName)&so=3&tr=udp%3A%2F%2Fa.example%3A1&tr=udp%3A%2F%2Fb.example%3A2"
            + "&tr=udp%3A%2F%2Fc.example%3A3&tr=udp%3A%2F%2Fd.example%3A4"
        let cut = RememberedRelease.shortenedLink(pack)
        check(cut.utf8.count <= 400, "≤ 400 bytes", "\(cut.utf8.count)")
        eq(MagnetLink.selectedFileIndex(of: cut), 3, "so= kept")
        eq(MagnetLink.sourceKey(of: cut), hashKey, "the hash, lower case")
        check(longName.hasPrefix(MagnetLink.displayName(of: cut) ?? "?"), "the name's start", MagnetLink.displayName(of: cut) ?? "nil")
        eq(MagnetLink.rawParameters("tr", in: cut).count, 3, "three trackers")
        // Spaces and accents survive.
        let spaced = RememberedRelease.shortenedLink("magnet:?xt=urn:btih:\(hashKey)&dn=Le%20Bureau%20des%20L%C3%A9gendes%20S01E01.mkv")
        eq(MagnetLink.displayName(of: spaced), "Le Bureau des Légendes S01E01.mkv", "decoded the same")
        // Anything else as it is.
        eq(RememberedRelease.shortenedLink("/tmp/bench/pack.torrent"), "/tmp/bench/pack.torrent", "a local .torrent")
        eq(RememberedRelease.shortenedLink("https://yts.example/torrent/download/ABC"), "https://yts.example/torrent/download/ABC", "a .torrent URL")
    }

    // MARK: Saves

    func testEverySaveRemembersTheReleasePlaying() {
        let clock = F.Clock("2026-11-15T10:00:00Z")
        let library = self.library(clock: clock)
        let e1 = episode(1, 1)
        let torrent = Torrent(url: torrentioMagnet, quality: "1080p HEVC — Torrentio", seeds: 30, size: "1.1 GB")
        PlaybackReleaseRegistry.note(torrent, for: e1.id, at: clock.now)
        let details = PlaybackDetails(media: e1, position: 600, duration: 3300)
        eq(details.release?.sourceKey, MagnetLink.sourceKey(of: torrentioMagnet), "the details carry the release noted")
        library.setProgress(0.18, id: e1.id, list: .episodes, details: details)
        eq(library.rememberedRelease(for: e1.id)?.sourceKey, MagnetLink.sourceKey(of: torrentioMagnet), "stored with the entry")
        eq(library.rememberedRelease(for: e1.id)?.link, RememberedRelease.shortenedLink(torrentioMagnet), "short")
        // A save without a release (another player's, before the stream was noted) keeps it.
        library.setProgress(0.3, id: e1.id, list: .episodes, details: PlaybackDetails(position: 1000, duration: 3300))
        eq(library.rememberedRelease(for: e1.id)?.sourceKey, MagnetLink.sourceKey(of: torrentioMagnet), "kept")
        eq(PlaybackDetails(media: episode(1, 2)).release, nil, "nothing noted for E02")
        // The file list the stream captured goes with it.
        PlaybackReleaseRegistry.noteFiles(PackFiles(names: ["P/S01E01.mkv", "P/S01E02.mkv"], sizes: [5, 5]), playedIndex: 0,
                                          forLink: torrentioMagnet)
        let pack = PlaybackDetails(media: e1).release
        check(pack?.isMultiFile == true && pack?.fileName == "S01E01.mkv" && pack?.packEpisodes == "1:1-2", "the pack's", "\(String(describing: pack))")
        PlaybackReleaseRegistry.forget(e1.id)
        eq(PlaybackDetails(media: e1).release, nil, "forgotten")
    }

    func testAFinishedEpisodesReleaseStaysWithTheShow() {
        let clock = F.Clock("2026-11-15T10:00:00Z")
        let library = self.library(clock: clock)
        let a = makeRelease("magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))&dn=Show.S01E01.1080p-AAA.mkv")
        let b = makeRelease("magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))&dn=Show.S01E02.1080p-BBB.mkv")
        let e1 = episode(1, 1, show: "tt0000042"), e2 = episode(1, 2, show: "tt0000042")
        library.setProgress(0.95, id: e1.id, list: .episodes, details: PlaybackDetails(media: e1).with(a))
        eq(library.rememberedRelease(ofShow: "tt0000042")?.group, "AAA", "E01 finished: its release")
        clock.advance(600)
        library.setProgress(0.3, id: e2.id, list: .episodes, details: PlaybackDetails(media: e2).with(b))
        eq(library.rememberedRelease(ofShow: "tt0000042")?.group, "BBB", "E02 more recent")
        eq(library.rememberedRelease(for: e1.id)?.group, "AAA", "E01 keeps its own")
        clock.advance(600)
        library.setProgress(0.97, id: e2.id, list: .episodes, details: PlaybackDetails(media: e2))
        eq(library.entry(e1.id), nil, "E02 finished: E01's entry goes (the show keeps its last one)")
        eq(library.rememberedRelease(ofShow: "tt0000042")?.group, "BBB", "the release stays with the entry left")
        eq(library.rememberedRelease(ofShow: "tt9999999"), nil, "another show: none")
        // Forgetting.
        check(library.forgetRelease(e2.id), "forgotten")
        eq(library.rememberedRelease(for: e2.id), nil, "gone")
        check(library.entry(e2.id) != nil, "the entry stays")
        check(!library.forgetRelease(e2.id), "nothing left to forget")
        library.setProgress(0.2, id: e1.id, list: .episodes, details: PlaybackDetails(media: e1).with(a))
        check(library.forgetRelease("tt0000042"), "by show")
        eq(library.rememberedRelease(ofShow: "tt0000042"), nil, "none left in the show")
        // A movie.
        library.setProgress(0.4, id: "tt0816692", list: .movies, details: PlaybackDetails(position: 3000, duration: 10000).with(a))
        eq(library.rememberedRelease(for: "tt0816692")?.group, "AAA", "a movie's")
    }

    // MARK: « Resume » and the Home card (D2, D4)

    func testResumeAndHomeCardChoices() {
        let clock = F.Clock("2026-11-15T10:00:00Z")
        let library = self.library(clock: clock)
        let files = PackFiles(names: ["S/Show.S01E01.1080p-PTT.mkv", "S/Show.S01E02.1080p-PTT.mkv", "S/Show.S01E03.1080p-PTT.mkv"])
        let pack = makeRelease("magnet:?xt=urn:btih:\(hashKey)&dn=Show.S01.1080p-PTT", files: files, played: 0, at: clock.now)
        let e1 = episode(1, 1, show: "tt0000043")
        library.setProgress(0.95, id: e1.id, list: .episodes, details: PlaybackDetails(media: e1).with(pack))
        clock.advance(3 * 3600)
        let resume = UpNextResume.choice(mediaID: e1.id, library: library, now: clock.now, capabilities: .everything)
        eq(resume?.rule, .sameRelease, "« Resume » of E01: its release")
        eq(resume?.torrent.releaseFileName, "Show.S01E01.1080p-PTT.mkv", "the same file")
        eq(resume?.logLine(mediaID: e1.id), "[UpNext] resume tt0000043-s1e1 rule=sameRelease release=1080p HEVC DD+ (cdef01234567) age 3 h", "its line")
        let next = UpNextResume.choice(mediaID: LibraryID.episodeID(showID: "tt0000043", F.number(1, 2)), library: library, now: clock.now,
                                       capabilities: .everything)
        eq(next?.rule, .samePack, "the Home card of E02: the same pack")
        eq(next?.torrent.url, pack.link, "that torrent")
        eq(next?.torrent.releaseFileName, nil, "without E01's file name")
        check(next?.replaysRemembered == true, "a remembered release: its patience, forgotten if it fails")
        eq(UpNextResume.choice(mediaID: LibraryID.episodeID(showID: "tt0000043", F.number(1, 4)), library: library, now: clock.now,
                               capabilities: .everything)?.rule, nil,
           "E04 is not in the pack: the usual flow")
        eq(UpNextResume.choice(mediaID: "tt0816692", library: library, now: clock.now)?.rule, nil, "nothing remembered: the usual flow")
        eq(UpNextResume.patience, 20, "D5: 20 s for a remembered release")
        eq(UpNextResume.choice(mediaID: LibraryID.episodeID(showID: "tt0000043", F.number(1, 2)), excluded: [hashKey], library: library,
                               now: clock.now, capabilities: .everything)?.rule, nil,
           "the pack did not answer this session: the usual flow")
    }

    func testNativeFirstAndContinuityForAnEpisodeNotStarted() {
        let clock = F.Clock("2026-11-15T10:00:00Z")
        let library = self.library(clock: clock)
        let dtsKey = String(repeating: "d", count: 40)
        let files = PackFiles(names: ["S/Show.S01E01.1080p.BluRay.DTS.x264-PTT.mkv", "S/Show.S01E02.1080p.BluRay.DTS.x264-PTT.mkv"])
        let dtsPack = makeRelease("magnet:?xt=urn:btih:\(dtsKey)&dn=Show.S01.1080p.BluRay.DTS.x264-PTT", quality: "1080p DTS — TPB",
                                  files: files, played: 0, at: clock.now)
        let e1 = episode(1, 1, show: "tt0000044")
        library.setProgress(0.95, id: e1.id, list: .episodes, details: PlaybackDetails(media: e1).with(dtsPack))
        let e2 = LibraryID.episodeID(showID: "tt0000044", F.number(1, 2))
        // A pack only VLC plays (DTS only): it waits for the episode's releases.
        eq(UpNextResume.choice(mediaID: e2, library: library, now: clock.now, capabilities: .everything)?.rule, nil,
           "DTS pack, releases not known yet: ask again once they are in")
        let eac3 = Torrent(url: "magnet:?xt=urn:btih:\(String(repeating: "e", count: 40))&dn=Show.S01E02.1080p.WEB-DL.DDP5.1.H.264-XYZ.mkv",
                           quality: "1080p DD+", seeds: 30, size: "1.1 GB")
        let native = UpNextResume.choice(mediaID: e2, candidates: [eac3], library: library, now: clock.now, capabilities: .everything)
        eq(native?.rule, .continuity, "a native release of E02 is listed: not the DTS pack")
        eq(native?.torrent.url, eac3.url, "the E-AC-3 release")
        eq(native?.planned?.rule, .sameClass, "in clear continuity: the same class")
        check(native?.replaysRemembered == false, "not a remembered release: no shorter patience, nothing to forget")
        let dtsOnly = Torrent(url: "magnet:?xt=urn:btih:\(String(repeating: "f", count: 40))&dn=Show.S01E02.1080p.BluRay.DTS.x264-QQQ.mkv",
                              quality: "1080p DTS", seeds: 30)
        eq(UpNextResume.choice(mediaID: e2, candidates: [dtsOnly], library: library, now: clock.now, capabilities: .everything)?.rule,
           .samePack, "no native release listed: the pack all the same")
        // Single-episode releases (D4): a release of the same group replays without asking; a balanced pick does not.
        let ntb = makeRelease("magnet:?xt=urn:btih:\(String(repeating: "1", count: 40))&dn=Other.S02E01.1080p.WEB.H264-NTb.mkv",
                              quality: "1080p — EZTV", at: clock.now)
        let f1 = episode(2, 1, show: "tt0000045")
        library.setProgress(0.97, id: f1.id, list: .episodes, details: PlaybackDetails(media: f1).with(ntb))
        let f3 = LibraryID.episodeID(showID: "tt0000045", F.number(2, 3))
        let ntb3 = Torrent(url: "magnet:?xt=urn:btih:\(String(repeating: "2", count: 40))&dn=Other.S02E03.1080p.WEB.H264-NTb.mkv",
                           quality: "1080p", seeds: 20)
        let uhd3 = Torrent(url: "magnet:?xt=urn:btih:\(String(repeating: "3", count: 40))&dn=Other.S02E03.2160p.WEB.H265-ZZZ.mkv",
                           quality: "2160p", seeds: 90)
        let group = UpNextResume.choice(mediaID: f3, candidates: [uhd3, ntb3], library: library, now: clock.now, capabilities: .everything)
        eq(group?.rule, .continuity, "E03 not started: NTb's E03")
        eq(group?.torrent.url, ntb3.url, "the same group")
        eq(group?.planned?.rule, .sameGroup, "rule sameGroup")
        eq(UpNextResume.choice(mediaID: f3, candidates: [uhd3], library: library, now: clock.now, capabilities: .everything)?.rule, nil,
           "only a 2160p: no clear continuity, the usual flow")
        eq(UpNextResume.choice(mediaID: f3, library: library, now: clock.now, capabilities: .everything)?.rule, nil,
           "releases not known: nothing yet")
    }

    func testAFailedPackIsForgottenWhereverTheShowRemembersIt() {
        let clock = F.Clock("2026-11-15T10:00:00Z")
        let library = self.library(clock: clock)
        let files = PackFiles(names: ["S/Show.S01E01.1080p-PTT.mkv", "S/Show.S01E02.1080p-PTT.mkv", "S/Show.S01E03.1080p-PTT.mkv"])
        let pack = makeRelease("magnet:?xt=urn:btih:\(hashKey)&dn=Show.S01.1080p-PTT", files: files, played: 0, at: clock.now)
        let other = makeRelease("magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))&dn=Show.S02E01.1080p-BBB.mkv")
        let e1 = episode(1, 1, show: "tt0000046"), s2 = episode(2, 1, show: "tt0000046")
        library.setProgress(0.3, id: s2.id, list: .episodes, details: PlaybackDetails(media: s2).with(other))
        clock.advance(60)
        library.setProgress(0.95, id: e1.id, list: .episodes, details: PlaybackDetails(media: e1).with(pack))
        let e3 = LibraryID.episodeID(showID: "tt0000046", F.number(1, 3))
        eq(UpNextResume.choice(mediaID: e3, library: library, now: clock.now, capabilities: .everything)?.rule, .samePack, "E03: the pack")
        // The pack replayed for E03 failed: E03 has no entry, the pack is E01's.
        check(library.forgetRelease(e3, sourceKey: hashKey), "forgotten through the episode replayed")
        eq(library.rememberedRelease(for: e1.id), nil, "E01's pack is gone")
        eq(library.rememberedRelease(for: s2.id)?.group, "BBB", "the other release of the show stays")
        eq(UpNextResume.choice(mediaID: e3, library: library, now: clock.now, capabilities: .everything)?.rule, nil,
           "E03's card no longer replays the dead pack")
        check(!library.forgetRelease(e3, sourceKey: hashKey), "nothing left to forget")
    }

    // MARK: Budget

    func testTwoHundredEntriesStayFarUnderTheBudget() throws {
        let clock = F.Clock("2026-11-15T10:00:00Z")
        let plain = MemoryLibraryStorage(), remembered = MemoryLibraryStorage()
        let without = library(plain, clock: clock), with = library(remembered, clock: clock)
        let longName = "Game.of.Thrones.S01E01.Winter.Is.Coming.2160p.UHD.BluRay.REMUX.HDR.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos-GROUPNAME.mkv"
        for index in 0..<200 {
            let id = "tt\(1_000_000 + index)"
            let link = torrentioMagnet.replacingOccurrences(of: MagnetLink.sourceKey(of: torrentioMagnet),
                                                            with: String(format: "%040d", index))
            let torrent = Torrent(url: link, quality: "2160p DV HDR HEVC TrueHD Atmos — Torrentio", seeds: 5, size: "31.07 GB",
                                  fileName: longName)
            let files = PackFiles(names: (1...10).map { "Pack/\(longName.replacingOccurrences(of: "E01", with: String(format: "E%02d", $0)))" })
            let details = PlaybackDetails(title: "A Title Long Enough To Be Realistic", position: 1200, duration: 3600)
            without.setProgress(0.33, id: id, list: .movies, details: details)
            with.setProgress(0.33, id: id, list: .movies,
                             details: details.with(RememberedRelease(torrent: torrent, files: files, playedIndex: 0, at: clock.now)))
        }
        let before = (plain.object(forKey: "continueWatchingEntries") as? Data)?.count ?? 0
        let after = (remembered.object(forKey: "continueWatchingEntries") as? Data)?.count ?? 0
        check(before > 10_000, "200 entries written", "\(before) bytes")
        check(after - before < 100_000, "the releases add less than 100 KB", "\(after - before) bytes")
        check(after < 200_000, "the whole blob under 200 KB (the domain's limit is 1 MB)", "\(after) bytes")
        print("RememberedRelease budget: 200 entries \(before) B, with releases \(after) B (+\(after - before) B)")
    }
}

private extension PlaybackDetails {
    func with(_ release: RememberedRelease) -> PlaybackDetails {
        var copy = self
        copy.release = release
        return copy
    }
}
