

import Foundation

class AutoPlayStoryboardSegue: UIStoryboardSegue {
    
    /// Boolean value indicating whether or not to autoplay media once the segue has been performed.
    var shouldAutoPlay = false

    /// The screen shown instead of the storyboard's destination: the
    /// title's page itself (`MainViewController.prepare(for:sender:)`). The
    /// storyboard's "showMovie" / "showShow" segues lead to the loading
    /// screen of 5.2, which the page no longer needs: it opens at once and
    /// fills in as it loads.
    var page: UIViewController?

    override func perform() {
        guard let page = page else { return super.perform() }
        source.show(page, sender: nil)
    }
}
