

import Foundation
import MarqueeLabel

extension MarqueeLabel: Object {

    public static func awake() {
        DispatchQueue.once {
            guard let originalMethod = class_getInstanceMethod(self, #selector(awakeFromNib)),
                  let swizzledMethod = class_getInstanceMethod(self, #selector(pctAwakeFromNib)) else { return }
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    @objc func pctAwakeFromNib() {
        self.pctAwakeFromNib()

        if let cString = NSString(string: "sublabel").utf8String,
           let iVar = class_getInstanceVariable(Swift.type(of: self), cString),
           let label = object_getIvar(self, iVar) as? UILabel {
            label.contentMode = contentMode
        }
    }
}
