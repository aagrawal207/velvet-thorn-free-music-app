#!/usr/bin/env swift
// Original Breezy icons use CoreGraphics paths; fonts appear only in preview captions, never in icons.

// swift tools/generate-artwork.swift [--icons ID,ID] [--preview path/contact-sheet.png]
//     [--primary-preview path/icon-preview.png] [--icon-previews path/directory]

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
    case unknownIconID(String)
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

// MARK: - Rose and fountain pen drawing

private func roseLeaf(_ context: CGContext, base: CGPoint, length: CGFloat, angle: CGFloat,
                      pigment: UInt32, vein: UInt32) {
    context.saveGState()
    context.translateBy(x: base.x, y: base.y)
    context.rotate(by: angle)
    context.scaleBy(x: length / 180, y: length / 180)

    let leaf = CGMutablePath()
    leaf.move(to: .zero)
    leaf.addCurve(to: CGPoint(x: 40, y: -37), control1: CGPoint(x: 10, y: -31), control2: CGPoint(x: 18, y: -41))
    leaf.addLine(to: CGPoint(x: 49, y: -32))
    leaf.addCurve(to: CGPoint(x: 74, y: -47), control1: CGPoint(x: 56, y: -47), control2: CGPoint(x: 63, y: -47))
    leaf.addLine(to: CGPoint(x: 78, y: -39))
    leaf.addCurve(to: CGPoint(x: 132, y: -32), control1: CGPoint(x: 100, y: -51), control2: CGPoint(x: 116, y: -44))
    leaf.addLine(to: CGPoint(x: 130, y: -21))
    leaf.addCurve(to: CGPoint(x: 180, y: 0), control1: CGPoint(x: 150, y: -19), control2: CGPoint(x: 160, y: -6))
    leaf.addCurve(to: CGPoint(x: 139, y: 26), control1: CGPoint(x: 161, y: 11), control2: CGPoint(x: 157, y: 23))
    leaf.addLine(to: CGPoint(x: 125, y: 22))
    leaf.addLine(to: CGPoint(x: 114, y: 38))
    leaf.addCurve(to: CGPoint(x: 71, y: 39), control1: CGPoint(x: 100, y: 46), control2: CGPoint(x: 84, y: 49))
    leaf.addLine(to: CGPoint(x: 68, y: 29))
    leaf.addLine(to: CGPoint(x: 48, y: 35))
    leaf.addCurve(to: .zero, control1: CGPoint(x: 19, y: 34), control2: CGPoint(x: 9, y: 18))
    leaf.closeSubpath()
    fill(context, leaf, pigment)

    let midrib = CGMutablePath()
    midrib.move(to: CGPoint(x: 14, y: 0))
    midrib.addCurve(to: CGPoint(x: 147, y: 0), control1: CGPoint(x: 63, y: 13), control2: CGPoint(x: 109, y: 2))
    stroke(context, midrib, vein, width: 11)
    let veins = CGMutablePath()
    veins.move(to: CGPoint(x: 53, y: 6))
    veins.addQuadCurve(to: CGPoint(x: 44, y: -20), control: CGPoint(x: 44, y: -3))
    veins.move(to: CGPoint(x: 87, y: 5))
    veins.addQuadCurve(to: CGPoint(x: 105, y: 29), control: CGPoint(x: 94, y: 20))
    stroke(context, veins, vein, width: 6)
    context.restoreGState()
}

private func fountainPen(_ context: CGContext, center: CGPoint, angle: CGFloat, scale: CGFloat = 1,
                         barrel: UInt32, nib: UInt32, trim: UInt32, ink: UInt32) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: angle)
    context.scaleBy(x: scale, y: scale)

    let body = CGMutablePath()
    body.move(to: CGPoint(x: -346, y: -47))
    body.addCurve(to: CGPoint(x: -396, y: 0), control1: CGPoint(x: -380, y: -47), control2: CGPoint(x: -396, y: -26))
    body.addCurve(to: CGPoint(x: -346, y: 47), control1: CGPoint(x: -396, y: 26), control2: CGPoint(x: -380, y: 47))
    body.addLine(to: CGPoint(x: 150, y: 47))
    body.addCurve(to: CGPoint(x: 177, y: 30), control1: CGPoint(x: 166, y: 47), control2: CGPoint(x: 177, y: 40))
    body.addLine(to: CGPoint(x: 177, y: -30))
    body.addCurve(to: CGPoint(x: 150, y: -47), control1: CGPoint(x: 177, y: -40), control2: CGPoint(x: 166, y: -47))
    body.closeSubpath()
    stroke(context, body, ink, width: 18)
    fill(context, body, barrel)

    let capSeam = CGMutablePath()
    capSeam.move(to: CGPoint(x: -209, y: -44))
    capSeam.addLine(to: CGPoint(x: -209, y: 44))
    stroke(context, capSeam, ink, width: 11)
    let clip = CGMutablePath()
    clip.move(to: CGPoint(x: -348, y: -17))
    clip.addCurve(to: CGPoint(x: -247, y: -22), control1: CGPoint(x: -340, y: -29), control2: CGPoint(x: -274, y: -27))
    stroke(context, clip, ink, width: 13)

    let grip = CGPath(roundedRect: CGRect(x: 108, y: -42, width: 86, height: 84),
                      cornerWidth: 14, cornerHeight: 14, transform: nil)
    fill(context, grip, ink)
    fill(context, CGPath(rect: CGRect(x: 108, y: -42, width: 18, height: 84), transform: nil), trim)

    // Broad shoulders, a large breather hole and split tines keep the nib readable at Home Screen size.
    let point = CGMutablePath()
    point.move(to: CGPoint(x: 176, y: -43))
    point.addLine(to: CGPoint(x: 207, y: -64))
    point.addCurve(to: CGPoint(x: 251, y: -82), control1: CGPoint(x: 221, y: -79), control2: CGPoint(x: 235, y: -86))
    point.addCurve(to: CGPoint(x: 420, y: 0), control1: CGPoint(x: 299, y: -48), control2: CGPoint(x: 357, y: -17))
    point.addCurve(to: CGPoint(x: 251, y: 82), control1: CGPoint(x: 357, y: 17), control2: CGPoint(x: 299, y: 48))
    point.addCurve(to: CGPoint(x: 207, y: 64), control1: CGPoint(x: 235, y: 86), control2: CGPoint(x: 221, y: 79))
    point.addLine(to: CGPoint(x: 176, y: 43))
    point.closeSubpath()
    stroke(context, point, ink, width: 18)
    fillGradient(context, point, [(0, nib), (0.6, nib), (1, trim)],
                 from: CGPoint(x: 260, y: -82), to: CGPoint(x: 290, y: 82))

    let wings = CGMutablePath()
    wings.move(to: CGPoint(x: 211, y: -37))
    wings.addCurve(to: CGPoint(x: 328, y: -19), control1: CGPoint(x: 232, y: -62), control2: CGPoint(x: 285, y: -38))
    wings.move(to: CGPoint(x: 211, y: 37))
    wings.addCurve(to: CGPoint(x: 328, y: 19), control1: CGPoint(x: 232, y: 62), control2: CGPoint(x: 285, y: 38))
    stroke(context, wings, ink, width: 7, alpha: 0.7)
    let sheen = CGMutablePath()
    sheen.move(to: CGPoint(x: -340, y: 24))
    sheen.addLine(to: CGPoint(x: 83, y: 24))
    stroke(context, sheen, trim, width: 9)

    context.saveGState()
    context.addPath(point)
    context.clip()
    let slit = CGMutablePath()
    slit.move(to: CGPoint(x: 271, y: 0))
    slit.addLine(to: CGPoint(x: 424, y: 0))
    stroke(context, slit, ink, width: 17)
    fill(context, circle(CGPoint(x: 271, y: 0), 21), ink)
    context.restoreGState()
    context.restoreGState()
}

/// Colors for the shared rose-and-pen composition. Ink doubles as every outline, vein, and pen detail, so it
/// should sit close to the background: on dark art it reads as shadowed seams, on paper as light paper gaps.
private struct RosePalette {
    let backgroundTop: UInt32
    let backgroundBottom: UInt32
    let ink: UInt32
    let stem: UInt32
    let leafLeft: UInt32
    let leafRight: UInt32
    let leafLower: UInt32
    let bloom: [(CGFloat, UInt32)]
    let outerFold: UInt32
    let leftPetal: [(CGFloat, UInt32)]
    let lowerPetal: [(CGFloat, UInt32)]
    let rightPetal: [(CGFloat, UInt32)]
    let heart: [(CGFloat, UInt32)]
    let engraving: UInt32
    let penBarrel: UInt32
    let penNib: UInt32
    let penTrim: UInt32
}

/// One fixed composition for every rose variant so the choices differ by mood alone. Draw order is part of
/// the design: the pen sits between the outer bloom and the cupped front petals to make the crossing tangible.
private func rosePen(_ c: CGContext, palette: RosePalette) {
    background(c, palette.backgroundTop, palette.backgroundBottom)
    let ink = palette.ink
    let stem = CGMutablePath()
    stem.move(to: CGPoint(x: 385, y: 590))
    stem.addCurve(to: CGPoint(x: 743, y: 756),
                  control1: CGPoint(x: 597, y: 650), control2: CGPoint(x: 599, y: 784))
    stroke(c, stem, palette.stem, width: 20)
    roseLeaf(c, base: CGPoint(x: 321, y: 448), length: 222, angle: -2.48, pigment: palette.leafLeft, vein: ink)
    roseLeaf(c, base: CGPoint(x: 593, y: 588), length: 226, angle: 0.2, pigment: palette.leafRight, vein: ink)
    roseLeaf(c, base: CGPoint(x: 583, y: 695), length: 174, angle: 0.88, pigment: palette.leafLower, vein: ink)

    let thorns = CGMutablePath()
    thorns.move(to: CGPoint(x: 624, y: 724))
    thorns.addQuadCurve(to: CGPoint(x: 648, y: 674), control: CGPoint(x: 649, y: 711))
    thorns.addQuadCurve(to: CGPoint(x: 653, y: 743), control: CGPoint(x: 673, y: 718))
    thorns.closeSubpath()
    thorns.move(to: CGPoint(x: 548, y: 669))
    thorns.addQuadCurve(to: CGPoint(x: 527, y: 714), control: CGPoint(x: 550, y: 696))
    thorns.addQuadCurve(to: CGPoint(x: 577, y: 687), control: CGPoint(x: 561, y: 714))
    thorns.closeSubpath()
    fill(c, thorns, palette.stem)

    c.saveGState()
    c.translateBy(x: 451, y: 459)
    let bloom = CGMutablePath()
    bloom.move(to: CGPoint(x: -182, y: 32))
    bloom.addCurve(to: CGPoint(x: -213, y: -71), control1: CGPoint(x: -246, y: -4), control2: CGPoint(x: -240, y: -46))
    bloom.addCurve(to: CGPoint(x: -139, y: -149), control1: CGPoint(x: -198, y: -118), control2: CGPoint(x: -202, y: -145))
    bloom.addCurve(to: CGPoint(x: -26, y: -192), control1: CGPoint(x: -133, y: -204), control2: CGPoint(x: -53, y: -217))
    bloom.addCurve(to: CGPoint(x: 84, y: -173), control1: CGPoint(x: 14, y: -227), control2: CGPoint(x: 68, y: -209))
    bloom.addCurve(to: CGPoint(x: 169, y: -103), control1: CGPoint(x: 149, y: -195), control2: CGPoint(x: 195, y: -157))
    bloom.addCurve(to: CGPoint(x: 208, y: -16), control1: CGPoint(x: 225, y: -86), control2: CGPoint(x: 246, y: -53))
    bloom.addCurve(to: CGPoint(x: 195, y: 84), control1: CGPoint(x: 250, y: 31), control2: CGPoint(x: 236, y: 70))
    bloom.addCurve(to: CGPoint(x: 107, y: 171), control1: CGPoint(x: 204, y: 135), control2: CGPoint(x: 157, y: 190))
    bloom.addCurve(to: CGPoint(x: -14, y: 203), control1: CGPoint(x: 66, y: 211), control2: CGPoint(x: 28, y: 218))
    bloom.addCurve(to: CGPoint(x: -141, y: 158), control1: CGPoint(x: -65, y: 211), control2: CGPoint(x: -126, y: 204))
    bloom.addCurve(to: CGPoint(x: -208, y: 96), control1: CGPoint(x: -207, y: 163), control2: CGPoint(x: -241, y: 130))
    bloom.addCurve(to: CGPoint(x: -182, y: 32), control1: CGPoint(x: -229, y: 70), control2: CGPoint(x: -215, y: 53))
    bloom.closeSubpath()
    fillGradient(c, bloom, palette.bloom, from: CGPoint(x: -170, y: -190), to: CGPoint(x: 169, y: 190))
    stroke(c, bloom, ink, width: 18)
    let outerFolds = CGMutablePath()
    outerFolds.move(to: CGPoint(x: -132, y: -145))
    outerFolds.addCurve(to: CGPoint(x: 41, y: -148), control1: CGPoint(x: -88, y: -185), control2: CGPoint(x: -10, y: -179))
    outerFolds.move(to: CGPoint(x: 103, y: -139))
    outerFolds.addQuadCurve(to: CGPoint(x: 177, y: -78), control: CGPoint(x: 164, y: -147))
    stroke(c, outerFolds, palette.outerFold, width: 10, alpha: 0.75)
    c.restoreGState()

    fountainPen(c, center: CGPoint(x: 514, y: 531), angle: .pi * 3 / 4,
                barrel: palette.penBarrel, nib: palette.penNib, trim: palette.penTrim, ink: ink)

    c.saveGState()
    c.translateBy(x: 451, y: 459)
    let leftPetal = CGMutablePath()
    leftPetal.move(to: CGPoint(x: -167, y: -75))
    leftPetal.addCurve(to: CGPoint(x: -87, y: -93), control1: CGPoint(x: -137, y: -119), control2: CGPoint(x: -102, y: -111))
    leftPetal.addCurve(to: CGPoint(x: -26, y: -27), control1: CGPoint(x: -49, y: -86), control2: CGPoint(x: -43, y: -71))
    leftPetal.addCurve(to: CGPoint(x: 13, y: 74), control1: CGPoint(x: -44, y: 28), control2: CGPoint(x: -31, y: 58))
    leftPetal.addCurve(to: CGPoint(x: -127, y: 120), control1: CGPoint(x: -64, y: 116), control2: CGPoint(x: -105, y: 94))
    leftPetal.addCurve(to: CGPoint(x: -190, y: 31), control1: CGPoint(x: -191, y: 107), control2: CGPoint(x: -218, y: 51))
    leftPetal.addCurve(to: CGPoint(x: -167, y: -75), control1: CGPoint(x: -210, y: -17), control2: CGPoint(x: -204, y: -45))
    leftPetal.closeSubpath()
    fillGradient(c, leftPetal, palette.leftPetal, from: CGPoint(x: -180, y: -80), to: CGPoint(x: -30, y: 120))
    stroke(c, leftPetal, ink, width: 16)

    let lowerPetal = CGMutablePath()
    lowerPetal.move(to: CGPoint(x: -154, y: 78))
    lowerPetal.addCurve(to: CGPoint(x: -41, y: 103), control1: CGPoint(x: -112, y: 91), control2: CGPoint(x: -77, y: 101))
    lowerPetal.addCurve(to: CGPoint(x: 66, y: 81), control1: CGPoint(x: 17, y: 116), control2: CGPoint(x: 26, y: 95))
    lowerPetal.addCurve(to: CGPoint(x: 153, y: 19), control1: CGPoint(x: 92, y: 53), control2: CGPoint(x: 104, y: 15))
    lowerPetal.addCurve(to: CGPoint(x: 160, y: 136), control1: CGPoint(x: 183, y: 52), control2: CGPoint(x: 187, y: 108))
    lowerPetal.addCurve(to: CGPoint(x: -14, y: 197), control1: CGPoint(x: 133, y: 180), control2: CGPoint(x: 61, y: 221))
    lowerPetal.addCurve(to: CGPoint(x: -154, y: 78), control1: CGPoint(x: -92, y: 189), control2: CGPoint(x: -172, y: 144))
    lowerPetal.closeSubpath()
    fillGradient(c, lowerPetal, palette.lowerPetal, from: CGPoint(x: -10, y: 72), to: CGPoint(x: 30, y: 213))
    stroke(c, lowerPetal, ink, width: 17)

    let rightPetal = CGMutablePath()
    rightPetal.move(to: CGPoint(x: 40, y: -129))
    rightPetal.addCurve(to: CGPoint(x: 169, y: -111), control1: CGPoint(x: 72, y: -166), control2: CGPoint(x: 128, y: -161))
    rightPetal.addCurve(to: CGPoint(x: 168, y: -6), control1: CGPoint(x: 225, y: -66), control2: CGPoint(x: 206, y: -32))
    rightPetal.addCurve(to: CGPoint(x: 66, y: 92), control1: CGPoint(x: 151, y: 42), control2: CGPoint(x: 140, y: 81))
    rightPetal.addCurve(to: CGPoint(x: 16, y: 61), control1: CGPoint(x: 42, y: 127), control2: CGPoint(x: 17, y: 88))
    rightPetal.addCurve(to: CGPoint(x: 49, y: -10), control1: CGPoint(x: 6, y: 23), control2: CGPoint(x: 46, y: 25))
    rightPetal.addCurve(to: CGPoint(x: 40, y: -129), control1: CGPoint(x: 116, y: -33), control2: CGPoint(x: 91, y: -99))
    rightPetal.closeSubpath()
    fillGradient(c, rightPetal, palette.rightPetal, from: CGPoint(x: 109, y: -140), to: CGPoint(x: 51, y: 110))
    stroke(c, rightPetal, ink, width: 17)

    let heart = CGMutablePath()
    heart.move(to: CGPoint(x: -100, y: -98))
    heart.addCurve(to: CGPoint(x: 44, y: -130), control1: CGPoint(x: -71, y: -159), control2: CGPoint(x: 7, y: -151))
    heart.addCurve(to: CGPoint(x: 104, y: -50), control1: CGPoint(x: 94, y: -139), control2: CGPoint(x: 129, y: -88))
    heart.addCurve(to: CGPoint(x: 34, y: 22), control1: CGPoint(x: 116, y: 0), control2: CGPoint(x: 75, y: 21))
    heart.addCurve(to: CGPoint(x: -56, y: 42), control1: CGPoint(x: 13, y: 66), control2: CGPoint(x: -30, y: 73))
    heart.addCurve(to: CGPoint(x: -106, y: -35), control1: CGPoint(x: -111, y: 47), control2: CGPoint(x: -122, y: 4))
    heart.addCurve(to: CGPoint(x: -100, y: -98), control1: CGPoint(x: -142, y: -70), control2: CGPoint(x: -112, y: -101))
    heart.closeSubpath()
    fillGradient(c, heart, palette.heart, from: CGPoint(x: -56, y: -143), to: CGPoint(x: 29, y: 51))
    stroke(c, heart, ink, width: 16)
    let spiral = CGMutablePath()
    spiral.move(to: CGPoint(x: -84, y: -63))
    spiral.addCurve(to: CGPoint(x: 58, y: -91), control1: CGPoint(x: -42, y: -109), control2: CGPoint(x: 20, y: -112))
    spiral.addCurve(to: CGPoint(x: 61, y: -14), control1: CGPoint(x: 95, y: -65), control2: CGPoint(x: 97, y: -41))
    spiral.addCurve(to: CGPoint(x: -7, y: 1), control1: CGPoint(x: 39, y: 15), control2: CGPoint(x: 6, y: 18))
    spiral.addCurve(to: CGPoint(x: -37, y: -44), control1: CGPoint(x: -45, y: -1), control2: CGPoint(x: -59, y: -35))
    spiral.addCurve(to: CGPoint(x: 27, y: -47), control1: CGPoint(x: -22, y: -66), control2: CGPoint(x: 12, y: -69))
    stroke(c, spiral, ink, width: 20)

    let engraving = CGMutablePath()
    engraving.move(to: CGPoint(x: -174, y: -26))
    engraving.addQuadCurve(to: CGPoint(x: -149, y: 39), control: CGPoint(x: -180, y: 16))
    engraving.move(to: CGPoint(x: -157, y: -26))
    engraving.addQuadCurve(to: CGPoint(x: -128, y: 44), control: CGPoint(x: -163, y: 16))
    engraving.move(to: CGPoint(x: -141, y: -18))
    engraving.addQuadCurve(to: CGPoint(x: -109, y: 46), control: CGPoint(x: -144, y: 17))
    engraving.move(to: CGPoint(x: 140, y: -94))
    engraving.addQuadCurve(to: CGPoint(x: 149, y: -37), control: CGPoint(x: 164, y: -75))
    engraving.move(to: CGPoint(x: 125, y: -87))
    engraving.addQuadCurve(to: CGPoint(x: 131, y: -33), control: CGPoint(x: 145, y: -67))
    engraving.move(to: CGPoint(x: -76, y: 138))
    engraving.addQuadCurve(to: CGPoint(x: -16, y: 162), control: CGPoint(x: -48, y: 160))
    engraving.move(to: CGPoint(x: -82, y: 151))
    engraving.addQuadCurve(to: CGPoint(x: -18, y: 177), control: CGPoint(x: -53, y: 175))
    engraving.move(to: CGPoint(x: 80, y: 139))
    engraving.addQuadCurve(to: CGPoint(x: 128, y: 99), control: CGPoint(x: 114, y: 132))
    stroke(c, engraving, palette.engraving, width: 6, alpha: 0.7)
    c.restoreGState()
}

// MARK: - Recipes

private struct IconRecipe {
    let id: String
    let title: String
    let draw: (CGContext) -> Void
}

/// Colours for the shared Leafnote composition: one note whose flag is a leaf.
private struct NotePalette {
    let top: UInt32
    let bottom: UInt32
    let note: UInt32
    let flag: UInt32
}

private func leafnote(_ c: CGContext, _ palette: NotePalette) {
    background(c, palette.top, palette.bottom)
    let stem = CGMutablePath()
    stem.move(to: CGPoint(x: 493, y: 667))
    stem.addCurve(to: CGPoint(x: 553, y: 258),
                  control1: CGPoint(x: 566, y: 515), control2: CGPoint(x: 565, y: 369))
    stroke(c, stem, palette.note, width: 52)

    let head = CGMutablePath()
    head.move(to: CGPoint(x: 551, y: 570))
    head.addCurve(to: CGPoint(x: 247, y: 779),
                  control1: CGPoint(x: 371, y: 561), control2: CGPoint(x: 269, y: 653))
    head.addCurve(to: CGPoint(x: 551, y: 570),
                  control1: CGPoint(x: 447, y: 806), control2: CGPoint(x: 561, y: 722))
    fill(c, head, palette.note)

    let flag = CGMutablePath()
    flag.move(to: CGPoint(x: 552, y: 242))
    flag.addCurve(to: CGPoint(x: 783, y: 439),
                  control1: CGPoint(x: 648, y: 329), control2: CGPoint(x: 801, y: 282))
    flag.addCurve(to: CGPoint(x: 552, y: 304),
                  control1: CGPoint(x: 685, y: 469), control2: CGPoint(x: 590, y: 404))
    flag.closeSubpath()
    fill(c, flag, palette.flag)
}

/// A rose variant from five petal tones, lightest first; the gradients reuse them in a fixed pattern.
private func roseVariant(background: (UInt32, UInt32), ink: UInt32, stem: UInt32, leaves: (UInt32, UInt32, UInt32),
                         petals: [UInt32], fold: UInt32, engraving: UInt32,
                         pen: (barrel: UInt32, nib: UInt32, trim: UInt32)) -> RosePalette {
    precondition(petals.count == 5)
    let (p0, p1, p2, p3, p4) = (petals[0], petals[1], petals[2], petals[3], petals[4])
    return RosePalette(
        backgroundTop: background.0, backgroundBottom: background.1, ink: ink, stem: stem,
        leafLeft: leaves.0, leafRight: leaves.1, leafLower: leaves.2,
        bloom: [(0, p2), (0.5, p3), (1, p4)], outerFold: fold,
        leftPetal: [(0, p1), (0.55, p2), (1, p3)], lowerPetal: [(0, p1), (1, p3)], rightPetal: [(0, p1), (1, p3)],
        heart: [(0, p0), (0.45, p1), (1, p2)], engraving: engraving,
        penBarrel: pen.barrel, penNib: pen.nib, penTrim: pen.trim)
}

private func leafnoteRecipe(_ id: String, _ title: String, _ palette: NotePalette) -> IconRecipe {
    IconRecipe(id: id, title: title) { leafnote($0, palette) }
}

private func roseRecipe(_ id: String, _ title: String, _ palette: RosePalette) -> IconRecipe {
    IconRecipe(id: id, title: title) { rosePen($0, palette: palette) }
}

private let recipes: [IconRecipe] = [
    leafnoteRecipe("Beat", "Leafnote", NotePalette(top: 0x27272F, bottom: 0x161A23, note: 0xA7EDD3, flag: 0xFF9B8F)),
    leafnoteRecipe("LeafPaper", "Paper", NotePalette(top: 0xFBF7EF, bottom: 0xEFE7D8, note: 0x2E7D64, flag: 0xE8604F)),
    leafnoteRecipe("LeafSky", "Sky", NotePalette(top: 0xEAF4FF, bottom: 0xD4E6FB, note: 0x1E5FB8, flag: 0xFF8A5B)),
    leafnoteRecipe("LeafBlossom", "Blossom", NotePalette(top: 0xFFF0F4, bottom: 0xF8DCE5, note: 0xB93080, flag: 0x2FA58C)),
    leafnoteRecipe("LeafMidnight", "Midnight", NotePalette(top: 0x1A2340, bottom: 0x0B1022, note: 0x9CC3FF, flag: 0xFFC15A)),
    leafnoteRecipe("LeafViolet", "Violet", NotePalette(top: 0x241B3D, bottom: 0x120D24, note: 0xC9B4FF, flag: 0x4DE0B0)),
    leafnoteRecipe("LeafSunset", "Sunset", NotePalette(top: 0xFFB38A, bottom: 0xE8707A, note: 0xFFF6E6, flag: 0x5A2340)),
    leafnoteRecipe("LeafMono", "Mono", NotePalette(top: 0xF4F4F6, bottom: 0xE2E2E7, note: 0x16161A, flag: 0xDC3159)),
    IconRecipe(id: "Thorn", title: "Thorn") { c in
        rosePen(c, palette: RosePalette(
            backgroundTop: 0x17141C, backgroundBottom: 0x080F18, ink: 0x21151F, stem: 0x914451,
            leafLeft: 0x914451, leafRight: 0xA34A57, leafLower: 0x80404E,
            bloom: [(0, 0xC5404D), (0.5, 0xA82A42), (1, 0x73233B)], outerFold: 0xEF8174,
            leftPetal: [(0, 0xED6260), (0.55, 0xD23B4C), (1, 0xA52B42)],
            lowerPetal: [(0, 0xE15259), (1, 0xA32740)],
            rightPetal: [(0, 0xEC5E60), (1, 0xB72C43)],
            heart: [(0, 0xF5796C), (0.45, 0xE34B54), (1, 0xC53247)], engraving: 0xFFC0A0,
            penBarrel: 0xF0E1C6, penNib: 0xFFF3DB, penTrim: 0xCBA779))
    },
    IconRecipe(id: "Sonnet", title: "Sonnet") { c in
        // Paper ink and mauve petals keep the cream mood; the petals stay dark enough to read on the paper.
        rosePen(c, palette: RosePalette(
            backgroundTop: 0xFFF3E2, backgroundBottom: 0xEFE0CD, ink: 0xF8EBDA, stem: 0xAD7A68,
            leafLeft: 0xBA8776, leafRight: 0xC58D7C, leafLower: 0xA8756A,
            bloom: [(0, 0x9E5468), (0.5, 0x7E3A52), (1, 0x52243A)], outerFold: 0xDDA9B3,
            leftPetal: [(0, 0xBE7385), (0.55, 0x9C4F66), (1, 0x76354B)],
            lowerPetal: [(0, 0xB4667B), (1, 0x7A3750)],
            rightPetal: [(0, 0xBC7083), (1, 0x86405A)],
            heart: [(0, 0xCE8593), (0.45, 0xB0607A), (1, 0x944762)], engraving: 0xEEC3CB,
            penBarrel: 0x733949, penNib: 0x773549, penTrim: 0xA96770))
    },
    roseRecipe("ThornEdge", "Edge", roseVariant(
        background: (0x0E1424, 0x05080F), ink: 0x111A2C, stem: 0x3D5A80, leaves: (0x3D5A80, 0x4A6B94, 0x34506F),
        petals: [0x9CC8FF, 0x5C9DF5, 0x2F6FD6, 0x1E4FA8, 0x142F6B], fold: 0xA9D1FF, engraving: 0xCFE4FF,
        pen: (0xD7263D, 0xFF5A5F, 0x8E1022))),
    roseRecipe("ThornFrost", "Frost", roseVariant(
        background: (0xEEF4FB, 0xDCE7F3), ink: 0xF2F7FC, stem: 0x6F8BA8, leaves: (0x7D98B4, 0x8AA5C0, 0x6A85A2),
        petals: [0x8FB6E8, 0x5E8FD0, 0x3D6DB5, 0x2A5193, 0x1C3A6E], fold: 0xBCD4F0, engraving: 0xDCE8F7,
        pen: (0xC8243A, 0xE14B57, 0x8C1427))),
    roseRecipe("ThornNoir", "Noir", roseVariant(
        background: (0x101012, 0x050506), ink: 0x18181B, stem: 0x4A4A50, leaves: (0x4A4A50, 0x56565D, 0x3E3E44),
        petals: [0xF2F2F2, 0xD6D6D8, 0xB3B3B8, 0x86868C, 0x55555B], fold: 0xFFFFFF, engraving: 0xFFFFFF,
        pen: (0xD7263D, 0xFF5A5F, 0x8E1022))),
    roseRecipe("ThornVenom", "Venom", roseVariant(
        background: (0x0D1410, 0x050906), ink: 0x101A13, stem: 0x2F6B45, leaves: (0x2F6B45, 0x3A7D52, 0x285C3B),
        petals: [0xC6FF8A, 0x8EE65C, 0x5BC23D, 0x3A9429, 0x22621B], fold: 0xD8FFAD, engraving: 0xE8FFD0,
        pen: (0x7A2BD6, 0xA25CFF, 0x4A148C))),
    roseRecipe("ThornDusk", "Dusk", roseVariant(
        background: (0x2A1838, 0x120A1E), ink: 0x241530, stem: 0x7A4E7E, leaves: (0x7A4E7E, 0x8A5A8E, 0x6A446E),
        petals: [0xFFC48A, 0xFF9E5E, 0xF2773F, 0xC9552C, 0x8E3720], fold: 0xFFD8B0, engraving: 0xFFE3C8,
        pen: (0x2EC4B6, 0x7FE7DC, 0x16867C))),
    roseRecipe("ThornBlush", "Blush", roseVariant(
        background: (0xFFF0F3, 0xF7DDE3), ink: 0xFFF5F7, stem: 0xC08A93, leaves: (0xC9959E, 0xD3A0A9, 0xB98690),
        petals: [0xFF9FB4, 0xF27593, 0xD94F74, 0xAE3A5B, 0x7C2944], fold: 0xFFC6D3, engraving: 0xFFE0E7,
        pen: (0x2B3A55, 0x46597D, 0x16213A))),
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

private func saveIconPreview(_ image: CGImage, to url: URL) throws {
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
    drawCaption("\(images.count) original icon choices", font: CTFontCreateWithName("Helvetica" as CFString, 16, nil), color: color(0xA7B9B5),
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
var selectedIDs: Set<String>?
for index in stride(from: 0, to: arguments.count, by: 2) {
    let flag = arguments[index]
    let value = arguments[index + 1]
    guard !value.isEmpty else { throw ArtworkError.invalidArguments }
    if flag == "--icons" {
        guard selectedIDs == nil else { throw ArtworkError.invalidArguments }
        let ids = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !ids.isEmpty, !ids.contains(""), Set(ids).count == ids.count else { throw ArtworkError.invalidArguments }
        for id in ids where !recipes.contains(where: { $0.id == id }) {
            throw ArtworkError.unknownIconID(id)
        }
        selectedIDs = Set(ids)
    } else {
        guard ["--preview", "--primary-preview", "--icon-previews"].contains(flag), previewURLs[flag] == nil else {
            throw ArtworkError.invalidArguments
        }
        previewURLs[flag] = URL(fileURLWithPath: value)
    }
}
private let primaryRecipe = recipes[0]
private let selectedRecipes = recipes.filter { selectedIDs?.contains($0.id) ?? true }

// A selected render cannot retire catalog entries belonging to the other choices.
if selectedIDs == nil {
    for entry in try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
    where entry.lastPathComponent.hasPrefix("AppIcon-") || entry.lastPathComponent.hasPrefix("IconPreview-") || entry.lastPathComponent == "BrandMark.imageset" {
        try FileManager.default.removeItem(at: entry)
    }
}

private var rendered: [(IconRecipe, CGImage)] = []
for recipe in selectedRecipes {
    let image = try render(recipe)
    // The primary retains its named alternate asset so saved iOS selections survive a default change.
    let iconNames = recipe.id == primaryRecipe.id ? ["AppIcon", "AppIcon-\(recipe.id)"] : ["AppIcon-\(recipe.id)"]
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

let iconSetCount = rendered.count + (selectedRecipes.contains { $0.id == primaryRecipe.id } ? 1 : 0)
print("Created \(rendered.count) visible choices and \(iconSetCount) icon sets: " + selectedRecipes.map { "\($0.id)=\($0.title)" }.joined(separator: ", "))
print("Catalog: \(recipes.count) visible choices, \(recipes.count + 1) icon sets")
print("Primary: AppIcon (\(primaryRecipe.id)=\(primaryRecipe.title)); hidden compatibility alternate: AppIcon-\(primaryRecipe.id)")
print("Alternate icon names: " + recipes.map { "AppIcon-\($0.id)" }.joined(separator: " "))
if let url = previewURLs["--preview"] {
    try saveContactSheet(rendered, to: url)
}
if let directory = previewURLs["--icon-previews"] {
    for (recipe, image) in rendered {
        try saveIconPreview(image, to: directory.appendingPathComponent("\(recipe.id)-preview.png"))
    }
}
if let url = previewURLs["--primary-preview"] {
    let image: CGImage
    if let primary = rendered.first(where: { $0.0.id == primaryRecipe.id }) {
        image = primary.1
    } else {
        image = try render(primaryRecipe)
    }
    try saveIconPreview(image, to: url)
}
