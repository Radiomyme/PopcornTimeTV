// GlassRemoteImage.swift — small remote image loader for the glass detail pages
// (tvOS and macOS): in-memory cache, downsampling to the size actually drawn,
// placeholder and fade-in. No AlamofireImage dependency, so the views also
// build on their own (file:// URLs work too).
//
// URLs are loaded as given: pass the ones the PopcornKit models expose, which
// ImageProxy has already rewritten (yts.* hosts go through images.weserv.nl).
import SwiftUI
import ImageIO
import CoreImage
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

/// Thread-safe in-memory image cache with request coalescing.
final class GlassImageCache: @unchecked Sendable {
    static let shared = GlassImageCache()

    private let cache = NSCache<NSString, GlassPlatformImage>()
    private let lock = NSLock()
    private var inFlight: [String: Task<GlassPlatformImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        cache.totalCostLimit = 160 * 1024 * 1024   // decoded bytes
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    private func key(_ url: URL, _ maxPixelSize: CGFloat?, _ variant: String) -> String {
        "\(variant)|\(Int(maxPixelSize ?? 0))|\(url.absoluteString)"
    }

    /// Already decoded image, if any (no I/O).
    func cachedImage(for url: URL, maxPixelSize: CGFloat?) -> GlassPlatformImage? {
        cache.object(forKey: key(url, maxPixelSize, "img") as NSString)
    }

    /// Loads, downsamples (longest side ≤ maxPixelSize, in pixels) and caches.
    func image(for url: URL, maxPixelSize: CGFloat?) async -> GlassPlatformImage? {
        await load(key(url, maxPixelSize, "img")) { [session] in
            guard let data = try? await GlassImageCache.data(for: url, session: session) else { return nil }
            return GlassImageCache.decode(data, maxPixelSize: maxPixelSize)
        }
    }

    /// A small, heavily blurred and slightly darkened copy of the image at
    /// `url`, for ambient backgrounds (computed once on a background thread,
    /// so nothing is blurred live while focus moves).
    /// Pass `source` when the image is already decoded (no second download).
    func blurredImage(for url: URL, from source: GlassPlatformImage? = nil, radius: CGFloat = 26) async -> GlassPlatformImage? {
        await load(key(url, 360, "blur\(Int(radius))")) { [weak self] in
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

    private func load(_ key: String, _ work: @escaping @Sendable () async -> GlassPlatformImage?) async -> GlassPlatformImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let task: Task<GlassPlatformImage?, Never> = lock.withLock {
            if let running = inFlight[key] { return running }
            let started = Task.detached(priority: .userInitiated) { await work() }
            inFlight[key] = started
            return started
        }
        let image = await task.value
        lock.withLock { inFlight[key] = nil }
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: image.glassPixelCost)
        }
        return image
    }

    private static func data(for url: URL, session: URLSession) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func decode(_ data: Data, maxPixelSize: CGFloat?) -> GlassPlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize, maxPixelSize > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        } else if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
                  let h = props[kCGImagePropertyPixelHeight] as? CGFloat {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
        }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return .glassImage(cg)
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
/// longest side to decode, in pixels (≈ 1× the drawn size on Apple TV, 2× on a Retina Mac).
struct GlassRemoteImage<Placeholder: View>: View {
    let url: URL?
    var maxPixelSize: CGFloat?
    var contentMode: ContentMode = .fill
    /// Where the image sits when its aspect ratio leaves room (contentMode .fit).
    var alignment: Alignment = .center
    /// Called with the decoded image (e.g. to read its aspect ratio).
    var onLoad: ((GlassPlatformImage) -> Void)? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: GlassPlatformImage?
    @State private var loadedURL: URL?

    init(url: URL?, maxPixelSize: CGFloat? = nil, contentMode: ContentMode = .fill,
         alignment: Alignment = .center,
         onLoad: ((GlassPlatformImage) -> Void)? = nil,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.alignment = alignment
        self.onLoad = onLoad
        self.placeholder = placeholder
        // Synchronous cache hit: no placeholder flash when cells are recycled.
        let hit = url.flatMap { GlassImageCache.shared.cachedImage(for: $0, maxPixelSize: maxPixelSize) }
        _image = State(initialValue: hit)
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
        .task(id: url) {
            guard let url else { image = nil; loadedURL = nil; return }
            if loadedURL == url, let image { onLoad?(image); return }
            guard let loaded = await GlassImageCache.shared.image(for: url, maxPixelSize: maxPixelSize),
                  !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                image = loaded
                loadedURL = url
            }
            onLoad?(loaded)
        }
    }
}

extension GlassRemoteImage where Placeholder == Color {
    init(url: URL?, maxPixelSize: CGFloat? = nil, contentMode: ContentMode = .fill,
         onLoad: ((GlassPlatformImage) -> Void)? = nil) {
        self.init(url: url, maxPixelSize: maxPixelSize, contentMode: contentMode, onLoad: onLoad) {
            Color.white.opacity(0.08)
        }
    }
}
