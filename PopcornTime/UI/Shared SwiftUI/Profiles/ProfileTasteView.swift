// ProfileTasteView.swift — Settings › Profiles › Your Preferences: what the
// active profile's taste has learned (`ProfileTaste`), and a way to forget
// it. iPhone / iPad: a page pushed from Settings (`ProfileTasteView`); Mac:
// sections of the Settings window's Profiles pane (`ProfileTasteSections`);
// Apple TV: a glass sheet of Settings (`GlassSettingsTasteSheet`, fed by
// `ProfileTasteModel.lines`).

import SwiftUI
import PopcornKit

/// One line of the page: a facet and its strongest values, best first.
struct ProfileTasteLine: Identifiable, Equatable {
    var id: String
    var title: String
    var values: [String]
}

final class ProfileTasteModel: ObservableObject {
    @Published private(set) var lines: [ProfileTasteLine] = []
    let profileName: String
    private let taste: ProfileTaste

    init(taste: ProfileTaste = .shared, profileName: String = ProfileManager.shared.active.name) {
        self.taste = taste
        self.profileName = profileName
        reload()
    }

    func reload() {
        lines = ProfileTasteModel.lines(of: taste)
    }

    func reset() {
        taste.reset()
        reload()
    }

    /// "Drama · Science Fiction" — the Settings row's value, joined as the
    /// panel's lines are; nil: nothing learnt.
    static func summary(of taste: ProfileTaste = .shared) -> String? {
        let genres = taste.topAffinities(limit: 2)[.genre] ?? []
        guard !genres.isEmpty else { return nil }
        return genres.map { genreName($0.value) }.joined(separator: " · ")
    }

    static func lines(of taste: ProfileTaste) -> [ProfileTasteLine] {
        let top = taste.topAffinities(limit: 3)
        var lines: [ProfileTasteLine] = []
        func add(_ id: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            lines.append(ProfileTasteLine(id: id, title: profilesLocalized("Profiles.Taste.\(id)"), values: values))
        }
        add("Genres", (top[.genre] ?? []).map { genreName($0.value) })
        add("Kinds", (top[.kind] ?? []).prefix(1).map { profilesLocalized($0.value == "show" ? "Profiles.Taste.Shows" : "Profiles.Taste.Movies") })
        add("Decades", (top[.decade] ?? []).map { String(format: profilesLocalized("Profiles.Taste.Decade"), $0.value) })
        add("People", (top[.person] ?? []).map(\.value))
        add("Audio", taste.preferredChoice(.audio).map { [languageName($0)] } ?? [])
        if taste.prefersSubtitlesOff {
            add("Subtitles", [profilesLocalized("Profiles.Taste.Off")])
        } else {
            add("Subtitles", taste.preferredChoice(.subtitle).map { [languageName($0)] } ?? [])
        }
        add("Quality", taste.preferredChoice(.quality).map { [$0] } ?? [])
        return lines
    }

    /// The genre under the app's name for it, translated.
    static func genreName(_ genre: String) -> String {
        let app: String
        switch genre {
        case "Sci-Fi": app = "Science Fiction"
        case "Sport": app = "Sports"
        default: app = genre
        }
        return profilesLocalized(app)
    }

    static func languageName(_ code: String) -> String {
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return locale.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }
}

#if os(iOS)
/// Your Preferences on the iPhone and iPad, pushed from Settings: one row per
/// facet, the values on its trailing side; Reset Preferences… once something
/// has been learned. Back returns to Settings.
struct ProfileTasteView: View {
    @StateObject private var model: ProfileTasteModel
    @State private var confirmReset = false

    init(model: @autoclosure @escaping () -> ProfileTasteModel = ProfileTasteModel()) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        Group {
            if model.lines.isEmpty {
                ContentUnavailableView {
                    Label(profilesLocalized("Profiles.Taste.Nothing"), systemImage: "sparkles")
                } description: {
                    // Under « Nothing yet »: the hint alone, not « Nothing
                    // learned yet » a second time.
                    Text(verbatim: profilesLocalized("Profiles.Taste.EmptyHint"))
                }
                .accessibilityIdentifier("Profiles.Taste.Empty")
            } else {
                Form {
                    Section {
                        ForEach(model.lines) { line in
                            LabeledContent(line.title, value: line.values.joined(separator: " · "))
                                .accessibilityIdentifier("Profiles.Taste.\(line.id)")
                        }
                    } footer: {
                        Text(verbatim: profilesLocalized("Profiles.Taste.Footer"))
                    }
                    Section {
                        Button(profilesLocalized("Profiles.Taste.Reset") + "…", role: .destructive) { confirmReset = true }
                            .accessibilityIdentifier("Profiles.Taste.Reset")
                    }
                }
            }
        }
        .navigationTitle(profilesLocalized("Profiles.Taste"))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ProfileTasteReset(model: model, isPresented: $confirmReset))
    }
}
#endif

#if os(macOS)
/// Your Preferences in the Mac's Profiles pane: a row per facet, the values
/// trailing in grey, cut at the pane's width; Reset Preferences… once
/// something has been learned.
struct ProfileTasteSections: View {
    @StateObject private var model = ProfileTasteModel()
    @State private var confirmReset = false

    var body: some View {
        Section {
            if model.lines.isEmpty {
                Text(verbatim: profilesLocalized("Profiles.Taste.Empty"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Profiles.Taste.Empty")
                    .modifier(ProfileTasteReset(model: model, isPresented: $confirmReset))
            } else {
                ForEach(model.lines) { line in
                    LabeledContent {
                        Text(verbatim: line.values.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityIdentifier("Profiles.Taste.\(line.id)")
                    } label: {
                        Text(verbatim: line.title)
                    }
                }
                HStack {
                    Spacer()
                    Button(profilesLocalized("Profiles.Taste.Reset") + "…", role: .destructive) { confirmReset = true }
                        .accessibilityIdentifier("Profiles.Taste.Reset")
                }
                // On a row, not on the section: a section's modifiers do
                // not reach a form's rows the same way on every macOS.
                .modifier(ProfileTasteReset(model: model, isPresented: $confirmReset))
            }
        } header: {
            Text(verbatim: profilesLocalized("Profiles.Taste"))
                .accessibilityIdentifier("Settings.ProfilePreferences")
        } footer: {
            Text(verbatim: profilesLocalized("Profiles.Taste.Footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif

#if !os(tvOS)
/// The confirmation before forgetting, and the page kept current with what
/// is learned meanwhile.
private struct ProfileTasteReset: ViewModifier {
    @ObservedObject var model: ProfileTasteModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .alert(String(format: profilesLocalized("Profiles.Taste.ResetConfirm"), model.profileName), isPresented: $isPresented) {
                SwiftUI.Button(profilesLocalized("Profiles.Taste.Reset"), role: .destructive) { model.reset() }
                SwiftUI.Button(profilesLocalized("Profiles.Cancel"), role: .cancel) {}
            } message: {
                Text(verbatim: profilesLocalized("Profiles.Taste.ResetMessage"))
            }
            .onReceive(NotificationCenter.default.publisher(for: ProfileTaste.didChangeNotification).receive(on: RunLoop.main)) { _ in
                model.reload()
            }
    }
}
#endif
