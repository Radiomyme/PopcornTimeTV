

import SwiftUI
import PopcornKit

/// Sidebar sections of the Mac app.
enum MacSection: String, CaseIterable, Identifiable {
    case movies = "Films"
    case shows = "Séries"
    case watchlist = "Watchlist"
    case search = "Recherche"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .movies: return "film"
        case .shows: return "play.tv"
        case .watchlist: return "bookmark"
        case .search: return "magnifyingglass"
        }
    }
    /// Sidebar label, through Localizable.strings ("Movies" = "Films",
    /// "Watchlist" = "Ma liste"…); `rawValue` is only the id.
    var title: Text {
        switch self {
        case .movies: return Text("Movies")
        case .shows: return Text("Shows")
        case .watchlist: return Text("Watchlist")
        case .search: return Text("Search")
        }
    }
}

/// NavigationSplitView shell: sidebar → grid → detail (pushed on a stack so
/// posters behave like links, same flow as the iOS app). The detail is the
/// Liquid Glass page (MacGlassDetailScreen), as on tvOS.
struct MacRootView: View {
    @State private var section: MacSection = .movies
    /// The detail pages pushed over the section's grid (emptied when the
    /// section changes).
    @State private var path = NavigationPath()
    /// Release notes, shown once per version (not on a fresh install).
    @State private var showWhatsNew = false

    var body: some View {
        // Read here, so that the destinations below get the current depth
        // (a value read only inside their closures can be stale).
        let depth = path.count
        NavigationSplitView {
            List(MacSection.allCases, selection: $section) { item in
                Label { item.title } icon: { Image(systemName: item.symbol) }
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    switch section {
                    case .movies: MacMoviesGridView()
                    case .shows: MacShowsGridView()
                    case .watchlist: MacWatchlistView()
                    case .search: MacSearchView()
                    }
                }
                // A page covered by a pushed one gets no onDisappear, nor
                // onAppear when it is on top again (Back) — the grid neither
                // when the stack is popped to it: they follow the stack's
                // depth instead. Set on each destination: an environment
                // value set around the NavigationStack (or on its root)
                // does not reach the pushed pages.
                .environment(\.macStackDepth, depth)
                .navigationDestination(for: Movie.self) {
                    MacGlassDetailScreen(media: $0).environment(\.macStackDepth, depth)
                }
                .navigationDestination(for: Show.self) {
                    MacGlassDetailScreen(media: $0).environment(\.macStackDepth, depth)
                }
            }
        }
        .onChange(of: section) { _, _ in path = NavigationPath() }
        .task {
            #if DEBUG
            // Verification runs (-PTDebug… launch arguments): no release
            // notes over the page, and the requested section / page.
            if MacDebugHooks.isActive {
                await runDebugHooks()
                return
            }
            #endif
            showWhatsNew = WhatsNewGate.checkAtLaunch(isFreshInstall: WhatsNewGate.looksLikeFreshInstall(),
                                                      launchedFromURL: false)
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView { showWhatsNew = false }
        }
    }

    #if DEBUG
    /// `-PTDebugSection`, then `-PTDebugOpenMovie` / `-PTDebugOpenShow` (pushed
    /// once the section change has emptied the stack; never plays), then the
    /// window size and snapshot hooks (MacDebugHooks).
    @MainActor
    private func runDebugHooks() async {
        await MacDebugHooks.prepareWindow()
        if let requested = MacDebugHooks.section { section = requested }
        if let media = MacDebugHooks.media {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let movie = media as? Movie {
                path.append(movie)
            } else if let show = media as? Show {
                path.append(show)
            }
        }
        MacDebugHooks.scheduleSnapshot()
    }
    #endif
}

// MARK: - Stack depth

private struct MacStackDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// How many pages are pushed over the section's grid (0 = the grid is
    /// on top). In a NavigationSplitView's NavigationStack (seen on macOS
    /// 27), pushing a page over another does not call the covered page's
    /// onDisappear, and popping back does not call its onAppear (nor the
    /// grid's, popped back to it): a view that must know whether it is on
    /// top compares this with its own depth. MacRootView sets it on the
    /// grid and on each pushed page.
    var macStackDepth: Int {
        get { self[MacStackDepthKey.self] }
        set { self[MacStackDepthKey.self] = newValue }
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
