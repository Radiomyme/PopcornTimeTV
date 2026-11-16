import Foundation

/// The "stream on cellular" setting (key `streamOnCellular`, off by
/// default), applied before a stream starts: on a connection the system
/// reports as expensive (cellular data, a personal hotspot) the app asks
/// first, unless the user turned the setting on. The connection's state is
/// passed in (`NWPath.isExpensive` in the apps), so the rule itself is
/// unit-tested.
public enum CellularStreamingPolicy {

    public static let defaultsKey = "streamOnCellular"

    public enum Decision: Equatable {
        /// Start the stream.
        case stream
        /// Expensive connection and the setting is off: ask before starting.
        case askFirst
    }

    public static func decision(isExpensive: Bool, defaults: UserDefaults = .standard) -> Decision {
        isExpensive && !defaults.bool(forKey: defaultsKey) ? .askFirst : .stream
    }

    /// The user answered "Turn On": streams no longer ask on cellular.
    public static func allow(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: defaultsKey)
    }
}
