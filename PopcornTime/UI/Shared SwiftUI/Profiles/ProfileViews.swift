// ProfileViews.swift — « Who's Watching? » and the profile editor, for the
// Apple TV, the iPhone and iPad, and the Mac. The profiles themselves are
// PopcornKit's (`ProfileManager`); each app decides what a pick does
// (tvOS: SceneDelegate / ProfilesPresenter; iOS and macOS: their root view).

import SwiftUI
import PopcornKit

private func tvOSOr<T>(_ tv: T, _ other: T) -> T {
    #if os(tvOS)
    return tv
    #else
    return other
    #endif
}

func profilesLocalized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

// MARK: - Avatars

/// The avatars a profile can have: a symbol on a gradient. A profile
/// stores the index (`Profile.avatar`); an unknown index wraps around.
enum ProfileAvatar {
    struct Style {
        let symbol: String
        let colors: [Color]
    }

    static let all: [Style] = [
        Style(symbol: "popcorn.fill", colors: [Color(red: 0.95, green: 0.29, blue: 0.24), Color(red: 0.70, green: 0.10, blue: 0.20)]),
        Style(symbol: "star.fill", colors: [Color(red: 0.20, green: 0.48, blue: 0.98), Color(red: 0.10, green: 0.22, blue: 0.65)]),
        Style(symbol: "bolt.fill", colors: [Color(red: 0.98, green: 0.74, blue: 0.18), Color(red: 0.90, green: 0.45, blue: 0.08)]),
        Style(symbol: "leaf.fill", colors: [Color(red: 0.25, green: 0.78, blue: 0.45), Color(red: 0.06, green: 0.45, blue: 0.30)]),
        Style(symbol: "moon.stars.fill", colors: [Color(red: 0.55, green: 0.35, blue: 0.95), Color(red: 0.28, green: 0.13, blue: 0.62)]),
        Style(symbol: "heart.fill", colors: [Color(red: 0.98, green: 0.40, blue: 0.62), Color(red: 0.76, green: 0.15, blue: 0.40)]),
        Style(symbol: "gamecontroller.fill", colors: [Color(red: 0.15, green: 0.75, blue: 0.85), Color(red: 0.05, green: 0.42, blue: 0.58)]),
        Style(symbol: "pawprint.fill", colors: [Color(red: 0.80, green: 0.56, blue: 0.36), Color(red: 0.50, green: 0.30, blue: 0.16)]),
        Style(symbol: "music.note", colors: [Color(red: 0.98, green: 0.52, blue: 0.30), Color(red: 0.85, green: 0.20, blue: 0.45)]),
        Style(symbol: "film.fill", colors: [Color(red: 0.45, green: 0.50, blue: 0.58), Color(red: 0.20, green: 0.23, blue: 0.30)]),
        Style(symbol: "sparkles", colors: [Color(red: 0.35, green: 0.85, blue: 0.75), Color(red: 0.25, green: 0.40, blue: 0.90)]),
        Style(symbol: "flame.fill", colors: [Color(red: 1.00, green: 0.55, blue: 0.10), Color(red: 0.85, green: 0.12, blue: 0.10)]),
    ]

    static func style(_ index: Int) -> Style {
        all[((index % all.count) + all.count) % all.count]
    }

    /// The avatar of a new profile: the first that no profile has yet.
    static func firstUnused(by profiles: [Profile]) -> Int {
        let used = Set(profiles.map { ((($0.avatar % all.count) + all.count) % all.count) })
        return all.indices.first { !used.contains($0) } ?? profiles.count % all.count
    }
}

struct ProfileAvatarView: View {
    let avatar: Int
    var size: CGFloat

    var body: some View {
        let style = ProfileAvatar.style(avatar)
        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
            .fill(LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: style.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: size * 0.03, y: size * 0.015)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Model

/// The profiles as the screens show them, kept current.
@MainActor
final class ProfilesModel: ObservableObject {
    @Published private(set) var profiles: [Profile]
    @Published private(set) var activeID: String
    let manager: ProfileManager
    private var observers: [NSObjectProtocol] = []

    init(manager: ProfileManager = .shared) {
        self.manager = manager
        profiles = manager.profiles
        activeID = manager.activeID
        for name in [Notification.Name.profilesDidChange, .activeProfileDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func reload() {
        profiles = manager.profiles
        activeID = manager.activeID
    }

    var canAdd: Bool { profiles.count < ProfileManager.maxProfiles }

    /// nil when saved; else the text to show.
    func save(_ draft: ProfileDraft) -> String? {
        do {
            if let id = draft.id {
                try manager.update(id, name: draft.name, avatar: draft.avatar)
            } else {
                try manager.create(name: draft.name, avatar: draft.avatar)
            }
            reload()
            return nil
        } catch let error as ProfileManager.ProfileError {
            return ProfilesModel.message(error)
        } catch {
            return error.localizedDescription
        }
    }

    func delete(_ id: String) {
        try? manager.delete(id)
        reload()
    }

    static func message(_ error: ProfileManager.ProfileError) -> String {
        switch error {
        case .emptyName: return profilesLocalized("Profiles.Error.EmptyName")
        case .duplicateName: return profilesLocalized("Profiles.Error.DuplicateName")
        case .tooManyProfiles: return profilesLocalized("Profiles.Error.TooMany")
        case .cannotDeletePrimary: return profilesLocalized("Profiles.Primary.Note")
        case .unknownProfile: return profilesLocalized("Profiles.Error.EmptyName")
        }
    }
}

/// What the editor changes: a new profile (`id` nil) or an existing one.
struct ProfileDraft: Identifiable, Equatable {
    var id: String?
    var name: String
    var avatar: Int
    var isPrimary: Bool { id == Profile.primaryID }

    var identity: String { id ?? "new" }
}

extension ProfileDraft {
    static func editing(_ profile: Profile) -> ProfileDraft {
        ProfileDraft(id: profile.id, name: profile.name, avatar: profile.avatar)
    }
}

// MARK: - « Who's Watching? »

/// The profiles in a row: a press picks one (`onPick`), « Manage Profiles »
/// turns a press into editing it; « Add Profile » makes one.
struct ProfilePickerView: View {
    @StateObject private var model: ProfilesModel
    /// The profile picked (already the active one when `onPick` is called).
    let onPick: (Profile) -> Void
    /// nil: no way out but picking (at launch).
    let onCancel: (() -> Void)?

    @State private var managing = false
    @State private var draft: ProfileDraft?

    init(manager: ProfileManager = .shared, startsManaging: Bool = false,
         onPick: @escaping (Profile) -> Void, onCancel: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: ProfilesModel(manager: manager))
        _managing = State(initialValue: startsManaging)
        self.onPick = onPick
        self.onCancel = onCancel
    }

    #if os(tvOS)
    private let tile: CGFloat = 230
    private let titleSize: CGFloat = 64
    private let spacing: CGFloat = 60
    #else
    private let tile: CGFloat = 110
    private let titleSize: CGFloat = 32
    private let spacing: CGFloat = 28
    #endif

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.02)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: spacing) {
                Text(profilesLocalized(managing ? "Profiles.Manage" : "Profiles.WhoIsWatching"))
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("Profiles.Title")
                tiles
                manageButton
            }
            .padding(40)
        }
        #if os(tvOS)
        .onExitCommand(perform: exit)
        #endif
        #if os(macOS)
        .sheet(item: $draft) { editor($0) }
        #else
        .fullScreenCover(item: $draft) { editor($0) }
        #endif
    }

    private var tiles: some View {
        #if os(tvOS)
        HStack(spacing: 50) { tileContent }
            .focusSection()
        #else
        // Rows that wrap: two or three tiles a row on an iPhone, one row on
        // an iPad or a Mac.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tile + 20, maximum: tile + 40), spacing: spacing)], spacing: spacing) {
            tileContent
        }
        .frame(maxWidth: 3 * (tile + 40) + 2 * spacing)
        #endif
    }

    @ViewBuilder
    private var tileContent: some View {
        ForEach(model.profiles) { profile in
            SwiftUI.Button { press(profile) } label: {
                ProfileTileLabel(name: profile.name, size: tile, isEditing: managing,
                                 isActive: profile.id == model.activeID && onCancel != nil) {
                    ProfileAvatarView(avatar: profile.avatar, size: tile)
                }
            }
            .buttonStyle(ProfileTileStyle())
            .accessibilityLabel(Text(profile.name))
            .accessibilityIdentifier("Profiles.Profile.\(profile.name)")
        }
        if model.canAdd {
            SwiftUI.Button {
                draft = ProfileDraft(id: nil, name: "", avatar: ProfileAvatar.firstUnused(by: model.profiles))
            } label: {
                ProfileTileLabel(name: profilesLocalized("Profiles.Add"), size: tile, isEditing: false, isActive: false) {
                    RoundedRectangle(cornerRadius: tile * 0.18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: tile * 0.02)
                        .overlay {
                            Image(systemName: "plus").font(.system(size: tile * 0.35, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(width: tile, height: tile)
                }
            }
            .buttonStyle(ProfileTileStyle())
            .accessibilityIdentifier("Profiles.Add")
        }
    }

    private var manageButton: some View {
        HStack(spacing: 30) {
            SwiftUI.Button {
                managing.toggle()
            } label: {
                Label(profilesLocalized(managing ? "Profiles.Done" : "Profiles.Manage"),
                      systemImage: managing ? "checkmark" : "pencil")
                    .padding(.horizontal, 10)
            }
            .accessibilityIdentifier("Profiles.Manage")
            if let onCancel {
                SwiftUI.Button(profilesLocalized("Profiles.Cancel"), action: onCancel)
                    .accessibilityIdentifier("Profiles.Cancel")
            }
        }
        #if !os(tvOS)
        .buttonStyle(.bordered)
        .tint(.white)
        #endif
    }

    private func press(_ profile: Profile) {
        if managing {
            draft = .editing(profile)
        } else {
            model.manager.activate(profile.id)
            onPick(profile)
        }
    }

    private func exit() {
        if managing { managing = false } else { onCancel?() }
    }

    private func editor(_ draft: ProfileDraft) -> some View {
        ProfileEditorView(model: model, draft: draft) { self.draft = nil }
    }
}

/// An avatar and its name; a pencil over it while editing.
private struct ProfileTileLabel<Avatar: View>: View {
    let name: String
    let size: CGFloat
    let isEditing: Bool
    let isActive: Bool
    @ViewBuilder let avatar: () -> Avatar

    var body: some View {
        VStack(spacing: size * 0.09) {
            avatar()
                .overlay {
                    if isEditing {
                        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                            .fill(.black.opacity(0.45))
                            .overlay { Image(systemName: "pencil").font(.system(size: size * 0.3, weight: .semibold)).foregroundStyle(.white) }
                    }
                }
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                            .strokeBorder(.white, lineWidth: max(2, size * 0.02))
                    }
                }
            Text(name)
                .font(.system(size: max(15, size * 0.13), weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: size * 1.2)
        }
    }
}

/// The tiles grow and brighten when focused (Apple TV), dim when pressed.
private struct ProfileTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.65))
                .scaleEffect(isFocused ? 1.1 : (configuration.isPressed ? 0.95 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 20, y: 12)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Editor

/// A profile's name and avatar; Delete for a profile other than the main one.
struct ProfileEditorView: View {
    @ObservedObject var model: ProfilesModel
    @State var draft: ProfileDraft
    let onClose: () -> Void

    @State private var error: String?
    @State private var confirmDelete = false

    #if os(tvOS)
    private let preview: CGFloat = 200
    private let avatarSize: CGFloat = 110
    private let columns = Array(repeating: GridItem(.fixed(130), spacing: 30), count: 6)
    #else
    private let preview: CGFloat = 96
    private let avatarSize: CGFloat = 52
    /// As many as the width takes (two rows of six on an iPad or a Mac,
    /// three of four on an iPhone).
    private let columns = [GridItem(.adaptive(minimum: 60, maximum: 72), spacing: 14)]
    #endif

    var body: some View {
        ZStack {
            Color(white: 0.06).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    Text(profilesLocalized(draft.id == nil ? "Profiles.New" : "Profiles.Edit"))
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    ProfileAvatarView(avatar: draft.avatar, size: preview)
                    TextField(profilesLocalized("Profiles.Name"), text: $draft.name)
                        #if !os(macOS)
                        .textContentType(.name)
                        #endif
                        .autocorrectionDisabled()
                        #if !os(tvOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .frame(maxWidth: 600)
                        .accessibilityIdentifier("Profiles.Editor.Name")
                        .onChange(of: draft.name) { _, name in
                            if name.count > ProfileManager.maxNameLength { draft.name = String(name.prefix(ProfileManager.maxNameLength)) }
                            error = nil
                        }
                    if let error {
                        Text(error).foregroundStyle(.red).font(.callout)
                            .accessibilityIdentifier("Profiles.Editor.Error")
                    }
                    Text(profilesLocalized("Profiles.Avatar")).font(.headline).foregroundStyle(.white.opacity(0.7))
                    LazyVGrid(columns: columns, spacing: tvOSOr(24, 14)) {
                        ForEach(ProfileAvatar.all.indices, id: \.self) { index in
                            SwiftUI.Button { draft.avatar = index } label: {
                                ProfileAvatarView(avatar: index, size: avatarSize)
                                    .overlay {
                                        if index == draft.avatar {
                                            RoundedRectangle(cornerRadius: avatarSize * 0.18, style: .continuous)
                                                .strokeBorder(.white, lineWidth: 3)
                                        }
                                    }
                            }
                            .buttonStyle(ProfileTileStyle())
                            .accessibilityLabel(Text("\(profilesLocalized("Profiles.Avatar")) \(index + 1)"))
                            .accessibilityAddTraits(index == draft.avatar ? .isSelected : [])
                        }
                    }
                    #if os(tvOS)
                    .focusSection()
                    #else
                    .frame(maxWidth: 480)
                    #endif
                    buttons
                    if draft.isPrimary {
                        Text(profilesLocalized("Profiles.Primary.Note"))
                            .font(.footnote).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                            .frame(maxWidth: 700)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity)
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
        .alert(profilesLocalized("Profiles.Delete"), isPresented: $confirmDelete) {
            SwiftUI.Button(profilesLocalized("Profiles.Delete"), role: .destructive) {
                if let id = draft.id { model.delete(id) }
                onClose()
            }
            SwiftUI.Button(profilesLocalized("Profiles.Cancel"), role: .cancel) {}
        } message: {
            Text(String(format: profilesLocalized("Profiles.Delete.Message"), draft.name))
        }
    }

    /// Save and Cancel; Delete on a line of its own, under them.
    private var buttons: some View {
        VStack(spacing: tvOSOr(30, 18)) {
            HStack(spacing: 30) {
                SwiftUI.Button(profilesLocalized("Profiles.Save")) {
                    if let message = model.save(draft) { error = message } else { onClose() }
                }
                #if !os(tvOS)
                .keyboardShortcut(.defaultAction)
                #endif
                .accessibilityIdentifier("Profiles.Editor.Save")
                SwiftUI.Button(profilesLocalized("Profiles.Cancel"), role: .cancel, action: onClose)
                    #if !os(tvOS)
                    .keyboardShortcut(.cancelAction)
                    #endif
                    .accessibilityIdentifier("Profiles.Editor.Cancel")
            }
            if let id = draft.id, id != Profile.primaryID {
                SwiftUI.Button(profilesLocalized("Profiles.Delete"), role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("Profiles.Editor.Delete")
            }
        }
        .lineLimit(1)
        #if !os(tvOS)
        .buttonStyle(.bordered)
        #endif
    }
}

// MARK: - iPhone, iPad and Mac: the gate

#if !os(tvOS)
extension Notification.Name {
    /// Asks the root's `ProfileGate` for « Who's Watching? » (Settings ›
    /// Switch Profile); `object` true: in its Manage mode.
    static let showProfilePicker = Notification.Name("PopcornTime.showProfilePicker")
}

/// The app's root behind « Who's Watching? »: the picker at launch when the
/// device has more than one profile, and whenever Settings asks for it. The
/// content is made again for another profile (`.id`): every screen then
/// reads the new profile's library and preferences.
struct ProfileGate<Content: View>: View {
    @ViewBuilder let content: () -> Content

    private enum Picker: Equatable {
        case launch
        case settings(managing: Bool)
    }

    @State private var picker: Picker? = ProfileManager.shared.asksAtLaunch ? .launch : nil
    @State private var activeID = ProfileManager.shared.activeID

    var body: some View {
        Group {
            if let picker {
                switch picker {
                case .launch:
                    ProfilePickerView(onPick: { _ in close() })
                case .settings(let managing):
                    ProfilePickerView(startsManaging: managing, onPick: { _ in close() }, onCancel: close)
                }
            } else {
                content().id(activeID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            activeID = ProfileManager.shared.activeID
        }
        .onReceive(NotificationCenter.default.publisher(for: .showProfilePicker)) { note in
            picker = .settings(managing: note.object as? Bool ?? false)
        }
    }

    private func close() {
        activeID = ProfileManager.shared.activeID
        picker = nil
    }
}

/// Content made again when another profile becomes active (the Mac's
/// Settings window, beside the main one).
struct ProfileScoped<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var activeID = ProfileManager.shared.activeID

    var body: some View {
        content()
            .id(activeID)
            .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
                activeID = ProfileManager.shared.activeID
            }
    }
}

/// Settings' Profiles section (iPhone, iPad, Mac): the active profile, Switch
/// Profile, Manage Profiles.
struct ProfilesSettingsSection: View {
    @StateObject private var model = ProfilesModel()
    @State private var showsTaste = false
    @State private var tasteSummary = ProfileTasteModel.summary()

    var body: some View {
        Section {
            if let profile = model.profiles.first(where: { $0.id == model.activeID }) {
                HStack(spacing: 12) {
                    ProfileAvatarView(avatar: profile.avatar, size: 36)
                    Text(String(format: profilesLocalized("Profiles.Current"), profile.name))
                }
            }
            Button {
                NotificationCenter.default.post(name: .showProfilePicker, object: false)
            } label: {
                Label(profilesLocalized("Profiles.Switch"), systemImage: "person.crop.circle.badge.checkmark")
            }
            .accessibilityIdentifier("Settings.SwitchProfile")
            Button {
                NotificationCenter.default.post(name: .showProfilePicker, object: true)
            } label: {
                Label(profilesLocalized("Profiles.Manage"), systemImage: "person.2")
            }
            .accessibilityIdentifier("Settings.ManageProfiles")
            Button {
                showsTaste = true
            } label: {
                LabeledContent {
                    Text(tasteSummary ?? profilesLocalized("Profiles.Taste.Nothing"))
                } label: {
                    Label(profilesLocalized("Profiles.Taste"), systemImage: "sparkles")
                }
            }
            .accessibilityIdentifier("Settings.ProfilePreferences")
            .sheet(isPresented: $showsTaste, onDismiss: { tasteSummary = ProfileTasteModel.summary() }) {
                ProfileTasteView(onClose: { showsTaste = false })
                    #if os(macOS)
                    .frame(minWidth: 560, minHeight: 460)
                    #endif
            }
        } header: {
            Text(profilesLocalized("Profiles"))
        } footer: {
            Text(profilesLocalized("Profiles.Footer"))
        }
    }
}
#endif
