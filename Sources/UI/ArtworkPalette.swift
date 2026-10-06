import CoreGraphics
import SwiftUI
import UIKit

/// Bounded sampling keeps palette extraction independent of the cover's display size.
struct ArtworkPalette: Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = min(max(red, 0), 1)
            self.green = min(max(green, 0), 1)
            self.blue = min(max(blue, 0), 1)
        }

        init(hue: Double, saturation: Double, brightness: Double) {
            let h = (hue - hue.rounded(.down)) * 6
            let sector = Int(h.rounded(.down)) % 6
            let fraction = h - h.rounded(.down)
            let v = min(max(brightness, 0), 1)
            let s = min(max(saturation, 0), 1)
            let p = v * (1 - s)
            let q = v * (1 - s * fraction)
            let t = v * (1 - s * (1 - fraction))
            switch sector {
            case 0: self.init(red: v, green: t, blue: p)
            case 1: self.init(red: q, green: v, blue: p)
            case 2: self.init(red: p, green: v, blue: t)
            case 3: self.init(red: p, green: q, blue: v)
            case 4: self.init(red: t, green: p, blue: v)
            default: self.init(red: v, green: p, blue: q)
            }
        }

        var hsb: (hue: Double, saturation: Double, brightness: Double) {
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let delta = maximum - minimum
            guard maximum > 0, delta > 0 else { return (0, 0, maximum) }
            var hue: Double
            if maximum == red { hue = (green - blue) / delta }
            else if maximum == green { hue = 2 + (blue - red) / delta }
            else { hue = 4 + (red - green) / delta }
            hue /= 6
            if hue < 0 { hue += 1 }
            return (hue, delta / maximum, maximum)
        }

        /// WCAG relative luminance of the sRGB value.
        var relativeLuminance: Double {
            func linear(_ channel: Double) -> Double {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        var color: Color { Color(red: red, green: green, blue: blue) }
    }

    /// The dominant chromatic colour, or the mean tone of monochrome artwork.
    let primary: RGB
    /// A second colour family at least 50° of hue away, or the primary when the artwork has one family.
    let secondary: RGB
    /// Mean relative luminance of the sampled bitmap, 0...1.
    let averageLuminance: Double
    /// False when too little of the artwork carries colour for a hue to represent it.
    let isChromatic: Bool

    static let sampleSide = 24
    private static let hueBuckets = 36
    private static let minimumSaturation = 0.15
    private static let minimumBrightness = 0.1

    static func extract(from image: UIImage) -> ArtworkPalette? {
        image.cgImage.flatMap(extract(from:))
    }

    static func extract(from cgImage: CGImage) -> ArtworkPalette? {
        let side = sampleSide
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              cgImage.width > 0, cgImage.height > 0 else { return nil }
        context.interpolationQuality = .medium
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let bytesPerRow = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * side)

        var luminanceTotal = 0.0
        var averageRed = 0.0, averageGreen = 0.0, averageBlue = 0.0
        var bucketWeight = [Double](repeating: 0, count: hueBuckets)
        var bucketRed = [Double](repeating: 0, count: hueBuckets)
        var bucketGreen = [Double](repeating: 0, count: hueBuckets)
        var bucketBlue = [Double](repeating: 0, count: hueBuckets)
        var chromaticPixels = 0
        let count = Double(side * side)
        for y in 0..<side {
            for x in 0..<side {
                let offset = y * bytesPerRow + x * 4
                let rgb = RGB(red: Double(pixels[offset]) / 255, green: Double(pixels[offset + 1]) / 255,
                              blue: Double(pixels[offset + 2]) / 255)
                luminanceTotal += rgb.relativeLuminance
                averageRed += rgb.red
                averageGreen += rgb.green
                averageBlue += rgb.blue
                let (hue, saturation, brightness) = rgb.hsb
                guard saturation >= minimumSaturation, brightness >= minimumBrightness else { continue }
                chromaticPixels += 1
                // Vivid mid-tones define a cover's colour; dim or washed-out pixels only nudge the hue.
                let weight = saturation * (0.35 + 0.65 * brightness)
                let bucket = min(hueBuckets - 1, Int(hue * Double(hueBuckets)))
                bucketWeight[bucket] += weight
                bucketRed[bucket] += rgb.red * weight
                bucketGreen[bucket] += rgb.green * weight
                bucketBlue[bucket] += rgb.blue * weight
            }
        }

        let average = RGB(red: averageRed / count, green: averageGreen / count, blue: averageBlue / count)
        let averageLuminance = luminanceTotal / count
        guard Double(chromaticPixels) >= count * 0.02 else {
            return ArtworkPalette(primary: average, secondary: average, averageLuminance: averageLuminance, isChromatic: false)
        }

        func neighbours(_ index: Int) -> [Int] {
            [(index + hueBuckets - 1) % hueBuckets, index, (index + 1) % hueBuckets]
        }
        // Neighbouring buckets join a family so a hue straddling a boundary is not split into two weak halves.
        func score(_ index: Int) -> Double {
            bucketWeight[(index + hueBuckets - 1) % hueBuckets] * 0.5 + bucketWeight[index] + bucketWeight[(index + 1) % hueBuckets] * 0.5
        }
        func family(_ index: Int) -> RGB {
            let members = neighbours(index)
            let weight = members.reduce(0) { $0 + bucketWeight[$1] }
            guard weight > 0 else { return average }
            return RGB(red: members.reduce(0) { $0 + bucketRed[$1] } / weight,
                       green: members.reduce(0) { $0 + bucketGreen[$1] } / weight,
                       blue: members.reduce(0) { $0 + bucketBlue[$1] } / weight)
        }
        func distance(_ a: Int, _ b: Int) -> Int {
            let direct = abs(a - b)
            return min(direct, hueBuckets - direct)
        }

        let scores = (0..<hueBuckets).map(score)
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] || (scores[$0] == scores[$1] && $0 > $1) }) else {
            return nil
        }
        let primary = family(best)
        let secondaryIndex = scores.indices
            .filter { distance($0, best) >= 5 && scores[$0] >= scores[best] * 0.2 }
            .max { scores[$0] < scores[$1] || (scores[$0] == scores[$1] && $0 > $1) }
        let secondary = secondaryIndex.map(family) ?? primary
        return ArtworkPalette(primary: primary, secondary: secondary, averageLuminance: averageLuminance, isChromatic: true)
    }

    /// Luminance rises monotonically with brightness and falling saturation, so both can be bisected.
    /// Saturation bounds preserve the artwork's colour when a pale target is outside that hue's gamut.
    func tint(_ rgb: RGB, luminance target: Double, saturation range: ClosedRange<Double>) -> RGB {
        let (hue, saturation, _) = rgb.hsb
        var adjusted = isChromatic ? min(max(saturation, range.lowerBound), range.upperBound) : min(saturation, 0.06)
        // Deep hues such as pure blue cannot reach a mid luminance at full saturation; fade towards the floor first.
        if RGB(hue: hue, saturation: adjusted, brightness: 1).relativeLuminance < target {
            var low = isChromatic ? range.lowerBound : 0, high = adjusted
            for _ in 0..<16 {
                let middle = (low + high) / 2
                if RGB(hue: hue, saturation: middle, brightness: 1).relativeLuminance < target { high = middle } else { low = middle }
            }
            adjusted = low
            if RGB(hue: hue, saturation: adjusted, brightness: 1).relativeLuminance < target {
                return RGB(hue: hue, saturation: adjusted, brightness: 1)
            }
        }
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if RGB(hue: hue, saturation: adjusted, brightness: middle).relativeLuminance < target { low = middle } else { high = middle }
        }
        return RGB(hue: hue, saturation: adjusted, brightness: (low + high) / 2)
    }
}

/// The recipe is independent of layout; rendered crops still need to meet the foreground's contrast bounds.
struct ArtworkBackdropStyle: Equatable {
    struct Stop: Equatable {
        let color: ArtworkPalette.RGB
        let location: Double
    }

    /// Palette-tinted gradient under the artwork, top to bottom.
    let baseStops: [Stop]
    /// Opacity of the blurred, saturated artwork layer; zero removes the layer.
    let artworkOpacity: Double
    let artworkSaturation: Double
    /// Screen preserves a dark cover's tint; multiply keeps light artwork from washing a pale tint out.
    let artworkBlend: BlendMode
    /// Page-colour scrim opacities, top to bottom, that keep text and controls legible over bright covers.
    let scrimStops: [(opacity: Double, location: Double)]

    /// Reduce Transparency and Increase Contrast get a flat tint without blur or artwork.
    let isFlat: Bool

    init(palette: ArtworkPalette, colorScheme: ColorScheme, reduceTransparency: Bool, increaseContrast: Bool) {
        isFlat = reduceTransparency || increaseContrast
        let dark = colorScheme == .dark
        if isFlat {
            let flat = dark ? palette.tint(palette.primary, luminance: 0.02, saturation: 0.3...0.7)
                : palette.tint(palette.primary, luminance: 0.9, saturation: 0.03...0.08)
            baseStops = [Stop(color: flat, location: 0), Stop(color: flat, location: 1)]
            artworkOpacity = 0
            artworkSaturation = 1
            artworkBlend = .normal
            scrimStops = [(0, 0), (0, 1)]
            return
        }
        baseStops = Self.baseTargets(dark: dark).map {
            Stop(color: palette.tint($0.usesSecondary ? palette.secondary : palette.primary, luminance: $0.luminance,
                                     saturation: $0.saturation), location: $0.location)
        }
        if dark {
            artworkOpacity = 0.3
            artworkSaturation = 1.6
            artworkBlend = .screen
            // A cropped bright patch can fill the viewport even when the whole cover is dark.
            // This floor pairs with artworkSecondaryText without dimming the page for ordinary secondary grey.
            let boost = min(0.4, max(0, palette.averageLuminance - 0.2))
            scrimStops = [(max(0.28, 0.08 + boost), 0), (0.28 + boost, 0.45), (0.66 + boost * 0.5, 1)]
        } else {
            artworkOpacity = 0.3
            artworkSaturation = 1.3
            artworkBlend = .multiply
            // The constant floor protects local dark patches; the mean only adds protection for darker covers.
            let boost = min(0.35, max(0, (0.4 - palette.averageLuminance) * 0.9))
            scrimStops = [(0.3 + boost, 0), (0.45 + boost, 0.5), (0.62 + boost * 0.5, 1)]
        }
    }

    struct BaseTarget: Equatable {
        let usesSecondary: Bool
        let luminance: Double
        let saturation: ClosedRange<Double>
        let location: Double
    }

    /// Base gradient recipe, top to bottom. The animated player backdrop tints its mesh rows to the same stops.
    static func baseTargets(dark: Bool) -> [BaseTarget] {
        if dark {
            // Lock-screen balance: a brighter tinted top fading to a deep tone behind the controls.
            return [BaseTarget(usesSecondary: false, luminance: 0.12, saturation: 0.45...0.85, location: 0),
                    BaseTarget(usesSecondary: true, luminance: 0.07, saturation: 0.4...0.8, location: 0.5),
                    BaseTarget(usesSecondary: false, luminance: 0.025, saturation: 0.35...0.75, location: 1)]
        }
        return [BaseTarget(usesSecondary: false, luminance: 0.86, saturation: 0.16...0.32, location: 0),
                BaseTarget(usesSecondary: true, luminance: 0.82, saturation: 0.14...0.3, location: 0.5),
                BaseTarget(usesSecondary: false, luminance: 0.76, saturation: 0.12...0.28, location: 1)]
    }

    static func == (lhs: ArtworkBackdropStyle, rhs: ArtworkBackdropStyle) -> Bool {
        lhs.baseStops == rhs.baseStops && lhs.artworkOpacity == rhs.artworkOpacity
            && lhs.artworkSaturation == rhs.artworkSaturation && lhs.artworkBlend == rhs.artworkBlend && lhs.isFlat == rhs.isFlat
            && lhs.scrimStops.map(\.opacity) == rhs.scrimStops.map(\.opacity)
            && lhs.scrimStops.map(\.location) == rhs.scrimStops.map(\.location)
    }
}
