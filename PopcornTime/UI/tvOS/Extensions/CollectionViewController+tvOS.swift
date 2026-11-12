

import Foundation
import PopcornKit

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

// MARK: - Play/Pause and long press on a poster

extension CollectionViewController {

    private static let playPauseGestureName = "PlayPauseOnPoster"

    /// The remote's Play/Pause on a poster opens its page and plays it, as
    /// Continue Watching does (the quality chooser, unless Auto Select
    /// Quality picks): tvOS users expect Play to play the title in focus.
    func installPlayPauseGesture() {
        guard let collectionView = collectionView,
              !(collectionView.gestureRecognizers ?? []).contains(where: { $0.name == Self.playPauseGestureName }) else { return }
        let gesture = UITapGestureRecognizer(target: self, action: #selector(playFocusedPoster))
        gesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        gesture.name = Self.playPauseGestureName
        collectionView.addGestureRecognizer(gesture)
    }

    @objc private func playFocusedPoster() {
        guard let collectionView = collectionView,
              let indexPath = collectionView.indexPathsForVisibleItems.first(where: { collectionView.cellForItem(at: $0)?.isFocused == true }),
              let media = media(at: indexPath) else { return }
        open(media, at: indexPath, autoPlay: true)
    }

    /// A movie or show of the grid (not a person or a download).
    private func media(at indexPath: IndexPath) -> Media? {
        guard let media = dataSources[safe: indexPath.section]?[safe: indexPath.item] as? Media,
              media is Movie || media is Show else { return nil }
        return media
    }

    /// Its page, like a click (with `autoPlay`, like Continue Watching).
    private func open(_ media: Media, at indexPath: IndexPath, autoPlay: Bool) {
        guard let navigationController = activeRootViewController?.navigationController ?? navigationController else { return }
        focusIndexPath = indexPath
        MainViewController.showDetail(of: media, on: navigationController, autoPlay: autoPlay)
    }

    /// Long press (hold Select) on a poster: Play, the watchlist and, for a
    /// movie, the watched mark — what its page offers, without opening it.
    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard collectionView === self.collectionView, indexPaths.count == 1, let indexPath = indexPaths.first,
              let media = media(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }
            var actions: [UIMenuElement] = [
                UIAction(title: "Play".localized, image: UIImage(systemName: "play.fill")) { [weak self] _ in
                    self?.open(media, at: indexPath, autoPlay: true)
                }
            ]
            let inWatchlist = media.isAddedToWatchlist
            actions.append(UIAction(title: (inWatchlist ? "Remove from Watchlist" : "Add to Watchlist").localized,
                                    image: UIImage(systemName: inWatchlist ? "minus" : "plus")) { [weak self] _ in
                self?.toggleWatchlist(of: media)
            })
            if let movie = media as? Movie {
                let watched = movie.isWatched
                actions.append(UIAction(title: (watched ? "Mark as Unwatched" : "Mark as Watched").localized,
                                        image: UIImage(systemName: watched ? "eye.slash" : "eye")) { [weak self] _ in
                    self?.toggleWatched(of: movie, at: indexPath)
                })
            }
            return UIMenu(title: media.title, children: actions)
        }
    }

    private func toggleWatchlist(of media: Media) {
        var media = media
        media.isAddedToWatchlist.toggle()
        // The Watchlist tab shows the change at once.
        if let watchlist = activeRootViewController as? WatchlistViewController, watchlist.collectionViewController === self {
            watchlist.load(page: -1)
            collectionView?.reloadData()
        }
    }

    private func toggleWatched(of movie: Movie, at indexPath: IndexPath) {
        var movie = movie
        movie.isWatched.toggle()
        (collectionView?.cellForItem(at: indexPath) as? CoverCollectionViewCell)?.watched = movie.isWatched
    }
}
