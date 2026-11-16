

import UIKit
import PopcornKit
import AlamofireImage

/// The "Continue Watching" row at the top of the Movies and Shows grids.
///
/// Its cards come from the library (`Library.continueWatching`): the titles
/// played, the most recent first, one card per movie or show — for a show,
/// the episode to resume or, once the last one played was finished, the next
/// one. Nothing is asked from a server to draw them (the row used to send
/// four requests per card at every reload of the grid, and crashed the Shows
/// tab: `Int(id)!` on an episode id): titles are stored with the progress,
/// artwork is derived from the IMDb id. Titles the library only knows by id
/// (played before 5.3) are asked once from Cinemeta and stored.
class ContinueWatchingCollectionReusableView: UICollectionReusableView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {

    @IBOutlet var collectionView: UICollectionView!

    var onDeck = [ContinueWatchingItem]()
    var workItem: DispatchWorkItem!
    var type: Trakt.MediaType!

    /// The most cards the row shows.
    static let limit = 12

    /// The row's cards for a grid: movies on Movies, shows on Shows.
    static func items(for type: Trakt.MediaType?) -> [ContinueWatchingItem] {
        return Library.shared.continueWatching(limit: limit, kinds: type == .movies ? [.movie] : [.show])
    }

    /// Apple TV: three 16:9 cards across the grid's width, not one card of
    /// 850 pt with the rest of the row empty when one title is in progress.
    var minItemSize: CGSize {
        return UIDevice.current.userInterfaceIdiom == .tv ? CGSize(width: 560, height: 315) : CGSize(width: 420, height: 260)
    }

    override var intrinsicContentSize: CGSize {
        if let parentCollectionView = self.superview as? UICollectionView,
            let layout = parentCollectionView.collectionViewLayout as? UICollectionViewFlowLayout {

            let itemHeight = self.collectionView(self.collectionView, layout: layout, sizeForItemAt: IndexPath(item: 0, section: 0)).height
            // The row's own insets (the grid's, 60 pt above and below,
            // were counted: the row was taller than what it shows).
            let section = (self.collectionView.collectionViewLayout as? UICollectionViewFlowLayout)?.sectionInset ?? layout.sectionInset
            let content = self.collectionView.contentInset

            let size   = CGSize(width: parentCollectionView.bounds.width, height: itemHeight + section.top + section.bottom + content.top + content.bottom)

            return self.onDeck.isEmpty ? .min : size
        }
        return .min
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        collectionView.decelerationRate = UIScrollView.DecelerationRate.fast
        collectionView.contentInset.left = 15
        #if os(tvOS)
        // On the grid's own left edge (the page title's, the posters'): the
        // safe area pushed the first card 60 pt to the right of them. And
        // as close to the header and to the first row of posters as a row
        // of posters is (the nib's insets left 60 pt above and below).
        collectionView.contentInsetAdjustmentBehavior = .never
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.sectionInset.top = GridStyle.sectionTop
            layout.sectionInset.bottom = 36
        }
        #endif
        collectionView.register(UINib(nibName: String(describing: ContinueWatchingCollectionViewCell.self), bundle: nil), forCellWithReuseIdentifier: "cell")
        collectionView.accessibilityIdentifier = "ContinueWatching.Row"

        NotificationCenter.default.addObserver(self, selector: #selector(libraryDidChange(_:)), name: .libraryDidChange, object: nil)
    }

    /// A title was played, marked, removed or named while the row is on
    /// screen. (Covered by another screen, the grid refreshes it when it
    /// comes back: `MainViewController.refreshShownContent`.)
    @objc private func libraryDidChange(_ notification: Notification) {
        guard window != nil else { return }
        refreshOnDeck()
    }

    /// Reads the row again, on the next turn of the run loop: the grid asks
    /// while it lays itself out (a header dequeued, `reloadData`), often
    /// several times in a row.
    func refreshOnDeck() {
        workItem?.cancel()
        workItem = DispatchWorkItem { [weak self] in self?.reloadOnDeck() }
        DispatchQueue.main.async(execute: workItem)
    }

    private func reloadOnDeck() {
        let items = ContinueWatchingCollectionReusableView.items(for: type)
        let sameCards = items.map({ $0.imdbID }) == onDeck.map({ $0.imdbID })
        let changed = items != onDeck
        onDeck = items
        if !sameCards {
            collectionView.reloadData()
            layoutSubviews()
        } else if changed {
            // The same cards with another progress, episode or title:
            // reconfigured, not reloaded — a focused card keeps the focus.
            collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
        }
        // Titles known by id only: asked once, then stored (the library
        // posts `.libraryDidChange` when they arrive).
        if !Library.shared.titlesToHydrate().isEmpty {
            Library.shared.hydrateMissingTitles()
        }
    }

    // MARK: - Collection view data source

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return onDeck.isEmpty ? 0 : 1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return onDeck.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! ContinueWatchingCollectionViewCell

        guard let item = onDeck[safe: indexPath.row] else { return cell }
        let placeholder = UIImage(named: item.kind == .movie ? "Movie Placeholder" : "Episode Placeholder")
        let size = self.collectionView(collectionView, layout: collectionView.collectionViewLayout, sizeForItemAt: indexPath)

        cell.titleLabel?.text = item.title ?? ""
        cell.subtitleLabel.text = ContinueWatchingCollectionReusableView.subtitle(for: item)
        cell.progressView.progress = item.progress
        // A next episode not started has nothing to show a bar for.
        cell.progressView.isHidden = item.progress <= 0
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = [cell.titleLabel?.text, cell.subtitleLabel.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        cell.accessibilityIdentifier = "ContinueWatching.Card.\(item.imdbID)"

        // Same card, same picture: a reconfigured cell keeps its image.
        let artwork = item.mediaID
        if cell.artworkID != artwork {
            cell.artworkID = artwork
            // An episode's own still, else the title's backdrop — both
            // derived from the IMDb id, scaled down to the card.
            let backdrop = LibraryArtwork.backdropURL(imdbID: item.imdbID, size: .medium)
            cell.setArtwork([item.episodeStillURL, backdrop].compactMap { $0 }, placeholder: placeholder, size: size)
        }

        return cell
    }

    /// "1 hour, 44 minutes remaining", in the user's language.
    private static let remainingFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        // Apple TV: "Il reste 1 h et 38 min", the Home's short units.
        formatter.unitsStyle = UIDevice.current.userInterfaceIdiom == .tv ? .short : .full
        formatter.includesTimeRemainingPhrase = true
        formatter.allowedUnits = [.hour, .minute]
        return formatter
    }()

    /// Second line of a card. Movie: the time left. Show: "S2 · E5", then
    /// the time left of an episode in progress, or — for the next episode —
    /// "Next episode" and its title.
    static func subtitle(for item: ContinueWatchingItem) -> String {
        // Under a minute left reads "0 minutes remaining": nothing then.
        let remaining = item.progress > 0 ? item.remaining.flatMap { $0 >= 60 ? remainingFormatter.string(from: $0) : nil } : nil
        guard item.kind == .show, let season = item.season, let episode = item.episode else { return remaining ?? "" }
        let number = String(format: "S%lld · E%lld".localized, season, episode)
        let title = item.episodeTitle.flatMap { $0.isEmpty ? nil : $0 }
        switch item.reason {
        case .resume:
            return [number, remaining ?? title].compactMap { $0 }.joined(separator: " · ")
        case .nextUp:
            return ["ContinueWatching.NextEpisode".localized, number, title].compactMap { $0 }.joined(separator: " · ")
        }
    }

    // MARK: - Collection view delegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = onDeck[safe: indexPath.row] else { return }
        // The page loads the title by its id; the title and the poster are
        // what it shows meanwhile.
        let poster = item.posterURL?.absoluteString
        let media: Media
        if item.kind == .movie {
            media = Movie(title: item.title ?? "", id: item.imdbID, largeCoverImage: poster)
        } else {
            media = Show(title: item.title ?? "", id: item.imdbID, largeCoverImage: poster)
        }
        guard let parent = parent as? CollectionViewController,
              let navigationController = parent.activeRootViewController?.navigationController else { return }
        MainViewController.showDetail(of: media, on: navigationController, autoPlay: true)
    }

    // MARK: - Removing a card

    /// Hold Select on a card: its menu, like a poster's — "Remove from on
    /// deck" takes the card out of the row, Menu closes the menu.
    ///
    /// (Until 5.2 a long-press recognizer on the cell asked with an alert.
    /// On tvOS 26 that recognizer never fires — checked with the remote on
    /// the 26.5 simulator, `ContinueWatchingUITests` — so a card could not
    /// be removed at all; the collection view's own menu is what a long
    /// press on Select reaches.)
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let item = onDeck[safe: indexPath.row] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let remove = UIAction(title: "Remove from on deck".localized, image: UIImage(systemName: "minus.circle"),
                                  attributes: .destructive) { [weak self] _ in
                self?.remove(item)
            }
            return UIMenu(title: item.title ?? "", children: [remove])
        }
    }

    private func remove(_ item: ContinueWatchingItem) {
        if item.reason == .resume {
            // Trakt's own playback progress, for an account still linked.
            TraktManager.shared.scrobble(item.mediaID, progress: 0, type: item.kind == .movie ? .movies : .episodes, status: .finished)
        }
        Library.shared.removeFromContinueWatching(item)
        onDeck.removeAll { $0.imdbID == item.imdbID }
        collectionView.reloadData()
        layoutSubviews()
    }
    
    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()


        invalidateIntrinsicContentSize()

        if let parentCollectionView = self.superview as? UICollectionView {
            parentCollectionView.collectionViewLayout.invalidateLayout()
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard let flowLayout = collectionViewLayout as? UICollectionViewFlowLayout else { return .zero }

        let content = collectionView.contentInset
        let section = flowLayout.sectionInset

        let itemSpacing = flowLayout.minimumLineSpacing + content.left + content.right + section.left + section.right

        // Not in a view controller yet (the grid's off-screen sizing copy).
        guard let width = parent?.view.bounds.width ?? superview?.bounds.width else { return minItemSize }
        let estimatedWidth = width - itemSpacing

        if estimatedWidth > minItemSize.width {
            return minItemSize
        }

        let ratio = estimatedWidth/23
        let height = 17 * ratio

        return CGSize(width: estimatedWidth, height: height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        (collectionView.collectionViewLayout as? UICollectionViewFlowLayout)?.minimumLineSpacing = traitCollection.horizontalSizeClass == .regular ? 30 : 10
        layoutSubviews()
    }
}
