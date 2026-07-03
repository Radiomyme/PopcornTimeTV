

import SwiftUI

/// Shared layout constants so the Films, Séries and Recherche grids render at
/// identical, uniform cell sizes. Adaptive columns keep each poster within a
/// tight width band (denser than the old per-screen values) and the same
/// spacing everywhere — one source of truth avoids the grids drifting apart.
enum PosterGrid {
    static let minCellWidth: CGFloat = 140
    static let maxCellWidth: CGFloat = 190
    static let interitemSpacing: CGFloat = 18
    static let lineSpacing: CGFloat = 22

    static let columns = [
        GridItem(.adaptive(minimum: minCellWidth, maximum: maxCellWidth), spacing: interitemSpacing),
    ]
}

/// Generic 2:3 poster + title cell used by the Movies / Shows / Search grids.
/// Loads via `AsyncImage` so it benefits from URLSession HTTP caching and
/// SwiftUI's automatic placeholder shimmer.
struct PosterCard: View {
    let title: String
    let subtitle: String
    let imageURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // `Color.clear` carries a locked 2:3 ratio (width-driven via
            // `.fit`), so every cell is exactly the same size regardless of
            // the source image's own dimensions. The poster is overlaid and
            // clipped to that box — using `.fill` on the image container
            // directly (the previous approach) let each cell's height track
            // its image ratio, producing the uneven grid.
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { posterImage.scaledToFill() }
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)

            // Reserve a fixed 2-line title height + 1 subtitle line so every
            // cell is exactly the same height regardless of how the title
            // wraps. Without this, 1-line vs 2-line titles give cells
            // different heights and the grid rows look ragged.
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(.primary)
                Text(subtitle.isEmpty ? " " : subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var posterImage: some View {
        if let urlString = imageURL, let url = URL(string: urlString) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                switch phase {
                case .empty:
                    placeholder
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemBackground)
            Image(systemName: "film.stack")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
        }
    }
}
