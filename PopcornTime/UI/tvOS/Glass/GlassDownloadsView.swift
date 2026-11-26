// GlassDownloadsView.swift — the Downloads tab of the Apple TV, in the look
// of the Settings page: the page title, the space the downloads take, then
// « Downloading » and « Downloaded », a glass card of rows each. A row is a
// poster, the title, one status line (« 42 % · 3.1 MB/s · about 12 min left
// · 1.1 GB of 2.6 GB ») and, while it downloads, a thin bar. Select opens
// what can be done with it (Play, Pause, Resume, Try Again, Delete); a long
// press shows the same; Play/Pause on the remote pauses or resumes.

import UIKit
import SwiftUI
import Combine
import PopcornKit

/// Root of the Downloads tab (installed by `TVTabBarController`).
final class GlassDownloadsHostingController: UIHostingController<GlassDownloadsView> {

    init(store: DownloadsStore = .shared) {
        super.init(rootView: GlassDownloadsView(store: store))
    }

    @available(*, unavailable, message: "Created in code by TVTabBarController")
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        DownloadsStore.shared.refreshNow()
        DownloadsStore.shared.measureStorage()
    }
}

/// What a row's menu can do.
enum DownloadsAction: String {
    case play, pause, resume, retry, delete, showDownloads
}

struct GlassDownloadsView: View {
    @ObservedObject var store: DownloadsStore

    @State private var menuEntry: DownloadsEntry?
    /// Delete asks in a sheet of its own, opened once the menu closed: a
    /// new sheet takes the focus where it says (Cancel).
    @State private var deleteEntry: DownloadsEntry?
    @State private var askDelete: DownloadsEntry?
    @FocusState private var focusedID: String?
    private let text = DownloadsText()

    var body: some View {
        let sections = DownloadsCatalog.sections(store.entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                header(sections.active)
                if store.entries.isEmpty {
                    emptyState
                } else {
                    if !sections.active.isEmpty {
                        section("Downloads.Section.Downloading", entries: sections.active)
                    }
                    if !sections.finished.isEmpty {
                        section("Downloads.Section.Downloaded", entries: sections.finished)
                    }
                    Text(glassSettingsLocalized("Downloads.Footer"))
                        .font(.system(size: 23))
                        .foregroundStyle(GlassSettingsPalette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)
                }
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 60)
        }
        // 90 pt from the screen's edge, as the Settings page and the grids.
        .ignoresSafeArea(.container, edges: .horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { DownloadsBackdrop().ignoresSafeArea() }
        .defaultFocus($focusedID, (sections.active + sections.finished).first?.id)
        .fullScreenCover(item: $menuEntry, onDismiss: {
            if let entry = askDelete {
                askDelete = nil
                deleteEntry = entry
            }
        }) { entry in
            DownloadsActionSheet(entry: store.entries.first { $0.id == entry.id } ?? entry,
                                 onAction: { action in
                                     menuEntry = nil
                                     if action == .delete { askDelete = entry } else { perform(action, on: entry) }
                                 },
                                 onClose: { menuEntry = nil })
        }
        .background {
            Color.clear.fullScreenCover(item: $deleteEntry) { entry in
                DownloadsActionSheet(entry: entry, mode: .confirmDelete,
                                     onAction: { _ in
                                         deleteEntry = nil
                                         store.delete(entry.id)
                                     },
                                     onClose: { deleteEntry = nil })
            }
        }
        .accessibilityIdentifier("Downloads.Page")
    }

    // MARK: Header

    private func header(_ active: [DownloadsEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 30) {
                // Same place, size and weight as the other tabs' titles.
                Text(glassSettingsLocalized("Downloads"))
                    .font(.system(size: 75, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(height: 100)
                Spacer(minLength: 20)
                // One button that changes its words: the focus stays on it.
                let running = active.contains(where: \.isRunning)
                if running || active.contains(where: { $0.phase == .paused }) {
                    allButton(running ? "Downloads.PauseAll" : "Downloads.ResumeAll",
                              symbol: running ? "pause.fill" : "arrow.down",
                              id: running ? "Downloads.PauseAll" : "Downloads.ResumeAll") {
                        running ? store.pauseAll() : store.resumeAll()
                    }
                }
            }
            if let used = store.usedBytes, !store.entries.isEmpty {
                Text(text.storage(used: used, free: store.freeBytes))
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(GlassSettingsPalette.secondaryText)
                    .accessibilityIdentifier("Downloads.Storage")
            }
        }
        .padding(.top, 16)
    }

    private func allButton(_ key: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) {
            Label(glassSettingsLocalized(key), systemImage: symbol)
                .font(.system(size: 27, weight: .semibold))
                .padding(.horizontal, 10)
        }
        .glassActionStyle()
        .accessibilityIdentifier(id)
    }

    // MARK: Sections

    private func section(_ title: String, entries: [DownloadsEntry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(glassSettingsLocalized(title))
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(GlassSettingsPalette.secondaryText)
                .padding(.leading, 28)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 1)
                            .padding(.leading, 128)
                            .padding(.trailing, 24)
                    }
                    row(entry)
                }
            }
            .padding(10)
            .modifier(GlassSettingsCard(cornerRadius: 34, fallback: false))
        }
    }

    private func row(_ entry: DownloadsEntry) -> some View {
        SwiftUI.Button { menuEntry = entry } label: {
            DownloadsRowLabel(entry: entry, text: text)
        }
        .buttonStyle(GlassSettingsRowStyle())
        .focused($focusedID, equals: entry.id)
        .contextMenu {
            ForEach(DownloadsActionSheet.actions(for: entry), id: \.self) { action in
                SwiftUI.Button(role: action == .delete ? .destructive : nil) {
                    if action == .delete { deleteEntry = entry } else { perform(action, on: entry) }
                } label: {
                    Text(DownloadsActionSheet.title(of: action))
                }
            }
        }
        .onPlayPauseCommand { toggle(entry) }
        .accessibilityIdentifier("Downloads.Row.\(entry.id)")
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(GlassSettingsPalette.tertiaryText)
            Text(glassSettingsLocalized("Downloads Empty"))
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(.white)
            Text(glassSettingsLocalized("Movies and episodes you download will show up here."))
                .font(.system(size: 29))
                .foregroundStyle(GlassSettingsPalette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 180)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Downloads.Empty")
    }

    // MARK: Actions

    private func toggle(_ entry: DownloadsEntry) {
        switch entry.phase {
        case .downloading: store.pause(entry.id)
        case .waiting: break
        case .paused: store.resume(entry.id)
        case .failed: store.retry(entry.id)
        case .finished: break
        }
    }

    private func perform(_ action: DownloadsAction, on entry: DownloadsEntry) {
        switch action {
        case .play: store.play(entry.id)
        case .pause: store.pause(entry.id)
        case .resume: store.resume(entry.id)
        case .retry: store.retry(entry.id)
        case .delete: store.delete(entry.id)
        case .showDownloads: break
        }
    }
}

/// A row's content: poster, title (and episode line), status, bar.
private struct DownloadsRowLabel: View {
    let entry: DownloadsEntry
    let text: DownloadsText

    var body: some View {
        HStack(spacing: 26) {
            GlassRemoteImage(url: entry.artworkURL, maxPixelSize: 220) {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: entry.kind == .movie ? "film" : "tv")
                        .font(.system(size: 30, weight: .medium))
                        .opacity(0.4)
                }
            }
            .frame(width: 76, height: 114)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(text.title(of: entry))
                    .font(.system(size: 31, weight: .medium))
                    .lineLimit(1)
                if let subtitle = text.subtitle(of: entry) {
                    Text(subtitle)
                        .font(.system(size: 24, weight: .medium))
                        .opacity(0.65)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    if case .failed = entry.phase {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(GlassSettingsPalette.accent)
                    } else if entry.phase == .paused {
                        Image(systemName: "pause.circle.fill")
                            .opacity(0.65)
                    }
                    Text(text.status(of: entry))
                        .opacity(0.65)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 24, weight: .medium))
                if showsBar {
                    DownloadsBar(progress: entry.progress, dimmed: entry.phase != .downloading)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var showsBar: Bool {
        switch entry.phase {
        case .downloading, .paused, .waiting: return true
        case .failed, .finished: return false
        }
    }
}

/// The download's bar: its track takes the row's text colour (white at
/// rest, black on the focused platter), the part done the app's red.
private struct DownloadsBar: View {
    let progress: Double
    var dimmed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(GlassSettingsPalette.accent.opacity(dimmed ? 0.55 : 1))
                    .frame(width: max(6, geometry.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 6)
        .frame(maxWidth: 720)
        .accessibilityHidden(true)
    }
}

/// The black of the other pages, a faint light at the top for the glass.
private struct DownloadsBackdrop: View {
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color.white.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: 1100)
        }
    }
}

// MARK: - Action sheet

/// What can be done with a download, in a glass sheet like the Settings
/// pickers (`.actions`); Delete is then asked in a second sheet
/// (`.confirmDelete`), the focus on Cancel. Menu closes either. Also shown
/// by a title's page (`GlassDetailHostingController`) for a download in
/// progress, with « Show in Downloads ».
struct DownloadsActionSheet: View {
    enum Mode: Equatable {
        case actions(showsGoToDownloads: Bool)
        case confirmDelete
    }

    let entry: DownloadsEntry
    var mode: Mode = .actions(showsGoToDownloads: false)
    /// An action chosen; in `.actions`, `.delete` means « ask » (the host
    /// opens the question), in `.confirmDelete` it means « delete now ».
    let onAction: (DownloadsAction) -> Void
    let onClose: () -> Void

    private let text = DownloadsText()

    static func actions(for entry: DownloadsEntry) -> [DownloadsAction] {
        switch entry.phase {
        case .finished: return [.play, .delete]
        case .downloading: return [.pause, .delete]
        // Still looking for its sources: nothing to pause yet.
        case .waiting: return [.delete]
        case .paused: return [.resume, .delete]
        case .failed: return [.retry, .delete]
        }
    }

    static func title(of action: DownloadsAction) -> String {
        switch action {
        case .play: return glassSettingsLocalized("Play")
        case .pause: return glassSettingsLocalized("Pause")
        case .resume: return glassSettingsLocalized("Resume")
        case .retry: return glassSettingsLocalized("Try Again")
        case .delete: return glassSettingsLocalized("Delete")
        case .showDownloads: return glassSettingsLocalized("Downloads.Action.Show")
        }
    }

    var body: some View {
        switch mode {
        case .confirmDelete:
            GlassSettingsPickerSheet(title: "Delete Download",
                                     message: sheetTitle + "\n" + deleteMessage,
                                     options: [.init(id: DownloadsAction.delete.rawValue, title: glassSettingsLocalized("Delete"), detail: nil),
                                               .init(id: "cancel", title: glassSettingsLocalized("Cancel"), detail: nil)],
                                     selectedID: "cancel",
                                     checkedIDs: [],
                                     onSelect: { id in
                                         if id == DownloadsAction.delete.rawValue { onAction(.delete) } else { onClose() }
                                     },
                                     onCancel: onClose)
        case .actions(let showsGoToDownloads):
            let actions = Self.actions(for: entry) + (showsGoToDownloads ? [.showDownloads] : [])
            GlassSettingsPickerSheet(title: sheetTitle,
                                     message: text.status(of: entry),
                                     options: actions.map { .init(id: $0.rawValue, title: Self.title(of: $0), detail: nil) },
                                     selectedID: actions.first?.rawValue ?? "",
                                     checkedIDs: [],
                                     onSelect: { id in
                                         guard let action = DownloadsAction(rawValue: id) else { return }
                                         onAction(action)
                                     },
                                     onCancel: onClose)
        }
    }

    /// The movie, or « Show · S1 E2 ».
    private var sheetTitle: String {
        let title = text.title(of: entry)
        guard case .episode = entry.kind, let code = text.subtitle(of: entry)?.components(separatedBy: " · ").first else { return title }
        return title + " · " + code
    }

    private var deleteMessage: String {
        if entry.phase == .finished, let size = entry.totalBytes {
            return String(format: glassSettingsLocalized("Downloads.Delete.Finished"), text.bytes(size))
        }
        return glassSettingsLocalized("Downloads.Delete.Active")
    }

    /// Shows the actions over `presenter` (a UIKit page): Delete asks in a
    /// second sheet; `onAction` once the last sheet closed (`.delete`: the
    /// user confirmed).
    static func present(_ entry: DownloadsEntry, showsGoToDownloads: Bool, from presenter: UIViewController,
                        onAction: @escaping (DownloadsAction) -> Void) {
        show(DownloadsActionSheet(entry: entry, mode: .actions(showsGoToDownloads: showsGoToDownloads),
                                  onAction: { _ in }, onClose: {}),
             from: presenter) { action in
            guard action == .delete else { return onAction(action) }
            show(DownloadsActionSheet(entry: entry, mode: .confirmDelete, onAction: { _ in }, onClose: {}),
                 from: presenter, then: onAction)
        }
    }

    /// Only the question, over `presenter`; `onDelete` once confirmed.
    static func confirmDelete(_ entry: DownloadsEntry, from presenter: UIViewController, onDelete: @escaping () -> Void) {
        show(DownloadsActionSheet(entry: entry, mode: .confirmDelete, onAction: { _ in }, onClose: {}),
             from: presenter) { action in if action == .delete { onDelete() } }
    }

    private static func show(_ sheet: DownloadsActionSheet, from presenter: UIViewController,
                             then: @escaping (DownloadsAction) -> Void) {
        weak var host: UIViewController?
        var sheet = sheet
        let close = { (action: DownloadsAction?) in
            host?.dismiss(animated: true) { if let action { then(action) } }
        }
        sheet = DownloadsActionSheet(entry: sheet.entry, mode: sheet.mode,
                                     onAction: { close($0) }, onClose: { close(nil) })
        let controller = UIHostingController(rootView: sheet)
        controller.modalPresentationStyle = .overFullScreen
        controller.view.backgroundColor = .clear
        host = controller
        presenter.present(controller, animated: true)
    }
}
