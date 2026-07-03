

import UIKit
import class PopcornKit.TraktManager
import class PopcornKit.UpdateManager
import protocol PopcornKit.TraktManagerDelegate

class SettingsTableViewController: UITableViewController, TraktManagerDelegate {
    
    @IBAction func done() {
        dismiss(animated: true)
    }
    
    func authenticationDidSucceed() {
        dismiss(animated: true) {
            let alert = UIAlertController(title: "Success".localized, message: "Successfully authenticated with Trakt".localized, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK".localized, style: .cancel, handler: nil))
            self.present(alert, animated: true)
        }
        tableView.reloadData()
        TraktManager.shared.syncUserData()
    }
    
    func authenticationDidFail(with error: NSError) {
        dismiss(animated: true)
        let alert = UIAlertController(title: "Failed to authenticate with Trakt".localized, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK".localized, style: .cancel, handler: nil))
        present(alert, animated: true)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        if UIDevice.current.userInterfaceIdiom == .tv {
            tableView.contentInset.bottom = 27
            applyTvOSCinemaTheme()
            relocateParentTitleIntoBody()
        }

        tableView.remembersLastFocusedIndexPath = true
    }

    /// Inject a cinema-warm gradient (matching the new app icon palette)
    /// into the Settings VC's parent view, and make the grouped table view
    /// transparent so the gradient shows through. The kawaii illustration
    /// in the storyboard's left half (which is owned by the parent VC, not
    /// us) sits naturally on top of this gradient since its PNG already has
    /// a transparent background.
    private func applyTvOSCinemaTheme() {
        // 1) Backdrop on the parent VC's root view (only if we haven't done
        //    it before — viewDidLoad can fire on container re-presentations).
        if let parentView = parent?.view ?? view.superview,
           parentView.viewWithTag(SettingsTableViewController.gradientBgTag) == nil {
            let gradient = CAGradientLayer()
            gradient.colors = [
                UIColor(red: 0.30, green: 0.08, blue: 0.34, alpha: 1.0).cgColor, // plum
                UIColor(red: 0.10, green: 0.04, blue: 0.22, alpha: 1.0).cgColor, // deep
                UIColor(red: 0.08, green: 0.03, blue: 0.18, alpha: 1.0).cgColor, // black-plum
            ]
            gradient.locations = [0.0, 0.55, 1.0]
            gradient.startPoint = CGPoint(x: 0.5, y: 0.0)
            gradient.endPoint   = CGPoint(x: 0.5, y: 1.0)
            // Soft warm glow from the top-right corner — matches the icon.
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.colors = [
                UIColor(red: 1.00, green: 0.55, blue: 0.20, alpha: 0.45).cgColor,
                UIColor(red: 1.00, green: 0.55, blue: 0.20, alpha: 0.0).cgColor,
            ]
            glow.locations = [0.0, 1.0]
            glow.startPoint = CGPoint(x: 0.78, y: 0.18)
            glow.endPoint   = CGPoint(x: 1.6, y: 1.10)

            let container = LayerBackedBackdropView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.tag = SettingsTableViewController.gradientBgTag
            container.tracked = [gradient, glow]
            container.layer.addSublayer(gradient)
            container.layer.addSublayer(glow)
            parentView.insertSubview(container, at: 0)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: parentView.topAnchor),
                container.bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
                container.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
            ])
        }

        // 2) Make the table itself transparent and tone down the system grouped
        //    chrome (the gradient does the heavy lifting now). `separatorColor`
        //    is unavailable on tvOS — separators between cells are drawn by
        //    the focus engine instead, so we just clear the bg.
        tableView.backgroundColor       = .clear
        tableView.backgroundView        = nil
        tableView.separatorInset        = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)

        // 3) Style the section headers (more readable on the gradient).
        // Done lazily in tableView(_:viewForHeaderInSection:); just trigger
        // a layout pass so the appearance hooks below take effect.
        tableView.reloadData()
    }

    private static let gradientBgTag = 0xC1A1
    private static let bodyTitleTag  = 0xC1A2

    /// The Settings page's "Settings" title lives in the parent container
    /// VC's `navigationItem.leftBarButtonItem.customView`. On tvOS 26 that
    /// position overlaps the centered tab pill bar — the title is hidden.
    /// Mirror what `MainViewController.installInBodyHeader` does for
    /// Movies/Shows/Watchlist: pull the title text out of the bar item,
    /// detach the item, and inject a fresh 75pt heavy `UILabel` in the
    /// parent VC's body view at the same Y as Downloads' title (≈190pt
    /// from the top safe area). The illustration + table layout in the
    /// storyboard stay where they are — they're already below this row.
    private func relocateParentTitleIntoBody() {
        guard let parent = parent,
              parent.view.viewWithTag(SettingsTableViewController.bodyTitleTag) == nil else { return }

        var titleText: String? = parent.navigationItem.title
        if titleText == nil,
           let custom = parent.navigationItem.leftBarButtonItem?.customView,
           let label = (custom as? UILabel) ?? custom.subviews.compactMap({ $0 as? UILabel }).first {
            titleText = label.text
        }
        // Default fallback so the page never goes title-less.
        let text = titleText ?? "Settings".localized

        // Detach from the nav bar so tvOS doesn't render a system title
        // alongside our body header (browser-style nav bar would mirror
        // `navigationItem.title` next to the tab pills).
        parent.navigationItem.title = ""
        parent.navigationItem.leftBarButtonItem = nil

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.tag = SettingsTableViewController.bodyTitleTag
        titleLabel.text = text
        titleLabel.font = .systemFont(ofSize: 75, weight: .heavy)
        titleLabel.textColor = .white
        parent.view.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: parent.view.safeAreaLayoutGuide.leadingAnchor, constant: 90),
            titleLabel.topAnchor.constraint(equalTo: parent.view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
    }

    /// Tiny UIView subclass that keeps the frames of its `tracked` CALayers
    /// in sync with its own bounds. CAGradientLayer doesn't autoresize when
    /// added as a sublayer (only when used via `view.layer = CAGradientLayer`).
    private final class LayerBackedBackdropView: UIView {
        var tracked: [CALayer] = []
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in tracked { layer.frame = bounds }
            CATransaction.commit()
        }
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard UIDevice.current.userInterfaceIdiom == .tv else { return }
        // Subtle frosted-card appearance on the cells themselves.
        cell.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        cell.contentView.backgroundColor = .clear
        cell.textLabel?.textColor       = .white
        cell.detailTextLabel?.textColor = UIColor.white.withAlphaComponent(0.65)
        // Focused state already inverts colours by default — leave it.
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard UIDevice.current.userInterfaceIdiom == .tv,
              let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.textColor = UIColor.white.withAlphaComponent(0.55)
        header.textLabel?.font      = .systemFont(ofSize: 28, weight: .semibold)
        header.contentView.backgroundColor = .clear
        // UITableViewHeaderFooterView.backgroundView is the right knob; the
        // generic `view` coming in is the same instance.
        header.backgroundView = UIView()
        header.backgroundView?.backgroundColor = .clear
    }
    
    override func indexPathForPreferredFocusedView(in tableView: UITableView) -> IndexPath? {
        return IndexPath(row: 0, section: 0)
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        
        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                if UIDevice.current.userInterfaceIdiom == .tv {
                    cell.detailTextLabel?.text = NumberFormatter.localizedString(from: NSNumber(value: UserDefaults.standard.float(forKey: "themeSongVolume")), number: .percent)
                } else {
                    cell.detailTextLabel?.text = UserDefaults.standard.bool(forKey: "streamOnCellular") ? "On".localized : "Off".localized
                }
            } else if indexPath.row == 1 {
                cell.detailTextLabel?.text = UserDefaults.standard.bool(forKey: "removeCacheOnPlayerExit") ? "On".localized : "Off".localized
            } else if indexPath.row == 2 {
                cell.detailTextLabel?.text = UserDefaults.standard.string(forKey: "autoSelectQuality") ?? "On".localized /// Auto select quality "On"
            }
        case 1:
            let subtitleSettings = SubtitleSettings.shared
            
            if indexPath.row == 0 {
                cell.detailTextLabel?.text = subtitleSettings.language ?? "None".localized
            } else if indexPath.row == 1 {
                cell.detailTextLabel?.text = subtitleSettings.size.localizedString
            } else if indexPath.row == 2 {
                cell.detailTextLabel?.text = UIColor.systemColors.first(where: {$0 == subtitleSettings.color})?.localizedString ?? ""
            } else if indexPath.row == 3 {
                cell.detailTextLabel?.text = subtitleSettings.font.familyName
            } else if indexPath.row == 4 {
                cell.detailTextLabel?.text = subtitleSettings.style.localizedString
            } else if indexPath.row == 5 {
                cell.detailTextLabel?.text = subtitleSettings.encoding
            }
        case 2 where indexPath.row == 0:
            cell.detailTextLabel?.text = UserDefaults.standard.string(forKey: "preferredAudioLanguage") ?? "None".localized
        case 3 where indexPath.row == 0:
            cell.detailTextLabel?.text = TraktManager.shared.isSignedIn() ? "Sign Out".localized : "Sign In".localized
        case 4:
            if indexPath.row == 1 {
                var date = "Never".localized
                if let lastChecked = UserDefaults.standard.object(forKey: "lastVersionCheckPerformedOnDate") as? Date {
                    date = DateFormatter.localizedString(from: lastChecked, dateStyle: .short, timeStyle: .short)
                }
                cell.detailTextLabel?.text = date
            } else if indexPath.row == 2 {
                cell.detailTextLabel?.text = Bundle.main.localizedVersion
            }
        default:
            break
        }

        return cell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        
        tableView.deselectRow(at: indexPath, animated: true)
        
        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                if UIDevice.current.userInterfaceIdiom == .tv {
                    let handler: (UIAlertAction) -> Void = { action in
                        guard let title = action.title?.replacingOccurrences(of: "%", with: ""),
                            let value = Double(title) else { return }
                        UserDefaults.standard.set(value/100.0, forKey: "themeSongVolume")
                        tableView.reloadData()
                    }
                    
                    let alertController = UIAlertController(title: "Theme Song Volume".localized, message: "Choose a volume for the TV Show and Movie theme songs.".localized, preferredStyle: .actionSheet, blurStyle: .dark)
                    
                    alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                    alertController.addAction(UIAlertAction(title: "Off".localized, style: .default, handler: { action in
                        UserDefaults.standard.set(0.0, forKey: "themeSongVolume")
                        tableView.reloadData()
                    }))
                    
                    alertController.addAction(UIAlertAction(title: NumberFormatter.localizedString(from: NSNumber(value: 0.25), number: .percent), style: .default, handler: handler))
                    alertController.addAction(UIAlertAction(title: NumberFormatter.localizedString(from: NSNumber(value: 0.5), number: .percent), style: .default, handler: handler))
                    alertController.addAction(UIAlertAction(title: NumberFormatter.localizedString(from: NSNumber(value: 0.75), number: .percent), style: .default, handler: handler))
                    alertController.addAction(UIAlertAction(title: NumberFormatter.localizedString(from: NSNumber(value: 1), number: .percent), style: .default, handler: handler))
                    
                    
                    alertController.preferredAction = alertController.actions.first(where: { $0.title == NumberFormatter.localizedString(from: NSNumber(value: UserDefaults.standard.float(forKey: "themeSongVolume")), number: .percent) })
                    
                    present(alertController, animated: true)
                } else {
                    let value = UserDefaults.standard.bool(forKey: "streamOnCellular")
                    UserDefaults.standard.set(!value, forKey: "streamOnCellular")
                    tableView.reloadData()
                }
            } else if indexPath.row == 1 {
                let value = UserDefaults.standard.bool(forKey: "removeCacheOnPlayerExit")
                UserDefaults.standard.set(!value, forKey: "removeCacheOnPlayerExit")
                tableView.reloadData()
            } else if indexPath.row == 2 {
                let alertController = UIAlertController(title: "Auto Select Quality".localized, message: "Choose a default quality. If said quality is available, it will be automatically selected.".localized, preferredStyle: .actionSheet, blurStyle: .dark)
                
                let handler: (UIAlertAction) -> Void = { action in
                    let value = action.title == "Off".localized ? nil : action.title
                    UserDefaults.standard.set(value, forKey: "autoSelectQuality")
                    tableView.reloadData()
                }
                
                alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                
                for quality in ["Off".localized, "Highest".localized, "Lowest".localized] {
                    alertController.addAction(UIAlertAction(title: quality, style: .default, handler: handler))
                }
                
                alertController.preferredAction = alertController.actions.first(where: { $0.title == UserDefaults.standard.string(forKey: "autoSelectQuality") ?? "Off".localized })
                
                alertController.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
                
                present(alertController, animated: true)
            }
        case 1:
            let subtitleSettings = SubtitleSettings.shared
            if indexPath.row == 0 {
                let alertController = UIAlertController(title: "Subtitle Language".localized, message: "Choose a default language for the player subtitles.".localized, preferredStyle: .actionSheet, blurStyle: .dark)
                
                let handler: (UIAlertAction) -> Void = { action in
                    subtitleSettings.language = action.title == "None".localized ? nil : action.title!
                    subtitleSettings.save()
                    tableView.reloadData()
                }
                
                alertController.addAction(UIAlertAction(title: "None".localized, style: .default, handler: handler))
                alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                
                for language in Locale.commonLanguages {
                    alertController.addAction(UIAlertAction(title: language, style: .default, handler: handler))
                }
                
                alertController.preferredAction = alertController.actions.first(where: { $0.title == subtitleSettings.language }) ?? alertController.actions.first(where: { $0.title == "None".localized })
                
                alertController.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
                
                present(alertController, animated: true)
            } else if indexPath.row == 1 {
                let alertController = UIAlertController(title: "Subtitle Font Size".localized, message: "Choose a font size for the player subtitles.".localized, preferredStyle: .actionSheet, blurStyle: .dark)
                
                alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                
                let handler: (UIAlertAction) -> Void = { action in
                    subtitleSettings.size = SubtitleSettings.Size.array.first(where: {$0.localizedString == action.title})!
                    subtitleSettings.save()
                    tableView.reloadData()
                }
                
                for size in SubtitleSettings.Size.array {
                    alertController.addAction(UIAlertAction(title: size.localizedString, style: .default, handler: handler))
                }
                
                alertController.preferredAction = alertController.actions.first(where: { $0.title == subtitleSettings.size.localizedString })
                
                alertController.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
                
                present(alertController, animated: true)
            } else if indexPath.row == 2 {
                let alertController = UIAlertController(title: "Subtitle Color".localized, message: "Choose text color for the player subtitles.".localized, preferredStyle: .actionSheet, blurStyle: .dark)
                
                let handler: (UIAlertAction) -> Void = { action in
                    subtitleSettings.color = UIColor.systemColors.first(where: {$0.localizedString == action.title})!
                    subtitleSettings.save()
                    tableView.reloadData()
                }
                
                alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                
                for title in UIColor.systemColors.compactMap({$0.localizedString}) {
                    alertController.addAction(UIAlertAction(title: title, style: .default, handler: handler))
                }
                
                alertController.preferredAction = alertController.actions.first(where: { $0.title == subtitleSettings.color.localizedString })
                
                alertController.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
                
                present(alertController, animated: true)
            } else if indexPath.row == 3 {
                let alertController = UIAlertController(title: "Subtitle Font".localized, message: "Choose a default font for the player subtitles.".localized, preferredStyle: .actionSheet, blurStyle: .dark)
                
                let handler: (UIAlertAction) -> Void = { action in
                    guard let familyName = action.title,
                        let fontName = UIFont.fontNames(forFamilyName: familyName).first,
                        let font = UIFont(name: fontName, size: 16) else { return }
                    subtitleSettings.font = font
                    subtitleSettings.save()
                    tableView.reloadData()
                }
                
                alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                
                for language in UIFont.familyNames {
                    alertController.addAction(UIAlertAction(title: language, style: .default, handler: handler))
                }
                
                alertController.preferredAction = alertController.actions.first(where: { $0.title == subtitleSettings.font.familyName })
                
                alertController.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
                
                present(alertController, animated: true)
            } else if indexPath.row == 4 {
                
                let alertController = UIAlertController(title: "Subtitle Font Style".localized, message: "Choose a default font style for the player subtitles.".localized, preferredStyle: .actionSheet, blurStyle: .dark)
                
                alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                
                for style in UIFont.Style.arrayValue {
                    let action = UIAlertAction(title: style.localizedString, style: .default) { _ in
                        subtitleSettings.style = style
                        subtitleSettings.save()
                        tableView.reloadData()
                    }
                    
                    alertController.addAction(action)
                }
                
                alertController.preferredAction = alertController.actions.first(where: { $0.title == subtitleSettings.style.localizedString })
                
                alertController.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
                
                present(alertController, animated: true)
            } else if indexPath.row == 5 {
                let keys   = Array(SubtitleSettings.encodings.keys)
                let values = Array(SubtitleSettings.encodings.values)
                
                let alertController = UIAlertController(title: "Subtitle Encoding".localized, message: "Choose encoding for the player subtitles.".localized, preferredStyle: .actionSheet, blurStyle: .dark)
                
                alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                
                for title in keys {
                    let action = UIAlertAction(title: title, style: .default) { _ in
                        subtitleSettings.encoding = values[keys.firstIndex(of: title)!]
                        subtitleSettings.save()
                        tableView.reloadData()
                    }
                    alertController.addAction(action)
                }
                
                alertController.preferredAction = alertController.actions.first(where: { $0.title == keys[values.firstIndex(of: subtitleSettings.encoding)!] })
                
                alertController.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
                
                present(alertController, animated: true)
            }
        case 2 where indexPath.row == 0:
            let alertController = UIAlertController(title: "Audio Language".localized, message: "Choose a preferred audio language. When the file carries a matching audio track, it will be selected automatically.".localized, preferredStyle: .actionSheet, blurStyle: .dark)

            let handler: (UIAlertAction) -> Void = { action in
                let value = action.title == "None".localized ? nil : action.title
                UserDefaults.standard.set(value, forKey: "preferredAudioLanguage")
                tableView.reloadData()
            }

            alertController.addAction(UIAlertAction(title: "None".localized, style: .default, handler: handler))
            alertController.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))

            for language in Locale.commonLanguages {
                alertController.addAction(UIAlertAction(title: language, style: .default, handler: handler))
            }

            let current = UserDefaults.standard.string(forKey: "preferredAudioLanguage")
            alertController.preferredAction = alertController.actions.first(where: { $0.title == current }) ?? alertController.actions.first(where: { $0.title == "None".localized })

            alertController.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)

            present(alertController, animated: true)
        case 3 where indexPath.row == 0:
            if TraktManager.shared.isSignedIn() {
                let alert = UIAlertController(title: "Sign Out".localized, message: "Are you sure you want to Sign Out?".localized, preferredStyle: .alert)
                
                alert.addAction(UIAlertAction(title: "Sign Out".localized, style: .destructive, handler: { action in
                    do { try TraktManager.shared.logout() } catch { }
                    tableView.reloadData()
                }))
                alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                present(alert, animated: true)
            } else {
                TraktManager.shared.delegate = self
                let vc = TraktManager.shared.loginViewController()
                present(vc, animated: true)
            }
        case 4:
            if indexPath.row == 0 {
                let controller = UIAlertController(title: nil, message: nil, preferredStyle: .alert)
                controller.addAction(UIAlertAction(title: "OK".localized, style: .cancel, handler: nil))
                do {
                    let size = FileManager.default.folderSize(atPath: NSTemporaryDirectory())
                    for path in try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()) {
                        try FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "/\(path)")
                    }
                    controller.title = "Success".localized
                    if size == 0 {
                        controller.message = "Cache was already empty, no disk space was reclaimed.".localized
                    } else {
                        controller.message = "Cleaned".localized + " \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))."
                    }
                } catch {
                    controller.title = "Failed".localized
                    controller.message = "Error cleaning cache.".localized
                }
                present(controller, animated: true)
            } else if indexPath.row == 1 {
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .alert)
                let contentViewController = UIStoryboard.main.instantiateViewController(withIdentifier: "CheckForUpdatesViewController")
                alert.setValue(contentViewController, forKey: "contentViewController")
                alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel, handler: nil))
                present(alert, animated: true)
                UpdateManager.shared.checkVersion(.immediately) { [weak self] success in
                    alert.dismiss(animated: true) {
                        if !success {
                            let alert = UIAlertController(title: "No Updates Available".localized, message: "There are no updates available for Popcorn Time at this time.".localized, preferredStyle: .alert)
                            alert.addAction(UIAlertAction(title: "OK".localized, style: .default, handler: nil))
                            self?.present(alert, animated: true)
                        }
                        tableView.reloadData() 
                    }
                }
            }
        default:
            break
        }
    }
}
