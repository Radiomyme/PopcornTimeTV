// HomeArtwork.swift — an image of the Home (iOS and macOS): the first of
// several addresses that answers, drawn in a box whose size never depends
// on it. Through the Glass pages' cache (`GlassImageCache`: decoded once at
// the size drawn, kept in memory, one request per address), so a card that
// scrolls back in shows its artwork at once.
//
// Several addresses because the sources' artwork is not always there: an
// episode's still may answer 404 (then the show's backdrop), a title may
// have no logo (then its name in text: the placeholder is told so).
import Foundation
import SwiftUI

struct HomeArtwork<Placeholder: View>: View {
    /// Best first.
    let urls: [URL]
    /// Longest side to decode, in pixels.
    let maxPixelSize: CGFloat
    var contentMode: ContentMode = .fill
    var alignment: Alignment = .center
    /// Drawn until an image arrives. `failed`: none of the addresses gave
    /// one — what stands in for the artwork for good.
    @ViewBuilder var placeholder: (_ failed: Bool) -> Placeholder

    @State private var image: GlassPlatformImage?
    @State private var loaded: [URL] = []
    @State private var failed = false

    init(urls: [URL], maxPixelSize: CGFloat, contentMode: ContentMode = .fill, alignment: Alignment = .center,
         @ViewBuilder placeholder: @escaping (_ failed: Bool) -> Placeholder) {
        self.urls = urls
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.alignment = alignment
        self.placeholder = placeholder
        // Already decoded: no placeholder, no fade (a recycled card).
        let hit = urls.lazy.compactMap { GlassImageCache.shared.cachedImage(for: $0, maxPixelSize: maxPixelSize) }.first
        _image = State(initialValue: hit)
        _loaded = State(initialValue: hit == nil ? [] : urls)
    }

    private var shown: GlassPlatformImage? { loaded == urls ? image : nil }

    var body: some View {
        ZStack(alignment: alignment) {
            if let shown {
                Image(glassImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder(failed && loaded == urls)
                    .transition(.opacity)
            }
        }
        .task(id: urls) {
            if loaded == urls, image != nil { return }
            for url in urls {
                let found = await GlassImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
                if Task.isCancelled { return }
                if let found {
                    withAnimation(.easeOut(duration: 0.3)) {
                        image = found
                        loaded = urls
                        failed = false
                    }
                    return
                }
            }
            withAnimation(.easeOut(duration: 0.3)) {
                image = nil
                loaded = urls
                failed = true
            }
        }
    }
}
