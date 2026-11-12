

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
        // The Top 100 filter: The Pirate Bay can't be reached (blocked on
        // some networks) or the titles couldn't be loaded, and no list is cached.
        if error.domain == PirateBayTop100.errorDomain {
            return setUpView(title: "Top 100 Unavailable".localized, description: PirateBayTop100.message(for: error))
        }
        let helpfulDescription: String
        let title: String
        switch error.code {
        case -1200:
            title = "SSL Error".localized
            helpfulDescription = "It looks like your ISP/Network admin is blocking our servers. You can try again with a VPN to hide your internet traffic from them. Please do so at your own risk".localized
        case -404:
            title = "Not found".localized
            helpfulDescription = "Please check your internet connection and try again.".localized
        case -1005, -1009:
            title = "You're Offline".localized
            helpfulDescription = "Please make sure you have a valid internet connection and try again.".localized
        default:
            title = "Unknown Error".localized
            helpfulDescription = error.localizedDescription
        }
        setUpView(title: title, description: helpfulDescription)
    }
}
