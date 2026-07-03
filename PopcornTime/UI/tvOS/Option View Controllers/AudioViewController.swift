

import Foundation
import PopcornKit
import AVFoundation

enum EqualizerProfiles: UInt32 {
    case fullDynamicRange = 0
    case reduceLoudSounds = 15

    static let array = [fullDynamicRange, reduceLoudSounds]

    var localizedString: String {
        switch self {
        case .fullDynamicRange:
            return "Full Dynamic Range".localized
        case .reduceLoudSounds:
            return "Reduce Loud Sounds".localized
        }
    }
}

class AudioViewController: OptionsStackViewController, UITableViewDataSource {

    let delays = [Int](-60...60)
    let sounds = EqualizerProfiles.array

    /// Audio tracks of the file being played (multi-audio MKVs carry one per
    /// language). Filled by the player before presenting the options panel.
    var audioTrackNames: [String] = []
    var audioTrackIndexes: [Int32] = []
    var currentAudioTrackIndex: Int32 = -1

    var currentDelay = 0
    var currentSound: EqualizerProfiles = .fullDynamicRange

    var manager = AVSpeakerManager()

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(self, selector: #selector(pickableRoutesDidChange), name: .AVSpeakerManagerPickableRoutesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pickableRoutesDidChange), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    @objc func pickableRoutesDidChange() {
        thirdTableView?.reloadData()
    }


    // MARK: Table view data source

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        switch tableView {
        case firstTableView:
            cell.textLabel?.text = audioTrackNames[indexPath.row]
            cell.accessoryType = currentAudioTrackIndex == audioTrackIndexes[indexPath.row] ? .checkmark : .none
            cell.imageView?.image = nil
        case secondTableView:
            let delay = delays[indexPath.row]
            cell.textLabel?.text = (delay > 0 ? "+" : "") + NumberFormatter.localizedString(from: NSNumber(value: delay), number: .decimal)
            cell.accessoryType = currentDelay == delays[indexPath.row] ? .checkmark : .none
            cell.imageView?.image = nil
        case thirdTableView where indexPath.section == 0:
            let sound = sounds[indexPath.row]
            cell.textLabel?.text = sound.localizedString
            cell.accessoryType = currentSound == sound ? .checkmark : .none
            cell.imageView?.image = nil
        case thirdTableView:
            let speaker = manager.speakerRoutes[indexPath.row]
            cell.textLabel?.text = speaker.name
            cell.accessoryType = speaker.isSelected ? .checkmark : .none
            cell.imageView?.image = UIImage(named: "Airplay TV")?.colored(cell.textLabel?.textColor)
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
            return section == 0 ? "Sound".localized : "Speakers".localized
        default:
            return nil
        }
    }

    // MARK: Table view delegate

    func numberOfSections(in tableView: UITableView) -> Int {
        tableView.backgroundView = nil
        if tableView == firstTableView && audioTrackNames.isEmpty {
            let label = UILabel(frame: CGRect(origin: .zero, size: CGSize(width: 200.0, height: 20)))
            tableView.backgroundView = label
            label.text = "No audio tracks available.".localized
            label.textColor = UIColor(white: 1.0, alpha: 0.5)
            label.textAlignment = .center
            label.font = UIFont.systemFont(ofSize: 35.0, weight: UIFont.Weight.medium)
            label.center = tableView.center
            label.sizeToFit()
        }
        return tableView == thirdTableView ? 2 : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch tableView {
        case firstTableView:
            return audioTrackNames.count
        case secondTableView:
            return delays.count
        case thirdTableView:
            return section == 0 ? sounds.count : manager.speakerRoutes.count
        default:
            return 0
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch tableView {
        case firstTableView:
            currentAudioTrackIndex = audioTrackIndexes[indexPath.row]
            delegate?.didSelectAudioTrack(currentAudioTrackIndex)
        case secondTableView:
            currentDelay = delays[indexPath.row]
            delegate?.didSelectAudioDelay(currentDelay)
        case thirdTableView where indexPath.section == 0:
            currentSound = sounds[indexPath.row]
            delegate?.didSelectEqualizerProfile(currentSound)
        case thirdTableView:
            let route = manager.speakerRoutes[indexPath.row]
            manager.select(route: route)
        default:
            break
        }
        tableView.reloadData()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
