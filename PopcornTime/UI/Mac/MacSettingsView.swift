

import Foundation
import AppKit
import SwiftUI
import PopcornKit

/// macOS Settings window (⌘,) mirroring the iOS `SettingsView`: same
/// UserDefaults keys, so preferences carry the same meaning across platforms.
/// Five panes, as a Mac's settings have — Profiles (`MacProfilesSettingsPane`:
/// who is watching, each profile's editor, Your Preferences), Playback,
/// Home, Streaming (`MacStreamingSettingsPane`: the TMDB key, the country,
/// the services), About — each a grouped form no taller than its rows: in
/// one pane the window had grown taller than a 14-inch screen once the
/// Home's settings were added.
/// Trakt: no sign-in is offered — Trakt refuses the app's key (403), the
/// browser flow could only end on an error. An account signed in with an
/// earlier version still shows, so that it can be signed out.
struct MacSettingsView: View {
    @AppStorage("autoSelectQuality") private var autoSelectQuality = "Balanced"
    /// « Autoplay next episode » (decision D8: on unless turned off).
    @AppStorage(UpNextPreferences.autoPlayNextKey) private var autoPlayNext = true
    /// « Next Episode Card » (seconds before the end; absent = 60).
    @AppStorage(UpNextPreferences.cardLeadKey) private var storedCardLead = Int(UpNextCountdown.defaultCardLead)
    // Localized language NAME ("Français"), same convention as tvOS Settings.
    @AppStorage(PlaybackLanguagePreferences.audioLanguageDefaultsKey)    private var preferredAudioLanguage: String?
    @AppStorage(PlaybackLanguagePreferences.subtitleLanguageDefaultsKey) private var preferredSubtitleLanguage: String?
    @State private var isTraktSignedIn = TraktManager.shared.isSignedIn()
    @Environment(\.openWindow) private var openWindow
    /// The Home's settings, as their rows sum them up; read again whenever
    /// one of their lists closes.
    @State private var homeLanguages: String?
    @State private var homeHiddenShelves = ""
    @State private var sendsFollowedShows = Library.shared.isBulkEpisodeLookupEnabled
    /// The list open in a sheet over the window.
    @State private var homeList: HomeList?

    /// The stored card time, one of the choices (anything else reads as 60 s).
    private var upNextCardLead: Binding<Int> {
        Binding(get: { Int(UpNextCountdown.cardLead(stored: storedCardLead)) },
                set: { storedCardLead = Int(UpNextCountdown.cardLead(stored: $0)) })
    }

    /// The two lists behind the Home's rows.
    private enum HomeList: String, Identifiable {
        case languages
        case shelves

        var id: String { rawValue }
    }

    /// The window's panes.
    private enum Pane: Hashable {
        case profiles
        case playback
        case home
        case streaming
        case about
    }

    /// The pane shown last, kept outside the view: a profile switch makes
    /// the window's content again (`ProfileScoped`), on the pane it was on.
    @MainActor private static var lastPane = Pane.playback
    @State private var pane = MacSettingsView.lastPane

    var body: some View {
        TabView(selection: $pane) {
            MacProfilesSettingsPane()
                .tabItem { Label(profilesLocalized("Profiles"), systemImage: "person.2") }
                .tag(Pane.profiles)
            form { playbackSections }
                .tabItem { Label("Playback", systemImage: "play.circle") }
                .tag(Pane.playback)
            form { homeSection }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Pane.home)
            MacStreamingSettingsPane(store: MacStreamingSettings.store)
                .tabItem { Label("Settings.Streaming.Tab", systemImage: "play.tv") }
                .tag(Pane.streaming)
            form { aboutSections }
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Pane.about)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macTraktDidAuthenticate)) { _ in
            isTraktSignedIn = TraktManager.shared.isSignedIn()
        }
        .onAppear {
            reloadHomeSettings()
            #if DEBUG
            // `-PTDebugSettingsPane <profiles|playback|home|streaming|about>`: that
            // pane; `-PTDebugSettingsSheet <languages|shelves>`: the Home's
            // pane with that list open, `<tmdbkey|services>`: the
            // Streaming pane with that sheet open.
            switch MacDebugHooks.settingsPane {
            case "profiles": pane = .profiles
            case "home": pane = .home
            case "streaming": pane = .streaming
            case "about": pane = .about
            default: break
            }
            if MacDebugHooks.settingsSheet.flatMap(MacStreamingSettingsPane.Sheet.init(rawValue:)) != nil {
                pane = .streaming
            }
            if homeList == nil, let list = MacDebugHooks.settingsSheet.flatMap(HomeList.init(rawValue:)) {
                pane = .home
                homeList = list
            }
            #endif
        }
        // A key saved or removed in the Streaming pane lists the
        // « Services » shelf, or not, among the Home's.
        .onChange(of: pane) { _, pane in
            MacSettingsView.lastPane = pane
            reloadHomeSettings()
        }
        .sheet(item: $homeList, onDismiss: reloadHomeSettings) { list in
            MacHomeSettingsSheet(title: list == .languages ? "Home.Settings.Languages" : "Home.Settings.Shelves") {
                switch list {
                case .languages: HomeLanguagesSettingsView(state: MacHome.state)
                case .shelves: HomeShelvesSettingsView(state: MacHome.state)
                }
            } close: {
                homeList = nil
            }
        }
    }

    /// One pane: a grouped form as tall as its rows.
    private func form<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form(content: content)
            .macSettingsPane()
    }

    // MARK: Playback

    @ViewBuilder
    private var playbackSections: some View {
        Section {
            // Labels only: the stored tags stay "Balanced" / "Highest" /
            // "Lowest" / "" (MacAutoQuality, the iOS / tvOS settings).
            Picker("Auto Select Quality", selection: $autoSelectQuality) {
                Text("Balanced (quick start)").tag("Balanced")
                Text("Highest").tag("Highest")
                Text("Lowest").tag("Lowest")
                Text("Always Ask").tag("")
            }
            .pickerStyle(.menu)
            // Off: the next episode's card stays without a countdown,
            // nothing starts by itself (episode chaining).
            Toggle("Settings.AutoPlayNext", isOn: $autoPlayNext)
                .accessibilityIdentifier("Settings.AutoPlayNext")
            // « Next Episode Card »: 30 / 45 / 60 / 90 s before the end
            // (an unknown stored value reads as the default, 60 s).
            Picker("Settings.UpNextCard", selection: upNextCardLead) {
                ForEach(UpNextCountdown.cardLeadChoices, id: \.self) { seconds in
                    Text(UpNextPreferences.cardLeadText(seconds)).tag(seconds)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("Settings.UpNextCard")
        } header: {
            Text("Playback")
        } footer: {
            footer("Settings.AutoPlayNext.Footer")
        }

        Section {
            languagePicker("Audio Language", storage: $preferredAudioLanguage, subtitles: false)
            languagePicker("Subtitle Language", storage: $preferredSubtitleLanguage, subtitles: true)
        } header: {
            Text("Languages")
        } footer: {
            (Text("Audio and subtitles in these languages are picked automatically when the file or OpenSubtitles offers them.")
                + Text(verbatim: " ") + Text("Settings.Language.Automatic.Footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

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
    }

    // MARK: About

    @ViewBuilder
    private var aboutSections: some View {
        // What the catalogue is really read from today (PopcornKit's
        // providers), by name: an About pane, not a diagnostics page.
        Section("Sources") {
            LabeledContent("Movies API", value: "YTS · Time4Popcorn")
            LabeledContent("Shows API", value: "EZTV · Time4Popcorn")
            LabeledContent("Metadata", value: "Cinemeta · TVMaze · metahub")
            LabeledContent("Torrents", value: "Torrentio · The Pirate Bay · Knaben")
        }

        Section("About") {
            LabeledContent("Version", value: Bundle.main.macShortVersion)
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

    // MARK: Home

    /// The Home: which original languages its shelves keep, which shelves
    /// show, and whether the followed shows go to Cinemeta in one request —
    /// each with what it does written under it, as on iOS. The same stored
    /// values as on the other platforms (`HomeSettings`, `Library`) and the
    /// same lists as on iOS (`HomeSettingsViews`), each in a sheet: a
    /// change is stored at once and the Home is rebuilt from what it
    /// already has.
    @ViewBuilder
    private var homeSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    Group {
                        if let homeLanguages { Text(verbatim: homeLanguages) } else { Text("Home.Settings.AllLanguages.Value") }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Button("Home.Settings.Edit") { homeList = .languages }
                        .accessibilityIdentifier("Settings.Home.Languages")
                }
            } label: {
                Text("Home.Settings.Languages")
            }
        } footer: {
            footer("Home.Settings.Languages.Footer")
        }
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    Text(verbatim: homeHiddenShelves)
                    Button("Home.Settings.Edit") { homeList = .shelves }
                        .accessibilityIdentifier("Settings.Home.Shelves")
                }
            } label: {
                Text("Home.Settings.HiddenShelves")
            }
        } footer: {
            footer("Home.Settings.Shelves.Footer")
        }
        Section {
            Toggle("Home.Settings.BulkLookup", isOn: Binding(get: { sendsFollowedShows }, set: { on in
                sendsFollowedShows = on
                Library.shared.isBulkEpisodeLookupEnabled = on
            }))
            .accessibilityIdentifier("Settings.Home.BulkLookup")
        } footer: {
            footer("Home.Settings.BulkLookup.Footer")
        }
    }

    private func footer(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reloadHomeSettings() {
        let model = HomeSettingsModel(settings: HomeSettings())
        homeLanguages = model.languageSummary
        homeHiddenShelves = model.hiddenSummary
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

extension View {
    /// A pane of the Settings window: a grouped form 480 pt wide, as tall
    /// as its rows (the window takes the size of the pane shown).
    func macSettingsPane() -> some View {
        formStyle(.grouped)
            .frame(width: 480)
            .fixedSize()
    }
}

/// One of the Home's lists (content languages, shelves) — or the Streaming
/// pane's services — in a sheet over the Settings window: its title, the
/// list, and OK (Return; Escape too when `closesOnEscape`).
struct MacHomeSettingsSheet<Content: View>: View {
    let title: LocalizedStringKey
    var closesOnEscape = false
    @ViewBuilder let content: () -> Content
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 4)
            content()
                .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("OK", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .background {
                if closesOnEscape {
                    // Escape: a list of buttons takes no keyboard focus, so
                    // no view would get the cancel command — a button does.
                    Button("Close", action: close)
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 520)
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
