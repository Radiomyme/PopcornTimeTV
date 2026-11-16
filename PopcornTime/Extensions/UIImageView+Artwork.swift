

import Foundation
import UIKit
import ObjectiveC
import PopcornKit

/// The UIKit door to PopcornKit's artwork pipeline (`ArtworkPipeline`), for
/// the collection view cells: the same sizes, fallbacks and caches as the
/// SwiftUI screens' `GlassRemoteImage`, so a poster loaded by a grid is the
/// one its title's page finds in memory.
extension UIImageView {

    /// What an image view is showing or loading.
    private final class ArtworkBinding {
        var url: URL?
        var task: Task<Void, Never>?
    }

    private static var artworkBindingKey: UInt8 = 0

    private var artworkBinding: ArtworkBinding {
        if let binding = objc_getAssociatedObject(self, &Self.artworkBindingKey) as? ArtworkBinding { return binding }
        let binding = ArtworkBinding()
        objc_setAssociatedObject(self, &Self.artworkBindingKey, binding, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return binding
    }

    /// Shows the artwork at `url`, downloaded and decoded for a view
    /// `pointWidth` points wide (times `magnification`: a poster that grows
    /// under the focus is drawn larger than its cell). A picture already in
    /// memory is set at once, without a transition; otherwise `placeholder`
    /// shows until the picture fades in. A cell reused for another title
    /// simply calls this again: the load of the previous one is dropped.
    func setArtwork(_ url: URL?, pointWidth: CGFloat, magnification: CGFloat = 1, placeholder: UIImage?) {
        let binding = artworkBinding
        binding.task?.cancel()
        binding.task = nil
        binding.url = url
        guard let url else {
            image = placeholder
            return
        }
        let scale = max(traitCollection.displayScale, 1)
        let pixelWidth = (max(pointWidth, 1) * magnification * scale).rounded(.up)
        let need = ArtworkNeed(longestSide: ArtworkURL.longestSide(forPixelWidth: pixelWidth, of: url), pixelWidth: pixelWidth)
        let pipeline = ArtworkPipeline.shared

        if let hit = pipeline.cached(url, need: need) {
            // Even one decoded smaller than asked is better than the
            // placeholder while the right one loads.
            image = UIImage(cgImage: hit.image.cgImage)
            if hit.isEnough { return }
        } else {
            image = placeholder
        }
        let wasEmpty = image == nil || image === placeholder
        binding.task = Task { @MainActor [weak self] in
            guard let loaded = await pipeline.image(for: url, need: need),
                  !Task.isCancelled, let self, self.artworkBinding.url == url else { return }
            let picture = UIImage(cgImage: loaded.cgImage)
            guard wasEmpty, !UIAccessibility.isReduceMotionEnabled else {
                self.image = picture
                return
            }
            UIView.transition(with: self, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.image = picture
            }
        }
    }

    /// Drops the load `setArtwork` started (the picture shown stays).
    func cancelArtwork() {
        let binding = artworkBinding
        binding.task?.cancel()
        binding.task = nil
        binding.url = nil
    }
}
