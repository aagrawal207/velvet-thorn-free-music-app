import SwiftUI
import XCTest
@testable import GanaBajana

final class ArtworkPaletteTests: XCTestCase {
    private typealias RGB = ArtworkPalette.RGB

    func testSolidColourArtworkYieldsItsHueSaturationAndLuminance() throws {
        let palette = try XCTUnwrap(ArtworkPalette.extract(from: image { context, side in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }))
        XCTAssertTrue(palette.isChromatic)
        let (hue, saturation, brightness) = palette.primary.hsb
        XCTAssertEqual(hue, 0, accuracy: 0.02)
        XCTAssertEqual(saturation, 1, accuracy: 0.03)
        XCTAssertEqual(brightness, 1, accuracy: 0.03)
        XCTAssertEqual(palette.averageLuminance, 0.2126, accuracy: 0.02)
        XCTAssertEqual(palette.secondary, palette.primary, "One colour family has no second colour")
    }

    func testWhiteCoverWithAGoldFrameIsRepresentedByTheGold() throws {
        let palette = try XCTUnwrap(ArtworkPalette.extract(from: image { context, side in
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.setFillColor(red: 0.85, green: 0.6, blue: 0.1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side * 0.3))
        }))
        XCTAssertTrue(palette.isChromatic)
        let (hue, saturation, _) = palette.primary.hsb
        XCTAssertEqual(hue, 0.111, accuracy: 0.03, "White is achromatic; the frame's gold is the cover's colour")
        XCTAssertGreaterThan(saturation, 0.7)
        XCTAssertGreaterThan(palette.averageLuminance, 0.6)
    }

    func testMonochromeArtworkStaysNeutral() throws {
        let palette = try XCTUnwrap(ArtworkPalette.extract(from: image { context, side in
            for row in 0..<Int(side) {
                let grey = CGFloat(row) / side
                context.setFillColor(red: grey, green: grey, blue: grey, alpha: 1)
                context.fill(CGRect(x: 0, y: CGFloat(row), width: side, height: 1))
            }
        }))
        XCTAssertFalse(palette.isChromatic)
        XCTAssertLessThan(palette.primary.hsb.saturation, 0.05)
        XCTAssertEqual(palette.primary.red, 0.5, accuracy: 0.06)
        let style = ArtworkBackdropStyle(palette: palette, colorScheme: .dark, reduceTransparency: false, increaseContrast: false)
        XCTAssertLessThan(style.baseStops[0].color.hsb.saturation, 0.07, "Neutral artwork never gains an invented hue")
    }

    func testTwoColourFamiliesProduceAPrimaryAndASecondary() throws {
        let palette = try XCTUnwrap(ArtworkPalette.extract(from: image { context, side in
            context.setFillColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side * 0.6))
            context.setFillColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 1)
            context.fill(CGRect(x: 0, y: side * 0.6, width: side, height: side * 0.4))
        }))
        XCTAssertEqual(palette.primary.hsb.hue, 0.625, accuracy: 0.03, "The larger blue area leads")
        XCTAssertEqual(palette.secondary.hsb.hue, 0.078, accuracy: 0.03, "The orange family is the second colour")
    }

    func testDarkTintPreservesColourAtConsistentLuminanceAcrossHueFamilies() {
        for step in 0..<24 {
            let hue = Double(step) / 24
            let palette = ArtworkPalette(primary: RGB(hue: hue, saturation: 1, brightness: 1),
                                         secondary: RGB(hue: hue + 0.3, saturation: 1, brightness: 1),
                                         averageLuminance: 0.2, isChromatic: true)
            let style = ArtworkBackdropStyle(palette: palette, colorScheme: .dark, reduceTransparency: false, increaseContrast: false)
            XCTAssertGreaterThan(style.baseStops[0].color.hsb.saturation, 0.4, "hue \(hue) still reads as the cover's colour")
            for (stop, luminance) in zip(style.baseStops, [0.12, 0.07, 0.025]) {
                XCTAssertEqual(stop.color.relativeLuminance, luminance, accuracy: 0.005, "hue \(hue) at \(stop.location)")
            }
            XCTAssertEqual(style.artworkBlend, .screen)
        }
    }

    func testReducedTransparencyAndIncreasedContrastUseAFlatTintWithoutArtwork() {
        let palette = ArtworkPalette(primary: RGB(hue: 0.08, saturation: 0.9, brightness: 0.9),
                                     secondary: RGB(hue: 0.6, saturation: 0.9, brightness: 0.9), averageLuminance: 0.5, isChromatic: true)
        for (scheme, reduce, increase) in [(ColorScheme.dark, true, false), (.dark, false, true), (.light, true, false), (.light, false, true)] {
            let style = ArtworkBackdropStyle(palette: palette, colorScheme: scheme, reduceTransparency: reduce, increaseContrast: increase)
            XCTAssertTrue(style.isFlat)
            XCTAssertEqual(style.artworkOpacity, 0)
            XCTAssertEqual(style.artworkBlend, .normal)
            XCTAssertEqual(style.baseStops.map(\.color), [style.baseStops[0].color, style.baseStops[0].color])
            XCTAssertTrue(style.scrimStops.allSatisfy { $0.opacity == 0 })
            let luminance = style.baseStops[0].color.relativeLuminance
            if scheme == .dark {
                XCTAssertLessThanOrEqual(luminance, 0.03)
                XCTAssertGreaterThan(style.baseStops[0].color.hsb.saturation, 0.25, "The flat tint still carries the cover's hue")
            } else {
                XCTAssertGreaterThanOrEqual(luminance, 0.84)
            }
        }
        let regular = ArtworkBackdropStyle(palette: palette, colorScheme: .dark, reduceTransparency: false, increaseContrast: false)
        XCTAssertFalse(regular.isFlat)
        XCTAssertGreaterThan(regular.artworkOpacity, 0)
        XCTAssertNotEqual(regular.baseStops[0].color, regular.baseStops[2].color, "The regular gradient darkens towards the controls")
    }

    func testBrightCoversEarnAStrongerScrimThanDarkOnes() {
        let bright = ArtworkPalette(primary: RGB(hue: 0.1, saturation: 0.8, brightness: 0.9), secondary: RGB(hue: 0.1, saturation: 0.8, brightness: 0.9),
                                    averageLuminance: 0.85, isChromatic: true)
        let dark = ArtworkPalette(primary: bright.primary, secondary: bright.secondary, averageLuminance: 0.05, isChromatic: true)
        let brightStyle = ArtworkBackdropStyle(palette: bright, colorScheme: .dark, reduceTransparency: false, increaseContrast: false)
        let darkStyle = ArtworkBackdropStyle(palette: dark, colorScheme: .dark, reduceTransparency: false, increaseContrast: false)
        XCTAssertGreaterThan(brightStyle.scrimStops[0].opacity, darkStyle.scrimStops[0].opacity)
        XCTAssertEqual(brightStyle.baseStops, darkStyle.baseStops, "Only the scrim adapts; the tint follows the cover's hue")
    }

    private func image(_ draw: (CGContext, CGFloat) -> Void) throws -> CGImage {
        let side = 96
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        draw(context, CGFloat(side))
        return try XCTUnwrap(context.makeImage())
    }
}
