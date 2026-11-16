

import Foundation
import Network

/// The current network path, watched from launch so that a Play tap knows at
/// once whether the connection is one the system calls expensive (cellular
/// data, a personal hotspot): `CellularStreamingPolicy` asks before a stream
/// starts on it.
final class NetworkPathObserver: @unchecked Sendable {
    static let shared = NetworkPathObserver()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false
    private var started = false

    private init() {}

    /// Idempotent.
    func start() {
        lock.lock()
        let begin = !started
        started = true
        lock.unlock()
        guard begin else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.expensive = path.isExpensive
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "popcorntime.network-path", qos: .utility))
    }

    /// Cellular data or a personal hotspot. False until the first path is
    /// known (a few milliseconds after `start`).
    var isExpensive: Bool {
        #if DEBUG
        if IOSDebugHooks.forcesExpensiveNetwork { return true }
        #endif
        lock.lock()
        defer { lock.unlock() }
        return expensive
    }
}
