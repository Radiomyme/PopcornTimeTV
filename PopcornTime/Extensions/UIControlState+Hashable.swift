

import Foundation

extension UIControl.State: Hashable {
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}
