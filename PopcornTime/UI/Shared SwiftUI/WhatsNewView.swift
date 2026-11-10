import SwiftUI
#if os(tvOS)
import UIKit
#endif

/// "What's new in version X": the release notes of `WhatsNewRelease.current`
/// for this platform, as glass cards, with a single Continue button.
///
/// tvOS: full screen, presented by `WhatsNewPresenter` over a blur of the app;
/// the Continue button has the focus and the Menu button does the same as it.
/// iOS / macOS: the content of a sheet (`RootTabView`, `MacRootView`).
struct WhatsNewView: View {
    var release: WhatsNewRelease = .current
    var french: Bool = WhatsNewGate.prefersFrench
    var onContinue: () -> Void

    /// The app accent (AccentColor, dark appearance), without the asset catalog.
    static let accent = Color(red: 0.949, green: 0.290, blue: 0.235)

    @FocusState private var continueFocused: Bool

    private var items: [WhatsNewItem] { release.items(for: .current) }

    private var title: String {
        french ? "Nouveautés de la version \(release.shortVersion)"
               : "What's New in Version \(release.shortVersion)"
    }

    var body: some View {
        #if os(tvOS)
        VStack(spacing: 30) {
            header
            grid
            continueButton
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($continueFocused, true)
        .onExitCommand(perform: onContinue)   // Menu / Back = Continue
        #else
        ScrollView {
            VStack(spacing: 28) {
                header
                grid
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            continueButton
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 560, idealHeight: 680)
        #endif
        #endif
    }

    private var header: some View {
        HStack(spacing: Metrics.headerSpacing) {
            Image(systemName: "sparkles")
                .foregroundStyle(WhatsNewView.accent.gradient)
            Text(title)
        }
        .font(Metrics.titleFont)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var grid: some View {
        #if os(tvOS)
        // Two columns whose cards share their row's height (a LazyVGrid would
        // centre a shorter card next to a taller one).
        Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: Metrics.gridSpacing) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { index in
                GridRow {
                    card(items[index])
                    if index + 1 < items.count {
                        card(items[index + 1])
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
        // Rows at their natural height (the cards would otherwise stretch to
        // fill the screen).
        .fixedSize(horizontal: false, vertical: true)
        #else
        LazyVGrid(columns: Metrics.columns, alignment: .leading, spacing: Metrics.gridSpacing) {
            ForEach(items) { item in
                card(item)
            }
        }
        #endif
    }

    private func card(_ item: WhatsNewItem) -> some View {
        WhatsNewCard(symbol: item.symbol,
                     title: item.title(french: french),
                     text: item.body(french: french))
    }

    private var continueButton: some View {
        SwiftUI.Button(action: onContinue) {
            Text(french ? "Continuer" : "Continue")
                .font(Metrics.buttonFont)
                .frame(minWidth: Metrics.buttonMinWidth)
        }
        .modifier(WhatsNewProminentButton())
        .focused($continueFocused)
        #if !os(tvOS)
        .keyboardShortcut(.defaultAction)
        #endif
    }

    fileprivate enum Metrics {
        #if os(tvOS)
        static let gridSpacing: CGFloat = 22
        static let titleFont = Font.system(size: 60, weight: .bold)
        static let headerSpacing: CGFloat = 22
        static let buttonFont = Font.system(size: 31, weight: .semibold)
        static let buttonMinWidth: CGFloat = 340
        static let cardTitleFont = Font.system(size: 31, weight: .semibold)
        static let cardTextFont = Font.system(size: 24)
        static let symbolFont = Font.system(size: 34, weight: .semibold)
        static let symbolSize: CGFloat = 74
        static let cardPadding: CGFloat = 24
        static let cardSpacing: CGFloat = 26
        static let cardRadius: CGFloat = 34
        static let cardMinHeight: CGFloat = 140
        /// Cards stretch to the height of their grid row.
        static let cardMaxHeight: CGFloat = .infinity
        #else
        static let columns = [GridItem(.adaptive(minimum: 300), spacing: 16)]
        static let gridSpacing: CGFloat = 16
        static let titleFont = Font.largeTitle.bold()
        static let headerSpacing: CGFloat = 10
        static let buttonFont = Font.headline
        static let buttonMinWidth: CGFloat = 220
        static let cardTitleFont = Font.headline
        static let cardTextFont = Font.callout
        static let symbolFont = Font.title3.weight(.semibold)
        static let symbolSize: CGFloat = 44
        static let cardPadding: CGFloat = 16
        static let cardSpacing: CGFloat = 14
        static let cardRadius: CGFloat = 22
        static let cardMinHeight: CGFloat = 0
        static let cardMaxHeight: CGFloat? = nil
        #endif
    }
}

/// One release-notes item: symbol badge, title, one sentence.
private struct WhatsNewCard: View {
    let symbol: String
    let title: String
    let text: String

    private typealias Metrics = WhatsNewView.Metrics

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.cardSpacing) {
            Image(systemName: symbol)
                .font(Metrics.symbolFont)
                .foregroundStyle(.white)
                .frame(width: Metrics.symbolSize, height: Metrics.symbolSize)
                .background(WhatsNewView.accent.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(Metrics.cardTitleFont)
                    .foregroundStyle(.primary)
                Text(text)
                    .font(Metrics.cardTextFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: Metrics.cardMinHeight, maxHeight: Metrics.cardMaxHeight, alignment: .topLeading)
        .modifier(WhatsNewGlassCard(cornerRadius: Metrics.cardRadius))
    }
}

/// Regular Liquid Glass on OS 26+, a thin material before.
private struct WhatsNewGlassCard: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}

/// `.glassProminent` on OS 26+, `.borderedProminent` before; both get the
/// system focus effect on tvOS.
private struct WhatsNewProminentButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
            content.buttonStyle(.glassProminent).tint(WhatsNewView.accent)
        } else {
            content.buttonStyle(.borderedProminent).tint(WhatsNewView.accent)
        }
    }
}

#if os(tvOS)
/// Presents `WhatsNewView` full screen over a blur of the app (tvOS).
@MainActor
enum WhatsNewPresenter {
    private static weak var presented: UIViewController?

    /// Launch hook (SceneDelegate, right after the Terms of Service gate):
    /// presents the notes once per version, never on a fresh install (the
    /// Terms of Service are the first screen then) and never when the app was
    /// launched to open a URL.
    static func presentAtLaunchIfNeeded(from presenter: UIViewController,
                                        isFreshInstall: Bool,
                                        launchedFromURL: Bool) {
        guard WhatsNewGate.checkAtLaunch(isFreshInstall: isFreshInstall,
                                         launchedFromURL: launchedFromURL) else { return }
        // Deferred like the Terms of Service: the window must be on screen.
        Task { @MainActor in present(from: presenter) }
    }

    /// Shows the notes (also used by Settings > Version).
    static func present(from presenter: UIViewController) {
        guard presented == nil, presenter.presentedViewController == nil else { return }
        let host = UIHostingController(rootView: WhatsNewView(onContinue: { dismiss(animated: true) }))
        host.modalPresentationStyle = .blurOverFullScreen
        host.view.backgroundColor = .clear
        presented = host
        presenter.present(host, animated: true)
    }

    /// Removes the notes, e.g. before a Top Shelf URL starts playback (the
    /// player is presented from the root view controller, which must not be
    /// presenting anything then).
    static func dismiss(animated: Bool) {
        guard let host = presented else { return }
        presented = nil
        host.presentingViewController?.dismiss(animated: animated)
    }
}
#endif
