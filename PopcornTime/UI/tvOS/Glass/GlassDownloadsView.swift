// GlassDownloadsView.swift — the Downloads tab of the Apple TV, in the look
// of the Settings page and the Home's shelves: the page title with a calm
// storage capsule and Pause All, then « Downloading » — a glass card of rows,
// each a landscape still, the title, one quiet line, the percentage large on
// the trailing side and a slim bar the width of the row — and « Downloaded »,
// a shelf of posters. Select opens what can be done (Play, Pause, Resume, Try
// Again, Delete); a long press shows the same; Play/Pause on the remote
// pauses or resumes a row.

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
    /// The row that takes the focus once a deleted row's question closed:
    /// the next one, else the one before (not the page's first).
    @State private var focusAfterDelete: String?
    @FocusState private var focusedID: String?
    private let text = DownloadsText()

    /// The shelf's posters: the width of the detail page's related titles.
    static let posterWidth: CGFloat = 220

    var body: some View {
        let sections = DownloadsCatalog.sections(store.entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                header(sections.active)
                if store.entries.isEmpty {
                    emptyState
                } else {
                    if !sections.active.isEmpty {
                        activeSection(sections.active)
                    }
                    if !sections.finished.isEmpty {
                        shelf(sections.finished)
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
            Color.clear.fullScreenCover(item: $deleteEntry, onDismiss: {
                guard let id = focusAfterDelete else { return }
                focusAfterDelete = nil
                // Set again from nil: the state may already hold the id (the
                // focus came back to nothing, the deleted row), and the same
                // value moves nothing.
                focusedID = nil
                DispatchQueue.main.async { focusedID = id }
            }) { entry in
                DownloadsActionSheet(entry: entry, mode: .confirmDelete,
                                     onAction: { _ in
                                         deleteEntry = nil
                                         delete(entry)
                                     },
                                     onClose: { deleteEntry = nil })
            }
        }
        .accessibilityIdentifier("Downloads.Page")
    }

    // MARK: Header

    private func header(_ active: [DownloadsEntry]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 30) {
                // Same place, size and weight as the other tabs' titles.
                Text(glassSettingsLocalized("Downloads"))
                    .font(.system(size: 75, weight: .heavy))
                    .foregroundStyle(.white)
                Spacer(minLength: 20)
                // One button that changes its words: the focus stays on it.
                let running = active.contains(where: \.isRunning)
                if running || active.contains(where: { $0.phase == .paused }) {
                    SwiftUI.Button {
                        running ? store.pauseAll() : store.resumeAll()
                    } label: {
                        Label(glassSettingsLocalized(running ? "Downloads.PauseAll" : "Downloads.ResumeAll"),
                              systemImage: running ? "pause.fill" : "arrow.down")
                            .font(.system(size: 27, weight: .semibold))
                            .padding(.horizontal, 6)
                    }
                    .glassActionStyle()
                    .accessibilityIdentifier(running ? "Downloads.PauseAll" : "Downloads.ResumeAll")
                }
            }
            .padding(.top, 16)
            if !store.entries.isEmpty, let free = store.freeBytes {
                DownloadsStorageGauge(used: store.usedBytes ?? 0, free: free,
                                      caption: text.storageCaption(used: store.usedBytes ?? 0, free: free))
                    .accessibilityIdentifier("Downloads.Storage")
            }
        }
    }

    // MARK: Downloading

    private func activeSection(_ entries: [DownloadsEntry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Downloads.Section.Downloading")
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                            .padding(.leading, 26 + DownloadsRow.stillWidth + 34)
                            .padding(.trailing, 26)
                    }
                    SwiftUI.Button { menuEntry = entry } label: {
                        DownloadsRow(entry: entry, text: text)
                    }
                    .buttonStyle(GlassSettingsRowStyle(cornerRadius: 26))
                    .focused($focusedID, equals: entry.id)
                    .contextMenu { contextMenu(for: entry) }
                    .onPlayPauseCommand { toggle(entry) }
                    .accessibilityLabel(Text(verbatim: [text.title(of: entry), text.episodeCode(of: entry), text.status(of: entry)]
                        .compactMap { $0 }.joined(separator: ", ")))
                    .accessibilityIdentifier("Downloads.Row.\(entry.id)")
                }
            }
            .padding(12)
            .modifier(GlassSettingsCard(cornerRadius: 38, fallback: false))
        }
    }

    // MARK: Downloaded

    /// A shelf of posters, like the Home's and the title page's.
    private func shelf(_ entries: [DownloadsEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Downloads.Section.Downloaded")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 48) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 0) {
                            SwiftUI.Button { menuEntry = entry } label: {
                                GlassRemoteImage(url: entry.artworkURL, maxPixelSize: Self.posterWidth * 2) {
                                    ZStack {
                                        Color.white.opacity(0.08)
                                        Text(verbatim: text.title(of: entry))
                                            .font(GlassFont.captionBold)
                                            .foregroundStyle(GlassPalette.secondaryText)
                                            .multilineTextAlignment(.center)
                                            .padding(18)
                                    }
                                }
                                .frame(width: Self.posterWidth, height: Self.posterWidth * 1.5)
                                .clipped()
                            }
                            .glassCardStyle()
                            .focused($focusedID, equals: entry.id)
                            .contextMenu { contextMenu(for: entry) }
                            .accessibilityLabel(Text(verbatim: [text.title(of: entry), text.episodeCode(of: entry), text.status(of: entry)]
                                .compactMap { $0 }.joined(separator: ", ")))
                            .accessibilityIdentifier("Downloads.Row.\(entry.id)")

                            Text(verbatim: text.title(of: entry))
                                .font(GlassFont.captionBold)
                                .foregroundStyle(GlassPalette.primaryText)
                                .lineLimit(1)
                                .padding(.top, 22)
                            Text(verbatim: [text.episodeCode(of: entry), text.status(of: entry)]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(GlassFont.small)
                                .foregroundStyle(GlassPalette.tertiaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .padding(.top, 4)
                        }
                        .frame(width: Self.posterWidth, alignment: .leading)
                    }
                }
                .padding(.vertical, 34)
                .padding(.horizontal, 28)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(glassSettingsLocalized(key))
            .font(.system(size: 29, weight: .semibold))
            .foregroundStyle(GlassSettingsPalette.secondaryText)
            .padding(.leading, 28)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func contextMenu(for entry: DownloadsEntry) -> some View {
        ForEach(DownloadsActionSheet.actions(for: entry), id: \.self) { action in
            SwiftUI.Button(role: action == .delete ? .destructive : nil) {
                if action == .delete { deleteEntry = entry } else { perform(action, on: entry) }
            } label: {
                Text(DownloadsActionSheet.title(of: action))
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 28) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 88, weight: .light))
                .foregroundStyle(GlassSettingsPalette.tertiaryText)
            Text(glassSettingsLocalized("Movies and episodes you download will show up here."))
                .font(.system(size: 31, weight: .medium))
                .foregroundStyle(GlassSettingsPalette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 220)
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

    /// Deletes the row's download; its neighbour gets the focus.
    private func delete(_ entry: DownloadsEntry) {
        let sections = DownloadsCatalog.sections(store.entries)
        let rows = (sections.active + sections.finished).map(\.id)
        if let index = rows.firstIndex(of: entry.id) {
            focusAfterDelete = index + 1 < rows.count ? rows[index + 1] : (index > 0 ? rows[index - 1] : nil)
        }
        store.delete(entry.id)
    }

    private func perform(_ action: DownloadsAction, on entry: DownloadsEntry) {
        switch action {
        case .play: store.play(entry.id)
        case .pause: store.pause(entry.id)
        case .resume: store.resume(entry.id)
        case .retry: store.retry(entry.id)
        case .delete: delete(entry)
        case .showDownloads: break
        }
    }
}

/// A row of « Downloading »: the still, the title (an episode's code beside
/// it, quieter), one quiet line, the percentage large on the trailing side,
/// and under the texts a slim bar to the row's trailing edge.
private struct DownloadsRow: View {
    let entry: DownloadsEntry
    let text: DownloadsText

    static let stillWidth: CGFloat = 208

    var body: some View {
        HStack(alignment: .center, spacing: 34) {
            GlassRemoteImage(url: entry.stillURL ?? entry.artworkURL,
                             alternates: [entry.artworkURL].compactMap { $0 },
                             maxPixelSize: Self.stillWidth * 2) {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: entry.kind == .movie ? "film" : "tv")
                        .font(.system(size: 34, weight: .medium))
                        .opacity(0.4)
                }
            }
            .frame(width: Self.stillWidth, height: Self.stillWidth * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        (Text(verbatim: text.title(of: entry))
                            + Text(verbatim: text.episodeCode(of: entry).map { "   " + $0 } ?? "")
                                .foregroundStyle(.secondary))
                            .font(.system(size: 31, weight: .medium))
                            .lineLimit(1)
                        Text(verbatim: text.detail(of: entry))
                            .font(.system(size: 23, weight: .medium))
                            .monospacedDigit()
                            .opacity(0.6)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 20)
                    trailing
                }
                if showsBar {
                    DownloadsBar(progress: entry.progress, active: entry.phase == .downloading)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
    }

    /// The state at a glance: the percentage, a spinner while it looks for
    /// its sources, a mark when it failed.
    @ViewBuilder private var trailing: some View {
        switch entry.phase {
        case .downloading, .paused:
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if entry.phase == .paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .opacity(0.55)
                }
                Text(verbatim: text.percent(entry.progress))
                    .font(.system(size: 42, weight: .semibold))
                    .monospacedDigit()
                    .opacity(entry.phase == .paused ? 0.55 : 1)
            }
        case .waiting:
            ProgressView()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(GlassSettingsPalette.accent)
        case .finished:
            EmptyView()
        }
    }

    private var showsBar: Bool {
        switch entry.phase {
        case .downloading, .paused, .waiting: return true
        case .failed, .finished: return false
        }
    }
}

/// The download's bar: a slim capsule the row's width, its track the row's
/// text colour faintly (white at rest, black on the focused platter), the
/// part done the app's red while it downloads, neutral while paused.
private struct DownloadsBar: View {
    let progress: Double
    var active: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(active ? AnyShapeStyle(GlassSettingsPalette.accent) : AnyShapeStyle(.secondary))
                    .frame(width: max(5, geometry.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.smooth(duration: 0.8), value: progress)
        .animation(.easeOut(duration: 0.25), value: active)
        .accessibilityHidden(true)
    }
}

/// How much of the space the downloads take: a thin capsule (the
/// downloads' part bright, the free part faint) and a short caption.
private struct DownloadsStorageGauge: View {
    let used: Int64
    let free: Int64
    let caption: String

    var body: some View {
        HStack(spacing: 22) {
            GeometryReader { geometry in
                let share = free + used > 0 ? Double(used) / Double(free + used) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: used > 0 ? max(14, geometry.size.width * share) : 0)
                }
            }
            .frame(width: 260, height: 6)
            Text(verbatim: caption)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(GlassSettingsPalette.secondaryText)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: caption))
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
