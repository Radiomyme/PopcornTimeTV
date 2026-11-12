

import SwiftUI
import PopcornKit

/// One torrent row shared by the iOS and macOS quality pickers, so all
/// platforms present the same information for judging the quality/seeds
/// tradeoff: resolution + codec/HDR/Atmos tags, a health-colored seed
/// indicator with the source (TPB, Knaben · 1337x, a Torrentio indexer…),
/// seed/peer counts, size and estimated bitrate ("≈ 72 Mb/s", when the
/// torrent carries its media runtime: `Torrent.withMediaRuntime`), a
/// "Recommandé" badge on the best quality-vs-seeds-vs-connection pick
/// (`Torrent.balancedPick`), and an orange warning on a release likely too
/// heavy for the connection (`Torrent.bandwidthWarning`). The source sits on
/// the second line: appended to a long quality label it was cut off.
struct TorrentPickerRow: View {
    let torrent: Torrent
    /// Whether this is the recommended (best ratio) torrent in its set.
    let recommended: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Swarm-health dot (red→green), same scale the tvOS list uses.
            Circle()
                .fill(Color(cgColor: torrent.health.color.cgColor))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: torrent.qualityLabel.isEmpty ? "—" : torrent.qualityLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if recommended {
                        Text(verbatim: NSLocalizedString("Picker.Recommended", value: "Recommended",
                                                         comment: "Quality picker: badge of the recommended release"))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                // One text that wraps (two lines at most) rather than two
                // that truncate: on an iPhone in portrait the source used to
                // vanish and the bitrate to be cut.
                Text(detailText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let warning = torrent.bandwidthWarning() {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.tint)
                .font(.title2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// "Knaben · 1337x · 120 seeds · 9.52 GB · ≈ 23 Mb/s", the source in semibold.
    private var detailText: AttributedString {
        var text = AttributedString()
        if let source = torrent.sourceLabel {
            var bold = AttributedString(source)
            bold.inlinePresentationIntent = .stronglyEmphasized
            text += bold
            text += AttributedString(" · ")
        }
        text += AttributedString(detailLine)
        return text
    }

    private var detailLine: String {
        var parts = ["\(torrent.seeds) seeds"]
        if torrent.peers > 0 { parts.append("\(torrent.peers) peers") }
        if let size = torrent.size, !size.isEmpty { parts.append(size) }
        if let bitrate = torrent.bitrateLabel { parts.append(bitrate) }
        return parts.joined(separator: " · ")
    }
}

extension Torrent {
    /// The recommended (best quality/seeds ratio the connection can carry)
    /// URL in a set — used to badge a row. Nil-safe: returns nil when there's
    /// no clear pick. Also starts measuring the connection
    /// (`ConnectionSpeed.start`, idempotent): a stream follows a pick.
    static func recommendedURL(in torrents: [Torrent]) -> String? {
        ConnectionSpeed.shared.start()
        return balancedPick(from: torrents)?.url
    }
}
