

import SwiftUI
import PopcornKit

/// macOS Settings window (⌘,) mirroring the iOS `SettingsView`: same
/// UserDefaults keys, so preferences carry the same meaning across platforms.
/// Trakt signs in through the default browser; the OAuth redirect
/// (popcorntime://trakt) comes back via `onOpenURL` in the app.
struct MacSettingsView: View {
    @AppStorage("autoSelectQuality") private var autoSelectQuality = "Balanced"
    // Localized language NAME ("Français"), same convention as tvOS Settings.
    @AppStorage(PlaybackLanguagePreferences.audioLanguageDefaultsKey)    private var preferredAudioLanguage: String?
    @AppStorage(PlaybackLanguagePreferences.subtitleLanguageDefaultsKey) private var preferredSubtitleLanguage: String?
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

            Section {
                languagePicker("Langue audio préférée", storage: $preferredAudioLanguage)
                languagePicker("Langue des sous-titres", storage: $preferredSubtitleLanguage)
            } header: {
                Text("Langues")
            } footer: {
                Text("Choisies automatiquement au lancement de la lecture quand le fichier (ou OpenSubtitles) les propose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    /// "Aucune" + common languages (localized names). The selection is the
    /// ISO code, the stored value the localized name (tvOS convention), so a
    /// name saved under another UI language still shows up selected.
    private func languagePicker(_ title: String, storage: Binding<String?>) -> some View {
        let selection = Binding<String>(
            get: { storage.wrappedValue.flatMap(PlaybackLanguagePreferences.isoCode(for:)) ?? "" },
            set: { storage.wrappedValue = $0.isEmpty ? nil : PlaybackLanguagePreferences.storedName(forCode: $0) }
        )
        var codes = PlaybackLanguagePreferences.sortedPickerLanguageCodes
        if !selection.wrappedValue.isEmpty, !codes.contains(selection.wrappedValue) {
            codes.insert(selection.wrappedValue, at: 0)
        }
        return Picker(title, selection: selection) {
            Text("Aucune").tag("")
            ForEach(codes, id: \.self) { code in
                Text(PlaybackLanguagePreferences.displayName(forCode: code)).tag(code)
            }
        }
        .pickerStyle(.menu)
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
