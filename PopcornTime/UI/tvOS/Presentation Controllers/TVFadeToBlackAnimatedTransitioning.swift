

import Foundation

typealias PreloadTorrentViewControllerAnimatedTransitioning = TVFadeToBlackAnimatedTransitioning

class TVFadeToBlackAnimatedTransitioning: NSObject, UIViewControllerAnimatedTransitioning {
    
    let isPresenting: Bool
    
    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
        super.init()
    }
    
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return transitionContext?.isAnimated == false ? 0 : 1.0
    }
    
    func animateTransition(using transitionContext: UIViewControllerContextTransitioning)  {
        // A presentation or dismissal asked without animation (UIKit still
        // calls a custom animator): done at once.
        guard transitionContext.isAnimated else {
            if isPresenting, let view = transitionContext.view(forKey: .to) {
                transitionContext.containerView.addSubview(view)
                view.frame = transitionContext.containerView.bounds
            } else {
                if let presenting = transitionContext.view(forKey: .to) {
                    transitionContext.containerView.insertSubview(presenting, at: 0)
                }
                transitionContext.view(forKey: .from)?.removeFromSuperview()
            }
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            return
        }
        isPresenting ? animatePresentationWithTransitionContext(transitionContext) : animateDismissalWithTransitionContext(transitionContext)
    }
    
    
    func animatePresentationWithTransitionContext(_ transitionContext: UIViewControllerContextTransitioning) {
        guard
            let presentedControllerView = transitionContext.view(forKey: .to)
            else {
                return
        }
        
        transitionContext.containerView.addSubview(presentedControllerView)
        presentedControllerView.frame = transitionContext.containerView.bounds
        presentedControllerView.isHidden = true
        
        let view = UIView(frame: transitionContext.containerView.bounds)
        view.backgroundColor = .black
        view.alpha = 0.0
        transitionContext.containerView.addSubview(view)
        
        UIView.animate(withDuration: transitionDuration(using: transitionContext), delay: 0.0, usingSpringWithDamping: 1.0, initialSpringVelocity: 0.0, options: .curveEaseIn, animations: {
            view.alpha = 1.0
        }, completion: { completed in
            view.removeFromSuperview()
            presentedControllerView.isHidden = false
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        })
    }
    
    func animateDismissalWithTransitionContext(_ transitionContext: UIViewControllerContextTransitioning) {
        guard
            let presentingControllerView = transitionContext.view(forKey: .to),
            let presentedControllerView = transitionContext.view(forKey: .from)
            else {
                return
        }
        transitionContext.containerView.addSubview(presentingControllerView)
        transitionContext.containerView.addSubview(presentedControllerView)
        
        UIView.animate(withDuration: transitionDuration(using: transitionContext), delay: 0.0, usingSpringWithDamping: 1.0, initialSpringVelocity: 0.0, options: .curveEaseOut, animations: {
            presentedControllerView.alpha = 0.0
        }, completion: { _ in
            presentedControllerView.removeFromSuperview()
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        })
    }
}

