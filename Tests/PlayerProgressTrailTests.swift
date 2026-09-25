import CoreGraphics
import XCTest
@testable import GanaBajana

final class PlayerProgressTrailTests: XCTestCase {
    private let phone = PlayerProgressTrail(rowWidth: 354)
    private let layout = PlayerProgressTrail.Layout.standard

    func testBarAndHeartOutlinePartitionTheTrail() {
        XCTAssertEqual(phone.totalLength, phone.barLength + phone.heartLength, accuracy: 1e-9)
        XCTAssertEqual(phone.barLength, phone.junction.x - phone.barStart.x, accuracy: 1e-9)
        // A 24-point heart's outline is a little under three widths long; the bar owns the rest of the song.
        XCTAssertEqual(phone.heartLength, layout.heartWidth * 3.05, accuracy: layout.heartWidth * 0.2)
        XCTAssertEqual(phone.junctionFraction, 0.82, accuracy: 0.02)
        XCTAssertEqual(PlayerProgressTrail(rowWidth: 572).junctionFraction, 0.89, accuracy: 0.02,
                       "A wider row gives the bar a larger share of the recording")
    }

    func testHeartHangsFromTheBaselineInsideTheLikeSlot() {
        let heart = phone.heartFrame
        XCTAssertEqual(phone.heartSlotOrigin, 354 - layout.heartSlotWidth)
        XCTAssertGreaterThanOrEqual(heart.minX, phone.heartSlotOrigin)
        XCTAssertLessThanOrEqual(heart.maxX, phone.rowWidth)
        XCTAssertEqual(heart.midX, phone.heartSlotOrigin + layout.heartSlotWidth / 2, accuracy: 1e-9)
        XCTAssertEqual(heart.width, layout.heartWidth)
        XCTAssertEqual(heart.height, layout.heartHeight, accuracy: 1e-9)
        XCTAssertEqual(heart.midY, layout.rowHeight / 2, accuracy: 1e-9, "The heart is centered in the row")
        let widest = CGPoint(x: heart.minX, y: heart.minY + PlayerProgressTrail.heartEntry.y * layout.heartWidth)
        XCTAssertEqual(phone.junction.y, widest.y + layout.heartEntryDrop, accuracy: 0.1,
                       "The bar joins the outline the entry drop below the heart's widest point")
        XCTAssertGreaterThanOrEqual(phone.junction.x, heart.minX)
        XCTAssertLessThan(phone.junction.x, heart.minX + 1, "The lower-left edge is still almost vertical there")
        XCTAssertLessThan(phone.junction.y, layout.rowHeight / 2, "The bar still runs a little above the row's center")
        XCTAssertEqual(phone.barStart.y, phone.junction.y)
        XCTAssertLessThan(heart.minY, phone.junction.y)
        XCTAssertGreaterThan(heart.maxY, phone.junction.y)
        var noDrop = layout
        noDrop.heartEntryDrop = 0
        let widestEntry = PlayerProgressTrail(rowWidth: 354, layout: noDrop)
        XCTAssertEqual(widestEntry.junction.x, widest.x, accuracy: 1e-6)
        XCTAssertEqual(widestEntry.junction.y, widest.y, accuracy: 1e-6)
        XCTAssertEqual(widestEntry.heartLength, phone.heartLength, accuracy: 0.05, "Moving the entry does not change the outline")
        let bounds = phone.heartPath.boundingBoxOfPath
        XCTAssertEqual(bounds.minX, heart.minX, accuracy: 0.05)
        XCTAssertEqual(bounds.maxX, heart.maxX, accuracy: 0.05)
        XCTAssertEqual(bounds.minY, heart.minY, accuracy: 0.05)
        XCTAssertEqual(bounds.maxY, heart.maxY, accuracy: 0.05)
    }

    func testBarCompletesExactlyAtTheJunctionAndTheOutlineClosesThere() {
        let junction = phone.junctionFraction
        assertEqual(phone.point(atProgress: junction), phone.junction)
        assertEqual(phone.progressPath(junction).currentPoint, phone.junction)
        assertEqual(phone.progressPath(1).currentPoint, phone.junction, accuracy: 0.05)
        assertEqual(phone.point(atProgress: 1), phone.junction, accuracy: 0.05)
        assertEqual(phone.point(atProgress: 0), phone.barStart)
        let complete = phone.progressPath(1).boundingBoxOfPath
        XCTAssertEqual(complete.minX, phone.barStart.x, accuracy: 0.05)
        XCTAssertEqual(complete.maxX, phone.heartFrame.maxX, accuracy: 0.05)
        XCTAssertEqual(complete.minY, phone.heartFrame.minY, accuracy: 0.05)
        XCTAssertEqual(complete.maxY, phone.heartFrame.maxY, accuracy: 0.05)
    }

    func testOutlineIsTracedUpOverTheLobesDownToTheTipAndBackToTheEntry() {
        let heart = phone.heartFrame
        func point(_ share: CGFloat) -> CGPoint {
            phone.point(atProgress: phone.junctionFraction + (1 - phone.junctionFraction) * share)
        }
        let start = point(0.05)
        XCTAssertLessThan(start.y, phone.junction.y, "The trace climbs the left edge first")
        XCTAssertLessThan(start.x, heart.midX)
        let notch = point(0.26)
        XCTAssertEqual(notch.x, heart.midX, accuracy: 0.5, "About a quarter of the outline reaches the notch")
        XCTAssertLessThan(notch.y, phone.junction.y)
        let rightSide = point(0.5)
        XCTAssertGreaterThan(rightSide.x, heart.midX)
        let tip = point(0.76)
        XCTAssertEqual(tip.x, heart.midX, accuracy: 0.5, "About three quarters of the outline reaches the tip")
        XCTAssertEqual(tip.y, heart.maxY, accuracy: 0.5)
        let finish = point(0.95)
        XCTAssertLessThan(finish.x, heart.midX)
        XCTAssertGreaterThan(finish.y, phone.junction.y, "The trace returns to the entry along the lower-left edge")
    }

    func testOutlinePointsAdvanceEvenlyAlongTheHeart() {
        // Equal progress steps cover equal outline distance, so the trace never speeds up or stalls on a segment.
        var previous = phone.point(atProgress: phone.junctionFraction)
        var steps: [CGFloat] = []
        let count = 200
        for index in 1...count {
            let progress = phone.junctionFraction + (1 - phone.junctionFraction) * CGFloat(index) / CGFloat(count)
            let point = phone.point(atProgress: progress)
            steps.append(hypot(point.x - previous.x, point.y - previous.y))
            previous = point
        }
        let expected = phone.heartLength / CGFloat(count)
        for step in steps {
            XCTAssertEqual(step, expected, accuracy: expected * 0.2)
        }
    }

    func testTouchMappingIsMonotonicInvertibleAndReachesBothEnds() {
        XCTAssertEqual(phone.progress(atX: 0), 0)
        XCTAssertEqual(phone.progress(atX: -20), 0)
        XCTAssertEqual(phone.progress(atX: phone.junction.x), phone.junctionFraction, accuracy: 1e-9)
        XCTAssertEqual(phone.progress(atX: phone.rowWidth), 1, accuracy: 1e-9)
        XCTAssertEqual(phone.progress(atX: phone.rowWidth + 40), 1)
        XCTAssertEqual(phone.progress(atX: .nan), 0)
        var last: CGFloat = 0
        var x = phone.barStart.x
        while x <= phone.rowWidth {
            let progress = phone.progress(atX: x)
            XCTAssertGreaterThanOrEqual(progress, last)
            XCTAssertEqual(phone.x(forProgress: progress), x, accuracy: 1e-6)
            last = progress
            x += 0.5
        }
        XCTAssertEqual(phone.x(forProgress: 0), phone.barStart.x)
        XCTAssertEqual(phone.x(forProgress: 1), phone.rowWidth, accuracy: 1e-9)
    }

    func testBarProgressStaysUnderTheFingerWhileScrubbingTheBar() {
        for x in stride(from: phone.barStart.x, through: phone.junction.x, by: 7) {
            let point = phone.point(atProgress: phone.progress(atX: x))
            XCTAssertEqual(point.x, x, accuracy: 1e-6)
            XCTAssertEqual(point.y, phone.barStart.y)
        }
        // Past the bar the finger is over the heart while the outline traces; the remaining song spans the slot.
        let midSlot = phone.progress(atX: (phone.junction.x + phone.rowWidth) / 2)
        XCTAssertEqual(midSlot, phone.junctionFraction + (1 - phone.junctionFraction) / 2, accuracy: 1e-9)
    }

    func testBarAndHeartPiecesMatchTheWholeTrail() {
        for progress in stride(from: CGFloat(0), through: 1, by: 0.02) {
            let whole = phone.progressPath(progress).currentPoint
            if progress <= phone.junctionFraction {
                assertEqual(phone.barProgressPath(progress).currentPoint, whole)
                XCTAssertNil(phone.heartProgressPath(progress))
            } else {
                assertEqual(phone.barProgressPath(progress).currentPoint, phone.junction)
                let heart = try? XCTUnwrap(phone.heartProgressPath(progress))
                assertEqual(heart?.currentPoint ?? .zero, whole, accuracy: 0.05)
            }
        }
    }

    func testNarrowOrInvalidRowsStayFiniteAndOrdered() {
        for width in [CGFloat(0), 10, 40, 56, 57, .nan, .infinity, -30] {
            let trail = PlayerProgressTrail(rowWidth: width)
            XCTAssertTrue(trail.totalLength.isFinite)
            XCTAssertGreaterThan(trail.heartLength, 0)
            XCTAssertGreaterThanOrEqual(trail.barLength, 0)
            XCTAssertGreaterThanOrEqual(trail.junction.x, trail.barStart.x)
            XCTAssertTrue((0...1).contains(trail.progress(atX: 12)))
            XCTAssertTrue(trail.point(atProgress: 0.5).x.isFinite)
            _ = trail.progressPath(0.5)
            _ = trail.trackPath
        }
    }

    private func assertEqual(_ actual: CGPoint, _ expected: CGPoint, accuracy: CGFloat = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
    }
}
