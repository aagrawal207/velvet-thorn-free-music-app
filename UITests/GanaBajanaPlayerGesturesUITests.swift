import UIKit
import XCTest

/// An upward swipe over the artwork or heading opens the sheet chosen in Settings > Playback (Lyrics by default),
/// without disturbing the downward dismissal, the horizontal seek or the heading's buttons.
@MainActor
final class GanaBajanaPlayerGesturesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSwipeUpOnTheArtworkOpensLyricsByDefaultAndSwipeDownStillDismisses() throws {
        let app = launchPlayer()
        let artwork = app.descendants(matching: .any).matching(identifier: "player.artwork").firstMatch
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        let elapsed = app.staticTexts["player.elapsed"]
        let position = try XCTUnwrap(AppUIClock.seconds(elapsed.value as? String))

        artwork.swipeUp()
        let lyrics = app.descendants(matching: .any).matching(identifier: "lyrics.screen").firstMatch
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5), "Swiping up on the artwork opens Lyrics by default")
        XCTAssertTrue(app.navigationBars["Lyrics"].exists)
        XCTAssertFalse(app.otherElements["player.options.sheet"].exists)
        capture(app, "player-swipe-up-lyrics")
        app.buttons["lyrics.done"].tap()
        waitFor("Closing Lyrics must return to the player") { !lyrics.exists && app.buttons["player.close"].isHittable }
        XCTAssertEqual(try XCTUnwrap(AppUIClock.seconds(elapsed.value as? String)), position, accuracy: 1,
                       "Opening a sheet never seeks")

        // The heading swipes too, and a swipe that starts on the heart must not toggle the like. XCUITest's swipeUp()
        // scales with the element, so a 52-point button gets an explicit drag instead.
        let like = app.buttons["player.like"]
        let likedLabel = like.label
        let heart = like.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        heart.press(forDuration: 0.05, thenDragTo: heart.withOffset(CGVector(dx: 0, dy: -220)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5), "Swiping up from the heading opens Lyrics")
        app.buttons["lyrics.done"].tap()
        waitFor("Closing Lyrics must return to the player") { !lyrics.exists && app.buttons["player.close"].isHittable }
        XCTAssertEqual(like.label, likedLabel, "A swipe starting on the heart does not like or unlike")
        like.tap()
        waitFor("A plain tap on the heart still toggles the like") { like.label != likedLabel }
        like.tap()
        waitFor("The like restores") { like.label == likedLabel }

        // Swiping up on the transport row is not a player gesture.
        app.buttons["player.playPause"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.buttons["player.playPause"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -3)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertFalse(lyrics.waitForExistence(timeout: 1.5), "The transport row does not open Lyrics")
        XCTAssertTrue(app.buttons["player.close"].isHittable)

        app.otherElements["player.screen"].swipeDown(velocity: .fast)
        waitFor("A downward swipe still dismisses the player") {
            !app.buttons["player.close"].exists && app.buttons["miniPlayer.open"].exists
        }
    }

    func testHorizontalSeekDragOnTheBarDoesNotOpenASheet() throws {
        let app = launchPlayer()
        let slider = app.sliders["player.seek"]
        let elapsed = app.staticTexts["player.elapsed"]
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        waitFor("A horizontal drag seeks linearly across the bar") {
            guard let seconds = AppUIClock.seconds(elapsed.value as? String) else { return false }
            return abs(seconds - 0.6 * 262) <= 6
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "lyrics.screen").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "queue.list").firstMatch.exists)
        XCTAssertFalse(app.otherElements["player.options.sheet"].exists)
        XCTAssertTrue(app.buttons["player.close"].isHittable)

        // A slanted drag that starts on the bar stays a seek: the bar is not part of the swipe-up area.
        let slanted = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        slanted.press(forDuration: 0.05, thenDragTo: slanted.withOffset(CGVector(dx: 0, dy: -140)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "lyrics.screen").firstMatch.waitForExistence(timeout: 1.5),
                       "An upward drag from the bar opens nothing")
        XCTAssertTrue(app.buttons["player.close"].isHittable)
    }

    func testSettingsChoiceMakesSwipeUpOpenTheQueueOrNothing() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "player-gestures")
        addTeardownBlock { await ui.finish() }
        try ui.launch()
        try ui.openSettings()
        try ui.openSettingsPage(.playback)
        let picker = ui.app.buttons["settings.playerSwipeUp"]
        let quality = ui.app.buttons["settings.audioQuality"]
        try ui.reveal(quality, maxSwipes: 16)
        try ui.reveal(picker, maxSwipes: 16)
        XCTAssertGreaterThanOrEqual(picker.frame.height + 1e-6, 44)
        XCTAssertGreaterThan(picker.frame.minY, quality.frame.maxY - 1, "The row follows Audio quality in Playback")
        try ui.expectValue(picker, "Lyrics")
        XCTAssertFalse(ui.app.staticTexts["settings.playerSwipeUp.description"].exists, "The value on the row replaces the note")
        try ui.tap(picker)
        for title in ["Lyrics", "Queue", "More Options", "Off"] {
            XCTAssertTrue(ui.app.buttons[title].waitForExistence(timeout: 3), "The menu offers \(title)")
        }
        try ui.tap(ui.app.buttons["Queue"])
        try ui.expectValue(picker, "Queue")
        ui.capture("settings-swipe-up-queue")
        try ui.tap(ui.app.buttons["settings.done"])

        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        let artwork = ui.element("player.artwork")
        try ui.wait("The artwork must expose its frame") { artwork.exists && artwork.frame.width > 0 }
        artwork.swipeUp()
        let queue = ui.element("queue.list")
        try ui.wait("Swiping up must open the Queue once chosen in Settings") { queue.exists }
        XCTAssertTrue(ui.app.buttons["player.shuffle"].exists)
        XCTAssertFalse(ui.element("lyrics.screen").exists)
        try ui.closeSheet("Queue")

        // Off leaves the swipe inert: the player stays and no sheet opens.
        try ui.closePlayer()
        try ui.openSettings()
        try ui.openSettingsPage(.playback)
        try ui.reveal(picker, maxSwipes: 16)
        try ui.tap(picker)
        try ui.tap(ui.app.buttons["Off"])
        try ui.expectValue(picker, "Off")
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.openPlayer()
        try ui.wait("The artwork must expose its frame") { artwork.exists && artwork.frame.width > 0 }
        let position = try ui.position()
        artwork.swipeUp()
        XCTAssertFalse(queue.waitForExistence(timeout: 1.5), "Off opens nothing")
        XCTAssertFalse(ui.element("lyrics.screen").exists)
        XCTAssertFalse(ui.element("player.options.sheet").exists)
        XCTAssertTrue(ui.element("player.screen").exists)
        try ui.requireHittable(ui.app.buttons["player.close"])
        try ui.expectPosition(position, tolerance: 1)

        // The choice persists across a relaunch like every other preference.
        try ui.relaunch()
        try ui.openSettings()
        try ui.openSettingsPage(.playback)
        try ui.reveal(picker, maxSwipes: 16)
        try ui.expectValue(picker, "Off")
    }

    private func waitFor(_ message: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                         condition: @escaping @MainActor () -> Bool) {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message, file: file, line: line)
    }

    private func launchPlayer() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui", "--player",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["GANABAJANA_TEST_STORE"] = "player-gestures-\(UUID().uuidString)"
        app.launch()
        addTeardownBlock { @MainActor in
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
