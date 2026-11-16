//
//  ArtworkPipelineTests.swift
//  PopcornTimeTests
//
//  The artwork pipeline (ArtworkPipeline) on a network that answers from a table, with real
//  pictures (PNG made here): the sized variant is what is fetched, a picture in memory is
//  never fetched nor decoded again, a larger size is, two callers share one load, another
//  picture of the title replaces an address that fails and is remembered, a host that keeps
//  failing is tried last. Then its parts: what a need accepts (ArtworkNeed), the memory
//  bound in pixels (ArtworkMemoryCache), the queue in front of the network (ArtworkQueue),
//  the prefetcher, and the disk cache's policy and session (ArtworkStore).
//

import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import PopcornKit

/// A PNG of `width` × `height` pixels.
func artworkTestPicture(_ width: Int, _ height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

final class ArtworkPipelineTests: CheckedTestCase {

    private let small = URL(string: "https://images.metahub.space/poster/small/tt7526136/img")!
    private let medium = URL(string: "https://images.metahub.space/poster/medium/tt7526136/img")!
    private let large = URL(string: "https://images.metahub.space/poster/large/tt7526136/img")!

    override func setUp() {
        super.setUp()
        ArtworkAlternates.removeAll()
    }

    private func pipeline(_ network: ArtworkTestNetwork, memoryPixels: Int = 4_000_000, loads: Int = 4, prefetches: Int = 2,
                          sizes: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) -> ArtworkPipeline {
        ArtworkPipeline(configuration: .init(memoryPixels: memoryPixels, concurrentLoads: loads, concurrentPrefetches: prefetches,
                                             hedgeDelay: 0.05, sizesAddresses: sizes, fetch: network.fetch, now: now))
    }

    /// metahub's three posters of one title.
    private func posters() -> ArtworkTestNetwork {
        let network = ArtworkTestNetwork()
        network[small] = .data(artworkTestPicture(300, 450))
        network[medium] = .data(artworkTestPicture(500, 750))
        network[large] = .data(artworkTestPicture(780, 1170))
        return network
    }

    // MARK: The pipeline

    func testTheSizedVariantIsFetchedAndDecodedAtTheSizeDrawn() async {
        let network = posters()
        let pipeline = pipeline(network)
        // A tvOS grid cell: 288 px wide when focused, so 432 px tall.
        let image = await pipeline.image(for: medium, need: ArtworkNeed(longestSide: 432, pixelWidth: 288))
        eq(network.requests, [small], "the 300 px poster is downloaded, not the 500 px one the model lists")
        eq(image?.pixelWidth, 288, "decoded 288 px wide")
        eq(image?.pixelHeight, 432, "and 432 px tall: the size drawn, not the file's")
        eq(image?.source, small, "it says where it came from")
        check(image?.isComplete == false, "a sized copy is not the whole picture")
        eq(pipeline.stats.decoded, 1, "one picture decoded")
    }

    func testAPictureInMemoryIsNeitherFetchedNorDecodedAgain() async {
        let network = posters()
        let pipeline = pipeline(network)
        let need = ArtworkNeed(longestSide: 432, pixelWidth: 288)
        let first = await pipeline.image(for: medium, need: need)
        let second = await pipeline.image(for: medium, need: need)
        check(first?.cgImage === second?.cgImage, "the same decoded bitmap is handed back")
        eq(network.requests.count, 1, "one request for the two")
        eq(pipeline.stats.decoded, 1, "decoded once")
        eq(pipeline.stats.memoryHits, 1, "the second came from memory")
        // A smaller card of the same poster (a related row) is served by it too.
        let smaller = await pipeline.image(for: medium, need: ArtworkNeed(longestSide: 240, pixelWidth: 160))
        check(smaller?.cgImage === first?.cgImage, "a smaller need is met by the picture already there")
        eq(network.requests.count, 1, "still one request")
        check(pipeline.cached(medium, need: need)?.isEnough == true, "the synchronous lookup says so too")
        check(pipeline.cached(medium, need: ArtworkNeed(longestSide: 1200, pixelWidth: 800))?.isEnough == false,
              "and says when the picture in memory is only a preview of a larger one")
        check(pipeline.cached(large, need: need) == nil, "another address has nothing")
    }

    func testALargerSizeIsLoadedAndReplacesTheSmallerOne() async {
        let network = posters()
        let pipeline = pipeline(network)
        _ = await pipeline.image(for: medium, need: ArtworkNeed(longestSide: 432, pixelWidth: 288))
        let hero = await pipeline.image(for: medium, need: ArtworkNeed(longestSide: 1200, pixelWidth: 800))
        eq(network.requests, [small, large], "the page's poster asks for the large one")
        eq(hero?.pixelWidth, 780, "all of it")
        let again = await pipeline.image(for: medium, need: ArtworkNeed(longestSide: 432, pixelWidth: 288))
        check(again?.cgImage === hero?.cgImage, "the grid now gets the larger copy: one picture per address is kept")
        eq(network.requests.count, 2, "without a request")
        eq(pipeline.memoryUse.pictures, 1, "one picture in memory")
        eq(pipeline.memoryUse.pixels, 780 * 1170, "its pixels are the cache's weight")
    }

    func testAVariantThatFailsFallsBackToTheAddressAsGiven() async {
        let network = posters()
        network[small] = .failure
        let pipeline = pipeline(network)
        let image = await pipeline.image(for: medium, need: ArtworkNeed(longestSide: 432, pixelWidth: 288))
        eq(network.requests, [small, medium], "the size that fails, then the address as given")
        eq(image?.source, medium, "the picture is the original")
        eq(image?.pixelWidth, 288, "decoded at the size drawn all the same")
        eq(pipeline.stats.detours, 1, "counted as a detour")
        network.reset()
        // The size is asked again later (another screen, a memory purge): straight to what worked.
        pipeline.purgeMemory()
        _ = await pipeline.image(for: medium, need: ArtworkNeed(longestSide: 432, pixelWidth: 288))
        eq(network.requests, [medium], "the address that had the picture is tried first the next time")
    }

    func testTwoCallersShareOneLoad() async {
        let network = posters()
        network[small] = .late(artworkTestPicture(300, 450), 0.15)
        let pipeline = pipeline(network)
        let need = ArtworkNeed(longestSide: 432, pixelWidth: 288)
        async let first = pipeline.image(for: medium, need: need)
        async let second = pipeline.image(for: medium, need: need)
        let (a, b) = await (first, second)
        check(a != nil && a?.cgImage === b?.cgImage, "both get the same picture")
        eq(network.requests.count, 1, "from one request")
        eq(pipeline.stats.decoded, 1, "decoded once")
    }

    func testACallerThatLeavesDoesNotStopTheLoadOfAnother() async {
        let network = posters()
        network[small] = .late(artworkTestPicture(300, 450), 0.2)
        let pipeline = pipeline(network)
        let need = ArtworkNeed(longestSide: 432, pixelWidth: 288)
        let poster = medium
        let leaving = Task { await pipeline.image(for: poster, need: need) }
        let staying = Task { await pipeline.image(for: poster, need: need) }
        for _ in 0..<200 where network.requests.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        leaving.cancel()
        let stayed = await staying.value
        let left = await leaving.value
        check(stayed != nil, "the caller still waiting gets its picture")
        check(left == nil, "the one that left gets nothing")
        // The last caller leaving cancels the load.
        network[large] = .silent
        let alone = Task { await pipeline.image(for: poster, need: ArtworkNeed(longestSide: 1200, pixelWidth: 800)) }
        for _ in 0..<200 where !network.requests.contains(large) { try? await Task.sleep(nanoseconds: 5_000_000) }
        alone.cancel()
        _ = await alone.value
        for _ in 0..<200 where network.cancelled.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        eq(network.cancelled, [large], "a load nobody waits for is cancelled")
    }

    func testAnotherPictureOfTheTitleReplacesACoverThatStaysSilent() async {
        let cover = URL(string: ImageProxy.proxied("https://yts.gg/assets/images/movies/national_theatre_live_prima_facie_2022/large-cover.jpg")!)!
        let sized = ArtworkURL.sized(cover, pixelWidth: 288)
        let poster = URL(string: "https://images.metahub.space/poster/small/tt21093976/img")!
        ArtworkAlternates.register(imdbID: "tt21093976", poster: cover.absoluteString)
        let network = ArtworkTestNetwork()
        network[sized] = .silent
        network[cover] = .silent
        network[poster] = .data(artworkTestPicture(300, 450))
        let pipeline = pipeline(network)
        let need = ArtworkNeed(longestSide: 432, pixelWidth: 288)

        let image = await pipeline.image(for: cover, need: need)
        eq(image?.source, poster, "metahub's poster of the film, when the proxy says nothing")
        eq(network.cancelled, [sized], "the silent request is dropped")
        eq(pipeline.stats.detours, 1, "a detour")
        // The cell comes back on screen: the picture is in memory under the cover's address.
        network.reset()
        let again = await pipeline.image(for: cover, need: need)
        check(again?.cgImage === image?.cgImage, "the same picture")
        eq(network.requests, [], "nothing is asked again: the silent cover is not retried at every appearance")
        // A larger size of it: straight to the source that answered. (It
        // answers: otherwise the silent cover, last in line, would be waited
        // for until the test network gives up, 30 s later.)
        let largePoster = URL(string: "https://images.metahub.space/poster/large/tt21093976/img")!
        network[largePoster] = .data(artworkTestPicture(780, 1170))
        let larger = await pipeline.image(for: cover, need: ArtworkNeed(longestSide: 1200, pixelWidth: 800))
        eq(network.requests.first, largePoster, "the source that had the picture is tried first for the larger size")
        eq(larger?.source, largePoster, "and gives it")
    }

    func testTheCallersOwnAlternatesAreTriedToo() async {
        let still = URL(string: "https://episodes.metahub.space/tt31510819/1/3/w780.jpg")!
        let backdrop = URL(string: "https://images.metahub.space/background/large/tt31510819/img")!
        let network = ArtworkTestNetwork()
        network[URL(string: "https://images.metahub.space/background/small/tt31510819/img")!] = .data(artworkTestPicture(480, 270))
        let pipeline = pipeline(network)
        let image = await pipeline.image(for: still, need: ArtworkNeed(pixelWidth: 400), alternates: [backdrop])
        eq(image?.pixelWidth, 480, "an episode without a still gets its show's backdrop, at the card's size")
        eq(network.requests.count, 3, "the still's two sizes, then the backdrop's small one")
    }

    func testAHostThatKeepsFailingIsTriedLast() async {
        let network = ArtworkTestNetwork()
        var covers: [URL] = []
        for index in 0..<5 {
            let cover = URL(string: ImageProxy.proxied("https://yts.gg/assets/images/movies/film\(index)/large-cover.jpg")!)!
            ArtworkAlternates.register(imdbID: "tt000000\(index)", poster: cover.absoluteString)
            network[URL(string: "https://images.metahub.space/poster/small/tt000000\(index)/img")!] = .data(artworkTestPicture(300, 450))
            covers.append(cover)
        }
        let pipeline = pipeline(network)
        let need = ArtworkNeed(longestSide: 432, pixelWidth: 288)
        for cover in covers.prefix(3) {
            let image = await pipeline.image(for: cover, need: need)
            check(image != nil, "the poster comes from metahub")
        }
        network.reset()
        let fourth = await pipeline.image(for: covers[3], need: need)
        check(fourth != nil, "the fourth too")
        eq(network.requests, [URL(string: "https://images.metahub.space/poster/small/tt0000003/img")!],
           "after three failures in a row the proxied covers are no longer tried first: metahub alone was asked")
    }

    func testAResizeSlowerThanItsOriginalDoesNotPutTheProxyAside() async {
        let network = ArtworkTestNetwork()
        let need = ArtworkNeed(longestSide: 432, pixelWidth: 288)
        var originals: [URL] = []
        for index in 0..<4 {
            let original = URL(string: "https://static.tvmaze.com/uploads/images/original_untouched/610/15252\(index).jpg")!
            // The proxy's first resize of a large original: slower than the hedge.
            network[ArtworkURL.sized(original, pixelWidth: 288)] = .late(artworkTestPicture(300, 450), 0.5)
            network[original] = .data(artworkTestPicture(680, 1000))
            originals.append(original)
        }
        let pipeline = pipeline(network)
        for original in originals.prefix(3) {
            let image = await pipeline.image(for: original, need: need)
            eq(image?.source, original, "the original, started beside the silent resize, wins")
        }
        network.reset()
        _ = await pipeline.image(for: originals[3], need: need)
        eq(network.requests.first, ArtworkURL.sized(originals[3], pixelWidth: 288),
           "three resizes only slower than their originals: the proxy is still tried first")
    }

    func testNothingWhenNoAddressHasAPicture() async {
        let network = ArtworkTestNetwork()
        let pipeline = pipeline(network)
        let image = await pipeline.image(for: medium, need: ArtworkNeed(longestSide: 432, pixelWidth: 288))
        check(image == nil, "no picture")
        eq(network.requests, [small, medium], "both addresses were tried")
        eq(pipeline.stats.missing, 1, "counted")
        check(pipeline.cached(medium, need: ArtworkNeed()) == nil, "and nothing is kept")
    }

    func testAddressesAsGivenWhenSizingIsOff() async {
        let network = posters()
        ArtworkAlternates.register([large], for: medium)
        let pipeline = pipeline(network, sizes: false)
        let image = await pipeline.image(for: medium, need: ArtworkNeed(longestSide: 432, pixelWidth: 288))
        eq(network.requests, [medium], "the address the model lists, as 5.2.0 loaded it")
        eq(image?.pixelHeight, 432, "decoded at the size drawn")
    }

    func testAPictureAskedWithoutASizeIsTheWholeFile() async {
        let network = posters()
        let pipeline = pipeline(network)
        let image = await pipeline.image(for: medium)
        eq(network.requests, [medium], "the address as given")
        eq(image?.pixelWidth, 500, "at its own size")
        check(image?.isComplete == true, "it answers any size from now on")
        let hero = await pipeline.image(for: medium, need: ArtworkNeed(longestSide: 1200, pixelWidth: 800))
        check(hero?.cgImage === image?.cgImage, "even a larger one: nothing larger exists at this address")
    }

    func testTheMemoryIsBoundedInPixels() async {
        let network = ArtworkTestNetwork()
        var urls: [URL] = []
        for index in 0..<6 {
            let url = URL(string: "https://example.org/\(index).png")!
            network[url] = .data(artworkTestPicture(100, 100))
            urls.append(url)
        }
        // Room for three 100 × 100 pictures and a half.
        let pipeline = pipeline(network, memoryPixels: 35_000)
        for url in urls.prefix(3) { _ = await pipeline.image(for: url) }
        eq(pipeline.memoryUse.pixels, 30_000, "three pictures held")
        _ = await pipeline.image(for: urls[0])          // used again: the most recent now
        _ = await pipeline.image(for: urls[3])
        eq(pipeline.memoryUse.pictures, 3, "a fourth one pushes one out")
        check(pipeline.cached(urls[1], need: ArtworkNeed()) == nil, "the least recently used")
        check(pipeline.cached(urls[0], need: ArtworkNeed()) != nil, "not the one used since")
        pipeline.purgeMemory()
        eq(pipeline.memoryUse.pixels, 0, "a purge empties it")
    }

    // MARK: Needs

    func testWhatANeedAccepts() {
        func image(_ width: Int, _ height: Int, askedWidth: CGFloat = .infinity, askedSide: CGFloat = .infinity, reduced: Bool = false) -> ArtworkImage {
            let data = artworkTestPicture(width, height)
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            return ArtworkImage(cgImage: CGImageSourceCreateImageAtIndex(source, 0, nil)!, source: medium,
                                askedWidth: askedWidth, askedSide: askedSide, reducedByDecoding: reduced)
        }
        let grid = ArtworkNeed(longestSide: 432, pixelWidth: 288)
        eq(grid.networkWidth(for: medium), 288, "the width drawn")
        eq(ArtworkNeed(longestSide: 300, pixelWidth: 288).networkWidth(for: medium), 200, "never more than the decoder keeps (a poster 300 px tall is 200 wide)")
        eq(ArtworkNeed(longestSide: 600).networkWidth(for: medium), 400, "from the longest side alone")
        check(ArtworkNeed().networkWidth(for: medium) == nil, "nothing asked: the address as given")
        eq(ArtworkNeed(longestSide: -1, pixelWidth: 0), ArtworkNeed(), "sizes that are not sizes are no sizes")

        check(grid.isMet(by: image(300, 450, askedWidth: 288, askedSide: 432), of: medium), "loaded for this very card")
        check(grid.isMet(by: image(288, 432, askedWidth: 288, askedSide: 432, reduced: true), of: medium), "cut down to it by the decoder")
        check(grid.isMet(by: image(230, 345, askedWidth: 288, askedSide: 432), of: medium),
              "a smaller file loaded for this card is all there is: not asked again")
        check(grid.isMet(by: image(250, 375, askedWidth: 200, askedSide: 300), of: medium), "13 % short: within the tolerance")
        check(!grid.isMet(by: image(160, 240, askedWidth: 160, askedSide: 240), of: medium), "a thumbnail is not enough")
        check(grid.isMet(by: image(500, 750), of: medium), "the whole file answers everything")
        check(ArtworkNeed().isMet(by: image(500, 750), of: medium), "even no size at all")
        check(!ArtworkNeed().isMet(by: image(300, 450, askedWidth: 288), of: medium), "a sized copy is not the whole file")
        // A prefetch decodes with room to spare; the view then asks its own, larger, decoded size.
        let view = ArtworkNeed(longestSide: 600, pixelWidth: 288)
        check(view.isMet(by: image(300, 450, askedWidth: 288, askedSide: 864), of: medium), "the prefetched poster serves the view")
        check(!view.isMet(by: image(200, 300, askedWidth: 288, askedSide: 300, reduced: true), of: medium),
              "one the decoder cut below the view's size does not")
    }

    // MARK: The memory cache

    func testTheMemoryCacheKeepsTheLargestPictureOfAnAddress() {
        func image(_ width: Int, askedWidth: CGFloat) -> ArtworkImage {
            let source = CGImageSourceCreateWithData(artworkTestPicture(width, width) as CFData, nil)!
            return ArtworkImage(cgImage: CGImageSourceCreateImageAtIndex(source, 0, nil)!, source: medium, askedWidth: askedWidth, askedSide: askedWidth)
        }
        var cache = ArtworkMemoryCache(limit: 1_000_000)
        cache.insert(image(100, askedWidth: 100), for: medium)
        let kept = cache.insert(image(50, askedWidth: 300), for: medium)
        eq(kept.pixelWidth, 100, "a smaller picture does not replace a larger one")
        eq(kept.askedWidth, 300, "but what it was loaded for is remembered: it is all the source had for 300 px")
        eq(cache.pixels, 10_000, "one picture's pixels")
        let larger = cache.insert(image(200, askedWidth: 200), for: medium)
        eq(larger.pixelWidth, 200, "a larger one does")
        eq(larger.askedWidth, 300, "keeping the largest size asked")
        eq(cache.pixels, 40_000, "the old one's pixels are given back")
        eq(cache.count, 1, "one picture per address")
        cache.insert(image(2000, askedWidth: 2000), for: small)
        eq(cache.count, 1, "a picture larger than the whole bound pushes the others out")
        check(cache.image(for: small) != nil, "and stays: it is on screen")
        cache.trim(to: 0)
        eq(cache.pixels, 0, "trimmed to nothing")
    }

    // MARK: The queue

    func testTheQueueKeepsPrefetchesBehindWhatAScreenWaitsFor() {
        var queue = ArtworkQueue(limit: 3, prefetchLimit: 1)
        check(queue.enter(1, .prefetch), "an idle queue starts a prefetch")
        check(!queue.enter(2, .prefetch), "but only one at a time")
        check(queue.enter(3, .visible), "a view's load starts")
        check(queue.enter(4, .visible), "a second one too")
        check(!queue.enter(5, .visible), "the third waits: three loads at once")
        check(!queue.enter(6, .visible), "and the fourth")
        eq(queue.running, 3, "three running")
        eq(queue.waiting, 3, "three waiting")
        eq(queue.leave(), [5], "a place: the first view waiting, not the prefetch that waited longer")
        eq(queue.leave(), [6], "then the next view")
        eq(queue.leave(), [], "the prefetch still waits: it only runs in the first place")
        eq(queue.leave(), [], "which a view's load still holds")
        eq(queue.leave(), [2], "the queue is idle: the prefetch starts")
        eq(queue.leave(), [], "nothing left")
        eq(queue.running, 0, "idle")
    }

    func testAPrefetchAScreenNowWaitsForJumpsTheQueue() {
        var queue = ArtworkQueue(limit: 2, prefetchLimit: 1)
        check(queue.enter(1, .visible), "a view")
        check(!queue.enter(2, .prefetch), "a prefetch waits behind it")
        check(!queue.enter(3, .prefetch), "another one")
        eq(queue.promote(3), [3], "a view now waits for the second: it starts, in the place a view may take")
        eq(queue.promote(3), [], "promoting twice changes nothing")
        eq(queue.promote(9), [], "an unknown load neither")
        check(queue.cancel(2), "the first prefetch gives up while waiting")
        check(!queue.cancel(2), "once")
        check(!queue.cancel(1), "a running load is not in the queue")
        eq(queue.leave(), [], "nothing to start")
        eq(queue.waiting, 0, "nobody waits")
    }

    // MARK: The prefetcher

    func testAPrefetchedPictureIsReadyForTheView() async {
        let network = posters()
        let pipeline = pipeline(network)
        let prefetcher = ArtworkPrefetcher(pipeline: pipeline)
        prefetcher.prefetch(urls: [medium], width: 288)
        for _ in 0..<400 where prefetcher.pending > 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        eq(network.requests, [small], "the size the card will draw was fetched")
        // The card appears: a decoded size of its own choosing (the Mac grids' 600), a width close to the prefetch's.
        let need = ArtworkNeed(longestSide: 600, pixelWidth: 300)
        check(pipeline.cached(medium, need: need)?.isEnough == true, "found in memory, at init, without I/O")
        _ = await pipeline.image(for: medium, need: need)
        eq(network.requests.count, 1, "no second request")
        eq(pipeline.stats.decoded, 1, "no second decoding")
        prefetcher.prefetch(urls: [medium], width: 288)
        eq(prefetcher.pending, 0, "a picture already in memory is not prefetched again")
        prefetcher.prefetch(urls: [large], width: 0)
        eq(prefetcher.pending, 0, "no width, no prefetch")
    }

    func testCancelledPrefetchesStop() async {
        let network = ArtworkTestNetwork()
        var urls: [URL] = []
        for index in 0..<6 {
            let url = URL(string: "https://example.org/\(index).png")!
            network[url] = .silent
            urls.append(url)
        }
        let pipeline = pipeline(network, loads: 4, prefetches: 2)
        let prefetcher = ArtworkPrefetcher(pipeline: pipeline)
        prefetcher.prefetch(urls: urls, width: 300)
        prefetcher.prefetch(urls: urls, width: 300)
        eq(prefetcher.pending, 6, "six prefetches, asked twice")
        for _ in 0..<400 where network.requests.count < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        eq(network.requests.count, 2, "two at a time: the rest wait")
        prefetcher.cancel(urls: [urls[5]])
        eq(prefetcher.pending, 5, "one cancelled by address")
        prefetcher.cancel()
        eq(prefetcher.pending, 0, "all cancelled")
        for _ in 0..<400 where network.cancelled.count < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
        eq(Set(network.cancelled), Set(network.requests), "the two running requests were dropped")
        try? await Task.sleep(nanoseconds: 100_000_000)
        eq(network.requests.count, 2, "and the ones waiting never started")
    }

    func testAViewJoinsAPrefetchAndMovesItAhead() async {
        let network = ArtworkTestNetwork()
        let blocker = URL(string: "https://example.org/blocker.png")!
        let wanted = URL(string: "https://example.org/wanted.png")!
        network[blocker] = .late(artworkTestPicture(10, 10), 5)
        network[wanted] = .data(artworkTestPicture(10, 10))
        // One prefetch at a time: `wanted` waits behind `blocker`.
        let pipeline = pipeline(network, loads: 2, prefetches: 1)
        let prefetcher = ArtworkPrefetcher(pipeline: pipeline)
        prefetcher.prefetch(urls: [blocker, wanted], width: 10)
        for _ in 0..<400 where network.requests.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        let started = Date()
        // What the views ask: the longest side they draw (a poster 10 px wide is 15 px tall).
        let image = await pipeline.image(for: wanted, need: ArtworkNeed(longestSide: 15))
        check(image != nil, "the view gets the picture")
        check(Date().timeIntervalSince(started) < 3, "without waiting for the prefetch in front of it", "\(Date().timeIntervalSince(started)) s")
        eq(network.requests.filter { $0 == wanted }.count, 1, "through the prefetch's own load: one request")
        prefetcher.cancel()
    }

    func testAViewFindsAPrefetchedPictureOfAnAddressThatDoesNotSayWhatItShows() async {
        // A TVMaze original: a poster, but its address does not say so.
        let original = URL(string: "https://static.tvmaze.com/uploads/images/original_untouched/610/1525272.jpg")!
        let width: CGFloat = 288
        let view = ArtworkNeed(longestSide: 432)   // HomeArtImage / HomeArtwork: the poster's height
        let variant = ArtworkURL.sized(original, pixelWidth: view.networkWidth(for: original)!)
        let network = ArtworkTestNetwork()
        network[variant] = .late(artworkTestPicture(400, 600), 0.2)
        let pipeline = pipeline(network)
        let prefetcher = ArtworkPrefetcher(pipeline: pipeline)

        // The view appears while the prefetch is loading: it joins it.
        prefetcher.prefetch(urls: [original], width: width)
        for _ in 0..<400 where network.requests.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        let joined = await pipeline.image(for: original, need: view)
        check(joined != nil, "the view gets the picture")
        eq(network.requests.filter { $0 != original }, [variant], "the variant the view would have asked for, asked once")

        // Finished, the prefetch is enough for the view.
        let other = URL(string: "https://static.tvmaze.com/uploads/images/original_untouched/610/1525273.jpg")!
        let otherVariant = ArtworkURL.sized(other, pixelWidth: 432)
        network[otherVariant] = .data(artworkTestPicture(400, 600))
        network.reset()
        prefetcher.prefetch(urls: [other], width: width)
        for _ in 0..<400 where prefetcher.pending > 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        check(pipeline.cached(other, need: view)?.isEnough == true, "found in memory, large enough")
        _ = await pipeline.image(for: other, need: view)
        eq(network.requests, [otherVariant], "no second, larger download")
    }

    func testACallerThatJoinsASmallerDecodeGetsItsOwnSize() async {
        let original = URL(string: "https://example.org/original.png")!
        let network = ArtworkTestNetwork()
        network[original] = .late(artworkTestPicture(800, 1200), 0.2)
        let pipeline = pipeline(network)
        let small = Task { await pipeline.image(for: original, need: ArtworkNeed(longestSide: 300)) }
        for _ in 0..<400 where network.requests.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        let large = await pipeline.image(for: original, need: ArtworkNeed(longestSide: 900))
        let smallImage = await small.value
        eq(smallImage?.pixelHeight, 300, "the first caller's size")
        eq(large?.pixelHeight, 900, "the one that joined is decoded again at its own")
        eq(network.requests.count, 2, "here a second fetch (the app's is answered by the disk cache the first one filled)")
    }

    // MARK: The disk cache

    func testTheDiskCachePolicy() {
        let policy = ArtworkStore.Policy.platform
        // The tests run on the Mac.
        eq(policy.diskBytes, 500 << 20, "500 MB on disk on the Mac")
        eq(policy.memoryBytes, 8 << 20, "8 MB of files in memory")
        eq(policy.timeout, 15, "15 s without a byte")
        check(ArtworkPipeline.Configuration.memoryPixels(physicalMemory: 16 << 30) == 64_000_000, "64 million decoded pixels on the Mac")
        // The Mac app is not sandboxed: ~/Library/Caches is every app's.
        let caches = URL(fileURLWithPath: "/Users/someone/Library/Caches", isDirectory: true)
        eq(ArtworkStore.directory(in: caches, bundleIdentifier: "com.popcorntime.mac").path,
           "/Users/someone/Library/Caches/com.popcorntime.mac/popcornkit-artwork", "under the bundle's own folder")
        eq(ArtworkStore.directory(in: caches, bundleIdentifier: "com.popcorntime.mac.test").path,
           "/Users/someone/Library/Caches/com.popcorntime.mac.test/popcornkit-artwork", "another identity has its own")
    }

    func testTheStoreFetchesCountsAndRefuses() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ArtworkStore(directory: folder, policy: .init(memoryBytes: 1 << 20, diskBytes: 8 << 20, timeout: 5),
                                 protocolClasses: [ArtworkTestProtocol.self])
        eq(store.cache.diskCapacity, 8 << 20, "the cache has the policy's size")
        let clock = ArtworkTestClock()
        store.now = { clock.date }
        let pipeline = ArtworkPipeline(configuration: .init(memoryPixels: 1_000_000, concurrentLoads: 2, concurrentPrefetches: 1,
                                                             fetch: { _ in throw URLError(.unsupportedURL) }), store: store)
        let good = URL(string: "https://artwork.test/poster.png")!
        let missing = URL(string: "https://artwork.test/missing.png")!
        ArtworkTestProtocol.answers = [good: (200, artworkTestPicture(60, 90)), missing: (404, Data("gone".utf8))]
        ArtworkTestProtocol.requests = []

        let image = await pipeline.image(for: good, need: ArtworkNeed(longestSide: 90, pixelWidth: 60))
        eq(image?.pixelWidth, 60, "the picture came through the store's session")
        eq(pipeline.stats.networkResponses, 1, "one network answer counted")
        check(pipeline.stats.networkBytes > 0, "with its bytes")
        let none = await pipeline.image(for: missing)
        check(none == nil, "a 404 is not a picture, whatever its body")
        eq(pipeline.stats.failures, 1, "one failure counted")
        eq(pipeline.stats.missing, 1, "one picture missing")
        eq(ArtworkTestProtocol.requests.filter { $0 == missing }.count, 1, "asked once")
        check(!store.holds(missing), "an answer that is not a picture is not kept in the cache")
        // The screen comes back (a hero that cycles): the address is left alone for ten minutes.
        _ = await pipeline.image(for: missing)
        _ = await pipeline.image(for: missing)
        eq(ArtworkTestProtocol.requests.filter { $0 == missing }.count, 1, "a missing picture is not asked again at once")
        clock.date += 601
        _ = await pipeline.image(for: missing)
        eq(ArtworkTestProtocol.requests.filter { $0 == missing }.count, 2, "ten minutes later it is: a new title's logo comes within days")
        // The picture is there now.
        ArtworkTestProtocol.answers[missing] = (200, artworkTestPicture(30, 45))
        clock.date += 601
        let arrived = await pipeline.image(for: missing)
        eq(arrived?.pixelWidth, 30, "and shown once the host has it")

        // A file address is read directly.
        var isFolder: ObjCBool = false
        check(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue,
              "the store made its folder")
        let file = folder.appendingPathComponent("local.png")
        try artworkTestPicture(40, 60).write(to: file)
        let local = await pipeline.image(for: file)
        eq(local?.pixelHeight, 60, "file:// works too")
        pipeline.removeAllCachedData()
        eq(pipeline.memoryUse.pictures, 0, "clearing the caches empties the memory")
    }
}

/// A date the tests move by hand.
final class ArtworkTestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

/// Answers the store's requests from a table.
final class ArtworkTestProtocol: URLProtocol {
    static var answers: [URL: (status: Int, body: Data)] = [:]
    /// The addresses asked, in order.
    static var requests: [URL] {
        get { lock.lock(); defer { lock.unlock() }; return asked }
        set { lock.lock(); asked = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    private static var asked: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.lock.lock(); Self.asked.append(url); Self.lock.unlock() }
        guard let url = request.url, let answer = Self.answers[url],
              let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
