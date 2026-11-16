//
//  HomeCollageTests.swift
//  PopcornTimeTests
//
//  The test that turns away a backdrop made of tiles (HomeCollage.swift, an Apple TV source
//  the bundle compiles), run on backdrops recorded from metahub on 2026-11-15
//  (Fixtures/Collage, `background/large`, scaled to 320 × 180: the test measures 160 × 90),
//  and on pictures drawn here. Before the recorded set was chosen, the same test went over
//  524 backdrops of the Home's lists: The Invite was the only one it turned away.
//

import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class HomeCollageTests: CheckedTestCase {

    private func recorded(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> CGImage? {
        let url = Fixtures.url("Collage/\(name).jpg")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("missing fixture Collage/\(name).jpg", file: file, line: line)
            return nil
        }
        return image
    }

    /// The Invite's large backdrop: four portraits on a cream matte. Its three
    /// gutters are found where they are (a quarter of the width apart).
    func testTheInvitesMontageIsTurnedAway() throws {
        let image = try XCTUnwrap(recorded("collage-the-invite-tt14173636"))
        XCTAssertTrue(HomeCollage.isCollage(image))
        let pixels = try XCTUnwrap(HomeCollage.thumbnail(image))
        let gutters = HomeCollage.gutters(in: pixels, width: HomeCollage.width, height: HomeCollage.height)
        XCTAssertEqual(gutters.count, 3)
        let centres = gutters.map { Double($0.lowerBound + $0.upperBound) / 2 / Double(HomeCollage.width) }
        for (centre, expected) in zip(centres, [0.25, 0.5, 0.75]) {
            XCTAssertEqual(centre, expected, accuracy: 0.02)
        }
    }

    /// Pictures that are kept: a frame of the same film (metahub's medium
    /// size), dark pictures, upright lines that are part of the picture (a door
    /// frame, panels), a key art of faces side by side without a matte, a
    /// contact sheet, a white ground. And a montage on black (Heist), kept on
    /// purpose: its matte is as dark as the veils over it.
    func testFramesAndKeyArtAreKept() throws {
        let kept = ["frame-the-invite-medium-tt14173636", "dark-tiles-heist-tt0252503", "faces-no-gutter-tt4122068",
                    "mostly-black-tt49815439", "room-panels-tt36329495", "door-frame-tt36586020",
                    "contact-sheet-tt39307872", "dark-edge-tt45114341", "white-ground-tt0109830"]
        for name in kept {
            let image = try XCTUnwrap(recorded(name))
            XCTAssertFalse(HomeCollage.isCollage(image), "\(name) taken for a montage")
        }
    }

    /// Drawn pictures: tiles of noise on a matte of any colour are a montage
    /// from two gutters on; one gutter (a split screen) is not; nor is noise
    /// with a wide dark band, nor a flat picture.
    func testDrawnPictures() throws {
        XCTAssertTrue(HomeCollage.isCollage(try XCTUnwrap(drawn(tiles: 4, matte: (240, 232, 220)))))
        XCTAssertTrue(HomeCollage.isCollage(try XCTUnwrap(drawn(tiles: 3, matte: (0, 0, 0)))))
        XCTAssertTrue(HomeCollage.isCollage(try XCTUnwrap(drawn(tiles: 5, matte: (30, 30, 120)))))
        XCTAssertFalse(HomeCollage.isCollage(try XCTUnwrap(drawn(tiles: 2, matte: (0, 0, 0)))))
        XCTAssertFalse(HomeCollage.isCollage(try XCTUnwrap(drawn(tiles: 1, matte: (0, 0, 0)))))
        XCTAssertFalse(HomeCollage.isCollage(try XCTUnwrap(drawn(tiles: 1, matte: (0, 0, 0), darkBand: true))))
        XCTAssertFalse(HomeCollage.isCollage(try XCTUnwrap(flat(gray: 20))))
        XCTAssertFalse(HomeCollage.isCollage(try XCTUnwrap(flat(gray: 235))))
    }

    /// 1280 × 720 noise cut in `tiles` upright tiles by gutters of 1.5 % of
    /// the width in `matte`; `darkBand` blacks out a fifth of the width.
    private func drawn(tiles: Int, matte: (UInt8, UInt8, UInt8), darkBand: Bool = false) -> CGImage? {
        let width = 1280, height = 720
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let gutter = Int(Double(width) * 0.015)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let nearCut = tiles > 1 && (1..<tiles).contains { abs(x - $0 * width / tiles) <= gutter / 2 }
                let inBand = darkBand && x > width * 2 / 5 && x < width * 3 / 5
                if nearCut {
                    (bytes[index], bytes[index + 1], bytes[index + 2]) = matte
                } else if inBand {
                    (bytes[index], bytes[index + 1], bytes[index + 2]) = (2, 2, 2)
                } else {
                    // Coarse noise (blocks of 8 × 8), like the texture of a picture.
                    var hash = UInt64(x / 8) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(y / 8) &* 0xC2B2_AE3D_27D4_EB4F
                    hash ^= hash >> 29
                    hash = hash &* 0xBF58_476D_1CE4_E5B9
                    hash ^= hash >> 32
                    bytes[index] = UInt8(truncatingIfNeeded: hash)
                    bytes[index + 1] = UInt8(truncatingIfNeeded: hash >> 8)
                    bytes[index + 2] = UInt8(truncatingIfNeeded: hash >> 16)
                }
                bytes[index + 3] = 255
            }
        }
        return image(bytes, width: width, height: height)
    }

    private func flat(gray: UInt8) -> CGImage? {
        let width = 640, height = 360
        var bytes = [UInt8](repeating: gray, count: width * height * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        return image(bytes, width: width, height: height)
    }

    private func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
