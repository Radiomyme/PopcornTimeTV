// StreamingSettingsViews.swift — « Services de streaming » in the Settings
// of the iPhone and the iPad: the user's TMDB key, the country of the
// catalogues and the services of the Home's « Services » row.
//
// The rules are PopcornKit's (`StreamingSettingsStore`, `TMDBKeySettings`),
// the same as the Apple TV's; these are their screens, pushed inside the
// Settings sheet. Every change is stored at once and the Home's hub
// (`IOSHome.state`) rebuilds its page from what it has.
import SwiftUI
import PopcornKit

/// The screens of the section, by the names a DEBUG launch gives them
/// (`-PTDebugSettingsScreen tmdbkey|region|services`).
enum StreamingSettingsScreen: String, Hashable, Identifiable {
    case tmdbKey = "tmdbkey"
    case region
    case services

    var id: String { rawValue }
}

/// The section of `SettingsView`: the key and its state, the country, the
/// services — each opens its screen — and the credits of the data.
struct StreamingSettingsSection: View {
    let store: StreamingSettingsStore

    var body: some View {
        Section {
            NavigationLink {
                StreamingSettingsDestination(screen: .tmdbKey, store: store)
            } label: {
                LabeledContent {
                    Text(store.isCheckingKey ? "Settings.TMDBKey.Checking" : store.keyState.summary)
                } label: {
                    Text("Settings.TMDBKey")
                }
            }
            .accessibilityIdentifier("Settings.Streaming.TMDBKey")

            NavigationLink {
                StreamingSettingsDestination(screen: .region, store: store)
            } label: {
                LabeledContent {
                    Text(verbatim: store.regionName(store.region))
                } label: {
                    Text("Settings.StreamingRegion")
                }
            }
            .accessibilityIdentifier("Settings.Streaming.Region")

            NavigationLink {
                StreamingSettingsDestination(screen: .services, store: store)
            } label: {
                LabeledContent {
                    if let summary = store.servicesSummary { Text(verbatim: summary) } else { Text("None") }
                } label: {
                    Text("Settings.StreamingServices")
                }
            }
            .accessibilityIdentifier("Settings.Streaming.Services")
        } header: {
            Text("Settings.Streaming")
        } footer: {
            // JustWatch's credit, TMDB's notice, and where the titles play
            // from: the app's own sources.
            Text("Settings.Streaming.Footer")
        }
    }
}

/// One of the section's screens.
struct StreamingSettingsDestination: View {
    let screen: StreamingSettingsScreen
    let store: StreamingSettingsStore

    var body: some View {
        switch screen {
        case .tmdbKey: TMDBKeySettingsView(store: store)
        case .region: StreamingRegionSettingsView(store: store)
        case .services: StreamingServicesSettingsView(store: store)
        }
    }
}

extension TMDBKeySettings.State {
    /// « Définie », « Refusée », « Aucune »: all the key row ever says of
    /// the key (it is never shown again once saved).
    var summary: LocalizedStringKey { LocalizedStringKey(summaryKey) }
}

// MARK: - Key

/// The key screen: one field for a v3 API key or a v4 read access token,
/// cleaned of what comes with a paste (`TMDBKeySettings.cleaned`), checked
/// with TMDB when saved. The field is in clear while typing, so a pasted
/// key can be checked by eye; once saved, the key is never shown again —
/// only its state.
struct TMDBKeySettingsView: View {
    let store: StreamingSettingsStore

    @State private var draft = ""
    /// What TMDB said last on this screen, in plain words.
    @State private var outcome: Outcome?
    @FocusState private var isFieldFocused: Bool

    /// A save's verdict, or a « Vérifier à nouveau »'s.
    enum Outcome: Equatable {
        case saved(TMDBKeySettings.Verdict)
        case checked(TMDBKeySettings.Verdict)
    }

    /// Longer than this, a pasted text is shown in full under the field.
    static let oneLine = 32

    /// `text` breakable after any character and never hyphenated: a zero
    /// width space between the characters (shown only, never stored).
    static func unbroken(_ text: String) -> String {
        text.map(String.init).joined(separator: "\u{200B}")
    }

    private var canSave: Bool {
        !store.isCheckingKey && TMDBKeySettings.cleaned(draft) != nil
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if store.isCheckingKey {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Settings.TMDBKey.Checking")
                        }
                    } else {
                        Text(store.keyState.summary)
                    }
                } label: {
                    Text("Settings.TMDBKey")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("Settings.TMDBKey.State")
            } footer: {
                Text("Settings.TMDBKey.Message.Touch")
            }

            Section {
                // One line: a field that wraps hyphenates a long key (a
                // French or English word break), and the hyphens would read
                // as part of it. The whole text shows under it instead.
                TextField("Settings.TMDBKey.Placeholder", text: $draft)
                    // A key in a typewriter face (0 and O apart); the
                    // placeholder in the usual one, whole on a phone.
                    .font(draft.isEmpty ? .body : .body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .focused($isFieldFocused)
                    .accessibilityLabel(Text("Settings.TMDBKey"))
                    .accessibilityIdentifier("Settings.TMDBKey.Field")
                if draft.count > TMDBKeySettingsView.oneLine {
                    // A read token (about 200 characters) in full, to check
                    // by eye that the paste is whole; VoiceOver reads the field.
                    Text(verbatim: TMDBKeySettingsView.unbroken(draft))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("Settings.TMDBKey.Preview")
                }
                // The system's Paste: no question about the pasteboard.
                PasteButton(payloadType: String.self) { texts in
                    guard let text = texts.first else { return }
                    DispatchQueue.main.async {
                        draft = text
                        outcome = nil
                    }
                }
                .accessibilityIdentifier("Settings.TMDBKey.Paste")
            } footer: {
                if store.hasKey { Text("Settings.TMDBKey.Hidden") }
            }

            Section {
                Button(action: save) {
                    Text("Save")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!canSave)
                .accessibilityIdentifier("Settings.TMDBKey.Save")
                if let outcome, !store.isCheckingKey {
                    TMDBKeyVerdictRow(outcome: outcome)
                }
            }

            if store.hasKey {
                Section {
                    Button(action: checkAgain) {
                        Text("Settings.TMDBKey.Check")
                    }
                    .disabled(store.isCheckingKey)
                    .accessibilityIdentifier("Settings.TMDBKey.Check")
                    Button(role: .destructive) {
                        store.removeKey()
                        outcome = nil
                    } label: {
                        Text("Settings.TMDBKey.Remove")
                    }
                    .disabled(store.isCheckingKey)
                    .accessibilityIdentifier("Settings.TMDBKey.Remove")
                }
            }

            Section {
                // Safari: a page on the Settings sheet would be a sheet on a sheet.
                Link(destination: TMDBKeySettings.apiSettingsPage) {
                    Label("Settings.TMDBKey.GetKey", systemImage: "safari")
                }
                .accessibilityIdentifier("Settings.TMDBKey.GetKey")
            }
        }
        .navigationTitle("Settings.TMDBKey")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.reload()
            #if DEBUG
            applyDebugHooks()
            #endif
        }
    }

    private func save() {
        guard canSave else { return }
        isFieldFocused = false
        outcome = nil
        store.saveKey(draft) { verdict in
            outcome = .saved(verdict)
            // Kept: the field empties, the key is not shown again.
            if verdict != .refused { draft = "" }
        }
    }

    private func checkAgain() {
        outcome = nil
        store.checkKeyAgain { verdict in
            outcome = verdict.map(Outcome.checked)
        }
    }

    #if DEBUG
    /// `-PTDebugTMDBKeyDraft <text>` (as if pasted), `-PTDebugTMDBKeySave
    /// YES`, `-PTDebugTMDBKeyCheck YES`: once per run.
    private func applyDebugHooks() {
        guard !IOSDebugHooks.didApplyKeyScreen else { return }
        IOSDebugHooks.didApplyKeyScreen = true
        if let text = IOSDebugHooks.keyDraft { draft = text }
        if IOSDebugHooks.savesKey { save() } else if IOSDebugHooks.checksKey { checkAgain() }
    }
    #endif
}

/// A verdict in plain words, with its symbol.
private struct TMDBKeyVerdictRow: View {
    let outcome: TMDBKeySettingsView.Outcome

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .accessibilityIdentifier("Settings.TMDBKey.Verdict")
    }

    private var verdict: TMDBKeySettings.Verdict {
        switch outcome {
        case .saved(let verdict), .checked(let verdict): return verdict
        }
    }

    private var text: LocalizedStringKey {
        switch outcome {
        case .saved(let verdict): return LocalizedStringKey(verdict.messageKey(afterCheck: false))
        case .checked(let verdict): return LocalizedStringKey(verdict.messageKey(afterCheck: true))
        }
    }

    private var symbol: String {
        switch verdict {
        case .accepted: return "checkmark.circle.fill"
        case .refused: return "xmark.octagon.fill"
        case .unanswered: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch verdict {
        case .accepted: return .green
        case .refused: return .red
        case .unanswered: return .orange
        }
    }
}

// MARK: - Country

/// The country of the catalogues: TMDB's countries by name, the current
/// one checked; a field narrows the list (a plain field: `.searchable`
/// crashes the app when it runs on a Mac).
struct StreamingRegionSettingsView: View {
    let store: StreamingSettingsStore

    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss

    private var choices: [StreamingChoice] {
        let all = store.regionOptions
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return all }
        return all.filter { $0.title.localizedStandardContains(text) || $0.id.caseInsensitiveCompare(text) == .orderedSame }
    }

    var body: some View {
        ScrollViewReader { reader in
            Form {
                Section {
                    TextField("Search", text: $filter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("Settings.StreamingRegion.Filter")
                } footer: {
                    Text("Settings.StreamingRegion.Message")
                }
                Section {
                    if store.regionChoices == nil {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Spinner.Loading").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(choices) { choice in
                        StreamingChoiceRow(title: choice.title, isChecked: choice.id == store.region) {
                            store.select(region: choice.id)
                            dismiss()
                        }
                        .id(choice.id)
                        .accessibilityIdentifier("Settings.StreamingRegion.\(choice.id)")
                    }
                }
            }
            .onChange(of: store.regionChoices == nil, initial: true) { _, waiting in
                // The current country in view once the list is there.
                guard !waiting else { return }
                let region = store.region
                DispatchQueue.main.async { reader.scrollTo(region, anchor: .center) }
            }
        }
        .navigationTitle("Settings.StreamingRegion")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.reload()
            store.loadRegions()
        }
    }
}

// MARK: - Services

/// The services of the country, the most watched first: each checked one
/// has its card in the Home's « Services » row. Without a key, only the
/// ones already chosen (TMDB is not asked).
struct StreamingServicesSettingsView: View {
    let store: StreamingSettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(store.serviceOptions) { choice in
                    let isChecked = store.chosenServices.contains { $0.id == choice.id }
                    StreamingChoiceRow(title: choice.title, isChecked: isChecked) {
                        withAnimation(.easeInOut(duration: 0.2)) { store.toggle(service: choice) }
                    }
                    .accessibilityIdentifier("Settings.StreamingServices.\(choice.id)")
                }
                if store.hasKey {
                    switch store.servicesLoad {
                    case .idle, .loading:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Spinner.Loading").foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("Settings.StreamingServices.Loading")
                    case .failed:
                        VStack(alignment: .leading, spacing: 10) {
                            Text(store.keyState == .refused ? "Settings.TMDBKey.Refused" : "Settings.StreamingServices.Failed")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("Settings.StreamingServices.Failed")
                            Button("Try Again") { store.loadServices() }
                                .accessibilityIdentifier("Settings.StreamingServices.Retry")
                        }
                        .padding(.vertical, 4)
                    case .loaded:
                        EmptyView()
                    }
                }
            } header: {
                Text(verbatim: store.regionName(store.region))
            } footer: {
                Text(store.hasKey ? "Settings.StreamingServices.Message.HomeOnly" : "Settings.StreamingServices.NoKey")
            }
        }
        .navigationTitle("Settings.StreamingServices")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.reload()
            if store.hasKey, store.servicesLoad != .loaded, store.servicesLoad != .loading { store.loadServices() }
        }
    }
}

/// A line of a list: its title, a checkmark when it is the one (one of
/// the ones) chosen.
private struct StreamingChoiceRow: View {
    let title: String
    let isChecked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(verbatim: title)
                    .foregroundStyle(.primary)
                Spacer()
                if isChecked {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}
