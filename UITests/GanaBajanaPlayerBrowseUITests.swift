import UIKit
import XCTest

@MainActor
final class GanaBajanaPlayerBrowseUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSingleCreditWithoutAnAlbumOpensTheArtistDirectly() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.seek(to: 0.35)
        try ui.expectPosition(92, tolerance: 3)
        let position = try ui.position()

        // One credit and an album title without an id leave a single destination, so no chooser is offered.
        XCTAssertFalse(ui.app.buttons["player.browse"].exists, "The bottom row has no Album and artists button.")
        let artistLine = ui.app.buttons["player.artistName"]
        try ui.expectLabel(artistLine, "Go to artist, Arijit Singh")
        XCTAssertTrue(artistLine.isEnabled)
        ui.capture("single-artist-no-album-direct-line")
        try ui.tap(artistLine)
        try ui.expectArtistPage(named: "Arijit Singh")
        XCTAssertFalse(ui.element("player.browse.sheet").exists, "A single destination must not open the chooser.")
        XCTAssertFalse(ui.element("player.artists.sheet").exists)
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectPosition(position)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
    }

    func testAlbumChoiceFitsWithItsArtistAndKeepsPlaybackMoving() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--artist-navigation-fixture"])
        let trackID = "fixture.setup.norah.2002"
        try ui.openPlayer()
        try ui.expectCurrentTrack(trackID)
        try ui.play()
        try ui.seek(to: 0.25)
        try ui.expectPosition(60, tolerance: 4)
        let position = try ui.position()
        let started = Date()

        // One credit plus a real album id is two destinations, so the artist line offers the chooser.
        let artistLine = ui.app.buttons["player.artistName"]
        try ui.expectLabel(artistLine, "Album and artists, Norah Jones")
        try ui.tap(artistLine)
        let album = ui.app.buttons["player.browse.album"]
        let artist = ui.app.buttons["player.artist.0"]
        try ui.requireHittable(album)
        try ui.requireHittable(artist)
        XCTAssertEqual(album.label, "Go to Album")
        XCTAssertEqual(album.value as? String, "Come Away With Me")
        XCTAssertEqual(artist.label, "Norah Jones")
        XCTAssertFalse(ui.app.buttons["player.artist.1"].exists)
        XCTAssertGreaterThan(artist.frame.minY, album.frame.maxY)
        try assertFittedChooser(ui, first: album, last: artist)
        ui.capture("album-and-single-artist-chooser")

        try ui.tap(album)
        try expectAlbum(ui, title: "Come Away With Me")
        try ui.expectLabel(ui.app.buttons["miniPlayer.playPause"], "Pause")
        try ui.openPlayer()
        try ui.expectCurrentTrack(trackID)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Pause")
        let resumedPosition = try ui.position()
        XCTAssertGreaterThanOrEqual(resumedPosition, position)
        XCTAssertLessThanOrEqual(resumedPosition - position, Date().timeIntervalSince(started) + 4,
                                "Browsing must not seek or restart playback; allow time spent in UI automation.")
        try ui.waitForAdvance(from: resumedPosition, by: 1)
    }

    func testAlbumAndEveryCreditShareOneChooserThatScrollsPastFiveArtists() throws {
        let ui = makeDriver()
        // The exact title makes missing opt-in fixture support fail before any chooser assertion.
        try ui.launch(additionalArguments: ["--player-browse-fixture"])
        try ui.search("Album and artists fixture")
        try ui.playSearchResult(id: AppUIFixture.agarTumSaathHo, title: "Album and artists fixture")
        try ui.openPlayer()
        try ui.pause()
        let position = try ui.position()

        try ui.tap(ui.app.buttons["player.artistName"])
        let album = ui.app.buttons["player.browse.album"]
        try ui.requireHittable(album)
        XCTAssertEqual(album.value as? String, "Evening favorites")
        let names = ["Alka Yagnik", "Arijit Singh", "The Weeknd", "Ed Sheeran", "A. R. Rahman", "Norah Jones"]
        for (index, name) in names.enumerated() {
            let artist = ui.app.buttons["player.artist.\(index)"]
            XCTAssertTrue(artist.exists)
            XCTAssertTrue(artist.isEnabled)
            XCTAssertEqual(artist.label, name)
        }
        let chooser = ui.element("player.browse.sheet")
        try assertFittedChooser(ui, first: album, last: ui.app.buttons["player.artist.4"])
        XCTAssertGreaterThan(ui.app.buttons["player.artist.5"].frame.maxY, chooser.frame.maxY,
                             "The initial content-sized detent fits five artists, with more available by scrolling.")
        ui.capture("album-and-six-artist-chooser")
        try ui.tap(album)
        try expectAlbum(ui, title: "Evening favorites")
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.agarTumSaathHo)
        try ui.expectPosition(position)

        try ui.tap(ui.app.buttons["player.artistName"])
        let last = ui.app.buttons["player.artist.5"]
        let list = ui.app.scrollViews["player.browse.list"]
        try ui.requireHittable(list)
        let initialLastTop = last.frame.minY
        list.swipeUp(velocity: .slow)
        try ui.wait("Scrolling must reveal the whole sixth artist without closing the chooser") {
            last.exists && last.isHittable && chooser.frame.insetBy(dx: -1, dy: -1).contains(last.frame)
                && last.frame.minY < initialLastTop - 1
        }
        ui.capture("album-and-six-artist-chooser-scrolled")
        try ui.tap(last)
        try ui.expectArtistPage(named: "Norah Jones")
        XCTAssertFalse(chooser.exists)
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.agarTumSaathHo)
        try ui.expectPosition(position)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
    }

    func testAlbumAndArtistChoicesFitLargestTextAndRemainReachableInLandscape() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--artist-navigation-fixture", "--light", "-UIPreferredContentSizeCategoryName",
                                            UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
        try ui.openPlayer()
        try ui.tap(ui.app.buttons["player.artistName"])
        let album = ui.app.buttons["player.browse.album"]
        let artist = ui.app.buttons["player.artist.0"]
        try assertFittedChooser(ui, first: album, last: artist)
        ui.capture("album-artist-chooser-largest-text")
        try ui.tap(ui.app.buttons["player.browse.done"])

        try ui.rotateToLandscape()
        // AirPlay leads the row and Queue trails it, with Lyrics 8 points inside Queue and no browse control.
        let controls = ["player.airplay", "player.lyrics", "player.queue"].map { ui.app.buttons[$0] }
        for control in controls {
            try ui.requireHittable(control)
            XCTAssertGreaterThanOrEqual(control.frame.width + 1e-6, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height + 1e-6, 44)
            XCTAssertTrue(ui.app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(control.frame))
            XCTAssertEqual(control.frame.midY, controls[0].frame.midY, accuracy: 1)
        }
        for (left, right) in zip(controls, controls.dropFirst()) {
            XCTAssertLessThan(left.frame.midX, right.frame.midX)
            XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX + 1e-6)
        }
        XCTAssertEqual(controls[1].frame.maxX + 8, controls[2].frame.minX, accuracy: 1)
        XCTAssertFalse(ui.app.buttons["player.browse"].exists)
        ui.capture("player-leading-airplay-landscape-largest-text")
        try ui.tap(ui.app.buttons["player.artistName"])
        // Fitted sheets inset their scroll indicator above visible rows; use the actual sheet and bar bounds.
        try assertFittedChooser(ui, first: album, last: artist)
        ui.capture("album-artist-chooser-landscape-largest-text")
        try ui.tap(artist)
        try ui.expectArtistPage(named: "Norah Jones")
        try ui.openPlayer()
        try ui.expectCurrentTrack("fixture.setup.norah.2002")
        try ui.expectPosition(32)
    }

    private func assertFittedChooser(_ ui: AppUITestDriver, first: XCUIElement, last: XCUIElement,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let chooser = ui.element("player.browse.sheet")
        let navigation = ui.app.navigationBars["Album and Artists"]
        try ui.requireHittable(first)
        try ui.requireHittable(last)
        try ui.wait("The chooser must finish fitting its measured choices", timeout: 5) {
            chooser.exists && navigation.exists && chooser.frame.insetBy(dx: -1, dy: -1).contains(last.frame)
                && chooser.frame.maxY - last.frame.maxY < 80
                && first.frame.minY >= navigation.frame.maxY - 1
        }
        XCTAssertTrue(chooser.exists, file: file, line: line)
        XCTAssertTrue(navigation.exists, file: file, line: line)
        XCTAssertFalse(ui.element("player.options.sheet").exists, file: file, line: line)
        XCTAssertGreaterThanOrEqual(first.frame.minY, navigation.frame.maxY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(first.frame.minY, navigation.frame.maxY + 28, file: file, line: line)
        XCTAssertLessThan(chooser.frame.maxY - last.frame.maxY, 80,
                          "The last fitted choice must not leave a half-empty sheet.", file: file, line: line)
        for choice in [first, last] {
            XCTAssertGreaterThanOrEqual(choice.frame.height + 1e-6, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(choice.frame.width + 1e-6, 44, file: file, line: line)
            XCTAssertTrue(chooser.frame.insetBy(dx: -1, dy: -1).contains(choice.frame), file: file, line: line)
            XCTAssertTrue(ui.app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(choice.frame), file: file, line: line)
        }
        try ui.requireHittable(ui.app.buttons["player.browse.done"])
    }

    private func expectAlbum(_ ui: AppUITestDriver, title: String) throws {
        try ui.wait("Selecting an album must dismiss the chooser and player before showing its collection") {
            !ui.element("player.browse.sheet").exists && !ui.app.buttons["player.close"].exists
                && ui.app.staticTexts["ALBUM"].exists && ui.app.staticTexts["collection.title"].label == title
                && ui.app.buttons["collection.play"].exists
        }
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "player-browse")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}
