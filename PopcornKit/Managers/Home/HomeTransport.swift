import Foundation

/// How the hub reaches the network: one closure, injected. The loader
/// (`HomeFeed`) only knows "GET this request, tell me the body or nil"; the
/// tests replay recorded answers through it, the app uses `live`.
public struct HomeTransport: Sendable {

    public typealias Completion = @Sendable (Data?) -> Void

    /// GETs `request` and calls back once, on any queue, with the body of a
    /// 2xx answer, or nil when no host gave one.
    public var fetch: @Sendable (_ request: HomeRequest, _ completion: @escaping Completion) -> Void

    /// Forgets what the transport remembers of the hosts that did not
    /// answer. The hub calls it when the user asks again (a forced refresh:
    /// Retry, pull to refresh): every host is then tried.
    public var reset: @Sendable () -> Void

    public init(fetch: @escaping @Sendable (_ request: HomeRequest, _ completion: @escaping Completion) -> Void,
                reset: @escaping @Sendable () -> Void = {}) {
        self.fetch = fetch
        self.reset = reset
    }

    /// The real hosts, with short timeouts and a memory of the hosts that
    /// do not answer (`HomeHTTP`).
    public static let live = HomeTransport(fetch: { request, completion in
        HomeHTTP.shared.get(request, completion: completion)
    }, reset: {
        HomeHTTP.shared.forgetFailures()
    })
}

/// The hosts that did not answer, and how long each is put aside: what
/// makes a dead mirror cost its timeout once, not at every request.
///
/// The failure of a host may be the device's (a router that lost its WAN, a
/// VPN reconnecting, a captive portal), and three of the four services have
/// one host: putting it aside must not shut the service for minutes.
/// - A host that could not be reached (DNS, connection, TLS) fails at once:
///   it goes behind its mirrors for `unreachableBackoff`, and is still
///   tried, last, when none of them answers or there is none.
/// - A host that kept silent (a timeout, a page that is not JSON) costs the
///   whole timeout again: it is not tried at all for `silentBackoff`.
/// - `forget()` (the user asks again) clears both.
struct HomeHostMemory: Sendable {

    enum Failure: Sendable {
        /// DNS, connection refused, TLS: known within milliseconds.
        case unreachable
        /// Timed out, or answered something else than JSON.
        case silent
    }

    var unreachableBackoff: TimeInterval = 300
    var silentBackoff: TimeInterval = 60

    private var aside: [String: (until: Date, failure: Failure)] = [:]

    init() {}

    /// `hosts` in the order to try them at `now`: the ones not put aside,
    /// then the unreachable ones (asking them again is free). Not the
    /// silent ones.
    func hostsToTry(_ hosts: [String], now: Date) -> [String] {
        func isAside(_ host: String) -> Bool { (aside[host]?.until ?? .distantPast) > now }
        return hosts.filter { !isAside($0) } + hosts.filter { isAside($0) && aside[$0]?.failure == .unreachable }
    }

    mutating func failed(_ host: String, _ failure: Failure, now: Date) {
        aside[host] = (now.addingTimeInterval(failure == .unreachable ? unreachableBackoff : silentBackoff), failure)
    }

    mutating func answered(_ host: String) {
        aside[host] = nil
    }

    mutating func forget() {
        aside.removeAll()
    }
}

/// GETs for the hub, built like `IndexFetcher`: every source is optional
/// and must never slow the page down.
///
/// - short timeouts (a DNS-blocked or black-holed host fails fast);
/// - the hosts of a service tried in turn (YTS has mirrors);
/// - a host that did not answer is put aside for a while (`HomeHostMemory`),
///   so the next requests do not wait out the timeout again;
/// - a 2xx answer that is not JSON (a parked mirror's HTML page) is a
///   failure of that host, not an answer.
///
/// Nothing is cached here: the hub keeps the parsed lists (`HomeStore`).
/// One session for the four services (connections are reused).
final class HomeHTTP: @unchecked Sendable {

    static let shared = HomeHTTP()

    /// Seconds without a byte before a request is given up.
    static let timeout: TimeInterval = 8

    /// The hosts of a service, in the order to try them. The same lists as
    /// the rest of the app, read at every request (they are overridable).
    var hosts: (HomeRequest.Host) -> [String] = { host in
        switch host {
        case .cinemeta: return CinemetaClient.hosts
        case .yts: return YTSEZTVProvider.ytsMirrors
        case .tvmaze: return ["https://api.tvmaze.com"]
        // Turned off in the app: the shelves made of it are simply absent.
        case .apibay: return PirateBayClient.isEnabled ? PirateBayClient.hosts : []
        }
    }

    private let session: URLSession
    private let lock = NSLock()
    private var memory = HomeHostMemory()

    /// - Parameter protocolClasses: what answers instead of the network (tests).
    init(protocolClasses: [AnyClass] = []) {
        let configuration = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = HomeHTTP.timeout
        configuration.timeoutIntervalForResource = HomeHTTP.timeout * 2
        // YTS answers 403 to URLSession's default user agent.
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 11_0) AppleWebKit/605.1.15 PopcornTime/4.2",
            "Accept": "application/json",
        ]
        session = URLSession(configuration: configuration)
    }

    func get(_ request: HomeRequest, completion: @escaping HomeTransport.Completion) {
        lock.lock()
        let usable = memory.hostsToTry(hosts(request.host), now: Date())
        lock.unlock()
        attempt(usable[...], path: request.path, completion: completion)
    }

    /// Every host is tried again at the next request.
    func forgetFailures() {
        lock.lock()
        memory.forget()
        lock.unlock()
    }

    private func attempt(_ hosts: ArraySlice<String>, path: String, completion: @escaping HomeTransport.Completion) {
        guard let host = hosts.first else { return completion(nil) }
        guard let url = URL(string: host + path) else {
            return attempt(hosts.dropFirst(), path: path, completion: completion)
        }
        session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return completion(nil) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let data = data, error == nil, (200..<300).contains(status), HomeHTTP.looksLikeJSON(data) {
                self.lock.lock()
                self.memory.answered(host)
                self.lock.unlock()
                return completion(data)
            }
            let code = (error as NSError?)?.code ?? 0
            print("[Home] \(host)\(path.prefix(70)) FAILED status=\(status) code=\(code)")
            // An HTTP error is the host answering, and an offline device is
            // not the host's fault: those are tried again next time.
            let unreachable: Set<Int> = [
                NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
                NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateHasBadDate,
            ]
            let notJSON = error == nil && (200..<300).contains(status)
            let failure: HomeHostMemory.Failure? = unreachable.contains(code) ? .unreachable
                : code == NSURLErrorTimedOut || notJSON ? .silent : nil
            if let failure = failure {
                self.lock.lock()
                self.memory.failed(host, failure, now: Date())
                self.lock.unlock()
            }
            self.attempt(hosts.dropFirst(), path: path, completion: completion)
        }.resume()
    }

    /// The body starts like a JSON object or array.
    static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }) else { return false }
        return first == 0x7B || first == 0x5B
    }
}
