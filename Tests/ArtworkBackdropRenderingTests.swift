import SwiftUI
import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class ArtworkBackdropRenderingTests: XCTestCase {
    private typealias RGB = ArtworkPalette.RGB
    private let canvases = [CGSize(width: 375, height: 812), CGSize(width: 844, height: 390), CGSize(width: 1024, height: 768)]

    func testRenderedMixedBrightnessCropsProtectTextAcrossTheWholeViewport() throws {
        let fixtures = try mixedFixtures()
        let wide = try XCTUnwrap(fixtures.first { $0.name == "wide-highlight" })
        let tall = try XCTUnwrap(fixtures.first { $0.name == "tall-shadow" })
        XCTAssertLessThan(try accepted(wide).palette.averageLuminance, 0.3)
        XCTAssertGreaterThan(try accepted(tall).palette.averageLuminance, 0.7)

        for scheme in [ColorScheme.dark, .light] {
            let secondary = try swatch(AppTheme.artworkSecondaryText, scheme: scheme)
            let primary = try swatch(AppTheme.primaryText, scheme: scheme)
            for fixture in fixtures {
                let artwork = try accepted(fixture)
                for size in canvases {
                    try autoreleasepool {
                        let bitmap = try render(ArtworkBackdropSurface(artwork: artwork, fallbackTint: .purple), size: size, scheme: scheme)
                        let samples = bitmap.samples
                        let detail = "\(fixture.name), \(scheme), \(size)"
                        XCTAssertGreaterThanOrEqual(try XCTUnwrap(samples.map { contrast(secondary, $0) }.min()), 4.5, detail)
                        XCTAssertGreaterThanOrEqual(try XCTUnwrap(samples.map { contrast(primary, $0) }.min()), scheme == .dark ? 4.5 : 9, detail)
                        if scheme == .dark {
                            let titleLine = stride(from: 0, to: bitmap.width, by: 8).map {
                                contrast(primary, bitmap.color(x: $0, y: Int(Double(bitmap.height) * 0.55)))
                            }
                            XCTAssertGreaterThanOrEqual(try XCTUnwrap(titleLine.min()), 7, detail)
                        }
                    }
                }
            }
        }
    }

    func testRendererIncludesSpatialArtworkRatherThanOnlyThePaletteGradient() throws {
        let left = try fixture("warm-left") { context, rect in
            context.setFillColor(red: 0.05, green: 0.2, blue: 0.7, alpha: 1)
            context.fill(rect)
            context.setFillColor(red: 0.85, green: 0.4, blue: 0.05, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: rect.width / 2, height: rect.height))
        }
        let right = try fixture("warm-right") { context, rect in
            context.setFillColor(red: 0.05, green: 0.2, blue: 0.7, alpha: 1)
            context.fill(rect)
            context.setFillColor(red: 0.85, green: 0.4, blue: 0.05, alpha: 1)
            context.fill(CGRect(x: rect.width / 2, y: 0, width: rect.width / 2, height: rect.height))
        }
        let first = try accepted(left), second = try accepted(right)
        XCTAssertEqual(first.palette.primary, second.palette.primary)
        XCTAssertEqual(first.palette.secondary, second.palette.secondary)
        XCTAssertEqual(first.palette.averageLuminance, second.palette.averageLuminance, accuracy: 1e-6)

        for scheme in [ColorScheme.dark, .light] {
            let a = try render(ArtworkBackdropSurface(artwork: first, fallbackTint: .purple), size: canvases[0], scheme: scheme)
            let b = try render(ArtworkBackdropSurface(artwork: second, fallbackTint: .purple), size: canvases[0], scheme: scheme)
            let changed = zip(a.samples, b.samples).filter { distance($0.0, $0.1) > 0.025 }.count
            XCTAssertGreaterThan(changed, a.samples.count / 8, "\(scheme): identical palettes must still retain different spatial artwork")
        }
    }

    func testGoldenAndBlueBrownArtworkKeepsVisibleColourAndLightness() throws {
        let fixtures = try mixedFixtures().filter { $0.name == "gold-frame" || $0.name == "blue-brown" }
        for fixture in fixtures {
            for scheme in [ColorScheme.dark, .light] {
                let bitmap = try render(ArtworkBackdropSurface(artwork: accepted(fixture), fallbackTint: .purple), size: canvases[0], scheme: scheme)
                let samples = bitmap.samples
                if scheme == .dark {
                    XCTAssertGreaterThan(try XCTUnwrap(samples.map(luminance).max()), 0.04, fixture.name)
                }
                if fixture.name == "gold-frame" || scheme == .dark {
                    let warmest = try XCTUnwrap(samples.map { $0.red - $0.blue }.max())
                    XCTAssertGreaterThan(warmest, scheme == .dark ? 0.08 : 0.04, "\(fixture.name), \(scheme): retain the warm family")
                }
                if fixture.name == "blue-brown" {
                    let coolest = try XCTUnwrap(samples.map { $0.blue - $0.red }.max())
                    XCTAssertGreaterThan(coolest, scheme == .dark ? 0.08 : 0.025, "\(scheme): retain the blue family")
                }
            }
        }
    }

    func testAccessibilitySurfacesAreFlatAndReadableWithAndWithoutArtwork() throws {
        let artwork = try accepted(XCTUnwrap(mixedFixtures().first))
        for scheme in [ColorScheme.dark, .light] {
            let foreground = try swatch(AppTheme.artworkSecondaryText, scheme: scheme)
            for (reduce, increase) in [(true, false), (false, true), (true, true)] {
                for frame in [artwork, nil] as [ArtworkBackdropState.Artwork?] {
                    let content = ArtworkBackdropSurface(artwork: frame, fallbackTint: AppTheme.gold,
                                                         reduceTransparency: reduce, increaseContrast: increase)
                    let bitmap = try render(content, size: canvases[0], scheme: scheme)
                    let first = try XCTUnwrap(bitmap.samples.first)
                    XCTAssertTrue(bitmap.samples.allSatisfy { distance(first, $0) <= 2.0 / 255 }, "\(scheme), reduce \(reduce), contrast \(increase)")
                    XCTAssertGreaterThanOrEqual(contrast(foreground, first), 4.5)
                }
            }
        }
    }

    func testReducedMotionReplacementRendersTheRetainedThenAcceptedArtwork() throws {
        let fixtures = try mixedFixtures()
        let first = try XCTUnwrap(fixtures.first), second = try XCTUnwrap(fixtures.last)
        var state = ArtworkBackdropState()
        let initial = try XCTUnwrap(state.begin(first.url))
        state.complete(first.image, for: initial)
        let before = try render(ArtworkBackdropSurface(artwork: state.displayed, fallbackTint: .purple, reduceMotion: true),
                                size: canvases[0], scheme: .dark)

        let request = try XCTUnwrap(state.begin(second.url))
        let waiting = try render(ArtworkBackdropSurface(artwork: state.displayed, fallbackTint: .purple, reduceMotion: true),
                                 size: canvases[0], scheme: .dark)
        XCTAssertEqual(before.bytes, waiting.bytes)
        state.complete(second.image, for: request)
        let after = try render(ArtworkBackdropSurface(artwork: state.displayed, fallbackTint: .purple, reduceMotion: true),
                               size: canvases[0], scheme: .dark)
        let expected = try render(ArtworkBackdropSurface(artwork: accepted(second), fallbackTint: .purple, reduceMotion: true),
                                  size: canvases[0], scheme: .dark)
        XCTAssertEqual(after.bytes, expected.bytes)
        XCTAssertNotEqual(before.bytes, after.bytes)
    }

    func testSharedSecondaryLabelsUseTheScopedColourAndKeepTheirDefaultElsewhere() async throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        // Empty primary labels keep their antialiased edges from masquerading as the expected secondary colour.
        let track = Track(id: "artwork-row", title: "", artists: ["Byline"], duration: 262)
        let collection = MusicCollection(id: "artwork-album", title: "", subtitle: "Byline", kind: .album)
        let components: [(String, AnyView, CGSize, CGRect)] = [
            ("row byline", AnyView(TrackRow(track: track)), CGSize(width: 350, height: 80),
             CGRect(x: 65, y: 0, width: 185, height: 80)),
            ("row duration", AnyView(TrackRow(track: track, showsDuration: true)), CGSize(width: 350, height: 80),
             CGRect(x: 250, y: 0, width: 44, height: 80)),
            ("section subtitle", AnyView(SectionHeader(title: "", subtitle: "Byline")), CGSize(width: 350, height: 80),
             CGRect(x: 0, y: 0, width: 350, height: 80)),
            ("collection subtitle", AnyView(CollectionCard(collection: collection, size: 160)), CGSize(width: 160, height: 240),
             CGRect(x: 0, y: 160, width: 160, height: 80)),
        ]
        for scheme in [ColorScheme.dark, .light] {
            for scoped in [false, true] {
                let foreground = try swatch(scoped ? AppTheme.artworkSecondaryText : AppTheme.secondaryText, scheme: scheme)
                for (name, component, size, region) in components {
                    let content = scoped ? AnyView(component.environment(\.secondaryTextColor, AppTheme.artworkSecondaryText)) : component
                    let scopedContent = content.environment(context.model).background(AppTheme.background)
                    let bitmap: Bitmap
                    if name == "collection subtitle" {
                        bitmap = try await renderHosted(scopedContent, size: size, scheme: scheme)
                    } else {
                        bitmap = try render(scopedContent, size: size, scheme: scheme, scale: 2)
                    }
                    let matching = bitmap.count(near: foreground, in: region.applying(CGAffineTransform(scaleX: 2, y: 2)))
                    XCTAssertGreaterThan(matching, 8, "\(name), \(scheme), scoped \(scoped)")
                }
            }
        }
    }

    private struct Fixture {
        let name: String
        let image: UIImage
        var url: URL { URL(string: "https://artwork.invalid/\(name)")! }
    }

    private func mixedFixtures() throws -> [Fixture] {
        [
            try fixture("gold-frame") { context, rect in
                context.setFillColor(red: 0.85, green: 0.6, blue: 0.1, alpha: 1)
                context.fill(rect)
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(rect.insetBy(dx: 22, dy: 22))
                context.setFillColor(red: 0.35, green: 0.12, blue: 0.04, alpha: 1)
                context.fill(CGRect(x: 100, y: 100, width: 100, height: 100))
            },
            try fixture("blue-brown") { context, rect in
                context.setFillColor(red: 0.05, green: 0.15, blue: 0.45, alpha: 1)
                context.fill(rect)
                context.setFillColor(red: 0.55, green: 0.3, blue: 0.12, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.3))
            },
            try fixture("dark-centre-highlight") { context, rect in
                context.setFillColor(red: 0.02, green: 0.05, blue: 0.15, alpha: 1)
                context.fill(rect)
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: rect.width * 0.39, y: 0, width: rect.width * 0.22, height: rect.height))
            },
            try fixture("light-centre-shadow") { context, rect in
                context.setFillColor(red: 1, green: 0.95, blue: 0.85, alpha: 1)
                context.fill(rect)
                context.setFillColor(gray: 0, alpha: 1)
                context.fill(CGRect(x: rect.width * 0.39, y: 0, width: rect.width * 0.22, height: rect.height))
            },
            try fixture("wide-highlight", size: CGSize(width: 300, height: 100)) { context, rect in
                context.setFillColor(red: 0.02, green: 0.05, blue: 0.15, alpha: 1)
                context.fill(rect)
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 120, y: 0, width: 60, height: rect.height))
            },
            try fixture("tall-shadow", size: CGSize(width: 100, height: 300)) { context, rect in
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(rect)
                context.setFillColor(gray: 0, alpha: 1)
                context.fill(CGRect(x: 0, y: 120, width: rect.width, height: 60))
            },
            try fixture("saturated-bands") { context, rect in
                let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (1, 0, 1), (0, 1, 1)]
                for (index, color) in colors.enumerated() {
                    context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
                    context.fill(CGRect(x: CGFloat(index) * rect.width / 6, y: 0, width: rect.width / 6, height: rect.height))
                }
            },
        ]
    }

    private func fixture(_ name: String, size: CGSize = CGSize(width: 300, height: 300),
                         draw: (CGContext, CGRect) -> Void) throws -> Fixture {
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        draw(context, CGRect(origin: .zero, size: size))
        return Fixture(name: name, image: UIImage(cgImage: try XCTUnwrap(context.makeImage())))
    }

    private func accepted(_ fixture: Fixture) throws -> ArtworkBackdropState.Artwork {
        var state = ArtworkBackdropState()
        let request = try XCTUnwrap(state.begin(fixture.url))
        state.complete(fixture.image, for: request)
        return try XCTUnwrap(state.displayed)
    }

    private func render<Content: View>(_ content: Content, size: CGSize, scheme: ColorScheme, scale: CGFloat = 1) throws -> Bitmap {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, scheme)
            .environment(\.displayScale, scale)
            .environment(\.dynamicTypeSize, .large))
        renderer.scale = scale
        renderer.isOpaque = true
        var image: CGImage?
        UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light).performAsCurrent { image = renderer.cgImage }
        return try Bitmap(XCTUnwrap(image))
    }

    private func swatch(_ color: Color, scheme: ColorScheme) throws -> RGB {
        try render(color, size: CGSize(width: 8, height: 8), scheme: scheme).color(x: 4, y: 4)
    }

    // Native navigation links contain UIKit buttons, which ImageRenderer cannot flatten.
    private func renderHosted<Content: View>(_ content: Content, size: CGSize, scheme: ColorScheme) async throws -> Bitmap {
        let host = UIHostingController(rootView: NavigationStack {
            content.frame(width: size.width, height: size.height, alignment: .topLeading)
                .toolbar(.hidden, for: .navigationBar)
        }
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large)
            .ignoresSafeArea())
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "hosted-collection-\(scheme)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return try Bitmap(XCTUnwrap(image.cgImage))
    }

    private func luminance(_ rgb: RGB) -> Double {
        func linear(_ channel: Double) -> Double { channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4) }
        return linear(rgb.red) * 0.2126 + linear(rgb.green) * 0.7152 + linear(rgb.blue) * 0.0722
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func distance(_ a: RGB, _ b: RGB) -> Double {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) throws {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            }
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        func color(x: Int, y: Int) -> RGB {
            let offset = (y * width + x) * 4
            return RGB(red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255, blue: Double(bytes[offset + 2]) / 255)
        }

        var samples: [RGB] {
            let xs = Array(stride(from: 0, to: width, by: 8)) + [width - 1]
            let ys = Array(stride(from: 0, to: height, by: 8)) + [height - 1]
            return ys.flatMap { y in xs.map { x in color(x: x, y: y) } }
        }

        func count(near expected: RGB, in rect: CGRect) -> Int {
            var count = 0
            for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
                for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                    let pixel = color(x: x, y: y)
                    if abs(pixel.red - expected.red) <= 3.0 / 255, abs(pixel.green - expected.green) <= 3.0 / 255,
                       abs(pixel.blue - expected.blue) <= 3.0 / 255 { count += 1 }
                }
            }
            return count
        }
    }
}
