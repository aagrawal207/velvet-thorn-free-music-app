import CoreGraphics
import Foundation

/// Now Playing progress as one continuous stroke: a straight bar that runs into the like heart's outline, so
/// playback finishes by drawing the heart instead of stopping at the bar's end. Pure geometry shared with UI tests.
struct PlayerProgressTrail: Equatable, Sendable {
    struct Layout: Equatable, Sendable {
        var rowHeight: CGFloat = 52
        /// Width of the like button at the trailing edge; the heart is centered inside it.
        var heartSlotWidth: CGFloat = 56
        var heartWidth: CGFloat = 24
        var lineWidth: CGFloat = 3.5
        /// Outline distance below the heart's widest point where the bar joins it, so the heart sits a little
        /// higher on the line than a junction at the widest point would place it.
        var heartEntryDrop: CGFloat = 2.5

        static let standard = Layout()

        var heartHeight: CGFloat { heartWidth * PlayerProgressTrail.heartAspect }
    }

    let rowWidth: CGFloat
    let layout: Layout
    /// Bounding box of the heart outline, centered in the row.
    let heartFrame: CGRect
    /// Where the bar meets the heart outline and the outline tracing starts and ends: on the lower-left edge,
    /// `heartEntryDrop` below the widest point.
    let junction: CGPoint
    let barStart: CGPoint
    let barLength: CGFloat
    let heartLength: CGFloat
    private let segments: [Segment]

    init(rowWidth: CGFloat, layout: Layout = .standard) {
        let width = rowWidth.isFinite ? max(0, rowWidth) : 0
        self.rowWidth = width
        self.layout = layout
        let slotStart = max(0, width - layout.heartSlotWidth)
        let heartOrigin = CGPoint(x: slotStart + (layout.heartSlotWidth - layout.heartWidth) / 2,
                                  y: (layout.rowHeight - layout.heartHeight) / 2)
        heartFrame = CGRect(origin: heartOrigin, size: CGSize(width: layout.heartWidth, height: layout.heartHeight))
        // The unit outline starts at the widest point; rotate it so tracing starts and ends at the entry a little
        // further down the left edge. The bar's baseline follows that entry.
        var outline = Self.heartOutline.map { $0.scaled(by: layout.heartWidth, offset: heartOrigin) }
        if let closing = outline.last {
            let drop = min(max(layout.heartEntryDrop, 0), closing.length)
            if drop > 0 {
                let (toEntry, toWidest) = closing.split(atLength: closing.length - drop)
                outline = [toWidest] + outline.dropLast() + [toEntry]
            }
        }
        segments = outline
        junction = outline.first?.start ?? CGPoint(x: heartOrigin.x, y: heartOrigin.y + Self.heartEntry.y * layout.heartWidth)
        // The round cap must not poke past the row's leading edge, where the elapsed label starts.
        barStart = CGPoint(x: min(layout.lineWidth / 2, junction.x), y: junction.y)
        barLength = max(0, junction.x - barStart.x)
        heartLength = segments.reduce(0) { $0 + $1.length }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rowWidth == rhs.rowWidth && lhs.layout == rhs.layout
    }

    var totalLength: CGFloat { barLength + heartLength }

    /// Progress at which the bar is complete and the heart outline begins.
    var junctionFraction: CGFloat { barLength / totalLength }

    /// Leading edge of the like button's slot in row coordinates.
    var heartSlotOrigin: CGFloat { max(0, rowWidth - layout.heartSlotWidth) }

    /// Progress for a touch at `x` in row coordinates: linear along the bar, then the rest of the outline is
    /// spread across the remaining width so the trailing edge still reaches the end of the song.
    func progress(atX x: CGFloat) -> CGFloat {
        guard x.isFinite else { return 0 }
        if x <= junction.x { return clamp(max(0, x - barStart.x) / totalLength) }
        let room = rowWidth - junction.x
        let heartShare = room > 0 ? clamp((x - junction.x) / room) : 1
        return clamp((barLength + heartLength * heartShare) / totalLength)
    }

    /// Inverse of `progress(atX:)`, used to place touches for a wanted position.
    func x(forProgress progress: CGFloat) -> CGFloat {
        let distance = clamp(progress) * totalLength
        if distance <= barLength { return barStart.x + distance }
        let heartShare = heartLength > 0 ? (distance - barLength) / heartLength : 1
        return junction.x + (rowWidth - junction.x) * heartShare
    }

    /// The trail's leading edge for `progress`, used for the scrubbing marker.
    func point(atProgress progress: CGFloat) -> CGPoint {
        let distance = clamp(progress) * totalLength
        if distance <= barLength { return CGPoint(x: barStart.x + distance, y: barStart.y) }
        var remaining = distance - barLength
        for segment in segments {
            if remaining <= segment.length { return segment.point(atLength: remaining) }
            remaining -= segment.length
        }
        return junction
    }

    /// Bar plus the complete heart outline.
    var trackPath: CGPath { path(through: 1) }

    /// Closed heart outline for the liked fill.
    var heartPath: CGPath {
        let path = CGMutablePath()
        path.move(to: junction)
        for segment in segments { segment.append(to: path) }
        path.closeSubpath()
        return path
    }

    /// The traced part of the trail: the bar, then the outline in tracing order up to `progress`.
    func progressPath(_ progress: CGFloat) -> CGPath { path(through: clamp(progress)) }

    /// The bar alone, traced up to `progress`; complete once the outline starts.
    func barProgressPath(_ progress: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: barStart)
        path.addLine(to: CGPoint(x: barStart.x + min(clamp(progress) * totalLength, barLength), y: barStart.y))
        return path
    }

    /// The outline alone, traced from the junction up to `progress`; nil while the bar is still filling.
    func heartProgressPath(_ progress: CGFloat) -> CGPath? {
        let remaining = clamp(progress) * totalLength - barLength
        guard remaining > 0 else { return nil }
        let path = CGMutablePath()
        path.move(to: junction)
        appendOutline(to: path, length: remaining)
        return path
    }

    private func path(through progress: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let distance = progress * totalLength
        path.move(to: barStart)
        guard distance > barLength else {
            path.addLine(to: CGPoint(x: barStart.x + distance, y: barStart.y))
            return path
        }
        path.addLine(to: junction)
        appendOutline(to: path, length: distance - barLength)
        return path
    }

    private func appendOutline(to path: CGMutablePath, length: CGFloat) {
        var remaining = length
        for segment in segments {
            if remaining >= segment.length {
                segment.append(to: path)
                remaining -= segment.length
            } else {
                if remaining > 0 { segment.prefix(length: remaining).append(to: path) }
                break
            }
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    // MARK: Heart outline

    /// Height of the unit heart relative to its width.
    static let heartAspect: CGFloat = 0.9175
    /// The heart's leftmost point in unit coordinates; the bar joins the outline here.
    static let heartEntry = CGPoint(x: 0, y: 0.275)

    /// Unit heart (y down), traced from the leftmost point: up over the left lobe, into the notch, over the right
    /// lobe, down to the tip and back up to the entry. The trace closes where the bar arrived.
    private static let heartOutline: [Segment] = [
        .cubic(CGPoint(x: 0, y: 0.275), CGPoint(x: 0, y: 0.121), CGPoint(x: 0.121, y: 0), CGPoint(x: 0.275, y: 0)),
        .cubic(CGPoint(x: 0.275, y: 0), CGPoint(x: 0.362, y: 0), CGPoint(x: 0.4455, y: 0.0405), CGPoint(x: 0.5, y: 0.1045)),
        .cubic(CGPoint(x: 0.5, y: 0.1045), CGPoint(x: 0.5545, y: 0.0405), CGPoint(x: 0.638, y: 0), CGPoint(x: 0.725, y: 0)),
        .cubic(CGPoint(x: 0.725, y: 0), CGPoint(x: 0.879, y: 0), CGPoint(x: 1, y: 0.121), CGPoint(x: 1, y: 0.275)),
        .cubic(CGPoint(x: 1, y: 0.275), CGPoint(x: 1, y: 0.464), CGPoint(x: 0.83, y: 0.618), CGPoint(x: 0.5725, y: 0.852)),
        .line(CGPoint(x: 0.5725, y: 0.852), CGPoint(x: 0.5, y: 0.9175)),
        .line(CGPoint(x: 0.5, y: 0.9175), CGPoint(x: 0.4275, y: 0.8515)),
        .cubic(CGPoint(x: 0.4275, y: 0.8515), CGPoint(x: 0.17, y: 0.618), CGPoint(x: 0, y: 0.464), CGPoint(x: 0, y: 0.275)),
    ]

    private enum Segment: Equatable, Sendable {
        case line(CGPoint, CGPoint)
        case cubic(CGPoint, CGPoint, CGPoint, CGPoint)

        /// Dense enough that the leading edge lands within a fraction of a point of the wanted length.
        private static let samples = 64

        func scaled(by scale: CGFloat, offset: CGPoint) -> Segment {
            func map(_ point: CGPoint) -> CGPoint {
                CGPoint(x: offset.x + point.x * scale, y: offset.y + point.y * scale)
            }
            switch self {
            case .line(let a, let b): return .line(map(a), map(b))
            case .cubic(let a, let b, let c, let d): return .cubic(map(a), map(b), map(c), map(d))
            }
        }

        var length: CGFloat {
            switch self {
            case .line(let a, let b): return hypot(b.x - a.x, b.y - a.y)
            case .cubic: return arcLengths().last ?? 0
            }
        }

        var start: CGPoint {
            switch self {
            case .line(let a, _): return a
            case .cubic(let a, _, _, _): return a
            }
        }

        var end: CGPoint {
            switch self {
            case .line(_, let b): return b
            case .cubic(_, _, _, let d): return d
            }
        }

        func append(to path: CGMutablePath) {
            switch self {
            case .line(_, let b): path.addLine(to: b)
            case .cubic(_, let b, let c, let d): path.addCurve(to: d, control1: b, control2: c)
            }
        }

        func point(atLength length: CGFloat) -> CGPoint {
            switch self {
            case .line(let a, let b):
                let total = self.length
                guard total > 0 else { return b }
                let t = min(max(length / total, 0), 1)
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            case .cubic:
                return evaluate(parameter(atLength: length))
            }
        }

        /// The exact sub-curve from the start to the given arc length (de Casteljau split for curves).
        func prefix(length: CGFloat) -> Segment { split(atLength: length).0 }

        /// Both exact pieces around the given arc length; the second starts where the first ends.
        func split(atLength length: CGFloat) -> (Segment, Segment) {
            switch self {
            case .line(let a, let b):
                let middle = point(atLength: length)
                return (.line(a, middle), .line(middle, b))
            case .cubic(let a, let b, let c, let d):
                let t = parameter(atLength: length)
                let ab = lerp(a, b, t), bc = lerp(b, c, t), cd = lerp(c, d, t)
                let abc = lerp(ab, bc, t), bcd = lerp(bc, cd, t)
                let middle = lerp(abc, bcd, t)
                return (.cubic(a, ab, abc, middle), .cubic(middle, bcd, cd, d))
            }
        }

        private func evaluate(_ t: CGFloat) -> CGPoint {
            guard case .cubic(let a, let b, let c, let d) = self else { return end }
            let u = 1 - t
            let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
            return CGPoint(x: w0 * a.x + w1 * b.x + w2 * c.x + w3 * d.x,
                           y: w0 * a.y + w1 * b.y + w2 * c.y + w3 * d.y)
        }

        /// Cumulative chord lengths at `samples` uniform parameter steps, index 0 being the start.
        private func arcLengths() -> [CGFloat] {
            guard case .cubic(let a, _, _, _) = self else { return [0, length] }
            var lengths = [CGFloat](repeating: 0, count: Self.samples + 1)
            var previous = a
            for index in 1...Self.samples {
                let point = evaluate(CGFloat(index) / CGFloat(Self.samples))
                lengths[index] = lengths[index - 1] + hypot(point.x - previous.x, point.y - previous.y)
                previous = point
            }
            return lengths
        }

        /// Curve parameter whose arc length from the start is `length`, interpolated between samples.
        private func parameter(atLength length: CGFloat) -> CGFloat {
            let lengths = arcLengths()
            guard let total = lengths.last, total > 0 else { return 1 }
            let target = min(max(length, 0), total)
            var index = 1
            while index < lengths.count - 1 && lengths[index] < target { index += 1 }
            let span = lengths[index] - lengths[index - 1]
            let within = span > 0 ? (target - lengths[index - 1]) / span : 0
            return (CGFloat(index - 1) + within) / CGFloat(Self.samples)
        }

        private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }
}
