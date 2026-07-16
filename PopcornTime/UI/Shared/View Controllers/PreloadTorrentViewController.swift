

import UIKit
import PopcornTorrent
import QuartzCore

class PreloadTorrentViewController: UIViewController {

    @IBOutlet var progressView: UIProgressView!
    @IBOutlet var speedLabel: UILabel!
    @IBOutlet var seedsLabel: UILabel!
    @IBOutlet var titleLabel: UILabel!
    @IBOutlet var processingView: UIView!

    @IBOutlet var backgroundImageView: UIImageView?

    var streamer: PTTorrentStreamer!

    /// Numeric buffering % + a rough ETA until playback can start, shown just
    /// below the existing progress bar / speed / seeds block. Built in code so
    /// it needs no storyboard outlet.
    private lazy var etaLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 1
        label.font = .systemFont(ofSize: 30, weight: .semibold)
        label.shadowColor = UIColor.black.withAlphaComponent(0.6)
        label.shadowOffset = CGSize(width: 0, height: 1)
        label.isHidden = true
        return label
    }()
    private var lastSample: (progress: Float, time: CFTimeInterval)?
    private var rateEMA: Double = 0

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(etaLabel)
        // Anchor under the container that holds the progress bar + speed/seeds
        // labels so it can't overlap them; fall back to the progress bar.
        let anchorView: UIView = progressView.superview ?? progressView
        NSLayoutConstraint.activate([
            etaLabel.centerXAnchor.constraint(equalTo: anchorView.centerXAnchor),
            etaLabel.topAnchor.constraint(equalTo: anchorView.bottomAnchor, constant: 16),
            etaLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            etaLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
        ])
    }

    var progress: Float = 0.0 {
        didSet {
            progressView.isHidden = false
            processingView.isHidden = true
            progressView.progress = progress
            updateETA(progress)
        }
    }

    var speed: Int = 0 {
        didSet {
            speedLabel.isHidden = false
            speedLabel.text = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .binary) + "/s"
        }
    }

    var seeds: Int = 0 {
        didSet {
            seedsLabel.isHidden = false
            seedsLabel.text = "\(seeds) " + "Seeds".localized.localizedLowercase
        }
    }

    /// Show buffering % and a smoothed ETA (from the rate of the buffering
    /// progress) until playback can start.
    private func updateETA(_ progress: Float) {
        etaLabel.isHidden = false
        let percent = max(0, min(1, progress))

        let now = CACurrentMediaTime()
        var etaText = ""
        if let last = lastSample, now > last.time, percent >= last.progress {
            let instantRate = Double(percent - last.progress) / (now - last.time) // fraction / sec
            if instantRate > 0 {
                rateEMA = rateEMA == 0 ? instantRate : (0.7 * rateEMA + 0.3 * instantRate)
            }
            if rateEMA > 0.0001 {
                let eta = Double(1 - percent) / rateEMA
                if eta.isFinite, eta > 0, eta < 3600 {
                    etaText = " · " + "Time remaining".localized + " ~" + formatETA(eta)
                }
            }
        }
        lastSample = (percent, now)

        etaLabel.text = String(format: "%.0f%%%@", percent * 100, etaText)
    }

    private func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }

    @IBAction func cancel() {
        streamer.cancelStreamingAndDeleteData(false)
        dismiss(animated: true)
    }

}
