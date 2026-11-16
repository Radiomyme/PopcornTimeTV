

import Foundation
import UIKit
import AlamofireImage

class ContinueWatchingCollectionViewCell: UICollectionViewCell {
    
    @IBOutlet var titleLabel: UILabel!
    @IBOutlet var subtitleLabel: UILabel!
    @IBOutlet var progressView: UIProgressView!
    @IBOutlet var imageView: UIImageView!
    @IBOutlet var dimmingView: GradientView!
    
    /// What the image shows (the media id of the card): the picture is only
    /// loaded again when the card changes, not when it is reconfigured.
    var artworkID: String?

    /// Shows the first of `urls` that loads (an episode's still, then its
    /// show's backdrop: metahub answers 404 for a still it does not have),
    /// scaled to the card so a 1080p backdrop is not kept decoded at full size.
    func setArtwork(_ urls: [URL], placeholder: UIImage?, size: CGSize) {
        let wanted = artworkID
        guard let url = urls.first else {
            imageView.af.cancelImageRequest()
            imageView.image = placeholder
            return
        }
        let filter = AspectScaledToFillSizeFilter(size: size)
        imageView.af.setImage(withURL: url, placeholderImage: placeholder, filter: filter,
                              imageTransition: .crossDissolve(.default)) { [weak self] response in
            // Still this card, and nothing came: the next address. A request
            // cancelled is not one that failed: its answer comes late, after
            // `prepareForReuse`, and a cell given the same card again would
            // drop the still it has just asked for the backdrop.
            guard case .failure(let error) = response.result, !error.isRequestCancelledError,
                  let self = self, self.artworkID == wanted, urls.count > 1 else { return }
            self.setArtwork(Array(urls.dropFirst()), placeholder: placeholder, size: size)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.af.cancelImageRequest()
        artworkID = nil
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
        
        // The pictures are sharp stills and backdrops now (they were small
        // blurred backgrounds): a stronger scrim under the two lines of
        // text, which stay readable on a bright image.
        dimmingView.bottomColor = UIColor(white: 0, alpha: 0.8)
        subtitleLabel.textColor = UIColor(white: 1, alpha: 0.85)
        
        focusedConstraints.append(dimmingView.leadingAnchor.constraint(equalTo: imageView.focusedFrameGuide.leadingAnchor))
        focusedConstraints.append(dimmingView.trailingAnchor.constraint(equalTo: imageView.focusedFrameGuide.trailingAnchor))
        focusedConstraints.append(dimmingView.bottomAnchor.constraint(equalTo: imageView.focusedFrameGuide.bottomAnchor))
    }

}
