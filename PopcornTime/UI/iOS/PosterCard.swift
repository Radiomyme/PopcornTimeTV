

import SwiftUI

/// Generic 2:3 poster + title cell used by the Movies / Shows / Search grids.
/// Loads via `AsyncImage` so it benefits from URLSession HTTP caching and
/// SwiftUI's automatic placeholder shimmer.
struct PosterCard: View {
    let title: String
    let subtitle: String
    let imageURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            posterImage
                .aspectRatio(2/3, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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
