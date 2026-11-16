

import Foundation
import PopcornKit
import AlamofireImage
import class PopcornTorrent.PTTorrentDownload
import MediaPlayer.MPMediaItem

protocol CollectionViewControllerDelegate: AnyObject {
    func load(page: Int)
    func didRefresh(collectionView: UICollectionView)
    func collectionView(isEmptyForUnknownReason collectionView: UICollectionView)
    
    func collectionView(_ collectionView: UICollectionView, titleForHeaderInSection section: Int) -> String?
    func collectionView(nibForHeaderInCollectionView collectionView: UICollectionView) -> UINib?
    
    func minItemSize(forCellIn collectionView: UICollectionView, at indexPath: IndexPath) -> CGSize?
    func collectionView(_ collectionView: UICollectionView, insetForSectionAt section: Int) -> UIEdgeInsets?
    
    @discardableResult func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) -> Bool

    /// Retry was pressed: on the message of a grid that could not load
    /// (`page` nil: the whole list is asked again), or under a list whose
    /// next page failed (`page`: that page).
    func retryLoading(page: Int?)
}

extension CollectionViewControllerDelegate {
    func load(page: Int) {}
    func didRefresh(collectionView: UICollectionView) {}
    func collectionView(isEmptyForUnknownReason collectionView: UICollectionView) {}
    
    func collectionView(_ collectionView: UICollectionView, titleForHeaderInSection section: Int) -> String? { return nil }
    func collectionView(nibForHeaderInCollectionView collectionView: UICollectionView) -> UINib? { return nil }
    
    func minItemSize(forCellIn collectionView: UICollectionView, at indexPath: IndexPath) -> CGSize? { return nil }
    func collectionView(_ collectionView: UICollectionView, insetForSectionAt section: Int) -> UIEdgeInsets? { return nil }
    
    @discardableResult func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) -> Bool { return false }

    func retryLoading(page: Int?) {}
}

class CollectionViewController: ResponsiveCollectionViewController, UICollectionViewDelegateFlowLayout {
    
    var dataSources: [[AnyHashable]] = [[]]
    var error: NSError?

    /// The next page could not be loaded. The grid keeps its titles: its
    /// footer says so and offers Retry (`loadFailed`). (The error used to be
    /// dropped, and the list never asked for another page again.)
    var loadMoreError: NSError? {
        didSet { updateFooter() }
    }
    
    let paginationIndicatorInset: CGFloat = 25
    
    func minItemSize(forCellIn collectionView: UICollectionView, at indexPath: IndexPath) -> CGSize {
        if let size = delegate?.minItemSize(forCellIn: collectionView, at: indexPath) {
            return size
        } else if isPosterSection(indexPath.section) {
            return GridStyle.posterSize
        } else {
            return UIDevice.current.userInterfaceIdiom == .tv ? CGSize(width: 250, height: 460) : CGSize(width: 108, height: 185)
        }
    }

    /// A section of movie and show posters (as opposed to people or
    /// downloads): laid out on the poster grid (`GridStyle`).
    func isPosterSection(_ section: Int) -> Bool {
        guard let first = dataSources[safe: section]?.first else { return false }
        return first is Movie || first is Show
    }
    
    var isLoading = false {
        didSet { if isLoading != oldValue { updateFooter() } }
    }
    var paginated = false
    weak var delegate: CollectionViewControllerDelegate?
    var hasNextPage = false
    var currentPage = 1
    
    var isDark = true {
        didSet {
            guard isDark != oldValue else { return }
            
            collectionView?.reloadData()
        }
    }
    
    /// Walk the responder chain to find the owning `MainViewController`.
    /// `AppDelegate.shared.activeRootViewController` only locates the host
    /// VC when the selected tab is a UINavigationController; the Search tab
    /// uses UISearchContainerViewController, which broke cell-tap → segue
    /// forwarding (and silently dropped the user's selection on the floor).
    /// Falling back to the global lookup keeps existing flows working.
    var activeRootViewController: MainViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let main = r as? MainViewController { return main }
            responder = r.next
        }
        return AppDelegate.shared.activeRootViewController
    }
    
    /// The currently visible "Continue watching" supplementary view, set on
    /// every dequeue so `collectionViewDidReloadData` can ask it to refresh.
    /// Never returned from `viewForSupplementaryElementOfKind` directly:
    /// tvOS 18+ requires a fresh dequeue for every index path.
    private weak var continueWatchingCollectionReusableView: ContinueWatchingCollectionReusableView?

    /// Off-screen instance used solely for `intrinsicContentSize` lookups in
    /// `referenceSizeForHeaderInSection`. Built once from the same nib the
    /// collection view registers; never added to the view hierarchy.
    private lazy var sizingContinueWatchingView: ContinueWatchingCollectionReusableView? = {
        guard
            let nib = delegate?.collectionView(nibForHeaderInCollectionView: self.collectionView ?? UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())),
            let view = nib.instantiate(withOwner: nil, options: nil).first as? ContinueWatchingCollectionReusableView
        else { return nil }
        if let parent = self.parent {
            view.type = type(of: parent) == MoviesViewController.self ? .movies : .episodes
        }
        return view
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()

        installPlayPauseGesture()

        if let collectionView = collectionView,
            let nib = delegate?.collectionView(nibForHeaderInCollectionView: collectionView) {
            collectionView.register(nib, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "stickyHeader")
        }
        collectionView?.register(GridSectionTitleView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                 withReuseIdentifier: GridSectionTitleView.reuseIdentifier)
        collectionView?.register(GridFooterView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
                                 withReuseIdentifier: GridFooterView.reuseIdentifier)

        // A title played, marked or added to the watchlist anywhere (a
        // page, a menu, another tab) shows on its poster when it is on screen.
        NotificationCenter.default.addObserver(self, selector: #selector(libraryDidChange), name: .libraryDidChange, object: nil)
        _ = CollectionViewController.preloadLibrary
    }

    /// The library's first answers read the disk (the stored lists, the
    /// guides of the followed shows): once, off the main thread, before the
    /// first posters ask on it.
    private static let preloadLibrary: Void = {
        DispatchQueue.global(qos: .userInitiated).async { Library.shared.preload() }
    }()

    // MARK: - Posters

    /// The library's answers for the posters (watched, progress, watchlist,
    /// new episodes), from its memory.
    let posterLibrary = PosterLibrary()

    /// The line under the focused poster: one view for the whole grid,
    /// made the first time a poster gets the focus (a grid of people or of
    /// downloads never has one).
    private var captionView: PosterCaptionView?

    private func makeCaptionView() -> PosterCaptionView {
        if let caption = captionView { return caption }
        let caption = PosterCaptionView()
        collectionView?.addSubview(caption)
        captionView = caption
        return caption
    }

    @objc private func libraryDidChange() {
        posterLibrary.invalidate()
        guard isViewLoaded, view.window != nil else { return }
        refreshVisiblePosters()
    }

    /// False on the Watchlist tab, where every poster is in the watchlist:
    /// the captions do not repeat it.
    var showsWatchlistMark = true

    /// The card of the poster at `indexPath`; nil for a person or a download.
    func card(at indexPath: IndexPath) -> PosterCard? {
        guard let media = dataSources[safe: indexPath.section]?[safe: indexPath.item] as? Media else { return nil }
        return card(for: media)
    }

    private func card(for media: Media) -> PosterCard? {
        var card = posterLibrary.card(for: media)
        if !showsWatchlistMark { card?.isInWatchlist = false }
        return card
    }

    /// The visible posters show what the library says now, in place: the
    /// cells, their images and the focus stay.
    private func refreshVisiblePosters() {
        guard let collectionView = collectionView else { return }
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? CoverCollectionViewCell, cell.marksView != nil else { continue }
            let card = self.card(at: indexPath)
            if cell.card != card { cell.showPoster(card) }
        }
        updateCaption(animated: false)
    }

    /// The poster of this grid that has the focus.
    var focusedPosterIndexPath: IndexPath? {
        guard let collectionView = collectionView else { return nil }
        return collectionView.indexPathsForVisibleItems.first { collectionView.cellForItem(at: $0)?.isFocused == true }
    }

    /// Puts the caption under the focused poster, or takes it away when no
    /// poster has the focus. `indexPath`: the poster getting the focus, when
    /// the focus is still on its way there.
    func updateCaption(for indexPath: IndexPath? = nil, animated: Bool) {
        pendingCaption?.cancel()
        pendingCaption = nil
        guard let collectionView = collectionView else { return }
        guard let target = indexPath ?? focusedPosterIndexPath, let card = card(at: target),
              let frame = collectionView.layoutAttributesForItem(at: target)?.frame else {
            return hideCaption(animated: animated)
        }
        let caption = makeCaptionView()
        let inPlace = caption.card == card && abs(caption.frame.minY - (frame.maxY + GridStyle.captionTop)) < 0.5 && caption.alpha == 1
        guard !inPlace else { return }
        caption.layer.removeAllAnimations()
        // Another poster: the line does not slide across the grid, it
        // appears under the new one.
        if animated { caption.alpha = 0 }
        caption.show(card, under: frame, gridWidth: collectionView.bounds.width)
        UIView.animate(withDuration: animated ? GridStyle.fadeDuration : 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            caption.alpha = 1
        }
    }

    private var pendingCaption: DispatchWorkItem?

    /// The focus moved to the poster at `indexPath`: its caption comes once
    /// the focus has rested there for a moment. The frame in which the
    /// focus moves is the grid's busiest (the focus animation, often a
    /// scroll and a row of new posters): the caption's text is not made in
    /// it, nor for the posters the focus only passes over on its way down
    /// the list.
    func captionFollowsFocus(to indexPath: IndexPath) {
        pendingCaption?.cancel()
        // The last poster's caption goes at once.
        if let caption = captionView, caption.card != nil, caption.alpha > 0 {
            caption.layer.removeAllAnimations()
            UIView.animate(withDuration: GridStyle.fadeDuration / 2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                caption.alpha = 0
            }
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.focusedPosterIndexPath == indexPath else { return }
            self.updateCaption(for: indexPath, animated: true)
        }
        pendingCaption = work
        DispatchQueue.main.asyncAfter(deadline: .now() + GridStyle.captionDelay, execute: work)
    }

    /// No poster has the focus any more.
    func hideCaption(animated: Bool = true) {
        pendingCaption?.cancel()
        pendingCaption = nil
        guard let caption = captionView, caption.card != nil || caption.alpha > 0 else { return }
        caption.clear()
        caption.layer.removeAllAnimations()
        UIView.animate(withDuration: animated ? GridStyle.fadeDuration : 0) { caption.alpha = 0 }
    }

    // MARK: - Changing the list without losing the focus

    /// Whether the focus is on a view of the grid that is not a cell: Sort
    /// or Genre, which live in the grid's header.
    private var headerHasFocus: Bool {
        guard let collectionView = collectionView,
              let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView,
              focused.isDescendant(of: collectionView) else { return false }
        var view: UIView? = focused
        while let current = view, current !== collectionView {
            if current is UICollectionViewCell || current is UICollectionReusableView { return false }
            view = current.superview
        }
        return true
    }

    /// Replaces what the grid shows by `dataSources` without `reloadData`:
    /// every item is taken out and put in again in one update. For a list
    /// that arrives while the focus is on Sort or Genre: a collection view
    /// that reloads moves a focus it holds to its preferred cell, as if the
    /// control were a cell that is gone, and no `shouldUpdateFocus` is asked
    /// — the focus jumped from the control to the first poster (when the
    /// list came after the menu had closed; not when it was already there).
    /// False when the sections changed: a reload is needed then.
    private func replaceItemsWithoutReload(in collectionView: UICollectionView) -> Bool {
        guard collectionView.numberOfSections == max(1, dataSources.count), !dataSources.isEmpty else { return false }
        let old = (0..<dataSources.count).map { collectionView.numberOfItems(inSection: $0) }
        UIView.performWithoutAnimation {
            collectionView.performBatchUpdates({
                for (section, count) in old.enumerated() {
                    collectionView.deleteItems(at: (0..<count).map { IndexPath(item: $0, section: section) })
                    collectionView.insertItems(at: (0..<shownCount(inSection: section)).map { IndexPath(item: $0, section: section) })
                }
            })
        }
        return true
    }

    /// Whether the focus is on a Continue Watching card, in the row at the
    /// top of the grid (a header view of the grid: a reload takes the focus
    /// from it as from Sort or Genre).
    private var continueWatchingHasFocus: Bool {
        guard let row = continueWatchingCollectionReusableView, row.window != nil,
              let focused = UIFocusSystem.focusSystem(for: row)?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: row)
    }

    /// Whether the focus is on a poster (a cell) of this grid.
    private var gridHasFocus: Bool {
        guard let collectionView = collectionView,
              let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UICollectionViewCell else { return false }
        return collectionView.indexPath(for: focused) != nil
    }

    /// Reloads the grid for a list that changed under it (the saved first
    /// page replaced by the network's, a list sorted again): the focus stays
    /// in the grid, at the same place — or on `item` when it is given and
    /// still listed, which then stays where it was on the screen.
    func reloadDataKeepingFocus(on item: AnyHashable? = nil) {
        guard let collectionView = collectionView else { return }
        let hadFocus = gridHasFocus
        // The focus on Sort or Genre stays there (see `replaceItemsWithoutReload`).
        if !hadFocus, headerHasFocus, replaceItemsWithoutReload(in: collectionView) {
            return updateCaption(animated: false)
        }
        // So does the focus on a Continue Watching card: the list arriving
        // (or the grid appearing) a moment after Down reached the row sent
        // the focus to the first poster under it. The row reads the library
        // again, as after a reload (same cards: the focused one stays).
        if !hadFocus, continueWatchingHasFocus, replaceItemsWithoutReload(in: collectionView) {
            continueWatchingCollectionReusableView?.refreshOnDeck()
            return updateCaption(animated: false)
        }
        var screenY: CGFloat?
        if hadFocus, let item = item, let old = focusedPosterIndexPath,
           let section = dataSources.firstIndex(where: { $0.contains(item) }),
           let index = dataSources[section].firstIndex(of: item) {
            screenY = collectionView.layoutAttributesForItem(at: old).map { $0.frame.minY - collectionView.contentOffset.y }
            focusIndexPath = IndexPath(item: index, section: section)
        }
        // Never past the end of a shorter list.
        let count = shownCount(inSection: focusIndexPath.section)
        if count > 0, focusIndexPath.item >= count {
            focusIndexPath = IndexPath(item: count - 1, section: focusIndexPath.section)
        }
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        if let screenY = screenY, let frame = collectionView.layoutAttributesForItem(at: focusIndexPath)?.frame {
            let top = -collectionView.adjustedContentInset.top
            let bottom = max(top, collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
            collectionView.contentOffset.y = min(max(frame.minY - screenY, top), bottom)
            collectionView.layoutIfNeeded()
        }
        if hadFocus {
            // The cells were made again: the focus goes to the one at
            // `focusIndexPath` now, not to whatever is nearest later (a tab).
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
        updateCaption(animated: false)
    }

    /// Adds a page under the list (`showNewItems`). An empty page says the
    /// list has ended.
    func append(_ items: [AnyHashable], toSection section: Int = 0) {
        guard dataSources.indices.contains(section) else { return }
        dataSources[section] += items
        showNewItems()
    }

    /// A load failed. An empty grid shows the error and Retry; a grid with
    /// titles keeps them, and its footer offers Retry for the page.
    func loadFailed(_ error: NSError?) {
        let error = error ?? NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown)
        if dataSources.allSatisfy({ $0.isEmpty }) {
            self.error = error
            collectionView?.reloadData()
        } else {
            loadMoreError = error
        }
    }

    // MARK: - Footer (the next page)

    private var footerState: GridFooterView.State {
        guard paginated, !dataSources.allSatisfy({ $0.isEmpty }) else { return .hidden }
        if loadMoreError != nil { return .failed("Couldn't load more titles.".localized) }
        return isLoading ? .loading : .hidden
    }

    private var shownFooterState = GridFooterView.State.hidden

    private func updateFooter() {
        guard isViewLoaded, let collectionView = collectionView else { return }
        let state = footerState
        guard state != shownFooterState else { return }
        shownFooterState = state
        collectionView.collectionViewLayout.invalidateLayout()
        let last = IndexPath(item: 0, section: max(0, dataSources.count - 1))
        (collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionFooter, at: last) as? GridFooterView)?.show(state)
    }

    private func retryNextPage() {
        guard loadMoreError != nil else { return }
        loadMoreError = nil
        delegate?.retryLoading(page: currentPage)
    }

    // MARK: - Empty, loading, error

    private enum BackgroundState: Equatable {
        case none
        case loading
        case message(String, String?, retry: Bool)
    }

    private var backgroundState = BackgroundState.none
    /// Set by `showMessage`: whether the delegate asked for a message.
    private var didShowMessage = false

    /// The message of a grid with nothing to show. Asked for again and
    /// again while the grid lays itself out: the view is made once per
    /// message (a Retry button made again would lose the focus).
    func showMessage(title: String, body: String?, retry: (() -> Void)? = nil) {
        didShowMessage = true
        let state = BackgroundState.message(title, body, retry: retry != nil)
        guard state != backgroundState || !(collectionView?.backgroundView is GridMessageView) else { return }
        backgroundState = state
        collectionView?.backgroundView = GridMessageView(title: title, body: body, retry: retry)
    }

    private func showLoadingPlaceholders(in collectionView: UICollectionView) {
        guard backgroundState != .loading || !(collectionView.backgroundView is GridSkeletonView) else { return }
        backgroundState = .loading
        let skeleton = GridSkeletonView()
        // Where the first row will be: under the grid's top inset and its
        // first section's (Search has its own). The first section's header
        // is added once the grid is laid out (`placeLoadingPlaceholders`).
        let sectionTop = delegate?.collectionView(collectionView, insetForSectionAt: 0)?.top ?? GridStyle.sectionTop
        skeleton.top = collectionView.adjustedContentInset.top + sectionTop
        collectionView.backgroundView = skeleton
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let collectionView { placeLoadingPlaceholders(in: collectionView) }
    }

    /// The placeholder cards under the first section's header too: Continue
    /// Watching keeps its row above a Movies or Shows list still loading
    /// (a sort picked for the first time), and the cards were drawn behind
    /// it. Read from the laid-out grid (asked while `numberOfSections` runs,
    /// the layout would ask for the sections again).
    private func placeLoadingPlaceholders(in collectionView: UICollectionView) {
        guard let skeleton = collectionView.backgroundView as? GridSkeletonView, collectionView.numberOfSections > 0 else { return }
        let header = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader,
                                                                            at: IndexPath(item: 0, section: 0))
        let sectionTop = delegate?.collectionView(collectionView, insetForSectionAt: 0)?.top ?? GridStyle.sectionTop
        skeleton.top = collectionView.adjustedContentInset.top + max(0, header?.frame.maxY ?? 0) + sectionTop
    }
    
    /// Updates what can change on the visible posters while another screen
    /// covers the grid (the watched mark) and the Continue Watching progress,
    /// without reloading anything: the cells, their images and the focus stay.
    func refreshVisibleItemsInPlace() {
        posterLibrary.invalidate()
        refreshVisiblePosters()
        if let header = continueWatchingCollectionReusableView, header.window != nil {
            // Reads the library again: the same cards are reconfigured, not
            // reloaded (a focused card keeps the focus).
            header.refreshOnDeck()
        }
    }

    private static let superHasWillDisplay = UICollectionViewController.instancesRespond(
        to: #selector(UICollectionViewDelegate.collectionView(_:willDisplay:forItemAt:)))

    /// A poster prepared ahead of time (prefetched) shows the watched mark of
    /// now: `refreshVisibleItemsInPlace` only reaches the visible ones.
    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if CollectionViewController.superHasWillDisplay { super.collectionView(collectionView, willDisplay: cell, forItemAt: indexPath) }
        guard collectionView === self.collectionView, let cover = cell as? CoverCollectionViewCell, cover.marksView != nil else { return }
        let card = self.card(at: indexPath)
        if cover.card != card { cover.showPoster(card) }
    }

    override func collectionViewDidReloadData(_ collectionView: UICollectionView) {
        super.collectionViewDidReloadData(collectionView)
        
        guard collectionView === self.collectionView else { return }
        
        continueWatchingCollectionReusableView?.refreshOnDeck()
        // The cells were made again: the caption follows the focus, once
        // the focus is back on one of them.
        DispatchQueue.main.async { [weak self] in self?.updateCaption(animated: false) }
    }
    
    override func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewFlowLayout, didChangeToSize size: CGSize) {
        let itemSize = self.collectionView(collectionView, layout: layout, sizeForItemAt: IndexPath(item: 0, section: 0))
        super.collectionView(collectionView, layout: layout, didChangeToSize: CGSize(width: size.width, height: itemSize.height))
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard let flowLayout = collectionViewLayout as? UICollectionViewFlowLayout else { return .zero }
        
        let minItemSize = self.minItemSize(forCellIn: collectionView, at: indexPath)
        
        var width: CGFloat = 0
        let inset = self.collectionView(collectionView, layout: collectionViewLayout, insetForSectionAt: indexPath.section)
        let sectionInset = inset == .zero ? flowLayout.sectionInset.left + flowLayout.sectionInset.right : inset.left + inset.right
        let spacing = flowLayout.scrollDirection == .horizontal ? flowLayout.minimumLineSpacing
            : self.collectionView(collectionView, layout: collectionViewLayout, minimumInteritemSpacingForSectionAt: indexPath.section)
        
        for items in (2...Int.max) {
            let items = CGFloat(items)
            let newWidth = (view.bounds.width/items) - (sectionInset/items) - (spacing * (items - 1)/items)
            if newWidth < minItemSize.width && items > 2 // Minimum of 2 cells no matter the screen size
            {
                break
            }
            width = newWidth
        }
        
        let ratio = width/minItemSize.width
        let height = minItemSize.height * ratio
        
        // Whole points: the posters stay sharp on a 1080p screen.
        return CGSize(width: width.rounded(.down), height: height.rounded(.down))
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        if isPosterSection(section) { return GridStyle.columnSpacing }
        return (collectionViewLayout as? UICollectionViewFlowLayout)?.minimumInteritemSpacing ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        if isPosterSection(section) { return GridStyle.rowSpacing }
        return (collectionViewLayout as? UICollectionViewFlowLayout)?.minimumLineSpacing ?? 0
    }
    
    override func numberOfSections(in collectionView: UICollectionView) -> Int {
        // Every section empty: the error, loading or empty background. (The
        // Swift 5 migration turned the flattening `flatMap` into
        // `compactMap`, which never sees `[[]]` as empty: no grid showed its
        // loading, error or empty state since.)
        guard dataSources.allSatisfy({ $0.isEmpty }) else {
            collectionView.backgroundView = nil
            backgroundState = .none
            error = nil
            return dataSources.count
        }
        // The grid asks while it lays itself out: the background is only
        // made again when what it says changed.
        if let error = error {
            let texts = ErrorBackgroundView.texts(for: error)
            showMessage(title: texts.title, body: texts.description) { [weak self] in
                self?.delegate?.retryLoading(page: nil)
            }
        } else if isLoading {
            // Cards where the posters will be: no spinner, and nothing
            // moves when they arrive.
            showLoadingPlaceholders(in: collectionView)
        } else {
            // The delegate says why (`showMessage`), or shows a view of its
            // own (Downloads). When it has nothing to say (a search not
            // typed yet), no placeholder or message is left behind.
            didShowMessage = false
            delegate?.collectionView(isEmptyForUnknownReason: collectionView)
            if !didShowMessage, collectionView.backgroundView is GridMessageView || collectionView.backgroundView is GridSkeletonView {
                collectionView.backgroundView = nil
            }
            if !didShowMessage { backgroundState = .none }
        }
        
        return 1
    }
    
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return shownCount(inSection: section)
    }

    /// Whether the list is expected to grow: a page is on its way, the
    /// next one will be asked for, or the one that failed can be retried.
    private var expectsMore: Bool {
        return paginated && (hasNextPage || isLoading || loadMoreError != nil)
    }

    /// How many items of a section the grid shows. A list of posters that
    /// is still growing shows whole rows only: the titles of a last, partly
    /// filled row wait for the page that completes it (or for the end of
    /// the list). With such a row on screen, Down from the columns it does
    /// not reach yet sent the focus to its last poster, in another column —
    /// and the row then filled up under it. The same while a page that
    /// failed can be retried: Down goes to Retry. Short lists (under three
    /// rows, all on the first screen) show everything.
    func shownCount(inSection section: Int) -> Int {
        let count = dataSources[safe: section]?.count ?? 0
        guard expectsMore, section == dataSources.count - 1, isPosterSection(section), let collectionView = collectionView else { return count }
        let width = collectionView.bounds.width - GridStyle.sideInset * 2 + GridStyle.columnSpacing
        let columns = max(1, Int(width / (GridStyle.posterSize.width + GridStyle.columnSpacing)))
        let rows = count / columns
        return rows >= 3 ? rows * columns : count
    }

    /// The grid shows what `shownCount` says now: the posters to show that
    /// it does not have yet are inserted under the others, which are not
    /// touched (no reload: their images and the focus stay). After a page
    /// was added, and when a list reaches its end: its last titles come out.
    func showNewItems() {
        guard isViewLoaded, let collectionView = collectionView else { return }
        guard collectionView.numberOfSections == dataSources.count, !dataSources.allSatisfy({ $0.isEmpty }) else {
            return reloadDataKeepingFocus()
        }
        var added: [IndexPath] = []
        for section in dataSources.indices {
            let shown = collectionView.numberOfItems(inSection: section), wanted = shownCount(inSection: section)
            // Fewer than shown, or the first titles of a grid that showed
            // its placeholders: not an insertion.
            if wanted < shown || (shown == 0 && wanted > 0) { return reloadDataKeepingFocus() }
            added += (shown..<wanted).map { IndexPath(item: $0, section: section) }
        }
        guard !added.isEmpty else { return }
        UIView.performWithoutAnimation {
            collectionView.performBatchUpdates({ collectionView.insertItems(at: added) })
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        if delegate?.collectionView(collectionView, titleForHeaderInSection: section) != nil {
            guard collectionView.numberOfItems(inSection: section) != 0 else { return .zero }
            guard isPosterSection(section) else { return CGSize(width: collectionView.bounds.width, height: 40) }
            // The first title of the page keeps its distance from the page title.
            let isFirst = !(0..<section).contains { !(dataSources[safe: $0] ?? []).isEmpty }
            return CGSize(width: collectionView.bounds.width, height: GridStyle.sectionTitleHeight + (isFirst ? GridStyle.firstSectionTitleTop : 0))
        } else if delegate?.collectionView(nibForHeaderInCollectionView: collectionView) != nil {
            // Measure the *live* header when it exists: it's the only instance
            // whose `superview` is the collection view AND whose `onDeck` is
            // populated, so its `intrinsicContentSize` reflects real content.
            // `sizingContinueWatchingView` is never in the hierarchy, so its
            // intrinsic size collapses to `.min` regardless of watch history —
            // which left the reserved header height at ~0 while the real
            // carousel rendered on top of the first poster row.
            return (continueWatchingCollectionReusableView ?? sizingContinueWatchingView)?.intrinsicContentSize ?? .min
        }
        return .zero
    }

    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        if kind == UICollectionView.elementKindSectionHeader {
            if let title = delegate?.collectionView(collectionView, titleForHeaderInSection: indexPath.section) {
                if isPosterSection(indexPath.section) {
                    let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: GridSectionTitleView.reuseIdentifier, for: indexPath) as! GridSectionTitleView
                    header.label.text = title
                    return header
                }
                let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "sectionHeader", for: indexPath)

                let label = header.viewWithTag(1) as? UILabel
                label?.text = title

                return header
            } else {
                // tvOS 18+ requires a fresh dequeue for each index path. Caching
                // and re-returning the same supplementary view raises
                // NSInternalInconsistencyException ("supplementary view that is
                // in the reuse queue").
                let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "stickyHeader", for: indexPath) as! ContinueWatchingCollectionReusableView
                if let parent = parent {
                    header.type = type(of: parent) == MoviesViewController.self ? .movies : .episodes
                }
                continueWatchingCollectionReusableView = header
                header.refreshOnDeck()
                return header
            }
        }
        if kind == UICollectionView.elementKindSectionFooter {
            let footer = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: GridFooterView.reuseIdentifier, for: indexPath) as! GridFooterView
            footer.show(footerState)
            footer.onRetry = { [weak self] in self?.retryNextPage() }
            return footer
        }
        return UICollectionReusableView()
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize {
        // Under the last section of a paginated grid: the next page loading,
        // or the one that failed.
        guard section == dataSources.count - 1 else { return .zero }
        let height = footerState.height
        return height > 0 ? CGSize(width: collectionView.bounds.width, height: height) : .zero
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        if let dataSource = dataSources[safe: section], !dataSource.isEmpty {
            
            if let inset = delegate?.collectionView(collectionView, insetForSectionAt: section) {
                return inset
            }
            
            if isPosterSection(section) {
                // Under a section's title the row starts a little closer:
                // the title already stands apart from what is above.
                let titled = delegate?.collectionView(collectionView, titleForHeaderInSection: section) != nil
                return UIEdgeInsets(top: titled ? GridStyle.titledSectionTop : GridStyle.sectionTop, left: GridStyle.sideInset,
                                    bottom: GridStyle.sectionBottom, right: GridStyle.sideInset)
            }

            let isTv = UIDevice.current.userInterfaceIdiom == .tv
            
            return isTv ? UIEdgeInsets(top: 60, left: 90, bottom: 60, right: 90) : UIEdgeInsets(top: 15, left: 15, bottom: 15, right: 15)
        }
        
        return .zero
    }
    
    override func shouldPerformSegue(withIdentifier identifier: String, sender: Any?) -> Bool {
        guard
            let collectionView = collectionView,
            let cell = sender as? UICollectionViewCell,
            let indexPath = collectionView.indexPath(for: cell),
            let delegate = delegate
            else {
                return true
        }
        return !delegate.collectionView(collectionView, didSelectItemAt: indexPath)
    }
    
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell: BaseCollectionViewCell
        let item = dataSources[indexPath.section][indexPath.row]
        
        if let media = item as? Media {
            let identifier  = media is Movie ? "movieCell" : "showCell"
            let placeholder = media is Movie ? "Movie Placeholder" : "Episode Placeholder"
            
            cell = {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: identifier, for: indexPath) as! CoverCollectionViewCell
                // The artwork and its marks; what the poster is, in words,
                // is the caption of the focused one. VoiceOver reads it on
                // every poster (the cell makes its label from the card),
                // told as the Home tells the title (`HomeTitleFacts`).
                let card = self.card(for: media)
                cell.titleLabel.text = card?.title ?? media.title
                cell.showPoster(card)
                cell.isAccessibilityElement = true
                cell.accessibilityIdentifier = "Grid.Card.\(media.id)"
                
                // The artwork pipeline (UIImageView+Artwork): the poster is
                // downloaded at the size this cell draws it — the focused
                // poster is some 15 % larger — instead of the source's
                // largest, and another address is tried when its own fails.
                cell.imageView.setArtwork(media.smallCoverImage.flatMap { URL(string: $0) },
                                          pointWidth: cell.bounds.width, magnification: 1.15,
                                          placeholder: UIImage(named: placeholder))
                
                return cell
            }()
        } else if let person = item as? Person {
            
            cell = {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "personCell", for: indexPath) as! MonogramCollectionViewCell
                cell.titleLabel.text = person.name
                cell.initialsLabel.text = person.initials
                
                if let image = person.mediumImage,
                    let url = URL(string: image),
                    let request = try? URLRequest(url: url, method: .get) {
                    cell.originalImage = UIImage(named: "Other Placeholder")
                    ImageDownloader.default.download(request, completion: { response in
                        if case .success(let image) = response.result {
                            cell.originalImage = image
                        }
                    })
                } else {
                    cell.originalImage = nil
                }
                
                if let actor = person as? Actor {
                    cell.subtitleLabel.text = actor.characterName
                } else if let crew = person as? Crew {
                    cell.subtitleLabel.text = crew.job
                }
                
                if UIDevice.current.userInterfaceIdiom == .tv {
                    cell.subtitleLabel.text = cell.subtitleLabel.text?.localizedUppercase
                }
                
                return cell
            }()
        } else if let download = item as? PTTorrentDownload {
            cell = {
#if os(tvOS)
                    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "downloadCell", for: indexPath) as! DownloadCollectionViewCell
                    
                    cell.delegate = parent as? DownloadCollectionViewCellDelegate
                    
                    cell.progress = download.torrentStatus.totalProgress
                    cell.downloadState = DownloadButton.State(download.downloadStatus)
                    
                    if let image = download.mediaMetadata[MPMediaItemPropertyArtwork] as? String, let url = URL(string: image) {
                        cell.imageView?.af.setImage(withURL: url)
                    } else {
                        cell.imageView?.image = UIImage(named: "Episode Placeholder")
                    }
                    
                    cell.titleLabel?.text = download.mediaMetadata[MPMediaItemPropertyTitle] as? String
                    cell.blurView.isHidden = download.downloadStatus == .finished
                    
                    return cell
#endif
            }()
        } else {
            fatalError("Unknown type in dataSource.")
        }
        
        cell.isDark = isDark
        
        return cell
    }
    
    override func targetViewController(forAction action: Selector, sender: Any?) -> UIViewController? {
        return activeRootViewController
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if let cell = sender as? UICollectionViewCell,
            let indexPath = collectionView?.indexPath(for: cell) {
            let sender = dataSources[indexPath.section][indexPath.row]

            activeRootViewController?.prepare(for: segue, sender: sender)
        }
    }
}
