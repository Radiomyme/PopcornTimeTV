

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
        // The page of the poster that keeps the focus is asked ahead
        // (`DetailStore.prewarm`: 0.4 s on it, two at a time): it then opens
        // with its sources. Nil when the focus leaves the posters.
        DetailStore.shared.prewarm(context.nextFocusedIndexPath.flatMap { media(at: $0) })
        // The caption goes with the focus: under the poster that gets it,
        // away when the focus leaves the posters (the header, the tab bar).
        if collectionView === self.collectionView {
            if let next = context.nextFocusedIndexPath {
                captionFollowsFocus(to: next)
            } else {
                hideCaption()
            }
        }

        // Infinite scroll: when the focus reaches the last three rows of
        // the list (21 posters; it was 10 cells, under two of the old rows
        // of six), kick off the next page: its posters are there before the
        // focus is. Guard with `hasNextPage` so we don't keep firing once
        // the catalog is exhausted.
        let itemsInSection = collectionView.numberOfItems(inSection: focusIndexPath.section)
        if paginated && hasNextPage && !isLoading && loadMoreError == nil
            && focusIndexPath.item >= (itemsInSection - 21) {
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
        guard let collectionView = collectionView else { return }
        if let indexPath = collectionView.indexPathsForVisibleItems.first(where: { collectionView.cellForItem(at: $0)?.isFocused == true }),
           let media = media(at: indexPath) {
            return open(media, at: indexPath, autoPlay: true)
        }
        // A Continue Watching card (the carousel in the grid's header gets no
        // recognizer of its own): what Select does there, which plays.
        for row in collectionView.subviews.compactMap({ $0 as? ContinueWatchingCollectionReusableView }) {
            guard let carousel = row.collectionView,
                  let indexPath = carousel.indexPathsForVisibleItems.first(where: { carousel.cellForItem(at: $0)?.isFocused == true })
            else { continue }
            row.collectionView(carousel, didSelectItemAt: indexPath)
            return
        }
    }

    /// A movie or show of the grid (not a person or a download).
    private func media(at indexPath: IndexPath) -> Media? {
        guard let media = dataSources[safe: indexPath.section]?[safe: indexPath.item] as? Media,
              media is Movie || media is Show else { return nil }
        return media
    }

    /// Its page, like a click (with `autoPlay`, like Continue Watching).
    private func open(_ media: Media, at indexPath: IndexPath, autoPlay: Bool) {
        #if DEBUG
        // `-PTDebugPosterPlayDryRun YES` (the UI tests, which walk a
        // poster's menu past Play): Play on a poster only logs.
        if autoPlay, UserDefaults.standard.bool(forKey: "PTDebugPosterPlayDryRun") {
            return print("[Debug] poster Play (dry run): \(media.title) (\(media.id))")
        }
        #endif
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
                                    image: UIImage(systemName: inWatchlist ? "minus.circle" : "plus.circle")) { [weak self] _ in
                self?.toggleWatchlist(of: media)
            })
            if let movie = media as? Movie {
                let watched = movie.isWatched
                actions.append(UIAction(title: (watched ? "Mark as Unwatched" : "Mark as Watched").localized,
                                        image: UIImage(systemName: watched ? "eye.slash" : "eye")) { [weak self] _ in
                    self?.toggleWatched(of: movie)
                })
            }
            return UIMenu(title: media.title, children: actions)
        }
    }

    private func toggleWatchlist(of media: Media) {
        var media = media
        media.isAddedToWatchlist.toggle()
        // The library says it changed: the poster and its caption follow
        // (`libraryDidChange`). On the Watchlist tab the poster leaves the
        // grid — once the menu has closed and the focus is back on it.
        if let watchlist = activeRootViewController as? WatchlistViewController, watchlist.collectionViewController === self {
            afterMenuCloses { [weak self] in self?.remove(media) }
        }
    }

    /// Runs `work` when the poster's menu has closed: when the focus is back
    /// on a poster (it returns to the one the menu was opened on, a moment
    /// after the menu's own animation), checked ten times a second, for 2 s
    /// at most. A poster taken out under its menu left the focus nowhere to
    /// come back to: it went to the grid's first poster.
    private func afterMenuCloses(attempt: Int = 0, _ work: @escaping () -> Void) {
        guard focusedPosterIndexPath == nil, attempt < 20 else { return work() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.afterMenuCloses(attempt: attempt + 1, work)
        }
    }

    /// Takes a poster out of the grid (the Watchlist). When it has the
    /// focus, the focus first moves to the poster that takes its place (the
    /// next one; the one before for the last of a section), then the poster
    /// goes and the others close the gap.
    private func remove(_ media: Media) {
        guard let collectionView = collectionView,
              let section = dataSources.firstIndex(where: { $0.contains { ($0 as? Media)?.id == media.id } }),
              let item = dataSources[section].firstIndex(where: { ($0 as? Media)?.id == media.id }) else { return }
        let removed = IndexPath(item: item, section: section)
        let count = dataSources[section].count
        // A list replaced without the grid following (not the case of the
        // Watchlist, which reloads): no batch delete, whose counts would
        // not match — a reload.
        guard collectionView.numberOfSections == dataSources.count,
              collectionView.numberOfItems(inSection: section) == shownCount(inSection: section) else {
            dataSources[section].remove(at: item)
            return reloadDataKeepingFocus()
        }
        if focusedPosterIndexPath == removed, count > 1 {
            focusIndexPath = IndexPath(item: item + 1 < count ? item + 1 : item - 1, section: section)
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
        dataSources[section].remove(at: item)
        // The posters after the one removed move up by one.
        if focusIndexPath.section == section, focusIndexPath.item > item {
            focusIndexPath = IndexPath(item: focusIndexPath.item - 1, section: section)
        }
        // A section emptied loses its title, an empty grid shows its
        // message: a reload; otherwise the poster alone goes.
        guard !dataSources[section].isEmpty, collectionView.numberOfSections == dataSources.count else {
            if let other = dataSources.firstIndex(where: { !$0.isEmpty }) { focusIndexPath = IndexPath(item: 0, section: other) }
            return reloadDataKeepingFocus()
        }
        collectionView.performBatchUpdates({ collectionView.deleteItems(at: [removed]) }) { [weak self] _ in
            self?.updateCaption(animated: true)
        }
    }

    private func toggleWatched(of movie: Movie) {
        // The poster's tick follows the library (`libraryDidChange`).
        var movie = movie
        movie.isWatched.toggle()
    }
}
