// HomeBackdrop.swift — the full-screen artwork behind the Home tab: the
// backdrop of the title the billboard shows, cross-faded when it changes,
// under gradients that keep white text readable on any image.
//
// Memory (an Apple TV HD has 2 GB): a 1920 × 1080 backdrop is 8 MB once
// decoded. They do not go through `GlassImageCache`, whose memory cache
// would keep every backdrop the focus crossed: this file keeps the one on
// screen and, during a cross-fade, the one coming in — never more than two.
// The bytes go through the artwork pipeline's disk store (`ArtworkStore`,
// 150 MB on tvOS, for pictures only), at the size drawn: going back to a
// title, or the hero's next turn, reads them from the disk. (Not
// `URLCache.shared`: a few MB, shared with the API answers, and it does
// not keep an answer larger than ~5 % of its size — a full backdrop.)
import SwiftUI
import ImageIO
import PopcornKit

@MainActor
@Observable
final class HomeBackdrop {

    /// The artwork of one title.
    struct Source: Equatable {
        /// The title (an episode's card shows its show's backdrop).
        var id: String
        /// What to try, in order.
        var urls: [URL]
        /// The title's poster: blurred, as ambient light, when every
        /// backdrop that loaded was a montage of tiles (`HomeCollage`).
        var posterURL: URL?

        init(id: String, urls: [URL], posterURL: URL? = nil) {
            self.id = id
            self.urls = urls
            self.posterURL = posterURL
        }

        /// The card's backdrop, then metahub's by IMDb id (a card's own may
        /// be missing, or behind a proxy that does not answer).
        init(_ item: HomeItem) {
            var urls: [URL] = []
            for url in [item.backdropURL, OpenMetadata.backgroundURL(imdbId: item.imdbId)].compactMap({ $0 }) where !urls.contains(url) {
                urls.append(url)
            }
            self.init(id: item.imdbId, urls: urls, posterURL: item.posterURL ?? OpenMetadata.posterURL(imdbId: item.imdbId))
        }
    }

    // Two layers that take turns: the new image goes in the hidden one,
    // which then fades in over the other.
    private(set) var first: GlassPlatformImage?
    private(set) var second: GlassPlatformImage?
    private(set) var showsSecond = false

    @ObservationIgnored private var wanted: Source?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var releasing: Task<Void, Never>?
    /// Longest side decoded, in pixels.
    @ObservationIgnored var maxPixelSize: CGFloat = 1920
    /// Called when an image is on screen (DEBUG timing).
    @ObservationIgnored var onPresent: (() -> Void)?

    static let fade: TimeInterval = 0.35

    /// Shows `source`'s artwork once it has loaded; what is on screen stays
    /// until then (and when there is nothing to load: no flash to black).
    func show(_ source: Source?) {
        guard source != wanted else { return }
        wanted = source
        loading?.cancel()
        guard let source, !source.urls.isEmpty else { return }
        let size = maxPixelSize
        loading = Task { [weak self] in
            let image = await HomeBackdropLoader.image(source.urls, posterURL: source.posterURL, maxPixelSize: size)
            guard !Task.isCancelled, let self, self.wanted == source else { return }
            self.present(image)
        }
    }

    private func present(_ image: GlassPlatformImage?) {
        // Nothing loaded: what is shown stays.
        guard let image else { return }
        if showsSecond { first = image } else { second = image }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        withAnimation(.easeInOut(duration: reduceMotion ? 0.01 : HomeBackdrop.fade)) { showsSecond.toggle() }
        onPresent?()
        // The image that faded out is released: one backdrop in memory at rest.
        releasing?.cancel()
        releasing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((HomeBackdrop.fade + 0.15) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.showsSecond { self.first = nil } else { self.second = nil }
        }
    }
}

/// Downloads and decodes a backdrop off the main thread, at the size it is drawn.
enum HomeBackdropLoader {

    /// The first of `urls` that gives a landscape image that is not a
    /// montage of tiles (`HomeCollage`); when the only ones were montages,
    /// the poster blurred (ambient light, as on the title's page); nil when
    /// nothing loads. Off the main thread (not isolated); the decoding is
    /// part of the caller's task: a backdrop no longer wanted is not decoded.
    static func image(_ urls: [URL], posterURL: URL? = nil, maxPixelSize: CGFloat) async -> GlassPlatformImage? {
        var turnedAway = false
        for url in urls {
            if Task.isCancelled { return nil }
            if montages.contains(url) { turnedAway = true; continue }
            guard let data = await data(ArtworkURL.sized(url, pixelWidth: maxPixelSize)), !Task.isCancelled else { continue }
            let image = decode(data, maxPixelSize: maxPixelSize)
            // A poster served as a backdrop would be a blown-up crop.
            guard let image, image.size.width >= image.size.height * 1.3 else { continue }
            if let cgImage = image.glassCGImage, HomeCollage.isCollage(cgImage) {
                montages.insert(url)
                turnedAway = true
                continue
            }
            return image
        }
        guard turnedAway, let posterURL, !Task.isCancelled else { return nil }
        return await GlassImageCache.shared.blurredImage(for: posterURL)
    }

    /// The backdrops found to be montages this session: not decoded again
    /// at each turn of the hero.
    private static let montages = HomeMontageSet()

    /// The bytes, through the pipeline's disk store (a file address is read
    /// directly); nil for anything but a 2xx answer with a body.
    private static func data(_ url: URL) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }
        return try? await ArtworkStore.standard.data(from: url)
    }

    private static func decode(_ data: Data, maxPixelSize: CGFloat) -> GlassPlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return .glassImage(image)
    }
}

/// A set of addresses shared across threads.
private final class HomeMontageSet: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: Set<URL> = []

    func contains(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return urls.contains(url)
    }

    func insert(_ url: URL) {
        lock.lock()
        urls.insert(url)
        lock.unlock()
    }
}

/// The artwork and its scrims, full screen. `lowered`: the focus is in the
/// shelves, the lower part of the screen belongs to the cards.
struct HomeBackdropView: View {
    let backdrop: HomeBackdrop
    let lowered: Bool
    let size: CGSize

    var body: some View {
        ZStack {
            // Under the image, and all there is until one has loaded.
            LinearGradient(colors: [Color(red: 0.17, green: 0.08, blue: 0.20), Color(red: 0.04, green: 0.03, blue: 0.07)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            layer(backdrop.first).opacity(backdrop.showsSecond ? 0 : 1)
            layer(backdrop.second).opacity(backdrop.showsSecond ? 1 : 0)
            scrims
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func layer(_ image: GlassPlatformImage?) -> some View {
        if let image {
            Image(glassImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
        }
    }

    /// Left: behind the billboard's text. Bottom: behind the shelves (much
    /// higher once the focus is in them). Top: behind the tab bar.
    private var scrims: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .black.opacity(0.90), location: 0),
                                   .init(color: .black.opacity(0.74), location: 0.36),
                                   .init(color: .black.opacity(0.30), location: 0.60),
                                   .init(color: .black.opacity(0), location: 0.82)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.34),
                                   .init(color: .black.opacity(0.66), location: 0.70),
                                   .init(color: .black.opacity(0.95), location: 0.92),
                                   .init(color: .black.opacity(0.97), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .opacity(lowered ? 0 : 1)
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.10),
                                   .init(color: .black.opacity(0.78), location: 0.34),
                                   .init(color: .black.opacity(0.95), location: 0.52),
                                   .init(color: .black.opacity(0.97), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .opacity(lowered ? 1 : 0)
            // Top: behind the tab bar, and over a light sky (a cream band
            // read brighter than the text area under it): 60 % and more of
            // black over the first quarter of the screen.
            LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0),
                                   .init(color: .black.opacity(0.60), location: 0.25),
                                   .init(color: .black.opacity(0), location: 0.42)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}
