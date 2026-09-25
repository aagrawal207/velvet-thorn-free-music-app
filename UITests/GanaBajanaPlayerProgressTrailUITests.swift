import UIKit
import XCTest

/// The progress bar and the like heart form one line: the bar fills first, then the last stretch of the song
/// traces the heart's outline. Seeks must reach that stretch, and liking must stay a plain tap on the heart.
@MainActor
final class GanaBajanaPlayerProgressTrailUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testBarAndHeartShareOneLineAndTheHeartStretchStaysSeekable() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        XCTAssertEqual(try ui.duration(), 262, accuracy: 1)

        let seek = ui.app.sliders["player.seek"]
        let like = ui.app.buttons["player.like"]
        let remaining = ui.app.staticTexts["player.remaining"]
        let title = ui.app.staticTexts["player.track.\(AppUIFixture.tumHiHo)"]
        try ui.requireHittable(like)
        XCTAssertEqual(like.frame.midY, seek.frame.midY, accuracy: 1, "The heart sits on the progress line")
        XCTAssertGreaterThanOrEqual(like.frame.minX + 1e-6, seek.frame.maxX, "The heart follows the bar")
        XCTAssertEqual(like.frame.maxX, remaining.frame.maxX, accuracy: 1, "The heart ends the row")
        XCTAssertGreaterThan(like.frame.minY, title.frame.maxY, "The heading no longer hosts the heart")
        XCTAssertGreaterThanOrEqual(like.frame.width + 1e-6, 52)
        XCTAssertGreaterThanOrEqual(like.frame.height + 1e-6, 52)
        XCTAssertGreaterThanOrEqual(seek.frame.height + 1e-6, 44)
        XCTAssertGreaterThan(ui.app.buttons["player.playPause"].frame.minY, like.frame.maxY)

        let trail = ui.app.playerProgressTrail
        XCTAssertGreaterThan(trail.junctionFraction, 0.7)
        XCTAssertLessThan(trail.junctionFraction, 0.92)
        let junction = trail.junctionFraction * 262

        // The fixture song starts liked; the outline only shows while the song is not liked.
        XCTAssertEqual(like.label, "Unlike this song")
        try ui.tap(like)
        try ui.wait("Unliking must clear the heart") { like.label == "Like this song" }
        try ui.seek(to: 0.4)
        try ui.expectPosition(0.4 * 262, tolerance: 3)
        ui.capture("player-trail-bar-filling")
        try ui.seek(to: trail.junctionFraction)
        try ui.expectPosition(junction, tolerance: 3)
        ui.capture("player-trail-bar-complete")
        try ui.seek(to: trail.junctionFraction + (1 - trail.junctionFraction) * 0.45)
        try ui.expectPosition(junction + (262 - junction) * 0.45, tolerance: 3)
        ui.capture("player-trail-heart-half-traced")
        try ui.seek(to: 0.995)
        try ui.expectPosition(0.995 * 262, tolerance: 3)
        ui.capture("player-trail-heart-traced")
        XCTAssertEqual(try ui.position() + ui.remaining(), 262, accuracy: 1)

        // A plain tap on the heart likes the song; it never seeks.
        let position = try ui.position()
        XCTAssertEqual(like.label, "Like this song")
        try ui.tap(like)
        try ui.wait("Tapping the heart must like the song") { like.label == "Unlike this song" }
        XCTAssertTrue(like.isSelected)
        try ui.expectPosition(position, tolerance: 1)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        ui.capture("player-trail-liked")
        try ui.tap(like)
        try ui.wait("Tapping again must unlike the song") { like.label == "Like this song" }
        try ui.expectPosition(position, tolerance: 1)

        // Dragging back from the heart's stretch onto the bar still scrubs.
        try ui.seek(to: 0.2)
        try ui.expectPosition(0.2 * 262, tolerance: 3)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
    }

    /// Opens the player directly over fixture artwork, so the row and the container-free transport are checked on
    /// every device class and appearance without the phone tab bar.
    func testTrailAndTransportSitOnTheArtworkBackdropInDarkAppearance() throws {
        try assertTrailOverArtwork(light: false)
    }

    func testTrailAndTransportSitOnTheArtworkBackdropInLightAppearance() throws {
        try assertTrailOverArtwork(light: true)
    }

    private func assertTrailOverArtwork(light: Bool) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui", "--player", "--artwork-fixture"]
            + (light ? ["--light"] : [])
        app.launchEnvironment["GANABAJANA_TEST_STORE"] = "player-trail-\(UUID().uuidString)"
        app.launch()
        addTeardownBlock { @MainActor in
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let appearance = light ? "light" : "dark"
        let seek = app.sliders["player.seek"]
        let like = app.buttons["player.like"]
        let elapsed = app.staticTexts["player.elapsed"]
        XCTAssertTrue(like.waitForExistence(timeout: 15))
        XCTAssertTrue(seek.exists)
        XCTAssertEqual(like.frame.midY, seek.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(like.frame.minX + 1e-6, seek.frame.maxX)
        XCTAssertEqual(like.frame.maxX, app.staticTexts["player.remaining"].frame.maxX, accuracy: 1)
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(like.frame))
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(seek.frame))

        // The transport keeps its geometry without a container: even spacing, shared center line, 80-point play.
        let previous = app.buttons["player.previous"].frame, play = app.buttons["player.playPause"].frame,
            next = app.buttons["player.next"].frame
        XCTAssertEqual(previous.midY, play.midY, accuracy: 1)
        XCTAssertEqual(next.midY, play.midY, accuracy: 1)
        XCTAssertEqual(play.minX - previous.maxX, next.minX - play.maxX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(play.width + 1e-6, 80)
        XCTAssertGreaterThan(play.minY, like.frame.maxY)

        let fixtureDuration: TimeInterval = 262
        let trail = app.playerProgressTrail
        if like.label == "Unlike this song" {
            like.tap()
            waitFor("The fixture song must be unliked to show the outline") { like.label == "Like this song" }
        }
        func drag(to progress: CGFloat) {
            let current = (AppUIClock.seconds(elapsed.value as? String) ?? 0) / fixtureDuration
            let start = seek.coordinate(withNormalizedOffset: CGVector(dx: min(app.playerSeekNormalizedX(forProgress: current), 0.98), dy: 0.5))
            let end = seek.coordinate(withNormalizedOffset: CGVector(dx: app.playerSeekNormalizedX(forProgress: progress), dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)
            waitFor("The drag must land at \(progress) of the fixture") {
                guard let seconds = AppUIClock.seconds(elapsed.value as? String) else { return false }
                return abs(seconds - progress * fixtureDuration) <= 3
            }
        }
        drag(to: 0.45)
        capture(app, "player-trail-\(appearance)-bar-filling")
        drag(to: trail.junctionFraction + (1 - trail.junctionFraction) * 0.5)
        capture(app, "player-trail-\(appearance)-heart-half-traced")
        // A liked song must keep the trace readable over the tinted heart.
        like.tap()
        waitFor("Liking mid-trace must not move the position") {
            like.label == "Unlike this song" && abs((AppUIClock.seconds(elapsed.value as? String) ?? -1)
                - (trail.junctionFraction + (1 - trail.junctionFraction) * 0.5) * fixtureDuration) <= 3
        }
        capture(app, "player-trail-\(appearance)-liked-half-traced")
        like.tap()
        waitFor("Unliking must restore the outline") { like.label == "Like this song" }
        drag(to: 0.995)
        capture(app, "player-trail-\(appearance)-heart-traced")
        like.tap()
        waitFor("The completed heart must still like the song on tap") { like.label == "Unlike this song" }
        capture(app, "player-trail-\(appearance)-liked")

        // Regular-width windows also use the side-by-side landscape player.
        guard window.width > 700 else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        if ProcessInfo.processInfo.environment["GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS"] == "1" {
            AppUITestDriver.requestSceneGeometry(.landscapeLeft)
        }
        waitFor("The window must turn landscape") {
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }
        waitFor("The row must settle in landscape") { abs(like.frame.midY - seek.frame.midY) <= 1 }
        XCTAssertGreaterThanOrEqual(like.frame.minX + 1e-6, seek.frame.maxX)
        XCTAssertEqual(like.frame.maxX, app.staticTexts["player.remaining"].frame.maxX, accuracy: 1)
        XCTAssertGreaterThan(app.buttons["player.playPause"].frame.minY, like.frame.maxY)
        capture(app, "player-trail-\(appearance)-landscape")
    }

    private func waitFor(_ message: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                         condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail(message, file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "player-trail")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}
