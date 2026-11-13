

import Foundation

class TVLoadingViewController: UIViewController {

    @IBOutlet var backgroundImageView: UIImageView!
    @IBOutlet var visualEffectView: UIVisualEffectView!
    @IBOutlet var titleLabel: UILabel!
    @IBOutlet var activityIndicatorView: UIActivityIndicatorView!

    /// Holds the focus while the page loads (see `TVFocusAnchorView`).
    private let focusAnchor = TVFocusAnchorView()

    /// `MainViewController.loadDetail` loads the view first (to fill the
    /// outlets before the push).
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
/// screen, a page that could not load) let the focus fall into the tab bar,
/// and Menu pressed there leaves the app instead of going back. This
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

/// The page shown when a movie or show could not be loaded: the error, and
/// Menu goes back (the focus is held by a `TVFocusAnchorView`).
final class TVErrorPageViewController: UIViewController {

    private let error: NSError
    private let focusAnchor = TVFocusAnchorView()

    init(error: NSError) {
        self.error = error
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let background: ErrorBackgroundView? = .fromNib()
        background?.setUpView(error: error)
        view = background ?? UIView()
        view.accessibilityIdentifier = "ErrorPage"
        focusAnchor.install(in: view)
        focusAnchor.accessibilityLabel = error.localizedDescription
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [focusAnchor]
    }
}
