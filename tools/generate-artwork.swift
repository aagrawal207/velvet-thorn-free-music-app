#!/usr/bin/env swift
// Original Breezy icons use CoreGraphics paths; fonts appear only in preview captions, never in icons.
// swift tools/generate-artwork.swift [--preview path/contact-sheet.png] [--primary-preview path/icon-preview.png]

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let canvas: CGFloat = 1024
private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
private let root = URL(fileURLWithPath: #filePath).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent()
private let assets = root.appendingPathComponent("Resources/Assets.xcassets")

private enum ArtworkError: Error {
    case invalidArguments
    case contextCreation
    case imageEncoding(URL)
    case invalidIcon(String)
}

// MARK: - Drawing helpers (y grows downward; the renderer flips the context)

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha,
    ])!
}

private func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

private func background(_ context: CGContext, _ top: UInt32, _ bottom: UInt32) {
    context.setFillColor(color(top))
    context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    context.drawLinearGradient(gradient([(0, color(top)), (1, color(bottom))]),
                               start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])
}

private func fill(_ context: CGContext, _ path: CGPath, _ hex: UInt32, alpha: CGFloat = 1) {
    context.setFillColor(color(hex, alpha: alpha))
    context.addPath(path)
    context.fillPath()
}

private func fillGradient(_ context: CGContext, _ path: CGPath, _ stops: [(CGFloat, UInt32)], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient(stops.map { ($0.0, color($0.1)) }), start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

private func stroke(_ context: CGContext, _ path: CGPath, _ hex: UInt32, width: CGFloat, alpha: CGFloat = 1, cap: CGLineCap = .round) {
    context.setStrokeColor(color(hex, alpha: alpha))
    context.setLineWidth(width)
    context.setLineCap(cap)
    context.setLineJoin(.round)
    context.addPath(path)
    context.strokePath()
}

private func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
}

private func ellipse(_ center: CGPoint, _ rx: CGFloat, _ ry: CGFloat, rotation: CGFloat = 0) -> CGPath {
    var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation)
    return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &transform)
}

private func arc(_ center: CGPoint, _ radius: CGFloat, from start: CGFloat, to end: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    return path
}

// MARK: - Recipes

private struct IconRecipe {
    let id: String
    let title: String
    let draw: (CGContext) -> Void
}

private let recipes: [IconRecipe] = [
    IconRecipe(id: "Beat", title: "Leafnote") { c in
        background(c, 0x27272F, 0x161A23)
        let stem = CGMutablePath()
        stem.move(to: CGPoint(x: 493, y: 667))
        stem.addCurve(to: CGPoint(x: 553, y: 258),
                      control1: CGPoint(x: 566, y: 515), control2: CGPoint(x: 565, y: 369))
        stroke(c, stem, 0xA7EDD3, width: 52)

        let head = CGMutablePath()
        head.move(to: CGPoint(x: 551, y: 570))
        head.addCurve(to: CGPoint(x: 247, y: 779),
                      control1: CGPoint(x: 371, y: 561), control2: CGPoint(x: 269, y: 653))
        head.addCurve(to: CGPoint(x: 551, y: 570),
                      control1: CGPoint(x: 447, y: 806), control2: CGPoint(x: 561, y: 722))
        fill(c, head, 0xA7EDD3)

        let flag = CGMutablePath()
        flag.move(to: CGPoint(x: 552, y: 242))
        flag.addCurve(to: CGPoint(x: 783, y: 439),
                      control1: CGPoint(x: 648, y: 329), control2: CGPoint(x: 801, y: 282))
        flag.addCurve(to: CGPoint(x: 552, y: 304),
                      control1: CGPoint(x: 685, y: 469), control2: CGPoint(x: 590, y: 404))
        flag.closeSubpath()
        fill(c, flag, 0xFF9B8F)
    },
    IconRecipe(id: "Dhol", title: "Breeze") { c in
        background(c, 0x1C2428, 0x0E1418)

        // The open, curved vein echoes the breeze without adding fine detail that disappears at small sizes.
        let leaf = CGMutablePath()
        leaf.move(to: CGPoint(x: 814, y: 206))
        leaf.addCurve(to: CGPoint(x: 319, y: 634),
                      control1: CGPoint(x: 546, y: 205), control2: CGPoint(x: 223, y: 346))
        leaf.addCurve(to: CGPoint(x: 688, y: 347),
                      control1: CGPoint(x: 456, y: 591), control2: CGPoint(x: 580, y: 451))
        leaf.addCurve(to: CGPoint(x: 383, y: 677),
                      control1: CGPoint(x: 620, y: 486), control2: CGPoint(x: 502, y: 606))
        leaf.addCurve(to: CGPoint(x: 814, y: 206),
                      control1: CGPoint(x: 693, y: 777), control2: CGPoint(x: 869, y: 519))
        leaf.closeSubpath()
        fillGradient(c, leaf, [(0, 0xCBF7DE), (0.55, 0x88E5C1), (1, 0x49C2A5)],
                     from: CGPoint(x: 300, y: 280), to: CGPoint(x: 790, y: 710))

        let breeze = CGMutablePath()
        breeze.move(to: CGPoint(x: 215, y: 727))
        breeze.addCurve(to: CGPoint(x: 778, y: 594),
                        control1: CGPoint(x: 375, y: 822), control2: CGPoint(x: 628, y: 778))
        stroke(c, breeze, 0x85DBC0, width: 26, alpha: 0.75)
    },
    IconRecipe(id: "Notes", title: "Drift") { c in
        background(c, 0xF9F0DF, 0xEDE1CC)
        let stems = CGMutablePath()
        stems.move(to: CGPoint(x: 415, y: 683))
        stems.addCurve(to: CGPoint(x: 429, y: 328),
                       control1: CGPoint(x: 444, y: 524), control2: CGPoint(x: 435, y: 417))
        stems.addCurve(to: CGPoint(x: 729, y: 264),
                       control1: CGPoint(x: 543, y: 350), control2: CGPoint(x: 630, y: 243))
        stems.addCurve(to: CGPoint(x: 703, y: 598),
                       control1: CGPoint(x: 736, y: 381), control2: CGPoint(x: 728, y: 499))
        stroke(c, stems, 0x275C59, width: 52)

        let left = CGMutablePath()
        left.move(to: CGPoint(x: 435, y: 617))
        left.addCurve(to: CGPoint(x: 216, y: 776),
                      control1: CGPoint(x: 302, y: 579), control2: CGPoint(x: 216, y: 675))
        left.addCurve(to: CGPoint(x: 435, y: 617),
                      control1: CGPoint(x: 359, y: 814), control2: CGPoint(x: 452, y: 744))
        fill(c, left, 0x275C59)
        let right = CGMutablePath()
        right.move(to: CGPoint(x: 725, y: 528))
        right.addCurve(to: CGPoint(x: 508, y: 688),
                       control1: CGPoint(x: 593, y: 494), control2: CGPoint(x: 507, y: 587))
        right.addCurve(to: CGPoint(x: 725, y: 528),
                       control1: CGPoint(x: 648, y: 727), control2: CGPoint(x: 740, y: 654))
        fill(c, right, 0x275C59)
    },
    IconRecipe(id: "Headphones", title: "Airwave") { c in
        background(c, 0x345F9C, 0x223964)
        let upper = CGMutablePath()
        upper.move(to: CGPoint(x: 224, y: 398))
        upper.addCurve(to: CGPoint(x: 696, y: 271),
                       control1: CGPoint(x: 392, y: 239), control2: CGPoint(x: 483, y: 437))
        stroke(c, upper, 0xCBEFEC, width: 62)
        let middle = CGMutablePath()
        middle.move(to: CGPoint(x: 205, y: 593))
        middle.addCurve(to: CGPoint(x: 815, y: 394),
                        control1: CGPoint(x: 427, y: 356), control2: CGPoint(x: 555, y: 655))
        stroke(c, middle, 0xB6EACF, width: 72)
        let lower = CGMutablePath()
        lower.move(to: CGPoint(x: 324, y: 755))
        lower.addCurve(to: CGPoint(x: 800, y: 608),
                       control1: CGPoint(x: 514, y: 566), control2: CGPoint(x: 610, y: 787))
        stroke(c, lower, 0x8CCEC9, width: 62)
    },
    IconRecipe(id: "Vinyl", title: "Groove") { c in
        background(c, 0xBDE7D9, 0x91C9B8)
        let center = CGPoint(x: 512, y: 512)
        fill(c, circle(center, 318), 0x213E43)
        for radius in [CGFloat(245), 181] {
            stroke(c, arc(center, radius, from: 0.35, to: 2.48), 0x72B8A9, width: 17)
            stroke(c, arc(center, radius, from: 3.49, to: 5.62), 0x72B8A9, width: 17)
        }
        fill(c, circle(center, 105), 0xFFAA91)
        let label = CGMutablePath()
        label.move(to: CGPoint(x: 567, y: 451))
        label.addCurve(to: CGPoint(x: 458, y: 570),
                       control1: CGPoint(x: 466, y: 449), control2: CGPoint(x: 443, y: 514))
        label.addCurve(to: CGPoint(x: 567, y: 451),
                       control1: CGPoint(x: 550, y: 575), control2: CGPoint(x: 579, y: 512))
        fill(c, label, 0xFFF2D9)
    },
    IconRecipe(id: "Boombox", title: "Moonleaf") { c in
        background(c, 0x2D2D50, 0x191D34)
        let moon = CGMutablePath()
        moon.move(to: CGPoint(x: 668, y: 220))
        moon.addCurve(to: CGPoint(x: 266, y: 590),
                      control1: CGPoint(x: 415, y: 157), control2: CGPoint(x: 219, y: 339))
        moon.addCurve(to: CGPoint(x: 811, y: 642),
                      control1: CGPoint(x: 310, y: 844), control2: CGPoint(x: 639, y: 862))
        moon.addCurve(to: CGPoint(x: 462, y: 428),
                      control1: CGPoint(x: 602, y: 733), control2: CGPoint(x: 413, y: 600))
        moon.addCurve(to: CGPoint(x: 668, y: 220),
                      control1: CGPoint(x: 483, y: 327), control2: CGPoint(x: 574, y: 255))
        fill(c, moon, 0xF5E8C8)

        let stem = CGMutablePath()
        stem.move(to: CGPoint(x: 680, y: 471))
        stem.addCurve(to: CGPoint(x: 691, y: 292),
                      control1: CGPoint(x: 704, y: 407), control2: CGPoint(x: 698, y: 342))
        stroke(c, stem, 0x9CDEC9, width: 34)
        let leaf = CGMutablePath()
        leaf.move(to: CGPoint(x: 692, y: 419))
        leaf.addCurve(to: CGPoint(x: 531, y: 548),
                      control1: CGPoint(x: 588, y: 398), control2: CGPoint(x: 529, y: 472))
        leaf.addCurve(to: CGPoint(x: 692, y: 419),
                      control1: CGPoint(x: 641, y: 570), control2: CGPoint(x: 705, y: 509))
        fill(c, leaf, 0x9CDEC9)
    },
    IconRecipe(id: "Cassette", title: "Daybreak") { c in
        background(c, 0xFFF1D9, 0xF2DFC7)
        let sun = CGMutablePath()
        sun.move(to: CGPoint(x: 284, y: 492))
        sun.addCurve(to: CGPoint(x: 740, y: 492),
                     control1: CGPoint(x: 284, y: 190), control2: CGPoint(x: 740, y: 190))
        sun.closeSubpath()
        fillGradient(c, sun, [(0, 0xFBA574), (1, 0xE77570)],
                     from: CGPoint(x: 512, y: 267), to: CGPoint(x: 512, y: 492))
        stroke(c, arc(CGPoint(x: 512, y: 492), 145, from: .pi + 0.14, to: .pi * 2 - 0.14), 0xFFE8C8, width: 18)
        let upper = CGMutablePath()
        upper.move(to: CGPoint(x: 220, y: 587))
        upper.addCurve(to: CGPoint(x: 512, y: 587),
                       control1: CGPoint(x: 320, y: 522), control2: CGPoint(x: 411, y: 652))
        upper.addCurve(to: CGPoint(x: 804, y: 587),
                       control1: CGPoint(x: 614, y: 522), control2: CGPoint(x: 705, y: 652))
        stroke(c, upper, 0x365F5B, width: 39)
        let lower = CGMutablePath()
        lower.move(to: CGPoint(x: 324, y: 707))
        lower.addCurve(to: CGPoint(x: 700, y: 707),
                       control1: CGPoint(x: 451, y: 645), control2: CGPoint(x: 573, y: 770))
        stroke(c, lower, 0x699A83, width: 33)
    },
    IconRecipe(id: "Speaker", title: "Ripple") { c in
        background(c, 0x194650, 0x102D3A)
        stroke(c, ellipse(CGPoint(x: 512, y: 659), 303, 112), 0x7BC6BE, width: 29)
        stroke(c, ellipse(CGPoint(x: 512, y: 659), 174, 60), 0x497D83, width: 25)
        let stem = CGMutablePath()
        stem.move(to: CGPoint(x: 563, y: 494))
        stem.addCurve(to: CGPoint(x: 588, y: 250),
                      control1: CGPoint(x: 594, y: 410), control2: CGPoint(x: 598, y: 335))
        stem.addCurve(to: CGPoint(x: 732, y: 351),
                      control1: CGPoint(x: 624, y: 304), control2: CGPoint(x: 700, y: 292))
        stroke(c, stem, 0xDEF0DB, width: 39)
        fill(c, ellipse(CGPoint(x: 485, y: 486), 108, 71, rotation: -0.35), 0xDEF0DB)
    },
    IconRecipe(id: "Waves", title: "Tide") { c in
        background(c, 0xFFAC92, 0xEA8584)
        let wave = CGMutablePath()
        wave.move(to: CGPoint(x: 192, y: 689))
        wave.addCurve(to: CGPoint(x: 562, y: 253),
                      control1: CGPoint(x: 349, y: 677), control2: CGPoint(x: 280, y: 291))
        wave.addCurve(to: CGPoint(x: 741, y: 526),
                      control1: CGPoint(x: 804, y: 220), control2: CGPoint(x: 864, y: 438))
        wave.addCurve(to: CGPoint(x: 530, y: 491),
                      control1: CGPoint(x: 663, y: 579), control2: CGPoint(x: 567, y: 557))
        wave.addCurve(to: CGPoint(x: 704, y: 431),
                      control1: CGPoint(x: 546, y: 403), control2: CGPoint(x: 652, y: 374))
        wave.addCurve(to: CGPoint(x: 496, y: 502),
                      control1: CGPoint(x: 671, y: 276), control2: CGPoint(x: 478, y: 332))
        wave.addCurve(to: CGPoint(x: 825, y: 666),
                      control1: CGPoint(x: 487, y: 663), control2: CGPoint(x: 658, y: 714))
        wave.addCurve(to: CGPoint(x: 192, y: 689),
                      control1: CGPoint(x: 672, y: 837), control2: CGPoint(x: 360, y: 839))
        fill(c, wave, 0xFFF2DB)
    },
    IconRecipe(id: "Peacock", title: "Zephyr") { c in
        background(c, 0xDBE7F5, 0xB7CDDF)
        // A hand-drawn b-shaped ribbon keeps the monogram independent of any font or system glyph.
        let ribbon = CGMutablePath()
        ribbon.move(to: CGPoint(x: 331, y: 244))
        ribbon.addCurve(to: CGPoint(x: 322, y: 605),
                        control1: CGPoint(x: 319, y: 385), control2: CGPoint(x: 322, y: 498))
        ribbon.addCurve(to: CGPoint(x: 731, y: 601),
                        control1: CGPoint(x: 322, y: 797), control2: CGPoint(x: 705, y: 799))
        ribbon.addCurve(to: CGPoint(x: 368, y: 497),
                        control1: CGPoint(x: 761, y: 379), control2: CGPoint(x: 514, y: 342))
        stroke(c, ribbon, 0x315671, width: 94)
        let air = CGMutablePath()
        air.move(to: CGPoint(x: 471, y: 622))
        air.addCurve(to: CGPoint(x: 636, y: 534),
                     control1: CGPoint(x: 536, y: 633), control2: CGPoint(x: 583, y: 597))
        stroke(c, air, 0x739DAB, width: 29)
    },
    IconRecipe(id: "Mic", title: "Sway") { c in
        background(c, 0xE5DEF1, 0xC8BDE3)
        let band = CGMutablePath()
        band.move(to: CGPoint(x: 256, y: 576))
        band.addCurve(to: CGPoint(x: 512, y: 251),
                      control1: CGPoint(x: 239, y: 355), control2: CGPoint(x: 350, y: 251))
        band.addCurve(to: CGPoint(x: 768, y: 576),
                      control1: CGPoint(x: 674, y: 251), control2: CGPoint(x: 785, y: 355))
        stroke(c, band, 0x4C3E65, width: 51)

        let left = CGMutablePath()
        left.move(to: CGPoint(x: 245, y: 500))
        left.addCurve(to: CGPoint(x: 344, y: 783),
                      control1: CGPoint(x: 151, y: 551), control2: CGPoint(x: 206, y: 720))
        left.addCurve(to: CGPoint(x: 245, y: 500),
                      control1: CGPoint(x: 434, y: 666), control2: CGPoint(x: 357, y: 543))
        fill(c, left, 0x4C3E65)
        let right = CGMutablePath()
        right.move(to: CGPoint(x: 779, y: 500))
        right.addCurve(to: CGPoint(x: 680, y: 783),
                       control1: CGPoint(x: 873, y: 551), control2: CGPoint(x: 818, y: 720))
        right.addCurve(to: CGPoint(x: 779, y: 500),
                       control1: CGPoint(x: 590, y: 666), control2: CGPoint(x: 667, y: 543))
        fill(c, right, 0x4C3E65)
    },
    IconRecipe(id: "Tabla", title: "Hush") { c in
        background(c, 0xECF0DD, 0xD4DECB)
        let left = CGMutablePath()
        left.move(to: CGPoint(x: 459, y: 233))
        left.addCurve(to: CGPoint(x: 412, y: 790),
                      control1: CGPoint(x: 212, y: 355), control2: CGPoint(x: 225, y: 650))
        left.addCurve(to: CGPoint(x: 459, y: 233),
                      control1: CGPoint(x: 508, y: 576), control2: CGPoint(x: 387, y: 442))
        fill(c, left, 0x305E52)
        let right = CGMutablePath()
        right.move(to: CGPoint(x: 626, y: 234))
        right.addCurve(to: CGPoint(x: 579, y: 791),
                       control1: CGPoint(x: 814, y: 374), control2: CGPoint(x: 826, y: 669))
        right.addCurve(to: CGPoint(x: 626, y: 234),
                       control1: CGPoint(x: 530, y: 558), control2: CGPoint(x: 673, y: 424))
        fill(c, right, 0x739883)
    },
    IconRecipe(id: "Sargam", title: "Flutter") { c in
        background(c, 0x244D41, 0x17372F)
        let stem = CGMutablePath()
        stem.move(to: CGPoint(x: 539, y: 414))
        stem.addCurve(to: CGPoint(x: 460, y: 735),
                      control1: CGPoint(x: 549, y: 559), control2: CGPoint(x: 522, y: 655))
        stroke(c, stem, 0xE2ECCE, width: 37)
        fill(c, ellipse(CGPoint(x: 409, y: 726), 89, 61, rotation: -0.38), 0xE2ECCE)
        let left = CGMutablePath()
        left.move(to: CGPoint(x: 537, y: 455))
        left.addCurve(to: CGPoint(x: 205, y: 269),
                      control1: CGPoint(x: 512, y: 251), control2: CGPoint(x: 329, y: 222))
        left.addCurve(to: CGPoint(x: 537, y: 455),
                      control1: CGPoint(x: 247, y: 472), control2: CGPoint(x: 411, y: 547))
        fill(c, left, 0xF7BC9B)
        let right = CGMutablePath()
        right.move(to: CGPoint(x: 534, y: 477))
        right.addCurve(to: CGPoint(x: 824, y: 292),
                       control1: CGPoint(x: 538, y: 326), control2: CGPoint(x: 687, y: 264))
        right.addCurve(to: CGPoint(x: 534, y: 477),
                       control1: CGPoint(x: 807, y: 478), control2: CGPoint(x: 676, y: 566))
        fill(c, right, 0xB7E7CC)
    },
    IconRecipe(id: "Bansuri", title: "Loop") { c in
        background(c, 0xF9908D, 0xD76679)
        let loop = CGMutablePath()
        loop.move(to: CGPoint(x: 512, y: 510))
        loop.addCurve(to: CGPoint(x: 234, y: 412),
                      control1: CGPoint(x: 414, y: 343), control2: CGPoint(x: 311, y: 304))
        loop.addCurve(to: CGPoint(x: 512, y: 510),
                      control1: CGPoint(x: 96, y: 651), control2: CGPoint(x: 350, y: 798))
        loop.addCurve(to: CGPoint(x: 790, y: 612),
                      control1: CGPoint(x: 674, y: 222), control2: CGPoint(x: 928, y: 374))
        loop.addCurve(to: CGPoint(x: 512, y: 510),
                      control1: CGPoint(x: 715, y: 722), control2: CGPoint(x: 610, y: 678))
        stroke(c, loop, 0xFFF1D9, width: 83)
        let leaf = CGMutablePath()
        leaf.move(to: CGPoint(x: 369, y: 437))
        leaf.addCurve(to: CGPoint(x: 270, y: 578),
                      control1: CGPoint(x: 273, y: 447), control2: CGPoint(x: 251, y: 506))
        leaf.addCurve(to: CGPoint(x: 369, y: 437),
                      control1: CGPoint(x: 365, y: 567), control2: CGPoint(x: 391, y: 501))
        fill(c, leaf, 0xFFF1D9)
    },
]

// MARK: - Rendering and output

private func bitmap(size: Int) throws -> CGContext {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw ArtworkError.contextCreation
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    return context
}

private func savePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw ArtworkError.imageEncoding(url)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ArtworkError.imageEncoding(url) }
}

private func render(_ recipe: IconRecipe) throws -> CGImage {
    let supersampling = 3
    let context = try bitmap(size: Int(canvas) * supersampling)
    context.translateBy(x: 0, y: canvas * CGFloat(supersampling))
    context.scaleBy(x: CGFloat(supersampling), y: -CGFloat(supersampling))
    recipe.draw(context)
    guard let large = context.makeImage() else { throw ArtworkError.contextCreation }
    let output = try bitmap(size: Int(canvas))
    output.draw(large, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    guard let image = output.makeImage() else { throw ArtworkError.contextCreation }
    return image
}

private func downscale(_ image: CGImage, to size: Int) throws -> CGImage {
    let context = try bitmap(size: size)
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let result = context.makeImage() else { throw ArtworkError.contextCreation }
    return result
}

private func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

private func validateOpaque(_ url: URL, width: Int, height: Int) throws {
    // PNG color type 2 is RGB without alpha; iOS rejects icons with transparency.
    let png = try Data(contentsOf: url)
    guard png.count > 26, png[24] == 8, png[25] == 2,
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
          decoded.width == width, decoded.height == height else { throw ArtworkError.invalidIcon(url.lastPathComponent) }
    let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
    print("Verified \(path): \(width)x\(height), 8-bit RGB, no alpha, \(png.count) bytes")
}

private func drawPreview(_ image: CGImage, in rect: CGRect, context: CGContext) {
    context.saveGState()
    context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 0.224, cornerHeight: rect.height * 0.224, transform: nil))
    context.clip()
    context.draw(image, in: rect)
    context.restoreGState()
}

private func drawCaption(_ text: String, font: CTFont, color: CGColor, centerX: CGFloat, baseline: CGFloat, context: CGContext) {
    let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
    let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
    let lineRef = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(lineRef, [])
    context.textPosition = CGPoint(x: centerX - bounds.width / 2, y: baseline)
    CTLineDraw(lineRef, context)
}

private func savePrimaryPreview(_ image: CGImage, to url: URL) throws {
    let context = try bitmap(size: 640)
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    for (row, backgroundHex) in [UInt32(0xF2F1EE), 0x111317].enumerated() {
        let bottom = CGFloat((1 - row) * 320)
        context.setFillColor(color(backgroundHex))
        context.fill(CGRect(x: 0, y: bottom, width: 640, height: 320))
        for (centerX, size) in [(CGFloat(168), CGFloat(240)), (408, 120), (550, 60)] {
            let rect = CGRect(x: centerX - size / 2, y: bottom + 168 - size / 2, width: size, height: size)
            drawPreview(image, in: rect, context: context)
            drawCaption("Breezy", font: font, color: color(row == 0 ? 0x1C2428 : 0xF2F1EE),
                        centerX: rect.midX, baseline: rect.minY - 28, context: context)
        }
    }
    guard let preview = context.makeImage() else { throw ArtworkError.contextCreation }
    try savePNG(preview, to: url)
    try validateOpaque(url, width: 640, height: 640)
}

private func saveContactSheet(_ images: [(IconRecipe, CGImage)], to url: URL) throws {
    let columns = 4, cell = 240, tile = 152, rowHeight = 204, header = 108
    let rows = (images.count + columns - 1) / columns
    let width = columns * cell, height = header + rows * rowHeight + 36
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw ArtworkError.contextCreation
    }
    context.setFillColor(color(0x151C21))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawCaption("Breezy", font: CTFontCreateWithName("Helvetica-Bold" as CFString, 32, nil), color: color(0xEFF4EF),
                centerX: CGFloat(width) / 2, baseline: CGFloat(height - 49), context: context)
    drawCaption("\(images.count) original music icons", font: CTFontCreateWithName("Helvetica" as CFString, 16, nil), color: color(0xA7B9B5),
                centerX: CGFloat(width) / 2, baseline: CGFloat(height - 76), context: context)
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 20, nil)
    for (index, (recipe, image)) in images.enumerated() {
        let column = index % columns, row = index / columns
        let itemsInRow = min(columns, images.count - row * columns)
        let rowInset = (width - itemsInRow * cell) / 2
        let origin = CGPoint(x: rowInset + column * cell + (cell - tile) / 2, y: height - header - row * rowHeight - tile)
        let rect = CGRect(origin: origin, size: CGSize(width: tile, height: tile))
        drawPreview(image, in: rect, context: context)
        drawCaption("\(index + 1). \(recipe.title)", font: font, color: color(0xFFFFFF),
                    centerX: rect.midX, baseline: rect.minY - 31, context: context)
    }
    guard let sheet = context.makeImage() else { throw ArtworkError.contextCreation }
    try savePNG(sheet, to: url)
    try validateOpaque(url, width: width, height: height)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count.isMultiple(of: 2) else { throw ArtworkError.invalidArguments }
var previewURLs: [String: URL] = [:]
for index in stride(from: 0, to: arguments.count, by: 2) {
    let flag = arguments[index]
    guard ["--preview", "--primary-preview"].contains(flag), previewURLs[flag] == nil else { throw ArtworkError.invalidArguments }
    previewURLs[flag] = URL(fileURLWithPath: arguments[index + 1])
}

// Stale sets from earlier recipe lists are removed so the catalog only contains current options.
for entry in try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
where entry.lastPathComponent.hasPrefix("AppIcon-") || entry.lastPathComponent.hasPrefix("IconPreview-") || entry.lastPathComponent == "BrandMark.imageset" {
    try FileManager.default.removeItem(at: entry)
}

private var rendered: [(IconRecipe, CGImage)] = []
for (index, recipe) in recipes.enumerated() {
    let image = try render(recipe)
    // The primary retains its named alternate asset so saved iOS selections survive a default change.
    let iconNames = index == 0 ? ["AppIcon", "AppIcon-\(recipe.id)"] : ["AppIcon-\(recipe.id)"]
    for name in iconNames {
        let iconSet = assets.appendingPathComponent("\(name).appiconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
        let iconURL = iconSet.appendingPathComponent("AppIcon.png")
        try savePNG(image, to: iconURL)
        try validateOpaque(iconURL, width: 1024, height: 1024)
        try writeJSON(["images": [["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
                       "info": ["author": "xcode", "version": 1]], to: iconSet.appendingPathComponent("Contents.json"))
    }

    let previewSet = assets.appendingPathComponent("IconPreview-\(recipe.id).imageset", isDirectory: true)
    try FileManager.default.createDirectory(at: previewSet, withIntermediateDirectories: true)
    let previewURL = previewSet.appendingPathComponent("preview.png")
    try savePNG(try downscale(image, to: 240), to: previewURL)
    try validateOpaque(previewURL, width: 240, height: 240)
    try writeJSON(["images": [["filename": "preview.png", "idiom": "universal"]],
                   "info": ["author": "xcode", "version": 1]], to: previewSet.appendingPathComponent("Contents.json"))
    rendered.append((recipe, image))
}

print("Created \(recipes.count) visible choices and \(recipes.count + 1) icon sets: " + recipes.map { "\($0.id)=\($0.title)" }.joined(separator: ", "))
if let primary = recipes.first {
    print("Primary: AppIcon (\(primary.id)=\(primary.title)); hidden compatibility alternate: AppIcon-\(primary.id)")
}
print("Alternate icon names: " + recipes.map { "AppIcon-\($0.id)" }.joined(separator: " "))
if let url = previewURLs["--preview"] {
    try saveContactSheet(rendered, to: url)
}
if let url = previewURLs["--primary-preview"], let primary = rendered.first {
    try savePrimaryPreview(primary.1, to: url)
}
