import Foundation
import PopcornKit
#if os(tvOS)
import TVServices
import UIKit
#endif

/// Tells tvOS when the Top Shelf may have changed
/// (`TVTopShelfContentProvider.topShelfContentDidChange()`): the system then
/// asks the extension again instead of showing the shelf it kept.
///
/// One thing changes it today: the Home has refreshed (new lists: the
/// extension shows the same hero and the same new titles). A change of the
/// library (a title played, marked, added to the watchlist) would too, once
/// the extension can read it: see `followsLibrary`. A change is only noted
/// while the app is in front — the Top Shelf cannot be seen then, and a film
/// saves its position every few seconds — and the system is told once, when
/// the app leaves the foreground: the moment the user goes back to the home
/// screen. A change that comes while the app is in the background (an
/// answer that arrives late) is told at once — a burst of them, once.
///
/// The Home is followed through `HomeFeed.didRefreshNotification`, not
/// `HomeFeed.onUpdate`: that one has a single subscriber, the Home screen's
/// `HomeState`. Nothing here makes the hub or the library: when neither is
/// used, nothing is posted.
///
/// (The extension cannot read the app's files — no App Group — so it does
/// not show the library yet: telling the system of a library change would
/// only wake the extension, and let it ask its stale lists again, for a
/// shelf that stays the same.)
final class TopShelfReloader {

    /// Whether the library's changes are followed: off until the extension
    /// can read the library (an App Group). The path is kept, and tested.
    static let followsLibrary = false

    #if os(tvOS)
    /// The app's reloader. `start()` at launch.
    static let shared = TopShelfReloader(
        leavesForeground: [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification],
        // Inactive (the launch, an overlay of the system) is still in front.
        isInFront: { UIApplication.shared.applicationState != .background },
        reload: {
            print("[TopShelf] the shelf may have changed: the system is told")
            TVTopShelfContentProvider.topShelfContentDidChange()
        })
    #endif

    private let center: NotificationCenter
    private let followsLibrary: Bool
    private let leavesForeground: [Notification.Name]
    private let isInFront: () -> Bool
    private let reload: () -> Void

    // Main thread only.
    private var tokens: [NSObjectProtocol] = []
    /// Something changed since the system was last told.
    private var isDirty = false
    /// A change came in the background: the system is told at the next
    /// turn of the main queue (one call for a burst of changes).
    private var isFlushScheduled = false
    /// The Home's `lastUpdated` when it was last noted: a refresh that asked
    /// nothing (every list still fresh) leaves it as it was.
    private var notedHomeDate: Date?
    private var hasNotedHome = false

    /// - Parameters:
    ///   - center: where the hub, the library and the app post.
    ///   - followsLibrary: a change of the library is noted too.
    ///   - leavesForeground: the app's notifications that mean it is not in
    ///     front any more.
    ///   - isInFront: the app is on screen, active or not (main thread).
    ///   - reload: tells the system.
    init(center: NotificationCenter = .default, followsLibrary: Bool = TopShelfReloader.followsLibrary,
         leavesForeground: [Notification.Name], isInFront: @escaping () -> Bool, reload: @escaping () -> Void) {
        self.center = center
        self.followsLibrary = followsLibrary
        self.leavesForeground = leavesForeground
        self.isInFront = isInFront
        self.reload = reload
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }

    /// Starts following the hub, the library (when `followsLibrary`) and
    /// the app. Main thread; a
    /// second call does nothing.
    func start() {
        guard tokens.isEmpty else { return }
        // No queue: the three are posted on the main thread, and a change is
        // only noted here.
        tokens.append(center.addObserver(forName: HomeFeed.didRefreshNotification, object: nil, queue: nil) { [weak self] notification in
            guard let feed = notification.object as? HomeFeed else { return }
            self?.homeRefreshed(lastUpdated: feed.snapshot.lastUpdated)
        })
        if followsLibrary {
            tokens.append(center.addObserver(forName: .libraryDidChange, object: nil, queue: nil) { [weak self] _ in
                self?.note()
            })
        }
        for name in leavesForeground {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.flush()
            })
        }
    }

    /// A refresh of the Home has ended; `lastUpdated` is when its freshest
    /// list was fetched.
    private func homeRefreshed(lastUpdated: Date?) {
        guard !hasNotedHome || lastUpdated != notedHomeDate else { return }
        hasNotedHome = true
        notedHomeDate = lastUpdated
        // A refresh that reached nothing and has nothing cached changes nothing.
        if lastUpdated != nil { note() }
    }

    private func note() {
        isDirty = true
        guard !isInFront(), !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isFlushScheduled = false
            self?.flush()
        }
    }

    private func flush() {
        guard isDirty else { return }
        isDirty = false
        reload()
    }
}
