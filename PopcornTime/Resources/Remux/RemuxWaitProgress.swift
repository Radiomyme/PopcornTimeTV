import Foundation
import PopcornKit

/// The latest `JumpWaitProgress` of a remux (`RemuxPlayback.waitProgress`): written by the remux's
/// pump queue on its 1 s timer tick, read by the player on the main queue (its own 1 Hz tick and
/// whenever « Resuming at … » is shown). Its own lock: never taken with the remux's.
final class RemuxWaitProgressBox {
    private let lock = NSLock()
    private var current: JumpWaitProgress?
    // Pump queue only (the refresh).
    var tracker = JumpWaitProgressTracker()
    /// The `[Resume] jump wait` step last logged, for the wait that began at `loggedWaitStart`.
    var lastLoggedStep: Int?
    var loggedWaitStart: TimeInterval?
    /// The torrent's piece length and a piece start of the file (engine statistics, constant for a
    /// stream; read once they are known).
    var pieceLength: Int64 = 0
    var pieceBoundary: Int64 = 0

    var value: JumpWaitProgress? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}
