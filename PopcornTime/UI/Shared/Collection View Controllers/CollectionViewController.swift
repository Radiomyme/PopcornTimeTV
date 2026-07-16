

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
}

class CollectionViewController: ResponsiveCollectionViewController, UICollectionViewDelegateFlowLayout {
    
    var dataSources: [[AnyHashable]] = [[]]
    var error: NSError?
    
    let paginationIndicatorInset: CGFloat = 25
    
    func minItemSize(forCellIn collectionView: UICollectionView, at indexPath: IndexPath) -> CGSize {
        if let size = delegate?.minItemSize(forCellIn: collectionView, at: indexPath) {
            return size
        } else {
            return UIDevice.current.userInterfaceIdiom == .tv ? CGSize(width: 250, height: 460) : CGSize(width: 108, height: 185)
        }
    }
    
    var isLoading = false
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
        
        if let collectionView = collectionView,
            let nib = delegate?.collectionView(nibForHeaderInCollectionView: collectionView) {
            collectionView.register(nib, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "stickyHeader")
        }
    }
    
    override func collectionViewDidReloadData(_ collectionView: UICollectionView) {
        super.collectionViewDidReloadData(collectionView)
        
        guard collectionView === self.collectionView else { return }
        
        continueWatchingCollectionReusableView?.refreshOnDeck()
    }
    
    override func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewFlowLayout, didChangeToSize size: CGSize) {
        let itemSize = self.collectionView(collectionView, layout: layout, sizeForItemAt: IndexPath(item: 0, section: 0))
        super.collectionView(collectionView, layout: layout, didChangeToSize: CGSize(width: size.width, height: itemSize.height))
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard let flowLayout = collectionViewLayout as? UICollectionViewFlowLayout else { return .zero }
        
        let minItemSize = self.minItemSize(forCellIn: collectionView, at: indexPath)
        
        var width: CGFloat = 0
        let sectionInset = flowLayout.sectionInset.left + flowLayout.sectionInset.right
        let spacing = flowLayout.scrollDirection == .horizontal ? flowLayout.minimumLineSpacing : flowLayout.minimumInteritemSpacing
        
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
        
        return CGSize(width: width, height: height)
    }
    
    override func numberOfSections(in collectionView: UICollectionView) -> Int {
        collectionView.backgroundView = nil
        guard dataSources.compactMap({$0}).isEmpty else {
            error = nil
            return dataSources.count
        }
        
        if let error = error,
            let background: ErrorBackgroundView = .fromNib() {
            background.setUpView(error: error)
            collectionView.backgroundView = background
        } else if isLoading {
            let view: LoadingView? = .fromNib()
            collectionView.backgroundView = view
            view?.sizeToFit()
        } else {
            delegate?.collectionView(isEmptyForUnknownReason: collectionView)
        }
        
        return 1
    }
    
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return dataSources[safe: section]?.count ?? 0
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        if delegate?.collectionView(collectionView, titleForHeaderInSection: section) != nil {
            return collectionView.numberOfItems(inSection: section) != 0 ? CGSize(width: collectionView.bounds.width, height: 40) : .zero
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
        return UICollectionReusableView()
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize {
        return .zero
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        if let dataSource = dataSources[safe: section], !dataSource.isEmpty {
            
            if let inset = delegate?.collectionView(collectionView, insetForSectionAt: section) {
                return inset
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
                cell.titleLabel.text = media.title
                cell.watched = media.isWatched
                
                
#if os(tvOS)
                    cell.hidesTitleLabelWhenUnfocused = true
#endif
                
                if let image = media.smallCoverImage,
                    let url = URL(string: image) {
                    cell.imageView.af.setImage(withURL: url, placeholderImage: UIImage(named: placeholder), imageTransition: .crossDissolve(.default))
                } else {
                    cell.imageView.image = UIImage(named: placeholder)
                }
                
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
