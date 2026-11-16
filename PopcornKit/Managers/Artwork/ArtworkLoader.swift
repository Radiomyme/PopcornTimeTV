//
//  ArtworkLoader.swift
//  PopcornKit
//
//  Loads one artwork from the first of its sources that gives a picture
//  (`ArtworkURL.sources`). Inside a source the addresses are tried one after
//  the other: the sized variant, then the address as given. The next source
//  starts when the previous one has failed — or has been silent for
//  `hedgeDelay`: the image proxy does not refuse a cover it cannot fetch, it
//  says nothing until the request times out, and a poster must not stay grey
//  that long when another address has it. The first picture wins and the
//  other requests are cancelled.
//
//  Pure of any session: the fetch, the decoder and the timer are arguments
//  (the tests pass their own).
//

import Foundation

public struct ArtworkLoader: Sendable {

    public typealias Fetch = @Sendable (URL) async throws -> Data
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    public var fetch: Fetch
    public var sleep: Sleep
    /// How long a source may stay silent before the next one is started too.
    public var hedgeDelay: TimeInterval

    public init(fetch: @escaping Fetch,
                sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
                hedgeDelay: TimeInterval = 2) {
        self.fetch = fetch
        self.sleep = sleep
        self.hedgeDelay = hedgeDelay
    }

    public struct Result<Output: Sendable>: Sendable {
        public let output: Output
        /// The address the picture came from.
        public let url: URL
        /// Its source (an index in `sources`).
        public let source: Int
        /// The sources started before the winner that had given nothing
        /// when it won: failed, or still silent.
        public let passed: [Int]
        /// Those of `passed` that had failed (the others were still silent).
        public let failed: [Int]
    }

    private enum Event<Output: Sendable>: Sendable {
        case picture(Int, Output, URL)
        case failed(Int)
        case silent(Int)
    }

    /// The first picture of `sources`, nil when none gives one (or when the
    /// task is cancelled). `decode` says whether an answer is a picture: an
    /// error page served with a 200 is a failure like another.
    public func load<Output: Sendable>(_ sources: [[URL]],
                                       decode: @escaping @Sendable (Data, URL) -> Output?) async -> Result<Output>? {
        let sources = sources.filter { !$0.isEmpty }
        guard !sources.isEmpty else { return nil }
        let fetch = self.fetch, sleep = self.sleep, hedgeDelay = self.hedgeDelay

        return await withTaskGroup(of: Event<Output>.self) { group -> Result<Output>? in
            var started = 0
            var pending = Set<Int>()
            var failed: [Int] = []

            func startNext() {
                let index = started
                started += 1
                pending.insert(index)
                group.addTask {
                    for url in sources[index] {
                        if Task.isCancelled { break }
                        if let data = try? await fetch(url), !Task.isCancelled, let output = decode(data, url) {
                            return .picture(index, output, url)
                        }
                    }
                    return .failed(index)
                }
                if started < sources.count {
                    group.addTask {
                        try? await sleep(hedgeDelay)
                        return .silent(index)
                    }
                }
            }

            startNext()
            for await event in group {
                switch event {
                case .picture(let index, let output, let url):
                    group.cancelAll()
                    pending.remove(index)
                    return Result(output: output, url: url, source: index,
                                  passed: (failed + pending.filter { $0 < index }).sorted(), failed: failed.sorted())
                case .failed(let index):
                    pending.remove(index)
                    failed.append(index)
                    if Task.isCancelled { group.cancelAll(); return nil }
                    if started < sources.count {
                        startNext()
                    } else if pending.isEmpty {
                        group.cancelAll()
                        return nil
                    }
                case .silent(let index):
                    // Only the newest source's timer starts the next one: an
                    // older timer firing late must not start two at once.
                    if index == started - 1, started < sources.count, !Task.isCancelled { startNext() }
                }
            }
            return nil
        }
    }
}

/// Which hosts are answering. A route that failed three times out of its
/// last six loads is put aside for a minute: its addresses are then tried
/// after the others instead of first, so a host that is down — or the proxy
/// in front of covers it no longer gets — costs a few waits, not one per
/// poster.
struct ArtworkRoutes {

    var failuresToBench = 3
    var window = 6
    var benchDuration: TimeInterval = 60

    /// The last outcomes of each route (true: it gave its picture).
    private var outcomes: [String: [Bool]] = [:]
    private var benchedUntil: [String: Date] = [:]

    func isBenched(_ route: String, now: Date) -> Bool {
        guard let until = benchedUntil[route] else { return false }
        return now < until
    }

    mutating func succeeded(_ route: String, now: Date) {
        record(true, route, now: now)
    }

    mutating func failed(_ route: String, now: Date) {
        record(false, route, now: now)
    }

    private mutating func record(_ success: Bool, _ route: String, now: Date) {
        var last = outcomes[route] ?? []
        last.append(success)
        if last.count > window { last.removeFirst(last.count - window) }
        outcomes[route] = last
        if last.filter({ !$0 }).count >= failuresToBench {
            // A success does not lift the bench of a route that still fails
            // half of the time, nor puts it back once it has run out (it
            // records no failure then: only a failure starts or extends it).
            if !success { benchedUntil[route] = now.addingTimeInterval(benchDuration) }
        } else {
            benchedUntil[route] = nil
        }
    }

    /// Where a picture came from last time, when not from the first address
    /// tried.
    struct Detour: Equatable {
        /// The source that had it, named by its address as given (its last).
        let origin: URL
        /// That source's sized variant had failed: the address as given
        /// first.
        let skipsVariant: Bool
    }

    /// `sources` with the ones whose first address is on a benched route
    /// moved to the end (the order is otherwise kept), and the one that had
    /// the picture last time — `detour` — first. `isAtHand` says that an
    /// address needs no network (it is in the disk cache): its source is not
    /// moved, whatever its route's state.
    func ordered(_ sources: [[URL]], detour: Detour? = nil, now: Date, isAtHand: (URL) -> Bool = { _ in false }) -> [[URL]] {
        var healthy: [[URL]] = [], benched: [[URL]] = [], first: [[URL]] = []
        for source in sources {
            guard let lead = source.first else { continue }
            if let detour, source.last == detour.origin {
                first.append(detour.skipsVariant ? [detour.origin] + source.dropLast() : source)
            } else if isBenched(ArtworkURL.route(of: lead), now: now), !isAtHand(lead) {
                benched.append(source)
            } else {
                healthy.append(source)
            }
        }
        return first + healthy + benched
    }
}
