import Foundation

/// GETs / POSTs to optional catalog sources (The Pirate Bay's apibay, the
/// Knaben meta-index, Cinemeta, TVMaze) that must never block or slow the app:
///
/// - short timeouts (a DNS-blocked or hijacked host fails fast: some French
///   ISPs block The Pirate Bay's domains);
/// - an ordered, overridable host list, tried in turn;
/// - a host that just failed to answer is skipped for a while (`backoff`
///   when blocked: DNS, refused connection, TLS; at most a minute after a
///   timeout, a slow moment), so every later call fails instantly instead of
///   waiting out the timeout again;
/// - small answers cached in memory for a few minutes.
///
/// Completions run on an arbitrary background queue.
final class IndexFetcher {

    /// What one request came to.
    enum Outcome {
        /// A host answered 2xx.
        case data(Data)
        /// A host answered, with this HTTP status (404: not there).
        case status(Int)
        /// No host answered (DNS, connection, timeout, TLS, every host backing off).
        case failed
    }

    /// How long a host that timed out is skipped (at most its `backoff`).
    static let timeoutBackoff: TimeInterval = 60

    let name: String
    private let session: URLSession
    private let cacheLifetime: TimeInterval
    private let backoff: TimeInterval
    private let lock = NSLock()
    private var failedUntil: [String: Date] = [:]
    private var cache: [String: (date: Date, data: Data)] = [:]

    init(name: String, timeout: TimeInterval = 5, cacheLifetime: TimeInterval = 600, backoff: TimeInterval = 300) {
        self.name = name
        self.cacheLifetime = cacheLifetime
        self.backoff = backoff
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 11_0) AppleWebKit/605.1.15 PopcornTime/4.2",
            "Accept": "application/json",
        ]
        session = URLSession(configuration: configuration)
    }

    /// GET (or POST `body` as JSON) `path` on the first host that answers
    /// 2xx, nil when none does. `path` starts with "/".
    func data(hosts: [String], path: String, body: Data? = nil, completion: @escaping (Data?) -> Void) {
        fetch(hosts: hosts, path: path, body: body) { outcome in
            if case .data(let data) = outcome { return completion(data) }
            completion(nil)
        }
    }

    /// Like `data(hosts:path:body:completion:)`, but telling "a host answered
    /// it isn't there" (an HTTP status) from "no host answered" (`.failed`).
    func fetch(hosts: [String], path: String, body: Data? = nil, completion: @escaping (Outcome) -> Void) {
        let cacheKey = path + (body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        let now = Date()
        lock.lock()
        if cacheLifetime > 0, let hit = cache[cacheKey], now.timeIntervalSince(hit.date) < cacheLifetime {
            lock.unlock()
            return completion(.data(hit.data))
        }
        let usable = hosts.filter { (failedUntil[$0] ?? .distantPast) <= now }
        lock.unlock()

        var remaining = usable
        var answeredStatus: Int?
        func next() {
            guard !remaining.isEmpty else {
                if usable.isEmpty { print("[\(name)] \(path.prefix(80)): every host backing off") }
                return completion(answeredStatus.map { .status($0) } ?? .failed)
            }
            let host = remaining.removeFirst()
            guard let url = URL(string: host + path) else { return next() }
            var request = URLRequest(url: url)
            if let body = body {
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let started = Date()
            session.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return completion(.failed) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if let data = data, error == nil, (200..<300).contains(status) {
                    // Nothing kept when answers aren't cached (`cacheLifetime`
                    // 0): the caller keeps what it needs (Cinemeta metas are large).
                    if self.cacheLifetime > 0 {
                        self.lock.lock()
                        self.cache[cacheKey] = (Date(), data)
                        if self.cache.count > 200 { self.cache.removeAll() }
                        self.lock.unlock()
                    }
                    completion(.data(data))
                    return
                }
                let code = (error as NSError?)?.code ?? 0
                print("[\(self.name)] \(host)\(path.prefix(80)) FAILED status=\(status) code=\(code) after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                if status > 0 { answeredStatus = status }
                // Unreachable (DNS-blocked, down, black-holed): skip it for a
                // while. An HTTP error is the host answering, and an offline
                // device isn't the host's fault: try again next time.
                let blocked: Set<Int> = [
                    NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
                    NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                    NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateHasBadDate,
                ]
                let skip: TimeInterval? = blocked.contains(code) ? self.backoff
                    : code == NSURLErrorTimedOut ? min(self.backoff, IndexFetcher.timeoutBackoff) : nil
                if let skip = skip {
                    self.lock.lock()
                    self.failedUntil[host] = Date().addingTimeInterval(skip)
                    self.lock.unlock()
                }
                next()
            }.resume()
        }
        next()
    }

    /// Query-string encoding of a value ("interstellar 2014" →
    /// "interstellar%202014").
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
