

import SwiftUI
import PopcornKit

/// The root of the iOS app: the iOS 26 tab bar on an iPhone (it shrinks while
/// a screen scrolls down, Search is its separate button), a sidebar that can
/// turn into a top bar on an iPad. Home comes first and is the tab the app
/// opens on. Each tab has its own navigation stack (`MediaStack`); which tab
/// shows and what is pushed belong to `AppRouter` — also for the
/// popcorntime:// links the system hands the app.
struct RootTabView: View {
    @State private var router = AppRouter()
    /// Release notes, shown once per version (not on a fresh install, not
    /// over a launch by link).
    @State private var showWhatsNew = false
    @State private var whatsNewCheck = WhatsNewLaunchCheck()

    var body: some View {
        TabView(selection: Bindable(router).selection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                MediaStack(tab: .home) { HomeTabView() }
            }

            Tab("Movies", systemImage: "film.stack", value: AppTab.movies) {
                MediaStack(tab: .movies) { MoviesGridView() }
            }

            Tab("Shows", systemImage: "tv", value: AppTab.shows) {
                MediaStack(tab: .shows) { ShowsGridView() }
            }

            Tab("Watchlist", systemImage: "bookmark", value: AppTab.watchlist) {
                MediaStack(tab: .watchlist) { WatchlistView() }
            }

            Tab(value: AppTab.search, role: .search) {
                MediaStack(tab: .search) { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(router)
        // popcorntime://movie/tt…, show/…, play/…, search?q=…, tab/<name>
        // (PopcornKit's `DeepLink`). Trakt's redirect has the same scheme:
        // it is not one of them and stays `PopcornTimeApp`'s.
        .onOpenURL { url in
            // A link that launched the app: no release notes over its page
            // (they show at the next normal launch).
            if whatsNewCheck.linkOpened() {
                showWhatsNew = false
                // The notes' sheet leaves first: a link to Settings is a
                // sheet too, and only one is presented at a time.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { router.open(url: url) }
                return
            }
            router.open(url: url)
        }
        .task {
            // A link that came while « Who's Watching? » asked (`ProfileGate`
            // held it): opened now that the tabs are here, without the
            // release notes over its page, as for a launch by link.
            if let url = ProfileLaunchQuestion.shared.takeHeldLink() {
                _ = whatsNewCheck.linkOpened()
                router.open(url: url)
            }
            #if DEBUG
            // The verification hooks pick the tab and the page themselves.
            if IOSDebugHooks.isActive {
                IOSDebugHooks.apply(to: router)
                // `-WhatsNewForce YES` still shows the notes over a hooked
                // launch (e.g. the recorded Home of `-PTDebugHomeFixtures`).
                showWhatsNew = UserDefaults.standard.bool(forKey: WhatsNewGate.forceKey)
                return
            }
            #endif
            // A moment for the link of a launch by link (`onOpenURL`) to
            // arrive first; if it comes after, it closes the notes.
            try? await Task.sleep(for: .milliseconds(300))
            showWhatsNew = whatsNewCheck.check(isFreshInstall: WhatsNewGate.looksLikeFreshInstall())
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView { showWhatsNew = false }
        }
        .sheet(isPresented: Bindable(router).showsSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(role: .close) { router.showsSettings = false }
                        }
                    }
            }
        }
    }
}

#Preview {
    RootTabView()
        .preferredColorScheme(.dark)
}
