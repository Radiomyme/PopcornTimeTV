import SwiftUI
import PopcornKit

/// The « next episode » card of the iPhone / iPad and Mac players (episode
/// chaining, 5.3.0): the episode's image, « S1 · E3 — Title », the version
/// line ("1080p HEVC · same pack"), « Play Now » with the countdown's ring,
/// « Cancel », and a « … » menu with « Choose Version ». The same card says
/// « Episode finished » after a file whose length was not known, and asks
/// « Still watching? » after episodes chained with no action.
///
/// It shows `UpNextSession.card` and calls the session back. The player
/// places it (iOS: over `PlaybackScreen`, bottom trailing, inside the safe
/// area, above AVKit's controls; Mac: over the player). Mac: Return plays
/// now, Escape cancels the card (the player's own Escape closes it only
/// when no card is up).
///
/// ```swift
/// if let card = session.card {
///     UpNextCardView(card: card, playNow: session.accept, cancel: session.cancel,
///                    chooseVersion: session.chooseVersion)
///         .padding()
/// }
/// ```
struct UpNextCardView: View {
    let card: UpNextCardState
    let playNow: () -> Void
    let cancel: () -> Void
    let chooseVersion: () -> Void

    #if os(macOS)
    private let width: CGFloat = 400
    private let imageWidth: CGFloat = 132
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var width: CGFloat { sizeClass == .compact ? 340 : 420 }
    private var imageWidth: CGFloat { sizeClass == .compact ? 112 : 140 }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if card.kind != .stillWatching {
                    artwork
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.headline)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    if let show = card.showTitle, card.kind != .stillWatching {
                        Text(show)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(card.kind == .stillWatching ? (card.message ?? card.title) : card.title)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line = card.versionLine, card.kind != .stillWatching {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if card.kind != .stillWatching {
                    moreMenu
                }
            }
            HStack(spacing: 10) {
                Button(action: playNow) {
                    HStack(spacing: 8) {
                        ring
                        Text(card.playNowTitle)
                            .lineLimit(1)
                            // « Lire maintenant » whole on an iPhone in
                            // portrait (it was cut to « Lire main… »).
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                #if os(macOS)
                .keyboardShortcut(.defaultAction)
                #endif
                .accessibilityHint(card.countdownText ?? "")

                Button(role: .cancel, action: cancel) {
                    // Its own width: « Play Now » takes the rest.
                    Text(card.cancelTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                #if os(macOS)
                .keyboardShortcut(.cancelAction)
                #endif
            }
            if let countdown = card.countdownText {
                Text(countdown)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityIdentifier("UpNextCard")
    }

    private var artwork: some View {
        AsyncImage(url: card.imageURL) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.white.opacity(0.08))
                    .overlay(Image(systemName: "play.rectangle").foregroundStyle(.secondary))
            }
        }
        .frame(width: imageWidth, height: imageWidth * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    /// « … »: « Choose Version ».
    private var moreMenu: some View {
        Menu {
            Button(action: chooseVersion) {
                Label(card.chooseVersionTitle, systemImage: "list.bullet")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityLabel(card.chooseVersionTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("UpNextCard.More")
    }

    /// The countdown's ring (nothing without a countdown).
    @ViewBuilder private var ring: some View {
        if let progress = card.progress {
            ZStack {
                Circle().stroke(.white.opacity(0.3), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
        } else {
            Image(systemName: "play.fill")
        }
    }
}
