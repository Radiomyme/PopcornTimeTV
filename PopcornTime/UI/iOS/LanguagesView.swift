// « Vos langues » on the iPhone and the iPad: the launch sheet (once per
// profile, sequenced by `LanguagesLaunchQueue` in RootTabView) and the editor
// of Settings › Profiles › « Langues par type ». Both are a native Form of
// three sections — one per content type — with an audio and a subtitle
// menu picker each, bound to `LanguagesByTypeModel`
// (PopcornTime/UI/Shared SwiftUI/Profiles/LanguagesByTypeModel.swift).

import SwiftUI
import PopcornKit

/// The three sections of the editor: a type's title and line, its audio and
/// subtitle pickers.
private struct LanguagesTypeSections: View {
    @ObservedObject var model: LanguagesByTypeModel
    /// Under the last section (Settings: « Chaque profil a ses propres choix. »).
    var footer: String? = nil

    var body: some View {
        ForEach(model.types, id: \.self) { type in
            Section {
                Picker(selection: model.audioBinding(for: type)) {
                    ForEach(model.audioOptions) { option in
                        Text(verbatim: option.title).tag(option.id)
                    }
                } label: {
                    Text(verbatim: languagesLocalized("Languages.Audio"))
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("Languages.Row.\(type.rawValue).audio")
                // VoiceOver names the type with « Audio » / « Sous-titres ».
                .accessibilityLabel(Text(verbatim: "\(LanguagesByTypeModel.title(of: type)), \(languagesLocalized("Languages.Audio"))"))

                Picker(selection: model.subtitleBinding(for: type)) {
                    ForEach(model.subtitleOptions) { option in
                        Text(verbatim: option.title).tag(option.id)
                    }
                } label: {
                    Text(verbatim: languagesLocalized("Languages.Subtitles"))
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("Languages.Row.\(type.rawValue).subtitles")
                // VoiceOver names the type with « Audio » / « Sous-titres ».
                .accessibilityLabel(Text(verbatim: "\(LanguagesByTypeModel.title(of: type)), \(languagesLocalized("Languages.Subtitles"))"))
            } header: {
                LanguagesTypeHeader(type: type)
            } footer: {
                if let footer, type == model.types.last {
                    Text(verbatim: footer)
                }
            }
        }
    }
}

/// A type's section header: its symbol, its name and one line under it.
private struct LanguagesTypeHeader: View {
    let type: ContentType

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: LanguagesTypeHeader.symbol(of: type))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: LanguagesByTypeModel.title(of: type))
                    .font(.headline)
                    // Not the header's grey: the type is the section's title.
                    .foregroundStyle(Color.primary)
                Text(verbatim: LanguagesByTypeModel.detail(of: type))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }

    static func symbol(of type: ContentType) -> String {
        switch type {
        case .movie: return "film"
        case .cartoon: return "paintpalette"
        case .anime: return "sparkles"
        }
    }
}

// MARK: - The launch sheet

/// « Vos langues » at launch: a title, one sentence, the three types, then
/// « Continuer » (saves) and « Plus tard » (stays Automatic). Either one marks
/// the profile as asked; a swipe down is not an answer, so it is disabled.
struct LanguagesLaunchSheet: View {
    @StateObject private var model = LanguagesByTypeModel(mode: .launchScreen)
    /// Closes the sheet (RootTabView's `showLanguages`).
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                }
                LanguagesTypeSections(model: model)
            }
            .contentMargins(.top, 8, for: .scrollContent)
            .safeAreaBar(edge: .bottom) { buttons }
            .toolbar(.hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("Languages.Screen")
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "character.bubble")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(verbatim: languagesLocalized("Languages.Title"))
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: languagesLocalized("Languages.Message"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            Button {
                model.finish(saving: true)
                onDone()
            } label: {
                Text(verbatim: languagesLocalized("Languages.Continue"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("Languages.Continue")

            Button {
                model.finish(saving: false)
                onDone()
            } label: {
                Text(verbatim: languagesLocalized("Languages.Later"))
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityIdentifier("Languages.Later")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Settings › Profiles › « Langues par type »

/// The editor pushed from Settings: the same three sections for the active
/// profile, each change saved at once.
struct LanguagesByTypeSettingsView: View {
    @StateObject private var model = LanguagesByTypeModel(mode: .settings)

    var body: some View {
        Form {
            LanguagesTypeSections(model: model, footer: languagesLocalized("Languages.Settings.Footer"))
        }
        .navigationTitle(languagesLocalized("Languages.Settings.Row"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("Languages.Settings")
    }
}

/// Settings' « Langues par type » row, laid out as Your Preferences: the
/// 30 pt symbol slot, the title, the value (« Automatique », else the types
/// chosen) on the title's line, or under it when it is too long.
struct LanguagesByTypeSettingsRow: View {
    @State private var value = LanguagesByTypeSettingsRow.currentValue()
    private let title = languagesLocalized("Languages.Settings.Row")

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "character.bubble")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.10)))
                .accessibilityHidden(true)
            // The value on the title's line when it fits, else under it:
            // never « Dessins ani… ».
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(verbatim: title)
                    Spacer(minLength: 8)
                    Text(verbatim: value)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                    Text(verbatim: value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .onAppear { value = LanguagesByTypeSettingsRow.currentValue() }
        .onReceive(NotificationCenter.default.publisher(for: .contentLanguagesDidChange).receive(on: RunLoop.main)) { _ in
            value = LanguagesByTypeSettingsRow.currentValue()
        }
    }

    @MainActor
    static func currentValue() -> String {
        LanguagesByTypeModel(mode: .settings).settingsRowValue
    }
}

#Preview("Launch") {
    LanguagesLaunchSheet {}
}

#Preview("Settings") {
    NavigationStack { LanguagesByTypeSettingsView() }
}
