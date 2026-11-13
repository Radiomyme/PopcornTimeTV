import Foundation
import GCDWebServer

/// What GCDWebServer — PopcornTorrent's streaming server and the remux HLS
/// server (RemuxPlayback) — writes to the console. The three apps call
/// `configure()` first thing at launch (before
/// `BoundedStorageDebugHooks.prepareAtLaunch`, whose `-PTDebugHTTPTrace`
/// installs its own verbose logger over this one).
///
/// Every build: errors only (DEBUG: warnings too), minus the expected ones.
/// The players drop connections all the time — AVPlayer cancels HLS segment
/// and byte-range requests on every seek, stream switch or buffer trim, VLC
/// closes its range reads — and GCDWebServer reports each one as an ERROR
/// ("Error while writing to socket N: Broken pipe (32)", "Connection reset
/// by peer (54)", "No more data available on socket N"); a busy port is a
/// retry our code expects (the streamer tries 50321…50341, the remux server
/// falls back to any port: "Failed binding IPv4 listening socket: Address
/// already in use (48)"). Those are left out (DEBUG counts the disconnects:
/// one line at the first, then every 100th); any other server error still
/// shows, as `[GCDWebServer] [ERROR] …`.
enum GCDWebServerLogging {
    static func configure() {
        #if DEBUG
        GCDWebServer.setLogLevel(3)   // WARNING and ERROR
        #else
        GCDWebServer.setLogLevel(4)   // ERROR
        #endif
        GCDWebServer.setBuiltInLogger { level, message in
            if isClientDisconnect(message) {
                #if DEBUG
                let count = disconnects.increment()
                if count == 1 || count.isMultiple(of: 100) {
                    fputs("[GCDWebServer] \(count) client disconnect(s) not logged (\(message))\n", stderr)
                }
                #endif
                return
            }
            if isExpectedRetry(message) { return }
            let names = ["DEBUG", "VERBOSE", "INFO", "WARNING", "ERROR"]
            let name = names.indices.contains(Int(level)) ? names[Int(level)] : "\(level)"
            fputs("[GCDWebServer] [\(name)] \(message)\n", stderr)
        }
    }

    #if DEBUG
    private static let disconnects = LockedCounter()
    #endif

    /// A port already taken, which the servers' callers retry on another
    /// one (GCDWebServer's bind error, EADDRINUSE).
    static func isExpectedRetry(_ message: String) -> Bool {
        guard message.hasPrefix("Failed binding"), let code = errorCode(of: message) else { return false }
        return code == EADDRINUSE
    }

    /// The trailing "(N)" errno of a GCDWebServer message.
    private static func errorCode(of message: String) -> Int32? {
        guard message.hasSuffix(")"), let open = message.lastIndex(of: "(") else { return nil }
        return Int32(message[message.index(after: open)..<message.index(before: message.endIndex)])
    }

    /// The peer closed or reset the connection (an expected cancel), from
    /// GCDWebServerConnection's read / write errors.
    static func isClientDisconnect(_ message: String) -> Bool {
        if message.hasPrefix("No more data available on socket") || message.hasPrefix("No data received from socket") {
            return true
        }
        // A body read the stream's cancel interrupted (PopcornTorrent's
        // gated response, ReadCancelled = 2): the player and the stream went.
        if message.hasPrefix("Failed reading response body"),
           message.contains("com.popcorntimetv.popcorntorrent.http Code=2 ") || message.hasSuffix("com.popcorntimetv.popcorntorrent.http Code=2") {
            return true
        }
        guard message.hasPrefix("Error while writing to socket") || message.hasPrefix("Error while reading from socket"),
              let code = errorCode(of: message) else {
            return false
        }
        return [EPIPE, ECONNRESET, ENOTCONN].contains(code)
    }
}

#if DEBUG
/// A counter shared by GCDWebServer's queues.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
#endif
