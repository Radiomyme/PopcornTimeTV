

import Foundation
import UIKit

// `@retroactive` (Swift 5.10+) acknowledges that we know UIKit might one
// day add this conformance natively — without the marker Swift 6 emits a
// warning that the future-conformance behaviour would be undefined. The
// extension is still load-bearing today: TVButton uses
// `[UIControl.State: …]` dictionaries which require Hashable, and the
// stock SDK stops at OptionSet-derived `==` only.
extension UIControl.State: @retroactive Hashable {

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}
