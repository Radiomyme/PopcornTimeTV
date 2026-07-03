

import Foundation

extension UIAlertController {

    private static let blurStyleKey: UnsafeRawPointer =
        UnsafeRawPointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))


    public var blurStyle: UIBlurEffect.Style {
        get {
            return objc_getAssociatedObject(self, Self.blurStyleKey) as? UIBlurEffect.Style ?? .extraLight
        } set (style) {
            objc_setAssociatedObject(self, Self.blurStyleKey, style, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }
    
    public var cancelButtonColor: UIColor? {
        return blurStyle == .dark ? .dark : nil
    }
    
    private var visualEffectView: UIVisualEffectView? {
        if let presentationController = presentationController, presentationController.responds(to: Selector(("popoverView"))), let view = presentationController.value(forKey: "popoverView") as? UIView // We're on an iPad and visual effect view is in a different place.
        {
            return view.recursiveSubviews.compactMap({$0 as? UIVisualEffectView}).first
        }
        
        return view.recursiveSubviews.compactMap({$0 as? UIVisualEffectView}).first
    }
    
    private var cancelBackgroundView: UIView? {
        return view.recursiveSubviews.first(where: {type(of: $0) == NSClassFromString("_UIAlertControlleriOSActionSheetCancelBackgroundView")})
    }
    
    private var cancelActionView: UIView? {
        return cancelBackgroundView?.value(forKey: "backgroundView") as? UIView
    }
    
    private var cancelHighlightView: UIView? {
        return cancelBackgroundView?.value(forKey: "highlightView") as? UIView
    }
    
    public convenience init(title: String?, message: String?, preferredStyle: UIAlertController.Style, blurStyle: UIBlurEffect.Style) {
        self.init(title: title, message: message, preferredStyle: preferredStyle)
        self.blurStyle = blurStyle
    }
}
