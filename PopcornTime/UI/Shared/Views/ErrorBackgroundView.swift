

import UIKit
import class PopcornKit.PirateBayTop100

class ErrorBackgroundView: UIView {
    @IBOutlet var titleLabel: UILabel?
    @IBOutlet var descriptionLabel: UILabel?
    
    
    func setUpView(title: String? = nil, description: String? = nil) {
        titleLabel?.text = title
        descriptionLabel?.text = description
    }
    
    func setUpView(error: NSError) {
        let texts = ErrorBackgroundView.texts(for: error)
        setUpView(title: texts.title, description: texts.description)
    }

    /// What to tell the user about `error`: a title and what to do.
    static func texts(for error: NSError) -> (title: String, description: String) {
        // The Top 100 filter: The Pirate Bay can't be reached (blocked on
        // some networks) or the titles couldn't be loaded, and no list is cached.
        if error.domain == PirateBayTop100.errorDomain {
            return ("Top 100 Unavailable".localized, PirateBayTop100.message(for: error))
        }
        switch error.code {
        case -1200:
            return ("SSL Error".localized, "It looks like your ISP/Network admin is blocking our servers. You can try again with a VPN to hide your internet traffic from them. Please do so at your own risk".localized)
        case -404:
            return ("Not found".localized, "Please check your internet connection and try again.".localized)
        case -1005, -1009:
            return ("You're Offline".localized, "Please make sure you have a valid internet connection and try again.".localized)
        default:
            return ("Unknown Error".localized, error.localizedDescription)
        }
    }
}
