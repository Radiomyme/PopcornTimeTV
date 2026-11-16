// GlassSourcesViews.swift — what a detail page shows while its sources are
// searched: the page opens before they are in (GlassSourcesState), and says
// so quietly, where the capability chips go and in the Play button.
import Foundation
import SwiftUI

/// A small activity ring in the current foreground style, at any size (the
/// system spinner comes in one size on Apple TV, and none fits a button's
/// label or a chip). Turns slower when Reduce Motion is on.
struct GlassSpinner: View {
    var size: CGFloat = 26
    @State private var isTurning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.8)
            .stroke(style: StrokeStyle(lineWidth: max(2, size / 8), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isTurning ? 360 : 0))
            .animation(.linear(duration: reduceMotion ? 2.4 : 0.9).repeatForever(autoreverses: false), value: isTurning)
            .onAppear { isTurning = true }
            .accessibilityHidden(true)
    }
}

/// The end of the capability chips' row while the sources are searched —
/// "Looking for sources…" before the first one, a lone ring while others
/// may still add to the list — and when the search found nothing. As tall
/// as a `GlassChip` of the same `fontSize`, so the row keeps its height
/// when the chips replace it.
struct GlassSourcesNote: View {
    let state: GlassSourcesState
    /// Text size (22 = Apple TV), as `GlassChip`.
    var fontSize: CGFloat = 22

    var body: some View {
        let k = fontSize / 22
        Group {
            switch state {
            case .searching:
                HStack(spacing: 12 * k) {
                    GlassSpinner(size: fontSize)
                    Text("Sources.Loading")
                }
                .accessibilityElement(children: .combine)
            case .partial:
                ZStack { GlassSpinner(size: fontSize) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Sources.Loading"))
            case .none:
                Text("No torrents found")
            case .ready:
                EmptyView()
            }
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(GlassPalette.secondaryText)
        // A chip's vertical padding, and the height of its text line.
        .padding(.vertical, 7 * k)
        .frame(minHeight: fontSize * 1.2 + 14 * k)
        .fixedSize()
        .transition(.opacity)
    }
}

/// Why the page has nothing to play (`GlassDetailModel.loadError`), where
/// the capability chips go.
struct GlassLoadErrorNote: View {
    let message: String
    var fontSize: CGFloat = 25

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(GlassPalette.star)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .font(.system(size: fontSize, weight: .medium))
        .foregroundStyle(GlassPalette.primaryText)
        .accessibilityIdentifier("Detail.LoadError")
        .transition(.opacity)
    }
}
