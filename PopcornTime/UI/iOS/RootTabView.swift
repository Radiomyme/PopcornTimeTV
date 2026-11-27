

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
    /// « Vos langues », once per profile, after the notes and never over
    /// another sheet (`LanguagesLaunchQueue`).
    @State private var showLanguages = false
    @State private var languagesQueue = LanguagesLaunchQueue()

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
            // A link: « Vos langues » closes (or never shows) without being
            // marked — the next launch asks again.
            let closedLanguages = languagesQueue.linkOpened()
            if closedLanguages {
                showLanguages = false
                LanguagesScreenGate.didCloseUnanswered(profileID: ProfileManager.shared.activeID)
            }
            // A link that launched the app: no release notes over its page
            // (they show at the next normal launch).
            if whatsNewCheck.linkOpened() || closedLanguages {
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
                _ = languagesQueue.linkOpened()
                router.open(url: url)
            }
            #if DEBUG
            // The verification hooks pick the tab and the page themselves.
            if IOSDebugHooks.isActive {
                IOSDebugHooks.apply(to: router)
                // `-WhatsNewForce YES` still shows the notes over a hooked
                // launch (e.g. the recorded Home of `-PTDebugHomeFixtures`).
                showWhatsNew = UserDefaults.standard.bool(forKey: WhatsNewGate.forceKey)
                // Only `-PTDebugLanguagesScreen YES` shows « Vos langues » here.
                _ = languagesQueue.check(harness: true)
                updateLanguages()
                return
            }
            #endif
            // A moment for the link of a launch by link (`onOpenURL`) to
            // arrive first; if it comes after, it closes the notes.
            try? await Task.sleep(for: .milliseconds(300))
            showWhatsNew = whatsNewCheck.check(isFreshInstall: WhatsNewGate.looksLikeFreshInstall())
            // (A hooked run returned above: `IOSDebugHooks` is the harness.)
            _ = languagesQueue.check()
            updateLanguages()
        }
        // « Vos langues » waits for the notes and Settings to close.
        .onChange(of: showWhatsNew) { updateLanguages(afterASheet: true) }
        .onChange(of: router.showsSettings) { updateLanguages(afterASheet: true) }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView { showWhatsNew = false }
        }
        .sheet(isPresented: $showLanguages, onDismiss: { languagesQueue.finished() }) {
            LanguagesLaunchSheet { showLanguages = false }
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

    /// Shows « Vos langues » when it is due and no other sheet is up. After
    /// a sheet changed, it waits for that sheet to finish leaving: two
    /// sheets never swap in the same update (as on the Mac).
    private func updateLanguages(afterASheet: Bool = false) {
        guard languagesQueue.pending else { return }
        Task { @MainActor in
            if afterASheet { try? await Task.sleep(for: .milliseconds(400)) }
            if languagesQueue.update(blocked: showWhatsNew || router.showsSettings) { showLanguages = true }
        }
    }
}

#Preview {
    RootTabView()
        .preferredColorScheme(.dark)
}
