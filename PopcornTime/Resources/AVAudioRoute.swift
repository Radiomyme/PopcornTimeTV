

import Foundation

/// Wrapper around Apple's PRIVATE `AVAudioRoute` class (one AirPlay speaker
/// route). Same hardening as `AVSpeakerManager`: every KVC access is
/// exception-guarded so a reshuffled private key on a new tvOS degrades to a
/// default value instead of throwing `NSUnknownKeyException` mid-UI.
class AVAudioRoute: NSObject {

    let instance: NSObject

    enum DeviceType: Int {
        case `default` = 0
        case wireless = 1
    }

    class var `default`: AVAudioRoute? {
        guard
            let routeClass = NSClassFromString("AVAudioRoute") as? NSObject.Type,
            let instance = routeClass.perform(Selector(("defaultAudioRoute")))?.takeUnretainedValue() as? NSObject,
            let route = AVAudioRoute(from: instance)
            else {
                return nil
        }
        return route
    }

    init?(from instance: NSObject) {
        guard let routeClass = NSClassFromString("AVAudioRoute"), type(of: instance) == routeClass else { return nil }
        self.instance = instance

        super.init()
    }

    /// KVC lookup that survives `valueForUndefinedKey:` exceptions.
    private func safeValue(forKey key: String) -> Any? {
        var result: Any?
        _ = ObjCExceptionCatcher.run {
            result = self.instance.value(forKey: key)
        }
        return result
    }

    override func isEqual(_ object: Any?) -> Bool {
        if let route = object as? AVAudioRoute {
           return identifier == route.identifier
        }
        return false
    }

    var deviceType: DeviceType {
        return DeviceType(rawValue: safeValue(forKey: "deviceType") as? Int ?? 0) ?? .default
    }

    var isPasswordProtected: Bool {
        return safeValue(forKey: "passwordOrPINRequired") as? Bool ?? false
    }

    var identifier: String {
        return safeValue(forKey: "identifier") as? String ?? ""
    }

    var name: String {
        return safeValue(forKey: "routeName") as? String ?? ""
    }

    var isSelected: Bool {
        return safeValue(forKey: "isSelected") as? Bool ?? false
    }

    var isDefault: Bool {
        return safeValue(forKey: "isDefaultRoute") as? Bool ?? false
    }

    override var description: String {
        return "<\(type(of: self)): \(String(format: "%p", unsafeBitCast(self, to: Int.self))); passwordProtected = \(isPasswordProtected); identifier = '\(identifier)'; name = '\(name)'; selected = \(isSelected); default = \(isDefault)>"
    }
}
