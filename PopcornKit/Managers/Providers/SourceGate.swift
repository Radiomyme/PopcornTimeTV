import Foundation

/// Several sources feeding one list (a grid page, a search): when to stop
/// waiting and deliver what arrived.
///
/// - Every source answered: at once.
/// - Every REQUIRED source answered and a source, required or not, brought
///   content: the optional ones still out (Time4Popcorn, a single plain-HTTP
///   host with a 10 s timeout; Cinemeta's search) get `grace` more seconds,
///   then the list is delivered without them. (Only a required source's
///   content used to count: a search YTS has nothing for waited 8 s for a
///   mute Time4Popcorn with Cinemeta's results in hand.)
/// - No source brought anything yet: the optional ones still out are all
///   there is, they are waited for until the deadline — except the ones
///   registered `gracedWhenEmpty` (a search's Time4Popcorn, often mute):
///   once the required sources answered with nothing — not failed — and
///   only those are still out, they get the grace, so « No results » does
///   not take the deadline to come. Cinemeta's search is never cut that
///   way: it finds the titles no catalog has.
/// - `deadline` seconds after `start()`: whatever arrived.
///
/// (The loads used to wait for the slowest source with no deadline: a mute
/// optional host held every grid page 10 s, a slow mirror chain 90 s.)
///
/// One queue only (the main queue in the app): the sources' callbacks, the
/// scheduler and `completion` all run there. The scheduler is injected so the
/// rules run in tests without waiting.
final class SourceGate {

    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    static let mainQueue: Scheduler = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Longest wait for a grid page or a search.
    static var deadline: TimeInterval = 8
    /// What an optional source gets once the required ones delivered: a grid…
    static var browseGrace: TimeInterval = 0.6
    /// …and a search (Cinemeta finds the titles no catalog has).
    static var searchGrace: TimeInterval = 1.5

    private let deadline: TimeInterval
    private let grace: TimeInterval
    private let schedule: Scheduler
    private var completion: ((_ complete: Bool) -> Void)?
    private var pendingRequired = 0
    private var pendingOptional = 0
    /// Optional sources still out that are not `gracedWhenEmpty`.
    private var pendingAwaited = 0
    /// A required source failed (`failed()`): no grace on an empty list.
    private var requiredFailed = false
    /// A source brought content.
    private var delivered = false
    private var started = false
    private var graceScheduled = false

    /// `completion(complete)`: `complete` false when a source was left out.
    init(deadline: TimeInterval = SourceGate.deadline, grace: TimeInterval,
         schedule: @escaping Scheduler = SourceGate.mainQueue,
         completion: @escaping (_ complete: Bool) -> Void) {
        self.deadline = deadline
        self.grace = grace
        self.schedule = schedule
        self.completion = completion
    }

    /// Registers a source before `start()`. Call the closure it returns once,
    /// when the source has answered; `delivered` says whether it brought
    /// content (a failure or an empty answer did not). `gracedWhenEmpty`
    /// (optional sources only): not waited for past the grace even when
    /// nothing was delivered.
    func source(required: Bool, gracedWhenEmpty: Bool = false) -> (_ delivered: Bool) -> Void {
        let awaited = !required && !gracedWhenEmpty
        if required { pendingRequired += 1 } else { pendingOptional += 1 }
        if awaited { pendingAwaited += 1 }
        var answered = false
        return { [self] delivered in
            guard !answered else { return }
            answered = true
            if required { pendingRequired -= 1 } else { pendingOptional -= 1 }
            if awaited { pendingAwaited -= 1 }
            if delivered { self.delivered = true }
            evaluate()
        }
    }

    /// A required source failed (before its closure is called): an empty
    /// list then waits for the optional sources, which may still bring
    /// something, until the deadline.
    func failed() {
        requiredFailed = true
    }

    /// Every source is registered: the deadline starts now.
    func start() {
        started = true
        schedule(deadline) { [self] in fire(complete: false) }
        evaluate()
    }

    private func evaluate() {
        guard started, completion != nil else { return }
        if pendingRequired == 0 && pendingOptional == 0 { return fire(complete: true) }
        guard pendingRequired == 0, !graceScheduled else { return }
        guard delivered || (!requiredFailed && pendingAwaited == 0) else { return }
        graceScheduled = true
        schedule(grace) { [self] in fire(complete: false) }
    }

    private func fire(complete: Bool) {
        guard let completion = completion else { return }
        self.completion = nil
        completion(complete)
    }
}
