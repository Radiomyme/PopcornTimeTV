// « Vos langues » on the Mac: the launch sheet (once per profile, sequenced by
// `LanguagesLaunchQueue` in MacRootView) and the « Langues par type » section
// of the Settings window's Profiles pane, whose rows open the same editor for
// each profile. Both bind to `LanguagesByTypeModel`
// (PopcornTime/UI/Shared SwiftUI/Profiles/LanguagesByTypeModel.swift).

#if os(macOS)
import SwiftUI
import AppKit
import PopcornKit

// MARK: - The editor

/// The three types, each a section with its Audio and Subtitles menus: a
/// grouped form as tall as its rows.
struct MacLanguagesForm: View {
    @ObservedObject var model: LanguagesByTypeModel

    var body: some View {
        Form {
            ForEach(model.types, id: \.self) { type in
                Section {
                    Picker(selection: model.audioBinding(for: type)) {
                        options(model.audioOptions, selected: model.audioTag(for: type))
                    } label: {
                        Text(verbatim: languagesLocalized("Languages.Audio"))
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("Languages.Row.\(type.rawValue).audio")
                    // VoiceOver names the type with « Audio » / « Sous-titres ».
                    .accessibilityLabel(Text(verbatim: "\(LanguagesByTypeModel.title(of: type)), \(languagesLocalized("Languages.Audio"))"))
                    Picker(selection: model.subtitleBinding(for: type)) {
                        options(model.subtitleOptions, selected: model.subtitleTag(for: type))
                    } label: {
                        Text(verbatim: languagesLocalized("Languages.Subtitles"))
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("Languages.Row.\(type.rawValue).subtitles")
                    // VoiceOver names the type with « Audio » / « Sous-titres ».
                    .accessibilityLabel(Text(verbatim: "\(LanguagesByTypeModel.title(of: type)), \(languagesLocalized("Languages.Subtitles"))"))
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: LanguagesByTypeModel.title(of: type))
                        Text(verbatim: LanguagesByTypeModel.detail(of: type))
                            .font(.caption)
                            .fontWeight(.regular)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }

    /// The menu's items; a stored language the list does not have is added
    /// first, so that the menu never shows an empty value.
    @ViewBuilder
    private func options(_ list: [LanguagesByTypeModel.Option], selected: String) -> some View {
        if !list.contains(where: { $0.id == selected }) {
            Text(verbatim: PlaybackLanguagePreferences.displayName(forCode: selected)).tag(selected)
        }
        ForEach(list) { option in
            Text(verbatim: option.title).tag(option.id)
        }
    }
}

// MARK: - At launch

/// « Vos langues »: shown once per profile over the main window. Continue
/// saves the choices, Later (Escape too) keeps everything Automatic; both
/// mark the profile as asked.
struct MacLanguagesLaunchSheet: View {
    @StateObject private var model: LanguagesByTypeModel
    let close: () -> Void

    init(profileID: String, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: LanguagesByTypeModel(profileID: profileID, mode: .launchScreen))
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.tint)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text(verbatim: languagesLocalized("Languages.Title"))
                    .font(.title2.weight(.semibold))
                Text(verbatim: languagesLocalized("Languages.Message"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            MacLanguagesForm(model: model)
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button {
                    model.finish(saving: false)
                    close()
                } label: {
                    Text(verbatim: languagesLocalized("Languages.Later"))
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("Languages.Later")
                Button {
                    model.finish(saving: true)
                    close()
                } label: {
                    Text(verbatim: languagesLocalized("Languages.Continue"))
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("Languages.Continue")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
        .accessibilityIdentifier("Languages.Screen")
        // Escape is Later: the sheet must not go away by itself unanswered.
        .interactiveDismissDisabled()
    }
}

// MARK: - Settings › Profiles

/// The Profiles pane's « Langues par type »: one row per profile, its
/// customised types (or « Automatique ») and Modifier…, which opens the
/// editor for that profile — each profile has its own.
struct MacLanguagesSettingsSection: View {
    @StateObject private var profiles = ProfilesModel()
    @State private var editing: Edited?
    /// Bumped when a profile's choices change: the rows read them again.
    @State private var revision = 0

    struct Edited: Identifiable {
        let id: String
        let name: String
    }

    var body: some View {
        Form {
            Section {
                ForEach(profiles.profiles) { profile in
                    row(profile)
                }
            } header: {
                Text(verbatim: languagesLocalized("Languages.Settings.Row"))
            } footer: {
                Text(verbatim: languagesLocalized("Languages.Settings.Footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .macSettingsPane()
        // One pane with the profiles' form above it: no second margin
        // between the two.
        .contentMargins(.top, 0, for: .scrollContent)
        .sheet(item: $editing) { edited in
            MacLanguagesSettingsSheet(profileID: edited.id, profileName: edited.name) { editing = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contentLanguagesDidChange)) { _ in
            revision += 1
        }
        .onAppear {
            #if DEBUG
            // `-PTDebugSettingsSheet contentLanguages`: the profile in use's
            // editor (once a run).
            if MacDebugHooks.settingsSheet == "contentlanguages", !MacLanguagesDebug.didOpenSheet,
               let profile = profiles.active {
                MacLanguagesDebug.didOpenSheet = true
                editing = Edited(id: profile.id, name: profile.name)
            }
            #endif
        }
    }

    private func row(_ profile: Profile) -> some View {
        let value = LanguagesByTypeModel(profileID: profile.id).settingsRowValue
        let isCurrent = profile.id == profiles.activeID
        return LabeledContent {
            HStack(spacing: 10) {
                Text(verbatim: value)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(revision)
                Button("Home.Settings.Edit") {
                    editing = Edited(id: profile.id, name: profile.name)
                }
                .accessibilityLabel(Text(verbatim: "\(languagesLocalized("Languages.Settings.Row")), \(profile.name)"))
                .accessibilityIdentifier(isCurrent ? "Settings.Row.contentLanguages" : "Settings.Row.contentLanguages.\(profile.name)")
            }
        } label: {
            HStack(spacing: 10) {
                ProfileAvatarView(avatar: profile.avatar, size: 20)
                Text(verbatim: profile.name)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The editor for one profile, over the Settings window: each change is
/// saved at once; OK (Return or Escape) closes it.
struct MacLanguagesSettingsSheet: View {
    @StateObject private var model: LanguagesByTypeModel
    let profileName: String
    let close: () -> Void

    init(profileID: String, profileName: String, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: LanguagesByTypeModel(profileID: profileID, mode: .settings))
        self.profileName = profileName
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: languagesLocalized("Languages.Settings.Row"))
                    .font(.headline)
                Text(verbatim: profileName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            MacLanguagesForm(model: model)
            Divider()
            HStack {
                Spacer()
                Button(action: close) {
                    Text(verbatim: languagesLocalized("Languages.Done"))
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("Languages.Done")
            }
            .background {
                // Escape closes too (the menus take no keyboard focus).
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
        .accessibilityIdentifier("Languages.Settings")
    }
}

#if DEBUG
@MainActor
enum MacLanguagesDebug {
    /// `-PTDebugSettingsSheet contentLanguages` opened the editor (once a run).
    static var didOpenSheet = false
}
#endif
#endif
