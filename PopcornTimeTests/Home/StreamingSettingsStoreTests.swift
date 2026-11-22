//
//  StreamingSettingsStoreTests.swift
//  PopcornTimeTests
//
//  The streaming section of Settings, shared by the Apple TV, iPhone, iPad and Mac
//  (StreamingSettingsStore): the country (the device's by default), TMDB's countries, a
//  country's services (stores left out, most watched first), the services chosen and how they
//  follow a new country, the loading and failure states, the key saved or removed, and the hub
//  it is given told to rebuild its page each time. TMDB answers from the recorded files of
//  Fixtures/Home (as a DEBUG fixture run) or not at all; nothing reaches it.
//

import Foundation
import XCTest
@testable import PopcornKit

final class StreamingSettingsStoreTests: CheckedTestCase {

    private var sandbox: HomeSandbox!
    /// How many times the store told its hub to rebuild the page.
    private var refreshes = 0

    override func setUp() {
        super.setUp()
        sandbox = HomeSandbox()
        refreshes = 0
    }

    override func tearDown() {
        sandbox.discard()
        super.tearDown()
    }

    private func settings(region: String? = "FR") -> HomeSettings {
        return HomeSettings(defaults: sandbox.defaults, deviceLanguages: { ["fr-FR"] }, deviceRegion: { region })
    }

    /// TMDB as the DEBUG fixture runs have it: every key taken, the recorded lists.
    private var recorded: TMDBStreamingClient { TMDBStreamingClient(recordedIn: Fixtures.url("Home")) }

    /// TMDB that never answers (offline): no session request ever succeeds.
    private var silent: TMDBStreamingClient {
        let client = TMDBStreamingClient(recordedIn: Fixtures.url("Home"))
        client.recorded = { _, completion in DispatchQueue.global().async { completion(nil) } }
        return client
    }

    @MainActor
    private func makeStore(_ settings: HomeSettings, client: TMDBStreamingClient? = nil) -> StreamingSettingsStore {
        return StreamingSettingsStore(settings: settings, client: client ?? recorded, locale: Locale(identifier: "fr_FR"),
                                      refreshHub: { [weak self] in self?.refreshes += 1 })
    }

    @MainActor
    func testTheDefaultsComeFromTheDevice() {
        let store = makeStore(settings(region: "FR"))
        eq(store.region, "FR", "the device's region")
        eq(store.chosenServices.map(\.id), ["8", "119", "337", "350"], "Netflix, Prime Video, Disney+, Apple TV")
        eq(store.keyState, .none, "no key")
        check(!store.hasKey, "none")
        eq(store.servicesLoad, .idle, "nothing asked")
        eq(store.regionName("FR"), "France", "a country by its name")
        eq(store.regionOptions.map(\.id), ["FR"], "before TMDB's list: the current country alone")

        let american = makeStore(settings(region: "US"))
        eq(american.chosenServices.map(\.id), ["8", "9", "337", "350"], "in the United States, Prime Video is 9")
        let nowhere = makeStore(settings(region: nil))
        eq(nowhere.region, "US", "no region: the United States")
        eq(refreshes, 0, "reading changes nothing on the Home")
    }

    @MainActor
    func testTheCountriesAreTMDBsByName() {
        let store = makeStore(settings())
        var listed: [StreamingChoice]?
        store.loadRegions { listed = $0 }
        eq(store.regionsLoad, .loading, "asked")
        homeWait(10) { listed != nil }
        eq(store.regionsLoad, .loaded, "answered")
        eq(Set(store.regionChoices?.map(\.id) ?? []), ["FR", "BE", "CH", "CA", "US", "GB", "DE", "ES", "IT"], "TMDB's countries")
        let titles = store.regionChoices?.map(\.title) ?? []
        eq(titles, titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, "by name")
        check(titles.contains("Allemagne"), "named in the store's language", "\(titles)")
        eq(listed, store.regionChoices, "the same to the completion")

        let offline = StreamingSettingsStore.regionChoices(nil, locale: Locale(identifier: "en_US"))
        check(offline.count > 200, "no answer: every country the system knows", "\(offline.count)")
        check(offline.allSatisfy { $0.id.count == 2 }, "two-letter codes only")
        eq(StreamingSettingsStore.regionChoices(["FR", "FR", "150", "BE"], locale: Locale(identifier: "en_US")).map(\.id),
           ["BE", "FR"], "each once, no region that is not a country")
    }

    @MainActor
    func testACountrysServicesLeaveTheStoresOut() {
        let store = makeStore(settings())
        var listed: [StreamingChoice]??
        store.loadServices { listed = .some($0) }
        eq(store.servicesLoad, .loading, "asked")
        homeWait(10) { listed != nil }
        eq(store.servicesLoad, .loaded, "answered")
        let ids = store.serviceChoices?.map(\.id) ?? []
        eq(ids.first, "8", "the most watched first: Netflix")
        check(ids.contains("381") && ids.contains("119"), "the country's services", "\(ids)")
        check(!ids.contains("2") && !ids.contains("10"), "no store (Apple TV Store, Amazon Video)", "\(ids)")
        eq(store.serviceOptions.prefix(4).map(\.id), ["8", "119", "337", "350"], "the chosen ones first")
        eq(Set(store.serviceOptions.map(\.id)).count, store.serviceOptions.count, "each once")
    }

    @MainActor
    func testAServiceListWithoutAnAnswerIsAFailure() {
        let store = makeStore(settings(), client: silent)
        var listed: [StreamingChoice]??
        store.loadServices { listed = .some($0) }
        homeWait(10) { listed != nil }
        check(listed != nil && listed! == nil, "no answer: nil")
        eq(store.servicesLoad, .failed, "a failure")
        check(store.serviceChoices == nil, "no list")
        eq(store.chosenServices.map(\.id), ["8", "119", "337", "350"], "the chosen services kept")
        eq(refreshes, 0, "nothing changed on the Home")
    }

    @MainActor
    func testCheckingServicesWritesWhatTheHubReads() {
        let settings = self.settings()
        settings.tmdbAPIKey = "fixture-key"
        let store = makeStore(settings)
        var listed = false
        store.loadServices { _ in listed = true }
        homeWait(10) { listed }
        let canal = store.serviceChoices?.first { $0.id == "381" }
        check(canal != nil, "Canal+ listed in France")
        store.toggle(service: canal!)
        eq(store.chosenServices.last?.id, "381", "a service checked goes last")
        eq(settings.streamingServices.last?.name, "Canal+", "stored with TMDB's name")
        eq(settings.streamingShelves.map(\.id), [8, 119, 337, 350, 381], "the row the Home shows")
        store.toggle(service: StreamingChoice(id: "8", title: "Netflix"))
        eq(settings.streamingServices.map(\.id), [119, 337, 350, 381], "unchecked: gone")
        store.setServices([])
        check(settings.streamingServices.isEmpty, "none: no row")
        eq(refreshes, 3, "the hub told each time")
    }

    /// Canal+ is French: chosen in France, it is dropped in the United States, and Prime Video
    /// becomes the American id (9), as soon as TMDB lists the American services.
    @MainActor
    func testANewCountryAdoptsItsServices() {
        let settings = self.settings()
        settings.streamingServices = [StreamingService(id: 8, name: "Netflix"), StreamingService(id: 119, name: "Amazon Prime Video"),
                                      StreamingService(id: 381, name: "Canal+")]
        let store = makeStore(settings)
        store.select(region: "us")
        eq(store.region, "US", "the country chosen, as a code")
        eq(settings.streamingRegion, "US", "stored")
        eq(refreshes, 1, "the hub told at once")
        eq(store.servicesLoad, .loading, "the American services asked")
        homeWait(10) { store.servicesLoad == .loaded }
        eq(store.chosenServices.map(\.id), ["8", "9"], "Prime Video's American id, no Canal+")
        eq(settings.streamingServices.map(\.id), [8, 9], "stored")
        eq(refreshes, 2, "the hub told again once they followed")
        check(store.serviceChoices?.contains { $0.id == "15" } == true, "Hulu offered")

        store.select(region: "US")
        eq(refreshes, 2, "the same country again: nothing")
        store.select(region: "150")
        eq(store.region, "US", "not a country: nothing")
    }

    /// An answer for a country left meanwhile changes nothing but its completion.
    @MainActor
    func testAnAnswerForAnotherCountryChangesNothing() {
        let store = makeStore(settings())
        var answered = false
        store.loadServices(region: "US") { _ in answered = true }
        homeWait(10) { answered }
        check(store.serviceChoices == nil, "not the country chosen: not offered")
        eq(store.chosenServices.map(\.id), ["8", "119", "337", "350"], "nor adopted")
        eq(refreshes, 0, "the Home unchanged")
    }

    @MainActor
    func testTheKeySavedOrRemovedRebuildsTheHome() {
        let settings = self.settings()
        let store = makeStore(settings)
        var verdict: TMDBKeySettings.Verdict?
        store.saveKey("  \"fixture-key\" ") { verdict = $0 }
        check(store.isCheckingKey, "being checked")
        homeWait(10) { verdict != nil }
        eq(verdict, .accepted, "the recorded answers take any key")
        check(!store.isCheckingKey, "checked")
        eq(settings.tmdbAPIKey, "fixture-key", "stored, cleaned")
        eq(store.keyState, .set, "« Définie »")
        check(refreshes >= 1, "the hub told")
        homeWait(10) { store.servicesLoad == .loaded }
        check(store.serviceChoices?.first?.id == "8", "and the country's services asked (their logos)")

        var again: TMDBKeySettings.Verdict??
        store.checkKeyAgain { again = .some($0) }
        homeWait(10) { again != nil }
        eq(again, .some(.accepted), "checked again")

        let before = refreshes
        store.removeKey()
        check(settings.tmdbAPIKey == nil, "removed")
        eq(store.keyState, .none, "« Aucune »")
        check(store.serviceChoices == nil && store.servicesLoad == .idle, "the services offered forgotten")
        eq(refreshes, before + 1, "the hub told")
    }

    @MainActor
    func testReloadReadsWhatAnotherScreenStored() {
        let settings = self.settings()
        let store = makeStore(settings)
        settings.streamingRegion = "BE"
        settings.tmdbAPIKey = "fixture-key"
        settings.streamingServices = [StreamingService(id: 8, name: "Netflix")]
        store.reload()
        eq(store.region, "BE", "the country")
        eq(store.chosenServices.map(\.id), ["8"], "the services")
        eq(store.keyState, .set, "the key")
    }

    /// The hub given is the one told: an app's own (`init(hub:)`), not `HomeState.shared`.
    @MainActor
    func testTheHubGivenIsTheOneTold() {
        // The hub reads the user's own shelves when it rebuilds its page (`refreshLocal`).
        var reads = 0
        var hooks = HomeLocalHooks()
        hooks.continueWatching = { reads += 1; return [] }
        let feed = HomeFeed(store: HomeStore(directory: sandbox.directory, now: { HomeFixture.now }),
                            transport: HomeTransport(fetch: { _, completion in completion(nil) }),
                            defaults: sandbox.defaults, deviceLanguages: { ["fr-FR"] }, hooks: hooks, now: { HomeFixture.now })
        let hub = HomeState(feed: feed)
        let store = StreamingSettingsStore(hub: hub, settings: settings(), client: recorded)
        homeWait(0.3) { false }
        eq(reads, 0, "nothing asked of the hub yet")
        store.setServices([StreamingChoice(id: "8", title: "Netflix")])
        eq(settings().streamingServices.map(\.id), [8], "stored")
        check(homeWait(10) { reads > 0 }, "the hub given rebuilt its page")
        check(hub !== HomeState.shared, "another hub than the app's")
    }

    func testTheServicesShelfIsListedOnlyWithAKey() {
        let order = [HomeShelfID.hero, HomeShelfID.continueWatching, "popularMovies"]
        eq(StreamingSettingsStore.shelves(order, hasKey: false), order, "no key: no « Services » row to hide")
        eq(StreamingSettingsStore.shelves(order, hasKey: true),
           [HomeShelfID.hero, HomeShelfID.continueWatching, HomeShelfID.services, "popularMovies"],
           "a key: under Continue Watching")
        eq(StreamingSettingsStore.shelves([HomeShelfID.continueWatching, "a"], hasKey: true),
           [HomeShelfID.continueWatching, HomeShelfID.services, "a"], "the Apple TV's list, without the hero")
        eq(StreamingSettingsStore.shelves([HomeShelfID.services, "a"], hasKey: true), [HomeShelfID.services, "a"], "listed once")
        eq(StreamingSettingsStore.shelves([], hasKey: true), [HomeShelfID.services], "an empty list")
    }

    /// What the Settings rows of the iPhone, the iPad and the Mac say.
    @MainActor
    func testWhatTheRowsSay() {
        eq(StreamingSettingsStore.summary(of: []), nil, "no service: the row says « Aucune »")
        eq(StreamingSettingsStore.summary(of: ["Netflix"]), "Netflix", "one")
        eq(StreamingSettingsStore.summary(of: ["Netflix", "Canal+"]), "Netflix, Canal+", "two")
        eq(StreamingSettingsStore.summary(of: ["Netflix", "Canal+", "Disney Plus", "Max"]), "Netflix, Canal+ +2", "the first two, then how many more")
        let store = makeStore(settings())
        store.setServices([StreamingChoice(id: "8", title: "Netflix"), StreamingChoice(id: "337", title: "Disney Plus"),
                           StreamingChoice(id: "381", title: "Canal+")])
        eq(store.servicesSummary, "Netflix, Disney Plus +1", "the chosen ones, in the row's order")

        eq(TMDBKeySettings.State.none.summaryKey, "Settings.TMDBKey.Missing", "no key")
        eq(TMDBKeySettings.State.set.summaryKey, "Settings.TMDBKey.Set", "a key")
        eq(TMDBKeySettings.State.refused.summaryKey, "Settings.TMDBKey.Refused.Short", "a refused key")
        // The keys are in the strings the apps ship (the test bundle has none of its own).
        let english = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PopcornTime/en.lproj/Localizable.strings")
        let strings = NSDictionary(contentsOf: english) as? [String: String] ?? [:]
        for state in [TMDBKeySettings.State.none, .set, .refused] {
            check(strings[state.summaryKey] != nil, "\(state.summaryKey) is in the strings")
        }

        // A verdict in plain words: a save's, a check's (the stored key's fate).
        eq(TMDBKeySettings.Verdict.accepted.messageKey(afterCheck: false), "Settings.TMDBKey.Accepted.HomeOnly",
           "accepted: the Home's row, no grids' filter promised")
        eq(TMDBKeySettings.Verdict.refused.messageKey(afterCheck: false), "Settings.TMDBKey.Refused", "refused: copied whole?")
        eq(TMDBKeySettings.Verdict.unanswered.messageKey(afterCheck: false), "Settings.TMDBKey.Unchecked", "kept, tried later")
        eq(TMDBKeySettings.Verdict.accepted.messageKey(afterCheck: true), "Settings.TMDBKey.Check.Accepted", "checked: accepted")
        eq(TMDBKeySettings.Verdict.refused.messageKey(afterCheck: true), "Settings.TMDBKey.Check.Refused", "checked: refused")
        eq(TMDBKeySettings.Verdict.unanswered.messageKey(afterCheck: true), "Settings.TMDBKey.Check.Unanswered", "checked: no answer")
        for verdict in [TMDBKeySettings.Verdict.accepted, .refused, .unanswered] {
            for afterCheck in [false, true] {
                check(strings[verdict.messageKey(afterCheck: afterCheck)] != nil, "\(verdict.messageKey(afterCheck: afterCheck)) is in the strings")
            }
        }
    }
}
