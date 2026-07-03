

import SwiftUI
import SafariServices

/// Lightweight `SFSafariViewController` wrapper. Used by:
///  - The Trakt sign-in flow (OAuth web view): the user authorises in a real
///    Safari context, the redirect back to `popcorntime://trakt?code=…` is
///    intercepted by AppDelegate's URL handler, which then calls
///    `TraktManager.shared.authenticate(url)`.
///  - The trailer button: rather than embedding XCDYouTubeKit (broken on
///    Xcode 26 due to its iOS-8 deployment target), open the YouTube watch
///    URL in Safari — fast, no extra dep, and supports Apple TV AirPlay.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        // `preferredControlTintColor` is deprecated as of iOS 26 (it clashes
        // with the system's background effects) — let the system tint.
        vc.modalPresentationStyle = .pageSheet
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// Wrapper so a `URL` can drive `.sheet(item:)` without conforming the
/// imported `URL` type to the imported `Identifiable` protocol — a
/// retroactive conformance that would break if Foundation ever adds its own.
struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
