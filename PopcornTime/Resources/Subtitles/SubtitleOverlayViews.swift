

import SwiftUI
import Combine
import PopcornKit
#if canImport(UIKit)
import UIKit
#endif

// CONTRACT FILE — owned by agent C2. Shared by the tvOS, iOS and macOS apps.

/// SwiftUI overlay drawing `controller.currentText` bottom-centred with an
/// outline/shadow (iOS AVPlayerViewController wrapper, macOS AVPlayerView).
/// Place it over the player with the same frame; it never takes touches.
struct SubtitleOverlayText: View {
    @ObservedObject var controller: SubtitleCueController
    /// Font size as a fraction of the container (shorter side → height in landscape).
    var fontScale: CGFloat = 0.045
    /// Distance from the bottom edge as a fraction of the container height.
    var bottomPadding: CGFloat = 0.06

    var body: some View {
        GeometryReader { geometry in
            let reference = min(geometry.size.width, geometry.size.height)
            let fontSize = max(14, reference * fontScale)
            VStack {
                Spacer(minLength: 0)
                if let text = controller.currentText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        // Stacked tight shadows read as an outline on bright
                        // frames; the soft one lifts the text off the picture.
                        .shadow(color: .black.opacity(0.9), radius: 0, x: 1, y: 1)
                        .shadow(color: .black.opacity(0.9), radius: 0, x: -1, y: -1)
                        .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 0)
                        .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)
                        .padding(.horizontal, geometry.size.width * 0.06)
                        .padding(.bottom, geometry.size.height * bottomPadding)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// SwiftUI menu button listing "Désactivés" + every available subtitle.
/// Works on iOS and macOS (checkmark on the selected entry); also offers a
/// ±0.5 s sync adjustment once a subtitle is on. « Désactivés » and the
/// unfilled icon mean no subtitle is on — neither the overlay nor one of the
/// file's own non-forced subtitles (`areSubtitlesOff`; its forced-only ones
/// may still show); picking it turns both off.
struct SubtitleMenuButton: View {
    @ObservedObject var controller: SubtitleCueController

    var body: some View {
        Menu {
            Toggle("Désactivés", isOn: offBinding)
            if controller.available.isEmpty {
                Text(controller.isSearching ? "Recherche des sous-titres…" : "Aucun sous-titre trouvé")
            } else {
                Section("OpenSubtitles") {
                    ForEach(controller.available, id: \.link) { subtitle in
                        Toggle(ExternalSubtitleLoader.menuTitle(for: subtitle), isOn: selectionBinding(for: subtitle))
                    }
                }
            }
            if controller.selected != nil {
                // `SwiftUI.` qualified: the tvOS module declares a global
                // `typealias Button = TVButton` (ItemViewController.swift).
                Section("Synchronisation") {
                    SwiftUI.Button("Afficher plus tôt (−0,5 s)") { controller.offset -= 0.5 }
                    SwiftUI.Button("Afficher plus tard (+0,5 s)") { controller.offset += 0.5 }
                    if controller.offset != 0 {
                        SwiftUI.Button("Réinitialiser (\(SubtitleMenuFormatting.offsetLabel(controller.offset)))") {
                            controller.offset = 0
                        }
                    }
                }
            }
        } label: {
            Image(systemName: controller.areSubtitlesOff ? "captions.bubble" : "captions.bubble.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .padding(10)
                .background(Circle().fill(Color.black.opacity(0.35)))
                .contentShape(Circle())
                .accessibilityLabel("Sous-titres")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Checkmark binding: on when `subtitle` is the selection (nil = off).
    /// Turning an entry off by re-clicking it is ignored (radio behaviour).
    private func selectionBinding(for subtitle: Subtitle?) -> Binding<Bool> {
        Binding(
            get: { controller.selected == subtitle },
            set: { isOn in if isOn { controller.select(subtitle) } }
        )
    }

    /// « Désactivés »: checked only when neither the overlay nor one of the
    /// file's own non-forced subtitles is shown (`areSubtitlesOff`); picking
    /// it turns both off. The file's forced-only subtitles for the language
    /// being heard stay on and don't count. Picking it while it is already
    /// checked (the Toggle then sets false) applies it again, as the tvOS
    /// menu does: those forced subtitles come back if they were turned off
    /// meanwhile (e.g. with the off entry of AVKit's own menu).
    private var offBinding: Binding<Bool> {
        Binding(
            get: { controller.areSubtitlesOff },
            set: { _ in controller.select(nil) }
        )
    }
}

enum SubtitleMenuFormatting {
    /// "+0,5 s" / "−1 s" (French decimal comma).
    static func offsetLabel(_ offset: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        let number = formatter.string(from: NSNumber(value: abs(offset))) ?? "\(abs(offset))"
        return (offset < 0 ? "−" : "+") + number + " s"
    }
}

#if canImport(UIKit)
/// UIKit overlay for AVPlayerViewController.contentOverlayView (tvOS and
/// the iOS remux / native controllers): a non-interactive label bound to
/// the controller. Pin it to the container's edges; it lays the text out.
final class SubtitleOverlayLabelView: UIView {
    private let label = UILabel()
    private var text: String?
    private var appliedFontSize: CGFloat = 0
    private var cancellable: AnyCancellable?

    init(controller: SubtitleCueController) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        label.numberOfLines = 0
        label.textAlignment = .center
        label.lineBreakMode = .byWordWrapping
        label.backgroundColor = .clear
        // Soft drop shadow on the LAYER, i.e. behind the composited text. An
        // NSShadow attribute would also shadow the stroke, which CoreText
        // draws after the fill — that shadow lands on the white glyphs and
        // muddies them (seen in rendered snapshots).
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.85
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.layer.shadowRadius = 2
        addSubview(label)
        text = controller.currentText
        // @Published emits in willSet: use the emitted value, not the property.
        cancellable = controller.$currentText
            .removeDuplicates()
            .sink { [weak self] newText in
                self?.text = newText
                self?.updateAttributedText()
                self?.setNeedsLayout()
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Point size for the current bounds: ~4.5 % of the shorter side
    /// (= the height in landscape), larger on tvOS (10-foot viewing).
    private var fontSize: CGFloat {
        let reference = min(bounds.width, bounds.height)
#if os(tvOS)
        return max(30, reference * 0.052)
#else
        return max(14, reference * 0.045)
#endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = fontSize
        if abs(size - appliedFontSize) > 0.5 {
            appliedFontSize = size
            updateAttributedText()
        }
        guard label.attributedText != nil, bounds.width > 0, bounds.height > 0 else {
            label.frame = .zero
            return
        }
        let maxWidth = bounds.width * 0.88
        let fitted = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let width = min(maxWidth, ceil(fitted.width))
        let height = ceil(fitted.height)
        let bottomInset = bounds.height * 0.06
        label.frame = CGRect(x: ((bounds.width - width) / 2).rounded(),
                             y: (bounds.height - bottomInset - height).rounded(),
                             width: width, height: height)
    }

    private func updateAttributedText() {
        guard let text, !text.isEmpty, appliedFontSize > 0 else {
            label.attributedText = nil
            label.isHidden = true
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: appliedFontSize, weight: .semibold),
            .foregroundColor: UIColor.white,
            // Negative width = stroke AND fill: white glyphs, black outline
            // (% of the point size).
            .strokeColor: UIColor.black,
            .strokeWidth: -3.0,
            .paragraphStyle: paragraph,
        ])
        label.layer.shadowRadius = max(1.5, appliedFontSize * 0.06)
        label.isHidden = false
    }
}

/// Builds a "Sous-titres" UIMenu (Désactivés + languages, current one
/// checked) for tvOS `AVPlayerViewController.transportBarCustomMenuItems`.
/// « Désactivés » and the unfilled icon mean no subtitle is on: neither the
/// overlay nor one of the file's own non-forced subtitles (`areSubtitlesOff`;
/// its forced-only ones may still show).
@MainActor
func makeSubtitleMenu(controller: SubtitleCueController) -> UIMenu {
    return makeSubtitleMenu(controller: controller,
                            available: controller.available,
                            selected: controller.selected,
                            offset: controller.offset,
                            isSearching: controller.isSearching,
                            isNativeSubtitleShown: controller.isNativeSubtitleShown)
}

/// Same menu from explicit values (the binder receives them from @Published
/// before the properties themselves are updated).
@MainActor
private func makeSubtitleMenu(controller: SubtitleCueController,
                              available: [Subtitle],
                              selected: Subtitle?,
                              offset: Double,
                              isSearching: Bool,
                              isNativeSubtitleShown: Bool) -> UIMenu {
    let subtitlesOff = selected == nil && !isNativeSubtitleShown
    var children: [UIMenuElement] = []
    children.append(UIAction(title: "Désactivés", state: subtitlesOff ? .on : .off) { [weak controller] _ in
        controller?.select(nil)   // also the file's own non-forced subtitle
    })
    if available.isEmpty {
        children.append(UIAction(title: isSearching ? "Recherche des sous-titres…" : "Aucun sous-titre trouvé",
                                 attributes: .disabled) { _ in })
    }
    for subtitle in available {
        children.append(UIAction(title: ExternalSubtitleLoader.menuTitle(for: subtitle),
                                 state: selected == subtitle ? .on : .off) { [weak controller] _ in
            controller?.select(subtitle)
        })
    }
    if selected != nil {
        var sync: [UIMenuElement] = [
            UIAction(title: "Afficher plus tôt (−0,5 s)") { [weak controller] _ in controller?.offset -= 0.5 },
            UIAction(title: "Afficher plus tard (+0,5 s)") { [weak controller] _ in controller?.offset += 0.5 },
        ]
        if offset != 0 {
            sync.append(UIAction(title: "Réinitialiser (\(SubtitleMenuFormatting.offsetLabel(offset)))") { [weak controller] _ in
                controller?.offset = 0
            })
        }
        children.append(UIMenu(title: "Synchronisation", image: UIImage(systemName: "timer"), children: sync))
    }
    let icon = subtitlesOff ? "captions.bubble" : "captions.bubble.fill"
    return UIMenu(title: "Sous-titres", image: UIImage(systemName: icon), children: children)
}

/// Keeps a transport-bar menu in sync: calls `apply` with a freshly built
/// menu now and every time `available`, `selected` (or the file's own
/// subtitle state, the sync offset, the search) changes (menus are
/// immutable snapshots). Hold a strong reference for the player's lifetime.
/// `apply` is retained: capture the player controller weakly in it.
@MainActor
final class SubtitleMenuBinder {
    private var cancellable: AnyCancellable?

    private struct MenuState: Equatable {
        var available: [Subtitle]
        var selected: Subtitle?
        var offset: Double
        var isSearching: Bool
        var isNativeSubtitleShown: Bool
    }

    init(controller: SubtitleCueController, apply: @escaping (UIMenu) -> Void) {
        apply(makeSubtitleMenu(controller: controller))
        // @Published emits in willSet, so build from the emitted values.
        cancellable = controller.$available
            .combineLatest(controller.$selected, controller.$offset, controller.$isSearching)
            .combineLatest(controller.$isNativeSubtitleShown)
            .map { values, isNativeSubtitleShown -> MenuState in
                MenuState(available: values.0, selected: values.1, offset: values.2,
                          isSearching: values.3, isNativeSubtitleShown: isNativeSubtitleShown)
            }
            .dropFirst()
            .removeDuplicates()
            .sink { [weak controller] state in
                guard let controller else { return }
                apply(makeSubtitleMenu(controller: controller, available: state.available, selected: state.selected,
                                       offset: state.offset, isSearching: state.isSearching,
                                       isNativeSubtitleShown: state.isNativeSubtitleShown))
            }
    }
}
#endif
