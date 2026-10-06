import CoreGraphics
import XCTest
@testable import GanaBajana

final class PlayerProgressBarTests: XCTestCase {
    private let width: CGFloat = 354

    func testTouchMappingIsLinearAcrossTheWholeWidthAndInvertible() {
        XCTAssertEqual(PlayerProgressBar.progress(atX: 0, width: width), 0)
        XCTAssertEqual(PlayerProgressBar.progress(atX: width / 4, width: width), 0.25, accuracy: 1e-9)
        XCTAssertEqual(PlayerProgressBar.progress(atX: width / 2, width: width), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PlayerProgressBar.progress(atX: width, width: width), 1, accuracy: 1e-9)
        var last: CGFloat = 0
        for x in stride(from: CGFloat(0), through: width, by: 0.5) {
            let progress = PlayerProgressBar.progress(atX: x, width: width)
            XCTAssertGreaterThanOrEqual(progress, last)
            XCTAssertEqual(PlayerProgressBar.x(forProgress: progress, width: width), x, accuracy: 1e-6)
            last = progress
        }
        XCTAssertEqual(PlayerProgressBar.x(forProgress: 0, width: width), 0)
        XCTAssertEqual(PlayerProgressBar.x(forProgress: 1, width: width), width)
        XCTAssertEqual(PlayerProgressBar.x(forProgress: 0.99, width: 572), 0.99 * 572, accuracy: 1e-9,
                       "A wider row keeps the same linear mapping")
    }

    func testTouchesAndProgressClampToTheRow() {
        XCTAssertEqual(PlayerProgressBar.progress(atX: -20, width: width), 0)
        XCTAssertEqual(PlayerProgressBar.progress(atX: width + 40, width: width), 1)
        XCTAssertEqual(PlayerProgressBar.progress(atX: .nan, width: width), 0)
        XCTAssertEqual(PlayerProgressBar.progress(atX: .infinity, width: width), 0, "A non-finite touch never seeks")
        XCTAssertEqual(PlayerProgressBar.x(forProgress: -0.5, width: width), 0)
        XCTAssertEqual(PlayerProgressBar.x(forProgress: 1.5, width: width), width)
        XCTAssertEqual(PlayerProgressBar.x(forProgress: .nan, width: width), 0)
        XCTAssertEqual(PlayerProgressBar.clamp(.nan), 0)
        XCTAssertEqual(PlayerProgressBar.clamp(2), 1)
        XCTAssertEqual(PlayerProgressBar.clamp(-1), 0)
    }

    func testDegenerateWidthsStayFiniteAndOrdered() {
        for degenerate in [CGFloat(0), -30, .nan, .infinity] {
            XCTAssertEqual(PlayerProgressBar.progress(atX: 12, width: degenerate), 0)
            XCTAssertEqual(PlayerProgressBar.x(forProgress: 0.5, width: degenerate), 0)
            XCTAssertTrue(PlayerProgressBar.strokeX(forProgress: 0.5, width: degenerate).isFinite)
            XCTAssertGreaterThanOrEqual(PlayerProgressBar.strokeEnd(width: degenerate), PlayerProgressBar.strokeStart(width: degenerate))
        }
        // A row narrower than one stroke collapses the stroke onto its centre instead of crossing over.
        XCTAssertEqual(PlayerProgressBar.strokeStart(width: 2), 1)
        XCTAssertEqual(PlayerProgressBar.strokeEnd(width: 2), 1)
    }

    func testStrokeKeepsItsRoundCapsInsideTheRowAndFollowsProgress() {
        let half = PlayerProgressBar.lineWidth / 2
        XCTAssertEqual(PlayerProgressBar.strokeStart(width: width), half)
        XCTAssertEqual(PlayerProgressBar.strokeEnd(width: width), width - half)
        XCTAssertEqual(PlayerProgressBar.strokeX(forProgress: 0, width: width), half)
        XCTAssertEqual(PlayerProgressBar.strokeX(forProgress: 1, width: width), width - half)
        XCTAssertEqual(PlayerProgressBar.strokeX(forProgress: 0.5, width: width), width / 2, accuracy: 1e-9)
        // The drawn leading edge stays within a cap of the touch that produced it.
        for progress in stride(from: CGFloat(0), through: 1, by: 0.05) {
            let touch = PlayerProgressBar.x(forProgress: progress, width: width)
            XCTAssertEqual(PlayerProgressBar.strokeX(forProgress: progress, width: width), touch, accuracy: half + 1e-9)
        }
        XCTAssertEqual(PlayerProgressBar.rowHeight, 32)
        XCTAssertEqual(PlayerProgressBar.hitHeight, 44)
    }
}

final class PlayerSwipeUpPreferenceTests: XCTestCase {
    func testSwipeUpActionDefaultsToLyricsAndDecodesLeniently() throws {
        XCTAssertEqual(UserPreferences().playerSwipeUpAction, .lyrics)
        XCTAssertEqual(PlayerSwipeUpAction.allCases.map(\.title), ["Lyrics", "Queue", "More options", "Off"])
        let decoder = JSONDecoder()
        for absent in ["{}", #"{"playerSwipeUpAction":null}"#, #"{"playerSwipeUpAction":"future-action"}"#, #"{"playerSwipeUpAction":7}"#] {
            let decoded = try decoder.decode(UserPreferences.self, from: Data(absent.utf8))
            XCTAssertEqual(decoded.playerSwipeUpAction, .lyrics, absent)
        }
        for action in PlayerSwipeUpAction.allCases {
            let decoded = try decoder.decode(UserPreferences.self, from: Data(#"{"playerSwipeUpAction":"\#(action.rawValue)"}"#.utf8))
            XCTAssertEqual(decoded.playerSwipeUpAction, action)
        }
        var preferences = UserPreferences()
        preferences.playerSwipeUpAction = .moreOptions
        let roundTrip = try decoder.decode(UserPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(roundTrip.playerSwipeUpAction, .moreOptions)
    }
}
