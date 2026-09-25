import UIKit
import XCTest

@MainActor
final class GanaBajanaPlayerAirPlayUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testBottomActionRowHasOneBrowseControlAndOneVisibleNativeAirPlayButton() throws {
        let ui = try launchPlayer()
        let ids = ["player.airplay", "player.lyrics", "player.browse", "player.queue"]
        let labels = ["AirPlay and audio output", "Lyrics", "Album and artists", "Queue"]
        let controls = ids.map { ui.app.buttons[$0] }
        let window = ui.app.windows.firstMatch.frame
        for (control, label) in zip(controls, labels) {
            try ui.requireHittable(control)
            XCTAssertEqual(control.label, label)
            XCTAssertEqual(control.elementType, .button)
            XCTAssertEqual(ui.app.buttons.matching(identifier: control.identifier).count, 1)
            XCTAssertGreaterThanOrEqual(control.frame.width + 1e-6, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height + 1e-6, 44)
            XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(control.frame))
            XCTAssertEqual(control.frame.midY, controls[0].frame.midY, accuracy: 1)
            XCTAssertGreaterThan(control.frame.minY, ui.app.buttons["player.playPause"].frame.maxY)
        }
        for (left, right) in zip(controls, controls.dropFirst()) {
            XCTAssertLessThan(left.frame.midX, right.frame.midX)
            XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX + 1e-6)
        }
        let spacing = controls[1].frame.midX - controls[0].frame.midX
        XCTAssertEqual(controls[2].frame.midX - controls[1].frame.midX, spacing, accuracy: 2)
        XCTAssertEqual(controls[3].frame.midX - controls[2].frame.midX, spacing, accuracy: 2)
        XCTAssertFalse(ui.app.buttons["player.album"].exists)
        XCTAssertFalse(ui.app.buttons["player.artist"].exists)
        let airPlayFrame = try assertNativeAirPlayAnchor(ui)
        ui.capture("player-four-actions-leftmost-native-airplay")

        try ui.tap(ui.app.buttons["player.menu"])
        try ui.requireHittable(ui.app.buttons["player.options.toolbarDone"])
        XCTAssertFalse(ui.app.buttons["player.options.airplay"].exists)
        try ui.tap(ui.app.buttons["player.options.toolbarDone"])
        let restoredFrame = try assertNativeAirPlayAnchor(ui)
        XCTAssertEqual(restoredFrame.minX, airPlayFrame.minX, accuracy: 1)
        XCTAssertEqual(restoredFrame.minY, airPlayFrame.minY, accuracy: 1)

        try ui.tap(ui.app.buttons["player.close"])
        try ui.openPlayer()
        let reopenedFrame = try assertNativeAirPlayAnchor(ui)
        XCTAssertEqual(reopenedFrame.minX, airPlayFrame.minX, accuracy: 1)
        XCTAssertEqual(reopenedFrame.minY, airPlayFrame.minY, accuracy: 1)
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
    }

    func testNativeAirPlayChooserReturnsToTheSamePlayingSong() throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_NATIVE_AIRPLAY_UI"] == "1" else {
            throw XCTSkip("Native route UI was unavailable in prior iOS 26.5 simulator runs. "
                + "Declare a capable runner with TEST_RUNNER_GANABAJANA_NATIVE_AIRPLAY_UI=1.")
        }
        let ui = try launchPlayer()
        try ui.play()
        try ui.seek(to: 0.25)
        try ui.expectPosition(66, tolerance: 4)
        try ui.waitForAdvance(from: 66, by: 1)
        let position = try ui.position()
        let started = Date()
        let airPlay = ui.app.buttons["player.airplay"]
        let airPlayFrame = try assertNativeAirPlayAnchor(ui)
        // Tap the native target's padding, outside the compact glyph.
        airPlay.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let exposed = NSPredicate { _, _ in MainActor.assumeIsolated {
            self.hasNativeRouteHeading(in: ui.app) || self.hasNativeRouteHeading(in: springboard)
        }}
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: exposed, object: nil)], timeout: 8)
        guard result == .completed else {
            ui.capture("native-airplay-ui-not-exposed")
            ui.note("native-airplay-accessibility", "App:\n\(ui.app.debugDescription)\nSystem:\n\(springboard.debugDescription)")
            XCTFail("A runner with GANABAJANA_NATIVE_AIRPLAY_UI=1 must expose the system route chooser "
                + "after the padding tap (wait result: \(result.rawValue)).")
            return
        }

        let owner = hasNativeRouteHeading(in: ui.app) ? ui.app : springboard
        XCTAssertTrue(hasNativeRouteHeading(in: owner), "The assertion must observe system route UI, not just the app's AirPlay button.")
        XCTAssertFalse(ui.element("player.options.sheet").exists)
        XCTAssertFalse(ui.element("player.browse.sheet").exists)
        ui.capture("native-airplay-system-route-chooser")
        ui.note("native-airplay-scope", "Observed the system audio-output chooser. No receiver was selected; audio route connection is not established by this test.")

        let done = owner.buttons["Done"]
        let close = owner.buttons["Close"]
        if done.exists && done.isHittable { done.tap() }
        else if close.exists && close.isHittable { close.tap() }
        else {
            // The top-center backdrop is outside the bottom route sheet and the iPad route popover.
            ui.app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }
        try ui.wait("Closing native routes must restore the player's visible AirPlay button") {
            !self.hasNativeRouteHeading(in: ui.app) && !self.hasNativeRouteHeading(in: springboard) && airPlay.isHittable
        }
        let restoredFrame = try assertNativeAirPlayAnchor(ui)
        XCTAssertEqual(restoredFrame.minX, airPlayFrame.minX, accuracy: 1)
        XCTAssertEqual(restoredFrame.minY, airPlayFrame.minY, accuracy: 1)
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Pause")
        let resumedPosition = try ui.position()
        XCTAssertGreaterThanOrEqual(resumedPosition, position)
        XCTAssertLessThanOrEqual(resumedPosition - position, Date().timeIntervalSince(started) + 4)
        try ui.waitForAdvance(from: resumedPosition, by: 1)

        ui.element("player.screen").swipeDown(velocity: .fast)
        try ui.wait("Ending native route presentation must re-enable the player's dismissal gesture") {
            !ui.app.buttons["player.close"].exists && ui.app.buttons["miniPlayer.open"].exists
        }
        try ui.expectLabel(ui.app.buttons["miniPlayer.playPause"], "Pause")
        try ui.openPlayer()
        _ = try assertNativeAirPlayAnchor(ui)
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Pause")
        let reopenedPosition = try ui.position()
        XCTAssertGreaterThanOrEqual(reopenedPosition, resumedPosition)
        XCTAssertLessThanOrEqual(reopenedPosition - position, Date().timeIntervalSince(started) + 4)
        try ui.waitForAdvance(from: reopenedPosition, by: 1)
        ui.capture("native-airplay-returned-player-continuation")
    }

    private func assertNativeAirPlayAnchor(_ ui: AppUITestDriver,
                                          file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let anchor = ui.element("player.airplay.anchor")
        let button = ui.app.buttons["player.airplay"]
        try ui.requireHittable(button)
        XCTAssertTrue(anchor.exists, file: file, line: line)
        XCTAssertEqual(anchor.buttons.matching(identifier: "player.airplay").count, 1, file: file, line: line)
        XCTAssertEqual(ui.app.buttons.matching(identifier: "player.airplay").count, 1, file: file, line: line)
        XCTAssertEqual(anchor.frame.width, 44, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(anchor.frame.height, 44, accuracy: 1e-6, file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.frame.width + 1e-6, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.frame.height + 1e-6, 44, file: file, line: line)
        XCTAssertEqual(button.frame.midX, anchor.frame.midX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(button.frame.midY, anchor.frame.midY, accuracy: 1, file: file, line: line)
        XCTAssertTrue(anchor.frame.insetBy(dx: -1e-6, dy: -1e-6).contains(button.frame), file: file, line: line)
        XCTAssertTrue(ui.app.windows.firstMatch.frame.insetBy(dx: -1e-6, dy: -1e-6).contains(anchor.frame),
                      file: file, line: line)
        XCTAssertLessThan(button.frame.midX, ui.app.buttons["player.lyrics"].frame.midX, file: file, line: line)
        return button.frame
    }

    private func hasNativeRouteHeading(in application: XCUIApplication) -> Bool {
        application.staticTexts["AirPlay"].exists || application.navigationBars["AirPlay"].exists
            || application.staticTexts["Speakers & TVs"].exists
    }

    private func launchPlayer() throws -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "player-airplay")
        addTeardownBlock { await ui.finish() }
        XCUIDevice.shared.orientation = .portrait
        // Direct launch also works with iPad's top tabs; this test needs only the player surface.
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui", "--player",
                                  "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["player.close"])
        return ui
    }
}
