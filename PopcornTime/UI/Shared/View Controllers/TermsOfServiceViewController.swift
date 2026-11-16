

import UIKit

class TermsOfServiceViewController: UIViewController {

    /// Posted on the main thread once the user accepts: what waited for the
    /// terms (the Apple TV Home's lists) starts.
    static let acceptedNotification = Notification.Name("PTTermsOfServiceAccepted")

    /// The terms were accepted (the `tosAccepted` setting).
    static var areAccepted: Bool { UserDefaults.standard.bool(forKey: "tosAccepted") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.isNavigationBarHidden = false
        navigationController?.navigationBar.titleTextAttributes?[NSAttributedString.Key.foregroundColor] = UIColor.white
    }
    
    @IBAction func accepted(_ sender: UIButton) {
        UserDefaults.standard.set(true, forKey: "tosAccepted")
        NotificationCenter.default.post(name: Self.acceptedNotification, object: nil)
        dismiss(animated: true)
    }
    
    @IBAction func canceled(_ sender: UIButton) {
        exit(0)
    }
}
