

import SwiftUI

/// Vertical-list picker for VLC subtitle / audio tracks.
///
/// Replaces `UIAlertController(.actionSheet)` because on Mac (Designed for
/// iPad) the action sheet renders as a horizontal strip at the bottom of the
/// window, so multi-language MKVs (10+ subtitle tracks) overflow off-screen
/// and become unusable. A SwiftUI `List` inside a `formSheet` is scrollable,
/// keyboard-focusable, looks at home on every form factor, and supports
/// large-title navigation + dismiss button consistently.
struct TrackPickerSheet: View {
    let title: String
    let tracks: [(index: Int32, name: String)]
    let selectedIndex: Int32
    /// True for subtitles (we add a synthetic "Aucun" row that maps to -1).
    /// False for audio — there is always at least one active track.
    let allowDisable: Bool
    let onSelect: (Int32) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if allowDisable {
                    row(label: "Aucun", isSelected: selectedIndex < 0) {
                        onSelect(-1); dismiss()
                    }
                }
                if tracks.isEmpty && !allowDisable {
                    Text("Aucune piste détectée")
                        .foregroundStyle(.secondary)
                }
                ForEach(tracks, id: \.index) { track in
                    row(label: track.name, isSelected: track.index == selectedIndex) {
                        onSelect(track.index); dismiss()
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func row(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 12)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
