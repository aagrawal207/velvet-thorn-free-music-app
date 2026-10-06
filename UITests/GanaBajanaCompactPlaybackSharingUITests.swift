import XCTest

@MainActor
final class GanaBajanaCompactPlaybackSharingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPlaylistCreationActionSitsBesideItsSectionHeading() throws {
        let ui = driver()
        try ui.launch()
        try ui.selectTab("library")
        let add = ui.app.buttons["library.createPlaylist"]
        try ui.reveal(add)
        let heading = ui.app.staticTexts["Playlists"]
        XCTAssertEqual(add.frame.midY, heading.frame.midY, accuracy: 2)
        XCTAssertGreaterThan(add.frame.minX, heading.frame.maxX)
        XCTAssertGreaterThan(add.frame.minY, ui.app.staticTexts["Your Library"].frame.maxY)
        XCTAssertEqual(ui.app.buttons.matching(identifier: "library.createPlaylist").count, 1)
        XCTAssertGreaterThanOrEqual(add.frame.height + 1e-6, 44)
        ui.capture("playlist-add-beside-heading")
        try ui.tap(add)
        let name = ui.app.textFields["library.playlist.name"]
        try ui.requireHittable(name)
        try ui.wait("The editor finishes focusing its name field") { ui.app.keyboards.firstMatch.exists }
        name.typeText("Unfinished Playlist")
        try ui.wait("The draft is editable from the relocated action") { name.value as? String == "Unfinished Playlist" }
        try ui.tap(ui.app.buttons["library.playlist.cancel"])
        try ui.wait("Cancel returns to the same playlist section") { add.isHittable }
    }

    func testLikedSongsShowsDurationsAndCompactQueueControls() throws {
        let ui = driver()
        try ui.launch()
        try ui.selectTab("library")
        try ui.tap(ui.app.buttons["library.likes"])
        let play = ui.app.buttons["library.likes.play"]
        let shuffle = ui.app.buttons["library.likes.shuffle"]
        try ui.wait("Liked Songs finishes presenting its list before scrolling") { play.exists && shuffle.exists }
        try ui.reveal(play)
        for button in [play, shuffle] {
            try ui.requireHittable(button)
            XCTAssertEqual(button.frame.height, 44, accuracy: 1)
            XCTAssertGreaterThanOrEqual(button.frame.width + 1e-6, 44)
        }
        XCTAssertEqual(play.frame.midY, shuffle.frame.midY, accuracy: 1)
        let track = ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(track)
        XCTAssertTrue((track.value as? String ?? "").contains("Duration 4:22"))
        XCTAssertTrue(ui.app.staticTexts["track.duration.\(AppUIFixture.tumHiHo)"].exists)
        ui.capture("liked-songs-compact-controls-and-duration")
        try ui.tap(track)
        try ui.wait("A duration-labelled row keeps its playback action") {
            ui.app.buttons["miniPlayer.open"].label.contains("Tum Hi Ho")
        }
    }

    func testStatsSharesOnlyTheImageUnlessSummaryTextIsSelected() throws {
        let ui = driver()
        try ui.launch()
        try ui.selectTab("recap")
        let share = ui.app.buttons["recap.share"]
        try ui.reveal(share)
        try ui.tap(share)
        let include = "recap.share.includeText"
        try ui.wait("The card renders before sharing options appear") { ui.app.switches[include].exists }
        try ui.reveal(ui.app.switches[include])
        try ui.expectSwitch(include, isOn: false)
        XCTAssertEqual(ui.element("recap.share.contents").label, "Shares only the image.")
        try ui.requireHittable(ui.app.buttons["recap.share.previewShare"])
        ui.capture("stats-share-image-only")
        try ui.setSwitch(include, to: true)
        XCTAssertEqual(ui.element("recap.share.contents").label, "Shares the image and its summary text.")
        try ui.setSwitch(include, to: false)
        try ui.tap(ui.app.buttons["recap.share.done"])
        try ui.reveal(share)
        try ui.tap(share)
        try ui.wait("Every new preview defaults to image-only") { ui.app.switches[include].exists }
        try ui.expectSwitch(include, isOn: false)
    }

    private func driver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "compact-playback-sharing")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}
