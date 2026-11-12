// GlassSettingsView.swift — the tvOS Settings tab, in Liquid Glass.
//
// Pure SwiftUI: no PopcornKit, no pods, no app types. Everything it reads or
// changes goes through `GlassSettingsModel` (values) and `GlassSettingsActions`
// (closures), filled by `GlassSettingsHostingController`, so the page can be
// compiled alone with mock values (the screenshot harness lives outside the
// repo; it builds with DEBUG for the switches below).
//
// Texts are English keys looked up in the app's Localizable.strings (en, fr…).
//
// Focus: rows are Buttons with `GlassSettingsRowStyle`, which draws the focus
// state itself from @Environment(\.isFocused) (custom glass gets no system
// focus effect on tvOS). No GlassEffectContainer is used.
import SwiftUI

// MARK: - Model

/// "Auto Select Quality" choices. For balanced / highest / lowest, `titleKey`
/// is both the Localizable.strings key and, localized, the value the quality
/// chooser compares the stored preference to (`AppDelegate.presentQualityChoice`);
/// off is stored as no value (the chooser then always asks).
enum GlassSettingsAutoQuality: String, CaseIterable, Identifiable {
    case off, balanced, highest, lowest

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .off: return "Always Ask"
        case .balanced: return "Balanced"
        case .highest: return "Highest"
        case .lowest: return "Lowest"
        }
    }

    var detailKey: String {
        switch self {
        case .off: return "Choose the source every time; the recommended one is starred."
        case .balanced: return "The best quality that starts quickly."
        case .highest: return "Always the best picture, even if it takes longer to start."
        case .lowest: return "The smallest file, for the quickest start."
        }
    }
}

/// A language offered by the audio and subtitle pickers.
struct GlassSettingsLanguage: Identifiable, Hashable {
    /// ISO 639-1 code ("fr").
    let code: String
    /// Name in the current UI language ("Français").
    let name: String
    var id: String { code }
}

/// What the page does, provided by its host.
struct GlassSettingsActions {
    var setAutoQuality: (GlassSettingsAutoQuality) -> Void = { _ in }
    /// nil = no preference.
    var setAudioLanguage: (String?) -> Void = { _ in }
    var setSubtitleLanguage: (String?) -> Void = { _ in }
    var setThemeSongs: (Bool) -> Void = { _ in }
    /// The stored Theme Songs state, re-read by `refresh()` (a fresh install
    /// turns theme songs on after this page was created). nil: never re-read.
    var readThemeSongs: (() -> Bool)? = nil
    /// Bytes the clearable cache holds now. Called off the main thread.
    var measureCache: @Sendable () -> Int64 = { 0 }
    /// Empties the cache. Called on the main thread.
    var clearCache: () -> Void = {}
    /// True while a download is in progress (clearing the cache would cut it).
    var hasActiveDownloads: () -> Bool = { false }
    var isTraktSignedIn: () -> Bool = { false }
    var signOutOfTrakt: () -> Void = {}
    var showWhatsNew: () -> Void = {}
}

/// The page's state. Changes go through the methods, which call the actions.
final class GlassSettingsModel: ObservableObject {
    @Published private(set) var autoQuality: GlassSettingsAutoQuality
    @Published private(set) var audioLanguage: String?
    @Published private(set) var subtitleLanguage: String?
    @Published private(set) var themeSongs: Bool
    @Published private(set) var isTraktSignedIn: Bool
    /// nil while it is being measured.
    @Published private(set) var cacheBytes: Int64?
    /// "5.1.0 (2)".
    let version: String
    /// Offered by the language pickers, in display order.
    let languages: [GlassSettingsLanguage]
    let actions: GlassSettingsActions

    init(autoQuality: GlassSettingsAutoQuality, audioLanguage: String?, subtitleLanguage: String?,
         themeSongs: Bool, version: String, languages: [GlassSettingsLanguage],
         actions: GlassSettingsActions) {
        self.autoQuality = autoQuality
        self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage
        self.themeSongs = themeSongs
        self.version = version
        self.languages = languages
        self.actions = actions
        self.isTraktSignedIn = actions.isTraktSignedIn()
    }

    func select(autoQuality: GlassSettingsAutoQuality) {
        self.autoQuality = autoQuality
        actions.setAutoQuality(autoQuality)
    }

    func select(audioLanguage code: String?) {
        audioLanguage = code
        actions.setAudioLanguage(code)
    }

    func select(subtitleLanguage code: String?) {
        subtitleLanguage = code
        actions.setSubtitleLanguage(code)
    }

    func toggleThemeSongs() {
        themeSongs.toggle()
        actions.setThemeSongs(themeSongs)
    }

    func signOutOfTrakt() {
        actions.signOutOfTrakt()
        isTraktSignedIn = actions.isTraktSignedIn()
    }

    /// Re-reads what can change outside the page (Trakt session, theme songs,
    /// cache size).
    func refresh() {
        isTraktSignedIn = actions.isTraktSignedIn()
        if let stored = actions.readThemeSongs?(), stored != themeSongs { themeSongs = stored }
        cacheBytes = nil
        let measure = actions.measureCache
        DispatchQueue.global(qos: .utility).async {
            let bytes = measure()
            DispatchQueue.main.async { self.cacheBytes = bytes }
        }
    }

    /// Clears the cache; `completion` (main thread) gets the bytes reclaimed,
    /// measured before and after (the measuring runs off the main thread).
    func clearCache(completion: @escaping (Int64) -> Void) {
        let measure = actions.measureCache
        DispatchQueue.global(qos: .userInitiated).async {
            let before = measure()
            DispatchQueue.main.async {
                self.actions.clearCache()
                DispatchQueue.global(qos: .userInitiated).async {
                    let after = measure()
                    DispatchQueue.main.async {
                        self.cacheBytes = after
                        completion(max(0, before - after))
                    }
                }
            }
        }
    }

    func languageName(_ code: String?) -> String {
        guard let code else { return glassSettingsLocalized("None") }
        return languages.first { $0.code == code }?.name ?? code
    }
}

/// Localizable.strings lookup in the app bundle (English key when missing).
func glassSettingsLocalized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

private func glassSettingsByteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - Glass on/off switch (screenshots, DEBUG builds only)

#if DEBUG
private struct GlassSettingsFallbackKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// true forces the tvOS 17–25 look where Liquid Glass exists, for
    /// side-by-side screenshots.
    var glassSettingsFallback: Bool {
        get { self[GlassSettingsFallbackKey.self] }
        set { self[GlassSettingsFallbackKey.self] = newValue }
    }
}
#else
extension EnvironmentValues {
    /// Liquid Glass wherever the system has it.
    var glassSettingsFallback: Bool { false }
}
#endif

enum GlassSettingsPalette {
    /// The app accent (AccentColor, dark appearance).
    static let accent = Color(red: 0.949, green: 0.290, blue: 0.235)
    static let secondaryText = Color.white.opacity(0.68)
    static let tertiaryText = Color.white.opacity(0.5)
}

// MARK: - Page

/// The rows that open a picker.
enum GlassSettingsPicker: String, Identifiable {
    case quality, audio, subtitles
    var id: String { rawValue }
}

/// Rows that can hold the focus (default focus, screenshots).
enum GlassSettingsRowID: Hashable {
    case quality, audio, subtitles, themeSongs, clearCache, trakt, version
}

struct GlassSettingsView: View {
    @ObservedObject var model: GlassSettingsModel
    #if DEBUG
    /// Picker open at first display (screenshots, DEBUG builds only).
    var initialPicker: GlassSettingsPicker?
    #endif
    /// The row that gets the focus when the page first takes it.
    var defaultFocusRow: GlassSettingsRowID = .quality

    @State private var picker: GlassSettingsPicker?
    @State private var confirmClear = false
    @State private var clearResult: Int64?
    @State private var showClearResult = false
    @State private var confirmSignOut = false
    @FocusState private var focusedRow: GlassSettingsRowID?

    var body: some View {
        // Fits a 1080p screen under the tab bar; the scroll view only matters
        // if a host leaves less room (the focus engine scrolls to the row).
        ScrollView {
            page
                .padding(.horizontal, 90)
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { GlassSettingsBackdrop().ignoresSafeArea() }
        .defaultFocus($focusedRow, defaultFocusRow)
        #if DEBUG
        .onAppear { if let initialPicker { picker = initialPicker } }
        #endif
        .fullScreenCover(item: $picker) { picker in
            pickerSheet(picker)
        }
        .alert(glassSettingsLocalized("Clear Cache"), isPresented: $confirmClear) {
            if model.actions.hasActiveDownloads() {
                SwiftUI.Button(glassSettingsLocalized("OK"), role: .cancel) {}
            } else {
                SwiftUI.Button(glassSettingsLocalized("Clear Cache"), role: .destructive) {
                    model.clearCache { reclaimed in
                        clearResult = reclaimed
                        showClearResult = true
                    }
                }
                SwiftUI.Button(glassSettingsLocalized("Cancel"), role: .cancel) {}
            }
        } message: {
            Text(clearCacheMessage)
        }
        .alert(glassSettingsLocalized("Cache Cleared"), isPresented: $showClearResult) {
            SwiftUI.Button(glassSettingsLocalized("OK"), role: .cancel) {}
        } message: {
            if let clearResult, clearResult > 0 {
                Text(String(format: glassSettingsLocalized("%@ reclaimed."), glassSettingsByteString(clearResult)))
            } else {
                Text(glassSettingsLocalized("Cache was already empty, no disk space was reclaimed."))
            }
        }
        .alert(glassSettingsLocalized("Sign Out of Trakt"), isPresented: $confirmSignOut) {
            SwiftUI.Button(glassSettingsLocalized("Sign Out"), role: .destructive) { model.signOutOfTrakt() }
            SwiftUI.Button(glassSettingsLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(glassSettingsLocalized("Are you sure you want to Sign Out?"))
        }
    }

    /// Page title, then two columns of sections.
    private var page: some View {
        VStack(alignment: .leading, spacing: 30) {
            // Same place, size and weight as the other tabs' titles
            // (MainViewController.installInBodyHeader).
            Text(glassSettingsLocalized("Settings"))
                .font(.system(size: 75, weight: .heavy))
                .foregroundStyle(.white)
                .frame(height: 100)
                .padding(.top, 16)

            HStack(alignment: .top, spacing: 60) {
                VStack(alignment: .leading, spacing: 44) {
                    playbackSection
                    detailPagesSection
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 44) {
                    storageSection
                    if model.isTraktSignedIn { accountSection }
                    aboutSection
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Sections

    private var playbackSection: some View {
        GlassSettingsSection(title: "Playback",
                             footer: "Audio and subtitles in these languages are picked automatically when the file or OpenSubtitles offers them.") {
            GlassSettingsRow(symbol: "sparkles.tv", tint: .orange, title: "Auto Select Quality",
                             value: glassSettingsLocalized(model.autoQuality.titleKey)) { picker = .quality }
                .focused($focusedRow, equals: .quality)
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "speaker.wave.2.fill", tint: .blue, title: "Audio Language",
                             value: model.languageName(model.audioLanguage)) { picker = .audio }
                .focused($focusedRow, equals: .audio)
            GlassSettingsDivider()
            GlassSettingsRow(symbol: "captions.bubble.fill", tint: .teal, title: "Subtitle Language",
                             value: model.languageName(model.subtitleLanguage)) { picker = .subtitles }
                .focused($focusedRow, equals: .subtitles)
        }
    }

    private var detailPagesSection: some View {
        GlassSettingsSection(title: "Detail Pages",
                             footer: "Plays the soundtrack of the movie or the theme of the show on its page.") {
            GlassSettingsRow(symbol: "music.note", tint: .pink, title: "Theme Songs",
                             value: glassSettingsLocalized(model.themeSongs ? "On" : "Off"),
                             showsChevron: false) { model.toggleThemeSongs() }
                .focused($focusedRow, equals: .themeSongs)
        }
    }

    private var storageSection: some View {
        GlassSettingsSection(title: "Storage",
                             footer: "Temporary video files, posters and network caches.") {
            GlassSettingsRow(symbol: "internaldrive.fill", tint: .gray, title: "Clear Cache",
                             value: model.cacheBytes.map(glassSettingsByteString) ?? "…",
                             showsChevron: false) { confirmClear = true }
                .focused($focusedRow, equals: .clearCache)
        }
    }

    private var accountSection: some View {
        GlassSettingsSection(title: "Account", footer: nil) {
            GlassSettingsRow(symbol: "person.crop.circle.badge.xmark", tint: .red, title: "Sign Out of Trakt",
                             value: nil, showsChevron: false) { confirmSignOut = true }
                .focused($focusedRow, equals: .trakt)
        }
    }

    private var aboutSection: some View {
        GlassSettingsSection(title: "About",
                             footer: "Popcorn Time is free and open-source software.") {
            GlassSettingsRow(symbol: "info.circle.fill", tint: GlassSettingsPalette.accent, title: "Version",
                             subtitle: "What's New", value: model.version) { model.actions.showWhatsNew() }
                .focused($focusedRow, equals: .version)
        }
    }

    private var clearCacheMessage: String {
        if model.actions.hasActiveDownloads() {
            return glassSettingsLocalized("A download is in progress. Clear the cache once it has finished.")
        }
        let size = model.cacheBytes.map(glassSettingsByteString) ?? "…"
        return String(format: glassSettingsLocalized("About %@ will be freed."), size)
    }

    // MARK: Pickers

    @ViewBuilder
    private func pickerSheet(_ picker: GlassSettingsPicker) -> some View {
        switch picker {
        case .quality:
            GlassSettingsPickerSheet(
                title: "Auto Select Quality",
                message: "Choose a default quality. If said quality is available, it will be automatically selected.",
                options: GlassSettingsAutoQuality.allCases.map {
                    .init(id: $0.rawValue, title: glassSettingsLocalized($0.titleKey),
                          detail: glassSettingsLocalized($0.detailKey))
                },
                selectedID: model.autoQuality.rawValue,
                onSelect: { id in
                    if let quality = GlassSettingsAutoQuality(rawValue: id) { model.select(autoQuality: quality) }
                    self.picker = nil
                },
                onCancel: { self.picker = nil })
        case .audio:
            GlassSettingsPickerSheet(
                title: "Audio Language",
                message: "Choose a preferred audio language. When the file carries a matching audio track, it will be selected automatically.",
                options: languageOptions,
                selectedID: model.audioLanguage ?? "",
                onSelect: { id in
                    model.select(audioLanguage: id.isEmpty ? nil : id)
                    self.picker = nil
                },
                onCancel: { self.picker = nil })
        case .subtitles:
            GlassSettingsPickerSheet(
                title: "Subtitle Language",
                message: "Choose a default language for the player subtitles.",
                options: languageOptions,
                selectedID: model.subtitleLanguage ?? "",
                onSelect: { id in
                    model.select(subtitleLanguage: id.isEmpty ? nil : id)
                    self.picker = nil
                },
                onCancel: { self.picker = nil })
        }
    }

    /// "None" (id "") then every language.
    private var languageOptions: [GlassSettingsPickerSheet.Option] {
        [.init(id: "", title: glassSettingsLocalized("None"), detail: nil)]
            + model.languages.map { .init(id: $0.code, title: $0.name, detail: nil) }
    }
}

// MARK: - Building blocks

/// Section title, a glass card holding the rows, and an optional footer.
private struct GlassSettingsSection<Rows: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder var rows: Rows
    @Environment(\.glassSettingsFallback) private var fallback

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(glassSettingsLocalized(title))
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(GlassSettingsPalette.secondaryText)
                .padding(.leading, 28)
            VStack(spacing: 0) { rows }
                .padding(10)
                .modifier(GlassSettingsCard(cornerRadius: 34, fallback: fallback))
            if let footer {
                Text(glassSettingsLocalized(footer))
                    .font(.system(size: 23))
                    .foregroundStyle(GlassSettingsPalette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
            }
        }
    }
}

/// Regular Liquid Glass on tvOS 26+, an ultra-thin material with a hairline before.
private struct GlassSettingsCard: ViewModifier {
    let cornerRadius: CGFloat
    let fallback: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(tvOS 26.0, *), !fallback {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(Color.white.opacity(0.14), lineWidth: 1) }
        }
    }
}

private struct GlassSettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 1)
            .padding(.leading, 104)
            .padding(.trailing, 24)
    }
}

/// A focusable row: tinted symbol tile, title (and subtitle), value, chevron.
private struct GlassSettingsRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    let value: String?
    var showsChevron = true
    let action: () -> Void

    var body: some View {
        SwiftUI.Button(action: action) {
            HStack(spacing: 24) {
                Image(systemName: symbol)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                // A long title (Italian "Seleziona Automaticamente la
                // Qualità") wraps to a second line instead of pushing the
                // value out; the value keeps its width.
                VStack(alignment: .leading, spacing: 2) {
                    Text(glassSettingsLocalized(title))
                        .font(.system(size: 31, weight: .medium))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(glassSettingsLocalized(subtitle))
                            .font(.system(size: 23, weight: .medium))
                            .opacity(0.6)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 16)
                if let value {
                    Text(value)
                        .font(.system(size: 29))
                        .opacity(0.65)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                }
                if showsChevron {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 24, weight: .semibold))
                        .opacity(0.4)
                }
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 90)
        }
        .buttonStyle(GlassSettingsRowStyle())
    }
}

/// Focus visual of the rows: unfocused, plain white text on the card;
/// focused, a bright platter (white-tinted glass on tvOS 26+, opaque white
/// before) with dark text, slightly lifted with a shadow.
struct GlassSettingsRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused
        @Environment(\.glassSettingsFallback) private var fallback

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .contentShape(shape)
                .background { platter(shape) }
                .scaleEffect(configuration.isPressed ? 1.01 : (isFocused ? 1.04 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 22, y: 14)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }

        @ViewBuilder
        private func platter(_ shape: RoundedRectangle) -> some View {
            if isFocused {
                if #available(tvOS 26.0, *), !fallback {
                    Color.clear.glassEffect(.regular.tint(.white.opacity(0.9)), in: shape)
                } else {
                    shape.fill(Color.white.opacity(0.94))
                }
            }
        }
    }
}

/// Glass sheet listing the choices of one setting; the current one has a
/// checkmark and the focus. Menu closes it without changing anything.
struct GlassSettingsPickerSheet: View {
    struct Option: Identifiable {
        /// "" for "None".
        let id: String
        let title: String
        let detail: String?
    }

    let title: String
    let message: String?
    let options: [Option]
    let selectedID: String
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focusedID: String?
    @Environment(\.glassSettingsFallback) private var fallback

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text(glassSettingsLocalized(title))
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 58)
                if let message {
                    Text(glassSettingsLocalized(message))
                        .font(.system(size: 24))
                        .foregroundStyle(GlassSettingsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 58)
                }
                // Clipped to the panel; the side padding leaves room for the
                // focused row's lift.
                ScrollView {
                    // Not lazy: the default focus must reach the current choice
                    // even when it is far down the list (≈40 rows at most).
                    VStack(spacing: 6) {
                        ForEach(options) { option in
                            optionRow(option)
                        }
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 36)
                }
            }
            .padding(.top, 44)
            .padding(.bottom, 20)
            .frame(width: 1000)
            .frame(maxHeight: 880)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(GlassSettingsCard(cornerRadius: 50, fallback: fallback))
        }
        .defaultFocus($focusedID, selectedID)
        .onExitCommand(perform: onCancel)
        .presentationBackground(.clear)
    }

    private func optionRow(_ option: Option) -> some View {
        SwiftUI.Button { onSelect(option.id) } label: {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .font(.system(size: 31, weight: .medium))
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 22, weight: .medium))
                            .opacity(0.65)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .opacity(option.id == selectedID ? 1 : 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, option.detail == nil ? 18 : 16)
        }
        .buttonStyle(GlassSettingsRowStyle(cornerRadius: 22))
        .focused($focusedID, equals: option.id)
    }
}

/// The page backdrop: the app icon's warm cinema gradient (plum to near black,
/// with an orange glow at the top right), which the glass cards refract.
private struct GlassSettingsBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.30, green: 0.08, blue: 0.34),
                                    Color(red: 0.10, green: 0.04, blue: 0.22),
                                    Color(red: 0.08, green: 0.03, blue: 0.18)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.20).opacity(0.45), .clear],
                           center: UnitPoint(x: 0.82, y: 0.12), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [GlassSettingsPalette.accent.opacity(0.22), .clear],
                           center: UnitPoint(x: 0.1, y: 0.95), startRadius: 0, endRadius: 800)
        }
    }
}
