// GlassTextSheet.swift — full summary on a glass sheet (replaces the old
// "…More" TVDescriptionViewController). Drawn inside GlassDetailView, above
// the disabled page: Menu or Select closes it.
import SwiftUI

struct GlassTextSheet: View {
    let text: GlassExpandedText
    let onClose: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            SwiftUI.Button(action: onClose) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: text.title)
                        .font(.system(size: 52, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    if let subtitle = text.subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(GlassFont.caption)
                            .foregroundStyle(GlassPalette.secondaryText)
                            .padding(.top, 12)
                    }
                    Text(verbatim: text.body)
                        .font(.system(size: 31, weight: .regular))
                        .lineSpacing(9)
                        .multilineTextAlignment(.leading)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 34)
                }
                .foregroundStyle(GlassPalette.primaryText)
                .padding(.horizontal, 70)
                .padding(.vertical, 64)
                .frame(width: 1320, alignment: .leading)
                .frame(maxHeight: 900)
                .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(GlassSheetPanelStyle())
            .focused($isFocused)
            .onExitCommand(perform: onClose)
            .accessibilityIdentifier("Detail.TextSheet")
        }
        .onAppear { isFocused = true }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// The sheet is the only focusable element on screen, so it shows no focus
/// change: a plain glass panel.
private struct GlassSheetPanelStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassSurface(RoundedRectangle(cornerRadius: 44, style: .continuous), fallback: .regularMaterial)
            .shadow(color: .black.opacity(0.4), radius: 50, y: 30)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}
