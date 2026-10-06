import UIKit
import XCTest

/// iPad layout captures. iPadOS renders the tab bar at the top as plain buttons (`tab.*`), so this suite launches and
/// navigates on its own instead of through the shared driver's bottom-tab-bar readiness checks.
@MainActor
final class GanaBajanaIPadLayoutUITests: XCTestCase {
    private let app = XCUIApplication()

    override func tearDown() async throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testIPadScreensRenderInRegularWidthPortraitAndLandscape() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui", "--artwork-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + geometryArguments
        app.launchEnvironment = ["GANABAJANA_TEST_STORE": "ipad-layout-\(UUID().uuidString)"]
        app.launch()
        try orient(.portrait)
        try tapDirect(app.buttons["tab.home"].firstMatch)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, 700, "This capture is meant for an iPad simulator")

        capture("ipad-home-portrait")
        try tapDirect(app.buttons["tab.search"].firstMatch)
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 10))
        capture("ipad-search-root-portrait")
        try tapDirect(app.buttons["search.radio.open"])
        assertRadioBrowser()
        capture("ipad-radio-song-artist-search-portrait")
        try tapDirect(app.navigationBars["Radio"].buttons["Back"])
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        try tapDirect(app.buttons["tab.library"].firstMatch)
        capture("ipad-library-portrait")
        try tapDirect(app.buttons["tab.recap"].firstMatch)
        capture("ipad-recap-portrait")

        try tapDirect(app.buttons["tab.home"].firstMatch)
        let firstTrack = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'track.card.'")).firstMatch
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 10))
        try tapDirect(firstTrack)
        let mini = app.buttons["miniPlayer.open"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        let miniFrame = app.otherElements["miniPlayer.container"].frame
        XCTAssertLessThanOrEqual(miniFrame.width, 641, "Regular width caps the mini-player column at 640 points")
        XCTAssertGreaterThanOrEqual(miniFrame.height + 1e-6, 64)
        capture("ipad-home-with-mini-player-portrait")
        try tapDirect(mini)
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 10))
        assertPlayerActions()
        let artwork = app.descendants(matching: .any).matching(identifier: "player.artwork").firstMatch
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertEqual(artwork.frame.width, 600, accuracy: 1, "Regular width portrait sits on the 600-point artwork cap")
        XCTAssertEqual(artwork.frame.height, artwork.frame.width, accuracy: 1)
        capture("ipad-player-portrait")
        try tapDirect(app.buttons["player.queue"])
        XCTAssertTrue(app.buttons["player.shuffle"].waitForExistence(timeout: 10))
        capture("ipad-queue-sheet-portrait")
        try tapDirect(app.buttons["queue.done"])
        // The chooser opens from the artist line once a song has several credits; the duet is queued by autoplay.
        let duet = app.staticTexts["player.track.\(AppUIFixture.agarTumSaathHo)"]
        for _ in 0..<5 where !duet.exists {
            try tapDirect(app.buttons["player.next"])
            _ = duet.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(duet.waitForExistence(timeout: 5))
        try tapDirect(app.buttons["player.artistName"])
        XCTAssertTrue(app.buttons["player.artist.0"].waitForExistence(timeout: 5))
        let chooser = app.otherElements["player.browse.sheet"]
        XCTAssertTrue(chooser.exists)
        XCTAssertLessThan(chooser.frame.height, window.height * 0.45, "Short credit lists must not become a tall iPad form.")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.artist.")).allElementsBoundByIndex
        let last = try XCTUnwrap(rows.last)
        XCTAssertLessThan(chooser.frame.maxY - last.frame.maxY, 100)
        capture("ipad-player-browse-portrait")
        try tapDirect(app.buttons["player.browse.done"])

        try orient(.landscapeLeft)
        assertPlayerActions()
        capture("ipad-player-landscape")
        if app.buttons["player.close"].exists { try tapDirect(app.buttons["player.close"]) }
        try tapDirect(app.buttons["tab.home"].firstMatch)
        sleep(1)
        capture("ipad-home-landscape")
        try tapDirect(app.buttons["tab.search"].firstMatch)
        sleep(1)
        capture("ipad-search-landscape")
        try tapDirect(app.buttons["search.radio.open"])
        assertRadioBrowser()
        capture("ipad-radio-song-artist-search-landscape")
    }

    private func assertRadioBrowser(file: StaticString = #filePath, line: UInt = #line) {
        let field = app.searchFields["Songs or artists"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(field.isHittable, file: file, line: line)
        XCTAssertTrue(app.navigationBars["Radio"].exists, file: file, line: line)
        XCTAssertFalse(app.textFields["search.field"].exists, file: file, line: line)
        XCTAssertFalse(app.keyboards.firstMatch.exists, file: file, line: line)
        XCTAssertFalse(app.buttons["player.close"].exists, file: file, line: line)
        let type = app.buttons["radio.search.type"]
        XCTAssertTrue(type.isHittable, file: file, line: line)
        XCTAssertEqual(type.value as? String, "Songs", file: file, line: line)
        XCTAssertGreaterThanOrEqual(type.frame.height + 1e-6, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(type.frame.width + 1e-6, 44, file: file, line: line)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(type.frame), file: file, line: line)
    }

    private func assertPlayerActions(file: StaticString = #filePath, line: UInt = #line) {
        // Four controls: native AirPlay then Download at the leading edge, Lyrics and Queue together at the trailing edge.
        let ids = ["player.airplay", "player.download", "player.lyrics", "player.queue"]
        let controls = ids.map { app.buttons[$0] }
        for control in controls {
            XCTAssertTrue(control.isHittable, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.width + 1e-6, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.height + 1e-6, 44, file: file, line: line)
            XCTAssertEqual(control.frame.midY, controls[0].frame.midY, accuracy: 1, file: file, line: line)
        }
        for (left, right) in zip(controls, controls.dropFirst()) {
            XCTAssertLessThan(left.frame.midX, right.frame.midX, file: file, line: line)
        }
        XCTAssertFalse(app.buttons["player.browse"].exists, file: file, line: line)
        XCTAssertEqual(controls[0].frame.minX, app.staticTexts["player.elapsed"].frame.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(controls[1].frame.minX, controls[0].frame.maxX + 8, accuracy: 1, file: file, line: line)
        XCTAssertEqual(controls[3].frame.maxX, app.buttons["player.trailingTime"].frame.maxX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(controls[2].frame.maxX + 8, controls[3].frame.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: "player.airplay").count, 1, file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: "player.download").count, 1, file: file, line: line)
    }

    func testIPadAlbumArtworkDurationsAndFooter() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui", "--artwork-fixture",
                               "--search-results", "Arijit", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["GANABAJANA_TEST_STORE": "ipad-collection-\(UUID().uuidString)"]
        app.launch()
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 700)
        try tapDirect(app.buttons["search.filter.albums"])
        try tapDirect(app.buttons["collection.fixture.album"])
        XCTAssertTrue(app.buttons["collection.play"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.otherElements["collection.header"].exists)
        XCTAssertFalse(app.otherElements["collection.header"].staticTexts["collection.summary"].exists)
        capture("ipad-album-artwork-header-portrait")
        for _ in 0..<8 where !app.staticTexts["collection.summary"].isHittable { app.swipeUp() }
        XCTAssertEqual(app.staticTexts["collection.summary"].label, "5 songs · 21:49")
        XCTAssertEqual(app.staticTexts["track.duration.xTvyyoF_LZY"].label, "3:54")
        capture("ipad-album-durations-footer-portrait")
    }

    private func tapDirect(_ element: XCUIElement) throws {
        guard element.waitForExistence(timeout: 15) else {
            throw NSError(domain: "ipad-layout", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(element)"])
        }
        element.tap()
    }

    private var geometryArguments: [String] {
        ProcessInfo.processInfo.environment["GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS"] == "1" ? ["--ui-scene-geometry"] : []
    }

    private func orient(_ orientation: UIDeviceOrientation) throws {
        XCUIDevice.shared.orientation = orientation
        if !geometryArguments.isEmpty { AppUITestDriver.requestSceneGeometry(orientation) }
        let landscape = orientation.isLandscape
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let frame = self.app.windows.firstMatch.frame
                return landscape ? frame.width > frame.height : frame.height > frame.width
            }
        }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 10) == .completed else {
            throw NSError(domain: "ipad-layout", code: 2, userInfo: [NSLocalizedDescriptionKey: "The requested scene orientation did not arrive"])
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
