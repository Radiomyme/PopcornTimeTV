

import UIKit

/// Legacy class of tvOS.storyboard's "Settings Table View Controller" scene,
/// embedded in the old root of the Settings tab. The tab now shows
/// `GlassSettingsView` (installed by `TVTabBarController`), so the scene is
/// never loaded; the class only remains for the storyboard's customClass.
/// Delete it together with that scene.
class SettingsTableViewController: UITableViewController {}
