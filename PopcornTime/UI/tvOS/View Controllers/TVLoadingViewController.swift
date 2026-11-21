

import Foundation

/// The loading screen a title's page used to wait behind. No longer shown:
/// the page opens at once and fills in as it loads
/// (`MainViewController.showDetail`). It stays as the destination of the
/// storyboard's "showMovie" / "showShow" segues, which show the page in its
/// place (`AutoPlayStoryboardSegue.page`).
class TVLoadingViewController: UIViewController {

    @IBOutlet var backgroundImageView: UIImageView!
    @IBOutlet var visualEffectView: UIVisualEffectView!
    @IBOutlet var titleLabel: UILabel!
    @IBOutlet var activityIndicatorView: UIActivityIndicatorView!

    /// Holds the focus while the page loads (see `TVFocusAnchorView`).
    private let focusAnchor = TVFocusAnchorView()

    override func loadView() {
        super.loadView()
        view.accessibilityIdentifier = "LoadingScreen"
        focusAnchor.install(in: view)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        focusAnchor.accessibilityLabel = titleLabel?.text
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [focusAnchor]
    }
}

/// A screen pushed in a tab with nothing focusable on it (the loading
/// screen) let the focus fall into the tab bar,
/// and Menu pressed there would not go back (from the tab bar Menu goes to
/// Home, and from Home leaves the app). This
/// invisible full-screen view takes the focus instead: Menu then reaches the
/// navigation controller, which goes back. It draws no focus effect.
final class TVFocusAnchorView: UIView {

    override var canBecomeFocused: Bool { return true }

    func install(in container: UIView) {
        frame = container.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        container.addSubview(self)
    }
}
