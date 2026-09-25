import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class ArtworkBackdropStateTests: XCTestCase {
    func testReplacementKeepsTheDisplayedImageAndPaletteUntilAcceptedTogether() throws {
        var state = ArtworkBackdropState()
        let red = image(.red), blue = image(.blue)
        let first = try XCTUnwrap(state.begin(url("a")))
        XCTAssertTrue(state.complete(red, for: first))
        let palette = try XCTUnwrap(state.displayed?.palette)

        let replacement = try XCTUnwrap(state.begin(url("b")))
        XCTAssertEqual(state.displayed?.url, url("a"))
        XCTAssertTrue(state.displayed?.image === red)
        XCTAssertEqual(state.displayed?.palette, palette)

        XCTAssertTrue(state.complete(blue, for: replacement))
        XCTAssertEqual(state.displayed?.url, url("b"))
        XCTAssertTrue(state.displayed?.image === blue)
        XCTAssertEqual(try XCTUnwrap(state.displayed?.palette).primary.hsb.hue, 2.0 / 3, accuracy: 0.02)
        XCTAssertFalse(state.complete(red, for: replacement), "A completion can only be accepted once")
    }

    func testSupersededResponsesCannotReplaceDisplayedArtworkBeforeOrAfterTheNewestResponse() throws {
        var state = ArtworkBackdropState()
        let first = try XCTUnwrap(state.begin(url("a")))
        let second = try XCTUnwrap(state.begin(url("b")))
        let third = try XCTUnwrap(state.begin(url("c")))

        XCTAssertFalse(state.complete(image(.red), for: second))
        XCTAssertNil(state.displayed)
        XCTAssertTrue(state.complete(image(.blue), for: third))
        XCTAssertFalse(state.complete(image(.green), for: first))
        XCTAssertEqual(state.displayed?.url, url("c"))
    }

    func testOlderTaskCleanupCannotCancelTheCurrentRequest() throws {
        var state = ArtworkBackdropState()
        let first = try XCTUnwrap(state.begin(url("a")))
        let second = try XCTUnwrap(state.begin(url("b")))
        state.cancel(first)

        XCTAssertTrue(state.complete(image(.blue), for: second))
        XCTAssertEqual(state.displayed?.url, url("b"))
    }

    func testRevisitingAPendingURLStillRejectsItsOriginalRequest() throws {
        var state = ArtworkBackdropState()
        let original = try XCTUnwrap(state.begin(url("a")))
        let intermediate = try XCTUnwrap(state.begin(url("b")))
        let current = try XCTUnwrap(state.begin(url("a")))

        XCTAssertFalse(state.complete(image(.red), for: original))
        XCTAssertFalse(state.complete(nil, for: intermediate))
        XCTAssertNil(state.displayed)
        XCTAssertTrue(state.complete(image(.blue), for: current))
        XCTAssertEqual(state.displayed?.url, url("a"))
    }

    func testNilURLClearsTheDisplayedArtworkAndRejectsThePendingResponse() throws {
        var state = ArtworkBackdropState()
        let first = try XCTUnwrap(state.begin(url("a")))
        state.complete(image(.red), for: first)
        let pending = try XCTUnwrap(state.begin(url("b")))

        XCTAssertNil(state.begin(nil))
        XCTAssertNil(state.displayed)
        XCTAssertFalse(state.complete(image(.blue), for: pending))
        XCTAssertNil(state.displayed)
    }

    func testOnlyFailureOfTheCurrentRequestFallsBackAndCanBeRetried() throws {
        var state = ArtworkBackdropState()
        let first = try XCTUnwrap(state.begin(url("a")))
        state.complete(image(.red), for: first)
        let second = try XCTUnwrap(state.begin(url("b")))
        let third = try XCTUnwrap(state.begin(url("c")))

        XCTAssertFalse(state.complete(nil, for: second))
        XCTAssertEqual(state.displayed?.url, url("a"))
        XCTAssertTrue(state.complete(nil, for: third))
        XCTAssertNil(state.displayed)
        let retry = try XCTUnwrap(state.begin(url("c")))
        XCTAssertTrue(state.complete(image(.blue), for: retry))
        XCTAssertEqual(state.displayed?.url, url("c"))
    }

    func testDisappearanceRejectsLateCompletionWithoutDiscardingTheDisplayedFrame() throws {
        var state = ArtworkBackdropState()
        let first = try XCTUnwrap(state.begin(url("a")))
        state.complete(image(.red), for: first)
        let pending = try XCTUnwrap(state.begin(url("b")))
        state.cancel()

        XCTAssertFalse(state.complete(image(.blue), for: pending))
        XCTAssertEqual(state.displayed?.url, url("a"))
        let resumed = try XCTUnwrap(state.begin(url("b")))
        XCTAssertTrue(state.complete(image(.blue), for: resumed))
    }

    func testReturningToTheDisplayedURLRetiresTheReplacementWithoutAnotherLoad() throws {
        var state = ArtworkBackdropState()
        let first = try XCTUnwrap(state.begin(url("a")))
        let red = image(.red)
        state.complete(red, for: first)
        let pending = try XCTUnwrap(state.begin(url("b")))

        XCTAssertNil(state.begin(url("a")))
        XCTAssertFalse(state.complete(image(.blue), for: pending))
        XCTAssertEqual(state.displayed?.url, url("a"))
        XCTAssertTrue(state.displayed?.image === red)
    }

    func testCancelledTaskCannotBeginOrAcceptAMatchingRequest() async throws {
        var state = ArtworkBackdropState()
        let first = try XCTUnwrap(state.begin(url("a")))
        state.complete(image(.red), for: first)
        let pending = try XCTUnwrap(state.begin(url("b")))
        let baseline = state, blue = image(.blue), next = url("c")

        let outcome = await Task { @MainActor in
            var cancelled = baseline
            withUnsafeCurrentTask { $0?.cancel() }
            let began = cancelled.begin(next) != nil
            let accepted = cancelled.complete(blue, for: pending)
            return (began, accepted, cancelled.displayed?.url)
        }.value

        XCTAssertFalse(outcome.0)
        XCTAssertFalse(outcome.1)
        XCTAssertEqual(outcome.2, url("a"))
    }

    private func url(_ name: String) -> URL { URL(string: "https://artwork.invalid/\(name)")! }

    private func image(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }
}
