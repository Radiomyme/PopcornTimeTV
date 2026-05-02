

import UIKit

class CoverCollectionViewCell: BaseCollectionViewCell {
    
    @IBOutlet var watchedIndicator: UIImageView?
    
    var watched = false {
        didSet {
            watchedIndicator?.isHidden = !watched
        }
    }
    
#if os(tvOS)
    
    override func awakeFromNib() {
        super.awakeFromNib()
        
        if let watchedIndicator = watchedIndicator {
            focusedConstraints.append(watchedIndicator.trailingAnchor.constraint(equalTo: imageView.focusedFrameGuide.trailingAnchor))
            focusedConstraints.append(watchedIndicator.topAnchor.constraint(equalTo: imageView.focusedFrameGuide.topAnchor))
        }
    }
    
#endif
}
