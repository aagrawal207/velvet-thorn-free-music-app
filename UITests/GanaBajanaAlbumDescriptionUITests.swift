import XCTest

@MainActor
final class GanaBajanaAlbumDescriptionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testDescriptionExpandsAndCollapsesWithVisibleSourceAndLicense() throws {
        let ui = makeDriver()
        try openAlbum(ui)
        let text = ui.app.staticTexts["album.description.text"]
        let expand = ui.app.buttons["album.description.expand"]
        try ui.reveal(expand)
        XCTAssertTrue(text.label.hasPrefix("Synthetic album-description fixture."))
        XCTAssertEqual(expand.value as? String, "Collapsed")
        let collapsedHeight = text.frame.height
        for id in ["album.description.expand", "album.description.source", "album.description.license"] {
            let control = ui.element(id)
            try ui.reveal(control)
            XCTAssertGreaterThanOrEqual(control.frame.height + 1e-6, 44)
        }
        XCTAssertEqual(ui.element("album.description.source").label, "Wikipedia via YouTube Music")
        XCTAssertTrue(ui.element("album.description.license").label.contains("CC BY-SA 3.0"))
        try ui.reveal(expand, direction: .down)
        try ui.tap(expand)
        try ui.wait("Read more must expand the actual description") {
            expand.value as? String == "Expanded" && text.frame.height > collapsedHeight + 20
        }
        try ui.reveal(ui.element("album.description.source"))
        try ui.reveal(ui.element("album.description.license"))
        try ui.reveal(expand, direction: .down)
        try ui.tap(expand)
        try ui.wait("Show less must restore the preview") {
            expand.value as? String == "Collapsed" && abs(text.frame.height - collapsedHeight) < 1
        }
        ui.capture("album-description-collapsed-attribution")
    }

    func testSongsCanPlayWhileTheOptionalDescriptionIsLoading() throws {
        let ui = makeDriver()
        try openAlbum(ui, arguments: ["--album-description-slow"])
        try ui.wait("The slow fixture must have a pending description") { ui.element("album.description.loading").exists }
        let play = ui.app.buttons["collection.play"]
        XCTAssertTrue(play.isEnabled)
        try ui.tap(play)
        try ui.wait("Playing the album must update playback independently of its description") {
            ui.app.buttons["miniPlayer.open"].label.contains("Tum Hi Ho")
        }
        try ui.wait("The description must arrive after the songs are usable") { ui.app.staticTexts["album.description.text"].exists }
        XCTAssertFalse(ui.element("album.description.error").exists)
    }

    func testUnavailableDescriptionLeavesSongsAndActionsUsable() throws {
        let ui = makeDriver()
        try openAlbum(ui, arguments: ["--album-description-empty"])
        try ui.wait("The empty metadata lookup must finish") { !ui.element("album.description.loading").exists }
        XCTAssertFalse(ui.element("album.description").exists)
        XCTAssertFalse(ui.element("album.description.error").exists)
        XCTAssertTrue(ui.app.buttons["collection.play"].isEnabled)
        try ui.reveal(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
    }

    func testRetryableDescriptionFailureRecoversWithoutReloadingTheSongs() throws {
        let ui = makeDriver()
        try openAlbum(ui, arguments: ["--album-description-fail-once"])
        let retry = ui.app.buttons["album.description.retry"]
        try ui.reveal(retry)
        let error = ui.app.otherElements["album.description.error"]
        XCTAssertTrue(error.exists)
        XCTAssertTrue(error.staticTexts["Album details couldn't load."].exists)
        XCTAssertEqual(error.buttons.matching(identifier: "album.description.retry").count, 1)
        XCTAssertEqual(retry.label, "Retry album description")
        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.width + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height + 1e-6, 44)
        XCTAssertTrue(ui.app.buttons["collection.play"].isEnabled)
        try ui.tap(retry)
        try ui.wait("Retry must replace the description error with text") { ui.app.staticTexts["album.description.text"].exists }
        XCTAssertFalse(retry.exists)
        XCTAssertFalse(error.exists)
        try ui.reveal(ui.element("album.description.source"))
        try ui.reveal(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
    }

    private func openAlbum(_ ui: AppUITestDriver, arguments: [String] = []) throws {
        try ui.launch(additionalArguments: ["--album-description-fixture"] + arguments)
        try ui.search("Arijit")
        try ui.waitForSearchResults()
        try ui.selectSearchFilter("albums")
        let album = ui.app.buttons["collection.\(AppUIFixture.album)"]
        try ui.reveal(album)
        try ui.tap(album)
        try ui.wait("The catalog must supply the album's songs") {
            ui.app.staticTexts["ALBUM"].exists && ui.app.buttons["collection.play"].exists
        }
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "album-description")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}
