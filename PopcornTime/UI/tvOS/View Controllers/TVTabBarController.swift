

import Foundation


class TVTabBarController: UITabBarController {
    
    var environmentsToFocus: [UIFocusEnvironment] = []
    
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        defer { environmentsToFocus.removeAll() }
        return environmentsToFocus.isEmpty ? super.preferredFocusEnvironments : environmentsToFocus
    }
    
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // Sort / Genre moved from custom-view UIButtons (legacy storyboard)
        // to native `UIBarButtonItem`s — see
        // `MainViewController.installModernRightBarButtonItems`. tvOS 17+
        // routes focus through native bar items automatically (they are
        // first-class focus environments alongside tab pills and the
        // collection view), so the bespoke redirect this method used to
        // perform is no longer needed and would actually fight the system's
        // routing. Default behaviour: let the focus engine decide.
        return super.shouldUpdateFocus(in: context)
    }
}
