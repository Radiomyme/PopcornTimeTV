import Foundation

/// The push / pop of the tvOS navigation controllers (`TVNavigationController`):
/// the page comes forward while the screen behind grows and fades (push); on
/// pop the page shrinks and fades while the screen behind comes back from
/// that zoom.
///
/// The screen behind is scaled with a transform, so its frame must be set
/// while the transform is the identity: a frame set on a scaled view divides
/// its bounds by the scale. The pop used to set the zoom first and let UIKit
/// place the view afterwards, which laid a grid out 1920 / 1.4 = 1371 points
/// wide (four columns instead of six) until the next layout pass put it back:
/// the grid jumped, reloaded its posters and lost the focused title. Both
/// directions now place the views first and leave them with the identity
/// transform and full opacity when done, so a screen shown again without
/// this animation (a pop that is not animated, a tab re-selected) is never
/// left zoomed or invisible.
class TVAppDocumentControllerAnimatedTransitioning: NSObject, UIViewControllerAnimatedTransitioning {

    /// Transform applied to presented view (previous view in stack) when view controller is being presented.
    let transformTo = CGAffineTransform(scaleX: 1.4, y: 1.4)

    /// Transform applied to dismissing view (current view in stack) when view controller is being dismissed.
    let transformFrom = CGAffineTransform(scaleX: 0.6, y: 0.6)

    let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.6
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning)  {
        isPresenting ? animatePresentationWithTransitionContext(transitionContext) : animateDismissalWithTransitionContext(transitionContext)
    }

    /// Identity transform, full opacity and the frame UIKit wants, laid out
    /// at that size before any animation scales it.
    private func place(_ view: UIView, of viewController: UIViewController?, in transitionContext: UIViewControllerContextTransitioning) {
        view.transform = .identity
        view.alpha = 1
        if let viewController {
            let frame = transitionContext.finalFrame(for: viewController)
            if !frame.isEmpty { view.frame = frame }
        }
        view.layoutIfNeeded()
    }

    func animatePresentationWithTransitionContext(_ transitionContext: UIViewControllerContextTransitioning) {
        guard
            let presentedControllerView = transitionContext.view(forKey: .to),
            let presentingControllerView = transitionContext.view(forKey: .from)
            else {
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
        }

        place(presentedControllerView, of: transitionContext.viewController(forKey: .to), in: transitionContext)
        transitionContext.containerView.addSubview(presentedControllerView)
        transitionContext.containerView.addSubview(presentingControllerView)
        presentedControllerView.alpha = 0.0

        UIView.animate(withDuration: transitionDuration(using: transitionContext), delay: 0.0, usingSpringWithDamping: 1.0, initialSpringVelocity: 0.0, options: .allowUserInteraction, animations: {
            presentingControllerView.alpha = 0.0
            presentedControllerView.alpha = 1.0
            presentingControllerView.transform = self.transformTo
        }, completion: { _ in
            let cancelled = transitionContext.transitionWasCancelled
            // The screen left behind gets its normal state back: the pop
            // animates it from the zoom again, anything else shows it as is.
            presentingControllerView.transform = .identity
            presentingControllerView.alpha = 1
            if cancelled {
                presentedControllerView.removeFromSuperview()
            } else {
                presentingControllerView.removeFromSuperview()
            }
            transitionContext.completeTransition(!cancelled)
        })
    }

    func animateDismissalWithTransitionContext(_ transitionContext: UIViewControllerContextTransitioning) {
        guard
            let presentedControllerView = transitionContext.view(forKey: .from),
            let presentingControllerView = transitionContext.view(forKey: .to)
            else {
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
        }

        // Placed and laid out at its real size first, then zoomed.
        place(presentingControllerView, of: transitionContext.viewController(forKey: .to), in: transitionContext)
        transitionContext.containerView.addSubview(presentedControllerView)
        transitionContext.containerView.addSubview(presentingControllerView)

        presentingControllerView.transform = self.transformTo // As if we've just come from that view and the transform has stuck
        presentingControllerView.alpha = 0.0

        UIView.animate(withDuration: transitionDuration(using: transitionContext), delay: 0.0, usingSpringWithDamping: 1.0, initialSpringVelocity: 0.0, options: .allowUserInteraction, animations: {
            presentedControllerView.transform = self.transformFrom
            presentedControllerView.alpha = 0.0
            presentingControllerView.transform = .identity
            presentingControllerView.alpha = 1.0
        }, completion: { _ in
            let cancelled = transitionContext.transitionWasCancelled
            presentingControllerView.transform = .identity
            presentingControllerView.alpha = 1
            presentedControllerView.transform = .identity
            presentedControllerView.alpha = 1
            if cancelled {
                presentingControllerView.removeFromSuperview()
            } else {
                presentedControllerView.removeFromSuperview()
            }
            transitionContext.completeTransition(!cancelled)
        })
    }
}
