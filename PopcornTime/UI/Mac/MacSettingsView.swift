

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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Playback") {
                // Labels only: the stored tags stay "Balanced" / "Highest" /
                // "Lowest" / "" (MacAutoQuality, the iOS / tvOS settings).
                Picker("Auto Select Quality", selection: $autoSelectQuality) {
                    Text("Balanced (quick start)").tag("Balanced")
                    Text("Highest").tag("Highest")
                    Text("Lowest").tag("Lowest")
                    Text("Always Ask").tag("")
                }
                .pickerStyle(.menu)
            }

            Section {
                languagePicker("Audio Language", storage: $preferredAudioLanguage)
                languagePicker("Subtitle Language", storage: $preferredSubtitleLanguage)
            } header: {
                Text("Languages")
            } footer: {
                Text("Audio and subtitles in these languages are picked automatically when the file or OpenSubtitles offers them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Trakt Account") {
                if isTraktSignedIn {
                    Label("Signed In to Trakt", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button(role: .destructive) {
                        try? TraktManager.shared.logout()
                        isTraktSignedIn = TraktManager.shared.isSignedIn()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Button {
                        NSWorkspace.shared.open(TraktManager.shared.iOSAuthorizationURL())
                    } label: {
                        Label("Sign In to Trakt (Browser)", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }

            Section("Sources") {
                LabeledContent("Movies API", value: "movies-api.accel.li + Time4Popcorn")
                LabeledContent("Shows API", value: String(format: "%@ (+ mirrors)".localized, "eztvx.to"))
                LabeledContent("Torrents", value: "Torrentio + T4P + YTS/EZTV")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.macShortVersion)
                LabeledContent("Engine", value: "MKV remux → AVPlayer (Atmos) · VLC fallback")
                Button {
                    openWindow(id: MacWhatsNewWindow.id)
                } label: {
                    Label("What's New", systemImage: "sparkles")
                }
                Link(destination: URL(string: "https://github.com/Radiomyme/PopcornTimeTV")!) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
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

    /// "None" + common languages (localized names). The selection is the
    /// ISO code, the stored value the localized name (tvOS convention), so a
    /// name saved under another UI language still shows up selected.
    private func languagePicker(_ title: LocalizedStringKey, storage: Binding<String?>) -> some View {
        let selection = Binding<String>(
            get: { storage.wrappedValue.flatMap(PlaybackLanguagePreferences.isoCode(for:)) ?? "" },
            set: { storage.wrappedValue = $0.isEmpty ? nil : PlaybackLanguagePreferences.storedName(forCode: $0) }
        )
        var codes = PlaybackLanguagePreferences.sortedPickerLanguageCodes
        if !selection.wrappedValue.isEmpty, !codes.contains(selection.wrappedValue) {
            codes.insert(selection.wrappedValue, at: 0)
        }
        return Picker(title, selection: selection) {
            Text("None").tag("")
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
