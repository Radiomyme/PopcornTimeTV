

import SwiftUI

struct RootTabView: View {
    /// Release notes, shown once per version (not on a fresh install).
    @State private var showWhatsNew = false

    var body: some View {
        TabView {
            NavigationStack {
                MoviesGridView()
                    .navigationTitle("Films")
            }
            .tabItem { Label("Films", systemImage: "film.stack") }

            NavigationStack {
                ShowsGridView()
                    .navigationTitle("Séries")
            }
            .tabItem { Label("Séries", systemImage: "tv") }

            NavigationStack {
                SearchView()
                    .navigationTitle("Recherche")
            }
            .tabItem { Label("Recherche", systemImage: "magnifyingglass") }

            NavigationStack {
                SettingsView()
                    .navigationTitle("Réglages")
            }
            .tabItem { Label("Réglages", systemImage: "gear") }
        }
        .task {
            showWhatsNew = WhatsNewGate.checkAtLaunch(isFreshInstall: WhatsNewGate.looksLikeFreshInstall(),
                                                      launchedFromURL: false)
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView { showWhatsNew = false }
        }
    }
}

#Preview {
    RootTabView()
        .preferredColorScheme(.dark)
}
