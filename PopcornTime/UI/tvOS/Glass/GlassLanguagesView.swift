// « Vos langues » on the Apple TV (Glass): the launch screen, shown once per
// profile by `LanguagesLaunchPresenter` (SceneDelegate, ProfilesPresenter),
// and the editor of Settings › Profiles › « Langues par type ». Both bind to
// `LanguagesByTypeModel` (Shared SwiftUI/Profiles/LanguagesByTypeModel.swift).
//
// One glass card, a row per content type: its name, then two value buttons —
// Audio and Subtitles — that open Settings' glass picker sheet
// (`GlassSettingsPickerSheet`). Launch: « Continuer » (the focus at first)
// and « Plus tard »; Menu continues, keeping what is on screen. Settings:
// each change is saved at once; « OK » or Menu close it.
//
// DEBUG: `-PTDebugLanguagesPicker <movie|cartoon|anime>.<audio|subtitles>`
// opens that picker at first display (screenshots).

import SwiftUI
import UIKit
import PopcornKit

struct GlassLanguagesView: View {
    @ObservedObject var model: LanguagesByTypeModel
    /// Launch: after the model's `finish(saving:)`; Settings: closes it.
    let onClose: () -> Void

    /// The value button whose picker is open.
    private struct PickerTarget: Identifiable, Equatable {
        let type: ContentType
        let subtitles: Bool
        var id: String { "\(type.rawValue).\(subtitles ? "subtitles" : "audio")" }
    }

    private enum Focus: Hashable {
        case audio(ContentType), subtitles(ContentType), continueAction, later, done
    }

    @State private var picker: PickerTarget?
    @FocusState private var focus: Focus?
    @Environment(\.glassSettingsFallback) private var fallback

    private var isLaunch: Bool { model.mode == .launchScreen }

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()
            VStack(spacing: 40) {
                header
                card
                buttons
            }
            .frame(width: 1500)
        }
        .defaultFocus($focus, isLaunch ? .continueAction : .audio(model.types[0]))
        .onExitCommand { isLaunch ? answer(saving: true) : onClose() }
        .fullScreenCover(item: $picker) { target in
            pickerSheet(target)
        }
        #if DEBUG
        .onAppear {
            guard picker == nil, let asked = UserDefaults.standard.string(forKey: "PTDebugLanguagesPicker") else { return }
            let parts = asked.split(separator: ".").map(String.init)
            if let type = parts.first.flatMap(ContentType.init(rawValue:)) {
                picker = PickerTarget(type: type, subtitles: parts.last == "subtitles")
            }
        }
        #endif
        .presentationBackground(.clear)
    }

    // MARK: Parts

    /// Launch: over UIKit's blur of the app. Settings: a cover of its own,
    /// the page dimmed and blurred behind.
    @ViewBuilder
    private var backdrop: some View {
        if isLaunch {
            Color.black.opacity(0.25)
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.45)
            }
        }
    }

    /// The profile it is for (when the device has several), the title and
    /// one sentence.
    private var header: some View {
        VStack(spacing: 16) {
            if ProfileManager.shared.profiles.count > 1, let profile = ProfileManager.shared.profiles.first(where: { $0.id == model.profileID }) {
                HStack(spacing: 14) {
                    ProfileAvatarView(avatar: profile.avatar, size: 48)
                    Text(profile.name)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            Text(languagesLocalized(isLaunch ? "Languages.Title" : "Languages.Settings.Row"))
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("Languages.Screen")
            Text(languagesLocalized(isLaunch ? "Languages.Message" : "Languages.Settings.Footer"))
                .font(.system(size: 29))
                .foregroundStyle(GlassSettingsPalette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var card: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.types.enumerated()), id: \.element) { index, type in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 1)
                        .padding(.horizontal, 30)
                }
                row(type)
            }
        }
        .padding(.vertical, 12)
        .modifier(GlassSettingsCard(cornerRadius: 44, fallback: fallback))
    }

    /// The type (icon, name, one line), then its two value buttons.
    private func row(_ type: ContentType) -> some View {
        HStack(spacing: 26) {
            Image(systemName: Self.symbol(of: type))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Self.tint(of: type).gradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(LanguagesByTypeModel.title(of: type))
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(LanguagesByTypeModel.detail(of: type))
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(GlassSettingsPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 400, alignment: .leading)
            .accessibilityElement(children: .combine)
            valueButton(type, subtitles: false)
            valueButton(type, subtitles: true)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
    }

    /// « Audio » over its value (« VO », « Automatique (Anglais) »…); a
    /// press opens its picker.
    private func valueButton(_ type: ContentType, subtitles: Bool) -> some View {
        let value = subtitles ? model.subtitleValue(for: type) : model.audioValue(for: type)
        let caption = languagesLocalized(subtitles ? "Languages.Subtitles" : "Languages.Audio")
        return SwiftUI.Button {
            picker = PickerTarget(type: type, subtitles: subtitles)
        } label: {
            HStack(spacing: 18) {
                Image(systemName: subtitles ? "captions.bubble.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 38)
                    .opacity(0.8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(caption)
                        .font(.system(size: 22, weight: .medium))
                        .opacity(0.6)
                        .lineLimit(1)
                    Text(value)
                        .font(.system(size: 30, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .opacity(0.4)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(GlassSettingsRowStyle(cornerRadius: 22))
        .focused($focus, equals: subtitles ? .subtitles(type) : .audio(type))
        .accessibilityIdentifier("Languages.Row.\(type.rawValue).\(subtitles ? "subtitles" : "audio")")
        // VoiceOver reads the focused button only: it names the type too.
        .accessibilityLabel(Text(verbatim: "\(LanguagesByTypeModel.title(of: type)), \(caption)"))
        .accessibilityValue(Text(verbatim: value))
    }

    /// Launch: « Continuer » (prominent, the first focus) and « Plus tard ».
    /// Settings: « OK ».
    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 30) {
            if isLaunch {
                SwiftUI.Button { answer(saving: true) } label: {
                    Text(languagesLocalized("Languages.Continue"))
                        .font(.system(size: 31, weight: .semibold))
                        .frame(minWidth: 300)
                }
                .modifier(GlassLanguagesButtonStyle(prominent: true))
                .focused($focus, equals: .continueAction)
                .accessibilityIdentifier("Languages.Continue")
                SwiftUI.Button { answer(saving: false) } label: {
                    Text(languagesLocalized("Languages.Later"))
                        .font(.system(size: 31, weight: .medium))
                        .frame(minWidth: 300)
                }
                .modifier(GlassLanguagesButtonStyle(prominent: false))
                .focused($focus, equals: .later)
                .accessibilityIdentifier("Languages.Later")
            } else {
                SwiftUI.Button(action: onClose) {
                    Text(languagesLocalized("Languages.Done"))
                        .font(.system(size: 31, weight: .semibold))
                        .frame(minWidth: 300)
                }
                .modifier(GlassLanguagesButtonStyle(prominent: true))
                .focused($focus, equals: .done)
                .accessibilityIdentifier("Languages.Done")
            }
        }
    }

    /// Settings' glass picker: the type's audio or subtitle choices, the
    /// current one checked and focused.
    private func pickerSheet(_ target: PickerTarget) -> some View {
        let type = target.type
        let options = target.subtitles ? model.subtitleOptions : model.audioOptions
        return GlassSettingsPickerSheet(
            title: languagesLocalized(target.subtitles ? "Languages.Subtitles" : "Languages.Audio"),
            message: LanguagesByTypeModel.title(of: type),
            options: options.map { option in
                // Automatic says what it stands for now (« Automatique (Anglais) »).
                let title = option.id == ContentAudioChoice.automaticTag
                    ? PlaybackLanguagePreferences.automaticName(subtitles: target.subtitles) : option.title
                return .init(id: option.id, title: title, detail: nil)
            },
            selectedID: target.subtitles ? model.subtitleTag(for: type) : model.audioTag(for: type),
            onSelect: { id in
                if target.subtitles { model.setSubtitleTag(id, for: type) } else { model.setAudioTag(id, for: type) }
                picker = nil
            },
            onCancel: { picker = nil })
    }

    private func answer(saving: Bool) {
        model.finish(saving: saving)
        onClose()
    }

    // MARK: Look

    static func symbol(of type: ContentType) -> String {
        switch type {
        case .movie: return "film.fill"
        case .cartoon: return "paintbrush.pointed.fill"
        case .anime: return "sparkles"
        }
    }

    static func tint(of type: ContentType) -> Color {
        switch type {
        case .movie: return .blue
        case .cartoon: return .orange
        case .anime: return .pink
        }
    }
}

/// `.glassProminent` (accent) or `.glass` on tvOS 26+, `.borderedProminent`
/// or `.bordered` before; all with the system focus effect.
private struct GlassLanguagesButtonStyle: ViewModifier {
    let prominent: Bool
    @Environment(\.glassSettingsFallback) private var fallback

    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *), !fallback {
            if prominent {
                content.buttonStyle(.glassProminent).tint(GlassSettingsPalette.accent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).tint(GlassSettingsPalette.accent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

// MARK: - Hosting

extension GlassLanguagesView {

    /// The launch screen for `LanguagesLaunchPresenter.schedule`: the active
    /// profile's choices, over a blur of the app like What's New.
    @MainActor
    static func makeLaunchScreen(finish: @escaping () -> Void) -> UIViewController {
        let model = LanguagesByTypeModel(mode: .launchScreen)
        let host = UIHostingController(rootView: GlassLanguagesView(model: model, onClose: finish))
        host.modalPresentationStyle = .blurOverFullScreen
        host.view.backgroundColor = .clear
        return host
    }

    /// Settings' editor (a cover of the Settings page): the active profile's
    /// choices, each change saved at once.
    @MainActor
    static func settingsEditor(onClose: @escaping () -> Void) -> AnyView {
        AnyView(GlassLanguagesEditorHost(onClose: onClose))
    }

    /// The value of Settings' « Langues par type » row: « Automatique », or
    /// the types chosen (« Dessins animés, Animés », « Films et séries +2 »).
    @MainActor
    static func settingsSummary() -> String {
        let choices = ContentLanguageSettings.active
        let changed = ContentType.allCases.filter { !choices[$0].isAutomatic }.map(LanguagesByTypeModel.title(of:))
        guard !changed.isEmpty else { return languagesLocalized("Languages.Automatic") }
        return changed.count > 2 ? "\(changed[0]) +\(changed.count - 1)" : changed.joined(separator: ", ")
    }
}

/// Owns the Settings editor's model for the cover's lifetime.
private struct GlassLanguagesEditorHost: View {
    @StateObject private var model = LanguagesByTypeModel(mode: .settings)
    let onClose: () -> Void

    var body: some View {
        GlassLanguagesView(model: model, onClose: onClose)
    }
}
