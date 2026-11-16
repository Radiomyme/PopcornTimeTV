// GlassRemoteImage.swift — the remote image of the SwiftUI screens (tvOS, iOS
// and macOS): a placeholder, the picture decoded at the size it is drawn,
// a fade-in. The loading itself is PopcornKit's artwork pipeline
// (ArtworkPipeline): the size downloaded is chosen from the size the view is
// laid out at, an address that fails falls back to the address as given and
// then to another picture of the title, and a picture held in memory is
// never decoded again (file:// URLs work too).
//
// URLs are passed as the PopcornKit models expose them, which ImageProxy has
// already rewritten (yts.* hosts go through images.weserv.nl).
import Foundation
import SwiftUI
import ImageIO
import CoreImage
import PopcornKit
#if canImport(UIKit)
import UIKit
/// GlassPlatformImage on tvOS, NSImage on macOS.
typealias GlassPlatformImage = UIImage
#else
import AppKit
typealias GlassPlatformImage = NSImage
#endif

extension GlassPlatformImage {
    /// The image as a CGImage (nil for images without bitmap data).
    var glassCGImage: CGImage? {
        #if canImport(UIKit)
        return cgImage
        #else
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// Wraps a decoded bitmap (1 point = 1 pixel, as UIImage(cgImage:) does).
    static func glassImage(_ cgImage: CGImage) -> GlassPlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    /// Decoded size in bytes, the NSCache cost.
    var glassPixelCost: Int {
        if let cg = glassCGImage { return cg.bytesPerRow * cg.height }
        return Int(size.width * size.height * 4)
    }
}

extension Image {
    init(glassImage: GlassPlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: glassImage)
        #else
        self.init(nsImage: glassImage)
        #endif
    }
}

/// The pictures of the SwiftUI screens: PopcornKit's artwork pipeline, with
/// its CGImages wrapped for SwiftUI, and the blurred copies made here.
final class GlassImageCache: @unchecked Sendable {
    static let shared = GlassImageCache()

    private let pipeline: ArtworkPipeline
    /// Blurred copies, by address and radius (small: 360 px at most).
    private let blurs = NSCache<NSString, GlassPlatformImage>()
    private let lock = NSLock()
    private var blurring: [String: Task<GlassPlatformImage?, Never>] = [:]

    init(pipeline: ArtworkPipeline = .shared) {
        self.pipeline = pipeline
        blurs.totalCostLimit = 24 * 1024 * 1024   // decoded bytes
    }

    /// The picture in memory for `url`, when it is large enough for
    /// `maxPixelSize` (no I/O).
    func cachedImage(for url: URL, maxPixelSize: CGFloat?) -> GlassPlatformImage? {
        guard let hit = cached(for: url, need: ArtworkNeed(longestSide: maxPixelSize)), hit.isEnough else { return nil }
        return hit.image
    }

    /// The picture in memory for `url` whatever its size, and whether it is
    /// enough for `need`: a smaller one is worth showing while the right
    /// one loads (no I/O).
    func cached(for url: URL, need: ArtworkNeed) -> (image: GlassPlatformImage, isEnough: Bool)? {
        pipeline.cached(url, need: need).map { (.glassImage($0.image.cgImage), $0.isEnough) }
    }

    /// Loads, downsamples (longest side ≤ maxPixelSize, in pixels) and caches.
    func image(for url: URL, maxPixelSize: CGFloat?) async -> GlassPlatformImage? {
        await image(for: url, need: ArtworkNeed(longestSide: maxPixelSize))
    }

    /// The picture of `url` for `need` (see ArtworkPipeline.image).
    func image(for url: URL, need: ArtworkNeed, alternates: [URL] = []) async -> GlassPlatformImage? {
        await pipeline.image(for: url, need: need, alternates: alternates).map { .glassImage($0.cgImage) }
    }

    /// A small, heavily blurred and slightly darkened copy of the image at
    /// `url`, for ambient backgrounds (computed once on a background thread,
    /// so nothing is blurred live while focus moves).
    /// Pass `source` when the image is already decoded (no second download).
    func blurredImage(for url: URL, from source: GlassPlatformImage? = nil, radius: CGFloat = 26) async -> GlassPlatformImage? {
        await blurred("blur\(Int(radius))|\(url.absoluteString)") { [weak self] in
            var small: GlassPlatformImage?
            if let source {
                let scale = min(1, 360 / max(source.size.width, source.size.height, 1))
                let target = CGSize(width: source.size.width * scale, height: source.size.height * scale)
                #if canImport(UIKit)
                small = source.preparingThumbnail(of: target) ?? source
                #else
                small = GlassImageCache.scaled(source, to: target) ?? source
                #endif
            } else {
                small = await self?.image(for: url, maxPixelSize: 360)
            }
            guard let small else { return nil }
            return GlassImageCache.blur(small, radius: radius)
        }
    }

    /// One blur per key at a time: the callers that ask meanwhile share it.
    private func blurred(_ key: String, _ work: @escaping @Sendable () async -> GlassPlatformImage?) async -> GlassPlatformImage? {
        if let hit = blurs.object(forKey: key as NSString) { return hit }
        let task: Task<GlassPlatformImage?, Never> = lock.withLock {
            if let running = blurring[key] { return running }
            let started = Task.detached(priority: .userInitiated) { await work() }
            blurring[key] = started
            return started
        }
        let image = await task.value
        lock.withLock { blurring[key] = nil }
        if let image {
            blurs.setObject(image, forKey: key as NSString, cost: image.glassPixelCost)
        }
        return image
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    #if !canImport(UIKit)
    /// macOS stand-in for UIImage.preparingThumbnail(of:).
    fileprivate static func scaled(_ image: GlassPlatformImage, to size: CGSize) -> GlassPlatformImage? {
        guard let cg = image.glassCGImage, size.width >= 1, size.height >= 1,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(origin: .zero, size: size))
        return context.makeImage().map(GlassPlatformImage.glassImage)
    }
    #endif

    private static func blur(_ image: GlassPlatformImage, radius: CGFloat) -> GlassPlatformImage? {
        guard let cg = image.glassCGImage else { return nil }
        let input = CIImage(cgImage: cg)
        let output = input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35,
                                                            kCIInputBrightnessKey: -0.06])
            .cropped(to: input.extent)
        guard let result = ciContext.createCGImage(output, from: input.extent) else { return nil }
        return .glassImage(result)
    }
}

/// Remote image with a placeholder and a fade-in. `maxPixelSize` is the
/// longest side to decode, in pixels (≈ 1× the drawn size on Apple TV, 2× on
/// a Retina Mac); what is downloaded is chosen from the size the view is
/// laid out at, never more than `maxPixelSize` allows.
struct GlassRemoteImage<Placeholder: View>: View {
    let url: URL?
    /// Other addresses of the same artwork, tried when `url` fails or does
    /// not answer (an episode's still, then its show's backdrop).
    var alternates: [URL] = []
    var maxPixelSize: CGFloat?
    var contentMode: ContentMode = .fill
    /// Where the image sits when its aspect ratio leaves room (contentMode .fit).
    var alignment: Alignment = .center
    /// Called with the decoded image (e.g. to read its aspect ratio).
    var onLoad: ((GlassPlatformImage) -> Void)? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: GlassPlatformImage?
    @State private var loadedURL: URL?
    @Environment(\.displayScale) private var displayScale

    init(url: URL?, alternates: [URL] = [], maxPixelSize: CGFloat? = nil, contentMode: ContentMode = .fill,
         alignment: Alignment = .center,
         onLoad: ((GlassPlatformImage) -> Void)? = nil,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.alternates = alternates
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.alignment = alignment
        self.onLoad = onLoad
        self.placeholder = placeholder
        // Synchronous cache hit: no placeholder flash when cells are
        // recycled. A picture decoded smaller than asked (a grid's poster
        // on the page it opens) is shown too, until the larger one is there.
        let hit = url.flatMap { GlassImageCache.shared.cached(for: $0, need: ArtworkNeed(longestSide: maxPixelSize)) }
        _image = State(initialValue: hit?.image)
        _loadedURL = State(initialValue: hit == nil ? nil : url)
    }

    var body: some View {
        ZStack(alignment: alignment) {
            if image == nil || loadedURL != url {
                placeholder()
            }
            if let image, loadedURL == url {
                Image(glassImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        // Behind the view, where it changes nothing of the layout: the size
        // the picture is laid out at, which chooses the variant to download.
        // The load starts again only when that variant changes (a window
        // resized by a few points keeps its pictures).
        .background {
            GeometryReader { proxy in
                let need = need(in: proxy.size)
                Color.clear
                    .task(id: Load(url: url, variant: variant(for: need), side: need.longestSide, alternates: alternates)) {
                        await load(need)
                    }
            }
            .accessibilityHidden(true)
        }
    }

    /// What identifies a load: the address, and the variant and decoded
    /// size its layout asks for.
    private struct Load: Equatable {
        let url: URL?
        let variant: URL?
        let side: CGFloat?
        let alternates: [URL]
    }

    private func variant(for need: ArtworkNeed) -> URL? {
        guard let url else { return nil }
        return need.networkWidth(for: url).map { ArtworkURL.sized(url, pixelWidth: $0) } ?? url
    }

    /// The size to load for a view laid out at `size` (points). A picture
    /// that fills its frame must cover it, one that fits is at most as wide;
    /// when the address says what it shows (a 2:3 poster in a 16:9 frame…),
    /// the frame's other side counts too.
    private func need(in size: CGSize) -> ArtworkNeed {
        // Not laid out yet, or sized by its own content: a fitted picture
        // that is not there yet has the size of its placeholder, which says
        // nothing of the picture's. `maxPixelSize` alone decides then.
        let isShown = image != nil && loadedURL == url
        guard let url, size.width >= 1, size.height >= 1,
              contentMode == .fill || isShown || maxPixelSize == nil else {
            return ArtworkNeed(longestSide: maxPixelSize)
        }
        let scale = max(displayScale, 1)
        var width = size.width
        var ratio = ArtworkURL.kind(of: url).aspectRatio
        if ratio == nil, contentMode == .fill {
            // The address does not say what it shows (a TVMaze original, a
            // TMDB file): a picture that fills an upright frame may be a 3:4
            // poster, wider than the frame; one that fills a landscape frame
            // may be 16:9. Guessed too narrow, the picture would be loaded a
            // second time once its own ratio is known.
            ratio = size.height > size.width ? 0.75 : 16.0 / 9.0
        }
        if let ratio {
            let other = size.height * ratio
            width = contentMode == .fill ? max(width, other) : min(width, other)
        }
        // No decode size given: twice the frame's longest side covers it
        // whatever the picture's ratio, and still cuts a huge original down.
        let side = maxPixelSize ?? (max(size.width, size.height) * scale * 2).rounded(.up)
        return ArtworkNeed(longestSide: side, pixelWidth: (width * scale).rounded(.up))
    }

    @MainActor
    private func load(_ need: ArtworkNeed) async {
        guard let url else { image = nil; loadedURL = nil; return }
        let cache = GlassImageCache.shared
        let showsURL = loadedURL == url && image != nil
        if let hit = cache.cached(for: url, need: need), hit.isEnough {
            // In memory at the right size (shown since init, or decoded
            // meanwhile for another view): nothing to load.
            if !showsURL || hit.image.size != image?.size { show(hit.image, for: url, fades: !showsURL) }
            onLoad?(hit.image)
            return
        }
        guard let loaded = await cache.image(for: url, need: need, alternates: alternates), !Task.isCancelled else { return }
        // A sharper copy of the picture already shown replaces it without a fade.
        show(loaded, for: url, fades: !(loadedURL == url && image != nil))
        onLoad?(loaded)
    }

    @MainActor
    private func show(_ picture: GlassPlatformImage, for url: URL, fades: Bool) {
        if fades {
            withAnimation(.easeOut(duration: 0.3)) {
                image = picture
                loadedURL = url
            }
        } else {
            image = picture
            loadedURL = url
        }
    }
}

extension GlassRemoteImage where Placeholder == Color {
    init(url: URL?, alternates: [URL] = [], maxPixelSize: CGFloat? = nil, contentMode: ContentMode = .fill,
         onLoad: ((GlassPlatformImage) -> Void)? = nil) {
        self.init(url: url, alternates: alternates, maxPixelSize: maxPixelSize, contentMode: contentMode, onLoad: onLoad) {
            Color.white.opacity(0.08)
        }
    }
}
