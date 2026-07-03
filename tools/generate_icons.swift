#!/usr/bin/env swift

// Re-runnable icon generator for PopcornTime.
//
// Source of truth: a single hand-designed master PNG provided by the user
// (see `MASTER_PATH` below). The script:
//   • Resamples the master into every iOS / iPadOS / Mac (Designed for iPad)
//     size required by AppIcon.appiconset (20pt → 1024pt at @1x/@2x/@3x).
//   • Builds the tvOS 3-D parallax brandassets — a solid background layer
//     plus the master on transparent canvas as the front layer.
//   • Renders the Top Shelf banners (1920×720 + 2320×720) with the icon on
//     the left and the "Popcorn Time" wordmark on the right.
//
// Re-run after design tweaks:  swift tools/generate_icons.swift
//
// SwiftUI's `ImageRenderer` (macOS 13+) handles the rasterisation. The
// master PNG itself is loaded via `NSImage` and drawn into the rendered
// scenes at full resolution, so the output keeps the source image's
// fidelity (highlights, transparency, gloss).

import SwiftUI
import AppKit

// MARK: - Master image

/// Master image — the user's hand-designed 3-D glass / liquid-metal popcorn
/// bucket. Square, ≥1024×1024, with transparent background where needed.
/// SwiftUI structs can't capture script-level `let`s, so we hold the loaded
/// `NSImage` in a class that any view can read at render time.
final class MasterImageHolder {
    static let shared = MasterImageHolder()
    let image: NSImage
    private init() {
        // Prefer the transparent-background version (the user manually
        // removed the baked-in red gradient so the popcorn motif blends
        // with whatever backdrop we composite under it). Fall back to the
        // older filled version if the transparent one isn't there.
        let candidates = [
            "~/Desktop/popcorn-time-logo-transp.png",
            "~/Desktop/popcorn-time-logo.png",
        ].map { ($0 as NSString).expandingTildeInPath }
        guard let path = candidates.first(where: FileManager.default.fileExists(atPath:)),
              let img = NSImage(contentsOfFile: path) else {
            fputs("FATAL: master image not found. Tried: \(candidates.joined(separator: ", "))\n", stderr)
            exit(1)
        }
        print("» Using master image: \(path)")
        self.image = img
    }
}

// MARK: - Backdrop palette (matches the master's red-to-black radial)

extension Color {
    static let masterBgInner = Color(red: 0.40, green: 0.02, blue: 0.04) // deep crimson
    static let masterBgOuter = Color(red: 0.05, green: 0.00, blue: 0.00) // near-black
    static let bucketCream   = Color(red: 0.99, green: 0.96, blue: 0.89)
    static let cornDark      = Color(red: 0.97, green: 0.83, blue: 0.50)
}

// MARK: - SwiftUI scenes

@available(macOS 13.0, *)
struct MasterImageScene: View {
    let size: CGFloat
    /// When true, fills the canvas with the master backdrop colour. When
    /// false, transparent — used for tvOS front parallax layers so only the
    /// popcorn motif stacks on top of the background layer.
    let withBackground: Bool

    var body: some View {
        ZStack {
            if withBackground {
                MasterBackdrop(size: size)
            } else {
                Color.clear
            }
            Image(nsImage: MasterImageHolder.shared.image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

@available(macOS 13.0, *)
struct MasterBackdrop: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            // Radial: deep crimson centre fading to near-black corners,
            // mirrors the lighting in the source illustration.
            RadialGradient(colors: [.masterBgInner, .masterBgOuter],
                           center: .center,
                           startRadius: 0, endRadius: size * 0.7)
            // Subtle vignette for depth.
            LinearGradient(colors: [.clear, Color.black.opacity(0.30)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size, height: size)
    }
}

@available(macOS 13.0, *)
struct TvParallaxLayer: View {
    enum Kind { case background, popcorn, blank }
    let kind: Kind
    let canvasW: CGFloat
    let canvasH: CGFloat
    var body: some View {
        let square = min(canvasW, canvasH)
        switch kind {
        case .background:
            // tvOS demands the back layer be fully opaque on the entire
            // canvas (1280×768 / 400×240). The radial backdrop spans the
            // longer edge so it doesn't repeat or stretch.
            MasterBackdrop(size: max(canvasW, canvasH))
                .frame(width: canvasW, height: canvasH)
                .clipped()
        case .popcorn:
            // The master image, centred on a transparent canvas. Floats on
            // top of the background layer with the parallax animation.
            ZStack {
                Color.clear
                Image(nsImage: MasterImageHolder.shared.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: square, height: square)
            }
            .frame(width: canvasW, height: canvasH)
        case .blank:
            Color.clear.frame(width: canvasW, height: canvasH)
        }
    }
}

@available(macOS 13.0, *)
struct TopShelfBanner: View {
    let width: CGFloat
    let height: CGFloat
    var body: some View {
        ZStack {
            MasterBackdrop(size: max(width, height))
                .frame(width: width, height: height)
                .clipped()
            // Master icon sized to the banner's height, anchored left.
            HStack(spacing: 0) {
                Image(nsImage: MasterImageHolder.shared.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: height * 1.1, height: height * 1.1)
                    .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 6)
                    .padding(.leading, height * 0.10)
                Text("Popcorn Time")
                    .font(.system(size: height * 0.20, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(
                        colors: [Color.bucketCream, Color.cornDark],
                        startPoint: .leading, endPoint: .trailing))
                    .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 3)
                    .padding(.leading, height * 0.20)
                Spacer(minLength: 0)
            }
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Render helpers

@available(macOS 13.0, *) @MainActor
func renderPNG<V: View>(_ view: V, size: CGSize) -> Data? {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 1.0
    guard let cg = renderer.cgImage else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: cg)
    bitmap.size = NSSize(width: size.width, height: size.height)
    return bitmap.representation(using: .png, properties: [:])
}

@available(macOS 13.0, *) @MainActor
func write<V: View>(_ view: V, to path: String, size: CGSize) {
    guard let data = renderPNG(view, size: size) else {
        fputs("FAILED to render \(path)\n", stderr); return
    }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? data.write(to: url)
    print("✓ \(path)  (\(Int(size.width))×\(Int(size.height)))")
}

// MARK: - Imperative driver

@MainActor
func runAll() {
    let here = FileManager.default.currentDirectoryPath
    let iosDir   = "\(here)/PopcornTime/Resources/Images.xcassets/AppIcon.appiconset"
    let brandDir = "\(here)/PopcornTime/Resources/Images.xcassets/App Icon & Top Shelf Image.brandassets"

    // 1) iOS / iPad legacy sizes — master with full opaque background. iOS
    //    will mask to the squircle automatically.
    let iosSizes: [(name: String, pt: CGFloat, scale: CGFloat)] = [
        ("Icon-20",      20,   1),
        ("Icon-20@2x",   20,   2),
        ("Icon-20@3x",   20,   3),
        ("Icon-29",      29,   1),
        ("Icon-29@2x",   29,   2),
        ("Icon-29@3x",   29,   3),
        ("Icon-40",      40,   1),
        ("Icon-40@2x",   40,   2),
        ("Icon-40@3x",   40,   3),
        ("Icon-60@2x",   60,   2),
        ("Icon-60@3x",   60,   3),
        ("Icon-76",      76,   1),
        ("Icon-76@2x",   76,   2),
        ("Icon-83.5@2x", 83.5, 2),
        ("Icon-1024",    1024, 1), // marketing
    ]
    for s in iosSizes {
        let px = s.pt * s.scale
        write(MasterImageScene(size: px, withBackground: true),
              to: "\(iosDir)/\(s.name).png",
              size: CGSize(width: px, height: px))
    }

    // 2) tvOS parallax — 5-layer imagestack. Layer 5 (deepest) carries the
    //    opaque backdrop; Layer 1 (front) carries the master motif on a
    //    transparent canvas. Layers 2-4 stay blank as spacer layers — Apple
    //    needs the full 5-layer count for the parallax animation.
    struct TvSize { let folder: String; let canvasW: CGFloat; let canvasH: CGFloat }
    let tvSizes: [TvSize] = [
        TvSize(folder: "App Icon - Large.imagestack", canvasW: 1280, canvasH: 768),
        TvSize(folder: "App Icon - Small.imagestack", canvasW: 400,  canvasH: 240),
    ]
    for tv in tvSizes {
        let layerSpecs: [(name: String, kind: TvParallaxLayer.Kind)] = [
            ("Layer 1", .popcorn),
            ("Layer 2", .blank),
            ("Layer 3", .blank),
            ("Layer 4", .blank),
            ("Layer 5", .background),
        ]
        for spec in layerSpecs {
            let imagestackDir = "\(brandDir)/\(tv.folder)/\(spec.name).imagestacklayer"
            let imgsetDir     = "\(imagestackDir)/Content.imageset"
            let pngPath       = "\(imgsetDir)/\(spec.name).png"
            write(TvParallaxLayer(kind: spec.kind,
                                  canvasW: tv.canvasW,
                                  canvasH: tv.canvasH),
                  to: pngPath,
                  size: CGSize(width: tv.canvasW, height: tv.canvasH))
            try? """
            { "info" : { "version" : 1, "author" : "popcorntime-icon-generator" } }
            """.write(toFile: "\(imagestackDir)/Contents.json",
                      atomically: true, encoding: .utf8)
            try? """
            {
              "images" : [
                { "idiom" : "tv", "filename" : "\(spec.name).png", "scale" : "1x" }
              ],
              "info" : { "version" : 1, "author" : "popcorntime-icon-generator" }
            }
            """.write(toFile: "\(imgsetDir)/Contents.json",
                      atomically: true, encoding: .utf8)
        }
        try? """
        {
          "layers" : [
            { "filename" : "Layer 1.imagestacklayer" },
            { "filename" : "Layer 2.imagestacklayer" },
            { "filename" : "Layer 3.imagestacklayer" },
            { "filename" : "Layer 4.imagestacklayer" },
            { "filename" : "Layer 5.imagestacklayer" }
          ],
          "info" : { "version" : 1, "author" : "popcorntime-icon-generator" }
        }
        """.write(toFile: "\(brandDir)/\(tv.folder)/Contents.json",
                  atomically: true, encoding: .utf8)
    }

    // 3) Top Shelf — wide + standard.
    let topShelfSets: [(folder: String, w: CGFloat, h: CGFloat)] = [
        ("Top Shelf Image.imageset",      1920, 720),
        ("Top Shelf Image Wide.imageset", 2320, 720),
    ]
    for ts in topShelfSets {
        let dir = "\(brandDir)/\(ts.folder)"
        let pngPath = "\(dir)/TopShelf.png"
        write(TopShelfBanner(width: ts.w, height: ts.h),
              to: pngPath, size: CGSize(width: ts.w, height: ts.h))
        try? """
        {
          "images" : [
            { "idiom" : "tv", "filename" : "TopShelf.png", "scale" : "1x" }
          ],
          "info" : { "version" : 1, "author" : "popcorntime-icon-generator" }
        }
        """.write(toFile: "\(dir)/Contents.json",
                  atomically: true, encoding: .utf8)
    }

    // 4) AppIcon.appiconset Contents.json
    try? """
    {
      "images" : [
        { "idiom" : "iphone", "size" : "20x20", "scale" : "2x", "filename" : "Icon-20@2x.png" },
        { "idiom" : "iphone", "size" : "20x20", "scale" : "3x", "filename" : "Icon-20@3x.png" },
        { "idiom" : "iphone", "size" : "29x29", "scale" : "2x", "filename" : "Icon-29@2x.png" },
        { "idiom" : "iphone", "size" : "29x29", "scale" : "3x", "filename" : "Icon-29@3x.png" },
        { "idiom" : "iphone", "size" : "40x40", "scale" : "2x", "filename" : "Icon-40@2x.png" },
        { "idiom" : "iphone", "size" : "40x40", "scale" : "3x", "filename" : "Icon-40@3x.png" },
        { "idiom" : "iphone", "size" : "60x60", "scale" : "2x", "filename" : "Icon-60@2x.png" },
        { "idiom" : "iphone", "size" : "60x60", "scale" : "3x", "filename" : "Icon-60@3x.png" },
        { "idiom" : "ipad",   "size" : "20x20", "scale" : "1x", "filename" : "Icon-20.png" },
        { "idiom" : "ipad",   "size" : "20x20", "scale" : "2x", "filename" : "Icon-20@2x.png" },
        { "idiom" : "ipad",   "size" : "29x29", "scale" : "1x", "filename" : "Icon-29.png" },
        { "idiom" : "ipad",   "size" : "29x29", "scale" : "2x", "filename" : "Icon-29@2x.png" },
        { "idiom" : "ipad",   "size" : "40x40", "scale" : "1x", "filename" : "Icon-40.png" },
        { "idiom" : "ipad",   "size" : "40x40", "scale" : "2x", "filename" : "Icon-40@2x.png" },
        { "idiom" : "ipad",   "size" : "76x76", "scale" : "1x", "filename" : "Icon-76.png" },
        { "idiom" : "ipad",   "size" : "76x76", "scale" : "2x", "filename" : "Icon-76@2x.png" },
        { "idiom" : "ipad",   "size" : "83.5x83.5", "scale" : "2x", "filename" : "Icon-83.5@2x.png" },
        { "idiom" : "ios-marketing", "size" : "1024x1024", "scale" : "1x", "filename" : "Icon-1024.png" }
      ],
      "info" : { "version" : 1, "author" : "popcorntime-icon-generator" }
    }
    """.write(toFile: "\(iosDir)/Contents.json",
              atomically: true, encoding: .utf8)

    // 5) Brand assets Contents.json (top-level)
    try? """
    {
      "assets" : [
        { "size" : "1280x768", "idiom" : "tv",
          "filename" : "App Icon - Large.imagestack", "role" : "primary-app-icon" },
        { "size" : "400x240",  "idiom" : "tv",
          "filename" : "App Icon - Small.imagestack", "role" : "primary-app-icon" },
        { "size" : "2320x720", "idiom" : "tv",
          "filename" : "Top Shelf Image Wide.imageset", "role" : "top-shelf-image-wide" },
        { "size" : "1920x720", "idiom" : "tv",
          "filename" : "Top Shelf Image.imageset", "role" : "top-shelf-image" }
      ],
      "info" : { "version" : 1, "author" : "popcorntime-icon-generator" }
    }
    """.write(toFile: "\(brandDir)/Contents.json",
              atomically: true, encoding: .utf8)

    // 6) The Settings illustration on tvOS uses `Icon.imageset/settings.png`.
    //    Refresh it from the same master so the page stays in style.
    let settingsDir = "\(here)/PopcornTime/Resources/Images.xcassets/Icon.imageset"
    write(MasterImageScene(size: 1200, withBackground: false),
          to: "\(settingsDir)/settings.png",
          size: CGSize(width: 1200, height: 1200))

    print("\n✅ Icon generation complete.")
}

guard #available(macOS 13.0, *) else {
    fputs("ImageRenderer requires macOS 13+\n", stderr); exit(1)
}

DispatchQueue.main.async { runAll(); exit(0) }
RunLoop.main.run()
