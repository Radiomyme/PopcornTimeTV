// MacStreamingSettingsView.swift — « Streaming », the fourth pane of the
// Mac's Settings window: the user's TMDB key, the country of the catalogues
// and the services of the Home's « Services » row.
//
// The rules are PopcornKit's (`StreamingSettingsStore`, `TMDBKeySettings`),
// the same as the Apple TV's and the iPhone's; this is their Mac face: a
// grouped form like the other panes, the key in a sheet (a field, ⌘V or
// Paste, Return saves and checks, Escape closes), the services in a sheet
// of checkmarks. Every change is stored at once and the window's hub
// (`MacHome.state`) rebuilds its page from what it has.
import Foundation
import AppKit
import SwiftUI
import PopcornKit

/// The pane's store, one for the app: its changes rebuild the Home of the
/// main window (`MacHome.state`, the recorded hub in DEBUG fixture runs).
@MainActor
enum MacStreamingSettings {
    static let store = StreamingSettingsStore(hub: MacHome.state)
}

/// The pane: the key and its state with « Modifier… », the country's menu,
/// the services with « Modifier… », and the credits of the data.
struct MacStreamingSettingsPane: View {
    let store: StreamingSettingsStore

    /// The sheet over the window, by the names a DEBUG launch gives them
    /// (`-PTDebugSettingsSheet tmdbkey|services`).
    enum Sheet: String, Identifiable {
        case tmdbKey = "tmdbkey"
        case services

        var id: String { rawValue }
    }

    @State private var sheet: Sheet?

    /// The country's menu: picking one stores it, the Home shows its
    /// catalogues and the chosen services follow it.
    private var region: Binding<String> {
        Binding(get: { store.region }, set: { store.select(region: $0) })
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        if store.isCheckingKey {
                            ProgressView()
                                .controlSize(.small)
                            Text("Settings.TMDBKey.Checking")
                        } else {
                            Text(LocalizedStringKey(store.keyState.summaryKey))
                        }
                        Button("Home.Settings.Edit") { sheet = .tmdbKey }
                            .accessibilityIdentifier("Settings.Streaming.TMDBKey")
                    }
                } label: {
                    Text("Settings.TMDBKey")
                }
            } header: {
                Text("Settings.Streaming")
            } footer: {
                footer("Settings.TMDBKey.Detail.HomeOnly")
            }

            Section {
                Picker("Settings.StreamingRegion", selection: region) {
                    ForEach(store.regionOptions) { choice in
                        Text(verbatim: choice.title).tag(choice.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("Settings.Streaming.Region")
            } footer: {
                footer("Settings.StreamingRegion.Message")
            }

            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        Group {
                            if let summary = store.servicesSummary { Text(verbatim: summary) } else { Text("None") }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                        Button("Home.Settings.Edit") { sheet = .services }
                            .accessibilityIdentifier("Settings.Streaming.Services")
                    }
                } label: {
                    Text("Settings.StreamingServices")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    footer(store.hasKey ? "Settings.StreamingServices.Message.HomeOnly" : "Settings.StreamingServices.NoKey")
                    // JustWatch's credit, TMDB's notice, and where the
                    // titles play from: the app's own sources.
                    footer("Settings.Streaming.Footer")
                }
            }
        }
        .macSettingsPane()
        .onAppear {
            store.reload()
            // TMDB's countries with a key (once a run); without one, every
            // country the system knows, and no request.
            store.loadRegions()
            #if DEBUG
            if !MacDebugHooks.didOpenStreamingSheet, let name = MacDebugHooks.settingsSheet, let debugSheet = Sheet(rawValue: name) {
                MacDebugHooks.didOpenStreamingSheet = true
                sheet = debugSheet
            }
            #endif
        }
        .sheet(item: $sheet, onDismiss: store.reload) { sheet in
            switch sheet {
            case .tmdbKey:
                MacTMDBKeySheet(store: store) { self.sheet = nil }
            case .services:
                MacHomeSettingsSheet(title: "Settings.StreamingServices", closesOnEscape: true) {
                    MacStreamingServicesList(store: store)
                } close: {
                    self.sheet = nil
                }
            }
        }
    }

    private func footer(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Key

/// The key's sheet: one field for a v3 API key or a v4 read access token,
/// cleaned of what comes with a paste (`TMDBKeySettings.cleaned`), checked
/// with TMDB when saved (Return, or « Enregistrer »). The field is in clear
/// while typing, so a pasted key can be checked by eye; once saved, the key
/// is never shown again — only its state. Escape closes.
struct MacTMDBKeySheet: View {
    let store: StreamingSettingsStore
    let close: () -> Void

    @State private var draft = ""
    /// What TMDB said last in this sheet: a save's verdict, or a check's.
    @State private var outcome: (verdict: TMDBKeySettings.Verdict, afterCheck: Bool)?
    @FocusState private var isFieldFocused: Bool

    /// Longer than this, a pasted text is shown in full under the field.
    private static let oneLine = 40

    private var canSave: Bool {
        !store.isCheckingKey && TMDBKeySettings.cleaned(draft) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Settings.TMDBKey")
                        .font(.headline)
                    Spacer()
                    state
                }
                Text("Settings.TMDBKey.Message.Mac")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    TextField("Settings.TMDBKey.Placeholder", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        // A key in a typewriter face (0 and O apart).
                        .font(draft.isEmpty ? .body : .body.monospaced())
                        .autocorrectionDisabled()
                        .focused($isFieldFocused)
                        .onSubmit(save)
                        .accessibilityLabel(Text("Settings.TMDBKey"))
                        .accessibilityIdentifier("Settings.TMDBKey.Field")
                    if draft.count > MacTMDBKeySheet.oneLine {
                        // A read token (about 200 characters) in full, to
                        // check by eye that the paste is whole.
                        Text(verbatim: draft.map(String.init).joined(separator: "\u{200B}"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                            .accessibilityIdentifier("Settings.TMDBKey.Preview")
                    }
                    if store.hasKey {
                        Text("Settings.TMDBKey.Hidden")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 12) {
                    // The system's Paste: no question about the pasteboard.
                    PasteButton(payloadType: String.self) { texts in
                        guard let text = texts.first else { return }
                        DispatchQueue.main.async {
                            draft = text
                            outcome = nil
                            isFieldFocused = true
                        }
                    }
                    .accessibilityIdentifier("Settings.TMDBKey.Paste")
                    Spacer()
                    // In the browser: TMDB's page where the key is shown.
                    Link(destination: TMDBKeySettings.apiSettingsPage) {
                        Label("Settings.TMDBKey.GetKey", systemImage: "arrow.up.forward.square")
                    }
                    .accessibilityIdentifier("Settings.TMDBKey.GetKey")
                }

                if let outcome, !store.isCheckingKey {
                    MacTMDBKeyVerdict(verdict: outcome.verdict, afterCheck: outcome.afterCheck)
                }
            }
            .padding(20)

            Divider()

            HStack(spacing: 10) {
                if store.hasKey {
                    Button(role: .destructive) {
                        store.removeKey()
                        outcome = nil
                        draft = ""
                    } label: {
                        Text("Settings.TMDBKey.Remove")
                    }
                    .disabled(store.isCheckingKey)
                    .accessibilityIdentifier("Settings.TMDBKey.Remove")
                    Button("Settings.TMDBKey.Check", action: checkAgain)
                        .disabled(store.isCheckingKey)
                        .accessibilityIdentifier("Settings.TMDBKey.Check")
                }
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("Settings.TMDBKey.Close")
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityIdentifier("Settings.TMDBKey.Save")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            store.reload()
            isFieldFocused = true
            #if DEBUG
            applyDebugHooks()
            #endif
        }
    }

    /// « Définie », « Refusée », « Aucune », or « Vérification… ».
    @ViewBuilder
    private var state: some View {
        HStack(spacing: 6) {
            if store.isCheckingKey {
                ProgressView()
                    .controlSize(.small)
                Text("Settings.TMDBKey.Checking")
            } else {
                Text(LocalizedStringKey(store.keyState.summaryKey))
            }
        }
        .foregroundStyle(store.keyState == .refused && !store.isCheckingKey ? Color.red : Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Settings.TMDBKey.State")
    }

    /// Return (in the field or on the sheet) and « Enregistrer ».
    private func save() {
        guard canSave else { return }
        outcome = nil
        let text = draft
        store.saveKey(text) { verdict in
            // Kept: the field empties, the key is not shown again.
            if verdict != .refused { draft = "" }
            outcome = (verdict, false)
        }
    }

    private func checkAgain() {
        outcome = nil
        store.checkKeyAgain { verdict in
            outcome = verdict.map { ($0, true) }
        }
    }

    #if DEBUG
    /// `-PTDebugTMDBKeyDraft <text>` (as if pasted), `-PTDebugTMDBKeySave
    /// YES`, `-PTDebugTMDBKeyCheck YES`: once per run.
    private func applyDebugHooks() {
        guard !MacDebugHooks.didApplyKeySheet else { return }
        MacDebugHooks.didApplyKeySheet = true
        if let text = MacDebugHooks.tmdbKeyDraft { draft = text }
        if MacDebugHooks.savesTMDBKey {
            // Once the draft is in the field.
            DispatchQueue.main.async { save() }
        } else if MacDebugHooks.checksTMDBKey {
            checkAgain()
        }
    }
    #endif
}

/// A verdict in plain words, with its symbol.
private struct MacTMDBKeyVerdict: View {
    let verdict: TMDBKeySettings.Verdict
    let afterCheck: Bool

    var body: some View {
        Label {
            Text(LocalizedStringKey(verdict.messageKey(afterCheck: afterCheck)))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Settings.TMDBKey.Verdict")
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

// MARK: - Services

/// The services of the country, the most watched first, the chosen ones
/// checked: each checked one has its card in the Home's « Services » row.
/// Without a key, only the ones already chosen (TMDB is not asked).
private struct MacStreamingServicesList: View {
    let store: StreamingSettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(store.serviceOptions) { choice in
                    let isChecked = store.chosenServices.contains { $0.id == choice.id }
                    MacStreamingChoiceRow(title: choice.title, isChecked: isChecked) {
                        store.toggle(service: choice)
                    }
                    .accessibilityIdentifier("Settings.StreamingServices.\(choice.id)")
                }
                if store.hasKey {
                    switch store.servicesLoad {
                    case .idle, .loading:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Spinner.Loading")
                                .foregroundStyle(.secondary)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            store.reload()
            if store.hasKey, store.servicesLoad != .loaded, store.servicesLoad != .loading { store.loadServices() }
        }
    }
}

/// A line of the list: its title, a checkmark when it is one of the ones
/// chosen; a click checks or unchecks it.
private struct MacStreamingChoiceRow: View {
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
