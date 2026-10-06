import UIKit
import XCTest

/// The player shell: art with 12-point side insets on phones, the heading one line below it, a four-control
/// bottom row and a right time label that switches between song length and remaining time.
@MainActor
final class GanaBajanaPlayerShellUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testArtworkFillsTheInsetColumnAndTheHeadingSitsJustBelowIt() throws {
        let ui = try launchPlayer()
        let artwork = ui.element("player.artwork")
        let title = ui.app.staticTexts["player.track.\(AppUIFixture.tumHiHo)"]
        let artistLine = ui.app.buttons["player.artistName"]
        try ui.wait("The artwork must expose its frame for layout checks") { artwork.exists && artwork.frame.width > 0 }
        let window = ui.app.windows.firstMatch.frame
        let leading = ui.app.staticTexts["player.elapsed"].frame.minX
        let trailing = ui.app.buttons["player.trailingTime"].frame.maxX
        let column = trailing - leading
        let art = artwork.frame
        let gap = title.frame.minY - art.maxY
        ui.note("player-shell-geometry", """
        window: \(window)
        column: \(column) from \(leading) to \(trailing)
        artwork: \(art)
        title: \(title.frame), artist line: \(artistLine.frame)
        heading gap below artwork: \(gap)
        airplay: \(ui.app.buttons["player.airplay"].frame)
        download: \(ui.app.buttons["player.download"].frame)
        lyrics: \(ui.app.buttons["player.lyrics"].frame)
        queue: \(ui.app.buttons["player.queue"].frame)
        trailing time: \(ui.app.buttons["player.trailingTime"].frame)
        play: \(ui.app.buttons["player.playPause"].frame)
        """)

        XCTAssertEqual(art.width, art.height, accuracy: 1, "Artwork stays square")
        XCTAssertEqual(art.midX, window.midX, accuracy: 1, "Artwork stays centered")
        XCTAssertGreaterThanOrEqual(art.minX, window.minX + 12 - 1e-6, "Art keeps at least the 12-point side inset")
        XCTAssertLessThanOrEqual(art.maxY + 1e-6, title.frame.minY, "The heading follows the art")
        if window.width > 700 {
            XCTAssertEqual(art.width, 600, accuracy: 1, "Regular width sits on the 600-point cap")
        } else {
            XCTAssertTrue((12...40).contains(gap), "The heading sits one padding below the art, not a Spacer away: \(gap)")
            XCTAssertGreaterThan(title.frame.minY, window.midY, "The title stays below the window midline")
            if window.height >= 800 {
                // 17 Pro class: width-bound art runs 12 points beyond the 24-point column on each side.
                XCTAssertGreaterThanOrEqual(art.width, 370)
                XCTAssertEqual(art.width, column + 24, accuracy: 1)
                XCTAssertEqual(art.minX, window.minX + 12, accuracy: 1)
            } else {
                // SE class: height-bound art grows with the 20 points freed from the transport and bottom rows.
                XCTAssertGreaterThanOrEqual(art.width, 245)
                XCTAssertLessThan(art.width, column + 24)
            }
        }
        XCTAssertGreaterThanOrEqual(artistLine.frame.minY + 1e-6, title.frame.maxY)
        // Four 44-point controls and the spacer fit the column on every phone: Download follows AirPlay by 8 points and
        // still leaves room before Lyrics.
        let download = ui.app.buttons["player.download"].frame
        XCTAssertEqual(download.minX, ui.app.buttons["player.airplay"].frame.maxX + 8, accuracy: 1)
        XCTAssertGreaterThanOrEqual(download.width + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(ui.app.buttons["player.lyrics"].frame.minX, download.maxX + 8)
        let airPlay = ui.app.buttons["player.airplay"].frame, lyrics = ui.app.buttons["player.lyrics"].frame,
            queue = ui.app.buttons["player.queue"].frame
        XCTAssertEqual(airPlay.minX, ui.app.staticTexts["player.elapsed"].frame.minX, accuracy: 1)
        XCTAssertEqual(lyrics.maxX + 8, queue.minX, accuracy: 1)
        XCTAssertEqual(queue.maxX, ui.app.buttons["player.trailingTime"].frame.maxX, accuracy: 1)
        for frame in [airPlay, download, lyrics, queue] {
            XCTAssertEqual(frame.midY, airPlay.midY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(min(frame.width, frame.height) + 1e-6, 44)
        }
        ui.capture("player-shell-artwork-and-heading")
    }

    func testTrailingTimeLabelSwitchesStylesAndKeepsTheChoiceAcrossReopenAndRelaunch() throws {
        let ui = try launchPlayer()
        let label = ui.app.buttons["player.trailingTime"]
        let elapsed = ui.app.staticTexts["player.elapsed"]
        try ui.requireHittable(label)
        XCTAssertGreaterThanOrEqual(label.frame.height + 1e-6, 44, "The switch has a thumb-sized target")
        XCTAssertGreaterThanOrEqual(label.frame.width + 1e-6, 44, "The target widens leftward into the empty middle of the row")
        XCTAssertEqual(label.frame.maxX, ui.app.buttons["player.like"].frame.maxX, accuracy: 1, "The text keeps the column's trailing edge")
        XCTAssertGreaterThanOrEqual(label.frame.minY + 4, elapsed.frame.minY, "The target must not grow upward into the seek row")
        XCTAssertGreaterThan(label.frame.maxY, elapsed.frame.maxY + 20, "The target grows downward below the time row")
        XCTAssertLessThan(label.frame.minY, ui.app.buttons["player.playPause"].frame.minY)
        XCTAssertLessThan(label.frame.midY, ui.app.buttons["player.playPause"].frame.minY,
                          "The label's activation point stays above the transport row")
        XCTAssertEqual(try ui.duration(), 262, accuracy: 1)
        try ui.expectLabel(label, "Song length")
        try ui.expectValue(label, "4:22")
        XCTAssertFalse(ui.app.staticTexts["player.remaining"].exists, "No separate remaining-only element sits beside the switch")
        ui.capture("player-shell-song-length")

        // The heart sits in the heading at the column's trailing edge; its lower corner still likes rather than switching.
        let like = ui.app.buttons["player.like"]
        let likedLabel = like.label
        like.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.95)).tap()
        try ui.wait("The heart's lower corner must toggle the like") { like.label != likedLabel }
        try ui.expectLabel(label, "Song length")
        try ui.tap(like)
        try ui.wait("The heart must restore the fixture's like") { like.label == likedLabel }

        try ui.tap(label)
        try ui.expectLabel(label, "Remaining time")
        let position = try ui.position()
        let remaining = try ui.trailingTime().seconds
        XCTAssertEqual(position + remaining, 262, accuracy: 1, "Remaining time counts down from the song length")
        XCTAssertEqual(remaining, try ui.remaining(), accuracy: 1)
        ui.capture("player-shell-remaining")

        // The choice is a saved preference: it survives closing the player and relaunching the app.
        try ui.tap(ui.app.buttons["player.close"])
        try ui.openPlayer()
        try ui.expectLabel(label, "Remaining time")
        ui.app.terminate()
        ui.app.launchArguments.removeAll { $0 == "--reset-ui" }
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["player.close"])
        try ui.expectLabel(label, "Remaining time")
        XCTAssertEqual(try ui.position() + ui.trailingTime().seconds, 262, accuracy: 1)

        // A tap on the visible digits themselves switches back.
        label.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.25)).tap()
        try ui.expectLabel(label, "Song length")
        try ui.expectValue(label, "4:22")
        try ui.tap(ui.app.buttons["player.close"])
        try ui.openPlayer()
        try ui.expectLabel(label, "Song length")
    }

    /// The right time label has no Settings row; the player tap alone writes the saved preference.
    func testRightTimeLabelIsSetFromThePlayerOnlyAndPersists() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "player-shell-settings")
        addTeardownBlock { await ui.finish() }
        try ui.launch()
        try ui.openSettings()
        XCTAssertFalse(ui.element("settings.trailingTime").exists, "The root list has no Right time label row")
        try ui.openSettingsPage(.playback)
        let shuffle = ui.app.buttons["settings.shuffleStyle"]
        try ui.reveal(shuffle, maxSwipes: 16)
        XCTAssertFalse(ui.element("settings.trailingTime").exists, "Playback has no Right time label row")
        XCTAssertFalse(ui.app.staticTexts["Right time label"].exists)
        try ui.tap(ui.app.buttons["settings.done"])

        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        let label = ui.app.buttons["player.trailingTime"]
        try ui.expectLabel(label, "Song length")
        try ui.tap(label)
        try ui.expectLabel(label, "Remaining time")
        XCTAssertEqual(try ui.position() + ui.trailingTime().seconds, 262, accuracy: 1)
        try ui.closePlayer()
        try ui.relaunch()
        try ui.openPlayer()
        try ui.expectLabel(label, "Remaining time")
    }

    private func launchPlayer() throws -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "player-shell")
        addTeardownBlock { await ui.finish() }
        XCUIDevice.shared.orientation = .portrait
        // Direct launch also works with iPad's top tabs; these tests need only the player surface.
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui", "--player",
                                  "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["player.close"])
        return ui
    }
}
