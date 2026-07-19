

import SwiftUI
import PopcornKit

/// Sidebar sections of the Mac app.
enum MacSection: String, CaseIterable, Identifiable {
    case movies = "Films"
    case shows = "Séries"
    case search = "Recherche"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .movies: return "film"
        case .shows: return "play.tv"
        case .search: return "magnifyingglass"
        }
    }
}

/// NavigationSplitView shell: sidebar → grid → detail (pushed on a stack so
/// posters behave like links, same flow as the iOS app).
struct MacRootView: View {
    @State private var section: MacSection = .movies

    var body: some View {
        NavigationSplitView {
            List(MacSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            NavigationStack {
                Group {
                    switch section {
                    case .movies: MacMoviesGridView()
                    case .shows: MacShowsGridView()
                    case .search: MacSearchView()
                    }
                }
                .navigationDestination(for: Movie.self) { MacMediaDetailView(media: $0) }
                .navigationDestination(for: Show.self) { MacMediaDetailView(media: $0) }
            }
        }
    }
}

// MARK: - Poster grid building blocks (Mac variant of PosterCard/PosterGrid)

enum MacPosterGrid {
    static let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 18)]
}

struct MacPosterCard: View {
    let title: String
    let subtitle: String
    let imageURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    AsyncImage(url: imageURL.flatMap { URL(string: $0) }) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        default: Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary)
                        }
                    }
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle.isEmpty ? " " : subtitle)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(.primary)
            }
        }
    }
}
