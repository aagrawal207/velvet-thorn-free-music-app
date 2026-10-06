import XCTest
import UIKit
@testable import GanaBajana

@MainActor
final class TVLyricsControllerTests: XCTestCase {
    func testDisplayReadsExistingPositionDurationAndOffsetWithoutAnIndependentClock() throws {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        let token = try XCTUnwrap(controller.beginSelection(for: try XCTUnwrap(playback.track?.id)))
        XCTAssertTrue(controller.select(playback.document(), token: token))
        playback.position = 5
        XCTAssertEqual(controller.lineWindow.current?.text, "Second test line")
        playback.offset = 1
        XCTAssertEqual(controller.lineWindow.current?.text, "First test line")
        playback.position = 6
        XCTAssertEqual(controller.lineWindow.current?.text, "Second test line")
        playback.duration = 6
        XCTAssertNil(controller.lineWindow.current)
        playback.position = 3
        XCTAssertEqual(controller.lineWindow.current?.text, "First test line")
    }

    func testTrackFenceHidesDocumentAndArtworkBeforeDeferredObservation() throws {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        let oldID = try XCTUnwrap(playback.track?.id)
        let token = try XCTUnwrap(controller.beginSelection(for: oldID))
        XCTAssertTrue(controller.select(playback.document(), token: token, artwork: UIImage()))
        XCTAssertNotNil(controller.artwork)
        playback.track = Track(id: "another-recording", title: "Another", artists: ["Test"])
        XCTAssertNil(controller.document)
        XCTAssertNil(controller.artwork)
        XCTAssertNil(controller.lineWindow.current)
        XCTAssertNil(controller.beginSelection(for: oldID))
        XCTAssertFalse(controller.select(.init(trackID: oldID, kind: .plain, plainText: "Old"), token: token))
    }

    func testMismatchedProviderResponseAndOlderSameTrackVariantAreRejected() throws {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        let id = try XCTUnwrap(playback.track?.id)
        let first = try XCTUnwrap(controller.beginSelection(for: id))
        XCTAssertFalse(controller.select(.init(trackID: "wrong", kind: .plain, plainText: "Wrong"), token: first))
        let second = try XCTUnwrap(controller.beginSelection(for: id))
        var romanized = playback.document()
        romanized.lines[0].text = "Romanized test line"
        XCTAssertTrue(controller.select(romanized, token: second, label: "Romanized"))
        XCTAssertFalse(controller.select(playback.document(), token: first))
        playback.position = 2
        XCTAssertEqual(controller.lineWindow.current?.text, "Romanized test line")
        XCTAssertEqual(controller.selectionLabel, "Romanized")
        XCTAssertEqual(controller.document?.source, "LRCLIB")
    }

    func testTrackChangeObservationClearsSelectionWithoutPlaybackCallbackReplacement() async throws {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        let token = try XCTUnwrap(controller.beginSelection(for: try XCTUnwrap(playback.track?.id)))
        XCTAssertTrue(controller.select(playback.document(), token: token, label: "Original"))
        playback.track = Track(id: "next", title: "Next")
        for _ in 0..<100 {
            if controller.selectionLabel == nil { break }
            await Task.yield()
        }
        XCTAssertNil(controller.selectionLabel)
        XCTAssertNil(controller.document)
    }

    func testEveryStopReasonClearsContentAndRetiresPendingSameTrackResults() throws {
        for reason in [TVLyricsController.StopReason.user, .privacy, .signOut, .suspended, .runtimeReplaced] {
            let playback = TVLyricsTestPlayback()
            let controller = playback.controller()
            controller.setPhoneSceneActive(true)
            let token = try XCTUnwrap(controller.beginSelection(for: try XCTUnwrap(playback.track?.id)))
            XCTAssertTrue(controller.select(playback.document(), token: token, label: "Original", artwork: UIImage()))
            XCTAssertTrue(controller.start())
            controller.phonePresentationVisibilityChanged(true)
            controller.stop(reason: reason)
            XCTAssertFalse(controller.isEnabled)
            XCTAssertFalse(controller.isPhonePresented)
            XCTAssertNil(controller.document)
            XCTAssertNil(controller.artwork)
            XCTAssertNil(controller.selectionLabel)
            XCTAssertFalse(playback.idleDisabled)
            XCTAssertFalse(controller.select(playback.document(), token: token))
        }
    }

    func testUntimedPageControlsAreSharedBoundedAndResetOnSelection() throws {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        controller.setPhoneSceneActive(true)
        let id = try XCTUnwrap(playback.track?.id)
        let token = try XCTUnwrap(controller.beginSelection(for: id))
        XCTAssertTrue(controller.select(playback.document(kind: .plain, plain: "One\nTwo"), token: token))
        controller.movePage(by: 1)
        XCTAssertEqual(controller.manualPage, "One")
        XCTAssertTrue(controller.start())
        controller.movePage(by: 1)
        controller.movePage(by: Int.max)
        XCTAssertEqual(controller.manualPageIndex, 1)
        XCTAssertEqual(controller.manualPage, "Two")
        controller.movePage(by: Int.min)
        controller.movePage(by: -1)
        XCTAssertEqual(controller.manualPage, "One")
        controller.movePage(by: 1)
        let replacement = try XCTUnwrap(controller.beginSelection(for: id))
        XCTAssertTrue(controller.select(playback.document(kind: .plain, plain: "New version"), token: replacement))
        XCTAssertEqual(controller.manualPageIndex, 0)
        XCTAssertEqual(controller.manualPage, "New version")
    }

    func testMissingTrackStopsAndCannotOptIn() {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        controller.setPhoneSceneActive(true)
        XCTAssertTrue(controller.start())
        playback.track = nil
        controller.synchronizeTrack()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.start())
    }
}
