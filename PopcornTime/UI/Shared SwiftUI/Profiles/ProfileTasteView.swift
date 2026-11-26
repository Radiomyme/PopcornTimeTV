// ProfileTasteView.swift — Settings › Profiles › Your Preferences: what the
// active profile's taste has learnt (`ProfileTaste`), and a way to forget
// it. Apple TV (ProfilesPresenter.presentTaste), iPhone / iPad and Mac
// (ProfilesSettingsSection, as a sheet).

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

    /// "Sci-Fi, Drama" — the Settings row's value; nil: nothing learnt.
    static func summary(of taste: ProfileTaste = .shared) -> String? {
        let genres = taste.topAffinities(limit: 2)[.genre] ?? []
        guard !genres.isEmpty else { return nil }
        return genres.map { genreName($0.value) }.joined(separator: ", ")
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

struct ProfileTasteView: View {
    @StateObject private var model: ProfileTasteModel
    let onClose: () -> Void
    @State private var confirmReset = false

    init(model: @autoclosure @escaping () -> ProfileTasteModel = ProfileTasteModel(), onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
        self.onClose = onClose
    }

    #if os(tvOS)
    private let titleFont = Font.system(size: 56, weight: .bold)
    private let lineFont = Font.system(size: 30)
    private let width: CGFloat = 1200
    #else
    private let titleFont = Font.title.bold()
    private let lineFont = Font.body
    private let width: CGFloat = 560
    #endif

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.02)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profilesLocalized("Profiles.Taste"))
                            .font(titleFont)
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("Profiles.Taste.Title")
                        Text(String(format: profilesLocalized("Profiles.Current"), model.profileName))
                            .font(lineFont)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if model.lines.isEmpty {
                        Text(profilesLocalized("Profiles.Taste.Empty"))
                            .font(lineFont)
                            .foregroundStyle(.white.opacity(0.7))
                            .accessibilityIdentifier("Profiles.Taste.Empty")
                    } else {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 30, verticalSpacing: 18) {
                            ForEach(model.lines) { line in
                                GridRow {
                                    Text(line.title)
                                        .foregroundStyle(.white.opacity(0.6))
                                    Text(line.values.joined(separator: " · "))
                                        .foregroundStyle(.white)
                                        .accessibilityIdentifier("Profiles.Taste.\(line.id)")
                                }
                                .font(lineFont)
                            }
                        }
                    }
                    Text(profilesLocalized("Profiles.Taste.Footer"))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                    buttons
                }
                .frame(maxWidth: width, alignment: .leading)
                .padding(tvOS ? 80 : 28)
                .frame(maxWidth: .infinity)
            }
        }
        #if os(tvOS)
        .onExitCommand(perform: onClose)
        #endif
        .alert(String(format: profilesLocalized("Profiles.Taste.ResetConfirm"), model.profileName), isPresented: $confirmReset) {
            SwiftUI.Button(profilesLocalized("Profiles.Taste.Reset"), role: .destructive) { model.reset() }
            SwiftUI.Button(profilesLocalized("Profiles.Cancel"), role: .cancel) {}
        } message: {
            Text(profilesLocalized("Profiles.Taste.ResetMessage"))
        }
        .onReceive(NotificationCenter.default.publisher(for: ProfileTaste.didChangeNotification).receive(on: RunLoop.main)) { _ in
            model.reload()
        }
    }

    private var buttons: some View {
        HStack(spacing: 30) {
            SwiftUI.Button(profilesLocalized("Profiles.Done"), action: onClose)
                .accessibilityIdentifier("Profiles.Taste.Done")
                #if !os(tvOS)
                .keyboardShortcut(.defaultAction)
                #endif
            // No destructive role here: on the Apple TV it draws red text on a
            // red button. The confirmation says it.
            SwiftUI.Button(profilesLocalized("Profiles.Taste.Reset")) { confirmReset = true }
                .disabled(model.lines.isEmpty)
                .accessibilityIdentifier("Profiles.Taste.Reset")
        }
        #if os(tvOS)
        .focusSection()
        #else
        .buttonStyle(.bordered)
        #endif
        .padding(.top, 12)
    }

    private var tvOS: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }
}
