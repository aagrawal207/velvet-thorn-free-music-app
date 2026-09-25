import XCTest

@MainActor
final class GanaBajanaArtistArtworkUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testCombinedChooserShowsTappableArtistsBeforeDelayedPhotos() throws {
        let ui = makeDriver()
        try openDuet(ui, pendingPhotos: true)
        let browse = ui.app.buttons["player.browse"]
        try ui.requireHittable(browse)
        let started = ContinuousClock.now
        browse.tap()
        try assertImmediateRows(ui)
        XCTAssertLessThan(started.duration(to: .now), .seconds(4), "Opening the list must beat the five-second photo deadline")

        try ui.tap(ui.app.buttons["player.artist.0"])
        try assertArtistNavigation(ui, name: "Alka Yagnik")
    }

    func testMoreArtistRouteShowsTappableRowsBeforeDelayedPhotos() throws {
        let ui = makeDriver()
        try openDuet(ui, pendingPhotos: true)
        try ui.tap(ui.app.buttons["player.menu"])
        let artistButton = ui.app.buttons["player.options.artist"]
        try ui.requireHittable(artistButton)
        let started = ContinuousClock.now
        artistButton.tap()
        try assertImmediateRows(ui)
        XCTAssertLessThan(started.duration(to: .now), .seconds(4), "Pushing artist choices must not await photo lookup")

        try ui.tap(ui.app.buttons["player.artist.1"])
        try assertArtistNavigation(ui, name: "Arijit Singh")
    }

    func testArtistNameKeepsTheArtistOnlyChooserForMultipleCredits() throws {
        let ui = makeDriver()
        try openDuet(ui)
        try ui.tap(ui.app.buttons["player.artistName"])
        try assertImmediateRows(ui)
        XCTAssertTrue(ui.element("player.artists.sheet").exists)
        XCTAssertTrue(ui.app.navigationBars["Go to artist"].exists)
        XCTAssertFalse(ui.element("player.browse.sheet").exists)
        XCTAssertFalse(ui.app.buttons["player.browse.album"].exists)
        try ui.tap(ui.app.buttons["player.artists.done"])
        try ui.expectCurrentTrack(AppUIFixture.agarTumSaathHo)
    }

    func testUnavailablePhotosKeepTheFittedSheetAndRowsStableAcrossReopenAndBothRoutes() throws {
        let ui = makeDriver()
        try openDuet(ui)
        try ui.tap(ui.app.buttons["player.browse"])
        try assertImmediateRows(ui)
        let first = ui.app.buttons["player.artist.0"]
        let second = ui.app.buttons["player.artist.1"]
        let initialFirst = first.frame
        let initialSecond = second.frame
        for row in [first, second] {
            XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 44)
            XCTAssertGreaterThanOrEqual(row.frame.width + 1e-6, 44)
        }
        XCTAssertLessThan(ui.element("player.browse.sheet").frame.maxY - initialSecond.maxY, 80)
        ui.capture("artist-picker-unavailable-photos")

        try ui.tap(ui.app.buttons["player.browse.done"])
        try ui.tap(ui.app.buttons["player.browse"])
        try assertImmediateRows(ui)
        XCTAssertEqual(first.frame.height, initialFirst.height, accuracy: 1)
        XCTAssertEqual(second.frame.height, initialSecond.height, accuracy: 1)
        XCTAssertEqual(second.frame.minY - first.frame.minY, initialSecond.minY - initialFirst.minY, accuracy: 1)

        try ui.tap(ui.app.buttons["player.browse.done"])
        try ui.tap(ui.app.buttons["player.menu"])
        try ui.tap(ui.app.buttons["player.options.artist"])
        try assertImmediateRows(ui)
        XCTAssertEqual(first.frame.height, initialFirst.height, accuracy: 1)
        XCTAssertEqual(second.frame.height, initialSecond.height, accuracy: 1)
        ui.capture("artist-options-unavailable-photos")
        try ui.tap(second)
        try assertArtistNavigation(ui, name: "Arijit Singh")
    }

    func testLoadedArtworkKeepsArtistChoicesAndArtistPageUsable() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--artwork-fixture"])
        try ui.search("Agar Tum Saath Ho")
        try ui.waitForSearchResults()
        try ui.playSearchResult(id: AppUIFixture.agarTumSaathHo, title: "Agar Tum Saath Ho")
        try ui.openPlayer()
        ui.capture("artwork-backed-player")
        try ui.tap(ui.app.buttons["player.browse"])
        try assertImmediateRows(ui)
        Thread.sleep(forTimeInterval: 1)
        ui.capture("artist-picker-loaded-fixture-artwork")
        try ui.tap(ui.app.buttons["player.artist.1"])
        try assertArtistNavigation(ui, name: "Arijit Singh")
        try ui.wait("The artist page must finish loading its header") { ui.app.buttons["collection.play"].exists }
        ui.capture("artist-page-artwork-backdrop")
    }

    func testPendingPhotosDoNotDelayDismissalReopenOrPlaybackControls() throws {
        let ui = makeDriver()
        try openDuet(ui, pendingPhotos: true)
        try ui.pause()
        try ui.seek(to: 0.25)
        try ui.expectPosition(86, tolerance: 3)
        let position = try ui.position()
        let controls = [ui.app.buttons["player.browse"], ui.app.buttons["player.airplay"], ui.app.buttons["player.playPause"]]
        let frames = controls.map(\.frame)

        for _ in 0..<3 {
            try ui.tap(ui.app.buttons["player.browse"])
            try assertImmediateRows(ui)
            try ui.tap(ui.app.buttons["player.browse.done"])
            try ui.wait("Dismissing the chooser must not wait for pending artist pictures", timeout: 2) {
                !ui.element("player.browse.sheet").exists && ui.app.buttons["player.browse"].isHittable
            }
            try ui.expectPosition(position)
            try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
            for (control, frame) in zip(controls, frames) {
                XCTAssertEqual(control.frame.minY, frame.minY, accuracy: 1)
                XCTAssertEqual(control.frame.height, frame.height, accuracy: 1)
            }
        }
        try ui.play()
        try ui.waitForAdvance(from: position, by: 1)
        try ui.tap(ui.app.buttons["player.browse"])
        try assertImmediateRows(ui)
        try ui.tap(ui.app.buttons["player.artist.1"])
        try assertArtistNavigation(ui, name: "Arijit Singh")
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.agarTumSaathHo)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Pause")
        try ui.waitForAdvance(from: position, by: 1)
    }

    private func openDuet(_ ui: AppUITestDriver, pendingPhotos: Bool = false) throws {
        try ui.launch(additionalArguments: pendingPhotos ? ["--artist-artwork-pending"] : [])
        // The fixture title proves the delayed catalog is installed rather than silently testing the ordinary fast fixture.
        let title = pendingPhotos ? "Pending artist photo fixture" : "Agar Tum Saath Ho"
        try ui.search(title)
        try ui.waitForSearchResults()
        try ui.playSearchResult(id: AppUIFixture.agarTumSaathHo, title: title)
        try ui.openPlayer()
    }

    private func assertImmediateRows(_ ui: AppUITestDriver) throws {
        let first = ui.app.buttons["player.artist.0"]
        let second = ui.app.buttons["player.artist.1"]
        try ui.wait("Artist choices must be available while the photo requests are pending", timeout: 2) {
            first.exists && second.exists && first.isHittable && second.isHittable
        }
        XCTAssertEqual(first.label, "Alka Yagnik")
        XCTAssertEqual(second.label, "Arijit Singh")
        XCTAssertTrue(first.isEnabled)
        XCTAssertTrue(second.isEnabled)
    }

    private func assertArtistNavigation(_ ui: AppUITestDriver, name: String) throws {
        try ui.wait("Selecting a row must close the player and navigate without waiting for its picture", timeout: 2) {
            !ui.app.buttons["player.close"].exists && !ui.app.buttons["player.artist.0"].exists
                && ui.app.staticTexts["ARTIST"].exists && ui.app.staticTexts[name].exists
        }
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "artist-artwork")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}
