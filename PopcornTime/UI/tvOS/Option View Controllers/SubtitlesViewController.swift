

import UIKit
import struct PopcornKit.Subtitle

class SubtitlesViewController: OptionsStackViewController, UITableViewDataSource {
    
    /// OpenSubtitles entries.
    var subtitles = [Subtitle]()
    /// The file's own text tracks (VLC track id + name), listed before the
    /// OpenSubtitles entries so the release's subtitles can be picked — or
    /// picked again after an OpenSubtitles file replaced them.
    var embeddedTracks: [(id: String, name: String)] = []
    /// The embedded track on screen; nil when an OpenSubtitles file or
    /// nothing is on.
    var currentEmbeddedTrackId: String?
    /// The user picked an embedded track (its id) or turned it off (nil).
    var didSelectEmbeddedTrack: ((String?) -> Void)?
    let encodings = SubtitleSettings.encodings
    let delays = [Int](-60...60)
    
    var currentSubtitle: Subtitle?
    var currentDelay = 0
    var currentEncoding = SubtitleSettings.shared.encoding {
        didSet {
            let subtitle = SubtitleSettings.shared
            subtitle.encoding = currentEncoding
            subtitle.save()
        }
    }
    

    // MARK: Table view data source
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        switch tableView {
        case firstTableView where indexPath.row < embeddedTracks.count:
            let track = embeddedTracks[indexPath.row]
            cell.textLabel?.text = track.name
            cell.accessoryType = currentEmbeddedTrackId == track.id ? .checkmark : .none
        case firstTableView:
            let subtitle = subtitles[indexPath.row - embeddedTracks.count]
            // Told apart from the file's own tracks when both are listed.
            cell.textLabel?.text = embeddedTracks.isEmpty ? subtitle.language : "\(subtitle.language) (OpenSubtitles)"
            cell.accessoryType = currentSubtitle == subtitle ? .checkmark : .none
        case secondTableView:
            let delay = delays[indexPath.row]
            cell.textLabel?.text = (delay > 0 ? "+" : "") + NumberFormatter.localizedString(from: NSNumber(value: delay), number: .decimal)
            cell.accessoryType = currentDelay == delay ? .checkmark : .none
        case thirdTableView:
            cell.textLabel?.text = Array(encodings.keys)[indexPath.row]
            cell.accessoryType = currentEncoding == Array(encodings.values)[indexPath.row] ? .checkmark : .none
        default:
            break
        }
        cell.contentView.backgroundColor = .clear
        cell.textLabel?.tintColor = .white
        
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch tableView {
        case firstTableView:
            return "Language".localized
        case secondTableView:
            return "Delay".localized
        case thirdTableView:
            return "Encoding".localized
        default:
            return nil
        }
    }
    
    // MARK: Table view delegate
    
    func numberOfSections(in tableView: UITableView) -> Int {
        tableView.backgroundView = nil
        if tableView == firstTableView && subtitles.isEmpty && embeddedTracks.isEmpty {
            let label = UILabel(frame: CGRect(origin: .zero, size: CGSize(width: 200.0, height: 20)))
            tableView.backgroundView = label
            label.text = "No subtitles available.".localized
            label.textColor = UIColor(white: 1.0, alpha: 0.5)
            label.textAlignment = .center
            label.font = UIFont.systemFont(ofSize: 35.0, weight: UIFont.Weight.medium)
            label.center = tableView.center
            label.sizeToFit()
        }
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch tableView {
        case firstTableView:
            return embeddedTracks.count + subtitles.count
        case secondTableView:
            return delays.count
        case thirdTableView:
            return encodings.count
        default:
            return 0
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch tableView {
        case firstTableView where indexPath.row < embeddedTracks.count:
            let id = embeddedTracks[indexPath.row].id
            // The checked row again turns it off.
            currentEmbeddedTrackId = currentEmbeddedTrackId == id ? nil : id
            currentSubtitle = nil
            didSelectEmbeddedTrack?(currentEmbeddedTrackId)
        case firstTableView:
            let subtitle = subtitles[indexPath.row - embeddedTracks.count]
            if currentSubtitle == subtitle { // If row was already selected, user wants to remove the selection.
                currentSubtitle = nil
            } else {
                currentSubtitle = subtitle
            }
            currentEmbeddedTrackId = nil
            delegate?.didSelectSubtitle(currentSubtitle)
        case secondTableView:
            currentDelay = delays[indexPath.row]
            delegate?.didSelectSubtitleDelay(currentDelay)
        case thirdTableView:
            currentEncoding = Array(encodings.values)[indexPath.row]
            delegate?.didSelectEncoding(currentEncoding)
        default:
            break
        }
        tableView.reloadData()
    }
}
