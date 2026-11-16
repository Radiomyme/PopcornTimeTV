//
//  ArtworkURL.swift
//  PopcornKit
//
//  The address of an artwork at the size it is drawn. The sources list one
//  size per image (YTS: the 500 px cover; TVMaze: its untouched original, up
//  to several megabytes; Cinemeta: metahub's small poster), and every screen
//  used to download that one whatever it drew. Each host has its own way of
//  serving another size; this file knows them, and nothing else: no network,
//  no state. Measured on real addresses in November 2026 (the table is in
//  the 5.3.0 notes of the images work):
//
//    metahub poster      small 300 px (31 KB) · medium 500 (91 KB) · large 780 (182 KB)
//    metahub background  small 480–780 (31 KB) · medium 1280 (205 KB) · large 1920–3840 (994 KB)
//    metahub logo        small 300 · medium 780 · large 1040 (often one 800 × 310 file for the three)
//    metahub still       w300 (7 KB) · w500 (16 KB) · w780 (33 KB) · w1280 (75 KB)
//    YTS cover (proxy)   500 px JPEG as listed (79 KB) · w=300 WebP (26 KB) · w=500 WebP (53 KB)
//    TVMaze              medium_portrait 210 (18 KB) · original 680–2000 (606 KB, up to 4.8 MB)
//                        · original through the proxy, w=300 WebP (23 KB)
//    TMDB CDN            w92 … w1280, original
//
//  An address this file does not know is returned unchanged.
//

import Foundation
import CoreGraphics

public enum ArtworkURL {

    // MARK: - Kinds

    /// What an address shows, when the address says so.
    public enum Kind: Equatable, Sendable {
        /// A 2:3 poster.
        case poster
        /// A 16:9 backdrop.
        case backdrop
        /// A 16:9 episode still.
        case still
        /// A transparent title logo (wide; the ratio varies).
        case logo
        /// The address does not say (a TVMaze original, a TMDB file…).
        case unknown

        /// Width / height, nil when it varies.
        public var aspectRatio: CGFloat? {
            switch self {
            case .poster: return 2.0 / 3.0
            case .backdrop, .still: return 16.0 / 9.0
            case .logo, .unknown: return nil
            }
        }
    }

    /// A variant may be this much narrower than the width asked for: drawn
    /// at most 18 % larger than its pixels, which nobody sees on a poster,
    /// where the next size up weighs twice as much (metahub: 500 → 780 px).
    public static let coverage: CGFloat = 0.85

    public static func kind(of url: URL) -> Kind {
        guard let host = url.host?.lowercased() else { return .unknown }
        if let metahub = Metahub(url) {
            switch metahub.kind {
            case "poster": return .poster
            case "background": return .backdrop
            case "logo": return .logo
            default: return .unknown
            }
        }
        if host == episodesHost { return .still }
        if let proxied = Proxied(url, sized: true) { return kind(ofFile: proxied.inner) }
        if host == tvmazeHost { return kind(ofFile: url.path) }
        if host == tmdbHost, let tmdb = TMDB(url) { return tmdb.kind }
        return .unknown
    }

    /// The kind a file's own name gives away (YTS covers, TVMaze variants).
    private static func kind(ofFile path: String) -> Kind {
        if path.hasSuffix("-cover.jpg") || path.contains("_portrait/") { return .poster }
        if path.hasSuffix("/background.jpg") { return .backdrop }
        if path.contains("_landscape/") { return .still }
        return .unknown
    }

    /// The pixel width of an image of this kind whose longest side is
    /// `longestSide` (a poster's longest side is its height).
    public static func pixelWidth(forLongestSide longestSide: CGFloat, of url: URL) -> CGFloat {
        kind(of: url) == .poster ? (longestSide * 2 / 3).rounded(.up) : longestSide
    }

    /// The longest side to decode for an image drawn `pixelWidth` wide. An
    /// address that does not say what it shows may be a poster: its height.
    public static func longestSide(forPixelWidth pixelWidth: CGFloat, of url: URL) -> CGFloat {
        switch kind(of: url) {
        case .poster, .unknown: return (pixelWidth * 1.5).rounded(.up)
        case .backdrop, .still, .logo: return pixelWidth
        }
    }

    // MARK: - Sizing

    /// The smallest variant of `url` that covers `pixelWidth` (the width the
    /// image is drawn at, in pixels), or `url` itself when its host serves
    /// one size, is unknown, or was already asked for a size.
    public static func sized(_ url: URL, pixelWidth: CGFloat) -> URL {
        guard pixelWidth > 0, let host = url.host?.lowercased() else { return url }
        let wanted = pixelWidth * coverage

        if let metahub = Metahub(url) {
            return metahub.url(size: metahub.size(covering: wanted)) ?? url
        }
        if host == episodesHost {
            return episodeStill(url, covering: wanted) ?? url
        }
        if let proxied = Proxied(url) {
            return proxied.sized(covering: wanted) ?? url
        }
        if host == tvmazeHost {
            return tvmaze(url, covering: wanted) ?? url
        }
        if host == tmdbHost, let tmdb = TMDB(url) {
            return tmdb.url(covering: wanted) ?? url
        }
        if host.hasSuffix(amazonHostSuffix) {
            return amazon(url, covering: wanted) ?? url
        }
        return url
    }

    /// The smallest of `widths` (ascending) that reaches `wanted`, else the
    /// largest.
    static func step(_ widths: [Int], covering wanted: CGFloat) -> Int {
        widths.first { CGFloat($0) >= wanted } ?? widths.last ?? 0
    }

    // MARK: - Fallbacks

    /// What to load for `url` drawn `pixelWidth` wide, in order. Each inner
    /// list is one source: its addresses are tried one after the other when
    /// the previous one fails. The next source is started when the previous
    /// one fails or stays silent (see `ArtworkLoader`).
    ///
    /// The sized variant comes first, then the address as given (a 404 on
    /// one size must not leave a hole): in the same source when both are on
    /// the same host — one that says nothing for a size will say nothing for
    /// the other — and as a source of its own when the variant goes through
    /// the proxy and the address does not (a TVMaze original): the proxy's
    /// first resize of a large file can take seconds, and the original then
    /// starts beside it. Then the other pictures of the same title: the ones
    /// registered in `ArtworkAlternates`, the ones passed here, and YTS's
    /// medium cover when its large one does not answer.
    public static func sources(for url: URL, pixelWidth: CGFloat?, alternates: [URL] = []) -> [[URL]] {
        var seen = Set<URL>()
        var all: [[URL]] = []
        func add(_ address: URL) {
            var variant: URL?
            if let pixelWidth, pixelWidth > 0 {
                let sized = sized(address, pixelWidth: pixelWidth)
                if seen.insert(sized).inserted { variant = sized }
            }
            let given = seen.insert(address).inserted ? address : nil
            switch (variant, given) {
            case let (variant?, given?) where route(of: variant) != route(of: given):
                all.append([variant])
                all.append([given])
            case let (variant?, given?):
                all.append([variant, given])
            case let (only?, nil), let (nil, only?):
                all.append([only])
            case (nil, nil):
                break
            }
        }
        add(url)
        for alternate in ArtworkAlternates.alternates(for: url) + alternates {
            add(alternate)
        }
        if let proxied = Proxied(url), let medium = proxied.mediumCover, seen.insert(medium).inserted {
            all.append([medium])
        }
        return all
    }

    /// What a failure of `url` says about: its host, or for a proxied
    /// address the proxy and the host behind it (the proxy answers for YTS
    /// and for TVMaze, and one of them failing says nothing of the other).
    public static func route(of url: URL) -> String {
        let host = url.host?.lowercased() ?? url.scheme ?? ""
        if let proxied = Proxied(url, sized: true), let inner = proxied.innerHost {
            return host + ">" + inner
        }
        return host
    }

    // MARK: - metahub

    private static let episodesHost = "episodes.metahub.space"

    /// `https://images.metahub.space/<kind>/<size>/<imdb id>/img` (and the
    /// same on `live.metahub.space`, where the first host redirects for the
    /// images it has to make).
    private struct Metahub {
        let scheme: String
        let host: String
        let kind: String
        let id: String

        init?(_ url: URL) {
            guard let host = url.host?.lowercased(), host == "images.metahub.space" || host == "live.metahub.space" else { return nil }
            let parts = url.pathComponents
            guard parts.count == 5, parts[4] == "img", Self.widths[parts[1]] != nil,
                  ["small", "medium", "large"].contains(parts[2]) else { return nil }
            self.scheme = url.scheme ?? "https"
            self.host = host
            self.kind = parts[1]
            self.id = parts[3]
        }

        /// The least each size is wide, measured (a backdrop's "small" is 480
        /// or 780 px, its "large" 1920 or 3840).
        static let widths: [String: [(size: String, width: Int)]] = [
            "poster": [("small", 300), ("medium", 500), ("large", 780)],
            "background": [("small", 480), ("medium", 1280), ("large", 1920)],
            "logo": [("small", 300), ("medium", 780), ("large", 1040)],
        ]

        func size(covering wanted: CGFloat) -> String {
            let sizes = Self.widths[kind] ?? []
            return (sizes.first { CGFloat($0.width) >= wanted } ?? sizes.last)?.size ?? "medium"
        }

        func url(size: String) -> URL? {
            URL(string: "\(scheme)://\(host)/\(kind)/\(size)/\(id)/img")
        }
    }

    /// `https://episodes.metahub.space/<show>/<season>/<episode>/w780.jpg`:
    /// the file name is the width (a redirect to the TMDB CDN).
    private static func episodeStill(_ url: URL, covering wanted: CGFloat) -> URL? {
        let name = url.lastPathComponent
        guard name.hasPrefix("w"), name.hasSuffix(".jpg"), Int(name.dropFirst().dropLast(4)) != nil else { return nil }
        let width = step([300, 500, 780, 1280], covering: wanted)
        return url.deletingLastPathComponent().appendingPathComponent("w\(width).jpg")
    }

    // MARK: - The image proxy (images.weserv.nl)

    /// The widths asked of the proxy: a few steps (metahub's and the TMDB
    /// CDN's among them), so that two screens that draw a poster a few
    /// pixels apart share one download.
    private static let proxyWidths = [160, 200, 300, 400, 500, 640, 780, 1000, 1280, 1600, 1920, 2560, 3840]

    /// `https://images.weserv.nl/?url=<address>` as `ImageProxy` writes it.
    private struct Proxied {
        let text: String
        /// The proxied address, percent-encoded as it was found.
        let inner: String

        /// `sized`: also an address that already asks for a size or a
        /// format (to read what it shows and where it goes; such an address
        /// is never sized again: somebody chose).
        init?(_ url: URL, sized: Bool = false) {
            guard let host = url.host?.lowercased(), host == "images.weserv.nl" || host == "wsrv.nl",
                  url.fragment == nil else { return nil }
            let text = url.absoluteString
            guard let query = text.range(of: "?") else { return nil }
            let items = text[query.upperBound...].split(separator: "&", omittingEmptySubsequences: true)
            guard let address = items.first(where: { $0.hasPrefix("url=") }) else { return nil }
            let chosen = items.contains { $0.hasPrefix("w=") || $0.hasPrefix("h=") || $0.hasPrefix("output=") }
            guard sized || !chosen else { return nil }
            self.text = text
            self.inner = String(address.dropFirst(4))
        }

        var innerHost: String? {
            let decoded = inner.removingPercentEncoding ?? inner
            if let host = URL(string: decoded)?.host { return host.lowercased() }
            // weserv also takes an address without its scheme.
            return URL(string: "https://" + decoded)?.host?.lowercased()
        }

        /// The proxy resizes (never enlarges: `we`) and re-encodes as WebP,
        /// a third lighter than the JPEG at the same size.
        func sized(covering wanted: CGFloat) -> URL? {
            var width: Int? = ArtworkURL.step(ArtworkURL.proxyWidths, covering: wanted)
            if CGFloat(ArtworkURL.proxyWidths.last ?? 0) < wanted { width = nil }
            // YTS's large cover is 500 px wide: nothing to resize from there up.
            if inner.hasSuffix("/large-cover.jpg"), let asked = width, asked >= 500 { width = nil }
            let size = width.map { "&w=\($0)&we" } ?? ""
            return URL(string: text + size + "&output=webp")
        }

        /// YTS's medium cover (230 × 345), for a large one that does not
        /// answer: the proxy only has what it once fetched, and half of the
        /// older films' large covers never come while their medium ones do.
        var mediumCover: URL? {
            guard inner.hasSuffix("/large-cover.jpg") else { return nil }
            return URL(string: text.replacingOccurrences(of: "/large-cover.jpg", with: "/medium-cover.jpg"))
        }
    }

    /// `address` through the proxy, `width` pixels wide, as WebP.
    private static func proxy(_ address: String, width: Int) -> URL? {
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? address
        return URL(string: "https://images.weserv.nl/?url=\(encoded)&w=\(width)&we&output=webp")
    }

    // MARK: - TVMaze

    private static let tvmazeHost = "static.tvmaze.com"

    /// `https://static.tvmaze.com/uploads/images/<variant>/<folder>/<file>`.
    /// TVMaze's own sizes are small (210 px posters, 250 and 400 px stills)
    /// and its originals are whatever was uploaded: beyond the small sizes
    /// the original goes through the proxy, which resizes it.
    private static func tvmaze(_ url: URL, covering wanted: CGFloat) -> URL? {
        let text = url.absoluteString
        let variants = ["medium_portrait", "medium_landscape", "large_landscape", "original_untouched"]
        guard let variant = variants.first(where: { text.contains("/uploads/images/\($0)/") }) else { return nil }
        func swapped(_ other: String) -> String {
            text.replacingOccurrences(of: "/uploads/images/\(variant)/", with: "/uploads/images/\(other)/")
        }
        switch variant {
        case "medium_portrait" where wanted <= 210:
            return url
        case "medium_landscape" where wanted <= 250, "large_landscape" where wanted <= 400:
            return url
        case "medium_landscape" where wanted <= 400:
            return URL(string: swapped("large_landscape"))
        default:
            if CGFloat(proxyWidths.last ?? 0) < wanted { return URL(string: swapped("original_untouched")) }
            return proxy(swapped("original_untouched"), width: step(proxyWidths, covering: wanted))
        }
    }

    // MARK: - TMDB's image CDN

    private static let tmdbHost = "image.tmdb.org"

    /// `https://image.tmdb.org/t/p/<size>/<file>`: the size is `w<width>`,
    /// `original`, or the web site's `w600_and_h900_bestv2`. The CDN needs
    /// no key and answers 400 for a width it does not have (`w1000`).
    private struct TMDB {
        let prefix: String
        let token: String
        let file: String

        init?(_ url: URL) {
            let parts = url.pathComponents
            guard parts.count == 5, parts[1] == "t", parts[2] == "p" else { return nil }
            self.prefix = "\(url.scheme ?? "https")://\(url.host ?? ArtworkURL.tmdbHost)/t/p/"
            self.token = parts[3]
            self.file = parts[4]
        }

        var kind: Kind {
            // "w600_and_h900_bestv2": the web site's poster crops.
            let numbers = token.split(separator: "_").compactMap { part -> Int? in
                guard let first = part.first, first == "w" || first == "h" else { return nil }
                return Int(part.dropFirst())
            }
            guard token.contains("_and_h"), numbers.count == 2 else { return .unknown }
            return numbers[0] < numbers[1] ? .poster : .unknown
        }

        func url(covering wanted: CGFloat) -> URL? {
            let widths = [92, 154, 185, 342, 500, 780, 1280]
            let size = CGFloat(widths.last ?? 0) < wanted ? "original" : "w\(ArtworkURL.step(widths, covering: wanted))"
            return URL(string: prefix + size + "/" + file)
        }
    }

    // MARK: - Amazon (some Cinemeta posters)

    private static let amazonHostSuffix = "media-amazon.com"

    /// `https://m.media-amazon.com/images/M/<id>._V1_SX250.jpg`: `SX` is the
    /// width, any number (never more than the original's). Only that plain
    /// form is rewritten: the others carry crops that depend on the size.
    private static func amazon(_ url: URL, covering wanted: CGFloat) -> URL? {
        let text = url.absoluteString
        guard let marker = text.range(of: "._V1_SX", options: .backwards),
              let dot = text[marker.upperBound...].firstIndex(of: "."),
              Int(text[marker.upperBound..<dot]) != nil else { return nil }
        let width = step([160, 250, 300, 400, 500, 640, 780, 1000], covering: wanted)
        return URL(string: String(text[..<marker.upperBound]) + "\(width)" + String(text[dot...]))
    }
}

// MARK: - Other pictures of the same title

/// Another address for the same artwork, for the ones whose host does not
/// always answer: a YTS cover is known by its file only, and the poster of
/// the same film by IMDb id (metahub) is another address altogether. The
/// models register it when they are made, so that a view given the cover's
/// address alone still has somewhere else to go.
public enum ArtworkAlternates {

    private static let lock = NSLock()
    private static var table: [URL: [URL]] = [:]
    private static var order: [URL] = []
    /// A few screens of every grid: the oldest registrations go first.
    static var capacity = 6000

    public static func register(_ alternates: [URL], for primary: URL) {
        let alternates = alternates.filter { $0 != primary }
        guard !alternates.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if table.updateValue(alternates, forKey: primary) == nil {
            order.append(primary)
            if order.count > capacity {
                let dropped = order.prefix(order.count - capacity / 2)
                dropped.forEach { table[$0] = nil }
                order.removeFirst(dropped.count)
            }
        }
    }

    /// A title's poster and backdrop as its source lists them: metahub's by
    /// IMDb id become their alternates (nothing to do for the ones that are
    /// metahub's already).
    public static func register(imdbID: String, poster: String?, backdrop: String? = nil) {
        guard imdbID.hasPrefix("tt"), imdbID.count > 2 else { return }
        func note(_ address: String?, _ kind: String) {
            guard let address, let primary = URL(string: address), let host = primary.host?.lowercased(),
                  !host.hasSuffix("metahub.space"),
                  let alternate = URL(string: "https://images.metahub.space/\(kind)/\(imdbID)/img") else { return }
            register([alternate], for: primary)
        }
        note(poster, "poster/medium")
        note(backdrop, "background/medium")
    }

    public static func alternates(for primary: URL) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return table[primary] ?? []
    }

    /// For the tests.
    static func removeAll() {
        lock.lock(); defer { lock.unlock() }
        table.removeAll()
        order.removeAll()
    }
}
