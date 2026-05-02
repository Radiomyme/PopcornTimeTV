

import UIKit

@IBDesignable class TVVisualEffectView: UIVisualEffectView {

    @IBInspectable var blurRadius: CGFloat {
        get {
            return (blurEffect?.value(forKey: "blurRadius") as? CGFloat) ?? 90
        } set (radius) {
            blurEffect?.setValue(radius, forKey: "blurRadius")
            effect = blurEffect
        }
    }

    /// Optional because on tvOS 18+ the private `_UICustomBlurEffect` API
    /// rejects `setValue:forKey:` for `scale` (and may reject `blurRadius`),
    /// so we fall back to the standard system blur and leave this property
    /// nil rather than crashing the whole view hierarchy.
    private var blurEffect: UIBlurEffect?

    override init(effect: UIVisualEffect?) {
        guard let effect = effect as? UIBlurEffect else {
            fatalError("Effect must be of class: UIBlurEffect")
        }
        super.init(effect: effect)
        sharedSetup(effect: effect)
        self.effect = blurEffect ?? effect
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)

        guard let effect = effect as? UIBlurEffect else {
            fatalError("Effect must be of class: UIBlurEffect")
        }

        sharedSetup(effect: effect)
        self.effect = blurEffect ?? effect
    }

    private func sharedSetup(effect: UIBlurEffect, radius: CGFloat = 90) {
        // The custom-radius hack relies on the private _UICustomBlurEffect
        // class plus three KVC-settable keys. tvOS 18 removed `scale` and
        // marked the others non-KVC-compliant in a way that throws an
        // NSUnknownKeyException. Detect feature availability via try/catch
        // (Objective-C exception bridge) and gracefully degrade to the
        // stock blur if any setter fails.
        guard
            let CustomBlurClass = NSClassFromString("_UICustomBlurEffect") as? UIBlurEffect.Type,
            let raw   = effect.value(forKey: "_style") as? Int,
            let style = UIBlurEffect.Style(rawValue: raw).map({ $0 })
        else {
            self.blurEffect = nil
            return
        }
        let candidate = CustomBlurClass.init(style: style)
        let success = TVVisualEffectView.applySafely {
            candidate.setValue(1.0, forKey: "scale")
            candidate.setValue(radius, forKey: "blurRadius")
            candidate.setValue(UIColor.clear, forKey: "colorTint")
        }
        self.blurEffect = success ? candidate : nil
    }

    /// Wrap a block of KVC calls in an Objective-C @try/@catch so an
    /// `NSUnknownKeyException` from Apple removing a private key doesn't
    /// terminate the app. Returns `true` if every setter succeeded.
    private static func applySafely(_ block: @escaping () -> Void) -> Bool {
        return ObjCExceptionCatcher.run(block)
    }
}
