

import SwiftUI
import PopcornKit

/// The Mac quality sheet's row, with the facts the iOS Sources list gives
/// for judging the quality/seeds tradeoff: resolution + codec/HDR/Atmos
/// tags, a health-colored seed indicator when the swarm's health is known,
/// the source (TPB, Knaben · 1337x, a Torrentio indexer…), the localized
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
            // Swarm-health dot (red→green), same scale the tvOS list uses;
            // none for a scraped release whose health nobody knows (a grey
            // dot on every row said nothing).
            if torrent.health != .unknown {
                Circle()
                    .fill(Color(cgColor: torrent.health.color.cgColor))
                    .frame(width: 9, height: 9)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: torrent.qualityLabel.isEmpty ? "—" : torrent.qualityLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Nothing on this line may cut the quality first.
                        .layoutPriority(1)
                    if recommended {
                        Text(verbatim: NSLocalizedString("Picker.Recommended", value: "Recommended",
                                                         comment: "Quality picker: badge of the recommended release"))
                            .font(.caption2.weight(.bold))
                            .lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(GlassPalette.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                // One text that wraps (two lines at most) rather than two
                // that truncate: on an iPhone in portrait the source used to
                // vanish and the bitrate to be cut.
                // The audio language leads the metadata line, not the title
                // line: beside the title it cut the quality name.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let tag = torrent.languageTag {
                        LanguageTag(token: tag.token, spoken: tag.spoken)
                    }
                    Text(detailText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let warning = torrent.bandwidthWarning() {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
            // The app's red, as on the iPhone: not the system accent.
            Image(systemName: "play.circle.fill")
                .foregroundStyle(GlassPalette.accent)
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

    private var detailLine: String { torrent.pickerDetail }
}

/// The audio language of a release at the head of a quality row's metadata
/// line ("FR", "MULTI": `Torrent.languageTag`), with the look of the Home's
/// format tags (small outlined capitals) at caption size. Shared by
/// `TorrentPickerRow` and the iOS `SourceRow`; VoiceOver reads "Audio in
/// French", not the letters.
struct LanguageTag: View {
    let token: String
    let spoken: String

    var body: some View {
        Text(verbatim: token)
            .font(.caption2.weight(.heavy))
            .tracking(0.3)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.secondary.opacity(0.7), lineWidth: 0.75))
            .fixedSize()
            .accessibilityLabel(Text(verbatim: spoken))
    }
}

extension Torrent {
    /// "178 sources · 12 pairs · 7,19 Go · ≈ 7 Mb/s": the swarm, the size
    /// and the bitrate in the UI's language (`Sources.Seeds`, `.Peers`, the
    /// system's byte units and decimal mark). The iPhone's Sources rows and
    /// the Mac's quality sheet.
    var pickerDetail: String {
        var parts: [String] = []
        // YTS lists 100 / 100 for a release it has no count for.
        let placeholder = seeds == 100 && peers == 100
        if !placeholder {
            parts.append(String(format: "Sources.Seeds".localized, seeds))
            if peers > 0 { parts.append(String(format: "Sources.Peers".localized, peers)) }
        }
        if let bytes = sizeInBytes, bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        } else if let size = size, !size.isEmpty {
            parts.append(size)
        }
        if let bitrate = bitrateLabel { parts.append(bitrate) }
        return parts.joined(separator: " · ")
    }

    /// The recommended (best quality/seeds ratio the connection can carry)
    /// URL in a set — used to badge a row. Nil-safe: returns nil when there's
    /// no clear pick. Also starts measuring the connection
    /// (`ConnectionSpeed.start`, idempotent): a stream follows a pick.
    static func recommendedURL(in torrents: [Torrent]) -> String? {
        ConnectionSpeed.shared.start()
        return balancedPick(from: torrents)?.url
    }
}
