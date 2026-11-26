// ProfileViews.swift — « Who's Watching? » and the profile editor, for the
// Apple TV, the iPhone and iPad, and the Mac; Settings' Profiles section on
// the iPhone and iPad, and the Mac's Profiles pane. The profiles themselves
// are PopcornKit's (`ProfileManager`); each app decides what a pick does
// (tvOS: SceneDelegate / ProfilesPresenter; iOS and macOS: `ProfileGate`,
// Settings, the Mac's Switch Profile… command).
//
// The look is the app's dark glass, quiet: circles of one calm tone each, a
// white ring that only ever means focus (Apple TV) or the pointer (iPad,
// Mac), a check for the profile in use, the system's glass buttons.

import SwiftUI
import PopcornKit
#if os(macOS)
import AppKit
#endif

func profilesLocalized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

#if DEBUG
/// `-PTDebugProfilesScreen <name>` (screenshots, DEBUG builds only): a
/// profile screen that needs a press, shown once per run where it can be —
/// `manage` (the picker in Manage mode), `editor` (the second profile's
/// editor, else the first's), `new` (a new profile's editor), on the first
/// picker shown; `picker` (iPhone, iPad: Settings › Switch Profile's cover,
/// with `-PTDebugSettings YES`), `taste` (iPhone, iPad: Your Preferences
/// pushed), `sheet` (Mac: Switch Profile…'s sheet), `paneEditor` (Mac:
/// the Profiles pane's editor of the second profile).
@MainActor
enum ProfilesDebugScreen {
    private static var taken = false

    /// The screen asked for, if it is one of `names` and not shown yet.
    static func take(_ names: Set<String>) -> String? {
        guard !taken, let name = UserDefaults.standard.string(forKey: "PTDebugProfilesScreen"),
              names.contains(name) else { return nil }
        taken = true
        return name
    }
}
#endif

// MARK: - Avatars

/// The avatars a profile can have: a symbol on a circle of one tone. A
/// profile stores the index (`Profile.avatar`): the symbols and their order
/// never change, an unknown index wraps around.
enum ProfileAvatar {
    struct Style {
        let symbol: String
        /// The circle's tone at its top; the bottom is the same hue, a
        /// fifth darker: light falling on it, not a second colour.
        let top: (red: Double, green: Double, blue: Double)

        /// Top, then bottom.
        var colors: [Color] {
            [Color(red: top.red, green: top.green, blue: top.blue),
             Color(red: top.red * 0.8, green: top.green * 0.8, blue: top.blue * 0.8)]
        }
    }

    // Calm tones of moderate saturation, each a hue of its own: a white
    // symbol reads on every one of them.
    static let all: [Style] = [
        Style(symbol: "popcorn.fill", top: (0.70, 0.39, 0.35)),         // clay
        Style(symbol: "star.fill", top: (0.39, 0.52, 0.70)),            // slate blue
        Style(symbol: "bolt.fill", top: (0.64, 0.52, 0.32)),            // ochre
        Style(symbol: "leaf.fill", top: (0.35, 0.58, 0.46)),            // sage
        Style(symbol: "moon.stars.fill", top: (0.48, 0.41, 0.68)),      // lavender
        Style(symbol: "heart.fill", top: (0.70, 0.41, 0.50)),           // rose
        Style(symbol: "gamecontroller.fill", top: (0.29, 0.53, 0.58)),  // teal
        Style(symbol: "pawprint.fill", top: (0.56, 0.50, 0.44)),        // taupe
        Style(symbol: "music.note", top: (0.62, 0.38, 0.54)),           // plum
        Style(symbol: "film.fill", top: (0.45, 0.47, 0.52)),            // graphite
        Style(symbol: "sparkles", top: (0.50, 0.55, 0.33)),             // olive
        Style(symbol: "flame.fill", top: (0.68, 0.45, 0.34)),           // burnt orange
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

/// A profile's avatar: its symbol on its circle, with the hairline the cast
/// photos have. Decoration only: the tile or the row says the name.
struct ProfileAvatarView: View {
    let avatar: Int
    var size: CGFloat
    /// false: the tone alone (Manage mode, where the pencil is the one
    /// symbol on the circle).
    var showsSymbol = true

    var body: some View {
        let style = ProfileAvatar.style(avatar)
        Circle()
            .fill(LinearGradient(colors: style.colors, startPoint: .top, endPoint: .bottom))
            .overlay { Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: max(1, size * 0.006)) }
            .overlay {
                if showsSymbol {
                    Image(systemName: style.symbol)
                        .font(.system(size: size * 0.40, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// « Add Profile »: an outlined, quiet circle — never a bright tile beside
/// the profiles.
private struct ProfileAddAvatar: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.06))
            .overlay {
                #if os(tvOS)
                Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 3)
                #else
                Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1.5)
                #endif
            }
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: size * 0.34, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Manage mode: a pencil on a dark disc over the dimmed tone (its symbol
/// left out), so that only one symbol shows. No glass: it sits inside a
/// button that scales.
private struct ProfileEditMark: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color.black.opacity(0.55))
            .overlay { Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1) }
            .overlay {
                Image(systemName: "pencil")
                    .font(.system(size: size * 0.16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size * 0.36, height: size * 0.36)
            .accessibilityHidden(true)
    }
}

/// The page behind the profile screens: the black of the app's pages, with a
/// faint light at the top for the glass to refract (`GlassSettingsBackdrop`).
private struct ProfilesBackdrop: View {
    /// 1100 on the Apple TV, 900 in a Mac window, 700 on an iPhone or iPad.
    let radius: CGFloat

    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color.white.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: radius)
        }
    }
}

// MARK: - Focus and pointer

private struct ProfileTilePressedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    /// The tile's button is pressed (handed to its label by ProfileTileStyle).
    var profileTilePressed: Bool {
        get { self[ProfileTilePressedKey.self] }
        set { self[ProfileTilePressedKey.self] = newValue }
    }
}

/// The profiles' buttons (tiles, the editor's avatars). The style itself
/// draws nothing: it hands its state to the label — the focus on the Apple
/// TV, the pointer elsewhere (`glassItemFocused`, as GlassCircleButtonStyle
/// does), and the press — and the label lights its circle only
/// (`ProfileCircleLift`): the name under it never moves. The whole label is
/// the hit area, the name included.
private struct ProfileTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused
        #if !os(tvOS)
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        #endif

        var body: some View {
            #if os(tvOS)
            configuration.label
                .environment(\.glassItemFocused, isFocused)
                .environment(\.profileTilePressed, configuration.isPressed)
                .contentShape(Rectangle())
            #else
            configuration.label
                // Full Keyboard Access's focus lights it as the pointer does.
                .environment(\.glassItemFocused, isHovered || isFocused)
                .environment(\.profileTilePressed, configuration.isPressed)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.95 : 1))
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
            #endif
        }
    }
}

/// A circle that answers its button's focus or pointer (`ProfileTileStyle`)
/// as the app's posters do: on the Apple TV it lifts by a tenth, rings in
/// white over a thin dark edge (seen on a light avatar too) and casts a
/// shadow; under a pointer the same at desk scale. A check badge (`badge`:
/// its diameter) sits over the ring, at 45° on the circle's bottom-trailing
/// edge, and lifts with it. No motion under Reduce Motion.
private struct ProfileCircleLift: ViewModifier {
    let size: CGFloat
    var hoverScale: CGFloat = 1.04
    var badge: CGFloat?
    @Environment(\.glassItemFocused) private var lit
    @Environment(\.profileTilePressed) private var pressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .overlay {
                ZStack {
                    Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 2)
                    Circle().inset(by: 2).strokeBorder(Color.white, lineWidth: 4)
                }
                .opacity(lit ? 1 : 0)
            }
            .overlay(alignment: .bottomTrailing) { checkBadge }
            .scaleEffect(pressed ? 1.04 : (lit ? 1.10 : 1))
            .shadow(color: .black.opacity(lit ? 0.6 : 0), radius: 30, y: 16)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: lit)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
        #else
        content
            .overlay {
                ZStack {
                    Circle().strokeBorder(Color.black.opacity(0.85), lineWidth: 2).padding(-2)
                    Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 2).padding(-4)
                }
                .opacity(lit ? 1 : 0)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) { checkBadge }
            .opacity(pressed ? 0.85 : 1)
            .scaleEffect(reduceMotion ? 1 : (lit ? hoverScale : 1))
            .shadow(color: .black.opacity(lit ? 0.55 : 0), radius: lit ? 12 : 0, y: lit ? 6 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: lit)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
        #endif
    }

    @ViewBuilder
    private var checkBadge: some View {
        if let badge {
            // The badge's centre on the circle at 45°: (1 − cos 45°) / 2 of
            // the size from the bottom and trailing edges. Padding, not an
            // offset, so that it mirrors in Arabic.
            let inset = size * 0.146 - badge / 2
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, .white)
                .frame(width: badge, height: badge)
                .background(Circle().fill(Color.black).padding(-3))
                .padding(.trailing, inset)
                .padding(.bottom, inset)
                .accessibilityHidden(true)
        }
    }
}

/// The sizes a tile has in one place (the picker on each platform, the Mac's
/// sheet): its circle, the gap to its name, the name's font and width.
private struct ProfileTileMetrics {
    var tile: CGFloat
    var gap: CGFloat
    var nameFont: Font
    /// Wider than the circle: the name may run into the gap between tiles,
    /// which are laid out by their circles.
    var nameWidth: CGFloat
    var nameLines = 1
}

/// A tile: the circle (lit by its button), then the name under it. On the
/// Apple TV the name goes from secondary to primary with the focus; it never
/// scales.
private struct ProfileTileLabel<Avatar: View>: View {
    let name: String
    let metrics: ProfileTileMetrics
    /// The check of the profile in use.
    var isCurrent = false
    @ViewBuilder let avatar: () -> Avatar
    @Environment(\.glassItemFocused) private var lit

    var body: some View {
        VStack(spacing: metrics.gap) {
            avatar()
                .frame(width: metrics.tile, height: metrics.tile)
                .modifier(ProfileCircleLift(size: metrics.tile, badge: isCurrent ? metrics.tile * 0.20 : nil))
            Text(verbatim: name)
                .font(metrics.nameFont)
                .foregroundStyle(nameColor)
                .lineLimit(metrics.nameLines)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .frame(width: metrics.nameWidth)
        }
        .frame(width: metrics.tile)
    }

    private var nameColor: Color {
        #if os(tvOS)
        return lit ? GlassPalette.primaryText : GlassPalette.secondaryText
        #else
        return .primary
        #endif
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

    var active: Profile? { profiles.first { $0.id == activeID } }

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
            reload()
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
        // Deleted meanwhile (another window of the Mac): the editor closes
        // as soon as it sees it; this is for a save that came first.
        case .unknownProfile: return profilesLocalized("Profiles.Error.Gone")
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

/// The profiles in a row, « Add Profile » last: a press picks one (`onPick`:
/// the host makes it the active profile), « Manage Profiles » turns a press
/// into editing it. Opened to change the profile in use (`onCancel` set),
/// that profile carries a check; at launch nothing is marked and there is no
/// way out but a pick. Its hosts give the way back: Menu on the Apple TV,
/// the glass ✕ of the iPhone's cover, Cancel in the Mac's sheet.
struct ProfilePickerView: View {
    /// `.page`: a screen of its own (every platform). `.sheet`: the Mac's
    /// Popcorn Time › Switch Profile…, a sheet over the window.
    enum Layout {
        case page
        case sheet
    }

    @StateObject private var model: ProfilesModel
    let layout: Layout
    /// The profile picked. The host makes it active (or does nothing when
    /// it already is).
    let onPick: (Profile) -> Void
    /// nil: no way out but picking (at launch).
    let onCancel: (() -> Void)?

    @State private var managing = false
    @State private var draft: ProfileDraft?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(tvOS)
    @FocusState private var focusedTile: String?
    #endif
    #if os(iOS)
    /// The tiles grow with the text size, up to a third more.
    @ScaledMetric(relativeTo: .title) private var typeScale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    init(manager: ProfileManager = .shared, layout: Layout = .page,
         onPick: @escaping (Profile) -> Void, onCancel: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: ProfilesModel(manager: manager))
        self.layout = layout
        self.onPick = onPick
        self.onCancel = onCancel
    }

    /// The profile in use carries a check when the picker is opened to
    /// change it — never on the launch question.
    private var marksCurrent: Bool { onCancel != nil }

    private enum Item: Identifiable {
        case profile(Profile)
        case add

        var id: String {
            switch self {
            case .profile(let profile): return profile.id
            case .add: return "add"
            }
        }
    }

    private var items: [Item] {
        model.profiles.map(Item.profile) + (model.canAdd ? [.add] : [])
    }

    var body: some View {
        content
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: managing)
            #if DEBUG
            .task {
                try? await Task.sleep(for: .milliseconds(600))
                switch ProfilesDebugScreen.take(["manage", "editor", "new"]) {
                case "manage": managing = true
                case "editor": draft = (model.profiles.dropFirst().first ?? model.profiles.first).map(ProfileDraft.editing)
                case "new": draft = ProfileDraft(id: nil, name: "", avatar: ProfileAvatar.firstUnused(by: model.profiles))
                default: break
                }
            }
            #endif
            #if os(tvOS)
            // At launch (nothing to go back to) Menu is the system's: it
            // leaves the app for the Home Screen, as on any first screen.
            // Elsewhere it leaves Manage mode first, then closes.
            .onExitCommand(perform: managing || onCancel != nil ? { exit() } : nil)
            .fullScreenCover(item: $draft) { editor($0) }
            #else
            .sheet(item: $draft) { editor($0) }
            #endif
    }

    private var title: some View {
        Text(profilesLocalized(managing ? "Profiles.Manage" : "Profiles.WhoIsWatching"))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("Profiles.Title")
    }

    // MARK: Layouts

    #if os(tvOS)
    /// 1920 × 1080: the title, 72 pt, the row of 220 pt circles 80 pt apart,
    /// 88 pt, Manage Profiles — the block centred.
    private var content: some View {
        ZStack {
            ProfilesBackdrop(radius: 1100).ignoresSafeArea()
            VStack(spacing: 0) {
                title
                    .font(.system(size: 60, weight: .bold))
                    .foregroundStyle(GlassPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(alignment: .top, spacing: 80) {
                    ForEach(items) { itemView($0) }
                }
                .focusSection()
                .padding(.top, 72)
                // Down from any tile reaches the button; Up from it goes
                // back to the tile it came from.
                HStack { manageButton.glassActionStyle() }
                    .frame(maxWidth: .infinity)
                    .focusSection()
                    .padding(.top, 88)
            }
            .padding(.horizontal, 90)
        }
        // The profile in use first, at launch as from Settings.
        .defaultFocus($focusedTile, model.activeID)
    }
    #elseif os(macOS)
    @ViewBuilder
    private var content: some View {
        switch layout {
        case .page:
            // The launch question, in the window.
            ZStack {
                ProfilesBackdrop(radius: 900).ignoresSafeArea()
                VStack(spacing: 0) {
                    title
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(GlassPalette.primaryText)
                    HStack(alignment: .top, spacing: 36) {
                        ForEach(items) { itemView($0) }
                    }
                    .padding(.top, 40)
                    manageButton
                        .glassActionStyle()
                        .controlSize(.large)
                        .padding(.top, 44)
                }
                .padding(40)
            }
        case .sheet:
            VStack(spacing: 0) {
                VStack(spacing: 28) {
                    title
                        .font(.system(size: 26, weight: .bold))
                        .multilineTextAlignment(.center)
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(items) { itemView($0) }
                    }
                }
                .padding(.top, 32)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                Divider()
                HStack {
                    manageButton
                    Spacer()
                    if let onCancel {
                        Button(profilesLocalized("Profiles.Cancel"), action: onCancel)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("Profiles.Cancel")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(width: 680)
        }
    }
    #else
    /// Centred on the screen; it scrolls only when the text is very large.
    private var content: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 32) {
                    title
                        .font(.largeTitle.bold())
                        .foregroundStyle(GlassPalette.primaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    rows(width: proxy.size.width - 32)
                    manageButton
                        .glassActionStyle()
                        .controlSize(.large)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background { ProfilesBackdrop(radius: 700).ignoresSafeArea() }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// One row when every tile fits, else rows of three (or two), each
    /// centred: « Add Profile » alone on the last row stays in the middle.
    private func rows(width: CGFloat) -> some View {
        let all = items
        let spacing: CGFloat = isPhone ? 24 : 40
        let rows = ProfilePickerRows.rows(count: all.count, tile: metrics.tile, spacing: spacing, width: width)
        return VStack(spacing: isPhone ? 28 : 36) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(rows[row].map { all[$0] }) { itemView($0) }
                }
            }
        }
    }
    #endif

    private var metrics: ProfileTileMetrics {
        #if os(tvOS)
        return ProfileTileMetrics(tile: 220, gap: 32, nameFont: .system(size: 30, weight: .medium), nameWidth: 260)
        #elseif os(macOS)
        switch layout {
        case .page: return ProfileTileMetrics(tile: 120, gap: 12, nameFont: .system(size: 15, weight: .medium), nameWidth: 144)
        case .sheet: return ProfileTileMetrics(tile: 96, gap: 10, nameFont: .system(size: 13, weight: .medium), nameWidth: 112)
        }
        #else
        let tile = (isPhone ? 96 : 120) * min(max(typeScale, 1), 1.35)
        return ProfileTileMetrics(tile: tile, gap: isPhone ? 10 : 12,
                                  nameFont: (isPhone ? Font.subheadline : Font.body).weight(.medium),
                                  nameWidth: tile + (isPhone ? 16 : 24),
                                  nameLines: dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        #endif
    }

    // MARK: Tiles

    @ViewBuilder
    private func itemView(_ item: Item) -> some View {
        let metrics = self.metrics
        switch item {
        case .profile(let profile):
            let isCurrent = marksCurrent && profile.id == model.activeID
            SwiftUI.Button { press(profile) } label: {
                ProfileTileLabel(name: profile.name, metrics: metrics, isCurrent: isCurrent && !managing) {
                    ProfileAvatarView(avatar: profile.avatar, size: metrics.tile, showsSymbol: !managing)
                        .opacity(managing ? 0.4 : 1)
                        .overlay { if managing { ProfileEditMark(size: metrics.tile) } }
                }
            }
            .buttonStyle(ProfileTileStyle())
            #if os(tvOS)
            .focused($focusedTile, equals: profile.id)
            #endif
            .accessibilityLabel(Text(verbatim: managing
                                     ? String(format: profilesLocalized("Profiles.EditNamed"), profile.name)
                                     : profile.name))
            .accessibilityValue(Text(verbatim: isCurrent ? profilesLocalized("Profiles.CurrentValue") : ""))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityIdentifier("Profiles.Profile.\(profile.name)")
        case .add:
            SwiftUI.Button {
                draft = ProfileDraft(id: nil, name: "", avatar: ProfileAvatar.firstUnused(by: model.profiles))
            } label: {
                ProfileTileLabel(name: profilesLocalized("Profiles.Add"), metrics: metrics) {
                    ProfileAddAvatar(size: metrics.tile)
                }
            }
            .buttonStyle(ProfileTileStyle())
            .accessibilityLabel(Text(verbatim: profilesLocalized("Profiles.Add")))
            .accessibilityIdentifier("Profiles.Add")
        }
    }

    /// Manage Profiles, or Done in Manage mode: text only.
    private var manageButton: some View {
        SwiftUI.Button {
            managing.toggle()
        } label: {
            Text(profilesLocalized(managing ? "Profiles.Done" : "Profiles.Manage"))
                .lineLimit(1)
        }
        #if !os(tvOS)
        // Neutral glass, white words: the app's red tint is kept for what
        // deletes.
        .tint(.primary)
        #endif
        .accessibilityIdentifier("Profiles.Manage")
    }

    private func press(_ profile: Profile) {
        if managing {
            draft = .editing(profile)
        } else {
            onPick(profile)
        }
    }

    #if os(tvOS)
    private func exit() {
        if managing { managing = false } else { onCancel?() }
    }
    #endif

    private func editor(_ draft: ProfileDraft) -> some View {
        ProfileEditorView(model: model, draft: draft) { self.draft = nil }
    }
}

// MARK: - Editor

/// A profile's name and avatar; Delete for a profile other than the main
/// one. Apple TV: a glass card over the dimmed picker, as Settings' sheets.
/// iPhone and iPad: a system form sheet. Mac: a sheet with its buttons at
/// the bottom, as the Settings window's sheets.
struct ProfileEditorView: View {
    @ObservedObject var model: ProfilesModel
    let onClose: () -> Void

    @State private var draft: ProfileDraft
    /// As opened: a sheet with changes is not swiped away (iPhone).
    private let initial: ProfileDraft
    @State private var error: String?
    @State private var confirmDelete = false
    #if os(tvOS)
    private enum Field: Hashable { case name, save }
    @FocusState private var focus: Field?
    @Environment(\.glassSettingsFallback) private var fallback
    #else
    @FocusState private var nameFocused: Bool
    #endif

    init(model: ProfilesModel, draft: ProfileDraft, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _draft = State(initialValue: draft)
        initial = draft
    }

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDirty: Bool { draft.name != initial.name || draft.avatar != initial.avatar }
    /// Delete is offered for a profile saved before, other than the main one.
    private var isDeletable: Bool { draft.id != nil && !draft.isPrimary }
    private var title: String { profilesLocalized(draft.id == nil ? "Profiles.New" : "Profiles.Edit") }

    var body: some View {
        content
            .onChange(of: draft.name) { _, name in
                if name.count > ProfileManager.maxNameLength { draft.name = String(name.prefix(ProfileManager.maxNameLength)) }
                error = nil
            }
            // Deleted meanwhile (the Mac's other window, Settings): there is
            // nothing left to edit.
            .onChange(of: model.profiles) { _, profiles in
                if let id = draft.id, !profiles.contains(where: { $0.id == id }) { onClose() }
            }
            .alert(profilesLocalized("Profiles.Delete"), isPresented: $confirmDelete) {
                SwiftUI.Button(profilesLocalized("Profiles.Delete"), role: .destructive) {
                    if let id = draft.id { model.delete(id) }
                    onClose()
                }
                SwiftUI.Button(profilesLocalized("Profiles.Cancel"), role: .cancel) {}
            } message: {
                Text(verbatim: String(format: profilesLocalized("Profiles.Delete.Message"), draft.name))
            }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if let message = model.save(draft) { error = message } else { onClose() }
    }

    #if os(tvOS)
    /// A 1100 pt card: the title; the 200 pt preview beside the name and the
    /// avatars; Save and Cancel; Delete Profile on a row of its own, or the
    /// main profile's note. It fits the screen without scrolling.
    private var content: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                HStack(alignment: .top, spacing: 56) {
                    ProfileAvatarView(avatar: draft.avatar, size: 200)
                        .frame(width: 220)
                    VStack(alignment: .leading, spacing: 0) {
                        // The field's focus region spans the column: Up
                        // from any column of avatars reaches it.
                        HStack {
                            TextField(profilesLocalized("Profiles.Name"), text: $draft.name)
                                .textContentType(.name)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .name)
                                .onSubmit { if !trimmedName.isEmpty { focus = .save } }
                                .accessibilityIdentifier("Profiles.Editor.Name")
                        }
                        .frame(maxWidth: .infinity)
                        .focusSection()
                        if let error {
                            errorLine(error)
                                .padding(.top, 14)
                        }
                        avatarGrid
                            .focusSection()
                            .padding(.top, 28)
                    }
                    .frame(width: 708)
                }
                .padding(.top, 36)
                HStack(spacing: 24) {
                    SwiftUI.Button(profilesLocalized("Profiles.Save"), action: save)
                        .glassActionStyle(prominent: true)
                        .disabled(trimmedName.isEmpty)
                        .focused($focus, equals: .save)
                        .accessibilityIdentifier("Profiles.Editor.Save")
                    SwiftUI.Button(profilesLocalized("Profiles.Cancel"), action: onClose)
                        .glassActionStyle()
                        .accessibilityIdentifier("Profiles.Editor.Cancel")
                }
                .lineLimit(1)
                .focusSection()
                .padding(.top, 40)
                if isDeletable {
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 1)
                        .padding(.top, 24)
                    deleteRow
                        .focusSection()
                        .padding(.top, 10)
                } else if draft.isPrimary {
                    Text(verbatim: profilesLocalized("Profiles.Primary.Note"))
                        .font(.system(size: 24))
                        .foregroundStyle(GlassSettingsPalette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                }
            }
            .padding(.top, 58)
            .padding(.horizontal, 58)
            .padding(.bottom, 40)
            .frame(width: 1100)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(GlassSettingsCard(cornerRadius: 50, fallback: fallback))
        }
        .defaultFocus($focus, .name)
        // Menu: Cancel, nothing kept.
        .onExitCommand(perform: onClose)
        .presentationBackground(.clear)
    }

    /// Two rows of six, each circle lit by the focus; the chosen one has the
    /// check (the white ring is the focus's).
    private var avatarGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 28), count: 6), spacing: 28) {
            ForEach(ProfileAvatar.all.indices, id: \.self) { index in
                SwiftUI.Button { draft.avatar = index } label: {
                    ProfileAvatarView(avatar: index, size: 84)
                        .modifier(ProfileCircleLift(size: 84, badge: index == draft.avatar ? 25 : nil))
                }
                .buttonStyle(ProfileTileStyle())
                .accessibilityLabel(Text(verbatim: "\(profilesLocalized("Profiles.Avatar")) \(index + 1)"))
                .accessibilityAddTraits(index == draft.avatar ? .isSelected : [])
                .accessibilityIdentifier("Profiles.Editor.Avatar.\(index)")
            }
        }
        // Its own width (6 × 84 + 5 × 28): under the field's leading edge,
        // not centred in the column.
        .frame(width: 644)
    }

    /// Delete Profile, a row of the card: red words that stay red on the
    /// focused white platter (large text, readable), never red on red. The
    /// confirmation carries the destructive role.
    private var deleteRow: some View {
        SwiftUI.Button { confirmDelete = true } label: {
            Text(verbatim: profilesLocalized("Profiles.Delete"))
                .font(.system(size: 31, weight: .medium))
                .foregroundStyle(GlassPalette.accent)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.vertical, 18)
        }
        .buttonStyle(GlassSettingsRowStyle(cornerRadius: 22))
        .accessibilityIdentifier("Profiles.Editor.Delete")
    }

    private func errorLine(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .font(.system(size: 24, weight: .medium))
        .foregroundStyle(GlassPalette.accent)
        .accessibilityIdentifier("Profiles.Editor.Error")
    }
    #elseif os(macOS)
    /// The Settings window's sheet build: the title, a grouped form, then
    /// Delete Profile… (leading), Cancel and Save.
    private var content: some View {
        VStack(spacing: 0) {
            Text(verbatim: title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 4)
            Form {
                Section {
                    ProfileAvatarView(avatar: draft.avatar, size: 72)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    TextField(text: $draft.name, prompt: Text(verbatim: profilesLocalized("Profiles.Name"))) {
                        Text(verbatim: profilesLocalized("Profiles.Name"))
                    }
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                    .onSubmit(save)
                    .accessibilityIdentifier("Profiles.Editor.Name")
                } footer: {
                    nameFooter
                }
                Section(profilesLocalized("Profiles.Avatar")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 12), count: 6), spacing: 12) {
                        avatarCells(size: 36)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                if isDeletable {
                    Button(profilesLocalized("Profiles.Delete") + "…", role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("Profiles.Editor.Delete")
                }
                Spacer()
                Button(profilesLocalized("Profiles.Cancel"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("Profiles.Editor.Cancel")
                Button(profilesLocalized("Profiles.Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("Profiles.Editor.Save")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .onAppear { if draft.id == nil { nameFocused = true } }
    }
    #else
    /// A system form: the preview and the name, the avatars, Delete Profile;
    /// Cancel and Done in the bar.
    private var content: some View {
        NavigationStack {
            Form {
                Section {
                    ProfileAvatarView(avatar: draft.avatar, size: 88)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                    TextField(profilesLocalized("Profiles.Name"), text: $draft.name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .accessibilityIdentifier("Profiles.Editor.Name")
                } footer: {
                    nameFooter
                }
                Section(profilesLocalized("Profiles.Avatar")) {
                    let cell: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 44 : 48
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: 56), spacing: 14)], spacing: 14) {
                        avatarCells(size: cell)
                    }
                    .padding(.vertical, 8)
                }
                if isDeletable {
                    Section {
                        Button(profilesLocalized("Profiles.Delete"), role: .destructive) { confirmDelete = true }
                            .accessibilityIdentifier("Profiles.Editor.Delete")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(profilesLocalized("Profiles.Cancel"), action: onClose)
                        .accessibilityIdentifier("Profiles.Editor.Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(profilesLocalized("Profiles.Done"), action: save)
                        .bold()
                        .disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier("Profiles.Editor.Save")
                }
            }
        }
        // Full height on an iPhone; the iPad keeps its form sheet.
        .presentationDetents([.large])
        .interactiveDismissDisabled(isDirty)
        // A new profile starts with its name; an edit does not bring the
        // keyboard up over the avatars.
        .task {
            guard draft.id == nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            nameFocused = true
        }
    }
    #endif

    #if !os(tvOS)
    /// Under the name: the error, else the main profile's note.
    @ViewBuilder
    private var nameFooter: some View {
        if let error {
            Label {
                Text(verbatim: error)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .foregroundStyle(GlassPalette.accent)
            .accessibilityIdentifier("Profiles.Editor.Error")
        } else if draft.isPrimary {
            Text(verbatim: profilesLocalized("Profiles.Primary.Note"))
        }
    }

    /// The avatars: the chosen one ringed in white, just outside its circle
    /// (no focus ring on these platforms to mistake it for).
    private func avatarCells(size: CGFloat) -> some View {
        ForEach(ProfileAvatar.all.indices, id: \.self) { index in
            SwiftUI.Button { draft.avatar = index } label: {
                ProfileAvatarView(avatar: index, size: size)
                    .overlay {
                        if index == draft.avatar {
                            Circle().strokeBorder(Color.white, lineWidth: 2.5).padding(-5)
                        }
                    }
                    .modifier(ProfileCircleLift(size: size, hoverScale: 1.06))
            }
            .buttonStyle(ProfileTileStyle())
            .accessibilityLabel(Text(verbatim: "\(profilesLocalized("Profiles.Avatar")) \(index + 1)"))
            .accessibilityAddTraits(index == draft.avatar ? .isSelected : [])
            .accessibilityIdentifier("Profiles.Editor.Avatar.\(index)")
        }
    }
    #endif
}

// MARK: - iPhone, iPad and Mac: the gate

#if !os(tvOS)
/// The app's root behind « Who's Watching? »: the question at launch when
/// the device has more than one profile — in every window, until a pick in
/// one of them answers it (`ProfileLaunchQuestion`). The content is made
/// again for another profile (`.id`): every screen then reads the new
/// profile's library and preferences. Settings and the Mac's menu present
/// the picker themselves, over what is on screen.
struct ProfileGate<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @ObservedObject private var question = ProfileLaunchQuestion.shared
    @State private var activeID = ProfileManager.shared.activeID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if question.isAsking {
                ProfilePickerView(onPick: { profile in
                    ProfileManager.shared.activate(profile.id)
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { question.answer() }
                })
                .transition(.opacity)
                #if DEBUG
                // `-PTDebugProfilesPick <name>`: that profile answers the
                // question at once (screenshots of the content with several
                // profiles, DEBUG builds only).
                .onAppear {
                    guard let name = UserDefaults.standard.string(forKey: "PTDebugProfilesPick"),
                          let profile = ProfileManager.shared.profiles.first(where: { $0.name == name }) else { return }
                    ProfileManager.shared.activate(profile.id)
                    question.answer()
                }
                #endif
            } else {
                content()
                    .id(activeID)
                    .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            activeID = ProfileManager.shared.activeID
        }
        // A link while the question is up has no screen to open in: held,
        // and opened by the content once a profile is picked
        // (`ProfileLaunchQuestion.takeHeldLink`). Trakt's redirect is not a
        // link to show: it stays the app's.
        .onOpenURL { url in
            if question.isAsking, DeepLink(url: url) != nil { question.hold(url) }
        }
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
#endif

// MARK: - iPhone and iPad: Settings › Profiles

#if os(iOS)
/// Settings' Profiles section: Switch Profile (the profile in use as its
/// value; « Who's Watching? » over Settings) and Your Preferences (pushed).
/// Manage Profiles is the picker's own button.
struct ProfilesSettingsSection: View {
    @StateObject private var model = ProfilesModel()
    @State private var tasteSummary = ProfileTasteModel.summary()
    @State private var showsPicker = false
    /// Another profile picked: made active once the cover has gone. The
    /// app's content is then made again for it, which closes Settings.
    @State private var picked: String?
    #if DEBUG
    @State private var debugTaste = false
    #endif

    var body: some View {
        Section {
            if let profile = model.active {
                switchRow(profile)
            }
            NavigationLink {
                ProfileTasteView()
            } label: {
                LabeledContent(profilesLocalized("Profiles.Taste")) {
                    Text(verbatim: tasteSummary ?? profilesLocalized("Profiles.Taste.Nothing"))
                }
            }
            .accessibilityIdentifier("Settings.ProfilePreferences")
            #if DEBUG
            .navigationDestination(isPresented: $debugTaste) { ProfileTasteView() }
            .task {
                try? await Task.sleep(for: .milliseconds(800))
                switch ProfilesDebugScreen.take(["picker", "taste"]) {
                case "picker": showsPicker = true
                case "taste": debugTaste = true
                default: break
                }
            }
            #endif
            // Back from the page, after a reset, or learned meanwhile.
            .onAppear { tasteSummary = ProfileTasteModel.summary() }
            .onReceive(NotificationCenter.default.publisher(for: ProfileTaste.didChangeNotification).receive(on: RunLoop.main)) { _ in
                tasteSummary = ProfileTasteModel.summary()
            }
        } header: {
            Text(verbatim: profilesLocalized("Profiles"))
        } footer: {
            Text(verbatim: profilesLocalized("Profiles.Footer"))
        }
    }

    private func switchRow(_ profile: Profile) -> some View {
        Button {
            showsPicker = true
        } label: {
            HStack(spacing: 12) {
                ProfileAvatarView(avatar: profile.avatar, size: 30)
                Text(verbatim: profilesLocalized("Profiles.Switch"))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(verbatim: profile.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Settings.SwitchProfile")
        // Over Settings: Cancel, the same profile or a change of name puts
        // the user back here, exactly as they left it.
        .fullScreenCover(isPresented: $showsPicker, onDismiss: switchToPicked) {
            NavigationStack {
                ProfilePickerView(onPick: { profile in
                    if profile.id != model.activeID { picked = profile.id }
                    showsPicker = false
                }, onCancel: { showsPicker = false })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { showsPicker = false }
                            .accessibilityIdentifier("Profiles.Cancel")
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func switchToPicked() {
        guard let id = picked else { return }
        picked = nil
        ProfileManager.shared.activate(id)
    }
}
#endif

// MARK: - Mac: Settings › Profiles, Popcorn Time › Switch Profile…

#if os(macOS)
/// The Settings window's Profiles pane: every profile on a row — Use makes
/// it the profile in use, ⓘ edits it — then what the one in use has
/// learned (`ProfileTasteSections`). It switches without the picker, so
/// nothing opens behind the Settings window.
struct MacProfilesSettingsPane: View {
    @StateObject private var model = ProfilesModel()
    @State private var editing: ProfileDraft?
    /// A main window shows the player (or another sheet): a switch would
    /// close it, so Use waits.
    @State private var isASheetUp = MacNavigator.isASheetUp

    var body: some View {
        Form {
            Section {
                ForEach(model.profiles) { profile in
                    row(profile)
                }
                if model.canAdd {
                    Button(profilesLocalized("Profiles.Add") + "…") {
                        editing = ProfileDraft(id: nil, name: "", avatar: ProfileAvatar.firstUnused(by: model.profiles))
                    }
                    .buttonStyle(.borderless)
                    // White as the rows' names: a borderless button's grey
                    // read as disabled.
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("Profiles.Add")
                }
            } header: {
                Text(verbatim: profilesLocalized("Profiles"))
            } footer: {
                Text(verbatim: model.canAdd
                     ? profilesLocalized("Profiles.Footer")
                     : profilesLocalized("Profiles.Footer") + " " + profilesLocalized("Profiles.Error.TooMany"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ProfileTasteSections()
        }
        .macSettingsPane()
        .sheet(item: $editing) { draft in
            ProfileEditorView(model: model, draft: draft) { editing = nil }
        }
        // The editor's own sheet counted as one: Use is free again once it
        // has gone.
        .onChange(of: editing) { _, editing in
            guard editing == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isASheetUp = MacNavigator.isASheetUp }
        }
        .onAppear {
            isASheetUp = MacNavigator.isASheetUp
            #if DEBUG
            if ProfilesDebugScreen.take(["paneEditor"]) != nil {
                editing = (model.profiles.dropFirst().first ?? model.profiles.first).map(ProfileDraft.editing)
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isASheetUp = MacNavigator.isASheetUp
        }
    }

    private func row(_ profile: Profile) -> some View {
        let isCurrent = profile.id == model.activeID
        let firstOther = model.profiles.first { $0.id != model.activeID }?.id
        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                ProfileAvatarView(avatar: profile.avatar, size: 24)
                Text(verbatim: profile.name)
                    .lineLimit(1)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: profile.name))
            .accessibilityValue(Text(verbatim: isCurrent ? profilesLocalized("Profiles.CurrentValue") : ""))
            Spacer(minLength: 8)
            if !isCurrent {
                Button(profilesLocalized("Profiles.Use")) {
                    guard !MacNavigator.isASheetUp else {
                        isASheetUp = true
                        NSSound.beep()
                        return
                    }
                    ProfileManager.shared.activate(profile.id)
                }
                .controlSize(.small)
                .disabled(isASheetUp)
                .help(isASheetUp ? profilesLocalized("Profiles.Use.Busy") : "")
                .accessibilityIdentifier(profile.id == firstOther ? "Settings.SwitchProfile" : "Settings.UseProfile.\(profile.name)")
            }
            Button {
                editing = .editing(profile)
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help(profilesLocalized("Profiles.Edit"))
            .accessibilityLabel(Text(verbatim: String(format: profilesLocalized("Profiles.EditNamed"), profile.name)))
            .accessibilityIdentifier("Settings.EditProfile.\(profile.name)")
        }
    }
}

/// Popcorn Time › Switch Profile… (⇧⌘P): « Who's Watching? » as a sheet on
/// the window in front; the other profile is made active once the sheet has
/// gone (`MacRootView`).
struct MacProfilePickerSheet: View {
    /// The profile picked (nil: Cancel, Escape).
    let close: (String?) -> Void

    var body: some View {
        ProfilePickerView(layout: .sheet, onPick: { close($0.id) }, onCancel: { close(nil) })
            .background(MacSheetToFront())
    }
}

/// Brings the window a sheet is put on in front, with the app: the menu
/// command may come while the Settings window is the key one.
private struct MacSheetToFront: NSViewRepresentable {
    func makeNSView(context: Context) -> FrontView { FrontView() }
    func updateNSView(_ view: FrontView, context: Context) {}

    final class FrontView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            NSApp.activate()
            (window.sheetParent ?? window).makeKeyAndOrderFront(nil)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
