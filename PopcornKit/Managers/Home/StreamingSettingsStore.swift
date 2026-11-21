import Foundation
import Observation

/// One line of a Settings list of the streaming section: a country ("FR",
/// « France ») or a service (TMDB's provider id as text, « Netflix »).
/// Neutral: the Apple TV maps it to its own row type, iOS and the Mac show
/// it as it is.
public struct StreamingChoice: Identifiable, Hashable, Sendable {
    public let id: String
    /// In the current UI language for a country; TMDB's name for a service.
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// The streaming section of Settings, the same on the Apple TV, the iPhone,
/// the iPad and the Mac: the user's TMDB key (`TMDBKeySettings`), the
/// country of the catalogues, the services TMDB lists there and the ones
/// chosen for the Home's « Services » row.
///
/// Every change is written where the hub reads it (`HomeSettings`), then
/// the hub GIVEN to the store is told to rebuild its page (`refreshHub`):
/// the Apple TV's `HomeState.shared`, iOS's `IOSHome.state`, the Mac's
/// `MacHome.state` — the recorded hubs in DEBUG fixture runs, which a
/// store tied to `HomeState.shared` would leave unchanged.
///
/// Observable, without SwiftUI: a SwiftUI screen reads its properties, the
/// Apple TV's page calls its methods with completions and keeps its own
/// state. Main actor: the defaults it writes are the ones the screens read.
@MainActor
@Observable
public final class StreamingSettingsStore {

    /// Where a list TMDB is asked for stands.
    public enum Load: Equatable, Sendable {
        /// Not asked yet (or asked for another country, another key).
        case idle
        case loading
        case loaded
        /// TMDB did not answer (offline, down, or the key refused).
        case failed
    }

    /// ISO 3166-1 code of the catalogues' country ("FR"): the one chosen,
    /// else the device's region (`HomeSettings.streamingRegion`).
    public private(set) var region: String
    /// The services that have a card in the « Services » row, in the row's
    /// order.
    public private(set) var chosenServices: [StreamingChoice]
    /// The services of `region` as TMDB lists them, the most watched there
    /// first and without the stores (`TMDBStreamingClient.services`); nil
    /// until TMDB answered for this country and key.
    public private(set) var serviceChoices: [StreamingChoice]?
    public private(set) var servicesLoad: Load = .idle
    /// The countries TMDB has catalogues for (else every country the system
    /// knows), by name; nil until asked.
    public private(set) var regionChoices: [StreamingChoice]?
    public private(set) var regionsLoad: Load = .idle
    /// What the key row says.
    public private(set) var keyState: TMDBKeySettings.State
    /// A key is being checked with TMDB (saving, or « Vérifier à nouveau »).
    public private(set) var isCheckingKey = false

    @ObservationIgnored public let keys: TMDBKeySettings
    @ObservationIgnored private let settings: HomeSettings
    @ObservationIgnored private let client: TMDBStreamingClient
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let refreshHub: @MainActor () -> Void
    /// The services TMDB listed last (their logos), by id: a service checked
    /// is stored with TMDB's name and logo.
    @ObservationIgnored private var knownServices: [Int: StreamingService] = [:]
    /// The country `serviceChoices` / `servicesLoad` are for.
    @ObservationIgnored private var servicesRegion: String?

    /// - Parameter settings: where the choices are kept (the app's standard
    ///   defaults; a scratch suite in tests).
    /// - Parameter client: TMDB (`.shared`: recorded answers in a DEBUG
    ///   fixture run).
    /// - Parameter locale: the language of the countries' names.
    /// - Parameter refreshHub: rebuilds the Home's page after a change (no
    ///   request: `HomeState.refreshLocal`).
    public init(settings: HomeSettings = HomeSettings(), client: TMDBStreamingClient = .shared,
                locale: Locale = .current, refreshHub: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.client = client
        self.locale = locale
        self.refreshHub = refreshHub
        self.keys = TMDBKeySettings(settings: settings, client: client)
        self.region = settings.streamingRegion
        self.chosenServices = settings.streamingServices.map(StreamingChoice.init)
        self.keyState = TMDBKeySettings(settings: settings, client: client).state
    }

    /// The store of an app's hub: the changes rebuild `hub`'s page.
    public convenience init(hub: HomeState, settings: HomeSettings = HomeSettings(), client: TMDBStreamingClient = .shared) {
        self.init(settings: settings, client: client, refreshHub: { [weak hub] in hub?.refreshLocal() })
    }

    // MARK: Reading

    public var hasKey: Bool { keys.hasKey }

    /// Reads the stored values again (a screen appearing: another screen or
    /// a launch argument may have changed them).
    public func reload() {
        region = settings.streamingRegion
        chosenServices = settings.streamingServices.map(StreamingChoice.init)
        keyState = keys.state
        if servicesRegion != region { forgetServiceChoices() }
    }

    /// "France" for "FR", in `locale`'s language; the code itself when the
    /// system has no name for it.
    public func regionName(_ code: String) -> String {
        return locale.localizedString(forRegionCode: code) ?? code
    }

    /// The services a list offers: the chosen ones first (a country's list
    /// may lack one), then the country's others.
    public var serviceOptions: [StreamingChoice] {
        let ids = Set(chosenServices.map(\.id))
        return chosenServices + (serviceChoices ?? []).filter { !ids.contains($0.id) }
    }

    /// The countries a list offers: TMDB's, with the current one first when
    /// TMDB's list lacks it.
    public var regionOptions: [StreamingChoice] {
        let all = regionChoices ?? []
        return all.contains { $0.id == region } ? all : [StreamingChoice(id: region, title: regionName(region))] + all
    }

    /// The fixed shelves a Settings list of the Home's shelves offers:
    /// `ids` in the Home's order, with the « Services » row after the first
    /// shelf that is not the hero (under Continue Watching) once there is a
    /// key — without one the row does not exist, and nothing to hide.
    nonisolated public static func shelves(_ ids: [String], hasKey: Bool) -> [String] {
        guard hasKey, !ids.contains(HomeShelfID.services) else { return ids }
        var shelves = ids
        let first = shelves.firstIndex { $0 != HomeShelfID.hero } ?? shelves.endIndex
        shelves.insert(HomeShelfID.services, at: min(first + 1, shelves.endIndex))
        return shelves
    }

    // MARK: Key

    /// Checks the key in `text` with TMDB, keeps it unless TMDB refused it
    /// (`TMDBKeySettings.save`). Kept: the hub rebuilds its page and the
    /// country's services are asked (their logos, for the row).
    /// `completion` runs on the main queue.
    public func saveKey(_ text: String, completion: @escaping (TMDBKeySettings.Verdict) -> Void) {
        isCheckingKey = true
        keys.save(text) { [weak self] verdict in
            guard let self else { return completion(verdict) }
            self.isCheckingKey = false
            if verdict != .refused {
                // Another key: the services offered are asked again.
                self.forgetServiceChoices()
                self.refreshHub()
                self.loadServices()
            }
            self.keyState = self.keys.state
            completion(verdict)
        }
    }

    /// Removes the key: the « Services » row and the streaming shelves go.
    public func removeKey() {
        keys.remove()
        forgetServiceChoices()
        keyState = keys.state
        refreshHub()
    }

    /// Asks TMDB again about the stored key: `keyState` then says
    /// « Refusée » or « Définie ». nil: no key stored.
    public func checkKeyAgain(completion: @escaping (TMDBKeySettings.Verdict?) -> Void) {
        isCheckingKey = true
        keys.checkAgain { [weak self] verdict in
            guard let self else { return completion(verdict) }
            self.isCheckingKey = false
            self.keyState = self.keys.state
            // Taken again: the lists the Home could not read are asked again.
            if verdict == .accepted { self.refreshHub() }
            completion(verdict)
        }
    }

    // MARK: Country and services

    /// Another country: the hub shows its catalogues, and the chosen
    /// services follow it as soon as TMDB lists its services
    /// (`HomeSettings.adoptServices`), list open or not.
    public func select(region code: String) {
        guard let code = HomeSettings.regionCode(code), code != settings.streamingRegion else { return }
        settings.streamingRegion = code
        region = settings.streamingRegion
        // Read in the new country's ids (Prime Video: 119 or 9) until TMDB lists its services.
        chosenServices = settings.streamingServices.map(StreamingChoice.init)
        forgetServiceChoices()
        refreshHub()
        loadServices()
    }

    /// The services of the row, in this order.
    public func setServices(_ choices: [StreamingChoice]) {
        let stored = Dictionary(settings.streamingServices.map { ($0.id, $0) }) { first, _ in first }
        settings.streamingServices = choices.compactMap { choice in
            guard let id = Int(choice.id) else { return nil }
            return knownServices[id] ?? stored[id] ?? StreamingService(id: id, name: choice.title)
        }
        chosenServices = settings.streamingServices.map(StreamingChoice.init)
        refreshHub()
    }

    /// Checks or unchecks a service: a checked one goes last in the row.
    public func toggle(service choice: StreamingChoice) {
        var choices = chosenServices
        if let index = choices.firstIndex(where: { $0.id == choice.id }) {
            choices.remove(at: index)
        } else {
            choices.append(choice)
        }
        setServices(choices)
    }

    /// Asks TMDB the services of `region` (the current country when nil),
    /// and matches the chosen ones to them (TMDB's logos and names, the
    /// country's id of a service — Amazon Prime Video is 119 in France, 9 in
    /// the United States —, and none the country lacks). Only for the
    /// country chosen now: an answer for a country left meanwhile changes
    /// nothing but goes to `completion` (main queue; nil: no answer).
    public func loadServices(region asked: String? = nil, completion: (([StreamingChoice]?) -> Void)? = nil) {
        let region = asked ?? self.region
        if region == self.region {
            servicesRegion = region
            servicesLoad = .loading
        }
        client.services(region: region) { services in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let current = region == self.region && self.servicesRegion == region
                guard let services else {
                    if current { self.servicesLoad = .failed }
                    completion?(nil)
                    return
                }
                for service in services { self.knownServices[service.id] = service }
                if self.settings.adoptServices(services, listedFor: region) {
                    self.chosenServices = self.settings.streamingServices.map(StreamingChoice.init)
                    self.refreshHub()
                }
                let choices = services.map(StreamingChoice.init)
                if current {
                    self.serviceChoices = choices
                    self.servicesLoad = .loaded
                }
                completion?(choices)
            }
        }
    }

    /// Asks TMDB its countries (once: they do not change during a run);
    /// without an answer, every country the system knows. By name.
    public func loadRegions(completion: (([StreamingChoice]) -> Void)? = nil) {
        if let regionChoices, regionsLoad == .loaded {
            completion?(regionChoices)
            return
        }
        regionsLoad = .loading
        let locale = self.locale
        client.regions { codes in
            let choices = StreamingSettingsStore.regionChoices(codes, locale: locale)
            DispatchQueue.main.async { [weak self] in
                if let self {
                    self.regionChoices = choices
                    self.regionsLoad = .loaded
                }
                completion?(choices)
            }
        }
    }

    /// TMDB's countries (`codes`), else every country the system knows:
    /// two-letter codes only, each once, by name in `locale`'s language.
    nonisolated static func regionChoices(_ codes: [String]?, locale: Locale) -> [StreamingChoice] {
        let all = (codes?.isEmpty == false ? codes! : Locale.Region.isoRegions.map(\.identifier)).filter { $0.count == 2 }
        return Set(all).map { StreamingChoice(id: $0, title: locale.localizedString(forRegionCode: $0) ?? $0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func forgetServiceChoices() {
        serviceChoices = nil
        servicesLoad = .idle
        servicesRegion = nil
    }
}

extension StreamingChoice {
    /// A service as a line: its TMDB id as text, its name.
    public init(_ service: StreamingService) {
        self.init(id: String(service.id), title: service.name)
    }
}
