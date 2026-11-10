// GlassKit.swift — Liquid Glass building blocks of the detail pages (tvOS and
// macOS).
//
// tvOS / macOS 26+: real Liquid Glass (glassEffect, .glass / .glassProminent
// button styles). tvOS 17–25 and macOS 14–15: materials and .bordered /
// .borderedProminent. GlassMetrics and GlassFont are the tvOS 10-foot sizes;
// the Mac page has its own (MacGlassMetrics).
//
// Focus facts this file relies on (checked in the tvOS 26.5 / 27.2 simulators):
// system button styles (.glass, .glassProminent, .card, .bordered…) draw their
// own focus state, but a custom view with glassEffect + focusable / hover
// effects shows no focus at all. Custom focusable glass therefore goes through
// a ButtonStyle that reads @Environment(\.isFocused) (GlassCardButtonStyle,
// GlassCircleButtonStyle).
//
// No GlassEffectContainer is used: on tvOS 27.2 it logs "glassEffect() tried
// to update multiple times per frame" when focus moves between its buttons.
// Leaving it out does not rule the message out: it still showed up, rarely
// (about one launch in 20 to 60 in the simulator) and with no visible effect,
// when focus was set by code while a scroll was animating (initial focus on
// Play, a programmatic move into the season pills). The season pills
// therefore no longer change their glass on focus (GlassPillButtonStyle).
import SwiftUI

enum GlassPalette {
    /// The app accent (AccentColor, dark appearance) without depending on the asset catalog.
    static let accent = Color(red: 0.949, green: 0.290, blue: 0.235)
    static let star = Color(red: 1.0, green: 0.78, blue: 0.24)
    /// Primary text over artwork / glass.
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.72)
    static let tertiaryText = Color.white.opacity(0.55)
}

/// Layout constants for a 1920×1080 screen (tvOS safe area: 60 pt top and
/// bottom, 80–90 pt on the sides). The page ignores the safe area and applies
/// these insets itself so it looks the same in any host.
enum GlassMetrics {
    static let sideInset: CGFloat = 90
    static let topInset: CGFloat = 60
    static let bottomInset: CGFloat = 60
    /// Height of the next section left visible under the first screen.
    static let peek: CGFloat = 200
    static let cardCorner: CGFloat = 28
}

/// Fonts sized for the 10-foot UI (explicit sizes: tvOS text styles differ by OS).
enum GlassFont {
    static let heroTitle = Font.system(size: 76, weight: .heavy)
    static let sectionTitle = Font.system(size: 38, weight: .bold)
    static let body = Font.system(size: 30, weight: .regular)
    static let bodyEmphasis = Font.system(size: 30, weight: .semibold)
    static let metadata = Font.system(size: 29, weight: .medium)
    static let caption = Font.system(size: 25, weight: .medium)
    static let captionBold = Font.system(size: 24, weight: .semibold)
    static let small = Font.system(size: 22, weight: .semibold)
}

// MARK: - Glass on/off switch

#if DEBUG
private struct GlassFallbackKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// true forces the tvOS 17–25 (material) look even where Liquid Glass
    /// exists, for side-by-side screenshots (DEBUG builds only).
    var glassFallback: Bool {
        get { self[GlassFallbackKey.self] }
        set { self[GlassFallbackKey.self] = newValue }
    }
}
#else
extension EnvironmentValues {
    /// Liquid Glass wherever the system has it (the switch exists in DEBUG
    /// builds only).
    var glassFallback: Bool { false }
}
#endif

// MARK: - Surfaces

private struct GlassSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    /// Use the clear variant (only over rich media, never for text blocks).
    let clear: Bool
    let fallbackMaterial: Material
    @Environment(\.glassFallback) private var fallback

    func body(content: Content) -> some View {
        if #available(tvOS 26.0, macOS 26.0, *), !fallback {
            content.glassEffect((clear ? Glass.clear : Glass.regular).tint(tint), in: shape)
        } else {
            content
                .background {
                    shape.fill(fallbackMaterial)
                    if let tint { shape.fill(tint.opacity(0.35)) }
                }
                .overlay { shape.glassHairline(Color.white.opacity(0.14), lineWidth: 1) }
        }
    }
}

private extension Shape {
    /// Inner hairline for any Shape (strokeBorder needs an InsettableShape).
    func glassHairline(_ color: Color, lineWidth: CGFloat) -> some View {
        stroke(color, lineWidth: lineWidth).padding(lineWidth / 2)
    }
}

extension View {
    /// A non-focusable glass surface (regular glass on tvOS 26+, a material before).
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, clear: Bool = false,
                                fallback material: Material = .ultraThinMaterial) -> some View {
        modifier(GlassSurfaceModifier(shape: shape, tint: tint, clear: clear, fallbackMaterial: material))
    }

    /// Rounded-rectangle glass panel.
    func glassPanel(cornerRadius: CGFloat = GlassMetrics.cardCorner, tint: Color? = nil) -> some View {
        glassSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
    }

    /// System glass button style: .glassProminent (accent) / .glass on tvOS 26+,
    /// .borderedProminent / .bordered before. The focus engine draws focus.
    func glassActionStyle(prominent: Bool = false) -> some View {
        modifier(GlassActionStyleModifier(prominent: prominent))
    }
}

private struct GlassActionStyleModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.glassFallback) private var fallback

    func body(content: Content) -> some View {
        if #available(tvOS 26.0, macOS 26.0, *), !fallback {
            if prominent {
                content.buttonStyle(.glassProminent).tint(GlassPalette.accent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent).tint(GlassPalette.accent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Custom focusable glass

/// A focusable glass card (summary cards, information cards). Unfocused it is
/// regular glass with white text; focused it turns into bright glass with dark
/// text, lifts and casts a shadow, like the system glass buttons.
struct GlassCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = GlassMetrics.cardCorner
    /// Scale when focused. Keep it small for wide cards.
    var focusScale: CGFloat = 1.03

    func makeBody(configuration: Configuration) -> some View {
        GlassCardBody(configuration: configuration, cornerRadius: cornerRadius, focusScale: focusScale)
    }

    private struct GlassCardBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let focusScale: CGFloat
        @Environment(\.isFocused) private var isFocused
        @Environment(\.glassFallback) private var fallback

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .background { focusedFill(shape) }
                .modifier(CardGlass(shape: shape, isFocused: isFocused, fallback: fallback))
                .scaleEffect(configuration.isPressed ? focusScale - 0.02 : (isFocused ? focusScale : 1))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 26, y: 18)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }

        @ViewBuilder private func focusedFill(_ shape: RoundedRectangle) -> some View {
            // tvOS 17–25: an opaque light fill carries the focus state.
            if isFocused, !glassAvailable { shape.fill(Color.white.opacity(0.92)) }
        }

        private var glassAvailable: Bool {
            if #available(tvOS 26.0, macOS 26.0, *) { return !fallback }
            return false
        }
    }

    private struct CardGlass: ViewModifier {
        let shape: RoundedRectangle
        let isFocused: Bool
        let fallback: Bool

        func body(content: Content) -> some View {
            if #available(tvOS 26.0, macOS 26.0, *), !fallback {
                content.glassEffect(isFocused ? .regular.tint(.white.opacity(0.88)) : .regular, in: shape)
            } else if isFocused {
                content
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
            }
        }
    }
}

/// Round focusable item (cast headshots). The label is drawn as-is; focus
/// adds a lift, a bright ring and a shadow.
struct GlassCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration)
    }

    private struct CircleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .environment(\.glassItemFocused, isFocused)
                .scaleEffect(configuration.isPressed ? 1.06 : (isFocused ? 1.12 : 1))
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

private struct GlassItemFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Focus state handed by GlassCircleButtonStyle to its label (to light up
    /// the ring and the caption).
    var glassItemFocused: Bool {
        get { self[GlassItemFocusedKey.self] }
        set { self[GlassItemFocusedKey.self] = newValue }
    }
}

#if os(tvOS)
/// Poster / episode cards: the system .card style (lift, parallax, glassy
/// platter on tvOS 26+), available on every supported tvOS.
extension View {
    func glassCardStyle() -> some View {
        buttonStyle(.card)
    }
}
#endif

// MARK: - Small pieces

/// 0–5 stars in halves.
struct GlassStarRating: View {
    let stars: Double
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: size * 0.18) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: symbol(index))
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(GlassPalette.star)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(format: "%.1f / 5", stars)))
    }

    private func symbol(_ index: Int) -> String {
        let base = Double(index)
        if stars >= base + 1 { return "star.fill" }
        if stars >= base + 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// Outlined capsule chip ("4K", "Dolby Vision", "PG-13").
struct GlassChip: View {
    let text: String
    var systemImage: String? = nil
    /// Stronger fill for the most important chip (best quality).
    var emphasized = false
    /// Text size; padding, corner and stroke follow (22 = Apple TV).
    var fontSize: CGFloat = 22

    var body: some View {
        let k = fontSize / 22
        HStack(spacing: 8 * k) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: fontSize - 2, weight: .bold))
            }
            Text(verbatim: text)
                .font(.system(size: fontSize, weight: .bold))
                .tracking(0.4 * k)
        }
        .foregroundStyle(Color.white.opacity(0.95))
        .padding(.horizontal, 16 * k)
        .padding(.vertical, 7 * k)
        .background {
            RoundedRectangle(cornerRadius: 9 * k, style: .continuous)
                .fill(Color.white.opacity(emphasized ? 0.24 : 0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9 * k, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: max(1, 1.5 * k))
        }
        .fixedSize()
    }
}

/// Thin progress bar (episode / movie progress).
struct GlassProgressBar: View {
    let progress: Double
    var height: CGFloat = 6
    var tint: Color = GlassPalette.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                Capsule().fill(tint)
                    .frame(width: max(height, geo.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Ring drawn around download icons.
struct GlassDownloadRing: View {
    let state: GlassDownloadState
    var lineWidth: CGFloat = 4
    @State private var spin = false

    var body: some View {
        ZStack {
            switch state {
            case .pending:
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(GlassPalette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            case .downloading(let p), .paused(let p):
                Circle().stroke(Color.white.opacity(0.25), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: min(max(p, 0.02), 1))
                    .stroke(GlassPalette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            case .idle, .downloaded:
                EmptyView()
            }
        }
    }
}

// MARK: - Text truncation, poster card

/// true when a line-limited Text is cut (see glassReportsTruncation).
struct GlassTruncationKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// Measures `text` without a line limit at this view's width and reports
    /// through GlassTruncationKey whether it is taller than this view.
    func glassReportsTruncation(of text: String, font: Font, lineSpacing: CGFloat) -> some View {
        background {
            GeometryReader { limited in
                Text(verbatim: text)
                    .font(font)
                    .lineSpacing(lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: limited.size.width, alignment: .topLeading)
                    .hidden()
                    .background {
                        GeometryReader { full in
                            Color.clear.preference(key: GlassTruncationKey.self,
                                                   value: full.size.height > limited.size.height + 2)
                        }
                    }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Crisp 2:3 poster shown in the hero when the background is only a blurred poster.
struct GlassPosterCard: View {
    let url: URL
    let title: String
    var width: CGFloat = 340
    /// Corner radius and placeholder title size (Apple TV values by default).
    var cornerRadius: CGFloat = 26
    var placeholderFont: Font = GlassFont.bodyEmphasis

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GlassRemoteImage(url: url, maxPixelSize: width * 2) {
            ZStack {
                Color.white.opacity(0.08)
                Text(verbatim: title)
                    .font(placeholderFont)
                    .foregroundStyle(GlassPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.55), radius: 40, y: 24)
        .accessibilityHidden(true)
    }
}
