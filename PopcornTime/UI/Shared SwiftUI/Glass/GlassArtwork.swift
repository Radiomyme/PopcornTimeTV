// GlassArtwork.swift — the full-bleed artwork behind the glass detail pages
// (tvOS and macOS): what to draw (a landscape backdrop, or a blurred poster as
// ambient light) and the backdrop view with its legibility scrims.
import SwiftUI

/// What fills the background.
enum GlassArtwork: Equatable {
    case loading
    /// A real landscape backdrop (plus a blurred copy for the lower sections).
    case landscape(image: GlassPlatformImage, blurred: GlassPlatformImage?)
    /// Only a poster: blurred, scaled up as ambient light; the crisp poster
    /// goes in the hero card.
    case ambient(blurred: GlassPlatformImage, posterURL: URL)
    /// Nothing usable: a dark accent gradient.
    case none

    var posterCardURL: URL? {
        if case .ambient(_, let url) = self { return url }
        return nil
    }

    var isLandscape: Bool {
        if case .landscape = self { return true }
        return false
    }
}

extension GlassArtwork {
    /// The backdrop when it loads (a landscape one fills the screen, a
    /// portrait one becomes ambient light), else `fallbackBackdrop` when that
    /// one is landscape, else the poster as ambient light, else `.none`.
    /// `maxPixelSize` is the longest side decoded.
    static func load(backdrop: URL?, fallbackBackdrop: URL? = nil, poster: URL?,
                     maxPixelSize: CGFloat = 1920) async -> GlassArtwork {
        let first = await loadSingle(backdrop: backdrop, poster: poster, maxPixelSize: maxPixelSize)
        if !first.isLandscape, let fallbackBackdrop, fallbackBackdrop != backdrop {
            let second = await loadSingle(backdrop: fallbackBackdrop, poster: nil, maxPixelSize: maxPixelSize)
            if second.isLandscape { return second }
        }
        return first
    }

    private static func loadSingle(backdrop: URL?, poster: URL?, maxPixelSize: CGFloat) async -> GlassArtwork {
        let cache = GlassImageCache.shared
        if let url = backdrop,
           let image = await cache.image(for: url, maxPixelSize: maxPixelSize) {
            let blurred = await cache.blurredImage(for: url, from: image)
            let landscape = image.size.width >= image.size.height * 1.3
            return landscape
                ? .landscape(image: image, blurred: blurred)
                : .ambient(blurred: blurred ?? image, posterURL: poster ?? url)
        }
        if let url = poster, let blurred = await cache.blurredImage(for: url) {
            return .ambient(blurred: blurred, posterURL: url)
        }
        return .none
    }
}

/// Full-bleed artwork + legibility scrims. `dimmed` (focus below the hero)
/// cross-fades to the blurred copy and darkens it.
struct GlassBackdropView: View {
    let artwork: GlassArtwork
    let dimmed: Bool
    let size: CGSize

    var body: some View {
        ZStack {
            Color.black
            switch artwork {
            case .loading:
                EmptyView()
            case .landscape(let image, let blurred):
                fill(image)
                if let blurred {
                    fill(blurred)
                        .opacity(dimmed ? 1 : 0)
                }
            case .ambient(let blurred, _):
                fill(blurred)
                    .scaleEffect(1.25)
                    .opacity(0.9)
            case .none:
                LinearGradient(colors: [GlassPalette.accent.opacity(0.35), Color.black],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
            }
            // First screen: directional scrims behind the hero text. Lower
            // sections: an even dim over the blurred art, so the glass cards
            // still pick up its colors.
            scrims
                .opacity(dimmed ? 0.3 : 1)
            Color.black.opacity(dimmed ? 0.42 : 0)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(.easeInOut(duration: 0.45), value: dimmed)
        .accessibilityHidden(true)
    }

    private func fill(_ image: GlassPlatformImage) -> some View {
        Image(glassImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    /// Leading + bottom darkening so white text stays legible on bright art.
    private var scrims: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .black.opacity(0.78), location: 0),
                                   .init(color: .black.opacity(0.45), location: 0.38),
                                   .init(color: .black.opacity(0.0), location: 0.72)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .black.opacity(0.0), location: 0.25),
                                   .init(color: .black.opacity(0.55), location: 0.62),
                                   .init(color: .black.opacity(0.88), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}
