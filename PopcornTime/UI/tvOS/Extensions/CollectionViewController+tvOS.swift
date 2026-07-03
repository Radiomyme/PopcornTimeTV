

import Foundation

extension CollectionViewController {

    /// Stable raw pointer key for `objc_setAssociatedObject`. We can't pass
    /// `&someStringVar` (Swift 6 warns: "Forming 'UnsafeRawPointer' to an
    /// inout variable of type String exposes the internal representation
    /// rather than the string contents") so we allocate a single byte and
    /// use its (forever-stable) address as the key.
    private static let focusIndexPathKey: UnsafeRawPointer =
        UnsafeRawPointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))

    var focusIndexPath: IndexPath {
        get {
            return objc_getAssociatedObject(self, Self.focusIndexPathKey) as? IndexPath ?? IndexPath(item: 0, section: 0)
        } set (indexPath) {
            objc_setAssociatedObject(self, Self.focusIndexPathKey, indexPath, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    override func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        return focusIndexPath
    }
    
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        focusIndexPath = indexPath
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        updateNavigationItemOffset()
    }
    
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateNavigationItemOffset()
    }
    
    func updateNavigationItemOffset() {
        guard let collectionView = collectionView else { return }
        
        let adjustment = collectionView.contentOffset.y + collectionView.contentInset.top - 44
        parent?.navigationItem.leftBarButtonItem?.customView?.frame.origin.y = -adjustment
        parent?.navigationItem.rightBarButtonItems?.forEach({$0.customView?.frame.origin.y = -adjustment})
    }
    
    override func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {

        if let next = context.nextFocusedIndexPath {
            focusIndexPath = next
        }

        // Infinite scroll: when the focus reaches within 10 cells of the end
        // of the current section, kick off the next page. Guard with
        // `hasNextPage` so we don't keep firing once the catalog is exhausted.
        let itemsInSection = collectionView.numberOfItems(inSection: focusIndexPath.section)
        if paginated && hasNextPage && !isLoading
            && focusIndexPath.item >= (itemsInSection - 10) {
            currentPage += 1
            delegate?.load(page: currentPage)
        }
    }
}
