//
//  NewEpisodesTests.swift
//  PopcornTimeTests
//
//  New and upcoming episodes of the followed shows (PopcornKit: NewEpisodesRule, ShowGuide,
//  Library.refreshNewEpisodes), on answers recorded from Cinemeta and TVMaze on 2026-11-14
//  (Fixtures/Library). The clock, the storage and the network are the tests'.
//

import Foundation
import XCTest
@testable import PopcornKit

final class NewEpisodesTests: CheckedTestCase {

    private typealias F = LibraryFixtures

    /// When the answers were recorded.
    private let recorded = LibraryFixtures.date("2026-11-14T15:40:00Z")

    private func calendar(_ file: String = "Library/cm_calendar_videos.json") -> [ShowGuide] {
        return LibraryRemote.guides(fromCinemetaCalendar: Fixtures.data(file)) ?? []
    }

    private func guide(_ showID: String) -> ShowGuide {
        guard let guide = calendar().first(where: { $0.showID == showID }) else {
            XCTFail("no \(showID) in the recorded calendar")
            return ShowGuide(showID: showID, source: .cinemeta)
        }
        return guide
    }

    private func compute(_ showID: String, reached: EpisodeNumber?, lastActivity: String? = nil, watched: [EpisodeNumber] = [],
                         acknowledged: EpisodeNumber? = nil, now: Date? = nil) -> ShowNewEpisodes {
        let guide = self.guide(showID)
        let date = now ?? recorded
        return NewEpisodesRule.compute(showID: showID, showTitle: guide.title, airings: guide.recentAirings(now: date),
                                       reached: reached, lastActivity: lastActivity.map(F.date), watched: Set(watched),
                                       acknowledgedThrough: acknowledged, now: date)
    }

    private func numbers(_ episodes: [GuideEpisode]) -> [String] {
        return episodes.map { "S\($0.season)E\($0.episode)" }
    }

    // MARK: - Recorded answers

    func testCinemetaCalendarAnswer() {
        let guides = calendar()
        eq(guides.map { $0.showID }, ["tt31510819", "tt26598805", "tt33043892", "tt16358384", "tt9813792", "tt5875444", "tt0903747"],
           "the seven shows asked")
        let mobland = guide("tt31510819")
        eq(mobland.title, "MobLand", "its title")
        eq(mobland.status, "Continuing", "its status")
        eq(numbers(mobland.episodes), ["S1E10", "S2E1", "S2E2", "S2E3", "S2E4", "S2E5", "S2E6", "S2E7", "S2E8", "S2E9", "S2E10"],
           "about ten episodes around today, in order")
        eq(mobland.episode(F.number(2, 9))?.aired, F.date("2026-11-13T03:00:00Z"), "an episode's air instant")
        eq(mobland.episode(F.number(2, 9))?.title, "Nervous Breakdown", "…and its title")
        check(mobland.source == .cinemeta && mobland.checkedAt == nil, "from Cinemeta; not yet dated")
        check(!mobland.isComplete, "a calendar answer is a window, not the whole guide")
        eq(mobland.runtime, 47, "an episode's usual length")
        // 100 shows in one answer (what a single request returns).
        let hundred = calendar("Library/cm_calendar_videos_100.json")
        eq(hundred.count, 100, "100 shows")
        check(hundred.allSatisfy { (2...20).contains($0.episodes.count) }, "2 to 20 episodes each")
        check(LibraryRemote.guides(fromCinemetaCalendar: Data("{}".utf8)) == nil, "not a calendar: nil, not an empty list")
        check(LibraryRemote.guides(fromCinemetaCalendar: Data("oops".utf8)) == nil, "not JSON: nil")
    }

    func testTVMazeAnswer() {
        let show = (try? JSONSerialization.jsonObject(with: Fixtures.data("Library/tvm_lookup_tt31510819.json"))) as? [String: Any] ?? [:]
        let guide = LibraryRemote.guide(showID: "tt31510819", tvmazeShow: show, episodes: Fixtures.data("Library/tvm_episodes_tt31510819.json"))
        eq(guide?.title, "MobLand", "the show's name")
        eq(guide?.status, "Running", "its status")
        eq(guide?.episodes.count, 20, "the full guide: 20 episodes")
        eq(guide?.episode(F.number(2, 9))?.aired, F.date("2026-11-13T12:00:00Z"), "the airstamp, an exact instant")
        check(guide?.source == .tvmaze && guide?.isComplete == true, "from TVMaze, complete")
        eq(guide?.runtime, 46, "an episode's usual length")
        // The full guide is cut to the latest ten aired and what is still to come.
        eq(numbers(guide?.recentAirings(now: recorded) ?? []), ["S1E10", "S2E1", "S2E2", "S2E3", "S2E4", "S2E5", "S2E6", "S2E7", "S2E8", "S2E9", "S2E10"],
           "the same eleven episodes as Cinemeta's calendar")
        check(LibraryRemote.guide(showID: "tt31510819", tvmazeShow: show, episodes: Data("{}".utf8)) == nil, "not an episode list: nil")
    }

    // MARK: - The rule

    func testNewAfterTheLastEpisodeReached() {
        // Up to date until last week: S2E9 aired on the 13th, S2E10 airs on the 20th.
        var found = compute("tt31510819", reached: F.number(2, 8), lastActivity: "2026-11-07T21:00:00Z")
        eq(numbers(found.new), ["S2E9"], "one new episode")
        eq(numbers(found.upcoming), ["S2E10"], "the next one airs within 7 days")
        eq(found.latestAiredAt, F.date("2026-11-13T03:00:00Z"), "when the latest aired")
        check(found.hasBadge && found.unacknowledged == found.new, "a badge is due")
        eq(found.stillURL(of: found.new[0])?.absoluteString, "https://episodes.metahub.space/tt31510819/2/9/w780.jpg", "its still")

        // Three weeks behind: everything aired since the last play.
        found = compute("tt31510819", reached: F.number(2, 5), lastActivity: "2026-10-17T21:00:00Z")
        eq(numbers(found.new), ["S2E6", "S2E7", "S2E8", "S2E9"], "four episodes aired since")

        // Stopped after season 1, a year ago: the whole new season.
        found = compute("tt31510819", reached: F.number(1, 10), lastActivity: "2025-06-02T21:00:00Z")
        eq(numbers(found.new), ["S2E1", "S2E2", "S2E3", "S2E4", "S2E5", "S2E6", "S2E7", "S2E8", "S2E9"], "season 2 so far")

        // Catching up now on older episodes: only what is recent is news (the rest is "next up").
        found = compute("tt31510819", reached: F.number(2, 2), lastActivity: "2026-11-14T10:00:00Z")
        eq(numbers(found.new), ["S2E8", "S2E9"], "aired in the last 14 days")

        // Watched episodes are never new; nothing before or at the episode reached.
        found = compute("tt31510819", reached: F.number(2, 7), lastActivity: "2026-10-31T21:00:00Z", watched: [F.number(2, 9)])
        eq(numbers(found.new), ["S2E8"], "S2E9 is watched")
        found = compute("tt31510819", reached: F.number(2, 9), lastActivity: "2026-11-13T21:00:00Z")
        check(found.new.isEmpty && numbers(found.upcoming) == ["S2E10"], "up to date: nothing new, one upcoming")
    }

    func testAShowThatEndedIsNotNews() {
        // Cinemeta's calendar returns the last ten episodes of Breaking Bad (2012–2013).
        let found = compute("tt0903747", reached: F.number(5, 10), lastActivity: "2026-11-10T21:00:00Z")
        check(found.new.isEmpty && found.upcoming.isEmpty && found.isEmpty, "catching up on a finished show: no new episodes")
        eq(guide("tt0903747").episodes.count, 10, "though the calendar lists ten episodes after S5E6")
    }

    func testAWatchlistedShowNeverStarted() {
        // Nocturne: S1E1-2 on Oct 30, E3 on Nov 6, E4 on Nov 13, E5 on Nov 20.
        var found = compute("tt26598805", reached: nil)
        eq(numbers(found.new), ["S1E3", "S1E4"], "aired in the last 14 days")
        eq(numbers(found.upcoming), ["S1E5"], "airing within 7 days")
        // Dexter: Resurrection — the calendar also lists specials (season 0): never new.
        found = compute("tt33043892", reached: nil)
        eq(numbers(found.new), ["S2E1", "S2E2"], "season 2's first two episodes; no special")
        eq(numbers(found.upcoming), ["S2E3"], "S2E3 on the 16th")
        // From: its season ended in June.
        check(compute("tt9813792", reached: nil).isEmpty, "nothing aired recently, nothing coming")
    }

    func testAnEpisodeIsNewOnlyOnceItHasAired() {
        let before = compute("tt31510819", reached: F.number(2, 9), lastActivity: "2026-11-13T21:00:00Z", now: F.date("2026-11-20T02:59:59Z"))
        check(before.new.isEmpty && numbers(before.upcoming) == ["S2E10"], "one second before it airs: upcoming")
        let after = compute("tt31510819", reached: F.number(2, 9), lastActivity: "2026-11-13T21:00:00Z", now: F.date("2026-11-20T03:00:00Z"))
        check(numbers(after.new) == ["S2E10"] && after.upcoming.isEmpty, "at its air instant: new")
        let far = compute("tt31510819", reached: F.number(2, 8), lastActivity: "2026-11-07T21:00:00Z", now: F.date("2026-11-12T02:59:59Z"))
        check(far.new.isEmpty && numbers(far.upcoming) == ["S2E9"], "S2E10 is more than 7 days away: not yet upcoming")
    }

    func testAcknowledgedThrough() {
        var found = compute("tt31510819", reached: F.number(2, 5), lastActivity: "2026-10-17T21:00:00Z", acknowledged: F.number(2, 8))
        eq(numbers(found.new), ["S2E6", "S2E7", "S2E8", "S2E9"], "still four new episodes")
        eq(numbers(found.unacknowledged), ["S2E9"], "one the user has not been shown")
        found = compute("tt31510819", reached: F.number(2, 5), lastActivity: "2026-10-17T21:00:00Z", acknowledged: F.number(2, 9))
        check(!found.hasBadge && found.new.count == 4, "all shown: no badge, the episodes stay new")
    }

    // MARK: - Guides merged

    func testCinemetaNeverRewritesAProvidersGuide() {
        // The provider's guide (TVMaze numbering) of a show page opened two weeks ago: S2E1–E8, E8 undated.
        let provider = ShowGuide(showID: "tt31510819", title: "MobLand (provider)", episodes:
            (1...8).map { F.episode(2, $0, aired: $0 == 8 ? nil : "2026-09-18T12:00:00Z", title: "Provider \($0)") }, source: .provider)
        let merged = provider.merging(guide("tt31510819"), checkedAt: recorded)
        eq(numbers(merged.episodes), ["S2E1", "S2E2", "S2E3", "S2E4", "S2E5", "S2E6", "S2E7", "S2E8", "S2E9", "S2E10"],
           "only the episodes after the guide's last one are added (not Cinemeta's S1E10)")
        eq(merged.episode(F.number(2, 1))?.title, "Provider 1", "a known episode keeps its title")
        eq(merged.episode(F.number(2, 1))?.aired, F.date("2026-09-18T12:00:00Z"), "…and its date")
        eq(merged.episode(F.number(2, 8))?.aired, F.date("2026-11-06T03:00:00Z"), "a missing date is filled in")
        check(merged.source == .provider && merged.title == "MobLand (provider)" && merged.checkedAt == recorded,
              "still the provider's guide, now dated")
        // A full guide replaces the episodes, but for those known after its last one.
        let replaced = merged.merging(ShowGuide(showID: "tt31510819", episodes: [F.episode(1, 1), F.episode(2, 9, title: "Fresh")], source: .tvmaze),
                                      checkedAt: nil)
        check(numbers(replaced.episodes) == ["S1E1", "S2E9", "S2E10"] && replaced.source == .tvmaze && replaced.checkedAt == recorded,
              "a full guide replaces; S2E10, after its end, stays", numbers(replaced.episodes).joined(separator: " "))
        eq(replaced.episode(F.number(2, 9))?.title, "Fresh", "…and its own episodes win")
        // An empty answer (the show is not in the calendar) only dates the guide.
        let later = recorded.addingTimeInterval(3600)
        let dated = merged.merging(ShowGuide(showID: "tt31510819", source: .cinemeta), checkedAt: later)
        check(dated.episodes == merged.episodes && dated.checkedAt == later, "an empty answer changes nothing but the date")
    }

    // MARK: - The library: followed shows, refresh, cache lifetime, fallback

    private final class Remote {
        var calendarCalls: [[String]] = []
        var tvmazeCalls: [String] = []
        var calendarAnswers = true
        /// What TVMaze says of a show that is not MobLand: it could not be reached, or (true) it
        /// answered that it does not have the show.
        var tvmazeAnswersUnknown = false
        let lock = NSLock()

        func make() -> LibraryRemote {
            return LibraryRemote(calendar: { [self] ids, done in
                lock.lock(); calendarCalls.append(ids); lock.unlock()
                guard calendarAnswers else { return done(nil) }
                let known = LibraryRemote.guides(fromCinemetaCalendar: Fixtures.data("Library/cm_calendar_videos.json")) ?? []
                done(known.filter { ids.contains($0.showID) })
            }, tvmazeGuide: { [self] id, done in
                lock.lock(); tvmazeCalls.append(id); lock.unlock()
                guard id == "tt31510819" else { return done(tvmazeAnswersUnknown ? .unknown : .unreachable) }
                let show = (try? JSONSerialization.jsonObject(with: Fixtures.data("Library/tvm_lookup_tt31510819.json"))) as? [String: Any] ?? [:]
                done(LibraryRemote.guide(showID: id, tvmazeShow: show, episodes: Fixtures.data("Library/tvm_episodes_tt31510819.json"))
                    .map { .found($0) } ?? .unknown)
            }, title: { _, _, done in done(.unreachable) })
        }
    }

    /// MobLand watched through S2E8 on Nov 7; Nocturne and From in the watchlist, never started.
    private func followingLibrary(_ remote: Remote, clock: F.Clock, storage: MemoryLibraryStorage = MemoryLibraryStorage(),
                                  center: NotificationCenter = NotificationCenter()) -> Library {
        storage.set([["imdb_id": "tt26598805", "title": "Nocturne"], ["imdb_id": "tt9813792", "title": "From"]], forKey: "showsWatchlist")
        let library = Library(storage: storage, guideDirectory: nil, remote: remote.make(), center: center, now: { clock.now })
        library.tvmazeSpacing = 0
        let today = clock.now
        clock.now = F.date("2026-11-07T21:00:00Z")
        for episode in 1...8 { library.setWatched(true, id: "tt31510819-s2e\(episode)", list: .episodes) }
        clock.now = today
        return library
    }

    private func refresh(_ library: Library, force: Bool = false) -> Bool {
        let done = expectation(description: "refreshed")
        var asked = false
        library.refreshNewEpisodes(force: force) { asked = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return asked
    }

    func testFollowedShows() {
        let clock = F.Clock("2026-11-14T15:40:00Z")
        let library = followingLibrary(Remote(), clock: clock)
        let followed = library.followedShows()
        eq(followed.map { $0.showID }, ["tt31510819", "tt9813792", "tt26598805"],
           "the show with activity first, then the watchlist's, the latest added first")
        eq(followed[0].reached, F.number(2, 8), "MobLand: reached S2E8")
        eq(followed[0].lastActivity, F.date("2026-11-07T21:00:00Z"), "…last on Nov 7")
        check(!followed[0].isInWatchlist && followed[1].isInWatchlist && followed[1].reached == nil && followed[1].lastActivity == nil,
              "a watchlisted show never started has no activity")
        eq(followed[2].title, "Nocturne", "a watchlisted show has its stored title")
        eq(library.watchlist(.show).map { $0.imdbID }, ["tt9813792", "tt26598805"], "the watchlist's items, the latest added first")
        eq(library.watchlist(.show)[0].posterURL?.absoluteString, "https://images.metahub.space/poster/medium/tt9813792/img",
           "no stored poster: metahub's by IMDb id")
        // A started episode counts as reached; a special or an episode only opened does not.
        library.setProgress(0.01, id: "tt31510819-s2e10", list: .episodes)
        library.setProgress(0.5, id: "tt31510819-s0e3", list: .episodes)
        eq(library.followedShows()[0].reached, F.number(2, 8), "still S2E8")
        library.setProgress(0.3, id: "tt31510819-s2e9", list: .episodes)
        eq(library.followedShows()[0].reached, F.number(2, 9), "S2E9 started: reached")
        // 180 days without activity: no longer followed (not in the watchlist).
        clock.advance(181 * 86400)
        eq(library.followedShows().map { $0.showID }, ["tt9813792", "tt26598805"], "after 180 days only the watchlist's shows are followed")
    }

    func testRefreshFromCinemetaAndCacheLifetime() {
        let clock = F.Clock("2026-11-14T15:40:00Z")
        let remote = Remote()
        let center = NotificationCenter()
        let library = followingLibrary(remote, clock: clock, center: center)
        check(library.newEpisodes().isEmpty, "nothing is known before the first refresh")

        var reasons: [LibraryChange.Reason] = []
        let token = center.addObserver(forName: .libraryDidChange, object: library, queue: nil) { note in
            if let reason = LibraryChange.reason(of: note) { reasons.append(reason) }
        }
        defer { center.removeObserver(token) }

        check(refresh(library), "the first refresh asks")
        eq(remote.calendarCalls, [["tt31510819", "tt9813792", "tt26598805"]], "one request for the three followed shows")
        check(remote.tvmazeCalls.isEmpty, "TVMaze is not asked")
        eq(reasons, [.newEpisodes], "one change notification")

        let found = library.newEpisodes()
        eq(found.map { $0.showID }, ["tt26598805", "tt31510819"], "the show whose latest episode aired last comes first; From has nothing")
        eq(numbers(found[1].new), ["S2E9"], "MobLand: S2E9")
        eq(numbers(found[1].upcoming), ["S2E10"], "MobLand: S2E10 next")
        eq(found[1].showTitle, "MobLand", "its title came with the calendar")
        eq(numbers(found[0].new), ["S1E3", "S1E4"], "Nocturne: two episodes in the last 14 days")
        eq(library.resume.entry("tt31510819-s2e8")?.title, "MobLand", "the calendar also named the show of the resume entry")
        // The row can now name the next episode without asking anything.
        eq(library.continueWatching().map { "\($0.mediaID):\($0.reason.rawValue)" }, ["tt31510819-s2e9:nextUp"], "next up: S2E9")
        eq(library.continueWatching().first?.episodeTitle, "Nervous Breakdown", "…with its title")
        eq(library.continueWatching().first?.remaining, Double(47 * 60), "…and a whole episode left")
        check(library.titlesToHydrate().isEmpty, "nothing else to ask for the row")

        // Fresh for 6 hours.
        check(!refresh(library), "right after: nothing is asked")
        clock.advance(6 * 3600 - 1)
        check(!refresh(library), "5 h 59 min 59 s later: still fresh")
        clock.advance(1)
        check(refresh(library), "6 h later: asked again")
        eq(remote.calendarCalls.count, 2, "two requests in all")
        check(refresh(library, force: true) && remote.calendarCalls.count == 3, "forced: asked whatever the age")

        // A show followed since is the only one asked.
        library.setProgress(0.5, id: "tt16358384-s4e5", list: .episodes)
        check(refresh(library), "a new show is stale")
        eq(remote.calendarCalls.last, ["tt16358384"], "only that show is asked")

        // Acknowledged: the badge goes out, the episode stays new.
        check(library.newEpisodes().first { $0.showID == "tt31510819" }?.hasBadge == true, "a badge before")
        library.acknowledgeNewEpisodes(ofShow: "tt31510819")
        let mobland = library.newEpisodes().first { $0.showID == "tt31510819" }
        check(mobland?.hasBadge == false && mobland?.new.count == 1, "no badge after, S2E9 still listed")
        check(reasons.last == .newEpisodes, "…and a change notification")
        // Watching it removes it.
        library.setWatched(true, id: "tt31510819-s2e9", list: .episodes)
        check(library.newEpisodes().first { $0.showID == "tt31510819" }?.new.isEmpty == true, "watched: not new any more (S2E10 still upcoming)")
        // A new library on the same storage keeps the acknowledgement (it is durable).
    }

    func testAcknowledgementsAreStored() {
        let storage = MemoryLibraryStorage()
        let marks = NewEpisodesAcknowledgements(storage: storage)
        check(marks.mark("tt31510819") == nil, "no mark at first")
        check(marks.acknowledge("tt31510819", through: F.number(2, 9)), "set")
        check(!marks.acknowledge("tt31510819", through: F.number(2, 8)), "never moved back")
        eq(NewEpisodesAcknowledgements(storage: storage).mark("tt31510819"), F.number(2, 9), "read back from the storage")
        check(storage.object(forKey: NewEpisodesAcknowledgements.storageKey) is [String: [Int]], "a property list: [show: [season, episode]]")
    }

    func testTVMazeWhenCinemetaIsDownOrTheBulkLookupIsOff() {
        let clock = F.Clock("2026-11-14T15:40:00Z")
        let remote = Remote()
        remote.calendarAnswers = false
        var library = followingLibrary(remote, clock: clock)
        check(refresh(library), "asked")
        eq(remote.calendarCalls.count, 1, "Cinemeta was tried once")
        eq(remote.tvmazeCalls, ["tt31510819", "tt9813792", "tt26598805"], "then TVMaze, show by show")
        eq(library.newEpisodes().map { $0.showID }, ["tt31510819"], "what TVMaze knows is used")
        eq(numbers(library.newEpisodes()[0].new), ["S2E9"], "MobLand: S2E9, from TVMaze's guide")
        // The shows TVMaze could not be asked about are asked again next time; MobLand is fresh.
        check(refresh(library), "asked again")
        eq(Array(remote.tvmazeCalls.suffix(2)), ["tt9813792", "tt26598805"], "only the two shows it did not answer for")
        // Once it answers that it does not have them, they are checked: not asked again for 6 h.
        remote.tvmazeAnswersUnknown = true
        check(refresh(library), "asked a third time")
        eq(remote.tvmazeCalls.count, 7, "the two shows again")
        check(!refresh(library), "TVMaze does not have them: nothing left to ask")
        clock.advance(6 * 3600)
        check(refresh(library) && remote.tvmazeCalls.count == 10, "6 h later every show is asked again")

        // The user turned the bulk lookup off: Cinemeta never gets the list.
        let quiet = Remote()
        let storage = MemoryLibraryStorage()
        library = followingLibrary(quiet, clock: clock, storage: storage)
        check(library.isBulkEpisodeLookupEnabled, "on by default")
        library.isBulkEpisodeLookupEnabled = false
        check(storage.object(forKey: Library.bulkEpisodeLookupKey) as? Bool == false, "the choice is stored")
        check(refresh(library), "asked")
        check(quiet.calendarCalls.isEmpty, "no calendar request")
        eq(quiet.tvmazeCalls, ["tt31510819", "tt9813792", "tt26598805"], "TVMaze, show by show")
    }

    func testShowsTVMazeDoesNotHaveDoNotKeepTheOthersWaiting() {
        // 22 followed shows TVMaze does not have, more recently added than MobLand, Nocturne and From;
        // 20 shows are asked per refresh.
        let clock = F.Clock("2026-11-14T15:40:00Z")
        let remote = Remote()
        remote.tvmazeAnswersUnknown = true
        let storage = MemoryLibraryStorage()
        storage.set((0..<22).map { ["imdb_id": "tt\(9_000_000 + $0)", "title": "Anime \($0)"] }
                    + [["imdb_id": "tt31510819", "title": "MobLand"]], forKey: "showsWatchlist")
        storage.set(false, forKey: Library.bulkEpisodeLookupKey)
        let library = Library(storage: storage, guideDirectory: nil, remote: remote.make(), now: { clock.now })
        library.tvmazeSpacing = 0
        let order = library.followedShowIDs()
        eq(order.first, "tt31510819", "the latest added is asked first")
        check(refresh(library), "asked")
        eq(remote.tvmazeCalls, Array(order.prefix(20)), "the first 20 followed shows")
        check(refresh(library), "asked again")
        eq(Array(remote.tvmazeCalls.dropFirst(20)), Array(order.dropFirst(20)),
           "the second refresh asks the shows left, not the ones TVMaze does not have again")
        check(!refresh(library), "then nothing for 6 h")
        check(library.newEpisodes().map { $0.showID } == ["tt31510819"], "what TVMaze knows is there")
    }

    func testOneTVMazeChainWhenCinemetaIsDown() {
        // 230 followed shows and no answer from Cinemeta: its three requests fail, and TVMaze is asked
        // about 20 shows in one chain — not 20 per failed request, three chains at once.
        let clock = F.Clock("2026-11-14T15:40:00Z")
        let remote = Remote()
        remote.calendarAnswers = false
        let storage = MemoryLibraryStorage()
        storage.set((0..<230).map { ["imdb_id": "tt\(9_000_000 + $0)", "title": "Show \($0)"] }, forKey: "showsWatchlist")
        let library = Library(storage: storage, guideDirectory: nil, remote: remote.make(), now: { clock.now })
        library.tvmazeSpacing = 0
        check(refresh(library), "asked")
        eq(remote.calendarCalls.count, 3, "three calendar requests")
        eq(remote.tvmazeCalls, Array(library.followedShowIDs().prefix(20)), "then 20 shows from TVMaze, the first followed, one after the other")
    }

    func testAHostThatDoesNotKnowIsNotAHostThatDidNotAnswer() {
        func said(_ outcome: IndexFetcher.Outcome) -> String {
            switch LibraryRemote.answer(outcome, { String(data: $0, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } }) {
            case .found(let text): return "found \(text)"
            case .unknown: return "unknown"
            case .unreachable: return "unreachable"
            }
        }
        eq(said(.data(Data("x".utf8))), "found x", "a body that reads")
        eq(said(.data(Data())), "unknown", "a body with nothing in it (Cinemeta's `{}`): the host does not have it")
        eq(said(.status(404)), "unknown", "404: the host does not have it")
        eq(said(.status(429)), "unreachable", "429: to ask again")
        eq(said(.status(503)), "unreachable", "503: to ask again")
        eq(said(.failed), "unreachable", "no answer: to ask again")
        // The recorded answers through the same reading.
        check(LibraryRemote.title(fromCinemetaMeta: Data("{}".utf8), imdbID: "tt15239678") == nil, "Cinemeta's `{}` names nothing")
    }

    func testMoreThanAHundredShowsGoInBatches() {
        let clock = F.Clock("2026-11-14T15:40:00Z")
        let remote = Remote()
        let storage = MemoryLibraryStorage()
        storage.set((0..<230).map { ["imdb_id": "tt\(9_000_000 + $0)", "title": "Show \($0)"] }, forKey: "showsWatchlist")
        let library = Library(storage: storage, guideDirectory: nil, remote: remote.make(), now: { clock.now })
        check(refresh(library), "asked")
        eq(remote.calendarCalls.map { $0.count }.sorted(), [30, 100, 100], "230 shows: three requests of at most 100 ids")
        eq(Set(remote.calendarCalls.flatMap { $0 }).count, 230, "each show asked once")
        check(!refresh(library), "shows Cinemeta returned nothing for are not asked again within 6 h")
    }

    func testGuidesAreCachedOnDisk() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PopcornTimeTests-guides-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = ShowGuideCache(directory: folder)
        check(cache.guide("tt31510819") == nil, "nothing at first")
        let stored = cache.merge(guide("tt31510819"), checkedAt: recorded)
        cache.flush()
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tt31510819.json").path), "one file per show")
        let reread = ShowGuideCache(directory: folder).guide("tt31510819")
        eq(reread, stored, "read back as stored: episodes, dates, the check date")
        check(ShowGuideCache(directory: folder).guide("../etc/passwd") == nil, "only IMDb ids name a file")
    }
}
