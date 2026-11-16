import Foundation
import TVServices
import PopcornKit

/// The Top Shelf of the Apple TV home screen: a full-screen carousel of what
/// is new — the Home's hero, then the newest 4K releases, additions and
/// episodes (`TopShelfModel`) — each with its details, a Play button (the
/// title's page, then playback) and a More Info button (the page).
///
/// tvOS makes the object and calls `loadTopShelfContent` when it wants the
/// shelf: when the app's icon is in the top row of the home screen and gets
/// the focus, and after `topShelfContentDidChange()`. The answer comes from
/// the extension's own disk cache when it has one (`TopShelfLoader`): no
/// request stands between the user and the shelf.
final class ContentProvider: TVTopShelfContentProvider {

    /// One hub per process: the system may ask again while a refresh runs
    /// (the second load joins it), and the lists stay in memory between two
    /// loads for as long as the system keeps the process.
    private static let loader = TopShelfLoader(feed: TopShelfLoader.makeFeed(), rules: rules, log: { NSLog("[TopShelf] %@", $0) })

    private static var rules: TopShelfModel.Rules {
        #if DEBUG
        // Simulator verification (an extension gets no launch argument): an
        // empty file named PTDebugTopShelfSections in the extension's Caches
        // folder makes the shelf the rows of posters it shows when no title
        // has a backdrop. Read once per process.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           FileManager.default.fileExists(atPath: caches.appendingPathComponent("PTDebugTopShelfSections").path) {
            var rules = TopShelfModel.Rules()
            rules.limit = 0
            return rules
        }
        #endif
        return TopShelfModel.Rules()
    }

    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        ContentProvider.loader.load(answer: { model in
            // Nil — nothing to show — makes the system show the app's
            // static Top Shelf image.
            completionHandler(ContentProvider.content(model))
        }, changed: {
            // The refresh that followed the answer brought other titles: the
            // system asks again, and is answered from memory.
            TVTopShelfContentProvider.topShelfContentDidChange()
        })
    }

    // MARK: - The model as the system's objects

    static func content(_ model: TopShelfModel) -> (any TVTopShelfContent)? {
        if !model.carousel.isEmpty {
            return TVTopShelfCarouselContent(style: .details, items: model.carousel.map(carouselItem))
        }
        guard !model.sections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: model.sections.map { section in
            let collection = TVTopShelfItemCollection(items: section.cards.map(sectionedItem))
            collection.title = section.title
            return collection
        })
    }

    private static func carouselItem(_ card: TopShelfModel.Card) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: card.id)
        item.title = card.title
        item.contextTitle = card.context
        // tvOS 26 draws neither of the two above in a card's details: the
        // title goes over the summary there (seen on tvOS 26.5).
        if #available(tvOS 26.0, *) {
            item.summary = card.titledSummary
        } else {
            item.summary = card.summary
        }
        item.genre = card.genre
        item.creationDate = card.date
        if let duration = card.duration { item.duration = duration }
        item.mediaOptions = mediaOptions(card.formats)
        // "Up to 4", says the header.
        item.namedAttributes = card.attributes.prefix(4).map { TVTopShelfNamedAttribute(name: $0.name, values: $0.values) }
        // The carousel is full screen: 1920 × 1080 points, so 3840 × 2160
        // pixels at 2x. One address for both scales: metahub's "large"
        // backdrop is the original (up to 3840 × 2160) and its next size
        // down is 1280 × 720, too small for a 1080p screen. A 1080p screen
        // (1x) is thus sent up to four times the pixels it needs, by
        // choice: the resizing proxy the app uses (images.weserv.nl, through
        // `ArtworkURL`) would put a third host between the system and the
        // most visible image of the box, with no second address to fall back
        // on when it is slow or down — the system gets one URL per scale —
        // and many of metahub's "large" backdrops are 1920 wide already. The
        // addresses do not change from one answer to the next, so the system
        // can keep what it fetched (not measured).
        // There is no place for a title logo in the API: the system draws
        // the title.
        item.setImageURL(card.wideImage, for: .screenScale1x)
        item.setImageURL(card.wideImage, for: .screenScale2x)
        setActions(of: item, card)
        return item
    }

    private static func sectionedItem(_ card: TopShelfModel.Card) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: card.id)
        item.title = card.title
        item.imageShape = .poster
        item.setImageURL(card.posterImage, for: .screenScale1x)
        item.setImageURL(card.posterImage, for: .screenScale2x)
        setActions(of: item, card)
        return item
    }

    /// Play (the first button of the carousel, the Play/Pause button on a
    /// poster) and More Info (the second button, a click on a poster).
    private static func setActions(of item: TVTopShelfItem, _ card: TopShelfModel.Card) {
        item.playAction = TVTopShelfAction(url: card.play)
        item.displayAction = TVTopShelfAction(url: card.display)
    }

    /// The badges of the Home's card as the system's: one resolution and one
    /// colour space at most (Dolby Vision before HDR), as the header asks.
    private static func mediaOptions(_ formats: TopShelfModel.Formats) -> TVTopShelfCarouselItem.MediaOptions {
        var options: TVTopShelfCarouselItem.MediaOptions = []
        if formats.contains(.uhd) { options.insert(.videoResolution4K) }
        if formats.contains(.dolbyVision) {
            options.insert(.videoColorSpaceDolbyVision)
        } else if formats.contains(.hdr) {
            options.insert(.videoColorSpaceHDR)
        }
        if formats.contains(.atmos) { options.insert(.audioDolbyAtmos) }
        return options
    }
}
