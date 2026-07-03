

import Foundation


extension PCTPlayerViewController {

    private static let windowsKey: UnsafeRawPointer =
        UnsafeRawPointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))

    var windows: [UIWindow] {
        get {
           return objc_getAssociatedObject(self, Self.windowsKey) as? [UIWindow] ?? []
        } set {
           objc_setAssociatedObject(self, Self.windowsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    func beginReceivingScreenNotifications() {
        let center = NotificationCenter.default
        
        OperationQueue.main.addOperation {
            // First handle any existing screens.
            let screens = UIScreen.screens
            if screens.count > 1 {
                for screen in screens where screen != UIScreen.main {
                    self.applicationDidConnect(to: screen)
                }
            }
        }
        
        center.addObserver(self, selector: #selector(didReceiveConnectScreenNotification(_:)), name: UIScreen.didConnectNotification, object: nil)
        center.addObserver(self, selector: #selector(didReceiveDisconnectScreenNotification(_:)), name: UIScreen.didDisconnectNotification, object: nil)
    }
    
    func endReceivingScreenNotifications() {
        let center = NotificationCenter.default
        
        center.removeObserver(self, name: UIScreen.didConnectNotification, object: nil)
        center.removeObserver(self, name: UIScreen.didDisconnectNotification, object: nil)
    }
    
    
    @objc func didReceiveConnectScreenNotification(_ notification: Notification) {
        if let screen = notification.object as? UIScreen {
            applicationDidConnect(to: screen)
        }
    }
    
    @objc func didReceiveDisconnectScreenNotification(_ notification: Notification) {
        if let screen = notification.object as? UIScreen {
            applicationDidDisconnect(from: screen)
        }
    }
    
    func applicationDidConnect(to screen: UIScreen) {
        // Remove black bars on second display
        screen.overscanCompensation = .none
        
        // Create a window and attach it to the screen.
        let screenWindow = UIWindow(frame: screen.bounds)
        screenWindow.screen = screen
        
        // Instantiate the correct view controller from the storyboard
        let viewController = UIViewController()
        viewController.view.addSubview(movieView)
        movieView.frame = screen.bounds
        
        // Make sure controls are not hidden and if the user scrubs, a screenshot is not shown.
        progressBar.isHidden ? toggleControlsVisible() : ()
        screenshotImageView?.alpha = 0.0
        
        screenWindow.rootViewController = viewController
        screenWindow.isHidden = false
        
        // If you do not retain the window, it will go away and you will see nothing.
        windows.append(screenWindow)
    }
    
    func applicationDidDisconnect(from screen: UIScreen) {
        if let index = windows.firstIndex(where: {$0.screen == screen}) {
            windows.remove(at: index)
        }
        screenshotImageView?.alpha = 1.0
        if let airPlayingView = airPlayingView {
            view.insertSubview(movieView, aboveSubview: airPlayingView)
            movieView.frame = airPlayingView.bounds
        }
        resetIdleTimer()
    }
}
