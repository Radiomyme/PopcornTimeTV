import Foundation

/// A thread-safe dictionary whose entries expire and whose size is bounded:
/// past `capacity`, the entry read or written the longest ago goes.
///
/// `fresh` answers only entries younger than `lifetime`; `any` also answers
/// an expired one with its age (what to show when a refresh fails). The clock
/// is injected, so the rules run in tests without waiting.
final class BoundedTTLCache<Value> {

    private struct Entry {
        let value: Value
        let stored: Date
        var used: UInt64
    }

    let lifetime: TimeInterval
    let capacity: Int
    private let now: () -> Date
    private let lock = NSLock()
    private var storage: [String: Entry] = [:]
    private var clock: UInt64 = 0

    init(lifetime: TimeInterval, capacity: Int, now: @escaping () -> Date = Date.init) {
        self.lifetime = lifetime
        self.capacity = max(1, capacity)
        self.now = now
    }

    /// The value stored less than `lifetime` ago, nil otherwise.
    func fresh(_ key: String) -> Value? {
        guard let hit = any(key), hit.age < lifetime else { return nil }
        return hit.value
    }

    /// The value stored under `key`, however old, with its age.
    func any(_ key: String) -> (value: Value, age: TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = storage[key] else { return nil }
        clock += 1
        entry.used = clock
        storage[key] = entry
        return (entry.value, max(0, now().timeIntervalSince(entry.stored)))
    }

    func set(_ value: Value, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        storage[key] = Entry(value: value, stored: now(), used: clock)
        while storage.count > capacity, let oldest = storage.min(by: { $0.value.used < $1.value.used }) {
            storage[oldest.key] = nil
        }
    }

    func remove(_ key: String) {
        lock.lock()
        storage[key] = nil
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}
