

import SwiftUI

struct RootTabView: View {
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
    }
}

#Preview {
    RootTabView()
        .preferredColorScheme(.dark)
}
