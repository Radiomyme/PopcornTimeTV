import Foundation

class TVNavigationController: UINavigationController, UINavigationControllerDelegate {

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationBar.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.clear]
    }

    func sharedSetup() {
        delegate = self
    }

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        sharedSetup()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        sharedSetup()
    }

    override init(rootViewController: UIViewController) {
        super.init(rootViewController: rootViewController)
        sharedSetup()
    }

    override init(navigationBarClass: AnyClass?, toolbarClass: AnyClass?) {
        super.init(navigationBarClass: navigationBarClass, toolbarClass: toolbarClass)
        sharedSetup()
    }

    public func navigationController(_ navigationController: UINavigationController, animationControllerFor operation: UINavigationController.Operation, from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {

        if operation == .push {
            return TVAppDocumentControllerAnimatedTransitioning(isPresenting: true)
        } else if operation == .pop {
            return TVAppDocumentControllerAnimatedTransitioning(isPresenting: false)
        }

        return nil
    }

    /// The screen shown last (`didShow`): a tab selected again shows it again.
    private weak var lastShownViewController: UIViewController?

    /// A screen pushed or shown again (a pop, the loading screen replaced by
    /// the page) while the focus is in the tab bar gets the focus: it lands
    /// there when the screen before had nothing focusable, and Menu pressed
    /// in the tab bar would leave the app instead of going back. Only when
    /// the screen changed within the tab: never for a tab's first display or
    /// a tab selected again (the focus stays on the tabs then, as in every
    /// tvOS app). A grid gets it on its collection view, which puts it back
    /// on the poster that was opened.
    public func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        let previous = lastShownViewController
        lastShownViewController = viewController
        guard let previous, previous !== viewController,
              let tabBarController = tabBarController as? TVTabBarController,
              tabBarController.selectedViewController === self,
              tabBarController.focusIsInTabBar else { return }
        tabBarController.moveFocus(to: (viewController as? MainViewController)?.collectionView ?? viewController)
    }

    // MARK: - Back during a push or a pop

    /// Back (Menu) pressed while a push or a pop still animates. UIKit's
    /// back gesture pops at once, in the middle of the push, which left the
    /// navigation in a broken state: the app crashed a moment later (Back
    /// pressed right after opening a title, while its loading screen slid in,
    /// "closed" the app). The pop is kept and done once the animation ends,
    /// one per press.
    private(set) var pendingBackCount = 0

    /// Whether a Back is waiting for a transition to end: the loading screen
    /// then does not open the page (`MainViewController.loadDetail`).
    var isGoingBack: Bool { return pendingBackCount > 0 }

    override func popViewController(animated: Bool) -> UIViewController? {
        guard transitionCoordinator == nil else {
            pendingBackCount += 1
            popAfterTransition()
            return nil
        }
        return super.popViewController(animated: animated)
    }

    override func popToRootViewController(animated: Bool) -> [UIViewController]? {
        guard transitionCoordinator == nil else {
            // A tab selected again during a push: after it.
            afterTransition { [weak self] in _ = self?.popToRootViewController(animated: animated) }
            return nil
        }
        return super.popToRootViewController(animated: animated)
    }

    /// One kept Back, once no transition runs any more.
    private func popAfterTransition() {
        afterTransition { [weak self] in
            guard let self else { return }
            self.pendingBackCount = max(0, self.pendingBackCount - 1)
            if self.viewControllers.count > 1 {
                _ = self.popViewController(animated: true)
            }
        }
    }

    /// `work` once the current transition (and any that follows at once) is over.
    private func afterTransition(_ work: @escaping () -> Void) {
        guard let coordinator = transitionCoordinator else { return work() }
        let queued = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.afterTransition(work) }
        }
        if !queued {
            DispatchQueue.main.async { [weak self] in self?.afterTransition(work) }
        }
    }

}
