//
//  ArtworkURLTests.swift
//  PopcornTimeTests
//
//  The address of an artwork at the size it is drawn (ArtworkURL): each host's variants
//  (metahub, the image proxy in front of YTS, TVMaze, the TMDB CDN, Amazon), the addresses
//  left alone, what an address says it shows, and the sources a load goes through — the
//  sized variant, the address as given, then the other pictures of the title
//  (ArtworkAlternates, YTS's medium cover). The widths are the ones measured on the real
//  hosts in November 2026.
//

import XCTest
import Foundation
@testable import PopcornKit

final class ArtworkURLTests: CheckedTestCase {

    private func url(_ text: String) -> URL { URL(string: text)! }
    private func sized(_ text: String, _ width: CGFloat) -> String {
        ArtworkURL.sized(url(text), pixelWidth: width).absoluteString
    }

    override func setUp() {
        super.setUp()
        ArtworkAlternates.removeAll()
    }

    // MARK: metahub

    func testAMetahubPosterComesInTheSmallestSizeThatCoversTheWidth() {
        let small = "https://images.metahub.space/poster/small/tt7526136/img"
        let medium = "https://images.metahub.space/poster/medium/tt7526136/img"
        let large = "https://images.metahub.space/poster/large/tt7526136/img"
        eq(sized(medium, 250), small, "a 250 px card: the 300 px poster, not the 500 px one the model lists")
        eq(sized(medium, 300), small, "300 px: still the small one")
        eq(sized(small, 352), small, "352 px is drawn from 300 px (17 % larger): within the tolerance")
        eq(sized(small, 400), medium, "a Cinemeta catalogue lists the small poster: a 400 px cell gets the medium one")
        eq(sized(large, 500), medium, "500 px: the medium one")
        eq(sized(small, 528), medium, "an iPhone's 176 pt cell at 3x (528 px): the medium one, 6 % short")
        eq(sized(small, 700), large, "700 px: the large one")
        eq(sized(small, 2000), large, "nothing larger than large")
    }

    func testMetahubBackdropsAndLogosHaveTheirOwnWidths() {
        let backdrop = "https://images.metahub.space/background/large/tt31510819/img"
        eq(sized(backdrop, 420), "https://images.metahub.space/background/small/tt31510819/img", "a landscape card: 480 px, not 1920")
        eq(sized(backdrop, 1000), "https://images.metahub.space/background/medium/tt31510819/img", "1000 px: the 1280 px one")
        eq(sized(backdrop, 1920), backdrop, "a full screen: the large one")
        eq(sized(backdrop, 3840), backdrop, "and nothing above it")
        let logo = "https://live.metahub.space/logo/medium/tt31510819/img"
        eq(sized(logo, 300), "https://live.metahub.space/logo/small/tt31510819/img", "the host the image was found on is kept")
        eq(sized(logo, 600), logo, "600 px: the 780 px logo")
        eq(sized(logo, 1000), "https://live.metahub.space/logo/large/tt31510819/img", "1000 px: the large logo")
    }

    func testAnEpisodeStillIsNamedByItsWidth() {
        let still = "https://episodes.metahub.space/tt31510819/1/3/w780.jpg"
        eq(sized(still, 280), "https://episodes.metahub.space/tt31510819/1/3/w300.jpg", "a 280 px card")
        eq(sized(still, 560), "https://episodes.metahub.space/tt31510819/1/3/w500.jpg", "560 px: w500, 12 % short")
        eq(sized(still, 640), "https://episodes.metahub.space/tt31510819/1/3/w780.jpg", "640 px")
        eq(sized(still, 1920), "https://episodes.metahub.space/tt31510819/1/3/w1280.jpg", "never the multi-megabyte original")
        eq(sized("https://episodes.metahub.space/tt31510819/1/3/original.jpg", 300),
           "https://episodes.metahub.space/tt31510819/1/3/original.jpg", "a name that is not a width is left alone")
    }

    // MARK: The image proxy

    func testAYTSCoverIsResizedAndReencodedByTheProxy() {
        let cover = ImageProxy.proxied("https://yts.gg/assets/images/movies/project_hail_mary_2026/large-cover.jpg")!
        eq(cover, "https://images.weserv.nl/?url=https%3A//yts.gg/assets/images/movies/project_hail_mary_2026/large-cover.jpg",
           "ImageProxy still writes what it wrote")
        eq(sized(cover, 288), cover + "&w=300&we&output=webp", "a tvOS grid cell (250 pt, 288 px focused): 300 px, WebP")
        eq(sized(cover, 200), cover + "&w=200&we&output=webp", "a small card")
        eq(sized(cover, 150), cover + "&w=160&we&output=webp", "the smallest step")
        eq(sized(cover, 400), cover + "&w=400&we&output=webp", "400 px")
        eq(sized(cover, 528), cover + "&output=webp", "the cover is 500 px wide: nothing to resize from there up, WebP all the same")
        eq(sized(cover, 2000), cover + "&output=webp", "and no enlargement asked")
    }

    func testAProxiedAddressAlreadySizedIsLeftAlone() {
        let chosen = "https://images.weserv.nl/?url=https://yts.gg/assets/images/movies/x/large-cover.jpg&w=120"
        eq(sized(chosen, 400), chosen, "somebody asked for a width")
        let format = "https://images.weserv.nl/?url=https://yts.gg/assets/images/movies/x/large-cover.jpg&output=jpg"
        eq(sized(format, 400), format, "or for a format")
        let background = ImageProxy.proxied("https://yts.gg/assets/images/movies/x/background.jpg")!
        eq(sized(background, 640), background + "&w=640&we&output=webp", "a YTS background is resized like a cover")
        eq(sized(background, 5000), background + "&output=webp", "beyond the last step: no width")
    }

    // MARK: TVMaze

    func testATVMazeOriginalGoesThroughTheProxy() {
        let original = "https://static.tvmaze.com/uploads/images/original_untouched/610/1525272.jpg"
        let medium = "https://static.tvmaze.com/uploads/images/medium_portrait/610/1525272.jpg"
        let proxied = "https://images.weserv.nl/?url=https%3A//static.tvmaze.com/uploads/images/original_untouched/610/1525272.jpg"
        eq(sized(original, 288), proxied + "&w=300&we&output=webp", "a grid poster: 23 KB instead of the original's 600 KB")
        eq(sized(original, 500), proxied + "&w=500&we&output=webp", "500 px")
        eq(sized(medium, 210), medium, "TVMaze's own 210 px poster for a small card")
        eq(sized(medium, 240), medium, "240 px is drawn from 210 px: within the tolerance")
        eq(sized(medium, 400), proxied + "&w=400&we&output=webp", "above it, the original through the proxy")
    }

    func testTVMazeStillsHaveTwoSmallSizes() {
        let medium = "https://static.tvmaze.com/uploads/images/medium_landscape/651/1628596.jpg"
        let large = "https://static.tvmaze.com/uploads/images/large_landscape/651/1628596.jpg"
        let proxied = "https://images.weserv.nl/?url=https%3A//static.tvmaze.com/uploads/images/original_untouched/651/1628596.jpg"
        eq(sized(medium, 250), medium, "250 px: the medium still")
        eq(sized(medium, 400), large, "400 px: the large one")
        eq(sized(large, 300), large, "a large still is not swapped for a smaller one")
        eq(sized(medium, 640), proxied + "&w=640&we&output=webp", "above 400 px: the original, resized")
        eq(sized("https://static.tvmaze.com/uploads/images/other/1/2.jpg", 300),
           "https://static.tvmaze.com/uploads/images/other/1/2.jpg", "an unknown variant is left alone")
    }

    // MARK: TMDB and Amazon

    func testATMDBFileComesInOneOfTheCDNsWidths() {
        let web = "https://image.tmdb.org/t/p/w600_and_h900_bestv2/acYXu4KaDj1NIkMgObnhe4C4a0T.jpg"
        eq(sized(web, 288), "https://image.tmdb.org/t/p/w342/acYXu4KaDj1NIkMgObnhe4C4a0T.jpg", "a grid poster")
        eq(sized(web, 100), "https://image.tmdb.org/t/p/w92/acYXu4KaDj1NIkMgObnhe4C4a0T.jpg", "a thumbnail")
        eq(sized(web, 528), "https://image.tmdb.org/t/p/w500/acYXu4KaDj1NIkMgObnhe4C4a0T.jpg", "528 px")
        eq(sized(web, 1400), "https://image.tmdb.org/t/p/w1280/acYXu4KaDj1NIkMgObnhe4C4a0T.jpg", "1400 px")
        eq(sized(web, 1920), "https://image.tmdb.org/t/p/original/acYXu4KaDj1NIkMgObnhe4C4a0T.jpg", "above 1280: the original")
        // The legacy mapping writes "w1000", a width the CDN answers 400 for.
        eq(sized("https://image.tmdb.org/t/p/w1000/acYXu4KaDj1NIkMgObnhe4C4a0T.jpg", 600),
           "https://image.tmdb.org/t/p/w780/acYXu4KaDj1NIkMgObnhe4C4a0T.jpg", "a width that does not exist becomes one that does")
        eq(sized("https://image.tmdb.org/other/x.jpg", 300), "https://image.tmdb.org/other/x.jpg", "not an image path: left alone")
    }

    func testAnAmazonPosterIsAskedAtTheWidthDrawn() {
        let poster = "https://m.media-amazon.com/images/M/MV5BM2Y2NTM2NjQt@._V1_SX250.jpg"
        eq(sized(poster, 288), poster, "250 px is enough for 288 (15 % short)")
        eq(sized(poster, 500), "https://m.media-amazon.com/images/M/MV5BM2Y2NTM2NjQt@._V1_SX500.jpg", "500 px")
        eq(sized(poster, 150), "https://m.media-amazon.com/images/M/MV5BM2Y2NTM2NjQt@._V1_SX160.jpg", "150 px")
        let cropped = "https://m.media-amazon.com/images/M/MV5B@._V1_QL75_UX380_CR0,0,380,562_.jpg"
        eq(sized(cropped, 500), cropped, "a crop depends on its size: left alone")
    }

    // MARK: Everything else

    func testUnknownAddressesAreReturnedUnchanged() {
        for text in ["https://example.org/poster.jpg", "https://yts.gg/assets/images/movies/x/large-cover.jpg",
                     "file:///tmp/poster.jpg", "https://images.metahub.space/poster/huge/tt1/img",
                     "https://images.metahub.space/other/small/tt1/img", "https://img.youtube.com/vi/abc/hqdefault.jpg"] {
            eq(sized(text, 300), text, "\(text) is left alone")
        }
        let poster = "https://images.metahub.space/poster/medium/tt7526136/img"
        eq(sized(poster, 0), poster, "no width: the address as given")
        eq(sized(poster, -5), poster, "a negative width too")
    }

    func testWhatAnAddressSaysItShows() {
        eq(ArtworkURL.kind(of: url("https://images.metahub.space/poster/small/tt1/img")), .poster, "metahub poster")
        eq(ArtworkURL.kind(of: url("https://live.metahub.space/background/large/tt1/img")), .backdrop, "metahub background")
        eq(ArtworkURL.kind(of: url("https://images.metahub.space/logo/medium/tt1/img")), .logo, "metahub logo")
        eq(ArtworkURL.kind(of: url("https://episodes.metahub.space/tt1/1/2/w780.jpg")), .still, "episode still")
        eq(ArtworkURL.kind(of: url(ImageProxy.proxied("https://yts.gg/assets/images/movies/x/large-cover.jpg")!)), .poster, "YTS cover")
        eq(ArtworkURL.kind(of: url(ImageProxy.proxied("https://yts.gg/assets/images/movies/x/background.jpg")!)), .backdrop, "YTS background")
        eq(ArtworkURL.kind(of: url("https://static.tvmaze.com/uploads/images/medium_portrait/1/2.jpg")), .poster, "TVMaze portrait")
        eq(ArtworkURL.kind(of: url("https://static.tvmaze.com/uploads/images/medium_landscape/1/2.jpg")), .still, "TVMaze landscape")
        eq(ArtworkURL.kind(of: url("https://static.tvmaze.com/uploads/images/original_untouched/1/2.jpg")), .unknown, "a TVMaze original says nothing")
        eq(ArtworkURL.kind(of: url("https://image.tmdb.org/t/p/w600_and_h900_bestv2/a.jpg")), .poster, "the TMDB site's poster crop")
        eq(ArtworkURL.kind(of: url("https://image.tmdb.org/t/p/w780/a.jpg")), .unknown, "a TMDB width says nothing")
        eq(ArtworkURL.kind(of: url("https://example.org/a.jpg")), .unknown, "an unknown host")
    }

    func testWidthAndLongestSide() {
        let poster = url("https://images.metahub.space/poster/small/tt1/img")
        let backdrop = url("https://images.metahub.space/background/small/tt1/img")
        let unknown = url("https://example.org/a.jpg")
        eq(ArtworkURL.pixelWidth(forLongestSide: 600, of: poster), 400, "a poster's longest side is its height")
        eq(ArtworkURL.pixelWidth(forLongestSide: 600, of: backdrop), 600, "a backdrop's is its width")
        eq(ArtworkURL.pixelWidth(forLongestSide: 600, of: unknown), 600, "unknown: the width, to be safe")
        eq(ArtworkURL.longestSide(forPixelWidth: 300, of: poster), 450, "and back")
        eq(ArtworkURL.longestSide(forPixelWidth: 300, of: backdrop), 300, "a backdrop 300 px wide")
        eq(ArtworkURL.longestSide(forPixelWidth: 300, of: unknown), 450, "unknown: it may be a poster")
    }

    // MARK: Sources

    func testALoadTriesTheSizedVariantThenTheAddressAsGiven() {
        let poster = url("https://images.metahub.space/poster/medium/tt7526136/img")
        let small = url("https://images.metahub.space/poster/small/tt7526136/img")
        eq(ArtworkURL.sources(for: poster, pixelWidth: 288), [[small, poster]], "the variant, then the address as given")
        eq(ArtworkURL.sources(for: small, pixelWidth: 288), [[small]], "the same address is not tried twice")
        eq(ArtworkURL.sources(for: poster, pixelWidth: nil), [[poster]], "no width: the address as given")
        let unknown = url("https://example.org/poster.jpg")
        eq(ArtworkURL.sources(for: unknown, pixelWidth: 288), [[unknown]], "an unknown host has one address")
    }

    func testAYTSCoverFallsBackToMetahubThenToItsMediumCover() {
        let cover = ImageProxy.proxied("https://yts.gg/assets/images/movies/national_theatre_live_prima_facie_2022/large-cover.jpg")!
        let background = ImageProxy.proxied("https://yts.gg/assets/images/movies/national_theatre_live_prima_facie_2022/background.jpg")!
        let medium = url(cover.replacingOccurrences(of: "large-cover", with: "medium-cover"))
        eq(ArtworkURL.sources(for: url(cover), pixelWidth: 288), [[url(cover + "&w=300&we&output=webp"), url(cover)], [medium]],
           "nothing registered: the medium cover of the same film is the second source")

        ArtworkAlternates.register(imdbID: "tt21093976", poster: cover, backdrop: background)
        eq(ArtworkURL.sources(for: url(cover), pixelWidth: 288),
           [[url(cover + "&w=300&we&output=webp"), url(cover)],
            [url("https://images.metahub.space/poster/small/tt21093976/img"), url("https://images.metahub.space/poster/medium/tt21093976/img")],
            [medium]],
           "registered by the model: metahub's poster by IMDb id, sized too, before the 230 px medium cover")
        eq(ArtworkURL.sources(for: url(background), pixelWidth: 1000),
           [[url(background + "&w=1000&we&output=webp"), url(background)],
            [url("https://images.metahub.space/background/medium/tt21093976/img")]],
           "the backdrop has metahub's too")

        let other = url("https://example.org/again.jpg")
        eq(ArtworkURL.sources(for: url(cover), pixelWidth: 288, alternates: [other, url(cover)]).count, 4,
           "the caller's own alternates come after the registered ones; one already listed is not repeated")
        eq(ArtworkURL.sources(for: url(cover), pixelWidth: 288, alternates: [other])[2], [other], "in that order")
    }

    func testAnOriginalBehindTheProxyIsASourceOfItsOwn() {
        let original = url("https://static.tvmaze.com/uploads/images/original_untouched/610/1525272.jpg")
        let sized = ArtworkURL.sized(original, pixelWidth: 288)
        eq(ArtworkURL.sources(for: original, pixelWidth: 288), [[sized], [original]],
           "the proxy's resized copy, and TVMaze's own file beside it when the proxy is slow: two hosts, two sources")
        let medium = url("https://static.tvmaze.com/uploads/images/medium_portrait/610/1525272.jpg")
        eq(ArtworkURL.sources(for: medium, pixelWidth: 400), [[ArtworkURL.sized(medium, pixelWidth: 400)], [medium]],
           "the same for a small TVMaze poster asked larger")
        eq(ArtworkURL.sources(for: medium, pixelWidth: 200), [[medium]], "and one address when TVMaze's own size does")
        let still = url("https://static.tvmaze.com/uploads/images/medium_landscape/651/1628596.jpg")
        eq(ArtworkURL.sources(for: still, pixelWidth: 400),
           [[url("https://static.tvmaze.com/uploads/images/large_landscape/651/1628596.jpg"), still]],
           "two sizes on the same host stay one source: the second is tried when the first fails")
    }

    func testOnlyAddressesThatNeedOneGetAnAlternate() {
        let metahub = "https://images.metahub.space/poster/medium/tt7526136/img"
        ArtworkAlternates.register(imdbID: "tt7526136", poster: metahub)
        check(ArtworkAlternates.alternates(for: url(metahub)).isEmpty, "metahub's own poster has no alternate")
        ArtworkAlternates.register(imdbID: "", poster: "https://example.org/a.jpg")
        ArtworkAlternates.register(imdbID: "1234", poster: "https://example.org/a.jpg")
        check(ArtworkAlternates.alternates(for: url("https://example.org/a.jpg")).isEmpty, "no IMDb id, no alternate")
        ArtworkAlternates.register(imdbID: "tt1", poster: nil, backdrop: nil)
        ArtworkAlternates.register([url("https://example.org/a.jpg")], for: url("https://example.org/a.jpg"))
        check(ArtworkAlternates.alternates(for: url("https://example.org/a.jpg")).isEmpty, "an address is not its own alternate")
    }

    func testTheOldestRegistrationsGoFirst() {
        let saved = ArtworkAlternates.capacity
        ArtworkAlternates.capacity = 10
        defer { ArtworkAlternates.capacity = saved; ArtworkAlternates.removeAll() }
        for index in 0..<11 {
            ArtworkAlternates.register([url("https://example.org/alt\(index).jpg")], for: url("https://example.org/\(index).jpg"))
        }
        check(ArtworkAlternates.alternates(for: url("https://example.org/0.jpg")).isEmpty, "the first ones were dropped")
        check(ArtworkAlternates.alternates(for: url("https://example.org/5.jpg")).isEmpty, "more than half of them, at once")
        eq(ArtworkAlternates.alternates(for: url("https://example.org/10.jpg")), [url("https://example.org/alt10.jpg")], "the newest stay")
        eq(ArtworkAlternates.alternates(for: url("https://example.org/6.jpg")), [url("https://example.org/alt6.jpg")], "down to the bound's half")
    }

    func testARouteIsAHostOrTheProxyAndTheHostBehindIt() {
        eq(ArtworkURL.route(of: url("https://images.metahub.space/poster/small/tt1/img")), "images.metahub.space", "a host")
        eq(ArtworkURL.route(of: url(ImageProxy.proxied("https://yts.gg/assets/images/movies/x/large-cover.jpg")!)),
           "images.weserv.nl>yts.gg", "YTS behind the proxy")
        eq(ArtworkURL.route(of: ArtworkURL.sized(url("https://static.tvmaze.com/uploads/images/original_untouched/1/2.jpg"), pixelWidth: 300)),
           "images.weserv.nl>static.tvmaze.com", "TVMaze behind the proxy: another route, a sized address included")
    }

    // MARK: The models register their alternates

    func testAYTSMovieRegistersMetahubsPosterForItsCover() {
        let movie = Movie(yts: [
            "imdb_code": "tt21093976", "title": "National Theatre Live: Prima Facie", "year": 2022,
            "large_cover_image": "https://yts.gg/assets/images/movies/national_theatre_live_prima_facie_2022/large-cover.jpg",
            "background_image_original": "https://yts.gg/assets/images/movies/national_theatre_live_prima_facie_2022/background.jpg",
        ])
        guard let cover = movie?.largeCoverImage.flatMap(URL.init(string:)) else { return XCTFail("no cover") }
        eq(ArtworkAlternates.alternates(for: cover), [url("https://images.metahub.space/poster/medium/tt21093976/img")],
           "the film's poster by IMDb id")
        eq(ArtworkURL.sources(for: cover, pixelWidth: 288).count, 3, "the cover, metahub's poster, the medium cover")
    }
}
