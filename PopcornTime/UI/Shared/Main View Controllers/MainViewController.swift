

import UIKit
import PopcornKit
import PopcornTorrent.PTTorrentDownloadManager
import MediaPlayer.MPMediaItem

class MainViewController: UIViewController, CollectionViewControllerDelegate {
    
    func load(page: Int) {}
    func collectionView(isEmptyForUnknownReason collectionView: UICollectionView) {}
    func collectionView(_ collectionView: UICollectionView, titleForHeaderInSection section: Int) -> String? { return nil }
    func collectionView(nibForHeaderInCollectionView collectionView: UICollectionView) -> UINib? { return nil }
    
    func minItemSize(forCellIn collectionView: UICollectionView, at indexPath: IndexPath) -> CGSize? { return nil }
    func collectionView(_ collectionView: UICollectionView, insetForSectionAt section: Int) -> UIEdgeInsets? { return nil }
    
    
    var collectionViewController: CollectionViewController!
    
    var collectionView: UICollectionView? {
        get {
            return collectionViewController?.collectionView
        } set(newObject) {
            collectionViewController?.collectionView = newObject
        }
    }
    
    var environmentsToFocus: [UIFocusEnvironment] = []

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return environmentsToFocus.isEmpty ? super.preferredFocusEnvironments : environmentsToFocus
    }

    #if os(tvOS)
    /// Tracks whether we've already injected the in-body header. viewDidLoad
    /// can fire repeatedly when the VC is removed/re-added (e.g. tab switch
    /// + memory pressure), so we de-dup.
    private var didInstallInBodyHeader: Bool = false

    /// Reference to the in-body title label so subclasses can update it
    /// (e.g. `MediaViewController.showGenres` rewrites the title to the
    /// current genre when the user filters).
    var bodyTitleLabel: UILabel?

    /// On tvOS 26 the centered tab-bar pills live in the same vertical strip
    /// as `navigationItem.leftBarButtonItem` and `rightBarButtonItems`,
    /// hiding the giant page title + Sort/Genre under them. The Downloads
    /// page never had this problem — its "Downloads" label is laid out as a
    /// regular subview at body y≈190, well below the pills. We mirror that
    /// approach for every `MainViewController` subclass: read the page
    /// title from `navigationItem.title` (set via storyboard or by the
    /// subclass), clear it so the system doesn't render its own copy
    /// alongside the pills, and inject a fresh body header at the top of
    /// the view with the title + Sort/Genre buttons.
    ///
    /// `responds(to:)` filters: Movies & Shows expose `showFilters:` and
    /// `showGenres:`; Watchlist / Settings have neither so they get the
    /// title only, no buttons.
    func installInBodyHeader() {
        guard !didInstallInBodyHeader else { return }
        didInstallInBodyHeader = true

        // 1) Extract title text. Storyboard sets `navigationItem.title`
        //    statically for Movies/Shows/Watchlist/Settings; subclasses
        //    (PersonViewController) set it before calling super. As a
        //    legacy fallback, read the customView label still in the bar
        //    item (Person hasn't been migrated).
        var titleText: String? = navigationItem.title
        if titleText == nil,
           let custom = navigationItem.leftBarButtonItem?.customView,
           let label = (custom as? UILabel) ?? custom.subviews.compactMap({ $0 as? UILabel }).first {
            titleText = label.text
        }

        // 2) Detach the legacy chrome so tvOS doesn't render its own copy
        //    of the title (browser-style nav bar would mirror
        //    `navigationItem.title` next to the tab pills).
        navigationItem.title = ""
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItems = nil

        // 3) Build the in-body header.
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        if let text = titleText {
            let titleLabel = UILabel()
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.text = text
            titleLabel.font = .systemFont(ofSize: 75, weight: .heavy)
            titleLabel.textColor = .white
            titleLabel.adjustsFontSizeToFitWidth = false
            header.addSubview(titleLabel)
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ])
            self.bodyTitleLabel = titleLabel
        }

        var rightButtons: [UIButton] = []
        let sortSel = NSSelectorFromString("showFilters:")
        if responds(to: sortSel) { rightButtons.append(makeCapsuleButton(title: "Sort".localized, action: sortSel)) }
        let genreSel = NSSelectorFromString("showGenres:")
        if responds(to: genreSel) { rightButtons.append(makeCapsuleButton(title: "Genre".localized, action: genreSel)) }

        if !rightButtons.isEmpty {
            let stack = UIStackView(arrangedSubviews: rightButtons)
            stack.axis = .horizontal
            stack.spacing = 28
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            ])
        }

        // 4) Pin the header just below the tab pill bar (safe area top
        //    already accounts for the pills on tvOS 26). 16pt is enough
        //    breathing room for the descenders without leaving a void.
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 90),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -90),
            header.heightAnchor.constraint(equalToConstant: 100),
        ])

        // 5) Push the collection view's content below the header.
        //    Header (100) + breathing room above (16) and below (~30) +
        //    extra padding so the focus zoom on the first row clears
        //    the header → 150pt.
        let topInset: CGFloat = 150
        collectionView?.contentInset.top = topInset
        collectionView?.verticalScrollIndicatorInsets.top = topInset
    }

    /// Update the in-body title label. Used by `MediaViewController`
    /// when the user picks a genre filter.
    func setBodyTitle(_ text: String) {
        bodyTitleLabel?.text = text
    }

    private func makeCapsuleButton(title: String, action: Selector) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 32, bottom: 14, trailing: 32)
        config.baseForegroundColor = .white
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 26, weight: .semibold)
            return out
        }
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: action, for: .primaryActionTriggered)
        return btn
    }
    #endif
    
    override dynamic func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        navigationController?.navigationBar.tintColor = .app
    }
    
    override dynamic func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        
        environmentsToFocus.removeAll()
        
        collectionView?.setNeedsFocusUpdate()
        collectionView?.updateFocusIfNeeded()
        
        collectionView?.reloadData()
    }

    override dynamic func viewDidLoad() {
        super.viewDidLoad()

        collectionViewController.paginated = true
        load(page: 1)

        #if os(tvOS)
        installInBodyHeader()
        #endif
    }
    
    func didRefresh(collectionView: UICollectionView) {
        collectionViewController.dataSources = [[]]
        collectionView.reloadData()
        load(page: 1)
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "embed", let vc = segue.destination as? CollectionViewController {
            collectionViewController = vc
            collectionViewController.delegate = self
        } else if let segue = segue as? AutoPlayStoryboardSegue,
            segue.identifier == "showMovie" || segue.identifier == "showShow",
            let media: Media = sender as? Movie ?? sender as? Show,
            let vc = storyboard?.instantiateViewController(withIdentifier: String(describing: DetailViewController.self)) as? DetailViewController {
            
#if os(tvOS)

                if let destination = segue.destination as? TVLoadingViewController {
                    destination.loadView() // Initialize the @IBOutlets
                    
                    if let image = media.smallCoverImage, let url = URL(string: image) {
                        destination.backgroundImageView.af.setImage(withURL: url)
                    }
                    
                    destination.titleLabel.text = media.title
                }
            
#endif
            
            // Exact same storyboard UI is being used for both classes. This will enable subclass-specific functions however, stored instance variables have to be set using `object_setIvar` otherwise there will be weird malloc crashes.
            object_setClass(vc, media is Movie ? MovieDetailViewController.self : ShowDetailViewController.self)
            
            
            vc.loadMedia(id: media.id) { (media, error) in
                guard let navigationController = segue.destination.navigationController,
                    navigationController.visibleViewController === segue.destination // Make sure we're still loading and the user hasn't dismissed the view.
                    else { return }
                
                
                let transition = CATransition()
                transition.duration = 0.5
                transition.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
                transition.type = CATransitionType.fade
                navigationController.view.layer.add(transition, forKey: nil)
                
                defer {
                    DispatchQueue.main.asyncAfter(deadline: .now() + transition.duration) {
                        var viewControllers = navigationController.viewControllers
                        if let index = viewControllers.firstIndex(where: {$0 === segue.destination}) {
                            viewControllers.remove(at: index)
                            navigationController.setViewControllers(viewControllers, animated: false)
                        }
                        
                        if let media = (media as? Show)?.latestUnwatchedEpisode() ?? media, segue.shouldAutoPlay {
                            AppDelegate.shared.chooseQuality(nil, media: media) { torrent in
                                AppDelegate.shared.play(media, torrent: torrent)
                            }
                        }
                    }
                }
                
                if let error = error {
                    let vc = UIViewController()
                    let view: ErrorBackgroundView? = .fromNib()
                    
                    view?.setUpView(error: error)
                    vc.view = view
                    
                    navigationController.pushViewController(vc, animated: false)
                } else if let currentItem = media {
                    vc.currentItem = currentItem
                    navigationController.pushViewController(vc, animated: false)
                }
            }
        } else if segue.identifier == "showPerson",
            let vc = segue.destination as? PersonViewController,
            let person: Person = sender as? Crew ?? sender as? Actor {
            vc.currentItem = person
        }
    }
}
