

import SwiftUI
import PopcornKit

/// Settings, opened by the gear of the root screens (a sheet of
/// `RootTabView`). Same UserDefaults keys as the tvOS and macOS settings, so
/// a preference means the same on every platform.
struct SettingsView: View {
    @AppStorage("autoSelectQuality") private var autoSelectQuality = "Balanced"
    @AppStorage(CellularStreamingPolicy.defaultsKey) private var streamOnCellular = false
    /// « Autoplay next episode » (episode chaining, on by default: D8).
    @AppStorage(UpNextPreferences.autoPlayNextKey) private var autoPlayNext = true
    /// « Next Episode Card » (seconds before the end; absent = 60).
    @AppStorage(UpNextPreferences.cardLeadKey) private var storedCardLead = Int(UpNextCountdown.defaultCardLead)
    // Localized language NAME ("Français"), same convention as tvOS Settings.
    @AppStorage(PlaybackLanguagePreferences.audioLanguageDefaultsKey)    private var preferredAudioLanguage: String?
    @AppStorage(PlaybackLanguagePreferences.subtitleLanguageDefaultsKey) private var preferredSubtitleLanguage: String?
    @State private var isTraktSignedIn = TraktManager.shared.isSignedIn()
    /// The release notes of this version, again (they show once at launch).
    @State private var showWhatsNew = false
    /// The Home's settings, as their rows sum them up; read again whenever
    /// the screen shows (back from one of their lists).
    @State private var homeLanguages: String?
    @State private var homeHiddenShelves = ""
    @State private var sendsFollowedShows = Library.shared.isBulkEpisodeLookupEnabled
    /// « Services de streaming »: the TMDB key, the country, the services
    /// of the Home's « Services » row; a change rebuilds the Home's page.
    @State private var streaming = StreamingSettingsStore(hub: IOSHome.state)
    /// A screen of the streaming section pushed by a DEBUG launch
    /// (`-PTDebugSettingsScreen`).
    @State private var pushedScreen: StreamingSettingsScreen?

    /// The stored card time, one of the choices (anything else reads as 60 s).
    private var upNextCardLead: Binding<Int> {
        Binding(get: { Int(UpNextCountdown.cardLead(stored: storedCardLead)) },
                set: { storedCardLead = Int(UpNextCountdown.cardLead(stored: $0)) })
    }

    var body: some View {
        Form {
            ProfilesSettingsSection()

            Section {
                // Labels only: the stored tags stay "Balanced" / "Highest" /
                // "Lowest" / "" (the tvOS / macOS settings).
                Picker("Auto Select Quality", selection: $autoSelectQuality) {
                    Text("Balanced (quick start)").tag("Balanced")
                    Text("Highest").tag("Highest")
                    Text("Lowest").tag("Lowest")
                    Text("Always Ask").tag("")
                }
                // The value on the label's line, or under it aligned with
                // it: a menu's long French value wrapped off the label.
                .pickerStyle(.navigationLink)

                Toggle("Stream on Cellular Data", isOn: $streamOnCellular)
            } header: {
                Text("Playback")
            } footer: {
                Text("When this is off, Popcorn Time asks before it starts a stream on cellular data or a personal hotspot.")
            }

            Section {
                Toggle("Settings.AutoPlayNext", isOn: $autoPlayNext)
                    .accessibilityIdentifier("Settings.AutoPlayNext")
                // « Next Episode Card »: 30 / 45 / 60 / 90 s before the end
                // (an unknown stored value reads as the default, 60 s).
                Picker("Settings.UpNextCard", selection: upNextCardLead) {
                    ForEach(UpNextCountdown.cardLeadChoices, id: \.self) { seconds in
                        Text(UpNextPreferences.cardLeadText(seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("Settings.UpNextCard")
            } footer: {
                Text("Settings.AutoPlayNext.Footer")
            }

            Section {
                languagePicker("Audio Language", storage: $preferredAudioLanguage, subtitles: false)
                languagePicker("Subtitle Language", storage: $preferredSubtitleLanguage, subtitles: true)
            } header: {
                Text("Languages")
            } footer: {
                Text("Audio and subtitles in these languages are picked automatically when the file or OpenSubtitles offers them.")
                    + Text(verbatim: " ") + Text("Settings.Language.Automatic.Footer")
            }

            homeSections

            StreamingSettingsSection(store: streaming)

            // Trakt refuses the app's key, so nothing offers to sign in any
            // more. An account connected by an earlier version can still be
            // disconnected here.
            if isTraktSignedIn {
                Section("Trakt Account") {
                    Label("Signed In to Trakt", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button(role: .destructive) {
                        try? TraktManager.shared.logout()
                        isTraktSignedIn = TraktManager.shared.isSignedIn()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }

            Section("Sources") {
                LabeledContent("Movies", value: "YTS · Time4Popcorn")
                LabeledContent("Shows", value: "EZTV · TVMaze · Time4Popcorn")
                LabeledContent("Torrents", value: "Torrentio · The Pirate Bay · Knaben")
                LabeledContent("Metadata", value: "Cinemeta · TVMaze · metahub")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                Button {
                    showWhatsNew = true
                } label: {
                    Label("What's New", systemImage: "sparkles")
                }
                Link(destination: URL(string: "https://github.com/Radiomyme/PopcornTimeTV")!) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView { showWhatsNew = false }
        }
        .navigationDestination(item: $pushedScreen) { screen in
            StreamingSettingsDestination(screen: screen, store: streaming)
        }
        .onAppear {
            reloadHomeSettings()
            streaming.reload()
            #if DEBUG
            if pushedScreen == nil, let screen = IOSDebugHooks.takeSettingsScreen() { pushedScreen = screen }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .traktDidAuthenticate)) { _ in
            isTraktSignedIn = TraktManager.shared.isSignedIn()
        }
    }

    // MARK: Home

    /// The Home: which original languages its shelves keep, which shelves
    /// show, and whether the followed shows go to Cinemeta in one request.
    /// The same stored values as on the other platforms (`HomeSettings`,
    /// `Library.bulkEpisodeLookupKey`).
    @ViewBuilder
    private var homeSections: some View {
        Section {
            NavigationLink {
                HomeLanguagesSettingsView(state: IOSHome.state)
            } label: {
                LabeledContent {
                    // "All": the list is not filtered.
                    if let homeLanguages { Text(verbatim: homeLanguages) } else { Text("Home.Settings.AllLanguages.Value") }
                } label: {
                    Text("Home.Settings.Languages")
                }
            }
            .accessibilityIdentifier("Settings.Home.Languages")
        } header: {
            Text("Home")
        } footer: {
            Text("Home.Settings.Languages.Footer")
        }

        Section {
            NavigationLink {
                HomeShelvesSettingsView(state: IOSHome.state)
            } label: {
                // "Rangées — Toutes": the page it opens lists the shelves
                // shown, switched on.
                LabeledContent {
                    Text(verbatim: homeHiddenShelves)
                } label: {
                    Text("Home.Settings.Shelves")
                }
            }
            .accessibilityIdentifier("Settings.Home.Shelves")
        } footer: {
            Text("Home.Settings.Shelves.Footer")
        }

        Section {
            Toggle("Home.Settings.BulkLookup", isOn: Binding(get: { sendsFollowedShows }, set: { on in
                sendsFollowedShows = on
                Library.shared.isBulkEpisodeLookupEnabled = on
            }))
            .accessibilityIdentifier("Settings.Home.BulkLookup")
        } footer: {
            Text("Home.Settings.BulkLookup.Footer")
        }
    }

    private func reloadHomeSettings() {
        let model = HomeSettingsModel(settings: HomeSettings())
        homeLanguages = model.languageSummary
        // "Toutes", or "12/16": how many shelves the Home shows.
        let shelves = model.shelves(current: IOSHome.state.shelves)
        let shown = shelves.filter(\.isShown).count
        homeHiddenShelves = shown == shelves.count ? "Home.Settings.AllLanguages.Value".localized : "\(shown)/\(shelves.count)"
        sendsFollowedShows = Library.shared.isBulkEpisodeLookupEnabled
    }

    /// « Automatic (French) », "None", then common languages (localized
    /// names). The selection is the ISO code, the stored value the localized
    /// name (tvOS convention), so a name saved under another UI language
    /// still shows up selected. Automatic removes the key: the language the
    /// profile picks itself; « None » is stored as a choice, which a learnt
    /// language never takes the place of.
    private func languagePicker(_ title: LocalizedStringKey, storage: Binding<String?>, subtitles: Bool) -> some View {
        typealias Setting = PlaybackLanguagePreferences.SettingValue
        let selection = Binding<String>(
            get: { Setting(stored: storage.wrappedValue).tag },
            set: { storage.wrappedValue = Setting(tag: $0).stored }
        )
        var codes = PlaybackLanguagePreferences.sortedPickerLanguageCodes
        if let code = Setting(stored: storage.wrappedValue).code, !codes.contains(code) {
            codes.insert(code, at: 0)
        }
        return Picker(title, selection: selection) {
            Text(verbatim: PlaybackLanguagePreferences.automaticName(subtitles: subtitles)).tag(PlaybackLanguagePreferences.automaticTag)
            Text("None").tag("")
            ForEach(codes, id: \.self) { code in
                Text(verbatim: PlaybackLanguagePreferences.displayName(forCode: code)).tag(code)
            }
        }
        .pickerStyle(.menu)
    }
}

extension Notification.Name {
    /// Posted once the `popcorntime://trakt` redirect was handled
    /// (`PopcornTimeApp`): kept with the sign-out row for accounts connected
    /// by an earlier version.
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
    NavigationStack { SettingsView().navigationTitle("Settings") }
        .preferredColorScheme(.dark)
}
