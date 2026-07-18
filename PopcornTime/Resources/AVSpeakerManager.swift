

import Foundation

/// Wrapper around Apple's PRIVATE `AVSpeakerManager` class, used to list and
/// select AirPlay speaker routes in the player's audio options.
///
/// Being private API, it breaks whenever Apple reshuffles internals — on
/// tvOS 26 several KVC keys ("speakerRoutes", …) raise
/// `NSUnknownKeyException`, which crashed the options panel the moment its
/// audio tab loaded. Every access is therefore exception-guarded via
/// `ObjCExceptionCatcher` and degrades to "no alternate routes available"
/// instead of taking the app down.
class AVSpeakerManager: NSObject {

    let instance: NSObject?

    override init() {
        if let managerClass = NSClassFromString("AVSpeakerManager") as? NSObject.Type {
            instance = managerClass.init()
        } else {
            instance = nil
        }
        super.init()
    }

    /// KVC lookup that survives `valueForUndefinedKey:` exceptions.
    private func safeValue(forKey key: String) -> Any? {
        guard let instance = instance else { return nil }
        var result: Any?
        _ = ObjCExceptionCatcher.run {
            result = instance.value(forKey: key)
        }
        return result
    }

    var alternateRoutesAvailable: Bool {
        return safeValue(forKey: "alternateRoutesAvailable") as? Bool ?? false
    }

    var selectedRoute: AVAudioRoute? {
        if let route = safeValue(forKey: "selectedRoute") as? NSObject {
            return AVAudioRoute(from: route)
        }
        return nil
    }

    var defaultRoute: AVAudioRoute? {
        if let route = safeValue(forKey: "defaultRoute") as? NSObject {
            return AVAudioRoute(from: route)
        }
        return nil
    }

    var speakerRoutes: [AVAudioRoute] {
        if let routes = safeValue(forKey: "speakerRoutes") as? [NSObject] {
            return routes.compactMap({ AVAudioRoute(from: $0) })
        }
        return []
    }

    func select(route: AVAudioRoute, with password: String? = nil) {
        guard let instance = instance else { return }
        _ = ObjCExceptionCatcher.run {
            _ = instance.perform(Selector(("selectRoute:withPassword:")), with: route.instance, with: password)
        }
    }
}
