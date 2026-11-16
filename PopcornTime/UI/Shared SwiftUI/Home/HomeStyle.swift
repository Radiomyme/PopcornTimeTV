// HomeStyle.swift — the Home's colours, type scale and small shared pieces
// (iOS and macOS). The colours are the Glass detail pages' (GlassPalette);
// the type follows each platform's detail page: text styles on iOS (they
// follow Dynamic Type), the Mac page's explicit sizes on macOS.
import Foundation
import SwiftUI
import PopcornKit

enum HomePalette {
    /// The page's background: the artwork's gradients end on it exactly.
    static let background = Color.black
    /// A card whose artwork has not arrived.
    static let placeholder = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.10)
}

enum HomeFont {
    /// A shelf's title.
    static func shelfTitle(_ sizeClass: HomeLayout.SizeClass) -> Font {
        #if os(macOS)
        return .system(size: 22, weight: .bold)
        #else
        return sizeClass == .compact ? .title3.weight(.bold) : .title2.weight(.bold)
        #endif
    }

    /// "See All".
    static var shelfAction: Font {
        #if os(macOS)
        return .system(size: 13, weight: .semibold)
        #else
        return .subheadline.weight(.semibold)
        #endif
    }

    /// A card's title.
    static var cardTitle: Font {
        #if os(macOS)
        return .system(size: 13, weight: .semibold)
        #else
        return .subheadline.weight(.semibold)
        #endif
    }

    /// A card's second line.
    static var cardDetail: Font {
        #if os(macOS)
        return .system(size: 11.5, weight: .medium)
        #else
        return .caption.weight(.medium)
        #endif
    }

    /// The hero's title when it has no logo.
    static func heroTitle(_ sizeClass: HomeLayout.SizeClass) -> Font {
        switch sizeClass {
        case .compact: return .system(size: 34, weight: .heavy)
        case .regular: return .system(size: 44, weight: .heavy)
        case .wide: return .system(size: 54, weight: .heavy)
        }
    }

    static var heroFacts: Font {
        #if os(macOS)
        return .system(size: 14, weight: .medium)
        #else
        return .subheadline.weight(.medium)
        #endif
    }

    static var heroSynopsis: Font {
        #if os(macOS)
        return .system(size: 15, weight: .regular)
        #else
        return .callout
        #endif
    }
}

// MARK: - Navigation hooks

/// A card the user picked, and what for.
struct HomeSelection {
    enum Intent {
        /// The title's page.
        case details
        /// Play it: a Continue Watching card resumes, the hero's Play
        /// button starts. Each platform goes through its own play path and
        /// its gates (the page, then what its Play button does).
        case play
    }

    let item: HomeItem
    let shelfID: String
    let intent: Intent

    /// Identifies the card on the page — the same title may sit on several
    /// shelves — for a transition that starts from it (`homeCardSource`).
    var sourceID: String { HomeSelection.sourceID(shelf: shelfID, item: item.id) }

    static func sourceID(shelf: String, item: String) -> String { "home/\(shelf)/\(item)" }
}

private struct HomeZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// iOS: the namespace of the zoom from a card to its page, given by the
    /// navigation stack that hosts the Home. Nil: no such transition (the
    /// Mac pushes its pages).
    var homeZoomNamespace: Namespace.ID? {
        get { self[HomeZoomNamespaceKey.self] }
        set { self[HomeZoomNamespaceKey.self] = newValue }
    }
}

private struct HomeCardSource: ViewModifier {
    let id: String
    @Environment(\.homeZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Marks the artwork a page zooms out of (`HomeSelection.sourceID`).
    func homeCardSource(id: String) -> some View {
        modifier(HomeCardSource(id: id))
    }
}

// MARK: - Library state

private struct HomeLibraryVersionKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Bumped by `HomeScreen` whenever the user's library changes
    /// (`.libraryDidChange`): the views that read the library to draw — a
    /// watchlist tick, a menu — read it too, and so are drawn again.
    var homeLibraryVersion: Int {
        get { self[HomeLibraryVersionKey.self] }
        set { self[HomeLibraryVersionKey.self] = newValue }
    }
}

// MARK: - Keyboard and pointer

private struct HomeControlsKey: EnvironmentKey {
    static let defaultValue: HomeControls? = nil
}

extension EnvironmentValues {
    /// The Home's keyboard cursor and pointer state (the Mac): given by
    /// `HomeScreen` to its carousel, shelves and cards. Nil: no cursor, no
    /// keys (iOS).
    var homeControls: HomeControls? {
        get { self[HomeControlsKey.self] }
        set { self[HomeControlsKey.self] = newValue }
    }
}

/// How a card's artwork is drawn under a pointer, a press or the keyboard
/// (`HomeCardButtonStyle` says, `homeCardLift` draws).
struct HomeCardLift: Equatable {
    var isHovered = false
    var isPressed = false
    /// The keyboard is on the card.
    var isSelected = false
}

private struct HomeCardLiftKey: EnvironmentKey {
    static let defaultValue = HomeCardLift()
}

extension EnvironmentValues {
    var homeCardLift: HomeCardLift {
        get { self[HomeCardLiftKey.self] }
        set { self[HomeCardLiftKey.self] = newValue }
    }
}

// MARK: - Press and hover

/// A card under a finger or a pointer. Short and eased; no motion at all
/// with Reduce Motion beyond the dimming.
///
/// iOS: the card dips when pressed and grows under a pointer (an iPad with
/// a trackpad). macOS: the card's artwork lifts, as the posters of the
/// grids and of a title's page do — a brighter edge, a deeper shadow, a
/// small scale (`homeCardLift`) — under the pointer and under the keyboard
/// (`isSelected`, with a ring); its caption stays where it is.
struct HomeCardButtonStyle: ButtonStyle {
    /// The keyboard is on this card (macOS).
    var isSelected = false
    /// Drawn as under the pointer (verification, macOS).
    var isHoverForced = false
    /// The pointer came over the card, or left it.
    var onHover: (Bool) -> Void = { _ in }

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, isSelected: isSelected, isHoverForced: isHoverForced, onHover: onHover)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let isHoverForced: Bool
        let onHover: (Bool) -> Void
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            #if os(macOS)
            configuration.label
                .environment(\.homeCardLift, HomeCardLift(isHovered: isHovered || isHoverForced,
                                                          isPressed: configuration.isPressed, isSelected: isSelected))
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { inside in
                    isHovered = inside
                    onHover(inside)
                }
                .contentShape(Rectangle())
            #else
            configuration.label
                .opacity(configuration.isPressed ? 0.8 : 1)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : (isHovered ? 1.03 : 1)))
                .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.2), value: isHovered)
                .onHover { isHovered = $0 }
                .contentShape(Rectangle())
            #endif
        }
    }
}

/// The lift of a card's artwork on the Mac (see `HomeCardButtonStyle`).
/// Nothing on iOS, where the whole card answers.
private struct HomeCardLiftEffect: ViewModifier {
    let corner: CGFloat
    #if os(macOS)
    @Environment(\.homeCardLift) private var lift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        let lit = lift.isHovered || lift.isSelected
        content
            .overlay {
                // Outside the artwork, a dark gap then a white ring: it
                // reads on a white or cream poster as on a dark one. The
                // keyboard's card has the stronger ring: it is the one
                // Return and Space act on.
                ZStack {
                    RoundedRectangle(cornerRadius: corner + 2, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.85), lineWidth: 2)
                        .padding(-2)
                    RoundedRectangle(cornerRadius: corner + 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(lift.isSelected ? 1 : 0.7), lineWidth: lift.isSelected ? 3 : 2)
                        .padding(lift.isSelected ? -5 : -4)
                }
                .opacity(lit ? 1 : 0)
                .allowsHitTesting(false)
            }
                        // Grown from low on the artwork: up into the shelf's header
            // space more than down onto the title (`homeCaptionGap`).
            .scaleEffect(reduceMotion ? 1 : (lift.isPressed ? 1.015 : (lit ? 1.03 : 1)), anchor: UnitPoint(x: 0.5, y: 0.8))
            .shadow(color: .black.opacity(lit ? 0.55 : 0), radius: lit ? 18 : 0, y: lit ? 6 : 0)
            .animation(.easeOut(duration: 0.16), value: lit)
            .animation(.easeOut(duration: 0.08), value: lift.isPressed)
        #else
        content
        #endif
    }
}

extension View {
    /// On a card's artwork, with its pills and its progress: what lifts
    /// under a pointer or the keyboard on the Mac.
    func homeCardLift(corner: CGFloat) -> some View {
        modifier(HomeCardLiftEffect(corner: corner))
    }
}

// MARK: - Primary action

/// The one main action of a hero or a title's page on the Mac — Play —
/// solid white with black type, 44 points high, so that it reads first
/// beside the glass buttons whatever the glass (the macOS 14 / 15
/// fallback draws every glass button alike). iOS keeps its prominent
/// glass.
struct HomePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(Color.black)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.78 : (isHovered ? 0.92 : 1))))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
    }
}

extension View {
    /// Play, the main action: solid white on the Mac (`HomePrimaryButtonStyle`),
    /// the prominent glass elsewhere.
    @ViewBuilder
    func homePrimaryActionStyle() -> some View {
        #if os(macOS)
        buttonStyle(HomePrimaryButtonStyle())
        #else
        glassActionStyle(prominent: true)
        #endif
    }
}
