

import SwiftUI
import PopcornKit

/// macOS Settings window (⌘,) mirroring the iOS `SettingsView`: same
/// UserDefaults keys, so preferences carry the same meaning across platforms.
/// Trakt signs in through the default browser; the OAuth redirect
/// (popcorntime://trakt) comes back via `onOpenURL` in the app.
struct MacSettingsView: View {
    @AppStorage("autoSelectQuality") private var autoSelectQuality = "Balanced"
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
                        NSWorkspace.shared.open(TraktManager.shared.iOSAuthorizationURL())
                    } label: {
                        Label("Se connecter à Trakt (navigateur)", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }

            Section("Sources") {
                LabeledContent("API Films", value: "movies-api.accel.li + Time4Popcorn")
                LabeledContent("API Séries", value: "eztvx.to (+ miroirs)")
                LabeledContent("Torrents", value: "Torrentio + T4P + YTS/EZTV")
            }

            Section("À propos") {
                LabeledContent("Version", value: Bundle.main.macShortVersion)
                LabeledContent("Moteur", value: "MKV remux → AVPlayer (Atmos) · VLC fallback")
                Link(destination: URL(string: "https://github.com/Radiomyme/PopcornTimeTV")!) {
                    Label("Code source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: .macTraktDidAuthenticate)) { _ in
            isTraktSignedIn = TraktManager.shared.isSignedIn()
        }
    }
}

extension Notification.Name {
    static let macTraktDidAuthenticate = Notification.Name("popcornkit.trakt.didAuthenticate.mac")
}

private extension Bundle {
    var macShortVersion: String {
        let v = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
