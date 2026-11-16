import Foundation

/// Why a mirror did not give the answer.
enum MirrorFailure: Equatable {
    /// DNS, refused connection, TLS: blocked or gone.
    case unreachable
    /// No answer in time.
    case timedOut
    /// The mirror answered an HTTP error.
    case http(Int)
    /// The mirror answered 2xx with something that is not the API's JSON (a
    /// parked domain's page, a captive portal).
    case invalid
    /// Not the mirror's fault: the device is offline, the connection dropped.
    case other
}

/// Which mirror of an API to ask first, and which to leave for last.
///
/// - The mirror that last gave a VALID answer is asked first ("sticky"), for
///   `stickyLifetime`: then the list's own order applies again, so a
///   secondary mirror never stays preferred for ever. It is remembered in
///   UserDefaults: a relaunch skips the dead mirrors at once. A sticky host
///   stored by an older version carries no date and is not trusted (it was
///   recorded on any 2xx answer, an HTML page included).
/// - A mirror that just failed goes to the end of the order for a while
///   (`backoff(after:)`); it is still asked when every other one fails.
///
/// The clock and the defaults are injected (tests).
final class MirrorHealth {

    static var stickyLifetime: TimeInterval = 24 * 3600

    /// How long a mirror is left for last after `failure`, nil for a failure
    /// that says nothing about the mirror.
    static func backoff(after failure: MirrorFailure) -> TimeInterval? {
        switch failure {
        case .unreachable: return 300
        case .invalid: return 600
        case .timedOut, .http: return 60
        case .other: return nil
        }
    }

    let name: String
    private let stickyKey: String
    private let defaults: UserDefaults
    private let now: () -> Date
    private let lock = NSLock()
    private var failedUntil: [String: Date] = [:]

    init(name: String, stickyKey: String, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.name = name
        self.stickyKey = stickyKey
        self.defaults = defaults
        self.now = now
    }

    private var dateKey: String { stickyKey + ".date" }

    /// The mirror that last gave a valid answer, while that is recent enough.
    var sticky: String? {
        guard let host = defaults.string(forKey: stickyKey),
              let stored = defaults.object(forKey: dateKey) as? Double else { return nil }
        let age = now().timeIntervalSince1970 - stored
        return age >= 0 && age < MirrorHealth.stickyLifetime ? host : nil
    }

    /// `mirrors` in the order to ask them: the sticky one, the others in the
    /// list's order, then those backing off.
    func ordered(_ mirrors: [String]) -> [String] {
        var list = mirrors
        if let sticky = sticky, let index = list.firstIndex(of: sticky) {
            list.remove(at: index)
            list.insert(sticky, at: 0)
        }
        let date = now()
        lock.lock()
        let until = failedUntil
        lock.unlock()
        let usable = list.filter { (until[$0] ?? .distantPast) <= date }
        return usable + list.filter { (until[$0] ?? .distantPast) > date }
    }

    /// `host` gave a valid answer.
    func succeeded(_ host: String) {
        lock.lock()
        failedUntil[host] = nil
        lock.unlock()
        let stamp = now().timeIntervalSince1970
        let known = defaults.string(forKey: stickyKey) == host ? defaults.object(forKey: dateKey) as? Double : nil
        // Not rewritten on every request: once an hour keeps it alive.
        if let known = known, stamp - known < 3600, stamp >= known { return }
        defaults.set(host, forKey: stickyKey)
        defaults.set(stamp, forKey: dateKey)
    }

    /// `host` did not give the answer.
    func failed(_ host: String, _ failure: MirrorFailure) {
        guard let pause = MirrorHealth.backoff(after: failure) else { return }
        lock.lock()
        failedUntil[host] = now().addingTimeInterval(pause)
        lock.unlock()
        if defaults.string(forKey: stickyKey) == host {
            defaults.removeObject(forKey: stickyKey)
            defaults.removeObject(forKey: dateKey)
        }
    }
}

/// One request sent to the mirrors of an API, as a staggered race: the first
/// mirror is asked; when it has not answered after `stagger` seconds, or as
/// soon as it fails, the next one is asked too, and so on. The first VALID
/// answer wins and the other requests are cancelled; an answer that is not
/// the API's (`validate`) counts as a failure of that mirror. After
/// `deadline` seconds without a valid answer the race is lost.
///
/// (The mirrors used to be asked one after the other, each with its 15 s
/// timeout: six black-holed hosts held a grid for 90 s, and any 2xx answer,
/// an HTML page included, made its host the preferred one.)
///
/// Everything runs on the queue `schedule` and `transport` call back on (the
/// main queue in the app); both are injected, so the race runs in tests.
enum MirrorRace {

    typealias Cancel = () -> Void

    enum Answer {
        case data(Data)
        case failure(MirrorFailure, NSError?)
    }

    /// Starts the request to `host`, calls back once, returns how to cancel it.
    typealias Transport = (_ host: String, _ completion: @escaping (Answer) -> Void) -> Cancel
    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    static let mainQueue: Scheduler = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Seconds a mirror has to answer before the next one is asked as well.
    static var stagger: TimeInterval = 2
    /// Longest wait for a valid answer from any mirror.
    static var deadline: TimeInterval = 10

    static let errorDomain = "popcornkit.mirrors"

    /// What the grids show when no mirror gave a valid answer and nothing
    /// more precise is known (an existing text: no new translation).
    private static func error(code: Int) -> NSError {
        return NSError(domain: errorDomain, code: code,
                       userInfo: [NSLocalizedDescriptionKey: "Please check your internet connection and try again.".localized])
    }

    static func run(hosts: [String],
                    health: MirrorHealth?,
                    stagger: TimeInterval = MirrorRace.stagger,
                    deadline: TimeInterval = MirrorRace.deadline,
                    schedule: @escaping Scheduler = MirrorRace.mainQueue,
                    validate: @escaping (Data) -> Bool,
                    transport: @escaping Transport,
                    completion: @escaping (Data?, NSError?) -> Void) {
        let race = Race(hosts: hosts, health: health, stagger: stagger, schedule: schedule,
                        validate: validate, transport: transport, completion: completion)
        schedule(deadline) { race.timeOut() }
        race.startNext()
    }

    /// The state of one race. Kept alive by its own closures until it ends.
    private final class Race {
        private var remaining: [String]
        private var running: [String: Cancel] = [:]
        private var started = 0
        private var finished = false
        private var lastError: NSError?
        private let health: MirrorHealth?
        private let stagger: TimeInterval
        private let schedule: Scheduler
        private let validate: (Data) -> Bool
        private let transport: Transport
        private let completion: (Data?, NSError?) -> Void

        init(hosts: [String], health: MirrorHealth?, stagger: TimeInterval, schedule: @escaping Scheduler,
             validate: @escaping (Data) -> Bool, transport: @escaping Transport,
             completion: @escaping (Data?, NSError?) -> Void) {
            self.remaining = hosts
            self.health = health
            self.stagger = stagger
            self.schedule = schedule
            self.validate = validate
            self.transport = transport
            self.completion = completion
        }

        func startNext() {
            guard !finished else { return }
            guard !remaining.isEmpty else {
                if running.isEmpty {
                    finish(nil, lastError ?? MirrorRace.error(code: -1))
                }
                return
            }
            let host = remaining.removeFirst()
            started += 1
            let position = started
            var answered = false
            let cancel = transport(host) { [self] answer in
                guard !answered else { return }
                answered = true
                running[host] = nil
                guard !finished else { return }
                switch answer {
                case .data(let data) where validate(data):
                    health?.succeeded(host)
                    finish(data, nil)
                case .data:
                    print("[Mirrors] \(health?.name ?? "") \(host): answered something else than the API (ignored)")
                    health?.failed(host, .invalid)
                    lastError = MirrorRace.error(code: -2)
                    startNext()
                case .failure(let failure, let error):
                    health?.failed(host, failure)
                    lastError = error ?? lastError
                    startNext()
                }
            }
            // A transport may answer before it returns (tests, a cached answer).
            if !answered { running[host] = cancel }
            schedule(stagger) { [self] in
                // Still waiting for this mirror, and no other was asked since.
                if !finished, started == position, running[host] != nil { startNext() }
            }
        }

        func timeOut() {
            guard !finished else { return }
            for host in running.keys { health?.failed(host, .timedOut) }
            finish(nil, lastError ?? MirrorRace.error(code: NSURLErrorTimedOut))
        }

        private func finish(_ data: Data?, _ error: NSError?) {
            finished = true
            let cancels = Array(running.values)
            running.removeAll()
            cancels.forEach { $0() }
            completion(data, error)
        }
    }
}
