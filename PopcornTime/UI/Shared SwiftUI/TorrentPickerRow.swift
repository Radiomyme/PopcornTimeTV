

import SwiftUI
import PopcornKit

/// One torrent row shared by the iOS and macOS quality pickers, so all
/// platforms present the same information for judging the quality/seeds
/// tradeoff: resolution + codec/HDR/Atmos tags, a health-colored seed
/// indicator with the source (TPB, Knaben · 1337x, a Torrentio indexer…),
/// seed/peer counts and size, and a "Recommandé" badge on the best
/// quality-vs-seeds pick (`Torrent.balancedPick`). The source sits on the
/// second line: appended to a long quality label it was cut off.
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
                        Text("Recommandé")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                HStack(spacing: 0) {
                    if let source = torrent.sourceLabel {
                        Text(verbatim: source)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .layoutPriority(-1)
                        Text(verbatim: " · ")
                    }
                    Text(verbatim: detailLine)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
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

    private var detailLine: String {
        var parts = ["\(torrent.seeds) seeds"]
        if torrent.peers > 0 { parts.append("\(torrent.peers) peers") }
        if let size = torrent.size, !size.isEmpty { parts.append(size) }
        return parts.joined(separator: " · ")
    }
}

extension Torrent {
    /// The recommended (best quality/seeds ratio) URL in a set — used to badge
    /// a row. Nil-safe: returns nil when there's no clear pick.
    static func recommendedURL(in torrents: [Torrent]) -> String? {
        balancedPick(from: torrents)?.url
    }
}
