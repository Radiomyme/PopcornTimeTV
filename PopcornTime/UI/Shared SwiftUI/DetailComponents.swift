

import SwiftUI
import PopcornKit

/// 5-star rating (half-star aware) shown on the detail screens, mirroring the
/// tvOS layout. `rating` is the API's 0…100 score, so 5 stars = rating / 20.
struct StarRatingView: View {
    let rating: Float

    var body: some View {
        let stars = Double(rating) / 20.0
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: symbol(index: index, stars: stars))
                    .foregroundStyle(.yellow)
            }
            if rating > 0 {
                Text(String(format: "%.1f", rating / 10.0))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }

    private func symbol(index: Int, stars: Double) -> String {
        let base = Double(index)
        if stars >= base + 1 { return "star.fill" }
        if stars >= base + 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// Horizontal cast strip: circular headshots with actor + character name,
/// preceded by the directors as a text line. Matches the tvOS
/// "Directors / Starring" block.
struct CastScroller: View {
    let directors: [String]
    let actors: [Actor]

    var body: some View {
        if !directors.isEmpty || !actors.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Distribution").font(.headline)

                if !directors.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text(directors.count > 1 ? "Réalisation" : "Réalisateur")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(directors.joined(separator: ", "))
                            .font(.caption)
                    }
                }

                if !actors.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(Array(actors.prefix(20).enumerated()), id: \.offset) { _, actor in
                                VStack(spacing: 6) {
                                    AsyncImage(url: (actor.mediumImage ?? actor.smallImage).flatMap { URL(string: $0) }) { phase in
                                        if case .success(let image) = phase { image.resizable().scaledToFill() }
                                        else { avatarPlaceholder(actor.initials) }
                                    }
                                    .frame(width: 72, height: 72)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))

                                    Text(actor.name).font(.caption2.weight(.medium)).lineLimit(1)
                                    Text(actor.characterName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(width: 84)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func avatarPlaceholder(_ initials: String) -> some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.3))
            Text(initials).font(.headline).foregroundStyle(.secondary)
        }
    }
}

/// "Vus aussi" / related titles — a horizontal poster strip. Each poster is a
/// NavigationLink so it pushes another detail screen (the destination is
/// registered on the enclosing NavigationStack in each app).
struct RelatedRow<Item: Media & Hashable>: View {
    let title: String
    let items: [Item]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(items, id: \.self) { item in
                            NavigationLink(value: item) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Color.clear
                                        .aspectRatio(2/3, contentMode: .fit)
                                        .frame(width: 108)
                                        .overlay {
                                            AsyncImage(url: item.smallCoverImage.flatMap { URL(string: $0) }) { phase in
                                                if case .success(let image) = phase { image.resizable().scaledToFill() }
                                                else { Color.gray.opacity(0.25) }
                                            }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    Text(item.title)
                                        .font(.caption2).lineLimit(1)
                                        .frame(width: 108, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
