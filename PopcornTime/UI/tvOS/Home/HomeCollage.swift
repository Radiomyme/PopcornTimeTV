// HomeCollage.swift — tells a backdrop made of tiles from a picture.
//
// Some backdrops of the catalogue are not a frame of the film but a montage:
// four portraits side by side on a cream matte ("The Invite", metahub's
// `background/large`, November 2026). Drawn full screen under the Home's
// and the title page's veils, the matte turns into dark gutters between
// the faces and a pale band at the top. The Home and the title page ask
// this test of every backdrop they decode, and take the next picture when
// it says yes (another source's backdrop, else the poster as ambient light).
//
// Pure Core Graphics: compiled into the unit tests, which run it on
// recorded backdrops (`HomeCollageTests`).
import CoreGraphics

enum HomeCollage {

    /// The size the picture is measured at: a 16:9 thumbnail. A gutter of
    /// 1 % of the width is still a column of its own.
    static let width = 160
    static let height = 90

    /// Two pixels of one column within this of each other (0–255, per
    /// channel) are the same flat colour.
    static let flatTolerance = 16
    /// A matte column is flat over this share of its height at least.
    static let gutterCoverage = 0.97
    /// The picture on both sides of a band is busy: flat over less than
    /// this share of its height (a dark area is not a gutter).
    static let busyCoverage = 0.6
    /// A band is this share of the width at most: a matte between tiles,
    /// not a dark half of the picture.
    static let gutterMaxWidth = 0.06
    /// Tiles on both sides, not the picture's own margins.
    static let edgeMargin = 0.04
    /// Two gutters are a tile apart at least.
    static let tileMinWidth = 0.12

    /// True when `image` is a montage: at least two narrow upright bands of
    /// one flat colour — the same colour — running from top to bottom
    /// inside the picture, with picture on both sides of each and a tile's
    /// width between them (the matte between tiles). One band is a split
    /// screen or a door frame, and stays; a night picture's black is wide
    /// or has no picture right beside it.
    static func isCollage(_ image: CGImage) -> Bool {
        guard let pixels = thumbnail(image) else { return false }
        return gutters(in: pixels, width: width, height: height).count >= 2
    }

    /// The matte bands found in an RGBA thumbnail (rows top to bottom), as
    /// ranges of columns.
    static func gutters(in pixels: [UInt8], width: Int, height: Int) -> [ClosedRange<Int>] {
        guard width > 4, height > 0, pixels.count >= width * height * 4 else { return [] }
        let columns = (0..<width).map { column($0, in: pixels, width: width, height: height) }
        let margin = Int((Double(width) * edgeMargin).rounded(.up))
        let widest = max(1, Int(Double(width) * gutterMaxWidth))
        let tile = Int(Double(width) * tileMinWidth)
        var bands: [(range: ClosedRange<Int>, colour: [Int])] = []
        var x = 0
        while x < width {
            guard columns[x].flatness >= gutterCoverage else { x += 1; continue }
            var end = x
            while end + 1 < width, columns[end + 1].flatness >= gutterCoverage { end += 1 }
            defer { x = end + 1 }
            // Inside the picture, narrow, picture on both sides (two columns
            // off: the one beside it is half matte once scaled down).
            guard x >= margin, end < width - margin, end - x + 1 <= widest,
                  x - 2 >= 0, end + 2 < width,
                  columns[x - 2].flatness < busyCoverage, columns[end + 2].flatness < busyCoverage else { continue }
            let colour = columns[(x + end) / 2].colour
            // One matte: the colour of the first band.
            if let first = bands.first, !close(colour, first.colour, tolerance: flatTolerance * 2) { continue }
            // A tile between two bands.
            if let last = bands.last, x - last.range.upperBound < tile { continue }
            bands.append((x...end, colour))
        }
        return bands.map(\.range)
    }

    /// A column's colour (its median, per channel) and the share of its
    /// pixels within `flatTolerance` of it.
    private static func column(_ x: Int, in pixels: [UInt8], width: Int, height: Int) -> (colour: [Int], flatness: Double) {
        var channels = [[Int]](repeating: [], count: 3)
        for y in 0..<height {
            let index = (y * width + x) * 4
            for c in 0..<3 { channels[c].append(Int(pixels[index + c])) }
        }
        let median = channels.map { $0.sorted()[height / 2] }
        var matching = 0
        for y in 0..<height {
            let index = (y * width + x) * 4
            if abs(Int(pixels[index]) - median[0]) <= flatTolerance,
               abs(Int(pixels[index + 1]) - median[1]) <= flatTolerance,
               abs(Int(pixels[index + 2]) - median[2]) <= flatTolerance {
                matching += 1
            }
        }
        return (median, Double(matching) / Double(height))
    }

    private static func close(_ a: [Int], _ b: [Int], tolerance: Int) -> Bool {
        return zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// The picture drawn at `width` × `height`, RGBA, rows from the top.
    static func thumbnail(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
