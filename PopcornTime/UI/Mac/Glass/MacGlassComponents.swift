// MacGlassComponents.swift — Mac building blocks of the Liquid Glass detail
// page: window-sized metrics and fonts, pointer (hover) button styles, the
// horizontal shelf with paging chevrons, section headers and the glass text
// sheet. The glass surfaces themselves come from GlassKit (shared with tvOS).
//
// On the Mac, `isFocused` is keyboard focus, not the pointer: the custom
// styles here track the pointer with onHover and treat keyboard focus the
// same way, so Tab navigation (when enabled in System Settings) shows the
// same lift as hovering.
import SwiftUI

/// Layout constants of the Mac page (a resizable window, ~1400×900 typical).
enum MacGlassMetrics {
    static let sideInset: CGFloat = 52
    /// Space above each lower section.
    static let sectionSpacing: CGFloat = 34
    /// Height of the next section left visible under the first screen.
    static let peek: CGFloat = 110
    static let cardCorner: CGFloat = 18
    /// Hero text column.
    static let heroMaxWidth: CGFloat = 680
    static let stillWidth: CGFloat = 280
    static let stillCorner: CGFloat = 12
    static let posterWidth: CGFloat = 150
    static let posterCorner: CGFloat = 12
    static let headshot: CGFloat = 108
    static let personWidth: CGFloat = 130
    /// Artwork decode size (longest side, pixels): Retina windows.
    static let backdropPixels: CGFloat = 2560
}

/// Mac type scale (explicit sizes: the page draws over artwork, not in a
/// standard window background).
enum MacGlassFont {
    static let heroTitle = Font.system(size: 54, weight: .heavy)
    static let sectionTitle = Font.system(size: 22, weight: .bold)
    static let body = Font.system(size: 15, weight: .regular)
    static let bodyEmphasis = Font.system(size: 15, weight: .semibold)
    static let metadata = Font.system(size: 14, weight: .medium)
    static let caption = Font.system(size: 13, weight: .medium)
    static let captionBold = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 11.5, weight: .semibold)
}

// MARK: - Hover state

private struct MacGlassHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MacGlassPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Pointer over (or keyboard focus on) the enclosing MacGlassHoverButtonStyle button.
    var macGlassHovered: Bool {
        get { self[MacGlassHoveredKey.self] }
        set { self[MacGlassHoveredKey.self] = newValue }
    }

    /// The enclosing MacGlassHoverButtonStyle button is pressed.
    var macGlassPressed: Bool {
        get { self[MacGlassPressedKey.self] }
        set { self[MacGlassPressedKey.self] = newValue }
    }
}

/// A plain button that hands its hover / focus / press state to its label
/// (environment `macGlassHovered`, `macGlassPressed`): posters, stills and
/// headshots lift their image (`macGlassLift`), not their caption.
struct MacGlassHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .environment(\.macGlassHovered, isEnabled && (isHovering || isFocused))
                .environment(\.macGlassPressed, configuration.isPressed)
                .onHover { isHovering = $0 }
        }
    }
}

/// Lift of an image inside a MacGlassHoverButtonStyle button: clip, hairline,
/// small scale and a deeper shadow on hover.
private struct MacGlassLift<S: InsettableShape>: ViewModifier {
    let shape: S
    let scale: CGFloat
    @Environment(\.macGlassHovered) private var isHovered
    @Environment(\.macGlassPressed) private var isPressed

    func body(content: Content) -> some View {
        content
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(isHovered ? 0.65 : 0.12), lineWidth: isHovered ? 2 : 1))
            .scaleEffect(isPressed ? scale - 0.02 : (isHovered ? scale : 1))
            .shadow(color: .black.opacity(isHovered ? 0.55 : 0.3), radius: isHovered ? 20 : 8, y: isHovered ? 12 : 4)
            .animation(.easeOut(duration: 0.16), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }
}

extension View {
    func macGlassLift<S: InsettableShape>(_ shape: S, scale: CGFloat = 1.04) -> some View {
        modifier(MacGlassLift(shape: shape, scale: scale))
    }
}

/// A clickable glass card (summary, episode panel): regular glass, a little
/// brighter with a lift on hover.
struct MacGlassCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = MacGlassMetrics.cardCorner
    var hoverScale: CGFloat = 1.01

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, cornerRadius: cornerRadius, hoverScale: hoverScale)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let hoverScale: CGFloat
        @State private var isHovering = false
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let lit = isHovering || isFocused
            configuration.label
                .foregroundStyle(GlassPalette.primaryText)
                .contentShape(shape)
                // The glass itself never changes (it depends on nothing that
                // moves); the hover light is a fill under the content.
                .background { shape.fill(Color.white.opacity(lit ? 0.09 : 0)) }
                .glassSurface(shape)
                .scaleEffect(configuration.isPressed ? hoverScale - 0.006 : (lit ? hoverScale : 1))
                .shadow(color: .black.opacity(lit ? 0.4 : 0.15), radius: lit ? 22 : 10, y: lit ? 12 : 4)
                .animation(.easeOut(duration: 0.16), value: lit)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { isHovering = $0 }
        }
    }
}

/// Season pill: glass capsule, accent-tinted when selected, lit on hover.
struct MacGlassPillButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, selected: selected)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var isHovering = false
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let lit = isHovering || isFocused
            configuration.label
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundStyle(GlassPalette.primaryText)
                .contentShape(Capsule())
                .background { Capsule().fill(Color.white.opacity(lit && !selected ? 0.12 : 0)) }
                .glassSurface(Capsule(), tint: selected ? GlassPalette.accent.opacity(0.85) : nil)
                .scaleEffect(configuration.isPressed ? 1.0 : (lit ? 1.05 : 1))
                .shadow(color: .black.opacity(lit ? 0.35 : 0), radius: 12, y: 6)
                .animation(.easeOut(duration: 0.15), value: lit)
                .animation(.easeOut(duration: 0.15), value: selected)
                .onHover { isHovering = $0 }
        }
    }
}

// MARK: - Round glass action

/// Round glass icon button (Watchlist, Watched) with a tooltip and a caption
/// under it while the pointer is over it.
struct MacGlassCircleAction: View {
    let systemImage: String
    /// "On" state (in watchlist, watched): accent-colored icon.
    var isOn = false
    let caption: Text
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isOn ? AnyShapeStyle(GlassPalette.accent) : AnyShapeStyle(.primary))
                .frame(width: 24, height: 24)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonBorderShape(.circle)
        .glassActionStyle()
        .controlSize(.extraLarge)
        .help(caption)
        .onHover { isHovering = $0 }
        .overlay(alignment: .bottom) {
            caption
                .font(MacGlassFont.small)
                .foregroundStyle(GlassPalette.primaryText)
                .fixedSize()
                .shadow(color: .black.opacity(0.7), radius: 5, y: 1)
                .offset(y: 24)
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityLabel(caption)
    }
}

// MARK: - Spinner

/// Indeterminate spinner drawn by SwiftUI itself, for containers that scale:
/// a lifted still (`macGlassLift`), a glass button that grows on hover and
/// bounces on press. The system ProgressView is an AppKit view
/// (NSProgressIndicator, fixed 16 / 32 pt sizes) that SwiftUI scales by
/// resizing it: every frame of such an animation logged "AppKitProgressView
/// … has an maximum length (32.35…) that doesn't satisfy min <= max".
/// VoiceOver reads it as "Loading…", like the system spinner it replaces.
struct MacGlassSpinner: View {
    /// 16 = the small system spinner, 32 = the regular one.
    var diameter: CGFloat = 32
    /// Nil: the foreground style (a button label's color).
    var color: Color?

    private static let spokes = 8
    /// Steps per second (the system spinner turns in steps too).
    private static let rate = 10.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.rate)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate * Self.rate) % Self.spokes
            ZStack {
                ForEach(0..<Self.spokes, id: \.self) { index in
                    Capsule()
                        .fill(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                        .frame(width: max(1.5, diameter * 0.09), height: diameter * 0.28)
                        .offset(y: -diameter * 0.32)
                        .rotationEffect(.degrees(Double(index) * 360 / Double(Self.spokes)))
                        .opacity(Self.opacity(of: index, at: step))
                }
            }
            .frame(width: diameter, height: diameter)
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: NSLocalizedString("Spinner.Loading", value: "Loading…",
                                                              comment: "VoiceOver: a spinner (something is loading)")))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The leading spoke opaque, the ones behind it fading out (clockwise).
    private static func opacity(of index: Int, at step: Int) -> Double {
        let behind = (step - index + spokes) % spokes
        return 1 - Double(behind) / Double(spokes) * 0.8
    }
}

// MARK: - Section header

struct MacGlassSectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(MacGlassFont.sectionTitle)
            .foregroundStyle(GlassPalette.primaryText)
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            .padding(.horizontal, MacGlassMetrics.sideInset)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Scroll metrics

/// Where a scroll view is along one axis: the distance scrolled from its rest
/// position, its content length and its visible length.
struct MacScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentLength: CGFloat = 0
    var viewportLength: CGFloat = 0
}

/// Reports a scroll view's metrics along `axis` (macOS 15+: on every scroll;
/// macOS 14 has no such API: the caller measures its content instead).
struct MacScrollMetricsReader: ViewModifier {
    let axis: Axis
    let onChange: (MacScrollMetrics) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: MacScrollMetrics.self) { geometry in
                axis == .vertical
                    ? MacScrollMetrics(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                       contentLength: geometry.contentSize.height,
                                       viewportLength: geometry.containerSize.height)
                    : MacScrollMetrics(offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                                       contentLength: geometry.contentSize.width,
                                       viewportLength: geometry.containerSize.width)
            } action: { _, metrics in
                onChange(metrics)
            }
        } else {
            content
        }
    }
}

extension View {
    func macScrollMetrics(_ axis: Axis, onChange: @escaping (MacScrollMetrics) -> Void) -> some View {
        modifier(MacScrollMetricsReader(axis: axis, onChange: onChange))
    }
}

/// A scroll position that changes on every frame, kept out of SwiftUI state
/// (a class held in @State, never observed): views store only what they
/// derive from it (dimmed, chevrons shown), when that changes.
final class MacScrollTracker {
    var metrics = MacScrollMetrics()
    /// macOS 14: the content's position at rest, latched from the first layout.
    var restY: CGFloat?
    /// macOS 14: the last content position seen, and the top safe-area
    /// inset of that layout (`noteContent`).
    private var lastY: CGFloat?
    private var lastInset: CGFloat?

    /// macOS 14 (no scroll geometry API): the vertical offset from where the
    /// content's top lies in the scroll view (`y`, in its coordinate space)
    /// under a top safe-area inset `inset`. The rest position is latched
    /// from the first layout (a rubber-band pull must not move it). A
    /// layout that comes with another inset (window toolbar shown / hidden,
    /// full screen) re-bases it by the content's move in that layout: the
    /// inset moved the content, the user did not scroll — re-latching from
    /// that frame would take a scrolled page for one at rest.
    func noteContent(y: CGFloat, inset: CGFloat) {
        if let rest = restY, let lastY, let lastInset, inset != lastInset {
            restY = rest + (y - lastY)
        } else if restY == nil {
            restY = y
        }
        lastY = y
        lastInset = inset
        metrics.offset = max(0, (restY ?? y) - y)
    }

    /// macOS 14: the top inset changed in a layout that did not move the
    /// content (no `noteContent` then): later moves are scrolls again.
    func insetSettled(_ inset: CGFloat) {
        lastInset = inset
    }
}

// MARK: - Shelf

/// macOS 14: a shelf's content frame in its own coordinate space.
private struct MacShelfGeometry: Equatable {
    var minX: CGFloat = 0
    var width: CGFloat = 0
}

private struct MacShelfGeometryKey: PreferenceKey {
    static let defaultValue = MacShelfGeometry()
    static func reduce(value: inout MacShelfGeometry, nextValue: () -> MacShelfGeometry) {
        value = nextValue()
    }
}

/// Horizontal shelf aligned on the page inset. Trackpads (and Shift + wheel)
/// scroll it; glass chevrons at its edges, shown while the pointer is over
/// it, page it by a screenful.
struct MacGlassShelf<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let itemWidth: CGFloat
    var spacing: CGFloat = 22
    var verticalPadding: CGFloat = 16
    /// Distance from an item's top to the middle of its image: the chevrons
    /// are centered there.
    let chevronCenter: CGFloat
    /// Item placed first (at the inset) when the shelf appears and whenever
    /// `scrollToken` changes; nil = the first item.
    var anchorID: Item.ID? = nil
    var scrollToken: AnyHashable = 0
    @ViewBuilder let content: (Item) -> Content

    /// The scroll position (every frame, not state) and what the shelf
    /// shows from it (state, written when it changes).
    @State private var tracker = MacScrollTracker()
    @State private var edges = Edges()
    @State private var viewportLength: CGFloat = 0
    @State private var isHovering = false
    @State private var spaceName = UUID()
    /// `scrollToken` the shelf was last anchored for: an onAppear of the
    /// same shelf again keeps the user's place.
    @State private var anchoredToken: AnyHashable?

    /// Whether the shelf can page back / forward (its chevrons).
    private struct Edges: Equatable {
        var back = false
        var forward = false
    }

    private var inset: CGFloat { MacGlassMetrics.sideInset }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(items) { item in
                        content(item)
                            .frame(width: itemWidth, alignment: .topLeading)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, inset)
                .padding(.vertical, verticalPadding)
                // Never narrower than the shelf: an uncovered part of the
                // scroll view draws an opaque background on macOS.
                .frame(minWidth: viewportLength, alignment: .leading)
                .background {
                    GeometryReader { content in
                        Color.clear.preference(key: MacShelfGeometryKey.self,
                                               value: MacShelfGeometry(minX: content.frame(in: .named(spaceName)).minX,
                                                                       width: content.size.width))
                    }
                }
            }
            .coordinateSpace(name: spaceName)
            .macScrollMetrics(.horizontal) { metrics in
                tracker.metrics = metrics
                syncState()
            }
            .onPreferenceChange(MacShelfGeometryKey.self) { geometry in
                // macOS 14 only: 15+ reads the scroll geometry itself.
                if #unavailable(macOS 15.0) {
                    tracker.metrics.offset = -geometry.minX
                    tracker.metrics.contentLength = geometry.width
                    syncState()
                }
            }
            .background {
                GeometryReader { scroll in
                    Color.clear
                        .onAppear {
                            tracker.metrics.viewportLength = scroll.size.width
                            syncState()
                            anchorIfNeeded(proxy)
                        }
                        .onChange(of: scroll.size.width) { _, width in
                            tracker.metrics.viewportLength = width
                            syncState()
                        }
                }
            }
            .overlay(alignment: .topLeading) { chevron(forward: false, proxy: proxy) }
            .overlay(alignment: .topTrailing) { chevron(forward: true, proxy: proxy) }
            .onHover { isHovering = $0 }
            .onChange(of: scrollToken) { _, token in
                anchoredToken = token
                scrollToAnchor(proxy)
            }
        }
    }

    /// The state derived from the scroll position, written only when it
    /// changes: the shelf is not redrawn on every scroll frame.
    private func syncState() {
        let metrics = tracker.metrics
        let now = Edges(back: metrics.offset > 1,
                        forward: metrics.offset + metrics.viewportLength < metrics.contentLength - 1)
        if now != edges { edges = now }
        if metrics.viewportLength != viewportLength { viewportLength = metrics.viewportLength }
    }

    /// `scrollTo` anchor that puts an item's leading edge on the page inset.
    private var leadingAnchor: UnitPoint {
        let room = tracker.metrics.viewportLength - itemWidth
        guard room > 1 else { return .leading }
        return UnitPoint(x: min(max(inset / room, 0), 1), y: 0)
    }

    /// The anchor item, once per `scrollToken`, should onAppear run again
    /// for this same shelf. (Back from a related title is not such a case:
    /// the stack does not call onAppear on the uncovered page — see
    /// `EnvironmentValues.macStackDepth` —, and the shelf, still in place,
    /// keeps its scroll position by itself.)
    private func anchorIfNeeded(_ proxy: ScrollViewProxy) {
        guard anchoredToken != scrollToken else { return }
        anchoredToken = scrollToken
        scrollToAnchor(proxy)
    }

    private func scrollToAnchor(_ proxy: ScrollViewProxy) {
        guard let first = items.first else { return }
        let target = anchorID.flatMap { id in items.first { $0.id == id } } ?? first
        // After this layout pass: the viewport is known by then.
        DispatchQueue.main.async {
            proxy.scrollTo(target.id, anchor: leadingAnchor)
        }
    }

    private func page(forward: Bool, proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        let metrics = tracker.metrics
        let pitch = itemWidth + spacing
        let firstVisible = max(0, Int(((metrics.offset - inset) / pitch).rounded(.up)))
        let perPage = max(1, Int((metrics.viewportLength - 2 * inset + spacing) / pitch))
        let target = forward ? min(items.count - 1, firstVisible + perPage) : max(0, firstVisible - perPage)
        withAnimation(.easeInOut(duration: 0.4)) {
            proxy.scrollTo(items[target].id, anchor: leadingAnchor)
        }
    }

    private func chevron(forward: Bool, proxy: ScrollViewProxy) -> some View {
        let visible = isHovering && (forward ? edges.forward : edges.back)
        return Button {
            page(forward: forward, proxy: proxy)
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 22, height: 22)
        }
        .buttonBorderShape(.circle)
        .glassActionStyle()
        .controlSize(.extraLarge)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, max(0, verticalPadding + chevronCenter - 22))
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        // Hidden: out of the keyboard loop too (Tab with keyboard navigation on).
        .disabled(!visible)
        .animation(.easeOut(duration: 0.15), value: visible)
        // The shelf itself scrolls with VoiceOver; the chevrons are a pointer affordance.
        .accessibilityHidden(true)
    }
}

// MARK: - Text sheet

/// Full text (summary, episode synopsis) on a glass panel over the dimmed
/// page. Esc, Return, OK or a click outside the panel closes it.
struct MacGlassTextSheet: View {
    let text: GlassExpandedText
    let maxHeight: CGFloat
    let onClose: () -> Void

    var body: some View {
        ZStack {
            // Also under the window toolbar, where the page runs too.
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
                .ignoresSafeArea()

            // The panel fits its text when the window is tall enough; a
            // longer text scrolls inside a window-high panel.
            ViewThatFits(in: .vertical) {
                panel(scrolls: false)
                panel(scrolls: true)
                    .frame(maxHeight: maxHeight)
            }
            .padding(40)

            // Esc closes too (a shortcut only: not a Tab stop).
            Button("", action: onClose)
                .keyboardShortcut(.cancelAction)
                .focusable(false)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private func panel(scrolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: text.title)
                .font(.system(size: 26, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = text.subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(MacGlassFont.caption)
                    .foregroundStyle(GlassPalette.secondaryText)
                    .padding(.top, 8)
            }
            Group {
                if scrolls {
                    ScrollView(.vertical) { bodyText }
                } else {
                    bodyText
                }
            }
            .padding(.top, 20)

            HStack {
                Spacer()
                Button(action: onClose) {
                    Text("OK")
                        .font(MacGlassFont.bodyEmphasis)
                        .frame(minWidth: 60)
                }
                .glassActionStyle()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .foregroundStyle(GlassPalette.primaryText)
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .frame(maxWidth: 660, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 28, style: .continuous), fallback: .regularMaterial)
        .shadow(color: .black.opacity(0.45), radius: 40, y: 20)
    }

    private var bodyText: some View {
        Text(verbatim: text.body)
            .font(.system(size: 15))
            .lineSpacing(5)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
