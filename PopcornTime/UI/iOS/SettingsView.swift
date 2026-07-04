

import SwiftUI
import PopcornKit

struct SettingsView: View {
    @AppStorage("autoSelectQuality") private var autoSelectQuality = "Balanced"
    @AppStorage("streamOnCellular")  private var streamOnCellular  = false
    @State private var traktAuthURL: IdentifiableURL?
    @State private var isTraktSignedIn = TraktManager.shared.isSignedIn()

    var body: some View {
        Form {
            Section("Lecture") {
                Picker("Qualité automatique", selection: $autoSelectQuality) {
                    Text("Équilibré (démarrage rapide)").tag("Balanced")
                    Text("La plus haute").tag("Highest")
                    Text("La plus basse").tag("Lowest")
                    Text("Choisir à chaque fois").tag("")
                }
                .pickerStyle(.menu)

                Toggle("Streamer en données mobiles", isOn: $streamOnCellular)
            }

            Section("Compte Trakt") {
                if isTraktSignedIn {
                    Label("Connecté à Trakt", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button(role: .destructive) {
                        try? TraktManager.shared.logout()
                        isTraktSignedIn = TraktManager.shared.isSignedIn()
                    } label: {
                        Label("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Button {
                        traktAuthURL = IdentifiableURL(url: TraktManager.shared.iOSAuthorizationURL())
                    } label: {
                        Label("Se connecter à Trakt", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }

            Section("Sources") {
                LabeledContent("API Films", value: "movies-api.accel.li")
                LabeledContent("API Séries", value: "eztvx.to (+ miroirs)")
                LabeledContent("Métadonnées", value: "TVMaze + TMDB")
            }

            Section("À propos") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                Link(destination: URL(string: "https://github.com/PopcornTimeTV/PopcornTimeTV")!) {
                    Label("Code source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .sheet(item: $traktAuthURL) { item in
            SafariSheet(url: item.url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .traktDidAuthenticate)) { _ in
            isTraktSignedIn = TraktManager.shared.isSignedIn()
            traktAuthURL = nil
        }
    }
}

extension Notification.Name {
    static let traktDidAuthenticate = Notification.Name("popcornkit.trakt.didAuthenticate")
}

private extension Bundle {
    var shortVersion: String {
        let v = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = object(forInfoDictionaryKey: "CFBundleVersion")            as? String ?? "?"
        return "\(v) (\(b))"
    }
}

#Preview {
    NavigationStack { SettingsView().navigationTitle("Réglages") }
        .preferredColorScheme(.dark)
}
