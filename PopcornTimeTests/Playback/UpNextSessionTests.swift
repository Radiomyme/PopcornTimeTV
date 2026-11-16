//
//  UpNextSessionTests.swift
//  PopcornTimeTests
//
//  The app's half of episode chaining (UpNextSession): what a player calls (tick, itemEnded,
//  playerClosed, the card's buttons) and what its platform implements (Host: startNext,
//  fallBack, chooseVersion, closePlayer), with a fake host, a hand-moved clock and sources
//  answered by hand. The new route never strands the user: no plan, a refused start, « Always
//  Ask » without a clear continuity all fall back to today's flow (playNext → chooseQuality).
//

import XCTest
import Foundation
import PopcornKit

@MainActor
final class UpNextSessionTests: CheckedTestCase {

    private final class Recorder {
        var started: [UpNextPlan] = []
        var fellBack: [String] = []
        var chooser: [UpNextPlan] = []
        var closed = 0
        var refuseStart = false
        var lines: [String] = []
    }

    private var time: TimeInterval = 0
    private var timers: [@MainActor () -> Void] = []
    private var pendingSources: [(EpisodeSourceResolver.Sources) -> Void] = []

    private func makeRelease(_ file: String, seeds: Int = 10, hash: Character) -> Torrent {
        let dn = file.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? file
        return Torrent(url: "magnet:?xt=urn:btih:\(String(repeating: hash, count: 40))&dn=\(dn)", quality: file, seeds: seeds)
    }

    /// A show `id` of three episodes; the playing one is E01.
    private func makeShow(_ id: String, episodes: Int = 3) -> (Episode, Show) {
        var show = Show(title: "Bench Show", id: id)
        show.episodes = (1...episodes).map { number in
            Episode(title: "Episode \(number)", id: LibraryID.episodeID(showID: id, EpisodeNumber(season: 1, episode: number)),
                    episode: number, season: 1, firstAirDate: Date(timeIntervalSince1970: 1_600_000_000))
        }
        var first = show.episodes[0]
        first.show = show
        return (first, show)
    }

    /// `cardLead`: the setting « Next Episode Card »; these tests were written with the card 30 s
    /// before the end (2:30 of a 3 min file), the default (60 s) has its own test.
    private func begin(_ episode: Episode, playing: Torrent?, recorder: Recorder, files: PackFiles? = nil, autoAdvance: Bool = true,
                       alwaysAsks: Bool = false, cardLead: TimeInterval = 30) -> UpNextSession? {
        var environment = UpNextSession.Environment()
        environment.tuning.cardLead = cardLead
        environment.now = { [unowned self] in self.time }
        environment.every = { [unowned self] _, block in self.timers.append(block); return {} }
        environment.resolveSources = { [unowned self] _, completion in self.pendingSources.append(completion) }
        environment.prefetchSubtitles = { _ in }
        environment.knownSubtitles = { _ in nil }
        environment.packFiles = { _ in files }
        environment.autoAdvance = { autoAdvance }
        environment.qualityAlwaysAsks = { alwaysAsks }
        environment.capabilities = { .everything }
        environment.log = { recorder.lines.append($0) }
        let host = UpNextSession.Host(startNext: { plan in recorder.started.append(plan); return !recorder.refuseStart },
                                      fallBack: { recorder.fellBack.append($0.id) },
                                      chooseVersion: { recorder.chooser.append($0) },
                                      closePlayer: { recorder.closed += 1 })
        return UpNextSession.begin(episode: episode, playing: playing, host: host, environment: environment)
    }

    /// Plays a 3 min file from `from` to `to`, one tick a second (the clock follows).
    private func play(_ session: UpNextSession?, from: Int, to: Int, duration: Double? = 180) {
        for second in from...to {
            time = Double(second)
            session?.tick(position: Double(second), duration: duration, isPlaying: true)
            timers.forEach { $0() }
        }
    }

    private func answer(_ torrents: [Torrent]) {
        var sources = EpisodeSourceResolver.Sources()
        sources.torrentio = torrents
        let waiting = pendingSources
        pendingSources = []
        waiting.forEach { $0(sources) }
    }

    func testNoSessionWithoutANextEpisode() {
        let recorder = Recorder()
        let (e1, show) = makeShow("tt0000101", episodes: 1)
        check(begin(e1, playing: nil, recorder: recorder) == nil, "the last episode: no session")
        var orphan = e1
        orphan.show = nil
        check(begin(orphan, playing: nil, recorder: recorder) == nil, "no show: no session")
        check(begin(Episode(title: "x", show: show), playing: nil, recorder: recorder) == nil, "no numbers: no session")
        check(recorder.lines.contains { $0.contains("no next episode to offer") }, "said", "\(recorder.lines)")
    }

    func testSamePackPlansAtOnceAndStartsAtTheEnd() {
        let recorder = Recorder()
        let (e1, _) = makeShow("tt0000102")
        let pack = makeRelease("Bench.Show.S01.1080p.HEVC-PTT", hash: "a")
        let files = PackFiles(names: ["P/Bench.Show.S01E01.1080p.HEVC-PTT.mkv", "P/Bench.Show.S01E02.1080p.HEVC-PTT.mkv"], sizes: [5, 5])
        let session = begin(e1, playing: pack, recorder: recorder, files: files)
        check(session != nil && UpNextSession.current === session, "current")
        eq(session?.plan?.rule, .samePack, "planned at once")
        eq(session?.next.episode, 2, "E02")
        play(session, from: 0, to: 149)
        eq(session?.card, nil, "no card before 2:30")
        play(session, from: 150, to: 150)
        eq(session?.card?.kind, .countdown, "the card at 2:30")
        eq(session?.card?.secondsLeft, 30, "30 s")
        check(session?.card?.versionLine != nil, "a version line")
        answer([makeRelease("Bench.Show.S01E02.1080p.WEB.H264-ABC.mkv", hash: "b")])
        eq(session?.plan?.rule, .samePack, "the sources do not replace the pack")
        eq(session?.plan?.sources.count, 1, "they are its other releases")
        play(session, from: 151, to: 180)
        eq(recorder.started.count, 1, "started once")
        eq(recorder.started.first?.torrent?.url, pack.url, "the pack")
        eq(recorder.started.first?.episode.id, "tt0000102-s1e2", "E02")
        check(recorder.started.first?.episode.show?.id == "tt0000102", "with its show")
        eq(recorder.fellBack, [], "no fallback")
        check(UpNextSession.current == nil, "the session ended")
        check(session?.itemEnded() == false, "after the start, the player's end is its own")
        check(recorder.lines.contains { $0.hasPrefix("[UpNext] plan S01E02 rule=samePack") }, "the plan line", "\(recorder.lines)")
        check(recorder.lines.contains { $0.hasPrefix("[UpNext] start S01E02 (deadline) rule=samePack") }, "the start line", "\(recorder.lines)")
    }

    func testAPackOnlyVLCPlaysGivesWayToANativeRelease() {
        // A DTS-only pack (VLC) whose file list holds E02: planned at once, but a native E02 listed wins.
        let recorder = Recorder()
        let (e1, _) = makeShow("tt0000113")
        let dtsPack = makeRelease("Bench.Show.S01.1080p.BluRay.DTS.x264-PTT", hash: "u")
        let files = PackFiles(names: ["P/Bench.Show.S01E01.1080p.BluRay.DTS.x264-PTT.mkv",
                                      "P/Bench.Show.S01E02.1080p.BluRay.DTS.x264-PTT.mkv"], sizes: [5, 5])
        let session = begin(e1, playing: dtsPack, recorder: recorder, files: files)
        eq(session?.plan?.rule, .samePack, "nothing else known yet: the pack")
        play(session, from: 0, to: 5)
        let eac3 = makeRelease("Bench.Show.S01E02.1080p.WEB-DL.DDP5.1.H.264-XYZ.mkv", hash: "v")
        answer([eac3])
        eq(session?.plan?.rule, .sameClass, "native first: the E-AC-3 release of the same class")
        eq(session?.plan?.torrent?.url, eac3.url, "XYZ's E02")
        play(session, from: 6, to: 180)
        eq(recorder.started.first?.torrent?.url, eac3.url, "E02 starts on the native release")

        // The same pack, and the sources list only VLC releases: the pack again.
        let vlcOnly = Recorder()
        let (f1, _) = makeShow("tt0000114")
        let again = begin(f1, playing: dtsPack, recorder: vlcOnly, files: files)
        play(again, from: 0, to: 5)
        answer([makeRelease("Bench.Show.S01E02.1080p.BluRay.DTS.x264-QQQ.mkv", hash: "w")])
        eq(again?.plan?.rule, .samePack, "no native release: the pack")
        eq(again?.plan?.torrent?.url, dtsPack.url, "the same torrent")
    }

    func testStillWatchingCountsOnlyChainsWithNoAction() {
        // Three episodes chained by the countdown, then the user leaves the player: the next playback starts at 0.
        let chain = Recorder()
        var (episode, guide) = makeShow("tt0000115", episodes: 6)
        for index in 0..<3 {
            let next = begin(episode, playing: makeRelease("Bench.Show.S01E0\(index + 1).1080p.HEVC-PTT.mkv", hash: "s"), recorder: chain)
            play(next, from: 0, to: 10)
            answer([makeRelease("Bench.Show.S01E0\(index + 2).1080p.HEVC-PTT.mkv", hash: Character(UnicodeScalar(UInt8(116 + index))))])
            play(next, from: 11, to: 180)
            episode = guide.episodes[index + 1]
            episode.show = guide
        }
        eq(chain.started.count, 3, "three chained")
        let fourth = begin(episode, playing: makeRelease("Bench.Show.S01E04.1080p.HEVC-PTT.mkv", hash: "s"), recorder: chain)
        check(chain.lines.last { $0.hasPrefix("[UpNext] begin S01E04") }?.contains("chained 3") == true, "E04 knows the 3", "\(chain.lines)")
        play(fourth, from: 0, to: 60)
        fourth?.playerClosed()
        var later = guide.episodes[4]
        later.show = guide
        _ = begin(later, playing: makeRelease("Bench.Show.S01E05.1080p.HEVC-PTT.mkv", hash: "s"), recorder: chain)
        check(chain.lines.last { $0.hasPrefix("[UpNext] begin S01E05") }?.contains("chained 0") == true,
              "a playback started by the user after Menu: no « Still watching? » carried over", "\(chain.lines)")

        // « Always Ask » and no clear continuity: each next episode goes through the chooser — the user picks, nothing counts.
        let asks = Recorder()
        var (first, shows) = makeShow("tt0000116", episodes: 6)
        for index in 0..<4 {
            let next = begin(first, playing: makeRelease("Bench.Show.S01E0\(index + 1).1080p.HEVC-PTT.mkv", hash: "x"), recorder: asks,
                             alwaysAsks: true)
            check(asks.lines.last { $0.hasPrefix("[UpNext] begin") }?.contains("chained 0") == true, "never counted", "\(asks.lines)")
            play(next, from: 0, to: 10)
            answer([makeRelease("Bench.Show.S01E0\(index + 2).720p.WEB.H264-ZZZ.mkv", hash: "y")])
            play(next, from: 11, to: 180)
            first = shows.episodes[index + 1]
            first.show = shows
        }
        eq(asks.fellBack.count, 4, "today's flow each time")
        eq(asks.started.count, 0, "nothing started without asking")
    }

    func testSourcesPlanAndAccept() {
        let recorder = Recorder()
        let (e1, _) = makeShow("tt0000103")
        let session = begin(e1, playing: makeRelease("Bench.Show.S01E01.1080p.HEVC-PTT.mkv", hash: "c"), recorder: recorder)
        play(session, from: 0, to: 5)
        eq(pendingSources.count, 1, "3 min: the sources asked at once")
        let ptt = makeRelease("Bench.Show.S01E02.1080p.HEVC-PTT.mkv", seeds: 2, hash: "d")
        answer([makeRelease("Bench.Show.S01E02.2160p.WEB.H265-QQQ.mkv", seeds: 90, hash: "e"), ptt])
        eq(session?.plan?.rule, .sameGroup, "the same group")
        play(session, from: 6, to: 155)
        session?.accept()
        eq(recorder.started.first?.torrent?.url, ptt.url, "Play Now: PTT's E02")
    }

    func testFallbacks() {
        // The start is refused: today's flow.
        let refused = Recorder()
        refused.refuseStart = true
        let (e1, _) = makeShow("tt0000104")
        let session = begin(e1, playing: makeRelease("Bench.Show.S01E01.1080p.HEVC-PTT.mkv", hash: "f"), recorder: refused)
        play(session, from: 0, to: 155)
        answer([makeRelease("Bench.Show.S01E02.1080p.HEVC-PTT.mkv", hash: "g")])
        session?.accept()
        eq(refused.started.count, 1, "tried")
        eq(refused.fellBack, ["tt0000104-s1e2"], "then today's flow")

        // No release at all: accepted, then today's flow at once.
        let none = Recorder()
        let (f1, _) = makeShow("tt0000105")
        let empty = begin(f1, playing: makeRelease("Bench.Show.S01E01.1080p.HEVC-PTT.mkv", hash: "h"), recorder: none)
        play(empty, from: 0, to: 155)
        answer([])
        eq(empty?.card?.versionLine, nil, "no version line once nothing is found")
        empty?.accept()
        eq(none.started.count, 0, "nothing started")
        eq(none.fellBack, ["tt0000105-s1e2"], "today's flow (the chooser, « No torrents found »)")

        // No plan in time: 3 s, then today's flow.
        let late = Recorder()
        let (g1, _) = makeShow("tt0000106")
        let slow = begin(g1, playing: makeRelease("Bench.Show.S01E01.1080p.HEVC-PTT.mkv", hash: "i"), recorder: late)
        play(slow, from: 0, to: 155)
        slow?.accept()
        eq(late.fellBack, [], "waits for the plan")
        time = 158
        timers.forEach { $0() }
        eq(late.fellBack, ["tt0000106-s1e2"], "3 s later: today's flow")

        // « Always Ask » and no clear continuity: the chooser of today's flow.
        let asks = Recorder()
        let (h1, _) = makeShow("tt0000107")
        let balanced = begin(h1, playing: makeRelease("Bench.Show.S01E01.2160p.WEB.H265-QQQ.mkv", hash: "j"), recorder: asks, alwaysAsks: true)
        play(balanced, from: 0, to: 10)
        answer([makeRelease("Bench.Show.S01E02.1080p.WEB.H264-ABC.mkv", hash: "k")])
        eq(balanced?.plan?.rule, .balanced, "balanced")
        check(balanced?.plan?.needsChooser == true, "needs the chooser")
        play(balanced, from: 11, to: 180)
        eq(asks.started.count, 0, "not played without asking")
        eq(asks.fellBack, ["tt0000107-s1e2"], "today's flow asks")
    }

    func testCancelChooseAndClose() {
        let cancel = Recorder()
        let (e1, _) = makeShow("tt0000108")
        let session = begin(e1, playing: makeRelease("Bench.Show.S01E01.1080p.HEVC-PTT.mkv", hash: "l"), recorder: cancel)
        play(session, from: 0, to: 160)
        session?.cancel()
        eq(session?.card, nil, "the card goes")
        play(session, from: 161, to: 179)
        check(session?.itemEnded() == true, "the session handles the end")
        eq(cancel.closed, 1, "the player closes, as before")
        eq(cancel.started.count + cancel.fellBack.count, 0, "nothing starts")

        let choose = Recorder()
        let (f1, _) = makeShow("tt0000109")
        let chooser = begin(f1, playing: makeRelease("Bench.Show.S01E01.1080p.HEVC-PTT.mkv", hash: "m"), recorder: choose)
        play(chooser, from: 0, to: 10)
        answer([makeRelease("Bench.Show.S01E02.1080p.HEVC-PTT.mkv", hash: "n")])
        play(chooser, from: 11, to: 160)
        chooser?.chooseVersion()
        eq(choose.chooser.count, 1, "the chooser opens")
        eq(choose.chooser.first?.rule, .sameGroup, "with the plan's release first")
        let other = makeRelease("Bench.Show.S01E02.720p.WEB.H264-ZZZ.mkv", hash: "o")
        chooser?.chose(other)
        eq(choose.started.first?.torrent?.url, other.url, "the pick starts")

        let close = Recorder()
        let (g1, _) = makeShow("tt0000110")
        let closing = begin(g1, playing: makeRelease("Bench.Show.S01E01.1080p.HEVC-PTT.mkv", hash: "p"), recorder: close)
        play(closing, from: 0, to: 160)
        closing?.playerClosed()
        eq(closing?.card, nil, "no card")
        check(UpNextSession.current == nil, "ended")
        play(closing, from: 161, to: 180)
        check(closing?.itemEnded() == false, "the player's end is its own")
        eq(close.started.count + close.fellBack.count + close.closed, 0, "nothing at all")
    }

    func testAfterPlayCardAndStillWatching() {
        // A file whose length is not known: the card after it.
        let after = Recorder()
        let (e1, _) = makeShow("tt0000111", episodes: 6)
        let session = begin(e1, playing: makeRelease("Bench.Show.S01E01.1080p.HEVC-PTT.mkv", hash: "q"), recorder: after)
        play(session, from: 0, to: 60, duration: nil)
        check(session?.card == nil, "no card while the length is unknown")
        check(session?.itemEnded() == true, "the end is the session's")
        eq(session?.card?.kind, .postPlay, "« Episode finished »")
        answer([makeRelease("Bench.Show.S01E02.1080p.HEVC-PTT.mkv", hash: "r")])
        for second in 61...71 { time = Double(second); timers.forEach { $0() } }
        eq(after.started.count, 1, "10 s later: E02")

        // Three episodes chained by the countdown alone, then « Still watching? ».
        let chain = Recorder()
        var (episode, guide) = makeShow("tt0000112", episodes: 6)
        for index in 0..<4 {
            let next = begin(episode, playing: makeRelease("Bench.Show.S01E0\(index + 1).1080p.HEVC-PTT.mkv", hash: "s"), recorder: chain)
            play(next, from: 0, to: 10)
            answer([makeRelease("Bench.Show.S01E0\(index + 2).1080p.HEVC-PTT.mkv", hash: Character(UnicodeScalar(UInt8(116 + index))))])
            play(next, from: 11, to: 180)
            if index < 3 {
                eq(chain.started.count, index + 1, "episode \(index + 2) chained")
            } else {
                eq(chain.started.count, 3, "the fourth: not started")
                eq(next?.card?.kind, .stillWatching, "« Still watching? »")
                next?.accept()
                eq(chain.started.count, 4, "Continue")
            }
            episode = guide.episodes[index + 1]
            episode.show = guide
        }
    }

    // MARK: 5.3.0's device session: the card's time, the accept line, the release on « Resume »

    func testTheDefaultCardComesSixtySecondsBeforeTheEnd() {
        let recorder = Recorder()
        let (e1, _) = makeShow("tt0000120")
        let pack = makeRelease("Bench.Show.S01.1080p.HEVC-PTT", hash: "a")
        let files = PackFiles(names: ["P/Bench.Show.S01E01.1080p.HEVC-PTT.mkv", "P/Bench.Show.S01E02.1080p.HEVC-PTT.mkv"], sizes: [5, 5])
        let session = begin(e1, playing: pack, recorder: recorder, files: files, cardLead: UpNextCountdown.defaultCardLead)
        play(session, from: 0, to: 119)
        eq(session?.card, nil, "no card before 2:00")
        check(recorder.lines.contains { $0.contains("card at 120 s (duration 180 s)") }, "the armed line", "\(recorder.lines)")
        play(session, from: 120, to: 120)
        eq(session?.card?.secondsLeft, 60, "60 s to the end of the file")
        eq(session?.card?.total, 60, "a 60 s countdown")
        check(recorder.lines.contains { $0.hasPrefix("[UpNext] card shown: countdown, 60 s") }, "the card line", "\(recorder.lines)")
        play(session, from: 121, to: 178)
        eq(recorder.started.count, 0, "nothing starts before the end")
        play(session, from: 179, to: 180)
        eq(recorder.started.count, 1, "the next episode at the end, once")
        eq(recorder.lines.filter { $0.hasPrefix("[UpNext] start S01E02 (deadline)") }.count, 1, "one start line, by the deadline")
    }

    func testEveryAcceptanceLogsItsSourceAndTheCardsTime() {
        func accepted(_ source: UpNextAcceptSource?) -> String? {
            let recorder = Recorder()
            let (e1, _) = makeShow("tt0000121")
            let session = begin(e1, playing: makeRelease("Bench.Show.S01E01.1080p.HEVC-PTT.mkv", hash: "c"), recorder: recorder)
            play(session, from: 0, to: 150)
            time = 152
            if let source = source { session?.accept(source: source) } else { session?.accept() }
            return recorder.lines.first { $0.hasPrefix("[UpNext] outcome accepted") }
        }
        eq(accepted(.playNow(cardUp: 12.4)), "[UpNext] outcome accepted (Play Now, card up 12.4 s)", "the card's Play Now, its time on screen")
        eq(accepted(.avkit(cardUp: nil)), "[UpNext] outcome accepted (AVKit didAccept, card up 2.0 s)", "AVKit, the session's time")
        eq(accepted(.overlay(cardUp: 3.24)), "[UpNext] outcome accepted (overlay, card up 3.2 s)", "the overlay")
        eq(accepted(.debug), "[UpNext] outcome accepted (debug, card up 2.0 s)", "the DEBUG answer")
        eq(accepted(nil), "[UpNext] outcome accepted (card button, card up 2.0 s)", "iPhone / iPad, Mac: the card's button")
    }

    func testThePressGuardOfTheAppleTVCard() {
        check(!UpNextPressGuard.accepts(appearedAt: 10, now: 10.3), "0.3 s after the card appeared: ignored")
        check(UpNextPressGuard.accepts(appearedAt: 10, now: 11.1), "1.1 s: it counts")
        check(UpNextPressGuard.accepts(appearedAt: 10, now: 11), "1.0 s: it counts")
        check(!UpNextPressGuard.accepts(appearedAt: nil, now: 11), "not on screen yet: ignored")
        var lines: [String] = []
        eq(UpNextPressGuard.check(appearedAt: 10, now: 10.3, button: "Play Now", log: { lines.append($0) }), nil, "refused")
        eq(lines, ["[UpNext] Play Now ignored: card up 0.3 s"], "the line")
        eq(UpNextPressGuard.check(appearedAt: nil, now: 10.3, button: "Continue", log: { lines.append($0) }), nil, "refused")
        eq(lines.last, "[UpNext] Continue ignored: card up not on screen yet", "the line, before viewDidAppear")
        let up = UpNextPressGuard.check(appearedAt: 10, now: 22.4, button: "Play Now", log: { lines.append($0) })
        check(up.map { abs($0 - 12.4) < 0.001 } == true, "accepted, 12.4 s up", "\(String(describing: up))")
        eq(lines.count, 2, "no line for a press that counts")

        // An ignored press leaves the session as it was: the countdown runs on, and a rewind still takes the card away.
        let recorder = Recorder()
        let (e1, _) = makeShow("tt0000122")
        let session = begin(e1, playing: makeRelease("Bench.Show.S01E01.1080p.HEVC-PTT.mkv", hash: "d"), recorder: recorder)
        play(session, from: 0, to: 150)
        eq(session?.card?.kind, .countdown, "the card")
        time = 150.3
        session?.tick(position: 140, duration: 180, isPlaying: true)
        eq(session?.card, nil, "a rewind before the card's time dismisses it")
        check(!recorder.lines.contains { $0.contains("outcome accepted") }, "nothing accepted", "\(recorder.lines)")
    }

    func testTheCardAfterAResumeReadsTheReleaseLabel() {
        // « Resume » plays the remembered pack by its short link; the episode's list holds the full magnet.
        let recorder = Recorder()
        let (e1, _) = makeShow("tt0000123")
        let full = Torrent(url: "magnet:?xt=urn:btih:\(String(repeating: "e", count: 40))&dn=Bench.Show.S01.2160p.HEVC-GRP"
                           + "&tr=udp%3A%2F%2Fa.example%3A1&tr=udp%3A%2F%2Fb.example%3A2&tr=udp%3A%2F%2Fc.example%3A3&tr=udp%3A%2F%2Fd.example%3A4",
                           quality: "2160p HEVC — T4P", seeds: 40, size: "3.2 GB", fileName: "Bench.Show.S01E01.2160p.HEVC-GRP.mkv")
        let files = PackFiles(names: ["P/Bench.Show.S01E01.2160p.HEVC-GRP.mkv", "P/Bench.Show.S01E02.2160p.HEVC-GRP.mkv"], sizes: [5, 5])
        let resume = RememberedRelease(torrent: full, files: files, playedIndex: 0, at: Date()).torrent
        let found = PlaybackStreamContext.playingRelease(sourceURL: resume.url, passed: resume, list: [full])
        let session = begin(e1, playing: found.playing, recorder: recorder, files: files)
        check(recorder.lines.contains { $0.hasSuffix("playing 2160p HEVC — T4P") }, "begin … playing <label>", "\(recorder.lines)")
        play(session, from: 0, to: 150)
        eq(session?.plan?.rule, .samePack, "the same pack")
        eq(session?.plan?.torrent?.qualityLabel, "2160p HEVC", "the label the card's line shows")
        eq(session?.card?.versionLine.map { _ in UpNextResumeReleaseTests.english(.samePack, session?.plan?.torrent?.qualityLabel ?? "") },
           "2160p HEVC · same pack", "never « ? · same pack »")
    }

    /// The card of before 5.3 (no session: a native proposal without a show
    /// guide) comes at the same time as the session's, no longer 30 s fixed.
    func testTheCardOfBefore53FollowsTheSetting() {
        eq(UpNextPreferences.legacyCardLead(duration: 2700, lead: 60), 60, "the default, 60 s")
        eq(UpNextPreferences.legacyCardLead(duration: 2700, lead: 90), 90, "the setting's 90 s")
        eq(UpNextPreferences.legacyCardLead(duration: 2700, lead: 30), 30, "30 s")
        eq(UpNextPreferences.legacyCardLead(duration: 120, lead: 60), 40, "at most a third of a short file")
        check(abs(UpNextPreferences.legacyCardLead(duration: 178, lead: 60) - 178.0 / 3) < 1e-9, "the rig's 3-minute episode: a third",
              "\(UpNextPreferences.legacyCardLead(duration: 178, lead: 60))")
    }

    /// Its countdown is the file's time: a pause or a stall during the card does not start the
    /// next episode before the end of this one.
    func testTheCardOfBefore53CountsTheFilesTime() {
        eq(UpNextPreferences.legacySecondsLeft(remaining: 55.2, total: 60, previous: 56), 55, "playing: the file's seconds left")
        eq(UpNextPreferences.legacySecondsLeft(remaining: 55.2, total: 60, previous: 55), 55,
           "paused or stalled a second later: the same file time, the count holds")
        eq(UpNextPreferences.legacySecondsLeft(remaining: 40, total: 60, previous: 2), 40,
           "40 s of a stall later the count is still the file's (the wall clock would have reached 0)")
        eq(UpNextPreferences.legacySecondsLeft(remaining: 0.3, total: 60, previous: 1), 0, "the end of the file: 0, the next episode")
        eq(UpNextPreferences.legacySecondsLeft(remaining: 300, total: 60, previous: 60), 60, "never more than the card's length")
        eq(UpNextPreferences.legacySecondsLeft(remaining: nil, total: 60, previous: 30), 29, "no item: one second less, as before")
        eq(UpNextPreferences.legacySecondsLeft(remaining: .nan, total: 60, previous: 0), 0, "never below 0")
    }
}
